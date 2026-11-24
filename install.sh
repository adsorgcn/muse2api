#!/usr/bin/env bash
# muse2api one-line installer for Ubuntu / Debian servers.
#
#   curl -fsSL https://raw.githubusercontent.com/adsorgcn/muse2api/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/adsorgcn/muse2api/main/install.sh | bash -s -- --domain api.example.com
#
# Run it as root on the server. Run the same line again to upgrade: the API key in .env
# and the accounts in data/ are kept. It never changes sshd, root login, passwords, users,
# SSH keys or firewall rules, and never runs apt upgrade. (Installing Docker, when it is
# missing, adds Docker's own iptables chains; ports published by Docker are not filtered
# by ufw.)
#
# The last line is one of
#   MUSE2API_INSTALL_OK base=... commit=... domain=...
#   MUSE2API_INSTALL_PENDING_PROXY base=... local=...   (a hosting panel must add the proxy)
#   [muse2api] ERROR: ...                               (nothing after it ran)
#
# Options
#   --domain NAME   serve on https://NAME. The service is first installed on plain IP; only
#                   after nginx and a Let's Encrypt certificate (no e-mail) work is it switched
#                   to https. NAME must resolve to this server (Cloudflare: DNS only).
#   --no-domain     go back to plain http://IP:18610
#   --ip ADDRESS    public IPv4 of this server, when detection picks the wrong one
#   --dir PATH      install directory (default /opt/muse2api)
#   --ref REF       branch, tag or commit to deploy (default main)
#   --force         continue when memory, disk or the muse.ai check is below the minimum
#
# Relay station (New API, https://github.com/QuantumNous/new-api) in front of muse2api,
# on the same domain; needs --domain the first time:
#   --relay new-api                  install it and add muse2api as a channel
#   --relay-register open|closed     whether people can sign up themselves
#   --relay-price free|chat=X,image=Y,video=Z   price per call in USD (free = 0 for all three)
#   --no-relay                       stop New API (its data stays in /opt/new-api) and send the domain to muse2api again
# Both choices are required the first time and can be changed on any later run. The New API
# admin is "root"; its password is created on the server in /opt/new-api/.admin.
set -Eeuo pipefail

REPO_URL="https://github.com/adsorgcn/muse2api"
REPO_SLUG="adsorgcn/muse2api"
PORT=18610
PLACEHOLDER_KEY="m2a_your_secret_admin_key_here"
LOCK_FILE=/run/muse2api-install.lock
SITE_MARK="# managed by muse2api install.sh"
NEWAPI_IMAGE="calciumion/new-api:v1.0.0-rc.51"
RELAY_DIR=/opt/new-api
RELAY_PORT=3000

WARNS=()
say()  { printf '[muse2api] %s\n' "$*"; }
warn() { printf '[muse2api] WARNING: %s\n' "$*" >&2; WARNS+=("$*"); }
die()  { trap - ERR; printf '[muse2api] ERROR: %s\n' "$*" >&2; exit 1; }
trap 'die "step failed (exit $?) at line $LINENO: $BASH_COMMAND"' ERR

# names of the processes listening on an ss filter such as "sport = :80"
listeners() { ss -tlnpH "$1" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | sort -u | tr '\n' ' ' || true; }
first_pid() { ss -tlnpH "$1" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | awk 'NR==1' || true; }

is_private() {
  case "$1" in
    10.*|192.168.*|127.*|169.254.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|198.1[89].*) return 0 ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
  esac
  return 1
}
local_v4() { ip -4 -o addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1]}' || true; }
local_v6() { ip -6 -o addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1]}' || true; }

detect_ip() {
  local a
  for a in $(local_v4); do
    if ! is_private "$a"; then printf '%s' "$a"; return 0; fi
  done
  a=$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)
  printf '%s' "$a"
}

wait_apt() {
  local i
  for i in $(seq 1 120); do
    # the real updater is /usr/bin/unattended-upgrade; unattended-upgrade-shutdown idles all the time and is not one
    if ! pgrep -x 'apt|apt-get|dpkg' >/dev/null 2>&1 && ! pgrep -f '^/usr/bin/python3 /usr/bin/unattended-upgrade( |$)' >/dev/null 2>&1; then return 0; fi
    if [ "$i" = 1 ]; then say "waiting for another apt/dpkg process (e.g. automatic updates) to finish"; fi
    sleep 5
  done
  die "another apt/dpkg process has been running for 10 minutes; wait for it to finish and re-run"
}

