-- Practice management, part 8: the full-mandate gate, the business the firm sets up, the director's confirmation, money.
--
-- A firm runs a business under full mandate only through this gate (private.mandate_gate, each condition true or false):
-- the caller is an active partner whose own licence TaxStreem has verified; TaxStreem lets the firm run full mandates
-- (private.practice_can_full: a verified partner, not suspended); the intake is risk rated, names the company by an RC, BN
-- or IT number or a Tax ID, and its conflicts check is clear (private.intake_cleared); a full-mandate engagement letter for
-- the intake, signed by the firm after the last change to the intake's name, numbers or people, is signed by the client
-- or a signed copy is uploaded (private.mandate_letter); a partner has declared that the firm holds the client's written
-- authority. practice_create_business then sets
-- the business up with no owner: its name from the intake, an email the firm chooses, the client's own bank details on its
-- invoices, run by the practice (orgs.managed_by) with identity pending; a full, active client link billed to the practice;
-- the firm's partners and managers acting as its owner (the seat sync). A company someone already owns on Counta, or that
-- another practice runs (the same RC number or Tax ID, compared as the conflicts check compares them), is refused with a
-- plain answer and a flag for TaxStreem (practice_mandate_flags, private.company_taken); so is a CAC record found for the
-- business later (kyc_submit) that is someone else's, and one for a different company from the intake's.
--
-- Money stays shut (private.payments_open, private.require_payments_open: the wallet, the tax wallet, payment links,
-- payouts, bulk pay, tax payments, Flux) until the business's identity is verified and a director of the business has
-- confirmed, once, and while TaxStreem lets the firm run full mandates (the kill switch, admin_practice_suspend).
-- The director's confirmation (practice_director_confirmations) is the client's one involvement: the firm names a director
-- on the business's CAC record and their own email address (not a firm person's, the practice's, or on the firm's own
-- domain unless that is a free-mail one: private.firm_email, private.free_mail_domains); the director gets a dc_ link (only
-- its SHA-256 kept, 14 days) and a 6-digit code (the letters' rules: private.otp_*), on the firm's name only, and
-- confirms or declines on the confirmation page (the practice edge function calls svc_director_*). A confirmation from an
-- address one of the firm's people signed in from in the last 30 days, or one that cannot be read, waits for TaxStreem
-- (admin_director_decide); a refusal tells the firm and TaxStreem's reviewers.
--
-- Carried here as well: a full-mandate business starts no partner-programme referral (the practice pays for its plan
-- itself); each business a practice runs has its own business profile draft, apart from each person's own, so a firm
-- person can complete several (kyc_profiles.for_business); and the managing practice's places in such a business use none
-- of its plan's places for people.
--
-- Redefined functions are their latest definitions with only the changes described at each one; signatures are unchanged,
-- so create or replace keeps every grant.

-- ---------------------------------------------------------------------------
-- 1. Tables and the mandates setting
-- ---------------------------------------------------------------------------
-- status: pending (waiting for the director), review (the director confirmed; TaxStreem checks it), confirmed, declined
-- (by the director, or by TaxStreem on review), cancelled (replaced by a newer request). ip and ua: where the director
-- answered from. flags: what TaxStreem should know (review_reason, review_note).
create table public.practice_director_confirmations (
  id uuid primary key default gen_random_uuid(),
  practice_id uuid not null references public.practices(id) on delete cascade,
  client_id uuid not null references public.practice_clients(id) on delete cascade,
  name text not null check (length(trim(name)) between 2 and 120),
  email text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and length(email) <= 254),
  phone text check (length(phone) <= 40),
  token_hash text,
  token_expires timestamptz,
  sends_today int not null default 0,
  sends_day date,
  otp_hash text,
  otp_expires timestamptz,
  otp_tries int not null default 0,
  otp_failures int not null default 0,
  locked_at timestamptz,
  status text not null default 'pending' check (status in ('pending', 'review', 'confirmed', 'declined', 'cancelled')),
  ip text check (length(ip) <= 64),
  ua text check (length(ua) <= 300),
  flags jsonb not null default '{}' check (jsonb_typeof(flags) = 'object'),
  decline_reason text check (length(decline_reason) <= 500),
  decided_by uuid references auth.users(id) on delete set null,
  decided_at timestamptz,
  requested_by uuid references public.practice_members(id) on delete set null,
  created_at timestamptz not null default now(),
  confirmed_at timestamptz
);
create index practice_director_confirmations_client on public.practice_director_confirmations(client_id, created_at desc);
create index practice_director_confirmations_practice on public.practice_director_confirmations(practice_id);
create index practice_director_confirmations_token on public.practice_director_confirmations(token_hash) where token_hash is not null;
create index practice_director_confirmations_review on public.practice_director_confirmations(created_at) where status = 'review';
create index practice_director_confirmations_decided_by on public.practice_director_confirmations(decided_by) where decided_by is not null;
create index practice_director_confirmations_requested_by on public.practice_director_confirmations(requested_by) where requested_by is not null;
alter table public.practice_director_confirmations enable row level security;
revoke all on public.practice_director_confirmations from anon, authenticated;

-- What TaxStreem should look at: a company someone else already has on Counta (duplicate_company), a director who declined
-- (director_declined), a confirmation held for review (director_review). Resolved by TaxStreem with a note.
create table public.practice_mandate_flags (
  id uuid primary key default gen_random_uuid(),
  practice_id uuid not null references public.practices(id) on delete cascade,
  intake_id uuid references public.practice_intakes(id) on delete set null,
  client_id uuid references public.practice_clients(id) on delete set null,
  kind text not null check (kind in ('duplicate_company', 'director_declined', 'director_review')),
  detail jsonb not null default '{}' check (jsonb_typeof(detail) = 'object'),
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references auth.users(id) on delete set null,
  resolution_note text check (length(resolution_note) <= 1000)
);
create index practice_mandate_flags_open on public.practice_mandate_flags(created_at desc) where resolved_at is null;
create index practice_mandate_flags_practice on public.practice_mandate_flags(practice_id);
create index practice_mandate_flags_intake on public.practice_mandate_flags(intake_id) where intake_id is not null;
create index practice_mandate_flags_client on public.practice_mandate_flags(client_id) where client_id is not null;
create index practice_mandate_flags_resolved_by on public.practice_mandate_flags(resolved_by) where resolved_by is not null;
alter table public.practice_mandate_flags enable row level security;
revoke all on public.practice_mandate_flags from anon, authenticated;

-- platform_settings key 'mandates': {free_mail_domains: [...]}, more free-mail domains than the built-in list.
alter table public.platform_settings drop constraint if exists platform_settings_key_check;
alter table public.platform_settings add constraint platform_settings_key_check check (key in ('martina', 'limits', 'switches', 'alerts', 'partners', 'mandates'));

-- ---------------------------------------------------------------------------
-- 2. The firm's addresses
-- ---------------------------------------------------------------------------
-- Domains anyone can have an address on: a firm person's address there says nothing about the firm. The built-in list,
-- and those TaxStreem adds in the mandates setting (lower case, without a leading @).
create or replace function private.free_mail_domains() returns text[]
language sql stable set search_path = public, private as $$
  select array['gmail.com', 'googlemail.com', 'yahoo.com', 'yahoo.co.uk', 'ymail.com', 'outlook.com', 'hotmail.com', 'live.com', 'msn.com',
      'icloud.com', 'me.com', 'aol.com', 'proton.me', 'protonmail.com', 'gmx.com', 'zoho.com', 'mail.com']
    || coalesce((select array_agg(distinct ltrim(lower(trim(d)), '@')) from jsonb_array_elements_text(z.v) d where ltrim(trim(d), '@') <> ''), '{}')
  from (select case when jsonb_typeof(coalesce(private.setting('mandates'), '{}')->'free_mail_domains') = 'array'
                    then coalesce(private.setting('mandates'), '{}')->'free_mail_domains' else '[]'::jsonb end as v) z
$$;

