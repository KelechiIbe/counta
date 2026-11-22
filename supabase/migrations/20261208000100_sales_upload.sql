-- Sales uploaded from another system, kept as Counta's own books.
--
-- A business that sells through another POS or sales system exports its sales each month (CSV or Excel) and uploads them.
-- The sales schedule upload under VAT posted one receipt a day for the VAT return only. An upload now posts each sale as a
-- Counta sale, through the same steps as a sale made in Counta:
-- - Each product is matched to a Counta item (by a name it has had before, its own name, or the person's choice), so stock
--   goes out and cost of sales is booked at average cost; a product the business does not stock is a line with no item.
--   When a row gives only the sale's total, the total is shared over its products by their selling prices (or the prices
--   the file itself shows for them).
-- - Each way of paying goes where its money is: cash to the branch's cash, card and POS payments to 9002 Bank clearing
--   until the bank shows the provider's settlement (one payment, or a day's payments together, less up to 2% in charges),
--   transfers waiting for the bank line that confirms them (or straight into the account when the person says so).
-- - A sale not paid in full is an invoice to the customer named on it, owed on their account until they pay.
-- - Discounts reduce the sale; a return is a credit note on the sale it returns, dated when it happened, with the stock
--   back and the refund paid from where the person says.
-- - The amounts are what customers paid, so the VAT is worked out inside them, on each product's own treatment.
-- Every sale keeps the key it came with (its receipt number, else a fingerprint of the row), so a row already uploaded is
-- never posted twice, whichever file it comes in. Months whose VAT return is filed take no uploaded sales. A whole upload
-- can be undone while its months are open.

-- ---------------------------------------------------------------------------
-- 1. Uploads, their rows, product names and file layouts
-- ---------------------------------------------------------------------------
create table if not exists public.sales_imports (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  number text not null,
  file_name text,
  source text,
  layout text not null default 'per_sale' check (layout in ('per_sale', 'per_line')),
  location_id uuid references public.locations(id) on delete set null,
  settings jsonb not null default '{}'::jsonb,
  status text not null default 'posting' check (status in ('posting', 'posted', 'void')),
  rows_total int not null default 0,
  sales int not null default 0,
  returns int not null default 0,
  skipped int not null default 0,
  failed int not null default 0,
  amount numeric(16,2) not null default 0,
  vat numeric(16,2) not null default 0,
  date_from date,
  date_to date,
  summary jsonb,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  posted_at timestamptz,
  voided_by uuid references public.members(id) on delete set null,
  voided_at timestamptz,
  void_reason text,
  unique (org_id, number)
);
create index if not exists sales_imports_org on public.sales_imports(org_id, created_at desc);
create index if not exists sales_imports_location_fk on public.sales_imports(location_id);
create index if not exists sales_imports_created_by_fk on public.sales_imports(created_by);
create index if not exists sales_imports_voided_by_fk on public.sales_imports(voided_by);

create table if not exists public.sales_import_rows (
  id uuid primary key default gen_random_uuid(),
  import_id uuid not null references public.sales_imports(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  row_no int not null,
  source_key text not null,
  receipt text,
  kind text not null default 'sale' check (kind in ('sale', 'return')),
  status text not null check (status in ('posted', 'duplicate', 'failed', 'void')),
  sale_id uuid references public.sales(id) on delete set null,
  collection_ids uuid[],
  amount numeric(16,2),
  error text,
  created_at timestamptz not null default now()
);
-- A key is posted once per business.
create unique index if not exists sales_import_rows_key on public.sales_import_rows(org_id, source_key) where status = 'posted';
create index if not exists sales_import_rows_import on public.sales_import_rows(import_id, row_no);
create index if not exists sales_import_rows_receipt on public.sales_import_rows(org_id, receipt) where receipt is not null and status = 'posted';
create index if not exists sales_import_rows_sale_fk on public.sales_import_rows(sale_id);

-- What a product name from the other system is in Counta: an item, or a line with no item.
create table if not exists public.sales_import_products (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  key text not null check (key <> ''),
  name text not null,
  mode text not null check (mode in ('item', 'non_stock')),
  item_id uuid references public.items(id) on delete cascade,
  vat_treatment text check (vat_treatment in ('standard', 'zero', 'exempt')),
  decided_by uuid references public.members(id) on delete set null,
  updated_at timestamptz not null default now(),
  unique (org_id, key),
  check (mode = 'non_stock' or item_id is not null)
);
create index if not exists sales_import_products_item_fk on public.sales_import_products(item_id);
create index if not exists sales_import_products_decided_by_fk on public.sales_import_products(decided_by);

-- The columns of a file layout the business has uploaded before (keyed by its headers), and how its ways of paying map.
create table if not exists public.sales_import_formats (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  signature text not null,
  name text,
  layout text not null default 'per_sale' check (layout in ('per_sale', 'per_line')),
  mapping jsonb not null default '{}'::jsonb,
  methods jsonb not null default '{}'::jsonb,
  branches jsonb not null default '{}'::jsonb,
  updated_by uuid references public.members(id) on delete set null,
  updated_at timestamptz not null default now(),
  unique (org_id, signature)
);
create index if not exists sales_import_formats_updated_by_fk on public.sales_import_formats(updated_by);

alter table public.sales_imports enable row level security;
alter table public.sales_import_rows enable row level security;
alter table public.sales_import_products enable row level security;
alter table public.sales_import_formats enable row level security;
drop policy if exists sales_imports_read on public.sales_imports;
create policy sales_imports_read on public.sales_imports for select to authenticated using ((select private.can_handle_money(org_id)));
drop policy if exists sales_import_rows_read on public.sales_import_rows;
create policy sales_import_rows_read on public.sales_import_rows for select to authenticated using ((select private.can_handle_money(org_id)));
revoke insert, update, delete on public.sales_imports, public.sales_import_rows from anon, authenticated;
revoke all on public.sales_imports, public.sales_import_rows from anon;
revoke all on public.sales_import_products, public.sales_import_formats from anon, authenticated;
select private.activity_attach('public.sales_imports');
select private.activity_attach('public.sales_import_rows');
select private.activity_attach('public.sales_import_products');
select private.activity_attach('public.sales_import_formats');

-- A card or POS payment held in 9002 is marked when the bank line that settles it comes in.
alter table public.collections add column if not exists cleared_line_id uuid references public.bank_lines(id) on delete set null;
create index if not exists collections_cleared_line_fk on public.collections(cleared_line_id) where cleared_line_id is not null;
create index if not exists collections_clearing_waiting on public.collections(org_id, received_at)
  where via_account is not null and cleared_line_id is null and status = 'confirmed';

-- Who uploads sales: they set prices, discounts and credit, so someone who approves adjustments (a manager, an accountant
-- or the owner).
create or replace function private.require_sales_upload(p_org uuid) returns public.members
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not coalesce(private.perm_of(m, 'approve_adjustments'), false) then
    raise exception 'Uploading sales needs a manager, an accountant or the owner (someone who approves adjustments).' using errcode = '42501';
  end if;
  if (select read_only_at is not null from orgs where id = p_org) then raise exception 'This business is read-only.'; end if;
  return m;
end $$;

-- The words of a product name as they are matched.
create or replace function private.product_key(p text) returns text
language sql immutable set search_path = public, private as $$
  select left(lower(regexp_replace(trim(coalesce(p, '')), '\s+', ' ', 'g')), 200)
$$;

-- A month whose VAT return is filed takes no uploaded sale or return.
create or replace function private.require_unfiled_month(p_org uuid, p_day date) returns void
language plpgsql stable security definer set search_path = public, private as $$
begin
  if exists (select 1 from vat_periods where org_id = p_org and period = date_trunc('month', p_day)::date) then
    raise exception 'The VAT return for % is filed. Reopen it to add sales to that month.', to_char(p_day, 'FMMonth YYYY');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Before the upload: what Counta already knows
-- ---------------------------------------------------------------------------
-- p: {names: [product names], keys: [row keys], signature, from, to}. Returns the products already decided or matching an
-- item by name, the keys already posted, the saved layout for these headers, the branches, the money accounts, the months
-- in range whose VAT return is filed, and the sales schedules already posted for those days (their sales would count twice).
create or replace function public.sales_import_prepare(p_org uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_from date := nullif(p->>'from', '')::date; v_to date := nullif(p->>'to', '')::date;
begin
  m := private.require_sales_upload(p_org);
  return jsonb_build_object(
    'products', (select coalesce(jsonb_agg(jsonb_build_object('name', n.name, 'key', n.k,
        'mode', coalesce(sp.mode, case when it.id is not null then 'item' end), 'item_id', coalesce(sp.item_id, it.id),
        'item_name', coalesce(spi.name, it.name), 'vat_treatment', coalesce(sp.vat_treatment, spi.vat_treatment, it.vat_treatment),
        'price', coalesce(spi.price, it.price),
        'how', case when sp.id is not null then 'saved' when it.id is not null then 'name' end)), '[]'::jsonb)
      from (select distinct on (private.product_key(x)) x name, private.product_key(x) k from jsonb_array_elements_text(coalesce(p->'names', '[]'::jsonb)) x
            where private.product_key(x) <> '') n
      left join sales_import_products sp on sp.org_id = p_org and sp.key = n.k
      left join items spi on spi.id = sp.item_id and not spi.archived
      left join lateral (select i.id, i.name, i.vat_treatment, i.price from items i where i.org_id = p_org and not i.archived and private.product_key(i.name) = n.k
                         order by i.created_at limit 1) it on sp.id is null),
    'posted', (select coalesce(jsonb_agg(r.source_key), '[]'::jsonb) from sales_import_rows r
      where r.org_id = p_org and r.status = 'posted' and r.source_key in (select jsonb_array_elements_text(coalesce(p->'keys', '[]'::jsonb)))),
    'format', (select to_jsonb(f) - 'org_id' - 'updated_by' from sales_import_formats f where f.org_id = p_org and f.signature = p->>'signature'),
    'locations', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'is_main', l.is_main) order by l.is_main desc, l.name), '[]'::jsonb)
      from locations l where l.org_id = p_org),
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'kind', b.kind, 'bank_name', b.bank_name,
        'location_id', b.location_id) order by b.kind, b.name), '[]'::jsonb)
      from bank_accounts b where b.org_id = p_org and b.active),
    'filed_months', (select coalesce(jsonb_agg(vp.period order by vp.period), '[]'::jsonb) from vat_periods vp
      where vp.org_id = p_org and v_from is not null and vp.period between date_trunc('month', v_from)::date and coalesce(v_to, v_from)),
    'schedules', (select coalesce(jsonb_agg(jsonb_build_object('id', sc.id, 'number', sc.number, 'from', sc.date_from, 'to', sc.date_to, 'amount', sc.amount)
        order by sc.date_from), '[]'::jsonb)
      from sales_schedules sc where sc.org_id = p_org and sc.status = 'posted' and v_from is not null
        and sc.date_from <= coalesce(v_to, v_from) and sc.date_to >= v_from),
    'closed_through', private.closed_through(p_org),
    'vat_registered', (select vat_registered from orgs where id = p_org),
    'can_create_items', coalesce(private.perm_of(m, 'edit_prices'), false));
