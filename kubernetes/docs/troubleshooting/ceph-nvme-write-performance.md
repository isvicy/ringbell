# Ceph NVMe Write Performance on Virtualized Storage

Date: 2026-03-29
Host: Unraid with Intel Optane P4800X (750GB NVMe, 550K+ IOPS capable)
Stack: KVM/QEMU 9.2 → Talos Linux → Rook-Ceph v1.16.5 (Squid v19.2.2) → BlueStore

## Problem

ceph-block sequential write throughput was 15 MB/s. The host NVMe does 1,360 MB/s direct — a 90x gap that cannot be explained by Ceph replication (2x) or virtualization overhead (~20-30%).

Random write IOPS was 154. The host does 18,599.

## Investigation Method

Used `fio` benchmarks at three layers to isolate the bottleneck:

1. **Host direct** — `ssh unraid` + fio on `/mnt/ultra` (ZFS on NVMe)
2. **K8s storage class** — fio Job with PVC per storage class
3. **Unraid individual disks** — fio on each `/mnt/disk*`

Benchmark script: `hack/disk-bench.sh` (not committed, disposable)

Test profiles: seq-read, seq-write, rand-read-4k, rand-write-4k, mixed-rw-4k (70/30). Each: 4G file, 30s runtime, `direct=1`, libaio.

## Root Causes Found (in order of discovery)

### 1. BlueStore misidentified NVMe as HDD

**Symptom:** `ceph osd metadata osd.0` showed `rotational: "1"`, `bdev_type: "hdd"`.

**Why:** NVMe host disk is presented to VMs as virtio `/dev/vdb`. The virtio-blk driver doesn't pass through the NVMe rotational flag, so the kernel reports `rotational=1`. BlueStore reads this at OSD creation and applies HDD-tuned defaults.

**Impact:** BlueStore used conservative HDD I/O scheduling, wrong cache sizes, wrong deferred write settings.

**Fix:**
```yaml
# Talos worker machine config (terraform/templates/worker_patch.yaml)
machine:
  udev:
    rules:
      - ACTION=="add|change", KERNEL=="vd[b-z]", SUBSYSTEM=="block", ATTR{queue/rotational}="0"
```

Plus runtime config overrides:
```bash
ceph config set osd osd_memory_target 3758096384
ceph config set osd bluestore_cache_autotune true
ceph config set osd osd_op_num_threads_per_shard 2
ceph config set osd osd_op_num_shards 8
```

**Result:** Rand read 4,665 → 23,488 IOPS (+403%). Seq write 15 → 34 MB/s.

### 2. QEMU disk cache defaulting to writethrough

**Symptom:** Host `iostat` showed 96.9% IOUtil at only 28 MB/s write throughput.

**Why:** libvirt VM XML had bare `<driver name='qemu' type='qcow2'/>` with no cache mode. Libvirt defaults to `cache=writethrough`, which forces `fdatasync()` after every write. Each 1M sequential write becomes: write data → fdatasync → update qcow2 metadata → fdatasync. This turns the NVMe into a flush-bound device.

**How we found it:** `virsh dumpxml w-01` showed zero driver options. Cross-referenced with QEMU docs on default cache behavior.

**Fix:** Set `cache='writeback'` — buffers writes in host RAM, only flushes when guest explicitly requests it.

**Result:** Seq write 34 → 51 MB/s.

### 3. qcow2 format on ZFS (double copy-on-write)

**Symptom:** Write performance still far below expectations even with writeback cache.

**Why:** qcow2 is a copy-on-write format (cluster allocation, L2 tables, refcounts). ZFS is also copy-on-write. Together they create a write amplification chain: each guest write triggers qcow2 cluster allocation + metadata updates, each of which triggers ZFS CoW block writes + indirect block updates + space map updates. The data disks were thin-provisioned (2.9G actual / 180G virtual), so nearly every write hit unallocated qcow2 clusters — worst case for this double-CoW pattern.

**How we found it:** Research on qcow2 write amplification, confirmed by: Ceph upstream docs explicitly say "Using QCOW2 for hosting a virtual machine disk is NOT recommended."

**Fix:** Converted data disks from qcow2 to raw:
```bash
# VM must be stopped
qemu-img convert -f qcow2 -O raw -t writeback /path/to/data.qcow2 /path/to/data.raw
# Update VM XML: type='raw', new source path
```

Root disks kept as qcow2 (need backing chain for base image).

**Result:** Seq write 51 → 71 MB/s. Raw files on ZFS are sparse — same thin-provisioning behavior without the metadata overhead.

### 4. ZFS default recordsize too large