-- Whether an address is the firm's, compared without case or surrounding spaces: 'member' when it is one of the practice's
-- people's (whatever their status), 'practice' when it is the practice's own, 'domain' when it is on the domain of one of
-- those, or a subdomain of it, and that domain is not a free-mail one; else null. The one "is this the firm's address"
-- rule (the outbound gate's private.firm_addresses keeps exact addresses for sending).
create or replace function private.firm_email(p_practice uuid, p_email text) returns text
language sql stable set search_path = public, private as $$
  with e as (select lower(trim(coalesce(p_email, ''))) as email, substring(lower(trim(coalesce(p_email, ''))) from '@([^@]+)$') as domain),
  firm as (
    select 'member' as kind, lower(trim(pm.email)) as email from practice_members pm where pm.practice_id = p_practice and pm.email is not null
    union all
    select 'practice', lower(trim(p.email)) from practices p where p.id = p_practice and p.email is not null),
  firm_domains as (
    select distinct substring(f.email from '@([^@]+)$') as domain from firm f
    where substring(f.email from '@([^@]+)$') is not null and not (substring(f.email from '@([^@]+)$') = any (private.free_mail_domains())))
  select case
    when e.email = '' then null
    when exists (select 1 from firm f where f.kind = 'member' and f.email = e.email) then 'member'
    when exists (select 1 from firm f where f.kind = 'practice' and f.email = e.email) then 'practice'
    when exists (select 1 from firm_domains d where e.domain = d.domain or right(e.domain, length(d.domain) + 1) = '.' || d.domain) then 'domain' end
  from e
$$;

-- ---------------------------------------------------------------------------
-- 3. The gate
-- ---------------------------------------------------------------------------
-- The intake's full-mandate letter as the intake stands: signed by the client (or a signed copy uploaded), and fixed by the
-- firm (the partner's signature, or the upload of a letter never signed in Counta) no earlier than the last change to the
-- intake's name, numbers or people (edited_at). A letter for the company as it was described before does not count. The
-- latest such letter, or nothing.
create or replace function private.mandate_letter(i public.practice_intakes) returns public.engagement_letters
language sql stable set search_path = public, private as $$
  select l.* from engagement_letters l
  cross join lateral (select coalesce(l.partner_signed_at,
    (select max(e.at) from engagement_letter_events e where e.letter_id = l.id and e.kind = 'uploaded')) as fixed_at) f
  where l.intake_id = i.id and l.variant = 'full' and l.status in ('completed', 'uploaded') and f.fixed_at >= i.edited_at
  order by f.fixed_at desc, l.id
  limit 1
$$;

-- Each condition for taking the intake's business on under full mandate, as the signed-in person, and ok when all hold.
-- rc_or_tax_id: the intake names the company by its RC, BN or IT number or its Tax ID (so it can be told apart from a
-- company already on Counta).
create or replace function private.mandate_gate(p_intake uuid) returns jsonb
language plpgsql stable set search_path = public, private as $$
declare i public.practice_intakes; m public.practice_members; g jsonb;
begin
  select * into i from practice_intakes where id = p_intake;
  if i.id is null then raise exception 'Intake not found.'; end if;
  m := private.practice_me(i.practice_id);
  g := jsonb_build_object(
    'partner_verified', coalesce(m.role = 'partner' and m.licence_status = 'verified', false),
    'practice_can_full', private.practice_can_full(i.practice_id),
    'risk_rated', i.risk_rating is not null,
    'rc_or_tax_id', private.norm_id(i.rc_number) is not null or private.norm_id(i.tax_id) is not null,
    'conflicts_cleared', private.intake_cleared(i),
    'letter_completed', (private.mandate_letter(i)).id is not null,
    'authority_declared', i.authority_declared_at is not null);
  return g || jsonb_build_object('ok', not exists (select 1 from jsonb_each(g) x where x.value = 'false'::jsonb));
end $$;

-- Takes the transaction's turn on a company's numbers (its RC number and Tax ID, as the conflicts check compares them, in
-- a fixed order): two set-ups or business profiles of the same company wait for each other, so the later one sees the
-- earlier one's business.
create or replace function private.company_lock(p_rc text, p_tax text) returns void
language plpgsql set search_path = public, private as $$
declare x text;
begin
  for x in select k from unnest(array['company:rc:' || private.norm_id(p_rc), 'company:tax:' || private.norm_id(p_tax)]) k where k is not null order by k loop
    perform pg_advisory_xact_lock(hashtextextended(x, 0));
  end loop;
end $$;

-- The business already on Counta that is this company (the same RC number or Tax ID) and someone else's: owned by a
-- person who signed in, or run by a practice other than p_practice. Never p_except itself or a sample business.
-- {org_id, matched_on: rc_number|tax_id}, or null. Takes the company's turn first (private.company_lock).
create or replace function private.company_taken(p_rc text, p_tax text, p_practice uuid, p_except uuid) returns jsonb
language plpgsql set search_path = public, private as $$
declare v_rc text := private.norm_id(p_rc); v_tax text := private.norm_id(p_tax); r jsonb;
begin
  perform private.company_lock(p_rc, p_tax);
  if v_rc is null and v_tax is null then return null; end if;
  select jsonb_build_object('org_id', o.id, 'matched_on', case when private.norm_id(o.rc_number) = v_rc then 'rc_number' else 'tax_id' end) into r
  from orgs o
  where o.id is distinct from p_except and not o.is_sample and (private.norm_id(o.rc_number) = v_rc or private.norm_id(o.tin) = v_tax)
    and ((o.managed_by is not null and o.managed_by is distinct from p_practice)
      or exists (select 1 from members x where x.org_id = o.id and x.role = 'owner' and x.status = 'active' and x.user_id is not null))
  order by o.created_at, o.id
  limit 1;
  return r;
end $$;

-- The gate for the portal (partners and managers).
create or replace function public.practice_mandate_gate(p_intake uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.practice_intakes;
begin
  i := private.intake_require(p_intake);
  return private.mandate_gate(i.id);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Setting up the business
-- ---------------------------------------------------------------------------
-- A verified partner sets up the intake's business under full mandate, once the gate is open. p: {email (the address the
-- business uses, the firm's choice), phone?, vat_registered? (yes unless said), bank_details? (the client's own account,
-- shown on invoices until the wallets open; up to 500 characters), engagement_partner_id? (else the caller), alert_email?
-- (one of the firm's addresses)}. A company that someone already owns on Counta, or that another practice runs, is not set
-- up again: {ok: false, reason: duplicate}, and TaxStreem is flagged (once while the flag is open). Otherwise the business
-- (no owner, identity pending), the client link (kept as long as the signed letter says) and the firm's places:
-- {ok: true, org_id, client_id}.
create or replace function public.practice_create_business(p_intake uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.practice_intakes; m public.practice_members; pr public.practices; g jsonb; v_missing text;
  v_email text; v_phone text; v_vat boolean; v_bank text; v_alert text; v_ep uuid; v_years int; v_dup jsonb; v_org uuid; v_client uuid;
begin
  i := private.intake_require(p_intake, true);
  m := private.practice_me(i.practice_id);
  if jsonb_typeof(p) is distinct from 'object' then raise exception 'Nothing to set up.'; end if;
  if i.status = 'declined' then raise exception 'This intake was declined after the conflicts check.'; end if;
  if i.status <> 'draft' or i.client_id is not null then raise exception 'This intake has a client already. Start a new intake for another business.'; end if;
  g := private.mandate_gate(i.id);
  select string_agg(k, ', ' order by n) into v_missing
  from unnest(array['partner_verified', 'practice_can_full', 'risk_rated', 'rc_or_tax_id', 'conflicts_cleared', 'letter_completed',
    'authority_declared']) with ordinality u(k, n)
  where not coalesce((g->>k)::boolean, false);
  if v_missing is not null then raise exception 'Full mandate needs: %', v_missing; end if;

  v_email := lower(trim(coalesce(p->>'email', '')));
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 254 then
    raise exception 'Enter the email address the business will use (the firm chooses it).';
  end if;
  v_phone := nullif(trim(coalesce(p->>'phone', '')), '');
  if length(v_phone) > 40 then raise exception 'That phone number is too long.'; end if;
  if jsonb_typeof(p->'vat_registered') not in ('boolean', 'null') and coalesce(p->>'vat_registered', '') not in ('true', 'false') then
    raise exception 'Say yes or no to whether the business is registered for VAT.';
  end if;
  v_vat := coalesce((p->>'vat_registered')::boolean, true);
  v_bank := nullif(trim(coalesce(p->>'bank_details', '')), '');
  if length(v_bank) > 500 then raise exception 'Keep the bank details under 500 characters.'; end if;
  v_alert := nullif(lower(trim(coalesce(p->>'alert_email', ''))), '');
  if v_alert is not null and (v_alert !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or private.firm_email(i.practice_id, v_alert) is null) then
    raise exception 'Use an address of the firm.';
  end if;
  v_ep := coalesce(private.uuid_of(nullif(p->>'engagement_partner_id', '')), m.id);
  if (nullif(p->>'engagement_partner_id', '') is not null and private.uuid_of(p->>'engagement_partner_id') is null)
     or not exists (select 1 from practice_members where id = v_ep and practice_id = i.practice_id and role in ('partner', 'manager') and status = 'active') then
    raise exception 'The engagement partner must be one of the firm''s active partners or managers.';
  end if;

  -- The same company already on Counta: owned by someone who signed in, or run by another practice. (Its numbers stay
  -- this transaction's until it ends, so another practice setting it up at the same moment sees this one.)
  v_dup := private.company_taken(i.rc_number, i.tax_id, i.practice_id, null);
  if v_dup is not null then
    insert into practice_mandate_flags (practice_id, intake_id, kind, detail)
    select i.practice_id, i.id, 'duplicate_company', v_dup || jsonb_build_object('by', m.id)
    where not exists (select 1 from practice_mandate_flags f where f.intake_id = i.id and f.kind = 'duplicate_company' and f.resolved_at is null);
    return jsonb_build_object('ok', false, 'reason', 'duplicate');
  end if;

  select * into pr from practices where id = i.practice_id;
  v_org := private.create_org_core(i.legal_name, v_email, v_phone, jsonb_build_array(jsonb_build_object('name', 'Head office', 'address', i.address)),
    v_vat, false);
  update orgs set managed_by = i.practice_id, identity_status = 'pending', invoice_note = v_bank, rc_number = nullif(trim(i.rc_number), ''),
    tin = nullif(trim(i.tax_id), ''), address = i.address
  where id = v_org;
  v_years := (private.mandate_letter(i)).retention_years;
  -- (The intake is engaged on the link by practice_clients_intake.)
  insert into practice_clients (practice_id, org_id, status, initiated_by, business_name, billing, mode, intake_id, engagement_partner_id,
    alert_email, retention_years, started_at, created_by)
  values (i.practice_id, v_org, 'active', 'practice', left(i.legal_name, 120), 'practice', 'full', i.id, v_ep, v_alert, v_years, now(), auth.uid())
  returning id into v_client;
  perform private.practice_sync_seats(v_client);
  perform private.activity_event(v_org, 'mandate_started', 'Full mandate started by ' || pr.name,
    jsonb_build_object('practice_id', i.practice_id, 'client_id', v_client, 'intake_id', i.id));
  return jsonb_build_object('ok', true, 'org_id', v_org, 'client_id', v_client);
end $$;

-- ---------------------------------------------------------------------------
-- 5. Money
-- ---------------------------------------------------------------------------
-- payments_open: as before, and a business a practice runs also needs a director's confirmation and the practice still
-- allowed to run full mandates.
create or replace function private.payments_open(p_org uuid) returns boolean
language sql stable security definer set search_path = public, private as $$
  select coalesce((select identity_status in ('not_required', 'verified', 'approved')
      and (managed_by is null or (director_confirmed_at is not null and private.practice_can_full(managed_by)))
    from orgs where id = p_org), false)
$$;

-- require_payments_open: as before, then the same for a business a practice runs.
create or replace function private.require_payments_open(p_org uuid) returns void
language plpgsql stable security definer set search_path = public, private as $$
declare v_status text; v_managed uuid; v_confirmed timestamptz;
begin
  if not private.feature_on(p_org, 'payments') then
    raise exception 'TaxStreem has paused payments for this business for now. The books still work; contact TaxStreem to find out more.' using errcode = '42501';
  end if;
  select identity_status, managed_by, director_confirmed_at into v_status, v_managed, v_confirmed from orgs where id = p_org;
  if v_status in ('not_required', 'verified', 'approved') then
    if v_managed is null or (v_confirmed is not null and private.practice_can_full(v_managed)) then return; end if;
    raise exception 'Payments open once a director of the business confirms, and while the firm may run full mandates.' using errcode = '42501';
  end if;
  raise exception '%', case v_status
    when 'review' then 'Payments open once TaxStreem has checked the NIN slip. This usually takes a working day.'
    when 'rejected' then 'Payments are locked: TaxStreem could not confirm a director''s identity. A director can do the NIN check in Settings.'
    else 'Payments open once a director confirms their NIN. Do the NIN check in Settings, Business identity, or ask Martina.' end
    using errcode = '42501';
end $$;

-- get_inventory: org.payments_open is private.payments_open.
create or replace function public.get_inventory(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_cost boolean; v_tz text; v jsonb; v_today date;
begin
  m := private.require(p_org, null);
  v_cost := private.perm_of(m, 'see_margins') or private.perm_of(m, 'edit_prices');
  select timezone into v_tz from orgs where id = p_org;
  v_today := (now() at time zone v_tz)::date;
  -- Usage counts sales and stock issued to jobs (less returns). Past sales brought over from another system fill in
  -- the days before Counta has its own.
  with sales as (
    select item_id,
      sum(-qty) filter (where recorded_at >= now() - interval '30 days') sold_30,
      sum(-qty) filter (where recorded_at >= now() - interval '60 days' and recorded_at < now() - interval '30 days') sold_prev30,
      sum(-qty * coalesce(unit_price, 0)) filter (where recorded_at >= now() - interval '30 days' and type in ('sale', 'voice_sale')) revenue_30,
      sum(-qty * unit_cost) filter (where recorded_at >= now() - interval '30 days' and type in ('sale', 'voice_sale')) cogs_30,
      max(recorded_at) filter (where qty < 0) last_sale_at
    from movements where org_id = p_org and type in ('sale', 'voice_sale', 'issue', 'issue_return')
    group by item_id),
  hist as (
    select item_id,
      sum(qty * private.overlap_days(day_from, day_to, v_today - 29, v_today) / (day_to - day_from + 1)) sold_30,
      sum(qty * private.overlap_days(day_from, day_to, v_today - 59, v_today - 30) / (day_to - day_from + 1)) sold_prev30,
      sum(coalesce(revenue, 0) * private.overlap_days(day_from, day_to, v_today - 29, v_today) / (day_to - day_from + 1)) revenue_30,
      min(day_from) first_day, max(day_to) last_day
    from sales_history where org_id = p_org group by item_id),
  firsts as (
    select item_id, min(recorded_at) first_at, max(recorded_at) last_move_at from movements where org_id = p_org group by item_id),
  lv as (
    select item_id, jsonb_object_agg(location_id, qty) q from stock_levels where org_id = p_org group by item_id)
  select jsonb_build_object(
    'org', (select to_jsonb(o) - 'identity' || jsonb_build_object('payments_open', private.payments_open(o.id)) from orgs o where o.id = p_org),
    'me', to_jsonb(m),
    'can_see_costs', v_cost,
    'now', now(),
    'today', (now() at time zone v_tz)::date,
    'locations', (select coalesce(jsonb_agg(to_jsonb(l) order by l.is_main desc, l.created_at), '[]'::jsonb) from locations l where l.org_id = p_org),
    'vendors', (select coalesce(jsonb_agg(to_jsonb(vd) order by vd.name), '[]'::jsonb) from vendors vd where vd.org_id = p_org),
    'members', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', mb.id, 'display_name', mb.display_name, 'role', mb.role, 'title', mb.title, 'location_id', mb.location_id,
        'status', mb.status, 'email', mb.email, 'phone', mb.phone, 'has_login', mb.user_id is not null, 'is_me', mb.id = m.id,
        'voice_confirmed', mb.voice_confirmed,
        'perms', case when mb.role = 'owner' then private.role_template('owner') else private.member_perms(mb) end,
        'role_label', private.role_label(mb.role)
      ) order by (mb.role = 'owner') desc, mb.created_at), '[]'::jsonb) from members mb where mb.org_id = p_org and mb.status <> 'disabled'),
    'items', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', i.id, 'name', i.name, 'photo_path', i.photo_path, 'barcode', i.barcode, 'sku', i.sku, 'qr_code', i.qr_code,
        'category', i.category, 'vat_treatment', i.vat_treatment, 'nafdac_no', i.nafdac_no, 'purchase_unit', i.purchase_unit,
        'pack_size', i.pack_size, 'selling_unit', i.selling_unit, 'informal_unit', i.informal_unit, 'track_batches', i.track_batches,
        'reorder_floor', i.reorder_floor, 'preferred_vendor_id', i.preferred_vendor_id, 'alt_vendor_id', i.alt_vendor_id,
        'price', i.price, 'import_priced', i.import_priced, 'notes', i.notes, 'needs_review', i.needs_review, 'created_at', i.created_at,
        'item_type', i.item_type, 'brand', i.brand, 'description', i.description, 'attributes', i.attributes,
        'inventory_account', i.inventory_account,
        'vat_basis', i.vat_basis, 'vat_review', i.vat_review, 'vat_confidence', i.vat_confidence, 'vat_checked', i.vat_checked_at is not null,
        'wac', case when v_cost then c.wac end, 'last_cost', case when v_cost then c.last_cost end,
        'replacement_cost', case when v_cost then c.replacement_cost end,
        'replacement_source', case when v_cost then c.replacement_source end,
        'qty', coalesce(lv.q, '{}'::jsonb),
        'sold_30', round(coalesce(s.sold_30, 0) + coalesce(h.sold_30, 0), 3), 'sold_prev30', round(coalesce(s.sold_prev30, 0) + coalesce(h.sold_prev30, 0), 3),
        'revenue_30', round(coalesce(s.revenue_30, 0) + coalesce(h.revenue_30, 0), 2),
        'cogs_30', case when v_cost then coalesce(s.cogs_30, 0) end,
        'last_sale_at', greatest(s.last_sale_at, (h.last_day::timestamp + interval '12 hours') at time zone v_tz),
        'first_at', least(f.first_at, h.first_day::timestamp at time zone v_tz), 'last_move_at', f.last_move_at,
        'has_history', h.item_id is not null,
        'snoozed_until', (select until from reorder_snoozes rs where rs.item_id = i.id)
      ) order by i.name), '[]'::jsonb)
      from items i left join item_costs c on c.item_id = i.id left join sales s on s.item_id = i.id left join hist h on h.item_id = i.id
        left join firsts f on f.item_id = i.id left join lv on lv.item_id = i.id
      where i.org_id = p_org and not i.archived),
    'batches', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'item_id', b.item_id, 'location_id', b.location_id, 'batch_no', b.batch_no, 'expiry_date', b.expiry_date,
        'qty_remaining', b.qty_remaining, 'qty_received', b.qty_received, 'quarantined', b.quarantined, 'quarantined_at', b.quarantined_at
      ) order by b.expiry_date nulls last), '[]'::jsonb)
      from batches b where b.org_id = p_org and (b.qty_remaining > 0 or b.quarantined_at > now() - interval '60 days'))
  ) into v;
  return v;
