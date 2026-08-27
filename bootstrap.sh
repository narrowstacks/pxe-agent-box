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
# Sourced BEFORE the defaults below so the defaults act as fallbacks. This
# file is the only channel carrying host config into the guest, because
# bootstrap.sh is curl'd standalone and cannot otherwise learn any value.
# shellcheck source=/dev/null
if [[ -r /etc/devbox.env ]]; then
  source /etc/devbox.env
fi

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
# EXTRA_APT_PACKAGES is a host-supplied space-separated list; word splitting
# is intended so each package becomes its own apt-get argument.
# shellcheck disable=SC2086
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
  ${EXTRA_APT_PACKAGES:-}

# Debian ships these under alternate binary names.
fdfind_path="$(command -v fdfind)" || fail "fdfind missing after apt install; base packages did not land"
ln -sf "$fdfind_path" /usr/local/bin/fd
batcat_path="$(command -v batcat)" || fail "batcat missing after apt install; base packages did not land"
ln -sf "$batcat_path" /usr/local/bin/bat

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
  systemctl enable tmp.mount 2>/dev/null \
    || warn "tmpfs /tmp not enabled; build scratch will land on the VM disk"
fi

# OOM cushion. Parallel test workers spike hard.
if [[ ! -f /swapfile ]]; then
  fallocate -l "${SWAP_SIZE_GB}G" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
fi
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
# Existence is not activation: the file can survive a rebuild without being
# swapped on, and vice versa. Check the actual end state, not just -f.
if ! swapon --show=NAME --noheadings 2>/dev/null | grep -qx '/swapfile'; then
  swapon /swapfile || warn "could not enable /swapfile"
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
      # Do NOT discard cp's status. /data is virtiofs, where xattr and
      # special-file copies can fail, and the rm below is the only copy's
      # last moment. Aborting loudly beats deleting state silently.
      cp -a "$dst/." "$src/" \
        || fail "could not copy ${dst} into ${src}; refusing to delete the original"
    else
      # If src already exists, salvaged state on /data wins over a freshly
      # created destination, so the copy is skipped rather than overwriting
      # it. Otherwise copy, and abort rather than delete dst on failure.
      [[ -e "$src" ]] || cp -a "$dst" "$src" \
        || fail "could not copy ${dst} to ${src}; refusing to delete the original"
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
    # Same precedence as link_state: skip the copy if src already has
    # salvaged state, otherwise copy and abort rather than delete dst on
    # failure.
    [[ -e "$src" ]] || cp -a "$dst" "$src" \
      || fail "could not copy ${dst} to ${src}; refusing to delete the original"
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
chown 1000:1000 "${DEV_HOME}/.ssh"
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
