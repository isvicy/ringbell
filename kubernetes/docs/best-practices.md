# Homelab Kubernetes Best Practices

Component-by-component comparison between our cluster (`ringbell.cc`) and the reference homelab (`zebernst/homelab`), with recommended best practices for each.

---

## 1. cert-manager

### Our Setup
- Chart **v1.17.2**, two ClusterIssuers (production + staging)
- DNS-01 via Cloudflare, no zone selector
- No Gateway API integration, no monitoring

### Reference
- Chart **v1.20.0**, `--enable-gateway-api` flag
- DNS-01 via Cloudflare with `dnsZones` selector restricting to specific domain
- `dns01RecursiveNameservers` set to Cloudflare DoH (`1.1.1.1:443`, `1.0.0.1:443`) with `dns01RecursiveNameserversOnly: true`
- PrometheusRule with 5 alerts (CertExpiry, CertNotReady, HittingRateLimits, etc.)
- Wildcard Certificate pre-issued and shared via ReferenceGrant to Gateway namespace
- PushSecret syncs TLS cert back to 1Password for backup
- Step-issuer for internal CA (`.internal` domain)
- `healthCheckExprs` on Kustomizations with CEL expressions

### Best Practices

1. **Enable Gateway API support** — Add `--enable-gateway-api` to cert-manager args. Required for cert-manager to auto-provision certificates for Gateway listeners.
2. **Use DoH recursive nameservers** — Set `dns01RecursiveNameservers: https://1.1.1.1:443/dns-query,https://1.0.0.1:443/dns-query` and `dns01RecursiveNameserversOnly: true`. Prevents DNS challenge failures from local resolver issues.
3. **Restrict DNS zone selector** — Add `selector.dnsZones: ["ringbell.cc"]` to ClusterIssuer solvers. Prevents cert-manager from attempting challenges against wrong zones.
4. **Pre-issue wildcard certificate** — Create a Certificate resource for `*.ringbell.cc` and share it via ReferenceGrant. Avoids per-service certificate issuance delays and rate limits.
5. **Add monitoring** — PrometheusRule alerts for cert expiry and ACME rate limits are critical for production.
6. **Use CEL health checks** — Add `healthCheckExprs` to Flux Kustomizations to properly detect ClusterIssuer/Certificate readiness.

