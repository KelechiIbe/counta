# Payments and partner rails

Counta collects money for a business by bank transfer, payment link and QR code, and pays suppliers, refunds and withdrawals out of the business's wallet. There is no tap-to-pay. Flutterwave is the default rail and TaxStreem holds customer funds with Flutterwave. A partner that integrates TaxStreem can plug in its own rail instead; the books, the till and the customer pages work the same way on either.

## How money moves on Flutterwave

1. Each business gets two wallets, both Flutterwave payout subaccounts in its name with their own account numbers (Payments, Open wallet): the business wallet, which takes payments and pays suppliers, and the tax wallet (see below). Customers can pay straight into the business wallet, and each credit is matched to the sale or invoice waiting for it.
2. At the till or on an invoice, Counta opens a payment request (`payment_requests`) and asks Flutterwave for a way to pay:
   - Pay by transfer: the business wallet's own account number, with the sale's number (`pay_ref`) to put in the transfer's description. The request waits at once; when the transfer reaches the wallet, Counta reads the wallet's statement and matches it, by that reference first, then by the amount (the oldest sale waiting for that amount, flagged for a check when several were). The money never passes through TaxStreem's balance, so it needs no sweep. The rail capability `direct_account` switches this on; without it, Counta falls back to a one-off dynamic virtual account on TaxStreem's account, swept as in step 4.
   - Payment link: Flutterwave checkout (card, transfer or USSD), returning to the document page.
   - QR: Flutterwave NQR where it is enabled; otherwise a QR code of the payment link.
3. When Flutterwave says a charge completed, Counta looks the transaction up with `verify_by_reference` and records only what Flutterwave's own record says (amount, fee, payer). The webhook alone never records money.
4. Card, USSD and QR payments land in TaxStreem's Flutterwave balance and are swept into the business's wallet with a transfer whose reference is `SWP-<tx_ref>`. A retry uses a fresh reference (`SWP-<tx_ref>-<n>`) so a lost answer can never pay twice.
5. The sale is marked paid and posted: Dr wallet (under 1014) and Dr 6701 for Flutterwave's fee, Cr receivables (or, at the till, revenue and output VAT).
6. A cron job every five minutes re-checks unpaid requests, retries failed sweeps and re-checks payouts in progress, so a missed webhook only delays the answer.
7. Every night at 00:40 Counta reads each wallet's statement from Flutterwave, records credits the books are missing and compares the balance with the books. A difference becomes a question in the Books inbox.

At the till the screen waits for the transfer, checks every four seconds and says the payment out loud when it lands ("Payment received. Five thousand naira from Ada Obi."). Payments by another channel (cash, POS, a transfer into another bank account) are recorded by the cashier and confirmed by a manager or the bookkeeper once they show in the bank.

### How fast a transfer is confirmed

Pay by transfer is confirmed without anyone checking the bank: Flutterwave tells Counta as soon as the money reaches the account it gave (the webhook), Counta asks Flutterwave to confirm before recording anything, and the till and the poll ask as well in case the webhook is late. A transfer sent by NIP usually lands within seconds of the customer pressing send; when the customer's bank holds it, the sale waits until it arrives, and nothing is marked paid on the customer's word. A transfer into one of the business's other bank accounts cannot be seen by Counta; it waits for someone to confirm it against the bank (Sales, Payments to confirm).

When the customer quotes no reference, the amount does the matching. A transfer to the business's own wallet number goes to the sale waiting for exactly that amount (opened up to four days before it arrived, or up to ten minutes after); with one such sale it is matched outright. With several waiting for the same amount, it goes to the oldest and the people who keep the books are asked to check which sale it paid. A transfer for an amount no sale is waiting for (part of a sale, or two sales in one transfer) is not matched by itself: it lands in Banking as money into the wallet, they are told, Atlas suggests a match, and the sale keeps waiting until someone matches it. With one-off accounts (the rail without `direct_account`) no reference is needed: each sale has its own account number, and whatever reaches it is recorded against that sale, so a short payment leaves the sale part-paid.

Goods leave once the money is confirmed. With Deliveries wait for the payment on (Sell, Online shop; on by default), a delivery cannot be marked dispatched or delivered while its sale is unpaid, waiting for a transfer, or paid by a transfer not yet confirmed. A manager can agree payment on delivery for a customer they trust, and the delivery shows who agreed it.

## When Flutterwave cannot make a wallet's account number

Flutterwave sometimes refuses a new wallet with "Error occurred while generating your nuban account" and gives no reason. Counta then tries again in order:

