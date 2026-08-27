#!/usr/bin/env bash
# agent-box guest provisioning — runs as root via cloud-init runcmd on first boot.
#
# Installs: bun, Chrome (stable, headless+GUI), Node LTS (npm ecosystem
# compat + agent CLIs), pnpm, Claude Code, opencode, pi, OpenAI Codex CLI,
# Docker + compose plugin, plus the standard CLI kit.
# Applies cache/size tuning and locks the firewall down to SSH.
#
# Knobs come from /etc/agent-box.env written by create-vm.sh.

set -euo pipefail

# /etc/agent-box.env is generated at VM-create time, so its path can't be
# statically followed.
ENV_FILE="/etc/agent-box.env"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

NODE_MAJOR="${NODE_MAJOR:-24}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-8}"
ENABLE_UFW="${ENABLE_UFW:-1}"
ADMIN_USER="${ADMIN_USER:-dev}"

# Common npm packages agents reach for in TS projects.
# Override via /etc/agent-box.env (space separated).
NPM_GLOBALS="${NPM_GLOBALS:-typescript tsx @types/node prettier eslint vitest concurrently http-server}"

# Common Python packages agents use for scripting/prototyping.
# On Ubuntu 24.04 pip is externally managed (PEP 668), hence --break-system-packages
# into the system env. Agents should still prefer `uv venv` / `python3 -m venv` per project.
PIP_PACKAGES="${PIP_PACKAGES:-pytest ruff black rich httpx requests pydantic python-dotenv numpy}"

# Common apt packages agents reach for (search/codecs/db clients/debugging).
# EXTRA_APT_PACKAGES from /etc/agent-box.env is appended on top of this default.
DEFAULT_APT_PACKAGES="ripgrep fd-find fzf zoxide mosh tree ncdu sqlite3 strace lsof rsync less file manpages"

export DEBIAN_FRONTEND=noninteractive

log() { printf '\033[1;34m[provision]\033[0m %s\n' "$*"; }

# Mirror output to the serial console for out-of-band debugging. Done HERE via
# process substitution, not in runcmd's 'bash | tee': a tee write failure to
# the console (EIO when serial-getty owns the line) would surface as the
# pipeline's exit code and fail cloud-init even on success.
if [[ -w /dev/ttyS0 ]]; then
  exec > >(tee /dev/ttyS0) 2>&1
fi
stamp() {
  mkdir -p /var/lib/agent-box
  date -u +"%Y-%m-%dT%H:%M:%SZ" >/var/lib/agent-box/provisioned-at
}

log "apt update + base packages"
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates gnupg curl wget unzip jq git gh build-essential tmux \
  qemu-guest-agent docker.io docker-compose-v2 ufw htop \
  python3 python3-yaml python3-pip \
  ${DEFAULT_APT_PACKAGES} "${EXTRA_APT_PACKAGES:-}"

# visibility ASAP: guest agent up before anything else can fail
systemctl enable --now qemu-guest-agent

log "installing Node ${NODE_MAJOR}.x LTS (Nodesource)"
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/nodesource-setup.sh
bash /tmp/nodesource-setup.sh >/dev/null
apt-get install -y nodejs

npm install -g pnpm@latest
npm install -g @openai/codex
# opencode's meta-package resolves a musl optional dep on glibc hosts
# (EBADPLATFORM, upstream packaging bug). Install the glibc-native binary
# package directly — exactly what npm's own error message recommends.
npm install -g opencode-linux-x64 ||
  log "WARNING: opencode install failed — retry later: npm i -g opencode-linux-x64"
# platform-scoped packages don't get a bin link on PATH (no top-level bin map)
# — link the binary explicitly so it lands next to the other agents.
if [[ -x /usr/lib/node_modules/opencode-linux-x64/bin/opencode ]]; then
  ln -sf /usr/lib/node_modules/opencode-linux-x64/bin/opencode /usr/local/bin/opencode
fi
# pi explicitly documents --ignore-scripts: no lifecycle scripts needed for normal installs
npm install -g --ignore-scripts @earendil-works/pi-coding-agent

log "installing common global npm packages (${NPM_GLOBALS})"
# shellcheck disable=SC2086  # word splitting intended
npm install -g ${NPM_GLOBALS}

