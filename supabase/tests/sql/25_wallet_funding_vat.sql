-- The VAT set aside for the tax wallet and the wallet checks (20261206000100_wallet_funding_vat.sql): money paid into the
-- business wallet carries the whole VAT when the customer kept back WHT or the NCD levy (worked out before or after VAT,
-- paid at once, in parts, or with the credit recorded later), none of the VAT the customer withheld, and nothing for money
-- paid elsewhere; invoices already short are topped up by their credit; a wallet check compares Flutterwave's available
-- balance and closes the earlier "wallet differs" question when it agrees. Only fake people (example.test addresses).
begin;

-- Fixture: Ada owns Ada Clinic Ltd (VAT-registered, with a Tax ID), with a Flutterwave wallet and a tax wallet. Customers:
-- Bola Stores Ltd, Chika Ventures Ltd, Femi Okafor Enterprises, Dayo Farms Ltd (businesses) and a government agency that
-- withholds VAT.
do $$
declare o uuid; w uuid; t uuid;
begin
  perform tests.hooks_on();
  perform tests.remember('ada', tests.user('ada.owner@clinic.example.test', 'Ada Owner'));
  o := tests.remember('o', tests.org(tests.id('ada'), 'Ada Clinic Ltd'));
  update orgs set vat_registered = true, payment_rail = 'flutterwave', payment_methods = '{account,link,qr}', identity_status = 'verified', tin = '12345678-0001'
  where id = o;
  perform tests.as_user(tests.id('ada'));
  perform tests.remember('bola', public.save_customer(o, '{"name": "Bola Stores Ltd", "email": "bola@example.test", "kind": "business"}'));
  perform tests.remember('chika', public.save_customer(o, '{"name": "Chika Ventures Ltd", "email": "chika@example.test", "kind": "business"}'));
  perform tests.remember('femi', public.save_customer(o, '{"name": "Femi Okafor Enterprises", "email": "femi@example.test", "kind": "business"}'));
  perform tests.remember('dayo', public.save_customer(o, '{"name": "Dayo Farms Ltd", "email": "dayo@example.test", "kind": "business"}'));
  perform tests.remember('agency', public.save_customer(o, '{"name": "Example State Agency", "email": "agency@example.test", "kind": "business"}'));
  perform tests.as_postgres();
  update customers set wvat_agent = true where id = tests.id('agency');
  insert into wallets (org_id, rail) values (o, 'flutterwave') returning id into w;
  perform public.svc_wallet_ready(w, '{"account_ref": "PSA-ADA", "account_number": "9911223344", "bank_name": "Flutterwave MFB", "account_name": "Ada Clinic Ltd"}');
  perform tests.remember('w', w);
  insert into tax_wallets (org_id, rail) values (o, 'flutterwave') returning id into t;
  perform public.svc_tax_wallet_ready(t, '{"account_ref": "PSA-ADATAX", "account_number": "9911223355", "bank_name": "Flutterwave MFB", "account_name": "Ada Clinic Ltd Tax", "barter_id": "BARTER-TAX"}');
  assert (select status from tax_wallets where id = t) = 'active', 'fixture: the tax wallet is open';
  perform tests.remember('t', t);
end $$;

-- An issued invoice for one line of p_amt with VAT at 7.5%.
create function pg_temp.inv(p_customer uuid, p_amt numeric) returns uuid language plpgsql as $f$
declare s jsonb;
begin
  perform tests.as_user(tests.id('ada'));
  s := public.save_sale_doc(tests.id('o'), jsonb_build_object('customer_id', p_customer, 'status', 'draft', 'prices_include_vat', false, 'doc_type', 'invoice',
    'lines', jsonb_build_array(jsonb_build_object('description', 'Consulting', 'qty', 1, 'unit_price', p_amt, 'vat_treatment', 'standard'))));
  perform public.issue_invoice((s->>'id')::uuid, null);
  perform tests.as_postgres();
  return (s->>'id')::uuid;
end $f$;
-- The customer's page asks to pay by transfer to the business's own number, for all or part of what is owed.
create function pg_temp.req(p_sale uuid, p_amount numeric default null) returns public.payment_requests language sql as $f$
  select private.open_request(tests.id('o'), p_sale, null, 'account', p_amount,
    (select mm from members mm where mm.org_id = tests.id('o') and mm.user_id = tests.id('ada')), true, null)