### Gaps in Our Setup
- No Gateway API flag (cert-manager can't auto-issue for Gateway listeners)
- No wildcard cert (each service would need its own)
- No monitoring (expired certs go unnoticed)
- No DoH nameservers (DNS challenges can fail with local resolvers)

---

## 2. Cilium

### Our Setup
- Chart **1.17.3**, `kubeProxyReplacement: true`
- Single Gateway (`external`, HTTP port 80, no TLS)
- L2 announcements on `eth/enp` interfaces, 10-IP pool (192.168.2.30-39)
- Basic Hubble (UI + relay)
- Operator replicas: 1

### Reference
- Chart **1.19.1**, extensive BPF optimization
- 5 Gateways (external, internal, external-auth, internal-auth, tailscale) with HTTPS listeners
- L2 + BGP (peering with UniFi UDM Pro)
- Dual-stack (IPv4 + IPv6), large IP pool (/24)
- `loadBalancer.algorithm: maglev`, `loadBalancer.mode: dsr`
- `bandwidthManager.enabled: true` with BBR
- `bpf.datapathMode: netkit`, `enableIPv4BIGTCP: true`
- Full Prometheus/ServiceMonitor integration
- Operator replicas: 2
- HTTPS redirect HTTPRoute (HTTP → HTTPS 301)

### Best Practices

1. **Add HTTPS to Gateway** — Our Gateway only has HTTP. With a wildcard cert from cert-manager, add an HTTPS listener. This enables TLS termination at the gateway for LAN access.
2. **Create internal + external Gateways** — Separate gateways allow `--gateway-label-filter` on external-dns to route LAN DNS separately from tunnel DNS. This solves the A-record-vs-CNAME conflict we hit.
3. **Enable DSR + Maglev** — `loadBalancer.mode: dsr` (Direct Server Return) reduces hop count. `loadBalancer.algorithm: maglev` provides consistent hashing for better connection affinity.
4. **Add PERFMON and BPF capabilities** — These enable `bpfClockProbe`, bandwidth manager, and IPv4 BIG TCP features.
5. **Increase operator replicas to 2** — Prevents single point of failure for Cilium control plane.
6. **Add HTTP→HTTPS redirect** — Create an HTTPRoute that redirects all HTTP to HTTPS (301).
7. **Use native routing mode** — `routingMode: native` with `ipv4NativeRoutingCIDR` reduces encapsulation overhead.

### Gaps in Our Setup
- No HTTPS on Gateway (no TLS termination for LAN)
- Single gateway makes LAN/tunnel DNS separation impossible
- No load balancer tuning (default algorithm, no DSR)
- No bandwidth management
- Operator has no HA (1 replica)

---

## 3. cloudflared

### Our Setup
- Raw Deployment (2 replicas), image `2025.4.2`
- `--protocol http2` (forced, QUIC blocked)
- Tunnel config: `*.ringbell.cc` → gateway HTTP port 80
- Metrics on port 8080, liveness probe only
- No security context hardening

### Reference
- app-template Helm chart (2 replicas × 2 tunnels = auth + noauth)
- `TUNNEL_TRANSPORT_PROTOCOL=auto` with HTTP/2 origin enabled
- Separate tunnels for authenticated and unauthenticated traffic
- DNSEndpoint CRD creates tunnel CNAME automatically
- Full security context: `runAsNonRoot: true`, `runAsUser: 568`, `readOnlyRootFilesystem: true`, `capabilities.drop: ALL`
- Priority class: `network-critical`
- ServiceMonitor for metrics
- `reloader.stakater.com/auto: "true"` for secret rotation

### Best Practices

1. **Harden security context** — Run as non-root (UID 568), read-only filesystem, drop all capabilities. Cloudflared doesn't need root.
2. **Use DNSEndpoint for tunnel CNAME** — Automates tunnel DNS record creation via external-dns CRD source. Avoids manual Cloudflare API calls.
3. **Set priority class** — `network-critical` or equivalent ensures cloudflared survives node pressure.
4. **Add readiness probe** — Liveness alone isn't sufficient. Readiness prevents traffic routing to unready pods.
5. **Consider auth/noauth separation** — Separate tunnels for authenticated services (with Cloudflare Access) vs public services. Adds defense in depth.
6. **Route to HTTPS gateway** — If Gateway has TLS, route cloudflared to `https://` gateway service for end-to-end encryption.

### Gaps in Our Setup
- No security hardening (runs as root, writable filesystem)
- Manual tunnel DNS management (Cloudflare API instead of DNSEndpoint)
- No readiness probe
- No priority class
- Single tunnel for all traffic (no auth separation)
- Routes to HTTP (not HTTPS) gateway

---

## 4. external-dns

### Our Setup
- Chart **1.16.1**, single instance (Cloudflare only)
- Sources: `gateway-httproute`, `gateway-grpcroute`, `gateway-tlsroute`, `service`, `crd`
- No `--gateway-label-filter`
- No `--cloudflare-proxied` flag
- No monitoring

### Reference
- Chart **1.20.0**, TWO instances (Cloudflare + UniFi)
- Cloudflare instance: `--cloudflare-proxied`, `--gateway-label-filter=...registry=cloudflare`, CRD source
- UniFi instance: webhook provider (`ghcr.io/kashalls/external-dns-unifi-webhook`), `--gateway-label-filter=...registry=unifi`
- Both: `triggerLoopOnEvent: true`, ServiceMonitor, PrometheusRule (stale sync alert)
- Secret reloader annotations

### Best Practices

1. **Use `--gateway-label-filter`** — Label gateways with `external-dns.alpha.kubernetes.io/registry: cloudflare` and filter. This prevents external-dns from generating A records for every HTTPRoute, solving the tunnel CNAME conflict.
2. **Enable `--cloudflare-proxied`** on the Cloudflare instance — When combined with gateway label filtering, all records from the external gateway are proxied through Cloudflare. LAN-only records go through a separate gateway/DNS provider.
3. **Add `triggerLoopOnEvent: true`** — Makes external-dns react immediately to resource changes instead of waiting for the poll interval.
4. **Consider a second DNS provider for LAN** — UniFi, Pi-hole, or k8s_gateway can provide local DNS resolution. Without it, LAN access depends on Cloudflare DNS records, which may not resolve private IPs when proxied.
5. **Add monitoring** — PrometheusRule for stale sync detection catches external-dns failures early.
6. **Use DNSEndpoint CRD for tunnel records** — Only way to create proxied CNAME records to cfargotunnel.com without conflicting with A records.

### Gaps in Our Setup
- Single instance can't differentiate LAN vs tunnel DNS
- No gateway label filter causes A-record-vs-CNAME conflicts for tunnel services
- No `--cloudflare-proxied` flag
- No event-triggered sync
- No monitoring

---

## 5. External Secrets (1Password Connect)

### Our Setup
- External Secrets **0.14.4**, 1Password Connect chart **2.4.1**
- Bootstrap secret via SOPS-encrypted file
- ClusterSecretStore in separate Kustomization (split from operator)
- Basic config, no monitoring

### Reference
- External Secrets **2.1.0**, 1Password via app-template
- Image tags pinned to SHA256 digests
- Full security hardening (non-root, read-only FS, dropped caps)
- Priority class: `control-plane-critical`
- ServiceMonitor on all controllers
- ClusterExternalSecret for distributing secrets to all namespaces (e.g., GHCR pull secret)
- CEL health check expressions on Kustomizations

### Best Practices

1. **Upgrade External Secrets** — 0.14.4 → 2.1.0 is a major jump. The newer version has significant stability improvements and new features.
2. **Pin images with SHA256** — Prevents supply chain attacks. 1Password Connect images should use `tag@sha256:...` format.
3. **Set priority class** — `control-plane-critical` ensures secret management survives node pressure. Without it, pod eviction breaks all ExternalSecrets.
4. **Add health probes** — 1Password Connect should have liveness (`/heartbeat`) and readiness (`/health`) probes.
5. **Use ConfigMap for Helm values** — Separates values from HelmRelease, enabling kustomize patches.
6. **Split operator from CRD** — We already do this (external-secrets vs external-secrets-store). This is correct — the CRD needs the operator running first.

### Gaps in Our Setup
- Severely outdated chart (15+ minor versions behind)
- No image pinning
- No security hardening on 1Password Connect
- No monitoring
- No priority class

---

## 6. Rook-Ceph

### Our Setup
- Operator + cluster chart **1.16.5**, Ceph **v19.2.2**
- 3 mons (CP toleration), 1 mgr, 2 OSDs on `/dev/vdb` (w-01, w-02)
- Host networking, `allowMultiplePerNode: false`
- Block pool: replication 2, features: `layering` only
- StorageClass `ceph-block`: Retain, not default
- No CephFS, no Object Store, no toolbox
- No monitoring, no dashboard ingress

### Reference
- Operator + cluster **v1.19.2**
- CSI liveness + ServiceMonitor enabled, discovery daemon
- All components on control-plane nodes
- Network: host with public/cluster address ranges, msgr2 required
- Block pool: replication 3, features: `layering,exclusive-lock,object-map,fast-diff,deep-flatten`
- StorageClass `ceph-block`: Delete, default, fstype ext4
- CephFileSystem (3x replicated, MDS active+standby)
- CephObjectStore (erasure coded 2+1, S3 gateway)
- Dashboard with Prometheus + Alertmanager + Grafana integration, ingress via Tailscale
- Toolbox enabled, PrometheusRules with custom alert patches
- CSI read affinity, pg_autoscaler module

### Best Practices

1. **Add RBD image features** — `exclusive-lock,object-map,fast-diff,deep-flatten` in addition to `layering`. These enable efficient snapshots, cloning, and space reclamation. Critical for Volsync backup performance.
2. **Enable toolbox** — `toolbox.enabled: true` provides `ceph` CLI access for debugging without `kubectl exec` into operator pod with keyring flags.
3. **Add monitoring** — Enable `monitoring.enabled: true` and `createPrometheusRules: true`. Ceph health issues are silent without alerting.
4. **Enable CSI read affinity** — `csi.readAffinity.enabled: true` localizes reads to the same node, reducing network latency.
5. **Set block pool as default StorageClass** — If Ceph is the primary storage, `isDefault: true` simplifies PVC creation.
6. **Use Delete reclaim policy for block pool** — `Retain` prevents PV cleanup and causes orphaned volumes. Use `Delete` for block pool (Volsync handles backup/restore).
7. **Consider increasing replication to 3** — With only 2 OSDs, replication 2 means zero redundancy during OSD failure. Add a third worker or accept the risk.
8. **Define network address ranges** — `addressRanges.public` and `addressRanges.cluster` separate client and replication traffic.
9. **Enable mgr modules** — `pg_autoscaler` auto-tunes placement group counts. `insights` helps with support.

### Gaps in Our Setup
- Minimal RBD features (missing fast-diff, deep-flatten needed for Volsync)
- No toolbox (debugging requires complex exec commands)
- No monitoring (Ceph health warnings go unnoticed)
- No CSI read affinity
- Replication 2 has no redundancy during single OSD failure
- No network segmentation
- `Retain` reclaim policy accumulates orphaned PVs

---

## 7. Volsync (Backups)

### Our Setup
- Chart **0.11.0**, empty values
- ReplicationSource: every 6h, retain daily:7/weekly:4/monthly:3
- Restic to Garage S3 (`192.168.50.177:3900/homelab`)
- Component pattern with variable substitution
- **No ReplicationDestination** (no restore support)
- No monitoring

### Reference
- Chart **0.15.0**, priority class `storage-critical`
- ReplicationSource: every 4h, retain hourly:24/daily:7
- Restic to Backblaze B2
- Component includes ReplicationDestination + PVC with `dataSourceRef`
- Mover security context (`runAsUser: 568`)
- PrometheusRule: `VolSyncComponentAbsent`, `VolSyncVolumeOutOfSync`

### Best Practices

1. **Add ReplicationDestination template** — Without this, restore requires manual YAML creation. The component should include a ReplicationDestination with `trigger.manual: restore-once`.
2. **Add PVC with dataSourceRef** — The PVC template should reference the ReplicationDestination as `dataSourceRef`. On first boot (fresh cluster), Volsync auto-restores from the last backup.
3. **Set mover security context** — `runAsUser/runAsGroup/fsGroup: 568` prevents permission issues with backed-up files.
4. **Add monitoring** — `VolSyncVolumeOutOfSync` alert catches backup failures. Silent failures mean data loss.
5. **Enable `enableFileDeletion: true`** on ReplicationDestination — Allows restore to remove files not in the backup (clean state).
6. **Include hourly retention** — `hourly: 24` provides recent recovery points. Monthly-only retention has large gaps.
7. **Set `cleanupCachePVC: true` and `cleanupTempPVC: true`** — Prevents storage leak from orphaned cache PVCs during restore.

### Gaps in Our Setup
- No restore capability (critical gap — backups are useless without restore)
- No monitoring (backup failures go undetected)
- No mover security context (permission issues possible)
- Outdated chart (0.11.0 vs 0.15.0)
- No PVC dataSourceRef (manual restore on fresh cluster)

---

## 8. Spegel (OCI Registry Mirror)

### Our Setup
- **Not installed**

### Reference
- Chart **0.6.0**, ServiceMonitor + Grafana dashboard
- Containerd socket: `/run/containerd/containerd.sock`
- Registry config path: `/etc/cri/conf.d/hosts` (Talos-specific)
- Host port: 29999

### Best Practices

1. **Install Spegel** — Reduces external bandwidth, speeds up image pulls across nodes, and provides resilience during registry outages.
2. **Talos-specific config** — `containerdRegistryConfigPath: /etc/cri/conf.d/hosts` is required for Talos Linux. Standard K8s uses `/etc/containerd/certs.d`.
3. **Use host port 29999** — Default that doesn't conflict with other services.

### Gap
- Missing entirely. Low priority but recommended for larger clusters or limited bandwidth.

---

## 9. ingress-nginx

### Our Setup
- **Not installed** — Using Cilium Gateway API instead

### Reference
- Uses ingress-nginx as legacy ingress alongside Gateway API

### Best Practices

We chose Cilium Gateway API over ingress-nginx, which is the more modern approach. Gateway API provides:
- Native L7 routing without extra controllers
- Direct integration with Cilium's eBPF dataplane
- Multi-tenant gateway support
- gRPC and TLS routing

**No action needed** — Our approach is correct and forward-looking. Gateway API supersedes Ingress for new deployments.

---

## Summary: Priority Actions

### Critical (data safety)
1. Add Volsync ReplicationDestination + PVC template (enable restore)
2. Add RBD image features (`fast-diff`, `deep-flatten` for Volsync snapshots)

### High (reliability)
3. Add HTTPS listener to Gateway + wildcard certificate
4. Create internal + external Gateways with label-based DNS routing
5. Upgrade External Secrets (0.14.4 → 2.x)
6. Add monitoring/PrometheusRules for cert-manager, Ceph, Volsync, external-dns

### Medium (security + operations)
7. Harden cloudflared security context (non-root, read-only FS)
8. Enable Ceph toolbox
9. Add DNSEndpoint CRD for tunnel DNS automation
10. Pin 1Password Connect images with SHA256

### Low (optimization)
11. Install Spegel for image caching
12. Enable Cilium DSR + Maglev load balancing
13. Add BGP peering (if router supports it)
14. Upgrade Cilium to 1.19.x for BPF enhancements
