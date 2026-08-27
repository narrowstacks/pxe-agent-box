# pxe-agent-box

A single, persistent Proxmox dev box for agent workflows.

> **Are you an AI agent?** Skip the human tutorial, read
> [AGENTS.md](AGENTS.md) for a setup walkthrough built for you (questions to
> ask, gotchas to check, exact commands to run).

There is one box: VMID 104, named `devbox`, running Debian 13 (trixie). You
build it once with `devbox.sh`, and from then on `devbox.sh rebuild`
destroys and recreates it in place. Auth, dotfiles and tool config survive
every rebuild; your working trees under `~/work` do not, and the rebuild gate
exists specifically to keep that safe (see "Rebuild the box" below).

## What's on the box

**Default shell: zsh** (a managed `.zshrc`: history sharing, completion,
autocd, zoxide, starship prompt).

| Category | Tools |
| --- | --- |
| TypeScript | mise-managed Node LTS + bun · pnpm · tsc/tsx/vitest/eslint/prettier (npm globals) |
| Agent CLIs | Claude Code (apt, `claude`) · opencode · pi · OpenAI Codex |
| Browser | Chrome stable (`--headless=new`), or headed via `google-chrome-under-xvfb` |
| Python | uv (+ `uvx`), installed via mise's python |
| Infra | Docker + compose · GitHub CLI · Tailscale · mosh (UDP 60000-61000 pre-opened) |
| Terminals | herdr, pre-started · tmux · zoxide/fzf/ripgrep/fd |
| Extras | sqlite3 · strace/lsof/ncdu · jq · rsync · build-essential · zsh |

Node, Python and bun are owned by mise in the `dev` user's tree, reinstalled
from the mise manifest (`~/.config/mise`, which persists) on every rebuild.
Everything else root-installs, either through apt or directly into
`/usr/local/bin`, and stays put across rebuilds because it lives on the fresh
VM disk built from the same recipe every time.

**Already running for you** (systemd user units, kept alive by linger):

- `moshi-hook.service`: hook daemon; pair once from the iOS app and the box
  appears in Moshi's session picker (with a workspace label of `~`, not a
  project name, see the FAQ). Claude agent hooks are pre-installed.
- `herdr-session.service`: holds the default herdr session open so Moshi and
  `herdr` attach instantly. Don't use `herdr server stop` to walk away, that
  kills every pane.

There is no login-banner MOTD and no periodic apt-status timer; both were
dropped as unnecessary surface area.

Claude Code comes from Anthropic's signed apt repo (key fingerprint verified
by `bootstrap.sh` at install time, stable channel); upgrades ride normal
`apt upgrade`. Bootstrap tolerates individual tool failures: anything that
can't install logs a `WARNING` and the rest still completes; only a
core-chain failure (base packages, kernel tuning, persistent-state links,
firewall) aborts loudly.