$f$;
-- Money reaching the wallet (as the funding webhook or the statement gives it).
create function pg_temp.land(p_amt numeric, p_ref text) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  perform tests.as_service();
  r := public.svc_wallet_inflow('flutterwave', '9911223344', jsonb_build_object('amount', p_amt, 'reference', p_ref, 'narration', 'Received Money from A Customer'));
  perform tests.as_postgres();
  return r;
end $f$;
-- The VAT set aside for a sale (waiting or moved).
create function pg_temp.vat_set(p_sale uuid) returns numeric language sql as $f$
  select coalesce(sum(mv.amount), 0) from tax_moves mv where mv.kind = 'vat' and mv.direction = 'in' and mv.status <> 'cancelled'
    and mv.source_type = 'allocation' and mv.source_id in (select private.alloc_key(a.collection_id, a.sale_id) from collection_allocations a where a.sale_id = p_sale)
$f$;
create function pg_temp.sale(p_sale uuid) returns public.sales language sql as $f$ select * from sales where id = p_sale $f$;
create function pg_temp.kept(p_sale uuid, p_method text) returns numeric language sql as $f$
  select coalesce(sum(a.amount), 0) from collection_allocations a join collections c on c.id = a.collection_id
  where a.sale_id = p_sale and c.method = p_method and c.status = 'confirmed'
$f$;
create function pg_temp.ada() returns public.members language sql as $f$
  select mm from members mm where mm.org_id = tests.id('o') and mm.user_id = tests.id('ada')
$f$;

-- test: vat_full_payment
-- ₦268.75 owed (₦250 and ₦18.75 VAT), paid in full into the wallet: all ₦18.75 is set aside, as before.
do $$
declare v uuid := pg_temp.inv(tests.id('bola'), 250); r public.payment_requests := pg_temp.req(v); res jsonb;
begin
  res := pg_temp.land(268.75, 'FUND-1');
  assert (pg_temp.sale(v)).status = 'paid', format('vat_full_payment: paid, got %s', res);
  assert pg_temp.vat_set(v) = 18.75, format('vat_full_payment: 18.75 set aside, got %s', pg_temp.vat_set(v));
end $$;

-- test: vat_short_by_wht
-- The same invoice paid less 2% WHT on the ₦250 (₦263.75 lands): the cash carries all ₦18.75 of VAT (₦18.40 before).
do $$
declare v uuid := pg_temp.inv(tests.id('chika'), 250); r public.payment_requests := pg_temp.req(v); res jsonb;
begin
  res := pg_temp.land(263.75, 'FUND-2');
  assert (pg_temp.sale(v)).status = 'paid' and pg_temp.kept(v, 'wht_credit') = 5, format('vat_short_by_wht: paid with 5 WHT, got %s', res);
  assert pg_temp.vat_set(v) = 18.75, format('vat_short_by_wht: 18.75 set aside, got %s', pg_temp.vat_set(v));
  assert (select count(*) from tax_moves mv where mv.kind = 'vat' and mv.source_id in
    (select private.alloc_key(a.collection_id, a.sale_id) from collection_allocations a where a.sale_id = v)) = 1, 'vat_short_by_wht: one move';
end $$;

-- test: vat_short_by_wht_on_total
-- 2% worked out on the total with VAT (₦5.38 of ₦268.75, ₦263.37 lands): still all ₦18.75 of VAT.
do $$
declare v uuid := pg_temp.inv(tests.id('femi'), 250); r public.payment_requests := pg_temp.req(v); res jsonb;
begin
  res := pg_temp.land(263.37, 'FUND-3');
  assert (pg_temp.sale(v)).status = 'paid', format('vat_short_by_wht_on_total: paid, got %s', res);
  assert pg_temp.kept(v, 'wht_credit') = 5.38, format('vat_short_by_wht_on_total: 5.38 WHT, got %s', pg_temp.kept(v, 'wht_credit'));
  assert pg_temp.vat_set(v) = 18.75, format('vat_short_by_wht_on_total: 18.75 set aside, got %s', pg_temp.vat_set(v));
end $$;

-- test: vat_short_by_wht_and_ncd
-- ₦2,150 owed (₦2,000 and VAT), ₦2,090 lands: 2% WHT and the 1% NCD levy on the ₦2,000. All ₦150 of VAT is set aside.
do $$
declare v uuid := pg_temp.inv(tests.id('dayo'), 2000); r public.payment_requests := pg_temp.req(v); res jsonb;
begin
  res := pg_temp.land(2090, 'FUND-4');
  assert (pg_temp.sale(v)).status = 'paid' and pg_temp.kept(v, 'wht_credit') = 40 and pg_temp.kept(v, 'ncd_levy') = 20,
    format('vat_short_by_wht_and_ncd: paid with 40 WHT and 20 levy, got %s', res);
  assert pg_temp.vat_set(v) = 150, format('vat_short_by_wht_and_ncd: 150 set aside, got %s', pg_temp.vat_set(v));
