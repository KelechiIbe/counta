# VAT, WHT and withholding VAT through TaxStreem Flux, and paying what Rev360 asks for

Flux files a business's returns on Rev360 with an RPA. Once a return is submitted, Rev360 issues a payment reference number
(PRN) and its payment page, through Flutterwave, shows a bank account opened for that one payment. The account changes every
time, so Counta cannot pay a fixed NRS account. Instead:

1. Counta sends Flux the month's return: VAT (once the month is filed in Counta), WHT to the NRS, or withholding VAT.
   The CIT return goes as before (docs/flux-cit-handoff.md).
2. Flux files it and reports back on the return.
3. Flux posts the PRN, the amount and the account its RPA copied from the payment page. Counta checks the account with the
   bank and pays it from the business's tax wallet when everything agrees, or holds it for the owner.
4. Counta tells Flux each payment it makes, and Flux tells Counta when Rev360 confirms it.

Settings, signatures and the five-minute clock window are the same as for CIT: `FLUX_URL`, `FLUX_SECRET`, and on every request
in both directions

```
x-counta-signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<raw body>" with FLUX_SECRET>
```

Counta's endpoints below are on `https://<project>.supabase.co/functions/v1/taxstreem`. Each answers `{ "ok": true, ... }`, or
`401` for a bad or old signature, `400` for a malformed request and `422` with `{ "ok": false, "error": "..." }` for one Counta
refuses (the error says why in plain words).

## 1. Counta to Flux: a return

`POST ${FLUX_URL}/counta/tax-returns`

```json
{
  "event": "tax.return.ready",
  "counta_org_id": "848b646b-...",
  "taxstreem_org_id": "ts_123 or null",
  "company": { "name": "Adaeze Foods Ltd", "tin": "2345678900099", "rc_number": "RC 1234567", "address": "12 Allen Avenue, Ikeja, Lagos" },
  "tax": "vat | wht | wvat",
  "period": "2026-09",
  "authority": "NRS",
  "amount": 325500.00,
  "to_pay": 5000.00,
  "due": "2026-10-21",
  "sent_by": "Kelechi Ibe",
  "summary": { "output": 0, "input": 0, "withheld_by_customers": 0, "credit_brought_forward": 0, "credit_used": 0, "payable": 0, "credit_carried_forward": 0, "refund_claimed": 0, "filed_in_counta_at": "..." },
  "schedule": { "rows": [ "..." ], "total": 325500.00 },
  "checks": [ { "severity": "warn", "text": "..." } ],
  "files": [ { "name": "2026-09_WHT_NRS_2345678900099.xlsx", "url": "<signed link, 7 days>", "content_type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "rows": 11, "total": 325500.00, "expires_in": 604800 } ],
  "callback_url": "https://<project>.supabase.co/functions/v1/taxstreem/flux/return-status",
  "payment_url": "https://<project>.supabase.co/functions/v1/taxstreem/flux/payment",
  "payment_status_url": "https://<project>.supabase.co/functions/v1/taxstreem/flux/payment-status"
}
```

- `vat`: the NRS VAT return workbook (Form VAT 002, schedules A to F) and `summary`, the figures frozen when the month was
  filed in Counta. `schedule` has the form's lines and Counta's own figures for the month.
- `wht`: WHT to the NRS on the NRS template (130 rows a file, so a big month is several files) and the rows as JSON.
  WHT for a state revenue service is not sent: it is paid to the state.
- `wvat`: withholding VAT and VAT self-charged on services from abroad, as rows (there is no template file).
- `amount` is the whole month on the return; `to_pay` is what Counta still shows as owed for it.
- The links expire after seven days. Copy the files on receipt.

Flux answers `2xx` with `{ "ok": true, "ref": "<Flux's reference>", "message": "optional" }`. Anything else is shown to the
user as not sent, with Flux's `error`, and they can send it again. A `5xx` or no answer in 30 seconds reads as "Flux did not
answer". While a return is with Flux (sent, processing or filed) Counta will not send it again.

## 2. Flux to Counta: where the return stands

`POST /flux/return-status`

```json
{ "counta_org_id": "848b646b-...", "tax": "wht", "period": "2026-09", "status": "processing | sent | filed | rejected",
  "ref": "FX-123", "message": "optional, shown to the user", "acknowledgement_ref": "ACK-...", "filed_at": "2026-10-12T09:30:00Z" }
```

`filed` and `rejected` notify whoever files tax. A filed return stays filed whatever comes after it.

## 3. Flux to Counta: the payment Rev360 asks for

`POST /flux/payment`, as soon as the payment page shows the account:

