# Personal income tax: the hand-off to TaxStreem Flux

A business name or partnership has one personal income tax return per person (the proprietor, or each partner), each for the state that taxes that person (docs/personal-income-tax.md). Once the year is approved, Counta sends Flux the returns for the states Flux files; Flux signs in to the state's portal as the business, files each return, generates the pay bill, reports the payment, and applies for the tax clearance certificate when asked. The business files the others itself and marks them filed in Counta.

There is no template to fill for personal income tax on LIRS e-Tax, unlike the Rev360 templates for companies income tax. The portal is a set of screens, so Counta sends the answers to each screen as data, plus the files the portal asks to be uploaded. The screens, in order, are: login, Returns, My Tax Return, File Return, the year, the uploads (statement of account and tax computation), the statement of income, the accommodation disclosure, support staff, assets, the reliefs with their documents, file, then Payment, Generate pay bill and Pay now. This document follows that order.

Which states Flux files is in the rule book, `filing.flux_authorities` (to begin with `["SIRS:LA"]`, Lagos, as the PIT rule book s.13 says). TaxStreem adds a state by changing the rule book; nothing in the app changes.

Settings and signatures are the same as for CIT (docs/flux-cit-handoff.md): `FLUX_URL` and `FLUX_SECRET`, and on every request in both directions

```
x-counta-signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<raw body>" with FLUX_SECRET>
```

Until both are set, "Send to Flux" answers `not_configured` and tells the user to download the computation and file with the state, and no portal login can be saved.

## 1. The business's portal logins (Settings, Tax portal logins)

