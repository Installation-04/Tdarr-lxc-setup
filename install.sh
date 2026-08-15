#!/usr/bin/env bash
#
# Tdarr LXC installer for Proxmox VE
# Run this ON THE PROXMOX HOST (not inside a container/VM).
#
# One-time run:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/installation-04/tdarr-lxc-setup/main/install.sh)"
#
# What it does:
#   - Creates a Debian 12 LXC container
#   - Detects GPU(s) on the Proxmox host (NVIDIA / Intel / AMD) and wires up
#     passthrough automatically so Tdarr can hardware-transcode
#   - Installs Docker + deploys Tdarr Server & Node inside the container
#   - Installs Samba + NFS and Cockpit (with the file-sharing module) so you
#     get a small web GUI to manage the shares
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Config (override with env vars, e.g. CTID=150 CT_HOSTNAME=tdarr bash install.sh)
# ---------------------------------------------------------------------------
CTID="${CTID:-$(pvesh get /cluster/nextid)}"
CT_HOSTNAME="${CT_HOSTNAME:-tdarr}"
DISK_SIZE="${DISK_SIZE:-12}"          # GB, root disk
CORES="${CORES:-4}"
RAM="${RAM:-4096}"                    # MB
SWAP="${SWAP:-512}"                   # MB
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
NET_CONFIG="${NET_CONFIG:-name=eth0,bridge=${BRIDGE},ip=dhcp,firewall=1}"
MEDIA_HOST_PATH="${MEDIA_HOST_PATH:-/mnt/tdarr_media}"   # host path bind-mounted into the CT
CONFIG_HOST_PATH="${CONFIG_HOST_PATH:-/mnt/tdarr_config}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"
GH_RAW_BASE="${GH_RAW_BASE:-https://raw.githubusercontent.com/installation-04/tdarr-lxc-setup/main}"

# TDARR_MODE=server -> deploy Tdarr Server + a local Node (default, all-in-one box)
# TDARR_MODE=node   -> deploy ONLY a Tdarr Node that connects to an existing remote server
TDARR_MODE="${TDARR_MODE:-server}"
REMOTE_SERVER_IP="${REMOTE_SERVER_IP:-}"       # required when TDARR_MODE=node
REMOTE_SERVER_PORT="${REMOTE_SERVER_PORT:-8266}"
NODE_NAME="${NODE_NAME:-${CT_HOSTNAME}}"

