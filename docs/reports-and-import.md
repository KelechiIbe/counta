# Reports, item fields and spreadsheet import

## Kind of business

Each business picks its trade at onboarding or later in Settings → Business. The choice sets the item fields the item form asks for, the categories and units it suggests, whether batches and expiry are on by default, and the columns in the import template. Changing it later keeps every value already saved; fields from the old trade stay on the item and still show in its Details tab.

| Kind of business | Extra item fields |
| --- | --- |
| Supermarket & general retail | Size, flavour or variant, wholesale price |
| Wholesale & distribution | Size, wholesale price, dealer price, minimum order quantity, units per pallet |
| Pharmacy & medical supplies | Generic name, strength, dosage form, pack presentation, prescription status, therapeutic class, storage. Batches on by default; new items start zero-rated |
| Restaurant, bakery & food service | Storage, shelf life, allergens, portion or yield, halal |
| Fashion, textiles & footwear | Size, colour, fabric, for (men, women, children), style code, season |
| Electronics, phones & appliances | Model number, key specification, colour, condition, warranty, SON/SONCAP number |
| Building materials & hardware | Grade, dimensions, weight per unit, finish, SON/MANCAP number |
| Agro-produce & farm inputs | Variety or grade, source state, moisture content, harvest season, active ingredient, storage. New items start zero-rated |
| Manufacturing & production | Specification, supplier material code, weight per unit, expected wastage, quality certificate, storage |
| Auto parts & lubricants | OEM part number, fitment, position, condition, oil grade, warranty |
| Beauty, cosmetics & salon | Shade, size, skin or hair type, hair length, product line |
| Oil & gas, industrial supplies | Part number, standard, material grade, size and pressure rating, serial tracking, criticality, hazard class, safety data sheet, MTC number |
| Other | Size or variant, colour, model |

Every trade also gets manufacturer, shelf or bin location, country of origin, HS code and maximum stock. The extra fields live in `items.attributes` (jsonb), so a new trade needs no migration: add it to `src/lib/industries.ts`.

VAT defaults follow the Nigeria Tax Act 2025: medicines, basic food and farm inputs are zero-rated (s.187), baby products and petroleum products are exempt (s.186). The default is only a starting point for a new item; the owner sets each item's treatment.

## Kind of item and its inventory account

| Kind of item | Needs a selling price | Inventory account |
| --- | --- | --- |
| Goods for resale | Yes | 1203 Inventory - Finished Goods |
| Finished goods | Yes | 1203 Inventory - Finished Goods |
| Raw material | No | 1201 Inventory - Raw Materials |
| Packaging material | No | 1201 Inventory - Raw Materials |
| Work in progress | No | 1202 Inventory - Work in Progress |
| Consumable / supplies | No | 1205 Consumables, Spares & Small Tools |
| Spare part / tool | No | 1205 Consumables, Spares & Small Tools |
| Chemicals & materials | No | 1206 Chemicals, Materials & Supplies |

Items that are not sold can have a price of zero; the phone app will not ring them up, and price alerts skip them. Changing an item's kind with stock on hand posts a reclass journal from the old account to the new one, the same way Settings → Chart of accounts does.

## Spreadsheet import

Inventory → Items → Upload (or Upload inventory on an empty Overview) takes .xlsx, .xls, .csv or .ods up to 15MB. A business coming from another system should use Move to Counta instead, which dates opening stock on a go-live day and checks it against the old system (`moving-to-counta.md`).

**Template.** The upload panel offers a template for any trade. It has the Items sheet with the trade's columns and an opening stock column per branch, an Example sheet filled with two or three realistic rows, a Guide sheet, and dropdowns (from a hidden Lists sheet) for category, kind of item, units, VAT and yes/no fields. Items → Export produces the same layout filled with the current item list, so a business can edit in Excel and upload it again.

