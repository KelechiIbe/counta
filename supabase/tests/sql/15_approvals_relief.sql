-- Release 2 of the identity work (20261126000100_approvals_and_relief.sql): sales exempt from VAT for a diplomatic mission,
-- a free trade zone entity or a humanitarian project (the customer's own, set by the owner or an admin, or marked on one
-- document); and approvals. What the firm that keeps a business's books does there (invoices, credit notes, refunds,
-- payments out of the wallet, recurring schedules) waits for the director who confirmed the wallets under full mandate, by
-- a link and a code, and for the owner or an admin when the client is involved. A credit note by anyone other than the
-- owner or an admin, an invoice whose discounts pass the business's limit and an invoice someone else marked exempt wait
-- for the owner or an admin. Only fake people (example.test addresses); the edge-function calls are only recorded in
-- net._requests.
begin;

-- Fixture: Ada owns Lagos Supplies Ltd (VAT registered) with Bimpe (admin), Kemi (staff, records sales) and Tunde (an
-- accountant on her staff, who raises credit notes); its customers Bola Stores and the Embassy of Testland. A verified
-- practice (partner Bisi) runs Managed Foods Ltd under full mandate, its wallet funded and its director Dayo reachable,
-- and keeps the books of Ife's Ife Crafts Ltd with Ife involved.
do $$
declare v_ada uuid; o uuid; mo uuid; io uuid; pr uuid; v_ife uuid;
begin
  perform tests.hooks_on();
  v_ada := tests.remember('ada', tests.user('ada.owner@lagos.example.test', 'Ada Owner'));
  perform tests.remember('bimpe', tests.user('bimpe.admin@lagos.example.test', 'Bimpe Admin'));
  perform tests.remember('kemi', tests.user('kemi.staff@lagos.example.test', 'Kemi Staff'));
  perform tests.remember('tunde', tests.user('tunde.books@lagos.example.test', 'Tunde Books'));
  o := tests.remember('o', tests.org(v_ada, 'Lagos Supplies Ltd'));
  update orgs set vat_registered = true where id = o;
  perform tests.remember('ada_seat', (select id from members where org_id = o and user_id = v_ada));
  perform tests.remember('bimpe_seat', tests.member(o, tests.id('bimpe'), 'admin'));
  perform tests.remember('kemi_seat', tests.member(o, tests.id('kemi'), 'staff'));
  perform tests.remember('tunde_seat', tests.member(o, tests.id('tunde'), 'accountant'));
  perform tests.as_user(v_ada);
  perform tests.remember('bola', public.save_customer(o, '{"name": "Bola Stores", "email": "bola@example.test"}'));
  perform tests.remember('embassy', public.save_customer(o, '{"name": "Embassy of Testland", "email": "embassy@example.test"}'));
  perform tests.as_postgres();

  perform tests.remember('bisi', tests.user('bisi.partner@fifteen.example.test', 'Bisi Partner'));
  pr := tests.remember('pr', tests.practice(tests.id('bisi'), 'Fifteen Partners', true));
  update practices set email = 'office@fifteen.example.test' where id = pr;
  mo := tests.remember('mo', tests.managed_org(pr, 'Managed Foods Ltd'));
  update orgs set identity_status = 'verified', vat_registered = true where id = mo;
  perform tests.remember('bisi_seat', (select id from members where org_id = mo and user_id = tests.id('bisi')));
  perform tests.remember('mo_client', (select id from practice_clients where org_id = mo and mode = 'full'));
  perform tests.as_user(tests.id('bisi'));
  perform tests.remember('mo_cu', public.save_customer(mo, '{"name": "Chika Foods", "email": "chika@example.test"}'));
  perform tests.as_postgres();

  v_ife := tests.remember('ife', tests.user('ife.owner@ife.example.test', 'Ife Owner'));
  io := tests.remember('io', tests.org(v_ife, 'Ife Crafts Ltd'));
  update orgs set vat_registered = true where id = io;
  perform tests.remember('io_client', tests.involved_client(pr, io));
  perform tests.remember('bisi_io_seat', (select id from members where org_id = io and user_id = tests.id('bisi')));
  perform tests.as_user(v_ife);
  perform tests.remember('io_cu', public.save_customer(io, '{"name": "Dele Crafts", "email": "dele@example.test"}'));
  perform tests.as_postgres();
end $$;

-- An invoice as save_sale_doc takes it: one 100,000 service line with VAT (less p_discount), issued unless p_draft.
create function pg_temp.invoice(p_org uuid, p_customer uuid, p_discount numeric default 0, p_draft boolean default false, p_extra jsonb default '{}')
returns jsonb language sql as $f$
  select public.save_sale_doc(p_org, jsonb_build_object('customer_id', p_customer, 'status', case when p_draft then 'draft' else 'issue' end,
    'lines', jsonb_build_array(jsonb_build_object('description', 'Supplies', 'qty', 1, 'unit_price', 100000, 'vat_treatment', 'standard',
      'discount', p_discount))) || p_extra)
$f$;

