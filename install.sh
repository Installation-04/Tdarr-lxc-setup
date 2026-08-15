#!/usr/bin/env bash
#
# Tdarr LXC installer for Proxmox VE
# Run this ON THE PROXMOX HOST (not inside a container/VM).
#
# Structured like the community-scripts / ProxmoxVE helper scripts
# (msg_info/msg_ok/msg_error, header_info, var_* settings, a
# default-vs-advanced settings prompt, then start -> build_container ->
# description), but kept self-contained (it does not source an external
# build.func) since this installs one specific app, not a shared library.
#
# One-time run:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/installation-04/tdarr-lxc-setup/main/install.sh)"
#
# What it does:
#   - Creates a Debian 12 (bookworm) or Debian 13 (trixie) LXC container
#   - Detects GPU(s) on the Proxmox host (NVIDIA / Intel / AMD) and wires up
#     passthrough automatically so Tdarr can hardware-transcode
#   - Installs Docker + deploys Tdarr Server & Node inside the container
#   - Installs Samba + NFS and Cockpit (with the file-sharing module) so you
#     get a small web GUI to manage the shares
#
set -Eeuo pipefail

APP="Tdarr"
var_tags="${var_tags:-media;transcode}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-12}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"   # 12 (bookworm) or 13 (trixie)
var_unprivileged="${var_unprivileged:-1}"

# ---------------------------------------------------------------------------
# Remaining defaults - shown as the starting values in the on-screen
# questions below. Set NONINTERACTIVE=1 to skip the wizard and use these
# (or env-var overrides) directly, e.g. for scripted/unattended installs.
# ---------------------------------------------------------------------------
CTID_DEFAULT="${CTID:-}"
CT_HOSTNAME="${CT_HOSTNAME:-tdarr}"
SWAP="${SWAP:-512}"                   # MB
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
NET_MODE="${NET_MODE:-dhcp}"          # dhcp | static
STATIC_IP="${STATIC_IP:-}"            # e.g. 192.168.1.50/24
STATIC_GW="${STATIC_GW:-}"            # e.g. 192.168.1.1
MEDIA_HOST_PATH="${MEDIA_HOST_PATH:-/mnt/tdarr_media}"   # host path bind-mounted into the CT
CONFIG_HOST_PATH="${CONFIG_HOST_PATH:-/mnt/tdarr_config}"
GH_RAW_BASE="${GH_RAW_BASE:-https://raw.githubusercontent.com/installation-04/tdarr-lxc-setup/main}"

# TDARR_MODE=server -> deploy Tdarr Server + a local Node (default, all-in-one box)
# TDARR_MODE=node   -> deploy ONLY a Tdarr Node that connects to an existing remote server
TDARR_MODE="${TDARR_MODE:-server}"
REMOTE_SERVER_IP="${REMOTE_SERVER_IP:-}"       # required when TDARR_MODE=node
REMOTE_SERVER_PORT="${REMOTE_SERVER_PORT:-8266}"
NODE_NAME="${NODE_NAME:-${CT_HOSTNAME}}"

NONINTERACTIVE="${NONINTERACTIVE:-0}"

# ---------------------------------------------------------------------------
# Output helpers (msg_info/msg_ok/msg_error/msg_warn) - all write to stderr
# so that functions which return a value via `$(...)` command substitution
# (e.g. ensure_template) never get status text mixed into their result.
# ---------------------------------------------------------------------------
color() {
  YW="\033[33m"; GN="\033[1;92m"; RD="\033[01;31m"; BL="\033[36m"; CL="\033[m"
}
color

msg_info()  { echo -e " ${BL}ℹ${CL} $*" >&2; }
msg_ok()    { echo -e " ${GN}✓${CL} $*" >&2; }
msg_warn()  { echo -e " ${YW}!${CL} $*" >&2; }
msg_error() { echo -e " ${RD}✗${CL} $*" >&2; }
die()       { msg_error "$*"; exit 1; }

