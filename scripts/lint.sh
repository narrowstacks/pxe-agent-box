#!/usr/bin/env bash
# Local test command. Runs over every shell file in the repo.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
# --others --exclude-standard also lists NEW files that are not yet
# staged. Without them the gate silently skips the file you are
# currently writing and reports clean, which is how a lint failure
# shipped in a commit that claimed lint passed.
mapfile -t files < <(git ls-files --cached --others --exclude-standard '*.sh')

for f in "${files[@]}"; do
  if ! bash -n "$f"; then
    echo "bash -n FAILED: $f" >&2
    fail=1
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  # config.sh files are sourced, not executed; tell shellcheck so.
  shellcheck -S warning "${files[@]}" || fail=1
elif [[ "${LINT_ALLOW_NO_SHELLCHECK:-0}" == "1" ]]; then
  echo "WARNING: shellcheck not installed, skipping (LINT_ALLOW_NO_SHELLCHECK=1)" >&2
else
  echo "ERROR: shellcheck not installed. Run 'brew install shellcheck', or set LINT_ALLOW_NO_SHELLCHECK=1 to skip." >&2
  fail=1
fi

# Every file destined for /etc/profile.d must parse under dash, because
# Debian sources profile.d for dash login shells too. A bash-only construct
# there makes 'sh -lc' exit 2 and silently breaks Moshi's hook detection.
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
