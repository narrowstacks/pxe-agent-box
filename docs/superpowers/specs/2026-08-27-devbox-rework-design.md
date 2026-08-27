# devbox rework: from disposable fleet to one rebuildable box

Date: 2026-08-27
Status: approved, ready for implementation planning
Supersedes: the `new-paradigm/` drafts, `cloud-init/provision.sh`, and the
three scripts under `scripts/`.

## 1. Why

The current repo builds many disposable Ubuntu boxes. Every box re-installs
everything and re-authenticates everything, so the cost of a rebuild is high
enough that boxes get repaired in place instead of recreated. The
`HANDOFF-SIMPLIFICATION.md` ledger catalogues what that produced: a 636-line
provisioning script, a mixed install-tree layout that needed symlink and copy
compensations, shell-config races against herdr, and a class of dash-parsing
bugs that silently broke Moshi detection.

This rework inverts the model. One long-lived box, a persistent state volume
on the Proxmox host, and a rebuild that is cheap and safe because the state
that matters was never on the VM disk. Most of the ledger's bug classes are
dissolved structurally rather than worked around.

## 2. Decisions

| Decision | Choice | Rationale |
| --- | --- | --- |
| Base image | Debian 13 trixie genericcloud | Newer glibc and kernel than bookworm, no snapd, small image. Distro package freshness barely matters because mise owns the user toolchains and Docker, Tailscale, gh, Chrome, and Claude Code all ship their own apt repos. |
| Box model | One persistent box, VMID 104, plus `rebuild` | Matches how the box is actually used. Removes `delete-vm.sh` and the per-box snippet bookkeeping. |
| Persistence | State only, on virtiofs `/data` | Measured state on the existing box is 8.2 MB. Work trees stay on the fast VM disk. |
| `/data` backing | Plain directory `/srv/devdata` on charon's root fs | charon has no ZFS. `local-lvm` has 683 GB but at 8 MB of state an LVM volume, mkfs, and fstab entry buy nothing. |
| Bootstrap delivery | curl from the already-public `narrowstacks/pxe-agent-box` | Cleanest cloud-init, and `sudo devbox-bootstrap` re-runs from a local copy. |
| Tailscale | SSH keys plus one manual `tailscale up`, ever | `TS_STATE_DIR` on `/data` means tailscaled returns already authenticated after every rebuild, so an auth key is only needed on genuine first boot. No long-lived secret in the snippet, and SSH stays as a fallback when the tailnet is unhappy. |
| Toolchains | mise owns the user tree | Answers the ledger's core rule directly: one mechanism for node, python, bun, and go, and nothing hops between trees. |
| Smoke tests | Built alongside | The ledger names this the highest-leverage item. |
| Old VMs | Replace in place (104 and 9000) | Salvage first. There is 8.2 MB to lose and `~/projects` is empty. |
| Prompt owner | starship, exclusively | Confirmed. `~/.omp` on the old box is deliberately not salvaged. |
| Username | `dev` at uid 1000 | Continuity with the salvaged state and existing `config.sh`. |

## 3. Architecture

Three layers, each with one job.

### 3.1 Host layer: `devbox.sh`

Runs as root on charon. Replaces `build-template.sh`, `create-vm.sh`, and
`delete-vm.sh`. Sources `config.sh`.

**`devbox.sh template`**

Downloads `debian-13-genericcloud-amd64.qcow2`, creates VM `$TEMPLATE_ID`,
converts it to a template. Notable settings, all applied to the template so
every clone inherits them:

- `--cpu x86-64-v3`. The ledger's default-`qemu64`-lacks-AVX bug caused bun
  binaries to segfault. Setting it here rather than per-clone means it cannot
  be forgotten on a future code path.
- `--scsihw virtio-scsi-single`, `--scsi0 ${STORAGE}:0,import-from=...,discard=on,ssd=1,iothread=1`
- `--ide2 ${STORAGE}:cloudinit`. Cloud-init drive belongs on images-capable
  storage; this is a PVE 8.x quirk already documented in the current scripts.
- `--serial0 socket --vga serial0`, `--agent enabled=1,fstrim_cloned_disks=1`,
  `--ostype l26`

**`devbox.sh create`**

1. Ensure `$DATA_HOST_DIR` exists and the `$DATA_MAP_ID` dir mapping is
   registered in `/etc/pve/mapping/dir.cfg`.
