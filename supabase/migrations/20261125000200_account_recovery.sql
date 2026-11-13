-- Counta · one business per company, and how a director recovers one set up by someone else
--
-- A company (one RC, BN or IT number, or one Tax ID) is on Counta once. Anyone who finds it on CAC while setting up a
-- business is told it is already here, with the email of the account that holds it masked (k****@g****.com), and is not
-- let through. A director of the company can recover it:
--
--   1. They prove who they are as a director confirming wallets does (20261125000100_director_identity.sql): their NIN
--      must match a director (or proprietor) on the CAC record, and the code goes to the phone NIMC holds for the NIN and
--      to their email on the CAC record, never to an address of the account that holds the business now.
--   2. The holder (the owner, or the firm that runs it) is told at once, by email and in the app, and has 30 minutes to
--      start the handover. Until it is settled, no money leaves the business's wallets.
--   3. The handover emails the director a link. Signed in with their own login, they accept: the business becomes theirs
--      and the previous owner's place ends (a firm's places end with it). Nothing about the director's own login changes.
--   4. If the holder does nothing within 30 minutes, says no, or the director cannot get the code, the director asks
--      TaxStreem's support from the page; the request reaches the admin portal (Recoveries) and the support address.
--   5. Without a phone on the NIN record, the code goes to the CAC email and phone and TaxStreem checks the request before
--      the holder is told.
--
-- A trigger on orgs refuses a second business with the same registration number or Tax ID, whichever function writes it.
-- Sample businesses and businesses kept read-only after a mandate ended are not counted.

-- ---------------------------------------------------------------------------
-- 1. One business per company
-- ---------------------------------------------------------------------------
-- A business's registration number with its registry: CAC numbers are kept as digits, so the registry comes from the
-- legal form when the number does not say (RC for a company, BN for a business name, IT for incorporated trustees).
create or replace function private.org_reg(p_rc text, p_form text) returns text
language sql immutable set search_path = public, private as $$
  select case when private.reg_kind(p_rc) is null and private.norm_id(p_rc) is not null and p_form in ('company', 'enterprise', 'ngo')
    then case p_form when 'company' then 'RC ' when 'enterprise' then 'BN ' else 'IT ' end || btrim(p_rc) else p_rc end
$$;

-- A draft profile's company: its registration number with the registry (from the CAC classification) and its Tax ID,
-- {reg, tin}.
create or replace function private.kyc_ids(k public.kyc_profiles) returns jsonb
language plpgsql stable set search_path = public, private as $$
declare c jsonb := k.cac->'profile'; v_rc text; v_cls text; v_tin text;
begin
  v_rc := coalesce(nullif(c->>'rc_number', ''), nullif(k.manual->>'rc_number', ''));
  v_cls := upper(coalesce(c->>'classification', ''));
  v_tin := coalesce(nullif(regexp_replace(coalesce(k.tin->>'nrs_tin', ''), '\D', '', 'g'), ''), nullif(regexp_replace(coalesce(c->>'tax_id', ''), '\D', '', 'g'), ''));
  return jsonb_build_object('reg', private.org_reg(v_rc, case when v_cls like 'COMPANY%' then 'company' when v_cls = 'BUSINESS_NAME' then 'enterprise'
      when v_cls = 'IT' then 'ngo' end),
    'tin', case when v_tin ~ '^[0-9]{13}$' then v_tin end);
end $$;

-- The business already on Counta with this registration number (compared with its registry) or Tax ID, other than p_except:
-- not a sample, not kept read-only. Null when there is none.
create or replace function private.reg_holder(p_reg text, p_tin text, p_except uuid) returns public.orgs
language sql stable set search_path = public, private as $$
  select o.* from orgs o
  where o.id is distinct from p_except and not o.is_sample and o.read_only_at is null
    and ((private.norm_id(p_reg) is not null and private.same_reg(private.org_reg(o.rc_number, o.legal_form), p_reg))
         or (private.norm_id(p_tin) is not null and private.norm_id(o.tin) = private.norm_id(p_tin)))
  order by o.created_at, o.id
  limit 1
$$;

create or replace function private.orgs_reg_unique() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare h public.orgs; v_reg text := private.org_reg(new.rc_number, new.legal_form); v_by_reg boolean;
begin
  if new.is_sample or new.read_only_at is not null then return new; end if;
  if tg_op = 'UPDATE' and new.rc_number is not distinct from old.rc_number and new.tin is not distinct from old.tin
     and new.legal_form is not distinct from old.legal_form and new.read_only_at is not distinct from old.read_only_at
     and new.is_sample is not distinct from old.is_sample then
    return new;
  end if;
  if private.norm_id(new.rc_number) is null and private.norm_id(new.tin) is null then return new; end if;
  perform private.company_lock(new.rc_number, new.tin);
  h := private.reg_holder(v_reg, new.tin, new.id);
  if h.id is not null then
    v_by_reg := private.norm_id(v_reg) is not null and private.same_reg(private.org_reg(h.rc_number, h.legal_form), v_reg);
    raise exception 'Another business on Counta already has this % (%). A company is on Counta once.',
      case when v_by_reg then 'registration number' else 'Tax ID' end, case when v_by_reg then btrim(new.rc_number) else btrim(new.tin) end
      using errcode = '23505';
  end if;
  return new;
end $$;
drop trigger if exists orgs_reg_unique on public.orgs;
create trigger orgs_reg_unique before insert or update of rc_number, tin, legal_form, read_only_at, is_sample on public.orgs
  for each row execute function private.orgs_reg_unique();

-- Where Counta writes to the holder of a business: its owners (active, with a login), or for a business a firm runs the
-- engagement partner and the firm's own address.
create or replace function private.holder_emails(p_org uuid) returns text[]
language sql stable security definer set search_path = public, private as $$
  select coalesce(array_agg(distinct e order by e) filter (where e is not null), '{}') from (
    select private.clean_email(coalesce(u.email, m.email)) as e
    from members m left join auth.users u on u.id = m.user_id
    where m.org_id = p_org and m.status = 'active' and m.role = 'owner' and m.user_id is not null
      and not exists (select 1 from orgs o where o.id = p_org and o.managed_by is not null)
    union all
    select private.clean_email(pm.email) from orgs o join practice_clients c on c.id = (private.mandate(o.id)).id
      join practice_members pm on pm.id = c.engagement_partner_id and pm.status = 'active'
    where o.id = p_org and o.managed_by is not null
    union all
    select private.clean_email(p.email) from orgs o join practices p on p.id = o.managed_by where o.id = p_org) x
$$;

-- The holder's address as a person setting the company up sees it: masked, the first of them.
create or replace function private.holder_masked(p_org uuid) returns text
language sql stable security definer set search_path = public, private as $$
  select private.mask_email((private.holder_emails(p_org))[1])
$$;

-- Every address of the people in the business and, for a business a firm runs, of the firm: a recovery's code never goes
-- to any of them.
create or replace function private.org_addresses(p_org uuid) returns text[]
language sql stable security definer set search_path = public, private as $$
  select coalesce(array_agg(distinct e) filter (where e is not null), '{}') from (
    select private.clean_email(coalesce(u.email, m.email)) as e from members m left join auth.users u on u.id = m.user_id
    where m.org_id = p_org and m.status in ('active', 'invited')
    union all select private.clean_email(o.email) from orgs o where o.id = p_org
    union all select unnest(private.holder_emails(p_org))
    union all select unnest(case when o.managed_by is not null then private.firm_addresses(o.id) else '{}'::text[] end) from orgs o where o.id = p_org) x
$$;

