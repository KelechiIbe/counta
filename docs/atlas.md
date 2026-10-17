# Atlas: books that keep themselves

Atlas is the accounting side of Counta. Agents read every bank line, sale, bill, payout and stock movement and post them to the TaxStreem chart of accounts. A person only sees the entries the agents were not sure about. This page explains how the agents decide, where their work lands and which reports come out of the ledger. The journal each stock event writes is in [accounting.md](accounting.md).

## The agents

| Agent | Works on | Where it runs |
| --- | --- | --- |
| Bookkeeper | Unmatched bank and wallet lines | `atlas` edge function (`classify_all` every three minutes from pg_cron, `run` from the Books inbox) |
| Tax agent | The VAT treatment of every item, when it is added or renamed | `ai` edge function (`vat_classify_pending` from pg_cron, `vat_classify_item` from the item form) |
| Payables | Bills from stock receipts, Prism and typed entry, with WHT worked out per supplier | Database (`write_bill`, `approve_bill`, `pay_bill`) |
| Close | The month-end checklist, accruals, depreciation, the IAS 2 stock review and ECL | Database (`close_checklist`, `close_books`, `run_ecl`, `close_year`) |
| Finance director | A written commentary on the period's numbers | `atlas` edge function (`commentary`); it reads figures and never posts |

Every agent run is logged in `agent_runs` with what it looked at, what it posted and what it asked.

## The 80% rule

An agent posts on its own only when its confidence is at least the business's threshold, which can never be set below 80% (`orgs.auto_post_threshold`, check constraint `orgs_auto_post_threshold_check`). The owner can raise it in Settings, Books and tax.

Anything less goes to account 9001 (Suspense) and waits in the Books inbox as an `ai_proposals` row with the agent's question. The person's answer moves the amount out of suspense with a reversing pair, and when they tick "remember this", the answer becomes a rule in `entity_rules` that the bookkeeper applies first next time. Tax decisions follow the same rule: below the threshold the item keeps its current VAT treatment and the tax agent's suggestion waits for a person.

## How the bookkeeper decides

The order is fixed, cheapest and safest first:

1. Match. A bank line that matches an open invoice, a bill payment, a payout, a sweep or a transfer between the business's own accounts is settled against it. No model is involved.
2. Rules. A payee the business has already explained (`entity_rules`) is posted the way the person said.
3. Model. Gemini (for now) gets up to 40 lines at a time with the chart of accounts, the payee's history and the business's settings, and must answer with an account and a confidence for each line.
4. Calibration. `calibrate()` in `atlas/bookkeeper.ts` lowers the model's confidence where experience says it is often wrong:

| Situation | Confidence capped at |
| --- | --- |
| The model picked a catch-all account (sundry, other, miscellaneous) | 50% |
| Money in posted to revenue when the business rings every sale up in Counta | 50% |
| Money out posted to an income account | 40% |
| Money in posted to an expense account | 70% |
| Any equity account (capital, drawings, dividends) | 60% |
| A payment to a private individual, the owner or an unknown name | 60% |
| An account that goes against how this payee was posted before | 75% |
| An account that does not exist in the chart | never posts; becomes a question |

A line the model skipped still gets a question, so nothing is lost. If the model fails, the remaining lines go to suspense with a question each and the run is logged with the error.

## Posting rules

All postings go through `private.post_entry`, which checks that debits equal credits, that every account is postable, and that the date is in an open period (a date in a closed month moves to the first open day and says so in the memo). Journals cannot be edited or deleted. A mistake is put right with `reverse_journal`, which posts the mirror entry and links the two. Manual journals (`post_manual_journal`) need the Keep the books permission and carry the poster, the approver and any evidence.

Journals from agents carry `origin` and `ai_confidence`, so the general ledger and the journal register show which entries an agent made and how sure it was.

## VAT on items

When an item is added, the tax agent reads its name, category, brand and description and sets its VAT treatment under the Nigeria Tax Act 2025: standard rate 7.5%, zero-rated under section 187 (basic food items, medical and pharmaceutical products, educational books and materials, fertiliser and other farm inputs, and the rest of that list) or exempt under section 186 (baby products, locally made sanitary pads, petroleum products, renewable energy equipment, transport, land and buildings and the rest of that list). The answer records the source, the reason, the section of the Act and the confidence in `items.vat_basis`.

Numens powers this in production. Until `NUMENS_API_URL` and `NUMENS_API_KEY` are set, Gemini answers with the same prompt and the item shows "Numens (testing model)". The Numens contract Counta expects:

```
POST {NUMENS_API_URL}/vat/classify
Authorization: Bearer {NUMENS_API_KEY}
{ "country": "NG", "law": "NTA2025", "items": [{ "id", "name", "category", "brand", "description", "kind", "unit", "business_trade" }] }

200 { "model": "numens-…", "results": [{ "id", "treatment": "standard" | "zero" | "exempt", "confidence": 0.0-1.0, "reason": "…", "law": "NTA 2025 s.187(…)" }] }
```

