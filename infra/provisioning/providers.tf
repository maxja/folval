terraform {
  required_version = ">= 1.9.0"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.111.1"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  # API for everything except the image import — that one operation goes
  # over SSH via the agent (same pattern as automate-dz; the agent key must
  # be authorized for root on the PVE node).
  ssh {
    agent    = true
    username = "root"
  }
}
