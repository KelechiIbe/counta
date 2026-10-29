# Counta · TaxStreem

Counta is TaxStreem's operating system for trading businesses: selling, payments, purchases, inventory and the books in one app. The books keep themselves. Agents post every sale, bill, bank line and stock movement to the TaxStreem chart of accounts, ask a person only when they are less than 80% sure, and produce IFRS financial statements, ledgers and CFO reports that export to Excel, PDF and CSV. People open Counta from their TaxStreem account with single sign-on.

## Selling, payments and the books

**Sell** has a till with shifts, floats and counts, split tender, returns and receipts by WhatsApp, email or a Bluetooth thermal printer; invoices, quotes and credit notes with a public page where the customer can pay; customers on credit with limits, statements and automatic payment reminders; price lists, phone and rep orders, deliveries and vans for distributors; and an online shop that follows live stock. See `docs/selling.md`.

**Payments** gives each business a wallet with its own account number and takes payment by bank transfer, payment link and QR code (no tap-to-pay). Flutterwave confirms payments through its webhook and Counta checks each one with Flutterwave before recording it; payments by any other channel are confirmed by a manager or the bookkeeper. Suppliers, refunds and withdrawals are paid from the wallet with WHT deducted. A partner integrating TaxStreem can plug in its own rail through the Counta Rail API. See `docs/payment-rails.md`.

**Purchases** holds bills from stock receipts, from Prism and typed in, with withholding tax by supplier category, approval and payment. Suppliers can send invoices on the business's own invoice link, or the business uploads them; Counta reads and checks each one (sums, VAT, Tax ID, address, bank account), adds the supplier when new, writes the bill and tells the supplier what to fix. See `docs/supplier-invoices.md`.

**Plans** are set by TaxStreem in the admin portal: modules (features and monthly limits), plans that include them, subscriptions paid by card or from the business wallet, and the cost of running Counta for each business. See `docs/plans-and-costs.md`.

**The admin portal's team**: admins and reviewers are added on Admin team. Someone with a Counta account gets the role and an email at once; anyone else gets an invitation that works for seven days. See `docs/admin-team.md`.

**Deleting a business**: TaxStreem's admins can remove a business for good, with its files and the logins of people in no other business, so it can sign up again. See `docs/deleting-a-business.md`.

**Accounting** is Atlas: the books inbox (the agents' questions), banking and reconciliation (PDF, Excel and CSV statements from any Nigerian bank, and bank feeds through Mono; see `docs/banking-and-feeds.md`), financial statements with notes, the tax computation and capital allowances (`docs/tax-computation.md`), ledgers and reports, the CFO pack with a written commentary, journals, the fixed asset register and the month-end close. See `docs/atlas.md`. When an item is added, the tax agent (Numens, with Gemini standing in for testing) sets its VAT treatment under the Nigeria Tax Act 2025, so each sale posts its output VAT correctly.

**Messages** go out by email through Resend and by WhatsApp Business with a link to pay. See `docs/messaging.md`. **Single sign-on** from TaxStreem and Prism bills are in `docs/taxstreem-sso.md`.

## Inventory

The inventory side covers twelve screens. **Overview** carries the Martina prompt bar, the KPI snapshot, a single needs-action queue and the movement ledger. **Items** lists every product with units shown in purchase and selling terms, an item drawer (stock, details, units and labels, batches, movements), Excel export, and upload from our template or any sheet the business already keeps. **Receive stock** reads typed and handwritten invoices with Gemini, asks the user to confirm any line under 85% confidence beside a crop of the photo, previews the journal against the TaxStreem chart of accounts and posts it. **Stock counts** lets the owner schedule blind counts and approve or reject variances with reasons. **Reorder** shows suggestions sized by velocity, lead time, safety days and seasonality, explainable vendor scores, FX timing advice and draft purchase orders that go out on the vendor's channel. **Pricing** handles price proposals (cost increase, below replacement cost, margin under threshold), landed cost allocation and the price change audit trail. **Production & jobs** issues raw materials, packaging and spares to production runs (cost held in work in progress until output is recorded) and to jobs (charged to the job's own account), with recipes, recipe-versus-actual variance and returns. **Insights** opens on Leak radar (shrink, count accuracy, cash short, what to count next and daily spot checks), then compares cash against stock, suggests dead stock markdowns and runs the FEFO batch table with quarantine. **Reports** has 24 stock, ledger, purchase, sales, production and control reports that download as Excel, CSV or PDF, plus a month-end pack in one workbook. **Month-end close** sets the allowance for stock worth less than cost and locks the period. **Move to Counta** brings items, opening stock, suppliers and past sales across from QuickBooks, Sage, Zoho, Odoo, Tally, Loyverse, Business Central, Square or a spreadsheet, dated a go-live day and reconciled to the old system. **Locations & staff** holds branch cards, transfers through goods in transit, the permission matrix, voice review and the activity log.

