# ---------- Dual Pools ----------
# SSD pool for control-planes
resource "libvirt_pool" "cp" {
  name = var.cp_pool_name
  type = "dir"
  target { path = var.cp_pool_path }
}

# NVMe pool for workers
resource "libvirt_pool" "wk" {
  name = var.wk_pool_name
  type = "dir"
  target { path = var.wk_pool_path }
}

# ---------- Base Talos images (one per pool) ----------
resource "libvirt_volume" "talos_base_ssd" {
  name   = "talos-base.qcow2"
  pool   = libvirt_pool.cp.name
  source = local.talos_image_local_path
}

resource "libvirt_volume" "talos_base_ultra" {
  name   = "talos-base.qcow2"
  pool   = libvirt_pool.wk.name
  source = local.talos_image_local_path
}

# ---------- Control-plane VMs (on SSD) ----------
module "controlplanes" {
  source    = "./modules/libvirt-talos-vm"
  providers = { libvirt = libvirt }
  for_each  = var.controlplanes

  pool_name      = libvirt_pool.cp.name
  name           = each.value.name
  vcpu           = var.cp_vcpu
  memory_mb      = var.cp_memory_mb
  root_size_gb   = var.cp_disk_gb
  base_volume_id = libvirt_volume.talos_base_ssd.id
  bridge_name    = var.bridge_name
  mac_address    = each.value.mac

  # control-planes have no extra data disk
  extra_data_size_gb = 0
}

# ---------- Worker VMs (on NVMe) ----------
module "workers" {
  source    = "./modules/libvirt-talos-vm"
  providers = { libvirt = libvirt }
  for_each  = var.workers

  pool_name      = libvirt_pool.wk.name
  name           = each.value.name
  vcpu           = var.wk_vcpu
  memory_mb      = var.wk_memory_mb
  root_size_gb   = var.wk_disk_gb # set to 160 in tfvars
  base_volume_id = libvirt_volume.talos_base_ultra.id
  bridge_name    = var.bridge_name
  mac_address    = each.value.mac

  # add a fast extra data disk (e.g. 180GB) on each worker
  extra_data_size_gb = var.wk_data_gb
}

output "dhcp_reservations" {
  value = {
    controlplanes = { for k, v in var.controlplanes : v.name => { ip = v.ip, mac = v.mac } }
    workers       = { for k, v in var.workers : v.name => { ip = v.ip, mac = v.mac } }
  }
  description = "Use these MAC/IP pairs to create DHCP reservations on your router."
}
