# CLAUDE.md

## What This Is

A homelab Kubernetes cluster managed by Flux CD GitOps, running on Talos Linux VMs (Unraid/libvirt KVM). Infrastructure provisioned via Terraform, workloads declared in `kubernetes/`.

## Cluster Context 

When deploying to this homelab K8s cluster: storage classes are 'ceph-bulk' and 'local-path'. Always verify existing StorageClass names with `kubectl get sc` before referencing them in manifests. StorageClasses are immutable — if fields need changing, delete and recreate.

This is a GitOps (Flux) managed cluster. Never use `kubectl apply` or `kubectl edit` to make persistent changes — they will be overwritten by Flux reconciliation. All changes must go through git commits to the repo.

## Safety Rules

**IMPORTANT — This is a live homelab cluster. Mistakes can cause data loss, downtime, or require a full rebuild.**

- You MUST research before executing any operation you are not 100% confident about. If an operation touches Ceph, Talos upgrades, NFS exports, Synology configuration, node reboots, PV deletion, or any destructive action — you MUST first research the topic (web search, reference repos, upstream docs) to confirm the approach follows community best practices. Do NOT guess. Do NOT assume. Prove it first.
- You MUST NOT run destructive commands (`kubectl delete pv`, `ceph osd destroy`, `talosctl reset`, `terraform destroy`, `rm -rf`) without explicit user approval AND having researched the consequences.
- You MUST NOT print secrets, tokens, or credentials to stdout. Use them inline via `$(pass show ...)` or pipe directly into commands.
- You MUST set Ceph `noout` flag before any worker node maintenance that takes OSDs offline.
- You MUST upgrade Talos nodes one at a time, control planes first, workers second, verifying health between each.
- You MUST verify container image tags exist before using them in any manifest, script, or HelmRelease. Use `skopeo inspect docker://<image>:<tag>`, the registry API, or a web search to confirm. Never guess or fabricate a tag from a tool's version number.

## Infrastructure / Kubernetes 

When working with Helm charts, ALWAYS read the chart's values schema (`helm show values <chart>` or check the chart repo) before guessing at value names or structure. Never assume Helm value paths.

## Reference Repositories

These repos are added as working directories and should be consulted when setting up or troubleshooting components:

1. **`/home/isvicy/repos/github/cluster-template`** — The upstream template used to generate the homelab setup. Refer to this for bootstrap procedures, Taskfile automation, and base configuration patterns.

2. **`/home/isvicy/repos/github/homelab`** — A production homelab generated from `cluster-template`. Core components:
   - cert-manager, cilium, cloudflared, external-dns, external-secrets
   - ingress-nginx, rook, spegel, volsync
   - Rich examples of app deployments, HTTPRoutes, Volsync opt-in, dual external-dns (Cloudflare + UniFi)
3. **`/home/isvicy/repos/github/homelab/khuedoan-homelab`** - Another production homelab utilizes Infrastructure as Code and GitOps to automate provisioning, operating, and updating self-hosted services in homelab. Core features:
   - Common applications: Gitea, Jellyfin, Paperless...
   - Automated bare metal provisioning with PXE boot
   - Automated Kubernetes installation and management
   - Installing and managing applications using GitOps
   - Automatic rolling upgrade for OS and Kubernetes
   - Automatically update apps (with approval)
   - Modular architecture, easy to add or remove features/components
   - Automated certificate management
   - Automatically update DNS records for exposed services
   - VPN (Tailscale or Wireguard)
   - Expose services to the internet securely with Cloudflare Tunnel
   - CI/CD platform
   - Private container registry
   - Distributed storage
   - Support multiple environments (dev, prod)
   - Monitoring and alerting
   - Automated backup and restore
   - Single sign-on
   - Infrastructure testing

4. **`/home/isvicy/repos/github/synology-csi-talos`** — Custom fork of Synology CSI driver for Talos Linux compatibility. Uses nsenter wrappers to access the host iSCSI stack. Helm chart served from GitHub Pages.

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

# E2E Storage Test (manual, not Flux-managed)
kubectl apply -k kubernetes/apps/default/e2e-test/app   # deploy
# visit http://test-lan.ringbell.cc to check results
kubectl delete -k kubernetes/apps/default/e2e-test/app  # clean up
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
  apps/             # All workloads by namespace (auth, dashboard, networking, security, storage, etc.)
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
- Hostname convention: `<name>.ringbell.cc` (LAN, A record) / `<name>-tunnel.ringbell.cc` (tunnel, proxied CNAME)
- LAN access: HTTPRoute → external-dns creates DNS-only A record → gateway `internal` at 192.168.2.30
- Internet access: Proxied CNAME → cloudflared → Caddy (`forward_auth` → Authelia) → backend
- Cloudflared routes all `*.ringbell.cc` tunnel traffic to Caddy (static config)
- Cloudflared uses `--protocol http2` (QUIC blocked in home network)
- CiliumEnvoyConfig CANNOT inject auth into Gateway API (cilium/cilium#26941) — use Caddy forward_auth instead

### Commits
Conventional commits enforced via commitlint: `type(scope): message`

## Known Gotchas

See `kubernetes/README.md` Gotchas section for the full list. Top issues:
1. Rook-Ceph StorageClass custom parameters override chart defaults (must include CSI secret refs)
2. StorageClass parameters are immutable — delete and recreate
3. Gateway API needs experimental CRDs for Cilium (TLSRoute)
4. `storage` namespace needs `pod-security.kubernetes.io/enforce: privileged`
5. CiliumEnvoyConfig cannot inject filters into Gateway API proxies — use Caddy `forward_auth` for auth
6. Always `helm show values` before writing a HelmRelease — chart schemas are not guessable