header_info() {
  cat <<'EOF' >&2

 _______   _
|__   __| | |
   | | __| | __ _ _ __ _ __
   | |/ _` |/ _` | '__| '__|
   | | (_| | (_| | |  | |
   |_|\__,_|\__,_|_|  |_|

EOF
  echo -e " ${APP} LXC installer for Proxmox VE" >&2
  echo >&2
}

catch_errors() {
  set -Eeuo pipefail
  trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
}

error_handler() {
  local line="$1" command="$2"
  msg_error "Failed at line ${line}: ${command}"
  exit 1
}

header_info
catch_errors

[[ $EUID -eq 0 ]] || die "Run this script as root on the Proxmox host."
command -v pveversion >/dev/null 2>&1 || die "pveversion not found - this must run on a Proxmox VE host."
command -v pct >/dev/null 2>&1 || die "pct not found - this must run on a Proxmox VE host."

# ---------------------------------------------------------------------------
# Update mode: re-running against an already-provisioned Tdarr container
# (e.g. `CTID=103 ./install.sh --update` or `UPDATE=1 CTID=103 ./install.sh`)
# pulls fresh images and restarts the stack instead of creating a new CT.
# Checked early so it short-circuits before the GPU detection / wizard run.
# ---------------------------------------------------------------------------
update_script() {
  [[ -n "${CTID_DEFAULT}" ]] || die "Set CTID=<container-id> when using --update."
  pct status "${CTID_DEFAULT}" >/dev/null 2>&1 || die "Container ${CTID_DEFAULT} not found."

  msg_info "Updating ${APP} in CT ${CTID_DEFAULT}..."
  pct exec "${CTID_DEFAULT}" -- bash -c "cd /opt/tdarr && docker compose pull && docker compose up -d"
  msg_ok "${APP} updated."
  exit 0
}

if [[ "${1:-}" == "--update" || "${UPDATE:-0}" == "1" ]]; then
  update_script
fi

if [[ "${NONINTERACTIVE}" != "1" ]] && ! command -v whiptail >/dev/null 2>&1; then
  msg_info "Installing whiptail for the setup GUI..."
  apt-get -qq update >/dev/null 2>&1 || true
  apt-get -y -qq install whiptail >/dev/null 2>&1 || true
  msg_ok "whiptail installed."
fi

WT_BACKTITLE="Tdarr LXC Setup for Proxmox VE"

# ---------------------------------------------------------------------------
# GPU detection (host side) - run up front so the wizard can show what was
# found and let the user opt out of passthrough.
# ---------------------------------------------------------------------------
HAS_NVIDIA=0
HAS_VAAPI=0   # Intel QuickSync or AMD VCN, both use /dev/dri + VAAPI
NVIDIA_DRIVER_VERSION=""
GPU_SUMMARY="No supported GPU detected - CPU (software) transcoding only."
ENABLE_GPU_PASSTHROUGH="${ENABLE_GPU_PASSTHROUGH:-1}"

detect_gpu() {
  msg_info "Detecting GPU hardware on host..."

  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    HAS_NVIDIA=1
    NVIDIA_DRIVER_VERSION="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)"
    GPU_SUMMARY="NVIDIA GPU detected (driver ${NVIDIA_DRIVER_VERSION}): $(nvidia-smi -L | head -n1)"
    msg_ok "${GPU_SUMMARY}"
  fi

  if [[ -d /dev/dri ]] && ls /dev/dri/renderD* >/dev/null 2>&1; then
    if lspci -nnk | grep -Ei "vga|3d|display" | grep -Eiq "intel|amd|ati"; then
      HAS_VAAPI=1
      GPU_SUMMARY="VAAPI-capable GPU detected: $(lspci -nnk | grep -Ei 'vga|3d|display' | grep -Ei 'intel|amd|ati' | head -n1)"
      msg_ok "${GPU_SUMMARY}"
    fi
  fi

  if [[ $HAS_NVIDIA -eq 0 && $HAS_VAAPI -eq 0 ]]; then
    msg_warn "${GPU_SUMMARY}"
  fi
}

detect_gpu

# whiptail input box; prints the answer to stdout, exits the script if the
# user hits Cancel.
ask_input() {
  local title="$1" text="$2" default="$3"
  whiptail --backtitle "${WT_BACKTITLE}" --title "${title}" \
    --inputbox "${text}" 12 70 "${default}" 3>&1 1>&2 2>&3 || die "Setup cancelled."
}

ask_menu() {
  local title="$1" text="$2"; shift 2
  whiptail --backtitle "${WT_BACKTITLE}" --title "${title}" \
    --menu "${text}" 15 70 4 "$@" 3>&1 1>&2 2>&3 || die "Setup cancelled."
}

# ---------------------------------------------------------------------------
# Settings: default (var_* values as-is) vs advanced (full whiptail wizard)
# ---------------------------------------------------------------------------
default_settings() {
  CTID="${CTID_DEFAULT:-$(pvesh get /cluster/nextid)}"
  CORES="${var_cpu}"
  RAM="${var_ram}"
  DISK_SIZE="${var_disk}"
  UNPRIVILEGED="${var_unprivileged}"
  msg_ok "Using default settings: ${CORES} vCPU / ${RAM}MB RAM / ${DISK_SIZE}GB disk, $( [[ ${UNPRIVILEGED} -eq 1 ]] && echo unprivileged || echo privileged )."
}

advanced_settings() {
  whiptail --backtitle "${WT_BACKTITLE}" --title "Welcome" --msgbox \
"This wizard will ask a few questions to set up Tdarr in a new LXC container.\n\nGPU check on this host:\n${GPU_SUMMARY}" 14 70

  if [[ $HAS_NVIDIA -eq 1 || $HAS_VAAPI -eq 1 ]]; then
    if whiptail --backtitle "${WT_BACKTITLE}" --title "GPU passthrough" \
        --yesno "Enable GPU passthrough into the container for hardware transcoding?\n\n${GPU_SUMMARY}" 12 70; then
      ENABLE_GPU_PASSTHROUGH=1
    else
      ENABLE_GPU_PASSTHROUGH=0
    fi
  else
    ENABLE_GPU_PASSTHROUGH=0
  fi

  CTID="$(ask_input "Container ID" "CTID for the new container:" "${CTID_DEFAULT:-$(pvesh get /cluster/nextid)}")"
  CT_HOSTNAME="$(ask_input "Hostname" "Hostname for the container:" "${CT_HOSTNAME}")"

  var_version="$(ask_menu "OS template" "Which Debian release should the container run?" \
    "13" "Debian 13 (trixie) - recommended" \
    "12" "Debian 12 (bookworm)")"

  CORES="$(ask_input "CPU cores" "Number of vCPU cores:" "${var_cpu}")"
  RAM="$(ask_input "Memory" "RAM in MB:" "${var_ram}")"
  SWAP="$(ask_input "Swap" "Swap in MB:" "${SWAP}")"
  DISK_SIZE="$(ask_input "Disk size" "Root disk size in GB:" "${var_disk}")"
  STORAGE="$(ask_input "Container storage" "Proxmox storage for the container disk:" "${STORAGE}")"
  TEMPLATE_STORAGE="$(ask_input "Template storage" "Proxmox storage holding the LXC template:" "${TEMPLATE_STORAGE}")"
  BRIDGE="$(ask_input "Network bridge" "Bridge to attach the container to:" "${BRIDGE}")"

  NET_MODE="$(ask_menu "Networking" "How should the container get its IP?" \
    "dhcp" "Automatic (DHCP)" \
    "static" "Static IP address")"
  if [[ "${NET_MODE}" == "static" ]]; then
    STATIC_IP="$(ask_input "Static IP" "IP address with CIDR, e.g. 192.168.1.50/24:" "${STATIC_IP}")"
    STATIC_GW="$(ask_input "Gateway" "Gateway IP, e.g. 192.168.1.1:" "${STATIC_GW}")"
  fi

  if whiptail --backtitle "${WT_BACKTITLE}" --title "Container privilege" \
      --yesno "Create an UNPRIVILEGED container? (Recommended. Choose No only if you hit GPU permission issues.)" 10 70; then
    UNPRIVILEGED=1
  else
    UNPRIVILEGED=0
  fi

  MEDIA_HOST_PATH="$(ask_input "Media library path" "Host directory to bind-mount as the media library (point this at your existing media pool):" "${MEDIA_HOST_PATH}")"
  CONFIG_HOST_PATH="$(ask_input "Tdarr config path" "Host directory to bind-mount for Tdarr's server config/logs:" "${CONFIG_HOST_PATH}")"

  TDARR_MODE="$(ask_menu "Tdarr mode" "Deploy a full Tdarr Server (+ local Node), or just a Node that joins an existing remote server?" \
    "server" "Server + local Node (all-in-one, recommended)" \
    "node" "Node only (connect to an existing remote Tdarr server)")"

  if [[ "${TDARR_MODE}" == "node" ]]; then
    REMOTE_SERVER_IP="$(ask_input "Remote Tdarr server" "IP/hostname of the existing Tdarr server:" "${REMOTE_SERVER_IP}")"
    REMOTE_SERVER_PORT="$(ask_input "Remote Tdarr server port" "Server API port on the remote Tdarr server:" "${REMOTE_SERVER_PORT}")"
  fi
  NODE_NAME="$(ask_input "Node name" "Name this node shows up as in the Tdarr UI:" "${NODE_NAME:-$CT_HOSTNAME}")"

  local summary="CTID:            ${CTID}
Hostname:        ${CT_HOSTNAME}
OS template:     Debian ${var_version}
CPU / RAM / Swap: ${CORES} cores / ${RAM}MB / ${SWAP}MB
Disk:            ${DISK_SIZE}GB on ${STORAGE}
Network:         ${BRIDGE}, $( [[ "${NET_MODE}" == "static" ]] && echo "static ${STATIC_IP} via ${STATIC_GW}" || echo "DHCP" )
Privilege:       $( [[ ${UNPRIVILEGED} -eq 1 ]] && echo unprivileged || echo privileged )
Media path:      ${MEDIA_HOST_PATH}
Config path:     ${CONFIG_HOST_PATH}
GPU passthrough: $( [[ ${ENABLE_GPU_PASSTHROUGH} -eq 1 ]] && echo "yes - ${GPU_SUMMARY}" || echo "no (CPU transcoding)" )
Mode:            ${TDARR_MODE}$( [[ "${TDARR_MODE}" == "node" ]] && echo " -> ${REMOTE_SERVER_IP}:${REMOTE_SERVER_PORT}" )
Node name:       ${NODE_NAME}"

  whiptail --backtitle "${WT_BACKTITLE}" --title "Confirm" --yesno "${summary}\n\nProceed with this setup?" 22 76 || die "Setup cancelled."
}

start() {
  if [[ "${NONINTERACTIVE}" == "1" ]] || ! command -v whiptail >/dev/null 2>&1; then
    default_settings
    return
  fi

  if whiptail --backtitle "${WT_BACKTITLE}" --title "${APP} LXC" \
      --yesno "Use Default Settings?\n\n${var_cpu} vCPU / ${var_ram}MB RAM / ${var_disk}GB disk\n${var_os} ${var_version}, $( [[ ${var_unprivileged} -eq 1 ]] && echo unprivileged || echo privileged )\n\nChoose No to configure networking, GPU passthrough, media paths, etc." 15 70 --defaultno; then
    default_settings
  else
    advanced_settings
  fi
}

start

if [[ "${ENABLE_GPU_PASSTHROUGH}" != "1" ]]; then
  HAS_NVIDIA=0
  HAS_VAAPI=0
fi

if [[ "${NET_MODE}" == "static" ]]; then
  [[ -n "${STATIC_IP}" && -n "${STATIC_GW}" ]] || die "Static networking requires an IP and gateway."
  NET_CONFIG="name=eth0,bridge=${BRIDGE},ip=${STATIC_IP},gw=${STATIC_GW},firewall=1"
else
  NET_CONFIG="name=eth0,bridge=${BRIDGE},ip=dhcp,firewall=1"
fi

if [[ "${TDARR_MODE}" == "node" && -z "${REMOTE_SERVER_IP}" ]]; then
  die "TDARR_MODE=node requires REMOTE_SERVER_IP=<ip-of-existing-tdarr-server> to be set."
fi

# ---------------------------------------------------------------------------
# Container build
# ---------------------------------------------------------------------------
ensure_template() {
  local pattern="^${var_os}-${var_version}-standard"
  local fallback
  case "${var_os}-${var_version}" in
    debian-13) fallback="debian-13-standard_13.0-1_amd64.tar.zst" ;;
    debian-12) fallback="debian-12-standard_12.7-1_amd64.tar.zst" ;;
    *)         fallback="${var_os}-${var_version}-standard_${var_version}.7-1_amd64.tar.zst" ;;
  esac

  msg_info "Updating LXC template list..."
  pveam update >/dev/null 2>&1 || true

  local template
  template="$(pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | awk '{print $1}' | sed "s#.*/##" | grep -E "${pattern}" | sort -V | tail -n1)"

  if [[ -z "${template}" ]]; then
    local latest
    latest="$(pveam available -section system | awk '{print $2}' | grep -E "${pattern}" | sort -V | tail -n1)"
    template="${latest:-$fallback}"
    msg_info "Downloading template ${template}..."
    pveam download "${TEMPLATE_STORAGE}" "${template}" >/dev/null || die "Failed to download ${template} - is ${var_os} ${var_version} available on this Proxmox version yet?"
  fi
  msg_ok "Template ready: ${template}"
  echo "${TEMPLATE_STORAGE}:vztmpl/${template}"
}

