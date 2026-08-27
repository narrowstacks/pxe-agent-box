# Simplification handoff — pxe-agent-box

Audience: an agent tasked with **reducing provisioning complexity** in this
repo. Read this fully before touching code. Everything below was learned the
expensive way (live-fire debugging across multiple full VM rebuilds).

## System context

- Proxmox host `charon`; scripts run there from `/root/agent-box` (rsync'd
  from the Mac repo). Template VM 9000 (`agent-box-tmpl-noble`, Ubuntu 24.04).
- `scripts/create-vm.sh` clones 9000, generates a per-box cloud-init snippet
  (`local:snippets/<name>-<id>.yml`) containing **all** user-data, and boots.
- `cloud-init/provision.sh` runs once as root via `runcmd`. It installs
  everything, writes three systemd *user* units, seeds shell configs.
- First-test box: `first-test` (VMID 104), user `dev`, connected via
  Tailscale (`agent-box-first-test`) and LAN DHCP.
- All fixes below are committed on `main` (through `7852803` / pushed).

## Design tension to understand first

Two audiences share every box:

1. **Provisioner (root)** installs global CLIs.
2. **Agent/user (dev)** runs everything, self-updates some tools, and SSH
   clients (Moshi) probe the box using **login** and **non-interactive**
   shells.

Most bugs came from these worlds colliding: binaries installed into root-only
or user-only trees, PATH depending on shell type, and third-party installers
making their own assumptions. Any simplification should start by **picking one
install tree per tool based on who updates it** and eliminating the tree-hop
workarounds listed below.

## Issue ledger

Format: Symptom → Root cause → Workaround currently in place → Simplification path.

### Packaging / installation layer

1. **Third-party curl-pipe-sh installers are the #1 bug source.**
   - moshi-hook ignores `INSTALL_DIR` when the env var prefixes the curl side
     of a pipe; lands in `~/.local/bin` regardless (v0.3.7). Workaround: pass
     env to the `sh` side of the pipe + `install -m755` copies into
     `/usr/local/bin`.
   - herdr installer crashes with `HOME: parameter not set` when run via
     cloud-init/qemu-ga (no `$HOME`). Workaround: `export HOME="${HOME:-/root}"`.
   - starship installer prompts interactively (and its stdin IS the piped
     script — prompting breaks it); requires escalation for `/usr/local/bin`.
     Workaround: `--yes -b ~/.local/bin`.
   - **Path:** avoid curl-installers entirely where an alternative exists:
     claude-code already moved to Anthropic's signed apt repo; check whether
     starship/opencode/herdr publish debs or add stable upstream apt repos.
     One `apt` line beats five workarounds per tool.

2. **opencode npm meta-package misresolves platform deps** (`EBADPLATFORM`,
   wants musl on glibc — upstream bug, failed on multiple runs even with
   `--force`). Workaround: `npm i -g opencode-linux-x64` directly +
   manual symlink into `/usr/local/bin` (platform-scoped npm packages don't
   create bin links).
   **Path:** wrap in its own function with a version pin; or vendor a `.deb`.

3. **Default QEMU CPU (`qemu64`) lacks AVX; bun-based binaries segfault.**
   opencode crashed at startup until `-cpu x86-64-v3` was set (host Ryzen has
   AVX2). Now in `create-vm.sh`. **Path:** nothing to simplify; keep in mind
   for any new binary.

4. **claude native installer busy-loops (100% CPU, zero network, 12+ min) on
   headless guests** — twice. Moved to the apt repo (verify signing-key
   fingerprint `31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE` before registering;
   stable channel). **Keep** whichever method is currently in provision.sh,
   and never trust a downloaded key without fingerprint verification.

### Install-tree / permissions layer

1. **Root-tree ↔ user-tree hops caused cascading bugs:** herdr/moshi/uv
   landed in `/root/.local/bin` (mode-0700 home) and were symlinked into
   `/usr/local/bin` — dev could not traverse `/root`, so the "global" binaries
   were invisible to the actual user; one daemon was caught running a
   **deleted** binary inode; copies carried a stale uid-501 owner. Fixed piecemeal
   with `install -m755` copies and correct ownership.
   **Path:** this is THE simplification target. Rule:
   - Tools updated by the provisioner (herdr, moshi-hook, uv, starship,
     tmux…): install **directly** into `/usr/local/bin` (most installers accept
     a dir override — `HERDR_INSTALL_DIR=/usr/local/bin` does; others need the
     copy) — owned by root, exactly like distro packages.
   - Tools that self-update in place (bun upgrade, possibly claude if the
     native route returns): user-owned under `~dev/.local/bin`, which is fine
     because only dev runs them.
   Then delete the leftover symlink/copy compensations from provision.sh.

