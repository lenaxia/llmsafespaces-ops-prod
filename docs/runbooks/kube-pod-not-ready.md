# KubePodNotReady

**Severity**: warning
**Fires when**: A pod has been in a non-Ready state for more than 15 minutes.
**Impact**: Depends on the pod. Critical if it's `llmsafespaces-api/controller/frontend`; medium if it's a subordinate like `falco`; low if it's a batch job.

## First 60 seconds

```bash
# 1. Identify the pod from the alert labels
POD=<pod-from-alert>
NS=<namespace-from-alert>

# 2. Get its current state
kubectl -n $NS get pod $POD
kubectl -n $NS describe pod $POD | tail -30

# 3. Get its logs
kubectl -n $NS logs $POD --tail=50
kubectl -n $NS logs $POD --tail=50 --previous  # if it's crash-looping
```

## Common causes (ordered by likelihood)

### 1. Node IP capacity exhausted (`Too many pods`)
`kubectl describe pod` shows `FailedScheduling: 0/N nodes are available: N Too many pods`.

**Cause**: VPC CNI allocates a limited number of ENI IPs per instance. m6a.large caps at ~29-35 pods.

**Fix**:
```bash
# Force node group to scale up
NG=$(aws eks list-nodegroups --cluster-name llmsafespaces --region us-west-2 --query 'nodegroups[0]' --output text)
aws eks update-nodegroup-config --cluster-name llmsafespaces --nodegroup-name "$NG" \
  --region us-west-2 --scaling-config desiredSize=3
```

Or migrate to Cilium CNI (which has better IPAM density) — see [ops-prod #1](https://github.com/lenaxia/llmsafespaces-ops-prod/issues/1).

### 2. CrashLoopBackOff — bad image or config
`describe pod` shows `Back-off restarting failed container`. Logs will show why.

**Fix**: Depends on what the logs say. Common: missing env var, missing Secret, misconfigured URL, kernel-arch mismatch.

### 3. ImagePullBackOff — bad image ref
`describe pod` shows `Failed to pull image` or `ErrImagePull`.

**Fix**:
```bash
# Verify the image ref is valid
kubectl -n $NS get pod $POD -o jsonpath='{.spec.containers[0].image}'
# Try pulling from a debug pod:
kubectl run test --rm -i --restart=Never --image=<the-image> -- true
```

If the image was GC'd (llmsafespaces#454), bump via `scripts/refresh-image-refs.sh` in the CDK repo.

### 4. Init container failure
`describe pod` shows `Init:0/N` state. Logs of the init container:
```bash
kubectl -n $NS logs $POD -c <init-container-name>
```

### 5. Readiness/Liveness probe failing
`describe pod` shows `Readiness probe failed`. Usually means the app started but isn't responding to `/livez` or similar. Check the app logs for what's wrong.

## If none of the above

Escalate to platform on-call. Include:
- `kubectl -n $NS describe pod $POD` output
- Last 200 lines of logs
- Node the pod was on (check for node-level issues)
