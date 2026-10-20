#!/bin/bash
# Sets up the Counta transfer relay on a fresh Ubuntu 24.04 server (a DigitalOcean Droplet or any other), signed in as root.
# In the Droplet's web console, paste this one line (with the relay's name at the end):
#
#   curl -fsSL https://raw.githubusercontent.com/KelechiIbe/counta/main/relay/setup.sh | bash -s relay.taxstreem.com
#
# It installs Node.js 22 and Caddy, the relay as a locked-down service, a firewall that lets in only SSH, HTTP and HTTPS,
# and a new random shared secret (kept in /etc/counta-relay.env, readable by root only). Running it again updates the relay
# and keeps the secret. At the end it prints the address to whitelist on Flutterwave and what to save in Counta.
set -euo pipefail

NAME="${1:-${RELAY_NAME:-}}"
REF="${RELAY_REF:-main}"
REPO="${RELAY_REPO:-https://raw.githubusercontent.com/KelechiIbe/counta/$REF/relay}"
LOG=/var/log/counta-relay-setup.log
say() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nSTOPPED: %s\n' "$*" >&2; exit 1; }
# Runs a step quietly; its output goes to the log, and the end of the log is shown if it fails.
run() { echo "+ $*" >> "$LOG"; "$@" >> "$LOG" 2>&1 || { tail -n 25 "$LOG" >&2; fail "This step failed: $* (the full log is in $LOG)"; }; }

[ "$(id -u)" = 0 ] || fail "Run this as root. The Droplet console signs you in as root; elsewhere put sudo before bash."
[ -n "$NAME" ] || fail "Put the relay's name at the end, for example: ... | bash -s relay.taxstreem.com"
[[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || fail "\"$NAME\" is not a host name like relay.taxstreem.com"
grep -qi 'ubuntu' /etc/os-release || fail "This script is for Ubuntu (24.04 is the one tested)."

export DEBIAN_FRONTEND=noninteractive
# A new server often updates itself for its first minutes; wait for it rather than fail.
APT=(apt-get -y -q -o DPkg::Lock::Timeout=900)

say "Installing Node.js 22 and Caddy (a few minutes)"
run "${APT[@]}" update
run "${APT[@]}" install curl ca-certificates gnupg debian-keyring debian-archive-keyring apt-transport-https ufw openssl iproute2
if ! command -v node >/dev/null || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 20 ]; then
  run bash -c 'curl -fsSL https://deb.nodesource.com/setup_22.x | bash -'
  run "${APT[@]}" install nodejs
fi
if ! command -v caddy >/dev/null; then
  run bash -c 'curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg'
  run bash -c 'curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list'
  run "${APT[@]}" update
  run "${APT[@]}" install caddy
fi
echo "Node.js $(node -v), $(caddy version | cut -d' ' -f1)"

say "Installing the relay from $REPO"
id counta-relay >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin counta-relay
mkdir -p /opt/counta-relay
tmp=$(mktemp -d)
for f in server.mjs counta-relay.service Caddyfile; do curl -fsSL "$REPO/$f" -o "$tmp/$f" || fail "Could not download $f from $REPO"; done
node --check "$tmp/server.mjs" || fail "The downloaded server.mjs is not valid JavaScript"
install -m 644 "$tmp/server.mjs" /opt/counta-relay/server.mjs
install -m 644 "$tmp/counta-relay.service" /etc/systemd/system/counta-relay.service
sed "s/^relay\.taxstreem\.com {/$NAME {/" "$tmp/Caddyfile" > /etc/caddy/Caddyfile
grep -q "^$NAME {" /etc/caddy/Caddyfile || fail "Could not put $NAME into the Caddy configuration"
mkdir -p /var/log/caddy && chown caddy:caddy /var/log/caddy 2>/dev/null || true
rm -rf "$tmp"

say "The shared secret"
if grep -qE '^RELAY_SECRET=[0-9a-f]{64}$' /etc/counta-relay.env 2>/dev/null; then
  echo "Keeping the secret already in /etc/counta-relay.env"
else
  (umask 077; printf 'RELAY_SECRET=%s\n' "$(openssl rand -hex 32)" > /etc/counta-relay.env)
  echo "A new secret is in /etc/counta-relay.env"
fi
chmod 600 /etc/counta-relay.env

say "Firewall: only SSH, HTTP and HTTPS come in"
run ufw allow 22/tcp
run ufw allow 80/tcp
run ufw allow 443/tcp
run ufw --force enable
ufw status | sed -n '1,10p'

say "Starting the relay and Caddy"
systemctl daemon-reload
systemctl enable counta-relay >/dev/null 2>&1
systemctl restart counta-relay
systemctl enable caddy >/dev/null 2>&1
systemctl restart caddy
ok=""
for _ in $(seq 1 20); do
  if curl -fsS -m 2 http://127.0.0.1:8787/health >/dev/null 2>&1; then ok=1; break; fi
  sleep 1
done
[ -n "$ok" ] || { journalctl -u counta-relay -n 20 --no-pager; fail "The relay did not start (its log is above)."; }
echo "Relay: $(curl -fsS -m 2 http://127.0.0.1:8787/health)"

# The address requests leave from: DigitalOcean's metadata first, then anything that answers on the machine itself.
IP=$(curl -fsS -m 3 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null || true)
[ -n "$IP" ] || IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}' | head -1)
DNS=$(getent ahostsv4 "$NAME" 2>/dev/null | awk 'NR == 1 {print $1}' || true)

cat <<MSG

======================================================================
 Done. Three things left, in this order:

 1. Whitelist this address on Flutterwave (Settings, Whitelisted IP addresses):
      $IP

 2. $NAME must point at the same address (an A record at Namecheap).
      It points at: ${DNS:-nothing yet}
    Caddy gets the HTTPS certificate by itself once it does; check with:
      curl https://$NAME/health
    which should print {"ok":true,"version":"1"}.

 3. In Counta's admin portal, Keys and services, Flutterwave, save:
      FLW_RELAY_URL     https://$NAME
      FLW_RELAY_SECRET  the 64 characters after RELAY_SECRET= in:
                        cat /etc/counta-relay.env
    then press Test. Never paste the secret into a chat or an email.
======================================================================
MSG