log "installing uv (fast python package manager) + common python packages"
# astral.sh official installer over TLS
# nosemgrep: bash.curl.security.curl-pipe-bash.curl-pipe-bash
curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
# install (copy), not symlink: the originals live under /root which is 0700 —
# symlinks would be invisible to the admin user the agents actually run as.
install -m 755 /root/.local/bin/uv /usr/local/bin/uv
install -m 755 /root/.local/bin/uvx /usr/local/bin/uvx
# shellcheck disable=SC2086  # word splitting intended
# --ignore-installed: some distro-python packages (e.g. typing_extensions) ship
# without RECORD metadata; plain --break-system-packages would try to uninstall
# them and abort.
pip3 install --break-system-packages --ignore-installed --no-input ${PIP_PACKAGES}

log "installing Claude Code from Anthropic's apt repo, stable channel (per code.claude.com/docs/en/setup)"
# Native installer busy-loops post-download on some headless guests, so use
# the documented apt path. Verify the signing key's published fingerprint
# BEFORE registering the repo; skip cleanly rather than trust an unverified key.
mkdir -p /etc/apt/keyrings
if curl -fsSL https://downloads.claude.ai/keys/claude-code.asc \
  -o /etc/apt/keyrings/claude-code.asc &&
  gpg --show-keys /etc/apt/keyrings/claude-code.asc 2>/dev/null | tr -d ' ' |
  grep -q 31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE; then
  # stable channel (~1 wk behind latest, skips regressed releases); upgrade via
  # 'apt upgrade claude-code' — our banner's apt-update counter sees these.
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main" \
    >/etc/apt/sources.list.d/claude-code.list &&
    apt-get update -qq &&
    DEBIAN_FRONTEND=noninteractive apt-get install -y claude-code ||
    log "WARNING: claude-code apt install failed — see https://code.claude.com/docs/en/setup"
else
  rm -f /etc/apt/keyrings/claude-code.asc
  log "WARNING: claude-code signing key missing or fingerprint mismatch — repo not registered"
fi

log "installing Google Chrome stable (full GUI + headless in one binary)"
CHROME_DEB="$(mktemp /tmp/chrome-XXXXXX.deb)"
curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o "$CHROME_DEB"
apt-get install -y "$CHROME_DEB"
rm -f "$CHROME_DEB"

log "installing xvfb (virtual display so headed chrome works without a desktop)"
apt-get install -y --no-install-recommends xvfb
# on-demand wrapper: run any GUI app under a throwaway virtual display,
# e.g. google-chrome-under-xvfb https://example.com
cat >/usr/local/bin/google-chrome-under-xvfb <<'EOF'
#!/usr/bin/env bash
# Runs google-chrome headed inside a fresh virtual X display; window is never
# shown anywhere, but rendering/screenshot/devtools behavior matches real GUI.
exec xvfb-run --server-args="-screen 0 1920x1080x24" /usr/bin/google-chrome \
  --no-sandbox --disable-dev-shm-usage "$@"
EOF
chmod 755 /usr/local/bin/google-chrome-under-xvfb

log "installing tailscale (service starts, but you must run 'sudo tailscale up' once to authenticate)"
curl -fsSL https://tailscale.com/install.sh | sh # nosemgrep: bash.curl.security.curl-pipe-bash.curl-pipe-bash (tailscale.com official installer over TLS)
systemctl enable --now tailscaled

log "installing bun system-wide"
# nosemgrep: bash.curl.security.curl-pipe-bash.curl-pipe-bash (bun.sh official installer over TLS)
curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local FORCE_INSTALL=1 bash >/dev/null

log "installing herdr (agent runtime / terminal multiplexer)"
# herdr.dev official installer over TLS. HOME must be exported: under
# cloud-init runcmd it is set, but qemu-ga exec paths run without it and the
# installer dies on "HOME: parameter not set".
# nosemgrep: bash.curl.security.curl-pipe-bash.curl-pipe-bash
export HOME="${HOME:-/root}"
# HERDR_INSTALL_DIR must ride the sh side of the pipe (env prefixes on curl
# don't reach the installer).
curl -fsSL https://herdr.dev/install.sh | HERDR_INSTALL_DIR=/usr/local/bin sh >/dev/null
# fallback copy if the installer ignored the dir
if ! command -v herdr >/dev/null 2>&1 && [[ -x /root/.local/bin/herdr ]]; then
  install -m 755 /root/.local/bin/herdr /usr/local/bin/herdr
