# Runbook: Cloudflare cutover + ALB origin lock

**Type**: One-time cutover.
**Estimated duration**: 30-45 minutes wall-clock (including provisioning wait).
**Blast radius**: Brief (~2 min) failure window during the DNS + origin-lock flip if steps are done out of order. Follow the order below carefully.
**Rollback**: DNS revert takes ~30s (`terraform destroy -target=cloudflare_dns_record.app`); origin-lock revert takes ~2 min (annotation removal + AWS LBC reconcile).

## Why

Currently the app is exposed via `safespaces.thekao.cloud` → CNAME → ALB with **DNS-only** Cloudflare (grey cloud). That means Cloudflare's WAF, rate-limits, and Bot Fight Mode are **not** in the request path. Any attacker who resolves the ALB's DNS name can hit it directly.

This runbook flips the DNS to Cloudflare-proxied (orange cloud), enables the WAF + rate-limits + Turnstile via the Cloudflare Terraform module, and locks the ALB SG to only accept traffic from Cloudflare's edge IPs.

## Prerequisites

1. **Cloudflare API token** in AWS Secrets Manager. Setup:
   ```bash
   # 1. Cloudflare dashboard → My Profile → API Tokens → Create Token
   #    Template: Custom, permissions:
   #      Zone:DNS:Edit + Zone:Zone Settings:Edit + Zone:Firewall Services:Edit +
   #      Zone:WAF:Edit + Account:Turnstile Sites:Edit
   #    Zone Resources: Include specific zone → thekao.cloud
   #    Account Resources: Include specific account → your account
   # 2. Store in AWS Secrets Manager:
   aws secretsmanager create-secret --profile mikekao-prod --region us-west-2 \
     --name llmsafespaces/cloudflare-api-token \
     --description 'Cloudflare API token for terraform to manage the llmsafespaces zone' \
     --secret-string 'YOUR_CF_TOKEN'
   ```

2. **Terraform state bucket** exists (see `~/llmsafespaces-cdk/terraform/cloudflare/README.md` for the CLI to create it).

3. **Terraform CLI ≥ 1.9** installed locally. Install: <https://developer.hashicorp.com/terraform/install>.

4. **Grafana SAN cert** already issued (see docs/worklogs/2026-07-02-checkpoint.md; the operator flipped this to out-of-band with `llmsafespaces:certificateArn` context). If the cert with `grafana.safespaces.thekao.cloud` SAN isn't ISSUED yet in ACM, do that FIRST — otherwise TLS for the grafana subdomain won't work post-cutover.

## Step 1 — Apply Terraform, but keep DNS records DNS-only initially (~5 min)

The Terraform module creates DNS records with `proxied = true` by default. Override for the first apply to keep the current DNS-only behavior — this lets us validate WAF/rate-limits are in place before flipping the proxy.

```bash
cd ~/llmsafespaces-cdk/terraform/cloudflare

# Grab the current ALB hostname.
ALB_HOSTNAME=$(kubectl get ingress -A -l app.kubernetes.io/instance=llmsafespaces \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
echo "ALB: $ALB_HOSTNAME"

# Grab the Cloudflare account ID.
# CF dashboard → your account → sidebar has "Account ID"
CF_ACCOUNT_ID="REPLACE_WITH_YOUR_CF_ACCOUNT_ID"

cat > terraform.tfvars <<EOF
cloudflare_account_id = "$CF_ACCOUNT_ID"
zone_name             = "thekao.cloud"
subdomains            = ["safespaces", "grafana.safespaces"]
alb_hostname          = "$ALB_HOSTNAME"
EOF

terraform init
terraform plan -out=cf.plan
# Sanity check the plan — should create:
#   - 2 cloudflare_dns_record (safespaces + grafana.safespaces, proxied=true)
#   - 5 cloudflare_zone_setting (security level, TLS, HTTPS rewrites, browser check, bot fight)
#   - 2 cloudflare_ruleset (WAF managed, rate limits)
#   - 1 cloudflare_turnstile_widget
#   - 1 aws_secretsmanager_secret (turnstile secret)

terraform apply cf.plan
```

