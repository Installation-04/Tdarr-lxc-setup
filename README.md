# Tdarr LXC Setup for Proxmox VE

Spin up a Debian 12 LXC container on Proxmox with [Tdarr](https://tdarr.io/)
pre-installed, automatic GPU passthrough (NVIDIA / Intel / AMD) for hardware
transcoding, and Samba + NFS shares you can manage from a small web GUI.

## What you get

- A new LXC container (Docker inside, Tdarr running via Docker Compose)
- **Automatic GPU detection on the Proxmox host**: NVIDIA (via `nvidia-smi`)
  or Intel/AMD VAAPI (via `/dev/dri`) — passthrough is wired into the
  container config and the matching userland driver is installed for you
- Either a full **Tdarr Server + local Node**, or a **Tdarr Node only** that
  connects to a Tdarr server you already have running elsewhere
- Samba (`\\<ip>\Media`) and NFS (`<ip>:/mnt/media`) shares for your media
  library
- [Cockpit](https://cockpit-project.org/) with the
  [45Drives file-sharing module](https://github.com/45Drives/cockpit-file-sharing)
  installed — a small web GUI at `https://<ip>:9090` for managing the Samba/NFS
  shares without touching the command line

## One-time run

Run this **on the Proxmox VE host** shell:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/installation-04/tdarr-lxc-setup/main/install.sh)"
```

That's it — the script creates the container, detects your GPU, deploys
Tdarr, and sets up the shares + GUI. At the end it prints the Tdarr Web UI
URL, the Cockpit GUI URL, and the generated Samba credentials.

## Configuration (optional env vars)

Everything has a sensible default, but you can override any of these by
setting env vars before running the one-liner, e.g.:

```bash
CTID=150 CT_HOSTNAME=tdarr RAM=8192 CORES=6 \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/installation-04/tdarr-lxc-setup/main/install.sh)"
```

| Variable | Default | Description |
|---|---|---|
| `CTID` | next free ID | Container ID |
| `CT_HOSTNAME` | `tdarr` | Container hostname |
| `CORES` | `4` | vCPU cores |
| `RAM` | `4096` | RAM in MB |
| `SWAP` | `512` | Swap in MB |
| `DISK_SIZE` | `12` | Root disk size in GB |
| `STORAGE` | `local-lvm` | Proxmox storage for the container disk |
| `TEMPLATE_STORAGE` | `local` | Proxmox storage holding the LXC template |
| `BRIDGE` | `vmbr0` | Network bridge |
| `NET_CONFIG` | DHCP on `vmbr0` | Full `pct` net string, override for static IP |
| `MEDIA_HOST_PATH` | `/mnt/tdarr_media` | Host directory bind-mounted to `/mnt/media` in the container (point this at your existing media pool) |
| `CONFIG_HOST_PATH` | `/mnt/tdarr_config` | Host directory bind-mounted to `/mnt/config` (Tdarr server/config/logs) |
| `UNPRIVILEGED` | `1` | `0` for a privileged container if you hit GPU permission issues |

### Server vs. Node-only mode

By default the container runs a full **Tdarr Server + internal Node**
(everything in one box). If you already have a Tdarr server elsewhere and
just want this LXC to be an extra transcode **Node** (e.g. a GPU box that
joins your existing Tdarr install), set:

```bash
TDARR_MODE=node REMOTE_SERVER_IP=192.168.1.50 REMOTE_SERVER_PORT=8266 \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/installation-04/tdarr-lxc-setup/main/install.sh)"
```

| Variable | Default | Description |
|---|---|---|
| `TDARR_MODE` | `server` | `server` (Server + local Node) or `node` (Node only, joins a remote server) |
| `REMOTE_SERVER_IP` | *(required for `node`)* | IP/hostname of the existing Tdarr server |
| `REMOTE_SERVER_PORT` | `8266` | Server API port of the existing Tdarr server |
| `NODE_NAME` | `$CT_HOSTNAME` | Name this node shows up as in the Tdarr UI |

## GPU passthrough details

The installer inspects the **Proxmox host**, not the container:

- **NVIDIA**: if `nvidia-smi` is available and reports a GPU, the container
  gets the NVIDIA character devices bind-mounted, the matching userland
  driver (same version as the host) is installed inside the container, and
  the NVIDIA Container Toolkit is configured so Docker can hand the GPU to
  the Tdarr container. The kernel module stays on the host — the container
  only needs the matching userland (`--no-kernel-module` install).
- **Intel / AMD (VAAPI)**: if `/dev/dri/renderD*` exists and the host GPU is
  Intel or AMD, `/dev/dri` is bind-mounted into the container and the VAAPI
  userland (`va-driver-all`, `intel-media-va-driver-non-free`, `vainfo`) is
  installed.
- **No GPU**: Tdarr still deploys, and falls back to CPU (software)
  transcoding.

You can verify hardware transcode is available inside the container with:

```bash
pct exec <CTID> -- vainfo         # Intel/AMD
pct exec <CTID> -- nvidia-smi     # NVIDIA
```

Then enable the relevant hardware-accelerated transcode plugin/options
inside the Tdarr Web UI (Library → Transcode Options).

## Files

- `install.sh` — runs on the Proxmox host: creates the LXC container,
  detects the GPU, configures passthrough, and hands off to `setup-tdarr.sh`
- `setup-tdarr.sh` — runs inside the new container: installs Docker,
  deploys Tdarr (server+node or node-only), sets up Samba/NFS, and installs
  the Cockpit share-management GUI

## Post-install

- Tdarr Web UI: `http://<container-ip>:8265`
- Share management GUI (Cockpit): `https://<container-ip>:9090`
- Samba share: `\\<container-ip>\Media` (credentials printed at the end of
  setup, also saved to `/root/tdarr_smb_credentials.txt` inside the
  container)
- NFS export: `<container-ip>:/mnt/media`

## Updating Tdarr

```bash
pct exec <CTID> -- bash -c "cd /opt/tdarr && docker compose pull && docker compose up -d"
```
