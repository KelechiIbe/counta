-- Monthly sales uploaded from another POS (20261208000100_sales_upload.sql): each row becomes a Counta sale with its stock
-- and cost of sales; a total is shared over its products by their prices; cash, card and transfers go where their money is;
-- card payments wait in 9002 until the provider's settlement (one payment or a day's together, less charges); transfers
-- wait for the bank line; part-paid sales are invoices; returns are credit notes dated when they happened; a row never posts
-- twice; filed VAT months take nothing; an upload is undone whole, bank settlements included; return_sale is unchanged.
-- Only fake people (example.test addresses).
begin;

-- Fixture: Ada owns Brooks Pharmacy Ltd (VAT-registered company). Three products on its list with prices and costs; a
-- Moniepoint settlement account; Bisi is a cashier.
do $$
declare o uuid; b uuid;
begin
  perform tests.hooks_on();
  perform tests.remember('ada', tests.user('ada.owner@brooks.example.test', 'Ada Owner'));
  perform tests.remember('bisi', tests.user('bisi.cashier@brooks.example.test', 'Bisi Cashier'));
  o := tests.remember('o', tests.org(tests.id('ada'), 'Brooks Pharmacy Ltd'));
  update orgs set vat_registered = true, tin = '44444444-0001', legal_form = 'company' where id = o;
  perform tests.member(o, tests.id('bisi'), 'cashier');
  perform tests.as_user(tests.id('ada'));
  perform public.import_inventory(o, '[{"name": "Procold Tab X 4", "price": 1500, "cost": 900, "vat_treatment": "standard"},
     {"name": "Otrivin Adults Nasal Drop 01", "price": 4800, "cost": 3000, "vat_treatment": "exempt"},
     {"name": "Vigor Chocolate Bar", "price": 4200, "cost": 2500, "vat_treatment": "standard"}]'::jsonb, '{}'::jsonb);
  perform tests.as_postgres();
  insert into bank_accounts (org_id, name, bank_name, account_number, kind, ledger_code)
  values (o, 'Moniepoint Settlement', 'Moniepoint', '5555555555', 'bank', '1103') returning id into b;
  perform tests.remember('bank', b);
  perform tests.remember('procold', (select id from items where org_id = o and name = 'Procold Tab X 4'));
  perform tests.remember('otrivin', (select id from items where org_id = o and name = 'Otrivin Adults Nasal Drop 01'));
  perform tests.remember('vigor', (select id from items where org_id = o and name = 'Vigor Chocolate Bar'));
end $$;

create function pg_temp.m1() returns date language sql as $f$ select (date_trunc('month', now()) - interval '1 month')::date $f$;
create function pg_temp.at(p_day int, p_time text default '10:00') returns text language sql as $f$
  select (pg_temp.m1() + p_day)::text || 'T' || p_time || ':00+01:00'
$f$;
-- A walk-in sale row: [product name, qty] pairs, the total paid, its discount, and payments [method, amount].
create function pg_temp.row(p_key text, p_day int, p_total numeric, p_lines jsonb, p_pay jsonb, p_disc numeric default 0, p_customer jsonb default '{"name": "Walk-In Customer"}',
  p_time text default '10:00') returns jsonb language plpgsql as $f$
declare ln jsonb := '[]'::jsonb; pay jsonb := '[]'::jsonb; x jsonb;
begin
  for x in select * from jsonb_array_elements(p_lines) loop
    ln := ln || (jsonb_build_object('name', x->>0, 'qty', coalesce((x->>1)::numeric, 1)) || coalesce(x->2, '{}'::jsonb));
  end loop;
  for x in select * from jsonb_array_elements(p_pay) loop
    pay := pay || jsonb_build_object('method', x->>0, 'amount', (x->>1)::numeric, 'account_id', case when x->>0 in ('card', 'pos', 'transfer') then tests.id('bank') end);
  end loop;
  return jsonb_build_object('row', 0, 'key', p_key, 'receipt', p_key, 'at', pg_temp.at(p_day, p_time), 'customer', p_customer, 'total', p_total, 'discount', p_disc,
    'lines', ln, 'payments', pay, 'sold_by', 'Joseph');
