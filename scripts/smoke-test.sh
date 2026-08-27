#!/usr/bin/env bash
#
# Run from the Mac against a booted box:  ./scripts/smoke-test.sh <host>
#
# Every assertion here corresponds to a real incident recorded in
# HANDOFF-SIMPLIFICATION.md. Adding one is cheaper than rediscovering the bug.
#
set -uo pipefail   # NOT -e: a failing assertion must not abort the suite

HOST="${1:?usage: smoke-test.sh <user@host>}"
pass=0; fail=0

check() {  # check <description> <exit-code>
  if [[ "$2" -eq 0 ]]; then
    printf '  \033[1;32mok\033[0m   %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1))
  fi
}

# Non-interactive SSH. Deliberately does NOT allocate a tty and does NOT
# source ~/.zshrc, which is exactly how scripts, scp and Moshi probe the box.
remote() { ssh -o BatchMode=yes "$HOST" "$@"; }

# Asserts a login-shell probe exits 0 AND writes nothing to stderr. Bash
# syntax in /etc/profile.d made 'sh -lc' emit a wall of errors and exit 2,
# which silently broke Moshi's moshi-hook detection.
remote_clean_stderr() {  # remote_clean_stderr <shell>
  local err
  err="$(ssh -o BatchMode=yes "$HOST" "$1 -lc 'true'" 2>&1 >/dev/null)"
  [[ -z "$err" ]] || { printf '    stderr was: %s\n' "$err" >&2; return 1; }
}

printf '\n\033[1;34m== boot and base ==\033[0m\n'

remote 'cloud-init status' 2>/dev/null | grep -q 'status: done'
check "cloud-init reports done" $?

remote 'mountpoint -q /data'
check "/data is a mountpoint" $?

remote 'touch /data/state/.probe && rm /data/state/.probe'
check "/data is writable by the admin user" $?

remote 'test "$(id -u)" -eq 1000'
check "admin user is uid 1000" $?

remote 'test -s ~/.ssh/authorized_keys && test "$(stat -c %a ~/.ssh/authorized_keys)" = "600"'
check "authorized_keys is non-empty and mode 600" $?

remote '! test -L ~/.ssh'
check "the admin user's .ssh is a real directory, not a symlink" $?

remote 'sudo -n true'
check "sudo is NOPASSWD" $?

remote 'grep -q avx2 /proc/cpuinfo'
check "guest CPU advertises avx2" $?

remote 'sudo ufw status | grep -q "^Status: active"'
check "ufw is active" $?

remote 'sudo ufw status | grep -q "60000:61000/udp"'
check "mosh UDP range is allowed" $?

printf '\n\033[1;34m== login shells ==\033[0m\n'

for sh in sh bash zsh; do
  remote "$sh -lc 'true'"
  check "$sh -lc exits 0" $?
  remote_clean_stderr "$sh"
  check "$sh -lc writes nothing to stderr" $?
done

remote 'for f in /etc/profile.d/*.sh; do dash -n "$f" || exit 1; done'
check "every /etc/profile.d file parses under dash" $?

printf '\n\033[1;34m== state persistence ==\033[0m\n'

for p in .claude .claude.json .config/gh .config/herdr .config/mise .gitconfig; do
  remote "test -L ~/$p && readlink -f ~/$p | grep -q '^/data/'"
  check "$p is a symlink into /data" $?
done

printf '\n\033[1;34m== root-tree tools ==\033[0m\n'

for b in docker gh claude google-chrome starship herdr moshi moshi-hook tailscale mosh rg fd bat jq; do
  remote "command -v $b >/dev/null"
  check "$b is on the non-interactive PATH" $?
done

remote 'docker info >/dev/null 2>&1'
check "docker daemon is reachable by the admin user" $?

remote 'id -nG | tr " " "\n" | grep -qx docker'
check "admin user is in the docker group" $?

# Every root-tree binary must be readable by dev without traversing /root.
for b in starship herdr moshi moshi-hook; do
  remote "test -x \"\$(command -v $b)\" && ! readlink -f \"\$(command -v $b)\" | grep -q '^/root/'"
  check "$b does not resolve into /root" $?
done

printf '\n\033[1;34m== shell configuration ==\033[0m\n'

remote 'grep -q "^# devbox-managed zshrc" ~/.zshrc'
# shellcheck disable=SC2088  # description text, not an executed path
check "~/.zshrc carries the managed marker" $?

remote '! grep -qE "promptinit|prompt adam1" ~/.zshrc'
# shellcheck disable=SC2088  # description text, not an executed path
check "~/.zshrc registers no competing prompt" $?

# grep -qv on its own succeeds on ANY non-matching line, including an
# empty one, so it alone would pass even if starship never initialised.
# Positive assertion first (starship IS the prompt), negative second
# (herdr's adam1 theme is NOT), so a genuinely broken prompt still fails.
remote 'zsh -ic "echo \$PROMPT" 2>/dev/null | grep -q starship'
check "starship owns the interactive prompt" $?

remote 'zsh -ic "echo \$PROMPT" 2>/dev/null | grep -qv adam'
check "no adam1 prompt theme is active" $?

remote 'test -L ~/.zshrc && readlink -f ~/.zshrc | grep -q "^/data/"'
# shellcheck disable=SC2088  # description text, not an executed path
check "~/.zshrc persists on /data" $?

# The gate that would have caught the .local/bin duplication between
# ~/.zshenv and ~/.zshrc: multiple PATH owners for the same entry silently
# stack instead of erroring, so nothing else in this suite would notice.
remote 'test "$(zsh -ic "echo \$PATH" 2>/dev/null | tr : "\n" | sort | uniq -d | wc -l)" -eq 0'
check "interactive PATH has no duplicate entries" $?

