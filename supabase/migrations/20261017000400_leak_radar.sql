-- Counta: Leak radar and daily spot checks.
-- Every count already tells Counta what went missing, where, and since when. Leak radar turns that history into a
-- risk score per item and branch: how fast the item moves, how long since anyone checked it, how often it went missing
-- before, and whether the books show it below zero. Each morning the riskiest few items at every branch go to a staff
-- member as a short blind count, picked so the person counting is not the person who sold them.

alter table public.orgs add column if not exists spot_checks_per_day int not null default 0;
alter table public.orgs drop constraint if exists orgs_spot_checks_check;
alter table public.orgs add constraint orgs_spot_checks_check check (spot_checks_per_day between 0 and 25);
alter table public.orgs add column if not exists spot_check_last date;
alter table public.count_sessions add column if not exists source text not null default 'manual';
alter table public.count_sessions drop constraint if exists count_sessions_source_check;
alter table public.count_sessions add constraint count_sessions_source_check check (source in ('manual', 'spot_check'));

-- Risk per item and branch. risk is the naira value likely to have gone missing since the item was last checked.
create or replace function private.item_risk(p_org uuid, p_days int default 90)
returns table (item_id uuid, location_id uuid, on_hand numeric, unit_cost numeric, per_day numeric, days_unchecked int,
  lost_qty numeric, sold_qty numeric, loss_rate numeric, units_since numeric, risk numeric, flags text[])
language plpgsql stable security definer set search_path = public, private as $$
declare v_tz text; v_from timestamptz; v_today date; v_rate numeric;
begin
  select timezone into v_tz from orgs where id = p_org;
  v_today := (now() at time zone v_tz)::date;
  v_from := now() - make_interval(days => greatest(coalesce(p_days, 90), 14));
  select coalesce(sum(-m.qty) filter (where m.type = 'adjustment' and m.qty < 0 and coalesce(m.reason, '') not in ('Breakage', 'Expired')), 0)
         / greatest(coalesce(sum(-m.qty) filter (where m.type in ('sale', 'voice_sale', 'issue')), 0), 1)
    into v_rate from movements m where m.org_id = p_org and m.recorded_at >= v_from;
  v_rate := greatest(least(coalesce(v_rate, 0), 0.5), 0.005);
  return query
  with mv as (
    select m.item_id, m.location_id,
      coalesce(sum(-m.qty) filter (where m.type in ('sale', 'voice_sale', 'issue')), 0) sold,
      coalesce(sum(-m.qty) filter (where m.type in ('sale', 'voice_sale', 'issue') and m.recorded_at >= now() - interval '30 days'), 0) sold30,
      coalesce(sum(-m.qty) filter (where m.type = 'adjustment' and m.qty < 0 and coalesce(m.reason, '') not in ('Breakage', 'Expired')), 0) lost
    from movements m where m.org_id = p_org and m.recorded_at >= v_from group by 1, 2),
  lc as (
    select cl.item_id, cs.location_id, max(coalesce(cs.submitted_at, cs.approved_at)) at
    from count_lines cl join count_sessions cs on cs.id = cl.session_id
    where cs.org_id = p_org and cl.counted is not null and cs.status in ('awaiting_reasons', 'awaiting_approval', 'approved')
    group by 1, 2),
  fm as (select m.item_id, m.location_id, min(m.recorded_at) at from movements m where m.org_id = p_org group by 1, 2),
  base as (
    select s.item_id, s.location_id, s.qty oh, coalesce(c.wac, 0) uc, coalesce(mv.sold30, 0) / 30.0 pd,
      greatest((v_today - (coalesce(lc.at, fm.at, now()) at time zone v_tz)::date)::int, 0) du,
      coalesce(mv.lost, 0) lq, coalesce(mv.sold, 0) sq, lc.at is null never
    from stock_levels s join items i on i.id = s.item_id and not i.archived
      left join item_costs c on c.item_id = s.item_id
      left join mv on mv.item_id = s.item_id and mv.location_id = s.location_id
      left join lc on lc.item_id = s.item_id and lc.location_id = s.location_id
      left join fm on fm.item_id = s.item_id and fm.location_id = s.location_id
    where s.org_id = p_org),
  calc as (
    select b.*, greatest(case when b.lq > 0 then b.lq / greatest(b.sq + b.lq, 1) else 0 end, v_rate) rate,
      b.pd * least(b.du, 120) since
    from base b)
  select c.item_id, c.location_id, c.oh, c.uc, round(c.pd, 3), c.du, c.lq, c.sq, round(c.rate, 4), round(c.since, 1),
    round(c.since * c.rate * c.uc
      + greatest(c.oh, 0) * c.uc * 0.001 * least(c.du, 120) / 30.0
      + case when c.oh < 0 then abs(c.oh) * c.uc + 1 else 0 end, 2),
    array_remove(array[
      case when c.oh < 0 then 'Below zero on the books' end,
      case when c.lq > 0 then 'Went missing before' end,
      case when c.never then 'Never counted' when c.du > 45 then 'Not counted for ' || c.du || ' days' end], null)
  from calc c
  where c.oh <> 0 or c.sq > 0;
