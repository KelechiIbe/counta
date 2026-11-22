-- Output VAT on payment basis (20261207000100_vat_payment_basis.sql): an invoice's VAT falls in the month its customer pays,
-- by each payment's share, whatever the customer kept back; credit notes keep their own month; sales recorded as paid when
-- made fall whole in their month; the owner or the accountant can switch a business to invoice basis from the month after
-- its last return; the NRS return, the summary rows and the ledger check follow; bank lines not in the books are flagged.
-- Only fake people (example.test addresses).
begin;

-- Fixture: Ada owns Basis Trading Ltd (VAT-registered, with a Tax ID). Staff Sam records sales; Chuka is its accountant
-- (file_tax). Customers Bola Stores Ltd, Chika Ventures Ltd, Dayo Farms Ltd (businesses) and a state agency that withholds VAT.
do $$
declare o uuid;
begin
  perform tests.hooks_on();
  perform tests.remember('ada', tests.user('ada.owner@basis.example.test', 'Ada Owner'));
  perform tests.remember('sam', tests.user('sam.staff@basis.example.test', 'Sam Staff'));
  perform tests.remember('chuka', tests.user('chuka.cpa@basis.example.test', 'Chuka Accountant'));
  o := tests.remember('o', tests.org(tests.id('ada'), 'Basis Trading Ltd'));
  update orgs set vat_registered = true, tin = '12345678-0001' where id = o;
  perform tests.remember('sam_m', tests.member(o, tests.id('sam'), 'staff'));
  perform tests.remember('chuka_m', tests.member(o, tests.id('chuka'), 'accountant'));
  update members set p_record_sales = true where id = tests.id('sam_m');
  update members set p_file_tax = true, p_keep_books = true where id = tests.id('chuka_m');
  perform tests.as_user(tests.id('ada'));
  perform tests.remember('bola', public.save_customer(o, '{"name": "Bola Stores Ltd", "email": "bola@example.test", "kind": "business"}'));
  perform tests.remember('chika', public.save_customer(o, '{"name": "Chika Ventures Ltd", "email": "chika@example.test", "kind": "business"}'));
  perform tests.remember('dayo', public.save_customer(o, '{"name": "Dayo Farms Ltd", "email": "dayo@example.test", "kind": "business"}'));
  perform tests.remember('agency', public.save_customer(o, '{"name": "Example State Agency", "email": "agency@example.test", "kind": "business"}'));
  perform tests.as_postgres();
  update customers set wvat_agent = true where id = tests.id('agency');
end $$;

-- The first day of the month k months before this one.
create function pg_temp.mon(k int) returns date language sql as $f$
  select (date_trunc('month', private.local_day(tests.id('o'), now())) - make_interval(months => k))::date
$f$;
create function pg_temp.mend(d date) returns date language sql as $f$ select (d + interval '1 month' - interval '1 day')::date $f$;
-- An invoice issued on a day: lines are [net, treatment] pairs, prices before VAT.
create function pg_temp.inv(p_customer uuid, p_day date, p_lines jsonb) returns uuid language plpgsql as $f$
declare s jsonb; ln jsonb := '[]'::jsonb; x jsonb;
begin
  for x in select * from jsonb_array_elements(p_lines) loop
    ln := ln || jsonb_build_object('description', 'Line ' || (jsonb_array_length(ln) + 1), 'qty', 1, 'unit_price', (x->>0)::numeric, 'vat_treatment', x->>1);
  end loop;
  perform tests.as_user(tests.id('ada'));
  s := public.save_sale_doc(tests.id('o'), jsonb_build_object('customer_id', p_customer, 'status', 'draft', 'prices_include_vat', false, 'doc_type', 'invoice',
    'issue_date', p_day, 'lines', ln));
  perform public.issue_invoice((s->>'id')::uuid, p_day);
  perform tests.as_postgres();
  return (s->>'id')::uuid;
