#!/bin/bash
# Sets up TaxStreem's WhatsApp gateway for Counta (OpenWA, github.com/rmyndharis/OpenWA) on a fresh Ubuntu 24.04 server,
# signed in as root. In the Droplet's web console, paste this one line (with the server's name at the end):
#
#   curl -fsSL https://raw.githubusercontent.com/KelechiIbe/counta/main/openwa/setup.sh | bash -s wa.taxstreem.com
#
# It installs Docker and Caddy (the web server that gets and renews the HTTPS certificate), runs OpenWA from its published
# image, a firewall that lets in only SSH, HTTP and HTTPS, a nightly backup of the WhatsApp sessions, and three commands:
#   openwa-admin-key   shows the admin key OpenWA made on its first start (to sign in to its dashboard)
#   openwa-backup      backs up the sessions now (the nightly backup runs the same)
#   openwa-status      shows whether OpenWA is running, and its last log lines
# Running it again updates OpenWA to the version below and keeps the keys, the sessions and the settings.
set -euo pipefail

NAME="${1:-${OPENWA_NAME:-}}"
VERSION="${OPENWA_VERSION:-0.25.0}"
DIR="${OPENWA_DIR:-/opt/openwa}"
REPO="${OPENWA_REPO:-https://github.com/rmyndharis/OpenWA.git}"
IMAGE="${OPENWA_IMAGE:-ghcr.io/rmyndharis/openwa}"
LOG=/var/log/counta-openwa-setup.log
say() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nSTOPPED: %s\n' "$*" >&2; exit 1; }
# Runs a step quietly; its output goes to the log, and the end of the log is shown if it fails.
run() { echo "+ $*" >> "$LOG"; "$@" >> "$LOG" 2>&1 || { tail -n 25 "$LOG" >&2; fail "This step failed: $* (the full log is in $LOG)"; }; }

[ "$(id -u)" = 0 ] || fail "Run this as root. The Droplet console signs you in as root; elsewhere put sudo before bash."
[ -n "$NAME" ] || fail "Put the server's name at the end, for example: ... | bash -s wa.taxstreem.com"
[[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || fail "\"$NAME\" is not a host name like wa.taxstreem.com"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "OPENWA_VERSION must look like 0.25.0"
grep -qi 'ubuntu' /etc/os-release || fail "This script is for Ubuntu (24.04 is the one tested)."
MEM_MB=$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)
[ "$MEM_MB" -ge 1800 ] || fail "This server has ${MEM_MB} MB of memory. OpenWA needs at least 2 GB: resize the Droplet and run this again."

export DEBIAN_FRONTEND=noninteractive
# A new server often updates itself for its first minutes; wait for it rather than fail.
APT=(apt-get -y -q -o DPkg::Lock::Timeout=900)

say "Installing the tools (a few minutes)"
run "${APT[@]}" update
run "${APT[@]}" install curl ca-certificates gnupg git openssl ufw debian-keyring debian-archive-keyring apt-transport-https
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  run bash -c 'curl -fsSL https://get.docker.com | sh'
fi
# get.docker.com starts Docker and makes it start at boot; this covers a server that had Docker without that.
if systemctl list-unit-files docker.service >/dev/null 2>&1; then run systemctl enable --now docker; fi
if ! command -v caddy >/dev/null; then
  run bash -c 'curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg'
  run bash -c 'curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list'
  run "${APT[@]}" update
  run "${APT[@]}" install caddy
fi
echo "$(docker --version | cut -d, -f1), $(docker compose version --short 2>/dev/null | sed 's/^/Compose /'), $(caddy version | cut -d' ' -f1)"

# WhatsApp Web runs a browser for each number; on a 2 GB server a swap file keeps a busy moment from stopping it.
if [ "$(swapon --show --noheadings | wc -l)" = 0 ] && [ "$MEM_MB" -lt 3800 ]; then
  say "Adding 2 GB of swap"
  run fallocate -l 2G /swapfile
  chmod 600 /swapfile
  run mkswap /swapfile
  run swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

say "Getting OpenWA $VERSION"
if [ -d "$DIR/.git" ]; then
  run git -C "$DIR" fetch --depth 1 origin "refs/tags/v$VERSION:refs/tags/v$VERSION"
  run git -C "$DIR" checkout -q -f "v$VERSION"
else
  run git clone -q --depth 1 --branch "v$VERSION" "$REPO" "$DIR"
fi
cd "$DIR"

say "Settings (kept in $DIR/.env, readable by root only)"
touch .env && chmod 600 .env
# Sets KEY=VALUE in .env, replacing the line if it is there.
setenv() { if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else printf '%s=%s\n' "$1" "$2" >> .env; fi; }
# The pepper protects every key OpenWA stores. It is made once and must never change: a new one locks out every key.
if grep -qE '^API_KEY_PEPPER=[0-9a-f]{64}$' .env; then
  echo "Keeping the key pepper already in .env"
else
  grep -q '^API_KEY_PEPPER=' .env && fail "API_KEY_PEPPER in $DIR/.env is not 64 hex characters. Fix it by hand; a new one would lock out every key."
  setenv API_KEY_PEPPER "$(openssl rand -hex 32)"
  echo "A new key pepper is in .env"
fi
setenv NODE_ENV production
setenv TZ Africa/Lagos
setenv DATABASE_TYPE sqlite
setenv BASE_URL "https://$NAME"
# Sessions start again by themselves after a restart or a reboot.
setenv AUTO_START_SESSIONS true
# Counta needs the sender's phone number on each message, also when WhatsApp hides it behind a privacy id.
setenv RESOLVE_LID_TO_PHONE true
setenv ENABLE_SWAGGER false
setenv MCP_ENABLED false

# The published image instead of building on the server, and without the Docker socket proxy (Counta does not use
# OpenWA's built-in database orchestration, so nothing in OpenWA needs to reach Docker).
cat > docker-compose.override.yml <<YML
services:
  docker-proxy:
    profiles: ['disabled']
  openwa-api:
    image: $IMAGE:$VERSION
YML

say "Starting OpenWA (the first time downloads about 600 MB)"
run docker compose pull openwa-api
run docker compose up -d --no-build --remove-orphans
ok=""
for _ in $(seq 1 90); do
  if curl -fsS -m 3 http://127.0.0.1:2785/api/health/ready >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
[ -n "$ok" ] || { docker compose logs --tail 40 openwa-api; fail "OpenWA did not start (its log is above)."; }
echo "OpenWA $VERSION is running on 127.0.0.1:2785"

say "HTTPS for $NAME"
SITE="$NAME {
	encode gzip
	reverse_proxy 127.0.0.1:2785
}"
if [ ! -s /etc/caddy/Caddyfile ] || grep -qE '^:80 *\{' /etc/caddy/Caddyfile; then
  printf '%s\n' "$SITE" > /etc/caddy/Caddyfile
