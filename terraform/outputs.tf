# Build a talosconfig (provider v0.9 uses client_configuration input)
data "talos_client_configuration" "local" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.cluster.client_configuration
  endpoints            = [for _, n in var.controlplanes : n.ip]
  nodes = concat(
    [for _, n in var.controlplanes : n.ip],
    [for _, n in var.workers : n.ip]
  )
}

resource "local_sensitive_file" "talosconfig" {
  filename = "${path.module}/../talosconfig"
  content  = data.talos_client_configuration.local.talos_config
}

output "talosconfig" {
  value     = data.talos_client_configuration.local.talos_config
  sensitive = true
}
