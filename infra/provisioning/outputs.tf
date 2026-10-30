output "vm_id" {
  value       = proxmox_virtual_environment_vm.folval3.vm_id
  description = "Provisioned VM ID"
}

output "vm_primary_ip" {
  value = try(one([
    for ip in flatten(proxmox_virtual_environment_vm.folval3.ipv4_addresses) :
    ip if !startswith(ip, "127.")
  ]), null)
  description = "Primary non-loopback IPv4 (from QEMU guest agent). Null until agent reports."
}

output "guest_mac" {
  value       = var.guest_mac
  description = "MAC carried into the VM (for DHCP reservation bookkeeping)"
}
