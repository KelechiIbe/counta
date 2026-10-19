-- Counta · team invitations and role permissions, the director's NIN check, Martina everywhere, business-aware wording
--
-- 1. Permissions. Five new permissions (add products, approve payouts, file tax returns, manage the team, change settings)
--    beside the eleven there were, and an Admin role. Each business keeps its own defaults per role (role_permissions);
--    a change to a role reaches everyone in it, and one person can still have their own exceptions (perm_overrides).
--    Nobody can give a permission they do not hold, and only the owner sets up admins.
-- 2. Invitations. Inviting someone emails them a one-time link (member_invites keeps only its hash, for seven days).
--    Joining needs that link and an account with the invited email address; signing up with an invited address is no
--    longer enough on its own, since Supabase does not confirm email addresses for this project yet.
-- 3. The director's NIN. After the business is set up, the owner gives an NIN (typed, or said to Martina). The mono function
--    looks it up with Mono and hands over only the names on it and the last four digits; the database compares the names
--    with the directors (or proprietors) on the CAC record and keeps the outcome. When it does not match, an NIN slip is
--    read by Gemini; if that does not match either, TaxStreem reviews it. Until then the business's wallet, payment links
--    and payouts stay locked; the books work as normal. Conversations with Martina in which an NIN was said are deleted
--    from ElevenLabs once the check is done.
-- 4. Martina everywhere: an allowance for everyday conversations (separate from onboarding) and a short, permission-aware
--    brief of the business for her to start from.
-- 5. Wording. A business records whether it sells goods, services or both, so Martina and the screens can say "revenue"
--    and "clients" to a consultancy and "sales" and "customers" to a shop.

-- ---------------------------------------------------------------------------
-- 1. Permissions and roles
-- ---------------------------------------------------------------------------
alter table public.members add column if not exists p_add_items boolean;
alter table public.members add column if not exists p_approve_payments boolean;
alter table public.members add column if not exists p_file_tax boolean;
alter table public.members add column if not exists p_manage_team boolean;
alter table public.members add column if not exists p_manage_settings boolean;
alter table public.members add column if not exists perm_overrides jsonb not null default '{}'::jsonb;
-- What people could do before stays as it was: whoever edited prices added items, whoever made payments approved them,
-- whoever kept the books filed tax, and the owner managed the team and settings.
update public.members set p_add_items = (role = 'owner' or p_edit_prices) where p_add_items is null;
update public.members set p_approve_payments = (role = 'owner' or p_make_payments) where p_approve_payments is null;
update public.members set p_file_tax = (role = 'owner' or p_keep_books) where p_file_tax is null;
update public.members set p_manage_team = (role = 'owner') where p_manage_team is null;
update public.members set p_manage_settings = (role = 'owner') where p_manage_settings is null;
alter table public.members alter column p_add_items set not null;
alter table public.members alter column p_approve_payments set not null;
alter table public.members alter column p_file_tax set not null;
alter table public.members alter column p_manage_team set not null;
alter table public.members alter column p_manage_settings set not null;
alter table public.members drop constraint if exists members_role_check;
alter table public.members add constraint members_role_check check (role in ('owner', 'admin', 'manager', 'staff', 'cashier', 'accountant'));
-- Whoever records sales can never also edit prices or approve adjustments, except the owner and admins, who run the business.
alter table public.members drop constraint if exists sales_cannot_edit;
alter table public.members add constraint sales_cannot_edit check (
  role in ('owner', 'admin') or not (p_record_sales and (p_edit_prices or p_approve_adjustments)));

-- The permissions, in the order the settings screen lists them.
create or replace function private.perm_keys() returns text[]
language sql immutable set search_path = '' as $$
  select array['record_sales', 'edit_prices', 'add_items', 'receive_stock', 'count_stock', 'transfer_stock', 'issue_stock',
    'approve_adjustments', 'approve_pos', 'make_payments', 'approve_payments', 'keep_books', 'see_margins', 'file_tax',
    'manage_team', 'manage_settings']
$$;

create or replace function private.role_template(p_role text) returns jsonb
language sql immutable set search_path = public, private as $$
  select case p_role
    when 'owner' then '{"record_sales":true,"edit_prices":true,"add_items":true,"receive_stock":true,"count_stock":true,"transfer_stock":true,"issue_stock":true,"approve_adjustments":true,"approve_pos":true,"make_payments":true,"approve_payments":true,"keep_books":true,"see_margins":true,"file_tax":true,"manage_team":true,"manage_settings":true}'
    when 'admin' then '{"record_sales":true,"edit_prices":true,"add_items":true,"receive_stock":true,"count_stock":true,"transfer_stock":true,"issue_stock":true,"approve_adjustments":true,"approve_pos":true,"make_payments":true,"approve_payments":true,"keep_books":true,"see_margins":true,"file_tax":true,"manage_team":true,"manage_settings":true}'
    when 'manager' then '{"record_sales":true,"edit_prices":false,"add_items":true,"receive_stock":true,"count_stock":true,"transfer_stock":true,"issue_stock":true,"approve_adjustments":false,"approve_pos":false,"make_payments":false,"approve_payments":false,"keep_books":false,"see_margins":true,"file_tax":false,"manage_team":false,"manage_settings":false}'
    when 'accountant' then '{"record_sales":false,"edit_prices":false,"add_items":false,"receive_stock":false,"count_stock":false,"transfer_stock":false,"issue_stock":false,"approve_adjustments":true,"approve_pos":false,"make_payments":false,"approve_payments":false,"keep_books":true,"see_margins":true,"file_tax":true,"manage_team":false,"manage_settings":false}'
    when 'staff' then '{"record_sales":true,"edit_prices":false,"add_items":false,"receive_stock":true,"count_stock":true,"transfer_stock":false,"issue_stock":true,"approve_adjustments":false,"approve_pos":false,"make_payments":false,"approve_payments":false,"keep_books":false,"see_margins":false,"file_tax":false,"manage_team":false,"manage_settings":false}'
    else '{"record_sales":true,"edit_prices":false,"add_items":false,"receive_stock":false,"count_stock":false,"transfer_stock":false,"issue_stock":false,"approve_adjustments":false,"approve_pos":false,"make_payments":false,"approve_payments":false,"keep_books":false,"see_margins":false,"file_tax":false,"manage_team":false,"manage_settings":false}'
  end::jsonb
$$;

-- Each business's own defaults per role, where it has changed them. Read by its members; written by save_role_permissions.
create table if not exists public.role_permissions (
  org_id uuid not null references public.orgs(id) on delete cascade,
  role text not null check (role in ('admin', 'manager', 'staff', 'cashier', 'accountant')),
  perms jsonb not null,
  updated_by uuid references public.members(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (org_id, role)
);
create index if not exists role_permissions_updated_by on public.role_permissions(updated_by);
alter table public.role_permissions enable row level security;
drop policy if exists role_permissions_read on public.role_permissions;
create policy role_permissions_read on public.role_permissions for select to authenticated using ((select private.is_member(org_id)));
revoke all on public.role_permissions from anon, authenticated;
grant select on public.role_permissions to authenticated;

-- Only true or false for the known permissions.
create or replace function private.clean_perms(p jsonb) returns jsonb
language sql immutable set search_path = public, private as $$
  select coalesce(jsonb_object_agg(k, (p->>k)::boolean), '{}'::jsonb)
  from unnest(private.perm_keys()) k where jsonb_typeof(p->k) = 'boolean'
$$;

-- A role's permissions in a business: the standard defaults, with the business's changes on top.
create or replace function private.role_perms(p_org uuid, p_role text) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select case when p_role = 'owner' then private.role_template('owner')
    else private.role_template(p_role) || coalesce((select private.clean_perms(rp.perms) from role_permissions rp where rp.org_id = p_org and rp.role = p_role), '{}'::jsonb) end
$$;

-- What a member holds, read from the columns.
create or replace function private.member_perms(mb public.members) returns jsonb
language sql immutable set search_path = public, private as $$
  select jsonb_build_object('record_sales', mb.p_record_sales, 'edit_prices', mb.p_edit_prices, 'add_items', mb.p_add_items,
    'receive_stock', mb.p_receive_stock, 'count_stock', mb.p_count_stock, 'transfer_stock', mb.p_transfer_stock, 'issue_stock', mb.p_issue_stock,
    'approve_adjustments', mb.p_approve_adjustments, 'approve_pos', mb.p_approve_pos, 'make_payments', mb.p_make_payments,
    'approve_payments', mb.p_approve_payments, 'keep_books', mb.p_keep_books, 'see_margins', mb.p_see_margins, 'file_tax', mb.p_file_tax,
    'manage_team', mb.p_manage_team, 'manage_settings', mb.p_manage_settings)
$$;

-- People whose permissions were set one by one before roles had defaults of their own keep them, as their own exceptions,
-- so a later change to the role (or to their phone number) never quietly takes them away.
update public.members mb set perm_overrides = d.over
from (
  select x.id, coalesce(jsonb_object_agg(k, (private.member_perms(x)->>k)::boolean)
           filter (where private.member_perms(x)->k is distinct from private.role_perms(x.org_id, x.role)->k), '{}'::jsonb) as over
  from public.members x cross join unnest(private.perm_keys()) k
  where x.role <> 'owner' and x.perm_overrides = '{}'::jsonb
  group by x.id
) d
where mb.id = d.id and d.over <> '{}'::jsonb;

-- Sets a member's permission columns from their role and their own exceptions.
create or replace function private.apply_member_perms(p_member uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare mb public.members; e jsonb;
begin
  select * into mb from members where id = p_member;
  if not found then return; end if;
  e := private.role_perms(mb.org_id, mb.role) || private.clean_perms(mb.perm_overrides);
  update members set
    p_record_sales = (e->>'record_sales')::boolean, p_edit_prices = (e->>'edit_prices')::boolean, p_add_items = (e->>'add_items')::boolean,
    p_receive_stock = (e->>'receive_stock')::boolean, p_count_stock = (e->>'count_stock')::boolean, p_transfer_stock = (e->>'transfer_stock')::boolean,
    p_issue_stock = (e->>'issue_stock')::boolean, p_approve_adjustments = (e->>'approve_adjustments')::boolean, p_approve_pos = (e->>'approve_pos')::boolean,
    p_make_payments = (e->>'make_payments')::boolean, p_approve_payments = (e->>'approve_payments')::boolean, p_keep_books = (e->>'keep_books')::boolean,
    p_see_margins = (e->>'see_margins')::boolean, p_file_tax = (e->>'file_tax')::boolean, p_manage_team = (e->>'manage_team')::boolean,
    p_manage_settings = (e->>'manage_settings')::boolean
  where id = p_member;
end $$;

create or replace function private.perm_of(m public.members, p_perm text) returns boolean
language sql immutable set search_path = public, private as $$
  select case
    when m.id is null then false
    when m.role = 'owner' then true
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

-- New members get their role's permissions for anything the insert leaves out.
create or replace function private.member_defaults() returns trigger
language plpgsql set search_path = public, private as $$
declare e jsonb := private.role_perms(new.org_id, new.role);
begin
  if new.p_issue_stock is null then new.p_issue_stock := coalesce((e->>'issue_stock')::boolean, false); end if;
  if new.p_add_items is null then new.p_add_items := coalesce((e->>'add_items')::boolean, false); end if;
  if new.p_approve_payments is null then new.p_approve_payments := coalesce((e->>'approve_payments')::boolean, false); end if;
  if new.p_file_tax is null then new.p_file_tax := coalesce((e->>'file_tax')::boolean, false); end if;
  if new.p_manage_team is null then new.p_manage_team := coalesce((e->>'manage_team')::boolean, false); end if;
  if new.p_manage_settings is null then new.p_manage_settings := coalesce((e->>'manage_settings')::boolean, false); end if;
  if new.p_keep_books is null then new.p_keep_books := coalesce((e->>'keep_books')::boolean, false); end if;
  if new.p_make_payments is null then new.p_make_payments := coalesce((e->>'make_payments')::boolean, false); end if;
  return new;
end $$;

-- The permissions someone may hand out: the owner any, anyone else only what they hold themselves.
create or replace function private.check_grantable(m public.members, p jsonb) returns void
language plpgsql stable security definer set search_path = public, private as $$
declare k text;
begin
  if m.role = 'owner' then return; end if;
  foreach k in array private.perm_keys() loop
    if coalesce((p->>k)::boolean, false) and not private.perm_of(m, k) then
      raise exception 'You cannot give a permission you do not have yourself (%).', replace(k, '_', ' ') using errcode = '42501';
    end if;
  end loop;
end $$;

-- Recording sales, and editing prices or approving adjustments, never go to the same person (owner and admins aside).
create or replace function private.check_split(p_role text, p jsonb, p_who text) returns void
language plpgsql immutable set search_path = public, private as $$
begin
  if p_role not in ('owner', 'admin') and coalesce((p->>'record_sales')::boolean, false)
     and (coalesce((p->>'edit_prices')::boolean, false) or coalesce((p->>'approve_adjustments')::boolean, false)) then
    raise exception '%: someone who records sales cannot also edit prices or approve adjustments. Turn one of them off.', p_who;
  end if;
end $$;

create or replace function private.role_label(p_role text) returns text
language sql immutable set search_path = '' as $$
  select case p_role when 'owner' then 'Owner' when 'admin' then 'Admin' when 'manager' then 'Manager' when 'accountant' then 'Accountant'
    when 'staff' then 'Staff' when 'cashier' then 'Cashier' else initcap(p_role) end
$$;

-- The team, every role's permissions and who may change what. For anyone who manages the team (others see only themselves).
create or replace function public.get_team(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_all boolean;
begin
  m := private.require(p_org, null);
  v_all := private.perm_of(m, 'manage_team');
  return jsonb_build_object(
    'can_manage', v_all,
    'is_owner', m.role = 'owner',
    'me', m.id,
    'my_perms', case when m.role = 'owner' then private.role_template('owner') else private.member_perms(m) end,
    'roles', (select jsonb_agg(jsonb_build_object('role', r, 'label', private.role_label(r), 'perms', private.role_perms(p_org, r),
        'standard', private.role_template(r), 'changed', exists (select 1 from role_permissions rp where rp.org_id = p_org and rp.role = r),
        'people', (select count(*) from members mb where mb.org_id = p_org and mb.role = r and mb.status <> 'disabled'))
      order by array_position(array['admin', 'manager', 'accountant', 'staff', 'cashier'], r))
      from unnest(array['admin', 'manager', 'accountant', 'staff', 'cashier']) r),
    'members', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', mb.id, 'display_name', mb.display_name, 'email', mb.email, 'phone', mb.phone, 'role', mb.role, 'role_label', private.role_label(mb.role),
        'title', mb.title, 'location_id', mb.location_id, 'status', mb.status, 'has_login', mb.user_id is not null, 'is_me', mb.id = m.id,
        'perms', case when mb.role = 'owner' then private.role_template('owner') else private.member_perms(mb) end,
        'overrides', private.clean_perms(mb.perm_overrides),
        'invite', (select jsonb_build_object('sent_at', i.sent_at, 'expires_at', i.expires_at, 'sent_count', i.sent_count,
            'expired', i.expires_at < now()) from member_invites i where i.member_id = mb.id))
      order by (mb.role = 'owner') desc, mb.status = 'disabled', mb.created_at), '[]'::jsonb)
      from members mb where mb.org_id = p_org and (v_all or mb.id = m.id))
  );
