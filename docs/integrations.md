# Integrations

A business connects the tools it already sells, spends and talks through at `/integrations` (Integrations in the sidebar). Payments and paid orders from those tools become paid sales in the books without anyone typing them. Bujeti's spending, balances, vendors and invoices come into the books too. Slack hears Counta's alerts. The business's own WhatsApp number can send its invoices and receipts. Accounting tools are left out on purpose, because a business that moves to Counta keeps its books here.

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
| Bumpa | A look every five minutes with the store's secret key; or a CSV upload | Secret API key from the Bumpa dashboard (and a location ID for a store with several), or the orders file |
| Bujeti | A look every fifteen minutes | An API key with read scopes, from Bujeti's Settings, Developers |
| Slack | Counta posts | An incoming webhook URL, and which alerts to post |
| WhatsApp Business | Messages go out from it | A QR scan from the business's phone (see [messaging.md](messaging.md)) |
| Bank accounts | Mono bank feeds | Set up in Banking (see [banking-and-feeds.md](banking-and-feeds.md)) |

Selar publishes no API a business can hand a key to, so it comes in by its webhook (or through Zapier).

## Bumpa

Bumpa's Commerce API ([docs.bumpa.io](https://docs.bumpa.io), in public beta) lets a store make a secret API key in its
Bumpa dashboard. With one, Counta reads the store's paid orders every five minutes:

```
GET https://api.getbumpa.com/api/commerce/v1/orders?payment_status=paid&from_date=YYYY-MM-DD&to_date=YYYY-MM-DD
    &orderByField=created_at&orderBy=asc&limit=50&page=N[&location_id=...]
X-Api-Key: <the store's secret key>
```

- Each look goes back to the day before the last one, up to five pages of 50 orders, and leaves out orders seen already.
- An order counts when its payment status is paid and it is not cancelled, refunded or voided. Its products, quantities and
  prices become the sale's lines, and the delivery fee a line of its own.
- The order number is the one the store sees, `#` taken off. A CSV export of the same orders uses the same numbers, so an
  order brought in both ways is recorded once. The CSV upload stays on the drawer for older orders.
- A location ID is only for a store with more than one location in Bumpa; empty means the main location.
- Bumpa publishes no sample responses and no way to sign webhooks yet, so Counta reads orders on a schedule rather than
  waiting for Bumpa to post them. The fields read are in `bumpaSale` in `supabase/functions/integrations/providers.ts`,
  with fallbacks for the names Bumpa uses in its exports.
- `BUMPA_BASE_URL` points the function at a stand-in for tests.

## Bujeti

Bujeti is a spend tool: the business pays suppliers, staff and subscriptions from a Bujeti balance, by transfer or card. Its
public API ([developers.bujeti.com](https://developers.bujeti.com), OpenAPI 3.1, version 1.2.1) gives a business an API key on
Bujeti's paid plans, under Settings, Developers, with scopes. Counta needs `transactions.read`, and uses `balances.read`,
`categories.read`, `vendors.read`, `invoices.read` and `assets.read` when the key has them. Counta never writes to Bujeti.

```
GET https://api.bujeti.com/v1/transactions?from=<ISO>&to=<ISO>&page=N&perPage=500     Authorization: Bearer <key>
GET .../transactions/{code}   .../transactions/{code}/assets   .../balances   .../categories   .../vendors   .../invoices
```

Every answer is `{message, status, error, data}`; lists carry `data.<things>` and `data.meta {page, perPage, total, hasMore,
nextPage}`. Amounts are in kobo. Bujeti has no webhooks, so Counta looks every fifteen minutes.

What Counta does with it:

- **Payments.** Every settled naira payment from 1 January 2026, or from the day the books start if later, becomes a line in
  a *Bujeti balance* account in Banking (a `1014-xx` wallet ledger), dated in Lagos time, with the recipient as the
  counterparty and the payment's code as reference. Bujeti's fee is a second line, booked to Bank charges (the `payment_fees`
  role, 6701). Statuses are read by their usual words: success, completed, approved, paid or processed is settled; pending,
  processing or queued waits; failed, declined or cancelled is left out; reversed or refunded puts the money back as a line
  of its own, posted back to the account the payment went to. A status Counta does not know waits, with a note in the list.
  A payment still pending a day later is asked about again, one by one, for 120 days.
- **Categories.** Counta keeps Bujeti's categories and suggests a Counta account for each from its name (software to 6303,
  fuel to 6207, flights to 6602, bank charges to 6701, anything unclear to 6907 Sundry), always an account the business can
  post to. Someone who keeps the books confirms the account once in the Bujeti drawer. From then on a payment in that
  category posts by itself, against the supplier, unless it fits a bill Counta already has from that supplier: then the
  bill is put to a person in the books inbox, as for a bank line, so the cost is not booked twice. Payments in a category not
  yet confirmed wait (the bookkeeper is told, at most once a day) and go into the books the moment it is confirmed. Payments
  with no category go through the same matching as any bank line, and what nothing explains goes to the bookkeeper agent.
  Choosing *Let payments wait* for a category stops it posting by itself again; what it already posted stays.
- **Receipts.** Files attached to a payment in Bujeti are fetched from Bujeti's short-lived signed address (public `https`
  only, PDFs and pictures up to 10 MB) and kept in Documents under Bank, *Bujeti receipts*, in the payment's month. A file
  that cannot be fetched is tried three times.
