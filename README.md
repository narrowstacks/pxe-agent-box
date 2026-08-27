# pxe-agent-box

A single, persistent Proxmox dev box for agent workflows.

> **AI agent?** Read [AGENTS.md](AGENTS.md) instead, then
> [docs/pitfalls.md](docs/pitfalls.md).

One box: VMID 104, named `devbox`, Debian 13 (trixie). Build it once with
`devbox.sh`, then `devbox.sh rebuild` destroys and recreates it in place. Auth,
dotfiles and tool config survive every rebuild. Working trees under `~/work` do
not, and the rebuild gate exists to keep that safe.

## What's on the box

Default shell is zsh, with a managed `.zshrc` (history sharing, completion,
autocd, zoxide, starship prompt).

| Category | Tools |
| --- | --- |
| TypeScript | mise-managed Node LTS + bun, pnpm, tsc/tsx/vitest/eslint/prettier |
| Agent CLIs | Claude Code (`claude`), opencode, pi, OpenAI Codex |
| Browser | Chrome stable (`--headless=new`), or `google-chrome-under-xvfb` for headed |
| Python | mise-managed python, uv (+ `uvx`) |
| Infra | Docker + compose, GitHub CLI, Tailscale, mosh (UDP 60000-61000 open) |
| Terminals | herdr (pre-started), tmux, zoxide/fzf/ripgrep/fd |
| Extras | sqlite3, strace/lsof/ncdu, jq, rsync, build-essential |

Node, Python and bun are owned by mise in the `dev` user's tree and reinstalled
from the mise manifest (`~/.config/mise`, which persists) on every rebuild.
Everything else installs as root through apt or into `/usr/local/bin`.

Running for you as systemd user units, kept alive by linger:

- `moshi-hook.service`: pair once from the iOS app and the box appears in
  Moshi's session picker. Claude agent hooks are pre-installed.
- `herdr-session.service`: holds the default herdr session open so `herdr` and
  Moshi attach instantly. Do not use `herdr server stop` to walk away; it kills
  every pane.

Claude Code installs from Anthropic's signed apt repo with its key fingerprint
verified at install time, so upgrades ride normal `apt upgrade`.

`bootstrap.sh` tolerates individual tool failures: an optional tool that cannot
install logs a `WARNING` and the rest still completes. A core-chain failure
(base packages, tuning, persistent-state links, firewall) aborts loudly.

---

## Quickstart

Prerequisites: a Proxmox VE host you can reach as root, and an SSH key.

### 1. Configure

```sh
cp config.example.sh config.sh
```

What actually matters in `config.sh`:

- `SSH_KEY_FILES`: absolute paths, resolved **on the PVE host**. `devbox.sh
  render` refuses to produce a snippet without at least one key.
- `STORAGE`: run `pvesm status` and pick one that exists and has space. Must be
  images-capable; `local-lvm` is the default install's answer.
- `VM_CORES` / `VM_MEMORY_MB` / `VM_DISK_SIZE_GB`: size against your host's
  real RAM. `scripts/preflight.sh` checks memory fit before every `create`.
- `DATA_HOST_DIR`: a plain directory on the PVE host that becomes `/data` in
  the guest over virtiofs. This is the box's only persistent volume.

### 2. Copy to the Proxmox host

Scripts run **on the Proxmox host**, not your Mac.

```sh
rsync -av --delete --exclude .pi ./ root@<pve-host>:/root/agent-box/
scp config.sh root@<pve-host>:/root/agent-box/config.sh
```

### 3. Verify the host, build the template

```sh
ssh root@<pve-host>
cd /root/agent-box && chmod +x devbox.sh scripts/*.sh
./devbox.sh preflight
./devbox.sh template
```

`preflight` checks Proxmox version, virtiofsd, storage, memory headroom, VMID
conflicts, SSH keys, and reachability of every third-party apt repo and the
cloud image. `template` downloads the Debian 13 image and converts VM 9000 into
a template. You repeat this only when Debian ships a new trixie image or you
change infrastructure values.

### 4. Create the box

```sh
./devbox.sh create
```

Clones the template into VMID 104, mounts `/data`, boots, and prints the guest
IP once the QEMU guest agent reports one. The address comes from DHCP, so do
not assume it is stable across rebuilds. `bootstrap.sh` then runs inside the
guest for several minutes:

```sh
ssh dev@<ip> tail -f /var/log/cloud-init-output.log
```

### 5. Rebuild

```sh
./devbox.sh rebuild
```

Destroys VMID 104 and recreates it from the template. `/data` is untouched.
Before destroying anything, `rebuild`:

1. Refuses if `~/work` has uncommitted changes, unpushed commits, non-git
   directories with contents, or loose files.
2. Snapshots `~/work` to `/data/work-snapshots`, keeping the last three.
3. Prompts you to type the VM name.

`--force` skips the gate and the snapshot. It is a deliberate destructive
escape hatch, not a habit.

The lifecycle: `template` once, `create` once, `rebuild` whenever you want a
clean box.

---

## What persists

**`/data` survives every rebuild.** It is virtiofs, backed by `DATA_HOST_DIR`
on the PVE host, and nothing in the VM lifecycle can reach it. Symlinked into
it:

- Auth and tool state: `~/.claude`, `~/.claude.json`, `~/.config/gh`,
  `~/.config/herdr`, `~/.config/moshi`, `~/.config/opencode`, `~/.config/mise`,
  `~/.codex`, `~/.pi`, `~/.gitconfig`, `~/.zsh_history.d`
- SSH: `~/.ssh/known_hosts`, and `~/.ssh/id_ed25519{,.pub}` if you add one, for
  a stable outbound git identity
