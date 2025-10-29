locals {
  talos_image_local_path = var.talos_image_local_path != "" ? var.talos_image_local_path : "${path.module}/images/talos-amd64.qcow2"
}
