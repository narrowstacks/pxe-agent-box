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
# /data ownership below is chowned to a hardcoded 1000:1000 in ~14 places.
# If the uid-1000 pin in cloud-init ever fails, this guard is what stops
# bootstrap from silently chowning /data/state to the wrong user.
[[ "$(id -u "$DEV_USER")" == "1000" ]] \
  || fail "$DEV_USER is uid $(id -u "$DEV_USER"), not 1000; /data ownership throughout this script assumes uid 1000, refusing to run against a wrong-uid user"
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

# Same as link_state_file, but never fabricates a placeholder: if the file
# has never existed on either side, it is skipped entirely rather than
# creating an empty stand-in. Used for a file whose mere existence has
# meaning (an ssh client key an empty file would still get loaded, and then
# rejected, not just be inert).
link_state_file_optional() {
  local src="${DATA}/state/$1" dst="${DEV_HOME}/$2"
  [[ -e "$dst" || -e "$src" ]] || return 0
  mkdir -p "$(dirname "$src")" "$(dirname "$dst")"
  if [[ -f "$dst" && ! -L "$dst" ]]; then
    [[ -e "$src" ]] || cp -a "$dst" "$src" \
      || fail "could not copy ${dst} to ${src}; refusing to delete the original"
    rm -f "$dst"
  fi
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
# Spec 3.3: a stable outbound git identity across rebuilds. Not generated
# here, only persisted if the operator has dropped one in; a missing key
# stays missing rather than getting fabricated.
link_state_file_optional ssh/id_ed25519      .ssh/id_ed25519
link_state_file_optional ssh/id_ed25519.pub  .ssh/id_ed25519.pub
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
fi

# tailscaled's own ExecStart hardcodes --state=/var/lib/tailscale/tailscaled.state,
# which wins over any TS_STATE_DIR env var: that variable is read by
# upstream's CONTAINERBOOT wrapper, not by tailscaled itself. An env
# drop-in was tried first and confirmed on a live box to be a no-op.
#
# Symlinking /var/lib/tailscale itself (link_state's usual discipline) was
# tried second and FAILS HARD on this box: the unit also declares
# StateDirectory=tailscale, and systemd's own exec-time setup for that
# directive does its own directory chase over the symlink and virtiofs,
# erroring "Too many levels of symbolic links" (systemd exit
# 238/STATE_DIRECTORY) and never starting tailscaled at all. Confirmed by
# restarting tailscaled after installing the symlink; reverted.
#
# Overriding ExecStart to point --state directly at /data sidesteps
# StateDirectory entirely, since that directive only governs
# /var/lib/tailscale, which this no longer touches. It duplicates
# upstream's command line (PORT and FLAGS still come from the unit's own
# EnvironmentFile=/etc/default/tailscaled, untouched by this drop-in), so if
# a future tailscale package changes its ExecStart, this needs updating too.
TAILSCALE_DROPIN=/etc/systemd/system/tailscaled.service.d/state-on-data.conf
if ! grep -q '^ExecStart=/usr/sbin/tailscaled --state=/data/state/tailscale/tailscaled.state' "$TAILSCALE_DROPIN" 2>/dev/null; then
  log "persisting tailscale state on /data"
  systemctl stop tailscaled 2>/dev/null || true
  mkdir -p "${DATA}/state/tailscale"
  # Same discipline as link_state: copy any existing identity in, and never
  # delete the original unless the copy succeeded. Leaving the orphaned
  # on-disk copy behind is harmless once ExecStart stops pointing at it.
  if [[ -f /var/lib/tailscale/tailscaled.state && ! -e "${DATA}/state/tailscale/tailscaled.state" ]]; then
    cp -a /var/lib/tailscale/tailscaled.state "${DATA}/state/tailscale/tailscaled.state" \
      || fail "could not copy /var/lib/tailscale/tailscaled.state into ${DATA}/state/tailscale; refusing to leave tailscale state stranded"
  fi
  install -d -m 0755 /etc/systemd/system/tailscaled.service.d
  cat >"$TAILSCALE_DROPIN" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/tailscaled --state=/data/state/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock --port=${PORT} $FLAGS
EOF
  systemctl daemon-reload
fi
chown -R root:root "${DATA}/state/tailscale"
chmod 700 "${DATA}/state/tailscale"

# A drop-in from the earlier, broken design (TS_STATE_DIR, which tailscaled
# never reads) is harmless but wrong; remove it so nothing on the box still
# documents a mechanism that does not work.
if [[ -f /etc/systemd/system/tailscaled.service.d/override.conf ]]; then
  rm -f /etc/systemd/system/tailscaled.service.d/override.conf
  systemctl daemon-reload
fi

systemctl enable --now tailscaled
# No 'tailscale up' here and no auth key anywhere. The node identity, once
# set by the one manual 'sudo tailscale up', now lives under /data via the
# ExecStart override above and survives every rebuild along with the
# MagicDNS name.

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
  # curl side never reaches the installer. Confirmed working directly into
  # /usr/local/bin, so there is no cross-tree fallback copy here: unlike
  # moshi-hook below, herdr's own install-dir override actually works.
  curl -fsSL https://herdr.dev/install.sh | HERDR_INSTALL_DIR=/usr/local/bin sh >/dev/null \
    || warn "herdr install failed"
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

# mise generates shims when IT installs a tool. Anything added afterwards
# (npm globals, and uv via pip into mise's python) has no shim until we
# ask for one, and shims are the only thing a non-interactive login shell
# sees. Without this, a tool is installed and still "not found".
mise reshim || echo "WARNING: mise reshim failed" >&2
EOF

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

# mise shims, not "mise activate": activate is an interactive-shell
# mechanism, while scripts, scp and remote-exec run non-interactively and
# would otherwise see a short PATH with none of the user-tree tools on it.
# Incident: agents, bash -lc, and sh -lc all invoke tools non-interactively
# and every one of them needs this, not just zsh.
cat >/etc/profile.d/15-devbox-mise-shims.sh <<'EOF'
# POSIX sh. Must parse under dash; validated by devbox-bootstrap.
# mise shims, not "mise activate": activate is an interactive-shell
# mechanism, while scripts, scp and remote-exec run non-interactively and
# would otherwise see a short PATH with none of the user-tree tools on it.
if [ -d "$HOME/.local/share/mise/shims" ]; then
  case ":${PATH}:" in
    *:"$HOME/.local/share/mise/shims":*) ;;
    *) PATH="$HOME/.local/share/mise/shims:$PATH" ;;
  esac
  export PATH
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

