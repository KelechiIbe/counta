-- Counta · Release 5: earlier years and assets from the bank
--
-- 1. A bank or wallet line whose money ends up in a fixed asset account opens a register record waiting for confirmation,
--    as a bill's asset line does; money in that ends up there waits to be matched to the asset sold. Confirmation can take
--    an old asset in part exchange; a waiting record can join another asset (an instalment, import duty, installation); an
--    asset a director paid for is owed to the director. The bookkeeper is told the business's trade, its capitalisation
--    threshold and its assets in use.
-- 2. Personal income tax from 2024 accounts. A filing-only business's year says where it starts: the year before approved
--    when it is done in Counta, or last year's figures, or the owner's word that there was nothing but the bank balances
--    (or that last year's figures do not exist), which the statements then say. Late returns are marked.
-- 3. The PITA rule book (version 1.2.0) covers 2024 accounts, as TaxStreem confirmed on 14 November 2026.
-- 4. Payments already posted to asset accounts in months not closed get their register records.
-- Safe to run more than once.

-- ---------------------------------------------------------------------------
-- 1. Assets from bank lines
-- ---------------------------------------------------------------------------
-- A bank or wallet line whose money ends up in a fixed asset account (by the bookkeeper, a rule, or a person answering
-- a question or correcting the account) is a purchase the register must hear about: it opens a register record waiting
-- for confirmation, as a bill's asset line does. Money in that ends up there is the sale of an asset, waiting to be
-- matched to the asset sold. The bank line's own journals decide, so a correction moves or withdraws what it opened.
alter table public.fixed_assets add column if not exists bank_line_id uuid references public.bank_lines(id) on delete set null;
-- The asset account the bank line put the cost in, which a change of class on confirmation leaves as it was.
alter table public.fixed_assets add column if not exists line_class text references public.asset_classes(cost_account);
-- A waiting record that turned out to be part of another asset (a second instalment, import duty, installation).
alter table public.fixed_assets add column if not exists merged_into uuid references public.fixed_assets(id) on delete set null;
create index if not exists fixed_assets_bank_line_fk on public.fixed_assets(bank_line_id) where bank_line_id is not null;
create index if not exists fixed_assets_line_class_fk on public.fixed_assets(line_class) where line_class is not null;
create index if not exists fixed_assets_merged_into_fk on public.fixed_assets(merged_into) where merged_into is not null;

create table if not exists public.asset_sales (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  bank_line_id uuid not null references public.bank_lines(id) on delete cascade,
  class_account text not null references public.asset_classes(cost_account),
  amount numeric(16,2) not null check (amount > 0),
  status text not null default 'pending' check (status in ('pending', 'matched', 'dismissed')),
  asset_id uuid references public.fixed_assets(id) on delete set null,
  journal_id uuid references public.journals(id) on delete set null,
  decided_by uuid references public.members(id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  unique (bank_line_id, class_account)
);
create index if not exists asset_sales_org on public.asset_sales(org_id, status);
create index if not exists asset_sales_class_fk on public.asset_sales(class_account);
create index if not exists asset_sales_asset_fk on public.asset_sales(asset_id) where asset_id is not null;
create index if not exists asset_sales_journal_fk on public.asset_sales(journal_id) where journal_id is not null;
create index if not exists asset_sales_decided_by_fk on public.asset_sales(decided_by) where decided_by is not null;
alter table public.asset_sales enable row level security;
drop policy if exists asset_sales_read on public.asset_sales;
create policy asset_sales_read on public.asset_sales for select to authenticated
  using ((select private.can_handle_money(org_id)) or (select private.has_perm(org_id, 'approve_pos')));
revoke insert, update, delete on public.asset_sales from anon, authenticated;

-- What a bank line's own journals (its posting, corrections out of suspense or to another account, and their reversals)
-- leave in each asset account, and the register records and sales that follow from it.
create or replace function private.bank_asset_sync(p_line uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare bl public.bank_lines; v_net jsonb; r record; a public.fixed_assets; s public.asset_sales; v_title text; v_n numeric;
begin
  select * into bl from bank_lines where id = p_line;
  if not found then return; end if;
  select coalesce(jsonb_object_agg(x.code, x.net), '{}'::jsonb) into v_net from (
    select l.account_code code, sum(l.debit - l.credit) net
    from journals j join journal_lines l on l.journal_id = j.id
    where j.org_id = bl.org_id and j.source_id = bl.id and j.source_type in ('bank', 'reclass')
      and l.account_code in (select cost_account from asset_classes)
    group by l.account_code) x;
  -- Named as the posting describes it (the bookkeeper's title), else as the bank does.
  v_title := coalesce(nullif(left(trim((select l.memo from journals j join journal_lines l on l.journal_id = j.id
                                        where j.org_id = bl.org_id and j.source_id = bl.id and j.source_type in ('bank', 'reclass') and l.debit > 0
                                          and l.account_code in (select cost_account from asset_classes)
                                        order by j.created_at desc, j.je_no desc limit 1)), 200), ''),
                      nullif(left(trim((select p.title from ai_proposals p where p.source_type = 'bank_line' and p.source_id = bl.id
                                        order by p.created_at desc limit 1)), 200), ''),
                      nullif(left(trim(bl.description), 200), ''), 'Bought on ' || to_char(bl.line_date, 'DD Mon YYYY'));

  -- Bought: one register record for each asset account the money is in.
  for r in select key code, value::numeric net from jsonb_each_text(v_net) where value::numeric > 0 order by key loop
    select * into a from fixed_assets where bank_line_id = bl.id and line_class = r.code order by created_at limit 1;
    if found then
      if a.status = 'pending_confirmation' and a.merged_into is null and a.cost <> r.net then
        update fixed_assets set cost = r.net where id = a.id;
      -- Withdrawn when the payment was moved away (never by a person), and now back.
      elsif a.status = 'rejected' and a.merged_into is null and a.confirmed_by is null then
        update fixed_assets set status = 'pending_confirmation', cost = r.net,
          notes = nullif(regexp_replace(coalesce(notes, ''), '( · )?The payment was moved to another account', '', 'g'), '') where id = a.id;
      end if;
      continue;
    end if;
    -- A waiting record whose account the line has left (or one withdrawn when the money left) moves with it.
    select * into a from fixed_assets f where f.bank_line_id = bl.id and f.merged_into is null
      and (f.status = 'pending_confirmation' or (f.status = 'rejected' and f.confirmed_by is null))
      and coalesce((v_net->>f.line_class)::numeric, 0) <= 0
    order by (f.status = 'pending_confirmation') desc, f.created_at limit 1 for update;
    if found then
      update fixed_assets set class_account = r.code, line_class = r.code, cost = r.net, status = 'pending_confirmation',
        life_months = (select default_life_months from asset_classes where cost_account = r.code),
        notes = nullif(regexp_replace(coalesce(notes, ''), '( · )?The payment was moved to another account', '', 'g'), '') where id = a.id;
    else
      insert into fixed_assets (org_id, number, name, class_account, line_class, cost, life_months, available_date, status, bank_line_id, journal_id)
      values (bl.org_id, 'FA-' || lpad(private.next_no(bl.org_id, 'FA', 1)::text, 4, '0'), v_title, r.code, r.code, r.net,
        (select default_life_months from asset_classes where cost_account = r.code), bl.line_date, 'pending_confirmation', bl.id,
        (select j.id from journals j where j.org_id = bl.org_id and j.source_id = bl.id and j.source_type in ('bank', 'reclass') order by j.created_at desc limit 1));
    end if;
  end loop;
  -- Money taken back out of an asset account: a waiting record goes; one already in the register cannot.
  for a in select * from fixed_assets where bank_line_id = bl.id and coalesce((v_net->>line_class)::numeric, 0) <= 0 for update loop
    if a.status = 'pending_confirmation' and a.merged_into is null then
      update fixed_assets set status = 'rejected', notes = concat_ws(' · ', notes, 'The payment was moved to another account') where id = a.id;
    elsif a.status in ('active', 'disposed') or a.merged_into is not null then
      raise exception '% in the asset register comes from this payment. Treat it as an expense or dispose of it under Fixed assets first.',
        coalesce((select number from fixed_assets where id = a.merged_into), a.number);
    end if;
  end loop;

  -- Sold: money in to an asset account waits to be matched to the asset sold.
  for r in select key code, -(value::numeric) amt from jsonb_each_text(v_net) where value::numeric < 0 order by key loop
    select * into s from asset_sales where bank_line_id = bl.id and class_account = r.code;
    if found then
      if s.status = 'pending' and s.amount <> r.amt then update asset_sales set amount = r.amt where id = s.id; end if;
      if s.status = 'dismissed' then update asset_sales set status = 'pending', amount = r.amt, decided_by = null, decided_at = null where id = s.id; end if;
      continue;
    end if;
    select * into s from asset_sales x where x.bank_line_id = bl.id and x.status = 'pending' and coalesce((v_net->>x.class_account)::numeric, 0) >= 0 limit 1 for update;
    if found then
      update asset_sales set class_account = r.code, amount = r.amt where id = s.id;
    else
      insert into asset_sales (org_id, bank_line_id, class_account, amount) values (bl.org_id, bl.id, r.code, r.amt);
    end if;
  end loop;
  for s in select * from asset_sales where bank_line_id = bl.id and coalesce((v_net->>class_account)::numeric, 0) >= 0 and status <> 'dismissed' for update loop
    if s.status = 'matched' then
      raise exception 'This money was matched to the sale of % under Fixed assets, so it stays where it is.',
        coalesce((select number from fixed_assets where id = s.asset_id), 'an asset');
    end if;
    update asset_sales set status = 'dismissed' where id = s.id;
  end loop;
end $$;

-- After each insert of journal lines (one statement per journal), the bank lines whose journals touched an asset account
-- are brought up to date. Seeing a journal's lines together lets a correction from one asset account to another move the
-- waiting record instead of closing one and opening another.
create or replace function private.journal_lines_asset_watch() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_src uuid;
begin
  for v_src in
    select distinct j.source_id from new_lines l join journals j on j.id = l.journal_id
    where l.account_code between '1501' and '1527' and j.source_type in ('bank', 'reclass') and j.source_id is not null
  loop
    if exists (select 1 from bank_lines where id = v_src) then perform private.bank_asset_sync(v_src); end if;
  end loop;
  return null;
end $$;
drop trigger if exists journal_lines_assets on public.journal_lines;
create trigger journal_lines_assets after insert on public.journal_lines referencing new table as new_lines
  for each statement execute function private.journal_lines_asset_watch();

-- Disposing of an asset: depreciation to the day, then cost and depreciation out, the proceeds where they went (the bank,
-- what the buyer owes, the asset account a bank line already credited, or the cost of the asset taken in exchange), and the
-- gain or loss. Shared by Dispose, matching a sale on the bank, and part exchange.
create or replace function private.dispose_core(p_asset uuid, p_day date, p_proceeds numeric, p_debit_code text, p_party_type text, p_party uuid,
  p_reason text, m public.members) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare a public.fixed_assets; ac public.asset_classes; v_proceeds numeric := round(coalesce(p_proceeds, 0), 2); v_charge numeric; v_acc numeric; v_carry numeric;
  v_jl jsonb; j public.journals; v_at timestamptz; v_gain numeric;
begin
  select * into a from fixed_assets where id = p_asset for update;
  if not found then raise exception 'Asset not found.'; end if;
  if a.status <> 'active' then raise exception '% is %.', a.number, replace(a.status, '_', ' '); end if;
  select * into ac from asset_classes where cost_account = a.class_account;
  perform private.require_open_day(a.org_id, p_day);
  if v_proceeds < 0 then raise exception 'Proceeds cannot be negative.'; end if;
  v_at := (p_day::timestamp + interval '12 hours') at time zone coalesce((select timezone from orgs where id = a.org_id), 'Africa/Lagos');
  -- Depreciation for the part of the month before disposal, if the month has not been run.
  if ac.depreciates then
    v_charge := round(private.asset_expected(a, p_day) - private.asset_accumulated(a.id), 2);
    if v_charge > 0 then
      perform private.post_entry(a.org_id, 'Depreciation to disposal · ' || a.number, 'depreciation', a.id, m.id, m.id, jsonb_build_array(
        jsonb_build_object('code', ac.expense_account, 'debit', v_charge, 'location_id', a.location_id, 'memo', a.number),
        jsonb_build_object('code', ac.accum_account, 'credit', v_charge, 'location_id', a.location_id, 'party_type', 'asset', 'party_id', a.id, 'memo', a.number)), v_at);
    end if;
  end if;
  v_acc := coalesce(private.asset_accumulated(a.id), 0);
  v_carry := a.cost - v_acc;
  v_gain := v_proceeds - v_carry;
  v_jl := jsonb_build_array(
    jsonb_build_object('code', ac.cost_account, 'credit', a.cost, 'location_id', a.location_id, 'memo', 'Cost of ' || a.number),
    jsonb_build_object('code', coalesce(ac.accum_account, ac.cost_account), 'debit', case when ac.accum_account is null then 0 else v_acc - a.opening_accumulated end,
      'party_type', 'asset', 'party_id', a.id, 'memo', 'Depreciation on ' || a.number),
    jsonb_build_object('code', coalesce(ac.accum_account, ac.cost_account), 'debit', case when ac.accum_account is null then 0 else a.opening_accumulated end,
      'memo', 'Opening depreciation on ' || a.number),
    jsonb_build_object('code', p_debit_code, 'debit', v_proceeds, 'party_type', p_party_type, 'party_id', p_party, 'memo', 'Proceeds from ' || a.number),
    jsonb_build_object('code', '4508', 'credit', greatest(v_gain, 0), 'memo', 'Gain on ' || a.number),
    jsonb_build_object('code', '6804', 'debit', greatest(-v_gain, 0), 'memo', 'Loss on ' || a.number));
  j := private.post_entry(a.org_id, 'Disposal of ' || a.number || ' · ' || a.name || coalesce(' · ' || nullif(trim(p_reason), ''), ''), 'asset_disposal', a.id, m.id, m.id, v_jl, v_at);
  update fixed_assets set status = 'disposed', disposed_at = p_day, proceeds = v_proceeds, disposal_journal_id = j.id,
    notes = concat_ws(' · ', notes, nullif(trim(p_reason), '')) where id = a.id;
  return private.asset_json(a.id) || jsonb_build_object('gain', v_gain);
end $$;

-- Money in on the bank for an asset sold, matched to the asset. Depreciation runs to the day of the sale (the line's date
-- unless another is given); the gain or loss posts, and the money already in the asset account clears.
create or replace function public.match_asset_sale(p_sale uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.asset_sales; m public.members; bl public.bank_lines; a public.fixed_assets; v_day date; r jsonb;
begin
  select * into s from asset_sales where id = p_sale for update;
  if not found then raise exception 'Not found.'; end if;
  m := private.require(s.org_id, 'keep_books');
  if s.status <> 'pending' then raise exception 'This money was already %.', case s.status when 'matched' then 'matched to an asset' else 'moved to another account' end; end if;
  select * into a from fixed_assets where id = private.uuid_of(p->>'asset_id') and org_id = s.org_id;
  if not found then raise exception 'Choose the asset that was sold.'; end if;
  if a.status = 'pending_confirmation' then raise exception 'Confirm % in the register first, then match the sale.', a.number; end if;
  if a.status <> 'active' then raise exception '% is %.', a.number, replace(a.status, '_', ' '); end if;
  select * into bl from bank_lines where id = s.bank_line_id;
  v_day := coalesce(nullif(p->>'date', '')::date, bl.line_date);
  if v_day < coalesce(a.available_date, v_day) then raise exception '% was not yet in use on %.', a.number, private.fdate(v_day); end if;
  r := private.dispose_core(a.id, v_day, s.amount, s.class_account, null, null,
    coalesce(nullif(left(trim(p->>'reason'), 200), ''), 'Sold · ' || left(coalesce(bl.description, ''), 120)), m);
  update asset_sales set status = 'matched', asset_id = a.id, journal_id = (r->>'disposal_journal_id')::uuid, decided_by = m.id, decided_at = now()
  where id = s.id;
  return r;
end $$;

-- Not a sale after all: the money moves from the asset account to the account it belongs in.
create or replace function public.asset_sale_elsewhere(p_sale uuid, p_account text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.asset_sales; m public.members; bl public.bank_lines; j public.journals;
begin
  select * into s from asset_sales where id = p_sale for update;
  if not found then raise exception 'Not found.'; end if;
  m := private.require(s.org_id, 'keep_books');
  if s.status <> 'pending' then raise exception 'This money was already %.', case s.status when 'matched' then 'matched to an asset' else 'moved to another account' end; end if;
  if coalesce(p_account, '') = '' or not private.postable(s.org_id, p_account) then raise exception 'Choose the account this money belongs to.'; end if;
  if exists (select 1 from asset_classes where cost_account = p_account) then raise exception 'Choose an account other than a fixed asset account.'; end if;
  if p_account ~ '^(1101|1102|2101|2102|2201|1402|2202|1401|9)' or exists (select 1 from bank_accounts where org_id = s.org_id and ledger_code = p_account) then
    raise exception 'That account takes money only through its own documents.';
  end if;
  select * into bl from bank_lines where id = s.bank_line_id;
  j := private.post_entry(s.org_id, 'Corrected: ' || coalesce(bl.description, 'money in'), 'reclass', bl.id, m.id, m.id,
    private.reclass_pair(s.class_account, p_account, s.amount, null, null), private.line_time(s.org_id, bl.line_date),
    jsonb_build_object('origin', 'manual', 'evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id),
      jsonb_build_object('type', 'decision', 'by', m.display_name, 'note', nullif(trim(p_note), '')))));
  update asset_sales set decided_by = m.id, decided_at = now() where id = s.id;
  return jsonb_build_object('status', 'moved', 'journal_ref', j.ref);
end $$;

-- A waiting record that is part of another asset: a second instalment, import duty or installation. Its cost joins the
-- other asset (moved to that asset's account if it differs) and the record closes.
create or replace function public.merge_asset(p_asset uuid, p_into uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare a public.fixed_assets; b public.fixed_assets; m public.members;
begin
  select * into a from fixed_assets where id = p_asset for update;
  if not found then raise exception 'Asset not found.'; end if;
  m := private.require(a.org_id, 'keep_books');
  if a.status <> 'pending_confirmation' then raise exception 'Only an asset waiting for confirmation can join another.'; end if;
  select * into b from fixed_assets where id = p_into and org_id = a.org_id for update;
  if not found or b.id = a.id then raise exception 'Choose the asset this belongs to.'; end if;
  if b.status not in ('pending_confirmation', 'active') then raise exception '% is %.', b.number, replace(b.status, '_', ' '); end if;
  if b.class_account <> a.class_account then
    perform private.post_entry(a.org_id, a.number || ' joined ' || b.number || ' · ' || (select name from asset_classes where cost_account = b.class_account), 'asset', a.id,
      m.id, m.id, private.reclass_pair(b.class_account, a.class_account, a.cost, a.location_id, null), now());
  end if;
  update fixed_assets set cost = cost + a.cost, notes = concat_ws(' · ', notes, 'Includes ' || a.number || ' (' || private.naira(a.cost) || ')') where id = b.id;
  update fixed_assets set status = 'rejected', merged_into = b.id, confirmed_by = m.id, confirmed_at = now(),
    notes = concat_ws(' · ', notes, 'Part of ' || b.number) where id = a.id;
  return private.asset_json(b.id);
end $$;

-- What the bookkeeper is told about the business's trade, so it can tell stock from an asset: a car dealer's cars and a
-- phone shop's phones are stock; a haulier's truck and a consultancy's laptops are assets.
create or replace function private.ai_trade(p_org uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'category', (select c.label from business_categories c where c.id = o.category_id),
    'sells', o.offering,
    'activity', nullif(left(trim(o.principal_activity), 240), ''),
    'examples', (select k.answers->'examples' from kyc_profiles k where k.org_id = o.id and jsonb_typeof(k.answers->'examples') = 'array'
                 order by k.updated_at desc limit 1)))
  from orgs o where o.id = p_org
$$;

-- The assets in use, so money in from selling one can be told apart.
create or replace function private.ai_assets(p_org uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('number', x.number, 'name', x.name, 'class', x.class_account, 'class_name', x.class_name,
      'carrying', x.carrying) order by x.number), '[]'::jsonb)
  from (select a.number, a.name, a.class_account, ac.name class_name, a.cost - private.asset_accumulated(a.id) carrying
        from fixed_assets a join asset_classes ac on ac.cost_account = a.class_account
        where a.org_id = p_org and a.status = 'active' order by a.number limit 60) x
$$;

-- ---------------------------------------------------------------------------
-- 2. Earlier years: personal income tax from 2024 accounts, and where each year starts
-- ---------------------------------------------------------------------------
alter table public.filing_orders add column if not exists opening jsonb;
comment on column public.filing_orders.opening is 'Where the year starts when no earlier year in Counta gives it: {kind: figures|bank_only|no_figures, by, by_name, at, as_of, journal_id, assets, lines}';

-- The first year Counta prepares a PIT return for: 2024 accounts (year of assessment 2025), or the first year of the books
-- if later. 2024 and 2025 accounts use the PITA rule book; 2026 onwards the NTA.
create or replace function private.pit_first_year(p_org uuid) returns int
language sql stable security definer set search_path = public, private as $$
  select greatest(2024, private.cit_first_year(p_org))
$$;

-- The years a filing-only business can file: up to four accounting years that have ended, none before the first year
-- Counta prepares (2023 for CIT, 2024 for PIT) or before the business began; and any year it has an order for.
create or replace function private.filing_years(p_org uuid) returns integer[]
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; v_today date := private.local_day(p_org, now()); v_last int; v_first int; v_kind text; v_out int[];
begin
  select * into o from orgs where id = p_org;
  v_last := private.cit_year_of(p_org, v_today);
  if (select pto from private.cit_period(p_org, v_last)) >= v_today then v_last := v_last - 1; end if;
  v_kind := private.filing_kind(p_org, v_last);
  v_first := greatest(v_last - 3, case v_kind when 'pit' then 2024 else 2023 end,
    coalesce(private.cit_year_of(p_org, coalesce(o.incorporation_date, o.commenced_on)), 0));
  select array_agg(y order by y desc) into v_out from (
    select generate_series(v_first, v_last) y union select year from filing_orders where org_id = p_org) x;
  return coalesce(v_out, '{}');
end $$;

-- Where a filing-only business's year starts. The year before it, done in Counta, hands over its closing figures, so that
-- year is approved first. Otherwise the start comes from a business that began in the year, books moved in at the year
-- start, last year's figures entered on the Filing page, or the owner's word that there was nothing but the bank balances
-- (or that last year's figures do not exist), which the statements then say.
-- {as_of, needed, done, source: began|previous_year|moved|figures|bank_only|no_figures|null, previous_year, by_name, at, journal_ref, assets}
create or replace function private.filing_opening(p_org uuid, p_year int) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; v_from date := (private.cit_period(p_org, p_year)).pfrom; v_as_of date; f public.filing_orders; v_prev_paid boolean; v_prev_ok boolean;
begin
  select * into o from orgs where id = p_org;
  v_as_of := v_from - 1;
  if coalesce(o.incorporation_date, o.commenced_on) >= v_from then
    return jsonb_build_object('as_of', v_as_of, 'needed', false, 'done', true, 'source', 'began');
  end if;
  v_prev_paid := exists (select 1 from filing_orders where org_id = p_org and year = p_year - 1 and status = 'paid');
  v_prev_ok := exists (select 1 from cit_years where org_id = p_org and accounting_year = p_year - 1 and status = 'approved')
            or exists (select 1 from pit_years where org_id = p_org and accounting_year = p_year - 1 and status = 'approved');
  if v_prev_paid or v_prev_ok then
    return jsonb_build_object('as_of', v_as_of, 'needed', false, 'done', v_prev_ok, 'source', 'previous_year', 'previous_year', p_year - 1);
  end if;
  if exists (select 1 from books_migrations where org_id = p_org and status = 'posted' and as_of between v_as_of - 7 and v_as_of) then
    return jsonb_build_object('as_of', v_as_of, 'needed', false, 'done', true, 'source', 'moved');
  end if;
  select * into f from filing_orders where org_id = p_org and year = p_year;
  if f.opening is not null then
    return jsonb_build_object('as_of', v_as_of, 'needed', true, 'done', true, 'source', f.opening->>'kind', 'by_name', f.opening->>'by_name',
      'at', f.opening->'at', 'journal_ref', (select ref from journals where id = private.uuid_of(f.opening->>'journal_id')),
      'assets', coalesce(jsonb_array_length(f.opening->'assets'), 0), 'lines', f.opening->'lines',
      'asset_rows', (select coalesce(jsonb_agg(jsonb_build_object('class_account', a.class_account, 'name', a.name, 'cost', a.cost,
          'accumulated', a.opening_accumulated, 'in_use_from', a.available_date) order by a.number), '[]'::jsonb)
        from fixed_assets a where a.org_id = p_org and a.id in (select private.uuid_of(x) from jsonb_array_elements_text(coalesce(f.opening->'assets', '[]'::jsonb)) x)));
  end if;
  return jsonb_build_object('as_of', v_as_of, 'needed', true, 'done', false, 'source', null);
end $$;

-- The opening position of a filing-only business's year, when no earlier year in Counta gives it.
-- p: {kind: 'figures'|'bank_only'|'no_figures'|'clear',
--     lines: [{key, amount}] (key: inventory, trade_receivables, other_receivables, prepayments, director_receivable, investments,
--            trade_payables, accruals, other_payables, director_payable, tax_payable, loans_short, loans_long, shareholder_loans,
--            share_capital, share_premium, deposit_for_shares, retained_earnings (negative for accumulated losses)),
--     assets: [{class_account, name, cost, accumulated, in_use_from}]}
-- Figures post one journal on the day before the year starts; the bank balances come from the bank accounts themselves,
-- and what the figures leave over stays in equity as opening balances to be confirmed. Each asset joins the register with
-- the depreciation it already had. Figures entered before are taken back first, as long as no depreciation has run on them.
create or replace function public.filing_opening_save(p_org uuid, p_year int, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; st jsonb; f public.filing_orders; v_kind text := coalesce(p->>'kind', ''); v_from date; v_as_of date; v_kind_tax text;
  v_map jsonb := '{"inventory": "1203", "trade_receivables": "1101", "other_receivables": "1110", "prepayments": "1303", "director_receivable": "1105",
    "investments": "1711", "trade_payables": "2101", "accruals": "2103", "other_payables": "2104", "director_payable": "2106", "tax_payable": "2208",
    "loans_short": "2302", "loans_long": "2501", "shareholder_loans": "2502", "share_capital": "3001", "share_premium": "3003",
    "deposit_for_shares": "3004", "retained_earnings": "3005"}';
  v_debit text[] := array['inventory', 'trade_receivables', 'other_receivables', 'prepayments', 'director_receivable', 'investments'];
  x jsonb; v_key text; v_amt numeric; v_jl jsonb := '[]'::jsonb; v_dr numeric := 0; v_cr numeric := 0; v_lines jsonb := '[]'::jsonb; ac public.asset_classes;
  v_cost numeric; v_acc numeric; v_use date; v_name text; v_assets jsonb := '[]'::jsonb; j public.journals; v_ids uuid[] := '{}'; v_id uuid; v_open jsonb;
  v_at timestamptz;
begin
  m := private.require(p_org, 'keep_books');
  select * into o from orgs where id = p_org;
  if not coalesce(o.filing_only, false) then raise exception 'This business is not on filing-only.'; end if;
  if not (p_year = any (private.filing_years(p_org))) then raise exception 'Choose one of the years on the Filing page.'; end if;
  if v_kind not in ('figures', 'bank_only', 'no_figures', 'clear') then raise exception 'Say where % starts.', p_year; end if;
  st := private.filing_opening(p_org, p_year);
  if not (st->>'needed')::boolean then
    raise exception '% starts where %.', p_year, case st->>'source' when 'began' then 'the business began' when 'moved' then 'the books moved into Counta start'
      else (p_year - 1) || ' ends in Counta' end;
  end if;
  if exists (select 1 from cit_years where org_id = p_org and accounting_year = p_year and status = 'approved')
     or exists (select 1 from pit_years where org_id = p_org and accounting_year = p_year and status = 'approved') then
    raise exception 'The % return is approved. Reopen it to change where the year starts.', p_year;
  end if;
  v_kind_tax := private.filing_kind(p_org, p_year);
  if v_kind_tax is null then raise exception 'This business is exempt from income tax, so it has no return to file.'; end if;
  insert into filing_orders (org_id, year, kind, created_by) values (p_org, p_year, v_kind_tax, m.id) on conflict (org_id, year) do nothing;
  select * into f from filing_orders where org_id = p_org and year = p_year for update;
  v_from := (private.cit_period(p_org, p_year)).pfrom; v_as_of := v_from - 1;
  v_at := (v_as_of::timestamp + interval '12 hours') at time zone coalesce(o.timezone, 'Africa/Lagos');

  -- Figures entered before are taken back, with the assets they added.
  if f.opening->>'kind' = 'figures' then
    select coalesce(array_agg(value::uuid), '{}') into v_ids from jsonb_array_elements_text(coalesce(f.opening->'assets', '[]'::jsonb));
    if exists (select 1 from fixed_assets where id = any (v_ids) and status <> 'active')
       or exists (select 1 from journal_lines where org_id = p_org and party_type = 'asset' and party_id = any (v_ids)) then
      raise exception 'Depreciation or a disposal has been recorded on the assets entered for the start of %. Change them under Fixed assets instead.', p_year;
    end if;
    if private.uuid_of(f.opening->>'journal_id') is not null then
      perform private.reverse_entry(private.uuid_of(f.opening->>'journal_id'), m.id, 'Opening position for ' || p_year || ' replaced', null);
    end if;
    update fixed_assets set status = 'rejected', notes = concat_ws(' · ', notes, 'Opening position replaced') where id = any (v_ids);
  end if;

  if v_kind = 'clear' then
    v_open := null;
  elsif v_kind in ('bank_only', 'no_figures') then
    v_open := jsonb_build_object('kind', v_kind, 'by', m.id, 'by_name', m.display_name, 'at', now(), 'as_of', v_as_of);
  else
    for x in select value from jsonb_array_elements(case when jsonb_typeof(p->'lines') = 'array' then p->'lines' else '[]'::jsonb end) loop
      v_key := x->>'key';
      if not (v_map ? coalesce(v_key, '')) then raise exception 'Unknown line in the opening position: %.', coalesce(v_key, 'none'); end if;
      v_amt := round(private.num(x->>'amount'), 2);
      if v_amt is null then raise exception 'Enter an amount for each line, or leave the line out.'; end if;
      if v_amt < 0 and v_key <> 'retained_earnings' then raise exception 'Enter amounts without a minus sign. Only retained earnings can be below zero (accumulated losses).'; end if;
      continue when v_amt = 0;
      if exists (select 1 from jsonb_array_elements(v_lines) y where y->>'key' = v_key) then raise exception 'Each line once, please: % appears twice.', v_key; end if;
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('key', v_key, 'amount', v_amt));
      if v_key = any (v_debit) then
        v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', v_map->>v_key, 'debit', v_amt, 'memo', 'Opening balance'));
        v_dr := v_dr + v_amt;
      else
        v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', v_map->>v_key, 'debit', greatest(-v_amt, 0), 'credit', greatest(v_amt, 0), 'memo', 'Opening balance'));
        v_cr := v_cr + v_amt;
      end if;
    end loop;
    if jsonb_typeof(p->'assets') = 'array' and jsonb_array_length(p->'assets') > 200 then raise exception 'Enter at most 200 assets here; group small ones by class.'; end if;
    for x in select value from jsonb_array_elements(case when jsonb_typeof(p->'assets') = 'array' then p->'assets' else '[]'::jsonb end) loop
      select * into ac from asset_classes where cost_account = x->>'class_account';
      if not found then raise exception 'Choose the class of each asset.'; end if;
      v_name := nullif(left(trim(x->>'name'), 200), '');
      if v_name is null then raise exception 'Name each asset.'; end if;
      v_cost := round(private.num(x->>'cost'), 2); v_acc := round(coalesce(private.num(x->>'accumulated'), 0), 2);
      if coalesce(v_cost, 0) <= 0 then raise exception 'Enter the cost of %.', v_name; end if;
      if v_acc < 0 or v_acc > v_cost then raise exception 'Depreciation on % must be between zero and its cost.', v_name; end if;
      if ac.accum_account is null and v_acc > 0 then raise exception '% is not depreciated, so it has no depreciation to enter.', ac.name; end if;
      v_use := coalesce(nullif(x->>'in_use_from', '')::date, v_as_of);
      if v_use > v_as_of then raise exception '% must have been in use by %.', v_name, private.fdate(v_as_of); end if;
      insert into fixed_assets (org_id, number, name, class_account, cost, life_months, available_date, status, opening_accumulated, depreciate_from,
        created_by, confirmed_by, confirmed_at, notes)
      values (p_org, 'FA-' || lpad(private.next_no(p_org, 'FA', 1)::text, 4, '0'), v_name, ac.cost_account, v_cost, ac.default_life_months, v_use, 'active',
        v_acc, v_from, m.id, m.id, now(), 'From last year''s accounts')
      returning id into v_id;
      v_assets := v_assets || to_jsonb(v_id::text);
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', ac.cost_account, 'debit', v_cost, 'memo', v_name));
      v_dr := v_dr + v_cost;
      if v_acc > 0 then
        v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', ac.accum_account, 'credit', v_acc, 'memo', 'Depreciation to ' || private.fdate(v_as_of) || ' · ' || v_name));
        v_cr := v_cr + v_acc;
      end if;
    end loop;
    if jsonb_array_length(v_jl) = 0 then raise exception 'Enter at least one figure from last year''s accounts.'; end if;
    -- What the figures leave over stays as opening balances to be confirmed, next to the bank balances already there.
    v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'opening_equity'), 'debit', greatest(v_cr - v_dr, 0),
      'credit', greatest(v_dr - v_cr, 0), 'memo', 'Opening balances to be confirmed'));
    j := private.post_entry(p_org, 'Opening position at ' || private.fdate(v_as_of) || ' from last year''s accounts', 'opening', f.id, m.id, m.id, v_jl, v_at,
      jsonb_build_object('origin', 'manual', 'evidence', jsonb_build_array(jsonb_build_object('type', 'filing_opening', 'year', p_year))));
    update fixed_assets set journal_id = j.id where id in (select value::uuid from jsonb_array_elements_text(v_assets));
    v_open := jsonb_build_object('kind', 'figures', 'by', m.id, 'by_name', m.display_name, 'at', now(), 'as_of', v_as_of, 'journal_id', j.id,
      'assets', v_assets, 'lines', v_lines);
  end if;
  update filing_orders set opening = v_open, updated_at = now() where id = f.id;
  return public.filing_state(p_org);
end $$;

-- The statements of a filing-only business's first year in Counta say where it started when nothing came from last year.
create or replace function private.filing_opening_note(p_org uuid, p_from date) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v jsonb;
begin
  select f.opening into v from filing_orders f join orgs o on o.id = f.org_id
  where f.org_id = p_org and o.filing_only and f.opening->>'kind' in ('bank_only', 'no_figures') and (private.cit_period(p_org, f.year)).pfrom = p_from
  limit 1;
  if v is null then return '[]'::jsonb; end if;
  return jsonb_build_array(private.ftxt(case v->>'kind'
    when 'bank_only' then 'At ' || private.fdate(p_from - 1) || ' the business had no assets or liabilities other than its bank balances, as its management confirmed when'
      || ' these financial statements were prepared.'
    else 'No financial statements were available for the period before ' || private.fdate(p_from) || '. The opening position is taken as the bank balances at '
      || private.fdate(p_from - 1) || '. Any other assets and liabilities at that date are not included, and the bank balances are shown in equity as opening'
      || ' balances to be confirmed.' end));
end $$;

-- A filing-only business approves a year's return once the year is paid for, with any difference for scans settled, and
-- once the year's start is settled: the year before approved when it is done in Counta, or the opening position given.
create or replace function private.filing_approve_check() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare f public.filing_orders; v_open jsonb;
begin
  if new.status = 'approved' and old.status is distinct from 'approved' and coalesce((select filing_only from orgs where id = new.org_id), false) then
    select * into f from filing_orders where org_id = new.org_id and year = new.accounting_year;
    if f.id is null or f.status <> 'paid' then
      raise exception 'Pay the filing fee for % on the Filing page before approving its return.', new.accounting_year;
    end if;
    if f.extra_due > 0 then
      raise exception 'The scanned statements for % came to more transactions than estimated. Pay the difference of ₦% on the Filing page, then approve.',
        new.accounting_year, to_char(f.extra_due, 'FM999,999,999,990.00');
    end if;
    v_open := private.filing_opening(new.org_id, new.accounting_year);
    if v_open->>'source' = 'previous_year' and not (v_open->>'done')::boolean then
      raise exception 'Approve the % return first: % starts with its closing figures.', new.accounting_year - 1, new.accounting_year;
    end if;
    if not (v_open->>'done')::boolean then
      raise exception 'Say where % starts on the Filing page (last year''s figures, or that there were none) before approving its return.', new.accounting_year;
    end if;
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Existing functions, each with the change named above it
-- ---------------------------------------------------------------------------

-- public.filing_state: each year says where it starts, and whether its return is late.
CREATE OR REPLACE FUNCTION public.filing_state(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; o public.orgs; v_years int[]; y int; v_out jsonb := '[]'::jsonb; q jsonb; f public.filing_orders; v_kind text; r jsonb; v_due date;
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  v_years := private.filing_years(p_org);
  foreach y in array v_years loop
    q := private.filing_quote(p_org, y);
    select * into f from filing_orders where org_id = p_org and year = y;
    v_kind := coalesce(f.kind, q->>'kind');
    r := case v_kind
      when 'cit' then (select jsonb_build_object('status', c.status, 'approved_at', c.approved_at, 'filed_at', c.filed_at, 'flux_status', c.flux_status) from cit_years c
                       where c.org_id = p_org and c.accounting_year = y)
      when 'pit' then (select jsonb_build_object('status', p.status, 'approved_at', p.approved_at,
                         'filed_at', (select max(pp.filed_at) from pit_person_years pp where pp.org_id = p_org and pp.accounting_year = y and pp.included))
                       from pit_years p where p.org_id = p_org and p.accounting_year = y) end;
    v_due := case v_kind when 'pit' then make_date(y + 1, 3, 31) else ((q->>'to')::date + interval '6 months')::date end;
    v_out := v_out || jsonb_build_array(q || jsonb_build_object(
      'kind', v_kind,
      'due', v_due,
      'late', v_kind is not null and v_due < private.local_day(p_org, now()) and (r->>'filed_at') is null,
      'opening', private.filing_opening(p_org, y),
      'order', case when f.id is not null then jsonb_build_object('id', f.id, 'status', f.status, 'amount', f.amount, 'counted', f.counted,
        'lines', f.lines, 'estimate', f.estimate, 'band_up_to', f.band_up_to, 'paid_at', f.paid_at, 'payer', f.payer,
        'practice', (select name from practices where id = f.practice_id), 'true_count', f.true_count, 'extra_due', f.extra_due,
        'extra_paid', f.extra_paid) end,
      'scans', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'file_name', s.file_name, 'pages', s.pages, 'status', s.status, 'path', s.path,
          'bank_account_id', s.bank_account_id, 'account', (select name from bank_accounts where id = s.bank_account_id), 'lines_found', s.lines_found,
          'created_at', s.created_at) order by s.created_at), '[]'::jsonb) from filing_scans s where s.order_id = f.id),
      'statements', (select coalesce(jsonb_agg(jsonb_build_object('file_name', i.file_name, 'account', b.name, 'from', coalesce(i.period_from, i.from_date),
          'to', coalesce(i.period_to, i.to_date), 'lines', i.lines_added, 'at', i.created_at) order by i.created_at), '[]'::jsonb)
        from bank_imports i join bank_accounts b on b.id = i.bank_account_id
        where i.org_id = p_org and coalesce(i.period_from, i.from_date) <= (q->>'to')::date and coalesce(i.period_to, i.to_date) >= (q->>'from')::date),
      'return', r,
      'pending', (select jsonb_build_object('tx_ref', c.tx_ref, 'amount', c.amount, 'payer', case when c.practice_id is not null then 'practice' else 'business' end,
          'status', c.status, 'at', c.created_at) from subscription_charges c
        where c.filing_order_id = f.id and c.status in ('pending', 'sent') and c.created_at > now() - interval '2 days' order by c.created_at desc limit 1)));
  end loop;
  return jsonb_build_object(
    'filing_only', o.filing_only, 'hold', private.filing_hold(p_org), 'is_sample', o.is_sample, 'managed', o.managed_by is not null,
    'kind', private.filing_kind(p_org, v_years[1]), 'legal_form', o.legal_form, 'vat_registered', o.vat_registered,
    'years', v_out,
    'prices', (select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'up_to', up_to, 'price', price) order by kind, coalesce(up_to, 2147483647)), '[]'::jsonb)
               from filing_prices),
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'kind', b.kind, 'bank_name', b.bank_name,
        'last4', right(regexp_replace(coalesce(b.account_number, ''), '\D', '', 'g'), 4)) order by b.created_at), '[]'::jsonb)
      from bank_accounts b where b.org_id = p_org and b.active and b.kind in ('bank', 'cash')),
    'can_upload', private.perm_of(m, 'keep_books'),
    'can_pay', o.managed_by is null and not o.is_sample and (m.role in ('owner', 'admin') or m.acts_as_owner),
    'card', (select jsonb_build_object('last4', k.last4, 'brand', k.brand) from subscription_cards k where k.org_id = p_org and k.active
             order by k.created_at desc limit 1),
    'practice', private.filing_practice(p_org));
