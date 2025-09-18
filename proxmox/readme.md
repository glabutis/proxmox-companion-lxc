# Proxmox Helper Script – Bitfocus Companion (LXC)

This creates a lightweight **Debian 12** LXC on Proxmox and installs **Bitfocus Companion** (headless), enabling the systemd service and the web UI.

## Quick start (Proxmox host)
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/glabutis/proxmox-companion-lxc/main/proxmox/ct/companion.sh)"