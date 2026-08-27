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
# opencode's platform-specific optional deps can mismatch glibc/musl and fail
# the whole install (EBADPLATFORM). Retry once, then continue — it is re-checked
# in the verification section below rather than aborting provisioning.
npm install -g opencode-ai ||
  npm install -g --force opencode-ai ||
  log "WARNING: opencode install failed — retry later: npm i -g opencode-ai"
# pi explicitly documents --ignore-scripts: no lifecycle scripts needed for normal installs
npm install -g --ignore-scripts @earendil-works/pi-coding-agent

log "installing common global npm packages (${NPM_GLOBALS})"
# shellcheck disable=SC2086  # word splitting intended
npm install -g ${NPM_GLOBALS}

log "installing uv (fast python package manager) + common python packages"
# astral.sh official installer over TLS
# nosemgrep: bash.curl.security.curl-pipe-bash.curl-pipe-bash
curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
ln -sf /root/.local/bin/uv /usr/local/bin/uv
ln -sf /root/.local/bin/uvx /usr/local/bin/uvx
# shellcheck disable=SC2086  # word splitting intended
pip3 install --break-system-packages --no-input ${PIP_PACKAGES}

log "installing Claude Code via the official installer (as ${ADMIN_USER}; lands in ~/.local/bin)"
sudo -iu "$ADMIN_USER" bash -c \
  'curl -fsSL https://claude.ai/install.sh | bash' # nosemgrep: bash.curl.security.curl-pipe-bash.curl-pipe-bash (Anthropic's own installer over TLS)

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
# herdr.dev official installer over TLS
# nosemgrep: bash.curl.security.curl-pipe-bash.curl-pipe-bash
curl -fsSL https://herdr.dev/install.sh | sh
# installers often land in ~root/.local/bin — expose system-wide
if ! command -v herdr >/dev/null 2>&1 && [[ -x /root/.local/bin/herdr ]]; then
  ln -sf /root/.local/bin/herdr /usr/local/bin/herdr
fi

log "installing moshi-hook (companion daemon for the Moshi iOS terminal)"
# getmoshi.app official installer over TLS. Skip interactive first-run (pairing
# happens later from the phone); INSTALL_DIR=/usr/local/bin puts it on PATH for
# every user. Non-fatal: cdn.getmoshi.app sits behind Cloudflare and curl gets
# 403'd on some networks — a failed download must not abort provisioning.
# nosemgrep: bash.curl.security.curl-pipe-bash.curl-pipe-bash
MOSHI_HOOK_SKIP_FIRST_RUN=1 INSTALL_DIR=/usr/local/bin \
  curl -fsSL https://getmoshi.app/install.sh | sh ||
  log "WARNING: moshi-hook install failed (Cloudflare 403?) — rerun 'curl -fsSL https://getmoshi.app/install.sh | sh' later"
command -v moshi >/dev/null 2>&1 || log "WARNING: moshi missing"

log "allowing ${ADMIN_USER}'s user daemons (herdr/moshi-hook) to run without an active login session"
loginctl enable-linger "$ADMIN_USER" 2>/dev/null || true

if command -v herdr >/dev/null 2>&1; then
  log "seeding herdr config for ${ADMIN_USER} (catppuccin theme + agent sidebar)"
  sudo -iu "$ADMIN_USER" bash -lc '
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
  ' || log "WARNING: could not seed herdr config for ${ADMIN_USER}"
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
  yes | ufw enable
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
sudo -iu "$ADMIN_USER" bash -lc 'claude --version' ||
  log "WARNING: claude not found for ${ADMIN_USER} (check ~/.local/bin/claude)"
google-chrome --version
which xvfb-run || log "WARNING: xvfb missing — headed chrome unavailable"

cat >/etc/profile.d/agent-box-welcome.sh <<'EOF'
# agent-box welcome banner
printf '\n\033[1;36m=== agent-box ===\033[0m\n'
printf 'bun %s | node %s | pnpm %s | docker ready\n' \
  "$(bun --version)" "$(node --version)" "$(pnpm --version)"
printf 'agents: claude / opencode / pi / codex | chrome: google-chrome [--headless=new]\n'
printf 'headed chrome under virtual display: google-chrome-under-xvfb <url>\n'
printf 'tsc/tsx/vitest ready | uv + pytest/ruff/black ready | docker ready\n'
printf 'tailscale installed — run: sudo tailscale up\n\n'
# ensure ~/.local/bin (where the claude installer links its binary) is on PATH
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
EOF

log "cleaning apt caches"
apt-get autoremove -y
apt-get clean

systemctl restart qemu-guest-agent
stamp
log "provisioning complete."
