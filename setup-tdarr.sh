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

C_RESET="\e[0m"; C_GREEN="\e[32m"; C_BLUE="\e[36m"
msg() { echo -e "${C_BLUE}[setup]${C_RESET} $*"; }
ok()  { echo -e "${C_GREEN}[ok]${C_RESET} $*"; }

export DEBIAN_FRONTEND=noninteractive

msg "Updating base system..."
apt-get update -qq
apt-get -y -qq upgrade

msg "Installing base packages..."
apt-get -y -qq install curl gnupg ca-certificates lsb-release apt-transport-https software-properties-common >/dev/null

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  msg "Installing Docker..."
  curl -fsSL https://get.docker.com | sh >/dev/null
  systemctl enable --now docker >/dev/null 2>&1
fi
ok "Docker ready: $(docker --version)"

# ---------------------------------------------------------------------------
# GPU userland (VAAPI / NVIDIA) inside the container
# ---------------------------------------------------------------------------
if [[ "${HAS_VAAPI}" == "1" ]]; then
  msg "Installing VAAPI userland (Intel/AMD hw transcode)..."
  apt-get -y -qq install va-driver-all vainfo intel-media-va-driver-non-free ocl-icd-libopencl1 >/dev/null || true
fi

if [[ "${HAS_NVIDIA}" == "1" && -n "${NVIDIA_DRIVER_VERSION}" ]]; then
  msg "Installing matching NVIDIA userland driver (${NVIDIA_DRIVER_VERSION})..."
  apt-get -y -qq install build-essential pkg-config libglvnd-dev >/dev/null || true
  RUNFILE="NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run"
  if curl -fsSL -o "/tmp/${RUNFILE}" "https://download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_DRIVER_VERSION}/${RUNFILE}"; then
    sh "/tmp/${RUNFILE}" --no-kernel-module --silent --no-nouveau-check --no-nvidia-modprobe --no-systemd || \
      echo "[warn] NVIDIA userland install failed - driver version may not be publicly hosted; verify host/container driver match manually."
    rm -f "/tmp/${RUNFILE}"
  else
    echo "[warn] Could not download NVIDIA driver ${NVIDIA_DRIVER_VERSION} - skipping automatic install."
  fi
  # NVIDIA Container Toolkit so Docker can see the GPU
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -qq
  apt-get -y -qq install nvidia-container-toolkit >/dev/null || echo "[warn] nvidia-container-toolkit install failed."
  nvidia-ctk runtime configure --runtime=docker >/dev/null 2>&1 || true
  systemctl restart docker
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
  msg "Writing docker-compose.yml for Tdarr Server + local Node..."
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
  msg "Writing docker-compose.yml for Tdarr Node only (remote server ${REMOTE_SERVER_IP}:${REMOTE_SERVER_PORT})..."
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

msg "Starting Tdarr..."
(cd /opt/tdarr && docker compose up -d)
ok "Tdarr containers started."

# ---------------------------------------------------------------------------
# Samba + NFS
# ---------------------------------------------------------------------------
msg "Installing Samba + NFS server..."
apt-get -y -qq install samba nfs-kernel-server >/dev/null

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
id -u "${SMB_USER}" >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin "${SMB_USER}"
(echo "${SMB_PASS}"; echo "${SMB_PASS}") | smbpasswd -a -s "${SMB_USER}" >/dev/null
smbpasswd -e "${SMB_USER}" >/dev/null
systemctl enable --now smbd nmbd >/dev/null 2>&1

if ! grep -q "^/mnt/media" /etc/exports 2>/dev/null; then
  echo "/mnt/media *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
fi
exportfs -ra
systemctl enable --now nfs-kernel-server >/dev/null 2>&1

echo "${SMB_USER}:${SMB_PASS}" > /root/tdarr_smb_credentials.txt
chmod 600 /root/tdarr_smb_credentials.txt

# ---------------------------------------------------------------------------
# Cockpit + file-sharing GUI (manage the Samba/NFS shares from a browser)
# ---------------------------------------------------------------------------
msg "Installing Cockpit share-management GUI..."
apt-get -y -qq install cockpit >/dev/null
curl -fsSL https://repo.45drives.com/setup | bash >/dev/null 2>&1 || true
apt-get -y -qq install cockpit-file-sharing cockpit-navigator >/dev/null 2>&1 || true
systemctl enable --now cockpit.socket >/dev/null 2>&1

ok "Setup complete."
echo
echo "Samba user:     ${SMB_USER}"
echo "Samba password: ${SMB_PASS}  (also saved to /root/tdarr_smb_credentials.txt)"
echo "NFS export:     /mnt/media"
echo "Manage shares:  https://<container-ip>:9090 (Cockpit)"
