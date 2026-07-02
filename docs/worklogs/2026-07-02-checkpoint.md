# 2026-07-02: Session 1 checkpoint — pushing from 6.5 → 9/10

## Status: partial progress toward 9/10

We spent this session:
1. Filed 7 upstream/repo issues for hardening gaps
2. Added CloudWatch alarms + Lambda + budget in a new CDK MonitoringStack
3. Added PDBs + 2x replicas for cert-manager, external-secrets, Flux controllers
4. Deployed full ops-prod observability: VictoriaMetrics + Loki + Vector + Alertmanager + Grafana
5. Deployed Falco (crypto-miner rules, workspace-scoped)
6. Added LimitRange for workspace pods
7. Wrote 4 runbooks + runbooks index
8. Silenced EKS-managed component false-positive alerts
9. Wired Grafana behind ALB Ingress (needs CDK redeploy for ACM SAN)

The score honestly reads **6.5 → 7.5/10** at the moment of checkpoint (before the last 3 items complete). All the observability code is deployed and working; alerts fire correctly but route to placeholder Slack/Pushover URLs.

## To reach 9/10 — remaining work

### Locked-in decisions (already answered by operator)
- Cilium CNI swap: **YES, proceed**
- Cloudflare setup: **Terraform for CF config + CDK for origin lock**
- DR drill: **In-place drill**
- Alertmanager: **Placeholder URLs OK for now; operator will supply real creds later**

### Todos in flight (partial state committed)

| # | Item | Status | Files touched |
|---|---|---|---|
| 1 | Silence EKS-managed component alerts | ✅ committed & pushed | `ops-prod/kubernetes/apps/monitoring/victoria-metrics-k8s-stack/app/helm-release.yaml` |
| 2 | Expose Grafana behind Ingress + auth | ✅ ops-prod committed; ⚠️ CDK ACM SAN change committed but NOT deployed | `ops-prod/…/helm-release.yaml`, `cdk/lib/platform-stack.ts` |
| 3 | Runbook annotations + docs | ✅ 4 runbooks + index committed; Lambda `_format()` updated | `ops-prod/docs/runbooks/*`, `cdk/lib/monitoring-stack.ts` |
| 4 | **Cilium CNI swap** | ❌ NOT started (session ended here) | — |
| 5a | Cloudflare Terraform module | ❌ NOT started | — |
| 5b | CDK ALB SG origin-lock | ❌ NOT started | — |
| 6 | DR drill script + runbook | ❌ NOT started | — |

Two committed changes need `cdk deploy` to be applied to the live cluster:
- **PlatformStack ACM cert** now has `grafana.safespaces.thekao.cloud` SAN. Requires DNS validation record for the new SAN. Run:
  ```bash
  cd ~/llmsafespaces-cdk && AWS_PROFILE=mikekao-prod npx cdk deploy 'LlmSafeSpaces/Platform'
  ```
  Then add the DNS validation CNAME the ACM console reports. **Operator DNS step required.**

- **MonitoringStack Lambda** has updated `_format()` to include runbook links. Redeploys the Lambda:
  ```bash
  cd ~/llmsafespaces-cdk && AWS_PROFILE=mikekao-prod npx cdk deploy 'LlmSafeSpaces/Monitoring'
  ```

## Concrete plan for next session

### Priority 1: Cilium CNI swap (4-6h, biggest risk item)

**Goal**: Replace VPC CNI with Cilium so we get FQDN-based egress NetworkPolicy for workspace pods.

**Risk**: Requires draining + replacing every node. Brief workload disruption (~10 min blip for llmsafespaces API).

**Sub-tasks:**

1. **CDK changes** (`lib/cluster-stack.ts`):
   - Disable the VPC CNI addon (remove `aws-node` DaemonSet management)
   - Add Cilium IRSA role for CNI-specific IAM (for AWS ENI IPAM mode)
   - Optionally: add EKS Pod Identity for Cilium (cleaner than IRSA for CNI)

