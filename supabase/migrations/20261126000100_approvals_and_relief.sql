-- Release 2 of the identity and compliance work: approvals, and sales exempt from VAT for diplomatic missions, free trade
-- zone entities and humanitarian projects.
--
-- 1. What waits for approval (private.approval_route), decided before anything posts:
--    - A firm's people in a business they work for (their places carry members.practice_id) ask before they issue an
--      invoice, raise a credit note, refund a customer, pay out of the wallet (a payout or a bulk payment) or save a
--      recurring invoice. Under full mandate the director who confirmed the wallets approves, from a link and a code, with
--      no login. For a client who runs its own books (involved), the owner or an admin approves in the app.
--    - Anyone who is not the owner or an admin asks before a credit note, before issuing an invoice whose discounts come to
--      more than the business's limit (orgs.discount_approval_pct, 10% unless the owner changes it), and before issuing an
--      invoice they marked exempt from VAT themselves. The owner or an admin approves.
--    A request is tried first and rolled back, so one that could not go through is refused at once with the reason. It is
--    then kept in approvals with what the approver sees. Approved, it is carried out as the person who asked, with their
--    own permissions at that moment; rejected, nothing happens (a payout is cancelled, a schedule paused).
-- 2. Exempt buyers: a customer can carry a VAT relief with its reference (customers.vat_relief, set by the owner or an
--    admin), and any document can be marked on its own (sales.vat_relief, with vat_relief_by when a person marked it).
--    Every line of such a document is exempt and carries the NRS label for the relief. An export stays zero-rated.
-- 3. The director's approvals: the email and phone their confirmation code reached are kept for approvals
--    (practice_director_confirmations.approver_email and approver_phone) while the mandate lasts, and wiped when it ends or
--    another director confirms. approval_links carry the link (minted as the email goes) and the code. A confirmation
--    TaxStreem accepted on a NIN slip leaves nobody to reach, so the firm may then ask a director to confirm by code.
-- Run once, in the SQL Editor of the counta project, as one script.

-- ---------------------------------------------------------------------------
-- 1. Settings and columns
-- ---------------------------------------------------------------------------
alter table public.orgs add column if not exists discount_approval_pct numeric(5,2) not null default 10
  check (discount_approval_pct between 0 and 100);

alter table public.customers add column if not exists vat_relief text check (vat_relief in ('diplomatic', 'free_zone', 'humanitarian'));
alter table public.customers add column if not exists vat_relief_ref text check (length(vat_relief_ref) between 2 and 120);
alter table public.sales add column if not exists vat_relief text check (vat_relief in ('diplomatic', 'free_zone', 'humanitarian'));
alter table public.sales add column if not exists vat_relief_ref text check (length(vat_relief_ref) <= 120);
alter table public.sales add column if not exists vat_relief_by uuid references public.members(id) on delete set null;
create index if not exists sales_vat_relief_by on public.sales(vat_relief_by) where vat_relief_by is not null;

alter table public.recurring_invoices add column if not exists approval_state text check (approval_state in ('pending', 'approved', 'rejected'));

alter table public.practice_director_confirmations add column if not exists approver_email text check (length(approver_email) <= 254);
alter table public.practice_director_confirmations add column if not exists approver_phone text check (approver_phone ~ '^234[0-9]{10}$');

-- ---------------------------------------------------------------------------
-- 2. VAT relief for exempt buyers
-- ---------------------------------------------------------------------------
-- The NRS VAT return's description for each relief (public.nrs_vat_labels, all exempt).
create or replace function private.relief_label(p text) returns text
language sql immutable set search_path = public, private as $$
  select case p
    when 'diplomatic' then 'Goods or services supplied to a diplomatic mission, diplomat or person recognised under the Diplomatic Immunities and Privileges Act whose activity is in public interest, and not for profit'
    when 'free_zone' then 'Supplies consumed by an approved entity in the export processing or free trade zones'
    when 'humanitarian' then 'Goods purchased for use in humanitarian donor funded projects' end
$$;

-- Who the relief is for, as a document says it ("Exempt from VAT: a supply to ...").
create or replace function private.relief_words(p text) returns text
language sql immutable set search_path = public, private as $$
  select case p when 'diplomatic' then 'a diplomatic mission or diplomat' when 'free_zone' then 'an approved free trade zone entity'
    when 'humanitarian' then 'a humanitarian donor-funded project' end
$$;

