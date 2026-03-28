# CLAUDE.md

## What This Is

A homelab Kubernetes cluster managed by Flux CD GitOps, running on Talos Linux VMs (Unraid/libvirt KVM). Infrastructure provisioned via Terraform, workloads declared in `kubernetes/`.

## Reference Repositories

These repos are added as working directories and should be consulted when setting up or troubleshooting components:

1. **`/home/isvicy/repos/github/cluster-template`** — The upstream template used to generate the homelab setup. Refer to this for bootstrap procedures, Taskfile automation, and base configuration patterns.

2. **`/home/isvicy/repos/github/homelab`** — A production homelab generated from `cluster-template`. Core components:
   - cert-manager, cilium, cloudflared, external-dns, external-secrets
   - ingress-nginx, rook, spegel, volsync
   - Rich examples of app deployments, HTTPRoutes, Volsync opt-in, dual external-dns (Cloudflare + UniFi)

3. **`/home/isvicy/repos/github/synology-csi-talos`** — Custom fork of Synology CSI driver for Talos Linux compatibility. Uses nsenter wrappers to access the host iSCSI stack. Helm chart served from GitHub Pages.

## Key Commands

```bash
# Terraform
cd terraform/terraform
AWS_ACCESS_KEY_ID=$(pass show s3/garage/tf-state/access-key) \
AWS_SECRET_ACCESS_KEY=$(pass show s3/garage/tf-state/secret-key) \
  terraform plan

# Flux
flux get ks -A                        # all Kustomizations
flux get hr -A                        # all HelmReleases
flux reconcile source git flux-system # force git sync
flux reconcile ks <name>              # force kustomization reconcile
flux suspend hr <name> && flux resume hr <name>  # clear stuck rollback

# Talos
talosctl --nodes <ip> upgrade --image=<factory-image> --timeout=10m
talosctl --nodes <ip> get extensions  # verify extensions

# Ceph (via operator pod)
kubectl -n storage exec deploy/rook-ceph-operator -- ceph -s \
  --conf=/var/lib/rook/storage/storage.config \
  --keyring=/var/lib/rook/storage/client.admin.keyring

# Secrets (never print to stdout)
pass show <path>  # use inline: $(pass show <path>)
```

## Directory Structure

```
terraform/          # Terraform configs for Talos VMs on Unraid/libvirt
  terraform/        # Main terraform root (providers, modules, state)
  templates/        # Talos machine config patches (controlplane, worker)
  images/           # Talos QCOW2 boot image (factory image with iscsi-tools)
kubernetes/         # Flux-managed GitOps manifests
  bootstrap/flux/   # Flux bootstrap (gotk-components, gotk-sync)
  flux/config/      # Cluster-level Flux Kustomizations + settings ConfigMap
  flux/repositories/# HelmRepository sources
  apps/             # All workloads by namespace (security, networking, storage, etc.)
  components/       # Reusable kustomize components (volsync)
.sops.yaml          # SOPS encryption rules (age backend)
```

## Conventions

### App Structure
Each app follows `kubernetes/apps/<namespace>/<app-name>/`:
- `ks.yaml` — Flux Kustomization (dependsOn, postBuild, components)
- `app/kustomization.yaml` — Kustomize resource list
- `app/helmrelease.yaml` or raw manifests

### Flux Kustomizations
- Every ks.yaml using `${}` variables MUST have its own `postBuild.substituteFrom` (not inherited from parent)
- Split operator installs from CR creation into separate Kustomizations with `dependsOn`
- Use `prune: true` and `wait: true` unless intentionally fire-and-forget

### Secrets
- Bootstrap secret (1Password Connect creds): SOPS-encrypted in git
- Everything else: ExternalSecret -> ClusterSecretStore "onepassword" -> 1Password vault "homelab"
- Never print secrets to stdout — use `$(pass show ...)` inline

### Storage
- `ceph-block`: App data (fast SSD, replicated, RWO)
- `nfs-unraid`: Bulk/shared data (31TB, RWX)
- `synology-iscsi`: NAS-protected data (RWO, WaitForFirstConsumer)

### Networking
- LAN access: HTTPRoute -> external-dns creates DNS-only A record -> gateway 192.168.2.30
- Internet access: Proxied CNAME to tunnel via Cloudflare API (not external-dns, due to A/CNAME conflict)
- Cloudflared uses `--protocol http2` (QUIC blocked in home network)

### Commits
Conventional commits enforced via commitlint: `type(scope): message`

## Known Gotchas

See `kubernetes/README.md` Gotchas section for the full list. Top issues:
1. Rook-Ceph StorageClass custom parameters override chart defaults (must include CSI secret refs)
2. StorageClass parameters are immutable — delete and recreate
3. Gateway API needs experimental CRDs for Cilium (TLSRoute)
4. `storage` namespace needs `pod-security.kubernetes.io/enforce: privileged`