end $$;

-- test: vat_withheld_by_customer
-- A government agency withholds the ₦18.75 VAT and sends ₦250: it pays that VAT to the NRS, so nothing is set aside
-- (₦17.44 before). The tax owed in the books agrees: output VAT less VAT withheld.
do $$
declare v uuid := pg_temp.inv(tests.id('agency'), 250); r public.payment_requests := pg_temp.req(v); res jsonb;
begin
  res := pg_temp.land(250, 'FUND-5');
  assert (pg_temp.sale(v)).status = 'paid' and pg_temp.kept(v, 'wvat_credit') = 18.75, format('vat_withheld_by_customer: paid with 18.75 withheld, got %s', res);
  assert pg_temp.vat_set(v) = 0, format('vat_withheld_by_customer: nothing set aside, got %s', pg_temp.vat_set(v));
end $$;

-- test: vat_in_parts_then_wht
-- ₦100 paid first (its share, ₦6.98, set aside), then the rest less 2% WHT on the ₦250 (₦163.75): the second payment tops
-- the VAT up to exactly ₦18.75.
do $$
declare v uuid := pg_temp.inv(tests.id('bola'), 250); r1 public.payment_requests := pg_temp.req(v, 100); r2 public.payment_requests; res jsonb;
begin
  res := pg_temp.land(100, 'FUND-6A');
  assert (pg_temp.sale(v)).status = 'partially_paid', format('vat_in_parts_then_wht: part paid, got %s', res);
  assert pg_temp.vat_set(v) = 6.98, format('vat_in_parts_then_wht: 6.98 after the first, got %s', pg_temp.vat_set(v));
  r2 := pg_temp.req(v);
  res := pg_temp.land(163.75, 'FUND-6B');
  assert (pg_temp.sale(v)).status = 'paid' and pg_temp.kept(v, 'wht_credit') = 5, format('vat_in_parts_then_wht: paid with 5 WHT, got %s', res);
  assert pg_temp.vat_set(v) = 18.75, format('vat_in_parts_then_wht: 18.75 in all, got %s', pg_temp.vat_set(v));
end $$;

-- test: vat_credit_recorded_later
-- ₦263.75 recorded into the wallet by hand as a part payment (₦18.40 set aside on its share), then the customer's ₦5 WHT
-- credit note is recorded: the credit tops the VAT up by ₦0.35 to ₦18.75.
do $$
declare v uuid := pg_temp.inv(tests.id('chika'), 250);
begin
  perform private.add_collection(tests.id('o'), tests.id('chika'), 263.75, 'transfer',
    jsonb_build_object('bank_account_id', (select bank_account_id from wallets where id = tests.id('w')), 'reference', 'FUND-7'), pg_temp.ada(), 'confirmed', array[v]);
  assert (pg_temp.sale(v)).status = 'partially_paid', format('vat_credit_recorded_later: part paid, got %s', to_jsonb(pg_temp.sale(v)));
  assert pg_temp.vat_set(v) = 18.40, format('vat_credit_recorded_later: 18.40 at first, got %s', pg_temp.vat_set(v));
  perform private.book_customer_withholding(tests.id('o'), tests.id('chika'), v, '{"wht": 5, "wht_rate": 0.02}'::jsonb, now(), pg_temp.ada());
  assert (pg_temp.sale(v)).status = 'paid', format('vat_credit_recorded_later: paid, got %s', to_jsonb(pg_temp.sale(v)));
  assert pg_temp.vat_set(v) = 18.75, format('vat_credit_recorded_later: 18.75 after the credit, got %s', pg_temp.vat_set(v));
end $$;

