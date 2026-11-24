#!/usr/bin/env bash
# muse2api one-line installer for Ubuntu / Debian servers.
#
#   curl -fsSL https://raw.githubusercontent.com/adsorgcn/muse2api/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/adsorgcn/muse2api/main/install.sh | bash -s -- --domain api.example.com
#
# Run it as root on the server. Run the same line again to upgrade: .env (your API key)
# and data/ (your accounts) are kept. It never touches sshd, root login, passwords,
# users, SSH keys or the firewall, and never runs apt upgrade.
#
# Options
#   --domain NAME   serve on https://NAME (nginx + Let's Encrypt, no e-mail); NAME must
#                   already resolve to this server (Cloudflare: DNS only, not proxied)
#   --no-domain     go back to plain http://IP:18610
#   --ip ADDRESS    public IPv4 to use when it cannot be detected
#   --dir PATH      install directory (default /opt/muse2api)
#   --ref REF       branch, tag or commit to deploy (default main)
#   --force         continue when memory, disk or the muse.ai check is below the minimum
set -euo pipefail

REPO_URL="https://github.com/adsorgcn/muse2api"
REPO_SLUG="adsorgcn/muse2api"
PORT=18610

say()  { printf '[muse2api] %s\n' "$*"; }
warn() { printf '[muse2api] WARNING: %s\n' "$*" >&2; }
die()  { printf '[muse2api] ERROR: %s\n' "$*" >&2; exit 1; }

# name of the process listening on a port filter, e.g. "sport = :80"
listeners() { ss -tlnpH "$1" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | sort -u | tr '\n' ' '; }

is_private() {
  case "$1" in
    10.*|192.168.*|127.*|169.254.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
  esac
  return 1
}

detect_ip() {
  local a
  a=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')
  if [ -z "$a" ] || is_private "$a"; then a=$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true); fi
  printf '%s' "$a"
}

APT_UPDATED=0
apt_install() {
  local missing=() p
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  if [ "$APT_UPDATED" = 0 ]; then apt-get update -q </dev/null; APT_UPDATED=1; fi
  say "installing ${missing[*]}"
  apt-get install -y -q --no-install-recommends "${missing[@]}" </dev/null
}

env_get()     { sed -n "s/^$1=//p" "$ENVF" | tail -n 1; }
env_set()     { if grep "^$1=" "$ENVF" >/dev/null; then sed -i "s|^$1=.*|$1=$2|" "$ENVF"; else printf '%s=%s\n' "$1" "$2" >> "$ENVF"; fi; }
env_default() { grep "^$1=" "$ENVF" >/dev/null || printf '%s=%s\n' "$1" "$2" >> "$ENVF"; }

