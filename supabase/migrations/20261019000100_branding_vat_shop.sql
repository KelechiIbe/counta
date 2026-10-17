-- Counta: branded invoices (three templates), fuller customer details, VAT status on every sale line
-- (0 VATable, 1 exempt, 2 zero-rated) with sales to customers outside Nigeria zero-rated as exports, branded emails,
-- and a branded online shop with a proper checkout.

-- ---------------------------------------------------------------------------
-- 1. Branding
-- ---------------------------------------------------------------------------
alter table public.orgs add column if not exists brand_color text not null default '#0072F5';
alter table public.orgs drop constraint if exists orgs_brand_color_check;
alter table public.orgs add constraint orgs_brand_color_check check (brand_color ~ '^#[0-9A-Fa-f]{6}$');
alter table public.orgs add column if not exists invoice_template text not null default 'classic';
alter table public.orgs drop constraint if exists orgs_invoice_template_check;
alter table public.orgs add constraint orgs_invoice_template_check check (invoice_template in ('classic', 'modern', 'minimal'));
alter table public.orgs add column if not exists website text;
alter table public.orgs add column if not exists invoice_footer text;
-- What the documents carry besides the essentials: {tin, rc_number, vat_status, amount_in_words, signature}.
alter table public.orgs add column if not exists invoice_show jsonb not null default '{"tin": true, "rc_number": true, "vat_status": true, "amount_in_words": true, "signature": false}';
alter table public.orgs add column if not exists shop_banner_path text;
alter table public.orgs add column if not exists shop_tagline text;
alter table public.orgs add column if not exists shop_socials jsonb not null default '{}';
alter table public.orgs add column if not exists shop_pay_on_delivery boolean not null default true;
alter table public.orgs add column if not exists shop_min_order numeric(14,2) not null default 0;

