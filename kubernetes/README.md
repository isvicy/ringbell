# Kubernetes GitOps - ringbell.cc

Homelab Kubernetes cluster managed by [Flux CD](https://fluxcd.io/), running on [Talos Linux](https://www.talos.dev/) VMs (Unraid/libvirt).

## Architecture

```
kubernetes/
├── bootstrap/flux/         # Flux v2.8.3 bootstrap manifests (gotk-components, gotk-sync)
├── flux/
│   ├── config/             # Cluster-level Flux Kustomizations + cluster-settings ConfigMap
│   └── repositories/helm/  # HelmRepository sources
├── apps/                   # All workloads, organized by namespace
│   ├── security/           # 1Password Connect, External Secrets 2.2.0, ClusterSecretStore
│   ├── networking/         # Cilium, Gateway API, cloudflared, external-dns
│   ├── cert-manager/       # cert-manager + ClusterIssuers + wildcard cert (*.ringbell.cc)
│   ├── storage/            # Rook-Ceph (+ toolbox + dashboard), NFS, Synology CSI, snapshots
│   ├── backup/             # Volsync (backup + restore)
│   ├── kube-system/        # Spegel OCI registry mirror
│   ├── observability/      # kube-prometheus-stack (Prometheus, Grafana, Alertmanager)
│   ├── flux-system/        # PriorityClasses
│   └── default/            # E2E test workload
├── components/
│   └── volsync/            # Reusable kustomize component (backup + restore + PVC)
└── docs/
    ├── best-practices.md   # Component comparison with reference homelab
    └── troubleshooting.md  # 13 issues with root cause, fix, prevention
```

### Flux Dependency Graph

```
priority-classes, spegel, nfs-provisioner (no deps)

onepassword-connect
  └─> external-secrets
        └─> external-secrets-store (bottleneck: 6 consumers)
              ├─> cert-manager-issuers
              ├─> cloudflared (also depends on cilium)
              ├─> external-dns
              ├─> synology-csi (also depends on snapshot-controller)
              ├─> volsync
              └─> (indirectly → e2e-test)

gateway-api ─> cilium ─> cloudflared
cert-manager ─> cert-manager-issuers
rook-ceph + snapshot-controller ─> rook-ceph-cluster ─> kube-prometheus-stack
```

## Bootstrap (from scratch)

### Prerequisites

| Item | Where |
|------|-------|
| 1Password items | `cloudflare-tunnel`, `cloudflare-api-token`, `synology-csi`, `volsync-restic` in vault `homelab` |
| SOPS age key | `pass show age/identity` |
| GitHub token | `pass show github/homelab/token` |
| Garage S3 creds | `pass show s3/garage/tf-state/{access,secret}-key` |
| Cloudflare tunnel | Created via `cloudflared tunnel create ringbell` |
| Unraid NFS | Share at `192.168.2.200:/mnt/user/kubernetes` (configured via Unraid WebUI) |
| Synology iSCSI | Service running, user `homelab` created, creds in 1Password |

### Steps

```bash
# 1. Terraform — create Talos VMs
cd terraform/terraform
AWS_ACCESS_KEY_ID=$(pass show s3/garage/tf-state/access-key) \
AWS_SECRET_ACCESS_KEY=$(pass show s3/garage/tf-state/secret-key) \
  terraform init -backend-config=backend.hcl && terraform apply

# 2. Bootstrap Flux
GITHUB_TOKEN=$(pass show github/homelab/token) flux bootstrap github \
  --owner=isvicy --repository=ringbell --branch=main \
  --path=kubernetes/bootstrap/flux --personal --token-auth

# 3. Create SOPS decryption secret
pass show age/identity | kubectl create secret generic sops-age \
  --namespace=flux-system --from-file=age.agekey=/dev/stdin

# 4. Verify
flux get ks -A                              # all Ready
kubectl get cephcluster -n storage          # HEALTH_OK
kubectl get hr -A                           # 12 HelmReleases Ready
```

### Talos Upgrade (rolling)

After changing the factory image or Talos version:

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
  # Wait ~60s for OSDs to rejoin
done

# Unset noout
kubectl -n storage exec deploy/rook-ceph-tools -- ceph osd unset noout
```

## Storage

Three storage classes for different use cases:

| StorageClass | Backend | Access | Best For |
|---|---|---|---|
| `ceph-block` | Rook-Ceph RBD (2x 180GB SSD) | RWO | App data — fast, replicated across workers |
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
  storageClassName: ceph-block    # or nfs-unraid, synology-iscsi
  resources:
    requests:
      storage: 10Gi
```

## Networking & DNS

### Gateway

Cilium Gateway `external` in `networking` namespace, HTTP:80 + HTTPS:443 (wildcard cert `*.ringbell.cc`), LB IP `192.168.2.30` via L2 announcements (pool: 192.168.2.30-39).

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
    - name: external
      namespace: networking
  rules:
    - backendRefs:
        - name: myapp
          port: 80
```

### Internet Access (via Cloudflare Tunnel)

The HTTPRoute above handles gateway routing. For internet exposure, create a proxied CNAME via Cloudflare API:

```bash
CF_TOKEN=$(kubectl -n networking get secret cloudflare-api-token \
  -o jsonpath='{.data.api-token}' | base64 -d)

curl -X POST "https://api.cloudflare.com/client/v4/zones/47902d03701ff7e82f7c14a124f34a6f/dns_records" \
  -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" \
  -d '{"type":"CNAME","name":"myapp.ringbell.cc",
       "content":"632934dd-f7ca-456e-92eb-dacfb5043624.cfargotunnel.com","proxied":true}'
