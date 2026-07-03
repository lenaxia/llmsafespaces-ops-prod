# 2026-07-02: Session 4 checkpoint — Cloudflare cutover + ALB origin lock complete

## Status: **9.5/10**

This session completed the Cloudflare cutover without Terraform, using direct v4 API calls. The last major posture piece from the session-1 plan is now live.

Remaining to reach 10/10:
- **Bot Fight Mode** — dashboard-only toggle on Free tier (not a security regression; WAF + rate-limits cover most bot patterns).
- **Workspace FQDN egress enforcement** — chart-side bug from session 3 (chart's built-in NetworkPolicy defeats our CNP allowlist).
- **vm-stack helm rollback** — pre-existing failed rollback blocking monitoring/loki/vector/falco.
- **Grafana ingress** — cert covers grafana subdomain but no ingress backend yet.
- **Turnstile widget** — created via Terraform output but not wired into frontend chart.

## What went live this session

### 1. DNS proxy state
- `safespaces.thekao.cloud` + `grafana.safespaces.thekao.cloud` were already proxied (orange cloud) from a prior operator action. `curl -sI ... | head -20` shows `server: cloudflare` and `cf-ray:` headers.

### 2. Zone security settings (via API)
- `always_use_https: on` (HTTP→HTTPS 301 at edge)
- `min_tls_version: 1.2` (reject TLS 1.0/1.1)
- `automatic_https_rewrites: on`
- `browser_check: on`
- `security_level: medium`
- `ssl: strict` (verified — already set)

### 3. WAF: Cloudflare Managed Free Ruleset
- Ruleset ID `77454fe2d30c4220b5701f6fdfb893ba` deployed at `http_request_firewall_managed` phase entry-point.
- The full Managed Ruleset and OWASP Core Ruleset require Pro plan — not available.

### 4. Custom firewall rules (3 rules, at http_request_firewall_custom phase)
- Block PHP/WordPress/exploit-scanner probes (`.php`, `/wp-admin`, `/xmlrpc`, `/.env`, `/.git/`).
- Managed-challenge auth endpoint requests when `cf.threat_score > 20`.
- Block requests missing User-Agent header (exempting `/livez`, `/healthz`, `/readyz`).

### 5. Rate limiting (1 rule at http_ratelimit phase — Free tier limit)
- `POST /api/v1/auth/login`: 5 requests per 10 seconds per IP, block for 10 seconds. Free tier only allows this configuration; the Terraform module's 60s/600s doesn't work.

### 6. Cleanup
- Deleted 2 ACM validation CNAMEs from Cloudflare DNS (`_e8dd0eab...safespaces`, `_498732e7...grafana.safespaces`) — cert is ISSUED, records no longer needed.

### 7. ALB origin lock
- Added `alb.ingress.kubernetes.io/inbound-cidrs` + `inbound-ipv6-cidrs` annotations to the frontend Ingress via ops-prod helm-release.yaml.
- AWS LBC replaced the ALB `frontend-sg`'s `0.0.0.0/0` :443 rule with 15 Cloudflare IPv4 CIDRs.
- IPv6 annotation silently dropped because the ALB is `IpAddressType: ipv4` — no IPv6 threat vector exists on this ALB.

Verification: direct-to-ALB (via DNS name AND via IP) times out at 10s. Through-Cloudflare requests succeed in 160ms.

## Bugs / findings during the cutover

Each documented in the updated runbook's "Known Gotchas" section (items 1-14):

1. `curl -sI ... | grep 'cf-ray'` sometimes silently misses headers.
2. CF API token permission wording is confusing (`Zone WAF:Edit` is separate from `Firewall Services:Edit`).
3. Free-tier rate limiting: 1 rule, `period=10`, `mitigation_timeout=10`. Requesting anything else fails with a specific error.
4. Free-tier Bot Fight Mode: dashboard-only.
5. Entry-point ruleset PUT rejects `kind`/`phase` fields (inferred from URL).
6. Managed ruleset IDs are 32-char UUIDs; the truncated 16-char preview isn't valid.
7. `aws secretsmanager describe-secret` can return "exists" for a non-existent secret in some SDK versions.
8. Cloudflare proxies WebSockets on Free/Pro (no plan gate).
9. `min_tls_version=1.2` rejects TLS 1.0/1.1 clients.
10. Cloudflare's edge IPs change rarely; no auto-sync from ConfigMap to Ingress annotation.
11. Turnstile widget isn't wired into the chart yet.
12. **`inbound-ipv6-cidrs` silently dropped on IPv4-only ALBs** — not a bug, no-op.
13. **Ingress annotations from HR values need force-reconcile** to propagate — helm-controller's value-hash skip.
14. **Two ALB SGs exist**; only the `frontend-sg` (name `k8s-llmsafes-...`) enforces inbound-cidrs. Filter by SG name pattern or absence of `elbv2.k8s.aws/resource=backend-sg` tag.

## Repository state

### `lenaxia/llmsafespaces-ops-prod`
- HEAD: `0743d9a` — enable ALB origin lock (Cloudflare edge IPs only)
- Also: `133257b` — rewrite CF cutover runbook to reflect API-driven cutover + new `scripts/cf-apply.sh` idempotent shell script for future re-applies.

### `lenaxia/llmsafespaces-aws-cdk`
- HEAD: `d856789` — terraform/cloudflare: document Free-tier caveats
- Terraform module remains as-designed for Pro plan; Free-tier caveats documented inline for the future.

## Live-cluster state (end of session)

| Path | Result |
|------|--------|
| Through Cloudflare | ✅ HTTP 200 |
| Through Cloudflare, PHP probe | ✅ HTTP 403 (WAF blocks) |
| Through Cloudflare, empty User-Agent | ✅ HTTP 403 (custom rule blocks) |
| Through Cloudflare, `/livez` with empty UA | ✅ HTTP 200 (rule exempts probes) |
| Through Cloudflare, 5 rapid `/api/v1/auth/login` POSTs | ✅ 5x 401, then 429 |
| Direct-to-ALB via DNS | ✅ Timeout after 10s |
| Direct-to-ALB via IP (52.10.54.196) | ✅ Timeout after 10s |
| Grafana subdomain | ⚠️ 404 (no chart ingress yet) |

Cluster + Cilium + monitoring all remain steady from session 3.

## Cloudflare zone config summary (for drift audits)

```
Zone: thekao.cloud (c96f67c85891ee8c0ee4c680b6d17a77)
Plan: Free
DNS:
  safespaces.thekao.cloud       CNAME → ALB (proxied)
  grafana.safespaces.thekao.cloud CNAME → ALB (proxied)
Settings:
  always_use_https: on
  min_tls_version: 1.2
  automatic_https_rewrites: on
  browser_check: on
  security_level: medium
  ssl: strict
Rulesets (entry points):
  http_request_firewall_managed: 1 execute rule (Cloudflare Managed Free Ruleset)
  http_request_firewall_custom: 3 rules (probe block, auth challenge, no-UA block)
  http_ratelimit: 1 rule (POST /api/v1/auth/login, 5 req/10s, 10s block)
```

To re-apply this config from any operator machine: `~/llmsafespaces-ops-prod/scripts/cf-apply.sh`. Idempotent.

## Operator action items remaining

1. **Bot Fight Mode**: Toggle manually in CF dashboard → Security → Bots. 30 seconds.

2. **vm-stack helm rollback fix** (from session 3 checkpoint, still open):
   ```bash
   kubectl -n monitoring delete hr victoria-metrics-k8s-stack
   flux reconcile kustomization cluster-monitoring-vmstack
   ```
   Unblocks loki, vector, falco reconciliation.

3. **Workspace FQDN egress enforcement** (chart-side): upstream PR to add `networkPolicy.workspaceEgress.enabled: false` toggle on the llmsafespaces chart so our Cilium CNP is the sole authority for workspace egress. Currently the chart's built-in NP unions `0.0.0.0/0` with our allowlist.

4. **Grafana ingress**: add an Ingress resource pointing at `victoria-metrics-k8s-stack-grafana` Service, using `alb.ingress.kubernetes.io/group.name: llmsafespaces` to share the existing ALB.

5. **Turnstile widget**: create via CF dashboard OR run the Terraform module (with the module fixed for Free-tier); then wire the site key into the frontend chart values (upstream chart PR).

## Resume command for a future session

```
Please resume from docs/worklogs/2026-07-02-session4-checkpoint.md in
llmsafespaces-ops-prod. Cloudflare cutover + origin lock are live.
Remaining work in priority order:
  1. vm-stack helm rollback fix (unblocks monitoring stack downstream).
  2. Workspace FQDN egress enforcement (upstream chart PR).
  3. Grafana ingress config.
  4. Bot Fight Mode manual toggle in CF dashboard.
  5. Turnstile widget for signup (chart PR).
```