-- Owner only. Files live in the public item-photos bucket under the business's own folder.
create or replace function public.update_branding(p_org uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; v_web text; v_color text; v_show jsonb; v_soc jsonb := '{}'::jsonb; k text; v text;
begin
  m := private.require(p_org, null);
  if m.role <> 'owner' then raise exception 'Only the owner changes the branding.' using errcode = '42501'; end if;
  if p_patch ? 'brand_color' then
    v_color := upper(trim(p_patch->>'brand_color'));
    if v_color !~ '^#[0-9A-F]{6}$' then raise exception 'Choose a colour as a hex code such as #0072F5.'; end if;
  end if;
  if p_patch ? 'invoice_template' and p_patch->>'invoice_template' not in ('classic', 'modern', 'minimal') then
    raise exception 'Choose the Classic, Modern or Minimal template.';
  end if;
  if p_patch ? 'website' then
    v_web := nullif(trim(p_patch->>'website'), '');
    if v_web is not null and v_web !~* '^https?://' then v_web := 'https://' || v_web; end if;
    if v_web is not null and (v_web !~* '^https?://[^\s/]+\.[^\s]{2,}$' or length(v_web) > 200) then raise exception 'Check the website address.'; end if;
  end if;
  foreach k in array array['logo_path', 'shop_banner_path'] loop
    if nullif(p_patch->>k, '') is not null and (p_patch->>k) not like p_org::text || '/%' then raise exception 'Upload the picture again.'; end if;
  end loop;
  if p_patch ? 'invoice_show' then
    if jsonb_typeof(p_patch->'invoice_show') <> 'object' then raise exception 'Choose what the documents show.'; end if;
    select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_show from jsonb_each(p_patch->'invoice_show')
    where key in ('tin', 'rc_number', 'vat_status', 'amount_in_words', 'signature') and jsonb_typeof(value) = 'boolean';
  end if;
  if p_patch ? 'shop_socials' then
    if jsonb_typeof(p_patch->'shop_socials') <> 'object' then raise exception 'Social handles must be a list.'; end if;
    for k, v in select key, value from jsonb_each_text(p_patch->'shop_socials') loop
      continue when k not in ('instagram', 'facebook', 'tiktok', 'x');
      v := nullif(regexp_replace(trim(v), '^@', ''), '');
      continue when v is null;
      if v !~ '^[A-Za-z0-9._-]{1,60}$' then raise exception 'Enter the % handle without the web address.', initcap(k); end if;
      v_soc := v_soc || jsonb_build_object(k, v);
    end loop;
  end if;
  if private.num(p_patch->>'shop_min_order') < 0 then raise exception 'The smallest order cannot be negative.'; end if;
  update orgs set
    brand_color = coalesce(v_color, brand_color),
    invoice_template = coalesce(nullif(p_patch->>'invoice_template', ''), invoice_template),
    website = case when p_patch ? 'website' then v_web else website end,
    invoice_footer = case when p_patch ? 'invoice_footer' then left(nullif(trim(p_patch->>'invoice_footer'), ''), 500) else invoice_footer end,
    invoice_note = case when p_patch ? 'invoice_note' then left(nullif(trim(p_patch->>'invoice_note'), ''), 600) else invoice_note end,
    invoice_show = case when p_patch ? 'invoice_show' then invoice_show || v_show else invoice_show end,
    logo_path = case when p_patch ? 'logo_path' then nullif(p_patch->>'logo_path', '') else logo_path end,
    shop_banner_path = case when p_patch ? 'shop_banner_path' then nullif(p_patch->>'shop_banner_path', '') else shop_banner_path end,
    shop_tagline = case when p_patch ? 'shop_tagline' then left(nullif(trim(p_patch->>'shop_tagline'), ''), 120) else shop_tagline end,
    shop_socials = case when p_patch ? 'shop_socials' then v_soc else shop_socials end,
    shop_pay_on_delivery = coalesce((p_patch->>'shop_pay_on_delivery')::boolean, shop_pay_on_delivery),
    shop_min_order = coalesce(round(private.num(p_patch->>'shop_min_order'), 2), shop_min_order)
  where id = p_org returning * into o;
  return private.org_brand(o.id);
end $$;

-- What documents, emails and the shop print about the business.
create or replace function private.org_brand(p_org uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('name', o.name, 'address', o.address, 'phone', o.phone, 'email', o.email, 'tin', o.tin, 'rc_number', o.rc_number,
    'logo_path', o.logo_path, 'receipt_footer', o.receipt_footer, 'vat_registered', o.vat_registered, 'timezone', o.timezone,
    'brand_color', o.brand_color, 'invoice_template', o.invoice_template, 'website', o.website, 'invoice_footer', o.invoice_footer,
    'payment_details', o.invoice_note, 'invoice_show', o.invoice_show, 'reply_to_email', coalesce(o.reply_to_email, o.email))
  from orgs o where o.id = p_org
$$;

-- ---------------------------------------------------------------------------
-- 2. Customers: where they are, who to copy, their tax ID
-- ---------------------------------------------------------------------------
alter table public.customers add column if not exists country text not null default 'NG';
alter table public.customers drop constraint if exists customers_country_check;
alter table public.customers add constraint customers_country_check check (country ~ '^[A-Z]{2}$');
alter table public.customers add column if not exists city text;
alter table public.customers add column if not exists state text;
alter table public.customers add column if not exists contact_person text;
alter table public.customers add column if not exists cc_emails text[] not null default '{}';

create or replace function private.clean_emails(p jsonb) returns text[]
language plpgsql immutable set search_path = '' as $$
declare v text[] := '{}'; e text;
begin
  if p is null or jsonb_typeof(p) = 'null' then return v; end if;
  for e in select lower(trim(x)) from jsonb_array_elements_text(case when jsonb_typeof(p) = 'array' then p else jsonb_build_array(p) end) x loop
    continue when e = '';
    if e !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' then raise exception '% is not an email address.', e; end if;
    if not e = any(v) then v := v || e; end if;
  end loop;
  if array_length(v, 1) > 5 then raise exception 'Copy up to five other email addresses.'; end if;
  return v;
end $$;

create or replace function private.upsert_customer(p_org uuid, p_customer jsonb, m public.members) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare v_id uuid := nullif(p_customer->>'id', '')::uuid; v_phone text := private.clean_phone(p_customer->>'phone');
  v_limit numeric := private.num(p_customer->>'credit_limit'); c public.customers; v_can_credit boolean; v_email text; v_country text;
begin
  if coalesce(trim(p_customer->>'name'), '') = '' then raise exception 'Enter the customer''s name.'; end if;
  if length(trim(p_customer->>'name')) > 120 then raise exception 'The customer''s name is too long.'; end if;
  v_email := nullif(lower(trim(p_customer->>'email')), '');
  if v_email is not null and v_email !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' then raise exception '% is not an email address.', v_email; end if;
  v_country := upper(nullif(trim(p_customer->>'country'), ''));
  if v_country is not null and v_country !~ '^[A-Z]{2}$' then raise exception 'Choose the customer''s country.'; end if;
  v_can_credit := private.perm_of(m, 'approve_adjustments') or private.perm_of(m, 'keep_books');
  if v_id is not null then
    select * into c from customers where id = v_id and org_id = p_org;
    if not found then raise exception 'Customer not found.'; end if;
    if c.is_walk_in then raise exception 'The walk-in customer cannot be edited.'; end if;
  end if;
  if v_limit is not null and v_limit < 0 then raise exception 'A credit limit cannot be negative.'; end if;
  if v_limit is not null and v_limit is distinct from coalesce(c.credit_limit, 0) and not v_can_credit then
    raise exception 'Only a manager, an accountant or the owner can set a credit limit.';
  end if;
  if (p_customer ? 'terms_days') and coalesce((p_customer->>'terms_days')::int, 0) is distinct from coalesce(c.terms_days, 0) and not v_can_credit then
    raise exception 'Only a manager, an accountant or the owner can set payment terms.';
  end if;
  if v_phone is not null and exists (select 1 from customers where org_id = p_org and phone = v_phone and not archived and id is distinct from v_id) then
    raise exception 'A customer with phone % already exists.', v_phone;
  end if;
  if nullif(p_customer->>'price_list_id', '') is not null and not exists (select 1 from price_lists where id = (p_customer->>'price_list_id')::uuid and org_id = p_org) then
    raise exception 'Price list not found.';
  end if;
  if v_id is null then
    insert into customers (org_id, name, kind, phone, email, tin, address, city, state, country, contact_person, cc_emails, price_list_id, credit_limit, terms_days,
      whatsapp_opt_in, notes, tags, created_by)
    values (p_org, trim(p_customer->>'name'), coalesce(nullif(p_customer->>'kind', ''), 'individual'), v_phone, v_email,
      nullif(trim(p_customer->>'tin'), ''), nullif(trim(p_customer->>'address'), ''), nullif(trim(p_customer->>'city'), ''), nullif(trim(p_customer->>'state'), ''),
      coalesce(v_country, 'NG'), nullif(trim(p_customer->>'contact_person'), ''), private.clean_emails(p_customer->'cc_emails'),
      nullif(p_customer->>'price_list_id', '')::uuid,
      coalesce(v_limit, 0), least(greatest(coalesce((p_customer->>'terms_days')::int, 0), 0), 365), coalesce((p_customer->>'whatsapp_opt_in')::boolean, true),
      nullif(trim(p_customer->>'notes'), ''),
      coalesce((select array_agg(value) from jsonb_array_elements_text(case when jsonb_typeof(p_customer->'tags') = 'array' then p_customer->'tags' else '[]'::jsonb end)), '{}'),
      m.id)
    returning id into v_id;
  else
    update customers set name = trim(p_customer->>'name'), kind = coalesce(nullif(p_customer->>'kind', ''), kind),
      phone = case when p_customer ? 'phone' then v_phone else phone end,
      email = case when p_customer ? 'email' then v_email else email end,
      tin = case when p_customer ? 'tin' then nullif(trim(p_customer->>'tin'), '') else tin end,
      address = case when p_customer ? 'address' then nullif(trim(p_customer->>'address'), '') else address end,
      city = case when p_customer ? 'city' then nullif(trim(p_customer->>'city'), '') else city end,
      state = case when p_customer ? 'state' then nullif(trim(p_customer->>'state'), '') else state end,
      country = coalesce(v_country, country),
      contact_person = case when p_customer ? 'contact_person' then nullif(trim(p_customer->>'contact_person'), '') else contact_person end,
      cc_emails = case when p_customer ? 'cc_emails' then private.clean_emails(p_customer->'cc_emails') else cc_emails end,
      price_list_id = case when p_customer ? 'price_list_id' then nullif(p_customer->>'price_list_id', '')::uuid else price_list_id end,
      credit_limit = coalesce(v_limit, credit_limit),
      terms_days = case when p_customer ? 'terms_days' then least(greatest(coalesce((p_customer->>'terms_days')::int, 0), 0), 365) else terms_days end,
      whatsapp_opt_in = coalesce((p_customer->>'whatsapp_opt_in')::boolean, whatsapp_opt_in),
      notes = case when p_customer ? 'notes' then nullif(trim(p_customer->>'notes'), '') else notes end,
      tags = case when jsonb_typeof(p_customer->'tags') = 'array' then coalesce((select array_agg(value) from jsonb_array_elements_text(p_customer->'tags')), '{}') else tags end,
      archived = coalesce((p_customer->>'archived')::boolean, archived)
    where id = v_id;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 3. VAT status on every line; sales to customers outside Nigeria are exports and zero-rated
-- ---------------------------------------------------------------------------
alter table public.sales add column if not exists customer_country text not null default 'NG';
alter table public.sales add column if not exists export boolean not null default false;
alter table public.sales add column if not exists export_note text;
alter table public.sales add column if not exists pay_later boolean not null default false;
-- The item's own treatment before the export rule (null for lines written before this change).
alter table public.sale_lines add column if not exists item_vat_treatment text;
-- 0 VATable (standard rate), 1 exempt, 2 zero-rated.
alter table public.sale_lines add column if not exists vat_status smallint generated always as
  (case vat_treatment when 'standard' then 0 when 'exempt' then 1 else 2 end) stored;

update sales s set customer_country = c.country, export = c.country <> 'NG' from customers c
where c.id = s.customer_id and s.customer_country is distinct from c.country and s.journal_id is null and s.status in ('draft', 'open', 'pending') and s.doc_type in ('invoice', 'quote', 'order');

-- Every document carries the customer's country when it is written. A credit note follows the sale it credits.
create or replace function private.sale_export_snapshot() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_country text;
begin
  if tg_op = 'INSERT' and new.doc_type = 'credit_note' and new.original_sale_id is not null then
    select customer_country, export into new.customer_country, new.export from sales where id = new.original_sale_id;
    return new;
  end if;
  if tg_op = 'UPDATE' and new.customer_id is not distinct from old.customer_id then return new; end if;
  select country into v_country from customers where id = new.customer_id;
  new.customer_country := coalesce(v_country, 'NG');
  new.export := new.customer_country <> 'NG';
  new.export_note := null;
  return new;
end $$;
drop trigger if exists sales_export_snapshot on public.sales;
create trigger sales_export_snapshot before insert or update of customer_id on public.sales
for each row execute function private.sale_export_snapshot();

-- Writes the lines and totals of a sale.
-- p_lines: [{item_id, qty, unit: 'selling'|'purchase', unit_price, discount}] for stock, or
--          [{description, qty, unit_label, unit_price, discount, vat_treatment, revenue_account}] for services.
-- A cart discount is spread over the lines by value. Delivery becomes its own line. On an export every line, delivery
-- included, is zero-rated (status 2) whatever the item's own treatment; the item's treatment is kept beside it.
create or replace function private.write_lines(s public.sales, p_lines jsonb, p_cart_discount numeric, m public.members) returns public.sales
language plpgsql security definer set search_path = public, private as $$
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
  -- Discounts beyond the cashier allowance need someone who can edit prices or approve adjustments.
  if not v_can_price and v_line_disc + v_cart > 0
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
    v_final := case when s.export then 'zero' else x->>'treat' end;
    v_rate := case when not s.vat_registered then 0 when v_final = 'standard' then 0.075 else 0 end;
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
      vat_treatment, item_vat_treatment, vat_rate, net, vat, gross, revenue_account)
    values (s.id, s.org_id, v_no, x->>'kind', nullif(x->>'item_id', '')::uuid, x->>'desc', (x->>'qty')::numeric, x->>'label', (x->>'factor')::numeric,
      (x->>'price')::numeric, nullif(x->>'list', '')::numeric, (x->>'disc')::numeric + v_share, v_final, x->>'treat', v_rate, v_net, v_vat, v_gross, x->>'acct');
  end loop;
  -- Delivery is a service and carries VAT like any other, unless the goods are exported.
  if s.delivery_fee > 0 then
    v_final := case when s.export then 'zero' else 'standard' end;
    v_rate := case when s.vat_registered and v_final = 'standard' then 0.075 else 0 end;
    if s.prices_include_vat then v_gross := s.delivery_fee; v_net := round(v_gross / (1 + v_rate), 2); v_vat := v_gross - v_net;
    else v_net := s.delivery_fee; v_vat := round(v_net * v_rate, 2); v_gross := v_net + v_vat; end if;
    insert into sale_lines (sale_id, org_id, line_no, kind, description, qty, unit_label, unit_price, vat_treatment, item_vat_treatment, vat_rate, net, vat, gross,
      revenue_account)
    values (s.id, s.org_id, v_no + 1, 'delivery', 'Delivery', 1, 'trip', s.delivery_fee, v_final, 'standard', v_rate, v_net, v_vat, v_gross,
      private.acct(s.org_id, 'delivery_income'));
  end if;
  update sales set
    subtotal = (select coalesce(sum(net), 0) from sale_lines where sale_id = s.id),
    discount_total = (select coalesce(sum(discount), 0) from sale_lines where sale_id = s.id),
    vat_total = (select coalesce(sum(vat), 0) from sale_lines where sale_id = s.id),
    total = (select coalesce(sum(gross), 0) from sale_lines where sale_id = s.id)
  where id = s.id returning * into s;
  return s;
end $$;

-- Overrides the export rule on a document that has not posted yet: a foreign customer collecting goods in Nigeria is not an
-- export; a Nigerian address shipping abroad is. Needs a manager or the bookkeeper and a reason, and rewrites the VAT.
create or replace function public.set_sale_export(p_sale uuid, p_export boolean, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
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
  update sales set export = p_export, export_note = left(trim(p_reason), 300) where id = s.id returning * into s;
  s := private.write_lines(s, (select jsonb_agg(case when l.item_id is not null then
        jsonb_build_object('item_id', l.item_id, 'qty', l.qty, 'unit', case when l.unit_factor > 1 then 'purchase' else 'selling' end, 'unit_price', l.unit_price,
          'discount', l.discount)
      else jsonb_build_object('description', l.description, 'qty', l.qty, 'unit_label', l.unit_label, 'unit_price', l.unit_price, 'discount', l.discount,
          'vat_treatment', l.vat_treatment, 'item_vat_treatment', coalesce(l.item_vat_treatment, l.vat_treatment), 'revenue_account', l.revenue_account) end order by l.line_no)
    from sale_lines l where l.sale_id = s.id and l.kind <> 'delivery'), null, m);
  return private.sale_json(s.id, private.can_see_costs(s.org_id));
end $$;

-- VAT return: supplies by status, exports within zero-rated.
create or replace function private.vat_rows(p_org uuid, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = public, private as $$
  with sl as (select s.doc_type, s.export, l.vat_treatment, l.net, l.vat from sales s join sale_lines l on l.sale_id = s.id
              where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.issue_date between p_from and p_to),
  so as (select coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'standard'), 0) std,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'zero'), 0) zero,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'zero' and export), 0) exports,
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
    private.fr('Standard-rated supplies, status 0 (7.5%)', so.std, null, 'line', 1),
    private.fr('Exempt supplies, status 1', so.exempt, null, 'line', 1),
    private.fr('Zero-rated supplies, status 2', so.zero, null, 'line', 1),
    private.fr('of which exports to customers outside Nigeria', so.exports, null, 'line', 2),
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

