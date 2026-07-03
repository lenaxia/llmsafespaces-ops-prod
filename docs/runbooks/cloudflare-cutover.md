# Runbook: Cloudflare cutover + ALB origin lock

**Type**: One-time cutover.
**Estimated duration**: 20-30 minutes wall-clock via API (10-15 min via Terraform).
**Blast radius**: Brief (~30s) TLS-handshake blip on the first orange-cloud flip. Origin-lock flip is zero-downtime. Follow the order below carefully.
**Rollback**: DNS revert takes ~30s (flip proxied=false); origin-lock revert takes ~2 min (annotation removal + AWS LBC reconcile).

## Why

Currently the app is exposed via `safespaces.thekao.cloud` → CNAME → ALB. Without Cloudflare's edge in the request path, any attacker who resolves the ALB's DNS name can hit it directly. Without origin lock, any attacker who guesses the ALB hostname (or grabs it from Cloudflare-bypass techniques) can hit the ALB even *with* Cloudflare in front.

This runbook flips DNS to Cloudflare-proxied (orange cloud), enables the WAF + custom firewall rules + rate limits, and locks the ALB Security Group so only Cloudflare's edge IP ranges can reach it on :443.

## Two implementation paths

**Path A — Direct API calls (chosen for the 2026-07-02 cutover).** Uses `curl` against the Cloudflare v4 REST API. No extra tools needed. Best when you're doing this once and want zero Terraform overhead for a personal/small-team zone. Every setting change is a documented API call in git for reference.

**Path B — Terraform.** Uses `~/llmsafespaces-cdk/terraform/cloudflare/`. Better when you'll be re-provisioning zones, running drift detection, or need >1 person managing the config. Requires terraform CLI + tfstate bucket + backend config. See `~/llmsafespaces-cdk/terraform/cloudflare/README.md`.

**The API path (A) is the source of truth for the 2026-07-02 deploy. The Terraform module (B) is documented but was not applied to prod.** Any future changes should keep both paths in sync until we consolidate on one.

---

## Prerequisites (both paths)

1. **Cloudflare API token** with permissions:
   - Zone → Zone → Read
   - Zone → DNS → Edit
   - Zone → Zone Settings → Edit
   - Zone → Firewall Services → Edit
   - Zone → Zone WAF → Edit
   - Zone → Page Rules → Edit *(optional, for future page-rule additions)*
   - Zone Resources: Include specific zone → `thekao.cloud`

   Store in AWS Secrets Manager:
   ```bash
   aws --profile mikekao-prod --region us-west-2 secretsmanager create-secret \
     --name llmsafespaces/cloudflare-api-token \
     --description 'Cloudflare API token scoped to thekao.cloud zone.' \
     --secret-string 'YOUR_CF_TOKEN' \
     --tags 'Key=project,Value=llmsafespaces'
   ```

2. **ACM cert with grafana SAN already ISSUED**. If the cert doesn't cover `grafana.safespaces.thekao.cloud`, that subdomain will 526 through Cloudflare (invalid origin cert). See `docs/worklogs/2026-07-02-session2-checkpoint.md` for how the cert was provisioned out-of-band. Verify:
   ```bash
   echo | openssl s_client -connect safespaces.thekao.cloud:443 -servername safespaces.thekao.cloud 2>/dev/null \
     | openssl x509 -noout -text | grep -A1 "Subject Alternative Name"
   # Should list both safespaces.thekao.cloud AND grafana.safespaces.thekao.cloud.
   ```

3. **Cluster + Cilium migration complete**. Not strictly required, but the runbook assumes both are already done.

---

## Path A: API-driven cutover (the 2026-07-02 procedure)

Set up the shell env once:

```bash
CF_TOKEN=$(aws --profile mikekao-prod --region us-west-2 --output text secretsmanager get-secret-value \
  --secret-id llmsafespaces/cloudflare-api-token --query SecretString)
# Then look up the zone ID (32-char hex under the zone in CF dashboard, or via API):
ZONE=$(curl -s -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones?name=thekao.cloud" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"][0]["id"])')
echo "Zone: $ZONE"
```