end $f$;
-- Start, post in batches of 100 and finish an upload as Ada; the finished upload with the posted rows.
create function pg_temp.up(p_rows jsonb, p_file text default 'Brooks.csv') returns jsonb language plpgsql as $f$
declare imp jsonb; res jsonb := '[]'::jsonb; b jsonb; i int := 0; n int := jsonb_array_length(p_rows); fin jsonb;
begin
  perform tests.as_user(tests.id('ada'));
  imp := public.sales_import_start(tests.id('o'), jsonb_build_object('file_name', p_file, 'source', 'Brooks POS', 'rows_total', n));
  while i < n loop
    b := public.sales_import_batch((imp->>'id')::uuid, (select jsonb_agg(e order by o) from jsonb_array_elements(p_rows) with ordinality t(e, o) where o > i and o <= i + 100));
    res := res || (b->'rows');
    i := i + 100;
  end loop;
  fin := public.sales_import_finish((imp->>'id')::uuid);
  perform tests.as_postgres();
  return fin || jsonb_build_object('rows', res);
end $f$;
create function pg_temp.sale(p_id uuid) returns public.sales language sql as $f$ select * from sales where id = p_id $f$;
create function pg_temp.cols(p_sale uuid) returns uuid[] language sql as $f$ select collection_ids from sales_import_rows where sale_id = p_sale and status = 'posted' $f$;
create function pg_temp.sale_of(p_res jsonb, p_key int) returns public.sales language sql as $f$
  select * from sales where id = ((p_res->'rows'->p_key)->>'sale_id')::uuid
$f$;
create function pg_temp.bal(p_code text) returns numeric language sql as $f$
  select coalesce(sum(l.debit - l.credit), 0) from journal_lines l where l.org_id = tests.id('o') and l.account_code = p_code
$f$;
create function pg_temp.line(p_day int, p_amt numeric, p_text text) returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into bank_lines (org_id, bank_account_id, line_date, description, amount, status, source, fingerprint)
  values (tests.id('o'), tests.id('bank'), pg_temp.m1() + p_day, p_text, p_amt, 'unmatched', 'statement', 'su:' || gen_random_uuid())
  returning id into v;
  return v;
end $f$;
-- Every account's balance, to compare before an upload and after it is undone.
create function pg_temp.tb() returns jsonb language sql as $f$
  select coalesce(jsonb_object_agg(account_code, b), '{}'::jsonb) from (select account_code, sum(debit - credit) b from journal_lines where org_id = tests.id('o')
    group by 1 having sum(debit - credit) <> 0) z
$f$;

-- test: total_shared_by_list_prices
-- A ₦6,300 card sale of Procold (₦1,500) and Otrivin (₦4,800): each product at its own price, VAT only inside the standard
-- one, cost of sales booked at the products' costs, ₦6,300 held in 9002.
do $$
declare r jsonb := pg_temp.up(jsonb_build_array(pg_temp.row('BRK-1', 3, 6300, '[["Procold Tab X 4"], ["Otrivin Adults Nasal Drop 01"]]', '[["card", 6300]]')));
  s public.sales := pg_temp.sale_of(r, 0);
begin
  assert r->'rows'->0->>'status' = 'posted', format('total_shared_by_list_prices: posted, got %s', r->'rows');
  assert s.doc_type = 'receipt' and s.status = 'paid' and s.total = 6300 and s.channel = 'schedule' and s.issue_date = pg_temp.m1() + 3, format('total_shared_by_list_prices: the receipt, got %s', to_jsonb(s));
  assert (select string_agg(description || ':' || unit_price || ':' || vat, ',' order by line_no) from sale_lines where sale_id = s.id)
    = 'Procold Tab X 4:1500.00:104.65,Otrivin Adults Nasal Drop 01:4800.00:0.00', 'total_shared_by_list_prices: lines at their prices, VAT inside Procold only';
  assert (select sum(cost) from sale_lines where sale_id = s.id) = 3900, 'total_shared_by_list_prices: cost of sales';
  assert (select count(*) from movements where sale_id = s.id and type = 'sale' and qty = -1) = 2, 'total_shared_by_list_prices: stock out';
  assert s.reference = 'BRK-1' and s.notes like 'From sales upload SU-% · Sold by Joseph', format('total_shared_by_list_prices: reference and note, got %s', s.notes);
  assert pg_temp.bal('9002') = 6300, format('total_shared_by_list_prices: 6,300 in clearing, got %s', pg_temp.bal('9002'));
  assert (r->'summary'->>'in_clearing')::numeric = 6300 and (r->'by_method'->>'card_clearing')::numeric = 6300, format('total_shared_by_list_prices: summary, got %s', r);
end $$;

