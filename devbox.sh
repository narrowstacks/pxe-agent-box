#!/usr/bin/env bash
#
# devbox.sh - runs on the PROXMOX HOST as root.
#
#   ./devbox.sh preflight  Verify the host can support the design.
#   ./devbox.sh salvage    Copy auth state off a running box into $DATA_HOST_DIR.
#   ./devbox.sh template   Build the base template from the Debian cloud image.
#   ./devbox.sh render     Print the cloud-init snippet without writing it.
#   ./devbox.sh create     Clone the template into the running dev box.
#   ./devbox.sh rebuild    Destroy and recreate the box. /data is untouched.
#
# Set DRYRUN=1 to print the qm commands instead of running them.
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# DEVBOX_CONFIG lets tests point at a fixture config. Without it, sourcing
# the real config.sh would clobber any environment the caller set, and
# tests/test-render.sh could never run on a machine without /root/.ssh.
CONFIG_FILE="${DEVBOX_CONFIG:-./config.sh}"
[[ -r "$CONFIG_FILE" ]] || {
  echo "ERROR: $CONFIG_FILE not found. Copy config.example.sh to config.sh and edit it." >&2
  exit 1
}
# shellcheck source=/dev/null
source "$CONFIG_FILE"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Shared by create and rebuild. Skips loopback, tailscale and docker
# interfaces so the LAN address is what comes back.
guest_ip() {
  qm guest cmd "$1" network-get-interfaces 2>/dev/null \
    | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for n in d:
    if n.get("name","").startswith(("lo","tail","docker")): continue
    for a in n.get("ip-addresses",[]):
        if a.get("ip-address-type")=="ipv4": print(a["ip-address"]); raise SystemExit' || true
}

# Every state-changing command goes through run() so DRYRUN can intercept it.
run() {
  if [[ "${DRYRUN:-0}" == "1" ]]; then
    printf '  [dryrun] %s\n' "$*"
  else
    "$@"
  fi
}

##### salvage #####

# Auth state worth carrying off the old box. Source paths are relative to the
# admin user's home; destinations are relative to $DATA_HOST_DIR/state.
# Deliberately excludes ~/.omp (starship is the sole prompt owner now) and
# the mise tree (toolchains are reinstalled from the manifest on rebuild).
SALVAGE_MAP=(
  ".claude:claude"
  ".claude.json:claude.json"
  ".config/gh:config-gh"
  ".config/herdr:config-herdr"
  ".config/moshi:config-moshi"
  ".config/mise:config-mise"
  ".gitconfig:gitconfig"
)

cmd_salvage() {
  local src_vmid="${1:-$VMID}"
  qm status "$src_vmid" 2>/dev/null | grep -q running \
    || fail "VM $src_vmid is not running; salvage reads a live box"

  local home="/home/${ADMIN_USER}"
  local dest="${DATA_HOST_DIR}/state"
  run mkdir -p "$dest"

  log "salvaging state from VM ${src_vmid} into ${dest}"
  local entry src dst
  for entry in "${SALVAGE_MAP[@]}"; do
    src="${home}/${entry%%:*}"
    dst="${dest}/${entry##*:}"

    # qm guest exec cannot stream files, so tar through base64 over the agent.
    # Nested quoting through guest exec is a known footgun; keep the guest-side
    # command a single flat sh -c string with no embedded newlines.
    if ! qm guest exec "$src_vmid" -- /bin/sh -c "test -e '$src'" >/dev/null 2>&1; then
      printf '  skip   %s (absent)\n' "$src"
      continue
    fi

    if [[ "${DRYRUN:-0}" == "1" ]]; then
      printf '  [dryrun] salvage %s -> %s\n' "$src" "$dst"
      continue
    fi

    # A single entry failing must not abort the salvage. The closing chown
    # would be skipped and everything already extracted would stay
    # root-owned, which is broken state for a volume the guest reads as
    # uid 1000. Warn and continue, matching how optional steps behave
    # elsewhere in this project.
    if ! qm guest exec "$src_vmid" --timeout 120 -- /bin/sh -c \
        "tar -C '$(dirname "$src")' -cf - '$(basename "$src")' | base64 -w0" \
      | python3 -c 'import json, sys, base64
try:
    payload = json.load(sys.stdin)["out-data"]
except Exception as exc:
    print("salvage decode failed: %s" % exc, file=sys.stderr)
    raise SystemExit(1)
sys.stdout.buffer.write(base64.b64decode(payload))' \
      | tar -C "$dest" -xf -; then
      warn "could not salvage ${src}, continuing"
      continue
    fi

    # Entries land under their original basename; move into the mapped name.
    local landed
    landed="${dest}/$(basename "$src")"
    [[ "$landed" == "$dst" ]] || { rm -rf "$dst"; mv "$landed" "$dst"; }
    printf '  ok     %s -> %s\n' "$src" "$dst"
  done

  run chown -R 1000:1000 "$dest"
  log "salvaged, sizes:"
  du -sh "$dest"/* 2>/dev/null || true
}

case "${1:-}" in
  preflight) ./scripts/preflight.sh ;;
  salvage)   shift; cmd_salvage "$@" ;;
  *) echo "usage: $0 {preflight|salvage|template|render|create|rebuild}" >&2; exit 1 ;;
esac
