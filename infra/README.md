# folly-n-valor — Proxmox VM infrastructure (folval3)

Provisions the game VM on the Proxmox box (Lenovo P330 Tiny, Quadro P1000
passthrough) with OpenTofu, configures it with Ansible. Secrets via 1Password
(`op run`). Organization follows ../automate-dz.

Exactly **one VM**: the Windows 10 LTSC box image (folval2.qcow2), P1000
passed through, vga none, mini-DP dummy plug as display sink. The "brain"
(gateway :8443, staging :8080, frida CLI, MQEL mining) stays on the
workstation host — see .ai-memory/handoff.md.

## Layout

```
provisioning/       OpenTofu: single proxmox_virtual_environment_vm (API-only, no SSH)
configuration/      Ansible: WinRM into the guest; roles assert/install/configure
```

## Workflow

```
make init        # tofu init
make plan        # preview (requires .env.secrets with op:// refs)
make provision   # create VM, NOT started (P1000 must be vfio-bound first —
                 # already done on the node by the user)
make up          # start VM via API, poll QEMU guest agent for IP
make inventory   # write configuration/inventory/hosts.yaml (winrm)
make configure   # run guest roles: nvidia_driver, game_stack, frida
make gpu         # run gpu-ready probe (restart device until problem=0)
make d3d9        # THE GATE: run d3d9probe task, fetch C:\re\d3d9-s1.txt
make destroy     # tear down
```

## Secrets

Copy `example.env` → `.env.secrets`, fill in `op://` refs, then run everything
through `make` (which wraps commands in `op run --env-file=.env.secrets`).

## Docs

Proxmox setup, first-run sequence, and the P1000 story: docs/GUIDE.md.
