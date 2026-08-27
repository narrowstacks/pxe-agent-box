#!/usr/bin/env bash
#
# Run from the Mac against a booted box:  ./scripts/smoke-test.sh <host>
#
# Each assertion guards a specific failure mode described in docs/pitfalls.md.
# Adding one is cheap; keeping a useless one is not. Before trusting a new
# assertion, break what it checks and confirm it reports FAIL.
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

# Asserts a login-shell probe exits 0 and writes nothing to stderr. Bash
# syntax in /etc/profile.d makes 'sh -lc' emit errors and exit 2, which
# breaks anything that probes the box that way.
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

# Every state link bootstrap.sh creates under $DEV_HOME; ~/.zshrc is
# asserted separately below. 'readlink -f | grep' alone passes on a broken
# symlink, so test -e proves the target exists and test -O proves the admin
# user owns it.
for p in .claude .claude.json .config/gh .config/herdr .config/moshi .config/opencode .config/mise .codex .pi .zsh_history.d .gitconfig .ssh/known_hosts .zshenv; do
  remote "test -L ~/$p && readlink -f ~/$p | grep -q '^/data/' && test -e ~/$p && test -O ~/$p"
  check "$p is a symlink into /data, target exists and is owned by the admin user" $?
done

# An empty ~/.claude.json is not a harmless placeholder: claude parses it on
# startup, reports "JSON Parse error: Unexpected EOF", backs the file up as
# corrupted and refuses to run. jq -e exits non-zero on an empty file and on
# a truncated one.
remote 'jq -e . ~/.claude.json >/dev/null'
check ".claude.json holds parseable JSON, not an empty placeholder" $?

# tailscaled's identity is root-owned and outside /home, so it is checked
# separately. bootstrap.sh persists it by overriding ExecStart's --state
# flag, so assert the effective flag systemd would run, not just a file on
# disk that nothing may read from.
remote 'systemctl show tailscaled -p ExecStart --no-pager | grep -q -- "--state=/data/"'
check "tailscaled's effective --state flag resolves under /data (survives a rebuild)" $?

remote 'sudo test -e /data/state/tailscale/tailscaled.state'
check "tailscaled's state file exists under /data" $?

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

# Anchored to the start of a line: the generated zshrc explains in a comment
# that it registers no prompt, and an unanchored grep matches that comment.
remote '! grep -qE "^[[:space:]]*(autoload .*promptinit|promptinit|prompt [a-z])" ~/.zshrc'
# shellcheck disable=SC2088  # description text, not an executed path
check "~/.zshrc registers no competing prompt" $?

# Positive assertion first, then the negative. 'grep -qv adam' on its own
# succeeds on any non-matching line, including the empty one a broken
# prompt produces.
remote 'zsh -ic "echo \$PROMPT" 2>/dev/null | grep -q starship'
check "starship owns the interactive prompt" $?

remote 'zsh -ic "echo \$PROMPT" 2>/dev/null | grep -qv adam'
check "no adam1 prompt theme is active" $?

remote 'test -L ~/.zshrc && readlink -f ~/.zshrc | grep -q "^/data/"'
# shellcheck disable=SC2088  # description text, not an executed path
check "~/.zshrc persists on /data" $?

# Two owners for one PATH entry stack silently instead of erroring, so
# nothing else in this suite would notice.
remote 'test "$(zsh -ic "echo \$PATH" 2>/dev/null | tr : "\n" | sort | uniq -d | wc -l)" -eq 0'
check "interactive PATH has no duplicate entries" $?

# These need the login-shell PATH that 15-devbox-mise-shims.sh creates. Do
# not weaken them to a bare 'command -v' or an absolute path: agents and
# Moshi invoke these from login shells, and a tool that only works by full
# path does not work.
printf '\n\033[1;34m== user tree (mise) ==\033[0m\n'

for b in mise node npm bun pnpm python uv opencode codex pi tsx prettier eslint vitest; do
  remote "zsh -lc 'command -v $b' >/dev/null 2>&1"
  check "$b is on the admin user's login PATH" $?
done

remote 'test -O "$(zsh -lc "command -v opencode" 2>/dev/null)"'
check "opencode is owned by the admin user" $?

remote 'zsh -lc "opencode --version" >/dev/null 2>&1'
check "opencode runs (needs avx2 from x86-64-v3)" $?

# The zsh -lc checks above only prove the zsh path. Agents, scripts and scp
# use bash or a plain non-interactive shell, which never source ~/.zshrc, so
# those invocation styles need asserting too.
printf '\n\033[1;34m== non-interactive PATH (all shells) ==\033[0m\n'

for b in node bun opencode mise; do
  remote "bash -lc 'command -v $b' >/dev/null 2>&1"
  check "$b is on the login PATH under bash" $?
  remote "sh -lc 'command -v $b' >/dev/null 2>&1"
  check "$b is on the login PATH under dash/sh" $?
done

# The one case /etc/profile.d cannot reach: 'ssh host cmd' is neither login
# nor interactive. ~/.zshenv covers it; zsh sources it on every invocation.
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

# moshi-hook state lives in ~/.config/moshi, not ~/.moshi*.
remote 'test -d ~/.config/moshi'
check "moshi state directory exists at ~/.config/moshi" $?

# Last because it is slow: a full re-convergence, not a single probe.
# SKIP_SLOW is an opt-out for fast iteration, never an opt-in: a check
# nobody runs by default is a check that silently stops existing.
if [[ "${SKIP_SLOW:-0}" != "1" ]]; then
  printf '\n\033[1;34m== idempotency ==\033[0m\n'
  # Re-running end to end must be a genuine no-op.
  remote 'sudo /usr/local/sbin/devbox-bootstrap >/tmp/rerun.log 2>&1'
  check "devbox-bootstrap re-runs clean end to end" $?

  # fail() writes "ERROR:" behind an ANSI escape, so a "^ERROR" anchor never
  # matches the bytes in the log. Strip escapes first, then anchor.
  #
  # WARNING lines are deliberately not asserted to be zero: bootstrap.sh
  # retries every optional tool on each run, so a transient warning is not
  # proof of non-idempotency. They are surfaced uncounted below instead.
  remote 'sed -E "s/\x1b\[[0-9;]*m//g" /tmp/rerun.log > /tmp/rerun.clean.log'

  # '! grep -q' against a missing file exits 2, which the '!' flips into a
  # false PASS reading as "no errors found". Assert the log exists first so
  # a failed sed above fails loudly instead.
  remote 'test -s /tmp/rerun.clean.log'
  check "the re-run produced a readable log" $?

  remote '! grep -q "^ERROR:" /tmp/rerun.clean.log'
  check "the re-run logged no errors" $?

  # Unlike the checks above, apt's summary proves nothing changed rather
  # than that nothing complained. Every later install in bootstrap.sh is
  # gated by 'command -v', so a re-run runs apt once, at the top.
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
