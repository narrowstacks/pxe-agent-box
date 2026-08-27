# devbox Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the disposable-Ubuntu-fleet provisioning with one persistent, rebuildable Debian 13 dev box whose auth state survives every rebuild.

**Architecture:** Three layers with one job each. `devbox.sh` runs on the Proxmox host and owns the VM lifecycle (template, create, rebuild, salvage). A thin cloud-init snippet creates the account and mounts a virtiofs state volume. `bootstrap.sh` runs inside the guest and converges it, idempotently, forever. `scripts/smoke-test.sh` asserts the result from the Mac.

**Tech Stack:** bash, Proxmox VE 8.4 (`qm`, `pvesm`, virtiofs dir mappings), cloud-init, Debian 13 trixie, mise, systemd user units, shellcheck.

**Spec:** `docs/superpowers/specs/2026-08-27-devbox-rework-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- Shell style: `#!/usr/bin/env bash` and `set -euo pipefail` at the top of every script. Functions lowercase. Failures go through the existing `log` and `fail` helper pattern.
- **No em dashes** anywhere: not in output, not in docs, not in code comments.
- Every shell file must pass `bash -n` and `shellcheck -S warning` before commit.
- Every file written to `/etc/profile.d` must pass `dash -n`. `bootstrap.sh` validates its own output and aborts on failure.
- Base image: `https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2`
- `$ADMIN_USER` is pinned to **uid 1000** and the cloud-init `users:` list **omits `- default`**. Stable uid 1000 is what keeps `/srv/devdata` ownership correct across rebuilds.
- `--balloon 0` is **required** by PVE for virtiofs, not a preference. Comment it as such.
- `--cpu x86-64-v3` is set on the **template**, not per-clone. The default `qemu64` lacks AVX and bun-based binaries segfault without it.
- claude-code apt signing key fingerprint must equal `31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE` before the repo is registered.
- `ufw --force enable`, never `yes | ufw enable`. No pipeline under `pipefail` whose producer outlives its consumer.
- Multi-line commands as another user use `sudo -iu "$ADMIN_USER" bash -s <<'EOF'`. Never `sudo -i` with multi-line arguments; it joins on spaces and re-parses.
- Heredocs that generate files must be **quoted** (`<<'EOF'`) with explicit substitution afterward. An unquoted heredoc previously executed a `$(qm set --sshkeys ...)` that appeared inside a comment.
- `bootstrap.sh` is guarded by `flock`, never `pgrep -f` (which self-matches its own command line).
- Failure policy: core chain (apt base, Docker, user creation, `/data` mount and links) fails loudly and aborts. Optional tools (opencode, pi, codex, Chrome, moshi-hook, herdr) log `WARNING` and let the run complete.
- Host is `charon`, reached as `root@charon`. Scripts execute there, not on the Mac.

## Development Loop

Do **not** iterate on `bootstrap.sh` by rebuilding the VM. The loop is:

```sh
rsync -av bootstrap.sh root@charon:/root/agent-box/bootstrap.sh
ssh root@charon 'qm guest exec 104 -- /bin/sh -c "..."'   # or scp into the box over SSH
ssh dev@<box> 'sudo /usr/local/sbin/devbox-bootstrap'
./scripts/smoke-test.sh <box>
```

Only genuine first boot uses the curl-from-GitHub path. Push to `main` when a layer is green, because that is what the next `create` will fetch.

## File Structure

| File | Responsibility |
| --- | --- |
| `devbox.sh` | Host entrypoint. Verbs: `template`, `create`, `rebuild`, `salvage`, `render`. Sources `config.sh`. Honors `DRYRUN=1`. |
| `bootstrap.sh` | Guest convergence. Idempotent, `flock`-guarded, re-runnable as `sudo devbox-bootstrap`. Repo root so the raw URL is short. |
| `cloud-init/devbox.yaml.tpl` | Snippet template with `@PLACEHOLDER@` tokens, rendered by `devbox.sh render`. |
| `config.example.sh` | Committed reference for every knob. |
| `config.sh` | Machine-local, gitignored. |
| `scripts/preflight.sh` | Host: verifies every assumption in spec section 10 before anything is built. |
| `scripts/lint.sh` | Local: `bash -n` + `shellcheck -S warning` over every shell file. The inner-loop test command. |
| `scripts/smoke-test.sh` | Mac: the 17 assertions from spec section 7 against a booted box. |
| `tests/test-render.sh` | Local: unit tests for snippet rendering. Runs without a Proxmox host. |

Deleted at the end: `scripts/build-template.sh`, `scripts/create-vm.sh`, `scripts/delete-vm.sh`, `cloud-init/provision.sh`. `HANDOFF-SIMPLIFICATION.md` is retained as the record justifying the rules above.

---

### Task 1: Lint harness and configuration reference

Establishes the inner-loop test command before any real code exists, so every later task has something to run.

**Files:**
- Create: `scripts/lint.sh`
- Create: `config.example.sh` (replacing the existing one wholesale)
- Modify: `config.sh` (machine-local, add the new knobs)

**Interfaces:**
- Consumes: nothing
- Produces: `./scripts/lint.sh` exits 0 when clean, non-zero with findings otherwise. Config variables consumed by every later task: `STORAGE`, `SNIPPET_STORAGE`, `BRIDGE`, `NET_VLAN_TAG`, `TEMPLATE_ID`, `VMID`, `VMNAME`, `VM_CORES`, `VM_MEMORY_MB`, `VM_DISK_SIZE_GB`, `STATIC_IP`, `GATEWAY`, `SEARCH_DOMAIN`, `ADMIN_USER`, `GUEST_TIMEZONE`, `SSH_KEY_FILES`, `DATA_HOST_DIR`, `DATA_MAP_ID`, `CLOUD_IMAGE_URL`, `BOOTSTRAP_URL`, `MISE_TOOLS`, `SWAP_SIZE_GB`, `ENABLE_UFW`, `EXTRA_APT_PACKAGES`.

- [ ] **Step 1: Write the failing test**

Create `scripts/lint.sh`:

```bash
#!/usr/bin/env bash
# Local test command. Runs over every shell file in the repo.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
mapfile -t files < <(git ls-files '*.sh')

for f in "${files[@]}"; do
  if ! bash -n "$f"; then
    echo "bash -n FAILED: $f" >&2
    fail=1
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  # config.sh files are sourced, not executed; tell shellcheck so.
  shellcheck -S warning "${files[@]}" || fail=1
elif [[ "${LINT_ALLOW_NO_SHELLCHECK:-0}" == "1" ]]; then
  echo "WARNING: shellcheck not installed, skipping (LINT_ALLOW_NO_SHELLCHECK=1)" >&2
else
  # Every later task reports against this gate. A gate that announces
  # success when its main check never ran is worse than no gate.
  echo "ERROR: shellcheck not installed. Run 'brew install shellcheck', or set LINT_ALLOW_NO_SHELLCHECK=1 to skip." >&2
  fail=1
fi

# Every file destined for /etc/profile.d must parse under dash, because
# Debian sources profile.d for dash login shells too. A bash-only construct
# there makes 'sh -lc' exit 2 and silently breaks Moshi's hook detection.
if [[ -d profile.d ]]; then
  for f in profile.d/*.sh; do
    [[ -e "$f" ]] || continue
    if ! dash -n "$f"; then
      echo "dash -n FAILED: $f" >&2
      fail=1
    fi
  done
fi

[[ $fail -eq 0 ]] && echo "lint: clean"
exit "$fail"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x scripts/lint.sh && ./scripts/lint.sh`
Expected: FAIL. The existing `scripts/create-vm.sh`, `build-template.sh`, `delete-vm.sh` and `cloud-init/provision.sh` are still present and may have findings. Record the exact findings as the **baseline** so a later failure can be attributed. If it already passes, record "baseline clean" instead.

- [ ] **Step 3: Write `config.example.sh`**

```bash
# agent-box configuration reference. Copy to config.sh and edit.
# Every variable here is consumed by devbox.sh and scripts/*.sh.
# shellcheck shell=bash disable=SC2034

##### Proxmox infrastructure #####

STORAGE="local-lvm"          # pvesm status; must be images-capable
SNIPPET_STORAGE="local"      # where the cloud-init snippet is written
BRIDGE="vmbr0"
NET_VLAN_TAG=""

TEMPLATE_ID="9000"
VMID="104"
VMNAME="devbox"

##### Box sizing #####
# NOTE: --balloon 0 is forced by devbox.sh because PVE requires ballooning
# disabled for virtiofs. Size VM_MEMORY_MB against the host's real RAM:
# charon has 32 GB with ~12 GB committed to other VMs, so 16 GB fits and
# 24 GB does not. scripts/preflight.sh checks this before every create.

VM_CORES="8"
VM_MEMORY_MB="16384"
VM_DISK_SIZE_GB="160"

STATIC_IP=""                 # e.g. "10.0.0.42/24"; empty means DHCP
GATEWAY=""
SEARCH_DOMAIN=""

##### Guest account #####

ADMIN_USER="dev"             # created at uid 1000; see cloud-init template
GUEST_TIMEZONE="America/Los_Angeles"

# Resolved ON THE PVE HOST. Absolute paths only.
SSH_KEY_FILES="/root/.ssh/id_ed25519.pub /root/.ssh/id_ed25519_iphone.pub"

##### Persistent state volume #####
# A plain host directory exposed to the guest over virtiofs as /data.
# It is never referenced by the VM config, so no destroy path can reach it.

DATA_HOST_DIR="/srv/devdata"
DATA_MAP_ID="devdata"

##### Images and bootstrap #####

CLOUD_IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"

# Pin to a tag or commit SHA once the box is stable, so an in-flight push
# to main cannot change what a rebuild installs.
BOOTSTRAP_URL="https://raw.githubusercontent.com/narrowstacks/pxe-agent-box/main/bootstrap.sh"

##### Guest provisioning knobs #####

# mise owns the user toolchain tree. Toolchains live on the VM disk and are
# reinstalled from ~/.config/mise on rebuild; only the manifest persists.
MISE_TOOLS="node@lts python@3.13 bun@latest"

SWAP_SIZE_GB="8"
ENABLE_UFW="1"
EXTRA_APT_PACKAGES=""
```

