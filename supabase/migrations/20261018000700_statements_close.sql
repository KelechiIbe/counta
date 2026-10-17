-- Counta · Financial statements under IFRS, the reports a CFO prepares, budgets, the close checklist (CLOSE-01), accruals,
-- expected credit losses, and the year-end close.
--
-- Every number comes from the ledger. Statement lines come from each account's IFRS line (FS-01); the statement of financial
-- position must cross-cast (assets = liabilities + equity) and the cash flow must end on the cash balance (FS-02), and both
-- checks travel with the report. Year-end closing entries (source 'year_end') are left out of profit and loss.

alter table public.orgs add column if not exists reporting_framework text not null default 'ifrs';
alter table public.orgs drop constraint if exists orgs_reporting_framework_check;
alter table public.orgs add constraint orgs_reporting_framework_check check (reporting_framework in ('ifrs', 'ifrs_sme'));
alter table public.orgs add column if not exists principal_activity text;

-- ---------------------------------------------------------------------------
-- 1. Balances by account
-- ---------------------------------------------------------------------------
create or replace function private.fy_start(p_org uuid, p_day date) returns date
language sql stable security definer set search_path = public, private as $$
  select case when extract(month from p_day) >= m then make_date(extract(year from p_day)::int, m, 1)
              else make_date(extract(year from p_day)::int - 1, m, 1) end
  from (select coalesce((select fiscal_year_start from orgs where id = p_org), 1) m) x
$$;

-- Debit-positive balance of every account with activity up to a date (all journals).
create or replace function private.balances_at(p_org uuid, p_to date) returns table (code text, bal numeric)
language sql stable security definer set search_path = public, private as $$
  select l.account_code, sum(l.debit - l.credit) from journal_lines l join journals j on j.id = l.journal_id
  where l.org_id = p_org and j.entry_date <= p_to group by l.account_code
$$;

-- Debit-positive movement on each account between two dates, without year-end closing entries.
create or replace function private.movement(p_org uuid, p_from date, p_to date) returns table (code text, dr numeric, cr numeric, net numeric)
language sql stable security definer set search_path = public, private as $$
  select l.account_code, sum(l.debit), sum(l.credit), sum(l.debit - l.credit) from journal_lines l join journals j on j.id = l.journal_id
  where l.org_id = p_org and j.entry_date between p_from and p_to and j.source_type is distinct from 'year_end' group by l.account_code
$$;

create or replace function private.acct_meta(p_org uuid) returns table (code text, name text, statement text, ifrs_line text, cf text, category text, own boolean)
language sql stable security definer set search_path = public, private as $$
  select a.code, a.name, coalesce(a.statement, 'system'), coalesce(a.ifrs_line, 'Unclassified'), coalesce(a.cash_flow_class, 'system'), a.category, a.own
  from private.accounts_of(p_org) a
$$;

