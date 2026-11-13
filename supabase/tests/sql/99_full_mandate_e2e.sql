-- The full mandate from end to end, as a firm lives it: due diligence on a prospect (its director and beneficial owner, a
-- risk rating, a conflicts check with nothing found), an engagement letter for a full mandate signed by the firm and
-- e-signed by the client through the link and the code, the partner's declaration of written authority, the gate, and the
-- business set up with the firm acting as its owner. Counta stays silent to the client (an alert goes to the firm instead).
-- The business's identity is verified against its CAC record, a director confirms the wallets with their NIN and a code
-- to the NIN's phone, and payments open. The firm
-- bills its fees from its own business on a schedule: the hourly tick issues the invoice, unbranded, and posts it as a
-- bill in the client's books. Finally the business is handed to its owner. Only fake people (example.test addresses); the
-- edge-function calls are only recorded in net._requests.
begin;

do $$
declare v_partner uuid;
begin
  v_partner := tests.remember('partner', tests.user('partner@firm.example.test', 'Bisi Partner'));
  perform tests.remember('owner', tests.user('owner@client.example.test', 'Ngozi Owner'));
  perform tests.remember('pr', tests.practice(v_partner, 'Bisi Partner & Co', true));
  update practices set email = 'office@firm.example.test' where id = tests.id('pr');
  perform tests.hooks_on();
end $$;

-- test: e2e_full_mandate
do $$
declare pr uuid := tests.id('pr'); partner uuid := tests.id('partner'); owner_user uuid := tests.id('owner');
  i uuid; l uuid; s uuid; c uuid; o uuid; f uuid; cu uuid; sched uuid; dc uuid; h uuid; v_sale uuid;
  tok text; code text; r jsonb;
