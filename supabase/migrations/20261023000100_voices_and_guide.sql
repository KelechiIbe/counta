-- Counta · Nigerian voices and the voice onboarding guide
--
-- 1. The voices a business can choose from: Nigerian voices from the ElevenLabs Voice Library, added to TaxStreem's
--    ElevenLabs account by the voice function and listed here. Signed-in users read the active ones; only the
--    service role writes.
-- 2. Each business's voice settings: which voice speaks, English or Pidgin, and which events are announced.
-- 3. A daily allowance of spoken phrases per business (and per person before they have a business), so a mistake
--    or misuse cannot run up the ElevenLabs bill.
-- 4. The business profile: the CAC and TIN records Mono returns (directors' birth dates, ID numbers, phones, emails and
--    home addresses are never kept), what a web search finds, the person's answers, the compliance score out of ten
--    (rules TaxStreem can reword), and the CAC document on file in "<business>/kyc/", which only the owner can open.
--    Submitting sets the business up from CAC: name, RC number, Tax ID, legal form, addresses, dates, directors,
--    secretary, issued shares and the head office's state.
-- 5. The onboarding guide: what a new customer has done (worked out from their real data), their consent to a
--    follow-up call, and how many guide conversations they have started.
-- 6. Follow-up calls to people who stopped halfway and said they want one, placed between 9:00 and 18:30 Lagos time.
--
-- Safe to run more than once.