**Symptom:** Diminishing returns from I/O path optimizations.

**Why:** ZFS default `recordsize=128K`. BlueStore's `max_blob_size_ssd=65536` (64K). A 64K write into a 128K ZFS record triggers read-modify-write: read 128K → modify 64K → COW-write 128K. This is 2x write amplification at the ZFS layer.

**Fix:** Created a dedicated ZFS dataset for Ceph data disks:
```bash
zfs create -o recordsize=64K -o primarycache=metadata \
  -o atime=off -o logbias=throughput ultra/ceph-data
```

- `recordsize=64K` — matches BlueStore max_blob_size, eliminates partial-record RMW
- `primarycache=metadata` — prevents ZFS ARC from double-caching what BlueStore already caches
- `sync=standard` (kept default) — Optane makes ZIL trivially fast (~10µs); `cache=writeback` already makes regular writes async

### 5. No QEMU iothreads, wrong AIO backend

**Symptom:** All disk I/O running on QEMU main thread with POSIX AIO.

**Why:** Default QEMU config has no `<iothreads>` element and uses `io=threads` (POSIX AIO thread pool). This serializes I/O through the main event loop and adds context-switching overhead.

**Fix:**
```xml
<iothreads>2</iothreads>
<cputune>
  <iothreadpin iothread='1' cpuset='32'/>
  <iothreadpin iothread='2' cpuset='33'/>
</cputune>
<disk ...>
  <driver name='qemu' type='raw' cache='writeback' io='io_uring' iothread='1' .../>
</disk>
```

- `io_uring` — kernel-native async I/O, non-blocking, works with `cache=writeback` on ZFS
- `iothread` — dedicated thread per disk, off the main QEMU event loop
- CPU pinning to HT siblings avoids vCPU contention (host has 64 CPUs)

### 6. OSD memory limit too low

**Symptom:** Ceph docs warn "setting osd_memory_target below 2GB is not recommended. Extremely slow performance is likely." OSD pods had 2Gi limit.

**Fix:** In `rook-ceph-cluster` HelmRelease:
```yaml
resources:
  osd:
    requests:
      cpu: 500m
      memory: 2Gi
    limits:
      memory: 4Gi
```

Plus: `ceph config set osd osd_memory_target 3758096384` (3.5GB, safe in 4Gi container).

## What Did NOT Help

| Attempt | Why it didn't help |
|---------|-------------------|
| `cache=none` + `io=native` | Bypassed all caching including qcow2/ZFS metadata cache. Reads degraded 10x because every I/O needed an uncached L2 table lookup. |
| `sync=disabled` on ZFS | QEMU `cache=writeback` already makes regular writes async (buffered I/O, no O_SYNC). Only guest flushes hit the ZIL, and Optane makes ZIL ~free. Near-zero benefit with added crash risk. |
| PCI passthrough | P4800X has no SR-IOV. Can't share one NVMe across 2 VMs. Would break 2-replica Ceph pool. |

## Final Results

```
ceph-block (NVMe, 2x replication, direct=1)

                    Before    After    Improvement
Seq Read  (MB/s)      943    1,367      +45%
Seq Write (MB/s)       15      102      +580% (6.8x)
Rand Read (IOPS)    4,665   25,179      +440% (5.4x)
Rand Write (IOPS)     154      702      +356% (4.6x)
Mixed R   (IOPS)      425    1,475      +247% (3.5x)
Mixed W   (IOPS)      181      629      +247% (3.5x)
Read latency (ms)    6.85     1.26      -82%
Write latency (ms)   1036       46      -96%
```

### 7. Ceph pool size:2 → size:1 (eliminated redundant replication)

**Symptom:** After all I/O path optimizations, writes were still 5-7% of host NVMe. The remaining gap was Ceph replication.

**Why:** Both NVMe OSDs (osd.0 on w-02, osd.1 on w-01) are backed by the **same physical P4800X**. With `size: 2`, every write traverses the full virtualized I/O path twice plus a network round-trip between VMs. This replication provides zero actual durability benefit — if the NVMe dies, both copies are lost.

**Fix:** Set `ceph-blockpool` to `size: 1`:
```yaml
cephBlockPools:
  - name: ceph-blockpool
    spec:
      failureDomain: osd
      replicated:
        size: 1
        requireSafeReplicaSize: false
      deviceClass: nvme
```

Disaster recovery relies on Volsync S3 backups to Garage. If a second host with its own NVMe is added later, bump back to `size: 2` with real cross-host durability.

**Result:** Rand write 253 → 702 IOPS (+177%). Seq write 79 → 102 MB/s (+28%). Write latency 126ms → 46ms (-64%).