-- test: vat_paid_elsewhere
-- Paid into an ordinary bank account (not the wallet): nothing to set aside.
do $$
declare v uuid := pg_temp.inv(tests.id('femi'), 250); b uuid;
begin
  b := (private.open_bank_account(tests.id('o'), 'bank', 'Ada Clinic GTBank', '{"bank_name": "GTBank", "account_number": "0123456789"}'::jsonb, (pg_temp.ada()).id)).id;
  perform private.add_collection(tests.id('o'), tests.id('femi'), 268.75, 'transfer', jsonb_build_object('bank_account_id', b, 'reference', 'BANK-1'),
    pg_temp.ada(), 'confirmed', array[v]);
  assert (pg_temp.sale(v)).status = 'paid', format('vat_paid_elsewhere: paid, got %s', to_jsonb(pg_temp.sale(v)));
  assert pg_temp.vat_set(v) = 0, format('vat_paid_elsewhere: nothing set aside, got %s', pg_temp.vat_set(v));
end $$;

-- test: vat_topup_of_old_short
-- An invoice paid less WHT under the old rule (₦18.40 set aside): queueing its credit again, as the migration does for
-- every such invoice, adds the missing ₦0.35 once.
do $$
declare v uuid := pg_temp.inv(tests.id('dayo'), 250); r public.payment_requests := pg_temp.req(v); c uuid; n int;
begin
  perform pg_temp.land(263.75, 'FUND-8');
  update tax_moves set amount = 18.40 where kind = 'vat' and source_id in
    (select private.alloc_key(a.collection_id, a.sale_id) from collection_allocations a where a.sale_id = v);
  assert pg_temp.vat_set(v) = 18.40, 'vat_topup_of_old_short: made short as before';
  select cc.id into c from collections cc join collection_allocations a on a.collection_id = cc.id where a.sale_id = v and cc.method = 'wht_credit';
  n := private.queue_vat_moves(c);
  assert n = 1 and pg_temp.vat_set(v) = 18.75, format('vat_topup_of_old_short: topped up, got %s and %s', n, pg_temp.vat_set(v));
  n := private.queue_vat_moves(c);
  assert n = 0 and pg_temp.vat_set(v) = 18.75, 'vat_topup_of_old_short: once only';
end $$;

-- test: wallet_check_available
-- Flutterwave's live answer: available balance equal to the books, ledger 0.00. The check agrees, and a "wallet differs"
-- question left by an earlier check is closed; a real difference still asks.
do $$
declare w uuid := tests.id('w'); books numeric := private.wallet_ledger(tests.id('w')); tbooks numeric := private.tax_wallet_ledger(tests.id('t')); rec jsonb; q uuid;
begin
  perform tests.as_service();
  rec := public.svc_wallet_balance(w, books - 10, 0);
  perform tests.as_postgres();
  assert rec->>'status' = 'difference' and (rec->>'difference')::numeric = -10, format('wallet_check_available: a real gap asks, got %s', rec);
  select id into q from ai_proposals where kind = 'wallet_difference' and status = 'pending' and proposal->>'wallet_id' = w::text;
  assert q is not null, 'wallet_check_available: the question is waiting';
  perform tests.as_service();
  rec := public.svc_wallet_balance(w, books, 0);
  perform tests.as_postgres();
  assert rec->>'status' = 'matched' and (rec->>'provider_balance')::numeric = books, format('wallet_check_available: available agrees, got %s', rec);
  assert (select status from ai_proposals where id = q) = 'superseded', 'wallet_check_available: the earlier question is closed';
  assert not exists (select 1 from ai_proposals where kind = 'wallet_difference' and status = 'pending' and proposal->>'wallet_id' = w::text),
    'wallet_check_available: no question left';
  perform tests.as_service();
  rec := public.svc_tax_wallet_balance(tests.id('t'), tbooks, 0);
  perform tests.as_postgres();
  assert (rec->>'difference')::numeric = 0 and (rec->>'provider')::numeric = tbooks,
    format('wallet_check_available: the tax wallet compares the available balance too, got %s', rec);
end $$;

-- test: wallet_funding_once
-- The funding webhook records a transfer under the bare reference; the statement's line for it later is the same line.
do $$
declare v uuid := pg_temp.inv(tests.id('bola'), 1000); r public.payment_requests := pg_temp.req(v); a jsonb; b jsonb;
begin
  a := pg_temp.land(1075, '000013261120183930000047875549');
  b := pg_temp.land(1075, '000013261120183930000047875549');
  assert a->>'matched' = 'true' and b->>'duplicate' = 'true', format('wallet_funding_once: recorded once, got %s then %s', a, b);
  assert (select count(*) from bank_lines where fingerprint = 'wallet:000013261120183930000047875549') = 1, 'wallet_funding_once: one line';
  assert pg_temp.vat_set(v) = 75, format('wallet_funding_once: 75 set aside, got %s', pg_temp.vat_set(v));
end $$;

rollback;
