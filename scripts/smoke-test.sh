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

printf '\n\033[1;34m== %d passed, %d failed ==\033[0m\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