-- ---------------------------------------------------------------------------
-- 1. Voices
-- ---------------------------------------------------------------------------
create table if not exists public.tts_voices (
  voice_id text primary key,
  name text not null,
  gender text,
  age text,
  accent text,
  description text,
  preview_url text,
  source text not null default 'library' check (source in ('library', 'pinned')),
  owner_id text,
  sort int not null default 100,
  active boolean not null default true,
  added_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.tts_voices enable row level security;
drop policy if exists tts_voices_read on public.tts_voices;
create policy tts_voices_read on public.tts_voices for select to authenticated using (active);
revoke all on public.tts_voices from anon, authenticated;
grant select on public.tts_voices to authenticated;

-- Workspace tools for the ElevenLabs agents (the guide's client tools), kept like voice_agents.
create table if not exists public.voice_tools (
  name text primary key,
  tool_id text not null,
  version int not null,
  updated_at timestamptz not null default now()
);
alter table public.voice_tools enable row level security;
revoke all on public.voice_tools from anon, authenticated;
revoke all on public.voice_agents from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. A business's voice settings
-- ---------------------------------------------------------------------------
alter table public.orgs add column if not exists voice_id text;
alter table public.orgs add column if not exists voice_lang text not null default 'en';
alter table public.orgs add column if not exists voice_events jsonb not null default '{"payment_received": true, "sale_recorded": true}'::jsonb;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'orgs_voice_lang_check') then
    alter table public.orgs add constraint orgs_voice_lang_check check (voice_lang in ('en', 'pcm'));
  end if;
end $$;

-- What the app needs to speak for a business, and the voices to choose from.
create or replace function public.voice_settings(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs;
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  return jsonb_build_object(
    'voice_id', o.voice_id, 'voice_lang', o.voice_lang, 'events', o.voice_events,
    'can_edit', m.role in ('owner', 'manager'),
    'voices', coalesce((select jsonb_agg(jsonb_build_object('voice_id', v.voice_id, 'name', v.name, 'gender', v.gender, 'age', v.age,
        'accent', v.accent, 'description', v.description) order by v.sort, v.name)
      from tts_voices v where v.active), '[]'::jsonb));
end $$;

create or replace function public.save_voice_settings(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_voice text; v_lang text; v_events jsonb; k text;
begin
  m := private.require(p_org, null);
  if m.role not in ('owner', 'manager') then
    raise exception 'Only the owner or a manager chooses the voice.' using errcode = '42501';
  end if;
  if p ? 'voice_id' then
    v_voice := nullif(trim(p->>'voice_id'), '');
    if v_voice is not null and not exists (select 1 from tts_voices where voice_id = v_voice and active) then
      raise exception 'Choose one of the voices on the list.';
    end if;
  end if;
  if p ? 'voice_lang' then
    v_lang := p->>'voice_lang';
    if v_lang not in ('en', 'pcm') then raise exception 'Choose English or Pidgin.'; end if;
  end if;
  if p ? 'events' then
    if jsonb_typeof(p->'events') <> 'object' then raise exception 'Choose which events are spoken.'; end if;
    select voice_events into v_events from orgs where id = p_org;
    for k in select jsonb_object_keys(p->'events') loop
      if k not in ('payment_received', 'sale_recorded') then raise exception 'Unknown event %.', k; end if;
      if jsonb_typeof(p->'events'->k) <> 'boolean' then raise exception 'Say yes or no for %.', k; end if;
      v_events := v_events || jsonb_build_object(k, (p->'events'->>k)::boolean);
    end loop;
  end if;
  update orgs set
    voice_id = case when p ? 'voice_id' then v_voice else voice_id end,
    voice_lang = coalesce(v_lang, voice_lang),
    voice_events = coalesce(v_events, voice_events)
  where id = p_org;
  return public.voice_settings(p_org);
end $$;

-- The facts behind a spoken line, checked against the caller's business (the voice function builds the words).
--   payment_received {request_id}             a paid transfer, link or QR payment of this business
--   sale_recorded    {item_id, qty, amount}   a sale recorded by voice (quantity in selling units)
--   payment_demo     {}                       the onboarding moment: a pretend payment, said in the business's voice
create or replace function public.voice_say(p_org uuid, p_kind text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs; r public.payment_requests; i public.items; v_qty numeric; v_amount numeric; v_vars jsonb;
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  case p_kind
    when 'payment_received' then
      select * into r from payment_requests where id = nullif(p->>'request_id', '')::uuid and org_id = p_org;
      if r.id is null then raise exception 'Payment not found.'; end if;
      if r.status <> 'paid' then raise exception 'That payment has not arrived yet.'; end if;
      v_vars := jsonb_build_object('amount', coalesce(r.paid_amount, r.amount),
        'payer', left(coalesce(nullif(trim(r.payer->>'name'), ''), ''), 60));
    when 'sale_recorded' then
      select * into i from items where id = nullif(p->>'item_id', '')::uuid and org_id = p_org;
      if i.id is null then raise exception 'Item not found.'; end if;
      begin
        v_qty := (p->>'qty')::numeric; v_amount := coalesce((p->>'amount')::numeric, 0);
      exception when others then raise exception 'Quantity and amount must be numbers.';
      end;
      if v_qty is null or v_qty <= 0 or v_qty > 1000000 or v_amount < 0 or v_amount > 10000000000 then
        raise exception 'Quantity and amount are out of range.';
      end if;
      v_vars := jsonb_build_object('item', left(i.name, 80), 'unit', i.selling_unit, 'qty', v_qty, 'amount', v_amount);
    when 'payment_demo' then
      v_vars := jsonb_build_object('amount', 15000, 'payer', 'Chidi Okafor');
    else raise exception 'Unknown announcement.';
  end case;
  return jsonb_build_object('kind', p_kind, 'business', o.name, 'voice_id', o.voice_id, 'lang', o.voice_lang,
    'enabled', p_kind = 'payment_demo' or coalesce((o.voice_events->>p_kind)::boolean, true), 'vars', v_vars);
end $$;

-- ---------------------------------------------------------------------------
-- 3. Daily allowance of spoken phrases
-- ---------------------------------------------------------------------------
create table if not exists public.tts_usage (
  subject text not null,
  day date not null,
  phrases int not null default 0,
  chars int not null default 0,
  primary key (subject, day)
);
alter table public.tts_usage enable row level security;
revoke all on public.tts_usage from anon, authenticated;

-- 'org:<id>' may say 600 phrases a day with 60,000 newly generated characters; 'user:<id>' (no business yet) 60 and 6,000.
-- A phrase already in the cache costs nothing at ElevenLabs, so it counts as a phrase but not as characters.
create or replace function public.svc_tts_take(p_subject text, p_chars int, p_cached boolean) returns boolean
language plpgsql security definer set search_path = public, private as $$
declare v_day date := (now() at time zone 'Africa/Lagos')::date; u public.tts_usage; v_max_p int; v_max_c int;
begin
  if p_subject !~ '^(org|user):[0-9a-f-]{36}$' then raise exception 'Unknown subject.'; end if;
  v_max_p := case when p_subject like 'org:%' then 600 else 60 end;
  v_max_c := case when p_subject like 'org:%' then 60000 else 6000 end;
  insert into tts_usage (subject, day) values (p_subject, v_day) on conflict do nothing;
  select * into u from tts_usage where subject = p_subject and day = v_day for update;
  if u.phrases + 1 > v_max_p or (not p_cached and u.chars + greatest(p_chars, 0) > v_max_c) then return false; end if;
  update tts_usage set phrases = phrases + 1, chars = chars + case when p_cached then 0 else greatest(p_chars, 0) end
  where subject = p_subject and day = v_day;
  return true;
end $$;

-- ---------------------------------------------------------------------------
-- 4. The business profile: the CAC and TIN records Mono returns, what a web search finds, and the person's answers
-- ---------------------------------------------------------------------------
-- Kinds of business a person can choose from (the app reads this list), each tied to the item set-up it gets.
create table if not exists public.business_categories (
  id text primary key,
  label text not null,
  kind text not null check (kind in ('goods', 'services', 'both')),
  industry text not null,
  sort int not null default 100
);
alter table public.business_categories enable row level security;
drop policy if exists business_categories_read on public.business_categories;
create policy business_categories_read on public.business_categories for select to authenticated using (true);
revoke all on public.business_categories from anon, authenticated;
grant select on public.business_categories to authenticated;
insert into public.business_categories (id, label, kind, industry, sort) values
  ('retail', 'Supermarket, provisions and general retail', 'goods', 'retail', 10),
  ('wholesale', 'Wholesale and distribution', 'goods', 'wholesale', 20),
  ('pharmacy', 'Pharmacy and medical supplies', 'goods', 'pharmacy', 30),
  ('food', 'Food, drinks, restaurants and catering', 'both', 'food', 40),
  ('fashion', 'Fashion, textiles and shoes', 'goods', 'fashion', 50),
  ('electronics', 'Phones, computers and electronics', 'goods', 'electronics', 60),
  ('building', 'Building materials and hardware', 'goods', 'building', 70),
  ('agro', 'Farming, livestock and agro-processing', 'goods', 'agro', 80),
  ('manufacturing', 'Manufacturing and production', 'goods', 'manufacturing', 90),
  ('auto', 'Cars, spare parts and auto services', 'both', 'auto', 100),
  ('beauty', 'Beauty, salon and cosmetics', 'both', 'beauty', 110),
  ('industrial', 'Industrial supplies, oil, gas and energy', 'goods', 'industrial', 120),
  ('professional', 'Professional services: legal, accounting, consulting', 'services', 'other', 200),
  ('technology', 'Technology and software', 'services', 'other', 210),
  ('creative', 'Media, marketing and creative work', 'services', 'other', 220),
  ('logistics', 'Logistics, haulage and transport', 'services', 'other', 230),
  ('construction', 'Construction and engineering', 'services', 'building', 240),
  ('education', 'Schools, training and education', 'services', 'other', 250),
  ('health', 'Hospitals, clinics and health services', 'services', 'pharmacy', 260),
  ('hospitality', 'Hotels, short-lets and events', 'services', 'food', 270),
  ('real_estate', 'Real estate and property', 'services', 'other', 280),
  ('finance', 'Financial services', 'services', 'other', 290),
  ('facility', 'Cleaning, security and facility services', 'services', 'other', 300),
  ('other', 'Something else', 'both', 'other', 999)
on conflict (id) do update set label = excluded.label, kind = excluded.kind, industry = excluded.industry, sort = excluded.sort;

-- One open profile per person, then one per business once submitted. The raw CAC records carry directors' personal
-- details (dates of birth, ID numbers, home addresses), so no signed-in role reads this table: kyc_draft() returns a
-- version without them, to the person who started it or to the owner of the business.
create table if not exists public.kyc_profiles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  org_id uuid references public.orgs(id) on delete set null,
  status text not null default 'draft' check (status in ('draft', 'submitted')),
  source text check (source in ('cac', 'manual')),
  search jsonb not null default '{}'::jsonb,
  cac jsonb,
  tin jsonb,
  web jsonb,
  manual jsonb,
  answers jsonb not null default '{}'::jsonb,
  doc jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  submitted_at timestamptz
);
create unique index if not exists kyc_profiles_one_draft on public.kyc_profiles(user_id) where status = 'draft';
create index if not exists kyc_profiles_org_fk on public.kyc_profiles(org_id);
create index if not exists kyc_profiles_user on public.kyc_profiles(user_id, updated_at desc);
alter table public.kyc_profiles enable row level security;
revoke all on public.kyc_profiles from anon, authenticated;

-- Each paid lookup is counted per person, so a stuck button or a curious user cannot run up the Mono bill.
create table if not exists public.kyc_lookups (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  at timestamptz not null default now()
);
create index if not exists kyc_lookups_user on public.kyc_lookups(user_id, at desc);
alter table public.kyc_lookups enable row level security;
revoke all on public.kyc_lookups from anon, authenticated;
revoke all on sequence public.kyc_lookups_id_seq from anon, authenticated;

-- Per person per day: 20 searches, 6 company profiles, 6 TIN lookups, 3 status reports, 8 web searches, 6 document readings.
create or replace function public.svc_kyc_take(p_user uuid, p_kind text) returns boolean
language plpgsql security definer set search_path = public, private as $$
declare v_max int;
begin
  v_max := case p_kind when 'search' then 20 when 'profile' then 6 when 'tin' then 6 when 'status_report' then 3
    when 'web' then 8 when 'document' then 6 else null end;
  if v_max is null then raise exception 'Unknown lookup.'; end if;
  perform pg_advisory_xact_lock(hashtext('kyc:' || p_user::text));
  if (select count(*) from kyc_lookups where user_id = p_user and kind = p_kind and at > now() - interval '1 day') >= v_max then return false; end if;
  insert into kyc_lookups (user_id, kind) values (p_user, p_kind);
  return true;
end $$;

-- The person's open profile, started if there is none. A business they own that has no profile gets one to finish.
create or replace function private.kyc_row(p_user uuid, p_org uuid default null) returns public.kyc_profiles
language plpgsql security definer set search_path = public, private as $$
declare k public.kyc_profiles;
begin
  if p_org is not null then
    select * into k from kyc_profiles where org_id = p_org order by (status = 'submitted') desc, updated_at desc limit 1;
    if found then return k; end if;
  end if;
  select * into k from kyc_profiles where user_id = p_user and status = 'draft';
  if not found then
    insert into kyc_profiles (user_id, org_id) values (p_user, p_org) on conflict do nothing returning * into k;
    if k.id is null then select * into k from kyc_profiles where user_id = p_user and status = 'draft'; end if;
  elsif p_org is not null and k.org_id is null then
    update kyc_profiles set org_id = p_org where id = k.id returning * into k;
  end if;
  return k;
end $$;

create or replace function private.person(p jsonb) returns text language sql immutable as $$
  select nullif(trim(regexp_replace(initcap(lower(concat_ws(' ', p->>'firstname', p->>'other_name', p->>'surname'))), '\s+', ' ', 'g')), '')
$$;

-- What the questions still need.
create or replace function private.kyc_missing(a jsonb) returns text[] language sql immutable as $$
  select array_remove(array[
    case when a->>'offering' is null then 'offering' end,
    case when a->>'category' is null then 'category' end,
    case when a->>'revenue_band' is null then 'revenue_band' end,
    case when coalesce(jsonb_array_length(a->'receive_methods'), 0) = 0 then 'receive_methods' end,
    case when coalesce(jsonb_array_length(a->'pay_methods'), 0) = 0 then 'pay_methods' end,
    case when coalesce(jsonb_array_length(a->'reasons'), 0) = 0 and coalesce(a->>'reason_note', '') = '' then 'reasons' end,
    case when coalesce(jsonb_array_length(a->'examples'), 0) = 0 then 'examples' end,
    case when a->'filing'->>'vat' is null then 'filing_vat' end,
    case when a->'filing'->>'wht' is null then 'filing_wht' end,
    case when a->'filing'->>'cit' is null then 'filing_cit' end], null)
$$;

-- The profile as the app sees it: the CAC record without directors' personal details.
create or replace function private.kyc_json(k public.kyc_profiles) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare c jsonb := k.cac->'profile'; v_name text; v_cat public.business_categories;
begin
  v_name := coalesce(c->>'approved_name', k.manual->>'name');
  select * into v_cat from business_categories where id = k.answers->>'category';
  return jsonb_build_object(
    'id', k.id, 'status', k.status, 'source', k.source, 'org_id', k.org_id,
    'search', jsonb_build_object('query', k.search->>'query', 'candidates', coalesce(k.search->'candidates', '[]'::jsonb), 'at', k.search->>'at'),
    'business', case when v_name is null then null else jsonb_build_object(
      'name', v_name,
      'cac_id', k.cac->'cac_id',
      'rc_number', coalesce(c->>'rc_number', k.manual->>'rc_number'),
      'classification', coalesce(c->>'classification', k.manual->>'kind'),
      'company_type', c->>'company_type_name',
      'registered_on', left(c->>'registration_date', 10),
      'commenced_on', left(c->>'business_commencement_date', 10),
      'active', (c->>'active')::boolean,
      'objectives', nullif(trim(c->>'objectives'), ''),
      'nature', c->>'nature_of_business_name',
      'address', coalesce(nullif(trim(c->>'business_address'), ''), nullif(trim(c->>'address'), ''), nullif(trim(c->>'head_office_address'), ''), k.manual->>'address'),
      'branch_address', nullif(trim(c->>'branch_address'), ''),
      'state', coalesce(nullif(c->>'state', ''), k.manual->>'state'),
      'email', coalesce(nullif(c->>'business_email', ''), nullif(c->>'email', '')),
      'share_capital', case when c->>'share_capital' ~ '^[0-9]+(\.[0-9]+)?$' then (c->>'share_capital')::numeric end,
      'issued_shares', (select nullif(sum(case when s->>'num_shares_alloted' ~ '^[0-9]+$' then (s->>'num_shares_alloted')::numeric else 0 end), 0)
        from jsonb_array_elements(coalesce(c->'shareholders', '[]'::jsonb)) s),
      'tax_id', coalesce(nullif(k.tin->>'nrs_tin', ''), nullif(c->>'tax_id', '')),
      'directors', coalesce((select jsonb_agg(jsonb_build_object('name', private.person(d), 'appointed', left(d->>'date_of_appointment', 10),
          'chairman', coalesce((d->>'is_chairman')::boolean, false), 'status', d->>'status'))
        from jsonb_array_elements(coalesce(c->'directors', '[]'::jsonb)) d where private.person(d) is not null), '[]'::jsonb),
      'shareholders', coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(private.person(s), nullif(s->>'corporation_name', '')),
          'shares', s->'num_shares_alloted', 'type', nullif(s->>'type_of_shares', '')))
        from jsonb_array_elements(coalesce(c->'shareholders', '[]'::jsonb)) s), '[]'::jsonb),
      'psc', coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(private.person(s), nullif(s->>'corporation_name', '')),
          'shares', s->'num_shares_alloted'))
        from jsonb_array_elements(coalesce(k.cac->'psc', '[]'::jsonb)) s), '[]'::jsonb),
      'secretary', (select coalesce(private.person(s), nullif(s->>'corporation_name', '')) from jsonb_array_elements(coalesce(k.cac->'secretary', '[]'::jsonb)) s limit 1),
      'tin', case when k.tin is null then null else jsonb_build_object('taxpayer_name', k.tin->>'taxpayer_name', 'nrs_tin', k.tin->>'nrs_tin',
        'tax_office', k.tin->>'tax_office', 'tin_type', k.tin->>'tin_type') end) end,
    'web', k.web,
    'answers', k.answers,
    'missing', to_jsonb(private.kyc_missing(k.answers)),
    'category', case when v_cat.id is null then null else jsonb_build_object('id', v_cat.id, 'label', v_cat.label, 'industry', v_cat.industry) end,
    'doc', case when k.doc is null then null else jsonb_build_object('kind', k.doc->>'kind', 'file_name', k.doc->>'file_name', 'path', k.doc->>'path',
      'read', k.doc ? 'extract', 'extract', k.doc->'extract', 'checks', k.doc->'checks', 'at', k.doc->>'at') end,
    'submitted_at', k.submitted_at, 'updated_at', k.updated_at);