-- A document's lines as write_lines takes them, so they can be worked out again (VAT, discounts) without being retyped.
-- Each line keeps its own VAT treatment (item_vat_treatment), so taking an export or a relief off restores it.
create or replace function private.sale_lines_input(p_sale uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_agg(case when l.item_id is not null then
      jsonb_build_object('item_id', l.item_id, 'qty', l.qty, 'unit', case when l.unit_factor > 1 then 'purchase' else 'selling' end,
        'unit_price', l.unit_price, 'discount', l.discount)
    else jsonb_build_object('description', l.description, 'qty', l.qty, 'unit_label', l.unit_label, 'unit_price', l.unit_price, 'discount', l.discount,
      'vat_treatment', coalesce(l.item_vat_treatment, l.vat_treatment), 'item_vat_treatment', coalesce(l.item_vat_treatment, l.vat_treatment),
      'revenue_account', l.revenue_account) end order by l.line_no)
  from sale_lines l where l.sale_id = p_sale and l.kind <> 'delivery'
$$;

-- Marks a document exempt from VAT for one of the reliefs, or takes the mark off, and works its lines out again. The
-- customer's own relief (which the owner or an admin set) counts as theirs; anything else is marked by the person.
create or replace function private.sale_set_relief(s public.sales, p_relief text, p_ref text, m public.members, p_rewrite boolean default true)
returns public.sales
language plpgsql security definer set search_path = public, private as $$
declare v_relief text := nullif(trim(coalesce(p_relief, '')), ''); v_ref text := nullif(trim(coalesce(p_ref, '')), ''); c public.customers;
begin
  if v_relief is not null and v_relief not in ('diplomatic', 'free_zone', 'humanitarian') then
    raise exception 'Choose who the supply is for: a diplomatic mission or diplomat, a free trade zone entity, or a humanitarian project.';
  end if;
  if v_relief is not null and coalesce(length(v_ref), 0) < 2 then
    raise exception 'Add the reference for the exemption: the mission''s or diplomat''s accreditation, the zone licence, or the project''s reference.';
  end if;
  if length(v_ref) > 120 then raise exception 'Keep the reference under 120 characters.'; end if;
  if v_relief is not null and s.export then raise exception 'An export is zero-rated already, so it cannot also be exempt.'; end if;
  if s.vat_relief is not distinct from v_relief and (v_relief is null or s.vat_relief_ref is not distinct from v_ref) then return s; end if;
  select * into c from customers where id = s.customer_id;
  update sales set vat_relief = v_relief, vat_relief_ref = case when v_relief is not null then v_ref end,
    vat_relief_by = case when v_relief is null or (c.vat_relief is not distinct from v_relief and c.vat_relief_ref is not distinct from v_ref) then null else m.id end
  where id = s.id returning * into s;
  if p_rewrite and exists (select 1 from sale_lines where sale_id = s.id) then
    s := private.write_lines(s, private.sale_lines_input(s.id), null, m);
  end if;
  return s;
end $$;

-- Marked exempt by someone other than the owner or an admin, and not the customer's own relief.
create or replace function private.relief_ticked(s public.sales) returns boolean
language sql stable security definer set search_path = public, private as $$
  select s.vat_relief is not null and s.vat_relief_by is not null
    and coalesce((select role from members where id = s.vat_relief_by), '') not in ('owner', 'admin')
$$;

-- Marks a document that has not posted exempt from VAT (or not): p_relief diplomatic, free_zone, humanitarian or null,
-- with its reference. Anyone who records sales may; an invoice someone other than the owner or an admin marked waits for
-- their approval when it is issued.
create or replace function public.set_sale_vat_relief(p_sale uuid, p_relief text, p_ref text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members;
begin
  select * into s from sales where id = p_sale for update;
  if not found then raise exception 'Document not found.'; end if;
  m := private.require(s.org_id, 'record_sales');
  if s.journal_id is not null or not (s.status = 'draft' or (s.doc_type = 'quote' and s.status = 'open') or (s.doc_type = 'order' and s.status = 'pending')) then
    raise exception '% has already posted. Raise a credit note and issue it again instead.', s.number;
  end if;
  if exists (select 1 from einvoice_docs where sale_id = s.id and state in ('waiting', 'sending')) then
    raise exception 'NRS is checking %. Take it back first to change it.', s.number;
  end if;
  perform private.approval_drop(s.id, 'The invoice was changed after it was sent for approval.');
  s := private.sale_set_relief(s, p_relief, p_ref, m);
  return private.sale_json(s.id, private.can_see_costs(s.org_id));
end $$;

CREATE OR REPLACE FUNCTION private.sale_export_snapshot()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare v_country text; v_relief text; v_ref text;
begin
  if tg_op = 'INSERT' and new.doc_type = 'credit_note' and new.original_sale_id is not null then
    select customer_country, export, vat_relief, vat_relief_ref into new.customer_country, new.export, new.vat_relief, new.vat_relief_ref
    from sales where id = new.original_sale_id;
    return new;
  end if;
  if tg_op = 'UPDATE' and new.customer_id is not distinct from old.customer_id then return new; end if;
  select country, vat_relief, vat_relief_ref into v_country, v_relief, v_ref from customers where id = new.customer_id;
  new.customer_country := coalesce(v_country, 'NG');
  new.export := new.customer_country <> 'NG';
  new.export_note := null;
  -- The customer's own exemption from VAT (a diplomatic mission, a free trade zone entity, a humanitarian project), unless
  -- the sale is an export, which is zero-rated.
  new.vat_relief := case when not new.export then v_relief end;
  new.vat_relief_ref := case when not new.export and v_relief is not null then v_ref end;
  new.vat_relief_by := null;
  return new;
end $function$;


CREATE OR REPLACE FUNCTION private.write_lines(s sales, p_lines jsonb, p_cart_discount numeric, m members)
 RETURNS sales
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare x jsonb; it public.items; v_no int := 0; v_factor numeric; v_qty numeric; v_price numeric; v_list numeric; v_disc numeric;
  v_rate numeric; v_gross numeric; v_net numeric; v_vat numeric; v_base numeric;
  v_lines jsonb := '[]'::jsonb; v_sum_before numeric := 0; v_line_disc numeric := 0; v_cart numeric := round(greatest(coalesce(p_cart_discount, 0), 0), 2);
  v_share numeric; v_alloc numeric := 0; v_i int := 0; v_n int; o public.orgs; v_can_price boolean; v_rev text; v_acct text; v_treat text; v_final text;
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
      v_acct := coalesce(nullif(x->>'revenue_account', ''), v_rev);
      if v_acct !~ '^4' or not private.postable(s.org_id, v_acct) then raise exception 'Choose an income account for "%".', trim(x->>'description'); end if;
      v_lines := v_lines || jsonb_build_object('kind', 'service', 'item_id', null, 'desc', left(trim(x->>'description'), 300), 'qty', v_qty, 'factor', 1,
        'price', v_price, 'list', null, 'treat', v_treat, 'label', coalesce(nullif(trim(x->>'unit_label'), ''), 'unit'), 'acct', v_acct);
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
      vat_treatment, item_vat_treatment, vat_rate, net, vat, gross, revenue_account, nrs_vat_label)
    values (s.id, s.org_id, v_no, x->>'kind', nullif(x->>'item_id', '')::uuid, x->>'desc', (x->>'qty')::numeric, x->>'label', (x->>'factor')::numeric,
      (x->>'price')::numeric, nullif(x->>'list', '')::numeric, (x->>'disc')::numeric + v_share, v_final, x->>'treat', v_rate, v_net, v_vat, v_gross, x->>'acct',
      case when s.vat_relief is not null and v_final = 'exempt' then private.relief_label(s.vat_relief) end);
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
end $function$;


CREATE OR REPLACE FUNCTION public.set_sale_export(p_sale uuid, p_export boolean, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare s public.sales; m public.members;
begin
  select * into s from sales where id = p_sale for update;
  if not found then raise exception 'Document not found.'; end if;
  m := private.require(s.org_id, null);
  if not (private.perm_of(m, 'approve_adjustments') or private.perm_of(m, 'keep_books')) then
    raise exception 'Only a manager or the bookkeeper changes whether a sale is an export.' using errcode = '42501';
  end if;
  if s.journal_id is not null or not (s.status = 'draft' or (s.doc_type = 'quote' and s.status = 'open') or (s.doc_type = 'order' and s.status = 'pending')) then
    raise exception '% has already posted. Raise a credit note and issue it again instead.', s.number;
  end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Say why, for the VAT records.'; end if;
  perform private.approval_drop(s.id, 'The invoice was changed after it was sent for approval.');
  -- An export is zero-rated, so it takes the place of an exemption.
  update sales set export = p_export, export_note = left(trim(p_reason), 300),
    vat_relief = case when p_export then null else vat_relief end, vat_relief_ref = case when p_export then null else vat_relief_ref end,
    vat_relief_by = case when p_export then null else vat_relief_by end
  where id = s.id returning * into s;
  s := private.write_lines(s, private.sale_lines_input(s.id), null, m);
  return private.sale_json(s.id, private.can_see_costs(s.org_id));
end $function$;


CREATE OR REPLACE FUNCTION public.convert_quote(p_sale uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare q public.sales; m public.members; v_lines jsonb; s public.sales;
begin
  select * into q from sales where id = p_sale for update;
  if not found or q.doc_type <> 'quote' then raise exception 'Quote not found.'; end if;
  m := private.require(q.org_id, 'record_sales');
  if q.status <> 'open' then raise exception '% is %.', q.number, q.status; end if;
  v_lines := private.sale_lines_input(q.id);
  -- The quoted prices are what the customer agreed, so the invoice keeps them whoever converts it.
  s := private.create_sale(q.org_id, jsonb_build_object('doc_type', 'invoice', 'status', 'draft', 'customer_id', q.customer_id,
    'location_id', q.location_id, 'price_list_id', q.price_list_id, 'delivery_fee', q.delivery_fee, 'notes', q.notes, 'terms', q.terms,
    'reference', q.number, 'prices_include_vat', q.prices_include_vat, 'delivery_address', q.delivery_address, 'lines', v_lines),
    jsonb_populate_record(m, '{"p_edit_prices": true}'::jsonb));
  -- An exemption marked on the quote goes on the invoice, as marked.
  if q.vat_relief is distinct from s.vat_relief or q.vat_relief_ref is distinct from s.vat_relief_ref then
    update sales set vat_relief = q.vat_relief, vat_relief_ref = q.vat_relief_ref, vat_relief_by = q.vat_relief_by where id = s.id returning * into s;
    s := private.write_lines(s, private.sale_lines_input(s.id), null, jsonb_populate_record(m, '{"p_edit_prices": true}'::jsonb));
  end if;
  update sales set status = 'converted', converted_to = s.id where id = q.id;
  return private.sale_json(s.id, private.can_see_costs(q.org_id));
end $function$;


CREATE OR REPLACE FUNCTION public.save_customer(p_org uuid, p_customer jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; c public.customers; v_country text; v_id uuid; v_agent boolean := (p_customer->>'wvat_agent')::boolean;
  v_ncd boolean := (p_customer->>'ncd_levy')::boolean; v_rate numeric; v_relief text; v_relief_ref text;
begin
  m := private.require(p_org, 'record_sales');
  if nullif(p_customer->>'kind', '') is not null and p_customer->>'kind' not in ('individual', 'business', 'government') then
    raise exception 'Choose whether the customer is a person, a business or a government body.';
  end if;
  if nullif(p_customer->>'id', '') is not null then
    select * into c from customers where id = (p_customer->>'id')::uuid and org_id = p_org;
  end if;
  if p_customer ? 'tin' then
    v_country := coalesce(upper(nullif(trim(p_customer->>'country'), '')), c.country, 'NG');
    p_customer := p_customer || jsonb_build_object('tin', case when v_country = 'NG' then private.tax_id_input(p_customer->>'tin', c.tin, 'The customer''s Tax ID')
      else nullif(left(trim(p_customer->>'tin'), 40), '') end);
  end if;
  if v_agent is not null and v_agent is distinct from coalesce(c.wvat_agent, false)
     and not (private.perm_of(m, 'approve_adjustments') or private.perm_of(m, 'keep_books')) then
    raise exception 'Only a manager, an accountant or the owner marks a customer as a withholding VAT agent.';
  end if;
  if p_customer ? 'wht_rate' then
    v_rate := case when nullif(trim(p_customer->>'wht_rate'), '') is null then null else round((p_customer->>'wht_rate')::numeric, 4) end;
    if v_rate is not null and (v_rate < 0 or v_rate > 0.25) then raise exception 'The WHT rate is between 0%% and 25%%.'; end if;
  end if;
  if ((v_ncd is not null and v_ncd is distinct from coalesce(c.ncd_levy, false)) or (p_customer ? 'wht_rate' and v_rate is distinct from c.wht_rate))
     and not (private.perm_of(m, 'approve_adjustments') or private.perm_of(m, 'keep_books')) then
    raise exception 'Only a manager, an accountant or the owner changes what a customer deducts.';
  end if;
  -- Exempt from VAT (a diplomatic mission or diplomat, a free trade zone entity, a humanitarian project), with the reference
  -- for it: the owner or an admin marks it.
  if p_customer ? 'vat_relief' then
    v_relief := nullif(trim(coalesce(p_customer->>'vat_relief', '')), '');
    v_relief_ref := nullif(trim(coalesce(p_customer->>'vat_relief_ref', '')), '');
    if v_relief is not null and v_relief not in ('diplomatic', 'free_zone', 'humanitarian') then
      raise exception 'Choose who the customer is: a diplomatic mission or diplomat, a free trade zone entity, or a humanitarian project.';
    end if;
    if v_relief is not null and coalesce(length(v_relief_ref), 0) < 2 then
      raise exception 'Add the reference for the exemption: the mission''s or diplomat''s accreditation, the zone licence, or the project''s reference.';
    end if;
    if length(v_relief_ref) > 120 then raise exception 'Keep the reference under 120 characters.'; end if;
    if (v_relief is distinct from c.vat_relief or (v_relief is not null and v_relief_ref is distinct from c.vat_relief_ref)) and m.role not in ('owner', 'admin') then
      raise exception 'Only the owner or an admin marks a customer exempt from VAT.' using errcode = '42501';
    end if;
  end if;
  v_id := private.upsert_customer(p_org, p_customer, m);
  if p_customer ? 'vat_relief' then
    if v_relief is not null and (select country from customers where id = v_id) <> 'NG' then
      raise exception 'A customer outside Nigeria buys as an export, which is zero-rated already.';
    end if;
    update customers set vat_relief = v_relief, vat_relief_ref = case when v_relief is not null then v_relief_ref end where id = v_id;
  end if;
  if v_ncd is not null then update customers set ncd_levy = v_ncd where id = v_id; end if;
  if p_customer ? 'wht_rate' then update customers set wht_rate = v_rate where id = v_id; end if;
  if v_agent is not null then update customers set wvat_agent = v_agent where id = v_id; end if;
  if p_customer ? 'lga' then update customers set lga = nullif(trim(p_customer->>'lga'), '') where id = v_id; end if;
  if p_customer ? 'postcode' then update customers set postcode = nullif(trim(p_customer->>'postcode'), '') where id = v_id; end if;
  return v_id;
end $function$;


-- ---------------------------------------------------------------------------
-- 3. Approvals
-- ---------------------------------------------------------------------------
create table public.approvals (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  kind text not null check (kind in ('invoice', 'credit_note', 'refund', 'payout', 'payout_batch', 'recurring')),
  -- director: the director who confirmed the wallets, by link and code; owner: the owner or an admin, in the app.
  approver text not null check (approver in ('director', 'owner')),
  reasons text[] not null check (cardinality(reasons) between 1 and 4 and reasons <@ array['firm', 'discount', 'credit_note', 'vat_relief']),
  -- approved: approved and carried out; failed: approved, but it could not be carried out (error says why).
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled', 'failed')),
  sale_id uuid references public.sales(id) on delete cascade,
  payout_id uuid references public.payouts(id) on delete cascade,
  batch_id uuid references public.payout_batches(id) on delete cascade,
  recurring_id uuid references public.recurring_invoices(id) on delete cascade,
  -- What is carried out once approved, with the arguments it was asked with.
  action text check (action in ('issue_invoice', 'credit_sale', 'return_sale', 'refund_customer')),
  args jsonb not null default '{}' check (jsonb_typeof(args) = 'object'),
  -- What the approver sees.
  summary jsonb not null default '{}' check (jsonb_typeof(summary) = 'object'),
  fingerprint text check (length(fingerprint) <= 64),
  requested_by uuid references public.members(id) on delete set null,
  practice_id uuid references public.practices(id) on delete set null,
  decided_by uuid references public.members(id) on delete set null,
  decided_name text check (length(decided_name) <= 160),
  decided_at timestamptz,
  decided_ip text check (length(decided_ip) <= 64),
  decided_ua text check (length(decided_ua) <= 300),
  note text check (length(note) <= 500),
  result jsonb,
  error text check (length(error) <= 500),
  notified_at timestamptz,
  created_at timestamptz not null default now()
);
create index approvals_org on public.approvals(org_id, created_at desc);
create index approvals_pending on public.approvals(org_id, approver) where status = 'pending';
create unique index approvals_one_invoice on public.approvals(sale_id) where status = 'pending' and kind = 'invoice';
create index approvals_sale on public.approvals(sale_id) where sale_id is not null;
create unique index approvals_one_payout on public.approvals(payout_id) where status = 'pending';
create index approvals_payout on public.approvals(payout_id) where payout_id is not null;
create unique index approvals_one_batch on public.approvals(batch_id) where status = 'pending';
create index approvals_batch on public.approvals(batch_id) where batch_id is not null;
create unique index approvals_one_recurring on public.approvals(recurring_id) where status = 'pending';
create index approvals_recurring on public.approvals(recurring_id) where recurring_id is not null;
create index approvals_requested_by on public.approvals(requested_by) where requested_by is not null;
create index approvals_decided_by on public.approvals(decided_by) where decided_by is not null;
create index approvals_practice on public.approvals(practice_id) where practice_id is not null;
alter table public.approvals enable row level security;
revoke all on public.approvals from anon, authenticated;

-- A link to the director's approvals, and the code that unlocks it. The token is minted as the email goes (only its hash
-- is kept); a right code lets the director decide for 15 minutes.
create table public.approval_links (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  confirmation_id uuid not null references public.practice_director_confirmations(id) on delete cascade,
  token_hash text unique,
  expires_at timestamptz,
  otp_hash text,
  otp_expires timestamptz,
  otp_tries int not null default 0,
  otp_failures int not null default 0,
  locked_at timestamptz,
  sends_day date,
  sends_today int not null default 0,
  verified_at timestamptz,
  opened_at timestamptz,
  created_at timestamptz not null default now()
);
create index approval_links_org on public.approval_links(org_id, created_at desc);
create index approval_links_confirmation on public.approval_links(confirmation_id);
alter table public.approval_links enable row level security;
revoke all on public.approval_links from anon, authenticated;

create or replace function private.activity_exempt() returns text[]
language sql immutable set search_path = public, private as $$
  select array['activity_log', 'messages', 'notifications', 'alert_log', 'usage_events', 'ai_logs', 'shop_hits', 'payment_events', 'org_counters',
    'stock_levels', 'agent_runs', 'guide_progress', 'lookup_failures', 'sso_logins', 'whatsapp_sessions', 'chat_links', 'voice_calls',
    'integration_events', 'prism_callbacks', 'kyc_profiles', 'practice_intakes', 'identity_checks', 'account_recoveries', 'support_cases',
    'approval_links']
$$;
select private.activity_attach('public.approvals');

-- The director who approves for a business a firm runs under full mandate: the latest confirmed director whose code
-- reached them, while the mandate is open. None (all nulls) otherwise.
create or replace function private.org_approver(p_org uuid) returns public.practice_director_confirmations
language sql stable security definer set search_path = public, private as $$
  select d.* from practice_director_confirmations d join practice_clients c on c.id = d.client_id join orgs o on o.id = c.org_id
  where c.org_id = p_org and d.practice_id = c.practice_id and c.status = 'active' and c.mode = 'full' and o.managed_by = c.practice_id
    and d.status = 'confirmed' and (d.approver_email is not null or d.approver_phone is not null)
  order by d.confirmed_at desc nulls last, d.created_at desc
  limit 1
$$;

-- Who must approve what a person is about to do, or null when nobody must. p_kind: invoice, credit_note, refund, payout,
-- payout_batch or recurring. p_ctx for an invoice: {discount_pct, relief_ticked}. Only a person acting for themselves is
-- asked (Martina acting for them included); Counta's own runs (the recurring schedule, integrations) and an approved
-- request being carried out are not.
create or replace function private.approval_route(p_org uuid, m public.members, p_kind text, p_ctx jsonb default '{}') returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_mode text; v_reasons text[] := '{}'; o public.orgs;
begin
  if coalesce(current_setting('counta.approval_replay', true), '') = 'on' then return null; end if;
  if m.id is null or auth.uid() is null or m.user_id is distinct from auth.uid() then return null; end if;
  select * into o from orgs where id = p_org;
  if m.practice_id is not null then
    select pc.mode into v_mode from practice_clients pc
    where pc.org_id = p_org and pc.practice_id = m.practice_id and pc.status = 'active'
    order by pc.created_at desc limit 1;
  end if;
  if v_mode is not null then v_reasons := v_reasons || 'firm'::text; end if;
  if m.role not in ('owner', 'admin') then
    if p_kind = 'credit_note' then v_reasons := v_reasons || 'credit_note'::text; end if;
    if p_kind = 'invoice' and coalesce((p_ctx->>'discount_pct')::numeric, 0) > o.discount_approval_pct + 0.0001 then
      v_reasons := v_reasons || 'discount'::text;
    end if;
    if p_kind = 'invoice' and coalesce((p_ctx->>'relief_ticked')::boolean, false) then v_reasons := v_reasons || 'vat_relief'::text; end if;
  end if;
  if cardinality(v_reasons) = 0 then return null; end if;
  return jsonb_build_object('approver', case when v_mode = 'full' then 'director' else 'owner' end, 'reasons', to_jsonb(v_reasons),
    'practice_id', case when v_mode is not null then m.practice_id end);
end $$;

-- The discounts on a document as a percentage of its value before them (delivery left out).
create or replace function private.sale_discount_pct(p_sale uuid) returns numeric
language sql stable security definer set search_path = public, private as $$
  select case when coalesce(sum(round(qty * unit_price, 2)), 0) > 0 then round(coalesce(sum(discount), 0) * 100 / sum(round(qty * unit_price, 2)), 2) else 0 end
  from sale_lines where sale_id = p_sale and kind <> 'delivery'
$$;

-- What an invoice says, so an approval is carried out only on the invoice that was approved.
create or replace function private.sale_fingerprint(p_sale uuid) returns text
language sql stable security definer set search_path = public, private as $$
  select md5(concat_ws('|', s.customer_id, s.total, s.vat_total, s.discount_total, s.vat_relief, s.vat_relief_ref, s.export, s.issue_date, s.due_date,
    s.delivery_fee, (select string_agg(concat_ws(':', l.kind, l.item_id, l.description, l.qty, l.unit_price, l.discount, l.vat_treatment, l.gross), ';'
      order by l.line_no) from sale_lines l where l.sale_id = s.id)))
  from sales s where s.id = p_sale
$$;

-- An invoice's pending approval is dropped when the invoice changes (it is asked for again when it is issued).
create or replace function private.approval_drop(p_sale uuid, p_note text) returns void
language sql security definer set search_path = public, private as $$
  update approvals set status = 'cancelled', note = left(p_note, 500), decided_at = now()
  where sale_id = p_sale and kind = 'invoice' and status = 'pending'
$$;

-- Carries out an approved request (or tries one): the function the person called, as them.
create or replace function private.approval_call(p_action text, p_args jsonb, m public.members) returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  case p_action
    when 'issue_invoice' then
      return private.issue_invoice_as((p_args->>'p_sale')::uuid, nullif(p_args->>'p_issue_date', '')::date, m);
    when 'credit_sale' then
      return public.credit_sale((p_args->>'p_sale')::uuid, p_args->'p');
    when 'return_sale' then
      return public.return_sale((p_args->>'p_sale')::uuid, p_args->'p_lines', p_args->'p_refund', p_args->>'p_reason',
        coalesce((p_args->>'p_restock')::boolean, true));
    when 'refund_customer' then
      return public.refund_customer((p_args->>'p_org')::uuid, (p_args->>'p_customer')::uuid, (p_args->>'p_amount')::numeric, p_args->>'p_method',
        nullif(p_args->>'p_bank_account', '')::uuid, p_args->>'p_reason');
    else
      raise exception 'Unknown request: %.', p_action;
  end case;
end $$;

-- What the approver sees. p_res: what the trial run answered (a credit note's figures).
create or replace function private.approval_summary(p_org uuid, p_kind text, p_args jsonb, p_target jsonb, p_res jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare s public.sales; po public.payouts; pb public.payout_batches; r public.recurring_invoices; v jsonb; cn jsonb;
begin
  if p_kind = 'invoice' then
    select * into s from sales where id = (p_target->>'sale_id')::uuid;
    return jsonb_build_object('title', 'Invoice ' || s.number || ' to ' || s.customer_name, 'number', s.number, 'customer', s.customer_name,
      'issue_date', s.issue_date, 'due_date', s.due_date, 'total', s.total, 'vat', s.vat_total, 'discount', s.discount_total,
      'discount_pct', private.sale_discount_pct(s.id), 'relief', s.vat_relief, 'relief_ref', s.vat_relief_ref, 'relief_words', private.relief_words(s.vat_relief),
      'export', s.export,
      'lines', (select coalesce(jsonb_agg(jsonb_build_object('description', l.description, 'qty', l.qty, 'unit_price', l.unit_price, 'discount', l.discount,
          'vat', l.vat, 'gross', l.gross, 'vat_treatment', l.vat_treatment) order by l.line_no), '[]'::jsonb)
        from (select * from sale_lines where sale_id = s.id order by line_no limit 50) l));
  elsif p_kind = 'credit_note' then
    select * into s from sales where id = (p_target->>'sale_id')::uuid;
    cn := p_res->'credit_note';
    return jsonb_build_object('title', 'Credit note on ' || s.number || ' for ' || s.customer_name, 'against', s.number, 'customer', s.customer_name,
      'total', cn->'total', 'vat', cn->'vat_total',
      'reason', coalesce(p_args->'p'->>'reason', p_args->>'p_reason'),
      'refund', coalesce(p_args->'p'->'refund', p_args->'p_refund'),
      'returned', p_args ? 'p_lines',
      'lines', (select coalesce(jsonb_agg(jsonb_build_object('description', x->>'description', 'qty', x->'qty', 'vat', x->'vat', 'gross', x->'gross')), '[]'::jsonb)
        from jsonb_array_elements(coalesce(cn->'lines', '[]'::jsonb)) x));
  elsif p_kind = 'refund' then
    return jsonb_build_object('title', 'Refund to ' || (select name from customers where id = (p_args->>'p_customer')::uuid),
      'customer', (select name from customers where id = (p_args->>'p_customer')::uuid), 'amount', (p_args->>'p_amount')::numeric,
      'method', p_args->>'p_method', 'reason', p_args->>'p_reason');
  elsif p_kind = 'payout' then
    select * into po from payouts where id = (p_target->>'payout_id')::uuid;
    return jsonb_build_object('title', 'Payment of ' || private.naira(po.amount) || ' to ' || po.account_name, 'number', po.number, 'amount', po.amount,
      'account_name', po.account_name, 'bank_name', po.bank_name, 'account_number', po.account_number, 'narration', po.narration, 'purpose', po.purpose,
      'vendor', (select name from vendors where id = po.vendor_id), 'customer', (select name from customers where id = po.customer_id));
  elsif p_kind = 'payout_batch' then
    select * into pb from payout_batches where id = (p_target->>'batch_id')::uuid;
    return jsonb_build_object('title', 'Bulk payment ' || pb.number || ': ' || private.naira(pb.total) || ' to ' || pb.row_count || ' account'
        || case when pb.row_count = 1 then '' else 's' end,
      'number', pb.number, 'name', pb.title, 'total', pb.total, 'rows', pb.row_count, 'wht', pb.wht_total, 'fees', pb.fee_estimate,
      'payments', (select coalesce(jsonb_agg(jsonb_build_object('account_name', p.account_name, 'bank_name', p.bank_name, 'account_number', p.account_number,
          'amount', p.amount, 'narration', p.narration) order by p.batch_row), '[]'::jsonb)
        from (select * from payouts where batch_id = pb.id order by batch_row limit 100) p));
  elsif p_kind = 'recurring' then
    select * into r from recurring_invoices where id = (p_target->>'recurring_id')::uuid;
    return jsonb_build_object('title', 'Recurring invoice to ' || (select name from customers where id = r.customer_id),
      'customer', (select name from customers where id = r.customer_id), 'frequency', r.frequency, 'day_of_month', r.day_of_month,
      'start_date', r.start_date, 'end_date', r.end_date, 'auto_send', r.auto_send, 'lines', r.lines,
      'amount_before_vat', (select coalesce(sum(round((x->>'qty')::numeric * (x->>'unit_price')::numeric, 2)), 0) from jsonb_array_elements(r.lines) x
        where not coalesce((x->>'once')::boolean, false)));
  end if;
  return '{}'::jsonb;
end $$;

-- The owners and admins who may approve a request (not the person who asked; nobody from the firm for what the firm asks).
create or replace function private.approval_tell_owners(a public.approvals) returns void
language plpgsql security definer set search_path = public, private as $$
declare x public.members;
begin
  for x in select * from members where org_id = a.org_id and status = 'active' and user_id is not null and role in ('owner', 'admin')
      and id is distinct from a.requested_by and (practice_id is null or not ('firm' = any(a.reasons))) loop
    perform private.notify(a.org_id, x.user_id, 'approval', 'Approve: ' || left(coalesce(a.summary->>'title', 'a request'), 100),
      'Asked by ' || coalesce((select display_name from members where id = a.requested_by), 'a member of the team') || '.', '/approvals', 'approval-' || a.id);
  end loop;
end $$;

-- Sends the director a link to what waits for them, at most every ten minutes unless forced (the firm asking again); the
-- cron job sends whatever came in meanwhile. The link itself is made as the email goes.
create or replace function private.approval_tell_director(p_org uuid, p_force boolean) returns boolean
language plpgsql security definer set search_path = public, private as $$
declare d public.practice_director_confirmations; l public.approval_links;
begin
  if not exists (select 1 from approvals where org_id = p_org and status = 'pending' and approver = 'director') then return false; end if;
  d := private.org_approver(p_org);
  if d.id is null then return false; end if;
  if not p_force and exists (select 1 from approval_links where org_id = p_org and created_at > now() - interval '10 minutes') then return false; end if;
  insert into approval_links (org_id, confirmation_id) values (p_org, d.id) returning * into l;
  update approvals set notified_at = now() where org_id = p_org and status = 'pending' and approver = 'director' and notified_at is null;
  perform private.identity_mail('approval_link', l.id);
  return true;
end $$;

create or replace function private.approval_tick() returns integer
language plpgsql security definer set search_path = public, private as $$
declare v_org uuid; v_n int := 0;
begin
  for v_org in select distinct org_id from approvals where status = 'pending' and approver = 'director' and notified_at is null loop
    if private.approval_tell_director(v_org, false) then v_n := v_n + 1; end if;
  end loop;
  return v_n;
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('counta-approvals', '*/5 * * * *', 'select private.approval_tick()');
  end if;
end $$;

-- Asks for an approval: refused at once when nobody could give it; otherwise the request is tried (and rolled back) so
-- anything that would stop it stops it now, then kept with what the approver sees, replacing one already waiting for the
-- same invoice, payout, bulk payment or schedule. The approver is told.
create or replace function private.approval_request(p_org uuid, m public.members, p_kind text, p_route jsonb, p_action text, p_args jsonb, p_target jsonb)
returns public.approvals
language plpgsql security definer set search_path = public, private as $$
declare a public.approvals; d public.practice_director_confirmations; v_res jsonb; v_reasons text[];
begin
  select array_agg(x) into v_reasons from jsonb_array_elements_text(p_route->'reasons') x;
  if p_route->>'approver' = 'director' then
    d := private.org_approver(p_org);
    if d.id is null then
      raise exception 'The director who confirmed the wallets approves what the firm does in this business, and Counta cannot reach them yet. Ask a director to confirm first, on the client''s Full mandate tab.';
    end if;
  elsif not exists (select 1 from members x where x.org_id = p_org and x.status = 'active' and x.user_id is not null and x.role in ('owner', 'admin')
      and x.id <> m.id and (x.practice_id is null or not ('firm' = any(v_reasons)))) then
    raise exception 'This needs the approval of the owner or an admin, and nobody else in the business can give it yet.';
  end if;
  if p_action is not null then
    begin
      perform set_config('counta.approval_replay', 'on', true);
      v_res := private.approval_call(p_action, p_args, m);
      raise exception using errcode = 'CA001', message = 'tried';
    exception when sqlstate 'CA001' then
      null;
    end;
  end if;
  update approvals set status = 'cancelled', note = 'Asked again.', decided_at = now()
  where status = 'pending' and kind = p_kind and (
    (p_kind = 'invoice' and sale_id = (p_target->>'sale_id')::uuid)
    or payout_id = (p_target->>'payout_id')::uuid or batch_id = (p_target->>'batch_id')::uuid or recurring_id = (p_target->>'recurring_id')::uuid);
  insert into approvals (org_id, kind, approver, reasons, sale_id, payout_id, batch_id, recurring_id, action, args, summary, fingerprint, requested_by,
    practice_id)
  values (p_org, p_kind, p_route->>'approver', v_reasons, nullif(p_target->>'sale_id', '')::uuid, nullif(p_target->>'payout_id', '')::uuid,
    nullif(p_target->>'batch_id', '')::uuid, nullif(p_target->>'recurring_id', '')::uuid, p_action, coalesce(p_args, '{}'::jsonb),
    private.approval_summary(p_org, p_kind, p_args, p_target, v_res) || jsonb_build_object('requested_by_name', m.display_name),
    case when p_kind = 'invoice' then private.sale_fingerprint((p_target->>'sale_id')::uuid) end, m.id, nullif(p_route->>'practice_id', '')::uuid)
  returning * into a;
  if a.approver = 'director' then
    perform private.approval_tell_director(p_org, false);
  else
    perform private.approval_tell_owners(a);
  end if;
  return a;
end $$;

-- An approval as the app shows it. With m: whether that person may decide it.
create or replace function private.approval_json(a public.approvals, m public.members default null) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', a.id, 'org_id', a.org_id, 'kind', a.kind, 'approver', a.approver, 'reasons', to_jsonb(a.reasons), 'status', a.status,
    'sale_id', a.sale_id, 'payout_id', a.payout_id, 'batch_id', a.batch_id, 'recurring_id', a.recurring_id, 'summary', a.summary,
    'requested_by', a.requested_by, 'requested_by_name', (select display_name from members where id = a.requested_by),
    'decided_name', coalesce(a.decided_name, (select display_name from members where id = a.decided_by)), 'decided_at', a.decided_at,
    'note', a.note, 'error', a.error, 'created_at', a.created_at,
    'director_name', case when a.approver = 'director' then (select coalesce(d.matched_name, d.name) from private.org_approver(a.org_id) d) end,
    'can_decide', m.id is not null and a.status = 'pending' and a.approver = 'owner' and m.role in ('owner', 'admin') and m.status = 'active'
      and m.id is distinct from a.requested_by and (m.practice_id is null or not ('firm' = any(a.reasons))))
$$;

-- Carries out an approved request as the person who asked (their place must still be active), then puts back whoever is
-- signed in. p_by: the owner or admin who approved, when it was not the director.
create or replace function private.approval_carry(a public.approvals, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_res jsonb; v_claims text := current_setting('request.jwt.claims', true);
  v_sub text := current_setting('request.jwt.claim.sub', true); v_role text := current_setting('request.jwt.claim.role', true);
begin
  select * into m from members where id = a.requested_by;
  if m.id is null or m.status <> 'active' or m.user_id is null then
    raise exception 'The person who asked is no longer on the team, so it was not carried out.';
  end if;
  perform set_config('counta.approval_replay', 'on', true);
  perform set_config('request.jwt.claim.sub', m.user_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', m.user_id, 'role', 'authenticated', 'aud', 'authenticated', 'aal', 'aal1',
    'via', 'approval')::text, true);
  case a.kind
    when 'invoice' then
      if private.sale_fingerprint(a.sale_id) is distinct from a.fingerprint then
        raise exception 'The invoice changed after it was sent for approval. Send it for approval again.';
      end if;
      v_res := private.approval_call(a.action, a.args, m);
    when 'credit_note', 'refund' then
      v_res := private.approval_call(a.action, a.args, m);
    when 'payout' then
      update payouts set status = 'approved', approved_by = p_by, approved_at = now() where id = a.payout_id and status = 'pending_approval';
      if not found then raise exception 'The payment is no longer waiting for approval.'; end if;
      v_res := jsonb_build_object('payout_id', a.payout_id);
    when 'payout_batch' then
      update payout_batches set approved_by = p_by, approved_at = now() where id = a.batch_id and status = 'pending_approval';
      if not found then raise exception 'The bulk payment is no longer waiting for approval.'; end if;
      update payouts set status = 'approved', approved_by = p_by, approved_at = now() where batch_id = a.batch_id and status = 'pending_approval';
      v_res := jsonb_build_object('batch_id', a.batch_id);
    when 'recurring' then
      update recurring_invoices set approval_state = 'approved', updated_at = now() where id = a.recurring_id and approval_state = 'pending';
      if not found then raise exception 'The recurring invoice is no longer waiting for approval.'; end if;
      v_res := jsonb_build_object('recurring_id', a.recurring_id);
  end case;
  perform set_config('counta.approval_replay', '', true);
  perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
  perform set_config('request.jwt.claim.sub', coalesce(v_sub, ''), true);
  perform set_config('request.jwt.claim.role', coalesce(v_role, ''), true);
  return coalesce(v_res, '{}'::jsonb);
end $$;

-- What a rejected or cancelled request leaves behind: a payout cancelled, a bulk payment cancelled with the bills written
-- for it voided, a schedule paused.
create or replace function private.approval_undo(a public.approvals) returns void
language plpgsql security definer set search_path = public, private as $$
declare m public.members;
begin
  if a.kind = 'payout' then
    update payouts set status = 'cancelled', error = coalesce(a.note, 'Not approved') where id = a.payout_id and status = 'pending_approval';
  elsif a.kind = 'payout_batch' then
    update payout_batches set note = coalesce(a.note, note) where id = a.batch_id;
    update payouts set status = 'cancelled', error = coalesce(a.note, 'Not approved') where batch_id = a.batch_id and status = 'pending_approval';
    select * into m from members where id = a.requested_by;
    if m.id is null then
      select * into m from members where org_id = a.org_id and role in ('owner', 'admin') order by acts_as_owner, created_at limit 1;
    end if;
    perform private.void_bulk_bills(a.batch_id, m);
  elsif a.kind = 'recurring' then
    update recurring_invoices set approval_state = 'rejected', status = case when status = 'active' then 'paused' else status end, updated_at = now()
    where id = a.recurring_id and approval_state = 'pending';
  end if;
end $$;

-- Tells the person who asked how it went.
create or replace function private.approval_tell_requester(a public.approvals) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_user uuid := (select user_id from members where id = a.requested_by); v_title text := left(coalesce(a.summary->>'title', 'Your request'), 90);
begin
  perform private.notify(a.org_id, v_user, 'approval',
    case a.status when 'approved' then 'Approved: ' || v_title when 'rejected' then 'Not approved: ' || v_title
      when 'failed' then 'Approved, but it did not go through: ' || v_title else 'Withdrawn: ' || v_title end,
    case a.status when 'approved' then 'Approved by ' || coalesce(a.decided_name, 'the approver') || '.'
      when 'rejected' then coalesce(a.decided_name, 'The approver') || ': ' || coalesce(a.note, 'no reason given') || '.'
      when 'failed' then coalesce(a.error, 'It could not be carried out.') else coalesce(a.note, '') end,
    '/approvals', 'approval-done-' || a.id);
end $$;

-- Decides a request (the owner or an admin in the app, or the director from their link) and carries it out. A request
-- that could not be carried out is kept as failed, with why.
create or replace function private.approval_settle(p_id uuid, p_approve boolean, p_note text, p_by uuid, p_name text, p_ip text, p_ua text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare a public.approvals; v_res jsonb; v_err text;
begin
  select * into a from approvals where id = p_id for update;
  if a.id is null or a.status <> 'pending' then return jsonb_build_object('id', p_id, 'status', a.status); end if;
  if not coalesce(p_approve, false) then
    update approvals set status = 'rejected', decided_by = p_by, decided_name = left(p_name, 160), decided_at = now(),
      decided_ip = left(nullif(trim(p_ip), ''), 64), decided_ua = left(nullif(p_ua, ''), 300), note = left(nullif(trim(p_note), ''), 500)
    where id = a.id returning * into a;
    perform private.approval_undo(a);
  else
    begin
      v_res := private.approval_carry(a, p_by);
      update approvals set status = 'approved', decided_by = p_by, decided_name = left(p_name, 160), decided_at = now(),
        decided_ip = left(nullif(trim(p_ip), ''), 64), decided_ua = left(nullif(p_ua, ''), 300), note = left(nullif(trim(p_note), ''), 500),
        result = v_res - 'credit_note'
      where id = a.id returning * into a;
    exception when others then
      get stacked diagnostics v_err = message_text;
      update approvals set status = 'failed', decided_by = p_by, decided_name = left(p_name, 160), decided_at = now(),
        decided_ip = left(nullif(trim(p_ip), ''), 64), decided_ua = left(nullif(p_ua, ''), 300), note = left(nullif(trim(p_note), ''), 500),
        error = left(v_err, 500)
      where id = a.id returning * into a;
    end;
  end if;
  perform private.approval_tell_requester(a);
  return jsonb_build_object('id', a.id, 'status', a.status, 'error', a.error);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Approvals in the app: the owner or an admin decides; everyone sees their own
-- ---------------------------------------------------------------------------
-- What waits, and the last 30 days. The owner and admins see everything; others see what they asked for.
create or replace function public.approvals_list(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_all boolean; d public.practice_director_confirmations;
begin
  m := private.require(p_org, null);
  v_all := m.role in ('owner', 'admin');
  d := private.org_approver(p_org);
  return jsonb_build_object(
    'owner_or_admin', v_all,
    'firm', m.practice_id is not null and exists (select 1 from orgs where id = p_org and managed_by = m.practice_id),
    'director', case when d.id is not null and m.practice_id is not null then jsonb_build_object('name', coalesce(d.matched_name, d.name),
        'email', private.mask_email(d.approver_email), 'phone', private.mask_phone(d.approver_phone),
        'last_link', (select max(created_at) from approval_links where org_id = p_org)) end,
    'limit_pct', (select discount_approval_pct from orgs where id = p_org),
    'items', (select coalesce(jsonb_agg(private.approval_json(a, m) order by (a.status = 'pending') desc, a.created_at desc), '[]'::jsonb)
      from (select * from approvals where org_id = p_org and (v_all or requested_by = m.id)
            and (status = 'pending' or created_at > now() - interval '30 days') order by created_at desc limit 200) a));
end $$;

-- The owner or an admin approves or rejects a request (rejecting takes a reason). What the director approves is decided
-- from their link only.
create or replace function public.approval_decide(p_id uuid, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare a public.approvals; m public.members;
begin
  select * into a from approvals where id = p_id;
  if a.id is null then raise exception 'Approval not found.'; end if;
  m := private.require(a.org_id, null);
  if a.approver = 'director' then
    raise exception 'This waits for the director who confirmed the wallets. They approve it from the link Counta sent them.' using errcode = '42501';
  end if;
  if a.status <> 'pending' then raise exception 'This is % already.', case a.status when 'failed' then 'approved' else a.status end; end if;
  if m.role not in ('owner', 'admin') then raise exception 'Only the owner or an admin approves this.' using errcode = '42501'; end if;
  if m.id = a.requested_by then raise exception 'Someone other than the person who asked must approve it.' using errcode = '42501'; end if;
  if 'firm' = any(a.reasons) and m.practice_id is not null then
    raise exception 'Someone outside the firm approves what the firm asks for.' using errcode = '42501';
  end if;
  if p_approve is null then raise exception 'Approve or reject it.'; end if;
  if not p_approve and length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Say why, so the person who asked knows what to change.'; end if;
  perform private.approval_settle(a.id, p_approve, p_note, m.id, m.display_name, null, null);
  select * into a from approvals where id = p_id;
  return private.approval_json(a, m);
end $$;

-- The firm sends the director the link again (at most every ten minutes).
create or replace function public.approvals_remind(p_org uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; d public.practice_director_confirmations;
begin
  m := private.require(p_org, null);
  if m.practice_id is null or not exists (select 1 from orgs where id = p_org and managed_by = m.practice_id) then
    raise exception 'Only the firm that runs the business sends the director the link.' using errcode = '42501';
  end if;
  if not exists (select 1 from approvals where org_id = p_org and status = 'pending' and approver = 'director') then
    raise exception 'Nothing is waiting for the director.';
  end if;
  d := private.org_approver(p_org);
  if d.id is null then raise exception 'Counta cannot reach the director yet. Ask a director to confirm first, on the client''s Full mandate tab.'; end if;
  if exists (select 1 from approval_links where org_id = p_org and created_at > now() - interval '10 minutes') then
    raise exception 'A link went to the director less than ten minutes ago.';
  end if;
  perform private.approval_tell_director(p_org, true);
  return jsonb_build_object('sent', true, 'email', private.mask_email(d.approver_email), 'phone', private.mask_phone(d.approver_phone));
end $$;

-- ---------------------------------------------------------------------------
-- 5. The director's approvals: a link and a code, no login
-- ---------------------------------------------------------------------------
create or replace function private.approval_link_by_token(p_token text) returns public.approval_links
language plpgsql security definer set search_path = public, private as $$
declare l public.approval_links;
begin
  if coalesce(p_token, '') ~ '^ap_[0-9a-f]{48}$' then
    select * into l from approval_links where token_hash = private.sha256_hex(p_token) for update;
  end if;
  return l;
end $$;

-- Why a link cannot be used (null when it can): invalid, expired, closed (the mandate ended, or another director confirms
-- for the business now) or locked.
create or replace function private.approval_link_state(l public.approval_links) returns text
language sql stable security definer set search_path = public, private as $$
  select case when l.id is null then 'invalid'
    when l.expires_at is null or l.expires_at <= now() then 'expired'
    when (select d.id from private.org_approver(l.org_id) d) is distinct from l.confirmation_id then 'closed'
    when l.locked_at is not null or l.otp_failures >= 15 then 'locked' end
$$;

create or replace function private.approval_link_json(l public.approval_links) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('ok', true, 'business', o.name, 'firm', p.name, 'director', coalesce(d.matched_name, d.name),
    'verified', l.verified_at is not null and l.verified_at > now() - interval '15 minutes',
    'code_sent', l.otp_expires is not null and l.otp_expires > now(),
    'sms', private.mask_phone(d.approver_phone), 'email', private.mask_email(d.approver_email),
    'items', (select coalesce(jsonb_agg(private.approval_json(a) - 'can_decide' - 'requested_by' - 'org_id' order by a.created_at), '[]'::jsonb)
      from approvals a where a.org_id = l.org_id and a.status = 'pending' and a.approver = 'director'),
    'done', (select coalesce(jsonb_agg(private.approval_json(a) - 'can_decide' - 'requested_by' - 'org_id' order by a.decided_at desc), '[]'::jsonb)
      from (select * from approvals where org_id = l.org_id and approver = 'director' and status in ('approved', 'rejected', 'failed')
            and decided_at > now() - interval '1 day' order by decided_at desc limit 20) a))
  from orgs o, practice_director_confirmations d, practices p
  where o.id = l.org_id and d.id = l.confirmation_id and p.id = d.practice_id
$$;

create or replace function public.svc_approval_open(p_token text, p_ip text, p_ua text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.approval_links; v_state text;
begin
  l := private.approval_link_by_token(p_token);
  v_state := private.approval_link_state(l);
  if v_state is not null and v_state <> 'locked' then return jsonb_build_object('ok', false, 'reason', v_state); end if;
  update approval_links set opened_at = coalesce(opened_at, now()) where id = l.id returning * into l;
  return private.approval_link_json(l) || jsonb_build_object('locked', v_state = 'locked');
end $$;

-- A code to the director's phone (SMS) and email, five a Lagos day per link.
create or replace function public.svc_approval_code(p_token text, p_ip text, p_ua text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.approval_links; v_state text; r jsonb;
begin
  l := private.approval_link_by_token(p_token);
  v_state := private.approval_link_state(l);
  if v_state is not null then return jsonb_build_object('ok', false, 'reason', v_state); end if;
  r := private.otp_send_ok(l.sends_day, l.sends_today);
  if not (r->>'ok')::boolean then return jsonb_build_object('ok', false, 'reason', r->>'reason'); end if;
  update approval_links set sends_day = (r->>'sends_day')::date, sends_today = (r->>'sends_today')::int where id = l.id;
  perform private.identity_mail('approval_code', l.id);
  return jsonb_build_object('ok', true, 'sends_left', 5 - (r->>'sends_today')::int);
end $$;

-- The code entered: a right one lets the director decide for 15 minutes.
create or replace function public.svc_approval_verify(p_token text, p_code text, p_ip text, p_ua text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.approval_links; v_state text; r jsonb;
begin
  l := private.approval_link_by_token(p_token);
  v_state := private.approval_link_state(l);
  -- The link's own state carries no `locked` (only a code's answer does), so its "expired" is the link's.
  if v_state is not null then return jsonb_build_object('ok', false, 'reason', v_state, 'tries_left', 0); end if;
  r := private.otp_check(l.id, p_code, l.otp_hash, l.otp_expires, l.otp_tries, l.otp_failures, l.locked_at);
  update approval_links set otp_tries = (r->>'otp_tries')::int, otp_failures = (r->>'otp_failures')::int,
    locked_at = case when (r->>'locked')::boolean then coalesce(locked_at, now()) else locked_at end,
    otp_hash = case when (r->>'ok')::boolean then null else otp_hash end,
    verified_at = case when (r->>'ok')::boolean then now() else verified_at end
  where id = l.id returning * into l;
  if not (r->>'ok')::boolean then
    return jsonb_build_object('ok', false, 'reason', r->>'reason', 'tries_left', (r->>'tries_left')::int, 'locked', (r->>'locked')::boolean);
  end if;
  return private.approval_link_json(l);
end $$;

-- The director approves or rejects what waits (p_ids), within 15 minutes of a right code. Rejecting takes a reason.
create or replace function public.svc_approval_decide(p_token text, p_ids uuid[], p_approve boolean, p_note text, p_ip text, p_ua text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.approval_links; v_state text; d public.practice_director_confirmations; v_id uuid; v_out jsonb := '[]'::jsonb;
begin
  l := private.approval_link_by_token(p_token);
  v_state := private.approval_link_state(l);
  if v_state is not null then return jsonb_build_object('ok', false, 'reason', v_state); end if;
  if l.verified_at is null or l.verified_at <= now() - interval '15 minutes' then return jsonb_build_object('ok', false, 'reason', 'not_verified'); end if;
  if p_approve is null then return jsonb_build_object('ok', false, 'reason', 'choose'); end if;
  if not p_approve and length(trim(coalesce(p_note, ''))) < 3 then return jsonb_build_object('ok', false, 'reason', 'note'); end if;
  if length(p_note) > 500 then return jsonb_build_object('ok', false, 'reason', 'note_long'); end if;
  select * into d from practice_director_confirmations where id = l.confirmation_id;
  for v_id in select a.id from approvals a where a.id = any(coalesce(p_ids, '{}')) and a.org_id = l.org_id and a.approver = 'director'
      and a.status = 'pending' order by a.created_at loop
    v_out := v_out || jsonb_build_array(private.approval_settle(v_id, p_approve, p_note, null,
      coalesce(d.matched_name, d.name) || ' (director)', p_ip, p_ua));
  end loop;
  return private.approval_link_json(l) || jsonb_build_object('results', v_out);
end $$;

-- The director's contact: what their code reached when they confirmed the wallets, kept for approvals.
create or replace function private.identity_checks_keep_approver() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if old.status = 'open' and new.status = 'verified' and new.purpose = 'director_confirm' and (old.sms_to is not null or old.email_to is not null) then
    update practice_director_confirmations set approver_email = old.email_to, approver_phone = old.sms_to where id = new.ref_id;
  end if;
  return null;
end $$;
drop trigger if exists identity_checks_keep_approver on public.identity_checks;
create trigger identity_checks_keep_approver after update of status on public.identity_checks
for each row execute function private.identity_checks_keep_approver();

-- One director approves at a time: a new confirmation takes over, and a declined or cancelled one keeps nothing.
create or replace function private.director_approver_one() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.status in ('declined', 'cancelled') then
    new.approver_email := null; new.approver_phone := null;
  elsif new.status = 'confirmed' and old.status is distinct from 'confirmed' then
    update practice_director_confirmations set approver_email = null, approver_phone = null
    where client_id = new.client_id and id <> new.id and (approver_email is not null or approver_phone is not null);
  end if;
  return new;
end $$;
drop trigger if exists director_approver_one on public.practice_director_confirmations;
create trigger director_approver_one before update of status on public.practice_director_confirmations
for each row execute function private.director_approver_one();

-- When a full mandate ends or is handed over, the director's contact is wiped and what waited for them is withdrawn.
create or replace function private.mandate_approvals_end() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare a public.approvals;
begin
  if old.mode = 'full' and old.status = 'active' and not (new.mode = 'full' and new.status = 'active') then
    update practice_director_confirmations set approver_email = null, approver_phone = null
    where client_id = new.id and (approver_email is not null or approver_phone is not null);
    for a in select * from approvals where org_id = new.org_id and status = 'pending' and approver = 'director' for update loop
      update approvals set status = 'cancelled', note = 'The firm''s full mandate ended.', decided_at = now() where id = a.id returning * into a;
      perform private.approval_undo(a);
    end loop;
  end if;
  return null;
end $$;
drop trigger if exists mandate_approvals_end on public.practice_clients;
create trigger mandate_approvals_end after update of status, mode on public.practice_clients
for each row execute function private.mandate_approvals_end();

-- A draft cancelled while it waits is withdrawn from its approver.
create or replace function private.sale_approvals_end() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  update approvals set status = 'cancelled', note = 'The invoice was cancelled.', decided_at = now()
  where sale_id = new.id and kind = 'invoice' and status = 'pending';
  return null;
end $$;
drop trigger if exists sales_approvals_end on public.sales;
create trigger sales_approvals_end after update of status on public.sales
for each row when (new.status in ('void', 'cancelled') and old.status is distinct from new.status)
execute function private.sale_approvals_end();

-- ---------------------------------------------------------------------------
-- 6. Where approvals are asked for
-- ---------------------------------------------------------------------------
-- Issuing an invoice: what needs approval waits for it; anything else is issued now.
create or replace function public.issue_invoice(p_sale uuid, p_issue_date date default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members; v_route jsonb;
begin
  select * into s from sales where id = p_sale for update;
  if not found then raise exception 'Invoice not found.'; end if;
  m := private.require(s.org_id, 'record_sales');
  if s.doc_type = 'invoice' and s.status = 'draft' then
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

CREATE OR REPLACE FUNCTION public.save_sale_doc(p_org uuid, p_doc jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; s public.sales; v_id uuid := nullif(p_doc->>'id', '')::uuid; v_type text := coalesce(nullif(p_doc->>'doc_type', ''), 'invoice');
  c public.customers; o public.orgs;
begin
  m := private.require(p_org, 'record_sales');
  if v_type not in ('invoice', 'quote') then raise exception 'Only invoices and quotes are edited here.'; end if;
  if v_id is null then
    s := private.create_sale(p_org, (p_doc - 'tenders' - 'pay_in_full' - 'retail_only') || jsonb_build_object('doc_type', v_type, 'status', 'draft'), m);
    if p_doc ? 'vat_relief' then s := private.sale_set_relief(s, p_doc->>'vat_relief', p_doc->>'vat_relief_ref', m); end if;
    if v_type = 'invoice' and p_doc->>'status' = 'issue' then
      return public.issue_invoice(s.id, s.issue_date);
    end if;
  else
    select * into s from sales where id = v_id and org_id = p_org for update;
    if not found then raise exception 'Document not found.'; end if;
    if not (s.status = 'draft' or (s.doc_type = 'quote' and s.status = 'open')) then
      raise exception '% is already issued. Void it or raise a credit note instead.', s.number;
    end if;
    if exists (select 1 from einvoice_docs where sale_id = s.id and state in ('waiting', 'sending')) then
      raise exception 'NRS is checking %. Take it back first to change it.', s.number;
    end if;
    select * into o from orgs where id = p_org;
    if nullif(p_doc->>'customer_id', '') is not null and (p_doc->>'customer_id')::uuid <> s.customer_id then
      select * into c from customers where id = (p_doc->>'customer_id')::uuid and org_id = p_org and not archived;
      if not found then raise exception 'Customer not found.'; end if;
      update sales set customer_id = c.id, customer_name = c.name, customer_phone = c.phone, customer_email = c.email, customer_tin = c.tin,
        customer_address = c.address, price_list_id = c.price_list_id where id = s.id;
    end if;
    update sales set issue_date = coalesce(nullif(p_doc->>'issue_date', '')::date, issue_date),
      due_date = coalesce(nullif(p_doc->>'due_date', '')::date, due_date),
      price_list_id = case when p_doc ? 'price_list_id' then (select id from price_lists where id = nullif(p_doc->>'price_list_id', '')::uuid and org_id = p_org)
                           else price_list_id end,
      reference = case when p_doc ? 'reference' then nullif(trim(p_doc->>'reference'), '') else reference end,
      notes = case when p_doc ? 'notes' then nullif(trim(p_doc->>'notes'), '') else notes end,
      terms = case when p_doc ? 'terms' then nullif(trim(p_doc->>'terms'), '') else terms end,
      delivery_fee = case when p_doc ? 'delivery_fee' then round(greatest(coalesce(private.num(p_doc->>'delivery_fee'), 0), 0), 2) else delivery_fee end,
      delivery_address = case when p_doc ? 'delivery_address' then nullif(trim(p_doc->>'delivery_address'), '') else delivery_address end,
      location_id = coalesce((select id from locations where id = nullif(p_doc->>'location_id', '')::uuid and org_id = p_org), location_id),
      prices_include_vat = coalesce((p_doc->>'prices_include_vat')::boolean, prices_include_vat), vat_registered = o.vat_registered
    where id = s.id returning * into s;
    if s.issue_date > private.local_day(p_org, now()) then raise exception 'A document cannot be dated in the future.'; end if;
    if s.due_date < s.issue_date then raise exception 'The due date is before the issue date.'; end if;
    perform private.approval_drop(s.id, 'The invoice was changed after it was sent for approval.');
    if p_doc ? 'vat_relief' then s := private.sale_set_relief(s, p_doc->>'vat_relief', p_doc->>'vat_relief_ref', m, false); end if;
    s := private.write_lines(s, coalesce(p_doc->'lines', private.sale_lines_input(s.id)), private.num(p_doc->>'cart_discount'), m);
    if p_doc->>'status' = 'issue' and s.doc_type = 'invoice' then
      return public.issue_invoice(s.id, null);
    end if;
  end if;
  return private.sale_json(s.id, private.can_see_costs(p_org));
end $function$;


CREATE OR REPLACE FUNCTION public.credit_sale(p_sale uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare s public.sales; m public.members; cn public.sales; l public.sale_lines; x jsonb; v_amt numeric; v_left numeric; v_vat numeric; v_net numeric;
  v_jl jsonb := '[]'::jsonb; v_no int := 0; v_tot numeric := 0; v_vtot numeric := 0; j public.journals; v_lines jsonb; v_pool numeric; v_want numeric;
  v_spread numeric; v_i int := 0; v_n int; v_res jsonb; v_reason text := trim(coalesce(p->>'reason', ''));
  v_route jsonb; a public.approvals;
begin
  select * into s from sales where id = p_sale for update;
  if not found then raise exception 'Sale not found.'; end if;
  m := private.require(s.org_id, 'approve_adjustments');
  if s.doc_type not in ('receipt', 'invoice', 'order') or s.journal_id is null or s.status in ('void', 'cancelled', 'draft') then
    raise exception '% cannot take a credit note.', s.number;
  end if;
  if v_reason = '' then raise exception 'Give the reason for the credit note.'; end if;
  -- Raised by someone other than the owner or an admin, or by the firm that runs the books: it waits for approval.
  v_route := private.approval_route(s.org_id, m, 'credit_note');
  if v_route is not null then
    a := private.approval_request(s.org_id, m, 'credit_note', v_route, 'credit_sale', jsonb_build_object('p_sale', s.id, 'p', p),
      jsonb_build_object('sale_id', s.id));
    return jsonb_build_object('pending_approval', true, 'approval', private.approval_json(a, m));
  end if;
  perform private.require_open_day(s.org_id, private.local_day(s.org_id, now()));
  -- One amount for the whole sale: shared over the lines by what each can still be credited.
  if jsonb_typeof(p->'lines') is distinct from 'array' or jsonb_array_length(p->'lines') = 0 then
    v_want := round(coalesce(private.num(p->>'amount'), 0), 2);
    if v_want <= 0 then raise exception 'Enter the amount to credit.'; end if;
    select coalesce(sum(private.sale_line_creditable(id)), 0), count(*) filter (where private.sale_line_creditable(id) > 0) into v_pool, v_n
    from sale_lines where sale_id = s.id;
    if v_want > v_pool + 0.004 then raise exception 'At most % can still be credited on %.', to_char(v_pool, 'FM999,999,999,990.00'), s.number; end if;
    v_lines := '[]'::jsonb; v_spread := 0;
    for l in select * from sale_lines where sale_id = s.id and private.sale_line_creditable(id) > 0 order by line_no loop
      v_i := v_i + 1;
      v_amt := case when v_i = v_n then v_want - v_spread else round(v_want * private.sale_line_creditable(l.id) / v_pool, 2) end;
      v_spread := v_spread + v_amt;
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('sale_line_id', l.id, 'amount', v_amt));
    end loop;
  else
    v_lines := p->'lines';
  end if;
  insert into sales (org_id, doc_type, number, status, customer_id, customer_name, customer_phone, customer_email, customer_tin, customer_address,
    location_id, channel, issue_date, prices_include_vat, vat_registered, original_sale_id, notes, created_by, issued_at, customer_country, export)
  values (s.org_id, 'credit_note', private.doc_number(s.org_id, 'credit_note'), 'open', s.customer_id, s.customer_name, s.customer_phone, s.customer_email,
    s.customer_tin, s.customer_address, s.location_id, s.channel, private.local_day(s.org_id, now()), s.prices_include_vat, s.vat_registered, s.id,
    v_reason, m.id, now(), s.customer_country, s.export)
  returning * into cn;
  for x in select * from jsonb_array_elements(v_lines) loop
    select * into l from sale_lines where id = nullif(x->>'sale_line_id', '')::uuid and sale_id = s.id for update;
    if not found then raise exception 'A credited line is not on %.', s.number; end if;
    v_amt := round(coalesce(private.num(x->>'amount'), 0), 2);
    continue when v_amt <= 0;
    v_left := private.sale_line_creditable(l.id);
    if v_amt > v_left + 0.004 then raise exception 'Only % can still be credited on %.', to_char(v_left, 'FM999,999,999,990.00'), l.description; end if;
    -- The VAT inside the amount, at the line's own rate; the last kobo follows the line when it is credited in full.
    v_vat := case when l.gross = 0 then 0 when v_amt >= v_left - 0.004 then l.vat - coalesce((select sum(c.vat) from sale_lines c join sales x2 on x2.id = c.sale_id
               where c.original_line_id = l.id and x2.status <> 'void'), 0) else round(v_amt * l.vat / l.gross, 2) end;
    v_net := v_amt - v_vat;
    v_no := v_no + 1;
    insert into sale_lines (sale_id, org_id, line_no, kind, item_id, description, qty, unit_label, unit_factor, unit_price, list_price, discount, vat_treatment,
      vat_rate, net, vat, gross, cost, revenue_account, original_line_id, adjustment, item_vat_treatment)
    values (cn.id, s.org_id, v_no, case when l.kind = 'delivery' then 'delivery' else 'service' end, null, left(l.description || ' · price adjustment', 300), 1, 'adjustment', 1,
      v_amt, null, 0, l.vat_treatment, l.vat_rate, v_net, v_vat, v_amt, 0, l.revenue_account, l.id, true, l.item_vat_treatment);
    v_tot := v_tot + v_amt; v_vtot := v_vtot + v_vat;
    v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', case when l.kind = 'goods' then private.acct(s.org_id, 'sales_returns') else coalesce(l.revenue_account, private.acct(s.org_id, 'sales_revenue')) end,
      'debit', v_net, 'location_id', s.location_id, 'doc_type', 'sale', 'doc_id', cn.id, 'memo', l.description || ' · price adjustment'));
  end loop;
  if v_tot <= 0 then raise exception 'Enter the amount to credit.'; end if;
  v_jl := v_jl || jsonb_build_array(
    jsonb_build_object('code', private.acct(s.org_id, 'output_vat'), 'debit', v_vtot, 'location_id', s.location_id, 'doc_type', 'sale', 'doc_id', cn.id, 'memo', 'VAT on ' || cn.number),
    jsonb_build_object('code', private.acct(s.org_id, 'receivables'), 'credit', v_tot, 'location_id', s.location_id, 'party_type', 'customer',
      'party_id', s.customer_id, 'doc_type', 'sale', 'doc_id', cn.id, 'memo', cn.number || ' for ' || s.number));
  update sales set subtotal = v_tot - v_vtot, vat_total = v_vtot, total = v_tot where id = cn.id;
  j := private.post_entry(s.org_id, 'Credit note ' || cn.number || ' for ' || s.number || ' · ' || v_reason, 'sale', cn.id, m.id, m.id, v_jl, now(),
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'sale', 'id', s.id, 'ref', s.number))));
  update sales set journal_id = j.id where id = cn.id;
  v_res := private.settle_credit_note(cn.id, s.id, coalesce(p->'refund', '{}'::jsonb), m);
  return jsonb_build_object('credit_note', private.sale_json(cn.id, private.can_see_costs(s.org_id))) || v_res;
end $function$;


CREATE OR REPLACE FUNCTION public.return_sale(p_sale uuid, p_lines jsonb, p_refund jsonb, p_reason text, p_restock boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare s public.sales; m public.members; cn public.sales; x jsonb; l public.sale_lines; v_qty numeric; v_jl jsonb := '[]'::jsonb; j public.journals;
  v_net numeric := 0; v_vat numeric := 0; v_gross numeric; v_lnet numeric; v_cost numeric; v_ratio numeric; v_refund numeric; v_due numeric; v_apply numeric;
  v_wac numeric; v_total numeric; v_bank uuid; col public.collections; v_no int := 0; v_whole boolean; v_route jsonb; a public.approvals;
begin
  select * into s from sales where id = p_sale for update;
  if not found then raise exception 'Sale not found.'; end if;
  m := private.require(s.org_id, 'approve_adjustments');
  if s.doc_type not in ('receipt', 'invoice', 'order') or s.journal_id is null or s.status in ('void', 'cancelled') then raise exception '% cannot take a return.', s.number; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Give a reason for the return.'; end if;
  v_route := private.approval_route(s.org_id, m, 'credit_note');
  if v_route is not null then
    a := private.approval_request(s.org_id, m, 'credit_note', v_route, 'return_sale', jsonb_build_object('p_sale', s.id, 'p_lines', p_lines,
      'p_refund', p_refund, 'p_reason', p_reason, 'p_restock', p_restock), jsonb_build_object('sale_id', s.id));
    return jsonb_build_object('pending_approval', true, 'approval', private.approval_json(a, m));
  end if;
  perform private.require_open_day(s.org_id, private.local_day(s.org_id, now()));
  insert into sales (org_id, doc_type, number, status, customer_id, customer_name, customer_phone, customer_email, customer_tin, customer_address,
    location_id, channel, issue_date, prices_include_vat, vat_registered, original_sale_id, notes, created_by, issued_at)
  values (s.org_id, 'credit_note', private.doc_number(s.org_id, 'credit_note'), 'open', s.customer_id, s.customer_name, s.customer_phone, s.customer_email,
    s.customer_tin, s.customer_address, s.location_id, s.channel, private.local_day(s.org_id, now()), s.prices_include_vat, s.vat_registered, s.id,
    trim(p_reason), m.id, now())
  returning * into cn;
  for x in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    select * into l from sale_lines where id = nullif(x->>'sale_line_id', '')::uuid and sale_id = s.id for update;
    if not found then raise exception 'A returned line is not on %.', s.number; end if;
    v_qty := round(private.num(x->>'qty'), 3);
    continue when coalesce(v_qty, 0) <= 0;
    if v_qty > l.qty - l.returned_qty + 0.0005 then raise exception 'Only % of % can still be returned.', private.fmt_qty(l.qty - l.returned_qty), l.description; end if;
    v_ratio := v_qty / l.qty;
    -- The last of a line takes whatever is left, so rounding never leaves a kobo behind.
    v_whole := v_qty >= l.qty - l.returned_qty - 0.0005;
    v_gross := case when v_whole then l.gross - coalesce((select sum(gross) from sale_lines where original_line_id = l.id), 0) else round(l.gross * v_ratio, 2) end;
    v_lnet := case when v_whole then l.net - coalesce((select sum(net) from sale_lines where original_line_id = l.id), 0) else round(l.net * v_ratio, 2) end;
    v_cost := case when not (p_restock and l.item_id is not null) then 0
                   when v_whole then coalesce(l.cost, 0) - coalesce((select sum(cost) from sale_lines where original_line_id = l.id), 0)
                   else round(coalesce(l.cost, 0) * v_ratio, 2) end;
    v_no := v_no + 1;
    insert into sale_lines (sale_id, org_id, line_no, kind, item_id, description, qty, unit_label, unit_factor, unit_price, list_price, discount, vat_treatment,
      vat_rate, net, vat, gross, cost, revenue_account, original_line_id)
    values (cn.id, s.org_id, v_no, l.kind, l.item_id, l.description, v_qty, l.unit_label, l.unit_factor, l.unit_price, l.list_price, round(l.discount * v_ratio, 2),
      l.vat_treatment, l.vat_rate, v_lnet, v_gross - v_lnet, v_gross, v_cost, l.revenue_account, l.id);
    update sale_lines set returned_qty = returned_qty + v_qty where id = l.id;
    v_net := v_net + v_lnet; v_vat := v_vat + (v_gross - v_lnet);
    v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', case when l.kind = 'goods' then private.acct(s.org_id, 'sales_returns') else l.revenue_account end,
      'debit', v_lnet, 'location_id', s.location_id, 'item_id', l.item_id, 'doc_type', 'sale', 'doc_id', cn.id, 'memo', l.description));
    if v_cost <> 0 then
      v_jl := v_jl || jsonb_build_array(
        jsonb_build_object('code', private.inv_acct(l.item_id), 'debit', v_cost, 'location_id', s.location_id, 'item_id', l.item_id, 'doc_type', 'sale', 'doc_id', cn.id),
        jsonb_build_object('code', private.acct(s.org_id, 'inventory_movement'), 'credit', v_cost, 'location_id', s.location_id, 'item_id', l.item_id, 'doc_type', 'sale', 'doc_id', cn.id));
    end if;
  end loop;
  v_total := v_net + v_vat;
  if v_total <= 0 then raise exception 'Choose what is being returned.'; end if;
  v_jl := v_jl || jsonb_build_array(
    jsonb_build_object('code', private.acct(s.org_id, 'output_vat'), 'debit', v_vat, 'location_id', s.location_id, 'doc_type', 'sale', 'doc_id', cn.id, 'memo', 'VAT on ' || cn.number),
    jsonb_build_object('code', private.acct(s.org_id, 'receivables'), 'credit', v_total, 'location_id', s.location_id, 'party_type', 'customer',
      'party_id', s.customer_id, 'doc_type', 'sale', 'doc_id', cn.id, 'memo', cn.number || ' for ' || s.number));
  update sales set subtotal = v_net, vat_total = v_vat, total = v_total where id = cn.id;
  j := private.post_entry(s.org_id, 'Credit note ' || cn.number || ' for ' || s.number || ' · ' || trim(p_reason), 'sale', cn.id, m.id, m.id, v_jl, now(),
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'sale', 'id', s.id, 'ref', s.number))));
  update sales set journal_id = j.id where id = cn.id;
  if p_restock then
    for l in select * from sale_lines where sale_id = cn.id and item_id is not null order by line_no loop
      v_wac := coalesce(l.cost, 0) / (l.qty * l.unit_factor);
      perform private.update_wac(l.item_id, l.qty * l.unit_factor, coalesce(l.cost, 0));
      perform private.add_movement(s.org_id, 'sale_return', l.item_id, s.location_id, l.qty * l.unit_factor, round(v_wac, 4), round(l.gross / (l.qty * l.unit_factor), 2),
        j.id, m.id, 'Return', now(), jsonb_build_object('note', cn.number || ' · ' || trim(p_reason)));
    end loop;
    update movements set sale_id = cn.id where journal_id = j.id;
  end if;
  -- The credit first settles what is still owed on the original sale.
  s := private.refresh_sale(s.id);
  v_due := s.total - s.amount_paid - s.credited;
  v_apply := least(greatest(v_due, 0), v_total);
  if v_apply > 0 then
    insert into credit_allocations (credit_note_id, sale_id, org_id, amount, created_by) values (cn.id, s.id, s.org_id, v_apply, m.id);
    s := private.refresh_sale(s.id);
  end if;
  -- Then a refund in money, if asked; what is left stays with the customer as credit.
  v_refund := least(round(coalesce(private.num(p_refund->>'amount'), 0), 2), v_total - v_apply);
  if v_refund > 0 then
    v_bank := nullif(p_refund->>'bank_account_id', '')::uuid;
    if v_bank is null and coalesce(nullif(p_refund->>'method', ''), 'cash') = 'cash' then v_bank := (private.cash_drawer(s.org_id, s.location_id, m)).id; end if;
    if v_bank is null or not exists (select 1 from bank_accounts where id = v_bank and org_id = s.org_id and active) then
      raise exception 'Choose the account the refund is paid from.';
    end if;
    if coalesce(nullif(p_refund->>'method', ''), 'cash') not in ('cash', 'transfer', 'cheque', 'other') then raise exception 'Unknown refund method.'; end if;
    insert into collections (org_id, number, direction, customer_id, sale_id, amount, method, status, bank_account_id, shift_id, reference, received_at,
      confirmed_by, confirmed_at, note, created_by)
    values (s.org_id, private.pay_no(s.org_id), 'out', s.customer_id, cn.id, v_refund, coalesce(nullif(p_refund->>'method', ''), 'cash'), 'confirmed', v_bank,
      (select id from shifts where cash_account_id = v_bank and status = 'open'), cn.number, now(), m.id, now(), 'Refund for ' || s.number, m.id)
    returning * into col;
    perform private.post_collection(col.id, m);
    insert into credit_allocations (credit_note_id, sale_id, org_id, amount, created_by) values (cn.id, cn.id, s.org_id, v_refund, m.id);
  end if;
  update sales set credited = v_apply + v_refund, status = case when v_apply + v_refund >= v_total - 0.004 then 'paid' else 'open' end where id = cn.id;
  return jsonb_build_object('credit_note', private.sale_json(cn.id, private.can_see_costs(s.org_id)), 'refunded', v_refund, 'applied', v_apply,
    'store_credit', v_total - v_apply - v_refund);
end $function$;


CREATE OR REPLACE FUNCTION public.refund_customer(p_org uuid, p_customer uuid, p_amount numeric, p_method text, p_bank_account uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; c public.customers; v_bal numeric; v_ar numeric; v_adv numeric; v_amt numeric := round(coalesce(p_amount, 0), 2);
  col public.collections; cn record; v_left numeric; v_take numeric; v_bank uuid := p_bank_account; v_route jsonb; a public.approvals;
begin
  m := private.require(p_org, 'approve_adjustments');
  select * into c from customers where id = p_customer and org_id = p_org;
  if not found then raise exception 'Customer not found.'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Give a reason for the refund.'; end if;
  if coalesce(p_method, 'cash') not in ('cash', 'transfer', 'cheque', 'other') then raise exception 'Unknown refund method.'; end if;
  v_route := private.approval_route(p_org, m, 'refund');
  if v_route is not null then
    a := private.approval_request(p_org, m, 'refund', v_route, 'refund_customer', jsonb_build_object('p_org', p_org, 'p_customer', c.id,
      'p_amount', v_amt, 'p_method', coalesce(p_method, 'cash'), 'p_bank_account', p_bank_account, 'p_reason', p_reason), '{}'::jsonb);
    return jsonb_build_object('pending_approval', true, 'approval', private.approval_json(a, m), 'balance', private.customer_balance(p_org, c.id));
  end if;
  v_bal := private.customer_balance(p_org, c.id);
  if v_amt <= 0 or v_amt > -v_bal + 0.004 then
    raise exception '% has % of credit to refund.', c.name, to_char(greatest(-v_bal, 0), 'FM999,999,999,990.00');
  end if;
  if v_bank is null and coalesce(p_method, 'cash') = 'cash' then v_bank := (private.cash_drawer(p_org, coalesce(m.location_id,
      (select id from locations where org_id = p_org order by is_main desc, created_at limit 1)), m)).id; end if;
  if v_bank is null or not exists (select 1 from bank_accounts where id = v_bank and org_id = p_org and active) then
    raise exception 'Choose the account the refund is paid from.';
  end if;
  -- Credit held in receivables (credit notes) goes first, then advances.
  select coalesce(sum(debit - credit), 0) into v_ar from journal_lines where org_id = p_org and party_type = 'customer' and party_id = c.id and account_code in ('1101', '1102');
  v_adv := greatest(v_amt - greatest(-v_ar, 0), 0);
  insert into collections (org_id, number, direction, customer_id, amount, advance_part, method, status, bank_account_id, shift_id, reference, received_at,
    confirmed_by, confirmed_at, note, created_by)
  values (p_org, private.pay_no(p_org), 'out', c.id, v_amt, v_adv, coalesce(p_method, 'cash'), 'confirmed', v_bank,
    (select id from shifts where cash_account_id = v_bank and status = 'open'), 'Refund', now(), m.id, now(), trim(p_reason), m.id)
  returning * into col;
  col := private.post_collection(col.id, m);
  v_left := v_amt - v_adv;
  for cn in select id, total - credited remaining from sales where org_id = p_org and customer_id = c.id and doc_type = 'credit_note' and status = 'open'
      and total - credited > 0 order by created_at for update loop
    exit when v_left <= 0.004;
    v_take := least(v_left, cn.remaining);
    insert into credit_allocations (credit_note_id, sale_id, org_id, amount, created_by) values (cn.id, cn.id, p_org, v_take, m.id)
    on conflict (credit_note_id, sale_id) do update set amount = credit_allocations.amount + excluded.amount;
    update sales set credited = credited + v_take, status = case when credited + v_take >= total - 0.004 then 'paid' else status end where id = cn.id;
    v_left := v_left - v_take;
  end loop;
  return jsonb_build_object('collection', to_jsonb(col), 'balance', private.customer_balance(p_org, c.id));
end $function$;


CREATE OR REPLACE FUNCTION private.create_payout(p_org uuid, p jsonb, p_lines jsonb, m members)
 RETURNS payouts
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare o public.orgs; w public.wallets; po public.payouts; v_amt numeric := round(private.num(p->>'amount'), 2); v_status text; v_inflight numeric;
  v_batch uuid := nullif(current_setting('counta.payout_batch', true), '')::uuid; v_row jsonb := nullif(current_setting('counta.payout_row', true), '')::jsonb;
  pb public.payout_batches; v_route jsonb;
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
    -- Paid by the firm that runs the books, it waits for the director or the owner (approvals); over the business's limit,
    -- for someone who approves payments.
    v_route := private.approval_route(p_org, m, 'payout');
    v_status := case when v_route is not null or (o.payout_approval_threshold > 0 and v_amt >= o.payout_approval_threshold and not private.perm_of(m, 'owner'))
      then 'pending_approval' else 'approved' end;
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
  if v_route is not null then
    perform private.approval_request(p_org, m, 'payout', v_route, null, '{}'::jsonb, jsonb_build_object('payout_id', po.id));
  elsif v_status = 'pending_approval' and pb.id is null then
    perform private.notify_perm(p_org, 'approve_payments', 'payout', 'Approve a payout of ₦' || to_char(v_amt, 'FM999,999,999,990.00'),
      po.account_name || ' · ' || po.narration || ' · asked by ' || coalesce(m.display_name, ''), '/payments', 'payout-' || po.id, m.id);
  end if;
  return po;
end $function$;


CREATE OR REPLACE FUNCTION public.approve_payout(p_payout uuid, p_approve boolean, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare po public.payouts; m public.members; a public.approvals;
begin
  select * into po from payouts where id = p_payout for update;
  if not found then raise exception 'Payout not found.'; end if;
  -- One the firm asked for is decided in approvals.
  select * into a from approvals where payout_id = po.id and status = 'pending';
  if a.id is not null then
    perform public.approval_decide(a.id, p_approve, p_note);
    select * into po from payouts where id = p_payout;
    return to_jsonb(po);
  end if;
  m := private.require(po.org_id, 'approve_payments');
  if po.batch_id is not null then
    raise exception 'Approve % with its bulk payment %.', po.number, (select number from payout_batches where id = po.batch_id);
  end if;
  if po.status <> 'pending_approval' then raise exception '% is %.', po.number, replace(po.status, '_', ' '); end if;
  if po.requested_by = m.id and not private.perm_of(m, 'owner') then raise exception 'Someone other than the person who asked must approve it.'; end if;
  update payouts set status = case when p_approve then 'approved' else 'cancelled' end, approved_by = m.id, approved_at = now(),
    error = case when not p_approve then nullif(trim(p_note), '') else error end
  where id = po.id returning * into po;
  return to_jsonb(po);
end $function$;


CREATE OR REPLACE FUNCTION public.cancel_payout(p_payout uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare po public.payouts; m public.members;
begin
  select * into po from payouts where id = p_payout for update;
  if not found then raise exception 'Payout not found.'; end if;
  m := private.require(po.org_id, 'make_payments');
  if po.status not in ('pending_approval', 'approved') then raise exception '% is %.', po.number, po.status; end if;
  update payouts set status = 'cancelled' where id = po.id returning * into po;
  update approvals set status = 'cancelled', note = 'Cancelled by ' || coalesce(m.display_name, 'a user') || '.', decided_at = now()
  where payout_id = po.id and status = 'pending';
  return to_jsonb(po);
end $function$;


CREATE OR REPLACE FUNCTION public.create_payout_batch(p_org uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; o public.orgs; c jsonb; pb public.payout_batches; r jsonb; v_src jsonb; v_status text; v_title text; v_first text;
  v_vid uuid; b public.bills; k jsonb; v_route jsonb;
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
  v_route := private.approval_route(p_org, m, 'payout_batch');
  v_status := case when v_route is not null or (c->>'needs_approval')::boolean then 'pending_approval' else 'approved' end;
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
    if r->>'kind' = 'contractor' then
      -- The contractor (added when new, gaps filled when on file) and its bill, written and approved, then paid like any bill.
      k := r->'contractor';
      v_vid := nullif(k->>'vendor_id', '')::uuid;
      if v_vid is null then
        insert into vendors (org_id, name, entity_type, is_individual, tin, tin_status, tin_checked_at, address, state, bank_code, bank_name, account_number,
          account_name, wht_category, channel, resident, default_account)
        values (p_org, k->>'name', k->>'type', k->>'type' = 'individual', k->>'tin', k->>'tin_status', case when k->>'tin_status' is not null then now() end,
          k->>'address', k->>'state', v_src->>'bank_code', v_src->>'bank_name', v_src->>'account_number', v_src->>'account_name', k->>'work', 'email', true,
          r->>'account')
        returning id into v_vid;
      else
        update vendors set
          tin_status = case when k->>'tin_status' = 'verified' and coalesce(tin_status, '') not in ('verified', 'confirmed')
                              and coalesce(private.clean_tax_id(tin), k->>'tin') = k->>'tin' then 'verified' else tin_status end,
          tin_checked_at = case when k->>'tin_status' = 'verified' and coalesce(tin_status, '') not in ('verified', 'confirmed')
                              and coalesce(private.clean_tax_id(tin), k->>'tin') = k->>'tin' then now() else tin_checked_at end,
          tin = coalesce(nullif(trim(tin), ''), k->>'tin'),
          address = coalesce(nullif(trim(address), ''), k->>'address'), state = coalesce(nullif(trim(state), ''), k->>'state'),
          entity_type = coalesce(entity_type, k->>'type'), is_individual = coalesce(is_individual, k->>'type' = 'individual'),
          bank_code = coalesce(bank_code, v_src->>'bank_code'), bank_name = coalesce(bank_name, v_src->>'bank_name'),
          account_name = case when account_number is null then v_src->>'account_name' else account_name end, account_number = coalesce(account_number, v_src->>'account_number')
        where id = v_vid;
      end if;
      b := private.write_bill(p_org, jsonb_build_object('vendor_id', v_vid, 'vendor_ref', nullif(trim(v_src->>'reference'), ''), 'source', 'bulk', 'external_ref', pb.id::text || ':' || (r->>'row'),
        'vat_charged', false, 'wht_category', k->>'work', 'notes', 'Written for bulk payment ' || pb.number || ' · ' || pb.title,
        'lines', jsonb_build_array(jsonb_build_object('description', coalesce(nullif(trim(v_src->>'narration'), ''), v_title), 'account_code', r->>'account',
          'qty', 1, 'unit_cost', (r->>'gross')::numeric))), m);
      -- What the check showed is what is paid: a bill whose withholding tax works out differently stops the batch.
      if abs(b.wht_expected - coalesce((r->>'wht')::numeric, 0)) > 0.01 then
        raise exception 'Row %: the withholding tax on % now works out at ₦%, not ₦%. Check the file again.', r->>'row', (select name from vendors where id = v_vid),
          to_char(b.wht_expected, 'FM999,999,999,990.00'), to_char(coalesce((r->>'wht')::numeric, 0), 'FM999,999,999,990.00');
      end if;
      b := private.post_bill(b.id, m);
      perform public.pay_bill(b.id, jsonb_build_object('method', 'wallet', 'amount', (r->>'gross')::numeric,
        'bank_code', v_src->>'bank_code', 'bank_name', v_src->>'bank_name', 'account_number', v_src->>'account_number', 'account_name', v_src->>'account_name',
        'narration', nullif(trim(v_src->>'narration'), '')));
    elsif r->>'kind' = 'bill' then
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
  if v_route is not null then
    perform private.approval_request(p_org, m, 'payout_batch', v_route, null, '{}'::jsonb, jsonb_build_object('batch_id', pb.id));
  elsif v_status = 'pending_approval' then
    perform private.notify_perm(p_org, 'approve_payments', 'payout',
      'Approve a bulk payment of ₦' || to_char(pb.total, 'FM999,999,999,990.00') || ' to ' || pb.row_count || ' account' || case when pb.row_count = 1 then '' else 's' end,
      pb.number || ' · ' || pb.title || ' · asked by ' || coalesce(m.display_name, ''), '/payments?tab=bulk&batch=' || pb.id, 'batch-' || pb.id, m.id);
  end if;
  return private.batch_json(pb.id);
end $function$;


CREATE OR REPLACE FUNCTION public.approve_payout_batch(p_batch uuid, p_approve boolean, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare pb public.payout_batches; m public.members; a public.approvals;
begin
  select * into pb from payout_batches where id = p_batch for update;
  if not found then raise exception 'Bulk payment not found.'; end if;
  select * into a from approvals where batch_id = pb.id and status = 'pending';
  if a.id is not null then
    perform public.approval_decide(a.id, p_approve, p_note);
    return private.batch_json(pb.id);
  end if;
  m := private.require(pb.org_id, 'approve_payments');
  if pb.status <> 'pending_approval' then raise exception '% is %.', pb.number, replace(pb.status, '_', ' '); end if;
  if pb.requested_by = m.id and not private.perm_of(m, 'owner') then raise exception 'Someone other than the person who asked must approve it.'; end if;
  update payout_batches set approved_by = m.id, approved_at = now(), note = case when not p_approve then nullif(trim(p_note), '') else note end where id = pb.id;
  update payouts set status = case when p_approve then 'approved' else 'cancelled' end, approved_by = m.id, approved_at = now(),
    error = case when not p_approve then coalesce(nullif(trim(p_note), ''), 'Not approved') else error end
  where batch_id = pb.id and status = 'pending_approval';
  if not p_approve then perform private.void_bulk_bills(pb.id, m); end if;
  return private.batch_json(pb.id);
end $function$;


CREATE OR REPLACE FUNCTION public.cancel_payout_batch(p_batch uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare pb public.payout_batches; m public.members; v_n int;
begin
  select * into pb from payout_batches where id = p_batch for update;
  if not found then raise exception 'Bulk payment not found.'; end if;
  m := private.require(pb.org_id, 'make_payments');
  if pb.status not in ('pending_approval', 'approved', 'sending') then raise exception '% is %.', pb.number, replace(pb.status, '_', ' '); end if;
  update payouts set status = 'cancelled', error = coalesce(error, 'Cancelled by ' || coalesce(m.display_name, 'a user'))
  where batch_id = pb.id and status in ('pending_approval', 'approved');
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'Nothing is left to cancel: the rest of % has gone to the bank.', pb.number; end if;
  perform private.void_bulk_bills(pb.id, m);
  update approvals set status = 'cancelled', note = 'Cancelled by ' || coalesce(m.display_name, 'a user') || '.', decided_at = now()
  where batch_id = pb.id and status = 'pending';
  return private.batch_json(pb.id);
end $function$;


CREATE OR REPLACE FUNCTION public.recurring_save(p_org uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
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
    if v_issued and exists (select 1 from jsonb_array_elements(v_lines) l where (l->>'once')::boolean and not r.lines @> jsonb_build_array(l)) then
      raise exception 'This schedule has already issued an invoice, so a new line marked once would never be billed. Bill it on an invoice of its own.';
    end if;
  end if;
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
end $function$;


CREATE OR REPLACE FUNCTION public.recurring_run_now(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare r public.recurring_invoices; m public.members; x public.recurring_invoice_runs; v_today date; v_run date; v_sale uuid; v_next date;
begin
  select * into r from recurring_invoices where id = p_id for update;
  if r.id is null then raise exception 'Recurring invoice not found.'; end if;
  m := private.require(r.org_id, 'record_sales');
  if r.status = 'ended' then raise exception 'This schedule has ended.'; end if;
  if r.approval_state = 'pending' then raise exception 'This schedule is waiting for approval. It runs once it is approved.'; end if;
  if r.approval_state = 'rejected' then raise exception 'This schedule was not approved. Change it and save it to ask again.'; end if;
  v_today := private.local_day(r.org_id, now());
  v_run := least(r.next_run, v_today);
  v_sale := private.recurring_run(r.id, v_run, m);
  perform private.set_actor(null);
  if v_sale is null then raise exception 'This schedule already has an invoice dated %.', to_char(v_run, 'DD Mon YYYY'); end if;
  v_next := private.recurring_next(r.frequency, r.day_of_month, r.next_run);
  while v_next <= v_today loop
    v_next := private.recurring_next(r.frequency, r.day_of_month, v_next);
  end loop;
  update recurring_invoices set next_run = v_next, failures = 0, last_error = null,
    status = case when end_date is not null and v_next > end_date then 'ended' else status end, updated_at = now()
  where id = r.id;
  select * into x from recurring_invoice_runs where schedule_id = r.id and run_date = v_run;
  return jsonb_build_object('sale_id', v_sale, 'number', (select number from sales where id = v_sale), 'status', x.status, 'send_error', x.send_error,
    'schedule', private.recurring_json(r.id));
end $function$;


CREATE OR REPLACE FUNCTION public.recurring_set_status(p_id uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare r public.recurring_invoices; v_today date; v_next date;
begin
  select * into r from recurring_invoices where id = p_id for update;
  if r.id is null then raise exception 'Recurring invoice not found.'; end if;
  perform private.require(r.org_id, 'record_sales');
  if p_status is null or p_status not in ('active', 'paused', 'ended') then raise exception 'Choose active, paused or ended.'; end if;
  if p_status = 'active' and r.approval_state = 'rejected' then
    raise exception 'This schedule was not approved. Change it and save it to ask again.';
  end if;
  if p_status = 'active' then
    v_today := private.local_day(r.org_id, now());
    v_next := r.next_run;
    while v_next < v_today loop
      v_next := private.recurring_next(r.frequency, r.day_of_month, v_next);
    end loop;
    if r.end_date is not null and v_next > r.end_date then
      raise exception 'No invoice date falls before the end date: the next would be %. Change the end date first.', to_char(v_next, 'DD Mon YYYY');
    end if;
    update recurring_invoices set status = 'active', next_run = v_next, failures = 0, last_error = null, updated_at = now() where id = r.id;
  else
    update recurring_invoices set status = p_status, updated_at = now() where id = r.id;
  end if;
  return private.recurring_json(r.id);
end $function$;


CREATE OR REPLACE FUNCTION private.recurring_tick(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare r public.recurring_invoices; x record; m public.members; v_today date; v_next date; v_sale uuid; v_status text; v_err text;
  v_issued int := 0; v_sent int := 0; v_failed int := 0;
begin
  for r in
    select ri.* from recurring_invoices ri join orgs o on o.id = ri.org_id
    where ri.status = 'active' and o.read_only_at is null and coalesce(ri.approval_state, 'approved') = 'approved'
      -- No business's day is more than one day ahead of UTC's (the index's bound); then its own day.
      and ri.next_run <= (p_now at time zone 'UTC')::date + 1
      and ri.next_run <= private.local_day(ri.org_id, p_now)
    order by ri.next_run, ri.created_at, ri.id
    for update of ri skip locked
  loop
    perform private.set_actor(null);
    v_today := private.local_day(r.org_id, p_now);
    begin
      if r.end_date is not null and r.next_run > r.end_date then
        update recurring_invoices set status = 'ended', updated_at = now() where id = r.id;
      else
        v_sale := private.recurring_run(r.id, r.next_run);
        if v_sale is not null then
          v_issued := v_issued + 1;
          select status into v_status from recurring_invoice_runs where schedule_id = r.id and run_date = r.next_run;
          if v_status = 'sent' then v_sent := v_sent + 1; end if;
        end if;
        v_next := r.next_run;
        while v_next <= v_today loop
          v_next := private.recurring_next(r.frequency, r.day_of_month, v_next);
        end loop;
        update recurring_invoices set next_run = v_next, failures = 0, last_error = null,
          status = case when end_date is not null and v_next > end_date then 'ended' else status end, updated_at = now()
        where id = r.id;
      end if;
    exception when others then
      get stacked diagnostics v_err = message_text;
      v_err := left(v_err, 500);
      update recurring_invoices set failures = failures + 1, last_error = v_err,
        status = case when failures + 1 >= 3 then 'paused' else status end, updated_at = now()
      where id = r.id;
      insert into recurring_invoice_runs (schedule_id, run_date, status, error) values (r.id, r.next_run, 'failed', v_err)
      on conflict (schedule_id, run_date) do update set error = excluded.error where recurring_invoice_runs.status = 'failed';
      v_failed := v_failed + 1;
    end;
    perform private.set_actor(null);
  end loop;

  -- Held invoices the schedule no longer sends: deleted; voided, cancelled or credited in full; or still a draft that NRS
  -- refused or that was taken back to change (the person issues it again, and sends it, themselves).
  update recurring_invoice_runs ru set status = 'void',
    error = case when w.sale_id is null then 'The invoice was deleted.'
                 when w.sale_status = 'credited' then 'The invoice was credited in full, so it is not sent.'
                 when w.sale_status <> 'draft' then 'The invoice was voided, so it is not sent.'
                 when w.einvoice_state = 'refused' then 'NRS refused the invoice, so it is not sent automatically. Put it right, issue it again and send it yourself.'
                 else 'The invoice was taken back to change, so it is not sent automatically. Issue it again and send it yourself.' end
  from (select h.id, h.sale_id, s.status as sale_status, d.state as einvoice_state
        from recurring_invoice_runs h
        left join sales s on s.id = h.sale_id
        left join einvoice_docs d on d.sale_id = h.sale_id
        where h.status = 'waiting_nrs'
          and (s.id is null or s.status in ('void', 'cancelled', 'credited', 'converted', 'expired')
               or (s.status = 'draft' and d.state in ('refused', 'stopped')))
        for update of h skip locked) w
  where ru.id = w.id;

  for x in
    select ru.id, ru.sale_id, ri.org_id, ri.created_by, ri.auto_send, ri.send_channel
    from recurring_invoice_runs ru
    join recurring_invoices ri on ri.id = ru.schedule_id
    join sales s on s.id = ru.sale_id
    join orgs o on o.id = ri.org_id
    where ru.status = 'waiting_nrs' and ri.status <> 'paused' and o.read_only_at is null and s.status in ('open', 'partially_paid', 'paid')
    order by ru.created_at, ru.id
    for update of ru skip locked
  loop
    perform private.set_actor(null);
    begin
      if x.auto_send then
        m := private.recurring_actor(x.org_id, x.created_by);
        perform private.set_actor(m.user_id);
        v_err := private.recurring_send(x.sale_id, x.send_channel, m);
        update recurring_invoice_runs set status = case when v_err is null then 'sent' else 'issued' end, send_error = v_err where id = x.id;
        if v_err is null then v_sent := v_sent + 1; else v_failed := v_failed + 1; end if;
      else
        update recurring_invoice_runs set status = 'issued' where id = x.id;
      end if;
    exception when others then
      get stacked diagnostics v_err = message_text;
      update recurring_invoice_runs set status = 'issued', send_error = left(v_err, 500) where id = x.id;
      v_failed := v_failed + 1;
    end;
    perform private.set_actor(null);
  end loop;
  return jsonb_build_object('issued', v_issued, 'sent', v_sent, 'failed', v_failed);
end $function$;


-- ---------------------------------------------------------------------------
-- 7. What the app reads
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.sale_json(p_sale uuid, p_cost boolean)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select to_jsonb(s) || jsonb_build_object(
    'cost_total', case when p_cost then (select sum(cost) from sale_lines where sale_id = s.id) end,
    'balance', case when s.doc_type in ('receipt', 'invoice', 'order') and s.status not in ('void', 'draft', 'converted', 'cancelled') then s.total - s.amount_paid - s.credited
                    when s.doc_type = 'credit_note' then s.total - s.credited else 0 end,
    'pending', (select coalesce(sum(a.amount), 0) from collection_allocations a join collections c on c.id = a.collection_id where a.sale_id = s.id and c.status = 'pending'),
    'confirmed', s.journal_id is not null,
    'location_name', (select name from locations where id = s.location_id),
    'created_by_name', (select display_name from members where id = s.created_by),
    'overdue_days', case when s.status in ('open', 'partially_paid') and s.due_date is not null then greatest(private.local_day(s.org_id, now()) - s.due_date, 0) end,
    'org', private.org_brand(s.org_id, s.customer_id),
    'customer', (select jsonb_build_object('city', c.city, 'state', c.state, 'country', c.country, 'contact_person', c.contact_person)
      from customers c where c.id = s.customer_id),
    'vat_statuses', (select coalesce(jsonb_agg(distinct l.vat_status), '[]'::jsonb) from sale_lines l where l.sale_id = s.id),
    'lines', (select coalesce(jsonb_agg(to_jsonb(l) - 'cost' - 'org_id' || jsonb_build_object('cost', case when p_cost then l.cost end) order by l.line_no), '[]'::jsonb)
              from sale_lines l where l.sale_id = s.id),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'number', c.number, 'method', c.method, 'status', c.status, 'direction', c.direction,
        'amount', a.amount, 'collection_amount', c.amount, 'fee', c.fee, 'received_at', c.received_at, 'reference', c.reference, 'bank_account_id', c.bank_account_id,
        'confirmed_by_name', (select display_name from members where id = c.confirmed_by)) order by c.received_at), '[]'::jsonb)
      from collection_allocations a join collections c on c.id = a.collection_id where a.sale_id = s.id),
    'refunds', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'number', c.number, 'method', c.method, 'amount', c.amount, 'received_at', c.received_at)), '[]'::jsonb)
      from collections c where c.sale_id = s.id and c.direction = 'out'),
    'credits', (select coalesce(jsonb_agg(jsonb_build_object('credit_note_id', ca.credit_note_id, 'number', cn.number, 'amount', ca.amount)), '[]'::jsonb)
      from credit_allocations ca join sales cn on cn.id = ca.credit_note_id where ca.sale_id = s.id and ca.credit_note_id <> s.id),
    'applied_to', (select coalesce(jsonb_agg(jsonb_build_object('sale_id', ca.sale_id, 'number', x.number, 'amount', ca.amount)), '[]'::jsonb)
      from credit_allocations ca join sales x on x.id = ca.sale_id where ca.credit_note_id = s.id and ca.sale_id <> s.id),
    'credit_notes', (select coalesce(jsonb_agg(jsonb_build_object('id', cn.id, 'number', cn.number, 'total', cn.total, 'status', cn.status)), '[]'::jsonb)
      from sales cn where cn.original_sale_id = s.id and cn.doc_type = 'credit_note'),
    'original_number', (select number from sales where id = s.original_sale_id),
    'relief_words', private.relief_words(s.vat_relief),
    'relief_by_name', (select display_name from members where id = s.vat_relief_by),
    'approvals', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'kind', a.kind, 'status', a.status, 'approver', a.approver,
        'reasons', to_jsonb(a.reasons), 'title', a.summary->>'title', 'note', a.note, 'error', a.error, 'decided_name', a.decided_name,
        'decided_at', a.decided_at, 'created_at', a.created_at, 'requested_by_name', (select display_name from members where id = a.requested_by))
        order by a.created_at desc), '[]'::jsonb)
      from (select * from approvals where sale_id = s.id order by created_at desc limit 10) a),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'method', r.method, 'status', r.status, 'amount', r.amount, 'account_number', r.account_number,
        'bank_name', r.bank_name, 'account_name', r.account_name, 'link_url', r.link_url, 'expires_at', r.expires_at, 'tx_ref', r.tx_ref,
        'direct', r.direct, 'pay_ref', r.pay_ref) order by r.created_at desc), '[]'::jsonb)
      from payment_requests r where r.sale_id = s.id),
    'deliveries', (select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at), '[]'::jsonb) from deliveries d where d.sale_id = s.id),
    'journal_ref', (select ref from journals where id = s.journal_id),
    'customer_credit', case when s.doc_type in ('receipt', 'invoice', 'order') and not (select is_walk_in from customers where id = s.customer_id) then
        (select coalesce(sum(total - credited), 0) from sales cn where cn.customer_id = s.customer_id and cn.doc_type = 'credit_note' and cn.status = 'open')
        + greatest(private.customer_advance(s.org_id, s.customer_id), 0) end,
    'einvoice', (select jsonb_build_object('irn', e.irn, 'kind', e.kind, 'state', e.state, 'held', e.held, 'qr', e.qr, 'note', e.note, 'signed_at', e.signed_at,
        'tries', e.tries, 'next_try_at', e.next_try_at, 'pay_status', e.pay_status, 'platform_keys', e.platform_keys,
        'buyer', case when e.xm_state is null then null else jsonb_build_object('state', e.xm_state, 'note', e.xm_note, 'at', e.xm_at, 'sent_at', e.xm_sent_at,
          'tries', e.xm_tries, 'next_at', e.xm_next_at) end)
      from einvoice_docs e where e.sale_id = s.id))
  from sales s where s.id = p_sale