### Step A1 — Verify token + list existing DNS records (~1 min)

```bash
# Verify token is active
curl -s -H "Authorization: Bearer $CF_TOKEN" \
  https://api.cloudflare.com/client/v4/user/tokens/verify \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("token status:", d["result"]["status"])'
# Expected: "token status: active"

# List existing DNS records for our subdomains
curl -s -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?per_page=100" \
  | python3 -c 'import json,sys
d=json.load(sys.stdin)
for r in d["result"]:
  if "safespaces" in r["name"] or "grafana" in r["name"]:
    print(r["type"], r["name"], r["content"], "proxied=" + str(r.get("proxied")))'
```

Expected: two CNAME records for `safespaces.thekao.cloud` and `grafana.safespaces.thekao.cloud` pointing at the current ALB hostname.

### Step A2 — Flip DNS records to orange cloud (~30s TLS blip)

If records already exist DNS-only, PATCH each with `proxied: true`. If they don't exist, POST fresh records.

```bash
# Grab the current ALB hostname
ALB_HOSTNAME=$(kubectl get ingress -A -l app.kubernetes.io/instance=llmsafespaces \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
echo "ALB: $ALB_HOSTNAME"

# For each subdomain, ensure a CNAME → ALB with proxied=true.
# The following script upserts the two records idempotently.
for SUB in safespaces grafana.safespaces; do
  FQDN="$SUB.thekao.cloud"
  # Try to find an existing record.
  RID=$(curl -s -H "Authorization: Bearer $CF_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?type=CNAME&name=$FQDN" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["result"][0]["id"] if d["result"] else "")')

  if [ -n "$RID" ]; then
    echo "Updating existing $FQDN → $ALB_HOSTNAME (proxied)"
    curl -s -X PATCH \
      -H "Authorization: Bearer $CF_TOKEN" \
      -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records/$RID" \
      -d "{\"type\":\"CNAME\",\"name\":\"$FQDN\",\"content\":\"$ALB_HOSTNAME\",\"proxied\":true,\"ttl\":1}" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  ok=" + str(d["success"]))'
  else
    echo "Creating $FQDN → $ALB_HOSTNAME (proxied)"
    curl -s -X POST \
      -H "Authorization: Bearer $CF_TOKEN" \
      -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records" \
      -d "{\"type\":\"CNAME\",\"name\":\"$FQDN\",\"content\":\"$ALB_HOSTNAME\",\"proxied\":true,\"ttl\":1}" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  ok=" + str(d["success"]))'
  fi
done

# Verify the flip
curl -sI https://safespaces.thekao.cloud/livez | grep -iE '^(server|cf-ray)'
# Expected: `server: cloudflare` and a `cf-ray: <hex>-<colo>` header.
```

**Gotcha found 2026-07-02**: `curl -sI ... | grep -iE 'server:|cf-ray'` sometimes silently misses the header even when it's there because of how curl buffers the HEAD response. Use `head -20` instead of grep to be sure, or run the request twice.

### Step A3 — Zone security settings (~1 min)

Set 5 zone settings. Each is a separate PATCH.

```bash
patch_setting() {
  local key=$1 val=$2
  curl -s -X PATCH \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE/settings/$key" \
    -d "{\"value\":\"$val\"}" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print('$key:', d.get('success'), '->', d.get('result',{}).get('value'))"
}

patch_setting always_use_https on           # HTTP→HTTPS 301 at the edge
patch_setting min_tls_version 1.2           # Reject TLS 1.0/1.1 clients
patch_setting automatic_https_rewrites on   # Bump `http://` in origin content to `https://`
patch_setting browser_check on              # Drop requests missing common browser headers
patch_setting security_level medium         # Challenge low-reputation IPs
# NB: `ssl` should already be "strict" (validates origin cert). Verify:
curl -s -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/settings/ssl" \
  | python3 -c 'import json,sys; print("ssl:", json.load(sys.stdin)["result"]["value"])'
