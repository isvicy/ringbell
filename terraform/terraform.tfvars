# Libvirt pools
cp_pool_name = "talos-ssd"
cp_pool_path = "/mnt/ssd/domains/talos"

wk_pool_name = "talos-ultra"
wk_pool_path = "/mnt/ultra/domains/talos"

# Libvirt
libvirt_uri            = "qemu+ssh://root@192.168.2.200/system?sshauth=privkey&keyfile=/home/isvicy/.ssh/id_ed25519&no_verify=1"
talos_image_local_path = "./images/talos-amd64.qcow2"

# Networking
bridge_name = "br0"
api_vip     = "192.168.2.20"
gateway     = "192.168.2.38"
dns_servers = ["198.18.0.2"]
cidr        = 24

# Nodes
controlplanes = {
  cp-01 = { name = "cp-01", ip = "192.168.2.21", mac = "52:54:00:aa:02:21" }
  cp-02 = { name = "cp-02", ip = "192.168.2.22", mac = "52:54:00:aa:02:22" }
  cp-03 = { name = "cp-03", ip = "192.168.2.23", mac = "52:54:00:aa:02:23" }
}

workers = {
  w-01 = { name = "w-01", ip = "192.168.2.24", mac = "52:54:00:aa:02:24" }
  w-02 = { name = "w-02", ip = "192.168.2.25", mac = "52:54:00:aa:02:25" }
}

# Sizing
cp_vcpu      = 4
cp_memory_mb = 16384
cp_disk_gb   = 80

wk_vcpu      = 8
wk_memory_mb = 32768
wk_disk_gb   = 160 # worker root on NVMe
wk_data_gb     = 180  # extra data disk on NVMe
wk_hdd_data_gb = 4096 # HDD-backed bulk storage disk

hdd_pools = {
  w-01 = { name = "talos-hdd1", path = "/mnt/disk1/domains/talos-hdd" }
  w-02 = { name = "talos-hdd2", path = "/mnt/disk2/domains/talos-hdd" }
}

# Talos/Kubernetes
talos_version      = "v1.12.6"
kubernetes_version = "1.35.3"
cluster_name       = "ringbell"
bootstrap_ip       = "192.168.2.21"