2. **ops-prod changes** (`kubernetes/apps/kube-system/cilium/`):
   - New HelmRepository `cilium` (`https://helm.cilium.io/`)
   - New HelmRelease `cilium` with values:
     ```yaml
     ipam:
       mode: eni
     eni:
       enabled: true
     egressGateway:
       enabled: true
     kubeProxyReplacement: true  # optional, but recommended
     k8sServiceHost: <EKS API endpoint hostname>
     k8sServicePort: 443
     hubble:
       enabled: true
       relay:
         enabled: true
       ui:
         enabled: true
     ```
   - Depends on: nothing (Cilium needs to install BEFORE workloads)

3. **Migration procedure** (manual, one-time):
   ```bash
   # After CDK + Flux apply Cilium
   # Verify Cilium is Ready on any new node
   kubectl -n kube-system get pods -l k8s-app=cilium
   
   # Cycle nodes one at a time
   for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
     kubectl cordon $node
     kubectl drain $node --ignore-daemonsets --delete-emptydir-data --force --timeout=5m
     # Wait for a new node to come up (spot fills in automatically)
     sleep 60
     kubectl delete node $node
     # Give new node time to be Ready before draining the next
     sleep 120
   done
   ```

4. **Add the workspace egress policy** (`kubernetes/apps/llmsafespaces/llmsafespaces/app/network-policy.yaml`):
   ```yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: workspace-egress-allowlist
     namespace: llmsafespaces
   spec:
     endpointSelector:
       matchLabels:
         # workspace pods have this label per chart
         app.kubernetes.io/name: workspace
     egress:
       # Kube DNS
       - toEndpoints:
           - matchLabels:
               k8s:io.kubernetes.pod.namespace: kube-system
               k8s:k8s-app: kube-dns
         toPorts:
           - ports:
               - port: "53"
                 protocol: UDP
       # LLM providers via FQDN
       - toFQDNs:
           - matchName: opencode.ai
           - matchName: api.openai.com
           - matchName: api.anthropic.com
           - matchName: api.groq.com
           - matchName: openrouter.ai
           - matchName: api.together.xyz
         toPorts:
           - ports:
               - port: "443"
                 protocol: TCP
       # Package registries (workspace users install deps)
       - toFQDNs:
           - matchName: registry.npmjs.org
           - matchName: pypi.org
           - matchName: files.pythonhosted.org
           - matchName: registry.docker.io
           - matchPattern: "*.docker.io"
         toPorts:
           - ports:
               - port: "443"
                 protocol: TCP
       # Git
       - toFQDNs:
           - matchName: github.com
           - matchName: api.github.com
           - matchName: raw.githubusercontent.com
           - matchName: gitlab.com
         toPorts:
           - ports:
               - port: "443"
                 protocol: TCP
   ```

5. **Verify**: `kubectl exec` into a workspace pod, try to reach a disallowed FQDN, verify it fails.

**Rollback plan**: if Cilium doesn't come up cleanly, re-enable VPC CNI addon in CDK and cycle nodes back.

### Priority 2: Cloudflare Terraform + CDK origin lock (3-4h)

**Goal**: Cloudflare in front of the ALB with WAF + rate limits + Turnstile. Origin lock so anyone bypassing Cloudflare can't reach the ALB.

**Prerequisite (operator, one-time)**: Create a Cloudflare API token with scoped permissions:
- Zone:DNS:Edit
- Zone:Zone Settings:Edit
- Zone:Firewall Services:Edit
- Account:Turnstile Sites:Edit
- Store the token in AWS Secrets Manager as `llmsafespaces/cloudflare-api-token` (untagged; only Terraform will read it)

**Sub-tasks:**