# The whole file is read before main runs, so "curl ... | bash" cannot lose the rest of the script.
main() {
  local DIR="/opt/muse2api" REF="main" DOMAIN="" NO_DOMAIN=0 IP="" FORCE=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --domain)    DOMAIN="${2:-}"; [ -n "$DOMAIN" ] || die "--domain needs a name"; shift 2 ;;
      --no-domain) NO_DOMAIN=1; shift ;;
      --ip)        IP="${2:-}"; [ -n "$IP" ] || die "--ip needs an address"; shift 2 ;;
      --dir)       DIR="${2:-}"; [ -n "$DIR" ] || die "--dir needs a path"; shift 2 ;;
      --ref)       REF="${2:-}"; [ -n "$REF" ] || die "--ref needs a value"; shift 2 ;;
      --force)     FORCE=1; shift ;;
      -h|--help)   echo "see the comments at the top of install.sh"; return 0 ;;
      *)           die "unknown option: $1" ;;
    esac
  done
  if [ -n "$DOMAIN" ] && [ "$NO_DOMAIN" = 1 ]; then die "use either --domain or --no-domain"; fi
  DOMAIN="${DOMAIN,,}"
  need_or_force() { if [ "$FORCE" = 1 ]; then warn "$1 (continuing because of --force)"; else die "$1 (re-run with --force to continue anyway)"; fi; }

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
  say "system: ${PRETTY_NAME:-$ID} $(uname -m)"
  export DEBIAN_FRONTEND=noninteractive
  apt_install ca-certificates curl git openssl iproute2

  # ------------------------------------------------------------ checks
  local MEM_MB DISK_MB MUSE_CODE
  MEM_MB=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
  DISK_MB=$(df -Pm / | awk 'NR==2 {print $4}')
  say "memory ${MEM_MB} MiB, free disk ${DISK_MB} MiB"
  [ "$MEM_MB" -ge 1700 ] || need_or_force "about 2 GB of memory is needed (found ${MEM_MB} MiB); adding swap helps"
  [ "$DISK_MB" -ge 5000 ] || need_or_force "about 5 GB of free disk is needed (found ${DISK_MB} MiB)"
  MUSE_CODE=$(curl -s -o /dev/null --max-time 20 -w '%{http_code}' https://muse.ai/ || true)
  case "$MUSE_CODE" in
    2??|3??) say "muse.ai reachable (HTTP $MUSE_CODE)" ;;
    *) need_or_force "this server cannot open https://muse.ai/ (HTTP ${MUSE_CODE:-none})" ;;
  esac

  if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -x muse2api >/dev/null; then
    local OTHER
    OTHER=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' muse2api 2>/dev/null || true)
    if [ -n "$OTHER" ] && [ "$OTHER" != "$DIR" ]; then die "a muse2api container from $OTHER already exists; use --dir $OTHER to upgrade it"; fi
  elif [ -n "$(listeners "sport = :$PORT")" ] || ss -tlnH "sport = :$PORT" | grep . >/dev/null; then
    die "port $PORT is already in use by: $(listeners "sport = :$PORT")"
  fi

  [ -n "$IP" ] || IP=$(detect_ip)
  printf '%s' "$IP" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' >/dev/null || die "could not detect the public IPv4 of this server; pass --ip ADDRESS"

  # keep an existing https setup on a plain re-run
  ENVF="$DIR/.env"
  if [ -z "$DOMAIN" ] && [ "$NO_DOMAIN" = 0 ] && [ -f "$ENVF" ]; then
    local OLD_BASE
    OLD_BASE=$(env_get MUSE2API_PUBLIC_BASE)
    case "$OLD_BASE" in https://*) DOMAIN="${OLD_BASE#https://}"; DOMAIN="${DOMAIN%%/*}"; say "keeping the existing domain $DOMAIN" ;; esac
  fi

  local WEB_MODE="" WEB_PROCS RESOLVED
  if [ -n "$DOMAIN" ]; then
    printf '%s' "$DOMAIN" | grep -E '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' >/dev/null || die "not a valid domain name: $DOMAIN"
    RESOLVED=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1 {print $1}')
    [ "$RESOLVED" = "$IP" ] || die "$DOMAIN resolves to ${RESOLVED:-nothing}, not to this server ($IP). Add an A record to $IP (on Cloudflare: DNS only, grey cloud) and re-run"
    WEB_PROCS=$(listeners '( sport = :80 or sport = :443 )')
    if [ -z "${WEB_PROCS// /}" ]; then
      WEB_MODE=nginx
    elif [ "${WEB_PROCS// /}" = "nginx" ] && systemctl is-active --quiet nginx 2>/dev/null; then
      WEB_MODE=nginx
    else
      WEB_MODE=panel
      warn "ports 80/443 are held by: ${WEB_PROCS}- nginx and certbot will not be installed; see the note at the end"
    fi
  fi
  local BASE="http://$IP:$PORT"
  [ -z "$DOMAIN" ] || BASE="https://$DOMAIN"

  # ------------------------------------------------------------ docker
  if ! command -v docker >/dev/null 2>&1; then
    say "installing Docker from download.docker.com ($DISTRO $CODENAME)"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$DISTRO/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$DISTRO $CODENAME stable" > /etc/apt/sources.list.d/docker.list
    APT_UPDATED=0
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  if ! docker compose version >/dev/null 2>&1; then
    say "installing the docker compose plugin"
    apt_install docker-compose-plugin 2>/dev/null || apt_install docker-compose-v2 || die "Docker is installed but 'docker compose' is missing; install the compose plugin and re-run"
  fi
  systemctl enable --now docker >/dev/null 2>&1 || die "could not start the docker service"
  say "$(docker --version); $(docker compose version)"

  # ------------------------------------------------------------ code
  if [ -d "$DIR/.git" ]; then
    git -C "$DIR" diff --quiet HEAD || die "tracked files in $DIR were changed by hand; restore them (git -C $DIR checkout -- .) and re-run"
    local ORIGIN
    ORIGIN=$(git -C "$DIR" remote get-url origin 2>/dev/null || true)
    case "$ORIGIN" in "$REPO_URL"|"$REPO_URL.git") ;; *) warn "$DIR came from ${ORIGIN:-unknown}; fetching $REPO_URL instead" ;; esac
    say "updating $DIR to $REF"
  elif [ -e "$DIR" ]; then
    die "$DIR exists and is not a git checkout; move it away or use --dir"
  else
    say "downloading $REPO_URL into $DIR"
    git clone -q "$REPO_URL" "$DIR"
  fi
  git -C "$DIR" fetch -q "$REPO_URL" "$REF"
  git -C "$DIR" checkout -q --detach FETCH_HEAD
  local COMMIT VERSION
  COMMIT=$(git -C "$DIR" rev-parse HEAD)
  VERSION=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$DIR/version.json" 2>/dev/null | awk 'NR==1')
  say "code at ${VERSION:-unknown version} (${COMMIT:0:12})"

  # ------------------------------------------------------------ .env
  umask 077
  touch "$ENVF"
  local NEW_KEY=0
  case "$(env_get MUSE2API_KEY)" in
    m2a_?*) ;;
    *) env_set MUSE2API_KEY "m2a_$(openssl rand -hex 24)"; NEW_KEY=1 ;;
  esac
  env_set     MUSE2API_PUBLIC_BASE "$BASE"
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
  if [ "$NEW_KEY" = 1 ]; then say "generated a new API key in $ENVF"; else say "kept the API key in $ENVF"; fi

  # ------------------------------------------------------------ compose override
  local OVR="$DIR/docker-compose.override.yml"
  if [ -f "$OVR" ] && ! grep '^# managed by install.sh' "$OVR" >/dev/null; then
    cp -p "$OVR" "$OVR.bak-$(date +%Y%m%d%H%M%S)"
    say "saved your previous docker-compose.override.yml next to it (.bak-*)"
  fi
  {
    echo "# managed by install.sh: rewritten on every run. Put your own settings in .env."
    echo "services:"
    echo "  muse2api:"
    echo "    build:"
    echo "      args:"
    echo "        BUILD_SHA: $COMMIT"
    echo "    env_file:"
    echo "      - .env"
    echo "    environment:"
    echo '      - MUSE2API_PUBLIC_BASE=${MUSE2API_PUBLIC_BASE}'
    if [ -n "$DOMAIN" ]; then
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

  # ------------------------------------------------------------ build and start
  cd "$DIR"
  say "building the image (a few minutes the first time)"
  docker compose build </dev/null
  docker compose up -d </dev/null
  local i
  for i in $(seq 1 60); do
    curl -fsS --max-time 3 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
    sleep 2
  done
  curl -fsS --max-time 3 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 || { docker compose logs --tail 40 >&2 || true; die "the service did not become healthy"; }
  say "service is up on port $PORT"

  # ------------------------------------------------------------ https
  if [ "$WEB_MODE" = nginx ]; then
    apt_install nginx certbot python3-certbot-nginx
    local SITE=/etc/nginx/conf.d/muse2api.conf
    [ -d /etc/nginx/sites-available ] && SITE=/etc/nginx/sites-available/muse2api
    if [ ! -f "$SITE" ]; then
      sed "s/server_name [^;]*;/server_name $DOMAIN;/" "$DIR/deploy/nginx.example.conf" > "$SITE"
      if [ "$SITE" = /etc/nginx/sites-available/muse2api ]; then ln -sfn "$SITE" /etc/nginx/sites-enabled/muse2api; fi
      say "wrote $SITE"
    elif ! grep "server_name $DOMAIN;" "$SITE" >/dev/null; then
      warn "$SITE already exists for another name; left it unchanged"
    fi
    systemctl enable --now nginx >/dev/null 2>&1 || true
    nginx -t >/dev/null 2>&1 || die "nginx -t failed; check $SITE"
    systemctl reload nginx
    if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
      say "requesting a Let's Encrypt certificate for $DOMAIN"
      certbot --nginx -d "$DOMAIN" --agree-tos --register-unsafely-without-email --redirect --non-interactive </dev/null \
        || die "certbot failed; check that $DOMAIN points here and is not proxied, then re-run"
    fi
    curl -fsS --max-time 15 "https://$DOMAIN/healthz" >/dev/null 2>&1 || warn "https://$DOMAIN/healthz did not answer from this server"
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep '^Status: active' >/dev/null; then
    if [ -n "$DOMAIN" ]; then
      warn "ufw is active; if the site is unreachable allow 80 and 443 (ufw allow 80/tcp; ufw allow 443/tcp). Nothing was changed"
    else
      warn "ufw is active; if the API is unreachable allow the port (ufw allow $PORT/tcp). Nothing was changed"
    fi
  fi

  # ------------------------------------------------------------ summary
  cat <<EOF

muse2api is running: ${VERSION:-?} (${COMMIT:0:12}) in $DIR
  API base    $BASE/v1        models: muse-spark, muse-image, muse-video
  admin page  $BASE/admin?key=<your key>
  your key    on this server: grep ^MUSE2API_KEY= $ENVF
  add accounts, on your own computer with Chrome:
    browser extension  $BASE/admin/extension  (unzip, load it in chrome://extensions, log in to muse.ai, click it)
    or Python helper   $BASE/admin/cookie-helper?download=1  then run it with MUSE2API_BASE and MUSE2API_KEY set
  upgrade     run the same install command again
EOF
  if [ -z "$DOMAIN" ]; then echo "  note        plain HTTP: the key and cookies travel unencrypted. Use --domain for https."; fi
  if [ "$WEB_MODE" = panel ]; then
    echo "  https       add a site for $DOMAIN in your panel that reverse proxies to http://127.0.0.1:$PORT"
    echo "              with proxy_read_timeout 600s and proxy_buffering off (see $DIR/deploy/nginx.example.conf)"
  fi
  echo "MUSE2API_INSTALL_OK base=$BASE commit=$COMMIT domain=${DOMAIN:-none}"
}

main "$@"
