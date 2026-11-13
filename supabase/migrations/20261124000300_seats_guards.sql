-- Practice management, part 3: seats, guards and departed staff.
--
-- The practice link alone decides who of a firm works in a client business, and how:
--   private.practice_sync_seats(client)  under full mandate each wanted firm person gets an admin place acting as the owner,
--                                        with every permission whatever the business's admin settings say; involved, an
--                                        accountant's place. Every other place of the practice is switched off and stops
--                                        acting as the owner, so switching a firm person off (practice_update_member)
--                                        removes every place of theirs in one call. A full mandate that ended without a
--                                        handover keeps its engagement partner's place, while they are an active partner
--                                        or manager of the firm.
-- The sync marks the transaction (counta.seat_sync = 'on') while it works; outside it, members_mandate_guard lets no one set
-- acts_as_owner, and in a business under full mandate lets in only the managing firm's places, which change only through
-- the sync. A business under full mandate cannot connect to another practice (practice_clients_guard, which also keeps the
-- engagement partner one of the firm's active partners or managers), gets no requests (practice_requests_guard), is paid
-- for by the practice (subscription_charges_guard), and its team, plan and practice link are not changed from inside it
-- (private.require_not_managed, practice_end).
-- Admin kill switch: practices.mandate_suspended_at; private.practice_can_full says whether a firm may run full mandates.
-- Identity: a business the firm runs is checked against its CAC directors only (svc_identity_nin), and its business
-- profile is submitted by its acting owner (kyc_submit with p.org_id).
--
-- Redefined functions are their latest definitions with only the changes described at each one; signatures are unchanged,
-- so create or replace keeps every grant.

-- ---------------------------------------------------------------------------
-- 1. Kill switch
-- ---------------------------------------------------------------------------
alter table public.practices add column if not exists mandate_suspended_at timestamptz;

-- A firm may run businesses under full mandate while it has an active partner with a verified licence and TaxStreem has
-- not suspended it.
create or replace function private.practice_can_full(p_practice uuid) returns boolean
language sql stable set search_path = public, private as $$
  select private.partner_verified(p_practice)
    and coalesce((select mandate_suspended_at is null from practices where id = p_practice), false)
$$;

-- ---------------------------------------------------------------------------
-- 2. The seat sync
-- ---------------------------------------------------------------------------
create or replace function private.practice_sync_seats(p_client uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients; pm public.practice_members; ex public.members; p jsonb; v_wanted boolean; v_firm text;
  v_full boolean; v_role text; v_over jsonb; v_seat uuid; v_seats uuid[] := '{}'; v_keep uuid;
begin
  select * into c from practice_clients where id = p_client;
  if not found or c.org_id is null or c.practice_id is null then return; end if;
  -- Only the seat sync changes the practice's places (members_mandate_guard), until it returns.
  perform set_config('counta.seat_sync', 'on', true);
  if c.status <> 'active' then
    -- A full mandate that ended without a handover leaves the business with its engagement partner.
    if c.end_kind = 'ended' then
      select ep.user_id into v_keep from practice_members ep
      where ep.id = c.engagement_partner_id and ep.practice_id = c.practice_id and ep.status = 'active' and ep.role in ('partner', 'manager');
    end if;
    update members set status = 'disabled', acts_as_owner = false
    where org_id = c.org_id and practice_id = c.practice_id and (status <> 'disabled' or acts_as_owner) and role <> 'owner'
      and (v_keep is null or user_id is distinct from v_keep);
    perform set_config('counta.seat_sync', '', true);
    return;
  end if;
  -- Under full mandate the firm's people are admins acting as the owner, with the admin template as their own permissions
  -- (the business's admin settings never narrow them); involved, accountants.
  v_full := c.mode = 'full';
  v_role := case when v_full then 'admin' else 'accountant' end;
  select name into v_firm from practices where id = c.practice_id;
  for pm in select * from practice_members where practice_id = c.practice_id order by created_at, id loop
    v_wanted := pm.status = 'active' and pm.user_id is not null
      and (pm.role in ('partner', 'manager') or exists (select 1 from practice_assignments a where a.client_id = c.id and a.member_id = pm.id));
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
      -- Their own earlier place (an invitation, or an accountant's place) becomes the practice's.
      update members set user_id = pm.user_id, status = 'active', practice_id = c.practice_id, role = v_role, acts_as_owner = v_full,
        perm_overrides = case when v_full then private.role_template('admin') when ex.role = 'accountant' then perm_overrides else '{}'::jsonb end
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
  perform set_config('counta.seat_sync', '', true);
end $$;

-- A firm person switched off, or moved, keeps no place they should not have: every client of the practice is synced,
-- including a full mandate that ended without a handover (its engagement partner's place).
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
  for c in select id from practice_clients where practice_id = t.practice_id and (status = 'active' or end_kind = 'ended') loop
    perform private.practice_sync_seats(c.id);
  end loop;
  return public.practice_home(t.practice_id);
end $$;

-- ---------------------------------------------------------------------------
-- 3. The business's contact: under full mandate only an active place acting as the owner
-- ---------------------------------------------------------------------------
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
    select * into c from members where org_id = p_org and user_id = v_user and status = 'active' and acts_as_owner;
    if found then return c; end if;
  end if;
  select * into c from members where org_id = p_org and acts_as_owner and status = 'active' order by created_at limit 1;
  return c;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Guards
-- ---------------------------------------------------------------------------
-- Places in a business. Outside the seat sync no one sets acts_as_owner; under full mandate only the managing firm's places
-- are active or invited, and who they are and what they may do changes only through the sync.
create or replace function private.members_mandate_guard() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_practice uuid;
begin
  if current_setting('counta.seat_sync', true) = 'on' then return new; end if;
  if (tg_op = 'INSERT' and new.acts_as_owner) or (tg_op = 'UPDATE' and new.acts_as_owner is distinct from old.acts_as_owner) then
    raise exception 'Only the practice link sets that.' using errcode = '42501';
  end if;
  select managed_by into v_practice from orgs where id = new.org_id;
  if v_practice is null then return new; end if;
  if new.status in ('active', 'invited') and new.practice_id is distinct from v_practice then
    raise exception 'Under full mandate only the firm''s people work in this business.' using errcode = '42501';
  end if;
  -- The person, their role, status and practice, and their permissions (perm_overrides and the p_ flags).
  if tg_op = 'INSERT' or exists (
    select 1 from jsonb_each(to_jsonb(new)) n join jsonb_each(to_jsonb(old)) o on o.key = n.key
    where (n.key in ('role', 'status', 'user_id', 'practice_id', 'perm_overrides') or n.key like 'p\_%') and n.value is distinct from o.value) then
    raise exception 'Under full mandate the firm''s places change from the accountant portal.' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger members_mandate_guard before insert or update on public.members
  for each row execute function private.members_mandate_guard();

-- Practice links. A business under full mandate connects to no other practice (an invitation the business sends has no
-- practice yet, and counts as another one). The engagement partner is one of the firm's active partners or managers.
create or replace function private.practice_clients_guard() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_practice uuid;
begin
  if new.engagement_partner_id is not null
     and (tg_op = 'INSERT' or new.engagement_partner_id is distinct from old.engagement_partner_id or new.practice_id is distinct from old.practice_id)
     and not exists (select 1 from practice_members where id = new.engagement_partner_id and practice_id = new.practice_id
                     and role in ('partner', 'manager') and status = 'active') then
    raise exception 'The engagement partner must be one of the firm''s active partners or managers.';
  end if;
  if new.status in ('invited', 'requested', 'active') then
    select managed_by into v_practice from orgs where id = new.org_id;
    if v_practice is not null and new.practice_id is distinct from v_practice then
      raise exception 'This business is run by its accountant under full mandate and cannot connect to another practice.' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

create trigger practice_clients_guard before insert or update of org_id, practice_id, status, engagement_partner_id on public.practice_clients
  for each row execute function private.practice_clients_guard();

-- The firm itself runs a full-mandate client: it asks the client nothing through Counta.
create or replace function private.practice_requests_guard() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if exists (select 1 from practice_clients where id = new.client_id and mode = 'full') then
    raise exception 'Requests are not sent to a full-mandate client.';
  end if;
  return new;
end $$;

create trigger practice_requests_guard before insert on public.practice_requests
  for each row execute function private.practice_requests_guard();

-- A full mandate is billed to the practice: every charge for the business carries it.
create or replace function private.subscription_charges_guard() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.practice_id is null and private.is_managed(new.org_id) then
    raise exception 'Under full mandate the practice pays for Counta.';
  end if;
  return new;
end $$;

create trigger subscription_charges_guard before insert on public.subscription_charges
  for each row execute function private.subscription_charges_guard();

-- What the firm does for a business under full mandate from the accountant portal, not from inside the business.
create or replace function private.require_not_managed(p_org uuid) returns void
language plpgsql stable set search_path = public, private as $$
begin
  if private.is_managed(p_org) then
    raise exception 'Under full mandate this is done from the accountant portal.' using errcode = '42501';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Blocked under full mandate: the team, the plan, ending the link
-- ---------------------------------------------------------------------------
-- invite_member: private.require_not_managed first.
create or replace function public.invite_member(p_org uuid, p_name text, p_email text, p_role text, p_title text default null,
  p_location uuid default null, p_phone text default null) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare m public.members; p jsonb; v_id uuid; v_email text := nullif(lower(trim(coalesce(p_email, ''))), '');
begin
  perform private.require_not_managed(p_org);
  m := private.require(p_org, 'manage_team');
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter the person''s name.'; end if;
  if p_role not in ('admin', 'manager', 'staff', 'cashier', 'accountant') then raise exception 'Choose a role.'; end if;
  if p_role = 'admin' and not private.perm_of(m, 'owner') then raise exception 'Only the owner makes someone an admin.' using errcode = '42501'; end if;
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

-- subscription_start: private.require_not_managed first.
create or replace function public.subscription_start(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; pl public.plans; cur public.plans; s public.subscriptions; v_billing text := coalesce(nullif(p->>'billing', ''), 'month');
  v_method text := nullif(p->>'method', ''); v_price numeric; v_cur_price numeric; c public.subscription_charges; v_card uuid; v_bal numeric;
begin
  perform private.require_not_managed(p_org);
  m := private.require(p_org, 'manage_settings');
  if not (m.role in ('owner', 'admin') or m.acts_as_owner) then raise exception 'Only the owner or an admin of the business changes its plan.' using errcode = '42501'; end if;
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

-- subscription_method: private.require_not_managed first.
create or replace function public.subscription_method(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_card uuid;
begin
  perform private.require_not_managed(p_org);
  m := private.require(p_org, 'manage_settings');
  if not (m.role in ('owner', 'admin') or m.acts_as_owner) then raise exception 'Only the owner or an admin of the business changes its plan.' using errcode = '42501'; end if;
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

-- practice_end: a full mandate ends by handover or by ending the mandate, not here (after the caller's own check).
create or replace function public.practice_end(p_client uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients; v_side text;
begin
  select * into c from practice_clients where id = p_client;
  if not found or c.status <> 'active' then raise exception 'That work has already ended.'; end if;
  if c.practice_id is not null and (private.practice_me(c.practice_id)).role in ('partner', 'manager') then v_side := 'practice';
  else perform private.require(c.org_id, 'manage_team'); v_side := 'business'; end if;
  if c.mode = 'full' then raise exception 'Use handover or end the mandate for a full-mandate client.'; end if;
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

-- ---------------------------------------------------------------------------
-- 6. Identity and the business profile for a business the firm runs
-- ---------------------------------------------------------------------------
-- svc_identity_nin: a business under full mandate has no account holder of its own, so with no CAC record the NIN would be
-- matched against the firm person checking it: it asks for the CAC record first. With it, the directors as for any business.
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

-- kyc_submit: with p.org_id, the profile of that business, which the caller must act as the owner of (a firm person for a
-- business under full mandate); without it, as before.
create or replace function public.kyc_submit(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid(); k public.kyc_profiles; c jsonb; v_org uuid; v_name text; v_addr text; v_vat boolean; v_cat public.business_categories;
  v_form text; v_cls text; v_tin text; v_dir jsonb; v_display text; v_branch text; v_email text; v_state text; v_lga text; v_shares numeric;
  v_new boolean := false; v_for uuid := nullif(p->>'org_id', '')::uuid;
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if v_for is not null and not private.is_owner(v_for) then
    raise exception 'Only the owner submits the business profile.' using errcode = '42501';
  end if;
  if p ? 'answers' then perform public.kyc_answer(p->'answers'); end if;
  if p ? 'charges_vat' then perform public.kyc_answer(jsonb_build_object('charges_vat', p->'charges_vat')); end if;
  k := private.kyc_row(v_uid, v_for);
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
-- 7. Grants
-- ---------------------------------------------------------------------------
-- core.sql grants every private function to authenticated: the helpers this migration creates or redefines are not
-- callable by the signed-in person.
revoke all on function private.practice_can_full(uuid), private.practice_sync_seats(uuid), private.org_contact(uuid),
  private.members_mandate_guard(), private.practice_clients_guard(), private.practice_requests_guard(), private.subscription_charges_guard(),
  private.require_not_managed(uuid)
  from public, anon, authenticated;
