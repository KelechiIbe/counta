-- Fee billing: the firm's own business (linked when a partner is its real owner, or created with identity pending so payments
-- stay locked until a director's identity is verified), a fee customer per practice client in it, and each fee invoice of a
-- full-mandate client posted as a bill (professional fees) in the client's own books as its contact: the vendor kept, the
-- event logged, the activity log's actor put back. The mirror never blocks issuing: a failure is recorded and tried again by
-- a lead; an involved client gets nothing; a client whose engagement has ended gets no bill (recorded as skipped) and its
-- read-only books are never written. A voided fee invoice voids its unpaid bill. The fees overview shows wallet balances to
-- partners only. Edge-function calls are only recorded in net._requests.
begin;

-- Fixture: a verified practice (partner Bisi, manager Tola, staff Ada) that runs Adire Foods Ltd under full mandate and is
-- involved with Dayo Bakery Ltd (owned by Dayo); another practice (partner Kemi); someone outside; hooks on.
do $$
declare v_partner uuid; pr uuid; c uuid; o uuid;
begin
  v_partner := tests.remember('partner', tests.user('partner@feefirm.example.test', 'Bisi Partner'));
  perform tests.remember('manager', tests.user('tola.manager@feefirm.example.test', 'Tola Manager'));
  perform tests.remember('staff', tests.user('ada.staff@feefirm.example.test', 'Ada Staff'));
  perform tests.remember('dayo', tests.user('dayo@bakery.example.test', 'Dayo Baker'));
  perform tests.remember('kemi', tests.user('kemi@otherfirm.example.test', 'Kemi Other'));
  perform tests.remember('someone', tests.user('someone@example.test', 'Some One'));
  pr := tests.remember('pr', tests.practice(v_partner, 'Fee Partners', true));
  update practices set email = 'office@feefirm.example.test' where id = pr;
  perform tests.practice_member(pr, tests.id('manager'), 'manager');
  perform tests.practice_member(pr, tests.id('staff'), 'staff');
  -- Bisi is the practice's first partner (in one transaction everyone would join at the same moment).
  update practice_members set created_at = created_at + interval '1 minute' where practice_id = pr and user_id <> v_partner;
  perform tests.remember('pr2', tests.practice(tests.id('kemi'), 'Kemi Partners', true));
  c := tests.remember('c1', tests.full_client(pr, v_partner, 'Adire Foods Ltd'));
  perform tests.remember('o1', (select org_id from practice_clients where id = c));
  o := tests.remember('dayo_org', tests.org(tests.id('dayo'), 'Dayo Bakery Ltd'));
  update orgs set phone = '08031234567', address = '1 Bakery Road, Lagos' where id = o;
  perform tests.remember('ci', tests.involved_client(pr, o));
  perform tests.hooks_on();
end $$;

-- A fee invoice of p_amount before VAT (standard rate), issued by the signed-in person in the firm business to p_customer,
-- dated p_date (today when null). Returns the invoice.
create function pg_temp.fee_invoice(p_org uuid, p_customer uuid, p_amount numeric, p_date date default null) returns uuid language plpgsql as $f$
begin
  return (public.save_sale_doc(p_org, jsonb_build_object('customer_id', p_customer, 'status', 'issue', 'prices_include_vat', false,
    'lines', jsonb_build_array(jsonb_build_object('description', 'Professional fees', 'qty', 1, 'unit_price', p_amount, 'vat_treatment', 'standard')))
    || case when p_date is not null then jsonb_build_object('issue_date', p_date) else '{}'::jsonb end)->>'id')::uuid;
end $f$;

