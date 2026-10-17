# Moving to Counta, and how opening and closing stock are worked out

## Move to Counta

Inventory → Move to Counta (also linked from Items and the empty Overview while a business has fewer than five items) walks a business across from the system it uses now. The page needs Edit costs and prices; undoing an upload needs the owner.

1. **Where are you coming from?** QuickBooks Online, QuickBooks Desktop, Sage 50 / Sage Pastel, Zoho Inventory or Zoho Books, Odoo, Tally Prime or ERP 9, Loyverse, Microsoft Dynamics 365 Business Central, Square, or a spreadsheet or ledger book. Choosing one shows where its item, supplier and sales exports live and loads a column preset for its export, so "Quantity On Hand", "Purchase Cost" and "Sales Price / Rate" in a QuickBooks file land on the right fields without guessing. Presets are in `src/lib/migrate.ts`.
2. **Get your data out.** Short instructions per system, plus the one report to keep: the old system's inventory valuation as at the go-live date.
3. **Pick your go-live date.** Opening stock is dated the close of business that day, and the person can type the old system's valuation total. The date cannot be in the future or in a closed month.
4. **Items and opening stock.** The usual upload panel (template or any sheet, column matching, Martina for messy files), told about the migration: every row it posts is dated 23:59:59 local time on the go-live date, so a business that keeps selling in Counta the next morning opens on exactly the right figure. Large files go up in chunks under one upload id. Services, non-inventory lines, bundles, discounts and charges in an accounting export are left out with the reason "Service or non-stock line", because they are not stock. When all the uploads standing for that go-live date are in, the page compares their opening value with the old system's total and says whether they agree to the naira, and if not, the usual reasons (rows left out, items with no cost, quantities read in cartons).
5. **Suppliers** (optional). Name, phone, email, address, TIN, VAT registration, credit days, delivery days and notes. Suppliers already in Counta are updated rather than duplicated.
6. **Past sales** (optional). Three to twelve months of sales per item, either dated lines (a "sales by item detail" export, where each product may be a heading row above its lines) or totals for a period (a "sales by item summary", where the person says which dates it covers). Lines are matched to items by SKU, then barcode, then name. History only fills the time before the business's first sale in Counta and is cut off the day before it, so nothing is counted twice. It never touches stock or the books; it feeds reorder suggestions, slow-stock flags and forecasts from day one.

The Uploads list shows every upload with who made it and when. **Undo** reverses an items upload's opening stock journals (dated like the originals) and archives the items it created, as long as none of them has been sold, received, counted or moved since. A supplier upload removes the suppliers it added unless an item, invoice or order now uses them. A past-sales upload deletes its history rows. Updates an upload made to existing items stay.

### What posts

Opening stock posts per upload and branch: Dr the item's inventory account (1203 for goods for sale, 1201, 1205 or 1206 for other kinds) / Cr 3999 Opening Balance Equity (System), at the cost in the sheet. When the sheet has a value column but no unit cost, cost is value ÷ quantity. Quantities on items that already exist are never changed by an upload; that is a stock count's job, and the preview says how many rows were left out for that reason.

### Tables and functions

| Object | Purpose |
| --- | --- |
| `imports` | One row per upload: kind (items, vendors, sales_history), source system, file, go-live date, journals, items and suppliers created, row counts, opening value, the old system's figure, period covered, status (posted or reversed) |
| `sales_history` | item, branch, day_from, day_to, qty, revenue, import id. `get_inventory` adds it to velocity over the days it overlaps |
| `import_inventory(org, rows, options)` | Gains `as_of`, `import_id`, `source` and `expected_value` options |
| `import_vendors(org, rows, options)` | Suppliers |
| `import_sales_history(org, rows, options)` | Past sales, cut off before the first sale in Counta; an upload that brings nothing in leaves no record |
| `undo_import(import)` | Owner only |
| `get_imports(org)` | Uploads with totals by branch; needs See margins or Edit costs and prices |

## Opening and closing stock

Counta keeps stock perpetually at weighted average cost. Every receipt, sale, transfer, count, issue, output and write-off is a movement with a quantity and a value, and each one posts a balanced journal. Closing stock for any day is therefore a sum, not an estimate:

closing stock = opening stock + receipts at cost (with landed charges) + production output + transfers in − cost of sales − stock issued to jobs and runs − transfers out ± count adjustments − write-offs

The opening stock of a period is the closing stock of the day before it. The Stock movement summary report shows each of those columns per item, and the Stock valuation report lists quantity × average cost per item and branch as at any date, adds work in progress on open production runs, and checks the total against the inventory accounts in the ledger. The two always agree because both are built from the same journals.

On the first day, opening stock comes from the migration upload above, dated the go-live date and reconciled to the old system's valuation.

### What month-end close adds

A perpetual figure can still be wrong in two ways. Someone can post into a month the accountant has already reported, and stock can be worth less than it cost. Month-end close fixes both; see `docs/month-end-close.md`. After a close, next month opens on exactly the closed figure and nothing can move it.
