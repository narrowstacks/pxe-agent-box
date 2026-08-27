# Pitfalls

Rules for working on this repo. Each one exists because the obvious form is
wrong in a way that stays silent. Follow the "do this" form; the "not this"
form is what looks correct and isn't.

---

## 1. A check that cannot fail is worse than no check

Every gate in this repo (`lint.sh`, `preflight.sh`, `smoke-test.sh`, the
`dash -n` validator, the idempotency assertion) is a claim that something
was verified. If the gate can report success without actually testing its
condition, every downstream "tests pass" becomes meaningless.

**Before you trust a new assertion, make it fail on purpose.** Break the
thing it checks, confirm it reports FAIL, then restore. If you cannot make
it fail, it is not a check.

Specific forms that silently always pass:

| Not this | Why it can't fail | Do this |
| --- | --- | --- |
| `grep -q '^ERROR' log` | `log()`/`fail()` emit an ANSI colour escape first, so the first byte is `ESC`, not `E` | strip escapes first: `sed -E 's/\x1b\[[0-9;]*m//g'` then grep |
| `git ls-files '*.sh'` | lists **tracked** files only; a new file you are writing is invisible | `git ls-files --cached --others --exclude-standard '*.sh'` |
| `curl -fsSI "$url"` | `-f` only catches 4xx/5xx, so a 3xx passes without following it; some hosts reject HEAD outright | `curl -fsSL -o /dev/null "$url"` (and `-r 0-0` for large files) |
| `grep -qv adam` | succeeds on any line without that string, including an empty one | assert positively: `grep -q starship` |
| `test -L "$p"` alone | passes on a symlink whose target does not exist | add `test -e "$p"` and `test -O "$p"` |
| `readlink -f "$p" \| grep '^/data/'` | resolves and matches even when the target is missing | pair with `test -e` |

---

## 2. Shell forms that fail silently

**A function whose last statement is a false conditional returns non-zero,
and `set -e` kills the caller with no message.**

```sh
# Not this: returns 1 when the array is empty, killing the caller silently
for f in "${old[@]:-}"; do [[ -n "$f" ]] && rm -f "$f"; done

# Do this: declare the array, drop the :- that synthesises an empty element,
# and end the function with an explicit return
local old=()
mapfile -t old < <(ls -1t "$dir"/*.tar.zst 2>/dev/null | tail -n +4)
for f in "${old[@]}"; do rm -f "$f"; done
return 0
```

When a script stops with no output, run it under `bash -x`. Reasoning about
where it stopped is slower and usually wrong.

**Other forms to avoid:**

- `"${arr[@]:-}"` synthesises a single empty element on an empty array. Use
  `local arr=()` and `"${arr[@]}"`.
- `sudo -i` joins its arguments with spaces and re-parses them, destroying
  quoting and newlines. Pass scripts on stdin: `sudo -iu "$user" bash -s <<'EOF'`.
- No pipeline under `pipefail` whose producer outlives its consumer.
  `yes | ufw enable` dies on SIGPIPE; use `ufw --force enable`.
- Guard concurrent runs with `flock`, never `pgrep -f`, which matches its own
  command line and always finds itself.
- Unquoted heredocs (`<<EOF`) expand `$(...)` in their body, including inside
  comments. Use `<<'EOF'` and substitute explicitly unless you specifically
  want expansion.
- `[[ ... ]]` is valid `dash` syntax, so it will not trip `dash -n`. To test
  that validator, use something dash genuinely rejects, such as an array
  literal `arr=(1 2 3)`.
- zsh does not word-split unquoted parameters. A loop like
  `for c in "cmd -a" "cmd -b"; do $c ...; done` runs a command literally named
  `cmd -a` under zsh. Use arrays or explicit invocations.

---

## 3. Never delete a source before the copy is proven

Any move-then-delete over `/data` must abort rather than lose the only copy.
virtiofs can fail a copy that would succeed locally (xattrs, special files).

```sh
# Do this
cp -a "$dst/." "$src/" || fail "could not copy $dst into $src; refusing to delete the original"
rm -rf "$dst"

# Not this: discards both the error output and the exit status, then deletes anyway
cp -a "$dst/." "$src/" 2>/dev/null || true
rm -rf "$dst"
```

Downloads follow the same rule. Write to a temporary name and rename on
success, so a partial file never occupies the final path where an existence
check would accept it as valid.

---

## 4. virtiofs `/data` serves stale content to the guest