-- test: firm_business
-- Only a partner sets up the firm's own business. A business is linked only when the partner is its real owner (not acting
-- for it, as in a business the firm runs, nor an ordinary business someone else owns), never a sample, never another
-- practice's; otherwise one is created with create_org (the partner its owner). Fees need it first. One per practice; linking
-- the same one again is a no-op.
do $$
declare pr uuid := tests.id('pr'); pr2 uuid := tests.id('pr2'); f uuid; k uuid; v_sample uuid; r jsonb;
begin
  perform tests.as_user(tests.id('manager'));
  perform tests.throws(format($q$select public.practice_firm_business(%L, '{"name":"Firm Books Ltd"}')$q$, pr), '%partner%');
  perform tests.throws(format($q$select public.practice_firm_business(%L, '{"name":"Firm Books Ltd"}')$q$, pr), '42501: Only a partner sets up%');
  perform tests.as_user(tests.id('staff'));
  perform tests.throws(format($q$select public.practice_firm_business(%L, '{"name":"Firm Books Ltd"}')$q$, pr), '42501: Only partners and managers%');
  perform tests.as_user(tests.id('someone'));
  perform tests.throws(format($q$select public.practice_firm_business(%L, '{"name":"Firm Books Ltd"}')$q$, pr), '%not on this practice%');
  perform tests.as_user(tests.id('partner'));
  -- Fees need the firm's business first.
  perform tests.throws(format($q$select public.practice_fee_customer(%L, '{}')$q$, tests.id('c1')), '%firm''s own business first%');
  -- The business the firm runs (Bisi acts as its owner) and Dayo's business are not Bisi's own.
  perform tests.throws(format('select public.practice_firm_business(%L, %L)', pr, jsonb_build_object('org_id', tests.id('o1'))), '%own%');
  perform tests.throws(format('select public.practice_firm_business(%L, %L)', pr, jsonb_build_object('org_id', tests.id('dayo_org'))), '%own%');
  perform tests.throws(format('select public.practice_firm_business(%L, %L)', pr, '{"org_id":"not-a-uuid"}'), '%own%');
  v_sample := public.create_org('Bisi Sample Shop', p_is_sample => true);
  perform tests.throws(format('select public.practice_firm_business(%L, %L)', pr, jsonb_build_object('org_id', v_sample)), '%sample%');
  perform tests.throws(format($q$select public.practice_firm_business(%L, '{"name":"  "}')$q$, pr), '%name%');
  perform tests.as_postgres();
  assert (select firm_org_id from practices where id = pr) is null, 'firm_business: nothing linked by a refusal';

  perform tests.as_user(tests.id('partner'));
  r := public.practice_firm_business(pr, '{"name":"Firm Books Ltd"}');
  f := tests.remember('f', (r->>'firm_org_id')::uuid);
  assert r = jsonb_build_object('firm_org_id', f), format('firm_business: result, got %s', r);
  perform tests.as_postgres();
  assert (select role from members where org_id = f and user_id = tests.id('partner')) = 'owner', 'firm_business: partner owns it';
  assert (select firm_org_id from practices where id = pr) = f, 'firm_business: linked';
  assert (select (name, email, managed_by, is_sample) is not distinct from ('Firm Books Ltd', 'partner@feefirm.example.test', null::uuid, false) from orgs where id = f),
    'firm_business: an ordinary business, its email the partner''s';
  assert (select display_name from members where org_id = f and user_id = tests.id('partner')) = 'Bisi Partner', 'firm_business: the partner''s name';

  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format('select public.practice_firm_business(%L, %L)', pr, jsonb_build_object('org_id', tests.id('o1'))), '%own%');
  -- One per practice: a second is refused; the same one again is a no-op.
  perform tests.throws(format($q$select public.practice_firm_business(%L, '{"name":"Second Firm Ltd"}')$q$, pr), '%already%');
  k := public.create_org('Bisi Consulting Ltd');
  perform tests.throws(format('select public.practice_firm_business(%L, %L)', pr, jsonb_build_object('org_id', k)), '%already%');
  assert public.practice_firm_business(pr, jsonb_build_object('org_id', f)) = jsonb_build_object('firm_org_id', f), 'firm_business: linked again';
  perform tests.as_postgres();
  assert (select count(*) from orgs where name = 'Second Firm Ltd') = 0, 'firm_business: no second business made';

  -- Bisi's business is not another practice's too, even where Bisi is also a partner.
  perform tests.as_postgres();
  perform tests.practice_member(pr2, tests.id('partner'), 'partner');
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format('select public.practice_firm_business(%L, %L)', pr2, jsonb_build_object('org_id', f)), '%another practice%');
  perform tests.as_postgres();
  delete from practice_members where practice_id = pr2 and user_id = tests.id('partner');
  -- Kemi links a business she owns to her practice, never Bisi's.
  k := tests.org(tests.id('kemi'), 'Kemi Advisory Ltd');
  perform tests.as_user(tests.id('kemi'));
  perform tests.throws(format('select public.practice_firm_business(%L, %L)', pr2, jsonb_build_object('org_id', f)), '%own%');
  assert public.practice_firm_business(pr2, jsonb_build_object('org_id', k)) = jsonb_build_object('firm_org_id', k), 'firm_business: link';
  perform tests.as_postgres();
  assert (select firm_org_id from practices where id = pr2) = k and (select identity_status from orgs where id = k) = 'not_required',
    'firm_business: a linked business keeps its identity status';
end $$;

-- test: firm_business_identity_pending
-- A firm business created here starts with identity pending (not the default not_required): payments stay locked until a
-- director's identity is verified, the usual way.
do $$
declare f uuid := tests.id('f');
begin
  assert (select identity_status from orgs where id = f) = 'pending' and not private.payments_open(f),
    'firm_business_identity_pending: payments stay locked until identity is verified';
  update orgs set identity_status = 'verified' where id = f;
  assert private.payments_open(f), 'firm_business_identity_pending: open once verified';
end $$;

