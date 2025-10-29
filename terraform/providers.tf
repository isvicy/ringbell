variable "libvirt_uri" {
  description = "Libvirt connection URI. Use qemu:///system if Terraform runs on Unraid; otherwise qemu+ssh://user@host/system."
  type        = string
  default     = "qemu:///system"
}

provider "libvirt" {
  uri = var.libvirt_uri
}

provider "talos" {}
