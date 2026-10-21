# VAT, WHT and withholding VAT through TaxStreem Flux, and paying what Rev360 asks for

Flux files a business's returns on Rev360 with an RPA. Once a return is submitted, Rev360 issues a payment reference number
(PRN) and its payment page, through Flutterwave, shows a bank account opened for that one payment. The account changes every
time, so Counta cannot pay a fixed NRS account. Instead:

1. Counta sends Flux the month's return: VAT (once the month is filed in Counta), WHT to the NRS, or withholding VAT.
   The CIT return goes as before (docs/flux-cit-handoff.md).
2. Flux files it and reports back on the return.
3. Flux posts the PRN, the amount, what the amount is made of, and the account its RPA copied from the payment page. Counta
   checks the account with the bank and each part of the amount against its own figures, and pays it from the business's tax
   wallet when everything is explained, or holds it for the owner.
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
  "amount": 15053.75,
  "breakdown": { "tax": 8000.00, "credit_applied": 3000.00, "penalty": 10000.00, "interest": 0, "late_filing_penalty": 0, "charges": 53.75 },
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
- `breakdown`: what Rev360's amount is made of, as the RPA reads it from Rev360 and the payment page. Send it every time;
  without it Counta can only compare the bare amount with the return, and anything above or below waits for the owner.
  - `tax`: the tax Rev360 worked out on the return, before any credit is taken off.
  - `credit_applied`: credit Rev360 took off the tax. For VAT, the input VAT credit carried forward on the business's Rev360
    account; for CIT, the WHT credit notes. Zero otherwise.
  - `penalty`, `interest`, `late_filing_penalty`: what Rev360 added, usually because the return was late.
  - `charges`: Flutterwave's charge, added when the payment page opened the account.
  - Each part is a number of naira, none below zero, and `amount` must equal
    `tax - credit_applied + penalty + interest + late_filing_penalty + charges` to within a naira. A breakdown that does not
    add up is refused (`422`, saying what the parts come to). Parts left out count as zero; `tax` is required.

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
   the amount is explained by the return (below); the tax wallet holds enough; and the business has not switched automatic
   payment off.

   With a `breakdown`, the amount is explained when every part is:

   - `tax` agrees with the return in Counta to within a naira (for VAT, a kobo for each VAT line of the month when that is
     more, since the template works VAT out on totals and Counta line by line). The return is the VAT filed for the month
     before credit, the WHT or withholding VAT deducted for the NRS that month, or the approved CIT return's tax before credit.
   - `credit_applied` agrees with the credit Counta took off to within a naira: the input VAT credit brought forward that the
     month used, or the WHT credit notes on the CIT return.
   - `penalty`, `interest` and `late_filing_penalty` are zero, or the return was filed after its due date and the owner has
     left "Also pay the penalties and interest Rev360 adds to a return filed late" on (it is on unless switched off). The
     filing date is the `filed_at` Flux reported on the return (section 2), or when the PRN came if Flux did not report one.
   - `charges` is at most 2% of the rest of the amount, at least ₦100 and never more than ₦5,000.

   Without a `breakdown` the amount must be within ₦1 of what the return leaves to pay.
3. Otherwise it waits for the owner (`needs_approval`, with the reason), who is told by push, email and WhatsApp. The owner can
   pay it from the tax wallet with a tap, pay it by transfer from any bank and mark it paid, or ask Flux for a new account.
   The tax wallet never pays an account the bank says belongs to someone else, or one that is not a tax collection account.
4. An account that expires before it is paid is marked expired and the owner is told.

Posting the same PRN again with the same account and amount while it is being paid changes nothing (`"duplicate": true`).
A new account for the same PRN (after the last expired) replaces the old one while it is not being paid. A new PRN for the
same return replaces an older unpaid one.

Each part is booked to its own account when the payment is made, from the tax wallet or marked paid from a bank:

- VAT, WHT and withholding VAT: what the return in Counta left to pay clears the liability (Output VAT 2201, WHT Payable 2202,
  Withholding VAT Payable 2211). Tax Rev360 worked out above or below the return goes to Other Statutory Charges (6512).
- VAT credit: input VAT credit Rev360 took off that the books did not have is credited to Opening Balance Equity (3999), since
  it came from before the books in Counta; credit Counta used that Rev360 did not allow is a charge to 6512.
- CIT: the tax before credits clears what the books provided for (Current Income Tax Payable 2208, then Development Levy
  Payable 2209) and anything not provided for is the year's tax expense (7501). The WHT credit notes Rev360 took off come off
  WHT Credit Notes (1401), and any beyond what 1401 holds go to 3999.
- `penalty`, `late_filing_penalty` and `interest`: Penalties (6514), each on its own line.
- `charges` and the transfer fee: Bank Charges (6701).

Without a `breakdown`, the return's amount clears the liability and anything above it is booked to Penalties (6514).

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

## 6. Files Flux sends back

Each of the four requests Flux sends (`/flux/return-status`, `/flux/payment`, `/flux/payment-status` and
`/flux/cit-status` in [flux-cit-handoff.md](flux-cit-handoff.md)) can carry the files Rev360 gave, and Counta keeps them in
the business's Documents:

```json
"documents": [
  { "kind": "acknowledgement", "name": "WHT August 2026 acknowledgement.pdf", "content_type": "application/pdf", "content_base64": "JVBERi0xLjQK..." },
  { "kind": "filing_evidence", "name": "Schedule evidence", "url": "https://<flux host>/files/abc.png" }
]
```

- `kind`: `acknowledgement`, `filing_evidence` or `assessment` (filed under **Filing evidence**), `prn` (**PRN and
  payment**), `payment_receipt` or `tax_clearance` (**Payment receipts**), `other` (**From Flux**).
- Send each file inline as `content_base64` (a `data:` prefix is fine), or as an `https` `url` on Flux's own host
  (`FLUX_URL`) or a host in `FLUX_FILE_HOSTS` (admin portal, Keys and services, TaxStreem). Counta does not follow redirects.
- PDF, PNG, JPEG, WebP, Excel (`.xlsx`, `.xls`), CSV or Word (`.docx`). The bytes must be what the type says.
- Up to 10 files a request, 15 MB each and 40 MB together.
- `name` is what the business sees; Counta adds the extension when it is missing.
- The files are filed with the return's tax and month (the year for CIT). For `/flux/payment-status`, with the PRN's.
- The same request sent again adds the files again; send each file once.

The answer then carries `"documents": { "stored": 2, "failed": [{ "name": "...", "why": "..." }] }`. A file Counta refuses
never undoes the status: the status is kept, and the reason says what to change. Nothing is kept from a request that is not
signed, or about a return Counta never sent.

## Testing

`supabase/migrations/20261028000100_flux_tax_payments.sql` holds the database side, and
`supabase/migrations/20261028000200_flux_reconcile.sql` the breakdown, the checks on each part and how each is booked. The edge tests post every request above
against a mock Flux and Flutterwave, through the transfer relay.
