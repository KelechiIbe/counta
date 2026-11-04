# Personal income tax: the hand-off to TaxStreem Flux

A business name or partnership has one personal income tax return per person (the proprietor, or each partner), each for the state that taxes that person (docs/personal-income-tax.md). Once the year is approved, Counta sends Flux the returns for the states Flux files; Flux files each one with the state revenue service and reports back on it. The business files the others itself and marks them filed in Counta.

Which states Flux files is in the rule book, `filing.flux_authorities` (to begin with `["SIRS:LA"]`, Lagos, as the PIT rule book s.13 says). TaxStreem adds a state by changing the rule book; nothing in the app changes.

Settings and signatures are the same as for CIT (docs/flux-cit-handoff.md): `FLUX_URL` and `FLUX_SECRET`, and on every request in both directions

```
x-counta-signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<raw body>" with FLUX_SECRET>
```

Until both are set, "Send to Flux" answers `not_configured` and tells the user to download the computation and file with the state.

## Counta to Flux: one approved return

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
  "computation": {
    "rows": [ { "id": "S1", "line": "Share of the business's assessable profit (40%)", "amount": 41760000, "basis": "40% of ₦104,400,000.00 (s.15(1)(b) and (3))" } ],
    "figures": { "business_income": 47760000, "total_income": 45260000, "reliefs": 11084600, "chargeable_income": 34175400, "tax": 7994096, "wht_credit": 2000000, "payable": 5994096 },
    "bands": [ { "label": "First ₦300,000", "from": 0, "to": 300000, "rate": 0.07, "slice": 300000, "tax": 21000 } ],
    "other_income": [ { "kind": "rent", "label": "Flat in Yaba", "amount": 3000000, "tax_deducted": 300000, "treatment": "taxable" } ]
  },
  "reliefs": { "pension": 2000000 },
  "business_computation": { "rows": [ { "id": "AP", "line": "Assessable profit / (loss) of the business", "amount": 104400000 } ], "figures": { "assessable": 104400000 } },
  "partners": [ { "person_id": "5f0c...", "name": "Ada Obi", "tin": "1234567-0001", "share_pct": 40, "role": "active", "authority": "SIRS:LA" } ],
  "files": { "statement_of_accounts": { "name": "statements.pdf", "url": "<signed link, 7 days>", "content_type": "application/pdf", "expires_in": 604800 } },
  "rulebook": { "id": "ng-pit-pita-legacy@1.1.0", "version": "1.1.0", "status": "approved" },
  "callback_url": "https://<project>.supabase.co/functions/v1/taxstreem/flux/pit-status"
}
```

- `regime` is `PITA` for 2025 accounts and `NTA_2025_PIT` from 2026 accounts.
- `computation.rows` is the person's computation line by line, as the screen and the downloaded file show it; `figures` has every amount by name (docs/personal-income-tax.md lists them).
- `partners` lists every partner, so the state has the particulars of the partnership and the shares (NTA 2025 s.15(5) and (7)). It is empty for a sole proprietor.
- `attested` is the taxpayer's attestation of the statement of accounts (NTAA 2025 s.13(2)(d)), given when the year was approved.
- The link expires after seven days. Copy the file on receipt.

Flux answers `2xx` with `{ "ok": true, "ref": "<Flux's reference>", "message": "optional" }`. Anything else, or no answer in 30 seconds, is shown on that person's return as not sent, and the user can send again. A return with Flux or filed is not sent again.

## Flux to Counta: where a return stands

`POST https://<project>.supabase.co/functions/v1/taxstreem/flux/pit-status`, signed the same way:

```json
{ "counta_org_id": "848b646b-...", "accounting_year": 2025, "person_id": "5f0c...", "status": "filed", "ref": "FLX-PIT-0042",
  "message": "Filed and assessed", "acknowledgement_ref": "LIRS-ACK-778812", "filed_at": "2026-03-20T09:00:00Z",
  "assessment": { "tax": 5994096, "assessment_number": "LIRS-DA-2026-..." }, "payment_url": "https://etax.lirs.net/..." }
```

| `status` | Effect in Counta |
| --- | --- |
| `processing` | The return shows "With Flux" with the message |
| `sent` | Flux has submitted it to the state. The year can no longer be reopened |
| `filed` | The return shows "Filed" with the acknowledgement; whoever files tax is notified. A filed return stays filed whatever comes after it |
| `rejected` | The return shows "Sent back" with the message; whoever files tax is notified. The business can mark it filed after fixing it with the state |

`payment_url` (https only) appears beside the return as "Pay". Counta does not pay personal income tax from the business's wallet: the tax is the partner's own.

It can also carry the files the state gave (the acknowledgement, the assessment, the payment receipt, a tax clearance certificate) in `documents`, kept in the business's Documents under Tax, PIT, for that year, in the same format and limits as for the other returns (docs/flux-tax-returns.md, section 6).

Counta answers `200 { ok: true, status, year_state }` (with `documents: { stored, failed }` when files were sent), `401` for a bad signature, `400` for a malformed body and `422` when the year is not approved or the person is not in it.

## Who may do what

- Sending to Flux, marking a return filed, approving and reopening: the owner, or someone with File tax.
- The year can be reopened until any of its returns is with Flux or filed; after that an amended return is filed with the state.
