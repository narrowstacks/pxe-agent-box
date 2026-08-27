#!/usr/bin/env bash
# Create a new agent dev box by cloning the cloud-init template.
#
# Usage: ./create-vm.sh [-n name] [-i vmid] [--no-start]
#   -n name   VM name (default: agent-box)
#   -i vmid   VM ID  (default: next free ID from the cluster)
#
# Run on the PVE host. Sources config.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

VM_NAME="agent-box"
VM_ID=""
VM_DISK_SIZE="" # override VM_DISK_SIZE_GB from config.sh when set
START_AFTER_CREATE=1

while getopts "n:i:c:m:d:h" opt; do
  case "$opt" in
  n) VM_NAME="$OPTARG" ;;
  i) VM_ID="$OPTARG" ;;
  c) OPT_CORES="$OPTARG" ;;
  m) OPT_MEMORY_MB="$OPTARG" ;;
  d) VM_DISK_SIZE="$OPTARG" ;;
  h)
    grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "see -h for usage" >&2
    exit 1
    ;;
  esac
done
[[ ${OPTIND} -gt 1 ]] || {
  echo "positional args unsupported — see -h" >&2
  exit 1
}

# shellcheck source=/dev/null disable=SC1091
source "$REPO_ROOT/config.sh"

# CLI flags win over config.sh (parsed before the source above, applied after)
VM_CORES="${OPT_CORES:-$VM_CORES}"
VM_MEMORY_MB="${OPT_MEMORY_MB:-$VM_MEMORY_MB}"

