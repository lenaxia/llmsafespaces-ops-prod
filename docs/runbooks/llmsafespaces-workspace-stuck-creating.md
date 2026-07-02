# WorkspaceStuckCreating

**Severity**: warning
**Fires when**: A `Workspace` CR has been in `phase: Creating` for >5 minutes.
**Impact**: User's UI shows "creating..." indefinitely. New workspaces can't start.

## First 60 seconds

```bash
WORKSPACE=<workspace-uuid>
kubectl -n llmsafespaces get workspace.llmsafespaces.dev $WORKSPACE -o yaml | head -40

# Look for the pod
kubectl -n llmsafespaces get pods -l llmsafespaces.dev/workspace=$WORKSPACE -o wide

# If pod exists, describe it
POD=$(kubectl -n llmsafespaces get pods -l llmsafespaces.dev/workspace=$WORKSPACE -o jsonpath='{.items[0].metadata.name}')
kubectl -n llmsafespaces describe pod $POD | tail -30
```

## Common causes

### 1. Node scheduling failure (too many pods, insufficient resources)
Same as [KubePodNotReady](./kube-pod-not-ready.md) case 1.

**Fix**: Scale node group or wait for spot capacity.

### 2. Image pull failure
Workspace base image (`ghcr.io/lenaxia/llmsafespaces/base:...`) not pulling.

**Fix**: Confirm image ref is current (see [CDK #10](https://github.com/lenaxia/llmsafespaces-aws-cdk/issues/10)). Refresh via `scripts/refresh-image-refs.sh`.

### 3. gVisor RuntimeClass unavailable on the node
The scheduled node doesn't have the `gvisor` RuntimeClass ready. `describe pod` shows `RuntimeClass "gvisor" not found`.

**Fix**: Check the gVisor installer DaemonSet:
```bash
kubectl -n gvisor-system get pods
```

If a pod is failing, check its logs for install errors. The installer marks `NodeCondition GvisorReady=True` when done:
```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{range .status.conditions[?(@.type=="GvisorReady")]}{.status}{"\n"}{end}{end}'
```

If a node shows `GvisorReady=False` (or missing), that node can't run workspace pods. Either fix the installer or cordon the node.

### 4. External-secrets not syncing
Workspace pods need the shared credentials Secret. Check:
```bash
kubectl -n llmsafespaces get secret llmsafespaces-credentials
kubectl -n llmsafespaces get externalsecret llmsafespaces-credentials
```

If ES status is not `Ready`, see [ExternalSecretSyncError](./external-secret-sync-error.md).

### 5. Controller not reconciling
The controller might be crash-looping or stuck.

```bash
kubectl -n llmsafespaces logs deploy/llmsafespaces-controller --tail=50
```

If crash-looping, see [llmsafespaces-controller](./llmsafespaces-controller-cm-watch-forbidden.md).

## Escalation

If workspace stays Creating for >30min with no clear cause:
- Delete the workspace CR (loses the session but frees the slot)
- Have the user retry
- File an issue with the pod's describe output + workspace CR yaml
