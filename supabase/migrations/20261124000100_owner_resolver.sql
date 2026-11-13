-- Practice management, part 1: the owner resolver.
--
-- A practice may run a business under full mandate: it creates the business itself, no client user exists, and the firm's
-- partners and managers work in it with an admin place that acts as the owner (members.acts_as_owner). Everything that asks
-- "is this the owner?" goes through one resolver, so every owner-only path keeps working for the firm's people:
--   private.perm_of(m, 'owner')       true for the owner and for an acting owner (so every require(..., 'owner') follows);
--   private.acts_as_owner(org, user)  the same question for a given person (for service functions);
--   private.is_owner(org)             the signed-in person (RLS on orgs and locations, the kyc/ storage rule);
--   private.org_contact(org)          who Counta treats as the business's contact: the owner, or under full mandate the
--                                     engagement partner's place (else the oldest acting owner's).
-- private.mandate(org) is the practice link that runs the business (still found after the mandate ends without a
-- handover), private.is_managed(org) whether a practice runs it. create_org is split: private.create_org_core makes the
-- business and its locations without any member, and create_org adds the owner exactly as before.
--
-- The business row's new columns (who runs it, the director's confirmation, read-only, retention, sending) change only
-- through Counta's own functions.

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------
alter table public.members add column if not exists acts_as_owner boolean not null default false;
alter table public.members add constraint members_acts_as_owner_check check (not acts_as_owner or (practice_id is not null and role = 'admin'));

alter table public.orgs
  add column if not exists managed_by uuid references public.practices(id) on delete restrict,
  add column if not exists director_confirmed_at timestamptz,
  add column if not exists read_only_at timestamptz,
  add column if not exists retain_until date,
  add column if not exists send_mode text not null default 'send' check (send_mode in ('send', 'download_only'));
create index if not exists orgs_managed_by on public.orgs(managed_by) where managed_by is not null;