end $$;

create or replace function public.leak_radar(p_org uuid, p_days int default 90) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_tz text; v_from timestamptz; v_today date; v_days int; v_out jsonb; v_owner boolean;
begin
  m := private.require(p_org, 'see_margins');
  v_owner := m.role = 'owner';
  v_days := least(greatest(coalesce(p_days, 90), 14), 365);
  select timezone into v_tz from orgs where id = p_org;
  v_today := (now() at time zone v_tz)::date;
  v_from := now() - make_interval(days => v_days);
  with adj as (
    select mv.* from movements mv
    where mv.org_id = p_org and mv.recorded_at >= v_from and mv.type in ('adjustment', 'write_off', 'quarantine')),
  tot as (
    select
      coalesce(sum(-value) filter (where type = 'adjustment' and qty < 0 and coalesce(reason, '') not in ('Breakage', 'Expired')), 0) unexplained,
      coalesce(sum(value) filter (where type = 'adjustment' and qty > 0), 0) gained,
      coalesce(sum(-value) filter (where (type = 'adjustment' and qty < 0 and reason in ('Breakage', 'Expired')) or type in ('write_off', 'quarantine')), 0) damage
    from adj),
  sales as (
    select coalesce(sum(-value), 0) cogs, coalesce(sum(-qty * coalesce(unit_price, 0)), 0) rev
    from movements where org_id = p_org and recorded_at >= v_from and type in ('sale', 'voice_sale')),
  ira as (
    select cs.location_id, count(*) n, count(*) filter (where abs(cl.counted - cl.expected) <= cl.expected * 0.02) ok
    from count_lines cl join count_sessions cs on cs.id = cl.session_id
    where cs.org_id = p_org and cl.counted is not null and cl.expected is not null and coalesce(cs.submitted_at, cs.created_at) >= v_from
    group by rollup (cs.location_id)),
  wk as (
    select date_trunc('week', (recorded_at at time zone v_tz))::date wk,
      coalesce(sum(-value) filter (where type = 'adjustment' and qty < 0 and coalesce(reason, '') not in ('Breakage', 'Expired')), 0) unexplained,
      coalesce(sum(value) filter (where type = 'adjustment' and qty > 0), 0) gained,
      coalesce(sum(-value) filter (where (type = 'adjustment' and qty < 0 and reason in ('Breakage', 'Expired')) or type in ('write_off', 'quarantine')), 0) damage
    from adj group by 1),
  cash as (
    select ct.location_id, ct.day, ct.cash + ct.pos + ct.transfers recorded,
      coalesce((select sum(-mv.qty * coalesce(mv.unit_price, 0)) from movements mv where mv.org_id = p_org and mv.location_id = ct.location_id
        and mv.type in ('sale', 'voice_sale') and (mv.recorded_at at time zone v_tz)::date = ct.day), 0) implied
    from cash_takings ct where ct.org_id = p_org and ct.day >= (v_from at time zone v_tz)::date),
  byloc as (
    select l.id, l.name,
      coalesce((select sum(-a.value) from adj a where a.location_id = l.id and a.type = 'adjustment' and a.qty < 0 and coalesce(a.reason, '') not in ('Breakage', 'Expired')), 0) unexplained,
      coalesce((select sum(a.value) from adj a where a.location_id = l.id and a.type = 'adjustment' and a.qty > 0), 0) gained,
      coalesce((select sum(-a.value) from adj a where a.location_id = l.id and ((a.type = 'adjustment' and a.qty < 0 and a.reason in ('Breakage', 'Expired')) or a.type in ('write_off', 'quarantine'))), 0) damage,
      coalesce((select sum(-mv.value) from movements mv where mv.org_id = p_org and mv.location_id = l.id and mv.type in ('sale', 'voice_sale') and mv.recorded_at >= v_from), 0) cogs,
      coalesce((select sum(greatest(c.implied - c.recorded, 0)) from cash c where c.location_id = l.id), 0) cash_short,
      (select round(100.0 * ok / nullif(n, 0), 1) from ira where ira.location_id = l.id) ira
    from locations l where l.org_id = p_org),
  risk as (select * from private.item_risk(p_org, v_days) r where r.risk > 0 order by r.risk desc limit 30)
  select jsonb_build_object(
    'days', v_days, 'today', v_today,
    'unexplained', t.unexplained, 'found', t.gained, 'net_unexplained', t.unexplained - t.gained, 'damage', t.damage,
    'cogs', s.cogs, 'revenue', s.rev,
    'shrink_pct', case when s.cogs > 0 then round(100 * (t.unexplained - t.gained) / s.cogs, 4) end,
    'monthly_leak', round((t.unexplained - t.gained + t.damage) * 30.0 / v_days, 2),
    'ira', (select round(100.0 * ok / nullif(n, 0), 1) from ira where ira.location_id is null),
    'lines_counted', (select n from ira where ira.location_id is null),
    'cash_short', (select coalesce(sum(greatest(implied - recorded, 0)), 0) from cash),
    'cash_days', (select count(*) from cash),
    'weeks', coalesce((select jsonb_agg(jsonb_build_object('week', wk, 'unexplained', unexplained, 'found', gained, 'damage', damage) order by wk)
                       from wk where wk >= (v_today - 84)), '[]'::jsonb),
    'locations', coalesce((select jsonb_agg(jsonb_build_object('location_id', id, 'name', name, 'unexplained', unexplained, 'found', gained,
        'damage', damage, 'cogs', cogs, 'shrink_pct', case when cogs > 0 then round(100 * (unexplained - gained) / cogs, 4) end,
        'cash_short', cash_short, 'ira', ira) order by name) from byloc), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(jsonb_build_object('item_id', r.item_id, 'location_id', r.location_id, 'item', i.name,
        'location', l.name, 'unit', i.selling_unit, 'on_hand', r.on_hand, 'unit_cost', r.unit_cost, 'per_day', r.per_day,
        'days_unchecked', r.days_unchecked, 'lost_qty', r.lost_qty, 'sold_qty', r.sold_qty, 'loss_rate', r.loss_rate,
        'risk', r.risk, 'flags', r.flags) order by r.risk desc)
      from risk r join items i on i.id = r.item_id join locations l on l.id = r.location_id), '[]'::jsonb),
    'spot_checks_per_day', (select spot_checks_per_day from orgs where id = p_org),
    'spot_check_last', (select spot_check_last from orgs where id = p_org),
    'spot_checks', coalesce((select jsonb_agg(jsonb_build_object('id', cs.id, 'ref', cs.ref, 'location_id', cs.location_id, 'area', cs.area,
        'status', cs.status, 'assignee', (select display_name from members where id = cs.assignee_id), 'created_at', cs.created_at,
        'items', (select count(*) from count_lines where session_id = cs.id),
        'differences', (select count(*) from count_lines where session_id = cs.id and counted is not null and expected is not null and counted <> expected))
      order by cs.created_at desc)
      from count_sessions cs where cs.org_id = p_org and cs.source = 'spot_check' and cs.created_at > now() - interval '14 days'), '[]'::jsonb),
    'can_see_people', v_owner
  ) into v_out
  from tot t, sales s;

  if v_owner then
    with ev as (
      select a.id, a.item_id, a.location_id, a.recorded_at at, -a.value v,
        coalesce((select max(coalesce(cs2.submitted_at, cs2.approved_at)) from count_lines cl2 join count_sessions cs2 on cs2.id = cl2.session_id
                  where cs2.location_id = a.location_id and cl2.item_id = a.item_id and cl2.counted is not null
                    and cs2.id is distinct from a.count_session_id and coalesce(cs2.submitted_at, cs2.approved_at) < a.recorded_at),
                 v_from - interval '30 days') prev
      from movements a
      where a.org_id = p_org and a.type = 'adjustment' and a.qty < 0 and a.recorded_at >= v_from
        and coalesce(a.reason, '') not in ('Breakage', 'Expired')),
    shares as (
      select ev.id, s.author_id, sum(-s.qty) q, ev.v
      from ev join movements s on s.org_id = p_org and s.item_id = ev.item_id and s.location_id = ev.location_id
        and s.type in ('sale', 'voice_sale', 'issue') and s.recorded_at > ev.prev and s.recorded_at <= ev.at and s.author_id is not null
      group by ev.id, s.author_id, ev.v),
    alloc as (
      select author_id, sum(v * q / nullif((select sum(q) from shares s2 where s2.id = shares.id), 0)) loss, count(distinct id) events
      from shares group by 1),
    sold as (
      select author_id, sum(-qty * coalesce(unit_price, 0)) rev, count(*) n, count(*) filter (where offline) offline_n,
        count(*) filter (where type = 'voice_sale') voice_n
      from movements where org_id = p_org and type in ('sale', 'voice_sale') and recorded_at >= v_from group by 1),
    ppl as (
      select mb.id, mb.display_name, mb.role, mb.location_id, coalesce(sd.rev, 0) rev, coalesce(sd.n, 0) n, coalesce(sd.offline_n, 0) offline_n,
        coalesce(sd.voice_n, 0) voice_n, coalesce(al.loss, 0) loss, coalesce(al.events, 0) events
      from members mb left join sold sd on sd.author_id = mb.id left join alloc al on al.author_id = mb.id
      where mb.org_id = p_org and (sd.n > 0 or al.events > 0))
    select v_out || jsonb_build_object(
      'loss_events', (select count(*) from ev),
      'people', coalesce((select jsonb_agg(jsonb_build_object('member_id', id, 'name', display_name, 'role', role, 'location_id', location_id,
          'sales', n, 'sales_value', rev, 'offline_sales', offline_n, 'voice_sales', voice_n, 'loss', round(loss, 2), 'events', events,
          'loss_pct', case when rev > 0 then round(100 * loss / rev, 2) end) order by loss desc, rev desc) from ppl), '[]'::jsonb))
    into v_out;
  end if;
  return v_out;
