# pxe-agent-box

Disposable Proxmox dev boxes for agent workflows, one command each.

> **Are you an AI agent?** Skip the human tutorial — read
> [AGENTS.md](AGENTS.md) for a setup walkthrough built for you (questions to
> ask, gotchas to check, exact commands to run).

You build **one template** on your Proxmox host. After that, every new dev box
is a single command — fully provisioned, your SSH keys already in it, ready in
a few minutes. Throw boxes away freely; making a fresh one costs nothing.

## What's on each box

**Default shell: zsh** (seeded `.zshrc`: history sharing, completion, autocd,
zoxide). Every box also runs a login banner that live-checks the setup steps
below and shows pending apt/npm/pip updates (refreshed twice daily by a
systemd timer — never scanned at login).

| Category | Tools |
| --- | --- |
| TypeScript | bun · Node 24 LTS · pnpm · tsc/tsx/vitest/eslint/prettier (global) |
| Agent CLIs | Claude Code (apt, `claude`) · opencode · pi · OpenAI Codex |
| Browser | Chrome stable — `--headless=new`, or headed via `google-chrome-under-xvfb` |
| Python | uv (+ `uvx`) · pytest/ruff/black/rich/httpx/pydantic/numpy · PyYAML |
| Infra | Docker + compose · GitHub CLI · Tailscale · mosh (UDP 60000–61000 pre-opened) |
| Terminals | herdr 0.8+ with a **pre-started `projects` workspace** · tmux · zoxide/fzf/ripgrep/fd |
| Extras | sqlite3 · strace/lsof/ncdu · jq · rsync · build-essential · zsh |

**Already running for you** (systemd user units, survive logins via linger):

- `moshi-hook.service` — hook daemon; pair once from the iOS app and the box
  appears with its herdr workspaces in Moshi's session picker. Claude agent
  hooks are pre-installed.
- `herdr-session.service` — holds the default herdr session open so Moshi and
  `herdr` attach instantly. The workspace is named `projects` (with a matching
  `~/projects` directory).
- `agent-box-apt-status.timer` — refreshes the update counts shown in the
  login banner every 12h.

Claude Code comes from Anthropic's signed apt repo (key fingerprint verified
at provision time, stable channel) — upgrades ride normal `apt upgrade`.
Provisioning tolerates individual failures: anything that can't install logs
a `WARNING` in `/var/log/cloud-init-output.log` and the rest still completes.

