#cloud-config
#
# Rendered by devbox.sh; do not edit the installed copy under snippets/.
#
# Deliberately thin: create the account, mount /data, hand off to
# bootstrap.sh. Everything else is convergence, and convergence belongs in a
# script that can be re-run.

hostname: @VMNAME@
preserve_hostname: false
timezone: @GUEST_TIMEZONE@

# No "- default" entry, deliberately: omitting it skips the image's built-in
# 'debian' user and frees uid 1000 for the admin user. Stable uid 1000 is
# what keeps /data ownership correct across rebuilds. Do not add it back.
users:
  - name: @ADMIN_USER@
    uid: 1000
    groups: [sudo]
    shell: /usr/bin/zsh
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
@SSH_KEYS@

package_update: true

# Only what is needed to reach bootstrap.sh. bootstrap installs the rest,
# so this list stays short and the two never drift.
packages:
  - curl
  - ca-certificates
  - zsh
  - qemu-guest-agent

# The persistent state volume: a Proxmox directory mapping over virtiofs.
# The mounts module runs at config stage, before runcmd at final stage, so
# /data is mounted by the time bootstrap runs.
mounts:
  - [ "@DATA_MAP_ID@", "/data", "virtiofs", "defaults,nofail", "0", "0" ]

write_files:
  # The ONLY channel carrying host config.sh values into the guest.
  # bootstrap.sh is curl'd standalone from GitHub and has no other way to
  # learn them, so without this file every knob silently takes its default.
  - path: /etc/devbox.env
    permissions: "0644"
    content: |
      DEV_USER="@ADMIN_USER@"
      MISE_TOOLS="@MISE_TOOLS@"
      SWAP_SIZE_GB="@SWAP_SIZE_GB@"
      ENABLE_UFW="@ENABLE_UFW@"
      EXTRA_APT_PACKAGES="@EXTRA_APT_PACKAGES@"
      BOOTSTRAP_URL="@BOOTSTRAP_URL@"

# Nothing here persists Tailscale's node identity. bootstrap.sh does it, by
# overriding tailscaled's ExecStart to point --state at /data; a TS_STATE_DIR
# drop-in here would be a no-op (see bootstrap.sh for why).

runcmd:
  - systemctl enable --now qemu-guest-agent
  - mkdir -p /data/state /data/work-snapshots
  - chown 1000:1000 /data/state /data/work-snapshots
  - curl -fsSL "@BOOTSTRAP_URL@" -o /usr/local/sbin/devbox-bootstrap
  - chmod 0755 /usr/local/sbin/devbox-bootstrap
  - /usr/local/sbin/devbox-bootstrap

final_message: "devbox base ready after $UPTIME seconds; bootstrap log in /var/log/cloud-init-output.log"
