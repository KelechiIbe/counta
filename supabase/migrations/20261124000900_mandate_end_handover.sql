-- Practice management, part 9: the full mandate's end. The handover to the owner, the end without a handover, the export of
-- the business's records, deletion blocked while the records are kept, and the portal's and admin portal's reads.
--
-- Handover (practice_handovers, practice_handover_start, practice_handover_accept): a partner names the person taking the
-- business over (never one of the practice's people); the invitation email is the firm's, sent like the practice's other
-- invitations (practice_invite_check and svc_practice_invite_link, kind 'handover': a ph_ link, only its SHA-256 kept, 14
-- days, five emails a day); the person signed in with that address takes it, once: the practice no longer runs the
-- business (orgs.managed_by cleared, so silence and branding lift), they are its owner, the client is involved and
-- marked handed over, and the firm's people are ordinary accountants. Their places stay outside the plan's limit on
-- people while the firm works on the business (private.seat_exempt), as they were under full mandate.
--
-- End without a handover (practice_end_mandate): refused while either wallet holds money or a payment is moving; then the
-- business's connections are paused (private.org_pause_all), the client ends (the intake is kept by its trigger), only the
-- engagement partner's place stays, a waiting handover is cancelled, and last the business becomes read-only and kept as
-- long as the letter says (orgs.retain_until). The practice still runs it, so it stays silent. A partner can choose another
-- engagement partner for such a business, and for any active client (practice_set_engagement_partner): the place kept
-- moves with it (practice_sync_seats).
--
-- Export (practice_export_begin for a partner; svc_export_* for the practice edge function): every business table but the
-- logs, sessions and KYC (private.export_tables), each row redacted, paged by its primary key; the ledger; the activity
-- log; the finished file logged. Deletion: no business is deleted while its records are kept (orgs_retention_guard, and the
-- admin's delete and its preview say so first).
--
-- Redefined functions are their latest definitions with only the changes described at each one; signatures are unchanged,
-- so create or replace keeps every grant.

-- ---------------------------------------------------------------------------
-- 1. Handovers
-- ---------------------------------------------------------------------------
-- email: lower-cased and trimmed. status: pending (waiting for the person), accepted, cancelled (replaced by a newer one,
-- or the mandate ended). token_hash: the SHA-256 of the ph_ link last sent (kept once accepted, so the link reads as used).
create table public.practice_handovers (
  id uuid primary key default gen_random_uuid(),
  practice_id uuid not null references public.practices(id) on delete cascade,
  client_id uuid not null references public.practice_clients(id) on delete cascade,
  email text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and length(email) <= 254),
  name text not null check (length(trim(name)) between 2 and 120),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'cancelled')),
  token_hash text,
  token_expires timestamptz,
  sent_count int not null default 0,
  sent_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  accepted_by uuid references auth.users(id) on delete set null,
  accepted_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index practice_handovers_one_pending on public.practice_handovers(client_id) where status = 'pending';
create index practice_handovers_client on public.practice_handovers(client_id, created_at desc);
create index practice_handovers_practice on public.practice_handovers(practice_id);
create unique index practice_handovers_token on public.practice_handovers(token_hash) where token_hash is not null;
create index practice_handovers_created_by on public.practice_handovers(created_by) where created_by is not null;
create index practice_handovers_accepted_by on public.practice_handovers(accepted_by) where accepted_by is not null;
alter table public.practice_handovers enable row level security;
revoke all on public.practice_handovers from anon, authenticated;

-- TaxStreem is also told of a handover to someone other than the director who confirmed the wallets (kind 'handover').
alter table public.practice_mandate_flags drop constraint if exists practice_mandate_flags_kind_check;
alter table public.practice_mandate_flags add constraint practice_mandate_flags_kind_check
  check (kind in ('duplicate_company', 'director_declined', 'director_review', 'handover'));

