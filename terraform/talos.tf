# Generate cluster secrets (PKI) once
resource "talos_machine_secrets" "cluster" {}

# Base machine configurations (Talos + K8s versions + API endpoint)
data "talos_machine_configuration" "controlplane" {
  cluster_name       = var.cluster_name
  machine_type       = "controlplane"
  talos_version      = var.talos_version
  cluster_endpoint   = "https://${var.api_vip}:6443"
  machine_secrets    = talos_machine_secrets.cluster.machine_secrets
  kubernetes_version = var.kubernetes_version
}

data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  machine_type       = "worker"
  talos_version      = var.talos_version
  cluster_endpoint   = "https://${var.api_vip}:6443"
  machine_secrets    = talos_machine_secrets.cluster.machine_secrets
  kubernetes_version = var.kubernetes_version
}

# Apply per-node configurations with patches:
# - Static IP + hostname
# - Disable embedded CNI (set CNI: none)
# - On control-planes, install kube-vip as a static pod exposing the API VIP
resource "talos_machine_configuration_apply" "cp" {
  for_each                    = var.controlplanes
  node                        = each.value.ip
  endpoint                    = each.value.ip
  client_configuration        = talos_machine_secrets.cluster.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  config_patches = [
    templatefile("${path.module}/templates/controlplane_network_patch.yaml.tmpl", {
      hostname      = each.value.name
      ip            = each.value.ip
      cidr          = var.cidr
      gateway       = var.gateway
      api_vip       = var.api_vip
      vip_interface = var.vip_interface
      dns1          = var.dns_servers[0]
      dns2          = length(var.dns_servers) > 1 ? var.dns_servers[1] : var.dns_servers[0]
    }),
    file("${path.module}/templates/controlplane_patch.yaml")
  ]

  depends_on = [module.controlplanes]
}

resource "talos_machine_configuration_apply" "wk" {
  for_each                    = var.workers
  node                        = each.value.ip
  endpoint                    = each.value.ip
  client_configuration        = talos_machine_secrets.cluster.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  config_patches = [
    templatefile("${path.module}/templates/worker_network_patch.yaml.tmpl", {
      hostname  = each.value.name
      ip        = each.value.ip
      cidr      = var.cidr
      gateway   = var.gateway
      interface = var.interface
      dns1      = var.dns_servers[0]
      dns2      = length(var.dns_servers) > 1 ? var.dns_servers[1] : var.dns_servers[0]
    }),
    file("${path.module}/templates/worker_patch.yaml")
  ]

  depends_on = [module.workers]
}

# Bootstrap etcd/Kubernetes on ONE control-plane (cp-01 by default)
resource "talos_machine_bootstrap" "bootstrap" {
  node                 = var.bootstrap_ip
  endpoint             = var.bootstrap_ip
  client_configuration = talos_machine_secrets.cluster.client_configuration
  depends_on           = [talos_machine_configuration_apply.cp]
}

# Retrieve kubeconfig after bootstrap
resource "talos_cluster_kubeconfig" "kube" {
  node                 = var.bootstrap_ip
  endpoint             = var.bootstrap_ip
  client_configuration = talos_machine_secrets.cluster.client_configuration
  depends_on           = [talos_machine_bootstrap.bootstrap]
}

output "kubeconfig" {
  value       = talos_cluster_kubeconfig.kube.kubeconfig_raw
  sensitive   = true
  description = "Write to file: terraform output -raw kubeconfig > ~/.kube/config"
}