The item form and the import template follow the kind of business: a pharmacy records generic name, strength and dosage form with batches on; a fashion store records size, colour and fabric; an auto parts dealer records OEM part number and fitment; a manufacturer records raw materials, packaging and spares that are not for sale and sit in their own inventory accounts. Thirteen trades are set up. `docs/reports-and-import.md` covers the fields, how an uploaded sheet is read and matched, what the import posts, and every report.

Every desktop screen also fits a phone. Tables turn into cards under 760px, modals become bottom sheets, fields stay at 16px so iPhones do not zoom, and the layout respects the notch and home bar. On a phone, `/` opens the phone app; a person can switch to the full app from Today and Counta remembers the choice on that device.

Martina, the assistant, answers by voice or typing anywhere in Counta. On a spoken yes (or a tap on Approve) she records a sale, issues and sends an invoice, approves a supplier bill or reminds a customer who owes; the app checks the yes itself, and money going out is always opened on screen for a tap. With Hands-free switched on for a device, saying "Hello Martina" while Counta is open starts a conversation without touching the screen. See `docs/onboarding-and-voices.md`.

Martina can also phone people through ElevenLabs voice agents. From a purchase order she calls the vendor, reads out the order, confirms quantities and a delivery date, and writes the outcome back to the order. From Locations & staff an owner or manager can have her ring a team member about a count to finish, counts to approve, invoices to confirm, a transfer to receive or price checks to decide. See `docs/voice-and-push.md`.

