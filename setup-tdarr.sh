#!/usr/bin/env bash
#
# Runs INSIDE the Tdarr LXC container (invoked by install.sh via `pct exec`).
# Installs Docker, deploys Tdarr, and sets up Samba/NFS shares with a small
# web GUI (Cockpit + cockpit-file-sharing) to manage them.
#
set -Eeuo pipefail

HAS_NVIDIA="${HAS_NVIDIA:-0}"
HAS_VAAPI="${HAS_VAAPI:-0}"
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-}"
TDARR_MODE="${TDARR_MODE:-server}"          # server | node
REMOTE_SERVER_IP="${REMOTE_SERVER_IP:-}"
REMOTE_SERVER_PORT="${REMOTE_SERVER_PORT:-8266}"
NODE_NAME="${NODE_NAME:-tdarr-node}"
VERBOSE="${VERBOSE:-0}"

C_RESET="\e[0m"; C_GREEN="\e[32m"; C_BLUE="\e[36m"; C_RED="\e[31m"
msg_info() { echo -e "${C_BLUE}[setup]${C_RESET} $*"; }
msg_ok()   { echo -e "${C_GREEN}[ok]${C_RESET} $*"; }
msg_error() { echo -e "${C_RED}[error]${C_RESET} $*"; }

# ---------------------------------------------------------------------------
# Quiet-by-default output: every noisy command is prefixed with $STD, which
# is a no-op in verbose mode and redirects to LOGFILE otherwise. Only the
# msg_info/msg_ok step lines above show on screen; the full log is kept on
# disk and its tail gets dumped automatically if a step fails.
# ---------------------------------------------------------------------------
LOGFILE="/var/log/tdarr-setup.log"
: > "${LOGFILE}"

silent() { "$@" >>"${LOGFILE}" 2>&1; }

if [[ "${VERBOSE}" == "1" ]]; then
  STD=""
else
  STD="silent"
fi

on_error() {
  local line="$1"
  msg_error "Setup failed at line ${line}."
  if [[ "${VERBOSE}" != "1" && -s "${LOGFILE}" ]]; then
    echo "----- last 40 lines of ${LOGFILE} -----" >&2
    tail -n 40 "${LOGFILE}" >&2
    echo "----------------------------------------" >&2
    echo "Full log: ${LOGFILE} (inside this container)" >&2
  fi
  exit 1
}
trap 'on_error $LINENO' ERR

export DEBIAN_FRONTEND=noninteractive
# The base template has no locales generated, so apt/perl fall back to "C"
# with a noisy warning on every invocation; C.UTF-8 is built in and silences it.
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

msg_info "Updating base system..."
$STD apt-get update -qq
$STD apt-get -y -qq upgrade

msg_info "Installing base packages..."
$STD apt-get -y -qq install curl gnupg ca-certificates lsb-release apt-transport-https

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------
install_docker() { curl -fsSL https://get.docker.com | sh; }

if ! command -v docker >/dev/null 2>&1; then
  msg_info "Installing Docker..."
  $STD install_docker
  $STD systemctl enable --now docker
fi
msg_ok "Docker ready: $(docker --version)"

# ---------------------------------------------------------------------------
# GPU userland (VAAPI / NVIDIA) inside the container
# ---------------------------------------------------------------------------
if [[ "${HAS_VAAPI}" == "1" ]]; then
  msg_info "Installing VAAPI userland (Intel/AMD hw transcode)..."
  # intel-media-va-driver-non-free lives in the non-free component, which
  # the base template doesn't enable by default - add it if missing.
  for f in /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list; do
    [[ -f "${f}" ]] || continue
    grep -q "non-free-firmware" "${f}" && continue
    if [[ "${f}" == *.sources ]]; then
      sed -i -E '/^Components:/ s/$/ contrib non-free non-free-firmware/' "${f}"
    else
      sed -i -E 's/^(deb(-src)? [^#]*\bmain\b)$/\1 contrib non-free non-free-firmware/' "${f}"
    fi
  done
  $STD apt-get update -qq || true
  $STD apt-get -y -qq install va-driver-all vainfo intel-media-va-driver-non-free ocl-icd-libopencl1 || true
fi

if [[ "${HAS_NVIDIA}" == "1" && -n "${NVIDIA_DRIVER_VERSION}" ]]; then
  msg_info "Installing matching NVIDIA userland driver (${NVIDIA_DRIVER_VERSION})..."
  $STD apt-get -y -qq install build-essential pkg-config libglvnd-dev || true
  RUNFILE="NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run"
  if $STD curl -fsSL -o "/tmp/${RUNFILE}" "https://download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_DRIVER_VERSION}/${RUNFILE}"; then
    $STD sh "/tmp/${RUNFILE}" --no-kernel-module --silent --no-nouveau-check --no-nvidia-modprobe --no-systemd || \
      msg_error "NVIDIA userland install failed - driver version may not be publicly hosted; verify host/container driver match manually."
    rm -f "/tmp/${RUNFILE}"
  else
    msg_error "Could not download NVIDIA driver ${NVIDIA_DRIVER_VERSION} - skipping automatic install."
  fi
  # NVIDIA Container Toolkit so Docker can see the GPU
  add_nvidia_ctk_repo() {
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  }
  $STD add_nvidia_ctk_repo
  $STD apt-get update -qq
  $STD apt-get -y -qq install nvidia-container-toolkit || msg_error "nvidia-container-toolkit install failed."
  $STD nvidia-ctk runtime configure --runtime=docker || true
  $STD systemctl restart docker
fi

# ---------------------------------------------------------------------------
# Directory layout
# ---------------------------------------------------------------------------
mkdir -p /mnt/media /mnt/config/server /mnt/config/configs /mnt/config/logs /mnt/transcode_cache

# ---------------------------------------------------------------------------
# Tdarr via Docker Compose
# ---------------------------------------------------------------------------
mkdir -p /opt/tdarr
COMPOSE_FILE=/opt/tdarr/docker-compose.yml

DEVICES_YAML=""
if [[ "${HAS_VAAPI}" == "1" ]]; then
  DEVICES_YAML="${DEVICES_YAML}
    devices:
      - /dev/dri:/dev/dri"
fi

GPU_DEPLOY_YAML=""
if [[ "${HAS_NVIDIA}" == "1" ]]; then
  GPU_DEPLOY_YAML="
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]"
fi