-- The draft profile's company and who holds it on Counta, for the person setting it up: {name, masked_email, yours} or
-- null. (yours: the person already runs that business.)
create or replace function private.kyc_taken(k public.kyc_profiles) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare x jsonb; h public.orgs;
begin
  if k.id is null or k.status <> 'draft' or k.for_business then return null; end if;
  x := private.kyc_ids(k);
  h := private.reg_holder(x->>'reg', x->>'tin', k.org_id);
  if h.id is null then return null; end if;
  return jsonb_build_object('name', h.name, 'masked_email', private.holder_masked(h.id),
    'yours', private.acts_as_owner(h.id, k.user_id),
    'recovery_id', (select r.id from account_recoveries r where r.org_id = h.id and r.user_id = k.user_id
                    and r.status in ('started', 'review', 'verified', 'handover_sent', 'disputed') order by r.created_at desc limit 1));
end $$;

-- ---------------------------------------------------------------------------
-- 2. Recoveries and support requests
-- ---------------------------------------------------------------------------
create table public.account_recoveries (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  matched_on text check (matched_on in ('rc_number', 'tax_id')),
  -- The company's CAC record as the person found it (Counta keeps no director's contacts in it), to match their NIN with.
  cac jsonb check (cac is null or jsonb_typeof(cac) = 'object'),
  -- started: the person is proving who they are; review: TaxStreem checks them first; verified: the holder has 30
  -- minutes to start the handover; handover_sent: the link is with the person; completed; disputed: the holder said no,
  -- TaxStreem decides; rejected by TaxStreem; cancelled by the person.
  status text not null default 'started'
    check (status in ('started', 'review', 'verified', 'handover_sent', 'completed', 'disputed', 'rejected', 'cancelled')),
  review_reason text check (review_reason in ('no_nin_phone', 'sms_not_ready', 'another_recovery')),
  nin_day date,
  nin_tries int not null default 0,
  check_id uuid references public.identity_checks(id) on delete set null,
  matched_name text check (length(matched_name) <= 160),
  matched_role text check (matched_role in ('director', 'owner')),
  nin_last4 text check (nin_last4 ~ '^[0-9]{4}$'),
  verified_at timestamptz,
  handover_due timestamptz,
  owner_told_at timestamptz,
  token_hash text,
  token_expires timestamptz,
  handover_by uuid references auth.users(id) on delete set null,
  handover_at timestamptz,
  dispute_reason text check (length(dispute_reason) <= 500),
  completed_at timestamptz,
  previous jsonb not null default '{}' check (jsonb_typeof(previous) = 'object'),
  decided_by uuid references auth.users(id) on delete set null,
  decided_at timestamptz,
  decision_note text check (length(decision_note) <= 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index account_recoveries_open on public.account_recoveries(org_id, user_id)
  where status in ('started', 'review', 'verified', 'handover_sent', 'disputed');
-- One at a time holds the business (its payments paused).
create unique index account_recoveries_live on public.account_recoveries(org_id) where status in ('verified', 'handover_sent', 'disputed');
create index account_recoveries_user on public.account_recoveries(user_id, created_at desc);
create index account_recoveries_token on public.account_recoveries(token_hash) where token_hash is not null;
create index account_recoveries_check on public.account_recoveries(check_id) where check_id is not null;
create index account_recoveries_handover_by on public.account_recoveries(handover_by) where handover_by is not null;
create index account_recoveries_decided_by on public.account_recoveries(decided_by) where decided_by is not null;
alter table public.account_recoveries enable row level security;
revoke all on public.account_recoveries from anon, authenticated;

create table public.support_cases (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('recovery_waiting', 'recovery_no_access', 'recovery_dispute', 'other')),
  user_id uuid references auth.users(id) on delete set null,
  org_id uuid references public.orgs(id) on delete set null,
  recovery_id uuid references public.account_recoveries(id) on delete set null,
  message text check (length(message) <= 2000),
  contact_email text check (length(contact_email) <= 254),
  status text not null default 'open' check (status in ('open', 'closed')),
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  closed_by uuid references auth.users(id) on delete set null,
  close_note text check (length(close_note) <= 1000)
);
create index support_cases_open on public.support_cases(created_at) where status = 'open';
create index support_cases_user on public.support_cases(user_id, created_at desc);
create index support_cases_org on public.support_cases(org_id) where org_id is not null;
create index support_cases_recovery on public.support_cases(recovery_id) where recovery_id is not null;
create index support_cases_closed_by on public.support_cases(closed_by) where closed_by is not null;
alter table public.support_cases enable row level security;
revoke all on public.support_cases from anon, authenticated;

-- A recovery as the person recovering sees it (p_holder false) or as the holder does (true).
create or replace function private.recovery_json(r public.account_recoveries, p_holder boolean) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; k public.identity_checks; v_name text; v_email text; s public.support_cases;
begin
  select * into o from orgs where id = r.org_id;
  if r.check_id is not null then select * into k from identity_checks where id = r.check_id; end if;
  select coalesce(nullif(btrim(raw_user_meta_data->>'full_name'), ''), split_part(email, '@', 1)), email into v_name, v_email
  from auth.users where id = r.user_id;
  -- The person sees their own request; the holder (and TaxStreem) the latest one.
  select * into s from support_cases where recovery_id = r.id and (p_holder or user_id = r.user_id) order by created_at desc limit 1;
  return jsonb_build_object('id', r.id, 'status', r.status, 'business', o.name, 'created_at', r.created_at,
    'matched_name', r.matched_name, 'matched_role', r.matched_role, 'verified_at', r.verified_at, 'handover_due', r.handover_due,
    'handover_at', r.handover_at, 'completed_at', r.completed_at, 'review_reason', r.review_reason, 'dispute_reason', r.dispute_reason,
    'decision_note', case when r.status in ('rejected', 'completed') then r.decision_note end,
    'support', case when s.id is not null then jsonb_build_object('id', s.id, 'status', s.status, 'kind', s.kind, 'at', s.created_at) end)
  || case when p_holder then jsonb_build_object('claimant', jsonb_build_object('name', v_name, 'email', private.mask_email(v_email)))
     else jsonb_build_object('holder_email', private.holder_masked(r.org_id),
       'step', case when r.status <> 'started' then null
         when k.id is null or k.status <> 'open' or (k.route <> 'slip' and k.sms_to is null and k.email_to is null) then 'nin'
         when k.route = 'slip' then 'support' else 'code' end,
       'route', case when k.status = 'open' then k.route end,
       'sms', case when k.status = 'open' then k.sms_masked end, 'email', case when k.status = 'open' then k.email_masked end,
       -- The person may ask TaxStreem's support while they cannot get the code, after the holder's 30 minutes, or once the
       -- holder said no.
       'support_open', r.status in ('started', 'disputed')
         or (r.status in ('verified', 'handover_sent') and r.handover_due <= now())) end;
end $$;