-- test: discount_and_cash_change
-- Total ₦2,200 after a ₦400 discount, paid with ₦2,500 cash: the sale is ₦2,600 less ₦400, and only ₦2,200 goes to cash.
-- A product with no item is recorded with no stock at the VAT treatment the person chose.
do $$
declare r jsonb; s public.sales;
begin
  r := pg_temp.up(jsonb_build_array(pg_temp.row('BRK-2', 3, 2200, '[["Kiss Lube Gel 120Ml", 1, {"non_stock": true, "vat_treatment": "standard"}]]', '[["cash", 2500]]', 400)));
  s := pg_temp.sale_of(r, 0);
  assert s.total = 2200 and s.discount_total = 400 and s.status = 'paid', format('discount_and_cash_change: the receipt, got %s', to_jsonb(s));
  assert (select unit_price from sale_lines where sale_id = s.id) = 2600 and (select item_id from sale_lines where sale_id = s.id) is null, 'discount_and_cash_change: the line';
  assert (select sum(amount) from collections where id = any(pg_temp.cols(s.id))) = 2200, 'discount_and_cash_change: 2,200 cash';
end $$;

-- test: price_hint_for_new_products
-- Three products with no Counta price share ₦5,000: two by the prices the file showed for them (₦1,000 and ₦3,000), the
-- third, with none, at their average (₦2,000), so 1:3:2.
do $$
declare r jsonb; s public.sales;
begin
  r := pg_temp.up(jsonb_build_array(pg_temp.row('BRK-3', 4, 5000,
    '[["Zentel Tab", 1, {"non_stock": true, "price_hint": 1000}], ["Feroglobin Caps X30", 1, {"non_stock": true, "price_hint": 3000}], ["Odd Thing", 1, {"non_stock": true}]]',
    '[["transfer", 5000]]')));
  s := pg_temp.sale_of(r, 0);
  assert s.total = 5000, format('price_hint_for_new_products: total, got %s', r->'rows');
  assert (select string_agg(unit_price::text, ',' order by line_no) from sale_lines where sale_id = s.id) = '833.33,2500.00,1666.67',
    format('price_hint_for_new_products: shared 1:3:2, got %s', (select string_agg(unit_price::text, ',' order by line_no) from sale_lines where sale_id = s.id));
  assert s.discount_total = 0, format('price_hint_for_new_products: no rounding left, got %s', s.discount_total);
end $$;

-- test: split_card_and_cash
do $$
declare r jsonb := pg_temp.up(jsonb_build_array(pg_temp.row('BRK-4', 5, 1700, '[["Kiss Lube Gel 120Ml", 1, {"non_stock": true}]]', '[["card", 1000], ["cash", 700]]')));
  s public.sales := pg_temp.sale_of(r, 0);
begin
  assert s.status = 'paid' and (select string_agg(method || ':' || amount, ',' order by method) from collections where id = any(pg_temp.cols(s.id)))
    = 'card:1000.00,cash:700.00', 'split_card_and_cash: both payments';
end $$;

-- test: duplicates_never_post_twice
-- The same receipt in the same upload and again in a later file: posted once, the rest marked duplicates.
do $$
declare r1 jsonb; r2 jsonb; n int := (select count(*) from sales where org_id = tests.id('o'));
begin
  r1 := pg_temp.up(jsonb_build_array(pg_temp.row('BRK-5', 6, 4200, '[["Vigor Chocolate Bar"]]', '[["card", 4200]]'),
    pg_temp.row('BRK-5', 6, 4200, '[["Vigor Chocolate Bar"]]', '[["card", 4200]]')));
  r2 := pg_temp.up(jsonb_build_array(pg_temp.row('BRK-5', 6, 4200, '[["Vigor Chocolate Bar"]]', '[["card", 4200]]')), 'Brooks again.csv');
  assert r1->'rows'->0->>'status' = 'posted' and r1->'rows'->1->>'status' = 'duplicate' and r2->'rows'->0->>'status' = 'duplicate', format('duplicates_never_post_twice: %s %s', r1->'rows', r2->'rows');
  assert (r2->>'skipped')::int = 1 and r2->'problems'->0->>'error' like 'Already uploaded in SU-%', format('duplicates_never_post_twice: problems, got %s', r2->'problems');
  assert (select count(*) from sales where org_id = tests.id('o')) = n + 1, 'duplicates_never_post_twice: one sale';
end $$;