fi

log "installing moshi-hook (companion daemon for the Moshi iOS terminal)"
# getmoshi.app official installer over TLS. Skip interactive first-run (pairing
# happens later from the phone); INSTALL_DIR=/usr/local/bin puts it on PATH for
# every user. Non-fatal: cdn.getmoshi.app sits behind Cloudflare and curl gets
# 403'd on some networks — a failed download must not abort provisioning.
# nosemgrep: bash.curl.security.curl-pipe-bash.curl-pipe-bash
# Installer ignores INSTALL_DIR env passed to curl (never reaches sh) and
# lands in ~root/.local/bin regardless — pass env to sh, then copy binaries
# onto the system PATH (copies, not symlinks: /root is 0700).
curl -fsSL https://getmoshi.app/install.sh |
  MOSHI_HOOK_SKIP_FIRST_RUN=1 INSTALL_DIR=/usr/local/bin sh ||
  log "WARNING: moshi-hook install failed (Cloudflare 403?) — rerun 'curl -fsSL https://getmoshi.app/install.sh | sh' later"
for b in moshi moshi-hook; do
  if ! command -v "$b" >/dev/null 2>&1 && [[ -x /root/.local/bin/$b ]]; then
    install -m 755 "/root/.local/bin/$b" "/usr/local/bin/$b"
  fi
done
command -v moshi >/dev/null 2>&1 || log "WARNING: moshi missing"

# Run the hook daemon under systemd --user (linger is enabled below, so it
# starts at boot without any login). Without this the daemon only lives as
# long as the SSH session that started it, and Moshi loses multiplexer
# discovery (herdr/tmux workspaces) the moment that session closes.
if command -v moshi-hook >/dev/null 2>&1; then
  sudo -iu "$ADMIN_USER" bash -s <<'MOSHIUNIT'
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/moshi-hook.service" <<'UNIT'
[Unit]
Description=Moshi hook daemon (agent hooks + Moshi bridge)
After=network-online.target

[Service]
ExecStart=%h/.local/bin/moshi-hook serve
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now moshi-hook.service
MOSHIUNIT
  # pre-install agent hook integrations (claude now; others pair later)
  sudo -iu "$ADMIN_USER" moshi-hook install --target claude >/dev/null 2>&1 ||
    log "WARNING: moshi-hook claude hooks not installed (claude may not be present yet)"
fi

# Pre-start the default herdr session so Moshi's session picker shows a
# workspace on first connect (it only lists RUNNING sessions; a fresh box
# would otherwise show nothing until someone runs `herdr` once). herdr's TUI
# needs a tty even when the client just daemonizes the session, so script(1)
# provides one. Type=simple: the script/herdr-client process stays attached
# to the session (unlike tmux's detach-and-exit), so forking detection would
# time out — the unit IS the session holder.
sudo -iu "$ADMIN_USER" bash -s <<'HERDRUNIT'
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/herdr-session.service" <<'UNIT'
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
UNIT
systemctl --user daemon-reload
systemctl --user enable --now herdr-session.service
HERDRUNIT

# Seed the herdr config in one write: --default-config plus the theme keys
# set (appending a second [theme] table makes the TOML invalid — duplicate
# key — so patch the uncommented defaults instead of adding a block).
sudo -iu "$ADMIN_USER" bash -s <<'HERDRCONF'
conf="$HOME/.config/herdr/config.toml"
if [[ ! -f "$conf" ]]; then
  mkdir -p "$(dirname "$conf")"
  herdr --default-config > "$conf"
  sed -i \
    -e 's|^# name = "catppuccin"|name = "catppuccin"|' \
    -e 's|^# auto_switch = false|auto_switch = true|' \
    -e 's|^# dark_name = "catppuccin"|dark_name = "catppuccin"|' \
    -e 's|^# light_name = "catppuccin-latte"|light_name = "catppuccin-latte"|' \
    "$conf"
fi
HERDRCONF

log "allowing ${ADMIN_USER}'s user daemons (herdr/moshi-hook) to run without an active login session"
loginctl enable-linger "$ADMIN_USER" 2>/dev/null || true