-- test: fee_customer_idempotent
-- A lead upserts each client's customer in the firm business, as the firm business's contact: named as the client business,
-- its email, phone and address as given; an involved client's start from the business's own. Called again it keeps the same
-- customer and what was given before. Staff, other practices and clients that are not connected are refused.
do $$
declare f uuid := tests.id('f'); c uuid := tests.id('c1'); cu uuid; r jsonb; v_invited uuid;
begin
  perform tests.as_user(tests.id('manager'));
  r := public.practice_fee_customer(c, '{"email":"accounts@client.example.test"}');
  assert r = public.practice_fee_customer(c, '{}'), 'fee_customer_idempotent';
  cu := tests.remember('cu1', (r->>'customer_id')::uuid);
  perform tests.as_postgres();
  assert (select fee_customer_id from practice_clients where id = c) = cu, 'fee_customer_idempotent: stored';
  assert (select (org_id, name, email, phone, address, created_by) is not distinct from (f, 'Adire Foods Ltd', 'accounts@client.example.test', null::text, null::text,
      (private.org_contact(f)).id) from customers where id = cu),
    'fee_customer_idempotent: named as the client, the email given, as the firm business''s contact';
  -- A full-mandate client's business email is the firm's own: never taken.
  perform tests.as_user(tests.id('partner'));
  r := public.practice_fee_customer(c, '{"phone":"0803 111 2222","address":"5 Adire Close, Abeokuta"}');
  perform tests.as_postgres();
  assert (r->>'customer_id')::uuid = cu and (select (email, phone, address) = ('accounts@client.example.test', '+2348031112222', '5 Adire Close, Abeokuta')
      from customers where id = cu), 'fee_customer_idempotent: details added, the email kept';
  -- An involved client: the business's own details.
  perform tests.as_user(tests.id('partner'));
  r := public.practice_fee_customer(tests.id('ci'), '{}');
  perform tests.remember('cu_inv', (r->>'customer_id')::uuid);
  perform tests.as_postgres();
  assert (select (name, email, phone, address) = ('Dayo Bakery Ltd', 'dayo@bakery.example.test', '+2348031234567', '1 Bakery Road, Lagos')
      from customers where id = tests.id('cu_inv') and org_id = f), 'fee_customer_idempotent: an involved client''s own details';
  assert tests.id('cu_inv') <> cu, 'fee_customer_idempotent: one customer per client';
  -- Refused: staff, someone outside, a client of another practice, an invitation not yet taken.
  perform tests.as_user(tests.id('staff'));
  perform tests.throws(format($q$select public.practice_fee_customer(%L, '{}')$q$, c), '42501: Only partners and managers%');
  perform tests.as_user(tests.id('kemi'));
  perform tests.throws(format($q$select public.practice_fee_customer(%L, '{}')$q$, c), '%not on this practice%');
  perform tests.as_postgres();
  insert into practice_clients (practice_id, status, initiated_by, invite_email, invite_name, business_name)
  values (tests.id('pr'), 'invited', 'practice', 'new@client.example.test', 'New Client', 'New Client Ltd')
  returning id into v_invited;
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_fee_customer(%L, '{}')$q$, v_invited), '%connected%');
  perform tests.throws(format($q$select public.practice_fee_customer(%L, '{"email":"not an email"}')$q$, c), '%email address%');
  perform tests.as_postgres();
end $$;

-- The fee bill record of an invoice.
create function pg_temp.fb(p_sale uuid) returns public.practice_fee_bills language sql as $f$
  select * from practice_fee_bills where sale_id = p_sale
$f$;

-- test: fee_mirror_posts_bill
-- The firm issues 100,000 + VAT to a full-mandate client's fee customer: the invoice is posted as an approved bill in the
-- client's books (professional fees, input VAT, the payable), from the practice as vendor (kept for next time), as the
-- client's contact, and logged. The activity log's actor is put back afterwards. A second call changes nothing.
do $$
declare f uuid := tests.id('f'); o uuid := tests.id('o1'); v_sale uuid; v_fb public.practice_fee_bills; v_bill public.bills; v_vendor public.vendors; v_inv text;
  v_actor text := coalesce(current_setting('counta.actor', true), '');