# Moved here from Task 10: these need the login-shell PATH that
# /etc/profile.d/15-devbox-mise-shims.sh creates, so they cannot pass until
# this task lands. Do NOT weaken them to a bare 'command -v' or a direct
# path: agents and Moshi invoke these from login shells, and a tool that
# only works by absolute path is a tool that does not work.
printf '\n\033[1;34m== user tree (mise) ==\033[0m\n'

for b in mise node npm bun pnpm python uv opencode codex pi tsx prettier eslint vitest; do
  remote "zsh -lc 'command -v $b' >/dev/null 2>&1"
  check "$b is on the admin user's login PATH" $?
done

remote 'test -O "$(zsh -lc "command -v opencode" 2>/dev/null)"'
check "opencode is owned by the admin user" $?

remote 'zsh -lc "opencode --version" >/dev/null 2>&1'
check "opencode runs (needs avx2 from x86-64-v3)" $?

# Issue #2 in the incident ledger, verbatim: "Non-interactive shells have a
# short PATH. Scripts, scp, and remote commands never source ~/.zshrc, so
# user-local bins are invisible." The zsh -lc checks above only prove the
# zsh path; agents, scripts, scp and remote-exec actually use bash or plain
# non-interactive shells, so those are the invocation styles that matter.
printf '\n\033[1;34m== non-interactive PATH (all shells) ==\033[0m\n'

for b in node bun opencode mise; do
  remote "bash -lc 'command -v $b' >/dev/null 2>&1"
  check "$b is on the login PATH under bash" $?
  remote "sh -lc 'command -v $b' >/dev/null 2>&1"
  check "$b is on the login PATH under dash/sh" $?
done

# The one case /etc/profile.d cannot reach: plain 'ssh host cmd' is
# non-interactive AND non-login, so no profile.d file runs. ~/.zshenv fixes
# this because zsh sources it unconditionally, for every invocation.
remote 'command -v node >/dev/null'
check "node resolves for a plain non-interactive ssh command" $?

printf '\n\033[1;34m== systemd user units ==\033[0m\n'

remote 'loginctl show-user "$(id -un)" -p Linger | grep -q "Linger=yes"'
check "linger is enabled" $?

for u in moshi-hook herdr-session; do
  remote "systemctl --user is-active $u.service >/dev/null"
  check "$u.service is active" $?
done

remote 'herdr session list 2>/dev/null | grep -q .'
check "herdr reports at least one session" $?

# moshi-hook state lives in ~/.config/moshi, NOT in ~/.moshi*. A previous
# check probed the wrong path and reported unpaired forever.
remote 'test -d ~/.config/moshi'
check "moshi state directory exists at ~/.config/moshi" $?

# Runs last because it is slow: a full re-convergence, not a single probe.
# Default is to run it. SKIP_SLOW is an opt-out for fast iteration, not an
# opt-in, because a check nobody runs by default is a check that silently
# stops existing.
if [[ "${SKIP_SLOW:-0}" != "1" ]]; then
  printf '\n\033[1;34m== idempotency ==\033[0m\n'
  # A qemu-ga restart once orphaned half a run and a second instance raced
  # dpkg locks, killing both. Re-running end to end must be a genuine no-op.
  remote 'sudo /usr/local/sbin/devbox-bootstrap >/tmp/rerun.log 2>&1'
  check "devbox-bootstrap re-runs clean end to end" $?

  # bootstrap.sh's fail() writes "ERROR:" behind a raw ANSI color escape
  # (printf '\033[1;31mERROR:...'), so a plain "^ERROR" anchor never matches
  # the bytes actually in the log; strip escapes first, then anchor.
  #
  # WARNING lines are deliberately NOT asserted to be zero. bootstrap.sh
  # warns and continues for a known list of optional tools (opencode, codex,
  # pi, pnpm, uv, chrome, moshi-hook, mise reshim, ...), and it retries those
  # installs unconditionally on every run, so a transient warning on a
  # re-run is not proof the re-run was non-idempotent. What is provable: the
  # run exited 0, and it logged nothing through the ERROR path. Warnings are
  # still surfaced below, uncounted, so a human can eyeball them.
  remote 'sed -E "s/\x1b\[[0-9;]*m//g" /tmp/rerun.log > /tmp/rerun.clean.log'

  # If the sed/redirect above silently failed, the clean log would be
  # missing or empty, and '! grep -q ...' against a missing file exits 2,
  # which the leading '!' flips into a false PASS: a missing log would read
  # as "no errors found". Assert the log exists and is non-empty first so
  # that failure mode fails loudly instead of passing quietly.
  remote 'test -s /tmp/rerun.clean.log'
  check "the re-run produced a readable log" $?

  remote '! grep -q "^ERROR:" /tmp/rerun.clean.log'
  check "the re-run logged no errors" $?

  # apt's own summary line is deterministic on a genuinely idempotent
  # re-run, unlike the ERROR/WARNING checks above. It proves nothing
  # actually changed, not merely that nothing complained. The docker,
  # tailscale, gh, claude-code and chrome installs below this line in
  # bootstrap.sh are each gated by 'command -v', so on a re-run only the
  # base 'apt-get install' at the top of the script runs apt at all, and
  # this line appears exactly once.
  remote 'grep -q "0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded." /tmp/rerun.clean.log'
  check "the re-run installed and upgraded nothing (apt reports no changes)" $?

  warnings="$(remote 'grep "^WARNING:" /tmp/rerun.clean.log' 2>/dev/null || true)"
  if [[ -n "$warnings" ]]; then
    printf '  \033[1;33minfo\033[0m re-run logged warnings (not a failure, optional tools only):\n'
    printf '    %s\n' "$warnings"
  fi
fi

printf '\n\033[1;34m== %d passed, %d failed ==\033[0m\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