create_container() {
  local template_volid="$1"
  msg_info "Creating CT ${CTID} (${CT_HOSTNAME}) - ${CORES} vCPU / ${RAM}MB RAM / ${DISK_SIZE}GB disk..."

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
    --tags "${var_tags}" >/dev/null

  msg_ok "Container ${CTID} created."
}

configure_gpu_passthrough() {
  local conf="/etc/pve/lxc/${CTID}.conf"
  [[ -f "${conf}" ]] || die "Container config ${conf} not found."

  if [[ $HAS_VAAPI -eq 1 ]]; then
    msg_info "Wiring up /dev/dri passthrough (Intel/AMD VAAPI)..."
    {
      echo "lxc.cgroup2.devices.allow: c 226:0 rwm"
      echo "lxc.cgroup2.devices.allow: c 226:128 rwm"
      echo "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir"
    } >> "${conf}"
    msg_ok "VAAPI device passthrough configured."
  fi

  if [[ $HAS_NVIDIA -eq 1 ]]; then
    msg_info "Wiring up NVIDIA device passthrough..."
    {
      echo "lxc.cgroup2.devices.allow: c 195:* rwm"
      echo "lxc.cgroup2.devices.allow: c 243:* rwm"
      for dev in nvidia0 nvidia1 nvidiactl nvidia-uvm nvidia-uvm-tools nvidia-modeset; do
        [[ -e "/dev/${dev}" ]] && echo "lxc.mount.entry: /dev/${dev} dev/${dev} none bind,optional,create=file"
      done
    } >> "${conf}"
    msg_ok "NVIDIA device passthrough configured."
  fi

  if [[ $UNPRIVILEGED -eq 1 && ( $HAS_VAAPI -eq 1 || $HAS_NVIDIA -eq 1 ) ]]; then
    # Allow the unprivileged CT's mapped root to actually open the render/video devices.
    cat >> "${conf}" <<'EOF'
lxc.apparmor.profile: unconfined
EOF
  fi
}

