# Counta · TaxStreem Inventory

Counta is the inventory module for TaxStreem. Inventory runs as a sub-ledger of the books: every stock movement posts a balanced journal, movements are append-only, and nothing reprices or orders without an owner tap. Staff capture stock on an installable phone app that keeps working offline.

## What is in here

The desktop app covers eight screens. **Overview** carries the Martina prompt bar, the KPI snapshot, a single needs-action queue and the movement ledger. **Items** lists every product with units shown in purchase and selling terms, an item drawer (stock, units and labels, batches, movements) and spreadsheet import. **Receive stock** reads typed and handwritten invoices with Gemini, asks the user to confirm any line under 85% confidence beside a crop of the photo, previews the journal (Dr 1310, Dr 1420 where VAT applies, Cr 2010) and posts it. **Stock counts** lets the owner schedule blind counts and approve or reject variances with reasons. **Reorder** shows suggestions sized by velocity, lead time, safety days and seasonality, explainable vendor scores, FX timing advice and draft purchase orders that go out on the vendor's channel. **Pricing** handles price proposals (cost increase, below replacement cost, margin under threshold), landed cost allocation and the price change audit trail. **Insights** compares cash against stock, suggests dead stock markdowns and runs the FEFO batch table with quarantine. **Locations & staff** holds branch cards, transfers through goods in transit, the permission matrix, voice review and the activity log.

The phone app lives at `/m`. It has Today (queue, counts assigned to you, transfers arriving, items running low), barcode and QR scanning, voice sales in Pidgin, Yoruba, Hausa, Igbo or English, invoice photos, blind counts and a WhatsApp-style Martina chat. Sales, counts, transfer confirmations and invoice photos queue on the device when there is no data and post in order, with their original time and a client UUID so a retry never posts twice.

## Stack

React 18, TypeScript, Vite, React Router and TanStack Query on the front end, shipped as a PWA. Supabase provides Postgres with row level security, Auth, Storage, Edge Functions and pg_cron. Gemini reads invoices and voice notes and answers Martina's open questions through the `ai` edge function.

```
src/
  pages/inventory/   Overview, Items, Receive, Counts, Reorder, Pricing, Insights, Locations
  pages/             Assistant (Martina), Settings, Onboarding, auth
  mobile/            phone app, offline queue (IndexedDB), scan, sell, receive, count, chat
  lib/               domain rules, receiving, ledger formatting, Martina, Supabase client
supabase/
  migrations/        schema, RLS, posting functions, sample business, storage, cron, hardening
  functions/ai       Gemini: read_invoice, ask, chat, voice
  functions/fx       daily USD/NGN rate for FX timing advice
```

## Accounting model

| Account | Name |
| --- | --- |
| 1310 | Inventory, stock on hand |
| 1315 | Goods in transit |
| 1420 | Input VAT receivable |
| 2010 | Accounts payable |
| 5100 | Cost of sales |
| 5200 | Inventory shrinkage |
| 3100 | Opening balance |

Receipts recalculate weighted average cost per item on the server. Sales relieve stock first-expiry-first-out and post cost of sales at WAC. Count variances post one journal per line to 5200 after approval. Transfers move value through 1315 until the receiving branch confirms. Landed cost goes into WAC for stock still on hand and to 5100 for any share already sold. Every posting runs inside a `security definer` function that checks the caller's permission first.

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
