-- Numens decides the VAT on the lines a person types on an invoice, and on new products received as stock.
--
-- A service business describes its work on each invoice line, and those lines had a VAT select that started at standard,
-- so the person decided the VAT. Now Numens (TaxStreem's tax model, Gemini until it is connected) reads the words of
-- each typed line and decides, under the Nigeria Tax Act 2025. Its answer, and its reason, go on the line. Below the
-- business's confidence threshold the answer is still used, and the invoice asks a person to confirm or change those lines
-- before it is issued. A person may change any line: their choice is recorded as theirs, by name, and Numens never
-- undoes it. Answers and choices are kept per business for the words of the line (line_vat), so the same service gets
-- the same VAT next time without asking Numens again.
--
-- Only lines the app marks (vat_by 'numens' or 'person') go through this. Bank receipts, sales schedules and the till
-- keep deciding their own lines, as before.
--
-- Recurring invoices are issued with no one there, so a schedule with a line Numens is not sure of is confirmed when
-- it is saved. A new product received as stock is decided by Numens' regular sweep, unless the person receiving it
-- chose its VAT and is allowed to set VAT.

-- ---------------------------------------------------------------------------
-- What Numens, or a person, decided for the words of a typed line
-- ---------------------------------------------------------------------------
create table public.line_vat (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  key text not null check (key <> ''),
  description text not null,
  treatment text not null check (treatment in ('standard', 'zero', 'exempt')),
  source text not null check (source in ('numens', 'gemini', 'person')),
  confidence numeric check (confidence between 0 and 1),
  reason text,
  law text,
  nrs_label text,
  model text,
  ai jsonb,
  by_name text,
  decided_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, key)
);
alter table public.line_vat enable row level security;
revoke all on public.line_vat from anon, authenticated;
select private.activity_attach('public.line_vat');

alter table public.sale_lines add column if not exists vat_basis jsonb;

-- The words of a line as they are matched: lower case, spaces collapsed.
create or replace function private.line_vat_key(p text) returns text
language sql immutable set search_path = public, private as $$
  select left(lower(regexp_replace(trim(coalesce(p, '')), '\s+', ' ', 'g')), 300)
$$;
revoke all on function private.line_vat_key(text) from public, anon, authenticated;

-- The confidence at which Numens' answer stands without a person: the business's auto-post threshold, never below 0.8.
create or replace function private.vat_sure_at(p_org uuid) returns numeric
language sql stable security definer set search_path = public, private as $$
  select greatest(coalesce((select auto_post_threshold from orgs where id = p_org), 0.8), 0.8)
$$;
revoke all on function private.vat_sure_at(uuid) from public, anon, authenticated;

-- What a line carries as the basis of its VAT.
create or replace function private.line_vat_json(lv public.line_vat) returns jsonb
language sql stable set search_path = public, private as $$
  select jsonb_strip_nulls(jsonb_build_object('source', lv.source, 'treatment', lv.treatment, 'confidence', lv.confidence, 'reason', lv.reason,
    'law', lv.law, 'nrs_label', lv.nrs_label, 'model', lv.model, 'by', lv.by_name, 'at', lv.updated_at, 'ai', lv.ai))
$$;
revoke all on function private.line_vat_json(public.line_vat) from public, anon, authenticated;

-- The decision on record for the words of a line. p_by 'person' records the person's choice of p_treatment first (the
-- answer Numens gave is kept beside it); 'numens' only reads. Nothing on record returns an empty row.
create or replace function private.line_vat_decide(p_org uuid, p_description text, p_by text, p_treatment text, p_member public.members)
returns public.line_vat
language plpgsql security definer set search_path = public, private as $$
declare lv public.line_vat; v_key text := private.line_vat_key(p_description);
begin
  if v_key = '' then return lv; end if;
  if p_by = 'person' and p_treatment in ('standard', 'zero', 'exempt') then
    insert into line_vat as t (org_id, key, description, treatment, source, by_name, decided_by)
    values (p_org, v_key, left(regexp_replace(trim(p_description), '\s+', ' ', 'g'), 300), p_treatment, 'person', p_member.display_name, p_member.id)
    on conflict (org_id, key) do update set treatment = excluded.treatment, source = 'person', by_name = excluded.by_name, decided_by = excluded.decided_by,
      ai = case when t.source <> 'person' then jsonb_strip_nulls(jsonb_build_object('source', t.source, 'treatment', t.treatment, 'confidence', t.confidence,
             'reason', t.reason, 'law', t.law, 'nrs_label', t.nrs_label, 'model', t.model, 'at', t.updated_at)) else t.ai end,
      nrs_label = case when t.treatment = excluded.treatment then t.nrs_label when t.ai->>'treatment' = excluded.treatment then t.ai->>'nrs_label' end,
      confidence = null, reason = null, law = null, model = null, updated_at = now()
    where t.source <> 'person' or t.treatment <> excluded.treatment;
  end if;
  select * into lv from line_vat where org_id = p_org and key = v_key;
  return lv;
end $$;
revoke all on function private.line_vat_decide(uuid, text, text, text, public.members) from public, anon, authenticated;

-- The decisions on record for some lines' words, in the order given.
create or replace function private.line_vat_rows(p_org uuid, p_lines jsonb) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('description', d.v) || case when lv.id is not null then private.line_vat_json(lv) else '{}'::jsonb end
    order by d.n), '[]'::jsonb)
  from jsonb_array_elements_text(p_lines) with ordinality d(v, n)
  left join line_vat lv on lv.org_id = p_org and lv.key = private.line_vat_key(d.v)
$$;
revoke all on function private.line_vat_rows(uuid, jsonb) from public, anon, authenticated;

