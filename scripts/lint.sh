#!/usr/bin/env bash
# Local test command. Runs over every shell file in the repo.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
mapfile -t files < <(git ls-files '*.sh')

for f in "${files[@]}"; do
  if ! bash -n "$f"; then
    echo "bash -n FAILED: $f" >&2
    fail=1
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  # config.sh files are sourced, not executed; tell shellcheck so.
  shellcheck -S warning "${files[@]}" || fail=1
else
  echo "WARNING: shellcheck not installed (brew install shellcheck)" >&2
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