if command -v herdr >/dev/null 2>&1; then
  log "seeding herdr config for ${ADMIN_USER} (catppuccin theme + agent sidebar)"
  # stdin, not bash -lc: sudo -i joins its args with spaces and re-parses
  # them through the login shell, destroying quoting and newlines.
  sudo -iu "$ADMIN_USER" bash -s <<'SEED'
    conf="$HOME/.config/herdr/config.toml"
    if [[ ! -f "$conf" ]]; then
      mkdir -p "$(dirname "$conf")"
      herdr --default-config > "$conf"
      cat >> "$conf" <<EOF2

[theme]
name = "catppuccin"
auto_switch = true
light_name = "catppuccin-latte"
dark_name = "catppuccin"

[ui.sidebar.agents]
rows = [
  ["state_icon", "workspace", "tab"],
  ["agent"],
]
EOF2
    fi
SEED
fi

log "granting ${ADMIN_USER} docker access + npm cache dir"
usermod -aG docker "$ADMIN_USER" || true
sudo -u "$ADMIN_USER" bash -c 'mkdir -p ~/.cache/node-gyp ~/.npm'

##### size & performance tuning #####

if ((SWAP_SIZE_GB > 0)) && ! swapon --show=NAME --noheadings | grep -q '^/swapfile$'; then
  log "creating ${SWAP_SIZE_GB}G swapfile"
  fallocate -l "${SWAP_SIZE_GB}G" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

log "writing sysctl tuning (inotify watches for TS watch modes, vm settings)"
cat >/etc/sysctl.d/90-agent-box.conf <<'EOF'
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 1024
vm.swappiness = 10
net.core.somaxconn = 4096
EOF
sysctl --system >/dev/null

log "configuring docker log rotation + default address pools"
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "default-address-pools": [
    { "base": "172.30.0.0/16", "size": 24 }
  ]
}
EOF

log "limiting journald disk usage"
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=200M\n' >/etc/systemd/journald.conf.d/agent-box.conf

log "enabling fstrim.timer (thin-provisioned disks like their TRIMs)"
systemctl enable --now fstrim.timer

log "configuring zoxide smart-cd hook for bash"
cat >/etc/profile.d/zoxide.sh <<'EOF'
# zoxide smart-cd (interactive shells only)
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init bash)"
EOF

##### network hardening #####

if [[ "$ENABLE_UFW" == "1" ]]; then
  log "ufw: allowing OpenSSH + mosh UDP range (note: published docker ports bypass ufw)"
  ufw allow OpenSSH
  ufw allow 60000:61000/udp comment 'mosh'
  # --force, NOT 'yes |': under pipefail, yes dies of SIGPIPE (141) when ufw
  # closes stdin and set -e aborts provisioning right after enabling the fw.
  ufw --force enable
fi

##### verification & finishing touches #####

log "verifying installed tools"
bun --version
node --version
npm --version
pnpm --version
for cli in gh opencode pi codex; do
  "$cli" --version || log "WARNING: $cli not on PATH yet — new login shells should find it"
done
tsc --version
uv --version
python3 --version
tailscale version || log "WARNING: tailscale missing"
command -v herdr >/dev/null 2>&1 || log "WARNING: herdr missing"
command -v mosh-server >/dev/null 2>&1 || log "WARNING: mosh missing"
python3 -c 'import yaml; print("pyyaml", yaml.__version__)' || log "WARNING: pyyaml missing"
gh auth status 2>/dev/null || true # expect 'not logged in' until you run `gh auth login`
command -v claude >/dev/null 2>&1 ||
  log "WARNING: claude not on PATH — apt install may have failed"
sudo -iu "$ADMIN_USER" claude --version ||
  log "WARNING: claude not runnable for ${ADMIN_USER}"
google-chrome --version
which xvfb-run || log "WARNING: xvfb missing — headed chrome unavailable"