2. **Non-interactive shells have a short PATH.** Scripts, scp, and remote
   commands never source `~/.zshrc`, so user-local bins are invisible.
   Workarounds sprinkled everywhere (symlinks, PATH exports).
   **Path:** the rule above makes this mostly moot; anything genuinely
   user-owned must either be on PATH via `~/.profile` (read by login shells)
   or be invoked by absolute path.

### Shell-config layer (profile.d / .zshrc)

1. **Bash syntax in /etc/profile.d broke ALL non-bash login shells.** The
   welcome banner used `[[`, `compgen`, arithmetic ternaries; Ubuntu sources
   profile.d for dash too, so any `sh -lc` probe got a wall of errors and
   **exit 2 — which silently broke Moshi's moshi-hook detection**. Same class
   of bug: `zoxide.sh` evaluating bash-only output unconditionally.
   Workarounds: banner rewritten in POSIX sh with a non-interactive early
   return; zoxide guards on `${BASH_VERSION:-}` and zsh gets its own
   `zoxide.zsh`.
   **Path:** convention worth keeping: **every profile.d file must parse
   clean under dash**. Add a CI/lint step (`dash -n` over generated files)
   rather than trusting authors.

2. **zsh prompt wars: herdr's .zshrc template registers `prompt adam1`,
   whose precmd re-asserts the old prompt every render**, stomping starship
   regardless of load order — while one-shot `zsh -ic` probes looked fine,
   which made diagnosis miserable. Workaround: provision strips
   `promptinit/prompt adam1` lines whenever merging an existing `.zshrc`, and
   seeds a full replacement otherwise.
   **Path:** pick ONE prompt owner (starship) and own the file explicitly:
   provisioning should treat `~/.zshrc` as managed (with a
   "regenerate-on-change" marker file) rather than merge-by-sed.

3. **File race: herdr may create/replace `~/.zshrc`** after the seed. The
   merge path above is a patch; a deterministic ownership model (write ours,
   let herdr read settings from its config.toml) would remove it.

4. **Checking state used wrong locations:** banner probed `~/.moshi*` for
    pairing, but state lives in `~/.config/moshi/`. Generic lesson: verify
    against each tool's *actual* persisted state, not assumed dotfiles.

### Provisioning-script mechanics

 1. **`sudo -i` joins arguments with spaces and re-parses them**, destroying
    quoting/newlines: multi-line `sudo -iu dev bash -lc '<script>'` became
    garbage. Workaround pattern now used consistently:
    `sudo -iu "$USER" bash -s <<'EOF' … EOF` (stdin passes verbatim).
    **Path:** keep this pattern; grep for any remaining `bash -lc` in
    provision.sh and convert.

 2. **Unquoted heredocs execute their content**: the cloud-init snippet
    heredoc ran `$(qm set --sshkeys)` from a *comment* line at build time.
    **Path:** prefer quoted heredocs + explicit `envsubst`-style expansion, or
    generate YAML programmatically (python/yq) instead of shell string surgery.

 3. **`yes | ufw enable` killed provisioning** under `set -o pipefail`
    (SIGPIPE 141 after ufw closes stdin) right after enabling the firewall —
    silent, late-stage failure. Use `ufw --force enable`. Generic rule: **no
    pipeline whose producer outlives the consumer** under pipefail.

 4. **Serial-console mirroring via runcmd's `bash | tee /dev/ttyS0` failed
    cloud-init** when tee hit EIO (serial-getty owns the tty) — exit status of
    the pipeline is tee's, not the script's. Workaround: mirror inside
    provision.sh with `exec > >(tee /dev/ttyS0) 2>&1` guarded on writability.
    **Path:** keep; alternatively drop serial mirroring entirely and rely on
    the structured log + marker.

 5. **pip on noble cannot uninstall distro packages lacking RECORD metadata**
    (`typing_extensions` aborted a whole run). `--ignore-installed` added.
    Banner originally counted ~45 *distro* python packages as "outdated pip"
    noise; now counts only the admin user's `--user` env. Correct hint text:
    `pip3 install --user --break-system-packages -U <name>`.

 6. **Idempotency is mandatory** — proved necessary when a qemu-ga restart
    orphaned half a run and a second instance raced dpkg locks (both died).
    Rules that emerged: never assume first-boot freshness; make
    `provision.sh` safe to re-run end-to-end; guard against concurrent
    instances with a lockfile (not pgrep -f, which self-matches its own
    command line — bit us too).

 7. **Remote-debug footguns** (cost hours): nested quoting through
    `qm guest exec`, seds applied to the Mac instead of the guest (worked
    "fine" on the wrong machine), background ssh wrappers dying without
    killing the guest-side job. **Path:** when fixing a running box, always
    push a small script file and execute it, never inline one-liners; kill
    guest processes explicitly via guest-exec, not by dropping transport.

