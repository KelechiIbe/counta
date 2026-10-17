-- Counta: issuing stock to production runs and jobs.
-- A production run turns materials into a finished item: issues move cost from the material's inventory account into
-- work in progress (1202), and recording the output moves the run's whole cost into the finished item's account.
-- A job (repair, maintenance, customer job, project) charges issued stock straight to the job's account.

-- ---------------------------------------------------------------------------
-- 1. Permission: Issue to jobs
-- ---------------------------------------------------------------------------
alter table public.members add column if not exists p_issue_stock boolean default false;
update public.members set p_issue_stock = (role in ('owner', 'manager') or (role = 'staff' and (p_receive_stock or p_transfer_stock)))
where p_issue_stock is not true;
alter table public.members alter column p_issue_stock drop default;
alter table public.members alter column p_issue_stock set not null;

create or replace function private.role_template(p_role text) returns jsonb
language sql immutable set search_path = public, private as $$
  select case p_role
    when 'owner' then '{"record_sales":true,"receive_stock":true,"count_stock":true,"approve_adjustments":true,"edit_prices":true,"approve_pos":true,"transfer_stock":true,"see_margins":true,"issue_stock":true}'
    when 'manager' then '{"record_sales":true,"receive_stock":true,"count_stock":true,"approve_adjustments":false,"edit_prices":false,"approve_pos":false,"transfer_stock":true,"see_margins":true,"issue_stock":true}'
    when 'staff' then '{"record_sales":true,"receive_stock":true,"count_stock":true,"approve_adjustments":false,"edit_prices":false,"approve_pos":false,"transfer_stock":false,"see_margins":false,"issue_stock":true}'
    else '{"record_sales":true,"receive_stock":false,"count_stock":false,"approve_adjustments":false,"edit_prices":false,"approve_pos":false,"transfer_stock":false,"see_margins":false,"issue_stock":false}'
  end::jsonb
$$;

-- New people get the permission from their role unless it is set explicitly.
create or replace function private.member_defaults() returns trigger
language plpgsql set search_path = public, private as $$
begin
  if new.p_issue_stock is null then
    new.p_issue_stock := coalesce((private.role_template(new.role)->>'issue_stock')::boolean, false);
  end if;
  return new;
end $$;
drop trigger if exists members_defaults on public.members;
create trigger members_defaults before insert on public.members for each row execute function private.member_defaults();

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
      when 'owner' then false
      else false end
  end
$$;

create or replace function public.update_member(p_member uuid, p_patch jsonb) returns void
language plpgsql security definer set search_path = public, private as $$
declare t public.members; m public.members; p jsonb; v_role text;
begin
  select * into t from members where id = p_member;
  if not found then raise exception 'Person not found.'; end if;
  m := private.require(t.org_id, 'owner');
  if t.role = 'owner' and (p_patch ? 'role' or p_patch ? 'perms' or p_patch ? 'status') then
    raise exception 'The owner keeps every permission.';
  end if;
  v_role := coalesce(p_patch->>'role', t.role);
  if v_role not in ('owner', 'manager', 'staff', 'cashier') then raise exception 'Unknown role.'; end if;
  if v_role = 'owner' and t.role <> 'owner' then raise exception 'Ownership transfer is not available here.'; end if;
  p := case when p_patch ? 'role' and p_patch->>'role' <> t.role and not (p_patch ? 'perms')
            then private.role_template(v_role) else coalesce(p_patch->'perms', '{}'::jsonb) end;
  update members set
    role = v_role,
    display_name = coalesce(nullif(trim(p_patch->>'display_name'), ''), display_name),
    title = case when p_patch ? 'title' then nullif(trim(p_patch->>'title'), '') else title end,
    phone = case when p_patch ? 'phone' then nullif(trim(p_patch->>'phone'), '') else phone end,
    location_id = case when p_patch ? 'location_id' then nullif(p_patch->>'location_id', '')::uuid else location_id end,
    status = coalesce(p_patch->>'status', status),
    p_record_sales = coalesce((p->>'record_sales')::boolean, p_record_sales),
    p_receive_stock = coalesce((p->>'receive_stock')::boolean, p_receive_stock),
    p_count_stock = coalesce((p->>'count_stock')::boolean, p_count_stock),
    p_approve_adjustments = coalesce((p->>'approve_adjustments')::boolean, p_approve_adjustments),
    p_edit_prices = coalesce((p->>'edit_prices')::boolean, p_edit_prices),
    p_approve_pos = coalesce((p->>'approve_pos')::boolean, p_approve_pos),
    p_transfer_stock = coalesce((p->>'transfer_stock')::boolean, p_transfer_stock),
    p_see_margins = coalesce((p->>'see_margins')::boolean, p_see_margins),
    p_issue_stock = coalesce((p->>'issue_stock')::boolean, p_issue_stock)
  where id = p_member;