log() { printf '\033[1;32m[create]\033[0m %s\n' "$*"; }
fail() {
  printf '\033[1;31m[create] ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

require() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
for cmd in qm pvesm base64; do require "$cmd"; done

qm status "$TEMPLATE_ID" >/dev/null 2>&1 ||
  fail "template ${TEMPLATE_ID} not found — run build-template.sh first"
qm config "$TEMPLATE_ID" | grep -q '^template: 1$' ||
  fail "VM ${TEMPLATE_ID} exists but is not a template"

if qm status "$VM_NAME" >/dev/null 2>&1; then
  fail "a VM named '${VM_NAME}' already exists — pick another with -n or delete it first (delete-vm.sh <name|id>)"
fi

if [[ -z "$VM_ID" ]]; then
  VM_ID="$(pvesh get /cluster/nextid)"
fi
qm status "$VM_ID" >/dev/null 2>&1 && fail "VM ID ${VM_ID} is already in use"

##### collect ssh public keys #####

declare -a KEY_ARGS=()
for f in $SSH_KEY_FILES; do
  [[ -s "$f" ]] || continue
  if ! head -c512 "$f" | grep -qE '^(ssh-(rsa|ed25519)|ecdsa-sha2-[a-z0-9-]+) '; then
    fail "$f does not look like an OpenSSH public key"
  fi
  log "using key file: $f ($(wc -l <"$f") key(s))"
  KEY_ARGS+=(--sshkeys "$f")
done
((${#KEY_ARGS[@]})) || fail "no SSH key files found (checked: ${SSH_KEY_FILES}). Set SSH_KEY_FILES in config.sh."

##### build guest env + provision payload #####

HOSTNAME="${GUEST_HOSTNAME_PREFIX:+${GUEST_HOSTNAME_PREFIX}-}${VM_NAME}"
mkdir -p /var/lib/vz/snippets 2>/dev/null || true

env_content="$(mktemp)"
printf 'ADMIN_USER=%s\nNODE_MAJOR=%s\nSWAP_SIZE_GB=%s\nENABLE_UFW=%s\n' \
  "$ADMIN_USER" "$NODE_MAJOR" "$SWAP_SIZE_GB" "$ENABLE_UFW" >"$env_content"

provision_b64="$(base64 -w0 "$REPO_ROOT/cloud-init/provision.sh")"

if [[ -n "$STATIC_IP" ]]; then
  NET_SECTION="      addresses: [${STATIC_IP}]"
else
  NET_SECTION="      dhcp4: true"
fi
if [[ -n "$GATEWAY" ]]; then
  NET_SECTION="${NET_SECTION}
      routes:
        - to: default
          via: ${GATEWAY}"
fi

SNIPPET_NAME="${VM_NAME}-${VM_ID}.yml"
SNIPPET_PATH="$(pvesm path "${SNIPPET_STORAGE}:snippets/${SNIPPET_NAME}")"
[[ -d "$(dirname "$SNIPPET_PATH")" ]] || fail "snippet dir $(dirname "$SNIPPET_PATH") missing"

log "writing cloud-init snippet: ${SNIPPET_STORAGE}:snippets/${SNIPPET_NAME}"

# shellcheck disable=SC2016  # heredoc deliberately unquoted for expansion below
cat >"$SNIPPET_PATH" <<YAML
#cloud-config
hostname: ${HOSTNAME}
manage_etc_hosts: true
timezone: ${GUEST_TIMEZONE}
ssh_pwauth: false
disable_root: true

users:
  - name: ${ADMIN_USER}
    gecos: agent-box admin
    groups: [adm, sudo, docker]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true

network:
  version: 2
  ethernets:
    nic0:
      match:
        name: "en*"
      set-name: nic0
${NET_SECTION}

write_files:
  - path: /etc/agent-box.env
    permissions: '0644'
    content: |
$(sed 's/^/      /' "$env_content")
  - path: /opt/agent-box/provision.sh
    permissions: '0755'
    encoding: b64
    content: ${provision_b64}

runcmd:
  - sh /opt/agent-box/provision.sh 2>&1 | tee /dev/ttyS0
YAML

chmod 644 "$SNIPPET_PATH"
rm -f "$env_content"

##### clone + configure #####

log "cloning template ${TEMPLATE_ID} -> VM ${VM_ID} (${VM_NAME}), full clone"
qm clone "$TEMPLATE_ID" "$VM_ID" --name "$VM_NAME" --full 1

DISK_GB="${VM_DISK_SIZE:-$VM_DISK_SIZE_GB}"
log "applying sizing: ${VM_CORES} cores / ${VM_MEMORY_MB}MiB / ${DISK_GB}G disk"
qm set "$VM_ID" --cores "$VM_CORES" --memory "$VM_MEMORY_MB" --balloon 2048
# PVE 8.4: legacy 'qm resize' alias mangles args; use the full 'qm disk resize'
# command with size as a positional argument.
qm disk resize "$VM_ID" scsi0 "${DISK_GB}G"
qm set "$VM_ID" --cicustom "user=${SNIPPET_STORAGE}:snippets/${SNIPPET_NAME}"

if [[ -n "$SEARCH_DOMAIN" ]]; then
  qm set "$VM_ID" --searchdomain "$SEARCH_DOMAIN"
fi

if ((START_AFTER_CREATE)); then
  log "starting VM ${VM_ID}"
  qm start "$VM_ID"

  log "waiting up to 120s for qemu-guest-agent to report the IP..."
  GUEST_IP=""
  for _ in $(seq 1 24); do
    sleep 5
    GUEST_IP="$(qm agent "$VM_ID" ping >/dev/null 2>&1 &&
      qm guest exec "$VM_ID" -- hostname -I 2>/dev/null |
      grep -oP '(?<="out-data":")[^"]*' | tr -d '\n' || true)"
    [[ -n "$GUEST_IP" ]] && break
    printf '.'
  done
  echo
fi

echo
echo "============================================="
echo " agent-box created: ${VM_NAME} (VMID ${VM_ID})"
if [[ -n "${GUEST_IP:-}" ]]; then
  echo " ip (may lag while provisioning finishes): ${GUEST_IP%% *}"
  echo " connect once ready:  ssh ${ADMIN_USER}@${GUEST_IP%% *}"
else
  echo " find the DHCP lease or run:"
  echo "   qm guest exec ${VM_ID} -- hostname -I"
  echo " then: ssh ${ADMIN_USER}@<ip>"
fi
echo " console (in case ssh is unavailable): qm terminal ${VM_ID}"
echo " provision.log: qm guest exec ${VM_ID} -- tail -50 /var/log/cloud-init-output.log"
echo "============================================="