end $$;

-- Plan today's spot checks. One short blind count per branch, of the riskiest items not already being counted or
-- counted in the last week, given to someone with Count stock who sold those items least in the last two weeks.
create or replace function private.plan_spot_checks(p_org uuid, p_n int default null) returns int
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; v_n int; l record; v_items uuid[]; a public.members; v_id uuid; v_ref text; v_made int := 0;
begin
  select * into o from orgs where id = p_org;
  v_n := least(coalesce(p_n, o.spot_checks_per_day, 0), 25);
  if v_n <= 0 then return 0; end if;
  for l in select * from locations where org_id = p_org order by is_main desc, name loop
    select array_agg(x.item_id order by x.risk desc) into v_items from (
      select r.item_id, r.risk from private.item_risk(p_org, 90) r
      where r.location_id = l.id and r.on_hand <> 0
        and not exists (select 1 from count_lines cl join count_sessions cs on cs.id = cl.session_id
                        where cs.location_id = l.id and cl.item_id = r.item_id
                          and (cs.status <> 'approved' or coalesce(cs.submitted_at, cs.created_at) > now() - interval '7 days'))
      order by r.risk desc limit v_n) x;
    if v_items is null or cardinality(v_items) = 0 then continue; end if;
    select mb.* into a from members mb
    where mb.org_id = p_org and mb.status = 'active' and private.perm_of(mb, 'count_stock')
      and (mb.location_id = l.id or mb.location_id is null)
    order by (mb.user_id is null), (mb.role = 'owner'),
      (select coalesce(sum(-s.qty), 0) from movements s where s.author_id = mb.id and s.location_id = l.id and s.item_id = any(v_items)
         and s.type in ('sale', 'voice_sale') and s.recorded_at > now() - interval '14 days'),
      random()
    limit 1;
    if a.id is null then continue; end if;
    v_ref := 'CS-' || lpad(private.next_no(p_org, 'CS', 1)::text, 3, '0');
    insert into count_sessions (org_id, ref, location_id, area, assignee_id, created_by, source)
    values (p_org, v_ref, l.id, 'Spot check · ' || cardinality(v_items) || case when cardinality(v_items) = 1 then ' item' else ' items' end,
      a.id, null, 'spot_check')
    returning id into v_id;
    insert into count_lines (session_id, org_id, item_id) select v_id, p_org, unnest(v_items);
    perform private.notify(p_org, a.user_id, 'spot_check', 'Spot check at ' || l.name,
      cardinality(v_items) || ' item' || case when cardinality(v_items) = 1 then '' else 's' end
        || ' to count before it gets busy. Count what you see on the shelf.',
      '/m/count/' || v_id, 'spot:' || v_id);
    v_made := v_made + 1;
  end loop;
  update orgs set spot_check_last = (now() at time zone o.timezone)::date where id = p_org;
  return v_made;
