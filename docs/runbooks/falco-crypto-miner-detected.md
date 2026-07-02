# FalcoCryptoMinerDetected

**Severity**: critical
**Fires when**: Falco detected a process matching a crypto-miner binary name or known mining pool traffic pattern inside a workspace pod.
**Impact**: The workspace tenant is likely abusing our compute. Silent cost drain + reputational risk if any of that traffic hits abuse-listed IPs. Actionable within minutes.

## First 60 seconds

The alert includes:
- `workspace=<pod-name>`: which workspace pod
- `proc=<process-name>` (miner rule) or `dest=<host:port>` (network rule)
- `container=<container-id>`

Actions:

```bash
# 1. Identify the workspace + owner
WORKSPACE=<workspace-uuid>
kubectl -n llmsafespaces get workspace.llmsafespaces.dev $WORKSPACE -o jsonpath='{.spec.owner}{" "}{.spec.accountId}{"\n"}'

# 2. Kill the workspace immediately (users don't get to argue)
kubectl -n llmsafespaces delete workspace.llmsafespaces.dev $WORKSPACE

# 3. Suspend the account so they can't spin up another
# Requires chart admin API (upstream #492 tracks this)
# Manual until then:
kubectl -n llmsafespaces exec deploy/llmsafespaces-api -- \
  psql "postgres://..." -c "UPDATE accounts SET status = 'suspended', suspended_reason = 'Falco: crypto miner' WHERE id = '$ACCOUNT_ID';"
```

## Confirming vs false positive

Rare, but possible if a user is legitimately running a mining-adjacent tool (a Rust crate that happens to be named `cpuminer-clone`, or a legitimate proof-of-work library).

Confirm:
```bash
# Grab the full Falco event from Loki
# Filter by workspace name
kubectl -n monitoring port-forward svc/loki 3100:3100 &
curl -sG http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace="security"} |= "'$WORKSPACE'"' \
  --data-urlencode "start=$(date -u -d '15 minutes ago' +%s)000000000" \
  --data-urlencode "end=$(date -u +%s)000000000" \
  --data-urlencode "limit=20"
```

Look for the `cmdline` — a real miner will have `stratum+tcp://<pool>` or `--donate-level` or similar. False positive is a Rust binary running its own logic.

If false positive: whitelist by adding the process name to a Falco exception rule in `kubernetes/apps/security/falco/app/helm-release.yaml`.

## After the incident

1. Post to `#security-incidents` on Slack with the account ID, workspace UUID, and Falco event
2. Review the account's other workspaces for related activity
3. If widespread abuse (multi-account bot ring), consider Cloudflare rate limiting on the signup endpoint
4. Update abuse-prevention procedures if this is a new pattern