$function$;


CREATE OR REPLACE FUNCTION private.recurring_json(p_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select jsonb_build_object('id', r.id, 'org_id', r.org_id, 'customer_id', r.customer_id, 'customer_name', c.name, 'status', r.status,
    'frequency', r.frequency, 'day_of_month', r.day_of_month, 'start_date', r.start_date, 'end_date', r.end_date, 'next_run', r.next_run,
    'due_days', r.due_days, 'lines', r.lines, 'auto_send', r.auto_send, 'send_channel', r.send_channel, 'notes', r.notes,
    'practice_client_id', r.practice_client_id, 'failures', r.failures, 'last_error', r.last_error, 'last_run_at', r.last_run_at,
    'created_by', r.created_by, 'created_by_name', cm.display_name, 'created_at', r.created_at, 'updated_at', r.updated_at,
    'approval_state', coalesce(r.approval_state, 'approved'),
    'approval', (select jsonb_build_object('id', a.id, 'status', a.status, 'approver', a.approver, 'note', a.note,
        'decided_name', a.decided_name, 'decided_at', a.decided_at, 'created_at', a.created_at)
      from approvals a where a.recurring_id = r.id order by a.created_at desc limit 1),
    'runs', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.id, 'run_date', x.run_date, 'status', x.status, 'sale_id', x.sale_id, 'number', s.number,
          'total', s.total, 'error', x.error, 'send_error', x.send_error, 'created_at', x.created_at) order by x.run_date desc)
      from (select * from recurring_invoice_runs where schedule_id = r.id order by run_date desc limit 12) x
      left join sales s on s.id = x.sale_id), '[]'::jsonb))
  from recurring_invoices r
  join customers c on c.id = r.customer_id
  left join members cm on cm.id = r.created_by
  where r.id = p_id
