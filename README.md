# Counta · TaxStreem Inventory

Counta is the inventory module for TaxStreem. Inventory runs as a sub-ledger of the books: every stock movement posts a balanced journal, movements are append-only, and nothing reprices or orders without an owner tap. Staff capture stock on an installable phone app that keeps working offline.

## What is in here

The desktop app covers nine screens. **Overview** carries the Martina prompt bar, the KPI snapshot, a single needs-action queue and the movement ledger. **Items** lists every product with units shown in purchase and selling terms, an item drawer (stock, details, units and labels, batches, movements), Excel export, and upload from our template or any sheet the business already keeps. **Receive stock** reads typed and handwritten invoices with Gemini, asks the user to confirm any line under 85% confidence beside a crop of the photo, previews the journal against the TaxStreem chart of accounts and posts it. **Stock counts** lets the owner schedule blind counts and approve or reject variances with reasons. **Reorder** shows suggestions sized by velocity, lead time, safety days and seasonality, explainable vendor scores, FX timing advice and draft purchase orders that go out on the vendor's channel. **Pricing** handles price proposals (cost increase, below replacement cost, margin under threshold), landed cost allocation and the price change audit trail. **Insights** compares cash against stock, suggests dead stock markdowns and runs the FEFO batch table with quarantine. **Reports** has 22 stock, ledger, purchase, sales and control reports that download as Excel, CSV or PDF, plus a month-end pack in one workbook. **Locations & staff** holds branch cards, transfers through goods in transit, the permission matrix, voice review and the activity log.

The item form and the import template follow the kind of business: a pharmacy records generic name, strength and dosage form with batches on; a fashion store records size, colour and fabric; an auto parts dealer records OEM part number and fitment; a manufacturer records raw materials, packaging and spares that are not for sale and sit in their own inventory accounts. Thirteen trades are set up. `docs/reports-and-import.md` covers the fields, how an uploaded sheet is read and matched, what the import posts, and every report.

Every desktop screen also fits a phone. Tables turn into cards under 760px, modals become bottom sheets, fields stay at 16px so iPhones do not zoom, and the layout respects the notch and home bar. On a phone, `/` opens the phone app; a person can switch to the full app from Today and Counta remembers the choice on that device.

Martina can also phone people through ElevenLabs voice agents. From a purchase order she calls the vendor, reads out the order, confirms quantities and a delivery date, and writes the outcome back to the order. From Locations & staff an owner or manager can have her ring a team member about a count to finish, counts to approve, invoices to confirm, a transfer to receive or price checks to decide. See `docs/voice-and-push.md`.

Installed as an app, Counta sends push notifications when a count needs approval or comes back for a recount, an invoice needs checking, stock is on its way to a branch, a price check opens, or a phone call finishes. A banner asks to install (Chrome's install prompt on Android, Share then Add to Home Screen on iPhone) and then to turn on notifications.

The phone app lives at `/m`. It has Today (queue, counts assigned to you, transfers arriving, items running low), barcode and QR scanning, voice sales in Pidgin, Yoruba, Hausa, Igbo or English, invoice photos, blind counts and a WhatsApp-style Martina chat. Sales, counts, transfer confirmations and invoice photos queue on the device when there is no data and post in order, with their original time and a client UUID so a retry never posts twice.

## Stack

React 18, TypeScript, Vite, React Router and TanStack Query on the front end, shipped as a PWA. Supabase provides Postgres with row level security, Auth, Storage, Edge Functions and pg_cron. Gemini reads invoices and voice notes and answers Martina's open questions through the `ai` edge function.

```
src/
  pages/inventory/   Overview, Items, Receive, Counts, Reorder, Pricing, Insights, Reports, Locations
  pages/             Assistant (Martina), Settings, Onboarding, auth
  mobile/            phone app, offline queue (IndexedDB), scan, sell, receive, count, chat
  lib/               domain rules, receiving, ledger formatting, chart of accounts, Martina, Supabase client,
                     industries (item fields per trade), sheet (reading and matching uploads), reports, exporters
docs/                TaxStreem chart of accounts (CSV), the posting reference, voice and push, reports and import
supabase/
  migrations/        schema, RLS, posting functions, sample business, storage, cron, hardening, TaxStreem chart
  functions/ai       Gemini: read_invoice, ask, chat, voice, map_columns and extract_rows for uploads
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

Apply the files in `supabase/migrations` in order, then deploy the edge functions. `ai` and `fx` verify the JWT; `voice` and `push` check the caller themselves (a signed-in user, or the database's hook secret) and are deployed with JWT verification off.

Keys can be Edge Function secrets or rows in Supabase Vault with the same name. The functions read the environment first and fall back to Vault through `public.app_secret()`, which only the service role can call. Store a Vault key with `select vault.create_secret('<value>', '<NAME>');`.

| Secret | Purpose |
| --- | --- |
| `GEMINI_API_KEY` | Invoice reading, voice entry and Martina's open answers. Without it the app still works; lines are typed by hand and Martina answers from rules. |
| `GEMINI_MODEL` | Optional model override (default `gemini-3.8-flash`, falling back through 3.6, 3.5 and `gemini-flash-latest` when a model is busy). |
| `ELEVENLABS_API_KEY` | Phone calls. Needs access to Agents and phone numbers. |
| `ELEVENLABS_PHONE_NUMBER_ID` | Optional. Which ElevenLabs number to ring from when the account has several. |
| `ELEVENLABS_VOICE_ID` | Optional. Voice for both agents. |
| `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` | Web Push keys. Generated by the `push` function on first use and saved to Vault. |
| `VAPID_SUBJECT` | Optional contact URL or mailto for push services (defaults to the site URL). |
| `PUSH_HOOK_SECRET` | Generated by the migration. The database sends it with each call to `push` and `voice`. |

In Auth settings, set the Site URL and redirect URLs to the deployed domain. A nightly pg_cron job quarantines expired batches and refreshes price alerts.

## Sample business

A new account can open **Kelandellen Company Limited**, a two-branch Lagos supermarket (Surulere and Yaba) with 130 days of history: receipts from six vendors, handwritten invoices, transfers, counts, voice sales, batches near expiry and a run of Saturday cash shortfalls for the cash-versus-stock narrative. It can be removed from Settings.

## Deploying

Netlify builds with `npm run build` and publishes `dist`. `netlify.toml` holds the SPA redirect, cache headers and the camera and microphone permissions policy.