if [[ "${TDARR_MODE}" == "server" ]]; then
  msg_info "Writing docker-compose.yml for Tdarr Server + local Node..."
  cat > "${COMPOSE_FILE}" <<EOF
services:
  tdarr:
    container_name: tdarr
    image: ghcr.io/haveagitgat/tdarr:latest
    restart: unless-stopped
    network_mode: bridge
    ports:
      - "8265:8265"   # Web UI
      - "8266:8266"   # Server API (used by remote nodes)
    environment:
      - TZ=Etc/UTC
      - PUID=0
      - PGID=0
      - UMASK_SET=002
      - serverIP=0.0.0.0
      - serverPort=8266
      - webUIPort=8265
      - internalNode=true
      - nodeName=${NODE_NAME}
    volumes:
      - /mnt/config/server:/app/server
      - /mnt/config/configs:/app/configs
      - /mnt/config/logs:/app/logs
      - /mnt/media:/media
      - /mnt/transcode_cache:/temp${DEVICES_YAML}${GPU_DEPLOY_YAML}
EOF
else
  msg_info "Writing docker-compose.yml for Tdarr Node only (remote server ${REMOTE_SERVER_IP}:${REMOTE_SERVER_PORT})..."
  cat > "${COMPOSE_FILE}" <<EOF
services:
  tdarr-node:
    container_name: tdarr-node
    image: ghcr.io/haveagitgat/tdarr_node:latest
    restart: unless-stopped
    network_mode: bridge
    environment:
      - TZ=Etc/UTC
      - PUID=0
      - PGID=0
      - UMASK_SET=002
      - nodeName=${NODE_NAME}
      - serverIP=${REMOTE_SERVER_IP}
      - serverPort=${REMOTE_SERVER_PORT}
    volumes:
      - /mnt/config/configs:/app/configs
      - /mnt/config/logs:/app/logs
      - /mnt/media:/media
      - /mnt/transcode_cache:/temp${DEVICES_YAML}${GPU_DEPLOY_YAML}
EOF
fi

msg_info "Starting Tdarr..."
start_tdarr() { cd /opt/tdarr && docker compose up -d; }
$STD start_tdarr
msg_ok "Tdarr containers started."

# ---------------------------------------------------------------------------
# Samba + NFS
# ---------------------------------------------------------------------------
msg_info "Installing Samba + NFS server..."
$STD apt-get -y -qq install samba nfs-kernel-server

if ! grep -q "^\[Media\]" /etc/samba/smb.conf 2>/dev/null; then
  cat >> /etc/samba/smb.conf <<'EOF'

[Media]
   path = /mnt/media
   browseable = yes
   read only = no
   guest ok = no
   create mask = 0664
   directory mask = 0775
EOF
fi

SMB_USER="tdarr"
SMB_PASS="${SMB_PASS:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)}"
id -u "${SMB_USER}" >/dev/null 2>&1 || $STD useradd -M -s /usr/sbin/nologin "${SMB_USER}"
set_smb_password() { (echo "${SMB_PASS}"; echo "${SMB_PASS}") | smbpasswd -a -s "${SMB_USER}"; }
$STD set_smb_password
$STD smbpasswd -e "${SMB_USER}"
$STD systemctl enable --now smbd nmbd

if ! grep -q "^/mnt/media" /etc/exports 2>/dev/null; then
  echo "/mnt/media *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
fi
$STD exportfs -ra
$STD systemctl enable --now nfs-kernel-server

echo "${SMB_USER}:${SMB_PASS}" > /root/tdarr_smb_credentials.txt
chmod 600 /root/tdarr_smb_credentials.txt

# ---------------------------------------------------------------------------
# Cockpit + file-sharing GUI (manage the Samba/NFS shares from a browser)
# ---------------------------------------------------------------------------
msg_info "Installing Cockpit share-management GUI..."
$STD apt-get -y -qq install cockpit
install_cockpit_file_sharing() { curl -fsSL https://repo.45drives.com/setup | bash; }
$STD install_cockpit_file_sharing || true
$STD apt-get -y -qq install cockpit-file-sharing cockpit-navigator || true
$STD systemctl enable --now cockpit.socket

msg_ok "Setup complete."
echo
echo "Samba user:     ${SMB_USER}"
echo "Samba password: ${SMB_PASS}  (also saved to /root/tdarr_smb_credentials.txt)"
echo "NFS export:     /mnt/media"
echo "Manage shares:  https://<container-ip>:9090 (Cockpit)"
[[ "${VERBOSE}" != "1" ]] && echo "Full install log: ${LOGFILE} (inside this container)"