$function$;


CREATE OR REPLACE FUNCTION private.batch_json(p_batch uuid, p_rows boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select to_jsonb(b) || jsonb_build_object(
    'requested_by_name', (select display_name from members where id = b.requested_by),
    'approved_by_name', (select display_name from members where id = b.approved_by),
    'sent_by_name', (select display_name from members where id = b.sent_by),
    'pending_count', (select count(*) from payouts where batch_id = b.id and status = 'pending_approval'),
    'approved_count', (select count(*) from payouts where batch_id = b.id and status = 'approved'),
    'processing_count', (select count(*) from payouts where batch_id = b.id and status = 'processing'),
    'approval', (select jsonb_build_object('id', a.id, 'status', a.status, 'approver', a.approver, 'reasons', to_jsonb(a.reasons), 'note', a.note,
        'decided_name', a.decided_name, 'decided_at', a.decided_at)
      from approvals a where a.batch_id = b.id order by a.created_at desc limit 1),
    'rows', case when p_rows then (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'row', p.batch_row, 'number', p.number, 'reference', p.reference,
        'your_reference', p.your_reference, 'account_name', p.account_name, 'bank_name', p.bank_name, 'bank_code', p.bank_code, 'account_number', p.account_number,
        'amount', p.amount, 'fee', p.fee, 'narration', p.narration, 'purpose', p.purpose, 'status', p.status, 'error', p.error, 'sent_at', p.sent_at,
        'completed_at', p.completed_at, 'provider_ref', p.provider_ref, 'journal_ref', (select ref from journals where id = p.journal_id),
        'bill_number', bp.number, 'wht', bp.wht, 'gross', bp.gross, 'vendor_name', (select name from vendors where id = p.vendor_id),
        'account_code', case when p.vendor_id is null then p.lines->0->>'code' end,
        'account_label', case when p.vendor_id is null and p.lines->0->>'code' is not null then private.account_name(p.org_id, p.lines->0->>'code') end)
      order by p.batch_row, p.created_at), '[]'::jsonb)
      from payouts p
      left join lateral (select b2.number, x.wht, x.gross from bill_payments x join bills b2 on b2.id = x.bill_id where x.payout_id = p.id limit 1) bp on true
      where p.batch_id = b.id) end)
  from payout_batches b where b.id = p_batch