end $$;

-- identity_json: payments_open is private.payments_open (the business identity screen says what the lock says).
create or replace function private.identity_json(p_org uuid, p_owner boolean) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs;
begin
  select * into o from orgs where id = p_org;
  return jsonb_build_object(
    'status', o.identity_status,
    'payments_open', private.payments_open(p_org),
    'can_check', p_owner,
    'method', o.identity->>'method', 'matched', o.identity->>'matched', 'matched_role', o.identity->>'matched_role',
    'last4', o.identity->>'last4', 'at', o.identity->>'at',
    'attempts', coalesce((o.identity->>'attempts')::int, 0),
    'registered', exists (select 1 from kyc_profiles k where k.org_id = p_org and k.status = 'submitted' and k.source = 'cac'),
    'people', (select coalesce(jsonb_agg(jsonb_build_object('name', x->>'name', 'role', x->>'role')), '[]'::jsonb) from jsonb_array_elements(private.identity_people(p_org)) x),
    'slip', case when p_owner then o.identity->'slip' end,
    'review', o.identity->'review');
end $$;

-- admin_business: payments_open is private.payments_open (and the payments switch, as before).
create or replace function public.admin_business(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; v_owner uuid; v_month timestamptz := now() - interval '30 days'; k text; v_sw jsonb := '[]'::jsonb;
begin
  perform private.require_staff();
  select * into o from orgs where id = p_org;
  if not found then raise exception 'Business not found.'; end if;
  select user_id into v_owner from members where org_id = p_org and role = 'owner' order by created_at limit 1;
  foreach k in array private.feature_keys() loop
    if k <> 'new_businesses' then
      v_sw := v_sw || jsonb_build_object('feature', k, 'on', private.feature_on(p_org, k),
        'override', (select jsonb_build_object('enabled', s.enabled, 'note', s.note, 'at', s.set_at, 'by', (select email from auth.users u where u.id = s.set_by))
                     from org_switches s where s.org_id = p_org and s.feature = k));
    end if;
  end loop;
  return jsonb_build_object(
    'org', jsonb_build_object('id', o.id, 'name', o.name, 'rc_number', o.rc_number, 'legal_form', o.legal_form, 'tin', o.tin, 'industry', o.industry,
      'offering', o.offering, 'category_id', o.category_id, 'email', o.email, 'phone', o.phone, 'address', o.address, 'created_at', o.created_at,
      'is_sample', o.is_sample, 'vat_registered', o.vat_registered, 'payment_rail', o.payment_rail, 'taxstreem_org_id', o.taxstreem_org_id,
      'voice_id', o.voice_id, 'voice_lang', o.voice_lang),
    'identity', jsonb_build_object('status', o.identity_status, 'last4', o.identity->'nin'->>'last4', 'checked_at', o.identity->'nin'->>'at',
      'slip', (o.identity->'slip') is not null, 'review', o.identity->'review', 'attempts', coalesce((o.identity->>'attempts')::int, 0)),
    'people', (select coalesce(jsonb_agg(jsonb_build_object('name', mb.display_name, 'role', mb.role, 'title', mb.title, 'status', mb.status,
        'email', coalesce(mb.email, u.email), 'joined', mb.created_at, 'last_sign_in', u.last_sign_in_at) order by mb.role = 'owner' desc, mb.created_at), '[]'::jsonb)
      from members mb left join auth.users u on u.id = mb.user_id where mb.org_id = p_org),
    'onboarding', case when v_owner is null then null else (select jsonb_build_object('steps', private.guide_steps(v_owner, p_org, coalesce(g.marks, '{}'::jsonb)),
        'last_seen', g.last_seen_at, 'completed', g.completed_at, 'language', g.language) from (select 1) one left join guide_progress g on g.user_id = v_owner) end,
    'wallet', (select jsonb_build_object('status', w.status, 'rail', w.rail, 'bank', w.bank_name, 'account_number', w.account_number, 'error', w.error, 'opened', w.created_at)
      from wallets w where w.org_id = p_org order by w.created_at desc limit 1),
    'payments_open', private.payments_open(p_org) and private.feature_on(p_org, 'payments'),
    'switches', v_sw,
    'usage', jsonb_build_object(
      'sales', (select count(*) from sales where org_id = p_org and created_at >= v_month),
      'messages', (select coalesce(jsonb_object_agg(st, n), '{}'::jsonb) from (select status st, count(*) n from messages where org_id = p_org and created_at >= v_month group by status) x),
      'calls', (select coalesce(jsonb_object_agg(st, n), '{}'::jsonb) from (select status st, count(*) n from voice_calls where org_id = p_org and created_at >= v_month group by status) x),
      'ai_reads', (select count(*) from ai_logs where org_id = p_org and created_at >= v_month),
      'martina', (select count(*) from guide_sessions gs where gs.started_at >= v_month and gs.user_id in (select user_id from members where org_id = p_org and user_id is not null))),
    'failures', private.platform_failures(now() - interval '30 days', p_org, 30));
end $$;

-- ---------------------------------------------------------------------------
-- 6. The director's confirmation
-- ---------------------------------------------------------------------------
-- Whether the practice still runs the client link's business under full mandate (an ended mandate or a handover closes
-- any confirmation still out).
create or replace function private.director_mandate_open(p_client uuid, p_practice uuid) returns boolean
language sql stable set search_path = public, private as $$
  select exists (select 1 from practice_clients c join orgs o on o.id = c.org_id
                 where c.id = p_client and c.practice_id = p_practice and c.status = 'active' and c.mode = 'full' and o.managed_by = c.practice_id)