-- test: failed_rows_do_not_stop_the_rest
-- An unknown product, a part-paid walk-in and a future date fail with their reasons; the good row posts.
do $$
declare r jsonb := pg_temp.up(jsonb_build_array(
    pg_temp.row('BRK-6', 6, 5800, '[["Mystery Product"]]', '[["card", 5800]]'),
    pg_temp.row('BRK-7', 6, 4200, '[["Vigor Chocolate Bar"]]', '[["card", 3000]]'),
    pg_temp.row('BRK-8', 40, 4200, '[["Vigor Chocolate Bar"]]', '[["card", 4200]]'),
    pg_temp.row('BRK-9', 7, 1500, '[["Procold Tab X 4"]]', '[["cash", 1500]]')));
begin
  assert r->'rows'->0->>'error' like '"Mystery Product" is not a Counta item yet%', format('failed_rows: unknown product, got %s', r->'rows'->0);
  assert r->'rows'->1->>'error' like 'A sale not paid in full needs the customer''s name%', format('failed_rows: walk-in on credit, got %s', r->'rows'->1);
  assert r->'rows'->2->>'error' = 'A sale cannot be dated in the future.' or pg_temp.m1() + 40 <= current_date, format('failed_rows: future, got %s', r->'rows'->2);
  assert r->'rows'->3->>'status' = 'posted' and (r->>'failed')::int >= 2 and (r->>'sales')::int >= 1, format('failed_rows: the rest posts, got %s', r);
  assert not exists (select 1 from sales where org_id = tests.id('o') and reference in ('BRK-6', 'BRK-7')), 'failed_rows: nothing left behind';
end $$;

-- test: part_paid_is_an_invoice
-- Queen Imo (named, with a phone) pays ₦3,000 of ₦5,800 by card: an invoice owing ₦2,800, her customer record added once and
-- found again by phone.
do $$
declare r jsonb := pg_temp.up(jsonb_build_array(
    pg_temp.row('BRK-10', 8, 5800, '[["Kiss Lube Gel 120Ml", 2, {"non_stock": true}]]', '[["card", 3000]]', 0, '{"name": "Queen Imo", "phone": "0803 123 4567"}'),
    pg_temp.row('BRK-11', 9, 1500, '[["Procold Tab X 4"]]', '[["cash", 1500]]', 0, '{"name": "Queen I.", "phone": "+2348031234567"}')));
  s public.sales := pg_temp.sale_of(r, 0);
begin
  assert s.doc_type = 'invoice' and s.total - s.amount_paid = 2800 and s.customer_name = 'Queen Imo', format('part_paid_is_an_invoice: got %s', to_jsonb(s));
  assert (pg_temp.sale_of(r, 1)).customer_id = s.customer_id, 'part_paid_is_an_invoice: found again by phone';
  assert (r->>'owed')::numeric = 2800 and (r->>'invoices')::int = 1, format('part_paid_is_an_invoice: summary, got %s', r);
end $$;

-- test: card_settlement_one_payment
-- Moniepoint pays ₦4,137 for the ₦4,200 card sale of BRK-5 (₦63 charge): settled, ₦63 to charges, the payment marked.
do $$
declare v uuid := pg_temp.line(7, 4137, 'MONIEPOINT SETTLEMENT'); bl public.bank_lines; c0 numeric := pg_temp.bal('9002'); f0 numeric := pg_temp.bal(private.acct(tests.id('o'), 'payment_fees'));
begin
  assert private.match_bank_line(v) = 'card_settlement', 'card_settlement_one_payment: stage';
  select * into bl from bank_lines where id = v;
  assert bl.status = 'matched' and bl.journal_id is not null, 'card_settlement_one_payment: matched';
  assert pg_temp.bal('9002') = c0 - 4200 and pg_temp.bal(private.acct(tests.id('o'), 'payment_fees')) = f0 + 63, 'card_settlement_one_payment: clearing down 4,200, charges 63';
  assert (select count(*) from collections where cleared_line_id = v and amount = 4200) = 1, 'card_settlement_one_payment: the payment marked';
end $$;

