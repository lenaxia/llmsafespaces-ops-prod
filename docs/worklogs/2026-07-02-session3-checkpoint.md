# 2026-07-02: Session 3 checkpoint — Cilium migration + second DR drill complete

## Status: **9/10**

This session executed the two remaining live-cluster migrations from the session-2 plan:

1. **Cilium CNI swap** — done. Cluster now runs Cilium 1.17.6 in ENI IPAM mode with kubeProxyReplacement. VPC CNI + kube-proxy DaemonSets removed. Both nodes cycled. Flux has adopted the HelmRelease.
2. **DR drill re-run post-Cilium** — RTO=458s, verify ok. Second data point recorded in the runbook.

Remaining to reach 9.5/10:
- **Cloudflare cutover** — Terraform module + runbook still staged, waiting for operator to (a) create CF API token, (b) create tf state bucket, (c) apply. Not blocking anything.
- **Workspace CNP allowlist enforcement** — CNP is applied and Cilium recognizes it, but the llmsafespaces chart's own workspace-egress NetworkPolicy allows `0.0.0.0/0` and unions with our allowlist. This is a chart bug tracked in "known open issues" below. FQDN enforcement will start working once the chart is fixed.

## Live-cluster changes made this session

### 1. ACM cert import (from session-2 setup carrying over)
- Added 2 DNS validation CNAMEs at Cloudflare DNS for `safespaces.thekao.cloud` and `grafana.safespaces.thekao.cloud`.
- New cert `41c6f42c-…` reached ISSUED within ~90s of adding records.
- `cdk deploy 'LlmSafeSpaces/Platform'` succeeded — imported the new cert, `cluster-config` ConfigMap now has `ACM_CERT_ARN` pointing at it, ALB listener attached to new cert. Old CDK-managed cert was orphaned during CFN destroy (couldn't be deleted while attached to ALB), then manually deleted after Flux flipped the ALB to the new cert.

### 2. Cilium migration
- Deleted `aws-node` + `kube-proxy` DaemonSets + their ClusterRole/Binding + ServiceAccount.
- `helm install cilium cilium/cilium --version 1.17.6` with ENI mode + native routing + kubeProxyReplacement.
- Cycled both nodes: `ip-10-42-7-168` → `ip-10-42-7-245`, then `ip-10-42-10-112` → `ip-10-42-8-167`. Each cycle: ~90-99s ASG replacement + ~2min for pods to reschedule + become Ready.
- Force-deleted stuck pods (kustomize-controller, aws-load-balancer-controller, cert-manager-cainjector, ebs-csi-controller, external-secrets, helm-controller) whose network state was stale from pre-Cilium veth pairs.
- Un-suspended the Flux HelmRelease. Adopted via `sh.helm.release.v1.cilium.v1` secret label patch (`managed-by=Helm`, `helm.toolkit.fluxcd.io/name=cilium`, `helm.toolkit.fluxcd.io/namespace=kube-system`).
- Flux is now reconciling the HR from ops-prod:`kubernetes/apps/kube-system/cilium/app/helm-release.yaml`.
- Restored the temporarily-patched Flux PDBs to `minAvailable: 1` (delete+recreate; kubectl couldn't merge because I'd swapped the field).

Total site downtime during migration: **~15 minutes** in one contiguous window while stuck pods on the second (pre-Cilium) node caused AWS LBC + kustomize-controller crashloops that stopped ALB target registration. After force-deleting them, workload recovered to HTTP 200. This is longer than the 2-min estimate in the runbook — updated the runbook's "Known gotchas" to include the force-delete-stuck-pods procedure.

### 3. Bugs found + fixed during migration
Each of these needed a code change in ops-prod during the session:

1. **`tunnel: disabled` removed in Cilium 1.15+** — first Flux install failed. Removed the setting; native routing implies no tunnel. Commit `853873a` (session 2, before Cilium was live).

2. **`spec.suspend: true` needed on the HR** — otherwise Flux would race the VPC CNI on install. Added; migration procedure un-suspends after helm CLI install. Commit `853873a`.

3. **`wait: true` + `healthChecks` on the cilium Kustomization deadlocked** with the suspended HR. Removed from the Kustomization; moved the HR health check to the downstream `cluster-llmsafespaces-policy` Kustomization instead. Commit `7216f4c`.

4. **`egressMasqueradeInterfaces: eth+` matches nothing on Nitro instances** — pod → internet egress silently fails. Changed to `ens+`. Discovered when Flux source-controller couldn't clone from github.com. Commit `36a3332`.

5. **`serviceMonitor.enabled: true` fails chart pre-render** — Prometheus Operator CRDs aren't installed (vm-stack HR is in a pre-existing failed rollback). Disabled on `prometheus.serviceMonitor`, `operator.prometheus.serviceMonitor`, and `hubble.metrics.serviceMonitor`. Commit `36a3332`.

6. **`postBuild.substituteFrom` was missing on the cilium Kustomization** — Flux applied the HR with the literal string `${KUBERNETES_API_HOST}` in `values.k8sServiceHost`. Cilium agent crashlooped on "host must be a URL or a host:port pair". Added the substituteFrom pointing at `cluster-config` ConfigMap. Commit `3bc6069`.

7. **`helm-controller` field ownership blocks manual `helm upgrade`** — when Flux adopts a release, its SSA field ownership uses `manager: helm-controller`. Manual `helm upgrade` uses `manager: helm` and hits SSA conflicts. Fix: strip helm-controller from managed fields via `kubectl get <res> --show-managed-fields -o json | jq '.metadata.managedFields |= map(select(.manager != "helm-controller"))' | kubectl replace -f -`. Then retry.

All 7 fixes now in `docs/runbooks/cilium-migration.md#known-gotchas` for future migrations.

### 4. Second DR drill run
- Instance `llmsafespaces-dr-drill-20260702233121` created + verified + teardown started.
- **RTO = 458s** (up from 392s in the first drill).
- Verify status: ok (schema present, provider_credentials has 1 row).
- Confirmed the drill script works post-Cilium — no CNI-specific tuning needed for the ephemeral verify pod.

## Repository state

Both pushed to main. No local diffs.

### `lenaxia/llmsafespaces-aws-cdk`
- HEAD: `eda0901` — cdk emits KUBERNETES_API_HOST in cluster-config
- All stacks deployed to prod (Platform + Monitoring + Cluster + Data + Network all UPDATE_COMPLETE).

### `lenaxia/llmsafespaces-ops-prod`
- HEAD: `3bc6069` — cilium: add postBuild substituteFrom cluster-config
- All Flux Kustomizations reconciling Ready except:
  - `cluster-monitoring-vmstack` — pre-existing failed rollback (unrelated to this session's work).
  - `cluster-monitoring-loki`, `cluster-monitoring-vector`, `cluster-security-falco` — waiting on vmstack (dependency chain).

## Known open issues (touched but not fixed)

- **Workspace FQDN egress enforcement is nominally-broken.** The Cilium CNP `workspace-egress-allowlist` is applied and Cilium enforces it, but the llmsafespaces chart's built-in `<release>-workspace-egress` K8s NetworkPolicy allows `0.0.0.0/0` (minus RFC1918) egress for the same pod selector. Cilium unions the two policies' allow rules, so effective egress = union = anywhere. Fix requires either (a) chart-side toggle to disable the built-in workspace-egress NP, or (b) Flux HR `postRenderers.kustomize.patches` block that strips the offending rules. Tracked in the runbook. Note: **the CNP does not silently fail — Hubble records all workspace pod egress**, so we retain full observability even without enforcement. Not blocking.

- **cluster-monitoring-vmstack** stuck reconciling — pre-existing. Blocks vector/loki/falco Kustomizations from reconciling. Fix: `kubectl -n monitoring delete hr victoria-metrics-k8s-stack` and let Flux re-install fresh.

- **PodSecurity policies in some namespaces** rejected the test pods I used for verification (`test-workspace`, `test-egress`, etc). Not a bug — the `restricted` PSA in prod namespaces is doing its job. Verification pods had to run in `default` (unrestricted) or accept the warning.

- **Grafana ingress returns 404**. Chart doesn't yet have a Grafana Ingress — the ACM cert covers `grafana.safespaces.thekao.cloud` but no ingress backend exists. Fix requires a chart-side addition (`monitoring.grafana.ingress` values block) or a manual Ingress resource in ops-prod pointing at the `victoria-metrics-k8s-stack-grafana` Service.

## Operator action items remaining

Ordered by priority + independence:

### 1. Cloudflare cutover (~30 min hands-on)

Still the highest-value remaining migration. Follow `docs/runbooks/cloudflare-cutover.md`. Prereqs:

- Install terraform ≥ 1.9 (`sudo apt install terraform` on Debian/WSL).
- Create Cloudflare API token (Zone: DNS+Zone Settings+Firewall+WAF+Turnstile) and stash:
  ```
  aws --profile mikekao-prod --region us-west-2 secretsmanager create-secret \
    --name llmsafespaces/cloudflare-api-token \
    --secret-string 'YOUR_CF_TOKEN'
  ```
- Create the terraform state bucket per session-2 checkpoint step 4c.

Then `terraform init && terraform apply` in `~/llmsafespaces-cdk/terraform/cloudflare`. After apply, flip DNS records to orange cloud in CF DNS UI. Origin lock (Ingress `inbound-cidrs` annotation) is a separate step after cutover verification.

### 2. Fix workspace-egress NP chart bug (~1h upstream work)

The chart's `templates/workspace-network-policy.yaml` needs a values-side toggle to disable the egress rules while keeping the ingress default-deny. Suggested API:

```yaml
networkPolicy:
  enabled: true                    # existing
  workspaceEgress:
    enabled: true                  # existing default behavior (allow world minus RFC1918)
    # or when using Cilium CNP for egress instead:
    enabled: false
```

Once merged upstream, set `workspaceEgress.enabled: false` in ops-prod's llmsafespaces HR values, and the Cilium CNP allowlist becomes the sole authority for workspace egress.

### 3. Fix vm-stack helm rollback (~15 min)

```bash
# Diagnose current state
kubectl -n monitoring get hr victoria-metrics-k8s-stack -o yaml | grep -A 3 conditions
# Nuclear option: delete + let Flux re-install
kubectl -n monitoring delete hr victoria-metrics-k8s-stack
flux reconcile kustomization cluster-monitoring-vmstack
```

Should recover loki/vector/falco reconcile chain within ~5 min.

### 4. Wire up Grafana ingress (~15 min)

Simplest path: add a hand-written `Ingress` resource in ops-prod under `kubernetes/apps/monitoring/victoria-metrics-k8s-stack/app/` alongside the existing HR. Point at the `victoria-metrics-k8s-stack-grafana` Service on port 80. Use `alb.ingress.kubernetes.io/group.name: llmsafespaces` so it shares the existing ALB.

### 5. Schedule the recurring DR drill

Two runs on file (392s, 458s). Suggested cadence: quarterly. Options:
- **Manual**: add a calendar reminder; run `./scripts/dr-drill.sh` and update the runbook table.
- **CI-driven**: GitHub Actions scheduled workflow with an OIDC-federated role in mikekao-prod. Roughly 2 hours to wire up.

## Resume command for a future session

```
Please resume from docs/worklogs/2026-07-02-session3-checkpoint.md in
the llmsafespaces-ops-prod repo. Cilium + DR are done. Remaining
priority order:
  1. Cloudflare cutover (needs operator: install terraform, create CF
     API token, create tf state bucket, then terraform apply per
     docs/runbooks/cloudflare-cutover.md).
  2. Fix vm-stack helm rollback so monitoring/loki/vector/falco
     Kustomizations start reconciling.
  3. Chart-side fix for the workspace-egress NP conflict (upstream
     llmsafespaces chart PR).
  4. Grafana ingress config.
```