end $f$;
-- A payment in cash on a day (noon, Lagos), with anything else the payment record takes.
create function pg_temp.pay(p_sale uuid, p_amt numeric, p_day date, p_extra jsonb default '{}'::jsonb) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  perform tests.as_user(tests.id('ada'));
  r := public.record_payment(tests.id('o'), jsonb_build_object('sale_id', p_sale, 'amount', p_amt, 'method', 'cash',
    'received_at', (p_day::text || 'T12:00:00+01:00')) || p_extra);
  perform tests.as_postgres();
  return r;
end $f$;
-- A sale's output VAT (and value) in a month, as the return takes it.
create function pg_temp.vat_of(p_sale uuid, p_month date) returns numeric language sql as $f$
  select coalesce(sum(case when s.doc_type = 'credit_note' then -p.vat else p.vat end), 0)
  from private.vat_sale_parts(tests.id('o'), p_month, pg_temp.mend(p_month)) p join sales s on s.id = p.sale_id where p.sale_id = p_sale
$f$;
create function pg_temp.net_of(p_sale uuid, p_month date) returns numeric language sql as $f$
  select coalesce(sum(case when s.doc_type = 'credit_note' then -p.net else p.net end), 0)
  from private.vat_sale_parts(tests.id('o'), p_month, pg_temp.mend(p_month)) p join sales s on s.id = p.sale_id where p.sale_id = p_sale
$f$;
create function pg_temp.sale(p_sale uuid) returns public.sales language sql as $f$ select * from sales where id = p_sale $f$;

-- test: basis_default_payment
-- A business with nothing filed is on payment basis from the start, and its owner and accountant can change it.
do $$
declare b jsonb;
begin
  assert private.vat_basis_on(tests.id('o'), pg_temp.mon(24)) = 'payment', 'basis_default_payment: payment';
  perform tests.as_user(tests.id('ada'));
  b := (public.vat_position(tests.id('o'), '{}'::jsonb))->'basis';
  perform tests.as_postgres();
  assert b->>'current' = 'payment' and (b->>'can_change')::boolean, format('basis_default_payment: position, got %s', b);
  perform tests.as_user(tests.id('sam'));
  perform tests.throws($q$select public.set_vat_basis(tests.id('o'), 'invoice')$q$, '%Only the owner or the business''s accountant%');
  perform tests.as_postgres();
end $$;

-- test: unpaid_then_paid_later
-- ₦250 + ₦18.75 VAT dated three months ago, unpaid: nothing in its month, ₦18.75 waiting. Paid in full last month: all of it
-- falls last month.
do $$
declare v uuid := pg_temp.inv(tests.id('bola'), pg_temp.mon(3) + 14, '[[250, "standard"]]');
begin
  assert pg_temp.vat_of(v, pg_temp.mon(3)) = 0 and pg_temp.net_of(v, pg_temp.mon(3)) = 0, 'unpaid_then_paid_later: nothing while unpaid';
  assert (private.vat_output_waiting(tests.id('o'))->>'vat')::numeric = 18.75, format('unpaid_then_paid_later: 18.75 waiting, got %s', private.vat_output_waiting(tests.id('o')));
  assert (private.sale_vat_months(v)->>'waiting')::numeric = 18.75, 'unpaid_then_paid_later: the page says 18.75 waits';
  perform pg_temp.pay(v, 268.75, pg_temp.mon(1) + 4);
  assert (pg_temp.sale(v)).status = 'paid' and (pg_temp.sale(v)).settled_on = pg_temp.mon(1) + 4, format('unpaid_then_paid_later: paid on its day, got %s', (pg_temp.sale(v)).settled_on);
  assert pg_temp.vat_of(v, pg_temp.mon(3)) = 0 and pg_temp.vat_of(v, pg_temp.mon(2)) = 0, 'unpaid_then_paid_later: nothing before the payment';
  assert pg_temp.vat_of(v, pg_temp.mon(1)) = 18.75 and pg_temp.net_of(v, pg_temp.mon(1)) = 250, 'unpaid_then_paid_later: all of it last month';
  assert (private.vat_output_waiting(tests.id('o'))->>'vat')::numeric = 0, 'unpaid_then_paid_later: nothing waits';
end $$;

