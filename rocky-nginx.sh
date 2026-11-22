#!/usr/bin/env bash
# =============================================================================
#  Rocky Linux NGINX Web Server — Proxmox VE LXC Helper Script
#
#  Run on a Proxmox VE host shell (as root):
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USER/proxmox-rocky-nginx/main/rocky-nginx.sh)"
#
#  Creates a Rocky Linux LXC container and installs/configures NGINX plus any
#  optional stack components you pick (PHP, MariaDB/MySQL, PostgreSQL, Redis,
#  Node.js, Composer, Certbot, Adminer, firewalld, Fail2ban, auto-updates ...).
#
#  License: MIT
# =============================================================================
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

SCRIPT_VERSION="1.0.0"
APP="Rocky Linux NGINX Web Server"
BACKTITLE="Proxmox VE Helper Script  —  ${APP}  (v${SCRIPT_VERSION})"

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
YW=$'\033[33m'; GN=$'\033[1;92m'; RD=$'\033[01;31m'; BL=$'\033[36m'
BOLD=$'\033[1m'; CL=$'\033[m'
CM="${GN}✔${CL}"; CROSS="${RD}✖${CL}"; INFO="${YW}➜${CL}"

msg_info()  { printf ' %s %s...' "$INFO" "$1"; }
msg_ok()    { printf '\r\033[K %s %s\n' "$CM" "$1"; }
msg_warn()  { printf '\r\033[K %s%s!%s %s\n' "$BOLD" "$YW" "$CL" "$1"; }
msg_error() { printf '\r\033[K %s %s%s%s\n' "$CROSS" "$RD" "$1" "$CL" >&2; }

header_info() {
  clear
  cat <<"EOF"
    ____             __            _   _______________   ___  __
   / __ \____  _____/ /____  __   / | / / ____/  _/ | / / |/ /
  / /_/ / __ \/ ___/ //_/ / / /  /  |/ / / __ / //  |/ /|   /
 / _, _/ /_/ / /__/ ,< / /_/ /  / /|  / /_/ // // /|  //   |
/_/ |_|\____/\___/_/|_|\__, /  /_/ |_/\____/___/_/ |_//_/|_|
                      /____/      Proxmox VE LXC Helper Script
EOF
  echo
}

# ----------------------------------------------------------------------------
# Error / exit handling
# ----------------------------------------------------------------------------
CTID=""
CT_CREATED=0
TMP_FILES=()

cleanup() {
  local f
  for f in "${TMP_FILES[@]:-}"; do
    [[ -n $f ]] && rm -f -- "$f"
  done
  return 0
}
trap cleanup EXIT