-- ---------------------------------------------------------------------------
-- 4. Reads: documents carry the branding; the sales list carries each document's VAT statuses
-- ---------------------------------------------------------------------------
create or replace function private.sale_json(p_sale uuid, p_cost boolean) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select to_jsonb(s) || jsonb_build_object(
    'cost_total', case when p_cost then (select sum(cost) from sale_lines where sale_id = s.id) end,
    'balance', case when s.doc_type in ('receipt', 'invoice', 'order') and s.status not in ('void', 'draft', 'converted', 'cancelled') then s.total - s.amount_paid - s.credited
                    when s.doc_type = 'credit_note' then s.total - s.credited else 0 end,
    'pending', (select coalesce(sum(a.amount), 0) from collection_allocations a join collections c on c.id = a.collection_id where a.sale_id = s.id and c.status = 'pending'),
    'confirmed', s.journal_id is not null,
    'location_name', (select name from locations where id = s.location_id),
    'created_by_name', (select display_name from members where id = s.created_by),
    'overdue_days', case when s.status in ('open', 'partially_paid') and s.due_date is not null then greatest(private.local_day(s.org_id, now()) - s.due_date, 0) end,
    'org', private.org_brand(s.org_id),
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
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'method', r.method, 'status', r.status, 'amount', r.amount, 'account_number', r.account_number,
        'bank_name', r.bank_name, 'account_name', r.account_name, 'link_url', r.link_url, 'expires_at', r.expires_at, 'tx_ref', r.tx_ref) order by r.created_at desc), '[]'::jsonb)
      from payment_requests r where r.sale_id = s.id),
    'deliveries', (select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at), '[]'::jsonb) from deliveries d where d.sale_id = s.id),
    'journal_ref', (select ref from journals where id = s.journal_id),
    'customer_credit', case when s.doc_type in ('receipt', 'invoice', 'order') and not (select is_walk_in from customers where id = s.customer_id) then
        (select coalesce(sum(total - credited), 0) from sales cn where cn.customer_id = s.customer_id and cn.doc_type = 'credit_note' and cn.status = 'open')
        + greatest(private.customer_advance(s.org_id, s.customer_id), 0) end)
  from sales s where s.id = p_sale
