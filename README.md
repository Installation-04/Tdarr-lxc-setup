# Tdarr LXC Setup for Proxmox VE

Spin up a Debian 13 (trixie) LXC container on Proxmox with [Tdarr](https://tdarr.io/)
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

The script auto-detects the GPU on the host, then asks **Use Default
Settings?** — same as the community-scripts / ProxmoxVE helper scripts.
Answer Yes to use the defaults below as-is (`4` vCPU / `4096`MB RAM /
`12`GB disk, unprivileged, DHCP), or No to walk through the full `whiptail`
wizard for container ID, hostname, resources, networking, storage paths,
GPU passthrough, and whether to deploy a full Tdarr server or just a node.
Nothing runs until you confirm the summary screen at the end.

It then creates the container, deploys Tdarr, and sets up the shares + GUI.
At the end it prints the Tdarr Web UI URL, the Cockpit GUI URL, and the
generated Samba credentials.

### Wizard questions

| Screen | Asks for | Default |
|---|---|---|
| GPU passthrough | Enable passthrough for the detected GPU? (skipped if none found) | Yes |
| Container ID | CTID for the new container | next free ID |
| Hostname | Container hostname | `tdarr` |
| CPU cores | vCPU cores | `4` |
| Memory | RAM in MB | `4096` |
| Swap | Swap in MB | `512` |
| Disk size | Root disk size in GB | `12` |
| Container storage | Proxmox storage for the container disk | `local-lvm` |
| Template storage | Proxmox storage holding the LXC template | `local` |
| Network bridge | Bridge to attach to | `vmbr0` |
| VLAN tag | VLAN tag for the container's network interface (blank = none) | *(none)* |
| Networking | DHCP or static IP (asks for IP/gateway if static) | DHCP |
| Container privilege | Unprivileged or privileged | Unprivileged |
| Media library path | Host directory bind-mounted as the media library | `/mnt/tdarr_media` |
| Tdarr config path | Host directory bind-mounted for server config/logs | `/mnt/tdarr_config` |
| Tdarr mode | Full Server + local Node, or Node-only joining a remote server | Server + local Node |
| Remote server (node mode only) | IP/hostname and port of the existing Tdarr server | — |
| Node name | Name shown in the Tdarr UI | container hostname |

### Unattended / scripted installs

If you'd rather skip the GUI and drive the installer from env vars (e.g. in
CI or a repeatable build pipeline), set `NONINTERACTIVE=1` — every setting
below falls back to its default unless overridden:

```bash
NONINTERACTIVE=1 CTID=150 CT_HOSTNAME=tdarr var_ram=8192 var_cpu=6 \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/installation-04/tdarr-lxc-setup/main/install.sh)"
```

> **Note:** CPU/RAM/disk/privilege/OS-template come from the `var_*`
> settings below, not from separate `CORES`/`RAM`/`DISK_SIZE`/`UNPRIVILEGED`
> variables — this matches the community-scripts/ProxmoxVE convention the
> installer follows. Everything else in the table is a plain env var.

| Variable | Default | Description |
|---|---|---|
| `CTID` | next free ID | Container ID |
| `CT_HOSTNAME` | `tdarr` | Container hostname |
| `var_cpu` | `4` | vCPU cores |
| `var_ram` | `4096` | RAM in MB |
| `SWAP` | `512` | Swap in MB |
| `var_disk` | `12` | Root disk size in GB |
| `var_os` | `debian` | LXC template OS |
| `var_version` | `12` | LXC template OS version |
| `var_unprivileged` | `1` | `0` for a privileged container if you hit GPU permission issues |
| `var_tags` | `media;transcode` | Proxmox tags applied to the container |
| `STORAGE` | `local-lvm` | Proxmox storage for the container disk |
| `TEMPLATE_STORAGE` | `local` | Proxmox storage holding the LXC template |
| `BRIDGE` | `vmbr0` | Network bridge |
| `VLAN_TAG` | *(none)* | VLAN tag for the container's network interface; leave unset for no VLAN |
| `NET_MODE` | `dhcp` | `dhcp` or `static` |
| `STATIC_IP` / `STATIC_GW` | *(required if `NET_MODE=static`)* | e.g. `192.168.1.50/24` / `192.168.1.1` |
| `MEDIA_HOST_PATH` | `/mnt/tdarr_media` | Host directory bind-mounted to `/mnt/media` in the container (point this at your existing media pool) |
| `CONFIG_HOST_PATH` | `/mnt/tdarr_config` | Host directory bind-mounted to `/mnt/config` (Tdarr server/config/logs) |
| `TDARR_MODE` | `server` | `server` (Server + local Node) or `node` (Node only, joins a remote server) |
| `REMOTE_SERVER_IP` | *(required for `node`)* | IP/hostname of the existing Tdarr server |
| `REMOTE_SERVER_PORT` | `8266` | Server API port of the existing Tdarr server |
| `NODE_NAME` | `$CT_HOSTNAME` | Name this node shows up as in the Tdarr UI |
| `ENABLE_GPU_PASSTHROUGH` | `1` | Set to `0` to skip passthrough even if a GPU was detected |

GPU detection always runs automatically, in both modes — `NONINTERACTIVE=1`
only skips the wizard's question screens.

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

Re-run the installer against an existing container in update mode (pulls
fresh images and restarts the stack — it does not touch the container's
config, resources, or shares):

```bash
CTID=<CTID> bash -c "$(curl -fsSL https://raw.githubusercontent.com/installation-04/tdarr-lxc-setup/main/install.sh)" -- --update
```

or equivalently:

```bash
CTID=<CTID> UPDATE=1 ./install.sh
```

This is the same thing `pct exec <CTID> -- bash -c "cd /opt/tdarr && docker compose pull && docker compose up -d"` does manually, if you'd rather run it by hand.

## Troubleshooting

**`mkdir: cannot create directory '/mnt/config/...': Permission denied`
during setup** — unprivileged containers (the default) map their root user
to a subordinate uid/gid on the Proxmox host, so bind-mounted host
directories need to be owned by that mapped id, not real root. The
installer now `chown`s `MEDIA_HOST_PATH`/`CONFIG_HOST_PATH` to the host's
default subordinate id (from `/etc/subuid`/`/etc/subgid`, normally
`100000`) before creating the container. If you still hit this on a host
with custom subuid/subgid ranges, either fix the ownership manually
(`chown -R <mapped-uid>:<mapped-gid> <path>`) or re-run with
`var_unprivileged=0` (or answer No to "Create an UNPRIVILEGED container?"
in the wizard) for a privileged container.