begin
  update orgs set tin = '23456789-0001' where id = f;
  perform tests.as_user(tests.id('partner'));
  v_sale := tests.remember('sale', pg_temp.fee_invoice(f, tests.id('cu1'), 100000));
  perform tests.as_postgres();
  assert coalesce(current_setting('counta.actor', true), '') = v_actor, 'fee_mirror_posts_bill: the actor put back';
  v_fb := pg_temp.fb(v_sale);
  assert (select b.source = 'practice_fee' and b.total = s.total and b.status = 'approved' from practice_fee_bills x join bills b on b.id = x.bill_id
          join sales s on s.id = x.sale_id where x.sale_id = tests.id('sale')), 'fee_mirror_posts_bill: totals match';
  assert (v_fb.practice_id, v_fb.client_id, v_fb.status, v_fb.error, v_fb.attempts) is not distinct from (tests.id('pr'), tests.id('c1'), 'posted', null::text, 1),
    format('fee_mirror_posts_bill: the record, got %s', to_jsonb(v_fb));
  assert exists (select 1 from bill_lines where bill_id = (select bill_id from practice_fee_bills where sale_id = v_sale) and account_code = '6502'), 'fee_mirror_posts_bill: professional fees account';
  assert (select vendor_id from bills where id = (select bill_id from practice_fee_bills where sale_id = v_sale)) = (select fee_vendor_id from practice_clients where id = tests.id('c1')),
    'fee_mirror_posts_bill: vendor kept';
  assert exists (select 1 from activity_log where org_id = o and action = 'fee_bill_posted'), 'fee_mirror_posts_bill: logged';
  select * into v_bill from bills where id = v_fb.bill_id;
  select number into v_inv from sales where id = v_sale;
  assert (v_bill.org_id, v_bill.vendor_ref, v_bill.bill_date, v_bill.due_date, v_bill.subtotal, v_bill.vat_total, v_bill.total, v_bill.vat_charged, v_bill.prices_include_vat, v_bill.wht_category, v_bill.created_by)
       = (o, v_inv, (select issue_date from sales where id = v_sale), (select due_date from sales where id = v_sale), 100000.00::numeric, 7500.00::numeric,
          107500.00::numeric, true, false, 'professional', (private.org_contact(o)).id),
    format('fee_mirror_posts_bill: the bill, got %s', to_jsonb(v_bill));
  assert (select count(*) from bill_lines where bill_id = v_bill.id) = 1
     and (select (description, qty, unit_cost, vat_treatment, net, vat) = ('Professional fees', 1.000, 100000.00, 'standard', 100000.00, 7500.00)
          from bill_lines where bill_id = v_bill.id), 'fee_mirror_posts_bill: one line per invoice line';
  select * into v_vendor from vendors where id = v_bill.vendor_id;
  assert (v_vendor.org_id, v_vendor.name, v_vendor.tin, v_vendor.email, v_vendor.wht_category) = (o, 'Fee Partners', '23456789-0001', 'office@feefirm.example.test', 'professional'),
    format('fee_mirror_posts_bill: the practice as vendor, got %s', to_jsonb(v_vendor));
  assert (select debit from journal_lines where journal_id = v_bill.journal_id and account_code = '6502') = 100000
     and (select debit from journal_lines where journal_id = v_bill.journal_id and account_code = private.acct(o, 'input_vat')) = 7500
     and (select credit from journal_lines where journal_id = v_bill.journal_id and account_code = private.acct(o, 'payables')) = 107500,
    'fee_mirror_posts_bill: professional fees, input VAT and the payable';
  assert (select (practice_id, source, actor_user) = (tests.id('pr'), 'event', tests.id('partner')) and label like '%' || v_bill.number || '%' and after->>'invoice' = v_inv
          from activity_log where org_id = o and action = 'fee_bill_posted'), 'fee_mirror_posts_bill: the event';
  -- Again: nothing more.
  v_fb := private.fee_mirror(v_sale);
  assert v_fb.status = 'posted' and v_fb.attempts = 1 and (select count(*) from bills where org_id = o and source = 'practice_fee') = 1, 'fee_mirror_posts_bill: once';
  -- The next invoice uses the vendor kept, even after it is renamed in the client's books.
  update vendors set name = 'Fee Partners (accountants)' where id = v_vendor.id;
  perform tests.as_user(tests.id('partner'));
  v_sale := tests.remember('sale_p', pg_temp.fee_invoice(f, tests.id('cu1'), 40000));
  perform tests.as_postgres();
  assert (select b2.vendor_id = v_vendor.id from bills b2 where b2.id = (pg_temp.fb(v_sale)).bill_id), 'fee_mirror_posts_bill: the vendor kept is used';
  -- An invoice priced with VAT included: the bill's VAT and total are the invoice's to the kobo (45,000 with VAT taken back to
  -- 41,860.47 and charged VAT again would come to 45,000.01).
  perform tests.as_user(tests.id('partner'));
  v_sale := (public.save_sale_doc(f, jsonb_build_object('customer_id', tests.id('cu1'), 'status', 'issue', 'prices_include_vat', true,
    'lines', '[{"description": "Advisory, VAT included", "qty": 1, "unit_price": 45000, "vat_treatment": "standard"}]'::jsonb))->>'id')::uuid;
  perform tests.as_postgres();
  assert (select (b2.subtotal, b2.vat_total, b2.total) = (s2.subtotal, s2.vat_total, s2.total) and b2.total = 45000
          from bills b2, sales s2 where b2.id = (pg_temp.fb(v_sale)).bill_id and s2.id = v_sale), 'fee_mirror_posts_bill: VAT included, to the kobo';
  -- 6507 when the client has no 6502.
  insert into org_accounts (org_id, code, name, parent_code, kind, category, normal_balance, statement, ifrs_line, cash_flow_class, active)
  select o, a.code, a.name, a.parent_code, 'custom', a.category, a.normal_balance, a.statement, a.ifrs_line, a.cash_flow_class, false from accounts a where a.code = '6502';
  perform tests.as_user(tests.id('partner'));
  v_sale := pg_temp.fee_invoice(f, tests.id('cu1'), 1000);
  perform tests.as_postgres();
  assert (select account_code from bill_lines where bill_id = (pg_temp.fb(v_sale)).bill_id) = '6507', 'fee_mirror_posts_bill: other professional fees';
  delete from org_accounts where org_id = o and code = '6502';