$$;

create or replace function public.get_sales(p_org uuid, p_filter jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_cost boolean; v_from date := nullif(p_filter->>'from', '')::date; v_to date := nullif(p_filter->>'to', '')::date;
  v_q text := nullif(lower(trim(p_filter->>'q')), ''); v_lim int := least(greatest(coalesce((p_filter->>'limit')::int, 300), 1), 2000); v_today date;
begin
  m := private.require(p_org, null);
  v_cost := private.can_see_costs(p_org);
  v_today := private.local_day(p_org, now());
  return jsonb_build_object(
    'rows', (select coalesce(jsonb_agg(r order by (r->>'created_at')::timestamptz desc), '[]'::jsonb) from (
      select jsonb_build_object('id', s.id, 'doc_type', s.doc_type, 'number', s.number, 'status', s.status, 'customer_id', s.customer_id,
        'customer_name', s.customer_name, 'customer_phone', s.customer_phone, 'customer_email', s.customer_email, 'location_id', s.location_id, 'channel', s.channel,
        'issue_date', s.issue_date, 'due_date', s.due_date, 'total', s.total, 'subtotal', s.subtotal, 'vat_total', s.vat_total, 'discount_total', s.discount_total,
        'amount_paid', s.amount_paid, 'credited', s.credited, 'confirmed', s.journal_id is not null, 'delivery_method', s.delivery_method,
        'balance', case when s.doc_type in ('receipt', 'invoice', 'order') and s.status not in ('void', 'draft', 'converted', 'cancelled') then s.total - s.amount_paid - s.credited
                        when s.doc_type = 'credit_note' then s.total - s.credited else 0 end,
        'cost_total', case when v_cost then (select sum(cost) from sale_lines where sale_id = s.id) end, 'created_at', s.created_at,
        'created_by_name', (select display_name from members where id = s.created_by),
        'shift_id', s.shift_id, 'sent_at', s.sent_at, 'viewed_at', s.viewed_at, 'public_token', s.public_token, 'reference', s.reference,
        'original_sale_id', s.original_sale_id, 'export', s.export, 'customer_country', s.customer_country, 'pay_later', s.pay_later,
        'vat_statuses', (select coalesce(jsonb_agg(distinct l.vat_status), '[]'::jsonb) from sale_lines l where l.sale_id = s.id),
        'pending', (select coalesce(sum(a.amount), 0) from collection_allocations a join collections c on c.id = a.collection_id where a.sale_id = s.id and c.status = 'pending'),
        'overdue_days', case when s.status in ('open', 'partially_paid') and s.due_date is not null then greatest(v_today - s.due_date, 0) end) r
      from sales s
      where s.org_id = p_org
        and (nullif(p_filter->>'doc_type', '') is null or s.doc_type = any(string_to_array(p_filter->>'doc_type', ',')))
        and (nullif(p_filter->>'status', '') is null or s.status = any(string_to_array(p_filter->>'status', ',')))
        and (nullif(p_filter->>'customer_id', '') is null or s.customer_id = (p_filter->>'customer_id')::uuid)
        and (nullif(p_filter->>'location_id', '') is null or s.location_id = (p_filter->>'location_id')::uuid)
        and (nullif(p_filter->>'shift_id', '') is null or s.shift_id = (p_filter->>'shift_id')::uuid)
        and (nullif(p_filter->>'vat_status', '') is null or exists (select 1 from sale_lines l where l.sale_id = s.id and l.vat_status = (p_filter->>'vat_status')::smallint))
        and (v_from is null or s.issue_date >= v_from) and (v_to is null or s.issue_date <= v_to)
        and (v_q is null or lower(s.number) like '%' || v_q || '%' or lower(s.customer_name) like '%' || v_q || '%' or coalesce(s.customer_phone, '') like '%' || v_q || '%'
             or lower(coalesce(s.reference, '')) like '%' || v_q || '%')
      order by s.created_at desc limit v_lim) x),
    'pending_payments', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'number', c.number, 'method', c.method, 'amount', c.amount, 'reference', c.reference,
        'customer_id', c.customer_id, 'customer_name', cu.name, 'received_at', c.received_at, 'note', c.note, 'bank_account_id', c.bank_account_id,
        'created_by_name', (select display_name from members where id = c.created_by),
        'sales', (select jsonb_agg(jsonb_build_object('id', s2.id, 'number', s2.number, 'amount', a.amount)) from collection_allocations a join sales s2 on s2.id = a.sale_id
                  where a.collection_id = c.id)) order by c.received_at), '[]'::jsonb)
      from collections c join customers cu on cu.id = c.customer_id where c.org_id = p_org and c.status = 'pending'),
    'orders_waiting', (select count(*) from sales where org_id = p_org and doc_type = 'order' and journal_id is null and status not in ('cancelled', 'void')));