-- The statement of financial position as a map of IFRS line to amount (assets debit-positive, liabilities and equity credit-positive),
-- with credit balances on customers shown as liabilities and debit balances on vendors shown as receivables.
create or replace function private.sofp_map(p_org uuid, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v jsonb := '{}'::jsonb; r record; v_line text; v_amt numeric; v_profit numeric := 0; v_cust_cr numeric; v_vend_dr numeric;
begin
  for r in select b.code, b.bal, coalesce(m.statement, 'system') statement, coalesce(m.ifrs_line, 'Unclassified') ifrs_line
           from private.balances_at(p_org, p_to) b left join private.acct_meta(p_org) m on m.code = b.code where b.bal <> 0 loop
    if r.statement in ('pl', 'oci') then
      v_profit := v_profit - r.bal;
      continue;
    end if;
    v_line := r.ifrs_line;
    if v_line = 'Unreconciled balances' then
      v_line := case when r.bal > 0 then 'Unreconciled balances (assets)' else 'Unreconciled balances (liabilities)' end;
    elsif v_line = 'Unclassified' then
      v_line := case when r.bal > 0 then 'Other current assets' else 'Other current liabilities' end;
    elsif v_line = 'Cash and cash equivalents' and r.bal < 0 then
      -- An overdrawn account is a liability. It is not set off against cash in other accounts (IAS 32.42).
      v_line := 'Bank overdrafts';
    end if;
    v_amt := case when v_line in (select unnest(private.asset_lines()) ) then r.bal else -r.bal end;
    v := jsonb_set(v, array[v_line], to_jsonb(coalesce((v->>v_line)::numeric, 0) + v_amt));
  end loop;
  -- Retained earnings include profit not yet closed to 3005.
  v := jsonb_set(v, array['Retained earnings'], to_jsonb(coalesce((v->>'Retained earnings')::numeric, 0) + v_profit));
  -- Customers in credit owe nothing: their credit is a liability. Vendors in debit owe us: an asset.
  select coalesce(sum(greatest(-x.b, 0)), 0) into v_cust_cr from (select sum(l.debit - l.credit) b from journal_lines l join journals j on j.id = l.journal_id
    where l.org_id = p_org and l.party_type = 'customer' and l.account_code in ('1101', '1102') and j.entry_date <= p_to group by l.party_id) x;
  select coalesce(sum(greatest(x.b, 0)), 0) into v_vend_dr from (select sum(l.debit - l.credit) b from journal_lines l join journals j on j.id = l.journal_id
    where l.org_id = p_org and l.party_type = 'vendor' and l.account_code in ('2101', '2102') and j.entry_date <= p_to group by l.party_id) x;
  if v_cust_cr > 0 then
    v := jsonb_set(v, array['Trade and other receivables'], to_jsonb(coalesce((v->>'Trade and other receivables')::numeric, 0) + v_cust_cr));
    v := jsonb_set(v, array['Contract liabilities'], to_jsonb(coalesce((v->>'Contract liabilities')::numeric, 0) + v_cust_cr));
  end if;
  if v_vend_dr > 0 then
    v := jsonb_set(v, array['Trade and other payables'], to_jsonb(coalesce((v->>'Trade and other payables')::numeric, 0) + v_vend_dr));
    v := jsonb_set(v, array['Trade and other receivables'], to_jsonb(coalesce((v->>'Trade and other receivables')::numeric, 0) + v_vend_dr));
  end if;
  return v || jsonb_build_object('_profit_unclosed', v_profit, '_customer_credit_reclass', v_cust_cr, '_vendor_debit_reclass', v_vend_dr);
end $$;

create or replace function private.asset_lines() returns text[]
language sql immutable set search_path = '' as $$
  select array['Property, plant and equipment', 'Intangible assets', 'Right-of-use assets', 'Investments in subsidiaries and associates', 'Investment property',
    'Other financial assets', 'Deferred tax assets', 'Other non-current assets', 'Inventories', 'Trade and other receivables', 'Contract assets', 'Prepayments',
    'Other current financial assets', 'Current tax assets', 'Assets held for sale', 'Cash and cash equivalents', 'Unreconciled balances (assets)', 'Other current assets']
$$;

-- Profit or loss for a period as a map of IFRS line to amount (income positive, expenses negative).
create or replace function private.pl_map(p_org uuid, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_object_agg(line, amt), '{}'::jsonb) from (
    select case when m.ifrs_line = 'Unclassified' or m.ifrs_line is null then 'Other expenses' else m.ifrs_line end line, sum(-mv.net) amt
    from private.movement(p_org, p_from, p_to) mv join private.acct_meta(p_org) m on m.code = mv.code
    where m.statement in ('pl', 'oci') group by 1) x
$$;

create or replace function private.v(p jsonb, k text) returns numeric
language sql immutable set search_path = '' as $$ select coalesce((p->>k)::numeric, 0) $$;

-- ---------------------------------------------------------------------------
-- 2. Statement rows
-- ---------------------------------------------------------------------------
-- A statement row: {line, note, current, prior, _style, _indent}
create or replace function private.fr(p_line text, p_cur numeric, p_pri numeric, p_style text default 'line', p_indent int default 1, p_note text default null) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object('line', p_line, 'note', p_note, 'current', round(p_cur, 2), 'prior', round(p_pri, 2), '_style', p_style, '_indent', p_indent)
$$;

create or replace function private.note_no(p_key text) returns text
language sql immutable set search_path = '' as $$
  select case p_key when 'revenue' then '3' when 'cost_of_sales' then '4' when 'expenses' then '5' when 'finance' then '6' when 'tax' then '7'
    when 'ppe' then '8' when 'inventories' then '9' when 'receivables' then '10' when 'cash' then '11' when 'equity' then '12' when 'payables' then '13'
    when 'statutory' then '14' when 'borrowings' then '15' when 'related' then '16' when 'unreconciled' then '17' else null end
$$;

create or replace function private.sofp_rows(c jsonb, p jsonb) returns jsonb
language plpgsql immutable set search_path = public, private as $$
declare v jsonb := '[]'::jsonb; l text; v_nca numeric; v_ncap numeric; v_ca numeric; v_cap numeric; v_eq numeric; v_eqp numeric; v_ncl numeric; v_nclp numeric;
  v_cl numeric; v_clp numeric;
  nca text[] := array['Property, plant and equipment', 'Intangible assets', 'Right-of-use assets', 'Investments in subsidiaries and associates', 'Investment property',
    'Other financial assets', 'Deferred tax assets', 'Other non-current assets'];
  ca text[] := array['Inventories', 'Trade and other receivables', 'Contract assets', 'Prepayments', 'Other current financial assets', 'Current tax assets',
    'Assets held for sale', 'Other current assets', 'Cash and cash equivalents', 'Unreconciled balances (assets)'];
  eq text[] := array['Share capital', 'Share premium', 'Deposit for shares', 'Other reserves', 'Retained earnings', 'Opening balances to be confirmed', 'Non-controlling interests'];
  ncl text[] := array['Borrowings (non-current)', 'Lease liabilities (non-current)', 'Deferred tax liabilities', 'Other non-current liabilities'];
  cl text[] := array['Trade and other payables', 'Contract liabilities', 'Current tax liabilities', 'Other statutory liabilities', 'Bank overdrafts', 'Borrowings (current)',
    'Lease liabilities (current)', 'Provisions (current)', 'Other current liabilities', 'Unreconciled balances (liabilities)'];
  function_note text;
begin
  v := v || private.fr('Assets', null, null, 'heading', 0) || private.fr('Non-current assets', null, null, 'subheading', 0);
  v_nca := 0; v_ncap := 0;
  foreach l in array nca loop
    if private.v(c, l) <> 0 or private.v(p, l) <> 0 then
      v := v || private.fr(l, private.v(c, l), private.v(p, l), 'line', 1, case l when 'Property, plant and equipment' then private.note_no('ppe') end);
      v_nca := v_nca + private.v(c, l); v_ncap := v_ncap + private.v(p, l);
    end if;
  end loop;
  v := v || private.fr('Total non-current assets', v_nca, v_ncap, 'subtotal', 0) || private.fr('Current assets', null, null, 'subheading', 0);
  v_ca := 0; v_cap := 0;
  foreach l in array ca loop
    if private.v(c, l) <> 0 or private.v(p, l) <> 0 then
      v := v || private.fr(l, private.v(c, l), private.v(p, l), 'line', 1, case l when 'Inventories' then private.note_no('inventories')
        when 'Trade and other receivables' then private.note_no('receivables') when 'Cash and cash equivalents' then private.note_no('cash')
        when 'Unreconciled balances (assets)' then private.note_no('unreconciled') end);
      v_ca := v_ca + private.v(c, l); v_cap := v_cap + private.v(p, l);
    end if;
  end loop;
  v := v || private.fr('Total current assets', v_ca, v_cap, 'subtotal', 0) || private.fr('Total assets', v_nca + v_ca, v_ncap + v_cap, 'total', 0)
    || private.fr('', null, null, 'blank', 0) || private.fr('Equity and liabilities', null, null, 'heading', 0) || private.fr('Equity', null, null, 'subheading', 0);
  v_eq := 0; v_eqp := 0;
  foreach l in array eq loop
    if private.v(c, l) <> 0 or private.v(p, l) <> 0 then
      v := v || private.fr(l, private.v(c, l), private.v(p, l), 'line', 1, case when l in ('Share capital', 'Share premium', 'Retained earnings', 'Other reserves') then private.note_no('equity') end);
      v_eq := v_eq + private.v(c, l); v_eqp := v_eqp + private.v(p, l);
    end if;
  end loop;
  v := v || private.fr('Total equity', v_eq, v_eqp, 'subtotal', 0) || private.fr('Non-current liabilities', null, null, 'subheading', 0);
  v_ncl := 0; v_nclp := 0;
  foreach l in array ncl loop
    if private.v(c, l) <> 0 or private.v(p, l) <> 0 then
      v := v || private.fr(l, private.v(c, l), private.v(p, l), 'line', 1, case when l like 'Borrowings%' then private.note_no('borrowings') end);
      v_ncl := v_ncl + private.v(c, l); v_nclp := v_nclp + private.v(p, l);
    end if;
  end loop;
  v := v || private.fr('Total non-current liabilities', v_ncl, v_nclp, 'subtotal', 0) || private.fr('Current liabilities', null, null, 'subheading', 0);
  v_cl := 0; v_clp := 0;
  foreach l in array cl loop
    if private.v(c, l) <> 0 or private.v(p, l) <> 0 then
      v := v || private.fr(l, private.v(c, l), private.v(p, l), 'line', 1, case l when 'Trade and other payables' then private.note_no('payables')
        when 'Contract liabilities' then private.note_no('payables') when 'Current tax liabilities' then private.note_no('tax')
        when 'Other statutory liabilities' then private.note_no('statutory') when 'Borrowings (current)' then private.note_no('borrowings')
        when 'Bank overdrafts' then private.note_no('cash')
        when 'Unreconciled balances (liabilities)' then private.note_no('unreconciled') end);
      v_cl := v_cl + private.v(c, l); v_clp := v_clp + private.v(p, l);
    end if;
  end loop;
  v := v || private.fr('Total current liabilities', v_cl, v_clp, 'subtotal', 0) || private.fr('Total liabilities', v_ncl + v_cl, v_nclp + v_clp, 'subtotal', 0)
    || private.fr('Total equity and liabilities', v_eq + v_ncl + v_cl, v_eqp + v_nclp + v_clp, 'total', 0);
  return v;
end $$;

create or replace function private.sopl_rows(c jsonb, p jsonb) returns jsonb
language plpgsql immutable set search_path = public, private as $$
declare v jsonb := '[]'::jsonb; gp numeric; gpp numeric; op numeric; opp numeric; pbt numeric; pbtp numeric; pat numeric; patp numeric; oci numeric; ocip numeric;
begin
  gp := private.v(c, 'Revenue') + private.v(c, 'Cost of sales'); gpp := private.v(p, 'Revenue') + private.v(p, 'Cost of sales');
  v := v || private.fr('Revenue', private.v(c, 'Revenue'), private.v(p, 'Revenue'), 'line', 0, private.note_no('revenue'))
    || private.fr('Cost of sales', private.v(c, 'Cost of sales'), private.v(p, 'Cost of sales'), 'line', 0, private.note_no('cost_of_sales'))
    || private.fr('Gross profit', gp, gpp, 'subtotal', 0);
  op := gp; opp := gpp;
  for i in 1 .. 7 loop
    declare l text := (array['Other income', 'Selling and distribution expenses', 'Administrative expenses', 'Impairment losses on financial assets',
      'Other operating expenses', 'Other gains and losses', 'Other expenses'])[i];
    begin
      if private.v(c, l) <> 0 or private.v(p, l) <> 0 or l in ('Administrative expenses') then
        v := v || private.fr(l, private.v(c, l), private.v(p, l), 'line', 0, case when l like '%expenses' then private.note_no('expenses') end);
      end if;
      op := op + private.v(c, l); opp := opp + private.v(p, l);
    end;
  end loop;
  v := v || private.fr('Operating profit', op, opp, 'subtotal', 0)
    || private.fr('Finance income', private.v(c, 'Finance income'), private.v(p, 'Finance income'), 'line', 0, private.note_no('finance'))
    || private.fr('Finance costs', private.v(c, 'Finance costs'), private.v(p, 'Finance costs'), 'line', 0, private.note_no('finance'));
  pbt := op + private.v(c, 'Finance income') + private.v(c, 'Finance costs'); pbtp := opp + private.v(p, 'Finance income') + private.v(p, 'Finance costs');
  v := v || private.fr('Profit before tax', pbt, pbtp, 'subtotal', 0)
    || private.fr('Income tax expense', private.v(c, 'Income tax expense'), private.v(p, 'Income tax expense'), 'line', 0, private.note_no('tax'));
  pat := pbt + private.v(c, 'Income tax expense'); patp := pbtp + private.v(p, 'Income tax expense');
  v := v || private.fr('Profit for the period', pat, patp, 'total', 0) || private.fr('Other comprehensive income', null, null, 'subheading', 0)
    || private.fr('Items that will not be reclassified to profit or loss', private.v(c, 'Items that will not be reclassified to profit or loss'),
         private.v(p, 'Items that will not be reclassified to profit or loss'), 'line', 1)
    || private.fr('Items that may be reclassified to profit or loss', private.v(c, 'Items that may be reclassified to profit or loss'),
         private.v(p, 'Items that may be reclassified to profit or loss'), 'line', 1)
    || private.fr('Income tax relating to other comprehensive income', private.v(c, 'Income tax relating to other comprehensive income'),
         private.v(p, 'Income tax relating to other comprehensive income'), 'line', 1);
  oci := private.v(c, 'Items that will not be reclassified to profit or loss') + private.v(c, 'Items that may be reclassified to profit or loss')
       + private.v(c, 'Income tax relating to other comprehensive income');
  ocip := private.v(p, 'Items that will not be reclassified to profit or loss') + private.v(p, 'Items that may be reclassified to profit or loss')
       + private.v(p, 'Income tax relating to other comprehensive income');
  v := v || private.fr('Other comprehensive income for the period', oci, ocip, 'subtotal', 0)
    || private.fr('Total comprehensive income for the period', pat + oci, patp + ocip, 'total', 0);
  return v;
end $$;

create or replace function private.pl_totals(c jsonb) returns jsonb
language sql immutable set search_path = public, private as $$
  select jsonb_build_object(
    'revenue', private.v(c, 'Revenue'), 'cost_of_sales', -private.v(c, 'Cost of sales'),
    'gross_profit', private.v(c, 'Revenue') + private.v(c, 'Cost of sales'),
    'opex', -(private.v(c, 'Selling and distribution expenses') + private.v(c, 'Administrative expenses') + private.v(c, 'Impairment losses on financial assets')
      + private.v(c, 'Other operating expenses') + private.v(c, 'Other expenses')),
    'other_income', private.v(c, 'Other income') + private.v(c, 'Other gains and losses'),
    'operating_profit', private.v(c, 'Revenue') + private.v(c, 'Cost of sales') + private.v(c, 'Other income') + private.v(c, 'Selling and distribution expenses')
      + private.v(c, 'Administrative expenses') + private.v(c, 'Impairment losses on financial assets') + private.v(c, 'Other operating expenses')
      + private.v(c, 'Other gains and losses') + private.v(c, 'Other expenses'),
    'finance_costs', -private.v(c, 'Finance costs'), 'finance_income', private.v(c, 'Finance income'),
    'profit_before_tax', private.v(c, 'Revenue') + private.v(c, 'Cost of sales') + private.v(c, 'Other income') + private.v(c, 'Selling and distribution expenses')
      + private.v(c, 'Administrative expenses') + private.v(c, 'Impairment losses on financial assets') + private.v(c, 'Other operating expenses')
      + private.v(c, 'Other gains and losses') + private.v(c, 'Other expenses') + private.v(c, 'Finance income') + private.v(c, 'Finance costs'),
    'tax', -private.v(c, 'Income tax expense'))
  || jsonb_build_object('profit', (select sum(value::numeric) from jsonb_each_text(c) where key not in (
      'Items that will not be reclassified to profit or loss', 'Items that may be reclassified to profit or loss', 'Income tax relating to other comprehensive income')))
$$;

-- Cash flows: each cash movement is classified by what was on the other side of its journal (looking through bills to what was bought);
-- operating activities are also shown on the indirect method, with any difference shown as other non-cash items so the statement ties.
create or replace function private.cash_flow_parts(p_org uuid, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = public, private as $$
  with meta as (select * from private.acct_meta(p_org)),
  cashacc as (select code from meta where ifrs_line = 'Cash and cash equivalents'),
  jl as (select l.*, j.source_type from journal_lines l join journals j on j.id = l.journal_id
         where l.org_id = p_org and j.entry_date between p_from and p_to and j.source_type is distinct from 'year_end'),
  cj as (select journal_id, sum(debit - credit) cash from jl where account_code in (select code from cashacc) group by journal_id having sum(debit - credit) <> 0),
  -- Only lines on the other side from the cash take a share of it (a WHT line beside a payment does not).
  counter as (
    -- Payables settled for a bill count as what the bill bought.
    select l.journal_id, abs(bl.gross / nullif(b.total, 0) * (l.debit - l.credit)) w, coalesce(m.cf, 'system') cf, coalesce(m.ifrs_line, 'Unclassified') line, l.source_type
    from jl l join cj on cj.journal_id = l.journal_id join bills b on b.id = l.doc_id and l.doc_type = 'bill' join bill_lines bl on bl.bill_id = b.id
    left join meta m on m.code = bl.account_code
    where l.account_code in ('2101', '2102') and sign(l.debit - l.credit) = -sign(cj.cash)
    union all
    select l.journal_id, abs(l.debit - l.credit), case when l.source_type = 'asset_disposal' then 'investing' else coalesce(m.cf, 'system') end,
      coalesce(m.ifrs_line, 'Unclassified'), l.source_type
    from jl l join cj on cj.journal_id = l.journal_id left join meta m on m.code = l.account_code
    where l.account_code not in (select code from cashacc) and sign(l.debit - l.credit) = -sign(cj.cash)
      and not (l.account_code in ('2101', '2102') and l.doc_type = 'bill')),
  tot as (select journal_id, sum(w) w from counter group by journal_id),
  alloc as (
    select c.journal_id, cj.cash * c.w / nullif(t.w, 0) amt,
      case when c.cf in ('investing', 'investing_gain') then 'investing' when c.cf in ('financing', 'equity_other') then 'financing'
           when c.cf = 'tax_paid' then 'tax' else 'operating' end section, c.line
    from counter c join tot t on t.journal_id = c.journal_id join cj on cj.journal_id = c.journal_id where t.w > 0)
  select jsonb_build_object(
    'operating_direct', coalesce((select sum(amt) from alloc where section in ('operating', 'tax')), 0),
    'tax_paid', coalesce((select sum(amt) from alloc where section = 'tax'), 0),
    'investing', coalesce((select jsonb_object_agg(k, v) from (select case when line = 'Property, plant and equipment' and sum(amt) < 0 then 'Purchase of property, plant and equipment'
        when line = 'Property, plant and equipment' then 'Proceeds from disposal of property, plant and equipment'
        when line = 'Intangible assets' then 'Purchase of intangible assets'
        when line in ('Other income', 'Other gains and losses', 'Other expenses') then 'Proceeds from disposal of property, plant and equipment'
        else line end k, sum(amt) v from alloc where section = 'investing' group by line) x), '{}'::jsonb),
    'financing', coalesce((select jsonb_object_agg(k, v) from (select case line when 'Share capital' then 'Proceeds from issue of shares'
        when 'Share premium' then 'Proceeds from issue of shares' when 'Deposit for shares' then 'Deposits for shares received'
        when 'Retained earnings' then 'Dividends and drawings paid' when 'Opening balances to be confirmed' then 'Owner''s funds introduced or withdrawn'
        when 'Trade and other payables' then 'Dividends paid' else line end k, sum(amt) v from alloc where section = 'financing' group by 1) x), '{}'::jsonb),
    'cash_open', (select coalesce(sum(b.bal), 0) from private.balances_at(p_org, p_from - 1) b where b.code in (select code from cashacc)),
    'cash_close', (select coalesce(sum(b.bal), 0) from private.balances_at(p_org, p_to) b where b.code in (select code from cashacc)),
    'depreciation', (select coalesce(sum(mv.net), 0) from private.movement(p_org, p_from, p_to) mv where mv.code in ('6901', '6902', '6903', '5204', '5205')),
    'impairment', (select coalesce(sum(mv.net), 0) from private.movement(p_org, p_from, p_to) mv where mv.code in ('6802', '6803', '6805', '6704', '4511', '4515', '4507')),
    'disposal_result', (select coalesce(sum(mv.net), 0) from private.movement(p_org, p_from, p_to) mv where mv.code in ('4508', '6804', '4506')),
    'wc', (select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from (select m.ifrs_line k, -sum(mv.net) v from private.movement(p_org, p_from, p_to) mv
        join meta m on m.code = mv.code where m.cf = 'working_capital' group by m.ifrs_line) x))
$$;

create or replace function private.cash_flow_rows(p_org uuid, p_from date, p_to date, p_pfrom date, p_pto date) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare c jsonb := private.cash_flow_parts(p_org, p_from, p_to); p jsonb; v jsonb := '[]'::jsonb; pc jsonb; pp jsonb; k text; v_op numeric; v_opp numeric;
  v_inv numeric; v_invp numeric; v_fin numeric; v_finp numeric; v_other numeric; v_otherp numeric; v_ind numeric; v_indp numeric; v_keys text[];
begin
  p := case when p_pfrom is null then '{}'::jsonb else private.cash_flow_parts(p_org, p_pfrom, p_pto) end;
  pc := private.pl_totals(private.pl_map(p_org, p_from, p_to));
  pp := case when p_pfrom is null then '{}'::jsonb else private.pl_totals(private.pl_map(p_org, p_pfrom, p_pto)) end;
  v := v || private.fr('Cash flows from operating activities', null, null, 'heading', 0)
    || private.fr('Profit before tax', private.v(pc, 'profit_before_tax'), private.v(pp, 'profit_before_tax'), 'line', 1)
    || private.fr('Adjustments for:', null, null, 'subheading', 1)
    || private.fr('Depreciation and amortisation', private.v(c, 'depreciation'), private.v(p, 'depreciation'), 'line', 2)
    || private.fr('Impairment and write-downs', private.v(c, 'impairment'), private.v(p, 'impairment'), 'line', 2)
    || private.fr('(Gain) / loss on disposal of assets', private.v(c, 'disposal_result'), private.v(p, 'disposal_result'), 'line', 2)
    || private.fr('Changes in working capital:', null, null, 'subheading', 1);
  v_ind := private.v(pc, 'profit_before_tax') + private.v(c, 'depreciation') + private.v(c, 'impairment') + private.v(c, 'disposal_result');
  v_indp := private.v(pp, 'profit_before_tax') + private.v(p, 'depreciation') + private.v(p, 'impairment') + private.v(p, 'disposal_result');
  select array_agg(distinct key) into v_keys from (select key from jsonb_each(c->'wc') union select key from jsonb_each(coalesce(p->'wc', '{}'::jsonb))) x;
  foreach k in array coalesce(v_keys, '{}') loop
    v := v || private.fr(case when k in (select unnest(private.asset_lines())) then '(Increase) / decrease in ' || lower(k) else 'Increase / (decrease) in ' || lower(k) end,
      private.v(c->'wc', k), private.v(p->'wc', k), 'line', 2);
    v_ind := v_ind + private.v(c->'wc', k); v_indp := v_indp + private.v(p->'wc', k);
  end loop;
  v_op := private.v(c, 'operating_direct'); v_opp := private.v(p, 'operating_direct');
  -- Whatever the indirect method does not explain (accruals moved between heads, journals with no cash in them) is shown, not hidden.
  v_other := v_op - private.v(c, 'tax_paid') - v_ind; v_otherp := v_opp - private.v(p, 'tax_paid') - v_indp;
  if abs(v_other) >= 0.01 or abs(v_otherp) >= 0.01 then
    v := v || private.fr('Other non-cash items', v_other, v_otherp, 'line', 2);
  end if;
  v := v || private.fr('Cash generated from operations', v_op - private.v(c, 'tax_paid'), v_opp - private.v(p, 'tax_paid'), 'subtotal', 1)
    || private.fr('Income taxes paid', private.v(c, 'tax_paid'), private.v(p, 'tax_paid'), 'line', 1)
    || private.fr('Net cash from operating activities', v_op, v_opp, 'subtotal', 0)
    || private.fr('Cash flows from investing activities', null, null, 'heading', 0);
  v_inv := 0; v_invp := 0;
  select array_agg(distinct key) into v_keys from (select key from jsonb_each(c->'investing') union select key from jsonb_each(coalesce(p->'investing', '{}'::jsonb))) x;
  foreach k in array coalesce(v_keys, '{}') loop
    v := v || private.fr(k, private.v(c->'investing', k), private.v(p->'investing', k), 'line', 1);
    v_inv := v_inv + private.v(c->'investing', k); v_invp := v_invp + private.v(p->'investing', k);
  end loop;
  v := v || private.fr('Net cash used in investing activities', v_inv, v_invp, 'subtotal', 0) || private.fr('Cash flows from financing activities', null, null, 'heading', 0);
  v_fin := 0; v_finp := 0;
  select array_agg(distinct key) into v_keys from (select key from jsonb_each(c->'financing') union select key from jsonb_each(coalesce(p->'financing', '{}'::jsonb))) x;
  foreach k in array coalesce(v_keys, '{}') loop
    v := v || private.fr(k, private.v(c->'financing', k), private.v(p->'financing', k), 'line', 1);
    v_fin := v_fin + private.v(c->'financing', k); v_finp := v_finp + private.v(p->'financing', k);
  end loop;
  v := v || private.fr('Net cash from financing activities', v_fin, v_finp, 'subtotal', 0)
    || private.fr('Net increase / (decrease) in cash and cash equivalents', v_op + v_inv + v_fin, v_opp + v_invp + v_finp, 'subtotal', 0)
    || private.fr('Cash and cash equivalents at the start of the period', private.v(c, 'cash_open'), private.v(p, 'cash_open'), 'line', 0)
    || private.fr('Cash and cash equivalents at the end of the period', private.v(c, 'cash_open') + v_op + v_inv + v_fin,
         private.v(p, 'cash_open') + v_opp + v_invp + v_finp, 'total', 0, private.note_no('cash'));
  return jsonb_build_object('rows', v, 'check', jsonb_build_object('computed_close', private.v(c, 'cash_open') + v_op + v_inv + v_fin, 'ledger_close', private.v(c, 'cash_close'),
    'ties', abs(private.v(c, 'cash_open') + v_op + v_inv + v_fin - private.v(c, 'cash_close')) < 0.01));
end $$;

-- Statement of changes in equity.
create or replace function private.soce_rows(p_org uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v jsonb := '[]'::jsonb; o jsonb; c jsonb; pl jsonb; k text; comps text[] := array['Share capital', 'Share premium', 'Other reserves', 'Retained earnings',
  'Opening balances to be confirmed']; v_profit numeric; v_oci numeric; v_cap numeric; v_div numeric; r jsonb; v_total_o numeric := 0; v_total_c numeric := 0;
begin
  o := private.sofp_map(p_org, p_from - 1);
  c := private.sofp_map(p_org, p_to);
  pl := private.pl_map(p_org, p_from, p_to);
  v_profit := (private.pl_totals(pl)->>'profit')::numeric;
  v_oci := private.v(pl, 'Items that will not be reclassified to profit or loss') + private.v(pl, 'Items that may be reclassified to profit or loss')
         + private.v(pl, 'Income tax relating to other comprehensive income');
  select coalesce(sum(mv.cr - mv.dr), 0) into v_cap from private.movement(p_org, p_from, p_to) mv where mv.code in ('3001', '3002', '3003', '3004');
  select coalesce(sum(mv.dr), 0) into v_div from private.movement(p_org, p_from, p_to) mv where mv.code = '3005';
  -- One row per component: start, profit, OCI, capital, dividends, other, end.
  foreach k in array comps loop
    r := jsonb_build_object('component', k, 'opening', private.v(o, k) + case when k = 'Share capital' then private.v(o, 'Deposit for shares') else 0 end,
      'profit', case when k = 'Retained earnings' then v_profit else 0 end,
      'oci', case when k = 'Other reserves' then v_oci else 0 end,
      'capital', case when k = 'Share capital' then v_cap else 0 end,
      'dividends', case when k = 'Retained earnings' then -v_div else 0 end,
      'closing', private.v(c, k) + case when k = 'Share capital' then private.v(c, 'Deposit for shares') else 0 end);
    r := r || jsonb_build_object('other', (r->>'closing')::numeric - (r->>'opening')::numeric - (r->>'profit')::numeric - (r->>'oci')::numeric
      - (r->>'capital')::numeric - (r->>'dividends')::numeric, '_style', 'line', '_indent', 0);
    v_total_o := v_total_o + (r->>'opening')::numeric; v_total_c := v_total_c + (r->>'closing')::numeric;
    if (r->>'opening')::numeric <> 0 or (r->>'closing')::numeric <> 0 then v := v || r; end if;
  end loop;
  v := v || jsonb_build_object('component', 'Total equity', 'opening', v_total_o, 'profit', v_profit, 'oci', v_oci, 'capital', v_cap, 'dividends', -v_div,
    'other', v_total_c - v_total_o - v_profit - v_oci - v_cap + v_div, 'closing', v_total_c, '_style', 'total', '_indent', 0);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Notes to the financial statements
-- ---------------------------------------------------------------------------
-- p_bpto: the date balances are compared at (the end of the previous financial year, IAS 1.38 and IAS 34.20); p_pfrom..p_pto: the comparative period.
drop function if exists private.note_rows(uuid, date, date, date, date);
create or replace function private.note_rows(p_org uuid, p_from date, p_to date, p_pfrom date, p_pto date, p_bpto date default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; v jsonb := '[]'::jsonb; r record; c jsonb; p jsonb; v_fw text; v_mv jsonb; plc jsonb; plp jsonb;
  mvc jsonb; mvp jsonb; drc jsonb; crc jsonb; balc jsonb; balo jsonb; balp jsonb; v_lines text[]; v_bpto date := coalesce(p_bpto, p_pto);
begin
  select * into o from orgs where id = p_org;
  c := private.sofp_map(p_org, p_to);
  p := case when v_bpto is null then '{}'::jsonb else private.sofp_map(p_org, v_bpto) end;
  plc := private.pl_map(p_org, p_from, p_to);
  plp := case when p_pfrom is null then '{}'::jsonb else private.pl_map(p_org, p_pfrom, p_pto) end;
  -- Each ledger figure is read once into a map of account to amount.
  select coalesce(jsonb_object_agg(code, net), '{}'), coalesce(jsonb_object_agg(code, dr), '{}'), coalesce(jsonb_object_agg(code, cr), '{}') into mvc, drc, crc
    from private.movement(p_org, p_from, p_to);
  select coalesce(jsonb_object_agg(code, net), '{}') into mvp from private.movement(p_org, coalesce(p_pfrom, p_from), coalesce(p_pto, p_from - 1)) where p_pfrom is not null;
  select coalesce(jsonb_object_agg(code, bal), '{}') into balc from private.balances_at(p_org, p_to);
  select coalesce(jsonb_object_agg(code, bal), '{}') into balo from private.balances_at(p_org, p_from - 1);
  select coalesce(jsonb_object_agg(code, bal), '{}') into balp from private.balances_at(p_org, v_bpto) where v_bpto is not null;
  mvp := coalesce(mvp, '{}'); balp := coalesce(balp, '{}');
  v_fw := case o.reporting_framework when 'ifrs_sme' then 'the IFRS for SMEs Accounting Standard' else 'IFRS Accounting Standards as issued by the IASB and adopted by the Financial Reporting Council of Nigeria' end;
  v := v || private.fr('1. General information', null, null, 'heading', 0)
    || private.fr(o.name || coalesce(' (RC ' || nullif(regexp_replace(o.rc_number, '^\s*RC\s*', '', 'i'), '') || ')', '') || ' is a business domiciled in Nigeria' || coalesce(', at ' || nullif(o.address, ''), '') || '.', null, null, 'text', 0)
    || private.fr('Its principal activity is ' || coalesce(nullif(o.principal_activity, ''), replace(coalesce(o.industry, 'trading'), '_', ' ')) || '. Tax identification number: ' || coalesce(nullif(o.tin, ''), 'not recorded') || '.', null, null, 'text', 0)
    || private.fr('These financial statements cover ' || to_char(p_from, 'FMDD FMMonth YYYY') || ' to ' || to_char(p_to, 'FMDD FMMonth YYYY') || ' and are presented in Nigerian naira (₦), the functional currency.', null, null, 'text', 0)
    || private.fr('2. Basis of preparation and significant accounting policies', null, null, 'heading', 0)
    || private.fr('The financial statements are prepared in accordance with ' || v_fw || ', on the historical cost basis and the going concern assumption.', null, null, 'text', 0)
    || case when p_pfrom is null then '[]'::jsonb else private.fr('Comparatives: profit or loss figures are for ' || to_char(p_pfrom, 'FMDD FMMonth YYYY') || ' to ' || to_char(p_pto, 'FMDD FMMonth YYYY')
         || '; balances are at ' || to_char(v_bpto, 'FMDD FMMonth YYYY') || case when v_bpto <> p_pto then ', the end of the previous financial year' else '' end || '.', null, null, 'text', 0) end
    || private.fr('Revenue (IFRS 15): recognised when control of goods passes to the customer at the point of sale or delivery, or as services are performed, at the transaction price net of VAT, discounts and returns.', null, null, 'text', 0)
    || private.fr('Inventories (IAS 2): measured at the lower of cost and net realisable value. Cost is weighted average and includes landed charges; production includes materials and absorbed labour.', null, null, 'text', 0)
    || private.fr('Property, plant and equipment (IAS 16): measured at cost less accumulated depreciation and impairment, depreciated on a straight-line basis over useful lives (computer hardware 3 years, motor vehicles 4 years, office equipment 4 years, furniture 5 years, plant 10 years, buildings 40 to 50 years). Land is not depreciated.', null, null, 'text', 0)
    || private.fr('Financial assets (IFRS 9): trade receivables are measured at amortised cost less a loss allowance under the simplified expected credit loss approach, using a provision matrix by age.', null, null, 'text', 0)
    || private.fr('Income taxes (IAS 12): current tax is the expected tax payable on taxable profit under the Nigeria Tax Act 2025, including the development levy.', null, null, 'text', 0)
    || private.fr('VAT: revenue and expenses are recognised net of value added tax where input VAT is recoverable. Withholding tax deducted by customers is a tax credit asset.', null, null, 'text', 0);
  -- 3 to 6: profit or loss lines by account
  for r in select * from (values ('3. Revenue', array['Revenue']), ('4. Cost of sales', array['Cost of sales']),
      ('5. Operating expenses by nature', array['Selling and distribution expenses', 'Administrative expenses', 'Impairment losses on financial assets', 'Other operating expenses',
        'Other expenses', 'Other income', 'Other gains and losses']), ('6. Finance income and finance costs', array['Finance income', 'Finance costs'])) t(title, lines) loop
    v_mv := (select jsonb_agg(private.fr(m.code || ' ' || m.name, -private.v(mvc, m.code), case when p_pfrom is null then null else -private.v(mvp, m.code) end, 'line', 1) order by m.code)
      from private.acct_meta(p_org) m where m.statement = 'pl' and (m.ifrs_line = any(r.lines) or (m.ifrs_line = 'Unclassified' and 'Other expenses' = any(r.lines)))
        and (private.v(mvc, m.code) <> 0 or private.v(mvp, m.code) <> 0));
    continue when v_mv is null;
    v := v || private.fr(r.title, null, null, 'heading', 0) || v_mv;
    if r.title like '3.%' then
      v := v || private.fr('By channel', null, null, 'subheading', 0) || coalesce((select jsonb_agg(private.fr(initcap(x.channel), x.amt, null, 'line', 1) order by x.amt desc) from (
          select s.channel, sum(case when s.doc_type = 'credit_note' then -s.subtotal else s.subtotal end) amt from sales s
          where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.issue_date between p_from and p_to group by 1) x), '[]'::jsonb);
    end if;
  end loop;
  -- 7 Income tax
  v := v || private.fr('7. Income tax', null, null, 'heading', 0)
    || private.fr('Current income tax and development levy charged', -private.v(plc, 'Income tax expense'), -private.v(plp, 'Income tax expense'), 'line', 1)
    || private.fr('Tax payable at the end of the period', private.v(c, 'Current tax liabilities'), private.v(p, 'Current tax liabilities'), 'line', 1)
    || private.fr('Withholding tax credits held', private.v(balc, '1401'), private.v(balp, '1401'), 'line', 1);
  -- 8 PPE roll-forward from the ledger, class by class
  v := v || private.fr('8. Property, plant and equipment', null, null, 'heading', 0);
  for r in select ac.* from asset_classes ac where private.v(balo, ac.cost_account) <> 0 or private.v(drc, ac.cost_account) <> 0 or private.v(crc, ac.cost_account) <> 0
           order by ac.cost_account loop
    v := v || private.fr(r.name, null, null, 'subheading', 1)
      || private.fr('Cost at the start', private.v(balo, r.cost_account), null, 'line', 2) || private.fr('Additions', private.v(drc, r.cost_account), null, 'line', 2)
      || private.fr('Disposals', -private.v(crc, r.cost_account), null, 'line', 2)
      || private.fr('Cost at the end', private.v(balo, r.cost_account) + private.v(drc, r.cost_account) - private.v(crc, r.cost_account), null, 'subtotal', 2);
    if r.accum_account is not null then
      v := v || private.fr('Accumulated depreciation at the start', private.v(balo, r.accum_account), null, 'line', 2)
        || private.fr('Charge for the period', -private.v(crc, r.accum_account), null, 'line', 2)
        || private.fr('On disposals', private.v(drc, r.accum_account), null, 'line', 2)
        || private.fr('Accumulated depreciation at the end', private.v(balo, r.accum_account) - private.v(crc, r.accum_account) + private.v(drc, r.accum_account), null, 'subtotal', 2);
    end if;
    v := v || private.fr('Carrying amount', private.v(balc, r.cost_account) + case when r.accum_account is not null then private.v(balc, r.accum_account) else 0 end, null, 'total', 2);
  end loop;
  -- 9 to 17: balances by account behind each line
  for r in select * from (values
      ('9. Inventories', array['Inventories']), ('10. Trade and other receivables', array['Trade and other receivables', 'Contract assets', 'Prepayments']),
      ('11. Cash and cash equivalents', array['Cash and cash equivalents']),
      ('12. Share capital and reserves', array['Share capital', 'Share premium', 'Deposit for shares', 'Other reserves', 'Retained earnings', 'Opening balances to be confirmed']),
      ('13. Trade and other payables', array['Trade and other payables', 'Contract liabilities']), ('14. Statutory liabilities', array['Other statutory liabilities', 'Current tax liabilities']),
      ('15. Borrowings', array['Borrowings (current)', 'Borrowings (non-current)', 'Lease liabilities (current)', 'Lease liabilities (non-current)']),
      ('17. Unreconciled balances', array['Unreconciled balances'])) t(title, lines) loop
    v_mv := (select jsonb_agg(private.fr(m.code || ' ' || m.name, sg * private.v(balc, m.code), case when v_bpto is null then null else sg * private.v(balp, m.code) end, 'line', 1) order by m.code)
      from (select mm.*, case when mm.code ~ '^(1|9)' then 1 else -1 end sg from private.acct_meta(p_org) mm where mm.ifrs_line = any(r.lines)) m
      where private.v(balc, m.code) <> 0 or private.v(balp, m.code) <> 0);
    continue when v_mv is null;
    v := v || private.fr(r.title, null, null, 'heading', 0) || v_mv;
    if r.title like '11.%' then
      v := v || private.fr('Cash and cash equivalents in the statement of cash flows', private.v(c, 'Cash and cash equivalents') - private.v(c, 'Bank overdrafts'),
        case when v_bpto is null then null else private.v(p, 'Cash and cash equivalents') - private.v(p, 'Bank overdrafts') end, 'subtotal', 0);
      if private.v(c, 'Bank overdrafts') <> 0 or private.v(p, 'Bank overdrafts') <> 0 then
        v := v || private.fr('Overdrawn accounts are shown under current liabilities as bank overdrafts. They are repayable on demand and part of day-to-day cash management, so the statement of cash flows counts them within cash (IAS 7.8).', null, null, 'text', 0);
      end if;
    end if;
    if r.title like '10.%' and private.v(c, '_customer_credit_reclass') > 0 then
      v := v || private.fr('Customers in credit, shown under contract liabilities', private.v(c, '_customer_credit_reclass'), null, 'line', 1);
    end if;
    if r.title like '12.%' then
      v := v || private.fr('Profit not yet closed to retained earnings', private.v(c, '_profit_unclosed'), private.v(p, '_profit_unclosed'), 'line', 1);
    end if;
    if r.title like '17.%' then
      v := v || private.fr('These are bank movements not yet explained and money between accounts. They must be cleared before the books are closed.', null, null, 'text', 0);
    end if;
  end loop;
  v := v || private.fr('16. Related parties', null, null, 'heading', 0)
    || private.fr('Directors'' current accounts (owed by directors)', private.v(balc, '1105'), private.v(balp, '1105'), 'line', 1)
    || private.fr('Loans from directors and shareholders', -(private.v(balc, '2303') + private.v(balc, '2502')), -(private.v(balp, '2303') + private.v(balp, '2502')), 'line', 1)
    || private.fr('18. Events after the reporting period', null, null, 'heading', 0)
    || private.fr('Management to confirm: no events after the reporting date require adjustment or disclosure.', null, null, 'text', 0);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Budgets
-- ---------------------------------------------------------------------------
create table if not exists public.budgets (
  org_id uuid not null references public.orgs(id) on delete cascade,
  account_code text not null,
  month date not null check (extract(day from month) = 1),
  amount numeric(16,2) not null,
  updated_by uuid references public.members(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (org_id, account_code, month)
);
create index if not exists budgets_updated_by_fk on public.budgets(updated_by);
alter table public.budgets enable row level security;
drop policy if exists budgets_read on public.budgets;
create policy budgets_read on public.budgets for select to authenticated using ((select private.can_handle_money(org_id)));

-- p_lines: [{account_code, month: 'YYYY-MM-01', amount}] — amounts as they appear in profit or loss (income and costs both positive).
create or replace function public.save_budget(p_org uuid, p_lines jsonb) returns int
language plpgsql security definer set search_path = public, private as $$
declare m public.members; x jsonb; n int := 0;
begin
  m := private.require(p_org, 'keep_books');
  for x in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    if not private.postable(p_org, x->>'account_code') then raise exception 'Account % cannot take a budget.', x->>'account_code'; end if;
    if private.num(x->>'amount') is null then
      delete from budgets where org_id = p_org and account_code = x->>'account_code' and month = date_trunc('month', (x->>'month')::date)::date;
    else
      insert into budgets (org_id, account_code, month, amount, updated_by) values (p_org, x->>'account_code', date_trunc('month', (x->>'month')::date)::date,
        round(private.num(x->>'amount'), 2), m.id)
      on conflict (org_id, account_code, month) do update set amount = excluded.amount, updated_by = excluded.updated_by, updated_at = now();
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- 5. The report function
-- ---------------------------------------------------------------------------
-- p_options: {compare: 'prior_year'|'prior_period'|'none', accounts: [codes], customer_id, vendor_id, bank_account_id, location_id, by, months}
create or replace function public.accounting_report(p_org uuid, p_report text, p_from date default null, p_to date default null, p_options jsonb default '{}'::jsonb)
returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs; v_today date; v_from date; v_to date; v_pfrom date; v_pto date; v_rows jsonb := '[]'::jsonb; v_extra jsonb := '{}'::jsonb;
  c jsonb; p jsonb; v_cmp text := coalesce(nullif(p_options->>'compare', ''), 'prior_year'); v_accts text[]; r record; v_cf jsonb; v_days numeric; v_months int;
  v_month date; v_cols jsonb; v_t jsonb; v_pt jsonb; v_bpto date;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Financial reports need See margins, Keep the books or Make payments.' using errcode = '42501'; end if;
  select * into o from orgs where id = p_org;
  v_today := private.local_day(p_org, now());
  v_to := coalesce(p_to, v_today);
  v_from := coalesce(p_from, case when p_report in ('sofp', 'sopl', 'soce', 'cash_flow', 'notes', 'ratios', 'pack') then private.fy_start(p_org, v_to)
                                  else date_trunc('month', v_to)::date end);
  if v_from > v_to then raise exception 'The start date is after the end date.'; end if;
  if v_cmp = 'prior_period' then v_pto := v_from - 1; v_pfrom := v_from - (v_to - v_from) - 1;
  elsif v_cmp = 'prior_year' then v_pto := (v_to - interval '1 year')::date; v_pfrom := (v_from - interval '1 year')::date;
  end if;
  -- The statement of financial position compares with the end of the previous financial year (IAS 1.38; IAS 34.20(a) for part-years).
  v_bpto := case when v_cmp = 'prior_year' then private.fy_start(p_org, v_to) - 1 else v_pto end;
  v_extra := jsonb_build_object('from', v_from, 'to', v_to, 'prior_from', v_pfrom, 'prior_to', v_pto, 'org', jsonb_build_object('name', o.name, 'tin', o.tin,
    'rc_number', o.rc_number, 'address', o.address, 'framework', o.reporting_framework), 'closed_through', private.closed_through(p_org));
  if jsonb_typeof(p_options->'accounts') = 'array' then select array_agg(value) into v_accts from jsonb_array_elements_text(p_options->'accounts'); end if;

  if p_report = 'coa' then
    select jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name, 'parent', a.parent_code, 'category', a.category, 'normal_balance', a.normal_balance,
        'statement', case a.statement when 'sofp' then 'Financial position' when 'pl' then 'Profit or loss' when 'oci' then 'Other comprehensive income' else 'System' end,
        'ifrs_line', a.ifrs_line, 'cash_flow', a.cash_flow_class, 'postable', private.postable(p_org, a.code), 'own', a.own, 'active', a.active,
        'balance', coalesce(b.bal, 0), '_style', case when a.is_group then 'subheading' else 'line' end, '_indent', case when a.is_group then 0 else 1 end) order by a.code)
    into v_rows from private.accounts_of(p_org) a left join private.balances_at(p_org, v_to) b on b.code = a.code
    where a.active or coalesce(b.bal, 0) <> 0;

  elsif p_report = 'trial_balance' then
    select jsonb_agg(x order by x->>'code') into v_rows from (
      select jsonb_build_object('code', m2.code, 'name', m2.name, 'ifrs_line', m2.ifrs_line, 'category', m2.category,
        'opening', coalesce(ob.bal, 0), 'debit', coalesce(mv.dr, 0), 'credit', coalesce(mv.cr, 0),
        'closing_dr', greatest(coalesce(ob.bal, 0) + coalesce(mv.net, 0) + coalesce(ye.net, 0), 0), 'closing_cr', greatest(-(coalesce(ob.bal, 0) + coalesce(mv.net, 0) + coalesce(ye.net, 0)), 0)) x
      from private.acct_meta(p_org) m2
      left join private.balances_at(p_org, v_from - 1) ob on ob.code = m2.code
      left join private.movement(p_org, v_from, v_to) mv on mv.code = m2.code
      left join (select l.account_code code, sum(l.debit - l.credit) net from journal_lines l join journals j on j.id = l.journal_id
                 where l.org_id = p_org and j.entry_date between v_from and v_to and j.source_type = 'year_end' group by 1) ye on ye.code = m2.code
      where coalesce(ob.bal, 0) <> 0 or coalesce(mv.dr, 0) <> 0 or coalesce(mv.cr, 0) <> 0 or coalesce(ye.net, 0) <> 0) t;
    v_extra := v_extra || jsonb_build_object('total_dr', (select sum((x->>'closing_dr')::numeric) from jsonb_array_elements(coalesce(v_rows, '[]')) x),
      'total_cr', (select sum((x->>'closing_cr')::numeric) from jsonb_array_elements(coalesce(v_rows, '[]')) x));
    v_extra := v_extra || jsonb_build_object('balances', abs((v_extra->>'total_dr')::numeric - (v_extra->>'total_cr')::numeric) < 0.01);

  elsif p_report in ('gl', 'account_ledger') then
    with ob as (select * from private.balances_at(p_org, v_from - 1)),
    meta as (select * from private.acct_meta(p_org)),
    ln as (select l.id, l.account_code, l.debit, l.credit, l.memo, l.party_id, j.entry_date, j.je_no, j.ref, j.memo jmemo, j.source_type, j.origin, j.ai_confidence
           from journal_lines l join journals j on j.id = l.journal_id
           where l.org_id = p_org and j.entry_date between v_from and v_to and (v_accts is null or l.account_code = any(v_accts))),
    accts as (select distinct account_code code from ln union select code from ob where bal <> 0 and (v_accts is null or code = any(v_accts)))
    select jsonb_agg(x order by x->>'code', (x->>'_seq')::numeric) into v_rows from (
      select jsonb_build_object('code', a.code, 'account', a.code || ' ' || coalesce(m2.name, ''), 'memo', 'Opening balance', 'balance', coalesce(ob.bal, 0),
        '_style', 'subheading', '_seq', 0) x
      from accts a left join meta m2 on m2.code = a.code left join ob on ob.code = a.code
      union all
      select jsonb_build_object('code', ln.account_code, 'account', ln.account_code || ' ' || coalesce(m2.name, ''), 'date', ln.entry_date, 'ref', ln.ref,
        'memo', coalesce(ln.memo, ln.jmemo), 'source', ln.source_type, 'origin', ln.origin, 'ai_confidence', ln.ai_confidence,
        'party', coalesce((select name from customers where id = ln.party_id), (select name from vendors where id = ln.party_id)),
        'debit', ln.debit, 'credit', ln.credit,
        'balance', coalesce(ob.bal, 0) + sum(ln.debit - ln.credit) over (partition by ln.account_code order by ln.entry_date, ln.je_no, ln.id),
        '_seq', ln.entry_date - date '2000-01-01' + ln.je_no / 1e7) x
      from ln left join ob on ob.code = ln.account_code left join meta m2 on m2.code = ln.account_code
      limit 60000) t;

  elsif p_report = 'journals' then
    select jsonb_agg(jsonb_build_object('date', j.entry_date, 'ref', j.ref, 'memo', j.memo, 'source', j.source_type, 'origin', j.origin, 'ai_confidence', j.ai_confidence,
        'code', l.account_code, 'account_name', private.account_name(p_org, l.account_code), 'debit', l.debit, 'credit', l.credit, 'line_memo', l.memo,
        'party', coalesce((select name from customers where id = l.party_id), (select name from vendors where id = l.party_id)),
        'posted_by', (select display_name from members where id = j.posted_by), 'approved_by', (select display_name from members where id = j.approved_by),
        'reversal_of', (select ref from journals where id = j.reversal_of)) order by j.entry_date, j.je_no, l.debit desc)
    into v_rows from journals j join journal_lines l on l.journal_id = j.id where j.org_id = p_org and j.entry_date between v_from and v_to;

  elsif p_report in ('ar_ledger', 'ap_ledger') then
    select jsonb_agg(jsonb_build_object('party', x.name, 'opening', x.opening, 'debit', x.dr, 'credit', x.cr, 'closing', x.opening + x.dr - x.cr) order by x.name) into v_rows from (
      select pp.name, coalesce(sum(case when j.entry_date < v_from then l.debit - l.credit end), 0) * case when p_report = 'ap_ledger' then -1 else 1 end opening,
        coalesce(sum(case when j.entry_date >= v_from then case when p_report = 'ap_ledger' then l.credit else l.debit end end), 0) dr,
        coalesce(sum(case when j.entry_date >= v_from then case when p_report = 'ap_ledger' then l.debit else l.credit end end), 0) cr
      from journal_lines l join journals j on j.id = l.journal_id
      join (select id, name from customers where org_id = p_org and p_report = 'ar_ledger' union all select id, name from vendors where org_id = p_org and p_report = 'ap_ledger') pp
        on pp.id = l.party_id
      where l.org_id = p_org and j.entry_date <= v_to and l.party_type = case when p_report = 'ar_ledger' then 'customer' else 'vendor' end
        and l.account_code in (case when p_report = 'ar_ledger' then '1101' else '2101' end, case when p_report = 'ar_ledger' then '1102' else '2102' end,
          case when p_report = 'ar_ledger' then '2107' else '2101' end)
      group by pp.name) x where x.opening <> 0 or x.dr <> 0 or x.cr <> 0;
    -- Sub-ledger against control account (AR-01, AP-01).
    v_extra := v_extra || jsonb_build_object('subledger_total', (select coalesce(sum((x->>'closing')::numeric), 0) from jsonb_array_elements(coalesce(v_rows, '[]')) x),
      'control_total', (select coalesce(sum(b.bal), 0) * case when p_report = 'ap_ledger' then -1 else 1 end from private.balances_at(p_org, v_to) b
        where b.code in (case when p_report = 'ar_ledger' then '1101' else '2101' end, case when p_report = 'ar_ledger' then '1102' else '2102' end,
          case when p_report = 'ar_ledger' then '2107' else '2101' end)),
      'unassigned', (select coalesce(sum(l.debit - l.credit), 0) * case when p_report = 'ap_ledger' then -1 else 1 end from journal_lines l join journals j on j.id = l.journal_id
        where l.org_id = p_org and j.entry_date <= v_to and l.party_id is null
          and l.account_code in (case when p_report = 'ar_ledger' then '1101' else '2101' end, case when p_report = 'ar_ledger' then '1102' else '2102' end)));

  elsif p_report in ('ar_aging', 'ap_aging') then
    if p_report = 'ar_aging' then
      select jsonb_agg(jsonb_build_object('party', x.name, 'current', x.b0, 'd1_30', x.b1, 'd31_60', x.b2, 'd61_90', x.b3, 'd90_plus', x.b4, 'total', x.b0 + x.b1 + x.b2 + x.b3 + x.b4,
          'credit_limit', x.credit_limit) order by x.b0 + x.b1 + x.b2 + x.b3 + x.b4 desc) into v_rows from (
        select cu.name, cu.credit_limit,
          sum(bal) filter (where age <= 0) b0, sum(bal) filter (where age between 1 and 30) b1, sum(bal) filter (where age between 31 and 60) b2,
          sum(bal) filter (where age between 61 and 90) b3, sum(bal) filter (where age > 90) b4
        from (select s.customer_id, s.total - s.amount_paid - s.credited bal, v_to - coalesce(s.due_date, s.issue_date) age from sales s
              where s.org_id = p_org and s.status in ('open', 'partially_paid') and s.journal_id is not null and s.issue_date <= v_to) d
        join customers cu on cu.id = d.customer_id group by cu.name, cu.credit_limit) x;
    else
      select jsonb_agg(jsonb_build_object('party', x.name, 'current', x.b0, 'd1_30', x.b1, 'd31_60', x.b2, 'd61_90', x.b3, 'd90_plus', x.b4, 'total', x.b0 + x.b1 + x.b2 + x.b3 + x.b4)
          order by x.b0 + x.b1 + x.b2 + x.b3 + x.b4 desc) into v_rows from (
        select v.name, sum(bal) filter (where age <= 0) b0, sum(bal) filter (where age between 1 and 30) b1, sum(bal) filter (where age between 31 and 60) b2,
          sum(bal) filter (where age between 61 and 90) b3, sum(bal) filter (where age > 90) b4
        from (select b.vendor_id, b.total - b.amount_paid bal, v_to - b.due_date age from bills b where b.org_id = p_org and b.status in ('approved', 'partially_paid') and b.bill_date <= v_to) d
        join vendors v on v.id = d.vendor_id group by v.name) x;
    end if;
    v_rows := coalesce(v_rows, '[]'::jsonb);
    v_rows := (select jsonb_agg(x || jsonb_build_object('current', coalesce((x->>'current')::numeric, 0), 'd1_30', coalesce((x->>'d1_30')::numeric, 0),
      'd31_60', coalesce((x->>'d31_60')::numeric, 0), 'd61_90', coalesce((x->>'d61_90')::numeric, 0), 'd90_plus', coalesce((x->>'d90_plus')::numeric, 0),
      'total', coalesce((x->>'current')::numeric, 0) + coalesce((x->>'d1_30')::numeric, 0) + coalesce((x->>'d31_60')::numeric, 0) + coalesce((x->>'d61_90')::numeric, 0)
        + coalesce((x->>'d90_plus')::numeric, 0))) from jsonb_array_elements(v_rows) x);

  elsif p_report = 'fixed_assets' then
    select jsonb_agg(jsonb_build_object('number', a.number, 'name', a.name, 'class', ac.name, 'location', (select name from locations where id = a.location_id),
        'available_date', a.available_date, 'life_months', a.life_months, 'status', a.status, 'cost', a.cost,
        'accumulated', private.asset_accumulated(a.id), 'carrying_amount', a.cost - private.asset_accumulated(a.id),
        'charge_period', coalesce((select sum(l.credit - l.debit) from journal_lines l join journals j on j.id = l.journal_id where l.party_type = 'asset' and l.party_id = a.id
          and j.entry_date between v_from and v_to and j.source_type = 'depreciation'), 0),
        'disposed_at', a.disposed_at, 'proceeds', a.proceeds, 'serial_no', a.serial_no) order by a.number)
    into v_rows from fixed_assets a join asset_classes ac on ac.cost_account = a.class_account
    where a.org_id = p_org and a.status in ('active', 'pending_confirmation', 'disposed') and coalesce(a.disposed_at, v_to) >= v_from;

  elsif p_report = 'sofp' then
    c := private.sofp_map(p_org, v_to);
    p := case when v_bpto is null then '{}'::jsonb else private.sofp_map(p_org, v_bpto) end;
    v_rows := private.sofp_rows(c, p);
    v_extra := v_extra || jsonb_build_object('prior_from', null, 'prior_to', v_bpto);
    v_extra := v_extra || jsonb_build_object('check', jsonb_build_object(
      'assets', (select (x->>'current')::numeric from jsonb_array_elements(v_rows) x where x->>'line' = 'Total assets'),
      'equity_and_liabilities', (select (x->>'current')::numeric from jsonb_array_elements(v_rows) x where x->>'line' = 'Total equity and liabilities')),
      'unreconciled', private.v(c, 'Unreconciled balances (assets)') + private.v(c, 'Unreconciled balances (liabilities)'),
      'opening_to_confirm', private.v(c, 'Opening balances to be confirmed'));
    v_extra := v_extra || jsonb_build_object('casts', abs(((v_extra->'check')->>'assets')::numeric - ((v_extra->'check')->>'equity_and_liabilities')::numeric) < 0.01);

  elsif p_report = 'sopl' then
    c := private.pl_map(p_org, v_from, v_to);
    p := case when v_pfrom is null then '{}'::jsonb else private.pl_map(p_org, v_pfrom, v_pto) end;
    v_rows := private.sopl_rows(c, p);
    v_extra := v_extra || jsonb_build_object('totals', private.pl_totals(c));

  elsif p_report = 'soce' then
    v_rows := private.soce_rows(p_org, v_from, v_to);

  elsif p_report = 'cash_flow' then
    v_cf := private.cash_flow_rows(p_org, v_from, v_to, v_pfrom, v_pto);
    v_rows := v_cf->'rows';
    v_extra := v_extra || jsonb_build_object('check', v_cf->'check', 'casts', (v_cf->'check'->>'ties')::boolean);

  elsif p_report = 'notes' then
    v_rows := private.note_rows(p_org, v_from, v_to, v_pfrom, v_pto, v_bpto);

  elsif p_report = 'ratios' then
    c := private.sofp_map(p_org, v_to); p := case when v_pto is null then '{}'::jsonb else private.sofp_map(p_org, v_pto) end;
    v_t := private.pl_totals(private.pl_map(p_org, v_from, v_to));
    v_pt := case when v_pfrom is null then '{}'::jsonb else private.pl_totals(private.pl_map(p_org, v_pfrom, v_pto)) end;
    v_days := v_to - v_from + 1;
    select jsonb_agg(jsonb_build_object('group', g, 'ratio', n, 'current', cur, 'prior', pri, 'formula', f, 'reading', rd, 'unit', u)) into v_rows from (values
      ('Liquidity', 'Current ratio', private.ratio(private.cur_assets(c), private.cur_liabs(c)), private.ratio(private.cur_assets(p), private.cur_liabs(p)),
        'Current assets ÷ current liabilities', 'Above 1.5 is comfortable; below 1 means short-term debts exceed short-term assets.', 'x'),
      ('Liquidity', 'Quick ratio', private.ratio(private.cur_assets(c) - private.v(c, 'Inventories'), private.cur_liabs(c)),
        private.ratio(private.cur_assets(p) - private.v(p, 'Inventories'), private.cur_liabs(p)), '(Current assets − inventories) ÷ current liabilities',
        'Ability to pay current debts without selling stock.', 'x'),
      ('Liquidity', 'Cash ratio', private.ratio(private.v(c, 'Cash and cash equivalents'), private.cur_liabs(c)), private.ratio(private.v(p, 'Cash and cash equivalents'), private.cur_liabs(p)),
        'Cash ÷ current liabilities', 'Share of current debts payable from cash today.', 'x'),
      ('Profitability', 'Gross margin', private.pct(private.v(v_t, 'gross_profit'), private.v(v_t, 'revenue')), private.pct(private.v(v_pt, 'gross_profit'), private.v(v_pt, 'revenue')),
        'Gross profit ÷ revenue', 'What each ₦100 of sales leaves after the cost of the goods.', '%'),
      ('Profitability', 'Operating margin', private.pct(private.v(v_t, 'operating_profit'), private.v(v_t, 'revenue')), private.pct(private.v(v_pt, 'operating_profit'), private.v(v_pt, 'revenue')),
        'Operating profit ÷ revenue', 'Profit from running the business before finance and tax.', '%'),
      ('Profitability', 'Net margin', private.pct(private.v(v_t, 'profit'), private.v(v_t, 'revenue')), private.pct(private.v(v_pt, 'profit'), private.v(v_pt, 'revenue')),
        'Profit for the period ÷ revenue', 'What is left for the owners from each ₦100 of sales.', '%'),
      ('Profitability', 'Return on assets (annualised)', private.pct(private.v(v_t, 'profit') * 365 / v_days, private.tot_assets(c)), private.pct(private.v(v_pt, 'profit') * 365 / v_days, private.tot_assets(p)),
        'Profit × 365 ÷ days ÷ total assets', 'How hard the assets work.', '%'),
      ('Profitability', 'Return on equity (annualised)', private.pct(private.v(v_t, 'profit') * 365 / v_days, private.tot_equity(c)), private.pct(private.v(v_pt, 'profit') * 365 / v_days, private.tot_equity(p)),
        'Profit × 365 ÷ days ÷ equity', 'Return earned on the owners'' money.', '%'),
      ('Efficiency', 'Stock days', private.ratio(private.v(c, 'Inventories') * v_days, private.v(v_t, 'cost_of_sales')), private.ratio(private.v(p, 'Inventories') * v_days, private.v(v_pt, 'cost_of_sales')),
        'Inventories ÷ cost of sales × days', 'How long stock sits before it sells.', 'days'),
      ('Efficiency', 'Debtor days', private.ratio(private.v(c, 'Trade and other receivables') * v_days, private.v(v_t, 'revenue') * 1.075),
        private.ratio(private.v(p, 'Trade and other receivables') * v_days, private.v(v_pt, 'revenue') * 1.075), 'Receivables ÷ revenue incl. VAT × days', 'How long customers take to pay.', 'days'),
      ('Efficiency', 'Creditor days', private.ratio(private.v(c, 'Trade and other payables') * v_days, private.v(v_t, 'cost_of_sales') * 1.075),
        private.ratio(private.v(p, 'Trade and other payables') * v_days, private.v(v_pt, 'cost_of_sales') * 1.075), 'Payables ÷ cost of sales incl. VAT × days', 'How long the business takes to pay suppliers.', 'days'),
      ('Efficiency', 'Asset turnover (annualised)', private.ratio(private.v(v_t, 'revenue') * 365 / v_days, private.tot_assets(c)), private.ratio(private.v(v_pt, 'revenue') * 365 / v_days, private.tot_assets(p)),
        'Revenue × 365 ÷ days ÷ total assets', 'Sales generated by each ₦1 of assets.', 'x'),
      ('Leverage', 'Debt to equity', private.ratio(private.v(c, 'Bank overdrafts') + private.v(c, 'Borrowings (current)') + private.v(c, 'Borrowings (non-current)')
          + private.v(c, 'Lease liabilities (current)') + private.v(c, 'Lease liabilities (non-current)'), private.tot_equity(c)),
        private.ratio(private.v(p, 'Bank overdrafts') + private.v(p, 'Borrowings (current)') + private.v(p, 'Borrowings (non-current)')
          + private.v(p, 'Lease liabilities (current)') + private.v(p, 'Lease liabilities (non-current)'), private.tot_equity(p)),
        'Borrowings, overdrafts and leases ÷ equity', 'How much of the business is funded by lenders.', 'x'),
      ('Leverage', 'Interest cover', private.ratio(private.v(v_t, 'operating_profit'), private.v(v_t, 'finance_costs')), private.ratio(private.v(v_pt, 'operating_profit'), private.v(v_pt, 'finance_costs')),
        'Operating profit ÷ finance costs', 'Times interest is covered by profit. Below 2 is tight.', 'x')
    ) t(g, n, cur, pri, f, rd, u);
    v_extra := v_extra || jsonb_build_object('cash_conversion_cycle',
      (select coalesce(sum(case when x->>'ratio' in ('Stock days', 'Debtor days') then (x->>'current')::numeric when x->>'ratio' = 'Creditor days' then -(x->>'current')::numeric end), 0)
       from jsonb_array_elements(v_rows) x));

  elsif p_report in ('management_accounts', 'budget_vs_actual') then
    -- Profit or loss by month (columns m1..m12) or against budget.
    v_months := least(greatest(((extract(year from v_to) - extract(year from v_from)) * 12 + extract(month from v_to) - extract(month from v_from) + 1)::int, 1), 24);
    if p_report = 'management_accounts' then
      v_cols := (select jsonb_agg(jsonb_build_object('key', 'm' || i, 'label', to_char((date_trunc('month', v_from) + make_interval(months => i - 1))::date, 'Mon YY'))) from generate_series(1, v_months) i);
      with mm as (select l.account_code code, ((extract(year from j.entry_date) - extract(year from v_from)) * 12 + extract(month from j.entry_date) - extract(month from v_from) + 1)::int idx,
                     -sum(l.debit - l.credit) amt
                  from journal_lines l join journals j on j.id = l.journal_id
                  where l.org_id = p_org and j.entry_date between v_from and v_to and j.source_type is distinct from 'year_end' group by 1, 2),
      meta as (select * from private.acct_meta(p_org) where statement = 'pl')
      select jsonb_agg(row order by sort, code) into v_rows from (
        select m2.code, case m2.ifrs_line when 'Revenue' then 1 when 'Cost of sales' then 2 when 'Other income' then 3 else 4 end sort,
          jsonb_build_object('code', m2.code, 'account', m2.name, 'ifrs_line', m2.ifrs_line)
          || coalesce((select jsonb_object_agg('m' || mm.idx, mm.amt) from mm where mm.code = m2.code), '{}'::jsonb)
          || jsonb_build_object('total', (select sum(mm.amt) from mm where mm.code = m2.code)) row
        from meta m2 where exists (select 1 from mm where mm.code = m2.code)) z;
      v_extra := v_extra || jsonb_build_object('columns', v_cols);
    else
      select jsonb_agg(jsonb_build_object('code', x.code, 'account', x.name, 'budget', x.budget, 'actual', x.actual, 'variance', x.actual - x.budget,
          'variance_pct', case when x.budget <> 0 then round((x.actual - x.budget) / abs(x.budget) * 100, 1) end) order by x.code) into v_rows from (
        select a.code, a.name, coalesce((select sum(amount) from budgets b where b.org_id = p_org and b.account_code = a.code and b.month between date_trunc('month', v_from) and v_to), 0) budget,
          abs(coalesce((select sum(mv.net) from private.movement(p_org, v_from, v_to) mv where mv.code = a.code), 0)) actual
        from private.acct_meta(p_org) a where a.statement = 'pl'
          and (exists (select 1 from budgets b where b.org_id = p_org and b.account_code = a.code and b.month between date_trunc('month', v_from) and v_to)
               or exists (select 1 from private.movement(p_org, v_from, v_to) mv where mv.code = a.code))) x;
    end if;

  elsif p_report = 'trends' then
    v_months := least(greatest(coalesce((p_options->>'months')::int, 12), 2), 36);
    select jsonb_agg(row order by mo) into v_rows from (
      select mo, (select jsonb_build_object('month', to_char(mo, 'Mon YYYY'), 'revenue', private.v(t, 'revenue'), 'gross_profit', private.v(t, 'gross_profit'),
          'gross_margin', private.pct(private.v(t, 'gross_profit'), private.v(t, 'revenue')), 'opex', private.v(t, 'opex'), 'profit', private.v(t, 'profit'),
          'cash', private.v(s, 'Cash and cash equivalents'), 'receivables', private.v(s, 'Trade and other receivables'), 'payables', private.v(s, 'Trade and other payables'),
          'inventories', private.v(s, 'Inventories'))
        from (select private.pl_totals(private.pl_map(p_org, mo, (mo + interval '1 month' - interval '1 day')::date)) t,
                     private.sofp_map(p_org, least((mo + interval '1 month' - interval '1 day')::date, v_to)) s) q) row
      from (select g::date mo from generate_series(date_trunc('month', v_to) - make_interval(months => v_months - 1), date_trunc('month', v_to), interval '1 month') g) gs) z;

  elsif p_report = 'cash_forecast' then
    v_rows := private.cash_forecast(p_org, v_to);

  elsif p_report = 'vat_return' then
    v_from := date_trunc('month', v_to)::date; v_to := (date_trunc('month', v_to) + interval '1 month' - interval '1 day')::date;
    v_rows := private.vat_rows(p_org, v_from, v_to);
    v_extra := v_extra || jsonb_build_object('from', v_from, 'to', v_to, 'due', (v_to + 21)::date);

  elsif p_report = 'wht_schedule' then
    select jsonb_agg(x order by x->>'date') into v_rows from (
      select jsonb_build_object('kind', 'Deducted from vendors (pay to NRS)', 'date', private.local_day(p_org, bp.paid_at), 'party', v.name, 'tin', v.tin,
        'individual', v.is_individual, 'category', (select name from wht_rates where code = b.wht_category), 'rate', b.wht_rate,
        'base', round(bp.wht / nullif(b.wht_rate, 0), 2), 'wht', bp.wht, 'document', b.number || coalesce(' · ' || b.vendor_ref, '')) x
      from bill_payments bp join bills b on b.id = bp.bill_id join vendors v on v.id = b.vendor_id
      where bp.org_id = p_org and bp.status = 'paid' and bp.wht > 0 and private.local_day(p_org, bp.paid_at) between v_from and v_to
      union all
      select jsonb_build_object('kind', 'Deducted by customers (credit to collect)', 'date', private.local_day(p_org, c2.received_at), 'party', cu.name, 'tin', cu.tin,
        'rate', c2.wht_rate, 'base', round(c2.amount / nullif(c2.wht_rate, 0), 2), 'wht', c2.amount,
        'document', (select string_agg(s.number, ', ') from collection_allocations a join sales s on s.id = a.sale_id where a.collection_id = c2.id))
      from collections c2 join customers cu on cu.id = c2.customer_id
      where c2.org_id = p_org and c2.method = 'wht_credit' and c2.status = 'confirmed' and private.local_day(p_org, c2.received_at) between v_from and v_to) t;
    v_extra := v_extra || jsonb_build_object('payable_balance', -coalesce((select sum(bal) from private.balances_at(p_org, v_to) where code = '2202'), 0),
      'receivable_balance', coalesce((select sum(bal) from private.balances_at(p_org, v_to) where code = '1401'), 0));

  elsif p_report = 'sales_analysis' then
    v_rows := private.sales_analysis(p_org, v_from, v_to, coalesce(nullif(p_options->>'by', ''), 'item'), private.can_see_costs(p_org));

  elsif p_report = 'kpis' then
    v_rows := jsonb_build_array(public.get_finance_overview(p_org));

  else
    raise exception 'Unknown report %.', p_report;
  end if;
  return jsonb_build_object('rows', coalesce(v_rows, '[]'::jsonb), 'extra', v_extra);
end $$;

create or replace function private.ratio(a numeric, b numeric) returns numeric
language sql immutable set search_path = '' as $$ select case when b is null or b = 0 then null else round(a / b, 2) end $$;
create or replace function private.pct(a numeric, b numeric) returns numeric
language sql immutable set search_path = '' as $$ select case when b is null or b = 0 then null else round(a / b * 100, 1) end $$;
create or replace function private.cur_assets(c jsonb) returns numeric
language sql immutable set search_path = public, private as $$
  select coalesce(sum(private.v(c, l)), 0) from unnest(array['Inventories', 'Trade and other receivables', 'Contract assets', 'Prepayments', 'Other current financial assets',
    'Current tax assets', 'Assets held for sale', 'Other current assets', 'Cash and cash equivalents', 'Unreconciled balances (assets)']) l
$$;
create or replace function private.cur_liabs(c jsonb) returns numeric
language sql immutable set search_path = public, private as $$
  select coalesce(sum(private.v(c, l)), 0) from unnest(array['Trade and other payables', 'Contract liabilities', 'Current tax liabilities', 'Other statutory liabilities',
    'Bank overdrafts', 'Borrowings (current)', 'Lease liabilities (current)', 'Provisions (current)', 'Other current liabilities', 'Unreconciled balances (liabilities)']) l
$$;
create or replace function private.tot_assets(c jsonb) returns numeric
language sql immutable set search_path = public, private as $$ select coalesce(sum(private.v(c, l)), 0) from unnest(private.asset_lines()) l $$;
create or replace function private.tot_equity(c jsonb) returns numeric
language sql immutable set search_path = public, private as $$
  select coalesce(sum(private.v(c, l)), 0) from unnest(array['Share capital', 'Share premium', 'Deposit for shares', 'Other reserves', 'Retained earnings',
    'Opening balances to be confirmed', 'Non-controlling interests']) l
$$;

-- VAT return for a month: output VAT from sales and credit notes, input VAT from bills and stock receipts, tied to the ledger (TAX-05).
create or replace function private.vat_rows(p_org uuid, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = public, private as $$
  with sl as (select s.doc_type, l.vat_treatment, l.net, l.vat from sales s join sale_lines l on l.sale_id = s.id
              where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.issue_date between p_from and p_to),
  so as (select coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'standard'), 0) std,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'zero'), 0) zero,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'exempt'), 0) exempt,
                coalesce(sum(case when doc_type = 'credit_note' then -vat else vat end), 0) vat from sl),
  bi as (select coalesce(sum(bl.vat) filter (where bl.vat_recoverable), 0) vat, coalesce(sum(bl.net) filter (where bl.vat > 0), 0) base from bills b join bill_lines bl on bl.bill_id = b.id
         where b.org_id = p_org and b.source <> 'receipt' and b.journal_id is not null and b.status <> 'void' and b.bill_date between p_from and p_to),
  rc as (select coalesce(sum(input_vat), 0) vat, coalesce(sum(net) filter (where input_vat > 0), 0) base from receipts
         where org_id = p_org and status = 'posted' and private.local_day(org_id, coalesce(posted_at, created_at)) between p_from and p_to),
  led as (select coalesce(sum(mv.cr - mv.dr) filter (where mv.code = '2201'), 0) out_ledger, coalesce(sum(mv.dr - mv.cr) filter (where mv.code = '1402'), 0) in_ledger
          from (select l.account_code code, sum(l.debit) dr, sum(l.credit) cr from journal_lines l join journals j on j.id = l.journal_id
                where l.org_id = p_org and j.entry_date between p_from and p_to and j.source_type in ('sale', 'bill', 'receipt') group by 1) mv)
  select jsonb_build_array(
    private.fr('Output VAT', null, null, 'heading', 0),
    private.fr('Standard-rated supplies (7.5%)', so.std, null, 'line', 1),
    private.fr('Zero-rated supplies', so.zero, null, 'line', 1),
    private.fr('Exempt supplies', so.exempt, null, 'line', 1),
    private.fr('Output VAT charged', so.vat, null, 'subtotal', 0),
    private.fr('Input VAT', null, null, 'heading', 0),
    private.fr('Purchases and expenses on bills (taxable value ' || to_char(bi.base, 'FM999,999,999,990.00') || ')', bi.vat, null, 'line', 1),
    private.fr('Stock received (taxable value ' || to_char(rc.base, 'FM999,999,999,990.00') || ')', rc.vat, null, 'line', 1),
    private.fr('Input VAT recoverable', bi.vat + rc.vat, null, 'subtotal', 0),
    private.fr('VAT payable / (refundable) for the month', so.vat - bi.vat - rc.vat, null, 'total', 0),
    private.fr('Ledger check', null, null, 'heading', 0),
    private.fr('Output VAT in the ledger (2201) from sales', led.out_ledger, null, 'line', 1),
    private.fr('Input VAT in the ledger (1402) from bills and receipts', led.in_ledger, null, 'line', 1),
    private.fr('Difference to explain', (so.vat - led.out_ledger) - (bi.vat + rc.vat - led.in_ledger), null, 'subtotal', 0))
  from so, bi, rc, led
