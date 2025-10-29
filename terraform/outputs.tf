# Build a talosconfig using the v0.9 data source.
# NOTE: "client_configuration" (not machine_secrets) is required in v0.9.
data "talos_client_configuration" "local" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.cluster.client_configuration
  # Provide endpoints that the Talos CLI should use to reach the API.
  # Control-plane IPs are a good default; the VIP may not exist pre-bootstrap.
  endpoints = [for _, n in var.controlplanes : n.ip]
  # Optional but helpful: list all nodes (so talosctl has the full node set)
  nodes = concat(
    [for _, n in var.controlplanes : n.ip],
    [for _, n in var.workers : n.ip]
  )
}

# Persist the talosconfig so you can copy it into ~/.talos/config
resource "local_sensitive_file" "talosconfig" {
  filename = "${path.module}/../talosconfig"
  content  = data.talos_client_configuration.local.talos_config
}

output "talosconfig" {
  value     = data.talos_client_configuration.local.talos_config
  sensitive = true
}
