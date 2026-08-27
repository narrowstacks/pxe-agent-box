#!/usr/bin/env bash
#
# devbox.sh - runs on the PROXMOX HOST as root.
#
#   ./devbox.sh preflight  Verify the host can support the design.
#   ./devbox.sh salvage <vmid>  Copy auth state off a running box into $DATA_HOST_DIR.
#                           <vmid> is required and must not be the live $VMID.
#   ./devbox.sh template   Build the base template from the Debian cloud image.
#   ./devbox.sh render     Print the cloud-init snippet without writing it.
#   ./devbox.sh create     Clone the template into the running dev box.
#   ./devbox.sh rebuild    Destroy and recreate the box. /data is untouched.
#
# Set DRYRUN=1 to print the qm commands instead of running them.
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# DEVBOX_CONFIG points tests at a fixture config. Sourcing the real
# config.sh would clobber whatever the caller exported, so tests could not
# run on a machine without /root/.ssh.
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
  qm guest cmd "$1" network-get-interfaces </dev/null 2>/dev/null \
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

# Auth state worth carrying off the old box. Sources are relative to the
# admin user's home, destinations to $DATA_HOST_DIR/state. Excludes ~/.omp
# (starship owns the prompt) and the mise tree (toolchains are reinstalled
# from the manifest).
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
  # No default vmid. Salvaging the live box would rm -rf and overwrite, under
  # a running cache=always mount, the very paths its own ~/.claude and
  # ~/.config/gh are symlinked to. Both cases refuse before touching
  # anything.
  [[ $# -ge 1 ]] || fail "usage: devbox.sh salvage <vmid>  (no default; salvage requires an explicit SOURCE vmid, distinct from the live \$VMID in config.sh)"
  local src_vmid="$1"
  [[ "$src_vmid" != "$VMID" ]] \
    || fail "refusing: VMID $src_vmid is the live box (\$VMID in config.sh). Salvage rm -rf's and overwrites \$DATA_HOST_DIR/state, which the live box's ~/.claude, ~/.config/gh etc. are symlinked to; running it against the live VMID would corrupt the running box's own auth state. Pass the OLD/replaced box's vmid instead."
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
    # Keep the guest-side command one flat sh -c string with no newlines.
    if ! qm guest exec "$src_vmid" -- /bin/sh -c "test -e '$src'" >/dev/null 2>&1; then
      printf '  skip   %s (absent)\n' "$src"
      continue
    fi

    if [[ "${DRYRUN:-0}" == "1" ]]; then
      printf '  [dryrun] salvage %s -> %s\n' "$src" "$dst"
      continue
    fi

    # Warn and continue: aborting here would skip the chown below and leave
    # what was already extracted root-owned on a volume the guest reads as
    # uid 1000.
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
    # Temp name plus rename on success. wget writes partial bytes straight
    # to its target, so a failed download would leave a truncated file that
    # the -f test above accepts and --import-from then reads.
    run wget -qO "${IMAGE_PATH}.partial" "$CLOUD_IMAGE_URL"
    run mv "${IMAGE_PATH}.partial" "$IMAGE_PATH"
  fi

  log "creating template $TEMPLATE_ID"
  # --cpu x86-64-v3 on the template, so every clone inherits it and no future
  # code path can forget it. The PVE default (qemu64) lacks AVX2 and
  # bun-based binaries segfault at startup.
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

  # ENVIRON, never -v: awk processes escapes in a -v assignment, so a literal
  # backslash-n in a value becomes a real newline and injects a sibling YAML
  # key. index/substr rather than gsub, whose replacement treats & as the
  # matched text. Neither processes escapes, so values pass through as bytes.
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

  # Register through the API, never by hand-writing
  # /etc/pve/mapping/directory.cfg: its format carries no "dir:" section
  # prefix, and a hand-written file is silently ignored. Letting the API own
  # the format also survives a PVE release that changes it.
  if pvesh get /cluster/mapping/dir --output-format json 2>/dev/null \
     | grep -q "\"id\":\"${DATA_MAP_ID}\""; then
    return 0
  fi

  log "creating directory mapping '${DATA_MAP_ID}' -> ${DATA_HOST_DIR}"
  # Re-creating an existing mapping is an error, not a no-op, so the check
  # above is mandatory.
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

  # --balloon 0 is required, not preferred: PVE refuses virtiofs on a VM with
  # ballooning enabled.
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

##### rebuild #####

# ~/work lives on the VM disk, so a rebuild destroys it. Refuse unless every
# repo is clean and pushed; this gate is what makes the state-only
# persistence split safe.
#
# The host has no private key for the guest, so this and snapshot_work go
# through 'qm guest exec' plus the /data share both sides see as the same
# directory. The script is always written to a file and run by path, never
# inlined: nested quoting through guest exec corrupts silently.
assert_work_tree_clean() {
  log "checking ~/work for unsaved state"

  # Unique per invocation, never a fixed path: /data is cache=always, so the
  # guest serves its cached content for a name it has already read.
  local check_script
  check_script="${DATA_HOST_DIR}/.devbox-workcheck.$$.$(date -u +%s).sh"
  {
    printf 'work="/home/%s/work"\n' "$ADMIN_USER"
    cat <<'EOF'
set -uo pipefail
shopt -s nullglob dotglob
if [[ ! -d "$work" ]]; then
  echo "work directory missing: cannot verify, refusing to guess"
  exit 0
fi
for d in "$work"/*; do
  name="$(basename "$d")"
  if [[ -d "$d/.git" ]]; then
    if [[ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]]; then
      echo "uncommitted changes: $name"
    fi
    upstream="$(git -C "$d" rev-parse --abbrev-ref '@{u}' 2>/dev/null || true)"
    if [[ -z "$upstream" ]]; then
      echo "no upstream branch: $name"
    elif [[ -n "$(git -C "$d" log '@{u}..' --oneline 2>/dev/null)" ]]; then
      echo "unpushed commits: $name"
    fi
  elif [[ -d "$d" ]]; then
    if [[ -n "$(ls -A "$d" 2>/dev/null)" ]]; then
      echo "non-git directory with contents: $name"
    fi
  else
    echo "loose file: $name"
  fi
done
EOF
  } > "$check_script"

  # As ADMIN_USER, not guest exec's default root: git refuses repos it does
  # not own, and the gate would report failures that are not real.
  local raw rc
  raw="$(qm guest exec "$VMID" --timeout 60 -- /bin/sh -c \
    "su -s /bin/bash - '${ADMIN_USER}' -c 'bash /data/$(basename "$check_script")'" </dev/null 2>/dev/null)" && rc=0 || rc=$?
  rm -f "$check_script"

  [[ $rc -eq 0 ]] || fail "cannot reach the guest agent to check ~/work; pass --force to rebuild anyway"

  # A gate that cannot verify must refuse, never pass. A missing field, a
  # timed-out command, or a nonzero exitcode all exit 1 here, which the '||'
  # below turns into a refusal.
  local dirty
  dirty="$(printf '%s' "$raw" | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
    if d.get("exited") != 1 or d.get("exitcode", 1) != 0:
        raise ValueError("guest command did not exit cleanly: %r" % d)
except Exception as exc:
    print("workcheck failed: %s" % exc, file=sys.stderr)
    raise SystemExit(1)
sys.stdout.write(d.get("out-data", ""))')" \
    || fail "guest check script did not run cleanly; pass --force to rebuild anyway"

  [[ -z "$dirty" ]] && { log "work tree is clean"; return 0; }

  printf '\n\033[1;31mrefusing to rebuild:\033[0m ~/work has unsaved state\n' >&2
  printf '%s\n' "$dirty" >&2
  printf '\nCommit and push, or pass --force to discard it.\n' >&2
  exit 1
}

snapshot_work() {
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  run mkdir -p "${DATA_HOST_DIR}/work-snapshots"
  log "snapshotting ~/work to ${DATA_HOST_DIR}/work-snapshots/${stamp}.tar.zst"

  # Belt and braces behind the gate, not the primary mechanism. Skips the
  # regenerable directories, and the guest writes straight to /data.
  #
  # Unique filename per invocation, same cache=always reason as
  # assert_work_tree_clean's check_script.
  local snap_script
  snap_script="${DATA_HOST_DIR}/.devbox-snapshot.$$.$(date -u +%s).sh"
  cat > "$snap_script" <<EOF
tar -C "/home/${ADMIN_USER}" --exclude=node_modules --exclude=.venv --exclude=target --exclude=dist -cf - work | zstd -q -T0 -o "/data/work-snapshots/${stamp}.tar.zst"
EOF

  # Root is fine here: tar and zstd do not care about ownership the way git
  # does, so no su.
  local raw rc
  raw="$(qm guest exec "$VMID" --timeout 120 -- /bin/sh -c "bash /data/$(basename "$snap_script")" </dev/null 2>/dev/null)" && rc=0 || rc=$?
  rm -f "$snap_script"

  if [[ $rc -eq 0 ]] && printf '%s' "$raw" | python3 -c 'import json, sys
d = json.load(sys.stdin)
sys.exit(0 if d.get("exited") == 1 and d.get("exitcode", 1) == 0 else 1)' 2>/dev/null; then
    run chown 1000:1000 "${DATA_HOST_DIR}/work-snapshots/${stamp}.tar.zst"
  else
    warn "work snapshot failed; continuing because the clean-tree gate already passed"
  fi

  # Keep the last three. 'local old=()' with a bare "${old[@]}" is
  # deliberate: "${old[@]:-}" synthesises an empty element on the empty
  # array, which is the common case here. An empty array already expands to
  # zero words under set -u on bash 4.4+, so ':-' only introduces bugs.
  local old=()
  mapfile -t old < <(ls -1t "${DATA_HOST_DIR}/work-snapshots"/*.tar.zst 2>/dev/null | tail -n +4)
  for old_file in "${old[@]}"; do
    rm -f "$old_file"
  done

  # Explicit, not incidental. A failed snapshot is warned about above and
  # must never abort the rebuild, so the exit status must not depend on
  # whatever the loop happens to return.
  return 0
}

cmd_rebuild() {
  local force="${1:-}"

  # Before the destroy, not after: cmd_create's own preflight runs past the
  # 'qm destroy' below, where a failing network gate leaves no VM at all.
  # Failing here costs nothing, the box still exists.
  ./scripts/preflight.sh || fail "preflight failed"

  qm status "$VMID" </dev/null >/dev/null 2>&1 || fail "VMID $VMID does not exist; use 'create'"

  # For the operator's benefit only; the checks below use qm guest exec.
  local ip
  ip="$(guest_ip "$VMID")"
  log "current guest address: ${ip:-unknown}"

  if [[ "$force" != "--force" ]]; then
    assert_work_tree_clean
    snapshot_work
  fi

  log "rebuilding ${VMID}. ${DATA_HOST_DIR} on the host is NOT touched."
  read -rp "type the VM name to confirm (${VMNAME}): " confirm
  [[ "$confirm" == "$VMNAME" ]] || fail "aborted"

  run qm stop "$VMID" --timeout 60 || true
  # --destroy-unreferenced-disks 0 so nothing outside this VM's config is
  # touched. $DATA_HOST_DIR is never referenced by it at all.
  run qm destroy "$VMID" --destroy-unreferenced-disks 0 --purge 1

  cmd_create
}

case "${1:-}" in
  preflight) ./scripts/preflight.sh ;;
  salvage)   shift; cmd_salvage "$@" ;;
  template)  shift; cmd_template "$@" ;;
  render)    render_snippet ;;
  create)    cmd_create ;;
  rebuild)   shift; cmd_rebuild "$@" ;;
  *) echo "usage: $0 {preflight|salvage <vmid>|template|render|create|rebuild}" >&2; exit 1 ;;
esac