$$;

create or replace function private.sales_analysis(p_org uuid, p_from date, p_to date, p_by text, p_cost boolean) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', k, 'documents', docs, 'qty', qty, 'net', net, 'vat', vat, 'gross', gross,
      'cost', case when p_cost then cost end, 'margin', case when p_cost then net - cost end,
      'margin_pct', case when p_cost and net <> 0 then round((net - cost) / net * 100, 1) end) order by net desc), '[]'::jsonb)
  from (
    select case p_by when 'customer' then s.customer_name when 'channel' then initcap(s.channel) when 'branch' then (select name from locations where id = s.location_id)
                when 'cashier' then coalesce((select display_name from members where id = s.created_by), 'Online') when 'month' then to_char(s.issue_date, 'YYYY-MM')
                when 'day' then to_char(s.issue_date, 'YYYY-MM-DD') else l.description end k,
      count(distinct s.id) docs, sum(case when s.doc_type = 'credit_note' then -l.qty else l.qty end * l.unit_factor) qty,
      sum(case when s.doc_type = 'credit_note' then -l.net else l.net end) net, sum(case when s.doc_type = 'credit_note' then -l.vat else l.vat end) vat,
      sum(case when s.doc_type = 'credit_note' then -l.gross else l.gross end) gross, sum(case when s.doc_type = 'credit_note' then -coalesce(l.cost, 0) else coalesce(l.cost, 0) end) cost
    from sales s join sale_lines l on l.sale_id = s.id
    where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.issue_date between p_from and p_to
      and (p_by <> 'item' or l.kind <> 'delivery')
    group by 1) x