-- test: card_settlement_day_batch
-- Three card sales on one day (₦1,500, ₦4,800 and ₦6,300 less a kobo-free 1%): one credit of ₦12,474 settles them together.
do $$
declare r jsonb := pg_temp.up(jsonb_build_array(
    pg_temp.row('BRK-12', 10, 1500, '[["Procold Tab X 4"]]', '[["pos", 1500]]', 0, '{"name": "Walk-In Customer"}', '09:00'),
    pg_temp.row('BRK-13', 10, 4800, '[["Otrivin Adults Nasal Drop 01"]]', '[["pos", 4800]]', 0, '{"name": "Walk-In Customer"}', '13:00'),
    pg_temp.row('BRK-14', 10, 6300, '[["Procold Tab X 4"], ["Otrivin Adults Nasal Drop 01"]]', '[["pos", 6300]]', 0, '{"name": "Walk-In Customer"}', '19:30')));
  v uuid := pg_temp.line(11, 12474, 'MONIEPOINT POS SETTLEMENT 11');
begin
  assert private.match_bank_line(v) = 'card_settlement', 'card_settlement_day_batch: stage';
  assert (select count(*) from collections where cleared_line_id = v) = 3, 'card_settlement_day_batch: three payments';
  assert (select debit from journal_lines where journal_id = (select journal_id from bank_lines where id = v) and account_code = private.acct(tests.id('o'), 'payment_fees')) = 126,
    'card_settlement_day_batch: 126 in charges';
end $$;

-- test: settlement_too_short_waits
-- A credit 5% short of a card payment is not a settlement of it.
do $$
declare v uuid := pg_temp.line(5, 950, 'MONIEPOINT SETTLEMENT');
begin
  assert private.match_bank_line(v) is distinct from 'card_settlement', 'settlement_too_short_waits';
end $$;

-- test: transfers_confirmed_by_the_bank
-- Two ₦2,800 walk-in transfers on different days, and the statement shows one ₦2,800 credit: the nearer is confirmed, the
-- other still waits.
do $$
declare r jsonb := pg_temp.up(jsonb_build_array(
    pg_temp.row('BRK-15', 12, 2800, '[["Kiss Lube Gel 120Ml", 1, {"non_stock": true}]]', '[["transfer", 2800]]'),
    pg_temp.row('BRK-16', 14, 2800, '[["Kiss Lube Gel 120Ml", 1, {"non_stock": true}]]', '[["transfer", 2800]]')));
  v uuid := pg_temp.line(14, 2800, 'TRF FROM ADEBAYO JOHN');
begin
  assert (pg_temp.sale_of(r, 0)).status = 'open' and (pg_temp.sale_of(r, 1)).status = 'open', 'transfers_confirmed_by_the_bank: both wait';
  assert private.match_bank_line(v) = 'pending_payment', 'transfers_confirmed_by_the_bank: matched';
  assert (pg_temp.sale_of(r, 1)).status = 'paid' and (pg_temp.sale_of(r, 0)).status = 'open', 'transfers_confirmed_by_the_bank: the nearer one';
end $$;

-- test: finish_matches_lines_already_in
-- A transfer the statement showed before the upload is matched when the upload finishes.
do $$
declare v uuid := pg_temp.line(15, 7350, 'TRF FROM OLUMIDE'); r jsonb;
begin
  r := pg_temp.up(jsonb_build_array(pg_temp.row('BRK-17', 15, 7350, '[["Kiss Lube Gel 120Ml", 1, {"non_stock": true}]]', '[["transfer", 7350]]')));
  assert (select stage from bank_lines where id = v) = 'pending_payment' and (pg_temp.sale_of(r, 0)).status = 'paid', format('finish_matches_lines_already_in: got %s', r->'summary');
  assert (r->'summary'->>'matched_lines')::int = 1, 'finish_matches_lines_already_in: counted';
end $$;