end $$;

-- The person's decisions on product names: [{name, mode: 'item'|'non_stock', item_id, vat_treatment}].
create or replace function public.save_sales_import_products(p_org uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; x jsonb; v_key text; v_n int := 0;
begin
  m := private.require_sales_upload(p_org);
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) > 2000 then raise exception 'Send up to 2,000 products at a time.'; end if;
  for x in select * from jsonb_array_elements(p_rows) loop
    v_key := private.product_key(x->>'name');
    continue when v_key = '';
    if x->>'mode' = 'item' then
      if not exists (select 1 from items where id = nullif(x->>'item_id', '')::uuid and org_id = p_org and not archived) then
        raise exception 'Choose a Counta item for "%".', x->>'name';
      end if;
    elsif coalesce(x->>'mode', '') <> 'non_stock' then
      raise exception 'Say what "%" is: one of your items, or a sale with no stock.', x->>'name';
    end if;
    if nullif(x->>'vat_treatment', '') is not null and x->>'vat_treatment' not in ('standard', 'zero', 'exempt') then raise exception 'Unknown VAT treatment.'; end if;
    insert into sales_import_products (org_id, key, name, mode, item_id, vat_treatment, decided_by)
    values (p_org, v_key, left(trim(x->>'name'), 200), x->>'mode', case when x->>'mode' = 'item' then (x->>'item_id')::uuid end,
      case when x->>'mode' = 'non_stock' then coalesce(nullif(x->>'vat_treatment', ''), 'standard') end, m.id)
    on conflict (org_id, key) do update set name = excluded.name, mode = excluded.mode, item_id = excluded.item_id, vat_treatment = excluded.vat_treatment,
      decided_by = excluded.decided_by, updated_at = now();
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('saved', v_n);
end $$;

-- ---------------------------------------------------------------------------
-- 3. One uploaded sale
-- ---------------------------------------------------------------------------
-- r: {row, key, receipt, at, day, location_id, customer: {name, phone, email, tin}, total, discount, sold_by, note,
--     lines: [{name, item_id, non_stock, qty, unit_price, discount, vat_treatment, price_hint}],
--     payments: [{method: cash|card|pos|transfer|cheque|other, amount, account_id, confirmed}]}
-- total: what the customer paid for the sale (after its discount). It may be left out when every line has a unit price.
-- Returns {sale_id, number, doc_type, total, vat, collections}.
create or replace function private.import_sale(imp public.sales_imports, r jsonb, m public.members) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; s public.sales; c public.customers; v_day date; v_at timestamptz; v_loc uuid; v_cust uuid; v_total numeric; v_disc numeric;
  x jsonb; it public.items; sp public.sales_import_products; v_lines jsonb := '[]'::jsonb; v_raw jsonb := '[]'::jsonb; v_priced boolean := true;
  v_base numeric; v_w numeric; v_wsum numeric; v_wqty numeric; v_n int; v_i int := 0; v_amt numeric; v_alloc numeric := 0; v_unit numeric; v_qty numeric;
  v_sum numeric := 0; v_cart numeric; v_paid numeric := 0; t jsonb; v_method text; v_bank uuid; v_status text; v_doc text; v_name text; v_email text;
  v_clear text; v_note text; v_cash numeric := 0; v_change numeric := 0; col public.collections; v_cols uuid[] := '{}'; v_hint numeric; v_list numeric;
