# WhatsApp on OpenWA

Counta sends its WhatsApp messages (invoices, receipts, reminders, codes) and lets people talk to Martina through [OpenWA](https://github.com/rmyndharis/OpenWA), an open-source WhatsApp gateway that TaxStreem runs on its own server. A business may also link its own WhatsApp number on the Integrations page, so its customers get messages from it.

OpenWA drives WhatsApp Web with a real phone number. It is not Meta's official WhatsApp Business API, so WhatsApp can restrict or ban a number that it thinks is sending spam. Counta keeps that risk low: it sends only what a person or the books asked for, one message at a time, and never bulk marketing. The official API stays wired in as a fallback (`WHATSAPP_PROVIDER = meta`).

## What TaxStreem needs

- **A dedicated number.** A new Nigerian SIM used only for Counta, registered on WhatsApp Business on a spare Android phone. Name the profile *Counta by TaxStreem* and add the logo. Keep the phone charged and on data: WhatsApp logs linked devices out when the phone stays offline for about two weeks. For the first week, use it lightly (a few chats with people who know the number) before turning Counta's messages on.
- **A server.** Ubuntu 24.04 with 2 GB of memory for TaxStreem's number alone. Each business number linked on the Integrations page adds about 400 MB, so move to 4 GB or more before switching business numbers on. A DigitalOcean droplet in London or Frankfurt is fine.
- **A name.** `wa.taxstreem.com` (or similar) pointing at the server, for HTTPS.

## Set up the server

On DigitalOcean: Create, Droplets, region London, Ubuntu 24.04 (LTS), Basic, Regular, 2 GB of memory (about US$12 a month),
a long root password kept in the password manager, hostname `counta-whatsapp`. At Namecheap add an A record, Host `wa`,
pointing at the Droplet's ipv4 address. Then open the Droplet, Access, Launch Droplet Console, and paste:

```sh
curl -fsSL https://raw.githubusercontent.com/KelechiIbe/counta/main/openwa/setup.sh | bash -s wa.taxstreem.com
```

`openwa/setup.sh` installs Docker and Caddy, runs OpenWA from its published image (`ghcr.io/rmyndharis/openwa`, the version
pinned in the script and tested with Counta), puts HTTPS in front of it, lets in only SSH, HTTP and HTTPS, adds 2 GB of swap
on a small server, and backs up the sessions every night to `/root/openwa-backups` (the last seven). It writes
`/opt/openwa/.env` (root only) with:

```sh
NODE_ENV=production
TZ=Africa/Lagos
DATABASE_TYPE=sqlite
BASE_URL=https://wa.taxstreem.com
AUTO_START_SESSIONS=true      # sessions start again after a restart
RESOLVE_LID_TO_PHONE=true     # Counta needs the sender's number when WhatsApp hides it behind a privacy id
ENABLE_SWAGGER=false
MCP_ENABLED=false
API_KEY_PEPPER=<made once, 64 hex characters>
```

and a `docker-compose.override.yml` that uses the published image and switches off the Docker socket proxy (Counta does
not use OpenWA's built-in database orchestration). OpenWA listens on `127.0.0.1:2785` only; Caddy serves it at
`https://wa.taxstreem.com`. Running the line again updates OpenWA to the script's version and keeps the pepper, the keys
and the sessions. Three commands come with it: `openwa-admin-key`, `openwa-backup` and `openwa-status`.

The admin key is made on first start. Show it with `openwa-admin-key`, sign in at `https://wa.taxstreem.com` with it and keep
it in TaxStreem's password manager. Do not paste it into a chat or email. In the dashboard, **API Keys**, **Create API
Key**: name *Counta*, role **Operator**, all sessions, no IP addresses (Counta's servers have no fixed address), no expiry.
Counta needs nothing more than Operator: making sessions, webhooks and sending. The admin key never goes into Counta.

`API_KEY_PEPPER` must stay the same for the life of the server; changing it locks out every key.

## Connect Counta

In Counta's admin portal, **Keys and services**, **WhatsApp through OpenWA**:

1. **OpenWA server address**: `https://wa.taxstreem.com`.
2. **OpenWA API key**: the Operator key. It is stored in Supabase Vault and never shown again.
3. Press **Connect**. Counta makes the `counta` session, gives OpenWA a new webhook secret and Counta's two addresses (`messaging/openwa` for delivery receipts, `chat/openwa` for messages to Martina), and shows a QR code.
4. On the dedicated phone: WhatsApp, Settings, Linked devices, Link a device. Scan the code. The panel turns to *Connected* with the number.
5. **Which WhatsApp sends**: leave it empty (OpenWA is used once it is connected) or set `openwa`. Set `meta` to go back to the official API.
6. **Businesses may link their own number**: `on` when the server has room for them; empty means off.

**Test** in the same group checks the address and the key. **Check** reads the session's state; **Log out** unlinks the phone.

Every webhook from OpenWA is signed (`X-OpenWA-Signature: sha256=…`, HMAC-SHA256 with the secret Connect made) and Counta drops anything unsigned, stale or already seen. Pressing Connect again makes a new secret.

## What people see

- **Messages from Counta** come from TaxStreem's number. If the session drops, messages wait in the queue instead of failing and go out once it is back.
- **Martina on WhatsApp**: in Counta, Settings, *Martina on WhatsApp and Siri*, a person enters their number and gets a code; they send `LINK 123456` to TaxStreem's number from that phone. Martina then answers as them, within their role, for that business: text or voice notes. She reads back anything that records or changes something and acts only on a yes. She never moves money; payments open in Counta. `UNLINK` stops it, and the owner can remove anyone's link.
- **Alerts**: the same chat carries the person's alerts: tax returns due, invoices overdue, transactions to confirm, and anything waiting for them (a bill to review, a payout to approve, a bank to sign in to again). Between 8:00 and 20:00, at most ten a day, each person only what their role covers. See [messaging.md](messaging.md#alerts-on-whatsapp).
- **Siri on iPhone**: Apple does not offer iMessage to businesses in Nigeria, so iPhone users make a personal key in the same Settings section and build a three-step *Ask Martina* shortcut. Counta keeps only a fingerprint of the key.
- **A business's own number**: on the Integrations page, *WhatsApp Business*, the owner presses *Link my number* and scans the QR code from the business's phone, then chooses *Send from my number*. If that phone drops off, Counta goes back to TaxStreem's number on its own.

## Keeping it healthy

- Update OpenWA by running the setup line again once the script's pinned version has been raised and tested. Sessions survive on the `openwa_openwa-data` volume.
- The nightly backup is in `/root/openwa-backups`; `openwa-backup` makes one at once, worth doing before an update. Losing the volume means scanning the QR codes again. The backups hold the admin key and the linked sessions, so they stay on the server.
- If WhatsApp restricts the number, Counta's admin panel shows *WhatsApp needs attention on the phone*. Open WhatsApp on the phone to see why, and switch `WHATSAPP_PROVIDER` to `meta` while it is sorted out.
