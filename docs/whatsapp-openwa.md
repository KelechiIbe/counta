# WhatsApp on OpenWA

Counta sends its WhatsApp messages (invoices, receipts, reminders, codes) and lets people talk to Martina through [OpenWA](https://github.com/rmyndharis/OpenWA), an open-source WhatsApp gateway that TaxStreem runs on its own server. A business may also link its own WhatsApp number on the Integrations page, so its customers get messages from it.

OpenWA drives WhatsApp Web with a real phone number. It is not Meta's official WhatsApp Business API, so WhatsApp can restrict or ban a number that it thinks is sending spam. Counta keeps that risk low: it sends only what a person or the books asked for, one message at a time, and never bulk marketing. The official API stays wired in as a fallback (`WHATSAPP_PROVIDER = meta`).

## What TaxStreem needs

- **A dedicated number.** A new Nigerian SIM used only for Counta, registered on WhatsApp Business on a spare Android phone. Name the profile *Counta by TaxStreem* and add the logo. Keep the phone charged and on data: WhatsApp logs linked devices out when the phone stays offline for about two weeks. For the first week, use it lightly (a few chats with people who know the number) before turning Counta's messages on.
- **A server.** Ubuntu 24.04 with 2 GB of memory for TaxStreem's number alone. Each business number linked on the Integrations page adds about 400 MB, so move to 4 GB or more before switching business numbers on. A DigitalOcean droplet in London or Frankfurt is fine.
- **A name.** `wa.taxstreem.com` (or similar) pointing at the server, for HTTPS.

## Set up the server

On the server, as root:

```sh
curl -fsSL https://get.docker.com | sh
apt-get update && apt-get install -y caddy
git clone https://github.com/rmyndharis/OpenWA.git /opt/openwa && cd /opt/openwa
git checkout "$(git describe --tags "$(git rev-list --tags --max-count=1)")"   # the latest release
cat > .env <<EOF
NODE_ENV=production
TZ=Africa/Lagos
DATABASE_TYPE=sqlite
AUTO_START_SESSIONS=true
BASE_URL=https://wa.taxstreem.com
API_KEY_PEPPER=$(openssl rand -hex 32)
ENABLE_SWAGGER=false
MCP_ENABLED=false
EOF
chmod 600 .env
# Counta does not use OpenWA's built-in database orchestration, so the Docker socket proxy is switched off.
cat > docker-compose.override.yml <<'EOF'
services:
  docker-proxy:
    profiles: ['disabled']
EOF
docker compose up -d --build
```

OpenWA listens on `127.0.0.1:2785` only. Caddy puts HTTPS in front of it:

```sh
cat > /etc/caddy/Caddyfile <<'EOF'
wa.taxstreem.com {
  reverse_proxy 127.0.0.1:2785
}
EOF
systemctl reload caddy
ufw allow OpenSSH && ufw allow 80 && ufw allow 443 && ufw --force enable
```

The admin key is made on first boot. Read it once, on the server, and keep it in TaxStreem's password manager:

```sh
docker compose logs openwa-api | grep -oE "owa_k1_[a-f0-9]{64}" | head -1
```

Do not paste it into a chat or email. Open `https://wa.taxstreem.com`, sign in with it, go to **API keys** and create a key with the **Operator** role named *Counta*. Counta needs nothing more than Operator: making sessions, webhooks and sending. The admin key never goes into Counta.

`API_KEY_PEPPER` must stay the same for the life of the server; changing it locks out every key.

## Connect Counta

In Counta's admin portal, **Keys**, **WhatsApp on OpenWA**:

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
- **Siri on iPhone**: Apple does not offer iMessage to businesses in Nigeria, so iPhone users make a personal key in the same Settings section and build a three-step *Ask Martina* shortcut. Counta keeps only a fingerprint of the key.
- **A business's own number**: on the Integrations page, *WhatsApp Business*, the owner presses *Link my number* and scans the QR code from the business's phone, then chooses *Send from my number*. If that phone drops off, Counta goes back to TaxStreem's number on its own.

## Keeping it healthy

- Update OpenWA with `cd /opt/openwa && git fetch --tags && git checkout <new tag> && docker compose up -d --build`. Sessions survive on the `openwa-data` volume.
- Back up the volume (`docker run --rm -v openwa_openwa-data:/d -v /root:/b alpine tar czf /b/openwa-data.tgz -C /d .`) before upgrades. Losing it means scanning the QR codes again.
- If WhatsApp restricts the number, Counta's admin panel shows *WhatsApp needs attention on the phone*. Open WhatsApp on the phone to see why, and switch `WHATSAPP_PROVIDER` to `meta` while it is sorted out.