ZSHRC_VERSION="2"
link_state_file zshrc .zshrc

if ! grep -q "^# devbox-managed zshrc v${ZSHRC_VERSION}\$" "${DATA}/state/zshrc" 2>/dev/null; then
  log "writing managed .zshrc (v${ZSHRC_VERSION})"
  cat >"${DATA}/state/zshrc" <<'ZRC'
# devbox-managed zshrc v2
# Regenerated by devbox-bootstrap when the version marker changes.
# Local additions go in ~/.zshrc.local, which is sourced at the end.
#
# No 'export PATH="$HOME/.local/bin:$PATH"' here: ~/.zshenv already adds it,
# guarded, and runs before ~/.zshrc on every zsh invocation without
# exception. Adding it again here duplicated the entry on every interactive
# shell start. One owner per PATH entry.

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

# starship is the SOLE prompt owner. Do not enable the zsh prompt subsystem
# or select herdr's own adam1 theme here: its precmd re-asserts itself on
# every render and stomps starship regardless of load order.
command -v starship >/dev/null && eval "$(starship init zsh)"

alias ll='ls -lah'
alias dc='docker compose'
alias work='tmux new -A -s work -c ~/work'
reload() { exec zsh; }

[ -f "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"
ZRC
  chown 1000:1000 "${DATA}/state/zshrc"
fi

# Issue #2 in the incident ledger: non-interactive shells have a short
# PATH. Scripts, scp and remote commands never source ~/.zshrc, so
# user-local bins are invisible to them. /etc/profile.d/15-devbox-mise-shims
# above covers every LOGIN shell (dash, bash, zsh). It cannot cover plain
# 'ssh host cmd', which is non-interactive AND non-login: no profile.d file
# runs for it. zsh sources ~/.zshenv for that case, and only zsh, so this
# is the zsh-specific top-up, not a duplicate of the profile.d file.
ZSHENV_VERSION="1"
link_state_file zshenv .zshenv

if ! grep -q "^# devbox-managed zshenv v${ZSHENV_VERSION}\$" "${DATA}/state/zshenv" 2>/dev/null; then
  log "writing managed .zshenv (v${ZSHENV_VERSION})"
  cat >"${DATA}/state/zshenv" <<'ZENV'
# devbox-managed zshenv v1
# Regenerated by devbox-bootstrap when the version marker changes.
#
# zsh sources ~/.zshenv for EVERY invocation, including plain
# 'ssh host cmd' (non-interactive, non-login), which is the one shell
# entry point /etc/profile.d cannot reach. mise shims, not 'mise activate':
# activate is interactive-only, this path must work with no shell running.
#
# zsh never sources /etc/profile.d on Debian; that is a bash/dash-only
# mechanism wired through /etc/profile, and zsh's own /etc/zsh/zprofile does
# not call it. So both prepends /etc/profile.d applies for other shells have
# to be repeated here for zsh: ~/.local/bin (where the mise binary itself
# lives) and the shims dir (where mise-managed tools live).
case ":${PATH}:" in
  *:"$HOME/.local/bin":*) ;;
  *) PATH="$HOME/.local/bin:$PATH" ;;