elif ! grep -q "^$NAME {" /etc/caddy/Caddyfile; then
  printf '\n%s\n' "$SITE" >> /etc/caddy/Caddyfile
fi
run caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl enable caddy >/dev/null 2>&1
run systemctl restart caddy

say "Firewall: only SSH, HTTP and HTTPS come in"
run ufw allow 22/tcp
run ufw allow 80/tcp
run ufw allow 443/tcp
run ufw --force enable
# Docker publishes OpenWA on 127.0.0.1 only, so nothing reaches it except through Caddy.

say "Commands and the nightly backup"
cat > /usr/local/bin/openwa-admin-key <<SH
#!/bin/bash
# The admin key OpenWA made on its first start. Sign in to https://$NAME with it, then keep it in a password manager.
docker exec openwa-api cat /app/data/.api-key 2>/dev/null && echo || echo "No first-start key is saved any more. Sign in with a key you kept, or see the guide."
SH
cat > /usr/local/bin/openwa-backup <<SH
#!/bin/bash
# Copies the WhatsApp sessions and OpenWA's own records to /root/openwa-backups (readable by root only), keeping the last seven.
set -e
mkdir -p /root/openwa-backups && chmod 700 /root/openwa-backups
f=/root/openwa-backups/openwa-data-\$(date +%Y%m%d-%H%M).tgz
docker run --rm --user 0:0 --entrypoint tar -v openwa_openwa-data:/d:ro -v /root/openwa-backups:/b $IMAGE:$VERSION czf "/b/\$(basename "\$f")" -C /d .
ls -1t /root/openwa-backups/openwa-data-*.tgz | tail -n +8 | xargs -r rm -f
echo "Saved \$f"
SH
cat > /usr/local/bin/openwa-status <<SH
#!/bin/bash
cd $DIR || exit 1
docker compose ps openwa-api
curl -fsS -m 3 http://127.0.0.1:2785/api/health/ready && echo || echo "OpenWA is not answering on 127.0.0.1:2785."
docker compose logs --tail 15 openwa-api
SH
chmod 700 /usr/local/bin/openwa-admin-key /usr/local/bin/openwa-backup /usr/local/bin/openwa-status
printf '#!/bin/sh\n/usr/local/bin/openwa-backup > /var/log/openwa-backup.log 2>&1\n' > /etc/cron.daily/openwa-backup
chmod 755 /etc/cron.daily/openwa-backup

IP=$(curl -fsS -m 3 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null || true)
[ -n "$IP" ] || IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}' | head -1)
DNS=$(getent ahostsv4 "$NAME" 2>/dev/null | awk 'NR == 1 {print $1}' || true)

cat <<MSG

======================================================================
 Done. OpenWA $VERSION is running.

 1. $NAME must point at this server (an A record at Namecheap):
      This server:  $IP
      $NAME points at: ${DNS:-nothing yet}
    Caddy gets the HTTPS certificate by itself once it does.

 2. To sign in to OpenWA's dashboard at https://$NAME, show the
    admin key with:
      openwa-admin-key
    Keep it in TaxStreem's password manager. Never paste it into a
    chat or an email.

 3. Follow the guide from "Make Counta's key": an Operator key named
    Counta, then Keys and services, WhatsApp through OpenWA, in
    Counta's admin portal.
======================================================================
MSG
