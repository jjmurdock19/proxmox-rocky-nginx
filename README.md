# Proxmox VE Helper Script — Rocky Linux NGINX Web Server

Spin up a ready-to-use **Rocky Linux + NGINX** web server in a Proxmox LXC container with one command, using the same kind of whiptail setup screens as the community Proxmox helper scripts.

## Quick start

Run this in the **Proxmox VE host shell** (as root):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jjmurdck19/proxmox-rocky-nginx/main/rocky-nginx.sh)"
```

## What it does

1. Lets you choose the **Rocky Linux version** from the templates Proxmox currently offers (8, 9, 10 …) and downloads the template if needed.
2. **Default** mode: sensible defaults, so you only pick packages.
   **Advanced** mode: customize everything below.
3. Creates and starts the container, then installs and configures the stack inside it.
4. Writes all connection details to `/root/webserver-info.txt` inside the container.

### Container options (Advanced)

| Setting | Default |
|---|---|
| Container ID | next free ID |
| Hostname | `rocky-web` |
| Type | Unprivileged (nesting + keyctl) |
| Root password | auto-generated (shown at the end) |
| Disk / Cores / RAM / Swap | 8 GB / 2 / 2048 MiB / 512 MiB |
| Storage | prompted if more than one pool |
| Bridge, IPv4 (DHCP/static), IPv6, VLAN, MTU, DNS, search domain | `vmbr0`, DHCP |
| Root SSH password login | off (key login allowed) |
| SSH public key for root | optional |
| Sudo admin user (owns the web root) | optional |
| Start on boot | yes |
| Timezone | same as the host |

### Web server options (Advanced)

| Setting | Default |
|---|---|
| Server name(s) | `_` (any name / IP) |
| Web root | `/var/www/html` or `/var/www/<domain>/public` |
| Upload limit (NGINX + PHP) | `64M` |
| HTTPS | HTTP only, self-signed, or self-signed + redirect |
| NGINX source | Rocky AppStream, nginx.org stable, or nginx.org mainline |
| Sample landing page | yes |
| Apply OS updates | yes |

### Optional packages

| Package | Notes |
|---|---|
| **PHP-FPM** | Common extensions, pool runs as `nginx`. On Rocky 8/9 you can choose PHP 8.1–8.5 from the Remi repo (Advanced). |
| **Composer** | Installer checksum-verified. Adds PHP automatically. |
| **MariaDB** / **MySQL** | Hardened (anonymous users and test DB removed). Pick one; they conflict. |
| **PostgreSQL** | Newest stream available; password (scram) auth on localhost. |
| **Redis** | Valkey on Rocky 10, where Redis was replaced. |
| **Node.js + npm** | Newest stream available. |
| **Adminer** | `/adminer/`, reachable from private/LAN IPs only. |
| **Certbot** | Plus the NGINX plugin (EPEL). |
| **firewalld** | Opens HTTP, HTTPS and SSH. |
| **Fail2ban** | SSH jail (adds firewalld automatically). |
| **dnf-automatic** | Daily automatic security updates. |
| **Git**, **CLI tools** | vim, nano, htop, wget, unzip, rsync, jq, tmux … |

In Advanced mode it can also create an **app database and user** on every SQL server you selected.

## After install

```bash
pct enter <CTID>
cat /root/webserver-info.txt        # URL, credentials, paths

nginx-site add example.com          # new vhost at /var/www/example.com/public
nginx-site list
nginx-site remove example.com
certbot --nginx -d example.com      # real certificate once DNS points here
```

## Notes

- **Rocky Linux 10** needs an **x86-64-v3** CPU (AVX2, etc.) and a current Proxmox VE (8.4+/9). The script warns you if your CPU doesn't qualify.
- **firewalld inside an LXC** doesn't work on every setup. If it can't start, the script warns you; the Proxmox firewall is the usual alternative.
- If the nginx.org repo isn't available for your Rocky version, the script falls back to AppStream NGINX and tells you.
- If anything fails, the script shows the last lines of the install log and offers to delete the half-built container.

## License

MIT
