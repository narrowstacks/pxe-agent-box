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

# Host config values, written by cloud-init. Sourced before the defaults
# below so those act as fallbacks. This is the only channel carrying host
# config into the guest; bootstrap.sh is curl'd standalone.
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

# Runs a script as the dev user. On stdin, never as arguments: 'sudo -i'
# joins its arguments with spaces and re-parses them, destroying quoting.
as_user() { sudo -iu "$DEV_USER" bash -s; }

# Optional step: warn and continue. The core chain does not use this; a
# base-package or Docker failure must abort loudly.
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

# Single-instance guard. flock, not pgrep -f, which matches its own command
# line and always finds itself.
exec 9>/var/lock/devbox-bootstrap.lock
flock -n 9 || fail "another devbox-bootstrap is already running"

id "$DEV_USER" >/dev/null 2>&1 || fail "user $DEV_USER does not exist"
# Everything below chowns /data to a hardcoded 1000:1000. This guard is what
# stops a failed cloud-init uid pin from chowning it to the wrong user.
[[ "$(id -u "$DEV_USER")" == "1000" ]] \
  || fail "$DEV_USER is uid $(id -u "$DEV_USER"), not 1000; /data ownership throughout this script assumes uid 1000, refusing to run against a wrong-uid user"
mountpoint -q "$DATA" || fail "$DATA is not a mountpoint; virtiofs did not come up"

export DEBIAN_FRONTEND=noninteractive

##### 1. base packages #####

log "base packages"
apt-get update -qq
# EXTRA_APT_PACKAGES is a host-supplied list; word splitting is intended.
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

# File watchers exhaust the default inotify budget fast and fail with a
# confusing ENOSPC.
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

# tmpfs /tmp keeps build scratch off the VM disk.
if ! systemctl is-enabled tmp.mount >/dev/null 2>&1; then
  cp /usr/share/systemd/tmp.mount /etc/systemd/system/tmp.mount 2>/dev/null || true
  systemctl enable tmp.mount 2>/dev/null \
    || warn "tmpfs /tmp not enabled; build scratch will land on the VM disk"
fi

# OOM cushion for parallel test workers.
if [[ ! -f /swapfile ]]; then
  fallocate -l "${SWAP_SIZE_GB}G" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
fi
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
# The file existing does not mean it is swapped on. Check the end state.
if ! swapon --show=NAME --noheadings 2>/dev/null | grep -qx '/swapfile'; then
  swapon /swapfile || warn "could not enable /swapfile"
fi

##### 3. persistent state links #####

log "persistent state links"

# link_state <path-under-$DATA/state> <path-relative-to-$DEV_HOME>
# An existing real file or directory at the destination moves into $DATA
# first, so salvaged state and a fresh first boot converge on one place.
link_state() {
  local src="${DATA}/state/$1" dst="${DEV_HOME}/$2"
  mkdir -p "$(dirname "$src")" "$(dirname "$dst")"

  if [[ -e "$dst" && ! -L "$dst" ]]; then
    if [[ -d "$dst" ]]; then
      mkdir -p "$src"
      # Never delete the original on a failed copy: /data is virtiofs, where
      # xattr and special-file copies can fail, and the rm below is final.
      cp -a "$dst/." "$src/" \
        || fail "could not copy ${dst} into ${src}; refusing to delete the original"
    else
      # Salvaged state on /data wins over a freshly created destination, so
      # an existing src is left alone rather than overwritten.
      [[ -e "$src" ]] || cp -a "$dst" "$src" \
        || fail "could not copy ${dst} to ${src}; refusing to delete the original"
    fi
    rm -rf "$dst"
  fi

  # Create the source if it still does not exist. Directories here; files go
  # through link_state_file.
  [[ -e "$src" ]] || mkdir -p "$src"
  ln -sfn "$src" "$dst"
  chown -R "1000:1000" "$src"
}

# Same, for entries that must be files rather than directories.
link_state_file() {
  local src="${DATA}/state/$1" dst="${DEV_HOME}/$2"
  mkdir -p "$(dirname "$src")" "$(dirname "$dst")"
  if [[ -f "$dst" && ! -L "$dst" ]]; then
    # Same precedence as link_state: existing salvaged state wins, and a
    # failed copy aborts rather than deleting dst.
    [[ -e "$src" ]] || cp -a "$dst" "$src" \
      || fail "could not copy ${dst} to ${src}; refusing to delete the original"
    rm -f "$dst"
  fi
  [[ -e "$src" ]] || : > "$src"
  ln -sfn "$src" "$dst"
  chown "1000:1000" "$src"
}