wait_for_network() {
  msg_info "Waiting for container network..."
  for _ in $(seq 1 30); do
    if pct exec "${CTID}" -- getent hosts deb.debian.org >/dev/null 2>&1; then
      msg_ok "Network is up inside the container."
      return 0
    fi
    sleep 2
  done
  msg_warn "Network check timed out - continuing anyway."
}

push_and_run_setup() {
  msg_info "Pushing setup script into the container..."
  local tmp="/tmp/tdarr-setup-${CTID}.sh"
  if [[ -f "$(dirname "$0")/setup-tdarr.sh" ]]; then
    cp "$(dirname "$0")/setup-tdarr.sh" "${tmp}"
  else
    curl -fsSL "${GH_RAW_BASE}/setup-tdarr.sh" -o "${tmp}"
  fi
  pct push "${CTID}" "${tmp}" /root/setup-tdarr.sh --perms 755
  rm -f "${tmp}"
  msg_ok "Setup script pushed."

  msg_info "Running in-container setup (Docker, Tdarr, Samba/NFS, Cockpit GUI)..."
  pct exec "${CTID}" -- env \
    HAS_NVIDIA="${HAS_NVIDIA}" \
    HAS_VAAPI="${HAS_VAAPI}" \
    NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION}" \
    TDARR_MODE="${TDARR_MODE}" \
    REMOTE_SERVER_IP="${REMOTE_SERVER_IP}" \
    REMOTE_SERVER_PORT="${REMOTE_SERVER_PORT}" \
    NODE_NAME="${NODE_NAME}" \
    /root/setup-tdarr.sh
  msg_ok "In-container setup complete."
}