```json
{
  "counta_org_id": "848b646b-...",
  "tax": "vat | wht | wvat | cit",
  "period": "2026-09",
  "accounting_year": 2025,
  "authority": "NRS",
  "prn": "PRN-1234567890",
  "amount": 5000.00,
  "account": { "number": "9900001111", "bank_name": "Wema Bank", "bank_code": "035 (optional)", "name": "NIGERIA REVENUE SERVICE REV360" },
  "expires_at": "2026-10-13T09:30:00Z",
  "ref": "Flux's reference for this payment",
  "message": "optional"
}
```

- `period` is the return's month (`YYYY-MM`) for VAT, WHT and withholding VAT. For CIT send `accounting_year` instead.
- `prn`: 4 to 60 letters, digits, `/ . _ -`. One request per PRN per business.
- `account.number` must be the 10-digit account; `bank_name` as the page shows it (Counta finds the bank code from
  Flutterwave's bank list, or uses `bank_code` when it is one Flutterwave knows); `name` as the page shows it.
- `expires_at` when the page says the account stops taking money, if it says.

Counta answers at once:

```json
{ "ok": true, "id": "<Counta's id>", "status": "paying | needs_approval | expired | received", "decision": "pay | wait | expired", "reason": "why it waits" }
```

What Counta does with it:

1. Asks the bank who holds the account (Flutterwave's account lookup).
2. Pays it straight away from the business's tax wallet, with the PRN at the start of the transfer narration, when all of
   these hold: the account has more than two minutes left; the business has an open tax wallet and is not a sample business;
   the bank was found and its name for the account matches `account.name`; that name looks like a tax collection account
   (it mentions revenue, NRS, FIRS, Rev360 or tax); the return is not paid already and no other payment for it is on its way;
   the amount is within ₦1 of the return in Counta (VAT filed for the month, WHT or withholding VAT deducted for the NRS that
   month, or the approved CIT return's tax payable); the tax wallet holds enough; and the business has not switched automatic
   payment off.
3. Otherwise it waits for the owner (`needs_approval`, with the reason), who is told by push, email and WhatsApp. The owner can
   pay it from the tax wallet with a tap, pay it by transfer from any bank and mark it paid, or ask Flux for a new account.
   The tax wallet never pays an account the bank says belongs to someone else, or one that is not a tax collection account.
4. An account that expires before it is paid is marked expired and the owner is told.

Posting the same PRN again with the same account and amount while it is being paid changes nothing (`"duplicate": true`).
A new account for the same PRN (after the last expired) replaces the old one while it is not being paid. A new PRN for the
same return replaces an older unpaid one.

What Rev360 asks above the return is booked as a penalty or interest. For CIT, the payment clears what the books provided for
(Current Income Tax Payable, then Development Levy Payable) and the rest is the year's tax expense.

## 4. Counta to Flux: a new account, and each payment made

`POST ${FLUX_URL}/counta/tax-payments`, when the owner asks for a new account:

```json
{ "event": "tax.payment.account_requested", "instruction_id": "...", "counta_org_id": "...", "taxstreem_org_id": "...", "tax": "vat",
  "period": "2026-09", "accounting_year": null, "authority": "NRS", "prn": "PRN-1234567890", "amount": 5000.00, "requested_by": "Kelechi Ibe",
  "payment_url": "https://<project>.supabase.co/functions/v1/taxstreem/flux/payment" }
```

Flux reopens the payment page for the PRN and posts the new account to `/flux/payment` as above.

And within five minutes of each payment Counta makes or records:

```json
{ "event": "tax.payment.made", "instruction_id": "...", "counta_org_id": "...", "prn": "PRN-1234567890", "tax": "vat", "amount": 5000.00,
  "paid_at": "2026-10-12T09:41:00Z", "from": "tax_wallet | bank_account", "transfer_reference": "CNTX-... or null", "provider_ref": "Flutterwave's transfer id or null" }
```

Answer `2xx`. Counta retries every five minutes for a week until it gets one.

## 5. Flux to Counta: what Rev360 says of the payment

`POST /flux/payment-status`

```json
{ "counta_org_id": "848b646b-...", "prn": "PRN-1234567890", "status": "confirmed | not_received | expired", "receipt_ref": "RCPT-...",
  "confirmed_at": "2026-10-12T10:02:00Z", "message": "optional" }
```

- `confirmed`: Rev360 has the payment. If the owner paid it from a bank and has not marked it yet, Counta asks them to, so the
  books show it.
- `not_received`: the owner is told, with `message`.
- `expired`: an unpaid request is marked expired and the owner is told.

## Testing

`supabase/migrations/20261028000100_flux_tax_payments.sql` holds the database side. The edge tests post every request above
against a mock Flux and Flutterwave, through the transfer relay.
