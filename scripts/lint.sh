#!/usr/bin/env bash
# Local test command. Runs over every shell file in the repo.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
# --others --exclude-standard so new, unstaged files are linted too.
# Without them the gate skips the file you are currently writing.
mapfile -t files < <(git ls-files --cached --others --exclude-standard '*.sh')

for f in "${files[@]}"; do
  if ! bash -n "$f"; then
    echo "bash -n FAILED: $f" >&2
    fail=1
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  # -S warning: style suggestions are not gate failures.
  shellcheck -S warning "${files[@]}" || fail=1
elif [[ "${LINT_ALLOW_NO_SHELLCHECK:-0}" == "1" ]]; then
  echo "WARNING: shellcheck not installed, skipping (LINT_ALLOW_NO_SHELLCHECK=1)" >&2
else
  echo "ERROR: shellcheck not installed. Run 'brew install shellcheck', or set LINT_ALLOW_NO_SHELLCHECK=1 to skip." >&2
  fail=1
fi

# Files destined for /etc/profile.d must parse under dash: Debian sources
# profile.d for dash login shells too, and a bash-only construct there makes
# every 'sh -lc' probe exit 2.
if [[ -d profile.d ]]; then
  for f in profile.d/*.sh; do
    [[ -e "$f" ]] || continue
    if ! dash -n "$f"; then
      echo "dash -n FAILED: $f" >&2
      fail=1
    fi
  done
fi

[[ $fail -eq 0 ]] && echo "lint: clean"
exit "$fail"
