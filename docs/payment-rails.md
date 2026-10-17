# Payments and partner rails

Counta collects money for a business by bank transfer, payment link and QR code, and pays suppliers, refunds and withdrawals out of the business's wallet. There is no tap-to-pay. Flutterwave is the default rail and TaxStreem holds customer funds with Flutterwave. A partner that integrates TaxStreem can plug in its own rail instead; the books, the till and the customer pages work the same way on either.

## How money moves on Flutterwave

1. Each business gets a wallet: a Flutterwave payout subaccount with its own virtual account number (Payments, Open wallet). Customers can pay straight into it, and Atlas matches each credit to the customer.
2. At the till or on an invoice, Counta opens a payment request (`payment_requests`) and asks Flutterwave for a way to pay:
   - Pay by transfer: a one-off dynamic virtual account for the exact amount (Flutterwave keeps it open for about an hour).
   - Payment link: Flutterwave checkout (card, transfer or USSD), returning to the document page.
   - QR: Flutterwave NQR where it is enabled; otherwise a QR code of the payment link.
3. When Flutterwave says a charge completed, Counta looks the transaction up with `verify_by_reference` and records only what Flutterwave's own record says (amount, fee, payer). The webhook alone never records money.
4. The money lands in TaxStreem's Flutterwave balance and is swept into the business's wallet with a transfer whose reference is `SWP-<tx_ref>`. A retry uses a fresh reference (`SWP-<tx_ref>-<n>`) so a lost answer can never pay twice.
5. The sale is marked paid and posted: Dr wallet (under 1014) and Dr 6701 for Flutterwave's fee, Cr receivables (or, at the till, revenue and output VAT).
6. A cron job every five minutes re-checks unpaid requests, retries failed sweeps and re-checks payouts in progress, so a missed webhook only delays the answer.
7. Every night at 00:40 Counta reads each wallet's statement from Flutterwave, records credits the books are missing and compares the balance with the books. A difference becomes a question in the Books inbox.

At the till the screen waits for the transfer, checks every four seconds and says the payment out loud when it lands ("Payment received. Five thousand naira from Ada Obi."). Payments by another channel (cash, POS, a transfer into another bank account) are recorded by the cashier and confirmed by a manager or the bookkeeper once they show in the bank.

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
| (none) | Dr the account chosen on upload / Cr wallet | For a payroll sheet, choose Salaries & Wages once. |

On upload Counta asks the bank for the name on every account (five at a time) and checks every row against the books: the bill exists and is approved, the amount is not more than is owed, the account can take a payment, the same bill is not paid twice. A row whose bank name differs from the sheet stays unticked until someone ticks it. Rows that pay the same account the same amount, or an amount paid to that account in the last seven days, are flagged. The batch must fit in the wallet with the estimated transfer fees (₦10.75 up to ₦5,000, ₦26.88 up to ₦50,000, ₦53.75 above).

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

Webhook URL in the Flutterwave dashboard: `https://krtqqhndmncarwusukrw.supabase.co/functions/v1/payments/webhook/flutterwave`, with the same secret hash. Switch on webhooks for transfers as well as charges, and webhook retries.

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
| `POST /accounts` | `{ business_id, name, email, phone }` | `{ account_ref, account_number, bank_name, account_name }`: the business's wallet |
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
```

For collections and payouts the webhook is only a nudge: Counta calls `GET /collections/{tx_ref}` or `GET /payouts/{reference}` and records what that says. `wallet.funded` covers money paid straight into the wallet's account number; it is recorded once per `provider_ref`. Answer 200 quickly; Counta's own checks every five minutes cover anything the webhook missed.

## Testing a rail

The edge test harness (kept outside the repository) runs a mock partner rail through the whole cycle: open wallet, collect by account, link and QR, the paid webhook with a bad and a good signature, payout, payout webhook and balance. A partner can run the same calls against its sandbox before going live.