- [ ] **Step 4: Update the machine-local `config.sh`**

Copy the new knobs into `config.sh`, preserving the verified local values (`STORAGE="local-lvm"`, the two real `SSH_KEY_FILES` paths, `GUEST_TIMEZONE`). Remove the retired knobs `NODE_MAJOR`, `NPM_GLOBALS`, `PIP_PACKAGES`, `GUEST_HOSTNAME_PREFIX`. `config.sh` is gitignored; confirm with `git check-ignore -v config.sh`.

- [ ] **Step 5: Run the lint to verify it passes**

Run: `./scripts/lint.sh`
Expected: clean, or exactly the baseline findings from Step 2 and nothing new.

- [ ] **Step 6: Commit**

```bash
git add scripts/lint.sh config.example.sh
git commit -m "build: add lint harness and rework config reference

lint.sh is the inner-loop test command: bash -n plus shellcheck over
every tracked shell file, and dash -n over anything destined for
/etc/profile.d."
```

---

### Task 2: Host preflight verification

Spec section 10 lists five unverified assumptions. This task turns them into a committed script rather than a one-off manual check, because `devbox.sh create` will reuse it.

**Files:**
- Create: `scripts/preflight.sh`

**Interfaces:**
- Consumes: `config.sh` variables from Task 1.
- Produces: `scripts/preflight.sh` exits 0 when the host can support the design, non-zero with a specific reason otherwise. `devbox.sh create` calls it in Task 7.

- [ ] **Step 1: Write the check script**

```bash
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
for k in $SSH_KEY_FILES; do
  if [[ -s "$k" ]]; then ok "$k"; else bad "$k missing or empty"; fi
done

log "third-party apt repos for trixie"
check_repo() {  # check_repo <label> <url>
  # GET, not HEAD: some endpoints reject HEAD while serving fine over GET
  # (mise.run does exactly this). -L to follow redirects: without it a 3xx
  # returns 0 and the check passes without confirming the target serves the
  # file at all, which is the one failure mode this gate exists to catch.
  if curl -fsSL -o /dev/null --max-time 15 "$2"; then ok "$1"; else bad "$1 unreachable: $2"; fi
}
check_repo "docker trixie"    "https://download.docker.com/linux/debian/dists/trixie/Release"
check_repo "tailscale trixie" "https://pkgs.tailscale.com/stable/debian/dists/trixie/Release"
check_repo "github cli"       "https://cli.github.com/packages/dists/stable/Release"
check_repo "claude-code"      "https://downloads.claude.ai/claude-code/apt/stable/dists/stable/Release"
check_repo "google chrome"    "https://dl.google.com/linux/chrome/deb/dists/stable/Release"

# Not routed through check_repo: a full GET would download the ~350 MB image.
# A single-byte range request proves the URL serves content without pulling it.
if curl -fsSL -o /dev/null --max-time 15 -r 0-0 "$CLOUD_IMAGE_URL"; then
  ok "debian image"
else
  bad "debian image unreachable: $CLOUD_IMAGE_URL"
fi

log "data volume"
df -h "$(dirname "$DATA_HOST_DIR")" | tail -1

if (( failures > 0 )); then
  printf '\n\033[1;31m%d check(s) failed.\033[0m Fix these before building.\n' "$failures" >&2
  exit 1
fi
printf '\n\033[1;32mpreflight clean.\033[0m\n'
```

- [ ] **Step 2: Lint it**

Run: `./scripts/lint.sh`
Expected: clean.

- [ ] **Step 3: Run it on charon**

```bash
rsync -av --delete --exclude .git --exclude .pi ./ root@charon:/root/agent-box/
scp config.sh root@charon:/root/agent-box/config.sh
ssh root@charon 'cd /root/agent-box && ./scripts/preflight.sh'
```

Expected: either clean, or a specific failure. **If `docker trixie` or `tailscale trixie` fails, stop and report it.** The spec's fallback is the bookworm suite with an inline comment explaining why, and that changes Task 9. Do not silently paper over it.

- [ ] **Step 4: Record the results**

Write the actual host RAM, the docker/tailscale repo verdicts, and the `df` output into the task notes. Later tasks depend on these numbers.

- [ ] **Step 5: Commit**

```bash
git add scripts/preflight.sh
git commit -m "build: add host preflight checks

One check per risk in the design spec section 10: virtiofsd presence,
storage, memory headroom, VMID collisions, SSH keys, and reachability of
every third-party apt suite for trixie."
```

---

### Task 3: `devbox.sh` skeleton and `salvage`

Salvage runs first because it reads the old box, and the old box occupies the VMID the new one will take. Nothing is destroyed in this task.

**Files:**
- Create: `devbox.sh`

**Interfaces:**
- Consumes: `config.sh` from Task 1.
- Produces: `log`, `fail`, `run` helpers and the verb dispatcher used by Tasks 4, 7, and 13. `run` honors `DRYRUN=1` by printing instead of executing, which is how later tasks are tested without burning VM builds.

- [ ] **Step 1: Write the skeleton and the salvage verb**

```bash
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
    # uid 1000. Warn and continue, matching optional steps elsewhere.
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
    local landed="${dest}/$(basename "$src")"
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
```

- [ ] **Step 2: Lint it**

Run: `./scripts/lint.sh`
Expected: clean. Note `shellcheck` will flag `$(basename ...)` inside a `local` assignment as SC2155 (masked return value); split the declaration if it exceeds warning severity.

> **STEPS 3 AND 4 ARE SKIPPED.** The user destroyed VM 104 before execution
> began, so there is no live box to salvage from and the ~8.2 MB of
> claude/gh/herdr/moshi auth state is gone. Implement the verb (the spec
> specifies it and it serves future migrations), lint it, and dry-run only
> the argument handling. Re-establishing auth by hand once on the new box
> replaces it. Do not attempt to run salvage against VMID 104.

- [ ] **Step 3: Dry-run it on charon**

```bash
rsync -av --delete --exclude .git --exclude .pi ./ root@charon:/root/agent-box/
ssh root@charon 'cd /root/agent-box && DRYRUN=1 ./devbox.sh salvage 104'
```

Expected: prints one `[dryrun] salvage` line per present path, skips absent ones. No files written.

- [ ] **Step 4: Run it for real**

```bash
ssh root@charon 'cd /root/agent-box && ./devbox.sh salvage 104'
```

Expected: `~8 MB` total, dominated by `claude`. Verify by hand before continuing, because VM 104 is destroyed in Task 7:

```bash
ssh root@charon 'ls -la /srv/devdata/state/ && du -sh /srv/devdata/state/*'
ssh root@charon 'test -s /srv/devdata/state/claude.json && echo "claude.json non-empty"'
ssh root@charon 'ls /srv/devdata/state/config-gh/hosts.yml && echo "gh auth present"'
```

- [ ] **Step 5: Commit**

```bash
git add devbox.sh
git commit -m "feat: devbox.sh skeleton with salvage verb

Salvage lands first because it reads the old box and the new box reuses
its VMID. Excludes ~/.omp (starship is the sole prompt owner) and the
mise tree (toolchains reinstall from the manifest)."
```

---

### Task 4: `devbox.sh template`

**Files:**
- Modify: `devbox.sh`

**Interfaces:**
- Consumes: `log`, `fail`, `run` from Task 3.
- Produces: a Debian 13 template at `$TEMPLATE_ID` that Task 7's `create` clones.

- [ ] **Step 1: Add the template verb**

Insert before the `case` block:

```bash
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
    run wget -qO "$IMAGE_PATH" "$CLOUD_IMAGE_URL"
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
```

Add `template) shift; cmd_template "$@" ;;` to the `case`.

- [ ] **Step 2: Lint and dry-run**

```bash
./scripts/lint.sh
rsync -av --delete --exclude .git --exclude .pi ./ root@charon:/root/agent-box/
ssh root@charon 'cd /root/agent-box && DRYRUN=1 ./devbox.sh template --force'
```

Expected: prints the `qm destroy`, `wget`, `qm create`, `qm template` lines. Read the `qm create` line and confirm `--cpu x86-64-v3` and `--ide2 ${STORAGE}:cloudinit` are present. The cloud-init drive must be on images-capable storage; `local` is a directory store and will fail at create time.

- [ ] **Step 3: Build it for real**

```bash
ssh root@charon 'cd /root/agent-box && ./devbox.sh template'
```

Expected: completes in roughly 5 minutes. `--force` is not needed: the user destroyed the old Ubuntu template before execution began, so VMID 9000 is free. Keep the `--force` code path; it is how future template upgrades work.

- [ ] **Step 4: Verify the template config**

```bash
ssh root@charon 'qm config 9000'
```

Assert: `template: 1`, `cpu: x86-64-v3`, `agent: enabled=1,fstrim_cloned_disks=1`, `ide2` names `cloudinit`, `scsi0` is on `local-lvm`.

- [ ] **Step 5: Commit**

```bash
git add devbox.sh
git commit -m "feat: devbox.sh template verb, Debian 13 trixie

x86-64-v3 is set on the template rather than per-clone so the AVX fix
cannot be forgotten by a future code path."
```

---

### Task 5: Cloud-init snippet template and renderer

Rendering is pure text transformation, so it gets real unit tests that run on the Mac with no Proxmox host.

**Files:**
- Create: `cloud-init/devbox.yaml.tpl`
- Create: `tests/test-render.sh`
- Modify: `devbox.sh` (add `render_snippet` and the `render` verb)

**Interfaces:**
- Consumes: `log`, `fail` from Task 3.
- Produces: `render_snippet()` writes the rendered YAML to stdout. Task 7's `create` redirects it into the snippet path.

- [ ] **Step 1: Write the failing test**

