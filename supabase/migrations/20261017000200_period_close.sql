-- Counta: month-end close.
-- Closing a month freezes its closing stock: the stock at cost is snapshotted per item and branch, the allowance for
-- stock worth less than cost is set (IAS 2: lower of cost and net realisable value), and nothing can post into the
-- month afterwards. Anything recorded later with an older date (an offline phone syncing, say) posts on the first
-- open day with a note, so next month's opening stock always equals this month's closing stock.

create table if not exists public.period_closes (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  period_end date not null,
  status text not null default 'closed' check (status in ('closed', 'reopened')),
  stock_value numeric(16,2) not null default 0,
  gl_value numeric(16,2),
  wip_value numeric(16,2) not null default 0,
  transit_value numeric(16,2) not null default 0,
  allowance numeric(16,2) not null default 0,
  allowance_change numeric(16,2) not null default 0,
  allowance_journal_id uuid references public.journals(id) on delete set null,
  policy jsonb not null default '{}'::jsonb,
  lines_count int not null default 0,
  note text,
  closed_by uuid references public.members(id) on delete set null,
  closed_at timestamptz not null default now(),
  reopened_by uuid references public.members(id) on delete set null,
  reopened_at timestamptz
);
create unique index if not exists period_closes_live on public.period_closes(org_id, period_end) where status = 'closed';
create index if not exists period_closes_org on public.period_closes(org_id, period_end desc);
create index if not exists period_closes_journal_fk on public.period_closes(allowance_journal_id);
create index if not exists period_closes_closed_by_fk on public.period_closes(closed_by);
create index if not exists period_closes_reopened_by_fk on public.period_closes(reopened_by);