end $$;

create or replace function private.cron_spot_checks() returns void
language plpgsql security definer set search_path = public, private as $$
declare o record;
begin
  for o in select id from orgs
           where spot_checks_per_day > 0 and (spot_check_last is null or spot_check_last < (now() at time zone timezone)::date) loop
    begin
      perform private.plan_spot_checks(o.id);
    exception when others then
      raise warning 'Spot checks failed for %: %', o.id, sqlerrm;
    end;
  end loop;
end $$;

create or replace function public.run_spot_checks(p_org uuid, p_n int default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_n int;
begin
  m := private.require(p_org, 'approve_adjustments');
  v_n := private.plan_spot_checks(p_org, coalesce(p_n, nullif((select spot_checks_per_day from orgs where id = p_org), 0), 5));
  return jsonb_build_object('created', v_n);
end $$;

create or replace function public.set_spot_checks(p_org uuid, p_n int) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, 'owner');
  if p_n is null or p_n < 0 or p_n > 25 then raise exception 'Choose between 0 and 25 items a day.'; end if;
  update orgs set spot_checks_per_day = p_n where id = p_org;
  return jsonb_build_object('spot_checks_per_day', p_n);
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'counta-spot-checks';
    perform cron.schedule('counta-spot-checks', '30 4 * * *', 'select private.cron_spot_checks()');
  end if;
end $$;