-- For the app (through the AI function): what is on record for up to 50 lines, and the confidence Numens needs.
create or replace function public.line_vat_lookup(p_org uuid, p_lines jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.require(p_org, 'record_sales');
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then raise exception 'Send the lines as a list.'; end if;
  if jsonb_array_length(p_lines) > 50 then raise exception 'Up to 50 lines at a time.'; end if;
  return jsonb_build_object('threshold', private.vat_sure_at(p_org), 'lines', private.line_vat_rows(p_org, p_lines));
end $$;
revoke all on function public.line_vat_lookup(uuid, jsonb) from public, anon;
grant execute on function public.line_vat_lookup(uuid, jsonb) to authenticated, service_role;

-- For the AI function: Numens' answers for lines with nothing on record. A person's decision is never replaced.
create or replace function public.svc_line_vat_store(p_org uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare x jsonb; v_key text; v_t text; v_names jsonb := '[]'::jsonb;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then return '[]'::jsonb; end if;
  for x in select * from jsonb_array_elements(p_rows) limit 50 loop
    v_key := private.line_vat_key(x->>'description');
    v_t := x->>'treatment';
    continue when v_key = '' or v_t is null or v_t not in ('standard', 'zero', 'exempt');
    insert into line_vat as t (org_id, key, description, treatment, source, confidence, reason, law, nrs_label, model)
    values (p_org, v_key, left(regexp_replace(trim(x->>'description'), '\s+', ' ', 'g'), 300), v_t,
      case when x->>'source' = 'numens' then 'numens' else 'gemini' end,
      least(greatest(coalesce(private.num(x->>'confidence'), 0), 0), 1), left(x->>'reason', 400), left(x->>'law', 120),
      (select label from nrs_vat_labels where label = x->>'nrs_label' and treatment = v_t), left(x->>'model', 80))
    on conflict (org_id, key) do update set treatment = excluded.treatment, source = excluded.source, confidence = excluded.confidence,
      reason = excluded.reason, law = excluded.law, nrs_label = excluded.nrs_label, model = excluded.model, updated_at = now()
    where t.source <> 'person';
    v_names := v_names || jsonb_build_array(x->>'description');
  end loop;
  return private.line_vat_rows(p_org, v_names);
end $$;
revoke all on function public.svc_line_vat_store(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.svc_line_vat_store(uuid, jsonb) to service_role;

-- A recurring schedule's lines with Numens: each takes the decision on record, and one Numens is not sure of, or has
-- not answered, waits for a person (the invoices are issued with no one there to ask).
create or replace function private.recurring_vat(p_org uuid, p_lines jsonb, m public.members) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare x jsonb; lv public.line_vat; v_out jsonb := '[]'::jsonb; v_on boolean := coalesce((select vat_registered from orgs where id = p_org), false);
begin
  for x in select * from jsonb_array_elements(p_lines) loop
    if x ? 'vat_by' then
      lv := private.line_vat_decide(p_org, x->>'description', x->>'vat_by', x->>'vat_treatment', m);
      -- A business that does not charge VAT is not asked: its lines carry none whatever they are.
      if lv.id is null and v_on then
        raise exception 'Numens has not checked the VAT on "%" yet. Wait a moment, or choose it yourself.', x->>'description';
      end if;
      if v_on and lv.source <> 'person' and coalesce(lv.confidence, 0) < private.vat_sure_at(p_org) then
        raise exception 'Check the VAT on "%" first: Numens is not sure of it, and each invoice is issued without asking. Keep its answer or change it.',
          x->>'description';
      end if;
      x := x - 'vat_by';
      if lv.id is not null then x := x || jsonb_build_object('vat_treatment', lv.treatment, 'vat_basis', private.line_vat_json(lv)); end if;
    end if;
    v_out := v_out || jsonb_build_array(x);
  end loop;
  return v_out;
end $$;
revoke all on function private.recurring_vat(uuid, jsonb, public.members) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Changed functions
-- ---------------------------------------------------------------------------
-- Lines typed on a sale: Numens decides their VAT unless a person has.
create or replace function private.write_lines(s public.sales, p_lines jsonb, p_cart_discount numeric, m public.members) returns public.sales
language plpgsql security definer set search_path = public, private as $$
declare x jsonb; it public.items; v_no int := 0; v_factor numeric; v_qty numeric; v_price numeric; v_list numeric; v_disc numeric;
  v_rate numeric; v_gross numeric; v_net numeric; v_vat numeric; v_base numeric;
  v_lines jsonb := '[]'::jsonb; v_sum_before numeric := 0; v_line_disc numeric := 0; v_cart numeric := round(greatest(coalesce(p_cart_discount, 0), 0), 2);
  v_share numeric; v_alloc numeric := 0; v_i int := 0; v_n int; o public.orgs; v_can_price boolean; v_rev text; v_acct text; v_treat text; v_final text;
  lv public.line_vat; v_basis jsonb; v_nrs text;
begin
  select * into o from orgs where id = s.org_id;
  v_can_price := coalesce(private.perm_of(m, 'edit_prices') or private.perm_of(m, 'approve_adjustments'), false);
  v_rev := private.acct(s.org_id, 'sales_revenue');
  delete from sale_lines where sale_id = s.id;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Add at least one item.'; end if;
  if jsonb_array_length(p_lines) > 300 then raise exception 'A sale can have up to 300 lines.'; end if;
  for x in select * from jsonb_array_elements(p_lines) loop
    v_qty := round(private.num(x->>'qty'), 3);
    if coalesce(v_qty, 0) <= 0 then raise exception 'Every line needs a quantity above zero.'; end if;
    if nullif(x->>'item_id', '') is not null then
      select * into it from items where id = (x->>'item_id')::uuid and org_id = s.org_id and not archived;
      if not found then raise exception 'An item on this sale no longer exists.'; end if;
      v_factor := case when x->>'unit' = 'purchase' then it.pack_size else 1 end;
      v_list := round(private.list_price(s.org_id, it.id, s.price_list_id, v_qty * v_factor) * v_factor, 2);
      v_price := coalesce(round(private.num(x->>'unit_price'), 2), v_list);
      if v_price < 0 then raise exception 'A price cannot be negative.'; end if;
      if abs(v_price - v_list) > 0.004 and not v_can_price then
        raise exception 'Only someone who can edit prices can change the price of %. Give a discount instead.', it.name;
      end if;
      v_lines := v_lines || jsonb_build_object('kind', 'goods', 'item_id', it.id, 'desc', it.name, 'qty', v_qty, 'factor', v_factor, 'price', v_price,
        'list', v_list, 'treat', it.vat_treatment, 'label', case when v_factor > 1 then it.purchase_unit else it.selling_unit end, 'acct', v_rev);
    else
      if coalesce(trim(x->>'description'), '') = '' then raise exception 'A line without an item needs a description.'; end if;
      v_price := round(private.num(x->>'unit_price'), 2);
      if v_price is null or v_price < 0 then raise exception 'Enter a price for "%".', trim(x->>'description'); end if;
      if not v_can_price and s.doc_type in ('receipt', 'order') then
        raise exception 'Only someone who can edit prices can sell "%" without an item.', trim(x->>'description');
      end if;
      v_treat := coalesce(nullif(x->>'item_vat_treatment', ''), nullif(x->>'vat_treatment', ''), 'standard');
      if v_treat not in ('standard', 'zero', 'exempt') then raise exception 'Unknown VAT treatment %.', v_treat; end if;
      -- Numens decides the VAT on a line typed on the invoice, unless a person has decided it (line_vat). The app marks those
      -- lines: vat_by 'numens' takes what is on record for the words, 'person' records the person's choice. Lines from
      -- other places (bank receipts, sales schedules, the till) keep the treatment they bring.
      v_basis := null; v_nrs := null;
      if x->>'vat_by' in ('numens', 'person') then
        lv := private.line_vat_decide(s.org_id, x->>'description', x->>'vat_by', v_treat, m);
        if lv.id is not null then
          v_treat := lv.treatment; v_basis := private.line_vat_json(lv); v_nrs := lv.nrs_label;
        else
          v_basis := jsonb_build_object('source', 'waiting');
        end if;
      end if;
      v_acct := coalesce(nullif(x->>'revenue_account', ''), v_rev);
      if v_acct !~ '^4' or not private.postable(s.org_id, v_acct) then raise exception 'Choose an income account for "%".', trim(x->>'description'); end if;
      v_lines := v_lines || jsonb_build_object('kind', 'service', 'item_id', null, 'desc', left(trim(x->>'description'), 300), 'qty', v_qty, 'factor', 1,
        'price', v_price, 'list', null, 'treat', v_treat, 'label', coalesce(nullif(trim(x->>'unit_label'), ''), 'unit'), 'acct', v_acct,
        'basis', v_basis, 'nrs', v_nrs);
    end if;
    v_disc := round(greatest(coalesce(private.num(x->>'discount'), 0), 0), 2);
    if v_disc > round(v_qty * v_price, 2) then raise exception 'The discount on a line is more than the line.'; end if;
    v_lines := jsonb_set(v_lines, array[(jsonb_array_length(v_lines) - 1)::text, 'disc'], to_jsonb(v_disc));
    v_sum_before := v_sum_before + round(v_qty * v_price, 2) - v_disc;
    v_line_disc := v_line_disc + v_disc;
  end loop;
  if v_cart > v_sum_before then raise exception 'The discount is more than the sale.'; end if;
  -- At the till, discounts beyond the cashier allowance need someone who can edit prices or approve adjustments. An invoice
  -- whose discounts pass the business's limit waits for the owner's approval when it is issued instead.
  if not v_can_price and s.doc_type in ('receipt', 'order') and v_line_disc + v_cart > 0
     and (v_line_disc + v_cart) * 100 > o.max_cashier_discount_pct * (v_sum_before + v_line_disc) + 0.001 then
    raise exception 'Discounts above % percent need a manager or the owner.', trim(to_char(o.max_cashier_discount_pct, 'FM990.##'));
  end if;
  v_n := jsonb_array_length(v_lines);
  for x in select * from jsonb_array_elements(v_lines) loop
    v_i := v_i + 1;
    v_base := round((x->>'qty')::numeric * (x->>'price')::numeric, 2) - (x->>'disc')::numeric;
    v_share := case when v_cart = 0 or v_sum_before = 0 then 0 when v_i = v_n then v_cart - v_alloc else round(v_cart * v_base / v_sum_before, 2) end;
    v_share := least(v_share, v_base);
    v_alloc := v_alloc + v_share;
    v_final := case when s.export then 'zero' when s.vat_relief is not null then 'exempt' else x->>'treat' end;
    v_rate := case when not s.vat_registered then 0 when v_final = 'standard' then private.vat_rate(s.issue_date) else 0 end;
    if s.prices_include_vat then
      v_gross := v_base - v_share;
      v_net := round(v_gross / (1 + v_rate), 2);
      v_vat := v_gross - v_net;
    else
      v_net := v_base - v_share;
      v_vat := round(v_net * v_rate, 2);
      v_gross := v_net + v_vat;
    end if;
    v_no := v_no + 1;
    insert into sale_lines (sale_id, org_id, line_no, kind, item_id, description, qty, unit_label, unit_factor, unit_price, list_price, discount,
      vat_treatment, item_vat_treatment, vat_rate, net, vat, gross, revenue_account, nrs_vat_label, vat_basis)
    values (s.id, s.org_id, v_no, x->>'kind', nullif(x->>'item_id', '')::uuid, x->>'desc', (x->>'qty')::numeric, x->>'label', (x->>'factor')::numeric,
      (x->>'price')::numeric, nullif(x->>'list', '')::numeric, (x->>'disc')::numeric + v_share, v_final, x->>'treat', v_rate, v_net, v_vat, v_gross, x->>'acct',
      case when s.vat_relief is not null and v_final = 'exempt' then private.relief_label(s.vat_relief)
           when v_final = x->>'treat' and v_final in ('zero', 'exempt') then nullif(x->>'nrs', '') end,
      nullif(x->'basis', 'null'::jsonb));
  end loop;
  -- Delivery is a service and carries VAT like any other, unless the goods are exported or the sale is exempt.
  if s.delivery_fee > 0 then
    v_final := case when s.export then 'zero' when s.vat_relief is not null then 'exempt' else 'standard' end;
    v_rate := case when s.vat_registered and v_final = 'standard' then private.vat_rate(s.issue_date) else 0 end;
    if s.prices_include_vat then v_gross := s.delivery_fee; v_net := round(v_gross / (1 + v_rate), 2); v_vat := v_gross - v_net;
    else v_net := s.delivery_fee; v_vat := round(v_net * v_rate, 2); v_gross := v_net + v_vat; end if;
    insert into sale_lines (sale_id, org_id, line_no, kind, description, qty, unit_label, unit_price, vat_treatment, item_vat_treatment, vat_rate, net, vat, gross,
      revenue_account, nrs_vat_label)
    values (s.id, s.org_id, v_no + 1, 'delivery', 'Delivery', 1, 'trip', s.delivery_fee, v_final, 'standard', v_rate, v_net, v_vat, v_gross,
      private.acct(s.org_id, 'delivery_income'), case when v_final = 'exempt' then private.relief_label(s.vat_relief) end);
  end if;
  update sales set
    subtotal = (select coalesce(sum(net), 0) from sale_lines where sale_id = s.id),
    discount_total = (select coalesce(sum(discount), 0) from sale_lines where sale_id = s.id),
    vat_total = (select coalesce(sum(vat), 0) from sale_lines where sale_id = s.id),
    total = (select coalesce(sum(gross), 0) from sale_lines where sale_id = s.id)
  where id = s.id returning * into s;
  return s;
end $$;
revoke all on function private.write_lines(public.sales, jsonb, numeric, public.members) from public, anon, authenticated;

-- A draft written again keeps its typed lines with Numens.
create or replace function private.sale_lines_input(p_sale uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_agg(case when l.item_id is not null then
      jsonb_build_object('item_id', l.item_id, 'qty', l.qty, 'unit', case when l.unit_factor > 1 then 'purchase' else 'selling' end,
        'unit_price', l.unit_price, 'discount', l.discount)
    else jsonb_build_object('description', l.description, 'qty', l.qty, 'unit_label', l.unit_label, 'unit_price', l.unit_price, 'discount', l.discount,
      'vat_treatment', coalesce(l.item_vat_treatment, l.vat_treatment), 'item_vat_treatment', coalesce(l.item_vat_treatment, l.vat_treatment),
      'revenue_account', l.revenue_account, 'vat_by', case when l.vat_basis is not null then 'numens' end) end order by l.line_no)
  from sale_lines l where l.sale_id = p_sale and l.kind <> 'delivery'
$$;
revoke all on function private.sale_lines_input(uuid) from public, anon, authenticated;

-- Issuing asks a person about the VAT Numens is not sure of.
create or replace function public.issue_invoice(p_sale uuid, p_issue_date date default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members; v_route jsonb; v_unsure text;
begin
  select * into s from sales where id = p_sale for update;
  if not found then raise exception 'Invoice not found.'; end if;
  m := private.require(s.org_id, 'record_sales');
  if s.doc_type = 'invoice' and s.status = 'draft' then
    -- Numens' answer goes on each typed line. One it is not sure of, or has not given yet, a person confirms or changes
    -- before the invoice is issued (in a business that charges VAT, on a sale that is not an export or to an exempt buyer).
    select string_agg('"' || l.description || '"', ', ' order by l.line_no) into v_unsure
    from sale_lines l
    where l.sale_id = s.id and l.item_id is null and l.kind <> 'delivery' and s.vat_registered and not s.export and s.vat_relief is null
      and (l.vat_basis->>'source' = 'waiting'
           or l.vat_basis->>'source' in ('numens', 'gemini') and coalesce((l.vat_basis->>'confidence')::numeric, 0) < private.vat_sure_at(s.org_id));
    if v_unsure is not null then
      raise exception 'Check the VAT on % before issuing: Numens is not sure of it. Open the invoice to keep its answer or change it.', v_unsure;
    end if;
    v_route := private.approval_route(s.org_id, m, 'invoice',
      jsonb_build_object('discount_pct', private.sale_discount_pct(s.id), 'relief_ticked', private.relief_ticked(s)));
    if v_route is not null then
      perform private.approval_request(s.org_id, m, 'invoice', v_route, 'issue_invoice',
        jsonb_build_object('p_sale', s.id, 'p_issue_date', p_issue_date), jsonb_build_object('sale_id', s.id));
      return private.sale_json(s.id, private.can_see_costs(s.org_id));
    end if;
    perform private.approval_drop(s.id, 'Issued without it by ' || coalesce(m.display_name, 'the owner') || '.');
  end if;
  return private.issue_invoice_as(p_sale, p_issue_date, m);
end $$;

-- Recurring lines say who decides their VAT.
create or replace function private.recurring_clean_lines(p jsonb) returns jsonb
language plpgsql immutable set search_path = public, private as $$
declare x jsonb; v_out jsonb := '[]'::jsonb; v_desc text; v_qty numeric; v_price numeric; v_treat text; v_once boolean; v_by text;
  v_repeats boolean := false; v_repeat_total numeric := 0;
begin
  if p is null or jsonb_typeof(p) <> 'array' or jsonb_array_length(p) = 0 then raise exception 'Add at least one line.'; end if;
  if jsonb_array_length(p) > 50 then raise exception 'A recurring invoice can have up to 50 lines.'; end if;
  for x in select * from jsonb_array_elements(p) loop
    if jsonb_typeof(x) <> 'object' then raise exception 'Each line needs a description, a quantity and a price.'; end if;
    v_desc := trim(coalesce(x->>'description', ''));
    if v_desc = '' then raise exception 'Each line needs a description.'; end if;
    if length(v_desc) > 300 then raise exception 'Keep each line''s description under 300 characters.'; end if;
    v_qty := round(private.num(x->>'qty'), 3);
    if coalesce(v_qty, 0) <= 0 then raise exception 'Every line needs a quantity above zero.'; end if;
    v_price := round(private.num(x->>'unit_price'), 2);
    if v_price is null or v_price < 0 then raise exception 'Enter a price of zero or more for "%".', v_desc; end if;
    v_treat := coalesce(nullif(trim(x->>'vat_treatment'), ''), 'standard');
    if v_treat not in ('standard', 'zero', 'exempt') then
      raise exception 'Choose the VAT treatment of "%": standard, zero or exempt.', v_desc;
    end if;
    v_once := coalesce(lower(x->>'once') = 'true', false);
    if not v_once then
      v_repeats := true;
      v_repeat_total := v_repeat_total + round(v_qty * v_price, 2);
    end if;
    -- Who decides the VAT: Numens ('numens', also a line already saved with Numens' answer) or the person ('person').
    v_by := case when lower(trim(coalesce(x->>'vat_by', ''))) in ('numens', 'person') then lower(trim(x->>'vat_by'))
                 when jsonb_typeof(x->'vat_basis') = 'object' then 'numens' end;
    v_out := v_out || jsonb_build_array(jsonb_build_object('description', v_desc, 'qty', v_qty, 'unit_price', v_price, 'vat_treatment', v_treat, 'once', v_once)
      || case when v_by is not null then jsonb_build_object('vat_by', v_by) else '{}'::jsonb end);
  end loop;
  if not v_repeats then raise exception 'Add at least one line that repeats: a line marked once goes on the first invoice only.'; end if;
  if v_repeat_total <= 0 then raise exception 'The lines that repeat must come to more than zero.'; end if;
  return v_out;
end $$;
revoke all on function private.recurring_clean_lines(jsonb) from public, anon, authenticated;

-- The customer's copy leaves out who decided each line's VAT and why.
create or replace function public.public_document(p_token text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; v jsonb; d public.deliveries;
begin
  if p_token is null or length(p_token) < 24 then raise exception 'Document not found.'; end if;
  select * into s from sales where public_token = p_token;
  if not found or s.status = 'draft' then raise exception 'Document not found.'; end if;
  if exists (select 1 from einvoice_docs e where e.sale_id = s.id and e.kind = 'clear' and e.state <> 'signed') then
    raise exception 'This document is waiting for NRS to sign it. Open the link again in a few minutes.';
  end if;
  if s.viewed_at is null then update sales set viewed_at = now() where id = s.id; end if;
  v := private.sale_json(s.id, false);
  select * into d from deliveries where sale_id = s.id and status <> 'cancelled' order by created_at desc limit 1;
  return (v - 'created_by' - 'voided_by' - 'shift_id' - 'device_id' - 'client_uuid' - 'journal_id' - 'journal_ref' - 'org_id' - 'cost_total' - 'location_id'
    - 'price_list_id' - 'created_by_name' - 'deliveries' - 'refunds' - 'void_reason' - 'offline' - 'customer_credit' - 'export_note' - 'einvoice'
    - 'approvals' - 'vat_relief_by' - 'relief_by_name')
    || jsonb_build_object(
      'lines', (select coalesce(jsonb_agg(l - 'cost' - 'item_id' - 'revenue_account' - 'list_price' - 'original_line_id' - 'returned_qty' - 'sale_id' - 'id'
          - 'vat_basis'
          order by (l->>'line_no')::int), '[]'::jsonb) from jsonb_array_elements(v->'lines') l),
      'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', p->>'method', 'amount', p->'amount', 'status', p->>'status', 'received_at', p->'received_at')), '[]'::jsonb)
        from jsonb_array_elements(v->'payments') p where p->>'status' in ('confirmed', 'pending')),
      'requests', (select coalesce(jsonb_agg(r - 'id'), '[]'::jsonb) from jsonb_array_elements(v->'requests') r where r->>'status' = 'pending'),
      'shop_slug', (select shop_slug from orgs where id = s.org_id and shop_enabled),
      'einvoice', case when v->'einvoice' is not null and v->'einvoice'->>'state' in ('waiting', 'sending', 'signed') and v->'einvoice'->>'irn' is not null then
        jsonb_build_object('irn', v->'einvoice'->>'irn', 'qr', v->'einvoice'->>'qr', 'signed', v->'einvoice'->>'state' = 'signed',
          'kind', v->'einvoice'->>'kind', 'state', v->'einvoice'->>'state') end,
      'tracking', case when s.doc_type = 'order' then jsonb_build_object(
        'placed_at', s.created_at, 'confirmed', s.journal_id is not null, 'confirmed_at', s.issued_at, 'method', s.delivery_method,
        'cancelled', s.status in ('cancelled', 'void'),
        'delivery_status', d.status, 'scheduled_for', d.scheduled_for, 'dispatched_at', d.dispatched_at, 'delivered_at', d.delivered_at,
        'pickup_address', case when s.delivery_method = 'pickup' then (select coalesce(nullif(l.address, ''), o.address) from locations l join orgs o on o.id = l.org_id where l.id = s.location_id) end)
      end);
end $$;

-- Saving a recurring invoice settles its VAT with Numens.
create or replace function public.recurring_save(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; r public.recurring_invoices; c public.customers; v_new boolean; v_freq text; v_day int; v_start date; v_end date;
  v_due_days int; v_lines jsonb; v_auto boolean; v_channel text; v_notes text; v_client uuid; v_next date; v_issued boolean := false;
  v_route jsonb;
begin
  m := private.require(p_org, 'record_sales');
  if p is null or jsonb_typeof(p) <> 'object' then raise exception 'Send the recurring invoice''s details.'; end if;
  v_new := nullif(trim(p->>'id'), '') is null;
  if not v_new then
    select * into r from recurring_invoices where id = private.uuid_of(trim(p->>'id')) and org_id = p_org for update;
    if r.id is null then raise exception 'Recurring invoice not found.'; end if;
    -- What p leaves out stays as it is.
    p := to_jsonb(r) || p;
  end if;

  select * into c from customers where id = private.uuid_of(trim(p->>'customer_id')) and org_id = p_org and not archived and not is_walk_in;
  if c.id is null then raise exception 'Choose the customer.'; end if;
  v_freq := nullif(trim(p->>'frequency'), '');
  if v_freq is null or v_freq not in ('monthly', 'quarterly', 'annually') then raise exception 'Choose how often: monthly, quarterly or annually.'; end if;
  v_day := case when p->>'day_of_month' ~ '^\s*[0-9]{1,2}\s*$' then trim(p->>'day_of_month')::int end;
  if v_day is null or v_day not between 1 and 28 then raise exception 'Choose a day of the month from 1 to 28.'; end if;
  v_start := private.date_or_null(p->>'start_date');
  if v_start is null then raise exception 'Enter the start date.'; end if;
  if nullif(trim(p->>'end_date'), '') is not null then
    v_end := private.date_or_null(p->>'end_date');
    if v_end is null then raise exception 'Enter the end date as a date, or leave it out.'; end if;
    if v_end < v_start then raise exception 'The end date must be on or after the start date.'; end if;
  end if;
  if nullif(trim(p->>'due_days'), '') is null then
    v_due_days := 14;
  else
    v_due_days := case when p->>'due_days' ~ '^\s*[0-9]{1,3}\s*$' then trim(p->>'due_days')::int end;
    if v_due_days is null or v_due_days > 365 then raise exception 'Give the days to pay as a whole number from 0 to 365.'; end if;
  end if;
  v_lines := private.recurring_clean_lines(p->'lines');
  -- Set up or changed by the firm that runs the books, the schedule waits for approval once; then it runs on its own.
  v_route := private.approval_route(p_org, m, 'recurring');
  if not v_new then
    v_issued := exists (select 1 from recurring_invoice_runs where schedule_id = r.id and status in ('issued', 'waiting_nrs', 'sent'));
    -- A line marked once goes on the first invoice only: added after that, it would never be billed. Those already there stay.
    if v_issued and exists (select 1 from jsonb_array_elements(v_lines) l where (l->>'once')::boolean
        and not r.lines @> jsonb_build_array(jsonb_build_object('description', l->'description', 'qty', l->'qty', 'unit_price', l->'unit_price', 'once', true))) then
      raise exception 'This schedule has already issued an invoice, so a new line marked once would never be billed. Bill it on an invoice of its own.';
    end if;
  end if;
  -- Each invoice is issued without anyone there, so the VAT Numens is not sure of is confirmed now.
  v_lines := private.recurring_vat(p_org, v_lines, m);
  if p->'auto_send' is null or jsonb_typeof(p->'auto_send') = 'null' then
    v_auto := true;
  else
    v_auto := case lower(p->>'auto_send') when 'true' then true when 'false' then false end;
    if v_auto is null then raise exception 'Say whether each invoice is sent to the customer.'; end if;
  end if;
  v_channel := coalesce(nullif(trim(p->>'send_channel'), ''), 'email');
  if v_channel not in ('email', 'whatsapp') then raise exception 'Send by email or WhatsApp.'; end if;
  if v_auto then perform private.require_outbound(p_org, v_channel, 'document'); end if;
  v_notes := nullif(trim(p->>'notes'), '');
  if length(v_notes) > 1000 then raise exception 'Keep the notes under 1,000 characters.'; end if;
  if nullif(trim(p->>'practice_client_id'), '') is not null then
    select pc.id into v_client from practice_clients pc join practices pr on pr.id = pc.practice_id
    where pc.id = private.uuid_of(trim(p->>'practice_client_id')) and pr.firm_org_id = p_org;
    if v_client is null then raise exception 'Choose a client of the practice whose firm business this is.'; end if;
  end if;

  if v_new then
    v_next := private.recurring_first(v_freq, v_day, v_start);
  elsif v_freq is distinct from r.frequency or v_day is distinct from r.day_of_month or v_start is distinct from r.start_date then
    if exists (select 1 from recurring_invoice_runs where schedule_id = r.id and status <> 'failed') then
      v_next := private.recurring_first(v_freq, v_day, greatest(v_start, date_trunc('month', r.next_run::timestamp)::date));
    else
      v_next := private.recurring_first(v_freq, v_day, v_start);
    end if;
  else
    v_next := r.next_run;
  end if;
  if v_end is not null and v_next > v_end and coalesce(r.status, 'active') <> 'ended' then
    raise exception 'No invoice date falls before the end date: the next would be %.', to_char(v_next, 'DD Mon YYYY');
  end if;

  if v_new then
    insert into recurring_invoices (org_id, customer_id, frequency, day_of_month, start_date, end_date, next_run, due_days, lines, auto_send,
      send_channel, notes, created_by, practice_client_id, approval_state)
    values (p_org, c.id, v_freq, v_day, v_start, v_end, v_next, v_due_days, v_lines, v_auto, v_channel, v_notes, m.id, v_client,
      case when v_route is not null then 'pending' else 'approved' end)
    returning * into r;
  else
    update recurring_invoices set customer_id = c.id, frequency = v_freq, day_of_month = v_day, start_date = v_start, end_date = v_end,
      next_run = v_next, due_days = v_due_days, lines = v_lines, auto_send = v_auto, send_channel = v_channel, notes = v_notes,
      practice_client_id = v_client, created_by = m.id, updated_at = now(),
      approval_state = case when v_route is not null then 'pending' else 'approved' end
    where id = r.id;
  end if;
  if v_route is not null then
    perform private.approval_request(p_org, m, 'recurring', v_route, null, '{}'::jsonb, jsonb_build_object('recurring_id', r.id));
  else
    update approvals set status = 'cancelled', note = 'Changed by ' || coalesce(m.display_name, 'the owner') || '.', decided_at = now()
    where recurring_id = r.id and status = 'pending';
  end if;
  return private.recurring_json(r.id);
end $$;

-- Each recurring invoice takes the VAT on record when it is issued.
create or replace function private.recurring_run(p_id uuid, p_run_date date, p_member public.members default null) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare r public.recurring_invoices; m public.members; s public.sales; v_run uuid; v_first boolean; v_lines jsonb; v_status text; v_send_error text;
begin
  select * into r from recurring_invoices where id = p_id for update;
  if r.id is null then raise exception 'Recurring invoice not found.'; end if;
  if p_member.id is not null and p_member.org_id is distinct from r.org_id then raise exception 'Recurring invoice not found.'; end if;
  insert into recurring_invoice_runs (schedule_id, run_date, status) values (r.id, p_run_date, 'issued')
  on conflict (schedule_id, run_date) do update set status = 'issued', sale_id = null, error = null, send_error = null, created_at = now()
    where recurring_invoice_runs.status = 'failed'
  returning id into v_run;
  if v_run is null then return null; end if;

  if p_member.id is not null then
    m := p_member;
  else
    m := private.recurring_actor(r.org_id, r.created_by);
  end if;
  perform private.set_actor(m.user_id);
  v_first := not exists (select 1 from recurring_invoice_runs x
    where x.schedule_id = r.id and x.id <> v_run and x.status in ('issued', 'waiting_nrs', 'sent'));
  select jsonb_agg(jsonb_build_object('description', e.l->>'description', 'kind', 'service', 'qty', e.l->'qty', 'unit_price', e.l->'unit_price',
      'vat_treatment', e.l->>'vat_treatment', 'vat_by', case when jsonb_typeof(e.l->'vat_basis') = 'object' then 'numens' end) order by e.n)
    into v_lines
  from jsonb_array_elements(r.lines) with ordinality as e(l, n)
  where v_first or not coalesce((e.l->>'once')::boolean, false);
  s := private.create_sale(r.org_id, jsonb_build_object('doc_type', 'invoice', 'status', 'draft', 'channel', 'recurring', 'customer_id', r.customer_id,
    'issue_date', p_run_date, 'due_date', p_run_date + r.due_days, 'prices_include_vat', false, 'notes', r.notes,
    'lines', coalesce(v_lines, '[]'::jsonb)), m);
  perform private.issue_invoice_as(s.id, p_run_date, m);
  select * into s from sales where id = s.id;
  if s.status = 'draft' and exists (select 1 from einvoice_docs d where d.sale_id = s.id and d.state in ('waiting', 'sending')) then
    v_status := 'waiting_nrs';
  elsif r.auto_send then
    v_send_error := private.recurring_send(s.id, r.send_channel, m);
    v_status := case when v_send_error is null then 'sent' else 'issued' end;
  else
    v_status := 'issued';
  end if;
  update recurring_invoice_runs set sale_id = s.id, status = v_status, send_error = v_send_error where id = v_run;
  update recurring_invoices set last_run_at = now(), updated_at = now() where id = r.id;
  return s.id;
end $$;
revoke all on function private.recurring_run(uuid, date, public.members) from public, anon, authenticated;

-- A new product received as stock: Numens decides its VAT unless the person did.
create or replace function private.post_receipt_internal(p_receipt uuid, p_member uuid, p_at timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.receipts; m public.members; l public.receipt_lines; it public.items; v public.vendors; o public.orgs;
  v_bad int; v_net numeric := 0; v_vat_base numeric := 0; v_vat numeric := 0; v_gross numeric; v_line numeric;
  v_vat_t text; v_pack int; v_su_qty numeric; v_cost_su numeric; v_old_last numeric; v_on_hand numeric; v_wac numeric;
  j public.journals; v_item uuid; v_batch uuid; v_new jsonb; v_price numeric; v_props int := 0; v_can_price boolean; v_pid uuid;
  v_memo text; v_acct text; v_amt numeric; v_by_acct jsonb := '{}'::jsonb; v_jl jsonb; v_billed boolean; v_mine boolean;
begin
  select * into r from receipts where id = p_receipt for update;
  if not found then raise exception 'Receipt not found.'; end if;
  select * into m from members where id = p_member;
  select * into o from orgs where id = r.org_id;
  if r.status <> 'needs_review' then raise exception 'This receipt is already %.', replace(r.status, '_', ' '); end if;
  if r.location_id is null then raise exception 'Choose the branch receiving this stock.'; end if;
  if r.vendor_id is null and coalesce(trim(r.vendor_name), '') = '' then raise exception 'Choose or name the vendor.'; end if;
  if not exists (select 1 from receipt_lines where receipt_id = r.id) then raise exception 'Add at least one line.'; end if;
  select count(*) into v_bad from receipt_lines
  where receipt_id = r.id and (not confirmed or qty <= 0 or unit_cost <= 0
    or (item_id is null and coalesce(trim(new_item->>'name'), '') = ''));
  if v_bad > 0 then
    raise exception '% line% still need% confirmation before posting.', v_bad,
      case when v_bad > 1 then 's' else '' end, case when v_bad > 1 then '' else 's' end;
  end if;

  if r.vendor_id is null then
    select id into r.vendor_id from vendors where org_id = r.org_id and lower(name) = lower(trim(r.vendor_name)) limit 1;
    if r.vendor_id is null then
      insert into vendors (org_id, name, vat_registered, channel)
      values (r.org_id, trim(r.vendor_name), r.vendor_vat_registered, 'whatsapp') returning id into r.vendor_id;
    end if;
    update receipts set vendor_id = r.vendor_id where id = r.id;
  end if;
  select * into v from vendors where id = r.vendor_id;
  v_can_price := private.perm_of(m, 'edit_prices');

  -- Totals first: the journal must exist before any movement references it.
  for l in select * from receipt_lines where receipt_id = r.id order by line_no loop
    v_line := round(l.qty * l.unit_cost, 2);
    if l.item_id is not null then
      select vat_treatment into v_vat_t from items where id = l.item_id;
      v_acct := private.inv_acct(l.item_id);
    else
      v_vat_t := coalesce(nullif(l.new_item->>'vat_treatment', ''), 'standard');
      v_acct := private.acct(r.org_id, 'inventory');
    end if;
    v_net := v_net + v_line;
    v_by_acct := jsonb_set(v_by_acct, array[v_acct], to_jsonb(coalesce((v_by_acct->>v_acct)::numeric, 0) + v_line));
    if v_vat_t = 'standard' then v_vat_base := v_vat_base + v_line; end if;
  end loop;
  -- Stock received on a supplier's bill (an uploaded invoice): the bill carries the purchase, its VAT and what is owed, so the
  -- receipt only moves the stock in.
  v_billed := exists (select 1 from bills where receipt_id = r.id and source <> 'receipt');
  v_vat := case when v_billed then 0 when r.vendor_vat_registered then round(v_vat_base * private.vat_rate(coalesce(r.invoice_date, p_at::date)), 2) else 0 end;
  v_gross := v_net + v_vat;
  v_memo := v.name || coalesce(' · ' || nullif(r.invoice_no, ''), '');

  v_jl := case when v_billed then '[]'::jsonb else jsonb_build_array(
    jsonb_build_object('code', private.acct(r.org_id, 'purchases'), 'debit', v_net, 'memo', 'Stock bought from ' || v.name),
    jsonb_build_object('code', private.acct(r.org_id, 'input_vat'), 'debit', v_vat, 'memo', 'Input VAT 7.5%'),
    jsonb_build_object('code', private.acct(r.org_id, 'payables'), 'credit', v_gross, 'memo', 'Payable to ' || v.name)) end;
  for v_acct, v_amt in select key, value::numeric from jsonb_each_text(v_by_acct) order by key loop
    v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', v_acct, 'debit', v_amt, 'location_id', r.location_id, 'memo', 'Stock received'));
  end loop;
  v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(r.org_id, 'inventory_movement'), 'credit', v_net,
    'location_id', r.location_id, 'memo', 'Purchases moved into stock'));
  j := private.post_journal(r.org_id, v_memo, 'receipt', r.id, m.id, null, v_jl, p_at);

  for l in select * from receipt_lines where receipt_id = r.id order by line_no loop
    v_item := l.item_id;
    if v_item is null then
      v_new := l.new_item;
      v_pack := greatest(1, coalesce(nullif(v_new->>'pack_size', '')::numeric, 1)::int);
      v_cost_su := l.unit_cost / case when l.unit_kind = 'purchase' then v_pack else 1 end;
      v_price := nullif(v_new->>'price', '')::numeric;
      if not v_can_price or v_price is null or v_price <= 0 then
        v_price := private.round_price(v_cost_su * 1.15);
      end if;
      -- Numens decides the new product's VAT once it exists. A person who sets VAT (edits prices or keeps the books) and chose
      -- it here has decided it instead.
      v_mine := v_new->>'vat_by' = 'person' and v_new->>'vat_treatment' in ('standard', 'zero', 'exempt')
        and coalesce(private.perm_of(m, 'edit_prices') or private.perm_of(m, 'keep_books'), false);
      insert into items (org_id, name, category, vat_treatment, purchase_unit, pack_size, selling_unit, informal_unit, track_batches,
        preferred_vendor_id, price, needs_review, created_by, barcode, vat_basis, vat_checked_at)
      values (r.org_id, trim(v_new->>'name'), coalesce(nullif(trim(v_new->>'category'), ''), 'General'),
        coalesce(nullif(v_new->>'vat_treatment', ''), 'standard'), coalesce(nullif(trim(v_new->>'purchase_unit'), ''), 'Carton'), v_pack,
        coalesce(nullif(trim(v_new->>'selling_unit'), ''), 'piece'),
        coalesce(nullif(trim(v_new->>'selling_unit'), ''), 'piece') in ('derica', 'mudu', 'paint bucket'),
        coalesce((v_new->>'track_batches')::boolean, false), r.vendor_id, v_price,
        not coalesce(v_can_price and nullif(v_new->>'price', '')::numeric > 0, false), m.id,
        case when nullif(trim(v_new->>'barcode'), '') is not null
              and not exists (select 1 from items where org_id = r.org_id and barcode = trim(v_new->>'barcode'))
             then trim(v_new->>'barcode') end,
        case when v_mine then jsonb_build_object('source', 'manual', 'treatment', v_new->>'vat_treatment', 'reason', 'Set when the stock was received',
          'by', m.display_name, 'at', now()) end,
        case when v_mine then now() end)
      returning id into v_item;
      insert into item_costs (item_id, org_id, wac) values (v_item, r.org_id, 0);
      update receipt_lines set item_id = v_item where id = l.id;
    end if;

    select * into it from items where id = v_item;
    v_pack := it.pack_size;
    v_su_qty := l.qty * case when l.unit_kind = 'purchase' then v_pack else 1 end;
    v_cost_su := round(l.unit_cost / case when l.unit_kind = 'purchase' then v_pack else 1 end, 4);

    -- Weighted average cost, recalculated on every receipt.
    select coalesce(sum(qty), 0) into v_on_hand from stock_levels where item_id = v_item;
    select wac, last_cost into v_wac, v_old_last from item_costs where item_id = v_item for update;
    if v_on_hand <= 0 or coalesce(v_wac, 0) = 0 then v_wac := v_cost_su;
    else v_wac := round((v_on_hand * v_wac + v_su_qty * v_cost_su) / (v_on_hand + v_su_qty), 4); end if;
    update item_costs set wac = v_wac, last_cost = v_cost_su, replacement_cost = v_cost_su,
      replacement_source = j.ref || ' · ' || v.name, updated_at = now()
    where item_id = v_item;

    v_batch := null;
    if it.track_batches then
      insert into batches (org_id, item_id, location_id, batch_no, expiry_date, qty_received, qty_remaining, receipt_id, created_at)
      values (r.org_id, v_item, r.location_id, coalesce(nullif(trim(l.batch_no), ''), 'R' || j.je_no || '-' || l.line_no),
        l.expiry_date, v_su_qty, v_su_qty, r.id, p_at)
      returning id into v_batch;
    end if;

    perform private.add_movement(r.org_id, 'receipt', v_item, r.location_id, v_su_qty, v_cost_su, null, j.id, m.id,
      private.channel_for(r.source), p_at,
      jsonb_build_object('receipt_id', r.id, 'batch_id', v_batch, 'device_id', r.device_id, 'offline', r.offline,
        'note', coalesce(l.raw_text, '')));

    if it.preferred_vendor_id is null then update items set preferred_vendor_id = r.vendor_id where id = v_item; end if;

    if v_old_last is not null and v_cost_su > v_old_last + 0.004 then
      v_pid := private.propose_price(v_item, 'cost_increase', v_old_last, v_cost_su,
        j.ref || ' · ' || v.name || ' · ' || to_char(private.local_day(r.org_id, p_at), 'DD Mon'));
      if v_pid is not null then v_props := v_props + 1; end if;
    end if;
  end loop;

  update receipts set status = 'posted', net = v_net, input_vat = v_vat, gross = v_gross, journal_id = j.id, ref = j.ref,
    posted_by = m.id, posted_at = p_at, vendor_id = r.vendor_id
  where id = r.id;
  if r.po_id is not null then
    update purchase_orders set status = 'received', received_at = p_at where id = r.po_id and status = 'sent';
  end if;
  return jsonb_build_object('journal_ref', j.ref, 'net', v_net, 'vat', v_vat, 'gross', v_gross, 'proposals', v_props);
end $$;
revoke all on function private.post_receipt_internal(uuid, uuid, timestamptz) from public, anon, authenticated;
