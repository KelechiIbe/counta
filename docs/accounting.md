# Counta posting reference

Counta keeps inventory as a sub-ledger of the TaxStreem books. Every stock event writes append-only movements and one balanced journal in the TaxStreem chart of accounts. This page lists the journal each event produces, the tables behind it and the open points the TaxStreem engineering team should settle when the two products merge.

## Chart of accounts

`public.accounts` holds the TaxStreem standard chart exactly as Accounting > Chart of accounts shows it: 393 accounts from 1000 ASSETS to 9007 Migration / Opening Balance Offset, transcribed from the web app on 16 October 2026. The same list is in `taxstreem-chart-of-accounts.csv` beside this file.

| Column | Meaning |
| --- | --- |
| `code` | TaxStreem account code |
| `name` | TaxStreem account name |
| `category` | Assets, Liabilities, Equity, Income, Cost of Sales, Expenses, Finance Costs & Taxation, Other Comprehensive Income, System & Control |
| `normal_balance` | `debit` or `credit`, as the TaxStreem screen shows it (contra accounts such as 1103, 1207, 1550-1574, 4131, 4132 and 5103 carry the opposite side) |
| `parent_code` | the header the account sits under |
| `is_group` | header row; `post_journal` refuses to post to it |
| `is_system` | 3999, 5400 and 9001-9007, marked "(System)" or listed under System & Control |
| `active` | false only for Counta's five interim accounts from before the remap (1310, 1315, 1420, 2010, 3100), which hold no lines |

## Posting roles

No posting function names an account code. Each asks for a role, and `private.acct(org, role)` returns the business's own choice from `posting_rules` or the TaxStreem default from `posting_roles`. `private.inv_acct(item)` returns the item's own `items.inventory_account` when it has one, otherwise the business's stock-on-hand account. `public.posting_map(org)` returns the resolved list for screens.

| Role | Default | Owner may choose |
| --- | --- | --- |
| `inventory` | 1203 Inventory - Finished Goods | 1201, 1202, 1203, 1205, 1206 |
| `goods_in_transit` | 1204 Goods in Transit | 1204 |
| `purchases` | 5101 Purchases - Local | 5101, 5102 |
| `input_vat` | 1402 VAT Input (Recoverable) | 1402, 1404 |
| `payables` | 2101 Trade Payables - Local | 2101, 2102, 2104, 2105, 9005 |
| `inventory_movement` | 5400 Inventory Movement (System) | 5400, 5401 |
| `stock_variance` | 5400 Inventory Movement (System) | 5400, 5401, 5209, 6805 |
| `stock_loss` | 6805 Inventory Write-Downs | 6805, 6803, 5209, 5400 |
| `opening_equity` | 3999 Opening Balance Equity (System) | 3999, 9007, 3005 |
| `landed_duty` | 5105 Import Duties & Landing Costs | 5104, 5105 |
| `landed_freight` | 5104 Carriage Inwards & Clearing | 5104, 5105, 6606 |
| `wip` | 1202 Inventory - Work in Progress | 1202 |
| `job_materials` | 5202 Direct Materials & Expenses (default for new jobs; each job keeps its own) | 5202, 5207, 5209, 5305, 5306, 6208, 6209, 6216, 1521 |
| `production_absorbed` | 5400 Inventory Movement (System) | 5400, 5401, 5201, 5304, 5306 |
| `nrv_writedown` | 6805 Inventory Write-Downs | 6805, 5400, 5209 |
| `nrv_allowance` | 1207 Allowance for Inventory Obsolescence | 1207 |

`public.set_posting_rule(org, role, code)` is owner only. Moving `inventory` or `goods_in_transit` posts a reclass journal (source type `reclass`) so the balance follows; other roles apply to new postings. `public.set_item_inventory_account(item, code)` moves one item and reclasses its stock at weighted average cost. A trigger blocks any other write to `items.inventory_account`.

## Journals by event

Codes below are the defaults. Amounts are net of VAT unless marked.