-- test: part_payments
-- ₦100 paid two months ago and the rest last month: ₦6.98 then ₦11.77, ₦18.75 in all; the page lists both months.
do $$
declare v uuid := pg_temp.inv(tests.id('chika'), pg_temp.mon(3) + 2, '[[250, "standard"]]'); m jsonb;
begin
  perform pg_temp.pay(v, 100, pg_temp.mon(2) + 9, '{"auto_split": false}');
  assert (pg_temp.sale(v)).status = 'partially_paid', 'part_payments: part paid';
  assert pg_temp.vat_of(v, pg_temp.mon(2)) = 6.98, format('part_payments: 6.98 first, got %s', pg_temp.vat_of(v, pg_temp.mon(2)));
  perform pg_temp.pay(v, 168.75, pg_temp.mon(1) + 9);
  assert pg_temp.vat_of(v, pg_temp.mon(1)) = 11.77, format('part_payments: 11.77 second, got %s', pg_temp.vat_of(v, pg_temp.mon(1)));
  assert pg_temp.net_of(v, pg_temp.mon(2)) + pg_temp.net_of(v, pg_temp.mon(1)) = 250, 'part_payments: the value adds up';
  m := private.sale_vat_months(v);
  assert jsonb_array_length(m->'months') = 2 and (m->>'waiting')::numeric = 0
     and (m->'months'->0->>'vat')::numeric = 6.98 and (m->'months'->1->>'vat')::numeric = 11.77, format('part_payments: page months, got %s', m);
end $$;

-- test: paid_less_wht
-- Paid last month less 2% WHT on the ₦250 (₦263.75): the whole ₦18.75 falls last month, worked out by Counta or typed.
do $$
declare v uuid := pg_temp.inv(tests.id('dayo'), pg_temp.mon(2) + 20, '[[250, "standard"]]');
  w uuid := pg_temp.inv(tests.id('dayo'), pg_temp.mon(2) + 21, '[[250, "standard"]]');
begin
  perform pg_temp.pay(v, 263.75, pg_temp.mon(1) + 2);
  assert (pg_temp.sale(v)).status = 'paid', 'paid_less_wht: settled with the WHT credit';
  assert pg_temp.vat_of(v, pg_temp.mon(2)) = 0 and pg_temp.vat_of(v, pg_temp.mon(1)) = 18.75, format('paid_less_wht: all last month, got %s', pg_temp.vat_of(v, pg_temp.mon(1)));
  -- Typed: the WHT credit takes the payment's day (it took the day it was recorded).
  perform pg_temp.pay(w, 263.75, pg_temp.mon(1) + 3, '{"wht_amount": 5, "auto_split": false}');
  assert (select private.local_day(c.org_id, c.received_at) from collections c join collection_allocations a on a.collection_id = c.id
          where a.sale_id = w and c.method = 'wht_credit') = pg_temp.mon(1) + 3, 'paid_less_wht: the typed WHT is dated with the payment';
  assert pg_temp.vat_of(w, pg_temp.mon(1)) = 18.75 and pg_temp.vat_of(w, pg_temp.mon(0)) = 0, 'paid_less_wht: typed, all last month';
end $$;

-- test: vat_withheld_by_customer
-- The agency keeps the ₦18.75 VAT and pays ₦250 last month: ₦18.75 output and ₦18.75 credited that month, nothing to pay.
do $$
declare v uuid := pg_temp.inv(tests.id('agency'), pg_temp.mon(2) + 5, '[[250, "standard"]]'); mo jsonb;
begin
  perform pg_temp.pay(v, 250, pg_temp.mon(1) + 6, '{"wvat_amount": 18.75, "auto_split": false}');
  assert (pg_temp.sale(v)).status = 'paid', 'vat_withheld_by_customer: paid';
  assert pg_temp.vat_of(v, pg_temp.mon(1)) = 18.75 and pg_temp.vat_of(v, pg_temp.mon(2)) = 0, 'vat_withheld_by_customer: output last month';
  mo := private.vat_month(tests.id('o'), pg_temp.mon(1));
  assert (mo->>'wvat_credit')::numeric = 18.75, format('vat_withheld_by_customer: credited last month, got %s', mo);
