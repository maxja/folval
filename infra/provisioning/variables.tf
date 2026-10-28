variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox API endpoint"
}

variable "proxmox_api_token" {
  type        = string
  sensitive   = true
  description = "Proxmox API token"
}

variable "proxmox_insecure" {
  type    = bool
  default = false
}

variable "pve_node" {
  type        = string
  description = "Proxmox target node name"
}

variable "vm_id" {
  type        = number
  default     = 300
  description = "Proxmox VM ID for folval3"
}

variable "vm_name" {
  type        = string
  default     = "folval3"
}

variable "storage_pool" {
  type        = string
  default     = "local-lvm"
}

variable "source_img_file" {
  type        = string
  default     = "local:iso/folval2.qcow2"
  description = "Uploaded box image (PVE Download from URL ← brain staging)"
}

variable "pci_address" {
  type        = string
  description = "Quadro P1000 PCI address (all functions), e.g. 0000:01:00"
}

variable "guest_mac" {
  type        = string
  description = "MAC carried over from folval2 (activation hash + DHCP stability)"
}

variable "vm_cpu_cores" {
  type        = number
  default     = 8
}

variable "vm_memory_mb" {
  type        = number
  default     = 12288
}

variable "vm_disk_gb" {
  type        = number
  default     = 64
}

variable "vm_started" {
  type        = bool
  default     = false
  description = "make up flips this to true (API start after vfio is in place)"
}