if [[ "${TDARR_MODE}" == "node" && -z "${REMOTE_SERVER_IP}" ]]; then
  die "TDARR_MODE=node requires REMOTE_SERVER_IP=<ip-of-existing-tdarr-server> to be set."
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
C_RESET="\e[0m"; C_GREEN="\e[32m"; C_YELLOW="\e[33m"; C_RED="\e[31m"; C_BLUE="\e[36m"
msg()  { echo -e "${C_BLUE}[tdarr-lxc]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}[ok]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[warn]${C_RESET} $*"; }
die()  { echo -e "${C_RED}[error]${C_RESET} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this script as root on the Proxmox host."
command -v pveversion >/dev/null 2>&1 || die "pveversion not found - this must run on a Proxmox VE host."
command -v pct >/dev/null 2>&1 || die "pct not found - this must run on a Proxmox VE host."

# ---------------------------------------------------------------------------
# GPU detection (host side)
# ---------------------------------------------------------------------------
HAS_NVIDIA=0
HAS_VAAPI=0   # Intel QuickSync or AMD VCN, both use /dev/dri + VAAPI
NVIDIA_DRIVER_VERSION=""

detect_gpu() {
  msg "Detecting GPU hardware on host..."

  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    HAS_NVIDIA=1
    NVIDIA_DRIVER_VERSION="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)"
    ok "NVIDIA GPU detected (driver ${NVIDIA_DRIVER_VERSION}): $(nvidia-smi -L | head -n1)"
  fi

  if [[ -d /dev/dri ]] && ls /dev/dri/renderD* >/dev/null 2>&1; then
    if lspci -nnk | grep -Ei "vga|3d|display" | grep -Eiq "intel|amd|ati"; then
      HAS_VAAPI=1
      ok "VAAPI-capable GPU detected on host: $(lspci -nnk | grep -Ei 'vga|3d|display' | grep -Ei 'intel|amd|ati' | head -n1)"
    fi
  fi

  if [[ $HAS_NVIDIA -eq 0 && $HAS_VAAPI -eq 0 ]]; then
    warn "No supported GPU detected - Tdarr will run with software (CPU) transcoding only."
  fi
}

# ---------------------------------------------------------------------------
# Container creation
# ---------------------------------------------------------------------------
ensure_template() {
  local template="debian-12-standard_12.7-1_amd64.tar.zst"
  msg "Updating LXC template list..."
  pveam update >/dev/null 2>&1 || true
  if ! pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | grep -q "${template}"; then
    local latest
    latest="$(pveam available -section system | awk '{print $2}' | grep -E '^debian-12-standard' | sort -V | tail -n1)"
    template="${latest:-$template}"
    msg "Downloading template ${template}..."
    pveam download "${TEMPLATE_STORAGE}" "${template}"
  fi
  echo "${TEMPLATE_STORAGE}:vztmpl/${template}"
}

create_container() {
  local template_volid="$1"
  msg "Creating CT ${CTID} (${CT_HOSTNAME}) - ${CORES} vCPU / ${RAM}MB RAM / ${DISK_SIZE}GB disk..."

  mkdir -p "${MEDIA_HOST_PATH}" "${CONFIG_HOST_PATH}"

  pct create "${CTID}" "${template_volid}" \
    --hostname "${CT_HOSTNAME}" \
    --cores "${CORES}" \
    --memory "${RAM}" \
    --swap "${SWAP}" \
    --net0 "${NET_CONFIG}" \
    --rootfs "${STORAGE}:${DISK_SIZE}" \
    --unprivileged "${UNPRIVILEGED}" \
    --features "nesting=1,keyctl=1" \
    --onboot 1 \
    --mp0 "${MEDIA_HOST_PATH},mp=/mnt/media" \
    --mp1 "${CONFIG_HOST_PATH},mp=/mnt/config" \
    --tags "tdarr" >/dev/null

  ok "Container ${CTID} created."
}

configure_gpu_passthrough() {
  local conf="/etc/pve/lxc/${CTID}.conf"
  [[ -f "${conf}" ]] || die "Container config ${conf} not found."

  if [[ $HAS_VAAPI -eq 1 ]]; then
    msg "Wiring up /dev/dri passthrough (Intel/AMD VAAPI)..."
    {
      echo "lxc.cgroup2.devices.allow: c 226:0 rwm"
      echo "lxc.cgroup2.devices.allow: c 226:128 rwm"
      echo "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir"
    } >> "${conf}"
  fi

  if [[ $HAS_NVIDIA -eq 1 ]]; then
    msg "Wiring up NVIDIA device passthrough..."
    {
      echo "lxc.cgroup2.devices.allow: c 195:* rwm"
      echo "lxc.cgroup2.devices.allow: c 243:* rwm"
      for dev in nvidia0 nvidia1 nvidiactl nvidia-uvm nvidia-uvm-tools nvidia-modeset; do
        [[ -e "/dev/${dev}" ]] && echo "lxc.mount.entry: /dev/${dev} dev/${dev} none bind,optional,create=file"
      done
    } >> "${conf}"
  fi

  if [[ $UNPRIVILEGED -eq 1 && ( $HAS_VAAPI -eq 1 || $HAS_NVIDIA -eq 1 ) ]]; then
    # Allow the unprivileged CT's mapped root to actually open the render/video devices.
    echo "lxc.idmap: u 0 100000 65536" >/dev/null # no-op, kept for readability
    cat >> "${conf}" <<'EOF'
lxc.apparmor.profile: unconfined
EOF
  fi
}

wait_for_network() {
  msg "Waiting for container network..."
  for _ in $(seq 1 30); do
    if pct exec "${CTID}" -- getent hosts deb.debian.org >/dev/null 2>&1; then
      ok "Network is up inside the container."
      return 0
    fi
    sleep 2
  done
  warn "Network check timed out - continuing anyway."
}

push_and_run_setup() {
  msg "Pushing setup script into the container..."
  local tmp="/tmp/tdarr-setup-${CTID}.sh"
  if [[ -f "$(dirname "$0")/setup-tdarr.sh" ]]; then
    cp "$(dirname "$0")/setup-tdarr.sh" "${tmp}"
  else
    curl -fsSL "${GH_RAW_BASE}/setup-tdarr.sh" -o "${tmp}"
  fi
  pct push "${CTID}" "${tmp}" /root/setup-tdarr.sh --perms 755
  rm -f "${tmp}"

  msg "Running in-container setup (Docker, Tdarr, Samba/NFS, Cockpit GUI)..."
  pct exec "${CTID}" -- env \
    HAS_NVIDIA="${HAS_NVIDIA}" \
    HAS_VAAPI="${HAS_VAAPI}" \
    NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION}" \
    TDARR_MODE="${TDARR_MODE}" \
    REMOTE_SERVER_IP="${REMOTE_SERVER_IP}" \
    REMOTE_SERVER_PORT="${REMOTE_SERVER_PORT}" \
    NODE_NAME="${NODE_NAME}" \
    /root/setup-tdarr.sh
}

print_summary() {
  local ip
  ip="$(pct exec "${CTID}" -- hostname -I 2>/dev/null | awk '{print $1}')"
  echo
  echo -e "${C_GREEN}=====================================================${C_RESET}"
  echo -e "${C_GREEN} Tdarr LXC ${CTID} (${CT_HOSTNAME}) is ready${C_RESET}"
  echo -e "${C_GREEN}=====================================================${C_RESET}"
  echo -e " Mode:                 ${TDARR_MODE}$( [[ "${TDARR_MODE}" == "node" ]] && echo " (connected to ${REMOTE_SERVER_IP}:${REMOTE_SERVER_PORT})" )"
  echo -e " Tdarr Web UI:         http://${ip}:8265$( [[ "${TDARR_MODE}" == "node" ]] && echo "  (node only - manage jobs from the server's UI)" )"
  echo -e " Share management GUI (Cockpit): https://${ip}:9090"
  echo -e " Media library (host path):      ${MEDIA_HOST_PATH}  -> /mnt/media in CT"
  echo -e " Tdarr config (host path):       ${CONFIG_HOST_PATH} -> /mnt/config in CT"
  [[ $HAS_NVIDIA -eq 1 ]] && echo -e " GPU passthrough:      NVIDIA (driver ${NVIDIA_DRIVER_VERSION})"
  [[ $HAS_VAAPI -eq 1 ]]  && echo -e " GPU passthrough:      VAAPI (/dev/dri)"
  [[ $HAS_NVIDIA -eq 0 && $HAS_VAAPI -eq 0 ]] && echo -e " GPU passthrough:      none (CPU transcoding)"
  echo -e "${C_GREEN}=====================================================${C_RESET}"
}

main() {
  detect_gpu
  local volid
  volid="$(ensure_template)"
  create_container "${volid}"
  configure_gpu_passthrough
  pct start "${CTID}"
  wait_for_network
  push_and_run_setup
  print_summary
}

main "$@"