end $function$;

-- public.dispose_asset: the work moves to private.dispose_core, shared with sales matched on the bank and part exchange.
CREATE OR REPLACE FUNCTION public.dispose_asset(p_asset uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare a public.fixed_assets; m public.members; v_day date; v_proceeds numeric := round(coalesce(private.num(p->>'proceeds'), 0), 2); v_bank text; v_cust uuid;
begin
  select * into a from fixed_assets where id = p_asset for update;
  if not found then raise exception 'Asset not found.'; end if;
  m := private.require(a.org_id, 'keep_books');
  if a.status <> 'active' then raise exception '% is %.', a.number, replace(a.status, '_', ' '); end if;
  v_day := coalesce(nullif(p->>'date', '')::date, private.local_day(a.org_id, now()));
  perform private.require_open_day(a.org_id, v_day);
  if v_proceeds < 0 then raise exception 'Proceeds cannot be negative.'; end if;
  if v_proceeds > 0 then
    v_cust := nullif(p->>'customer_id', '')::uuid;
    if v_cust is null then
      select ledger_code into v_bank from bank_accounts where id = nullif(p->>'bank_account_id', '')::uuid and org_id = a.org_id and active;
      if v_bank is null then raise exception 'Choose where the proceeds went, or the customer who owes them.'; end if;
    elsif not exists (select 1 from customers where id = v_cust and org_id = a.org_id) then
      raise exception 'Customer not found.';
    end if;
  end if;
  return private.dispose_core(a.id, v_day, v_proceeds, coalesce(v_bank, private.acct(a.org_id, 'receivables')),
    case when v_cust is not null then 'customer' end, v_cust, p->>'reason', m);
end $function$;

-- public.confirm_asset: an old asset taken in part exchange is disposed of at the value agreed, which joins the new one's cost.
CREATE OR REPLACE FUNCTION public.confirm_asset(p_asset uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare a public.fixed_assets; m public.members; v_class text; v_life int; v_was text; v_old public.fixed_assets; v_val numeric;
begin
  select * into a from fixed_assets where id = p_asset for update;
  if not found then raise exception 'Asset not found.'; end if;
  m := private.require(a.org_id, 'keep_books');
  v_was := a.status;
  if a.status not in ('pending_confirmation', 'active') then raise exception '% is %.', a.number, a.status; end if;
  v_class := coalesce(nullif(p->>'class_account', ''), a.class_account);
  if not exists (select 1 from asset_classes where cost_account = v_class) then raise exception 'Unknown asset class.'; end if;
  v_life := coalesce(nullif(p->>'life_months', '')::int, a.life_months, (select default_life_months from asset_classes where cost_account = v_class));
  if (select depreciates from asset_classes where cost_account = v_class) and (v_life is null or v_life < 1) then raise exception 'Enter the useful life in months.'; end if;
  if a.status = 'active' and exists (select 1 from journal_lines where party_type = 'asset' and party_id = a.id) and (v_class <> a.class_account) then
    raise exception 'Depreciation has started on %. Its class can no longer change.', a.number;
  end if;
  if v_class <> a.class_account then
    perform private.post_entry(a.org_id, 'Asset ' || a.number || ' reclassified to ' || (select name from asset_classes where cost_account = v_class), 'asset', a.id, m.id, m.id,
      private.reclass_pair(v_class, a.class_account, a.cost, a.location_id, null), now());
  end if;
  update fixed_assets set class_account = v_class, life_months = v_life, name = coalesce(nullif(trim(p->>'name'), ''), name),
    available_date = coalesce(nullif(p->>'available_date', '')::date, available_date), residual = coalesce(private.num(p->>'residual'), residual),
    depreciate_from = coalesce(nullif(p->>'available_date', '')::date, available_date),
    location_id = coalesce((select id from locations where id = nullif(p->>'location_id', '')::uuid and org_id = a.org_id), location_id),
    serial_no = case when p ? 'serial_no' then nullif(trim(p->>'serial_no'), '') else serial_no end,
    status = 'active', confirmed_by = m.id, confirmed_at = now()
  where id = a.id returning * into a;
  if a.residual > a.cost then raise exception 'The residual value is more than the cost.'; end if;
  -- Part exchange: the old asset leaves at the value agreed for it, and that value is part of what the new one cost.
  if private.uuid_of(p->'trade_in'->>'asset_id') is not null then
    if v_was <> 'pending_confirmation' then raise exception 'Part exchange is recorded when the new asset is confirmed.'; end if;
    select * into v_old from fixed_assets where id = private.uuid_of(p->'trade_in'->>'asset_id') and org_id = a.org_id for update;
    if not found or v_old.id = a.id or v_old.status <> 'active' then raise exception 'Choose an asset in use to part-exchange.'; end if;
    v_val := round(private.num(p->'trade_in'->>'value'), 2);
    if coalesce(v_val, 0) <= 0 then raise exception 'Enter the value the seller gave for %.', v_old.number; end if;
    perform private.dispose_core(v_old.id, coalesce(a.available_date, private.local_day(a.org_id, now())), v_val, a.class_account, null, null,
      'Part-exchanged for ' || a.number, m);
    update fixed_assets set cost = cost + v_val,
      notes = concat_ws(' · ', notes, 'Includes ' || private.naira(v_val) || ' for ' || v_old.number || ' taken in part exchange') where id = a.id;
  end if;
  return private.asset_json(a.id);
end $function$;

-- public.add_asset: an asset a director paid for personally is owed to the director.
CREATE OR REPLACE FUNCTION public.add_asset(p_org uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; a public.fixed_assets; ac public.asset_classes; v_cost numeric := round(private.num(p->>'cost'), 2); v_acc numeric := round(coalesce(private.num(p->>'accumulated'), 0), 2);
  v_credit text; v_party uuid; v_fund text := coalesce(nullif(p->>'funding', ''), 'opening'); v_day date; v_at timestamptz; j public.journals;
begin
  m := private.require(p_org, 'keep_books');
  select * into ac from asset_classes where cost_account = p->>'class_account';
  if not found then raise exception 'Choose the asset class.'; end if;
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'Name the asset.'; end if;
  if coalesce(v_cost, 0) <= 0 then raise exception 'Enter the cost.'; end if;
  if v_acc < 0 or v_acc > v_cost then raise exception 'Accumulated depreciation must be between zero and the cost.'; end if;
  if v_fund = 'opening' then
    v_credit := private.acct(p_org, 'opening_equity');
    v_day := coalesce((select books_start - 1 from orgs where id = p_org), nullif(p->>'date', '')::date, private.local_day(p_org, now()));
  elsif v_fund = 'bank' then
    select ledger_code into v_credit from bank_accounts where id = nullif(p->>'bank_account_id', '')::uuid and org_id = p_org and active;
    if v_credit is null then raise exception 'Choose the account it was paid from.'; end if;
    if v_acc > 0 then raise exception 'A new purchase has no depreciation yet.'; end if;
  elsif v_fund = 'vendor' then
    v_party := nullif(p->>'vendor_id', '')::uuid;
    if not exists (select 1 from vendors where id = v_party and org_id = p_org) then raise exception 'Choose the vendor.'; end if;
    v_credit := private.acct(p_org, 'payables');
    if v_acc > 0 then raise exception 'A new purchase has no depreciation yet.'; end if;
  elsif v_fund = 'director' then
    -- Paid by a director from their own pocket: the business owes the director (Directors' current accounts).
    v_credit := '2106';
    if v_acc > 0 then raise exception 'A new purchase has no depreciation yet.'; end if;
  else
    raise exception 'Say how the asset was paid for.';
  end if;
  v_day := coalesce(v_day, nullif(p->>'date', '')::date, nullif(p->>'available_date', '')::date, private.local_day(p_org, now()));
  v_at := (v_day::timestamp + interval '12 hours') at time zone coalesce((select timezone from orgs where id = p_org), 'Africa/Lagos');
  insert into fixed_assets (org_id, number, name, class_account, cost, residual, life_months, available_date, status, location_id, serial_no, opening_accumulated,
    depreciate_from, created_by, confirmed_by, confirmed_at)
  values (p_org, 'FA-' || lpad(private.next_no(p_org, 'FA', 1)::text, 4, '0'), trim(p->>'name'), ac.cost_account, v_cost, coalesce(private.num(p->>'residual'), 0),
    coalesce(nullif(p->>'life_months', '')::int, ac.default_life_months), coalesce(nullif(p->>'available_date', '')::date, v_day), 'active',
    (select id from locations where id = nullif(p->>'location_id', '')::uuid and org_id = p_org), nullif(trim(p->>'serial_no'), ''),
    case when v_fund = 'opening' then v_acc else 0 end,
    case when v_fund = 'opening' then v_day + 1 else coalesce(nullif(p->>'available_date', '')::date, v_day) end, m.id, m.id, now())
  returning * into a;
  j := private.post_entry(p_org, 'Asset ' || a.number || ' · ' || a.name, 'asset', a.id, m.id, m.id, jsonb_build_array(
      jsonb_build_object('code', ac.cost_account, 'debit', v_cost, 'location_id', a.location_id, 'memo', a.name),
      jsonb_build_object('code', v_credit, 'credit', v_cost - case when v_fund = 'opening' then v_acc else 0 end,
        'party_type', case when v_party is not null then 'vendor' end, 'party_id', v_party),
      jsonb_build_object('code', ac.accum_account, 'credit', case when v_fund = 'opening' then v_acc else 0 end, 'memo', 'Depreciation before the books started')),
    v_at, jsonb_build_object('origin', 'manual'));
  update fixed_assets set journal_id = j.id where id = a.id;
  return private.asset_json(a.id);
end $function$;

-- private.asset_json: the bank line an asset came from, and the asset a record joined.
CREATE OR REPLACE FUNCTION private.asset_json(p_asset uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select to_jsonb(a) || jsonb_build_object('class_name', ac.name, 'accum_account', ac.accum_account, 'depreciates', ac.depreciates,
    'accumulated', private.asset_accumulated(a.id), 'carrying_amount', a.cost - private.asset_accumulated(a.id),
    'monthly_charge', case when a.life_months > 0 and ac.depreciates then round((a.cost - a.residual) / a.life_months, 2) end,
    'location_name', (select name from locations where id = a.location_id), 'bill_number', (select number from bills where id = a.bill_id),
    'vendor_name', (select v.name from bills b join vendors v on v.id = b.vendor_id where b.id = a.bill_id),
    'bank_line', (select jsonb_build_object('date', bl.line_date, 'amount', bl.amount, 'narration', bl.description, 'counterparty', bl.counterparty,
       'account', (select name from bank_accounts where id = bl.bank_account_id)) from bank_lines bl where bl.id = a.bank_line_id),
    'merged_into_number', (select x.number from fixed_assets x where x.id = a.merged_into))
  from fixed_assets a join asset_classes ac on ac.cost_account = a.class_account where a.id = p_asset
$function$;

-- public.get_assets: money in for assets sold, waiting to be matched, and what it does to the reconciliation.
CREATE OR REPLACE FUNCTION public.get_assets(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Your role does not see the asset register.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'assets', (select coalesce(jsonb_agg(private.asset_json(a.id) order by a.number), '[]'::jsonb) from fixed_assets a where a.org_id = p_org and a.status <> 'rejected'),
    'classes', (select jsonb_agg(to_jsonb(c) order by c.cost_account) from asset_classes c),
    'runs', (select coalesce(jsonb_agg(jsonb_build_object('period_end', r.period_end, 'total', r.total, 'journal_ref', (select ref from journals where id = r.journal_id))
        order by r.period_end desc), '[]'::jsonb) from depreciation_runs r where r.org_id = p_org),
    'threshold', (select capitalisation_threshold from orgs where id = p_org),
    'sales', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'status', s.status, 'class_account', s.class_account,
        'class_name', (select name from asset_classes where cost_account = s.class_account), 'amount', s.amount, 'date', bl.line_date,
        'narration', bl.description, 'counterparty', bl.counterparty, 'account', (select name from bank_accounts where id = bl.bank_account_id),
        'asset_number', (select number from fixed_assets where id = s.asset_id), 'decided_at', s.decided_at) order by bl.line_date desc), '[]'::jsonb)
      from asset_sales s join bank_lines bl on bl.id = s.bank_line_id
      where s.org_id = p_org and (s.status = 'pending' or (s.status = 'matched' and s.decided_at > now() - interval '90 days'))),
    -- FA-01: the register must agree with the ledger, class by class.
    'reconciliation', (select coalesce(jsonb_agg(jsonb_build_object('class', c.cost_account, 'name', c.name,
        'register_cost', (select coalesce(sum(cost), 0) from fixed_assets where org_id = p_org and class_account = c.cost_account and status in ('active', 'pending_confirmation')),
        'unmatched_sales', (select coalesce(sum(amount), 0) from asset_sales where org_id = p_org and class_account = c.cost_account and status = 'pending'),
        'ledger_cost', (select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code = c.cost_account),
        'register_accumulated', (select coalesce(sum(private.asset_accumulated(id)), 0) from fixed_assets where org_id = p_org and class_account = c.cost_account and status = 'active'),
        'ledger_accumulated', (select coalesce(sum(credit - debit), 0) from journal_lines where org_id = p_org and account_code = c.accum_account))), '[]'::jsonb)
      from asset_classes c where exists (select 1 from journal_lines where org_id = p_org and account_code in (c.cost_account, c.accum_account))
        or exists (select 1 from fixed_assets where org_id = p_org and class_account = c.cost_account)));
end $function$;

-- public.get_books_inbox: asset sales on the bank waiting to be matched.
CREATE OR REPLACE FUNCTION public.get_books_inbox(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Your role does not see the books inbox.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'questions', (select coalesce(jsonb_agg(to_jsonb(p) || jsonb_build_object(
        'line', (select jsonb_build_object('date', bl.line_date, 'amount', bl.amount, 'narration', bl.description, 'counterparty', bl.counterparty,
           'account', (select name from bank_accounts where id = bl.bank_account_id)) from bank_lines bl where bl.id = p.source_id and p.source_type = 'bank_line'),
        'account_name', private.account_name(p_org, p.proposal->>'account_code')) order by p.created_at), '[]'::jsonb)
      from ai_proposals p where p.org_id = p_org and p.status = 'pending'),
    'review', (select coalesce(jsonb_agg(to_jsonb(p) || jsonb_build_object('account_name', private.account_name(p_org, p.proposal->>'account_code'),
        'line', (select jsonb_build_object('date', bl.line_date, 'amount', bl.amount, 'narration', bl.description, 'counterparty', bl.counterparty)
           from bank_lines bl where bl.id = p.source_id and p.source_type = 'bank_line'),
        'journal_ref', (select ref from journals where id = p.journal_id)) order by p.created_at desc), '[]'::jsonb)
      from (select * from ai_proposals where org_id = p_org and status in ('auto_posted', 'info') and created_at > now() - interval '45 days' order by created_at desc limit 200) p),
    'payments_to_confirm', (select count(*) from collections where org_id = p_org and status = 'pending'),
    'bills_to_approve', (select count(*) from bills where org_id = p_org and status = 'draft'),
    'assets_to_confirm', (select count(*) from fixed_assets where org_id = p_org and status = 'pending_confirmation'),
    'asset_sales_to_match', (select count(*) from asset_sales where org_id = p_org and status = 'pending'),
    'payouts_to_approve', (select count(*) from payouts where org_id = p_org and status = 'pending_approval'),
    'suspense', (select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code = '9001'));
end $function$;

-- public.close_checklist: asset sales on the bank are matched before the month closes, as new assets are confirmed.
CREATE OR REPLACE FUNCTION public.close_checklist(p_org uuid, p_period_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; v jsonb := '[]'::jsonb; v_n numeric; v_txt text; r record;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Your role does not see the close.' using errcode = '42501'; end if;
  -- Each step: {key, title, blocking, ok, detail, waived}
  -- 1 Every bank and wallet account reconciled to the month end
  select string_agg(b.name, ', ') into v_txt from bank_accounts b where b.org_id = p_org and b.active and b.kind in ('bank', 'wallet')
    and exists (select 1 from journal_lines l join journals j on j.id = l.journal_id where l.org_id = p_org and l.account_code = b.ledger_code and j.entry_date <= p_period_end)
    and not exists (select 1 from bank_reconciliations r2 where r2.bank_account_id = b.id and r2.as_of = p_period_end and r2.status = 'balanced');
  v := v || jsonb_build_object('key', 'bank_reconciled', 'title', 'Bank and wallet accounts reconciled to the month end', 'blocking', true, 'ok', v_txt is null,
    'detail', coalesce('Not reconciled: ' || v_txt, 'All reconciled'));
  -- 2 Suspense and clearing empty
  select coalesce(sum(bal), 0) into v_n from private.balances_at(p_org, p_period_end) where code in ('9001', '9002', '9003', '9004', '9005', '9006', '9007');
  v := v || jsonb_build_object('key', 'suspense_clear', 'title', 'Suspense and clearing accounts are empty', 'blocking', true, 'ok', abs(v_n) < 0.01,
    'detail', case when abs(v_n) < 0.01 then 'Nothing waiting' else '₦' || to_char(v_n, 'FM999,999,999,990.00') || ' still unexplained' end);
  -- 3 Questions from the agents answered
  select count(*) into v_n from ai_proposals ap where ap.org_id = p_org and ap.status = 'pending' and ap.kind <> 'item_vat'
    and ((ap.source_type = 'bank_line' and exists (select 1 from bank_lines bl where bl.id = ap.source_id and bl.line_date <= p_period_end))
         or (ap.source_type is distinct from 'bank_line' and ap.created_at::date <= p_period_end + 15));
  v := v || jsonb_build_object('key', 'inbox_clear', 'title', 'Questions in the books inbox answered', 'blocking', true, 'ok', v_n = 0, 'detail', v_n || ' waiting');
  -- 4 Payments recorded at the till confirmed or rejected
  select count(*) into v_n from collections where org_id = p_org and status = 'pending' and private.local_day(p_org, received_at) <= p_period_end;
  v := v || jsonb_build_object('key', 'payments_confirmed', 'title', 'Transfers and card payments confirmed against the bank', 'blocking', true, 'ok', v_n = 0, 'detail', v_n || ' waiting');
  -- 5 Till sales still waiting for their transfer
  select count(*) into v_n from sales where org_id = p_org and doc_type = 'receipt' and journal_id is null and status not in ('cancelled', 'void') and issue_date <= p_period_end;
  v := v || jsonb_build_object('key', 'till_sales', 'title', 'Till sales waiting for payment completed or cancelled', 'blocking', true, 'ok', v_n = 0, 'detail', v_n || ' waiting');
  -- 6 Bills for the month approved (or they will be accrued)
  select count(*), coalesce(sum(total), 0) into v_n, v_txt from bills where org_id = p_org and status = 'draft' and bill_date <= p_period_end and accrual_journal_id is null;
  v := v || jsonb_build_object('key', 'bills_approved', 'title', 'Bills for the month approved; the rest are accrued at close', 'blocking', false, 'ok', v_n = 0,
    'detail', case when v_n = 0 then 'All approved' else v_n || ' draft bill(s) will be accrued to 2103' end);
  -- 7 Assets confirmed and depreciation run
  select count(*) into v_n from fixed_assets where org_id = p_org and status = 'pending_confirmation' and coalesce(available_date, created_at::date) <= p_period_end;
  v_n := v_n + (select count(*) from asset_sales s join bank_lines bl on bl.id = s.bank_line_id
                where s.org_id = p_org and s.status = 'pending' and bl.line_date <= p_period_end);
  v := v || jsonb_build_object('key', 'assets_confirmed', 'title', 'New assets confirmed in the register', 'blocking', true, 'ok', v_n = 0, 'detail', v_n || ' waiting');
  v := v || jsonb_build_object('key', 'depreciation', 'title', 'Depreciation run for the month', 'blocking', false,
    'ok', not exists (select 1 from fixed_assets where org_id = p_org and status = 'active') or exists (select 1 from depreciation_runs where org_id = p_org and period_end >= p_period_end),
    'detail', 'Runs automatically at close');
  -- 8 Sub-ledgers agree to their control accounts
  select coalesce(sum(case when l.party_id is null then l.debit - l.credit end), 0) into v_n from journal_lines l join journals j on j.id = l.journal_id
    where l.org_id = p_org and j.entry_date <= p_period_end and l.account_code in ('1101', '1102');
  v := v || jsonb_build_object('key', 'subledgers', 'title', 'Customer and vendor ledgers agree to receivables and payables', 'blocking', false, 'ok', abs(v_n) < 0.01,
    'detail', case when abs(v_n) < 0.01 then 'Agreed' else '₦' || to_char(v_n, 'FM999,999,999,990.00') || ' of receivables has no customer' end);
  -- 9 Expected credit losses reviewed
  v := v || jsonb_build_object('key', 'ecl', 'title', 'Expected credit losses on receivables reviewed', 'blocking', false,
    'ok', exists (select 1 from journals where org_id = p_org and source_type = 'ecl' and entry_date = p_period_end)
          or not exists (select 1 from sales where org_id = p_org and status in ('open', 'partially_paid') and due_date < p_period_end - 30),
    'detail', 'Run the provision matrix if customers are more than 30 days late');
  -- 10 Statutory heads: VAT output and input agree to documents
  v := v || jsonb_build_object('key', 'vat_tieout', 'title', 'VAT in the ledger agrees to invoices and bills', 'blocking', true,
    'ok', abs(coalesce((select (x->>'current')::numeric from jsonb_array_elements(private.vat_rows(p_org, date_trunc('month', p_period_end)::date, p_period_end)) x
       where x->>'line' = 'Difference to explain'), 0)) < 0.01, 'detail', 'Output and input VAT for the month');
  -- Waivers
  v := (select jsonb_agg(s || jsonb_build_object('waived', w.reason is not null, 'waiver', case when w.reason is not null then jsonb_build_object('reason', w.reason,
      'by', (select display_name from members where id = w.waived_by), 'at', w.waived_at) end))
    from jsonb_array_elements(v) s left join close_waivers w on w.org_id = p_org and w.period_end = p_period_end and w.step = s->>'key');
  return jsonb_build_object('period_end', p_period_end, 'steps', v,
    'ready', not exists (select 1 from jsonb_array_elements(v) s where (s->>'blocking')::boolean and not (s->>'ok')::boolean and not (s->>'waived')::boolean));
end $function$;

-- public.svc_lines_for_ai: the business's trade, its capitalisation threshold and its assets in use, so the bookkeeper can tell stock from an asset and spot a sale.
CREATE OR REPLACE FUNCTION public.svc_lines_for_ai(p_org uuid, p_limit integer DEFAULT 40)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select jsonb_build_object(
    'org', (select jsonb_build_object('id', o.id, 'name', o.name, 'industry', o.industry, 'vat_registered', o.vat_registered,
       'cash_sales_without_invoices', o.cash_sales_without_invoices, 'threshold', greatest(o.auto_post_threshold, 0.8),
       'capitalisation_threshold', o.capitalisation_threshold, 'trade', private.ai_trade(o.id)) from orgs o where o.id = p_org),
    'assets', private.ai_assets(p_org),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('id', bl.id, 'date', bl.line_date, 'amount', bl.amount, 'narration', bl.description,
        'reference', bl.reference, 'counterparty', bl.counterparty, 'account', b.name, 'account_kind', b.kind,
        'history', (select jsonb_agg(h) from (select l.account_code code, count(*) n from bank_lines x join journal_lines l on l.journal_id = x.journal_id
            and l.account_code <> b.ledger_code where x.org_id = p_org and x.party_key = bl.party_key and x.status in ('posted', 'matched') and x.id <> bl.id
            group by 1 order by 2 desc limit 3) h)) order by bl.line_date), '[]'::jsonb)
      from (select * from bank_lines where org_id = p_org and status = 'unmatched' and ai_attempts < 3 and private.filing_day_open(p_org, line_date) order by line_date limit greatest(p_limit, 1)) bl
      join bank_accounts b on b.id = bl.bank_account_id),
    'accounts', (select jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name, 'category', a.category, 'ifrs_line', a.ifrs_line) order by a.code)
      from private.accounts_of(p_org) a
      where a.active and not a.is_group and private.postable(p_org, a.code) and a.code !~ '^(101|1101|1102|1203|1201|1202|2101|2102|2201|1402|1401|2202|9)'),
    'customers', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name)), '[]'::jsonb) from customers where org_id = p_org and not is_walk_in and not archived),
    'vendors', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name)), '[]'::jsonb) from vendors where org_id = p_org),
    'directors', (select coalesce(jsonb_agg(display_name), '[]'::jsonb) from members where org_id = p_org and role = 'owner'))