Everything is installed by `bootstrap.sh`, run inside the guest on first boot
and re-runnable forever afterward. Nothing bloated, no desktop environment;
see [FAQ](#faq) for console details.

---

## Quickstart

Prerequisites: a Proxmox VE host you can SSH into as root, and an SSH key on
your Mac.

### 1. Configure

```sh
cp config.example.sh config.sh
```

Edit `config.sh`. What actually matters:

- `SSH_KEY_FILES`: absolute paths, resolved on the PVE host. Check they
  exist (`ls` them); `devbox.sh render` refuses to produce a snippet without
  at least one key.
- `STORAGE`: run `pvesm status` on your Proxmox host and pick a storage that
  exists and has space (`local-lvm` is the default install's answer).
- `VM_CORES` / `VM_MEMORY_MB` / `VM_DISK_SIZE_GB`: size against your host's
  real RAM. On the reference host (32 GB, ~12 GB already committed to other
  VMs), 16384 MB fits and 24576 MB would overcommit it.
  `scripts/preflight.sh` checks memory fit before every `create`.
- `DATA_HOST_DIR`: a plain directory on the PVE host that becomes `/data`
  in the guest over virtiofs. This is the box's only persistent volume.

Everything else has sane defaults.

### 2. Copy to the Proxmox host

The scripts run **on the Proxmox host**, not your Mac.

```sh
rsync -av --delete --exclude .pi ./ root@<pve-host>:/root/agent-box/
scp config.sh root@<pve-host>:/root/agent-box/config.sh   # keep local copy out of repo sync
```

### 3. Verify the host, then build the template (once)

```sh
ssh root@<pve-host>
cd /root/agent-box && chmod +x devbox.sh scripts/*.sh   # insurance if perms were lost in transit
./devbox.sh preflight
./devbox.sh template
```

`preflight` checks Proxmox version, virtiofsd availability, storage, memory
headroom, VMID conflicts, SSH keys, and reachability of every third-party apt
repo and the Debian cloud image, before anything is built. `template`
downloads the Debian 13 cloud image (~400 MB) and converts VM 9000 into a
template. Takes a few minutes. You don't repeat this unless Debian ships a
new trixie image or you change infrastructure values in `config.sh`.
(`create`, below, also runs `preflight` itself, so you don't have to remember
to call it separately before a fresh build.)

### 4. Create the box

```sh
./devbox.sh create
```

Clones the template into VMID 104, mounts `/data`, and boots. Prints the
guest IP once the QEMU guest agent reports one. The box picks up whatever
address DHCP hands it, so don't assume it stays fixed across rebuilds.
`bootstrap.sh` then runs inside the guest for several minutes; watch it:

```sh
ssh dev@<ip> tail -f /var/log/cloud-init-output.log
```

Then `ssh dev@<ip>` and work.

### 5. Rebuild the box

```sh
./devbox.sh rebuild
```

Destroys VMID 104 and recreates it from the template, exactly like `create`.
`/data` (and therefore everything under it) is untouched. Before it destroys
anything, `rebuild`:

1. Refuses if `~/work` has uncommitted changes, unpushed commits, non-git
   directories with contents, or loose files/dotfiles.
2. Snapshots `~/work` to `/data/work-snapshots` anyway (belt and braces,
   keeping the last three snapshots) once the gate above passes.
3. Prompts you to type the VM name to confirm.

Pass `--force` to skip the gate and snapshot and rebuild immediately. This
is a deliberate, destructive escape hatch, not a shortcut to reach for by
habit.

That's the lifecycle: `preflight` → `template` (once) → `create` (once) →
`rebuild` (repeatedly, whenever you want a clean box).

### Iterating on `bootstrap.sh` itself

`bootstrap.sh` runs inside the guest and is idempotent. scp your edit over
and re-run it as `sudo devbox-bootstrap` to test a change. Don't rebuild the
VM to test a bootstrap edit; that's slow and defeats the point of an
idempotent script. `devbox-bootstrap --update` re-fetches the script from
`BOOTSTRAP_URL` and re-execs it, which is how a live box picks up a change
that's already been pushed.

---

## What persists and what doesn't

- **`/data` (virtiofs, backed by `DATA_HOST_DIR` on the host) survives every
  rebuild.** Auth state (`~/.claude`, `~/.claude.json`, `~/.config/gh`,
  `~/.config/herdr`, `~/.config/moshi`, `~/.config/opencode`,
  `~/.config/mise`, `~/.codex`, `~/.pi`, `~/.zsh_history.d`, `~/.gitconfig`,
  `~/.ssh/known_hosts`, and, if you've dropped one in, `~/.ssh/id_ed25519{,.pub}`
  for a stable outbound git identity), the managed `~/.zshrc`/`~/.zshenv`,
  and Tailscale's node identity (`/var/lib/tailscale` is symlinked to
  `/data/state/tailscale`, so the MagicDNS name doesn't change) all live
  there as symlink targets.
- **`~/work` does NOT survive a rebuild.** It lives on the VM's own disk,
  which `rebuild` destroys and recreates. That's exactly why `rebuild`
  refuses to run against a dirty `~/work` and snapshots it to
  `/data/work-snapshots` first, see "Rebuild the box" above.
- Toolchains under `~/.local/share/mise` also live on the VM disk and are
  reinstalled from the mise manifest (which *does* persist) on every
  rebuild.

## One-time account setup

Do these once, the first time you get a shell on a freshly created box:

1. **Tailscale**: `sudo tailscale up` (gives you a stable hostname + tailnet
   access from anywhere)
2. **GitHub CLI**: `gh auth login`
3. **Claude Code**: `claude login` (or `export ANTHROPIC_API_KEY`)
4. **Moshi** (optional): `moshi-hook pair --token <token>`. Token comes from
   Moshi > Settings > Hooks (the daemon is already running; pairing is the
   only missing piece)

After the first time, all four persist across every `rebuild`. That is the
whole point of the `/data` persistence design. You should never need to redo
this list unless you deliberately wipe `/data`.

## Daily workflow notes

- **herdr**: pre-started at boot; `herdr` attaches instantly (detach with
  `ctrl+b q`, panes keep running). Don't use `herdr server stop` to walk away,
  that kills every pane. Moshi's picker currently shows the workspace label
  as `~`, not a project name; see the FAQ.
- **Moshi**: point the iOS app at this box over SSH or Mosh; the paired hook
  daemon serves its session picker, so the herdr session appears
  automatically (both transports). With moshi-hook paired, blocked agents
  send push notifications that deep-link to the exact pane. For Mosh
  transports, set the connection's *Mosh server path* to
  `/usr/bin/mosh-server` if the app asks.
- **mosh**: works out of the box (`ufw` already allows UDP 60000-61000).
  Survives laptop sleep and network switches.
- Override packages in `config.sh`: `EXTRA_APT_PACKAGES`, `MISE_TOOLS`.

## Config reference

Every knob lives in `config.example.sh` with comments. Highlights:

| Knob | Meaning | Default |
| --- | --- | --- |
| `TEMPLATE_ID` / `VMID` / `VMNAME` | template and box identity | `9000` / `104` / `devbox` |
| `STORAGE` / `SNIPPET_STORAGE` | where disks/cloud-init files live | `local-lvm` / `local` |
| `BRIDGE` / `NET_VLAN_TAG` | network attach | `vmbr0` / untagged |
| `STATIC_IP` / `GATEWAY` / `SEARCH_DOMAIN` | skip DHCP | DHCP |
| `VM_CORES` / `VM_MEMORY_MB` / `VM_DISK_SIZE_GB` | box size | `8` / `16384` / `160` |
| `ADMIN_USER` | login user (uid 1000) created on the box | `dev` |
| `SSH_KEY_FILES` | pubkeys baked into the box, absolute host paths | `/root/.ssh/*.pub` |
| `DATA_HOST_DIR` / `DATA_MAP_ID` | host directory backing `/data`, and its Proxmox directory-mapping ID | `/srv/devdata` / `devdata` |
| `CLOUD_IMAGE_URL` | Debian 13 cloud image to build the template from | trixie genericcloud qcow2 |
| `BOOTSTRAP_URL` | where the guest fetches `bootstrap.sh` from on first boot | `raw.githubusercontent.com/.../main/bootstrap.sh` |
| `MISE_TOOLS` | toolchains mise installs into the user tree | `node@lts python@3.13 bun@latest` |
| `SWAP_SIZE_GB` / `ENABLE_UFW` | guest tuning | `8` / on |
| `EXTRA_APT_PACKAGES` | extra apt packages, space-separated | empty |

## FAQ

**Is there a GUI/VNC?**
No desktop environment. The Proxmox web console shows a *text* serial console
(boot messages + login prompt), enough to fix a broken SSH config. For visual
browser work, agents use `google-chrome --headless=new`; when something insists
on headed Chrome, `google-chrome-under-xvfb <url>` runs it in a virtual
1920x1080 framebuffer.

**Why does Moshi's picker show `~` instead of a project name?**
An earlier design assumed a `~/projects` directory would become the
workspace label. It doesn't: herdr derives the label from the session's
working directory, the pre-started `herdr-session.service` unit sets none,
and it defaults to `$HOME`. A prior attempt at pinning
`WorkingDirectory=%h/projects` on that unit moved the process's cwd but did
not change the picker label. This isn't fixed. A real fix would likely go
through `herdr workspace rename <id> <label>` after the session starts;
that's a possible follow-up, not something this repo does today.

**Static IP instead of DHCP?**
Set `STATIC_IP="10.0.0.42/24"` (and `GATEWAY`) in `config.sh` before running
`create`.

**Template upgrade?**
Re-run `./devbox.sh template --force` (destroys + rebuilds only the
template; the running box is untouched). Then the next `./devbox.sh rebuild`
uses it.

**Something broke mid-bootstrap?**
Check `ssh dev@<ip> tail -50 /var/log/cloud-init-output.log`. Since
`bootstrap.sh` is idempotent, re-running it as `sudo devbox-bootstrap` is
usually enough; reach for `./devbox.sh rebuild` only if the box itself is
unrecoverable. Emergency console: `qm terminal 104` on the host.

**Where's the per-box cloud-init file?**
`${SNIPPET_STORAGE}:snippets/devbox.yaml` on the PVE host, regenerated by
`devbox.sh create`/`rebuild` from `cloud-init/devbox.yaml.tpl` every time.

**How do I see what the cloud-init snippet would look like without touching
anything?**
`./devbox.sh render` prints it to stdout. `DRYRUN=1 ./devbox.sh create` (or
`rebuild`) prints every `qm`/`pvesh` command it would run instead of running
them.

## Files

```text
config.example.sh          copy to config.sh and edit (see step 1)
devbox.sh                  PVE host: preflight, salvage, template, render, create, rebuild
cloud-init/devbox.yaml.tpl rendered into the per-box cloud-init snippet
bootstrap.sh               guest: converges the box on first boot, re-runnable forever
scripts/preflight.sh       PVE host: verifies the host before anything is built
scripts/lint.sh            Mac/CI: bash -n + shellcheck + dash -n over every shell file
scripts/smoke-test.sh      Mac/CI: assertion suite against a booted box (the gate for every change)
tests/test-render.sh       Mac/CI: unit tests for cloud-init snippet rendering
HANDOFF-SIMPLIFICATION.md  incident record behind the rules enforced in bootstrap.sh
```

## Security notes

- The box only accepts SSH (and mosh) inbound; password auth is disabled;
  root login is disabled; sudo is NOPASSWD for the admin user on a private
  lab network; tighten if this faces the internet.
- Docker-published ports bypass ufw by design; don't bind services to
  `0.0.0.0` you didn't mean to expose.
- moshi-hook listens on localhost only and relays via your paired device.
- The admin user is in the `docker` group, which is effectively root on this
  guest. Accepted here because the VM itself is the security boundary.
