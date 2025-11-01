variable "pool_name" { type = string }
variable "name" { type = string }
variable "vcpu" { type = number }
variable "memory_mb" { type = number }
variable "root_size_gb" { type = number }
variable "base_volume_id" { type = string }
variable "bridge_name" { type = string }
variable "mac_address" { type = string }

# NEW: optional extra data disk (0 = disabled)
variable "extra_data_size_gb" {
  type    = number
  default = 0
}
