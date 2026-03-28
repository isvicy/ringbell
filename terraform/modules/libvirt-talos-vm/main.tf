resource "libvirt_volume" "root" {
  name           = "${var.name}-root.qcow2"
  pool           = var.pool_name
  base_volume_id = var.base_volume_id
  size           = var.root_size_gb * 1024 * 1024 * 1024
}

# optional data disk
resource "libvirt_volume" "data" {
  count = var.extra_data_size_gb > 0 ? 1 : 0
  name  = "${var.name}-data.qcow2"
  pool  = var.pool_name
  size  = var.extra_data_size_gb * 1024 * 1024 * 1024
}

resource "libvirt_volume" "data2" {
  count = var.extra_data2_size_gb > 0 ? 1 : 0
  name  = "${var.name}-data2.qcow2"
  pool  = var.extra_data2_pool_name
  size  = var.extra_data2_size_gb * 1024 * 1024 * 1024
}

resource "libvirt_domain" "vm" {
  name   = var.name
  vcpu   = var.vcpu
  memory = var.memory_mb

  cpu { mode = "host-passthrough" }
  machine    = "q35"
  autostart  = true
  qemu_agent = true

  network_interface {
    bridge = var.bridge_name
    mac    = var.mac_address
  }

  # root disk
  disk { volume_id = libvirt_volume.root.id }

  # optional data disk
  dynamic "disk" {
    for_each = var.extra_data_size_gb > 0 ? [1] : []
    content {
      volume_id = libvirt_volume.data[0].id
    }
  }

  # data2 disk is attached via virsh (not Terraform) to avoid VM recreation
  # See: virsh attach-disk <vm> <path> vdc --persistent

  lifecycle {
    ignore_changes = [disk]
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }
}

output "domain_name" { value = libvirt_domain.vm.name }
output "mac" { value = var.mac_address }