The mount uses `cache=always`. The guest caches file **content** and does not
revalidate. A brand-new path the host writes is seen correctly, but
**overwriting a path the guest has already cached returns the old content.**

- Give every host-written helper script a unique per-invocation name (PID plus
  timestamp). Do not reuse a fixed path, even though a fixed name looks tidier.
- Do not assume the guest sees a host edit to an existing file.
- `systemd`'s `StateDirectory=` cannot chase a symlink across virtiofs; it
  fails with "Too many levels of symbolic links". Point a unit at `/data` by
  overriding its `ExecStart` path, not by symlinking its state directory.

---

## 5. The Proxmox host cannot SSH into the guest

`/root/.ssh` on the PVE host holds only the **public** keys baked into boxes.
There is no matching private key, so anything in `devbox.sh` that needs to
reach the guest must use `qm guest exec`, which needs no credentials.

When running a command in the guest, write the script to `$DATA_HOST_DIR`
(which is `/data` inside the guest) and execute it by path. Never inline a
multi-line one-liner through `qm guest exec`; nested quoting through that
interface is a reliable source of silent corruption.

`qm guest exec` runs as root. Anything touching the admin user's files must
run as that user (`su -s /bin/bash - "$ADMIN_USER" -c ...`), or git will
refuse the repos with a "dubious ownership" error and the check will report
failures that are not real.

---

## 6. Proxmox specifics that have no useful error message

- `--balloon 0` is **required** for virtiofs. PVE refuses the combination
  otherwise. This is not a tuning preference.
- `--cpu x86-64-v3` belongs on the **template**, so every clone inherits it.
  The PVE default (`qemu64`) lacks AVX2 and bun-based binaries segfault at
  startup with no useful message.
- Directory mappings live in `/etc/pve/mapping/directory.cfg`, and the format
  has no `dir:` section prefix. Do not hand-write it. Register through the API
  (`pvesh create /cluster/mapping/dir --id X --map node=Y,path=Z`) so PVE owns
  the format. Re-creating an existing id is an error, not a no-op, so check
  first with `pvesh get /cluster/mapping/dir`.
- The cloud-init drive must be on images-capable storage (`local-lvm`), not a
  directory store.
- Resize with `qm disk resize <id> scsi0 <size>G`. The legacy `qm resize` alias
  mangles its arguments.
- When `cicustom user=` is set, custom user-data replaces **all**
  PVE-generated user-data. SSH keys must be embedded in the snippet under
  `users[].ssh_authorized_keys`; `qm set --sshkeys` does nothing.
- Destroy with `--destroy-unreferenced-disks 0` so nothing outside the VM's
  own config is touched.

---

## 7. One tool, one install tree, chosen by who updates it

- Tools the provisioner updates go to apt, or directly into `/usr/local/bin`.
- Tools the user updates live under mise in the user tree.
- **No symlinks or copies between the two.** A binary installed into a
  mode-0700 `/root` and symlinked into `/usr/local/bin` is invisible to the
  only user who runs it.

Most installers accept a directory override, and environment variables must
ride the `sh` side of a pipe (`curl ... | VAR=x sh`), not the curl side.
Prefer a signed apt repo over a curl installer wherever upstream publishes
one, and verify a downloaded signing key's fingerprint before registering the
repo.

---

## 8. PATH and shell startup

**Debian's `/etc/zsh/zprofile` does not source `/etc/profile`**, so zsh login
shells never see `/etc/profile.d`. Anything zsh needs on PATH must be in
`~/.zshenv`, which zsh sources on every invocation including non-interactive
non-login (which is what `ssh host cmd` uses).

**Use mise shims for PATH, not `mise activate`.** `activate` is an
interactive-shell mechanism. Scripts, `scp`, and remote commands run
non-interactively and would see none of the user-tree tools. Put
`~/.local/share/mise/shims` on PATH from a POSIX `profile.d` file and from
`~/.zshenv`; keep `mise activate` in `~/.zshrc` for interactive sessions only.

**Run `mise reshim` after installing anything mise did not install itself.**
npm's mise wrapper reshims automatically; `pip install` does not, so a tool
installed that way exists but is unreachable.

**Every file written to `/etc/profile.d` must parse under `dash`.** Debian
sources them for dash login shells too, and a bash-only construct makes every
`sh -lc` probe exit non-zero, which breaks tooling that probes the box.
`bootstrap.sh` validates its own output with `dash -n` and aborts; keep that.

