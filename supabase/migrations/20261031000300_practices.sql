-- Counta · the accountant portal
--
-- An accountant runs a practice (a firm, or a sole practitioner as a firm of one) with its own staff: partners and
-- managers see every client; staff see the clients they are assigned. A practice and a business connect by invitation,
-- either way round: the practice invites a business owner by email, or a business invites its accountant by email. Once
-- connected, the practice's people get an Accountant's place in the business (members.practice_id marks it), so the
-- business's own role settings and the database's checks govern what they may do there, and the owner can end it at any
-- time. The portal (/practice) shows every client's state: questions in the books, bank lines waiting, tax deadlines,
-- requests to the client, the files the accountant changed, and who pays for Counta.
--
-- Licences. Each accountant may give an ICAN, ANAN or CITN membership number; TaxStreem checks it in the admin portal.
-- Until then their work carries the word "unverified".
--
-- Changed files. An accountant downloads a tax return or the financial statements, changes them, and uploads them again
-- (filing_versions). Counta compares the upload with its own figures and shows every change; the accountant books the
-- differences with an adjusting journal and accepts responsibility for the changes in their own name. From then on
-- Counta uses the accountant's file for that return or year, with a note of who changed it.
--
-- Paying for Counta. Either side may pay a business's plan: subscriptions.paid_by names the practice that pays, with its
-- own card (subscription_cards.practice_id).

-- ---------------------------------------------------------------------------
-- 1. Practices, their people and their clients
-- ---------------------------------------------------------------------------
create table if not exists public.practices (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 2 and 120),
  kind text not null default 'firm' check (kind in ('firm', 'sole')),
  email text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone text check (phone is null or length(phone) <= 30),
  address text check (address is null or length(address) <= 300),
  state text check (state is null or length(state) <= 40),
  firm_reg text check (firm_reg is null or length(firm_reg) <= 40),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists practices_created_by on public.practices(created_by);
alter table public.practices enable row level security;
revoke all on public.practices from anon, authenticated;