2. `qm clone $TEMPLATE_ID $VMID --name $VMNAME --full --storage $STORAGE`
3. `qm set` cores, memory, `--balloon 0`, `--onboot 1`, `--tags dev`
4. Render the cloud-init snippet from `cloud-init/devbox.yaml.tpl` to
   `${SNIPPET_STORAGE}:snippets/${VMNAME}.yaml`, then
   `--cicustom "user=..."`
5. `--virtiofs0 dirid=${DATA_MAP_ID},cache=always,expose-acl=1`
6. `--ipconfig0` from `STATIC_IP`/`GATEWAY` or `ip=dhcp`
7. `qm disk resize $VMID scsi0 ${VM_DISK_SIZE_GB}G` (the `qm resize` alias
   mangles arguments on PVE 8.x)
8. `qm start $VMID`, then poll the guest agent for an IP and print it

`--balloon 0` is not a preference. PVE requires ballooning disabled for
virtiofs, so this is load-bearing and must be commented as such.

**`devbox.sh rebuild`**

`~/work` is not persisted, so rebuild is gated rather than blind:

1. Over SSH, walk every directory under `~/work`. For each git repository,
   require `git status --porcelain` empty and `git log @{u}..` empty. Treat a
   non-git directory containing files as dirty. Refuse the rebuild and print
   the offending paths unless `--force` is passed.
2. Tar `~/work` excluding `node_modules`, `.venv`, `target`, and `dist` into
   `/srv/devdata/work-snapshots/<ISO8601>.tar.zst`. Keep the last three.
   This is belt and braces behind the gate, not the primary mechanism.
3. Confirm by typing the VM name.
4. `qm stop --timeout 60`, then
   `qm destroy $VMID --destroy-unreferenced-disks 0 --purge 1`
5. Call `create`.

`$DATA_HOST_DIR` is a host directory and is never referenced by the VM config,
so no destroy path can reach it.

**`devbox.sh salvage [vmid]`**

One-shot migration helper. Pulls `~/.claude`, `~/.claude.json`,
`~/.config/{gh,herdr,moshi}`, and `~/.gitconfig` off a running box into
`/srv/devdata/state/`, preserving the layout `bootstrap.sh` expects, and
chowns to uid 1000. Prints what it copied and its size so the result can be
eyeballed before anything is destroyed.

### 3.2 Guest layer: `cloud-init/devbox.yaml.tpl`

Rendered by `devbox.sh create`. Deliberately thin: it creates the account,
mounts `/data`, and hands off. Everything else is `bootstrap.sh`.

- `users:` **omits `- default`**. This prevents Debian's built-in `debian`
  user from being created, which frees uid 1000 for `$ADMIN_USER`. Stable
  uid 1000 is what keeps `/srv/devdata` ownership correct across every
  rebuild, so this is load-bearing and must be commented as such.
- `$ADMIN_USER` gets `uid: 1000`, `groups: [sudo]`, `shell: /usr/bin/zsh`,
  `sudo: ALL=(ALL) NOPASSWD:ALL`, `lock_passwd: true`, and every key in
  `SSH_KEY_FILES` under `ssh_authorized_keys`.
- `mounts:` one virtiofs entry, `[ "$DATA_MAP_ID", "/data", "virtiofs",
  "defaults,nofail", "0", "0" ]`. cloud-init's mounts module runs at config
  stage, before `runcmd` at final stage, so `/data` is available to bootstrap.
- `write_files:` the tailscaled drop-in setting
  `Environment=TS_STATE_DIR=/data/state/tailscale`.
- `runcmd:` enable qemu-guest-agent, `mkdir -p /data/state`, chown to 1000,
  curl `$BOOTSTRAP_URL` to `/usr/local/sbin/devbox-bootstrap`, chmod 0755,
  execute it.
- No Tailscale auth key. No `fs_setup` or `disk_setup` blocks, ever.

The snippet must be generated with a **quoted** heredoc plus explicit
substitution, never an unquoted one. An unquoted heredoc previously executed
a `$(qm set --sshkeys ...)` command that appeared inside a comment.

### 3.3 Convergence layer: `bootstrap.sh`

Lives at the repo root so the raw URL is short and stable. Idempotent,
re-runnable at any time as `sudo devbox-bootstrap`, guarded by
`flock /var/lock/devbox-bootstrap.lock` (not `pgrep -f`, which self-matches).
A `--update` flag re-fetches itself from `$BOOTSTRAP_URL` before running, so
normal re-runs use the local copy and are not at the mercy of an in-flight
edit to `main`.