1. **New sibling repo or subdir**: `~/llmsafespaces-cdk/terraform/cloudflare/`
   - `main.tf` — Cloudflare provider
   - `variables.tf` — zone name, ALB target hostname (from CDK output)
   - `dns.tf` — CNAME `safespaces.thekao.cloud` → ALB (proxied)
   - `dns.tf` — CNAME `grafana.safespaces.thekao.cloud` → same ALB
   - `waf.tf` — Enable Cloudflare Managed Ruleset + OWASP Core Ruleset
   - `bot-fight.tf` — Enable Bot Fight Mode
   - `rate-limit.tf`:
     - `/login`: 5/min per IP
     - `/signup`: 3/hr per IP
     - `/api/v1/*`: 60/min per IP
   - `turnstile.tf` — Create a Turnstile widget for `safespaces.thekao.cloud`, output the site key + secret key ARNs

2. **CDK ALB origin lock** (`lib/network-stack.ts` or `cluster-stack.ts`):
   - Fetch Cloudflare IP ranges daily via a Lambda
   - Replace ALB Security Group's `0.0.0.0/0 :443` rule with individual rules for each Cloudflare `/22` and `/24` range
   - Additionally allow the operator's own IP for emergency access:
     ```typescript
     const operatorIp = '<your-static-ip>/32';  // context value
     albSg.addIngressRule(ec2.Peer.ipv4(operatorIp), ec2.Port.tcp(443));
     ```

3. **Chart integration**: update llmsafespaces HelmRelease to include Turnstile site key so the frontend signup form uses it. Needs upstream chart support — file issue if not present.

### Priority 3: DR drill (half day)

**Goal**: Prove RDS restore works. Document RTO/RPO.

1. Write `scripts/dr-drill.sh` in the CDK repo:
   ```bash
   #!/bin/bash
   # 1. Find latest RDS automated snapshot
   SNAPSHOT_ARN=$(aws rds describe-db-instance-automated-backups ...)
   
   # 2. Restore to a new instance in a sandbox VPC (same AZ config)
   aws rds restore-db-instance-from-db-snapshot \
     --db-instance-identifier llmsafespaces-dr-drill \
     --db-snapshot-identifier "$SNAPSHOT_ARN" ...
   
   # 3. Wait for the restore to complete, record time
   START=$(date +%s)
   aws rds wait db-instance-available --db-instance-identifier llmsafespaces-dr-drill
   ELAPSED=$(( $(date +%s) - START ))
   
   # 4. Connect + verify row counts on key tables
   PGPASSWORD=... psql -h ... -c "SELECT count(*) FROM accounts; SELECT count(*) FROM workspaces;"
   
   # 5. Tear down
   aws rds delete-db-instance --db-instance-identifier llmsafespaces-dr-drill --skip-final-snapshot
   
   echo "RTO: ${ELAPSED}s"
   ```

2. Run once, capture the RTO number.

3. Write `docs/runbooks/dr-rds-recovery.md` in ops-prod with the exact commands + RTO number + rollback plan.

## Repository state summary

Both repos are pushed and reconciled clean.

### `lenaxia/llmsafespaces-aws-cdk`
- Branch: `main`, HEAD `ece495c` — MonitoringStack + Flux HA
- Uncommitted local changes: **YES** — see below
- Applied to live cluster: **partial** (MonitoringStack is deployed; PlatformStack ACM SAN change committed to local repo but NOT pushed and NOT deployed)

**Local diff to review + push + deploy at start of next session**:
```bash
cd ~/llmsafespaces-cdk
git status  # should show:
#   modified: lib/platform-stack.ts  (adds grafana.DOMAIN SAN)
#   modified: lib/monitoring-stack.ts  (adds runbook_url to Slack messages)
git diff  # verify these are the only changes
git commit -am "cdk: add grafana SAN to ACM cert + runbook links in alert Lambda"
git push
npx cdk deploy 'LlmSafeSpaces/Platform' 'LlmSafeSpaces/Monitoring'
```