create table if not exists public.practice_members (
  id uuid primary key default gen_random_uuid(),
  practice_id uuid not null references public.practices(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  email text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  display_name text not null check (length(trim(display_name)) between 2 and 80),
  role text not null default 'staff' check (role in ('partner', 'manager', 'staff')),
  status text not null default 'invited' check (status in ('active', 'invited', 'disabled')),
  licence_body text check (licence_body in ('ICAN', 'ANAN', 'CITN')),
  licence_no text check (licence_no is null or licence_no ~ '^[A-Za-z0-9/ .-]{2,30}$'),
  licence_status text not null default 'none' check (licence_status in ('none', 'pending', 'verified', 'rejected')),
  licence_note text,
  verified_by uuid references auth.users(id) on delete set null,
  verified_at timestamptz,
  token_hash text,
  token_expires timestamptz,
  invited_by uuid references public.practice_members(id) on delete set null,
  created_at timestamptz not null default now()
);
create unique index if not exists practice_members_user on public.practice_members(practice_id, user_id) where user_id is not null;
create unique index if not exists practice_members_email on public.practice_members(practice_id, lower(email));
create unique index if not exists practice_members_token on public.practice_members(token_hash) where token_hash is not null;
create index if not exists practice_members_user_id on public.practice_members(user_id);
create index if not exists practice_members_invited_by on public.practice_members(invited_by);
create index if not exists practice_members_verified_by on public.practice_members(verified_by);
create index if not exists practice_members_pending on public.practice_members(licence_status) where licence_status = 'pending';
alter table public.practice_members enable row level security;
revoke all on public.practice_members from anon, authenticated;

-- invited: the practice asked a business owner; requested: a business asked an accountant; active; ended; declined.
create table if not exists public.practice_clients (
  id uuid primary key default gen_random_uuid(),
  practice_id uuid references public.practices(id) on delete cascade,
  org_id uuid references public.orgs(id) on delete cascade,
  status text not null check (status in ('invited', 'requested', 'active', 'ended', 'declined')),
  initiated_by text not null check (initiated_by in ('practice', 'business')),
  invite_email text,
  invite_name text,
  business_name text,
  services text[] not null default '{bookkeeping,vat,wht,cit,statements}',
  billing text not null default 'business' check (billing in ('business', 'practice')),
  note text check (note is null or length(note) <= 500),
  token_hash text,
  token_expires timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  accepted_by uuid references auth.users(id) on delete set null,
  ended_by uuid references auth.users(id) on delete set null,
  started_at timestamptz,
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  check (status = 'requested' or practice_id is not null),
  check (status = 'invited' or status = 'declined' or org_id is not null)
);
create unique index if not exists practice_clients_live on public.practice_clients(practice_id, org_id) where status = 'active';
create unique index if not exists practice_clients_token on public.practice_clients(token_hash) where token_hash is not null;
create index if not exists practice_clients_org on public.practice_clients(org_id);
create index if not exists practice_clients_practice on public.practice_clients(practice_id, status);
create index if not exists practice_clients_email on public.practice_clients(lower(invite_email)) where status in ('invited', 'requested');
create index if not exists practice_clients_created_by on public.practice_clients(created_by);
create index if not exists practice_clients_accepted_by on public.practice_clients(accepted_by);
create index if not exists practice_clients_ended_by on public.practice_clients(ended_by);
alter table public.practice_clients enable row level security;
revoke all on public.practice_clients from anon, authenticated;

-- Staff who work on a client (partners and managers work on every client).
create table if not exists public.practice_assignments (
  client_id uuid not null references public.practice_clients(id) on delete cascade,
  member_id uuid not null references public.practice_members(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (client_id, member_id)
);
create index if not exists practice_assignments_member on public.practice_assignments(member_id);
alter table public.practice_assignments enable row level security;
revoke all on public.practice_assignments from anon, authenticated;

-- What the accountant asks the business for (a statement, receipts, an answer), and the answer.
create table if not exists public.practice_requests (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.practice_clients(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  practice_id uuid not null references public.practices(id) on delete cascade,
  kind text not null default 'document' check (kind in ('document', 'question', 'approval')),
  title text not null check (length(trim(title)) between 3 and 140),
  detail text check (detail is null or length(detail) <= 1500),
  due_date date,
  status text not null default 'open' check (status in ('open', 'answered', 'done', 'cancelled')),
  answer text check (answer is null or length(answer) <= 2000),
  file_path text,
  file_name text,
  asked_by uuid references public.practice_members(id) on delete set null,
  answered_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  answered_at timestamptz,
  closed_at timestamptz
);
create index if not exists practice_requests_client on public.practice_requests(client_id, status);
create index if not exists practice_requests_org on public.practice_requests(org_id, status);
create index if not exists practice_requests_practice on public.practice_requests(practice_id);
create index if not exists practice_requests_asked_by on public.practice_requests(asked_by);
create index if not exists practice_requests_answered_by on public.practice_requests(answered_by);
alter table public.practice_requests enable row level security;
revoke all on public.practice_requests from anon, authenticated;

-- The practice's own notes on a client; the business never sees them.
create table if not exists public.practice_notes (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.practice_clients(id) on delete cascade,
  author_id uuid references public.practice_members(id) on delete set null,
  text text not null check (length(trim(text)) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index if not exists practice_notes_client on public.practice_notes(client_id, created_at desc);
create index if not exists practice_notes_author on public.practice_notes(author_id);
alter table public.practice_notes enable row level security;
revoke all on public.practice_notes from anon, authenticated;

-- An accountant's place in a client's business comes from the practice.
alter table public.members add column if not exists practice_id uuid references public.practices(id) on delete set null;
create index if not exists members_practice on public.members(practice_id) where practice_id is not null;

-- Paying for a client's plan.
alter table public.subscription_cards alter column org_id drop not null;
alter table public.subscription_cards add column if not exists practice_id uuid references public.practices(id) on delete cascade;
alter table public.subscription_cards drop constraint if exists subscription_cards_owner_check;
alter table public.subscription_cards add constraint subscription_cards_owner_check check (num_nonnulls(org_id, practice_id) = 1);
create index if not exists subscription_cards_practice on public.subscription_cards(practice_id) where practice_id is not null and active;
alter table public.subscriptions add column if not exists paid_by uuid references public.practices(id) on delete set null;
create index if not exists subscriptions_paid_by on public.subscriptions(paid_by) where paid_by is not null;
alter table public.subscription_charges add column if not exists practice_id uuid references public.practices(id) on delete set null;
create index if not exists subscription_charges_practice on public.subscription_charges(practice_id) where practice_id is not null;

-- ---------------------------------------------------------------------------
-- 2. Who is who
-- ---------------------------------------------------------------------------
create or replace function private.practice_me(p_practice uuid) returns public.practice_members
language sql stable security definer set search_path = public, private as $$
  select * from practice_members where practice_id = p_practice and user_id = auth.uid() and status = 'active'
$$;

-- The person's place in the practice; p_lead asks for a partner or manager.
create or replace function private.practice_require(p_practice uuid, p_lead boolean default false) returns public.practice_members
language plpgsql stable security definer set search_path = public, private as $$
declare m public.practice_members;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  m := private.practice_me(p_practice);
  if m.id is null then raise exception 'You are not on this practice.' using errcode = '42501'; end if;
  if p_lead and m.role not in ('partner', 'manager') then raise exception 'Only partners and managers of the practice do this.' using errcode = '42501'; end if;
  return m;
end $$;

-- A client the person may see: a partner or manager any; staff those they are assigned.
create or replace function private.practice_client_require(p_client uuid, p_lead boolean default false) returns public.practice_clients
language plpgsql stable security definer set search_path = public, private as $$
declare c public.practice_clients; m public.practice_members;
begin
  select * into c from practice_clients where id = p_client;
  if not found or c.practice_id is null then raise exception 'Client not found.'; end if;
  m := private.practice_require(c.practice_id, p_lead);
  if m.role = 'staff' and not exists (select 1 from practice_assignments where client_id = c.id and member_id = m.id) then
    raise exception 'You are not assigned to this client.' using errcode = '42501';
  end if;
  return c;
end $$;

create or replace function private.licence_text(m public.practice_members) returns text
language sql immutable set search_path = public as $$
  select case when m.licence_body is not null and m.licence_no is not null
    then m.licence_body || ' ' || m.licence_no || case m.licence_status when 'verified' then ' (verified by TaxStreem)' when 'rejected' then ' (not confirmed)' else ' (unverified)' end
    else 'no professional licence number given' end
$$;

-- Tells a practice's partners and managers.
create or replace function private.practice_notify(p_practice uuid, p_title text, p_body text, p_url text) returns void
language plpgsql security definer set search_path = public, private as $$
declare u uuid;
begin
  for u in select user_id from practice_members where practice_id = p_practice and status = 'active' and role in ('partner', 'manager') and user_id is not null loop
    perform private.notify(null, u, 'practice', p_title, p_body, p_url, null);
  end loop;
end $$;

-- The accountants' places in a client's business, as the link and the assignments say: added, or switched off.
create or replace function private.practice_sync_seats(p_client uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients; pm public.practice_members; ex public.members; p jsonb; v_wanted boolean; v_firm text;
begin
  select * into c from practice_clients where id = p_client;
  if not found or c.org_id is null or c.practice_id is null then return; end if;
  if c.status <> 'active' then
    update members set status = 'disabled' where org_id = c.org_id and practice_id = c.practice_id and status <> 'disabled' and role <> 'owner';
    return;
  end if;
  p := private.role_perms(c.org_id, 'accountant');
  select name into v_firm from practices where id = c.practice_id;
  for pm in select * from practice_members where practice_id = c.practice_id loop
    v_wanted := pm.status = 'active' and pm.user_id is not null
      and (pm.role in ('partner', 'manager') or exists (select 1 from practice_assignments a where a.client_id = c.id and a.member_id = pm.id));
    ex := null;
    if pm.user_id is not null then select * into ex from members where org_id = c.org_id and user_id = pm.user_id; end if;
    if ex.id is null then select * into ex from members where org_id = c.org_id and user_id is null and lower(email) = lower(pm.email); end if;
    if v_wanted then
      if ex.id is null then
        insert into members (org_id, user_id, email, display_name, role, title, status, practice_id,
          p_record_sales, p_receive_stock, p_count_stock, p_approve_adjustments, p_edit_prices, p_approve_pos, p_transfer_stock, p_see_margins,
          p_issue_stock, p_keep_books, p_make_payments, p_add_items, p_approve_payments, p_file_tax, p_manage_team, p_manage_settings)
        values (c.org_id, pm.user_id, lower(pm.email), pm.display_name, 'accountant', left('Accountant, ' || v_firm, 80), 'active', c.practice_id,
          (p->>'record_sales')::boolean, (p->>'receive_stock')::boolean, (p->>'count_stock')::boolean, (p->>'approve_adjustments')::boolean,
          (p->>'edit_prices')::boolean, (p->>'approve_pos')::boolean, (p->>'transfer_stock')::boolean, (p->>'see_margins')::boolean,
          (p->>'issue_stock')::boolean, (p->>'keep_books')::boolean, (p->>'make_payments')::boolean, (p->>'add_items')::boolean,
          (p->>'approve_payments')::boolean, (p->>'file_tax')::boolean, (p->>'manage_team')::boolean, (p->>'manage_settings')::boolean);
      elsif ex.role <> 'owner' and (ex.practice_id = c.practice_id or (ex.practice_id is null and (ex.role = 'accountant' or ex.user_id is null))) then
        -- Their own earlier place (an invitation, or an accountant's place) becomes the practice's.
        update members set user_id = pm.user_id, status = 'active', practice_id = c.practice_id, role = 'accountant', perm_overrides = case when ex.role = 'accountant' then perm_overrides else '{}'::jsonb end
        where id = ex.id;
        perform private.apply_member_perms(ex.id);
        update member_invites set token_hash = null where member_id = ex.id;
      end if;
    elsif ex.id is not null and ex.practice_id = c.practice_id and ex.status <> 'disabled' then
      update members set status = 'disabled' where id = ex.id;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Setting up a practice, its people and its licences
-- ---------------------------------------------------------------------------
-- p: {name, kind, email, phone, address, state, firm_reg, my_name, licence_body, licence_no}
create or replace function public.create_practice(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_id uuid; v_email text; v_name text;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if (select count(*) from practice_members where user_id = auth.uid() and role = 'partner') >= 3 then raise exception 'You run three practices already.'; end if;
  select lower(email), coalesce(nullif(trim(raw_user_meta_data->>'full_name'), ''), nullif(trim(raw_user_meta_data->>'name'), ''), split_part(email, '@', 1))
    into v_email, v_name from auth.users where id = auth.uid();
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'Enter the practice''s name.'; end if;
  insert into practices (name, kind, email, phone, address, state, firm_reg, created_by)
  values (trim(p->>'name'), coalesce(nullif(p->>'kind', ''), 'firm'), nullif(lower(trim(p->>'email')), ''), nullif(trim(p->>'phone'), ''), nullif(trim(p->>'address'), ''),
    nullif(trim(p->>'state'), ''), nullif(trim(p->>'firm_reg'), ''), auth.uid())
  returning id into v_id;
  insert into practice_members (practice_id, user_id, email, display_name, role, status, licence_body, licence_no, licence_status)
  values (v_id, auth.uid(), v_email, left(coalesce(nullif(trim(p->>'my_name'), ''), v_name), 80), 'partner', 'active', nullif(p->>'licence_body', ''),
    nullif(trim(p->>'licence_no'), ''), case when nullif(trim(p->>'licence_no'), '') is not null and nullif(p->>'licence_body', '') is not null then 'pending' else 'none' end);
  return public.practice_home(v_id);
end $$;

-- p: the same fields as create_practice, for a partner.
create or replace function public.update_practice(p_practice uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.practice_members;
begin
  m := private.practice_require(p_practice, true);
  if m.role <> 'partner' then raise exception 'Only a partner changes the practice''s details.' using errcode = '42501'; end if;
  update practices set name = coalesce(nullif(trim(p->>'name'), ''), name), kind = coalesce(nullif(p->>'kind', ''), kind),
    email = case when p ? 'email' then nullif(lower(trim(p->>'email')), '') else email end, phone = case when p ? 'phone' then nullif(trim(p->>'phone'), '') else phone end,
    address = case when p ? 'address' then nullif(trim(p->>'address'), '') else address end, state = case when p ? 'state' then nullif(trim(p->>'state'), '') else state end,
    firm_reg = case when p ? 'firm_reg' then nullif(trim(p->>'firm_reg'), '') else firm_reg end, updated_at = now()
  where id = p_practice;
  return public.practice_home(p_practice);
end $$;

-- A person's own licence number, which waits for TaxStreem to check it.
create or replace function public.practice_set_licence(p_practice uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.practice_members; v_body text := nullif(p->>'licence_body', ''); v_no text := nullif(trim(p->>'licence_no'), '');
begin
  m := private.practice_require(p_practice);
  if v_body is not null and v_body not in ('ICAN', 'ANAN', 'CITN') then raise exception 'Choose ICAN, ANAN or CITN.'; end if;
  if (v_body is null) <> (v_no is null) then raise exception 'Give the body and the membership number together.'; end if;
  update practice_members set licence_body = v_body, licence_no = v_no,
    licence_status = case when v_no is null then 'none' when v_body = licence_body and v_no = licence_no and licence_status = 'verified' then 'verified' else 'pending' end,
    licence_note = case when v_no is distinct from licence_no then null else licence_note end
  where id = m.id;
  return public.practice_home(p_practice);
end $$;

-- p: {email, name, role}
create or replace function public.practice_invite_member(p_practice uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare m public.practice_members; v_email text := lower(trim(coalesce(p->>'email', ''))); v_role text := coalesce(nullif(p->>'role', ''), 'staff'); v_id uuid;
begin
  m := private.practice_require(p_practice, true);
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email address does not look right.'; end if;
  if v_role not in ('partner', 'manager', 'staff') then raise exception 'Choose partner, manager or staff.'; end if;
  if v_role = 'partner' and m.role <> 'partner' then raise exception 'Only a partner adds a partner.' using errcode = '42501'; end if;
  if exists (select 1 from practice_members where practice_id = p_practice and lower(email) = v_email) then raise exception '% is already on the practice.', v_email; end if;
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'Enter the person''s name.'; end if;
  insert into practice_members (practice_id, email, display_name, role, status, invited_by)
  values (p_practice, v_email, left(trim(p->>'name'), 80), v_role, 'invited', m.id) returning id into v_id;
  return v_id;
end $$;

-- p: {role, status: active|disabled}
create or replace function public.practice_update_member(p_member uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare t public.practice_members; m public.practice_members; c record;
begin
  select * into t from practice_members where id = p_member;
  if not found then raise exception 'Person not found.'; end if;
  m := private.practice_require(t.practice_id, true);
  if t.id = m.id then raise exception 'Ask another partner to change your own place.'; end if;
  if (t.role = 'partner' or p->>'role' = 'partner') and m.role <> 'partner' then raise exception 'Only a partner changes a partner.' using errcode = '42501'; end if;
  if coalesce(p->>'role', t.role) not in ('partner', 'manager', 'staff') or coalesce(p->>'status', t.status) not in ('active', 'invited', 'disabled') then raise exception 'Unknown role or status.'; end if;
  if p->>'status' = 'active' and t.status = 'invited' then raise exception '% joins by accepting the invitation.', t.display_name; end if;
  update practice_members set role = coalesce(nullif(p->>'role', ''), role), status = coalesce(nullif(p->>'status', ''), status),
    token_hash = case when p->>'status' = 'disabled' then null else token_hash end where id = t.id;
  for c in select id from practice_clients where practice_id = t.practice_id and status = 'active' loop perform private.practice_sync_seats(c.id); end loop;
  return public.practice_home(t.practice_id);
end $$;

-- Who works on a client.
create or replace function public.practice_assign(p_client uuid, p_member uuid, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients;
begin
  c := private.practice_client_require(p_client, true);
  if not exists (select 1 from practice_members where id = p_member and practice_id = c.practice_id) then raise exception 'Person not found.'; end if;
  if p_on then insert into practice_assignments (client_id, member_id) values (c.id, p_member) on conflict do nothing;
  else delete from practice_assignments where client_id = c.id and member_id = p_member; end if;
  perform private.practice_sync_seats(c.id);
  return public.practice_client(c.id);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Invitations, either way round
-- ---------------------------------------------------------------------------
alter table public.practice_members add column if not exists sent_count int not null default 0;
alter table public.practice_members add column if not exists sent_at timestamptz;
alter table public.practice_clients add column if not exists sent_count int not null default 0;
alter table public.practice_clients add column if not exists sent_at timestamptz;

-- p: {email, name, business_name, services, billing, note}: the practice asks a business owner to connect their business.
create or replace function public.practice_invite_client(p_practice uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare m public.practice_members; v_email text := lower(trim(coalesce(p->>'email', ''))); v_id uuid; v_services text[];
begin
  m := private.practice_require(p_practice, true);
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter the business owner''s email address.'; end if;
  if (select count(*) from practice_clients where practice_id = p_practice and created_at > now() - interval '1 day') >= 50 then
    raise exception 'That is fifty invitations today. Try again tomorrow.';
  end if;
  select coalesce(array_agg(distinct x) filter (where x in ('bookkeeping', 'vat', 'wht', 'cit', 'statements', 'payroll', 'advisory')), '{bookkeeping,vat,wht,cit,statements}')
    into v_services from jsonb_array_elements_text(coalesce(p->'services', '[]'::jsonb)) x;
  if exists (select 1 from practice_clients where practice_id = p_practice and status = 'invited' and lower(invite_email) = v_email) then
    raise exception 'An invitation to % is already waiting. Send it again from the list.', v_email;
  end if;
  insert into practice_clients (practice_id, status, initiated_by, invite_email, invite_name, business_name, services, billing, note, created_by)
  values (p_practice, 'invited', 'practice', v_email, nullif(left(trim(p->>'name'), 80), ''), nullif(left(trim(p->>'business_name'), 120), ''), v_services,
    case when p->>'billing' = 'practice' then 'practice' else 'business' end, nullif(left(trim(p->>'note'), 500), ''), auth.uid())
  returning id into v_id;
  return v_id;
end $$;

-- p: {email, name, firm, services, billing, note}: a business asks its accountant to connect.
create or replace function public.business_invite_accountant(p_org uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_email text := lower(trim(coalesce(p->>'email', ''))); v_id uuid; v_services text[];
begin
  m := private.require(p_org, 'manage_team');
  if (select is_sample from orgs where id = p_org) then raise exception 'The sample business cannot connect an accountant. Use your own business.'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter your accountant''s email address.'; end if;
  if (select count(*) from practice_clients where org_id = p_org and created_at > now() - interval '1 day') >= 10 then raise exception 'That is enough invitations for today.'; end if;
  if exists (select 1 from practice_clients where org_id = p_org and status = 'requested' and lower(invite_email) = v_email) then
    raise exception 'An invitation to % is already waiting. Send it again from the list.', v_email;
  end if;
  select coalesce(array_agg(distinct x) filter (where x in ('bookkeeping', 'vat', 'wht', 'cit', 'statements', 'payroll', 'advisory')), '{bookkeeping,vat,wht,cit,statements}')
    into v_services from jsonb_array_elements_text(coalesce(p->'services', '[]'::jsonb)) x;
  insert into practice_clients (org_id, status, initiated_by, invite_email, invite_name, business_name, services, billing, note, created_by)
  values (p_org, 'requested', 'business', v_email, nullif(left(trim(p->>'name'), 80), ''), (select name from orgs where id = p_org), v_services,
    case when p->>'billing' = 'practice' then 'practice' else 'business' end,
    nullif(left(trim(concat_ws(' · ', nullif(trim(p->>'firm'), ''), nullif(trim(p->>'note'), ''))), 500), ''), auth.uid())
  returning id into v_id;
  return v_id;
end $$;

-- Before the messaging function sends an invitation email: whether this person may send it (and not too often).
-- p_kind: member (practice staff), client (to a business owner), accountant (from a business to its accountant).
create or replace function public.practice_invite_check(p_kind text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare t public.practice_members; c public.practice_clients;
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
  else
    raise exception 'Unknown invitation.';
  end if;
  return jsonb_build_object('ok', true, 'kind', p_kind, 'id', p_id);
end $$;

-- For the messaging function as it sends the email: a fresh link (good for fourteen days; earlier links stop working) and
-- what the email says.
create or replace function public.svc_practice_invite_link(p_kind text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare t public.practice_members; c public.practice_clients; pr public.practices; v_token text; v_app text; v_by text; v_by_email text;
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

-- What a link is for, shown before the person signs in.
create or replace function public.practice_invite_preview(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare t public.practice_members; c public.practice_clients; pr public.practices; v_hash text;
begin
  if coalesce(p_token, '') !~ '^p[mc]_[0-9a-f]{48}$' then return jsonb_build_object('status', 'invalid'); end if;
  v_hash := encode(extensions.digest(p_token, 'sha256'), 'hex');
  if p_token like 'pm_%' then
    select * into t from practice_members where token_hash = v_hash;
    if not found then return jsonb_build_object('status', 'invalid'); end if;
    select * into pr from practices where id = t.practice_id;
    return jsonb_build_object('kind', 'member', 'status', case when t.status <> 'invited' then 'used' when t.token_expires < now() then 'expired' else 'open' end,
      'practice', pr.name, 'email', t.email, 'name', t.display_name, 'role', t.role);
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

-- Accepting. p: {org_id} for a business owner choosing the business; {practice_id} for an accountant choosing the practice.
create or replace function public.practice_accept(p_token text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare t public.practice_members; c public.practice_clients; v_email text; v_hash text; v_org uuid; v_practice uuid; cl record; mb public.members;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if coalesce(p_token, '') !~ '^p[mc]_[0-9a-f]{48}$' then raise exception 'This invitation link is not complete. Open it from the email again.'; end if;
  v_hash := encode(extensions.digest(p_token, 'sha256'), 'hex');
  select lower(email) into v_email from auth.users where id = auth.uid();
  if p_token like 'pm_%' then
    select * into t from practice_members where token_hash = v_hash for update;
    if not found then raise exception 'This invitation link has been replaced or used. Ask for a new one.'; end if;
    if t.status <> 'invited' then raise exception 'This invitation has already been used.'; end if;
    if t.token_expires < now() then raise exception 'This invitation has expired. Ask the practice for a new one.'; end if;
    if v_email is distinct from lower(t.email) then raise exception 'This invitation is for %. Sign in with that email address to join.', t.email using errcode = '42501'; end if;
    if exists (select 1 from practice_members where practice_id = t.practice_id and user_id = auth.uid()) then raise exception 'You are already on this practice.'; end if;
    update practice_members set user_id = auth.uid(), status = 'active', token_expires = least(token_expires, now()) where id = t.id;
    for cl in select id from practice_clients where practice_id = t.practice_id and status = 'active' loop perform private.practice_sync_seats(cl.id); end loop;
    perform private.practice_notify(t.practice_id, t.display_name || ' joined the practice', 'They can now work on the clients you assign.', '/practice/team');
    return jsonb_build_object('kind', 'member', 'practice_id', t.practice_id);
  end if;
  select * into c from practice_clients where token_hash = v_hash for update;
  if not found then raise exception 'This invitation link has been replaced or used. Ask for a new one.'; end if;
  if c.status not in ('invited', 'requested') then raise exception 'This invitation has already been used.'; end if;
  if c.token_expires < now() then raise exception 'This invitation has expired. Ask for a new one.'; end if;
  if c.status = 'invited' then
    -- A business owner connects one of their businesses to the practice.
    v_org := nullif(p->>'org_id', '')::uuid;
    if v_org is null then raise exception 'Choose the business to connect.'; end if;
    mb := private.require(v_org, null);
    if mb.role <> 'owner' then raise exception 'Only the owner of the business connects it to an accountant.' using errcode = '42501'; end if;
    if (select is_sample from orgs where id = v_org) then raise exception 'The sample business cannot be connected. Choose your own business.'; end if;
    if exists (select 1 from practice_clients where practice_id = c.practice_id and org_id = v_org and status = 'active') then
      raise exception 'That business is already connected to this practice.';
    end if;
    update practice_clients set org_id = v_org, status = 'active', started_at = now(), accepted_by = auth.uid(), token_expires = least(token_expires, now()),
      business_name = (select name from orgs where id = v_org) where id = c.id returning * into c;
    perform private.practice_sync_seats(c.id);
    perform private.practice_notify(c.practice_id, c.business_name || ' accepted your invitation', 'It is now one of your clients.', '/practice/clients/' || c.id);
    return jsonb_build_object('kind', 'client', 'org_id', v_org, 'client_id', c.id);
  end if;
  -- An accountant takes on a business that invited them.
  if v_email is distinct from lower(c.invite_email) then raise exception 'This invitation is for %. Sign in with that email address.', c.invite_email using errcode = '42501'; end if;
  v_practice := nullif(p->>'practice_id', '')::uuid;
  if v_practice is null then raise exception 'Set up your practice first, then accept.'; end if;
  perform private.practice_require(v_practice, true);
  if exists (select 1 from practice_clients where practice_id = v_practice and org_id = c.org_id and status = 'active') then
    raise exception 'That business is already one of your clients.';
  end if;
  update practice_clients set practice_id = v_practice, status = 'active', started_at = now(), accepted_by = auth.uid(), token_expires = least(token_expires, now()) where id = c.id returning * into c;
  perform private.practice_sync_seats(c.id);
  perform private.notify_perm(c.org_id, 'manage_team', 'practice', (select name from practices where id = v_practice) || ' is now your accountant',
    'They can keep the books and prepare tax returns. See and change what they may do in Settings, Your accountant.', '/settings#accountant', 'practice-' || c.id);
  return jsonb_build_object('kind', 'accountant', 'org_id', c.org_id, 'client_id', c.id, 'practice_id', v_practice);
end $$;

create or replace function public.practice_decline(p_token text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients; v_hash text := encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if p_token like 'pm_%' then
    update practice_members set status = 'disabled', token_expires = least(token_expires, now()) where token_hash = v_hash and status = 'invited'
      and lower(email) = (select lower(email) from auth.users where id = auth.uid());
    return jsonb_build_object('declined', found);
  end if;
  select * into c from practice_clients where token_hash = v_hash and status in ('invited', 'requested');
  if not found then return jsonb_build_object('declined', false); end if;
  if c.status = 'requested' and lower(c.invite_email) <> (select lower(email) from auth.users where id = auth.uid()) then
    raise exception 'This invitation is for %.', c.invite_email using errcode = '42501';
  end if;
  update practice_clients set status = 'declined', token_expires = least(token_expires, now()), ended_at = now(), ended_by = auth.uid() where id = c.id;
  if c.status = 'invited' then perform private.practice_notify(c.practice_id, 'An invitation was declined', coalesce(c.business_name, c.invite_email) || ' said no for now.', '/practice/clients');
  else perform private.notify_perm(c.org_id, 'manage_team', 'practice', 'Your accountant declined', c.invite_email || ' declined the invitation.', '/settings#accountant', null); end if;
  return jsonb_build_object('declined', true);
end $$;

-- Withdrawing an invitation not yet accepted (whoever sent it).
create or replace function public.practice_withdraw(p_client uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients;
begin
  select * into c from practice_clients where id = p_client;
  if not found or c.status not in ('invited', 'requested') then raise exception 'Nothing is waiting to withdraw.'; end if;
  if c.status = 'invited' then perform private.practice_require(c.practice_id, true); else perform private.require(c.org_id, 'manage_team'); end if;
  update practice_clients set status = 'declined', token_hash = null, ended_at = now(), ended_by = auth.uid() where id = c.id;
  return jsonb_build_object('withdrawn', true);
end $$;

-- Ending the work together, from either side. Their places in the business switch off at once; a plan the practice paid
-- for runs to the end of its period and then stops.
create or replace function public.practice_end(p_client uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients; v_side text;
begin
  select * into c from practice_clients where id = p_client;
  if not found or c.status <> 'active' then raise exception 'That work has already ended.'; end if;
  if c.practice_id is not null and (private.practice_me(c.practice_id)).role in ('partner', 'manager') then v_side := 'practice';
  else perform private.require(c.org_id, 'manage_team'); v_side := 'business'; end if;
  update practice_clients set status = 'ended', ended_at = now(), ended_by = auth.uid() where id = c.id;
  perform private.practice_sync_seats(c.id);
  update subscriptions set cancel_at_period_end = true, updated_at = now() where org_id = c.org_id and paid_by = c.practice_id;
  if v_side = 'practice' then
    perform private.notify_perm(c.org_id, 'manage_team', 'practice', (select name from practices where id = c.practice_id) || ' has stopped working on your books',
      'Their places in your business are switched off.' || case when exists (select 1 from subscriptions where org_id = c.org_id and paid_by = c.practice_id)
        then ' They paid for your Counta plan: it runs to the end of this period, then choose how to pay in Settings, Subscription.' else '' end,
      '/settings#accountant', 'practice-end-' || c.id);
  else
    perform private.practice_notify(c.practice_id, c.business_name || ' ended your work on its books', 'Your places in the business are switched off.', '/practice/clients');
  end if;
  return jsonb_build_object('ended', true);
end $$;

-- Who pays for the client's plan from now on.
create or replace function public.practice_set_billing(p_client uuid, p_billing text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients;
begin
  c := private.practice_client_require(p_client, true);
  if p_billing not in ('business', 'practice') then raise exception 'Choose who pays.'; end if;
  update practice_clients set billing = p_billing where id = c.id;
  if p_billing = 'business' and exists (select 1 from subscriptions where org_id = c.org_id and paid_by = c.practice_id) then
    update subscriptions set cancel_at_period_end = true, updated_at = now() where org_id = c.org_id and paid_by = c.practice_id;
    perform private.notify_perm(c.org_id, 'manage_settings', 'plan', 'Your accountant will stop paying for Counta',
      'The plan they paid for runs to the end of this period. Choose how to pay in Settings, Subscription to keep it.', '/settings/subscription', 'practice-bill-' || c.id);
  end if;
  return public.practice_client(c.id);
end $$;

-- ---------------------------------------------------------------------------
-- 5. The portal: the practices a person is on, the practice's clients and their state
-- ---------------------------------------------------------------------------
-- How a client's books and tax stand, for the portal. Counted for the business as a whole: the practice looks after all of it.
create or replace function private.client_health(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_today date := private.local_day(p_org, now()); v_dl jsonb; s public.subscriptions; pl public.plans;
begin
  select coalesce(jsonb_agg(jsonb_build_object('tax', d.tax, 'label', d.label, 'period', d.period, 'due', d.due, 'amount', d.amount, 'url', d.url,
      'overdue', d.due < v_today) order by d.due), '[]'::jsonb)
    into v_dl from private.tax_deadlines(p_org) d;
  select * into s from subscriptions where org_id = p_org;
  select * into pl from plans where id = private.org_plan_id(p_org);
  return jsonb_build_object(
    'deadlines', v_dl,
    'overdue', (select count(*) from jsonb_array_elements(v_dl) x where (x->>'overdue')::boolean),
    'due_soon', (select count(*) from jsonb_array_elements(v_dl) x where not (x->>'overdue')::boolean and (x->>'due')::date <= v_today + 14),
    'bank_lines', (select count(*) from bank_lines where org_id = p_org and status = 'unmatched'),
    'proposals', (select count(*) from ai_proposals where org_id = p_org and status = 'pending'),
    'invoices_overdue', (select count(*) from sales where org_id = p_org and doc_type = 'invoice' and status in ('open', 'partially_paid')
      and journal_id is not null and due_date < v_today),
    'bills_overdue', (select count(*) from bills where org_id = p_org and status in ('approved', 'partially_paid') and due_date < v_today),
    'files_review', (select count(*) from filing_versions where org_id = p_org and status = 'review'),
    'closed_through', private.closed_through(p_org),
    'last_entry', (select max(created_at) from journals where org_id = p_org),
    'plan', jsonb_build_object('name', pl.name, 'status', coalesce(s.status, 'active'), 'period_end', s.current_period_end,
      'paid_by', s.paid_by, 'cancel_at_period_end', coalesce(s.cancel_at_period_end, false), 'billing', coalesce(s.billing, 'month'),
      'price', private.plan_price(pl, coalesce(s.billing, 'month'))));
end $$;

create or replace function private.practice_member_json(m public.practice_members, p_full boolean) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', m.id, 'display_name', m.display_name, 'role', m.role, 'status', m.status, 'joined', m.user_id is not null,
    'licence_body', m.licence_body, 'licence_no', m.licence_no, 'licence_status', m.licence_status, 'licence_text', private.licence_text(m),
    'clients', (select count(*) from practice_assignments a join practice_clients c on c.id = a.client_id where a.member_id = m.id and c.status = 'active'))
    || case when p_full then jsonb_build_object('email', m.email, 'licence_note', m.licence_note, 'sent_at', m.sent_at, 'created_at', m.created_at) else '{}'::jsonb end
$$;

-- The practices the signed-in person is on, and invitations waiting for their email address.
create or replace function public.practices_mine() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_email text;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  select lower(email) into v_email from auth.users where id = auth.uid();
  return jsonb_build_object(
    'practices', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'role', m.role,
        'clients', (select count(*) from practice_clients c where c.practice_id = p.id and c.status = 'active')) order by p.name), '[]'::jsonb)
      from practice_members m join practices p on p.id = m.practice_id where m.user_id = auth.uid() and m.status = 'active'),
    'business_invitations', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'business', c.business_name, 'services', c.services,
        'billing', c.billing, 'note', c.note, 'created_at', c.created_at) order by c.created_at desc), '[]'::jsonb)
      from practice_clients c where c.status = 'requested' and lower(c.invite_email) = v_email and coalesce(c.token_expires, c.created_at + interval '14 days') > now()));
end $$;

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
        'health', case when c.status = 'active' then private.client_health(c.org_id) end)
        order by c.status = 'active' desc, coalesce(o.name, c.business_name)), '[]'::jsonb)
      from practice_clients c left join orgs o on o.id = c.org_id
      where c.practice_id = p_practice and c.status in ('active', 'invited')
        and (v_lead or exists (select 1 from practice_assignments a where a.client_id = c.id and a.member_id = me.id))),
    'past_clients', case when v_lead then (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'status', c.status, 'business_name', coalesce(o.name, c.business_name),
        'invite_email', c.invite_email, 'ended_at', c.ended_at) order by c.ended_at desc nulls last), '[]'::jsonb)
      from practice_clients c left join orgs o on o.id = c.org_id where c.practice_id = p_practice and c.status in ('ended', 'declined')
        and coalesce(c.ended_at, c.created_at) > now() - interval '180 days') else '[]'::jsonb end,
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
      from plans pl where pl.active and pl.public and pl.price_month > 0));
end $$;

-- One client in full: its state, deadlines, requests, the practice's notes, the files changed and who works on it.
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
      'started_at', c.started_at, 'ended_at', c.ended_at, 'practice_id', c.practice_id),
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
    'can_lead', v_lead);
end $$;

-- ---------------------------------------------------------------------------
-- 6. Requests to the business, and the practice's notes
-- ---------------------------------------------------------------------------
create or replace function private.practice_request_json(r public.practice_requests) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', r.id, 'client_id', r.client_id, 'org_id', r.org_id, 'kind', r.kind, 'title', r.title, 'detail', r.detail, 'due_date', r.due_date,
    'status', r.status, 'answer', r.answer, 'file_path', r.file_path, 'file_name', r.file_name, 'created_at', r.created_at, 'answered_at', r.answered_at,
    'closed_at', r.closed_at, 'asked_by', (select display_name from practice_members where id = r.asked_by),
    'practice', (select name from practices where id = r.practice_id),
    'answered_by', (select coalesce(nullif(trim(raw_user_meta_data->>'full_name'), ''), email) from auth.users where id = r.answered_by))
$$;

-- p: {kind: document|question|approval, title, detail, due_date}
create or replace function public.practice_request_create(p_client uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients; me public.practice_members; r public.practice_requests; v_kind text := coalesce(nullif(p->>'kind', ''), 'document');
begin
  c := private.practice_client_require(p_client);
  if c.status <> 'active' then raise exception 'Requests go to businesses you work for.'; end if;
  me := private.practice_me(c.practice_id);
  if v_kind not in ('document', 'question', 'approval') then raise exception 'Choose a document, a question or an approval.'; end if;
  if length(trim(coalesce(p->>'title', ''))) < 3 then raise exception 'Say what you need.'; end if;
  if (select count(*) from practice_requests where client_id = c.id and created_at > now() - interval '1 day') >= 30 then raise exception 'That is thirty requests today for this business.'; end if;
  insert into practice_requests (client_id, org_id, practice_id, kind, title, detail, due_date, asked_by)
  values (c.id, c.org_id, c.practice_id, v_kind, left(trim(p->>'title'), 140), nullif(left(trim(p->>'detail'), 1500), ''), nullif(p->>'due_date', '')::date, me.id)
  returning * into r;
  perform private.notify_perm(c.org_id, 'owner', 'practice', 'Your accountant asks: ' || r.title,
    me.display_name || ' of ' || (select name from practices where id = c.practice_id) || case when r.due_date is not null then ', by ' || to_char(r.due_date, 'DD Mon') else '' end
    || '. Answer in Settings, Your accountant.', '/settings#accountant', 'practice-req-' || r.id);
  return private.practice_request_json(r);
end $$;

-- Closing a request the business answered (done), or one no longer needed (cancelled).
create or replace function public.practice_request_close(p_request uuid, p_status text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.practice_requests;
begin
  select * into r from practice_requests where id = p_request;
  if not found then raise exception 'Request not found.'; end if;
  perform private.practice_client_require(r.client_id);
  if p_status not in ('done', 'cancelled', 'open') then raise exception 'Mark it done, cancelled or open again.'; end if;
  update practice_requests set status = p_status, closed_at = case when p_status = 'open' then null else now() end where id = r.id returning * into r;
  return private.practice_request_json(r);
end $$;

create or replace function public.practice_note_add(p_client uuid, p_text text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients; me public.practice_members;
begin
  c := private.practice_client_require(p_client);
  me := private.practice_me(c.practice_id);
  if length(trim(coalesce(p_text, ''))) = 0 then raise exception 'Write the note first.'; end if;
  insert into practice_notes (client_id, author_id, text) values (c.id, me.id, left(trim(p_text), 2000));
  return public.practice_client(c.id);
end $$;

create or replace function public.practice_note_delete(p_note uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare n public.practice_notes; c public.practice_clients; me public.practice_members;
begin
  select * into n from practice_notes where id = p_note;
  if not found then raise exception 'Note not found.'; end if;
  c := private.practice_client_require(n.client_id);
  me := private.practice_me(c.practice_id);
  if n.author_id is distinct from me.id and me.role not in ('partner', 'manager') then raise exception 'Only the person who wrote a note, or a partner or manager, removes it.' using errcode = '42501'; end if;
  delete from practice_notes where id = n.id;
  return public.practice_client(c.id);
end $$;

-- Taking on a business that asked for this accountant, from inside the portal (the same as following the email's link).
create or replace function public.practice_take_request(p_client uuid, p_practice uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients;
begin
  perform private.practice_require(p_practice, true);
  select * into c from practice_clients where id = p_client and status = 'requested';
  if not found then raise exception 'That invitation was withdrawn or used.'; end if;
  if lower(c.invite_email) <> (select lower(email) from auth.users where id = auth.uid()) then raise exception 'That invitation is for %.', c.invite_email using errcode = '42501'; end if;
  if exists (select 1 from practice_clients where practice_id = p_practice and org_id = c.org_id and status = 'active') then
    raise exception 'That business is already one of your clients.';
  end if;
  update practice_clients set practice_id = p_practice, status = 'active', started_at = now(), accepted_by = auth.uid(), token_expires = least(token_expires, now())
  where id = c.id returning * into c;
  perform private.practice_sync_seats(c.id);
  perform private.notify_perm(c.org_id, 'manage_team', 'practice', (select name from practices where id = p_practice) || ' is now your accountant',
    'They can keep the books and prepare tax returns. See and change what they may do in Settings, Your accountant.', '/settings#accountant', 'practice-' || c.id);
  return jsonb_build_object('client_id', c.id, 'org_id', c.org_id);
end $$;

create or replace function public.practice_decline_request(p_client uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  select * into c from practice_clients where id = p_client and status = 'requested';
  if not found then return jsonb_build_object('declined', false); end if;
  if lower(c.invite_email) <> (select lower(email) from auth.users where id = auth.uid()) then raise exception 'That invitation is for %.', c.invite_email using errcode = '42501'; end if;
  update practice_clients set status = 'declined', ended_at = now(), ended_by = auth.uid(), token_expires = least(token_expires, now()) where id = c.id;
  perform private.notify_perm(c.org_id, 'manage_team', 'practice', 'Your accountant declined', c.invite_email || ' declined the invitation.', '/settings#accountant', null);
  return jsonb_build_object('declined', true);
end $$;

-- ---------------------------------------------------------------------------
-- 7. The business's side: its accountants, their requests and what they may do
-- ---------------------------------------------------------------------------
create or replace function public.org_accountants(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_team boolean;
begin
  m := private.require(p_org, null);
  v_team := private.perm_of(m, 'manage_team');
  return jsonb_build_object(
    'can_manage', v_team,
    'practices', (select coalesce(jsonb_agg(jsonb_build_object('client_id', c.id, 'status', c.status, 'practice', jsonb_build_object('id', pr.id, 'name', pr.name,
        'email', pr.email, 'phone', pr.phone, 'firm_reg', pr.firm_reg, 'kind', pr.kind),
        'partners', (select coalesce(jsonb_agg(jsonb_build_object('name', x.display_name, 'licence', private.licence_text(x), 'verified', x.licence_status = 'verified')), '[]'::jsonb)
          from practice_members x where x.practice_id = pr.id and x.role = 'partner' and x.status = 'active'),
        'people', (select coalesce(jsonb_agg(jsonb_build_object('member_id', mb.id, 'name', mb.display_name, 'status', mb.status, 'title', mb.title,
            'licence', (select private.licence_text(x) from practice_members x where x.practice_id = pr.id and x.user_id = mb.user_id)) order by mb.display_name), '[]'::jsonb)
          from members mb where mb.org_id = p_org and mb.practice_id = pr.id and mb.status = 'active'),
        'services', c.services, 'billing', c.billing, 'started_at', c.started_at,
        'pays_plan', exists (select 1 from subscriptions s where s.org_id = p_org and s.paid_by = pr.id)) order by c.started_at), '[]'::jsonb)
      from practice_clients c join practices pr on pr.id = c.practice_id where c.org_id = p_org and c.status = 'active'),
    'invitations', case when v_team then (select coalesce(jsonb_agg(jsonb_build_object('client_id', c.id, 'email', c.invite_email, 'name', c.invite_name, 'note', c.note,
        'billing', c.billing, 'services', c.services, 'created_at', c.created_at, 'sent_at', c.sent_at,
        'expired', coalesce(c.token_expires, c.created_at + interval '14 days') < now()) order by c.created_at desc), '[]'::jsonb)
      from practice_clients c where c.org_id = p_org and c.status = 'requested') else '[]'::jsonb end,
    'requests', (select coalesce(jsonb_agg(private.practice_request_json(r) order by r.status = 'open' desc, r.due_date nulls last, r.created_at desc), '[]'::jsonb)
      from practice_requests r where r.id in (select id from practice_requests where org_id = p_org and (status in ('open', 'answered') or closed_at > now() - interval '30 days')
        order by created_at desc limit 100)),
    'files', (select coalesce(jsonb_agg(private.filing_version_brief(v) order by v.created_at desc), '[]'::jsonb)
      from filing_versions v where v.id in (select id from filing_versions where org_id = p_org and status in ('review', 'in_use') order by created_at desc limit 40)));
end $$;

-- The business answers a request: words, a file it uploaded to its documents (p: {answer, file_path, file_name}), or both.
create or replace function public.org_request_answer(p_request uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.practice_requests; m public.members; v_path text := nullif(p->>'file_path', '');
begin
  select * into r from practice_requests where id = p_request;
  if not found then raise exception 'Request not found.'; end if;
  m := private.require(r.org_id, null);
  if m.practice_id is not null then raise exception 'The business answers its accountant''s requests.' using errcode = '42501'; end if;
  if r.status not in ('open', 'answered') then raise exception 'That request is closed.'; end if;
  if coalesce(trim(p->>'answer'), '') = '' and v_path is null then raise exception 'Write an answer or attach a file.'; end if;
  if v_path is not null and (split_part(v_path, '/', 1) <> r.org_id::text or split_part(v_path, '/', 2) <> 'requests' or v_path ~ '\.\.') then
    raise exception 'Attach the file through Counta.';
  end if;
  update practice_requests set status = 'answered', answer = nullif(left(trim(p->>'answer'), 2000), ''), file_path = coalesce(v_path, file_path),
    file_name = case when v_path is not null then left(coalesce(nullif(p->>'file_name', ''), split_part(v_path, '/', -1)), 140) else file_name end,
    answered_by = auth.uid(), answered_at = now() where id = r.id returning * into r;
  perform private.practice_notify(r.practice_id, (select name from orgs where id = r.org_id) || ' answered: ' || r.title,
    coalesce(left(r.answer, 140), 'They attached ' || r.file_name || '.'), '/practice/clients/' || r.client_id);
  for m in select mb.* from members mb join practice_assignments a on true join practice_members x on x.id = a.member_id
           where a.client_id = r.client_id and x.user_id = mb.user_id and mb.org_id = r.org_id and x.role = 'staff' loop
    perform private.notify(null, m.user_id, 'practice', (select name from orgs where id = r.org_id) || ' answered: ' || r.title, coalesce(left(r.answer, 140), 'A file is attached.'),
      '/practice/clients/' || r.client_id, null);
  end loop;
  return private.practice_request_json(r);
end $$;

-- ---------------------------------------------------------------------------
-- 8. TaxStreem checks accountants' licence numbers (admin portal)
-- ---------------------------------------------------------------------------
create or replace function public.admin_licences(p_status text default 'pending') returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_staff(false);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', m.display_name, 'email', m.email, 'role', m.role, 'practice', p.name, 'practice_id', p.id,
      'firm_reg', p.firm_reg, 'licence_body', m.licence_body, 'licence_no', m.licence_no, 'licence_status', m.licence_status, 'licence_note', m.licence_note,
      'verified_at', m.verified_at, 'created_at', m.created_at,
      'clients', (select count(*) from practice_clients c where c.practice_id = p.id and c.status = 'active')) order by m.created_at), '[]'::jsonb)
    from practice_members m join practices p on p.id = m.practice_id
    where m.licence_no is not null and (coalesce(p_status, 'all') = 'all' or m.licence_status = p_status) and m.status <> 'disabled');
end $$;

-- p_status: verified or rejected; the note says why (shown to the accountant when rejected).
create or replace function public.admin_licence_decide(p_member uuid, p_status text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.practice_members;
begin
  perform private.require_staff(false);
  if p_status not in ('verified', 'rejected') then raise exception 'Verify or reject.'; end if;
  if p_status = 'rejected' and length(trim(coalesce(p_note, ''))) < 5 then raise exception 'Say why, so the accountant can put it right.'; end if;
  update practice_members set licence_status = p_status, licence_note = nullif(left(trim(p_note), 300), ''), verified_by = auth.uid(), verified_at = now()
  where id = p_member and licence_no is not null returning * into m;
  if not found then raise exception 'That accountant has no licence number to check.'; end if;
  perform private.audit('licence_' || p_status, m.id::text, jsonb_build_object('practice_id', m.practice_id, 'body', m.licence_body, 'number', m.licence_no, 'note', p_note));
  if m.user_id is not null then
    perform private.notify(null, m.user_id, 'practice', case when p_status = 'verified' then 'TaxStreem verified your ' || m.licence_body || ' number'
        else 'TaxStreem could not confirm your ' || m.licence_body || ' number' end,
      case when p_status = 'verified' then 'Your clients now see it as verified.' else left(p_note, 200) end, '/practice/settings', null);
  end if;
  return jsonb_build_object('id', m.id, 'licence_status', m.licence_status);
end $$;

-- ---------------------------------------------------------------------------
-- 9. The practice paying for a client's plan
-- ---------------------------------------------------------------------------
-- p: {plan_id, billing: month|year, use_saved}
create or replace function public.practice_plan_start(p_client uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients; me public.practice_members; pl public.plans; s public.subscriptions; ch public.subscription_charges; v_billing text := coalesce(nullif(p->>'billing', ''), 'month');
  v_card uuid; v_seat uuid;
begin
  c := private.practice_client_require(p_client, true);
  me := private.practice_me(c.practice_id);
  if c.status <> 'active' then raise exception 'Pay for businesses you work for.'; end if;
  if (select is_sample from orgs where id = c.org_id) then raise exception 'The sample business stays on its plan.'; end if;
  if v_billing not in ('month', 'year') then raise exception 'Pay monthly or yearly.'; end if;
  select * into pl from plans where id = nullif(p->>'plan_id', '')::uuid and active and public;
  if not found then raise exception 'Choose a plan.'; end if;
  if private.plan_price(pl, v_billing) <= 0 then raise exception 'The % plan is free: nothing to pay.', pl.name; end if;
  select * into s from subscriptions where org_id = c.org_id for update;
  if s.paid_by = c.practice_id and s.plan_id = pl.id and s.billing = v_billing and s.status = 'active' and not s.cancel_at_period_end and s.current_period_end > now() then
    raise exception 'You already pay for % on the % plan.', coalesce(c.business_name, 'this business'), pl.name;
  end if;
  update practice_clients set billing = 'practice' where id = c.id;
  select id into v_card from subscription_cards where practice_id = c.practice_id and active order by created_at desc limit 1;
  select id into v_seat from members where org_id = c.org_id and user_id = auth.uid();
  select * into ch from subscription_charges where org_id = c.org_id and practice_id = c.practice_id and kind = 'start' and status = 'pending' and plan_id = pl.id
    and billing = v_billing and created_at > now() - interval '30 minutes' order by created_at desc limit 1;
  if not found then
    update subscription_charges set status = 'cancelled', updated_at = now() where org_id = c.org_id and kind = 'start' and status = 'pending';
    insert into subscription_charges (org_id, plan_id, billing, amount, method, kind, card_id, tx_ref, requested_by, practice_id)
    values (c.org_id, pl.id, v_billing, private.plan_price(pl, v_billing), 'card', 'start', case when coalesce((p->>'use_saved')::boolean, true) then v_card end,
      'SUB-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)), v_seat, c.practice_id)
    returning * into ch;
  end if;
  return jsonb_build_object('action', case when ch.card_id is not null then 'charge_card' else 'checkout' end, 'charge_id', ch.id, 'tx_ref', ch.tx_ref, 'amount', ch.amount);
end $$;

-- Stops paying: the plan runs to the end of the period the practice paid for.
create or replace function public.practice_plan_stop(p_client uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  return public.practice_set_billing(p_client, 'business');
end $$;

-- Before the payments function checks a plan payment for the practice: the person is a partner or manager of the practice that pays.
create or replace function public.practice_charge_check(p_tx_ref text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare ch public.subscription_charges;
begin
  select * into ch from subscription_charges where tx_ref = p_tx_ref and practice_id is not null;
  if not found then raise exception 'Unknown payment.'; end if;
  perform private.practice_require(ch.practice_id, true);
  return jsonb_build_object('charge_id', ch.id, 'practice_id', ch.practice_id, 'org_id', ch.org_id, 'status', ch.status);
end $$;

create or replace function public.practice_billing(p_practice uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.practice_require(p_practice, true);
  return jsonb_build_object(
    'clients', (select coalesce(jsonb_agg(jsonb_build_object('client_id', c.id, 'org_id', c.org_id, 'business_name', o.name, 'billing', c.billing,
        'plan', (select jsonb_build_object('id', pl.id, 'name', pl.name) from plans pl where pl.id = private.org_plan_id(c.org_id)),
        'subscription', (select jsonb_build_object('status', s.status, 'billing', s.billing, 'period_end', s.current_period_end, 'cancel_at_period_end', s.cancel_at_period_end,
            'paid_by_us', s.paid_by = p_practice, 'paid_by_other', s.paid_by is not null and s.paid_by <> p_practice) from subscriptions s where s.org_id = c.org_id)) order by o.name), '[]'::jsonb)
      from practice_clients c join orgs o on o.id = c.org_id where c.practice_id = p_practice and c.status = 'active'),
    'cards', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'last4', k.last4, 'brand', k.brand, 'expiry', k.expiry, 'created_at', k.created_at) order by k.created_at desc), '[]'::jsonb)
      from subscription_cards k where k.practice_id = p_practice and k.active),
    'charges', (select coalesce(jsonb_agg(jsonb_build_object('id', ch.id, 'tx_ref', ch.tx_ref, 'business_name', o.name, 'plan', pl.name, 'billing', ch.billing, 'amount', ch.amount,
        'kind', ch.kind, 'status', ch.status, 'error', ch.error, 'paid_at', ch.paid_at, 'created_at', ch.created_at) order by ch.created_at desc), '[]'::jsonb)
      from (select * from subscription_charges where practice_id = p_practice order by created_at desc limit 60) ch join orgs o on o.id = ch.org_id join plans pl on pl.id = ch.plan_id),
    'plans', (select coalesce(jsonb_agg(jsonb_build_object('id', pl.id, 'name', pl.name, 'price_month', pl.price_month, 'price_year', pl.price_year,
        'description', pl.description) order by pl.sort, pl.price_month), '[]'::jsonb)
      from plans pl where pl.active and pl.public and pl.price_month > 0));
end $$;

create or replace function public.practice_card_remove(p_practice uuid, p_card uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.practice_require(p_practice, true);
  update subscription_cards set active = false where id = p_card and practice_id = p_practice;
  update subscriptions set card_id = null, updated_at = now() where card_id = p_card and paid_by = p_practice;
  return public.practice_billing(p_practice);
end $$;

-- ---------------------------------------------------------------------------
-- 10. Returns and statements an accountant changed
-- ---------------------------------------------------------------------------
-- period: VAT and WHT 'YYYY-MM'; CIT the accounting year 'YYYY'; financial statements 'YYYY-MM-DD:YYYY-MM-DD' (from:to).
-- figures: what Counta read from its own file (or from the version in use) and from the upload, line by line:
--   [{key, label, counta, uploaded}]. changes: the lines that differ. proposal: the journal Counta suggests to book them.
create table if not exists public.filing_versions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  kind text not null check (kind in ('vat', 'wht', 'cit', 'fs')),
  period text not null,
  authority text,
  version int not null,
  status text not null default 'review' check (status in ('review', 'in_use', 'replaced', 'withdrawn')),
  file_path text not null,
  file_name text not null check (length(file_name) between 1 and 160),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  size_bytes int,
  base_version uuid references public.filing_versions(id) on delete set null,
  figures jsonb not null default '[]'::jsonb,
  changes jsonb not null default '[]'::jsonb,
  checks jsonb not null default '[]'::jsonb,
  proposal jsonb not null default '[]'::jsonb,
  payable_difference numeric(16,2),
  note text check (note is null or length(note) <= 1500),
  journal_id uuid references public.journals(id) on delete set null,
  reversal_journal_id uuid references public.journals(id) on delete set null,
  no_journal_reason text check (no_journal_reason is null or length(no_journal_reason) <= 500),
  statement text,
  practice_id uuid references public.practices(id) on delete set null,
  practice_name text,
  uploaded_by uuid references auth.users(id) on delete set null,
  uploaded_member uuid references public.members(id) on delete set null,
  uploader_name text,
  accepted_by uuid references auth.users(id) on delete set null,
  accepted_name text,
  accepted_licence text,
  accepted_at timestamptz,
  withdrawn_by uuid references auth.users(id) on delete set null,
  withdrawn_at timestamptz,
  withdrawn_reason text,
  created_at timestamptz not null default now()
);
create unique index if not exists filing_versions_no on public.filing_versions(org_id, kind, period, coalesce(authority, ''), version);
create unique index if not exists filing_versions_in_use on public.filing_versions(org_id, kind, period, coalesce(authority, '')) where status = 'in_use';
create index if not exists filing_versions_org on public.filing_versions(org_id, created_at desc);
create index if not exists filing_versions_base on public.filing_versions(base_version);
create index if not exists filing_versions_journal on public.filing_versions(journal_id);
create index if not exists filing_versions_reversal on public.filing_versions(reversal_journal_id);
create index if not exists filing_versions_practice on public.filing_versions(practice_id);
create index if not exists filing_versions_uploaded_by on public.filing_versions(uploaded_by);
create index if not exists filing_versions_uploaded_member on public.filing_versions(uploaded_member);
create index if not exists filing_versions_accepted_by on public.filing_versions(accepted_by);
create index if not exists filing_versions_withdrawn_by on public.filing_versions(withdrawn_by);
alter table public.filing_versions enable row level security;
revoke all on public.filing_versions from anon, authenticated;

create or replace function private.filing_period_ok(p_kind text, p_period text, p_authority text) returns boolean
language sql immutable set search_path = '' as $$
  select case p_kind
    when 'vat' then p_period ~ '^\d{4}-(0[1-9]|1[0-2])$' and p_authority is null
    when 'wht' then p_period ~ '^\d{4}-(0[1-9]|1[0-2])$' and coalesce(p_authority, '') ~ '^(NRS|SIRS:[A-Z]{2})$'
    when 'cit' then p_period ~ '^(19|20)\d{2}$' and p_authority is null
    when 'fs' then p_period ~ '^\d{4}-\d{2}-\d{2}:\d{4}-\d{2}-\d{2}$' and p_authority is null and split_part(p_period, ':', 1) <= split_part(p_period, ':', 2)
    else false end
$$;

create or replace function private.filing_label(p_kind text, p_period text, p_authority text) returns text
language sql immutable set search_path = '' as $$
  select case p_kind
    when 'vat' then 'VAT return for ' || to_char(to_date(p_period || '-01', 'YYYY-MM-DD'), 'FMMonth YYYY')
    when 'wht' then 'WHT schedule for ' || to_char(to_date(p_period || '-01', 'YYYY-MM-DD'), 'FMMonth YYYY')
      || case when p_authority = 'NRS' then ' (NRS)' else ' (' || replace(coalesce(p_authority, ''), 'SIRS:', '') || ' state revenue service)' end
    when 'cit' then 'companies income tax return for ' || p_period
    when 'fs' then 'financial statements for the period ended ' || to_char(to_date(split_part(p_period, ':', 2), 'YYYY-MM-DD'), 'FMDD FMMonth YYYY')
    else p_kind end
$$;

-- The day an adjusting journal for the filing is dated: the last day it covers.
create or replace function private.filing_day(p_org uuid, p_kind text, p_period text) returns date
language plpgsql stable security definer set search_path = public, private as $$
declare v_to date;
begin
  if p_kind in ('vat', 'wht') then return (to_date(p_period || '-01', 'YYYY-MM-DD') + interval '1 month' - interval '1 day')::date; end if;
  if p_kind = 'fs' then return to_date(split_part(p_period, ':', 2), 'YYYY-MM-DD'); end if;
  select pto into v_to from private.cit_period(p_org, p_period::int);
  return coalesce(v_to, make_date(p_period::int, 12, 31));
end $$;

-- Whether the filing has gone to Flux or been filed, so a changed version can no longer replace (or stop replacing) it.
create or replace function private.filing_locked(p_org uuid, p_kind text, p_period text, p_authority text) returns text
language sql stable security definer set search_path = public, private as $$
  select case
    when p_kind in ('vat', 'wht') and exists (select 1 from flux_returns r where r.org_id = p_org and r.tax = p_kind and r.period = to_date(p_period || '-01', 'YYYY-MM-DD')
      and r.authority = coalesce(p_authority, 'NRS') and r.status in ('sent', 'processing', 'filed')) then 'with Flux or filed'
    when p_kind = 'cit' and exists (select 1 from cit_years y where y.org_id = p_org and y.accounting_year = p_period::int and y.status in ('sent', 'filed')) then 'sent or filed'
    else null end
$$;

create or replace function private.filing_perm(p_kind text) returns text
language sql immutable set search_path = '' as $$ select case when p_kind = 'fs' then 'keep_books' else 'file_tax' end $$;

create or replace function private.filing_version_brief(v public.filing_versions) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', v.id, 'kind', v.kind, 'period', v.period, 'authority', v.authority, 'label', private.filing_label(v.kind, v.period, v.authority),
    'version', v.version, 'status', v.status, 'file_name', v.file_name, 'uploader_name', v.uploader_name, 'practice_name', v.practice_name,
    'accepted_name', v.accepted_name, 'accepted_licence', v.accepted_licence, 'accepted_at', v.accepted_at, 'created_at', v.created_at,
    'changes', jsonb_array_length(v.changes), 'payable_difference', v.payable_difference, 'statement', v.statement,
    'journal_ref', (select ref from journals where id = v.journal_id), 'withdrawn_at', v.withdrawn_at, 'withdrawn_reason', v.withdrawn_reason)
$$;

-- The account Counta suggests for a change on a line of the statements: the account of that line used most in the period,
-- leaving out the customer and supplier control accounts and the VAT accounts (written by their own records).
create or replace function private.fs_line_account(p_org uuid, p_line text, p_from date, p_to date) returns text
language sql stable security definer set search_path = public, private as $$
  select m.code from private.acct_meta(p_org) m
  left join (select l.account_code code, count(*) n from journal_lines l join journals j on j.id = l.journal_id
             where l.org_id = p_org and j.entry_date between p_from and p_to group by 1) u on u.code = m.code
  where m.ifrs_line = p_line and private.postable(p_org, m.code) and split_part(m.code, '-', 1) not in ('1101', '1102', '2101', '2102', '2201', '1402', '9001', '3999')
  order by coalesce(u.n, 0) desc, m.code limit 1
$$;

-- The journal Counta suggests to bring the books to the accountant's figures. The accountant changes it as they need.
create or replace function private.filing_proposal(p_org uuid, p_kind text, p_period text, p_changes jsonb, p_payable numeric) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v jsonb := '[]'::jsonb; x jsonb; d numeric; v_code text; v_from date; v_to date; v_pl numeric := 0; v_re numeric := 0; v_label text;
  v_other text; v_inc text;
begin
  v_other := case when private.postable(p_org, private.acct(p_org, 'expenses_default')) then private.acct(p_org, 'expenses_default') end;
  v_inc := case when private.postable(p_org, private.acct(p_org, 'other_income')) then private.acct(p_org, 'other_income') end;
  if p_kind in ('vat', 'wht') then
    d := round(coalesce(p_payable, 0), 2);
    if abs(d) < 0.01 then return v; end if;
    v_code := private.acct(p_org, case when p_kind = 'vat' then 'output_vat' else 'wht_payable' end);
    v_label := case when p_kind = 'vat' then 'VAT' else 'WHT' end || ' for ' || private.filing_label(p_kind, p_period, null);
    if d > 0 then
      v := jsonb_build_array(jsonb_build_object('code', v_other, 'debit', d, 'memo', 'More ' || v_label || ' in the accountant''s return'),
        jsonb_build_object('code', v_code, 'credit', d, 'memo', 'More ' || v_label || ' in the accountant''s return'));
    else
      v := jsonb_build_array(jsonb_build_object('code', v_code, 'debit', -d, 'memo', 'Less ' || v_label || ' in the accountant''s return'),
        jsonb_build_object('code', v_inc, 'credit', -d, 'memo', 'Less ' || v_label || ' in the accountant''s return'));
    end if;
    return v;
  end if;
  if p_kind = 'cit' then
    select (c->>'uploaded')::numeric - (c->>'counta')::numeric into d from jsonb_array_elements(p_changes) c where c->>'key' = 'taxation';
    d := round(coalesce(d, 0), 2);
    if abs(d) < 0.01 then return v; end if;
    if d > 0 then
      return jsonb_build_array(jsonb_build_object('code', case when private.postable(p_org, '7501') then '7501' end, 'debit', d, 'memo', 'Tax charge in the accountant''s return'),
        jsonb_build_object('code', case when private.postable(p_org, '2208') then '2208' end, 'credit', d, 'memo', 'Tax charge in the accountant''s return'));
    end if;
    return jsonb_build_array(jsonb_build_object('code', case when private.postable(p_org, '2208') then '2208' end, 'debit', -d, 'memo', 'Lower tax charge in the accountant''s return'),
      jsonb_build_object('code', case when private.postable(p_org, '7501') then '7501' end, 'credit', -d, 'memo', 'Lower tax charge in the accountant''s return'));
  end if;
  -- The statements: one line per changed line item; the change in retained earnings that profit does not explain goes to 3005.
  v_from := to_date(split_part(p_period, ':', 1), 'YYYY-MM-DD'); v_to := to_date(split_part(p_period, ':', 2), 'YYYY-MM-DD');
  for x in select * from jsonb_array_elements(p_changes) loop
    continue when not coalesce((x->>'bookable')::boolean, false);
    d := round((x->>'uploaded')::numeric - (x->>'counta')::numeric, 2);
    continue when abs(d) < 0.01;
    if x->>'key' like 'pl:%' then v_pl := v_pl + d; end if;
    if x->>'label' = 'Retained earnings' and x->>'key' like 'fp:%' then v_re := d; continue; end if;
    v_code := private.fs_line_account(p_org, x->>'label', v_from, v_to);
    -- Profit or loss: a larger figure is more income or less expense (a credit). Assets: a larger figure is a debit; equity and liabilities a credit.
    if x->>'key' like 'pl:%' or not (x->>'label' = any (private.asset_lines())) then
      v := v || jsonb_build_array(jsonb_build_object('code', v_code, case when d > 0 then 'credit' else 'debit' end, abs(d), 'memo', x->>'label' || ' as the accountant changed it'));
    else
      v := v || jsonb_build_array(jsonb_build_object('code', v_code, case when d > 0 then 'debit' else 'credit' end, abs(d), 'memo', x->>'label' || ' as the accountant changed it'));
    end if;
  end loop;
  d := round(v_re - v_pl, 2);
  if abs(d) >= 0.01 then
    v := v || jsonb_build_array(jsonb_build_object('code', '3005', case when d > 0 then 'credit' else 'debit' end, abs(d), 'memo', 'Retained earnings as the accountant changed them'));
  end if;
  return v;
end $$;

-- What a proposed journal would do: whether it balances and can be posted, and what still differs from the accountant's file.
create or replace function private.filing_lines_check(v public.filing_versions, p_lines jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare x jsonb; v_dr numeric := 0; v_cr numeric := 0; d numeric; c numeric; v_problems jsonb := '[]'::jsonb; v_rem jsonb := '[]'::jsonb; v_n int := 0;
  v_code text; v_eff numeric; v_pl numeric := 0; v_ch jsonb; v_meta record; v_tax_codes text[];
begin
  if jsonb_typeof(coalesce(p_lines, '[]'::jsonb)) <> 'array' then raise exception 'The journal lines are not a list.'; end if;
  if jsonb_array_length(coalesce(p_lines, '[]'::jsonb)) > 60 then raise exception 'A journal here holds up to sixty lines.'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    d := round(coalesce(nullif(x->>'debit', '')::numeric, 0), 2); c := round(coalesce(nullif(x->>'credit', '')::numeric, 0), 2);
    continue when d = 0 and c = 0;
    v_n := v_n + 1;
    v_code := nullif(trim(x->>'code'), '');
    if d < 0 or c < 0 then v_problems := v_problems || to_jsonb('Line ' || v_n || ': amounts cannot be negative.'::text);
    elsif d <> 0 and c <> 0 then v_problems := v_problems || to_jsonb('Line ' || v_n || ' is either a debit or a credit, not both.'::text); end if;
    if v_code is null then v_problems := v_problems || to_jsonb('Line ' || v_n || ' needs an account.'::text);
    elsif split_part(v_code, '-', 1) in ('1101', '1102', '2101', '2102') then
      v_problems := v_problems || to_jsonb(('Line ' || v_n || ': ' || v_code || ' holds customers'' and suppliers'' balances. Book those through Sales or Bills, or use another account.')::text);
    elsif not private.postable(v.org_id, v_code) then
      v_problems := v_problems || to_jsonb(('Line ' || v_n || ': account ' || v_code || ' cannot take postings.')::text);
    end if;
    v_dr := v_dr + d; v_cr := v_cr + c;
  end loop;
  if v_dr <> v_cr then v_problems := v_problems || to_jsonb(('The journal does not balance: debits ' || private.naira(v_dr) || ', credits ' || private.naira(v_cr) || '.')::text); end if;

  -- What the accountant's file shows that the journal does not book.
  if v.kind in ('vat', 'wht', 'cit') then
    v_tax_codes := case v.kind when 'vat' then array[private.acct(v.org_id, 'output_vat')] when 'wht' then array[private.acct(v.org_id, 'wht_payable')] else array['2208', '2209'] end;
    select coalesce(sum(round(coalesce(nullif(e->>'credit', '')::numeric, 0), 2) - round(coalesce(nullif(e->>'debit', '')::numeric, 0), 2)), 0) into v_eff
      from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e where split_part(e->>'code', '-', 1) = any (v_tax_codes) or e->>'code' = any (v_tax_codes);
    d := case when v.kind = 'cit' then (select (c2->>'uploaded')::numeric - (c2->>'counta')::numeric from jsonb_array_elements(v.changes) c2 where c2->>'key' = 'taxation')
              else v.payable_difference end;
    if abs(coalesce(d, 0) - v_eff) >= 0.01 then
      v_rem := v_rem || jsonb_build_array(jsonb_build_object('label', case v.kind when 'vat' then 'VAT payable (' || v_tax_codes[1] || ')' when 'wht' then 'WHT payable (' || v_tax_codes[1] || ')'
        else 'Income tax payable (2208, 2209)' end, 'file', round(coalesce(d, 0), 2), 'journal', round(v_eff, 2), 'left', round(coalesce(d, 0) - v_eff, 2)));
    end if;
  else
    for v_ch in select * from jsonb_array_elements(v.changes) loop
      continue when not coalesce((v_ch->>'bookable')::boolean, false);
      v_eff := 0;
      for x in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
        select m.ifrs_line, m.statement into v_meta from private.acct_meta(v.org_id) m where m.code = x->>'code';
        continue when v_meta.ifrs_line is distinct from v_ch->>'label';
        d := round(coalesce(nullif(x->>'debit', '')::numeric, 0), 2) - round(coalesce(nullif(x->>'credit', '')::numeric, 0), 2);
        v_eff := v_eff + case when v_ch->>'key' like 'pl:%' or not (v_ch->>'label' = any (private.asset_lines())) then -d else d end;
      end loop;
      if v_ch->>'key' like 'pl:%' then v_pl := v_pl + v_eff; end if;
      if v_ch->>'label' = 'Retained earnings' then continue; end if;
      d := round((v_ch->>'uploaded')::numeric - (v_ch->>'counta')::numeric, 2);
      if abs(d - v_eff) >= 0.01 then
        v_rem := v_rem || jsonb_build_array(jsonb_build_object('label', v_ch->>'label', 'file', d, 'journal', round(v_eff, 2), 'left', round(d - v_eff, 2)));
      end if;
    end loop;
    -- Retained earnings: what the journal books on 3005 plus the profit it changes.
    select v_ch2 into v_ch from jsonb_array_elements(v.changes) v_ch2 where v_ch2->>'label' = 'Retained earnings' and v_ch2->>'key' like 'fp:%' limit 1;
    select coalesce(sum(round(coalesce(nullif(e->>'credit', '')::numeric, 0), 2) - round(coalesce(nullif(e->>'debit', '')::numeric, 0), 2)), 0) into v_eff
      from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e where e->>'code' = '3005';
    d := coalesce((v_ch->>'uploaded')::numeric - (v_ch->>'counta')::numeric, 0);
    if abs(d - v_eff - v_pl) >= 0.01 then
      v_rem := v_rem || jsonb_build_array(jsonb_build_object('label', 'Retained earnings', 'file', round(d, 2), 'journal', round(v_eff + v_pl, 2), 'left', round(d - v_eff - v_pl, 2)));
    end if;
  end if;
  return jsonb_build_object('lines', v_n, 'debit', v_dr, 'credit', v_cr, 'balanced', v_dr = v_cr, 'problems', v_problems, 'remaining', v_rem);
end $$;

-- The words the accountant accepts, in their own name.
create or replace function private.filing_statement(v public.filing_versions, p_name text, p_licence text, p_practice text, p_journal_ref text, p_reason text) returns text
language sql stable security definer set search_path = public, private as $$
  select 'I, ' || p_name || coalesce(' (' || p_licence || ')', '') || coalesce(', of ' || p_practice, '') || ', changed the ' || private.filing_label(v.kind, v.period, v.authority)
    || ' that Counta prepared for ' || (select name from orgs where id = v.org_id) || '. The changes are listed with this version. '
    || case when p_journal_ref is not null then 'I booked them in the books with journal ' || p_journal_ref || '. '
            else 'They need no entry in the books, because ' || rtrim(coalesce(p_reason, ''), '.') || '. ' end
    || 'I take professional responsibility for these changes and for this version, which Counta uses in place of its own from '
    || to_char(now() at time zone 'Africa/Lagos', 'FMDD FMMonth YYYY') || '.'
$$;

-- Who may upload or accept: an accountant in the business, with the permission the filing needs (and Keep the books to book it).
create or replace function private.filing_accountant(p_org uuid, p_kind text, p_book boolean) returns public.members
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, private.filing_perm(p_kind));
  if m.role <> 'accountant' then
    raise exception 'Only an accountant uploads a changed return, and takes responsibility for it. Invite yours in Settings, Your accountant.' using errcode = '42501';
  end if;
  if p_book and not private.perm_of(m, 'keep_books') then raise exception 'Booking the changes needs Keep the books.' using errcode = '42501'; end if;
  return m;
end $$;

-- For the tax-files function, as the accountant uploads: whether they may, and what the upload is compared with.
create or replace function public.filing_version_start(p_org uuid, p_kind text, p_period text, p_authority text default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; pm public.practice_members; pr public.practices; cur public.filing_versions; v_lock text;
begin
  m := private.filing_accountant(p_org, p_kind, false);
  if not private.filing_period_ok(p_kind, p_period, nullif(p_authority, '')) then raise exception 'Choose the return and its period.'; end if;
  v_lock := private.filing_locked(p_org, p_kind, p_period, nullif(p_authority, ''));
  if v_lock is not null then raise exception 'The % is already %. A changed version can no longer replace it.', private.filing_label(p_kind, p_period, nullif(p_authority, '')), v_lock; end if;
  if (select count(*) from filing_versions where org_id = p_org and uploaded_by = auth.uid() and created_at > now() - interval '1 day') >= 30 then
    raise exception 'That is thirty uploads today. Try again tomorrow.';
  end if;
  select * into pr from practices where id = m.practice_id;
  select * into pm from practice_members where practice_id = m.practice_id and user_id = auth.uid();
  select * into cur from filing_versions where org_id = p_org and kind = p_kind and period = p_period and coalesce(authority, '') = coalesce(nullif(p_authority, ''), '') and status = 'in_use';
  return jsonb_build_object('member_id', m.id, 'name', m.display_name, 'practice_id', pr.id, 'practice_name', pr.name,
    'licence', case when pm.id is not null then private.licence_text(pm) end, 'org_name', (select name from orgs where id = p_org),
    'label', private.filing_label(p_kind, p_period, nullif(p_authority, '')),
    'current', case when cur.id is not null then jsonb_build_object('id', cur.id, 'figures', cur.figures, 'accepted_name', cur.accepted_name, 'accepted_at', cur.accepted_at) end);
end $$;

-- From the tax-files function once the file is stored and read. p: {org_id, kind, period, authority, file_path, file_name, sha256, size, user_id,
-- member_id, base_version, rows: [{key, label, counta, uploaded, bookable}], checks: [text], note}
create or replace function public.svc_filing_version_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v public.filing_versions; v_kind text := p->>'kind'; v_period text := p->>'period'; v_auth text := nullif(p->>'authority', '');
  v_rows jsonb := coalesce(p->'rows', '[]'::jsonb); v_changes jsonb; v_payable numeric; pr public.practices; x jsonb;
begin
  select * into m from members where id = (p->>'member_id')::uuid and org_id = (p->>'org_id')::uuid and user_id = (p->>'user_id')::uuid and status = 'active' and role = 'accountant';
  if not found then raise exception 'Only an accountant in the business uploads a changed return.'; end if;
  if not private.filing_period_ok(v_kind, v_period, v_auth) then raise exception 'Choose the return and its period.'; end if;
  if split_part(p->>'file_path', '/', 1) <> m.org_id::text or split_part(p->>'file_path', '/', 2) <> 'tax' then raise exception 'The file is not in the business''s tax documents.'; end if;
  if jsonb_typeof(v_rows) <> 'array' or jsonb_array_length(v_rows) = 0 then raise exception 'Counta could not read any figures from the file.'; end if;
  for x in select * from jsonb_array_elements(v_rows) loop
    if coalesce(x->>'key', '') = '' or jsonb_typeof(x->'counta') not in ('number', 'null') or jsonb_typeof(x->'uploaded') not in ('number', 'null') then
      raise exception 'A figure read from the file is not a number.';
    end if;
  end loop;
  select coalesce(jsonb_agg(r || jsonb_build_object('difference', round(coalesce((r->>'uploaded')::numeric, 0) - coalesce((r->>'counta')::numeric, 0), 2))
           order by ord), '[]'::jsonb)
    into v_changes from jsonb_array_elements(v_rows) with ordinality t(r, ord)
    where abs(coalesce((r->>'uploaded')::numeric, 0) - coalesce((r->>'counta')::numeric, 0)) >= 0.005;
  v_payable := case v_kind
    when 'vat' then (select round(coalesce((r->>'uploaded')::numeric, 0) - coalesce((r->>'counta')::numeric, 0), 2) from jsonb_array_elements(v_rows) r where r->>'key' = 'line_115')
    when 'wht' then (select round(coalesce((r->>'uploaded')::numeric, 0) - coalesce((r->>'counta')::numeric, 0), 2) from jsonb_array_elements(v_rows) r where r->>'key' = 'wht_total')
    else null end;
  select * into pr from practices where id = m.practice_id;
  -- A new upload of the same return replaces one still waiting for review.
  update filing_versions set status = 'replaced' where org_id = m.org_id and kind = v_kind and period = v_period and coalesce(authority, '') = coalesce(v_auth, '') and status = 'review';
  insert into filing_versions (org_id, kind, period, authority, version, file_path, file_name, sha256, size_bytes, base_version, figures, changes, checks, proposal,
    payable_difference, note, practice_id, practice_name, uploaded_by, uploaded_member, uploader_name)
  values (m.org_id, v_kind, v_period, v_auth,
    coalesce((select max(version) from filing_versions where org_id = m.org_id and kind = v_kind and period = v_period and coalesce(authority, '') = coalesce(v_auth, '')), 0) + 1,
    p->>'file_path', left(p->>'file_name', 160), p->>'sha256', nullif(p->>'size', '')::int, nullif(p->>'base_version', '')::uuid, v_rows, v_changes,
    coalesce(p->'checks', '[]'::jsonb), private.filing_proposal(m.org_id, v_kind, v_period, v_changes, v_payable), v_payable, nullif(left(trim(p->>'note'), 1500), ''),
    pr.id, pr.name, m.user_id, m.id, m.display_name)
  returning * into v;
  return private.filing_version_brief(v) || jsonb_build_object('changed', v.changes);
end $$;

-- One version in full, for the accountant reviewing it and for the business.
create or replace function public.filing_version(p_version uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v public.filing_versions; m public.members; pm public.practice_members; v_can boolean; v_check jsonb;
begin
  select * into v from filing_versions where id = p_version;
  if not found then raise exception 'That version was not found.'; end if;
  m := private.require(v.org_id, null);
  if not (private.perm_of(m, private.filing_perm(v.kind)) or private.can_handle_money(v.org_id)) then
    raise exception 'Your role does not see tax returns.' using errcode = '42501';
  end if;
  v_can := m.role = 'accountant' and private.perm_of(m, private.filing_perm(v.kind)) and private.perm_of(m, 'keep_books') and v.status = 'review';
  select * into pm from practice_members where practice_id = m.practice_id and user_id = auth.uid();
  if v_can then v_check := private.filing_lines_check(v, v.proposal); end if;
  return private.filing_version_brief(v) || jsonb_build_object('org_id', v.org_id, 'figures', v.figures, 'changes', v.changes, 'checks', v.checks, 'proposal', v.proposal,
    'proposal_check', v_check, 'note', v.note, 'file_path', v.file_path, 'sha256', v.sha256, 'no_journal_reason', v.no_journal_reason,
    'locked', private.filing_locked(v.org_id, v.kind, v.period, v.authority),
    'base', case when v.base_version is not null then (select jsonb_build_object('id', b.id, 'version', b.version, 'accepted_name', b.accepted_name) from filing_versions b where b.id = v.base_version) end,
    'can_apply', v_can,
    'can_withdraw', v.status in ('review', 'in_use') and (m.role = 'owner' or (m.role = 'accountant' and private.perm_of(m, private.filing_perm(v.kind)))),
    'statement_preview', case when v_can then private.filing_statement(v, m.display_name, case when pm.id is not null then private.licence_text(pm) end,
      (select name from practices where id = m.practice_id), 'JE-…', null) end,
    'accounts', case when v_can then (select coalesce(jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name, 'line', a.ifrs_line, 'statement', a.statement) order by a.code), '[]'::jsonb)
      from private.acct_meta(v.org_id) a where private.postable(v.org_id, a.code) and split_part(a.code, '-', 1) not in ('1101', '1102', '2101', '2102')) end);
end $$;

-- The accountant checks a journal before booking it.
create or replace function public.filing_version_check(p_version uuid, p_lines jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v public.filing_versions;
begin
  select * into v from filing_versions where id = p_version;
  if not found then raise exception 'That version was not found.'; end if;
  perform private.filing_accountant(v.org_id, v.kind, true);
  return private.filing_lines_check(v, p_lines);
end $$;

-- The accountant books the differences and takes responsibility: the version becomes the one Counta uses.
-- p: {lines: [{code, debit, credit, memo}], reason (when no journal is needed), accept: true}
create or replace function public.filing_version_apply(p_version uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v public.filing_versions; m public.members; pm public.practice_members; pr public.practices; ck jsonb; j public.journals; v_lines jsonb := '[]'::jsonb; x jsonb;
  v_reason text := nullif(trim(p->>'reason'), ''); v_lock text; v_licence text; old public.filing_versions;
begin
  select * into v from filing_versions where id = p_version for update;
  if not found then raise exception 'That version was not found.'; end if;
  m := private.filing_accountant(v.org_id, v.kind, true);
  if v.status <> 'review' then raise exception 'This version is % already.', case v.status when 'in_use' then 'in use' else v.status end; end if;
  v_lock := private.filing_locked(v.org_id, v.kind, v.period, v.authority);
  if v_lock is not null then raise exception 'The % is already %. A changed version can no longer replace it.', private.filing_label(v.kind, v.period, v.authority), v_lock; end if;
  if not coalesce((p->>'accept')::boolean, false) then raise exception 'Confirm that you take responsibility for the changes.'; end if;
  ck := private.filing_lines_check(v, p->'lines');
  if jsonb_array_length(ck->'problems') > 0 then raise exception '%', ck->'problems'->>0; end if;
  if (ck->>'lines')::int = 0 and length(coalesce(v_reason, '')) < 10 then
    raise exception 'Say why the changes need no entry in the books (for example, they only move figures between lines of the return).';
  end if;
  select * into pm from practice_members where practice_id = m.practice_id and user_id = auth.uid();
  select * into pr from practices where id = m.practice_id;
  v_licence := case when pm.id is not null and pm.licence_no is not null then private.licence_text(pm) end;
  if (ck->>'lines')::int > 0 then
    for x in select * from jsonb_array_elements(p->'lines') loop
      continue when round(coalesce(nullif(x->>'debit', '')::numeric, 0), 2) = 0 and round(coalesce(nullif(x->>'credit', '')::numeric, 0), 2) = 0;
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('code', trim(x->>'code'), 'debit', round(coalesce(nullif(x->>'debit', '')::numeric, 0), 2),
        'credit', round(coalesce(nullif(x->>'credit', '')::numeric, 0), 2), 'memo', left(coalesce(nullif(trim(x->>'memo'), ''), 'Accountant''s change'), 200)));
    end loop;
    j := private.post_entry(v.org_id, left('Accountant''s changes to the ' || private.filing_label(v.kind, v.period, v.authority) || ' (' || m.display_name
        || coalesce(', ' || pr.name, '') || ')', 500), 'accountant_file', v.id, m.id, m.id, v_lines,
      private.posting_time(v.org_id, private.filing_day(v.org_id, v.kind, v.period)),
      jsonb_build_object('origin', 'manual', 'evidence', jsonb_build_array(jsonb_build_object('type', 'accountant_file', 'version_id', v.id, 'file_name', v.file_name,
        'label', private.filing_label(v.kind, v.period, v.authority), 'accountant', m.display_name, 'licence', v_licence, 'practice', pr.name))));
  end if;
  -- The version in use until now steps aside; its journal stays, since this version was compared with it.
  update filing_versions set status = 'replaced' where org_id = v.org_id and kind = v.kind and period = v.period and coalesce(authority, '') = coalesce(v.authority, '')
    and status = 'in_use' and id <> v.id;
  update filing_versions set status = 'in_use', journal_id = j.id, no_journal_reason = case when j.id is null then left(v_reason, 500) end,
    statement = private.filing_statement(v, m.display_name, v_licence, pr.name, j.ref, v_reason),
    accepted_by = auth.uid(), accepted_name = m.display_name, accepted_licence = v_licence, accepted_at = now(), practice_id = pr.id, practice_name = pr.name
  where id = v.id returning * into v;
  perform private.notify_perm(v.org_id, 'owner', 'practice', m.display_name || ' changed your ' || private.filing_label(v.kind, v.period, v.authority),
    case when j.id is not null then 'They booked the changes (' || j.ref || ') and take responsibility for them. ' else 'The changes need no entry in the books. ' end
    || 'Counta now uses their version.', case when v.kind = 'fs' then '/accounting/statements' else '/tax/' || v.kind end, 'filing-' || v.id);
  return public.filing_version(v.id);
end $$;

-- Stops using a changed version: Counta goes back to its own file, and the journal that booked the changes is reversed.
create or replace function public.filing_version_withdraw(p_version uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v public.filing_versions; m public.members; r public.journals; v_lock text;
begin
  select * into v from filing_versions where id = p_version for update;
  if not found then raise exception 'That version was not found.'; end if;
  m := private.require(v.org_id, null);
  if not (m.role = 'owner' or (m.role = 'accountant' and private.perm_of(m, private.filing_perm(v.kind)))) then
    raise exception 'The owner or an accountant of the business withdraws a changed version.' using errcode = '42501';
  end if;
  if v.status not in ('review', 'in_use') then raise exception 'This version is no longer in use.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then raise exception 'Say why it is withdrawn.'; end if;
  if v.status = 'in_use' then
    v_lock := private.filing_locked(v.org_id, v.kind, v.period, v.authority);
    if v_lock is not null then raise exception 'The % is already %: the version filed stays.', private.filing_label(v.kind, v.period, v.authority), v_lock; end if;
    if v.journal_id is not null then r := private.reverse_entry(v.journal_id, m.id, 'Accountant''s version withdrawn: ' || left(trim(p_reason), 200)); end if;
  end if;
  update filing_versions set status = 'withdrawn', withdrawn_by = auth.uid(), withdrawn_at = now(), withdrawn_reason = left(trim(p_reason), 300), reversal_journal_id = r.id
  where id = v.id returning * into v;
  if m.role = 'owner' and v.practice_id is not null then
    perform private.practice_notify(v.practice_id, (select name from orgs where id = v.org_id) || ' withdrew your ' || private.filing_label(v.kind, v.period, v.authority),
      left(trim(p_reason), 200), '/practice');
  elsif m.role <> 'owner' and v.accepted_at is not null then
    perform private.notify_perm(v.org_id, 'owner', 'practice', 'Counta''s own ' || private.filing_label(v.kind, v.period, v.authority) || ' is back in use',
      m.display_name || ' withdrew their version: ' || left(trim(p_reason), 160), case when v.kind = 'fs' then '/accounting/statements' else '/tax/' || v.kind end, null);
  end if;
  return private.filing_version_brief(v);
end $$;

-- The version in use for a return, if an accountant's: what the Tax and Statements pages show and what tax-files sends.
create or replace function public.filing_version_current(p_org uuid, p_kind text, p_period text, p_authority text default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v public.filing_versions;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, private.filing_perm(p_kind)) or private.can_handle_money(p_org)) then raise exception 'Your role does not see tax returns.' using errcode = '42501'; end if;
  select * into v from filing_versions where org_id = p_org and kind = p_kind and period = p_period and coalesce(authority, '') = coalesce(nullif(p_authority, ''), '') and status = 'in_use';
  if not found then return null; end if;
  return private.filing_version_brief(v) || jsonb_build_object('file_path', v.file_path, 'sha256', v.sha256, 'figures', v.figures, 'changes', v.changes);
end $$;

-- The changed versions of a business's returns, newest first (the Tax and Statements pages, and Settings).
create or replace function public.filing_versions_list(p_org uuid, p_kind text default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'file_tax') or private.can_handle_money(p_org)) then raise exception 'Your role does not see tax returns.' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(private.filing_version_brief(v) order by v.created_at desc), '[]'::jsonb)
    from filing_versions v where v.id in (select id from filing_versions where org_id = p_org and (p_kind is null or kind = p_kind) order by created_at desc limit 100));
end $$;

-- What Counta expects to pay for a return follows the accountant's version: the books' figure moved by the change in tax payable
-- the accountant's file shows. (The function the payments use keeps its name; the books' figure is tax_expected_books.)
do $$
begin
  if to_regprocedure('private.tax_expected_books(uuid, text, date, text, integer)') is null then
    alter function private.tax_expected(uuid, text, date, text, integer) rename to tax_expected_books;
  end if;
end $$;

create or replace function private.tax_expected(p_org uuid, p_tax text, p_period date, p_authority text, p_year int) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare e jsonb := private.tax_expected_books(p_org, p_tax, p_period, p_authority, p_year); v public.filing_versions;
begin
  if p_tax not in ('vat', 'wht', 'cit') then return e; end if;
  select * into v from filing_versions where org_id = p_org and status = 'in_use' and kind = p_tax and payable_difference is not null
    and period = case when p_tax = 'cit' then p_year::text else to_char(p_period, 'YYYY-MM') end
    and coalesce(authority, '') = case when p_tax = 'wht' then coalesce(p_authority, 'NRS') else '' end;
  if not found or e->>'amount' is null then return e; end if;
  return e || jsonb_build_object('amount', greatest(0, round((e->>'amount')::numeric + v.payable_difference, 2)), 'books_amount', e->'amount',
    'accountant_version', v.id)
    || case when e ? 'total' and e->>'total' is not null then jsonb_build_object('total', greatest(0, round((e->>'total')::numeric + v.payable_difference, 2))) else '{}'::jsonb end;
end $$;
create or replace function private.sub_json(p_org uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('status', coalesce(s.status, 'active'), 'billing', coalesce(s.billing, 'month'), 'pay_method', s.pay_method,
    'current_period_start', s.current_period_start, 'current_period_end', s.current_period_end, 'trial_ends_at', s.trial_ends_at,
    'trial_used', coalesce(s.trial_used, false), 'cancel_at_period_end', coalesce(s.cancel_at_period_end, false), 'past_due_since', s.past_due_since,
    'retry_at', s.retry_at, 'comp', coalesce(s.comp, false),
    'paid_by', case when s.paid_by is not null then (select jsonb_build_object('id', pr.id, 'name', pr.name) from practices pr where pr.id = s.paid_by) end,
    'next_plan', case when s.next_plan_id is not null then jsonb_build_object('id', np.id, 'name', np.name, 'billing', s.next_billing) end,
    'card', (select jsonb_build_object('id', c.id, 'last4', c.last4, 'brand', c.brand, 'expiry', c.expiry) from subscription_cards c
             where c.org_id = p_org and c.active order by (c.id = s.card_id) desc, c.created_at desc limit 1))
  from (select 1) one left join subscriptions s on s.org_id = p_org left join plans np on np.id = s.next_plan_id
$$;

create or replace function public.subscription_start(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; pl public.plans; cur public.plans; s public.subscriptions; v_billing text := coalesce(nullif(p->>'billing', ''), 'month');
  v_method text := nullif(p->>'method', ''); v_price numeric; v_cur_price numeric; c public.subscription_charges; v_card uuid; v_bal numeric;
begin
  m := private.require(p_org, 'manage_settings');
  if m.role not in ('owner', 'admin') then raise exception 'Only the owner or an admin of the business changes its plan.' using errcode = '42501'; end if;
  if (select is_sample from orgs where id = p_org) then raise exception 'The sample business stays on its plan.'; end if;
  if v_billing not in ('month', 'year') then raise exception 'Pay monthly or yearly.'; end if;
  select * into s from subscriptions where org_id = p_org for update;
  select * into cur from plans where id = private.org_plan_id(p_org);
  select * into pl from plans where id = nullif(p->>'plan_id', '')::uuid and active and (public or id = cur.id);
  if not found then raise exception 'Choose a plan.'; end if;
  v_price := private.plan_price(pl, v_billing);
  if pl.id = cur.id and coalesce(s.billing, 'month') = v_billing and coalesce(s.status, 'active') <> 'past_due' and not coalesce(s.cancel_at_period_end, false)
     and s.next_plan_id is null and (v_price = 0 or s.pay_method is not null) and s.paid_by is null then
    raise exception 'The business is on % already.', pl.name;
  end if;

  -- A free plan starts at once.
  if v_price = 0 then
    insert into subscriptions (org_id, plan_id, status, billing, pay_method, current_period_start, current_period_end)
    values (p_org, pl.id, 'active', v_billing, null, now(), now() + case when v_billing = 'year' then interval '1 year' else interval '1 month' end)
    on conflict (org_id) do update set plan_id = excluded.plan_id, status = 'active', billing = excluded.billing, pay_method = null, card_id = null,
      current_period_start = excluded.current_period_start, current_period_end = excluded.current_period_end, trial_ends_at = null,
      cancel_at_period_end = false, next_plan_id = null, next_billing = null, past_due_since = null, retry_at = null, attempts = 0, paid_by = null, updated_at = now();
    update subscription_charges set status = 'cancelled', updated_at = now() where org_id = p_org and status = 'pending';
    return jsonb_build_object('action', 'done', 'state', public.subscription_state(p_org));
  end if;

  if coalesce(v_method, '') not in ('card', 'wallet') then raise exception 'Pay by card or from the wallet.'; end if;
  select id into v_card from subscription_cards where org_id = p_org and active order by (id = s.card_id) desc, created_at desc limit 1;
  -- The business paying for itself again: the accountant's card is not used for it.
  if s.paid_by is not null then v_card := null; s.card_id := null; end if;

  -- A first trial of a plan with one: no charge until it ends.
  if pl.trial_days > 0 and not coalesce(s.trial_used, false) and not exists (select 1 from subscription_charges where org_id = p_org and status = 'successful') then
    insert into subscriptions (org_id, plan_id, status, billing, pay_method, card_id, current_period_start, current_period_end, trial_ends_at, trial_used)
    values (p_org, pl.id, 'trialing', v_billing, v_method, case when v_method = 'card' then v_card end, now(), now() + make_interval(days => pl.trial_days),
      now() + make_interval(days => pl.trial_days), true)
    on conflict (org_id) do update set plan_id = excluded.plan_id, status = 'trialing', billing = excluded.billing, pay_method = excluded.pay_method,
      card_id = excluded.card_id, current_period_start = excluded.current_period_start, current_period_end = excluded.current_period_end,
      trial_ends_at = excluded.trial_ends_at, trial_used = true, cancel_at_period_end = false, next_plan_id = null, next_billing = null,
      past_due_since = null, retry_at = null, attempts = 0, paid_by = null, updated_at = now();
    return jsonb_build_object('action', 'done', 'trial', true, 'state', public.subscription_state(p_org));
  end if;

  -- A cheaper plan while a paid period runs: it starts when the period ends.
  v_cur_price := private.plan_price(cur, coalesce(s.billing, 'month'));
  if s.status = 'active' and s.current_period_end > now() and v_cur_price > 0 and not coalesce(s.comp, false)
     and v_price < private.plan_price(cur, v_billing) then
    update subscriptions set next_plan_id = pl.id, next_billing = v_billing, pay_method = v_method, card_id = coalesce(v_card, card_id),
      cancel_at_period_end = false, paid_by = null, updated_at = now() where org_id = p_org;
    return jsonb_build_object('action', 'scheduled', 'at', s.current_period_end, 'state', public.subscription_state(p_org));
  end if;

  if v_method = 'wallet' then
    select private.wallet_balance(w.id) - coalesce((select sum(amount + fee) from payouts where wallet_id = w.id and status in ('approved', 'processing', 'pending_approval')), 0)
      into v_bal from wallets w join orgs o on o.id = w.org_id where w.org_id = p_org and w.rail = o.payment_rail and w.status = 'active';
    if v_bal is null then raise exception 'Open the business wallet in Payments first, or pay by card.'; end if;
    if v_bal < v_price then
      raise exception 'The wallet has ₦% available and the plan costs ₦%. Fund the wallet or pay by card.', to_char(v_bal, 'FM999,999,999,990.00'),
        to_char(v_price, 'FM999,999,999,990.00');
    end if;
  end if;
  -- The same choice made again within half an hour uses the charge already waiting.
  select * into c from subscription_charges where org_id = p_org and kind = 'start' and status = 'pending' and plan_id = pl.id and billing = v_billing
    and method = v_method and created_at > now() - interval '30 minutes' order by created_at desc limit 1;
  if not found then
    update subscription_charges set status = 'cancelled', updated_at = now() where org_id = p_org and kind = 'start' and status = 'pending';
    insert into subscription_charges (org_id, plan_id, billing, amount, method, kind, card_id, tx_ref, requested_by)
    values (p_org, pl.id, v_billing, v_price, v_method, 'start', case when v_method = 'card' and coalesce((p->>'use_saved')::boolean, true) then v_card end,
      'SUB-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)), m.id)
    returning * into c;
  end if;
  return jsonb_build_object('action', case when v_method = 'wallet' then 'wallet' when c.card_id is not null then 'charge_card' else 'checkout' end,
    'charge_id', c.id, 'tx_ref', c.tx_ref, 'amount', c.amount);
end $$;

create or replace function public.subscription_method(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_card uuid;
begin
  m := private.require(p_org, 'manage_settings');
  if m.role not in ('owner', 'admin') then raise exception 'Only the owner or an admin of the business changes its plan.' using errcode = '42501'; end if;
  if p->>'method' in ('card', 'wallet') and exists (select 1 from subscriptions where org_id = p_org and paid_by is not null) then
    raise exception 'Your accountant pays for Counta. To pay for it yourself, choose a plan above.';
  end if;
  if nullif(p->>'remove_card_id', '') is not null then
    update subscription_cards set active = false where id = (p->>'remove_card_id')::uuid and org_id = p_org;
    update subscriptions set card_id = null, pay_method = case when pay_method = 'card' then null else pay_method end, updated_at = now()
    where org_id = p_org and card_id = (p->>'remove_card_id')::uuid;
  end if;
  if p->>'method' in ('card', 'wallet') then
    select id into v_card from subscription_cards where org_id = p_org and active order by created_at desc limit 1;
    if p->>'method' = 'card' and v_card is null then raise exception 'Add a card first: pay for the plan by card once, and Counta keeps it for renewals.'; end if;
    update subscriptions set pay_method = p->>'method', card_id = case when p->>'method' = 'card' then v_card else card_id end, updated_at = now() where org_id = p_org;
  end if;
  return public.subscription_state(p_org);
end $$;

create or replace function public.svc_subscription_charge(p_charge uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('charge', to_jsonb(c) - 'journal_id', 'plan', jsonb_build_object('name', pl.name, 'code', pl.code),
    'org', jsonb_build_object('id', o.id, 'name', o.name, 'phone', o.phone,
      'email', coalesce((select coalesce(mb.email, u.email) from members mb left join auth.users u on u.id = mb.user_id where mb.org_id = o.id and mb.role = 'owner'
        order by mb.created_at limit 1), o.email)),
    'card', (select jsonb_build_object('token', k.token, 'email', k.email, 'last4', k.last4) from subscription_cards k
             where k.active and (case when c.practice_id is not null then k.practice_id = c.practice_id else k.org_id = c.org_id end)
               and (c.card_id is null or k.id = c.card_id) order by (k.id = c.card_id) desc, k.created_at desc limit 1),
    'payer', case when c.practice_id is not null then (select jsonb_build_object('kind', 'practice', 'id', pr.id, 'name', pr.name,
        'email', coalesce(nullif(pr.email, ''), (select u.email from auth.users u where u.id = pr.created_by)), 'phone', pr.phone) from practices pr where pr.id = c.practice_id) end,
    'return_path', case when c.practice_id is not null then '/practice/billing' else '/settings/subscription' end,
    'wallet', (select jsonb_build_object('id', w.id, 'account_ref', w.account_ref, 'rail', w.rail) from wallets w
               where w.org_id = c.org_id and w.rail = o.payment_rail and w.status = 'active' limit 1))
  from subscription_charges c join orgs o on o.id = c.org_id join plans pl on pl.id = c.plan_id where c.id = p_charge
$$;

create or replace function public.svc_subscription_charge_update(p_tx_ref text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.subscription_charges; s public.subscriptions; pl public.plans; v_card uuid; v_start timestamptz; v_end timestamptz; o public.orgs;
  v_net numeric; v_vat numeric; v_ledger text; j public.journals; v_status text := p->>'status';
begin
  select * into c from subscription_charges where tx_ref = p_tx_ref for update;
  if not found then raise exception 'Charge not found.'; end if;
  if c.status in ('successful', 'cancelled') or (c.status = 'failed' and v_status <> 'successful') then
    return jsonb_build_object('status', c.status, 'unchanged', true);
  end if;
  select * into o from orgs where id = c.org_id;
  select * into pl from plans where id = c.plan_id;
  if v_status = 'sent' then
    update subscription_charges set status = 'sent', provider_ref = coalesce(nullif(p->>'provider_ref', ''), provider_ref), updated_at = now() where id = c.id;
    return jsonb_build_object('status', 'sent');
  end if;
  if v_status = 'successful' and (coalesce((p->>'amount')::numeric, 0) < c.amount - 0.01 or coalesce(nullif(p->>'currency', ''), 'NGN') <> 'NGN') then
    v_status := 'failed'; p := p || jsonb_build_object('error', format('The rail reports %s %s, not ₦%s.', coalesce(p->>'currency', 'NGN'), coalesce(p->>'amount', '0'), c.amount));
  end if;
  if v_status = 'successful' then
    if nullif(p->'card'->>'token', '') is not null then
      select id into v_card from subscription_cards where token = p->'card'->>'token' and active
        and (case when c.practice_id is not null then practice_id = c.practice_id else org_id = c.org_id end);
      if v_card is null then
        insert into subscription_cards (org_id, practice_id, token, email, last4, brand, expiry, added_by)
        values (case when c.practice_id is null then c.org_id end, c.practice_id, p->'card'->>'token', coalesce(nullif(p->'card'->>'email', ''), 'unknown@counta.ng'),
          left(p->'card'->>'last4', 4), left(p->'card'->>'brand', 30), left(p->'card'->>'expiry', 7), c.requested_by)
        returning id into v_card;
      end if;
    end if;
    select * into s from subscriptions where org_id = c.org_id for update;
    v_start := case when c.kind = 'renewal' and s.current_period_end is not null and s.current_period_end > now() - interval '7 days'
                    then s.current_period_end else now() end;
    v_end := v_start + case when c.billing = 'year' then interval '1 year' else interval '1 month' end;
    insert into subscriptions (org_id, plan_id, status, billing, pay_method, card_id, current_period_start, current_period_end, trial_used, paid_by)
    values (c.org_id, c.plan_id, 'active', c.billing, c.method, coalesce(v_card, c.card_id), v_start, v_end, false, c.practice_id)
    on conflict (org_id) do update set plan_id = excluded.plan_id, status = 'active', billing = excluded.billing, pay_method = excluded.pay_method,
      card_id = case when excluded.paid_by is distinct from subscriptions.paid_by then excluded.card_id else coalesce(excluded.card_id, subscriptions.card_id) end,
      current_period_start = excluded.current_period_start,
      current_period_end = excluded.current_period_end, trial_ends_at = null, cancel_at_period_end = false, next_plan_id = null, next_billing = null,
      past_due_since = null, retry_at = null, attempts = 0, paid_by = excluded.paid_by, updated_at = now();
    -- Paid from the wallet: the books show the money leaving it, as a software subscription (VAT included in the price).
    if c.method = 'wallet' then
      select b.ledger_code into v_ledger from wallets w join bank_accounts b on b.id = w.bank_account_id
      where w.org_id = c.org_id and w.rail = o.payment_rail and w.status = 'active' limit 1;
      if v_ledger is not null then
        v_net := case when o.vat_registered then round(c.amount / (1 + private.vat_rate(private.local_day(c.org_id, now()))), 2) else c.amount end;
        v_vat := c.amount - v_net;
        j := private.post_entry(c.org_id, 'Counta ' || pl.name || ' plan · ' || c.tx_ref, 'subscription', c.id, null, null, jsonb_build_array(
          jsonb_build_object('code', coalesce((select code from accounts where code = '6303'), private.acct(c.org_id, 'expenses_default')), 'debit', v_net,
            'memo', 'Counta ' || pl.name || ' plan, ' || case when c.billing = 'year' then 'a year' else 'a month' end),
          jsonb_build_object('code', private.acct(c.org_id, 'input_vat'), 'debit', v_vat, 'memo', 'VAT on the Counta plan'),
          jsonb_build_object('code', v_ledger, 'credit', c.amount, 'memo', 'Counta plan · ' || c.tx_ref)),
          now(), jsonb_build_object('origin', 'system', 'evidence', jsonb_build_array(jsonb_build_object('type', 'subscription', 'ref', c.tx_ref))));
      end if;
    end if;
    update subscription_charges set status = 'successful', paid_at = now(), provider_ref = coalesce(nullif(p->>'provider_ref', ''), provider_ref),
      card_id = coalesce(v_card, card_id), journal_id = j.id, error = null, updated_at = now() where id = c.id;
    perform private.notify_perm(c.org_id, 'manage_settings', 'plan', 'Counta plan paid: ' || pl.name,
      format('₦%s %s. It runs to %s.', to_char(c.amount, 'FM999,999,999,990.00'),
        case when c.practice_id is not null then 'by ' || coalesce((select name from practices where id = c.practice_id), 'your accountant')
             when c.method = 'wallet' then 'from the wallet' else 'by card' end,
        to_char(v_end at time zone 'Africa/Lagos', 'DD Mon YYYY')), '/settings/subscription', 'sub-' || c.id);
    return jsonb_build_object('status', 'successful', 'period_end', v_end);
  end if;
  -- Failed.
  update subscription_charges set status = 'failed', error = left(coalesce(nullif(p->>'error', ''), 'The payment did not go through.'), 300),
    provider_ref = coalesce(nullif(p->>'provider_ref', ''), provider_ref), updated_at = now() where id = c.id;
  if c.kind = 'renewal' then
    update subscriptions set status = 'past_due', past_due_since = coalesce(past_due_since, now()), attempts = attempts + 1, retry_at = now() + interval '1 day',
      updated_at = now() where org_id = c.org_id;
    if c.practice_id is not null then perform private.practice_notify(c.practice_id, 'Counta plan payment failed for ' || coalesce((select name from orgs where id = c.org_id), 'a client'),
      'Counta tries the card again tomorrow. Check the card under Billing.', '/practice/billing'); end if;
    perform private.notify_perm(c.org_id, 'manage_settings', 'plan', 'Counta plan payment failed',
      format('%s. Counta tries again tomorrow; after three days the business moves to the %s plan. Check the card or fund the wallet in Settings, Subscription.',
        left(coalesce(nullif(p->>'error', ''), 'The payment did not go through'), 200), (select name from plans where id = private.default_plan_id())),
      '/settings/subscription', 'sub-fail-' || c.org_id);
  end if;
  return jsonb_build_object('status', 'failed');
end $$;

create or replace function private.renewal_charge(s public.subscriptions, p_plan uuid, p_billing text) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare pl public.plans; v_id uuid; v_card uuid;
begin
  select * into pl from plans where id = p_plan;
  select id into v_card from subscription_cards where active
    and (case when s.paid_by is not null then practice_id = s.paid_by else org_id = s.org_id end) order by (id = s.card_id) desc, created_at desc limit 1;
  insert into subscription_charges (org_id, plan_id, billing, amount, method, kind, card_id, tx_ref, practice_id)
  values (s.org_id, pl.id, p_billing, private.plan_price(pl, p_billing), case when s.paid_by is not null then 'card' else s.pay_method end, 'renewal',
    case when s.pay_method = 'card' or s.paid_by is not null then v_card end,
    'SUB-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)), s.paid_by)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.svc_subscription_tick() returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.subscriptions; pl public.plans; v_out jsonb := '[]'::jsonb; v_id uuid; v_has_card boolean; v_np public.plans; v_default uuid := private.default_plan_id();
begin
  for s in select * from subscriptions where current_period_end <= now() or status = 'past_due' for update skip locked loop
    select * into pl from plans where id = s.plan_id;
    v_has_card := exists (select 1 from subscription_cards where active and (case when s.paid_by is not null then practice_id = s.paid_by else org_id = s.org_id end));
    if exists (select 1 from subscription_charges where org_id = s.org_id and kind = 'renewal' and status in ('pending', 'sent') and created_at > now() - interval '6 hours') then
      continue;
    end if;
    if s.plan_id = v_default or s.comp or private.plan_price(pl, s.billing) = 0 then
      -- Free and complimentary plans roll on.
      if s.current_period_end <= now() then
        update subscriptions set current_period_start = current_period_end,
          current_period_end = current_period_end + case when billing = 'year' then interval '1 year' else interval '1 month' end,
          status = 'active', past_due_since = null, retry_at = null, attempts = 0, updated_at = now() where org_id = s.org_id;
      end if;
      continue;
    end if;
    if s.cancel_at_period_end and s.current_period_end <= now() then
      perform private.to_default_plan(s.org_id, format('The %s plan was cancelled and has ended.', pl.name));
      continue;
    end if;
    if s.status = 'past_due' and s.past_due_since < now() - interval '3 days' then
      perform private.to_default_plan(s.org_id, format('The %s plan was not paid for three days.', pl.name));
      continue;
    end if;
    if s.status = 'past_due' and s.retry_at > now() then continue; end if;
    if s.current_period_end > now() and s.status <> 'past_due' then continue; end if;
    if s.next_plan_id is not null then
      select * into v_np from plans where id = s.next_plan_id;
      if private.plan_price(v_np, coalesce(s.next_billing, s.billing)) = 0 then
        update subscriptions set plan_id = v_np.id, billing = coalesce(next_billing, billing), pay_method = null, next_plan_id = null, next_billing = null,
          current_period_start = now(), current_period_end = now() + interval '1 month', status = 'active', updated_at = now() where org_id = s.org_id;
        continue;
      end if;
    end if;
    if (s.pay_method is null and s.paid_by is null) or ((s.pay_method = 'card' or s.paid_by is not null) and not v_has_card) then
      if s.status = 'trialing' then
        perform private.to_default_plan(s.org_id, format('The %s trial ended with no way to pay chosen.', pl.name));
      elsif s.status <> 'past_due' then
        update subscriptions set status = 'past_due', past_due_since = now(), retry_at = now() + interval '1 day', updated_at = now() where org_id = s.org_id;
        perform private.notify_perm(s.org_id, 'manage_settings', 'plan', 'Choose how to pay for Counta',
          format('The %s plan is due and no card or wallet is set to pay it. After three days the business moves to the standard plan.', pl.name),
          '/settings/subscription', 'sub-nomethod-' || s.org_id);
      end if;
      continue;
    end if;
    v_id := private.renewal_charge(s, coalesce(s.next_plan_id, s.plan_id), coalesce(s.next_billing, s.billing));
    v_out := v_out || jsonb_build_array(jsonb_build_object('charge_id', v_id, 'method', case when s.paid_by is not null then 'card' else s.pay_method end));
  end loop;
  return v_out;
end $$;
-- ---------------------------------------------------------------------------
-- 11. Who may call what
-- ---------------------------------------------------------------------------
revoke execute on function public.create_practice(jsonb), public.update_practice(uuid, jsonb), public.practice_set_licence(uuid, jsonb),
  public.practice_invite_member(uuid, jsonb), public.practice_update_member(uuid, jsonb), public.practice_assign(uuid, uuid, boolean),
  public.practice_invite_client(uuid, jsonb), public.business_invite_accountant(uuid, jsonb), public.practice_invite_check(text, uuid),
  public.practice_accept(text, jsonb), public.practice_decline(text), public.practice_withdraw(uuid), public.practice_end(uuid),
  public.practice_set_billing(uuid, text), public.practices_mine(), public.practice_home(uuid), public.practice_client(uuid),
  public.practice_request_create(uuid, jsonb), public.practice_request_close(uuid, text), public.practice_note_add(uuid, text), public.practice_note_delete(uuid),
  public.practice_take_request(uuid, uuid), public.practice_decline_request(uuid), public.org_accountants(uuid), public.org_request_answer(uuid, jsonb),
  public.admin_licences(text), public.admin_licence_decide(uuid, text, text), public.practice_plan_start(uuid, jsonb), public.practice_plan_stop(uuid),
  public.practice_charge_check(text), public.practice_billing(uuid), public.practice_card_remove(uuid, uuid),
  public.filing_version_start(uuid, text, text, text), public.filing_version(uuid), public.filing_version_check(uuid, jsonb), public.filing_version_apply(uuid, jsonb),
  public.filing_version_withdraw(uuid, text), public.filing_version_current(uuid, text, text, text), public.filing_versions_list(uuid, text)
  from public, anon;
grant execute on function public.create_practice(jsonb), public.update_practice(uuid, jsonb), public.practice_set_licence(uuid, jsonb),
  public.practice_invite_member(uuid, jsonb), public.practice_update_member(uuid, jsonb), public.practice_assign(uuid, uuid, boolean),
  public.practice_invite_client(uuid, jsonb), public.business_invite_accountant(uuid, jsonb), public.practice_invite_check(text, uuid),
  public.practice_accept(text, jsonb), public.practice_decline(text), public.practice_withdraw(uuid), public.practice_end(uuid),
  public.practice_set_billing(uuid, text), public.practices_mine(), public.practice_home(uuid), public.practice_client(uuid),
  public.practice_request_create(uuid, jsonb), public.practice_request_close(uuid, text), public.practice_note_add(uuid, text), public.practice_note_delete(uuid),
  public.practice_take_request(uuid, uuid), public.practice_decline_request(uuid), public.org_accountants(uuid), public.org_request_answer(uuid, jsonb),
  public.admin_licences(text), public.admin_licence_decide(uuid, text, text), public.practice_plan_start(uuid, jsonb), public.practice_plan_stop(uuid),
  public.practice_charge_check(text), public.practice_billing(uuid), public.practice_card_remove(uuid, uuid),
  public.filing_version_start(uuid, text, text, text), public.filing_version(uuid), public.filing_version_check(uuid, jsonb), public.filing_version_apply(uuid, jsonb),
  public.filing_version_withdraw(uuid, text), public.filing_version_current(uuid, text, text, text), public.filing_versions_list(uuid, text)
  to authenticated;
-- The invitation page says what a link is for before the person signs in.
revoke execute on function public.practice_invite_preview(text) from public;
grant execute on function public.practice_invite_preview(text) to anon, authenticated;
revoke all on function public.svc_practice_invite_link(text, uuid), public.svc_filing_version_save(jsonb) from public, anon, authenticated;
grant execute on function public.svc_practice_invite_link(text, uuid), public.svc_filing_version_save(jsonb) to service_role;
revoke all on function private.practice_me(uuid), private.practice_require(uuid, boolean), private.practice_client_require(uuid, boolean),
  private.licence_text(public.practice_members), private.practice_notify(uuid, text, text, text), private.practice_sync_seats(uuid), private.client_health(uuid),
  private.practice_member_json(public.practice_members, boolean), private.practice_request_json(public.practice_requests),
  private.filing_period_ok(text, text, text), private.filing_label(text, text, text), private.filing_day(uuid, text, text), private.filing_locked(uuid, text, text, text),
  private.filing_perm(text), private.filing_version_brief(public.filing_versions), private.fs_line_account(uuid, text, date, date),
  private.filing_proposal(uuid, text, text, jsonb, numeric), private.filing_lines_check(public.filing_versions, jsonb),
  private.filing_statement(public.filing_versions, text, text, text, text, text), private.filing_accountant(uuid, text, boolean),
  private.tax_expected(uuid, text, date, text, integer), private.tax_expected_books(uuid, text, date, text, integer)
  from public, anon, authenticated;