Asserts `/data` is a mountpoint and aborts loudly if not.

#### Rule 1: one tool, one tree, chosen by who updates it

This is the ledger's identified simplification target and the single biggest
structural change.

- **Root tree.** Tools the provisioner updates go to apt, or when no package
  exists, directly into `/usr/local/bin`. Owned by root, exactly like distro
  packages. Because bootstrap runs as root, installers that need a writable
  target directory get `/usr/local/bin` without escalation prompts.
- **User tree.** Tools that self-update in place live under mise in
  `~/.local/share/mise`, on the VM disk. Only mise's declarative config,
  `~/.config/mise`, persists on `/data`. Toolchains behave like work, not like
  state: they are large, they are hot, and they are reproducible from the
  manifest. Keeping them local avoids executing `node` off virtiofs on every
  invocation and keeps `/data` small enough to justify a plain directory.
- **No symlinks or copies between trees.** `moshi-hook` is the one documented
  exception (its installer ignores `INSTALL_DIR` when the variable prefixes
  the curl side of a pipe), handled with a single `install -m755` and an
  inline comment naming the upstream bug.

`opencode`, `pi`, and `codex` move from `/usr/local/bin` into the mise-node
user tree. This is what actually retires the ledger's root-tree-to-user-tree
bug class: those binaries are now installed, run, and updated by the same
user, and they sit on `$PATH` without compensation. Their *configuration and auth*
persist on `/data` via `.config/opencode`, `.codex`, and `.pi`; the binaries
themselves are reinstalled from the mise manifest on rebuild, which is
deterministic and costs a couple of minutes. `opencode` still installs as
the platform-scoped `opencode-linux-x64` package with an explicit bin link,
because the meta-package misresolves platform deps upstream.

#### Rule 2: every generated profile.d file parses under dash

Ubuntu and Debian source `/etc/profile.d` for dash too. A bash-only construct
there makes any `sh -lc` probe emit a wall of errors and exit 2, which
silently broke Moshi's moshi-hook detection and took hours to find.

bootstrap runs `dash -n` over every file it writes to `/etc/profile.d` and
**aborts on failure**. Shell-specific integrations (zoxide, mise, starship)
are guarded on the running shell or split into `.zsh` variants.

#### Rule 3: ~/.zshrc is managed, lives on /data, and starship owns the prompt

No sed-merging, no stripping of `promptinit` and `prompt adam1` lines. The
file is written once with a marker header, persists on `/data`, and is
regenerated only when the marker version changes.

This is the structural fix for the herdr prompt war. herdr's first-run
behaviour, writing its own `.zshrc` template and seeding `config.toml`, is a
first-run problem. With `~/.zshrc` and `~/.config/herdr` on `/data`, first run
happens exactly once, on the very first boot of the very first box, and never
again. There is nothing left to race against on subsequent rebuilds. Ordering
within that single first run is handled by installing herdr before writing
`~/.zshrc`.

#### Rule 4: script mechanics

- `sudo -iu "$ADMIN_USER" bash -s <<'EOF'` for anything multi-line. `sudo -i`
  joins arguments with spaces and re-parses them, which destroys quoting.
- `ufw --force enable`, never `yes | ufw enable`. Under `pipefail` the
  producer outlived the consumer and SIGPIPE killed provisioning right after
  the firewall came up.
- No pipeline under `pipefail` whose producer outlives its consumer.
- Serial mirroring, if kept, happens inside the script via
  `exec > >(tee /dev/ttyS0) 2>&1` guarded on writability, never as
  `runcmd: bash | tee /dev/ttyS0`.

#### Failure policy

The core chain fails loudly and aborts: apt base packages, Docker, user
creation, `/data` mount and state links. Optional tools log a `WARNING` to
`/var/log/cloud-init-output.log` and let the run complete: opencode, pi,
codex, Chrome, moshi-hook, herdr.

#### Persistence map

Everything below is symlinked from the home directory into `/data/state/`:

