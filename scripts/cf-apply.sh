#!/usr/bin/env bash
# Snapshot of the Cloudflare API calls used in the 2026-07-02 cutover.
# Not a full runbook — see docs/runbooks/cloudflare-cutover.md for the
# ordering, verification steps, and gotchas.
#
# Idempotent: safe to re-run. Each PUT/PATCH is upserting existing
# rulesets/records.
#
# Usage:
#   scripts/cf-apply.sh
#
# Env / prereqs:
#   * CF_TOKEN either in env, or fetched from AWS Secrets Manager
#     (llmsafespaces/cloudflare-api-token).
#   * AWS_PROFILE=mikekao-prod for the fallback secret fetch.
#
# NOT covered by this script (do manually via CF dashboard or the runbook):
#   * Bot Fight Mode (Free tier: dashboard-only).
#   * DNS record proxy flip from grey to orange cloud (does that once
#     per record; re-runs are no-ops).
#   * Deleting stale ACM validation CNAMEs (one-off cleanup).

set -euo pipefail

# --- Setup ---
: "${AWS_PROFILE:=mikekao-prod}"
: "${AWS_REGION:=us-west-2}"
export AWS_PROFILE AWS_REGION

if [ -z "${CF_TOKEN:-}" ]; then
  echo "Fetching CF_TOKEN from AWS Secrets Manager..." >&2
  CF_TOKEN=$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" --output text \
    secretsmanager get-secret-value \
    --secret-id llmsafespaces/cloudflare-api-token \
    --query SecretString)
fi

ZONE=$(curl -s -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones?name=thekao.cloud" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"][0]["id"])')
echo "Zone: $ZONE" >&2

# --- Verify token ---
echo "=== [1/5] verifying token ===" >&2
curl -s -H "Authorization: Bearer $CF_TOKEN" \
  https://api.cloudflare.com/client/v4/user/tokens/verify \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["result"]["status"]=="active", d; print("token active")'

# --- Zone settings ---
echo "=== [2/5] zone security settings ===" >&2
patch() {
  local key=$1 val=$2
  local resp
  resp=$(curl -s -X PATCH \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE/settings/$key" \
    -d "{\"value\":\"$val\"}")
  echo "  $key -> $val: $(echo "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("success"))')"
}
patch always_use_https on
patch min_tls_version 1.2
patch automatic_https_rewrites on
patch browser_check on
patch security_level medium

# --- WAF: Cloudflare Managed Free Ruleset ---
echo "=== [3/5] WAF entry point (Managed Free Ruleset) ===" >&2
FREE_RULESET_ID=$(curl -s -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/rulesets" \
  | python3 -c 'import json,sys; [print(r["id"]) for r in json.load(sys.stdin)["result"] if r["phase"]=="http_request_firewall_managed" and r["kind"]=="managed"]')
[ -n "$FREE_RULESET_ID" ] || { echo "ERROR: no managed WAF ruleset found on this zone"; exit 1; }

curl -s -X PUT \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/rulesets/phases/http_request_firewall_managed/entrypoint" \
  -d "$(cat <<EOF
{
  "name":"default",
  "description":"llmsafespaces WAF entry point - deploys Cloudflare Managed Free Ruleset",
  "rules":[{
    "action":"execute",
    "action_parameters":{"id":"$FREE_RULESET_ID"},
    "expression":"true",
    "description":"Execute Cloudflare Managed Free Ruleset",
    "enabled":true
  }]
}
EOF
)" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["success"], d; print("  WAF entry point:", d["result"]["id"][:16])'

# --- Custom firewall rules ---
echo "=== [4/5] custom firewall rules ===" >&2
curl -s -X PUT \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/rulesets/phases/http_request_firewall_custom/entrypoint" \
  -d '{
    "name":"default",
    "description":"llmsafespaces custom firewall rules",
    "rules":[
      {
        "description":"Block PHP/WordPress/exploit-scanner probes (we do not serve any of these paths)",
        "expression":"(http.request.uri.path contains \".php\") or (http.request.uri.path contains \"/wp-admin\") or (http.request.uri.path contains \"/wp-login\") or (http.request.uri.path contains \"/xmlrpc\") or (http.request.uri.path contains \"/.env\") or (http.request.uri.path contains \"/.git/\")",
        "action":"block",
        "enabled":true
      },
      {
        "description":"Challenge requests to auth endpoints from high-threat-score IPs",
        "expression":"(http.request.uri.path in {\"/api/v1/auth/login\" \"/api/v1/auth/signup\"}) and (cf.threat_score gt 20)",
        "action":"managed_challenge",
        "enabled":true
      },
      {
        "description":"Block requests missing a User-Agent header (script-kiddie signal). Exempt k8s liveness paths so probes still work.",
        "expression":"(http.user_agent eq \"\") and not (http.request.uri.path in {\"/livez\" \"/healthz\" \"/readyz\"})",
        "action":"block",
        "enabled":true
      }
    ]
  }' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["success"], d; print("  custom firewall entry point:", d["result"]["id"][:16], "rules:", len(d["result"]["rules"]))'

# --- Rate limiting: /api/v1/auth/login ---
echo "=== [5/5] rate limit rule (Free tier: 1 rule, 10s window) ===" >&2
curl -s -X PUT \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/rulesets/phases/http_ratelimit/entrypoint" \
  -d '{
    "name":"default",
    "description":"llmsafespaces rate limiting entry point",
    "rules":[
      {
        "description":"Rate limit POST /api/v1/auth/login by IP (Free tier: 10s window/timeout)",
        "expression":"(http.request.uri.path eq \"/api/v1/auth/login\") and (http.request.method eq \"POST\")",
        "action":"block",
        "action_parameters":{
          "response":{
            "status_code":429,
            "content":"{\"error\":\"rate_limited\",\"retry_after_seconds\":10}",
            "content_type":"application/json"
          }
        },
        "ratelimit":{
          "characteristics":["ip.src","cf.colo.id"],
          "period":10,
          "requests_per_period":5,
          "mitigation_timeout":10
        },
        "enabled":true
      }
    ]
  }' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["success"], d; print("  rate limit entry point:", d["result"]["id"][:16])'

echo ""
echo "=== DONE ==="
echo "Reminder: Bot Fight Mode (dashboard-only on Free tier) is NOT toggled by this script."
echo "         Toggle manually: CF dashboard -> Security -> Bots -> Bot Fight Mode -> On"
