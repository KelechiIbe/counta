# Counta · TaxStreem Inventory

Counta is the inventory module for TaxStreem. Inventory runs as a sub-ledger of the books: every stock movement posts a balanced journal, movements are append-only, and nothing reprices or orders without an owner tap. Staff capture stock on an installable phone app that keeps working offline.

## What is in here

The desktop app covers eight screens. **Overview** carries the Martina prompt bar, the KPI snapshot, a single needs-action queue and the movement ledger. **Items** lists every product with units shown in purchase and selling terms, an item drawer (stock, units and labels, batches, movements) and spreadsheet import. **Receive stock** reads typed and handwritten invoices with Gemini, asks the user to confirm any line under 85% confidence beside a crop of the photo, previews the journal against the TaxStreem chart of accounts and posts it. **Stock counts** lets the owner schedule blind counts and approve or reject variances with reasons. **Reorder** shows suggestions sized by velocity, lead time, safety days and seasonality, explainable vendor scores, FX timing advice and draft purchase orders that go out on the vendor's channel. **Pricing** handles price proposals (cost increase, below replacement cost, margin under threshold), landed cost allocation and the price change audit trail. **Insights** compares cash against stock, suggests dead stock markdowns and runs the FEFO batch table with quarantine. **Locations & staff** holds branch cards, transfers through goods in transit, the permission matrix, voice review and the activity log.

The phone app lives at `/m`. It has Today (queue, counts assigned to you, transfers arriving, items running low), barcode and QR scanning, voice sales in Pidgin, Yoruba, Hausa, Igbo or English, invoice photos, blind counts and a WhatsApp-style Martina chat. Sales, counts, transfer confirmations and invoice photos queue on the device when there is no data and post in order, with their original time and a client UUID so a retry never posts twice.

## Stack

React 18, TypeScript, Vite, React Router and TanStack Query on the front end, shipped as a PWA. Supabase provides Postgres with row level security, Auth, Storage, Edge Functions and pg_cron. Gemini reads invoices and voice notes and answers Martina's open questions through the `ai` edge function.

```
src/
  pages/inventory/   Overview, Items, Receive, Counts, Reorder, Pricing, Insights, Locations
  pages/             Assistant (Martina), Settings, Onboarding, auth
  mobile/            phone app, offline queue (IndexedDB), scan, sell, receive, count, chat
  lib/               domain rules, receiving, ledger formatting, chart of accounts, Martina, Supabase client
docs/                TaxStreem chart of accounts (CSV) and the posting reference
supabase/
  migrations/        schema, RLS, posting functions, sample business, storage, cron, hardening, TaxStreem chart
  functions/ai       Gemini: read_invoice, ask, chat, voice
  functions/fx       daily USD/NGN rate for FX timing advice
```

## Accounting model

Counta posts into the TaxStreem chart of accounts, the same 393 accounts as Accounting > Chart of accounts in the TaxStreem web app (`docs/taxstreem-chart-of-accounts.csv`). No posting function names an account code. Each asks for a posting role and `private.acct()` resolves it from the business's own rule in `posting_rules`, falling back to the TaxStreem default in `posting_roles`. An item can sit in its own inventory account through `items.inventory_account`.

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
| Opening stock | 3999 Opening Balance Equity (System) |
| Import duty | 5105 Import Duties & Landing Costs |
| Clearing and haulage | 5104 Carriage Inwards & Clearing |

Receipts follow the purchases method with perpetual stock: Dr 5101 net, Dr 1402 input VAT, Cr 2101 gross, then Dr 1203 and Cr 5400 for the stock that went onto the shelf. Sales relieve stock first-expiry-first-out with Dr 5400 / Cr 1203 at weighted average cost, so the cost of sales group reads purchases plus landed charges plus inventory movement. Transfers move value through 1204 until the receiving branch confirms. Landed cost posts duty to 5105 and other charges to 5104, and the share on stock still on hand moves into 1203 through 5400. Every posting runs inside a `security definer` function that checks the caller's permission first. Owners change the rules in Settings > Chart of accounts; moving the stock-on-hand or goods-in-transit role, or one item's account, posts a reclass journal so the balance follows. `docs/accounting.md` has the journal for every event.

## Roles

Templates exist for owner, manager, staff and cashier, with per-person overrides across eight permissions: record sales, receive stock, count stock, approve adjustments, edit costs and prices, approve POs, transfer stock and see margins. A database constraint enforces the hard rule that anyone who records sales can never edit prices or approve adjustments. Costs and margins are masked server-side for roles without see margins.

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

Apply the files in `supabase/migrations` in order, then deploy both edge functions with JWT verification on. Edge function secrets:

| Secret | Purpose |
| --- | --- |
| `GEMINI_API_KEY` | Required for invoice reading, voice entry and Martina's open answers. Without it the app still works; lines are typed by hand and Martina answers from rules. |
| `GEMINI_MODEL` | Optional model override (default `gemini-3.8-flash`, falling back to `gemini-flash-latest`). |

In Auth settings, set the Site URL and redirect URLs to the deployed domain. A nightly pg_cron job quarantines expired batches and refreshes price alerts.

## Sample business

A new account can open **Kelandellen Company Limited**, a two-branch Lagos supermarket (Surulere and Yaba) with 130 days of history: receipts from six vendors, handwritten invoices, transfers, counts, voice sales, batches near expiry and a run of Saturday cash shortfalls for the cash-versus-stock narrative. It can be removed from Settings.

## Deploying

Netlify builds with `npm run build` and publishes `dist`. `netlify.toml` holds the SPA redirect, cache headers and the camera and microphone permissions policy.
