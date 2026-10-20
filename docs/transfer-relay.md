# The transfer relay

## Why Counta needs it

Flutterwave accepts transfer requests (payouts to suppliers and staff, bulk payments, sweeps of card and USSD payments into
a business's wallet, moves between a business's wallet and its tax wallet, and tax payments) only from IP addresses that
TaxStreem has whitelisted on its Flutterwave account. Counta's server functions run on Supabase, whose servers change
address, so Flutterwave refuses those requests.

This was why money paid by transfer for a sale stayed in TaxStreem's Flutterwave balance: each sale got a one-off account on
TaxStreem's own Flutterwave account, and the sweep that should have moved the money to the business's wallet was refused.
Transfers for sales now go straight to the business's own wallet number, so they no longer depend on a sweep. Card, USSD and
QR payments, payouts and the tax wallet still need transfers, and the relay is how Counta sends them.

The relay is a small program (`relay/server.mjs` in the repository, no packages needed) on a server TaxStreem rents, with
one fixed IP address. Counta signs each transfer request with a shared secret; the relay checks the signature, the time
(within five minutes) and that it has not seen the request before, then passes it to Flutterwave from its fixed address. It
forwards only Flutterwave's transfer paths, keeps nothing on disk and logs only the method, path and status of each request.

Until the relay is set up, Counta keeps working: collections are recorded as before, and transfers wait (a payout stays
approved, a sweep pending, a tax wallet move queued) and go once the relay works. Nothing needs to be redone.

## Setting it up (about an hour)

### 1. Rent a small server with a fixed IP address

Any provider works. The smallest plan is enough (1 CPU, 1 GB of memory, about US$5 a month), with Ubuntu 24.04.

- DigitalOcean: create a Droplet, then Networking, Reserved IPs, assign one to the Droplet.
- AWS Lightsail: create an instance, then Networking, attach a static IP.
- Hetzner: create a server; its primary IPv4 address is fixed.

Write down the fixed IP address. Allow incoming ports 22 (SSH, ideally only from your office), 80 and 443 in the provider's
firewall.

### 2. Give it a name

In TaxStreem's DNS, add an `A` record such as `relay.taxstreem.com` pointing to the fixed IP address.

### 3. Install the relay

Sign in to the server (`ssh root@<the IP address>`) and run, one block at a time:

```bash
# Node.js 22 and Caddy (the web server that handles HTTPS)
apt-get update && apt-get install -y curl debian-keyring debian-archive-keyring apt-transport-https gnupg
curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
apt-get update && apt-get install -y caddy

# A user of its own, and the program
useradd --system --no-create-home --shell /usr/sbin/nologin counta-relay
mkdir -p /opt/counta-relay
curl -fsSL https://raw.githubusercontent.com/KelechiIbe/counta/main/relay/server.mjs -o /opt/counta-relay/server.mjs
curl -fsSL https://raw.githubusercontent.com/KelechiIbe/counta/main/relay/counta-relay.service -o /etc/systemd/system/counta-relay.service
curl -fsSL https://raw.githubusercontent.com/KelechiIbe/counta/main/relay/Caddyfile -o /etc/caddy/Caddyfile
```

(If the repository is private, copy the three files from `relay/` with `scp` instead.)

### 4. The secret

```bash
openssl rand -hex 32
```

Keep the 64 characters it prints for the next two steps; do not email them or paste them into a chat. Then:

```bash
printf 'RELAY_SECRET=%s\n' '<the 64 characters>' > /etc/counta-relay.env
chmod 600 /etc/counta-relay.env
```

### 5. Start it

Edit `/etc/caddy/Caddyfile` and change `relay.taxstreem.com` to the name from step 2. Then:

```bash
systemctl daemon-reload
systemctl enable --now counta-relay
systemctl restart caddy
curl https://relay.taxstreem.com/health
```

The last line should print `{"ok":true,"version":"1"}`. Caddy gets and renews the HTTPS certificate by itself.

### 6. Whitelist it on Flutterwave

In the Flutterwave dashboard: Settings, Whitelisted IP addresses, add the fixed IP address from step 1. Flutterwave may ask
for a code sent to the account owner.

While there, check Settings, Webhooks: switch on "Enable payout subaccounts wallet funding hook", so a transfer to a
business's own number reaches Counta at once.

### 7. Tell Counta

In Counta's admin portal, Keys and services, Flutterwave:

- `FLW_RELAY_URL`: `https://relay.taxstreem.com` (the name from step 2)
- `FLW_RELAY_SECRET`: the 64 characters from step 4

Then press Test. It should say "Transfers go through the relay (version 1)". From then on payouts, bulk payments, sweeps,
tax wallet moves and tax payments go out, including any that were waiting.

## Looking after it

- Logs: `journalctl -u counta-relay -n 100` shows each request's time, method, path and Flutterwave's status code.
- Updating: download `server.mjs` again (step 3) and run `systemctl restart counta-relay`.
- Changing the secret: make a new one (step 4), restart the relay, then save the new value in the admin portal. Transfers
  sent in the minute between the two are refused by the relay, nothing leaves anyone's wallet, and they go on the next try.
- If the server's address ever changes, whitelist the new one on Flutterwave before removing the old one.
- `RELAY_FLW_KEY` in `/etc/counta-relay.env` keeps Flutterwave's secret key on the relay instead of letting Counta send it
  with each request. If you set it, rotate it there too when the key changes.

## How Counta uses it

The payments function sends transfer requests (`/transfers`, `/bulk-transfers`) to `FLW_RELAY_URL/forward/<path>` with:

```
X-Relay-Timestamp: <unix seconds>
X-Relay-Signature: <hex HMAC-SHA256 of "<timestamp>\n<METHOD>\n<path with query>\n<body>" with the relay secret>
X-Flw-Authorization: Bearer <Flutterwave secret key>
```

The relay answers with Flutterwave's own status and body. Its own refusals start with "Relay:" (401 for a bad, stale or
repeated signature, 403 for a path it does not forward, 504 when Flutterwave did not answer). A 504 is treated as "no
answer": the transfer may have gone, so Counta checks with Flutterwave before sending it again.

The test suite runs the real relay between Counta and a stand-in for Flutterwave that, like the live account, refuses
transfers from any address but the relay's.