A person can change the treatment on the item (Inventory, Items, Details). That choice is final: renaming the item no longer sends it back to the agent. "Ask Numens again" clears the manual choice and asks once more.

When the item is sold, its treatment decides the VAT on the invoice line, and the VAT is credited to 2201 (Output VAT).

## Reconciliation

Bank statements come in as CSV or Excel (Accounting, Banking). Counta maps the columns, skips lines it already holds (each line carries a fingerprint) and takes the statement's closing balance as the account's anchor. Each account is reconciled to a statement balance at a date, listing what is in the books but not on the statement and the reverse. The difference must be zero before the month can close.

The Flutterwave wallet is reconciled every night at 00:40 by the `payments` function: it reads the wallet statement from Flutterwave, records any credit the books do not have, and compares the wallet balance with the wallet's ledger account (under 1014). A difference raises a question in the Books inbox.

## Period close

Accounting, Period close runs `close_checklist` for the month and shows each step:

| Step | Stops the close |
| --- | --- |
| Bank and wallet accounts reconciled to the month end | yes |
| Suspense and clearing accounts are empty | yes |
| Questions in the books inbox answered | yes |
| Transfers and card payments confirmed against the bank | yes |
| Till sales waiting for payment completed or cancelled | yes |
| New assets confirmed in the register | yes |
| VAT in the ledger agrees to invoices and bills | yes |
| Bills for the month approved (the rest are accrued at close) | no |
| Customer and vendor ledgers agree to receivables and payables | no |
| Expected credit losses on receivables reviewed (IFRS 9) | no |

The owner can waive a blocking step with a reason of at least ten characters; the waiver is kept with their name. The accountant role prepares everything and the owner closes. Closing accrues draft bills, runs depreciation (IAS 16, straight line, monthly), closes stock with the IAS 2 net realisable value review, and locks the month. `close_year` moves the year's profit or loss to retained earnings once all twelve months are closed.

## Reports

Every report comes from `accounting_report(org, report, from, to, options)` and exports to Excel, PDF and CSV. Statements print with brackets for negatives, single rules above subtotals and double rules under totals.

| Group | Report | Notes |
| --- | --- | --- |
| Statements | Statement of financial position | IAS 1. Checks that it casts. Compared with the end of the previous financial year (IAS 1.38; IAS 34.20 for part-years). |
| | Statement of profit or loss | By function, with other comprehensive income |
| | Statement of changes in equity | Opening equity to closing equity by component |
| | Statement of cash flows | IAS 7, indirect method for operating activities; ties to the cash in the books |
| | Notes to the financial statements | General information, basis of preparation, policies, and a note behind each line |
| Ledgers | Trial balance, general ledger, journal register, chart of accounts, fixed asset register | |
| Customers and vendors | Customer and vendor ledgers, receivables and payables ageing | Each ledger is checked against its control account |
| Analysis | Management accounts by month, financial ratios, twelve-month trends, budget against actual, 13-week cash forecast, sales analysis | The CFO pack puts these together with a written commentary |
| Tax | VAT return, withholding tax schedule | |

The full set (statements and notes) exports as one workbook or one PDF with a cover page from Accounting, Financial statements. Figures for a month that is not closed carry a draft note.

### Presentation choices

- The statements say whether they follow IFRS Accounting Standards or IFRS for SMEs (Settings, Books and tax). Note 2 names the framework.
- An overdrawn bank account is a current liability ("Bank overdrafts"). It is not set off against cash in other accounts (IAS 32.42). The statement of cash flows counts overdrafts repayable on demand within cash (IAS 7.8), and note 11 reconciles the two.
- Customers in credit are shown as contract liabilities, and suppliers in debit as receivables.
- Profit not yet closed to retained earnings is shown within retained earnings and named in note 12.
- Opening balances that were never confirmed stay visible as "Opening balances to be confirmed" in equity until someone confirms them.

## Settings that change the books

| Setting | Where | Effect |
| --- | --- | --- |
| Reporting framework | Settings, Books and tax | Wording in note 2 and on the statements |
| Financial year start | Settings, Books and tax | Year to date, year-end close and comparatives |
| Auto-post threshold (80% or more) | Settings, Books and tax | When agents post without asking |
| Sales not rung up in Counta | Settings, Books and tax | Lets the bookkeeper treat unexplained money in as sales |
| Capitalisation threshold | Settings, Books and tax | Below it, equipment is expensed |
| Small company WHT exemption | Settings, Books and tax | No WHT on bills under ₦2m from suppliers with a TIN |
| Prices include VAT, invoice terms, payment details | Settings, Books and tax | Invoices and receipts |

## Secrets

| Name | Used by | Notes |
| --- | --- | --- |
| `GEMINI_API_KEY` | `atlas`, `ai` | Already in Vault |
| `NUMENS_API_URL`, `NUMENS_API_KEY` | `ai` | When set, Numens answers VAT questions instead of Gemini |
| `PUSH_HOOK_SECRET` | all functions | Already set; pg_cron and pg_net send it as `x-counta-hook` |