-- test: relief_customer_default
-- The owner or an admin marks a customer exempt, with its reference; nobody else can, and a customer abroad buys as an
-- export. Every line of an invoice to that customer is exempt and carries the NRS VAT return's description, delivery
-- included; a credit note on it is exempt the same way.
do $$
declare o uuid := tests.id('o'); v jsonb; s uuid; cn jsonb; v_label text;
begin
  v_label := 'Goods or services supplied to a diplomatic mission, diplomat or person recognised under the Diplomatic Immunities and Privileges Act whose activity is in public interest, and not for profit';
  perform tests.as_user(tests.id('kemi'));
  perform tests.throws(format('select public.save_customer(%L, %L)', o, jsonb_build_object('id', tests.id('embassy'), 'name', 'Embassy of Testland',
    'vat_relief', 'diplomatic', 'vat_relief_ref', 'MFA/ACC/2026/114')), '%Only the owner or an admin%');
  perform tests.as_user(tests.id('ada'));
  perform tests.throws(format('select public.save_customer(%L, %L)', o, jsonb_build_object('id', tests.id('embassy'), 'name', 'Embassy of Testland',
    'vat_relief', 'diplomatic')), '%Add the reference%');
  perform tests.throws(format('select public.save_customer(%L, %L)', o, jsonb_build_object('id', tests.id('embassy'), 'name', 'Embassy of Testland',
    'vat_relief', 'tax_free', 'vat_relief_ref', 'X1')), '%Choose who the customer is%');
  perform tests.throws(format('select public.save_customer(%L, %L)', o, jsonb_build_object('name', 'Ghana Mission', 'country', 'GH',
    'vat_relief', 'diplomatic', 'vat_relief_ref', 'GH-1')), '%export%');
  perform public.save_customer(o, jsonb_build_object('id', tests.id('embassy'), 'name', 'Embassy of Testland',
    'vat_relief', 'diplomatic', 'vat_relief_ref', 'MFA/ACC/2026/114'));
  perform tests.as_user(tests.id('bimpe'));
  perform public.save_customer(o, jsonb_build_object('id', tests.id('embassy'), 'name', 'Embassy of Testland',
    'vat_relief', 'diplomatic', 'vat_relief_ref', 'MFA/ACC/2026/114'));
  perform tests.as_postgres();
  assert (select vat_relief = 'diplomatic' and vat_relief_ref = 'MFA/ACC/2026/114' from customers where id = tests.id('embassy')),
    'relief_customer_default: saved';

  -- Kemi invoices the embassy (the customer's own exemption needs nobody's approval), with delivery.
  perform tests.as_user(tests.id('kemi'));
  v := pg_temp.invoice(o, tests.id('embassy'), 0, false, '{"delivery_fee": 5000}');
  perform tests.as_postgres();
  s := tests.remember('embassy_invoice', (v->>'id')::uuid);
  assert v->>'status' = 'open' and v->>'vat_relief' = 'diplomatic' and v->>'vat_relief_ref' = 'MFA/ACC/2026/114' and v->>'vat_relief_by' is null
     and (v->>'vat_total')::numeric = 0 and (v->>'total')::numeric = 105000 and v->>'relief_words' = 'a diplomatic mission or diplomat',
    format('relief_customer_default: issued, exempt, got %s', v - 'lines' - 'org');
  assert (select bool_and(vat_treatment = 'exempt' and nrs_vat_label = v_label and vat = 0) and count(*) = 2 from sale_lines where sale_id = s),
    'relief_customer_default: the line and the delivery are exempt, with the NRS description';
  assert (select item_vat_treatment from sale_lines where sale_id = s and kind <> 'delivery') = 'standard', 'relief_customer_default: the line keeps its own treatment';
  assert not exists (select 1 from approvals where sale_id = s), 'relief_customer_default: nobody approves the customer''s own exemption';

  -- Ada credits part of it: the credit note is exempt too.
  perform tests.as_user(tests.id('ada'));
  cn := public.credit_sale(s, '{"reason": "Short delivery", "amount": 10000}');
  perform tests.as_postgres();
  assert cn->'credit_note'->>'vat_relief' = 'diplomatic' and (cn->'credit_note'->>'vat_total')::numeric = 0,
    format('relief_customer_default: the credit note is exempt, got %s', cn->'credit_note' - 'lines' - 'org');

  -- The public document says so, and carries nothing of the approvals.
  update sales set public_token = 'fifteen-relief-token-00000001' where id = s;
  perform tests.as_anon();
  v := public.public_document('fifteen-relief-token-00000001');
  perform tests.as_postgres();
  assert v->>'vat_relief' = 'diplomatic' and v->>'relief_words' is not null and not (v ? 'approvals') and not (v ? 'vat_relief_by'),
    'relief_customer_default: the public document';
end $$;