$function$;

-- public.svc_questions_for_ai: the same for the short lists under waiting questions.
CREATE OR REPLACE FUNCTION public.svc_questions_for_ai(p_org uuid, p_limit integer DEFAULT 40)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select jsonb_build_object(
    'org', (select jsonb_build_object('id', o.id, 'name', o.name, 'industry', o.industry, 'vat_registered', o.vat_registered,
       'cash_sales_without_invoices', o.cash_sales_without_invoices, 'threshold', greatest(o.auto_post_threshold, 0.8),
       'capitalisation_threshold', o.capitalisation_threshold, 'trade', private.ai_trade(o.id)) from orgs o where o.id = p_org),
    'assets', private.ai_assets(p_org),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'date', bl.line_date, 'amount', bl.amount, 'narration', bl.description,
        'reference', bl.reference, 'counterparty', bl.counterparty, 'account', b.name, 'account_kind', b.kind,
        'history', (select jsonb_agg(h) from (select l.account_code code, count(*) n from bank_lines x join journal_lines l on l.journal_id = x.journal_id
            and l.account_code <> b.ledger_code where x.org_id = p_org and x.party_key = bl.party_key and x.status in ('posted', 'matched') and x.id <> bl.id
            group by 1 order by 2 desc limit 3) h)) order by bl.line_date), '[]'::jsonb)
      from (select * from ai_proposals where org_id = p_org and status = 'pending' and source_type = 'bank_line' and not (proposal ? 'alternatives')
              and coalesce(proposal->>'kind', '') not in ('invoice_match', 'bill_match') order by created_at limit greatest(p_limit, 1)) pr
      join bank_lines bl on bl.id = pr.source_id
      join bank_accounts b on b.id = bl.bank_account_id),
    'accounts', (select jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name, 'category', a.category, 'ifrs_line', a.ifrs_line) order by a.code)
      from private.accounts_of(p_org) a
      where a.active and not a.is_group and private.postable(p_org, a.code) and a.code !~ '^(101|1101|1102|1203|1201|1202|2101|2102|2201|1402|1401|2202|9)'),
    'customers', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name)), '[]'::jsonb) from customers where org_id = p_org and not is_walk_in and not archived),
    'vendors', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name)), '[]'::jsonb) from vendors where org_id = p_org),
    'directors', (select coalesce(jsonb_agg(display_name), '[]'::jsonb) from members where org_id = p_org and role = 'owner'))