-- The person setting up a business found it on Counta: their recovery of it starts (or the one open goes on).
create or replace function public.recovery_start() returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid(); k public.kyc_profiles; x jsonb; v_reg text; h public.orgs; r public.account_recoveries;
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  select * into k from kyc_profiles where user_id = v_uid and status = 'draft' and not for_business;
  if k.id is null or (k.cac is null and k.manual is null) then raise exception 'Find the business on CAC first.'; end if;
  x := private.kyc_ids(k);
  v_reg := x->>'reg';
  h := private.reg_holder(v_reg, x->>'tin', k.org_id);
  if h.id is null then raise exception 'This business is not on Counta yet. Carry on setting it up.'; end if;
  if private.acts_as_owner(h.id, v_uid) then raise exception 'You run this business on Counta already. Open it from the list of your businesses.'; end if;
  -- The directors are matched on the CAC record the person found, so it must be the record of the business on Counta: the
  -- same registration number. A business found by its Tax ID alone is for TaxStreem's support.
  if k.cac is null or private.norm_id(v_reg) is null
     or not private.same_reg(private.org_reg(h.rc_number, h.legal_form), v_reg) then
    raise exception 'This business is recovered with the CAC record of its registration number. Ask TaxStreem''s support for help.';
  end if;
  select * into r from account_recoveries where org_id = h.id and user_id = v_uid
    and status in ('started', 'review', 'verified', 'handover_sent', 'disputed');
  if r.id is null then
    if (select count(*) from account_recoveries where user_id = v_uid and created_at > now() - interval '1 day') >= 3 then
      raise exception 'That is three recoveries today. Try again tomorrow, or ask TaxStreem''s support for help.';
    end if;
    insert into account_recoveries (org_id, user_id, matched_on, cac) values (h.id, v_uid, 'rc_number', k.cac) returning * into r;
  end if;
  return private.recovery_json(r, false);
end $$;

