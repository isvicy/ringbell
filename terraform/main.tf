# Storage pool for VM disks
resource "libvirt_pool" "talos" {
  name = var.pool_name
  type = "dir"
  target {
    path = var.pool_path
  }
}

# Base Talos image (download it to var.talos_image_local_path)
resource "libvirt_volume" "talos_base" {
  name   = "talos-base.qcow2"
  pool   = libvirt_pool.talos.name
  source = local.talos_image_local_path
}

# Control-plane VMs
module "controlplanes" {
  source         = "./modules/libvirt-talos-vm"
  providers      = { libvirt = libvirt }
  for_each       = var.controlplanes
  pool_name      = libvirt_pool.talos.name
  name           = each.value.name
  vcpu           = var.cp_vcpu
  memory_mb      = var.cp_memory_mb
  root_size_gb   = var.cp_disk_gb
  base_volume_id = libvirt_volume.talos_base.id
  bridge_name    = var.bridge_name
  mac_address    = each.value.mac
}

# Worker VMs
module "workers" {
  source         = "./modules/libvirt-talos-vm"
  providers      = { libvirt = libvirt }
  for_each       = var.workers
  pool_name      = libvirt_pool.talos.name
  name           = each.value.name
  vcpu           = var.wk_vcpu
  memory_mb      = var.wk_memory_mb
  root_size_gb   = var.wk_disk_gb
  base_volume_id = libvirt_volume.talos_base.id
  bridge_name    = var.bridge_name
  mac_address    = each.value.mac
}

output "dhcp_reservations" {
  value = {
    controlplanes = { for k, v in var.controlplanes : v.name => { ip = v.ip, mac = v.mac } }
    workers       = { for k, v in var.workers : v.name => { ip = v.ip, mac = v.mac } }
  }
  description = "Use these MAC/IP pairs to create DHCP reservations on your router (so Talos nodes come up at their static addresses)."
}