begin
  select * into o from orgs where id = imp.org_id;
  v_at := nullif(r->>'at', '')::timestamptz;
  v_day := coalesce(nullif(r->>'day', '')::date, private.local_day(o.id, v_at));
  if v_day is null then raise exception 'The sale has no date.'; end if;
  if v_day > private.local_day(o.id, now()) then raise exception 'A sale cannot be dated in the future.'; end if;
  v_at := least(coalesce(v_at, private.posting_time(o.id, v_day)), now());
  perform private.require_open_day(o.id, v_day);
  perform private.require_unfiled_month(o.id, v_day);
  v_loc := coalesce(nullif(r->>'location_id', '')::uuid, imp.location_id, private.main_location(o.id));
  if not exists (select 1 from locations where id = v_loc and org_id = o.id) then raise exception 'Choose the branch for this sale.'; end if;
  v_total := round(private.num(r->>'total'), 2);
  v_disc := round(greatest(coalesce(private.num(r->>'discount'), 0), 0), 2);
  if v_total is not null and v_total <= 0 then raise exception 'The sale''s total must be above zero.'; end if;

  -- The customer: named (matched by phone, then by name, else added), else the walk-in customer.
  v_name := left(nullif(trim(r->'customer'->>'name'), ''), 120);
  if v_name is not null and lower(v_name) ~ '^(walk[ -]?in|walkin|cash|guest|customer)( customer)?s?$' then v_name := null; end if;
  if v_name is not null then
    if private.clean_phone(r->'customer'->>'phone') is not null then
      select id into v_cust from customers where org_id = o.id and not archived and phone = private.clean_phone(r->'customer'->>'phone') limit 1;
    end if;
    if v_cust is null then
      select id into v_cust from customers where org_id = o.id and not archived and not is_walk_in and lower(name) = lower(v_name) order by created_at limit 1;
    end if;
    if v_cust is null then
      v_email := nullif(lower(trim(r->'customer'->>'email')), '');
      if v_email !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' then v_email := null; end if;
      v_cust := private.upsert_customer(o.id, jsonb_strip_nulls(jsonb_build_object('name', v_name, 'phone', private.clean_phone(r->'customer'->>'phone'),
        'email', v_email, 'tin', nullif(trim(r->'customer'->>'tin'), ''),
        'kind', case when nullif(trim(r->'customer'->>'tin'), '') is not null or v_name ~* '\m(ltd|limited|plc|enterprises?|ventures|company)\M' then 'business' else 'individual' end)), m);
    end if;
  else
    v_cust := private.walk_in(o.id);
  end if;
  select * into c from customers where id = v_cust;

  -- The products: a Counta item (from the line, the name the person mapped, or the item's own name), else a line with no item.
  for x in select * from jsonb_array_elements(coalesce(r->'lines', '[]'::jsonb)) loop
    v_qty := round(coalesce(private.num(x->>'qty'), 1), 3);
    if v_qty <= 0 then raise exception 'Every product needs a quantity above zero.'; end if;
    it := null; sp := null;
    if nullif(x->>'item_id', '') is not null then
      select * into it from items where id = (x->>'item_id')::uuid and org_id = o.id and not archived;
      if it.id is null then raise exception 'An item on this sale no longer exists.'; end if;
    elsif not coalesce((x->>'non_stock')::boolean, false) then
      select * into sp from sales_import_products where org_id = o.id and key = private.product_key(x->>'name');
      if sp.mode = 'item' then select * into it from items where id = sp.item_id and not archived; end if;
      if it.id is null and sp.id is null then
        select * into it from items where org_id = o.id and not archived and private.product_key(name) = private.product_key(x->>'name') order by created_at limit 1;
      end if;
      if it.id is null and coalesce(sp.mode, 'item') = 'item' then
        raise exception '"%" is not a Counta item yet. Match it to one, or record it with no stock.', x->>'name';
      end if;
    end if;
    if it.id is null and coalesce(trim(x->>'name'), '') = '' then raise exception 'A product on this sale has no name.'; end if;
    v_unit := round(private.num(x->>'unit_price'), 2);
    if v_unit is null then v_priced := false; end if;
    v_hint := greatest(coalesce(private.num(x->>'price_hint'), 0), 0);
    v_list := case when it.id is not null then greatest(coalesce(private.list_price(o.id, it.id, null, v_qty), 0), 0) else 0 end;
    v_raw := v_raw || jsonb_build_object('item_id', it.id, 'name', coalesce(it.name, left(trim(x->>'name'), 300)), 'qty', v_qty, 'unit_price', v_unit,
      'discount', round(greatest(coalesce(private.num(x->>'discount'), 0), 0), 2),
      'vat', coalesce(nullif(x->>'vat_treatment', ''), sp.vat_treatment, 'standard'),
      'weight', case when v_list > 0 then v_list when v_hint > 0 then v_hint else 0 end * v_qty);
  end loop;
  v_n := jsonb_array_length(v_raw);
  if v_n = 0 then raise exception 'The sale has no products.'; end if;
  if v_n > 300 then raise exception 'A sale can have up to 300 products.'; end if;

  if not v_priced then
    -- Only the sale's total: shared over the products by their selling prices. A product with no price takes the average
    -- price of the others; when none has one, the total is shared by quantity. Rounding goes to the sale's discount, so the
    -- sale comes to its total exactly.
    if v_total is null then raise exception 'The sale has no total.'; end if;
    v_base := v_total + v_disc;
    select coalesce(sum((e->>'weight')::numeric), 0), coalesce(sum((e->>'qty')::numeric) filter (where (e->>'weight')::numeric > 0), 0)
      into v_wsum, v_wqty from jsonb_array_elements(v_raw) e;
    if v_wsum > 0 then
      for x in select * from jsonb_array_elements(v_raw) loop
        v_i := v_i + 1;
        if (x->>'weight')::numeric = 0 then
          v_raw := jsonb_set(v_raw, array[(v_i - 1)::text, 'weight'], to_jsonb(round(v_wsum / v_wqty * (x->>'qty')::numeric, 4)));
        end if;
      end loop;
      v_i := 0;
    end if;
    v_wsum := (select sum(case when v_wsum > 0 then (e->>'weight')::numeric else (e->>'qty')::numeric end) from jsonb_array_elements(v_raw) e);
    for x in select * from jsonb_array_elements(v_raw) loop
      v_i := v_i + 1;
      v_w := case when (x->>'weight')::numeric > 0 then (x->>'weight')::numeric else (x->>'qty')::numeric end / v_wsum;
      v_amt := case when v_i = v_n then v_base - v_alloc else round(v_base * v_w, 2) end;
      v_alloc := v_alloc + v_amt;
      v_unit := ceil(greatest(v_amt, 0) * 100 / (x->>'qty')::numeric) / 100;
      v_raw := jsonb_set(v_raw, array[(v_i - 1)::text, 'unit_price'], to_jsonb(v_unit));
    end loop;
    v_sum := (select coalesce(sum(round((e->>'qty')::numeric * (e->>'unit_price')::numeric, 2)), 0) from jsonb_array_elements(v_raw) e);
    v_cart := round(v_sum - v_total, 2);
  else
    v_sum := (select coalesce(sum(round((e->>'qty')::numeric * (e->>'unit_price')::numeric, 2) - (e->>'discount')::numeric), 0) from jsonb_array_elements(v_raw) e);
    v_cart := v_disc;
    v_total := coalesce(v_total, v_sum - v_cart);
  end if;
  if v_cart < 0 or v_sum - v_cart <= 0 then raise exception 'The products come to less than the sale''s total.'; end if;
  for x in select * from jsonb_array_elements(v_raw) loop
    v_lines := v_lines || case when x->>'item_id' is not null
      then jsonb_build_object('item_id', x->>'item_id', 'qty', x->'qty', 'unit_price', x->'unit_price', 'discount', x->'discount')
      else jsonb_build_object('description', x->>'name', 'qty', x->'qty', 'unit_price', x->'unit_price', 'discount', x->'discount', 'vat_treatment', x->>'vat') end;
  end loop;

  -- What was paid now. Cash above the total is change.
  for t in select * from jsonb_array_elements(coalesce(r->'payments', '[]'::jsonb)) loop
    v_amt := round(coalesce(private.num(t->>'amount'), 0), 2);
    continue when v_amt = 0;
    if v_amt < 0 then raise exception 'A payment cannot be negative.'; end if;
    if coalesce(t->>'method', '') not in ('cash', 'card', 'pos', 'transfer', 'cheque', 'other') then raise exception 'Unknown way of paying: %.', coalesce(t->>'method', '(none)'); end if;
    v_paid := v_paid + v_amt;
    if t->>'method' = 'cash' then v_cash := v_cash + v_amt; end if;
  end loop;
  if v_paid > v_total + 0.004 then
    v_change := v_paid - v_total;
    if v_cash < v_change - 0.004 then raise exception 'The payments (%) are more than the sale (%).', private.naira(v_paid), private.naira(v_total); end if;
  end if;
  v_doc := case when v_paid >= v_total - 0.004 then 'receipt' else 'invoice' end;
  if v_doc = 'invoice' and c.is_walk_in then raise exception 'A sale not paid in full needs the customer''s name, so Counta knows who owes it.'; end if;

  v_note := left(concat_ws(' · ', 'From sales upload ' || imp.number || coalesce(', row ' || (r->>'row'), ''),
    case when nullif(trim(r->>'sold_by'), '') is not null then 'Sold by ' || trim(r->>'sold_by') end, nullif(trim(r->>'note'), '')), 300);
  insert into sales (org_id, doc_type, number, status, customer_id, customer_name, customer_phone, customer_email, customer_tin, customer_address,
    location_id, channel, issue_date, due_date, prices_include_vat, vat_registered, reference, notes, created_by, created_at)
  values (o.id, v_doc, private.doc_number(o.id, v_doc), 'open', c.id, c.name, c.phone, c.email, c.tin, c.address, v_loc, 'schedule', v_day,
    v_day + case when v_doc = 'invoice' then coalesce(nullif(c.terms_days, 0), o.invoice_terms_days, 0) else 0 end,
    true, o.vat_registered, left(nullif(trim(r->>'receipt'), ''), 60), v_note, m.id, v_at)
  returning * into s;
  s := private.write_lines(s, v_lines, v_cart, m);
  if abs(s.total - v_total) > 0.009 then
    raise exception 'The products come to % but the sale''s total is %.', private.naira(s.total), private.naira(v_total);
  end if;
  s := private.post_sale(s.id, m, v_at);

  -- The money: cash to the branch's cash; card and POS to 9002 until the provider settles; transfers wait for the bank line
  -- (or go straight in when the person said they are already in the account).
  v_clear := private.acct(o.id, 'bank_clearing');
  for t in select * from jsonb_array_elements(coalesce(r->'payments', '[]'::jsonb)) loop
    v_method := t->>'method';
    v_amt := round(coalesce(private.num(t->>'amount'), 0), 2);
    continue when v_amt <= 0;
    if v_method = 'cash' and v_change > 0 then
      v_unit := least(v_change, v_amt);
      v_amt := v_amt - v_unit; v_change := v_change - v_unit;
      continue when v_amt <= 0;
    end if;
    v_bank := nullif(t->>'account_id', '')::uuid;
    if v_bank is not null and not exists (select 1 from bank_accounts where id = v_bank and org_id = o.id and active) then
      raise exception 'The account chosen for % payments is not available.', v_method;
    end if;
    if v_method = 'cash' then
      col := private.add_collection(o.id, c.id, v_amt, 'cash', jsonb_build_object('bank_account_id', coalesce(v_bank, (private.cash_drawer(o.id, v_loc, m)).id),
        'received_at', v_at, 'spread', false, 'reference', s.reference, 'note', 'From sales upload ' || imp.number), m, 'confirmed', array[s.id]);
    elsif v_method in ('card', 'pos') then
      col := private.add_collection(o.id, c.id, v_amt, v_method, jsonb_build_object('bank_account_id', v_bank, 'via_account', v_clear, 'received_at', v_at,
        'spread', false, 'reference', s.reference, 'note', 'From sales upload ' || imp.number || '; in clearing until the provider settles it'), m, 'confirmed', array[s.id]);
    else
      v_status := case when coalesce((t->>'confirmed')::boolean, false) and v_bank is not null then 'confirmed' else 'pending' end;
      col := private.add_collection(o.id, c.id, v_amt, v_method, jsonb_build_object('bank_account_id', v_bank, 'received_at', v_at, 'spread', false,
        'reference', s.reference, 'note', 'From sales upload ' || imp.number || case when v_status = 'pending' then '; the bank line confirms it' else '' end),
        m, v_status, array[s.id]);
    end if;
    v_cols := v_cols || col.id;
  end loop;
  s := private.refresh_sale(s.id);
  return jsonb_build_object('sale_id', s.id, 'number', s.number, 'doc_type', s.doc_type, 'total', s.total, 'vat', s.vat_total, 'collections', to_jsonb(v_cols));
end $$;

-- One uploaded return: r: {row, key, at, day, original (its receipt number in the other system, or a Counta number), reason,
-- lines: [{name, item_id, qty}], payments (the refund): [{method, amount, account_id}]}.
create or replace function private.import_return(imp public.sales_imports, r jsonb, m public.members) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; v_day date; v_at timestamptz; x jsonb; l public.sale_lines; v_lines jsonb := '[]'::jsonb; v_left numeric; v_take numeric; v_qty numeric;
  v_key text; t jsonb; v_refund jsonb := '{}'::jsonb; res jsonb; v_amt numeric := 0; v_method text; v_bank uuid; v_item uuid;
begin
  v_at := nullif(r->>'at', '')::timestamptz;
  v_day := coalesce(nullif(r->>'day', '')::date, private.local_day(imp.org_id, v_at));
  if v_day is null then raise exception 'The return has no date.'; end if;
  if v_day > private.local_day(imp.org_id, now()) then raise exception 'A return cannot be dated in the future.'; end if;
  v_at := least(coalesce(v_at, private.posting_time(imp.org_id, v_day)), now());
  perform private.require_unfiled_month(imp.org_id, v_day);
  -- The sale it returns: uploaded before with that receipt number, else a Counta sale of that number.
  select x2.* into s from sales_import_rows ir join sales x2 on x2.id = ir.sale_id
  where ir.org_id = imp.org_id and ir.status = 'posted' and ir.kind = 'sale' and ir.receipt = nullif(trim(r->>'original'), '') and x2.status <> 'void'
  order by ir.created_at desc limit 1;
  if s.id is null then
    select * into s from sales where org_id = imp.org_id and number = nullif(trim(r->>'original'), '') and doc_type in ('receipt', 'invoice');
  end if;
  if s.id is null then
    raise exception 'The sale this return is for (%) is not in Counta. Upload that sale first, or leave the return out.', coalesce(nullif(trim(r->>'original'), ''), 'no receipt number');
  end if;
  perform 1 from sales where id = s.id for update;
  -- Each returned product against the sale's lines: by item, else by words.
  for x in select * from jsonb_array_elements(coalesce(r->'lines', '[]'::jsonb)) loop
    v_qty := round(abs(coalesce(private.num(x->>'qty'), 1)), 3);
    v_key := private.product_key(x->>'name');
    v_item := coalesce(nullif(x->>'item_id', '')::uuid, (select sp.item_id from sales_import_products sp where sp.org_id = imp.org_id and sp.key = v_key and sp.mode = 'item'));
    for l in select * from sale_lines sl where sl.sale_id = s.id and sl.qty - sl.returned_qty > 0.0005
             and (sl.item_id = v_item or private.product_key(sl.description) = v_key)
             order by sl.line_no loop
      exit when v_qty <= 0.0005;
      v_left := l.qty - l.returned_qty - coalesce((select sum((e->>'qty')::numeric) from jsonb_array_elements(v_lines) e where (e->>'sale_line_id')::uuid = l.id), 0);
      v_take := least(v_left, v_qty);
      continue when v_take <= 0;
      v_lines := v_lines || jsonb_build_object('sale_line_id', l.id, 'qty', v_take);
      v_qty := v_qty - v_take;
    end loop;
    if v_qty > 0.0005 then
      raise exception '% of "%" is more than % can still take back.', private.fmt_qty(abs(coalesce(private.num(x->>'qty'), 1))), x->>'name', s.number;
    end if;
  end loop;
  if jsonb_array_length(v_lines) = 0 then raise exception 'Say which products came back.'; end if;
  for t in select * from jsonb_array_elements(coalesce(r->'payments', '[]'::jsonb)) loop
    continue when coalesce(private.num(t->>'amount'), 0) = 0;
    v_amt := v_amt + abs(round(private.num(t->>'amount'), 2));
    v_method := case when t->>'method' in ('card', 'pos') then 'other' when t->>'method' in ('cash', 'transfer', 'cheque') then t->>'method' else 'other' end;
    v_bank := coalesce(nullif(t->>'account_id', '')::uuid, v_bank);
  end loop;
  if v_amt > 0 then v_refund := jsonb_strip_nulls(jsonb_build_object('amount', v_amt, 'method', v_method, 'bank_account_id', v_bank)); end if;
  res := private.return_sale_core(s, v_lines, v_refund, left(coalesce(nullif(trim(r->>'reason'), ''), 'Return from sales upload ' || imp.number), 200), true, v_day, v_at, m);
  return jsonb_build_object('sale_id', (res->'credit_note'->>'id')::uuid, 'number', res->'credit_note'->>'number', 'doc_type', 'credit_note',
    'total', -((res->'credit_note'->>'total')::numeric), 'vat', -((res->'credit_note'->>'vat_total')::numeric), 'refunded', res->'refunded');
end $$;

-- ---------------------------------------------------------------------------
-- 4. Posting an upload
-- ---------------------------------------------------------------------------
-- p: {file_name, source, layout, location_id, signature, mapping, methods, branches, rows_total}
create or replace function public.sales_import_start(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; imp public.sales_imports;
begin
  m := private.require_sales_upload(p_org);
  if nullif(p->>'location_id', '') is not null and not exists (select 1 from locations where id = (p->>'location_id')::uuid and org_id = p_org) then
    raise exception 'Choose one of the business''s branches.';
  end if;
  if coalesce(nullif(p->>'layout', ''), 'per_sale') not in ('per_sale', 'per_line') then raise exception 'Unknown file layout.'; end if;
  insert into sales_imports (org_id, number, file_name, source, layout, location_id, settings, rows_total, created_by)
  values (p_org, 'SU-' || lpad(private.next_no(p_org, 'SU', 1)::text, 4, '0'), left(nullif(trim(p->>'file_name'), ''), 200), left(nullif(trim(p->>'source'), ''), 80),
    coalesce(nullif(p->>'layout', ''), 'per_sale'), nullif(p->>'location_id', '')::uuid,
    jsonb_strip_nulls(jsonb_build_object('methods', p->'methods', 'branches', p->'branches', 'mapping', p->'mapping')),
    least(greatest(coalesce((p->>'rows_total')::int, 0), 0), 1000000), m.id)
  returning * into imp;
  if nullif(p->>'signature', '') is not null then
    insert into sales_import_formats (org_id, signature, name, layout, mapping, methods, branches, updated_by)
    values (p_org, left(p->>'signature', 500), left(nullif(trim(p->>'source'), ''), 80), imp.layout, coalesce(p->'mapping', '{}'::jsonb),
      coalesce(p->'methods', '{}'::jsonb), coalesce(p->'branches', '{}'::jsonb), m.id)
    on conflict (org_id, signature) do update set name = coalesce(excluded.name, sales_import_formats.name), layout = excluded.layout, mapping = excluded.mapping,
      methods = excluded.methods, branches = excluded.branches, updated_by = excluded.updated_by, updated_at = now();
  end if;
  return to_jsonb(imp);
end $$;

-- Up to 100 rows at a time. Each row posts on its own: one that fails is recorded with its reason and the rest go on; a row
-- whose key is already posted is a duplicate.
create or replace function public.sales_import_batch(p_import uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare imp public.sales_imports; m public.members; r jsonb; v_key text; res jsonb; v_out jsonb := '[]'::jsonb; v_kind text; v_err text; v_cols uuid[];
begin
  select * into imp from sales_imports where id = p_import for update;
  if not found then raise exception 'Upload not found.'; end if;
  m := private.require_sales_upload(imp.org_id);
  if imp.status <> 'posting' then raise exception '% is %.', imp.number, case imp.status when 'void' then 'undone' else 'finished' end; end if;
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) > 100 then raise exception 'Send up to 100 rows at a time.'; end if;
  perform set_config('counta.quiet', 'on', true);
  for r in select * from jsonb_array_elements(p_rows) loop
    v_key := left(nullif(trim(r->>'key'), ''), 300);
    v_kind := case when r->>'kind' = 'return' then 'return' else 'sale' end;
    if v_key is null then
      v_out := v_out || jsonb_build_object('row', r->'row', 'status', 'failed', 'error', 'The row has no key.');
      continue;
    end if;
    if exists (select 1 from sales_import_rows where org_id = imp.org_id and source_key = v_key and status = 'posted') then
      insert into sales_import_rows (import_id, org_id, row_no, source_key, receipt, kind, status, error)
      values (imp.id, imp.org_id, coalesce((r->>'row')::int, 0), v_key, left(nullif(trim(r->>'receipt'), ''), 60), v_kind, 'duplicate',
        'Already uploaded in ' || (select i2.number from sales_import_rows x join sales_imports i2 on i2.id = x.import_id
                                   where x.org_id = imp.org_id and x.source_key = v_key and x.status = 'posted' limit 1));
      v_out := v_out || jsonb_build_object('row', r->'row', 'status', 'duplicate');
      continue;
    end if;
    begin
      res := case when v_kind = 'return' then private.import_return(imp, r, m) else private.import_sale(imp, r, m) end;
      select array_agg(x::uuid) into v_cols from jsonb_array_elements_text(coalesce(res->'collections', '[]'::jsonb)) x;
      insert into sales_import_rows (import_id, org_id, row_no, source_key, receipt, kind, status, sale_id, collection_ids, amount)
      values (imp.id, imp.org_id, coalesce((r->>'row')::int, 0), v_key, left(nullif(trim(r->>'receipt'), ''), 60), v_kind, 'posted', (res->>'sale_id')::uuid,
        v_cols, (res->>'total')::numeric);
      v_out := v_out || (jsonb_build_object('row', r->'row', 'status', 'posted') || (res - 'collections'));
    exception when others then
      get stacked diagnostics v_err = message_text;
      insert into sales_import_rows (import_id, org_id, row_no, source_key, receipt, kind, status, error)
      values (imp.id, imp.org_id, coalesce((r->>'row')::int, 0), v_key, left(nullif(trim(r->>'receipt'), ''), 60), v_kind, 'failed', left(v_err, 500));
      v_out := v_out || jsonb_build_object('row', r->'row', 'status', 'failed', 'error', left(v_err, 500));
    end;
  end loop;
  perform set_config('counta.quiet', '', true);
  return jsonb_build_object('import_id', imp.id, 'rows', v_out);
end $$;

-- The upload is done: its figures, and the bank lines that may now be explained (transfers waiting for their bank line, card
-- settlements in clearing) are matched again.
create or replace function public.sales_import_finish(p_import uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare imp public.sales_imports; m public.members; bl record; v_matched int := 0; v_stage text; v_dups jsonb; v_from date; v_to date;
begin
  select * into imp from sales_imports where id = p_import for update;
  if not found then raise exception 'Upload not found.'; end if;
  m := private.require_sales_upload(imp.org_id);
  if imp.status = 'posting' then
    perform set_config('counta.quiet', 'on', true);
    select min(s.issue_date), max(s.issue_date) into v_from, v_to from sales_import_rows r join sales s on s.id = r.sale_id where r.import_id = imp.id and r.status = 'posted';
    update sales_imports set status = 'posted', posted_at = now(),
      sales = (select count(*) from sales_import_rows where import_id = imp.id and status = 'posted' and kind = 'sale'),
      returns = (select count(*) from sales_import_rows where import_id = imp.id and status = 'posted' and kind = 'return'),
      skipped = (select count(*) from sales_import_rows where import_id = imp.id and status = 'duplicate'),
      failed = (select count(*) from sales_import_rows where import_id = imp.id and status = 'failed'),
      amount = (select coalesce(sum(case when s.doc_type = 'credit_note' then -s.total else s.total end), 0) from sales_import_rows r join sales s on s.id = r.sale_id
                where r.import_id = imp.id and r.status = 'posted'),
      vat = (select coalesce(sum(case when s.doc_type = 'credit_note' then -s.vat_total else s.vat_total end), 0) from sales_import_rows r join sales s on s.id = r.sale_id
             where r.import_id = imp.id and r.status = 'posted'),
      date_from = v_from, date_to = v_to
    where id = imp.id returning * into imp;
    -- Bank lines of those days not in the books yet, and those the AI only proposed whose amount is a transfer from this
    -- upload still waiting, or that settle card payments waiting in clearing: matched again.
    if v_from is not null then
      for bl in select l.* from bank_lines l join bank_accounts b on b.id = l.bank_account_id
               where l.org_id = imp.org_id and l.amount > 0 and l.line_date between v_from - 1 and v_to + 7
                 and (l.status = 'unmatched'
                   or (l.status = 'proposed' and (exists (select 1 from sales_import_rows ir join collection_allocations a on a.sale_id = ir.sale_id
                                                            join collections c on c.id = a.collection_id
                                                          where ir.import_id = imp.id and c.status = 'pending' and c.amount = l.amount)
                                                  or private.clearing_fit(l, b) is not null)))
               order by l.line_date, l.created_at loop
        if bl.status = 'proposed' then
          update ai_proposals set status = 'superseded' where id = bl.proposal_id and status in ('pending', 'info');
          update bank_lines set status = 'unmatched', proposal_id = null where id = bl.id;
        end if;
        v_stage := private.match_bank_line(bl.id);
        if v_stage in ('pending_payment', 'card_settlement') then v_matched := v_matched + 1; end if;
      end loop;
    end if;
    -- Money the bank feed already booked as sales of its own that look like this upload's transfers: listed for a person.
    select coalesce(jsonb_agg(jsonb_build_object('number', x.number, 'id', x.id, 'date', x.issue_date, 'amount', x.total) order by x.issue_date), '[]'::jsonb) into v_dups
    from sales x
    where x.org_id = imp.org_id and x.channel = 'bank' and x.status <> 'void' and v_from is not null and x.issue_date between v_from - 1 and v_to + 3
      and exists (select 1 from sales_import_rows ir join collection_allocations a on a.sale_id = ir.sale_id join collections c on c.id = a.collection_id
                  where ir.import_id = imp.id and c.status = 'pending' and c.method in ('transfer', 'other') and c.amount = x.total);
    update sales_imports set summary = jsonb_build_object('matched_lines', v_matched, 'bank_sales_alike', v_dups,
      'waiting_transfers', (select count(*) from sales_import_rows ir join collection_allocations a on a.sale_id = ir.sale_id join collections c on c.id = a.collection_id
                            where ir.import_id = imp.id and c.status = 'pending'),
      'in_clearing', (select coalesce(sum(c.amount), 0) from sales_import_rows ir join collections c on c.id = any(ir.collection_ids)
                      where ir.import_id = imp.id and c.via_account is not null and c.cleared_line_id is null and c.status = 'confirmed'),
      'no_cost', (select count(distinct l.item_id) from sales_import_rows ir join sale_lines l on l.sale_id = ir.sale_id
                  where ir.import_id = imp.id and ir.status = 'posted' and l.item_id is not null and coalesce(l.cost, 0) = 0))
    where id = imp.id returning * into imp;
    perform set_config('counta.quiet', '', true);
  end if;
  return public.get_sales_import(imp.id);
end $$;

-- An upload, its figures and the rows that did not post.
create or replace function public.get_sales_import(p_import uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare imp public.sales_imports; m public.members;
begin
  select * into imp from sales_imports where id = p_import;
  if not found then raise exception 'Upload not found.'; end if;
  m := private.require(imp.org_id, null);
  if not private.can_handle_money(imp.org_id) then raise exception 'Uploads need See margins, Keep the books or Make payments.' using errcode = '42501'; end if;
  return to_jsonb(imp) || jsonb_build_object(
    'created_by_name', (select display_name from members where id = imp.created_by),
    'voided_by_name', (select display_name from members where id = imp.voided_by),
    'problems', (select coalesce(jsonb_agg(jsonb_build_object('row', r.row_no, 'receipt', r.receipt, 'kind', r.kind, 'status', r.status, 'error', r.error) order by r.row_no), '[]'::jsonb)
                 from sales_import_rows r where r.import_id = imp.id and r.status in ('failed', 'duplicate')),
    'by_method', (select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from (
        select case when c.direction = 'out' then 'refund' when c.via_account is not null then c.method || '_clearing' when c.status = 'pending' then c.method || '_waiting'
                    else c.method end k, sum(c.amount) v
        from sales_import_rows ir join collections c on c.id = any(ir.collection_ids)
        where ir.import_id = imp.id and ir.status = 'posted' group by 1) z),
    'owed', (select coalesce(sum(s.total - s.amount_paid - s.credited), 0) from sales_import_rows ir join sales s on s.id = ir.sale_id
             where ir.import_id = imp.id and ir.status = 'posted' and s.doc_type = 'invoice'),
    'invoices', (select count(*) from sales_import_rows ir join sales s on s.id = ir.sale_id where ir.import_id = imp.id and ir.status = 'posted' and s.doc_type = 'invoice'),
    'can_undo', imp.status = 'posted' and coalesce(private.perm_of(m, 'approve_adjustments'), false));
end $$;

create or replace function public.get_sales_imports(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Uploads need See margins, Keep the books or Make payments.' using errcode = '42501'; end if;
  return jsonb_build_object('imports', (select coalesce(jsonb_agg((to_jsonb(i) - 'settings') || jsonb_build_object('created_by_name', mm.display_name) order by i.created_at desc), '[]'::jsonb)
    from (select * from sales_imports where org_id = p_org order by created_at desc limit 60) i left join members mm on mm.id = i.created_by),
    'can_upload', coalesce(private.perm_of(m, 'approve_adjustments'), false) and (select read_only_at is null from orgs where id = p_org));
end $$;

-- ---------------------------------------------------------------------------
-- 5. Card and POS payments in clearing, settled by the bank line
-- ---------------------------------------------------------------------------
-- The payments a credit settles: one payment from three days before to a day after whose amount is the line's or at most
-- 2% more (the provider's charge), else the card and POS payments of one of the four days up to the line's together, inside
-- the same 2%. Only payments booked to 9002 for this account (or for no account yet).
create or replace function private.clearing_fit(bl public.bank_lines, b public.bank_accounts) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_amt numeric := bl.amount; v_one record; v_ids uuid[]; v_total numeric; v_day date; v_clear text;
begin
  if bl.amount <= 0 or b.id is null or b.kind = 'cash' then return null; end if;
  v_clear := private.acct(bl.org_id, 'bank_clearing');
  select c.id, c.amount into v_one from collections c
  where c.org_id = bl.org_id and c.via_account = v_clear and c.cleared_line_id is null and c.status = 'confirmed' and c.direction = 'in'
    and c.method in ('card', 'pos') and (c.bank_account_id = b.id or c.bank_account_id is null) and c.journal_id is not null
    and c.amount >= v_amt and c.amount - v_amt <= round(c.amount * 0.02, 2)
    and c.received_at >= (bl.line_date - 4)::timestamptz and private.local_day(c.org_id, c.received_at) between bl.line_date - 3 and bl.line_date + 1
  order by (c.amount = v_amt) desc, (c.bank_account_id = b.id) desc, abs(private.local_day(c.org_id, c.received_at) - bl.line_date), c.received_at
  limit 1;
  if v_one.id is not null then return jsonb_build_object('ids', jsonb_build_array(v_one.id), 'total', v_one.amount); end if;
  foreach v_day in array array[bl.line_date, bl.line_date - 1, bl.line_date - 2, bl.line_date - 3] loop
    select array_agg(c.id), sum(c.amount) into v_ids, v_total from collections c
    where c.org_id = bl.org_id and c.via_account = v_clear and c.cleared_line_id is null and c.status = 'confirmed' and c.direction = 'in'
      and c.method in ('card', 'pos') and (c.bank_account_id = b.id or c.bank_account_id is null) and c.journal_id is not null
      and c.received_at >= (v_day - 1)::timestamptz and private.local_day(c.org_id, c.received_at) = v_day;
    if cardinality(v_ids) > 1 and v_total >= v_amt and v_total - v_amt <= round(v_total * 0.02, 2) then
      return jsonb_build_object('ids', to_jsonb(v_ids), 'total', v_total);
    end if;
  end loop;
  return null;
end $$;

create or replace function private.clearing_settle_line(bl public.bank_lines, b public.bank_accounts, m public.members) returns text
language plpgsql security definer set search_path = public, private as $$
declare v_fit jsonb := private.clearing_fit(bl, b); v_ids uuid[]; v_total numeric; v_n int; j public.journals;
begin
  if v_fit is null then return null; end if;
  select array_agg(x::uuid) into v_ids from jsonb_array_elements_text(v_fit->'ids') x;
  v_total := (v_fit->>'total')::numeric;
  v_n := cardinality(v_ids);
  j := private.post_entry(bl.org_id, 'Card and POS payments settled into ' || b.name || case when v_n > 1 then ' · ' || v_n || ' payments' else '' end, 'bank', bl.id, m.id, null,
    jsonb_build_array(
      jsonb_build_object('code', b.ledger_code, 'debit', bl.amount, 'memo', bl.description),
      jsonb_build_object('code', private.acct(bl.org_id, 'payment_fees'), 'debit', v_total - bl.amount, 'memo', 'Card and POS charges · ' || b.name),
      jsonb_build_object('code', private.acct(bl.org_id, 'bank_clearing'), 'credit', v_total, 'memo', 'Card and POS payments settled')),
    private.line_time(bl.org_id, bl.line_date),
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id, 'source', bl.source, 'date', bl.line_date,
      'amount', bl.amount, 'narration', bl.description, 'stage', 'card_settlement'), jsonb_build_object('type', 'card_settlement', 'payments', v_n, 'total', v_total))));
  update bank_lines set status = 'matched', journal_id = j.id, stage = 'card_settlement', matched_by = 'system', confidence = 1 where id = bl.id;
  update collections set cleared_line_id = bl.id, bank_account_id = coalesce(bank_account_id, b.id) where id = any(v_ids);
  return 'card_settlement';
end $$;

revoke all on function private.require_sales_upload(uuid), private.product_key(text), private.require_unfiled_month(uuid, date),
  private.import_sale(public.sales_imports, jsonb, public.members), private.import_return(public.sales_imports, jsonb, public.members),
  private.clearing_fit(public.bank_lines, public.bank_accounts), private.clearing_settle_line(public.bank_lines, public.bank_accounts, public.members)
  from public, anon, authenticated;
revoke all on function public.sales_import_prepare(uuid, jsonb), public.save_sales_import_products(uuid, jsonb), public.sales_import_start(uuid, jsonb),
  public.sales_import_batch(uuid, jsonb), public.sales_import_finish(uuid), public.get_sales_import(uuid), public.get_sales_imports(uuid) from public, anon;
grant execute on function public.sales_import_prepare(uuid, jsonb), public.save_sales_import_products(uuid, jsonb), public.sales_import_start(uuid, jsonb),
  public.sales_import_batch(uuid, jsonb), public.sales_import_finish(uuid), public.get_sales_import(uuid), public.get_sales_imports(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Returns dated when they happened
-- ---------------------------------------------------------------------------
-- The body of return_sale, unchanged except that the day and time of the return are given: return_sale passes today and
-- now, as before; an uploaded return passes the day it happened in the other system.
create or replace function private.return_sale_core(s public.sales, p_lines jsonb, p_refund jsonb, p_reason text, p_restock boolean,
  p_day date, p_at timestamptz, m public.members) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare cn public.sales; x jsonb; l public.sale_lines; v_qty numeric; v_jl jsonb := '[]'::jsonb; j public.journals;
  v_net numeric := 0; v_vat numeric := 0; v_gross numeric; v_lnet numeric; v_cost numeric; v_ratio numeric; v_refund numeric; v_due numeric; v_apply numeric;
  v_wac numeric; v_total numeric; v_bank uuid; col public.collections; v_no int := 0; v_whole boolean;
begin
  if s.doc_type not in ('receipt', 'invoice', 'order') or s.journal_id is null or s.status in ('void', 'cancelled') then raise exception '% cannot take a return.', s.number; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Give a reason for the return.'; end if;
  perform private.require_open_day(s.org_id, p_day);
  insert into sales (org_id, doc_type, number, status, customer_id, customer_name, customer_phone, customer_email, customer_tin, customer_address,
    location_id, channel, issue_date, prices_include_vat, vat_registered, original_sale_id, notes, created_by, issued_at)
  values (s.org_id, 'credit_note', private.doc_number(s.org_id, 'credit_note'), 'open', s.customer_id, s.customer_name, s.customer_phone, s.customer_email,
    s.customer_tin, s.customer_address, s.location_id, s.channel, p_day, s.prices_include_vat, s.vat_registered, s.id,
    trim(p_reason), m.id, p_at)
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
  j := private.post_entry(s.org_id, 'Credit note ' || cn.number || ' for ' || s.number || ' · ' || trim(p_reason), 'sale', cn.id, m.id, m.id, v_jl, p_at,
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'sale', 'id', s.id, 'ref', s.number))));
  update sales set journal_id = j.id where id = cn.id;
  if p_restock then
    for l in select * from sale_lines where sale_id = cn.id and item_id is not null order by line_no loop
      v_wac := coalesce(l.cost, 0) / (l.qty * l.unit_factor);
      perform private.update_wac(l.item_id, l.qty * l.unit_factor, coalesce(l.cost, 0));
      perform private.add_movement(s.org_id, 'sale_return', l.item_id, s.location_id, l.qty * l.unit_factor, round(v_wac, 4), round(l.gross / (l.qty * l.unit_factor), 2),
        j.id, m.id, 'Return', p_at, jsonb_build_object('note', cn.number || ' · ' || trim(p_reason)));
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
      (select id from shifts where cash_account_id = v_bank and status = 'open'), cn.number, p_at, m.id, now(), 'Refund for ' || s.number, m.id)
    returning * into col;
    perform private.post_collection(col.id, m);
    insert into credit_allocations (credit_note_id, sale_id, org_id, amount, created_by) values (cn.id, cn.id, s.org_id, v_refund, m.id);
  end if;
  update sales set credited = v_apply + v_refund, status = case when v_apply + v_refund >= v_total - 0.004 then 'paid' else 'open' end where id = cn.id;
  return jsonb_build_object('credit_note', private.sale_json(cn.id, private.can_see_costs(s.org_id)), 'refunded', v_refund, 'applied', v_apply,
    'store_credit', v_total - v_apply - v_refund);