begin
  -- 1. Due diligence: the prospect, its people, a low risk rating; the conflicts check finds nothing.
  perform tests.as_user(partner);
  i := (public.practice_intake_save(pr, jsonb_build_object('legal_name', 'Ikenna Textiles Ltd', 'mode_requested', 'full', 'rc_number', 'RC 7654321',
    'entity_type', 'company', 'risk_rating', 'low', 'risk_reason', 'Established trading company, no PEPs',
    'people', jsonb_build_array(jsonb_build_object('kind', 'director', 'name', 'Tunde Bello', 'role', 'Managing Director'),
                                jsonb_build_object('kind', 'beneficial_owner', 'name', 'Amina Yusuf', 'ownership_pct', 60))))->>'id')::uuid;
  r := public.practice_conflict_run(i);
  assert r->>'conflict_status' = 'none', format('e2e_full_mandate: conflicts check clear, got %s', r->'hits');

  -- 2. The engagement letter for a full mandate: drafted, signed by the firm, sent, e-signed by the client with the code.
  l := (public.practice_letter_draft(i, '{"variant": "full"}')->>'id')::uuid;
  perform tests.as_postgres();
  tok := private.letter_fingerprint(l);
  perform tests.as_service();
  perform public.svc_letter_frozen(l, jsonb_build_object('doc_path', 'practice/' || pr || '/letters/' || l || '/letter.pdf', 'doc_sha256', repeat('ab', 32),
    'by_user', partner, 'signature_name', 'Bisi Partner', 'ip', '203.0.113.5', 'ua', 'Test browser', 'fingerprint', tok));
  perform tests.as_user(partner);
  s := (public.practice_letter_send(l, '{"name":"Tunde Bello","email":"tunde.bello@director.example.test","title":"Managing Director"}')->'signers'->0->>'id')::uuid;
  perform tests.as_postgres();
  assert exists (select 1 from net._requests where body->>'action' = 'practice_mail' and body->>'kind' = 'letter_sign' and body->>'id' = s::text),
    'e2e_full_mandate: the signing email is queued';
  perform tests.as_service();
  tok := substring(public.svc_practice_mail('letter_sign', s)->>'link' from 'es_[0-9a-f]{48}$');
  code := public.svc_practice_mail('letter_code', s)->>'code';
  r := public.svc_sign_verify(tok, code, '198.51.100.20', 'Client browser');
  assert (r->>'ok')::boolean, format('e2e_full_mandate: the code, got %s', r);
  r := public.svc_sign_complete(tok, jsonb_build_object('signature_path', 'practice/' || pr || '/letters/' || l || '/signature-' || s || '.png',
    'final_path', 'practice/' || pr || '/letters/' || l || '/final.pdf', 'final_sha256', repeat('cd', 32), 'typed_name', 'Tunde Bello',
    'ip', '198.51.100.20', 'ua', 'Client browser'));
  assert (r->>'ok')::boolean, format('e2e_full_mandate: signed, got %s', r);
  perform tests.as_postgres();
  assert (select status from engagement_letters where id = l) = 'completed', 'e2e_full_mandate: the letter is complete';

  -- 3. The partner declares the client's written authority; the gate opens; the business is set up.
  perform tests.as_user(partner);
  perform public.practice_intake_declare(i, '{}');
  r := public.practice_mandate_gate(i);
  assert (r->>'ok')::boolean, format('e2e_full_mandate: gate, got %s', r);
  r := public.practice_create_business(i, '{"email":"books@firm.example.test"}');
  assert (r->>'ok')::boolean, format('e2e_full_mandate: set up, got %s', r);
  c := (r->>'client_id')::uuid;
  perform tests.as_postgres();
  o := (select org_id from practice_clients where id = c);
  assert (select role = 'admin' and acts_as_owner from members where org_id = o and user_id = partner), 'e2e_full_mandate: acting seat';
  assert (select managed_by = pr and identity_status = 'pending' from orgs where id = o) and not private.payments_open(o), 'e2e_full_mandate: run by the firm, money locked';

  -- 4. Silence: an alert meant for the client goes to the firm.
  insert into messages (org_id, channel, to_address, template, params) values (o, 'email', 'client-owner@client.example.test', 'alert', '{}');
  assert (select to_address from messages where org_id = o and template = 'alert' order by created_at desc limit 1) = 'partner@firm.example.test', 'e2e_full_mandate: silence';

  -- 5. Identity: the business's own profile (made by the acting owner) holds its CAC record (as the CAC lookup leaves it);
  -- the firm checks a director's NIN and it matches the record.
  perform tests.as_user(partner);
  perform public.kyc_draft(o);
  perform tests.as_postgres();
  assert (select for_business and status = 'draft' from kyc_profiles where org_id = o), 'e2e_full_mandate: the business''s own profile';
  update kyc_profiles set status = 'submitted', source = 'cac', submitted_at = now(),
    cac = '{"cac_id": 5151, "profile": {"classification": "COMPANY", "rc_number": "RC 7654321", "directors": [{"firstname": "TUNDE", "surname": "BELLO"}]}}'
  where org_id = o;
  perform tests.as_service();
  r := public.svc_identity_nin(partner, o, '1234', 'Tunde', null, 'Bello');
  assert (r->>'verified')::boolean, format('e2e_full_mandate: director''s NIN, got %s', r);
  perform tests.as_postgres();
  assert not private.payments_open(o), 'e2e_full_mandate: still locked until a director confirms';

  -- 6. The director confirms the wallets: their NIN matches the director on the CAC record, and the code goes to the
  -- NIN's phone (Termii is set up) and their CAC email. Money opens.
  insert into vault.secrets (name, secret) values ('TERMII_API_KEY', 'test-termii-key'), ('TERMII_SENDER_ID', 'TaxStreem');
  perform tests.as_user(partner);
  dc := (public.practice_director_request(c, '{"name":"Tunde Bello","email":"tunde.bello@director.example.test"}')->>'id')::uuid;
  perform tests.as_service();
  tok := substring(public.svc_practice_mail('director_confirm', dc)->>'link' from 'dc_[0-9a-f]{48}$');
  assert (public.svc_director_nin_begin(tok, '198.51.100.30', 'Director phone')->>'cac_id') = '5151', 'e2e_full_mandate: the NIN lookup''s turn';
  r := public.svc_director_identity(tok, '{"first": "TUNDE", "last": "BELLO", "last4": "9876", "nin_phone": "0803 123 4567",
    "cac": [{"surname": "BELLO", "given": "TUNDE", "email": "tunde.bello@director.example.test", "phone": null}]}', '198.51.100.30', 'Director phone');
  assert (r->>'ok')::boolean and r->>'route' = 'code', format('e2e_full_mandate: director''s code sent, got %s', r);
  code := public.svc_identity_mail('identity_code', (select check_id from practice_director_confirmations where id = dc))->>'code';
  r := public.svc_director_confirm(tok, code, '198.51.100.30', 'Director phone');
  assert r->>'status' = 'confirmed', format('e2e_full_mandate: director confirmed, got %s', r);
  perform tests.as_postgres();
  assert private.payments_open(o), 'e2e_full_mandate: director unlocked money';

  -- 7. Fees: the firm's own business, the client as its customer, a monthly retainer the tick issues, unbranded, and the
  -- fee mirrored as a bill in the client's books.
  perform tests.as_user(partner);
  f := (public.practice_firm_business(pr, '{"name":"Bisi Partner & Co"}')->>'firm_org_id')::uuid;
  cu := (public.practice_fee_customer(c, '{}')->>'customer_id')::uuid;
  sched := (public.recurring_save(f, jsonb_build_object('customer_id', cu, 'frequency', 'monthly', 'day_of_month', 1, 'start_date', '2026-01-01',
    'auto_send', false, 'practice_client_id', c,
    'lines', '[{"description": "Bookkeeping and tax retainer", "qty": 1, "unit_price": 250000, "vat_treatment": "standard"}]'::jsonb))->>'id')::uuid;
  perform tests.as_postgres();
  perform private.recurring_tick('2026-01-01 08:00:00+00');
  v_sale := (select sale_id from recurring_invoice_runs where schedule_id = sched and run_date = '2026-01-01');
  assert (select status = 'open' and channel = 'recurring' and customer_id = cu from sales where id = v_sale), 'e2e_full_mandate: the fee invoice issued';
  assert (select status from practice_fee_bills where client_id = c) = 'posted' and private.white_label(f, (select fee_customer_id from practice_clients where id = c)),
    'e2e_full_mandate: fee invoice mirrored, unbranded';
  assert (select b.total = s2.total from practice_fee_bills x join bills b on b.id = x.bill_id join sales s2 on s2.id = x.sale_id where x.client_id = c),
    'e2e_full_mandate: the bill matches the invoice';

  -- 8. The handover: the owner-to-be accepts the link; the firm stays on as an accountant. She is not the director who
  -- confirmed, so TaxStreem checks the handover before payments open again.
  perform tests.as_user(partner);
  h := (public.practice_handover_start(c, '{"email":"owner@client.example.test","name":"Ngozi Owner"}')->>'id')::uuid;
  perform tests.as_service();
  tok := substring(public.svc_practice_invite_link('handover', h)->>'link' from 'ph_[0-9a-f]{48}$');
  perform tests.as_user(owner_user);
  assert public.practice_handover_accept(tok)->>'org_id' = o::text, 'e2e_full_mandate: accepted';
  perform tests.as_postgres();
  assert (select managed_by is null from orgs where id = o) and (select role from members where org_id = o and user_id = owner_user) = 'owner', 'e2e_full_mandate: handed over';
  assert (select role = 'accountant' and not acts_as_owner from members where org_id = o and user_id = partner), 'e2e_full_mandate: the firm stays on as accountant';
  assert (select identity_status = 'review' and identity->>'reason' = 'handover' from orgs where id = o) and not private.payments_open(o)
     and exists (select 1 from practice_mandate_flags where client_id = c and kind = 'handover' and resolved_at is null), 'e2e_full_mandate: TaxStreem checks the handover';

  -- The business's own record of all of it.
  assert (select array_agg(distinct action) from activity_log where org_id = o and source = 'event') @> '{mandate_started,director_confirmed,fee_bill_posted,handover}',
    format('e2e_full_mandate: events recorded, got %s', (select array_agg(distinct action) from activity_log where org_id = o and source = 'event'));
end $$;

rollback;