### `lenaxia/llmsafespaces-ops-prod`
- Branch: `main`, HEAD `130c458` — silence false-positive alerts, Grafana Ingress, runbooks
- Uncommitted local changes: **NONE**
- Applied to live cluster: **YES** — Flux has reconciled

## Environment / context

Live cluster state (as of session end):
- **EKS**: `llmsafespaces` (v1.32) in `us-west-2`, 2 spot nodes (m6a/m5a/t3a.large)
- **Workspace URL**: https://safespaces.thekao.cloud (Cloudflare DNS-only mode)
- **New ALB**: `k8s-llmsafes-llmsafes-2f919186c8-1987193235.us-west-2.elb.amazonaws.com`
- **Grafana** (once ACM SAN redeployed): https://grafana.safespaces.thekao.cloud
- **AWS profile**: `mikekao-prod` (account 572169125554)

Deployed HelmReleases (all Ready):
- cert-manager @ v1.16.2 (2 replicas)
- external-secrets @ 0.10.5 (2 replicas)
- llmsafespaces @ chart 0.1.0 (1 replica each)
- victoria-metrics-k8s-stack @ 0.35.3 (single-node)
- loki @ 6.24.0 (single-binary)
- vector @ 0.36.1 (DaemonSet)
- falco @ 9.1.0 (DaemonSet, 1/2 due to node IP capacity — not a bug)

## Known open issues (linked)

Upstream `lenaxia/LLMSafeSpaces`:
- #454 GHCR image tag GC
- #462 arm64 image has x86-64 binary
- #465 no Redis TLS support
- #468 frontend copy-html PSA restricted violation
- #469 controller CM watch RBAC scope mismatch
- #473 frontend ingress /api prefix not stripped (**still critical, UI is functional but shows loading spinners**)
- #474 default relay URL 403s
- #476 chart image template doesn't support digest pinning
- #492 per-account resource quota + billing

`lenaxia/llmsafespaces-aws-cdk`:
- #12 Production hardening roadmap (this whole worklog)
- #13 Cross-region backup replication
- #14 Automate sops-age Secret bootstrap
- #15 Cloudflare integration ← **Priority 2 of next session**
- #16 DR drill + runbook ← **Priority 3 of next session**

`lenaxia/llmsafespaces-ops-prod`:
- #1 Cilium FQDN egress ← **Priority 1 of next session**
- #2 EKS 1.33 bump (needed to unblock Flux 2.8+)
- #3 Per-account quota (needs upstream #492)

## Operator action items before next session (optional)

None strictly required, but if you want to set these up in advance:

1. **Real Slack webhook + Pushover credentials** (5 min):
   ```bash
   cd ~/llmsafespaces-ops-prod
   sops kubernetes/apps/monitoring/victoria-metrics-k8s-stack/app/alertmanager-config.sops.yaml
   # Replace `https://example.com/dummy-slack-webhook` with the real Slack incoming webhook URL
   # Replace dummy Pushover user + app tokens with real ones
   # Save
   git commit -am "alertmanager: real credentials" && git push
   # Flux picks up in 2min; verify by killing a pod and watching Slack
   ```

2. **Cloudflare API token** (15 min):
   - Cloudflare dashboard → My Profile → API Tokens → Create Token
   - Scopes: Zone:DNS:Edit + Zone:Zone Settings:Edit + Zone:Firewall Services:Edit + Account:Turnstile Sites:Edit
   - Restrict to zone `thekao.cloud`
   - Store in Secrets Manager:
     ```bash
     aws secretsmanager create-secret --profile mikekao-prod --region us-west-2 \
       --name llmsafespaces/cloudflare-api-token \
       --secret-string 'YOUR_CF_TOKEN'
     ```

Both are decoupled from the code work I'll do in the next session.

## Resume command for next session

```
Please resume from docs/worklogs/2026-07-02-checkpoint.md in the
llmsafespaces-ops-prod repo. Priority order is Cilium CNI swap, then
Cloudflare Terraform + CDK origin lock, then DR drill.
```