exception when check_violation then
  raise exception 'Someone who records sales cannot also edit prices or approve adjustments.';
end $$;

-- ---------------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------------
create table if not exists public.jobs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  ref text not null,
  kind text not null check (kind in ('production', 'job')),
  name text not null check (length(trim(name)) > 0),
  location_id uuid not null references public.locations(id) on delete cascade,
  status text not null default 'open' check (status in ('open', 'completed', 'cancelled')),
  output_item_id uuid references public.items(id) on delete set null,
  planned_qty numeric(14,3),
  produced_qty numeric(14,3),
  output_unit_cost numeric(14,4),
  charge_account text references public.accounts(code),
  customer text,
  notes text,
  due_date date,
  client_uuid uuid unique,
  created_by uuid references public.members(id) on delete set null,
  closed_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  unique (org_id, ref)
);
create index if not exists jobs_org on public.jobs(org_id, status, created_at desc);
create index if not exists jobs_location_id_fk on public.jobs(location_id);
create index if not exists jobs_output_item_id_fk on public.jobs(output_item_id);
create index if not exists jobs_created_by_fk on public.jobs(created_by);
create index if not exists jobs_closed_by_fk on public.jobs(closed_by);
create index if not exists jobs_charge_account_fk on public.jobs(charge_account);

-- One recipe (bill of materials) per item: what goes into a batch and how much the batch makes.
create table if not exists public.recipes (
  output_item_id uuid primary key references public.items(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  yield_qty numeric(14,3) not null default 1 check (yield_qty > 0),
  lines jsonb not null default '[]'::jsonb,
  notes text,
  updated_by uuid references public.members(id) on delete set null,
  updated_at timestamptz not null default now()
);
create index if not exists recipes_org on public.recipes(org_id);
create index if not exists recipes_updated_by_fk on public.recipes(updated_by);

alter table public.jobs enable row level security;
alter table public.recipes enable row level security;
drop policy if exists jobs_read on public.jobs;
create policy jobs_read on public.jobs for select to authenticated using ((select private.is_member(org_id)));
drop policy if exists recipes_read on public.recipes;
create policy recipes_read on public.recipes for select to authenticated using ((select private.is_member(org_id)));

alter table public.movements drop constraint if exists movements_type_check;
alter table public.movements add constraint movements_type_check check (type in (
  'opening', 'receipt', 'sale', 'voice_sale', 'transfer_out', 'transfer_in', 'adjustment', 'write_off', 'quarantine',
  'issue', 'issue_return', 'production_in'));
alter table public.movements add column if not exists job_id uuid references public.jobs(id) on delete set null;
create index if not exists movements_job on public.movements(job_id) where job_id is not null;

insert into public.posting_roles (role, label, description, default_code, allowed, sort) values
  ('wip', 'Production in progress', 'Materials issued to an open production run, and labour or overheads added to it, until its output is recorded.', '1202', '^(1202)$', 12),
  ('job_materials', 'Materials used on jobs', 'Default account charged when stock is issued to a job, repair or project. Each job can choose its own.', '5202', '^(5202|5207|5209|5305|5306|6208|6209|6216|1521)$', 13),
  ('production_absorbed', 'Labour and overheads in production', 'Credit side when a production run takes labour, power or other costs into the cost of what it made.', '5400', '^(5400|5401|5201|5304|5306)$', 14)
on conflict (role) do nothing;

-- ---------------------------------------------------------------------------
-- 3. Helpers
-- ---------------------------------------------------------------------------
create or replace function private.add_movement(p_org uuid, p_type text, p_item uuid, p_location uuid, p_qty numeric, p_unit_cost numeric,
  p_unit_price numeric, p_journal uuid, p_author uuid, p_channel text, p_at timestamptz default now(), p_extra jsonb default '{}'::jsonb)
returns public.movements
language plpgsql security definer set search_path = public as $$
declare mv public.movements;
begin
  insert into public.movements (
    org_id, type, item_id, location_id, qty, unit_cost, unit_price, journal_id, author_id, channel,
    recorded_at, synced_at, receipt_id, transfer_id, count_session_id, batch_id, reason, note,
    approver_id, device_id, offline, client_uuid, review_status, job_id)
  values (
    p_org, p_type, p_item, p_location, p_qty, coalesce(p_unit_cost, 0), p_unit_price, p_journal, p_author, coalesce(p_channel, 'App'),
    p_at, case when coalesce((p_extra->>'offline')::boolean, false) then now() else p_at end,
    nullif(p_extra->>'receipt_id', '')::uuid, nullif(p_extra->>'transfer_id', '')::uuid,
    nullif(p_extra->>'count_session_id', '')::uuid, nullif(p_extra->>'batch_id', '')::uuid,
    p_extra->>'reason', p_extra->>'note', nullif(p_extra->>'approver_id', '')::uuid,
    p_extra->>'device_id', coalesce((p_extra->>'offline')::boolean, false),
    nullif(p_extra->>'client_uuid', '')::uuid, p_extra->>'review_status', nullif(p_extra->>'job_id', '')::uuid)
  returning * into mv;
  return mv;
end $$;

-- Weighted average cost after p_qty arrives at a total of p_value. Call before the movement is added.
create or replace function private.update_wac(p_item uuid, p_qty numeric, p_value numeric) returns numeric
language plpgsql security definer set search_path = public, private as $$
declare v_on numeric; v_wac numeric;
begin
  if p_qty is null or p_qty <= 0 then return null; end if;
  insert into item_costs (item_id, org_id, wac) select id, org_id, 0 from items where id = p_item on conflict (item_id) do nothing;
  select coalesce(sum(qty), 0) into v_on from stock_levels where item_id = p_item;
  select wac into v_wac from item_costs where item_id = p_item for update;
  if v_on <= 0 or coalesce(v_wac, 0) = 0 then v_wac := round(p_value / p_qty, 4);
  else v_wac := round((v_on * v_wac + p_value) / (v_on + p_qty), 4); end if;
  update item_costs set wac = greatest(v_wac, 0), updated_at = now() where item_id = p_item;
  return v_wac;
end $$;

-- Cost sitting in work in progress for one production run.
create or replace function private.job_wip(p_job uuid) returns numeric
language sql stable security definer set search_path = public, private as $$
  select coalesce(sum(jl.debit - jl.credit), 0)
  from public.journals j join public.journal_lines jl on jl.journal_id = j.id
  where j.source_type = 'production' and j.source_id = p_job and jl.account_code = private.acct(j.org_id, 'wip')
$$;

create or replace function private.job_noun(p_kind text) returns text
language sql immutable set search_path = '' as $$
  select case when p_kind = 'production' then 'production run' else 'job' end
$$;

-- ---------------------------------------------------------------------------
-- 4. Create or edit a production run or job
-- ---------------------------------------------------------------------------
create or replace function public.save_job(p_org uuid, p_job jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; j public.jobs; v_id uuid := nullif(p_job->>'id', '')::uuid; v_kind text; v_item public.items;
  v_acct text; v_allowed text; v_loc uuid; v_planned numeric; v_used boolean;
begin
  m := private.require(p_org, 'issue_stock');
  if v_id is not null then
    select * into j from jobs where id = v_id and org_id = p_org for update;
    if not found then raise exception 'Job not found.'; end if;
    if j.status <> 'open' then raise exception 'This % is closed.', private.job_noun(j.kind); end if;
  elsif nullif(p_job->>'client_uuid', '') is not null then
    select * into j from jobs where client_uuid = (p_job->>'client_uuid')::uuid and org_id = p_org;
    if found then return jsonb_build_object('id', j.id, 'ref', j.ref, 'duplicate', true); end if;
  end if;
  v_kind := coalesce(j.kind, nullif(p_job->>'kind', ''), 'job');
  if v_kind not in ('production', 'job') then raise exception 'Choose a production run or a job.'; end if;
  if coalesce(trim(coalesce(p_job->>'name', j.name)), '') = '' then raise exception 'Give it a name.'; end if;
  v_loc := coalesce(nullif(p_job->>'location_id', '')::uuid, j.location_id, m.location_id,
    (select id from locations where org_id = p_org order by is_main desc, created_at limit 1));
  if not exists (select 1 from locations where id = v_loc and org_id = p_org) then raise exception 'Choose a branch.'; end if;
  v_used := j.id is not null and exists (select 1 from movements where job_id = j.id);
  if v_used and v_loc <> j.location_id then raise exception 'Stock was already issued from this branch, so the branch cannot change.'; end if;

  if v_kind = 'production' then
    select * into v_item from items where org_id = p_org and not archived
      and id = coalesce(nullif(p_job->>'output_item_id', '')::uuid, j.output_item_id);
    if not found then raise exception 'Choose the item this run makes.'; end if;
    v_planned := coalesce(private.num(p_job->>'planned_qty'), j.planned_qty);
    if coalesce(v_planned, 0) <= 0 then raise exception 'Enter how many % this run should make.', v_item.selling_unit; end if;
  else
    select allowed into v_allowed from posting_roles where role = 'job_materials';
    v_acct := coalesce(nullif(p_job->>'charge_account', ''), j.charge_account, private.acct(p_org, 'job_materials'));
    if v_acct !~ v_allowed then raise exception 'Account % cannot be charged with job materials.', v_acct; end if;
    if v_used and v_acct <> j.charge_account then raise exception 'Stock was already charged to %, so the account cannot change now.', j.charge_account; end if;
  end if;

  if j.id is null then
    insert into jobs (org_id, ref, kind, name, location_id, output_item_id, planned_qty, charge_account, customer, notes, due_date, client_uuid, created_by)
    values (p_org,
      case when v_kind = 'production' then 'RUN-' else 'JOB-' end
        || lpad(private.next_no(p_org, case when v_kind = 'production' then 'RUN' else 'JOB' end, 1)::text, 4, '0'),
      v_kind, left(trim(p_job->>'name'), 120), v_loc, v_item.id, v_planned, v_acct, nullif(left(trim(p_job->>'customer'), 120), ''),
      nullif(left(trim(p_job->>'notes'), 1000), ''), private.date_or_null(p_job->>'due_date'), nullif(p_job->>'client_uuid', '')::uuid, m.id)
    returning * into j;
  else
    update jobs set
      name = left(trim(coalesce(p_job->>'name', name)), 120),
      location_id = v_loc,
      output_item_id = coalesce(v_item.id, output_item_id),
      planned_qty = coalesce(v_planned, planned_qty),
      charge_account = coalesce(v_acct, charge_account),
      customer = case when p_job ? 'customer' then nullif(left(trim(p_job->>'customer'), 120), '') else customer end,
      notes = case when p_job ? 'notes' then nullif(left(trim(p_job->>'notes'), 1000), '') else notes end,
      due_date = case when p_job ? 'due_date' then private.date_or_null(p_job->>'due_date') else due_date end
    where id = j.id returning * into j;
  end if;
  return jsonb_build_object('id', j.id, 'ref', j.ref);
end $$;

-- ---------------------------------------------------------------------------
-- 5. Issue stock to a run or job, or return what was not used
-- ---------------------------------------------------------------------------
-- p_lines: [{item_id, qty (selling units), note}]. Issues leave at weighted average cost, first expiry first.
-- Returns come back at the average cost they left at, so the run or job is credited exactly.
create or replace function public.issue_materials(p_job uuid, p_lines jsonb, p_return boolean default false,
  p_client_uuid uuid default null, p_device text default null, p_offline boolean default false, p_recorded_at timestamptz default null)
returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare jb public.jobs; m public.members; x jsonb; op jsonb; it public.items; v_qty numeric; v_wac numeric; v_uc numeric; v_val numeric;
  v_net numeric; v_netv numeric; v_on numeric; v_jl jsonb := '[]'::jsonb; v_ops jsonb := '[]'::jsonb; v_warn jsonb := '[]'::jsonb;
  j public.journals; v_at timestamptz := coalesce(p_recorded_at, now()); v_total numeric := 0; v_dest text; v_alloc jsonb;
  v_batch uuid; v_first boolean := true; v_seen uuid[] := '{}';
begin
  select * into jb from jobs where id = p_job for update;
  if not found then raise exception 'Job not found.'; end if;
  m := private.require(jb.org_id, 'issue_stock');
  if p_client_uuid is not null and exists (select 1 from movements where client_uuid = p_client_uuid) then
    return jsonb_build_object('duplicate', true, 'ref', jb.ref);
  end if;
  if jb.status <> 'open' then raise exception '% is closed, so stock can no longer go to it or come back from it.', jb.ref; end if;
  if v_at > now() + interval '5 minutes' then v_at := now(); end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Add at least one item.'; end if;
  v_dest := case when jb.kind = 'production' then private.acct(jb.org_id, 'wip') else jb.charge_account end;

  for x in select * from jsonb_array_elements(p_lines) loop
    v_qty := private.num(x->>'qty');
    if v_qty is null or v_qty <= 0 then raise exception 'Enter a quantity above zero on every line.'; end if;
    select * into it from items where id = nullif(x->>'item_id', '')::uuid and org_id = jb.org_id;
    if not found then raise exception 'Item not found.'; end if;
    if it.id = any(v_seen) then raise exception '% is on the list twice. Put it on one line.', it.name; end if;
    v_seen := v_seen || it.id;
    if jb.kind = 'production' and it.id = jb.output_item_id then
      raise exception '% is what this run makes, so it cannot also go into it.', it.name;
    end if;
    if not p_return then
      select wac into v_wac from item_costs where item_id = it.id;
      v_uc := coalesce(v_wac, 0);
      v_val := round(v_qty * v_uc, 2);
      select qty into v_on from stock_levels where item_id = it.id and location_id = jb.location_id;
      if coalesce(v_on, 0) < v_qty then
        v_warn := v_warn || jsonb_build_object('item', it.name, 'on_hand', coalesce(v_on, 0), 'qty', v_qty, 'unit', it.selling_unit);
      end if;
      v_jl := v_jl || jsonb_build_array(
        jsonb_build_object('code', v_dest, 'debit', v_val, 'location_id', jb.location_id, 'item_id', it.id, 'memo', jb.ref || ' · ' || it.name),
        jsonb_build_object('code', private.inv_acct(it.id), 'credit', v_val, 'location_id', jb.location_id, 'item_id', it.id, 'memo', jb.ref || ' · ' || it.name));
    else
      select coalesce(sum(-qty), 0), coalesce(sum(-value), 0) into v_net, v_netv
      from movements where job_id = jb.id and item_id = it.id and type in ('issue', 'issue_return');
      if v_net <= 0 then raise exception 'No % went to %, so there is nothing to return.', it.name, jb.ref; end if;
      if v_qty > v_net + 0.0005 then
        raise exception 'Only % % of % went to %.', private.fmt_qty(v_net), it.selling_unit, it.name, jb.ref;
      end if;
      v_uc := round(v_netv / v_net, 4);
      v_val := case when abs(v_qty - v_net) < 0.0005 then round(v_netv, 2) else round(v_qty * v_uc, 2) end;
      v_jl := v_jl || jsonb_build_array(
        jsonb_build_object('code', private.inv_acct(it.id), 'debit', v_val, 'location_id', jb.location_id, 'item_id', it.id, 'memo', jb.ref || ' · ' || it.name || ' returned'),
        jsonb_build_object('code', v_dest, 'credit', v_val, 'location_id', jb.location_id, 'item_id', it.id, 'memo', jb.ref || ' · ' || it.name || ' returned'));
    end if;
    v_total := v_total + v_val;
    v_ops := v_ops || jsonb_build_object('item_id', it.id, 'qty', v_qty, 'uc', v_uc, 'val', v_val, 'note', nullif(trim(x->>'note'), ''));
  end loop;

  j := private.post_journal(jb.org_id,
    case when p_return then 'Returned from ' else 'Issued to ' end || jb.ref || ' · ' || jb.name,
    case when jb.kind = 'production' then 'production' else 'job' end, jb.id, m.id, null, v_jl, v_at);

  for op in select * from jsonb_array_elements(v_ops) loop
    v_batch := null;
    if not p_return then
      v_alloc := private.consume_batches((op->>'item_id')::uuid, jb.location_id, (op->>'qty')::numeric, private.local_day(jb.org_id, v_at));
      v_batch := (v_alloc->0->>'batch_id')::uuid;
    else
      perform private.update_wac((op->>'item_id')::uuid, (op->>'qty')::numeric, (op->>'val')::numeric);
      select id into v_batch from batches where item_id = (op->>'item_id')::uuid and location_id = jb.location_id and not quarantined
        order by expiry_date desc nulls first, created_at desc limit 1;
      if v_batch is not null then update batches set qty_remaining = qty_remaining + (op->>'qty')::numeric where id = v_batch; end if;
    end if;
    perform private.add_movement(jb.org_id, case when p_return then 'issue_return' else 'issue' end, (op->>'item_id')::uuid, jb.location_id,
      case when p_return then (op->>'qty')::numeric else -(op->>'qty')::numeric end, (op->>'uc')::numeric, null, j.id, m.id,
      case when p_device is not null then 'Phone app' else 'App' end, v_at,
      jsonb_build_object('job_id', jb.id, 'note', op->>'note', 'batch_id', v_batch, 'device_id', p_device, 'offline', p_offline,
        'client_uuid', case when v_first then p_client_uuid end));
    v_first := false;
  end loop;

  return jsonb_build_object('ref', jb.ref, 'journal_ref', j.ref, 'lines', jsonb_array_length(v_ops), 'warnings', v_warn,
    'value', case when private.perm_of(m, 'see_margins') or private.perm_of(m, 'edit_prices') then v_total end);
end $$;

-- ---------------------------------------------------------------------------
-- 6. Record a production run's output and close it
-- ---------------------------------------------------------------------------
-- p_extra: {costs: [{label, amount}], batch_no, expiry_date, note}. Costs are labour, power and the like that the
-- run absorbs into the cost of its output (Dr WIP / Cr the production-absorbed role).
create or replace function public.complete_production(p_job uuid, p_qty numeric, p_extra jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare jb public.jobs; m public.members; it public.items; c jsonb; v_amt numeric; v_costs numeric := 0; v_jl jsonb := '[]'::jsonb;
  v_wip_acct text; v_absorb text; v_wip numeric; v_total numeric; v_uc numeric; j public.journals; v_old numeric; v_new numeric;
  v_batch uuid; v_expiry date;
begin
  select * into jb from jobs where id = p_job for update;
  if not found then raise exception 'Production run not found.'; end if;
  m := private.require(jb.org_id, 'approve_adjustments');
  if jb.kind <> 'production' then raise exception 'Only a production run records output. Close a job instead.'; end if;
  if jb.status <> 'open' then raise exception '% is already closed.', jb.ref; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Enter how much the run made.'; end if;
  select * into it from items where id = jb.output_item_id;
  if not found then raise exception 'The item this run makes no longer exists.'; end if;
  v_wip_acct := private.acct(jb.org_id, 'wip');
  v_absorb := private.acct(jb.org_id, 'production_absorbed');
  for c in select * from jsonb_array_elements(coalesce(p_extra->'costs', '[]'::jsonb)) loop
    v_amt := round(coalesce(private.num(c->>'amount'), 0), 2);
    if v_amt < 0 then raise exception 'Costs cannot be negative.'; end if;
    if v_amt > 0 then
      v_costs := v_costs + v_amt;
      v_jl := v_jl || jsonb_build_array(
        jsonb_build_object('code', v_wip_acct, 'debit', v_amt, 'location_id', jb.location_id,
          'memo', jb.ref || ' · ' || coalesce(nullif(left(trim(c->>'label'), 60), ''), 'Other costs')),
        jsonb_build_object('code', v_absorb, 'credit', v_amt, 'location_id', jb.location_id,
          'memo', jb.ref || ' · ' || coalesce(nullif(left(trim(c->>'label'), 60), ''), 'Other costs')));
    end if;
  end loop;
  v_wip := private.job_wip(jb.id);
  v_total := round(v_wip + v_costs, 2);
  if v_total <= 0 then
    raise exception 'Nothing has gone into % yet. Issue its materials first, or add the labour and other costs.', jb.ref;
  end if;
  v_uc := round(v_total / p_qty, 4);
  v_jl := v_jl || jsonb_build_array(
    jsonb_build_object('code', private.inv_acct(it.id), 'debit', v_total, 'location_id', jb.location_id, 'item_id', it.id, 'memo', jb.ref || ' · output'),
    jsonb_build_object('code', v_wip_acct, 'credit', v_total, 'location_id', jb.location_id, 'item_id', it.id, 'memo', jb.ref || ' · output'));
  j := private.post_journal(jb.org_id, 'Output of ' || jb.ref || ' · ' || private.fmt_qty(p_qty) || ' × ' || it.name,
    'production', jb.id, m.id, m.id, v_jl, now());

  select wac into v_old from item_costs where item_id = it.id;
  v_new := private.update_wac(it.id, p_qty, v_total);
  update item_costs set last_cost = v_uc, updated_at = now() where item_id = it.id;

  v_expiry := private.date_or_null(p_extra->>'expiry_date');
  if it.track_batches or nullif(trim(p_extra->>'batch_no'), '') is not null or v_expiry is not null then
    insert into batches (org_id, item_id, location_id, batch_no, expiry_date, qty_received, qty_remaining)
    values (jb.org_id, it.id, jb.location_id, coalesce(nullif(left(trim(p_extra->>'batch_no'), 40), ''), jb.ref), v_expiry, p_qty, p_qty)
    returning id into v_batch;
  end if;
  perform private.add_movement(jb.org_id, 'production_in', it.id, jb.location_id, p_qty, v_uc, null, j.id, m.id, 'App', now(),
    jsonb_build_object('job_id', jb.id, 'batch_id', v_batch, 'note', nullif(trim(p_extra->>'note'), '')));
  update jobs set status = 'completed', produced_qty = p_qty, output_unit_cost = v_uc, closed_by = m.id, closed_at = now()
  where id = jb.id;
  if coalesce(v_old, 0) > 0 and v_uc > v_old * 1.01 and private.sells(it.item_type) then
    perform private.propose_price(it.id, 'cost_increase', v_old, v_uc, jb.ref);
  end if;
  return jsonb_build_object('ref', jb.ref, 'journal_ref', j.ref, 'unit_cost', v_uc, 'total', v_total, 'materials', v_wip,
    'other_costs', v_costs, 'wac', v_new, 'qty', p_qty);
end $$;

-- ---------------------------------------------------------------------------
-- 7. Close or cancel
-- ---------------------------------------------------------------------------
-- A job closes with nothing to post, since its stock was charged when issued. Cancelling a production run writes off
-- whatever is still in work in progress, so return unused materials first.
create or replace function public.close_job(p_job uuid, p_cancel boolean default false, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare jb public.jobs; m public.members; v_wip numeric := 0; j public.journals;
begin
  select * into jb from jobs where id = p_job for update;
  if not found then raise exception 'Job not found.'; end if;
  if jb.status <> 'open' then raise exception '% is already closed.', jb.ref; end if;
  if jb.kind = 'production' then
    if not p_cancel then raise exception 'Record the output to finish a production run, or cancel it.'; end if;
    m := private.require(jb.org_id, 'approve_adjustments');
    v_wip := private.job_wip(jb.id);
    if v_wip <> 0 then
      j := private.post_journal(jb.org_id, 'Cancelled ' || jb.ref || ' · materials not returned written off', 'production', jb.id, m.id, m.id,
        private.reclass_pair(private.acct(jb.org_id, 'stock_loss'), private.acct(jb.org_id, 'wip'), v_wip, jb.location_id, null), now());
    end if;
  else
    m := private.require(jb.org_id, 'issue_stock');
  end if;
  update jobs set status = case when p_cancel then 'cancelled' else 'completed' end, closed_by = m.id, closed_at = now(),
    notes = case when nullif(trim(p_note), '') is null then notes else concat_ws(E'\n', notes, trim(p_note)) end
  where id = jb.id;
  return jsonb_build_object('ref', jb.ref, 'written_off', v_wip, 'journal_ref', j.ref);
end $$;

-- ---------------------------------------------------------------------------
-- 8. Recipes
-- ---------------------------------------------------------------------------
-- p_lines: [{item_id, qty, wastage_pct}] per batch of p_yield output units. An empty list deletes the recipe.
create or replace function public.save_recipe(p_org uuid, p_item uuid, p_yield numeric, p_lines jsonb, p_notes text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; it public.items; x jsonb; c public.items; v_lines jsonb := '[]'::jsonb; v_seen uuid[] := '{}'; v_q numeric; v_w numeric;
begin
  m := private.require(p_org, 'edit_prices');
  select * into it from items where id = p_item and org_id = p_org;
  if not found then raise exception 'Item not found.'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    delete from recipes where output_item_id = p_item;
    return jsonb_build_object('deleted', true);
  end if;
  if coalesce(p_yield, 0) <= 0 then raise exception 'Enter how many % one batch makes.', it.selling_unit; end if;
  for x in select * from jsonb_array_elements(p_lines) loop
    select * into c from items where id = nullif(x->>'item_id', '')::uuid and org_id = p_org;
    if not found then raise exception 'A recipe line points to an item that does not exist.'; end if;
    if c.id = p_item then raise exception 'An item cannot go into its own recipe.'; end if;
    if c.id = any(v_seen) then raise exception '% is in the recipe twice.', c.name; end if;
    v_seen := v_seen || c.id;
    v_q := private.num(x->>'qty'); v_w := coalesce(private.num(x->>'wastage_pct'), 0);
    if coalesce(v_q, 0) <= 0 then raise exception 'Enter how much % goes into a batch.', c.name; end if;
    if v_w < 0 or v_w >= 100 then raise exception 'Wastage for % must be between 0 and 99%%.', c.name; end if;
    v_lines := v_lines || jsonb_build_object('item_id', c.id, 'qty', v_q, 'wastage_pct', v_w);
  end loop;
  insert into recipes (output_item_id, org_id, yield_qty, lines, notes, updated_by, updated_at)
  values (p_item, p_org, p_yield, v_lines, nullif(trim(p_notes), ''), m.id, now())
  on conflict (output_item_id) do update set yield_qty = excluded.yield_qty, lines = excluded.lines, notes = excluded.notes,
    updated_by = excluded.updated_by, updated_at = now();
  return jsonb_build_object('item_id', p_item, 'lines', jsonb_array_length(v_lines));
end $$;

-- ---------------------------------------------------------------------------
-- 9. Read: runs and jobs with what went into them
-- ---------------------------------------------------------------------------
create or replace function public.get_jobs(p_org uuid, p_closed_days int default 60) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_cost boolean;
begin
  m := private.require(p_org, null);
  v_cost := private.perm_of(m, 'see_margins') or private.perm_of(m, 'edit_prices');
  return jsonb_build_object(
    'jobs', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', jb.id, 'ref', jb.ref, 'kind', jb.kind, 'name', jb.name, 'location_id', jb.location_id, 'status', jb.status,
        'output_item_id', jb.output_item_id, 'planned_qty', jb.planned_qty, 'produced_qty', jb.produced_qty,
        'output_unit_cost', case when v_cost then jb.output_unit_cost end,
        'charge_account', jb.charge_account, 'charge_account_name', (select name from accounts where code = jb.charge_account),
        'customer', jb.customer, 'notes', jb.notes, 'due_date', jb.due_date, 'created_at', jb.created_at, 'closed_at', jb.closed_at,
        'created_by_name', (select display_name from members where id = jb.created_by),
        'closed_by_name', (select display_name from members where id = jb.closed_by),
        'materials', coalesce((
          select jsonb_agg(jsonb_build_object('item_id', t.item_id, 'issued', t.issued, 'returned', t.returned, 'net', t.issued - t.returned,
              'value', case when v_cost then t.v end, 'last_at', t.last_at) order by t.last_at desc)
          from (select mv.item_id, sum(-mv.qty) filter (where mv.type = 'issue') issued,
                  coalesce(sum(mv.qty) filter (where mv.type = 'issue_return'), 0) returned,
                  sum(-mv.value) filter (where mv.type in ('issue', 'issue_return')) v, max(mv.recorded_at) last_at
                from movements mv where mv.job_id = jb.id and mv.type in ('issue', 'issue_return') group by mv.item_id) t), '[]'::jsonb),
        'materials_value', case when v_cost then (select coalesce(sum(-value), 0) from movements where job_id = jb.id and type in ('issue', 'issue_return')) end,
        'other_costs', case when v_cost then (
          select coalesce(sum(jl.debit), 0) from journals j join journal_lines jl on jl.journal_id = j.id
          where j.source_type = 'production' and j.source_id = jb.id and jl.account_code = private.acct(p_org, 'wip') and jl.item_id is null) end,
        'wip', case when v_cost and jb.kind = 'production' then private.job_wip(jb.id) end,
        'last_at', coalesce((select max(recorded_at) from movements where job_id = jb.id), jb.created_at)
      ) order by (jb.status = 'open') desc, jb.created_at desc)
      from jobs jb
      where jb.org_id = p_org and (jb.status = 'open' or jb.closed_at > now() - make_interval(days => greatest(p_closed_days, 1)))), '[]'::jsonb),
    'recipes', coalesce((
      select jsonb_agg(jsonb_build_object('item_id', r.output_item_id, 'yield_qty', r.yield_qty, 'lines', r.lines, 'notes', r.notes,
        'updated_at', r.updated_at))
      from recipes r where r.org_id = p_org), '[]'::jsonb),
    'accounts', (
      select jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name) order by a.code)
      from accounts a, posting_roles pr where pr.role = 'job_materials' and a.code ~ pr.allowed and a.active and not a.is_group),
    'default_account', private.acct(p_org, 'job_materials'));
end $$;