$$;

-- Thirteen weeks of cash: what customers owe by due date, bills by due date, the business's usual weekly cash in and out, and VAT on the 21st.
create or replace function private.cash_forecast(p_org uuid, p_from date) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_cash numeric; v_in numeric; v_out numeric; v jsonb := '[]'::jsonb; w int; v_ws date; v_we date; v_ar numeric; v_ap numeric; v_vat numeric; v_close numeric;
  v_cashacc text[]; v_vat_due numeric;
begin
  select array_agg(code) into v_cashacc from private.acct_meta(p_org) where ifrs_line = 'Cash and cash equivalents';
  select coalesce(sum(bal), 0) into v_cash from private.balances_at(p_org, p_from) where code = any(v_cashacc);
  -- Usual weekly cash not tied to invoices or bills, from the last eight weeks.
  select coalesce(sum(l.debit - l.credit) filter (where l.debit > l.credit), 0) / 8, coalesce(sum(l.credit - l.debit) filter (where l.credit > l.debit), 0) / 8
  into v_in, v_out
  from journal_lines l join journals j on j.id = l.journal_id
  where l.org_id = p_org and l.account_code = any(v_cashacc) and j.entry_date between p_from - 56 and p_from
    and j.source_type not in ('bill_payment', 'payout', 'opening', 'reclass') and not exists (select 1 from journal_lines x where x.journal_id = j.id and x.account_code = any(v_cashacc) and x.id <> l.id)
    and not exists (select 1 from collection_allocations a join collections c on c.id = a.collection_id join sales s on s.id = a.sale_id
                    where c.journal_id = j.id and s.doc_type = 'invoice');
  v_vat_due := greatest(-coalesce((select sum(bal) from private.balances_at(p_org, p_from) where code = '2201'), 0)
    - coalesce((select sum(bal) from private.balances_at(p_org, p_from) where code = '1402'), 0), 0);
  for w in 1 .. 13 loop
    v_ws := p_from + (w - 1) * 7; v_we := v_ws + 6;
    select coalesce(sum(total - amount_paid - credited), 0) into v_ar from sales where org_id = p_org and status in ('open', 'partially_paid') and journal_id is not null
      and doc_type = 'invoice' and (coalesce(due_date, issue_date) between v_ws and v_we or (w = 1 and coalesce(due_date, issue_date) < v_ws));
    select coalesce(sum(total - amount_paid), 0) into v_ap from bills where org_id = p_org and status in ('approved', 'partially_paid')
      and (due_date between v_ws and v_we or (w = 1 and due_date < v_ws));
    v_vat := case when exists (select 1 from generate_series(v_ws, v_we, interval '1 day') d where extract(day from d) = 21) then v_vat_due else 0 end;
    if v_vat > 0 then v_vat_due := 0; end if;
    v_close := v_cash + v_ar + v_in - v_ap - v_out - v_vat;
    v := v || jsonb_build_object('week', w, 'from', v_ws, 'to', v_we, 'opening', round(v_cash, 2), 'customers', round(v_ar, 2), 'other_receipts', round(v_in, 2),
      'bills', round(-v_ap, 2), 'other_payments', round(-v_out, 2), 'vat', round(-v_vat, 2), 'closing', round(v_close, 2), '_style', case when v_close < 0 then 'warning' else 'line' end);
    v_cash := v_close;
  end loop;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 6. The overview tiles (INS-01)