end $$;

-- test: fee_mirror_involved_none
-- An involved client keeps its own books: nothing is posted or recorded. Nor for a customer that is not a fee customer, nor
-- for an ordinary business's invoices.
do $$
declare f uuid := tests.id('f'); s uuid; cu uuid; n bigint;
begin
  n := (select count(*) from bills where org_id = tests.id('dayo_org'));
  perform tests.as_user(tests.id('partner'));
  s := tests.remember('involved_sale', pg_temp.fee_invoice(f, tests.id('cu_inv'), 50000));
  cu := public.save_customer(f, '{"name": "Walk-up Client", "email": "walkup@example.test"}');
  perform pg_temp.fee_invoice(f, cu, 20000);
  perform tests.as_user(tests.id('dayo'));
  cu := public.save_customer(tests.id('dayo_org'), '{"name": "Adire Foods Ltd", "email": "adire@example.test"}');
  perform pg_temp.fee_invoice(tests.id('dayo_org'), cu, 20000);
  perform tests.as_postgres();
  assert not exists (select 1 from practice_fee_bills where sale_id = tests.id('involved_sale')), 'fee_mirror_involved_none';
  assert (select status from sales where id = tests.id('involved_sale')) = 'open', 'fee_mirror_involved_none: issued';
  assert (select count(*) from practice_fee_bills) = 4 and (select count(*) from bills where org_id = tests.id('dayo_org')) = n,
    'fee_mirror_involved_none: nothing else recorded or posted';
end $$;

-- test: fee_mirror_failure_never_blocks
-- The client's books are closed through the invoice's date: the invoice is issued all the same, and the record says why the
-- bill failed. Once the month is reopened a lead tries it again (failed records only). A retry put back the actor it found.
do $$
declare f uuid := tests.id('f'); o uuid := tests.id('o1'); v_day date; s2 uuid; s3 uuid; s4 uuid; fb2 uuid; x public.practice_fee_bills; r jsonb;
  v_posted uuid := (pg_temp.fb(tests.id('sale'))).id;
begin
  v_day := private.local_day(o, now()) - 1;
  perform tests.as_user(tests.id('partner'));
  perform public.close_period(o, v_day);
  s2 := tests.remember('sale2', pg_temp.fee_invoice(f, tests.id('cu1'), 60000, v_day));
  s3 := tests.remember('sale3', pg_temp.fee_invoice(f, tests.id('cu1'), 70000, v_day));
  s4 := tests.remember('sale4', pg_temp.fee_invoice(f, tests.id('cu1'), 80000, v_day));
  perform tests.as_postgres();
  assert (select status from sales where id = s2) = 'open' and (select status from practice_fee_bills where sale_id = s2) = 'failed', 'fee_mirror_failure_never_blocks';
  x := pg_temp.fb(s2);
  fb2 := tests.remember('fb2', x.id);
  assert x.bill_id is null and x.attempts = 1 and x.error like 'The books are closed up to%', format('fee_mirror_failure_never_blocks: why, got %s', to_jsonb(x));
  assert not exists (select 1 from bills where org_id = o and vendor_ref = (select number from sales where id = s2)), 'fee_mirror_failure_never_blocks: no bill kept';
  -- Only a lead, only a failed record.
  perform tests.as_user(tests.id('staff'));
  perform tests.throws(format('select public.practice_fee_bill_retry(%L)', fb2), '42501: Only partners and managers%');
  perform tests.as_user(tests.id('kemi'));
  perform tests.throws(format('select public.practice_fee_bill_retry(%L)', fb2), '%not on this practice%');
  perform tests.as_user(tests.id('manager'));
  perform tests.throws(format('select public.practice_fee_bill_retry(%L)', v_posted), '%failed%');
  perform tests.throws(format('select public.practice_fee_bill_retry(%L)', gen_random_uuid()), '%not found%');
  -- Still closed: failed again.
  r := public.practice_fee_bill_retry(fb2);
  assert r->>'status' = 'failed' and (r->>'attempts')::int = 2, format('fee_mirror_failure_never_blocks: still closed, got %s', r);
  -- Reopened.
  perform tests.as_user(tests.id('partner'));
  perform public.reopen_period(o, 'Fee bills');
  perform tests.as_user(tests.id('manager'));
  r := public.practice_fee_bill_retry(fb2);
  perform tests.as_postgres();
  assert (select status from practice_fee_bills where id = fb2) = 'posted', 'fee_mirror_failure_never_blocks: retry';
  assert r->>'status' = 'posted' and (r->>'attempts')::int = 3 and r->>'error' is null and (r->>'bill_id')::uuid is not null, format('fee_mirror_failure_never_blocks: result, got %s', r);
  assert (select (b.status, b.total, b.bill_date) = ('approved', 64500.00, v_day) from bills b where b.id = (pg_temp.fb(s2)).bill_id), 'fee_mirror_failure_never_blocks: the bill';
  -- Tried again by Counta with another actor in place: the client's contact acts, then that actor is put back.
  perform private.set_actor(tests.id('manager'));
  x := private.fee_mirror(s3);
  assert x.status = 'posted' and current_setting('counta.actor', true) = tests.id('manager')::text, 'fee_mirror_failure_never_blocks: the actor put back';
  assert (select actor_user from activity_log where org_id = o and action = 'fee_bill_posted' and after->>'sale_id' = s3::text) = tests.id('partner'),
    'fee_mirror_failure_never_blocks: posted as the client''s contact';
  perform private.set_actor(null);
