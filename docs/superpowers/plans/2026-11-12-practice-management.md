# Counta Practice Management Release 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a firm onboard a client through due diligence, a conflicts check and an e-signed engagement letter, then either invite the owner (involved) or create and run the business itself (full mandate: silent, unbranded, logged, money locked until a director confirms), bill its own fees with recurring invoices, and hand the business over or end the engagement with an export.

**Architecture:** Firm people act *for* the owner through one resolver (`members.acts_as_owner`, `private.perm_of`, `private.acts_as_owner`, `private.org_contact`), and every existing function that compares a role to `'owner'` is mechanically swept onto it, proven identical for ordinary businesses by a golden fixture on a local Postgres 16 harness. One outbound gate (`private.outbound_check` + BEFORE INSERT triggers on `messages` and `voice_calls`), one branding resolver (`private.white_label` via `private.org_brand`) and one trigger-fed `activity_log` cover silence, branding and the record. Practice data (intakes, conflicts, letters, director confirmations, handovers, fee bills) lives in RLS-locked tables behind security-definer RPCs; a new `practice` edge function renders and signs PDFs, runs director confirmation and builds exports.

**Tech Stack:** Supabase Postgres 16 (plpgsql, pg_cron, pg_net), Deno edge functions (`npm:@supabase/supabase-js@2`, `npm:pdf-lib@1.17.1`, `npm:fflate@0.8.3`), Resend, Vite + React 18 + TypeScript + React Query, `fflate` 0.8.3 in the browser. Tests: local Postgres 16 harness (`supabase/tests`), `deno test` for pure TS modules, `tsc -b` + `vite build`.

**Spec:** docs/superpowers/specs/2026-11-12-practice-management-design.md

## Global Constraints