**One owner per PATH entry.** If `~/.zshenv` adds a directory, `~/.zshrc` must
not add it again. Assert the interactive PATH has no duplicates.

**starship is the sole prompt owner.** Do not add `promptinit` or any
`prompt <name>` line to the generated `~/.zshrc`; a theme's `precmd` will
re-assert itself on every render and win regardless of load order.

Test PATH changes against all four invocation styles, because they source
different files:

```sh
zsh -lc 'command -v node'    # login, non-interactive
bash -lc 'command -v node'
sh -lc 'command -v node'
ssh dev@<ip> 'command -v node'   # non-interactive, non-login
```

---

## 9. Managed files and idempotency

`bootstrap.sh` must be safe to re-run end to end at any time. Never assume
first-boot freshness.

Files the provisioner owns (`~/.zshrc`, `~/.zshenv`) carry a version marker in
their first line and are regenerated only when that marker changes. Bump the
marker when you change the content, or the stale file on `/data` will persist.

Do not merge into a managed file with `sed`. Own it outright. If a third-party
tool wants to write the same file, let it lose: because the file lives on
`/data`, that tool's first-run behaviour happens exactly once, ever, and never
again on any later rebuild.

Verify a tool's **actual** persisted state location rather than an assumed
dotfile path. Check where it really writes before asserting on it.

---

## 10. uid 1000 is load-bearing

The admin user is pinned to uid 1000 in cloud-init (which is why the `users:`
list omits `- default`, freeing the uid from Debian's built-in user), and
`/data` ownership depends on it. `bootstrap.sh` asserts it before any `chown`.
Do not add `- default` back, and do not remove that assertion.

---

## 11. systemd user units

`sudo -iu` does not establish a PAM login session, so `systemctl --user` has no
bus and fails with "Failed to connect to user scope bus". Export
`XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS`, and start
`user@<uid>.service` explicitly after enabling linger. That unit carries
`BindsTo=user-runtime-dir@%i.service`, so starting it materialises
`/run/user/<uid>` deterministically on a genuine first boot, with no login
required.

Do not accept `systemctl --user enable --now` exiting 0 as proof a unit works.
Check `is-active`, and check `NRestarts` to catch a unit that is crash-looping
behind `Restart=on-failure`.

A TUI that daemonizes still needs a tty. Wrapping with
`script -qec <cmd> /dev/null` and `Type=simple` is deliberate: the unit is the
session holder, so forking detection would time out.

---

## 12. Environment variables that do not do what their name suggests

Read the daemon's own unit before assuming an environment variable reaches it.

`TS_STATE_DIR` is read by tailscale's containerboot wrapper, not by
`tailscaled`. Debian's unit passes an explicit `--state=...` on the command
line, which wins over anything in the environment. Persisting tailscaled state
means overriding `ExecStart` (clear it with an empty `ExecStart=` first, then
restate the full command). That duplicates upstream's command line, so a
tailscale package update that changes `ExecStart` needs a matching update here.

---

## 13. Failure policy

- **Core chain fails loudly and aborts**: base packages, Docker, user creation,
  the `/data` mount and its state links.
- **Optional tools warn and continue**: agent CLIs, Chrome, herdr, moshi-hook.
  A single optional tool failing must not prevent the rest of the box from
  converging.

Do not convert an optional failure into a hard abort, and do not silence a
core failure into a warning.

---

## 14. Working on a live box

- Deploy before you test. Running a host-side script from a stale copy tests
  the wrong code and can do real damage.
- Prefer editing `bootstrap.sh` and re-running it in place over rebuilding the
  VM. Rebuild only when you specifically need a clean VM disk.
- A rebuilt VM gets a new SSH host key, and DHCP may hand it an address you
  have seen before. Clear stale `known_hosts` entries rather than disabling
  host key checking.
- `DRYRUN=1` prints every mutating command in `devbox.sh` instead of running
  it. Use it before anything destructive.
- Iterate with `SKIP_SLOW=1 ./scripts/smoke-test.sh dev@<ip>`, but run the full
  suite before calling a change done. The slow section is the idempotency
  gate, and it is the part that proves a re-run changes nothing.

---

## 15. Verify upstream formats, do not guess

Release tags, config file schemas and installer flags change. Check the actual
value before parsing or matching it. When asserting on a command's output,
paste the real output into the assertion rather than the format you expect.
