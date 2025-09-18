#!/usr/bin/env bash
# Companion (Bitfocus) - Proxmox Helper Script (CT)
# Host-side script: creates an unprivileged Debian LXC and runs the in-CT installer.
# Inspired by the community Proxmox Helper Scripts layout and flow (tteck/community-scripts).
# License: MIT (adjust as desired)

set -Eeuo pipefail

# -------- Defaults (override via env) ----------
APP="Companion"
CTID="${CTID:-950}"
HN="${HN:-companion}"
PWD="${PWD:-changeme}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
IPV4="${IPV4:-dhcp}"        # "dhcp" or "192.168.10.50/24"
GATEWAY="${GATEWAY:-}"       # e.g. 192.168.10.1; empty for DHCP
MEM_MB="${MEM_MB:-1024}"
CORES="${CORES:-2}"
ROOTFS_GB="${ROOTFS_GB:-8}"
AUTOSTART="${AUTOSTART:-1}"
NESTING="${NESTING:-1}"
TIMEZONE="${TIMEZONE:-Etc/UTC}"
# Template (matches community scripts’ Debian 12 default)
TSTORE="${TSTORE:-local}"
TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"

# Where to fetch the in-CT installer from (your repo raw URL)
INSTALL_URL="${INSTALL_URL:-https://raw.githubusercontent.com/<youruser>/proxmox-companion-lxc/main/proxmox/install/companion_install.sh}"

# -------- Helpers ----------
msg() { echo -e "[$(date +%T)] $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"; }

# -------- Preflight ----------
need_cmd pveversion
need_cmd pveam
need_cmd pct
need_cmd curl

# Warn about SSH vs. local shell (common issue in helper-script usage)
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  msg "Note: Running from SSH. If you hit locale/env issues, try the Proxmox web shell."
fi

# Internet check
curl -fsSL https://1.1.1.1 >/dev/null 2>&1 || fail "No internet access from host."

# Ensure template
msg "Ensuring Debian template exists in ${TSTORE} ..."
if ! pveam list "$TSTORE" | grep -q "$TEMPLATE"; then
  pveam update
  pveam download "$TSTORE" "$TEMPLATE"
fi

# Network config
NET0="name=eth0,bridge=${BRIDGE}"
if [[ "$IPV4" == "dhcp" ]]; then
  NET0="${NET0},ip=dhcp"
else
  NET0="${NET0},ip=${IPV4}"
  [[ -n "$GATEWAY" ]] && NET0="${NET0},gw=${GATEWAY}"
fi

# Create CT
msg "Creating unprivileged LXC CTID ${CTID} (${HN}) on ${STORAGE} ..."
pct create "$CTID" "${TSTORE}:vztmpl/${TEMPLATE}" \
  -hostname "$HN" \
  -password "$PWD" \
  -storage "$STORAGE" \
  -rootfs "${STORAGE}:${ROOTFS_GB}" \
  -memory "$MEM_MB" \
  -cores "$CORES" \
  -unprivileged 1 \
  -features nesting=${NESTING} \
  -onboot "${AUTOSTART}" \
  -net0 "$NET0" \
  -timezone "$TIMEZONE"

# Start CT
msg "Starting container ${CTID} ..."
pct start "$CTID"

# Push and run installer
msg "Fetching in-CT installer ..."
TMP_INSTALL="/root/companion_install.sh"
pct exec "$CTID" -- bash -lc "apt-get update && apt-get install -y curl ca-certificates"
pct exec "$CTID" -- bash -lc "curl -fsSL '${INSTALL_URL}' -o '${TMP_INSTALL}' && chmod +x '${TMP_INSTALL}'"

msg "Running in-CT installer ..."
pct exec "$CTID" -- bash -lc "'${TMP_INSTALL}'"

# Status + hints
IP_OUT="$(pct exec "$CTID" -- bash -lc 'hostname -I 2>/dev/null || true')"
msg "Done."
echo "-----------------------------------------------------"
echo " CTID:        $CTID"
echo " Hostname:    $HN"
echo " Autostart:   $AUTOSTART"
echo " Container IP:${IP_OUT:- (check DHCP server)}"
echo " Web UI:      http://<container-ip>:8000"
echo " Satellite:   Ensure TCP 16622 (and 16623 for WS) reachable"
echo " Console:     pct console $CTID"
echo "-----------------------------------------------------"