alter table public.practice_clients
  add column if not exists mode text not null default 'involved' check (mode in ('involved', 'full')),
  add column if not exists engagement_partner_id uuid references public.practice_members(id) on delete set null,
  add column if not exists intake_id uuid,
  add column if not exists alert_email text check (alert_email is null or alert_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  add column if not exists retention_years int check (retention_years is null or retention_years >= 5),
  add column if not exists end_kind text check (end_kind in ('handover', 'ended')),
  add column if not exists fee_customer_id uuid references public.customers(id) on delete set null,
  add column if not exists fee_vendor_id uuid references public.vendors(id) on delete set null;
-- A full mandate is always billed to the practice, and a business has at most one active full mandate.
alter table public.practice_clients add constraint practice_clients_full_billing check (mode = 'involved' or billing = 'practice');
create unique index if not exists practice_clients_one_full on public.practice_clients(org_id) where mode = 'full' and status = 'active';
create index if not exists practice_clients_engagement_partner on public.practice_clients(engagement_partner_id) where engagement_partner_id is not null;
create index if not exists practice_clients_fee_customer on public.practice_clients(fee_customer_id) where fee_customer_id is not null;
create index if not exists practice_clients_fee_vendor on public.practice_clients(fee_vendor_id) where fee_vendor_id is not null;

-- ---------------------------------------------------------------------------
-- 2. Who acts as the owner
-- ---------------------------------------------------------------------------
create or replace function private.perm_of(m public.members, p_perm text) returns boolean
language sql immutable set search_path = public, private as $$
  select case
    when m.id is null then false
    when m.role = 'owner' or m.acts_as_owner then true
    else case p_perm
      when 'record_sales' then m.p_record_sales
      when 'receive_stock' then m.p_receive_stock
      when 'count_stock' then m.p_count_stock
      when 'approve_adjustments' then m.p_approve_adjustments
      when 'edit_prices' then m.p_edit_prices
      when 'approve_pos' then m.p_approve_pos
      when 'transfer_stock' then m.p_transfer_stock
      when 'see_margins' then m.p_see_margins
      when 'issue_stock' then coalesce(m.p_issue_stock, false)
      when 'keep_books' then coalesce(m.p_keep_books, false)
      when 'make_payments' then coalesce(m.p_make_payments, false)
      when 'add_items' then coalesce(m.p_add_items, false)
      when 'approve_payments' then coalesce(m.p_approve_payments, false)
      when 'file_tax' then coalesce(m.p_file_tax, false)
      when 'manage_team' then coalesce(m.p_manage_team, false)
      when 'manage_settings' then coalesce(m.p_manage_settings, false)
      when 'owner' then false
      else false end
  end
$$;

-- The person's active place in the business is the owner's, or a practice place acting as the owner.
create or replace function private.acts_as_owner(p_org uuid, p_user uuid) returns boolean
language sql stable set search_path = public, private as $$
  select exists (select 1 from public.members m
    where m.org_id = p_org and m.user_id = p_user and m.status = 'active' and (m.role = 'owner' or m.acts_as_owner))
$$;

-- Policy helper, called as the signed-in person.
create or replace function private.is_owner(p_org uuid) returns boolean
language sql stable security definer set search_path = public, private as $$
  select private.acts_as_owner(p_org, auth.uid())
$$;

-- ---------------------------------------------------------------------------
-- 3. Businesses run by a practice, and the business's contact
-- ---------------------------------------------------------------------------
-- The full-mandate link of the practice that runs the business: the active one first, else the latest (a mandate that
-- ended without a handover keeps the business with the practice).
create or replace function private.mandate(p_org uuid) returns public.practice_clients
language sql stable set search_path = public, private as $$
  select c.* from public.practice_clients c join public.orgs o on o.id = c.org_id
  where c.org_id = p_org and c.practice_id = o.managed_by and c.mode = 'full'
  order by c.status = 'active' desc, c.started_at desc nulls last
  limit 1
$$;

create or replace function private.is_managed(p_org uuid) returns boolean
language sql stable set search_path = public, private as $$
  select exists (select 1 from public.orgs where id = p_org and managed_by is not null)
$$;

-- Who Counta treats as the business's contact (the recipient of what would go to the owner, the member for system
-- postings): the owner; under full mandate the engagement partner's active place, else the oldest active acting owner.
create or replace function private.org_contact(p_org uuid) returns public.members
language plpgsql stable set search_path = public, private as $$
declare c public.members; v_user uuid;
begin
  if not private.is_managed(p_org) then
    select * into c from members where org_id = p_org and role = 'owner' and status = 'active' order by created_at limit 1;
    return c;
  end if;
  select pm.user_id into v_user from practice_members pm where pm.id = (private.mandate(p_org)).engagement_partner_id;
  if v_user is not null then
    select * into c from members where org_id = p_org and user_id = v_user and status = 'active';
    if found then return c; end if;
  end if;
  select * into c from members where org_id = p_org and acts_as_owner and status = 'active' order by created_at limit 1;
  return c;
end $$;

-- ---------------------------------------------------------------------------
-- 4. The business row: the new columns change only through Counta's own functions
-- ---------------------------------------------------------------------------
create or replace function private.orgs_guard() returns trigger
language plpgsql set search_path = public, private as $$
declare v_plain text[] := array['name', 'industry', 'offering', 'email', 'phone', 'vat_registered', 'margin_threshold', 'safety_days', 'cover_days',
  'cash_available', 'voice_trust_threshold'];
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if new.identity_status is distinct from old.identity_status or new.identity is distinct from old.identity
     or new.taxstreem_org_id is distinct from old.taxstreem_org_id or new.is_sample is distinct from old.is_sample or new.id is distinct from old.id
     or new.managed_by is distinct from old.managed_by or new.director_confirmed_at is distinct from old.director_confirmed_at
     or new.read_only_at is distinct from old.read_only_at or new.retain_until is distinct from old.retain_until
     or new.send_mode is distinct from old.send_mode then
    raise exception 'That cannot be changed here.' using errcode = '42501';
  end if;
  -- Someone given "Change settings" edits the business details and stock rules directly. Payment controls, the books and
  -- tax records change only through Counta's own functions, which check their own permissions (or by the owner).
  if not private.is_owner(new.id) and (to_jsonb(new) - v_plain) is distinct from (to_jsonb(old) - v_plain) then
    raise exception 'Only the owner changes that here.' using errcode = '42501';
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Creating a business: the core (no member), and create_org (the caller becomes the owner, as before)
-- ---------------------------------------------------------------------------
create or replace function private.create_org_core(p_name text, p_email text, p_phone text, p_locations jsonb, p_vat_registered boolean,
  p_is_sample boolean) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare v_org uuid; v_uid uuid := auth.uid(); l jsonb; v_i int := 0; v_code text; v_base text; v_n int;