The DNS records are created with proxied=true, which flips the DNS record for `safespaces.thekao.cloud` from CNAME (DNS-only) to CNAME (Cloudflare-proxied). This may cause a brief (~30s) window of TLS mismatch: Cloudflare presents its own edge cert while the browser expects the ALB's ACM cert. Modern browsers accept CF's Universal SSL cert for the zone; test in an incognito window.

## Step 2 — Verify Cloudflare is in the request path (~2 min)

```bash
curl -sv https://safespaces.thekao.cloud/livez 2>&1 | grep -iE 'server:|cf-ray|cf-cache-status'
# Expected: 
#   Server: cloudflare
#   cf-ray: 8xxxxxxxxxxxxxxx-<colo>
#   cf-cache-status: DYNAMIC

# Test the rate limit on /api/v1/auth/login. Should return 429 after
# 5 requests/60s from the same source.
for i in $(seq 1 8); do
  code=$(curl -sw '%{http_code}\n' -o /dev/null \
    -X POST https://safespaces.thekao.cloud/api/v1/auth/login \
    -H 'Content-Type: application/json' \
    -d '{"email":"nobody@example.com","password":"x"}')
  echo "req $i: $code"
done
# Expected: first 5 return 400 (bad credentials, not rate-limited), 
# requests 6-8 return 429 with content-type: application/json.
```

If Cloudflare isn't proxying, check DNS: `dig safespaces.thekao.cloud +short` should return an IP in Cloudflare's ranges (e.g. `104.16.*` or `172.64.*`), not the ALB's direct IP.

## Step 3 — Enable ALB origin lock (~2 min, PLANNED downtime window: ~90s)

Add the `inbound-cidrs` + `inbound-ipv6-cidrs` annotations to the frontend Ingress. The AWS LBC will replace the ALB SG's `0.0.0.0/0` :443 rule with rules for each Cloudflare CIDR. **During the transition (~10s)** the SG has both the old and new rules, so no traffic is dropped. After LBC removes the `0.0.0.0/0` rule, only Cloudflare's edge can reach :443.

```bash
cd ~/llmsafespaces-ops-prod

# Copy the CIDR values from the ConfigMap into the Ingress annotations.
# Easiest via sed on the helm-release.yaml — the block is commented
# out and the ConfigMap has the source-of-truth list.

# Extract v4 and v6 as CSV.
V4_CIDRS=$(kubectl -n llmsafespaces get cm cloudflare-ip-ranges \
  -o jsonpath='{.data.ips-v4}' | tr '\n' ',' | sed 's/,$//' | sed 's/,/,/g')
V6_CIDRS=$(kubectl -n llmsafespaces get cm cloudflare-ip-ranges \
  -o jsonpath='{.data.ips-v6}' | tr '\n' ',' | sed 's/,$//' | sed 's/,/,/g')

# Edit kubernetes/apps/llmsafespaces/llmsafespaces/app/helm-release.yaml.
# Under `frontend.ingress.annotations`, after certificate-arn, add:
#
#   alb.ingress.kubernetes.io/inbound-cidrs: "$V4_CIDRS"
#   alb.ingress.kubernetes.io/inbound-ipv6-cidrs: "$V6_CIDRS"
#
# (Substitute the actual CSV strings from the env vars above.)

git commit -am "enable ALB origin lock (Cloudflare edge only)"
git push

# Force Flux to reconcile immediately.
flux reconcile source git llmsafespaces-ops
flux reconcile helmrelease -n llmsafespaces llmsafespaces

# Watch AWS LBC apply the annotation changes to the ALB SG.
kubectl -n llmsafespaces get events --sort-by='.lastTimestamp' | tail -20
# Expected: `Ingress ...`  ->  reconcile events from
# aws-load-balancer-controller.

# Confirm the SG in AWS console (or CLI):
ALB_ARN=$(aws elbv2 describe-load-balancers --profile mikekao-prod --region us-west-2 \
  --query "LoadBalancers[?contains(DNSName,'llmsafes')].LoadBalancerArn" \
  --output text)
SG_ID=$(aws elbv2 describe-load-balancers --profile mikekao-prod --region us-west-2 \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].SecurityGroups[0]' --output text)
aws ec2 describe-security-groups --profile mikekao-prod --region us-west-2 \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`443`]' \
  --output table
# Expected: many IpRanges entries, all Cloudflare CIDRs. No 0.0.0.0/0.
```