Create `tests/test-render.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for cloud-init snippet rendering. Runs on the Mac, no PVE needed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

pass=0; fail=0
check() {  # check <description> <condition-exit-code>
  if [[ "$2" -eq 0 ]]; then
    printf '  \033[1;32mok\033[0m   %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1))
  fi
}

# Render against a fixture config so the test does not depend on config.sh.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/key1.pub" <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAATEST1 test@one
EOF
cat > "$tmp/key2.pub" <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAATEST2 test@two
EOF

# A fixture config, not environment overrides: devbox.sh sources its config
# file, which would clobber anything the caller exported.
cat > "$tmp/config.sh" <<EOF
VMNAME="testbox"
ADMIN_USER="dev"
GUEST_TIMEZONE="UTC"
DATA_MAP_ID="devdata"
BOOTSTRAP_URL="https://example.invalid/bootstrap.sh"
MISE_TOOLS="node@lts"
SWAP_SIZE_GB="8"
ENABLE_UFW="1"
EXTRA_APT_PACKAGES=""
SSH_KEY_FILES="$tmp/key1.pub $tmp/key2.pub"
EOF

out="$(DEVBOX_CONFIG="$tmp/config.sh" ./devbox.sh render)"

printf '%s\n' "$out" > "$tmp/rendered.yaml"

python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$tmp/rendered.yaml" 2>/dev/null
check "renders valid YAML" $?

grep -q '^#cloud-config' "$tmp/rendered.yaml"
check "starts with the #cloud-config header" $?

# Omitting '- default' frees uid 1000 from Debian's built-in user. This is
# load-bearing: stable uid 1000 keeps /srv/devdata ownership correct forever.
! grep -qE '^\s+- default\s*$' "$tmp/rendered.yaml"
check "omits '- default' from users" $?

grep -q 'uid: 1000' "$tmp/rendered.yaml"
check "pins the admin user to uid 1000" $?

grep -q 'TEST1' "$tmp/rendered.yaml" && grep -q 'TEST2' "$tmp/rendered.yaml"
check "embeds every SSH key" $?

grep -q 'virtiofs' "$tmp/rendered.yaml" && grep -q '/data' "$tmp/rendered.yaml"
check "mounts /data over virtiofs" $?

grep -q 'TS_STATE_DIR=/data/state/tailscale' "$tmp/rendered.yaml"
check "sets the tailscaled state dir override" $?

# No Tailscale auth key belongs in a snippet. State on /data means tailscaled
# comes back authenticated after a rebuild without one.
! grep -q 'tskey-' "$tmp/rendered.yaml"
check "contains no tailscale auth key" $?

! grep -qE 'fs_setup|disk_setup' "$tmp/rendered.yaml"
check "contains no fs_setup or disk_setup" $?

grep -q 'path: /etc/devbox.env' "$tmp/rendered.yaml" && grep -q 'MISE_TOOLS="node@lts"' "$tmp/rendered.yaml"
check "renders /etc/devbox.env carrying host config into the guest" $?

! grep -qE '@[A-Z_]+@' "$tmp/rendered.yaml"
check "leaves no unsubstituted placeholders" $?

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x tests/test-render.sh && ./tests/test-render.sh`
Expected: FAIL, because `devbox.sh` has no `render` verb yet.

- [ ] **Step 3: Write the template**

Create `cloud-init/devbox.yaml.tpl`. `@TOKEN@` markers are substituted by `render_snippet`. This file is data, not shell, so it is never sourced.

```yaml
#cloud-config
#
# Rendered by devbox.sh; do not edit the installed copy under snippets/.
#
# Deliberately thin: create the account, mount /data, hand off to
# bootstrap.sh. Everything else is convergence, and convergence belongs in a
# script that can be re-run.

hostname: @VMNAME@
preserve_hostname: false
timezone: @GUEST_TIMEZONE@

# IMPORTANT: no "- default" entry. Omitting it prevents the Debian image's
# built-in 'debian' user from being created, which frees uid 1000 for the
# admin user. Stable uid 1000 is what keeps /srv/devdata ownership correct
# across every rebuild. Do not add it back.
users:
  - name: @ADMIN_USER@
    uid: 1000
    groups: [sudo]
    shell: /usr/bin/zsh
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
@SSH_KEYS@

package_update: true

# Only what is needed to reach bootstrap.sh. bootstrap installs the rest,
# so this list stays short and the two never drift.
packages:
  - curl
  - ca-certificates
  - zsh
  - qemu-guest-agent

# The persistent state volume. A Proxmox directory mapping exposed over
# virtiofs; the mounts module runs at config stage, before runcmd at final
# stage, so /data is available to bootstrap.
mounts:
  - [ "@DATA_MAP_ID@", "/data", "virtiofs", "defaults,nofail", "0", "0" ]

write_files:
  # The ONLY channel carrying host config.sh values into the guest.
  # bootstrap.sh is curl'd standalone from GitHub and has no other way to
  # learn them, so without this file every knob silently takes its default.
  - path: /etc/devbox.env
    permissions: "0644"
    content: |
      DEV_USER="@ADMIN_USER@"
      MISE_TOOLS="@MISE_TOOLS@"
      SWAP_SIZE_GB="@SWAP_SIZE_GB@"
      ENABLE_UFW="@ENABLE_UFW@"
      EXTRA_APT_PACKAGES="@EXTRA_APT_PACKAGES@"
      BOOTSTRAP_URL="@BOOTSTRAP_URL@"

  # Persist tailscale's node identity so rebuilds keep the same MagicDNS
  # name instead of producing devbox-1, devbox-2, devbox-3.
  - path: /etc/systemd/system/tailscaled.service.d/override.conf
    permissions: "0644"
    content: |
      [Service]
      Environment=TS_STATE_DIR=/data/state/tailscale

runcmd:
  - systemctl enable --now qemu-guest-agent
  - mkdir -p /data/state /data/work-snapshots
  - chown 1000:1000 /data/state /data/work-snapshots
  - curl -fsSL "@BOOTSTRAP_URL@" -o /usr/local/sbin/devbox-bootstrap
  - chmod 0755 /usr/local/sbin/devbox-bootstrap
  - /usr/local/sbin/devbox-bootstrap

final_message: "devbox base ready after $UPTIME seconds; bootstrap log in /var/log/cloud-init-output.log"
```

- [ ] **Step 4: Write the renderer**

Add to `devbox.sh` before the `case` block:

```bash
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

  # Substitute with awk rather than sed so key material containing slashes
  # or ampersands cannot corrupt the output.
  awk -v vmname="$VMNAME" \
      -v adminuser="$ADMIN_USER" \
      -v tz="$GUEST_TIMEZONE" \
      -v mapid="$DATA_MAP_ID" \
      -v bootstrap="$BOOTSTRAP_URL" \
      -v misetools="${MISE_TOOLS:-}" \
      -v swapgb="${SWAP_SIZE_GB:-8}" \
      -v enableufw="${ENABLE_UFW:-1}" \
      -v extraapt="${EXTRA_APT_PACKAGES:-}" \
      -v keys="$keys" '
    { line = $0
      gsub(/@VMNAME@/,             vmname,     line)
      gsub(/@ADMIN_USER@/,         adminuser,  line)
      gsub(/@GUEST_TIMEZONE@/,     tz,         line)
      gsub(/@DATA_MAP_ID@/,        mapid,      line)
      gsub(/@BOOTSTRAP_URL@/,      bootstrap,  line)
      gsub(/@MISE_TOOLS@/,         misetools,  line)
      gsub(/@SWAP_SIZE_GB@/,       swapgb,     line)
      gsub(/@ENABLE_UFW@/,         enableufw,  line)
      gsub(/@EXTRA_APT_PACKAGES@/, extraapt,   line)
      if (line == "@SSH_KEYS@") { print keys } else { print line }
    }' "$tpl"
}
```

Add `render) render_snippet ;;` to the `case`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./tests/test-render.sh`
Expected: 10 passed, 0 failed. Also run `./scripts/lint.sh` and confirm clean.

- [ ] **Step 6: Commit**

```bash
git add cloud-init/devbox.yaml.tpl tests/test-render.sh devbox.sh
git commit -m "feat: cloud-init snippet template and renderer

Substitution uses awk rather than sed so key material containing slashes
or ampersands cannot corrupt the output. Tests assert the load-bearing
properties: no '- default', uid 1000 pinned, no tailscale auth key, no
fs_setup, no unsubstituted placeholders."
```

---

### Task 6: `bootstrap.sh` core chain

The first version must be good enough for `create` in Task 7 to produce a reachable box. Optional tools come in Tasks 9 through 12.

**Files:**
- Create: `bootstrap.sh`

**Interfaces:**
- Consumes: nothing (runs standalone in the guest).
- Produces: `log`, `warn`, `fail`, `as_user`, `link_state` used by Tasks 9 through 12. `/usr/local/sbin/devbox-bootstrap` is re-runnable with `--update` re-fetching itself.

- [ ] **Step 1: Write the core chain**

```bash
#!/usr/bin/env bash
#
# devbox bootstrap: converges a Debian 13 VM into a dev box.
# Idempotent. Safe to re-run at any time: sudo devbox-bootstrap
#
# Rules this script exists to enforce, each from a real incident:
#   1. One tool, one install tree, chosen by who updates it. No cross-tree
#      symlinks or copies.
#   2. Every file written to /etc/profile.d must parse under dash.
#   3. ~/.zshrc is managed and lives on /data. starship owns the prompt.
#   4. No 'sudo -i' with multi-line arguments. No pipeline under pipefail
#      whose producer outlives its consumer.
#
set -euo pipefail

# Host config.sh values arrive through this file, written by cloud-init.
# Sourced BEFORE the defaults below so the defaults act as fallbacks.
# shellcheck source=/dev/null
[[ -r /etc/devbox.env ]] && source /etc/devbox.env

DEV_USER="${DEV_USER:-dev}"
DEV_HOME="/home/${DEV_USER}"
DATA="${DATA:-/data}"
BOOTSTRAP_URL="${BOOTSTRAP_URL:-https://raw.githubusercontent.com/narrowstacks/pxe-agent-box/main/bootstrap.sh}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-8}"
ENABLE_UFW="${ENABLE_UFW:-1}"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Multi-line commands as the dev user go through stdin, never as arguments.
# 'sudo -i' joins its arguments with spaces and re-parses them, which
# destroys quoting and newlines.
as_user() { sudo -iu "$DEV_USER" bash -s; }

# An optional step: log a WARNING and continue. The core chain does not use
# this; a base-package or Docker failure must abort loudly.
optional() {  # optional <label> <command...>
  local label="$1"; shift
  if "$@"; then return 0; fi
  warn "optional step failed: ${label}"
  return 0
}

