# Argo CD GitOps root-of-trust bootstrap.
#
# Seeds the one secret Argo CD cannot derive from anything else — the 1Password
# Connect credentials — straight from `pass` into the cluster, WITHOUT persisting
# secret material in Terraform state (local-exec + kubectl, deliberately not a
# `kubernetes_secret` resource whose data would land in the Garage S3 backend).
# terraform_data + local-exec need no extra provider.
#
# The ringbell repo is public, so Argo clones it anonymously — no repo credential
# needed. Everything else flows from this secret: External Secrets uses it to
# serve every other secret from the 1Password "homelab" vault.
#
# Run on cluster genesis with KUBECONFIG pointing at the cluster
# (`terraform output -raw kubeconfig > /tmp/kc && export KUBECONFIG=/tmp/kc`).
# Re-seed after rotating the credential with:
#   terraform apply -replace=terraform_data.onepassword_connect_secret
#
# NOT on the live Flux->Argo migration path: the onepassword-connect Secret
# already exists in the running cluster (Flux created it from secret.sops.yaml).
# This makes a from-scratch rebuild reproducible. Before relying on it for a real
# rebuild, confirm the credential encoding matches the live Secret
# (`kubectl -n security get secret onepassword-connect -o yaml`).
resource "terraform_data" "onepassword_connect_secret" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      kubectl create namespace security --dry-run=client -o yaml | kubectl apply -f -
      kubectl create secret generic onepassword-connect -n security \
        --from-literal=1password-credentials.json="$(pass show homelab/connect-server/credential)" \
        --from-literal=token="$(pass show homelab/connect-server/token)" \
        --dry-run=client -o yaml | kubectl apply -f -
    EOT
  }
}
