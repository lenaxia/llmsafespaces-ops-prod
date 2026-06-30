# llmsafespaces-ops-prod

[FluxCD](https://fluxcd.io) GitOps repository for the
[lenaxia/LLMSafeSpaces](https://github.com/lenaxia/LLMSafeSpaces) platform
on the EKS cluster provisioned by
[lenaxia/llmsafespaces-aws-cdk](https://github.com/lenaxia/llmsafespaces-aws-cdk).

## Architecture

Three-repo separation:

| Repo | Concern |
|---|---|
| [llmsafespaces](https://github.com/lenaxia/LLMSafeSpaces) | The app: code, Helm chart, container images, upstream fixes |
| [llmsafespaces-aws-cdk](https://github.com/lenaxia/llmsafespaces-aws-cdk) | AWS-side infrastructure: VPC, EKS, RDS, Valkey, ACM, IAM, **Flux bootstrap** |
| **this repo** | Continuous reconciliation of K8s state: HelmReleases, ExternalSecrets, NetworkPolicies, monitoring, security policies |

Bootstrap chain:
1. `cdk deploy --all` creates AWS resources + installs Flux + applies a single GitRepository pointing here
2. Flux reads this repo every 2 minutes and applies everything under `kubernetes/`
3. Cluster reaches steady state without any further manual steps

## Repository layout

Mirrors the [home-operations/k8s](https://github.com/onedr0p/home-cluster) convention used by
[lenaxia/talos-ops-prod](https://github.com/lenaxia/talos-ops-prod).

```
kubernetes/
├── flux/                          # Flux self-management
│   ├── config/                    # GitRepository + cluster Kustomization
│   ├── repositories/              # HelmRepository definitions
│   └── vars/                      # cluster-settings ConfigMap (+ sops secret)
└── apps/                          # All workloads
    ├── external-secrets/          # ExternalSecrets operator + ClusterSecretStore
    ├── cert-manager/              # Validating webhook cert issuer
    └── llmsafespaces/             # The platform chart + workarounds
```

Each app under `apps/<ns>/<name>/` follows the pattern:
- `ks.yaml`: Flux `Kustomization` that defines how Flux applies the app (path, healthChecks, dependsOn)
- `app/`: actual K8s manifests applied by the Kustomization above
- `<ns>/namespace.yaml`: namespace definition with PSA labels

## Variable substitution

Flux's `postBuild.substituteFrom` makes the following ConfigMap keys
available as `${VAR}` substitutions in any manifest under `kubernetes/`:

From `kubernetes/flux/vars/cluster-settings.yaml`:
- `DOMAIN`, `TIMEZONE`, `CLUSTER_NAME`, `AWS_REGION`

From `cluster-config` (created by CDK PlatformStack):
- `POSTGRES_HOST`, `POSTGRES_SECRET_ARN`
- `VALKEY_HOST`
- `ACM_CERT_ARN`
- `EXTERNAL_SECRETS_ROLE_ARN`
- `JWT_SECRET_ARN`, `MASTER_SECRET_ARN`, `INTERNAL_TOKEN_ARN`, `INFERENCE_RELAY_SECRET_ARN`
- `IMAGE_REPO_API`, `IMAGE_TAG_API` (and same for controller/frontend/base)

This means the same git repo deploys against any environment without
modification — all environment-specific values come from CDK outputs
materialized into the cluster-config ConfigMap.

## Secrets

Two patterns:

### AWS-managed secrets (RDS password, app-level JWT keys, etc.)
Created by CDK in AWS Secrets Manager. Materialized into K8s Secrets by
`external-secrets-operator` via the `ExternalSecret` CR at
`kubernetes/apps/llmsafespaces/llmsafespaces/externalsecret/`. Never in git.

### Operator-controlled secrets (Cloudflare API token, Discord webhook URL)
Stored as SOPS-encrypted `*.sops.yaml` files in this repo, decrypted by
Flux's `kustomize-controller` at apply time using the age private key.

The age recipient is in `.sops.yaml`. The matching private key:
- Operator: `~/.config/sops/age/keys.txt`
- Cluster: `Secret/sops-age` in `flux-system` namespace (created by CDK
  from the same SecretsManager source)

## Bootstrap on a fresh cluster

This is automatic — CDK does it. But for reference, the equivalent
manual procedure:

```bash
# 1. cdk deploys cluster + creates Flux installation + cluster-config CM
aws eks update-kubeconfig --name llmsafespaces --region us-west-2

# 2. Apply the sops age key (one-time, from password manager)
kubectl create secret generic sops-age \
  --namespace flux-system \
  --from-file=age.agekey=$HOME/.config/sops/age/keys.txt

# 3. Apply this repo's Flux config
kubectl apply -f kubernetes/flux/config/cluster.yaml
kubectl apply -f kubernetes/flux/config/flux.yaml

# 4. Watch reconciliation
flux get all -A
```

## Adding a new app

1. Create `kubernetes/apps/<ns>/<name>/`
2. Write `ks.yaml` (Flux Kustomization) at the namespace level
3. Write `app/helm-release.yaml` or raw manifests in `app/`
4. Write `app/kustomization.yaml` listing the resources
5. Add the new app to `kubernetes/apps/<ns>/kustomization.yaml`
6. Commit + push; Flux picks it up within 2 minutes

For Helm-installed apps, also add the `HelmRepository` to
`kubernetes/flux/repositories/helm/` if it's not already there.

## Phase 2 apps (not yet in this repo)

The production-hardening roadmap (lenaxia/llmsafespaces-aws-cdk#12)
calls for these next:

- **VictoriaMetrics** + Grafana + Loki + Vector (metrics + logs)
- **Falco** (runtime threat detection)
- **Cilium** with FQDN egress NetworkPolicy for workspace pods
- **Cloudflare** integration (DNS, WAF rules via Cloudflare Workers)

## License

MIT.