end $$;

-- test: credit_note_on_unpaid_invoice
-- ₦100 + ₦7.50 dated two months ago; half credited that month; the other half paid last month. The credit note and the
-- share it settles net to nothing in its month, and ₦3.75 falls last month.
do $$
declare v uuid := pg_temp.inv(tests.id('bola'), pg_temp.mon(2) + 10, '[[100, "standard"]]'); cn uuid;
begin
  perform tests.as_user(tests.id('ada'));
  perform public.credit_sale(v, jsonb_build_object('amount', 53.75, 'reason', 'Half returned'));
  perform tests.as_postgres();
  select id into cn from sales where original_sale_id = v and doc_type = 'credit_note';
  update sales set issue_date = pg_temp.mon(2) + 12 where id = cn;
  assert exists (select 1 from credit_allocations where credit_note_id = cn and sale_id = v), 'credit_note_on_unpaid_invoice: the credit settles the invoice';
  assert pg_temp.vat_of(v, pg_temp.mon(2)) = 3.75 and pg_temp.vat_of(cn, pg_temp.mon(2)) = -3.75,
    format('credit_note_on_unpaid_invoice: 3.75 and -3.75, got %s and %s', pg_temp.vat_of(v, pg_temp.mon(2)), pg_temp.vat_of(cn, pg_temp.mon(2)));
  perform pg_temp.pay(v, 53.75, pg_temp.mon(1) + 1);
  assert (pg_temp.sale(v)).status = 'paid', 'credit_note_on_unpaid_invoice: paid';
  assert pg_temp.vat_of(v, pg_temp.mon(1)) = 3.75, format('credit_note_on_unpaid_invoice: 3.75 last month, got %s', pg_temp.vat_of(v, pg_temp.mon(1)));
end $$;

-- test: recorded_paid_when_made
-- A sale recorded as paid when it was made (as a sales schedule, the bank or a POS terminal records it, with no payment
-- row): it falls whole in its own month.
do $$
declare v uuid := pg_temp.inv(tests.id('chika'), pg_temp.mon(2) + 7, '[[400, "standard"], [100, "zero"]]');
begin
  update sales set amount_paid = total, status = 'paid' where id = v;
  assert (pg_temp.sale(v)).settled_on = pg_temp.mon(2) + 7, format('recorded_paid_when_made: settled on its day, got %s', (pg_temp.sale(v)).settled_on);
  assert pg_temp.vat_of(v, pg_temp.mon(2)) = 30 and pg_temp.net_of(v, pg_temp.mon(2)) = 500, 'recorded_paid_when_made: all in its month';
end $$;

-- test: return_rows_and_tie
-- A month with a part-paid invoice of a standard and a zero-rated line: schedule A carries each line's paid share, line 115
-- ties to Counta's VAT, the unpaid share is explained, and the summary rows' ledger check comes to nothing.
do $$
declare v uuid := pg_temp.inv(tests.id('dayo'), pg_temp.mon(4) + 3, '[[1000, "standard"], [1000, "zero"]]'); sc jsonb; rows jsonb; d numeric;
begin
  -- ₦2,075 owed; ₦1,037.50 paid the same month: half of each line.
  perform pg_temp.pay(v, 1037.50, pg_temp.mon(4) + 20, '{"auto_split": false}');
  perform tests.as_user(tests.id('ada'));
  sc := public.vat_schedule(tests.id('o'), pg_temp.mon(4));
  perform tests.as_postgres();
  assert (sc->'lines'->>'10')::numeric = 1000 and (sc->'lines'->>'20')::numeric = 500, format('return_rows_and_tie: half of each line, got %s', sc->'lines');
  assert (sc->'counta'->>'output')::numeric = 37.50, format('return_rows_and_tie: 37.50 output, got %s', sc->'counta');
  assert not exists (select 1 from jsonb_array_elements(sc->'checks') c where c->>'code' = 'tie'), format('return_rows_and_tie: ties, got %s', sc->'checks');
  assert exists (select 1 from jsonb_array_elements(sc->'checks') c where c->>'code' = 'unpaid_invoices' and (c->>'vat')::numeric = 37.50),
    format('return_rows_and_tie: the unpaid share is explained, got %s', sc->'checks');
  rows := private.vat_rows(tests.id('o'), pg_temp.mon(4), pg_temp.mend(pg_temp.mon(4)));
  select (r->>'current')::numeric into d from jsonb_array_elements(rows) r where r->>'line' = 'Difference to explain';
  assert abs(coalesce(d, 99)) < 0.01, format('return_rows_and_tie: the ledger check comes to nothing, got %s in %s', d, rows);
