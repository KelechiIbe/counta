# Counta Practice Management — Release 1 spec

Status: decisions approved by the product owner on 2026-11-12. This file is the binding authority for design and build.

Repo: /home/claude/counta (Vite + React + TypeScript + React Query; Supabase project `krtqqhndmncarwusukrw`). Existing practice model: `supabase/migrations/20261031000300_practices.sql`, portal UI under `src/practice/`, behaviour doc `docs/accountant-portal.md`.

## What exists today (short)

- Practices (`practices`, `practice_members` partner/manager/staff with ICAN/ANAN/CITN licence fields, `practice_clients` invited/requested/active/ended/declined, `practice_assignments`, `practice_requests`, `practice_notes` plain text ≤2000 chars, `filing_versions`).
- A client connects only when the business owner accepts an invite or starts the link (invite, business_invite_accountant, referral /r/CODE, directory request). There is NO create-on-behalf flow.
- `private.practice_sync_seats(client)` gives assigned practice people a `members` row with `role='accountant'` (keep_books, approve_adjustments, see_margins, file_tax on; make_payments, approve_payments, manage_team, manage_settings off).
- Business roles: owner, admin, manager, staff, cashier, accountant; 16 permission flags (`private.perm_keys()`, `private.role_template()`, `role_permissions`), checked via `private.require(org, perm)` / `perm_of` and frontend `can()`.
- Owner-only actions: closing books/years, NIN/NIN slip/CAC documents (`kyc_submit`), tax portal logins (owner + authenticator code), connecting to a practice, (no ownership transfer exists).
- `create_org(...)` makes the caller owner and defaults `orgs.email` to the caller's email.
- Payments locked until `identity_status` verified (NIN must match a CAC director). Business wallet + tax wallet = two Flutterwave payout subaccounts (`supabase/functions/payments`, `open_wallet`, `open_tax_wallet`; tables in `20261018000300_payments.sql` and `20261027000100_wallets_vat_alerts.sql`; VAT on collections queued to the tax wallet).
- Outbound messages to the owner: `alerts_tick` (deadline email/WhatsApp, weekly digest, transactions to confirm, Martina owner calls), LIRS pay reminder, VAT-threshold push, Flux approval holds; many paths hard-code `role='owner'`. Customer documents go out as "Business via Counta" with Reply-To and a "Sent with Counta" footer; public pages `/p/:token`.
- No audit table (actor stored per row as `members.id`). No template/merge engine, no e-signature, no recurring invoices, no fee billing for firms (existing portal "Billing" page = the firm paying clients' Counta plans).

## Release 1 scope

### 1. Add-client wizard with two modes
When a firm adds a business it chooses:
- **Involved** — today's flow (invite the owner; owner accepts).
- **Full mandate** — the firm creates and runs the business on Counta; the client is never contacted by Counta and need not know Counta exists. Only the outcome is visible to the client.

Both modes go through the due-diligence intake (§3) and conflicts check (§4) first.

### 2. Full-mandate rules
- The firm creates the business itself. No client user exists. Design must decide how ownership is represented (e.g. a managed flag + practice-held ownership, or a placeholder owner member with no user) — but every owner-gated path must keep working.
- Firm people working the business get **admin-level** permissions (all 16 flags) **plus** the owner-only actions: identity verification (kyc_submit / NIN / CAC docs), tax portal logins, closing books and years.
- **Excluded until a director confirms once:** the Counta business wallet, the tax wallet, payment links and payouts. The firm enters a director's contact; the director receives a one-time confirmation (the single client-involvement step); only then can the wallets open. Until then invoices show the client's own bank details for payment.
- Mono bank feeds allowed (firm uses a view-only banking login the client gives it); statement upload remains the fallback.
- The Counta plan for a full-mandate business is always billed to the practice.
- **Silence:** Counta sends the client/owner nothing — no email, WhatsApp, Martina calls, digests, deadline alerts, VAT-threshold pushes, LIRS reminders, Flux holds, transactions-to-confirm. `orgs.email` is an address the firm chooses. Reminders and digests that would go to the owner go to the firm instead.
- **Branding:** documents and emails sent to the client's customers (invoices, receipts, credit notes, statements, quotes, payment/public pages) drop "Sent with Counta" and the "via Counta" sender name. Sending domain and public-link domain stay Counta's for now. Firm may choose download-only (no sending).
- **Gate:** a firm may choose full mandate only when (a) a signed engagement letter exists for that client (e-signed in Counta or a signed copy uploaded), (b) a partner has declared that the firm holds the client's written authority, and (c) the firm's professional licence (ICAN/ANAN/CITN) has been verified by Counta staff in the admin portal. Unverified firms can add involved clients only.
- **Activity log:** every write a firm member makes in a full-mandate business is logged (who, when, what entity, values before and after). The firm sees it; the client sees it if they ever join.
- **Handover:** the firm invites the owner by email; on acceptance the person becomes the owner member, the firm drops to an ordinary accountant seat, the mode becomes involved, and silence/branding rules lift.
- **Ending without handover:** the firm can export the client's full records; the business becomes read-only and is kept for the retention period set in the engagement letter.

### 3. Client onboarding = due-diligence intake
Accountants and tax consultants are DNFBPs (MLPPA 2022 s.30, supervised by SCUML; s.4 CDD incl. beneficial owners and PEP measures; s.8 records kept ≥5 years after the relationship ends). Intake records, as **practice data** kept apart from the owner-only `kyc_profiles.cac`:
- business registration details (name, type, RC/BN number, TIN, address, industry);
- directors and beneficial owners (name, role, ownership %, nationality, PEP yes/no, ID type, **ID number last 4 digits only**);
- risk rating (low/medium/high) with reason;
- supporting documents (documents bucket, practice-owned path);
- retention: kept ≥5 years after the engagement ends.
Applies to both modes.

### 4. Conflicts check at intake
- Match the prospect's name, RC number, TIN, directors and beneficial owners against the firm's current and former clients, their recorded related parties (intake directors/BOs), and opposing parties the firm records on engagements. Fuzzy name matching (reuse `private.name_score` / `name_match`).
- Hits show as possible conflicts; a partner records clearance (with a note) or refusal (with a reason). Intake cannot proceed to engagement without a recorded outcome when there are hits.
- Search never crosses practices.
- Optional firm setting, **default off**: also flag when the prospect appears as a customer or supplier in an existing client's books.

### 5. Engagement letters
- Per-practice templates. The default template is an improved version of a real firm sample letter (draft text: `docs/superpowers/specs/2026-11-12-engagement-letter-template.md`): fix 1.1(a) numbering (skips ii), "ethSSL" typo in 5.1, TaxProMax → NRS Rev360 portal, remove personal phone number; add NDPA 2023 clause, termination, client responsibilities, express authority/mandate clause (with a full-mandate variant). Liability cap clause defaults to "whichever is lower" and stays editable. Template must hold no real-person data (repo is public).
- Merge fields filled from intake/practice: client name, RC number, address, services, fees, engagement partner, date, firm details.
- Partners edit any clause; only partners manage templates. A firm may import its own letter: a Word (.docx) file becomes an editable template; a PDF is sent for signature as it stands.
- Per-client letter lifecycle: draft → partner signs → sent to client → client signs → completed (or upload a signed copy).
- E-sign: client opens a tokenised link (hashed token like practice invites), reads the letter, types or draws a signature, confirms a code sent to their email, signs. Counta produces a final PDF with a certificate page (signer names, emails, times, IP addresses, user agents, SHA-256 of the document). For full-mandate clients the signing page and emails show only the firm's name.
- Stored in the documents bucket.

### 6. Fee billing (added to Release 1)
- Each firm gets its **own Counta business** linked to the practice ("firm business"), set up from the portal; a partner is its owner and verifies identity the usual way. That business gets the standard **Flutterwave business wallet and tax wallet** through the existing wallet machinery; VAT on fee collections moves to the tax wallet as today.
- Fee invoices are ordinary sales invoices of the firm business, addressed to the client as a customer (customer record created/linked per practice client).
- **Recurring invoices (new, general Counta feature):** schedule (monthly on day N, quarterly, annually), start/end, lines, VAT 7.5%; auto-issue and send. One-off lines such as an expenses deposit supported. Payment links collect into the firm's business wallet once its identity is verified. WHT deducted by the client handled by existing WHT credit notes.
- Fee invoices sent to a full-mandate client carry no Counta branding.
- For a full-mandate client, each fee invoice also posts automatically as a bill (professional fees payable) in the client's books.
- Portal: a "Fees" page (per-client fee invoices, outstanding, recurring schedules, wallet balances). Rename the existing "Billing" page to "Counta plans".

### Out of scope for Release 1
Richer practice notes, tasks/recurring-job workflow, time tracking, WIP and profitability reports, custom sending domain.

## Global constraints (binding)
- Migrations: new files named `YYYYMMDDNNNNNN_slug.sql` with timestamps after `20261123000100`. Tables: `enable row level security` + `revoke all … from anon, authenticated`, no policies. Access through `public` security-definer RPCs with `set search_path = public, private`; helpers in `private`; grants block pattern of `practices.sql:1828-1865` (`revoke … from public, anon; grant … to authenticated`; `svc_*` to `service_role`). Plain, readable SQL (no obfuscation).
- Frontend: RPCs via `rpc()` (`src/lib/supabase.ts`), edge functions via `edge()` (`src/lib/api.ts`), errors via `cleanError`; React Query; UI from `src/components/ui.tsx` and `src/admin/ui.tsx`; global `src/styles.css`; `data-testid` attributes; `useToast`.
- Edge functions in `supabase/functions/*` (Deno). Email via Resend in `messaging/index.ts` with templates in `messaging/wording.ts`.
- Verification: `tsc -b` + `vite build`; SQL must be proven on a local Postgres 16 harness before any SQL file goes to the owner. No live DDL; Supabase MCP `execute_sql` read-only only.
- Privacy: CAC directors' data in `kyc_profiles` stays owner-only; NIN kept as outcome + last 4 digits only; no real-person data in committed files.
- No real emails, WhatsApp, calls, wallet openings or paid lookups during build/testing.

---

# Chosen architecture (approved 2026-11-12): central resolvers + hardened controls

Three designs were compared. The owner chose the "clean architecture" structure (firm staff act *for* the owner through one resolver; one outbound gate; one branding resolver; one activity log) combined with the "pragmatic" design's security controls. Ignore effort; correctness and an honest record come first. Rewrites of existing functions must be proven behaviour-identical for ordinary (non-managed) businesses on the local harness before they ship.

## A. Owner resolver (who acts as owner, who is the contact)
- `members.acts_as_owner boolean not null default false`, check: `not acts_as_owner or (practice_id is not null and role = 'admin')`.
- `orgs` gains (all protected from direct `authenticated` updates by redefining `private.orgs_guard`): `managed_by uuid references practices(id)` (set while under full mandate and after an end-without-handover), `director_confirmed_at timestamptz`, `read_only_at timestamptz`, `retain_until date`, `send_mode text not null default 'send' check (send_mode in ('send','download_only'))`.
- `practice_clients` gains: `mode text not null default 'involved' check (mode in ('involved','full'))`, `engagement_partner_id uuid references practice_members(id)`, `intake_id uuid`, `alert_email text`, `retention_years int`, `end_kind text check (end_kind in ('handover','ended'))`, `fee_customer_id uuid` (customer row in the firm business), `fee_vendor_id uuid` (vendor row in the client's books). Full mode forces `billing='practice'` (check). One active full mandate per org (partial unique index).
- `private.perm_of`: first branch becomes `m.role = 'owner' or m.acts_as_owner`. Every `require(…,'owner')` caller is then fixed with no edit.
- New helpers in `private`: `acts_as_owner(p_org uuid, p_user uuid) returns boolean`; `is_owner(p_org)` rebuilt on it (fixes RLS on orgs/locations and the `kyc/` storage rule); `mandate(p_org) returns practice_clients` (active full-mode row via `orgs.managed_by`); `is_managed(p_org) returns boolean` (`orgs.managed_by is not null`); `org_contact(p_org) returns members` (the owner normally; under full mandate the engagement partner's seat; also the acting member for system postings).
- **Sweep.** Every function whose *latest* definition compares a role to `'owner'` inline (`role\s*(<>|!=|=)\s*'owner'`) is redefined from its latest `pg_get_functiondef` on the harness: user-facing checks become `perm_of(m,'owner')`; `svc_*` checks become `acts_as_owner(org, p_user)`; "pick the owner as recipient/actor" lookups become `org_contact(org)`. Known sites (verify on harness, the list is not exhaustive): statements_close 1044/1109/1130; team_identity_martina 247/324/439/444, identity_state 619, identity_slip 666, svc_identity_nin 628, svc_identity_slip 682; pit_lirs_filing 216/231; sales 1859; transfer_choice 148/164; branding_vat_shop 30; integrations 272; app_reads 135; books_migration 840; cit_vat_wht 3538; personal_income_tax 1914; pos_moniepoint 230/775; whatsapp_alerts 435; alert_send, alerts_tick, get_alert_prefs, flux instruction_alert 325/451, flux_reconcile 272, vat_threshold_tick 3665, pit_pay_remind 575, einvoice_issue_held 232, si_apply (supplier_stock_input_vat 1288), practice_client owner display (practices 761), wallets_vat_alerts 450/1335, periods_taxid 473, bujeti 621/844.
- **Golden check.** Before the sweep, record the results of every swept function for an ordinary business fixture (owner, admin, accountant, staff callers) on the harness; after the sweep the results must be identical.
- Frontend: `can()` (`src/state/session.tsx:122`) treats `me.acts_as_owner` like owner; every `role === 'owner'` test in `src/` moves to `can(inv,'owner')` (or a single `actsAsOwner(inv)` helper).
- `create_org` is split: `private.create_org_core(...)` creates the org without an owner member; `create_org` keeps its exact behaviour by calling core + inserting the owner. Full-mandate creation uses core and sets `identity_status = 'pending'` (the default `'not_required'` is reserved for legacy/sample/TaxStreem businesses and would open payments).

## B. Seats, guards and departed staff
- `private.practice_sync_seats` rewritten: full mode → wanted seats `role='admin'`, `acts_as_owner=true`; involved → `role='accountant'`, `acts_as_owner=false`; every sync re-applies permissions. Unwanted practice seats are disabled whatever their role, so removing a practice member disables every client seat in one call (wire practice-member removal/deactivation to resync all of that practice's clients).
- `members_mandate_guard` (BEFORE INSERT/UPDATE on members): in a managed org only seats tagged with the managing practice may be active or invited; role/status/user/permission/acts_as_owner columns change only while the transaction-local setting `counta.seat_sync = 'on'` (seat sync, handover).
- `practice_clients_guard`: a managed org cannot connect to or request another practice (blocks `practice_accept`, `business_invite_accountant`, partner-programme connect, `practice_request_create`).
- `subscription_charges_guard`: a managed org's charge must carry `practice_id`.
- Blocked under full mandate: `invite_member`, `practice_end` (use handover or end-mandate), `subscription_start`/`subscription_method`.
- `svc_identity_nin` on a managed org with no CAC record returns `cac_required` (its fallback would match a firm person's own name); with CAC data it matches the NIN against CAC directors as today.
- `kyc_submit`/lookup calls accept `p.org_id` → `kyc_row(uid, org)`.
- Admin kill switch: `practices.mandate_suspended_at timestamptz`; `private.practice_can_full(p_practice)` = an active partner with a verified licence (`private.partner_verified`) and not suspended.

## C. Outbound gate (silence) and branding resolver
- `private.outbound_check(p_org, p_channel text, p_kind text, p_to text) returns text` (null = allowed, else reason). For managed or read-only orgs: alerts/invites only to firm addresses (practice member emails, `practices.email`, `practice_clients.alert_email`) or a pending handover invite; customer/supplier messages allowed unless `send_mode='download_only'`; calls never; read-only orgs send nothing.
- BEFORE INSERT trigger on `messages`: alert email to a non-firm address is re-addressed to `org_contact`/`alert_email`; anything else not allowed gets the new status `suppressed` (add to the status check) with the reason. BEFORE INSERT on `voice_calls`: managed orgs → dropped + activity event. `private.alert_prefs` forces `owner_calls`/`customer_calls` off for managed orgs.
- `svc_message` returns `managed` and `alert_to_allowed`; `supabase/functions/messaging/index.ts` `deliver()` fails closed on a mismatch.
- User-pressed sends call `private.require_outbound` so the user sees a clear error in download-only mode.
- `private.white_label(p_org uuid, p_customer uuid default null) returns boolean`: true when the org is managed, or when the customer is the `fee_customer_id` of an active full-mandate client of a practice whose firm business is `p_org`. `org_brand` gains `white_label` and `pay_online`; `svc_message` and `public_document` pass the customer. Drop "via Counta"/"Sent with Counta"/"Powered by Counta"/"made by Counta" at: `messaging/index.ts:93` (displayName), `index.ts:142`, `wording.ts:119/128/158`, `src/pages/public/Public.tsx:26` (and hide pay buttons unless `pay_online`, showing `invoice_note` bank details), `src/lib/docPdf.ts:222/269/329/387`, `src/lib/printer.ts:83`, `src/pages/public/ShopPage.tsx:187`, `src/pages/settings/SettingsBooks.tsx:123` (match the real sender). Meta WhatsApp templates all end "Sent with Counta": unbranded WhatsApp over Meta is unavailable (email only) until `_nb` template variants are approved.

## D. Gate, declaration, director confirmation, money lock
- Intake columns hold the declaration: `authority_declared_by`, `authority_declared_at`, `authority_statement` (snapshot text), optional `authority_doc_path`. Partner-only.
- `private.mandate_gate(p_intake uuid) returns jsonb` (each condition true/false) and `practice_create_business(p_intake uuid, p jsonb) returns jsonb` require: caller is a personally verified partner; `practice_can_full`; intake risk rating set and conflicts none-or-cleared; a completed full-variant letter (e-signed, or an uploaded signed copy); the declaration; no other org with the same normalised RC number or Tax ID that is owned by a real person or managed by another practice (generic error + admin flag). It creates the org via core (firm-chosen `orgs.email`, client bank details in `invoice_note`, `managed_by`, `identity_status='pending'`), the `practice_clients` row (mode full, billing practice, status active), syncs seats, logs an activity event.
- `practice_director_confirmations`: name, email, phone, token hash, expiry, sends, OTP hash/expiry/attempts/total failures, status `pending|review|confirmed|declined`, IP, user agent, flags. `practice_director_request` requires identity verified; the name must `identity_match` a CAC director from `private.identity_people`; the email must not be any practice member's, the practice's, or on the practice's own (non-free-mail) domain. Public page `/confirm/:token` → `practice` edge function → service-role-only `svc_director_open/code/confirm/decline`. If the confirming IP matches a recent `auth.sessions.ip` of any member of that practice, status becomes `review` and TaxStreem admins decide in the admin portal. Decline alerts admins and the firm. The page shows the firm's name and names TaxStreem and Flutterwave as the wallet provider (the director is consenting to accounts that hold company money).
- `private.payments_open` and `private.require_payments_open` (team_identity_martina.sql:516-530): existing checks AND (`managed_by is null` OR (`director_confirmed_at is not null` AND `practice_can_full(managed_by)`)). This one change gates wallet, tax wallet, payment links, payouts, bulk pay, tax payments and Flux.

## E. Activity log
- `public.activity_log`: `id bigint generated always as identity`, `org_id`, `practice_id`, `at`, `actor_user`, `actor_member`, `actor_name` (snapshot), `source text check (source in ('row','event'))`, `action`, `entity`, `entity_id text`, `label`, `before jsonb`, `after jsonb`, `changed text[]`. Immutable (trigger blocks update/delete).
- `private.activity_row()` AFTER row trigger attached by a DO loop to every public table with `org_id` plus `orgs` and `members`, minus `private.activity_exempt()` (messages, notifications, alert_log, usage_events, ai_logs, shop_hits, payment_events, org_counters, stock_levels, chat/voice logs — confirm on harness). Returns immediately unless the org is managed or read-only (PK lookup). Actor = `auth.uid()` or the `counta.actor` setting (set by `svc_*`, the fee mirror, the recurring job). Updates store changed keys only; keys matching token/secret/hash/password/otp/nin/api_key are redacted; values over 4 KB truncated. The same trigger enforces read-only: raises 42501 when `orgs.read_only_at` is set and the writer is a signed-in user.
- `private.activity_event(p_org, p_action, p_label, p_meta jsonb)` for business events (mode changes, handover, end, export, director confirmation, letter steps, suppressed messages/calls, fee-bill postings).
- Reads: `practice_activity(p_client uuid, p jsonb)`; `org_activity(p_org uuid, p jsonb)` (owner/acting owner/manage_team).
- Harness coverage test: fails if any public table with `org_id` lacks the trigger and is not exempt.

## F. Intake and conflicts
- Tables: `practice_intakes` (practice, status, mode_requested, legal name, entity type, rc_number, tax_id, address, industry, risk_rating, risk_reason, pep_present, conflict_status `pending|none|hits|cleared|refused`, conflict note, decided by/at, checked_at, declaration columns, client_id, org_id on delete set null, retain_until), `practice_intake_people` (kind director|beneficial_owner|related, name, role, ownership_pct, nationality, is_pep, id_type, `id_last4` check `^[A-Za-z0-9]{4}$`), `practice_intake_docs` (path under `practice/<pid>/intake/<iid>/`, sha256), `practice_opposing_parties`, `practice_conflict_hits`; `practices.conflict_scan_books boolean not null default false`.
- RPCs: `practice_intake_save` (rejects full ID numbers; a PEP forces risk `high`), `practice_intake`, `practice_intakes`, `practice_intake_doc_add`, `practice_opposing_save`, `practice_conflict_run` → `private.conflict_scan` (every predicate filtered to the intake's practice; RC/Tax ID normalised exact; company names `name_match` or `name_score ≥ 0.75`; people via `identity_match`; books scan of customers/vendors of this practice's active clients only when the setting is on), `practice_conflict_decide` (partner only, note ≥ 10 chars), `practice_set_conflict_scan`.
- Engagement cannot proceed while hits exist without a recorded outcome or after a re-edit without a re-run. `practice_invite_client` requires a cleared intake; business-initiated links auto-create a draft intake flagged "due diligence incomplete".
- Storage: documents-bucket policies for `practice/<pid>/…` via `private.practice_file_ok`; no delete policy. Deletes of intake rows blocked until `retain_until` (≥ 5 years after the engagement ends).

## G. Engagement letters
- `practice_letter_templates`: practice, name, kind `blocks|pdf`, `body jsonb {version, blocks:[{id, kind heading|clause|paragraph|list|signature, level, text, variant null|full|involved, optional}]}` (plain text with `{{field}}`, no HTML; numbering computed at render), `pdf_path`, `is_default`. Partner-only writes. `private.letter_body_ok` validates size, kinds and whitelisted merge fields. `private.letter_default_body()` = the template in `docs/superpowers/specs/2026-11-12-engagement-letter-template.md` converted to blocks (conditional sections become `variant`/`optional` blocks; merge-field names may be normalised but every field in the draft must map).
- `engagement_letters`: practice, intake/client, variant, source `template|pdf|signed_upload`, status `draft|partner_signed|sent|completed|uploaded|void`, frozen blocks + merge values, doc path + sha256, final path + sha256, retention_years ≥ 5, partner signature + IP + UA, white_label. Freeze trigger after `partner_signed`.
- `engagement_letter_signers`: token hash (`es_` + 48 hex, 14 days, replaced on resend), OTP hash (6 digits, 10 min, 5 tries per code, 5 sends per day, lock after 15 failures), signature PNG path, IP, UA, signed_at. `engagement_letter_events` (time, kind, actor, IP, UA).
- Edge function `supabase/functions/practice/` (`index.ts`, `pdf.ts`, `export.ts`) using `npm:pdf-lib` with standard fonts (amounts written "NGN …"): `letter_freeze` (partner signs: render PDF, SHA-256, write-once store), `sign_open`, `sign_code`, `sign_submit` (re-hash stored doc and compare; append a signature page and a completion certificate: both parties' names, emails, Lagos times, IPs, UAs, verified email, original SHA-256; store `final.pdf` + hash), director confirmation actions, export. Uploaded PDFs are signed as they stand.
- DOCX import runs in the browser (`src/practice/letterDocx.ts`, using the existing `fflate`; 2 MB file and uncompressed-size caps) producing blocks that the server validates.
- Emails in the firm's name only via a new messaging hook (kinds `letter_sign`, `letter_code`, `letter_done`, `director_confirm`, `director_code`).
- Public `/sign/:token` (`src/pages/public/Sign.tsx`): `no-referrer`, token removed from the URL on load, documents via 5-minute signed URLs.
- Storage: `practice/<pid>/letters/<lid>/`.

## H. Recurring invoices and fees
- `recurring_invoices` (org, customer, status active|paused|ended, frequency monthly|quarterly|annually, day_of_month 1–28, start_date, end_date, next_run, due_days, lines jsonb with a `once` flag for one-off lines, auto_send, send_channel, created_by, failures, last_error, practice_client_id) and `recurring_invoice_runs` unique (schedule, run_date). `issue_invoice_as`/`send_document_as` extracted to `private` (public wrappers keep behaviour). `private.recurring_tick()` hourly via the guarded `cron.schedule('counta-recurring', …)` pattern of `sales.sql:2124`; `for update skip locked`; create → issue → `waiting_nrs` when held → send when sendable → roll forward (one catch-up, no backfill); each schedule in its own exception block; pause after 3 consecutive failures. RPCs `recurring_save/list/set_status/run_now`. Business-app screen `src/pages/sell/Recurring.tsx`.
- `practices.firm_org_id`; `practice_firm_business(p_practice, p)` links a business the partner owns or creates one with `create_org` (identity and the Flutterwave business wallet + tax wallet then work exactly as for any business; VAT on fee collections moves to the tax wallet as today). `practice_fee_customer(p_client)` upserts the customer in the firm business.
- Fee mirror: AFTER UPDATE OF `journal_id` on `sales`; when the customer is a full-mandate client's `fee_customer_id`, `write_bill` + `post_bill` in the client's books (professional fees expense account from the chart + input VAT) as `org_contact`; recorded in `practice_fee_bills` (posted|failed, retryable); never blocks issuing; a voided fee invoice voids an unpaid mirrored bill.
- Portal: `practice_fees(p_practice)` (wallet balances to partners only) → `src/practice/pages/Fees.tsx`; the "Billing" nav label becomes "Counta plans" (route `billing` unchanged).

## I. Handover, end, export, deletion
- `practice_handover_start(p_client, p)` (partner; recipient not a practice member) issues a `ph_` token; `practice_handover_accept` (signed-in email must match) in one transaction: new owner member, `managed_by` cleared, mode involved, seats resynced to accountant, activity event. Silence and branding lift because they key on `managed_by`.
- `practice_end_mandate(p_client, p)` refuses while either wallet holds a balance or a payout is pending; sets `read_only_at`, `retain_until` = today + max(letter retention, 5) years; pauses recurring schedules, feeds, integrations, POS; cancels the plan at period end; engagement partner seats stay (read-only), others disabled; `managed_by` stays set so silence persists.
- Export via the `practice` function: zip of redacted JSON per table + ledger CSV + activity log + stored files; signed URL valid 10 minutes; logged.
- Every business-deletion path refuses while `retain_until` is in the future.

## J. Admin portal
- Mandates page (`src/admin/pages/Mandates.tsx`): director confirmations in `review` (approve/decline), suspend/unsuspend a practice's full mandates, flagged duplicate-company attempts. Uses the existing admin audit (`private.audit`).

## K. Harness and verification
- `supabase/tests/harness/run.sh` + `stubs.sql`, proven in a spike at `/var/tmp/counta-pgh/` (applies all 84 existing migrations). Run as the `postgres` OS user (`runuser -u postgres`; initdb refuses root) with data and socket under `/var/tmp/counta-pgh` (the scratchpad's parent directories lose world-execute permission). pg_cron/pg_net are stubbed by stripping their two `create extension` lines and creating `cron`/`net` schemas by hand (`net.http_post` should write into a `net._requests` table so tests can assert edge-function calls).
- Add Supabase-style default privileges on `public` (tables and functions granted to anon/authenticated/service_role) so the migrations' revokes are tested. Note `core.sql:599` grants execute on every `private` function to `authenticated`: each new private helper must be revoked explicitly.
- Tests: `supabase/tests/sql/*.sql`, each in `begin … rollback`, `DO`/`assert` blocks, acting as users via `set local role authenticated` + `set_config('request.jwt.claims', …)` (helpers `tests.as_user`, `tests.throws`). Fixtures use fake names and `@example.test` addresses only.
- Frontend: `tsc -b` + `vite build` (revert `tsconfig.tsbuildinfo` before committing). No live DDL; no real emails, WhatsApp, calls, wallet openings or paid lookups.