The owner chooses the tax authority (any of the 38: the NRS and every state revenue service, the FCT's included), enters the username and password and, if they like, the tax office. The app sends them to the tax-files function, which checks the person is the owner and signed in with two-step, and passes them straight on to Flux. Counta never stores, logs or shows the password; it keeps only which portal, a hint of the username (`ib•••01`), the tax office, Flux's reference and whether the login worked. Those who file tax see which logins are saved; nobody else sees the section.

`POST ${FLUX_URL}/counta/portal-credentials`:

```json
{
  "event": "portal.credentials.saved",
  "counta_org_id": "848b646b-...",
  "taxstreem_org_id": "ts_123 or null",
  "business": { "name": "Ibe & Partners", "tin": "2345678-0001", "registration_number": "BN 1234567" },
  "authority": { "code": "SIRS:LA", "name": "Lagos State Internal Revenue Service", "short_name": "LIRS", "state": "Lagos", "portal": "LIRS e-Tax" },
  "username": "ibepartners01",
  "password": "<the password, only here>",
  "tax_office": "Ikoyi",
  "replaces": "FLX-CRED-0007 or null",
  "callback_url": "https://<project>.supabase.co/functions/v1/taxstreem/flux/portal-login-status"
}
```

Flux keeps the login in its own vault and answers `2xx` with `{ "ok": true, "ref": "<Flux's reference to it>" }`. Without a `ref`, nothing is saved in Counta. When the owner replaces a login, `replaces` is the reference of the old one, which Flux can drop. Counta never repeats the password in what it shows: an error from Flux that quotes it is shown with the password masked. Flux must not log the password either.

When the owner removes a login, the same address gets `{ "event": "portal.credentials.removed", "counta_org_id", "authority", "ref" }`; Counta removes its record only once Flux answers `2xx`.

Each later request for the business carries Flux's reference (`portal.login_ref`), never the password.

When Flux signs in with a login, it says whether it worked:

`POST https://<project>.supabase.co/functions/v1/taxstreem/flux/portal-login-status`

```json
{ "counta_org_id": "848b646b-...", "authority": "SIRS:LA", "status": "failed", "message": "LIRS e-Tax said the password has expired." }
```

`status` is `verified` or `failed`. A failed login shows on the login in Settings with the message, and the owner and those who change settings are notified, with a link to Settings. Counta answers `200 { ok: true, status }`, `400` for a malformed body and `422` when the business has no login saved for that authority.

## 2. Counta to Flux: one approved return

`POST ${FLUX_URL}/counta/pit-returns`, one request per person, JSON:

```json
{
  "event": "pit.return.approved",
  "counta_org_id": "848b646b-...",
  "taxstreem_org_id": "ts_123 or null",
  "business": { "name": "Ibe & Partners", "kind": "partnership", "legal_form": "enterprise", "tin": "2345678-0001",
                "registration_number": "BN 1234567", "address": "12 Allen Avenue, Ikeja, Lagos" },
  "accounting_year": 2025,
  "year_of_assessment": 2026,
  "period": { "from": "2025-01-01", "to": "2025-12-31" },
  "regime": "PITA",
  "due": "2026-03-31",
  "approved": { "by": "Kelechi Ibe", "at": "2026-03-02T10:15:00Z" },
  "attested": { "by": "Kelechi Ibe", "at": "2026-03-02T10:15:00Z", "statement": "I confirm that the statement of accounts for ... is a true and correct account ..." },
  "taxpayer": { "person_id": "5f0c...", "name": "Ada Obi", "tin": "1234567-0001", "role": "active", "share_pct": 40, "resident": true,
                "authority": "SIRS:LA", "authority_name": "Lagos State Internal Revenue Service", "state": "Lagos",
                "office": { "id": "...", "name": "Head office", "state": "Lagos", "address": "..." } },
  "portal": { "authority": "SIRS:LA", "login_ref": "FLX-CRED-0008", "tax_office": "Ikoyi" },
  "files": {
    "statement_of_accounts": { "name": "statements.pdf", "url": "<signed link, 7 days>", "content_type": "application/pdf", "expires_in": 604800 },
    "tax_computation": { "name": "Ada Obi income tax computation 2025.pdf", "url": "<signed link, 7 days>", "content_type": "application/pdf", "expires_in": 604800 }
  },
  "return_form": {
    "statement_of_income": { "salary": 0, "commission": 0, "trade_income": 45260000, "allowance": 0, "pension": 0, "annuity": 0,
                             "foreign_income": 0, "dividend": 0, "interest": 0, "rent": 0, "other_income": 0 },
    "income_total": 45260000,
    "other_income_lines": [],
    "left_out_of_income": [ { "label": "Bank shares", "kind": "dividend", "amount": 1000000, "treatment": "final" } ],
    "accommodation": { "address": "3 Bourdillon Road, Ikoyi, Lagos", "type": "detached", "occupancy": "tenant", "landlord_name": "Chief Ade Bankole",
                       "landlord_id": "1987654-0001", "landlord_address": "1 Glover Road, Ikoyi", "rent_paid": 15000000, "rent_paid_by_employer": 15000000,
                       "started_on": "2021-03-01" },
    "support_staff": [ { "name": "Musa Bello", "role": "Office manager", "annual_pay": 15000000 } ],
    "assets": [ { "number": null, "name": "Computers", "category": "Plants (excluding Furniture and fittings)", "cost": 6000000, "in_use": "2025-03-01",
                  "first_year": 2025, "use_pct": 100, "tax_value_bf": 0, "allowance": 3750000, "tax_value_cf": 2250000, "disposed": false, "proceeds": null, "qualifies": true } ],
    "reliefs": [ { "relief": "pension", "label": "Pension contributions", "amount": 2000000, "rsa_number": "PEN200123456789", "pfa": "ARM Pension Managers",
                   "total_contribution": 2000000,
                   "documents": [ { "doc": "rsa_statement", "label": "Retirement savings account (RSA) statement for the year", "name": "rsa_statement.pdf",
                                    "url": "<signed link, 7 days>", "expires_in": 604800 } ] } ],
    "reliefs_left_out": []
  },
  "payment": { "mode": "pay_link", "note": "Generate the pay bill after filing and send it back as bill, with its payment link. ..." },
  "computation": {
    "rows": [ { "id": "S1", "line": "Share of the business's assessable profit (40%)", "amount": 41760000, "basis": "40% of ₦104,400,000.00 (s.15(1)(b) and (3))" } ],
    "figures": { "business_income": 47760000, "total_income": 45260000, "reliefs": 11084600, "chargeable_income": 34175400, "tax": 7994096, "wht_credit": 2000000, "payable": 5994096 },
    "bands": [ { "label": "First ₦300,000", "from": 0, "to": 300000, "rate": 0.07, "slice": 300000, "tax": 21000 } ],
    "other_income": [ { "kind": "rent", "field": null, "label": "Flat in Yaba", "amount": 3000000, "tax_deducted": 300000, "treatment": "taxable" } ]
  },
  "reliefs": { "pension": 2000000 },
  "business_computation": { "rows": [ { "id": "AP", "line": "Assessable profit / (loss) of the business", "amount": 104400000 } ], "figures": { "assessable": 104400000 } },
  "partners": [ { "person_id": "5f0c...", "name": "Ada Obi", "tin": "1234567-0001", "share_pct": 40, "role": "active", "authority": "SIRS:LA" } ],
  "rulebook": { "id": "ng-pit-pita-legacy@1.1.0", "version": "1.1.0", "status": "approved" },
  "callback_url": "https://<project>.supabase.co/functions/v1/taxstreem/flux/pit-status"
}
```

Screen by screen:

- **Login.** `portal.login_ref` is Flux's reference to the business's login for that portal (section 1). The tax office is the one the owner gave with it. Counta does not send a return when the business has no login saved for the person's state; it asks the owner to save one first.
- **Uploads.** `files.statement_of_accounts` is the statement of accounts attached to the year (the portal's "statement of account"). `files.tax_computation` is the person's own computation as a PDF: the app makes it from the approved figures when the return is sent, and it shows the business, how the profit is shared, the person's computation and the same lines as the return form. Copy both files on receipt: the links last seven days.
- **Statement of income.** `return_form.statement_of_income` has one amount for each line on the portal, and the lines add up to `income_total`. They are Counta's taxable figures, so the tax the portal works out is the tax Counta worked out: trade income is the person's income from the business after losses and capital allowances; a salary, commission or allowance from a job and a pension or annuity go on their own lines as the person entered them; foreign income is in naira; rent, dividends and interest are those taxed with the return. Income that was exempt, or taxed in full when the tax was deducted (a dividend with its WHT, for example), is left off and listed in `left_out_of_income`. Chargeable gains on the business's disposals (2026 accounts onwards) are part of `other_income`; `other_income_lines` names what is in it. A business loss gives a trade income of 0; the loss carries forward in Counta.
- **Accommodation.** `return_form.accommodation`: `type` is `flat`, `room`, `bungalow`, `duplex`, `terrace`, `detached` or `other`; `occupancy` is `tenant` (the portal's tenant), `owner` (the person owns and lives in it: the portal's landlord, with the person as the owner), `employer` (provided by an employer) or `family` (lives with family, pays no rent). For a tenant, the landlord's name and address and the rent are always there; `landlord_id` (the landlord's Tax ID or ID) when the person knows it. `rent_paid` is the year's rent and `rent_paid_by_employer` the part an employer paid. Counta does not approve a return Flux files without this disclosure.
- **Support staff.** `return_form.support_staff`: the business's employees for the year with their role, pay for the year and Tax ID when known. An empty list means the business confirmed it had none.
- **Assets.** `return_form.assets`: the business's fixed assets as the capital allowance schedule has them (cost, the year first in use, the tax value at the start and end of the year, the allowance).
- **Reliefs.** `return_form.reliefs`: each relief Counta counted, with its amount and the documents the portal asks for, as signed links. Pension adds the RSA number, the pension fund administrator and the total contribution (the portal's NPS retirement, PFA and total contribution, with the RSA statement). A relief entered without its documents is not counted in the computation and not sent; `reliefs_left_out` lists any, with what was missing, so Flux knows why it is not there. Rent relief (2026 accounts onwards) needs no document of its own: it comes from the accommodation disclosure of a tenant.

| Relief | Documents Counta requires before it counts |
| --- | --- |
| Pension contributions | RSA statement for the year, with the RSA number and the pension fund administrator |
| Health insurance (NHIS or an HMO) | The policy and evidence of payment |
| Life insurance or deferred annuity | The policy and evidence of payment |
| Mortgage interest | The mortgage agreement or loan documents, and a statement of the interest paid |
| National Housing Fund | The NHF contribution statement |
| Gratuity (2025 accounts) | A statement of the gratuity contributions |
| Rent relief (2026 accounts onwards) | None: the accommodation details of a tenant |

TaxStreem's list names the pension, health insurance, life insurance and mortgage documents. The NHF and gratuity statements follow the same rule, as Counta's reading; tell us if the portal accepts those reliefs without a document.

- `regime` is `PITA` for 2025 accounts and `NTA_2025_PIT` from 2026 accounts.
- `computation.rows` is the person's computation line by line, as the screen and the downloaded file show it; `figures` has every amount by name (docs/personal-income-tax.md lists them). `reliefs` is the reliefs counted.
- `partners` lists every partner, so the state has the particulars of the partnership and the shares (NTA 2025 s.15(5) and (7)). It is empty for a sole proprietor.
- `attested` is the taxpayer's attestation of the statement of accounts (NTAA 2025 s.13(2)(d)), given when the year was approved.

Flux answers `2xx` with `{ "ok": true, "ref": "<Flux's reference>", "message": "optional" }`. Anything else, or no answer in 30 seconds, is shown on that person's return as not sent, and the user can send again. A return with Flux or filed is not sent again.

## 3. Flux to Counta: the filing, the bill, the payment, the certificate

`POST https://<project>.supabase.co/functions/v1/taxstreem/flux/pit-status`, signed the same way. One call can carry the filing, the pay bill, the payment or the certificate, or several of them; `status` may be left out when it carries only the others.

```json
{ "counta_org_id": "848b646b-...", "accounting_year": 2025, "person_id": "5f0c...", "status": "filed", "ref": "FLX-PIT-0042",
  "message": "Filed and assessed", "acknowledgement_ref": "LIRS-ACK-778812", "filed_at": "2026-03-20T09:00:00Z",
  "assessment": { "tax": 5994096, "assessment_number": "LIRS-DA-2026-..." } }
```

| `status` | Effect in Counta |
| --- | --- |
| `processing` | The return shows "With Flux" with the message |
| `sent` | Flux has submitted it to the state. The year can no longer be reopened |
| `filed` | The return shows "Filed" with the acknowledgement; whoever files tax is notified. A filed return stays filed whatever comes after it |
| `rejected` | The return shows "Sent back" with the message; whoever files tax is notified. The business can mark it filed after fixing it with the state |

**The pay bill.** After filing, Flux generates the pay bill on the portal (Payment, Generate pay bill: the agency is the tax office, the revenue is direct assessment) and sends it:

```json
{ "counta_org_id": "848b646b-...", "accounting_year": 2025, "person_id": "5f0c...",
  "bill": { "amount": 5994096, "reference": "LIRS-BILL-778812", "agency": "Ikoyi tax office", "revenue": "Direct assessment", "payer_id": "N-1234567",
            "payment_url": "https://checkout.flutterwave.com/pay/...", "generated_at": "2026-03-20T09:05:00Z", "expires_at": "2026-04-30T23:59:00+01:00" } }
```

The bill shows on the return with a "Pay" button that opens `payment_url` (https only), and whoever files tax is told to pay it. The partner, or the business for them, pays through that link; Counta does not pay personal income tax from the business's wallet, because the tax is the partner's own. A bill can only follow a filed return.

**The payment.** When the state has the payment, Flux says so: `{ ..., "paid": { "paid_at": "2026-03-22T14:00:00Z", "reference": "FLW-778812", "amount": 5994096 } }`. The return shows "Paid" with the receipt and the Pay button goes.

**The tax clearance certificate.** See section 4. Flux reports on it with `{ ..., "tcc": { "status": "processing" | "issued" | "rejected", "ref", "number", "issued_at", "expires_on", "message" } }`. An issued certificate needs its `number`; it shows on the return with its number and the end of its validity, and whoever files tax is notified. A refused one shows the message. Send the certificate itself in `documents` with `kind: "tax_clearance"`.

Any call can carry the files the state gave (the acknowledgement, the assessment, the pay bill, the payment receipt, the certificate) in `documents`, kept in the business's Documents under Tax, PIT, for that year, in the same format and limits as for the other returns (docs/flux-tax-returns.md, section 6).

Counta answers `200 { ok: true, status, year_state }` (with `documents: { stored, failed }` when files were sent), `401` for a bad signature, `400` for a malformed body (or one with nothing in it) and `422` when the year is not approved, the person is not in it, or a bill, payment or certificate comes before the return is filed.

## 4. Counta to Flux: apply for a tax clearance certificate

Once a person's return is filed and paid (or nothing was payable), whoever files tax opens "Tax clearance" on the return, adds a profile picture of the person, attaches the returns for the two years before (the year itself, and any earlier year filed through Counta, need nothing more), ticks the person's authority to file any return still outstanding, and asks Flux to apply.

`POST ${FLUX_URL}/counta/pit-tcc`:

```json
{
  "event": "pit.tcc.requested",
  "counta_org_id": "848b646b-...",
  "taxstreem_org_id": "ts_123 or null",
  "business": { "name": "Ibe & Partners", "tin": "2345678-0001", "registration_number": "BN 1234567", "address": "..." },
  "accounting_year": 2025,
  "year_of_assessment": 2026,
  "taxpayer": { "person_id": "5f0c...", "name": "Ada Obi", "tin": "1234567-0001", "role": "active", "authority": "SIRS:LA", "authority_name": "Lagos State Internal Revenue Service", "state": "Lagos" },
  "portal": { "authority": "SIRS:LA", "login_ref": "FLX-CRED-0008", "tax_office": "Ikoyi" },
  "profile_picture": { "name": "Ada.jpg", "url": "<signed link, 7 days>", "expires_in": 604800 },
  "returns": [
    { "accounting_year": 2025, "year_of_assessment": 2026, "filed_in_counta": true, "acknowledgement_ref": "LIRS-ACK-778812" },
    { "accounting_year": 2024, "year_of_assessment": 2025, "filed_in_counta": false, "file": { "name": "2024 return.pdf", "url": "<signed link, 7 days>", "expires_in": 604800 } },
    { "accounting_year": 2023, "year_of_assessment": 2024, "filed_in_counta": false, "file": { "name": "2023 return.pdf", "url": "<signed link, 7 days>", "expires_in": 604800 } }
  ],
  "authorise_outstanding": true,
  "payment": { "at": "2026-03-22T14:00:00Z", "reference": "FLW-778812", "bill": { "amount": 5994096, "reference": "LIRS-BILL-778812" } },
  "callback_url": "https://<project>.supabase.co/functions/v1/taxstreem/flux/pit-status"
}
```

Flux answers `2xx` with `{ "ok": true, "ref": "<Flux's reference>", "message": "optional" }`; the return then shows "Certificate requested", and it is not asked for again unless the state refuses it.

## Who may do what

- Saving and removing the portal logins: the owner only, signed in with two-step. Those who file tax see which are saved.
- Sending to Flux, asking for the certificate, marking a return filed, approving and reopening: the owner, or someone with File tax.
- A person's documents (relief documents, the profile picture, earlier returns) are attached and opened by that person, when linked to their own Counta login, and by those who file tax. Those who only keep the books do not see them.
- The year can be reopened until any of its returns is with Flux or filed; after that an amended return is filed with the state. Reopening drops the computation made for the portal; the next approval makes a new one.