| Path in `$HOME` | `/data/state/` entry |
| --- | --- |
| `.claude` | `claude` |
| `.claude.json` (file) | `claude.json` |
| `.config/gh` | `config-gh` |
| `.config/herdr` | `config-herdr` |
| `.config/moshi` | `config-moshi` |
| `.config/opencode` | `config-opencode` |
| `.codex` | `codex` |
| `.pi` | `pi` |
| `.config/mise` | `config-mise` |
| `.gitconfig` (file) | `gitconfig` |
| `.zshrc` (file) | `zshrc` |
| zsh history dir | `zsh-history` |
| `.ssh/known_hosts` (file) | `ssh/known_hosts` |
| `.ssh/id_ed25519{,.pub}` (files) | `ssh/id_ed25519{,.pub}` |
| tailscaled `TS_STATE_DIR` | `tailscale` |

`~/.ssh` itself stays a real directory on the VM disk so cloud-init keeps
ownership of `authorized_keys`. Only the individual files above are linked,
which gives a stable outbound git identity across rebuilds without fighting
cloud-init for the file it writes on every boot.

The link helper must handle the case where the destination already exists as
a real file or directory: copy its contents into `/data` first, then replace
with the symlink. This is what makes the salvaged state and the first boot
converge to the same place.

## 4. Tool inventory

**apt base:** zsh, zsh-autosuggestions, zsh-syntax-highlighting, git, git-lfs,
curl, wget, ca-certificates, gnupg, lsb-release, build-essential, pkg-config,
libssl-dev, tmux, htop, btop, jq, unzip, zip, rsync, tree, ripgrep, fd-find,
bat, fzf, zoxide, sqlite3, strace, lsof, ncdu, mosh, ufw, xvfb,
qemu-guest-agent. Debian ships `fdfind` and `batcat`, so `fd` and `bat` get
`/usr/local/bin` symlinks.

**apt, third-party repos:** Docker CE plus compose and buildx, Tailscale, gh,
`claude-code` (signing key fingerprint `31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE`
verified before the repo is registered, stable channel),
`google-chrome-stable` plus the `google-chrome-under-xvfb` wrapper.

**`/usr/local/bin` direct:** starship (`--yes -b /usr/local/bin`), herdr
(`HERDR_INSTALL_DIR=/usr/local/bin`, with `export HOME="${HOME:-/root}"`
because its installer crashes without `$HOME` under qemu-ga), moshi-hook (the
documented `install -m755` exception).

**mise user tree (VM disk, reinstalled on rebuild from `~/.config/mise`):**
node@lts, python, bun, and via mise-node: typescript, tsx, prettier, eslint,
vitest, opencode-linux-x64, pi, codex. Python packages come
from mise's python plus uv. Debian 13 marks the system python
externally-managed, so `pip3 --user --break-system-packages` is retired
entirely along with the `PIP_PACKAGES` knob.

**systemd user units, with linger enabled:** `moshi-hook.service`,
`herdr-session.service` holding the default `projects` workspace open.

**System tuning:** the inotify, file-max, `vm.max_map_count`, and swappiness
sysctls; `nofile` limits in both `limits.d` and `systemd/system.conf.d`;
tmpfs `/tmp`; an 8 GB swapfile; ufw allowing SSH and UDP 60000-61000 for mosh.

## 5. Configuration

`config.sh` stays gitignored with `config.example.sh` as the committed
reference. Added: `VMID`, `VMNAME`, `DATA_HOST_DIR`, `DATA_MAP_ID`,
`BOOTSTRAP_URL`, `MISE_TOOLS`. Removed: `NODE_MAJOR`, `NPM_GLOBALS`,
`PIP_PACKAGES`, `GUEST_HOSTNAME_PREFIX`. `CLOUD_IMAGE_URL` points at trixie.

`VM_CORES`, `VM_MEMORY_MB`, and `VM_DISK_SIZE_GB` default to 8, 16384, and 160.
Measured during implementation: charon has 32017 MiB total with 12290 MiB
committed to VMs 206 and 800, so the draft's 24576 would have overcommitted the
host by about 4.8 GB. 16384 leaves roughly 3.3 GB for the PVE host itself.

## 6. Repository layout

```text
devbox.sh                     host: template | create | rebuild | salvage
bootstrap.sh                  guest: convergence, curl'd raw from main
cloud-init/devbox.yaml.tpl    snippet template rendered by devbox.sh
config.example.sh             committed reference
config.sh                     gitignored, machine-local
scripts/smoke-test.sh         run from the Mac against a booted box
docs/superpowers/specs/       this document
README.md, AGENTS.md
```