esac
case ":${PATH}:" in
  *:"$HOME/.local/share/mise/shims":*) ;;
  *) PATH="$HOME/.local/share/mise/shims:$PATH" ;;
esac
export PATH
ZENV
  chown 1000:1000 "${DATA}/state/zshenv"
fi

mkdir -p "${DEV_HOME}/.cache"
chown -R 1000:1000 "${DEV_HOME}/.cache"

##### 10. systemd user units #####
#
# Linger keeps these running when no session is attached, which is what makes
# the box reachable from Moshi's session picker without an SSH login first.

log "systemd user units"
loginctl enable-linger "$DEV_USER"

# 'sudo -iu' does not run a real PAM login session, so it never inherits
# XDG_RUNTIME_DIR or DBUS_SESSION_BUS_ADDRESS from logind; systemctl --user
# below would otherwise fail with "Failed to connect to user scope bus".
# Linger already keeps this user manager running, so just make sure it is
# up before talking to it instead of waiting on a session that never comes.
systemctl start "user@$(id -u "$DEV_USER").service"

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

# Moshi's picker shows the herdr workspace label as "~", not a project name.
# herdr derives the label from the session's working directory, and this
# unit has none set, so it defaults to $HOME. A prior attempt at
# WorkingDirectory=%h/projects on herdr-session.service moved the process
# cwd but did NOT change the picker label; do not re-try that fix here. The
# mkdir below is not load-bearing for the label. A real fix would go through
# 'herdr workspace rename <id> <label>' after the session starts (see
# 'herdr workspace rename --help'); left as a follow-up, not implemented.
as_user <<'EOF'
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
mkdir -p "$HOME/projects"
systemctl --user daemon-reload
systemctl --user enable --now moshi-hook.service   || echo "WARNING: moshi-hook unit failed" >&2
systemctl --user enable --now herdr-session.service || echo "WARNING: herdr-session unit failed" >&2
EOF

# Pre-install the Claude agent hooks so blocked agents can push to the phone
# as soon as pairing happens. claude must already be installed (task 9).
# Same bus env as above: without it, moshi-hook can't see its own already-
# running daemon and prints a misleading "daemon isn't running" warning.
optional "moshi-hook claude hooks" \
  sudo -iu "$DEV_USER" env \
    "XDG_RUNTIME_DIR=/run/user/$(id -u "$DEV_USER")" \
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$DEV_USER")/bus" \
    moshi-hook install --target claude