# Same as link_state_file but never fabricates an empty placeholder. For
# files whose mere existence has meaning: an empty ssh client key is loaded
# and rejected, not ignored.
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

# ~/.ssh stays a real directory so cloud-init keeps ownership of
# authorized_keys, which it rewrites every boot. Only the files that should
# outlive a rebuild are linked individually.
mkdir -p "${DEV_HOME}/.ssh" "${DATA}/state/ssh"
chmod 700 "${DEV_HOME}/.ssh"
chown 1000:1000 "${DEV_HOME}/.ssh"
link_state_file ssh/known_hosts   .ssh/known_hosts
# A stable outbound git identity across rebuilds. Persisted only if the
# operator drops a key in; never generated here.
link_state_file_optional ssh/id_ed25519      .ssh/id_ed25519
link_state_file_optional ssh/id_ed25519.pub  .ssh/id_ed25519.pub
chown -R 1000:1000 "${DATA}/state/ssh"

mkdir -p "${DATA}/work-snapshots"
chown 1000:1000 "${DATA}/work-snapshots"

# Work trees live on the VM disk, not /data: large, hot, and durable via git
# remotes. devbox.sh rebuild gates on a clean tree.
mkdir -p "${DEV_HOME}/work"
chown 1000:1000 "${DEV_HOME}/work"

chsh -s /usr/bin/zsh "$DEV_USER" || warn "chsh failed"

##### 4. firewall #####

if [[ "$ENABLE_UFW" == "1" ]]; then
  log "firewall"
  ufw allow OpenSSH >/dev/null
  # mosh survives laptop sleep and network switches.
  ufw allow 60000:61000/udp >/dev/null
  # --force, never 'yes | ufw enable': under pipefail the producer outlives
  # the consumer and SIGPIPE kills provisioning.
  ufw --force enable >/dev/null
fi

log "core chain complete"

##### 5. root-tree tools: apt repositories #####
#
# Rule 1, root half: tools the provisioner updates live in apt or directly
# in /usr/local/bin, root-owned like distro packages. Nothing here is ever
# symlinked into a user tree, or out of a mode-0700 /root that dev cannot
# traverse.

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
# The docker group is effectively root here. Accepted: the VM itself is the
# security boundary. Switch to rootless if you disagree.

if ! command -v tailscale >/dev/null 2>&1; then
  log "tailscale"
  curl -fsSL "https://pkgs.tailscale.com/stable/debian/${CODENAME}.noarmor.gpg" \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL "https://pkgs.tailscale.com/stable/debian/${CODENAME}.tailscale-keyring.list" \
    -o /etc/apt/sources.list.d/tailscale.list
  apt-get update -qq
  apt-get install -y tailscale
fi

# tailscaled's packaged ExecStart hardcodes --state=/var/lib/tailscale/...,
# so persisting state means overriding ExecStart. Two other routes were
# tried on a live box and do not work: TS_STATE_DIR is read by upstream's
# containerboot wrapper, not tailscaled, and symlinking /var/lib/tailscale
# fails the unit's own StateDirectory= over virtiofs ("Too many levels of
# symbolic links"). PORT and FLAGS still come from the unit's
# EnvironmentFile, but this restates upstream's command line, so a package
# update that changes ExecStart needs a matching update here.
TAILSCALE_DROPIN=/etc/systemd/system/tailscaled.service.d/state-on-data.conf
if ! grep -q '^ExecStart=/usr/sbin/tailscaled --state=/data/state/tailscale/tailscaled.state' "$TAILSCALE_DROPIN" 2>/dev/null; then
  log "persisting tailscale state on /data"
  systemctl stop tailscaled 2>/dev/null || true
  mkdir -p "${DATA}/state/tailscale"
  # Copy any existing identity in, never deleting the original. The orphan
  # left in /var/lib is harmless once ExecStart stops pointing at it.
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

# Remove the dead TS_STATE_DIR drop-in from the earlier design, so nothing
# on the box still documents a mechanism that does not work.
if [[ -f /etc/systemd/system/tailscaled.service.d/override.conf ]]; then
  rm -f /etc/systemd/system/tailscaled.service.d/override.conf
  systemctl daemon-reload
fi