-- test: return_dated_when_it_happened
-- BRK-14 (Procold and Otrivin) comes back in part on day 12: Otrivin returned and ₦4,800 refunded in cash. The credit note
-- is dated day 12, the stock comes back, the VAT on Otrivin (exempt) is nil.
do $$
declare r jsonb; cn public.sales; o public.sales := (select s from sales s where org_id = tests.id('o') and reference = 'BRK-14');
begin
  r := pg_temp.up(jsonb_build_array(jsonb_build_object('row', 2, 'key', 'RET-1', 'kind', 'return', 'original', 'BRK-14', 'at', pg_temp.at(12),
    'lines', '[{"name": "Otrivin Adults Nasal Drop 01", "qty": 1}]'::jsonb, 'payments', '[{"method": "cash", "amount": 4800}]'::jsonb, 'reason', 'Wrong strength')));
  cn := pg_temp.sale_of(r, 0);
  assert r->'rows'->0->>'status' = 'posted' and cn.doc_type = 'credit_note' and cn.issue_date = pg_temp.m1() + 12 and cn.total = 4800 and cn.vat_total = 0,
    format('return_dated_when_it_happened: the credit note, got %s', r->'rows');
  assert cn.original_sale_id = o.id and cn.channel = 'schedule', 'return_dated_when_it_happened: on BRK-14';
  assert (select returned_qty from sale_lines where sale_id = o.id and item_id = tests.id('otrivin')) = 1, 'return_dated_when_it_happened: returned';
  assert (select count(*) from movements where sale_id = cn.id and type = 'sale_return' and qty = 1) = 1, 'return_dated_when_it_happened: stock back';
  assert (select entry_date from journals where id = cn.journal_id) = pg_temp.m1() + 12, 'return_dated_when_it_happened: entry dated day 12';
  assert (r->>'returns')::int = 1 and (r->>'amount')::numeric = -4800, format('return_dated_when_it_happened: summary, got %s', r);
  -- Returning more than is left fails.
  r := pg_temp.up(jsonb_build_array(jsonb_build_object('row', 3, 'key', 'RET-2', 'kind', 'return', 'original', 'BRK-14', 'at', pg_temp.at(13),
    'lines', '[{"name": "Otrivin Adults Nasal Drop 01", "qty": 1}]'::jsonb)));
  assert r->'rows'->0->>'error' like '%more than % can still take back.', format('return_dated_when_it_happened: too many, got %s', r->'rows');
end $$;

-- test: return_sale_unchanged
-- A return made in Counta is still dated today.
do $$
declare s public.sales := (select s from sales s where org_id = tests.id('o') and reference = 'BRK-12'); res jsonb;
begin
  perform tests.as_user(tests.id('ada'));
  res := public.return_sale(s.id, jsonb_build_array(jsonb_build_object('sale_line_id', (select id from sale_lines where sale_id = s.id), 'qty', 1)), '{}'::jsonb, 'Damaged', true);
  perform tests.as_postgres();
  assert (res->'credit_note'->>'issue_date')::date = private.local_day(tests.id('o'), now()), format('return_sale_unchanged: today, got %s', res->'credit_note'->>'issue_date');
end $$;

-- test: products_remembered
-- A person's answer for a name is kept: the next upload uses it, and prepare says so.
do $$
declare p jsonb; r jsonb;
begin
  perform tests.as_user(tests.id('ada'));
  perform public.save_sales_import_products(tests.id('o'), jsonb_build_array(jsonb_build_object('name', 'Procold Tabs (4)', 'mode', 'item', 'item_id', tests.id('procold')),
    jsonb_build_object('name', 'Delivery fee', 'mode', 'non_stock', 'vat_treatment', 'standard')));
  p := public.sales_import_prepare(tests.id('o'), '{"names": ["procold  tabs (4)", "Delivery Fee", "Vigor Chocolate Bar", "Never Seen"], "keys": ["BRK-1", "NEW-1"]}');
  perform tests.as_postgres();
  assert (select string_agg(e->>'key' || ':' || coalesce(e->>'how', '-') || ':' || coalesce(e->>'mode', '-'), ',' order by e->>'key') from jsonb_array_elements(p->'products') e)
    = 'delivery fee:saved:non_stock,never seen:-:-,procold tabs (4):saved:item,vigor chocolate bar:name:item', format('products_remembered: prepare, got %s', p->'products');
  assert p->'posted' = '["BRK-1"]', format('products_remembered: posted keys, got %s', p->'posted');
  r := pg_temp.up(jsonb_build_array(pg_temp.row('BRK-18', 16, 3500, '[["Procold Tabs (4)"], ["Delivery fee", 1, {"price_hint": 2000}]]', '[["cash", 3500]]')));
  assert (select string_agg(coalesce(item_id::text, 'none') || ':' || unit_price, ',' order by line_no) from sale_lines where sale_id = (pg_temp.sale_of(r, 0)).id)
    = tests.id('procold')::text || ':1500.00,none:2000.00', format('products_remembered: used, got %s', r->'rows');
end $$;

-- test: no_notifications_while_posting
-- Pending transfers from an upload tell nobody one by one.
do $$
declare n int := (select count(*) from notifications where org_id = tests.id('o'));
begin
  perform pg_temp.up(jsonb_build_array(pg_temp.row('BRK-19', 16, 2950, '[["Kiss Lube Gel 120Ml", 1, {"non_stock": true}]]', '[["transfer", 2950]]')));
  assert (select count(*) from notifications where org_id = tests.id('o')) = n, 'no_notifications_while_posting';
  assert coalesce(current_setting('counta.quiet', true), '') = '', 'no_notifications_while_posting: quiet ends';