end $$;

-- The person's profile (or the business's, for its owner). Reading never starts one: without an open draft it is the
-- profile they submitted last (so the score shows after submitting), or an empty one until they find their business.
create or replace function public.kyc_draft(p_org uuid default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid(); k public.kyc_profiles;
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if p_org is not null and not private.is_owner(p_org) then raise exception 'Only the owner sees the business profile.' using errcode = '42501'; end if;
  if p_org is not null then
    k := private.kyc_row(v_uid, p_org);
  else
    select * into k from kyc_profiles where user_id = v_uid and status = 'draft';
    if not found then
      select * into k from kyc_profiles where user_id = v_uid and status = 'submitted' and org_id is not null and private.is_owner(org_id)
      order by submitted_at desc limit 1;
    end if;
    if not found then
      k.status := 'draft'; k.answers := '{}'::jsonb; k.updated_at := now();
    end if;
  end if;
  return private.kyc_json(k);
end $$;

-- Written by the server only: what Mono and the web search returned, and what was read from a document.
create or replace function public.svc_kyc_store(p_user uuid, p_part text, p_data jsonb, p_org uuid default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare k public.kyc_profiles;
begin
  k := private.kyc_row(p_user, p_org);
  if k.status = 'submitted' and p_part not in ('doc', 'web', 'tin') then raise exception 'This profile is already submitted.'; end if;
  case p_part
    when 'search' then update kyc_profiles set search = p_data, updated_at = now() where id = k.id returning * into k;
    when 'cac' then
      -- A different business: what was found for the last one no longer applies.
      update kyc_profiles set cac = p_data, source = 'cac', manual = null,
        tin = case when cac->'profile'->>'rc_number' is distinct from p_data->'profile'->>'rc_number' then null else tin end,
        web = case when cac->'profile'->>'rc_number' is distinct from p_data->'profile'->>'rc_number' then null else web end,
        updated_at = now() where id = k.id returning * into k;
    when 'tin' then update kyc_profiles set tin = p_data, updated_at = now() where id = k.id returning * into k;
    when 'web' then update kyc_profiles set web = p_data, updated_at = now() where id = k.id returning * into k;
    when 'doc' then update kyc_profiles set doc = coalesce(doc, '{}'::jsonb) || p_data, updated_at = now() where id = k.id returning * into k;
    else raise exception 'Unknown part.';
  end case;
  return private.kyc_json(k);
end $$;

-- A business that is not on CAC (or not yet): the name and address as the person gives them.
create or replace function public.kyc_manual(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid(); k public.kyc_profiles; v_name text := left(trim(coalesce(p->>'name', '')), 120);
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if v_name = '' then raise exception 'Tell us the business name.'; end if;
  if coalesce(p->>'kind', 'unregistered') not in ('unregistered', 'pending', 'other') then raise exception 'Choose how the business is registered.'; end if;
  k := private.kyc_row(v_uid);
  if k.status = 'submitted' then raise exception 'This profile is already submitted.'; end if;
  update kyc_profiles set source = 'manual', cac = null, tin = null,
    manual = jsonb_build_object('name', v_name, 'kind', coalesce(p->>'kind', 'unregistered'), 'address', left(nullif(trim(p->>'address'), ''), 300),
      'state', private.ng_state(p->>'state'), 'rc_number', left(nullif(trim(p->>'rc_number'), ''), 20)),
    updated_at = now()
  where id = k.id returning * into k;
  return private.kyc_json(k);
end $$;

-- The person's answers, each checked against what it may be. Lists replace, the rest merge.
create or replace function public.kyc_answer(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid(); k public.kyc_profiles; a jsonb; x text; v jsonb;
  ok_receive text[] := array['cash', 'bank_transfer', 'pos', 'payment_links', 'ussd', 'mobile_money', 'cheque', 'crypto', 'other'];
  ok_pay text[] := array['cash', 'bank_transfer', 'card', 'pos', 'mobile_money', 'cheque', 'other'];
  ok_reasons text[] := array['track_sales', 'manage_stock', 'get_paid', 'bookkeeping', 'tax_compliance', 'financial_statements', 'loans', 'pay_suppliers', 'team', 'other'];
  ok_filing text[] := array['always', 'sometimes', 'never', 'not_sure', 'not_applicable'];
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if jsonb_typeof(p) <> 'object' then raise exception 'Send the answers as an object.'; end if;
  k := private.kyc_row(v_uid);
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

-- ---------------------------------------------------------------------------
-- The compliance score: ten points, each from a rule. TaxStreem edits the wording in compliance_rules.
-- ---------------------------------------------------------------------------
create table if not exists public.compliance_rules (
  id text primary key,
  sort int not null,
  label text not null,
  done_text text not null,
  todo_text text not null,
  action text,
  active boolean not null default true
);
alter table public.compliance_rules enable row level security;
drop policy if exists compliance_rules_read on public.compliance_rules;
create policy compliance_rules_read on public.compliance_rules for select to authenticated using (true);
revoke all on public.compliance_rules from anon, authenticated;
grant select on public.compliance_rules to authenticated;
insert into public.compliance_rules (id, sort, label, done_text, todo_text, action) values
  ('cac_registered', 1, 'Registered with CAC', 'Your business is registered with the Corporate Affairs Commission and active.',
   'Register the business with the Corporate Affairs Commission: a business name for a sole trader, a company for a limited company. Banks, big customers and the NRS all ask for it.', null),
  ('tax_id', 2, 'Has a Tax ID', 'Your Tax ID is on record.',
   'Get your Tax ID, free, at taxid.nrs.gov.ng with your RC or BN number. It goes on your invoices and on every tax return.', 'settings'),
  ('cac_document', 3, 'CAC records on file', 'Your CAC status report is on file.',
   'Upload your latest CAC status report or your application for registration, so your directors, owners and share capital are on record.', 'cac_document'),
  ('owners_on_record', 4, 'Directors and owners on record', 'CAC shows who runs and owns the business.',
   'CAC shows no directors or owners for the business. Update the record on the CAC portal: banks and the NRS check it.', null),
  ('vat_filing', 5, 'VAT handled', 'VAT is filed every month, or the business is below the ₦100m small company limit.',
   'File a VAT return every month by the 21st, even when it is nil. Counta prepares the NRS VAT return from your sales and bills.', 'vat'),
  ('wht_filing', 6, 'Withholding tax handled', 'Withholding tax is deducted and paid over on time.',
   'Deduct withholding tax from qualifying payments to suppliers and pay it over by the 21st of the next month. Counta works it out on every bill.', 'wht'),
  ('cit_filing', 7, 'Income tax return filed', 'Your annual income tax return is filed.',
   'File your income tax return every year, within six months of your year end. Counta builds the return from your books.', 'cit'),
  ('business_account', 8, 'Paid into a business account', 'Customers pay into an account in the business''s name.',
   'Collect payments into an account in the business''s name, not a personal one. Get your Counta account number in Payments.', 'account_number'),
  ('bank_records', 9, 'Bank records in the books', 'Your bank activity comes into Counta.',
   'Connect your bank, or upload a bank statement, so every naira in and out is in your books.', 'bank'),
  ('books_current', 10, 'Sales recorded', 'Your sales are recorded in Counta.',
   'Record your sales in Counta, at the till, by invoice or by voice, so your books and tax returns build themselves.', 'first_sale')
on conflict (id) do nothing;

create or replace function private.compliance_items(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; k public.kyc_profiles; a jsonb; v_out jsonb := '[]'::jsonb; r public.compliance_rules; v_ok boolean; v_cls text; v_small boolean;
begin
  select * into o from orgs where id = p_org;
  select * into k from kyc_profiles where org_id = p_org order by (status = 'submitted') desc, updated_at desc limit 1;
  a := coalesce(k.answers, '{}'::jsonb);
  v_cls := upper(coalesce(k.cac->'profile'->>'classification', ''));
  v_small := a->>'revenue_band' in ('0_50m', '50_100m');
  for r in select * from compliance_rules where active order by sort loop
    v_ok := case r.id
      when 'cac_registered' then (k.source = 'cac' and coalesce((k.cac->'profile'->>'active')::boolean, true)) or (k.id is null and o.rc_number is not null)
      when 'tax_id' then o.tin is not null or coalesce(k.tin->>'nrs_tin', k.cac->'profile'->>'tax_id', '') <> ''
      when 'cac_document' then k.doc ? 'path'
      when 'owners_on_record' then k.source = 'cac' and (jsonb_array_length(coalesce(k.cac->'profile'->'directors', '[]'::jsonb)) > 0
        or jsonb_array_length(coalesce(k.cac->'profile'->'shareholders', '[]'::jsonb)) > 0 or jsonb_array_length(coalesce(k.cac->'psc', '[]'::jsonb)) > 0)
      when 'vat_filing' then a->'filing'->>'vat' = 'always' or (v_small and not o.vat_registered)
        or exists (select 1 from vat_periods where org_id = p_org and status = 'filed' and period >= (now() - interval '62 days')::date)
      when 'wht_filing' then a->'filing'->>'wht' in ('always', 'not_applicable')
        or exists (select 1 from wht_remittances where org_id = p_org and created_at > now() - interval '62 days')
      when 'cit_filing' then a->'filing'->>'cit' = 'always' or exists (select 1 from cit_years where org_id = p_org and status = 'filed')
      when 'business_account' then exists (select 1 from wallets where org_id = p_org and status = 'active')
        or exists (select 1 from jsonb_array_elements_text(coalesce(a->'receive_methods', '[]'::jsonb)) m where m in ('bank_transfer', 'pos', 'payment_links'))
      when 'bank_records' then exists (select 1 from bank_accounts where org_id = p_org and provider = 'mono' and active)
        or exists (select 1 from bank_imports where org_id = p_org)
      when 'books_current' then exists (select 1 from sales where org_id = p_org
        and ((doc_type = 'receipt' and status = 'paid') or (doc_type = 'invoice' and status in ('open', 'partially_paid', 'paid'))))
      else false end;
    v_out := v_out || jsonb_build_object('id', r.id, 'label', r.label, 'ok', coalesce(v_ok, false),
      'text', case when coalesce(v_ok, false) then r.done_text else r.todo_text end, 'action', r.action);
  end loop;
  return v_out;
end $$;

-- The score and what to do next, for the owner and anyone who keeps the books.
create or replace function public.compliance_score(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_items jsonb;
begin
  m := private.require(p_org, null);
  if m.role <> 'owner' and not private.perm_of(m, 'keep_books') then raise exception 'Only the owner and the bookkeepers see the compliance score.' using errcode = '42501'; end if;
  v_items := private.compliance_items(p_org);
  return jsonb_build_object('score', (select count(*) from jsonb_array_elements(v_items) i where (i->>'ok')::boolean),
    'total', jsonb_array_length(v_items), 'items', v_items,
    'next', (select i from jsonb_array_elements(v_items) i where not (i->>'ok')::boolean and i->>'action' is not null limit 1));
end $$;

-- Submit the profile: the business is set up from the CAC record (or updated, when the person already owns it) with the
-- answers as edited on the summary, and the score is returned.
--   p: {trading_name, phone, email, address, branch_name, charges_vat, answers: {...}}
create or replace function public.kyc_submit(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid(); k public.kyc_profiles; c jsonb; v_org uuid; v_name text; v_addr text; v_vat boolean; v_cat public.business_categories;
  v_form text; v_cls text; v_tin text; v_dir jsonb; v_display text; v_branch text; v_email text; v_state text; v_lga text; v_shares numeric;
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if p ? 'answers' then perform public.kyc_answer(p->'answers'); end if;
  if p ? 'charges_vat' then perform public.kyc_answer(jsonb_build_object('charges_vat', p->'charges_vat')); end if;
  k := private.kyc_row(v_uid);
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

  v_org := k.org_id;
  if v_org is null then
    v_org := public.create_org(v_name, coalesce(nullif(trim(p->>'email'), ''), v_email), nullif(trim(p->>'phone'), ''), v_display,
      jsonb_build_array(jsonb_build_object('name', v_branch, 'address', v_addr)), v_vat, false);
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

-- A CAC document in the business's folder (uploaded by the owner, or fetched from CAC through Mono).
create or replace function public.kyc_doc(p_org uuid, p_path text, p_kind text, p_file_name text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid(); k public.kyc_profiles;
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if not private.is_owner(p_org) then raise exception 'Only the owner adds the CAC documents.' using errcode = '42501'; end if;
  if p_kind not in ('status_report', 'application', 'certificate', 'other') then raise exception 'Choose what kind of CAC document this is.'; end if;
  if p_path is null or left(p_path, 41) <> p_org::text || '/kyc/' or p_path like '%..%' or length(p_path) > 200 then raise exception 'Upload the document again.'; end if;
  k := private.kyc_row(v_uid, p_org);
  update kyc_profiles set doc = jsonb_build_object('path', p_path, 'kind', p_kind, 'file_name', left(coalesce(p_file_name, split_part(p_path, '/', -1)), 200),
    'at', now()), updated_at = now() where id = k.id returning * into k;
  return private.kyc_json(k);
end $$;

-- ---------------------------------------------------------------------------
-- 5. The onboarding guide
-- ---------------------------------------------------------------------------
create table if not exists public.guide_progress (
  user_id uuid primary key references auth.users(id) on delete cascade,
  org_id uuid references public.orgs(id) on delete set null,
  marks jsonb not null default '{}'::jsonb,
  language text not null default 'en' check (language in ('en', 'pcm')),
  call_consent boolean not null default false,
  call_phone text,
  consent_at timestamptz,
  started_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  completed_at timestamptz,
  dismissed_at timestamptz,
  followup_status text not null default 'none' check (followup_status in ('none', 'calling', 'done', 'no_answer', 'failed', 'declined')),
  followup_attempts int not null default 0,
  followup_last_at timestamptz
);
create index if not exists guide_progress_org_fk on public.guide_progress(org_id);
create index if not exists guide_progress_due on public.guide_progress(last_seen_at) where call_consent and completed_at is null;
alter table public.guide_progress enable row level security;
drop policy if exists guide_progress_own on public.guide_progress;
create policy guide_progress_own on public.guide_progress for select to authenticated using (user_id = (select auth.uid()));
revoke all on public.guide_progress from anon, authenticated;
grant select on public.guide_progress to authenticated;

create table if not exists public.guide_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  conversation_id text,
  started_at timestamptz not null default now()
);
create index if not exists guide_sessions_user on public.guide_sessions(user_id, started_at desc);
alter table public.guide_sessions enable row level security;
revoke all on public.guide_sessions from anon, authenticated;

-- The steps, in order, worked out from what the person has really done (so the checklist cannot be faked). First the
-- business profile, then the first things to do in Counta. Optional steps can be skipped.
create or replace function private.guide_steps(p_user uuid, p_org uuid, p_marks jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare k public.kyc_profiles; o public.orgs; v jsonb := '[]'::jsonb; s record;
begin
  select * into k from kyc_profiles
  where (p_org is not null and org_id = p_org) or (user_id = p_user and status = 'draft')
  order by (org_id is not distinct from p_org) desc, (status = 'submitted') desc, updated_at desc limit 1;
  select * into o from orgs where id = p_org;
  for s in select * from (values
    ('find_business', 'profile', false, k.source is not null),
    ('questions', 'profile', false, k.id is not null and array_length(private.kyc_missing(k.answers), 1) is null),
    ('submitted', 'profile', false, k.status = 'submitted'),
    ('cac_document', 'profile', true, k.doc ? 'path'),
    ('account_number', 'first_steps', false, p_org is not null and exists (select 1 from wallets where org_id = p_org and status = 'active')),
    ('voice', 'first_steps', false, p_org is not null and (o.voice_id is not null or p_marks ? 'voice_chosen')),
    ('first_sale', 'first_steps', false, p_org is not null and exists (select 1 from sales where org_id = p_org
      and ((doc_type = 'receipt' and status = 'paid') or (doc_type = 'invoice' and status in ('open', 'partially_paid', 'paid'))))),
    ('bank_connect', 'first_steps', true, p_org is not null and exists (select 1 from bank_accounts where org_id = p_org and provider = 'mono' and active)),
    ('bank_statement', 'first_steps', true, p_org is not null and exists (select 1 from bank_imports where org_id = p_org)),
    ('products', 'first_steps', true, p_org is not null and exists (select 1 from items where org_id = p_org and not archived)),
    ('team', 'first_steps', true, p_org is not null and exists (select 1 from members where org_id = p_org and user_id is distinct from p_user))
  ) t(id, phase, optional, done) loop
    v := v || jsonb_build_object('id', s.id, 'phase', s.phase, 'optional', s.optional, 'done', coalesce(s.done, false),
      'skipped', s.optional and not coalesce(s.done, false) and p_marks ? ('skip_' || s.id));
  end loop;
  return v;
end $$;

-- Where the signed-in person is with setting up: their business (the one asked for, else the newest one they own
-- that is not a sample), the steps done, the next step, and their call consent.
create or replace function public.guide_state(p_org uuid default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid(); g public.guide_progress; v_org uuid; o public.orgs; v_steps jsonb; v_done int; v_next text; v_name text;
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  insert into guide_progress (user_id) values (v_uid) on conflict do nothing;
  if p_org is not null then
    perform private.require(p_org, null);
    v_org := p_org;
  else
    select m.org_id into v_org from members m join orgs x on x.id = m.org_id
    where m.user_id = v_uid and m.role = 'owner' and not coalesce(x.is_sample, false)
    order by x.created_at desc limit 1;
  end if;
  select * into g from guide_progress where user_id = v_uid;
  -- A business they have just set up speaks the language they chose for the guide, until they choose otherwise.
  if v_org is not null and g.org_id is distinct from v_org and g.language <> 'en' then
    update orgs set voice_lang = g.language where id = v_org and voice_id is null and voice_lang = 'en'
      and exists (select 1 from members where org_id = v_org and user_id = v_uid and role = 'owner');
  end if;
  update guide_progress set org_id = coalesce(v_org, org_id), last_seen_at = now() where user_id = v_uid returning * into g;
  if g.org_id is not null and not exists (select 1 from members where org_id = g.org_id and user_id = v_uid) then
    update guide_progress set org_id = null where user_id = v_uid returning * into g;
  end if;
  select * into o from orgs where id = g.org_id;
  v_steps := private.guide_steps(v_uid, g.org_id, g.marks);
  select count(*) filter (where (s->>'done')::boolean or (s->>'skipped')::boolean) into v_done from jsonb_array_elements(v_steps) s;
  select s->>'id' into v_next from jsonb_array_elements(v_steps) with ordinality t(s, ord)
  where not (s->>'done')::boolean and not (s->>'skipped')::boolean order by ord limit 1;
  if v_done = jsonb_array_length(v_steps) and g.completed_at is null then
    update guide_progress set completed_at = now() where user_id = v_uid returning * into g;
  end if;
  select coalesce(nullif(trim(raw_user_meta_data->>'full_name'), ''), nullif(trim(raw_user_meta_data->>'name'), '')) into v_name
  from auth.users where id = v_uid;
  if v_name is null and o.id is not null then select display_name into v_name from members where org_id = o.id and user_id = v_uid; end if;
  return jsonb_build_object(
    'steps', v_steps, 'done', v_done, 'total', jsonb_array_length(v_steps), 'next', v_next,
    'completed', g.completed_at is not null, 'dismissed', g.dismissed_at is not null,
    'org', case when o.id is null then null else jsonb_build_object('id', o.id, 'name', o.name, 'industry', o.industry, 'created_at', o.created_at,
      'voice_id', o.voice_id, 'voice_lang', o.voice_lang, 'is_owner', exists (select 1 from members where org_id = o.id and user_id = v_uid and role = 'owner')) end,
    'first_name', coalesce(split_part(v_name, ' ', 1), ''),
    'language', g.language, 'marks', g.marks,
    'call', jsonb_build_object('consent', g.call_consent, 'phone', g.call_phone, 'status', g.followup_status));
end $$;

-- What the app reports itself: the payment moment was heard, a voice was previewed or chosen, the checklist was put away.
create or replace function public.guide_mark(p_mark text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if p_mark not in ('payment_demo', 'voice_previewed', 'voice_chosen', 'intro_heard', 'dismissed', 'resumed', 'score_seen',
                    'skip_cac_document', 'skip_bank_connect', 'skip_bank_statement', 'skip_products', 'skip_team') then
    raise exception 'Unknown step.';
  end if;
  insert into guide_progress (user_id) values (v_uid) on conflict do nothing;
  update guide_progress set
    marks = case when p_mark in ('dismissed', 'resumed') then marks else marks || jsonb_build_object(p_mark, now()) end,
    dismissed_at = case when p_mark = 'dismissed' then now() when p_mark = 'resumed' then null else dismissed_at end,
    last_seen_at = now()
  where user_id = v_uid;
  return public.guide_state(null);
end $$;

-- English or Pidgin for the guide (and for the business's announcements when the person owns it).
create or replace function public.guide_language(p_lang text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid(); g public.guide_progress;
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if p_lang not in ('en', 'pcm') then raise exception 'Choose English or Pidgin.'; end if;
  insert into guide_progress (user_id) values (v_uid) on conflict do nothing;
  update guide_progress set language = p_lang, last_seen_at = now() where user_id = v_uid returning * into g;
  if g.org_id is not null and exists (select 1 from members where org_id = g.org_id and user_id = v_uid and role in ('owner', 'manager')) then
    update orgs set voice_lang = p_lang where id = g.org_id;
  end if;
  return public.guide_state(null);
end $$;

-- "Call me if I get stuck": the number is checked, and saying no removes it.
create or replace function public.guide_consent(p_consent boolean, p_phone text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid(); v_phone text;
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  insert into guide_progress (user_id) values (v_uid) on conflict do nothing;
  if coalesce(p_consent, false) then
    v_phone := private.e164(p_phone);
    if v_phone is null then raise exception 'Enter a Nigerian phone number, for example 0803 123 4567.'; end if;
    update guide_progress set call_consent = true, call_phone = v_phone, consent_at = now(), last_seen_at = now(),
      followup_status = case when followup_status = 'declined' then 'none' else followup_status end
    where user_id = v_uid;
  else
    update guide_progress set call_consent = false, call_phone = null, consent_at = now(), last_seen_at = now() where user_id = v_uid;
  end if;
  return public.guide_state(null);
end $$;

-- A new guide conversation: at most 8 a day and 25 a week per person. Returns the session id, or null when over.
create or replace function public.svc_guide_session(p_user uuid, p_conversation text default null) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare v_id uuid;
begin
  perform pg_advisory_xact_lock(hashtext('guide:' || p_user::text));
  if (select count(*) from guide_sessions where user_id = p_user and started_at > now() - interval '1 day') >= 8
     or (select count(*) from guide_sessions where user_id = p_user and started_at > now() - interval '7 days') >= 25 then
    return null;
  end if;
  insert into guide_sessions (user_id, conversation_id) values (p_user, nullif(p_conversation, '')) returning id into v_id;
  return v_id;
end $$;

create or replace function public.svc_guide_session_set(p_session uuid, p_conversation text) returns void
language sql security definer set search_path = public, private as $$
  update guide_sessions set conversation_id = nullif(p_conversation, '') where id = p_session;
$$;

-- ---------------------------------------------------------------------------
-- 6. Follow-up calls
-- ---------------------------------------------------------------------------
alter table public.voice_calls add column if not exists user_id uuid references auth.users(id) on delete set null;
alter table public.voice_calls alter column org_id drop not null;
create index if not exists voice_calls_user_fk on public.voice_calls(user_id);
do $$
declare c text;
begin
  for c in select conname from pg_constraint where conrelid = 'public.voice_calls'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) like '%kind%' loop
    execute format('alter table public.voice_calls drop constraint %I', c);
  end loop;
  alter table public.voice_calls add constraint voice_calls_kind_check check (kind in ('vendor_order', 'reminder', 'guide_followup'));
  alter table public.voice_calls add constraint voice_calls_owner_check check (org_id is not null or (kind = 'guide_followup' and user_id is not null));
end $$;

-- Who is due a call: said yes, has a number, has not finished, went quiet for three hours within a week of starting,
-- at most two tries a day apart. Only between 9:00 and 18:30 in Lagos.
create or replace function private.guide_due(p_at timestamptz default now()) returns setof public.guide_progress
language sql stable security definer set search_path = public, private as $$
  select g.* from guide_progress g
  where g.call_consent and g.call_phone is not null and g.completed_at is null and g.dismissed_at is null
    and g.started_at > p_at - interval '7 days' and g.last_seen_at < p_at - interval '3 hours'
    and g.followup_status in ('none', 'no_answer') and g.followup_attempts < 2
    and (g.followup_last_at is null or g.followup_last_at < p_at - interval '20 hours')
    and (p_at at time zone 'Africa/Lagos')::time between time '09:00' and time '18:30';
$$;

-- Taken by the voice function: marks each person as being called and opens the call record.
create or replace function public.svc_guide_followups_due(p_limit int default 10, p_at timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare g public.guide_progress; v_out jsonb := '[]'::jsonb; v_state jsonb; v_vars jsonb; v_id uuid; v_name text; v_org public.orgs; v_step text;
begin
  for g in select * from private.guide_due(p_at) order by last_seen_at limit greatest(1, least(p_limit, 25)) loop
    perform 1 from guide_progress where user_id = g.user_id and followup_status in ('none', 'no_answer') for update skip locked;
    if not found then continue; end if;
    select * into v_org from orgs where id = g.org_id;
    select coalesce(nullif(trim(raw_user_meta_data->>'full_name'), ''), nullif(trim(raw_user_meta_data->>'name'), ''), '') into v_name from auth.users where id = g.user_id;
    v_state := private.guide_steps(g.user_id, g.org_id, g.marks);
    select s->>'id' into v_step from jsonb_array_elements(v_state) with ordinality t(s, ord)
    where not (s->>'done')::boolean and not (s->>'skipped')::boolean order by ord limit 1;
    v_vars := jsonb_build_object(
      'first_name', coalesce(nullif(split_part(v_name, ' ', 1), ''), 'there'),
      'business_name', coalesce(v_org.name, 'your business'),
      'has_business', case when v_org.id is null then 'no' else 'yes' end,
      'next_step', case v_step when 'find_business' then 'finding the business on CAC' when 'questions' then 'answering a few questions about the business'
        when 'submitted' then 'checking and submitting the business profile' when 'cac_document' then 'uploading the CAC status report'
        when 'account_number' then 'getting the business account number' when 'voice' then 'choosing the voice that announces payments'
        when 'first_sale' then 'recording the first sale' when 'bank_connect' then 'connecting the bank account'
        when 'bank_statement' then 'uploading a bank statement' when 'products' then 'adding the first products'
        when 'team' then 'inviting the team' else 'finishing setup' end,
      'steps_done', (select count(*) from jsonb_array_elements(v_state) s where (s->>'done')::boolean or (s->>'skipped')::boolean),
      'steps_total', jsonb_array_length(v_state),
      'language_style', case when g.language = 'pcm' then 'pidgin' else 'english' end);
    insert into voice_calls (org_id, user_id, kind, to_number, variables)
    values (g.org_id, g.user_id, 'guide_followup', g.call_phone, v_vars) returning id into v_id;
    update guide_progress set followup_status = 'calling', followup_attempts = followup_attempts + 1, followup_last_at = p_at where user_id = g.user_id;
    v_out := v_out || jsonb_build_object('call_id', v_id, 'to_number', g.call_phone, 'variables', v_vars, 'org_id', g.org_id,
      'voice_id', v_org.voice_id, 'lang', g.language);
  end loop;
  return v_out;
end $$;

-- Every 15 minutes: if anyone is due a call, ask the voice function to place it.
create or replace function private.guide_tick() returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if exists (select 1 from private.guide_due(now())) then
    perform private.call_function('voice', jsonb_build_object('action', 'guide_followups'));
  end if;
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'counta-guide-followups';
    perform cron.schedule('counta-guide-followups', '*/15 * * * *', 'select private.guide_tick()');
  end if;
end $$;

-- The call record, as before, plus the guide's follow-up calls: the result updates the person's guide progress, and
-- "please don't call me again" withdraws the consent.
create or replace function public.voice_call_update(p_call uuid, p_patch jsonb) returns void
language plpgsql security definer set search_path = public, private as $$
declare c public.voice_calls; v_final boolean; v_outcome jsonb; v_vendor text; v_when text; v_title text; v_body text;
begin
  select * into c from voice_calls where id = p_call for update;
  if not found then return; end if;
  update voice_calls set
    status = coalesce(p_patch->>'status', status),
    conversation_id = coalesce(p_patch->>'conversation_id', conversation_id),
    call_sid = coalesce(p_patch->>'call_sid', call_sid),
    outcome = case when p_patch ? 'outcome' then p_patch->'outcome' else outcome end,
    summary = coalesce(p_patch->>'summary', summary),
    transcript = case when p_patch ? 'transcript' then p_patch->'transcript' else transcript end,
    duration_secs = coalesce((p_patch->>'duration_secs')::int, duration_secs),
    error = coalesce(p_patch->>'error', error),
    ended_at = case when p_patch->>'status' in ('completed', 'no_answer', 'busy', 'voicemail', 'failed') then coalesce(ended_at, now()) else ended_at end,
    synced_at = now()
  where id = c.id;

  v_final := p_patch->>'status' in ('completed', 'no_answer', 'busy', 'voicemail', 'failed')
             and c.status not in ('completed', 'no_answer', 'busy', 'voicemail', 'failed');
  if not v_final then return; end if;
  v_outcome := coalesce(p_patch->'outcome', '{}'::jsonb);

  if c.kind = 'guide_followup' then
    if p_patch->>'status' = 'completed' and coalesce((v_outcome->>'stop_calls')::boolean, false) then
      update guide_progress set followup_status = 'declined', call_consent = false, call_phone = null where user_id = c.user_id;
    else
      update guide_progress set followup_status = case p_patch->>'status' when 'completed' then 'done' when 'failed' then 'failed' else 'no_answer' end
      where user_id = c.user_id;
    end if;
    return;
  end if;

  if c.kind = 'vendor_order' then
    v_vendor := coalesce(c.variables->>'vendor_name', 'The vendor');
    v_when := nullif(trim(v_outcome->>'delivery_date'), '');
    if p_patch->>'status' = 'completed' and coalesce((v_outcome->>'order_confirmed')::boolean, false) then
      update purchase_orders set
        status = case when status = 'draft' then 'sent' else status end,
        sent_via = case when status = 'draft' then 'phone call' else sent_via end,
        sent_at = coalesce(sent_at, now()),
        approved_by = coalesce(approved_by, c.created_by),
        note = left(trim(coalesce(note || E'\n', '') || 'Phone call ' || to_char(now() at time zone 'Africa/Lagos', 'DD Mon HH24:MI') || ': confirmed'
          || coalesce(', delivery ' || v_when, '')
          || coalesce('. Not available: ' || nullif(trim(v_outcome->>'unavailable_items'), ''), '')
          || coalesce('. Price changes: ' || nullif(trim(v_outcome->>'price_changes'), ''), '') || '.'), 2000)
      where id = c.po_id;
      v_title := v_vendor || ' confirmed ' || coalesce(c.variables->>'po_ref', 'the order');
      v_body := coalesce('Delivery ' || v_when || '. ', '') || coalesce('Not available: ' || nullif(trim(v_outcome->>'unavailable_items'), '') || '. ', '')
        || coalesce('Price changes: ' || nullif(trim(v_outcome->>'price_changes'), '') || '.', '');
    elsif p_patch->>'status' = 'completed' then
      v_title := v_vendor || ' did not confirm ' || coalesce(c.variables->>'po_ref', 'the order');
      v_body := coalesce(nullif(p_patch->>'summary', ''), 'Open the call to see what they said.');
    else
      v_title := 'Could not reach ' || v_vendor;
      v_body := case p_patch->>'status' when 'no_answer' then 'No one picked up.' when 'busy' then 'The line was busy.' when 'voicemail' then 'The call went to voicemail.'
                else coalesce('The call failed: ' || nullif(p_patch->>'error', ''), 'The call failed.') end || ' Try again later or send the order on WhatsApp.';
    end if;
    perform private.notify(c.org_id, (select user_id from members where id = c.created_by), 'call_result', v_title, coalesce(nullif(v_body, ''), 'Open Counta for the details.'),
      '/inventory/reorder', 'call:' || c.id);
  else
    v_title := case when p_patch->>'status' = 'completed' then 'Reminder call to ' || coalesce(c.variables->>'person_first_name', 'your colleague') || ' done'
                    else 'Could not reach ' || coalesce(c.variables->>'person_first_name', 'your colleague') end;
    v_body := case when p_patch->>'status' = 'completed'
                   then coalesce(case when (v_outcome->>'will_act')::boolean then 'They said they will handle it' || coalesce(' ' || nullif(trim(v_outcome->>'when'), ''), '') || '.' end,
                                 nullif(p_patch->>'summary', ''), 'Open Counta for the details.')
                   else 'The call did not connect.' end;
    perform private.notify(c.org_id, (select user_id from members where id = c.created_by), 'call_result', v_title, v_body, '/inventory/locations', 'call:' || c.id);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Storage: spoken phrases are cached in a private bucket only the service role reads. The CAC documents in
-- "<org>/kyc/" name the directors and their addresses, so only the owner reads or adds them (staff keep the rest).
-- ---------------------------------------------------------------------------
create or replace function private.is_owner_text(p_org text) returns boolean
language sql stable security definer set search_path = public as $$
  select case when p_org ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then private.is_owner(p_org::uuid) else false end
$$;
revoke execute on function private.is_owner_text(text) from public, anon;
grant execute on function private.is_owner_text(text) to authenticated;

do $$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public) values ('voice-cache', 'voice-cache', false) on conflict (id) do nothing;
  end if;
  if to_regclass('storage.objects') is not null then
    drop policy if exists "documents read by members" on storage.objects;
    create policy "documents read by members" on storage.objects for select to authenticated
      using (bucket_id = 'documents' and (select private.is_member_text((storage.foldername(name))[1]))
        and ((storage.foldername(name))[2] is distinct from 'tax' or (select private.can_handle_money_text((storage.foldername(name))[1])))
        and ((storage.foldername(name))[2] is distinct from 'kyc' or (select private.is_owner_text((storage.foldername(name))[1]))));
    drop policy if exists "documents upload by members" on storage.objects;
    create policy "documents upload by members" on storage.objects for insert to authenticated
      with check (bucket_id = 'documents' and (select private.is_member_text((storage.foldername(name))[1]))
        and ((storage.foldername(name))[2] is distinct from 'tax' or (select private.can_handle_money_text((storage.foldername(name))[1])))
        and ((storage.foldername(name))[2] is distinct from 'kyc' or (select private.is_owner_text((storage.foldername(name))[1]))));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
revoke execute on function public.voice_settings(uuid), public.save_voice_settings(uuid, jsonb), public.voice_say(uuid, text, jsonb),
  public.guide_state(uuid), public.guide_mark(text), public.guide_language(text), public.guide_consent(boolean, text),
  public.kyc_draft(uuid), public.kyc_manual(jsonb), public.kyc_answer(jsonb), public.kyc_submit(jsonb), public.kyc_doc(uuid, text, text, text),
  public.compliance_score(uuid)
  from public, anon;
grant execute on function public.voice_settings(uuid), public.save_voice_settings(uuid, jsonb), public.voice_say(uuid, text, jsonb),
  public.guide_state(uuid), public.guide_mark(text), public.guide_language(text), public.guide_consent(boolean, text),
  public.kyc_draft(uuid), public.kyc_manual(jsonb), public.kyc_answer(jsonb), public.kyc_submit(jsonb), public.kyc_doc(uuid, text, text, text),
  public.compliance_score(uuid)
  to authenticated;
revoke execute on function public.svc_tts_take(text, int, boolean), public.svc_guide_session(uuid, text), public.svc_guide_session_set(uuid, text),
  public.svc_guide_followups_due(int, timestamptz), public.voice_call_update(uuid, jsonb),
  public.svc_kyc_take(uuid, text), public.svc_kyc_store(uuid, text, jsonb, uuid)
  from public, anon, authenticated;
grant execute on function public.svc_tts_take(text, int, boolean), public.svc_guide_session(uuid, text), public.svc_guide_session_set(uuid, text),
  public.svc_guide_followups_due(int, timestamptz), public.voice_call_update(uuid, jsonb),
  public.svc_kyc_take(uuid, text), public.svc_kyc_store(uuid, text, jsonb, uuid)
  to service_role;
revoke execute on function private.guide_steps(uuid, uuid, jsonb), private.guide_due(timestamptz), private.guide_tick(),
  private.kyc_row(uuid, uuid), private.person(jsonb), private.kyc_missing(jsonb), private.kyc_json(public.kyc_profiles), private.compliance_items(uuid)
  from public, anon, authenticated;
