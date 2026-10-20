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

## Setting it up (about half an hour)

### 1. Rent a small server

On DigitalOcean: Create, Droplets. Region London, image Ubuntu 24.04 (LTS), the Basic plan with a Regular CPU at about
US$6 a month (1 GB of memory). Authentication: a long root password, kept in a password manager. Name it `counta-relay`.

The Droplet's page shows its **ipv4** address. It stays the same for as long as the Droplet exists, and it is the address
Flutterwave sees: a Droplet sends its traffic from its own address. A DigitalOcean Reserved IP is not needed (outgoing traffic
uses one only after extra routing changes on the server). If you ever replace the Droplet, whitelist the new one's address on
Flutterwave before deleting the old one.

Other providers work the same way (AWS Lightsail with a static IP, Hetzner): the address the server's outgoing traffic comes
from is the one to whitelist. The relay always connects to Flutterwave over IPv4 (`RELAY_IP_FAMILY`, default 4), so a server
that also has IPv6 still sends from its IPv4 address.

### 2. Give it a name

taxstreem.com's DNS is at Namecheap: Domain List, Manage beside taxstreem.com, Advanced DNS, Host Records, Add New Record,
**A Record**, Host `relay`, Value the server's address, TTL Automatic, then the green tick. `relay.taxstreem.com` then points
at the server.

### 3. Run the setup

On DigitalOcean open the Droplet, then Access, Launch Droplet Console (it signs you in as root). Paste this one line:

```bash
curl -fsSL https://raw.githubusercontent.com/KelechiIbe/counta/main/relay/setup.sh | bash -s relay.taxstreem.com
```

It takes a few minutes. It installs Node.js 22 and Caddy (the web server that gets and renews the HTTPS certificate), the
relay as a locked-down service, a firewall that lets in only SSH, HTTP and HTTPS, and a new random secret in
`/etc/counta-relay.env` (readable by root only). It ends by printing the address to whitelist, whether the name points at
the server yet, and what to save in Counta. Running it again updates the relay and keeps the secret.

To see the secret when you save it in Counta (step 6):

```bash
cat /etc/counta-relay.env
```

The 64 characters after `RELAY_SECRET=` are the secret. Do not email them or paste them into a chat.

Once the name points at the server (a few minutes after step 2), this should print `{"ok":true,"version":"1"}`:

```bash
curl https://relay.taxstreem.com/health
```

### 4. By hand, instead of the setup line

Everything `relay/setup.sh` does can be done by hand on any Ubuntu server: install Node.js 20 or later and Caddy, copy
`relay/server.mjs` to `/opt/counta-relay/`, `relay/counta-relay.service` to `/etc/systemd/system/` and `relay/Caddyfile` to
`/etc/caddy/Caddyfile` (with the relay's name in place of `relay.taxstreem.com`), add a `counta-relay` system user, put
`RELAY_SECRET=<output of openssl rand -hex 32>` in `/etc/counta-relay.env` (chmod 600), then
`systemctl daemon-reload && systemctl enable --now counta-relay && systemctl restart caddy`.

### 5. Whitelist it on Flutterwave

In the Flutterwave dashboard: Settings, Whitelisted IP addresses, add the server's address from step 1 (the setup prints it too). Flutterwave may ask
for a code sent to the account owner.

While there, check Settings, Webhooks: switch on "Enable payout subaccounts wallet funding hook", so a transfer to a
business's own number reaches Counta at once.

### 6. Tell Counta

In Counta's admin portal, Keys and services, Flutterwave:

- `FLW_RELAY_URL`: `https://relay.taxstreem.com` (the name from step 2)
- `FLW_RELAY_SECRET`: the 64 characters after `RELAY_SECRET=` (step 3)

Then press Test. It should say "Transfers go through the relay (version 1)". From then on payouts, bulk payments, sweeps,
tax wallet moves and tax payments go out, including any that were waiting.

## Looking after it

- Logs: `journalctl -u counta-relay -n 100` shows each request's time, method, path and Flutterwave's status code.
- Updating: run the setup line from step 3 again. It keeps the secret.
- Changing the secret: `rm /etc/counta-relay.env`, run the setup line again, then save the new value in the admin portal. Transfers
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
