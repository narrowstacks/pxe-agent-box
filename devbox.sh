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

##### template #####

IMAGE_PATH="/var/lib/vz/template/iso/$(basename "$CLOUD_IMAGE_URL")"

cmd_template() {
  local force="${1:-}"

  if qm status "$TEMPLATE_ID" >/dev/null 2>&1; then
    [[ "$force" == "--force" ]] \
      || fail "VMID $TEMPLATE_ID exists; pass --force to destroy and rebuild it"
    log "destroying existing template $TEMPLATE_ID"
    run qm destroy "$TEMPLATE_ID" --purge 1
  fi

  if [[ ! -f "$IMAGE_PATH" ]]; then
    log "downloading $(basename "$CLOUD_IMAGE_URL")"
    # Download to a temp name and rename only on success. wget writes
    # partial bytes straight to its target, so a failed download would
    # leave a truncated file that the next run's -f test accepts as
    # valid, feeding a corrupt image to 'qm create --import-from'.
    run wget -qO "${IMAGE_PATH}.partial" "$CLOUD_IMAGE_URL"
    run mv "${IMAGE_PATH}.partial" "$IMAGE_PATH"
  fi

  log "creating template $TEMPLATE_ID"
  # --cpu x86-64-v3 is set HERE, on the template, so every clone inherits it.
  # The PVE default (qemu64) lacks AVX and bun-based binaries segfault at
  # startup. Setting it per-clone means a future code path can forget it.
  run qm create "$TEMPLATE_ID" \
    --name "devbox-tmpl-trixie" \
    --memory 4096 --cores 2 --cpu x86-64-v3 --numa 0 \
    --net0 "virtio,bridge=${BRIDGE}${NET_VLAN_TAG:+,tag=$NET_VLAN_TAG}" \
    --scsihw virtio-scsi-single \
    --scsi0 "${STORAGE}:0,import-from=${IMAGE_PATH},discard=on,ssd=1,iothread=1" \
    --ide2 "${STORAGE}:cloudinit" \
    --boot order=scsi0 \
    --serial0 socket --vga serial0 \
    --agent enabled=1,fstrim_cloned_disks=1 \
    --ostype l26

  run qm template "$TEMPLATE_ID"
  log "template $TEMPLATE_ID ready"
}

##### render #####

render_snippet() {
  local tpl="cloud-init/devbox.yaml.tpl"
  [[ -f "$tpl" ]] || fail "missing $tpl"

  # Build the YAML key list with correct indentation. Keys are read from
  # files on the PVE host, so SSH_KEY_FILES must hold absolute paths.
  local keys="" k line
  for k in $SSH_KEY_FILES; do
    [[ -s "$k" ]] || fail "SSH key file missing or empty: $k"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      keys+="      - ${line}"$'\n'
    done < "$k"
  done
  [[ -n "$keys" ]] || fail "no SSH keys resolved from SSH_KEY_FILES"
  keys="${keys%$'\n'}"

  # Values reach awk through ENVIRON, never through -v: POSIX lexes -v
  # assignments as string literals, so a value containing a literal
  # backslash-n becomes a REAL newline and injects a sibling YAML key.
  # Substitution is literal index/substr rather than gsub, because gsub
  # treats & in the replacement as "the matched text". Neither construct
  # processes escapes, so values pass through as bytes.
  DEVBOX_VMNAME="$VMNAME" \
  DEVBOX_ADMIN_USER="$ADMIN_USER" \
  DEVBOX_TZ="$GUEST_TIMEZONE" \
  DEVBOX_MAPID="$DATA_MAP_ID" \
  DEVBOX_BOOTSTRAP="$BOOTSTRAP_URL" \
  DEVBOX_MISETOOLS="${MISE_TOOLS:-}" \
  DEVBOX_SWAPGB="${SWAP_SIZE_GB:-8}" \
  DEVBOX_ENABLEUFW="${ENABLE_UFW:-1}" \
  DEVBOX_EXTRAAPT="${EXTRA_APT_PACKAGES:-}" \
  DEVBOX_KEYS="$keys" \
  awk '
    # Literal replace. Never rescans what it just substituted, so a value
    # containing its own token cannot loop forever.
    function subst(s, token, value,   pos, out) {
      out = ""
      while ((pos = index(s, token)) > 0) {
        out = out substr(s, 1, pos - 1) value
        s = substr(s, pos + length(token))
      }
      return out s
    }
    {
      line = $0
      line = subst(line, "@VMNAME@",             ENVIRON["DEVBOX_VMNAME"])
      line = subst(line, "@ADMIN_USER@",         ENVIRON["DEVBOX_ADMIN_USER"])
      line = subst(line, "@GUEST_TIMEZONE@",     ENVIRON["DEVBOX_TZ"])
      line = subst(line, "@DATA_MAP_ID@",        ENVIRON["DEVBOX_MAPID"])
      line = subst(line, "@BOOTSTRAP_URL@",      ENVIRON["DEVBOX_BOOTSTRAP"])
      line = subst(line, "@MISE_TOOLS@",         ENVIRON["DEVBOX_MISETOOLS"])
      line = subst(line, "@SWAP_SIZE_GB@",       ENVIRON["DEVBOX_SWAPGB"])
      line = subst(line, "@ENABLE_UFW@",         ENVIRON["DEVBOX_ENABLEUFW"])
      line = subst(line, "@EXTRA_APT_PACKAGES@", ENVIRON["DEVBOX_EXTRAAPT"])
      if (line == "@SSH_KEYS@") { print ENVIRON["DEVBOX_KEYS"] } else { print line }
    }' "$tpl"
}