end $$;

-- test: month_sums_its_parts
-- Every month's output VAT is the sum of what each sale puts in it.
do $$
declare k int;
begin
  for k in 0..5 loop
    assert (private.vat_month(tests.id('o'), pg_temp.mon(k))->>'output')::numeric
      = (select coalesce(sum(case when s.doc_type = 'credit_note' then -p.vat else p.vat end), 0)
         from private.vat_sale_parts(tests.id('o'), pg_temp.mon(k), pg_temp.mend(pg_temp.mon(k))) p join sales s on s.id = p.sale_id),
      format('month_sums_its_parts: month %s', pg_temp.mon(k));
  end loop;
end $$;

-- test: bank_lines_waiting
-- A bank line of last month still in the Books inbox: the return and the position say so.
do $$
declare ba uuid; sc jsonb; pos jsonb;
begin
  insert into bank_accounts (org_id, name, bank_name, account_number, kind, ledger_code) values (tests.id('o'), 'Kuda Operations', 'Kuda Bank', '1234567890', 'bank', '1103')
  returning id into ba;
  insert into bank_lines (org_id, bank_account_id, line_date, description, amount, status, source, fingerprint)
  values (tests.id('o'), ba, pg_temp.mon(1) + 12, 'agency fee', 700000, 'proposed', 'api', 'test:bw1'),
         (tests.id('o'), ba, pg_temp.mon(1) + 13, 'fuel', -50500, 'unmatched', 'api', 'test:bw2'),
         (tests.id('o'), ba, pg_temp.mon(1) + 14, 'charges', -50, 'posted', 'api', 'test:bw3');
  perform tests.as_user(tests.id('ada'));
  sc := public.vat_schedule(tests.id('o'), pg_temp.mon(1));
  pos := public.vat_position(tests.id('o'), jsonb_build_object('from', pg_temp.mon(3), 'to', pg_temp.mon(0)));
  perform tests.as_postgres();
  assert exists (select 1 from jsonb_array_elements(sc->'checks') c where c->>'code' = 'bank_waiting' and (c->>'lines')::int = 2
    and (c->>'money_in')::numeric = 700000 and (c->>'money_out')::numeric = 50500), format('bank_lines_waiting: return check, got %s', sc->'checks');
  assert (pos->'bank_waiting'->(pg_temp.mon(1)::text)->>'lines')::int = 2, format('bank_lines_waiting: position, got %s', pos->'bank_waiting');
end $$;

-- test: switch_to_invoice_basis
-- The accountant switches to invoice basis (nothing filed, so from the start): an unpaid invoice falls in its own month.
-- Switching back puts it on payment basis again.
do $$
declare v uuid := pg_temp.inv(tests.id('bola'), pg_temp.mon(5) + 1, '[[80, "standard"]]'); b jsonb;
begin
  assert pg_temp.vat_of(v, pg_temp.mon(5)) = 0, 'switch_to_invoice_basis: waits on payment basis';
  perform tests.as_user(tests.id('chuka'));
  b := public.set_vat_basis(tests.id('o'), 'invoice');
  perform tests.as_postgres();
  assert b->>'current' = 'invoice', format('switch_to_invoice_basis: switched, got %s', b);
  assert pg_temp.vat_of(v, pg_temp.mon(5)) = 6, format('switch_to_invoice_basis: in its own month, got %s', pg_temp.vat_of(v, pg_temp.mon(5)));
  assert private.sale_vat_months(v)->>'basis' = 'invoice', 'switch_to_invoice_basis: the page says so';
  perform tests.as_user(tests.id('ada'));
  b := public.set_vat_basis(tests.id('o'), 'payment');
  perform tests.as_postgres();
  assert b->>'current' = 'payment' and pg_temp.vat_of(v, pg_temp.mon(5)) = 0, 'switch_to_invoice_basis: back to payment';
  assert (select count(*) from vat_basis_changes where org_id = tests.id('o')) = 2, 'switch_to_invoice_basis: both changes on record';