-- ---------------------------------------------------------------------------
create or replace function public.get_finance_overview(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_today date; v_cashacc text[]; v_cash numeric; v_burn numeric; v_in numeric; t jsonb; tl jsonb; v_fy date;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then return null; end if;
  v_today := private.local_day(p_org, now());
  v_fy := private.fy_start(p_org, v_today);
  select array_agg(code) into v_cashacc from private.acct_meta(p_org) where ifrs_line = 'Cash and cash equivalents';
  select coalesce(sum(bal), 0) into v_cash from private.balances_at(p_org, v_today) where code = any(v_cashacc);
  select coalesce(sum(l.credit - l.debit) filter (where l.credit > l.debit), 0), coalesce(sum(l.debit - l.credit) filter (where l.debit > l.credit), 0) into v_burn, v_in
  from journal_lines l join journals j on j.id = l.journal_id
  where l.org_id = p_org and l.account_code = any(v_cashacc) and j.entry_date between v_today - 29 and v_today
    and not exists (select 1 from journal_lines x where x.journal_id = j.id and x.account_code = any(v_cashacc) and x.id <> l.id);
  t := private.pl_totals(private.pl_map(p_org, date_trunc('month', v_today)::date, v_today));
  tl := private.pl_totals(private.pl_map(p_org, (date_trunc('month', v_today) - interval '1 month')::date, (date_trunc('month', v_today) - interval '1 day')::date));
  return jsonb_build_object(
    'cash', v_cash,
    'receivables', (select coalesce(sum(total - amount_paid - credited), 0) from sales where org_id = p_org and status in ('open', 'partially_paid') and journal_id is not null),
    'receivables_overdue', (select coalesce(sum(total - amount_paid - credited), 0) from sales where org_id = p_org and status in ('open', 'partially_paid') and journal_id is not null and due_date < v_today),
    'payables', (select coalesce(sum(total - amount_paid), 0) from bills where org_id = p_org and status in ('approved', 'partially_paid')),
    'bills_to_pay', (select count(*) from bills where org_id = p_org and status in ('approved', 'partially_paid')),
    'revenue_mtd', private.v(t, 'revenue'), 'gross_profit_mtd', private.v(t, 'gross_profit'), 'profit_mtd', private.v(t, 'profit'),
    'revenue_last_month', private.v(tl, 'revenue'), 'profit_last_month', private.v(tl, 'profit'),
    'revenue_ytd', private.v(private.pl_totals(private.pl_map(p_org, v_fy, v_today)), 'revenue'),
    'gross_burn_30d', v_burn, 'net_burn_30d', v_burn - v_in,
    'runway_months', case when v_burn - v_in > 0 and v_cash > 0 then round(v_cash / (v_burn - v_in), 1) when v_burn - v_in > 0 then 0 end,
    'vat_payable', -coalesce((select sum(bal) from private.balances_at(p_org, v_today) where code = '2201'), 0)
                   - coalesce((select sum(bal) from private.balances_at(p_org, v_today) where code = '1402'), 0),
    'suspense', coalesce((select sum(bal) from private.balances_at(p_org, v_today) where code like '9%'), 0),
    'inbox', (select count(*) from ai_proposals where org_id = p_org and status = 'pending'),
    'closed_through', private.closed_through(p_org));
end $$;

-- ---------------------------------------------------------------------------
-- 7. Closing a month: the checklist, accruals, expected credit losses; closing a year
-- ---------------------------------------------------------------------------
create table if not exists public.close_waivers (
  org_id uuid not null references public.orgs(id) on delete cascade,
  period_end date not null,
  step text not null,
  reason text not null,
  waived_by uuid references public.members(id) on delete set null,
  waived_at timestamptz not null default now(),
  primary key (org_id, period_end, step)
);
create index if not exists close_waivers_by_fk on public.close_waivers(waived_by);
alter table public.close_waivers enable row level security;
drop policy if exists close_waivers_read on public.close_waivers;
create policy close_waivers_read on public.close_waivers for select to authenticated using ((select private.can_handle_money(org_id)));

alter table public.bills add column if not exists accrual_journal_id uuid references public.journals(id) on delete set null;
create index if not exists bills_accrual_fk on public.bills(accrual_journal_id);

create or replace function public.close_checklist(p_org uuid, p_period_end date) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
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
end $$;

create or replace function public.waive_close_step(p_org uuid, p_period_end date, p_step text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if m.role <> 'owner' then raise exception 'Only the owner can waive a close step.' using errcode = '42501'; end if;
  if length(coalesce(trim(p_reason), '')) < 10 then raise exception 'Explain why this step is being waived.'; end if;
  insert into close_waivers (org_id, period_end, step, reason, waived_by) values (p_org, p_period_end, p_step, trim(p_reason), m.id)
  on conflict (org_id, period_end, step) do update set reason = excluded.reason, waived_by = excluded.waived_by, waived_at = now();
  return public.close_checklist(p_org, p_period_end);
end $$;

-- Draft bills dated in the month are accrued at the month end and reversed the next day (AP-01 cut-off).
create or replace function private.accrue_bills(p_org uuid, p_period_end date, m public.members) returns int
language plpgsql security definer set search_path = public, private as $$
declare b record; j public.journals; v_jl jsonb; n int := 0; v_tz text;
begin
  select timezone into v_tz from orgs where id = p_org;
  for b in select * from bills where org_id = p_org and status = 'draft' and bill_date <= p_period_end and accrual_journal_id is null and total > 0 loop
    select jsonb_agg(jsonb_build_object('code', bl.account_code, 'debit', bl.net + case when bl.vat_recoverable then 0 else bl.vat end, 'memo', bl.description)) into v_jl
    from bill_lines bl where bl.bill_id = b.id;
    v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'accrued_expenses'), 'credit',
      (select sum(bl.net + case when bl.vat_recoverable then 0 else bl.vat end) from bill_lines bl where bl.bill_id = b.id), 'memo', 'Accrued: ' || b.number));
    j := private.post_entry(p_org, 'Accrual for draft bill ' || b.number, 'accrual', b.id, m.id, m.id, v_jl,
      ((p_period_end + 1)::timestamp at time zone coalesce(v_tz, 'Africa/Lagos')) - interval '1 second');
    perform private.reverse_entry(j.id, m.id, 'Accrual reversed on the first day of the next month', (p_period_end + 1)::timestamp at time zone coalesce(v_tz, 'Africa/Lagos'));
    update bills set accrual_journal_id = j.id where id = b.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- Expected credit losses on receivables by a provision matrix (IFRS 9 simplified approach).