Deleted: `scripts/build-template.sh`, `scripts/create-vm.sh`,
`scripts/delete-vm.sh`, `cloud-init/provision.sh`, `new-paradigm/`.
`HANDOFF-SIMPLIFICATION.md` is retained as the historical record that
justifies the rules in section 3.3.

## 7. `scripts/smoke-test.sh`

Run from the Mac against a booted box, seconds to complete, gating every
template rebuild and every `bootstrap.sh` change. Each assertion maps to a
real incident in the ledger.

1. `cloud-init status --wait` reports `done` with no errors
2. Non-interactive `command -v` for claude, opencode, pi, codex, bun, node,
   npm, mise, uv, starship, herdr, moshi-hook, tailscale, docker, gh,
   google-chrome, mosh, rg, fd, bat, jq
3. `sh -lc 'true'` exits 0 **and** writes nothing to stderr
4. The same for `bash -lc` and `zsh -lc`
5. Every `/etc/profile.d/*.sh` on the box passes `dash -n`
6. `herdr session list` shows a running default session
7. `systemctl --user is-active moshi-hook herdr-session`
8. `loginctl show-user dev -p Linger` reports `yes`
9. `/data` is a mountpoint and is writable by `dev`
10. Every state symlink resolves into `/data` and is owned by `dev`
11. `~/.ssh/authorized_keys` exists, is non-empty, mode 600
12. `sudo -n true` succeeds inside a pty
13. `docker info` exits 0 and `dev` is in the docker group
14. `/proc/cpuinfo` advertises avx2
15. ufw is active and UDP 60000-61000 is allowed
16. `~/.zshrc` contains the managed marker and no `promptinit` or
    `prompt adam1`, and starship is the active prompt
17. `sudo devbox-bootstrap` re-runs clean end to end, exit 0 (idempotency)

Additionally, `shellcheck -S warning` and `bash -n` over every shell file in
the repo, run locally before anything is pushed.

## 8. Cutover sequence

1. Write and lint everything locally. Nothing touches charon yet.
2. `devbox.sh salvage 104`. Verify the ~8.2 MB landed in
   `/srv/devdata/state/` with the right ownership.
3. Destroy VM 104 and template 9000.
4. `devbox.sh template`
5. `devbox.sh create`
6. `scripts/smoke-test.sh`
7. `sudo tailscale up`. Confirm `claude` and `gh` are already authenticated
   from the salvaged state, which is the first real proof the model works.
8. `devbox.sh rebuild`, then re-run the smoke tests. The persistence claim is
   worth proving before it is relied on.

## 9. Non-goals

- Multiple concurrent boxes. `create` is single-box by design.
- The MOTD banner and the apt-status timer. Under this model most of the
  banner's checklist disappears because the state it tracked now persists.
- Backups beyond the `work-snapshots` tarballs. `/srv/devdata` is a plain
  host directory, so any host-side rsync or borg job covers it, and that is
  out of scope here.
- Rootless Docker. Membership in the docker group is effectively root on the
  guest, which is an accepted trade inside a VM whose purpose is to be the
  boundary.

## 10. Risks to verify during implementation

- **virtiofs on PVE 8.4 with a trixie guest** is the least-trodden path in
  this design. Verify the dir mapping, the `--balloon 0` requirement, and the
  guest-side mount before building anything on top of it.
- **Docker's apt repo for trixie** must be confirmed to exist. If it does not,
  fall back to the bookworm suite with a comment, or to `docker.io` from
  Debian.
- **Tailscale's trixie repo path** likewise.
- ~~**charon's total RAM** against a 24 GB allocation.~~ RESOLVED during
  implementation: charon has 32017 MiB with 12290 MiB committed to VMs 206
  and 800. The 24576 default overcommitted by ~4.8 GB, so the default is now
  16384.
- **Bootstrap fetched from `main`** means a mid-edit push changes what a
  rebuild installs. Mitigated by the local copy at
  `/usr/local/sbin/devbox-bootstrap` and by `BOOTSTRAP_URL` accepting a tag or
  commit SHA, but worth pinning once the box is stable.
- **`/data` growth.** State is measured at 8.2 MB today and toolchains are
  deliberately excluded, but `~/.claude` grows with project history. `/data`
  shares charon's 66 GB root filesystem, so it is worth a size check during
  the cutover and a move to an LVM volume if it ever approaches a few GB.
- **Debian package name drift** from Ubuntu, particularly `btop`, `zoxide`,
  and `fd-find`, all of which should be confirmed present in trixie.
