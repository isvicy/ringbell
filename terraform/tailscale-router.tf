# ---------- Tailscale Subnet Routers (Debian 12 cloud-init VMs) ----------

resource "libvirt_volume" "debian_base" {
  name   = "debian-12-generic-base.qcow2"
  pool   = libvirt_pool.cp.name
  source = local.debian_image_local_path
}

resource "libvirt_volume" "ts_router_root" {
  for_each = var.ts_routers

  name           = "${each.key}-root.qcow2"
  pool           = libvirt_pool.cp.name
  base_volume_id = libvirt_volume.debian_base.id
  size           = 4 * 1024 * 1024 * 1024 # 4 GB
}

resource "libvirt_cloudinit_disk" "ts_router" {
  for_each = var.ts_routers

  name = "${each.key}-cloudinit.iso"
  pool = libvirt_pool.cp.name

  user_data = templatefile("${path.module}/templates/ts_router_user_data.yaml.tmpl", {
    hostname           = each.key
    tailscale_auth_key = var.tailscale_auth_key
    ssh_pub_key        = trimspace(file("~/.ssh/id_ed25519.pub"))
    routes             = join(",", each.value.routes)
    accept_routes      = each.value.accept_routes
    ip_rule_bypass     = each.value.ip_rule_bypass
  })

  meta_data = yamlencode({
    instance-id    = each.key
    local-hostname = each.key
  })

  network_config = yamlencode({
    version = 2
    ethernets = {
      mainif = merge(
        {
          match       = { macaddress = each.value.mac }
          addresses   = ["${each.value.ip}/24"]
          gateway4    = each.value.gateway
          nameservers = { addresses = each.value.dns }
        },
        each.value.ipv6 ? {
          accept-ra    = true
          dhcp6        = true
          ipv6-privacy = false
        } : {},
        length(each.value.static_routes) > 0 ? {
          routes = [for r in each.value.static_routes : { to = r.dest, via = r.via }]
        } : {},
      )
    }
  })
}

resource "libvirt_domain" "ts_router" {
  for_each = var.ts_routers

  name      = each.key
  vcpu      = 1
  memory    = 512
  autostart = true

  cpu { mode = "host-passthrough" }

  cloudinit = libvirt_cloudinit_disk.ts_router[each.key].id

  network_interface {
    bridge = each.value.bridge
    mac    = each.value.mac
  }

  disk { volume_id = libvirt_volume.ts_router_root[each.key].id }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }
}

output "ts_routers_info" {
  value = { for k, v in var.ts_routers : k => {
    ip     = v.ip
    mac    = v.mac
    bridge = v.bridge
    routes = v.routes
  } }
}