-- p_rates: {current, d1_30, d31_60, d61_90, d90_plus} as fractions; defaults 1%, 3%, 10%, 25%, 50%.
create or replace function public.run_ecl(p_org uuid, p_as_of date, p_rates jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_need numeric := 0; v_have numeric; v_change numeric; j public.journals; r record; v_detail jsonb := '[]'::jsonb; v_tz text;
  v_rate jsonb := jsonb_build_object('current', 0.01, 'd1_30', 0.03, 'd31_60', 0.10, 'd61_90', 0.25, 'd90_plus', 0.50) || coalesce(p_rates, '{}'::jsonb);
begin
  m := private.require(p_org, 'keep_books');
  perform private.require_open_day(p_org, p_as_of);
  select timezone into v_tz from orgs where id = p_org;
  for r in select bucket, sum(bal) bal from (
      select s.total - s.amount_paid - s.credited bal, case when p_as_of - coalesce(s.due_date, s.issue_date) <= 0 then 'current'
        when p_as_of - coalesce(s.due_date, s.issue_date) <= 30 then 'd1_30' when p_as_of - coalesce(s.due_date, s.issue_date) <= 60 then 'd31_60'
        when p_as_of - coalesce(s.due_date, s.issue_date) <= 90 then 'd61_90' else 'd90_plus' end bucket
      from sales s join customers c on c.id = s.customer_id
      where s.org_id = p_org and s.status in ('open', 'partially_paid') and s.journal_id is not null and s.issue_date <= p_as_of and not c.is_walk_in) x group by bucket loop
    v_need := v_need + round(r.bal * (v_rate->>r.bucket)::numeric, 2);
    v_detail := v_detail || jsonb_build_object('bucket', r.bucket, 'balance', r.bal, 'rate', (v_rate->>r.bucket)::numeric, 'allowance', round(r.bal * (v_rate->>r.bucket)::numeric, 2));
  end loop;
  select -coalesce(sum(bal), 0) into v_have from private.balances_at(p_org, p_as_of) where code = private.acct(p_org, 'ecl_allowance');
  v_change := round(v_need - v_have, 2);
  if v_change <> 0 then
    j := private.post_entry(p_org, 'Expected credit losses at ' || to_char(p_as_of, 'DD Mon YYYY'), 'ecl', null, m.id, m.id,
      private.reclass_pair(private.acct(p_org, 'ecl_expense'), private.acct(p_org, 'ecl_allowance'), v_change, null, null),
      ((p_as_of + 1)::timestamp at time zone coalesce(v_tz, 'Africa/Lagos')) - interval '2 seconds',
      jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'provision_matrix', 'rates', v_rate, 'buckets', v_detail))));
  end if;
  return jsonb_build_object('allowance', v_need, 'before', v_have, 'change', v_change, 'journal_ref', j.ref, 'buckets', v_detail);
