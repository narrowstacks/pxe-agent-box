# AGENTS.md: pxe-agent-box

Guidance for AI agents working in this repo. Humans: see [README.md](README.md).

**Read @docs/pitfalls.md before changing any script here.** It lists the forms
that look correct and fail silently, and it is the difference between a change
that works and one that appears to.

## What this repo is

Proxmox VE tooling for a single persistent Linux dev box.

- **`devbox.sh`** runs on the Proxmox host and owns the VM lifecycle. Verbs:
  `preflight`, `salvage`, `template`, `render`, `create`, `rebuild`.
- **`bootstrap.sh`** runs inside the guest, is idempotent, and converges the
  box on first boot and on every re-run afterward.
- One box, Debian 13 (trixie). Its id and name come from `VMID` and `VMNAME`
  in `config.sh`; nothing should assume a particular value.
- `/data` is a virtiofs volume backed by `DATA_HOST_DIR` on the host. Auth
  state, dotfiles and tool config live there and survive rebuilds. `~/work`
  lives on the VM disk and does not.

## Common requests

| Ask | What it means |
| --- | --- |
| "build it for the first time" | `./devbox.sh template` then `./devbox.sh create`, from `/root/agent-box` on the PVE host. `create` runs `preflight` itself. |
| "rebuild it" / "give me a clean box" | `./devbox.sh rebuild`. Destroys and recreates the box at `VMID`. `/data` is untouched. |
| "something's broken on the box" | Almost always an edit to `bootstrap.sh` re-run in place, **not** a rebuild. |

## Iterate on `bootstrap.sh` in place

`bootstrap.sh` is idempotent and re-runnable as `sudo devbox-bootstrap`:

```sh
scp bootstrap.sh dev@<ip>:/tmp/bootstrap.sh
ssh dev@<ip> 'sudo install -m 0755 /tmp/bootstrap.sh /usr/local/sbin/devbox-bootstrap && sudo devbox-bootstrap'
```

Rebuilding the VM to test a bootstrap edit is slow and defeats the point of an
idempotent script. Reach for `rebuild` only when you need a clean VM disk, for
example to confirm a fresh first boot converges. A live box picks up a pushed
change with `sudo devbox-bootstrap --update`.

## Verifying a change

Run these in order. All three must pass before a change is done.

```sh
./scripts/lint.sh                          # bash -n + shellcheck, every shell file
./tests/test-render.sh                     # cloud-init rendering, no PVE host needed
./scripts/smoke-test.sh dev@<ip>           # the gate: assertions against a booted box
```

`SKIP_SLOW=1` skips the idempotency section of the smoke suite for fast
iteration. The full run is what proves idempotency, so do not skip it before
calling a change done.

When you add an assertion, **make it fail on purpose first.** An assertion
that cannot fail makes every later "tests pass" meaningless. See section 1 of
@docs/pitfalls.md.

## Conventions

- Scripts run as root on the PVE host. Editing and syntax-checking on a Mac is
  fine; execution is not.
- bash with `set -euo pipefail`, lowercase functions, failure messages through
  the existing `log`/`warn`/`fail` helpers.
- No em dashes anywhere, including comments and docs.
- `config.sh` is machine-local and gitignored. `config.example.sh` is the
  committed reference. Keep both lint-clean.
- PVE compatibility quirks are commented inline at their call site. A comment
  that looks unnecessarily defensive usually is not; check @docs/pitfalls.md
  before removing one.
- `bootstrap.sh` states four rules at the top. They are load-bearing and each
  is explained in @docs/pitfalls.md. Do not simplify one away without reading
  it first.
