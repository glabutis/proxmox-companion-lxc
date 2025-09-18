#!/usr/bin/env bash
# Companion (Bitfocus) - In-Container Installer
# Runs inside the Debian LXC: installs Companion headless via the official script, enables service.

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

msg() { echo -e "[$(date +%T)] $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"; }

need_cmd apt-get
need_cmd curl
need_cmd systemctl

msg "Updating base packages ..."
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl git systemd-sysv iproute2 net-tools

msg "Installing Bitfocus Companion (headless) via CompanionPi script ..."
# Officially documented path for Debian-based headless installs.
# Ref: Companion wiki Installation page.
curl -fsSL https://raw.githubusercontent.com/bitfocus/companion-pi/main/install.sh | bash

msg "Enabling Companion systemd service ..."
systemctl enable --now companion.service

msg "Final checks ..."
sleep 1
systemctl --no-pager --full status companion.service || true

IP_LIST="$(hostname -I 2>/dev/null || true)"
msg "Installation complete."
echo "----------------------------------------------"
echo " IP(s):      ${IP_LIST}"
echo " Web UI:     http://<container-ip>:8000"
echo " Satellite:  TCP 16622 (and 16623 for WS mode)"
echo " Update:     sudo companion-update (if provided) or rerun installer"
echo "----------------------------------------------"