1. without the phone number, on an address of the wallet's own (`name+w…@domain`, or `+wt…` for a tax wallet)
2. on an address of Counta's (`wallet-…@counta.ng`, or `tax-…@counta.ng`)
3. under the name with " Wallet" after it, first with the business's email and phone, then on the last address without the phone

The wallet keeps the name Flutterwave opened it under, so a business may see "<name> Wallet" on its account. The third step exists because Flutterwave would not open any wallet named "Taxstreem Technologies Limited", the name on TaxStreem's own Flutterwave account, while "Taxstreem Technologies Limited Tax" opened. When every try fails, the wallet records each one with Flutterwave's answer, and Open wallet tries again from the start.

## Transfers need the relay

Flutterwave takes transfers (payouts, bulk payments, sweeps, moves between a business's two wallets and tax payments) only from IP addresses whitelisted on TaxStreem's account. Supabase's servers have no fixed address, so Counta sends every transfer through TaxStreem's relay, a small server with one fixed address: see [transfer-relay.md](transfer-relay.md). Without the relay set up (`FLW_RELAY_URL` and `FLW_RELAY_SECRET` in the admin portal), transfers wait: a payout stays approved, a sweep stays pending, a move to the tax wallet waits, and each goes once the relay works. Collections need no relay.

## The tax wallet

The second account number holds the business's tax. Moves into it are automatic:

- VAT: when a payment reaches the business wallet (a till sale, an invoice paid, money paid with no request and taken as a sale), the VAT share of it (`amount x VAT / total` of the sale) is queued to move.
- WHT: when a supplier's bill is paid from the business wallet, the WHT and withholding VAT kept back are queued to move.

The poll every five minutes gathers what is queued into one transfer per business (reference `TAXB-…`), sends it from the business wallet to the tax wallet, and books it (Dr tax wallet / Cr business wallet) the moment Flutterwave accepts it. A transfer Flutterwave later reports failed is reversed and tried again under a new reference. While a move is queued, the business wallet cannot pay that money out.

Money leaves the tax wallet only to pay tax: a filed VAT month, or a month's WHT for one authority, to an account TaxStreem lists in the admin portal (Alerts and tax wallets) for that tax, with the payment reference the tax office gave (`CNTX-…` is Counta's own reference). When Flutterwave confirms, the VAT month is marked paid (or the WHT remittance recorded and the deductions marked remitted). Once a month's VAT is paid, and once deductions are remitted, whatever the tax wallet holds beyond the tax still owed goes back to the business wallet. When the tax wallet holds less than is owed (VAT collected into other bank accounts, say), the Payments page shows the shortfall and the tax wallet's number to top it up.

## Payouts

Payouts (supplier bills, refunds, withdrawals) leave from the wallet. Bills are paid net of withholding tax, and the WHT is credited to 2202 until it is remitted. Above the business's approval threshold a second person must approve. If Flutterwave does not answer, the payout stays "processing" and the poller asks again; it is never resent blindly.

## Bulk payments

Payments, Bulk payments takes a spreadsheet of payments: salaries, allowances, suppliers' bills and other costs. The template (Download the template) has a Payments sheet with a dropdown of the rail's banks, a worked example and a How to fill it sheet. A payroll or bank upload sheet with the same information works too; its columns are matched on screen.

Each row needs the beneficiary's name, bank, 10-digit account number and the amount they receive. What the row pays for is one of:

