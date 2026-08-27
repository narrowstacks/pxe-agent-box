# AGENTS.md: pxe-agent-box

Guidance for AI agents working in this repository. Humans: the canonical
workflow doc is [README.md](README.md).

## What this repo is

Proxmox VE tooling that builds and maintains a single, persistent Linux dev
box for agent workflows. `devbox.sh` runs on the Proxmox host and drives the
whole lifecycle (verbs: `preflight`, `salvage`, `template`, `render`,
`create`, `rebuild`). `bootstrap.sh` runs inside the guest, is idempotent,
and converges the box into its final state on first boot and on every
re-run afterward. There is one box: VMID 104, named `devbox`, on Debian 13
(trixie).

## Helping a user work on the box

When a user asks about "the dev box", "devbox", or "the agent VM", they mean
the one persistent box, not a fleet. Common asks and what they map to:

- **"Build it for the first time"**: `./devbox.sh preflight` then
  `./devbox.sh template` then `./devbox.sh create`, from `/root/agent-box`
  on the Proxmox host. `create` also runs preflight itself.
- **"Rebuild it" / "give me a clean box"**: `./devbox.sh rebuild`. This
  destroys and recreates VMID 104. It refuses if `~/work` on the box has
  uncommitted changes, unpushed commits, non-git directories with contents,
  or loose files, and it snapshots `~/work` to `/data/work-snapshots` first.
  `/data` itself, and everything symlinked into it (auth, dotfiles, tool
  config), is never touched by a rebuild.
- **"Something's broken on the box, fix it"**: this almost always means
  editing `bootstrap.sh` and re-running it inside the guest, NOT rebuilding
  the VM. See the next section.

### `bootstrap.sh` is iterated by scp-and-run, never by rebuilding the VM

`bootstrap.sh` is idempotent and safe to re-run at any time as
`sudo devbox-bootstrap`. The fast loop for a change to it is:

```sh
scp bootstrap.sh dev@<ip>:/tmp/bootstrap.sh
ssh dev@<ip> 'sudo install -m 0755 /tmp/bootstrap.sh /usr/local/sbin/devbox-bootstrap && sudo devbox-bootstrap'
```

Rebuilding the VM to test a one-line bootstrap edit is slow (a full
reprovision) and defeats the entire point of writing an idempotent script.
Reach for `./devbox.sh rebuild` only when you actually need a clean VM disk
(for example, testing that a fresh first boot converges correctly), not to
pick up a bootstrap edit.

After a change lands and is pushed, a live box can also pick it up with
`sudo devbox-bootstrap --update`, which re-fetches from `BOOTSTRAP_URL` and
re-execs.

### The four rules in `bootstrap.sh` are load-bearing

The top of `bootstrap.sh` states four rules, and every one of them exists
because of a real incident recorded in `HANDOFF-SIMPLIFICATION.md`:

1. One tool, one install tree, chosen by who updates it. No cross-tree
   symlinks or copies.
2. Every file written to `/etc/profile.d` must parse under dash.
3. `~/.zshrc` is managed and lives on `/data`. starship owns the prompt.
4. No `sudo -i` with multi-line arguments. No pipeline under `pipefail`
   whose producer outlives its consumer.

Do not "simplify" one of these away, collapse a workaround you don't
immediately recognize, or "clean up" a comment that looks unnecessarily
defensive, without reading `HANDOFF-SIMPLIFICATION.md` first. Each rule maps
to hours of live-fire debugging across full VM rebuilds; the fix usually
looks over-engineered in isolation and is not.

### Verifying a change

- `./scripts/lint.sh`: bash -n + shellcheck + dash -n over every shell file
  in the repo. Run before committing anything.
- `./tests/test-render.sh`: unit tests for cloud-init snippet rendering, no
  Proxmox host needed. Run after touching `devbox.sh` or
  `cloud-init/devbox.yaml.tpl`.
- `./scripts/smoke-test.sh <user@host>`: the gate for every change that
  touches guest state, run against a booted box. `SKIP_SLOW=1` skips the
  slow idempotency section (a full `devbox-bootstrap` re-run) for fast
  iteration; the full run (no `SKIP_SLOW`) is what actually proves
  idempotency and should not be skipped before calling a change done.

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