end $$;

-- ---------------------------------------------------------------------------
-- 5. Messages: copies to the customer's other addresses; the email carries the business's branding
-- ---------------------------------------------------------------------------
create or replace function private.queue_message(p_org uuid, p_channel text, p_to text, p_template text, p_subject text, p_params jsonb, p_sale uuid,
  p_customer uuid, p_by uuid) returns public.messages
language plpgsql security definer set search_path = public, private as $$
declare msg public.messages; v_to text; v_cc text[];
begin
  if p_channel = 'whatsapp' then
    v_to := private.clean_phone(p_to);
    if v_to is null or length(v_to) < 11 then raise exception 'Add a WhatsApp number for the customer.'; end if;
  elsif p_channel = 'email' then
    v_to := lower(trim(p_to));
    if v_to is null or v_to !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Add an email address for the customer.'; end if;
    if p_customer is not null then
      select array(select e from unnest(cc_emails) e where e <> v_to) into v_cc from customers where id = p_customer;
    end if;
  else
    raise exception 'Send by email or WhatsApp.';
  end if;
  if (select count(*) from messages where org_id = p_org and created_at > now() - interval '1 hour') >= 500 then
    raise exception 'Too many messages this hour. Try again later.';
  end if;
  insert into messages (org_id, channel, to_address, template, subject, params, sale_id, customer_id, created_by)
  values (p_org, p_channel, v_to, p_template, p_subject,
    coalesce(p_params, '{}'::jsonb) || case when coalesce(array_length(v_cc, 1), 0) > 0 then jsonb_build_object('cc', to_jsonb(v_cc)) else '{}'::jsonb end,
    p_sale, p_customer, p_by) returning * into msg;
  perform private.call_function('messaging', jsonb_build_object('message_id', msg.id));
  return msg;
