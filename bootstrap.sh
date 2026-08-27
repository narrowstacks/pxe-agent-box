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