-- A partner of the practice hands a business it runs under full mandate to the person who will own it. p: {email, name}.
-- Never one of the practice's people (whatever their status) or the practice's own address; a handover waiting is
-- cancelled (its link stops working); five handovers a day for a business. The email goes as the practice's other
-- invitations do (practice_invite_check, then svc_practice_invite_link 'handover'). {id}.
create or replace function public.practice_handover_start(p_client uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients; m public.practice_members; v_email text; v_name text; v_id uuid;
begin
  select * into c from practice_clients where id = p_client for update;
  if c.id is null or c.practice_id is null then raise exception 'Client not found.'; end if;
  m := private.practice_require(c.practice_id, true);
  if m.role <> 'partner' then raise exception 'Only a partner hands a business over.' using errcode = '42501'; end if;
  if not private.director_mandate_open(c.id, c.practice_id) then
    raise exception 'Only a business the firm runs under full mandate is handed over.';
  end if;
  if jsonb_typeof(p) is distinct from 'object' then raise exception 'Enter the email address and name of the person taking the business over.'; end if;
  v_email := lower(trim(coalesce(p->>'email', '')));
  v_name := trim(coalesce(p->>'name', ''));
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 254 then
    raise exception 'Enter the email address of the person taking the business over.';
  end if;
  if private.firm_email(c.practice_id, v_email) in ('member', 'practice') then raise exception 'That person is on the practice.'; end if;
  -- Nor an address on the firm's own domain: the business goes to its owner, not back to the firm.
  if private.firm_email(c.practice_id, v_email) = 'domain' then
    raise exception 'Use the owner''s own email address, not one on the firm''s domain.';
  end if;
  if length(v_name) not between 2 and 120 then raise exception 'Enter the name of the person taking the business over.'; end if;
  if (select count(*) from practice_handovers where client_id = c.id and created_at > now() - interval '1 day') >= 5 then
    raise exception 'That is five handovers for this business today. Try again tomorrow.';
  end if;
  update practice_handovers set status = 'cancelled', token_hash = null, token_expires = null where client_id = c.id and status = 'pending';
  insert into practice_handovers (practice_id, client_id, email, name, created_by)
  values (c.practice_id, c.id, v_email, v_name, auth.uid())
  returning id into v_id;
  perform private.activity_event(c.org_id, 'handover_started', 'A handover to the owner was started',
    jsonb_build_object('practice_id', c.practice_id, 'client_id', c.id, 'handover_id', v_id));
  return jsonb_build_object('id', v_id);
end $$;

-- practice_invite_check: as before, and kind 'handover' (a partner of the practice, the handover still waiting and the
-- business still run under full mandate, five emails a day).
create or replace function public.practice_invite_check(p_kind text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare t public.practice_members; c public.practice_clients; h public.practice_handovers; m public.practice_members;
begin
  if p_kind = 'member' then
    select * into t from practice_members where id = p_id;
    if not found or t.status <> 'invited' then raise exception 'That person has joined already or was removed.'; end if;
    perform private.practice_require(t.practice_id, true);
    if t.sent_count >= 5 and t.sent_at > now() - interval '1 day' then raise exception 'That is enough emails to % for today.', t.email; end if;
  elsif p_kind in ('client', 'accountant') then
    select * into c from practice_clients where id = p_id;
    if not found or c.status not in ('invited', 'requested') then raise exception 'That invitation was accepted or withdrawn.'; end if;
    if p_kind = 'client' then
      if c.status <> 'invited' then raise exception 'That is not an invitation to a business.'; end if;
      perform private.practice_require(c.practice_id, true);
    else
      if c.status <> 'requested' then raise exception 'That is not an invitation to an accountant.'; end if;
      perform private.require(c.org_id, 'manage_team');
    end if;
    if c.sent_count >= 5 and c.sent_at > now() - interval '1 day' then raise exception 'That is enough emails to % for today.', c.invite_email; end if;
  elsif p_kind = 'handover' then
    select * into h from practice_handovers where id = p_id;
    if not found or h.status <> 'pending' then raise exception 'That handover was accepted or cancelled.'; end if;
    m := private.practice_require(h.practice_id, true);
    if m.role <> 'partner' then raise exception 'Only a partner hands a business over.' using errcode = '42501'; end if;
    if not private.director_mandate_open(h.client_id, h.practice_id) then raise exception 'The firm no longer runs this business under full mandate.'; end if;
    if h.sent_count >= 5 and h.sent_at > now() - interval '1 day' then raise exception 'That is enough emails to % for today.', h.email; end if;
  else
    raise exception 'Unknown invitation.';
  end if;
  return jsonb_build_object('ok', true, 'kind', p_kind, 'id', p_id);
end $$;

-- svc_practice_invite_link: as before, and kind 'handover': a fresh ph_ link (replacing the last one) for 14 days, in the
-- firm's name, replies to the engagement partner while they are in the practice, else the practice.
create or replace function public.svc_practice_invite_link(p_kind text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare t public.practice_members; c public.practice_clients; pr public.practices; v_token text; v_app text; v_by text; v_by_email text;
  h public.practice_handovers; v_business text;
begin
  v_app := coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app');
  if p_kind = 'member' then
    select * into t from practice_members where id = p_id and status = 'invited';
    if not found then return null; end if;
    select * into pr from practices where id = t.practice_id;
    v_token := 'pm_' || encode(extensions.gen_random_bytes(24), 'hex');
    update practice_members set token_hash = encode(extensions.digest(v_token, 'sha256'), 'hex'), token_expires = now() + interval '14 days',
      sent_count = case when sent_at > now() - interval '1 day' then sent_count + 1 else 1 end, sent_at = now() where id = t.id;
    select display_name, email into v_by, v_by_email from practice_members where id = t.invited_by;
    return jsonb_build_object('to', t.email, 'link', v_app || '/practice/join?t=' || v_token, 'reply_to', v_by_email, 'from_name', pr.name,
      'subject', 'Join ' || pr.name || ' on Counta', 'heading', 'Join ' || pr.name || ' on Counta',
      'greet', split_part(t.display_name, ' ', 1),
      'lines', jsonb_build_array(coalesce(v_by, 'Your practice') || ' has added you to ' || pr.name || '''s accountant portal on Counta as ' ||
        case t.role when 'partner' then 'a partner' when 'manager' then 'a manager' else 'a member of staff' end || '.',
        'Use the button to sign in, or sign up, with ' || t.email || '. The link works once, for fourteen days.'),
      'button', 'Join the practice');
  end if;
  if p_kind = 'handover' then
    select * into h from practice_handovers where id = p_id and status = 'pending' for update;
    if not found or not private.director_mandate_open(h.client_id, h.practice_id) then return null; end if;
    select * into pr from practices where id = h.practice_id;
    select o.name into v_business from practice_clients pc join orgs o on o.id = pc.org_id where pc.id = h.client_id;
    v_by_email := coalesce((select pm.email from practice_clients pc join practice_members pm on pm.id = pc.engagement_partner_id
                            where pc.id = h.client_id and pm.status = 'active'), pr.email);
    v_token := 'ph_' || encode(extensions.gen_random_bytes(24), 'hex');
    update practice_handovers set token_hash = encode(extensions.digest(v_token, 'sha256'), 'hex'), token_expires = now() + interval '14 days',
      sent_count = case when sent_at > now() - interval '1 day' then sent_count + 1 else 1 end, sent_at = now() where id = h.id;
    return jsonb_build_object('to', h.email, 'link', v_app || '/practice/join?t=' || v_token, 'reply_to', v_by_email, 'from_name', pr.name,
      'subject', 'Take over ' || v_business || ' on Counta', 'heading', 'Take over ' || v_business || ' on Counta',
      'greet', split_part(trim(h.name), ' ', 1),
      'lines', jsonb_build_array(pr.name || ' has kept the books of ' || v_business || ' on Counta and is handing the business over to you.',
        'When you accept, you become the owner of ' || v_business || ' on Counta. ' || pr.name || ' stays on as your accountant, with an Accountant''s place.',
        'Use the button to sign in, or sign up, with ' || h.email || '. The link works once, for fourteen days.'),
      'button', 'Take over the business');
  end if;
  select * into c from practice_clients where id = p_id and status in ('invited', 'requested');
  if not found then return null; end if;
  v_token := 'pc_' || encode(extensions.gen_random_bytes(24), 'hex');
  update practice_clients set token_hash = encode(extensions.digest(v_token, 'sha256'), 'hex'), token_expires = now() + interval '14 days',
    sent_count = case when sent_at > now() - interval '1 day' then sent_count + 1 else 1 end, sent_at = now() where id = c.id;
  select coalesce(nullif(trim(raw_user_meta_data->>'full_name'), ''), email), email into v_by, v_by_email from auth.users where id = c.created_by;
  if c.status = 'invited' then
    select * into pr from practices where id = c.practice_id;
    return jsonb_build_object('to', c.invite_email, 'link', v_app || '/practice/join?t=' || v_token, 'reply_to', coalesce(pr.email, v_by_email), 'from_name', pr.name,
      'subject', pr.name || ' invites you to work together on Counta', 'heading', 'Connect your business to ' || pr.name,
      'greet', coalesce(split_part(c.invite_name, ' ', 1), ''),
      'lines', jsonb_build_array(pr.name || ' would like to keep your books and handle your tax in Counta' || coalesce(', for ' || c.business_name, '') || '.',
        'When you accept, their accountants get an Accountant''s place in your business: they keep the books and prepare tax returns, and never move money. You choose which business, and you can end it at any time.'
        || case when c.billing = 'practice' then ' ' || pr.name || ' pays for your Counta plan.' else '' end,
        'Use the button to sign in, or sign up if you are new to Counta.'),
      'button', 'See the invitation');
  end if;
  return jsonb_build_object('to', c.invite_email, 'link', v_app || '/practice/join?t=' || v_token, 'reply_to', v_by_email, 'from_name', c.business_name,
    'subject', c.business_name || ' invites you to keep its books on Counta', 'heading', c.business_name || ' wants you as its accountant',
    'greet', coalesce(split_part(c.invite_name, ' ', 1), ''),
    'lines', jsonb_build_array(coalesce(v_by, 'The owner') || ' has invited you to look after ' || c.business_name || ' in Counta''s accountant portal.',
      'Accept to see the business with your other clients: its books, bank lines, tax deadlines and returns, all in one place.',
      'Use the button to sign in, or sign up with ' || c.invite_email || ' if you are new to Counta.'),
    'button', 'See the invitation');
end $$;

-- practice_invite_preview: as before, and ph_ links: {kind 'handover', status (open, expired, used: accepted, cancelled or
-- no longer run under full mandate), practice, business, email}.
create or replace function public.practice_invite_preview(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare t public.practice_members; c public.practice_clients; pr public.practices; v_hash text; h public.practice_handovers;
begin
  if coalesce(p_token, '') !~ '^p[mch]_[0-9a-f]{48}$' then return jsonb_build_object('status', 'invalid'); end if;
  v_hash := encode(extensions.digest(p_token, 'sha256'), 'hex');
  if p_token like 'pm_%' then
    select * into t from practice_members where token_hash = v_hash;
    if not found then return jsonb_build_object('status', 'invalid'); end if;
    select * into pr from practices where id = t.practice_id;
    return jsonb_build_object('kind', 'member', 'status', case when t.status <> 'invited' then 'used' when t.token_expires < now() then 'expired' else 'open' end,
      'practice', pr.name, 'email', t.email, 'name', t.display_name, 'role', t.role);
  end if;
  if p_token like 'ph_%' then
    select * into h from practice_handovers where token_hash = v_hash;
    if not found then return jsonb_build_object('status', 'invalid'); end if;
    return jsonb_build_object('kind', 'handover',
      'status', case when h.status <> 'pending' or not private.director_mandate_open(h.client_id, h.practice_id) then 'used'
                     when h.token_expires < now() then 'expired' else 'open' end,
      'practice', (select name from practices where id = h.practice_id),
      'business', (select o.name from practice_clients pc join orgs o on o.id = pc.org_id where pc.id = h.client_id),
      'email', h.email);
  end if;
  select * into c from practice_clients where token_hash = v_hash;
  if not found then return jsonb_build_object('status', 'invalid'); end if;
  select * into pr from practices where id = c.practice_id;
  return jsonb_build_object('kind', case when c.initiated_by = 'practice' then 'client' else 'accountant' end,
    'status', case when c.status not in ('invited', 'requested') then 'used' when c.token_expires < now() then 'expired' else 'open' end,
    'practice', pr.name, 'practice_verified', exists (select 1 from practice_members where practice_id = pr.id and status = 'active' and licence_status = 'verified'),
    'business', c.business_name, 'email', c.invite_email, 'services', c.services, 'billing', c.billing, 'note', c.note,
    'partners', (select coalesce(jsonb_agg(jsonb_build_object('name', x.display_name, 'licence', private.licence_text(x))), '[]'::jsonb)
                 from practice_members x where x.practice_id = pr.id and x.role = 'partner' and x.status = 'active'));
end $$;

-- The person signed in with the handover's address takes the business over, in this order: the practice no longer runs it;
-- they are its owner (their own place, or a place they had there, becomes the owner's); the client is involved and was
-- handed over; the firm's people get ordinary accountants' places; the handover is accepted; logged. {org_id}.
-- The director's consent stays binding: unless the new owner is the director who confirmed the wallets (the same address),
-- TaxStreem checks the handover before payments open (identity_status 'review', identity reason 'handover'; approved through
-- review_identity), and is told with a 'handover' flag that records whether the accepting session's address is one the
-- firm's people signed in from in the last 30 days (null when it cannot be read). The client link is locked before the
-- handover, as practice_handover_start and practice_end_mandate do.
create or replace function public.practice_handover_accept(p_token text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare h public.practice_handovers; c public.practice_clients; o public.orgs; ex public.members; v_uid uuid := auth.uid(); v_email text; v_name text;
  v_confirmed timestamptz; v_member uuid; v_prev text; v_client uuid; v_director boolean; v_ip inet; v_firm_ip boolean;
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if coalesce(p_token, '') ~ '^ph_[0-9a-f]{48}$' then
    select client_id into v_client from practice_handovers where token_hash = private.sha256_hex(p_token);
  end if;
  if v_client is not null then
    select * into c from practice_clients where id = v_client for update;
    select * into h from practice_handovers where token_hash = private.sha256_hex(p_token) and client_id = v_client for update;
  end if;
  if h.id is null then raise exception 'That handover link is not valid. Ask the firm to send it again.'; end if;
  if h.status = 'accepted' then raise exception 'This handover was accepted already.'; end if;
  if h.status = 'cancelled' then raise exception 'This handover was cancelled. Ask the firm about it.'; end if;
  if h.token_expires is null or h.token_expires <= now() then raise exception 'This handover link has expired. Ask the firm to send it again.'; end if;
  select lower(trim(email)), coalesce(nullif(trim(raw_user_meta_data->>'full_name'), ''), h.name), email_confirmed_at into v_email, v_name, v_confirmed
  from auth.users where id = v_uid;
  if v_email is distinct from h.email then
    raise exception 'This handover is for %. Sign in with that email address.', h.email;
  end if;
  -- The business goes to whoever holds the address: the address must be confirmed as theirs.
  if v_confirmed is null then raise exception 'Confirm your email address first, then open the link again.' using errcode = '42501'; end if;
  select * into o from orgs where id = c.org_id for update;
  if not (c.status = 'active' and c.mode = 'full' and o.managed_by is not distinct from c.practice_id) then
    raise exception 'The firm no longer runs this business under full mandate.';
  end if;
  if exists (select 1 from practice_members where practice_id = c.practice_id and user_id = v_uid and status = 'active') then
    raise exception 'You are on the practice. The business is handed over to someone outside the firm.';
  end if;
  -- The director who confirmed the wallets, taking the business over themselves.
  v_director := exists (select 1 from practice_director_confirmations d where d.client_id = c.id and d.status = 'confirmed' and lower(trim(d.email)) = v_email);
  if not v_director then
    begin
      v_ip := private.ip_host((select s.ip from auth.sessions s where s.id = private.uuid_of(auth.jwt()->>'session_id') and s.user_id = v_uid));
    exception when others then
      v_ip := null;
    end;
    v_firm_ip := case when v_ip is not null then exists (
      select 1 from auth.sessions s join practice_members pm on pm.user_id = s.user_id
      where pm.practice_id = c.practice_id and private.ip_host(s.ip) = v_ip and coalesce(s.updated_at, s.created_at) > now() - interval '30 days') end;
  end if;

  update orgs set managed_by = null,
    identity_status = case when v_director then identity_status else 'review' end,
    identity = case when v_director then identity
      else (identity - 'review') || jsonb_build_object('reason', 'handover',
        'handover', jsonb_build_object('id', h.id, 'at', now(), 'status_before', o.identity_status)) end
  where id = o.id;
  v_prev := coalesce(current_setting('counta.seat_sync', true), '');
  perform set_config('counta.seat_sync', 'on', true);
  select * into ex from members where org_id = o.id and (user_id = v_uid or (user_id is null and lower(email) = v_email))
  order by (user_id = v_uid) desc nulls last limit 1;
  if ex.id is null then
    insert into members (org_id, user_id, email, display_name, role, title, status)
    values (o.id, v_uid, v_email, left(v_name, 120), 'owner', 'Owner', 'active')
    returning id into v_member;
  else
    update members set user_id = v_uid, email = v_email, role = 'owner', title = 'Owner', status = 'active', practice_id = null, acts_as_owner = false,
      perm_overrides = '{}'::jsonb
    where id = ex.id;
    v_member := ex.id;
  end if;
  perform private.apply_member_perms(v_member);
  perform set_config('counta.seat_sync', v_prev, true);
  update practice_clients set mode = 'involved', end_kind = 'handover', accepted_by = v_uid where id = c.id;
  perform private.practice_sync_seats(c.id);
  update practice_handovers set status = 'accepted', accepted_by = v_uid, accepted_at = now() where id = h.id;
  if not v_director then
    insert into practice_mandate_flags (practice_id, client_id, kind, detail)
    values (c.practice_id, c.id, 'handover', jsonb_build_object('handover_id', h.id, 'org_id', o.id,
      'reason', case when o.director_confirmed_at is null then 'no_director' else 'not_director' end,
      'ip', host(v_ip), 'ip_matches_firm', v_firm_ip, 'identity_before', o.identity_status));
  end if;
  perform private.activity_event(o.id, 'handover', 'Handed over to ' || left(v_name, 80),
    jsonb_build_object('practice_id', c.practice_id, 'client_id', c.id, 'handover_id', h.id, 'director', v_director));
  perform private.practice_notify(c.practice_id, o.name || ' was handed over',
    left(v_name, 80) || ' accepted the handover and owns the business on Counta now. The firm stays on as its accountant.'
      || case when v_director then '' else ' Payments stay shut until TaxStreem has checked the handover.' end, '/practice/clients');
  return jsonb_build_object('org_id', o.id);
end $$;

-- outbound_check: as before, and an alert, invitation or practice email to the address of a handover waiting for the
-- business's owner-to-be may go.
create or replace function private.outbound_check(p_org uuid, p_channel text, p_kind text, p_to text) returns text
language plpgsql stable set search_path = public, private as $$
declare o public.orgs;
begin
  select * into o from orgs where id = p_org;
  if not found or (o.managed_by is null and o.read_only_at is null) then return null; end if;
  if o.read_only_at is not null then return 'read_only'; end if;
  if p_channel = 'call' then return 'calls_off'; end if;
  if p_kind in ('alert', 'invite', 'practice') then
    if p_channel = 'email' and lower(trim(p_to)) = any (private.firm_addresses(p_org)) then return null; end if;
    -- The owner-to-be of a handover waiting.
    if p_channel = 'email' and exists (
        select 1 from practice_handovers h join practice_clients c on c.id = h.client_id
        where c.org_id = p_org and h.status = 'pending' and h.email = lower(trim(p_to))) then
      return null;
    end if;
    -- The WhatsApp number linked by someone working the business for the practice.
    if p_channel = 'whatsapp' and exists (
        select 1 from members m cross join lateral private.wa_number(m.user_id, p_org) w
        where m.org_id = p_org and m.status = 'active' and m.practice_id = o.managed_by and m.user_id is not null
          and private.clean_phone(w.phone) = private.clean_phone(p_to)) then
      return null;
    end if;
    return 'not_firm_address';
  end if;
  if o.send_mode = 'download_only' then return 'download_only'; end if;
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- 2. The firm's places outside the plan's limit on people
-- ---------------------------------------------------------------------------
-- A practice's places in a business use none of its plan's places for people while the practice runs it (it pays for the
-- plan), and after it handed the business over to its owner while it still works on it (the link it handed over on).
create or replace function private.seat_exempt(p_org uuid, p_practice uuid) returns boolean
language sql stable set search_path = public, private as $$
  select p_practice is not null and (
    exists (select 1 from orgs where id = p_org and managed_by = p_practice)
    or exists (select 1 from practice_clients c where c.org_id = p_org and c.practice_id = p_practice and c.status = 'active' and c.end_kind = 'handover'))
$$;

-- meter_usage: as before, people counted outside private.seat_exempt.
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
        and not private.seat_exempt(p_org, m.practice_id);
    when 'locations' then
      select count(*) into v from locations where org_id = p_org;
    when 'bank_feeds' then
      select count(*) into v from bank_accounts where org_id = p_org and provider = 'mono' and active;
    else v := 0;
  end case;
  return coalesce(v, 0);
end $$;

-- enforce_plan: as before, a place outside private.seat_exempt is not checked.
create or replace function private.enforce_plan() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if tg_table_name = 'sales' then
    -- Partners' invoices through Prism are charged by Prism in credits.
    if new.doc_type in ('receipt', 'invoice') and new.status not in ('draft', 'void', 'cancelled') and new.channel is distinct from 'api' then
      perform private.check_quota(new.org_id, 'sales');
    end if;
  elsif tg_table_name = 'members' then
    -- The practice's places in a business it runs, or handed over and still works on, use none of the plan's places.
    if private.seat_exempt(new.org_id, new.practice_id) then return new; end if;
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
-- 3. The seat sync, and the engagement partner
-- ---------------------------------------------------------------------------
-- practice_sync_seats: as before, and a full mandate that ended without a handover keeps its engagement partner's place
-- whoever that is now: that place is given back (as it was under the mandate) when the engagement partner changes; every
-- other place of the practice is switched off. (One path for every link: a link that is not active wants no one else.)
create or replace function private.practice_sync_seats(p_client uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients; pm public.practice_members; ex public.members; p jsonb; v_wanted boolean; v_firm text;
  v_full boolean; v_role text; v_over jsonb; v_seat uuid; v_seats uuid[] := '{}'; v_keep uuid;
  v_prev text := coalesce(current_setting('counta.seat_sync', true), '');
begin
  select * into c from practice_clients where id = p_client;
  if not found or c.org_id is null or c.practice_id is null then return; end if;
  -- Only the seat sync changes the practice's places (members_mandate_guard), until it returns; then the caller's own
  -- value again (a handover turns it on before it syncs).
  perform set_config('counta.seat_sync', 'on', true);
  -- A full mandate that ended without a handover leaves the business with its engagement partner.
  if c.status <> 'active' and c.end_kind = 'ended' and c.mode = 'full' then
    select ep.user_id into v_keep from practice_members ep
    where ep.id = c.engagement_partner_id and ep.practice_id = c.practice_id and ep.status = 'active' and ep.role in ('partner', 'manager');
  end if;
  -- Under full mandate the firm's people are admins acting as the owner, with the admin template as their own permissions
  -- (the business's admin settings never narrow them); involved, accountants. A full-mode link is a full mandate only
  -- while the practice runs the business.
  v_full := c.mode = 'full' and exists (select 1 from orgs where id = c.org_id and managed_by = c.practice_id);
  v_role := case when v_full then 'admin' else 'accountant' end;
  select name into v_firm from practices where id = c.practice_id;
  for pm in select * from practice_members where practice_id = c.practice_id order by created_at, id loop
    v_wanted := pm.status = 'active' and pm.user_id is not null
      and case when c.status = 'active'
               then pm.role in ('partner', 'manager') or exists (select 1 from practice_assignments a where a.client_id = c.id and a.member_id = pm.id)
               else coalesce(pm.user_id = v_keep, false) end;
    continue when not v_wanted;
    ex := null; v_seat := null;
    select * into ex from members where org_id = c.org_id and user_id = pm.user_id;
    if ex.id is null then select * into ex from members where org_id = c.org_id and user_id is null and lower(email) = lower(pm.email); end if;
    if ex.id is null then
      v_over := case when v_full then private.role_template('admin') else '{}'::jsonb end;
      p := private.role_perms(c.org_id, v_role) || v_over;
      insert into members (org_id, user_id, email, display_name, role, title, status, practice_id, acts_as_owner, perm_overrides,
        p_record_sales, p_receive_stock, p_count_stock, p_approve_adjustments, p_edit_prices, p_approve_pos, p_transfer_stock, p_see_margins,
        p_issue_stock, p_keep_books, p_make_payments, p_add_items, p_approve_payments, p_file_tax, p_manage_team, p_manage_settings)
      values (c.org_id, pm.user_id, lower(pm.email), pm.display_name, v_role, left('Accountant, ' || v_firm, 80), 'active', c.practice_id, v_full, v_over,
        (p->>'record_sales')::boolean, (p->>'receive_stock')::boolean, (p->>'count_stock')::boolean, (p->>'approve_adjustments')::boolean,
        (p->>'edit_prices')::boolean, (p->>'approve_pos')::boolean, (p->>'transfer_stock')::boolean, (p->>'see_margins')::boolean,
        (p->>'issue_stock')::boolean, (p->>'keep_books')::boolean, (p->>'make_payments')::boolean, (p->>'add_items')::boolean,
        (p->>'approve_payments')::boolean, (p->>'file_tax')::boolean, (p->>'manage_team')::boolean, (p->>'manage_settings')::boolean)
      returning id into v_seat;
    elsif ex.role <> 'owner' and (ex.practice_id = c.practice_id or (ex.practice_id is null and (ex.role = 'accountant' or ex.user_id is null))) then
      -- Their own earlier place (an invitation, or an accountant's place) becomes the practice's. The permissions change
      -- with the role in the same statement (an admin's place becoming an accountant's, at a handover, would otherwise
      -- hold an admin's permissions under an accountant's role for a moment, which members_sales_cannot_edit refuses).
      v_over := case when v_full then private.role_template('admin') when ex.role = 'accountant' then ex.perm_overrides else '{}'::jsonb end;
      p := private.role_perms(c.org_id, v_role) || private.clean_perms(v_over);
      update members set user_id = pm.user_id, status = 'active', practice_id = c.practice_id, role = v_role, acts_as_owner = v_full, perm_overrides = v_over,
        p_record_sales = (p->>'record_sales')::boolean, p_receive_stock = (p->>'receive_stock')::boolean, p_count_stock = (p->>'count_stock')::boolean,
        p_approve_adjustments = (p->>'approve_adjustments')::boolean, p_edit_prices = (p->>'edit_prices')::boolean, p_approve_pos = (p->>'approve_pos')::boolean,
        p_transfer_stock = (p->>'transfer_stock')::boolean, p_see_margins = (p->>'see_margins')::boolean, p_issue_stock = (p->>'issue_stock')::boolean,
        p_keep_books = (p->>'keep_books')::boolean, p_make_payments = (p->>'make_payments')::boolean, p_add_items = (p->>'add_items')::boolean,
        p_approve_payments = (p->>'approve_payments')::boolean, p_file_tax = (p->>'file_tax')::boolean, p_manage_team = (p->>'manage_team')::boolean,
        p_manage_settings = (p->>'manage_settings')::boolean
      where id = ex.id;
      update member_invites set token_hash = null where member_id = ex.id;
      v_seat := ex.id;
    end if;
    if v_seat is not null then
      perform private.apply_member_perms(v_seat);
      v_seats := v_seats || v_seat;
    end if;
  end loop;
  -- Every other place of the practice is switched off, whatever its role, and no longer acts as the owner.
  update members set status = 'disabled', acts_as_owner = false
  where org_id = c.org_id and practice_id = c.practice_id and (status <> 'disabled' or acts_as_owner) and role <> 'owner'
    and not (id = any (v_seats));
  perform set_config('counta.seat_sync', v_prev, true);
end $$;

-- A partner chooses the engagement partner of an active client, or of a full mandate kept read-only after it ended without
-- a handover (its link written as the seat sync writes, so the read-only rule lets it through): one of the firm's active
-- partners or managers. The seats follow (the place kept moves to the new one). {client_id, engagement_partner_id}.
create or replace function public.practice_set_engagement_partner(p_client uuid, p_member uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients; m public.practice_members; t public.practice_members; v_prev text;
begin
  select * into c from practice_clients where id = p_client for update;
  if c.id is null or c.practice_id is null then raise exception 'Client not found.'; end if;
  m := private.practice_require(c.practice_id, true);
  if m.role <> 'partner' then raise exception 'Only a partner chooses the engagement partner.' using errcode = '42501'; end if;
  if not (c.status = 'active' or (c.status = 'ended' and c.end_kind = 'ended' and c.mode = 'full')) then raise exception 'That work has ended.'; end if;
  select * into t from practice_members where id = p_member and practice_id = c.practice_id and role in ('partner', 'manager') and status = 'active';
  if t.id is null then raise exception 'The engagement partner must be one of the firm''s active partners or managers.'; end if;
  if c.engagement_partner_id is distinct from t.id then
    v_prev := coalesce(current_setting('counta.seat_sync', true), '');
    perform set_config('counta.seat_sync', 'on', true);
    update practice_clients set engagement_partner_id = t.id where id = c.id;
    perform set_config('counta.seat_sync', v_prev, true);
    perform private.practice_sync_seats(c.id);
    perform private.activity_event(c.org_id, 'engagement_partner', 'Engagement partner: ' || t.display_name,
      jsonb_build_object('practice_id', c.practice_id, 'client_id', c.id, 'member_id', t.id));
  end if;
  return jsonb_build_object('client_id', c.id, 'engagement_partner_id', t.id);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Ending a full mandate without a handover
-- ---------------------------------------------------------------------------
-- Everything that keeps a business working on its own is stopped: connected tools paused, POS connections removed (their
-- keys wiped, terminals stopped), bank feeds unlinked (lines already in stay), the plan cancelled at the end of its period
-- (Counta then moves it to the standard plan instead of charging anyone).
create or replace function private.org_pause_all(p_org uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare x uuid;
begin
  update integrations set status = 'paused' where org_id = p_org and status in ('active', 'error');
  for x in select id from pos_connections where org_id = p_org and status <> 'removed' loop
    perform public.svc_pos_remove(x);
  end loop;
  update bank_accounts set provider = 'manual', provider_meta = coalesce(provider_meta, '{}'::jsonb) || jsonb_build_object('unlinked_at', now(),
      'unlinked_reason', 'engagement ended', 'former_feed', provider_ref), provider_ref = null
  where org_id = p_org and provider = 'mono' and provider_ref is not null;
  update subscriptions set cancel_at_period_end = true, updated_at = now() where org_id = p_org and not cancel_at_period_end;
end $$;

-- A partner ends a full mandate without a handover, with a reason of 10 characters or more. Refused while either wallet
-- holds money or a payment is moving. Then: the business's connections paused; the client ended (the intake is kept as
-- long, by practice_clients_intake); only the engagement partner's place left; a handover waiting cancelled; logged; and
-- last the business read-only and kept as long as the letter says (at least five years). The practice still runs it, so
-- Counta stays silent to the client. {client_id, org_id, read_only_at, retain_until}.
create or replace function public.practice_end_mandate(p_client uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients; m public.practice_members; o public.orgs; v_reason text;
begin
  select * into c from practice_clients where id = p_client for update;
  if c.id is null or c.practice_id is null then raise exception 'Client not found.'; end if;
  m := private.practice_require(c.practice_id, true);
  if m.role <> 'partner' then raise exception 'Only a partner ends a full mandate.' using errcode = '42501'; end if;
  select * into o from orgs where id = c.org_id for update;
  if not (c.status = 'active' and c.mode = 'full' and o.managed_by is not distinct from c.practice_id) then
    raise exception 'Only a business the firm runs under full mandate is ended here.';
  end if;
  v_reason := trim(coalesce(p->>'reason', ''));
  if length(v_reason) < 10 then raise exception 'Give a reason of at least 10 characters.'; end if;
  if length(v_reason) > 1000 then raise exception 'Keep the reason under 1,000 characters.'; end if;
  if exists (select 1 from wallets w where w.org_id = o.id and private.wallet_ledger(w.id) > 0.004)
     or exists (select 1 from tax_wallets t where t.org_id = o.id and private.tax_wallet_ledger(t.id) > 0.004) then
    raise exception 'Move the money out of the business wallet and the tax wallet first.';
  end if;
  if exists (select 1 from payouts where org_id = o.id and status in ('pending_approval', 'approved', 'processing'))
     or exists (select 1 from tax_transfers where org_id = o.id and status in ('pending', 'sent'))
     or exists (select 1 from tax_payments where org_id = o.id and status in ('approved', 'processing')) then
    raise exception 'Wait for the payouts in progress to finish first.';
  end if;

  perform private.org_pause_all(o.id);
  update practice_clients set status = 'ended', end_kind = 'ended', ended_at = now(), ended_by = auth.uid() where id = c.id;
  perform private.practice_sync_seats(c.id);
  update practice_handovers set status = 'cancelled', token_hash = null, token_expires = null where client_id = c.id and status = 'pending';
  perform private.activity_event(o.id, 'mandate_ended', 'Full mandate ended by ' || (select name from practices where id = c.practice_id),
    jsonb_build_object('practice_id', c.practice_id, 'client_id', c.id, 'reason', v_reason));
  update orgs set read_only_at = now(), retain_until = private.retain_date(c.retention_years) where id = o.id
  returning * into o;
  return jsonb_build_object('client_id', c.id, 'org_id', o.id, 'read_only_at', o.read_only_at, 'retain_until', o.retain_until);
end $$;

-- Money and stored files while a business is kept read-only, or after a handover TaxStreem has still to approve.
-- A handover TaxStreem has not approved (practice_handover_accept): in review, or rejected. Until TaxStreem decides it
-- through the identity review (review_identity), no NIN check or NIN slip of the new owner's verifies the business.
create or replace function private.handover_pending(p_status text, p_identity jsonb) returns boolean
language sql immutable set search_path = public, private as $$
  select coalesce(p_identity->>'reason' = 'handover' and p_status in ('review', 'rejected'), false)
$$;

-- Why the identity cannot be confirmed by the business while its handover waits for TaxStreem.
create or replace function private.handover_pending_text(p_status text) returns text
language sql immutable set search_path = public, private as $$
  select case when p_status = 'rejected' then 'Payments are locked: TaxStreem did not accept the handover of the business. Contact TaxStreem about it.'
    else 'Payments open once TaxStreem has checked the handover. This usually takes a working day.' end
$$;

-- payments_open: as before, and never for a business kept read-only after its engagement ended.
create or replace function private.payments_open(p_org uuid) returns boolean
language sql stable security definer set search_path = public, private as $$
  select coalesce((select identity_status in ('not_required', 'verified', 'approved') and read_only_at is null
      and (managed_by is null or (director_confirmed_at is not null and private.practice_can_full(managed_by)))
    from orgs where id = p_org), false)
$$;

-- require_payments_open: as before; a business kept read-only is refused, and a handover TaxStreem has not approved says
-- so.
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

-- svc_identity_nin: as before, and a handover TaxStreem has not approved is not gone round by a NIN check (TaxStreem
-- decides it through the identity review).
create or replace function public.svc_identity_nin(p_user uuid, p_org uuid, p_last4 text, p_first text, p_middle text, p_last text,
  p_conversation text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; v_people jsonb; v_match jsonb; v_self text; v_registered boolean; v_attempts int;
begin
  if not private.acts_as_owner(p_org, p_user) then
    raise exception 'Only the owner confirms a director''s identity.' using errcode = '42501';
  end if;
  select * into o from orgs where id = p_org for update;
  if p_conversation is not null and p_conversation ~ '^[A-Za-z0-9_-]{6,80}$' then
    insert into voice_forget (conversation_id, user_id) values (p_conversation, p_user) on conflict (conversation_id) do nothing;
  end if;
  if o.identity_status in ('verified', 'approved', 'not_required') then
    return jsonb_build_object('verified', true, 'already', true, 'matched', o.identity->>'matched');
  end if;
  if private.handover_pending(o.identity_status, o.identity) then
    return jsonb_build_object('verified', false, 'reason', 'handover_review');
  end if;
  v_registered := exists (select 1 from kyc_profiles k where k.org_id = p_org and k.status = 'submitted' and k.source = 'cac');
  if not v_registered and o.managed_by is not null then
    return jsonb_build_object('verified', false, 'reason', 'cac_required');
  end if;
  v_people := private.identity_people(p_org);
  if not v_registered then
    -- Not on CAC: the NIN must be the account holder's own.
    select coalesce(nullif(trim(raw_user_meta_data->>'full_name'), ''), '') into v_self from auth.users where id = p_user;
    v_people := jsonb_build_array(jsonb_build_object('role', 'owner', 'name', v_self, 'surname', '', 'given', ''));
  end if;
  v_match := private.identity_match(p_first, p_middle, p_last, v_people);
  v_attempts := coalesce((o.identity->>'attempts')::int, 0) + 1;
  if v_match is not null then
    update orgs set identity_status = 'verified', identity = identity || jsonb_build_object('method', 'nin', 'matched', v_match->>'name',
      'matched_role', v_match->>'role', 'last4', right(regexp_replace(coalesce(p_last4, ''), '\D', '', 'g'), 4), 'at', now(), 'by', p_user, 'attempts', v_attempts)
    where id = p_org;
    return jsonb_build_object('verified', true, 'matched', v_match->>'name', 'role', v_match->>'role');
  end if;
  update orgs set identity = identity || jsonb_build_object('attempts', v_attempts, 'last_try', jsonb_build_object('at', now(),
    'last4', right(regexp_replace(coalesce(p_last4, ''), '\D', '', 'g'), 4), 'result', 'no_match')) where id = p_org;
  return jsonb_build_object('verified', false, 'reason', case when not v_registered then 'not_account_holder'
    when jsonb_array_length(v_people) = 0 then 'no_directors_on_record' else 'no_match' end,
    'people', (select coalesce(jsonb_agg(x->>'name'), '[]'::jsonb) from jsonb_array_elements(v_people) x));
end $$;

-- identity_slip: as before, and no NIN slip is added while a handover waits for TaxStreem.
create or replace function public.identity_slip(p_org uuid, p_path text, p_file_name text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs;
begin
  m := private.require(p_org, null);
  if not private.perm_of(m, 'owner') then raise exception 'Only the owner adds the NIN slip.' using errcode = '42501'; end if;
  if coalesce(p_path, '') !~ ('^' || p_org::text || '/kyc/nin-slip-[A-Za-z0-9._-]{1,120}$') then raise exception 'Upload the NIN slip again.'; end if;
  select * into o from orgs where id = p_org;
  if o.identity_status in ('verified', 'approved', 'not_required') then
    raise exception 'The business''s identity is already confirmed.';
  end if;
  if private.handover_pending(o.identity_status, o.identity) then raise exception '%', private.handover_pending_text(o.identity_status); end if;
  update orgs set identity = identity || jsonb_build_object('slip', jsonb_build_object('path', p_path, 'file_name', left(coalesce(p_file_name, 'NIN slip'), 120),
    'at', now(), 'read', false)) where id = p_org;
  return public.identity_state(p_org);
end $$;

-- svc_identity_slip: as before, and a slip read while a handover waits for TaxStreem (one added before it) changes nothing.
create or replace function public.svc_identity_slip(p_user uuid, p_org uuid, p_extract jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; v_people jsonb; v_match jsonb; v_self text; v_registered boolean; v_is_slip boolean := coalesce((p_extract->>'is_nin_document')::boolean, false);
begin
  if not private.acts_as_owner(p_org, p_user) then
    raise exception 'Only the owner adds the NIN slip.' using errcode = '42501';
  end if;
  select * into o from orgs where id = p_org for update;
  if private.handover_pending(o.identity_status, o.identity) then raise exception '%', private.handover_pending_text(o.identity_status); end if;
  if o.identity->'slip' is null then raise exception 'Add the NIN slip first.'; end if;
  v_registered := exists (select 1 from kyc_profiles k where k.org_id = p_org and k.status = 'submitted' and k.source = 'cac');
  v_people := private.identity_people(p_org);
  if not v_registered then
    select coalesce(nullif(trim(raw_user_meta_data->>'full_name'), ''), '') into v_self from auth.users where id = p_user;
    v_people := jsonb_build_array(jsonb_build_object('role', 'owner', 'name', v_self, 'surname', '', 'given', ''));
  end if;
  v_match := case when v_is_slip then private.identity_match(p_extract->>'first_name', p_extract->>'middle_name', p_extract->>'surname', v_people) end;
  update orgs set
    identity = identity || jsonb_build_object('slip', (identity->'slip') || jsonb_build_object('read', true, 'read_at', now(),
      'name', left(concat_ws(' ', p_extract->>'first_name', p_extract->>'middle_name', p_extract->>'surname'), 160),
      'last4', right(regexp_replace(coalesce(p_extract->>'nin_last4', ''), '\D', '', 'g'), 4), 'is_nin_document', v_is_slip,
      'warnings', coalesce(p_extract->'warnings', '[]'::jsonb)))
      || case when v_match is not null then jsonb_build_object('method', 'slip', 'matched', v_match->>'name', 'matched_role', v_match->>'role',
           'last4', right(regexp_replace(coalesce(p_extract->>'nin_last4', ''), '\D', '', 'g'), 4), 'at', now(), 'by', p_user) else '{}'::jsonb end,
    identity_status = case when v_match is not null then 'verified' else 'review' end
  where id = p_org;
  return private.identity_json(p_org, true);
end $$;

-- identity_json: as before, and whether the identity waits on a handover TaxStreem has not approved (reason 'handover',
-- handover_review), so the screens and the edge functions stop before any NIN or slip check.
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
    'review', o.identity->'review',
    'reason', o.identity->>'reason', 'handover_review', private.handover_pending(o.identity_status, o.identity));
end $$;

-- identity_reviews: as before, each business also with why it is reviewed (reason 'handover') and the handover (its id,
-- when, and the identity's status before it).
create or replace function public.identity_reviews() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  if not private.is_reviewer() then raise exception 'Only TaxStreem reviewers see this.' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'org_id', o.id, 'business', o.name, 'rc_number', o.rc_number, 'legal_form', o.legal_form, 'status', o.identity_status,
      'people', (select coalesce(jsonb_agg(jsonb_build_object('name', x->>'name', 'role', x->>'role')), '[]'::jsonb) from jsonb_array_elements(private.identity_people(o.id)) x),
      'slip', o.identity->'slip', 'review', o.identity->'review', 'attempts', coalesce((o.identity->>'attempts')::int, 0),
      'reason', o.identity->>'reason', 'handover', o.identity->'handover',
      'owner', (select jsonb_build_object('name', mb.display_name, 'email', coalesce(mb.email, u.email)) from members mb left join auth.users u on u.id = mb.user_id
        where mb.org_id = o.id and mb.role = 'owner' limit 1))
    order by o.identity_status <> 'review', (o.identity->'slip'->>'read_at') desc nulls last), '[]'::jsonb)
    from orgs o
    where o.identity_status = 'review'
       or (o.identity_status in ('approved', 'rejected') and (o.identity->'review'->>'at')::timestamptz > now() - interval '30 days'));
end $$;

-- review_identity: as before; a handover is approved as 'approved' only when the business's identity was confirmed before
-- it (verified, approved or not needed), else it goes back to 'pending' (the new owner does the NIN check as any owner)
-- and is no longer a handover review. A handover rejected stays one, and its 'handover' flag stays open (TaxStreem decides
-- it again); approved, the flag is resolved.
create or replace function public.review_identity(p_org uuid, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; v_handover boolean; v_status text;
begin
  if not private.is_reviewer() then raise exception 'Only TaxStreem reviewers decide this.' using errcode = '42501'; end if;
  select * into o from orgs where id = p_org for update;
  if not found then raise exception 'Business not found.'; end if;
  if o.identity_status not in ('review', 'approved', 'rejected') then raise exception 'There is nothing to review for %.', o.name; end if;
  if not p_approve and length(trim(coalesce(p_note, ''))) < 5 then raise exception 'Say why, so the business knows what to do next.'; end if;
  v_handover := coalesce(o.identity->>'reason' = 'handover', false);
  v_status := case when not p_approve then 'rejected'
    when v_handover and coalesce(o.identity->'handover'->>'status_before', '') not in ('verified', 'approved', 'not_required') then 'pending'
    else 'approved' end;
  update orgs set identity_status = v_status,
    identity = case when v_status = 'pending' then identity - 'reason' else identity end
      || jsonb_build_object('review', jsonb_build_object('approved', p_approve, 'note', nullif(left(trim(coalesce(p_note, '')), 500), ''),
      'at', now(), 'by', auth.uid()))
  where id = p_org;
  perform private.audit('review_identity', p_org::text, jsonb_build_object('approved', p_approve, 'note', nullif(trim(coalesce(p_note, '')), '')));
  if v_handover then
    update practice_mandate_flags set resolved_at = now(), resolved_by = auth.uid(),
      resolution_note = left('Identity review: approved' || coalesce('. ' || nullif(trim(p_note), ''), ''), 1000)
    where p_approve and kind = 'handover' and detail->>'org_id' = p_org::text and resolved_at is null;
    perform private.notify_perm(p_org, 'owner', 'identity',
      case when v_status = 'approved' then 'Payments are open' when v_status = 'pending' then 'TaxStreem checked the handover'
        else 'TaxStreem did not accept the handover' end,
      case when v_status = 'approved' then 'TaxStreem checked the handover of the business. Your wallet, payment links and payouts are ready.'
        when v_status = 'pending' then 'Confirm a director''s NIN in Settings, Business identity, to open payments.'
        else coalesce(nullif(trim(p_note), ''), 'Contact TaxStreem about it.') end, '/settings#identity', 'identity-' || p_org);
    return jsonb_build_object('status', v_status);
  end if;
  perform private.notify_perm(p_org, 'owner', 'identity', case when p_approve then 'Payments are open' else 'We could not confirm the NIN slip' end,
    case when p_approve then 'TaxStreem confirmed the director''s identity. Your wallet, payment links and payouts are ready.'
      else coalesce(nullif(trim(p_note), ''), 'Check the NIN slip and try again.') end, '/settings#identity', 'identity-' || p_org);
  return jsonb_build_object('status', case when p_approve then 'approved' else 'rejected' end);
end $$;

-- document_may_delete: as before, and no stored file of a business kept read-only is deleted until its records are past
-- their date.
create or replace function private.document_may_delete(p_path text) returns boolean
language sql stable security definer set search_path = public, private as $$
  select exists (select 1 from documents d join members mm on mm.org_id = d.org_id and mm.user_id = auth.uid() and mm.status = 'active'
    where d.path = p_path and d.source = 'upload' and (d.uploaded_by = mm.id or private.perm_of(mm, 'owner')))
    and not exists (select 1 from documents d join orgs o on o.id = d.org_id
                    where d.path = p_path and o.read_only_at is not null and coalesce(o.retain_until >= current_date, true))
$$;

-- ---------------------------------------------------------------------------
-- 5. Deletion while the records are kept
-- ---------------------------------------------------------------------------
-- Raises while a business's records are kept (up to and including the date).
create or replace function private.require_not_kept(p_retain date) returns void
language plpgsql stable set search_path = public, private as $$
begin
  if p_retain >= current_date then
    raise exception 'This business is kept until % (engagement records).', to_char(p_retain, 'DD Mon YYYY');
  end if;
end $$;

create or replace function private.orgs_retention_guard() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.require_not_kept(old.retain_until);
  return old;
end $$;

create trigger orgs_retention_guard before delete on public.orgs for each row execute function private.orgs_retention_guard();

-- admin_business_delete: as before, a business whose records are kept is refused first.
create or replace function public.admin_business_delete(p_org uuid, p_confirm text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_staff(); o public.orgs; v jsonb; v_org uuid; r record; v_audit bigint; v_removed uuid[];
  norm text := lower(regexp_replace(trim(coalesce(p_confirm, '')), '\s+', ' ', 'g'));
begin
  select * into o from orgs where id = p_org for update;
  if not found then raise exception 'This business is no longer on Counta.'; end if;
  perform private.require_not_kept(o.retain_until);
  if norm = '' or norm <> lower(regexp_replace(trim(o.name), '\s+', ' ', 'g')) then
    raise exception 'Type the business''s name exactly as it shows, to confirm.';
  end if;
  v := private.business_purge_plan(p_org);
  if not (v->>'can_delete')::boolean then raise exception '%', v->'blockers'->>0; end if;
  select coalesce(array_agg(x::uuid), '{}') into v_removed from jsonb_array_elements_text(v->'removed') x;

  perform set_config('app.allow_purge', 'on', true);
  for v_org in select x::uuid from jsonb_array_elements_text(v->'orgs') x loop
    -- Keys its tools kept in Vault.
    delete from vault.secrets where id in (select secret_id from integrations where org_id = v_org and secret_id is not null
                                           union select hook_secret_id from integrations where org_id = v_org and hook_secret_id is not null);
    -- Tables that keep their rows (with no business) when a business goes: deleted here, so nothing of it stays behind.
    for r in select c.conrelid::regclass as tbl, a.attname as col from pg_constraint c
             join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
             where c.contype = 'f' and c.confrelid = 'public.orgs'::regclass and c.confdeltype <> 'c' and cardinality(c.conkey) = 1 loop
      execute format('delete from %s where %I = $1', r.tbl, r.col) using v_org;
    end loop;
    delete from orgs where id = v_org;
  end loop;
  perform set_config('app.allow_purge', 'off', true);

  insert into admin_audit (user_id, action, target, detail)
  values (v_uid, 'delete_business', p_org::text, jsonb_build_object('name', o.name,
    'logins_removed', cardinality(v_removed), 'logins_kept', (select count(*) from jsonb_array_elements(v->'people') p where p->>'login' = 'kept'),
    'samples', jsonb_array_length(v->'samples'), 'counts', v->'counts',
    'pending', jsonb_build_object('users', to_jsonb(v_removed), 'orgs', v->'orgs', 'mono', v->'mono', 'whatsapp', v->'whatsapp')))
  returning id into v_audit;
  return jsonb_build_object('ok', true, 'audit_id', v_audit, 'name', o.name, 'logins', cardinality(v_removed));
end $$;

-- admin_business_delete_preview: as before, a business whose records are kept is refused first.
create or replace function public.admin_business_delete_preview(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v jsonb;
begin
  perform private.require_staff();
  perform private.require_not_kept((select retain_until from orgs where id = p_org));
  v := private.business_purge_plan(p_org);
  if v is null then raise exception 'This business is no longer on Counta.'; end if;
  return v - 'mono' - 'whatsapp' - 'removed' - 'orgs';
end $$;

-- ---------------------------------------------------------------------------
-- 6. Export
-- ---------------------------------------------------------------------------
-- The business tables exported: the business's own row (orgs), and every public table with org_id but the logs, counters'
-- sources, sessions and KYC (CAC directors stay with the owner; documents under kyc/ are left out by the edge function).
create or replace function private.export_tables() returns text[]
language sql stable set search_path = public, private as $$
  select coalesce(array_agg(t order by t), '{}')
  from (
    select 'orgs'::text as t
    union
    select c.table_name::text
    from information_schema.columns c join information_schema.tables tb using (table_schema, table_name)
    where c.table_schema = 'public' and c.column_name = 'org_id' and tb.table_type = 'BASE TABLE'
      and c.table_name <> all (array['activity_log', 'kyc_profiles', 'usage_events', 'ai_logs', 'shop_hits', 'sso_logins', 'chat_links',
        'whatsapp_sessions', 'portal_logins', 'pit_etax_logins'])) x
$$;

-- A row as exported: values under a secret's key replaced by "[redacted]" (private.redact_key), nothing cut short (an
-- export keeps whole values, unlike the activity log's private.redact).
create or replace function private.export_redact(p jsonb) returns jsonb
language sql immutable set search_path = public, private as $$
  select case when p is null or jsonb_typeof(p) <> 'object' then p else (
    select coalesce(jsonb_object_agg(e.key, case when private.redact_key(e.key) then to_jsonb('[redacted]'::text) else e.value end), '{}'::jsonb)
    from jsonb_each(p) e) end
$$;

-- The page an export continues after: p_after (the last key of the page before, a JSON array of one value per key column,
-- each readable as that column's type in p_types, as next gave it), or null for the first page. Anything else is refused
-- in plain words.
create or replace function private.export_after(p_after text, p_types text[]) returns jsonb
language plpgsql stable set search_path = public, private as $$
declare v jsonb; i int;
begin
  if p_after is null then return null; end if;
  begin
    v := p_after::jsonb;
    if jsonb_typeof(v) is distinct from 'array' or jsonb_array_length(v) <> cardinality(p_types) then raise exception 'not a page'; end if;
    for i in 1 .. cardinality(p_types) loop
      if jsonb_typeof(v->(i - 1)) not in ('string', 'number') then raise exception 'not a page'; end if;
      -- The types come from the catalog (the table's key) or are fixed by the caller.
      execute format('select ($1)::%s', p_types[i]) using v->>(i - 1);
    end loop;
  exception when others then
    raise exception 'That page of the export is not valid.';
  end;
  return v;
end $$;

-- A partner starts the export of a full-mandate client's records, or of one kept read-only after its mandate ended: what
-- the practice edge function exports. {org_id, client_id, practice_id, tables}.
create or replace function public.practice_export_begin(p_client uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare c public.practice_clients; m public.practice_members;
begin
  select * into c from practice_clients where id = p_client;
  if c.id is null or c.practice_id is null then raise exception 'Client not found.'; end if;
  m := private.practice_require(c.practice_id, true);
  if m.role <> 'partner' then raise exception 'Only a partner exports a client''s records.' using errcode = '42501'; end if;
  if not (c.mode = 'full' and (private.director_mandate_open(c.id, c.practice_id) or (c.status = 'ended' and c.end_kind = 'ended'))) then
    raise exception 'Only a business the firm runs under full mandate, or one kept read-only after its mandate ended, is exported here.';
  end if;
  return jsonb_build_object('org_id', c.org_id, 'client_id', c.id, 'practice_id', c.practice_id, 'tables', to_jsonb(private.export_tables()));
end $$;

-- A page of a table's rows for the business (for orgs, the business's own row), in the order of the table's primary key:
-- each row with its secrets redacted (private.export_redact), the names of income-tax people taken from the CAC record
-- hidden, and the business row without its identity check, directors and company secretary (as the activity log keeps
-- them out). p_after is the last key of the page before (a JSON array of its values, as next gave it); p_limit 1 to
-- 1,000. {rows, next (null on the last page)}.
create or replace function public.svc_export_rows(p_org uuid, p_table text, p_after text, p_limit int) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_limit int := least(greatest(coalesce(p_limit, 1000), 1), 1000); v_cols text[]; v_types text[]; v_after jsonb; v_order text; v_key text;
  v_where text := ''; v_rows jsonb; v_next jsonb;
begin
  if p_table is null or not (p_table = any (private.export_tables())) then raise exception 'That table is not exported.'; end if;
  select array_agg(a.attname::text order by k.n), array_agg(format_type(a.atttypid, a.atttypmod) order by k.n) into v_cols, v_types
  from pg_index i cross join lateral unnest(i.indkey) with ordinality k(attnum, n)
  join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
  where i.indrelid = format('public.%I', p_table)::regclass and i.indisprimary;
  if v_cols is null then raise exception 'That table has no primary key.'; end if;
  select string_agg(format('t.%I', x), ', ' order by n) into v_order from unnest(v_cols) with ordinality u(x, n);
  v_key := 'jsonb_build_array(' || v_order || ')';
  v_after := private.export_after(p_after, v_types);
  if v_after is not null then
    select format(' and (%s) > (%s)', v_order, string_agg(format('($2->>%s)::%s', n - 1, ty), ', ' order by n)) into v_where
    from unnest(v_types) with ordinality u(ty, n);
  end if;
  execute format(
    'select coalesce(jsonb_agg(r.j order by r.n), ''[]''::jsonb), (array_agg(r.k order by r.n desc))[1]
     from (select private.export_redact(private.activity_hide(to_jsonb(t), case
                    when %1$L = ''pit_people'' and to_jsonb(t)->>''source'' = ''cac'' then array[''name'']
                    when %1$L = ''orgs'' then array[''identity'', ''directors'', ''company_secretary''] end)) as j,
                  %2$s as k, row_number() over (order by %3$s) as n
           from public.%4$I t where %5$s%6$s order by %3$s limit %7$s) r',
    p_table, v_key, v_order, p_table, case when p_table = 'orgs' then 't.id = $1' else 't.org_id = $1' end, v_where, v_limit)
    into v_rows, v_next using p_org, v_after;
  return jsonb_build_object('rows', v_rows, 'next', case when jsonb_array_length(v_rows) = v_limit then v_next::text end);
end $$;

-- A page of the business's ledger, line by line in date order: {rows: [{date, journal_ref, account_code, account_name,
-- debit, credit, memo}], next}, paged as svc_export_rows (the key: date, journal number, line).
create or replace function public.svc_export_ledger(p_org uuid, p_after text default null, p_limit int default 1000) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_limit int := least(greatest(coalesce(p_limit, 1000), 1), 1000); v_after jsonb := private.export_after(p_after, array['date', 'integer', 'bigint']); v_rows jsonb; v_next jsonb;
begin
  select coalesce(jsonb_agg(x.j order by x.n), '[]'::jsonb), (array_agg(x.k order by x.n desc))[1] into v_rows, v_next
  from (select jsonb_build_object('date', j.entry_date, 'journal_ref', j.ref, 'account_code', l.account_code,
                 'account_name', private.account_name(p_org, l.account_code), 'debit', l.debit, 'credit', l.credit, 'memo', coalesce(l.memo, j.memo)) as j,
               jsonb_build_array(j.entry_date, j.je_no, l.id) as k, row_number() over (order by j.entry_date, j.je_no, l.id) as n
        from journals j join journal_lines l on l.journal_id = j.id
        where j.org_id = p_org
          and (v_after is null or (j.entry_date, j.je_no, l.id) > ((v_after->>0)::date, (v_after->>1)::int, (v_after->>2)::bigint))
        order by j.entry_date, j.je_no, l.id
        limit v_limit) x;
  return jsonb_build_object('rows', v_rows, 'next', case when jsonb_array_length(v_rows) = v_limit then v_next::text end);
end $$;

-- A page of the business's activity log, oldest first (as written: redacted, CAC details kept out): {rows, next}, paged as
-- svc_export_rows (the key: the entry's id).
create or replace function public.svc_export_activity(p_org uuid, p_after text default null, p_limit int default 1000) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_limit int := least(greatest(coalesce(p_limit, 1000), 1), 1000); v_after jsonb := private.export_after(p_after, array['bigint']); v_rows jsonb; v_next jsonb;
begin
  select coalesce(jsonb_agg(x.j order by x.n), '[]'::jsonb), (array_agg(x.k order by x.n desc))[1] into v_rows, v_next
  from (select jsonb_build_object('id', a.id, 'at', a.at, 'practice_id', a.practice_id, 'actor_name', a.actor_name, 'source', a.source,
                 'action', a.action, 'entity', a.entity, 'entity_id', a.entity_id, 'label', a.label, 'before', a.before, 'after', a.after,
                 'changed', a.changed) as j,
               jsonb_build_array(a.id) as k, row_number() over (order by a.id) as n
        from activity_log a
        where a.org_id = p_org and (v_after is null or a.id > (v_after->>0)::bigint)
        order by a.id
        limit v_limit) x;
  return jsonb_build_object('rows', v_rows, 'next', case when jsonb_array_length(v_rows) = v_limit then v_next::text end);
end $$;

-- The export file is stored: p {path (practice/<practice>/exports/<client>/<name>.zip), sha256, bytes} is logged.
create or replace function public.svc_export_done(p_client uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients; v_path text := coalesce(p->>'path', ''); v_sha text := lower(coalesce(p->>'sha256', ''));
begin
  select * into c from practice_clients where id = p_client;
  if c.id is null or c.practice_id is null then raise exception 'Client not found.'; end if;
  if v_path !~ ('^practice/' || c.practice_id || '/exports/' || c.id || '/[A-Za-z0-9._-]+\.zip$') then raise exception 'That is not an export path for this client.'; end if;
  if v_sha !~ '^[0-9a-f]{64}$' then raise exception 'The export''s SHA-256 is not valid.'; end if;
  if jsonb_typeof(p->'bytes') is distinct from 'number' or (p->>'bytes')::numeric <= 0 or (p->>'bytes')::numeric <> trunc((p->>'bytes')::numeric) then
    raise exception 'The export''s size is not valid.';
  end if;
  perform private.activity_event(c.org_id, 'export', 'The business''s records were exported',
    jsonb_build_object('practice_id', c.practice_id, 'client_id', c.id, 'path', v_path, 'sha256', v_sha, 'bytes', (p->>'bytes')::bigint));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- 7. The firm's settings for a business it runs
-- ---------------------------------------------------------------------------
-- A business the practice runs under full mandate now, for its leads.
create or replace function private.mandate_client_require(p_client uuid) returns public.practice_clients
language plpgsql set search_path = public, private as $$
declare c public.practice_clients;
begin
  c := private.practice_client_require(p_client, true);
  if not private.director_mandate_open(c.id, c.practice_id) then
    raise exception 'Only for a business the firm runs under full mandate.';
  end if;
  return c;
end $$;

-- Leads choose whether the business sends its documents (send) or only downloads them (download_only).
create or replace function public.practice_set_send_mode(p_client uuid, p_mode text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients;
begin
  c := private.mandate_client_require(p_client);
  if p_mode is null or p_mode not in ('send', 'download_only') then raise exception 'Choose send or download_only.'; end if;
  update orgs set send_mode = p_mode where id = c.org_id;
  return jsonb_build_object('client_id', c.id, 'send_mode', p_mode);
end $$;

-- Leads choose where the business's alerts go: one of the firm's addresses (private.firm_email), or none (the business's
-- contact, as before).
create or replace function public.practice_set_alert_email(p_client uuid, p_email text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients; v_email text := nullif(lower(trim(coalesce(p_email, ''))), '');
begin
  c := private.mandate_client_require(p_client);
  if v_email is not null and (v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 254 or private.firm_email(c.practice_id, v_email) is null) then
    raise exception 'Use an address of the firm.';
  end if;
  update practice_clients set alert_email = v_email where id = c.id;
  return jsonb_build_object('client_id', c.id, 'alert_email', v_email);
end $$;

-- ---------------------------------------------------------------------------
-- 8. The portal's reads
-- ---------------------------------------------------------------------------
-- practice_home: as before, each client also with its mode, intake, due-diligence state, read-only state and retention;
-- the full mandates kept read-only after they ended are listed with them (status ended; not again under past_clients); and
-- whether the firm may run full mandates (can_full).
create or replace function public.practice_home(p_practice uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare me public.practice_members; pr public.practices; v_lead boolean; v_email text;
begin
  me := private.practice_require(p_practice);
  v_lead := me.role in ('partner', 'manager');
  select * into pr from practices where id = p_practice;
  select lower(email) into v_email from auth.users where id = auth.uid();
  return jsonb_build_object(
    'practice', to_jsonb(pr) - 'created_by',
    'me', private.practice_member_json(me, true),
    'members', (select coalesce(jsonb_agg(private.practice_member_json(x, v_lead) order by x.status, x.role, x.display_name), '[]'::jsonb)
      from practice_members x where x.practice_id = p_practice and (v_lead or x.status = 'active')),
    'clients', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'status', c.status, 'initiated_by', c.initiated_by, 'org_id', c.org_id,
        'business_name', coalesce(o.name, c.business_name), 'invite_email', case when v_lead then c.invite_email end, 'invite_name', c.invite_name,
        'services', c.services, 'billing', c.billing, 'note', c.note, 'created_at', c.created_at, 'started_at', c.started_at, 'sent_at', c.sent_at,
        'tin', o.tin, 'vat_registered', o.vat_registered,
        'assigned', (select coalesce(jsonb_agg(a.member_id), '[]'::jsonb) from practice_assignments a where a.client_id = c.id),
        'requests_open', (select count(*) from practice_requests r where r.client_id = c.id and r.status in ('open', 'answered')),
        'answered', (select count(*) from practice_requests r where r.client_id = c.id and r.status = 'answered'),
        'health', case when c.status = 'active' then private.client_health(c.org_id) end,
        'mode', c.mode, 'intake_id', c.intake_id,
        'dd_incomplete', coalesce((select i.dd_incomplete from practice_intakes i where i.id = c.intake_id), false),
        'read_only', o.read_only_at is not null, 'retain_until', o.retain_until)
        order by c.status = 'active' desc, coalesce(o.name, c.business_name)), '[]'::jsonb)
      from practice_clients c left join orgs o on o.id = c.org_id
      where c.practice_id = p_practice and (c.status in ('active', 'invited') or (c.status = 'ended' and c.end_kind = 'ended'))
        and (v_lead or exists (select 1 from practice_assignments a where a.client_id = c.id and a.member_id = me.id))),
    'past_clients', case when v_lead then (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'status', c.status, 'business_name', coalesce(o.name, c.business_name),
        'invite_email', c.invite_email, 'ended_at', c.ended_at) order by c.ended_at desc nulls last), '[]'::jsonb)
      from practice_clients c left join orgs o on o.id = c.org_id where c.practice_id = p_practice and c.status in ('ended', 'declined')
        and c.end_kind is distinct from 'ended' and coalesce(c.ended_at, c.created_at) > now() - interval '180 days') else '[]'::jsonb end,
    -- Businesses that asked this person to be their accountant: taken on into a practice from here.
    'business_invitations', case when v_lead then (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'business', c.business_name, 'services', c.services,
        'billing', c.billing, 'note', c.note, 'created_at', c.created_at) order by c.created_at desc), '[]'::jsonb)
      from practice_clients c where c.status = 'requested' and lower(c.invite_email) = v_email and coalesce(c.token_expires, c.created_at + interval '14 days') > now())
      else '[]'::jsonb end,
    'billing', case when v_lead then jsonb_build_object(
      'paying_for', (select count(*) from subscriptions s join practice_clients c on c.org_id = s.org_id and c.practice_id = p_practice and c.status = 'active'
        where s.paid_by = p_practice),
      'card', (select jsonb_build_object('id', k.id, 'last4', k.last4, 'brand', k.brand, 'expiry', k.expiry) from subscription_cards k
        where k.practice_id = p_practice and k.active order by k.created_at desc limit 1)) end,
    'plans', (select coalesce(jsonb_agg(jsonb_build_object('id', pl.id, 'name', pl.name, 'price_month', pl.price_month, 'price_year', pl.price_year) order by pl.sort, pl.price_month), '[]'::jsonb)
      from plans pl where pl.active and pl.public and pl.price_month > 0),
    'can_full', private.practice_can_full(p_practice));
end $$;

-- practice_client: as before; client also with its mode, how it ended and its intake; the opposing parties the firm
-- recorded for it (for leads); and for a full mandate (or one kept read-only after it ended) the mandate: how the business
-- sends, its alert address, engagement partner, director's confirmation, read-only state and retention, whether payments
-- are open, the latest director's request, handover and engagement letter (the director's and the handover's contact
-- details for leads only).
create or replace function public.practice_client(p_client uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare c public.practice_clients; me public.practice_members; o public.orgs; v_lead boolean;
begin
  c := private.practice_client_require(p_client);
  me := private.practice_me(c.practice_id);
  v_lead := me.role in ('partner', 'manager');
  select * into o from orgs where id = c.org_id;
  return jsonb_build_object(
    'client', jsonb_build_object('id', c.id, 'status', c.status, 'initiated_by', c.initiated_by, 'org_id', c.org_id, 'business_name', coalesce(o.name, c.business_name),
      'invite_email', c.invite_email, 'invite_name', c.invite_name, 'services', c.services, 'billing', c.billing, 'note', c.note, 'created_at', c.created_at,
      'started_at', c.started_at, 'ended_at', c.ended_at, 'practice_id', c.practice_id, 'mode', c.mode, 'end_kind', c.end_kind, 'intake_id', c.intake_id),
    'business', case when o.id is not null then jsonb_build_object('name', o.name, 'tin', o.tin, 'rc_number', o.rc_number, 'vat_registered', o.vat_registered,
      'fiscal_year_start', o.fiscal_year_start, 'books_start', o.books_start, 'address', o.address, 'phone', o.phone, 'email', o.email,
      'owner', (select jsonb_build_object('name', mb.display_name, 'email', coalesce(mb.email, u.email)) from members mb left join auth.users u on u.id = mb.user_id
                where mb.org_id = o.id and mb.role = 'owner' order by mb.created_at limit 1)) end,
    'me', private.practice_member_json(me, true),
    'my_seat', (select jsonb_build_object('member_id', mb.id, 'status', mb.status, 'role', mb.role) from members mb where mb.org_id = c.org_id and mb.user_id = auth.uid()),
    'health', case when c.status = 'active' then private.client_health(c.org_id) end,
    'team', (select coalesce(jsonb_agg(jsonb_build_object('member', private.practice_member_json(x, false),
        'assigned', x.role in ('partner', 'manager') or exists (select 1 from practice_assignments a where a.client_id = c.id and a.member_id = x.id),
        'seat', (select mb.status from members mb where mb.org_id = c.org_id and mb.practice_id = c.practice_id and mb.user_id = x.user_id)) order by x.role, x.display_name), '[]'::jsonb)
      from practice_members x where x.practice_id = c.practice_id and x.status = 'active'),
    'requests', (select coalesce(jsonb_agg(private.practice_request_json(r) order by r.status = 'answered' desc, r.status = 'open' desc, r.created_at desc), '[]'::jsonb)
      from practice_requests r where r.client_id = c.id),
    'notes', (select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'text', n.text, 'created_at', n.created_at,
        'author', (select display_name from practice_members where id = n.author_id), 'mine', n.author_id = me.id) order by n.created_at desc), '[]'::jsonb)
      from (select * from practice_notes where client_id = c.id order by created_at desc limit 100) n),
    'files', case when c.status = 'active' then (select coalesce(jsonb_agg(private.filing_version_brief(v) order by v.created_at desc), '[]'::jsonb)
      from filing_versions v where v.id in (select id from filing_versions where org_id = c.org_id order by created_at desc limit 60)) else '[]'::jsonb end,
    'can_lead', v_lead,
    'opposing_parties', case when v_lead then (select coalesce(jsonb_agg(jsonb_build_object('id', op.id, 'name', op.name, 'rc_number', op.rc_number, 'note', op.note)
        order by op.created_at, op.id), '[]'::jsonb)
      from practice_opposing_parties op where op.client_id = c.id and op.practice_id = c.practice_id) else '[]'::jsonb end,
    'mandate', case when c.mode = 'full' and o.id is not null and (c.status = 'active' or (c.status = 'ended' and c.end_kind = 'ended')) then jsonb_build_object(
      'send_mode', o.send_mode, 'alert_email', c.alert_email, 'engagement_partner_id', c.engagement_partner_id,
      'director_confirmed_at', o.director_confirmed_at, 'read_only_at', o.read_only_at, 'retain_until', o.retain_until,
      'payments_open', private.payments_open(o.id),
      'director', (select jsonb_build_object('status', d.status, 'name', case when v_lead then d.name end, 'email', case when v_lead then d.email end,
          'sent_at', d.created_at, 'confirmed_at', d.confirmed_at)
        from practice_director_confirmations d where d.client_id = c.id order by d.created_at desc, d.id limit 1),
      'handover', (select jsonb_build_object('id', h.id, 'email', case when v_lead then h.email end, 'status', h.status, 'sent_at', h.sent_at)
        from practice_handovers h where h.client_id = c.id order by h.created_at desc, h.id limit 1),
      'letter', (select jsonb_build_object('id', l.id, 'status', l.status) from engagement_letters l
        where l.intake_id = c.intake_id or l.client_id = c.id
        order by l.status in ('completed', 'uploaded') desc, l.created_at desc, l.id limit 1)) end);
end $$;

-- ---------------------------------------------------------------------------
-- 9. The admin portal's mandates page
-- ---------------------------------------------------------------------------
-- TaxStreem's reviewers and admins: director confirmations waiting for review (the practice, the business, the director
-- and where they answered from), the practices that may run or run full mandates, and the open flags.
create or replace function public.admin_mandates() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_staff(false);
  return jsonb_build_object(
    'reviews', (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'status', d.status, 'created_at', d.created_at,
        'practice', jsonb_build_object('id', pr.id, 'name', pr.name),
        'business', jsonb_build_object('client_id', c.id, 'org_id', c.org_id, 'name', coalesce(o.name, c.business_name)),
        'director', jsonb_build_object('name', d.name, 'email', d.email, 'phone', d.phone),
        'ip', d.ip, 'ua', d.ua, 'reason', d.flags->>'review_reason') order by d.created_at, d.id), '[]'::jsonb)
      from practice_director_confirmations d join practices pr on pr.id = d.practice_id
      join practice_clients c on c.id = d.client_id left join orgs o on o.id = c.org_id
      where d.status = 'review'),
    'practices', (select coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'name', pr.name,
        'full_clients', (select count(*) from practice_clients c where c.practice_id = pr.id and c.mode = 'full' and c.status = 'active'),
        'suspended_at', pr.mandate_suspended_at, 'partner_verified', private.partner_verified(pr.id)) order by pr.name, pr.id), '[]'::jsonb)
      from practices pr
      where private.partner_verified(pr.id) or pr.mandate_suspended_at is not null
        or exists (select 1 from practice_clients c where c.practice_id = pr.id and c.mode = 'full')),
    'flags', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'kind', f.kind, 'detail', f.detail, 'created_at', f.created_at,
        'practice', jsonb_build_object('id', pr.id, 'name', pr.name),
        'intake', case when i.id is not null then jsonb_build_object('id', i.id, 'legal_name', i.legal_name, 'rc_number', i.rc_number, 'tax_id', i.tax_id) end,
        'business', case when c.id is not null then jsonb_build_object('client_id', c.id, 'org_id', c.org_id, 'name', coalesce(o.name, c.business_name)) end)
        order by f.created_at desc, f.id), '[]'::jsonb)
      from practice_mandate_flags f join practices pr on pr.id = f.practice_id
      left join practice_intakes i on i.id = f.intake_id
      left join practice_clients c on c.id = f.client_id left join orgs o on o.id = c.org_id
      where f.resolved_at is null));
end $$;

-- A reviewer or admin resolves an open flag with a note of 5 characters or more (a confirmation waiting for review is
-- decided with admin_director_decide instead). Audited.
create or replace function public.admin_mandate_flag_resolve(p_id uuid, p_note text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_note text := trim(coalesce(p_note, '')); f public.practice_mandate_flags;
begin
  perform private.require_staff(false);
  if length(v_note) < 5 then raise exception 'Write a note of at least 5 characters.'; end if;
  if length(v_note) > 1000 then raise exception 'Keep the note under 1,000 characters.'; end if;
  select * into f from practice_mandate_flags where id = p_id for update;
  if f.id is null then raise exception 'Flag not found.'; end if;
  if f.resolved_at is not null then raise exception 'That flag is resolved already.'; end if;
  if f.kind = 'director_review' and exists (select 1 from practice_director_confirmations d
                                            where d.id = private.uuid_of(f.detail->>'confirmation_id') and d.status = 'review') then
    raise exception 'Accept or decline the director''s confirmation instead.';
  end if;
  update practice_mandate_flags set resolved_at = now(), resolved_by = auth.uid(), resolution_note = v_note where id = f.id
  returning * into f;
  perform private.audit('mandate_flag_resolved', f.id::text, jsonb_build_object('kind', f.kind, 'practice_id', f.practice_id, 'note', v_note));
  return jsonb_build_object('id', f.id, 'resolved_at', f.resolved_at);
end $$;

-- ---------------------------------------------------------------------------
-- 10. Grants
-- ---------------------------------------------------------------------------
-- core.sql grants every private function to authenticated: the helpers this migration creates or redefines are not
-- callable by the signed-in person.
revoke all on function private.outbound_check(uuid, text, text, text), private.seat_exempt(uuid, uuid), private.meter_usage(uuid, text),
  private.enforce_plan(), private.practice_sync_seats(uuid), private.org_pause_all(uuid), private.require_not_kept(date), private.orgs_retention_guard(),
  private.export_tables(), private.mandate_client_require(uuid), private.export_redact(jsonb), private.export_after(text, text[]),
  private.payments_open(uuid), private.require_payments_open(uuid), private.handover_pending(text, jsonb), private.handover_pending_text(text),
  private.identity_json(uuid, boolean)
  from public, anon, authenticated;
revoke execute on function public.practice_handover_start(uuid, jsonb), public.practice_handover_accept(text), public.practice_set_engagement_partner(uuid, uuid),
  public.practice_end_mandate(uuid, jsonb), public.practice_export_begin(uuid), public.practice_set_send_mode(uuid, text),
  public.practice_set_alert_email(uuid, text), public.admin_mandates(), public.admin_mandate_flag_resolve(uuid, text)
  from public, anon;
grant execute on function public.practice_handover_start(uuid, jsonb), public.practice_handover_accept(text), public.practice_set_engagement_partner(uuid, uuid),
  public.practice_end_mandate(uuid, jsonb), public.practice_export_begin(uuid), public.practice_set_send_mode(uuid, text),
  public.practice_set_alert_email(uuid, text), public.admin_mandates(), public.admin_mandate_flag_resolve(uuid, text)
  to authenticated;
revoke all on function public.svc_export_rows(uuid, text, text, int), public.svc_export_ledger(uuid, text, int), public.svc_export_activity(uuid, text, int),
  public.svc_export_done(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.svc_export_rows(uuid, text, text, int), public.svc_export_ledger(uuid, text, int), public.svc_export_activity(uuid, text, int),
  public.svc_export_done(uuid, jsonb)
  to service_role;
