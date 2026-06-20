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
# This makes a from-scratch rebuild reproducible.
#
# Verified 2026-06-20 against the live Secret (hash-compared, no secret printed):
#   - `token` reproduces BYTE-FOR-BYTE. ESO sends it in the Connect auth header
#     so exactness matters; `$()` correctly strips the trailing newline `pass`
#     stores, matching the live value.
#   - `1password-credentials.json` is a JSON object (deviceUuid / encCredentials /
#     uniqueKey / verifier / ...) the Connect pod consumes as a MOUNTED FILE. The
#     live value keeps a trailing newline that `$()` strips, but a JSON parse
#     ignores it, so the seeded credential is functionally identical. Encoding
#     confirmed correct (raw values, base64'd into the Secret by kubectl).
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