end $$;

create or replace function public.svc_message(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare msg public.messages;
begin
  update messages set status = 'sending', attempts = attempts + 1, updated_at = now() where id = p_id and status in ('queued', 'failed') and attempts < 5
  returning * into msg;
  if not found then return null; end if;
  return to_jsonb(msg) || jsonb_build_object('org', private.org_brand(msg.org_id));
end $$;

-- ---------------------------------------------------------------------------
-- 6. The shop: branding, a checkout that asks how to pay, and order tracking on the order's own page
-- ---------------------------------------------------------------------------
create or replace function public.shop_catalog(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs;
begin
  select * into o from orgs where shop_slug = lower(trim(p_slug)) and shop_enabled;
  if not found then raise exception 'This shop is not open.'; end if;
  return jsonb_build_object(
    'shop', jsonb_build_object('slug', o.shop_slug, 'name', o.name, 'title', coalesce(o.shop_title, o.name), 'note', o.shop_note, 'whatsapp', o.shop_whatsapp,
      'phone', o.phone, 'email', o.email, 'address', o.address, 'website', o.website, 'logo_path', o.logo_path, 'banner_path', o.shop_banner_path,
      'tagline', o.shop_tagline, 'brand_color', o.brand_color, 'socials', o.shop_socials, 'delivery_fee', o.shop_delivery_fee, 'pickup', o.shop_pickup,
      'delivery', o.shop_delivery, 'pay_on_delivery', o.shop_pay_on_delivery, 'min_order', o.shop_min_order,
      'pickup_address', (select coalesce(nullif(l.address, ''), o.address) from locations l where l.id = coalesce(o.shop_location_id,
        (select id from locations where org_id = o.id order by is_main desc, created_at limit 1))),
      'vat_registered', o.vat_registered, 'prices_include_vat', o.prices_include_vat,
      'online_payments', exists (select 1 from wallets w where w.org_id = o.id and w.rail = o.payment_rail and w.status = 'active')),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'category', i.category, 'brand', i.brand, 'description', i.description,
        'price', i.price, 'unit', i.selling_unit, 'photo_path', i.photo_path,
        'available', coalesce(st.qty, 0) > 0,
        'stock', case when o.shop_show_stock then greatest(floor(coalesce(st.qty, 0)), 0) end) order by i.category nulls last, i.name), '[]'::jsonb)
      from items i
      left join (select item_id, sum(qty) qty from stock_levels where org_id = o.id and (o.shop_location_id is null or location_id = o.shop_location_id) group by item_id) st
        on st.item_id = i.id
      where i.org_id = o.id and not i.archived and i.price > 0 and i.item_type in ('merchandise', 'finished_good')
        and (o.shop_categories is null or i.category = any(o.shop_categories))));
