# Filing-only

Some businesses want Counta for one thing: their yearly income tax return. Filing-only is for them. Counta prepares the return (companies income tax for a company, personal income tax for a business name or partnership) from the business's bank statements, and the business pays a one-time fee for each year instead of a monthly plan. Nothing is read by AI and nothing is shown until the year is paid for.

## Who is on it

A person signing up answers one question first: what they need Counta for, running the business or only the yearly tax return. The second answer sets the new business up filing-only. The answer is kept in the browser until the profile is submitted, so it holds whether they talk to Martina or fill the steps in themselves, and the summary before submitting says so with a way to change it.

An owner or admin on the free plan can also switch later, in Settings, Subscription ("Only need the yearly income tax return?"). A business paying for a plan lets it end first (stop renewing it, then switch). An accounting firm switches a business it runs under full mandate from the accountant portal (Counta plans, "Switch to filing-only"), or ticks Filing only when it sets the business up; a business the firm only works with is switched by its owner.

Choosing any plan in Subscription ends filing-only and switches the rest of Counta back on. Years already paid for stay paid.

## The package

A filing-only business is on the Annual filing package. Like any plan it is made of modules, and TaxStreem changes it in the admin portal (Plans, Annual filing). It is never offered as a plan to choose and is never the default.

Four modules were added for parts of the app: Selling (sales, invoices, the till, customers, recurring invoices, price lists and the shop), Purchases (bills and vendors), Inventory, and VAT and WHT returns. Every other plan leaves them on, so nothing changes for anyone else. Annual filing leaves them off, with payments, bank feeds, Martina, phone calls and the supplier portal. It keeps AI reading, the books, the financial statements and the income tax return. Email and WhatsApp stay on so Counta's own alerts reach the business; with Selling off nothing goes to customers.

The menu leaves out what the package does not include, and a page opened by its address says it is not part of filing-only, with links to the Filing page and the plans. The business starts on its Filing page instead of Home, and the phone app sends it there too. TaxStreem can switch one of the four areas back on for a single business (Businesses, a business, switches).

## The Filing page

The Filing page lists the years the business can file: up to four accounting years that have ended, none before the first year Counta prepares (2023 accounts for companies income tax, 2024 for personal income tax) or before the business began. Each year is paid for and billed on its own. For each year it shows the period, the due date and these steps.

1. Bank accounts: each account the business used in the year, with its balance at the close of the day before the year starts (a new account is dated that day).
2. Statements: Excel, CSV or PDF from internet banking. A statement Counta can read by its columns goes in at once; its lines count towards the fee. A scanned PDF needs the AI reader, so before the year is paid for it is kept unread in the business's filing folder and counts 35 lines for each page.
3. Where the year starts (see below), shown when something has to be said about it.
4. Other documents (optional): receipts for equipment or vehicles, loan letters, last year's accounts and tax receipts, under Documents.
5. The fee: the statement lines dated in the year, the scanned pages at 35 lines a page, the count, the band it falls in and the price.

A year whose return was due and has not been filed is marked late: the tax office may charge a penalty for late filing and interest on tax paid late. Counta's figures cover the tax only.

## Where a year starts

Bank statements show money moving, never what the business owned and owed when the year began, so each year's start is settled before its return can be approved (`private.filing_opening`):

- The year before is done in Counta (paid for, or its return approved): its closing figures carry over, losses and tax values included, so that year's return is approved first.
- The business began during the year (its incorporation or start date), or its books were moved into Counta at the year start (Move your books): nothing more is needed.
- Otherwise the business says where the year starts (`public.filing_opening_save`), in one of three ways:
  - Last year's figures: stock, receivables, prepayments, payables, loans, capital, retained earnings, and property, plant and equipment by class or item with its depreciation so far. They can be read from last year's accounts (a PDF or photo, kept under Documents) once a year is paid for (the `atlas` function, `read_opening`), and are checked and changed before saving. They post one journal on the day before the year starts; each asset joins the register with its depreciation; what the figures leave over, after the bank balances, stays in equity as opening balances to be confirmed. Entered again, the earlier figures are taken back first, unless depreciation has run on their assets.
  - Nothing but the bank balances: the statements say the business had no other assets or liabilities at that date.
  - No figures from last year: the statements say the opening position is the bank balances and that other assets and liabilities, if any, are not included.

Losses brought forward and tax written-down values from last year's return go in the return itself, under Adjustments.

The year is opened the first time someone uploads or pays for it. Anyone who keeps the books can upload; the owner or an admin pays by card (Flutterwave's page the first time, then the saved card). A partner or manager of an accounting firm that works for the business can pay with the firm's card from the same page; for a business the firm runs under full mandate, only the firm pays. Coming back from Flutterwave's page, Counta asks Flutterwave about the payment before saying it is paid. A payment started and not confirmed shows on the page with a Check it button.

## Nothing before payment

Until a year is paid for:

- AI reading is off for a business that has paid for no year at all, so nothing it uploads is read by AI and no AI cost is incurred. The bookkeeper leaves its lines alone.
- After a first year is paid, the bookkeeper reads that year's lines only; lines dated in years not paid for wait, unasked.
- The year's return, its file and the financial statements answer with a note pointing to the Filing page, and the list of years shows no figures for it.

After payment, Counta reads the year's lines and builds the books. Lines it cannot explain come to the books inbox as questions; the financial statements and the return follow. Statements added later for a paid year are read at no extra charge.

## Scans after payment

A scan held before payment is read once the year is paid for (Filing page, Read it now): the AI reader reads it, the person checks the lines, and they go into the books. The real number of lines then replaces the scan's estimate. If the year's count lands in a dearer band, the business owes the difference (the dearer band's price less what was paid), and the people who manage the business are told. The year's return cannot be approved until the difference is paid; it is paid on the Filing page like the fee. More lines that keep the year in its band cost nothing.

## Prices

TaxStreem sets the prices in the admin portal (Filing fees), separately for companies income tax and personal income tax: up to ten bands, each up to a number of transactions, the last with no upper end. The migration sets both to ₦70,000 up to 5,000 transactions, ₦120,000 up to 10,000 and ₦200,000 above; change the personal income tax prices before businesses start paying. A year is charged at the prices when it is paid; a difference owed later uses the prices at that time. The same page shows how many businesses are filing-only, what was collected this month and in all, and the years paid for, newest first.

## VAT

A filing-only business whose sales pass ₦100 million in a year still has VAT turned on, as the law requires. The people told are pointed to a plan, because filing-only covers the yearly income tax return and not the monthly VAT returns.

## Where it lives

- Database: `supabase/migrations/20261128000100_filing_only.sql` (orgs.filing_only, plans.kind, filing_prices, filing_orders, filing_scans, the filing functions); tests in `supabase/tests/sql/17_filing_only.sql`. Where a year starts, personal income tax from 2024 and the late mark: `20261129000100_prior_years_assets.sql` (filing_orders.opening), tests in `18_prior_years_assets.sql`.
- Payments function: `filing_pay` and `filing_verify` (the fee goes through the plan payments, as subscription_charges of kind filing).
- Screens: `src/pages/filing/Filing.tsx`, `src/pages/filing/Opening.tsx`, the hold and scan modes of `src/pages/accounting/BankStatement.tsx`, `src/admin/pages/FilingFees.tsx`.

A company whose year is above the small company limits sees the year's audit on the Filing page once the year is paid for: it chooses a TaxStreem partner firm and pays it there, or names its own auditor. See [audits.md](audits.md).