log "apt status refresh timer (keeps the login banner's update info fresh)"
cat >/usr/local/bin/agent-box-apt-status <<'EOF'
#!/usr/bin/env bash
# Refreshes pending-update counts (apt + language ecosystems) for the login
# banner. Invoked by agent-box-apt-status.timer, never at login time.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
updates=$(apt list --upgradable 2>/dev/null | grep -vc '^Listing' || true)
security=$(apt-get -s dist-upgrade 2>/dev/null | grep -ci '^Inst .*secur' || true)
mkdir -p /var/lib/agent-box
{
  printf 'updates=%s\nsecurity=%s\n' "$updates" "$security"

  # npm -g covers everything npm-installed system-wide: pnpm, opencode, pi,
  # codex, tsx… (--parseable = one line per package, machine-countable)
  npm_outdated=0
  command -v npm >/dev/null && \
    npm_outdated=$(npm outdated -g --parseable 2>/dev/null | grep -c . || true)
  printf 'npm_outdated=%s\n' "$npm_outdated"

  # Agents run as the admin user, so scan THAT account's ecosystem trees:
  # ~/.bun/install/global (bun add -g) and pip's --user env (~/.local), where
  # runtime installs actually land. System python env is also counted, minus
  # entries the user tree supersedes (shadowing must not double-report).
  ADMIN_USER_="${ADMIN_USER:-dev}"
  ADMIN_HOME="$(getent passwd "$ADMIN_USER_" | cut -d: -f6)"

  bun_outdated=0
  if command -v bun >/dev/null && [[ -f "${ADMIN_HOME}/.bun/install/global/package.json" ]]; then
    bun_outdated=$(npm outdated -g --parseable \
      --prefix "${ADMIN_HOME}/.bun/install/global" 2>/dev/null | grep -c . || true)
  fi
  printf 'bun_outdated=%s\n' "$bun_outdated"

  # Effective python-outdated = packages the admin user can actually act on:
  # their ~/.local (--user) env, plus pip itself. Distro-owned system packages
  # (Twisted, cloud-init deps…) are apt's business — counting them as "pip
  # outdated" produced 45 lines of noise the user cannot fix via pip.
  ADMIN_USER_="${ADMIN_USER:-dev}"
  ADMIN_HOME="$(getent passwd "$ADMIN_USER_" | cut -d: -f6)"

  pip_outdated=0
  if [[ -n "$ADMIN_HOME" ]] && ls "${ADMIN_HOME}"/.local/lib/python3*/site-packages >/dev/null 2>&1; then
    pip_outdated=$(su -s /bin/bash "$ADMIN_USER_" -c \
      'pip3 list --outdated --user --disable-pip-version-check 2>/dev/null' \
      | tail -n +3 | grep -c . || true)
  fi
  printf 'pip_outdated=%s\n' "$pip_outdated"

  # bun self-updates outside npm; compare against the latest GitHub release.
  # Best-effort: rate limits or network hiccups just leave the prompt away.
  bun_cur=$(bun --version 2>/dev/null || true)
  bun_new=""
  [[ -n "$bun_cur" ]] && bun_new=$(curl -fsSL --max-time 20 \
    https://api.github.com/repos/oven-sh/bun/releases/latest |
    jq -r '.tag_name' 2>/dev/null | sed 's/^bun-v//' || true)
  printf 'bun_cur=%s\nbun_new=%s\n' "$bun_cur" "$bun_new"

  printf 'ts=%s\n' "$(date +%s)"
} >/var/lib/agent-box/apt-status
EOF
chmod 755 /usr/local/bin/agent-box-apt-status
cat >/etc/systemd/system/agent-box-apt-status.service <<'EOF'
[Unit]
Description=agent-box: refresh apt update counts for login banner
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/agent-box-apt-status
Nice=10
IOSchedulingClass=idle
EOF
cat >/etc/systemd/system/agent-box-apt-status.timer <<'EOF'
[Unit]
Description=agent-box: refresh apt counts twice daily
[Timer]
OnBootSec=7min
OnUnitActiveSec=12h
RandomizedDelaySec=20min
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
/usr/local/bin/agent-box-apt-status >/dev/null 2>&1 || log "WARNING: initial apt-status scan failed"
systemctl enable --now agent-box-apt-status.timer

cat >/etc/profile.d/agent-box-welcome.sh <<'EOF'
# agent-box welcome banner + interactive first-run setup checklist.
# Sourced by every login shell (bash -l); keep it fast and quiet-on-fail.

# ensure ~/.local/bin (where the claude installer links its binary) is on PATH
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

printf '\n\033[1;36m=== agent-box ===\033[0m\n'
printf 'bun %s | node %s | pnpm %s | docker ready\n' \
  "$(bun --version 2>/dev/null)" "$(node --version 2>/dev/null)" "$(pnpm --version 2>/dev/null)"