end $$;

-- p_order: {customer:{name, phone, email}, lines:[{item_id, qty}], delivery_method: 'pickup'|'delivery', address, city, state, note,
--           payment: 'now'|'later', client_uuid}
create or replace function public.shop_place_order(p_slug text, p_order jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; v_phone text := private.clean_phone(p_order->'customer'->>'phone'); v_cust uuid; s public.sales; x jsonb; v_lines jsonb := '[]'::jsonb;
  v_loc uuid; v_method text := coalesce(nullif(p_order->>'delivery_method', ''), 'pickup'); m public.members; v_avail numeric; it public.items;
  v_email text := nullif(lower(trim(p_order->'customer'->>'email')), ''); v_later boolean := coalesce(p_order->>'payment', 'now') = 'later';
  v_addr text; v_goods numeric := 0;
begin
  select * into o from orgs where shop_slug = lower(trim(p_slug)) and shop_enabled;
  if not found then raise exception 'This shop is not open.'; end if;
  if nullif(p_order->>'client_uuid', '') is not null then
    select * into s from sales where client_uuid = (p_order->>'client_uuid')::uuid and org_id = o.id;
    if found then return jsonb_build_object('number', s.number, 'token', s.public_token, 'total', s.total, 'duplicate', true, 'pay_later', s.pay_later); end if;
  end if;
  if coalesce(trim(p_order->'customer'->>'name'), '') = '' then raise exception 'Enter your name.'; end if;
  if v_phone is null or length(v_phone) < 11 then raise exception 'Enter a phone number we can reach you on.'; end if;
  if v_email is not null and v_email !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' then raise exception 'Check your email address.'; end if;
  if v_method not in ('pickup', 'delivery') or (v_method = 'pickup' and not o.shop_pickup) or (v_method = 'delivery' and not o.shop_delivery) then
    raise exception 'Choose pickup or delivery.';
  end if;
  v_addr := nullif(concat_ws(', ', nullif(trim(p_order->>'address'), ''), nullif(trim(p_order->>'city'), ''), nullif(trim(p_order->>'state'), '')), '');
  if v_method = 'delivery' and coalesce(trim(p_order->>'address'), '') = '' then raise exception 'Enter the delivery address.'; end if;
  if v_later and not o.shop_pay_on_delivery then raise exception 'This shop takes payment when you order.'; end if;
  -- Slow down floods: five orders an hour from one phone, sixty every ten minutes for the shop.
  if (select count(*) from shop_hits where org_id = o.id and phone = v_phone and at > now() - interval '1 hour') >= 5
     or (select count(*) from shop_hits where org_id = o.id and at > now() - interval '10 minutes') >= 60 then
    raise exception 'Too many orders just now. Please try again in a little while, or message the shop.';
  end if;
  if jsonb_typeof(p_order->'lines') <> 'array' or jsonb_array_length(p_order->'lines') = 0 then raise exception 'Your cart is empty.'; end if;
  if jsonb_array_length(p_order->'lines') > 50 then raise exception 'Up to 50 different items per order.'; end if;
  insert into shop_hits (org_id, phone) values (o.id, v_phone);
  v_loc := coalesce(o.shop_location_id, (select id from locations where org_id = o.id order by is_main desc, created_at limit 1));
  for x in select * from jsonb_array_elements(p_order->'lines') loop
    select * into it from items where id = nullif(x->>'item_id', '')::uuid and org_id = o.id and not archived and price > 0 and item_type in ('merchandise', 'finished_good');
    if not found then raise exception 'An item in your cart is no longer for sale.'; end if;
    if coalesce(private.num(x->>'qty'), 0) <= 0 or private.num(x->>'qty') > 10000 then raise exception 'Check the quantity of %.', it.name; end if;
    select coalesce(sum(qty), 0) into v_avail from stock_levels where item_id = it.id and (o.shop_location_id is null or location_id = o.shop_location_id);
    if v_avail < private.num(x->>'qty') then
      raise exception 'Only % of % left.', private.fmt_qty(greatest(v_avail, 0)), it.name;
    end if;
    v_goods := v_goods + round(private.num(x->>'qty') * it.price, 2);
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('item_id', it.id, 'qty', round(private.num(x->>'qty'), 3)));
  end loop;
  if o.shop_min_order > 0 and v_goods < o.shop_min_order then
    raise exception 'The smallest order is ₦%.', to_char(o.shop_min_order, 'FM999,999,999,990.00');
  end if;
  select id into v_cust from customers where org_id = o.id and phone = v_phone and not archived;
  if v_cust is null then
    insert into customers (org_id, name, kind, phone, email, address, city, state, whatsapp_opt_in, notes)
    values (o.id, left(trim(p_order->'customer'->>'name'), 120), 'individual', v_phone, v_email,
      nullif(trim(p_order->>'address'), ''), nullif(trim(p_order->>'city'), ''), nullif(trim(p_order->>'state'), ''), true, 'Added by an online order')
    returning id into v_cust;
  else
    update customers set email = coalesce(email, v_email), address = coalesce(address, nullif(trim(p_order->>'address'), '')),
      city = coalesce(city, nullif(trim(p_order->>'city'), '')), state = coalesce(state, nullif(trim(p_order->>'state'), ''))
    where id = v_cust;
  end if;
  -- The shop writes the order, not a staff member: it carries no permissions and no author until someone confirms it.
  s := private.create_sale(o.id, jsonb_build_object('doc_type', 'order', 'status', 'draft', 'customer_id', v_cust, 'location_id', v_loc, 'channel', 'online',
    'retail_only', true, 'lines', v_lines, 'delivery_fee', case when v_method = 'delivery' then o.shop_delivery_fee else 0 end, 'delivery_method', v_method,
    'delivery_address', case when v_method = 'delivery' then v_addr end, 'notes', left(nullif(trim(p_order->>'note'), ''), 500),
    'client_uuid', nullif(p_order->>'client_uuid', '')), m);
  update sales set pay_later = v_later, customer_email = coalesce(v_email, customer_email) where id = s.id returning * into s;
  perform private.notify_perm(o.id, 'record_sales', 'order', 'New online order ' || s.number,
    s.customer_name || ' · ₦' || to_char(s.total, 'FM999,999,999,990.00') || case when v_method = 'delivery' then ' · delivery' else ' · pickup' end
    || case when v_later then ' · pays on ' || case when v_method = 'delivery' then 'delivery' else 'pickup' end else '' end,
    '/sell/orders', 'order-' || s.id, null, v_loc);
  return jsonb_build_object('number', s.number, 'token', s.public_token, 'total', s.total, 'vat', s.vat_total, 'status', s.status, 'pay_later', s.pay_later);