end $$;

-- Close the books for a month: the checklist must pass (or blocking steps be waived), draft bills are accrued, depreciation is run,
-- then stock is closed and the month locked.
create or replace function public.close_books(p_org uuid, p_period_end date, p_policy jsonb default '{}'::jsonb, p_overrides jsonb default '[]'::jsonb,
  p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_check jsonb; v_accrued int; v_dep jsonb; v_res jsonb;
begin
  m := private.require(p_org, null);
  if m.role <> 'owner' then raise exception 'Only the owner closes the books.' using errcode = '42501'; end if;
  if p_period_end <> (date_trunc('month', p_period_end) + interval '1 month' - interval '1 day')::date and coalesce((p_policy->>'allow_mid_month')::boolean, false) is false then
    raise exception 'The books close at a month end.';
  end if;
  v_check := public.close_checklist(p_org, p_period_end);
  if not (v_check->>'ready')::boolean then
    raise exception 'Not ready to close: %.', (select string_agg(s->>'title', '; ') from jsonb_array_elements(v_check->'steps') s
      where (s->>'blocking')::boolean and not (s->>'ok')::boolean and not (s->>'waived')::boolean);
  end if;
  v_accrued := private.accrue_bills(p_org, p_period_end, m);
  if exists (select 1 from fixed_assets where org_id = p_org and status = 'active') then v_dep := private.depreciate(p_org, p_period_end, m); end if;
  v_res := public.close_period(p_org, p_period_end, p_policy, p_overrides, p_note);
  return v_res || jsonb_build_object('accrued_bills', v_accrued, 'depreciation', v_dep, 'checklist', v_check);
end $$;

-- Year end: income and expenses for the year move to retained earnings (3005). Only after every month of the year is closed.
create or replace function public.close_year(p_org uuid, p_year_end date) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_jl jsonb; j public.journals; v_profit numeric; v_tz text;
begin
  m := private.require(p_org, null);
  if m.role <> 'owner' then raise exception 'Only the owner closes the year.' using errcode = '42501'; end if;
  if p_year_end <> (private.fy_start(p_org, p_year_end) + interval '1 year' - interval '1 day')::date then raise exception 'That is not the last day of a financial year.'; end if;
  if coalesce(private.closed_through(p_org), '1900-01-01') < p_year_end then raise exception 'Close every month of the year first.'; end if;
  if exists (select 1 from journals where org_id = p_org and source_type = 'year_end' and entry_date = p_year_end) then raise exception 'This year is already closed.'; end if;
  select timezone into v_tz from orgs where id = p_org;
  select jsonb_agg(jsonb_build_object('code', b.code, 'debit', greatest(-b.bal, 0), 'credit', greatest(b.bal, 0), 'memo', 'Closed to retained earnings')), coalesce(-sum(b.bal), 0)
  into v_jl, v_profit
  from private.balances_at(p_org, p_year_end) b join private.acct_meta(p_org) a on a.code = b.code where a.statement = 'pl' and b.bal <> 0;
  if v_jl is null then raise exception 'There is nothing to close.'; end if;
  v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'retained_earnings'), 'debit', greatest(-v_profit, 0), 'credit', greatest(v_profit, 0),
    'memo', 'Profit for the year'));
  perform set_config('app.period_close', 'on', true);
  j := private.post_entry(p_org, 'Year end ' || to_char(p_year_end, 'YYYY') || ' · profit to retained earnings', 'year_end', null, m.id, m.id, v_jl,
    ((p_year_end + 1)::timestamp at time zone coalesce(v_tz, 'Africa/Lagos')) - interval '1 second');
  perform set_config('app.period_close', '', true);
  return jsonb_build_object('journal_ref', j.ref, 'profit', v_profit);