- Managed `~/.zshrc` and `~/.zshenv`
- Tailscale's node identity, so your MagicDNS name does not change

**`~/work` does not survive.** It is on the VM disk that `rebuild` destroys.
That is why `rebuild` refuses a dirty tree and snapshots it first.

**Toolchains do not survive**, but are reproducible. `~/.local/share/mise` is
on the VM disk and reinstalls from the manifest, which does persist.

## One-time account setup

Do these once on a freshly created box. All four persist across every rebuild.

1. `sudo tailscale up`
2. `gh auth login`
3. `claude login` (or export `ANTHROPIC_API_KEY`)
4. `moshi-hook pair --token <token>`, optional. Token from Moshi > Settings >
   Hooks; the daemon is already running.

## Daily notes

- **herdr** is pre-started, so `herdr` attaches instantly. Detach with
  `ctrl+b q`; panes keep running.
- **Moshi**: point the iOS app at the box over SSH or Mosh. With moshi-hook
  paired, blocked agents send push notifications that deep-link to the exact
  pane. For Mosh, set the connection's *Mosh server path* to
  `/usr/bin/mosh-server` if asked.
- **mosh** works out of the box; ufw already allows UDP 60000-61000.
- Add packages via `EXTRA_APT_PACKAGES` and `MISE_TOOLS` in `config.sh`.

## Config reference

Every knob is documented in `config.example.sh`. Highlights:

| Knob | Meaning | Default |
| --- | --- | --- |
| `TEMPLATE_ID` / `VMID` / `VMNAME` | template and box identity | `9000` / `104` / `devbox` |
| `STORAGE` / `SNIPPET_STORAGE` | where disks and cloud-init files live | `local-lvm` / `local` |
| `BRIDGE` / `NET_VLAN_TAG` | network attach | `vmbr0` / untagged |
| `STATIC_IP` / `GATEWAY` / `SEARCH_DOMAIN` | skip DHCP | DHCP |
| `VM_CORES` / `VM_MEMORY_MB` / `VM_DISK_SIZE_GB` | box size | `8` / `16384` / `160` |
| `ADMIN_USER` | login user, uid 1000 | `dev` |
| `SSH_KEY_FILES` | pubkeys baked in, absolute host paths | `/root/.ssh/*.pub` |
| `DATA_HOST_DIR` / `DATA_MAP_ID` | host dir backing `/data`, and its PVE mapping id | `/srv/devdata` / `devdata` |
| `CLOUD_IMAGE_URL` | image the template is built from | trixie genericcloud qcow2 |
| `BOOTSTRAP_URL` | where the guest fetches `bootstrap.sh` | pinned tag on GitHub raw |
| `MISE_TOOLS` | toolchains mise installs | `node@lts python@3.13 bun@latest` |
| `SWAP_SIZE_GB` / `ENABLE_UFW` | guest tuning | `8` / on |
| `EXTRA_APT_PACKAGES` | extra apt packages, space-separated | empty |

## FAQ

**Is there a GUI or VNC?**
No desktop environment. The Proxmox web console gives a text serial console,
enough to fix a broken SSH config. For browser work use
`google-chrome --headless=new`, or `google-chrome-under-xvfb <url>` when
something insists on a headed browser (1920x1080 virtual framebuffer).

**Moshi's picker shows the workspace as `~`.**
herdr derives the label from the session's working directory, and the
pre-started unit sets none, so it defaults to `$HOME`. To change it, rename the
workspace after the session starts with `herdr workspace rename`.

**Static IP instead of DHCP?**
Set `STATIC_IP="10.0.0.42/24"` and `GATEWAY` in `config.sh` before `create`.

**Upgrading the template?**
`./devbox.sh template --force` rebuilds only the template; the running box is
untouched. The next `rebuild` picks it up.

**Something broke during bootstrap?**
`ssh dev@<ip> tail -50 /var/log/cloud-init-output.log`. Since `bootstrap.sh` is
idempotent, re-running it as `sudo devbox-bootstrap` is usually enough. Reach
for `rebuild` only if the box is unrecoverable. Emergency console:
`qm terminal 104` on the host.

**Where is the cloud-init snippet?**
`${SNIPPET_STORAGE}:snippets/devbox.yaml`, regenerated from
`cloud-init/devbox.yaml.tpl` on every `create` and `rebuild`.

**How do I see what would happen without doing it?**
`./devbox.sh render` prints the snippet to stdout. `DRYRUN=1 ./devbox.sh create`
(or `rebuild`) prints every `qm` and `pvesh` command instead of running them.

## Files

```text
config.example.sh          copy to config.sh and edit
devbox.sh                  PVE host: preflight, salvage, template, render, create, rebuild
cloud-init/devbox.yaml.tpl rendered into the per-box cloud-init snippet
bootstrap.sh               guest: converges the box, re-runnable forever
scripts/preflight.sh       PVE host: verifies the host before anything is built
scripts/lint.sh            bash -n + shellcheck over every shell file
scripts/smoke-test.sh      assertion suite against a booted box
tests/test-render.sh       unit tests for cloud-init rendering
docs/pitfalls.md           rules for working on this repo, read before editing
```

## Security notes

- Inbound is SSH and mosh only. Password auth and root login are disabled.
  sudo is NOPASSWD for the admin user, appropriate for a private lab network.
- Docker-published ports bypass ufw by design. Do not bind services to
  `0.0.0.0` you did not mean to expose.
- moshi-hook listens on localhost only and relays through your paired device.
- The admin user is in the `docker` group, which is effectively root on the
  guest. Accepted because the VM itself is the security boundary.