$function$;


CREATE OR REPLACE FUNCTION public.get_payout_batch(p_batch uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare pb public.payout_batches; m public.members; a public.approvals;
begin
  select * into pb from payout_batches where id = p_batch;
  if not found then raise exception 'Bulk payment not found.'; end if;
  m := private.require(pb.org_id, null);
  if not private.can_handle_money(pb.org_id) then raise exception 'Your role does not see payments.' using errcode = '42501'; end if;
  select * into a from approvals where batch_id = pb.id and status = 'pending';
  return private.batch_json(pb.id) || jsonb_build_object('can', jsonb_build_object('pay_out', private.perm_of(m, 'make_payments'),
    'approve', case when a.id is not null then coalesce((private.approval_json(a, m)->>'can_decide')::boolean, false)
      else private.perm_of(m, 'make_payments') and (pb.requested_by is distinct from m.id or private.perm_of(m, 'owner')) end));
end $function$;


CREATE OR REPLACE FUNCTION public.get_payments(p_org uuid, p_filter jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; o public.orgs; w public.wallets; v_money boolean; v_from date := nullif(p_filter->>'from', '')::date;
  v_to date := nullif(p_filter->>'to', '')::date; v_lo timestamptz; v_hi timestamptz;
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  v_lo := case when v_from is not null then (v_from::timestamp) at time zone coalesce(o.timezone, 'Africa/Lagos') end;
  v_hi := case when v_to is not null then ((v_to + 1)::timestamp) at time zone coalesce(o.timezone, 'Africa/Lagos') end;
  select * into w from wallets where org_id = p_org and rail = o.payment_rail;
  v_money := private.can_handle_money(p_org);
  return jsonb_build_object(
    'rail', (select to_jsonb(r) - 'api_key_secret' - 'webhook_secret' from payment_rails r where r.code = o.payment_rail),
    'rails', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'capabilities', capabilities) order by code = 'flutterwave' desc, name), '[]'::jsonb)
              from payment_rails where active),
    'wallet', case when w.id is not null then to_jsonb(w) - 'provider_available' - 'provider_ledger' || jsonb_build_object(
        'books_balance', case when v_money then private.wallet_balance(w.id) end,
        'provider_balance', case when v_money then coalesce(w.provider_ledger, w.provider_available) end,
        'available', case when v_money then private.wallet_balance(w.id) - coalesce((select sum(amount + fee) from payouts where wallet_id = w.id
           and status in ('approved', 'processing', 'pending_approval')), 0) end) end,
    'settings', jsonb_build_object('payment_methods', o.payment_methods, 'payout_approval_threshold', o.payout_approval_threshold),
    'requests', (select coalesce(jsonb_agg(private.request_json(r) || jsonb_build_object('created_at', r.created_at, 'customer_name', c.name,
        'created_by_name', (select display_name from members where id = r.created_by), 'sweep_status', case when v_money then r.sweep_status end,
        'fee', case when v_money then r.fee end) order by r.created_at desc), '[]'::jsonb)
      from (select * from payment_requests where org_id = p_org
              and created_at >= coalesce(v_lo, case when v_hi is null then now() - interval '60 days' end, '-infinity') and created_at < coalesce(v_hi, 'infinity')
            order by created_at desc limit case when v_lo is null and v_hi is null then 300 else 2000 end) r
      left join customers c on c.id = r.customer_id),
    'payouts', case when v_money then (select coalesce(jsonb_agg(to_jsonb(p) - 'raw' - 'lines' || jsonb_build_object(
        'requested_by_name', (select display_name from members where id = p.requested_by), 'approved_by_name', (select display_name from members where id = p.approved_by),
        'journal_ref', (select ref from journals where id = p.journal_id),
        'approval', (select private.approval_json(a, m) - 'summary' from approvals a where a.payout_id = p.id order by a.created_at desc limit 1))
        order by p.created_at desc), '[]'::jsonb)
      from (select * from payouts where org_id = p_org and batch_id is null and created_at >= coalesce(v_lo, '-infinity') and created_at < coalesce(v_hi, 'infinity')
            order by created_at desc limit case when v_lo is null and v_hi is null then 300 else 2000 end) p) end,
    'batches', case when v_money then (select coalesce(jsonb_agg(private.batch_json(b.id, false) order by b.created_at desc), '[]'::jsonb)
      from (select id, created_at from payout_batches where org_id = p_org and created_at >= coalesce(v_lo, '-infinity') and created_at < coalesce(v_hi, 'infinity')
            order by created_at desc limit case when v_lo is null and v_hi is null then 100 else 500 end) b) end,
    'reconciliations', case when v_money then (select coalesce(jsonb_agg(to_jsonb(x) order by x.at desc), '[]'::jsonb)
      from (select * from wallet_reconciliations where org_id = p_org order by at desc limit 30) x) end,
    'can', jsonb_build_object('pay_out', private.perm_of(m, 'make_payments'), 'open_wallet', private.perm_of(m, 'keep_books') or private.perm_of(m, 'make_payments'),
      'settings', private.perm_of(m, 'owner')),
    'me', m.id, 'period', case when v_from is not null or v_to is not null then jsonb_build_object('from', v_from, 'to', v_to) end);