##### create #####

ensure_data_mapping() {
  run mkdir -p "$DATA_HOST_DIR"

  # Register through PVE's API, never by hand-writing the config. The
  # mapping lives in /etc/pve/mapping/directory.cfg (NOT dir.cfg) and its
  # format carries no "dir:" section prefix, so a hand-written file is
  # silently ignored: pvesh reports nothing and qm start fails with
  # "Directory ID <id> does not exist". Letting the API own the format
  # means a future PVE release changing it does not break us.
  if pvesh get /cluster/mapping/dir --output-format json 2>/dev/null \
     | grep -q "\"id\":\"${DATA_MAP_ID}\""; then
    return 0
  fi

  log "creating directory mapping '${DATA_MAP_ID}' -> ${DATA_HOST_DIR}"
  # Re-creating an existing mapping is an ERROR, not a no-op
  # ("dir ID 'x' already defined"), so the check above is mandatory.
  run pvesh create /cluster/mapping/dir \
    --id "$DATA_MAP_ID" \
    --map "node=$(hostname),path=${DATA_HOST_DIR}"
}

cmd_create() {
  ./scripts/preflight.sh || fail "preflight failed"

  qm status "$TEMPLATE_ID" >/dev/null 2>&1 \
    || fail "template $TEMPLATE_ID does not exist; run './devbox.sh template' first"

  qm status "$VMID" >/dev/null 2>&1 \
    && fail "VMID $VMID already exists; use 'rebuild'"

  ensure_data_mapping

  local snippet_name="${VMNAME}.yaml"
  local snippet_path
  snippet_path="$(pvesm path "${SNIPPET_STORAGE}:snippets/${snippet_name}")"
  [[ -d "$(dirname "$snippet_path")" ]] || run mkdir -p "$(dirname "$snippet_path")"

  log "writing snippet ${SNIPPET_STORAGE}:snippets/${snippet_name}"
  if [[ "${DRYRUN:-0}" == "1" ]]; then
    render_snippet | sed 's/^/  [dryrun] /'
  else
    render_snippet > "$snippet_path"
  fi

  log "cloning ${TEMPLATE_ID} -> ${VMID}"
  run qm clone "$TEMPLATE_ID" "$VMID" --name "$VMNAME" --full 1 --storage "$STORAGE"

  # --balloon 0 is REQUIRED, not preferred: PVE refuses virtiofs on a VM with
  # ballooning enabled. Do not "optimize" this back to a balloon value.
  run qm set "$VMID" \
    --cores "$VM_CORES" \
    --memory "$VM_MEMORY_MB" --balloon 0 \
    --cicustom "user=${SNIPPET_STORAGE}:snippets/${snippet_name}" \
    --virtiofs0 "dirid=${DATA_MAP_ID},cache=always,expose-acl=1" \
    --onboot 1 \
    --tags dev

  local ipconfig="ip=dhcp"
  if [[ -n "$STATIC_IP" ]]; then
    ipconfig="ip=${STATIC_IP}${GATEWAY:+,gw=$GATEWAY}"
  fi
  run qm set "$VMID" --ipconfig0 "$ipconfig"
  [[ -z "$SEARCH_DOMAIN" ]] || run qm set "$VMID" --searchdomain "$SEARCH_DOMAIN"

  # 'qm disk resize', not the legacy 'qm resize' alias, which mangles args.
  run qm disk resize "$VMID" scsi0 "${VM_DISK_SIZE_GB}G"
  run qm start "$VMID"

  [[ "${DRYRUN:-0}" == "1" ]] && return 0

  log "waiting for the guest agent to report an address"
  local ip=""
  for _ in $(seq 1 60); do
    ip="$(guest_ip "$VMID")"
    [[ -n "$ip" ]] && break
    sleep 5
  done

  if [[ -n "$ip" ]]; then
    log "box is up at ${ip}"
    log "watch provisioning:  ssh ${ADMIN_USER}@${ip} tail -f /var/log/cloud-init-output.log"
  else
    warn "agent did not report an address in 5 minutes; check 'qm terminal ${VMID}'"
  fi
}

case "${1:-}" in
  preflight) ./scripts/preflight.sh ;;
  salvage)   shift; cmd_salvage "$@" ;;
  template)  shift; cmd_template "$@" ;;
  render)    render_snippet ;;
  create)    cmd_create ;;
  *) echo "usage: $0 {preflight|salvage|template|render|create|rebuild}" >&2; exit 1 ;;
esac