| Column | Posts | Notes |
| --- | --- | --- |
| Bill number | Dr 2101 payables (the bill's supplier) / Cr 2202 WHT / Cr wallet | Paid through the same path as Pay bill. Leave Amount empty to pay what is owed after WHT. The bill clears when the bank confirms. |
| Supplier in Counta | Dr 2101 payables (that supplier) / Cr wallet | A payment on account, with no WHT. |
| Account code | Dr that account / Cr wallet | Any postable account except bank, cash, wallet, receivables, payables, customer advances, inventory and equity accounts. |
| (none) | Dr the account chosen on upload or on the review step / Cr wallet | No bill is needed. For a payroll sheet, choose Salaries & Wages once. Placeholders such as NA, N/A, nil, none, - or 0 in the bill, supplier, account, type-of-work or Tax ID columns count as empty. |
| Type of work (a contractor with no bill) | Writes and approves a bill for the work: Dr the account / Cr 2101; then pays it: Dr 2101 / Cr 2202 WHT / Cr wallet | See Contractors below. |

On upload Counta asks the bank for the name on every account (five at a time) and checks every row against the books: the bill exists and is approved, the amount is not more than is owed, the account can take a payment, the same bill is not paid twice. A row whose bank name differs from the sheet stays unticked until someone ticks it. Rows that pay the same account the same amount, or an amount paid to that account in the last seven days, are flagged. The batch must fit in the wallet with the estimated transfer fees (₦10.75 up to ₦5,000, ₦26.88 up to ₦50,000, ₦53.75 above).

### Contractors

A contractor paid with no bill in Counta goes on the same sheet. The template's columns Type of work (a list: services, professional services, construction, supply of goods, rent, commission, brokerage, no withholding tax), Company or individual, Tax ID, Address, State and Contract amount before WHT (instead of Amount) carry what the books need. Counta finds the contractor among the business's suppliers by Tax ID, then by bank account, then by name, or adds them when the batch is saved. The withholding tax rate comes from the type of work and whether the contractor is a company, the small-company rule (no WHT while a month's purchases from a supplier with a Tax ID stay within ₦2 million) and exemptions on file. The contractor receives the contract amount less WHT.

The same rules as a bill apply:

- Where the work attracts withholding tax, the row needs the contractor's Tax ID. One on file and already checked is enough; a new one must be checked with the NRS first, from the review screen (Check with the NRS), and the NRS's name for it must match the contractor or the account. Up to 60 checks a day per business.
- A company or a business name is paid only with its address, on file or in the sheet.
- WHT from an individual or a business name goes to the state revenue service, so the state must be known.
- What is on file wins over the sheet: a different Tax ID, or an individual on file listed as a company, is shown as an error to resolve.

Each contractor row writes and approves a bill (source `bulk`) when the batch is saved and pays it in the batch. If the batch is declined or cancelled before the money leaves, those bills are voided and their postings reversed.

A batch is approved once, as a whole: when its total is at or above the approval threshold and the person who made it is not the owner, someone else who makes payments approves it. One notice goes out for the approval and one when the batch finishes, not one per row. Rows of a batch cannot be approved one by one.

Send now hands the rows to Flutterwave from the business's payout subaccount (`debit_subaccount`), one transfer per row with its own `CNTP-` reference. Each row moves to "processing" before it is sent, so the page and the five-minute poll can both push a batch without paying anyone twice; closing the page does not stop it. A row Flutterwave refuses is marked failed with Flutterwave's reason and nothing leaves the wallet for it. Results come back per row (webhook `transfer.completed`, or the poll), and Download the results gives each row's status, fee, WHT, reference and reason.

Flutterwave's bulk transfer endpoint (`POST /v3/bulk-transfers`, results from `GET /v3/transfers?batch_id=`) is built in and switched off. Flutterwave documents `debit_subaccount` for single transfers but not inside `bulk_data`; if it were ignored, a bulk transfer would be paid from TaxStreem's main balance instead of the business's wallet. Once Flutterwave confirms in writing that bulk items debit the payout subaccount, switch it on with:

```sql
update public.payment_rails set capabilities = array_append(capabilities, 'bulk_payout')
where code = 'flutterwave' and not ('bulk_payout' = any(capabilities));
```

Batches made after that go as one bulk transfer of up to 100 rows per request. Removing `bulk_payout` sends any batch still waiting one row at a time.

## Flutterwave setup

| Secret | Value |
| --- | --- |
| `FLW_SECRET_KEY` | Live secret key |
| `FLW_PUBLIC_KEY` | Live public key |
| `FLW_WEBHOOK_HASH` | The secret hash set in the Flutterwave dashboard |

Webhook URL in the Flutterwave dashboard: `https://krtqqhndmncarwusukrw.supabase.co/functions/v1/payments/webhook/flutterwave`, with the same secret hash. Switch on webhooks for transfers as well as charges, webhook retries, and "Enable payout subaccounts wallet funding hook" so a transfer to a business's own number is seen at once (the poll reads the wallets' statements anyway).

| Secret | Value |
| --- | --- |
| `FLW_RELAY_URL` | The relay's https address, for example `https://relay.taxstreem.com` |
| `FLW_RELAY_SECRET` | The `RELAY_SECRET` set on the relay server |
| `FLW_MERCHANT_ID` | TaxStreem's own Flutterwave merchant ID, where Counta plans paid from a business wallet go (see [plans-and-costs.md](plans-and-costs.md)) |

Payments, Settings shows whether the keys and the secret hash are set and when Flutterwave last reached Counta with a verified event. Flutterwave only sends an event once money moves, so that line stays empty until the first payment or transfer. Phone numbers go to Flutterwave as digits only (`08035550142`); Flutterwave refuses anything else.

## Adding a partner rail

A partner implements the Counta Rail API below over HTTPS and gives TaxStreem an API key and a webhook secret. TaxStreem then registers the rail:

```sql
insert into public.payment_rails (code, name, kind, base_url, capabilities, api_key_secret, webhook_secret, support_contact)
values ('acmepay', 'AcmePay', 'http', 'https://api.acmepay.ng/counta/v1', '{wallet,account,link,qr,payout}',
        'RAIL_ACMEPAY_KEY', 'RAIL_ACMEPAY_WEBHOOK', 'ops@acmepay.ng');
```

`api_key_secret` and `webhook_secret` are the names of secrets, never the values. Put the values in Supabase Vault (or Edge Function secrets) under those names.

A business moves to the partner's rail when the partner's TaxStreem sign-on sends `"rail": "acmepay"` (see [taxstreem-sso.md](taxstreem-sso.md)), or when TaxStreem sets `orgs.payment_rail`. A business that already has an active wallet stays on its rail until that wallet is closed, so money is never split across two providers without anyone noticing.

### Counta Rail API

Counta calls the partner's base URL with:

```
Authorization: Bearer <api key>
Content-Type: application/json
X-Counta-Version: 1
```

Amounts are naira with two decimals. Times are ISO 8601. A 404 means "not found"; any other non-2xx answer is shown to the user with the partner's `error` or `message`.

| Call | Request | Answer |
| --- | --- | --- |
| `POST /accounts` | `{ business_id, name, email, phone, purpose: "main" \| "tax" }` | `{ account_ref, account_number, bank_name, account_name }`: the business wallet, or its tax wallet |
| `POST /accounts/{account_ref}/move` | `{ to_account_ref, amount, reference, narration }` | `{ status: "sent" \| "failed", provider_ref?, error? }`: money between a business's two accounts; idempotent on `reference` |
| `GET /accounts/{account_ref}/balance` | | `{ available, ledger }` |
| `GET /accounts/resolve?account_number=&bank_code=` | | `{ account_name }` |
| `GET /banks` | | `[{ code, name }]` |
| `POST /collections` | `{ tx_ref, amount, currency: "NGN", method: "account" \| "link" \| "qr", account_ref, customer: { name, email, phone }, narration, expires_in, redirect_url }` | `{ provider_ref, account_number?, bank_name?, account_name?, link_url?, qr_image?, expires_at? }` |
| `GET /collections/{tx_ref}` | | `{ status: "pending" \| "paid" \| "failed", amount_paid, fee, provider_ref, payer: { name, account_number, bank }, paid_at }` |
| `POST /payouts` | `{ reference, amount, currency, bank_code, account_number, account_name, narration, account_ref }` | `{ status: "processing" \| "successful" \| "failed", provider_ref, fee }` |
| `GET /payouts/{reference}` | | `{ status, provider_ref, fee, error }` |

Rules the partner must keep:

- `tx_ref` and payout `reference` are Counta's idempotency keys. A repeated `POST` with the same key must return the original result, not create a second collection or payout.
- Money collected for a business must end in that business's wallet (`account_ref`). If the partner collects into a pooled account first, it moves the money before answering `paid`.
- `qr_image` is a data URL or an https URL of an image. When it is missing, Counta shows a QR code of `link_url`.

### Webhooks from the partner

`POST https://krtqqhndmncarwusukrw.supabase.co/functions/v1/payments/webhook/rail/{code}`

```
x-counta-signature: sha256=<hex HMAC-SHA256 of the raw body with the webhook secret>
{ "event": "collection.paid", "data": { "tx_ref": "CNT-…" } }
{ "event": "payout.completed", "data": { "reference": "CNTP-…" } }
{ "event": "payout.failed", "data": { "reference": "CNTP-…" } }
{ "event": "wallet.funded", "data": { "account_ref", "amount", "reference", "provider_ref", "narration", "sender": { "name", "account_number", "bank" }, "at" } }
{ "event": "move.completed", "data": { "reference": "TAXB-…" } }
{ "event": "move.failed", "data": { "reference": "TAXB-…", "error" } }
```

For collections and payouts the webhook is only a nudge: Counta calls `GET /collections/{tx_ref}` or `GET /payouts/{reference}` and records what that says. `wallet.funded` covers money paid straight into the wallet's account number; it is recorded once per `provider_ref`. Answer 200 quickly; Counta's own checks every five minutes cover anything the webhook missed.

## Testing a rail

The edge test harness (kept outside the repository) runs a mock partner rail through the whole cycle: open wallet, collect by account, link and QR, the paid webhook with a bad and a good signature, payout, payout webhook and balance. A partner can run the same calls against its sandbox before going live.