begin
  if v_uid is null then raise exception 'Sign in first.'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Business name is required.'; end if;
  insert into orgs (name, email, phone, vat_registered, created_by, is_sample)
  values (trim(p_name), nullif(trim(p_email), ''), nullif(trim(p_phone), ''), coalesce(p_vat_registered, true), v_uid, coalesce(p_is_sample, false))
  returning id into v_org;

  for l in select * from jsonb_array_elements(coalesce(p_locations, '[]'::jsonb)) loop
    continue when coalesce(trim(l->>'name'), '') = '';
    v_i := v_i + 1;
    v_base := coalesce(nullif(upper(trim(l->>'code')), ''), upper(left(regexp_replace(l->>'name', '[^A-Za-z]', '', 'g'), 3)));
    if v_base = '' then v_base := 'LOC'; end if;
    v_code := v_base; v_n := 1;
    while exists (select 1 from locations where org_id = v_org and code = v_code) loop
      v_n := v_n + 1; v_code := v_base || v_n;
    end loop;
    insert into locations (org_id, name, code, address, is_main)
    values (v_org, trim(l->>'name'), v_code, nullif(trim(l->>'address'), ''), v_i = 1);
  end loop;
  if v_i = 0 then
    insert into locations (org_id, name, code, is_main) values (v_org, 'Main store', 'MAIN', true);
  end if;
  return v_org;
end $$;

create or replace function public.create_org(p_name text, p_email text default null, p_phone text default null, p_display_name text default null,
  p_locations jsonb default '[]'::jsonb, p_vat_registered boolean default true, p_is_sample boolean default false) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare v_org uuid; v_uid uuid := auth.uid(); v_email text;
begin
  select email into v_email from auth.users where id = v_uid;
  -- The business's email defaults to the caller's.
  v_org := private.create_org_core(p_name, coalesce(nullif(trim(p_email), ''), v_email), p_phone, p_locations, p_vat_registered, p_is_sample);
  insert into members (org_id, user_id, email, display_name, role, title, status,
    p_record_sales, p_receive_stock, p_count_stock, p_approve_adjustments, p_edit_prices, p_approve_pos, p_transfer_stock, p_see_margins)
  values (v_org, v_uid, v_email, coalesce(nullif(trim(p_display_name), ''), split_part(v_email, '@', 1)), 'owner', 'Owner', 'active',
    true, true, true, true, true, true, true, true);
  return v_org;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------------
-- core.sql grants every private function to authenticated: the helpers this migration creates or redefines are not callable
-- by the signed-in person, except is_owner, which RLS policies call as that person.
revoke all on function private.perm_of(public.members, text), private.acts_as_owner(uuid, uuid), private.mandate(uuid), private.is_managed(uuid),
  private.org_contact(uuid), private.orgs_guard(), private.create_org_core(text, text, text, jsonb, boolean, boolean)
  from public, anon, authenticated;
revoke execute on function private.is_owner(uuid) from public, anon;
grant execute on function private.is_owner(uuid) to authenticated;