##### guards #####

[[ $EUID -eq 0 ]] || fail "run as root"

if [[ "${1:-}" == "--update" ]]; then
  log "re-fetching bootstrap from ${BOOTSTRAP_URL}"
  curl -fsSL "$BOOTSTRAP_URL" -o /usr/local/sbin/devbox-bootstrap.new
  bash -n /usr/local/sbin/devbox-bootstrap.new \
    || fail "downloaded bootstrap does not parse; refusing to install it"
  mv /usr/local/sbin/devbox-bootstrap.new /usr/local/sbin/devbox-bootstrap
  chmod 0755 /usr/local/sbin/devbox-bootstrap
  exec /usr/local/sbin/devbox-bootstrap
fi

# flock, not pgrep -f. pgrep -f matches its own command line and always finds
# itself, which is how a previous guard silently never fired. A qemu-ga
# restart once orphaned half a run and a second instance raced dpkg locks.
exec 9>/var/lock/devbox-bootstrap.lock
flock -n 9 || fail "another devbox-bootstrap is already running"

id "$DEV_USER" >/dev/null 2>&1 || fail "user $DEV_USER does not exist"
mountpoint -q "$DATA" || fail "$DATA is not a mountpoint; virtiofs did not come up"

export DEBIAN_FRONTEND=noninteractive

##### 1. base packages #####

log "base packages"
apt-get update -qq
apt-get install -y --no-install-recommends \
  zsh zsh-autosuggestions zsh-syntax-highlighting \
  git git-lfs curl wget ca-certificates gnupg lsb-release \
  build-essential pkg-config libssl-dev \
  tmux htop btop jq unzip zip zstd rsync tree \
  ripgrep fd-find bat fzf zoxide \
  sqlite3 strace lsof ncdu \
  mosh ufw xvfb \
  python3 python3-venv \
  qemu-guest-agent \
  bsdutils \
  ${EXTRA_APT_PACKAGES:-}   # shellcheck disable=SC2086  # word splitting intended

# Debian ships these under alternate binary names.
ln -sf "$(command -v fdfind)" /usr/local/bin/fd
ln -sf "$(command -v batcat)" /usr/local/bin/bat

##### 2. system tuning #####

log "kernel and limit tuning"

# Vite, webpack, nodemon and jest watchers exhaust the default inotify budget
# fast and fail with a confusing ENOSPC. The single most common dev-VM papercut.
cat >/etc/sysctl.d/60-devbox.conf <<'EOF'
fs.inotify.max_user_watches   = 1048576
fs.inotify.max_user_instances = 1024
fs.file-max                   = 2097152
vm.max_map_count              = 262144
vm.swappiness                 = 10
EOF
sysctl --system >/dev/null

cat >/etc/security/limits.d/60-devbox.conf <<'EOF'
*  soft  nofile  1048576
*  hard  nofile  1048576
EOF

mkdir -p /etc/systemd/system.conf.d
cat >/etc/systemd/system.conf.d/60-devbox.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF

# tmpfs /tmp keeps build scratch off the virtual disk entirely.
if ! systemctl is-enabled tmp.mount >/dev/null 2>&1; then
  cp /usr/share/systemd/tmp.mount /etc/systemd/system/tmp.mount 2>/dev/null || true
  systemctl enable tmp.mount 2>/dev/null || true
fi

# OOM cushion. Parallel test workers spike hard.
if [[ ! -f /swapfile ]]; then
  fallocate -l "${SWAP_SIZE_GB}G" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

##### 3. persistent state links #####

log "persistent state links"

# link_state <path-under-$DATA/state> <path-relative-to-$DEV_HOME>
# If the destination already exists as a real file or directory, its contents
# move into $DATA first. That is what makes salvaged state and a fresh first
# boot converge on the same place.
link_state() {
  local src="${DATA}/state/$1" dst="${DEV_HOME}/$2"
  mkdir -p "$(dirname "$src")" "$(dirname "$dst")"

  if [[ -e "$dst" && ! -L "$dst" ]]; then
    if [[ -d "$dst" ]]; then
      mkdir -p "$src"
      cp -a "$dst/." "$src/" 2>/dev/null || true
    else
      [[ -e "$src" ]] || cp -a "$dst" "$src"
    fi
    rm -rf "$dst"
  fi

  # Create the source if it still does not exist, matching the destination's
  # intended type. Callers pass a trailing marker via link_state_file for files.
  [[ -e "$src" ]] || mkdir -p "$src"
  ln -sfn "$src" "$dst"
  chown -R "1000:1000" "$src"
}

# Same, for entries that must be files rather than directories.
link_state_file() {
  local src="${DATA}/state/$1" dst="${DEV_HOME}/$2"
  mkdir -p "$(dirname "$src")" "$(dirname "$dst")"
  if [[ -f "$dst" && ! -L "$dst" ]]; then
    [[ -e "$src" ]] || cp -a "$dst" "$src"
    rm -f "$dst"
  fi
  [[ -e "$src" ]] || : > "$src"
  ln -sfn "$src" "$dst"
  chown "1000:1000" "$src"
}

link_state      claude           .claude
link_state_file claude.json      .claude.json
link_state      config-gh        .config/gh
link_state      config-herdr     .config/herdr
link_state      config-moshi     .config/moshi
link_state      config-opencode  .config/opencode
link_state      config-mise      .config/mise
link_state      codex            .codex
link_state      pi               .pi
link_state      zsh-history      .zsh_history.d
link_state_file gitconfig        .gitconfig

# ~/.ssh stays a REAL directory so cloud-init keeps ownership of
# authorized_keys, which it rewrites on every boot. Only the files that
# should outlive a rebuild are linked individually.
mkdir -p "${DEV_HOME}/.ssh" "${DATA}/state/ssh"
chmod 700 "${DEV_HOME}/.ssh"
link_state_file ssh/known_hosts   .ssh/known_hosts
chown -R 1000:1000 "${DATA}/state/ssh"

mkdir -p "${DATA}/work-snapshots"
chown 1000:1000 "${DATA}/work-snapshots"

# Work trees live on the VM disk, not on /data. They are fast, large, and
# durable via git remotes. devbox.sh rebuild gates on a clean tree.
mkdir -p "${DEV_HOME}/work"
chown 1000:1000 "${DEV_HOME}/work"

chsh -s /usr/bin/zsh "$DEV_USER" || warn "chsh failed"

##### 4. firewall #####

if [[ "$ENABLE_UFW" == "1" ]]; then
  log "firewall"
  ufw allow OpenSSH >/dev/null
  # mosh survives laptop sleep and network switches.
  ufw allow 60000:61000/udp >/dev/null
  # --force, never 'yes | ufw enable'. Under pipefail the producer outlives
  # the consumer and SIGPIPE killed provisioning right after the firewall
  # came up, which read as a silent late-stage failure.
  ufw --force enable >/dev/null
fi

log "core chain complete"
```

- [ ] **Step 2: Lint it**

Run: `./scripts/lint.sh`
Expected: clean.

- [ ] **Step 3: Push to main**

`create` in Task 7 curls this from `main`, so it must be there first.

```bash
git add bootstrap.sh
git commit -m "feat: bootstrap.sh core chain

flock rather than pgrep -f, which self-matches. Asserts /data is a
mountpoint before doing anything. ~/.ssh stays a real directory so
cloud-init keeps ownership of authorized_keys; only known_hosts is linked."
git push origin main
```

- [ ] **Step 4: Verify the raw URL resolves**

```bash
curl -fsSL https://raw.githubusercontent.com/narrowstacks/pxe-agent-box/main/bootstrap.sh | head -5
```

Expected: the shebang and the comment header. If this 404s, `create` will produce an unprovisioned box.

---

### Task 7: `devbox.sh create` and first boot

Destroys VM 104. Salvage (Task 3) must be verified complete before starting.

**Files:**
- Modify: `devbox.sh`

**Interfaces:**
- Consumes: `render_snippet` from Task 5, `run`/`log`/`fail` from Task 3, `scripts/preflight.sh` from Task 2.
- Produces: `ensure_data_mapping()` and `cmd_create()`, both called by `rebuild` in Task 13.

- [ ] **Step 1: Add the dir mapping helper and create verb**

```bash
##### create #####

ensure_data_mapping() {
  run mkdir -p "$DATA_HOST_DIR"
  run mkdir -p /etc/pve/mapping

  if grep -q "^dir: ${DATA_MAP_ID}\$" /etc/pve/mapping/dir.cfg 2>/dev/null; then
    return 0
  fi

  log "creating directory mapping '${DATA_MAP_ID}' -> ${DATA_HOST_DIR}"
  if [[ "${DRYRUN:-0}" == "1" ]]; then
    printf '  [dryrun] append dir mapping %s\n' "$DATA_MAP_ID"
    return 0
  fi
  # The map line must be TAB-indented; PVE's parser rejects spaces.
  printf '\ndir: %s\n\tmap node=%s,path=%s\n' \
    "$DATA_MAP_ID" "$(hostname)" "$DATA_HOST_DIR" >>/etc/pve/mapping/dir.cfg
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
  local ip="" i
  for i in $(seq 1 60); do
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
```

Add `create) cmd_create ;;` to the `case`.

- [ ] **Step 2: Lint and dry-run**

```bash
./scripts/lint.sh
rsync -av --delete --exclude .git --exclude .pi ./ root@charon:/root/agent-box/
ssh root@charon 'cd /root/agent-box && DRYRUN=1 ./devbox.sh create'
```

Expected: dry-run aborts at the VMID-exists guard because 104 is still alive. That is correct behavior; read the rendered snippet in the output and confirm it looks right.

- [ ] **Step 3: Confirm VMID 104 is free**

Already satisfied: the user destroyed VM 104 before execution began, and
there was no salvage to confirm. Just verify the id is actually free, since
`create` refuses otherwise.

```bash
ssh root@charon 'qm list'
```

Expected: 104 absent. Only 206 and 800 should be running.

- [ ] **Step 4: Create the box**

```bash
ssh root@charon 'cd /root/agent-box && ./devbox.sh create'
```

Expected: prints an IP within a few minutes.

- [ ] **Step 5: Verify virtiofs came up**

This is the least-trodden path in the design; check it before anything is built on top.

```bash
ssh dev@<ip> 'mountpoint /data && ls -la /data/state/ && touch /data/state/.probe && rm /data/state/.probe && echo "writable"'
ssh dev@<ip> 'id'
```

Assert: `/data` is a mountpoint, the salvaged state is visible, `dev` is uid 1000 and can write. **If virtiofs failed, stop and report.** The fallback is a second LVM disk, which changes Tasks 5, 6, and 7.

- [ ] **Step 6: Verify the core chain ran**

```bash
ssh dev@<ip> 'cloud-init status --long; tail -40 /var/log/cloud-init-output.log'
```

- [ ] **Step 7: Commit**

```bash
git add devbox.sh
git commit -m "feat: devbox.sh create verb