end $$;

-- test: only_managers_upload
do $$
begin
  perform tests.as_user(tests.id('bisi'));
  perform tests.throws($q$select public.sales_import_start(tests.id('o'), '{}')$q$, '%Uploading sales needs a manager%');
  perform tests.throws($q$select public.sales_import_prepare(tests.id('o'), '{}')$q$, '%Uploading sales needs a manager%');
  perform tests.as_anon();
  perform tests.throws($q$select public.get_sales_imports(tests.id('o'))$q$, '%permission denied%');
  perform tests.as_postgres();
end $$;

-- test: undo_upload_whole
-- An upload with card, cash and transfer sales, a settlement and a confirmed transfer, then a return: undone, the books,
-- stock and VAT are as before, and the bank lines are back in the inbox.
do $$
declare tb0 jsonb := pg_temp.tb(); r jsonb; ret jsonb; v1 uuid; v2 uuid; u jsonb; st0 jsonb;
  vat0 jsonb := private.vat_month(tests.id('o'), pg_temp.m1());
begin
  st0 := (select jsonb_object_agg(item_id, q) from (select item_id, sum(qty) q from movements where org_id = tests.id('o') group by 1) z);
  r := pg_temp.up(jsonb_build_array(
    pg_temp.row('UN-1', 18, 6300, '[["Procold Tab X 4"], ["Otrivin Adults Nasal Drop 01"]]', '[["card", 6300]]'),
    pg_temp.row('UN-2', 18, 4200, '[["Vigor Chocolate Bar"]]', '[["cash", 5000]]'),
    pg_temp.row('UN-3', 19, 3100, '[["Procold Tab X 4", 2]]', '[["transfer", 3100]]', 0, '{"name": "Funke Ade"}')), 'Mistake.csv');
  ret := pg_temp.up(jsonb_build_array(jsonb_build_object('row', 2, 'key', 'UN-R1', 'kind', 'return', 'original', 'UN-3', 'at', pg_temp.at(20),
    'lines', '[{"name": "Procold Tab X 4", "qty": 1}]'::jsonb)), 'Mistake returns.csv');
  v1 := pg_temp.line(19, 6237, 'MONIEPOINT SETTLEMENT');
  v2 := pg_temp.line(19, 3100, 'TRF REF 99812');
  assert private.match_bank_line(v1) = 'card_settlement' and private.match_bank_line(v2) = 'pending_payment', 'undo_upload_whole: matched first';
  -- The sales upload cannot go while its return is in another upload that is still in place.
  perform tests.as_user(tests.id('ada'));
  perform tests.throws(format($q$select public.void_sales_import(%L, 'Wrong file')$q$, r->>'id'), '%Nothing was undone: % has a credit note that was not uploaded with it%');
  perform public.void_sales_import((ret->>'id')::uuid, 'Wrong file');
  u := public.void_sales_import((r->>'id')::uuid, 'Wrong file');
  perform tests.throws(format($q$select public.void_sales_import(%L, 'Again')$q$, r->>'id'), '%is already undone.');
  perform tests.as_postgres();
  assert (u->>'undone')::int = 3 and u->'import'->>'status' = 'void', format('undo_upload_whole: undone, got %s', u);
  assert not exists (select 1 from sales where org_id = tests.id('o') and reference like 'UN-%' and status <> 'void'), 'undo_upload_whole: sales void';
  assert pg_temp.tb() = tb0, format('undo_upload_whole: books as before, %s vs %s', pg_temp.tb(), tb0);
  assert (select jsonb_object_agg(item_id, q) from (select item_id, sum(qty) q from movements where org_id = tests.id('o') group by 1) z) = st0, 'undo_upload_whole: stock as before';
  assert (select status <> 'matched' and stage is distinct from 'card_settlement' from bank_lines where id = v1)
    and (select status <> 'matched' and stage is distinct from 'pending_payment' from bank_lines where id = v2), format('undo_upload_whole: lines back, got %s %s',
      (select status || '/' || coalesce(stage, '-') from bank_lines where id = v1), (select status || '/' || coalesce(stage, '-') from bank_lines where id = v2));
  assert (private.vat_month(tests.id('o'), pg_temp.m1())->>'output')::numeric = (vat0->>'output')::numeric,
    format('undo_upload_whole: VAT as before, %s vs %s', private.vat_month(tests.id('o'), pg_temp.m1())->>'output', vat0->>'output');
  -- Undone keys can be uploaded again.
  r := pg_temp.up(jsonb_build_array(pg_temp.row('UN-2', 18, 4200, '[["Vigor Chocolate Bar"]]', '[["cash", 4200]]')));
  assert r->'rows'->0->>'status' = 'posted', format('undo_upload_whole: key free again, got %s', r->'rows');