| Event | Function | Debit | Credit |
| --- | --- | --- | --- |
| Opening stock from a spreadsheet | `import_items` | 1203 stock value | 3999 |
| Vendor receipt | `post_receipt_internal` | 5101 net; 1402 input VAT (VAT-registered vendor, standard-rated lines, 7.5%) | 2101 gross |
| | | 1203 net, per inventory account | 5400 net |
| Landed cost (duty, clearing, haulage, agent) | `post_landed_cost` | 5105 duty and levies; 5104 the rest | 2101 total |
| | | 1203 share on stock still on hand | 5400 same amount |
| Sale or voice sale | `sale_internal` | 5400 qty × WAC | 1203 |
| Day close from the invoicing rail | `post_day_close` | 5400 | 1203, per inventory account |
| Transfer out | `create_transfer` | 1204 | 1203 at origin |
| Transfer received | `receive_transfer_internal` | 1203 at destination | 1204 |
| Count shortfall, loss reason (Breakage, Expired, Theft suspected, Other) | `approve_count_internal` | 6805 | 1203 |
| Count shortfall, Miscount or Unrecorded sale | `approve_count_internal` | 5400 | 1203 |
| Count surplus (stock found) | `approve_count_internal` | 1203 | 5400 |
| Batch quarantined or expired | `quarantine_internal` | 6805 | 1203 |
| Issue to a production run | `issue_materials` | 1202 qty × WAC | the material's inventory account |
| Issue to a job | `issue_materials` | the job's account (default 5202) | the material's inventory account |
| Return from a run or job | `issue_materials` with `p_return` | the material's inventory account | 1202 or the job's account, at the cost it left at |
| Labour and other costs added to a run | `complete_production` | 1202 | 5400 |
| Output of a production run | `complete_production` | the finished item's inventory account, the run's whole cost | 1202 |
| Run cancelled with value in progress | `close_job` | 6805 | 1202 |
| Opening stock from a migration | `import_inventory` with `as_of` | the item's inventory account, dated 23:59:59 on the go-live day | 3999 |
| Migration upload undone | `undo_import` | 3999 | the item's inventory account |
| Month-end close, allowance rises | `close_period` | 6805 | 1207 |
| Month-end close, allowance falls | `close_period` | 1207 | 6805 |
| Close reopened | `reopen_period` | the close's entry reversed | |
| Rule change or item move | `set_posting_rule`, `set_item_inventory_account` | new account | old account |
| Customer credit note for an amount | `credit_sale` | 4131 (goods) or the line's revenue account, net; 2201 the VAT inside | 1101 gross |
| Supplier credit note | `record_vendor_credit` | 2101 gross | the bill line's account net; 1402 the VAT inside (VAT-registered business) |
| | goods sent back | | 1203 at weighted average cost; 5103 Purchase Returns for the difference |
| | allowance on stock with nothing sent back | | 5103 Purchase Returns |
| Supplier credit used on another bill | `use_vendor_credit` | no journal (both sides in 2101); the bill's WHT falls with it | |
| Supplier refund of a credit | `refund_vendor_credit` | the bank account | 2101 |
| Tax charge | `post_tax_charge` | 7501 companies income tax, 7505 minimum tax top-up, 7502 development levy | 2208, 2209 |

Nothing posts into a closed period. A journal or movement dated on or before the last closed day, such as a phone sale that synced late, moves to the first open day with a note. See `month-end-close.md`.

Read across a period, the 5000 group gives cost of sales by the purchases method: 5101 purchases + 5104/5105 landed charges + 5400 inventory movement. 5400 nets to cost of goods sold less the stock still on hand, so it is negative in a month where stock builds up. Write-downs sit in 6805 under operating expenses.

## What Counta does not post

Counta leaves revenue, output VAT, receivables and payments to TaxStreem. Revenue belongs in the 4100 group (4107 Revenue - Wholesale & Retail Trade for a trading business), output VAT in 2201 and receivables in 1101. Paying a vendor should clear 2101. If TaxStreem's bank categorisation books the same payment to 5101 Purchases, the purchase is counted twice, once from the Counta receipt and once from the bank line. When the products merge, a bank debit that matches an open Counta payable should be matched to 2101 instead of being categorised as a purchase.

## Open points for the TaxStreem team

1. Whether 5400 Inventory Movement (System) and 3999 Opening Balance Equity (System) are postable accounts or headers in TaxStreem's own tables. Counta treats both as postable system accounts.
2. Whether TaxStreem keeps one chart per business or one shared chart with business-level custom accounts ("Add new account"). Counta keeps one shared chart and per-business posting rules.
3. Which account TaxStreem's invoicing posts revenue to for a trading business, so stock relief at invoice time can sit in the same journal or link to it.
4. How vendor bills and vendor payments are booked today, so 2101 is cleared once.