--balloon 0 is required by PVE for virtiofs, not a preference. The dir
mapping line must be tab-indented or PVE's parser rejects it."
```

---

### Task 8: Smoke test harness and boot-level assertions

Builds the test runner now so Tasks 9 through 12 have a gate. Assertions for tools that do not exist yet are added by the task that installs them.

**Files:**
- Create: `scripts/smoke-test.sh`

**Interfaces:**
- Consumes: a booted box from Task 7.
- Produces: `check`, `remote`, and `remote_clean_stderr` helpers used by Tasks 9 through 13.

- [ ] **Step 1: Write the harness with the boot-level assertions**

```bash
#!/usr/bin/env bash
#
# Run from the Mac against a booted box:  ./scripts/smoke-test.sh <host>
#
# Every assertion here corresponds to a real incident recorded in
# HANDOFF-SIMPLIFICATION.md. Adding one is cheaper than rediscovering the bug.
#
set -uo pipefail   # NOT -e: a failing assertion must not abort the suite

HOST="${1:?usage: smoke-test.sh <user@host>}"
pass=0; fail=0

check() {  # check <description> <exit-code>
  if [[ "$2" -eq 0 ]]; then
    printf '  \033[1;32mok\033[0m   %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1))
  fi
}

# Non-interactive SSH. Deliberately does NOT allocate a tty and does NOT
# source ~/.zshrc, which is exactly how scripts, scp and Moshi probe the box.
remote() { ssh -o BatchMode=yes "$HOST" "$@"; }

# Asserts a login-shell probe exits 0 AND writes nothing to stderr. Bash
# syntax in /etc/profile.d made 'sh -lc' emit a wall of errors and exit 2,
# which silently broke Moshi's moshi-hook detection.
remote_clean_stderr() {  # remote_clean_stderr <shell>
  local err
  err="$(ssh -o BatchMode=yes "$HOST" "$1 -lc 'true'" 2>&1 >/dev/null)"
  [[ -z "$err" ]] || { printf '    stderr was: %s\n' "$err" >&2; return 1; }
}

printf '\n\033[1;34m== boot and base ==\033[0m\n'

remote 'cloud-init status' 2>/dev/null | grep -q 'status: done'
check "cloud-init reports done" $?

remote 'mountpoint -q /data'
check "/data is a mountpoint" $?

remote 'touch /data/state/.probe && rm /data/state/.probe'
check "/data is writable by the admin user" $?

remote 'test "$(id -u)" -eq 1000'
check "admin user is uid 1000" $?

remote 'test -s ~/.ssh/authorized_keys && test "$(stat -c %a ~/.ssh/authorized_keys)" = "600"'
check "authorized_keys is non-empty and mode 600" $?

remote '! test -L ~/.ssh'
check "~/.ssh is a real directory, not a symlink" $?

remote 'sudo -n true'
check "sudo is NOPASSWD" $?

remote 'grep -q avx2 /proc/cpuinfo'
check "guest CPU advertises avx2" $?

remote 'sudo ufw status | grep -q "^Status: active"'
check "ufw is active" $?

remote 'sudo ufw status | grep -q "60000:61000/udp"'
check "mosh UDP range is allowed" $?

printf '\n\033[1;34m== login shells ==\033[0m\n'

for sh in sh bash zsh; do
  remote "$sh -lc 'true'"
  check "$sh -lc exits 0" $?
  remote_clean_stderr "$sh"
  check "$sh -lc writes nothing to stderr" $?
done

remote 'for f in /etc/profile.d/*.sh; do dash -n "$f" || exit 1; done'
check "every /etc/profile.d file parses under dash" $?

printf '\n\033[1;34m== state persistence ==\033[0m\n'

for p in .claude .claude.json .config/gh .config/herdr .config/mise .gitconfig; do
  remote "test -L ~/$p && readlink -f ~/$p | grep -q '^/data/'"
  check "~/$p is a symlink into /data" $?
done

printf '\n\033[1;34m== %d passed, %d failed ==\033[0m\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
```

- [ ] **Step 2: Run it and record the baseline**

```bash
chmod +x scripts/smoke-test.sh
./scripts/smoke-test.sh dev@<ip>
```

Expected: the boot, login-shell, and state-persistence sections pass. `dash -n` may fail if Debian ships a profile.d file with bash syntax; if so, investigate whether it is ours or the distro's before "fixing" it.

- [ ] **Step 3: Commit**

```bash
git add scripts/smoke-test.sh
git commit -m "test: smoke-test harness with boot-level assertions

remote_clean_stderr asserts exit 0 AND empty stderr, because the login
shell bug that broke Moshi detection produced a non-empty stderr with a
zero exit under some shells."
```

---

### Task 9: Root-tree tools

Everything the provisioner updates. Apt where a repo exists, `/usr/local/bin` directly where it does not. No cross-tree symlinks.

**Files:**
- Modify: `bootstrap.sh`
- Modify: `scripts/smoke-test.sh`

**Interfaces:**
- Consumes: `log`, `warn`, `optional` from Task 6.
- Produces: `docker`, `tailscale`, `gh`, `claude`, `google-chrome`, `starship`, `herdr`, `moshi-hook` on the system `PATH`, all root-owned.

- [ ] **Step 1: Add the apt-repo tools to `bootstrap.sh`**

Insert after the firewall section:

```bash
##### 5. root-tree tools: apt repositories #####
#
# Rule 1, root half: tools the PROVISIONER updates live in apt or directly in
# /usr/local/bin, owned by root, exactly like distro packages. Nothing here
# is ever symlinked into a user tree. The previous setup installed several of
# these into /root/.local/bin (a mode-0700 home) and symlinked them into
# /usr/local/bin, so 'dev' could not traverse the path and the "global"
# binaries were invisible to the only user who ran them.

CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"

add_repo() {  # add_repo <name> <key-url> <repo-line>
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL "$2" -o "/etc/apt/keyrings/$1.asc"
  chmod a+r "/etc/apt/keyrings/$1.asc"
  echo "$3" >"/etc/apt/sources.list.d/$1.list"
}

if ! command -v docker >/dev/null 2>&1; then
  log "docker"
  add_repo docker https://download.docker.com/linux/debian/gpg \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${CODENAME} stable"
  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
fi
usermod -aG docker "$DEV_USER"
# Membership in the docker group is effectively root on this guest. Accepted:
# the VM itself is the security boundary. Switch to rootless if you disagree.

if ! command -v tailscale >/dev/null 2>&1; then
  log "tailscale"
  curl -fsSL "https://pkgs.tailscale.com/stable/debian/${CODENAME}.noarmor.gpg" \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL "https://pkgs.tailscale.com/stable/debian/${CODENAME}.tailscale-keyring.list" \
    -o /etc/apt/sources.list.d/tailscale.list
  apt-get update -qq
  apt-get install -y tailscale
  systemctl enable --now tailscaled
fi
# No 'tailscale up' here and no auth key anywhere. TS_STATE_DIR points at
# /data, so after the one manual 'sudo tailscale up' the identity survives
# every rebuild and the box keeps its MagicDNS name.

if ! command -v gh >/dev/null 2>&1; then
  log "gh"
  add_repo githubcli https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.asc] https://cli.github.com/packages stable main"
  apt-get update -qq
  apt-get install -y gh
fi

if ! command -v claude >/dev/null 2>&1; then
  log "claude code"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://downloads.claude.ai/keys/claude-code.asc \
    -o /etc/apt/keyrings/claude-code.asc

  # Never trust a downloaded key without verifying its fingerprint.
  EXPECTED="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
  FOUND="$(gpg --show-keys --with-colons /etc/apt/keyrings/claude-code.asc \
           | awk -F: '/^fpr:/ {print $10; exit}')"
  [[ "$FOUND" == "$EXPECTED" ]] || fail "claude-code key fingerprint mismatch: expected $EXPECTED, found ${FOUND:-<none>}"

  # The stable channel trails latest by about a week and skips releases with
  # known major regressions, which is what a box running long unattended
  # agent loops wants. The native installer busy-looped at 100% CPU with zero
  # network for 12+ minutes on this headless guest, twice; apt does not.
  echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main" \
    >/etc/apt/sources.list.d/claude-code.list
  apt-get update -qq
  apt-get install -y claude-code
fi

if ! command -v google-chrome >/dev/null 2>&1; then
  log "chrome"
  # The apt repo rather than the direct .deb the old provisioner fetched, so
  # Chrome upgrades ride normal 'apt upgrade' instead of going stale.
  if add_repo google-chrome https://dl.google.com/linux/linux_signing_key.pub \
       "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.asc] https://dl.google.com/linux/chrome/deb/ stable main" \
     && apt-get update -qq && apt-get install -y google-chrome-stable; then
    :
  else
    warn "chrome install failed; fallback is the direct .deb at https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
  fi
fi

# Headed Chrome inside a virtual framebuffer, for the things that refuse
# --headless=new.
cat >/usr/local/bin/google-chrome-under-xvfb <<'EOF'
#!/bin/sh
exec xvfb-run -a -s "-screen 0 1920x1080x24" google-chrome --no-sandbox "$@"
EOF
chmod 0755 /usr/local/bin/google-chrome-under-xvfb
```

- [ ] **Step 2: Add the direct-to-`/usr/local/bin` tools**

```bash
##### 6. root-tree tools: direct installers #####
#
# No distro package exists for these. Because bootstrap runs as root,
# /usr/local/bin is writable and no installer needs to escalate or prompt.
# Each workaround below names the upstream bug it exists for.

