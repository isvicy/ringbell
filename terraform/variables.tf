# ---------- Libvirt pools ----------
variable "cp_pool_name" {
  description = "Libvirt storage pool name for control-planes (SSD)"
  type        = string
  default     = "talos-ssd"
}

variable "cp_pool_path" {
  description = "Directory path for the SSD pool"
  type        = string
  default     = "/mnt/ssd/domains/talos"
}

variable "wk_pool_name" {
  description = "Libvirt storage pool name for workers (NVMe)"
  type        = string
  default     = "talos-ultra"
}

variable "wk_pool_path" {
  description = "Directory path for the NVMe pool"
  type        = string
  default     = "/mnt/ultra/domains/talos"
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

# ---------- Networking ----------
variable "api_vip" {
  description = "Kubernetes API VIP (Talos native VIP)"
  type        = string
  default     = "192.168.2.20"
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

# ---------- Sizing ----------
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
  default = 160
} # worker root disk (on NVMe)
variable "wk_data_gb" {
  type    = number
  default = 180
}

# ---------- Talos / Kubernetes ----------
variable "talos_version" {
  type    = string
  default = "v1.11.3"
}
variable "kubernetes_version" {
  type    = string
  default = "1.34.1"
}
variable "cluster_name" {
  type    = string
  default = "ringbell"
}
variable "bootstrap_ip" {
  type    = string
  default = "192.168.2.21"
}