on_error() {
  local ec=$1 line=$2 cmd=$3
  trap - ERR
  echo
  msg_error "Failed (exit ${ec}) at line ${line}: ${cmd}"
  if [[ $CT_CREATED == 1 && -n $CTID ]]; then
    if whiptail --backtitle "$BACKTITLE" --title "Setup failed" --yesno \
      "Setup failed.\n\nRemove the partially created container ${CTID}?" 10 60; then
      pct stop "$CTID" >/dev/null 2>&1 || true
      pct destroy "$CTID" --purge >/dev/null 2>&1 || pct destroy "$CTID" >/dev/null 2>&1 || true
      msg_ok "Removed container ${CTID}"
    else
      msg_warn "Container ${CTID} was left in place for troubleshooting"
    fi
  fi
  exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

exit_script() {
  clear
  echo -e "\n ${YW}User exited the script — nothing was created.${CL}\n"
  exit 0
}

# ----------------------------------------------------------------------------
# whiptail wrappers (assign results to globals so Cancel exits the main shell)
# ----------------------------------------------------------------------------
msgbox() { whiptail --backtitle "$BACKTITLE" --title "${2:-Notice}" --msgbox "$1" 12 72; }

ask_input() { # var title prompt default
  local __v=$1 __out
  __out=$(whiptail --backtitle "$BACKTITLE" --title "$2" --inputbox "$3" 12 76 "${4-}" 3>&1 1>&2 2>&3) || exit_script
  printf -v "$__v" '%s' "$__out"
}

ask_password() { # var title prompt   (blank allowed => auto-generate)
  local __v=$1 p1 p2
  while true; do
    p1=$(whiptail --backtitle "$BACKTITLE" --title "$2" --passwordbox "$3" 12 76 3>&1 1>&2 2>&3) || exit_script
    if [[ -z $p1 ]]; then printf -v "$__v" '%s' ""; return 0; fi
    if (( ${#p1} < 5 )); then msgbox "Password must be at least 5 characters." "Password"; continue; fi
    if [[ $p1 == *$'\n'* || $p1 == *" "* ]]; then msgbox "Password cannot contain spaces." "Password"; continue; fi
    p2=$(whiptail --backtitle "$BACKTITLE" --title "$2" --passwordbox "Confirm password:" 10 76 3>&1 1>&2 2>&3) || exit_script
    if [[ $p1 == "$p2" ]]; then break; fi
    msgbox "Passwords do not match. Try again." "Password"
  done
  printf -v "$__v" '%s' "$p1"
}

ask_menu() { # var title prompt default  tag desc [tag desc ...]
  local __v=$1 title=$2 prompt=$3 def=$4 __out n
  shift 4
  n=$(( $# / 2 )); if (( n > 10 )); then n=10; fi
  __out=$(whiptail --backtitle "$BACKTITLE" --title "$title" --default-item "$def" \
    --menu "$prompt" $(( n + 10 )) 78 "$n" "$@" 3>&1 1>&2 2>&3) || exit_script
  printf -v "$__v" '%s' "$__out"
}

ask_yesno() { # title prompt default(yes|no)  -> return 0 yes / 1 no
  local extra=()
  if [[ ${3:-yes} == no ]]; then extra=(--defaultno); fi
  whiptail --backtitle "$BACKTITLE" --title "$1" "${extra[@]}" --yesno "$2" 11 74
}

ask_checklist() { # var title prompt  tag desc ON|OFF ...
  local __v=$1 title=$2 prompt=$3 __out n
  shift 3
  n=$(( $# / 3 )); if (( n > 14 )); then n=14; fi
  __out=$(whiptail --backtitle "$BACKTITLE" --title "$title" --separate-output \
    --checklist "$prompt" $(( n + 9 )) 80 "$n" "$@" 3>&1 1>&2 2>&3) || exit_script
  printf -v "$__v" '%s' "${__out//$'\n'/ }"
}

# ----------------------------------------------------------------------------
# Validators / utils
# ----------------------------------------------------------------------------
is_int()         { [[ $1 =~ ^[0-9]+$ ]]; }
valid_hostname() { [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; }
valid_ip4()      { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
valid_cidr4()    { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; }
valid_cidr6()    { [[ $1 =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]]; }
valid_dbname()   { [[ $1 =~ ^[a-z_][a-z0-9_]{0,31}$ ]]; }
valid_secret()   { [[ $1 =~ ^[A-Za-z0-9@#%^*_+=.,:!?-]+$ ]]; }
gen_pw()         { openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | cut -c1-"${1:-20}"; }
ctid_free()      { pvesh get /cluster/nextid --vmid "$1" >/dev/null 2>&1; }

has_pkg() { [[ " $PKGS " == *" $1 "* ]]; }
add_pkg() { if ! has_pkg "$1"; then PKGS="${PKGS:+$PKGS }$1"; fi; }
del_pkg() { PKGS=" $PKGS "; PKGS=${PKGS// $1 / }; PKGS=$(echo $PKGS); }

check_x86_64_v3() {
  local flags f
  flags="$(grep -m1 '^flags' /proc/cpuinfo) "
  for f in avx2 bmi1 bmi2 fma movbe f16c; do
    [[ $flags == *" $f "* ]] || return 1
  done
}

# ----------------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------------
preflight() {
  if [[ $EUID -ne 0 ]]; then msg_error "Please run this script as root on the Proxmox VE host."; exit 1; fi
  if ! command -v pct >/dev/null || ! command -v pveversion >/dev/null; then
    msg_error "This doesn't look like a Proxmox VE host (pct/pveversion not found)."; exit 1
  fi
  if [[ $(dpkg --print-architecture) != amd64 ]]; then
    msg_error "Only amd64 Proxmox hosts are supported."; exit 1
  fi
  for c in whiptail pveam pvesm pvesh openssl; do
    if ! command -v "$c" >/dev/null; then msg_error "Required command '$c' not found."; exit 1; fi
  done
  local pvemajor
  pvemajor=$(pveversion | sed -nE 's|.*pve-manager/([0-9]+)\..*|\1|p')
  if [[ -z $pvemajor ]] || (( pvemajor < 8 )); then
    if ! ask_yesno "Unsupported Proxmox VE" "This script is tested on Proxmox VE 8 and 9.\nDetected: $(pveversion | head -n1)\n\nContinue anyway?" no; then
      exit_script
    fi
  fi
}

# ----------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------
set_defaults() {
  CTID=$(pvesh get /cluster/nextid)
  CT_HOSTNAME="rocky-web"
  UNPRIV=1
  ROOT_PW=""
  DISK=8
  CORES=2
  RAM=2048
  SWAP=512
  BRIDGE="vmbr0"
  IP4="dhcp"; GW4=""
  IP6=""; GW6=""
  VLAN=""; MTU=""
  DNS=""; SEARCHDOMAIN=""
  SSH_KEY=""
  ROOT_SSH="no"
  ONBOOT=1
  ADMIN_USER=""; ADMIN_PASS=""
  SERVER_NAMES="_"
  SITE_NAME="default"
  WEB_ROOT="/var/www/html"
  MAX_BODY="64M"
  HTTPS_MODE="none"
  NGINX_SOURCE="appstream"
  DO_UPDATE="yes"
  SAMPLE_PAGE="yes"
  PKGS=""
  PHP_SOURCE="appstream"; PHP_VERSION=""
  CREATE_DB="no"; DB_NAME=""; DB_USER=""; DB_PASS=""
  MYSQL_ROOT_PASS=""
}

# ----------------------------------------------------------------------------
# Storage + template selection
# ----------------------------------------------------------------------------
select_storage() { # var content label
  local __v=$1 content=$2 label=$3 name type status total used avail rest
  local -a menu=()
  local first="" count=0
  while read -r name type status total used avail rest; do
    [[ $name == Name || $status != active ]] && continue
    menu+=("$name" "$(printf 'Type: %-9s Free: %s' "$type" "$(numfmt --to=iec --from-unit=1024 "$avail" 2>/dev/null || echo "?")")")
    [[ -z $first ]] && first=$name
    count=$((count + 1))
  done < <(pvesm status -content "$content" 2>/dev/null || true)

  if (( count == 0 )); then
    msg_error "No active storage supports '${content}' (${label}). Enable it under Datacenter → Storage."
    exit 1
  elif (( count == 1 )); then
    printf -v "$__v" '%s' "$first"
  else
    ask_menu "$__v" "Storage — ${label}" "Select the storage pool for the ${label}:" "$first" "${menu[@]}"
  fi
}

declare -A TPL_BY_MAJOR=()

discover_templates() {
  msg_info "Refreshing Proxmox template catalogue"
  pveam update >/dev/null 2>&1 || true
  msg_ok "Template catalogue refreshed"

  local t major
  while read -r t; do
    [[ -z $t ]] && continue
    major=$(sed -nE 's/^rockylinux-([0-9]+)[-._].*/\1/p' <<<"$t")
    [[ -z $major ]] && continue
    TPL_BY_MAJOR[$major]=$t      # input is version-sorted → last (newest) wins
  done < <(
    {
      pveam available --section system 2>/dev/null | awk '{print $2}'
      pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk 'NR>1{print $1}' | sed 's|.*/||'
    } | grep -E '^rockylinux-[0-9]+.*amd64' | sort -uV || true
  )

  if (( ${#TPL_BY_MAJOR[@]} == 0 )); then
    msg_error "No Rocky Linux templates found (pveam available). Check the host's internet access."
    exit 1
  fi
}

select_rocky_version() {
  local -a menu=()
  local m newest=""
  for m in $(printf '%s\n' "${!TPL_BY_MAJOR[@]}" | sort -n); do
    menu+=("$m" "Rocky Linux ${m}   (${TPL_BY_MAJOR[$m]})")
    newest=$m
  done
  while true; do
    ask_menu RL_MAJOR "Rocky Linux Version" "Choose the Rocky Linux release for the container:" "$newest" "${menu[@]}"
    if (( RL_MAJOR >= 10 )) && ! check_x86_64_v3; then
      if ask_yesno "CPU compatibility" "Rocky Linux ${RL_MAJOR} requires an x86-64-v3 CPU (AVX2, BMI2, FMA, MOVBE).\nThis host's CPU does not appear to support it, so the container will likely fail to start.\n\nUse Rocky Linux ${RL_MAJOR} anyway?" no; then
        break
      fi
      continue
    fi
    break
  done
  TEMPLATE=${TPL_BY_MAJOR[$RL_MAJOR]}
}

# ----------------------------------------------------------------------------
# Optional packages
# ----------------------------------------------------------------------------
select_packages() {
  local redis_label="Redis in-memory cache"
  if (( RL_MAJOR >= 10 )); then redis_label="Valkey (Redis-compatible) cache"; fi
  while true; do
    ask_checklist PKGS "Optional Packages" "Space = toggle, Enter = confirm. NGINX is always installed." \
      PHP        "PHP-FPM + common extensions"                   ON  \
      COMPOSER   "Composer (PHP dependency manager)"             OFF \
      MARIADB    "MariaDB server (MySQL-compatible)"             ON  \
      MYSQL      "MySQL Community server"                        OFF \
      POSTGRESQL "PostgreSQL server"                             OFF \
      REDIS      "$redis_label"                                  OFF \
      NODEJS     "Node.js + npm"                                 OFF \
      ADMINER    "Adminer DB web UI at /adminer (LAN only)"      OFF \
      CERTBOT    "Certbot (Let's Encrypt) + NGINX plugin"        OFF \
      FIREWALLD  "firewalld (opens HTTP/HTTPS/SSH)"              OFF \
      FAIL2BAN   "Fail2ban SSH brute-force protection"           OFF \
      AUTOUPDATE "dnf-automatic daily security updates"          OFF \
      GIT        "Git"                                           ON  \
      TOOLS      "CLI tools: vim nano htop wget unzip rsync jq"  ON
    if has_pkg MARIADB && has_pkg MYSQL; then
      msgbox "MariaDB and MySQL can't be installed together (they conflict).\nPlease pick only one." "Conflict"
      continue
    fi
    break
  done

  local notes=""
  if { has_pkg COMPOSER || has_pkg ADMINER; } && ! has_pkg PHP; then add_pkg PHP; notes+="• PHP added (required by Composer/Adminer)\n"; fi
  if has_pkg FAIL2BAN && ! has_pkg FIREWALLD; then add_pkg FIREWALLD; notes+="• firewalld added (used by Fail2ban to ban IPs)\n"; fi
  if has_pkg ADMINER && ! { has_pkg MARIADB || has_pkg MYSQL || has_pkg POSTGRESQL; }; then
    notes+="• Adminer selected without a database server — it can still manage remote DBs\n"
  fi
  if [[ -n $notes ]]; then msgbox "Adjusted your selection:\n\n${notes}" "Dependencies"; fi
}

configure_package_options() { # advanced only
  if has_pkg PHP; then
    if (( RL_MAJOR < 10 )); then
      ask_menu PHP_SOURCE "PHP Version" "Where should PHP come from?" "appstream" \
        appstream "Rocky AppStream (newest stream available)" \
        remi-8.1  "PHP 8.1 (Remi repository)" \
        remi-8.2  "PHP 8.2 (Remi repository)" \
        remi-8.3  "PHP 8.3 (Remi repository)" \
        remi-8.4  "PHP 8.4 (Remi repository)" \
        remi-8.5  "PHP 8.5 (Remi repository)"
      if [[ $PHP_SOURCE == remi-* ]]; then PHP_VERSION=${PHP_SOURCE#remi-}; PHP_SOURCE=remi; fi
    else
      msgbox "On Rocky Linux ${RL_MAJOR}, PHP is installed from AppStream (the Remi module method isn't used on EL10)." "PHP Version"
    fi
  fi

  if has_pkg MARIADB || has_pkg MYSQL || has_pkg POSTGRESQL; then
    if ask_yesno "Application Database" "Create a database and user for your web app?\n(Created on every SQL server you selected.)" yes; then
      CREATE_DB="yes"
      DB_NAME="webapp"; DB_USER="webapp"
      while true; do
        ask_input DB_NAME "Database" "Database name (lowercase letters, digits, _):" "$DB_NAME"
        valid_dbname "$DB_NAME" && break; msgbox "Invalid database name." "Database"
      done
      while true; do
        ask_input DB_USER "Database" "Database user (lowercase letters, digits, _):" "$DB_USER"
        valid_dbname "$DB_USER" && break; msgbox "Invalid user name." "Database"
      done
      while true; do
        ask_password DB_PASS "Database" "Password for '${DB_USER}' (leave blank to auto-generate):"
        if [[ -z $DB_PASS ]] || valid_secret "$DB_PASS"; then break; fi
        msgbox "Allowed characters: letters, digits and @#%^*_+=.,:!?-" "Database"
      done
    fi
  fi
}

# ----------------------------------------------------------------------------
# Advanced settings
# ----------------------------------------------------------------------------
advanced_settings() {
  # --- Container ---
  while true; do
    ask_input CTID "Container ID" "Container ID:" "$CTID"
    if is_int "$CTID" && (( CTID >= 100 )) && ctid_free "$CTID"; then break; fi
    msgbox "ID ${CTID} is invalid or already in use." "Container ID"
  done
  while true; do
    ask_input CT_HOSTNAME "Hostname" "Container hostname:" "$CT_HOSTNAME"
    valid_hostname "$CT_HOSTNAME" && break; msgbox "Invalid hostname (letters, digits, hyphens)." "Hostname"
  done
  local ctype
  ask_menu ctype "Container Type" "Choose the container type:" "1" \
    1 "Unprivileged (recommended)" \
    0 "Privileged"
  UNPRIV=$ctype
  ask_password ROOT_PW "Root Password" "Root password (leave blank to auto-generate):"

  # --- Resources ---
  while true; do ask_input DISK  "Disk Size"  "Root disk size in GB:" "$DISK";  is_int "$DISK"  && (( DISK  >= 2 ))  && break; msgbox "Enter a whole number ≥ 2."; done
  while true; do ask_input CORES "CPU Cores"  "Number of CPU cores:"  "$CORES"; is_int "$CORES" && (( CORES >= 1 ))  && break; msgbox "Enter a whole number ≥ 1."; done
  while true; do ask_input RAM   "Memory"     "RAM in MiB:"           "$RAM";   is_int "$RAM"   && (( RAM   >= 256 )) && break; msgbox "Enter a whole number ≥ 256."; done
  while true; do ask_input SWAP  "Swap"       "Swap in MiB:"          "$SWAP";  is_int "$SWAP" && break; msgbox "Enter a whole number."; done

  # --- Network ---
  local -a bridges=() bmenu=()
  local b
  mapfile -t bridges < <(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -vE '^(fwbr|fwpr|fwln)' | sort -V || true)
  if (( ${#bridges[@]} > 1 )); then
    for b in "${bridges[@]}"; do bmenu+=("$b" "Linux bridge"); done
    ask_menu BRIDGE "Network Bridge" "Select the bridge:" "$BRIDGE" "${bmenu[@]}"
  elif (( ${#bridges[@]} == 1 )); then
    BRIDGE=${bridges[0]}
  fi

  local ipmode
  ask_menu ipmode "IPv4" "IPv4 configuration:" "dhcp" dhcp "DHCP" static "Static IP"
  if [[ $ipmode == static ]]; then
    while true; do ask_input IP4 "IPv4 Address" "Static IPv4 in CIDR notation (e.g. 192.168.1.50/24):" "${IP4/dhcp/}"; valid_cidr4 "$IP4" && break; msgbox "Invalid CIDR address."; done
    while true; do ask_input GW4 "IPv4 Gateway" "Gateway IP (e.g. 192.168.1.1):" "$GW4"; valid_ip4 "$GW4" && break; msgbox "Invalid gateway IP."; done
  else
    IP4="dhcp"; GW4=""
  fi

  local ip6mode
  ask_menu ip6mode "IPv6" "IPv6 configuration:" "none" none "Disabled / not configured" auto "SLAAC (auto)" dhcp "DHCPv6" static "Static IPv6"
  case $ip6mode in
    none) IP6="" ;;
    auto|dhcp) IP6=$ip6mode ;;
    static)
      while true; do ask_input IP6 "IPv6 Address" "Static IPv6 in CIDR notation:" ""; valid_cidr6 "$IP6" && break; msgbox "Invalid IPv6 CIDR."; done
      ask_input GW6 "IPv6 Gateway" "IPv6 gateway (blank for none):" "" ;;
  esac

  while true; do ask_input VLAN "VLAN" "VLAN tag (blank for none):" "$VLAN"; [[ -z $VLAN ]] || { is_int "$VLAN" && (( VLAN >= 1 && VLAN <= 4094 )); } && break; msgbox "VLAN must be 1-4094."; done
  while true; do ask_input MTU "MTU" "Interface MTU (blank for default):" "$MTU"; [[ -z $MTU ]] || { is_int "$MTU" && (( MTU >= 576 )); } && break; msgbox "Invalid MTU."; done
  ask_input DNS "DNS Server" "DNS server IP(s), space separated (blank = use host settings):" "$DNS"
  ask_input SEARCHDOMAIN "DNS Search Domain" "DNS search domain (blank = use host settings):" "$SEARCHDOMAIN"

  # --- Access ---
  if ask_yesno "SSH" "Allow root to log in over SSH with a password?\n\n(No = root may still log in with an SSH key.)" no; then ROOT_SSH="yes"; else ROOT_SSH="no"; fi
  while true; do
    ask_input SSH_KEY "SSH Public Key" "Paste an SSH public key for root (blank to skip):" "$SSH_KEY"
    if [[ -z $SSH_KEY || $SSH_KEY =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp[0-9]+|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]] ]]; then break; fi
    msgbox "That doesn't look like an OpenSSH public key." "SSH Public Key"
  done
  while true; do
    ask_input ADMIN_USER "Admin User" "Create a sudo user that owns the web root (blank to skip):" "$ADMIN_USER"
    if [[ -z $ADMIN_USER ]]; then break; fi
    if [[ $ADMIN_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ && ! $ADMIN_USER =~ ^(root|nginx|apache|mysql|postgres)$ ]]; then
      ask_password ADMIN_PASS "Admin User" "Password for '${ADMIN_USER}' (leave blank to auto-generate):"
      break
    fi
    msgbox "Invalid or reserved user name." "Admin User"
  done
  if ask_yesno "Start on Boot" "Start this container automatically when the host boots?" yes; then ONBOOT=1; else ONBOOT=0; fi

  # --- Web server ---
  while true; do
    ask_input SERVER_NAMES "NGINX — Server Name" "Domain name(s) for this site, separated by spaces\n(e.g. example.com www.example.com). Use _ to answer for any name/IP:" "$SERVER_NAMES"
    SERVER_NAMES=$(echo $SERVER_NAMES)
    [[ -n $SERVER_NAMES && $SERVER_NAMES =~ ^[A-Za-z0-9._*\ -]+$ ]] && break
    msgbox "Invalid server name(s)." "Server Name"
  done
  local first=${SERVER_NAMES%% *}
  if [[ $first == "_" ]]; then SITE_NAME="default"; WEB_ROOT="/var/www/html"
  else SITE_NAME=${first//[^A-Za-z0-9._-]/_}; WEB_ROOT="/var/www/${SITE_NAME}/public"; fi
  while true; do
    ask_input WEB_ROOT "NGINX — Web Root" "Where should the website files live (document root)?" "$WEB_ROOT"
    if [[ $WEB_ROOT =~ ^/[A-Za-z0-9._/-]+$ && ! $WEB_ROOT =~ ^/(etc|bin|sbin|usr|lib|lib64|boot|dev|proc|sys|run)(/|$) && $WEB_ROOT != "/" ]]; then
      WEB_ROOT=${WEB_ROOT%/}; break
    fi
    msgbox "Use an absolute path such as /var/www/mysite/public (not a system directory)." "Web Root"
  done
  while true; do
    ask_input MAX_BODY "NGINX — Upload Limit" "Maximum upload / request body size (e.g. 64M, 512M, 1G).\nPHP upload limits will match:" "$MAX_BODY"
    [[ $MAX_BODY =~ ^[0-9]+[kKmMgG]?$ ]] && break; msgbox "Use a number with an optional K/M/G suffix."
  done
  ask_menu HTTPS_MODE "NGINX — HTTPS" "HTTPS configuration:" "$HTTPS_MODE" \
    none       "HTTP only (add HTTPS later, e.g. with Certbot)" \
    selfsigned "HTTP + HTTPS with a self-signed certificate" \
    redirect   "Self-signed HTTPS and redirect all HTTP to HTTPS"
  ask_menu NGINX_SOURCE "NGINX — Package Source" "Which NGINX build?" "$NGINX_SOURCE" \
    appstream "Rocky AppStream (newest stream available)" \
    stable    "nginx.org official repo — stable branch" \
    mainline  "nginx.org official repo — mainline branch"
  if ask_yesno "Sample Page" "Create a sample landing page in the web root?" yes; then SAMPLE_PAGE="yes"; else SAMPLE_PAGE="no"; fi
  if ask_yesno "System Updates" "Apply all available OS updates during setup? (recommended)" yes; then DO_UPDATE="yes"; else DO_UPDATE="no"; fi
}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
confirm_summary() {
  local net="$IP4${GW4:+ gw $GW4}"
  [[ -n $IP6 ]] && net+=" | v6: $IP6${GW6:+ gw $GW6}"
  [[ -n $VLAN ]] && net+=" | VLAN $VLAN"
  local summary
  summary=$(cat <<EOF
CONTAINER
  ID / Hostname : ${CTID} / ${CT_HOSTNAME}
  OS            : Rocky Linux ${RL_MAJOR}  (${TEMPLATE})
  Type          : $([[ $UNPRIV == 1 ]] && echo Unprivileged || echo Privileged)
  CPU / RAM     : ${CORES} cores / ${RAM} MiB (+${SWAP} MiB swap)
  Disk          : ${DISK} GB on ${CT_STORAGE}
  Network       : ${BRIDGE}  ${net}
  Root password : $([[ -n $ROOT_PW ]] && echo "(set)" || echo "auto-generate")
  Root SSH      : password login ${ROOT_SSH}$([[ -n $SSH_KEY ]] && echo ", key added")
  Admin user    : ${ADMIN_USER:-none}
  Start on boot : $([[ $ONBOOT == 1 ]] && echo yes || echo no)

WEB SERVER
  NGINX source  : ${NGINX_SOURCE}
  Server name   : ${SERVER_NAMES}
  Web root      : ${WEB_ROOT}
  Upload limit  : ${MAX_BODY}
  HTTPS         : ${HTTPS_MODE}

PACKAGES
  ${PKGS:-none}
  PHP source    : ${PHP_SOURCE}${PHP_VERSION:+ $PHP_VERSION}
  App database  : $([[ $CREATE_DB == yes ]] && echo "${DB_NAME} (user ${DB_USER})" || echo no)
  OS updates    : ${DO_UPDATE}

Create the container now?
EOF
)
  whiptail --backtitle "$BACKTITLE" --title "Review Settings" --scrolltext --yesno "$summary" 24 78 || exit_script
}

# ----------------------------------------------------------------------------
# Installer that runs INSIDE the container
# ----------------------------------------------------------------------------
installer_body() {
cat <<'INSTALLER_EOF'
set -Eeuo pipefail
trap 'rm -f -- "$0"' EXIT
export LC_ALL=C HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 022
exec 3>&1 4>&2

LOG=/var/log/rocky-nginx-install.log
: >"$LOG"; chmod 600 "$LOG"
GN=$'\033[1;92m'; RD=$'\033[01;31m'; YW=$'\033[33m'; BL=$'\033[36m'; CL=$'\033[m'
CUR="Starting"
WARNINGS=()
PHP_SOCK=""; FASTCGI_PASS=""; ADMINER_OK="no"; EPEL_DONE="no"
MYSQL_CMD=(mysql -uroot)

on_err() {
  local ec=$1 ln=$2
  trap - ERR
  printf '\r\033[K   %s✖%s %s %s(exit %s, line %s)%s\n' "$RD" "$CL" "$CUR" "$RD" "$ec" "$ln" "$CL" >&3
  printf '\n   ----- last 30 lines of %s -----\n' "$LOG" >&3
  tail -n 30 "$LOG" >&3 || true
  exit "$ec"
}
trap 'on_err $? $LINENO' ERR

step() {
  CUR=$1; shift
  printf '   %s➜%s %s...' "$YW" "$CL" "$CUR" >&3
  printf '\n===== %s =====\n' "$CUR" >>"$LOG"
  "$@" >>"$LOG" 2>&1
  printf '\r\033[K   %s✔%s %s\n' "$GN" "$CL" "$CUR" >&3
}

has() { [[ " $PKGS " == *" $1 "* ]]; }

RL_MAJOR=$(rpm -E %rhel)

enable_best_stream() {
  local mod=$1 stream
  stream=$(dnf -q module list "$mod" 2>/dev/null | awk -v m="$mod" '$1==m{print $2}' | grep -E '^[0-9][0-9.]*$' | sort -V | tail -n1 || true)
  if [[ -n $stream ]]; then
    dnf -y module reset "$mod" || true
    dnf -y module enable "${mod}:${stream}"
  fi
}

enable_epel() {
  if [[ $EPEL_DONE == yes ]]; then return 0; fi
  dnf -y install epel-release
  if (( RL_MAJOR >= 9 )); then dnf config-manager --set-enabled crb || true
  else dnf config-manager --set-enabled powertools || true; fi
  dnf -y makecache || true
  EPEL_DONE="yes"
}

nginx_at_least() {
  local v
  v=$(nginx -v 2>&1 | sed -E 's|.*nginx/([0-9.]+).*|\1|')
  [[ $(printf '%s\n%s\n' "$1" "$v" | sort -V | head -n1) == "$1" ]]
}

# ---------------------------------------------------------------- base
base_setup() {
  dnf -y makecache
  dnf -y --setopt=strict=0 install dnf-plugins-core ca-certificates curl tar openssl findutils procps-ng iproute sudo which
  if [[ $DO_UPDATE == yes ]]; then dnf -y upgrade --refresh; fi
  if has CERTBOT || has FAIL2BAN || has TOOLS || [[ $PHP_SOURCE == remi ]]; then enable_epel; fi
}

wait_network() {
  local i
  for i in $(seq 1 60); do
    if getent hosts dl.rockylinux.org >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  echo "No DNS/network after 60s" >&2
  return 1
}

# ---------------------------------------------------------------- nginx
install_nginx() {
  if [[ $NGINX_SOURCE != appstream ]]; then
    cat >/etc/yum.repos.d/nginx.repo <<'EOF'
[nginx-stable]
name=nginx stable repo
baseurl=https://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true

[nginx-mainline]
name=nginx mainline repo
baseurl=https://nginx.org/packages/mainline/centos/$releasever/$basearch/
gpgcheck=1
enabled=0
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF
    if [[ $NGINX_SOURCE == mainline ]]; then
      dnf config-manager --set-disabled nginx-stable
      dnf config-manager --set-enabled nginx-mainline
    fi
    if dnf -y install nginx; then return 0; fi
    WARNINGS+=("nginx.org repo unavailable for Rocky ${RL_MAJOR} — installed AppStream NGINX instead")
    rm -f /etc/yum.repos.d/nginx.repo
    dnf clean all || true
  fi
  enable_best_stream nginx
  dnf -y install nginx
}

write_nginx_main() {
  [[ -f /etc/nginx/nginx.conf.orig ]] || cp -a /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig
  rm -f /etc/nginx/conf.d/default.conf
  cat >/etc/nginx/nginx.conf <<'EOF'
# Managed by the rocky-nginx Proxmox helper. Original: nginx.conf.orig
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /run/nginx.pid;

include /usr/share/nginx/modules/*.conf;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log  main;

    sendfile            on;
    tcp_nopush          on;
    keepalive_timeout   65;
    types_hash_max_size 4096;
    server_tokens       off;

    gzip              on;
    gzip_vary         on;
    gzip_proxied      any;
    gzip_comp_level   5;
    gzip_min_length   1024;
    gzip_types text/plain text/css text/xml text/javascript application/json
               application/javascript application/xml application/rss+xml image/svg+xml;

    include /etc/nginx/conf.d/*.conf;
}
EOF
}

# ---------------------------------------------------------------- php
install_php() {
  local used_remi="no"
  if [[ $PHP_SOURCE == remi && $RL_MAJOR -lt 10 ]]; then
    enable_epel
    if dnf -y install "https://rpms.remirepo.net/enterprise/remi-release-${RL_MAJOR}.rpm" \
       && dnf -y module reset php \
       && dnf -y module enable "php:remi-${PHP_VERSION}"; then
      used_remi="yes"
    else
      WARNINGS+=("Remi PHP ${PHP_VERSION} could not be enabled — installed AppStream PHP instead")
    fi
  fi
  if [[ $used_remi == no ]]; then enable_best_stream php; fi

  dnf -y install php-fpm php-cli php-common
  dnf -y --setopt=strict=0 install php-mysqlnd php-pgsql php-pdo php-gd php-mbstring php-xml \
      php-intl php-opcache php-bcmath php-process php-sodium php-pecl-zip php-zip php-pecl-apcu php-json \
    || WARNINGS+=("Some optional PHP extensions could not be installed")

  local conf=/etc/php-fpm.d/www.conf
  sed -ri \
    -e 's/^user = .*/user = nginx/' \
    -e 's/^group = .*/group = nginx/' \
    -e 's/^;?listen\.owner = .*/listen.owner = nginx/' \
    -e 's/^;?listen\.group = .*/listen.group = nginx/' \
    -e 's/^;?listen\.mode = .*/listen.mode = 0660/' \
    -e 's/^listen\.acl_users/;listen.acl_users/' \
    -e 's/^listen\.acl_groups/;listen.acl_groups/' "$conf"
  PHP_SOCK=$(awk -F'=' '/^listen[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$conf")
  if [[ -z $PHP_SOCK ]]; then PHP_SOCK=/run/php-fpm/www.sock; fi
  if [[ $PHP_SOCK == /* ]]; then FASTCGI_PASS="unix:${PHP_SOCK}"; else FASTCGI_PASS=$PHP_SOCK; fi

  local tz
  tz=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || true)
  if [[ -z $tz ]]; then tz=UTC; fi
  sed -ri \
    -e "s|^;?date\.timezone =.*|date.timezone = ${tz}|" \
    -e "s|^upload_max_filesize =.*|upload_max_filesize = ${MAX_BODY}|" \
    -e "s|^post_max_size =.*|post_max_size = ${MAX_BODY}|" \
    -e "s|^memory_limit =.*|memory_limit = 256M|" \
    -e "s|^expose_php =.*|expose_php = Off|" /etc/php.ini

  local d
  for d in /var/lib/php/session /var/lib/php/wsdlcache /var/lib/php/opcache; do
    if [[ -d $d ]]; then chgrp -R nginx "$d"; fi
  done
  systemctl enable --now php-fpm
}

# ---------------------------------------------------------------- databases
mysql_harden_sql() {
  cat <<SQL
DROP USER IF EXISTS ''@'localhost';
DROP USER IF EXISTS ''@'${HOSTNAME}';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL
}

install_mariadb() {
  enable_best_stream mariadb
  dnf -y install mariadb-server || dnf -y install mariadb10.11-server
  systemctl enable --now mariadb
  mysql_harden_sql | mysql -uroot
  MYSQL_CMD=(mysql -uroot)
}

install_mysql() {
  dnf -y install mysql-server || dnf -y install mysql8.4-server
  systemctl enable --now mysqld
  { mysql_harden_sql; echo "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}'; FLUSH PRIVILEGES;"; } | mysql -uroot
  printf '[client]\nuser=root\npassword=%s\n' "$MYSQL_ROOT_PASS" >/root/.my.cnf
  chmod 600 /root/.my.cnf
  MYSQL_CMD=(mysql --defaults-extra-file=/root/.my.cnf)
}

create_mysql_db() {
  "${MYSQL_CMD[@]}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
}

install_postgresql() {
  enable_best_stream postgresql
  dnf -y install postgresql-server postgresql-contrib
  if [[ ! -f /var/lib/pgsql/data/PG_VERSION ]]; then postgresql-setup --initdb; fi
  sed -ri 's/^(host[[:space:]]+all[[:space:]]+all[[:space:]]+(127\.0\.0\.1\/32|::1\/128)[[:space:]]+)ident/\1scram-sha-256/' \
    /var/lib/pgsql/data/pg_hba.conf
  systemctl enable --now postgresql
}

create_pg_db() {
  cd /tmp
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q <<SQL
SET password_encryption = 'scram-sha-256';
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE ROLE "${DB_USER}" LOGIN PASSWORD '${DB_PASS}';
  END IF;
END
\$\$;
SQL
  if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
    runuser -u postgres -- createdb -O "${DB_USER}" "${DB_NAME}"
  fi
  cd /
}

# ---------------------------------------------------------------- other packages
install_redis() {
  if (( RL_MAJOR >= 10 )); then
    dnf -y install valkey
    systemctl enable --now valkey
  else
    enable_best_stream redis
    dnf -y install redis
    systemctl enable --now redis
  fi
  if has PHP; then
    dnf -y install php-pecl-redis6 || dnf -y install php-pecl-redis5 || dnf -y install php-pecl-redis \
      || WARNINGS+=("PHP redis extension not available from enabled repos")
  fi
}

install_nodejs() {
  enable_best_stream nodejs
  dnf -y install nodejs
  if ! command -v npm >/dev/null; then
    dnf -y install npm || dnf -y install nodejs-npm || WARNINGS+=("npm package not found")
  fi
}

install_composer() {
  local sig actual
  curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php || return 1
  sig=$(curl -fsSL https://composer.github.io/installer.sig) || return 1
  actual=$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');") || return 1
  if [[ $sig != "$actual" ]]; then echo "Composer installer checksum mismatch" >&2; rm -f /tmp/composer-setup.php; return 1; fi
  php /tmp/composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer || return 1
  rm -f /tmp/composer-setup.php
}
try_composer() { install_composer || WARNINGS+=("Composer install failed — see $LOG"); }

install_adminer() {
  mkdir -p /usr/share/adminer
  if curl -fsSL -o /usr/share/adminer/index.php https://www.adminer.org/latest.php \
     && grep -q '<?php' /usr/share/adminer/index.php; then
    chmod 644 /usr/share/adminer/index.php
    ADMINER_OK="yes"
  else
    rm -f /usr/share/adminer/index.php
    WARNINGS+=("Adminer download failed — skipped")
  fi
}

install_certbot() {
  enable_epel
  dnf -y install certbot python3-certbot-nginx
}

install_firewalld() {
  dnf -y install firewalld
  if systemctl enable --now firewalld; then
    firewall-cmd --permanent --add-service=http --add-service=https --add-service=ssh \
      && firewall-cmd --reload \
      || WARNINGS+=("firewalld rules could not be applied")
  else
    systemctl disable firewalld || true
    WARNINGS+=("firewalld could not start in this container — consider the Proxmox firewall instead")
  fi
}

install_fail2ban() {
  enable_epel
  dnf -y --setopt=strict=0 install fail2ban-server fail2ban-firewalld fail2ban-systemd || dnf -y install fail2ban
  mkdir -p /etc/fail2ban/jail.d
  cat >/etc/fail2ban/jail.d/90-rocky-nginx.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
backend = systemd
EOF
  systemctl enable --now fail2ban || WARNINGS+=("fail2ban could not start — see 'journalctl -u fail2ban'")
}

install_autoupdate() {
  dnf -y install dnf-automatic
  if [[ -f /etc/dnf/automatic.conf ]]; then
    sed -ri -e 's/^upgrade_type[[:space:]]*=.*/upgrade_type = security/' \
            -e 's/^apply_updates[[:space:]]*=.*/apply_updates = yes/' /etc/dnf/automatic.conf
  fi
  systemctl enable --now dnf-automatic.timer || WARNINGS+=("dnf-automatic timer could not be enabled")
}

install_tools() {
  dnf -y --setopt=strict=0 install vim-enhanced nano htop wget unzip zip rsync bash-completion tree lsof bind-utils jq tmux
}

# ---------------------------------------------------------------- access
setup_ssh() {
  dnf -y install openssh-server
  local val="prohibit-password"
  if [[ $ROOT_SSH == yes ]]; then val="yes"; fi
  if [[ -d /etc/ssh/sshd_config.d ]] && grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d' /etc/ssh/sshd_config; then
    echo "PermitRootLogin ${val}" >/etc/ssh/sshd_config.d/00-rocky-nginx.conf
  else
    sed -ri "s/^#?PermitRootLogin.*/PermitRootLogin ${val}/" /etc/ssh/sshd_config
  fi
  systemctl enable sshd
  systemctl restart sshd || WARNINGS+=("sshd failed to start")
}

create_admin() {
  if id "$ADMIN_USER" >/dev/null 2>&1; then usermod -aG wheel,nginx "$ADMIN_USER"
  else useradd -m -s /bin/bash -G wheel,nginx "$ADMIN_USER"; fi
  printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASS" | chpasswd
}

# ---------------------------------------------------------------- site
make_selfsigned() {
  local ip cn san n
  ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)
  cn=${SERVER_NAMES%% *}
  if [[ $cn == "_" ]]; then cn=$HOSTNAME; fi
  san="DNS:${HOSTNAME}"
  for n in $SERVER_NAMES; do
    if [[ $n != "_" && $n != "$HOSTNAME" ]]; then san+=",DNS:${n}"; fi
  done
  if [[ -n $ip ]]; then san+=",IP:${ip}"; fi
  mkdir -p /etc/pki/nginx/private
  chmod 700 /etc/pki/nginx/private
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "/etc/pki/nginx/private/${SITE_NAME}.key" \
    -out "/etc/pki/nginx/${SITE_NAME}.crt" \
    -subj "/CN=${cn}" -addext "subjectAltName=${san}"
  chmod 600 "/etc/pki/nginx/private/${SITE_NAME}.key"
}

site_body() {
  local index="index.html index.htm" fallback="=404"
  if [[ -n $FASTCGI_PASS ]]; then index="index.php index.html index.htm"; fallback='/index.php?$query_string'; fi
  cat <<EOF
    server_name ${SERVER_NAMES};
    root ${WEB_ROOT};
    index ${index};

    client_max_body_size ${MAX_BODY};
    access_log /var/log/nginx/${SITE_NAME}.access.log main;
    error_log  /var/log/nginx/${SITE_NAME}.error.log warn;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location / {
        try_files \$uri \$uri/ ${fallback};
    }
EOF
  if [[ -n $FASTCGI_PASS ]]; then
    cat <<EOF

    location ~ \.php\$ {
        try_files \$uri =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_index index.php;
        fastcgi_pass ${FASTCGI_PASS};
    }
EOF
  fi
  if [[ $ADMINER_OK == yes && -n $FASTCGI_PASS ]]; then
    cat <<EOF

    # Adminer — only reachable from private/LAN addresses
    location = /adminer { return 301 /adminer/; }
    location ^~ /adminer/ {
        allow 127.0.0.1; allow ::1;
        allow 10.0.0.0/8; allow 172.16.0.0/12; allow 192.168.0.0/16; allow fc00::/7;
        deny all;
        alias /usr/share/adminer/;
        index index.php;
        location ~ \.php\$ {
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME \$request_filename;
            fastcgi_pass ${FASTCGI_PASS};
        }
    }
EOF
  fi
  cat <<'EOF'

    location ~ /\.(?!well-known) { deny all; }
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }
EOF
}

write_site() {
  local f="/etc/nginx/conf.d/${SITE_NAME}.conf" v6="no"
  if [[ -f /proc/net/if_inet6 ]]; then v6="yes"; fi
  if [[ $HTTPS_MODE != none ]]; then make_selfsigned; fi
  {
    echo "# Site '${SITE_NAME}' — generated by the rocky-nginx Proxmox helper"
    echo "server {"
    echo "    listen 80 default_server;"
    if [[ $v6 == yes ]]; then echo "    listen [::]:80 default_server;"; fi
    if [[ $HTTPS_MODE == redirect ]]; then
      echo "    server_name ${SERVER_NAMES};"
      echo "    location /.well-known/acme-challenge/ { root ${WEB_ROOT}; }"
      echo '    location / { return 301 https://$host$request_uri; }'
    else
      site_body
    fi
    echo "}"
    if [[ $HTTPS_MODE != none ]]; then
      echo
      echo "server {"
      if nginx_at_least 1.25.1; then
        echo "    listen 443 ssl default_server;"
        if [[ $v6 == yes ]]; then echo "    listen [::]:443 ssl default_server;"; fi
        echo "    http2 on;"
      else
        echo "    listen 443 ssl http2 default_server;"
        if [[ $v6 == yes ]]; then echo "    listen [::]:443 ssl http2 default_server;"; fi
      fi
      echo "    ssl_certificate     /etc/pki/nginx/${SITE_NAME}.crt;"
      echo "    ssl_certificate_key /etc/pki/nginx/private/${SITE_NAME}.key;"
      echo "    ssl_protocols TLSv1.2 TLSv1.3;"
      echo "    ssl_prefer_server_ciphers off;"
      echo "    ssl_session_cache shared:SSL:10m;"
      echo "    ssl_session_timeout 1d;"
      echo
      site_body
      echo "}"
    fi
  } >"$f"
}

stack_summary() {
  local s
  s="NGINX $(nginx -v 2>&1 | sed -E 's|.*nginx/||')"
  if command -v php >/dev/null; then s+=" · PHP $(php -r 'echo PHP_VERSION;' 2>/dev/null || true)"; fi
  if has MARIADB; then s+=" · MariaDB"; fi
  if has MYSQL; then s+=" · MySQL"; fi
  if has POSTGRESQL; then s+=" · PostgreSQL"; fi
  if has REDIS; then if (( RL_MAJOR >= 10 )); then s+=" · Valkey"; else s+=" · Redis"; fi; fi
  if command -v node >/dev/null; then s+=" · Node.js $(node -v 2>/dev/null || true)"; fi
  echo "$s"
}

setup_webroot() {
  mkdir -p "$WEB_ROOT"
  if [[ $SAMPLE_PAGE == yes ]] && [[ -z $(ls -A "$WEB_ROOT") ]]; then
    local stack page="index.html" phpline=""
    stack=$(stack_summary)
    if [[ -n $FASTCGI_PASS ]]; then page="index.php"; phpline='<p class="ok">PHP is working — version <?= PHP_VERSION ?></p>'; fi
    cat >"${WEB_ROOT}/${page}" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${HOSTNAME} — it works!</title>
<style>
  body{margin:0;min-height:100vh;display:grid;place-items:center;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#0f1720;color:#e6edf3}
  .card{max-width:640px;padding:2.5rem;border-radius:14px;background:#16212c;box-shadow:0 10px 40px #0006}
  h1{margin:0 0 .5rem;font-size:1.8rem}
  code{background:#0b1218;padding:.15rem .4rem;border-radius:4px}
  .muted{color:#8b9bab}.ok{color:#3fb950}
</style>
</head>
<body>
<div class="card">
  <h1>🚀 ${HOSTNAME} is up</h1>
  <p class="muted">Rocky Linux ${RL_MAJOR} · ${stack}</p>
  ${phpline}
  <p>Replace this page by uploading your site to <code>${WEB_ROOT}</code>.</p>
</div>
</body>
</html>
EOF
  fi
  local owner="nginx"
  if [[ -n $ADMIN_USER ]]; then owner=$ADMIN_USER; fi
  chown -R "${owner}:nginx" "$WEB_ROOT"
  find "$WEB_ROOT" -type d -exec chmod 2775 {} +
  find "$WEB_ROOT" -type f -exec chmod 0664 {} +
  if command -v selinuxenabled >/dev/null && selinuxenabled; then
    setsebool -P httpd_can_network_connect 1 || true
    restorecon -R "$WEB_ROOT" || true
  fi
}

start_web() {
  nginx -t
  systemctl enable nginx
  systemctl restart nginx
  if [[ -n $FASTCGI_PASS ]]; then systemctl restart php-fpm; fi
}

install_site_helper() {
  cat >/usr/local/sbin/nginx-site <<'HELPER_EOF'
#!/usr/bin/env bash
# nginx-site — add/remove/list NGINX sites (installed by the rocky-nginx Proxmox helper)
set -euo pipefail
CONF_DIR=/etc/nginx/conf.d

usage() {
  cat <<EOF
Usage:
  nginx-site add <domain> [web-root]   Create a site (default root: /var/www/<domain>/public)
  nginx-site remove <domain>           Remove a site's NGINX config (files are kept)
  nginx-site list                      List configured sites
EOF
}

php_pass() {
  local s
  s=$(awk -F'=' '/^listen[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2;exit}' /etc/php-fpm.d/www.conf 2>/dev/null || true)
  [[ -n $s ]] || return 1
  if [[ $s == /* ]]; then echo "unix:$s"; else echo "$s"; fi
}

add_site() {
  local d=$1 root=${2:-/var/www/$1/public} f="$CONF_DIR/$1.conf" names pass index="index.html index.htm" fb="=404" phpblk=""
  [[ $d =~ ^[A-Za-z0-9.-]+$ ]] || { echo "Invalid domain: $d" >&2; exit 1; }
  if [[ -e $f ]]; then echo "Site already exists: $f" >&2; exit 1; fi
  names=$d
  if [[ $d != www.* ]]; then names="$d www.$d"; fi
  local listen6=""
  if [[ -f /proc/net/if_inet6 ]]; then listen6="    listen [::]:80;"; fi
  if pass=$(php_pass); then
    index="index.php $index"; fb='/index.php?$query_string'
    phpblk="    location ~ \.php\$ {
        try_files \$uri =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass $pass;
    }"
  fi
  cat >"$f" <<EOF
server {
    listen 80;
$listen6
    server_name $names;
    root $root;
    index $index;
    access_log /var/log/nginx/$d.access.log main;
    error_log  /var/log/nginx/$d.error.log warn;

    location / {
        try_files \$uri \$uri/ $fb;
    }
$phpblk
    location ~ /\.(?!well-known) { deny all; }
}
EOF
  mkdir -p "$root"
  if [[ -z $(ls -A "$root") ]]; then echo "<h1>$d</h1><p>New site is live.</p>" >"$root/index.html"; fi
  chown -R "$(stat -c %U "$(dirname "$root")")":nginx "$root" 2>/dev/null || chown -R nginx:nginx "$root"
  if nginx -t 2>/dev/null; then
    systemctl reload nginx
    echo "Created $d → $root  (config: $f)"
    echo "HTTPS: certbot --nginx -d $d$([[ $d != www.* ]] && echo " -d www.$d")"
  else
    rm -f "$f"; nginx -t || true; echo "Config test failed — site not added." >&2; exit 1
  fi
}

remove_site() {
  local f="$CONF_DIR/$1.conf"
  [[ -f $f ]] || { echo "No such site: $1" >&2; exit 1; }
  rm -f "$f"
  nginx -t && systemctl reload nginx
  echo "Removed $1 (web files were kept)."
}

list_sites() {
  local f
  for f in "$CONF_DIR"/*.conf; do
    [[ -e $f ]] || continue
    printf '%-28s %s\n' "$(basename "$f" .conf)" "$(grep -m1 -E '^\s*server_name' "$f" | sed -E 's/^\s*server_name\s+//; s/;$//')"
  done
}

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }
case ${1:-} in
  add)    [[ -n ${2:-} ]] || { usage; exit 1; }; add_site "$2" "${3:-}";;
  remove) [[ -n ${2:-} ]] || { usage; exit 1; }; remove_site "$2";;
  list)   list_sites;;
  *)      usage;;
esac
HELPER_EOF
  chmod 755 /usr/local/sbin/nginx-site
}

write_info() {
  local ip url scheme="http"
  ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)
  if [[ $HTTPS_MODE != none ]]; then scheme="https"; fi
  url="${scheme}://${ip:-<container-ip>}/"
  {
    echo "Rocky Linux NGINX Web Server — created $(date '+%F %T %Z')"
    echo "=================================================================="
    echo "Hostname      : ${HOSTNAME}"
    echo "Rocky Linux   : $(cat /etc/rocky-release 2>/dev/null || echo "$RL_MAJOR")"
    echo "URL           : ${url}"
    echo "Stack         : $(stack_summary)"
    echo "Server name   : ${SERVER_NAMES}"
    echo "Web root      : ${WEB_ROOT}"
    echo "Site config   : /etc/nginx/conf.d/${SITE_NAME}.conf"
    echo "Install log   : ${LOG}"
    if [[ -n $FASTCGI_PASS ]]; then echo "PHP-FPM       : ${FASTCGI_PASS}  (pool user: nginx)"; fi
    if [[ $HTTPS_MODE != none ]]; then echo "TLS cert      : /etc/pki/nginx/${SITE_NAME}.crt (self-signed, 10 years)"; fi
    if [[ -n $ADMIN_USER ]]; then echo "Admin user    : ${ADMIN_USER} / ${ADMIN_PASS}  (sudo via wheel)"; fi
    if has MARIADB; then echo "MariaDB root  : local socket auth — run 'mysql' as root"; fi
    if has MYSQL; then echo "MySQL root    : ${MYSQL_ROOT_PASS}  (saved in /root/.my.cnf)"; fi
    if has POSTGRESQL; then echo "PostgreSQL    : superuser 'postgres' — run 'runuser -u postgres -- psql'"; fi
    if [[ $CREATE_DB == yes ]]; then echo "App database  : db=${DB_NAME} user=${DB_USER} password=${DB_PASS} host=127.0.0.1"; fi
    if [[ $ADMINER_OK == yes ]]; then echo "Adminer       : ${scheme}://${ip:-<container-ip>}/adminer/  (LAN only)"; fi
    if has CERTBOT; then
      if [[ ${SERVER_NAMES%% *} != "_" ]]; then echo "Let's Encrypt : certbot --nginx $(printf -- '-d %s ' $SERVER_NAMES)"
      else echo "Let's Encrypt : certbot --nginx -d yourdomain.com"; fi
    fi
    echo
    echo "Add more sites: nginx-site add example.com   |   nginx-site list"
  } >/root/webserver-info.txt
  chmod 600 /root/webserver-info.txt
}

# ============================================================== main
printf '\n   %sConfiguring Rocky Linux %s container%s\n\n' "$BL" "$RL_MAJOR" "$CL" >&3

step "Waiting for network"                 wait_network
step "Preparing base system$([[ $DO_UPDATE == yes ]] && echo ' + OS updates')" base_setup
step "Installing NGINX (${NGINX_SOURCE})"  install_nginx
step "Writing NGINX main config"           write_nginx_main
if has PHP;        then step "Installing PHP-FPM"            install_php; fi
if has MARIADB;    then step "Installing MariaDB"            install_mariadb; fi
if has MYSQL;      then step "Installing MySQL"              install_mysql; fi
if has POSTGRESQL; then step "Installing PostgreSQL"         install_postgresql; fi
if [[ $CREATE_DB == yes ]]; then
  if has MARIADB || has MYSQL; then step "Creating database '${DB_NAME}' (MySQL/MariaDB)" create_mysql_db; fi
  if has POSTGRESQL;           then step "Creating database '${DB_NAME}' (PostgreSQL)"    create_pg_db; fi
fi
if has REDIS;      then step "Installing $( (( RL_MAJOR >= 10 )) && echo Valkey || echo Redis)" install_redis; fi
if has NODEJS;     then step "Installing Node.js"            install_nodejs; fi
if has COMPOSER;   then step "Installing Composer"           try_composer; fi
if has ADMINER;    then step "Installing Adminer"            install_adminer; fi
if has CERTBOT;    then step "Installing Certbot"            install_certbot; fi
if has GIT;        then step "Installing Git"                dnf -y install git; fi
if has TOOLS;      then step "Installing CLI tools"          install_tools; fi
step "Configuring SSH"                     setup_ssh
if [[ -n $ADMIN_USER ]]; then step "Creating admin user '${ADMIN_USER}'" create_admin; fi
step "Writing site '${SITE_NAME}'"         write_site
step "Preparing web root ${WEB_ROOT}"      setup_webroot
step "Installing 'nginx-site' helper"      install_site_helper
step "Starting web services"               start_web
if has FIREWALLD;  then step "Configuring firewalld"         install_firewalld; fi
if has FAIL2BAN;   then step "Configuring Fail2ban"          install_fail2ban; fi
if has AUTOUPDATE; then step "Enabling automatic security updates" install_autoupdate; fi
step "Cleaning up"                         dnf clean all
step "Writing /root/webserver-info.txt"    write_info

if (( ${#WARNINGS[@]} > 0 )); then
  printf '\n   %sWarnings:%s\n' "$YW" "$CL" >&3
  for w in "${WARNINGS[@]}"; do printf '   %s!%s %s\n' "$YW" "$CL" "$w" >&3; done
fi
printf '\n' >&3
sed 's/^/   /' /root/webserver-info.txt >&3
INSTALLER_EOF
}

# ----------------------------------------------------------------------------
# Build & run
# ----------------------------------------------------------------------------
build_container() {
  header_info
  echo -e " ${BOLD}Creating ${APP}${CL}\n"

  # Fill in generated secrets
  local gen_root="no"
  if [[ -z $ROOT_PW ]]; then ROOT_PW=$(gen_pw 20); gen_root="yes"; fi
  if [[ -n $ADMIN_USER && -z $ADMIN_PASS ]]; then ADMIN_PASS=$(gen_pw 16); fi
  if [[ $CREATE_DB == yes && -z $DB_PASS ]]; then DB_PASS=$(gen_pw 24); fi
  if has_pkg MYSQL; then MYSQL_ROOT_PASS=$(gen_pw 24); fi

  # Template
  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk -v t="$TEMPLATE" 'index($0,t){f=1} END{exit !f}'; then
    msg_info "Downloading template ${TEMPLATE}"
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null
    msg_ok "Downloaded template ${TEMPLATE}"
  else
    msg_ok "Template ${TEMPLATE} already present"
  fi

  # Network string
  local net="name=eth0,bridge=${BRIDGE},ip=${IP4}"
  [[ -n $GW4 ]]  && net+=",gw=${GW4}"
  [[ -n $IP6 ]]  && net+=",ip6=${IP6}"
  [[ -n $GW6 ]]  && net+=",gw6=${GW6}"
  [[ -n $VLAN ]] && net+=",tag=${VLAN}"
  [[ -n $MTU ]]  && net+=",mtu=${MTU}"

  local features="nesting=1"
  [[ $UNPRIV == 1 ]] && features+=",keyctl=1"

  local desc
  desc="Rocky Linux ${RL_MAJOR} NGINX web server
Created $(date '+%F') by the rocky-nginx Proxmox helper script v${SCRIPT_VERSION}
Packages: ${PKGS:-none}
Web root: ${WEB_ROOT}
Details inside the container: /root/webserver-info.txt"

  local -a args=(
    "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"
    --hostname "$CT_HOSTNAME"
    --cores "$CORES" --memory "$RAM" --swap "$SWAP"
    --rootfs "${CT_STORAGE}:${DISK}"
    --net0 "$net"
    --unprivileged "$UNPRIV"
    --features "$features"
    --onboot "$ONBOOT"
    --timezone host
    --tags "rocky-linux;nginx;webserver"
    --description "$desc"
    --password "$ROOT_PW"
  )
  [[ -n $DNS ]] && args+=(--nameserver "$DNS")
  [[ -n $SEARCHDOMAIN ]] && args+=(--searchdomain "$SEARCHDOMAIN")
  if [[ -n $SSH_KEY ]]; then
    local keyf; keyf=$(mktemp); TMP_FILES+=("$keyf")
    printf '%s\n' "$SSH_KEY" >"$keyf"
    args+=(--ssh-public-keys "$keyf")
  fi

  msg_info "Creating LXC container ${CTID}"
  pct create "${args[@]}" >/dev/null
  CT_CREATED=1
  msg_ok "Created LXC container ${CTID} (${CT_HOSTNAME})"

  msg_info "Starting container"
  pct start "$CTID"
  local i
  for i in $(seq 1 30); do
    if pct exec "$CTID" -- true >/dev/null 2>&1; then break; fi
    sleep 1
  done
  pct exec "$CTID" -- true >/dev/null
  msg_ok "Started container ${CTID}"

  # Build installer with settings baked in
  local inst v
  inst=$(mktemp); TMP_FILES+=("$inst"); chmod 600 "$inst"
  {
    echo '#!/usr/bin/env bash'
    for v in RL_MAJOR SERVER_NAMES SITE_NAME WEB_ROOT MAX_BODY HTTPS_MODE NGINX_SOURCE DO_UPDATE ROOT_SSH \
             ADMIN_USER ADMIN_PASS PKGS PHP_SOURCE PHP_VERSION CREATE_DB DB_NAME DB_USER DB_PASS \
             MYSQL_ROOT_PASS SAMPLE_PAGE SCRIPT_VERSION; do
      printf '%s=%q\n' "$v" "${!v}"
    done
    installer_body
  } >"$inst"

  pct push "$CTID" "$inst" /root/.rocky-nginx-install.sh --perms 0700
  pct exec "$CTID" -- bash /root/.rocky-nginx-install.sh

  local ip
  ip=$(pct exec "$CTID" -- sh -c "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -n1" 2>/dev/null || true)
  local scheme="http"; [[ $HTTPS_MODE != none ]] && scheme="https"

  echo
  msg_ok "${GN}Completed successfully!${CL}"
  echo -e "\n ${BOLD}Container ${CTID} (${CT_HOSTNAME})${CL}"
  echo -e "   Website      : ${BL}${scheme}://${ip:-<container-ip>}/${CL}"
  echo -e "   Console      : pct enter ${CTID}"
  if [[ $gen_root == yes ]]; then
    echo -e "   Root password: ${YW}${ROOT_PW}${CL}   ${RD}(save this — it is not stored anywhere)${CL}"
  fi
  echo -e "   All details  : cat /root/webserver-info.txt   (inside the container)\n"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  header_info
  preflight
  set_defaults

  ask_yesno "$APP" "This will create a new Rocky Linux LXC container and set up an NGINX web server.\n\nProceed?" yes || exit_script

  select_storage TEMPLATE_STORAGE vztmpl "container templates"
  discover_templates
  select_rocky_version

  local mode
  ask_menu mode "Settings" "Choose a setup mode:" "default" \
    default  "Default settings  (quick — just pick packages)" \
    advanced "Advanced settings (customize everything)"

  if [[ $mode == advanced ]]; then advanced_settings; fi
  select_storage CT_STORAGE rootdir "container disk"
  select_packages
  if [[ $mode == advanced ]]; then configure_package_options; fi
  confirm_summary
  build_container
}

main "$@"