printf 'agents: claude / opencode / pi / codex | chrome: google-chrome [--headless=new]\n'
printf 'headed chrome under virtual display: google-chrome-under-xvfb <url>\n'
printf 'tsc/tsx/vitest ready | uv + pytest/ruff/black ready | docker ready\n\n'

# One-time account setup checklist. Each line re-checks LIVE state, so the
# list shrinks as you complete the steps.
green='\033[0;32m'; yellow='\033[0;33m'; dim='\033[2m'; off='\033[0m'
row() { # row <done|todo> <label> <command>
  if [[ "$1" == done ]]; then
    printf " ${green}✔${off} %-14s${dim}done${off}\n" "$2"
  else
    printf " ${yellow}○${off} %-14s run: \033[1m%s\033[0m\n" "$2" "$3"
  fi
}

remaining=0

if sudo tailscale status --json 2>/dev/null | grep -q '"BackendState": "Running"'; then
  row done tailscale '' ; else remaining=$((remaining+1)); row todo tailscale 'sudo tailscale up'
fi

if gh auth status >/dev/null 2>&1; then
  row done 'gh' ''; else remaining=$((remaining+1)); row todo 'gh' 'gh auth login'
fi

if [[ -f "$HOME/.claude/.credentials.json" || -f "$HOME/.claude.json" ]]; then
  row done claude ''; else remaining=$((remaining+1)); row todo claude '~/.local/bin/claude'
fi

if command -v moshi >/dev/null 2>&1 && compgen -G "$HOME/.moshi*" >/dev/null; then
  row done 'moshi-hook' ''; else remaining=$((remaining+1)); row todo 'moshi-hook' 'pair from Moshi on iOS'
fi

if ((remaining)); then
  printf " ${dim}%s step%s left before this box is fully yours${off}\n\n" \
    "$remaining" "$( ((remaining == 1)) || echo s )"
else
  printf " ${green}all setup steps complete — happy hacking${off}\n\n"
fi

# Package freshness — fed by agent-box-apt-status.timer (12h), never scanned
# at login. Stale data (>48h old) is suppressed rather than shown wrong.
if [[ -r /var/lib/agent-box/apt-status ]]; then
  updates=0 security=0 ts=0
  . /var/lib/agent-box/apt-status 2>/dev/null || true
  if (( $(date +%s) - ts < 172800 )); then
    if ((security > 0)); then
      printf " ${yellow}%s update%s pending (%s security)${off} — sudo apt update && sudo apt upgrade\n" \
        "$updates" "$( ((updates == 1)) || echo s )" "$security"
    elif ((updates > 0)); then
      printf " ${dim}%s update%s pending${off} — sudo apt update && sudo apt upgrade\n" \
        "$updates" "$( ((updates == 1)) || echo s )"
    else
      printf " ${green}packages up to date${off}\n"
    fi
    [[ -e /var/run/reboot-required ]] && printf " ${yellow}reboot required to finish updating${off}\n"
  fi
fi

if [[ -r /var/lib/agent-box/apt-status ]]; then
  npm_outdated=0 pip_outdated=0 bun_cur='' bun_new=''
  . /var/lib/agent-box/apt-status 2>/dev/null || true
  if (( $(date +%s) - ts < 172800 )); then
    if ((npm_outdated > 0)); then
      printf " ${dim}%s global npm package%s outdated${off} — npm outdated -g; npm i -g <name>@latest\n" \
        "$npm_outdated" "$( ((npm_outdated == 1)) || echo s )"
    fi
    if ((pip_outdated > 0)); then
      printf " ${dim}%s user python package%s outdated${off} — pip3 list --outdated --user; pip3 install --user --break-system-packages -U <name>\n" \
        "$pip_outdated" "$( ((pip_outdated == 1)) || echo s )"
    fi
    if ((bun_outdated > 0)); then
      printf " ${dim}%s bun package%s outdated${off} — bun pm ls -g; bun update -g\n" \
        "$bun_outdated" "$( ((bun_outdated == 1)) || echo s )"
    fi
    if [[ -n "$bun_cur" && -n "$bun_new" && "$bun_cur" != "$bun_new" ]]; then
      printf " ${dim}bun %s available (%s installed)${off} — bun upgrade\n" "$bun_new" "$bun_cur"
    fi
  fi
fi
EOF

log "cleaning apt caches"
apt-get autoremove -y
apt-get clean

systemctl restart qemu-guest-agent
stamp
log "provisioning complete."
