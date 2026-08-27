#!/usr/bin/env bash
# Unit tests for cloud-init snippet rendering. Runs on the Mac, no PVE needed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

pass=0; fail=0
check() {  # check <description> <condition-exit-code>
  if [[ "$2" -eq 0 ]]; then
    printf '  \033[1;32mok\033[0m   %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1))
  fi
}

# Render against a fixture config so the test does not depend on config.sh.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/key1.pub" <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAATEST1 test@one
EOF
cat > "$tmp/key2.pub" <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAATEST2 test@two
EOF

# A fixture config, not environment overrides: devbox.sh sources its config
# file, which would clobber anything the caller exported.
cat > "$tmp/config.sh" <<EOF
VMNAME="testbox"
ADMIN_USER="dev"
GUEST_TIMEZONE="UTC"
DATA_MAP_ID="devdata"
BOOTSTRAP_URL="https://example.invalid/bootstrap.sh"
MISE_TOOLS="node@lts"
SWAP_SIZE_GB="8"
ENABLE_UFW="1"
EXTRA_APT_PACKAGES=""
SSH_KEY_FILES="$tmp/key1.pub $tmp/key2.pub"
# devbox.sh computes IMAGE_PATH from this at top level, unconditionally,
# before verb dispatch. render doesn't use it, but the fixture must still
# define it or 'set -u' fails the script before it ever reaches the case.
CLOUD_IMAGE_URL="https://example.invalid/debian.qcow2"
EOF

out="$(DEVBOX_CONFIG="$tmp/config.sh" ./devbox.sh render)"

printf '%s\n' "$out" > "$tmp/rendered.yaml"

python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$tmp/rendered.yaml" 2>/dev/null
check "renders valid YAML" $?

grep -q '^#cloud-config' "$tmp/rendered.yaml"
check "starts with the #cloud-config header" $?

# Omitting '- default' frees uid 1000 from Debian's built-in user. This is
# load-bearing: stable uid 1000 keeps /srv/devdata ownership correct forever.
! grep -qE '^\s+- default\s*$' "$tmp/rendered.yaml"
check "omits '- default' from users" $?

grep -q 'uid: 1000' "$tmp/rendered.yaml"
check "pins the admin user to uid 1000" $?

grep -q 'TEST1' "$tmp/rendered.yaml" && grep -q 'TEST2' "$tmp/rendered.yaml"
check "embeds every SSH key" $?

grep -q 'virtiofs' "$tmp/rendered.yaml" && grep -q '/data' "$tmp/rendered.yaml"
check "mounts /data over virtiofs" $?

grep -q 'TS_STATE_DIR=/data/state/tailscale' "$tmp/rendered.yaml"
check "sets the tailscaled state dir override" $?

# No Tailscale auth key belongs in a snippet. State on /data means tailscaled
# comes back authenticated after a rebuild without one.
! grep -q 'tskey-' "$tmp/rendered.yaml"
check "contains no tailscale auth key" $?

! grep -qE 'fs_setup|disk_setup' "$tmp/rendered.yaml"
check "contains no fs_setup or disk_setup" $?

grep -q 'path: /etc/devbox.env' "$tmp/rendered.yaml" && grep -q 'MISE_TOOLS="node@lts"' "$tmp/rendered.yaml"
check "renders /etc/devbox.env carrying host config into the guest" $?

! grep -qE '@[A-Z_]+@' "$tmp/rendered.yaml"
check "leaves no unsubstituted placeholders" $?

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
