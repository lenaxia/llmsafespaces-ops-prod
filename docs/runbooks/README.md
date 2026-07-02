# Runbooks index

Each alert emitted by the observability stack should have a runbook here.
When an alert fires, the message includes a link to the corresponding runbook.

## Format

Each runbook follows the same structure:
- **Alert**: the exact `alertname`
- **Severity**: warning / critical
- **What it means**: the underlying condition being detected
- **Impact**: what breaks for users
- **First 60 seconds**: exact commands to run to diagnose
- **Common causes**: ordered by likelihood
- **Fix by cause**: exact commands to remediate each
- **Escalation**: if none of the above works

## Runbooks

### Infrastructure

- [KubePodNotReady](./kube-pod-not-ready.md) — a pod has been non-ready for >15min
- [KubeCPUOvercommit](./kube-cpu-overcommit.md) — cluster CPU requests exceed capacity
- [KubeDaemonSetRolloutStuck](./kube-daemonset-rollout-stuck.md) — a DaemonSet can't roll out
- [KubeJobFailed](./kube-job-failed.md) — a Job (usually pre-install hook) failed
- [KubeletTooManyPods](./kubelet-too-many-pods.md) — node is at pod IP capacity
- [NodeMemoryHigh](./node-memory-high.md)
- [NodeFilesystemAlmostOutOfSpace](./node-filesystem-almost-out-of-space.md)

### Data plane

- [rds-cpu-high](./rds-cpu-high.md) — RDS CPU >80% for 15min
- [rds-storage-low](./rds-storage-low.md) — RDS free storage <5GiB
- [rds-connections-high](./rds-connections-high.md) — RDS connections >70
- [valkey-memory-high](./valkey-memory-high.md) — Valkey memory >80%
- [valkey-evictions](./valkey-evictions.md) — Valkey evicting keys

### Application

- [llmsafespaces-api-error-rate](./llmsafespaces-api-error-rate.md)
- [llmsafespaces-workspace-stuck-creating](./llmsafespaces-workspace-stuck-creating.md)
- [llmsafespaces-controller-cm-watch-forbidden](./llmsafespaces-controller-cm-watch-forbidden.md)

### Security

- [falco-crypto-miner-detected](./falco-crypto-miner-detected.md) — Falco detected a crypto miner
- [falco-mining-pool-outbound](./falco-mining-pool-outbound.md)

### Meta (alerting itself)

- [alertmanager-not-firing](./alertmanager-not-firing.md) — Watchdog dead-man-switch
- [alertmanager-failed-to-send](./alertmanager-failed-to-send.md)

### Migrations (one-time, procedural)

- [Cilium CNI swap](./cilium-migration.md) — replace VPC CNI + kube-proxy with Cilium in ENI mode
- [DR RDS recovery](./dr-rds-recovery.md) — restore RDS from an automated snapshot; captures RTO measurement
