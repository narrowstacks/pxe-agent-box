# agent-box configuration
#
# Copy to config.sh and edit before running anything. All scripts source this
# file and are meant to run ON the Proxmox VE host (or wherever qm/pvesm are
# available).
#
# Every variable here is consumed by scripts/*.sh, not in this file.
# shellcheck shell=bash disable=SC2034

##### Proxmox infrastructure #####

# Storage where the template's disk lives (and clones inherit from)
STORAGE="local-lvm"

# Storage that accepts snippet content (where generated cloud-init user-data goes).
# The built-in "local" directory storage supports snippets out of the box.
SNIPPET_STORAGE="local"

# Network bridge VMs attach to
BRIDGE="vmbr0"
# Optional VLAN tag; leave empty for untagged
NET_VLAN_TAG=""

# ID of the cloud-init template created by build-template.sh
TEMPLATE_ID="9000"

##### Per-VM defaults (overridable via create-vm.sh flags) #####

VM_CORES="4"
VM_MEMORY_MB="8192"   # MiB
VM_DISK_SIZE_GB="80"  # root disk; expanded post-clone, growpart runs on boot

# Set a fixed IP like "10.0.0.42/24" to skip DHCP. Leave empty for DHCP4.
STATIC_IP=""
# Only used when STATIC_IP is set
GATEWAY=""

# Optional DNS search domain for the guest
SEARCH_DOMAIN=""

##### Guest OS / account #####

GUEST_HOSTNAME_PREFIX="agent-box"
ADMIN_USER="dev"
GUEST_TIMEZONE="America/Los_Angeles"

# One or more files with SSH public keys, whitespace separated.
# IMPORTANT: resolved on the machine where create-vm.sh runs (the PVE host).
# Use absolute paths to avoid $HOME surprises; copy keys there if needed:
#   scp ~/.ssh/id_ed25519.pub root@pve:/root/.ssh/
# Each key gets full sudo + docker access on the box.
SSH_KEY_FILES="/root/.ssh/id_ed25519.pub"
# Non-existent entries in the list above are ignored; keep at least one real one.

##### Provisioning knobs (applied inside the guest) #####

NODE_MAJOR="24"        # Node LTS major installed alongside bun (agent CLIs need npm)
SWAP_SIZE_GB="8"       # 0 disables swapfile creation
ENABLE_UFW="1"         # 1 = firewall with OpenSSH + mosh UDP inbound (Docker bypasses ufw)
# Extra apt packages installed on every box. Defaults live in provision.sh
# (ripgrep fd-find fzf tree ncdu sqlite3 strace lsof rsync less file manpages);
# set this to ADD more, e.g. "postgresql-client redis-tools ffmpeg"
EXTRA_APT_PACKAGES=""

##### Build-template options #####

# Sourced externally by scripts/build-template.sh
# shellcheck disable=SC2034
# Ubuntu 24.04 (noble) generic cloud image
CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