build_container() {
  local volid
  volid="$(ensure_template)"
  create_container "${volid}"
  configure_gpu_passthrough
  pct start "${CTID}"
  msg_ok "Container ${CTID} started."
  wait_for_network
  push_and_run_setup
}

description() {
  local ip
  ip="$(pct exec "${CTID}" -- hostname -I 2>/dev/null | awk '{print $1}')"
  pct set "${CTID}" --description "# ${APP} LXC

- Web UI: http://${ip}:8265
- Share management (Cockpit): https://${ip}:9090
- Media library (host): ${MEDIA_HOST_PATH}
- Tdarr config (host): ${CONFIG_HOST_PATH}
- Mode: ${TDARR_MODE}$( [[ "${TDARR_MODE}" == "node" ]] && echo " -> ${REMOTE_SERVER_IP}:${REMOTE_SERVER_PORT}" )
" >/dev/null 2>&1 || true

  echo >&2
  echo -e "${GN}=====================================================${CL}" >&2
  echo -e "${GN} ${APP} LXC ${CTID} (${CT_HOSTNAME}) is ready${CL}" >&2
  echo -e "${GN}=====================================================${CL}" >&2
  echo -e " Mode:                 ${TDARR_MODE}$( [[ "${TDARR_MODE}" == "node" ]] && echo " (connected to ${REMOTE_SERVER_IP}:${REMOTE_SERVER_PORT})" )" >&2
  echo -e " Tdarr Web UI:         http://${ip}:8265$( [[ "${TDARR_MODE}" == "node" ]] && echo "  (node only - manage jobs from the server's UI)" )" >&2
  echo -e " Share management GUI (Cockpit): https://${ip}:9090" >&2
  echo -e " Media library (host path):      ${MEDIA_HOST_PATH}  -> /mnt/media in CT" >&2
  echo -e " Tdarr config (host path):       ${CONFIG_HOST_PATH} -> /mnt/config in CT" >&2
  [[ $HAS_NVIDIA -eq 1 ]] && echo -e " GPU passthrough:      NVIDIA (driver ${NVIDIA_DRIVER_VERSION})" >&2
  [[ $HAS_VAAPI -eq 1 ]]  && echo -e " GPU passthrough:      VAAPI (/dev/dri)" >&2
  [[ $HAS_NVIDIA -eq 0 && $HAS_VAAPI -eq 0 ]] && echo -e " GPU passthrough:      none (CPU transcoding)" >&2
  echo -e "${GN}=====================================================${CL}" >&2
}

build_container
description

msg_ok "Completed Successfully!"
