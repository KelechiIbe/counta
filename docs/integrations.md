# Integrations

A business connects the tools it already sells and talks through at `/integrations` (Integrations in the sidebar). Payments and paid orders from those tools become paid sales in the books without anyone typing them. Slack hears Counta's alerts. The business's own WhatsApp number can send its invoices and receipts. Accounting tools are left out on purpose, because a business that moves to Counta keeps its books here.

Only the owner, or someone whose role manages settings, connects or changes a tool. Everyone else in the business sees what is connected. The sample business cannot connect anything.

## The tools

| Tool | How sales arrive | What the business pastes in |
| --- | --- | --- |
| Paystack | Webhook at once, and a look every five minutes | Secret key (`sk_live_…`); then Counta's webhook address into Paystack |
| Flutterwave (own account) | Webhook at once, checked with Flutterwave, and a look every five minutes | Secret key (`FLWSECK-…-X`); then Counta's webhook address and secret hash into Flutterwave |
| WooCommerce | A look every five minutes | Shop address, consumer key and secret with Read access |
| Shopify | A look every five minutes | `*.myshopify.com` address and a custom app's Admin API token (`shpat_…`) with `read_orders` |
| Selar | Webhook | Counta's webhook address into Selar, or into Zapier when the Selar plan has no webhooks |
| Zapier or Make | Webhook | Counta's webhook address in a "POST JSON" step |
| Bumpa | CSV upload | The orders file exported from Bumpa |
| Slack | Counta posts | An incoming webhook URL, and which alerts to post |
| WhatsApp Business | Messages go out from it | A QR scan from the business's phone (see [messaging.md](messaging.md)) |
| Bank accounts | Mono bank feeds | Set up in Banking (see [banking-and-feeds.md](banking-and-feeds.md)) |

Bumpa and Selar publish no API a business can hand a key to, so Bumpa comes in by its CSV export and Selar by its webhook (or through Zapier).

## How a sale is booked

Each payment or paid order becomes a receipt, recorded by the business's owner:

- **Customer**: an existing one matched by email or phone, otherwise a new one from the payment's details, otherwise walk-in.
- **Lines**: products matched to the business's items by SKU, then by name. Anything unmatched becomes a description line with the tool's wording.
- **VAT**: the tool's price includes VAT. A VAT-registered business whose prices exclude VAT records the price before VAT, so the total equals what was paid.
- **Money**: the payment goes into a balance account for that tool (for example *Paystack balance*, a `1014-xx` ledger), with the tool's fee booked as a payment fee. When the tool pays out to the bank, the bank line is matched in Banking as a transfer from that balance account.
- **Branch**: the main branch, or the branch chosen when connecting.

Only naira payments are recorded. A payment in another currency is listed as left out, with a note to record it by hand.

The same payment is never booked twice. Counta checks the tool's own id (prefixed `ps:`, `flw:`, `woo:`, `shop:`, `selar:`, `zapier:`, `bumpa:`) against everything the business has recorded through connected tools, including what an earlier connection of the same tool recorded before it was disconnected. Importing the same Bumpa file twice records nothing new.

Every payment the tool sent shows in the drawer's *Latest* list as recorded, left out or failed, with the reason.

## Webhooks

```
POST /functions/v1/integrations/hook/paystack/<token>     x-paystack-signature: HMAC-SHA512 of the body with the business's key
POST /functions/v1/integrations/hook/flutterwave/<token>  verif-hash: the secret hash Counta made; the payment is then checked with Flutterwave
POST /functions/v1/integrations/hook/selar/<token>
POST /functions/v1/integrations/hook/zapier/<token>       the 48-character token in the address is the secret
```

Counta keeps only a SHA-256 hash of each token, so the address is shown once, when it is made. *New webhook address* makes another and the old one stops working at once. Paystack posts are refused unless signed with the business's own key. Flutterwave posts are refused without the secret hash, and the amount recorded is the one Flutterwave confirms, never the amount in the post.

Zapier, Make and Selar post JSON with an id and an amount. Counta reads the first of these it finds, at the top level or under `data`:

- id: `id`, `transaction_id`, `reference`, `order_id`, `sale_id`, `tx_ref`, `payment_reference`
- amount in naira: `amount`, `total`, `amount_paid`, `price`, `total_amount`, `value` (add `"amount_unit": "kobo"` for kobo)
- optional: `fee`, `currency`, `paid_at`, `product_name`, `quantity`, `sku`, `customer_name`, `customer_email`, `customer_phone`

## The five-minute look

The `counta-integrations` cron job calls the function with `{ "action": "poll" }` and the `x-counta-hook` header (`PUSH_HOOK_SECRET`). For each active Paystack, Flutterwave, WooCommerce and Shopify connection it reads what was paid since the last look, with a minute of overlap, and records anything new. Connecting reads the last two days at once. For Slack it posts the business's new notifications of the kinds chosen (payments in, tax deadlines and alerts, books, everything else), once each, with a link back into Counta.

A tool that refuses its key (or a Slack address that no longer exists) is marked *Needs attention* at once, and the owner is told once. A tool that is down or slow is only noted at first; when it has kept failing for half an hour it is marked too. The next successful look clears it. Paused connections are skipped and record nothing.

## Keys and safety

- Keys and Slack URLs live in Supabase Vault. The `integrations` table holds only the Vault id and the last four characters. The app never receives a key back.
- Keys are used to read payments and orders only. Counta never moves money with them.
- Disconnecting deletes the key and the webhook secret from Vault. Sales already recorded stay.
- Shop addresses must be public `https` addresses: Counta refuses private and local addresses so a key cannot be sent anywhere unexpected.
- `integration_events` and `integrations` are closed to the API; the app reads them through `org_integrations` and `integration_events_list`, which check membership.

## Settings for TaxStreem

Nothing to set beyond what Counta already uses: `PUSH_HOOK_SECRET` (in Vault, for the cron job) and the usual Supabase keys. These are for local tests only and must not be set in production: `PAYSTACK_BASE_URL`, `SHOPIFY_BASE_URL`, `INTEGRATIONS_TEST_HOSTS`.

## Functions and tables

- Edge function `integrations`: actions `connect`, `bumpa_import`, `sync`, `test`, `new_address`, the webhook routes and the poll.
- `integrations`: one live row per business and tool (`paystack`, `flutterwave`, `selar`, `woocommerce`, `shopify`, `zapier`, `bumpa`, `slack`).
- `integration_events`: each payment a tool sent, once per connection.
- RPCs: `org_integrations`, `integration_events_list`, `integration_settings` (branch, Slack kinds, pause), `integration_disconnect`. Service only: `svc_integration_save`, `svc_integration`, `svc_integration_by_token`, `svc_integrations_due`, `svc_integration_note`, `svc_integration_sale`, `svc_slack_outbox`.