Installed as an app, Counta sends push notifications when a count needs approval or comes back for a recount, an invoice needs checking, stock is on its way to a branch, a price check opens, or a phone call finishes. A banner asks to install (Chrome's install prompt on Android, Share then Add to Home Screen on iPhone) and then to turn on notifications.

The phone app lives at `/m`. It has Today (queue, counts and spot checks assigned to you, transfers arriving, items running low), barcode and QR scanning, voice sales in Pidgin, Yoruba, Hausa, Igbo or English, invoice photos, blind counts, issuing stock to a run or job, and a WhatsApp-style Martina chat. Sales, counts, issues, transfer confirmations and invoice photos queue on the device when there is no data and post in order, with their original time and a client UUID so a retry never posts twice.

More on the newer parts: `docs/production-and-jobs.md`, `docs/moving-to-counta.md` (including how opening and closing stock are worked out), `docs/month-end-close.md` and `docs/leak-radar.md`.

## Stack

React 18, TypeScript, Vite, React Router and TanStack Query on the front end, shipped as a PWA. Supabase provides Postgres with row level security, Auth, Storage, Edge Functions and pg_cron. Gemini reads invoices and voice notes and answers Martina's open questions through the `ai` edge function.

```
src/
  pages/home/        Home: the day's numbers from the books and what needs a person
  pages/sell/        Till, Sales and invoices, Customers, Orders and deliveries, Price lists, Online shop
  pages/payments/    Wallet, collections, payouts, reconciliations, payment settings
  pages/purchases/   Bills and vendors
  pages/accounting/  Books inbox, Banking, Financial statements, Ledgers and reports, CFO pack, Journals, Fixed assets, Period close
  pages/public/      Document and pay page (/p/:token), online shop (/shop/:slug), TaxStreem sign-on (/sso)
  pages/inventory/   Overview, Items, Receive, Counts, Reorder, Pricing, Production, Insights (Leak radar), Reports,
                     Month-end close, Move to Counta, Locations
  pages/             Assistant (Martina), Settings, Onboarding, auth
  mobile/            phone app, offline queue (IndexedDB), scan, sell, receive, count, issue to a job, chat
  lib/               domain rules, receiving, ledger formatting, chart of accounts, Martina, Supabase client,
                     industries (item fields per trade), sheet (reading and matching uploads), migrate (source system
                     presets), jobs, reports, exporters
docs/                Atlas, selling, payment rails, messaging, TaxStreem sign-on, TaxStreem chart of accounts (CSV),
                     the posting reference, voice and push, reports and import, production and jobs, moving to Counta,
                     month-end close, Leak radar
supabase/
  migrations/        schema, RLS, posting functions, sample business, storage, cron, hardening, TaxStreem chart,
                     production and jobs, period close, migration, Leak radar
  functions/ai       Gemini: read_invoice, ask, chat, voice, map_columns and extract_rows for uploads; the tax agent
                     (VAT on items, through Numens when it is configured)
  functions/atlas    the bookkeeper (bank lines) and the CFO commentary
  functions/payments wallets, collections, payouts, Flutterwave and partner-rail webhooks, polling, nightly reconciliation
  functions/messaging email (Resend) and WhatsApp Business delivery, Meta webhook
  functions/taxstreem single sign-on from TaxStreem and Prism bills
  functions/fx       daily USD/NGN rate for FX timing advice
  functions/voice    ElevenLabs outbound calls: vendor orders and staff reminders
  functions/push     Web Push delivery for the notifications table
public/push-sw.js    push and notification-click handlers, imported into the Workbox service worker
```

## Accounting model

Counta posts into the TaxStreem chart of accounts, the same 393 accounts as Accounting > Chart of accounts in the TaxStreem web app (`docs/taxstreem-chart-of-accounts.csv`). No posting function names an account code. Each asks for a posting role and `private.acct()` resolves it from the business's own rule in `posting_rules`, falling back to the TaxStreem default in `posting_roles`. An item can sit in its own inventory account through `items.inventory_account`. Its kind sets that account: raw materials and packaging go to 1201, work in progress to 1202, consumables and spares to 1205, chemicals to 1206, and goods for sale stay on the stock-on-hand role.

| Role | Default account |
| --- | --- |
| Stock on hand | 1203 Inventory - Finished Goods |
| Stock moving between branches | 1204 Goods in Transit |
| Stock bought | 5101 Purchases - Local |
| VAT on purchases | 1402 VAT Input (Recoverable) |
| Owed to vendors | 2101 Trade Payables - Local |
| Stock in and out | 5400 Inventory Movement (System) |
| Count differences (miscount, unrecorded sale, stock found) | 5400 Inventory Movement (System) |
| Stock lost or written off (breakage, expiry, theft, quarantine) | 6805 Inventory Write-Downs |
| Opening stock (including stock brought in by an upload) | 3999 Opening Balance Equity (System) |
| Import duty | 5105 Import Duties & Landing Costs |
| Clearing and haulage | 5104 Carriage Inwards & Clearing |
| Materials in an open production run | 1202 Inventory - Work in Progress |
| Stock issued to a job, repair or project | 5202 Direct Materials & Expenses (each job may choose 5207, 5209, 5305, 5306, 6208, 6209, 6216 or 1521) |
| Labour and overheads taken into a run's output | 5400 Inventory Movement (System) |
| Month-end write-down to net realisable value | 6805 Inventory Write-Downs |
| Allowance for stock below cost | 1207 Allowance for Inventory Obsolescence |

Receipts follow the purchases method with perpetual stock: Dr 5101 net, Dr 1402 input VAT, Cr 2101 gross, then Dr 1203 and Cr 5400 for the stock that went onto the shelf. Sales relieve stock first-expiry-first-out with Dr 5400 / Cr 1203 at weighted average cost, so the cost of sales group reads purchases plus landed charges plus inventory movement. Transfers move value through 1204 until the receiving branch confirms. Landed cost posts duty to 5105 and other charges to 5104, and the share on stock still on hand moves into 1203 through 5400. Issues to a production run move materials into 1202 and its output moves the run's whole cost into the finished item; issues to a job go straight to the job's account. Month-end close posts the change in the allowance for stock below cost (Dr 6805 / Cr 1207) and locks the period. Every posting runs inside a `security definer` function that checks the caller's permission first. Owners change the rules in Settings > Chart of accounts; moving the stock-on-hand or goods-in-transit role, or one item's account, posts a reclass journal so the balance follows. `docs/accounting.md` has the journal for every event.

## Roles

Templates exist for owner, manager, accountant, staff and cashier, with per-person overrides across eleven permissions: record sales, receive stock, count stock, approve adjustments, edit costs and prices, approve POs, transfer stock, issue to jobs, see margins, keep the books and make payments. A database constraint enforces the hard rule that anyone who records sales can never edit prices or approve adjustments. Costs and margins are masked server-side for roles without see margins.

## Running it

```bash
npm install
npm run dev       # http://localhost:5173
npm run build     # type-checks, then builds to dist/
```

The Supabase URL and publishable key default to the TaxStreem Counta project, so no `.env` is needed. To point at another project, copy `.env.example` to `.env`.

| Variable | Purpose |
| --- | --- |
| `VITE_SUPABASE_URL` | Supabase project URL |
| `VITE_SUPABASE_ANON_KEY` | Supabase publishable key |
| `VITE_MAIN_APP_URL` | Where the non-inventory sidebar links open (defaults to app.taxstreem.com) |
| `VITE_SUPPORT_URL` | Target of the Get Help button |

## Supabase setup

Apply the files in `supabase/migrations` in order, then deploy the edge functions. `fx` verifies the JWT. `ai`, `atlas`, `payments`, `messaging`, `taxstreem`, `voice` and `push` check the caller themselves (a signed-in user, the database's hook secret, a signed webhook or a signed TaxStreem token) and are deployed with JWT verification off.

Keys can be Edge Function secrets or rows in Supabase Vault with the same name. The functions read the environment first and fall back to Vault through `public.app_secret()`, which only the service role can call. Store a Vault key with `select vault.create_secret('<value>', '<NAME>');`.

| Secret | Purpose |
| --- | --- |
| `GOOGLE_APPLICATION_CREDENTIALS_JSON` | Gemini on Vertex AI, signed in with Application Default Credentials: the whole JSON of a service account key (or of the file `gcloud auth application-default login` writes), as text or base64. The account needs the Vertex AI User role. Used for invoice reading, voice entry, Martina's open answers, VAT decisions and the bookkeeper. Edge Function secret only. See [docs/gemini-vertex.md](docs/gemini-vertex.md). |
| `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION` | Where Vertex AI runs. Default: the credential's project and `us-central1`. Counta uses `infrastructure-staging-477918` in `us-central1`. |
| `GEMINI_API_KEY` | Used only when no ADC credential is set. Without either, the app still works; lines are typed by hand and Martina answers from rules. |
| `GEMINI_MODEL` | Optional model override (default `gemini-3.8-flash`, falling back through 3.6, 3.5 and, on Vertex AI, `gemini-2.5-flash` when a model is busy or not offered in the region). |
| `ELEVENLABS_API_KEY` | Phone calls. Needs access to Agents and phone numbers. |
| `ELEVENLABS_PHONE_NUMBER_ID` | Optional. Which ElevenLabs number to ring from when the account has several. |
| `ELEVENLABS_VOICE_ID` | Optional. Voice for both agents. |
| `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` | Web Push keys. Generated by the `push` function on first use and saved to Vault. |
| `VAPID_SUBJECT` | Optional contact URL or mailto for push services (defaults to the site URL). |
| `PUSH_HOOK_SECRET` | Generated by the migration. The database sends it with each call to the functions. |
| `FLW_SECRET_KEY`, `FLW_PUBLIC_KEY`, `FLW_WEBHOOK_HASH` | Flutterwave (`docs/payment-rails.md`) |
| `FLW_MERCHANT_ID` | TaxStreem's Flutterwave merchant ID, where plans paid from a business wallet go. Set in the admin portal (`docs/plans-and-costs.md`) |
| `RESEND_API_KEY`, `RESEND_FROM` | Email (`docs/messaging.md`) |
| `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_BUSINESS_ACCOUNT_ID`, `WHATSAPP_APP_SECRET`, `WHATSAPP_VERIFY_TOKEN` | WhatsApp Business (`docs/messaging.md`) |
| `TAXSTREEM_SSO_SECRET` | Single sign-on and Prism (`docs/taxstreem-sso.md`) |
| `NUMENS_API_URL`, `NUMENS_API_KEY` | Optional. Numens answers VAT questions instead of Gemini (`docs/atlas.md`) |

In Auth settings, set the Site URL and redirect URLs to the deployed domain. pg_cron runs the agents every three minutes, re-checks payments every five, retries messages every ten, sends payment reminders each morning, reconciles wallets nightly, quarantines expired batches and refreshes price alerts.

## Sample business

A new account can open **Kelandellen Company Limited**, a two-branch Lagos supermarket (Surulere and Yaba) with 130 days of history: receipts from six vendors, handwritten invoices, transfers, counts, voice sales, batches near expiry and a run of Saturday cash shortfalls for the cash-versus-stock narrative. It can be removed from Settings.

## Deploying

Netlify builds with `npm run build` and publishes `dist`. `netlify.toml` holds the SPA redirect, cache headers and the camera and microphone permissions policy.
