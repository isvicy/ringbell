# Troubleshooting Guide

Lessons learned from the initial cluster setup and the Phase 1-6 upgrade migration. Each issue includes root cause, symptoms, fix, and how to prevent it.

---

## 1. External Secrets Major Version Upgrade (CRD Incompatibility)

**Scenario:** Upgraded ESO chart from 0.14.4 to 2.2.0 in one jump.

**Symptoms:**
- HelmRelease stuck in failed/rollback loop for hours
- Error: `spec.conversion.strategy: Required value, spec.conversion.webhookClientConfig: Forbidden`
- Rollback error: `missing from spec.versions; v1 was previously a storage version`
- Controller crash: `no matches for kind "ExternalSecret" in version "external-secrets.io/v1"`

**Root Cause:** The ESO CRD format changed between 0.14.x and 2.x. The conversion webhook configuration is incompatible during in-place upgrade. Helm's `CreateReplace` tries to apply the new CRD atomically but Kubernetes rejects the intermediate state. Rollback also fails because new stored versions can't be removed.

**Fix:**
```bash
# 1. Manually apply 2.x CRDs via server-side apply (bypasses validation)
helm template external-secrets external-secrets/external-secrets \
  --version 2.2.0 --set installCRDs=true | \
  kubectl apply --server-side --force-conflicts -f -

# 2. If Helm release history is corrupted, delete it
flux suspend hr external-secrets -n security
kubectl -n security delete secret -l owner=helm,name=external-secrets
flux resume hr external-secrets -n security

# 3. Set crds: Skip in HelmRelease (CRDs are now manually managed)
```

**Prevention:**
- Never jump 15+ minor versions. Do incremental upgrades: 0.14 → 0.16 (v1beta1+v1 transition) → 2.x
- Or: manually apply target CRDs first, then bump the chart with `crds: Skip`
- Always update `apiVersion: external-secrets.io/v1beta1` → `v1` in all manifests before upgrading past 0.16.x

---

## 2. Flux Kustomize-Controller Stale CRD Cache

**Scenario:** After ESO CRDs were deleted and recreated, Flux health checks report resources as `NotFound` even though they exist.

**Symptoms:**
- Multiple KS stuck as `Unknown` with `Reconciliation in progress`
- Health check error: `ExternalSecret/cert-manager/cloudflare-api-token status: 'NotFound'`
- `kubectl get externalsecret -A` shows the resources exist and are `SecretSynced`
- Forcing `flux reconcile ks` doesn't help — same error after 5m timeout

**Root Cause:** The Flux kustomize-controller caches Kubernetes API resource discovery in memory. When CRDs are deleted and recreated, the API server invalidates its discovery endpoint, but the controller's in-memory cache is stale. It doesn't know ExternalSecret exists as a resource type anymore.

**Fix:**
```bash
kubectl -n flux-system rollout restart deployment kustomize-controller
```