$$;

-- An address as compared for the director's check: the host alone (no netmask), and an IPv4 address written as IPv6
-- (::ffff:a.b.c.d) as the IPv4 address.
create or replace function private.ip_host(p inet) returns inet
language sql immutable set search_path = '' as $$
  select case when p is null then null
    when family(p) = 6 and host(p) ~* '^::ffff:[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' then substring(host(p) from 8)::inet
    else host(p)::inet end
$$;

-- The confirmation a presented link belongs to (locked), or nothing.
create or replace function private.director_by_token(p_token text) returns public.practice_director_confirmations
language plpgsql set search_path = public, private as $$
declare d public.practice_director_confirmations;
begin
  if coalesce(p_token, '') ~ '^dc_[0-9a-f]{48}$' then
    select * into d from practice_director_confirmations where token_hash = private.sha256_hex(p_token) for update;
  end if;
  return d;
end $$;

-- Why the director cannot answer now, or null while the confirmation waits for them: invalid (no such link, or replaced),
-- expired, closed (the firm no longer runs the business under full mandate), or its status (review, confirmed, declined).
create or replace function private.director_state(d public.practice_director_confirmations) returns text
language sql stable set search_path = public, private as $$
  select case when d.id is null or d.status = 'cancelled' then 'invalid'
    when d.token_expires is null or d.token_expires <= now() then 'expired'
    when not private.director_mandate_open(d.client_id, d.practice_id) then 'closed'
    when d.status <> 'pending' then d.status end
$$;