# Expected: `ssl: strict`. If different, set with patch_setting ssl strict.
```

### Step A4 — Bot Fight Mode (SKIP on Free tier)

**Free-tier limitation discovered 2026-07-02**: Bot Fight Mode cannot be toggled via API without the Bot Management add-on. The `/zones/$ZONE/bot_management` endpoint returns "Authentication error" (code 10000) even with `Zone Settings:Edit`, and `/zones/$ZONE/settings/bot_fight_mode` returns "Undefined zone setting" (code 1003).

**Workaround**: Toggle it in the CF dashboard manually:
1. Log in → select `thekao.cloud` zone
2. Security → Bots
3. Toggle "Bot Fight Mode" to **On**

Not a security regression; the WAF + rate-limits + Managed Ruleset below already catch most botnet traffic. Bot Fight Mode is a bonus JavaScript challenge for low-reputation IPs.

### Step A5 — Deploy Cloudflare Managed Free Ruleset (~1 min)

Free tier gets the "Cloudflare Managed Free Ruleset" (not the full Managed Ruleset, not the OWASP Core Ruleset — those need Pro plan). It's still meaningful: covers common exploit patterns for known CVEs.

```bash
# Look up the Managed Free Ruleset UUID (published constant per-zone, so no hard-coding)
FREE_RULESET_ID=$(curl -s -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/rulesets" \
  | python3 -c 'import json,sys; [print(r["id"]) for r in json.load(sys.stdin)["result"] if r["phase"]=="http_request_firewall_managed"]')
echo "Managed Free Ruleset ID: $FREE_RULESET_ID"

# Create/update the entry-point ruleset for the http_request_firewall_managed phase.
curl -s -X PUT \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/rulesets/phases/http_request_firewall_managed/entrypoint" \
  -d "{
    \"name\":\"default\",
    \"description\":\"llmsafespaces WAF entry point - deploys Cloudflare Managed Free Ruleset\",
    \"rules\":[
      {
        \"action\":\"execute\",
        \"action_parameters\":{\"id\":\"$FREE_RULESET_ID\"},
        \"expression\":\"true\",
        \"description\":\"Execute Cloudflare Managed Free Ruleset\",
        \"enabled\":true
      }
    ]
  }" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("success:", d.get("success"))'