- Migrations: new files named `YYYYMMDDNNNNNN_slug.sql` with timestamps after `20261123000100`; this plan uses `supabase/migrations/202611240001NN_<slug>.sql`, increasing, one per SQL task.
- Tables: `enable row level security` + `revoke all … from anon, authenticated`, no policies (the only policies added are the documents-bucket ones in Task 8).
- Access through `public` security-definer RPCs with `set search_path = public, private`; helpers in `private`; plain, readable SQL (no obfuscation).
- Grants block pattern of `practices.sql:1828-1865`: `revoke execute on function public.x(...) from public, anon;` then `grant execute on function public.x(...) to authenticated;`; `svc_*` revoked from `public, anon, authenticated` and granted to `service_role`; anon-callable previews granted `to anon, authenticated`.
- `core.sql:599` grants execute on every `private` function to `authenticated`: every new private helper gets `revoke all on function private.x(...) from public, anon, authenticated;` in its migration (Task 1's `00_harness.sql` and each task's test assert it).
- `create or replace` keeps grants; a signature change (`private.org_brand`) is `drop function` + `create` + re-grant/revoke.
- Frontend: RPCs via `rpc()` (`src/lib/supabase.ts`), edge functions via `edge()`/`edgeOk()` (`src/lib/api.ts`), errors via `cleanError`; React Query; UI from `src/components/ui.tsx` and `src/admin/ui.tsx`; global `src/styles.css`; `data-testid` attributes; `useToast`.
- Edge functions in `supabase/functions/*` (Deno); email via Resend in `messaging/index.ts` with words in `messaging/wording.ts`.
- Frontend verification: `./node_modules/.bin/tsc -b --noEmit && ./node_modules/.bin/vite build`, then `git checkout -- tsconfig.tsbuildinfo` before committing.
- Deno verification: `deno test --node-modules-dir=none --allow-read <files>` and `deno check --node-modules-dir=none <entry>`.
- SQL must be proven on the local Postgres 16 harness before any SQL file goes to the owner: every SQL task ends with `bash supabase/tests/run_tests.sh` printing `ALL PASS`. No live DDL; Supabase MCP `execute_sql` read-only only.
- Rewrites of existing functions must be proven behaviour-identical for ordinary (non-managed) businesses: `bash supabase/tests/golden/run.sh check` prints `golden OK (136 cases)` after every task that redefines an existing function (Tasks 2, 3, 4, 6, 8, 10, 11, 13, 14). Expected outputs are recorded once, in Task 1, and never re-recorded. A task that adds a column to an existing table or a key to an existing function's output appends each new name to `supabase/tests/golden/added_keys.txt` in the same commit; the golden check ignores those keys at any depth and nothing else.
- Privacy: CAC directors' data in `kyc_profiles` stays owner-only (never copied into intake, activity log or export); NIN kept as outcome + last 4 digits only; intake ID numbers last 4 only (`^[A-Za-z0-9]{4}$`); no real-person data in committed files; fixtures use fake names and `@example.test` addresses only.
- No real emails, WhatsApp, calls, wallet openings or paid lookups during build/testing (edge calls are asserted through `net._requests`, never sent).
- Harness scripts are run as root from `/home/claude/counta-pm` and call `runuser -u postgres --` internally (initdb refuses root); data and socket live in `/var/tmp/counta-pgh`, port `54329`.
- Commits: run `export TRAILER=$'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_01EKbNNrvjeEWKMi4mbrtF6N'` once; every commit below is `git commit -m "<subject>" -m "$TRAILER"`, which ends the message with a blank line and exactly these two lines:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01EKbNNrvjeEWKMi4mbrtF6N`

## Review Focus

1. Yoruba/Igbo diacritics and the naira sign in a letter or certificate (client "Ọlá Àdé Foods Ltd", partner "Ṣọlá", amount "₦250,000"): pdf-lib standard fonts cannot encode them, so rendering must fold them instead of throwing — test `pdf_diacritics_do_not_throw` in Task 12.
2. The same diacritics plus "Ltd/Limited", case, punctuation and "RC" prefixes in the conflicts check: "Ọlá Àdé Foods Ltd" / "RC 123456" must hit an existing client "OLA ADE FOODS LIMITED" / "123456" — test `conflict_diacritics_suffix_rc` in Task 8.
3. A director whose email is on a free-mail domain that a firm person also uses (gmail.com in real life; tested with `freemail.example.test` added through the `mandates` platform setting) must be accepted, while the firm's own domain and firm addresses are refused whatever their case or spacing — test `director_email_free_mail_and_case` in Task 10.
4. A full 11-digit NIN/BVN pasted into an intake person's name, role, nationality or last-4 field must be refused, keeping only last 4 — test `intake_rejects_full_id_numbers` in Task 8.
5. Recurring dates: day 28 in February (leap and non-leap), a schedule started after its day of the month, and "today" being the business's Lagos day when the hourly tick runs at 23:30 UTC — test `recurring_dates_and_local_day` in Task 13.

---

### Task 1: Local Postgres harness, test helpers and golden baseline

**Files:**
- Create: `supabase/tests/harness/run.sh` (from `/var/tmp/counta-pgh/up.sh`)
- Create: `supabase/tests/harness/stubs.sql` (from `/var/tmp/counta-pgh/stubs.sql`)
- Create: `supabase/tests/harness/helpers.sql`
- Create: `supabase/tests/harness/fn_dump.sh`
- Create: `supabase/tests/run_tests.sh`
- Create: `supabase/tests/sql/00_harness.sql`
- Create: `supabase/tests/golden/run.sh`, `supabase/tests/golden/fixture.sql`, `supabase/tests/golden/owner_functions.txt`, `supabase/tests/golden/added_keys.txt` (empty), `supabase/tests/golden/cases/<schema>.<function>.sql`, `supabase/tests/golden/expected/<schema>.<function>.out`

**Interfaces:**
- Produces (commands, used by every later task):
  - `bash supabase/tests/harness/run.sh [migrations_dir]` → fresh cluster, stubs, every migration in order; prints `OK: <n> migrations applied` or `FAIL: <file>` + first 5 error lines; leaves the cluster running.
  - `bash supabase/tests/run_tests.sh [pattern]` → run.sh, then `helpers.sql`, then each `supabase/tests/sql/*<pattern>*.sql` sorted; prints `PASS <file>` / `FAIL <file>: <first ERROR line>`; last line `ALL PASS (<n> files)` (exit 0) or exit 1.
  - `bash supabase/tests/harness/fn_dump.sh <schema.name>...` → latest `pg_get_functiondef` of each, each followed by `;` and a blank line (running cluster required). `fn_dump.sh --owner-list` → the owner enumeration below, one `schema.name` per line.
  - `bash supabase/tests/golden/run.sh record|check|coverage [pattern]` → `record` writes `expected/<case>.out`; `check` prints `golden OK (<n> cases)` or a unified diff and exits 1; `coverage` prints `coverage OK (<n> functions)` when every line of `owner_functions.txt` has `cases/<line>.sql`.
- Produces (SQL helpers in schema `tests`, usage + execute granted to `anon, authenticated, service_role`):
  - `tests.ids(name text primary key, id uuid not null)`; `tests.remember(p_name text, p_id uuid) returns uuid`; `tests.id(p_name text) returns uuid`
  - `tests.user(p_email text, p_name text default null) returns uuid` (inserts `auth.users` with `raw_user_meta_data.full_name`)
  - `tests.as_user(p_user uuid, p_aal text default 'aal1') returns void` (sets `request.jwt.claims` `{sub, role:'authenticated', email, aal}`, `request.jwt.claim.sub`, `request.jwt.claim.role`, then `set local role authenticated`)
  - `tests.as_service() returns void`, `tests.as_anon() returns void`, `tests.as_postgres() returns void` (`reset role`, claims cleared)
  - `tests.error_of(p_sql text) returns text` (null when `p_sql` runs; else `SQLSTATE || ': ' || SQLERRM`), `tests.throws(p_sql text, p_like text) returns void` (raises `expected error like <p_like>, got <error_of or 'no error'>` unless `error_of(p_sql) ilike p_like`), `tests.capture(p_sql text) returns text` (runs the SELECT `p_sql` as `select coalesce(jsonb_agg(to_jsonb(q)), '[]') from (p_sql) q`, strips the keys in `tests.golden_ignore(key text primary key)` with `tests.strip_keys(p jsonb, p_keys text[]) returns jsonb` at any depth, returns the jsonb text or `ERROR <sqlstate>: <message>`)
  - `tests.hooks_on() returns void` (`private.config` `functions_url = 'http://functions.test'`, vault secret `PUSH_HOOK_SECRET = 'test-hook'`)
  - `tests.org(p_owner uuid, p_name text) returns uuid` (`public.create_org` as the owner), `tests.member(p_org uuid, p_user uuid, p_role text) returns uuid` (active member, perms via `private.apply_member_perms`)
  - `tests.admin_user(p_email text) returns uuid` (adds `platform_admins`; use with `tests.as_user(u, 'aal2')`)
  - `tests.practice(p_partner uuid, p_name text, p_verified boolean default true) returns uuid` (`public.create_practice` as the partner, licence ICAN `TEST/0001`, `verified` when asked), `tests.practice_member(p_practice uuid, p_user uuid, p_role text) returns uuid` (active), `tests.involved_client(p_practice uuid, p_org uuid) returns uuid` (active `practice_clients` row + `private.practice_sync_seats`)
- Test file convention (every later test file): `begin;` … `rollback;`; each test is `-- test: <name>` followed by one `do $$ … $$;` block that starts as postgres, ends with `perform tests.as_postgres();`, and whose `assert` messages start with `<name>:`. In the test sketches below, `<x>` inside a `$q$…$q$` string stands for the fixture value, interpolated with `format()`, and a parenthesised note describes setup.
- Golden fixture ids (`tests.id(...)`): `org` ("Golden Foods Ltd"), users `owner`, `admin`, `accountant`, `staff`, `partner` (`<role>@example.test`), members `m_owner`, `m_admin`, `m_accountant`, `m_staff`, `m_partner` (the partner's practice seat), `practice` ("Golden Partners", verified), `client` (involved link), `customer`, `invoice_draft`, `invoice`, `vendor`, `bill`, `wallet`, `tax_wallet`.

- [ ] **Step 1: Write the failing test** — `supabase/tests/sql/00_harness.sql`

```sql
-- test: harness_utf8
assert current_setting('server_encoding') = 'UTF8', 'harness_utf8: cluster is UTF8';
-- test: harness_as_user
v := tests.user('a@example.test'); perform tests.as_user(v);
assert auth.uid() = v and current_user = 'authenticated', 'harness_as_user: uid and role set';
perform tests.as_user(v, 'aal2'); assert private.jwt_aal() = 'aal2', 'harness_as_user: aal claim';
-- test: harness_errors
perform tests.throws('select 1/0', '%division by zero%');
assert tests.error_of('select 1') is null, 'harness_errors: no error is null';
-- test: harness_net_requests
perform tests.hooks_on(); perform private.call_function('messaging', '{"x":1}');
assert (select count(*) from net._requests where url = 'http://functions.test/messaging' and body->>'x' = '1') = 1, 'harness_net_requests: call recorded';
-- test: harness_default_privileges
create table public.tmp_priv (x int);
assert has_table_privilege('anon', 'public.tmp_priv', 'select'), 'harness_default_privileges: Supabase defaults active';
assert not has_table_privilege('anon', 'public.practices', 'select'), 'harness_default_privileges: migration revoke wins';
-- test: harness_auth_sessions
assert (select data_type from information_schema.columns where table_schema = 'auth' and table_name = 'sessions' and column_name = 'ip') = 'inet', 'harness_auth_sessions: ip column';
-- test: harness_fixtures
o := tests.org(tests.user('o@example.test'), 'Fixture Ltd');
assert (select role from members where org_id = o) = 'owner', 'harness_fixtures: create_org owner';
p := tests.practice(tests.user('p@example.test'), 'Fixture Partners', true);
assert private.partner_verified(p), 'harness_fixtures: verified partner';
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash supabase/tests/run_tests.sh 00_harness`
Expected: FAIL — `bash: supabase/tests/run_tests.sh: No such file or directory`

- [ ] **Step 3: Implement the harness**

`run.sh`: as `up.sh`, plus: `PGH_DIR=${PGH_DIR:-/var/tmp/counta-pgh}`; migrations dir defaults to `supabase/migrations`; `initdb -D "$PGH_DIR/data" -U postgres -A trust -E UTF8 --locale=C.UTF-8`; every `initdb`/`pg_ctl`/`psql` through `runuser -u postgres --`.
`stubs.sql`: the spike file plus — `auth.uid()` returns `coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''), nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'sub')::uuid` (same pattern for `auth.role()`); `auth.sessions (id uuid primary key default gen_random_uuid(), user_id uuid references auth.users(id) on delete cascade, created_at timestamptz default now(), updated_at timestamptz default now(), ip inet, user_agent text)`; `net._requests (id bigserial primary key, url text, body jsonb, headers jsonb, created_at timestamptz default now())` with `net.http_post` inserting its arguments and returning the id; and Supabase default privileges:

```sql
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
```

`helpers.sql`: the `tests` schema exactly as in Interfaces. `fn_dump.sh --owner-list` runs:

```sql
select n.nspname || '.' || p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname in ('public', 'private') and p.prokind = 'f'
  and (pg_get_functiondef(p.oid) ~ $r$role\s*(<>|!=|=)\s*'owner'$r$
    or pg_get_functiondef(p.oid) ~ $r$role\s+(not\s+)?in\s*\([^)]*'owner'[^)]*\)$r$)
order by 1;
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash supabase/tests/run_tests.sh 00_harness`
Expected: `OK: 84 migrations applied`, `PASS 00_harness.sql`, `ALL PASS (1 files)`

- [ ] **Step 5: Write the golden baseline**

`owner_functions.txt` = output of `bash supabase/tests/harness/fn_dump.sh --owner-list` now (117 lines). One case file per line, plus 19 cases for functions that later tasks rewrite but that are not on the list: `public.create_org`, `public.kyc_draft`, `public.kyc_submit`, `private.payments_open`, `private.require_payments_open`, `public.practice_assign` (runs `practice_sync_seats`), `public.practice_end`, `public.practice_update_member`, `public.send_document`, `public.send_reminder`, `public.send_statement`, `public.return_bill`, `public.reject_supplier_invoice`, `public.prepare_vendor_call`, `public.practice_invite_check`, `public.practice_invite_preview`, `public.svc_practice_invite_link`, `public.issue_invoice`, `public.void_bill` — 136 cases. `run.sh` loads `added_keys.txt` into `tests.golden_ignore` before the cases. Case format:

```
-- callers: owner admin accountant staff
-- setup
<optional SQL run as postgres, adding rows the call needs>
-- call
select public.get_team(tests.id('org'));
```

Rules: `fixture.sql` builds the fixture ids listed in Interfaces with the `tests` helpers and registers each with `tests.remember`; callers from `owner admin accountant staff partner service anon` (default the first four; `svc_*` use `service`); one SELECT per `-- call` line, void results cast `::text`; each case reaches the line holding its owner comparison (setup inserts what the function needs first). `run.sh` loads `fixture.sql` once per case inside one transaction and, per caller, does `savepoint` → setup → switch (`tests.as_user(tests.id('<caller>'))`, or `tests.as_service()` / `tests.as_anon()`) → `tests.capture()` per call → `tests.as_postgres()` → `rollback to savepoint`. Output `== <caller>` then one line per call, normalised with: UUIDs → `<uuid>`; `\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?([+-]\d{2}(:\d{2})?|Z)?` → `<ts>`; `\d{4}-\d{2}-\d{2}` → `<date>`; `[0-9a-f]{48,}` → `<hex>`.

- [ ] **Step 6: Record and prove the baseline is deterministic**

Run: `bash supabase/tests/golden/run.sh coverage && bash supabase/tests/golden/run.sh record && bash supabase/tests/golden/run.sh check && bash supabase/tests/golden/run.sh check`
Expected: `coverage OK (117 functions)`, then `golden OK (136 cases)` twice (fix any case whose output is unordered by ordering inside its call).

- [ ] **Step 7: Commit**

```bash
git add supabase/tests
git commit -m "Test harness: local Postgres 16, helpers and golden baseline of owner-gated functions" -m "$TRAILER"
```

---

### Task 2: Owner resolver and acting-owner checks in the app

**Files:**
- Create: `supabase/migrations/20261124000100_owner_resolver.sql`
- Create: `supabase/tests/sql/01_owner_resolver.sql`
- Modify: `supabase/tests/harness/helpers.sql` (add `tests.managed_org`)
- Modify: `supabase/tests/golden/added_keys.txt` (append `acts_as_owner managed_by director_confirmed_at read_only_at retain_until send_mode mode engagement_partner_id intake_id alert_email retention_years end_kind fee_customer_id fee_vendor_id`, one per line)
- Modify: `src/state/session.tsx:122-128`, `src/lib/types.ts:26-31` (`Org`), `src/lib/types.ts:58-63` (`MeRow`)
- Modify: `src/shell/AppShell.tsx:250-251`, `src/pages/settings/Accountant.tsx:34`, `src/pages/accounting/MoveBooks.tsx:41,75`, `src/pages/accounting/tax/PitTab.tsx:75`, `src/pages/accounting/Statements.tsx:46`, `src/pages/inventory/Locations.tsx:38,126`, `src/pages/inventory/Insights.tsx:53,75`, `src/pages/home/GuideChecklist.tsx:34`, `src/pages/Settings.tsx:237`, `src/pages/sell/Orders.tsx:84`, `src/pages/sell/Shop.tsx:39`, `src/pages/payments/BulkPay.tsx:192`, `src/pages/onboarding/Identity.tsx:150`

**Interfaces:**
- Consumes: Task 1 helpers.
- Produces (SQL):
  - `members.acts_as_owner boolean not null default false`, constraint `members_acts_as_owner_check check (not acts_as_owner or (practice_id is not null and role = 'admin'))`
  - `orgs.managed_by uuid references practices(id) on delete restrict`, `orgs.director_confirmed_at timestamptz`, `orgs.read_only_at timestamptz`, `orgs.retain_until date`, `orgs.send_mode text not null default 'send' check (send_mode in ('send','download_only'))`
  - `practice_clients.mode text not null default 'involved' check (mode in ('involved','full'))`, `engagement_partner_id uuid references practice_members(id) on delete set null`, `intake_id uuid` (FK added in Task 8), `alert_email text` (email regex check), `retention_years int check (retention_years is null or retention_years >= 5)`, `end_kind text check (end_kind in ('handover','ended'))`, `fee_customer_id uuid references customers(id) on delete set null`, `fee_vendor_id uuid references vendors(id) on delete set null`; `practice_clients_full_billing check (mode = 'involved' or billing = 'practice')`; `create unique index practice_clients_one_full on practice_clients(org_id) where mode = 'full' and status = 'active'`
  - `private.perm_of(m members, p_perm text) returns boolean` (first branch `m.role = 'owner' or m.acts_as_owner`)
  - `private.acts_as_owner(p_org uuid, p_user uuid) returns boolean`; `private.is_owner(p_org uuid) returns boolean` = `acts_as_owner(p_org, auth.uid())` (stays security definer, keeps its grant)
  - `private.mandate(p_org uuid) returns practice_clients` (row with `org_id = p_org`, `practice_id = orgs.managed_by`, `mode = 'full'`, ordered `status = 'active' desc, started_at desc`, limit 1 — still found after an end without handover)
  - `private.is_managed(p_org uuid) returns boolean` (`orgs.managed_by is not null`)
  - `private.org_contact(p_org uuid) returns members` — unmanaged: the active `role = 'owner'` member, oldest first (exactly today's "pick the owner" lookup); managed: the active seat of `mandate(p_org).engagement_partner_id`'s user, else the oldest active `acts_as_owner` seat
  - `private.create_org_core(p_name text, p_email text, p_phone text, p_locations jsonb, p_vat_registered boolean, p_is_sample boolean) returns uuid` (org + locations, no member; `created_by = auth.uid()`); `public.create_org` unchanged signature and behaviour, calling core then inserting the owner
  - `private.orgs_guard()` also raises `That cannot be changed here.` (42501) for `authenticated`/`anon` changes to `managed_by`, `director_confirmed_at`, `read_only_at`, `retain_until`, `send_mode`
  - `tests.managed_org(p_practice uuid, p_name text default 'Managed Test Ltd') returns uuid` — as postgres with the first active partner's claims: `create_org_core(p_name, 'books@firm.example.test', null, '[]', true, false)`, `managed_by`, `identity_status = 'pending'`, an active full `practice_clients` row (`billing 'practice'`, `initiated_by 'practice'`, `engagement_partner_id` = that partner, `started_at now()`), and an `admin`/`acts_as_owner` seat with all 16 flags for each active partner and manager (inside `set_config('counta.seat_sync','on',true)` … `''`)
- Produces (TS): `export function actsAsOwner(inv: Inventory | undefined): boolean` in `src/state/session.tsx` (`me.role === 'owner' || me.acts_as_owner === true`); `can()` returns true when `actsAsOwner(inv)`; `MeRow.acts_as_owner?: boolean`; `Org.managed_by?: string | null; director_confirmed_at?: string | null; read_only_at?: string | null; retain_until?: string | null; send_mode?: 'send' | 'download_only'`.

- [ ] **Step 1: Write the failing test** — `supabase/tests/sql/01_owner_resolver.sql`

```sql
-- test: acts_as_owner_check
perform tests.throws($q$insert into members (org_id, email, display_name, role, status, practice_id, acts_as_owner) values (...,'accountant','active',...,true)$q$, '23514%');
-- test: perm_of_acting_owner      (o := tests.managed_org(tests.practice(partner,'Firm',true)); seat := the partner's seat)
assert private.perm_of(seat, 'owner') and private.perm_of(seat, 'make_payments'), 'perm_of_acting_owner: owner and all flags';
-- test: is_owner_acting
perform tests.as_user(partner); assert private.is_owner(o), 'is_owner_acting: acting owner counts';
perform tests.as_user(staff_user); assert not private.is_owner(ordinary_org), 'is_owner_acting: staff does not';
-- test: orgs_guard_new_columns   (as the ordinary owner, each of the five columns)
perform tests.throws($q$update orgs set send_mode = 'download_only' where id = ...$q$, '%That cannot be changed here.%');
-- test: org_contact
assert (private.org_contact(ordinary_org)).role = 'owner', 'org_contact: owner when unmanaged';
assert (private.org_contact(o)).user_id = partner and (private.org_contact(o)).acts_as_owner, 'org_contact: engagement partner seat when managed';
-- test: mandate_and_is_managed
assert private.is_managed(o) and (private.mandate(o)).mode = 'full' and not private.is_managed(ordinary_org), 'mandate_and_is_managed';
-- test: create_org_core_no_member
assert (select count(*) from members where org_id = core_org) = 0 and (select name from locations where org_id = core_org and is_main) = 'Main store', 'create_org_core_no_member';
-- test: full_needs_practice_billing / one_full_per_org
perform tests.throws($q$insert into practice_clients (..., mode, billing) values (..., 'full', 'business')$q$, '23514%');
perform tests.throws($q$insert into practice_clients (...second active full row for o...)$q$, '23505%');
-- test: helpers_revoked
assert not has_function_privilege('authenticated', 'private.acts_as_owner(uuid,uuid)', 'execute')
   and not has_function_privilege('authenticated', 'private.org_contact(uuid)', 'execute')
   and not has_function_privilege('authenticated', 'private.mandate(uuid)', 'execute')
   and not has_function_privilege('authenticated', 'private.is_managed(uuid)', 'execute')
   and not has_function_privilege('authenticated', 'private.create_org_core(text,text,text,jsonb,boolean,boolean)', 'execute'), 'helpers_revoked';
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash supabase/tests/run_tests.sh 01_owner`
Expected: `FAIL 01_owner_resolver.sql: ERROR:  expected error like 23514%, got 42703: column "acts_as_owner" of relation "members" does not exist`

- [ ] **Step 3: Implement `20261124000100_owner_resolver.sql` and `tests.managed_org`** as listed in Interfaces (redefine `perm_of`, `is_owner`, `orgs_guard`, `create_org` from `fn_dump.sh` output).

- [ ] **Step 4: Run the SQL tests and the golden check**

Run: `bash supabase/tests/run_tests.sh && bash supabase/tests/golden/run.sh check`
Expected: `ALL PASS (2 files)`, `golden OK (136 cases)`

- [ ] **Step 5: Write the failing frontend check**

Run: `grep -rnoE "role\s*(===|!==|==|!=)\s*'owner'" src | cut -d: -f1 | sort | uniq -c`
Expected after the change (exactly these 5 lines; today it lists 15 files):
```
      2 src/pages/inventory/Counts.tsx
      1 src/pages/settings/Partners.tsx
      2 src/pages/settings/Team.tsx
      1 src/practice/Join.tsx
      1 src/state/session.tsx
```
Kept on purpose: `Counts.tsx:83,87` and `Team.tsx:38,177` test another member's role; `Join.tsx:37` and `Partners.tsx:22` connect a business to a practice or partner, which a managed business may not do; `session.tsx` is `actsAsOwner` itself.

- [ ] **Step 6: Implement** `actsAsOwner`/`can()` and replace every other site with `actsAsOwner(inv)` (keeping the `|| role === 'manager'/'admin'` and `can(...)` parts beside it). `AppShell.tsx:250-251`: `owner = actsAsOwner(inv)`; role label `Acting owner · <first name>` when `inv.me.acts_as_owner`, `Owner view` for the real owner.

- [ ] **Step 7: Verify**

Run: the Step 5 grep, then `./node_modules/.bin/tsc -b --noEmit && ./node_modules/.bin/vite build && git checkout -- tsconfig.tsbuildinfo`
Expected: the 5 lines above; tsc silent; vite `✓ built`

- [ ] **Step 8: Commit**

```bash
git add supabase/migrations/20261124000100_owner_resolver.sql supabase/tests/sql/01_owner_resolver.sql supabase/tests/harness/helpers.sql supabase/tests/golden/added_keys.txt src/state/session.tsx src/lib/types.ts src/shell/AppShell.tsx src/pages
git commit -m "Owner resolver: acting owners, managed businesses, org contact, create_org core" -m "$TRAILER"
```

---

### Task 3: Sweep every owner comparison in SQL onto the resolver

**Files:**
- Create: `supabase/migrations/20261124000200_owner_sweep.sql`
- Create: `supabase/tests/sql/02_owner_sweep.sql`
- Create: `supabase/tests/golden/sweep_manifest.tsv`
- Modify: `supabase/tests/golden/run.sh` (add `sweep` mode)

**Interfaces:**
- Consumes: `owner_functions.txt` (117 functions; authoritative — the spec's known-site list is a subset), `fn_dump.sh`, Task 2 helpers.
- Produces: redefinitions only (no new names). `sweep_manifest.tsv` lines `<schema.function>\t<category>\t<matched snippet>` with category `perm_of | acts_as_owner | org_contact | keep`. `golden/run.sh sweep` → for every function whose latest definition still matches either enumeration regex, every match must appear in the manifest as `keep`; prints `sweep OK (<n> kept)`.

- [ ] **Step 1: Write the failing test** — `supabase/tests/sql/02_owner_sweep.sql` (o := `tests.managed_org(...)`, acting as the partner)

```sql
-- test: sweep_user_facing
assert (public.get_team(o)->>'is_owner')::boolean, 'sweep_user_facing: get_team is_owner';
assert (public.portal_logins(o)->>'can_manage')::boolean, 'sweep_user_facing: portal_logins can_manage';
assert coalesce(tests.error_of($q$select public.close_year(<o>, current_date)$q$), '') not like '%Only the owner%', 'sweep_user_facing: close_year passes owner check';
-- test: sweep_svc
perform tests.as_service();
assert coalesce(tests.error_of($q$select public.svc_identity_nin(<partner>, <o>, '1234', 'Ada', null, 'Eze')$q$), '') not like '%Only the owner%', 'sweep_svc: svc_identity_nin owner check';
-- test: sweep_recipient
assert public.get_alert_prefs(o)->'owner'->>'email' = 'partner@firm.example.test', 'sweep_recipient: alert prefs contact';
perform private.alert_send(o, 'test', 'k1', array['email'], '{"title":"T","body":"B"}');
assert (select to_address from messages where org_id = o and template = 'alert') = 'partner@firm.example.test', 'sweep_recipient: alert email to org_contact';
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash supabase/tests/run_tests.sh 02_owner`
Expected: `FAIL 02_owner_sweep.sql: ERROR:  sweep_user_facing: get_team is_owner`

- [ ] **Step 3: Implement the sweep.** `bash supabase/tests/harness/run.sh && bash supabase/tests/harness/fn_dump.sh $(cat supabase/tests/golden/owner_functions.txt)` gives the latest definitions. Classify every match and record it in the manifest:
  - the caller's/actor's own authority (`m.role = 'owner'`, `m.role <> 'owner'`, `role in ('owner','manager')` for the caller) → `perm_of`: `private.perm_of(m, 'owner')` / `not private.perm_of(m, 'owner')` / `(m.role in (...) or m.acts_as_owner)`;
  - a `svc_*` check on `p_user`/`p_member` → `acts_as_owner`: `private.acts_as_owner(p_org, p_user)` (or `perm_of` on the fetched member row);
  - choosing who receives or acts (`select … from members where … role = 'owner' … limit 1`) → `org_contact`: `private.org_contact(p_org)`;
  - another member's role, a role parameter, listing order, admin-portal display, the real owner's identity (`practice_client` owner display, `perm_of`/`acts_as_owner`/`org_contact`/`role_perms`/`practice_sync_seats` themselves, `invite_member` refusing `p_role = 'owner'`) → `keep`.
  Put only functions with at least one non-`keep` change in the migration, each as its full latest definition with the substitutions and nothing else.

- [ ] **Step 4: Run tests, golden and sweep checks**

Run: `bash supabase/tests/run_tests.sh && bash supabase/tests/golden/run.sh check && bash supabase/tests/golden/run.sh sweep`
Expected: `ALL PASS (3 files)`, `golden OK (136 cases)`, `sweep OK (<n> kept)`

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261124000200_owner_sweep.sql supabase/tests/sql/02_owner_sweep.sql supabase/tests/golden
git commit -m "Owner sweep: every owner comparison goes through perm_of, acts_as_owner or org_contact" -m "$TRAILER"
```

---

### Task 4: Seats, guards, departed staff, kill switch, identity and KYC

**Files:**
- Create: `supabase/migrations/20261124000300_seats_guards.sql`
- Create: `supabase/tests/sql/03_seats_guards.sql`
- Modify: `supabase/tests/harness/helpers.sql` (`tests.managed_org` calls `private.practice_sync_seats` instead of inserting seats)
- Modify: `supabase/tests/golden/added_keys.txt` (append `mandate_suspended_at`)
- Modify: `supabase/functions/mono/index.ts:472-494` (`cacSearch`), `:496-528` (`cacSelect`), `:668-674` (actions)

**Interfaces:**
- Consumes: Task 2 columns and helpers.
- Produces:
  - `private.practice_sync_seats(p_client uuid) returns void` — sets `counta.seat_sync` to `'on'` and back to `''` before every return; active full → wanted seats `role 'admin'`, `acts_as_owner true`, `perm_overrides = private.role_template('admin')`; active involved → `role 'accountant'`, `acts_as_owner false`; every sync calls `private.apply_member_perms` on each wanted seat; unwanted practice seats disabled whatever their role; not active → disable all practice seats except, when `end_kind = 'ended'`, the engagement partner's seat (stays active).
  - `public.practice_update_member` resyncs clients where `status = 'active' or end_kind = 'ended'`.
  - trigger `members_mandate_guard` (BEFORE INSERT OR UPDATE on `members`) → `private.members_mandate_guard()`: when `current_setting('counta.seat_sync', true) = 'on'` allow; setting or changing `acts_as_owner` raises `Only the practice link sets that.` (42501) in any org; in a managed org an active/invited row whose `practice_id` is not `managed_by` raises `Under full mandate only the firm's people work in this business.` (42501), and any insert or change to `role, status, user_id, practice_id, perm_overrides, p_*` raises `Under full mandate the firm's places change from the accountant portal.` (42501).
  - trigger `practice_clients_guard` (BEFORE INSERT OR UPDATE OF `org_id, practice_id, status`) → `private.practice_clients_guard()`: a managed org linked to a practice other than `managed_by` with status `invited|requested|active` raises `This business is run by its accountant under full mandate and cannot connect to another practice.` (42501).
  - trigger `practice_requests_guard` (BEFORE INSERT on `practice_requests`): client `mode = 'full'` raises `Requests are not sent to a full-mandate client.`
  - trigger `subscription_charges_guard` (BEFORE INSERT): managed org with `practice_id is null` raises `Under full mandate the practice pays for Counta.`
  - `private.require_not_managed(p_org uuid) returns void` raising `Under full mandate this is done from the accountant portal.` (42501); called first in `public.invite_member`, `public.subscription_start`, `public.subscription_method`; `public.practice_end` raises `Use handover or end the mandate for a full-mandate client.` when `mode = 'full'`.
  - `practices.mandate_suspended_at timestamptz`; `private.practice_can_full(p_practice uuid) returns boolean` = `private.partner_verified(p_practice) and mandate_suspended_at is null`.
  - `public.svc_identity_nin`: managed org with no submitted CAC `kyc_profiles` row returns `{"verified": false, "reason": "cac_required"}`; with CAC data unchanged.
  - `public.kyc_submit(p jsonb)`: `p->>'org_id'` given → `k := private.kyc_row(auth.uid(), org)` and `private.is_owner(org)` required (`Only the owner submits the business profile.`); absent → today's behaviour.
  - mono `cac_search {query, org_id?}` / `cac_select {cac_id, org_id?}`: with `org_id`, first `kyc_draft({p_org})` as the user (owner check), then `svc_kyc_store(..., p_org)`.

- [ ] **Step 1: Write the failing test** — `supabase/tests/sql/03_seats_guards.sql`

```sql
-- test: sync_full_seats            (role_permissions sets admin make_payments=false, then public.practice_assign(c, staff_pm, true) resyncs)
assert (select role = 'admin' and acts_as_owner and p_make_payments and p_manage_team from members where org_id = o and user_id = partner), 'sync_full_seats: admin, acting owner, all flags';
-- test: sync_involved_seats
assert (select role = 'accountant' and not acts_as_owner from members where org_id = ordinary and user_id = partner), 'sync_involved_seats';
-- test: departed_staff_disabled    (partner disables manager via practice_update_member)
assert not exists (select 1 from members where user_id = manager and status = 'active' and practice_id = pr), 'departed_staff_disabled: every client seat';
-- test: seat_sync_not_left_on
perform public.practice_assign(c, staff_pm, true);
assert coalesce(current_setting('counta.seat_sync', true), '') <> 'on', 'seat_sync_not_left_on';
-- test: guard_blocks_seat_edits
perform tests.throws($q$select public.update_member(<seat>, '{"role":"manager"}')$q$, '%change from the accountant portal%');
perform tests.throws($q$insert into members (org_id, email, display_name, role, status) values (<o>, 'x@example.test', 'X', 'staff', 'active')$q$, '%only the firm''s people%');
perform tests.throws($q$update members set acts_as_owner = true where id = <ordinary admin>$q$, '%Only the practice link sets that.%');
-- test: managed_cannot_connect
perform tests.throws($q$select public.business_invite_accountant(<o>, '{"email":"acc@example.test"}')$q$, '%cannot connect to another practice%');
perform tests.throws($q$select public.practice_request_create(<c>, '{"title":"Bank statement"}')$q$, '%Requests are not sent%');
-- test: blocked_under_full_mandate
perform tests.throws($q$select public.invite_member(<o>, 'X', 'x@example.test', 'staff')$q$, '%done from the accountant portal%');
perform tests.throws($q$select public.subscription_start(<o>, '{}')$q$, '%done from the accountant portal%');
perform tests.throws($q$select public.practice_end(<c>)$q$, '%Use handover or end the mandate%');
perform tests.throws($q$insert into subscription_charges (org_id, ...) values (<o>, ...)$q$, '%practice pays for Counta%');
-- test: nin_cac_required
assert public.svc_identity_nin(partner, o, '1234', 'Ada', null, 'Eze')->>'reason' = 'cac_required', 'nin_cac_required';
-- test: kyc_for_managed_org
perform tests.throws($q$select public.kyc_submit('{"org_id":"<ordinary org the partner does not own>"}')$q$, '%Only the owner submits%');
assert public.svc_kyc_store(partner, 'search', '{"query":"x"}', o) is not null and exists (select 1 from kyc_profiles where org_id = o), 'kyc_for_managed_org: profile bound to org';
-- test: practice_can_full
assert private.practice_can_full(pr), 'practice_can_full: verified partner';
update practices set mandate_suspended_at = now() where id = pr; assert not private.practice_can_full(pr), 'practice_can_full: suspended';
assert not private.practice_can_full(unverified_pr), 'practice_can_full: unverified';
-- test: new_helpers_revoked (require_not_managed, practice_can_full, members_mandate_guard, practice_clients_guard)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash supabase/tests/run_tests.sh 03_seats`
Expected: `FAIL 03_seats_guards.sql: ERROR:  new row for relation "members" violates check constraint "members_acts_as_owner_check"` (today's sync turns the acting seat into an accountant)

- [ ] **Step 3: Implement** the migration as in Interfaces (redefine from `fn_dump.sh`), the helper change and the mono change.

- [ ] **Step 4: Verify**

Run: `bash supabase/tests/run_tests.sh && bash supabase/tests/golden/run.sh check && deno check --node-modules-dir=none supabase/functions/mono/index.ts`
Expected: `ALL PASS (4 files)`, `golden OK (136 cases)`, `Check supabase/functions/mono/index.ts`

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261124000300_seats_guards.sql supabase/tests/sql/03_seats_guards.sql supabase/tests/harness/helpers.sql supabase/tests/golden/added_keys.txt supabase/functions/mono/index.ts
git commit -m "Full-mandate seats and guards: admin acting-owner seats, departed staff, kill switch, KYC for managed businesses" -m "$TRAILER"
```

---

### Task 5: Activity log

**Files:**
- Create: `supabase/migrations/20261124000400_activity_log.sql`
- Create: `supabase/tests/sql/04_activity_log.sql`

**Interfaces:**
- Consumes: `orgs.managed_by`, `orgs.read_only_at` (Task 2).
- Produces:
  - `public.activity_log` (`id bigint generated always as identity primary key`, `org_id uuid not null references orgs(id) on delete cascade`, `practice_id uuid`, `at timestamptz not null default now()`, `actor_user uuid`, `actor_member uuid`, `actor_name text`, `source text check (source in ('row','event'))`, `action text not null`, `entity text`, `entity_id text`, `label text`, `before jsonb`, `after jsonb`, `changed text[]`); indexes `(org_id, at desc)`, `(practice_id, at desc)`.
  - trigger `activity_log_immutable` → `private.activity_guard()`: update raises `The activity log cannot be changed.`; delete raises the same unless `pg_trigger_depth() > 1` (an org's cascade delete).
  - `private.activity_exempt() returns text[]` = `{activity_log, messages, notifications, alert_log, usage_events, ai_logs, shop_hits, payment_events, org_counters, stock_levels, agent_runs, guide_progress, lookup_failures, sso_logins, whatsapp_sessions, chat_links, voice_calls, integration_events, prism_callbacks, kyc_profiles}`.
  - `private.redact_key(p_key text) returns boolean` — `p_key ~* '(^|_)(token|secret|hash|password|otp|nin|api_key)(_|$)'`.
  - `private.redact(p jsonb) returns jsonb` — top-level keys: `redact_key` → `"[redacted]"`; values whose text exceeds 4096 chars → `left(text, 4096) || '…[truncated]'`.
  - `private.set_actor(p_user uuid) returns void` — `set_config('counta.actor', p_user::text, true)`.
  - `private.activity_row()` AFTER INSERT OR UPDATE OR DELETE FOR EACH ROW, trigger name `activity_row`: org id = `row.org_id` (`row.id` for `orgs`); return at once unless the org is managed or read-only (PK lookup; an org row not found — deleted by this statement's cascade — also returns at once; for `orgs` itself use `OLD.read_only_at` on update so the statement that sets it is not blocked). Read-only and `auth.uid() is not null` → raise `This business is read-only: its engagement has ended. Its records are kept until <retain_until>.` (42501). Actor = `coalesce(auth.uid(), nullif(current_setting('counta.actor', true), '')::uuid)`; `actor_name` = the member's `display_name`, else the practice member's, else `Counta`. Insert: `after = redact(row)`; delete: `before = redact(row)`; update: only keys whose values differ (ignoring `updated_at`) in `before`/`after`/`changed`, no row when none. `label = coalesce(number, name, display_name, title, description)` truncated to 120; `entity = TG_TABLE_NAME`, `entity_id = row->>'id'`.
  - `private.activity_attach(p_table regclass) returns void` (drop + create the `activity_row` trigger); the migration's DO loop attaches it to `orgs`, `members` and every public base table with an `org_id` column not in `activity_exempt()`.
  - `private.activity_event(p_org uuid, p_action text, p_label text, p_meta jsonb default '{}') returns bigint` (source `event`, `after = p_meta`, practice from `managed_by` or `p_meta->>'practice_id'`).
  - `public.practice_activity(p_client uuid, p jsonb default '{}') returns jsonb` (`private.practice_client_require(p_client)`) and `public.org_activity(p_org uuid, p jsonb default '{}') returns jsonb` (`perm_of(me,'owner')` or `manage_team`): `p = {before?: bigint, limit?: 1..200 default 50, entity?: text}` → `{"rows":[{id, at, actor_name, source, action, entity, entity_id, label, before, after, changed}], "next_before": bigint|null}`.

- [ ] **Step 1: Write the failing test** — `supabase/tests/sql/04_activity_log.sql`

```sql
-- test: activity_trigger_coverage
assert not exists (select 1 from information_schema.columns c join information_schema.tables t using (table_schema, table_name)
  where c.table_schema = 'public' and c.column_name = 'org_id' and t.table_type = 'BASE TABLE'
    and c.table_name <> all (private.activity_exempt())
    and not exists (select 1 from pg_trigger g where g.tgrelid = ('public.' || c.table_name)::regclass and g.tgname = 'activity_row')),
  'activity_trigger_coverage: every org table has the trigger or is exempt';
-- test: activity_ordinary_silent
assert (select count(*) from activity_log where org_id = ordinary) = 0, 'activity_ordinary_silent';
-- test: activity_row_changes      (acting owner inserts then renames a customer in o)
assert (select count(*) from activity_log where org_id = o and entity = 'customers' and action = 'insert' and actor_user = partner) = 1, 'activity_row_changes: insert';
assert (select changed = '{name}' and before ? 'name' and not before ? 'phone' from activity_log where org_id = o and action = 'update'), 'activity_row_changes: changed keys only';
-- test: activity_redaction
assert private.redact_key('token_hash') and private.redact_key('nin_last4') and private.redact_key('api_key_secret') and private.redact_key('otp_hash') and private.redact_key('password'), 'activity_redaction: secrets';
assert not private.redact_key('opening_balance') and not private.redact_key('margin_threshold') and not private.redact_key('pinned'), 'activity_redaction: no over-match';
assert private.redact(jsonb_build_object('notes', repeat('x', 5000)))->>'notes' like '%…[truncated]', 'activity_redaction: 4 KB cap';
-- test: activity_immutable
perform tests.throws($q$update activity_log set label = 'x'$q$, '%cannot be changed%');
perform tests.throws($q$delete from activity_log$q$, '%cannot be changed%');
delete from orgs where id = o; assert (select count(*) from activity_log where org_id = o) = 0, 'activity_immutable: org delete cascades';
-- test: activity_actor_setting   (service role, set_actor(partner), insert in o)
assert (select actor_user from activity_log where org_id = o order by id desc limit 1) = partner, 'activity_actor_setting';
-- test: read_only_enforced       (update orgs set read_only_at = now(), retain_until = current_date + 1825)
perform tests.as_user(partner); perform tests.throws($q$select public.save_customer(<o>, '{"name":"New"}')$q$, '42501%');
perform tests.as_service(); assert tests.error_of($q$insert into customers (org_id, name) values (<o>, 'System')$q$) is null, 'read_only_enforced: system writes pass';
-- test: activity_reads
assert jsonb_array_length(public.practice_activity(c)->'rows') > 0, 'activity_reads: practice';
perform tests.as_user(other_practice_partner); perform tests.throws($q$select public.practice_activity(<c>)$q$, '%not on this practice%');
-- test: activity_helpers_revoked (activity_event, activity_row, redact, redact_key, set_actor, activity_attach, activity_exempt)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash supabase/tests/run_tests.sh 04_activity`
Expected: `FAIL 04_activity_log.sql: ERROR:  function private.activity_exempt() does not exist`

- [ ] **Step 3: Implement `20261124000400_activity_log.sql`** as in Interfaces.

- [ ] **Step 4: Verify**

Run: `bash supabase/tests/run_tests.sh && bash supabase/tests/golden/run.sh check`
Expected: `ALL PASS (5 files)`, `golden OK (136 cases)`

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261124000400_activity_log.sql supabase/tests/sql/04_activity_log.sql
git commit -m "Activity log: every write in a managed or read-only business, events, read-only enforcement" -m "$TRAILER"
```

---

### Task 6: Outbound gate and branding resolver (SQL)

**Files:**
- Create: `supabase/migrations/20261124000500_outbound_branding.sql`
- Create: `supabase/tests/sql/05_outbound_branding.sql`
- Modify: `supabase/tests/golden/added_keys.txt` (append `firm_org_id white_label pay_online`)

**Interfaces:**
- Consumes: `private.mandate`, `private.org_contact`, `private.activity_event`, `private.wa_number(p_user, p_org)`, `private.clean_phone`.
- Produces:
  - `messages_status_check` adds `'suppressed'`.
  - `practices.firm_org_id uuid references orgs(id) on delete set null` (consumed by Tasks 13, 14).
  - `private.firm_addresses(p_org uuid) returns text[]` — `lower(trim())` of the managing practice's active members' emails, `practices.email`, `mandate(p_org).alert_email`.
  - `private.outbound_check(p_org uuid, p_channel text, p_kind text, p_to text) returns text` — null when the org is neither managed nor read-only; else, in order: `read_only_at` → `'read_only'`; `p_channel = 'call'` → `'calls_off'`; `p_kind in ('alert','invite','practice')`: email allowed when `lower(trim(p_to)) = any(firm_addresses)`, WhatsApp allowed when `p_to` equals `private.clean_phone` of `wa_number(seat.user_id, p_org).phone` for an active seat with `practice_id = managed_by`, else `'not_firm_address'`; any other template: `send_mode = 'download_only'` → `'download_only'`, else null. (Task 11 adds the pending-handover address.)
  - trigger `messages_outbound` (BEFORE INSERT on `messages`) → `private.messages_outbound()`: `not_firm_address` on an email `alert` → `to_address := coalesce(lower(trim(mandate.alert_email)), lower(org_contact.email))`, `params.readdressed = true`; any other reason → `status 'suppressed'`, `error 'Not sent: <reason>'`, `activity_event(org, 'message_suppressed', template, {template, channel, reason})`.
  - trigger `voice_calls_mandate` (BEFORE INSERT on `voice_calls`) → managed or read-only: `activity_event(org, 'call_suppressed', coalesce(topic, kind), {kind})`, return null.
  - `private.alert_prefs(p_org)`: `owner_calls` and `customer_calls` false when `managed_by is not null`.
  - `private.queue_message(...)`: calls `private.call_function('messaging', …)` only when the inserted row's status is `'queued'`.
  - `private.require_outbound(p_org uuid, p_channel text, p_kind text) returns void` — raises (42501) `This business is read-only: its engagement has ended.` | `This business is set to download only. Download the document and send it yourself.` | `Counta does not make calls for a business run under full mandate.` | `Under full mandate Counta only writes to the firm.`; called after the permission check in `public.send_document`, `public.send_reminder`, `public.send_statement`, `public.return_bill`, `public.reject_supplier_invoice` (channel/template of the message) and `public.prepare_reminder_call`, `public.prepare_vendor_call` (channel `'call'`).
  - `private.white_label(p_org uuid, p_customer uuid default null) returns boolean` — `is_managed(p_org)` or exists an active `mode = 'full'` `practice_clients` row with `fee_customer_id = p_customer` whose practice has `firm_org_id = p_org`.
  - `private.org_brand(p_org uuid, p_customer uuid default null) returns jsonb` (drop the one-argument function first) — today's keys plus `white_label` and `pay_online` (`private.payments_open(p_org)`).
  - `private.sale_json` passes `s.customer_id` to `org_brand`; `public.shop_catalog` adds `shop.white_label`.
  - `public.svc_message(p_id uuid)`: when `outbound_check` is not null set `status 'suppressed'` and return null; else adds `org` = `org_brand(org, customer_id)`, `managed` = `is_managed(org)`, `alert_to_allowed` = `outbound_check(...) is null`.

- [ ] **Step 1: Write the failing test** — `supabase/tests/sql/05_outbound_branding.sql` (o managed, engagement partner `partner@firm.example.test`)

```sql
-- test: outbound_ordinary_untouched
assert (private.queue_message(ordinary, 'email', 'c@example.test', 'document', 'Invoice', '{}', null, null, null)).status = 'queued', 'outbound_ordinary_untouched';
-- test: outbound_alert_readdressed
insert into messages (org_id, channel, to_address, template, params) values (o, 'email', 'client-owner@example.test', 'alert', '{}');
assert (select to_address from messages where org_id = o and template = 'alert') = 'partner@firm.example.test', 'outbound_alert_readdressed';
-- test: outbound_firm_address_case
insert ... to_address ' Partner@Firm.Example.Test ' ...;
assert (select status = 'queued' and coalesce(params->>'readdressed','') = '' from messages where ...), 'outbound_firm_address_case: firm address kept';
-- test: outbound_download_only
update orgs set send_mode = 'download_only' where id = o; insert a 'document' email;
assert (select status = 'suppressed' and error = 'Not sent: download_only' from messages where ...), 'outbound_download_only';
assert exists (select 1 from activity_log where org_id = o and action = 'message_suppressed'), 'outbound_download_only: logged';
perform tests.as_user(partner); perform tests.throws($q$select public.send_document(<sale>, 'email')$q$, '%set to download only%');
-- test: outbound_read_only        (read_only_at set: alert to firm address is suppressed too)
-- test: outbound_calls
insert into voice_calls (org_id, kind, to_number, status) values (o, 'reminder', '+2348000000000', 'queued');
assert (select count(*) from voice_calls where org_id = o) = 0 and exists (select 1 from activity_log where org_id = o and action = 'call_suppressed'), 'outbound_calls';
assert not (private.alert_prefs(o)->>'owner_calls')::boolean and not (private.alert_prefs(o)->>'customer_calls')::boolean, 'outbound_calls: prefs off';
-- test: svc_message_flags
perform tests.as_service(); r := public.svc_message(<queued alert to partner>);
assert (r->>'managed')::boolean and (r->>'alert_to_allowed')::boolean and (r->'org'->>'white_label')::boolean, 'svc_message_flags';
-- test: white_label_fee_customer  (firm org F, practices.firm_org_id = F, full client fee_customer_id = cu)
assert private.white_label(F, cu) and not private.white_label(F, other_cu) and not private.white_label(F), 'white_label_fee_customer';
-- test: org_brand_keys
assert not (private.org_brand(ordinary)->>'white_label')::boolean and (private.org_brand(ordinary)->>'pay_online')::boolean = private.payments_open(ordinary), 'org_brand_keys';
assert (public.public_document(<token of F's invoice to cu>)->'org'->>'white_label')::boolean, 'org_brand_keys: public document';
assert (public.shop_catalog(<o shop slug>)->'shop'->>'white_label')::boolean, 'org_brand_keys: shop';
-- test: outbound_helpers_revoked (firm_addresses, outbound_check, require_outbound, white_label, org_brand, messages_outbound, voice_calls_mandate)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash supabase/tests/run_tests.sh 05_outbound`
Expected: `FAIL 05_outbound_branding.sql: ERROR:  outbound_alert_readdressed`

- [ ] **Step 3: Implement `20261124000500_outbound_branding.sql`** as in Interfaces.

- [ ] **Step 4: Verify**

Run: `bash supabase/tests/run_tests.sh && bash supabase/tests/golden/run.sh check`
Expected: `ALL PASS (6 files)`, `golden OK (136 cases)`

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261124000500_outbound_branding.sql supabase/tests/sql/05_outbound_branding.sql supabase/tests/golden/added_keys.txt
git commit -m "Outbound gate and branding resolver: silence, download-only, white label per business and fee customer" -m "$TRAILER"
```

---

### Task 7: Messaging function and white-labelled documents in the app

**Files:**
- Modify: `supabase/functions/messaging/wording.ts:119,128,158` and move in `senderAddress`, `displayName`, `waText` from `supabase/functions/messaging/index.ts:86-94,134-143`
- Modify: `supabase/functions/messaging/index.ts:97-120` (`sendEmail`), `:156-180` (`sendWhatsApp`), `:182-216` (`deliver`)
- Create: `supabase/functions/messaging/wording_test.ts`
- Modify: `src/pages/public/Public.tsx:12-30` (`Frame`), `:75-102` (pay block); `src/lib/docPdf.ts:222,269,329,387`; `src/lib/printer.ts:83`; `src/pages/public/ShopPage.tsx:187`; `src/pages/SettingsBooks.tsx:123`
- Create: `scripts/ui-check.mjs`

**Interfaces:**
- Consumes: `svc_message` keys `managed`, `alert_to_allowed`, `org.white_label`, `org.pay_online`, `org.payment_details`; `shop_catalog` `shop.white_label` (Task 6).
- Produces:
  - `wording.ts`: `Msg.org.white_label?: boolean`; `export function displayName(name: string, whiteLabel?: boolean): string` (`<name>` when white label, else `<name> via Counta`); `export function senderAddress(raw: string): string`; `export function waText(m: Msg): string` (white label → no footer line); `emailHtml` drops the footer paragraph when `m.org.white_label`; alert footer (white label) `Sent for <biz>. Choose which alerts you get in Settings, Alerts.`; practice footer (white label or `params.white_label`) `If you were not expecting this, you can ignore the email.`
  - `deliver()`: `m.managed === true && m.alert_to_allowed !== true` → `svc_message_update(id, 'failed', null, 'Not sent: full-mandate rules.')`, no send; Meta provider + `m.org.white_label` + WhatsApp → `failed`, `Unbranded WhatsApp is not available yet. Send it by email.`
  - `node scripts/ui-check.mjs <file> <testid>...` → exit 1 printing `missing in <file>: <ids>` unless each literal `data-testid="<id>"` occurs.
  - testids: `public-powered-by` (only when `!org.white_label`), `public-pay-online` (pay buttons, only when `org.pay_online`), `public-bank-details` (shows `org.payment_details` when `!org.pay_online`), `shop-powered-by` (only when `!shop.white_label`).

- [ ] **Step 1: Write the failing tests**

```ts
// supabase/functions/messaging/wording_test.ts
Deno.test('display_name_white_label', () => {
  assertEquals(displayName('Ada Foods Ltd', true), 'Ada Foods Ltd');
  assertEquals(displayName('Ada Foods Ltd', false), 'Ada Foods Ltd via Counta');
});
Deno.test('email_white_label_has_no_counta', () => {
  const m = { id: '1', channel: 'email', to_address: 'c@example.test', template: 'document', params: { doc_label: 'Invoice', number: 'INV-1', total: 100 }, org: { name: 'Ada Foods Ltd', white_label: true } } as Msg;
  assert(!emailHtml(m).includes('Counta') && !emailText(m).includes('Counta') && !waText(m).includes('Counta'));
});
Deno.test('email_branded_by_default', () => { assert(emailHtml({ ...m, org: { name: 'Ada Foods Ltd' } }).includes('Sent for Ada Foods Ltd by Counta')); });
```
and `node scripts/ui-check.mjs src/pages/public/Public.tsx public-powered-by public-pay-online public-bank-details && node scripts/ui-check.mjs src/pages/public/ShopPage.tsx shop-powered-by`.

- [ ] **Step 2: Run them to verify they fail**

Run: `deno test --node-modules-dir=none --allow-read supabase/functions/messaging/wording_test.ts`
Expected: FAIL — `does not provide an export named 'displayName'`; the ui-check fails with `node: cannot find module scripts/ui-check.mjs`.

- [ ] **Step 3: Implement** as in Interfaces. `docPdf.ts` footers end `· made by Counta` only when `!o.white_label`; `printer.ts:83` pushes `Powered by Counta` only when `!s.org?.white_label`; `SettingsBooks.tsx:123` shows `Sends from <name> <sender>` when `inv.org.managed_by`, else today's text.

- [ ] **Step 4: Verify**

Run: `deno test --node-modules-dir=none --allow-read supabase/functions/messaging/wording_test.ts && deno check --node-modules-dir=none supabase/functions/messaging/index.ts && node scripts/ui-check.mjs src/pages/public/Public.tsx public-powered-by public-pay-online public-bank-details && node scripts/ui-check.mjs src/pages/public/ShopPage.tsx shop-powered-by && ./node_modules/.bin/tsc -b --noEmit && ./node_modules/.bin/vite build && git checkout -- tsconfig.tsbuildinfo`
Expected: `ok | 3 passed`, `Check …index.ts`, ui-check silent, tsc silent, `✓ built`

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/messaging scripts/ui-check.mjs src/pages/public/Public.tsx src/pages/public/ShopPage.tsx src/lib/docPdf.ts src/lib/printer.ts src/pages/SettingsBooks.tsx
git commit -m "White label: no Counta sender name, footers or pay buttons for managed businesses and fee invoices; fail closed on full-mandate rules" -m "$TRAILER"
```

---

### Task 8: Due-diligence intake and conflicts check

**Files:**
- Create: `supabase/migrations/20261124000600_intake_conflicts.sql`
- Create: `supabase/tests/sql/06_intake_conflicts.sql`
- Modify: `supabase/tests/harness/helpers.sql` (add `tests.cleared_intake`)
- Modify: `supabase/tests/golden/added_keys.txt` (append `conflict_scan_books`)

**Interfaces:**
- Consumes: `private.practice_require`, `private.practice_client_require`, `private.name_match`, `private.name_score`, `private.identity_match`, `private.activity_exempt` (Task 5).
- Produces:
  - `practice_intakes` (`id`, `practice_id` not null, `status` `draft|engaged|declined` default `draft`, `mode_requested` `involved|full`, `legal_name` 2..160, `entity_type` `company|business_name|incorporated_trustees|partnership|individual`, `rc_number`, `tax_id`, `address` ≤300, `industry` ≤80, `risk_rating` `low|medium|high`, `risk_reason` ≤1000, `pep_present boolean default false`, `dd_incomplete boolean default false`, `conflict_status` `pending|none|hits|cleared|refused` default `pending`, `conflict_note`, `conflict_decided_by`, `conflict_decided_at`, `checked_at`, `authority_declared_by`, `authority_declared_at`, `authority_statement`, `authority_doc_path`, `client_id` → `practice_clients` on delete set null, `org_id` → `orgs` on delete set null, `retain_until date`, `created_by`, `created_at`, `updated_at`); `practice_intake_people` (`intake_id`, `practice_id`, `kind` `director|beneficial_owner|related`, `name` 2..120, `role` ≤80, `ownership_pct numeric(5,2)` 0..100, `nationality` ≤60, `is_pep`, `id_type` `nin|bvn|passport|drivers_licence|voters_card|cac|other`, `id_last4` check `^[A-Za-z0-9]{4}$`); `practice_intake_docs` (`kind` `cac|id|address|other`, `name`, `path` like `practice/<pid>/intake/<iid>/%`, `sha256` `^[0-9a-f]{64}$`, `added_by`); `practice_opposing_parties` (`practice_id`, `client_id`, `name`, `rc_number`, `note` ≤500); `practice_conflict_hits` (`intake_id`, `practice_id`, `kind` `client|prospect|related_party|opposing_party|books`, `matched_on` `rc_number|tax_id|name|person`, `subject`, `match_name`, `score numeric(4,2)`, `source_client_id`, `source_intake_id`, `source_opposing_id`); `practices.conflict_scan_books boolean not null default false`; FK `practice_clients.intake_id` → `practice_intakes(id)` on delete set null; `activity_exempt()` gains `practice_intakes`.
  - `private.fold_name(p text) returns text` = `regexp_replace(normalize(coalesce(p,''), NFD), '[̀-ͯ]', '', 'g')`; `private.norm_id(p text) returns text` = upper, non-alphanumerics removed, leading `RC|BN|IT` removed, null when empty; `private.has_id_number(p text) returns boolean` = `p ~ '[0-9]{5,}'`.
  - `private.intake_cleared(i practice_intakes) returns boolean` = `risk_rating is not null and conflict_status in ('none','cleared') and checked_at >= updated_at`.
  - `private.conflict_scan(p_intake uuid) returns integer` — replaces the intake's hits; every predicate filtered to the intake's `practice_id`: against this practice's current and former clients (`practice_clients` any status, via `orgs.name/business_name/rc_number/tin`), its other intakes, their people (`related_party`), its opposing parties, and — only when `conflict_scan_books` — `customers`/`vendors` of its active clients; RC/Tax ID by `norm_id` equality; company names by `name_match(fold_name(a), fold_name(b)) or name_score(fold_name(a), fold_name(b)) >= 0.75`; people by `identity_match(first token, middle tokens, last token of fold_name(person), jsonb_build_array(jsonb_build_object('name', fold_name(other))))`.
  - `private.intake_json(i practice_intakes, p_full boolean) returns jsonb`; trigger `practice_intakes_retention` (BEFORE DELETE on the three intake tables) raising `Due-diligence records are kept until <retain_until>.` while `retain_until is null or retain_until > current_date`.
  - trigger `practice_clients_intake` (AFTER INSERT OR UPDATE OF status on `practice_clients`): becomes `active` with no `intake_id` → insert a `draft` intake (`dd_incomplete true`, `legal_name/rc_number/tax_id` from the org, `client_id`, `org_id`) and set `intake_id`; with `intake_id` → intake `status 'engaged'`, `org_id`, `client_id`; becomes `ended|declined` → intake `retain_until = current_date + greatest(coalesce(retention_years,5),5) years`.
  - `private.practice_file_ok(p_name text) returns boolean` (`practice/<pid>/intake|letters/…`: any active member of `<pid>`; `practice/<pid>/exports/…`: partners only); documents-bucket policies `practice files read by practice members` (select) and `practice files upload by practice members` (insert) on `bucket_id = 'documents' and (storage.foldername(name))[1] = 'practice' and private.practice_file_ok(name)`; no delete policy.
  - RPCs (lead = partner or manager unless stated): `public.practice_intake_save(p_practice uuid, p jsonb) returns jsonb` (`p`: `id?`, the columns above, `people[]` replacing all; raises `Record only the last 4 characters of an ID number.` when a person has key `id_number`/`nin`/`bvn`, `id_last4` of another length, or `has_id_number` in `name`, `role` or `nationality`; any PEP → `pep_present true`, `risk_rating 'high'`; any change to name, RC, Tax ID or people → `conflict_status 'pending'`, decision cleared, `updated_at = now()`); `public.practice_intake(p_intake uuid) returns jsonb` (intake, people, docs, hits, letters); `public.practice_intakes(p_practice uuid, p jsonb default '{}') returns jsonb` (`p.status`); `public.practice_intake_doc_add(p_intake uuid, p jsonb) returns jsonb` (`{path, name, sha256, kind}`); `public.practice_opposing_save(p_practice uuid, p jsonb) returns jsonb` (`{id?, client_id?, name, rc_number?, note?, remove?}`); `public.practice_conflict_run(p_intake uuid) returns jsonb` (sets `checked_at`, `none|hits`); `public.practice_conflict_decide(p_intake uuid, p jsonb) returns jsonb` (partner only; `{outcome: 'cleared'|'refused', note}`, note ≥ 10 chars, needs `hits` and a run after the last edit; refused → `status 'declined'`, `retain_until = current_date + 5 years`); `public.practice_set_conflict_scan(p_practice uuid, p_on boolean) returns jsonb` (partner); `public.practice_intake_declare(p_intake uuid, p jsonb) returns jsonb` (partner; `{doc_path?}`; stores `authority_statement` = `I confirm that <firm> holds the written authority of <client> to set up and run its accounting records and tax affairs on its behalf under full mandate, as set out in the engagement letter, and that I am a partner of <firm>.`).
  - `public.practice_invite_client(p_practice uuid, p jsonb)`: requires `p->>'intake_id'` of this practice with `intake_cleared` and `mode_requested 'involved'` (`Finish the due diligence and conflicts check first.`), stores `intake_id`.
  - `tests.cleared_intake(p_practice uuid, p_name text, p_mode text default 'involved') returns uuid` (risk low, run, no hits).

- [ ] **Step 1: Write the failing test** — `supabase/tests/sql/06_intake_conflicts.sql`

```sql
-- test: intake_pep_forces_high
i := public.practice_intake_save(pr, '{"legal_name":"Kola Ventures Ltd","risk_rating":"low","people":[{"kind":"director","name":"Kola Ade","is_pep":true}]}')->>'id';
assert (select risk_rating = 'high' and pep_present from practice_intakes where id = i), 'intake_pep_forces_high';
-- test: intake_rejects_full_id_numbers          (Review Focus 4)
perform tests.throws($q$select public.practice_intake_save(<pr>, '{"legal_name":"X Ltd","people":[{"kind":"director","name":"Ada 12345678901"}]}')$q$, '%last 4 characters%');
perform tests.throws($q$... "people":[{"kind":"director","name":"Ada Eze","id_last4":"12345678901"}] ...$q$, '%last 4 characters%');
perform tests.throws($q$... "people":[{"kind":"director","name":"Ada Eze","nin":"12345678901"}] ...$q$, '%last 4 characters%');
assert tests.error_of($q$... "people":[{"kind":"director","name":"Ada Eze","id_type":"nin","id_last4":"8901"}] ...$q$) is null, 'intake_rejects_full_id_numbers: last 4 accepted';
-- test: conflict_diacritics_suffix_rc           (Review Focus 2; existing client org "OLA ADE FOODS LIMITED", rc_number '123456')
i := intake 'Ọlá Àdé Foods Ltd', rc_number 'RC 123456'; perform public.practice_conflict_run(i);
assert exists (select 1 from practice_conflict_hits where intake_id = i and matched_on = 'name' and kind = 'client'), 'conflict_diacritics_suffix_rc: name';
assert exists (select 1 from practice_conflict_hits where intake_id = i and matched_on = 'rc_number'), 'conflict_diacritics_suffix_rc: RC';
-- test: conflict_people_and_opposing
assert exists (... matched_on = 'person' and kind = 'related_party' ...) and exists (... kind = 'opposing_party' ...), 'conflict_people_and_opposing';
-- test: conflict_never_crosses_practices        (same RC as a client of another practice only)
assert (public.practice_conflict_run(i2)->>'conflict_status') = 'none', 'conflict_never_crosses_practices';
-- test: conflict_books_scan_setting             (prospect is a customer of an active client)
assert not exists (... kind = 'books' ...), 'conflict_books_scan_setting: off by default';
perform public.practice_set_conflict_scan(pr, true); perform public.practice_conflict_run(i);
assert exists (... kind = 'books' ...), 'conflict_books_scan_setting: on';
-- test: conflict_decide_rules
perform tests.as_user(manager); perform tests.throws($q$select public.practice_conflict_decide(<i>, '{"outcome":"cleared","note":"Different company"}')$q$, '%partner%');
perform tests.as_user(partner); perform tests.throws($q$... '{"outcome":"cleared","note":"short"}' ...$q$, '%10%');
-- test: intake_reedit_needs_rerun
perform public.practice_intake_save(pr, jsonb_build_object('id', i, 'legal_name', 'Kola Ventures Nigeria Ltd'));
assert (select conflict_status from practice_intakes where id = i) = 'pending' and not private.intake_cleared((select x from practice_intakes x where id = i)), 'intake_reedit_needs_rerun';
-- test: invite_needs_cleared_intake
perform tests.throws($q$select public.practice_invite_client(<pr>, '{"email":"o@example.test","intake_id":"<uncleared>"}')$q$, '%due diligence%');
-- test: business_link_creates_draft_intake      (business_invite_accountant then practice_accept by the practice)
assert (select dd_incomplete and status = 'engaged' from practice_intakes where client_id = c), 'business_link_creates_draft_intake';
-- test: intake_retention
perform tests.throws($q$delete from practice_intakes where id = <i>$q$, '%kept until%');
-- test: practice_files
assert private.practice_file_ok('practice/' || pr || '/intake/' || i || '/cac.pdf') (as partner) and not (as another practice's partner), 'practice_files';
-- test: intake_helpers_revoked (fold_name, norm_id, has_id_number, intake_cleared, conflict_scan, intake_json, practice_file_ok)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash supabase/tests/run_tests.sh 06_intake`
Expected: `FAIL 06_intake_conflicts.sql: ERROR:  function public.practice_intake_save(uuid, jsonb) does not exist`

- [ ] **Step 3: Implement `20261124000600_intake_conflicts.sql`** and `tests.cleared_intake` as in Interfaces.

- [ ] **Step 4: Verify**

Run: `bash supabase/tests/run_tests.sh && bash supabase/tests/golden/run.sh check`
Expected: `ALL PASS (7 files)`, `golden OK (136 cases)`

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261124000600_intake_conflicts.sql supabase/tests/sql/06_intake_conflicts.sql supabase/tests/harness/helpers.sql supabase/tests/golden/added_keys.txt
git commit -m "Due-diligence intake and conflicts check: people with last-4 IDs, PEP risk, fuzzy matches within the practice, retention" -m "$TRAILER"
```

---

### Task 9: Engagement letters, default template and signing records (SQL)

**Files:**
- Create: `supabase/migrations/20261124000700_engagement_letters.sql`
- Create: `supabase/tests/sql/07_engagement_letters.sql`
- Modify: `supabase/tests/harness/helpers.sql` (add `tests.completed_letter`)

**Interfaces:**
- Consumes: intakes (Task 8), `private.call_function`, `private.activity_event`.
- Produces:
  - Tables `practice_letter_templates` (`practice_id`, `name` 2..80, `kind` `blocks|pdf`, `body jsonb`, `pdf_path`, `is_default`, `archived`, partial unique default per practice), `engagement_letters` (`practice_id`, `intake_id`, `client_id`, `template_id`, `variant` `full|involved`, `source` `template|pdf|signed_upload`, `status` `draft|partner_signed|sent|completed|uploaded|void`, `title`, `blocks jsonb`, `merge jsonb not null default '{}'`, `doc_path`, `doc_sha256`, `final_path`, `final_sha256`, `retention_years int not null default 6 check (retention_years >= 5)`, `partner_id`, `partner_signature`, `partner_signed_at`, `partner_ip`, `partner_ua`, `white_label boolean not null default false` (= `variant = 'full'`), `void_reason`), `engagement_letter_signers` (`letter_id`, `name`, `email`, `title`, `token_hash`, `token_expires`, `sends_today`, `sends_day`, `otp_hash`, `otp_expires`, `otp_tries`, `otp_failures`, `locked_at`, `code_verified_at`, `signature_path`, `typed_name`, `ip`, `ua`, `signed_at`), `engagement_letter_events` (`id bigint identity`, `letter_id`, `at`, `kind`, `actor`, `ip`, `ua`, `detail jsonb`).
  - trigger `engagement_letters_freeze` (BEFORE UPDATE): once `OLD.status <> 'draft'`, `blocks, merge, variant, source, doc_path, doc_sha256, template_id, intake_id` cannot change (`A signed letter cannot be edited. Void it and start again.`).
  - `private.letter_fields() returns text[]` — exactly the 50 fields of the draft: `letter.date contact.title contact.name contact.salutation client.name client.address client.name_upper client.reg_label client.rc_number client.description engagement.title_upper engagement.title_lower engagement.start_date proposal.date firm.name firm.email firm.phone firm.city fees.frequency fees.amount fees.amount_words fees.deposit fees.deposit_words fees.billing_day fees.billing_period fees.payment_days fees.suspend_days service.advisory service.bookkeeping service.monthly service.annual service.other service.other_text service.days partner.name partner.title partner.email team.assistant conflicts.note liability.cap_basis retention.years termination.notice_days termination.handover_days arbitration.seat signer.name signer.title signer.date mode.full_mandate signature.firm signature.client`.
  - `private.letter_body_ok(p_body jsonb) returns text` (null = valid, else the reason): `octet_length(p_body::text) <= 204800`; `version = 1`; 1..600 blocks; `id ~ '^[a-z0-9_-]{1,40}$'` unique; `kind in ('heading','clause','paragraph','list','signature')`; `level` 1..4; `text` ≤ 4000 and `text !~ '<[A-Za-z/!]'`; `variant in (null,'full','involved')`; `optional` null or a field; every `{{x}}`, `{{#x}}`, `{{/x}}` names a field; every `{{ref:id}}` names a block; signature text `firm|client`.
  - `private.letter_default_body() returns jsonb` — the draft converted: one block per paragraph; written-out numbers removed; heading/clause/list levels 1/2/3/4 for `1.`/`1.1`/`(a)`/`(i)`; whole-paragraph `{{#x}}…{{/x}}` → `optional: 'x'` on each block inside; `{{#mode.full_mandate}}` → `variant: 'full'`; inline `{{#x}}…{{/x}}` kept in text; `paragraph 1.1`, `1.1(b)`, `6.3`, `13` → `{{ref:scope_services}}`, `{{ref:svc_bookkeeping}}`, `{{ref:conf_other_clients}}`, `{{ref:term}}` with those block ids; clause 2.1(d) gets `optional: 'service.bookkeeping'`; `{{signature.firm}}`/`{{signature.client}}` → signature blocks.
  - `private.letter_defaults() returns jsonb` — `{"liability.cap_basis":"lower","retention.years":6,"termination.notice_days":30,"termination.handover_days":14,"fees.payment_days":14,"fees.suspend_days":30,"fees.frequency":"monthly","fees.billing_day":1,"fees.billing_period":"month","service.days":10,"arbitration.seat":"Lagos","contact.salutation":"Sir/Madam","client.reg_label":"RC"}`.
  - `private.letter_event(p_letter uuid, p_kind text, p_actor text, p_ip text, p_ua text, p_detail jsonb default '{}') returns void` (also `activity_event(org, 'letter_' || p_kind, …)` on the client's org when there is one); kinds `drafted, partner_signed, sent, opened, code_sent, code_failed, signed, uploaded, voided`.
  - `private.practice_mail(p_kind text, p_id uuid) returns void` → `private.call_function('messaging', jsonb_build_object('action','practice_mail','kind',p_kind,'id',p_id))`.
  - RPCs: `public.practice_letter_templates(p_practice uuid) returns jsonb` (inserts `Counta standard letter` from `letter_default_body()` as default when the practice has none); `public.practice_letter_template_save(p_practice uuid, p jsonb) returns jsonb` (partner; `{id?, name, kind, body?, pdf_path?, is_default?, archived?}`, body validated); `public.practice_letter_draft(p_intake uuid, p jsonb) returns jsonb` (lead; `{template_id?, variant?, merge?, retention_years?}`; variant defaults to `mode_requested`; merge = `letter_defaults()` ‖ intake/practice/partner values ‖ `p.merge`); `public.practice_letter_save(p_letter uuid, p jsonb) returns jsonb` (draft only; `blocks` partner only, `merge` lead); `public.practice_letter(p_letter uuid) returns jsonb` (letter, signers without hashes, events); `public.practice_letter_prepare(p_letter uuid) returns jsonb` (partner; draft; `{letter_id, practice_id, source, doc_path, title, variant, blocks, merge, firm, partner}`); `public.svc_letter_frozen(p_letter uuid, p jsonb) returns jsonb` (`{doc_path, doc_sha256, by_user, signature_name, ip, ua}` → `partner_signed`); `public.practice_letter_send(p_letter uuid, p jsonb) returns jsonb` (partner; `partner_signed`; `{name, email, title}` → signer row, `sent`, `practice_mail('letter_sign', signer_id)`); `public.practice_letter_upload_signed(p_letter uuid, p jsonb) returns jsonb` (partner; `{path, sha256}` → `uploaded`); `public.practice_letter_void(p_letter uuid, p_reason text) returns jsonb` (partner).
  - Signer service RPCs (service_role; never raise for a wrong code, so counters persist): `public.svc_sign_open(p_token text, p_ip text, p_ua text) returns jsonb` (`{ok, reason?, letter_id, title, firm_name, signer_name, doc_path, status, white_label}`); `public.svc_sign_code(p_token text, p_ip text, p_ua text) returns jsonb` (`{ok, reason: 'too_many_today'|'locked'|'expired'}`; ≤5 per Lagos day; queues `letter_code`); `public.svc_sign_verify(p_token text, p_code text, p_ip text, p_ua text) returns jsonb` (`{ok, reason: 'wrong_code'|'expired'|'used_up'|'locked', tries_left, letter: {letter_id, signer_id, doc_path, doc_sha256, title, practice_id, partner_name, partner_email, partner_signed_at, partner_ip, partner_ua, signer_name, signer_email, signer_title}}`; 5 tries per code, lock after 15 failures; success sets `code_verified_at`); `public.svc_sign_complete(p_token text, p jsonb) returns jsonb` (`{signature_path, final_path, final_sha256, typed_name, ip, ua}`; needs `code_verified_at > now() - 15 minutes`; → `completed`, `practice_mail('letter_done', letter_id)`). Tokens `es_` + 48 hex, sha256-hashed, 14 days.
  - `public.svc_practice_mail(p_kind text, p_id uuid) returns jsonb` — `{to, cc?, reply_to, from_name, subject, heading, greet, lines[], button, link, code?, white_label}` or null when not sendable; `letter_sign` (signer id): new token replacing the hash, `link = app_url || '/sign/' || token`; `letter_code` (signer id): 6 digits from `gen_random_bytes`, `otp_hash = sha256(signer_id || ':' || code)`, 10 minutes, `otp_tries = 0`, `code` returned; `letter_done` (letter id): to the signer, cc the partner. `from_name` is the firm's name.
  - `tests.completed_letter(p_intake uuid) returns uuid` (draft → `svc_letter_frozen` with a fake path/hash → send → `svc_practice_mail('letter_code')` → `svc_sign_verify` → `svc_sign_complete`).

- [ ] **Step 1: Write the failing test** — `supabase/tests/sql/07_engagement_letters.sql`

```sql
-- test: default_template_valid
b := private.letter_default_body();
assert private.letter_body_ok(b) is null, 'default_template_valid: validates';
assert (select count(*) from jsonb_array_elements(b->'blocks') x where x->>'kind' = 'heading' and (x->>'level')::int = 1) = 16, 'default_template_valid: 16 headings';
assert (select bool_and(b::text like '%{{' || f || '}}%' or b::text like '%{{#' || f || '}}%' or b->'blocks' @> jsonb_build_array(jsonb_build_object('optional', f))
  or f in ('mode.full_mandate','signature.firm','signature.client')) from unnest(private.letter_fields()) f), 'default_template_valid: every field maps';
assert (select count(*) from jsonb_array_elements(b->'blocks') x where x->>'variant' = 'full') = 1, 'default_template_valid: one full-mandate clause';
assert b::text like '%Rev360%' and b::text like '%Nigeria Data Protection Act 2023%' and b::text not like '%TaxProMax%' and b::text not ilike '%ethSSL%', 'default_template_valid: fixes';
assert not exists (select 1 from jsonb_array_elements(b->'blocks') x where x->>'text' ~ '^(\d+(\.\d+)?\s|\([a-z]+\)\s)'), 'default_template_valid: numbering computed at render';
-- test: letter_body_rejects
assert private.letter_body_ok('{"version":1,"blocks":[{"id":"a","kind":"paragraph","level":1,"text":"<b>x</b>"}]}') is not null, 'letter_body_rejects: html';
assert private.letter_body_ok('{"version":1,"blocks":[{"id":"a","kind":"paragraph","level":1,"text":"{{client.nickname}}"}]}') is not null, 'letter_body_rejects: field';
assert private.letter_body_ok('{"version":1,"blocks":[{"id":"a","kind":"paragraph","level":1,"text":"see {{ref:zz}}"}]}') is not null, 'letter_body_rejects: ref';
-- test: templates_partner_only
perform tests.as_user(manager); perform tests.throws($q$select public.practice_letter_template_save(<pr>, '{"name":"Mine","kind":"blocks","body":...}')$q$, '%partner%');
-- test: letter_draft_defaults
l := public.practice_letter_draft(i, '{}')->>'id';
assert (select merge->>'liability.cap_basis' = 'lower' and retention_years = 6 from engagement_letters where id = l), 'letter_draft_defaults';
perform tests.throws($q$select public.practice_letter_draft(<i>, '{"retention_years":4}')$q$, '23514%');
-- test: letter_freeze
perform public.svc_letter_frozen(l, '{"doc_path":"practice/<pr>/letters/<l>/letter.pdf","doc_sha256":"<64 hex>","signature_name":"Bisi Partner"}');
perform tests.throws($q$update engagement_letters set blocks = '{}' where id = <l>$q$, '%cannot be edited%');
-- test: letter_send_queues_mail
perform tests.hooks_on(); perform public.practice_letter_send(l, '{"name":"Dayo Client","email":"dayo@client.example.test","title":"Director"}');
assert exists (select 1 from net._requests where body->>'action' = 'practice_mail' and body->>'kind' = 'letter_sign'), 'letter_send_queues_mail';
-- test: sign_token_and_code
r := public.svc_practice_mail('letter_sign', s); assert r->>'link' ~ '/sign/es_[0-9a-f]{48}$' and (r->>'white_label')::boolean = (variant = 'full'), 'sign_token_and_code: link';
c := public.svc_practice_mail('letter_code', s)->>'code'; assert c ~ '^[0-9]{6}$', 'sign_token_and_code: 6 digits';
-- test: sign_limits
-- five svc_sign_code calls succeed, the sixth returns reason 'too_many_today'; five wrong codes → 'used_up'; fifteen failures → 'locked' and locked_at set
-- test: sign_complete                 (svc_sign_open, svc_sign_code, svc_practice_mail('letter_code') first)
assert (public.svc_sign_verify(tok, c, '203.0.113.9', 'UA')->>'ok')::boolean, 'sign_complete: verify';
perform public.svc_sign_complete(tok, '{"signature_path":"…/signature.png","final_path":"…/final.pdf","final_sha256":"<64 hex>","typed_name":"Dayo Client","ip":"203.0.113.9","ua":"UA"}');
assert (select status from engagement_letters where id = l) = 'completed'
   and (select array_agg(kind order by id) from engagement_letter_events where letter_id = l) @> '{partner_signed,sent,opened,code_sent,signed}', 'sign_complete';
-- test: upload_signed_copy
assert public.practice_letter_upload_signed(l2, '{"path":"practice/<pr>/letters/<l2>/signed.pdf","sha256":"<64 hex>"}')->>'status' = 'uploaded', 'upload_signed_copy';
-- test: letter_helpers_revoked (letter_fields, letter_body_ok, letter_default_body, letter_defaults, letter_event, practice_mail; svc_* not executable by authenticated)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash supabase/tests/run_tests.sh 07_engagement`
Expected: `FAIL 07_engagement_letters.sql: ERROR:  function private.letter_default_body() does not exist`

- [ ] **Step 3: Implement `20261124000700_engagement_letters.sql`** and `tests.completed_letter` as in Interfaces.

- [ ] **Step 4: Verify**

Run: `bash supabase/tests/run_tests.sh && bash supabase/tests/golden/run.sh check`
Expected: `ALL PASS (8 files)`, `golden OK (136 cases)`

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261124000700_engagement_letters.sql supabase/tests/sql/07_engagement_letters.sql supabase/tests/harness/helpers.sql
git commit -m "Engagement letters: templates as blocks, default letter, freeze, e-sign records with codes and limits" -m "$TRAILER"
```

---

### Task 10: Full mandate I — gate, business creation, director confirmation, money lock

**Files:**
- Create: `supabase/migrations/20261124000800_mandate_gate.sql`
- Create: `supabase/tests/sql/08_mandate_gate.sql`
- Modify: `supabase/tests/harness/helpers.sql` (add `tests.full_client`)

**Interfaces:**
- Consumes: `private.practice_can_full`, `private.create_org_core`, `private.practice_sync_seats`, `private.intake_cleared`, `private.identity_people`, `private.identity_match`, `private.fold_name`, `private.norm_id`, `private.practice_mail`, `svc_practice_mail` (Task 9 body).
- Produces:
  - `practice_director_confirmations` (`practice_id`, `client_id`, `name`, `email`, `phone`, `token_hash`, `token_expires`, `sends_today`, `sends_day`, `otp_hash`, `otp_expires`, `otp_tries`, `otp_failures`, `locked_at`, `status` `pending|review|confirmed|declined|cancelled`, `ip`, `ua`, `flags jsonb not null default '{}'`, `decline_reason`, `decided_by`, `decided_at`, `requested_by`, `created_at`, `confirmed_at`); `practice_mandate_flags` (`practice_id`, `intake_id`, `client_id`, `kind` `duplicate_company|director_declined|director_review`, `detail jsonb`, `created_at`, `resolved_at`, `resolved_by`, `resolution_note`).
  - `private.mandate_gate(p_intake uuid) returns jsonb` → `{"partner_verified","practice_can_full","risk_rated","conflicts_cleared","letter_completed","authority_declared","ok"}` (caller is an active partner with `licence_status 'verified'`; `practice_can_full`; `risk_rating` set; `intake_cleared`; a `variant 'full'` letter for the intake with status `completed|uploaded`; `authority_declared_at` set); `public.practice_mandate_gate(p_intake uuid) returns jsonb` (lead wrapper).
  - `public.practice_create_business(p_intake uuid, p jsonb) returns jsonb` — `p = {email (required), phone?, vat_registered? default true, bank_details? ≤500, engagement_partner_id? default the caller, alert_email?}`; gate not ok → raises `Full mandate needs: <comma-separated false keys>`; another org with the same `norm_id` RC or Tax ID that has an active owner with a user or is managed by another practice → inserts a `duplicate_company` flag and returns `{"ok": false, "reason": "duplicate"}`; else `create_org_core(intake.legal_name, p.email, …)`, `orgs.managed_by`, `identity_status 'pending'`, `invoice_note = bank_details`, `rc_number`, `tin`, `address`; `practice_clients` (`mode 'full'`, `billing 'practice'`, `status 'active'`, `initiated_by 'practice'`, `intake_id`, `engagement_partner_id`, `alert_email`, `retention_years` from the letter, `started_at`); sync seats; `activity_event(org, 'mandate_started', …)`; returns `{"ok": true, "org_id", "client_id"}`.
  - `private.payments_open(p_org)` and `private.require_payments_open(p_org)`: existing checks AND (`managed_by is null` OR (`director_confirmed_at is not null` AND `practice_can_full(managed_by)`)); new message for the managed case `Payments open once a director of the business confirms, and while the firm may run full mandates.`; `public.get_inventory` `org.payments_open` = `private.payments_open(o.id)`.
  - `private.free_mail_domains() returns text[]` = `{gmail.com, googlemail.com, yahoo.com, yahoo.co.uk, ymail.com, outlook.com, hotmail.com, live.com, msn.com, icloud.com, me.com, aol.com, proton.me, protonmail.com, gmx.com, zoho.com, mail.com}` plus the domains in `coalesce(private.setting('mandates'), '{}')->'free_mail_domains'` (a jsonb array in `platform_settings` key `mandates`).
  - `public.practice_director_request(p_client uuid, p jsonb) returns jsonb` (lead; `{name, email, phone?}`; full, active; `identity_status in ('verified','approved')` else `Verify the business's identity first.`; `identity_match` of `fold_name(name)` against `identity_people(org)` else `That name is not a director on the CAC record.`; `lower(trim(email))` not any practice member's or `practices.email`, and its domain not the domain of any of those unless in `free_mail_domains()` → else `Use the director's own email address, not the firm's.`; cancels earlier pending rows; `practice_mail('director_confirm', id)`).
  - Service RPCs (never raise on a wrong code): `public.svc_director_open(p_token text, p_ip text, p_ua text) returns jsonb` (`{ok, firm_name, business_name, director_name, status}`), `public.svc_director_code(p_token text, p_ip text, p_ua text) returns jsonb`, `public.svc_director_confirm(p_token text, p_code text, p_ip text, p_ua text) returns jsonb` (same code rules as letters; on success: an `auth.sessions` row of any member of the practice with `ip = p_ip::inet` updated within 30 days, or an unparsable IP → `status 'review'` + `director_review` flag; else `confirmed`, `orgs.director_confirmed_at = now()`, `activity_event(org, 'director_confirmed', …)`; returns `{ok, status}`), `public.svc_director_decline(p_token text, p_reason text, p_ip text, p_ua text) returns jsonb` (`declined`, `director_declined` flag, `practice_notify`). Tokens `dc_` + 48 hex, 14 days.
  - `public.svc_practice_mail` adds `director_confirm` (link `app_url || '/confirm/' || token`) and `director_code`; both `white_label true`.
  - `public.admin_director_decide(p_id uuid, p_approve boolean, p_note text) returns jsonb` (`require_staff(false)`; `review` → `confirmed` (sets `director_confirmed_at`) or `declined`; `private.audit('director_confirmed'|'director_declined', …)`); `public.admin_practice_suspend(p_practice uuid, p_on boolean, p_note text) returns jsonb` (`require_staff(true)`, note ≥ 5 chars, `mandate_suspended_at`, `private.audit('mandates_suspended'|'mandates_resumed', …)`, `practice_notify`).
  - `tests.full_client(p_practice uuid, p_partner uuid) returns uuid` (cleared full intake → declaration → completed letter → `practice_create_business` as the partner; returns the `practice_clients` id).

- [ ] **Step 1: Write the failing test** — `supabase/tests/sql/08_mandate_gate.sql`

```sql
-- test: mandate_gate_conditions        (fresh full intake, nothing done)
g := private.mandate_gate(i);
assert not (g->>'ok')::boolean and not (g->>'letter_completed')::boolean and not (g->>'authority_declared')::boolean, 'mandate_gate_conditions: blocked';
-- after risk, run, declaration and tests.completed_letter(i):
assert (private.mandate_gate(i)->>'ok')::boolean, 'mandate_gate_conditions: open';
perform tests.as_user(unverified_partner); assert not (private.mandate_gate(i)->>'partner_verified')::boolean, 'mandate_gate_conditions: personal licence';
-- test: create_business_full
r := public.practice_create_business(i, '{"email":"books@firm.example.test","bank_details":"Pay to Test Bank 0123456789"}');
assert (select managed_by = pr and identity_status = 'pending' and email = 'books@firm.example.test' and invoice_note like 'Pay to Test Bank%' from orgs where id = (r->>'org_id')::uuid), 'create_business_full: org';
assert (select mode = 'full' and billing = 'practice' and status = 'active' from practice_clients where id = (r->>'client_id')::uuid), 'create_business_full: client';
assert not exists (select 1 from members where org_id = (r->>'org_id')::uuid and role = 'owner'), 'create_business_full: no owner member';
assert exists (select 1 from activity_log where org_id = (r->>'org_id')::uuid and action = 'mandate_started'), 'create_business_full: logged';
-- test: create_business_duplicate      (org with rc_number '7654321' owned by a real user; intake rc 'RC-7654321')
assert public.practice_create_business(i2, '{"email":"b@firm.example.test"}')->>'reason' = 'duplicate', 'create_business_duplicate: refused';
assert exists (select 1 from practice_mandate_flags where intake_id = i2 and kind = 'duplicate_company'), 'create_business_duplicate: flag kept';
-- test: money_locked_until_director
assert not private.payments_open(o), 'money_locked_until_director: locked';
perform tests.as_service(); perform tests.throws($q$select public.svc_wallet_to_open(<o>, <seat>)$q$, '%director of the business confirms%');
perform tests.throws($q$select public.svc_tax_wallet_to_open(<o>, <seat>)$q$, '%director of the business confirms%');
-- after director confirmation (identity verified, director confirms from a fresh IP):
assert private.payments_open(o), 'money_locked_until_director: open';
perform public.admin_practice_suspend(pr, true, 'Licence lapsed'); assert not private.payments_open(o), 'money_locked_until_director: kill switch';
-- test: director_email_free_mail_and_case   (Review Focus 3; platform_settings ('mandates', '{"free_mail_domains":["freemail.example.test"]}'); practice members ada@freemail.example.test and partner@firm.example.test)
assert tests.error_of($q$select public.practice_director_request(<c>, '{"name":"Tunde Bello","email":"tunde.bello@freemail.example.test"}')$q$) is null, 'director_email_free_mail_and_case: shared free-mail domain allowed';
perform tests.throws($q$… "email":" Ada@FreeMail.example.test " …$q$, '%director''s own email%');
perform tests.throws($q$… "email":"tunde@FIRM.example.test" …$q$, '%director''s own email%');
-- test: director_name_and_identity
perform tests.throws($q$… "name":"Someone Else" …$q$, '%not a director on the CAC record%');
assert tests.error_of($q$… "name":"Túndé Bello" …$q$) is null, 'director_name_and_identity: diacritics folded';
-- test: director_confirm_flow
assert (public.svc_director_confirm(tok, code, '198.51.100.7', 'UA')->>'status') = 'confirmed' and (select director_confirmed_at is not null from orgs where id = o), 'director_confirm_flow';
-- test: director_ip_review              (auth.sessions row for the partner with ip 198.51.100.8)
assert public.svc_director_confirm(tok2, code2, '198.51.100.8', 'UA')->>'status' = 'review' and (select director_confirmed_at is null from orgs where id = o2), 'director_ip_review';
perform tests.as_user(tests.admin_user('admin1@example.test'), 'aal2'); perform public.admin_director_decide(dc2, true, 'Checked by phone');
assert (select director_confirmed_at is not null from orgs where id = o2), 'director_ip_review: admin approves';
-- test: director_decline
perform public.svc_director_decline(tok3, 'I did not agree to this', '198.51.100.9', 'UA');
assert exists (select 1 from practice_mandate_flags where kind = 'director_declined' and client_id = c3), 'director_decline';
-- test: mandate_helpers_revoked (mandate_gate, free_mail_domains; svc_director_* not executable by authenticated)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash supabase/tests/run_tests.sh 08_mandate`
Expected: `FAIL 08_mandate_gate.sql: ERROR:  function private.mandate_gate(uuid) does not exist`

- [ ] **Step 3: Implement `20261124000800_mandate_gate.sql`** and `tests.full_client` as in Interfaces (redefine `payments_open`, `require_payments_open`, `get_inventory`, `svc_practice_mail` from `fn_dump.sh`).

- [ ] **Step 4: Verify**

Run: `bash supabase/tests/run_tests.sh && bash supabase/tests/golden/run.sh check`
Expected: `ALL PASS (9 files)`, `golden OK (136 cases)`

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261124000800_mandate_gate.sql supabase/tests/sql/08_mandate_gate.sql supabase/tests/harness/helpers.sql
git commit -m "Full mandate gate: verified partner, cleared intake, signed letter, declaration; director confirmation unlocks money" -m "$TRAILER"
```

---

### Task 11: Full mandate II — handover, end, export, deletion blocks, portal and admin reads

**Files:**
- Create: `supabase/migrations/20261124000900_mandate_end_handover.sql`
- Create: `supabase/tests/sql/09_mandate_end_handover.sql`
- Modify: `supabase/tests/golden/added_keys.txt` (append `mandate can_full dd_incomplete read_only opposing_parties`)

**Interfaces:**
- Consumes: Task 10 tables, `tests.full_client`, `private.redact`, `private.activity_event`, `private.practice_sync_seats`, `private.wallet_ledger`, `private.tax_wallet_ledger`.
- Produces:
  - `practice_handovers` (`practice_id`, `client_id`, `email`, `name`, `status` `pending|accepted|cancelled`, `token_hash`, `token_expires`, `sent_count int default 0`, `sent_at`, `created_by`, `accepted_by`, `accepted_at`, `created_at`; one pending per client).
  - `public.practice_handover_start(p_client uuid, p jsonb) returns jsonb` (partner; `{email, name}`; full, active; refuses `That person is on the practice.` when `lower(trim(email))` is any practice member's; cancels older pending; returns `{"id"}`).
  - `public.practice_invite_check` and `public.svc_practice_invite_link` accept `p_kind = 'handover'` (partner; same 5-per-day rule; token `ph_` + 48 hex, 14 days; link `app_url || '/practice/join?t=' || token`; words: heading `Take over <business> on Counta`, from the firm); `public.practice_invite_preview` accepts `^p[mch]_[0-9a-f]{48}$` and returns `{kind:'handover', status, practice, business, email}`.
  - `public.practice_handover_accept(p_token text) returns jsonb` — signed-in email equals the handover email (case-insensitive) else `This handover is for <email>. Sign in with that email address.`; caller not an active member of the practice; in order: `orgs.managed_by = null`; insert the owner member (`role 'owner'`, `status 'active'`) with `counta.seat_sync` on; `mode 'involved'`, `end_kind 'handover'` on the client row; sync seats (accountant, not acting owner); handover `accepted`; `activity_event(org, 'handover', …)`; returns `{"org_id"}`.
  - `private.outbound_check` also allows an alert/invite/practice email to a pending handover's address.
  - `private.org_pause_all(p_org uuid) returns void` — `integrations.status 'paused'` where active; `pos_connections.status 'removed'` where live; Mono feeds unlinked (`bank_accounts.provider_ref = null`, `provider_meta.unlinked_reason = 'engagement ended'`); subscriptions `cancel_at_period_end = true`. (Task 13 adds recurring schedules.)
  - `public.practice_end_mandate(p_client uuid, p jsonb) returns jsonb` (partner; `{reason}` ≥ 10 chars) — refuses `Move the money out of the business wallet and the tax wallet first.` when any `wallet_ledger(wallet) > 0.004` or `tax_wallet_ledger(tax_wallet) > 0.004`; refuses `Wait for the payouts in progress to finish first.` when payouts `pending_approval|approved|processing`, tax transfers `pending|sent` or tax payments `approved|processing` exist; then `org_pause_all`; client `status 'ended'`, `end_kind 'ended'`, `ended_at`; sync seats (engagement partner seat stays, others disabled); intake `retain_until`; event `mandate_ended`; last, `orgs.read_only_at = now()`, `retain_until = current_date + greatest(coalesce(retention_years,5),5) years`; `managed_by` stays.
  - trigger `orgs_retention_guard` (BEFORE DELETE on `orgs`) raising `This business is kept until <retain_until> (engagement records).`; `public.admin_business_delete` and `public.admin_business_delete_preview` say the same before anything else.
  - `private.export_tables() returns text[]` (public base tables with `org_id` minus `{activity_log, kyc_profiles, usage_events, ai_logs, shop_hits, sso_logins, chat_links, whatsapp_sessions, portal_logins, pit_etax_logins}`); `public.practice_export_begin(p_client uuid) returns jsonb` (partner; full or ended-kept client; `{org_id, client_id, practice_id, tables}`); `public.svc_export_rows(p_org uuid, p_table text, p_after text, p_limit int) returns jsonb` (`{rows (each private.redact), next}` ordered by `id::text`, ≤1000); `public.svc_export_ledger(p_org uuid) returns jsonb` (rows `{date, journal_ref, account_code, account_name, debit, credit, memo}`); `public.svc_export_activity(p_org uuid) returns jsonb`; `public.svc_export_done(p_client uuid, p jsonb) returns jsonb` (`{path, sha256, bytes}` → event `export`).
  - `public.practice_set_send_mode(p_client uuid, p_mode text) returns jsonb` (lead, `send|download_only`); `public.practice_set_alert_email(p_client uuid, p_email text) returns jsonb` (lead; must be a firm address: a practice member's, `practices.email`, or on the practice's own non-free-mail domain).
  - `public.practice_home`: each client row adds `mode`, `intake_id`, `dd_incomplete`, `read_only`, `retain_until`; ended clients with `end_kind 'ended'` are listed (status `ended`); top-level `can_full` = `practice_can_full(p_practice)`.
  - `public.practice_client`: `client` adds `mode`, `end_kind`, `intake_id`; new key `opposing_parties` (`[{id, name, rc_number, note}]` recorded for this client, any mode); new key `mandate` (full or ended-kept only) = `{send_mode, alert_email, engagement_partner_id, director_confirmed_at, read_only_at, retain_until, payments_open, director: {status, name, email, sent_at, confirmed_at} | null, handover: {id, email, status, sent_at} | null, letter: {id, status} | null}`.
  - `public.admin_mandates() returns jsonb` (`require_staff(false)`; `{reviews:[…review confirmations with practice/business/director/ip…], practices:[{id, name, full_clients, suspended_at, partner_verified}], flags:[unresolved]}`); `public.admin_mandate_flag_resolve(p_id uuid, p_note text) returns jsonb` (`require_staff(false)`, audit).

- [ ] **Step 1: Write the failing test** — `supabase/tests/sql/09_mandate_end_handover.sql`

```sql
-- test: handover_start_rules
perform tests.throws($q$select public.practice_handover_start(<c>, '{"email":" PARTNER@firm.example.test ","name":"P"}')$q$, '%on the practice%');
h := public.practice_handover_start(c, '{"email":"owner@client.example.test","name":"Ngozi Owner"}')->>'id';
perform tests.as_service(); assert public.svc_practice_invite_link('handover', h)->>'link' ~ 'ph_[0-9a-f]{48}$', 'handover_start_rules: link';
-- test: handover_accept
perform tests.as_user(tests.user('someone@example.test')); perform tests.throws($q$select public.practice_handover_accept('<token>')$q$, '%Sign in with that email address%');
perform tests.as_user(new_owner); r := public.practice_handover_accept(token);
assert (select managed_by is null from orgs where id = o) and (select role from members where org_id = o and user_id = new_owner) = 'owner', 'handover_accept: owner';
assert (select mode = 'involved' and end_kind = 'handover' from practice_clients where id = c), 'handover_accept: involved';
assert not exists (select 1 from members where org_id = o and acts_as_owner and status = 'active') and exists (select 1 from members where org_id = o and user_id = partner and role = 'accountant'), 'handover_accept: firm drops to accountant';
perform private.alert_send(o, 'test', 'k2', array['email'], '{"title":"T"}');
assert (select to_address from messages where org_id = o and template = 'alert' order by created_at desc limit 1) = 'owner@client.example.test', 'handover_accept: silence lifted';
-- test: end_refuses_money
(wallet ledger > 0) perform tests.throws($q$select public.practice_end_mandate(<c>, '{"reason":"Client moved firms"}')$q$, '%Move the money out%');
(pending payout)    perform tests.throws($q$…$q$, '%payouts in progress%');
-- test: end_mandate
perform public.practice_end_mandate(c, '{"reason":"Client moved firms"}');
assert (select read_only_at is not null and retain_until = (current_date + interval '6 years')::date and managed_by = pr from orgs where id = o), 'end_mandate: kept 6 years (letter default)';
assert (select status from integrations where org_id = o) = 'paused' and (select status from pos_connections where org_id = o) = 'removed', 'end_mandate: paused';
assert (select status from members where org_id = o and user_id = partner) = 'active' and (select status from members where org_id = o and user_id = manager) = 'disabled', 'end_mandate: seats';
perform tests.as_user(partner); perform tests.throws($q$select public.save_customer(<o>, '{"name":"After"}')$q$, '42501%');
insert into messages (org_id, channel, to_address, template, params) values (o, 'email', 'partner@firm.example.test', 'alert', '{}');
assert (select status from messages where org_id = o order by created_at desc limit 1) = 'suppressed', 'end_mandate: silence persists';
-- test: deletion_blocked
perform tests.throws($q$delete from orgs where id = <o>$q$, '%kept until%');
perform tests.as_user(admin, 'aal2'); perform tests.throws($q$select public.admin_business_delete(<o>, '<name>')$q$, '%kept until%');
-- test: export_rows
perform tests.as_user(partner); assert public.practice_export_begin(c)->'tables' ? 'customers' and not public.practice_export_begin(c)->'tables' ? 'kyc_profiles', 'export_rows: tables';
perform tests.as_service(); assert (select bool_and(x->>'hook_token_hash' = '[redacted]') from jsonb_array_elements(public.svc_export_rows(o, 'integrations', null, 1000)->'rows') x), 'export_rows: redacted';
perform public.svc_export_done(c, '{"path":"practice/<pr>/exports/<c>/x.zip","sha256":"<64 hex>","bytes":10}');
assert exists (select 1 from activity_log where org_id = o and action = 'export'), 'export_rows: logged';
-- test: portal_reads
assert (public.practice_home(pr)->>'can_full')::boolean and exists (select 1 from jsonb_array_elements(public.practice_home(pr)->'clients') x where x->>'mode' = 'full'), 'portal_reads: home';
assert public.practice_client(c)->'mandate' ? 'director', 'portal_reads: client mandate';
perform public.practice_opposing_save(pr, jsonb_build_object('client_id', c, 'name', 'Rival Haulage Ltd'));
assert public.practice_client(c)->'opposing_parties'->0->>'name' = 'Rival Haulage Ltd', 'portal_reads: opposing parties';
perform public.practice_set_send_mode(c, 'download_only'); assert (select send_mode from orgs where id = o) = 'download_only', 'portal_reads: send mode';
perform tests.throws($q$select public.practice_set_alert_email(<c>, 'someone@client.example.test')$q$, '%firm%');
-- test: admin_reads
perform tests.as_user(admin, 'aal2'); assert public.admin_mandates() ? 'reviews' and public.admin_mandates() ? 'flags', 'admin_reads';
perform tests.as_user(partner); perform tests.throws($q$select public.admin_mandates()$q$, '%only for TaxStreem%');
-- test: end_helpers_revoked (org_pause_all, export_tables; svc_export_* not executable by authenticated)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash supabase/tests/run_tests.sh 09_mandate`
Expected: `FAIL 09_mandate_end_handover.sql: ERROR:  function public.practice_handover_start(uuid, jsonb) does not exist`

- [ ] **Step 3: Implement `20261124000900_mandate_end_handover.sql`** as in Interfaces (redefine existing functions from `fn_dump.sh`).

- [ ] **Step 4: Verify**

Run: `bash supabase/tests/run_tests.sh && bash supabase/tests/golden/run.sh check`
Expected: `ALL PASS (10 files)`, `golden OK (136 cases)`

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261124000900_mandate_end_handover.sql supabase/tests/sql/09_mandate_end_handover.sql supabase/tests/golden/added_keys.txt
git commit -m "Full mandate handover, end without handover, export records, retention block on deletion, portal and admin reads" -m "$TRAILER"
```

---

### Task 12: `practice` edge function — letter PDFs, e-signing, director confirmation, export, firm emails

**Files:**
- Create: `supabase/functions/_shared/letter.ts`, `supabase/functions/_shared/letter_test.ts`, `supabase/functions/_shared/default_letter.json` (generated in Step 3)
- Create: `supabase/functions/practice/index.ts`, `supabase/functions/practice/pdf.ts`, `supabase/functions/practice/pdf_test.ts`, `supabase/functions/practice/util.ts`, `supabase/functions/practice/util_test.ts`, `supabase/functions/practice/export.ts`
- Modify: `supabase/functions/messaging/index.ts:337-357` (`practiceEmail` kinds add `'handover'`), `:370-381` (hook action `practice_mail`)

**Interfaces:**
- Consumes: `practice_letter_prepare`, `svc_letter_frozen`, `svc_sign_open|code|verify|complete`, `svc_director_open|code|confirm|decline`, `svc_practice_mail`, `practice_export_begin`, `svc_export_rows|ledger|activity|done`.
- Produces:
  - `_shared/letter.ts` (pure TS, no Deno or npm imports; also imported by the browser in Task 16): types `LetterBlock = { id: string; kind: 'heading'|'clause'|'paragraph'|'list'|'signature'; level: number; text: string; variant?: 'full'|'involved'|null; optional?: string|null }`, `LetterBody = { version: 1; blocks: LetterBlock[] }`, `MergeValues = Record<string, string | number | boolean | null>`, `RenderedBlock = { id: string; kind: LetterBlock['kind']; level: number; number: string | null; ref: string | null; text: string }` (`number` is the printed label — `1.`, `1.1`, `(a)`, `(i)`; `ref` is the full reference — `1`, `1.1`, `1.1(a)`, `1.1(a)(i)`); `export const LETTER_FIELDS: string[]` (the 50 of Task 9); `export function deriveMerge(raw: MergeValues): MergeValues` (fills `client.name_upper`, `engagement.title_upper`, `fees.amount` as `nairaText`, `fees.amount_words`, `fees.deposit`, `fees.deposit_words`); `export function nairaText(n: number): string` (`NGN 250,000.00`); `export function amountWords(n: number): string` (`two hundred and fifty thousand naira only`); `export function renderModel(body: LetterBody, merge: MergeValues, variant: 'full'|'involved'): RenderedBlock[]` — drops blocks whose `variant` differs or whose `optional` field is falsy; numbers the rest: heading level 1 `1.`, `2.` …; clause `<h>.<n>` under the last heading; list level 3 `(a)` … under the last clause; level 4 `(i)` … under the last list item; counters restart under each new parent and dropped blocks consume none; then resolves `{{ref:id}}` to that block's `ref` (throws `Reference to a paragraph that is not in this letter: <id>`), inline `{{#x}}…{{/x}}` (kept when `x` is truthy) and `{{x}}`.
  - `practice/util.ts`: `clientIp(req: Request): string` (first `x-forwarded-for` entry, else `x-real-ip`, else `''`), `userAgent(req: Request): string` (≤300 chars), `sha256Hex(b: Uint8Array): Promise<string>`, `tokenOk(t: string, prefix: 'es'|'dc'): boolean` (`^<prefix>_[0-9a-f]{48}$`), `pngFromDataUrl(s: string): Uint8Array | null` (`data:image/png;base64,`, ≤300 KB, PNG signature).
  - `practice/pdf.ts` (`npm:pdf-lib@1.17.1`, `StandardFonts.Helvetica`/`HelveticaBold`): `pdfSafe(s: string): string` (`₦` → `NGN `, curly quotes → straight, dashes → `-`, `…` → `...`, other non-ASCII letters NFD-folded with combining marks dropped, anything left outside WinAnsi → `?`); `renderLetterPdf(blocks: RenderedBlock[], meta: { title: string; firmName: string; partnerName: string; partnerTitle: string; partnerSignature?: string }): Promise<Uint8Array>` (A4, 50 pt margins, wrapped text, page numbers); `appendCompletion(pdf: Uint8Array, c: Completion): Promise<Uint8Array>` where `Completion = { title; originalSha256; firm: { name; partnerName; partnerEmail; signedAt; ip; ua }; client: { name; email; title; signedAt; ip; ua; typedName; signaturePng: Uint8Array } }` — adds a signature page and a page titled `Completion certificate` listing both parties' names, emails, times as `dd Mon yyyy, HH:mm (Africa/Lagos)`, IPs, user agents, `Email verified by a one-time code` for the client, and `Original document SHA-256: <hex>`.
  - `practice/index.ts` actions (`POST`, JSON `{action, …}` → `{ok: true, …}` or `{ok: false, error}`): signed-in `letter_freeze {letter_id, signature_name}` (prepare as the user → `renderModel` + `deriveMerge` → PDF → upload `practice/<pid>/letters/<lid>/letter.pdf` with `upsert: false` → `svc_letter_frozen`; a `source 'pdf'` letter hashes its uploaded file instead), signed-in `export {client_id}` (`practice_export_begin` as the user → `buildExport` → `{url}` signed for 600 s); public `sign_open {token}` (→ `{…svc_sign_open, doc_url}` signed for 300 s), `sign_code {token}`, `sign_submit {token, code, typed_name, signature_png}` (verify → download `doc_path`, re-hash, refuse `The letter has changed since it was signed by the firm.` on mismatch → upload `signature-<signer>.png` → `appendCompletion` → upload `final.pdf` → `svc_sign_complete`), `director_open {token}`, `director_code {token}`, `director_confirm {token, code}`, `director_decline {token, reason}`. Public actions check `tokenOk` first and pass `clientIp`/`userAgent`.
  - `practice/export.ts`: `buildExport(admin: SupabaseClient, b: { org_id: string; client_id: string; practice_id: string; tables: string[] }): Promise<{ path: string; sha256: string; bytes: number }>` — zip (`npm:fflate@0.8.3` `zipSync`) of `tables/<table>.json`, `ledger.csv`, `activity_log.json`, `files/<path>` for every `documents` object under `<org_id>/`; stored at `practice/<pid>/exports/<client_id>/<yyyyMMdd-HHmmss>.zip`; then `svc_export_done`.
  - messaging hook `{action: 'practice_mail', kind, id}` (header `x-counta-hook`) → `svc_practice_mail` → `sendEmail` with template `'practice'`, `from` display name = `displayName(from_name, true)`, `params.white_label` from the result; returns `{ok, sent_to}` or `{ok: true, skipped: true}` when null.

- [ ] **Step 1: Write the failing tests**

```ts
// supabase/functions/_shared/letter_test.ts   (body = the JSON from private.letter_default_body(), saved as supabase/functions/_shared/default_letter.json by running fn output once)
Deno.test('render_numbering_full', () => {
  const r = renderModel(body, { 'service.advisory': true, 'service.bookkeeping': true }, 'full');
  assertEquals(r.find((b) => b.id === 'scope')!.number, '1.');
  assertEquals(r.find((b) => b.id === 'svc_bookkeeping')!.number, '(b)');
  assertEquals(r.find((b) => b.id === 'svc_bookkeeping')!.ref, '1.1(b)');
  assertEquals(r.find((b) => b.id === 'term')!.ref, '13');
  assert(r.some((b) => b.text.includes('paragraph 1.1(b) applies')));
});
Deno.test('render_renumbers_when_services_off', () => {
  const r = renderModel(body, { 'service.advisory': false, 'service.bookkeeping': true }, 'involved');
  assertEquals(r.find((b) => b.id === 'svc_bookkeeping')!.number, '(a)');
  assert(r.some((b) => b.text.includes('paragraph 1.1(a) applies')));
  assert(!r.some((b) => b.text.startsWith('Full mandate.')));            // 2.2 dropped, 2.3 becomes 2.2
  assert(!renderModel(body, { 'service.bookkeeping': false }, 'full').some((b) => b.text.includes('paragraph 1.1(')));
});
Deno.test('render_inline_and_fields', () => {
  const t = renderModel(body, { 'client.name': 'Ada Foods Ltd', 'proposal.date': '' }, 'involved').map((b) => b.text).join('\n');
  assert(t.includes('act for Ada Foods Ltd') && !t.includes('our proposal dated'));
});
Deno.test('derive_merge_amounts', () => {
  const m = deriveMerge({ 'fees.amount': 250000, 'client.name': 'Ada Foods Ltd' });
  assertEquals(m['fees.amount'], 'NGN 250,000.00'); assertEquals(m['fees.amount_words'], 'two hundred and fifty thousand naira only'); assertEquals(m['client.name_upper'], 'ADA FOODS LTD');
});
// supabase/functions/practice/pdf_test.ts
Deno.test('pdf_diacritics_do_not_throw', async () => {            // Review Focus 1
  const bytes = await renderLetterPdf([{ id: 'p', kind: 'paragraph', level: 1, number: null, ref: null, text: 'Ọlá Àdé Foods Ltd pays ₦250,000 – “monthly”…' }],
    { title: 'Letter', firmName: 'Ṣọlá & Co', partnerName: 'Ṣọlá Ìyá', partnerTitle: 'Partner' });
  assertEquals(new TextDecoder().decode(bytes.slice(0, 5)), '%PDF-');
  assertEquals(pdfSafe('Ọlá Àdé ₦5'), 'Ola Ade NGN 5');
});
Deno.test('pdf_completion_certificate', async () => {
  const out = await appendCompletion(await renderLetterPdf(blocks, meta), completion);   // completion.originalSha256 = 'ab'.repeat(32)
  assertEquals((await PDFDocument.load(out)).getPageCount(), (await PDFDocument.load(base)).getPageCount() + 2);
});
// supabase/functions/practice/util_test.ts
Deno.test('client_ip', () => assertEquals(clientIp(new Request('http://x', { headers: { 'x-forwarded-for': '203.0.113.9, 10.0.0.1' } })), '203.0.113.9'));
Deno.test('sha256_vector', async () => assertEquals(await sha256Hex(new TextEncoder().encode('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'));
Deno.test('token_ok', () => { assert(tokenOk('es_' + 'a'.repeat(48), 'es')); assert(!tokenOk('es_' + 'a'.repeat(47), 'es')); assert(!tokenOk('dc_' + 'a'.repeat(48), 'es')); });
Deno.test('png_data_url', () => assertEquals(pngFromDataUrl('data:image/jpeg;base64,AAAA'), null));
```

- [ ] **Step 2: Run them to verify they fail**

Run: `deno test --node-modules-dir=none --allow-read supabase/functions/_shared/letter_test.ts supabase/functions/practice/`
Expected: FAIL — `Module not found "file:///…/supabase/functions/_shared/letter.ts"`

- [ ] **Step 3: Implement** the modules and actions as in Interfaces. Save the default body once: `bash supabase/tests/harness/run.sh && runuser -u postgres -- psql -h /var/tmp/counta-pgh -p 54329 -U postgres -AtXc "select jsonb_pretty(private.letter_default_body())" > supabase/functions/_shared/default_letter.json`.

- [ ] **Step 4: Verify**

Run: `deno test --node-modules-dir=none --allow-read supabase/functions/_shared/letter_test.ts supabase/functions/practice/ && deno check --node-modules-dir=none supabase/functions/practice/index.ts supabase/functions/messaging/index.ts`
Expected: `ok | 10 passed`, both files `Check …`

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/_shared supabase/functions/practice supabase/functions/messaging/index.ts
git commit -m "Practice edge function: letter PDFs with completion certificate, e-signing, director confirmation, export, firm-only emails" -m "$TRAILER"
```

---

### Task 13: Recurring invoices

**Files:**
- Create: `supabase/migrations/20261124001000_recurring_invoices.sql`
- Create: `supabase/tests/sql/10_recurring_invoices.sql`
- (Golden cases `public.issue_invoice` and `public.send_document`, recorded in Task 1, prove the wrappers unchanged.)

**Interfaces:**
- Consumes: `private.create_sale(p_org uuid, p_doc jsonb, m members)`, `private.local_day`, `private.org_contact`, `private.set_actor`, `private.activity_attach`, `practices.firm_org_id` (Task 6), `private.org_pause_all` (Task 11).
- Produces:
  - `recurring_invoices` (`org_id` → orgs on delete cascade, `customer_id` not null, `status` `active|paused|ended` default `active`, `frequency` `monthly|quarterly|annually`, `day_of_month int` 1..28, `start_date`, `end_date` (≥ start), `next_run date not null`, `due_days int default 14` 0..365, `lines jsonb not null` (1..50 of `{description, qty > 0, unit_price >= 0, vat_treatment 'standard'|'zero'|'exempt'|'none' default 'standard', once boolean default false}`), `auto_send boolean default true`, `send_channel` `email|whatsapp` default `email`, `notes`, `created_by` → members, `failures int default 0`, `last_error`, `last_run_at`, `practice_client_id` → practice_clients on delete set null, `created_at`, `updated_at`), activity trigger attached; `recurring_invoice_runs` (`schedule_id` → recurring_invoices on delete cascade, `run_date`, `sale_id`, `status` `issued|waiting_nrs|sent|failed`, `error`, `send_error`, `created_at`, unique `(schedule_id, run_date)`); `sales_channel_check` adds `'recurring'`.
  - `private.issue_invoice_as(p_sale uuid, p_issue_date date, m members) returns jsonb` and `private.send_document_as(p_sale uuid, p_channel text, p_to text, m members) returns jsonb` (today's bodies after the permission check); `public.issue_invoice`/`public.send_document` = row lookup + `private.require(...)` + the `_as` function.
  - `private.recurring_first(p_freq text, p_day int, p_start date) returns date` (first date ≥ `p_start` falling on `p_day`) and `private.recurring_next(p_freq text, p_day int, p_after date) returns date` (`p_after` + 1/3/12 months on `p_day`).
  - `private.recurring_run(p_id uuid, p_run_date date) returns uuid` — actor = `created_by` member if active else `org_contact`; `set_actor`; `create_sale` with `doc_type 'invoice'`, `status 'draft'`, `channel 'recurring'`, `customer_id`, `issue_date = p_run_date`, `due_date = p_run_date + due_days`, lines mapped to `{description, kind:'service', qty, unit_price, vat_treatment}` with `once` lines only while the schedule has no `issued|waiting_nrs|sent` run; `issue_invoice_as`; still draft with an e-invoice `waiting|sending` → run `waiting_nrs`; else `auto_send` → `send_document_as(sale, send_channel, null, m)` (an error goes to `send_error`, run stays `issued`) → `sent`.
  - `private.recurring_tick(p_now timestamptz default now()) returns jsonb` — for `status 'active' and next_run <= local_day(org, p_now)` rows `for update skip locked`, each in its own `begin … exception` block: insert the run (on conflict skip the work); run; `next_run := recurring_next(...)` repeated until `> local today` (one invoice per tick, no backfill); `failures := 0`; `next_run > end_date` → `ended`. On exception: `failures + 1`, `last_error = SQLERRM`, run `failed`, `failures >= 3` → `paused`, `next_run` unchanged. Then for `waiting_nrs` runs whose sale is now open: send when `auto_send` → `sent`. Returns `{"issued": n, "sent": n, "failed": n}`. Cron (guarded like `sales.sql:2124`): `cron.schedule('counta-recurring', '7 * * * *', 'select private.recurring_tick()')`.
  - RPCs (`record_sales`): `public.recurring_save(p_org uuid, p jsonb) returns jsonb` (`{id?, customer_id, frequency, day_of_month, start_date, end_date?, due_days?, lines, auto_send?, send_channel?, notes?, practice_client_id?}`; `practice_client_id` must belong to a practice whose `firm_org_id = p_org`; `next_run = recurring_first(...)` on create or when the timing changes); `public.recurring_list(p_org uuid) returns jsonb` (schedules with customer name and last 12 runs); `public.recurring_set_status(p_id uuid, p_status text) returns jsonb` (`active` recomputes a past `next_run` forward); `public.recurring_run_now(p_id uuid) returns jsonb` (runs `next_run` now and rolls forward).
  - `private.org_pause_all` also sets active schedules of the org to `paused`.

- [ ] **Step 1: Write the failing test** — `supabase/tests/sql/10_recurring_invoices.sql`

```sql
-- test: recurring_dates_and_local_day                 (Review Focus 5)
assert private.recurring_next('monthly', 28, '2027-01-28') = '2027-02-28' and private.recurring_next('monthly', 28, '2028-01-28') = '2028-02-28', 'recurring_dates_and_local_day: February';
assert private.recurring_next('quarterly', 15, '2026-11-15') = '2027-02-15' and private.recurring_next('annually', 1, '2026-12-01') = '2027-12-01', 'recurring_dates_and_local_day: quarter, year';
assert private.recurring_first('monthly', 5, '2026-11-20') = '2026-12-05' and private.recurring_first('monthly', 5, '2026-11-03') = '2026-11-05', 'recurring_dates_and_local_day: mid-month start';
-- schedule with next_run 2026-01-28 in an Africa/Lagos org (past dates, so issuing is not "in the future"):
perform private.recurring_tick('2026-01-27 23:30:00+00');
assert (select count(*) from recurring_invoice_runs where schedule_id = r and run_date = '2026-01-28') = 1, 'recurring_dates_and_local_day: Lagos day';
-- test: recurring_issue_and_send
assert (select s.status = 'open' and s.channel = 'recurring' and s.due_date = s.issue_date + 14 from sales s join recurring_invoice_runs x on x.sale_id = s.id where x.schedule_id = r), 'recurring_issue_and_send: issued';
assert (select status from recurring_invoice_runs where schedule_id = r) = 'sent' and exists (select 1 from messages m join recurring_invoice_runs x on m.sale_id = x.sale_id where x.schedule_id = r), 'recurring_issue_and_send: sent';
assert (select next_run from recurring_invoices where id = r) = '2026-02-28', 'recurring_issue_and_send: rolled forward';
-- test: recurring_vat_and_once_lines     (lines: fee 100000 'standard'; expenses deposit 20000 'none', once)
assert (select total from sales where id = first_sale) = 127500 and (select total from sales where id = second_sale) = 107500, 'recurring_vat_and_once_lines: 7.5% VAT, deposit once';
-- test: recurring_no_double_run
perform private.recurring_tick('2026-01-27 23:45:00+00'); assert (select count(*) from recurring_invoice_runs where schedule_id = r) = 1, 'recurring_no_double_run';
-- test: recurring_catch_up_once          (next_run three months behind)
assert (select count(*) from recurring_invoice_runs where schedule_id = r2) = 1 and (select next_run > current_date from recurring_invoices where id = r2), 'recurring_catch_up_once';
-- test: recurring_pause_after_failures   (customer archived so create_sale raises, three ticks)
assert (select status = 'paused' and failures = 3 and last_error is not null from recurring_invoices where id = r3), 'recurring_pause_after_failures';
-- test: recurring_waiting_nrs            (business customer with TIN, e-invoicing clear route: run waiting_nrs, then signed → sent on the next tick)
-- test: recurring_rpcs_permission
perform tests.as_user(cashier); perform tests.throws($q$select public.recurring_save(<org>, '{…}')$q$, '%record sales%');
-- test: recurring_paused_on_end          (private.org_pause_all(org) → schedule paused)
-- test: recurring_helpers_revoked (issue_invoice_as, send_document_as, recurring_first, recurring_next, recurring_run, recurring_tick)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash supabase/tests/run_tests.sh 10_recurring`
Expected: `FAIL 10_recurring_invoices.sql: ERROR:  function private.recurring_next(unknown, integer, unknown) does not exist`

- [ ] **Step 3: Implement `20261124001000_recurring_invoices.sql`** as in Interfaces (redefine `issue_invoice`, `send_document`, `org_pause_all` from `fn_dump.sh`).

- [ ] **Step 4: Verify**

Run: `bash supabase/tests/run_tests.sh && bash supabase/tests/golden/run.sh check`
Expected: `ALL PASS (11 files)`, `golden OK (136 cases)`

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261124001000_recurring_invoices.sql supabase/tests/sql/10_recurring_invoices.sql
git commit -m "Recurring invoices: schedules, hourly issue and send in the business's local day, one catch-up, pause after three failures" -m "$TRAILER"
```

---

### Task 14: Fee billing — firm business, fee customers, mirrored bills, fees overview

**Files:**
- Create: `supabase/migrations/20261124001100_practice_fees.sql`
- Create: `supabase/tests/sql/11_practice_fees.sql`
- (Golden case `public.void_bill`, recorded in Task 1, proves the wrapper unchanged.)

**Interfaces:**
- Consumes: `practices.firm_org_id` (Task 6), `private.upsert_customer(p_org uuid, p_customer jsonb, m members)`, `private.write_bill(p_org uuid, p jsonb, m members)`, `private.post_bill(p_bill uuid, m members)`, `private.org_contact`, `private.set_actor`, `private.activity_event`, `private.wallet_ledger`, `private.tax_wallet_ledger`, recurring tables (Task 13).
- Produces:
  - `practice_fee_bills` (`practice_id`, `client_id`, `sale_id` (fee invoice, unique), `bill_id`, `status` `posted|failed|voided`, `error`, `attempts int default 0`, `created_at`, `updated_at`); `bills_source_check` adds `'practice_fee'`.
  - `public.practice_firm_business(p_practice uuid, p jsonb) returns jsonb` (partner; `{org_id}` links an unmanaged, non-sample business whose real owner is the caller; or `{name, email?, phone?}` creates one with `public.create_org`; sets `firm_org_id`; returns `{"firm_org_id"}`).
  - `public.practice_fee_customer(p_client uuid, p jsonb default '{}') returns jsonb` (lead; needs `firm_org_id`; upserts the customer in the firm business as `org_contact(firm)` with `name` = the client business name, `email`/`phone`/`address` from `p` or, for involved clients, the business's own; stores `fee_customer_id`; returns `{"customer_id"}`).
  - `private.void_bill_as(p_bill uuid, p_reason text, m members) returns jsonb`; `public.void_bill` = lookup + `require(…,'keep_books')` + `_as`.
  - `private.fee_mirror(p_sale uuid) returns practice_fee_bills` — for an invoice of `firm_org_id` whose customer is an active full client's `fee_customer_id`: `m := org_contact(client org)`, `set_actor(m.user_id)`; vendor = `fee_vendor_id`, else `write_bill`'s inline `vendor` `{name: practice name, tin: firm org tin, email: practices.email, wht_category: 'professional'}` (stored back as `fee_vendor_id`); bill `{bill_date: issue_date, due_date, vendor_ref: sale number, source: 'practice_fee', vat_charged: vat_total > 0, prices_include_vat: false}` with one line per sale line `{description, qty: 1, unit_cost: line net, account_code: '6502' (else '6507' when the org has no 6502), vat_treatment: 'standard' when line VAT > 0 else 'none'}`; `post_bill`; row `posted`; `activity_event(client org, 'fee_bill_posted', …)`. Errors are caught: row `failed` with `error`, `attempts + 1`.
  - trigger `sales_fee_mirror` (AFTER UPDATE OF `journal_id` on `sales`, when `old.journal_id is null and new.journal_id is not null and new.doc_type = 'invoice'`) → `private.fee_mirror_on_post()`; trigger `sales_fee_mirror_void` (AFTER UPDATE OF `status`, when `new.status = 'void'`) → `private.fee_mirror_on_void()` voids the mirrored bill via `void_bill_as` when `amount_paid = 0`, row `voided`; never raise.
  - `public.practice_fee_bill_retry(p_id uuid) returns jsonb` (lead; `failed` only).
  - `public.practice_fees(p_practice uuid) returns jsonb` (lead) → `{firm_org: {id, name, identity_status} | null, clients: [{client_id, business_name, mode, fee_customer_id, outstanding, invoices: [{id, number, issue_date, total, balance, status}], schedules: [{id, frequency, day_of_month, next_run, status, total}], fee_bills: [{id, sale_id, status, error, bill_id}]}], wallets?: {wallet: {status, balance}, tax_wallet: {status, balance}}}` — `wallets` only for partners (`wallet_ledger`/`tax_wallet_ledger`).

- [ ] **Step 1: Write the failing test** — `supabase/tests/sql/11_practice_fees.sql`

```sql
-- test: firm_business
perform tests.as_user(manager); perform tests.throws($q$select public.practice_firm_business(<pr>, '{"name":"Firm Books Ltd"}')$q$, '%partner%');
perform tests.as_user(partner); f := (public.practice_firm_business(pr, '{"name":"Firm Books Ltd"}')->>'firm_org_id')::uuid;
assert (select role from members where org_id = f and user_id = partner) = 'owner', 'firm_business: partner owns it';
perform tests.throws($q$select public.practice_firm_business(<pr>, '{"org_id":"<managed org>"}')$q$, '%own%');
-- test: fee_customer_idempotent
assert public.practice_fee_customer(c, '{"email":"accounts@client.example.test"}') = public.practice_fee_customer(c, '{}'), 'fee_customer_idempotent';
-- test: fee_mirror_posts_bill            (firm issues 100000 + VAT to the fee customer)
assert (select b.source = 'practice_fee' and b.total = s.total and b.status = 'approved' from practice_fee_bills x join bills b on b.id = x.bill_id join sales s on s.id = x.sale_id where x.sale_id = sale), 'fee_mirror_posts_bill: totals match';
assert exists (select 1 from bill_lines where bill_id = (select bill_id from practice_fee_bills where sale_id = sale) and account_code = '6502'), 'fee_mirror_posts_bill: professional fees account';
assert (select vendor_id from bills where id = (select bill_id from practice_fee_bills where sale_id = sale)) = (select fee_vendor_id from practice_clients where id = c), 'fee_mirror_posts_bill: vendor kept';
assert exists (select 1 from activity_log where org_id = client_org and action = 'fee_bill_posted'), 'fee_mirror_posts_bill: logged';
-- test: fee_mirror_involved_none
assert not exists (select 1 from practice_fee_bills where sale_id = involved_sale), 'fee_mirror_involved_none';
-- test: fee_mirror_failure_never_blocks  (client books closed through the invoice date)
assert (select status from sales where id = sale2) = 'open' and (select status from practice_fee_bills where sale_id = sale2) = 'failed', 'fee_mirror_failure_never_blocks';
(reopen) perform public.practice_fee_bill_retry(fb2); assert (select status from practice_fee_bills where id = fb2) = 'posted', 'fee_mirror_failure_never_blocks: retry';
-- test: fee_void_voids_unpaid_bill
perform public.void_sale(sale, 'Raised in error'); assert (select status from bills where id = fee_bill) = 'void', 'fee_void_voids_unpaid_bill';
-- test: practice_fees_reads
assert public.practice_fees(pr) ? 'wallets' (as partner) and not public.practice_fees(pr) ? 'wallets' (as manager), 'practice_fees_reads: wallets partners only';
-- test: fees_helpers_revoked (fee_mirror, fee_mirror_on_post, fee_mirror_on_void, void_bill_as)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash supabase/tests/run_tests.sh 11_practice_fees`
Expected: `FAIL 11_practice_fees.sql: ERROR:  function public.practice_firm_business(uuid, unknown) does not exist`

- [ ] **Step 3: Implement `20261124001100_practice_fees.sql`** as in Interfaces (redefine `void_bill` from `fn_dump.sh`).

- [ ] **Step 4: Verify**

Run: `bash supabase/tests/run_tests.sh && bash supabase/tests/golden/run.sh check`
Expected: `ALL PASS (12 files)`, `golden OK (136 cases)`

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261124001100_practice_fees.sql supabase/tests/sql/11_practice_fees.sql
git commit -m "Fee billing: firm business, fee customers, fee invoices mirrored as bills in full-mandate books, fees overview" -m "$TRAILER"
```

---

### Task 15: Portal — add-client wizard (intake, conflicts, declaration, create or invite)

**Files:**
- Create: `src/practice/pages/Intake.tsx`
- Modify: `src/practice/api.ts` (types and hooks), `src/practice/pages/Overview.tsx:35-95,163-212` (replace `InviteClient` with the wizard entry and an "In progress" list), `src/practice/PracticeApp.tsx:85-96` (routes), `src/practice/pages/Settings.tsx` (partner switch for the books scan)

**Interfaces:**
- Consumes RPCs: `practice_intakes`, `practice_intake`, `practice_intake_save`, `practice_intake_doc_add`, `practice_opposing_save`, `practice_conflict_run`, `practice_conflict_decide`, `practice_intake_declare`, `practice_letter_draft`, `practice_mandate_gate`, `practice_create_business`, `practice_invite_client` + `sendInvite('client', id)`; `practice_home.can_full`.
- Produces (TS, `src/practice/api.ts`): `IntakePerson`, `IntakeRow`, `ConflictHit`, `IntakeDetail` (intake columns + `people`, `docs`, `hits`, `letters: {id, status, variant}[]`), `MandateGate` (`Record<'partner_verified'|'practice_can_full'|'risk_rated'|'conflicts_cleared'|'letter_completed'|'authority_declared'|'ok', boolean>`); `usePracticeIntakes(pid: string, status?: string)`, `usePracticeIntake(iid: string | null)`, `useMandateGate(iid: string | null)` (query keys `['practice-intakes', pid, status]`, `['practice-intake', iid]`, `['mandate-gate', iid]`); `Home.can_full: boolean`; `ClientRow.mode`, `dd_incomplete`, `read_only`, `retain_until`.
- Produces (routes): `/practice/:pid/intake/new`, `/practice/:pid/intake/:iid` → `export default function IntakePage({ pid }: { pid: string })`.
- testids (Intake.tsx): `intake-step-1`…`intake-step-6`, `mode-involved`, `mode-full`, `mode-full-locked`, `intake-legal-name`, `intake-entity-type`, `intake-rc`, `intake-tin`, `intake-address`, `intake-industry`, `person-add`, `person-row`, `person-name`, `person-kind`, `person-role`, `person-pct`, `person-nationality`, `person-pep`, `person-id-type`, `person-id-last4`, `intake-risk`, `intake-risk-reason`, `intake-doc-upload`, `intake-save`, `conflict-run`, `conflict-hit`, `conflict-note`, `conflict-clear`, `conflict-refuse`, `letter-status`, `letter-new`, `letter-open`, `declare-statement`, `declare-authority`, `mandate-gate`, `gate-partner_verified`, `gate-practice_can_full`, `gate-risk_rated`, `gate-conflicts_cleared`, `gate-letter_completed`, `gate-authority_declared`, `create-email`, `create-bank-details`, `create-alert-email`, `create-partner`, `create-business`, `invite-email`, `invite-owner`. Overview.tsx: `add-client-open`, `intake-row`, `dd-incomplete` chip on client rows. Settings.tsx: `conflict-scan-books` (checkbox, partners only, off by default, label `Also look for the prospect among your clients' customers and suppliers` → `practice_set_conflict_scan`).
- Behaviour pins: `mode-full` disabled with `mode-full-locked` text `Full mandate needs a partner whose licence TaxStreem has verified.` when `!home.can_full`; `person-id-last4` `maxLength={4}`; documents upload to `practice/<pid>/intake/<iid>/<uuid>-<file name>` in the `documents` bucket, SHA-256 via `crypto.subtle.digest`; declaration and conflict decisions shown only to partners; a `duplicate` result shows `This business cannot be set up under full mandate. TaxStreem has been told and will be in touch.`; success navigates to `/practice/:pid/clients/:cid`.

- [ ] **Step 1: Write the failing check**

Run: `node scripts/ui-check.mjs src/practice/pages/Intake.tsx intake-step-1 mode-full mode-full-locked person-id-last4 conflict-run conflict-clear declare-authority mandate-gate create-business invite-owner && node scripts/ui-check.mjs src/practice/pages/Overview.tsx add-client-open intake-row dd-incomplete && node scripts/ui-check.mjs src/practice/pages/Settings.tsx conflict-scan-books`
Expected: FAIL — `missing in src/practice/pages/Intake.tsx: …` (file does not exist)

- [ ] **Step 2: Implement** the page, hooks, Overview changes and routes as pinned.

- [ ] **Step 3: Verify**

Run: the Step 1 command, then `./node_modules/.bin/tsc -b --noEmit && ./node_modules/.bin/vite build && git checkout -- tsconfig.tsbuildinfo`
Expected: ui-check silent; tsc silent; `✓ built`

- [ ] **Step 4: Commit**

```bash
git add src/practice/pages/Intake.tsx src/practice/api.ts src/practice/pages/Overview.tsx src/practice/PracticeApp.tsx src/practice/pages/Settings.tsx
git commit -m "Portal: add-client wizard with due diligence, conflicts, declaration and full-mandate gate" -m "$TRAILER"
```

---

### Task 16: Portal letters, public signing page and director confirmation page

**Files:**
- Create: `src/practice/pages/Letters.tsx`, `src/practice/LetterEditor.tsx`, `src/practice/letterDocx.ts`, `src/pages/public/Sign.tsx`, `src/pages/public/DirectorConfirm.tsx`
- Modify: `supabase/functions/_shared/letter.ts` (add `docxXmlToBlocks`), `supabase/functions/_shared/letter_test.ts`
- Modify: `src/practice/api.ts`, `src/practice/PracticeApp.tsx:22-25` (NAV `['letters','Letters','file']` for leads), `:85-96` (routes `letters`, `letters/:lid`), `src/App.tsx:59-64,159-163` (lazy routes `/sign/:token`, `/sign`, `/confirm/:token`, `/confirm`)

**Interfaces:**
- Consumes: Task 9 RPCs (`practice_letter_templates`, `practice_letter_template_save`, `practice_letter_draft`, `practice_letter_save`, `practice_letter`, `practice_letter_send`, `practice_letter_upload_signed`, `practice_letter_void`), Task 12 edge actions (`letter_freeze`, `sign_*`, `director_*`), `renderModel`, `deriveMerge`, `LETTER_FIELDS`, `LetterBody` from `../../supabase/functions/_shared/letter.ts`.
- Produces:
  - `export function docxXmlToBlocks(xml: string): LetterBody` in `_shared/letter.ts` (paragraphs `w:p`; `w:pStyle` `Heading1`/`Title` → heading 1, `Heading2` → clause 2; `w:numPr/w:ilvl` 0/1 → list 3/4; text = concatenated `w:t` across runs; leading written numbers `^\d+(\.\d+)*\.?\s+`, `^\([a-z]+\)\s+`, `^\([ivx]+\)\s+` removed; `<`, `>` removed; empty paragraphs skipped; ids `b1`, `b2`, …).
  - `export async function docxToBlocks(file: File): Promise<LetterBody>` in `src/practice/letterDocx.ts` — refuses `file.size > 2 * 1024 * 1024`, total uncompressed entries `> 20 MB` or `word/document.xml > 8 MB` (checked through `fflate` `unzipSync` `filter` on `originalSize`) with `That Word file is too large to import.`.
  - `export function LetterEditor(props: { body: LetterBody; merge: MergeValues; variant: 'full'|'involved'; editable: boolean; onChange: (b: LetterBody) => void })` (add, edit, move, remove blocks; live numbered preview).
  - api hooks `useLetterTemplates(pid: string)`, `useLetter(lid: string | null)`; types `LetterTemplate`, `LetterDetail`.
  - Sign/Confirm token hygiene: on mount insert `<meta name="referrer" content="no-referrer">`, store the token in `sessionStorage` (`counta.sign` / `counta.confirm`), `history.replaceState(null, '', '/sign' | '/confirm')`; documents only through the 5-minute `doc_url`.
  - Director page copy (`director-provider`): `<firm> asks you, as a director of <business>, to confirm that it may open a business wallet and a tax wallet for <business>. The wallets are provided by TaxStreem through Flutterwave and hold the company's money.`; review result (`director-review`): `Thank you. TaxStreem will check this confirmation and tell <firm>.`
  - testids: Letters.tsx `letter-template-row`, `letter-template-new`, `letter-import-docx`, `letter-import-pdf`, `letter-merge-form`, `letter-save`, `letter-partner-sign`, `letter-send`, `letter-signer-name`, `letter-signer-email`, `letter-signer-title`, `letter-upload-signed`, `letter-void`, `letter-status`, `letter-events`; LetterEditor.tsx `letter-block`, `letter-block-text`, `letter-block-add`, `letter-preview`; Sign.tsx `sign-firm`, `sign-doc`, `sign-read`, `sign-mode-type`, `sign-mode-draw`, `sign-typed`, `sign-canvas`, `sign-send-code`, `sign-code`, `sign-submit`, `sign-done`, `sign-powered-by` (only when `!white_label`); DirectorConfirm.tsx `director-firm`, `director-provider`, `director-send-code`, `director-code`, `director-confirm`, `director-decline`, `director-decline-reason`, `director-done`, `director-review`.

- [ ] **Step 1: Write the failing tests**

```ts
// supabase/functions/_shared/letter_test.ts (added)
Deno.test('docx_xml_to_blocks', () => {
  const xml = '<w:document><w:body>'
    + '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>1. Scope</w:t></w:r></w:p>'
    + '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/></w:numPr></w:pPr><w:r><w:t>(a) Keep the </w:t></w:r><w:r><w:t>{{client.</w:t></w:r><w:r><w:t>name}} books</w:t></w:r></w:p>'
    + '<w:p/></w:body></w:document>';
  const b = docxXmlToBlocks(xml);
  assertEquals(b.blocks.map((x) => [x.kind, x.level, x.text]), [['heading', 1, 'Scope'], ['list', 3, 'Keep the {{client.name}} books']]);
});
```
and `node scripts/ui-check.mjs src/pages/public/Sign.tsx sign-firm sign-code sign-submit sign-powered-by && node scripts/ui-check.mjs src/pages/public/DirectorConfirm.tsx director-provider director-confirm director-decline director-review && node scripts/ui-check.mjs src/practice/pages/Letters.tsx letter-import-docx letter-partner-sign letter-send letter-upload-signed && node scripts/ui-check.mjs src/practice/LetterEditor.tsx letter-block letter-preview`

- [ ] **Step 2: Run them to verify they fail**

Run: `deno test --node-modules-dir=none --allow-read supabase/functions/_shared/letter_test.ts`
Expected: FAIL — `does not provide an export named 'docxXmlToBlocks'`; ui-check reports the missing files.

- [ ] **Step 3: Implement** as pinned.

- [ ] **Step 4: Verify**

Run: the Step 1 deno test and ui-check commands, then `./node_modules/.bin/tsc -b --noEmit && ./node_modules/.bin/vite build && git checkout -- tsconfig.tsbuildinfo`
Expected: `ok | 5 passed`; ui-check silent; tsc silent; `✓ built`

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/_shared src/practice/pages/Letters.tsx src/practice/LetterEditor.tsx src/practice/letterDocx.ts src/practice/api.ts src/practice/PracticeApp.tsx src/pages/public/Sign.tsx src/pages/public/DirectorConfirm.tsx src/App.tsx
git commit -m "Portal letters with Word import, public e-signing page and director confirmation page" -m "$TRAILER"
```

---

### Task 17: Portal client mandate panel, handover acceptance and business-app notices

**Files:**
- Create: `src/practice/MandatePanel.tsx`
- Modify: `src/practice/pages/Client.tsx:19-47` (panel and Activity tab when `mode === 'full'` or ended-kept; an "Opposing parties" card for every client), `:212` (`end()` hidden for full mandate), `src/practice/api.ts` (`ClientDetail.client.mode`, `end_kind`, `ClientDetail.mandate`, `usePracticeActivity(cid)`), `src/practice/Join.tsx:22-24,37-50,57-60` (`ph_` tokens), `src/shell/AppShell.tsx` (banners), `src/pages/settings/Accountant.tsx` (managed notice and the owner's activity list)

**Interfaces:**
- Consumes: `practice_client.mandate`, `practice_client.opposing_parties`, `practice_opposing_save`, `practice_activity`, `org_activity`, `practice_director_request`, `practice_set_send_mode`, `practice_set_alert_email`, `practice_handover_start` + `sendInvite('handover', id)`, `practice_end_mandate`, edge `practice` `export`, `practice_invite_preview` (kind `handover`), `practice_handover_accept`.
- Produces:
  - `export function MandatePanel({ d }: { d: ClientDetail })`; `sendInvite` kind union gains `'handover'`; `usePracticeActivity(cid: string, before?: number)` (key `['practice-activity', cid, before]`), `useOrgActivity(orgId: string)` in `src/lib/api.ts`.
  - Join.tsx: valid token `^p[mch]_[0-9a-f]{48}$`; handover title `Take over <business>`; lead `<practice> has run <business> on Counta for you. Accept to become its owner; <practice> keeps an accountant's place.`; button `handover-accept` → `practice_handover_accept` → `refreshMemberships()`, `setOrgId(r.org_id)`, navigate `/home`.
  - AppShell banners: `managed-banner` (`inv.org.managed_by && !inv.org.read_only_at`): `Full mandate: you are acting for the owner. Counta sends the client nothing and documents carry no Counta branding.`; `read-only-banner` (`inv.org.read_only_at`): `Read-only: this engagement has ended. Records are kept until <retain_until>.`
  - testids MandatePanel.tsx: `mandate-panel`, `director-status`, `director-request`, `director-name`, `director-email`, `director-phone`, `director-send`, `send-mode`, `alert-email`, `alert-email-save`, `handover-start`, `handover-email`, `handover-name`, `handover-send`, `end-mandate`, `end-mandate-reason`, `end-mandate-confirm`, `export-records`, `mandate-activity`, `activity-row`, `activity-more`; Client.tsx `opposing-parties`, `opposing-party-row`, `opposing-party-name`, `opposing-party-add`, `opposing-party-remove` (leads); Join.tsx `handover-accept`; AppShell.tsx `managed-banner`, `read-only-banner`; Accountant.tsx `managed-notice`, `org-activity`.

- [ ] **Step 1: Write the failing check**

Run: `node scripts/ui-check.mjs src/practice/MandatePanel.tsx mandate-panel director-request send-mode alert-email handover-start end-mandate-confirm export-records mandate-activity activity-row && node scripts/ui-check.mjs src/practice/pages/Client.tsx opposing-parties opposing-party-add && node scripts/ui-check.mjs src/practice/Join.tsx handover-accept && node scripts/ui-check.mjs src/shell/AppShell.tsx managed-banner read-only-banner && node scripts/ui-check.mjs src/pages/settings/Accountant.tsx managed-notice org-activity`
Expected: FAIL — `missing in src/practice/MandatePanel.tsx: …`

- [ ] **Step 2: Implement** as pinned.

- [ ] **Step 3: Verify**

Run: the Step 1 command, then `./node_modules/.bin/tsc -b --noEmit && ./node_modules/.bin/vite build && git checkout -- tsconfig.tsbuildinfo`
Expected: ui-check silent; tsc silent; `✓ built`

- [ ] **Step 4: Commit**

```bash
git add src/practice/MandatePanel.tsx src/practice/pages/Client.tsx src/practice/api.ts src/practice/Join.tsx src/shell/AppShell.tsx src/pages/settings/Accountant.tsx src/lib/api.ts
git commit -m "Portal mandate panel (director, send mode, handover, end, export, activity), handover acceptance, business-app notices" -m "$TRAILER"
```

---

### Task 18: Fees page, "Counta plans" rename and the Recurring invoices screen

**Files:**
- Create: `src/practice/pages/Fees.tsx`, `src/pages/sell/Recurring.tsx`
- Modify: `src/practice/PracticeApp.tsx:22-25` (NAV: `['fees','Fees','receipt']` for leads; `['billing','Counta plans','card']`), `:85-96` (route `fees`), `:126` (`ToPage` list adds `fees`), `src/practice/pages/Billing.tsx:86` (`PageHead title="Counta plans"`), `src/practice/api.ts` (`PracticeFees`, `usePracticeFees(pid)`), `src/App.tsx:40-45,171-176` (`/sell/recurring`), `src/shell/AppShell.tsx:26,183-185` (title `Recurring invoices`, nav item `['/sell/recurring', 'Recurring invoices']` in both lists), `src/lib/api.ts` (`RecurringSchedule`, `useRecurring(orgId)`)

**Interfaces:**
- Consumes: `practice_fees`, `practice_firm_business`, `practice_fee_customer`, `practice_fee_bill_retry`, `recurring_save`, `recurring_list`, `recurring_set_status`, `recurring_run_now`, `save_customer` lookups via existing customer hooks.
- Produces: `usePracticeFees(pid: string)` (key `['practice-fees', pid]`); `useRecurring(orgId: string | null)` (key `['recurring', orgId]`); `RecurringSchedule = { id; customer_id; customer_name; status: 'active'|'paused'|'ended'; frequency: 'monthly'|'quarterly'|'annually'; day_of_month: number; start_date; end_date: string|null; next_run: string; due_days: number; lines: { description: string; qty: number; unit_price: number; vat_treatment: string; once: boolean }[]; auto_send: boolean; send_channel: 'email'|'whatsapp'; failures: number; last_error: string|null; runs: { run_date; status; sale_id; number?; error?; send_error? }[] }`. Recurring screen opens with `?customer=<id>` preselected (the Fees page links there after `setOrgId(firm_org_id)`).
- testids: Fees.tsx `fees-firm-setup`, `fees-firm-create`, `fees-firm-link`, `fees-client-row`, `fees-customer`, `fees-outstanding`, `fees-schedule-row`, `fees-schedule-new`, `fee-bill-status`, `fee-bill-retry`, `fees-wallets`; Recurring.tsx `recurring-new`, `recurring-row`, `recurring-customer`, `recurring-frequency`, `recurring-day`, `recurring-start`, `recurring-end`, `recurring-due-days`, `recurring-line`, `recurring-line-once`, `recurring-auto-send`, `recurring-save`, `recurring-pause`, `recurring-resume`, `recurring-run-now`, `recurring-runs`. `recurring-day` offers 1–28 only.

- [ ] **Step 1: Write the failing check**

Run: `node scripts/ui-check.mjs src/practice/pages/Fees.tsx fees-firm-setup fees-client-row fees-outstanding fees-schedule-row fee-bill-retry fees-wallets && node scripts/ui-check.mjs src/pages/sell/Recurring.tsx recurring-new recurring-day recurring-line-once recurring-save recurring-run-now && grep -c "Counta plans" src/practice/PracticeApp.tsx src/practice/pages/Billing.tsx`
Expected: FAIL — `missing in src/practice/pages/Fees.tsx: …`; grep counts `0`

- [ ] **Step 2: Implement** as pinned.

- [ ] **Step 3: Verify**

Run: the Step 1 command (grep prints `src/practice/PracticeApp.tsx:1` and `src/practice/pages/Billing.tsx:1`), then `./node_modules/.bin/tsc -b --noEmit && ./node_modules/.bin/vite build && git checkout -- tsconfig.tsbuildinfo`
Expected: ui-check silent; counts 1 and 1; tsc silent; `✓ built`

- [ ] **Step 4: Commit**

```bash
git add src/practice/pages/Fees.tsx src/practice/pages/Billing.tsx src/practice/PracticeApp.tsx src/practice/api.ts src/pages/sell/Recurring.tsx src/App.tsx src/shell/AppShell.tsx src/lib/api.ts
git commit -m "Portal Fees page and Counta plans rename; Recurring invoices screen in the business app" -m "$TRAILER"
```

---

### Task 19: Admin portal Mandates page

**Files:**
- Create: `src/admin/pages/Mandates.tsx`
- Modify: `src/admin/AdminApp.tsx:29-34` (NAV `['mandates','Mandates','shield']`), `:120` (reviewers also see `mandates`), `:172-200` (route `mandates` in both route lists), `src/admin/api.ts` (`AdminMandates`, `useAdminMandates()`)

**Interfaces:**
- Consumes: `admin_mandates`, `admin_director_decide`, `admin_practice_suspend` (admins only; hidden for reviewers), `admin_mandate_flag_resolve`.
- Produces: `useAdminMandates()` (key `['admin-mandates']`); testids `mandate-reviews`, `director-review-row`, `director-approve`, `director-decline`, `director-note`, `mandate-practices`, `mandate-practice-row`, `practice-suspend`, `practice-resume`, `mandate-flags`, `mandate-flag-row`, `flag-resolve`. Each decision asks for a note (≥ 5 characters) before calling.

- [ ] **Step 1: Write the failing check**

Run: `node scripts/ui-check.mjs src/admin/pages/Mandates.tsx mandate-reviews director-review-row director-approve director-decline mandate-practice-row practice-suspend mandate-flag-row flag-resolve`
Expected: FAIL — `missing in src/admin/pages/Mandates.tsx: …`

- [ ] **Step 2: Implement** as pinned.

- [ ] **Step 3: Verify**

Run: the Step 1 command, then `./node_modules/.bin/tsc -b --noEmit && ./node_modules/.bin/vite build && git checkout -- tsconfig.tsbuildinfo`
Expected: ui-check silent; tsc silent; `✓ built`

- [ ] **Step 4: Commit**

```bash
git add src/admin/pages/Mandates.tsx src/admin/AdminApp.tsx src/admin/api.ts
git commit -m "Admin Mandates page: director confirmations under review, suspending a practice's full mandates, duplicate-company flags" -m "$TRAILER"
```

---

### Task 20: Documentation, end-to-end scenario and final verification

**Files:**
- Create: `supabase/tests/sql/99_full_mandate_e2e.sql`
- Modify: `docs/accountant-portal.md` (modes, intake and conflicts, letters and e-sign, full-mandate rules and gate, director confirmation, activity log, handover, end and export, fees, harness commands), `docs/messaging.md` (outbound gate and `suppressed`, white label, `practice_mail` kinds `letter_sign letter_code letter_done director_confirm director_code`, Meta templates end "Sent with Counta" so unbranded WhatsApp waits for `_nb` variants), `docs/selling.md` (recurring invoices), `docs/deleting-a-business.md` (retention block)

**Interfaces:**
- Consumes: every earlier task's RPCs and helpers.
- Produces: one scenario test proving the parts work together.

- [ ] **Step 1: Write the end-to-end test** — `supabase/tests/sql/99_full_mandate_e2e.sql` (fake people only: `Bisi Partner <partner@firm.example.test>`, `Tunde Bello <tunde.bello@director.example.test>`, `Ngozi Owner <owner@client.example.test>`)

```sql
-- test: e2e_full_mandate
-- verified practice + firm business (practice_firm_business) → intake with a director and a BO, risk low → practice_conflict_run = none
-- → practice_letter_draft(variant full) → svc_letter_frozen → practice_letter_send → svc_practice_mail('letter_code') → svc_sign_verify → svc_sign_complete
-- → practice_intake_declare → practice_mandate_gate ok → practice_create_business
assert (select role = 'admin' and acts_as_owner from members where org_id = o and user_id = partner), 'e2e_full_mandate: acting seat';
-- silence: alert to the client is re-addressed to the firm; customer email white-labelled
assert (select to_address from messages where org_id = o and template = 'alert' order by created_at desc limit 1) = 'partner@firm.example.test', 'e2e_full_mandate: silence';
-- money: locked → KYC as acting owner + svc_identity_nin verified → director request/confirm → payments_open
assert private.payments_open(o), 'e2e_full_mandate: director unlocked money';
-- fees: practice_fee_customer → recurring_save on the firm business → recurring_tick → fee invoice issued and mirrored
assert (select status from practice_fee_bills where client_id = c) = 'posted' and private.white_label(f, (select fee_customer_id from practice_clients where id = c)), 'e2e_full_mandate: fee invoice mirrored, unbranded';
-- handover → accept as Ngozi Owner
assert (select managed_by is null from orgs where id = o) and (select role from members where org_id = o and user_id = owner_user) = 'owner', 'e2e_full_mandate: handed over';
assert (select array_agg(distinct action) from activity_log where org_id = o and source = 'event') @> '{mandate_started,director_confirmed,fee_bill_posted,handover}', 'e2e_full_mandate: events recorded';
```

- [ ] **Step 2: Run it**

Run: `bash supabase/tests/run_tests.sh 99_full`
Expected: `PASS 99_full_mandate_e2e.sql` (if it fails, fix the owning task's code, not the scenario).

- [ ] **Step 3: Write the docs** (behaviour as built; no real-person data; cite RPC and table names from this plan).

- [ ] **Step 4: Final verification**

Run: `bash supabase/tests/run_tests.sh && bash supabase/tests/golden/run.sh check && bash supabase/tests/golden/run.sh sweep && deno test --node-modules-dir=none --allow-read supabase/functions/_shared/letter_test.ts supabase/functions/practice/ supabase/functions/messaging/wording_test.ts && deno check --node-modules-dir=none supabase/functions/practice/index.ts supabase/functions/messaging/index.ts supabase/functions/mono/index.ts && ./node_modules/.bin/tsc -b --noEmit && ./node_modules/.bin/vite build && git checkout -- tsconfig.tsbuildinfo && grep -rnoE "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}" supabase/tests supabase/functions/_shared supabase/functions/practice | grep -vE "@([a-z0-9-]+\.)*example\.test$"`
Expected: `ALL PASS (13 files)`, `golden OK (136 cases)`, `sweep OK (…)`, `ok | 14 passed` across the deno files, three `Check` lines, tsc silent, `✓ built`, and the final grep prints nothing (every address in tests and new function code is `@…example.test`).

- [ ] **Step 5: Commit**

```bash
git add supabase/tests/sql/99_full_mandate_e2e.sql docs/accountant-portal.md docs/messaging.md docs/selling.md docs/deleting-a-business.md
git commit -m "Practice management release 1: end-to-end full-mandate scenario and documentation" -m "$TRAILER"
```