- **Balance.** The naira held in Bujeti (not a linked bank account, which Bujeti also lists) is the account's *bank said*
  figure in Banking, so the books can be reconciled to it. Dollar balances and linked accounts show in the drawer.
- **Money in and out of Bujeti.** A line in another of the business's accounts that names Bujeti (for example
  `NIP TRF TO BUJETI TECHNOLOGIES`) is matched as a transfer into the Bujeti balance, or out of it when money comes back.
- **Vendors.** Bujeti's vendors become Counta suppliers, matched by name (then email) first so nobody is added twice; an
  inactive vendor is linked if Counta has it but never added.
- **Invoices.** Invoices sent from Bujeti (not drafts, not cancelled ones) become Counta invoices with Bujeti's number as the
  reference, the customer matched by email or name or added, and Bujeti's VAT kept as it was. An invoice with no VAT from
  a VAT-registered business is taken as including VAT, as for the other tools, and the list says so. When Bujeti marks one
  paid, the payment goes into the Bujeti balance. An invoice cancelled in Bujeti after Counta recorded it is left for a person
  to void (they are told once). A Bujeti payment that is the money for such an invoice is not recorded twice.
- **Dollars.** Payments and invoices in other currencies are listed for recording by hand.

The look: balances every time; categories and vendors once a day; payments of the last ten days every time (45 days once a
day, to catch late reversals); older months from the start, a month at a time, until the history is in; up to 20 pending
payments and 10 payments' receipts; invoices once an hour. Connecting does the balances, the lists and the last 45 days at
once, and the rest follows within a few minutes. `BUJETI_BASE_URL` points the function at a stand-in for tests.

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

The `counta-integrations` cron job calls the function with `{ "action": "poll" }` and the `x-counta-hook` header (`PUSH_HOOK_SECRET`). Bujeti is looked at every fifteen minutes (above). For each active Paystack, Flutterwave, WooCommerce and Shopify connection it reads what was paid since the last look, with a minute of overlap, and records anything new. Connecting reads the last two days at once. For Slack it posts the business's new notifications of the kinds chosen (payments in, tax deadlines and alerts, books, everything else), once each, with a link back into Counta.

A tool that refuses its key (or a Slack address that no longer exists) is marked *Needs attention* at once, and the owner is told once. A tool that is down or slow is only noted at first; when it has kept failing for half an hour it is marked too. The next successful look clears it. Paused connections are skipped and record nothing.

## Keys and safety

- Keys and Slack URLs live in Supabase Vault. The `integrations` table holds only the Vault id and the last four characters. The app never receives a key back.
- Keys are used to read payments and orders only. Counta never moves money with them.
- Disconnecting deletes the key and the webhook secret from Vault. Sales already recorded stay.
- Shop addresses must be public `https` addresses: Counta refuses private and local addresses so a key cannot be sent anywhere unexpected.
- `integration_events` and `integrations` are closed to the API; the app reads them through `org_integrations` and `integration_events_list`, which check membership.

## Settings for TaxStreem

Nothing to set beyond what Counta already uses: `PUSH_HOOK_SECRET` (in Vault, for the cron job) and the usual Supabase keys. These are for local tests only and must not be set in production: `PAYSTACK_BASE_URL`, `SHOPIFY_BASE_URL`, `BUMPA_BASE_URL`, `BUJETI_BASE_URL`, `INTEGRATIONS_TEST_HOSTS`.

## Functions and tables

- Edge function `integrations`: actions `connect`, `bumpa_import`, `sync`, `test`, `new_address`, the webhook routes and the poll.
- `integrations`: one live row per business and tool (`paystack`, `flutterwave`, `selar`, `woocommerce`, `shopify`, `zapier`, `bumpa`, `slack`, `bujeti`).
- `bujeti_categories`: each Bujeti category, Counta's suggestion and the confirmed account. `bujeti_items`: each Bujeti payment, invoice and vendor and what Counta did with it.
- `integration_events`: each payment a tool sent, once per connection.
- RPCs: `org_integrations`, `integration_events_list`, `integration_settings` (branch, Slack kinds, pause), `integration_disconnect`, `bujeti_overview`, `bujeti_categories_set`. Service only: `svc_integration_save`, `svc_integration`, `svc_integration_by_token`, `svc_integrations_due`, `svc_integration_note`, `svc_integration_sale`, `svc_slack_outbox`, `svc_bujeti_state`, `svc_bujeti_balances`, `svc_bujeti_categories`, `svc_bujeti_vendors`, `svc_bujeti_payments`, `svc_bujeti_receipt`, `svc_bujeti_invoices`.
