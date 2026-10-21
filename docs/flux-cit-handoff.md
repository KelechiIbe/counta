# Companies income tax: the hand-off to TaxStreem Flux

Counta prepares each company's CIT return year by year (2023 accounts onwards) and fills the NRS Rev360 CIT template from it. Once a person with authority approves the year and attaches the audited financial statements, Counta sends the return to Flux, which files it on Rev360 and reports back.

Nothing is sent until the year is approved. An approved year is frozen: the computation, the template cells, the fixed asset declaration and the company details are kept as they were at approval, so the file Flux receives is the file the business approved even if the books change later.

## Settings

Two edge function secrets, set by TaxStreem (never in the repository or a chat):

| Secret | What it is |
| --- | --- |
| `FLUX_URL` | Flux's base URL, for example `https://flux.taxstreem.com/api`. Counta posts to `${FLUX_URL}/counta/cit-returns`. |
| `FLUX_SECRET` | A shared secret for signing both directions. |

Until both are set, "Send to Flux" answers `not_configured` and tells the user to download the file and file it on Rev360 themselves.

## Signatures

Both directions carry the header

```
x-counta-signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<raw body>" with FLUX_SECRET>
```

The receiver recomputes the HMAC over the exact bytes received and rejects a timestamp more than five minutes from its own clock.

## Counta to Flux: an approved return

`POST ${FLUX_URL}/counta/cit-returns`, JSON:

```json
{
  "event": "cit.return.approved",
  "counta_org_id": "848b646b-...",
  "taxstreem_org_id": "ts_123 or null",
  "company": { "name": "Adaeze Foods Ltd", "tin": "2345678900099", "rc_number": "RC 1234567", "address": "12 Allen Avenue, Ikeja, Lagos" },
  "accounting_year": 2025,
  "year_of_assessment": 2026,
  "period": { "from": "2025-01-01", "to": "2025-12-31" },
  "regime": "NTA_2025",
  "due": "2026-06-30",
  "approved": { "by": "Kelechi Ibe", "at": "2026-03-02T10:15:00Z" },
  "files": {
    "template": { "name": "2025_2345678900099_CIT.xlsx", "url": "<signed link, 7 days>", "sha256": "<hex>", "content_type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "expires_in": 604800 },
    "financial_statements": { "name": "afs-2025.pdf", "url": "<signed link, 7 days>", "expires_in": 604800 }
  },
  "fixed_asset_declaration": [ { "key": "fa:...", "name": "Delivery van", "number": "FA-0003", "date": "2024-05-01", "category": "...", "description": "05.06.01100 - Motor vehicle", "cost": 18500000, "accumulated_depreciation": 4625000, "charge_for_year": 3700000, "disposed": false, "proceeds": null, "allowance": 3515000, "twdv_cf": 11285000 } ],
  "computation": { "rows": [ { "id": "A", "line": "Profit / (loss) before tax", "amount": 41250000 } ], "figures": { "total_tax": 0, "payable": 0 } },
  "callback_url": "https://<project>.supabase.co/functions/v1/taxstreem/flux/cit-status"
}
```

- `regime` is `LEGACY_CITA` for 2023 and 2024 accounts (Companies Income Tax Act, tertiary education tax) and `NTA_2025` from 2025 accounts (Nigeria Tax Act 2025, development levy).
- The template is the Rev360 workbook with the formulas intact and their cached values recalculated; `sha256` is of the file the link serves. Counta has checked that its profit before tax, add-backs, deductions and balance sheet totals agree with the approved computation to within ₦1 before sending.
- The template's year cell has a data validation of 2025 or later. Counta writes 2023 and 2024 there anyway for prior-year returns; Flux should expect that and either file it as is or ask Rev360 how prior years are taken.
- The links expire after seven days. Flux should copy the files on receipt.

Flux answers `2xx` with `{ "ok": true, "ref": "<Flux's own reference>", "message": "optional" }`. Any other answer, or `ok: false` with `error`, is shown to the user as "Not sent" with the message, and they can send again. A send that times out (30 seconds) is treated the same way.

## Flux to Counta: status

`POST https://<project>.supabase.co/functions/v1/taxstreem/flux/cit-status`, signed the same way:

```json
{ "counta_org_id": "848b646b-...", "accounting_year": 2025, "status": "filed", "ref": "FLX-2026-0042",
  "message": "Filed and acknowledged", "acknowledgement_ref": "REV360-ACK-778812", "filed_at": "2026-04-10T09:00:00Z",
  "rev360_computation": { "...": "what Rev360 computed, kept for comparison" } }
```

| `status` | Effect in Counta |
| --- | --- |
| `processing` | Shown as "With Flux" with the message. The year stays approved. |
| `sent` | Flux has submitted it on Rev360. The year shows "With Flux" and can no longer be reopened in Counta. |
| `filed` | The year shows "Filed" with the acknowledgement; the bookkeepers are notified. |
| `rejected` | The year shows "Sent back" with the message; the bookkeepers are notified. It can be corrected, approved again and sent again. |

It can also carry the files Rev360 gave for the year (the acknowledgement, the assessment, the PRN page, the receipt) in
`documents`, kept in the business's Documents under CIT for that year. The format and limits are in
[flux-tax-returns.md](flux-tax-returns.md#6-files-flux-sends-back).

Counta answers `200 { ok: true, status, flux_status }` (with `documents: { stored, failed }` when files were sent), `401` for a bad signature, `400` for a malformed body and `422` when the year is unknown or was never approved.

## Who may do what

- Downloading the draft or approved template, attaching the audited accounts and editing a draft year: anyone who keeps the books.
- Approving, reopening and sending to Flux: the owner, or someone who keeps the books and approves adjustments.
- A year that Flux has submitted or filed cannot be reopened; an amended return is filed on Rev360 instead.

## Paying it

Once Rev360 gives the PRN for the return, Flux posts it to `/flux/payment` with `"tax": "cit"` and `accounting_year`, as for VAT and WHT
(docs/flux-tax-returns.md), with the `breakdown`: `tax` as the tax before WHT credit notes, `credit_applied` as the credit notes
Rev360 took off, and any penalty, interest or Flutterwave charge. Counta pays it from the tax wallet when each part agrees with the
approved return, or holds it for the owner. When it is paid, the credit notes Rev360 used come off WHT Credit Notes (1401).
