-- TaxStreem's answers on the six VAT return points (sign-off page, 20 October 2026).
-- N-1, N-2, N-4 and N-6 stand as Counta already works. Two change:
--   N-3: exempt goods the Act names that the NRS template's list does not (baby products, s.186(1)(d); assistive devices and
--        disability-related products, s.186(1)(o)) get the Act's words as their description, and Counta applies the
--        description an item's words point to without asking. A notice says when the file carries one the list lacks.
--   N-5: schedule F takes the invoice's own value before VAT; where an agent kept a different amount from 7.5% of it, a check
--        says so before filing.

-- Descriptions in the Act's words, off the template's list (tried before the others: their words are specific).
alter table public.nrs_vat_labels add column if not exists on_template boolean not null default true;
insert into public.nrs_vat_labels (label, treatment, sort, keywords, on_template) values
  ('Assistive devices and disability-related products including hearing aids, wheelchairs, and braille materials', 'exempt', -1,
   'assistive|disabilit|disabled|wheel ?chairs?|hearing aids?|braille|crutch|walking (aids?|frames?|sticks?)|rollators?|zimmer|white canes?|prosthe|orthos[ie]s|orthotic|mobility (aids?|scooters?)|screen readers?',
   false),
  ('Baby products', 'exempt', 0,
   'bab(y|ies)|infants?\M|toddlers?|newborns?|diapers?|napp(y|ies)|pampers|huggies|feeding bottles?|teethers?|pacifiers?|soothers?|prams?\M|strollers?|cribs?\M|bibs?\M|sippy|breast pumps?|nursing pads?',
   false)
on conflict (label) do update set treatment = excluded.treatment, sort = excluded.sort, keywords = excluded.keywords, on_template = excluded.on_template;

-- Exempt items with no description yet take the one their words now point to (the item trigger works it out).
update public.items set nrs_vat_label = nrs_vat_label where vat_treatment = 'exempt' and nrs_vat_label is null and not nrs_vat_label_manual;

-- The NRS VAT return for a month. Changed: schedule A guesses the description for products as well as typed lines (N-3),
-- with a notice for descriptions off the template's list; schedule F takes the invoice's value (N-5).
create or replace function private.vat_schedule(p_org uuid, p_period date) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_f date := date_trunc('month', p_period)::date; v_t date := (date_trunc('month', p_period) + interval '1 month' - interval '1 day')::date;
  v_vr numeric := private.vat_rate((date_trunc('month', p_period) + interval '1 month' - interval '1 day')::date);
  o public.orgs; mn public.locations; a jsonb; b jsonb; c2 jsonb; c2v jsonb; c1 jsonb; d jsonb; e jsonb; f jsonb; checks jsonb := '[]'::jsonb;
  mo jsonb; vp public.vat_periods; v_zs numeric; v_std numeric; v_zero numeric; l jsonb; v_tol numeric; v_lines int; v_net numeric; v_place_state text;
  v_e_place text; v_today date := private.local_day(p_org, now()); rw record; v_wgap numeric;