**Prevention:**
- Avoid CRD deletion entirely — upgrade charts incrementally so CRDs are updated in-place
- If CRDs must be recreated, always restart the kustomize-controller afterward
- Reference: [fluxcd/flux2#2711](https://github.com/fluxcd/flux2/issues/2711)

---

## 3. PodSecurity Baseline Blocking Privileged Pods

**Scenario:** Pods requiring host access (hostNetwork, hostPID, hostPath, privileged) fail to create in namespaces with default PodSecurity.

**Symptoms:**
- DaemonSet/Deployment shows 0 pods scheduled
- Events: `violates PodSecurity "baseline:latest": host namespaces (hostNetwork=true, hostPID=true), hostPath volumes`
- Affected components: Rook-Ceph (mons, OSDs), Synology CSI (node DaemonSet), Prometheus node-exporter

**Root Cause:** Kubernetes enforces PodSecurity Standards per-namespace. The `baseline` level blocks host namespaces, hostPath, and privileged containers. Storage drivers and node-level monitoring require these capabilities.

**Fix:**
```bash
kubectl label namespace <ns> pod-security.kubernetes.io/enforce=privileged --overwrite
```
And persist in the namespace YAML:
```yaml
metadata:
  labels:
    pod-security.kubernetes.io/enforce: privileged
```

**Prevention:**
- Any namespace running: Rook-Ceph, CSI drivers, node-exporter, Spegel → needs `privileged` label
- Check before deploying by reviewing if the Helm chart uses `hostNetwork`, `hostPID`, `privileged`, or `hostPath`

**Affected namespaces in our cluster:** `storage`, `observability`, `kube-system`

---

## 4. StorageClass Parameters Are Immutable

**Scenario:** Added RBD image features (`fast-diff`, `deep-flatten`) to the ceph-block StorageClass via HelmRelease values.

**Symptoms:**
- HelmRelease fails: `StorageClass.storage.k8s.io "ceph-block" is invalid: parameters: Forbidden: updates to parameters are forbidden`
- Helm rolls back, but the old SC is already gone (or the new one can't apply)

**Root Cause:** Kubernetes StorageClass `.parameters` field is immutable after creation. The Helm chart tries to update the SC in-place but Kubernetes rejects it.

**Fix:**
```bash
# 1. Delete the old StorageClass
kubectl delete sc ceph-block

# 2. Clear the HelmRelease rollback state
flux suspend hr rook-ceph-cluster -n storage
flux resume hr rook-ceph-cluster -n storage

# 3. Helm recreates the SC with new parameters on next reconcile
```

**Prevention:**
- Know that SC parameters are immutable before adding/changing them
- Plan for the delete+recreate cycle when modifying: `imageFeatures`, `fstype`, CSI secret refs
- Existing PVCs continue to work — they reference the PV, not the SC

---

## 5. Rook-Ceph Custom Parameters Override Chart Defaults

**Scenario:** Added custom `parameters` block to ceph-block StorageClass in HelmRelease, but provisioning fails with "provided secret is empty".

**Symptoms:**
- PVC stuck in Pending
- Events: `failed to provision volume: rpc error: code = InvalidArgument desc = provided secret is empty`
- StorageClass missing `csi.storage.k8s.io/provisioner-secret-name` and related fields

**Root Cause:** The rook-ceph-cluster Helm chart has default SC parameters that include CSI secret references. When you specify a custom `parameters` block in values, it **replaces** the defaults entirely rather than merging. The CSI secret refs are lost.

**Fix:** Always include the full set of CSI parameters:
```yaml
parameters:
  imageFormat: "2"
  imageFeatures: layering,exclusive-lock,object-map,fast-diff,deep-flatten
  csi.storage.k8s.io/fstype: ext4
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: storage
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: storage
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: storage
```

**Prevention:** Always check the chart's default values before overriding a `parameters` map. Helm replaces maps, it doesn't merge them.

---

## 6. Rook-Ceph Mon Placement with Host Networking

**Scenario:** CephCluster with `network.provider: host` and `mon.allowMultiplePerNode: true` + 3 mons on a 5-node cluster (3 CP + 2 workers).

**Symptoms:**
- CephCluster stuck in `Progressing: Configuring Ceph Mons`
- Operator log: `refusing to deploy 3 monitors on the same host with host networking and allowMultiplePerNode is true`
- Then after fixing to `allowMultiplePerNode: false`: mon canary pods stuck, never created

**Root Cause:** Two compounding issues:
1. `allowMultiplePerNode: true` + `host` networking is an invalid combination (mons need unique IPs)
2. After fixing to `false`, mons need 3 different nodes, but CP nodes have `NoSchedule` taint — only 2 workers available

**Fix:**
```yaml
mon:
  count: 3
  allowMultiplePerNode: false
placement:
  mon:
    tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
```

**Prevention:** With host networking, always set `allowMultiplePerNode: false` and add CP tolerations if you need more mons than workers.

---

## 7. Cilium ServiceMonitor CRD Chicken-and-Egg

**Scenario:** Enabled `prometheus.serviceMonitor.enabled: true` on Cilium before the Prometheus operator (and its CRDs) was installed.

**Symptoms:**
- Cilium HelmRelease fails: `Service Monitor requires monitoring.coreos.com/v1 CRDs`
- Helm upgrade fails repeatedly, HR goes into rollback loop

**Root Cause:** The Cilium Helm chart validates that ServiceMonitor CRDs exist before rendering templates. Since kube-prometheus-stack isn't installed yet, the CRDs don't exist.

**Fix:** Add `trustCRDsExist: true` to skip the validation:
```yaml
prometheus:
  serviceMonitor:
    enabled: true
    trustCRDsExist: true
```

**Prevention:** When enabling ServiceMonitor/PrometheusRule on any chart, always add `trustCRDsExist: true` if the Prometheus CRDs might not exist yet.

---

## 8. Gateway API: Standard vs Experimental CRDs

**Scenario:** Cilium Gateway controller fails to reconcile Gateway resources.

**Symptoms:**
- Gateway status: `Waiting for controller`
- Cilium operator log: `no kind is registered for the type v1alpha2.TLSRouteList`

**Root Cause:** The standard Gateway API CRDs don't include `TLSRoute` (experimental channel only). Cilium's gateway controller requires TLSRoute to be registered.

**Fix:** Switch to experimental CRDs:
```yaml
# kubernetes/apps/networking/gateway-api/app/kustomization.yaml
resources:
  - https://github.com/kubernetes-sigs/gateway-api/config/crd/experimental?ref=v1.2.1
```
Then restart Cilium operator: `kubectl -n kube-system rollout restart deployment cilium-operator`

**Prevention:** Always use experimental Gateway API CRDs when using Cilium as the Gateway controller.

---

## 9. Cloudflared QUIC Timeout

**Scenario:** Cloudflared pods CrashLoopBackOff, can't connect to Cloudflare edge.

**Symptoms:**
- Log: `Failed to dial a quic connection error="timeout: no recent network activity"` on IPs `198.19.59.x`
- Retries with exponential backoff, eventually killed by liveness probe

**Root Cause:** QUIC uses UDP port 7844. Many home routers/ISPs silently drop UDP on non-standard ports.

**Fix:** Force HTTP/2 (TCP 7844):
```yaml
args:
  - tunnel
  - --config
  - /etc/cloudflared/config/config.yaml
  - --protocol
  - http2
  - run
```

**Prevention:** Default to `--protocol http2` in homelab environments. QUIC is only beneficial when UDP 7844 is not blocked.

---

## 10. External-DNS A/CNAME Conflict for Tunnel Services

**Scenario:** external-dns creates A records for ALL HTTPRoute hostnames. Tunnel-exposed services need a CNAME to `<uuid>.cfargotunnel.com`. Can't have both A and CNAME for the same hostname.

**Symptoms:**
- external-dns error: `Target 192.168.2.30 is not allowed for a proxied record (9003)`
- Or: external-dns creates A record that conflicts with manually-created tunnel CNAME

**Root Cause:** The `gateway-httproute` source always reads the Gateway's `.status.addresses` as the target IP. There's no per-HTTPRoute override for target. The `external-dns.alpha.kubernetes.io/target` annotation only works on the Gateway, not individual HTTPRoutes.

**Fix options:**
1. **Simple (our approach):** Manage tunnel CNAMEs via Cloudflare API/dashboard. External-dns handles LAN A records only.
2. **Proper (reference repo):** Dual gateway + dual external-dns with `--gateway-label-filter`. Tunnel DNS via `DNSEndpoint` CRD.

**Prevention:** Design the DNS strategy before deploying cloudflared. Choose between single-gateway (simpler, manual tunnel DNS) or dual-gateway (automated, more components).

---

## 11. Flux HelmRelease Stuck in Rollback Loop

**Scenario:** A Helm upgrade fails, triggering automatic rollback. The rollback also fails, creating an infinite loop.

**Symptoms:**
- HR status: `Helm rollback to previous release ... failed`
- `flux suspend hr` / `flux resume hr` doesn't clear the state
- HR keeps attempting rollback on every reconcile

**Root Cause:** When both upgrade and rollback fail (e.g., CRD incompatibility), the Helm release history accumulates failed entries. Flux can't move forward or backward.

**Fix:**
```bash
# Nuclear option: delete Helm release history and start fresh
flux suspend hr <name> -n <namespace>
kubectl -n <namespace> delete secret -l owner=helm,name=<release-name>
flux resume hr <name> -n <namespace>
```

**Prevention:**
- Test chart upgrades in a staging environment or dry-run first
- For major version jumps, manually apply CRDs before the chart upgrade
- Use `flux suspend hr` before risky changes so you can intervene manually

---

## 12. ClusterSecretStore Health Check with targetNamespace

**Scenario:** Flux KS for ClusterSecretStore (cluster-scoped) has `targetNamespace: security` and `wait: true`.

**Symptoms:**
- KS stuck as `Unknown: Reconciliation in progress` indefinitely
- The ClusterSecretStore is `Valid` and `Ready` when checked manually

**Root Cause:** Flux's health checker looks for the resource in the `targetNamespace`, but ClusterSecretStore is cluster-scoped (no namespace). The health check can't find it, times out, retries forever.

**Fix:** Set `wait: false` on the KS:
```yaml
spec:
  wait: false  # cluster-scoped resources don't need wait
```

**Prevention:** Always use `wait: false` for KS that create cluster-scoped resources (ClusterSecretStore, ClusterIssuer, ClusterRole, etc.) when `targetNamespace` is set.

---

## 13. Spegel Helm Repository Type

**Scenario:** Spegel chart configured as traditional HTTP HelmRepository.

**Symptoms:**
- HelmRepository status: `failed to fetch: 404 Not Found`

**Root Cause:** Spegel migrated from GitHub Pages Helm repo to OCI-only distribution via `ghcr.io`.

**Fix:**
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: spegel
spec:
  type: oci
  url: oci://ghcr.io/spegel-org/helm-charts
```

**Prevention:** Always check the upstream chart's distribution method. Many projects are migrating to OCI. Check ArtifactHub or the project's GitHub for the correct URL.

---

## Quick Reference: Flux Recovery Commands

```bash
# Clear stuck HelmRelease
flux suspend hr <name> -n <ns> && sleep 2 && flux resume hr <name> -n <ns>

# Nuclear: reset Helm release history
flux suspend hr <name> -n <ns>
kubectl -n <ns> delete secret -l owner=helm,name=<release-name>
flux resume hr <name> -n <ns>

# Refresh CRD cache after CRD changes
kubectl -n flux-system rollout restart deployment kustomize-controller

# Force reconcile from git
flux reconcile source git flux-system
flux reconcile ks <name>

# Check dependency chain
flux get ks -A  # look for "dependency X is not ready"
```

## Quick Reference: Ceph Commands via Operator

```bash
# All ceph commands require these flags:
CEPH="kubectl -n storage exec deploy/rook-ceph-operator -- ceph \
  --conf=/var/lib/rook/storage/storage.config \
  --keyring=/var/lib/rook/storage/client.admin.keyring"

$CEPH -s              # cluster status
$CEPH osd set noout   # before worker maintenance
$CEPH osd unset noout # after worker maintenance
```

After enabling the toolbox (`toolbox.enabled: true`), use:
```bash
kubectl -n storage exec -it deploy/rook-ceph-tools -- ceph -s
```
