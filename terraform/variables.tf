variable "pool_name" {
  description = "Libvirt storage pool name"
  type        = string
  default     = "talos"
}

variable "pool_path" {
  description = "Directory path for the libvirt storage pool"
  type        = string
  default     = "/mnt/user/domains/talos"
}

variable "talos_image_local_path" {
  description = "Path to the Talos QCOW2 image (leave empty to use ./images/talos-amd64.qcow2)"
  type        = string
  default     = ""
}

variable "bridge_name" {
  description = "Bridge name on Unraid (usually br0)"
  type        = string
  default     = "br0"
}

variable "api_vip" {
  description = "Kubernetes API VIP (kube-vip)"
  type        = string
  default     = "192.168.2.20"
}

variable "vip_interface" {
  description = "Interface name inside Talos for kube-vip (eth0)"
  type        = string
  default     = "eth0"
}

variable "interface" {
  description = "Interface name inside Talos (eth0)"
  type        = string
  default     = "eth0"
}

variable "gateway" {
  description = "Default gateway for the nodes"
  type        = string
  default     = "192.168.2.1"
}

variable "dns_servers" {
  description = "DNS servers for the nodes"
  type        = list(string)
  default     = ["192.168.2.1", "1.1.1.1"]
}

variable "cidr" {
  description = "CIDR prefix length for node addresses (e.g., 24)"
  type        = number
  default     = 24
}

variable "controlplanes" {
  description = "Map of control-plane nodes"
  type = map(object({
    name = string
    ip   = string
    mac  = string
  }))
  default = {
    "cp-01" = { name = "cp-01", ip = "192.168.2.21", mac = "52:54:00:aa:02:21" }
    "cp-02" = { name = "cp-02", ip = "192.168.2.22", mac = "52:54:00:aa:02:22" }
    "cp-03" = { name = "cp-03", ip = "192.168.2.23", mac = "52:54:00:aa:02:23" }
  }
}

variable "workers" {
  description = "Map of worker nodes"
  type = map(object({
    name = string
    ip   = string
    mac  = string
  }))
  default = {
    "w-01" = { name = "w-01", ip = "192.168.2.24", mac = "52:54:00:aa:02:24" }
    "w-02" = { name = "w-02", ip = "192.168.2.25", mac = "52:54:00:aa:02:25" }
  }
}

variable "cp_vcpu" {
  type    = number
  default = 4
}

variable "cp_memory_mb" {
  type    = number
  default = 16384
}
variable "cp_disk_gb" {
  type    = number
  default = 80
}

variable "wk_vcpu" {
  type    = number
  default = 8
}
variable "wk_memory_mb" {
  type    = number
  default = 32768
}
variable "wk_disk_gb" {
  type    = number
  default = 120
}

variable "talos_version" {
  description = "Talos OS version tag"
  type        = string
  default     = "v1.11.3"
}

variable "kubernetes_version" {
  description = "Kubernetes version to install"
  type        = string
  default     = "1.34.1"
}

variable "kubevip_tag" {
  description = "kube-vip container tag"
  type        = string
  default     = "v0.8.0"
}

variable "cluster_name" {
  description = "Talos cluster name"
  type        = string
  default     = "ringbell"
}

variable "bootstrap_ip" {
  description = "The control-plane node IP to run Talos bootstrap against"
  type        = string
  default     = "192.168.2.21"
}