end $$;

-- test: fee_mirror_ended_client_skipped
-- Once the full mandate ends the client's books are read-only: a later fee invoice posts no bill (recorded as skipped, with
-- why, and not tried again), also when Counta issues it with nobody signed in (the read-only guard lets system writes
-- through, so the mirror itself must not write); voiding an earlier one leaves its bill there (the record says why); the
-- fee customer's details can still be changed; nothing is written in the client's books.
do $$
declare pr uuid := tests.id('pr'); f uuid := tests.id('f'); c3 uuid; o3 uuid; cu3 uuid; sa uuid; sb uuid; ba uuid; n_log bigint; n_bills bigint; x public.practice_fee_bills;
  v_sched uuid; sc uuid;
begin
  c3 := tests.full_client(pr, tests.id('partner'), 'Cedar Farms Ltd');
  o3 := (select org_id from practice_clients where id = c3);
  perform tests.as_user(tests.id('partner'));
  cu3 := (public.practice_fee_customer(c3, '{"email":"accounts@cedar.example.test"}')->>'customer_id')::uuid;
  sa := pg_temp.fee_invoice(f, cu3, 30000);
  perform public.practice_end_mandate(c3, '{"reason":"Engagement finished by agreement"}');
  perform tests.as_postgres();
  ba := (pg_temp.fb(sa)).bill_id;
  assert (select status from bills where id = ba) = 'approved', 'fee_mirror_ended_client_skipped: posted while running';
  n_log := (select count(*) from activity_log where org_id = o3);
  n_bills := (select count(*) from bills where org_id = o3);
  perform tests.as_user(tests.id('partner'));
  sb := pg_temp.fee_invoice(f, cu3, 30000);
  perform public.void_sale(sa, 'Billed twice');
  assert (public.practice_fee_customer(c3, '{"phone":"08035556666"}')->>'customer_id')::uuid = cu3, 'fee_mirror_ended_client_skipped: the fee customer';
  -- Counta issues a schedule's invoice with nobody signed in.
  v_sched := (public.recurring_save(f, jsonb_build_object('customer_id', cu3, 'frequency', 'monthly', 'day_of_month', 1,
    'start_date', private.local_day(f, now()), 'auto_send', false,
    'lines', '[{"description": "Closing fees", "qty": 1, "unit_price": 20000, "vat_treatment": "standard"}]'::jsonb))->>'id')::uuid;
  perform tests.as_postgres();
  sc := private.recurring_run(v_sched, private.local_day(f, now()));
  assert (select status from sales where id = sc) = 'open' and (pg_temp.fb(sc)).status = 'skipped', 'fee_mirror_ended_client_skipped: issued by Counta, skipped';
  perform private.set_actor(null);
  x := pg_temp.fb(sb);
  assert (select status from sales where id = sb) = 'open' and x.status = 'skipped' and x.bill_id is null and x.error like '%engagement has ended%',
    format('fee_mirror_ended_client_skipped: skipped, got %s', to_jsonb(x));
  assert (select status from sales where id = sa) = 'void' and (select status from bills where id = ba) = 'approved'
     and (pg_temp.fb(sa)).status = 'posted' and (pg_temp.fb(sa)).error like '%read-only%', 'fee_mirror_ended_client_skipped: the earlier bill left';
  assert (select count(*) from activity_log where org_id = o3) = n_log and (select count(*) from bills where org_id = o3) = n_bills,
    'fee_mirror_ended_client_skipped: nothing written in the client''s books';
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format('select public.practice_fee_bill_retry(%L)', x.id), '%failed%');
  perform tests.as_postgres();
end $$;