end $$;

-- return_sale: unchanged checks and approvals, then the body above with today and now.
create or replace function public.return_sale(p_sale uuid, p_lines jsonb, p_refund jsonb, p_reason text, p_restock boolean default true) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members; v_route jsonb; a public.approvals;
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
  return private.return_sale_core(s, p_lines, p_refund, p_reason, p_restock, private.local_day(s.org_id, now()), now(), m);
end $$;

-- ---------------------------------------------------------------------------
-- 7. Undoing an upload
-- ---------------------------------------------------------------------------
-- One sale or return of an upload, undone as if it had not been uploaded: its entries are reversed on their own dates, its
-- stock comes back (or goes out again, for a return), and the bank lines that settled its card payments or confirmed its
-- transfers go back to the Books inbox (the caller matches them again). p_cols: the payments the upload recorded for it.
-- Returns the bank lines put back.
create or replace function private.undo_import_doc(p_sale uuid, p_cols uuid[], p_reason text, m public.members) returns uuid[]
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; c public.collections; bl public.bank_lines; mv record; l record; v_lines uuid[] := '{}'; v_at timestamptz;
begin
  select * into s from sales where id = p_sale for update;
  if not found or s.status = 'void' then return v_lines; end if;
  perform private.require_open_day(s.org_id, s.issue_date);
  if exists (select 1 from vat_periods where org_id = s.org_id and period = date_trunc('month', s.issue_date)::date) then
    raise exception '% is dated in %, whose VAT return is filed. Reopen that return first.', s.number, to_char(s.issue_date, 'FMMonth YYYY');
  end if;
  if s.doc_type <> 'credit_note' then
    if exists (select 1 from sales x where x.original_sale_id = s.id and x.doc_type = 'credit_note' and x.status <> 'void') then
      raise exception '% has a credit note that was not uploaded with it. Undo that first.', s.number;
    end if;
    if exists (select 1 from collection_allocations a join collections cc on cc.id = a.collection_id
               where a.sale_id = s.id and cc.status in ('pending', 'confirmed') and not (cc.id = any(coalesce(p_cols, '{}')))) then
      raise exception 'A payment recorded after the upload is on %. Undo that payment first.', s.number;
    end if;
  end if;
  -- The payments the upload recorded (for a return, its refund).
  for c in select * from collections where id = any(coalesce(p_cols, '{}')) or (s.doc_type = 'credit_note' and sale_id = s.id and direction = 'out')
           order by created_at for update loop
    -- A card or POS settlement that took this payment: undone, so every payment it took waits again.
    if c.cleared_line_id is not null then
      select * into bl from bank_lines where id = c.cleared_line_id for update;
      if bl.id is not null and bl.stage = 'card_settlement' and bl.journal_id is not null then
        perform private.require_open_day(s.org_id, bl.line_date);
        perform private.reverse_entry(bl.journal_id, m.id, 'Sales upload undone: ' || p_reason, null);
        update collections set cleared_line_id = null where cleared_line_id = bl.id;
        update bank_lines set status = 'unmatched', journal_id = null, stage = null, matched_by = null, confidence = null where id = bl.id;
        v_lines := v_lines || bl.id;
      end if;
    end if;
    -- A bank line that confirmed this payment goes back to the inbox; the payment's entry is reversed below.
    if c.journal_id is not null then
      for bl in select * from bank_lines where journal_id = c.journal_id for update loop
        perform private.require_open_day(s.org_id, bl.line_date);
        update bank_lines set status = 'unmatched', journal_id = null, stage = null, matched_by = null, confidence = null where id = bl.id;
        v_lines := v_lines || bl.id;
      end loop;
    end if;
    if c.status = 'confirmed' and c.journal_id is not null then
      perform private.reverse_entry(c.journal_id, m.id, 'Sales upload undone: ' || p_reason, null);
      update collections set status = 'reversed', note = concat_ws(' · ', note, 'Upload undone') where id = c.id;
    elsif c.status = 'pending' then
      update collections set status = 'rejected', note = concat_ws(' · ', note, 'Upload undone') where id = c.id;
    end if;
  end loop;
  v_at := (select created_at from journals where id = s.journal_id);
  if s.doc_type = 'credit_note' then
    delete from credit_allocations where credit_note_id = s.id;
    for l in select original_line_id, qty from sale_lines where sale_id = s.id and original_line_id is not null loop
      update sale_lines set returned_qty = greatest(returned_qty - l.qty, 0) where id = l.original_line_id;
    end loop;
  else
    delete from collection_allocations where sale_id = s.id;
  end if;
  perform private.reverse_entry(s.journal_id, m.id, 'Sales upload undone: ' || p_reason, null);
  -- Stock: what the sale took comes back, what the return put back goes out again, at the cost it moved at.
  for mv in select * from movements where journal_id = s.journal_id and item_id is not null loop
    if mv.qty < 0 then perform private.update_wac(mv.item_id, -mv.qty, -mv.qty * mv.unit_cost); end if;
    if mv.batch_id is not null then update batches set qty_remaining = qty_remaining - mv.qty where id = mv.batch_id; end if;
    perform private.add_movement(s.org_id, case when mv.qty < 0 then 'sale_return' else 'sale' end, mv.item_id, mv.location_id, -mv.qty, mv.unit_cost, mv.unit_price,
      (select id from journals where reversal_of = s.journal_id), m.id, 'Upload undone', coalesce(v_at, now()),
      jsonb_build_object('note', 'Undo ' || s.number || ' · ' || p_reason, 'batch_id', mv.batch_id));
  end loop;
  update movements set sale_id = s.id where journal_id = (select id from journals where reversal_of = s.journal_id);
  update sales set status = 'void', voided_by = m.id, voided_at = now(), void_reason = left('Sales upload undone: ' || p_reason, 300) where id = s.id;
  if s.doc_type = 'credit_note' and s.original_sale_id is not null then perform private.refresh_sale(s.original_sale_id); end if;
  return v_lines;
