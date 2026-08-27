# AGENTS.md — pxe-agent-box

Guidance for AI agents working in this repository. Humans: the canonical
workflow doc is [README.md](README.md).

## What this repo is

Proxmox VE tooling that turns a stock Proxmox host into a source of disposable,
fully-provisioned Linux dev boxes for agent workflows. `build-template.sh`
creates one Ubuntu 24.04 cloud-init template; `create-vm.sh` clones it into
sized boxes with SSH keys baked in; `cloud-init/provision.sh` installs the
actual software inside each box on first boot.

## Helping a user initialize a new VM

When a user asks you to create a dev box ("spin up a box", "new agent VM",
"set up first-test"), walk them through this checklist. Ask before assuming —
every question below has bitten someone.

### 1. Gather what you must know (ask, don't guess)

1. **PXE/PVE node name or IP** — which Proxmox host? (`ssh root@<host>` must
   work from here; verify with a quick `ssh root@<host> pveversion`.)
2. **Are your keys already on that host?** Check whether the user's public
   keys exist on the PVE host:

   ```sh
   ssh root@<host> 'ls /root/.ssh/*.pub'
   ```

   If missing, offer to copy them (`scp ~/.ssh/id_ed25519.pub root@<host>:/root/.ssh/`)
   and ask **which keys** they want — see the key-preferences question below.
3. **SSH key preference** — which public keys should be baked into boxes?
   - Ask if they have multiple: main laptop key, phone/tablet key, etc.
   - Recommend *excluding* git-signing-only keys.
4. **Sizing** — cores/RAM/disk for the workload. Defaults are 4c/8GB/80GB;
   recommend more RAM (16–32 GB) and disk for heavy Chrome or Docker use.
5. **Package preferences** — `config.sh` knobs to tune, with recommendations:
   - `EXTRA_APT_PACKAGES`: suggest `postgresql-client redis-tools ffmpeg` only
     if their projects touch those services.
   - `NPM_GLOBALS`: defaults (typescript tsx @types/node prettier eslint vitest
     concurrently http-server) fit most TS work — ask about extras like
     `drizzle-kit prisma turbo nx`.
   - `PIP_PACKAGES`: defaults cover most scripting; add project-specific ones.
6. **Static IP vs DHCP** — DHCP default; ask only if their network has IP
   bookkeeping needs (`STATIC_IP` + `GATEWAY` in config.sh).

### 2. Verify prerequisites before running anything

- `/root/.ssh/<chosen>.pub` exists on the host for every chosen key
- `pvesm status` shows `STORAGE` (default `local-lvm`) active with space
- VMID conflicts: `qm list`; template existence: `qm status $TEMPLATE_ID`

### 3. Run the flow

```sh
# on the Mac (one-time per change):
rsync -av --delete --exclude .pi ./ root@<host>:/root/agent-box/
scp config.sh root@<host>:/root/agent-box/config.sh  # keep local copy out of repo sync

# on the host:
/root/agent-box/scripts/create-vm.sh -n <name> [-i <vmid>] [-c N] [-m N] [-d N]
```

The script prints the guest IP when the agent reports it. Provisioning then
runs ~5–10 min inside the guest — watch with:

```sh
ssh root@<host> 'qm guest exec <vmid> -- tail -f /var/log/cloud-init-output.log'
```

### 4. Report back to the user

Give them: VMID, name, IP, how to connect (`ssh dev@<ip>`, or Moshi on the
phone), and the one-time account setup list (tailscale up, gh auth login,
claude login, moshi-hook pair) from README.md.

## Repo conventions

- Scripts run as root on the PVE host (Debian); local Mac-side is fine for
  editing/testing syntax but not for execution.
- Shell style: bash with `set -euo pipefail`, functions lowercase, explicit
  failure messages via the existing `log`/`fail` helpers.
- Every PVE-8.x compatibility quirk we hit is documented inline at its call
  site (`--import-from`, `qm disk resize`, cloud-init drive placement).
- `config.sh` is machine-local and gitignored; `config.example.sh` is the
  committed reference. Keep both lint-clean (`shellcheck -S warning`).
- Validate shell changes with `bash -n` + `shellcheck -S warning` before
  committing; test flag logic locally by simulating, not by burning VM builds.
