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
INSTALL_URL="${INSTALL_URL:-https://raw.githubusercontent.com/glabutis/proxmox-companion-lxc/main/proxmox/install/companion_install.sh}"

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

# ----- Template auto-select (robust) -----
DEBIAN_SERIES="${DEBIAN_SERIES:-12}"   # 12 = Debian 12 (bookworm)
ARCH="${ARCH:-amd64}"
TSTORE="${TSTORE:-local}"              # must support content type: vztmpl

require_storage_vztmpl() {
  # Make sure TSTORE exists and supports templates
  if ! pvesm status | awk '{print $1}' | grep -qx "$TSTORE"; then
    echo "ERROR: storage '$TSTORE' not found. See: Datacenter -> Storage." >&2
    exit 1
  fi
  if ! pvesm status --verbose 2>/dev/null | awk -v s="$TSTORE" '
      $1==s && $0 ~ /content:.*(^|,)(vztmpl)(,|$)/ {found=1} END{exit(found?0:1)}'
  then
    echo "ERROR: storage '$TSTORE' does not allow content type 'vztmpl' (templates)." >&2
    echo "       Enable it in Datacenter -> Storage -> $TSTORE -> Content -> check 'VZDump template'." >&2
    exit 1
  fi
}

pick_template() {
  local series="$1" arch="$2"
  # Extract the filename from the whole line regardless of columns.
  # Example line: "system  debian-12-standard_12.6-1_amd64.tar.zst"
  local latest
  latest="$(pveam available \
    | awk -v s="$series" -v a="$arch" '
        {
          match($0, ("debian-" s "-standard_[0-9.]+-[0-9]_" a "\\.tar\\.(zst|gz)"))
          if (RSTART) print substr($0, RSTART, RLENGTH)
        }' \
    | sort -V | tail -n1)"

  if [[ -z "$latest" ]]; then
    echo "ERROR: No Debian ${series} standard template found for ${arch}." >&2
    echo "       Try: pveam update && pveam available | grep -E \"debian-${series}-standard_.*_${arch}\\.tar\"" >&2
    exit 1
  fi
  echo "$latest"
}

require_storage_vztmpl

echo "[+] Updating template catalog ..."
pveam update

if [[ -z "${TEMPLATE:-}" ]]; then
  TEMPLATE="$(pick_template "$DEBIAN_SERIES" "$ARCH")"
fi

echo "[+] Using template: ${TEMPLATE}"
echo "[+] Ensuring template exists in ${TSTORE} ..."
if ! pveam list "$TSTORE" | awk '{print $2}' | grep -qx "$TEMPLATE"; then
  pveam download "$TSTORE" "$TEMPLATE"
fi

# Later in pct create keep:
# pct create "$CTID" "${TSTORE}:vztmpl/${TEMPLATE}" ...
# Resolve the template name once at runtime (unless TEMPLATE is pre-set by env)
if [[ -z "${TEMPLATE:-}" ]]; then
  TEMPLATE="$(pick_template "$DEBIAN_SERIES" "$ARCH")" || exit 1
fi

echo "[+] Ensuring Debian template exists in ${TSTORE} ..."
pveam update
if ! pveam list "$TSTORE" | grep -q "$TEMPLATE"; then
  pveam download "$TSTORE" "$TEMPLATE"
fi

# When creating the CT, remember to reference it like this:
# pct create "$CTID" "${TSTORE}:vztmpl/${TEMPLATE}"  ...

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