## Step 4 — Verify origin lock works (~2 min)

```bash
# From your workstation — this SHOULD succeed (Cloudflare fetches on
# your behalf).
curl -sf https://safespaces.thekao.cloud/livez && echo OK

# From your workstation — direct-to-ALB SHOULD fail (SSL handshake
# times out because the SG drops the SYN).
ALB_HOSTNAME=$(aws elbv2 describe-load-balancers --profile mikekao-prod --region us-west-2 \
  --query "LoadBalancers[?contains(DNSName,'llmsafes')].DNSName" --output text)
curl -sfm 10 "https://$ALB_HOSTNAME/livez" -H "Host: safespaces.thekao.cloud" 2>&1 | tail -3
# Expected: `curl: (28) Connection timed out after 10001 milliseconds`
# NOT: HTTP 200 OK. If you get 200, the SG rule isn't applied yet —
# wait ~2 min and retry (AWS LBC reconcile can take up to 2 min).
```

## Rollback

### Rollback origin lock only (keep Cloudflare in the request path)

Remove the `inbound-cidrs` + `inbound-ipv6-cidrs` annotations from the frontend Ingress. AWS LBC restores the SG's `0.0.0.0/0` :443 rule.

```bash
cd ~/llmsafespaces-ops-prod
# Delete the two annotation lines from helm-release.yaml, then:
git commit -am "rollback: remove ALB origin lock annotations"
git push
flux reconcile source git llmsafespaces-ops
flux reconcile helmrelease -n llmsafespaces llmsafespaces
```

### Rollback Cloudflare entirely (revert DNS to point directly to ALB)

```bash
cd ~/llmsafespaces-cdk/terraform/cloudflare
# Flip proxied=false on the DNS records:
terraform apply -var-file=terraform.tfvars -replace='cloudflare_dns_record.app["safespaces"]' \
  -replace='cloudflare_dns_record.app["grafana.safespaces"]'
# ...but with the `proxied = true` still hardcoded in dns.tf, this
# won't help. Instead, edit dns.tf and set proxied=false, then:
terraform apply

# OR nuke the entire zone config (removes WAF, rate limits, etc):
terraform destroy
```

Also make sure to remove the origin lock annotations FIRST if they're in place, or you'll cut off all traffic to the ALB the moment DNS resolves to a non-CF IP.

## Known gotchas

1. **WebSocket connections through Cloudflare**. Cloudflare proxies WebSockets on Enterprise plan; on Free/Pro they're supported for the standard `/api/v1/terminal` upgrade path. Watch for reconnect loops in the terminal after cutover — that's the tell.

2. **Rate limits count Cloudflare's own retries**. If a browser page issues 60 concurrent XHRs (e.g. an over-parallelized dashboard load), it can hit the 60/min limit. Bump `rate_limit_api_requests_per_minute` in tfvars if you see legit users blocked.

3. **Cloudflare Zone Setting `min_tls_version = 1.2`** rejects the very old TLS 1.0 / 1.1 clients (mostly Windows XP / IE6). Nobody who runs code sandboxes uses those.

4. **Cloudflare's edge IPs change (rarely).** When they do, the `cloudflare-ip-ranges.yaml` ConfigMap AND the annotation values must both be updated together. There's a Renovate config in the repo that auto-PRs the ConfigMap; you have to manually copy through to the annotation until an operator writes a Kustomize replacement transformer.

5. **Turnstile widget hasn't been wired into the chart yet.** The `turnstile_site_key` is emitted as a Terraform output; the frontend chart needs a values-side plumbing PR (upstream `lenaxia/LLMSafeSpaces`) to render the widget on signup. Track: file an issue in the upstream repo.

## References

- Cloudflare Terraform module: `../../../llmsafespaces-cdk/terraform/cloudflare/`
- Cloudflare IP ranges (canonical): <https://www.cloudflare.com/ips/>
- AWS LBC inbound-cidrs annotation: <https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/annotations/#load-balancer-attributes>
- Related issue: [lenaxia/llmsafespaces-aws-cdk#15](https://github.com/lenaxia/llmsafespaces-aws-cdk/issues/15)
