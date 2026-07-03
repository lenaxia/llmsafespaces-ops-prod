# Migration: Cilium CNI swap

**Type**: One-time cluster migration.
**Estimated duration**: 30-45 minutes wall-clock.
**Blast radius**: brief pod-network outage (~2-4 minutes per node while it's cycled); total workload interruption depends on replica count. On the current MVP tier (1 replica of each app pod, 2 nodes) expect a ~2min blip in `safespaces.thekao.cloud` availability while the API pod is rescheduled onto a fresh node.
**Rollback**: possible up until Cilium is scheduled on a live workload node; after that it's a re-migration back to VPC CNI (same procedure, opposite direction).
**Prerequisites**: `kubectl` context = `llmsafespaces`, `helm` v3, `AWS_PROFILE=mikekao-prod`, Cilium CLI (optional but recommended: <https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/#install-the-cilium-cli>).

## Why we're doing this

The default EKS CNI (aws-node / VPC CNI) has no support for FQDN-based egress NetworkPolicies. Workspace pods run untrusted user-supplied agent code. Without FQDN egress control, a compromised workspace can egress to any internet host the VPC route table permits (i.e. anything).

Cilium in ENI mode gives us:
- FQDN egress allowlist enforced by an in-pod DNS proxy + eBPF datapath. See `kubernetes/apps/llmsafespaces/llmsafespaces/policy/workspace-egress.yaml`.
- Hubble flow observability (already scraped into VictoriaMetrics).
- kube-proxy replacement: eBPF service load balancing, no iptables sync cost.
- Same VPC-native networking (native routing, no overlay overhead) as VPC CNI.

## What's already in-repo, waiting to activate

- `kubernetes/apps/kube-system/cilium/app/helm-release.yaml` — the Cilium HelmRelease (chart 1.17.6, ENI mode, `kubeProxyReplacement: true`).
- `kubernetes/apps/kube-system/cilium/ks.yaml` — the Flux Kustomization that reconciles it.
- `kubernetes/apps/llmsafespaces/llmsafespaces/policy/workspace-egress.yaml` — the FQDN allowlist CNP.
- `kubernetes/flux/repositories/helm/cilium.yaml` — HelmRepository pointing at helm.cilium.io.

All are wired into their parent kustomization.yaml files. If you `git push` these unchanged onto a cluster still running VPC CNI, Flux will fail to install Cilium — specifically, Cilium and VPC CNI will conflict on `/etc/cni/net.d/` config and one of them (whichever loses the race) will be non-functional. **Do not merge the ops-prod cilium branch to main until you've followed step 3 below.**

## Step 1 — Preflight (5 min, no downtime)

Verify current state:

```bash
kubectl -n kube-system get ds aws-node kube-proxy -o wide
# Both should be 2/2 running.

kubectl get nodes -L topology.kubernetes.io/zone -L node.kubernetes.io/instance-type
# Should be 2 nodes, both Ready.

# Confirm cluster-config has KUBERNETES_API_HOST (needed by Cilium
# HelmRelease values). If empty, patch it first:
kubectl -n flux-system get cm cluster-config -o jsonpath='{.data.KUBERNETES_API_HOST}'
# Expected: something like `<hex>.<slug>.us-west-2.eks.amazonaws.com`
# If empty:
API_HOST=$(aws eks describe-cluster --profile mikekao-prod --region us-west-2 \
  --name llmsafespaces --query 'cluster.endpoint' --output text | sed 's|https://||')
kubectl -n flux-system patch cm cluster-config --type=merge \
  -p "{\"data\":{\"KUBERNETES_API_HOST\":\"$API_HOST\"}}"
# On the next CDK deploy of PlatformStack this field becomes CDK-owned;
# no further manual patch needed.

# Sanity-check that Flux is healthy (no in-flight reconciles that
# might race the migration).
flux get all -A --status-selector ready=false
# Should show 0 rows.
```

## Step 2 — Delete the conflicting default add-ons (30 seconds; downtime starts)

The moment you delete `aws-node`, existing pods keep running (their veth pairs are already set up) but new pod scheduling breaks until Cilium is up. Do this AND install Cilium quickly.

```bash
# Delete kube-proxy (Cilium will replace it via kubeProxyReplacement).
kubectl -n kube-system delete ds kube-proxy

# Delete aws-node (VPC CNI). Existing pods keep running.
kubectl -n kube-system delete ds aws-node

# Also delete the associated ClusterRole/Binding — they'd conflict with
# Cilium's SA permissions.
kubectl delete clusterrole aws-node --ignore-not-found
kubectl delete clusterrolebinding aws-node --ignore-not-found

# ...and the SA. Cilium creates its own.
kubectl -n kube-system delete sa aws-node --ignore-not-found
```

Do NOT delete the CNI config file on the nodes manually — the Cilium install container handles that when it lands.

## Step 3 — Install Cilium via helm (bootstrap, ~3 min)

We install Cilium directly with helm BEFORE letting Flux take over. This avoids a chicken-and-egg where Flux (which relies on the pod network) needs Cilium up but Cilium needs to be installed first. After the bootstrap, Flux adopts the release via the HelmRelease that's already in the ops-prod repo.

```bash
# The values here MUST match kubernetes/apps/kube-system/cilium/app/helm-release.yaml
# in ops-prod. Diffs will be reconciled to the ops-prod version once
# Flux takes over on the next reconcile.

API_HOST=$(aws eks describe-cluster --profile mikekao-prod --region us-west-2 \
  --name llmsafespaces --query 'cluster.endpoint' --output text | sed 's|https://||')

helm repo add cilium https://helm.cilium.io/
helm repo update

helm install cilium cilium/cilium --version 1.17.6 \
  --namespace kube-system \
  --set cluster.name=llmsafespaces \
  --set cluster.id=1 \
  --set ipam.mode=eni \
  --set eni.enabled=true \
  --set eni.awsReleaseExcessIPs=true \
  --set routingMode=native \
  --set egressMasqueradeInterfaces=ens+ \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=$API_HOST \
  --set k8sServicePort=443 \
  --set operator.replicas=2 \
  --set operator.rollOutPods=true \
  --set operator.podAntiAffinity=hard \
  --set rollOutCiliumPods=true \
  --set priorityClassName=system-node-critical \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set encryption.enabled=false

# Watch cilium-agent DaemonSet come up.
kubectl -n kube-system rollout status ds/cilium --timeout=5m
```

## Step 4 — Cycle nodes (~10 min, brief workload disruption)

Existing pods on the old nodes still have veth pairs configured by the (now-deleted) VPC CNI. Their CNI-observed identity is stale. Cycling nodes forces new pods to be scheduled with Cilium-owned ENIs.

```bash
# Cordon both nodes so replacement nodes come up before we drain.
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  kubectl cordon "$node"
done

# Delete node objects one at a time. EC2-scale AutoScalingGroup will
# replace instances that are unregistered.
NODES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
for node in $NODES; do
  echo "=== Draining $node ==="
  kubectl drain "$node" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --force \
    --timeout=5m || echo "drain hit timeout, continuing anyway"

  echo "=== Deleting $node (triggers ASG replacement) ==="
  # Find the EC2 instance ID from the node's spec.providerID
  INSTANCE_ID=$(kubectl get node "$node" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}')
  aws ec2 terminate-instances --profile mikekao-prod --region us-west-2 \
    --instance-ids "$INSTANCE_ID" \
    --query 'TerminatingInstances[0].InstanceId' --output text

  kubectl delete node "$node" --ignore-not-found

  echo "=== Waiting up to 5m for a new node to join Ready ==="
  # Poll until we have at least (starting_count) nodes again.
  for i in $(seq 1 60); do
    READY_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | \
      grep -v NotReady | grep -c 'Ready' || echo 0)
    if [ "$READY_COUNT" -ge 2 ]; then
      break
    fi
    sleep 5
  done

  echo "=== Waiting for cilium-agent to be Ready on the new node ==="
  # Cilium DS pods start on new nodes automatically.
  kubectl -n kube-system rollout status ds/cilium --timeout=3m
  echo "=== Sleeping 30s to let workloads reschedule ==="
  sleep 30
done
```

## Step 5 — Verify (~5 min)

```bash
# 1. cilium-agent + cilium-operator + hubble on new nodes only.
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system get pods -l io.cilium/app=operator -o wide

# 2. cilium status (via CLI or exec into an agent pod).
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium status --brief
# Expect: `Cilium:  OK`, `Kube-proxy:  Disabled`, `KubeProxyReplacement: True`.

# 3. New pods are Cilium-managed. Restart a workload and verify:
kubectl -n llmsafespaces rollout restart deploy/llmsafespaces-api
kubectl -n llmsafespaces get pods -l app.kubernetes.io/component=api
POD=$(kubectl -n llmsafespaces get pods -l app.kubernetes.io/component=api -o name | head -1)
# Confirm cilium sees the endpoint:
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium endpoint list | \
  grep "$(kubectl -n llmsafespaces get "$POD" -o jsonpath='{.status.podIP}')"
# Expected: one row with identity + labels visible.

# 4. Traffic still flows. Hit the app externally:
curl -sf https://safespaces.thekao.cloud/livez && echo OK
```

## Step 6 — Push the ops-prod repo change (~2 min)

At this point the cluster is running Cilium bootstrapped by helm CLI. Un-suspend the Flux HelmRelease so Flux takes over reconciliation:

```bash
cd ~/llmsafespaces-ops-prod

# Un-suspend the HelmRelease. The manifest ships with spec.suspend=true
# so Flux doesn't race the migration. Remove the `suspend: true` line
# from kubernetes/apps/kube-system/cilium/app/helm-release.yaml, then:
git diff kubernetes/apps/kube-system/cilium/app/helm-release.yaml
git commit -am "cilium: un-suspend HelmRelease post-migration"
git push

# Flux picks up in ~2min. Force reconcile:
flux reconcile source git llmsafespaces-ops
flux reconcile kustomization cluster-apps

# Watch Cilium's HelmRelease adopt the bootstrap release.
kubectl -n kube-system get hr cilium -w
# Status → Ready. If it goes into UpgradeFailed with the message
# "release cilium exists" you need to annotate the existing release
# so Flux takes ownership:
#   kubectl -n kube-system label secret sh.helm.release.v1.cilium.v1 \
#     app.kubernetes.io/managed-by=Helm \
#     helm.toolkit.fluxcd.io/name=cilium \
#     helm.toolkit.fluxcd.io/namespace=kube-system --overwrite
```

Once Flux is reconciling Cilium successfully, the `cluster-llmsafespaces-policy` Kustomization (which depends on cilium's HR being Ready) will apply the `workspace-egress-allowlist` CNP.

## Step 7 — Verify the egress policy (~5 min)

```bash
# 1. CNP is in place.
kubectl -n llmsafespaces get cnp workspace-egress-allowlist
kubectl -n llmsafespaces describe cnp workspace-egress-allowlist | grep -A 5 Status

# 2. Cilium sees the policy attached to workspace endpoints. Wait
#    until a workspace pod is running (create a Workspace CR or wait
#    for a user to spawn one), then:
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium policy get --labels app=llmsafespaces,component=workspace | head -30

# 3. Egress enforcement: exec into a workspace pod and try both a
#    permitted and denied FQDN.
POD=$(kubectl -n llmsafespaces get pods -l component=workspace -o name | head -1)
kubectl -n llmsafespaces exec "$POD" -- curl -sfm 5 https://api.openai.com/v1/models > /dev/null && echo 'OpenAI: allowed OK'
kubectl -n llmsafespaces exec "$POD" -- curl -sfm 5 https://example.com/ 2>&1 | tail -3
# Expected: "curl: (28) Resolving timed out" or "curl: (6) Could not resolve host"
# because the DNS proxy learned no IP for example.com (not in allowlist).

# 4. Hubble shows drops for denied traffic:
kubectl -n kube-system exec deploy/hubble-relay -c hubble-relay -- \
  hubble observe --namespace llmsafespaces --verdict DROPPED --last 20
```

## Rollback

If Cilium fails to install or nodes won't come up post-cycle:

```bash
# 1. Uninstall Cilium.
helm --namespace kube-system uninstall cilium

# 2. Reinstall VPC CNI + kube-proxy. Easiest via EKS managed addons
#    (which Cilium didn't need but VPC CNI does for updates):
aws eks create-addon --profile mikekao-prod --region us-west-2 \
  --cluster-name llmsafespaces \
  --addon-name vpc-cni \
  --resolve-conflicts OVERWRITE
aws eks create-addon --profile mikekao-prod --region us-west-2 \
  --cluster-name llmsafespaces \
  --addon-name kube-proxy \
  --resolve-conflicts OVERWRITE

# 3. Cycle nodes again to get VPC CNI-managed veth pairs back.
#    Same for-loop as Step 4 above.

# 4. Revert the ops-prod repo change (remove kube-system/cilium/*,
#    remove workspace-egress-allowlist, drop the ./kube-system entry
#    in apps/kustomization.yaml). git push. Flux prunes the stale
#    resources.
```

## Known gotchas

1. **DNS resolution briefly fails during agent boot on a new node.** The Cilium agent installs a CNI config file, then briefly (~5s) the kubelet has no working CNI. New pods on that node get `ContainerCreating`. Not a problem for running pods.

2. **Hubble UI in-cluster only.** No Ingress yet. Access via `cilium hubble ui` (port-forward) or `kubectl -n kube-system port-forward svc/hubble-ui 12000:80` if you don't have the CLI.

3. **Node IP capacity dropped.** Cilium ENI mode uses secondary IPs on the primary ENI; the count you get depends on instance type. `t3a.large`: max 12 pods per node (down from ~35 with VPC CNI's IP prefix mode). If your cluster runs hot on pod count, either upgrade instance types or enable `eni.awsEnablePrefixDelegation=true` (adds prefix delegation support). We haven't set that here; add it if you see `nodes at pod capacity` alerts.

4. **falco daemonset shows 1/2 Ready.** Pre-existing issue (`kubelet-too-many-pods` on one node). Cilium migration does NOT fix this. Same workaround (bigger instances or prefix delegation).

5. **Older ClusterMesh states**. This cluster has cluster.id=1. If you ever add a second cluster to a mesh, IDs must be unique across the mesh.

6. **`egressMasqueradeInterfaces` must match your ENI naming**. AWS Nitro instances (t3a, m5+, c5+, r5+, everything modern) name their ENIs `ens5`, `ens6`, etc — NOT `eth0`. Setting `egressMasqueradeInterfaces=eth+` (the Cilium blog example) silently breaks all pod → internet egress because the iptables MASQUERADE rule matches no interface. Symptoms: pods can reach in-cluster services + can serve ALB traffic, but ANY `curl external.example.com` from inside a pod hangs then times out. Use `ens+` on Nitro, or `eth+,ens+` if you have a mixed fleet. Session-2 (2026-07-02) tripped over this during the actual migration.

7. **Existing K8s NetworkPolicies get enforced immediately**. Any NetworkPolicy CRDs the old cluster ignored (because VPC CNI didn't enforce them without the aws-network-policy-agent add-on being explicitly enabled) will start being enforced the moment Cilium boots. Look for pods with `POLICY (ingress) Enabled` in `cilium endpoint list`. If a controller suddenly can't reach the K8s API, it's probably an over-restrictive NetworkPolicy on its namespace. Check with `kubectl -n <ns> get networkpolicy`.

8. **Force-delete stuck pods after aws-node deletion**. Pre-migration pods have veth pairs set up by VPC CNI. After you delete `aws-node`, those pods keep running BUT their network state is orphaned — if the pod restarts (e.g. crashloop, OOM, evict), it can't get networking back until it's scheduled onto a Cilium-managed node. Practical workaround: after node cycling completes, `kubectl get pods -A | grep -v Running` and force-delete anything crashlooping. Their replacements will land on Cilium-clean nodes.

9. **Flux single-replica controllers block drain via PDB**. The flux-system Flux controllers ship with `PodDisruptionBudget minAvailable: 1` and are single-replica. Draining a node hosting one of these controllers hits a permanent PDB block. Workaround: temporarily patch each PDB to `maxUnavailable: 1` via `kubectl patch pdb <name> --type=json -p '[{"op":"remove","path":"/spec/minAvailable"},{"op":"add","path":"/spec/maxUnavailable","value":1}]'`. After migration, `flux reconcile kustomization cluster-flux-pdbs` restores the desired state.

## References

- Cilium on EKS ENI mode: <https://cilium.io/blog/2025/06/19/eks-eni-install>
- Cilium 1.17 upgrade guide: <https://docs.cilium.io/en/v1.17/operations/upgrade/>
- FQDN-based policies: <https://docs.cilium.io/en/stable/security/policy/language/#dns-based>
- Related issue: [lenaxia/llmsafespaces-ops-prod#1](https://github.com/lenaxia/llmsafespaces-ops-prod/issues/1)