### Upstream-format assumptions

 1. **bun release tags are `bun-vX.Y.Z`** — naive strip left `-v1.4.0` and the
    banner offered downgrading to a phantom version. Verify tag formats, don't
    guess. Similarly the preset/config TOML of herdr changes between versions
    (duplicate `[theme]` table incident: seeding appended a second table;
    fix uncomments the template keys in place).

## Conventions worth keeping (do not regress)

- Custom user-data replaces **all** PVE-generated cloud-init user-data:
  SSH keys MUST be embedded in the snippet under `users[].ssh_authorized_keys`;
  VM-level `qm set --sshkeys` is dead weight when `cicustom user=` is set.
- Guest networking goes through PVE's `--ipconfig0` (DHCP default).
- Cloud-init drive belongs on images-capable storage (`local-lvm`), and disk
  resize uses `qm disk resize <id> scsi0 <size>G` (legacy alias mangles args).
- One watchdog principle: every optional tool failure logs a WARNING and lets
  provisioning complete; the login banner + verification section surface gaps.
  But a failure in the core chain (apt/base) SHOULD fail loudly.
- The MOTD banner is the human interface: checklist of manual steps
  (tailscale up, gh auth login, claude login, moshi pairing) with live state;
  apt/npm/pip/bun update counts refreshed by a 12h timer — never scanned at
  login.

## Smoke-test suite to build (highest leverage)

`scripts/smoke-test.sh <vmid>` run from the Mac/CI after any provision or
template rebuild. Each item maps to a bug that escaped today:

```text
as dev over plain ssh (non-interactive):
  command -v {claude,opencode,pi,codex,bun,node,pnpm,uv,starship,herdr,moshi-hook,tailscale,docker}
  herdr session list --json | jq '.sessions[] |= select(.running)' is non-empty
as dev via LOGIN shell probe exactly like Moshi: sh -lc '<same checks>'; assert exit 0 AND no stderr
interactive pty: banner renders identically under dash/bash/zsh (golden-output diff)
sudo NOPASSWD works inside a pty
systemctl --user: moshi-hook + herdr-session active; linger enabled
agent-box-apt-status.timer enabled; /var/lib/agent-box/apt-status age < 24h
authorized_keys exists, non-empty, perms 600
cloud-init status == done; provisioned-at stamp < uptime
gh/cargo-esque outbound reachability: curl api endpoints 200
provision.sh re-runs cleanly back-to-back (idempotency gate)
shellcheck + dash -n over every profile.d file produced
```

~15 assertions, seconds to run, and every one corresponds to a real incident
above. Gate template rebuilds and provision.sh changes on it.

## Suggested simplification order (smallest risk first)

1. Add the smoke-test suite (pure addition; immediately converts future
   debugging into green/red).
2. Consolidate install trees per the rule in #5; delete the copy/symlink
   compensations.
3. Replace remaining curl-installers with distro packages where feasible;
   isolate the unavoidable ones behind small pinned functions.
4. Convert profile.d generation to validated templates (dash -n gate) and
   take explicit ownership of `~/.zshrc` (#8/#9).
5. Introduce a lockfile + idempotency guarantees (#16) if not already
   straightened out during earlier passes.