**Any other sheet.** Counta finds the header row (titles and blank rows above it are skipped), picks the sheet that holds the items, and matches columns by name and synonym: "Desc" or "Description" becomes the product name, "CP/Ctn" is cost per carton, "SP" is the selling price, "Exp" is expiry, "S/N" is ignored. A column headed with a branch name ("Yaba", "Qty Surulere", "Ikeja stock") holds stock at that branch. Martina (Gemini, `ai` function `map_columns`) then reads the headers with a few sample rows and fills in what the name rules could not place. The user can change any match. Columns left unmatched are kept on the item as notes, so nothing in the sheet is lost. One-cell rows such as "BEVERAGES" become the category of the rows under them, and total rows are skipped.

When a sheet has no usable columns (one free-text line per product, such as "Indomie chicken 70g x40 - 12 ctns @ 9,600"), "Let Martina read each row instead" sends the lines to `extract_rows`, which returns name, units, quantity, cost and price per selling unit for each one.

Figures per carton, bag or case are converted to selling units using the pack size. Plain quantity, cost and price columns default to selling units, and the screen asks when that is unclear. Dates read as day first (06/03/2027 is 6 March), "06/2027" means the last day of June 2027, and Excel date serials are understood.

**What gets posted.** `public.import_inventory` checks the caller can edit prices, then works through up to 1,000 rows per call (the app sends 250 at a time).

- A new item is created with its units, kind, VAT, vendor (created by name if new), extra fields and notes. Its opening quantities post in one journal per upload: Dr the item's inventory account and Cr 3999 Opening Balance Equity (System), per branch, at the cost in the sheet. Rows with a batch number or expiry create batches.
- An existing item (matched by SKU, then barcode, then name) is updated in update mode or left alone in skip mode. Prices that change are written to the price change log. Quantities on existing items are never changed by an upload: that is what a stock count is for, so the upload reports how many rows carried stock for existing items.
- Goods for resale without a selling price, rows without a name, and duplicates in the same file are skipped with a reason. The done screen offers those rows as a CSV.

## Reports

Inventory → Reports. Every report runs in `public.inventory_report` from the same movements and journals as the books, filtered by period, branch, item and (for the ledger) account. Each one downloads as Excel (with totals as SUBTOTAL formulas, frozen headers and filters), CSV (UTF-8, safe against formula injection) or PDF. Reports that show cost need the See margins permission; for other people the cost columns are blank.

| Group | Report | Notes |
| --- | --- | --- |
| Stock | Stock valuation | Qty, unit cost, value at cost, retail value and margin per item and branch, as at a date, plus work in progress on open production runs. Checks the total against the inventory accounts in the ledger and shows the allowance for stock below cost and the carrying amount |
| Stock | Stock movement summary | Opening, received, produced, sold at cost, issued to jobs and runs, transfers, adjustments and closing, in quantity and value. Opening + movements = closing |
| Stock | Stock card (item ledger) | Every movement of an item with a running balance |
| Stock | Batches & expiry | Batch, NAFDAC number, expiry, days left, quantity left and status |
| Stock | Reorder list, Slow & dead stock, Item list | Same data as the Reorder and Insights screens; the item list includes the trade's extra fields |
| Books | Inventory general ledger | Opening balance, every journal line and running balance on inventory and goods-in-transit accounts, or any account Counta posts to |
| Books | Journal register | Every journal with its lines |
| Books | Trial balance (Counta accounts) | Opening, debits, credits and closing balance for each account Counta posts to |
| Purchases | Purchases register, Purchases by line, Input VAT schedule, Purchases by vendor, Purchase orders | The input VAT schedule lists vendor, invoice, net and VAT for the VAT return |
| Sales | Sales by item, Sales by day, Sales by staff | By item and by day: quantity, sales value, cost of sales and gross profit. By staff: how many sales each person recorded, how many by voice or offline, and their value |
| Production | Production runs and jobs | Every run or job open in the period: materials issued and returned, labour and other costs, output and cost per unit |
| Production | Stock issued to jobs | Each issue and return: run or job, branch, item, quantity, unit cost, value and who did it |
| Controls | Stock adjustments & write-offs, Transfers register, Price changes, Cash vs stock | Who did what, when, and the value |

**Month-end pack** builds one workbook with a contents sheet and the valuation, movement summary, inventory ledger, trial balance, purchases register, input VAT schedule, sales by item, production runs and jobs, adjustments and transfers for the chosen period.