systemctl enable --now tailscaled
# No 'tailscale up' and no auth key anywhere. The identity set by the one
# manual 'sudo tailscale up' lives on /data via the override above and
# survives every rebuild, MagicDNS name included.

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
  # known regressions, which suits long unattended agent loops. apt, not the
  # native installer, which busy-looped for 12+ minutes on this guest.
  echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main" \
    >/etc/apt/sources.list.d/claude-code.list
  apt-get update -qq
  apt-get install -y claude-code
fi

if ! command -v google-chrome >/dev/null 2>&1; then
  log "chrome"
  # The apt repo, not a direct .deb, so Chrome rides normal 'apt upgrade'.
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
# No distro package exists for these. bootstrap runs as root, so
# /usr/local/bin is writable and no installer needs to escalate or prompt.

if ! command -v starship >/dev/null 2>&1; then
  log "starship"
  # --yes because the installer's stdin is the piped script, so a prompt
  # breaks the pipe. -b installs straight into /usr/local/bin.
  optional "starship" sh -c \
    'curl -fsSL https://starship.rs/install.sh | sh -s -- --yes -b /usr/local/bin >/dev/null'
fi

if ! command -v herdr >/dev/null 2>&1; then
  log "herdr"
  # HOME is unset on qemu-ga exec paths and herdr's installer dies without it.
  export HOME="${HOME:-/root}"
  # HERDR_INSTALL_DIR rides the sh side of the pipe; a prefix on the curl
  # side never reaches the installer. The override works, so unlike
  # moshi-hook below this needs no cross-tree fallback copy.
  curl -fsSL https://herdr.dev/install.sh | HERDR_INSTALL_DIR=/usr/local/bin sh >/dev/null \
    || warn "herdr install failed"
fi

if ! command -v moshi-hook >/dev/null 2>&1; then
  log "moshi-hook"
  # The one documented cross-tree exception: the installer lands in
  # ~root/.local/bin regardless of INSTALL_DIR, so copy out afterward.
  # Copies, not symlinks: /root is mode 0700 and dev cannot traverse it.
  # Installs two binaries, and 403s behind Cloudflare on some networks.
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
# who updates them. mise provides node, python and bun; npm globals on top
# of it carry opencode, pi and codex.
#
# Toolchains install under ~/.local/share/mise on the VM disk; only the
# manifest at ~/.config/mise persists on /data. They are reproducible from
# it, and keeping them local avoids running node off virtiofs.

MISE_TOOLS="${MISE_TOOLS:-node@lts python@3.13 bun@latest}"

log "mise"
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

# The 'opencode' meta-package demands a musl build on glibc (EBADPLATFORM),
# so install the platform-scoped package directly. Those create no bin link,
# so link it by hand within the user tree. Both ends are the same user.
npm i -g --no-fund --no-audit opencode-linux-x64 || echo "WARNING: opencode failed" >&2
prefix="$(npm prefix -g)"
if [[ -f "$prefix/lib/node_modules/opencode-linux-x64/bin/opencode" ]]; then
  ln -sf "$prefix/lib/node_modules/opencode-linux-x64/bin/opencode" "$prefix/bin/opencode"
fi

npm i -g --no-fund --no-audit @openai/codex || echo "WARNING: codex failed" >&2

# --ignore-scripts per pi's own docs; it needs no lifecycle scripts.
npm i -g --no-fund --no-audit --ignore-scripts @earendil-works/pi-coding-agent \
  || echo "WARNING: pi failed" >&2

# pnpm as the documented fallback package manager. bun comes from mise.
npm i -g --no-fund --no-audit pnpm@latest || echo "WARNING: pnpm failed" >&2

# uv owns python packages; Debian 13's system python is externally-managed.
mise exec python -- python -m pip install --quiet --upgrade uv || echo "WARNING: uv failed" >&2

# mise only shims what it installed itself, and shims are all a
# non-interactive login shell sees. Without this the npm globals and uv
# above are installed and still "not found".
mise reshim || echo "WARNING: mise reshim failed" >&2
EOF

##### 8. shell configuration #####
#
# Rule 2: Debian sources /etc/profile.d for dash login shells too, so a
# bash-only construct there makes every 'sh -lc' probe exit 2. Everything
# written here is POSIX, and the dash -n loop below aborts if it is not.

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

# zoxide's init output is shell-specific; guard on the running shell.
cat >/etc/profile.d/20-devbox-zoxide.sh <<'EOF'
# POSIX sh. Must parse under dash; validated by devbox-bootstrap.
if [ -n "${BASH_VERSION:-}" ] && command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init bash)"
fi
EOF