APT_UPDATED=0
apt_install() {
  local missing=() p
  for p in "$@"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then missing+=("$p"); fi
  done
  if [ ${#missing[@]} -eq 0 ]; then return 0; fi
  wait_apt
  if [ "$APT_UPDATED" = 0 ]; then
    apt-get -o DPkg::Lock::Timeout=600 update -q </dev/null || die "apt-get update failed (a repository on this server may be broken); fix apt and re-run"
    APT_UPDATED=1
  fi
  say "installing ${missing[*]}"
  apt-get -o DPkg::Lock::Timeout=600 install -y -q --no-install-recommends "${missing[@]}" </dev/null || die "apt-get could not install ${missing[*]}"
}

# .env helpers; ENVF is set in main
env_newline() {
  if [ -s "$ENVF" ] && [ -n "$(tail -c 1 "$ENVF")" ]; then echo >> "$ENVF"; fi
  return 0
}
# a definition may be written "KEY=v", "export KEY=v" or "KEY = v"; compose reads all three
env_has() { grep -E "^[[:space:]]*(export[[:space:]]+)?$1[[:space:]]*=" "$ENVF" >/dev/null 2>&1; }
env_get() {
  sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?$1[[:space:]]*=//p" "$ENVF" | tail -n 1 | tr -d '\r' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\\(.*\\)'\$/\\1/" || true
}
# replaces every definition of the key with one plain line; the value is never parsed by sed
env_set() {
  local tmp="$ENVF.tmp"
  K="$1" V="$2" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"]; re = "^[[:space:]]*(export[[:space:]]+)?" k "[[:space:]]*=" }
    { sub(/\r$/, "") } $0 ~ re { if (!done) print k "=" v; done = 1; next } { print }
    END { if (!done) print k "=" v }' "$ENVF" > "$tmp"
  cat "$tmp" > "$ENVF"
  rm -f "$tmp"
}
env_default() {
  if ! env_has "$1"; then env_newline; printf '%s=%s\n' "$1" "$2" >> "$ENVF"; fi
  return 0
}

# The whole file is read before main runs, so "curl ... | bash" cannot lose the rest of the script.
main() {
  local DIR="/opt/muse2api" REF="main" DOMAIN="" NO_DOMAIN=0 IP="" FORCE=0 RELAY="" RELAY_REG="" RELAY_PRICE="" NO_RELAY=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --domain)    DOMAIN="${2:-}"; [ -n "$DOMAIN" ] || die "--domain needs a name"; shift 2 ;;
      --no-domain) NO_DOMAIN=1; shift ;;
      --ip)        IP="${2:-}"; [ -n "$IP" ] || die "--ip needs an address"; shift 2 ;;
      --dir)       DIR="${2:-}"; [ -n "$DIR" ] || die "--dir needs a path"; shift 2 ;;
      --ref)       REF="${2:-}"; [ -n "$REF" ] || die "--ref needs a value"; shift 2 ;;
      --force)     FORCE=1; shift ;;
      --relay)     RELAY="${2:-}"; [ "$RELAY" = new-api ] || die "--relay supports: new-api"; shift 2 ;;
      --relay-register) RELAY_REG="${2:-}"; case "$RELAY_REG" in open|closed) ;; *) die "--relay-register is open or closed" ;; esac; shift 2 ;;
      --no-relay)  NO_RELAY=1; shift ;;
      --relay-price) RELAY_PRICE="${2:-}"; [ -n "$RELAY_PRICE" ] || die "--relay-price needs free or chat=X,image=Y,video=Z"; shift 2 ;;
      -h|--help)   echo "see the comments at the top of install.sh"; return 0 ;;
      *)           die "unknown option: $1" ;;
    esac
  done
  if [ -n "$DOMAIN" ] && [ "$NO_DOMAIN" = 1 ]; then die "use either --domain or --no-domain"; fi
  DOMAIN="${DOMAIN,,}"
  need_or_force() { if [ "$FORCE" = 1 ]; then warn "$1 (continuing because of --force)"; else die "$1 (re-run with --force to continue anyway)"; fi; }
  g() { git -c safe.directory="$DIR" -C "$DIR" "$@"; }

  # ------------------------------------------------------------ system
  [ "$(id -u)" = 0 ] || die "run as root"
  [ -r /etc/os-release ] || die "cannot read /etc/os-release"
  . /etc/os-release
  local DISTRO="" CODENAME=""
  case " ${ID:-} ${ID_LIKE:-} " in
    *" ubuntu "*) DISTRO=ubuntu; CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" ;;
    *" debian "*) DISTRO=debian; CODENAME="${VERSION_CODENAME:-}" ;;
  esac
  if [ -z "$DISTRO" ] || [ -z "$CODENAME" ]; then die "only Ubuntu and Debian are supported (found ${PRETTY_NAME:-unknown})"; fi
  case "$(uname -m)" in x86_64|aarch64) ;; *) die "unsupported CPU architecture $(uname -m)" ;; esac
  command -v systemctl >/dev/null || die "systemd is required"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another run of install.sh is in progress on this server; wait for it to finish"
  say "system: ${PRETTY_NAME:-$ID} $(uname -m)"
  export DEBIAN_FRONTEND=noninteractive
  apt_install ca-certificates curl git openssl iproute2 procps

  # ------------------------------------------------------------ checks (nothing is changed before these pass)
  local MEM_MB SWAP_MB DISK_MB MUSE_CODE
  MEM_MB=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
  SWAP_MB=$(awk '/^SwapTotal:/ {print int($2/1024)}' /proc/meminfo)
  DISK_MB=$(df -Pm / | awk 'NR==2 {print $4}')
  say "memory ${MEM_MB} MiB + swap ${SWAP_MB} MiB, free disk ${DISK_MB} MiB"
  if [ "$MEM_MB" -lt 900 ]; then
    need_or_force "at least 900 MiB of RAM is needed (found ${MEM_MB} MiB); swap does not make up for this, use a bigger server"
  elif [ $((MEM_MB + SWAP_MB)) -lt 1700 ]; then
    need_or_force "RAM plus swap must reach 1700 MiB (found ${MEM_MB} + ${SWAP_MB}); adding swap fixes this"
  fi
  local DISK_NEED=5000
  if command -v docker >/dev/null 2>&1 && docker image inspect muse2api:latest >/dev/null 2>&1; then DISK_NEED=2500; fi
  [ "$DISK_MB" -ge "$DISK_NEED" ] || need_or_force "about $((DISK_NEED / 1000)) GB of free disk is needed (found ${DISK_MB} MiB)"
  MUSE_CODE=$(curl -s -o /dev/null --max-time 20 -w '%{http_code}' https://muse.ai/ || true)
  case "$MUSE_CODE" in
    2??|3??) say "muse.ai reachable (HTTP $MUSE_CODE)" ;;
    *) need_or_force "this server cannot open https://muse.ai/ (HTTP ${MUSE_CODE:-none})" ;;
  esac

  if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -x muse2api >/dev/null; then
    local OTHER
    OTHER=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' muse2api 2>/dev/null || true)
    if [ -n "$OTHER" ] && [ "$OTHER" != "$DIR" ]; then die "a muse2api container from $OTHER already exists; use --dir $OTHER to upgrade it"; fi
  elif ss -tlnH "sport = :$PORT" | grep . >/dev/null; then
    die "port $PORT is already in use by: $(listeners "sport = :$PORT")"
  fi

  local IP_NOTE=""
  if [ -n "$IP" ]; then
    printf '%s' "$IP" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' >/dev/null || die "--ip must be an IPv4 address"
  else
    IP=$(detect_ip)
    printf '%s' "$IP" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' >/dev/null || die "could not detect the public IPv4 of this server (a public IPv4 is required); pass --ip ADDRESS"
    if ! local_v4 | grep -x "$IP" >/dev/null; then IP_NOTE=" (seen from outside via api.ipify.org; if this is not the address you reach the server on, re-run with --ip ADDRESS)"; fi
  fi
  say "public IPv4: $IP$IP_NOTE"

  # ------------------------------------------------------------ mode
  ENVF="$DIR/.env"
  local OVR="$DIR/docker-compose.override.yml"
  local MARKER="$DIR/.install-domain" OLD_BASE="" MANAGED_DOMAIN="" MANAGED_KIND="" MODE="ip" ACTIVE=0 WEB="" ADOPT=0
  local SITE=/etc/nginx/conf.d/muse2api.conf
  if [ -d /etc/nginx/sites-available ]; then SITE=/etc/nginx/sites-available/muse2api; fi
  if [ -f "$OVR" ] && ! grep -E "^# managed by (muse2api )?install.sh" "$OVR" >/dev/null && grep -E '^[[:space:]]+volumes:' "$OVR" >/dev/null; then
    die "your $OVR mounts volumes; the installer would replace that file and your accounts could seem to vanish. Move the data back to $DIR/data or remove the volumes entry, then re-run; nothing was changed"
  fi
  local OLD_LOOPBACK=0
  if [ -f "$OVR" ] && grep -E '127[.]0[.]0[.]1:18610' "$OVR" >/dev/null; then OLD_LOOPBACK=1; fi
  if [ -f "$ENVF" ]; then OLD_BASE=$(env_get MUSE2API_PUBLIC_BASE); fi
  if [ -f "$MARKER" ]; then read -r MANAGED_DOMAIN MANAGED_KIND < "$MARKER" || true; fi
  if [ "$NO_DOMAIN" = 1 ]; then
    MODE=ip
  elif [ -n "$DOMAIN" ]; then
    MODE=domain
    if [ "$DOMAIN" = "$MANAGED_DOMAIN" ]; then ACTIVE=1; WEB="${MANAGED_KIND:-nginx}"; fi
  elif [ -n "$MANAGED_DOMAIN" ]; then
    MODE=domain; DOMAIN="$MANAGED_DOMAIN"; ACTIVE=1; WEB="${MANAGED_KIND:-nginx}"
    say "keeping the domain $DOMAIN set up by an earlier run"
  elif [ "${OLD_BASE#https://}" != "$OLD_BASE" ] && [ -f "$OVR" ] && grep '^# managed by install.sh:' "$OVR" >/dev/null; then
    # set up by the first published version of this installer, which kept no marker
    MODE=domain; DOMAIN="${OLD_BASE#https://}"; DOMAIN="${DOMAIN%%/*}"; DOMAIN="${DOMAIN,,}"; ADOPT=1
    say "taking over the domain $DOMAIN set up by an earlier version of this installer"
  elif [ "${OLD_BASE#https://}" != "$OLD_BASE" ]; then
    MODE=external
    warn "MUSE2API_PUBLIC_BASE is $OLD_BASE, served by a front end this installer did not set up; leaving it and the port as they are. Pass --domain NAME to let the installer manage https"
  fi
  # a managed domain whose nginx site lost its certificate goes through the full switch again
  if [ "$MODE" = domain ] && [ "$ACTIVE" = 1 ] && [ "$WEB" = nginx ] && ! grep "ssl_certificate /etc/letsencrypt/live/$DOMAIN/" "$SITE" >/dev/null 2>&1; then
    ACTIVE=0
  fi

  if [ "$MODE" = domain ] && [ "$ACTIVE" = 0 ]; then
    printf '%s' "$DOMAIN" | grep -E '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' >/dev/null || die "not a valid domain name: $DOMAIN"
    local V4S V6S a ok=0
    V4S=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)
    for a in $V4S; do
      if [ "$a" = "$IP" ] || local_v4 | grep -x "$a" >/dev/null; then ok=1; fi
    done
    [ "$ok" = 1 ] || die "$DOMAIN resolves to ${V4S:-nothing}, not to this server ($IP). Add an A record to this server's public IPv4 (on Cloudflare: DNS only, grey cloud), wait a few minutes and re-run. If $IP is not that address, re-run with --ip ADDRESS. muse2api was not touched"
    V6S=$(getent ahostsv6 "$DOMAIN" 2>/dev/null | awk '{print $1}' | grep -v '^::ffff:' | sort -u || true)
    for a in $V6S; do
      local_v6 | grep -xi "$a" >/dev/null || die "$DOMAIN also has an AAAA record ($a) that is not this server; Let's Encrypt checks IPv6 first. Remove or fix the AAAA record and re-run; nothing was changed"
    done
    local HOLDERS PID EXE
    HOLDERS=$(listeners '( sport = :80 or sport = :443 )')
    if [ -z "${HOLDERS// /}" ]; then
      WEB=nginx
    else
      PID=$(first_pid '( sport = :80 or sport = :443 )')
      EXE=$(readlink -f "/proc/${PID:-0}/exe" 2>/dev/null || true)
      if [ "${HOLDERS// /}" = nginx ] && [ "$EXE" = /usr/sbin/nginx ] && dpkg -s nginx >/dev/null 2>&1; then
        WEB=nginx
      else
        case " $HOLDERS " in
          *" docker-proxy "*) die "ports 80/443 are published by a Docker container (docker-proxy); the installer cannot put https in front of muse2api there. Run without --domain, or add a site in that proxy for $DOMAIN to http://$IP:$PORT; nothing was changed" ;;
        esac
        local h known=1
        for h in $HOLDERS; do
          case "$h" in nginx|openresty|apache2|httpd|caddy|litespeed|lshttpd|lsws|openlitespeed) ;; *) known=0 ;; esac
        done
        [ "$known" = 1 ] || die "ports 80/443 are used by: ${HOLDERS}- that is not a web server the installer can work with. Run without --domain, or free the ports; nothing was changed"
        WEB=panel
        warn "ports 80/443 belong to a web server this installer does not manage (${HOLDERS% }); it will install muse2api on http://$IP:$PORT and tell you how to add the https site in your panel"
      fi
    fi
  fi

  if [ "$MODE" = domain ] && [ "$WEB" = nginx ] && [ -f "$SITE" ]; then
    if [ "$ADOPT" = 1 ] && ! grep -x "$SITE_MARK" "$SITE" >/dev/null && grep "server_name $DOMAIN;" "$SITE" >/dev/null && grep 'proxy_pass http://127.0.0.1:18610' "$SITE" >/dev/null; then
      sed -i "1i $SITE_MARK" "$SITE"
    fi
    grep -x "$SITE_MARK" "$SITE" >/dev/null || die "$SITE exists and was not written by this installer; move it away and re-run; nothing was changed"
    grep "server_name $DOMAIN;" "$SITE" >/dev/null || die "$SITE is set up for another domain; remove it (and the old certificate if you no longer need it) and re-run; nothing was changed"
  fi

  # ------------------------------------------------------------ relay checks
  local RELAY_MARK="$RELAY_DIR/.install-relay" RELAY_NEW=0 P_CHAT="" P_IMAGE="" P_VIDEO=""
  if [ "$NO_RELAY" = 1 ] && [ -n "$RELAY" ]; then die "use either --relay or --no-relay"; fi
  if [ -z "$RELAY" ] && [ "$NO_RELAY" = 0 ] && [ -f "$RELAY_MARK" ]; then RELAY=new-api; fi
  if [ "$NO_DOMAIN" = 1 ] && [ "$NO_RELAY" = 0 ] && [ -f "$RELAY_MARK" ]; then die "the relay station runs on the domain; add --no-relay to go back to plain IP; muse2api was not touched"; fi
  if [ -n "$RELAY" ]; then
    if [ "$MODE" != domain ] || [ "$WEB" != nginx ]; then die "the relay needs --domain on a server where this installer sets up nginx; muse2api was not touched"; fi
    if [ ! -f "$RELAY_MARK" ]; then RELAY_NEW=1; fi
    if [ "$RELAY_NEW" = 1 ] && { [ -z "$RELAY_REG" ] || [ -z "$RELAY_PRICE" ]; }; then
      die "first relay install: choose --relay-register open|closed and --relay-price free|chat=X,image=Y,video=Z; muse2api was not touched"
    fi
    if [ -n "$RELAY_PRICE" ]; then
      if [ "$RELAY_PRICE" = free ]; then
        P_CHAT=0; P_IMAGE=0; P_VIDEO=0
      else
        local kv k v
        for kv in ${RELAY_PRICE//,/ }; do
          k="${kv%%=*}"; v="${kv#*=}"
          printf '%s' "$v" | grep -E '^[0-9]+([.][0-9]+)?$' >/dev/null || die "--relay-price: $kv is not a number"
          case "$k" in chat) P_CHAT=$v ;; image) P_IMAGE=$v ;; video) P_VIDEO=$v ;; *) die "--relay-price: unknown item $k (use chat, image, video)" ;; esac
        done
        if [ -z "$P_CHAT" ] || [ -z "$P_IMAGE" ] || [ -z "$P_VIDEO" ]; then die "--relay-price needs all three: chat=X,image=Y,video=Z"; fi
      fi
    fi
    if ss -tlnH "sport = :$RELAY_PORT" | grep . >/dev/null && ! { command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -x new-api >/dev/null; }; then
      die "port $RELAY_PORT is already in use by: $(listeners "sport = :$RELAY_PORT"); muse2api was not touched"
    fi
  fi

  # ------------------------------------------------------------ docker
  if ! command -v docker >/dev/null 2>&1; then
    say "installing Docker from download.docker.com ($DISTRO $CODENAME)"
    curl -fsI --max-time 20 "https://download.docker.com/linux/$DISTRO/dists/$CODENAME/Release" >/dev/null 2>&1 \
      || die "Docker publishes no packages for $DISTRO $CODENAME; install Docker yourself and re-run"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$DISTRO/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$DISTRO $CODENAME stable" > /etc/apt/sources.list.d/docker.list
    APT_UPDATED=0
    if ! (apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin); then
      rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
      die "installing Docker failed; the Docker apt source was removed again"
    fi
  fi
  if ! docker compose version >/dev/null 2>&1; then
    say "installing the docker compose plugin"
    (apt_install docker-compose-plugin) 2>/dev/null || (apt_install docker-compose-v2) || die "Docker is installed but 'docker compose' is missing; install the compose plugin and re-run"
  fi
  systemctl enable --now docker >/dev/null 2>&1 || die "could not start the docker service"
  say "$(docker --version); $(docker compose version)"

  # ------------------------------------------------------------ code
  if [ -d "$DIR/.git" ]; then
    local rc=0
    # data/ is runtime state (the admin page may delete its .gitkeep files), so it is not checked
    g diff --quiet HEAD -- . ':(exclude)data' || rc=$?
    if [ "$rc" = 1 ]; then die "tracked files in $DIR were changed by hand ($(g diff --name-only HEAD -- . ':(exclude)data' | tr '\n' ' ' || true)); save or restore them and re-run"; fi
    if [ "$rc" != 0 ]; then die "git cannot read $DIR (exit $rc): $(g status 2>&1 | awk 'NR==1' || true)"; fi
    local ORIGIN
    ORIGIN=$(g remote get-url origin 2>/dev/null || true)
    case "$ORIGIN" in "$REPO_URL"|"$REPO_URL.git") ;; *) warn "$DIR came from ${ORIGIN:-unknown}; fetching $REPO_URL instead" ;; esac
    say "updating $DIR to $REF"
  elif [ -e "$DIR" ]; then
    die "$DIR exists and is not a git checkout; move it away or use --dir"
  else
    say "downloading $REPO_URL into $DIR"
    git clone -q "$REPO_URL" "$DIR"
  fi
  g fetch -q "$REPO_URL" "$REF" || die "could not fetch $REF from $REPO_URL"
  g checkout -q --detach FETCH_HEAD
  local COMMIT VERSION
  COMMIT=$(g rev-parse HEAD)
  VERSION=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$DIR/version.json" 2>/dev/null | awk 'NR==1' || true)
  say "code at ${VERSION:-unknown version} (${COMMIT:0:12})"

  # ------------------------------------------------------------ .env
  umask 077
  touch "$ENVF"
  local KEY NEW_KEY=0 KEY_NOTE="" MOVED=0
  KEY=$(env_get MUSE2API_KEY)
  if [ -z "$KEY" ] && [ -f "$OVR" ] && ! grep -E "^# managed by (muse2api )?install.sh" "$OVR" >/dev/null 2>&1; then
    KEY=$(sed -n -E 's/^[^#$]*MUSE2API_KEY[[:space:]]*[=:][[:space:]]*//p' "$OVR" | awk 'NR==1' | tr -d '\r' \
      | sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\\(.*\\)'\$/\\1/" || true)
    case "$KEY" in *'$'*|*'{'*) KEY="" ;; esac
    if [ ${#KEY} -ge 8 ]; then
      if env_has MUSE2API_KEY; then cp -p "$ENVF" "$ENVF.bak-$(date +%Y%m%d%H%M%S)"; chmod 600 "$ENVF".bak-*; fi
      env_set MUSE2API_KEY "$KEY"; MOVED=1
    else
      KEY=""
    fi
  fi
  if [ -z "$KEY" ] && env_has MUSE2API_KEY; then
    cp -p "$ENVF" "$ENVF.bak-$(date +%Y%m%d%H%M%S)"; chmod 600 "$ENVF".bak-*
  fi
  if [ -z "$KEY" ]; then
    env_set MUSE2API_KEY "m2a_$(openssl rand -hex 24)"; NEW_KEY=1; KEY_NOTE="generated a new API key in $ENVF"
  elif [ "$KEY" = "$PLACEHOLDER_KEY" ]; then
    cp -p "$ENVF" "$ENVF.bak-$(date +%Y%m%d%H%M%S)"; chmod 600 "$ENVF".bak-*
    env_set MUSE2API_KEY "m2a_$(openssl rand -hex 24)"; NEW_KEY=2
    KEY_NOTE="the API key was the public example key from .env.example; it was REPLACED with a new one (old .env saved as .env.bak-*). Update your clients"
    warn "$KEY_NOTE"
  elif ! printf '%s' "$KEY" | grep -E '^m2a_[0-9a-f]{48}$' >/dev/null; then
    KEY_NOTE="kept your own API key in $ENVF (it is not in the m2a_ + 48 hex format the installer generates)"
  else
    KEY_NOTE="kept the API key in $ENVF"
  fi
  if [ "$MOVED" = 1 ]; then KEY_NOTE="moved the API key from your docker-compose.override.yml into .env; $KEY_NOTE"; fi
  local BASE="http://$IP:$PORT" BIND=public
  case "$MODE" in
    domain) if [ "$ACTIVE" = 1 ]; then BASE="https://$DOMAIN"; BIND=loopback; fi ;;
    external) BASE="$OLD_BASE"; if [ "$OLD_LOOPBACK" = 1 ]; then BIND=loopback; fi ;;
  esac
  if [ "$MODE" != external ]; then env_set MUSE2API_PUBLIC_BASE "$BASE"; fi
  env_default MUSE2API_CONCURRENCY 2
  env_set     MUSE2API_REPOSITORY "$REPO_SLUG"
  env_default MUSE2API_REPO_REF main
  env_set     MUSE2API_MANAGED_DEPLOYMENT 1
  env_default MUSE2API_KEEPALIVE_DISABLED_ACCOUNTS 0
  env_default MUSE2API_REF_IMAGE_LOCAL_FILES 0
  env_default MUSE2API_REF_IMAGE_PRIVATE_FETCH 0
  chown root:root "$ENVF"
  chmod 600 "$ENVF"
  umask 022
  if grep '^GITHUB_TOKEN=' "$ENVF" >/dev/null; then warn ".env contains GITHUB_TOKEN; with it the admin page can push to GitHub. Remove it unless you need that"; fi
  say "$KEY_NOTE"

  # ------------------------------------------------------------ compose override, build, start
  write_override() {
    if [ -f "$OVR" ] && ! grep -E "^# managed by (muse2api )?install.sh" "$OVR" >/dev/null; then
      cp -p "$OVR" "$OVR.bak-$(date +%Y%m%d%H%M%S)"; chmod 600 "$OVR".bak-*
      warn "your docker-compose.override.yml was saved as .bak-* and replaced; its settings ($(grep -E '^    [a-z_]+:' "$OVR" | tr -d ' :' | tr '\n' ' ' || true)) no longer apply. Put settings in .env"
    fi
    {
      echo "$SITE_MARK"
      echo "# rewritten on every run. Put your own settings in .env."
      echo "services:"
      echo "  muse2api:"
      echo "    env_file:"
      echo "      - .env"
      echo "    environment:"
      echo '      - MUSE2API_PUBLIC_BASE=${MUSE2API_PUBLIC_BASE}'
      echo '      - MUSE2API_IMAGE_TIMEOUT=${MUSE2API_IMAGE_TIMEOUT:-240}'
      echo '      - MUSE2API_VIDEO_TIMEOUT=${MUSE2API_VIDEO_TIMEOUT:-600}'
      echo '      - MUSE2API_CHAT_TIMEOUT=${MUSE2API_CHAT_TIMEOUT:-300}'
      echo "      - MUSE2API_BUILD_SHA=$COMMIT"
      if [ "$1" = loopback ]; then
        echo "    ports: !override"
        echo "      - \"127.0.0.1:$PORT:$PORT\""
      fi
      echo "    logging:"
      echo "      driver: json-file"
      echo "      options:"
      echo "        max-size: \"10m\""
      echo "        max-file: \"3\""
    } > "$OVR.tmp"
    mv "$OVR.tmp" "$OVR"
  }
  # nginx applies a reload a moment after "systemctl reload" returns
  retry_https() {
    local i
    for i in $(seq 1 15); do
      if curl -fsS --max-time 10 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN$1" >/dev/null 2>&1; then return 0; fi
      sleep 1
    done
    return 1
  }
  wait_healthy() {
    local i
    for i in $(seq 1 60); do
      if curl -fsS --max-time 3 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then return 0; fi
      sleep 2
    done
    docker compose logs --tail 40 >&2 || true
    die "the service did not become healthy"
  }
  write_override "$BIND"
  cd "$DIR"
  local OLD_IMG NEW_IMG
  OLD_IMG=$(docker image inspect -f '{{.Id}}' muse2api:latest 2>/dev/null || true)
  say "building the image (a few minutes the first time)"
  docker compose build </dev/null
  docker compose up -d </dev/null
  wait_healthy
  NEW_IMG=$(docker image inspect -f '{{.Id}}' muse2api:latest 2>/dev/null || true)
  if [ -n "$OLD_IMG" ] && [ "$OLD_IMG" != "$NEW_IMG" ]; then docker image rm "$OLD_IMG" >/dev/null 2>&1 || true; fi
  say "service is up on port $PORT"

  # ------------------------------------------------------------ https
  local PENDING=0
  if [ "$MODE" = domain ] && [ "$WEB" = nginx ]; then
    apt_install nginx certbot python3-certbot-nginx
    if [ -d /etc/nginx/sites-available ]; then SITE=/etc/nginx/sites-available/muse2api; fi
    if [ ! -f "$SITE" ]; then
      {
        echo "$SITE_MARK"
        sed "s/server_name [^;]*;/server_name $DOMAIN;/" "$DIR/deploy/nginx.example.conf"
      } > "$SITE"
      if [ -n "$(local_v6)" ] && [ -n "$(getent ahostsv6 "$DOMAIN" 2>/dev/null | awk '{print $1}' | grep -v '^::ffff:' || true)" ]; then
        sed -i 's/^\([[:space:]]*\)listen 80;/\1listen 80;\n\1listen [::]:80;/' "$SITE"
      fi
      if [ "$SITE" = /etc/nginx/sites-available/muse2api ]; then ln -sfn "$SITE" /etc/nginx/sites-enabled/muse2api; fi
      say "wrote $SITE"
    fi
    systemctl enable --now nginx >/dev/null 2>&1 || true
    nginx -t >/dev/null 2>&1 || die "nginx -t failed: $(nginx -t 2>&1 | tail -n 2 | tr '\n' ' ' || true)"
    systemctl reload nginx
    if ! grep "ssl_certificate /etc/letsencrypt/live/$DOMAIN/" "$SITE" >/dev/null; then
      say "requesting a Let's Encrypt certificate for $DOMAIN"
      if ! certbot --nginx -d "$DOMAIN" --agree-tos --register-unsafely-without-email --redirect --keep-until-expiring --non-interactive </dev/null; then
        die "certbot could not get a certificate for $DOMAIN (its reason is in the lines above). The usual cause is that Let's Encrypt cannot reach this server on TCP port 80: open ports 80 and 443 in your provider's security group or firewall (Oracle Cloud images also block them in iptables), then re-run. Nothing was switched: muse2api still answers on http://$IP:$PORT"
      fi
    fi
    if [ "$ACTIVE" = 0 ]; then
      echo "$DOMAIN nginx" > "$MARKER"
      env_set MUSE2API_PUBLIC_BASE "https://$DOMAIN"; BASE="https://$DOMAIN"
      write_override loopback; BIND=loopback
      docker compose up -d </dev/null
      wait_healthy
    fi
    # once the relay owns "/", muse2api is reached under /admin
    local HCHK=/healthz
    if grep '# muse2api-direct' "$SITE" >/dev/null; then HCHK=/admin; fi
    retry_https "$HCHK" || die "https://$DOMAIN$HCHK does not answer through nginx; check $SITE and 'nginx -t'"
    say "https is on: https://$DOMAIN"
  elif [ "$MODE" = domain ] && [ "$WEB" = panel ]; then
    if curl -fsS --max-time 15 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/healthz" >/dev/null 2>&1; then
      if [ "$ACTIVE" = 0 ]; then
        echo "$DOMAIN panel" > "$MARKER"
        env_set MUSE2API_PUBLIC_BASE "https://$DOMAIN"; BASE="https://$DOMAIN"
        write_override loopback; BIND=loopback
        docker compose up -d </dev/null
        wait_healthy
        if ! curl -fsS --max-time 15 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/healthz" >/dev/null 2>&1; then
          rm -f "$MARKER"
          env_set MUSE2API_PUBLIC_BASE "http://$IP:$PORT"; BASE="http://$IP:$PORT"
          write_override public
          docker compose up -d </dev/null
          wait_healthy
          die "your panel's site for $DOMAIN stopped answering once muse2api moved to 127.0.0.1; it must proxy to http://127.0.0.1:$PORT. Switched back: muse2api answers on http://$IP:$PORT"
        fi
      fi
      say "https through your panel works: https://$DOMAIN"
    elif [ "$ACTIVE" = 1 ]; then
      die "https://$DOMAIN/healthz no longer answers through your panel; check that its site proxies to http://127.0.0.1:$PORT, or re-run with --no-domain"
    else
      PENDING=1
    fi
  elif [ "$MODE" = ip ] && [ -f "$MARKER" ]; then
    rm -f "$MARKER"
    say "back on plain IP; the nginx site and certificate for $MANAGED_DOMAIN were left in place"
  fi

  # ------------------------------------------------------------ relay station off
  if [ "$NO_RELAY" = 1 ] && [ -f "$RELAY_MARK" ]; then
    (cd "$RELAY_DIR" && docker compose down </dev/null) || true
    rm -f "$RELAY_MARK"
    if [ -f "$SITE" ] && grep '# muse2api-direct' "$SITE" >/dev/null; then
      sed -i "/# muse2api-direct/! s#proxy_pass http://127.0.0.1:$RELAY_PORT;#proxy_pass http://127.0.0.1:$PORT;#" "$SITE"
      if nginx -t >/dev/null 2>&1; then systemctl reload nginx; fi
    fi
    say "relay station stopped; its data stays in $RELAY_DIR (run with --relay new-api to start it again)"
  fi

  # ------------------------------------------------------------ relay station (New API)
  local RELAY_ON=0
  if [ -n "$RELAY" ]; then
    apt_install jq
    install -d -m 700 "$RELAY_DIR"
    local NET MKEY SAVE_ENVF="$ENVF"
    NET=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' muse2api 2>/dev/null | awk '{print $1}' || true)
    [ -n "$NET" ] || die "cannot find the Docker network of the muse2api container"
    MKEY=$(env_get MUSE2API_KEY)
    ENVF="$RELAY_DIR/.env"
    umask 077
    touch "$ENVF"
    env_default SESSION_SECRET "$(openssl rand -hex 32)"
    env_default CRYPTO_SECRET "$(openssl rand -hex 32)"
    env_set     SESSION_COOKIE_SECURE true
    env_set     SESSION_COOKIE_TRUSTED_URL "https://$DOMAIN"
    env_default STREAMING_TIMEOUT 600
    env_default MAX_REQUEST_BODY_MB 200
    chmod 600 "$ENVF"
    umask 022
    ENVF="$SAVE_ENVF"
    {
      echo "$SITE_MARK"
      echo "services:"
      echo "  new-api:"
      echo "    image: $NEWAPI_IMAGE"
      echo "    container_name: new-api"
      echo "    restart: always"
      echo "    env_file:"
      echo "      - .env"
      echo "    volumes:"
      echo "      - ./data:/data"
      echo "    ports:"
      echo "      - \"127.0.0.1:$RELAY_PORT:3000\""
      echo "    networks:"
      echo "      - default"
      echo "      - muse2api"
      echo "    logging:"
      echo "      driver: json-file"
      echo "      options:"
      echo "        max-size: \"10m\""
      echo "        max-file: \"3\""
      echo "networks:"
      echo "  muse2api:"
      echo "    external: true"
      echo "    name: $NET"
    } > "$RELAY_DIR/docker-compose.yml"
    say "starting New API ($NEWAPI_IMAGE)"
    (cd "$RELAY_DIR" && docker compose pull -q </dev/null && docker compose up -d </dev/null)
    local i up=0
    for i in $(seq 1 60); do
      if curl -fsS --max-time 3 "http://127.0.0.1:$RELAY_PORT/api/status" >/dev/null 2>&1; then up=1; break; fi
      sleep 2
    done
    if [ "$up" != 1 ]; then (cd "$RELAY_DIR" && docker compose logs --tail 40 >&2) || true; die "New API did not start"; fi

    local NA="http://127.0.0.1:$RELAY_PORT" ADMIN_FILE="$RELAY_DIR/.admin" PW="" TOKEN="" R="" CH_ID=""
    if [ "$(curl -fsS "$NA/api/setup" | jq -r '.data.status' || true)" != true ]; then
      PW=$(openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | head -c 20 || true)
      umask 077
      printf 'username=root\npassword=%s\n' "$PW" > "$ADMIN_FILE"
      umask 022
      R=$(jq -n --arg p "$PW" '{username:"root",password:$p,confirmPassword:$p,SelfUseModeEnabled:false,DemoSiteEnabled:false}' \
        | curl -fsS -X POST "$NA/api/setup" -H 'Content-Type: application/json' --data-binary @- || true)
      [ "$(printf '%s' "$R" | jq -r '.success' 2>/dev/null || true)" = true ] || die "New API setup failed: $(printf '%s' "$R" | jq -r '.message' 2>/dev/null || true)"
      say "New API admin created: user root, password in $ADMIN_FILE"
    elif [ -f "$ADMIN_FILE" ]; then
      PW=$(sed -n 's/^password=//p' "$ADMIN_FILE")
    fi
    if [ -n "$PW" ]; then
      TOKEN=$(jq -n --arg p "$PW" '{username:"root",password:$p}' \
        | curl -fsS -X POST "$NA/api/user/login" -H 'Content-Type: application/json' --data-binary @- | jq -r '.data.access_token // empty' || true)
    fi
    if [ -z "$TOKEN" ]; then
      warn "could not log in to New API as root with the password in $ADMIN_FILE (changed in the web page?); the muse2api channel, sign-up and prices were not updated on this run"
    else
      na() { local m="$1" p="$2"; shift 2; curl -fsS -X "$m" "$NA$p" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' "$@"; }
      ch_id() { na GET "/api/channel/search?keyword=muse2api" | jq -r '[.. | objects | select(.name? == "muse2api") | .id] | first // empty' || true; }
      CH_ID=$(ch_id)
      if [ -z "$CH_ID" ]; then
        R=$(jq -n --arg k "$MKEY" '{mode:"single",channel:{type:1,name:"muse2api",key:$k,base_url:"http://muse2api:18610",models:"muse-spark,muse-image,muse-video",group:"default"}}' \
          | na POST /api/channel/ --data-binary @- || true)
        [ "$(printf '%s' "$R" | jq -r '.success' 2>/dev/null || true)" = true ] || die "adding the muse2api channel to New API failed: $(printf '%s' "$R" | jq -r '.message' 2>/dev/null || true)"
        CH_ID=$(ch_id)
        say "added muse2api as a New API channel"
      else
        R=$(jq -n --argjson id "$CH_ID" --arg k "$MKEY" '{id:$id,type:1,name:"muse2api",key:$k,base_url:"http://muse2api:18610",models:"muse-spark,muse-image,muse-video",group:"default"}' \
          | na PUT /api/channel/ --data-binary @- || true)
        [ "$(printf '%s' "$R" | jq -r '.success' 2>/dev/null || true)" = true ] || warn "updating the muse2api channel in New API failed: $(printf '%s' "$R" | jq -r '.message' 2>/dev/null || true)"
      fi
      if [ -n "$RELAY_REG" ]; then
        R=$(jq -n --argjson v "$([ "$RELAY_REG" = open ] && echo true || echo false)" '{key:"RegisterEnabled",value:$v}' | na PUT /api/option/ --data-binary @- || true)
        [ "$(printf '%s' "$R" | jq -r '.success' 2>/dev/null || true)" = true ] || die "setting sign-up in New API failed: $(printf '%s' "$R" | jq -r '.message' 2>/dev/null || true)"
        say "New API sign-up: $RELAY_REG"
      fi
      if [ -n "$P_CHAT" ]; then
        local MP
        MP=$(na GET /api/option/ | jq -r '[.data[]? | select(.key == "ModelPrice") | .value] | first // "{}"' || true)
        if [ -z "$MP" ] || [ "$MP" = null ]; then MP='{}'; fi
        MP=$(printf '%s' "$MP" | jq -c --argjson c "$P_CHAT" --argjson i "$P_IMAGE" --argjson v "$P_VIDEO" '. + {"muse-spark": $c, "muse-image": $i, "muse-video": $v}')
        R=$(jq -n --arg v "$MP" '{key:"ModelPrice",value:$v}' | na PUT /api/option/ --data-binary @- || true)
        [ "$(printf '%s' "$R" | jq -r '.success' 2>/dev/null || true)" = true ] || die "setting prices in New API failed: $(printf '%s' "$R" | jq -r '.message' 2>/dev/null || true)"
        say "New API prices per call (USD): chat $P_CHAT, image $P_IMAGE, video $P_VIDEO"
      fi
      if [ "$RELAY_NEW" = 1 ] && [ -n "$CH_ID" ]; then
        R=$(na GET "/api/channel/test/$CH_ID?model=muse-spark" || true)
        if [ "$(printf '%s' "$R" | jq -r '.success // false' 2>/dev/null || true)" = true ]; then
          say "New API reached muse2api (channel test passed)"
        else
          warn "New API's test of the muse2api channel did not pass: $(printf '%s' "$R" | jq -r '.message // empty' 2>/dev/null || true)"
        fi
      fi
    fi
    # nginx: /admin and /v1/media/ stay with muse2api, everything else goes to New API
    if ! grep '# muse2api-direct' "$SITE" >/dev/null; then
      sed -i '/^[[:space:]]*location \/ {/i\    location ^~ /v1/media/ {\n        limit_except GET { deny all; }\n        proxy_pass http://127.0.0.1:18610; # muse2api-direct\n        proxy_set_header Host $host;\n    }\n    location ^~ /admin {\n        proxy_pass http://127.0.0.1:18610; # muse2api-direct\n        proxy_read_timeout 600s;\n        proxy_buffering off;\n        client_max_body_size 200M;\n        proxy_set_header Host $host;\n        proxy_set_header X-Forwarded-Proto $scheme;\n    }' "$SITE"
    fi
    sed -i "/# muse2api-direct/! s#proxy_pass http://127.0.0.1:$PORT;#proxy_pass http://127.0.0.1:$RELAY_PORT;#" "$SITE"
    nginx -t >/dev/null 2>&1 || die "nginx -t failed after adding the relay: $(nginx -t 2>&1 | tail -n 2 | tr '\n' ' ' || true)"
    systemctl reload nginx
    retry_https /api/status || die "https://$DOMAIN/api/status (New API) does not answer through nginx"
    echo "$RELAY" > "$RELAY_MARK"
    RELAY_ON=1
    say "relay station is on: https://$DOMAIN"
  fi

  # ------------------------------------------------------------ summary
  if [ "$RELAY_ON" = 1 ]; then
    cat <<EOF

relay station (New API) is running on https://$DOMAIN
  API base    https://$DOMAIN/v1   people use keys they create in New API; models muse-spark, muse-image, muse-video
  New API     https://$DOMAIN   admin user root, password on this server: grep ^password= $RELAY_DIR/.admin
              (if you change it in the web page, also change that file, or later runs cannot update New API)
  payments    New API asks you to confirm its compliance terms before payments, top-ups and redeem codes work;
              payment providers are set up in its settings
EOF
  fi
  cat <<EOF

muse2api is running: ${VERSION:-?} (${COMMIT:0:12}) in $DIR
  API base    $BASE/v1        models: muse-spark, muse-image, muse-video$([ "$RELAY_ON" = 1 ] && echo "   (behind the relay: use New API keys there)")
  admin page  $BASE/admin?key=<your key>
  your key    on this server: grep ^MUSE2API_KEY= $ENVF
              to change it, edit that line and re-run this installer; the admin page's
              regenerate button only lasts until the next container restart
  add accounts, on your own computer with Chrome (fetch the files over ssh; they run on your computer):
    Python helper      scp root@$IP:$DIR/tools/get_muse_cookie.py .   then run it with MUSE2API_BASE and MUSE2API_KEY set
    browser extension  scp -r root@$IP:$DIR/extension .   then load that folder in chrome://extensions, log in to muse.ai, click it
  upgrade     run the same install command again
EOF
  if [ "$NEW_KEY" = 2 ]; then echo "  KEY         the old key was the public example key and has been replaced. Update your clients."; fi
  if [ "${BASE#https://}" = "$BASE" ]; then
    echo "  note        plain HTTP: the key and cookies travel unencrypted, and files downloaded from $BASE"
    echo "              could be swapped on the way. Use --domain for https."
  fi
  if [ "$BIND" = public ] || [ "${BASE#https://}" = "$BASE" ]; then
    echo "  network     port $PORT is published by Docker on all addresses, which ufw does not filter; if it is"
    echo "              unreachable from outside, open TCP $PORT in your provider's security group or panel."
  fi
  if [ ${#WARNS[@]} -gt 0 ]; then
    local w
    for w in "${WARNS[@]}"; do echo "  WARNING     $w"; done
  fi
  if [ "$PENDING" = 1 ]; then
    echo "  https       add a site for $DOMAIN in your panel that reverse proxies to http://127.0.0.1:$PORT,"
    echo "              with an SSL certificate, proxy_read_timeout 600s and proxy_buffering off"
    echo "              (see $DIR/deploy/nginx.example.conf). Then re-run this command with --domain $DOMAIN."
    echo "              Until then muse2api answers on http://$IP:$PORT"
    echo "MUSE2API_INSTALL_PENDING_PROXY base=https://$DOMAIN local=http://$IP:$PORT commit=$COMMIT"
  else
    echo "MUSE2API_INSTALL_OK base=$BASE commit=$COMMIT domain=$([ "$MODE" = domain ] && echo "$DOMAIN" || echo none) relay=$([ "$RELAY_ON" = 1 ] && echo new-api || echo none)"
  fi
}

main "$@"