if ! command -v starship >/dev/null 2>&1; then
  log "starship"
  # --yes because the installer prompts interactively, and its stdin IS the
  # piped script, so a prompt breaks the pipe. -b to target /usr/local/bin
  # directly rather than installing to a home and copying afterward.
  optional "starship" sh -c \
    'curl -fsSL https://starship.rs/install.sh | sh -s -- --yes -b /usr/local/bin >/dev/null'
fi

if ! command -v herdr >/dev/null 2>&1; then
  log "herdr"
  # HOME is set under cloud-init runcmd but NOT on qemu-ga exec paths, and
  # herdr's installer dies on "HOME: parameter not set" without it.
  export HOME="${HOME:-/root}"
  # HERDR_INSTALL_DIR must ride the SH side of the pipe. An env prefix on the
  # curl side never reaches the installer.
  curl -fsSL https://herdr.dev/install.sh | HERDR_INSTALL_DIR=/usr/local/bin sh >/dev/null \
    || warn "herdr install failed"
  if ! command -v herdr >/dev/null 2>&1 && [[ -x /root/.local/bin/herdr ]]; then
    install -m 0755 /root/.local/bin/herdr /usr/local/bin/herdr
  fi
fi

if ! command -v moshi-hook >/dev/null 2>&1; then
  log "moshi-hook"
  # THE ONE DOCUMENTED CROSS-TREE EXCEPTION. The installer ignores INSTALL_DIR
  # when the variable prefixes the CURL side of the pipe and lands in
  # ~root/.local/bin regardless, so pass the env to the SH side and copy
  # afterward. Copies, not symlinks: /root is mode 0700 and dev cannot
  # traverse it, which is how "global" binaries became invisible before.
  # Non-fatal: cdn.getmoshi.app sits behind Cloudflare and curl gets 403'd on
  # some networks. Installs TWO binaries, moshi and moshi-hook.
  curl -fsSL https://getmoshi.app/install.sh \
    | MOSHI_HOOK_SKIP_FIRST_RUN=1 INSTALL_DIR=/usr/local/bin sh \
    || warn "moshi-hook install failed (Cloudflare 403?); rerun 'curl -fsSL https://getmoshi.app/install.sh | sh' later"
  for b in moshi moshi-hook; do
    if ! command -v "$b" >/dev/null 2>&1 && [[ -x "/root/.local/bin/$b" ]]; then
      install -m 0755 "/root/.local/bin/$b" "/usr/local/bin/$b"
    fi
  done
fi
```

- [ ] **Step 3: Add the assertions to `scripts/smoke-test.sh`**

Insert before the summary line:

```bash
printf '\n\033[1;34m== root-tree tools ==\033[0m\n'

for b in docker gh claude google-chrome starship herdr moshi moshi-hook tailscale mosh rg fd bat jq; do
  remote "command -v $b >/dev/null"
  check "$b is on the non-interactive PATH" $?
done

remote 'docker info >/dev/null 2>&1'
check "docker daemon is reachable by the admin user" $?

remote 'id -nG | tr " " "\n" | grep -qx docker'
check "admin user is in the docker group" $?

# Every root-tree binary must be readable by dev without traversing /root.
for b in starship herdr moshi moshi-hook; do
  remote "test -x \"\$(command -v $b)\" && ! readlink -f \"\$(command -v $b)\" | grep -q '^/root/'"
  check "$b does not resolve into /root" $?
done
```

That last check is the regression gate for the install-tree bug: binaries that resolved into root's mode-0700 home were invisible to the only user who ran them, and one daemon was caught executing a deleted inode.

- [ ] **Step 4: Deploy and run**

```bash
./scripts/lint.sh
scp bootstrap.sh dev@<ip>:/tmp/bootstrap.sh
ssh dev@<ip> 'sudo install -m755 /tmp/bootstrap.sh /usr/local/sbin/devbox-bootstrap && sudo devbox-bootstrap'
./scripts/smoke-test.sh dev@<ip>
```

Expected: the root-tree section passes. `google-chrome`, `herdr`, and `moshi-hook` are optional, so a `WARNING` in the bootstrap output plus a smoke-test FAIL means investigate, not abort.

- [ ] **Step 5: Commit and push**

```bash
git add bootstrap.sh scripts/smoke-test.sh
git commit -m "feat: root-tree tools with one documented cross-tree exception

Each workaround names the upstream bug it exists for. The smoke test
asserts no root-tree binary resolves into /root, which is the regression
gate for the install-tree class of bug."
git push origin main
```

---

### Task 10: mise user tree

The other half of Rule 1, and the task that retires the cross-tree symlink class of bug for the agent CLIs.

**Files:**
- Modify: `bootstrap.sh`
- Modify: `scripts/smoke-test.sh`

**Interfaces:**
- Consumes: `as_user`, `log`, `warn` from Task 6.
- Produces: `mise`, `node`, `npm`, `bun`, `python`, `uv`, `opencode`, `pi`, `codex` on the admin user's `PATH`.

- [ ] **Step 1: Add the mise section to `bootstrap.sh`**

```bash
##### 7. user tree: mise #####
#
# Rule 1, user half: tools that self-update in place are owned by the user
# who updates them. mise is the single mechanism for node, python and bun,
# and mise-managed npm globals carry opencode, pi and codex.
#
# Toolchains install under ~/.local/share/mise, on the VM DISK. Only
# ~/.config/mise (the manifest) persists on /data. Toolchains are large, hot,
# and reproducible from the manifest, so keeping them local avoids executing
# node off virtiofs on every invocation and keeps /data small.

MISE_TOOLS="${MISE_TOOLS:-node@lts python@3.13 bun@latest}"

log "mise"
# Multi-line as the dev user goes through STDIN. 'sudo -i' with multi-line
# arguments joins them on spaces and re-parses, destroying the quoting.
as_user <<'EOF'
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
if [[ ! -x "$HOME/.local/bin/mise" ]]; then
  curl -fsSL https://mise.run | sh
fi
EOF

log "mise toolchains: ${MISE_TOOLS}"
as_user <<EOF
set -euo pipefail
export PATH="\$HOME/.local/bin:\$PATH"
mise use -g ${MISE_TOOLS}
mise install
EOF

log "user-tree CLIs"
as_user <<'EOF'
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
eval "$(mise activate bash)"

npm i -g --no-fund --no-audit typescript tsx prettier eslint vitest || echo "WARNING: npm globals partially failed" >&2

# The 'opencode' meta-package misresolves its platform deps and demands a
# musl build on glibc (EBADPLATFORM), reproducibly, even with --force.
# Install the platform-scoped package directly. Platform-scoped npm packages
# do not create bin links, so link it by hand INSIDE the user tree. This is
# not a cross-tree hop: both ends are owned by the same user.
npm i -g --no-fund --no-audit opencode-linux-x64 || echo "WARNING: opencode failed" >&2
prefix="$(npm prefix -g)"
if [[ -f "$prefix/lib/node_modules/opencode-linux-x64/bin/opencode" ]]; then
  ln -sf "$prefix/lib/node_modules/opencode-linux-x64/bin/opencode" "$prefix/bin/opencode"
fi

npm i -g --no-fund --no-audit @openai/codex || echo "WARNING: codex failed" >&2

# pi's own docs specify --ignore-scripts: it needs no lifecycle scripts for a
# normal install, and bun/npm block them by default anyway.
npm i -g --no-fund --no-audit --ignore-scripts @earendil-works/pi-coding-agent \
  || echo "WARNING: pi failed" >&2

# pnpm as the documented fallback package manager. bun comes from mise.
npm i -g --no-fund --no-audit pnpm@latest || echo "WARNING: pnpm failed" >&2

# uv owns python packages. Debian 13 marks the system python
# externally-managed, so 'pip3 --user --break-system-packages' is retired.
mise exec python -- python -m pip install --quiet --upgrade uv || echo "WARNING: uv failed" >&2
EOF
```

- [ ] **Step 2: Add the assertions**

```bash
printf '\n\033[1;34m== user tree (mise) ==\033[0m\n'

for b in mise node npm bun pnpm python uv opencode codex pi tsx prettier eslint vitest; do
  remote "zsh -lc 'command -v $b' >/dev/null 2>&1"
  check "$b is on the admin user's login PATH" $?
done

# The whole point of the user tree: these are owned by the user who updates
# them, so no root-owned copy or symlink can go stale.
remote 'test -O "$(zsh -lc "command -v opencode" 2>/dev/null)"'
check "opencode is owned by the admin user" $?

remote 'zsh -lc "opencode --version" >/dev/null 2>&1'
check "opencode runs (needs avx2 from x86-64-v3)" $?
```

- [ ] **Step 3: Deploy and run**

```bash
./scripts/lint.sh
scp bootstrap.sh dev@<ip>:/tmp/bootstrap.sh
ssh dev@<ip> 'sudo install -m755 /tmp/bootstrap.sh /usr/local/sbin/devbox-bootstrap && sudo devbox-bootstrap'
./scripts/smoke-test.sh dev@<ip>
```

The `opencode --version` check is the one that catches a missing AVX2. If it segfaults, `--cpu x86-64-v3` did not reach the VM; check `qm config 104`.

- [ ] **Step 4: Commit and push**

```bash
git add bootstrap.sh scripts/smoke-test.sh
git commit -m "feat: mise owns the user toolchain tree

opencode, pi and codex move from /usr/local/bin into the mise-node user
tree, which retires the cross-tree symlink bug class rather than working
around it. Toolchains stay on the VM disk; only the manifest persists."
git push origin main
```

---

### Task 11: Shell configuration with the dash gate

**Files:**
- Modify: `bootstrap.sh`
- Modify: `scripts/smoke-test.sh`

**Interfaces:**
- Consumes: `as_user`, `link_state_file`, `fail` from Task 6.
- Produces: a managed `~/.zshrc` on `/data` with a version marker, and dash-clean `/etc/profile.d` files.

- [ ] **Step 1: Add the shell section with self-validation**

```bash
##### 8. shell configuration #####
#
# Rule 2: Debian sources /etc/profile.d for DASH login shells too. A
# bash-only construct there makes every 'sh -lc' probe emit errors and exit
# 2, which silently broke Moshi's moshi-hook detection and cost hours to
# find. This script validates its own output and aborts rather than shipping
# a file that only bash can read.