end $function$;


CREATE OR REPLACE FUNCTION public.public_document(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
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
end $function$;


CREATE OR REPLACE FUNCTION public.get_attention(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; o public.orgs; v_today date; v_books boolean; v_pay boolean; v_sales boolean; v_tax boolean; v_vat int := 0; v_wht int := 0; v_cit int := 0;
  r record;
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  v_today := private.local_day(p_org, now());
  v_books := private.perm_of(m, 'keep_books');
  v_pay := private.perm_of(m, 'make_payments');
  v_sales := private.perm_of(m, 'record_sales') or v_books;
  v_tax := v_books or private.perm_of(m, 'file_tax');
  if v_tax then
    for r in select * from private.tax_deadlines(p_org) where due <= v_today + 7 loop
      if r.tax = 'vat' then v_vat := v_vat + 1; elsif r.tax in ('cit', 'pit') then v_cit := v_cit + 1; else v_wht := v_wht + 1; end if;
    end loop;
    v_cit := case when exists (select 1 from private.tax_deadlines(p_org) t where t.tax in ('cit', 'pit') and t.due <= v_today + 30) then 1 else 0 end;
  end if;
  return jsonb_build_object(
    'invoices_overdue', case when v_sales then (select count(*) from sales where org_id = p_org and doc_type = 'invoice' and status in ('open', 'partially_paid')
      and journal_id is not null and due_date < v_today) else 0 end,
    'orders_to_confirm', case when v_sales then (select count(*) from sales where org_id = p_org and doc_type = 'order' and status = 'pending') else 0 end,
    'payments_to_confirm', case when v_books or private.perm_of(m, 'approve_adjustments') then (select count(*) from collections where org_id = p_org and status = 'pending') else 0 end,
    'bills_overdue', case when v_books or v_pay then (select count(*) from bills where org_id = p_org and status in ('approved', 'partially_paid') and due_date < v_today) else 0 end,
    'bank_lines', case when v_books then (select count(*) from bank_lines where org_id = p_org and status = 'unmatched') else 0 end,
    'proposals', case when v_books then (select count(*) from ai_proposals where org_id = p_org and status = 'pending') else 0 end,
    'schedules_draft', case when v_tax then (select count(*) from sales_schedules where org_id = p_org and status = 'draft') else 0 end,
    'vat', v_vat, 'wht', v_wht, 'cit', v_cit,
    'tax_wallet', case when v_pay or v_books then
      (case when exists (select 1 from wallets where org_id = p_org and status = 'active') and not exists (select 1 from tax_wallets where org_id = p_org and status = 'active') then 1 else 0 end)
      + (select count(*) from tax_payments where org_id = p_org and status = 'failed' and created_at > now() - interval '7 days')
      + (select count(*) from tax_payment_instructions where org_id = p_org
         and (status in ('needs_approval', 'expired') or (status = 'confirmed' and journal_id is null and payment_id is null))) else 0 end,
    'tax_id', case when private.perm_of(m, 'owner') or private.perm_of(m, 'manage_settings') then
      case when coalesce(o.tin, '') = '' or coalesce(o.tin_status, '') not in ('verified', 'confirmed') then 1 else 0 end else 0 end,
    'accountant_requests', case when m.practice_id is null and (m.role in ('owner', 'admin') or m.acts_as_owner) then
      (select count(*) from practice_requests pr join practice_clients pc on pc.id = pr.client_id
       where pr.org_id = p_org and pr.status = 'open' and pc.status = 'active') else 0 end,
    -- What waits for this person's approval, and what they asked for that waits.
    'approvals', case when m.role in ('owner', 'admin') then (select count(*) from approvals a where a.org_id = p_org and a.status = 'pending'
      and a.approver = 'owner' and a.requested_by is distinct from m.id and (m.practice_id is null or not ('firm' = any(a.reasons)))) else 0 end,
    'approvals_mine', (select count(*) from approvals where org_id = p_org and status = 'pending' and requested_by = m.id),
    -- Payments taken as sales whose VAT a person should check: once the AI has looked (or could not), not while it is about to.
    'receipts_vat', case when v_tax then (select count(*) from sales where org_id = p_org and channel = 'bank' and doc_type = 'receipt' and status <> 'void'
      and vat_check and (vat_ai_at is not null or vat_ai_tries >= 3 or vat_source is distinct from 'usual' or created_at < now() - interval '1 day')) else 0 end);
end $function$;


CREATE OR REPLACE FUNCTION public.update_sales_settings(p_org uuid, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; o public.orgs; v_slug text;
begin
  m := private.require(p_org, null);
  if not private.perm_of(m, 'owner') then raise exception 'Only the owner changes these settings.' using errcode = '42501'; end if;
  if p_patch ? 'shop_slug' then
    v_slug := nullif(lower(trim(p_patch->>'shop_slug')), '');
    if v_slug is not null and v_slug !~ '^[a-z0-9]([a-z0-9-]{1,38}[a-z0-9])$' then
      raise exception 'Use 3 to 40 letters, numbers or dashes for the shop link.';
    end if;
    if v_slug is not null and exists (select 1 from orgs where shop_slug = v_slug and id <> p_org) then raise exception 'That shop link is taken.'; end if;
  end if;
  if nullif(p_patch->>'shop_location_id', '') is not null and not exists (select 1 from locations where id = (p_patch->>'shop_location_id')::uuid and org_id = p_org) then
    raise exception 'Choose the branch the shop sells from.';
  end if;
  if private.num(p_patch->>'max_cashier_discount_pct') not between 0 and 100 then raise exception 'The cashier discount allowance is a percentage from 0 to 100.'; end if;
  if private.num(p_patch->>'discount_approval_pct') not between 0 and 100 then raise exception 'The discount limit for invoices is a percentage from 0 to 100.'; end if;
  update orgs set
    max_cashier_discount_pct = coalesce(private.num(p_patch->>'max_cashier_discount_pct'), max_cashier_discount_pct),
    discount_approval_pct = coalesce(private.num(p_patch->>'discount_approval_pct'), discount_approval_pct),
    receipt_footer = case when p_patch ? 'receipt_footer' then left(nullif(trim(p_patch->>'receipt_footer'), ''), 300) else receipt_footer end,
    shop_slug = case when p_patch ? 'shop_slug' then v_slug else shop_slug end,
    shop_enabled = coalesce((p_patch->>'shop_enabled')::boolean, shop_enabled),
    shop_title = case when p_patch ? 'shop_title' then left(nullif(trim(p_patch->>'shop_title'), ''), 80) else shop_title end,
    shop_note = case when p_patch ? 'shop_note' then left(nullif(trim(p_patch->>'shop_note'), ''), 500) else shop_note end,
    shop_whatsapp = case when p_patch ? 'shop_whatsapp' then private.clean_phone(p_patch->>'shop_whatsapp') else shop_whatsapp end,
    shop_location_id = case when p_patch ? 'shop_location_id' then nullif(p_patch->>'shop_location_id', '')::uuid else shop_location_id end,
    shop_delivery_fee = case when p_patch ? 'shop_delivery_fee' then round(greatest(coalesce(private.num(p_patch->>'shop_delivery_fee'), 0), 0), 2) else shop_delivery_fee end,
    shop_pickup = coalesce((p_patch->>'shop_pickup')::boolean, shop_pickup),
    shop_delivery = coalesce((p_patch->>'shop_delivery')::boolean, shop_delivery),
    shop_show_stock = coalesce((p_patch->>'shop_show_stock')::boolean, shop_show_stock),
    shop_categories = case when p_patch ? 'shop_categories' then
      (select nullif(array_agg(value), '{}') from jsonb_array_elements_text(case when jsonb_typeof(p_patch->'shop_categories') = 'array' then p_patch->'shop_categories' else '[]'::jsonb end))
      else shop_categories end
  where id = p_org returning * into o;
  if o.shop_enabled and o.shop_slug is null then raise exception 'Choose a link for the shop before opening it.'; end if;
  if o.shop_enabled and not o.shop_pickup and not o.shop_delivery then raise exception 'Offer pickup, delivery or both.'; end if;
  return jsonb_build_object('max_cashier_discount_pct', o.max_cashier_discount_pct, 'discount_approval_pct', o.discount_approval_pct, 'receipt_footer', o.receipt_footer, 'shop_slug', o.shop_slug,
    'shop_enabled', o.shop_enabled, 'shop_title', o.shop_title, 'shop_note', o.shop_note, 'shop_whatsapp', o.shop_whatsapp, 'shop_location_id', o.shop_location_id,
    'shop_delivery_fee', o.shop_delivery_fee, 'shop_pickup', o.shop_pickup, 'shop_delivery', o.shop_delivery, 'shop_show_stock', o.shop_show_stock,
    'shop_categories', o.shop_categories);
end $function$;


CREATE OR REPLACE FUNCTION public.practice_director_state(p_client uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare c public.practice_clients; o public.orgs; d public.practice_director_confirmations; k public.identity_checks;
begin
  select * into c from practice_clients where id = p_client;
  if c.id is null or c.practice_id is null then raise exception 'Client not found.'; end if;
  perform private.practice_require(c.practice_id, true);
  select * into o from orgs where id = c.org_id;
  select * into d from practice_director_confirmations where client_id = c.id order by created_at desc, id limit 1;
  if d.check_id is not null then select * into k from identity_checks where id = d.check_id; end if;
  return jsonb_build_object(
    'confirmed_at', o.director_confirmed_at,
    'cac', private.org_cac(o.id) is not null,
    'directors', case when private.acts_as_owner(o.id, auth.uid()) then
        (select coalesce(jsonb_agg(jsonb_build_object('name', x->>'name', 'role', x->>'role') order by x->>'name'), '[]'::jsonb)
         from jsonb_array_elements(private.cac_people(private.org_cac(o.id))) x) else '[]'::jsonb end,
    'latest', case when d.id is not null then jsonb_build_object('id', d.id, 'status', d.status, 'name', d.name, 'email', d.email,
        'created_at', d.created_at, 'confirmed_at', d.confirmed_at, 'matched_name', d.matched_name,
        'review_reason', d.flags->>'review_reason', 'decline_reason', d.decline_reason,
        'step', case when d.status <> 'pending' then null when k.id is null or k.status <> 'open' then 'nin' when k.route = 'slip' then 'slip' else 'code' end,
        'link_live', d.token_hash is not null and d.token_expires > now()) end,
    -- Who approves what the firm does here (full mandate): the director whose code reached them, with where it goes.
    'approver', (select jsonb_build_object('name', coalesce(a.matched_name, a.name), 'email', private.mask_email(a.approver_email),
        'phone', private.mask_phone(a.approver_phone), 'confirmed_at', a.confirmed_at,
        'pending', (select count(*) from approvals where org_id = o.id and status = 'pending' and approver = 'director'),
        'last_link', (select max(created_at) from approval_links where org_id = o.id))
      from private.org_approver(o.id) a where a.id is not null),
    'approver_missing', c.mode = 'full' and c.status = 'active' and o.director_confirmed_at is not null
      and (select a.id from private.org_approver(o.id) a) is null);
end $function$;


CREATE OR REPLACE FUNCTION public.practice_director_request(p_client uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare c public.practice_clients; m public.practice_members; o public.orgs; d public.practice_director_confirmations;
  v_name text; v_email text; v_parts text[]; v_people jsonb; t jsonb;
begin
  select * into c from practice_clients where id = p_client for update;
  if c.id is null or c.practice_id is null then raise exception 'Client not found.'; end if;
  m := private.practice_require(c.practice_id, true);
  select * into o from orgs where id = c.org_id;
  if c.mode <> 'full' or c.status <> 'active' or o.managed_by is distinct from c.practice_id then
    raise exception 'A director confirms only for a business the firm runs under full mandate.';
  end if;
  -- The CAC record is read only by someone acting as the business's owner (the firm's partners and managers have such a
  -- place while they are active).
  if not private.acts_as_owner(o.id, auth.uid()) then
    raise exception 'Only the firm''s people acting as the business''s owner ask a director to confirm.' using errcode = '42501';
  end if;
  -- Once a director confirmed, another is asked only while Counta cannot reach one for approvals (a confirmation TaxStreem
  -- accepted on a NIN slip leaves no phone or email): that director confirms by code and approves from then on.
  if o.director_confirmed_at is not null and (select a.id from private.org_approver(o.id) a) is not null then
    raise exception 'A director of the business has confirmed already.';
  end if;
  if exists (select 1 from practice_director_confirmations where client_id = c.id and status = 'review') then
    raise exception 'TaxStreem is checking the director''s last confirmation. Wait for its decision.';
  end if;
  v_people := private.cac_people(private.org_cac(o.id));
  if jsonb_array_length(v_people) = 0 then
    raise exception 'Add the business''s CAC record first (Settings, Business profile), so Counta knows its directors.';
  end if;
  if jsonb_typeof(p) is distinct from 'object' then raise exception 'Choose the director.'; end if;
  v_name := btrim(regexp_replace(coalesce(p->>'name', ''), '\s+', ' ', 'g'));
  v_email := nullif(lower(btrim(coalesce(p->>'email', ''))), '');
  if length(v_name) not between 2 and 120 then raise exception 'Choose the director from the CAC record.'; end if;
  if v_email is not null and private.clean_email(v_email) is null then raise exception 'That email address is not valid.'; end if;
  v_parts := private.name_parts(v_name);
  if v_parts is null or private.identity_match(v_parts[1], v_parts[2], v_parts[3], v_people) is null then
    raise exception 'That name is not a director on the CAC record.';
  end if;
  if v_email is not null and private.firm_email(c.practice_id, v_email) is not null then
    raise exception 'Send it to the director''s own email address, not the firm''s.';
  end if;
  if (select count(*) from practice_director_confirmations where client_id = c.id and created_at > now() - interval '1 day') >= 5 then
    raise exception 'That is five requests for this business today. Try again tomorrow.';
  end if;
  for d in select * from practice_director_confirmations where client_id = c.id and status = 'pending' loop
    perform private.identity_close(d.id);
  end loop;
  update practice_director_confirmations set status = 'cancelled', token_hash = null, token_expires = null, otp_hash = null, otp_expires = null
  where client_id = c.id and status = 'pending';
  insert into practice_director_confirmations (practice_id, client_id, name, email, requested_by)
  values (c.practice_id, c.id, v_name, v_email, m.id)
  returning * into d;
  perform private.activity_event(c.org_id, 'director_requested', 'A director''s confirmation was asked for',
    jsonb_build_object('practice_id', c.practice_id, 'confirmation_id', d.id));
  if v_email is not null then
    perform private.practice_mail('director_confirm', d.id);
    return jsonb_build_object('id', d.id, 'status', d.status, 'name', d.name, 'email', d.email, 'sent', true, 'created_at', d.created_at);
  end if;
  t := private.token_new('dc');
  update practice_director_confirmations set token_hash = t->>'hash', token_expires = now() + interval '14 days' where id = d.id;
  return jsonb_build_object('id', d.id, 'status', d.status, 'name', d.name, 'email', null, 'sent', false, 'created_at', d.created_at,
    'link', coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app') || '/confirm/' || (t->>'token'));
end $function$;


CREATE OR REPLACE FUNCTION public.svc_identity_mail(p_kind text, p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare c public.identity_checks; d public.practice_director_confirmations; r public.account_recoveries; s public.support_cases; o public.orgs;
  t jsonb; v_firm text; v_business text; v_reply text; v_app text; v_name text; v_email text; v_support text;
  l public.approval_links; v_n int; v_titles jsonb;
begin
  v_app := coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app');
  if p_kind = 'identity_code' then
    select * into c from identity_checks where id = p_id for update;
    if c.id is null or c.status <> 'open' or c.route = 'slip' or (c.sms_to is null and c.email_to is null)
       or c.locked_at is not null or c.otp_failures >= 15 then
      return null;
    end if;
    if c.purpose = 'director_confirm' then
      select * into d from practice_director_confirmations where id = c.ref_id;
      if d.id is null or d.status <> 'pending' or d.check_id is distinct from c.id or not private.director_mandate_open(d.client_id, d.practice_id) then
        return null;
      end if;
      select name into v_firm from practices where id = d.practice_id;
      select o2.name into v_business from practice_clients pc join orgs o2 on o2.id = pc.org_id where pc.id = d.client_id;
      v_reply := coalesce((select pm.email from practice_clients pc join practice_members pm on pm.id = pc.engagement_partner_id
                           where pc.id = d.client_id and pm.status = 'active'), (select email from practices where id = d.practice_id));
      t := private.otp_new(c.id);
      update identity_checks set otp_hash = t->>'otp_hash', otp_expires = (t->>'otp_expires')::timestamptz, otp_tries = 0 where id = c.id;
      return jsonb_build_object('to', c.email_to, 'reply_to', v_reply, 'from_name', v_firm, 'org_id', c.org_id, 'purpose', c.purpose,
        'subject', 'Your code to confirm the wallets for ' || v_business,
        'heading', 'Your confirmation code',
        'greet', split_part(btrim(coalesce(c.matched_name, d.name)), ' ', 1),
        'lines', jsonb_build_array('Enter this code to answer ' || v_firm || '''s request about the wallets for ' || v_business || '. It works for ten minutes.',
          'If you did not ask for a code, you can ignore this email.'),
        'button', null, 'link', null, 'code', t->>'code', 'white_label', true,
        'sms', case when c.sms_to is not null then jsonb_build_object('to', c.sms_to,
          'text', (t->>'code') || ' is your code to confirm the wallets for ' || left(v_business, 60) || '. It expires in 10 minutes. Do not share it.') end);
    end if;
    select * into r from account_recoveries where id = c.ref_id;
    if r.id is null or r.status <> 'started' or r.check_id is distinct from c.id then return null; end if;
    select name into v_business from orgs where id = r.org_id;
    t := private.otp_new(c.id);
    update identity_checks set otp_hash = t->>'otp_hash', otp_expires = (t->>'otp_expires')::timestamptz, otp_tries = 0 where id = c.id;
    return jsonb_build_object('to', c.email_to, 'reply_to', null, 'from_name', 'Counta', 'org_id', c.org_id, 'purpose', c.purpose,
      'subject', 'Your Counta code to recover ' || v_business,
      'heading', 'Your recovery code',
      'greet', split_part(btrim(coalesce(c.matched_name, '')), ' ', 1),
      'lines', jsonb_build_array('Enter this code in Counta to prove you are a director of ' || v_business || ' and recover it. It works for ten minutes.',
        'If you did not ask to recover this business, someone may have your NIN. Ignore this email and tell TaxStreem''s support.'),
      'button', null, 'link', null, 'code', t->>'code', 'white_label', false,
      'sms', case when c.sms_to is not null then jsonb_build_object('to', c.sms_to,
        'text', (t->>'code') || ' is your Counta code to recover ' || left(v_business, 60) || '. It expires in 10 minutes. Do not share it.') end);
  end if;

  if p_kind in ('recovery_owner', 'recovery_handover', 'recovery_done', 'recovery_admin') then
    select * into r from account_recoveries where id = p_id for update;
    if r.id is null then return null; end if;
    select * into o from orgs where id = r.org_id;
    select coalesce(nullif(btrim(raw_user_meta_data->>'full_name'), ''), split_part(email, '@', 1)), email into v_name, v_email
    from auth.users where id = r.user_id;
    if p_kind = 'recovery_owner' then
      if r.status <> 'verified' then return null; end if;
      return jsonb_build_object('to', to_jsonb(private.holder_emails(o.id)), 'reply_to', null, 'from_name', 'Counta',
        'subject', 'A director asked to take over ' || o.name || ' on Counta',
        'heading', 'A director asked for the business',
        'greet', null,
        'lines', jsonb_build_array(left(v_name, 80) || ' proved with their NIN that they are a director of ' || o.name
            || ' on its CAC record, and asked to take the business over on Counta.',
          'Open Counta within 30 minutes to hand it over, or to say why it should not go to them. Until this is settled, no money leaves the business''s wallets.',
          'If you do not answer, the director may ask TaxStreem to decide.'),
        'button', 'Open Counta', 'link', v_app || case when o.managed_by is not null then '/practice/clients' else '/settings#ownership' end,
        'white_label', false);
    elsif p_kind = 'recovery_handover' then
      if r.status <> 'handover_sent' then return null; end if;
      t := private.token_new('rh');
      update account_recoveries set token_hash = t->>'hash', token_expires = now() + interval '7 days', updated_at = now() where id = r.id;
      return jsonb_build_object('to', v_email, 'reply_to', null, 'from_name', 'Counta',
        'subject', o.name || ' is ready for you on Counta',
        'heading', 'Take over the business',
        'greet', split_part(btrim(v_name), ' ', 1),
        'lines', jsonb_build_array('The business''s holder handed ' || o.name || ' over to you.',
          'Use the button while signed in with this login to take it. You become its owner and the previous owner''s place ends. The link works for seven days.'),
        'button', 'Take over the business', 'link', v_app || '/recover/accept/' || (t->>'token'), 'white_label', false);
    elsif p_kind = 'recovery_done' then
      if r.status <> 'completed' then return null; end if;
      return jsonb_build_object('to', coalesce(r.previous->'emails', '[]'::jsonb), 'reply_to', null, 'from_name', 'Counta',
        'subject', o.name || ' was taken over by its director',
        'heading', 'The business has a new owner',
        'greet', null,
        'lines', jsonb_build_array(left(v_name, 80) || ', a director of ' || o.name || ' on its CAC record, owns the business on Counta now. Your place in it has ended.',
          'If you think this is wrong, write to TaxStreem''s support.'),
        'button', null, 'link', null, 'white_label', false);
    end if;
    if r.status <> 'review' then return null; end if;
    return jsonb_build_object('to', to_jsonb(public.svc_review_recipients()), 'reply_to', null, 'from_name', 'Counta',
      'subject', 'A recovery to check: ' || o.name,
      'heading', 'A director''s recovery to check',
      'greet', null,
      'lines', jsonb_build_array('Business: ' || o.name || '.', 'Asked by: ' || left(v_name, 80) || '.',
        case r.review_reason when 'another_recovery' then 'Another director''s recovery of this business is open.'
          else 'Their NIN matched a director on the CAC record, but the code could not go to a phone on the NIN record, so Counta did not tell the holder yet.' end),
      'button', 'Open recoveries', 'link', v_app || '/admin/recoveries', 'white_label', false);
  end if;

  -- The director's approvals: a link to what waits (minted as it goes), or the code that opens it. Only while they are the
  -- director who approves for the business.
  if p_kind in ('approval_link', 'approval_code') then
    select * into l from approval_links where id = p_id for update;
    if l.id is null then return null; end if;
    select * into d from practice_director_confirmations where id = l.confirmation_id;
    if d.id is null or (select x.id from private.org_approver(l.org_id) x) is distinct from d.id then return null; end if;
    select name into v_firm from practices where id = d.practice_id;
    select name into v_business from orgs where id = l.org_id;
    v_reply := coalesce((select pm.email from practice_clients pc join practice_members pm on pm.id = pc.engagement_partner_id
                         where pc.id = d.client_id and pm.status = 'active'), (select email from practices where id = d.practice_id));
    if p_kind = 'approval_link' then
      select count(*), coalesce(jsonb_agg(left(x.summary->>'title', 120) order by x.created_at) filter (where x.rn <= 5), '[]'::jsonb) into v_n, v_titles
      from (select a.*, row_number() over (order by a.created_at) rn from approvals a
            where a.org_id = l.org_id and a.status = 'pending' and a.approver = 'director') x;
      if v_n = 0 or l.token_hash is not null then return null; end if;
      t := private.token_new('ap');
      update approval_links set token_hash = t->>'hash', expires_at = now() + interval '7 days' where id = l.id;
      return jsonb_build_object('to', d.approver_email, 'reply_to', v_reply, 'from_name', v_firm, 'org_id', l.org_id, 'purpose', 'approval',
        'subject', v_firm || ' asks you to approve ' || case when v_n = 1 then 'one item' else v_n || ' items' end || ' for ' || v_business,
        'heading', 'Waiting for your approval',
        'greet', initcap(split_part(btrim(coalesce(d.matched_name, d.name)), ' ', 1)),
        'lines', jsonb_build_array(v_firm || ' keeps the books of ' || v_business || ' under your full mandate, and asks you to approve: '
            || (select string_agg(value, '; ') from jsonb_array_elements_text(v_titles)) || case when v_n > 5 then ' and ' || (v_n - 5) || ' more' else '' end || '.',
          'Open the link to see each one and approve it or say why not. Counta sends a code to your phone and email first. The link works for seven days.',
          'Nothing waiting for you is issued or paid until you approve it.'),
        'button', 'Review and approve', 'link', v_app || '/approve/' || (t->>'token'), 'code', null, 'white_label', true,
        'sms', case when d.approver_phone is not null then jsonb_build_object('to', d.approver_phone,
          'text', left(v_firm, 40) || ' asks you to approve ' || case when v_n = 1 then 'one item' else v_n || ' items' end || ' for ' || left(v_business, 50)
            || ' on Counta. ' || case when d.approver_email is not null then 'The link is in your email ' || private.mask_email(d.approver_email) || '.'
              else 'Open ' || v_app || '/approve/' || (t->>'token') end) end);
    end if;
    if l.token_hash is null or l.expires_at is null or l.expires_at <= now() or l.locked_at is not null or l.otp_failures >= 15 then return null; end if;
    t := private.otp_new(l.id);
    update approval_links set otp_hash = t->>'otp_hash', otp_expires = (t->>'otp_expires')::timestamptz, otp_tries = 0 where id = l.id;
    return jsonb_build_object('to', d.approver_email, 'reply_to', v_reply, 'from_name', v_firm, 'org_id', l.org_id, 'purpose', 'approval',
      'subject', 'Your code to approve for ' || v_business,
      'heading', 'Your approval code',
      'greet', initcap(split_part(btrim(coalesce(d.matched_name, d.name)), ' ', 1)),
      'lines', jsonb_build_array('Enter this code on the approval page for ' || v_business || '. It works for ten minutes.',
        'If you did not ask for a code, you can ignore this email.'),
      'button', null, 'link', null, 'code', t->>'code', 'white_label', true,
      'sms', case when d.approver_phone is not null then jsonb_build_object('to', d.approver_phone,
        'text', (t->>'code') || ' is your code to approve for ' || left(v_business, 60) || ' on Counta. It expires in 10 minutes. Do not share it.') end);
  end if;

  if p_kind = 'support_case' then
    select * into s from support_cases where id = p_id;
    if s.id is null or s.status <> 'open' then return null; end if;
    v_support := coalesce(private.clean_email(public.svc_secret('SUPPORT_EMAIL')), private.clean_email(public.svc_secret('KYC_REVIEW_EMAIL')), 'admin@taxstreem.com');
    return jsonb_build_object('to', v_support, 'reply_to', s.contact_email, 'from_name', 'Counta',
      'subject', 'Support request: ' || case s.kind when 'recovery_waiting' then 'a holder has not handed a business over'
        when 'recovery_no_access' then 'a director cannot get their recovery code' when 'recovery_dispute' then 'a recovery was disputed'
        else 'help needed' end || coalesce(' (' || (select name from orgs where id = s.org_id) || ')', ''),
      'heading', 'A support request',
      'greet', null,
      'lines', jsonb_build_array('From: ' || coalesce(s.contact_email, 'unknown') || '.',
          coalesce('Message: ' || s.message, 'No message.'), 'Reply to this email to answer them.'),
      'button', 'Open recoveries', 'link', v_app || '/admin/recoveries', 'white_label', false);
  end if;
  raise exception 'Unknown identity email: %.', p_kind;
end $function$;


-- ---------------------------------------------------------------------------
-- 8. Grants
-- ---------------------------------------------------------------------------
revoke all on function private.relief_label(text), private.relief_words(text), private.sale_lines_input(uuid),
  private.sale_set_relief(public.sales, text, text, public.members, boolean), private.relief_ticked(public.sales),
  private.org_approver(uuid), private.approval_route(uuid, public.members, text, jsonb), private.sale_discount_pct(uuid), private.sale_fingerprint(uuid),
  private.approval_drop(uuid, text), private.approval_call(text, jsonb, public.members), private.approval_summary(uuid, text, jsonb, jsonb, jsonb),
  private.approval_tell_owners(public.approvals), private.approval_tell_director(uuid, boolean), private.approval_tick(),
  private.approval_request(uuid, public.members, text, jsonb, text, jsonb, jsonb), private.approval_json(public.approvals, public.members),
  private.approval_carry(public.approvals, uuid), private.approval_undo(public.approvals), private.approval_tell_requester(public.approvals),
  private.approval_settle(uuid, boolean, text, uuid, text, text, text), private.approval_link_by_token(text),
  private.approval_link_state(public.approval_links), private.approval_link_json(public.approval_links),
  private.identity_checks_keep_approver(), private.director_approver_one(), private.mandate_approvals_end(), private.sale_approvals_end()
  from public, anon, authenticated;

revoke all on function public.set_sale_vat_relief(uuid, text, text), public.approvals_list(uuid), public.approval_decide(uuid, boolean, text),
  public.approvals_remind(uuid) from public, anon;
grant execute on function public.set_sale_vat_relief(uuid, text, text), public.approvals_list(uuid), public.approval_decide(uuid, boolean, text),
  public.approvals_remind(uuid) to authenticated;

revoke all on function public.svc_approval_open(text, text, text), public.svc_approval_code(text, text, text),
  public.svc_approval_verify(text, text, text, text), public.svc_approval_decide(text, uuid[], boolean, text, text, text)
  from public, anon, authenticated;
grant execute on function public.svc_approval_open(text, text, text), public.svc_approval_code(text, text, text),
  public.svc_approval_verify(text, text, text, text), public.svc_approval_decide(text, uuid[], boolean, text, text, text) to service_role;