end $$;

-- A role's defaults for this business. The change reaches everyone in the role, keeping each person's own exceptions.
create or replace function public.save_role_permissions(p_org uuid, p_role text, p_perms jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; p jsonb; v_std jsonb; mb public.members; n int := 0;
begin
  m := private.require(p_org, 'manage_team');
  if p_role not in ('admin', 'manager', 'staff', 'cashier', 'accountant') then raise exception 'Choose a role.'; end if;
  if p_role = 'admin' and m.role <> 'owner' then raise exception 'Only the owner changes what admins can do.' using errcode = '42501'; end if;
  if p_role = m.role and m.role <> 'owner' then raise exception 'Ask the owner to change your own role.' using errcode = '42501'; end if;
  p := private.role_perms(p_org, p_role) || private.clean_perms(coalesce(p_perms, '{}'::jsonb));
  perform private.check_grantable(m, p);
  perform private.check_split(p_role, p, private.role_label(p_role));
  for mb in select * from members where org_id = p_org and role = p_role and status <> 'disabled' loop
    perform private.check_split(p_role, p || private.clean_perms(mb.perm_overrides), mb.display_name);
  end loop;
  v_std := private.role_template(p_role);
  if p = v_std then
    delete from role_permissions where org_id = p_org and role = p_role;
  else
    insert into role_permissions (org_id, role, perms, updated_by) values (p_org, p_role, p, m.id)
    on conflict (org_id, role) do update set perms = excluded.perms, updated_by = excluded.updated_by, updated_at = now();
  end if;
  for mb in select * from members where org_id = p_org and role = p_role loop
    -- An exception that now matches the role is no longer an exception.
    update members set perm_overrides = (select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from jsonb_each(private.clean_perms(mb.perm_overrides)) x(k, v) where v <> p->k)
    where id = mb.id;
    perform private.apply_member_perms(mb.id);
    n := n + 1;
  end loop;
  return jsonb_build_object('role', p_role, 'perms', p, 'people', n);
end $$;

-- ---------------------------------------------------------------------------
-- 2. Invitations
-- ---------------------------------------------------------------------------
create table if not exists public.member_invites (
  member_id uuid primary key references public.members(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  token_hash text,
  expires_at timestamptz,
  sent_at timestamptz,
  sent_count int not null default 0,
  invited_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists member_invites_org on public.member_invites(org_id);
create index if not exists member_invites_invited_by on public.member_invites(invited_by);
create unique index if not exists member_invites_token on public.member_invites(token_hash) where token_hash is not null;
-- Nobody reads invitations directly; the functions below do.
alter table public.member_invites enable row level security;
revoke all on public.member_invites from anon, authenticated;

-- Invitation emails carry the member id only; the link is made when the email goes out (svc_invite), so no usable
-- token ever rests in the messages table. Anyone who can see the team sees the invitations sent to it.
drop policy if exists messages_read on public.messages;
create policy messages_read on public.messages for select to authenticated
  using ((select private.is_member(org_id)) and (template <> 'invite' or (select private.has_perm(org_id, 'manage_team'))));

create or replace function private.queue_invite(p_member uuid, p_by public.members) returns void
language plpgsql security definer set search_path = public, private as $$
declare mb public.members; o public.orgs; v_count int;
begin
  select * into mb from members where id = p_member;
  if mb.email is null then raise exception 'Add an email address for % first.', mb.display_name; end if;
  if mb.status <> 'invited' then raise exception '% has already joined.', mb.display_name; end if;
  select coalesce(sum(1), 0) into v_count from messages where org_id = mb.org_id and template = 'invite' and params->>'member_id' = mb.id::text
    and created_at > now() - interval '1 day';
  if v_count >= 5 then raise exception 'That is enough invitations to % for today. Try again tomorrow.', mb.display_name; end if;
  select * into o from orgs where id = mb.org_id;
  insert into member_invites (member_id, org_id, invited_by) values (mb.id, mb.org_id, p_by.id)
  on conflict (member_id) do update set invited_by = excluded.invited_by;
  perform private.queue_message(mb.org_id, 'email', mb.email, 'invite', 'Join ' || o.name || ' on Counta',
    jsonb_build_object('member_id', mb.id, 'name', mb.display_name, 'business', o.name, 'role_label', private.role_label(mb.role),
      'invited_by', p_by.display_name), null, null, p_by.id);
end $$;

create or replace function public.invite_member(p_org uuid, p_name text, p_email text, p_role text, p_title text default null,
  p_location uuid default null, p_phone text default null) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare m public.members; p jsonb; v_id uuid; v_email text := nullif(lower(trim(coalesce(p_email, ''))), '');
begin
  m := private.require(p_org, 'manage_team');
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter the person''s name.'; end if;
  if p_role not in ('admin', 'manager', 'staff', 'cashier', 'accountant') then raise exception 'Choose a role.'; end if;
  if p_role = 'admin' and m.role <> 'owner' then raise exception 'Only the owner makes someone an admin.' using errcode = '42501'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email address does not look right.'; end if;
  if v_email is not null and exists (select 1 from members where org_id = p_org and lower(email) = v_email) then
    raise exception '% is already on your team.', v_email;
  end if;
  if p_location is not null and not exists (select 1 from locations where id = p_location and org_id = p_org) then raise exception 'Unknown branch.'; end if;
  -- The role's permissions as this business has set them, which the person inviting must hold themselves.
  p := private.role_perms(p_org, p_role);
  perform private.check_grantable(m, p);
  insert into members (org_id, user_id, email, display_name, phone, role, title, location_id, status,
    p_record_sales, p_receive_stock, p_count_stock, p_approve_adjustments, p_edit_prices, p_approve_pos, p_transfer_stock, p_see_margins,
    p_issue_stock, p_keep_books, p_make_payments, p_add_items, p_approve_payments, p_file_tax, p_manage_team, p_manage_settings)
  values (p_org, null, v_email, trim(p_name), nullif(trim(p_phone), ''), p_role, coalesce(nullif(trim(p_title), ''), private.role_label(p_role)), p_location,
    case when v_email is null then 'active' else 'invited' end,
    (p->>'record_sales')::boolean, (p->>'receive_stock')::boolean, (p->>'count_stock')::boolean, (p->>'approve_adjustments')::boolean,
    (p->>'edit_prices')::boolean, (p->>'approve_pos')::boolean, (p->>'transfer_stock')::boolean, (p->>'see_margins')::boolean,
    (p->>'issue_stock')::boolean, (p->>'keep_books')::boolean, (p->>'make_payments')::boolean, (p->>'add_items')::boolean,
    (p->>'approve_payments')::boolean, (p->>'file_tax')::boolean, (p->>'manage_team')::boolean, (p->>'manage_settings')::boolean)
  returning id into v_id;
  -- Someone with an email gets the invitation by email; someone without one is on the team without a login.
  if v_email is not null then perform private.queue_invite(v_id, m); end if;
  return v_id;
end $$;

create or replace function public.resend_invite(p_member uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare t public.members; m public.members;
begin
  select * into t from members where id = p_member;
  if not found then raise exception 'Person not found.'; end if;
  m := private.require(t.org_id, 'manage_team');
  perform private.queue_invite(t.id, m);
  return jsonb_build_object('sent_to', t.email);
end $$;

-- For the messaging function as it sends an invitation: a fresh link, good for seven days. Earlier links stop working.
create or replace function public.svc_invite(p_member uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare mb public.members; o public.orgs; v_token text := encode(extensions.gen_random_bytes(24), 'hex'); v_by text;
begin
  select * into mb from members where id = p_member;
  if not found or mb.status <> 'invited' or mb.email is null then return null; end if;
  select * into o from orgs where id = mb.org_id;
  insert into member_invites (member_id, org_id, token_hash, expires_at, sent_at, sent_count)
  values (mb.id, mb.org_id, encode(extensions.digest(v_token, 'sha256'), 'hex'), now() + interval '7 days', now(), 1)
  on conflict (member_id) do update set token_hash = excluded.token_hash, expires_at = excluded.expires_at, sent_at = now(),
    sent_count = member_invites.sent_count + 1;
  select display_name into v_by from members where id = (select invited_by from member_invites where member_id = mb.id);
  return jsonb_build_object('link', coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app') || '/join?t=' || v_token,
    'name', mb.display_name, 'email', mb.email, 'business', o.name, 'role_label', private.role_label(mb.role), 'invited_by', v_by,
    'expires_at', now() + interval '7 days');
end $$;

-- What a link is for, shown on the join page before the person signs in.
create or replace function public.invite_preview(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare i public.member_invites; mb public.members;
begin
  if coalesce(p_token, '') !~ '^[0-9a-f]{48}$' then return jsonb_build_object('status', 'invalid'); end if;
  select * into i from member_invites where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
  if not found then return jsonb_build_object('status', 'invalid'); end if;
  select * into mb from members where id = i.member_id;
  return jsonb_build_object(
    'status', case when mb.status <> 'invited' then 'used' when i.expires_at < now() then 'expired' else 'open' end,
    'business', (select name from orgs where id = mb.org_id), 'name', mb.display_name, 'email', mb.email,
    'role_label', private.role_label(mb.role), 'invited_by', (select display_name from members where id = i.invited_by));
end $$;

-- Joining: the link, signed in with the invited email address.
create or replace function public.accept_invite(p_token text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.member_invites; mb public.members; v_email text;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if coalesce(p_token, '') !~ '^[0-9a-f]{48}$' then raise exception 'This invitation link is not complete. Open it from the email again.'; end if;
  select * into i from member_invites where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex') for update;
  if not found then raise exception 'This invitation link has been replaced or used. Ask for a new one.'; end if;
  select * into mb from members where id = i.member_id for update;
  if mb.status <> 'invited' then raise exception 'This invitation has already been used.'; end if;
  if i.expires_at < now() then raise exception 'This invitation has expired. Ask % for a new one.',
    coalesce((select display_name from members where id = i.invited_by), 'the business'); end if;
  select lower(email) into v_email from auth.users where id = auth.uid();
  if v_email is distinct from lower(mb.email) then
    raise exception 'This invitation is for %. Sign in with that email address to join.', mb.email using errcode = '42501';
  end if;
  if exists (select 1 from members where org_id = mb.org_id and user_id = auth.uid()) then
    update member_invites set token_hash = null where member_id = mb.id;
    raise exception 'You are already on this team.';
  end if;
  update members set user_id = auth.uid(), status = 'active' where id = mb.id;
  -- The link stays known so the join page can say it was used; it can never join anyone again.
  update member_invites set expires_at = now() where member_id = mb.id;
  return jsonb_build_object('org_id', mb.org_id, 'business', (select name from orgs where id = mb.org_id), 'role_label', private.role_label(mb.role));
end $$;

-- Signing up with an invited address no longer joins a business by itself: the email link does.
create or replace function public.claim_invites() returns int
language sql stable security definer set search_path = public as $$
  select 0
$$;

create or replace function public.update_member(p_member uuid, p_patch jsonb) returns void
language plpgsql security definer set search_path = public, private as $$
declare t public.members; m public.members; v_role text; v_over jsonb; e jsonb; k text;
begin
  select * into t from members where id = p_member;
  if not found then raise exception 'Person not found.'; end if;
  m := private.require(t.org_id, 'manage_team');
  if t.role = 'owner' and (p_patch ? 'role' or p_patch ? 'perms' or p_patch ? 'status' or p_patch ? 'reset_perms') then
    raise exception 'The owner keeps every permission.';
  end if;
  if t.id = m.id and m.role <> 'owner' and (p_patch ? 'role' or p_patch ? 'perms' or p_patch ? 'status' or p_patch ? 'reset_perms') then
    raise exception 'Ask the owner to change your own role or permissions.' using errcode = '42501';
  end if;
  if t.role = 'admin' and m.role <> 'owner' and (p_patch ? 'role' or p_patch ? 'perms' or p_patch ? 'status' or p_patch ? 'reset_perms') then
    raise exception 'Only the owner changes an admin.' using errcode = '42501';
  end if;
  v_role := coalesce(p_patch->>'role', t.role);
  if v_role not in ('owner', 'admin', 'manager', 'staff', 'cashier', 'accountant') then raise exception 'Unknown role.'; end if;
  if v_role = 'owner' and t.role <> 'owner' then raise exception 'Ownership transfer is not available here.'; end if;
  if v_role = 'admin' and t.role <> 'admin' and m.role <> 'owner' then raise exception 'Only the owner makes someone an admin.' using errcode = '42501'; end if;
  if coalesce(p_patch->>'status', t.status) not in ('active', 'invited', 'disabled') then raise exception 'Unknown status.'; end if;
  if p_patch->>'status' = 'active' and t.status = 'invited' then raise exception '% joins by accepting the invitation.', t.display_name; end if;

  -- Their own exceptions: what differs from the role. A new role starts clean unless permissions come with it.
  v_over := case when v_role <> t.role and not (p_patch ? 'perms') then '{}'::jsonb else private.clean_perms(t.perm_overrides) end;
  if coalesce((p_patch->>'reset_perms')::boolean, false) then v_over := '{}'::jsonb; end if;
  if p_patch ? 'perms' then
    e := private.role_perms(t.org_id, v_role) || v_over || private.clean_perms(p_patch->'perms');
    v_over := '{}'::jsonb;
    foreach k in array private.perm_keys() loop
      if e->k is distinct from private.role_perms(t.org_id, v_role)->k then v_over := v_over || jsonb_build_object(k, e->k); end if;
    end loop;
  end if;
  e := private.role_perms(t.org_id, v_role) || v_over;
  if v_role <> 'owner' then
    perform private.check_grantable(m, e);
    perform private.check_split(v_role, e, t.display_name);
  end if;
  update members set
    role = v_role,
    perm_overrides = v_over,
    display_name = coalesce(nullif(trim(p_patch->>'display_name'), ''), display_name),
    title = case when p_patch ? 'title' then nullif(trim(p_patch->>'title'), '') else title end,
    phone = case when p_patch ? 'phone' then nullif(trim(p_patch->>'phone'), '') else phone end,
    location_id = case when p_patch ? 'location_id' then nullif(p_patch->>'location_id', '')::uuid else location_id end,
    status = coalesce(p_patch->>'status', status)
  where id = p_member;
  if v_role <> 'owner' then perform private.apply_member_perms(p_member); end if;
  if p_patch->>'status' = 'disabled' then update member_invites set token_hash = null where member_id = p_member; end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. The director's NIN check, and payments locked until it passes
-- ---------------------------------------------------------------------------
-- not_required: businesses set up before this check existed, the sample business and TaxStreem sign-ins (TaxStreem has
--   checked them); pending: set up in onboarding, NIN not confirmed yet; verified: an NIN or NIN slip matched a director;
--   review: an NIN slip that did not match waits for TaxStreem; approved / rejected: TaxStreem's decision.
alter table public.orgs add column if not exists identity_status text not null default 'not_required';
alter table public.orgs drop constraint if exists orgs_identity_status_check;
alter table public.orgs add constraint orgs_identity_status_check
  check (identity_status in ('not_required', 'pending', 'verified', 'review', 'approved', 'rejected'));
-- How it was confirmed: the method, the director matched, the NIN's last four digits, when; the slip and the review.
-- Never the NIN itself, a photo, a date of birth or an address.
alter table public.orgs add column if not exists identity jsonb not null default '{}'::jsonb;

-- The identity check, the TaxStreem link and the sample flag change only through Counta's own functions, never by a direct
-- update from the app. Whoever may change settings updates the rest of the business's details directly, as the owner could.
create or replace function private.orgs_guard() returns trigger
language plpgsql set search_path = public, private as $$
declare v_plain text[] := array['name', 'industry', 'offering', 'email', 'phone', 'vat_registered', 'margin_threshold', 'safety_days', 'cover_days',
  'cash_available', 'voice_trust_threshold'];
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if new.identity_status is distinct from old.identity_status or new.identity is distinct from old.identity
     or new.taxstreem_org_id is distinct from old.taxstreem_org_id or new.is_sample is distinct from old.is_sample or new.id is distinct from old.id then
    raise exception 'That cannot be changed here.' using errcode = '42501';
  end if;
  -- Someone given "Change settings" edits the business details and stock rules directly. Payment controls, the books and
  -- tax records change only through Counta's own functions, which check their own permissions (or by the owner).
  if not private.is_owner(new.id) and (to_jsonb(new) - v_plain) is distinct from (to_jsonb(old) - v_plain) then
    raise exception 'Only the owner changes that here.' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists orgs_guard on public.orgs;
create trigger orgs_guard before update on public.orgs for each row execute function private.orgs_guard();
drop policy if exists orgs_update on public.orgs;
create policy orgs_update on public.orgs for update to authenticated
  using ((select private.is_owner(id)) or (select private.has_perm(id, 'manage_settings')))
  with check ((select private.is_owner(id)) or (select private.has_perm(id, 'manage_settings')));

create or replace function private.payments_open(p_org uuid) returns boolean
language sql stable security definer set search_path = public, private as $$
  select coalesce((select identity_status in ('not_required', 'verified', 'approved') from orgs where id = p_org), false)
$$;

create or replace function private.require_payments_open(p_org uuid) returns void
language plpgsql stable security definer set search_path = public, private as $$
declare v_status text;
begin
  select identity_status into v_status from orgs where id = p_org;
  if v_status in ('not_required', 'verified', 'approved') then return; end if;
  raise exception '%', case v_status
    when 'review' then 'Payments open once TaxStreem has checked the NIN slip. This usually takes a working day.'
    when 'rejected' then 'Payments are locked: TaxStreem could not confirm a director''s identity. A director can do the NIN check in Settings.'
    else 'Payments open once a director confirms their NIN. Do the NIN check in Settings, Business identity, or ask Martina.' end
    using errcode = '42501';
end $$;

-- Names compared without titles, punctuation or case: "Chief (Mrs) Ngozi O. Okafor-Eze" gives NGOZI, O, OKAFOR, EZE.
create or replace function private.name_tokens(p text) returns text[]
language sql immutable set search_path = '' as $$
  select coalesce(array_agg(t), '{}') from unnest(regexp_split_to_array(trim(regexp_replace(upper(coalesce(p, '')), '[^A-Z]+', ' ', 'g')), ' ')) t
  where t <> '' and t not in ('MR', 'MRS', 'MS', 'MISS', 'DR', 'CHIEF', 'ALHAJI', 'ALHAJA', 'ALH', 'ENGR', 'PROF', 'BARR', 'SIR', 'HRH',
    'OTUNBA', 'PASTOR', 'REV', 'ARC', 'ESQ', 'SAN', 'JNR', 'JR', 'SNR', 'SR', 'HON', 'PRINCE', 'PRINCESS', 'MAJ', 'GEN', 'CAPT', 'COL')
$$;

-- Two names are the same name when equal, or when one starts the other and both are at least five letters (EMMANUEL, EMMA is not).
create or replace function private.token_in(t text, list text[]) returns boolean
language sql immutable set search_path = '' as $$
  select exists (select 1 from unnest(list) x where x = t or (length(t) >= 5 and length(x) >= 5 and (x like t || '%' or t like x || '%')))
$$;

-- The people an NIN can confirm: directors of a company; for a business name or anything else, its proprietors, partners
-- and owners too. From the CAC record the business was set up with.
create or replace function private.identity_people(p_org uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  with k as (select * from kyc_profiles where org_id = p_org and status = 'submitted' order by submitted_at desc nulls last limit 1),
  cls as (select upper(coalesce(k.cac->'profile'->>'classification', '')) c, k.cac, k.source from k),
  people as (
    select 'director' as role, d as p from cls, jsonb_array_elements(coalesce(cls.cac->'profile'->'directors', '[]'::jsonb)) d
    union all
    select 'owner', s from cls, jsonb_array_elements(coalesce(cls.cac->'profile'->'shareholders', '[]'::jsonb)) s where cls.c not like 'COMPANY%'
    union all
    select 'owner', s from cls, jsonb_array_elements(coalesce(cls.cac->'psc', '[]'::jsonb)) s where cls.c not like 'COMPANY%')
  select coalesce(jsonb_agg(distinct jsonb_build_object('role', role, 'name', private.person(p),
      'surname', upper(coalesce(p->>'surname', '')), 'given', upper(concat_ws(' ', p->>'firstname', p->>'other_name'))))
    filter (where private.person(p) is not null), '[]'::jsonb)
  from people
$$;

-- The person the NIN's names match, or null. The surname must match, and so must a first or middle name; a record that
-- has the names the other way round (surname as first name) matches too.
create or replace function private.identity_match(p_first text, p_middle text, p_last text, p_people jsonb) returns jsonb
language plpgsql immutable set search_path = public, private as $$
declare x jsonb; f text[] := private.name_tokens(p_first); mid text[] := private.name_tokens(p_middle); l text[] := private.name_tokens(p_last);
  s text[]; g text[]; t text; ok_l boolean; ok_g boolean;
begin
  if coalesce(array_length(l, 1), 0) = 0 or coalesce(array_length(f, 1), 0) + coalesce(array_length(mid, 1), 0) = 0 then return null; end if;
  for x in select * from jsonb_array_elements(coalesce(p_people, '[]'::jsonb)) loop
    s := private.name_tokens(x->>'surname'); g := private.name_tokens(x->>'given');
    if coalesce(array_length(s, 1), 0) = 0 then
      -- Only a full name on record: every surname token and a first or middle name somewhere in it.
      g := private.name_tokens(x->>'name'); s := g;
    end if;
    ok_l := true;
    foreach t in array l loop if not private.token_in(t, s) then ok_l := false; end if; end loop;
    ok_g := false;
    foreach t in array f || mid loop if private.token_in(t, g) then ok_g := true; end if; end loop;
    if ok_l and ok_g then return x; end if;
    -- Names the other way round.
    ok_l := true;
    foreach t in array l loop if not private.token_in(t, g) then ok_l := false; end if; end loop;
    ok_g := false;
    foreach t in array f || mid loop if private.token_in(t, s) then ok_g := true; end if; end loop;
    if ok_l and ok_g then return x; end if;
  end loop;
  return null;
end $$;

-- The NIN check's state. The slip's details are the owner's only.
create or replace function private.identity_json(p_org uuid, p_owner boolean) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs;
begin
  select * into o from orgs where id = p_org;
  return jsonb_build_object(
    'status', o.identity_status,
    'payments_open', o.identity_status in ('not_required', 'verified', 'approved'),
    'can_check', p_owner,
    'method', o.identity->>'method', 'matched', o.identity->>'matched', 'matched_role', o.identity->>'matched_role',
    'last4', o.identity->>'last4', 'at', o.identity->>'at',
    'attempts', coalesce((o.identity->>'attempts')::int, 0),
    'registered', exists (select 1 from kyc_profiles k where k.org_id = p_org and k.status = 'submitted' and k.source = 'cac'),
    'people', (select coalesce(jsonb_agg(jsonb_build_object('name', x->>'name', 'role', x->>'role')), '[]'::jsonb) from jsonb_array_elements(private.identity_people(p_org)) x),
    'slip', case when p_owner then o.identity->'slip' end,
    'review', o.identity->'review');
end $$;

create or replace function public.identity_state(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  return private.identity_json(p_org, m.role = 'owner');
end $$;

-- For the mono function, after it looked the NIN up with Mono: only the names on the record and the last four digits come here.
create or replace function public.svc_identity_nin(p_user uuid, p_org uuid, p_last4 text, p_first text, p_middle text, p_last text,
  p_conversation text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; v_people jsonb; v_match jsonb; v_self text; v_registered boolean; v_attempts int;
begin
  if not exists (select 1 from members where org_id = p_org and user_id = p_user and role = 'owner' and status = 'active') then
    raise exception 'Only the owner confirms a director''s identity.' using errcode = '42501';
  end if;
  select * into o from orgs where id = p_org for update;
  if p_conversation is not null and p_conversation ~ '^[A-Za-z0-9_-]{6,80}$' then
    insert into voice_forget (conversation_id, user_id) values (p_conversation, p_user) on conflict (conversation_id) do nothing;
  end if;
  if o.identity_status in ('verified', 'approved', 'not_required') then
    return jsonb_build_object('verified', true, 'already', true, 'matched', o.identity->>'matched');
  end if;
  v_registered := exists (select 1 from kyc_profiles k where k.org_id = p_org and k.status = 'submitted' and k.source = 'cac');
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

-- The owner added an NIN slip (in the business's private kyc folder); the ai function reads it next.
create or replace function public.identity_slip(p_org uuid, p_path text, p_file_name text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if m.role <> 'owner' then raise exception 'Only the owner adds the NIN slip.' using errcode = '42501'; end if;
  if coalesce(p_path, '') !~ ('^' || p_org::text || '/kyc/nin-slip-[A-Za-z0-9._-]{1,120}$') then raise exception 'Upload the NIN slip again.'; end if;
  if (select identity_status from orgs where id = p_org) in ('verified', 'approved', 'not_required') then
    raise exception 'The business''s identity is already confirmed.';
  end if;
  update orgs set identity = identity || jsonb_build_object('slip', jsonb_build_object('path', p_path, 'file_name', left(coalesce(p_file_name, 'NIN slip'), 120),
    'at', now(), 'read', false)) where id = p_org;
  return public.identity_state(p_org);
end $$;

-- For the ai function, after Gemini read the slip: the names and last four digits on it. A match confirms the business;
-- otherwise TaxStreem reviews it.
create or replace function public.svc_identity_slip(p_user uuid, p_org uuid, p_extract jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; v_people jsonb; v_match jsonb; v_self text; v_registered boolean; v_is_slip boolean := coalesce((p_extract->>'is_nin_document')::boolean, false);
begin
  if not exists (select 1 from members where org_id = p_org and user_id = p_user and role = 'owner' and status = 'active') then
    raise exception 'Only the owner adds the NIN slip.' using errcode = '42501';
  end if;
  select * into o from orgs where id = p_org for update;
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

-- TaxStreem's reviewers: their Counta accounts, added by TaxStreem in the SQL editor.
create table if not exists public.platform_reviewers (
  user_id uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now()
);
alter table public.platform_reviewers enable row level security;
revoke all on public.platform_reviewers from anon, authenticated;

create or replace function private.is_reviewer() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.platform_reviewers where user_id = auth.uid())
$$;
create or replace function public.am_reviewer() returns boolean
language sql stable security definer set search_path = public, private as $$
  select private.is_reviewer()
$$;

-- NIN slips waiting for TaxStreem, and those decided in the last thirty days.
create or replace function public.identity_reviews() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  if not private.is_reviewer() then raise exception 'Only TaxStreem reviewers see this.' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'org_id', o.id, 'business', o.name, 'rc_number', o.rc_number, 'legal_form', o.legal_form, 'status', o.identity_status,
      'people', (select coalesce(jsonb_agg(jsonb_build_object('name', x->>'name', 'role', x->>'role')), '[]'::jsonb) from jsonb_array_elements(private.identity_people(o.id)) x),
      'slip', o.identity->'slip', 'review', o.identity->'review', 'attempts', coalesce((o.identity->>'attempts')::int, 0),
      'owner', (select jsonb_build_object('name', mb.display_name, 'email', coalesce(mb.email, u.email)) from members mb left join auth.users u on u.id = mb.user_id
        where mb.org_id = o.id and mb.role = 'owner' limit 1))
    order by o.identity_status <> 'review', (o.identity->'slip'->>'read_at') desc nulls last), '[]'::jsonb)
    from orgs o
    where o.identity_status = 'review'
       or (o.identity_status in ('approved', 'rejected') and (o.identity->'review'->>'at')::timestamptz > now() - interval '30 days'));
end $$;

create or replace function public.review_identity(p_org uuid, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs;
begin
  if not private.is_reviewer() then raise exception 'Only TaxStreem reviewers decide this.' using errcode = '42501'; end if;
  select * into o from orgs where id = p_org for update;
  if not found then raise exception 'Business not found.'; end if;
  if o.identity_status not in ('review', 'approved', 'rejected') then raise exception 'There is nothing to review for %.', o.name; end if;
  if not p_approve and length(trim(coalesce(p_note, ''))) < 5 then raise exception 'Say why, so the business knows what to do next.'; end if;
  update orgs set identity_status = case when p_approve then 'approved' else 'rejected' end,
    identity = identity || jsonb_build_object('review', jsonb_build_object('approved', p_approve, 'note', nullif(left(trim(coalesce(p_note, '')), 500), ''),
      'at', now(), 'by', auth.uid()))
  where id = p_org;
  perform private.notify_perm(p_org, 'owner', 'identity', case when p_approve then 'Payments are open' else 'We could not confirm the NIN slip' end,
    case when p_approve then 'TaxStreem confirmed the director''s identity. Your wallet, payment links and payouts are ready.'
      else coalesce(nullif(trim(p_note), ''), 'Check the NIN slip and try again.') end, '/settings#identity', 'identity-' || p_org);
  return jsonb_build_object('status', case when p_approve then 'approved' else 'rejected' end);
end $$;

-- ElevenLabs conversations in which an NIN was said, to be deleted there once the check is done.
create table if not exists public.voice_forget (
  conversation_id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  tries int not null default 0,
  done_at timestamptz
);
create index if not exists voice_forget_user on public.voice_forget(user_id);
alter table public.voice_forget enable row level security;
revoke all on public.voice_forget from anon, authenticated;

create or replace function public.svc_forget_add(p_user uuid, p_conversation text) returns void
language sql security definer set search_path = public, private as $$
  insert into voice_forget (conversation_id, user_id) select p_conversation, p_user where p_conversation ~ '^[A-Za-z0-9_-]{6,80}$'
  on conflict (conversation_id) do nothing;
$$;
create or replace function public.svc_forget_due(p_user uuid default null, p_limit int default 20) returns setof text
language sql stable security definer set search_path = public, private as $$
  select conversation_id from voice_forget
  where done_at is null and tries < 20 and (p_user is null or user_id = p_user) and created_at > now() - interval '40 days'
  order by created_at limit greatest(1, least(p_limit, 50))
$$;
create or replace function public.svc_forget_done(p_conversation text, p_ok boolean) returns void
language sql security definer set search_path = public, private as $$
  update voice_forget set done_at = case when p_ok then now() else done_at end, tries = tries + 1 where conversation_id = p_conversation;
$$;

-- Every 15 minutes: conversations still waiting to be deleted at ElevenLabs are tried again.
create or replace function private.forget_tick() returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if exists (select 1 from voice_forget where done_at is null and tries < 20 and created_at > now() - interval '40 days') then
    perform private.call_function('voice', jsonb_build_object('action', 'forget_pending'));
  end if;
end $$;
revoke execute on function private.forget_tick() from public, anon, authenticated;
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'counta-voice-forget';
    perform cron.schedule('counta-voice-forget', '*/15 * * * *', 'select private.forget_tick()');
  end if;
end $$;

-- Reviewers may open the NIN slips of businesses waiting for review.
create or replace function private.reviewer_may_read(p_name text) returns boolean
language sql stable security definer set search_path = public, private as $$
  select private.is_reviewer() and coalesce(p_name, '') ~ '^[0-9a-f-]{36}/kyc/nin-slip-'
    and exists (select 1 from public.orgs o where o.id::text = split_part(p_name, '/', 1) and o.identity_status in ('review', 'approved', 'rejected'))
$$;
do $$
begin
  if to_regclass('storage.objects') is not null then
    drop policy if exists "documents read by reviewers" on storage.objects;
    create policy "documents read by reviewers" on storage.objects for select to authenticated
      using (bucket_id = 'documents' and (select private.reviewer_may_read(name)));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Martina everywhere: everyday conversations have their own allowance
-- ---------------------------------------------------------------------------
alter table public.guide_sessions add column if not exists kind text not null default 'guide';
alter table public.guide_sessions drop constraint if exists guide_sessions_kind_check;
alter table public.guide_sessions add constraint guide_sessions_kind_check check (kind in ('guide', 'assistant'));
drop function if exists public.svc_guide_session(uuid, text);
-- Onboarding: eight conversations a day and 25 a week per person. Everyday help: 30 a day and 150 a week.
create or replace function public.svc_guide_session(p_user uuid, p_conversation text default null, p_kind text default 'guide') returns uuid
language plpgsql security definer set search_path = public, private as $$
declare v_id uuid; v_kind text := case when p_kind = 'assistant' then 'assistant' else 'guide' end;
  v_day int := case when p_kind = 'assistant' then 30 else 8 end; v_week int := case when p_kind = 'assistant' then 150 else 25 end;
begin
  perform pg_advisory_xact_lock(hashtext('guide:' || p_user::text));
  if (select count(*) from guide_sessions where user_id = p_user and kind = v_kind and started_at > now() - interval '1 day') >= v_day
     or (select count(*) from guide_sessions where user_id = p_user and kind = v_kind and started_at > now() - interval '7 days') >= v_week then
    return null;
  end if;
  insert into guide_sessions (user_id, conversation_id, kind) values (p_user, nullif(p_conversation, ''), v_kind) returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 5. What the business sells: goods, services or both, so the wording fits it
-- ---------------------------------------------------------------------------
alter table public.orgs add column if not exists offering text;
alter table public.orgs drop constraint if exists orgs_offering_check;
alter table public.orgs add constraint orgs_offering_check check (offering is null or offering in ('goods', 'services', 'both'));
alter table public.orgs add column if not exists category_id text references public.business_categories(id) on delete set null;
create index if not exists orgs_category_id on public.orgs(category_id);
-- From the onboarding answers of businesses already set up that way.
update public.orgs o set offering = coalesce(o.offering, nullif(k.answers->>'offering', ''), c.kind), category_id = coalesce(o.category_id, c.id)
from public.kyc_profiles k left join public.business_categories c on c.id = k.answers->>'category'
where k.org_id = o.id and k.status = 'submitted' and (o.offering is null or o.category_id is null);

-- ---------------------------------------------------------------------------
-- The new permissions where they belong: settings, approving payouts and filing tax returns
-- ---------------------------------------------------------------------------
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
        when 'identity' then 'confirming a director''s NIN' when 'team' then 'inviting the team' else 'finishing setup' end,
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

create or replace function public.update_branding(p_org uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; v_web text; v_color text; v_show jsonb; v_soc jsonb := '{}'::jsonb; k text; v text;
begin
  m := private.require(p_org, 'manage_settings');
  if p_patch ? 'brand_color' then
    v_color := upper(trim(p_patch->>'brand_color'));
    if v_color !~ '^#[0-9A-F]{6}$' then raise exception 'Choose a colour as a hex code such as #0072F5.'; end if;
  end if;
  if p_patch ? 'invoice_template' and p_patch->>'invoice_template' not in ('classic', 'modern', 'minimal') then
    raise exception 'Choose the Classic, Modern or Minimal template.';
  end if;
  if p_patch ? 'website' then
    v_web := nullif(trim(p_patch->>'website'), '');
    if v_web is not null and v_web !~* '^https?://' then v_web := 'https://' || v_web; end if;
    if v_web is not null and (v_web !~* '^https?://[^\s/]+\.[^\s]{2,}$' or length(v_web) > 200) then raise exception 'Check the website address.'; end if;
  end if;
  foreach k in array array['logo_path', 'shop_banner_path'] loop
    if nullif(p_patch->>k, '') is not null and (p_patch->>k) not like p_org::text || '/%' then raise exception 'Upload the picture again.'; end if;
  end loop;
  if p_patch ? 'invoice_show' then
    if jsonb_typeof(p_patch->'invoice_show') <> 'object' then raise exception 'Choose what the documents show.'; end if;
    select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_show from jsonb_each(p_patch->'invoice_show')
    where key in ('tin', 'rc_number', 'vat_status', 'amount_in_words', 'signature') and jsonb_typeof(value) = 'boolean';
  end if;
  if p_patch ? 'shop_socials' then
    if jsonb_typeof(p_patch->'shop_socials') <> 'object' then raise exception 'Social handles must be a list.'; end if;
    for k, v in select key, value from jsonb_each_text(p_patch->'shop_socials') loop
      continue when k not in ('instagram', 'facebook', 'tiktok', 'x');
      v := nullif(regexp_replace(trim(v), '^@', ''), '');
      continue when v is null;
      if v !~ '^[A-Za-z0-9._-]{1,60}$' then raise exception 'Enter the % handle without the web address.', initcap(k); end if;
      v_soc := v_soc || jsonb_build_object(k, v);
    end loop;
  end if;
  if private.num(p_patch->>'shop_min_order') < 0 then raise exception 'The smallest order cannot be negative.'; end if;
  update orgs set
    brand_color = coalesce(v_color, brand_color),
    invoice_template = coalesce(nullif(p_patch->>'invoice_template', ''), invoice_template),
    website = case when p_patch ? 'website' then v_web else website end,
    invoice_footer = case when p_patch ? 'invoice_footer' then left(nullif(trim(p_patch->>'invoice_footer'), ''), 500) else invoice_footer end,
    invoice_note = case when p_patch ? 'invoice_note' then left(nullif(trim(p_patch->>'invoice_note'), ''), 600) else invoice_note end,
    invoice_show = case when p_patch ? 'invoice_show' then invoice_show || v_show else invoice_show end,
    logo_path = case when p_patch ? 'logo_path' then nullif(p_patch->>'logo_path', '') else logo_path end,
    shop_banner_path = case when p_patch ? 'shop_banner_path' then nullif(p_patch->>'shop_banner_path', '') else shop_banner_path end,
    shop_tagline = case when p_patch ? 'shop_tagline' then left(nullif(trim(p_patch->>'shop_tagline'), ''), 120) else shop_tagline end,
    shop_socials = case when p_patch ? 'shop_socials' then v_soc else shop_socials end,
    shop_pay_on_delivery = coalesce((p_patch->>'shop_pay_on_delivery')::boolean, shop_pay_on_delivery),
    shop_min_order = coalesce(round(private.num(p_patch->>'shop_min_order'), 2), shop_min_order)
  where id = p_org returning * into o;
  return private.org_brand(o.id);
end $$;
create or replace function public.update_books_settings(p_org uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs;
begin
  m := private.require(p_org, 'manage_settings');
  if p_patch ? 'reporting_framework' and p_patch->>'reporting_framework' not in ('ifrs', 'ifrs_sme') then raise exception 'Choose IFRS or IFRS for SMEs.'; end if;
  update orgs set
    reporting_framework = coalesce(nullif(p_patch->>'reporting_framework', ''), reporting_framework),
    principal_activity = case when p_patch ? 'principal_activity' then nullif(trim(p_patch->>'principal_activity'), '') else principal_activity end,
    wht_small_company = coalesce((p_patch->>'wht_small_company')::boolean, wht_small_company)
  where id = p_org returning * into o;
  return jsonb_build_object('reporting_framework', o.reporting_framework, 'principal_activity', o.principal_activity, 'wht_small_company', o.wht_small_company);
end $$;
create or replace function public.update_message_settings(p_org uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; v_days int[];
begin
  m := private.require(p_org, 'manage_settings');
  if jsonb_typeof(p_patch->'reminder_days') = 'array' then
    select array_agg(distinct d::int order by d::int) into v_days from jsonb_array_elements_text(p_patch->'reminder_days') d where d ~ '^-?[0-9]{1,3}$' and d::int between -30 and 120;
  end if;
  if coalesce(p_patch->>'reply_to_email', '') <> '' and p_patch->>'reply_to_email' !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address.'; end if;
  update orgs set reminders_enabled = coalesce((p_patch->>'reminders_enabled')::boolean, reminders_enabled), reminder_days = coalesce(v_days, reminder_days),
    reply_to_email = case when p_patch ? 'reply_to_email' then nullif(lower(trim(p_patch->>'reply_to_email')), '') else reply_to_email end
  where id = p_org returning * into o;
  return jsonb_build_object('reminders_enabled', o.reminders_enabled, 'reminder_days', o.reminder_days, 'reply_to_email', o.reply_to_email);
end $$;

create or replace function public.set_spot_checks(p_org uuid, p_n int) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, 'manage_settings');
  if p_n is null or p_n < 0 or p_n > 25 then raise exception 'Choose between 0 and 25 items a day.'; end if;
  update orgs set spot_checks_per_day = p_n where id = p_org;
  return jsonb_build_object('spot_checks_per_day', p_n);
end $$;

create or replace function public.set_posting_rule(p_org uuid, p_role text, p_code text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; pr public.posting_roles; v_old text; v_name text; v_lines jsonb := '[]'::jsonb; x record; j public.journals;
begin
  m := private.require(p_org, 'manage_settings');
  select * into pr from posting_roles where role = p_role;
  if not found then raise exception 'Unknown posting rule.'; end if;
  select name into v_name from accounts where code = p_code and active and not is_group;
  if v_name is null or p_code !~ pr.allowed then
    raise exception '% cannot be used for %.', coalesce(p_code, 'That account'), lower(pr.label);
  end if;
  v_old := private.acct(p_org, p_role);
  if v_old = p_code then return jsonb_build_object('changed', false, 'account_code', p_code, 'account_name', v_name); end if;

  -- When no item names the old account itself, its whole ledger balance moves, so not even a
  -- rounding cent is left behind. Otherwise only the stock of items on the default moves, at WAC.
  if p_role = 'goods_in_transit'
     or (p_role = 'inventory' and not exists (select 1 from items where org_id = p_org and inventory_account = v_old)) then
    for x in select l.location_id, sum(l.debit - l.credit) as val from journal_lines l
             where l.org_id = p_org and l.account_code = v_old
             group by l.location_id having sum(l.debit - l.credit) <> 0 loop
      v_lines := v_lines || private.reclass_pair(p_code, v_old, x.val, x.location_id);
    end loop;
  elsif p_role = 'inventory' then
    for x in select s.location_id, round(sum(s.qty * coalesce(c.wac, 0)), 2) as val
             from stock_levels s join items i on i.id = s.item_id left join item_costs c on c.item_id = s.item_id
             where s.org_id = p_org and i.inventory_account is null
             group by s.location_id having round(sum(s.qty * coalesce(c.wac, 0)), 2) <> 0 loop
      v_lines := v_lines || private.reclass_pair(p_code, v_old, x.val, x.location_id);
    end loop;
  end if;
  if jsonb_array_length(v_lines) > 0 then
    j := private.post_journal(p_org, 'Reclass · ' || pr.label || ' from ' || v_old || ' to ' || p_code, 'reclass', null, m.id, m.id, v_lines);
  end if;

  insert into posting_rules (org_id, role, account_code, updated_by) values (p_org, p_role, p_code, m.id)
  on conflict (org_id, role) do update set account_code = excluded.account_code, updated_by = excluded.updated_by, updated_at = now();
  return jsonb_build_object('changed', true, 'account_code', p_code, 'account_name', v_name, 'journal_ref', j.ref);
end $$;

create or replace function public.set_item_inventory_account(p_item uuid, p_code text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare it public.items; m public.members; v_old text; v_new text; v_wac numeric; v_lines jsonb := '[]'::jsonb; x record; j public.journals;
begin
  select * into it from items where id = p_item;
  if not found then raise exception 'Item not found.'; end if;
  m := private.require(it.org_id, 'manage_settings');
  p_code := nullif(trim(coalesce(p_code, '')), '');
  if p_code is not null and (p_code !~ (select allowed from posting_roles where role = 'inventory')
     or not exists (select 1 from accounts where code = p_code and active and not is_group)) then
    raise exception '% is not an inventory account.', p_code;
  end if;
  v_old := private.inv_acct(p_item);
  v_new := coalesce(p_code, private.acct(it.org_id, 'inventory'));
  if v_old <> v_new then
    select wac into v_wac from item_costs where item_id = p_item;
    for x in select location_id, round(qty * coalesce(v_wac, 0), 2) as val from stock_levels
             where item_id = p_item and round(qty * coalesce(v_wac, 0), 2) <> 0 loop
      v_lines := v_lines || private.reclass_pair(v_new, v_old, x.val, x.location_id, p_item);
    end loop;
    if jsonb_array_length(v_lines) > 0 then
      j := private.post_journal(it.org_id, 'Reclass · ' || it.name || ' from ' || v_old || ' to ' || v_new, 'reclass', p_item, m.id, m.id, v_lines);
    end if;
  end if;
  perform set_config('app.reclass', 'on', true);
  update items set inventory_account = p_code where id = p_item;
  perform set_config('app.reclass', 'off', true);
  return jsonb_build_object('account_code', v_new, 'account_name', (select name from accounts where code = v_new), 'journal_ref', j.ref);
end $$;

create or replace function public.approve_payout(p_payout uuid, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare po public.payouts; m public.members;
begin
  select * into po from payouts where id = p_payout for update;
  if not found then raise exception 'Payout not found.'; end if;
  m := private.require(po.org_id, 'approve_payments');
  if po.batch_id is not null then
    raise exception 'Approve % with its bulk payment %.', po.number, (select number from payout_batches where id = po.batch_id);
  end if;
  if po.status <> 'pending_approval' then raise exception '% is %.', po.number, replace(po.status, '_', ' '); end if;
  if po.requested_by = m.id and m.role <> 'owner' then raise exception 'Someone other than the person who asked must approve it.'; end if;
  update payouts set status = case when p_approve then 'approved' else 'cancelled' end, approved_by = m.id, approved_at = now(),
    error = case when not p_approve then nullif(trim(p_note), '') else error end
  where id = po.id returning * into po;
  return to_jsonb(po);
end $$;

create or replace function public.approve_payout_batch(p_batch uuid, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare pb public.payout_batches; m public.members;
begin
  select * into pb from payout_batches where id = p_batch for update;
  if not found then raise exception 'Bulk payment not found.'; end if;
  m := private.require(pb.org_id, 'approve_payments');
  if pb.status <> 'pending_approval' then raise exception '% is %.', pb.number, replace(pb.status, '_', ' '); end if;
  if pb.requested_by = m.id and m.role <> 'owner' then raise exception 'Someone other than the person who asked must approve it.'; end if;
  update payout_batches set approved_by = m.id, approved_at = now(), note = case when not p_approve then nullif(trim(p_note), '') else note end where id = pb.id;
  update payouts set status = case when p_approve then 'approved' else 'cancelled' end, approved_by = m.id, approved_at = now(),
    error = case when not p_approve then coalesce(nullif(trim(p_note), ''), 'Not approved') else error end
  where batch_id = pb.id and status = 'pending_approval';
  return private.batch_json(pb.id);
end $$;

create or replace function public.file_vat_return(p_org uuid, p_period date, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_period date := date_trunc('month', p_period)::date; x jsonb; ch jsonb; j public.journals; v_refund numeric := round(coalesce(private.num(p->>'refund_claim'), 0), 2);
  v_jl jsonb; v_refundable numeric; v_end date;
begin
  m := private.require(p_org, 'file_tax');
  if v_period is null then raise exception 'Choose the month.'; end if;
  v_end := (v_period + interval '1 month' - interval '1 day')::date;
  if v_end >= private.local_day(p_org, now()) then raise exception 'File % after the month ends.', to_char(v_period, 'FMMonth YYYY'); end if;
  if exists (select 1 from vat_periods where org_id = p_org and period = v_period) then raise exception 'The % return is already filed.', to_char(v_period, 'FMMonth YYYY'); end if;
  perform private.require_open_day(p_org, v_end);
  ch := private.vat_chain(p_org, v_period);
  x := ch->-1;
  if x is null or (x->>'period')::date <> v_period then raise exception 'Nothing to file for %.', to_char(v_period, 'FMMonth YYYY'); end if;
  if v_refund < 0 then raise exception 'The refund cannot be negative.'; end if;
  v_refundable := (select coalesce(sum((l->>'amount')::numeric), 0) from jsonb_array_elements(x->'layers') l where (l->>'from')::date >= (v_period - interval '11 months')::date);
  if v_refund > v_refundable + 0.004 then
    raise exception 'A refund can only be claimed within 12 months; up to % of the credit qualifies.', private.naira(v_refundable);
  end if;
  v_jl := jsonb_build_array(
    jsonb_build_object('code', private.acct(p_org, 'output_vat'), 'debit', (x->>'output')::numeric - (x->>'payable')::numeric, 'memo', 'Output VAT for ' || to_char(v_period, 'FMMonth YYYY')),
    jsonb_build_object('code', private.acct(p_org, 'vat_withheld_by_customers'), 'credit', (x->>'wvat_credit')::numeric, 'memo', 'VAT withheld by customers, credited'),
    jsonb_build_object('code', private.acct(p_org, 'input_vat'), 'credit', (x->>'input')::numeric + (x->>'credit_used')::numeric - (x->>'new_credit')::numeric,
      'memo', 'Input VAT claimed' || case when (x->>'credit_used')::numeric > 0 then ', with ' || private.naira((x->>'credit_used')::numeric) || ' brought forward' else '' end),
    jsonb_build_object('code', private.acct(p_org, 'stock_loss'), 'debit', coalesce((x->>'stock_writeoff_vat')::numeric, 0), 'memo', 'Input VAT taken back on stock written off'),
    jsonb_build_object('code', private.acct(p_org, 'input_vat'), 'credit', coalesce((x->>'stock_writeoff_vat')::numeric, 0), 'memo', 'Input VAT on stock written off'),
    jsonb_build_object('code', '6512', 'debit', (x->>'credit_expired')::numeric, 'memo', 'Input VAT credit more than five years old'),
    jsonb_build_object('code', private.acct(p_org, 'input_vat'), 'credit', (x->>'credit_expired')::numeric, 'memo', 'Input VAT credit lapsed'),
    jsonb_build_object('code', '1404', 'debit', v_refund, 'memo', 'VAT refund claimed from the NRS'),
    jsonb_build_object('code', private.acct(p_org, 'input_vat'), 'credit', v_refund, 'memo', 'Input VAT credit claimed as a refund'));
  if exists (select 1 from jsonb_array_elements(v_jl) l where coalesce((l->>'debit')::numeric, 0) <> 0 or coalesce((l->>'credit')::numeric, 0) <> 0) then
    j := private.post_entry(p_org, 'VAT return for ' || to_char(v_period, 'FMMonth YYYY'), 'vat_return', null, m.id, m.id, v_jl, private.posting_time(p_org, v_end),
      jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'vat_return', 'period', v_period, 'payable', x->'payable', 'by', m.display_name))));
  end if;
  insert into vat_periods (org_id, period, output_vat, input_vat, wvat_credit, import_vat, stock_writeoff_vat, credit_bf, credit_used, credit_expired, payable, new_credit,
    refund_claimed, credit_cf, layers, status, filed_at, filed_by, journal_id, notes)
  values (p_org, v_period, (x->>'output')::numeric, (x->>'input')::numeric, (x->>'wvat_credit')::numeric, coalesce((x->>'import_vat')::numeric, 0),
    coalesce((x->>'stock_writeoff_vat')::numeric, 0), (x->>'credit_bf')::numeric, (x->>'credit_used')::numeric,
    (x->>'credit_expired')::numeric, (x->>'payable')::numeric, (x->>'new_credit')::numeric, v_refund, (x->>'credit_cf')::numeric - v_refund, x->'layers',
    case when (x->>'payable')::numeric = 0 then 'paid' else 'filed' end, now(), m.id, j.id, nullif(trim(p->>'notes'), ''));
  return public.vat_position(p_org, jsonb_build_object('from', v_period, 'to', v_period));
end $$;

create or replace function public.reopen_vat_return(p_org uuid, p_period date, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; vp public.vat_periods;
begin
  m := private.require(p_org, 'file_tax');
  select * into vp from vat_periods where org_id = p_org and period = date_trunc('month', p_period)::date for update;
  if not found then raise exception 'The % return is not filed.', to_char(p_period, 'FMMonth YYYY'); end if;
  if vp.payment_journal_id is not null then raise exception 'The % VAT is paid. File a correction with the NRS instead.', to_char(vp.period, 'FMMonth YYYY'); end if;
  if exists (select 1 from vat_periods where org_id = p_org and period > vp.period) then raise exception 'Reopen the later months first.'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Say why the return is reopened.'; end if;
  if vp.journal_id is not null then perform private.reverse_entry(vp.journal_id, m.id, 'VAT return reopened: ' || left(trim(p_reason), 200), null); end if;
  delete from vat_periods where org_id = p_org and period = vp.period;
  return public.vat_position(p_org, jsonb_build_object('from', vp.period, 'to', vp.period));
end $$;

create or replace function public.reopen_cit_year(p_org uuid, p_year int, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; cy public.cit_years;
begin
  m := private.require(p_org, 'file_tax');
  select * into cy from cit_years where org_id = p_org and accounting_year = p_year for update;
  if not found or cy.status = 'draft' then raise exception 'The % return is not approved.', p_year; end if;
  if cy.status in ('sent', 'filed') then raise exception 'The % return is % on Rev360. File an amended return there; Counta keeps this one as filed.', p_year, cy.status; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Say why the return is reopened.'; end if;
  update cit_years set status = 'draft', snapshot = null, template_path = null, approved_by = null, approved_at = null,
    settings = settings || jsonb_build_object('reopened', jsonb_build_object('reason', left(trim(p_reason), 300), 'by', m.display_name, 'at', now())),
    updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year;
  return public.cit_year(p_org, p_year);
end $$;

create or replace function public.update_org_settings(p_org uuid, p_patch jsonb) returns void
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_rev text;
begin
  m := private.require(p_org, 'manage_settings');
  v_rev := nullif(p_patch->>'revenue_account', '');
  if v_rev is not null and v_rev !~ '^41(0[1-9]|1[0-9]|2[01])$' then raise exception 'Choose a revenue account from 4101 to 4121.'; end if;
  if p_patch ? 'fiscal_year_start' and coalesce((p_patch->>'fiscal_year_start')::int, 0) not between 1 and 12 then raise exception 'Choose the month the financial year ends.'; end if;
  if coalesce(p_patch->>'offering', 'goods') not in ('goods', 'services', 'both') then raise exception 'Choose goods, services or both.'; end if;
  update orgs set
    name = coalesce(nullif(trim(p_patch->>'name'), ''), name),
    offering = case when p_patch ? 'offering' then nullif(p_patch->>'offering', '') else offering end,
    email = case when p_patch ? 'email' then nullif(trim(p_patch->>'email'), '') else email end,
    phone = case when p_patch ? 'phone' then nullif(trim(p_patch->>'phone'), '') else phone end,
    tin = case when p_patch ? 'tin' then private.tax_id_input(p_patch->>'tin', tin, 'Your Tax ID') else tin end,
    rc_number = case when p_patch ? 'rc_number' then nullif(trim(p_patch->>'rc_number'), '') else rc_number end,
    address = case when p_patch ? 'address' then nullif(trim(p_patch->>'address'), '') else address end,
    logo_path = case when p_patch ? 'logo_path' then nullif(trim(p_patch->>'logo_path'), '') else logo_path end,
    legal_form = coalesce(nullif(p_patch->>'legal_form', ''), legal_form),
    fiscal_year_start = coalesce((p_patch->>'fiscal_year_start')::int, fiscal_year_start),
    vat_registered = coalesce((p_patch->>'vat_registered')::boolean, vat_registered),
    prices_include_vat = coalesce((p_patch->>'prices_include_vat')::boolean, prices_include_vat),
    invoice_terms_days = coalesce((p_patch->>'invoice_terms_days')::int, invoice_terms_days),
    invoice_note = case when p_patch ? 'invoice_note' then nullif(trim(p_patch->>'invoice_note'), '') else invoice_note end,
    revenue_account = coalesce(v_rev, revenue_account),
    cash_sales_without_invoices = coalesce((p_patch->>'cash_sales_without_invoices')::boolean, cash_sales_without_invoices),
    capitalisation_threshold = coalesce((p_patch->>'capitalisation_threshold')::numeric, capitalisation_threshold),
    auto_post_threshold = coalesce((p_patch->>'auto_post_threshold')::numeric, auto_post_threshold),
    books_start = case when p_patch ? 'books_start' then private.date_or_null(p_patch->>'books_start') else books_start end
  where id = p_org;
  if v_rev is not null then
    insert into posting_rules (org_id, role, account_code, updated_by) values (p_org, 'sales_revenue', v_rev, m.id)
    on conflict (org_id, role) do update set account_code = excluded.account_code, updated_by = excluded.updated_by, updated_at = now();
  end if;
end $$;

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
    'offering', coalesce(o.offering, 'goods'), 'enabled', p_kind = 'payment_demo' or coalesce((o.voice_events->>p_kind)::boolean, true), 'vars', v_vars);
end $$;

create or replace function public.approve_cit_year(p_org uuid, p_year int) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; cy public.cit_years; comp jsonb; v_blocks text;
begin
  m := private.require(p_org, 'file_tax');
  perform public.save_cit_year(p_org, p_year, '{}'::jsonb);
  select * into cy from cit_years where org_id = p_org and accounting_year = p_year for update;
  comp := private.cit_run(p_org, p_year);
  select string_agg(k->>'text', ' ') into v_blocks from jsonb_array_elements(comp->'checks') k where k->>'severity' = 'block';
  if v_blocks is not null then raise exception 'Not ready: %', v_blocks; end if;
  update cit_years set status = 'approved', approved_by = m.id, approved_at = now(), rulebook_id = comp->'rulebook'->>'id',
    snapshot = jsonb_build_object('computation', comp, 'cell_map', private.cit_cell_map(comp), 'declaration', private.cit_declaration(p_org, comp),
      'org', (select jsonb_build_object('name', name, 'tin', tin, 'rc_number', rc_number, 'address', address, 'taxstreem_org_id', taxstreem_org_id) from orgs where id = p_org),
      'approved_by', m.display_name, 'approved_at', now()),
    flux_status = null, flux_message = null, updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year;
  return public.cit_year(p_org, p_year);
end $$;
create or replace function private.create_payout(p_org uuid, p jsonb, p_lines jsonb, m public.members) returns public.payouts
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; w public.wallets; po public.payouts; v_amt numeric := round(private.num(p->>'amount'), 2); v_status text; v_inflight numeric;
  v_batch uuid := nullif(current_setting('counta.payout_batch', true), '')::uuid; v_row jsonb := nullif(current_setting('counta.payout_row', true), '')::jsonb;
  pb public.payout_batches;
begin
  if nullif(p->>'client_uuid', '') is not null then
    select * into po from payouts where client_uuid = (p->>'client_uuid')::uuid;
    if found then return po; end if;
  end if;
  select * into o from orgs where id = p_org;
  perform private.require_payments_open(p_org);
  select * into w from wallets where org_id = p_org and rail = o.payment_rail and status = 'active';
  if not found then raise exception 'Open the business wallet in Payments first.'; end if;
  if not exists (select 1 from payment_rails where code = w.rail and 'payout' = any(capabilities)) then raise exception 'This payment rail does not make payouts.'; end if;
  if coalesce(v_amt, 0) < 100 then raise exception 'A payout must be at least ₦100.'; end if;
  if coalesce(p->>'account_number', '') !~ '^[0-9]{10}$' then raise exception 'Enter the 10-digit account number.'; end if;
  if coalesce(trim(p->>'bank_code'), '') = '' then raise exception 'Choose the bank.'; end if;
  if coalesce(trim(p->>'account_name'), '') = '' then raise exception 'Check the account name before paying.'; end if;
  select coalesce(sum(amount + fee), 0) into v_inflight from payouts where wallet_id = w.id and status in ('approved', 'processing', 'pending_approval');
  if v_amt > private.wallet_balance(w.id) - v_inflight + 0.004 then
    raise exception 'The wallet holds % after payouts already waiting. Fund it first.', to_char(private.wallet_balance(w.id) - v_inflight, 'FM999,999,999,990.00');
  end if;
  if v_batch is not null then
    select * into pb from payout_batches where id = v_batch and org_id = p_org;
    if not found then raise exception 'Bulk payment not found.'; end if;
    v_status := pb.status;
  else
    v_status := case when o.payout_approval_threshold > 0 and v_amt >= o.payout_approval_threshold and m.role <> 'owner' then 'pending_approval' else 'approved' end;
  end if;
  insert into payouts (org_id, number, wallet_id, purpose, vendor_id, customer_id, to_bank_account_id, amount, bank_code, bank_name, account_number, account_name,
    narration, lines, reference, status, requested_by, approved_by, approved_at, client_uuid, batch_id, batch_row, your_reference)
  values (p_org, 'PO-' || lpad(private.next_no(p_org, 'PO', 1)::text, 5, '0'), w.id, coalesce(nullif(p->>'purpose', ''), 'other'),
    nullif(p->>'vendor_id', '')::uuid, nullif(p->>'customer_id', '')::uuid, nullif(p->>'to_bank_account_id', '')::uuid, v_amt, trim(p->>'bank_code'),
    nullif(trim(p->>'bank_name'), ''), p->>'account_number', left(trim(p->>'account_name'), 120), left(coalesce(nullif(trim(p->>'narration'), ''), o.name), 80),
    p_lines, 'CNTP-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)), v_status, m.id,
    case when v_status = 'approved' then m.id end, case when v_status = 'approved' then now() end, nullif(p->>'client_uuid', '')::uuid,
    pb.id, case when pb.id is not null then (v_row->>'row')::int end, case when pb.id is not null then nullif(left(trim(v_row->>'ref'), 60), '') end)
  returning * into po;
  if v_status = 'pending_approval' and pb.id is null then
    perform private.notify_perm(p_org, 'approve_payments', 'payout', 'Approve a payout of ₦' || to_char(v_amt, 'FM999,999,999,990.00'),
      po.account_name || ' · ' || po.narration || ' · asked by ' || coalesce(m.display_name, ''), '/payments', 'payout-' || po.id, m.id);
  end if;
  return po;
end $$;

create or replace function private.open_request(p_org uuid, p_sale uuid, p_customer uuid, p_method text, p_amount numeric, m public.members,
  p_public boolean, p_shift uuid) returns public.payment_requests
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; s public.sales; w public.wallets; r public.payment_requests; v_amt numeric; v_due numeric; v_pending numeric; pr public.payment_rails;
begin
  select * into o from orgs where id = p_org;
  perform private.require_payments_open(p_org);
  select * into pr from payment_rails where code = o.payment_rail and active;
  if not found then raise exception 'Payments are not available for this business yet.'; end if;
  if p_method not in ('account', 'link', 'qr') then raise exception 'Choose transfer, link or QR.'; end if;
  if not (p_method = any(pr.capabilities)) or not (p_method = any(o.payment_methods)) then raise exception 'This way of paying is not switched on.'; end if;
  select * into w from wallets where org_id = p_org and rail = o.payment_rail and status = 'active';
  if not found then raise exception 'Open the business wallet in Payments before taking payments.'; end if;
  if p_sale is not null then
    select * into s from sales where id = p_sale and org_id = p_org for update;
    if not found or s.doc_type not in ('receipt', 'invoice', 'order') then raise exception 'Sale not found.'; end if;
    if s.status in ('void', 'cancelled', 'draft', 'converted', 'paid', 'credited') then raise exception '% has nothing to pay.', s.number; end if;
    v_due := s.total - s.amount_paid - s.credited;
    select coalesce(sum(a.amount), 0) into v_pending from collection_allocations a join collections c on c.id = a.collection_id
      where a.sale_id = s.id and c.status = 'pending';
    v_amt := round(coalesce(p_amount, v_due - v_pending), 2);
    if v_amt > v_due + 0.004 then raise exception 'Only % is owed on %.', to_char(v_due, 'FM999,999,999,990.00'), s.number; end if;
  else
    if p_customer is null or not exists (select 1 from customers where id = p_customer and org_id = p_org and not is_walk_in) then
      raise exception 'Choose the customer.';
    end if;
    v_amt := round(coalesce(p_amount, greatest(private.customer_balance(p_org, p_customer), 0)), 2);
  end if;
  if coalesce(v_amt, 0) < 100 then raise exception 'The amount to collect must be at least ₦100.'; end if;
  select * into r from payment_requests
  where org_id = p_org and sale_id is not distinct from p_sale and customer_id is not distinct from coalesce(p_customer, s.customer_id)
    and method = p_method and amount = v_amt and status = 'pending' and (expires_at is null or expires_at > now() + interval '5 minutes')
  order by created_at desc limit 1;
  if found then return r; end if;
  -- Earlier requests for the same sale that were never paid are withdrawn.
  update payment_requests set status = 'cancelled' where sale_id = p_sale and p_sale is not null and status in ('creating', 'pending') and method = p_method;
  insert into payment_requests (org_id, sale_id, customer_id, purpose, method, rail, amount, tx_ref, status, shift_id, created_by, wallet_id, public_request)
  values (p_org, p_sale, coalesce(p_customer, s.customer_id), case when p_sale is null then 'customer_balance' when s.doc_type = 'order' then 'order' else 'sale' end,
    p_method, o.payment_rail, v_amt, 'CNT-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)), 'creating', p_shift, m.id, w.id, p_public)
  returning * into r;
  return r;
end $$;

create or replace function public.svc_wallet_to_open(p_org uuid, p_member uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; w public.wallets; pr public.payment_rails; m public.members;
begin
  select * into o from orgs where id = p_org;
  perform private.require_payments_open(p_org);
  select * into m from members where id = p_member and org_id = p_org and status = 'active';
  if m.id is null or not (private.perm_of(m, 'keep_books') or private.perm_of(m, 'make_payments') or m.role = 'owner') then
    raise exception 'Only the owner or someone who keeps the books opens the wallet.';
  end if;
  select * into pr from payment_rails where code = o.payment_rail and active;
  if not found then raise exception 'Payments are not available for this business yet.'; end if;
  select * into w from wallets where org_id = p_org and rail = o.payment_rail;
  if found and w.status = 'active' then return jsonb_build_object('wallet', to_jsonb(w), 'ready', true); end if;
  if not found then
    insert into wallets (org_id, rail, status, created_by) values (p_org, o.payment_rail, 'creating', m.id) returning * into w;
  else
    update wallets set status = 'creating', error = null where id = w.id returning * into w;
  end if;
  return jsonb_build_object('wallet', to_jsonb(w), 'ready', false, 'rail', to_jsonb(pr) - 'api_key_secret' - 'webhook_secret',
    'api_key_secret', pr.api_key_secret, 'org', jsonb_build_object('name', o.name, 'email', o.email, 'phone', o.phone, 'id', o.id));
end $$;

create or replace function public.create_payout_batch(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; c jsonb; pb public.payout_batches; r jsonb; v_src jsonb; v_status text; v_title text; v_first text;
begin
  m := private.require(p_org, 'make_payments');
  perform private.require_payments_open(p_org);
  if nullif(p->>'client_uuid', '') is not null then
    select * into pb from payout_batches where client_uuid = (p->>'client_uuid')::uuid and org_id = p_org;
    if found then return private.batch_json(pb.id); end if;
  end if;
  select * into o from orgs where id = p_org;
  c := private.bulk_check(p_org, p, m);
  if (c->>'error_count')::int > 0 then
    select format('Row %s: %s', x->>'row', x->'errors'->>0) into v_first from jsonb_array_elements(c->'rows') x where not (x->>'ok')::boolean limit 1;
    raise exception '%', v_first;
  end if;
  if (c->>'total')::numeric + (c->>'fee_estimate')::numeric > (c->>'available')::numeric + 0.004 then
    raise exception 'The wallet has ₦% available. These payments need ₦% with transfer fees. Fund the wallet first.',
      to_char((c->>'available')::numeric, 'FM999,999,999,990.00'), to_char((c->>'total')::numeric + (c->>'fee_estimate')::numeric, 'FM999,999,999,990.00');
  end if;
  v_status := case when (c->>'needs_approval')::boolean then 'pending_approval' else 'approved' end;
  v_title := left(coalesce(nullif(trim(p->>'title'), ''), 'Bulk payment ' || to_char(now() at time zone 'Africa/Lagos', 'DD Mon YYYY')), 80);
  insert into payout_batches (org_id, number, title, wallet_id, default_account, status, mode, row_count, total, wht_total, fee_estimate, file_name, requested_by,
    approved_by, approved_at, client_uuid)
  values (p_org, 'BP-' || lpad(private.next_no(p_org, 'BP', 1)::text, 5, '0'), v_title, (c->>'wallet_id')::uuid, nullif(trim(p->>'default_account'), ''), v_status,
    c->>'mode', (c->>'ok_count')::int, (c->>'total')::numeric, (c->>'wht_total')::numeric, (c->>'fee_estimate')::numeric, left(nullif(trim(p->>'file_name'), ''), 200),
    m.id, case when v_status = 'approved' then m.id end, case when v_status = 'approved' then now() end, nullif(p->>'client_uuid', '')::uuid)
  returning * into pb;
  perform set_config('counta.payout_batch', pb.id::text, true);
  for r in select value from jsonb_array_elements(c->'rows') loop
    select value into v_src from jsonb_array_elements(p->'rows') where value->'row' = r->'row' limit 1;
    perform set_config('counta.payout_row', jsonb_build_object('row', r->'row', 'ref', v_src->>'reference')::text, true);
    if r->>'kind' = 'bill' then
      perform public.pay_bill((r->>'bill_id')::uuid, jsonb_build_object('method', 'wallet', 'amount', (r->>'gross')::numeric, 'wht', (r->>'wht')::numeric,
        'bank_code', v_src->>'bank_code', 'bank_name', v_src->>'bank_name', 'account_number', v_src->>'account_number', 'account_name', v_src->>'account_name',
        'narration', nullif(trim(v_src->>'narration'), '')));
    else
      perform private.create_payout(p_org, jsonb_build_object('purpose', r->>'purpose', 'vendor_id', r->>'vendor_id', 'amount', (r->>'amount')::numeric,
        'bank_code', v_src->>'bank_code', 'bank_name', v_src->>'bank_name', 'account_number', v_src->>'account_number', 'account_name', v_src->>'account_name',
        'narration', coalesce(nullif(trim(v_src->>'narration'), ''), v_title)), r->'lines', m);
    end if;
  end loop;
  perform set_config('counta.payout_batch', '', true);
  perform set_config('counta.payout_row', '', true);
  perform private.refresh_payout_batch(pb.id);
  if v_status = 'pending_approval' then
    perform private.notify_perm(p_org, 'approve_payments', 'payout',
      'Approve a bulk payment of ₦' || to_char(pb.total, 'FM999,999,999,990.00') || ' to ' || pb.row_count || ' account' || case when pb.row_count = 1 then '' else 's' end,
      pb.number || ' · ' || pb.title || ' · asked by ' || coalesce(m.display_name, ''), '/payments?tab=bulk&batch=' || pb.id, 'batch-' || pb.id, m.id);
  end if;
  return private.batch_json(pb.id);
end $$;
create or replace function public.upsert_item(p_org uuid, p_item jsonb) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_id uuid := nullif(p_item->>'id', '')::uuid; v_old public.items;
  v_name text := trim(coalesce(p_item->>'name', '')); v_pack numeric; v_price numeric; v_cost numeric; v_qty numeric;
  v_barcode text := nullif(trim(coalesce(p_item->>'barcode', '')), ''); v_su text;
  v_type text := coalesce(nullif(p_item->>'item_type', ''), 'merchandise'); v_attrs jsonb := private.clean_attrs(p_item->'attributes');
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'add_items') or private.perm_of(m, 'edit_prices')) then
    raise exception 'Your role does not allow this (add items).' using errcode = '42501';
  end if;
  if v_name = '' then raise exception 'Product name is required.'; end if;
  if v_type not in ('merchandise', 'finished_good', 'raw_material', 'packaging', 'work_in_progress', 'consumable', 'spare_part', 'chemical') then
    raise exception 'Choose what kind of item this is.';
  end if;
  begin
    v_pack := nullif(p_item->>'pack_size', '')::numeric;
    v_price := nullif(p_item->>'price', '')::numeric;
    v_cost := nullif(p_item->>'cost', '')::numeric;
  exception when others then raise exception 'Pack size, cost and price must be numbers.';
  end;
  if v_price is null and not private.sells(v_type) then v_price := 0; end if;
  if v_pack is null or v_pack < 1 or v_pack <> floor(v_pack) then raise exception 'Pack size must be a whole number, at least 1.'; end if;
  if v_price is null or v_price < 0 or (v_price = 0 and private.sells(v_type)) then raise exception 'Enter a selling price.'; end if;
  if v_cost is not null and v_cost < 0 then raise exception 'Cost cannot be negative.'; end if;
  if v_barcode is not null and exists (select 1 from items where org_id = p_org and barcode = v_barcode and id is distinct from v_id) then
    raise exception 'Another item already uses barcode %.', v_barcode;
  end if;
  v_su := coalesce(nullif(trim(p_item->>'selling_unit'), ''), 'piece');

  if v_id is null then
    if v_cost is null then raise exception 'Enter a cost per selling unit.'; end if;
    insert into items (org_id, name, barcode, sku, category, vat_treatment, nafdac_no, purchase_unit, pack_size, selling_unit,
      informal_unit, track_batches, reorder_floor, preferred_vendor_id, alt_vendor_id, price, import_priced, photo_path, created_by,
      item_type, brand, description, attributes, inventory_account)
    values (p_org, v_name, v_barcode, nullif(trim(p_item->>'sku'), ''), coalesce(nullif(trim(p_item->>'category'), ''), 'General'),
      coalesce(nullif(p_item->>'vat_treatment', ''), 'standard'), nullif(trim(p_item->>'nafdac_no'), ''),
      coalesce(nullif(trim(p_item->>'purchase_unit'), ''), 'Carton'), v_pack::int, v_su,
      coalesce((p_item->>'informal_unit')::boolean, v_su in ('derica', 'mudu', 'paint bucket')),
      coalesce((p_item->>'track_batches')::boolean, false), coalesce(nullif(p_item->>'reorder_floor', '')::numeric, 0),
      nullif(p_item->>'preferred_vendor_id', '')::uuid, nullif(p_item->>'alt_vendor_id', '')::uuid,
      v_price, coalesce((p_item->>'import_priced')::boolean, false), nullif(p_item->>'photo_path', ''), m.id,
      v_type, nullif(trim(p_item->>'brand'), ''), nullif(trim(p_item->>'description'), ''), v_attrs, private.type_account(v_type))
    returning id into v_id;
    insert into item_costs (item_id, org_id, wac, last_cost) values (v_id, p_org, v_cost, v_cost);
  else
    select * into v_old from items where id = v_id and org_id = p_org for update;
    if not found then raise exception 'Item not found.'; end if;
    if not private.perm_of(m, 'edit_prices') and (v_old.price <> v_price
        or (v_cost is not null and v_cost is distinct from (select wac from item_costs where item_id = v_id))) then
      raise exception 'Your role does not allow changing prices or costs (edit prices).' using errcode = '42501';
    end if;
    update items set
      name = v_name, barcode = v_barcode,
      sku = case when p_item ? 'sku' then nullif(trim(p_item->>'sku'), '') else sku end,
      category = coalesce(nullif(trim(p_item->>'category'), ''), category),
      vat_treatment = coalesce(nullif(p_item->>'vat_treatment', ''), vat_treatment),
      nafdac_no = case when p_item ? 'nafdac_no' then nullif(trim(p_item->>'nafdac_no'), '') else nafdac_no end,
      purchase_unit = coalesce(nullif(trim(p_item->>'purchase_unit'), ''), purchase_unit),
      pack_size = v_pack::int, selling_unit = v_su,
      informal_unit = coalesce((p_item->>'informal_unit')::boolean, v_su in ('derica', 'mudu', 'paint bucket')),
      track_batches = coalesce((p_item->>'track_batches')::boolean, track_batches),
      reorder_floor = coalesce(nullif(p_item->>'reorder_floor', '')::numeric, reorder_floor),
      preferred_vendor_id = case when p_item ? 'preferred_vendor_id' then nullif(p_item->>'preferred_vendor_id', '')::uuid else preferred_vendor_id end,
      alt_vendor_id = case when p_item ? 'alt_vendor_id' then nullif(p_item->>'alt_vendor_id', '')::uuid else alt_vendor_id end,
      price = v_price,
      item_type = v_type,
      brand = case when p_item ? 'brand' then nullif(trim(p_item->>'brand'), '') else brand end,
      description = case when p_item ? 'description' then nullif(trim(p_item->>'description'), '') else description end,
      attributes = case when p_item ? 'attributes' then v_attrs else attributes end,
      import_priced = coalesce((p_item->>'import_priced')::boolean, import_priced),
      photo_path = case when p_item ? 'photo_path' then nullif(p_item->>'photo_path', '') else photo_path end,
      needs_review = case when p_item ? 'needs_review' then (p_item->>'needs_review')::boolean else false end
    where id = v_id;
    if v_old.item_type <> v_type then
      perform private.move_item_account(v_id, private.type_account(v_type), m.id);
    end if;
    if v_old.price <> v_price then
      insert into price_changes (org_id, item_id, old_price, new_price, reason, changed_by)
      values (p_org, v_id, v_old.price, v_price, coalesce(nullif(p_item->>'price_reason', ''), 'Manual edit'), m.id);
    end if;
    if v_cost is not null then
      select coalesce(sum(qty), 0) into v_qty from stock_levels where item_id = v_id;
      if v_qty = 0 then
        update item_costs set wac = v_cost, last_cost = coalesce(last_cost, v_cost), updated_at = now() where item_id = v_id;
      end if;
    end if;
  end if;
  return v_id;
end $$;

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
    'org', (select to_jsonb(o) - 'identity' || jsonb_build_object('payments_open', o.identity_status in ('not_required', 'verified', 'approved')) from orgs o where o.id = p_org),
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

create or replace function public.kyc_submit(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid(); k public.kyc_profiles; c jsonb; v_org uuid; v_name text; v_addr text; v_vat boolean; v_cat public.business_categories;
  v_form text; v_cls text; v_tin text; v_dir jsonb; v_display text; v_branch text; v_email text; v_state text; v_lga text; v_shares numeric;
  v_new boolean := false;
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

-- ---------------------------------------------------------------------------
-- Invitation emails, and the daily allowances for NIN checks, NIN slips and products read from photos
-- ---------------------------------------------------------------------------
alter table public.messages drop constraint if exists messages_template_check;
alter table public.messages add constraint messages_template_check
  check (template in ('document', 'reminder', 'receipt', 'statement', 'order', 'custom', 'bill_returned', 'invite'));

create or replace function public.svc_kyc_take(p_user uuid, p_kind text) returns boolean
language plpgsql security definer set search_path = public, private as $$
declare v_max int;
begin
  v_max := case p_kind when 'search' then 20 when 'profile' then 6 when 'tin' then 6 when 'status_report' then 3
    when 'web' then 8 when 'document' then 6 when 'nin' then 5 when 'nin_slip' then 4 when 'product' then 200 else null end;
  if v_max is null then raise exception 'Unknown lookup.'; end if;
  perform pg_advisory_xact_lock(hashtext('kyc:' || p_user::text));
  if (select count(*) from kyc_lookups where user_id = p_user and kind = p_kind and at > now() - interval '1 day') >= v_max then return false; end if;
  insert into kyc_lookups (user_id, kind) values (p_user, p_kind);
  return true;
end $$;

-- The checklist gains the director's NIN check, right after the business is set up.
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
    -- The director's NIN: done once confirmed, or once a slip waits for TaxStreem (the rest is TaxStreem's part).
    ('identity', 'profile', false, p_org is not null and o.identity_status in ('not_required', 'verified', 'approved', 'review')),
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

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
revoke execute on function public.get_team(uuid), public.save_role_permissions(uuid, text, jsonb), public.resend_invite(uuid),
  public.accept_invite(text), public.identity_state(uuid), public.identity_slip(uuid, text, text), public.am_reviewer(),
  public.identity_reviews(), public.review_identity(uuid, boolean, text)
  from public, anon;
grant execute on function public.get_team(uuid), public.save_role_permissions(uuid, text, jsonb), public.resend_invite(uuid),
  public.accept_invite(text), public.identity_state(uuid), public.identity_slip(uuid, text, text), public.am_reviewer(),
  public.identity_reviews(), public.review_identity(uuid, boolean, text)
  to authenticated;
-- The join page shows what a link is for before the person has an account.
revoke execute on function public.invite_preview(text) from public;
grant execute on function public.invite_preview(text) to anon, authenticated;
revoke execute on function public.svc_invite(uuid), public.svc_identity_nin(uuid, uuid, text, text, text, text, text),
  public.svc_identity_slip(uuid, uuid, jsonb), public.svc_forget_add(uuid, text), public.svc_forget_due(uuid, int), public.svc_forget_done(text, boolean),
  public.svc_guide_session(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.svc_invite(uuid), public.svc_identity_nin(uuid, uuid, text, text, text, text, text),
  public.svc_identity_slip(uuid, uuid, jsonb), public.svc_forget_add(uuid, text), public.svc_forget_due(uuid, int), public.svc_forget_done(text, boolean),
  public.svc_guide_session(uuid, text, text)
  to service_role;
revoke execute on function private.perm_keys(), private.role_template(text), private.clean_perms(jsonb), private.role_perms(uuid, text),
  private.member_perms(public.members), private.apply_member_perms(uuid), private.check_grantable(public.members, jsonb),
  private.check_split(text, jsonb, text), private.role_label(text), private.queue_invite(uuid, public.members),
  private.payments_open(uuid), private.require_payments_open(uuid), private.name_tokens(text), private.token_in(text, text[]),
  private.identity_people(uuid), private.identity_match(text, text, text, jsonb), private.is_reviewer(), private.identity_json(uuid, boolean), private.orgs_guard()
  from public, anon, authenticated;
-- Storage policies call this one as the signed-in person.
revoke execute on function private.reviewer_may_read(text) from public, anon;
grant execute on function private.reviewer_may_read(text) to authenticated;
