#!/usr/bin/env bash
# Verifies charon can support the design before anything is built.
# Every check here corresponds to a risk in the design spec, section 10.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
CONFIG_FILE="${DEVBOX_CONFIG:-./config.sh}"
[[ -r "$CONFIG_FILE" ]] || {
  echo "ERROR: $CONFIG_FILE not found. Copy config.example.sh to config.sh and edit it." >&2
  exit 1
}
# shellcheck source=/dev/null
source "$CONFIG_FILE"

log()  { printf '\033[1;34m[preflight]\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; failures=$((failures + 1)); }
warn() { printf '  \033[1;33mwarn\033[0m %s\n' "$*"; }

failures=0

log "proxmox"
pveversion | head -1
if [[ -x /usr/lib/kvm/virtiofsd ]] || command -v virtiofsd >/dev/null 2>&1; then
  ok "virtiofsd present"
else
  bad "virtiofsd not found; virtiofs needs PVE 8.4 or newer"
fi

log "storage"
if pvesm status | awk -v s="$STORAGE" '$1 == s && $3 == "active" {found=1} END {exit !found}'; then
  ok "storage '$STORAGE' active"
else
  bad "storage '$STORAGE' not active"
fi

log "memory"
total_mb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
allocated_mb=$(qm list | awk 'NR > 1 && $3 == "running" {sum += $4} END {print sum + 0}')
log "host has ${total_mb} MiB, running VMs allocate ${allocated_mb} MiB, this box wants ${VM_MEMORY_MB} MiB"
if (( allocated_mb + VM_MEMORY_MB > total_mb )); then
  warn "overcommitted; reduce VM_MEMORY_MB or stop another VM"
else
  ok "memory fits"
fi

log "vmids"
for id in "$TEMPLATE_ID" "$VMID"; do
  if qm status "$id" >/dev/null 2>&1; then
    warn "VMID $id exists and will be destroyed by template/create"
  else
    ok "VMID $id free"
  fi
done

log "ssh keys"
# shellcheck disable=SC2086
for k in $SSH_KEY_FILES; do
  if [[ -s "$k" ]]; then ok "$k"; else bad "$k missing or empty"; fi
done

log "third-party apt repos for trixie"
check_repo() {  # check_repo <label> <url>
  # GET, not HEAD: some endpoints reject HEAD while serving fine over GET.
  # -L to follow redirects: without it a 3xx returns 0 and the check passes
  # without ever confirming the target serves the file.
  if curl -fsSL -o /dev/null --max-time 15 "$2"; then ok "$1"; else bad "$1 unreachable: $2"; fi
}
check_repo "docker trixie"    "https://download.docker.com/linux/debian/dists/trixie/Release"
check_repo "tailscale trixie" "https://pkgs.tailscale.com/stable/debian/dists/trixie/Release"
check_repo "github cli"       "https://cli.github.com/packages/dists/stable/Release"
check_repo "claude-code"      "https://downloads.claude.ai/claude-code/apt/stable/dists/stable/Release"
check_repo "google chrome"    "https://dl.google.com/linux/chrome/deb/dists/stable/Release"
# Range request for debian image to avoid downloading 350 MB qcow2 file.
# Only fetches first byte, proving the URL serves content.
if curl -fsSL -o /dev/null --max-time 15 -r 0-0 "$CLOUD_IMAGE_URL"; then ok "debian image"; else bad "debian image unreachable: $CLOUD_IMAGE_URL"; fi

log "data volume"
df -h "$(dirname "$DATA_HOST_DIR")" | tail -1

if (( failures > 0 )); then
  printf '\n\033[1;31m%d check(s) failed.\033[0m Fix these before building.\n' "$failures" >&2
  exit 1
fi
printf '\n\033[1;32mpreflight clean.\033[0m\n'
