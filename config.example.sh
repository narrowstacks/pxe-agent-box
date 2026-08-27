# agent-box configuration reference. Copy to config.sh and edit.
# Every variable here is consumed by devbox.sh and scripts/*.sh.
# shellcheck shell=bash disable=SC2034

##### Proxmox infrastructure #####

STORAGE="local-lvm"          # pvesm status; must be images-capable
SNIPPET_STORAGE="local"      # where the cloud-init snippet is written
BRIDGE="vmbr0"
NET_VLAN_TAG=""

TEMPLATE_ID="9000"
VMID="104"
VMNAME="devbox"

##### Box sizing #####
# NOTE: devbox.sh forces --balloon 0, because PVE requires ballooning
# disabled for virtiofs. Size VM_MEMORY_MB against the host's real RAM minus
# what other VMs already hold; scripts/preflight.sh checks it before every
# create.

VM_CORES="8"
VM_MEMORY_MB="16384"
VM_DISK_SIZE_GB="160"

STATIC_IP=""                 # e.g. "10.0.0.42/24"; empty means DHCP
GATEWAY=""
SEARCH_DOMAIN=""

##### Guest account #####

ADMIN_USER="dev"             # created at uid 1000; see cloud-init template
GUEST_TIMEZONE="America/Los_Angeles"

# Resolved ON THE PVE HOST. Absolute paths only.
SSH_KEY_FILES="/root/.ssh/id_ed25519.pub /root/.ssh/id_ed25519_iphone.pub"

##### Persistent state volume #####
# A plain host directory exposed to the guest over virtiofs as /data.
# It is never referenced by the VM config, so no destroy path can reach it.

DATA_HOST_DIR="/srv/devdata"
DATA_MAP_ID="devdata"

##### Images and bootstrap #####

CLOUD_IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"

# Pin to a tag or commit SHA once the box is stable, so an in-flight push
# to main cannot change what a rebuild installs.
BOOTSTRAP_URL="https://raw.githubusercontent.com/narrowstacks/pxe-agent-box/main/bootstrap.sh"

##### Guest provisioning knobs #####

# mise owns the user toolchain tree. Toolchains live on the VM disk and are
# reinstalled from ~/.config/mise on rebuild; only the manifest persists.
MISE_TOOLS="node@lts python@3.13 bun@latest"

SWAP_SIZE_GB="8"
ENABLE_UFW="1"
EXTRA_APT_PACKAGES=""