log "profile.d"

# POSIX only. No [[, no compgen, no arithmetic ternaries.
cat >/etc/profile.d/10-devbox-path.sh <<'EOF'
# POSIX sh. Must parse under dash; validated by devbox-bootstrap.
case ":${PATH}:" in
  *:"$HOME/.local/bin":*) ;;
  *) PATH="$HOME/.local/bin:$PATH" ;;
esac
export PATH
EOF

# zoxide's init output is shell-specific and evaluating it unconditionally
# broke dash login shells. Guard on the running shell.
cat >/etc/profile.d/20-devbox-zoxide.sh <<'EOF'
# POSIX sh. Must parse under dash; validated by devbox-bootstrap.
if [ -n "${BASH_VERSION:-}" ] && command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init bash)"
fi
EOF

for f in /etc/profile.d/*devbox*.sh; do
  dash -n "$f" || fail "generated profile.d file does not parse under dash: $f"
done

##### 9. ~/.zshrc #####
#
# Rule 3: the file is MANAGED and lives on /data. No sed-merging, no
# stripping of herdr's 'promptinit; prompt adam1' lines. herdr's precmd
# re-asserted its own prompt on every render and stomped starship regardless
# of load order, while one-shot 'zsh -ic' probes looked fine.
#
# Because ~/.zshrc persists on /data, herdr's first-run file creation happens
# exactly once, on the first boot of the first box, and never again. herdr is
# installed BEFORE this runs so the ordering within that single first run is
# deterministic.

ZSHRC_VERSION="1"
link_state_file zshrc .zshrc

if ! grep -q "^# devbox-managed zshrc v${ZSHRC_VERSION}\$" "${DATA}/state/zshrc" 2>/dev/null; then
  log "writing managed .zshrc (v${ZSHRC_VERSION})"
  cat >"${DATA}/state/zshrc" <<'ZRC'
# devbox-managed zshrc v1
# Regenerated by devbox-bootstrap when the version marker changes.
# Local additions go in ~/.zshrc.local, which is sourced at the end.

export PATH="$HOME/.local/bin:$PATH"
export EDITOR=vim

mkdir -p "$HOME/.zsh_history.d"
export HISTFILE="$HOME/.zsh_history.d/history"
HISTSIZE=100000
SAVEHIST=100000
setopt SHARE_HISTORY HIST_IGNORE_DUPS HIST_REDUCE_BLANKS EXTENDED_HISTORY AUTO_CD

autoload -Uz compinit && compinit -d "$HOME/.cache/zcompdump"

source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh 2>/dev/null
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh 2>/dev/null

command -v mise    >/dev/null && eval "$(mise activate zsh)"
command -v zoxide  >/dev/null && eval "$(zoxide init zsh)"

# starship is the SOLE prompt owner. Do not add promptinit or 'prompt <name>'
# here; herdr's template registers 'prompt adam1', whose precmd re-asserts
# itself on every render and stomps starship regardless of load order.
command -v starship >/dev/null && eval "$(starship init zsh)"

alias ll='ls -lah'
alias dc='docker compose'
alias work='tmux new -A -s work -c ~/work'
reload() { exec zsh; }

[ -f "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"
ZRC
  chown 1000:1000 "${DATA}/state/zshrc"
fi

mkdir -p "${DEV_HOME}/.cache"
chown -R 1000:1000 "${DEV_HOME}/.cache"
```

- [ ] **Step 2: Add the assertions**

```bash
printf '\n\033[1;34m== shell configuration ==\033[0m\n'

remote 'grep -q "^# devbox-managed zshrc" ~/.zshrc'
check "~/.zshrc carries the managed marker" $?

remote '! grep -qE "promptinit|prompt adam1" ~/.zshrc'
check "~/.zshrc registers no competing prompt" $?

remote 'zsh -ic "echo \$PROMPT" 2>/dev/null | grep -qv adam'
check "starship is the active prompt" $?

remote 'test -L ~/.zshrc && readlink -f ~/.zshrc | grep -q "^/data/"'
check "~/.zshrc persists on /data" $?
```

- [ ] **Step 3: Deploy, run, and verify the dash gate actually fires**

```bash
./scripts/lint.sh
scp bootstrap.sh dev@<ip>:/tmp/bootstrap.sh
ssh dev@<ip> 'sudo install -m755 /tmp/bootstrap.sh /usr/local/sbin/devbox-bootstrap && sudo devbox-bootstrap'
./scripts/smoke-test.sh dev@<ip>
```

Then prove the gate is not decorative. Temporarily add `[[ -n "$FOO" ]] && true` to the `10-devbox-path.sh` heredoc, re-run bootstrap, and confirm it **aborts** with the dash-parse error. Revert the change afterward and re-run.

- [ ] **Step 4: Commit and push**

```bash
git add bootstrap.sh scripts/smoke-test.sh
git commit -m "feat: managed .zshrc on /data and a dash-parse gate

The gate aborts bootstrap rather than shipping a profile.d file only bash
can read. ~/.zshrc persisting on /data means herdr's first-run file
creation happens once ever, so there is nothing left to sed-merge."
git push origin main
```

---

### Task 12: systemd user units

**Files:**
- Modify: `bootstrap.sh`
- Modify: `scripts/smoke-test.sh`

**Interfaces:**
- Consumes: `as_user`, `log`, `optional` from Task 6; `herdr` and `moshi-hook` from Task 9.
- Produces: `moshi-hook.service` and `herdr-session.service` running under the admin user with linger enabled.

- [ ] **Step 1: Add the units**

```bash
##### 10. systemd user units #####
#
# Linger keeps these running when no session is attached, which is what makes
# the box reachable from Moshi's session picker without an SSH login first.

log "systemd user units"
loginctl enable-linger "$DEV_USER"

install -d -o 1000 -g 1000 -m 0755 "${DEV_HOME}/.config/systemd/user"

# The subcommand is 'serve'. ExecStart points at /usr/local/bin because
# moshi-hook is a root-tree tool now, not the old %h/.local/bin path.
cat >"${DEV_HOME}/.config/systemd/user/moshi-hook.service" <<'EOF'
[Unit]
Description=Moshi hook daemon (agent hooks + Moshi bridge)
After=network-online.target

[Service]
ExecStart=/usr/local/bin/moshi-hook serve
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

# Pre-starts the default herdr session so Moshi's picker shows a workspace on
# first connect; it lists only RUNNING sessions, so a fresh box would
# otherwise show nothing until someone ran 'herdr' by hand.
#
# script(1) is not decoration: herdr's TUI needs a tty even when the client
# just daemonizes the session. Type=simple because the script/herdr-client
# process stays attached to the session (unlike tmux's detach-and-exit), so
# forking detection would time out. The unit IS the session holder.
#
# Do NOT use 'herdr server stop' to walk away; that kills every pane.
cat >"${DEV_HOME}/.config/systemd/user/herdr-session.service" <<'EOF'
[Unit]
Description=herdr default session (pre-started for Moshi)

[Service]
Type=simple
ExecStart=/usr/bin/script -qec /usr/local/bin/herdr /dev/null
Restart=on-failure
RestartSec=10
StandardOutput=null
StandardError=null

[Install]
WantedBy=default.target
EOF

chown -R 1000:1000 "${DEV_HOME}/.config/systemd"

# ~/projects is the herdr workspace home, so the picker shows "projects"
# rather than a bare "~" home-dir workspace.
as_user <<'EOF'
set -euo pipefail
mkdir -p "$HOME/projects"
systemctl --user daemon-reload
systemctl --user enable --now moshi-hook.service   || echo "WARNING: moshi-hook unit failed" >&2
systemctl --user enable --now herdr-session.service || echo "WARNING: herdr-session unit failed" >&2
EOF

# Pre-install the Claude agent hooks so blocked agents can push to the phone
# as soon as pairing happens. claude must already be installed (task 9).
optional "moshi-hook claude hooks" \
  sudo -iu "$DEV_USER" moshi-hook install --target claude
```

- [ ] **Step 2: Add the assertions**

```bash
printf '\n\033[1;34m== systemd user units ==\033[0m\n'

remote 'loginctl show-user "$(id -un)" -p Linger | grep -q "Linger=yes"'
check "linger is enabled" $?

for u in moshi-hook herdr-session; do
  remote "systemctl --user is-active $u.service >/dev/null"
  check "$u.service is active" $?
done

remote 'herdr session list 2>/dev/null | grep -q .'
check "herdr reports at least one session" $?

# moshi-hook state lives in ~/.config/moshi, NOT in ~/.moshi*. A previous
# check probed the wrong path and reported unpaired forever.
remote 'test -d ~/.config/moshi'
check "moshi state directory exists at ~/.config/moshi" $?
```

- [ ] **Step 3: Deploy and run**

```bash
./scripts/lint.sh
scp bootstrap.sh dev@<ip>:/tmp/bootstrap.sh
ssh dev@<ip> 'sudo install -m755 /tmp/bootstrap.sh /usr/local/sbin/devbox-bootstrap && sudo devbox-bootstrap'
./scripts/smoke-test.sh dev@<ip>
```

The `script -qec` wrapper is load-bearing, not decoration: herdr's TUI needs a tty even when the client only daemonizes the session. If `herdr-session.service` flaps, check `journalctl --user -u herdr-session` on the box before changing the `ExecStart`, and do not replace `script` with a bare `herdr` invocation.

- [ ] **Step 4: Commit and push**

```bash
git add bootstrap.sh scripts/smoke-test.sh
git commit -m "feat: systemd user units for moshi-hook and herdr

Linger keeps them running with no session attached, which is what makes
the box appear in Moshi's picker without an SSH login first. State checks
probe ~/.config/moshi, the actual location."
git push origin main
```

---

### Task 13: `devbox.sh rebuild` with the clean-tree gate

`~/work` is on the VM disk and does not survive. The gate is what makes that safe rather than a footgun.

**Files:**
- Modify: `devbox.sh`

**Interfaces:**
- Consumes: `cmd_create`, `log`, `fail`, `run` from Tasks 3 and 7.
- Produces: `cmd_rebuild()`.

- [ ] **Step 1: Add the gate and the rebuild verb**

```bash
##### rebuild #####

# ~/work lives on the VM disk, not on /data, so a rebuild destroys it. Refuse
# unless every repo is clean AND pushed. This gate is the reason the
# state-only persistence split is safe.
assert_work_tree_clean() {
  local ip="$1"
  log "checking ~/work for unsaved state"

  local dirty
  dirty="$(ssh -o BatchMode=yes "${ADMIN_USER}@${ip}" 'bash -s' <<'EOF'
set -uo pipefail
shopt -s nullglob
for d in "$HOME"/work/*/; do
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
  elif [[ -n "$(ls -A "$d" 2>/dev/null)" ]]; then
    echo "non-git directory with contents: $name"
  fi