end $$;

-- A shared receipt, invoice, quote, order or credit note, opened by its link. No costs and no staff details.
-- Orders also say where they are: received, confirmed, on the way, delivered or ready to collect.
create or replace function public.public_document(p_token text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; v jsonb; d public.deliveries;
begin
  if p_token is null or length(p_token) < 24 then raise exception 'Document not found.'; end if;
  select * into s from sales where public_token = p_token;
  if not found or s.status = 'draft' then raise exception 'Document not found.'; end if;
  if s.viewed_at is null then update sales set viewed_at = now() where id = s.id; end if;
  v := private.sale_json(s.id, false);
  select * into d from deliveries where sale_id = s.id and status <> 'cancelled' order by created_at desc limit 1;
  return (v - 'created_by' - 'voided_by' - 'shift_id' - 'device_id' - 'client_uuid' - 'journal_id' - 'journal_ref' - 'org_id' - 'cost_total' - 'location_id'
    - 'price_list_id' - 'created_by_name' - 'deliveries' - 'refunds' - 'void_reason' - 'offline' - 'customer_credit' - 'export_note')
    || jsonb_build_object(
      'lines', (select coalesce(jsonb_agg(l - 'cost' - 'item_id' - 'revenue_account' - 'list_price' - 'original_line_id' - 'returned_qty' - 'sale_id' - 'id'
          order by (l->>'line_no')::int), '[]'::jsonb) from jsonb_array_elements(v->'lines') l),
      'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', p->>'method', 'amount', p->'amount', 'status', p->>'status', 'received_at', p->'received_at')), '[]'::jsonb)
        from jsonb_array_elements(v->'payments') p where p->>'status' in ('confirmed', 'pending')),
      'requests', (select coalesce(jsonb_agg(r - 'id'), '[]'::jsonb) from jsonb_array_elements(v->'requests') r where r->>'status' = 'pending'),
      'shop_slug', (select shop_slug from orgs where id = s.org_id and shop_enabled),
      'tracking', case when s.doc_type = 'order' then jsonb_build_object(
        'placed_at', s.created_at, 'confirmed', s.journal_id is not null, 'confirmed_at', s.issued_at, 'method', s.delivery_method,
        'cancelled', s.status in ('cancelled', 'void'),
        'delivery_status', d.status, 'scheduled_for', d.scheduled_for, 'dispatched_at', d.dispatched_at, 'delivered_at', d.delivered_at,
        'pickup_address', case when s.delivery_method = 'pickup' then (select coalesce(nullif(l.address, ''), o.address) from locations l join orgs o on o.id = l.org_id where l.id = s.location_id) end)
      end);
end $$;

-- ---------------------------------------------------------------------------
-- 7. Grants
-- ---------------------------------------------------------------------------
revoke all on function public.update_branding(uuid, jsonb), public.set_sale_export(uuid, boolean, text) from public, anon;
grant execute on function public.update_branding(uuid, jsonb), public.set_sale_export(uuid, boolean, text) to authenticated;
revoke all on function private.org_brand(uuid), private.clean_emails(jsonb), private.sale_export_snapshot() from public, anon, authenticated;
grant execute on function public.shop_catalog(text), public.shop_place_order(text, jsonb), public.public_document(text) to anon, authenticated;