end $$;

-- test: filed_month_takes_nothing
-- With last month's VAT return filed, a sale dated in it fails and says why; undo of an upload in it is refused.
do $$
declare r jsonb; u0 uuid := (select id from sales_imports where org_id = tests.id('o') and status = 'posted' order by created_at limit 1);
begin
  insert into vat_periods (org_id, period, status, filed_at) values (tests.id('o'), pg_temp.m1(), 'filed', now());
  r := pg_temp.up(jsonb_build_array(pg_temp.row('BRK-20', 20, 1500, '[["Procold Tab X 4"]]', '[["cash", 1500]]')));
  assert r->'rows'->0->>'error' = format('The VAT return for %s is filed. Reopen it to add sales to that month.', to_char(pg_temp.m1(), 'FMMonth YYYY')),
    format('filed_month_takes_nothing: refused, got %s', r->'rows');
  perform tests.as_user(tests.id('ada'));
  perform tests.throws(format($q$select public.void_sales_import(%L, 'Wrong')$q$, u0), '%whose VAT return is filed%');
  perform tests.as_postgres();
  delete from vat_periods where org_id = tests.id('o') and period = pg_temp.m1();
end $$;

-- test: vat_on_payment_basis
-- An uploaded card receipt is paid the day it is made, so its VAT falls in its month; a transfer waiting for the bank
-- waits for it, as any payment does.
do $$
declare r jsonb := pg_temp.up(jsonb_build_array(pg_temp.row('BRK-21', 21, 4200, '[["Vigor Chocolate Bar"]]', '[["card", 4200]]'),
    pg_temp.row('BRK-22', 21, 4200, '[["Vigor Chocolate Bar"]]', '[["transfer", 4200]]')));
begin
  assert exists (select 1 from private.vat_sale_parts(tests.id('o'), pg_temp.m1(), (pg_temp.m1() + interval '1 month - 1 day')::date) p
                 where p.sale_id = (pg_temp.sale_of(r, 0)).id and p.vat = 293.02), 'vat_on_payment_basis: card in the month';
  assert not exists (select 1 from private.vat_sale_parts(tests.id('o'), pg_temp.m1(), (pg_temp.m1() + interval '1 month - 1 day')::date) p
                 where p.sale_id = (pg_temp.sale_of(r, 1)).id), 'vat_on_payment_basis: transfer waits';
end $$;

-- test: a_month_of_sales_in_good_time
-- 365 sales (the size of the Brooks file) post in under 20 seconds in batches of 100.
do $$
declare rows jsonb := '[]'::jsonb; i int; t0 timestamptz := clock_timestamp(); r jsonb;
begin
  for i in 1..365 loop
    rows := rows || pg_temp.row('PERF-' || i, (i % 25) + 1, case i % 3 when 0 then 6300 when 1 then 1500 else 4200 end,
      case i % 3 when 0 then '[["Procold Tab X 4"], ["Otrivin Adults Nasal Drop 01"]]'::jsonb when 1 then '[["Procold Tab X 4"]]'::jsonb else '[["Vigor Chocolate Bar"]]'::jsonb end,
      jsonb_build_array(jsonb_build_array(case i % 3 when 0 then 'card' when 1 then 'cash' else 'transfer' end, case i % 3 when 0 then 6300 when 1 then 1500 else 4200 end)));
  end loop;
  r := pg_temp.up(rows);
  assert (r->>'sales')::int = 365 and (r->>'failed')::int = 0, format('a_month_of_sales_in_good_time: all posted, got %s', r - 'rows');
  assert clock_timestamp() - t0 < interval '20 seconds', format('a_month_of_sales_in_good_time: took %s', clock_timestamp() - t0);
  raise notice 'a_month_of_sales_in_good_time: % for 365 sales', clock_timestamp() - t0;
end $$;

rollback;