end $$;

-- test: switch_after_a_filed_month
-- With a month filed, a switch takes effect the month after: invoices dated before it keep the old basis.
do $$
declare o uuid := tests.id('o'); early uuid; late uuid; b jsonb;
begin
  early := pg_temp.inv(tests.id('chika'), pg_temp.mon(5) + 20, '[[200, "standard"]]');
  late := pg_temp.inv(tests.id('chika'), pg_temp.mon(3) + 20, '[[200, "standard"]]');
  perform tests.as_user(tests.id('ada'));
  perform public.file_vat_return(o, pg_temp.mon(5), '{}'::jsonb);
  b := public.set_vat_basis(o, 'invoice');
  perform tests.as_postgres();
  assert (b->>'from')::date = pg_temp.mon(4), format('switch_after_a_filed_month: from the month after, got %s', b);
  assert private.vat_basis_on(o, pg_temp.mon(5) + 20) = 'payment' and private.vat_basis_on(o, pg_temp.mon(3) + 20) = 'invoice', 'switch_after_a_filed_month: by date';
  assert pg_temp.vat_of(late, pg_temp.mon(3)) = 15, 'switch_after_a_filed_month: the later invoice in its own month';
  perform pg_temp.pay(early, 215, pg_temp.mon(2) + 1);
  assert pg_temp.vat_of(early, pg_temp.mon(2)) = 15 and pg_temp.vat_of(early, pg_temp.mon(5)) = 0, 'switch_after_a_filed_month: the earlier one still follows its payment';
  perform tests.as_user(tests.id('ada'));
  perform public.set_vat_basis(o, 'payment');
  perform tests.as_postgres();
end $$;

-- test: performance_many_sales
-- 1,200 invoices over 24 months, most paid the month after: the twelve-month position is quick.
do $$
declare o uuid := tests.id('o'); c uuid := tests.id('dayo'); i int; s uuid; t0 timestamptz; ms numeric; loc uuid := private.main_location(o); j uuid;
begin
  select id into j from journals where org_id = o limit 1;
  for i in 1..1200 loop
    insert into sales (org_id, doc_type, number, status, customer_id, customer_name, location_id, channel, issue_date, prices_include_vat, vat_registered,
      subtotal, vat_total, total, amount_paid, journal_id, issued_at)
    values (o, 'invoice', 'PERF-' || i, 'open', c, 'Dayo Farms Ltd', loc, 'invoice', pg_temp.mon(1 + i % 24) + (i % 27), false, true, 1000, 75, 1075, 0, j, now())
    returning id into s;
    insert into sale_lines (sale_id, org_id, line_no, kind, description, qty, unit_label, unit_price, vat_treatment, vat_rate, net, vat, gross, revenue_account)
    values (s, o, 1, 'goods', 'Perf', 1, 'unit', 1000, 'standard', 0.075, 1000, 75, 1075, '4001');
    if i % 5 <> 0 then
      update sales set amount_paid = 1075, status = 'paid' where id = s;
    end if;
  end loop;
  perform tests.as_user(tests.id('ada'));
  t0 := clock_timestamp();
  perform public.vat_position(o, jsonb_build_object('from', pg_temp.mon(11), 'to', pg_temp.mon(0)));
  ms := extract(epoch from clock_timestamp() - t0) * 1000;
  perform tests.as_postgres();
  raise notice 'performance_many_sales: % ms', round(ms);
  assert ms < 8000, format('performance_many_sales: under 8s, took %s ms', round(ms));
end $$;

rollback;