Everything is installed by `cloud-init/provision.sh` on first boot. Nothing
bloated, no desktop environment — see [FAQ](#faq) for console details.

---

## Quickstart

Prerequisites: a Proxmox VE host you can SSH into as root, and an SSH key on
your Mac.

### 1. Configure

```sh
cp config.example.sh config.sh
```

Edit `config.sh`. Three settings actually matter:

- `SSH_KEY_FILES` — check these paths exist (`ls` them). The script refuses to
  create a box you can't log into.
- `STORAGE` — run `pvesm status` on your Proxmox host and pick a storage that
  exists and has space (`local-lvm` is the default install's answer).
- `TEMPLATE_ID` — any free VM id; `9000` is fine unless you use it.

Everything else has sane defaults.

### 2. Copy to the Proxmox host

The scripts run **on the Proxmox host**, not your Mac.

```sh
scp -r ./ root@<pve-host>:/root/agent-box
```

(`rsync -av --delete --exclude .pi ./ root@<pve-host>:/root/agent-box/` does the
same but skips unchanged files — prefer it once you start editing.)

### 3. Build the template — once

```sh
ssh root@<pve-host>
cd /root/agent-box && chmod +x scripts/*.sh   # insurance if perms were lost in transit
./scripts/build-template.sh
```

Downloads Ubuntu 24.04 Server cloud image (~700 MB), creates VM 9000, converts
it to a template. Takes ~5 minutes. You never do this again unless Ubuntu
releases a new image or you change `config.sh` infrastructure values.

### 4. Make boxes

```sh
./scripts/create-vm.sh                     # defaults: 4 cores, 8 GB RAM, 80 GB disk
./scripts/create-vm.sh -n ts-work -c 8 -m 32768   # bigger box
```

Prints the IP when it's up. First boot provisions for a few minutes; watch it:

```sh
ssh dev@<ip> tail -f /var/log/cloud-init-output.log   # until "provisioning complete"
```

Then `ssh dev@<ip>` and work.

### 5. Delete boxes

```sh
./scripts/delete-vm.sh ts-work             # asks for confirmation
./scripts/delete-vm.sh 9101 --force        # doesn't ask
```

That's the whole lifecycle: build-template → create → delete → create again.

---

## One-time account setup per box

The login banner tracks these live — completed steps flip to ✔ on your next
login, so the banner itself is your checklist:

1. **Tailscale**: `sudo tailscale up` (gives you a stable hostname + tailnet
   access from anywhere)
2. **GitHub CLI**: `gh auth login`
3. **Claude Code**: `claude login` (or `export ANTHROPIC_API_KEY`)
4. **Moshi** (optional): pair the phone app with
   `moshi-hook pair --token <token>` — token comes from Moshi → Settings → Hooks
   (the daemon is already running; pairing is the only missing piece)

## Daily workflow notes

- **herdr**: pre-started at boot — `herdr` attaches instantly (detach with
  `ctrl+b q`, panes keep running). Don't use `herdr server stop` to walk away —
  that kills every pane. Workspaces live under `~/projects`.
- **Moshi**: point the iOS app at this box over SSH or Mosh; the paired hook
  daemon serves its session picker, so herdr workspaces appear automatically
  (both transports). With moshi-hook paired, blocked agents send push
  notifications that deep-link to the exact pane. For Mosh transports, set the
  connection's *Mosh server path* to `/usr/bin/mosh-server` if the app asks.
- **mosh**: works out of the box after provisioning (`ufw` already allows UDP
  60000–61000). Survives laptop sleep and network switches.
- Override per-box packages in `config.sh`: `EXTRA_APT_PACKAGES`,
  `NPM_GLOBALS`, `PIP_PACKAGES`.

## Config reference

Every knob lives in `config.example.sh` with comments. Highlights:

| Knob | Meaning | Default |
| --- | --- | --- |
| `TEMPLATE_ID` | VM id of the gold template | `9000` |
| `STORAGE` / `SNIPPET_STORAGE` | where disks/cloud-init files live | `local-lvm` / `local` |
| `BRIDGE` / `NET_VLAN_TAG` | network attach | `vmbr0` / untagged |
| `STATIC_IP` / `GATEWAY` | skip DHCP | DHCP |
| `VM_CORES` / `VM_MEMORY_MB` / `VM_DISK_SIZE_GB` | box size at clone time | 4 / 8192 / 80 |
| `ADMIN_USER` | login user created on each box | `dev` |
| `SSH_KEY_FILES` | pubkeys baked into every box | `~/.ssh/*.pub` |
| `NODE_MAJOR` | Node LTS line alongside bun | `24` |
| `SWAP_SIZE_GB` / `ENABLE_UFW` | guest tuning | 8 / on |

CLI flags override config per-box: `create-vm.sh -n name -i vmid -c cores -m memoryMiB -d diskGB [--no-start]`.

## FAQ

**Is there a GUI/VNC?**
No desktop environment. The Proxmox web console shows a *text* serial console
(boot messages + login prompt) — enough to fix a broken SSH config. For visual
browser work, agents use `google-chrome --headless=new`; when something insists
on headed Chrome, `google-chrome-under-xvfb <url>` runs it in a virtual
1920×1080 framebuffer.

**Static IP instead of DHCP?**
Set `STATIC_IP="10.0.0.42/24"` (and `GATEWAY`) in `config.sh` before creating
boxes.

**Template upgrade?**
Re-run `build-template.sh --force` (destroys + rebuilds only the template;
existing boxes are untouched). Then future `create-vm.sh` calls use it.

**Something broke mid-provision?**
Check `ssh dev@<ip> tail -50 /var/log/cloud-init-output.log`; re-provision by
deleting and recreating the box — cheap by design. Emergency console:
`qm terminal <vmid>` on the host.

**Where are per-box cloud-init files?**
`${SNIPPET_STORAGE}:snippets/<name>-<vmid>.yml` on the PVE host.
`delete-vm.sh` cleans them up automatically.

## Files

```text
config.example.sh         copy to config.sh, edit three settings (see step 1)
scripts/build-template.sh PVE host: Ubuntu image → cloud-init template (once)
scripts/create-vm.sh      PVE host: clone template → provisioned box
scripts/delete-vm.sh      PVE host: destroy box + its snippet
cloud-init/provision.sh   guest: installs everything on first boot
```

## Security notes

- Boxes only accept SSH (and mosh) inbound; password auth is disabled; root
  login disabled; sudo is NOPASSWD for your user on a private lab network —
  tighten if this faces the internet.
- Docker-published ports bypass ufw by design — don't bind services to
  `0.0.0.0` you didn't mean to expose.
- moshi-hook listens on localhost only and relays via your paired device.
