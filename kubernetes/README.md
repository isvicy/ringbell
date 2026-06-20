# Kubernetes GitOps - ringbell.cc

Homelab Kubernetes cluster managed by [Argo CD](https://argo-cd.readthedocs.io/), running on [Talos Linux](https://www.talos.dev/) VMs (Unraid/libvirt). Migrated from Flux CD to Argo CD on 2026-06-20.

## Architecture

```
kubernetes/
├── argocd/                    # Argo CD control plane (installed once, then self-managed)
│   ├── bootstrap/             # AppProject, the `homelab` ApplicationSet, self-managed argocd App, namespaces App
│   ├── namespaces/            # the app Namespaces (incl. privileged PodSecurity labels)
│   └── values/argocd.yaml     # argo-cd Helm chart values (tracking, ServerSideDiff, Lua health, SSO, metrics)
├── apps/                      # All workloads, by namespace; each app = <ns>/<app>/{app.yaml, values.yaml, app/}
│   ├── security/              # 1Password Connect, External Secrets, ClusterSecretStore
│   ├── networking/            # Cilium, Gateway API, cloudflared, external-dns, Caddy auth proxy
│   ├── auth/                  # Authelia (Caddy forward-auth + native OIDC SSO for grafana/harbor/argocd/...)
│   ├── cert-manager/          # cert-manager + ClusterIssuers + wildcard cert (*.ringbell.cc)
│   ├── dashboard/             # Homepage (K8s service discovery, cluster widgets)
│   ├── storage/              # Rook-Ceph (+ toolbox), NFS, Synology CSI, snapshots
│   ├── backup/                # Volsync (backup + restore — see Backups below)
│   ├── kube-system/           # Cilium, Spegel OCI mirror, metrics-server, priority-classes
│   ├── observability/         # kube-prometheus-stack (Prometheus, Grafana, Alertmanager), loki, tempo, alloy
│   ├── registry/              # Harbor
│   ├── vcs/                   # Forgejo (+ postgres), gitea-mirror
│   └── default/               # E2E storage test (manual, not Argo-managed)
├── components/
│   └── volsync/               # Reusable kustomize component (Argo-native; per-app backup opt-in)
└── docs/
    ├── best-practices.md      # Component comparison with reference homelab
    └── troubleshooting.md     # issues with root cause, fix, prevention
```

### How apps are defined (ApplicationSet)

A single `homelab` **ApplicationSet** (git *files* generator, `goTemplate` + `templatePatch`) generates one Argo `Application` per `app.yaml`. Drop in a new app by adding a directory under `apps/<ns>/<app>/`:

```yaml
# apps/<ns>/<app>/app.yaml — metadata the ApplicationSet reads
name: harbor
namespace: registry
wave: 3                  # documents the dependency layer (see below); not a hard gate under autosync
type: helm               # helm | kustomize
adopted: true            # true -> the app gets automated {prune, selfHeal}
repoURL: https://helm.goharbor.io   # helm only
chart: harbor                        # helm only
version: "1.18.3"                    # helm only — pinned
resources: true          # helm only — also render app/resources/ (ExternalSecret, HTTPRoute, CRs)
# ignoreDifferences:     # optional, per-app (see Gotchas)
```

- **Helm apps** render native Helm via multi-source: a `$values` ref (this repo's `values.yaml`) + the upstream chart + an optional `app/resources` kustomize source for bundled raw manifests.
- **Kustomize apps** point at `app/` (a kustomization).
- Resource tracking is by **annotation** (`application.resourceTrackingMethod: annotation`), so adopting a resource only adds a tracking annotation — no churn.

### Dependency ordering (waves + convergence)

Argo CD doesn't use Flux-style `dependsOn`. Cross-app ordering is handled by:

1. **autosync + retry** — each adopted app self-heals; apps whose dependencies aren't ready yet fail and retry until the cluster **converges**.
2. **`wave`** in `app.yaml` — documents the dependency layer (roughly: namespaces → onepassword-connect → external-secrets → external-secrets-store → cert-manager/storage/network → leaf apps). It's the source label if RollingSync is ever enabled, not a hard gate today.
3. **Custom Lua health checks** (in `values/argocd.yaml`) for CRDs Argo can't assess natively (CephCluster/CephBlockPool/CephFilesystem, Gateway).

## Bootstrap (from scratch)

### Prerequisites

| Item | Where |
|------|-------|
| 1Password items | app secrets in vault `homelab`; the **Connect** server credential + token at `pass show homelab/connect-server/{credential,token}` |
| Garage S3 creds | `pass show s3/garage/tf-state/{access,secret}-key` |
| Cloudflare tunnel | Created via `cloudflared tunnel create ringbell` |
| Unraid NFS | Share at `192.168.2.200:/mnt/user/kubernetes` (Unraid WebUI) |
| Synology iSCSI | Service running, user `homelab`, creds in 1Password |

### Steps

```bash
# 1. Terraform — create Talos VMs AND seed the GitOps root-of-trust
#    (terraform/argocd-bootstrap.tf creates the onepassword-connect Secret from `pass`,
#     without persisting secret material in TF state)
cd terraform
AWS_ACCESS_KEY_ID=$(pass show s3/garage/tf-state/access-key) \
AWS_SECRET_ACCESS_KEY=$(pass show s3/garage/tf-state/secret-key) \
  terraform init -backend-config=backend.hcl && terraform apply
# export the kubeconfig: terraform output -raw kubeconfig > /tmp/kc && export KUBECONFIG=/tmp/kc

# 2. Install Cilium (CNI) so pods can network and Argo can come up.
helm install cilium cilium/cilium --version <v> -n kube-system -f kubernetes/apps/networking/cilium/values.yaml

# 3. Install Argo CD once (it then manages itself via apps/argocd bootstrap), then seed the control plane.
helm install argocd argo/argo-cd --version 9.5.22 -n argocd --create-namespace \
  -f kubernetes/argocd/values/argocd.yaml
kubectl apply -f kubernetes/argocd/bootstrap/project-homelab.yaml
kubectl apply -f kubernetes/argocd/bootstrap/app-namespaces.yaml
kubectl apply -f kubernetes/argocd/bootstrap/applicationset-apps.yaml
kubectl apply -f kubernetes/argocd/bootstrap/app-argocd.yaml   # self-management

# 4. Argo adopts Cilium + reconciles every app.yaml from git. Verify:
kubectl get applications -n argocd               # all Synced / Healthy
kubectl config set-context --current --namespace=argocd
argocd app list --core
kubectl get cephcluster -n storage               # HEALTH_OK
```

The ringbell repo is **public**, so Argo clones it anonymously — no repo credential needed. Everything else flows from the `onepassword-connect` Secret: External Secrets serves every other secret from the 1Password `homelab` vault.

### Talos Upgrade (rolling)

```bash
IMAGE="factory.talos.dev/installer/<schematic>:<version>"

# Control planes first (no Ceph impact)
for ip in 192.168.2.21 192.168.2.22 192.168.2.23; do
  talosctl --nodes $ip upgrade --image=$IMAGE --timeout=10m
done

# Set Ceph noout before worker upgrades
kubectl -n storage exec deploy/rook-ceph-tools -- ceph osd set noout

# Workers one at a time, wait for OSD recovery between each
for ip in 192.168.2.24 192.168.2.25; do
  talosctl --nodes $ip upgrade --image=$IMAGE --timeout=10m
done

kubectl -n storage exec deploy/rook-ceph-tools -- ceph osd unset noout
```

## Storage

Three storage classes for different use cases:

| StorageClass | Backend | Access | Best For |
|---|---|---|---|
| `ceph-bulk` | Rook-Ceph RBD (2× 4TiB OSDs, replica 2) | RWO | App data — replicated across workers |
| `local-nvme` | local-path (node-local NVMe) | RWO | Fast scratch / single-node data; no replication, `WaitForFirstConsumer` |
| `nfs-unraid` | Unraid NFS (31TB) | RWX | Bulk/shared data — media, backups, large datasets |
| `synology-iscsi` | Synology iSCSI (DS918+) | RWO | Data needing NAS-level RAID/snapshot protection |

### Example: PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: myapp-data
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ceph-bulk    # or local-nvme, nfs-unraid, synology-iscsi
  resources:
    requests:
      storage: 10Gi
```

## Networking & DNS

### Gateway

Cilium Gateway `internal` in `networking` namespace, HTTP:80 + HTTPS:443 (wildcard cert `*.ringbell.cc`), LB IP `192.168.2.30` via L2 announcements (pool: 192.168.2.30-39).

### Hostname Convention

DNS A records and proxied CNAMEs can't coexist on the same hostname. To support both LAN and tunnel access, services use separate hostnames:

| Access | Hostname | DNS Record |
|--------|----------|------------|
| LAN | `<name>.ringbell.cc` | DNS-only A → 192.168.2.30 (via external-dns) |
| Tunnel | `<name>-tunnel.ringbell.cc` | Proxied CNAME → tunnel (via Cloudflare API) |

### LAN Access (default)

Create an HTTPRoute — external-dns automatically creates a DNS-only A record in Cloudflare pointing to `192.168.2.30`. Accessible from LAN only.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
spec:
  hostnames: ["myapp.ringbell.cc"]
  parentRefs:
    - name: internal
      namespace: networking
  rules:
    - backendRefs:
        - name: myapp
          port: 80
```

### Internet Access (via Cloudflare Tunnel)

Cloudflared routes all `*.ringbell.cc` tunnel traffic to Caddy. Apps **without** native SSO get Authelia via Caddy `forward_auth`; apps **with** native OIDC (grafana, harbor, argocd, forgejo, proxmox) authenticate against Authelia directly and Caddy just proxies.

Traffic flow: Internet → Cloudflare edge → tunnel → cloudflared → Caddy (`forward_auth` → Authelia, or pass-through) → backend Service

To expose a service via tunnel, add a proxied CNAME via Cloudflare API and a backend entry in Caddy's Caddyfile:

```bash
CF_TOKEN=$(kubectl -n networking get secret cloudflare-api-token \
  -o jsonpath='{.data.api-token}' | base64 -d)

curl -X POST "https://api.cloudflare.com/client/v4/zones/47902d03701ff7e82f7c14a124f34a6f/dns_records" \
  -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" \
  -d '{"type":"CNAME","name":"myapp-tunnel.ringbell.cc",
       "content":"632934dd-f7ca-456e-92eb-dacfb5043624.cfargotunnel.com","proxied":true}'
```

## Authentication

Two SSO patterns against [Authelia](https://www.authelia.com/) (`auth` ns):

- **Caddy `forward_auth`** — for apps with no native auth. Cloudflared routes `*.ringbell.cc` to Caddy; Caddy enforces `forward_auth` → Authelia before proxying. (CiliumEnvoyConfig *cannot* inject auth into Gateway API proxies — cilium/cilium#26941 — so Caddy does it.)
- **Native OIDC** — for apps that speak OIDC (grafana, harbor, argocd, forgejo, proxmox). Each is an Authelia OIDC client; the app does the login flow itself. Argo CD uses two clients (`argocd` confidential web + `argocd-cli` public/PKCE) because it can't combine PKCE with a client secret on one client (argoproj/argo-cd#23773).

```
┌──────────┐     ┌──────────┐  forward_auth  ┌──────────┐
│cloudflared├────►│  Caddy   ├───────────────►│ Authelia  │
└──────────┘     └────┬─────┘                 └──────────┘
                      │ (authed / or app does OIDC itself)
                      ▼
                  ┌──────────┐
                  │ Backend  │
                  └──────────┘
```

## Backups (Volsync)

`components/volsync` is a reusable, **Argo-native** kustomize component for per-app Restic backups to Garage S3. Per-app values (`app`, `capacity`) come from a `volsync-config` ConfigMap injected via kustomize `replacements` (the replacement for Flux's `${APP}` postBuild); shared infra (S3 endpoint, snapshot class, 6h schedule, 7d/4w/3m retention) is baked into the component.

Opt an app in — in its `app/kustomization.yaml`:

```yaml
components:
  - ../../../../components/volsync
configMapGenerator:
  - name: volsync-config
    literals:
      - app=myapp        # names every resource + the restic repo path
      - capacity=10Gi    # data PVC + restore-destination size
generatorOptions:
  disableNameSuffixHash: true   # replacements reference it by stable name
```

Creates: the app's data PVC `myapp` (auto-restores from the latest backup on a fresh cluster via `dataSourceRef`), `ReplicationSource myapp-backup` (scheduled snapshots), `ReplicationDestination myapp` (manual restore), and the restic-creds ExternalSecret. Mount PVC `myapp` in the app's pod. No app currently opts in.

### Manual Snapshot / Restore

```bash
# snapshot now
kubectl -n <ns> annotate replicationsource <app>-backup --overwrite \
  volsync.backube/trigger=$(date +%s)

# restore: scale down, trigger, wait, scale up
kubectl -n <ns> scale deploy/<app> --replicas=0
kubectl -n <ns> patch replicationdestination <app> \
  --type merge -p '{"spec":{"trigger":{"manual":"restore-'$(date +%s)'"}}}'
kubectl -n <ns> get replicationdestination <app> -w
kubectl -n <ns> scale deploy/<app> --replicas=1
```

## Secrets

All secrets flow through **1Password Connect** + **External Secrets Operator**:

```
1Password vault "homelab"
  └─> 1Password Connect (security ns)        # root cred seeded by Terraform from `pass`
        └─> ClusterSecretStore "onepassword"
              └─> ExternalSecret (per-app) ─> Kubernetes Secret
```

The root of trust — the `onepassword-connect` Secret — is seeded by **Terraform** from `pass` (`terraform/argocd-bootstrap.tf`), NOT SOPS-in-git. Everything else uses ExternalSecret.

### Example: ExternalSecret

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: myapp-secret
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword
  target:
    name: myapp-secret
  data:
    - secretKey: password
      remoteRef:
        key: myapp          # 1Password item name
        property: password   # field name
```

## E2E Storage Test

Manually triggered test that verifies all storage classes (`local-nvme`, `ceph-bulk`, `nfs-unraid`, `synology-iscsi`). Not Argo-managed — run after significant storage or PVC changes.

```bash
kubectl apply -k kubernetes/apps/default/e2e-test/app   # deploy
# Check results at http://test-lan.ringbell.cc
kubectl delete -k kubernetes/apps/default/e2e-test/app  # clean up
```

## Gotchas

See `docs/troubleshooting.md` for storage/networking details. Argo CD + this cluster specifically:

1. **ServerSideDiff must be on** (`controller.diff.server.side: "true"`) — else Gateway API HTTPRoutes are perpetually OutOfSync from server-applied default fields.
2. **Chart-generated secrets** (harbor internal, grafana admin): make them **declarative** (source from 1Password via ExternalSecret + the chart's `existingSecret` knobs) so renders are byte-stable. Fragile alternative: per-app `ignoreDifferences` on the secret `/data` + the dependent Deployment's checksum annotations, **plus** global `RespectIgnoreDifferences=true` (without it, sync still rotates them).
3. **cilium Hubble certs**: `ignoreDifferences` on `cilium-ca`/`hubble-server-certs`/`hubble-relay-client-certs` `/data` is the **correct upstream pattern** (auto-generated, non-idempotent — cilium docs "Troubleshooting Cilium deployed with Argo CD"), not a hack to remove.
4. **SSA can't remove fields owned by another manager / left from client-side apply** (argoproj/argo-cd#23214): the app shows **Synced with no diff while live ≠ git**. Fix: the `argocd.argoproj.io/client-side-apply-migration-manager` annotation, `Replace=true`, or delete-and-recreate the resource.
5. **RollingUpdate→Recreate won't apply via SSA** (mutually-exclusive `strategy.rollingUpdate` vs `type: Recreate`): `kubectl patch deploy X --type=merge -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'` (matches git). Harbor registry/jobservice need Recreate (RWO PVCs deadlock on RollingUpdate Multi-Attach).
6. **repo-server caches branch→commit**: after a push, `kubectl -n argocd rollout restart deploy/argocd-repo-server` (+ `argocd-applicationset-controller` for `app.yaml` changes) to force a fresh render instead of waiting ~3 min.
7. **Privileged PodSecurity** needed for `storage`, `observability`, `kube-system` namespaces.
8. **Cilium needs experimental Gateway API CRDs** — standard channel lacks TLSRoute.
9. **Cloudflared needs `--protocol http2`** — QUIC blocked in most home networks.
10. **Rook-Ceph SC parameters** — custom `parameters` replaces chart defaults; must include `csi.storage.k8s.io/*` refs. StorageClass params are immutable — delete + recreate.
11. **Prometheus must NOT use NFS** — causes WAL corruption; use `ceph-bulk`.
12. **CiliumEnvoyConfig can't inject into Gateway API** — cilium/cilium#26941; use Caddy `forward_auth` for auth.
13. **Authelia chart secret keys use dot-paths** — e.g. `identity_validation.reset_password.jwt.hmac.key`. Always `helm show values` first.
14. **The Bash here runs zsh** — `for x in $string` does NOT word-split; use file-based `while read` loops for cluster scripts.