end $$;

grant execute on function public.accounting_report(uuid, text, date, date, jsonb), public.save_budget(uuid, jsonb), public.get_finance_overview(uuid),
  public.close_checklist(uuid, date), public.waive_close_step(uuid, date, text, text), public.run_ecl(uuid, date, jsonb),
  public.close_books(uuid, date, jsonb, jsonb, text), public.close_year(uuid, date) to authenticated;
revoke execute on function public.accounting_report(uuid, text, date, date, jsonb), public.save_budget(uuid, jsonb), public.get_finance_overview(uuid),
  public.close_checklist(uuid, date), public.waive_close_step(uuid, date, text, text), public.run_ecl(uuid, date, jsonb),
  public.close_books(uuid, date, jsonb, jsonb, text), public.close_year(uuid, date) from public, anon;
revoke execute on function private.fy_start(uuid, date), private.balances_at(uuid, date), private.movement(uuid, date, date), private.acct_meta(uuid),
  private.sofp_map(uuid, date), private.pl_map(uuid, date, date), private.cash_flow_parts(uuid, date, date), private.cash_flow_rows(uuid, date, date, date, date),
  private.soce_rows(uuid, date, date), private.note_rows(uuid, date, date, date, date, date), private.vat_rows(uuid, date, date),
  private.sales_analysis(uuid, date, date, text, boolean), private.cash_forecast(uuid, date), private.accrue_bills(uuid, date, public.members)
  from public, anon, authenticated;