-- test: fee_void_voids_unpaid_bill
-- A voided fee invoice voids its bill in the client's books when nothing is paid on it, as the client's contact; a bill with
-- payments is left (the record says why); a failed record has no bill and is closed.
do $$
declare o uuid := tests.id('o1'); fee_bill uuid := (pg_temp.fb(tests.id('sale'))).bill_id; paid_bill uuid := (pg_temp.fb(tests.id('sale_p'))).bill_id; fb4 uuid;
begin
  perform tests.as_user(tests.id('partner'));
  perform public.void_sale(tests.id('sale'), 'Raised in error');
  perform tests.as_postgres();
  assert (select status from bills where id = fee_bill) = 'void', 'fee_void_voids_unpaid_bill';
  assert (pg_temp.fb(tests.id('sale'))).status = 'voided' and (select void_reason from bills where id = fee_bill) like '%voided: Raised in error'
     and (select voided_by from bills where id = fee_bill) = (private.org_contact(o)).id, 'fee_void_voids_unpaid_bill: the record and the reason';
  -- Paid in part in the client's books: left.
  update bills set amount_paid = 10000, status = 'partially_paid' where id = paid_bill;
  perform tests.as_user(tests.id('partner'));
  perform public.void_sale(tests.id('sale_p'), 'Raised in error');
  perform tests.as_postgres();
  assert (select status from bills where id = paid_bill) = 'partially_paid' and (pg_temp.fb(tests.id('sale_p'))).status = 'posted'
     and (pg_temp.fb(tests.id('sale_p'))).error like '%payments%', 'fee_void_voids_unpaid_bill: a paid bill left';
  -- A record that failed (while the books were closed, never tried again) is closed with its invoice.
  assert (pg_temp.fb(tests.id('sale4'))).status = 'failed', 'fee_void_voids_unpaid_bill: sale4 failed';
  perform tests.as_user(tests.id('partner'));
  perform public.void_sale(tests.id('sale4'), 'Raised in error');
  perform tests.as_postgres();
  assert (pg_temp.fb(tests.id('sale4'))).status = 'voided' and (pg_temp.fb(tests.id('sale4'))).bill_id is null, 'fee_void_voids_unpaid_bill: a failed record closed';
  assert not exists (select 1 from bills where org_id = o and vendor_ref = (select number from sales where id = tests.id('sale4'))), 'fee_void_voids_unpaid_bill: no bill';
  fb4 := (pg_temp.fb(tests.id('sale4'))).id;
  perform tests.as_user(tests.id('manager'));
  perform tests.throws(format('select public.practice_fee_bill_retry(%L)', fb4), '%failed%');
  perform tests.as_postgres();
end $$;

-- test: practice_fees_reads
-- The fees overview for leads: the firm business, each client with its fee customer, what it owes, its fee invoices,
-- recurring schedules and fee bills; the wallet balances to partners only. A schedule run for a fee customer is mirrored too.
do $$
declare pr uuid := tests.id('pr'); f uuid := tests.id('f'); r jsonb; cl jsonb; w uuid; v_sched uuid; pr3 uuid;
begin
  -- A monthly retainer for Adire Foods, run now: issued and mirrored.
  perform tests.as_user(tests.id('partner'));
  v_sched := (public.recurring_save(f, jsonb_build_object('customer_id', tests.id('cu1'), 'practice_client_id', tests.id('c1'), 'frequency', 'monthly',
    'day_of_month', 1, 'start_date', private.local_day(f, now()), 'auto_send', false,
    'lines', '[{"description": "Monthly retainer", "qty": 1, "unit_price": 100000, "vat_treatment": "standard"}]'::jsonb))->>'id')::uuid;
  r := public.recurring_run_now(v_sched);
  perform tests.as_postgres();
  assert (pg_temp.fb((r->>'sale_id')::uuid)).status = 'posted', 'practice_fees_reads: the schedule''s invoice is mirrored';
  -- Wallets of the firm business, the way the payments edge function opens them, with 5,000 in the wallet.
  insert into wallets (org_id, rail) values (f, 'flutterwave') returning id into w;
  perform public.svc_wallet_ready(w, '{"account_ref": "fee-wallet", "account_number": "0123456789", "bank_name": "Test Bank", "account_name": "Firm Books Ltd"}');
  insert into tax_wallets (org_id, rail) values (f, 'flutterwave') returning id into w;
  perform public.svc_tax_wallet_ready(w, '{"account_ref": "fee-tax-wallet", "account_number": "0123456780", "bank_name": "Test Bank", "account_name": "Firm Books Ltd Tax"}');
  perform private.post_entry(f, 'Test movement', 'manual', null, null, null, jsonb_build_array(
    jsonb_build_object('code', (select b.ledger_code from bank_accounts b join wallets x on x.bank_account_id = b.id where x.org_id = f), 'debit', 5000),
    jsonb_build_object('code', '3001', 'credit', 5000)));

  perform tests.as_user(tests.id('partner'));
  r := public.practice_fees(pr);
  assert r ? 'wallets', 'practice_fees_reads: wallets for partners';
  assert r->'firm_org' = jsonb_build_object('id', f, 'name', 'Firm Books Ltd', 'identity_status', 'verified'), format('practice_fees_reads: firm, got %s', r->'firm_org');
  assert r->'wallets' = '{"wallet": {"status": "active", "balance": 5000.00}, "tax_wallet": {"status": "active", "balance": 0}}'::jsonb,
    format('practice_fees_reads: wallets, got %s', r->'wallets');
  select x into cl from jsonb_array_elements(r->'clients') x where x->>'client_id' = tests.id('c1')::text;
  perform tests.as_postgres();
  assert cl->>'business_name' = 'Adire Foods Ltd' and cl->>'mode' = 'full' and (cl->>'fee_customer_id')::uuid = tests.id('cu1'),
    format('practice_fees_reads: the client, got %s', cl);
  assert (cl->>'outstanding')::numeric = (select sum(total - amount_paid - credited) from sales where customer_id = tests.id('cu1') and status in ('open', 'partially_paid'))
     and (cl->>'outstanding')::numeric > 0, format('practice_fees_reads: outstanding, got %s', cl->'outstanding');
  assert jsonb_array_length(cl->'invoices') = (select count(*) from sales where customer_id = tests.id('cu1') and doc_type = 'invoice')
     and exists (select 1 from jsonb_array_elements(cl->'invoices') i where i->>'id' = tests.id('sale')::text and i->>'status' = 'void' and (i->>'balance')::numeric = 0
                 and (i->>'total')::numeric = 107500 and i ? 'number' and i ? 'issue_date')
     and exists (select 1 from jsonb_array_elements(cl->'invoices') i where i->>'id' = tests.id('sale2')::text and (i->>'balance')::numeric = 64500),
    format('practice_fees_reads: invoices, got %s', cl->'invoices');
  assert cl->'schedules' = jsonb_build_array(jsonb_build_object('id', v_sched, 'frequency', 'monthly', 'day_of_month', 1,
      'next_run', (select next_run from recurring_invoices where id = v_sched), 'status', 'active', 'total', 107500.00)),
    format('practice_fees_reads: schedules, got %s', cl->'schedules');
  assert jsonb_array_length(cl->'fee_bills') = (select count(*) from practice_fee_bills where client_id = tests.id('c1'))
     and exists (select 1 from jsonb_array_elements(cl->'fee_bills') b where b->>'id' = tests.id('fb2')::text and b->>'status' = 'posted'
                 and b->>'sale_id' = tests.id('sale2')::text and b ? 'error' and (b->>'bill_id')::uuid is not null),
    format('practice_fees_reads: fee bills, got %s', cl->'fee_bills');
  assert exists (select 1 from jsonb_array_elements(r->'clients') x where x->>'client_id' = tests.id('ci')::text and x->>'mode' = 'involved'
                 and (x->>'fee_customer_id')::uuid = tests.id('cu_inv') and (x->>'outstanding')::numeric = 53750),
    'practice_fees_reads: the involved client';
  perform tests.as_user(tests.id('manager'));
  r := public.practice_fees(pr);
  assert not r ? 'wallets' and r->'firm_org'->>'id' = f::text and jsonb_array_length(r->'clients') >= 2, 'practice_fees_reads: wallets partners only';
  perform tests.as_user(tests.id('staff'));
  perform tests.throws(format('select public.practice_fees(%L)', pr), '42501: Only partners and managers%');
  perform tests.as_user(tests.id('kemi'));
  perform tests.throws(format('select public.practice_fees(%L)', pr), '%not on this practice%');
  -- A practice with no firm business yet.
  perform tests.as_postgres();
  pr3 := tests.practice(tests.id('someone'), 'Third Partners', true);
  perform tests.as_user(tests.id('someone'));
  r := public.practice_fees(pr3);
  assert r = '{"firm_org": null, "clients": [], "wallets": {"wallet": {"status": null, "balance": 0}, "tax_wallet": {"status": null, "balance": 0}}}'::jsonb,
    format('practice_fees_reads: no firm business, got %s', r);
  perform tests.as_postgres();
