resource "libvirt_volume" "root" {
  name           = "${var.name}-root.qcow2"
  pool           = var.pool_name
  base_volume_id = var.base_volume_id
  size           = var.root_size_gb * 1024 * 1024 * 1024
}

resource "libvirt_domain" "vm" {
  name   = var.name
  vcpu   = var.vcpu
  memory = var.memory_mb

  cpu { mode = "host-passthrough" }
  machine = "q35"

  autostart = true
  # NOTE: If you built a Talos image with qemu-guest-agent, you may set qemu_agent = true
  qemu_agent = false

  network_interface {
    bridge = var.bridge_name
    mac    = var.mac_address
  }

  disk {
    volume_id = libvirt_volume.root.id
    # bus defaults to virtio
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }
}

output "domain_name" { value = libvirt_domain.vm.name }
output "mac"         { value = var.mac_address }