```

**Gotcha found 2026-07-02**: Do not include `"kind":"zone"` or `"phase":"..."` in the PUT body for the entry-point endpoint — CF rejects with "unknown field kind". Those are inferred from the URL.

### Step A6 — Custom firewall rules (~1 min)

Free tier allows 5 custom firewall rules. We deploy 3, leaving 2 spare.

```bash
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
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("success:", d.get("success"))'
```

**Design note**: the auth-endpoint challenge rule is complementary to the rate limit below. Rate limit catches sustained volumes; the threat-score challenge catches even a single request from a known-bad IP.

### Step A7 — Rate limiting (~1 min)

**Free-tier limitations discovered 2026-07-02**:
- Only **1** rate limiting rule per zone.
- `period` can only be `10` seconds. Requesting 60 gets `"not entitled to use the period 60, can only use a period among [10]"`.
- `mitigation_timeout` can only be `10` seconds. Requesting 600 gets `"not entitled to use a mitigation timeout different from 10"`.

Given the 1-rule budget, the highest-value target is `/api/v1/auth/login` (credential-stuffing has the biggest business impact). 5 requests per 10 seconds → sustained attackers get blocked; a user typing wrong password 2-3× is fine.

```bash
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
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("success:", d.get("success"))'
```

**Trade-off**: The `signup` and generic `/api/*` rate limits from the Terraform module can't be deployed on Free tier — we'd need Pro plan ($20/mo/zone) for 5+ rules. Custom firewall rule #2 (threat-score challenge on `/auth/*`) partially compensates for this.

### Step A8 — Verify all rules fire (~2 min)

```bash
echo "=== 1. Baseline: CF is in path ==="
curl -sI https://safespaces.thekao.cloud/livez | head -10
# Expect: `server: cloudflare` + `cf-ray: ...`

echo "=== 2. WAF: PHP probe should be BLOCKED ==="
curl -sw 'http=%{http_code}\n' -o /tmp/resp.html https://safespaces.thekao.cloud/wp-admin/admin.php
# Expect: http=403, response body contains "Cloudflare" and "blocked"

echo "=== 3. Custom firewall: no User-Agent should be BLOCKED ==="
curl -sw 'http=%{http_code}\n' -o /dev/null -H 'User-Agent:' https://safespaces.thekao.cloud/
# Expect: http=403

echo "=== 4. Custom firewall: livez exempted from no-UA block ==="
curl -sw 'http=%{http_code}\n' -o /dev/null -H 'User-Agent:' https://safespaces.thekao.cloud/livez
# Expect: http=200

echo "=== 5. Rate limit: 8 rapid POSTs to /login should trigger 429 by request 6 ==="
for i in $(seq 1 8); do
  CODE=$(curl -so /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -H 'User-Agent: rate-limit-tester' \
    -d '{"email":"nobody@example.com","password":"x"}' \
    https://safespaces.thekao.cloud/api/v1/auth/login)
  echo "req $i: HTTP $CODE"
done
# Expect: 5x 401 (bad creds pass-through) followed by 429s. Some 401s may
# slip in between 429s because the 10s mitigation timeout is short.
```

### Step A9 — Delete stale ACM validation CNAMEs (~30s)

The ACM cert is ISSUED. The DNS validation CNAMEs (from the cert request in session-2) can be removed.

```bash
# List them first to confirm
curl -s -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?per_page=100" \
  | python3 -c 'import json,sys
for r in json.load(sys.stdin)["result"]:
  if r["name"].startswith("_") and "acm-validations" in r.get("content",""):
    print(r["id"], r["name"])'

# For each returned ID:
# curl -s -X DELETE -H "Authorization: Bearer $CF_TOKEN" \
#   "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records/<RID>"
```

Leave any unrelated `_acme-challenge.*` TXT records alone (they may be for other cert issuers, e.g. cert-manager).

### Step A10 — Enable ALB origin lock (~2 min)

Add `alb.ingress.kubernetes.io/inbound-cidrs` + `inbound-ipv6-cidrs` annotations to the frontend Ingress via the ops-prod helm-release.yaml. AWS LBC replaces the ALB SG's `0.0.0.0/0` :443 rule with per-CIDR rules for each Cloudflare edge range.

```bash
cd ~/llmsafespaces-ops-prod

# CIDR lists live in kubernetes/apps/llmsafespaces/llmsafespaces/app/cloudflare-ip-ranges.yaml
# (documented ConfigMap; not consumed at runtime — the annotations below are the source of truth).

# Edit kubernetes/apps/llmsafespaces/llmsafespaces/app/helm-release.yaml.
# Under `frontend.ingress.annotations`, uncomment/add:
#
#   alb.ingress.kubernetes.io/inbound-cidrs: "173.245.48.0/20,103.21.244.0/22,103.22.200.0/22,103.31.4.0/22,141.101.64.0/18,108.162.192.0/18,190.93.240.0/20,188.114.96.0/20,197.234.240.0/22,198.41.128.0/17,162.158.0.0/15,104.16.0.0/13,104.24.0.0/14,172.64.0.0/13,131.0.72.0/22"
#   alb.ingress.kubernetes.io/inbound-ipv6-cidrs: "2400:cb00::/32,2606:4700::/32,2803:f800::/32,2405:b500::/32,2405:8100::/32,2a06:98c0::/29,2c0f:f248::/32"

git commit -am "enable ALB origin lock (Cloudflare edge IPs only)"
git push

flux reconcile source git llmsafespaces-ops
flux reconcile helmrelease -n llmsafespaces llmsafespaces

# AWS LBC picks up the annotation change within ~30-60s. Verify by
# checking the ALB SG:
ALB_ARN=$(aws --profile mikekao-prod --region us-west-2 --output text elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(DNSName,'llmsafes')].LoadBalancerArn" | head -1)
SG_ID=$(aws --profile mikekao-prod --region us-west-2 --output text elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].SecurityGroups[0]')
aws --profile mikekao-prod --region us-west-2 --output table ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`443`].IpRanges[*].CidrIp'
# Expected: 15 Cloudflare IPv4 CIDRs. NOT 0.0.0.0/0.
```

### Step A11 — Verify origin lock works (~1 min)

```bash
# 1. Through Cloudflare (SHOULD succeed):
curl -sf https://safespaces.thekao.cloud/livez && echo OK

# 2. Direct-to-ALB (SHOULD fail; SG drops SYN):
ALB_HOSTNAME=$(aws --profile mikekao-prod --region us-west-2 --output text elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(DNSName,'llmsafes')].DNSName" | head -1)
curl -sfm 10 "https://$ALB_HOSTNAME/livez" -H "Host: safespaces.thekao.cloud" 2>&1 | tail -3
# Expected: `curl: (28) Connection timed out after 10001 milliseconds`
# If you get HTTP 200, the SG rule isn't applied yet — wait 2 min and retry.
# If you get HTTP 502/503, LBC hit a race condition; re-run
# `flux reconcile helmrelease -n llmsafespaces llmsafespaces`.
```

---

## Path B: Terraform (not applied to prod as of 2026-07-02)

See `~/llmsafespaces-cdk/terraform/cloudflare/README.md`. The module exists and is well-commented, but on Free tier some resources will fail:
- `cloudflare_ruleset.zone_ratelimit` with 3 rules → fails (Free = 1 rule).
- `period: 60` / `mitigation_timeout: 600` in `rate-limit.tf` → fails (Free = 10s only).
- `cloudflare_turnstile_widget` → works, but the site key hasn't been wired into the frontend chart yet.
- OWASP Core Ruleset in `waf.tf` → fails (paid-only).

To make the module Free-tier-compatible, replace `rate-limit.tf` with a single-rule variant matching Path A step A7, and drop the OWASP execute rule from `waf.tf`.

---

## Rollback

### Rollback origin lock only (keep Cloudflare in the request path)

Remove the two `inbound-cidrs` annotations from `helm-release.yaml`. AWS LBC restores the `0.0.0.0/0` :443 rule.

```bash
cd ~/llmsafespaces-ops-prod
# Delete both annotation lines from helm-release.yaml, then:
git commit -am "rollback: remove ALB origin lock annotations"
git push
flux reconcile source git llmsafespaces-ops
flux reconcile helmrelease -n llmsafespaces llmsafespaces
```

### Rollback Cloudflare entirely (revert to DNS-only)

**IMPORTANT**: remove the origin lock FIRST, or DNS-only traffic will hit the ALB SG's Cloudflare-only rule and be dropped.

```bash
# Step 1: rollback origin lock (see above).

# Step 2: flip both DNS records to proxied=false via API:
for SUB in safespaces grafana.safespaces; do
  FQDN="$SUB.thekao.cloud"
  RID=$(curl -s -H "Authorization: Bearer $CF_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?type=CNAME&name=$FQDN" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"][0]["id"])')
  curl -s -X PATCH \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records/$RID" \
    -d '{"proxied":false}'
done

# Step 3 (optional): remove the deployed rulesets. Only do this if
# rolling back permanently; otherwise leave them in place.
# List entry-point rulesets:
curl -s -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/rulesets" \
  | python3 -c 'import json,sys; [print(r["id"], r["phase"]) for r in json.load(sys.stdin)["result"] if r["kind"]=="zone"]'
# For each, DELETE:
# curl -s -X DELETE -H "Authorization: Bearer $CF_TOKEN" \
#   "https://api.cloudflare.com/client/v4/zones/$ZONE/rulesets/<RID>"
```

---

## Known gotchas (found during 2026-07-02 cutover)

1. **`curl -sI ... | grep 'cf-ray'` sometimes silently misses the header** even when it's there. Symptom: you think Cloudflare isn't proxying, but a full `curl -sI` shows `server: cloudflare` and `cf-ray:` in the output. Use `head -20` on the raw output before concluding.

2. **Cloudflare API token permission wording is confusing.** `Zone WAF Edit` is REQUIRED for `/zones/$ZONE/rulesets/*` endpoints, and it's separate from `Firewall Services: Edit`. Symptom: a token with only Firewall Services can list DNS records + write filters but gets "Authentication error" (code 10000) on `/rulesets`. Recreate the token with both permissions.

3. **Free-tier rate-limiting is severely constrained.**
   - Only 1 rule per zone.
   - `period` must be `10` seconds (60 is rejected).
   - `mitigation_timeout` must be `10` seconds (600 is rejected).
   - Combined effect: with 5 req / 10s window / 10s block, attackers doing 100 req/s get blocked in bursts of 10s. Not perfect but non-trivially annoying.

4. **Free-tier Bot Fight Mode is dashboard-only.** No API path works; both `/zones/$ZONE/bot_management` and `/zones/$ZONE/settings/bot_fight_mode` fail. Toggle it manually in the CF dashboard → Security → Bots. Not a security regression — WAF + rate-limits + Managed Ruleset cover most bot patterns.

5. **The entry-point ruleset PUT endpoint rejects `kind` + `phase` fields.** Symptom: `"invalid JSON: unknown field \"kind\""`. Those are inferred from the URL (`/zones/$ZONE/rulesets/phases/$PHASE/entrypoint`), so drop them from the JSON body.

6. **Managed Ruleset IDs are 32-char UUIDs; the 16-char preview shown in list output isn't valid.** Symptom: `execute` action with a truncated ID fails. Always take the full ID from `.result[].id`, not from a formatted print.

7. **`aws secretsmanager describe-secret` can return "exists" for a non-existent secret in some SDK versions.** Symptom: `describe-secret --secret-id X` succeeds, but `update-secret --secret-id X` fails with `ResourceNotFoundException`. Just call `create-secret`; if it says "already exists" then it does, and use `put-secret-value` on the ARN instead.

8. **WebSocket connections through Cloudflare on Free/Pro plan**. Cloudflare proxies WebSockets by default on all plans. Watch for reconnect loops in the terminal after cutover — that's the tell.

9. **`min_tls_version = 1.2`** rejects TLS 1.0/1.1 clients (mostly Windows XP / IE6 / very old Android). Not a real concern.

10. **Cloudflare's edge IPs change (rarely).** When they do, the `cloudflare-ip-ranges.yaml` ConfigMap AND the Ingress annotation must both be updated. There's no auto-sync; Renovate can PR the ConfigMap but not the annotation. Consider writing a Kustomize replacement transformer once we've done this a second time.

11. **Turnstile widget isn't wired into the chart yet.** Emitted as a Terraform output; the frontend chart needs a values-side plumbing PR (upstream `lenaxia/LLMSafeSpaces`) to render the widget on signup.

---

## References

- Cloudflare v4 API docs: <https://developers.cloudflare.com/api/>
- Rulesets API reference: <https://developers.cloudflare.com/ruleset-engine/rulesets-api/>
- Free-tier limits (rate limiting): <https://developers.cloudflare.com/waf/rate-limiting-rules/parameters/#requests-per-period>
- AWS LBC `inbound-cidrs` annotation: <https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/annotations/#load-balancer-attributes>
- Cloudflare IP ranges (canonical): <https://www.cloudflare.com/ips/>
- Terraform module: `~/llmsafespaces-cdk/terraform/cloudflare/`
- Related issue: [lenaxia/llmsafespaces-aws-cdk#15](https://github.com/lenaxia/llmsafespaces-aws-cdk/issues/15)