-- The person's recovery (theirs only).
create or replace function public.recovery_get(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare r public.account_recoveries;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  select * into r from account_recoveries where id = p_id and user_id = auth.uid();
  if r.id is null then raise exception 'Recovery not found.'; end if;
  return private.recovery_json(r, false);
end $$;

-- Before the person's NIN is looked up (the mono function asks as them): theirs, still being proved, three a Lagos day.
-- {cac_id, classification, tries_left}.
create or replace function public.recovery_nin_begin(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.account_recoveries; v_today date := (now() at time zone 'Africa/Lagos')::date; v_tries int;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  select * into r from account_recoveries where id = p_id and user_id = auth.uid() for update;
  if r.id is null then raise exception 'Recovery not found.'; end if;
  if r.status <> 'started' then raise exception 'Your identity is checked already for this recovery.'; end if;
  v_tries := case when r.nin_day = v_today then r.nin_tries else 0 end;
  if v_tries >= 3 then raise exception 'That is three NIN checks today. Try again tomorrow, or ask TaxStreem''s support for help.'; end if;
  if coalesce(r.cac->>'cac_id', '') = '' then raise exception 'Find the business on CAC again.'; end if;
  update account_recoveries set nin_day = v_today, nin_tries = v_tries + 1, updated_at = now() where id = r.id;
  return jsonb_build_object('cac_id', r.cac->>'cac_id', 'classification', r.cac->'profile'->>'classification', 'tries_left', 2 - v_tries);
end $$;

-- The NIN's record and the directors' contacts (the mono function). As for a director's confirmation: the names must match a
-- director (or proprietor) on the CAC record; the code never goes to an address of the business's people or its firm.
-- Answers the recovery as the person sees it, or {ok: false, reason: 'no_match'}.
create or replace function public.svc_recovery_identity(p_user uuid, p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.account_recoveries; v_match jsonb; v_contact jsonb; v_email text; v_avoid jsonb := '{}'; k public.identity_checks; x jsonb;
begin
  select * into r from account_recoveries where id = p_id and user_id = p_user for update;
  if r.id is null then raise exception 'Recovery not found.'; end if;
  if r.status <> 'started' then raise exception 'Your identity is checked already for this recovery.'; end if;
  v_match := private.identity_match(p->>'first', p->>'middle', p->>'last', private.cac_people(r.cac));
  if v_match is null then return jsonb_build_object('ok', false, 'reason', 'no_match'); end if;
  v_contact := private.identity_match(p->>'first', p->>'middle', p->>'last', case when jsonb_typeof(p->'cac') = 'array' then p->'cac' else '[]'::jsonb end);
  v_email := private.clean_email(v_contact->>'email');
  if v_email is not null and v_email = any (private.org_addresses(r.org_id)) then v_avoid := jsonb_build_object(v_email, 'holder_address'); end if;
  k := private.identity_check_new('recovery', r.id, r.org_id, jsonb_build_object('matched_name', v_match->>'name', 'matched_role', v_match->>'role',
    'last4', p->>'last4', 'nin_phone', p->>'nin_phone', 'cac_email', v_email, 'cac_phone', v_contact->>'phone', 'avoid_emails', v_avoid));
  -- The CAC phone of a person in the business is no proof either.
  if k.route = 'review' and k.sms_to is not null and exists (select 1 from members m where m.org_id = r.org_id and private.sms_phone(m.phone) = k.sms_to) then
    update identity_checks set sms_to = null, sms_masked = null, skipped = skipped || '{"sms": "holder_phone"}',
      route = case when email_to is null then 'slip' else route end, why = case when email_to is null then 'no_channel' else why end
    where id = k.id returning * into k;
  end if;
  update account_recoveries set check_id = k.id, matched_name = k.matched_name, matched_role = k.matched_role, nin_last4 = k.nin_last4, updated_at = now()
  where id = r.id returning * into r;
  if k.route <> 'slip' then
    x := private.identity_send(k.id);
    if not (x->>'ok')::boolean then return jsonb_build_object('ok', false, 'reason', x->>'reason'); end if;
  end if;
  return jsonb_build_object('ok', true) || private.recovery_json(r, false);
end $$;

-- The code again (five a Lagos day).
create or replace function public.recovery_code(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.account_recoveries; x jsonb;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  select * into r from account_recoveries where id = p_id and user_id = auth.uid();
  if r.id is null then raise exception 'Recovery not found.'; end if;
  if r.status <> 'started' or r.check_id is null then raise exception 'Enter your NIN first.'; end if;
  x := private.identity_send(r.check_id);
  if not (x->>'ok')::boolean then
    raise exception '%', case x->>'reason' when 'too_many_today' then 'That is five codes today. Try again tomorrow.'
      when 'locked' then 'Too many wrong codes were entered. Ask TaxStreem''s support for help.' else 'Enter your NIN again for a new code.' end;
  end if;
  return x;
end $$;

-- Tells the holder (email, and the bell for the owner or the firm's leads) that a director proved who they are.
create or replace function private.recovery_tell_holder(r public.account_recoveries) returns void
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; u uuid;
begin
  select * into o from orgs where id = r.org_id;
  perform private.identity_mail('recovery_owner', r.id);
  if o.managed_by is not null then
    perform private.practice_notify(o.managed_by, 'A director asked to take over ' || o.name,
      'They proved with their NIN that they are a director on its CAC record. Hand the business over within 30 minutes, or say why not.', '/practice/clients');
  else
    for u in select user_id from members where org_id = o.id and role = 'owner' and status = 'active' and user_id is not null loop
      perform private.notify(o.id, u, 'security', 'A director asked to take over ' || o.name,
        'They proved with their NIN that they are a director on its CAC record. Hand the business over within 30 minutes, or say why not.',
        '/settings#ownership', 'recovery-' || r.id);
    end loop;
  end if;
  update account_recoveries set owner_told_at = now() where id = r.id;
  perform private.activity_event(o.id, 'recovery_verified', 'A director proved who they are and asked to take the business over',
    jsonb_build_object('recovery_id', r.id));
end $$;

-- The person enters the code. Through the NIN's phone: the holder is told and has 30 minutes; the business's payments
-- pause. Otherwise (or while another director's recovery holds the business) TaxStreem checks first.
create or replace function public.recovery_verify(p_id uuid, p_code text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.account_recoveries; x jsonb; k public.identity_checks; v_reason text;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  select * into r from account_recoveries where id = p_id and user_id = auth.uid() for update;
  if r.id is null then raise exception 'Recovery not found.'; end if;
  if r.status <> 'started' or r.check_id is null then raise exception 'Enter your NIN first.'; end if;
  x := private.identity_verify(r.check_id, p_code);
  if not (x->>'ok')::boolean then
    return jsonb_build_object('ok', false, 'reason', x->>'reason', 'tries_left', (x->>'tries_left')::int, 'locked', (x->>'locked')::boolean);
  end if;
  select * into k from identity_checks where id = r.check_id;
  v_reason := case when k.route = 'review' then k.why
    when exists (select 1 from account_recoveries z where z.org_id = r.org_id and z.id <> r.id and z.status in ('verified', 'handover_sent', 'disputed'))
      then 'another_recovery' end;
  if v_reason is not null then
    update account_recoveries set status = 'review', review_reason = v_reason, verified_at = now(), updated_at = now() where id = r.id returning * into r;
    perform private.identity_mail('recovery_admin', r.id);
  else
    update account_recoveries set status = 'verified', verified_at = now(), handover_due = now() + interval '30 minutes', updated_at = now()
    where id = r.id returning * into r;
    perform private.recovery_tell_holder(r);
  end if;
  return jsonb_build_object('ok', true) || private.recovery_json(r, false);
end $$;

-- The person stops their recovery.
create or replace function public.recovery_cancel(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.account_recoveries;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  select * into r from account_recoveries where id = p_id and user_id = auth.uid() for update;
  if r.id is null then raise exception 'Recovery not found.'; end if;
  if r.status not in ('started', 'review', 'verified', 'handover_sent', 'disputed') then raise exception 'This recovery is closed already.'; end if;
  perform private.identity_close(r.id);
  update account_recoveries set status = 'cancelled', token_hash = null, token_expires = null, updated_at = now() where id = r.id returning * into r;
  if r.owner_told_at is not null then
    perform private.activity_event(r.org_id, 'recovery_cancelled', 'The director stopped their request to take the business over',
      jsonb_build_object('recovery_id', r.id));
  end if;
  return private.recovery_json(r, false);
end $$;

-- The holder's side: may this person answer for the business (its owner, or a partner or manager of the firm that runs it)?
create or replace function private.holder_require(p_org uuid) returns void
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  select * into o from orgs where id = p_org;
  if o.id is null then raise exception 'Business not found.'; end if;
  if o.managed_by is not null then
    perform private.practice_require(o.managed_by, true);
  elsif not exists (select 1 from members where org_id = p_org and user_id = auth.uid() and role = 'owner' and status = 'active') then
    raise exception 'Only the owner answers for the business.' using errcode = '42501';
  end if;
end $$;

-- The recovery holding the business, for its holder; null when there is none.
create or replace function public.recovery_for_org(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare r public.account_recoveries;
begin
  perform private.holder_require(p_org);
  select * into r from account_recoveries where org_id = p_org and status in ('verified', 'handover_sent', 'disputed') limit 1;
  if r.id is null then return null; end if;
  return private.recovery_json(r, true);
end $$;

-- The holder hands the business over: the person gets an email with a link (7 days) to take it.
create or replace function public.recovery_handover_start(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.account_recoveries;
begin
  select * into r from account_recoveries where id = p_id for update;
  if r.id is null then raise exception 'Recovery not found.'; end if;
  perform private.holder_require(r.org_id);
  if r.status not in ('verified', 'handover_sent') then raise exception 'This request is not waiting for a handover.'; end if;
  update account_recoveries set status = 'handover_sent', handover_by = coalesce(handover_by, auth.uid()), handover_at = coalesce(handover_at, now()),
    updated_at = now()
  where id = r.id returning * into r;
  perform private.identity_mail('recovery_handover', r.id);
  perform private.notify(null, r.user_id, 'security', 'The business is ready for you',
    'The holder handed it over. Open the link in your email to take it.', '/recover/' || r.id, 'recovery-handover-' || r.id);
  perform private.activity_event(r.org_id, 'recovery_handover', 'The business was handed over to the director who asked for it',
    jsonb_build_object('recovery_id', r.id));
  return private.recovery_json(r, true);
end $$;

-- The holder says no (with a reason): TaxStreem decides, and payments stay paused until it has.
create or replace function public.recovery_dispute(p_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.account_recoveries; v_reason text := nullif(left(btrim(coalesce(p_reason, '')), 500), ''); s uuid;
begin
  select * into r from account_recoveries where id = p_id for update;
  if r.id is null then raise exception 'Recovery not found.'; end if;
  perform private.holder_require(r.org_id);
  if r.status not in ('verified', 'handover_sent') then raise exception 'This request is not waiting for a handover.'; end if;
  if v_reason is null or length(v_reason) < 10 then raise exception 'Say why, in at least 10 characters. TaxStreem reads it before it decides.'; end if;
  update account_recoveries set status = 'disputed', dispute_reason = v_reason, token_hash = null, token_expires = null, updated_at = now()
  where id = r.id returning * into r;
  insert into support_cases (kind, user_id, org_id, recovery_id, message, contact_email)
  values ('recovery_dispute', auth.uid(), r.org_id, r.id, v_reason, (select email from auth.users where id = auth.uid()))
  returning id into s;
  perform private.identity_mail('support_case', s);
  perform private.notify(null, r.user_id, 'security', 'The holder of the business said no',
    'TaxStreem will look at your request and write to you.', '/recover/' || r.id, 'recovery-dispute-' || r.id);
  perform private.activity_event(r.org_id, 'recovery_disputed', 'The request to take the business over was disputed; TaxStreem decides',
    jsonb_build_object('recovery_id', r.id));
  return private.recovery_json(r, true);
end $$;

-- The business moves to the person recovering it: they become its owner, the previous owner's place ends, and a firm that
-- ran it leaves with its places. Their own login is untouched. p_note: TaxStreem's note when an admin hands it over.
create or replace function private.recovery_transfer(p_id uuid, p_note text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.account_recoveries; o public.orgs; c public.practice_clients; ex public.members; v_member uuid; v_email text; v_name text;
  v_prev text := coalesce(current_setting('counta.seat_sync', true), ''); v_previous jsonb;
begin
  select * into r from account_recoveries where id = p_id for update;
  select * into o from orgs where id = r.org_id for update;
  select lower(btrim(email)), coalesce(nullif(btrim(raw_user_meta_data->>'full_name'), ''), split_part(email, '@', 1)) into v_email, v_name
  from auth.users where id = r.user_id;
  if v_email is null then raise exception 'The person recovering the business no longer has a login.'; end if;
  v_previous := jsonb_build_object('owners', (select coalesce(jsonb_agg(jsonb_build_object('member_id', m.id, 'name', m.display_name,
      'email', coalesce(u.email, m.email))), '[]'::jsonb)
    from members m left join auth.users u on u.id = m.user_id where m.org_id = o.id and m.role = 'owner' and m.status = 'active'),
    'practice_id', o.managed_by, 'emails', to_jsonb(private.holder_emails(o.id)));
  perform set_config('counta.seat_sync', 'on', true);
  if o.managed_by is not null then
    c := private.mandate(o.id);
    update orgs set managed_by = null where id = o.id;
    update practice_handovers set status = 'cancelled', token_hash = null, token_expires = null where client_id = c.id and status = 'pending';
    perform private.identity_close(d.id) from practice_director_confirmations d where d.client_id = c.id and d.status in ('pending', 'review');
    update practice_director_confirmations set status = 'cancelled', token_hash = null, token_expires = null, otp_hash = null, otp_expires = null
    where client_id = c.id and status in ('pending', 'review');
    update practice_clients set status = 'ended', end_kind = 'handover', ended_at = coalesce(ended_at, now()), ended_by = r.user_id where id = c.id and status = 'active';
    -- The firm stops paying for the plan at the end of its period, as when any engagement ends.
    update subscriptions set cancel_at_period_end = true, updated_at = now() where org_id = o.id and paid_by = c.practice_id;
    perform private.practice_sync_seats(c.id);
    perform private.practice_notify(c.practice_id, o.name || ' was taken over by its director',
      left(v_name, 80) || ' proved with their NIN that they are a director on its CAC record and took the business over. The firm''s places in it have ended.',
      '/practice/clients');
  end if;
  -- The previous owner's place is switched off, its permissions with it in the same statement (members_sales_cannot_edit).
  update members set status = 'disabled', role = 'staff', title = 'Former owner', acts_as_owner = false, perm_overrides = '{}'::jsonb,
    p_record_sales = false, p_receive_stock = false, p_count_stock = false, p_approve_adjustments = false, p_edit_prices = false,
    p_approve_pos = false, p_transfer_stock = false, p_see_margins = false, p_issue_stock = false, p_keep_books = false,
    p_make_payments = false, p_add_items = false, p_approve_payments = false, p_file_tax = false, p_manage_team = false, p_manage_settings = false
  where org_id = o.id and role = 'owner' and user_id is distinct from r.user_id;
  select * into ex from members where org_id = o.id and (user_id = r.user_id or (user_id is null and lower(email) = v_email))
  order by (user_id = r.user_id) desc nulls last limit 1;
  if ex.id is null then
    insert into members (org_id, user_id, email, display_name, role, title, status)
    values (o.id, r.user_id, v_email, left(v_name, 120), 'owner', 'Owner', 'active')
    returning id into v_member;
  else
    update members set user_id = r.user_id, email = v_email, role = 'owner', title = 'Owner', status = 'active', practice_id = null, acts_as_owner = false,
      perm_overrides = '{}'::jsonb
    where id = ex.id;
    v_member := ex.id;
  end if;
  perform private.apply_member_perms(v_member);
  perform set_config('counta.seat_sync', v_prev, true);
  update orgs set identity_status = 'verified',
    identity = (identity - 'review' - 'reason' - 'handover') || jsonb_build_object('method', 'recovery', 'matched', r.matched_name,
      'matched_role', coalesce(r.matched_role, 'director'), 'last4', r.nin_last4, 'at', now(), 'by', r.user_id, 'recovery_id', r.id)
  where id = o.id;
  update account_recoveries set status = 'completed', completed_at = now(), token_hash = null, token_expires = null, previous = v_previous,
    decision_note = coalesce(nullif(btrim(p_note), ''), decision_note), updated_at = now()
  where id = r.id returning * into r;
  -- The person's own draft for this company is done with: the business is theirs now.
  delete from kyc_profiles where user_id = r.user_id and status = 'draft' and not for_business and org_id is null;
  insert into guide_progress (user_id, org_id) values (r.user_id, o.id) on conflict (user_id) do update set org_id = excluded.org_id, last_seen_at = now();
  perform private.activity_event(o.id, 'recovered', 'Taken over by ' || left(v_name, 80) || ', a director on the CAC record',
    jsonb_build_object('recovery_id', r.id));
  perform private.identity_mail('recovery_done', r.id);
  return jsonb_build_object('org_id', o.id, 'recovery', private.recovery_json(r, false));
end $$;

-- The person opens the handover link, signed in with the login that asked, and takes the business.
create or replace function public.recovery_accept(p_token text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.account_recoveries; v_confirmed timestamptz;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if coalesce(p_token, '') ~ '^rh_[0-9a-f]{48}$' then
    select * into r from account_recoveries where token_hash = private.sha256_hex(p_token) for update;
  end if;
  if r.id is null then raise exception 'That link is not valid. Ask the holder of the business to hand it over again.'; end if;
  if r.user_id <> auth.uid() then raise exception 'This link is for the person who asked to recover the business. Sign in with that login.'; end if;
  if r.status <> 'handover_sent' then raise exception 'This handover is no longer open.'; end if;
  if r.token_expires is null or r.token_expires <= now() then raise exception 'This link has expired. Ask the holder of the business to hand it over again.'; end if;
  select email_confirmed_at into v_confirmed from auth.users where id = auth.uid();
  if v_confirmed is null then raise exception 'Confirm your email address first, then open the link again.' using errcode = '42501'; end if;
  return private.recovery_transfer(r.id, null);
end $$;

-- A request for TaxStreem's support from the app. p: {kind, recovery_id (optional), message}. Three a day.
create or replace function public.support_request(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid(); v_kind text; v_msg text; r public.account_recoveries; s public.support_cases;
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if jsonb_typeof(p) is distinct from 'object' then raise exception 'Say what you need help with.'; end if;
  v_kind := coalesce(nullif(p->>'kind', ''), 'other');
  if v_kind not in ('recovery_waiting', 'recovery_no_access', 'other') then raise exception 'Choose what the request is about.'; end if;
  v_msg := nullif(left(btrim(coalesce(p->>'message', '')), 2000), '');
  if nullif(p->>'recovery_id', '') is not null then
    select * into r from account_recoveries where id = private.uuid_of(p->>'recovery_id') and user_id = v_uid;
    if r.id is null then raise exception 'Recovery not found.'; end if;
  elsif v_kind <> 'other' then
    raise exception 'Choose the recovery the request is about.';
  end if;
  if v_kind = 'other' and coalesce(length(v_msg), 0) < 10 then raise exception 'Say what you need help with, in at least 10 characters.'; end if;
  if (select count(*) from support_cases where user_id = v_uid and created_at > now() - interval '1 day') >= 3 then
    raise exception 'That is three requests today. TaxStreem will answer the ones you sent.';
  end if;
  if r.id is not null and exists (select 1 from support_cases where recovery_id = r.id and status = 'open' and user_id = v_uid) then
    raise exception 'TaxStreem has your request about this already, and will write to you.';
  end if;
  insert into support_cases (kind, user_id, org_id, recovery_id, message, contact_email)
  values (v_kind, v_uid, r.org_id, r.id, v_msg, (select email from auth.users where id = v_uid))
  returning * into s;
  perform private.identity_mail('support_case', s.id);
  return jsonb_build_object('id', s.id, 'status', s.status, 'created_at', s.created_at);
end $$;

-- ---------------------------------------------------------------------------
-- 3. TaxStreem's side
-- ---------------------------------------------------------------------------
create or replace function public.admin_recoveries() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_staff(false);
  return jsonb_build_object(
    'recoveries', (select coalesce(jsonb_agg(private.recovery_json(r, true) || jsonb_build_object('org_id', r.org_id, 'matched_on', r.matched_on,
        'nin_last4', r.nin_last4, 'claimant_email', u.email, 'holder_emails', to_jsonb(private.holder_emails(r.org_id)),
        'code_went', (select jsonb_build_object('sms', k.sms_masked, 'email', k.email_masked, 'route', k.route, 'why', k.why, 'skipped', k.skipped)
                      from identity_checks k where k.id = r.check_id)) order by r.created_at desc), '[]'::jsonb)
      from account_recoveries r left join auth.users u on u.id = r.user_id
      where r.status in ('review', 'verified', 'handover_sent', 'disputed')
         or (r.status in ('started', 'completed', 'rejected', 'cancelled') and r.updated_at > now() - interval '30 days')),
    'cases', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'kind', s.kind, 'status', s.status, 'message', s.message,
        'contact_email', s.contact_email, 'created_at', s.created_at, 'closed_at', s.closed_at, 'close_note', s.close_note,
        'business', (select name from orgs where id = s.org_id), 'recovery_id', s.recovery_id) order by s.status = 'open' desc, s.created_at desc), '[]'::jsonb)
      from support_cases s where s.status = 'open' or s.created_at > now() - interval '30 days'));
end $$;

-- TaxStreem decides: approve (a recovery it checks: the holder is told and has 30 minutes), reject (payments open again),
-- or transfer (an admin hands the business to the person now, for a holder who did not answer or a dispute decided for
-- the person). Every decision takes a note.
create or replace function public.admin_recovery_decide(p_id uuid, p_action text, p_note text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.account_recoveries; v_note text := btrim(coalesce(p_note, '')); x jsonb;
begin
  perform private.require_staff(p_action = 'transfer');
  if length(v_note) < 5 then raise exception 'Write a note of at least 5 characters.'; end if;
  if length(v_note) > 1000 then raise exception 'Keep the note under 1,000 characters.'; end if;
  select * into r from account_recoveries where id = p_id for update;
  if r.id is null then raise exception 'Recovery not found.'; end if;
  if p_action = 'approve' then
    if r.status <> 'review' then raise exception 'Only a recovery waiting for TaxStreem''s check is approved.'; end if;
    if exists (select 1 from account_recoveries z where z.org_id = r.org_id and z.id <> r.id and z.status in ('verified', 'handover_sent', 'disputed')) then
      raise exception 'Another director''s recovery holds this business. Decide that one first.';
    end if;
    update account_recoveries set status = 'verified', handover_due = now() + interval '30 minutes', decided_by = auth.uid(), decided_at = now(),
      decision_note = v_note, updated_at = now()
    where id = r.id returning * into r;
    perform private.recovery_tell_holder(r);
  elsif p_action = 'reject' then
    if r.status not in ('started', 'review', 'verified', 'handover_sent', 'disputed') then raise exception 'This recovery is closed already.'; end if;
    perform private.identity_close(r.id);
    update account_recoveries set status = 'rejected', token_hash = null, token_expires = null, decided_by = auth.uid(), decided_at = now(),
      decision_note = v_note, updated_at = now()
    where id = r.id returning * into r;
    perform private.notify(null, r.user_id, 'security', 'TaxStreem did not approve your recovery', left(v_note, 300), '/recover/' || r.id, null);
    perform private.activity_event(r.org_id, 'recovery_rejected', 'TaxStreem did not approve a request to take the business over',
      jsonb_build_object('recovery_id', r.id));
  elsif p_action = 'transfer' then
    if r.status not in ('verified', 'handover_sent', 'disputed') then
      raise exception 'Only a recovery whose director proved who they are can be handed over.';
    end if;
    update account_recoveries set decided_by = auth.uid(), decided_at = now(), updated_at = now() where id = r.id;
    x := private.recovery_transfer(r.id, v_note);
    perform private.audit('recovery_transfer', r.id::text, jsonb_build_object('org_id', r.org_id, 'user_id', r.user_id, 'note', v_note));
    update support_cases set status = 'closed', closed_at = now(), closed_by = auth.uid(), close_note = v_note where recovery_id = r.id and status = 'open';
    select * into r from account_recoveries where id = p_id;
  else
    raise exception 'Choose approve, reject or transfer.';
  end if;
  perform private.audit('recovery_' || p_action, r.id::text, jsonb_build_object('org_id', r.org_id, 'note', v_note));
  return private.recovery_json(r, true);
end $$;

create or replace function public.admin_support_close(p_id uuid, p_note text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.support_cases; v_note text := btrim(coalesce(p_note, ''));
begin
  perform private.require_staff(false);
  if length(v_note) < 5 then raise exception 'Write a note of at least 5 characters.'; end if;
  update support_cases set status = 'closed', closed_at = now(), closed_by = auth.uid(), close_note = left(v_note, 1000)
  where id = p_id and status = 'open' returning * into s;
  if s.id is null then raise exception 'Request not found, or closed already.'; end if;
  perform private.audit('support_close', s.id::text, jsonb_build_object('note', v_note));
  return jsonb_build_object('id', s.id, 'status', s.status);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Payments pause while a director's recovery holds the business
-- ---------------------------------------------------------------------------
-- Latest definition (20261124000900_mandate_end_handover.sql); and no recovery is waiting on the holder.
create or replace function private.payments_open(p_org uuid) returns boolean
language sql stable security definer set search_path = public, private as $$
  select coalesce((select identity_status in ('not_required', 'verified', 'approved') and read_only_at is null
      and (managed_by is null or (director_confirmed_at is not null and private.practice_can_full(managed_by)))
      and not exists (select 1 from account_recoveries r where r.org_id = o.id and r.status in ('verified', 'handover_sent', 'disputed'))
    from orgs o where o.id = p_org), false)
$$;


-- Latest definition (20261124000900_mandate_end_handover.sql); refused while a director's recovery holds the business.
create or replace function private.require_payments_open(p_org uuid) returns void
language plpgsql stable security definer set search_path = public, private as $$
declare v_status text; v_managed uuid; v_confirmed timestamptz; v_read_only timestamptz; v_identity jsonb;
begin
  if not private.feature_on(p_org, 'payments') then
    raise exception 'TaxStreem has paused payments for this business for now. The books still work; contact TaxStreem to find out more.' using errcode = '42501';
  end if;
  select identity_status, managed_by, director_confirmed_at, read_only_at, identity into v_status, v_managed, v_confirmed, v_read_only, v_identity
  from orgs where id = p_org;
  if v_read_only is not null then
    raise exception 'This business is read-only: its engagement has ended. Payments are closed.' using errcode = '42501';
  end if;
  if exists (select 1 from account_recoveries r where r.org_id = p_org and r.status in ('verified', 'handover_sent', 'disputed')) then
    raise exception 'Payments are paused: a director of the business asked to take it over on Counta, and no money leaves its wallets until that is settled.'
      using errcode = '42501';
  end if;
  if v_status in ('not_required', 'verified', 'approved') then
    if v_managed is null or (v_confirmed is not null and private.practice_can_full(v_managed)) then return; end if;
    raise exception 'Payments open once a director of the business confirms, and while the firm may run full mandates.' using errcode = '42501';
  end if;
  if private.handover_pending(v_status, v_identity) then raise exception '%', private.handover_pending_text(v_status) using errcode = '42501'; end if;
  raise exception '%', case v_status
    when 'review' then 'Payments open once TaxStreem has checked the NIN slip. This usually takes a working day.'
    when 'rejected' then 'Payments are locked: TaxStreem could not confirm a director''s identity. A director can do the NIN check in Settings.'
    else 'Payments open once a director confirms their NIN. Do the NIN check in Settings, Business identity, or ask Martina.' end
    using errcode = '42501';
end $$;

-- ---------------------------------------------------------------------------
-- 5. What the messaging function sends
-- ---------------------------------------------------------------------------
-- Latest definition (20261125000100_director_identity.sql), with the recovery's code (from Counta), the holder told, the
-- handover link, the previous owner told, TaxStreem's reviewers asked to check one, and a support request.
create or replace function public.svc_identity_mail(p_kind text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.identity_checks; d public.practice_director_confirmations; r public.account_recoveries; s public.support_cases; o public.orgs;
  t jsonb; v_firm text; v_business text; v_reply text; v_app text; v_name text; v_email text; v_support text;
begin
  v_app := coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app');
  if p_kind = 'identity_code' then
    select * into c from identity_checks where id = p_id for update;
    if c.id is null or c.status <> 'open' or c.route = 'slip' or (c.sms_to is null and c.email_to is null)
       or c.locked_at is not null or c.otp_failures >= 15 then
      return null;
    end if;
    if c.purpose = 'director_confirm' then
      select * into d from practice_director_confirmations where id = c.ref_id;
      if d.id is null or d.status <> 'pending' or d.check_id is distinct from c.id or not private.director_mandate_open(d.client_id, d.practice_id) then
        return null;
      end if;
      select name into v_firm from practices where id = d.practice_id;
      select o2.name into v_business from practice_clients pc join orgs o2 on o2.id = pc.org_id where pc.id = d.client_id;
      v_reply := coalesce((select pm.email from practice_clients pc join practice_members pm on pm.id = pc.engagement_partner_id
                           where pc.id = d.client_id and pm.status = 'active'), (select email from practices where id = d.practice_id));
      t := private.otp_new(c.id);
      update identity_checks set otp_hash = t->>'otp_hash', otp_expires = (t->>'otp_expires')::timestamptz, otp_tries = 0 where id = c.id;
      return jsonb_build_object('to', c.email_to, 'reply_to', v_reply, 'from_name', v_firm, 'org_id', c.org_id, 'purpose', c.purpose,
        'subject', 'Your code to confirm the wallets for ' || v_business,
        'heading', 'Your confirmation code',
        'greet', split_part(btrim(coalesce(c.matched_name, d.name)), ' ', 1),
        'lines', jsonb_build_array('Enter this code to answer ' || v_firm || '''s request about the wallets for ' || v_business || '. It works for ten minutes.',
          'If you did not ask for a code, you can ignore this email.'),
        'button', null, 'link', null, 'code', t->>'code', 'white_label', true,
        'sms', case when c.sms_to is not null then jsonb_build_object('to', c.sms_to,
          'text', (t->>'code') || ' is your code to confirm the wallets for ' || left(v_business, 60) || '. It expires in 10 minutes. Do not share it.') end);
    end if;
    select * into r from account_recoveries where id = c.ref_id;
    if r.id is null or r.status <> 'started' or r.check_id is distinct from c.id then return null; end if;
    select name into v_business from orgs where id = r.org_id;
    t := private.otp_new(c.id);
    update identity_checks set otp_hash = t->>'otp_hash', otp_expires = (t->>'otp_expires')::timestamptz, otp_tries = 0 where id = c.id;
    return jsonb_build_object('to', c.email_to, 'reply_to', null, 'from_name', 'Counta', 'org_id', c.org_id, 'purpose', c.purpose,
      'subject', 'Your Counta code to recover ' || v_business,
      'heading', 'Your recovery code',
      'greet', split_part(btrim(coalesce(c.matched_name, '')), ' ', 1),
      'lines', jsonb_build_array('Enter this code in Counta to prove you are a director of ' || v_business || ' and recover it. It works for ten minutes.',
        'If you did not ask to recover this business, someone may have your NIN. Ignore this email and tell TaxStreem''s support.'),
      'button', null, 'link', null, 'code', t->>'code', 'white_label', false,
      'sms', case when c.sms_to is not null then jsonb_build_object('to', c.sms_to,
        'text', (t->>'code') || ' is your Counta code to recover ' || left(v_business, 60) || '. It expires in 10 minutes. Do not share it.') end);
  end if;

  if p_kind in ('recovery_owner', 'recovery_handover', 'recovery_done', 'recovery_admin') then
    select * into r from account_recoveries where id = p_id for update;
    if r.id is null then return null; end if;
    select * into o from orgs where id = r.org_id;
    select coalesce(nullif(btrim(raw_user_meta_data->>'full_name'), ''), split_part(email, '@', 1)), email into v_name, v_email
    from auth.users where id = r.user_id;
    if p_kind = 'recovery_owner' then
      if r.status <> 'verified' then return null; end if;
      return jsonb_build_object('to', to_jsonb(private.holder_emails(o.id)), 'reply_to', null, 'from_name', 'Counta',
        'subject', 'A director asked to take over ' || o.name || ' on Counta',
        'heading', 'A director asked for the business',
        'greet', null,
        'lines', jsonb_build_array(left(v_name, 80) || ' proved with their NIN that they are a director of ' || o.name
            || ' on its CAC record, and asked to take the business over on Counta.',
          'Open Counta within 30 minutes to hand it over, or to say why it should not go to them. Until this is settled, no money leaves the business''s wallets.',
          'If you do not answer, the director may ask TaxStreem to decide.'),
        'button', 'Open Counta', 'link', v_app || case when o.managed_by is not null then '/practice/clients' else '/settings#ownership' end,
        'white_label', false);
    elsif p_kind = 'recovery_handover' then
      if r.status <> 'handover_sent' then return null; end if;
      t := private.token_new('rh');
      update account_recoveries set token_hash = t->>'hash', token_expires = now() + interval '7 days', updated_at = now() where id = r.id;
      return jsonb_build_object('to', v_email, 'reply_to', null, 'from_name', 'Counta',
        'subject', o.name || ' is ready for you on Counta',
        'heading', 'Take over the business',
        'greet', split_part(btrim(v_name), ' ', 1),
        'lines', jsonb_build_array('The business''s holder handed ' || o.name || ' over to you.',
          'Use the button while signed in with this login to take it. You become its owner and the previous owner''s place ends. The link works for seven days.'),
        'button', 'Take over the business', 'link', v_app || '/recover/accept/' || (t->>'token'), 'white_label', false);
    elsif p_kind = 'recovery_done' then
      if r.status <> 'completed' then return null; end if;
      return jsonb_build_object('to', coalesce(r.previous->'emails', '[]'::jsonb), 'reply_to', null, 'from_name', 'Counta',
        'subject', o.name || ' was taken over by its director',
        'heading', 'The business has a new owner',
        'greet', null,
        'lines', jsonb_build_array(left(v_name, 80) || ', a director of ' || o.name || ' on its CAC record, owns the business on Counta now. Your place in it has ended.',
          'If you think this is wrong, write to TaxStreem''s support.'),
        'button', null, 'link', null, 'white_label', false);
    end if;
    if r.status <> 'review' then return null; end if;
    return jsonb_build_object('to', to_jsonb(public.svc_review_recipients()), 'reply_to', null, 'from_name', 'Counta',
      'subject', 'A recovery to check: ' || o.name,
      'heading', 'A director''s recovery to check',
      'greet', null,
      'lines', jsonb_build_array('Business: ' || o.name || '.', 'Asked by: ' || left(v_name, 80) || '.',
        case r.review_reason when 'another_recovery' then 'Another director''s recovery of this business is open.'
          else 'Their NIN matched a director on the CAC record, but the code could not go to a phone on the NIN record, so Counta did not tell the holder yet.' end),
      'button', 'Open recoveries', 'link', v_app || '/admin/recoveries', 'white_label', false);
  end if;

  if p_kind = 'support_case' then
    select * into s from support_cases where id = p_id;
    if s.id is null or s.status <> 'open' then return null; end if;
    v_support := coalesce(private.clean_email(public.svc_secret('SUPPORT_EMAIL')), private.clean_email(public.svc_secret('KYC_REVIEW_EMAIL')), 'admin@taxstreem.com');
    return jsonb_build_object('to', v_support, 'reply_to', s.contact_email, 'from_name', 'Counta',
      'subject', 'Support request: ' || case s.kind when 'recovery_waiting' then 'a holder has not handed a business over'
        when 'recovery_no_access' then 'a director cannot get their recovery code' when 'recovery_dispute' then 'a recovery was disputed'
        else 'help needed' end || coalesce(' (' || (select name from orgs where id = s.org_id) || ')', ''),
      'heading', 'A support request',
      'greet', null,
      'lines', jsonb_build_array('From: ' || coalesce(s.contact_email, 'unknown') || '.',
          coalesce('Message: ' || s.message, 'No message.'), 'Reply to this email to answer them.'),
      'button', 'Open recoveries', 'link', v_app || '/admin/recoveries', 'white_label', false);
  end if;
  raise exception 'Unknown identity email: %.', p_kind;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Setting up a business: refused for a company already on Counta
-- ---------------------------------------------------------------------------
-- Latest definition (20261023000100_voices_and_guide.sql); the profile also says when its company is already on
-- Counta (taken: {name, masked_email, yours, recovery_id}).
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
    'submitted_at', k.submitted_at, 'updated_at', k.updated_at,
    'taken', private.kyc_taken(k));
end $$;

-- Latest definition (20261124001300_fixes_and_rules.sql). The ordinary path refuses any company already on Counta (not only
-- one a firm runs), with reason 'exists', the business's name and the holder's address masked.
create or replace function public.kyc_submit(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid(); k public.kyc_profiles; c jsonb; v_org uuid; v_name text; v_addr text; v_vat boolean; v_cat public.business_categories;
  v_form text; v_cls text; v_tin text; v_dir jsonb; v_display text; v_branch text; v_email text; v_state text; v_lga text; v_shares numeric;
  v_new boolean := false; v_for uuid; v_to jsonb; v_rc text; mc public.practice_clients; v_intake_rc text;
  v_dup jsonb; v_practice uuid; mo public.orgs; v_reg text;
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  v_for := private.uuid_of(p->>'org_id');
  if nullif(trim(coalesce(p->>'org_id', '')), '') is not null and v_for is null then raise exception 'Choose the business.'; end if;
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
  if k.org_id is not null and not private.is_owner(k.org_id) then
    raise exception 'Only the owner submits the business profile.' using errcode = '42501';
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
  -- The number with its registry, from the CAC classification when the number does not say (RC for a company, BN for a
  -- business name, IT for incorporated trustees), to compare it.
  v_reg := case when private.reg_kind(v_rc) is null and private.norm_id(v_rc) is not null and v_form in ('company', 'enterprise', 'ngo')
    then case v_form when 'company' then 'RC ' when 'enterprise' then 'BN ' else 'IT ' end || v_rc else v_rc end;
  if k.org_id is not null and private.is_managed(k.org_id) then
    select managed_by into v_practice from orgs where id = k.org_id;
    mc := private.mandate(k.org_id);
    select x.rc_number into v_intake_rc from practice_intakes x where x.id = mc.intake_id;
    if private.norm_id(v_rc) is not null and private.norm_id(v_intake_rc) is not null and not private.same_reg(v_reg, v_intake_rc) then
      raise exception 'This CAC record is for RC %, but the firm took this business on as RC %. Choose the right company.',
        private.norm_id(v_rc), private.norm_id(v_intake_rc);
    end if;
    v_dup := private.company_taken(v_reg, v_tin, v_practice, k.org_id);
    if v_dup is not null then
      insert into practice_mandate_flags (practice_id, intake_id, client_id, kind, detail)
      select v_practice, mc.intake_id, mc.id, 'duplicate_company', v_dup || jsonb_build_object('source', 'cac', 'business_org_id', k.org_id)
      where not exists (select 1 from practice_mandate_flags f where f.practice_id = v_practice and f.kind = 'duplicate_company' and f.resolved_at is null
                        and f.detail->>'business_org_id' = k.org_id::text);
      return jsonb_build_object('ok', false, 'reason', 'duplicate');
    end if;
  elsif private.norm_id(v_rc) is not null or v_tin is not null then
    -- A company already on Counta is not set up a second time. The person is told whose account holds it (masked), and a
    -- director recovers it (recovery_start). A firm that runs it under full mandate is also told, as before.
    mo := private.reg_holder(v_reg, v_tin, k.org_id);
    if mo.id is not null then
      if mo.managed_by is not null then
        mc := private.mandate(mo.id);
        insert into practice_mandate_flags (practice_id, intake_id, client_id, kind, detail)
        select mo.managed_by, mc.intake_id, mc.id, 'duplicate_company',
          jsonb_build_object('source', 'owner', 'matched_on', case when private.same_reg(mo.rc_number, v_reg) then 'rc_number' else 'tax_id' end,
            'business_org_id', mo.id, 'user_id', v_uid, 'email', v_email, 'name', v_name, 'org_id', k.org_id)
        where not exists (select 1 from practice_mandate_flags f where f.kind = 'duplicate_company' and f.resolved_at is null
                          and f.detail->>'source' = 'owner' and f.detail->>'business_org_id' = mo.id::text and f.detail->>'user_id' = v_uid::text);
      end if;
      return jsonb_build_object('ok', false, 'reason', 'exists', 'business', mo.name, 'masked_email', private.holder_masked(mo.id),
        'yours', private.acts_as_owner(mo.id, v_uid));
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

-- Recoveries and support requests are logged by the events they raise (recovery_verified, recovered and the rest), not row
-- by row (latest definition, 20261125000100_director_identity.sql, with both).
create or replace function private.activity_exempt() returns text[]
language sql immutable set search_path = public, private as $$
  select array['activity_log', 'messages', 'notifications', 'alert_log', 'usage_events', 'ai_logs', 'shop_hits', 'payment_events', 'org_counters',
    'stock_levels', 'agent_runs', 'guide_progress', 'lookup_failures', 'sso_logins', 'whatsapp_sessions', 'chat_links', 'voice_calls',
    'integration_events', 'prism_callbacks', 'kyc_profiles', 'practice_intakes', 'identity_checks', 'account_recoveries', 'support_cases']
$$;

-- ---------------------------------------------------------------------------
-- 7. Grants
-- ---------------------------------------------------------------------------
revoke all on function private.org_reg(text, text), private.kyc_ids(public.kyc_profiles), private.reg_holder(text, text, uuid), private.orgs_reg_unique(), private.holder_emails(uuid), private.holder_masked(uuid),
  private.org_addresses(uuid), private.kyc_taken(public.kyc_profiles), private.recovery_json(public.account_recoveries, boolean),
  private.recovery_tell_holder(public.account_recoveries), private.holder_require(uuid), private.recovery_transfer(uuid, text),
  private.activity_exempt()
  from public, anon, authenticated;
revoke execute on function public.svc_recovery_identity(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.svc_recovery_identity(uuid, uuid, jsonb) to service_role;
revoke execute on function public.recovery_start(), public.recovery_get(uuid), public.recovery_nin_begin(uuid), public.recovery_code(uuid),
  public.recovery_verify(uuid, text), public.recovery_cancel(uuid), public.recovery_for_org(uuid), public.recovery_handover_start(uuid),
  public.recovery_dispute(uuid, text), public.recovery_accept(text), public.support_request(jsonb), public.admin_recoveries(),
  public.admin_recovery_decide(uuid, text, text), public.admin_support_close(uuid, text)
  from public, anon;
grant execute on function public.recovery_start(), public.recovery_get(uuid), public.recovery_nin_begin(uuid), public.recovery_code(uuid),
  public.recovery_verify(uuid, text), public.recovery_cancel(uuid), public.recovery_for_org(uuid), public.recovery_handover_start(uuid),
  public.recovery_dispute(uuid, text), public.recovery_accept(text), public.support_request(jsonb), public.admin_recoveries(),
  public.admin_recovery_decide(uuid, text, text), public.admin_support_close(uuid, text)
  to authenticated;