create table if not exists public.period_close_lines (
  id bigint generated always as identity primary key,
  close_id uuid not null references public.period_closes(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  item_id uuid references public.items(id) on delete cascade,
  location_id uuid references public.locations(id) on delete cascade,
  qty numeric(14,3) not null,
  unit_cost numeric(14,4),
  value numeric(16,2) not null default 0,
  price numeric(14,2),
  nrv_unit numeric(14,4),
  allowance numeric(16,2) not null default 0,
  reason text
);
create index if not exists period_close_lines_close on public.period_close_lines(close_id);
create index if not exists period_close_lines_org_fk on public.period_close_lines(org_id);
create index if not exists period_close_lines_item_fk on public.period_close_lines(item_id);
create index if not exists period_close_lines_location_fk on public.period_close_lines(location_id);

alter table public.period_closes enable row level security;
alter table public.period_close_lines enable row level security;
drop policy if exists period_closes_read on public.period_closes;
create policy period_closes_read on public.period_closes for select to authenticated using ((select private.can_see_costs(org_id)));
drop policy if exists period_close_lines_read on public.period_close_lines;
create policy period_close_lines_read on public.period_close_lines for select to authenticated using ((select private.can_see_costs(org_id)));

insert into public.posting_roles (role, label, description, default_code, allowed, sort) values
  ('nrv_writedown', 'Write-down to net realisable value', 'Expense when month-end close finds stock worth less than it cost.', '6805', '^(6805|5400|5209)$', 15),
  ('nrv_allowance', 'Allowance for stock below cost', 'Holds the month-end write-down against stock at cost, so stock is carried at the lower of cost and net realisable value.', '1207', '^(1207)$', 16)
on conflict (role) do nothing;

-- ---------------------------------------------------------------------------
-- The lock
-- ---------------------------------------------------------------------------
create or replace function private.closed_through(p_org uuid) returns date
language sql stable security definer set search_path = public as $$
  select max(period_end) from public.period_closes where org_id = p_org and status = 'closed'
$$;

create or replace function private.guard_closed_journal() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_closed date; v_tz text;
begin
  if coalesce(current_setting('app.period_close', true), '') = 'on' then return new; end if;
  v_closed := private.closed_through(new.org_id);
  if v_closed is not null and new.entry_date <= v_closed then
    select timezone into v_tz from orgs where id = new.org_id;
    new.memo := new.memo || ' · dated ' || to_char(new.entry_date, 'DD Mon YYYY') || ', posted after that month closed';
    new.entry_date := v_closed + 1;
    new.created_at := (v_closed + 1)::timestamp at time zone coalesce(v_tz, 'Africa/Lagos');
  end if;
  return new;
end $$;
drop trigger if exists journals_closed_period on public.journals;
create trigger journals_closed_period before insert on public.journals for each row execute function private.guard_closed_journal();

create or replace function private.guard_closed_movement() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_closed date; v_tz text; v_day date;
begin
  if coalesce(current_setting('app.period_close', true), '') = 'on' then return new; end if;
  v_closed := private.closed_through(new.org_id);
  if v_closed is null then return new; end if;
  select timezone into v_tz from orgs where id = new.org_id;
  v_day := (new.recorded_at at time zone coalesce(v_tz, 'Africa/Lagos'))::date;
  if v_day <= v_closed then
    new.note := concat_ws(' · ', nullif(new.note, ''), 'Recorded ' || to_char(v_day, 'DD Mon YYYY') || ' in a closed month');
    new.recorded_at := (v_closed + 1)::timestamp at time zone coalesce(v_tz, 'Africa/Lagos');
  end if;
  return new;
end $$;
drop trigger if exists movements_closed_period on public.movements;
create trigger movements_closed_period before insert on public.movements for each row execute function private.guard_closed_movement();

-- ---------------------------------------------------------------------------
-- Closing stock as at a date, with the net realisable value test
-- ---------------------------------------------------------------------------
-- p_policy: {selling_cost_pct, age_180_pct, age_365_pct, expired_pct}. Each line's allowance is the largest of:
--   sells below cost      qty x (unit cost - price x (1 - selling cost %))
--   expired batches       expired qty x unit cost x expired %
--   no sales for long     value x the ageing % (180 to 365 days, over 365 days)
create or replace function private.period_lines(p_org uuid, p_end date, p_policy jsonb default '{}'::jsonb)
returns table (item_id uuid, location_id uuid, item_name text, location_name text, item_type text, category text, unit text,
  qty numeric, unit_cost numeric, value numeric, price numeric, nrv_unit numeric, age_days int, expired_qty numeric,
  allowance numeric, reason text)
language plpgsql stable security definer set search_path = public, private as $$
declare v_tz text; v_t timestamptz; v_sell numeric; v_a180 numeric; v_a365 numeric; v_exp numeric;
begin
  select timezone into v_tz from orgs where id = p_org;
  v_t := (p_end + 1)::timestamp at time zone v_tz;
  v_sell := least(greatest(coalesce(private.num(p_policy->>'selling_cost_pct'), 0), 0), 90);
  v_a180 := least(greatest(coalesce(private.num(p_policy->>'age_180_pct'), 25), 0), 100);
  v_a365 := least(greatest(coalesce(private.num(p_policy->>'age_365_pct'), 50), 0), 100);
  v_exp := least(greatest(coalesce(private.num(p_policy->>'expired_pct'), 100), 0), 100);
  return query
  with mv as (
    select m.item_id, m.location_id, sum(m.qty) q from movements m
    where m.org_id = p_org and m.recorded_at < v_t group by 1, 2),
  landed as (
    select (a->>'item_id')::uuid iid, sum((a->>'allocated')::numeric) amt
    from landed_costs lc cross join lateral jsonb_array_elements(lc.allocation) a
    where lc.org_id = p_org and lc.created_at < v_t and coalesce((a->>'absorbed')::boolean, false) group by 1),
  book as (
    select m.item_id, sum(m.qty) q, sum(m.value) + coalesce((select l.amt from landed l where l.iid = m.item_id), 0) bv
    from movements m where m.org_id = p_org and m.recorded_at < v_t group by m.item_id),
  lastout as (
    select m.item_id, m.location_id, max(m.recorded_at) at from movements m
    where m.org_id = p_org and m.recorded_at < v_t and m.qty < 0 and m.type in ('sale', 'voice_sale', 'issue', 'transfer_out')
    group by 1, 2),
  firstin as (
    select m.item_id, m.location_id, min(m.recorded_at) at from movements m
    where m.org_id = p_org and m.recorded_at < v_t and m.qty > 0 group by 1, 2),
  expd as (
    select b.item_id, b.location_id, sum(b.qty_remaining) q from batches b
    where b.org_id = p_org and not b.quarantined and b.qty_remaining > 0 and b.expiry_date is not null and b.expiry_date <= p_end
    group by 1, 2),
  base as (
    select mv.item_id, mv.location_id, i.name iname, l.name lname, i.item_type itype, i.category cat, i.selling_unit su, mv.q,
      case when b.q <> 0 then b.bv / b.q end uc, i.price pr,
      case when private.sells(i.item_type) and i.price > 0 then round(i.price * (1 - v_sell / 100), 4) end nrv,
      (p_end - (coalesce(lo.at, fi.at) at time zone v_tz)::date)::int age,
      least(coalesce(e.q, 0), mv.q) eq
    from mv join book b on b.item_id = mv.item_id join items i on i.id = mv.item_id join locations l on l.id = mv.location_id
      left join lastout lo on lo.item_id = mv.item_id and lo.location_id = mv.location_id
      left join firstin fi on fi.item_id = mv.item_id and fi.location_id = mv.location_id
      left join expd e on e.item_id = mv.item_id and e.location_id = mv.location_id
    where mv.q <> 0),
  calc as (
    select base.*, round(base.q * coalesce(base.uc, 0), 2) val,
      case when base.q > 0 and base.nrv is not null and base.uc is not null and base.nrv < base.uc then round(base.q * (base.uc - base.nrv), 2) else 0 end a_price,
      case when base.q > 0 and base.eq > 0 then round(base.eq * coalesce(base.uc, 0) * v_exp / 100, 2) else 0 end a_exp,
      case when base.q > 0 and base.age > 365 then round(base.q * coalesce(base.uc, 0) * v_a365 / 100, 2)
           when base.q > 0 and base.age > 180 then round(base.q * coalesce(base.uc, 0) * v_a180 / 100, 2) else 0 end a_age
    from base)
  select c.item_id, c.location_id, c.iname, c.lname, c.itype, c.cat, c.su, c.q, round(c.uc, 4), c.val, c.pr, c.nrv, c.age, c.eq,
    least(greatest(c.a_price, c.a_exp, c.a_age), greatest(c.val, 0)),
    case when greatest(c.a_price, c.a_exp, c.a_age) = 0 then null
         when c.a_exp >= c.a_price and c.a_exp >= c.a_age then 'Expired batches'
         when c.a_price >= c.a_age then 'Sells below cost'
         else 'No sales for ' || c.age || ' days' end
  from calc c;
end $$;

-- Balance of the accounts that hold one posting role, as at a date. Credit balances come back positive when p_credit.
create or replace function private.role_balance(p_org uuid, p_role text, p_end date, p_credit boolean default false) returns numeric
language sql stable security definer set search_path = public, private as $$
  select coalesce(sum(case when p_credit then jl.credit - jl.debit else jl.debit - jl.credit end), 0)
  from journal_lines jl join journals j on j.id = jl.journal_id
  where jl.org_id = p_org and j.entry_date <= p_end and jl.account_code = private.acct(p_org, p_role)
$$;

create or replace function public.period_close_preview(p_org uuid, p_period_end date, p_policy jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_tz text; v_today date; v_closed date; v_inv_re text; v_t timestamptz; v jsonb;
begin
  m := private.require(p_org, 'see_margins');
  select timezone into v_tz from orgs where id = p_org;
  v_today := (now() at time zone v_tz)::date;
  v_closed := private.closed_through(p_org);
  if p_period_end is null then raise exception 'Choose the last day of the month to close.'; end if;
  v_t := (p_period_end + 1)::timestamp at time zone v_tz;
  select allowed into v_inv_re from posting_roles where role = 'inventory';
  with l as (select * from private.period_lines(p_org, p_period_end, p_policy))
  select jsonb_build_object(
    'period_end', p_period_end, 'closed_through', v_closed, 'today', v_today,
    'can_close', private.perm_of(m, 'owner') and p_period_end < v_today and (v_closed is null or p_period_end > v_closed),
    'stock_value', (select coalesce(sum(value), 0) from l),
    'lines_count', (select count(*) from l),
    'negative_lines', (select count(*) from l where qty < 0),
    'gl_inventory', (select coalesce(sum(jl.debit - jl.credit), 0) from journal_lines jl join journals j on j.id = jl.journal_id
                     where jl.org_id = p_org and j.entry_date <= p_period_end and jl.account_code ~ v_inv_re),
    'wip_value', private.role_balance(p_org, 'wip', p_period_end),
    'transit_value', private.role_balance(p_org, 'goods_in_transit', p_period_end),
    'current_allowance', private.role_balance(p_org, 'nrv_allowance', p_period_end, true),
    'proposed_allowance', (select coalesce(sum(allowance), 0) from l),
    'lines', coalesce((select jsonb_agg(jsonb_build_object(
        'item_id', item_id, 'location_id', location_id, 'item', item_name, 'location', location_name, 'category', category, 'unit', unit,
        'qty', qty, 'unit_cost', unit_cost, 'value', value, 'price', price, 'nrv_unit', nrv_unit, 'age_days', age_days,
        'expired_qty', expired_qty, 'allowance', allowance, 'reason', reason) order by allowance desc, item_name)
      from l where allowance > 0 or qty < 0), '[]'::jsonb),
    'checks', jsonb_build_object(
      'receipts_waiting', (select count(*) from receipts where org_id = p_org and status in ('reading', 'needs_review') and created_at < v_t),
      'counts_waiting', (select count(*) from count_sessions where org_id = p_org and status in ('awaiting_reasons', 'awaiting_approval')),
      'counts_open', (select count(*) from count_sessions where org_id = p_org and status = 'open' and created_at < v_t),
      'transfers_in_transit', (select count(*) from transfers where org_id = p_org and status = 'in_transit' and created_at < v_t),
      'runs_open', (select count(*) from jobs where org_id = p_org and kind = 'production' and status = 'open' and created_at < v_t),
      'voice_to_review', (select count(*) from movements where org_id = p_org and review_status = 'pending' and recorded_at < v_t))
  ) into v from (select 1) x;
  return v;
end $$;

-- Close the month. p_overrides: [{item_id, location_id, allowance}] replaces the proposed allowance on a line.
create or replace function public.close_period(p_org uuid, p_period_end date, p_policy jsonb default '{}'::jsonb,
  p_overrides jsonb default '[]'::jsonb, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_tz text; v_today date; v_closed date; v_inv_re text; v_id uuid; v_new numeric; v_cur numeric; v_change numeric;
  j public.journals; v_stock numeric; v_gl numeric; v_n int;
begin
  m := private.require(p_org, 'owner');
  select timezone into v_tz from orgs where id = p_org;
  v_today := (now() at time zone v_tz)::date;
  v_closed := private.closed_through(p_org);
  if p_period_end is null or p_period_end >= v_today then raise exception 'Only a day that has already ended can be closed.'; end if;
  if v_closed is not null and p_period_end <= v_closed then
    raise exception 'Stock is already closed up to %. Choose a later date.', to_char(v_closed, 'DD Mon YYYY');
  end if;
  select allowed into v_inv_re from posting_roles where role = 'inventory';

  create temporary table if not exists pg_temp.close_lines on commit drop as
    select * from private.period_lines(p_org, p_period_end, p_policy) limit 0;
  delete from pg_temp.close_lines;
  insert into pg_temp.close_lines select * from private.period_lines(p_org, p_period_end, p_policy);
  update pg_temp.close_lines cl set allowance = least(greatest(round(private.num(o->>'allowance'), 2), 0), greatest(cl.value, 0))
  from jsonb_array_elements(case when jsonb_typeof(p_overrides) = 'array' then p_overrides else '[]'::jsonb end) o
  where cl.item_id = nullif(o->>'item_id', '')::uuid and cl.location_id = nullif(o->>'location_id', '')::uuid and o ? 'allowance';
  update pg_temp.close_lines set reason = coalesce(reason, 'Set at close') where allowance > 0;

  select coalesce(sum(allowance), 0), coalesce(sum(value), 0), count(*) into v_new, v_stock, v_n from pg_temp.close_lines;
  v_cur := private.role_balance(p_org, 'nrv_allowance', p_period_end, true);
  v_change := round(v_new - v_cur, 2);
  if v_change <> 0 then
    j := private.post_journal(p_org, 'Month-end close ' || to_char(p_period_end, 'Mon YYYY') || ' · stock below cost allowance', 'period_close', null,
      m.id, m.id, private.reclass_pair(private.acct(p_org, 'nrv_writedown'), private.acct(p_org, 'nrv_allowance'), v_change, null, null),
      ((p_period_end + 1)::timestamp at time zone v_tz) - interval '1 second');
  end if;
  select coalesce(sum(jl.debit - jl.credit), 0) into v_gl from journal_lines jl join journals jj on jj.id = jl.journal_id
  where jl.org_id = p_org and jj.entry_date <= p_period_end and jl.account_code ~ v_inv_re;

  insert into period_closes (org_id, period_end, stock_value, gl_value, wip_value, transit_value, allowance, allowance_change,
    allowance_journal_id, policy, lines_count, note, closed_by)
  values (p_org, p_period_end, v_stock, v_gl, private.role_balance(p_org, 'wip', p_period_end),
    private.role_balance(p_org, 'goods_in_transit', p_period_end), v_new, v_change, j.id, coalesce(p_policy, '{}'::jsonb), v_n,
    nullif(trim(p_note), ''), m.id)
  returning id into v_id;
  insert into period_close_lines (close_id, org_id, item_id, location_id, qty, unit_cost, value, price, nrv_unit, allowance, reason)
  select v_id, p_org, item_id, location_id, qty, unit_cost, value, price, nrv_unit, allowance, reason from pg_temp.close_lines;
  return jsonb_build_object('id', v_id, 'period_end', p_period_end, 'stock_value', v_stock, 'gl_value', v_gl, 'allowance', v_new,
    'allowance_change', v_change, 'journal_ref', j.ref, 'lines', v_n);
end $$;

-- Reopen the latest closed month. Its allowance entry is reversed, dated the same day.
create or replace function public.reopen_period(p_org uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; pc public.period_closes; v_tz text; j public.journals;
begin
  m := private.require(p_org, 'owner');
  select * into pc from period_closes where org_id = p_org and status = 'closed' order by period_end desc limit 1 for update;
  if not found then raise exception 'No month is closed.'; end if;
  select timezone into v_tz from orgs where id = p_org;
  update period_closes set status = 'reopened', reopened_by = m.id, reopened_at = now(),
    note = concat_ws(E'\n', note, 'Reopened' || coalesce(': ' || nullif(trim(p_reason), ''), ''))
  where id = pc.id;
  if pc.allowance_change <> 0 then
    j := private.post_journal(p_org, 'Reopened ' || to_char(pc.period_end, 'Mon YYYY') || ' · allowance reversed', 'period_close', null,
      m.id, m.id, private.reclass_pair(private.acct(p_org, 'nrv_allowance'), private.acct(p_org, 'nrv_writedown'), pc.allowance_change, null, null),
      ((pc.period_end + 1)::timestamp at time zone v_tz) - interval '1 second');
  end if;
  return jsonb_build_object('period_end', pc.period_end, 'journal_ref', j.ref, 'closed_through', private.closed_through(p_org));
end $$;

create or replace function public.get_period_closes(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, 'see_margins');
  return jsonb_build_object(
    'closed_through', private.closed_through(p_org),
    'closes', coalesce((select jsonb_agg(jsonb_build_object(
        'id', pc.id, 'period_end', pc.period_end, 'status', pc.status, 'stock_value', pc.stock_value, 'gl_value', pc.gl_value,
        'wip_value', pc.wip_value, 'transit_value', pc.transit_value, 'allowance', pc.allowance, 'allowance_change', pc.allowance_change,
        'journal_ref', (select ref from journals where id = pc.allowance_journal_id), 'lines_count', pc.lines_count, 'policy', pc.policy,
        'note', pc.note, 'closed_at', pc.closed_at, 'closed_by', (select display_name from members where id = pc.closed_by),
        'reopened_at', pc.reopened_at, 'reopened_by', (select display_name from members where id = pc.reopened_by))
      order by pc.period_end desc, pc.closed_at desc) from period_closes pc where pc.org_id = p_org), '[]'::jsonb));
end $$;

create or replace function public.get_period_close_lines(p_close uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; pc public.period_closes;
begin
  select * into pc from period_closes where id = p_close;
  if not found then raise exception 'Close not found.'; end if;
  m := private.require(pc.org_id, 'see_margins');
  return coalesce((select jsonb_agg(jsonb_build_object(
      'item', i.name, 'sku', i.sku, 'category', i.category, 'location', l.name, 'unit', i.selling_unit, 'qty', cl.qty,
      'unit_cost', cl.unit_cost, 'value', cl.value, 'price', cl.price, 'nrv_unit', cl.nrv_unit, 'allowance', cl.allowance,
      'carrying', cl.value - cl.allowance, 'reason', cl.reason) order by i.name, l.name)
    from period_close_lines cl left join items i on i.id = cl.item_id left join locations l on l.id = cl.location_id
    where cl.close_id = p_close), '[]'::jsonb);
end $$;
