locals {
  talos_image_local_path  = var.talos_image_local_path != "" ? var.talos_image_local_path : "${path.module}/images/talos-amd64.qcow2"
  debian_image_local_path = var.debian_image_local_path != "" ? var.debian_image_local_path : "${path.module}/images/debian-12-generic-amd64.qcow2"
}
