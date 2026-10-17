# Month-end close

Inventory → Month-end close freezes a period's closing stock and carries stock at the lower of cost and net realisable value, as IAS 2 and IFRS for SMEs section 13 require. Anyone with See margins can preview a close. Only the owner closes or reopens.

## The preview

The owner picks a day to close up to (usually the last day of last month; any day before today after the last close works) and sets the policy once with the accountant:

| Setting | Default | Meaning |
| --- | --- | --- |
| Selling costs, % of price | 0 | Delivery, commission and the like, taken off the selling price before comparing it with cost |
| No sales 181–365 days | 25% | Share of value set aside for items with no sale or use for six months to a year |
| No sales over 365 days | 50% | The same for over a year |
| Expired batches | 100% | Share of the value of expired batches set aside |

For every item and branch with stock on that day, `private.period_lines` works out quantity, weighted average cost and value, then three tests, and the allowance is the largest of them:

- sells below cost: quantity × (unit cost − price × (1 − selling cost %)), when that is positive
- expired batches: expired quantity × unit cost × the expired %
- no sales for long: value × the ageing % (days since the last sale, issue or other outward movement)

The preview shows stock at cost (including work in progress on open runs and stock in transit), the inventory accounts in the ledger and whether they agree, the allowance now and after the close, the carrying amount, and a checklist of things still open: invoices waiting to be posted, counts waiting for approval or still being counted, transfers in transit, production runs open, voice sales to review. The owner can change any line's allowance before closing; the change is kept on the line.

## Closing

`close_period(org, period_end, policy, overrides, note)` saves a `period_closes` row and one `period_close_lines` row per item and branch, then posts one journal dated the period end for the change in the allowance:

| Allowance | Debit | Credit |
| --- | --- | --- |
| Rises | 6805 Inventory Write-Downs (role `nrv_writedown`) | 1207 Allowance for Inventory Obsolescence (role `nrv_allowance`) |
| Falls | 1207 | 6805 |

Stock at cost and its average costs do not change; the allowance sits beside them. The Stock valuation report shows "Less allowance for stock below cost … carrying amount …" under the total. 6805 may be swapped for 5400 or 5209 in Settings → Chart of accounts.

## The lock

From then on nothing can post into the closed period. Two triggers (`journals_closed_period`, `movements_closed_period`) catch any journal or movement dated on or before the closed day, such as a sale queued on a phone that was offline over month end, and move it to the first open day with a note ("Recorded 30 Sep 2026 in a closed month"; the journal memo says it was dated earlier and posted after the close). The sale is kept and the closed figures stay exactly as they were. A go-live date for a migration cannot fall in a closed period.

## Reopening

`reopen_period(org, reason)` reopens only the latest close. It reverses that close's allowance entry, marks the close reopened with the reason, and lets postings land in the period again. Close it again when the correction is in.

## History

Closed months list stock at cost, allowance, carrying amount, the journal and who closed it. **Snapshot** downloads the frozen lines as Excel: every item and branch with quantity, unit cost, value, net realisable value, reason and allowance as at that close.

| Function | Permission |
| --- | --- |
| `period_close_preview(org, period_end, policy)` | See margins |
| `close_period(org, period_end, policy, overrides, note)` | Owner |
| `reopen_period(org, reason)` | Owner |
| `get_period_closes(org)`, `get_period_close_lines(close)` | See margins |