### 8. Replaced ceph-block with local-path-provisioner (eliminated Ceph from NVMe path)

**Symptom:** Even with all optimizations, Ceph-in-VM seq write was 102 MB/s vs host NVMe's 1,360 MB/s. The Ceph+BlueStore+virtio stack has inherent overhead that can't be eliminated.

**Why:** The Ceph data path (BlueStore → RBD → CSI → virtio → QEMU → ZFS → NVMe) adds multiple layers of overhead even for size:1 replication. For a homelab with a single physical NVMe, Ceph provides no benefit for fast storage — its replication, journaling, and metadata management only add latency.

**Fix:** Replaced ceph-block with local-path-provisioner:
1. Removed NVMe OSDs from Ceph, deleted ceph-blockpool
2. Formatted /dev/vdb as XFS filesystem via Talos `machine.disks`
3. Deployed Rancher local-path-provisioner with StorageClass `local-nvme`
4. Migrated all apps (authelia, harbor DB/redis/trivy, prometheus, alertmanager) to `local-nvme`
5. Ceph retained only for HDD bulk storage (`ceph-bulk`)

**Result:** Seq write 102 → 1,807 MB/s (+1,672%). Rand write 702 → 7,063 IOPS (+906%).

## Final Results (complete journey)

```
NVMe storage: ceph-block (original) → local-nvme (final)

                    Before    After     Improvement
Seq Read  (MB/s)       943    2,558       +171% (2.7x)
Seq Write (MB/s)        15    1,807     +11,947% (120x)
Rand Read (IOPS)     4,665   21,452       +360% (4.6x)
Rand Write (IOPS)      154    7,063      +4,487% (46x)
Mixed R   (IOPS)       425   11,552      +2,618% (27x)
Mixed W   (IOPS)       181    4,967      +2,644% (27x)
```

## Files Changed

| File | Change |
|------|--------|
| `terraform/templates/worker_patch.yaml` | Added udev rule, machine.disks for /var/mnt/nvme, kubelet.extraMounts |
| `kubernetes/apps/storage/rook-ceph-cluster/app/helmrelease.yaml` | Removed ceph-blockpool + NVMe OSDs, OSD memory 4Gi |
| `kubernetes/apps/storage/local-path-provisioner/` | New app: local-path-provisioner with `local-nvme` StorageClass |
| `kubernetes/apps/storage/kustomization.yaml` | Added local-path-provisioner |
| `kubernetes/apps/auth/authelia/app/helmrelease.yaml` | StorageClass → local-nvme |
| `kubernetes/apps/registry/harbor/app/helmrelease.yaml` | StorageClass → local-nvme (DB, Redis, Trivy, JobLog) |
| `kubernetes/apps/observability/kube-prometheus-stack/app/helmrelease.yaml` | StorageClass → local-nvme |
| `kubernetes/apps/default/e2e-test/app/pvc.yaml` | StorageClass → local-nvme |
| `kubernetes/components/volsync/` | Default StorageClass → local-nvme |
| `terraform/main.tf` | Removed NVMe data disk from Terraform (managed by Talos) |
| `CLAUDE.md` | Added safety rule: verify container image tags before use |
| VM XML (virsh, not in git) | raw format, cache=writeback, io_uring, iothreads, 4K block alignment |
| ZFS (Unraid host, not in git) | `ultra/ceph-data` dataset with recordsize=64K, primarycache=metadata |

## Key Takeaways

1. **For maximum NVMe performance on a single host, skip Ceph entirely.** local-path-provisioner gives 120x better seq write than Ceph RBD. Use Ceph only when real cross-host replication is needed.
2. **Always check `ceph osd metadata` for `rotational` and `bdev_type`** on virtualized setups. virtio-blk never reports correct rotation.
3. **Never use qcow2 for VM data disks on ZFS.** Double CoW is a performance killer. Use raw files or direct partitions.
4. **Never leave libvirt disk driver at defaults.** The default `cache=writethrough` forces fdatasync per write — use `cache=writeback` + `io=io_uring` + iothreads.
5. **Match ZFS recordsize to workload.** 64K for block storage workloads.
6. **Don't replicate across VMs on the same physical disk.** Both copies are lost together. Use `size: 1` + backups instead.
7. **Don't `kubectl apply` GitOps-managed resources.** It conflicts with Flux reconciliation and creates resources in wrong namespaces. Always commit+push and let Flux handle it.
8. **StatefulSet volumeClaimTemplates are immutable.** To change storageClass, delete the STS and PVCs first, then let Helm recreate them.