done
EOF
)"

  [[ -z "$dirty" ]] && { log "~/work is clean"; return 0; }

  printf '\n\033[1;31mrefusing to rebuild:\033[0m ~/work has unsaved state\n' >&2
  printf '%s\n' "$dirty" >&2
  printf '\nCommit and push, or pass --force to discard it.\n' >&2
  exit 1
}

snapshot_work() {
  local ip="$1"
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  log "snapshotting ~/work to ${DATA_HOST_DIR}/work-snapshots/${stamp}.tar.zst"

  # Belt and braces behind the gate, not the primary mechanism. Excludes the
  # regenerable directories so the tarball stays small.
  ssh -o BatchMode=yes "${ADMIN_USER}@${ip}" \
    "tar -C \"\$HOME\" --exclude=node_modules --exclude=.venv --exclude=target --exclude=dist -cf - work 2>/dev/null | zstd -q -T0" \
    > "${DATA_HOST_DIR}/work-snapshots/${stamp}.tar.zst" \
    || warn "work snapshot failed; continuing because the clean-tree gate already passed"

  # Keep the last three.
  local old
  mapfile -t old < <(ls -1t "${DATA_HOST_DIR}/work-snapshots"/*.tar.zst 2>/dev/null | tail -n +4)
  for old_file in "${old[@]:-}"; do
    [[ -n "$old_file" ]] && rm -f "$old_file"
  done
}

cmd_rebuild() {
  local force="${1:-}"

  qm status "$VMID" >/dev/null 2>&1 || fail "VMID $VMID does not exist; use 'create'"

  local ip
  ip="$(guest_ip "$VMID")"

  if [[ "$force" != "--force" ]]; then
    [[ -n "$ip" ]] || fail "cannot reach the guest to check ~/work; pass --force to rebuild anyway"
    assert_work_tree_clean "$ip"
    snapshot_work "$ip"
  fi

  log "rebuilding ${VMID}. ${DATA_HOST_DIR} on the host is NOT touched."
  read -rp "type the VM name to confirm (${VMNAME}): " confirm
  [[ "$confirm" == "$VMNAME" ]] || fail "aborted"

  run qm stop "$VMID" --timeout 60 || true
  # --destroy-unreferenced-disks 0 so nothing outside this VM's config is
  # touched. $DATA_HOST_DIR is a host directory and is never referenced by
  # the VM config at all, so no destroy path can reach it.
  run qm destroy "$VMID" --destroy-unreferenced-disks 0 --purge 1

  cmd_create
}
```

Add `rebuild) shift; cmd_rebuild "$@" ;;` to the `case`.

- [ ] **Step 2: Lint and test the gate**

```bash
./scripts/lint.sh
rsync -av --delete --exclude .git --exclude .pi ./ root@charon:/root/agent-box/
```

Prove the gate fires before trusting it. On the box:

```bash
ssh dev@<ip> 'mkdir -p ~/work/scratch && echo dirty > ~/work/scratch/file'
ssh root@charon 'cd /root/agent-box && ./devbox.sh rebuild'
```

Expected: refuses with `non-git directory with contents: scratch` and exits non-zero **before** prompting for confirmation. Then clean up and confirm it passes:

```bash
ssh dev@<ip> 'rm -rf ~/work/scratch'
ssh root@charon 'cd /root/agent-box && DRYRUN=1 ./devbox.sh rebuild'
```

- [ ] **Step 3: Commit**

```bash
git add devbox.sh
git commit -m "feat: devbox.sh rebuild with a clean-tree gate

~/work is on the VM disk and does not survive a rebuild, so rebuild
refuses unless every repo is committed and pushed. The tarball snapshot
is belt and braces behind that gate, not the primary mechanism."
```

---

### Task 14: Idempotency gate and the rebuild proof

The persistence claim is the entire point of the design. Prove it before relying on it.

**Files:**
- Modify: `scripts/smoke-test.sh`

**Interfaces:**
- Consumes: everything above.
- Produces: a green full suite across a real rebuild.

- [ ] **Step 1: Add the idempotency assertion**

Append before the summary. It runs last because it is slow.

```bash
if [[ "${SKIP_SLOW:-0}" != "1" ]]; then
  printf '\n\033[1;34m== idempotency ==\033[0m\n'
  # A qemu-ga restart once orphaned half a run and a second instance raced
  # dpkg locks, killing both. Re-running end to end must be a no-op.
  remote 'sudo /usr/local/sbin/devbox-bootstrap >/tmp/rerun.log 2>&1'
  check "devbox-bootstrap re-runs clean end to end" $?

  remote '! grep -qi "^ERROR" /tmp/rerun.log'
  check "the re-run logged no errors" $?
fi
```

- [ ] **Step 2: Run the full suite**

```bash
./scripts/smoke-test.sh dev@<ip>
```

Expected: everything green. Fix anything that is not before continuing; a red suite here is a red suite that will be blamed on the rebuild in the next step.

- [ ] **Step 3: Authenticate and confirm the salvaged state landed**

```bash
ssh dev@<ip> 'sudo tailscale up'
ssh dev@<ip> 'gh auth status'
ssh dev@<ip> 'claude --version && ls -la ~/.claude/'
```

`gh auth status` should report authenticated **without a login**, from the state salvaged in Task 3. That is the first real proof the model works.

- [ ] **Step 4: Rebuild and re-run**

```bash
ssh root@charon 'cd /root/agent-box && ./devbox.sh rebuild'
# wait for provisioning, then:
./scripts/smoke-test.sh dev@<new-ip>
ssh dev@<new-ip> 'gh auth status && tailscale status'
```

Expected: the suite is green again, `gh` is still authenticated with no login, and Tailscale reports the **same** MagicDNS hostname rather than `devbox-1`. If the hostname incremented, `TS_STATE_DIR` did not take effect; check the drop-in landed and `/data/state/tailscale` is populated.

- [ ] **Step 5: Commit**

```bash
git add scripts/smoke-test.sh
git commit -m "test: idempotency gate

Re-running devbox-bootstrap end to end must be a no-op. Set SKIP_SLOW=1
to skip it during fast iteration."
```

---

### Task 15: Documentation and removal of the superseded implementation

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md` (and the `CLAUDE.md` symlink or copy, if they differ)
- Delete: `scripts/build-template.sh`, `scripts/create-vm.sh`, `scripts/delete-vm.sh`, `cloud-init/provision.sh`

**Interfaces:**
- Consumes: the finished system.
- Produces: docs that match reality.

- [ ] **Step 1: Delete the superseded files**

```bash
git rm scripts/build-template.sh scripts/create-vm.sh scripts/delete-vm.sh cloud-init/provision.sh
```

Keep `HANDOFF-SIMPLIFICATION.md`. It is the record that justifies the rules in `bootstrap.sh`, and every comment there referencing an incident points back to it.

- [ ] **Step 2: Rewrite `README.md`**

It currently documents the disposable-fleet model, which no longer exists. Replace:

- The opening claim "Disposable Proxmox dev boxes, one command each" with the persistent-box model.
- The lifecycle section: `preflight` → `template` → `create` → `rebuild`, and what `rebuild` does and does not preserve. State it plainly: `/data` survives, `~/work` does not, and the clean-tree gate is why that is safe.
- The what-is-installed table: replace the Node/npm-globals row with mise, drop the login-banner and apt-status-timer bullets from "already running for you".
- The one-time setup list: only `sudo tailscale up`, `gh auth login`, `claude login`, and `moshi-hook pair` remain, and note that after the first time they persist across rebuilds.
- The config reference table: the new knob names from Task 1.
- The files table: the layout from this plan's File Structure section.

- [ ] **Step 3: Rewrite the `AGENTS.md` walkthrough**

The "Helping a user initialize a new VM" checklist assumes many boxes and a `create-vm.sh` with flags. Rewrite for one box, and add the two facts an agent working here most needs:

- `bootstrap.sh` is iterated by scp-and-run, never by rebuilding the VM.
- The four rules in `bootstrap.sh` are load-bearing and each names a real incident. Do not "simplify" a rule away without reading `HANDOFF-SIMPLIFICATION.md` first.

Keep the existing repo-conventions section; it is still accurate.

- [ ] **Step 4: Verify the docs against reality**

Run every command the README claims works, on the real box. Docs that drift are worse than no docs.

```bash
./scripts/lint.sh
./tests/test-render.sh
./scripts/smoke-test.sh dev@<ip>
```

- [ ] **Step 5: Commit and push**

```bash
git add -A
git commit -m "docs: rewrite for the persistent-box model; drop superseded scripts

build-template.sh, create-vm.sh, delete-vm.sh and provision.sh are
replaced by devbox.sh and bootstrap.sh. HANDOFF-SIMPLIFICATION.md is
kept as the record justifying the rules in bootstrap.sh."
git push origin main
```

- [ ] **Step 6: Pin the bootstrap URL**

Now that the box is proven, set `BOOTSTRAP_URL` in `config.sh` to a tag or commit SHA rather than `main`, so an in-flight push cannot change what a rebuild installs:

```bash
git tag -a devbox-v1 -m "first proven devbox build" && git push origin devbox-v1
# then in config.sh:
# BOOTSTRAP_URL="https://raw.githubusercontent.com/narrowstacks/pxe-agent-box/devbox-v1/bootstrap.sh"
```

Re-run `./devbox.sh rebuild` once more to confirm the pinned URL resolves.
