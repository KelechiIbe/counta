-- Counta: reports and the inventory payload learn about jobs, production, closes and imported sales history.

create or replace function public.inventory_report(
  p_org uuid, p_report text, p_from date default null, p_to date default null,
  p_location uuid default null, p_item uuid default null, p_accounts text[] default null
) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_cost boolean; v_tz text; v_today date; v_from date; v_to date; v_f timestamptz; v_t timestamptz;
  v_rows jsonb; v_extra jsonb := '{}'::jsonb; v_cap int := 50000; v_inv_re text; v_git text; v_accts text[];
begin
  m := private.require(p_org, null);
  v_cost := private.perm_of(m, 'see_margins') or private.perm_of(m, 'edit_prices');
  select timezone into v_tz from orgs where id = p_org;
  v_today := (now() at time zone v_tz)::date;
  v_to := least(coalesce(p_to, v_today), v_today + 1);
  v_from := coalesce(p_from, date_trunc('month', v_to)::date);
  if v_from > v_to then raise exception 'The start date is after the end date.'; end if;
  v_f := v_from::timestamp at time zone v_tz;
  v_t := (v_to + 1)::timestamp at time zone v_tz;
  select allowed into v_inv_re from posting_roles where role = 'inventory';
  v_git := private.acct(p_org, 'goods_in_transit');

  if p_report in ('valuation', 'movement_summary', 'gl', 'journals', 'trial_balance', 'purchases', 'purchase_lines', 'input_vat',
                  'vendors', 'cash_vs_stock', 'purchase_orders') and not v_cost then
    raise exception 'This report shows costs, which your role does not see.' using errcode = '42501';
  end if;

  if p_report = 'valuation' then
    with mv as (
      select item_id, location_id, sum(qty) q, sum(value) v from movements
      where org_id = p_org and recorded_at < v_t group by 1, 2),
    landed as (
      select (a->>'item_id')::uuid item_id, sum((a->>'allocated')::numeric) amt
      from landed_costs lc cross join lateral jsonb_array_elements(lc.allocation) a
      where lc.org_id = p_org and lc.created_at < v_t and coalesce((a->>'absorbed')::boolean, false) group by 1),
    book as (
      select mv.item_id, sum(mv.q) q, sum(mv.v) + coalesce(max(l.amt), 0) bv
      from mv left join landed l on l.item_id = mv.item_id group by mv.item_id),
    rows as (
      select i.name, i.sku, i.category, i.item_type, i.brand, i.selling_unit, i.purchase_unit, i.pack_size, i.price,
        coalesce(i.inventory_account, private.acct(p_org, 'inventory')) acct, l.name loc, mv.q,
        case when b.q <> 0 then b.bv / b.q end uc
      from mv join book b on b.item_id = mv.item_id join items i on i.id = mv.item_id join locations l on l.id = mv.location_id
      where mv.q <> 0 and (p_location is null or mv.location_id = p_location) and (p_item is null or mv.item_id = p_item))
    select jsonb_agg(jsonb_build_object(
        'item', name, 'sku', sku, 'category', category, 'item_type', item_type, 'brand', brand, 'account', acct, 'location', loc,
        'qty', q, 'unit', selling_unit, 'cartons', case when pack_size > 1 then round(q / pack_size, 2) end, 'purchase_unit', purchase_unit,
        'unit_cost', round(uc, 4), 'value', round(q * coalesce(uc, 0), 2), 'price', price, 'retail_value', round(q * price, 2),
        'margin_pct', case when price > 0 and uc is not null then round((price - uc) / price * 100, 1) end)
      order by name, loc)
    into v_rows from rows;
    if p_item is null then
      select coalesce(v_rows, '[]'::jsonb) || coalesce(jsonb_agg(jsonb_build_object(
          'item', 'Work in progress · ' || x.ref || ' ' || x.name, 'category', 'Production', 'item_type', 'work_in_progress',
          'account', x.acct, 'location', x.loc, 'value', x.v) order by x.ref), '[]'::jsonb)
      into v_rows
      from (
        select jb.ref, jb.name, l.name loc, private.acct(p_org, 'wip') acct,
          (select coalesce(sum(jl.debit - jl.credit), 0) from journals j join journal_lines jl on jl.journal_id = j.id
           where j.source_type = 'production' and j.source_id = jb.id and jl.account_code = private.acct(p_org, 'wip') and j.entry_date <= v_to) v
        from jobs jb join locations l on l.id = jb.location_id
        where jb.org_id = p_org and jb.kind = 'production' and (p_location is null or jb.location_id = p_location)) x
      where x.v <> 0;
    end if;
    select jsonb_build_object(
      'as_at', v_to,
      'allowance', case when p_location is null and p_item is null then private.role_balance(p_org, 'nrv_allowance', v_to, true) end,
      'closed_through', private.closed_through(p_org),
      'gl_inventory', coalesce(sum(jl.debit - jl.credit) filter (where jl.account_code ~ v_inv_re), 0),
      'gl_in_transit', coalesce(sum(jl.debit - jl.credit) filter (where jl.account_code = v_git), 0))
    into v_extra
    from journal_lines jl join journals j on j.id = jl.journal_id
    where jl.org_id = p_org and j.entry_date <= v_to and (p_location is null or jl.location_id = p_location);

  elsif p_report = 'movement_summary' then
    with lc as (
      select (a->>'item_id')::uuid item_id, lc.created_at at, (a->>'allocated')::numeric amt
      from landed_costs lc cross join lateral jsonb_array_elements(lc.allocation) a
      where lc.org_id = p_org and coalesce((a->>'absorbed')::boolean, false)),
    bf as (select item_id, sum(qty) q, sum(value) v from movements where org_id = p_org and recorded_at < v_f group by 1),
    bt as (select item_id, sum(qty) q, sum(value) v from movements where org_id = p_org and recorded_at < v_t group by 1),
    uf as (select bf.item_id, case when bf.q <> 0 then (bf.v + coalesce((select sum(amt) from lc where lc.item_id = bf.item_id and lc.at < v_f), 0)) / bf.q end uc from bf),
    ut as (select bt.item_id, case when bt.q <> 0 then (bt.v + coalesce((select sum(amt) from lc where lc.item_id = bt.item_id and lc.at < v_t), 0)) / bt.q end uc from bt),
    sf as (select item_id, sum(qty) q from movements where org_id = p_org and recorded_at < v_f and (p_location is null or location_id = p_location) group by 1),
    st as (select item_id, sum(qty) q from movements where org_id = p_org and recorded_at < v_t and (p_location is null or location_id = p_location) group by 1),
    fl as (
      select item_id,
        coalesce(sum(qty) filter (where type = 'opening'), 0) open_q, coalesce(sum(value) filter (where type = 'opening'), 0) open_v,
        coalesce(sum(qty) filter (where type = 'receipt'), 0) rec_q, coalesce(sum(value) filter (where type = 'receipt'), 0) rec_v,
        coalesce(sum(-qty) filter (where type in ('sale', 'voice_sale')), 0) sold_q, coalesce(sum(-value) filter (where type in ('sale', 'voice_sale')), 0) cogs,
        coalesce(sum(-qty * coalesce(unit_price, 0)) filter (where type in ('sale', 'voice_sale')), 0) revenue,
        coalesce(sum(qty) filter (where type = 'transfer_in'), 0) tin_q, coalesce(sum(value) filter (where type = 'transfer_in'), 0) tin_v,
        coalesce(sum(-qty) filter (where type = 'transfer_out'), 0) tout_q, coalesce(sum(-value) filter (where type = 'transfer_out'), 0) tout_v,
        coalesce(sum(qty) filter (where type in ('adjustment', 'write_off', 'quarantine')), 0) adj_q,
        coalesce(sum(value) filter (where type in ('adjustment', 'write_off', 'quarantine')), 0) adj_v,
        coalesce(sum(-qty) filter (where type in ('issue', 'issue_return')), 0) iss_q, coalesce(sum(-value) filter (where type in ('issue', 'issue_return')), 0) iss_v,
        coalesce(sum(qty) filter (where type = 'production_in'), 0) prod_q, coalesce(sum(value) filter (where type = 'production_in'), 0) prod_v
      from movements where org_id = p_org and recorded_at >= v_f and recorded_at < v_t and (p_location is null or location_id = p_location)
      group by 1),
    r as (
      select i.id, i.name, i.sku, i.category, i.item_type, i.selling_unit,
        coalesce(sf.q, 0) oq, round(coalesce(sf.q, 0) * coalesce(uf.uc, 0), 2) ov,
        coalesce(st.q, 0) cq, round(coalesce(st.q, 0) * coalesce(ut.uc, 0), 2) cv,
        coalesce(fl.open_q, 0) open_q, coalesce(fl.open_v, 0) open_v, coalesce(fl.rec_q, 0) rec_q, coalesce(fl.rec_v, 0) rec_v,
        coalesce(fl.sold_q, 0) sold_q, coalesce(fl.cogs, 0) cogs, coalesce(fl.revenue, 0) revenue,
        coalesce(fl.tin_q, 0) tin_q, coalesce(fl.tin_v, 0) tin_v, coalesce(fl.tout_q, 0) tout_q, coalesce(fl.tout_v, 0) tout_v,
        coalesce(fl.adj_q, 0) adj_q, coalesce(fl.adj_v, 0) adj_v, coalesce(fl.iss_q, 0) iss_q, coalesce(fl.iss_v, 0) iss_v,
        coalesce(fl.prod_q, 0) prod_q, coalesce(fl.prod_v, 0) prod_v
      from items i left join sf on sf.item_id = i.id left join st on st.item_id = i.id left join fl on fl.item_id = i.id
        left join uf on uf.item_id = i.id left join ut on ut.item_id = i.id
      where i.org_id = p_org and (p_item is null or i.id = p_item)
        and (coalesce(sf.q, 0) <> 0 or coalesce(st.q, 0) <> 0 or fl.item_id is not null))
    select jsonb_agg(jsonb_build_object(
        'item', name, 'sku', sku, 'category', category, 'item_type', item_type, 'unit', selling_unit,
        'opening_qty', oq, 'opening_value', ov, 'added_qty', open_q, 'added_value', open_v,
        'received_qty', rec_q, 'received_value', rec_v, 'sold_qty', sold_q, 'cogs', cogs, 'revenue', revenue,
        'transfer_in_qty', tin_q, 'transfer_in_value', tin_v, 'transfer_out_qty', tout_q, 'transfer_out_value', tout_v,
        'adjust_qty', adj_q, 'adjust_value', adj_v, 'issued_qty', iss_q, 'issued_value', iss_v, 'produced_qty', prod_q, 'produced_value', prod_v,
        'cost_adjust', round(cv - (ov + open_v + rec_v - cogs + tin_v - tout_v + adj_v - iss_v + prod_v), 2),
        'closing_qty', cq, 'closing_value', cv)
      order by name)
    into v_rows from r;

  elsif p_report = 'stock_card' then
    with base as (
      select mv.*, sum(mv.qty) over (partition by mv.item_id, mv.location_id order by mv.recorded_at, mv.created_at, mv.id
                                     rows between unbounded preceding and current row) bal
      from movements mv
      where mv.org_id = p_org and (p_item is null or mv.item_id = p_item) and (p_location is null or mv.location_id = p_location)
        and mv.recorded_at < v_t),
    opening as (
      select item_id, location_id, sum(qty) q from base where recorded_at < v_f group by 1, 2),
    lines as (
      select i.name as item, i.sku, l.name as loc, v_from as dt, null::text as ref, 'Balance brought forward' as kind, null::text as doc,
        null::numeric as qin, null::numeric as qout, o.q as bal, null::numeric as uc, null::numeric as vin, null::numeric as vout,
        null::text as who, null::text as chan, null::text as note, '0' as srt, null::timestamptz as ts
      from opening o join items i on i.id = o.item_id join locations l on l.id = o.location_id
      where o.q <> 0 or exists (select 1 from base b where b.item_id = o.item_id and b.location_id = o.location_id and b.recorded_at >= v_f)
      union all
      select i.name, i.sku, l.name, (b.recorded_at at time zone v_tz)::date, j.ref,
        case b.type when 'opening' then 'Opening stock' when 'receipt' then 'Receipt' when 'sale' then 'Sale' when 'voice_sale' then 'Sale (voice)'
          when 'transfer_out' then 'Transfer out' when 'transfer_in' then 'Transfer in' when 'adjustment' then 'Count adjustment'
          when 'write_off' then 'Write-off' when 'quarantine' then 'Quarantine' when 'issue' then 'Issued to job'
          when 'issue_return' then 'Returned from job' when 'production_in' then 'Produced' else b.type end,
        coalesce((select rc.ref from receipts rc where rc.id = b.receipt_id), (select t.ref from transfers t where t.id = b.transfer_id),
          (select cs.ref from count_sessions cs where cs.id = b.count_session_id), (select jb.ref from jobs jb where jb.id = b.job_id)),
        case when b.qty > 0 then b.qty end, case when b.qty < 0 then -b.qty end, b.bal,
        b.unit_cost, case when b.qty > 0 then b.value end, case when b.qty < 0 then -b.value end,
        (select mb.display_name from members mb where mb.id = b.author_id), b.channel, coalesce(b.reason, b.note), '1', b.recorded_at
      from base b join items i on i.id = b.item_id join locations l on l.id = b.location_id left join journals j on j.id = b.journal_id
      where b.recorded_at >= v_f)
    select jsonb_agg(jsonb_build_object('item', item, 'sku', sku, 'location', loc, 'date', dt, 'journal', ref, 'type', kind, 'document', doc,
        'qty_in', qin, 'qty_out', qout, 'balance', bal,
        'unit_cost', case when v_cost then round(uc, 4) end, 'value_in', case when v_cost then vin end, 'value_out', case when v_cost then vout end,
        'by', who, 'channel', chan, 'note', note) order by item, loc, srt, ts)
    into v_rows from (select * from lines order by item, loc, srt, ts limit v_cap) x;

  elsif p_report = 'gl' or p_report = 'trial_balance' then
    if p_accounts is null or cardinality(p_accounts) = 0 then
      if p_report = 'gl' then
        select array_agg(code order by code) into v_accts from accounts where code ~ v_inv_re or code = v_git;
      else
        select array_agg(distinct account_code) into v_accts from journal_lines where org_id = p_org;
      end if;
    elsif p_accounts = array['*'] then
      select array_agg(distinct account_code) into v_accts from journal_lines where org_id = p_org;
    else
      v_accts := p_accounts;
    end if;
    if p_report = 'gl' then
      with lines as (
        select jl.id, jl.account_code, jl.debit, jl.credit, jl.memo lmemo, jl.location_id, jl.item_id,
          j.entry_date, j.ref, j.je_no, j.memo, j.source_type
        from journal_lines jl join journals j on j.id = jl.journal_id
        where jl.org_id = p_org and jl.account_code = any(v_accts) and j.entry_date <= v_to
          and (p_location is null or jl.location_id = p_location)),
      ob as (select account_code, sum(debit - credit) b from lines where entry_date < v_from group by 1),
      per as (
        select l.*, coalesce(ob.b, 0) + sum(l.debit - l.credit) over (partition by l.account_code order by l.entry_date, l.je_no, l.id
                                                                       rows between unbounded preceding and current row) run
        from lines l left join ob on ob.account_code = l.account_code where l.entry_date >= v_from),
      allrows as (
        select a.code, a.name as aname, v_from as dt, null::text as ref, 'Opening balance' as memo, null::text as src, null::text as loc, null::text as item,
          null::numeric as dr, null::numeric as cr, coalesce(ob.b, 0) as bal, 0 as srt, 0 as je, 0::bigint as lid
        from accounts a left join ob on ob.account_code = a.code
        where a.code = any(v_accts) and (ob.b is not null or exists (select 1 from per where per.account_code = a.code))
        union all
        select p.account_code, a.name, p.entry_date, p.ref, coalesce(nullif(p.lmemo, ''), p.memo), p.source_type,
          (select name from locations where id = p.location_id), (select name from items where id = p.item_id),
          p.debit, p.credit, p.run, 1, p.je_no, p.id
        from per p join accounts a on a.code = p.account_code)
      select jsonb_agg(jsonb_build_object('account', code, 'account_name', aname, 'date', dt, 'journal', ref, 'memo', memo,
          'source', src, 'location', loc, 'item', item, 'debit', dr, 'credit', cr, 'balance', bal) order by code, srt, dt, je, lid)
      into v_rows from (select * from allrows order by code, srt, dt, je, lid limit v_cap) x;
    else
      with lines as (
        select jl.account_code, jl.debit, jl.credit, j.entry_date
        from journal_lines jl join journals j on j.id = jl.journal_id
        where jl.org_id = p_org and jl.account_code = any(v_accts) and j.entry_date <= v_to
          and (p_location is null or jl.location_id = p_location)),
      agg as (
        select account_code,
          coalesce(sum(debit - credit) filter (where entry_date < v_from), 0) ob,
          coalesce(sum(debit) filter (where entry_date >= v_from), 0) dr,
          coalesce(sum(credit) filter (where entry_date >= v_from), 0) cr
        from lines group by 1)
      select jsonb_agg(jsonb_build_object('account', a.code, 'account_name', a.name, 'kind', a.kind, 'normal_balance', a.normal_balance,
          'opening', g.ob, 'debit', g.dr, 'credit', g.cr, 'closing', g.ob + g.dr - g.cr,
          'closing_dr', case when g.ob + g.dr - g.cr > 0 then g.ob + g.dr - g.cr end,
          'closing_cr', case when g.ob + g.dr - g.cr < 0 then -(g.ob + g.dr - g.cr) end) order by a.code)
      into v_rows from agg g join accounts a on a.code = g.account_code
      where g.ob <> 0 or g.dr <> 0 or g.cr <> 0;
    end if;

  elsif p_report = 'journals' then
    select jsonb_agg(x order by (x->>'date'), (x->>'je_no')::int, (x->>'line')::bigint) into v_rows from (
      select jsonb_build_object('date', j.entry_date, 'journal', j.ref, 'je_no', j.je_no, 'memo', j.memo, 'source', j.source_type,
        'account', jl.account_code, 'account_name', a.name, 'debit', jl.debit, 'credit', jl.credit,
        'location', (select name from locations where id = jl.location_id), 'item', (select name from items where id = jl.item_id),
        'line_memo', jl.memo, 'posted_by', (select display_name from members where id = j.posted_by),
        'approved_by', (select display_name from members where id = j.approved_by), 'line', jl.id) x
      from journals j join journal_lines jl on jl.journal_id = j.id join accounts a on a.code = jl.account_code
      where j.org_id = p_org and j.entry_date between v_from and v_to and (p_location is null or jl.location_id = p_location)
      order by j.entry_date, j.je_no, jl.id
      limit v_cap) s;

  elsif p_report = 'purchases' then
    select jsonb_agg(x order by x->>'date', x->>'ref') into v_rows from (
      select jsonb_build_object('date', (r.posted_at at time zone v_tz)::date, 'invoice_date', r.invoice_date, 'ref', r.ref,
        'vendor', coalesce(v.name, r.vendor_name), 'invoice_no', r.invoice_no, 'location', l.name,
        'source', case r.source when 'pdf' then 'PDF invoice' when 'photo_typed' then 'Photo (typed)' when 'photo_handwritten' then 'Photo (handwritten)' else 'Manual' end,
        'lines', (select count(*) from receipt_lines rl where rl.receipt_id = r.id), 'net', r.net, 'vat', r.input_vat, 'gross', r.gross,
        'landed', (select coalesce(sum(total), 0) from landed_costs lc where lc.receipt_id = r.id), 'journal', j.ref,
        'posted_by', (select display_name from members where id = r.posted_by)) x
      from receipts r left join vendors v on v.id = r.vendor_id left join locations l on l.id = r.location_id left join journals j on j.id = r.journal_id
      where r.org_id = p_org and r.status = 'posted' and r.posted_at >= v_f and r.posted_at < v_t
        and (p_location is null or r.location_id = p_location)
      limit v_cap) s;

  elsif p_report = 'purchase_lines' then
    select jsonb_agg(x order by x->>'date', x->>'ref', (x->>'line')::int) into v_rows from (
      select jsonb_build_object('date', (r.posted_at at time zone v_tz)::date, 'ref', r.ref, 'vendor', coalesce(v.name, r.vendor_name),
        'invoice_no', r.invoice_no, 'location', l.name, 'line', rl.line_no, 'item', coalesce(i.name, rl.new_item->>'name', rl.raw_text),
        'sku', i.sku, 'qty', rl.qty,
        'unit', coalesce(rl.unit_label, case when rl.unit_kind = 'purchase' then i.purchase_unit else i.selling_unit end),
        'unit_cost', rl.unit_cost, 'line_total', round(rl.qty * rl.unit_cost, 2),
        'vat_treatment', coalesce(i.vat_treatment, rl.new_item->>'vat_treatment', 'standard'),
        'batch_no', rl.batch_no, 'expiry_date', rl.expiry_date) x
      from receipts r join receipt_lines rl on rl.receipt_id = r.id left join items i on i.id = rl.item_id
        left join vendors v on v.id = r.vendor_id left join locations l on l.id = r.location_id
      where r.org_id = p_org and r.status = 'posted' and r.posted_at >= v_f and r.posted_at < v_t
        and (p_location is null or r.location_id = p_location) and (p_item is null or rl.item_id = p_item)
      limit v_cap) s;

  elsif p_report = 'input_vat' then
    select jsonb_agg(x order by x->>'date', x->>'ref') into v_rows from (
      select jsonb_build_object('date', (r.posted_at at time zone v_tz)::date, 'invoice_date', r.invoice_date, 'ref', r.ref,
        'vendor', coalesce(v.name, r.vendor_name), 'invoice_no', r.invoice_no, 'location', l.name,
        'taxable', (select coalesce(sum(round(rl.qty * rl.unit_cost, 2)), 0) from receipt_lines rl left join items i on i.id = rl.item_id
                    where rl.receipt_id = r.id and coalesce(i.vat_treatment, rl.new_item->>'vat_treatment', 'standard') = 'standard'),
        'non_taxable', (select coalesce(sum(round(rl.qty * rl.unit_cost, 2)), 0) from receipt_lines rl left join items i on i.id = rl.item_id
                    where rl.receipt_id = r.id and coalesce(i.vat_treatment, rl.new_item->>'vat_treatment', 'standard') <> 'standard'),
        'vat', r.input_vat, 'gross', r.gross, 'journal', j.ref) x
      from receipts r left join vendors v on v.id = r.vendor_id left join locations l on l.id = r.location_id left join journals j on j.id = r.journal_id
      where r.org_id = p_org and r.status = 'posted' and r.input_vat > 0 and r.posted_at >= v_f and r.posted_at < v_t
        and (p_location is null or r.location_id = p_location)
      limit v_cap) s;

  elsif p_report = 'vendors' then
    select jsonb_agg(x order by (x->>'gross')::numeric desc) into v_rows from (
      select jsonb_build_object('vendor', v.name, 'vat_registered', v.vat_registered, 'receipts', count(r.id),
        'net', coalesce(sum(r.net), 0), 'vat', coalesce(sum(r.input_vat), 0), 'gross', coalesce(sum(r.gross), 0),
        'items', (select count(distinct rl.item_id) from receipt_lines rl join receipts r2 on r2.id = rl.receipt_id
                  where r2.vendor_id = v.id and r2.status = 'posted' and r2.posted_at >= v_f and r2.posted_at < v_t),
        'last_receipt', max((r.posted_at at time zone v_tz)::date), 'lead_time_days', v.lead_time_days, 'credit_days', v.credit_days,
        'phone', v.phone, 'email', v.email) x
      from vendors v join receipts r on r.vendor_id = v.id and r.status = 'posted' and r.posted_at >= v_f and r.posted_at < v_t
        and (p_location is null or r.location_id = p_location)
      where v.org_id = p_org
      group by v.id) s;

  elsif p_report = 'purchase_orders' then
    select jsonb_agg(x order by x->>'date', x->>'ref') into v_rows from (
      select jsonb_build_object('date', (po.created_at at time zone v_tz)::date, 'ref', po.ref, 'vendor', v.name, 'location', l.name,
        'status', initcap(po.status), 'sent_via', po.sent_via, 'sent', (po.sent_at at time zone v_tz)::date,
        'received', (po.received_at at time zone v_tz)::date,
        'lines', (select string_agg(trim(to_char(pl.qty, 'FM999,999,990.###')) || ' ' || i.purchase_unit || ' ' || i.name, '; ')
                  from po_lines pl join items i on i.id = pl.item_id where pl.po_id = po.id),
        'total', po.total, 'created_by', (select display_name from members where id = po.created_by)) x
      from purchase_orders po left join vendors v on v.id = po.vendor_id left join locations l on l.id = po.location_id
      where po.org_id = p_org and po.created_at >= v_f and po.created_at < v_t and (p_location is null or po.location_id = p_location)
      limit v_cap) s;

  elsif p_report = 'sales_by_item' then
    select jsonb_agg(x order by (x->>'revenue')::numeric desc) into v_rows from (
      select jsonb_build_object('item', i.name, 'sku', i.sku, 'category', i.category, 'unit', i.selling_unit,
        'sales', count(*), 'qty', sum(-mv.qty), 'revenue', round(sum(-mv.qty * coalesce(mv.unit_price, 0)), 2),
        'avg_price', round(sum(-mv.qty * coalesce(mv.unit_price, 0)) / nullif(sum(-mv.qty), 0), 2),
        'cogs', case when v_cost then round(sum(-mv.value), 2) end,
        'gross_profit', case when v_cost then round(sum(-mv.qty * coalesce(mv.unit_price, 0)) - sum(-mv.value), 2) end,
        'margin_pct', case when v_cost and sum(-mv.qty * coalesce(mv.unit_price, 0)) > 0 then
          round((sum(-mv.qty * coalesce(mv.unit_price, 0)) - sum(-mv.value)) / sum(-mv.qty * coalesce(mv.unit_price, 0)) * 100, 1) end) x
      from movements mv join items i on i.id = mv.item_id
      where mv.org_id = p_org and mv.type in ('sale', 'voice_sale') and mv.recorded_at >= v_f and mv.recorded_at < v_t
        and (p_location is null or mv.location_id = p_location) and (p_item is null or mv.item_id = p_item)
      group by i.id) s;

  elsif p_report = 'sales_by_day' then
    select jsonb_agg(x order by x->>'date', x->>'location') into v_rows from (
      select jsonb_build_object('date', (mv.recorded_at at time zone v_tz)::date, 'location', l.name, 'sales', count(*),
        'voice', count(*) filter (where mv.type = 'voice_sale'), 'qty', sum(-mv.qty),
        'revenue', round(sum(-mv.qty * coalesce(mv.unit_price, 0)), 2),
        'cogs', case when v_cost then round(sum(-mv.value), 2) end,
        'gross_profit', case when v_cost then round(sum(-mv.qty * coalesce(mv.unit_price, 0)) - sum(-mv.value), 2) end) x
      from movements mv join locations l on l.id = mv.location_id
      where mv.org_id = p_org and mv.type in ('sale', 'voice_sale') and mv.recorded_at >= v_f and mv.recorded_at < v_t
        and (p_location is null or mv.location_id = p_location) and (p_item is null or mv.item_id = p_item)
      group by (mv.recorded_at at time zone v_tz)::date, l.name) s;

  elsif p_report = 'sales_by_staff' then
    select jsonb_agg(x order by (x->>'revenue')::numeric desc) into v_rows from (
      select jsonb_build_object('person', coalesce(mb.display_name, 'Unknown'), 'role', initcap(mb.role), 'sales', count(*),
        'voice', count(*) filter (where mv.type = 'voice_sale'), 'offline', count(*) filter (where mv.offline),
        'revenue', round(sum(-mv.qty * coalesce(mv.unit_price, 0)), 2),
        'first', min((mv.recorded_at at time zone v_tz)::date), 'last', max((mv.recorded_at at time zone v_tz)::date)) x
      from movements mv left join members mb on mb.id = mv.author_id
      where mv.org_id = p_org and mv.type in ('sale', 'voice_sale') and mv.recorded_at >= v_f and mv.recorded_at < v_t
        and (p_location is null or mv.location_id = p_location) and (p_item is null or mv.item_id = p_item)
      group by mb.id, mb.display_name, mb.role) s;

  elsif p_report = 'adjustments' then
    select jsonb_agg(x order by x->>'date') into v_rows from (
      select jsonb_build_object('date', (mv.recorded_at at time zone v_tz)::date, 'journal', j.ref,
        'count', (select cs.ref from count_sessions cs where cs.id = mv.count_session_id), 'type', initcap(replace(mv.type, '_', ' ')),
        'item', i.name, 'sku', i.sku, 'location', l.name, 'qty', mv.qty, 'unit', i.selling_unit,
        'value', case when v_cost then mv.value end, 'reason', mv.reason, 'note', mv.note,
        'by', (select display_name from members where id = mv.author_id), 'approved_by', (select display_name from members where id = mv.approver_id)) x
      from movements mv join items i on i.id = mv.item_id join locations l on l.id = mv.location_id left join journals j on j.id = mv.journal_id
      where mv.org_id = p_org and mv.type in ('adjustment', 'write_off', 'quarantine') and mv.recorded_at >= v_f and mv.recorded_at < v_t
        and (p_location is null or mv.location_id = p_location) and (p_item is null or mv.item_id = p_item)
      order by mv.recorded_at
      limit v_cap) s;

  elsif p_report = 'transfers' then
    select jsonb_agg(x order by x->>'date', x->>'ref') into v_rows from (
      select jsonb_build_object('date', (t.created_at at time zone v_tz)::date, 'ref', t.ref, 'item', i.name, 'sku', i.sku,
        'qty', t.qty, 'unit', i.selling_unit, 'from', lf.name, 'to', lt.name,
        'status', case t.status when 'in_transit' then 'In transit' else 'Received' end,
        'received', (t.received_at at time zone v_tz)::date, 'value', case when v_cost then round(t.qty * t.unit_cost, 2) end,
        'sent_by', (select display_name from members where id = t.created_by), 'received_by', (select display_name from members where id = t.received_by)) x
      from transfers t join items i on i.id = t.item_id join locations lf on lf.id = t.from_location_id join locations lt on lt.id = t.to_location_id
      where t.org_id = p_org and t.created_at >= v_f and t.created_at < v_t
        and (p_location is null or t.from_location_id = p_location or t.to_location_id = p_location) and (p_item is null or t.item_id = p_item)
      limit v_cap) s;

  elsif p_report = 'price_changes' then
    select jsonb_agg(x order by x->>'date') into v_rows from (
      select jsonb_build_object('date', (pc.created_at at time zone v_tz)::date, 'item', i.name, 'sku', i.sku,
        'old_price', pc.old_price, 'new_price', pc.new_price,
        'change_pct', case when pc.old_price > 0 then round((pc.new_price - pc.old_price) / pc.old_price * 100, 1) end,
        'reason', pc.reason, 'by', (select display_name from members where id = pc.changed_by)) x
      from price_changes pc join items i on i.id = pc.item_id
      where pc.org_id = p_org and pc.created_at >= v_f and pc.created_at < v_t and (p_item is null or pc.item_id = p_item)
      order by pc.created_at
      limit v_cap) s;

  elsif p_report = 'cash_vs_stock' then
    with implied as (
      select (mv.recorded_at at time zone v_tz)::date d, mv.location_id, round(sum(-mv.qty * coalesce(mv.unit_price, 0)), 2) amt
      from movements mv
      where mv.org_id = p_org and mv.type in ('sale', 'voice_sale') and mv.recorded_at >= v_f and mv.recorded_at < v_t
      group by 1, 2),
    days as (
      select d, location_id from implied
      union select ct.day, ct.location_id from cash_takings ct where ct.org_id = p_org and ct.day between v_from and v_to)
    select jsonb_agg(jsonb_build_object('date', ds.d, 'location', l.name, 'implied', coalesce(im.amt, 0),
        'cash', ct.cash, 'pos', ct.pos, 'transfers', ct.transfers,
        'recorded', case when ct.id is not null then ct.cash + ct.pos + ct.transfers end,
        'gap', case when ct.id is not null then coalesce(im.amt, 0) - (ct.cash + ct.pos + ct.transfers) end) order by ds.d, l.name)
    into v_rows
    from days ds join locations l on l.id = ds.location_id
      left join implied im on im.d = ds.d and im.location_id = ds.location_id
      left join cash_takings ct on ct.org_id = p_org and ct.day = ds.d and ct.location_id = ds.location_id
    where p_location is null or ds.location_id = p_location;

  elsif p_report = 'batches' then
    select jsonb_agg(x order by x->>'expiry_date' nulls last) into v_rows from (
      select jsonb_build_object('item', i.name, 'sku', i.sku, 'nafdac_no', i.nafdac_no, 'batch_no', b.batch_no, 'location', l.name,
        'expiry_date', b.expiry_date, 'days_left', b.expiry_date - v_today, 'qty_received', b.qty_received, 'qty_remaining', b.qty_remaining,
        'unit', i.selling_unit, 'value', case when v_cost then round(b.qty_remaining * coalesce(c.wac, 0), 2) end,
        'status', case when b.quarantined then 'Quarantined' when b.expiry_date is null then 'No expiry'
          when b.expiry_date < v_today then 'Expired' when b.expiry_date - v_today <= 30 then 'Expiring'
          when b.expiry_date - v_today <= 90 then 'Watch' else 'OK' end) x
      from batches b join items i on i.id = b.item_id join locations l on l.id = b.location_id left join item_costs c on c.item_id = b.item_id
      where b.org_id = p_org and (b.qty_remaining > 0 or b.quarantined)
        and (p_location is null or b.location_id = p_location) and (p_item is null or b.item_id = p_item)
      limit v_cap) s;

  elsif p_report = 'jobs' then
    with jb as (
      select * from jobs where org_id = p_org and (p_location is null or location_id = p_location)
        and created_at < v_t and (status = 'open' or closed_at >= v_f)),
    mat as (
      select mv.job_id, coalesce(sum(-mv.value) filter (where mv.type = 'issue'), 0) issued,
        coalesce(sum(mv.value) filter (where mv.type = 'issue_return'), 0) returned, count(distinct mv.item_id) n_items
      from movements mv where mv.job_id in (select id from jb) and mv.type in ('issue', 'issue_return') and mv.recorded_at < v_t group by 1),
    oth as (
      select j.source_id job_id, sum(jl.debit) v from journals j join journal_lines jl on jl.journal_id = j.id
      where j.org_id = p_org and j.source_type = 'production' and jl.account_code = private.acct(p_org, 'wip') and jl.item_id is null
        and j.entry_date <= v_to group by 1)
    select jsonb_agg(jsonb_build_object('ref', jb.ref, 'kind', case when jb.kind = 'production' then 'Production run' else 'Job' end,
        'name', jb.name, 'location', l.name, 'status', initcap(jb.status), 'opened', (jb.created_at at time zone v_tz)::date,
        'closed', (jb.closed_at at time zone v_tz)::date, 'customer', jb.customer,
        'account', case when jb.kind = 'production' then private.acct(p_org, 'wip') else jb.charge_account end,
        'makes', i.name, 'planned_qty', jb.planned_qty, 'produced_qty', jb.produced_qty, 'items', coalesce(mat.n_items, 0),
        'materials', case when v_cost then coalesce(mat.issued, 0) end, 'returned', case when v_cost then coalesce(mat.returned, 0) end,
        'other_costs', case when v_cost then coalesce(oth.v, 0) end,
        'total_cost', case when v_cost then coalesce(mat.issued, 0) - coalesce(mat.returned, 0) + coalesce(oth.v, 0) end,
        'unit_cost', case when v_cost then jb.output_unit_cost end) order by jb.created_at)
    into v_rows
    from jb join locations l on l.id = jb.location_id left join items i on i.id = jb.output_item_id
      left join mat on mat.job_id = jb.id left join oth on oth.job_id = jb.id;

  elsif p_report = 'issues' then
    select jsonb_agg(jsonb_build_object('date', (mv.recorded_at at time zone v_tz)::date, 'job', jb.ref, 'job_name', jb.name,
        'kind', case when jb.kind = 'production' then 'Production run' else 'Job' end,
        'type', case when mv.type = 'issue' then 'Issued' else 'Returned' end, 'item', i.name, 'sku', i.sku, 'location', l.name,
        'qty', -mv.qty, 'unit', i.selling_unit, 'unit_cost', case when v_cost then mv.unit_cost end,
        'value', case when v_cost then -mv.value end,
        'account', case when jb.kind = 'production' then private.acct(p_org, 'wip') else jb.charge_account end,
        'journal', j.ref, 'by', mb.display_name, 'note', mv.note) order by mv.recorded_at, i.name)
    into v_rows
    from (select * from movements where org_id = p_org and type in ('issue', 'issue_return') and recorded_at >= v_f and recorded_at < v_t
            and (p_location is null or location_id = p_location) and (p_item is null or item_id = p_item)
          order by recorded_at limit v_cap) mv
      join jobs jb on jb.id = mv.job_id join items i on i.id = mv.item_id join locations l on l.id = mv.location_id
      left join journals j on j.id = mv.journal_id left join members mb on mb.id = mv.author_id;

  else
    raise exception 'Unknown report %.', p_report;
  end if;

  return jsonb_build_object('rows', coalesce(v_rows, '[]'::jsonb), 'extra', v_extra, 'from', v_from, 'to', v_to,
    'truncated', jsonb_array_length(coalesce(v_rows, '[]'::jsonb)) >= v_cap, 'can_see_costs', v_cost);
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
    'org', (select to_jsonb(o) from orgs o where o.id = p_org),
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
        'perms', jsonb_build_object('record_sales', private.perm_of(mb, 'record_sales'), 'receive_stock', private.perm_of(mb, 'receive_stock'),
          'count_stock', private.perm_of(mb, 'count_stock'), 'approve_adjustments', private.perm_of(mb, 'approve_adjustments'),
          'edit_prices', private.perm_of(mb, 'edit_prices'), 'approve_pos', private.perm_of(mb, 'approve_pos'),
          'transfer_stock', private.perm_of(mb, 'transfer_stock'), 'see_margins', private.perm_of(mb, 'see_margins'),
          'issue_stock', private.perm_of(mb, 'issue_stock'))
      ) order by (mb.role = 'owner') desc, mb.created_at), '[]'::jsonb) from members mb where mb.org_id = p_org and mb.status <> 'disabled'),
    'items', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', i.id, 'name', i.name, 'photo_path', i.photo_path, 'barcode', i.barcode, 'sku', i.sku, 'qr_code', i.qr_code,
        'category', i.category, 'vat_treatment', i.vat_treatment, 'nafdac_no', i.nafdac_no, 'purchase_unit', i.purchase_unit,
        'pack_size', i.pack_size, 'selling_unit', i.selling_unit, 'informal_unit', i.informal_unit, 'track_batches', i.track_batches,
        'reorder_floor', i.reorder_floor, 'preferred_vendor_id', i.preferred_vendor_id, 'alt_vendor_id', i.alt_vendor_id,
        'price', i.price, 'import_priced', i.import_priced, 'notes', i.notes, 'needs_review', i.needs_review, 'created_at', i.created_at,
        'item_type', i.item_type, 'brand', i.brand, 'description', i.description, 'attributes', i.attributes,
        'inventory_account', i.inventory_account,
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

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
      and p.proname in ('save_job', 'issue_materials', 'complete_production', 'close_job', 'save_recipe', 'get_jobs',
        'period_close_preview', 'close_period', 'reopen_period', 'get_period_closes', 'get_period_close_lines',
        'import_inventory', 'import_vendors', 'import_sales_history', 'undo_import', 'get_imports',
        'leak_radar', 'run_spot_checks', 'set_spot_checks', 'inventory_report', 'get_inventory', 'update_member')
  loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private' and p.prokind = 'f'
      and p.proname in ('member_defaults', 'update_wac', 'job_wip', 'job_noun', 'closed_through', 'guard_closed_journal',
        'guard_closed_movement', 'period_lines', 'role_balance', 'overlap_days', 'yes', 'item_risk', 'plan_spot_checks', 'cron_spot_checks')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;