end $$;

-- test: fees_helpers_revoked
-- The helpers are not callable by the signed-in person; the RPCs by authenticated only; the table is closed; the triggers and
-- the bill source are in place.
do $$
declare v_fn text;
begin
  foreach v_fn in array array['private.fee_mirror(uuid)', 'private.fee_mirror_on_post()', 'private.fee_mirror_on_void()',
    'private.void_bill_as(uuid, text, public.members)'] loop
    assert not has_function_privilege('anon', v_fn, 'execute') and not has_function_privilege('authenticated', v_fn, 'execute'), 'fees_helpers_revoked: ' || v_fn;
  end loop;
  foreach v_fn in array array['public.practice_firm_business(uuid, jsonb)', 'public.practice_fee_customer(uuid, jsonb)',
    'public.practice_fee_bill_retry(uuid)', 'public.practice_fees(uuid)', 'public.void_bill(uuid, text)'] loop
    assert has_function_privilege('authenticated', v_fn, 'execute') and not has_function_privilege('anon', v_fn, 'execute'), 'fees_helpers_revoked: rpc ' || v_fn;
  end loop;
  assert (select relrowsecurity from pg_class where oid = 'public.practice_fee_bills'::regclass)
     and not has_table_privilege('authenticated', 'public.practice_fee_bills', 'select')
     and not has_table_privilege('anon', 'public.practice_fee_bills', 'select'), 'fees_helpers_revoked: table';
  assert (select count(*) from pg_trigger where tgrelid = 'public.sales'::regclass and tgname in ('sales_fee_mirror', 'sales_fee_mirror_void')) = 2,
    'fees_helpers_revoked: triggers';
  assert pg_get_constraintdef((select oid from pg_constraint where conname = 'bills_source_check')) like '%practice_fee%', 'fees_helpers_revoked: bill source';
end $$;

rollback;