$function$;

-- private.note_rows: a filing-only business's first year says where it started when nothing came from last year.
CREATE OR REPLACE FUNCTION private.note_rows(p_org uuid, p_from date, p_to date, p_pfrom date, p_pto date, p_bpto date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare o public.orgs; v jsonb := '[]'::jsonb; r record; c jsonb; p jsonb; plc jsonb; plp jsonb; tc jsonb; tp jsonb;
  mvc jsonb; mvp jsonb; drc jsonb; crc jsonb; balc jsonb; balo jsonb; balp jsonb; v_bpto date := coalesce(p_bpto, p_pto); n jsonb; v_mv jsonb;
  v_fw text; v_ifrs boolean; v_nta boolean; v_co boolean; v_period text; v_ended text; v_cmp text; v_x numeric; v_y numeric; v_z numeric; v_w numeric;
  v_rate numeric; v_pbt numeric; v_pbtp numeric; v_tax numeric; v_taxp numeric; v_ca numeric; v_cl numeric; v_eq numeric; v_cash numeric; v_debt numeric;
  v_txt text; v_lives text; v_name text; v_dirs text; v_start int;
begin
  select * into o from orgs where id = p_org;
  n := coalesce(o.fs_narrative, '{}'::jsonb);
  c := private.sofp_map(p_org, p_to);
  p := case when v_bpto is null then '{}'::jsonb else private.sofp_map(p_org, v_bpto) end;
  plc := private.pl_map(p_org, p_from, p_to);
  plp := case when p_pfrom is null then '{}'::jsonb else private.pl_map(p_org, p_pfrom, p_pto) end;
  tc := private.pl_totals(plc); tp := private.pl_totals(plp);
  select coalesce(jsonb_object_agg(code, net), '{}'), coalesce(jsonb_object_agg(code, dr), '{}'), coalesce(jsonb_object_agg(code, cr), '{}') into mvc, drc, crc
    from private.movement(p_org, p_from, p_to);
  select coalesce(jsonb_object_agg(code, net), '{}') into mvp from private.movement(p_org, coalesce(p_pfrom, p_from), coalesce(p_pto, p_from - 1)) where p_pfrom is not null;
  select coalesce(jsonb_object_agg(code, bal), '{}') into balc from private.balances_at(p_org, p_to);
  select coalesce(jsonb_object_agg(code, bal), '{}') into balo from private.balances_at(p_org, p_from - 1);
  select coalesce(jsonb_object_agg(code, bal), '{}') into balp from private.balances_at(p_org, v_bpto) where v_bpto is not null;
  mvp := coalesce(mvp, '{}'); balp := coalesce(balp, '{}');
  v_ifrs := coalesce(o.reporting_framework, 'ifrs') <> 'ifrs_sme';
  v_fw := case when v_ifrs then 'IFRS Accounting Standards as issued by the International Accounting Standards Board (IASB)' else 'the IFRS for SMEs Accounting Standard issued by the IASB' end;
  v_nta := p_to >= date '2026-01-01';
  v_co := coalesce(o.legal_form, 'company') = 'company';
  v_ended := private.fdate(p_to);
  v_period := case when private.fs_periods(p_org, p_from, p_to)->>'full_year' = 'true' then 'year ended ' || v_ended else 'period from ' || private.fdate(p_from) || ' to ' || v_ended end;
  v_cmp := case when v_bpto is null then '' else to_char(v_bpto, 'YYYY') end;
  v_name := case when v_co then 'the Company' else 'the business' end;
  select string_agg(d->>'name' || coalesce(' (' || (d->>'role') || ')', ''), ', ') into v_dirs from jsonb_array_elements(o.directors) d;

  -- 1 ----------------------------------------------------------------------
  v := v || private.fhd('1. General information')
    || private.ftxt(o.name || case when v_co then ' ("the Company") is a private limited liability company incorporated in Nigeria under the Companies and Allied Matters Act'
         else ' ("the business") is registered in Nigeria' end
         || coalesce(' on ' || private.fdate(o.incorporation_date), '') || coalesce(' with registration number RC ' || nullif(regexp_replace(o.rc_number, '^\s*RC\s*', '', 'i'), ''), '') || '.'
         || coalesce(' Its registered office is at ' || nullif(coalesce(o.registered_office, o.address), '') || '.', ''))
    || private.ftxt('The principal activity of ' || v_name || ' is ' || coalesce(nullif(o.principal_activity, ''), replace(coalesce(o.industry, 'trading'), '_', ' ')) || '.'
         || coalesce(' Its Tax ID is ' || nullif(o.tin, '') || '.', ''))
    || private.ftxt('These financial statements are for the ' || v_period || '.');

  -- 2 ----------------------------------------------------------------------
  v := v || private.fhd('2. Basis of preparation')
    || private.fsh('2.1 Statement of compliance')
    || private.ftxt('The financial statements have been prepared in accordance with ' || v_fw || ', and comply with the requirements of the Companies and Allied Matters Act 2020'
         || ' and the Financial Reporting Council of Nigeria Act 2011 (as amended).')
    || private.fsh('2.2 Basis of measurement')
    || private.ftxt('The financial statements are prepared on the historical cost basis, except where a policy below states otherwise.')
    || private.fsh('2.3 Functional and presentation currency')
    || private.ftxt('The financial statements are presented in Nigerian naira (₦), the functional currency of ' || v_name || '. Amounts are shown to the nearest kobo.')
    || private.fsh('2.4 Going concern');
  v_ca := (select coalesce(sum(value::numeric), 0) from jsonb_each_text(c) where key in ('Inventories', 'Trade and other receivables', 'Contract assets', 'Prepayments',
    'Other current financial assets', 'Current tax assets', 'Assets held for sale', 'Other current assets', 'Cash and cash equivalents', 'Unreconciled balances (assets)'));
  v_cl := (select coalesce(sum(value::numeric), 0) from jsonb_each_text(c) where key in ('Trade and other payables', 'Contract liabilities', 'Current tax liabilities',
    'Other statutory liabilities', 'Bank overdrafts', 'Borrowings (current)', 'Lease liabilities (current)', 'Provisions (current)', 'Other current liabilities',
    'Unreconciled balances (liabilities)'));
  v_eq := (select coalesce(sum(value::numeric), 0) from jsonb_each_text(c) where key in ('Share capital', 'Share premium', 'Deposit for shares', 'Other reserves',
    'Retained earnings', 'Opening balances to be confirmed', 'Non-controlling interests'));
  v := v || private.ftxt(coalesce(n->>'going_concern', 'The directors have assessed the ability of ' || v_name || ' to continue as a going concern and are satisfied that it has the resources'
         || ' to continue in business for at least twelve months from the date these financial statements are approved. The financial statements are therefore prepared on the going concern basis.'));
  if v_cl > v_ca + 0.005 or v_eq < -0.005 then
    v := v || private.ftxt('At ' || v_ended || ', ' || case when v_cl > v_ca + 0.005 then 'current liabilities exceeded current assets by ' || private.naira(v_cl - v_ca) else '' end
      || case when v_cl > v_ca + 0.005 and v_eq < -0.005 then ' and ' else '' end
      || case when v_eq < -0.005 then 'total liabilities exceeded total assets by ' || private.naira(-v_eq) else '' end
      || '. The directors have taken this into account in their assessment.');
  end if;
  v := v || private.fsh('2.5 Use of judgements and estimates')
    || private.ftxt('Preparing financial statements requires the directors to make judgements, estimates and assumptions that affect the application of accounting policies and the reported amounts'
         || ' of assets, liabilities, income and expenses. Estimates are reviewed on an ongoing basis and revisions are recognised prospectively. The judgements and estimates with the most significant effect are described in note 4.')
    || private.fsh('2.6 Comparative information')
    || case when p_pfrom is null then private.ftxt('These are the first financial statements prepared from these books, so no comparative figures are presented.')
       else private.ftxt('Comparative figures for profit or loss, other comprehensive income and cash flows are for ' || private.fdate(p_pfrom) || ' to ' || private.fdate(p_pto)
         || '. Comparative balances are at ' || private.fdate(v_bpto) || case when v_bpto <> p_pto then ', the end of the previous financial year' else '' end || '.') end
    || private.filing_opening_note(p_org, p_from)
    || private.fsh('2.7 New and amended standards');
  v_start := extract(year from private.fy_start(p_org, p_to))::int;
  if not v_ifrs then
    v := v || private.ftxt(case when v_start >= 2027 then 'The third edition of the IFRS for SMEs Accounting Standard, issued in February 2025, is effective for periods beginning on or after 1 January 2027 and has been applied.'
      else 'The third edition of the IFRS for SMEs Accounting Standard, issued in February 2025, is effective for periods beginning on or after 1 January 2027. The directors are assessing its effect; the main changes concern revenue (a new section aligned with IFRS 15), fair value measurement and the expected credit loss model for financial assets.' end);
  elsif v_start >= 2027 then
    v := v || private.ftxt('IFRS 18 Presentation and Disclosure in Financial Statements, which replaces IAS 1, and IFRS 19 Subsidiaries without Public Accountability: Disclosures are effective for annual periods beginning on or after 1 January 2027.'
      || ' IFRS 18 changes the structure of the statement of profit or loss into operating, investing and financing categories and requires disclosure of management-defined performance measures.');
  elsif v_start = 2026 then
    v := v || private.ftxt('The following amendments are effective for periods beginning on or after 1 January 2026 and have no material effect on these financial statements: Amendments to the Classification and Measurement of Financial Instruments (IFRS 9 and IFRS 7);'
        || ' Contracts Referencing Nature-dependent Electricity (IFRS 9 and IFRS 7); and Annual Improvements to IFRS Accounting Standards, Volume 11.')
      || private.ftxt('IFRS 18 Presentation and Disclosure in Financial Statements, which replaces IAS 1, and IFRS 19 Subsidiaries without Public Accountability: Disclosures have been issued and are effective for annual periods beginning on or after 1 January 2027.'
        || ' They have not been applied early. IFRS 18 will change the structure of the statement of profit or loss and add disclosure of management-defined performance measures; the directors are assessing its effect.');
  else
    v := v || private.ftxt('Lack of Exchangeability (Amendments to IAS 21) is effective for periods beginning on or after 1 January 2025 and has no material effect on these financial statements.')
      || private.ftxt('The following have been issued but are not yet effective and have not been applied early: Amendments to the Classification and Measurement of Financial Instruments (IFRS 9 and IFRS 7),'
        || ' Contracts Referencing Nature-dependent Electricity and Annual Improvements Volume 11 (all effective 1 January 2026); and IFRS 18 Presentation and Disclosure in Financial Statements and IFRS 19'
        || ' Subsidiaries without Public Accountability: Disclosures (effective 1 January 2027). The directors are assessing their effect.');
  end if;

  -- 3 ----------------------------------------------------------------------
  select string_agg(ac.name || ' ' || case when ac.default_life_months % 12 = 0 then (ac.default_life_months / 12)::text || ' years' else ac.default_life_months::text || ' months' end, '; ' order by ac.cost_account)
    into v_lives from asset_classes ac where ac.depreciates and (private.sum_codes(balc, array[ac.cost_account]) <> 0 or private.sum_codes(balp, array[ac.cost_account]) <> 0);
  v := v || private.fhd('3. Material accounting policies')
    || private.ftxt('The accounting policies below have been applied consistently to all periods presented.')
    || private.fsh('3.1 Revenue from contracts with customers (IFRS 15)')
    || private.ftxt('Revenue is recognised when control of goods or services passes to the customer, at the amount ' || v_name || ' expects to be entitled to, excluding value added tax and net of discounts, rebates and returns.'
         || ' Sales of goods are recognised at a point in time, when the goods are collected by or delivered to the customer. Services are recognised as they are performed.')
    || private.ftxt('Invoices are generally due within ' || coalesce(o.invoice_terms_days, 30) || ' days and contain no significant financing component. Amounts received before goods or services are delivered are contract liabilities until the performance obligation is met.'
         || ' Where customers have a right of return, revenue is reduced by the returns expected and a refund liability is recognised.')
    || private.fsh('3.2 Foreign currency transactions (IAS 21)')
    || private.ftxt('Transactions in foreign currencies are translated into naira at the exchange rate on the date of the transaction. Monetary assets and liabilities in foreign currencies are retranslated at the closing rate at the reporting date.'
         || ' Exchange differences are recognised in profit or loss.')
    || private.fsh('3.3 Financial instruments (IFRS 9)')
    || private.ftxt('Financial assets and liabilities are recognised when ' || v_name || ' becomes party to the contractual provisions of the instrument. Trade receivables without a significant financing component are measured initially at the transaction price; other financial instruments at fair value plus transaction costs.')
    || private.ftxt('Trade and other receivables and cash and cash equivalents are held to collect contractual cash flows that are solely payments of principal and interest, and are measured at amortised cost.'
         || ' Trade and other payables and borrowings are financial liabilities measured at amortised cost.')
    || private.ftxt('Impairment: loss allowances on trade receivables are measured at lifetime expected credit losses using the simplified approach, through a provision matrix based on how long amounts have been overdue,'
         || ' adjusted for forward-looking information. A receivable is written off when there is no reasonable expectation of recovery.')
    || private.ftxt('A financial asset is derecognised when the rights to its cash flows expire or are transferred; a financial liability when it is discharged, cancelled or expires.')
    || private.fsh('3.4 Cash and cash equivalents')
    || private.ftxt('Cash and cash equivalents comprise cash in hand, balances with banks and payment wallets, and short-term deposits with original maturities of three months or less.'
         || ' Bank overdrafts repayable on demand form part of cash management and are included in cash and cash equivalents in the statement of cash flows.')
    || private.fsh('3.5 Inventories (IAS 2)')
    || private.ftxt('Inventories are measured at the lower of cost and net realisable value. Cost is determined on the weighted average basis and includes purchase price, import duties, freight and other costs of bringing inventories to their present location and condition.'
         || ' Net realisable value is the estimated selling price less the costs of completion and sale. Write-downs to net realisable value are recognised in profit or loss in the period they occur.')
    || private.fsh('3.6 Property, plant and equipment (IAS 16)')
    || private.ftxt('Items of property, plant and equipment are measured at cost less accumulated depreciation and impairment losses. Cost includes expenditure directly attributable to bringing the asset into use.'
         || ' Purchases below ' || private.naira(o.capitalisation_threshold) || ' are expensed. Subsequent costs are capitalised only when it is probable that future economic benefits will flow from them; repairs and maintenance are expensed as incurred.')
    || private.ftxt('Depreciation is charged on a straight-line basis over the estimated useful life of each asset from the date it is available for use. Land and assets under construction are not depreciated.'
         || coalesce(' The useful lives used are: ' || v_lives || '.', ''))
    || private.ftxt('Useful lives, residual values and depreciation methods are reviewed at each reporting date. Gains and losses on disposal are recognised in profit or loss.')
    || private.fsh('3.7 Intangible assets (IAS 38)')
    || private.ftxt('Intangible assets acquired separately, such as computer software, are measured at cost less accumulated amortisation and impairment, and amortised on a straight-line basis over their useful lives, generally three to five years.')
    || private.fsh('3.8 Impairment of non-financial assets (IAS 36)')
    || private.ftxt('At each reporting date the carrying amounts of non-financial assets are reviewed for indications of impairment. Where such an indication exists, the recoverable amount is estimated and an impairment loss is recognised in profit or loss for any excess of carrying amount over recoverable amount.')
    || private.fsh('3.9 Leases (IFRS 16)')
    || private.ftxt('At the start of a lease a right-of-use asset and a lease liability are recognised. The lease liability is measured at the present value of the lease payments, discounted at the rate implicit in the lease or the incremental borrowing rate;'
         || ' the right-of-use asset is depreciated over the shorter of the lease term and its useful life. Payments for short-term leases of twelve months or less and leases of low-value assets are expensed on a straight-line basis.')
    || private.fsh('3.10 Employee benefits (IAS 19)')
    || private.ftxt('Salaries, allowances and other short-term benefits are expensed as the related service is provided. ' || (upper(left(v_name, 1)) || substr(v_name, 2)) || ' operates a defined contribution pension scheme under the Pension Reform Act 2014,'
         || ' contributing at least 10% of qualifying emoluments while employees contribute at least 8%. Contributions are expensed when due; there is no further obligation once they are paid.')
    || private.fsh('3.11 Provisions and contingent liabilities (IAS 37)')
    || private.ftxt('A provision is recognised when there is a present obligation from a past event, an outflow of resources is probable and the amount can be estimated reliably. Contingent liabilities are not recognised but are disclosed unless an outflow is remote.')
    || private.fsh('3.12 Taxation (IAS 12)')
    || case when v_nta then private.ftxt('Current tax is the tax expected to be payable on the taxable profit for the period under the Nigeria Tax Act 2025: companies income tax at 30% of assessable profits and the development levy at 4%,'
         || ' together with any top-up to the 15% minimum effective tax rate where it applies. Small companies, as defined in the Act, are exempt from companies income tax and the development levy.')
       else private.ftxt('Current tax is the tax expected to be payable on the taxable profit for the period under the Companies Income Tax Act, at the rate that applies to ' || v_name
         || '''s size (30% for large companies, 20% for medium-sized companies and nil for small companies), together with tertiary education tax at 3% of assessable profits.') end
    || private.ftxt('Deferred tax is recognised on temporary differences between the carrying amounts of assets and liabilities and their tax bases, using rates enacted at the reporting date.'
         || ' Deferred tax assets are recognised only to the extent that taxable profits are expected to be available to use them.')
    || private.ftxt('Revenue, expenses and assets are recognised net of value added tax where the input tax is recoverable. Withholding tax deducted by customers is held as an asset and set against income tax payable.')
    || private.fsh('3.13 Share capital and dividends (IAS 32)')
    || private.ftxt('Ordinary shares are classified as equity. Dividends are recognised as a liability in the period in which they are approved by the shareholders.')
    || private.fsh('3.14 Events after the reporting period (IAS 10)')
    || private.ftxt('Events after the reporting date that provide evidence of conditions at the reporting date are adjusted for. Material events that arise after the reporting date are disclosed.');

  -- 4 ----------------------------------------------------------------------
  v := v || private.fhd('4. Critical accounting judgements and key sources of estimation uncertainty')
    || private.fsh('Expected credit losses on trade receivables')
    || private.ftxt('The loss allowance depends on loss rates by ageing band, taken from collection experience and adjusted for current and forward-looking conditions. At ' || v_ended
         || ' the allowance was ' || private.naira(-private.sum_codes(balc, array['1103'])) || ' against gross trade receivables of ' || private.naira(private.sum_codes(balc, array['1101', '1102'])) || '.')
    || private.fsh('Net realisable value of inventories')
    || private.ftxt('Slow-moving, expired and damaged items are written down to the amount expected to be realised, using recent selling prices and stock counts. Write-downs charged in the period were '
         || private.naira(private.sum_codes(mvc, array['6805'])) || '.')
    || private.fsh('Useful lives of property, plant and equipment')
    || private.ftxt('Depreciation depends on the useful lives and residual values set for each class of asset, which are reviewed each year against how the assets are used and maintained.')
    || private.fsh('Income taxes')
    || private.ftxt('Determining the tax charge requires judgement on the deductibility of expenses and the tax treatment of transactions. Where the final outcome differs from the amounts recorded, the difference affects the tax charge of the period in which it is determined.');

  -- 5 Revenue ------------------------------------------------------------
  v := v || private.fhd('5. Revenue');
  v_mv := (select jsonb_agg(private.fr(m.name, -private.v(mvc, m.code), case when p_pfrom is null then null else -private.v(mvp, m.code) end, 'line', 1) order by m.code)
    from private.acct_meta(p_org) m where m.statement = 'pl' and m.ifrs_line = 'Revenue' and (private.v(mvc, m.code) <> 0 or private.v(mvp, m.code) <> 0));
  v := v || coalesce(v_mv, '[]'::jsonb) || private.fr('Total revenue', private.v(plc, 'Revenue'), private.v(plp, 'Revenue'), 'subtotal', 0);
  v := v || private.fsh('Disaggregation of revenue');
  select coalesce(sum(case when s.doc_type = 'credit_note' then -l.net else l.net end) filter (where l.kind = 'goods' or l.kind = 'delivery'), 0),
         coalesce(sum(case when s.doc_type = 'credit_note' then -l.net else l.net end) filter (where l.kind = 'service'), 0),
         coalesce(sum(case when s.doc_type = 'credit_note' then -l.net else l.net end) filter (where s.export), 0),
         coalesce(sum(case when s.doc_type = 'credit_note' then -l.net else l.net end) filter (where not s.export), 0)
    into v_x, v_y, v_z, v_w
  from sales s join sale_lines l on l.sale_id = s.id where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import'
    and s.issue_date between p_from and p_to;
  v := v || private.fr('Goods, recognised at a point in time', v_x, null, 'line', 1) || private.fl('Services', v_y, null)
    || private.fr('Customers in Nigeria', v_w, null, 'line', 1) || private.fl('Exports to customers outside Nigeria (zero-rated)', v_z, null)
    || coalesce((select jsonb_agg(private.fr('By channel: ' || x.label, x.amt, null, 'line', 1) order by x.amt desc) from (
        select case s.channel when 'till' then 'shop counter' when 'online' then 'online shop' when 'invoice' then 'invoiced sales' when 'van' then 'van sales'
          when 'whatsapp' then 'WhatsApp' when 'phone' then 'phone orders' else s.channel end label,
          sum(case when s.doc_type = 'credit_note' then -s.subtotal else s.subtotal end) amt from sales s
        where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import' and s.issue_date between p_from and p_to group by 1) x where x.amt <> 0), '[]'::jsonb);
  v := v || private.ftxt('Revenue recorded directly in the ledger (for example from bank receipts) is included in the totals above but not in the analysis by sale document.')
    || private.fsh('Contract balances')
    || private.fr('Trade receivables', private.sum_codes(balc, array['1101', '1102']), private.sum_codes(balp, array['1101', '1102']), 'line', 1)
    || private.fr('Contract liabilities (advances from customers)', -private.sum_codes(balc, array['2107']), -private.sum_codes(balp, array['2107']), 'line', 1);

  -- 6 Cost of sales --------------------------------------------------------
  v := v || private.fhd('6. Cost of sales');
  v_mv := (select jsonb_agg(private.fr(m.name, private.v(mvc, m.code), case when p_pfrom is null then null else private.v(mvp, m.code) end, 'line', 1) order by m.code)
    from private.acct_meta(p_org) m where m.statement = 'pl' and m.ifrs_line = 'Cost of sales' and (private.v(mvc, m.code) <> 0 or private.v(mvp, m.code) <> 0));
  v := v || coalesce(v_mv, '[]'::jsonb) || private.fr('Total cost of sales', -private.v(plc, 'Cost of sales'), -private.v(plp, 'Cost of sales'), 'subtotal', 0)
    || private.ftxt('The cost of inventories recognised as an expense was ' || private.naira(private.sum_codes(mvc, array['5400', '5401'])) || '.');

  -- 7 Other income and operating expenses ------------------------------------
  v := v || private.fhd('7. Other income and operating expenses');
  for r in select * from (values (1, 'Other income', array['Other income', 'Other gains and losses'], -1), (2, 'Selling and distribution expenses', array['Selling and distribution expenses'], 1),
      (3, 'Administrative expenses', array['Administrative expenses'], 1), (4, 'Other operating expenses', array['Other operating expenses', 'Other expenses'], 1)) t(k, title, lines, sg) loop
    v_mv := (select jsonb_agg(private.fr(m.name, r.sg * private.v(mvc, m.code), case when p_pfrom is null then null else r.sg * private.v(mvp, m.code) end, 'line', 1) order by m.code)
      from private.acct_meta(p_org) m where m.statement = 'pl' and (m.ifrs_line = any(r.lines) or (r.k = 4 and m.ifrs_line = 'Unclassified'))
        and (private.v(mvc, m.code) <> 0 or private.v(mvp, m.code) <> 0));
    continue when v_mv is null;
    v := v || private.fsh(r.title) || v_mv
      || private.fr('Total ' || lower(r.title), r.sg * -(select coalesce(sum(private.v(plc, x)), 0) from unnest(r.lines) x),
           case when p_pfrom is null then null else r.sg * -(select coalesce(sum(private.v(plp, x)), 0) from unnest(r.lines) x) end, 'subtotal', 0);
  end loop;

  -- 8 Finance income and costs ------------------------------------------------
  v := v || private.fhd('8. Finance income and finance costs');
  v_mv := (select jsonb_agg(private.fr(m.name, case when m.ifrs_line = 'Finance income' then -1 else 1 end * private.v(mvc, m.code),
      case when p_pfrom is null then null else case when m.ifrs_line = 'Finance income' then -1 else 1 end * private.v(mvp, m.code) end, 'line', 1) order by m.ifrs_line desc, m.code)
    from private.acct_meta(p_org) m where m.statement = 'pl' and m.ifrs_line in ('Finance income', 'Finance costs') and (private.v(mvc, m.code) <> 0 or private.v(mvp, m.code) <> 0));
  v := v || coalesce(v_mv, private.ftxt('There was no finance income and no finance costs in the period.'))
    || private.fr('Net finance (costs) / income', private.v(plc, 'Finance income') + private.v(plc, 'Finance costs'), private.v(plp, 'Finance income') + private.v(plp, 'Finance costs'), 'subtotal', 0);

  -- 9 Profit before tax --------------------------------------------------------
  v := v || private.fhd('9. Profit before taxation') || private.ftxt('Profit before taxation is stated after charging / (crediting):')
    || private.fl('Depreciation of property, plant and equipment', private.sum_codes(mvc, array['5204', '6901']), private.sum_codes(mvp, array['5204', '6901']))
    || private.fl('Depreciation of right-of-use assets', private.sum_codes(mvc, array['6902']), private.sum_codes(mvp, array['6902']))
    || private.fl('Amortisation of intangible assets', private.sum_codes(mvc, array['5205', '6903']), private.sum_codes(mvp, array['5205', '6903']))
    || private.fl('Staff costs (note 10)', private.sum_codes(mvc, array['5201', '5304', '6101', '6102', '6103', '6104', '6105', '6106', '6107', '6108', '6111', '6112', '6113', '6114']),
         private.sum_codes(mvp, array['5201', '5304', '6101', '6102', '6103', '6104', '6105', '6106', '6107', '6108', '6111', '6112', '6113', '6114']))
    || private.fl('Directors'' emoluments (note 10)', private.sum_codes(mvc, array['6109', '6110']), private.sum_codes(mvp, array['6109', '6110']))
    || private.fl('Auditors'' remuneration', private.sum_codes(mvc, array['6501']), private.sum_codes(mvp, array['6501']))
    || private.fl('Rent on short-term leases', private.sum_codes(mvc, array['6201', '5301']), private.sum_codes(mvp, array['6201', '5301']))
    || private.fl('Impairment losses on trade receivables and bad debts', private.sum_codes(mvc, array['6801', '6802']), private.sum_codes(mvp, array['6801', '6802']))
    || private.fl('Inventory write-downs', private.sum_codes(mvc, array['6805']), private.sum_codes(mvp, array['6805']))
    || private.fl('Donations', private.sum_codes(mvc, array['6904']), private.sum_codes(mvp, array['6904']))
    || private.fl('Bank charges', private.sum_codes(mvc, array['6701']), private.sum_codes(mvp, array['6701']))
    || private.fl('Net foreign exchange loss / (gain)', private.sum_codes(mvc, array['6703', '6704', '4510', '4511']), private.sum_codes(mvp, array['6703', '6704', '4510', '4511']))
    || private.fl('Net loss / (gain) on disposal of property, plant and equipment', private.sum_codes(mvc, array['6804', '4508']), private.sum_codes(mvp, array['6804', '4508']))
    || private.fl('Interest income', private.sum_codes(mvc, array['4502', '4503']), private.sum_codes(mvp, array['4502', '4503']));

  -- 10 Staff costs and directors' emoluments ---------------------------------------
  v := v || private.fhd('10. Staff costs and directors'' emoluments') || private.fsh('Staff costs')
    || private.fl('Salaries and wages', private.sum_codes(mvc, array['5201', '5304', '6101']), private.sum_codes(mvp, array['5201', '5304', '6101']))
    || private.fl('Allowances and other benefits', private.sum_codes(mvc, array['6102', '6103', '6106', '6108']), private.sum_codes(mvp, array['6102', '6103', '6106', '6108']))
    || private.fl('Employer pension contributions', private.sum_codes(mvc, array['6104']), private.sum_codes(mvp, array['6104']))
    || private.fl('Gratuity', private.sum_codes(mvc, array['6105']), private.sum_codes(mvp, array['6105']))
    || private.fl('Training and development', private.sum_codes(mvc, array['6107']), private.sum_codes(mvp, array['6107']))
    || private.fl('Contract staff and other staff costs', private.sum_codes(mvc, array['6111', '6112', '6113', '6114']), private.sum_codes(mvp, array['6111', '6112', '6113', '6114']))
    || private.fr('Total staff costs', private.sum_codes(mvc, array['5201', '5304', '6101', '6102', '6103', '6104', '6105', '6106', '6107', '6108', '6111', '6112', '6113', '6114']),
         private.sum_codes(mvp, array['5201', '5304', '6101', '6102', '6103', '6104', '6105', '6106', '6107', '6108', '6111', '6112', '6113', '6114']), 'subtotal', 0)
    || case when nullif(n->>'employees_count', '') is not null then private.ftxt('The average number of persons employed during the period was ' || (n->>'employees_count') || '.') else '[]'::jsonb end
    || private.fsh('Directors'' emoluments')
    || private.fr('Fees and other emoluments', private.sum_codes(mvc, array['6109']), private.sum_codes(mvp, array['6109']), 'line', 1)
    || private.fl('Directors'' expenses', private.sum_codes(mvc, array['6110']), private.sum_codes(mvp, array['6110']));

  -- 11 Taxation ------------------------------------------------------------------
  v_rate := case when v_nta then 0.34 else 0.33 end;
  v_pbt := (tc->>'profit_before_tax')::numeric; v_pbtp := (tp->>'profit_before_tax')::numeric;
  v_tax := -private.v(plc, 'Income tax expense'); v_taxp := -private.v(plp, 'Income tax expense');
  v := v || private.fhd('11. Taxation') || private.fsh('11.1 Income tax expense')
    || private.fl('Companies income tax', private.sum_codes(mvc, array['7501']), private.sum_codes(mvp, array['7501']))
    || private.fl(case when v_nta then 'Development levy' else 'Tertiary education tax' end, private.sum_codes(mvc, array['7502']), private.sum_codes(mvp, array['7502']))
    || private.fl('Minimum effective tax rate top-up', private.sum_codes(mvc, array['7505']), private.sum_codes(mvp, array['7505']))
    || private.fl('Under / (over) provision in prior years', private.sum_codes(mvc, array['7504']), private.sum_codes(mvp, array['7504']))
    || private.fl('Deferred tax charge / (credit)', private.sum_codes(mvc, array['7503']), private.sum_codes(mvp, array['7503']))
    || private.fr('Income tax expense', v_tax, case when p_pfrom is null then null else v_taxp end, 'subtotal', 0)
    || private.fsh('11.2 Reconciliation of the tax charge')
    || private.fr('Profit before tax', v_pbt, case when p_pfrom is null then null else v_pbtp end, 'line', 1)
    || private.fr('Tax at the statutory rates (' || case when v_nta then 'companies income tax 30% and development levy 4%' else 'companies income tax 30% and tertiary education tax 3%' end || ')',
         round(greatest(v_pbt, 0) * v_rate, 2), case when p_pfrom is null then null else round(greatest(v_pbtp, 0) * v_rate, 2) end, 'line', 1)
    || private.fr('Effect of exempt income, non-deductible expenses, capital allowances, small-company relief and other differences',
         v_tax - round(greatest(v_pbt, 0) * v_rate, 2), case when p_pfrom is null then null else v_taxp - round(greatest(v_pbtp, 0) * v_rate, 2) end, 'line', 1)
    || private.fr('Income tax expense', v_tax, case when p_pfrom is null then null else v_taxp end, 'subtotal', 0)
    || case when v_pbt > 0 then private.ftxt('The effective tax rate for the period was ' || to_char(round(v_tax / v_pbt * 100, 1), 'FM990.0') || '%.') else '[]'::jsonb end
    || private.fsh('11.3 Current tax payable')
    || private.fr('At the start of the period', -private.sum_codes(balo, array['2208', '2209']), null, 'line', 1)
    || private.fr('Charge for the period', private.sum_codes(crc, array['2208', '2209']), null, 'line', 1)
    || private.fr('Paid and withholding tax credits applied', -private.sum_codes(drc, array['2208', '2209']), null, 'line', 1)
    || private.fr('At the end of the period', -private.sum_codes(balc, array['2208', '2209']), case when v_bpto is null then null else -private.sum_codes(balp, array['2208', '2209']) end, 'subtotal', 0)
    || private.fsh('11.4 Tax assets')
    || private.fr('Withholding tax credit notes held', private.sum_codes(balc, array['1401']), private.sum_codes(balp, array['1401']), 'line', 1)
    || private.fl('Income tax paid in advance', private.sum_codes(balc, array['1403']), private.sum_codes(balp, array['1403']))
    || private.fl('VAT recoverable', private.sum_codes(balc, array['1402']), private.sum_codes(balp, array['1402']))
    || private.fsh('11.5 Deferred tax')
    || case when private.sum_codes(balc, array['1803', '2601']) = 0 and private.sum_codes(balp, array['1803', '2601']) = 0
         then private.ftxt('No deferred tax asset or liability is recognised. Temporary differences between the carrying amounts of assets and their tax written-down values are not material.')
         else private.fr('Deferred tax asset / (liability)', private.sum_codes(balc, array['1803', '2601']), private.sum_codes(balp, array['1803', '2601']), 'line', 1) end;

  -- 12 Property, plant and equipment ------------------------------------------------
  v := v || private.fhd('12. Property, plant and equipment');
  v_x := 0;
  for r in select ac.* from asset_classes ac where private.sum_codes(balo, array[ac.cost_account]) <> 0 or private.sum_codes(drc, array[ac.cost_account]) <> 0
           or private.sum_codes(crc, array[ac.cost_account]) <> 0 order by ac.cost_account loop
    v_x := v_x + 1;
    v := v || private.fr(r.name, null, null, 'subheading', 1)
      || private.fr('Cost at the start of the period', private.sum_codes(balo, array[r.cost_account]), null, 'line', 2)
      || private.fl('Additions', private.sum_codes(drc, array[r.cost_account]), null, 2)
      || private.fl('Disposals', -private.sum_codes(crc, array[r.cost_account]), null, 2)
      || private.fr('Cost at the end of the period', private.sum_codes(balc, array[r.cost_account]), null, 'subtotal', 2);
    if r.accum_account is not null then
      v := v || private.fr('Accumulated depreciation at the start', private.sum_codes(balo, array[r.accum_account]), null, 'line', 2)
        || private.fr('Charge for the period', -private.sum_codes(crc, array[r.accum_account]), null, 'line', 2)
        || private.fl('Eliminated on disposal', private.sum_codes(drc, array[r.accum_account]), null, 2)
        || private.fr('Accumulated depreciation at the end', private.sum_codes(balc, array[r.accum_account]), null, 'subtotal', 2);
    end if;
    v := v || private.fr('Carrying amount', private.sum_codes(balc, array[r.cost_account]) + case when r.accum_account is not null then private.sum_codes(balc, array[r.accum_account]) else 0 end,
      case when v_bpto is null then null else private.sum_codes(balp, array[r.cost_account]) + case when r.accum_account is not null then private.sum_codes(balp, array[r.accum_account]) else 0 end end, 'total', 2);
  end loop;
  if private.sum_range(balc, '1650', '1654') <> 0 or private.sum_range(balp, '1650', '1654') <> 0 then
    v_x := v_x + 1;
    v := v || private.fr('Right-of-use assets', null, null, 'subheading', 1)
      || private.fr('Cost', private.sum_codes(balc, array['1650', '1651', '1652', '1653']), private.sum_codes(balp, array['1650', '1651', '1652', '1653']), 'line', 2)
      || private.fr('Accumulated depreciation', private.sum_codes(balc, array['1654']), private.sum_codes(balp, array['1654']), 'line', 2)
      || private.fr('Carrying amount', private.sum_range(balc, '1650', '1654'), private.sum_range(balp, '1650', '1654'), 'total', 2);
  end if;
  if v_x = 0 then v := v || private.ftxt('No property, plant or equipment was held during the period.'); end if;
  v := v || private.fr('Total carrying amount', private.v(c, 'Property, plant and equipment') + private.v(c, 'Right-of-use assets'),
      case when v_bpto is null then null else private.v(p, 'Property, plant and equipment') + private.v(p, 'Right-of-use assets') end, 'subtotal', 0)
    || private.ftxt(coalesce(n->>'pledged', 'No item of property, plant and equipment was pledged as security for liabilities at the reporting date.'));

  -- 13 Intangible assets -------------------------------------------------------------
  v := v || private.fhd('13. Intangible assets');
  if private.sum_range(balc, '1600', '1610') = 0 and private.sum_range(balp, '1600', '1610') = 0 then
    v := v || private.ftxt('No intangible assets were held at the reporting date' || case when v_bpto is null then '.' else ' or at ' || private.fdate(v_bpto) || '.' end);
  else
    v := v || private.fr('Cost', private.sum_range(balc, '1600', '1608') + private.sum_codes(balc, array['1610']), private.sum_range(balp, '1600', '1608') + private.sum_codes(balp, array['1610']), 'line', 1)
      || private.fr('Accumulated amortisation', private.sum_codes(balc, array['1609']), private.sum_codes(balp, array['1609']), 'line', 1)
      || private.fr('Carrying amount', private.sum_range(balc, '1600', '1610'), private.sum_range(balp, '1600', '1610'), 'subtotal', 0)
      || private.fr('Amortisation charged in the period', private.sum_codes(mvc, array['5205', '6903']), private.sum_codes(mvp, array['5205', '6903']), 'line', 1);
  end if;

  -- 14 to 20: balances behind the statement lines ---------------------------------------
  for r in select * from (values
      ('14. Inventories', array['Inventories'], 'inventories'),
      ('15. Trade and other receivables', array['Trade and other receivables', 'Contract assets', 'Prepayments', 'Other current assets', 'Other current financial assets'], 'receivables'),
      ('16. Cash and cash equivalents', array['Cash and cash equivalents'], 'cash'),
      ('17. Share capital and reserves', array['Share capital', 'Share premium', 'Deposit for shares', 'Other reserves', 'Retained earnings', 'Opening balances to be confirmed'], 'equity'),
      ('18. Borrowings and lease liabilities', array['Borrowings (current)', 'Borrowings (non-current)', 'Lease liabilities (current)', 'Lease liabilities (non-current)'], 'borrowings'),
      ('19. Trade and other payables', array['Trade and other payables', 'Contract liabilities', 'Provisions (current)', 'Other current liabilities', 'Other non-current liabilities'], 'payables'),
      ('20. Statutory liabilities', array['Other statutory liabilities'], 'statutory')) t(title, lines, k) loop
    if r.k = 'cash' then
      -- Accounts in credit are overdrafts, listed separately below.
      v_mv := (select jsonb_agg(private.fr(m.name, greatest(private.v(balc, m.code), 0), case when v_bpto is null then null else greatest(private.v(balp, m.code), 0) end, 'line', 1) order by m.code)
        from private.acct_meta(p_org) m where m.ifrs_line = 'Cash and cash equivalents' and (private.v(balc, m.code) > 0 or private.v(balp, m.code) > 0));
    else
      v_mv := (select jsonb_agg(private.fr(m.name, sg * private.v(balc, m.code), case when v_bpto is null then null else sg * private.v(balp, m.code) end, 'line', 1) order by m.code)
        from (select mm.*, case when mm.code ~ '^(1|9)' then 1 else -1 end sg from private.acct_meta(p_org) mm where mm.ifrs_line = any(r.lines)
              and not (r.k = 'equity' and split_part(mm.code, '-', 1) = '3005')) m
        where private.v(balc, m.code) <> 0 or private.v(balp, m.code) <> 0);
      -- Retained earnings include profit not yet closed to the account.
      if r.k = 'equity' and (private.v(c, 'Retained earnings') <> 0 or private.v(p, 'Retained earnings') <> 0) then
        v_mv := coalesce(v_mv, '[]'::jsonb) || private.fr('Retained earnings', private.v(c, 'Retained earnings'), case when v_bpto is null then null else private.v(p, 'Retained earnings') end, 'line', 1);
      end if;
    end if;
    v := v || private.fhd(r.title);
    if r.k = 'equity' and (o.share_info ? 'issued_shares') then
      v := v || private.ftxt(coalesce('Authorised: ' || to_char((o.share_info->>'authorised_shares')::numeric, 'FM999,999,999,999') || ' ordinary shares'
             || coalesce(' of ₦' || to_char((o.share_info->>'nominal_value')::numeric, case when round((o.share_info->>'nominal_value')::numeric, 2) = (o.share_info->>'nominal_value')::numeric then 'FM999,999,990.00' else 'FM999,999,990.0000' end) || ' each', '') || '. ', '')
           || 'Issued and fully paid: ' || to_char((o.share_info->>'issued_shares')::numeric, 'FM999,999,999,999') || ' ordinary shares'
           || coalesce(' of ₦' || to_char((o.share_info->>'nominal_value')::numeric, case when round((o.share_info->>'nominal_value')::numeric, 2) = (o.share_info->>'nominal_value')::numeric then 'FM999,999,990.00' else 'FM999,999,990.0000' end) || ' each', '') || '.');
    end if;
    if v_mv is null then
      v := v || private.ftxt(case r.k when 'borrowings' then 'There were no borrowings or lease liabilities at the reporting date.'
        when 'inventories' then 'No inventories were held at the reporting date.' when 'statutory' then 'There were no statutory liabilities outstanding at the reporting date.'
        else 'There was no balance at the reporting date.' end);
    else
      v := v || v_mv || private.fr('Total', (select coalesce(sum(private.v(c, x)), 0) from unnest(r.lines) x),
        case when v_bpto is null then null else (select coalesce(sum(private.v(p, x)), 0) from unnest(r.lines) x) end, 'subtotal', 0);
    end if;
    if r.k = 'inventories' and v_mv is not null then
      v := v || private.ftxt('Inventories recognised as an expense in cost of sales during the period amounted to ' || private.naira(private.sum_codes(mvc, array['5400', '5401']))
        || '. Write-downs to net realisable value of ' || private.naira(private.sum_codes(mvc, array['6805'])) || ' were recognised in the period.');
    elsif r.k = 'receivables' then
      if private.v(c, '_customer_credit_reclass') > 0 then
        v := v || private.ftxt('Trade receivables include ' || private.naira(private.v(c, '_customer_credit_reclass')) || ' for customers in credit, which is shown within contract liabilities.');
      end if;
      v := v || private.fsh('Movement in the loss allowance')
        || private.fr('At the start of the period', -private.sum_codes(balo, array['1103']), null, 'line', 1)
        || private.fr('Charged to profit or loss', private.sum_codes(crc, array['1103']), null, 'line', 1)
        || private.fr('Written off or released', -private.sum_codes(drc, array['1103']), null, 'line', 1)
        || private.fr('At the end of the period', -private.sum_codes(balc, array['1103']), null, 'subtotal', 0)
        || private.fsh('Ageing of trade receivables from invoices at ' || v_ended);
      select coalesce(sum(bal) filter (where age <= 0), 0), coalesce(sum(bal) filter (where age between 1 and 30), 0), coalesce(sum(bal) filter (where age between 31 and 90), 0),
             coalesce(sum(bal) filter (where age > 90), 0) into v_x, v_y, v_z, v_w
      from (select s.total - s.amount_paid - s.credited bal, p_to - coalesce(s.due_date, s.issue_date) age from sales s
            where s.org_id = p_org and s.status in ('open', 'partially_paid') and s.journal_id is not null and s.issue_date <= p_to) d;
      v := v || private.fr('Not yet due', v_x, null, 'line', 1) || private.fr('1 to 30 days overdue', v_y, null, 'line', 1)
        || private.fr('31 to 90 days overdue', v_z, null, 'line', 1) || private.fr('More than 90 days overdue', v_w, null, 'line', 1)
        || private.fr('Open invoices', v_x + v_y + v_z + v_w, null, 'subtotal', 0);
    elsif r.k = 'cash' then
      if private.v(c, 'Bank overdrafts') <> 0 or private.v(p, 'Bank overdrafts') <> 0 then
        v := v || private.fsh('Bank overdrafts, shown under current liabilities')
          || coalesce((select jsonb_agg(private.fr(m.name, -least(private.v(balc, m.code), 0), case when v_bpto is null then null else -least(private.v(balp, m.code), 0) end, 'line', 1) order by m.code)
               from private.acct_meta(p_org) m where m.ifrs_line = 'Cash and cash equivalents' and (private.v(balc, m.code) < 0 or private.v(balp, m.code) < 0)), '[]'::jsonb)
          || private.fr('Total bank overdrafts', private.v(c, 'Bank overdrafts'), case when v_bpto is null then null else private.v(p, 'Bank overdrafts') end, 'subtotal', 0)
          || private.ftxt('Overdrawn accounts are repayable on demand and form part of day-to-day cash management, so the statement of cash flows counts them within cash (IAS 7.8).');
      end if;
      v := v || private.fr('Cash and cash equivalents in the statement of cash flows', private.v(c, 'Cash and cash equivalents') - private.v(c, 'Bank overdrafts'),
        case when v_bpto is null then null else private.v(p, 'Cash and cash equivalents') - private.v(p, 'Bank overdrafts') end, 'subtotal', 0);
    elsif r.k = 'equity' then
      v_x := private.v(private.sofp_map(p_org, p_from - 1), 'Retained earnings');
      v_y := private.v(plc, 'Items that will not be reclassified to profit or loss') + private.v(plc, 'Items that may be reclassified to profit or loss')
        + private.v(plc, 'Income tax relating to other comprehensive income');
      v_z := -private.sum_codes(drc, array['3005']);
      v := v || private.fsh('Retained earnings')
        || private.fr('At the start of the period', v_x, null, 'line', 1)
        || private.fr('Profit for the period', (tc->>'profit')::numeric, null, 'line', 1)
        || private.fl('Other comprehensive income', v_y, null)
        || private.fl('Dividends paid', v_z, null)
        || private.fl('Transfers and other movements', private.v(c, 'Retained earnings') - v_x - (tc->>'profit')::numeric - v_y - v_z, null)
        || private.fr('At the end of the period', private.v(c, 'Retained earnings'), null, 'subtotal', 0);
      if private.v(c, 'Opening balances to be confirmed') <> 0 then
        v := v || private.ftxt('Opening balances of ' || private.naira(private.v(c, 'Opening balances to be confirmed')) || ' were brought into the books without a full split between share capital and reserves. They are to be confirmed and reclassified.');
      end if;
    end if;
  end loop;

  -- 21 Related parties -----------------------------------------------------------------
  v := v || private.fhd('21. Related party transactions')
    || private.ftxt('The directors' || coalesce(' (' || v_dirs || ')', '') || ' are the key management personnel of ' || v_name || '. Their emoluments are shown in note 10.')
    || private.fl('Amounts owed by directors (directors'' current accounts)', private.sum_codes(balc, array['1105']), private.sum_codes(balp, array['1105']))
    || private.fl('Amounts owed by other related parties', private.sum_codes(balc, array['1108']), private.sum_codes(balp, array['1108']))
    || private.fl('Amounts owed to directors (directors'' current accounts)', -private.sum_codes(balc, array['2106']), -private.sum_codes(balp, array['2106']))
    || private.fl('Amounts owed to other related parties', -private.sum_codes(balc, array['2105']), -private.sum_codes(balp, array['2105']))
    || private.fl('Loans from shareholders and related parties', -private.sum_codes(balc, array['2502']), -private.sum_codes(balp, array['2502']))
    || private.ftxt('Balances with related parties are unsecured, interest-free and repayable on demand unless stated otherwise. No guarantees were given or received.');

  -- 22 Financial instruments and risk management -----------------------------------------
  v_cash := private.v(c, 'Cash and cash equivalents');
  v := v || private.fhd('22. Financial instruments and risk management') || private.fsh('22.1 Categories of financial instruments')
    || private.fr('Financial assets at amortised cost', null, null, 'line', 1)
    || private.fr('Trade receivables, net of loss allowance', private.sum_codes(balc, array['1101', '1102', '1103']), private.sum_codes(balp, array['1101', '1102', '1103']), 'line', 2)
    || private.fl('Other receivables', private.sum_codes(balc, array['1104', '1105', '1107', '1108', '1110']), private.sum_codes(balp, array['1104', '1105', '1107', '1108', '1110']), 2)
    || private.fr('Cash and cash equivalents', v_cash, private.v(p, 'Cash and cash equivalents'), 'line', 2)
    || private.fr('Financial liabilities at amortised cost', null, null, 'line', 1)
    || private.fr('Trade payables and accruals', -private.sum_codes(balc, array['2101', '2102', '2103']), -private.sum_codes(balp, array['2101', '2102', '2103']), 'line', 2)
    || private.fl('Other payables', -private.sum_codes(balc, array['2104', '2105', '2106', '2108']), -private.sum_codes(balp, array['2104', '2105', '2106', '2108']), 2)
    || private.fl('Borrowings, lease liabilities and overdrafts', -private.sum_range(balc, '2301', '2306') - private.sum_range(balc, '2501', '2504'),
         -private.sum_range(balp, '2301', '2306') - private.sum_range(balp, '2501', '2504'), 2)
    || private.ftxt('The carrying amounts of these financial assets and liabilities approximate their fair values because of their short-term nature.')
    || private.fsh('22.2 Credit risk')
    || private.ftxt('Credit risk is the risk of loss if a customer or bank fails to meet its obligations. It arises mainly on trade receivables and bank balances, whose carrying amounts are the maximum exposure.'
         || ' Credit limits are set for customers buying on account, overdue balances are followed up through statements and reminders, and bank balances are held with licensed Nigerian banks and payment institutions.');
  select coalesce(sum(b) filter (where rk <= 5), 0), coalesce(sum(b), 0) into v_x, v_y from (
    select sum(l.debit - l.credit) b, row_number() over (order by sum(l.debit - l.credit) desc) rk from journal_lines l join journals j on j.id = l.journal_id
    where l.org_id = p_org and l.party_type = 'customer' and split_part(l.account_code, '-', 1) in ('1101', '1102') and j.entry_date <= p_to group by l.party_id having sum(l.debit - l.credit) > 0) x;
  if v_y > 0 then
    v := v || private.ftxt('The five largest customer balances make up ' || to_char(round(v_x / v_y * 100, 1), 'FM990.0') || '% of trade receivables.');
  end if;
  v := v || private.fsh('22.3 Liquidity risk')
    || private.ftxt('Liquidity risk is the risk of being unable to pay obligations as they fall due. Cash is forecast thirteen weeks ahead and payments are scheduled against expected collections.'
         || ' At ' || v_ended || ' current assets were ' || private.naira(v_ca) || ' against current liabilities of ' || private.naira(v_cl)
         || case when v_cl > 0 then ' (a current ratio of ' || to_char(round(v_ca / v_cl, 2), 'FM990.00') || ')' else '' end || '.')
    || private.fr('Due within one year: trade and other payables and current borrowings', -private.sum_codes(balc, array['2101', '2102', '2103', '2104', '2105', '2106', '2108'])
         - private.sum_range(balc, '2301', '2306'), null, 'line', 1)
    || private.fl('Due after one year: non-current borrowings and lease liabilities', -private.sum_range(balc, '2501', '2504'), null)
    || private.fsh('22.4 Market risk')
    || case when private.sum_codes(balc, array['1013', '1102', '2102']) <> 0 or private.sum_codes(balp, array['1013', '1102', '2102']) <> 0 then
         private.ftxt('Currency risk arises on balances in foreign currencies, which are retranslated at the closing rate. The naira equivalent of foreign currency balances at the reporting date was:')
         || private.fl('Domiciliary bank balances', private.sum_codes(balc, array['1013']), private.sum_codes(balp, array['1013']))
         || private.fl('Receivables from foreign customers', private.sum_codes(balc, array['1102']), private.sum_codes(balp, array['1102']))
         || private.fl('Payables to foreign suppliers', -private.sum_codes(balc, array['2102']), -private.sum_codes(balp, array['2102']))
       else private.ftxt('No material balances were held in foreign currencies at the reporting date, so exposure to currency risk is limited.') end
    || private.ftxt(case when private.sum_range(balc, '2301', '2306') + private.sum_range(balc, '2501', '2504') <> 0
         then 'Interest rate risk arises on borrowings. Rates and repayment terms are reviewed before facilities are taken or renewed.'
         else 'There were no interest-bearing borrowings at the reporting date, so exposure to interest rate risk is limited.' end);

  -- 23 Capital management ---------------------------------------------------------------
  v_debt := -(private.sum_range(balc, '2301', '2306') + private.sum_range(balc, '2501', '2504'));
  v := v || private.fhd('23. Capital management')
    || private.ftxt('The directors manage capital, being equity and net debt, to keep ' || v_name || ' able to continue as a going concern and to fund its growth. Net debt and equity are reviewed with the management accounts.')
    || private.fr('Borrowings, lease liabilities and overdrafts', v_debt, null, 'line', 1)
    || private.fr('Less cash and cash equivalents', -v_cash, null, 'line', 1)
    || private.fr('Net debt / (net cash)', v_debt - v_cash, null, 'subtotal', 0)
    || private.fr('Total equity', v_eq, null, 'line', 1)
    || case when v_eq > 0 and v_debt - v_cash > 0 then private.ftxt('Net debt to equity was ' || to_char(round((v_debt - v_cash) / v_eq * 100, 1), 'FM990.0') || '% at ' || v_ended || '.') else '[]'::jsonb end;

  -- 24 to 26 ---------------------------------------------------------------------------
  v := v || private.fhd('24. Contingent liabilities and commitments')
    || private.ftxt(coalesce(n->>'contingencies', 'There were no contingent liabilities at the reporting date, including pending litigation, that require disclosure.'))
    || private.ftxt(coalesce(n->>'commitments', 'There were no capital commitments contracted for but not provided at the reporting date.'))
    || private.fhd('25. Events after the reporting period')
    || private.ftxt(coalesce(n->>'events_after', 'There were no events after the reporting date that require adjustment to, or disclosure in, these financial statements.'))
    || private.fhd('26. Approval of the financial statements')
    || private.ftxt('These financial statements were approved by the Board of Directors and authorised for issue on '
         || coalesce(private.fdate(nullif(n->>'approved_on', '')::date), '.......................................') || '.');
  if private.v(c, 'Unreconciled balances (assets)') <> 0 or private.v(c, 'Unreconciled balances (liabilities)') <> 0 then
    v := v || private.fhd('27. Unreconciled balances')
      || private.fr('Unreconciled balances (assets)', private.v(c, 'Unreconciled balances (assets)'), private.v(p, 'Unreconciled balances (assets)'), 'line', 1)
      || private.fr('Unreconciled balances (liabilities)', private.v(c, 'Unreconciled balances (liabilities)'), private.v(p, 'Unreconciled balances (liabilities)'), 'line', 1)
      || private.ftxt('These are bank movements not yet explained and money between accounts. They must be cleared before the financial statements are signed.');
  end if;
  return v;
end $function$;

-- public.pit_year: from 2024 accounts.
CREATE OR REPLACE FUNCTION public.pit_year(p_org uuid, p_year integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare acc jsonb; py public.pit_years; comp jsonb; v_cit jsonb; v_draft boolean; v_all boolean; v_books boolean; p record;
begin
  if private.filing_unpaid(p_org, p_year) then return private.filing_unpaid_json(p_org, p_year); end if;
  acc := private.pit_access(p_org);
  if p_year < 2024 or p_year > 2100 then raise exception 'Counta prepares personal income tax from 2024 accounts.'; end if;
  v_all := (acc->>'all')::boolean;
  v_books := (acc->>'books')::boolean or v_all;
  select * into py from pit_years where org_id = p_org and accounting_year = p_year;
  v_draft := coalesce(py.status, 'draft') = 'draft';
  select pfrom, pto into p from private.cit_period(p_org, p_year);
  comp := private.pit_live(p_org, p_year, private.pit_run(p_org, p_year));
  if private.can_handle_money(p_org) then
    v_cit := public.cit_year(p_org, p_year);
    v_cit := v_cit || jsonb_build_object('can_edit', coalesce((v_cit->>'can_edit')::boolean, false) and v_draft);
  end if;
  return jsonb_build_object('kind', private.income_tax_kind(p_org, p_year), 'computation', private.pit_mask(comp, acc), 'state', private.pit_state(p_org, p_year),
    'row', jsonb_build_object('status', coalesce(py.status, 'draft'), 'settings', coalesce(py.settings, '{}'::jsonb), 'soa_path', py.soa_path,
      'approved_at', py.approved_at, 'approved_by', (select display_name from members where id = py.approved_by), 'attested', py.snapshot->'attested',
      'updated_at', py.updated_at),
    'cit', v_cit,
    'people_all', (select coalesce(jsonb_agg(jsonb_build_object('id', pp.id, 'name', pp.name, 'tin', pp.tin, 'member_id', pp.member_id, 'active', pp.active,
        'source', pp.source) order by pp.sort, pp.created_at), '[]'::jsonb) from pit_people pp where pp.org_id = p_org),
    'members', case when v_all then (select coalesce(jsonb_agg(jsonb_build_object('id', mm.id, 'name', mm.display_name, 'role', mm.role) order by mm.display_name), '[]'::jsonb)
        from members mm where mm.org_id = p_org and mm.status = 'active' and mm.practice_id is null) end,
    'locations', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'state', l.state, 'authority', private.state_code(l.state), 'is_main', l.is_main)
        order by l.is_main desc, l.name), '[]'::jsonb) from locations l where l.org_id = p_org),
    'authorities', (select jsonb_agg(jsonb_build_object('code', a.code, 'state', a.state, 'name', a.name, 'short_name', a.short_name) order by a.sort) from tax_authorities a),
    'needs_setup', not exists (select 1 from pit_people where org_id = p_org),
    'suggested', case when not exists (select 1 from pit_people where org_id = p_org) then
        coalesce((select jsonb_agg(d->>'name') from orgs o, jsonb_array_elements(case when jsonb_typeof(o.directors) = 'array' then o.directors else '[]'::jsonb end) d
                  where o.id = p_org and coalesce(d->>'name', '') <> ''), '[]'::jsonb) end,
    'can', jsonb_build_object('see_all', v_all, 'edit_business', v_books and v_draft, 'edit_people', v_all and v_draft,
      'edit_self', acc->>'me' is not null and v_draft, 'approve', v_all, 'owner', (acc->>'owner')::boolean),
    'me', acc->'me', 'period', jsonb_build_object('from', p.pfrom, 'to', p.pto), 'relief_needs', private.pit_relief_needs(), 'staff_roles', private.pit_staff_roles(),
    'bot_authorities', to_jsonb(private.pit_bot_authorities()),
    'logins', case when v_all then (select coalesce(jsonb_agg(jsonb_build_object('authority', l.authority, 'status', l.status, 'tax_office', l.tax_office,
        'username_hint', l.username_hint)), '[]'::jsonb) from portal_logins l where l.org_id = p_org) end);
end $function$;

-- public.pit_years: from 2024 accounts.
CREATE OR REPLACE FUNCTION public.pit_years(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare acc jsonb; v_now int := private.cit_year_of(p_org, private.local_day(p_org, now())); v_kind text; ch jsonb; v_all boolean;
begin
  acc := private.pit_access(p_org);
  v_all := (acc->>'all')::boolean;
  v_kind := private.income_tax_kind(p_org, v_now);
  if v_kind not in ('sole', 'partnership') or v_now < 2024 then
    return jsonb_build_object('kind', v_kind, 'years', '[]'::jsonb, 'current_year', v_now, 'first_year', private.pit_first_year(p_org));
  end if;
  ch := private.pit_chain(p_org, v_now);
  return jsonb_build_object('kind', v_kind, 'current_year', v_now, 'first_year', private.pit_first_year(p_org),
    'years', (select coalesce(jsonb_agg(jsonb_build_object('year', (c->>'year')::int, 'yoa', (c->>'yoa')::int, 'from', c->>'from', 'to', c->>'to',
        'regime', c->>'regime', 'kind', c->>'kind', 'has_data', coalesce((c->>'has_data')::boolean, false) and not private.filing_unpaid(p_org, (c->>'year')::int), 'locked', private.filing_unpaid(p_org, (c->>'year')::int), 'ended', (c->>'ended')::boolean,
        'state', private.pit_state(p_org, (c->>'year')::int), 'due', c->>'due', 'people', (c->'figures'->>'people')::int,
        'tax', case when v_all and not private.filing_unpaid(p_org, (c->>'year')::int) then (c->'figures'->>'tax')::numeric end, 'payable', case when v_all and not private.filing_unpaid(p_org, (c->>'year')::int) then (c->'figures'->>'payable')::numeric end,
        'assessable', case when not private.filing_unpaid(p_org, (c->>'year')::int) then (c->'figures'->>'assessable')::numeric end,
        'blocks', case when private.filing_unpaid(p_org, (c->>'year')::int) then 0 else (select count(*) from jsonb_array_elements(coalesce(c->'checks', '[]'::jsonb)) k where k->>'severity' = 'block') end)
      order by (c->>'year')::int desc), '[]'::jsonb) from jsonb_array_elements(ch) c where c ? 'people' or not coalesce((c->>'has_data')::boolean, true)));
end $function$;

-- public.save_pit_year: from 2024 accounts.
CREATE OR REPLACE FUNCTION public.save_pit_year(p_org uuid, p_year integer, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare acc jsonb; m public.members; py public.pit_years; v_set jsonb; x record; v_cells text[]; v_n numeric; s jsonb; v_staff jsonb; v_tin text;
begin
  acc := private.pit_access(p_org);
  m := private.require(p_org, null);
  if not ((acc->>'all')::boolean or (acc->>'books')::boolean) then raise exception 'Your role does not allow this (keep books).' using errcode = '42501'; end if;
  if p_year < 2024 or p_year > 2100 then raise exception 'Choose the year.'; end if;
  insert into pit_years (org_id, accounting_year, updated_by) values (p_org, p_year, m.id) on conflict (org_id, accounting_year) do nothing;
  select * into py from pit_years where org_id = p_org and accounting_year = p_year for update;
  if coalesce(py.status, 'draft') <> 'draft' then raise exception '%', private.pit_locked(p_year, py.status); end if;
  v_set := coalesce(py.settings, '{}'::jsonb);
  for x in select key, value from jsonb_each(p) loop
    if x.key not in ('mixed_use', 'mixed_use_reviewed', 'soa_path', 'notes', 'staff', 'staff_reviewed') then raise exception 'Unknown setting %.', x.key; end if;
  end loop;
  if p ? 'mixed_use' then
    if jsonb_typeof(p->'mixed_use') <> 'object' then raise exception 'Mixed use is {line: business share %%}.'; end if;
    v_cells := array(select l->>'cell' from jsonb_array_elements((private.pit_rulebook(p_year)).config->'business'->'mixed_use'->'lines') l);
    for x in select key, value from jsonb_each(p->'mixed_use') loop
      if not x.key = any(v_cells) then raise exception 'That line is not one the rule book treats as mixed use.'; end if;
      if jsonb_typeof(x.value) = 'null' then v_set := jsonb_set(v_set, '{mixed_use}', coalesce(v_set->'mixed_use', '{}'::jsonb) - x.key); continue; end if;
      v_n := private.num(x.value #>> '{}');
      if v_n is null or v_n < 0 or v_n > 100 then raise exception 'The business share of a mixed-use expense is between 0%% and 100%%.'; end if;
      v_set := jsonb_set(v_set, '{mixed_use}', coalesce(v_set->'mixed_use', '{}'::jsonb) || jsonb_build_object(x.key, round(v_n, 2)));
    end loop;
    v_set := v_set || jsonb_build_object('mixed_use_reviewed', true, 'mixed_use_by', m.display_name, 'mixed_use_at', now());
  end if;
  if p ? 'mixed_use_reviewed' then v_set := v_set || jsonb_build_object('mixed_use_reviewed', coalesce((p->>'mixed_use_reviewed')::boolean, false)); end if;
  if p ? 'notes' then v_set := case when coalesce(trim(p->>'notes'), '') = '' then v_set - 'notes' else v_set || jsonb_build_object('notes', left(trim(p->>'notes'), 2000)) end; end if;
  if p ? 'staff' then
    if jsonb_typeof(p->'staff') <> 'array' then raise exception 'Staff is a list.'; end if;
    if jsonb_array_length(p->'staff') > 500 then raise exception 'At most 500 employees.'; end if;
    v_staff := '[]'::jsonb;
    for s in select value from jsonb_array_elements(p->'staff') loop
      continue when coalesce(trim(s->>'name'), '') = '' and coalesce(private.num(s->>'annual_pay'), 0) = 0 and coalesce(trim(s->>'role'), '') = '';
      if length(trim(coalesce(s->>'name', ''))) < 2 then raise exception 'Enter each employee''s name.'; end if;
      if private.num(s->>'annual_pay') is null or private.num(s->>'annual_pay') < 0 then raise exception 'Enter %''s pay for the year.', trim(s->>'name'); end if;
      v_tin := nullif(regexp_replace(coalesce(s->>'tin', ''), '\s', '', 'g'), '');
      if v_tin is not null and v_tin !~ '^[0-9][0-9-]{6,15}$' then raise exception 'A Tax ID is digits (with dashes, if any).'; end if;
      v_staff := v_staff || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('name', left(trim(s->>'name'), 120),
        'role', left(nullif(trim(coalesce(s->>'role', '')), ''), 80), 'annual_pay', round(private.num(s->>'annual_pay'), 2), 'tin', v_tin)));
    end loop;
    v_set := v_set || jsonb_build_object('staff_reviewed', true, 'staff_by', m.display_name, 'staff_at', now());
  end if;
  if p ? 'staff_reviewed' then
    v_set := v_set || jsonb_build_object('staff_reviewed', coalesce((p->>'staff_reviewed')::boolean, false), 'staff_by', m.display_name, 'staff_at', now());
  end if;
  if p ? 'soa_path' then
    if nullif(p->>'soa_path', '') is not null and split_part(p->>'soa_path', '/', 1) <> p_org::text then raise exception 'That file is not this business''s.'; end if;
  end if;
  update pit_years set settings = v_set, soa_path = case when p ? 'soa_path' then nullif(p->>'soa_path', '') else soa_path end,
    staff = case when p ? 'staff' then v_staff else staff end,
    updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year;
  return public.pit_year(p_org, p_year);
end $function$;

-- public.save_pit_person_year: from 2024 accounts.
CREATE OR REPLACE FUNCTION public.save_pit_person_year(p_org uuid, p_year integer, p_person uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare acc jsonb; m public.members; py public.pit_years; d jsonb; k text; v_kinds text[]; x jsonb; v_oi jsonb := '[]'::jsonb; v_rl jsonb := '{}'::jsonb; v_n numeric;
  v_self_keys text[] := array['residence', 'resident', 'reliefs', 'other_income', 'opening', 'accommodation', 'pension_details', 'relief_docs', 'household_staff'];
  v_field text; a jsonb; v_acc jsonb; v_pen jsonb; v_rsa text; y public.pit_person_years; v_docs jsonb; v_needs jsonb := private.pit_relief_needs();
  v_ids text[]; v_list jsonb; f jsonb; v_pre text; v_at text; per record; v_net numeric; v_hs jsonb; v_reg boolean; v_pid text;
begin
  acc := private.pit_access(p_org);
  m := private.require(p_org, null);
  if p_year < 2024 or p_year > 2100 then raise exception 'Choose the year.'; end if;
  if not exists (select 1 from pit_people where id = p_person and org_id = p_org) then raise exception 'That person is not in this business.'; end if;
  if not (acc->>'all')::boolean then
    if acc->>'me' is distinct from p_person::text then raise exception 'Only those who file tax change another person''s return.' using errcode = '42501'; end if;
    for k in select jsonb_object_keys(p) loop
      if not k = any(v_self_keys) then raise exception 'Your share, role, office and pay are set by whoever files the business''s tax.' using errcode = '42501'; end if;
    end loop;
  end if;
  for k in select jsonb_object_keys(p) loop
    if not k = any(array['share_pct', 'role', 'office_location_id', 'residence', 'resident', 'remuneration', 'remuneration_note', 'included', 'opening', 'reliefs', 'other_income',
                         'accommodation', 'pension_details', 'relief_docs', 'household_staff']) then
      raise exception 'Unknown field %.', k;
    end if;
  end loop;
  select * into py from pit_years where org_id = p_org and accounting_year = p_year;
  if coalesce(py.status, 'draft') <> 'draft' then raise exception '%', private.pit_locked(p_year, py.status); end if;
  select pfrom, pto into per from private.cit_period(p_org, p_year);

  -- Validate.
  if p ? 'share_pct' and (private.num(p->>'share_pct') is null or private.num(p->>'share_pct') < 0 or private.num(p->>'share_pct') > 100) then
    raise exception 'A share of the profit is between 0%% and 100%%.';
  end if;
  if p ? 'role' and p->>'role' not in ('proprietor', 'active', 'dormant') then raise exception 'Choose whether the partner works in the business or is dormant.'; end if;
  if nullif(p->>'office_location_id', '') is not null and not exists (select 1 from locations where id = (p->>'office_location_id')::uuid and org_id = p_org) then
    raise exception 'Choose one of the business''s offices.';
  end if;
  if nullif(p->>'residence', '') is not null and not exists (select 1 from tax_authorities where code = p->>'residence' and kind = 'state') then
    raise exception 'Choose the state.';
  end if;
  if p ? 'remuneration' and (private.num(p->>'remuneration') is null or private.num(p->>'remuneration') < 0) then raise exception 'Enter the pay as an amount of zero or more.'; end if;
  if p ? 'reliefs' then
    if jsonb_typeof(p->'reliefs') <> 'object' then raise exception 'Reliefs are {pension, nhf, ...}.'; end if;
    for k in select jsonb_object_keys(p->'reliefs') loop
      if not k = any(array['pension', 'nhf', 'nhis', 'life_insurance', 'home_loan_interest', 'gratuity', 'rent_paid']) then raise exception 'Unknown relief %.', k; end if;
      continue when jsonb_typeof(p->'reliefs'->k) = 'null' or coalesce(p->'reliefs'->>k, '') = '';
      v_n := private.num(p->'reliefs'->>k);
      if v_n is null or v_n < 0 then raise exception 'Enter % as an amount of zero or more.', replace(k, '_', ' '); end if;
      if v_n > 0 then v_rl := jsonb_set(v_rl, array[k], to_jsonb(round(v_n, 2))); end if;
    end loop;
  end if;
  if p ? 'other_income' then
    if jsonb_typeof(p->'other_income') <> 'array' then raise exception 'Other income is a list.'; end if;
    v_kinds := array(select jsonb_array_elements_text((private.pit_rulebook(p_year)).config->'other_income'->'kinds'));
    for x in select value from jsonb_array_elements(p->'other_income') loop
      continue when coalesce(private.num(x->>'amount'), 0) = 0 and coalesce(trim(x->>'label'), '') = '';
      if not coalesce(x->>'kind', '') = any(v_kinds) then raise exception 'Choose what kind of income "%" is.', coalesce(nullif(trim(x->>'label'), ''), x->>'kind', 'this line'); end if;
      if private.num(x->>'amount') is null or private.num(x->>'amount') <= 0 then raise exception 'Enter the amount of "%".', coalesce(nullif(x->>'label', ''), x->>'kind'); end if;
      if coalesce(private.num(x->>'tax_deducted'), 0) < 0 or coalesce(private.num(x->>'tax_deducted'), 0) > private.num(x->>'amount') then
        raise exception 'The tax deducted from "%" is more than the income.', coalesce(nullif(x->>'label', ''), x->>'kind');
      end if;
      v_field := nullif(x->>'field', '');
      if v_field is not null and not ((x->>'kind' = 'employment' and v_field in ('salary', 'commission', 'allowance'))
                                      or (x->>'kind' = 'pension_gratuity' and v_field in ('pension', 'annuity', 'gratuities'))) then
        raise exception 'The return has no % line for that kind of income.', v_field;
      end if;
      v_oi := v_oi || jsonb_build_array(jsonb_build_object('kind', x->>'kind', 'label', left(coalesce(nullif(trim(x->>'label'), ''), initcap(replace(x->>'kind', '_', ' '))), 120),
        'amount', round(private.num(x->>'amount'), 2), 'tax_deducted', round(coalesce(private.num(x->>'tax_deducted'), 0), 2))
        || case when x ? 'final_tax' and jsonb_typeof(x->'final_tax') = 'boolean' then jsonb_build_object('final_tax', (x->>'final_tax')::boolean) else '{}'::jsonb end
        || case when v_field is not null then jsonb_build_object('field', v_field) else '{}'::jsonb end);
    end loop;
    if jsonb_array_length(v_oi) > 40 then raise exception 'At most 40 lines of other income.'; end if;
  end if;
  if p ? 'opening' and (jsonb_typeof(p->'opening') <> 'object' or coalesce(private.num(p->'opening'->>'losses_bf'), 0) < 0 or coalesce(private.num(p->'opening'->>'ca_bf'), 0) < 0) then
    raise exception 'Amounts brought forward are zero or more.';
  end if;

  -- Where the person lived: the portal's accommodation disclosure.
  if p ? 'accommodation' then
    a := p->'accommodation';
    if jsonb_typeof(a) <> 'object' then raise exception 'The accommodation is {address, type, occupancy, ...}.'; end if;
    for k in select jsonb_object_keys(a) loop
      if not k = any(array['address', 'type', 'occupancy', 'landlord_name', 'landlord_id', 'landlord_address', 'rent_paid', 'rent_paid_by_employer', 'started_on', 'ended_on']) then
        raise exception 'Unknown accommodation field %.', k;
      end if;
    end loop;
    if nullif(a->>'type', '') is not null and a->>'type' not in ('flat', 'room', 'bungalow', 'duplex', 'terrace', 'detached', 'other') then raise exception 'Choose the kind of home.'; end if;
    if nullif(a->>'occupancy', '') is not null and a->>'occupancy' not in ('tenant', 'owner', 'employer', 'family') then raise exception 'Choose whether they rent the home, own it, or live there another way.'; end if;
    for k in select unnest(array['rent_paid', 'rent_paid_by_employer']) loop
      if coalesce(a->>k, '') <> '' and (private.num(a->>k) is null or private.num(a->>k) < 0) then raise exception 'Enter the rent as an amount of zero or more.'; end if;
    end loop;
    if coalesce(private.num(a->>'rent_paid_by_employer'), 0) > coalesce(private.num(a->>'rent_paid'), 0) and a->>'occupancy' = 'tenant' then
      raise exception 'The rent an employer paid is more than the rent.';
    end if;
    for k in select unnest(array['started_on', 'ended_on']) loop
      if coalesce(a->>k, '') <> '' and a->>k !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Enter the dates as days.'; end if;
    end loop;
    if coalesce(a->>'started_on', '') <> '' and (a->>'started_on')::date > per.pto then raise exception 'They moved in after the year ended: enter the home they lived in during %.', p_year; end if;
    if coalesce(a->>'ended_on', '') <> '' and (a->>'ended_on')::date < coalesce(nullif(a->>'started_on', '')::date, per.pfrom) then raise exception 'They moved out before they moved in.'; end if;
    if coalesce(a->>'ended_on', '') <> '' and (a->>'ended_on')::date < per.pfrom then raise exception 'They moved out before the year began: enter the home they lived in during %.', p_year; end if;
    v_acc := jsonb_strip_nulls(jsonb_build_object('address', left(nullif(trim(coalesce(a->>'address', '')), ''), 300), 'type', nullif(a->>'type', ''),
      'occupancy', nullif(a->>'occupancy', ''), 'landlord_name', left(nullif(trim(coalesce(a->>'landlord_name', '')), ''), 120),
      'landlord_id', left(nullif(trim(coalesce(a->>'landlord_id', '')), ''), 60), 'landlord_address', left(nullif(trim(coalesce(a->>'landlord_address', '')), ''), 300),
      'rent_paid', round(nullif(private.num(a->>'rent_paid'), 0), 2), 'rent_paid_by_employer', round(nullif(private.num(a->>'rent_paid_by_employer'), 0), 2),
      'started_on', nullif(a->>'started_on', ''), 'ended_on', nullif(a->>'ended_on', '')));
  end if;
  if p ? 'pension_details' then
    if jsonb_typeof(p->'pension_details') <> 'object' then raise exception 'The relief details are {rsa_number, pfa, life_company, life_policy, mortgage_institution, mortgage_capital}.'; end if;
    v_pen := '{}'::jsonb;
    for k in select jsonb_object_keys(p->'pension_details') loop
      if k not in ('rsa_number', 'pfa', 'life_company', 'life_policy', 'mortgage_institution', 'mortgage_capital') then raise exception 'Unknown relief detail %.', k; end if;
      if k = 'rsa_number' then
        v_rsa := nullif(upper(regexp_replace(coalesce(p->'pension_details'->>'rsa_number', ''), '\s', '', 'g')), '');
        if v_rsa is not null and v_rsa !~ '^[A-Z]{0,4}[0-9]{6,20}$' then raise exception 'An RSA number is PEN followed by twelve digits.'; end if;
        v_pen := v_pen || jsonb_build_object('rsa_number', v_rsa);
      elsif k = 'mortgage_capital' then
        v_n := private.num(p->'pension_details'->>k);
        if coalesce(p->'pension_details'->>k, '') <> '' and (v_n is null or v_n <= 0) then raise exception 'Enter the capital sum on the mortgage as an amount.'; end if;
        v_pen := v_pen || jsonb_build_object(k, round(v_n, 2));
      else
        v_pen := v_pen || jsonb_build_object(k, left(nullif(trim(coalesce(p->'pension_details'->>k, '')), ''), 120));
      end if;
    end loop;
  end if;

  -- Household staff (e-Tax's support staff, kept on the person's e-Tax profile).
  if p ? 'household_staff' then
    if jsonb_typeof(p->'household_staff') <> 'array' then raise exception 'The household staff are a list.'; end if;
    if jsonb_array_length(p->'household_staff') > 30 then raise exception 'At most 30 household staff.'; end if;
    v_hs := '[]'::jsonb;
    for x in select value from jsonb_array_elements(p->'household_staff') loop
      if not (private.pit_staff_roles() ? coalesce(x->>'role', '')) then raise exception 'Choose what each member of staff does.'; end if;
      v_reg := coalesce((x->>'registered')::boolean, false);
      v_n := private.num(x->>'income_paid');
      if v_n is null or v_n < 0 then raise exception 'Enter what % was paid in the year.', coalesce(nullif(trim(x->>'name'), ''), 'each member of staff'); end if;
      if v_reg then
        v_pid := upper(regexp_replace(coalesce(x->>'payer_id', ''), '\s', '', 'g'));
        if v_pid !~ '^[NC]-[0-9]{4,12}$' then raise exception 'A Payer ID is N- followed by digits, as e-Tax shows it.'; end if;
        v_hs := v_hs || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('role', x->>'role', 'registered', true, 'payer_id', v_pid,
          'name', left(nullif(trim(coalesce(x->>'name', '')), ''), 120), 'income_paid', round(v_n, 2))));
      else
        if length(trim(coalesce(x->>'name', ''))) < 2 then raise exception 'Enter the name of each member of staff.'; end if;
        if length(trim(coalesce(x->>'address', ''))) < 5 then raise exception 'Enter the home address of %.', trim(x->>'name'); end if;
        v_hs := v_hs || jsonb_build_array(jsonb_build_object('role', x->>'role', 'registered', false, 'name', left(trim(x->>'name'), 120),
          'address', left(trim(x->>'address'), 300), 'income_paid', round(v_n, 2)));
      end if;
    end loop;
  end if;

  -- The person's row for the year starts from what the year already gives them.
  select x2 into d from jsonb_array_elements(private.pit_people_year(p_org, p_year)) x2 where (x2->>'person_id')::uuid = p_person;
  insert into pit_years (org_id, accounting_year, updated_by) values (p_org, p_year, m.id) on conflict (org_id, accounting_year) do nothing;
  insert into pit_person_years (org_id, accounting_year, person_id, share_pct, role, office_location_id, residence, resident, household_staff, updated_by)
  values (p_org, p_year, p_person, private.num(d->>'share_pct'), d->>'role', nullif(d->>'office_location_id', '')::uuid, nullif(d->>'residence', ''),
    coalesce((d->>'resident')::boolean, true), coalesce(d->'household_staff', '[]'::jsonb), m.id)
  on conflict (org_id, accounting_year, person_id) do nothing;
  select * into y from pit_person_years where org_id = p_org and accounting_year = p_year and person_id = p_person for update;

  -- The documents for each relief, replacing those of each relief given (null or [] removes them).
  if p ? 'relief_docs' then
    if jsonb_typeof(p->'relief_docs') <> 'object' then raise exception 'The documents are {relief: [file]}.'; end if;
    v_docs := coalesce(y.relief_docs, '{}'::jsonb);
    for k in select jsonb_object_keys(p->'relief_docs') loop
      if not (v_needs ? k) or jsonb_array_length(coalesce(v_needs->k->'docs', '[]'::jsonb)) = 0 then raise exception 'There are no documents to attach for %.', replace(k, '_', ' '); end if;
      if jsonb_typeof(p->'relief_docs'->k) = 'null' then v_docs := v_docs - k; continue; end if;
      if jsonb_typeof(p->'relief_docs'->k) <> 'array' then raise exception 'The documents for % are a list.', replace(k, '_', ' '); end if;
      if jsonb_array_length(p->'relief_docs'->k) > 10 then raise exception 'At most 10 documents for each relief.'; end if;
      v_ids := array(select e->>'id' from jsonb_array_elements(v_needs->k->'docs') e);
      v_pre := p_org::text || '/tax/pit/' || p_year || '/people/' || p_person::text || '/' || k || '/';
      v_list := '[]'::jsonb;
      for f in select value from jsonb_array_elements(p->'relief_docs'->k) loop
        if not coalesce(f->>'doc', '') = any(v_ids) then raise exception 'That is not one of the documents for %.', replace(k, '_', ' '); end if;
        if left(coalesce(f->>'path', ''), length(v_pre)) <> v_pre or f->>'path' ~ '\.\.' or length(f->>'path') > 400 then raise exception 'That file is not this person''s.'; end if;
        select e->>'at' into v_at from jsonb_array_elements(case when jsonb_typeof(y.relief_docs->k) = 'array' then y.relief_docs->k else '[]'::jsonb end) e where e->>'path' = f->>'path' limit 1;
        v_list := v_list || jsonb_build_array(jsonb_build_object('doc', f->>'doc', 'path', f->>'path',
          'name', left(coalesce(nullif(trim(coalesce(f->>'name', '')), ''), split_part(f->>'path', '/', -1)), 160), 'at', coalesce(v_at, now()::text)));
      end loop;
      v_docs := case when jsonb_array_length(v_list) = 0 then v_docs - k else v_docs || jsonb_build_object(k, v_list) end;
    end loop;
  end if;

  update pit_person_years set
    share_pct = case when p ? 'share_pct' then round(private.num(p->>'share_pct'), 4) else share_pct end,
    role = case when p ? 'role' then p->>'role' else role end,
    office_location_id = case when p ? 'office_location_id' then nullif(p->>'office_location_id', '')::uuid else office_location_id end,
    residence = case when p ? 'residence' then nullif(p->>'residence', '') else residence end,
    resident = case when p ? 'resident' then coalesce((p->>'resident')::boolean, true) else resident end,
    remuneration = case when p ? 'remuneration' then round(private.num(p->>'remuneration'), 2) else remuneration end,
    remuneration_note = case when p ? 'remuneration_note' then nullif(left(trim(p->>'remuneration_note'), 300), '') else remuneration_note end,
    included = case when p ? 'included' then coalesce((p->>'included')::boolean, true) else included end,
    opening = case when p ? 'opening' then jsonb_strip_nulls(jsonb_build_object('losses_bf', round(nullif(private.num(p->'opening'->>'losses_bf'), 0), 2),
      'ca_bf', round(nullif(private.num(p->'opening'->>'ca_bf'), 0), 2))) else opening end,
    reliefs = case when p ? 'reliefs' then v_rl else reliefs end,
    other_income = case when p ? 'other_income' then v_oi else other_income end,
    accommodation = case when p ? 'accommodation' then v_acc else accommodation end,
    pension_details = case when p ? 'pension_details' then jsonb_strip_nulls(coalesce(pension_details, '{}'::jsonb) || v_pen) else pension_details end,
    household_staff = case when p ? 'household_staff' then v_hs else household_staff end,
    relief_docs = case when p ? 'relief_docs' then v_docs else relief_docs end,
    updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year and person_id = p_person
  returning * into y;

  -- Rent relief follows the accommodation: a tenant's rent, less any part an employer paid. Saving a home that is not
  -- rented takes the rent relief away.
  if y.accommodation->>'occupancy' = 'tenant' then
    v_net := round(coalesce(private.num(y.accommodation->>'rent_paid'), 0) - coalesce(private.num(y.accommodation->>'rent_paid_by_employer'), 0), 2);
    update pit_person_years set reliefs = case when v_net > 0 then reliefs || jsonb_build_object('rent_paid', v_net) else reliefs - 'rent_paid' end
    where org_id = p_org and accounting_year = p_year and person_id = p_person;
  elsif p ? 'accommodation' then
    update pit_person_years set reliefs = reliefs - 'rent_paid' where org_id = p_org and accounting_year = p_year and person_id = p_person;
  end if;
  update pit_years set updated_by = m.id, updated_at = now() where org_id = p_org and accounting_year = p_year;
  return public.pit_year(p_org, p_year);
end $function$;

-- ---------------------------------------------------------------------------
-- 4. The PITA rule book covers 2024 accounts too
-- ---------------------------------------------------------------------------
-- TaxStreem confirmed on 14 November 2026 that 2024 accounts (year of assessment 2025) use the same PITA rules as 2025
-- accounts. The rules are unchanged; version 1.2.0 says so, and 1.1.0 is retired. No return was approved under 1.1.0.
insert into public.tax_rulebooks (id, config_id, version, regime, yoa_from, yoa_to, status, config, approved_by, approved_at, note)
select 'ng-pit-pita-legacy@1.2.0', r.config_id, '1.2.0', r.regime, r.yoa_from, r.yoa_to, 'approved',
  jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(r.config,
    '{meta,version}', '"1.2.0"'),
    '{meta,applies_to}', '"Accounts for years ending in 2024 and 2025 (years of assessment 2025 and 2026)"'),
    '{meta,sources}', coalesce(r.config->'meta'->'sources', '[]'::jsonb) || '["TaxStreem answer of 14 November 2026: the same rules for 2024 accounts"]'::jsonb),
    '{configurable_flags,flags,P-1,title}', '"Old law for 2024 and 2025"'),
    '{configurable_flags,flags,P-1,reading}',
      '"Accounts for 2024 and 2025 (filed in 2025 and 2026) use the old rates and reliefs, with chargeable gains left out of taxable profit."'),
    '{configurable_flags,flags,P-8,reading}',
      to_jsonb(replace(r.config#>>'{configurable_flags,flags,P-8,reading}', '2025 accounts use the old initial', '2024 and 2025 accounts use the old initial'))),
    '{configurable_flags,flags,P-9,reading}',
      to_jsonb(replace(r.config#>>'{configurable_flags,flags,P-9,reading}', 'Losses brought into 2025 accounts', 'Losses brought into 2024 or 2025 accounts'))),
  'TaxStreem', '2026-11-14 12:00:00+01',
  'Version 1.1.0 (signed off by TaxStreem on 4 November 2026) widened to 2024 accounts on TaxStreem''s instruction of 14 November 2026. The rules are unchanged.'
from public.tax_rulebooks r where r.id = 'ng-pit-pita-legacy@1.1.0'
on conflict (id) do nothing;

update public.tax_rulebooks set status = 'retired',
  note = coalesce(note, '') || ' Retired 14 November 2026: replaced by version 1.2.0, which covers 2024 accounts as well.'
where id = 'ng-pit-pita-legacy@1.1.0' and status <> 'retired'
  and exists (select 1 from public.tax_rulebooks where id = 'ng-pit-pita-legacy@1.2.0' and status = 'approved');

-- ---------------------------------------------------------------------------
-- 5. Bank payments already in asset accounts
-- ---------------------------------------------------------------------------
-- Payments posted to an asset account before this release get their register records (and money in, its sale to match),
-- except in months already closed.
create or replace function private.bank_asset_backfill() returns int
language plpgsql security definer set search_path = public, private as $$
declare r record; n int := 0;
begin
  for r in
    select distinct bl.id from bank_lines bl
    join journals j on j.org_id = bl.org_id and j.source_id = bl.id and j.source_type in ('bank', 'reclass')
    join journal_lines l on l.journal_id = j.id and l.account_code in (select cost_account from asset_classes)
    where bl.line_date > coalesce(private.closed_through(bl.org_id), '1900-01-01'::date)
      and not exists (select 1 from fixed_assets fa where fa.bank_line_id = bl.id)
      and not exists (select 1 from asset_sales s where s.bank_line_id = bl.id)
  loop
    perform private.bank_asset_sync(r.id);
    n := n + 1;
  end loop;
  return n;
end $$;
select private.bank_asset_backfill();

-- ---------------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------------
select private.activity_attach('public.asset_sales');

revoke all on function private.bank_asset_sync(uuid), private.journal_lines_asset_watch(),
  private.dispose_core(uuid, date, numeric, text, text, uuid, text, public.members), private.ai_trade(uuid), private.ai_assets(uuid),
  private.filing_opening(uuid, integer), private.filing_opening_note(uuid, date), private.bank_asset_backfill() from public, anon, authenticated;

revoke all on function public.match_asset_sale(uuid, jsonb), public.asset_sale_elsewhere(uuid, text, text), public.merge_asset(uuid, uuid),
  public.filing_opening_save(uuid, integer, jsonb) from public, anon;
grant execute on function public.match_asset_sale(uuid, jsonb), public.asset_sale_elsewhere(uuid, text, text), public.merge_asset(uuid, uuid),
  public.filing_opening_save(uuid, integer, jsonb) to authenticated;