end $$;

-- Undo an upload: its returns first, then its sales, newest first. All or nothing: if one cannot be undone, none is.
create or replace function public.void_sales_import(p_import uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare imp public.sales_imports; m public.members; r record; v_n int := 0; v_lines uuid[] := '{}'; v_id uuid;
begin
  select * into imp from sales_imports where id = p_import for update;
  if not found then raise exception 'Upload not found.'; end if;
  m := private.require_sales_upload(imp.org_id);
  if imp.status = 'void' then raise exception '% is already undone.', imp.number; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Give a reason for undoing the upload.'; end if;
  perform set_config('counta.quiet', 'on', true);
  for r in select ir.id, ir.sale_id, ir.collection_ids, s.number from sales_import_rows ir join sales s on s.id = ir.sale_id
           where ir.import_id = imp.id and ir.status = 'posted' order by (ir.kind = 'return') desc, s.created_at desc, ir.row_no desc loop
    begin
      v_lines := v_lines || private.undo_import_doc(r.sale_id, r.collection_ids, trim(p_reason), m);
    exception when others then
      raise exception 'Nothing was undone: % cannot be (%)', r.number, sqlerrm;
    end;
    update sales_import_rows set status = 'void' where id = r.id;
    v_n := v_n + 1;
  end loop;
  update sales_imports set status = 'void', voided_by = m.id, voided_at = now(), void_reason = left(trim(p_reason), 300) where id = imp.id;
  -- The bank lines put back are matched again: a settlement may still fit other payments.
  foreach v_id in array coalesce((select array_agg(distinct x) from unnest(v_lines) x), '{}') loop
    perform private.match_bank_line(v_id);
  end loop;
  perform set_config('counta.quiet', '', true);
  return jsonb_build_object('undone', v_n, 'bank_lines', coalesce(cardinality(v_lines), 0), 'import', public.get_sales_import(imp.id));
end $$;

-- Notifications are held back while an upload posts (one per payment would flood every manager) and in a sample business.
create or replace function private.quiet(p_org uuid) returns boolean
language sql stable security definer set search_path = public, private as $$
  select coalesce(current_setting('counta.quiet', true), '') = 'on'
      or exists (select 1 from orgs o where o.id = p_org and o.is_sample and o.created_at >= now() - interval '1 second')
$$;

revoke all on function private.return_sale_core(public.sales, jsonb, jsonb, text, boolean, date, timestamptz, public.members),
  private.undo_import_doc(uuid, uuid[], text, public.members), private.quiet(uuid) from public, anon, authenticated;
revoke all on function public.void_sales_import(uuid, text) from public, anon;
grant execute on function public.void_sales_import(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. The bank matcher settles card and POS payments in clearing
-- ---------------------------------------------------------------------------
-- match_bank_line: its latest definition with three changes. 1: an entry that was reversed (or is a reversal) is not "already
-- in the books", so a line put back by an undo is matched afresh. 1c (new): a credit that settles card or POS payments held
-- in 9002 (clearing_settle_line). 2: several pending payments of the same amount, all from walk-in customers, no longer wait
-- for a person; the nearest in time is confirmed, as any of them would be the same to the books.
create or replace function private.match_bank_line(p_line uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare bl public.bank_lines; b public.bank_accounts; v_amt numeric; v_in boolean; r record; c public.collections; v_cnt int; m public.members;
  v_cust public.customers; v_vendor public.vendors; v_due numeric; v_rate numeric; v_gross numeric; v_wht numeric; v_head numeric; j public.journals;
  other public.bank_lines; ob public.bank_accounts; v_key text; v_rule public.entity_rules; v_at timestamptz; v_text text; s public.sales; bb public.bills;
  v_left_wht numeric; v_pid uuid; v_split jsonb; v_cands jsonb; v_pos text; v_fits int; v_fit uuid; mr public.members;
begin
  select * into bl from bank_lines where id = p_line for update;
  if bl.status <> 'unmatched' then return bl.stage; end if;
  select * into b from bank_accounts where id = bl.bank_account_id;
  v_amt := abs(bl.amount); v_in := bl.amount > 0;
  v_key := private.party_key(coalesce(nullif(bl.counterparty, ''), bl.description));
  update bank_lines set party_key = v_key where id = bl.id;
  v_at := private.line_time(bl.org_id, bl.line_date);
  v_text := coalesce(bl.description, '') || ' ' || coalesce(bl.reference, '') || ' ' || coalesce(bl.counterparty, '');
  -- Actions are taken in the name of the business owner; the line and its evidence say why.
  m := private.org_contact(bl.org_id);

  -- 1 Already in the books on this account, same amount, within three days, not yet tied to another line.
  select l.journal_id into r from journal_lines l join journals jj on jj.id = l.journal_id
  where l.org_id = bl.org_id and l.account_code = b.ledger_code and (case when v_in then l.debit else l.credit end) = v_amt
    and jj.entry_date between bl.line_date - 3 and bl.line_date + 3 and jj.reversal_of is null
    and not exists (select 1 from journals rv where rv.reversal_of = jj.id)
    and not exists (select 1 from bank_lines x where x.bank_account_id = b.id and x.journal_id = l.journal_id and x.id <> bl.id)
  order by abs(jj.entry_date - bl.line_date), jj.created_at limit 1;
  if r.journal_id is not null then
    update bank_lines set status = 'matched', journal_id = r.journal_id, stage = 'in_books', matched_by = 'system', confidence = 1 where id = bl.id;
    return 'in_books';
  end if;
  -- 1b A POS provider settling payments Counta already holds in 9002 (see pos_settle_line).
  if v_in then
    v_pos := private.pos_settle_line(bl, b, m);
    if v_pos is not null then return v_pos; end if;
    -- 1c Card and POS payments from uploaded sales, held in 9002, settled by the provider (see clearing_settle_line).
    v_pos := private.clearing_settle_line(bl, b, m);
    if v_pos is not null then return v_pos; end if;
  end if;

  if v_in then
    -- 2 A transfer recorded at the till or against an invoice, waiting for confirmation: the statement confirms it.
    select count(*) into v_cnt from collections col where col.org_id = bl.org_id and col.status = 'pending' and col.direction = 'in'
      and col.amount = v_amt and col.method in ('transfer', 'card', 'pos', 'cheque', 'other') and col.received_at::date between bl.line_date - 5 and bl.line_date + 1;
    if v_cnt >= 1 then
      select col.* into c from collections col join customers cu on cu.id = col.customer_id
      where col.org_id = bl.org_id and col.status = 'pending' and col.direction = 'in' and col.amount = v_amt
        and col.method in ('transfer', 'card', 'pos', 'cheque', 'other') and col.received_at::date between bl.line_date - 5 and bl.line_date + 1
      order by private.name_in(cu.name, bl.description) desc, (col.reference is not null and position(upper(col.reference) in upper(bl.description || ' ' || coalesce(bl.reference, ''))) > 0) desc,
        abs(col.received_at::date - bl.line_date), col.received_at limit 1;
      -- Several payments of the same amount from walk-in customers are the same to the books: the nearest in time is taken.
      if v_cnt = 1 or private.name_in((select name from customers where id = c.customer_id), bl.description)
         or not exists (select 1 from collections col join customers cu on cu.id = col.customer_id
                        where col.org_id = bl.org_id and col.status = 'pending' and col.direction = 'in' and col.amount = v_amt
                          and col.method in ('transfer', 'card', 'pos', 'cheque', 'other') and col.received_at::date between bl.line_date - 5 and bl.line_date + 1
                          and not cu.is_walk_in) then
        update collections set status = 'confirmed', bank_account_id = b.id, confirmed_at = now(), note = concat_ws(' · ', note, 'Confirmed by the bank statement')
        where id = c.id;
        c := private.post_collection(c.id, m);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'pending_payment', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'pending_payment';
      end if;
    end if;

    -- 2b The invoice or order the narration names, whoever paid it (a director paying for the company, a relative).
    select * into s from sales x where x.org_id = bl.org_id and x.doc_type in ('invoice', 'order') and x.status in ('open', 'partially_paid') and x.journal_id is not null
      and x.issue_date <= bl.line_date + 1 and private.doc_in_text(x.number, v_text)
    order by x.issue_date desc limit 1;
    if s.id is not null then
      v_due := s.total - s.amount_paid - s.credited - coalesce((select sum(a.amount) from collection_allocations a join collections cc on cc.id = a.collection_id
        where a.sale_id = s.id and cc.status = 'pending'), 0);
      -- The invoice's own number and exactly what is owed (or that less WHT, and VAT for a customer who withholds VAT): settled.
      -- Any other amount is put to a person below.
      v_split := private.customer_short_split(s.id, v_due, v_amt);
      if abs(v_due - v_amt) < 0.005 or v_split is not null then
        if v_split is not null then
          perform private.book_customer_withholding(bl.org_id, s.customer_id, s.id, v_split, v_at, m);
        end if;
        c := private.add_collection(bl.org_id, s.customer_id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
          'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'Matched from the bank by ' || s.number, 'spread', false), m, 'confirmed', array[s.id]);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'invoice_ref', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'invoice_ref';
      end if;
    end if;
  else
    -- 3 Statutory payees clear the tax head, never an expense (AP-06).
    select * into r from payee_registry pr where pr.kind like 'statutory%' and pr.direction in ('out', 'both')
      and upper(bl.description || ' ' || coalesce(bl.counterparty, '')) ~ pr.pattern order by pr.id limit 1;
    if r.id is not null then
      j := private.post_bank_line(bl.id, coalesce(case when r.role is not null then private.acct(bl.org_id, r.role) end, r.account_code), null, null,
        r.description || ' · ' || bl.description, 'statutory', jsonb_build_object('matched_by', 'rule'));
      select coalesce(sum(credit - debit), 0) into v_head from journal_lines where org_id = bl.org_id and account_code = coalesce(case when r.role is not null then private.acct(bl.org_id, r.role) end, r.account_code);
      if v_head < -0.004 then
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'tax', 'remittance_without_accrual', 'bank_line', bl.id, 'Paid more ' || r.description || ' than the books owed',
          'This remittance is more than the liability on record. Is a return missing, or was this paid in advance?',
          jsonb_build_object('account', r.account_code, 'overpaid', -v_head), 1, 'AP-06 exception', 'statutory', 'info', v_amt, j.id) on conflict do nothing;
      end if;
      return 'statutory';
    end if;

    -- 3b The bill the narration names: Counta's number, or the supplier's own invoice number together with the amount
    --    owed or the supplier's name (a short invoice number alone could be a coincidence).
    select bb2.* into bb from bills bb2 where bb2.org_id = bl.org_id and bb2.status in ('approved', 'partially_paid')
      and (private.doc_in_text(bb2.number, v_text)
           or private.ref_in_text(bb2.vendor_ref, v_text) and (abs(bb2.total - bb2.amount_paid - v_amt) < 0.005
             or abs(bb2.total - bb2.amount_paid - greatest(bb2.wht_expected + bb2.wvat_expected - bb2.wht_withheld - bb2.wvat_withheld, 0) - v_amt) < 0.005
             or private.name_in((select name from vendors where id = bb2.vendor_id), coalesce(bl.counterparty, '') || ' ' || bl.description)))
    order by bb2.due_date limit 1;
    if bb.id is not null then
      v_due := bb.total - bb.amount_paid - coalesce((select sum(gross) from bill_payments where bill_id = bb.id and status = 'processing'), 0);
      v_left_wht := greatest(bb.wht_expected + bb.wvat_expected - bb.wht_withheld - bb.wvat_withheld
        - coalesce((select sum(wht + wvat) from bill_payments where bill_id = bb.id and status = 'processing'), 0), 0);
      v_rate := coalesce((bb.wht_expected + bb.wvat_expected) / nullif(bb.total, 0), 0);
      v_gross := case when abs(v_due - v_amt) < 0.005 then v_due
                      when v_left_wht > 0 and abs(v_due - v_left_wht - v_amt) < 0.005 then v_due end;
      if v_gross is not null then
        v_wht := greatest(v_gross - v_amt, 0);
        j := private.record_bill_payment(bb.id, b.id, v_gross, v_wht, v_at, coalesce(bl.reference, left(bl.description, 60)), m);
        update bank_lines set status = 'matched', journal_id = j.id, stage = 'bill_ref', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'bill_ref';
      end if;
    end if;
  end if;

  if v_in then
    -- 4 A customer named in the narration: their open invoices that fit are put to a person to confirm (AR-03).
    for v_cust in select cu.* from customers cu where cu.org_id = bl.org_id and not cu.is_walk_in and not cu.archived
        and private.name_in(cu.name, coalesce(bl.counterparty, '') || ' ' || bl.description)
        order by length(cu.name) desc limit 1 loop
      -- One of their open invoices fits, exactly or less what they kept back (WHT, the NCD levy, VAT withheld): settled.
      select count(*), (array_agg(x.id order by x.ord))[1], (array_agg(x.due order by x.ord))[1] into v_fits, v_fit, v_due
      from (select s2.id, row_number() over (order by coalesce(s2.due_date, s2.issue_date), s2.created_at) ord,
              s2.total - s2.amount_paid - s2.credited - coalesce((select sum(a.amount) from collection_allocations a join collections cc on cc.id = a.collection_id
                where a.sale_id = s2.id and cc.status = 'pending'), 0) due
            from sales s2
            where s2.org_id = bl.org_id and s2.customer_id = v_cust.id and s2.status in ('open', 'partially_paid') and s2.journal_id is not null
              and s2.doc_type in ('invoice', 'order', 'receipt')) x
      where x.due > 0.004 and (abs(x.due - v_amt) < 0.005 or private.customer_short_split(x.id, x.due, v_amt) is not null);
      if v_fits = 1 then
        select * into s from sales where id = v_fit for update;
        v_split := private.customer_short_split(s.id, v_due, v_amt);
        if v_split is not null then
          perform private.book_customer_withholding(bl.org_id, s.customer_id, s.id, v_split, v_at, m);
        end if;
        c := private.add_collection(bl.org_id, s.customer_id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
          'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'Matched from the bank: ' || v_cust.name || ' named, ' || s.number || ' fits',
          'spread', false), m, 'confirmed', array[s.id]);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'customer_invoice', matched_by = 'system', confidence = 0.95 where id = bl.id;
        return 'customer_invoice';
      end if;
      v_cands := private.match_candidates(bl.id);
      if jsonb_array_length(v_cands) > 0 then
        perform private.propose_match(bl.id, v_cands, 'customer');
        return 'customer';
      end if;
      select coalesce(sum(s2.total - s2.amount_paid - s2.credited), 0) into v_due from sales s2
      where s2.customer_id = v_cust.id and s2.status in ('open', 'partially_paid') and s2.journal_id is not null;
      -- Paying with nothing owed: held as an advance, flagged (AR rule).
      if v_due <= 0.004 then
        c := private.add_collection(bl.org_id, v_cust.id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
          'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'No invoice open: held as customer credit', 'spread', true), m, 'confirmed', null);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'customer_advance', matched_by = 'system', confidence = 0.8 where id = bl.id;
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'bookkeeper', 'advance_without_invoice', 'bank_line', bl.id, v_cust.name || ' paid with nothing owed',
          'Held as customer credit. Raise the invoice it was for, or refund it.', jsonb_build_object('customer_id', v_cust.id), 0.8,
          'AR: inflow from a known customer with no open invoice', 'customer', 'info', v_amt, c.journal_id) on conflict do nothing;
        return 'customer_advance';
      end if;
    end loop;
  else
    -- 5 A vendor named in the narration being paid for open bills (AP-03).
    for v_vendor in select v.* from vendors v where v.org_id = bl.org_id
        and (private.name_in(v.name, coalesce(bl.counterparty, '') || ' ' || bl.description)
             or (v.account_number is not null and position(v.account_number in coalesce(bl.counterparty_account, '') || bl.description) > 0))
        order by length(v.name) desc limit 1 loop
      v_cands := private.match_candidates(bl.id);
      if jsonb_array_length(v_cands) > 0 then
        perform private.propose_match(bl.id, v_cands, 'vendor_bill');
        return 'vendor_bill';
      end if;
      -- A known vendor with no matching bill: post to their usual account and ask for the bill (AP-05).
      if v_vendor.default_account is not null then
        j := private.post_bank_line(bl.id, v_vendor.default_account, null, null, v_vendor.name || ' · no bill', 'vendor_no_bill',
          jsonb_build_object('matched_by', 'rule', 'ai_confidence', 0.85));
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'bookkeeper', 'payment_without_bill', 'bank_line', bl.id, 'Paid ' || v_vendor.name || ' without a bill',
          'Posted to their usual account with no VAT claimed and no WHT. Upload the bill if there is one.', jsonb_build_object('vendor_id', v_vendor.id),
          0.85, 'AP-05', 'vendor_no_bill', 'info', v_amt, j.id) on conflict do nothing;
        return 'vendor_no_bill';
      end if;
    end loop;
  end if;

  -- 6 Money moving between the business's own accounts.
  select x.* into other from bank_lines x join bank_accounts xa on xa.id = x.bank_account_id
  where x.org_id = bl.org_id and x.bank_account_id <> bl.bank_account_id and x.amount = -bl.amount and x.status in ('unmatched', 'posted')
    and x.line_date between bl.line_date - 2 and bl.line_date + 2 and (x.status = 'unmatched' or x.stage = 'transfer_one_leg')
  order by abs(x.line_date - bl.line_date) limit 1;
  if other.id is not null then
    select * into ob from bank_accounts where id = other.bank_account_id;
    if other.status = 'unmatched' then
      j := private.post_entry(bl.org_id, 'Transfer between own accounts · ' || b.name || ' and ' || ob.name, 'bank', bl.id, m.id, null,
        private.reclass_pair(case when v_in then b.ledger_code else ob.ledger_code end, case when v_in then ob.ledger_code else b.ledger_code end, v_amt, null, null),
        v_at, jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id), jsonb_build_object('type', 'bank_line', 'id', other.id))));
      update bank_lines set status = 'matched', journal_id = j.id, stage = 'transfer', matched_by = 'system', confidence = 1 where id in (bl.id, other.id);
    else
      j := private.post_bank_line(bl.id, private.acct(bl.org_id, 'bank_clearing'), null, null, 'Transfer between own accounts · ' || ob.name, 'transfer',
        jsonb_build_object('matched_by', 'system'), 'matched');
      update bank_lines set stage = 'transfer' where id = other.id;
    end if;
    return 'transfer';
  end if;
  -- 6b Money sent to Bujeti from this account (or taken back from it): a transfer to or from the Bujeti balance.
  if upper(v_text) ~ '\yBUJETI\y' then
    select xa.* into ob from bank_accounts xa where xa.org_id = bl.org_id and xa.id <> b.id and xa.active and xa.provider = 'integration'
      and xa.provider_ref = bl.org_id::text || ':bujeti';
    if ob.id is not null then
      perform private.post_bank_line(bl.id, ob.ledger_code, null, null, case when v_in then 'Money back from Bujeti · ' else 'Money sent to Bujeti · ' end || bl.description,
        'transfer', jsonb_build_object('matched_by', 'system'));
      return 'transfer';
    end if;
  end if;
  if exists (select 1 from bank_accounts xa where xa.org_id = bl.org_id and xa.id <> b.id and xa.active
             and ((xa.account_number is not null and position(xa.account_number in coalesce(bl.counterparty_account, '') || ' ' || bl.description) > 0)
                  or upper(bl.description) ~ '(OWN ACCOUNT|SELF TRANSFER|TRF TO SELF|SWEEP)')) then
    perform private.post_bank_line(bl.id, private.acct(bl.org_id, 'bank_clearing'), null, null, 'Transfer between own accounts, other side to come', 'transfer_one_leg',
      jsonb_build_object('matched_by', 'system'));
    return 'transfer_one_leg';
  end if;

  -- 7 A rule learned from an earlier decision.
  select * into v_rule from entity_rules er where er.org_id = bl.org_id and er.direction = case when v_in then 'in' else 'out' end
    and v_key is not null and (er.party_key = v_key or position(er.party_key in v_key) > 0) order by length(er.party_key) desc limit 1;
  if v_rule.id is not null and private.postable(bl.org_id, v_rule.account_code) then
    if v_in and v_rule.customer_id is not null and v_rule.account_code ~ '^(1101|1102)' then
      -- A customer's money to what they owe goes to their invoices, as a person's answer does.
      mr := m;
      mr.display_name := 'a learned rule';
      perform private.apply_match(bl.id, private.customer_pick(bl.org_id, v_rule.customer_id, v_amt), mr, null);
      update bank_lines set stage = 'rule', matched_by = 'rule', confidence = 0.95 where id = bl.id;
    else
      perform private.post_bank_line(bl.id, v_rule.account_code,
        case when v_rule.customer_id is not null then 'customer' when v_rule.vendor_id is not null then 'vendor' end, coalesce(v_rule.customer_id, v_rule.vendor_id),
        null, 'rule', jsonb_build_object('matched_by', 'rule', 'ai_confidence', 0.95));
    end if;
    update entity_rules set hits = hits + 1 where id = v_rule.id;
    return 'rule';
  end if;

  -- 8 Payee types: bank charges, power, telcos, internet, fuel, CAC, interest received.
  select * into r from payee_registry pr where pr.kind not like 'statutory%' and pr.direction in (case when v_in then 'in' else 'out' end, 'both')
    and upper(bl.description || ' ' || coalesce(bl.counterparty, '')) ~ pr.pattern order by pr.id limit 1;
  if r.id is not null then
    perform private.post_bank_line(bl.id, coalesce(case when r.role is not null then private.acct(bl.org_id, r.role) end, r.account_code), null, null,
      r.description || ' · ' || bl.description, 'registry', jsonb_build_object('matched_by', 'rule', 'ai_confidence', 0.9));
    return 'registry';
  end if;

  -- 9 Nobody named: the open invoices (or bills) the amount fits, as it stands, less WHT or less bank charges, are put to a
  --   person to confirm in one tap.
  v_cands := private.match_candidates(bl.id);
  if jsonb_array_length(v_cands) > 0 then
    perform private.propose_match(bl.id, v_cands, case when v_in then 'invoice_amount' else 'bill_amount' end);
    return case when v_in then 'invoice_amount' else 'bill_amount' end;
  end if;
  return null;
end $function$;