-- The practice's partners and managers ask a director of a business the firm runs to confirm, once its identity is
-- verified. p: {name (as on the CAC record), email (the director's own), phone?}. A request waiting is replaced (its link
-- stops working); none while TaxStreem checks a confirmation; five requests a day for a business. The link goes out by
-- email (svc_practice_mail director_confirm).
create or replace function public.practice_director_request(p_client uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients; m public.practice_members; o public.orgs; d public.practice_director_confirmations;
  v_name text; v_email text; v_phone text; v_t text[]; v_people jsonb;
begin
  select * into c from practice_clients where id = p_client for update;
  if c.id is null or c.practice_id is null then raise exception 'Client not found.'; end if;
  m := private.practice_require(c.practice_id, true);
  select * into o from orgs where id = c.org_id;
  if c.mode <> 'full' or c.status <> 'active' or o.managed_by is distinct from c.practice_id then
    raise exception 'A director confirms only for a business the firm runs under full mandate.';
  end if;
  -- The CAC record is read only by someone acting as the business's owner (the firm's partners and managers have such a
  -- place while they are active).
  if not private.acts_as_owner(o.id, auth.uid()) then
    raise exception 'Only the firm''s people acting as the business''s owner ask a director to confirm.' using errcode = '42501';
  end if;
  if o.director_confirmed_at is not null then raise exception 'A director of the business has confirmed already.'; end if;
  if o.identity_status not in ('verified', 'approved') then raise exception 'Verify the business''s identity first.'; end if;
  -- A confirmation TaxStreem is checking is not gone round by asking again.
  if exists (select 1 from practice_director_confirmations where client_id = c.id and status = 'review') then
    raise exception 'TaxStreem is checking the director''s last confirmation. Wait for its decision.';
  end if;
  if jsonb_typeof(p) is distinct from 'object' then raise exception 'Enter the director''s name and email address.'; end if;
  v_name := trim(coalesce(p->>'name', ''));
  v_email := lower(trim(coalesce(p->>'email', '')));
  v_phone := nullif(trim(coalesce(p->>'phone', '')), '');
  if length(v_name) not between 2 and 120 then raise exception 'Enter the director''s name as it is on the CAC record.'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 254 then raise exception 'Enter the director''s email address.'; end if;
  if length(v_phone) > 40 then raise exception 'That phone number is too long.'; end if;
  -- The name as the NIN check matches people: without accents, titles or punctuation, in either order.
  v_t := private.name_tokens(private.fold_name(v_name));
  select coalesce(jsonb_agg(jsonb_build_object('role', x->>'role', 'name', private.fold_name(x->>'name'), 'surname', private.fold_name(x->>'surname'),
      'given', private.fold_name(x->>'given'))), '[]'::jsonb)
    into v_people from jsonb_array_elements(private.identity_people(o.id)) x;
  if cardinality(v_t) < 2
     or private.identity_match(v_t[1], array_to_string(v_t[2:cardinality(v_t) - 1], ' '), v_t[cardinality(v_t)], v_people) is null then
    raise exception 'That name is not a director on the CAC record.';
  end if;
  if private.firm_email(c.practice_id, v_email) is not null then raise exception 'Use the director''s own email address, not the firm''s.'; end if;
  if (select count(*) from practice_director_confirmations where client_id = c.id and created_at > now() - interval '1 day') >= 5 then
    raise exception 'That is five requests for this business today. Try again tomorrow.';
  end if;
  update practice_director_confirmations set status = 'cancelled', token_hash = null, token_expires = null, otp_hash = null, otp_expires = null
  where client_id = c.id and status = 'pending';
  insert into practice_director_confirmations (practice_id, client_id, name, email, phone, requested_by)
  values (c.practice_id, c.id, v_name, v_email, v_phone, m.id)
  returning * into d;
  perform private.activity_event(c.org_id, 'director_requested', 'A director''s confirmation was asked for',
    jsonb_build_object('practice_id', c.practice_id, 'confirmation_id', d.id));
  perform private.practice_mail('director_confirm', d.id);
  return jsonb_build_object('id', d.id, 'status', d.status, 'name', d.name, 'email', d.email, 'phone', d.phone, 'created_at', d.created_at);
end $$;

-- The confirmation page opens a link: who asks, for which business, and where it stands. Never raises.
create or replace function public.svc_director_open(p_token text, p_ip text, p_ua text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.practice_director_confirmations; v_state text;
begin
  d := private.director_by_token(p_token);
  v_state := private.director_state(d);
  if v_state in ('invalid', 'expired', 'closed') then return jsonb_build_object('ok', false, 'reason', v_state); end if;
  return jsonb_build_object('ok', true, 'firm_name', (select name from practices where id = d.practice_id),
    'business_name', (select o.name from practice_clients c join orgs o on o.id = c.org_id where c.id = d.client_id),
    'director_name', d.name, 'status', d.status);
end $$;

-- The director asks for a code by email: five a Lagos day. Never raises.
create or replace function public.svc_director_code(p_token text, p_ip text, p_ua text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.practice_director_confirmations; v_state text; r jsonb;
begin
  d := private.director_by_token(p_token);
  v_state := private.director_state(d);
  if v_state is not null then return jsonb_build_object('ok', false, 'reason', v_state); end if;
  if d.locked_at is not null or d.otp_failures >= 15 then return jsonb_build_object('ok', false, 'reason', 'locked'); end if;
  r := private.otp_send_ok(d.sends_day, d.sends_today);
  if not (r->>'ok')::boolean then return jsonb_build_object('ok', false, 'reason', r->>'reason'); end if;
  update practice_director_confirmations set sends_day = (r->>'sends_day')::date, sends_today = (r->>'sends_today')::int where id = d.id;
  perform private.practice_mail('director_code', d.id);
  return jsonb_build_object('ok', true, 'sends_left', 5 - (r->>'sends_today')::int);
end $$;

-- The director enters the code and confirms: five tries per code, locked after fifteen wrong codes, and a wrong code never
-- raises, so the counts stay. Right, from an address none of the firm's people signed in from in the last 30 days, the
-- business's director has confirmed; from one of theirs, or an address that cannot be read, TaxStreem checks it first.
create or replace function public.svc_director_confirm(p_token text, p_code text, p_ip text, p_ua text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.practice_director_confirmations; v_state text; r jsonb; v_ip inet; v_reason text; v_org uuid; v_business text;
begin
  d := private.director_by_token(p_token);
  v_state := private.director_state(d);
  if v_state is not null then return jsonb_build_object('ok', false, 'reason', v_state, 'tries_left', 0); end if;
  r := private.otp_check(d.id, p_code, d.otp_hash, d.otp_expires, d.otp_tries, d.otp_failures, d.locked_at);
  update practice_director_confirmations set otp_tries = (r->>'otp_tries')::int, otp_failures = (r->>'otp_failures')::int,
    locked_at = case when (r->>'locked')::boolean then coalesce(locked_at, now()) else locked_at end,
    otp_hash = case when (r->>'ok')::boolean then null else otp_hash end
  where id = d.id;
  if not (r->>'ok')::boolean then
    return jsonb_build_object('ok', false, 'reason', r->>'reason', 'tries_left', (r->>'tries_left')::int, 'locked', (r->>'locked')::boolean);
  end if;

  begin
    v_ip := private.ip_host(nullif(trim(coalesce(p_ip, '')), '')::inet);
  exception when others then
    v_ip := null;
  end;
  v_reason := case when v_ip is null then 'ip_unreadable'
    when exists (select 1 from auth.sessions s join practice_members pm on pm.user_id = s.user_id
                 where pm.practice_id = d.practice_id and private.ip_host(s.ip) = v_ip
                   and coalesce(s.updated_at, s.created_at) > now() - interval '30 days') then 'firm_ip' end;
  select c.org_id, o.name into v_org, v_business from practice_clients c join orgs o on o.id = c.org_id where c.id = d.client_id;
  if v_reason is not null then
    update practice_director_confirmations set status = 'review', ip = left(nullif(trim(p_ip), ''), 64), ua = left(nullif(p_ua, ''), 300),
      flags = flags || jsonb_build_object('review_reason', v_reason)
    where id = d.id;
    insert into practice_mandate_flags (practice_id, client_id, kind, detail)
    values (d.practice_id, d.client_id, 'director_review', jsonb_build_object('confirmation_id', d.id, 'reason', v_reason));
    perform private.activity_event(v_org, 'director_review', 'A director''s confirmation is waiting for TaxStreem''s check',
      jsonb_build_object('practice_id', d.practice_id, 'confirmation_id', d.id));
    perform private.practice_mail('director_admin', d.id);
    return jsonb_build_object('ok', true, 'status', 'review');
  end if;
  update practice_director_confirmations set status = 'confirmed', confirmed_at = now(), ip = left(nullif(trim(p_ip), ''), 64),
    ua = left(nullif(p_ua, ''), 300)
  where id = d.id;
  update orgs set director_confirmed_at = now() where id = v_org and director_confirmed_at is null;
  perform private.activity_event(v_org, 'director_confirmed', 'A director of the business confirmed the business wallet and tax wallet',
    jsonb_build_object('practice_id', d.practice_id, 'confirmation_id', d.id));
  perform private.practice_notify(d.practice_id, 'A director of ' || v_business || ' confirmed',
    'The business wallet and tax wallet can be opened now.', '/practice/clients');
  return jsonb_build_object('ok', true, 'status', 'confirmed');
end $$;

-- The director declines (p_reason up to 500 characters): the firm is told, and TaxStreem's reviewers. Never raises.
create or replace function public.svc_director_decline(p_token text, p_reason text, p_ip text, p_ua text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.practice_director_confirmations; v_state text; v_reason text := nullif(left(trim(coalesce(p_reason, '')), 500), '');
  v_org uuid; v_business text;
begin
  d := private.director_by_token(p_token);
  v_state := private.director_state(d);
  if v_state is not null then return jsonb_build_object('ok', false, 'reason', v_state); end if;
  update practice_director_confirmations set status = 'declined', decline_reason = v_reason, ip = left(nullif(trim(p_ip), ''), 64),
    ua = left(nullif(p_ua, ''), 300), otp_hash = null, otp_expires = null
  where id = d.id;
  select c.org_id, o.name into v_org, v_business from practice_clients c join orgs o on o.id = c.org_id where c.id = d.client_id;
  insert into practice_mandate_flags (practice_id, client_id, kind, detail)
  values (d.practice_id, d.client_id, 'director_declined', jsonb_build_object('confirmation_id', d.id, 'reason', v_reason));
  perform private.activity_event(v_org, 'director_declined', 'A director of the business declined the business wallet and tax wallet',
    jsonb_build_object('practice_id', d.practice_id, 'confirmation_id', d.id));
  perform private.practice_notify(d.practice_id, 'A director of ' || v_business || ' declined',
    coalesce('They said: ' || v_reason, 'They gave no reason.'), '/practice/clients');
  perform private.practice_mail('director_admin', d.id);
  return jsonb_build_object('ok', true, 'status', 'declined');
end $$;

-- ---------------------------------------------------------------------------
-- 7. The emails
-- ---------------------------------------------------------------------------
-- svc_practice_mail: as before, and three director emails. director_confirm (a confirmation waiting for the director): a
-- fresh link, replacing the last one, for 14 days, in the firm's name. director_code (the same): a fresh code for 10
-- minutes, its tries reset. director_admin (a confirmation in review or declined): to TaxStreem's review recipients, from
-- Counta, with the firm, the business, where it stands and (declined) the reason, and no director's contact details.
create or replace function public.svc_practice_mail(p_kind text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.engagement_letter_signers; l public.engagement_letters; pr public.practices; v_app text; v_client text; v_reply text; t jsonb;
  d public.practice_director_confirmations; v_business text;
begin
  if p_kind in ('director_confirm', 'director_code', 'director_admin') then
    select * into d from practice_director_confirmations where id = p_id for update;
    if d.id is null then return null; end if;
    if p_kind in ('director_confirm', 'director_code')
       and (d.status <> 'pending' or not private.director_mandate_open(d.client_id, d.practice_id)) then
      return null;
    end if;
    if p_kind = 'director_code' and (d.locked_at is not null or d.otp_failures >= 15) then return null; end if;
    if p_kind = 'director_admin' and d.status not in ('review', 'declined') then return null; end if;
    v_app := coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app');
    select * into pr from practices where id = d.practice_id;
    select o.name into v_business from practice_clients c join orgs o on o.id = c.org_id where c.id = d.client_id;
    if p_kind = 'director_admin' then
      return jsonb_build_object('to', to_jsonb(public.svc_review_recipients()), 'reply_to', null, 'from_name', 'Counta',
        'subject', case when d.status = 'review' then 'Director confirmation to review: ' else 'A director declined: ' end || v_business,
        'heading', case when d.status = 'review' then 'A director''s confirmation to check' else 'A director declined' end,
        'greet', null,
        'lines', jsonb_build_array('Firm: ' || pr.name || '.', 'Business: ' || v_business || '.',
            case when d.status = 'review'
              then 'The director confirmed the business wallet and tax wallet from an address the firm''s people use, or one that could not be read. Check it before the wallets open.'
              else 'The director declined the business wallet and tax wallet.' end)
          || case when d.status = 'declined' then jsonb_build_array('Reason given: ' || coalesce(d.decline_reason, 'none') || '.') else '[]'::jsonb end,
        'button', 'Open mandates', 'link', v_app || '/admin/mandates', 'white_label', false);
    end if;
    -- Replies go to the engagement partner while they are in the practice, else the practice.
    v_reply := coalesce((select pm.email from practice_clients c join practice_members pm on pm.id = c.engagement_partner_id
                         where c.id = d.client_id and pm.status = 'active'), pr.email);
    if p_kind = 'director_confirm' then
      t := private.token_new('dc');
      update practice_director_confirmations set token_hash = t->>'hash', token_expires = now() + interval '14 days' where id = d.id;
      return jsonb_build_object('to', d.email, 'reply_to', v_reply, 'from_name', pr.name,
        'subject', pr.name || ' asks you to confirm the wallets for ' || v_business,
        'heading', 'Confirm the business wallets',
        'greet', split_part(trim(d.name), ' ', 1),
        'lines', jsonb_build_array(pr.name || ' asks you, as a director of ' || v_business || ', to confirm that it may open a business wallet and a tax wallet for '
            || v_business || '. The wallets are provided by TaxStreem through Flutterwave and hold the company''s money.',
          'Use the button to confirm or decline. A 6-digit code is emailed to this address first, to confirm it is you. The link works for fourteen days.'),
        'button', 'Confirm or decline', 'link', v_app || '/confirm/' || (t->>'token'), 'white_label', true);
    end if;
    t := private.otp_new(d.id);
    update practice_director_confirmations set otp_hash = t->>'otp_hash', otp_expires = (t->>'otp_expires')::timestamptz, otp_tries = 0 where id = d.id;
    return jsonb_build_object('to', d.email, 'reply_to', v_reply, 'from_name', pr.name,
      'subject', 'Your code to confirm the wallets for ' || v_business,
      'heading', 'Your confirmation code',
      'greet', split_part(trim(d.name), ' ', 1),
      'lines', jsonb_build_array('Enter this code to answer ' || pr.name || '''s request about the wallets for ' || v_business || '. It works for ten minutes.',
        'If you did not ask for a code, you can ignore this email.'),
      'button', null, 'link', null, 'code', t->>'code', 'white_label', true);
  end if;

  -- The letter, then its signer, locked in that order.
  if p_kind in ('letter_sign', 'letter_code') then
    select * into l from engagement_letters where id = (select letter_id from engagement_letter_signers where id = p_id) for update;
    select * into s from engagement_letter_signers where id = p_id and letter_id = l.id for update;
    if s.id is null or l.status is distinct from 'sent' or s.signed_at is not null then return null; end if;
    if p_kind = 'letter_code' and s.locked_at is not null then return null; end if;
  elsif p_kind = 'letter_done' then
    select * into l from engagement_letters where id = p_id for update;
    if l.id is null or l.status <> 'completed' then return null; end if;
    select * into s from engagement_letter_signers where letter_id = l.id and signed_at is not null for update;
    if s.id is null then return null; end if;
  else
    raise exception 'Unknown practice email: %.', p_kind;
  end if;
  v_app := coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app');
  select * into pr from practices where id = l.practice_id;
  select legal_name into v_client from practice_intakes where id = l.intake_id;
  -- Replies go to the partner who signed (at their address now while they are in the practice), else the practice.
  v_reply := coalesce((select email from practice_members where id = l.partner_id and status = 'active'), l.partner_email, pr.email);

  if p_kind = 'letter_sign' then
    t := private.token_new('es');
    update engagement_letter_signers set token_hash = t->>'hash', token_expires = now() + interval '14 days', updated_at = now() where id = s.id;
    return jsonb_build_object('to', s.email, 'reply_to', v_reply, 'from_name', pr.name,
      'subject', 'Letter of engagement from ' || pr.name || ' to sign',
      'heading', 'Your letter of engagement',
      'greet', split_part(trim(s.name), ' ', 1),
      'lines', jsonb_build_array(pr.name || ' has signed its letter of engagement with ' || v_client || ' and sent it to you to read and sign.',
        'Use the button to open it. Before you sign, a 6-digit code is emailed to this address to confirm it is you. The link works for fourteen days.'),
      'button', 'Read and sign', 'link', v_app || '/sign/' || (t->>'token'), 'white_label', l.white_label);
  elsif p_kind = 'letter_code' then
    t := private.otp_new(s.id);
    update engagement_letter_signers set otp_hash = t->>'otp_hash', otp_expires = (t->>'otp_expires')::timestamptz, otp_tries = 0, updated_at = now()
    where id = s.id;
    return jsonb_build_object('to', s.email, 'reply_to', v_reply, 'from_name', pr.name,
      'subject', 'Your code to sign the letter of engagement',
      'heading', 'Your signing code',
      'greet', split_part(trim(s.name), ' ', 1),
      'lines', jsonb_build_array('Enter this code to sign the letter of engagement from ' || pr.name || '. It works for ten minutes.',
        'If you did not ask for a code, you can ignore this email.'),
      'button', null, 'link', null, 'code', t->>'code', 'white_label', l.white_label);
  end if;
  t := private.token_new('es');
  update engagement_letter_signers set token_hash = t->>'hash', token_expires = now() + interval '14 days', updated_at = now() where id = s.id;
  return jsonb_build_object('to', s.email, 'cc', v_reply, 'reply_to', v_reply, 'from_name', pr.name,
    'subject', 'Letter of engagement signed: ' || v_client,
    'heading', 'Your letter of engagement is signed',
    'greet', split_part(trim(s.name), ' ', 1),
    'lines', jsonb_build_array(pr.name || ' and ' || v_client || ' have both signed the letter of engagement.',
      'Use the button to download the signed letter with its certificate of signing. The link works for fourteen days.'),
    'button', 'Download the signed letter', 'link', v_app || '/sign/' || (t->>'token'), 'white_label', l.white_label);
end $$;

-- ---------------------------------------------------------------------------
-- 8. TaxStreem's decisions
-- ---------------------------------------------------------------------------
-- A reviewer or admin decides a confirmation held for review, with a note of 5 characters or more: accepted, the
-- business's director has confirmed; else declined. The review flag is resolved with the note, and the firm is told.
create or replace function public.admin_director_decide(p_id uuid, p_approve boolean, p_note text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_note text := trim(coalesce(p_note, '')); d public.practice_director_confirmations; v_org uuid; v_business text;
begin
  perform private.require_staff(false);
  if length(v_note) < 5 then raise exception 'Write a note of at least 5 characters.'; end if;
  if length(v_note) > 1000 then raise exception 'Keep the note under 1,000 characters.'; end if;
  if p_approve is null then raise exception 'Accept or decline the confirmation.'; end if;
  select * into d from practice_director_confirmations where id = p_id for update;
  if d.id is null then raise exception 'Confirmation not found.'; end if;
  if d.status <> 'review' then raise exception 'Only a confirmation waiting for review is decided here.'; end if;
  select c.org_id, o.name into v_org, v_business from practice_clients c join orgs o on o.id = c.org_id where c.id = d.client_id;
  if p_approve and not private.director_mandate_open(d.client_id, d.practice_id) then
    raise exception 'The firm no longer runs this business under full mandate.';
  end if;
  update practice_director_confirmations set status = case when p_approve then 'confirmed' else 'declined' end,
    confirmed_at = case when p_approve then now() else confirmed_at end, decided_by = auth.uid(), decided_at = now(),
    flags = flags || jsonb_build_object('review_note', v_note)
  where id = d.id
  returning * into d;
  update practice_mandate_flags set resolved_at = now(), resolved_by = auth.uid(), resolution_note = v_note
  where kind = 'director_review' and detail->>'confirmation_id' = d.id::text and resolved_at is null;
  if p_approve then
    update orgs set director_confirmed_at = now() where id = v_org and director_confirmed_at is null;
    perform private.activity_event(v_org, 'director_confirmed', 'TaxStreem accepted a director''s confirmation of the business wallet and tax wallet',
      jsonb_build_object('practice_id', d.practice_id, 'confirmation_id', d.id));
    perform private.audit('director_confirmed', d.id::text, jsonb_build_object('practice_id', d.practice_id, 'client_id', d.client_id, 'org_id', v_org, 'note', v_note));
    perform private.practice_notify(d.practice_id, 'A director of ' || v_business || ' confirmed',
      'TaxStreem checked the confirmation. The business wallet and tax wallet can be opened now.', '/practice/clients');
  else
    perform private.activity_event(v_org, 'director_declined', 'TaxStreem did not accept a director''s confirmation',
      jsonb_build_object('practice_id', d.practice_id, 'confirmation_id', d.id));
    perform private.audit('director_declined', d.id::text, jsonb_build_object('practice_id', d.practice_id, 'client_id', d.client_id, 'org_id', v_org, 'note', v_note));
    perform private.practice_notify(d.practice_id, 'TaxStreem did not accept the director''s confirmation for ' || v_business,
      'Ask the director to confirm again from their own device and connection.', '/practice/clients');
  end if;
  return jsonb_build_object('id', d.id, 'status', d.status);
end $$;

-- An admin pauses or resumes a practice's full mandates (the kill switch), with a reason of 5 characters or more: while
-- paused, the businesses it runs have their payments shut and it takes on none.
create or replace function public.admin_practice_suspend(p_practice uuid, p_on boolean, p_note text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_note text := trim(coalesce(p_note, '')); v_at timestamptz;
begin
  perform private.require_staff(true);
  if length(v_note) < 5 then raise exception 'Give a reason of at least 5 characters.'; end if;
  if length(v_note) > 1000 then raise exception 'Keep the reason under 1,000 characters.'; end if;
  if p_on is null then raise exception 'Pause or resume.'; end if;
  update practices set mandate_suspended_at = case when p_on then coalesce(mandate_suspended_at, now()) end where id = p_practice
  returning mandate_suspended_at into v_at;
  if not found then raise exception 'Practice not found.'; end if;
  perform private.audit(case when p_on then 'mandates_suspended' else 'mandates_resumed' end, p_practice::text, jsonb_build_object('note', v_note));
  if p_on then
    perform private.practice_notify(p_practice, 'TaxStreem has paused your full mandates',
      'The payments of the businesses you run under full mandate are shut, and you take on no new ones, until TaxStreem resumes them. Reason: ' || v_note,
      '/practice/clients');
  else
    perform private.practice_notify(p_practice, 'TaxStreem has resumed your full mandates', 'The businesses you run under full mandate work as before.',
      '/practice/clients');
  end if;
  return jsonb_build_object('id', p_practice, 'mandate_suspended_at', v_at);
end $$;

-- ---------------------------------------------------------------------------
-- 9. Carried: referrals, business profiles, plan places
-- ---------------------------------------------------------------------------
-- partner_referral_start: a business the practice runs under full mandate starts no referral (the practice pays for its
-- plan itself); otherwise as before.
create or replace function private.partner_referral_start(c public.practice_clients) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_self boolean; v_source text;
begin
  if c.org_id is null or c.practice_id is null or c.status <> 'active' then return; end if;
  if c.mode = 'full' then return; end if;
  if not (private.partner_settings()->>'enabled')::boolean then return; end if;
  if (select is_sample from orgs where id = c.org_id) then return; end if;
  if exists (select 1 from partner_referrals where org_id = c.org_id and status <> 'void') then return; end if;
  if exists (select 1 from subscription_charges where org_id = c.org_id and status = 'successful') then return; end if;
  v_self := exists (select 1 from members m join practice_members pm on pm.user_id = m.user_id
    where m.org_id = c.org_id and m.role = 'owner' and m.user_id is not null and pm.practice_id = c.practice_id and pm.status = 'active');
  v_source := case when c.via is not null then c.via when c.initiated_by = 'practice' then 'invite' else 'request' end;
  insert into partner_referrals (practice_id, org_id, client_id, source, status, void_reason)
  values (c.practice_id, c.org_id, c.id, v_source, case when v_self then 'void' else 'waiting' end, case when v_self then 'self' end);
end $$;

-- Business profiles. A person keeps one draft of their own (for a business they set up or own, as before); each business a
-- practice runs has its own draft as well (for_business), whoever of the firm started it, so a firm person completes
-- several such profiles, one after another or side by side. Profiles already bound to such a business become its own (the
-- newest draft, and every submitted one).
alter table public.kyc_profiles add column if not exists for_business boolean not null default false;
update public.kyc_profiles set for_business = true
where id in (select distinct on (k.org_id) k.id from public.kyc_profiles k join public.orgs o on o.id = k.org_id
             where k.status = 'draft' and o.managed_by is not null order by k.org_id, k.updated_at desc, k.id)
   or (status = 'submitted' and org_id in (select id from public.orgs where managed_by is not null));
drop index if exists public.kyc_profiles_one_draft;
create unique index kyc_profiles_one_draft on public.kyc_profiles(user_id) where status = 'draft' and not for_business;
create unique index kyc_profiles_business_draft on public.kyc_profiles(org_id) where status = 'draft' and for_business;

-- kyc_row: for a business a practice runs with no profile yet, that business's own draft (made when there is none); the
-- person's own draft is never one of those. Otherwise as before.
create or replace function private.kyc_row(p_user uuid, p_org uuid default null) returns public.kyc_profiles
language plpgsql security definer set search_path = public, private as $$
declare k public.kyc_profiles;
begin
  if p_org is not null then
    select * into k from kyc_profiles where org_id = p_org order by (status = 'submitted') desc, updated_at desc limit 1;
    if found then return k; end if;
    if private.is_managed(p_org) then
      insert into kyc_profiles (user_id, org_id, for_business) values (p_user, p_org, true) on conflict do nothing returning * into k;
      if k.id is null then select * into k from kyc_profiles where org_id = p_org and status = 'draft' and for_business; end if;
      return k;
    end if;
  end if;
  select * into k from kyc_profiles where user_id = p_user and status = 'draft' and not for_business;
  if not found then
    insert into kyc_profiles (user_id, org_id) values (p_user, p_org) on conflict do nothing returning * into k;
    if k.id is null then select * into k from kyc_profiles where user_id = p_user and status = 'draft' and not for_business; end if;
  elsif p_org is not null and (k.org_id is not null and k.org_id <> p_org
      or k.org_id is null and (k.search <> '{}'::jsonb or k.cac is not null or k.manual is not null or k.tin is not null or k.web is not null
                               or k.doc is not null or k.answers <> '{}'::jsonb)) then
    raise exception 'You have another business profile in progress. Finish it first, then come back to this business.';
  elsif p_org is not null and k.org_id is null then
    update kyc_profiles set org_id = p_org where id = k.id returning * into k;
  end if;
  return k;
end $$;

-- kyc_draft: without a business, the person's own draft or submitted profile (never a business's own); otherwise as before.
create or replace function public.kyc_draft(p_org uuid default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid(); k public.kyc_profiles;
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if p_org is not null and not private.is_owner(p_org) then raise exception 'Only the owner sees the business profile.' using errcode = '42501'; end if;
  if p_org is not null then
    k := private.kyc_row(v_uid, p_org);
  else
    select * into k from kyc_profiles where user_id = v_uid and status = 'draft' and not for_business;
    if not found then
      select * into k from kyc_profiles where user_id = v_uid and status = 'submitted' and not for_business and org_id is not null
        and private.is_owner(org_id)
      order by submitted_at desc limit 1;
    end if;
    if not found then
      k.status := 'draft'; k.answers := '{}'::jsonb; k.updated_at := now();
    end if;
  end if;
  return private.kyc_json(k);
end $$;

-- kyc_manual: with p.org_id, the profile of that business, which the caller acts as the owner of; otherwise as before.
create or replace function public.kyc_manual(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid(); k public.kyc_profiles; v_name text := left(trim(coalesce(p->>'name', '')), 120);
  v_for uuid := private.uuid_of(nullif(p->>'org_id', ''));
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if nullif(p->>'org_id', '') is not null and (v_for is null or not private.is_owner(v_for)) then
    raise exception 'Only the owner changes the business profile.' using errcode = '42501';
  end if;
  if v_name = '' then raise exception 'Tell us the business name.'; end if;
  if coalesce(p->>'kind', 'unregistered') not in ('unregistered', 'pending', 'other') then raise exception 'Choose how the business is registered.'; end if;
  k := private.kyc_row(v_uid, v_for);
  if v_for is not null and k.org_id is distinct from v_for then
    raise exception 'You have another business profile in progress. Finish it first, then come back to this business.';
  end if;
  if k.status = 'submitted' then raise exception 'This profile is already submitted.'; end if;
  update kyc_profiles set source = 'manual', cac = null, tin = null,
    manual = jsonb_build_object('name', v_name, 'kind', coalesce(p->>'kind', 'unregistered'), 'address', left(nullif(trim(p->>'address'), ''), 300),
      'state', private.ng_state(p->>'state'), 'rc_number', left(nullif(trim(p->>'rc_number'), ''), 20)),
    updated_at = now()
  where id = k.id returning * into k;
  return private.kyc_json(k);
end $$;

-- kyc_answer: with p.org_id, the profile of that business, which the caller acts as the owner of; otherwise as before.
create or replace function public.kyc_answer(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid(); k public.kyc_profiles; a jsonb; x text; v jsonb; v_for uuid;
  ok_receive text[] := array['cash', 'bank_transfer', 'pos', 'payment_links', 'ussd', 'mobile_money', 'cheque', 'crypto', 'other'];
  ok_pay text[] := array['cash', 'bank_transfer', 'card', 'pos', 'mobile_money', 'cheque', 'other'];
  ok_reasons text[] := array['track_sales', 'manage_stock', 'get_paid', 'bookkeeping', 'tax_compliance', 'financial_statements', 'loans', 'pay_suppliers', 'team', 'other'];
  ok_filing text[] := array['always', 'sometimes', 'never', 'not_sure', 'not_applicable'];
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if jsonb_typeof(p) <> 'object' then raise exception 'Send the answers as an object.'; end if;
  if p ? 'org_id' then
    v_for := private.uuid_of(nullif(p->>'org_id', ''));
    if nullif(p->>'org_id', '') is not null and (v_for is null or not private.is_owner(v_for)) then
      raise exception 'Only the owner answers for the business profile.' using errcode = '42501';
    end if;
    p := p - 'org_id';
  end if;
  k := private.kyc_row(v_uid, v_for);
  if v_for is not null and k.org_id is distinct from v_for then
    raise exception 'You have another business profile in progress. Finish it first, then come back to this business.';
  end if;
  if k.status = 'submitted' then raise exception 'This profile is already submitted.'; end if;
  a := k.answers;
  for x in select jsonb_object_keys(p) loop
    v := p->x;
    case x
      when 'offering' then
        if v #>> '{}' not in ('goods', 'services', 'both') then raise exception 'Goods, services or both?'; end if;
        a := a || jsonb_build_object(x, v #>> '{}');
      when 'category' then
        if not exists (select 1 from business_categories where id = v #>> '{}') then raise exception 'Choose a category from the list.'; end if;
        a := a || jsonb_build_object(x, v #>> '{}');
      when 'revenue_band' then
        if v #>> '{}' not in ('0_50m', '50_100m', 'over_100m') then raise exception 'Choose a revenue band.'; end if;
        a := a || jsonb_build_object(x, v #>> '{}');
      when 'receive_methods', 'pay_methods', 'reasons' then
        if jsonb_typeof(v) <> 'array' or exists (select 1 from jsonb_array_elements_text(v) e
             where not e = any (case x when 'receive_methods' then ok_receive when 'pay_methods' then ok_pay else ok_reasons end)) then
          raise exception 'Choose from the options for %.', replace(x, '_', ' ');
        end if;
        a := a || jsonb_build_object(x, (select coalesce(jsonb_agg(distinct e), '[]'::jsonb) from jsonb_array_elements_text(v) e));
      when 'reason_note' then
        a := a || jsonb_build_object(x, left(trim(coalesce(v #>> '{}', '')), 500));
      when 'examples' then
        if jsonb_typeof(v) <> 'array' then raise exception 'List some products or services.'; end if;
        a := a || jsonb_build_object(x, (select coalesce(jsonb_agg(left(trim(e), 80)), '[]'::jsonb)
          from (select e from jsonb_array_elements_text(v) e where trim(e) <> '' limit 20) t));
      when 'filing' then
        if jsonb_typeof(v) <> 'object' or exists (select 1 from jsonb_each_text(v) f where f.key not in ('vat', 'wht', 'cit') or not f.value = any (ok_filing)) then
          raise exception 'For each of VAT, WHT and CIT: always, sometimes, never, not sure or not applicable.';
        end if;
        a := a || jsonb_build_object('filing', coalesce(a->'filing', '{}'::jsonb) || v);
      when 'charges_vat' then
        if jsonb_typeof(v) <> 'boolean' then raise exception 'Does the business charge VAT: yes or no?'; end if;
        a := a || jsonb_build_object(x, v);
      else raise exception 'Unknown question %.', x;
    end case;
  end loop;
  update kyc_profiles set answers = a, updated_at = now() where id = k.id returning * into k;
  return private.kyc_json(k);
end $$;

-- kyc_submit: with p.org_id, the answers given with it go to that business's profile too. The company's numbers (its RC
-- number and Tax ID) are this transaction's while it runs (private.company_lock). For a business a practice runs, the
-- record must be the company the firm took on (the RC number on its intake, when both have one) and not a company that is
-- someone else's on Counta (private.company_taken): then nothing is submitted, TaxStreem is flagged (once while the flag is
-- open) and the answer is {ok: false, reason: duplicate}. Otherwise as before.
create or replace function public.kyc_submit(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid(); k public.kyc_profiles; c jsonb; v_org uuid; v_name text; v_addr text; v_vat boolean; v_cat public.business_categories;
  v_form text; v_cls text; v_tin text; v_dir jsonb; v_display text; v_branch text; v_email text; v_state text; v_lga text; v_shares numeric;
  v_new boolean := false; v_for uuid := nullif(p->>'org_id', '')::uuid; v_to jsonb; v_rc text; mc public.practice_clients; v_intake_rc text;
  v_dup jsonb; v_practice uuid;
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if v_for is not null and not private.is_owner(v_for) then
    raise exception 'Only the owner submits the business profile.' using errcode = '42501';
  end if;
  v_to := case when v_for is not null then jsonb_build_object('org_id', v_for) else '{}'::jsonb end;
  if p ? 'answers' then
    perform public.kyc_answer(case when jsonb_typeof(p->'answers') = 'object' then (p->'answers') || v_to else p->'answers' end);
  end if;
  if p ? 'charges_vat' then perform public.kyc_answer(jsonb_build_object('charges_vat', p->'charges_vat') || v_to); end if;
  k := private.kyc_row(v_uid, v_for);
  if v_for is not null and k.org_id is distinct from v_for then
    raise exception 'You have another business profile in progress. Finish it first, then come back to this business.';
  end if;
  if k.status = 'submitted' then raise exception 'This profile is already submitted.'; end if;
  if k.source is null then raise exception 'Find the business on CAC first, or tell us it is not registered.'; end if;
  if array_length(private.kyc_missing(k.answers), 1) > 0 then
    raise exception 'A few questions are still open: %.', array_to_string(private.kyc_missing(k.answers), ', ');
  end if;
  c := k.cac->'profile';
  select * into v_cat from business_categories where id = k.answers->>'category';
  v_cls := upper(coalesce(c->>'classification', ''));
  v_form := case when v_cls like 'COMPANY%' then 'company' when v_cls = 'BUSINESS_NAME' then 'enterprise' when v_cls = 'IT' then 'ngo'
                 when v_cls = 'LP' then 'partnership' when k.source = 'manual' then 'individual' else null end;
  v_name := coalesce(nullif(left(trim(p->>'trading_name'), 120), ''), initcap(lower(c->>'approved_name')), k.manual->>'name');
  v_addr := coalesce(nullif(left(trim(p->>'address'), 300), ''), nullif(trim(c->>'business_address'), ''), nullif(trim(c->>'address'), ''), k.manual->>'address');
  v_vat := coalesce((k.answers->>'charges_vat')::boolean, k.answers->>'revenue_band' = 'over_100m' or k.answers->'filing'->>'vat' in ('always', 'sometimes'));
  v_tin := coalesce(nullif(regexp_replace(coalesce(k.tin->>'nrs_tin', ''), '\D', '', 'g'), ''), nullif(regexp_replace(coalesce(c->>'tax_id', ''), '\D', '', 'g'), ''));
  if v_tin !~ '^[0-9]{13}$' then v_tin := null; end if;
  v_dir := (select jsonb_agg(jsonb_build_object('name', private.person(d), 'appointed', left(d->>'date_of_appointment', 10)))
            from jsonb_array_elements(coalesce(c->'directors', '[]'::jsonb)) d where private.person(d) is not null);
  v_shares := (select sum(case when s->>'num_shares_alloted' ~ '^[0-9]+$' then (s->>'num_shares_alloted')::numeric else 0 end)
               from jsonb_array_elements(coalesce(c->'shareholders', '[]'::jsonb)) s);
  select coalesce(nullif(trim(raw_user_meta_data->>'full_name'), ''), split_part(email, '@', 1)), email into v_display, v_email from auth.users where id = v_uid;
  v_branch := coalesce(nullif(left(trim(p->>'branch_name'), 60), ''), 'Head office');

  -- The company: its turn on its numbers, and for a business a practice runs, the one the firm took on and nobody else's.
  v_rc := coalesce(nullif(c->>'rc_number', ''), nullif(k.manual->>'rc_number', ''));
  perform private.company_lock(v_rc, v_tin);
  if k.org_id is not null and private.is_managed(k.org_id) then
    select managed_by into v_practice from orgs where id = k.org_id;
    mc := private.mandate(k.org_id);
    select x.rc_number into v_intake_rc from practice_intakes x where x.id = mc.intake_id;
    if private.norm_id(v_rc) is not null and private.norm_id(v_intake_rc) is not null and private.norm_id(v_rc) <> private.norm_id(v_intake_rc) then
      raise exception 'This CAC record is for RC %, but the firm took this business on as RC %. Choose the right company.',
        private.norm_id(v_rc), private.norm_id(v_intake_rc);
    end if;
    v_dup := private.company_taken(v_rc, v_tin, v_practice, k.org_id);
    if v_dup is not null then
      insert into practice_mandate_flags (practice_id, intake_id, client_id, kind, detail)
      select v_practice, mc.intake_id, mc.id, 'duplicate_company', v_dup || jsonb_build_object('source', 'cac', 'business_org_id', k.org_id)
      where not exists (select 1 from practice_mandate_flags f where f.practice_id = v_practice and f.kind = 'duplicate_company' and f.resolved_at is null
                        and f.detail->>'business_org_id' = k.org_id::text);
      return jsonb_build_object('ok', false, 'reason', 'duplicate');
    end if;
  end if;

  v_org := k.org_id;
  if v_org is null then
    v_org := public.create_org(v_name, coalesce(nullif(trim(p->>'email'), ''), v_email), nullif(trim(p->>'phone'), ''), v_display,
      jsonb_build_array(jsonb_build_object('name', v_branch, 'address', v_addr)), v_vat, false);
    v_new := true;
  elsif not private.is_owner(v_org) then
    raise exception 'Only the owner submits the business profile.' using errcode = '42501';
  else
    update orgs set name = v_name, vat_registered = v_vat, phone = coalesce(nullif(trim(p->>'phone'), ''), phone) where id = v_org;
  end if;
  update orgs set
    rc_number = coalesce(nullif(c->>'rc_number', ''), nullif(k.manual->>'rc_number', ''), rc_number),
    tin = coalesce(v_tin, tin),
    legal_form = coalesce(v_form, legal_form),
    address = coalesce(v_addr, address),
    registered_office = coalesce(nullif(trim(c->>'address'), ''), nullif(trim(c->>'head_office_address'), ''), registered_office),
    incorporation_date = coalesce(nullif(left(c->>'registration_date', 10), '')::date, incorporation_date),
    commenced_on = coalesce(nullif(left(c->>'business_commencement_date', 10), '')::date, commenced_on),
    principal_activity = coalesce(nullif(left(trim(c->>'objectives'), 500), ''), v_cat.label, principal_activity),
    directors = coalesce(v_dir, directors),
    industry = coalesce(v_cat.industry, industry),
    offering = coalesce(nullif(k.answers->>'offering', ''), v_cat.kind, offering),
    category_id = coalesce(v_cat.id, category_id),
    identity_status = case when v_new then 'pending' else identity_status end,
    website = coalesce(website, nullif(left(k.web->>'website', 200), '')),
    -- The shares CAC has on record, when the statements have none yet.
    share_info = case when share_info = '{}'::jsonb and v_shares > 0 then jsonb_build_object('issued_shares', v_shares) else share_info end,
    company_secretary = coalesce(nullif(company_secretary, ''), (select coalesce(private.person(s), nullif(trim(s->>'corporation_name'), ''))
      from jsonb_array_elements(coalesce(k.cac->'secretary', '[]'::jsonb)) s limit 1))
  where id = v_org;
  -- The head office's state (and local government area, when CAC names one the NRS list knows) from the CAC record or the address.
  v_state := coalesce(private.ng_state(nullif(c->>'state', '')), private.ng_state(k.manual->>'state'), private.ng_state_of_address(v_addr));
  if v_state is not null then
    v_lga := private.ng_lga(v_state, nullif(trim(regexp_replace(coalesce(nullif(c->>'lga', ''), c->>'city', ''), '\s*L\.?G\.?A\.?$', '', 'i')), ''));
    update locations set state = v_state, lga = coalesce(v_lga, lga) where org_id = v_org and is_main and state is null;
  end if;
  update kyc_profiles set status = 'submitted', submitted_at = now(), org_id = v_org, updated_at = now() where id = k.id;
  insert into guide_progress (user_id, org_id) values (v_uid, v_org) on conflict (user_id) do update set org_id = excluded.org_id, last_seen_at = now();
  return jsonb_build_object('org_id', v_org, 'name', v_name, 'compliance', public.compliance_score(v_org));
end $$;

-- Plan places for people: the managing practice's places in a business it runs are the practice's (it pays for the plan),
-- so they are not counted (meter_usage) and not checked (enforce_plan); otherwise as before.
create or replace function private.meter_usage(p_org uuid, p_meter text) returns numeric
language plpgsql stable security definer set search_path = public, private as $$
declare v_from timestamptz := private.month_start(); v numeric;
begin
  case p_meter
    when 'sales' then
      select count(*) into v from sales where org_id = p_org and created_at >= v_from and doc_type in ('receipt', 'invoice') and status not in ('draft', 'void', 'cancelled')
        and channel <> 'api';
    when 'ai_reads' then
      select count(*) into v from usage_events where org_id = p_org and service = 'gemini' and kind = any(private.ai_read_kinds()) and at >= v_from;
    when 'assistant' then
      select count(*) into v from usage_events where org_id = p_org and service = 'gemini' and kind = any(private.ai_assistant_kinds()) and at >= v_from;
    when 'call_minutes' then
      select coalesce(sum(ceil(coalesce(duration_secs, 0) / 60.0)), 0) into v from voice_calls where org_id = p_org and created_at >= v_from;
    when 'whatsapp' then
      select count(*) into v from messages where org_id = p_org and channel = 'whatsapp' and template <> 'alert' and status not in ('failed', 'suppressed')
        and created_at >= v_from;
    when 'emails' then
      select count(*) into v from messages where org_id = p_org and channel = 'email' and template <> 'alert' and status not in ('failed', 'suppressed')
        and created_at >= v_from;
    when 'tin_checks' then
      select count(*) into v from tin_checks where org_id = p_org and at >= v_from;
    when 'supplier_invoices' then
      select count(*) into v from supplier_invoices where org_id = p_org and created_at >= v_from;
    when 'payouts' then
      select count(*) into v from payouts where org_id = p_org and created_at >= v_from and status <> 'cancelled';
    when 'users' then
      select count(*) into v from members m where m.org_id = p_org and m.status in ('active', 'invited')
        and not exists (select 1 from orgs o where o.id = p_org and o.managed_by is not null and o.managed_by = m.practice_id);
    when 'locations' then
      select count(*) into v from locations where org_id = p_org;
    when 'bank_feeds' then
      select count(*) into v from bank_accounts where org_id = p_org and provider = 'mono' and active;
    else v := 0;
  end case;
  return coalesce(v, 0);
end $$;

create or replace function private.enforce_plan() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if tg_table_name = 'sales' then
    -- Partners' invoices through Prism are charged by Prism in credits.
    if new.doc_type in ('receipt', 'invoice') and new.status not in ('draft', 'void', 'cancelled') and new.channel is distinct from 'api' then
      perform private.check_quota(new.org_id, 'sales');
    end if;
  elsif tg_table_name = 'members' then
    -- The managing practice's places in a business it runs use none of the plan's places.
    if new.practice_id is not null and exists (select 1 from orgs where id = new.org_id and managed_by = new.practice_id) then return new; end if;
    if new.role <> 'owner' and new.status in ('active', 'invited') then perform private.check_quota(new.org_id, 'users'); end if;
  elsif tg_table_name = 'locations' then
    perform private.check_quota(new.org_id, 'locations');
  elsif tg_table_name = 'payouts' then
    if new.batch_id is not null and not private.feature_on(new.org_id, 'bulk_payments') then
      raise exception 'Bulk payments are not in your plan. The owner can change the plan in Settings, Subscription.';
    end if;
    perform private.check_quota(new.org_id, 'payouts');
  elsif tg_table_name = 'supplier_invoices' then
    if new.source = 'portal' and not private.feature_on(new.org_id, 'supplier_portal') then
      raise exception 'This business is not taking invoices on its portal right now.';
    end if;
    perform private.check_quota(new.org_id, 'supplier_invoices');
  elsif tg_table_name = 'tin_checks' then
    perform private.check_quota(new.org_id, 'tin_checks');
  elsif tg_table_name = 'bank_accounts' then
    if new.provider = 'mono' and (tg_op = 'INSERT' or old.provider is distinct from 'mono') then
      if not private.feature_on(new.org_id, 'bank_feeds') then
        raise exception 'Bank feeds are not in your plan. The owner can change the plan in Settings, Subscription.';
      end if;
      perform private.check_quota(new.org_id, 'bank_feeds');
    end if;
  elsif tg_table_name = 'voice_calls' then
    perform private.check_quota(new.org_id, 'call_minutes');
  elsif tg_table_name = 'messages' then
    -- A message over a blocking limit is kept, marked failed with the reason, so whatever queued it carries on. Counta's
    -- own alerts to the team are not counted.
    if new.template is distinct from 'alert' then
      begin
        perform private.check_quota(new.org_id, case when new.channel = 'whatsapp' then 'whatsapp' else 'emails' end);
      exception when sqlstate 'P0001' then
        new.status := 'failed'; new.error := left(sqlerrm, 300);
      end;
    end if;
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- 10. Grants
-- ---------------------------------------------------------------------------
-- core.sql grants every private function to authenticated: the helpers this migration creates or redefines are not
-- callable by the signed-in person.
revoke all on function private.free_mail_domains(), private.firm_email(uuid, text), private.mandate_gate(uuid),
  private.mandate_letter(public.practice_intakes), private.company_lock(text, text), private.company_taken(text, text, uuid, uuid),
  private.ip_host(inet), private.identity_json(uuid, boolean),
  private.director_mandate_open(uuid, uuid), private.director_by_token(text), private.director_state(public.practice_director_confirmations),
  private.payments_open(uuid), private.require_payments_open(uuid), private.partner_referral_start(public.practice_clients),
  private.kyc_row(uuid, uuid), private.meter_usage(uuid, text), private.enforce_plan()
  from public, anon, authenticated;
revoke execute on function public.practice_mandate_gate(uuid), public.practice_create_business(uuid, jsonb), public.practice_director_request(uuid, jsonb),
  public.admin_director_decide(uuid, boolean, text), public.admin_practice_suspend(uuid, boolean, text)
  from public, anon;
grant execute on function public.practice_mandate_gate(uuid), public.practice_create_business(uuid, jsonb), public.practice_director_request(uuid, jsonb),
  public.admin_director_decide(uuid, boolean, text), public.admin_practice_suspend(uuid, boolean, text)
  to authenticated;
revoke all on function public.svc_director_open(text, text, text), public.svc_director_code(text, text, text),
  public.svc_director_confirm(text, text, text, text), public.svc_director_decline(text, text, text, text), public.svc_practice_mail(text, uuid)
  from public, anon, authenticated;
grant execute on function public.svc_director_open(text, text, text), public.svc_director_code(text, text, text),
  public.svc_director_confirm(text, text, text, text), public.svc_director_decline(text, text, text, text), public.svc_practice_mail(text, uuid)
  to service_role;