```

Traffic flow: Internet -> Cloudflare edge -> tunnel -> cloudflared pod -> cilium-gateway-external -> HTTPRoute -> Service

> **Note:** external-dns creates A records for ALL HTTPRoute hostnames. A CNAME and A record can't coexist. Delete the external-dns A record before creating a tunnel CNAME, or don't create the HTTPRoute until the CNAME is in place. For a cleaner setup, consider dual external-dns instances with `--gateway-label-filter`.

## Backups (Volsync)

Volsync performs scheduled Restic backups to Garage S3 (`192.168.50.177:3900/homelab`).

### App Opt-In

Add the volsync component to your app's `ks.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app myapp
  namespace: flux-system
spec:
  targetNamespace: default
  path: ./kubernetes/apps/default/myapp/app
  sourceRef:
    kind: GitRepository
    name: flux-system
  components:
    - ../../../../components/volsync
  dependsOn:
    - name: volsync
  postBuild:
    substitute:
      APP: *app
      VOLSYNC_CAPACITY: 5Gi
    substituteFrom:
      - kind: ConfigMap
        name: cluster-settings
```

This creates:
- **ReplicationSource** — scheduled backup every 6h (retain 7 daily / 4 weekly / 3 monthly)
- **ReplicationDestination** — manual restore trigger
- **ExternalSecret** — restic + S3 creds from 1Password (`volsync-restic` item)
- **PVC** — with `dataSourceRef` pointing to ReplicationDestination (auto-restore on fresh cluster)

### Manual Snapshot

```bash
kubectl -n <namespace> annotate replicationsource <app>-backup --overwrite \
  volsync.backube/trigger=$(date +%s)
```

### Restore

```bash
# 1. Scale down
kubectl -n <ns> scale deploy/<app> --replicas=0

# 2. Trigger restore
kubectl -n <ns> patch replicationdestination <app> \
  --type merge -p '{"spec":{"trigger":{"manual":"restore-'$(date +%s)'"}}}'

# 3. Wait for completion
kubectl -n <ns> get replicationdestination <app> -w

# 4. Scale up
kubectl -n <ns> scale deploy/<app> --replicas=1
```

## Secrets

All secrets flow through **1Password Connect** + **External Secrets Operator**:

```
1Password vault "homelab"
  └─> 1Password Connect (security ns)
        └─> ClusterSecretStore "onepassword"
              └─> ExternalSecret (per-app) ─> Kubernetes Secret
```

Bootstrap chicken-and-egg: 1Password Connect credentials are SOPS-encrypted in git (`secret.sops.yaml`). Everything else uses ExternalSecret.

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

## Gotchas

See `docs/troubleshooting.md` for full details (13 issues). Top ones:

1. **Never jump 15+ chart versions** — ESO 0.14→2.2 caused hours of cascading failures. Upgrade incrementally.
2. **Restart kustomize-controller after CRD changes** — `kubectl -n flux-system rollout restart deploy/kustomize-controller`
3. **StorageClass params are immutable** — delete SC, suspend/resume HR to recreate
4. **Privileged PodSecurity** needed for `storage`, `observability`, `kube-system` namespaces
5. **Cilium needs experimental Gateway API CRDs** — standard channel lacks TLSRoute
6. **Cloudflared needs `--protocol http2`** — QUIC blocked in most home networks
7. **`wait: false` for cluster-scoped resources** — Flux can't health-check ClusterSecretStore with `targetNamespace`
8. **Rook-Ceph SC parameters** — custom `parameters` replaces chart defaults; must include `csi.storage.k8s.io/*` refs
9. **Prometheus must NOT use NFS** — causes WAL corruption; use `ceph-block`
10. **ServiceMonitor before Prometheus** — add `trustCRDsExist: true` to any chart enabling ServiceMonitors
