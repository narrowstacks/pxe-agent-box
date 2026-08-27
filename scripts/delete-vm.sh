#!/usr/bin/env bash
# Delete an agent-box VM by name or ID.
#
# Usage: ./delete-vm.sh <name|vmid> [--force]
#   --force : skip confirmation prompt
#
# Run on the PVE host. Also removes the VM's generated cloud-init snippet.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

FORCE=0
TARGET=""
for arg in "$@"; do
  case "$arg" in
  --force) FORCE=1 ;;
  *) TARGET="$arg" ;;
  esac
done
[[ -n "$TARGET" ]] || {
  echo "usage: $0 <name|vmid> [--force]" >&2
  exit 1
}

# shellcheck source=/dev/null disable=SC1091
source "$REPO_ROOT/config.sh"

log() { printf '\033[1;33m[delete]\033[0m %s\n' "$*"; }
fail() {
  printf '\033[1;31m[delete] ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

for cmd in qm pvesm; do command -v "$cmd" >/dev/null || fail "missing: $cmd"; done

if qm status "$TARGET" >/dev/null 2>&1; then
  VM_ID="$TARGET"
else
  # resolve name -> id via cluster resources (proper JSON parse, not grep)
  VM_ID="$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null |
    python3 -c "
import json, sys
name = '$TARGET'.replace(\"'\", \"\")
ids = [v['vmid'] for v in json.load(sys.stdin) if v.get('name') == name]
print(ids[0] if ids else '')
" || true)"
fi
[[ -n "${VM_ID:-}" ]] && qm status "$VM_ID" >/dev/null 2>&1 || fail "no VM matching '${TARGET}'"

VM_NAME="$(qm config "$VM_ID" | grep -oP '(?<=^name: ).*' || true)"
log "found VM ${VM_ID} (${VM_NAME:-unnamed})"

if ((!FORCE)); then
  read -r -p "Destroy ${VM_NAME:-$VM_ID} and its disks? Type 'yes' to confirm: " reply
  [[ "$reply" == "yes" ]] || fail "aborted"
fi

qm stop "$VM_ID" >/dev/null 2>&1 || true
qm destroy "$VM_ID" --purge --destroy-unreferenced-disks 1
log "destroyed VM ${VM_ID}"

SNIPPET_NAME="${VM_NAME:-agent-box}-${VM_ID}.yml"
SNIPPET_PATH="$(pvesm path "${SNIPPET_STORAGE}:snippets/${SNIPPET_NAME}" 2>/dev/null || true)"
if [[ -n "$SNIPPET_PATH" && -f "$SNIPPET_PATH" ]]; then
  rm -f "$SNIPPET_PATH"
  log "removed snippet $SNIPPET_NAME"
fi

log "done."