# Covers every login shell, dash and bash included, not just zsh: agents,
# scripts and remote-exec all invoke tools this way.
cat >/etc/profile.d/15-devbox-mise-shims.sh <<'EOF'
# POSIX sh. Must parse under dash; validated by devbox-bootstrap.
# mise shims, not "mise activate": activate is an interactive-shell
# mechanism, and scripts, scp and remote-exec run non-interactively.
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
# Rule 3: the file is managed and lives on /data. Own it outright; no
# sed-merging with what another tool wrote. Because it persists on /data,
# herdr's first-run write happens once ever, and herdr is installed before
# this runs so that single first run is deterministic.

ZSHRC_VERSION="3"
link_state_file zshrc .zshrc

if ! grep -q "^# devbox-managed zshrc v${ZSHRC_VERSION}\$" "${DATA}/state/zshrc" 2>/dev/null; then
  log "writing managed .zshrc (v${ZSHRC_VERSION})"
  cat >"${DATA}/state/zshrc" <<'ZRC'
# devbox-managed zshrc v3
# Regenerated by devbox-bootstrap when the version marker changes.
# Local additions go in ~/.zshrc.local, which is sourced at the end.
#
# ~/.zshenv owns PATH and runs first on every zsh invocation. Do not prepend
# to PATH here: one owner per entry, or it duplicates on every shell start.

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

# starship is the sole prompt owner. No promptinit and no 'prompt <name>'
# here: a theme's precmd re-asserts itself on every render and stomps
# starship regardless of load order.
command -v starship >/dev/null && eval "$(starship init zsh)"

alias ll='ls -lah'
alias dc='docker compose'
alias work='tmux new -A -s work -c ~/work'
reload() { exec zsh; }

[ -f "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"
ZRC
  chown 1000:1000 "${DATA}/state/zshrc"
fi

# The profile.d files above cover every login shell, but not plain
# 'ssh host cmd', which is neither login nor interactive. zsh sources
# ~/.zshenv for that case, so this is the zsh-specific top-up rather than a
# duplicate of the profile.d file.
ZSHENV_VERSION="2"
link_state_file zshenv .zshenv

if ! grep -q "^# devbox-managed zshenv v${ZSHENV_VERSION}\$" "${DATA}/state/zshenv" 2>/dev/null; then
  log "writing managed .zshenv (v${ZSHENV_VERSION})"
  cat >"${DATA}/state/zshenv" <<'ZENV'
# devbox-managed zshenv v2
# Regenerated by devbox-bootstrap when the version marker changes.
#
# zsh sources this on every invocation, including plain 'ssh host cmd', the
# one entry point /etc/profile.d cannot reach. Debian's /etc/zsh/zprofile
# never sources /etc/profile, so both prepends that file makes for other
# shells are repeated here: ~/.local/bin, holding the mise binary, and the
# shims directory, holding what mise manages.
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
# Linger keeps these running with no session attached, so the box is
# reachable from Moshi's session picker without an SSH login first.

log "systemd user units"
loginctl enable-linger "$DEV_USER"

# 'sudo -iu' establishes no PAM login session, so systemctl --user below has
# no bus until the user manager is up. Start it rather than waiting on a
# login session that never comes; linger keeps it running afterward.
systemctl start "user@$(id -u "$DEV_USER").service"

install -d -o 1000 -g 1000 -m 0755 "${DEV_HOME}/.config/systemd/user"

# moshi-hook is a root-tree tool, so /usr/local/bin, not %h/.local/bin.
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

# Pre-starts the default herdr session. Moshi's picker lists only running
# sessions, so a fresh box would show nothing until someone ran 'herdr'.
#
# script(1) gives the TUI a tty, which it needs even when the client
# daemonizes. Type=simple because the process stays attached to the session,
# so forking detection would time out: the unit is the session holder.
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

# Known and unfixed: Moshi's picker labels the herdr workspace "~".
# WorkingDirectory= on the unit was tried and moves the cwd without changing
# the label, so do not re-try it. The fix would be 'herdr workspace rename'
# after the session starts. The mkdir below is unrelated to the label.
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
# as soon as pairing happens. Same bus env as above, or moshi-hook cannot
# see its own running daemon and warns that it is not running.
optional "moshi-hook claude hooks" \
  sudo -iu "$DEV_USER" env \
    "XDG_RUNTIME_DIR=/run/user/$(id -u "$DEV_USER")" \
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$DEV_USER")/bus" \
    moshi-hook install --target claude