begin
  select * into o from orgs where id = p_org;
  select * into mn from locations where org_id = p_org order by is_main desc, created_at limit 1;
  mo := private.vat_month(p_org, v_f);
  select * into vp from vat_periods where org_id = p_org and period = v_f;
  v_std := (mo->>'standard_sales')::numeric; v_zero := (mo->>'zero_rated_sales')::numeric;
  v_zs := case when v_std + v_zero > 0 then round(greatest(v_zero, 0) / (v_std + v_zero), 6) else 0 end;

  -- ---- A: every sale line (standard credit notes go to B), by customer, product, VAT status, description and place ----
  create temp table if not exists vat_a_lines (line_id uuid, item_id uuid, description text, treatment text, label text, cust_key text, cname text, ctin text,
    product text, cat int, st text, lga text, place_from text, branch_id uuid, branch_name text, customer_id uuid, c_state text, c_lga text, amount numeric) on commit drop;
  truncate vat_a_lines;
  insert into vat_a_lines
  select l.id, coalesce(l.item_id, ol.item_id), coalesce(ol.description, l.description), l.vat_treatment,
    case when l.vat_treatment = 'standard' then null
      when l.vat_treatment = 'zero' and s.export then case when coalesce(ol.kind, l.kind) = 'service' or i.item_type = 'service' then 'Exported services' else 'Exported goods excluding oil and gas' end
      -- The description chosen for the line or the product, else the one its words point to (TaxStreem sign-off N-3: Counta
      -- applies it without asking).
      else coalesce(l.nrs_vat_label, ol.nrs_vat_label, i.nrs_vat_label,
        private.nrs_label_guess(l.vat_treatment, concat_ws(' ', i.name, i.category, coalesce(ol.description, l.description)))) end,
    case when w.walk_in then 'walkin:' || coalesce(s.location_id, mn.id)::text else 'c:' || coalesce(s.customer_id::text, lower(coalesce(s.customer_name, ''))) end,
    case when w.walk_in then 'Walk-in customers' else coalesce(c.name, s.customer_name, 'Customer') end,
    case when w.walk_in then null else private.vat_tin(coalesce(c.tin, s.customer_tin)) end,
    left(case when coalesce(ol.kind, l.kind) = 'delivery' then 'Delivery' else coalesce(i.name, nullif(trim(coalesce(ol.description, l.description)), ''), 'Sale') end, 120),
    case l.vat_treatment when 'exempt' then 1 when 'zero' then 2 else 0 end,
    case when pc.by_customer then cs.st else br.state end,
    case when pc.by_customer then private.ng_lga(cs.st, c.lga) else br.lga end,
    case when pc.by_customer then 'customer' else 'branch' end,
    br.id, br.name, c.id, c.state, c.lga,
    case when s.doc_type = 'credit_note' then -l.net else l.net end
  -- A credit note's line names the line it credits, so it nets against that product.
  from sales s join sale_lines l on l.sale_id = s.id left join sale_lines ol on ol.id = l.original_line_id
    left join customers c on c.id = s.customer_id left join items i on i.id = coalesce(l.item_id, ol.item_id)
    left join locations br on br.id = coalesce(s.location_id, mn.id)
    cross join lateral (select coalesce(c.is_walk_in, s.customer_id is null and s.channel in ('till', 'voice')) walk_in) w
    -- The customer's state as chosen, else as its address names it.
    cross join lateral (select case when c.id is not null and coalesce(upper(c.country), 'NG') = 'NG'
      then coalesce(private.ng_state(c.state), private.ng_state_of_address(c.address)) end st) cs
    cross join lateral (select not w.walk_in and not coalesce(s.export, false) and cs.st is not null by_customer) pc
  where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import' and s.issue_date between v_f and v_t
    and not (s.doc_type = 'credit_note' and l.vat_treatment = 'standard') and l.net <> 0;

  select coalesce(jsonb_agg(jsonb_build_object('customer', cname, 'tin', ctin, 'product', product, 'category', cat, 'label', label, 'state', st, 'lga', lga,
      'amount', amount, 'place_from', place_from) order by cat, cname, product), '[]'::jsonb)
  into a
  from (select cust_key, cname, ctin, product, cat, label, st, lga, place_from, round(sum(amount), 2) amount from vat_a_lines
        group by cust_key, cname, ctin, product, cat, label, st, lga, place_from having round(sum(amount), 2) <> 0) g;

  -- ---- B: credit notes on standard-rated lines, one row each ----
  select coalesce(jsonb_agg(jsonb_build_object('description', descr, 'tin', ctin, 'customer', cname, 'date', issue_date, 'invoice', inv_no,
      'invoice_amount', inv_amount, 'adjusted', adjusted) order by issue_date, number), '[]'::jsonb)
  into b
  from (select s.number, s.issue_date,
          left('Credit note ' || s.number || coalesce(' against ' || orig.number, '') || coalesce(': ' || nullif(trim(s.notes), ''), ''), 200) descr,
          case when coalesce(c.is_walk_in, false) then null else private.vat_tin(coalesce(c.tin, s.customer_tin)) end ctin,
          case when coalesce(c.is_walk_in, false) then 'Walk-in customers' else coalesce(c.name, s.customer_name, 'Customer') end cname,
          coalesce(orig.number, s.number) inv_no,
          round(coalesce((select sum(ol.net) from sale_lines ol where ol.sale_id = orig.id), sum(l.net)), 2) inv_amount,
          round(sum(l.net), 2) adjusted
        from sales s join sale_lines l on l.sale_id = s.id left join customers c on c.id = s.customer_id left join sales orig on orig.id = s.original_sale_id
        where s.org_id = p_org and s.doc_type = 'credit_note' and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import'
          and s.issue_date between v_f and v_t and l.vat_treatment = 'standard' and l.net <> 0
        group by s.id, s.number, s.issue_date, s.notes, s.customer_tin, s.customer_name, c.is_walk_in, c.tin, c.name, orig.id, orig.number) x;

  -- ---- C_2: standard-rated purchases whose VAT is claimed, by bill (and stock receipt), as goods, services or fixed assets ----
  select coalesce(jsonb_object_agg(kind, rows), '{}'::jsonb) into c2
  from (select kind, jsonb_agg(jsonb_build_object('seller', seller, 'tin', tin, 'description', descr, 'amount', amount, 'ref', ref) order by pday, ref) rows
        from (select private.vat_purchase_kind(bl.account_code, coalesce(bl.wht_category, x.wht_category)) kind, x.bill_date as pday, x.number as ref,
                v.name seller, private.vat_tin(v.tin) tin,
                left(x.number || coalesce(' (their ' || nullif(x.vendor_ref, '') || ')', '') || ': ' || string_agg(distinct coalesce(nullif(trim(bl.description), ''), 'Purchase'), ', '), 200) descr,
                round(sum(bl.net), 2) amount
              from bills x join bill_lines bl on bl.bill_id = x.id join vendors v on v.id = x.vendor_id
              where x.org_id = p_org and x.source not in ('receipt', 'import') and x.journal_id is not null and x.status <> 'void' and x.bill_date between v_f and v_t
                and bl.vat_recoverable and bl.vat > 0
              group by 1, x.id, x.bill_date, x.number, x.vendor_ref, v.name, v.tin
              union all
              select 'goods', private.local_day(r.org_id, coalesce(r.posted_at, r.created_at)), r.ref, coalesce(v.name, r.vendor_name, 'Supplier'), private.vat_tin(v.tin),
                left('Stock received ' || r.ref || coalesce(' (their ' || nullif(r.invoice_no, '') || ')', ''), 200), round(r.input_vat / v_vr, 2)
              from receipts r left join vendors v on v.id = r.vendor_id
              where r.org_id = p_org and r.status = 'posted' and r.input_vat > 0 and private.local_day(r.org_id, coalesce(r.posted_at, r.created_at)) between v_f and v_t) y
        group by kind) z;
  -- Suppliers' credit notes reduce the purchases (the reconciliation column of schedule C).
  select jsonb_build_object('goods', coalesce(sum(n) filter (where kind = 'goods'), 0), 'services', coalesce(sum(n) filter (where kind = 'services'), 0),
      'fixed_assets', coalesce(sum(n) filter (where kind = 'fixed_assets'), 0))
  into c2v
  from (select private.vat_purchase_kind(cl.account_code, ob.wht_category) kind, -round(cl.net, 2) n
        from vendor_credits vc join vendor_credit_lines cl on cl.credit_id = vc.id left join bill_lines ob on ob.id = cl.bill_line_id
        where vc.org_id = p_org and vc.status <> 'void' and vc.journal_id is not null and vc.credit_date between v_f and v_t and cl.vat > 0) q;

  -- ---- C1: standard-rated stock written off (its VAT is taken back), grouped by why ----
  select coalesce(jsonb_agg(jsonb_build_object('description', descr, 'amount', amount, 'zero', round(amount * v_zs, 2)) order by descr), '[]'::jsonb) into c1
  from (select case reason when 'Breakage' then 'Damaged or broken stock written off' when 'Expired' then 'Expired stock written off'
            when 'Theft suspected' then 'Stock lost to theft' when 'Written off' then 'Stock written off' else 'Other stock losses written off' end descr,
          round(sum(cost), 2) amount
        from private.vat_stock_writeoffs(p_org, v_f, v_t) group by 1) w;

  -- ---- D: imports, from the customs entries ----
  select coalesce(jsonb_agg(jsonb_build_object('number', number, 'importer', importer, 'description', left(description || coalesce(' (HS ' || hs_code || ')', ''), 250),
      'vessel', vessel, 'country', country, 'form_m', form_m, 'bill_of_lading', bill_of_lading, 'quantity', quantity, 'currency', currency, 'invoice_value', invoice_value,
      'fx_rate', fx_rate, 'value_ngn', value_ngn, 'other_charges', other_charges, 'total_cost', vat_base, 'import_vat', import_vat) order by entry_date, number), '[]'::jsonb)
  into d
  from customs_entries where org_id = p_org and status = 'posted' and entry_date between v_f and v_t;

  -- ---- E: VAT self-charged on services (and goods) from suppliers abroad, whose VAT is claimed back ----
  v_place_state := coalesce(mn.state, private.ng_state_of_address(coalesce(o.registered_office, o.address)));
  select coalesce(jsonb_agg(jsonb_build_object('name', name, 'tin', tin, 'status', 'Self Charge', 'description', descr,
      'category', case kind when 'goods' then 'VATable Local Goods Purchased (Relating to VATable purchases)'
        when 'fixed_assets' then 'VATable Fixed Assets Purchased Locally (Relating to VATable purchases)'
        else 'VATable Local Services Received (Relating to VATable purchases)' end,
      'place', case when st = 'FCT' then 'Federal Capital Territory' else st end, 'amount', amount) order by name, descr), '[]'::jsonb)
  into e
  from (select v.name, private.vat_tin(v.tin) tin, private.vat_purchase_kind(bl.account_code, coalesce(bl.wht_category, x.wht_category)) kind,
          coalesce(lb.state, v_place_state) st,
          left(x.number || ': ' || string_agg(distinct coalesce(nullif(trim(bl.description), ''), 'Service'), ', '), 200) descr, round(sum(bl.net), 2) amount
        from bills x join bill_lines bl on bl.bill_id = x.id join vendors v on v.id = x.vendor_id left join locations lb on lb.id = bl.location_id
        where x.org_id = p_org and x.source not in ('receipt', 'import') and x.journal_id is not null and x.status <> 'void' and x.bill_date between v_f and v_t
          and bl.vat_recoverable and bl.reverse_charge_vat > 0
        group by v.name, v.tin, 3, 4, x.id, x.number) r;

  -- ---- F: VAT kept by withholding agents (MDAs, banks, oil and gas companies) on what we sold them ----
  select coalesce(jsonb_agg(jsonb_build_object('agent', agent, 'address', address, 'tin', tin, 'nature', nature, 'date', day, 'invoice', invoice,
      'currency', 'NGN', 'invoice_value', value, 'fx_rate', 1, 'value_ngn', value, 'vat', vat) order by day, invoice), '[]'::jsonb)
  into f
  from (select coalesce(cu.name, s.customer_name, 'Customer') agent, left(concat_ws(', ', nullif(trim(cu.address), ''), nullif(trim(cu.city), ''), nullif(trim(cu.state), '')), 250) address,
          private.vat_tin(coalesce(cu.tin, s.customer_tin)) tin,
          case when bool_and(sl.kind = 'service') then 'Supply of services' when bool_or(sl.kind = 'service') then 'Supply of goods and services' else 'Supply of goods' end nature,
          private.local_day(co.org_id, co.received_at) as day, coalesce(s.number, co.number) as invoice,
          -- The invoice's own value before VAT (its VATable lines, less credit notes on them), shared across the agent's payments
          -- on it by the VAT each kept (TaxStreem sign-off N-5). The template credits 7.5% of it; where that differs from what the
          -- agent kept, a check says so. A payment with no invoice keeps the value its VAT implies.
          coalesce(round(iv.vatable * co.amount / nullif(iv.kept, 0), 2), round(co.amount / v_vr, 2)) value, co.amount vat
        from collections co left join sales s on s.id = co.sale_id left join customers cu on cu.id = co.customer_id left join sale_lines sl on sl.sale_id = s.id
          left join lateral (select nullif(greatest((select coalesce(sum(x.net), 0) from sale_lines x where x.sale_id = s.id and x.vat > 0)
              - (select coalesce(sum(x.net), 0) from sales cn join sale_lines x on x.sale_id = cn.id
                 where cn.original_sale_id = s.id and cn.doc_type = 'credit_note' and cn.status <> 'void' and cn.journal_id is not null and x.vat > 0), 0), 0) vatable,
            (select sum(k.amount) from collections k where k.sale_id = s.id and k.method = 'wvat_credit' and k.status = 'confirmed' and k.journal_id is not null) kept) iv on s.id is not null
        where co.org_id = p_org and co.method = 'wvat_credit' and co.status = 'confirmed' and co.journal_id is not null
          and private.local_day(co.org_id, co.received_at) between v_f and v_t
        group by co.id, co.org_id, co.received_at, co.number, co.amount, cu.name, cu.address, cu.city, cu.state, cu.tin, s.customer_name, s.customer_tin, s.number,
          iv.vatable, iv.kept) w;

  -- ---- The form's lines, as the template's formulas work them out ----
  l := jsonb_build_object(
    '10', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(a) r),
    '15', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(a) r where (r->>'category')::int = 1),
    '20', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(a) r where (r->>'category')::int = 2),
    '22', (select coalesce(sum((r->>'adjusted')::numeric), 0) from jsonb_array_elements(b) r),
    '40', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_each(c2) k, jsonb_array_elements(k.value) r)
      + coalesce((c2v->>'goods')::numeric, 0) + coalesce((c2v->>'services')::numeric, 0) + coalesce((c2v->>'fixed_assets')::numeric, 0),
    '45', -(select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(c1) r),
    '85', (select coalesce(sum((r->>'total_cost')::numeric), 0) from jsonb_array_elements(d) r),
    '105_base', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(e) r),
    '110', (select coalesce(sum(round(v_vr * (r->>'value_ngn')::numeric, 10)), 0) from jsonb_array_elements(f) r));
  l := l || jsonb_build_object('25', (l->>'10')::numeric - (l->>'15')::numeric - (l->>'20')::numeric - (l->>'22')::numeric);
  l := l || jsonb_build_object('35', round((l->>'25')::numeric * v_vr, 2), '55', round(((l->>'40')::numeric + (l->>'45')::numeric) * v_vr, 2),
    '90', round((l->>'85')::numeric * v_vr, 2), '105', round((l->>'105_base')::numeric * v_vr, 2));
  l := l || jsonb_build_object('95', (l->>'55')::numeric + (l->>'90')::numeric);
  l := l || jsonb_build_object('100', (l->>'35')::numeric - (l->>'95')::numeric);
  l := l || jsonb_build_object('115', round((l->>'100')::numeric - ((l->>'105')::numeric + (l->>'110')::numeric), 2));

  -- ---- What to fix, and how the return ties to Counta's VAT for the month ----
  v_net := (mo->>'output')::numeric - (mo->>'wvat_credit')::numeric - (mo->>'input')::numeric;
  -- What line 110 credits beyond the VAT agents kept (their own check explains it, so the tie leaves it out).
  v_wgap := (select coalesce(round(sum(v_vr * (r->>'value_ngn')::numeric - (r->>'vat')::numeric), 2), 0) from jsonb_array_elements(f) r);
  select count(*) into v_lines from vat_a_lines;
  v_tol := greatest(1, round(0.01 * (v_lines + jsonb_array_length(b) + jsonb_array_length(e) + jsonb_array_length(f)
    + (select count(*) from jsonb_each(c2) k, jsonb_array_elements(k.value) r)), 2));
  if v_t >= v_today then
    checks := checks || jsonb_build_object('severity', 'info', 'code', 'month_open', 'text', 'The month has not ended, so these figures can still change.');
  end if;
  if vp.period is not null and (abs((mo->>'output')::numeric - vp.output_vat) >= 0.01 or abs((mo->>'input')::numeric - vp.input_vat) >= 0.01
     or abs((mo->>'wvat_credit')::numeric - vp.wvat_credit) >= 0.01) then
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'changed_since_filing',
      'text', 'Documents for this month changed after the return was filed. The file shows the books as they are now; reopen the return to file the change.');
  end if;
  -- Places.
  for rw in select branch_id, branch_name, bool_or(st is null) no_state, bool_or(st is not null and lga is null) no_lga, count(*) n
           from vat_a_lines where place_from = 'branch' group by branch_id, branch_name having bool_or(st is null) or bool_or(lga is null) loop
    checks := checks || jsonb_build_object('severity', 'warn', 'code', case when rw.no_state then 'branch_state' else 'branch_lga' end,
      'text', case when rw.branch_id is null then 'The business has no branch with a state. Add the state and local government area of the main branch.'
        else 'Add the ' || case when rw.no_state then 'state and local government area' else 'local government area' end || ' of ' || rw.branch_name
          || ': its sales (and those of customers whose state is not known) are placed there.' end,
      'fix', jsonb_build_object('kind', 'branch', 'id', rw.branch_id, 'name', rw.branch_name));
  end loop;
  for rw in select customer_id, max(cname) cname, max(st) st from vat_a_lines where place_from = 'customer' and lga is null and customer_id is not null group by customer_id
           order by 2 limit 50 loop
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'customer_lga', 'text', 'Add the local government area of ' || rw.cname || ' (' || rw.st || ').',
      'fix', jsonb_build_object('kind', 'customer', 'id', rw.customer_id, 'name', rw.cname, 'state', rw.st));
  end loop;
  for rw in select customer_id, max(cname) cname, max(c_state) c_state from vat_a_lines
           where place_from = 'branch' and customer_id is not null and nullif(trim(c_state), '') is not null and private.ng_state(c_state) is null
             and not cust_key like 'walkin:%'
             and exists (select 1 from customers cc where cc.id = customer_id and coalesce(upper(cc.country), 'NG') = 'NG')
           group by customer_id order by 2 limit 20 loop
    checks := checks || jsonb_build_object('severity', 'info', 'code', 'customer_state', 'text', rw.cname || '''s state "' || rw.c_state
      || '" is not a Nigerian state Counta knows, so the branch''s state is used. Choose it from the list if the customer is in Nigeria.',
      'fix', jsonb_build_object('kind', 'customer', 'id', rw.customer_id, 'name', rw.cname));
  end loop;
  -- Descriptions of exempt and zero-rated supplies.
  for rw in select item_id, coalesce(max(i.name), max(vl.description)) name, max(vl.treatment) treatment, min(vl.line_id::text)::uuid line_id, sum(vl.amount) amount
           from vat_a_lines vl left join items i on i.id = vl.item_id where vl.cat in (1, 2) and vl.label is null
           group by vl.item_id, case when vl.item_id is null then vl.line_id end order by 2 limit 50 loop
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'label',
      'text', 'Choose the NRS description for ' || rw.name || ' (' || case rw.treatment when 'zero' then 'zero-rated' else 'exempt' end || ', '
        || private.naira(rw.amount) || '). The template takes only its own list.',
      'fix', case when rw.item_id is not null then jsonb_build_object('kind', 'item', 'id', rw.item_id, 'name', rw.name, 'treatment', rw.treatment)
        else jsonb_build_object('kind', 'line', 'id', rw.line_id, 'name', rw.name, 'treatment', rw.treatment) end);
  end loop;
  -- Descriptions in the Act's words that the template's list does not carry yet.
  for rw in select vl.label, count(distinct vl.product) n, (array_agg(distinct vl.product order by vl.product))[1:5] names
           from vat_a_lines vl join nrs_vat_labels nl on nl.label = vl.label and not nl.on_template group by vl.label order by 1 loop
    checks := checks || jsonb_build_object('severity', 'info', 'code', 'label_off_list',
      'text', 'Schedule A describes ' || array_to_string(rw.names, ', ') || case when rw.n > 5 then ' and ' || (rw.n - 5) || ' more' else '' end
        || ' as "' || rw.label || '", the Act''s words. The NRS template''s list does not have them yet; '
        || 'if the portal refuses the file, choose the nearest description on the list for them.');
  end loop;
  -- An agent that kept a different amount from 7.5% of the invoice value: line 110 credits 7.5% of it.
  for rw in select r->>'agent' agent, r->>'invoice' invoice, (r->>'vat')::numeric kept, round(v_vr * (r->>'value_ngn')::numeric, 2) credited
           from jsonb_array_elements(f) r where abs((r->>'vat')::numeric - round(v_vr * (r->>'value_ngn')::numeric, 2)) >= 1 order by 2 limit 50 loop
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'wvat_partial',
      'text', 'On ' || rw.invoice || ', ' || rw.agent || ' kept ' || private.naira(rw.kept) || ' of VAT, but the template credits 7.5% of the invoice value, '
        || private.naira(rw.credited) || '. Check what the agent withheld before you file.');
  end loop;
  if exists (select 1 from jsonb_array_elements(a) r where (r->>'amount')::numeric < 0) then
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'negative_row',
      'text', 'Credit notes on exempt or zero-rated sales are more than the sales they net against for some rows. Those rows go in as negative amounts, which the portal may refuse.');
  end if;
  -- What the template holds.
  if jsonb_array_length(a) > 9973 then
    checks := checks || jsonb_build_object('severity', 'block', 'code', 'too_many_a', 'text', 'Schedule A holds 9,973 rows and this month has ' || jsonb_array_length(a) || '.');
  end if;
  if jsonb_array_length(e) > 37 then
    checks := checks || jsonb_build_object('severity', 'block', 'code', 'too_many_e', 'text', 'Schedule E holds 37 rows and this month has ' || jsonb_array_length(e) || ' bills with VAT self-charged.');
  end if;
  if jsonb_array_length(f) > 2299 then
    checks := checks || jsonb_build_object('severity', 'block', 'code', 'too_many_f', 'text', 'Schedule F holds 2,299 rows and this month has ' || jsonb_array_length(f) || '.');
  end if;
  if exists (select 1 from customs_entries where org_id = p_org and status = 'posted' and entry_date between v_f and v_t and abs(import_vat - round(vat_base * v_vr, 2)) >= 1) then
    checks := checks || jsonb_build_object('severity', 'info', 'code', 'import_vat', 'text', 'The template takes import VAT as 7.5% of the total cost of each import; '
      || 'some customs entries paid a different amount, so line 90 differs from what was paid.');
  end if;
  if abs((l->>'115')::numeric + v_wgap - v_net) > v_tol then
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'tie',
      'text', 'The return comes to ' || private.naira((l->>'115')::numeric) || ' (line 115) and Counta''s VAT for the month to ' || private.naira(v_net)
        || '. The template works VAT out on totals, Counta line by line; a gap of more than ' || private.naira(v_tol) || ' needs a look.');
  end if;

  return jsonb_build_object('period', v_f, 'to', v_t,
    'org', jsonb_build_object('name', o.name, 'tin', o.tin, 'tax_id', private.vat_tin(o.tin), 'state', v_place_state),
    'file_name', to_char(v_f, 'YYYY') || '_' || coalesce(private.vat_tin(o.tin), regexp_replace(coalesce(o.tin, 'NO-TAX-ID'), '[^0-9A-Za-z-]', '', 'g')) || '_VAT_'
      || extract(month from v_f)::int || '.xlsx',
    'a', a, 'b', b, 'c2', jsonb_build_object('goods', coalesce(c2->'goods', '[]'::jsonb), 'services', coalesce(c2->'services', '[]'::jsonb),
      'fixed_assets', coalesce(c2->'fixed_assets', '[]'::jsonb)), 'c_variance', c2v, 'zero_share', v_zs,
    'c1', c1, 'd', d, 'e', e, 'f', f, 'lines', l,
    'counta', mo || jsonb_build_object('net', v_net, 'filed', vp.period is not null, 'status', coalesce(vp.status, 'open')),
    'tolerance', v_tol, 'difference', round((l->>'115')::numeric - v_net, 2), 'wvat_gap', v_wgap,
    'checks', checks, 'blocked', exists (select 1 from jsonb_array_elements(checks) c where c->>'severity' = 'block'));
end $$;