-- test: relief_marked_on_a_document
-- Kemi marks one invoice to Bola Stores as a supply to a free trade zone entity: its lines are exempt with the zone's
-- description, and issuing it waits for the owner or an admin. Taking the mark off restores each line's own treatment; an
-- export cannot also be exempt. Ada's own mark needs nobody. A quote's mark goes on the invoice made from it.
do $$
declare o uuid := tests.id('o'); v jsonb; s uuid; q uuid; a public.approvals;
begin
  perform tests.as_user(tests.id('kemi'));
  v := pg_temp.invoice(o, tests.id('bola'), 0, true);
  s := (v->>'id')::uuid;
  perform tests.throws(format('select public.set_sale_vat_relief(%L, %L, %L)', s, 'free_zone', ''), '%Add the reference%');
  v := public.set_sale_vat_relief(s, 'free_zone', 'OGFZA/LIC/0042');
  assert v->>'vat_relief' = 'free_zone' and (v->>'vat_relief_by')::uuid = tests.id('kemi_seat') and (v->>'vat_total')::numeric = 0
     and v->>'relief_by_name' = 'Kemi Staff', format('relief_marked_on_a_document: marked, got %s', v - 'lines' - 'org');
  perform tests.as_postgres();
  assert (select bool_and(vat_treatment = 'exempt' and nrs_vat_label = 'Supplies consumed by an approved entity in the export processing or free trade zones')
          from sale_lines where sale_id = s), 'relief_marked_on_a_document: the zone''s description';
  perform tests.as_user(tests.id('kemi'));
  v := public.set_sale_vat_relief(s, null, null);
  -- (The business's prices include VAT.)
  assert v->>'vat_relief' is null and (v->>'vat_total')::numeric = 6976.74
     and (select bool_and(x->>'vat_treatment' = 'standard' and x->>'nrs_vat_label' is null) from jsonb_array_elements(v->'lines') x),
    format('relief_marked_on_a_document: taken off, got %s', v->>'vat_total');
  perform public.set_sale_vat_relief(s, 'free_zone', 'OGFZA/LIC/0042');
  -- Issuing it waits for Ada or Bimpe.
  v := public.issue_invoice(s);
  perform tests.as_postgres();
  assert v->>'status' = 'draft', 'relief_marked_on_a_document: not issued yet';
  select * into a from approvals where sale_id = s and status = 'pending';
  assert a.kind = 'invoice' and a.approver = 'owner' and a.reasons = array['vat_relief'] and a.requested_by = tests.id('kemi_seat')
     and a.summary->>'relief' = 'free_zone' and a.summary->>'title' like 'Invoice % to Bola Stores',
    format('relief_marked_on_a_document: the approval, got %s', to_jsonb(a) - 'summary');
  assert exists (select 1 from notifications where user_id = tests.id('ada') and kind = 'approval' and url = '/approvals')
     and exists (select 1 from notifications where user_id = tests.id('bimpe') and kind = 'approval')
     and not exists (select 1 from notifications where user_id = tests.id('kemi') and kind = 'approval'),
    'relief_marked_on_a_document: the owner and the admin are told';
  perform tests.as_user(tests.id('bimpe'));
  v := public.approval_decide(a.id, true);
  perform tests.as_postgres();
  assert v->>'status' = 'approved' and (select status = 'open' and journal_id is not null and vat_relief = 'free_zone' from sales where id = s),
    format('relief_marked_on_a_document: approved and issued, got %s', v - 'summary');
  assert (select created_by from sales where id = s) = tests.id('kemi_seat'), 'relief_marked_on_a_document: issued as Kemi';
  assert exists (select 1 from notifications where user_id = tests.id('kemi') and kind = 'approval' and title like 'Approved:%'),
    'relief_marked_on_a_document: Kemi is told';

  -- An export cannot also be exempt; making it one takes the exemption off.
  perform tests.as_user(tests.id('ada'));
  v := pg_temp.invoice(o, tests.id('bola'), 0, true);
  s := (v->>'id')::uuid;
  perform public.set_sale_vat_relief(s, 'humanitarian', 'UNDP/NG/2026/7');
  v := public.set_sale_export(s, true, 'Shipped to Ghana');
  assert v->>'vat_relief' is null and (v->>'export')::boolean, 'relief_marked_on_a_document: the export takes its place';
  perform tests.throws(format('select public.set_sale_vat_relief(%L, %L, %L)', s, 'humanitarian', 'UNDP/NG/2026/7'), '%zero-rated already%');
  perform public.set_sale_export(s, false, 'Not shipped after all');
  -- Ada's own mark: issued at once.
  perform public.set_sale_vat_relief(s, 'humanitarian', 'UNDP/NG/2026/7');
  v := public.issue_invoice(s);
  assert v->>'status' = 'open' and (v->>'vat_total')::numeric = 0, 'relief_marked_on_a_document: the owner''s own mark';
  -- A quote marked exempt becomes an exempt invoice.
  v := public.save_sale_doc(o, jsonb_build_object('doc_type', 'quote', 'customer_id', tests.id('bola'),
    'vat_relief', 'diplomatic', 'vat_relief_ref', 'MFA/ACC/2026/200',
    'lines', '[{"description": "Supplies", "qty": 2, "unit_price": 1000, "vat_treatment": "standard"}]'::jsonb));
  q := (v->>'id')::uuid;
  assert v->>'vat_relief' = 'diplomatic' and (v->>'vat_total')::numeric = 0, 'relief_marked_on_a_document: the quote';
  perform tests.as_postgres();
  update sales set status = 'open' where id = q;
  perform tests.as_user(tests.id('ada'));
  v := public.convert_quote(q);
  assert v->>'vat_relief' = 'diplomatic' and v->>'vat_relief_ref' = 'MFA/ACC/2026/200' and (v->>'vat_total')::numeric = 0,
    format('relief_marked_on_a_document: the invoice from the quote, got %s', v - 'lines' - 'org');
  perform tests.as_postgres();
end $$;

-- test: discount_limit
-- Kemi's invoice with more than the business's limit (10% unless Ada changes it) off waits for the owner or an admin; at the
-- limit it is issued at once, and so is the owner's own. Only the owner sets the limit, from 0 to 100. At the till the
-- cashier allowance still refuses.
do $$
declare o uuid := tests.id('o'); v jsonb; a public.approvals;
begin
  assert (select discount_approval_pct from orgs where id = o) = 10, 'discount_limit: 10% by default';
  perform tests.as_user(tests.id('kemi'));
  v := pg_temp.invoice(o, tests.id('bola'), 10000);
  assert v->>'status' = 'open', 'discount_limit: at the limit, issued';
  v := pg_temp.invoice(o, tests.id('bola'), 15000);
  assert v->>'status' = 'draft', 'discount_limit: over it, waits';
  perform tests.as_postgres();
  select * into a from approvals where sale_id = (v->>'id')::uuid;
  assert a.reasons = array['discount'] and a.approver = 'owner' and (a.summary->>'discount_pct')::numeric = 15
     and (a.summary->>'discount')::numeric = 15000, format('discount_limit: the approval says why, got %s', a.summary);
  -- Kemi cannot approve her own; Ada rejects it with a reason.
  perform tests.as_user(tests.id('kemi'));
  perform tests.throws(format('select public.approval_decide(%L, true)', a.id), '%Only the owner or an admin%');
  perform tests.as_user(tests.id('ada'));
  perform tests.throws(format('select public.approval_decide(%L, false)', a.id), '%Say why%');
  v := public.approval_decide(a.id, false, 'Ten percent is the most for Bola');
  assert v->>'status' = 'rejected' and v->>'note' = 'Ten percent is the most for Bola', 'discount_limit: rejected';
  perform tests.throws(format('select public.approval_decide(%L, true)', a.id), '%rejected already%');
  perform tests.as_postgres();
  assert (select status from sales where id = a.sale_id) = 'draft', 'discount_limit: still a draft';
  assert exists (select 1 from notifications where user_id = tests.id('kemi') and title like 'Not approved:%' and body like '%Ten percent%'),
    'discount_limit: Kemi is told why';

  -- The owner's own discount; the limit changed.
  perform tests.as_user(tests.id('ada'));
  v := pg_temp.invoice(o, tests.id('bola'), 50000);
  assert v->>'status' = 'open', 'discount_limit: the owner''s own';
  perform tests.throws(format('select public.update_sales_settings(%L, %L)', o, '{"discount_approval_pct": 120}'), '%0 to 100%');
  v := public.update_sales_settings(o, '{"discount_approval_pct": 20}');
  assert (v->>'discount_approval_pct')::numeric = 20, 'discount_limit: changed';
  perform tests.as_user(tests.id('kemi'));
  perform tests.throws(format('select public.update_sales_settings(%L, %L)', o, '{"discount_approval_pct": 50}'), '%Only the owner%');
  v := pg_temp.invoice(o, tests.id('bola'), 15000);
  assert v->>'status' = 'open', 'discount_limit: under the new limit';
  -- The till keeps its cashier allowance (a sale's lines as the till writes them).
  perform tests.as_postgres();
  update orgs set max_cashier_discount_pct = 5 where id = o;
  insert into items (org_id, name, price) values (o, 'Till Item', 100);
  perform tests.throws(format($q$select private.write_lines(jsonb_populate_record((select s from sales s where id = %L), '{"doc_type": "receipt"}'),
      jsonb_build_array(jsonb_build_object('item_id', %L, 'qty', 1, 'discount', 50)), null, (select m from members m where id = %L))$q$,
    (v->>'id'), (select id from items where org_id = o and name = 'Till Item'), tests.id('kemi_seat')), '%need a manager or the owner%');
  update orgs set discount_approval_pct = 10 where id = o;
end $$;

-- test: credit_note_approval
-- A credit note by Tunde (an accountant, not the owner or an admin) waits for Ada or Bimpe: tried first, so one that could
-- not go through is refused at once and nothing waits; approved, it is raised as Tunde. A return waits the same way. One
-- the books overtook is kept as approved but failed, with why.
do $$
declare o uuid := tests.id('o'); s uuid; v jsonb; a public.approvals; v_n bigint; v_ar numeric;
begin
  perform tests.as_user(tests.id('ada'));
  s := (pg_temp.invoice(o, tests.id('bola'))->>'id')::uuid;
  perform tests.as_user(tests.id('tunde'));
  perform tests.throws(format('select public.credit_sale(%L, %L)', s, '{"reason": "Too much", "amount": 500000}'), '%At most%');
  perform tests.as_postgres();
  assert not exists (select 1 from approvals where sale_id = s), 'credit_note_approval: refused at once, nothing waits';
  v_n := (select count(*) from sales where org_id = o and doc_type = 'credit_note');
  perform tests.as_user(tests.id('tunde'));
  v := public.credit_sale(s, '{"reason": "Damaged goods", "amount": 21500}');
  perform tests.as_postgres();
  assert (v->>'pending_approval')::boolean and v->'approval'->>'kind' = 'credit_note' and v->'approval'->>'status' = 'pending'
     and (select count(*) from sales where org_id = o and doc_type = 'credit_note') = v_n, 'credit_note_approval: waits, no credit note yet';
  select * into a from approvals where id = (v->'approval'->>'id')::uuid;
  assert a.reasons = array['credit_note'] and (a.summary->>'total')::numeric = 21500 and (a.summary->>'vat')::numeric = 1500
     and a.summary->>'reason' = 'Damaged goods', format('credit_note_approval: the approver sees the figures, got %s', a.summary);
  -- Bimpe approves.
  perform tests.as_user(tests.id('bimpe'));
  v := public.approval_decide(a.id, true);
  perform tests.as_postgres();
  assert v->>'status' = 'approved' and (select count(*) from sales where org_id = o and doc_type = 'credit_note') = v_n + 1,
    'credit_note_approval: raised';
  assert (select created_by from sales where org_id = o and doc_type = 'credit_note' and original_sale_id = s) = tests.id('tunde_seat')
     and (select decided_by from approvals where id = a.id) = tests.id('bimpe_seat'), 'credit_note_approval: as Tunde, approved by Bimpe';
  assert coalesce(current_setting('counta.approval_replay', true), '') = '', 'credit_note_approval: the replay flag is cleared';

  -- Overtaken: Tunde asks to credit the rest, Ada credits it herself first, then Bimpe approves.
  perform tests.as_user(tests.id('tunde'));
  v := public.credit_sale(s, '{"reason": "The rest", "amount": 78500}');
  perform tests.as_user(tests.id('ada'));
  perform public.credit_sale(s, '{"reason": "Settled", "amount": 78500}');
  perform tests.as_user(tests.id('bimpe'));
  v := public.approval_decide((v->'approval'->>'id')::uuid, true);
  perform tests.as_postgres();
  assert v->>'status' = 'failed' and v->>'error' like '%can still be credited%', format('credit_note_approval: failed, got %s', v - 'summary');
  assert exists (select 1 from notifications where user_id = tests.id('tunde') and title like 'Approved, but it did not go through:%'),
    'credit_note_approval: Tunde is told';

  -- A return waits too.
  perform tests.as_user(tests.id('ada'));
  s := (pg_temp.invoice(o, tests.id('bola'))->>'id')::uuid;
  perform tests.as_user(tests.id('tunde'));
  v := public.return_sale(s, jsonb_build_array(jsonb_build_object('sale_line_id', (select id from sale_lines where sale_id = s limit 1), 'qty', 0.5)),
    null, 'Returned unused', false);
  perform tests.as_postgres();
  assert (v->>'pending_approval')::boolean and not exists (select 1 from sales where original_sale_id = s), 'credit_note_approval: the return waits';
  perform tests.as_user(tests.id('ada'));
  v := public.approval_decide((v->'approval'->>'id')::uuid, true);
  perform tests.as_postgres();
  assert v->>'status' = 'approved' and exists (select 1 from sales where original_sale_id = s and doc_type = 'credit_note'), 'credit_note_approval: returned';
  -- The owner's own credit note is raised at once.
  perform tests.as_user(tests.id('ada'));
  v := public.credit_sale(s, '{"reason": "Goodwill", "amount": 100}');
  assert v ? 'credit_note' and not (v ? 'pending_approval'), 'credit_note_approval: the owner''s own';
  perform tests.as_postgres();
end $$;

-- test: changed_after_asking
-- An invoice changed after it was sent for approval is withdrawn from the approver; one changed some other way is not
-- issued when approved. A draft cancelled while it waits is withdrawn.
do $$
declare o uuid := tests.id('o'); v jsonb; s uuid; a uuid;
begin
  perform tests.as_user(tests.id('kemi'));
  v := pg_temp.invoice(o, tests.id('bola'), 20000);
  s := (v->>'id')::uuid;
  perform tests.as_postgres();
  a := (select id from approvals where sale_id = s and status = 'pending');
  perform tests.as_user(tests.id('kemi'));
  v := public.save_sale_doc(o, jsonb_build_object('id', s, 'notes', 'Delivered Tuesday'));
  perform tests.as_postgres();
  assert (select status = 'cancelled' and note like 'The invoice was changed%' from approvals where id = a), 'changed_after_asking: withdrawn';
  perform tests.as_user(tests.id('kemi'));
  v := public.issue_invoice(s);
  perform tests.as_postgres();
  a := (select id from approvals where sale_id = s and status = 'pending');
  assert a is not null, 'changed_after_asking: asked again';
  -- Changed behind the approval's back.
  update sale_lines set unit_price = 90000, net = 90000 where sale_id = s;
  perform tests.as_user(tests.id('ada'));
  v := public.approval_decide(a, true);
  perform tests.as_postgres();
  assert v->>'status' = 'failed' and v->>'error' like '%changed after it was sent%' and (select status from sales where id = s) = 'draft',
    'changed_after_asking: not issued';
  -- The owner issues one herself: what waited is withdrawn.
  perform tests.as_user(tests.id('kemi'));
  s := (pg_temp.invoice(o, tests.id('bola'), 20000)->>'id')::uuid;
  perform tests.as_user(tests.id('ada'));
  v := public.issue_invoice(s);
  perform tests.as_postgres();
  assert v->>'status' = 'open' and (select status from approvals where sale_id = s order by created_at desc limit 1) = 'cancelled',
    'changed_after_asking: issued by the owner, withdrawn';
  -- A draft cancelled.
  perform tests.as_user(tests.id('kemi'));
  s := (pg_temp.invoice(o, tests.id('bola'), 20000)->>'id')::uuid;
  perform tests.as_postgres();
  update sales set status = 'cancelled' where id = s;
  assert (select status from approvals where sale_id = s) = 'cancelled', 'changed_after_asking: a cancelled draft';
end $$;

-- test: approvals_list_and_attention
-- The owner and admins see everything; others see what they asked for. The attention counts what this person may decide
-- and what they asked for that waits.
do $$
declare o uuid := tests.id('o'); v jsonb; s uuid; v_n bigint;
begin
  perform tests.as_user(tests.id('kemi'));
  s := tests.remember('kemi_waiting', (pg_temp.invoice(o, tests.id('bola'), 30000)->>'id')::uuid);
  v := public.approvals_list(o);
  assert not (v->>'owner_or_admin')::boolean and (v->>'limit_pct')::numeric = 10
     and (select bool_and((x->>'requested_by')::uuid = tests.id('kemi_seat')) from jsonb_array_elements(v->'items') x)
     and (select bool_and(not (x->>'can_decide')::boolean) from jsonb_array_elements(v->'items') x), 'approvals_list_and_attention: Kemi sees her own';
  v := public.get_attention(o);
  assert (v->>'approvals')::int = 0 and (v->>'approvals_mine')::int >= 1, format('approvals_list_and_attention: Kemi''s counts, got %s', v);
  perform tests.as_postgres();
  v_n := (select count(*) from approvals where org_id = o and status = 'pending');
  perform tests.as_user(tests.id('ada'));
  v := public.approvals_list(o);
  assert (v->>'owner_or_admin')::boolean and exists (select 1 from jsonb_array_elements(v->'items') x where (x->>'sale_id')::uuid = s
     and (x->>'can_decide')::boolean and x->>'requested_by_name' = 'Kemi Staff') and exists (select 1 from jsonb_array_elements(v->'items') x
     where (x->>'requested_by')::uuid = tests.id('tunde_seat')), 'approvals_list_and_attention: Ada sees all and decides';
  v := public.get_attention(o);
  assert (v->>'approvals')::int = v_n, format('approvals_list_and_attention: Ada''s count, got %s of %s', v->>'approvals', v_n);
  v := public.get_sale(s);
  assert jsonb_array_length(v->'approvals') = 1 and v->'approvals'->0->>'status' = 'pending', 'approvals_list_and_attention: on the invoice';
  perform tests.as_user(tests.id('bisi'));
  perform tests.throws(format('select public.approvals_list(%L)', o), '%not a member%');
  perform tests.as_postgres();
end $$;

-- test: involved_firm_asks_the_owner
-- In a business whose owner is involved, a credit note by the firm's accountant waits for the owner (never the firm), and
-- a firm person cannot decide it.
do $$
declare io uuid := tests.id('io'); s uuid; v jsonb; a public.approvals;
begin
  perform tests.as_user(tests.id('ife'));
  s := (pg_temp.invoice(io, tests.id('io_cu'))->>'id')::uuid;
  perform tests.as_user(tests.id('bisi'));
  v := public.credit_sale(s, '{"reason": "Wrong price", "amount": 1075}');
  perform tests.as_postgres();
  select * into a from approvals where id = (v->'approval'->>'id')::uuid;
  assert a.approver = 'owner' and a.reasons = array['firm', 'credit_note'] and a.practice_id = tests.id('pr'),
    format('involved_firm_asks_the_owner: the owner approves, got %s', to_jsonb(a) - 'summary');
  assert exists (select 1 from notifications where user_id = tests.id('ife') and kind = 'approval'), 'involved_firm_asks_the_owner: Ife is told';
  perform tests.as_user(tests.id('bisi'));
  perform tests.throws(format('select public.approval_decide(%L, true)', a.id), '%Only the owner or an admin%');
  perform tests.as_user(tests.id('ife'));
  v := public.approval_decide(a.id, true);
  perform tests.as_postgres();
  assert v->>'status' = 'approved' and (select created_by from sales where original_sale_id = s) = tests.id('bisi_io_seat'),
    'involved_firm_asks_the_owner: approved, raised as the firm''s accountant';
  -- A refund the firm asks for is tried first: with no credit to refund, it is refused at once.
  perform tests.as_user(tests.id('bisi'));
  perform tests.throws(format('select public.refund_customer(%L, %L, 500, %L, null, %L)', io, tests.id('io_cu'), 'cash', 'Overpaid'),
    '%of credit to refund%');
  perform tests.as_postgres();
  assert not exists (select 1 from approvals where org_id = io and kind = 'refund'), 'involved_firm_asks_the_owner: nothing waits';
end $$;

-- test: full_mandate_needs_a_director
-- Under full mandate nothing the firm asks for can wait while Counta cannot reach a director: the request is refused with
-- what to do. The code that reached a director when they confirmed the wallets is kept for approvals.
do $$
declare mo uuid := tests.id('mo'); c uuid := tests.id('mo_client'); d uuid; k uuid;
begin
  perform tests.as_user(tests.id('bisi'));
  perform tests.throws(format('select pg_temp.invoice(%L, %L)', mo, tests.id('mo_cu')), '%cannot reach them yet%');
  perform tests.as_postgres();
  -- Confirmed with nothing to reach the director by (TaxStreem accepted a NIN slip): the firm may ask a director again (the
  -- request then stops only at the missing CAC record).
  update orgs set director_confirmed_at = now() where id = mo;
  perform tests.as_user(tests.id('bisi'));
  assert (public.practice_director_state(c)->>'approver_missing')::boolean, 'full_mandate_needs_a_director: nobody to reach';
  perform tests.throws(format('select public.practice_director_request(%L, %L)', c, '{"name": "Dayo Director"}'), '%CAC record first%');
  perform tests.as_postgres();
  update orgs set director_confirmed_at = null where id = mo;
  -- Dayo confirms the wallets by code: the check's addresses are kept on his confirmation when the code is right.
  insert into practice_director_confirmations (practice_id, client_id, name, email, status)
  values (tests.id('pr'), c, 'Dayo Director', 'dayo@director.example.test', 'pending') returning id into d;
  insert into identity_checks (purpose, ref_id, org_id, matched_name, route, sms_to, email_to, status)
  values ('director_confirm', d, mo, 'DAYO DIRECTOR', 'code', '2348031110000', 'dayo@director.example.test', 'open') returning id into k;
  update identity_checks set status = 'verified', sms_to = null, email_to = null, wiped_at = now() where id = k;
  assert (select approver_email = 'dayo@director.example.test' and approver_phone = '2348031110000' from practice_director_confirmations where id = d),
    'full_mandate_needs_a_director: kept for approvals';
  update practice_director_confirmations set status = 'confirmed', confirmed_at = now(), matched_name = 'DAYO DIRECTOR' where id = d;
  update orgs set director_confirmed_at = now() where id = mo;
  perform tests.remember('dayo_conf', d);
  assert (select d2.id from private.org_approver(mo) d2) = d, 'full_mandate_needs_a_director: Dayo approves';
  perform tests.as_user(tests.id('bisi'));
  assert (public.practice_director_state(c)->'approver'->>'email') like 'd%@d%', 'full_mandate_needs_a_director: the firm sees where it goes, masked';
  perform tests.throws(format('select public.practice_director_request(%L, %L)', c, '{"name": "Dayo Director"}'), '%confirmed already%');
  perform tests.as_postgres();
end $$;

-- test: director_approves_by_link_and_code
-- The firm's invoice waits for Dayo, who gets a link (minted as the email goes) and, on the page, a code to his phone and
-- email. A right code lets him approve or reject for 15 minutes; rejecting takes a reason. Nobody approves it in the app.
do $$
declare mo uuid := tests.id('mo'); v jsonb; s uuid; l public.approval_links; m jsonb; v_token text; v_code text; v_old bigint; a uuid; s2 uuid;
begin
  v_old := (select coalesce(max(id), 0) from net._requests);
  perform tests.as_user(tests.id('bisi'));
  v := pg_temp.invoice(mo, tests.id('mo_cu'));
  s := (v->>'id')::uuid;
  assert v->>'status' = 'draft', 'director_approves_by_link_and_code: waits';
  a := (v->'approvals'->0->>'id')::uuid;
  perform tests.throws(format('select public.approval_decide(%L, true)', a), '%director who confirmed the wallets%');
  v := public.approvals_list(mo);
  assert (v->>'firm')::boolean and v->'director'->>'name' = 'DAYO DIRECTOR' and v->'director'->>'email' not like 'dayo@%',
    format('approvals_list for the firm, got %s', v->'director');
  perform tests.as_postgres();
  select * into l from approval_links where org_id = mo order by created_at desc limit 1;
  assert l.id is not null and l.confirmation_id = tests.id('dayo_conf') and l.token_hash is null, 'director_approves_by_link_and_code: a link to send';
  assert exists (select 1 from net._requests where id > v_old and body->>'action' = 'identity_mail' and body->>'kind' = 'approval_link'
    and body->>'id' = l.id::text), 'director_approves_by_link_and_code: the messaging function asked';
  -- A second request inside ten minutes rides on the same email; the cron tick sends later ones.
  perform tests.as_user(tests.id('bisi'));
  s2 := (pg_temp.invoice(mo, tests.id('mo_cu'))->>'id')::uuid;
  perform tests.throws(format('select public.approvals_remind(%L)', mo), '%less than ten minutes%');
  perform tests.as_postgres();
  assert (select count(*) from approval_links where org_id = mo) = 1, 'director_approves_by_link_and_code: one email for both';
  assert private.approval_tick() = 0, 'director_approves_by_link_and_code: the tick waits ten minutes';
  update approval_links set created_at = created_at - interval '11 minutes' where id = l.id;
  assert private.approval_tick() = 1, 'director_approves_by_link_and_code: the tick sends';
  assert (select count(*) from approval_links where org_id = mo) = 2
     and not exists (select 1 from approvals where org_id = mo and status = 'pending' and notified_at is null),
    'director_approves_by_link_and_code: then sends what came in';

  -- The email: Dayo's address, the firm's name, the link.
  m := public.svc_identity_mail('approval_link', l.id);
  assert m->>'to' = 'dayo@director.example.test' and m->>'from_name' = 'Fifteen Partners' and (m->>'white_label')::boolean
     and m->>'subject' like 'Fifteen Partners asks you to approve 2 items for Managed Foods Ltd' and m->'sms'->>'to' = '2348031110000'
     and m->'sms'->>'text' not like '%/approve/%', format('director_approves_by_link_and_code: the email, got %s', m);
  v_token := substring(m->>'link' from '/approve/(ap_[0-9a-f]{48})$');
  assert v_token is not null and public.svc_identity_mail('approval_link', l.id) is null, 'director_approves_by_link_and_code: minted once';

  perform tests.as_service();
  v := public.svc_approval_open(v_token, '10.0.0.1', 'test');
  assert (v->>'ok')::boolean and v->>'business' = 'Managed Foods Ltd' and v->>'firm' = 'Fifteen Partners' and not (v->>'verified')::boolean
     and jsonb_array_length(v->'items') = 2 and not (v->'items'->0 ? 'requested_by'), format('director_approves_by_link_and_code: open, got %s', v);
  assert (public.svc_approval_open('ap_' || repeat('0', 48), null, null))->>'reason' = 'invalid', 'director_approves_by_link_and_code: a wrong link';
  v := public.svc_approval_decide(v_token, array[a], true, null, null, null);
  assert v->>'reason' = 'not_verified', 'director_approves_by_link_and_code: a code first';
  v := public.svc_approval_code(v_token, null, null);
  assert (v->>'ok')::boolean, 'director_approves_by_link_and_code: a code asked for';
  perform tests.as_postgres();
  assert exists (select 1 from net._requests where id > v_old and body->>'kind' = 'approval_code' and body->>'id' = l.id::text),
    'director_approves_by_link_and_code: the code goes';
  m := public.svc_identity_mail('approval_code', l.id);
  v_code := m->>'code';
  assert v_code ~ '^\d{6}$' and m->>'to' = 'dayo@director.example.test' and m->'sms'->>'text' like v_code || ' is your code%',
    'director_approves_by_link_and_code: the code';
  perform tests.as_service();
  v := public.svc_approval_verify(v_token, case when v_code = '000000' then '111111' else '000000' end, null, null);
  assert v->>'reason' = 'wrong_code' and (v->>'tries_left')::int = 4, format('director_approves_by_link_and_code: a wrong code, got %s', v);
  v := public.svc_approval_verify(v_token, v_code, null, null);
  assert (v->>'ok')::boolean and (v->>'verified')::boolean, 'director_approves_by_link_and_code: verified';
  v := public.svc_approval_decide(v_token, array[s2], false, 'no', null, null);
  assert v->>'reason' = 'note', 'director_approves_by_link_and_code: a reason to reject';
  v := public.svc_approval_decide(v_token, array[a, (select id from approvals where sale_id = s2)], true, null, '10.0.0.1', 'test');
  perform tests.as_postgres();
  assert (select bool_and(x->>'status' = 'approved') from jsonb_array_elements(v->'results') x) and jsonb_array_length(v->'items') = 0,
    format('director_approves_by_link_and_code: approved, got %s', v->'results');
  assert (select status = 'open' and created_by = tests.id('bisi_seat') from sales where id = s), 'director_approves_by_link_and_code: issued as Bisi';
  assert (select decided_name = 'DAYO DIRECTOR (director)' and decided_by is null and decided_ip = '10.0.0.1' from approvals where id = a),
    'director_approves_by_link_and_code: who decided';
end $$;

-- test: firm_payments_and_schedules
-- A payment out of the wallet by the firm waits for Dayo; approved, it can be sent; cancelling it withdraws it. A bulk
-- payment waits the same way. A recurring schedule waits once, and a rejected one is paused and cannot be run or resumed.
-- Ending the mandate withdraws what waits and wipes Dayo's contact.
do $$
declare mo uuid := tests.id('mo'); w uuid; v jsonb; po uuid; a public.approvals; r uuid; b1 uuid; b2 uuid;
begin
  insert into wallets (org_id, rail) values (mo, 'flutterwave') returning id into w;
  perform public.svc_wallet_ready(w, jsonb_build_object('account_ref', 'w-15', 'account_number', '0123456789', 'bank_name', 'Test Bank', 'account_name', 'Managed Foods Ltd'));
  perform private.post_entry(mo, 'Funding', 'manual', null, null, null, jsonb_build_array(
    jsonb_build_object('code', (select ledger_code from bank_accounts where id = (select bank_account_id from wallets where id = w)), 'debit', 500000),
    jsonb_build_object('code', '3001', 'credit', 500000)));
  perform tests.as_user(tests.id('bisi'));
  v := public.request_payout(mo, jsonb_build_object('purpose', 'expense', 'expense_account', '6201', 'amount', 25000, 'bank_code', '058',
    'bank_name', 'Test Bank', 'account_number', '0011223344', 'account_name', 'Fuel Station Ltd', 'narration', 'Diesel'));
  perform tests.as_postgres();
  po := (v->>'id')::uuid;
  select * into a from approvals where payout_id = po;
  assert v->>'status' = 'pending_approval' and a.approver = 'director' and a.kind = 'payout' and a.summary->>'account_name' = 'Fuel Station Ltd'
     and (a.summary->>'amount')::numeric = 25000, format('firm_payments_and_schedules: waits for Dayo, got %s', a.summary);
  perform tests.as_user(tests.id('bisi'));
  perform tests.throws(format('select public.approve_payout(%L, true)', po), '%director who confirmed the wallets%');
  v := public.get_payments(mo);
  assert (select x->'approval'->>'approver' from jsonb_array_elements(v->'payouts') x where (x->>'id')::uuid = po) = 'director',
    'firm_payments_and_schedules: the payment shows it';
  perform tests.as_postgres();
  perform private.approval_settle(a.id, true, null, null, 'DAYO DIRECTOR (director)', null, null);
  assert (select status from payouts where id = po) = 'approved', 'firm_payments_and_schedules: approved, ready to send';
  -- Another one, cancelled by the firm.
  perform tests.as_user(tests.id('bisi'));
  v := public.request_payout(mo, jsonb_build_object('purpose', 'expense', 'expense_account', '6201', 'amount', 1000, 'bank_code', '058',
    'bank_name', 'Test Bank', 'account_number', '0011223344', 'account_name', 'Fuel Station Ltd', 'narration', 'Diesel'));
  perform public.cancel_payout((v->>'id')::uuid);
  perform tests.as_postgres();
  assert (select status from approvals where payout_id = (v->>'id')::uuid) = 'cancelled', 'firm_payments_and_schedules: cancelled, withdrawn';

  -- Bulk payments: one approved, one rejected.
  perform tests.as_user(tests.id('bisi'));
  v := public.create_payout_batch(mo, jsonb_build_object('title', 'Diesel run', 'default_account', '6201', 'rows', jsonb_build_array(
    jsonb_build_object('row', 1, 'account_number', '0011223344', 'bank_code', '058', 'bank_name', 'Test Bank', 'account_name', 'Fuel Station Ltd',
      'amount', 5000, 'narration', 'Diesel'),
    jsonb_build_object('row', 2, 'account_number', '0011223355', 'bank_code', '058', 'bank_name', 'Test Bank', 'account_name', 'Gas Depot Ltd',
      'amount', 7000, 'narration', 'Gas'))));
  perform tests.as_postgres();
  b1 := (v->>'id')::uuid;
  select * into a from approvals where batch_id = b1;
  assert v->>'status' = 'pending_approval' and a.approver = 'director' and (a.summary->>'total')::numeric = 12000
     and jsonb_array_length(a.summary->'payments') = 2, format('firm_payments_and_schedules: the bulk payment waits, got %s', a.summary);
  perform tests.as_user(tests.id('bisi'));
  perform tests.throws(format('select public.approve_payout_batch(%L, true)', b1), '%director who confirmed the wallets%');
  assert not (public.get_payout_batch(b1)->'can'->>'approve')::boolean, 'firm_payments_and_schedules: the firm cannot approve it';
  v := public.create_payout_batch(mo, jsonb_build_object('title', 'Second run', 'default_account', '6201', 'rows', jsonb_build_array(
    jsonb_build_object('row', 1, 'account_number', '0011223344', 'bank_code', '058', 'bank_name', 'Test Bank', 'account_name', 'Fuel Station Ltd',
      'amount', 3000, 'narration', 'Diesel'))));
  perform tests.as_postgres();
  b2 := (v->>'id')::uuid;
  perform private.approval_settle(a.id, true, null, null, 'DAYO DIRECTOR (director)', null, null);
  perform private.approval_settle((select id from approvals where batch_id = b2), false, 'Use the fuel card', null, 'DAYO DIRECTOR (director)', null, null);
  assert (select status from payout_batches where id = b1) = 'approved' and not exists (select 1 from payouts where batch_id = b1 and status <> 'approved'),
    'firm_payments_and_schedules: approved, ready to send';
  assert (select status from payout_batches where id = b2) = 'cancelled' and (select error from payouts where batch_id = b2) = 'Use the fuel card',
    'firm_payments_and_schedules: rejected, cancelled';

  -- A schedule: rejected by Dayo, it is paused and stays so.
  perform tests.as_user(tests.id('bisi'));
  v := public.recurring_save(mo, jsonb_build_object('customer_id', tests.id('mo_cu'), 'frequency', 'monthly', 'day_of_month', 5,
    'start_date', '2027-01-01', 'auto_send', false, 'lines', '[{"description": "Retainer", "qty": 1, "unit_price": 50000, "vat_treatment": "standard"}]'::jsonb));
  r := (v->>'id')::uuid;
  assert v->>'approval_state' = 'pending' and v->'approval'->>'status' = 'pending', 'firm_payments_and_schedules: the schedule waits';
  perform tests.throws(format('select public.recurring_run_now(%L)', r), '%waiting for approval%');
  perform tests.as_postgres();
  perform private.approval_settle((select id from approvals where recurring_id = r and status = 'pending'), false, 'Not this year', null,
    'DAYO DIRECTOR (director)', null, null);
  assert (select approval_state = 'rejected' and status = 'paused' from recurring_invoices where id = r), 'firm_payments_and_schedules: rejected and paused';
  perform tests.as_user(tests.id('bisi'));
  perform tests.throws(format('select public.recurring_set_status(%L, %L)', r, 'active'), '%was not approved%');
  perform tests.throws(format('select public.recurring_run_now(%L)', r), '%was not approved%');
  -- Saved again, it waits again.
  v := public.recurring_save(mo, jsonb_build_object('id', r, 'notes', 'From February'));
  assert v->>'approval_state' = 'pending', 'firm_payments_and_schedules: asked again';
  -- One more thing waits: an invoice.
  perform pg_temp.invoice(mo, tests.id('mo_cu'));
  perform tests.as_postgres();

  -- Another director confirms: Dayo's contact is wiped, and the new one approves.
  insert into practice_director_confirmations (practice_id, client_id, name, email, status, approver_email)
  values (tests.id('pr'), tests.id('mo_client'), 'Eze Director', 'eze@director.example.test', 'review', 'eze@director.example.test')
  returning id into r;
  update practice_director_confirmations set status = 'confirmed', confirmed_at = now() + interval '1 second' where id = r;
  assert (select approver_email is null and approver_phone is null from practice_director_confirmations where id = tests.id('dayo_conf'))
     and (select d.id from private.org_approver(mo) d) = r, 'firm_payments_and_schedules: one director approves at a time';
  -- The old link is closed.
  assert (select private.approval_link_state(l) from approval_links l where org_id = mo order by created_at limit 1) = 'closed',
    'firm_payments_and_schedules: Dayo''s link is closed';

  -- The mandate ends (practice_end_mandate wants the wallets empty first; the link ends the same way): what waited is
  -- withdrawn and the contact wiped.
  update practice_clients set status = 'ended', ended_at = now() where id = tests.id('mo_client');
  assert not exists (select 1 from approvals where org_id = mo and status = 'pending')
     and (select status from recurring_invoices where id = (select recurring_id from approvals where org_id = mo and kind = 'recurring'
       order by created_at desc limit 1)) = 'paused', 'firm_payments_and_schedules: withdrawn at the end';
  assert not exists (select 1 from practice_director_confirmations where client_id = tests.id('mo_client') and (approver_email is not null or approver_phone is not null)),
    'firm_payments_and_schedules: contacts wiped';
end $$;

-- test: approval_grants
-- The director's page goes through the practice function (service role) only; the app's functions need a signed-in member.
do $$
begin
  perform tests.as_anon();
  perform tests.throws($q$select public.svc_approval_open('x', null, null)$q$, '%permission denied%');
  perform tests.throws($q$select public.approvals_list(gen_random_uuid())$q$, '%permission denied%');
  perform tests.as_user(tests.id('kemi'));
  perform tests.throws($q$select public.svc_approval_decide('x', null, true, null, null, null)$q$, '%permission denied%');
  perform tests.throws($q$select private.approval_settle(gen_random_uuid(), true, null, null, 'x', null, null)$q$, '%permission denied%');
  perform tests.as_postgres();
  assert not exists (select 1 from information_schema.role_table_grants where table_name in ('approvals', 'approval_links')
    and grantee in ('anon', 'authenticated')), 'approval_grants: no table access';
end $$;

rollback;
