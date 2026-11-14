-- Release 6 (20261130000100_audit_firms.sql): audits. A company above the small company limits has its accounts audited; a
-- partner firm with a verified ICAN or ANAN partner and FRC number, a confirmed bank account, its Tax ID, prices by turnover
-- band and a Flutterwave split offers audits; the business asks one, the firm answers, the business pays the fee and VAT less
-- WHT at checkout, the bill goes in its books, and TaxStreem's referral fee is split off. A professional services company is
-- small for CIT on its size. Only fake people (example.test addresses).
begin;

-- Fixture: Ada owns Ada Industries Ltd (₦150m turnover in 2025) with Bimpe (admin) and Kola (staff). Gina owns Gina Plant Ltd
-- (₦20m turnover, ₦300m of equipment). Chi owns Chi Consult Ltd (professional services, ₦30m turnover). Femi owns Femi Stores,
-- a business name with ₦150m turnover. Okafor Audit & Co (partner Bisi, manager Mo, staff Ife) and Head Partners (partner
-- Uche, which keeps Ada's books) audit. Tayo is TaxStreem's admin.
do $$
declare o uuid; g uuid; c uuid; f uuid; pr uuid; hp uuid;
begin
  perform tests.hooks_on();
  perform tests.remember('ada', tests.user('ada.owner@industries.example.test', 'Ada Owner'));
  perform tests.remember('bimpe', tests.user('bimpe.admin@industries.example.test', 'Bimpe Admin'));
  perform tests.remember('kola', tests.user('kola.staff@industries.example.test', 'Kola Staff'));
  perform tests.remember('gina', tests.user('gina.owner@plant.example.test', 'Gina Owner'));
  perform tests.remember('chi', tests.user('chi.owner@consult.example.test', 'Chi Owner'));
  perform tests.remember('femi', tests.user('femi.owner@stores.example.test', 'Femi Owner'));
  perform tests.remember('bisi', tests.user('bisi.partner@okafor.example.test', 'Bisi Partner'));
  perform tests.remember('mo', tests.user('mo.manager@okafor.example.test', 'Mo Manager'));
  perform tests.remember('ife', tests.user('ife.staff@okafor.example.test', 'Ife Staff'));
  perform tests.remember('uche', tests.user('uche.partner@head.example.test', 'Uche Partner'));
  perform tests.remember('tayo', tests.admin_user('tayo.admin@taxstreem.example.test'));

  o := tests.remember('o', tests.org(tests.id('ada'), 'Ada Industries Ltd'));
  update orgs set legal_form = 'company', incorporation_date = '2015-02-01' where id = o;
  perform tests.remember('bimpe_seat', tests.member(o, tests.id('bimpe'), 'admin'));
  perform tests.remember('kola_seat', tests.member(o, tests.id('kola'), 'staff'));
  g := tests.remember('g', tests.org(tests.id('gina'), 'Gina Plant Ltd'));
  update orgs set legal_form = 'company', incorporation_date = '2015-02-01', filing_only = true where id = g;
  c := tests.remember('c', tests.org(tests.id('chi'), 'Chi Consult Ltd'));
  update orgs set legal_form = 'company', incorporation_date = '2015-02-01', professional_services = true where id = c;
  f := tests.remember('f', tests.org(tests.id('femi'), 'Femi Stores'));
  update orgs set legal_form = 'enterprise', commenced_on = '2015-02-01' where id = f;

  perform private.post_entry(o, 'Sales 2025', 'manual', null, null, null, jsonb_build_array(
    jsonb_build_object('code', '1101', 'debit', 150000000), jsonb_build_object('code', '4107', 'credit', 150000000)), '2025-06-30 12:00+01');
  perform private.post_entry(g, 'Sales 2025', 'manual', null, null, null, jsonb_build_array(
    jsonb_build_object('code', '1101', 'debit', 20000000), jsonb_build_object('code', '4107', 'credit', 20000000)), '2025-06-30 12:00+01');
  perform private.post_entry(g, 'Equipment', 'manual', null, null, null, jsonb_build_array(
    jsonb_build_object('code', '1506', 'debit', 300000000), jsonb_build_object('code', '3001', 'credit', 300000000)), '2025-03-31 12:00+01');
  perform private.post_entry(c, 'Fees 2025', 'manual', null, null, null, jsonb_build_array(
    jsonb_build_object('code', '1101', 'debit', 30000000), jsonb_build_object('code', '4107', 'credit', 30000000)), '2025-06-30 12:00+01');
  perform private.post_entry(f, 'Sales 2025', 'manual', null, null, null, jsonb_build_array(
    jsonb_build_object('code', '1101', 'debit', 150000000), jsonb_build_object('code', '4107', 'credit', 150000000)), '2025-06-30 12:00+01');

  pr := tests.remember('pr', tests.practice(tests.id('bisi'), 'Okafor Audit & Co'));
  update practices set state = 'Lagos', email = 'audit@okafor.example.test', address = '12 Broad Street, Lagos' where id = pr;
  perform tests.remember('mo_pm', tests.practice_member(pr, tests.id('mo'), 'manager'));
  perform tests.remember('ife_pm', tests.practice_member(pr, tests.id('ife'), 'staff'));
  perform tests.remember('bisi_pm', (select id from practice_members where practice_id = pr and user_id = tests.id('bisi')));
  hp := tests.remember('hp', tests.practice(tests.id('uche'), 'Head Partners'));
  update practices set state = 'Abuja' where id = hp;
  perform tests.remember('ada_client', tests.involved_client(hp, o));
end $$;

-- Makes a firm ready for audits as each step of the release does it: FRC number checked, bank account confirmed, Tax ID and
-- prices, Flutterwave split. p_vat: the firm charges VAT.
create function pg_temp.make_ready(p_practice uuid, p_partner uuid, p_frc text, p_account text, p_vat boolean, p_prices jsonb) returns void
language plpgsql as $f$
declare v_member uuid;
begin
  perform tests.as_user(p_partner);
  perform public.practice_set_licence(p_practice, jsonb_build_object('licence_body', 'ICAN', 'licence_no', 'TEST/0001', 'frc_no', p_frc));
  perform public.practice_audit_save(p_practice, jsonb_build_object('entity_type', 'partnership', 'tin', '12345678-0001', 'vat_registered', p_vat, 'prices', p_prices));
  perform tests.as_postgres();
  select id into v_member from practice_members where practice_id = p_practice and user_id = p_partner;
  perform tests.as_user(tests.id('tayo'), 'aal2');
  perform public.admin_licence_decide(v_member, 'verified');
  perform public.admin_frc_decide(v_member, 'verified');
  perform tests.as_service();
  perform public.svc_practice_bank_save(p_practice, p_partner, jsonb_build_object('bank_code', '058', 'bank_name', 'GTBank', 'account_number', p_account,
    'account_name', 'Test Firm', 'name_match', true));
  perform public.svc_audit_subaccount_save(p_practice, jsonb_build_object('status', 'ready', 'ref', 'RS_' || p_account, 'num', 77, 'bank', '058', 'account', p_account));
  perform tests.as_postgres();
end $f$;

-- Notifications a person got with a title like p_like.
create function pg_temp.told(p_user uuid, p_like text) returns int language sql as $f$
  select count(*)::int from notifications where user_id = p_user and title like p_like
$f$;

-- test: cit_small_professional
-- A professional services company is small for CIT on its turnover and fixed assets alone (rate 0); for VAT it is never small.
do $$
declare c uuid := tests.id('c'); r jsonb;
begin
  r := private.cit_compute(c, 2025);
  assert (r->>'small')::boolean and r->>'class' = 'SMALL', format('cit_small_professional: small for CIT, got %s / %s', r->>'small', r->>'class');
  assert coalesce((r->'figures'->>'turnover')::numeric, 0) = 30000000, format('cit_small_professional: turnover, got %s', r->'figures'->>'turnover');
  r := private.vat_small_status(c);
  assert not coalesce((r->>'small')::boolean, false), format('cit_small_professional: never small for VAT, got %s', r);
end $$;

-- test: bands_and_settings
-- The default bands and TaxStreem's changes to the rate, the days and the bands, checked.
do $$
declare r jsonb; b jsonb;
begin
  b := private.audit_bands();
  assert jsonb_array_length(b) = 5, format('bands_and_settings: five bands, got %s', b);
  assert b->0 = '{"key": "250000000", "from": 0, "up_to": 250000000, "label": "Up to ₦250m"}'::jsonb, format('bands_and_settings: first band, got %s', b->0);
  assert b->2->>'label' = '₦500m to ₦1bn' and b->4 = '{"key": "top", "from": 5000000000, "up_to": null, "label": "Above ₦5bn"}'::jsonb,
    format('bands_and_settings: names, got %s', b);
  assert private.audit_band(150000000)->>'key' = '250000000' and private.audit_band(250000000)->>'key' = '250000000'
     and private.audit_band(250000001)->>'key' = '500000000' and private.audit_band(9e9)->>'key' = 'top', 'bands_and_settings: which band';
  assert (private.audit_settings()->>'referral_rate')::numeric = 0.10 and (private.audit_settings()->>'request_days')::int = 7, 'bands_and_settings: defaults';

  perform tests.as_user(tests.id('bisi'));
  perform tests.throws($q$select public.admin_audit_settings_save('{"referral_rate": 0.2}')$q$, '%only for TaxStreem%');
  perform tests.as_user(tests.id('tayo'), 'aal2');
  perform tests.throws($q$select public.admin_audit_settings_save('{"referral_rate": 0.6}')$q$, '%between 0% and 50%%');
  perform tests.throws($q$select public.admin_audit_settings_save('{"bands": [500000000, 250000000]}')$q$, '%above the one before%');
  perform tests.throws($q$select public.admin_audit_settings_save('{"request_days": 0}')$q$, '%between 1 and 30 days%');
  r := public.admin_audit_settings_save('{"referral_rate": 0.125, "bands": [250000000, 1500000000]}');
  assert (r->'settings'->>'referral_rate')::numeric = 0.125 and r->'bands'->1->>'label' = '₦250m to ₦1.5bn' and r->'bands'->2->>'label' = 'Above ₦1.5bn',
    format('bands_and_settings: saved, got %s', r->'bands');
  r := public.admin_audit_settings_save('{"referral_rate": 0.1, "bands": [250000000, 500000000, 1000000000, 5000000000]}');
  perform tests.as_postgres();
  assert (select updated_by from platform_settings where key = 'audits') = tests.id('tayo'), 'bands_and_settings: who changed it';
end $$;

-- test: frc_numbers
-- The FRC number goes with the licence; TaxStreem checks it; a partner signs audits with both verified.
do $$
declare pr uuid := tests.id('pr'); h jsonb; me jsonb; r jsonb;
begin
  perform tests.as_user(tests.id('bisi'));
  perform tests.throws(format($q$select public.practice_set_licence(%L, '{"licence_body": "ICAN", "licence_no": "TEST/0001", "frc_no": "x"}')$q$, pr),
    '%as it appears on your certificate%');
  h := public.practice_set_licence(pr, '{"licence_body": "ICAN", "licence_no": "TEST/0001", "frc_no": "frc/2014/ican/ 00000001234"}');
  me := h->'me';
  assert me->>'frc_no' = 'FRC/2014/ICAN/00000001234' and me->>'frc_status' = 'pending' and me->>'licence_status' = 'verified'
     and not (me->>'signs_audits')::boolean, format('frc_numbers: saved and waiting, got %s', me);
  -- Saving the licence alone keeps the FRC number.
  h := public.practice_set_licence(pr, '{"licence_body": "ICAN", "licence_no": "TEST/0001"}');
  assert h->'me'->>'frc_no' = 'FRC/2014/ICAN/00000001234', 'frc_numbers: kept';
  perform tests.as_postgres();
  assert jsonb_array_length(private.audit_signers(pr)) = 0, 'frc_numbers: no signer yet';

  perform tests.as_user(tests.id('tayo'), 'aal2');
  r := public.admin_licences('pending');
  assert exists (select 1 from jsonb_array_elements(r) x where x->>'id' = tests.id('bisi_pm')::text and x->>'frc_status' = 'pending'
    and x->>'licence_status' = 'verified'), format('frc_numbers: waiting for TaxStreem, got %s', r);
  perform tests.throws(format($q$select public.admin_frc_decide(%L, 'rejected', 'no')$q$, tests.id('bisi_pm')), '%Say why%');
  r := public.admin_frc_decide(tests.id('bisi_pm'), 'verified');
  assert r->>'frc_status' = 'verified', 'frc_numbers: verified';
  perform tests.as_postgres();
  assert pg_temp.told(tests.id('bisi'), 'TaxStreem verified your FRC number') = 1, 'frc_numbers: told';
  assert private.audit_signers(pr) @> jsonb_build_array(jsonb_build_object('name', 'Bisi Partner', 'body', 'ICAN', 'frc_no', 'FRC/2014/ICAN/00000001234')),
    format('frc_numbers: signs audits, got %s', private.audit_signers(pr));

  -- A changed number is checked again; a CITN licence never signs audits.
  perform tests.as_user(tests.id('bisi'));
  h := public.practice_set_licence(pr, '{"licence_body": "ICAN", "licence_no": "TEST/0001", "frc_no": "FRC/2014/ICAN/00000009999"}');
  assert h->'me'->>'frc_status' = 'pending', 'frc_numbers: a new number waits again';
  perform tests.as_postgres();
  update practice_members set frc_status = 'verified', licence_body = 'CITN' where id = tests.id('bisi_pm');
  assert jsonb_array_length(private.audit_signers(pr)) = 0, 'frc_numbers: CITN does not sign audits';
  update practice_members set licence_body = 'ICAN', frc_no = 'FRC/2014/ICAN/00000001234' where id = tests.id('bisi_pm');

  -- Setting up a practice can carry the FRC number.
  perform tests.as_user(tests.id('mo'));
  perform tests.throws($q$select public.create_practice('{"name": "Mo and Co", "frc_no": "?"}')$q$, '%as it appears on your certificate%');
  h := public.create_practice('{"name": "Mo and Co", "licence_body": "ANAN", "licence_no": "AN/22", "frc_no": "FRC/2020/ANAN/00000000042"}');
  assert h->'me'->>'frc_no' = 'FRC/2020/ANAN/00000000042' and h->'me'->>'frc_status' = 'pending', format('frc_numbers: at set-up, got %s', h->'me');
  perform tests.as_postgres();
end $$;

-- test: firm_readiness
-- Each step must be done before a firm is listed; only a partner sets the offer or switches it on.
do $$
declare pr uuid := tests.id('pr'); r jsonb; st jsonb;
begin
  perform tests.as_user(tests.id('ife'));
  r := public.practice_audit(pr);
  assert r->'requests' = '[]'::jsonb and not (r->'ready'->>'ready')::boolean, 'firm_readiness: staff see the offer, no requests';
  perform tests.throws(format($q$select public.practice_audit_save(%L, '{"tin": "12345678-0001"}')$q$, pr), '%Only partners and managers%');
  perform tests.as_user(tests.id('mo'));
  perform tests.throws(format($q$select public.practice_audit_save(%L, '{"tin": "12345678-0001"}')$q$, pr), '%Only a partner sets%');
  perform tests.throws(format($q$select public.practice_audit_switch(%L, true)$q$, pr), '%Only a partner switches%');

  perform tests.as_user(tests.id('bisi'));
  r := public.practice_audit(pr);
  select jsonb_object_agg(x->>'id', (x->>'done')::boolean) into st from jsonb_array_elements(r->'ready'->'steps') x;
  assert st = '{"signer": true, "bank": false, "tax": false, "prices": false, "flutterwave": false}'::jsonb, format('firm_readiness: first, got %s', st);
  perform tests.throws(format($q$select public.practice_audit_switch(%L, true)$q$, pr), '%Finish these first. A bank account in the practice''s or a partner''s name, confirmed with the bank. The firm''s Tax ID%');
  perform tests.throws(format($q$select public.practice_audit_save(%L, '{"tin": "TIN"}')$q$, pr), '%Tax ID as digits%');
  perform tests.throws(format($q$select public.practice_audit_save(%L, '{"entity_type": "club"}')$q$, pr), '%what the firm is%');
  perform tests.throws(format($q$select public.practice_audit_save(%L, '{"prices": {"250000000": "-5"}}')$q$, pr), '%in naira, above zero%');
  r := public.practice_audit_save(pr, '{"entity_type": "partnership", "tin": "12345678-0001", "vat_registered": true, "note": "Audits for manufacturers",
    "prices": {"250000000": "5000000", "500000000": "", "nonsense": "9", "top": 40000000}}');
  assert r->'offer'->'prices' = '{"250000000": 5000000, "top": 40000000}'::jsonb and r->'offer'->>'tin' = '12345678-0001'
     and (r->'offer'->>'vat_registered')::boolean, format('firm_readiness: offer saved, got %s', r->'offer');
  -- No bank account yet: the Flutterwave split cannot be set up.
  perform tests.throws(format($q$select public.practice_audit_flutterwave_check(%L)$q$, pr), '%Add the bank account first%');
  perform tests.as_postgres();
end $$;

do $$
declare pr uuid := tests.id('pr'); r jsonb; st jsonb;
begin
  perform tests.as_service();
  perform public.svc_practice_bank_save(pr, tests.id('bisi'), '{"bank_code": "058", "bank_name": "GTBank", "account_number": "0011223344",
    "account_name": "Someone Else", "name_match": false}');
  perform tests.as_user(tests.id('bisi'));
  perform tests.throws(format($q$select public.practice_audit_flutterwave_check(%L)$q$, pr), '%in another name%');
  perform tests.as_service();
  perform public.svc_practice_bank_save(pr, tests.id('bisi'), '{"bank_code": "058", "bank_name": "GTBank", "account_number": "0011223344",
    "account_name": "Okafor Audit and Co", "name_match": true}');
  perform tests.as_user(tests.id('bisi'));
  assert (public.practice_audit_flutterwave_check(pr)->>'ok')::boolean, 'firm_readiness: may set up Flutterwave';
  perform tests.as_service();
  perform public.svc_audit_subaccount_save(pr, '{"status": "failed", "error": "IP not whitelisted"}');
  perform tests.as_user(tests.id('bisi'));
  r := public.practice_audit(pr);
  assert r->'offer'->'flutterwave'->>'status' = 'failed' and (select x->>'text' from jsonb_array_elements(r->'ready'->'steps') x where x->>'id' = 'flutterwave')
    = 'Flutterwave could not set up the split: IP not whitelisted', format('firm_readiness: failed split, got %s', r->'ready');
  perform tests.as_service();
  r := public.svc_audit_subaccount(pr);
  assert r->'bank'->>'account_number' = '0011223344' and (r->>'referral_rate')::numeric = 0.1 and r->'subaccount'->>'status' = 'failed',
    format('firm_readiness: what the function gets, got %s', r);
  perform public.svc_audit_subaccount_save(pr, '{"status": "ready", "ref": "RS_OKAFOR", "num": 2181, "bank": "058", "account": "0011223344"}');
  perform tests.as_user(tests.id('bisi'));
  r := public.practice_audit(pr);
  select jsonb_object_agg(x->>'id', (x->>'done')::boolean) into st from jsonb_array_elements(r->'ready'->'steps') x;
  assert st = '{"signer": true, "bank": true, "tax": true, "prices": true, "flutterwave": true}'::jsonb and (r->'ready'->>'ready')::boolean
     and not (r->'ready'->>'listed')::boolean, format('firm_readiness: ready, not on, got %s', r->'ready');
  r := public.practice_audit_switch(pr, true);
  assert (r->'ready'->>'listed')::boolean and (r->'me'->>'signs')::boolean, 'firm_readiness: listed';

  -- A changed payout account needs the split set up again.
  perform tests.as_service();
  perform public.svc_practice_bank_save(pr, tests.id('bisi'), '{"bank_code": "058", "bank_name": "GTBank", "account_number": "0099887766",
    "account_name": "Okafor Audit and Co", "name_match": true}');
  perform tests.as_postgres();
  r := private.audit_ready(pr);
  assert not (r->>'listed')::boolean and (select x->>'text' from jsonb_array_elements(r->'steps') x where x->>'id' = 'flutterwave')
    = 'The payout account changed: set up Flutterwave again', format('firm_readiness: changed account, got %s', r);
  perform tests.as_service();
  perform public.svc_audit_subaccount_save(pr, '{"status": "ready", "ref": "RS_OKAFOR", "num": 2181, "bank": "058", "account": "0099887766"}');
  perform tests.as_postgres();
  assert (private.audit_ready(pr)->>'listed')::boolean, 'firm_readiness: listed again';
end $$;

-- test: audit_need
-- Turnover above ₦100m or fixed assets above ₦250m: an audit. A business name never; a small company not.
do $$
declare r jsonb;
begin
  r := private.audit_need(tests.id('o'), 2025);
  assert (r->>'company')::boolean and (r->>'required')::boolean and (r->>'over_turnover')::boolean and not (r->>'over_assets')::boolean
     and (r->>'turnover')::numeric = 150000000 and (r->>'turnover_max')::numeric = 100000000 and (r->>'ended')::boolean
     and r->'band'->>'key' = '250000000', format('audit_need: Ada, got %s', r);
  r := private.audit_need(tests.id('g'), 2025);
  assert (r->>'required')::boolean and not (r->>'over_turnover')::boolean and (r->>'over_assets')::boolean and (r->>'fixed_assets')::numeric = 300000000,
    format('audit_need: Gina by assets, got %s', r);
  r := private.audit_need(tests.id('c'), 2025);
  assert (r->>'company')::boolean and not (r->>'required')::boolean, format('audit_need: Chi is small, professional services or not, got %s', r);
  r := private.audit_need(tests.id('f'), 2025);
  assert not (r->>'company')::boolean and not (r->>'required')::boolean, format('audit_need: a business name, got %s', r);
  -- The limits are TaxStreem's tax rules.
  update tax_rules set value = 200000000 where key = 'small_company_turnover';
  assert not (private.audit_need(tests.id('o'), 2025)->>'required')::boolean, 'audit_need: the rule decides';
  update tax_rules set value = 100000000 where key = 'small_company_turnover';
end $$;

-- test: firms_for_business
-- Listed firms with a price for the business's band; the firm that keeps its books with a warning; others not.
do $$
declare o uuid := tests.id('o'); r jsonb; x jsonb;
begin
  perform pg_temp.make_ready(tests.id('hp'), tests.id('uche'), 'FRC/2016/ICAN/00000000777', '0055667788', false, '{"250000000": 3000000}');
  perform tests.as_user(tests.id('uche'));
  perform public.practice_audit_switch(tests.id('hp'), true);
  perform tests.as_user(tests.id('kola'));
  r := public.audit_firms(o, 2025);
  assert r->'band'->>'label' = 'Up to ₦250m' and jsonb_array_length(r->'firms') = 2, format('firms_for_business: two firms, got %s', r);
  x := r->'firms'->0;
  assert x->>'name' = 'Okafor Audit & Co' and (x->>'price')::numeric = 5000000 and (x->>'vat')::numeric = 375000 and not (x->>'keeps_books')::boolean
     and x->'signers'->0->>'frc_no' = 'FRC/2014/ICAN/00000001234' and x->>'note' = 'Audits for manufacturers', format('firms_for_business: Okafor first, got %s', x);
  x := r->'firms'->1;
  assert x->>'name' = 'Head Partners' and (x->>'keeps_books')::boolean and (x->>'vat')::numeric = 0, format('firms_for_business: Head Partners warned, got %s', x);
  -- Gina is in the same band; Femi's is not a company but sees the band.
  perform tests.as_user(tests.id('gina'));
  assert jsonb_array_length(public.audit_firms(tests.id('g'), 2025)->'firms') = 2, 'firms_for_business: Gina';
  -- A firm switched off, or audits closed by TaxStreem, is not shown.
  perform tests.as_user(tests.id('uche'));
  perform public.practice_audit_switch(tests.id('hp'), false);
  perform tests.as_user(tests.id('ada'));
  assert jsonb_array_length(public.audit_firms(o, 2025)->'firms') = 1, 'firms_for_business: switched off';
  perform tests.as_postgres();
  update platform_settings set value = value || '{"enabled": false}' where key = 'audits';
  perform tests.as_user(tests.id('ada'));
  assert public.audit_firms(o, 2025)->'firms' = '[]'::jsonb, 'firms_for_business: closed';
  perform tests.as_postgres();
  update platform_settings set value = value || '{"enabled": true}' where key = 'audits';
  perform tests.as_user(tests.id('uche'));
  perform public.practice_audit_switch(tests.id('hp'), true);
  perform tests.as_postgres();
end $$;

-- test: request_and_answer
-- The owner or an admin asks; the firm hears; a manager declines with a note; the business asks again and a partner accepts.
do $$
declare o uuid := tests.id('o'); pr uuid := tests.id('pr'); r jsonb; e jsonb; v_id uuid;
begin
  perform tests.as_user(tests.id('kola'));
  r := public.audit_state(o, 2025);
  assert (r->'need'->>'required')::boolean and not (r->>'can_act')::boolean and r->'engagement' = 'null'::jsonb, format('request_and_answer: staff see it, got %s', r);
  perform tests.throws(format($q$select public.audit_request(%L, 2025, %L)$q$, o, pr), '%owner or an admin%');
  perform tests.as_user(tests.id('femi'));
  perform tests.throws(format($q$select public.audit_request(%L, 2025, %L)$q$, tests.id('f'), pr), '%Only a company has its accounts audited%');
  perform tests.as_user(tests.id('bimpe'));
  perform tests.throws(format($q$select public.audit_request(%L, 2031, %L)$q$, o, pr), '%Choose the year%');
  perform tests.throws(format($q$select public.audit_request(%L, 2025, %L)$q$, o, tests.id('o')), '%not taking audits%');
  r := public.audit_request(o, 2025, pr, '{"note": "Year end 31 December"}');
  e := r->'engagement';
  assert e->>'status' = 'requested' and (e->>'price')::numeric = 5000000 and (e->>'vat')::numeric = 375000 and e->'firm'->>'name' = 'Okafor Audit & Co'
     and not e->'firm' ? 'price' and not e ? 'referral' and e->'band'->>'key' = '250000000' and (e->>'turnover')::numeric = 150000000
     and e->>'lapses_at' is not null, format('request_and_answer: asked, got %s', e);
  perform tests.throws(format($q$select public.audit_request(%L, 2025, %L)$q$, o, tests.id('hp')), '%already have an auditor or a request waiting%');
  perform tests.as_postgres();
  assert pg_temp.told(tests.id('bisi'), 'Ada Industries Ltd asks you to audit its 2025 accounts') = 1
     and pg_temp.told(tests.id('mo'), 'Ada Industries Ltd asks you to audit its 2025 accounts') = 1
     and pg_temp.told(tests.id('ife'), 'Ada Industries Ltd%') = 0, 'request_and_answer: partners and managers hear';

  perform tests.as_user(tests.id('ife'));
  assert public.practice_audit(pr)->'requests' = '[]'::jsonb, 'request_and_answer: staff do not see requests';
  perform tests.throws(format($q$select public.practice_audit_answer(%L, true)$q$, (e->>'id')::uuid), '%Only partners and managers%');
  perform tests.as_user(tests.id('mo'));
  r := public.practice_audit(pr);
  assert jsonb_array_length(r->'requests') = 1 and (r->'requests'->0->>'referral')::numeric = 500000 and (r->'requests'->0->>'referral_rate')::numeric = 0.1
     and r->'requests'->0->'business'->>'name' = 'Ada Industries Ltd' and r->'requests'->0->>'note' = 'Year end 31 December',
    format('request_and_answer: the firm sees it, got %s', r->'requests');
  r := public.practice_audit_answer((e->>'id')::uuid, false, 'We are full until March.');
  assert r->'requests' = '[]'::jsonb and r->'engagements'->0->>'status' = 'declined', 'request_and_answer: declined';
  perform tests.throws(format($q$select public.practice_audit_answer(%L, true)$q$, (e->>'id')::uuid), '%withdrawn or answered%');
  perform tests.as_postgres();
  assert pg_temp.told(tests.id('ada'), 'Okafor Audit & Co cannot audit your 2025 accounts') = 1
     and pg_temp.told(tests.id('bimpe'), 'Okafor Audit & Co cannot audit your 2025 accounts') = 1
     and pg_temp.told(tests.id('kola'), 'Okafor%') = 0, 'request_and_answer: owner and admin hear';

  perform tests.as_user(tests.id('ada'));
  r := public.audit_request(o, 2025, pr);
  v_id := (r->'engagement'->>'id')::uuid;
  perform tests.remember('e1', v_id);
  perform tests.as_user(tests.id('bisi'));
  r := public.practice_audit_answer(v_id, true, 'We start in January.');
  assert r->'engagements'->0->>'status' = 'accepted' and r->'engagements'->0->>'answer_note' = 'We start in January.', 'request_and_answer: accepted';
  perform tests.as_postgres();
  assert pg_temp.told(tests.id('ada'), 'Okafor Audit & Co will audit your 2025 accounts') = 1, 'request_and_answer: the business hears';
  assert (select count(*) from activity_log where org_id = o and action in ('audit_requested', 'audit_declined', 'audit_accepted')) = 4,
    'request_and_answer: in the activity log';
end $$;

-- test: pay_start
-- The bill from the firm is entered as a draft with its VAT and WHT; the checkout charges the fee and VAT less WHT;
-- TaxStreem's referral is 10% of the fee. Starting again keeps the same bill.
do $$
declare e uuid := tests.id('e1'); r jsonb; r2 jsonb; b public.bills; v public.vendors; c public.audit_charges;
begin
  perform tests.as_user(tests.id('kola'));
  perform tests.throws(format($q$select public.audit_pay_start(%L)$q$, e), '%owner or an admin of the business pays%');
  perform tests.as_user(tests.id('ada'));
  r := public.audit_pay_start(e);
  assert r->>'tx_ref' ~ '^AUD-[0-9A-F]{16}$' and (r->>'fee')::numeric = 5000000 and (r->>'vat')::numeric = 375000 and (r->>'wht')::numeric = 250000
     and (r->>'amount')::numeric = 5125000, format('pay_start: amounts, got %s', r);
  perform tests.as_postgres();
  select * into b from bills where id = (select bill_id from audit_engagements where id = e);
  select * into v from vendors where id = b.vendor_id;
  assert b.status = 'draft' and b.source = 'audit' and b.vendor_ref = 'AUDIT-2025' and b.total = 5375000 and b.wht_expected = 250000 and b.wht_category = 'professional'
     and (select account_code from bill_lines where bill_id = b.id) = '6501'
     and (select description from bill_lines where bill_id = b.id) = 'Audit of the financial statements for the year ended 31 December 2025',
    format('pay_start: the draft bill, got %s', to_jsonb(b));
  assert v.name = 'Okafor Audit & Co' and v.tin = '12345678-0001' and v.entity_type = 'partnership' and v.state = 'Lagos', format('pay_start: the vendor, got %s', to_jsonb(v));
  select * into c from audit_charges where tx_ref = r->>'tx_ref';
  assert c.amount = 5125000 and c.referral = 500000 and c.subaccount_ref = 'RS_OKAFOR' and c.status = 'pending' and c.created_by = tests.id('ada'),
    format('pay_start: the charge, got %s', to_jsonb(c));
  perform tests.remember('b1', b.id);

  perform tests.as_user(tests.id('bimpe'));
  r2 := public.audit_pay_start(e);
  assert r2->>'tx_ref' <> r->>'tx_ref' and r2->>'bill' = r->>'bill', 'pay_start: again, same bill';
  perform tests.as_postgres();
  assert (select count(*) from bills where org_id = tests.id('o') and source = 'audit') = 1, 'pay_start: one bill';
  perform tests.as_service();
  r := public.svc_audit_charge(r2->>'tx_ref');
  assert r->'org'->>'email' = 'ada.owner@industries.example.test' and r->'firm'->>'name' = 'Okafor Audit & Co' and r->>'return_path' = '/tax/cit'
     and r->>'description' = 'Audit of the 2025 accounts by Okafor Audit & Co' and (r->'charge'->>'referral')::numeric = 500000,
    format('pay_start: what the function gets, got %s', r);
  perform tests.as_postgres();
end $$;

-- test: paid
-- Flutterwave's confirmation: too little is refused; the right amount approves the bill, pays the engagement and tells both
-- sides; a second payment is marked for a refund; a failed one just closes.
do $$
declare e uuid := tests.id('e1'); refs text[]; r jsonb; b public.bills;
begin
  select array_agg(tx_ref order by tx_ref) into refs from audit_charges where engagement_id = e;
  perform tests.as_user(tests.id('ada'));
  perform tests.throws(format($q$select public.svc_audit_charge_update(%L, '{"status": "successful"}')$q$, refs[1]), '%permission denied%');
  perform tests.as_service();
  perform tests.throws(format($q$select public.svc_audit_charge_update(%L, '{"status": "successful", "paid_amount": 5000}')$q$, refs[1]), '%but ₦5,125,000.00 was due%');
  r := public.svc_audit_charge_update(refs[1], '{"status": "successful", "paid_amount": 5125000, "fee": 2000, "provider_ref": "998877"}');
  assert r->>'status' = 'successful' and r->>'bill_error' is null, format('paid: confirmed, got %s', r);
  perform tests.as_postgres();
end $$;

do $$
declare e uuid := tests.id('e1'); refs text[]; r jsonb; b public.bills; a public.audit_engagements;
begin
  select array_agg(tx_ref order by tx_ref) into refs from audit_charges where engagement_id = e;
  select * into b from bills where id = tests.id('b1');
  assert b.status = 'approved' and b.journal_id is not null
     and b.approved_by = (select m.id from members m join audit_charges c on c.created_by = m.user_id and c.org_id = m.org_id where c.tx_ref = refs[1]),
    format('paid: the bill is approved by whoever started that payment, got %s', to_jsonb(b));
  select * into a from audit_engagements where id = e;
  assert a.status = 'paid' and a.paid_at is not null and a.amount = 5125000 and a.wht = 250000 and a.referral = 500000, format('paid: engagement, got %s', to_jsonb(a));
  assert (select status from audit_charges where tx_ref = refs[1]) = 'successful' and (select fee from audit_charges where tx_ref = refs[1]) = 2000, 'paid: charge';
  assert pg_temp.told(tests.id('ada'), 'The 2025 audit is paid for') = 1 and pg_temp.told(tests.id('bisi'), 'Ada Industries Ltd paid for the 2025 audit') = 1,
    'paid: both sides hear';
  assert (select body from notifications where user_id = tests.id('bisi') and title = 'Ada Industries Ltd paid for the 2025 audit')
    = '₦5,125,000.00 paid. Your bank receives it less TaxStreem''s referral fee (₦500,000.00) and Flutterwave''s charge. The business deducted ₦250,000.00 withholding tax.',
    'paid: what the firm is told';

  perform tests.as_service();
  r := public.svc_audit_charge_update(refs[1], '{"status": "successful", "paid_amount": 5125000}');
  assert r->>'status' = 'successful', 'paid: again is harmless';
  r := public.svc_audit_charge_update(refs[2], '{"status": "successful", "paid_amount": 5125000}');
  assert (r->>'duplicate')::boolean, 'paid: a second payment is a duplicate';
  perform tests.as_postgres();
  assert (select error from audit_charges where tx_ref = refs[2]) = 'Paid twice: TaxStreem refunds this payment.', 'paid: marked for refund';
  assert (select count(*) from journals where org_id = tests.id('o') and source_type = 'bill' and source_id = tests.id('b1')) = 1, 'paid: one journal';

  perform tests.as_user(tests.id('ada'));
  perform tests.throws(format($q$select public.audit_cancel(%L)$q$, e), '%paid for. Ask TaxStreem%');
  perform tests.throws(format($q$select public.audit_pay_start(%L)$q$, e), '%paid for already%');
  r := public.audit_state(tests.id('o'), 2025);
  assert r->'engagement'->>'status' = 'paid' and r->'engagement'->'bill'->>'status' = 'approved' and r->'engagement'->'charge'->>'status' = 'successful',
    format('paid: the business sees it, got %s', r->'engagement');
  perform tests.as_user(tests.id('tayo'), 'aal2');
  r := public.admin_audits();
  assert (r->'totals'->>'paid')::int = 1 and (r->'totals'->>'referral')::numeric = 500000 and (r->'totals'->>'refunds')::int = 1
     and (select jsonb_array_length(x->'charges') from jsonb_array_elements(r->'engagements') x where x->>'id' = e::text) = 2,
    format('paid: TaxStreem sees it, got %s', r->'totals');
  perform tests.as_postgres();
end $$;

-- test: own_and_cancel
-- An auditor of the business's own; cancelling voids a draft bill; a payment that arrives after cancelling still pays the
-- firm, and the voided bill is left for a person to look at.
do $$
declare g uuid := tests.id('g'); r jsonb; e uuid; v_tx text; v_bill uuid;
begin
  perform tests.as_user(tests.id('gina'));
  perform tests.throws(format($q$select public.audit_own(%L, 2025, '{"name": "X"}')$q$, g), '%firm''s name%');
  r := public.audit_own(g, 2025, '{"name": "Bello & Partners", "email": "audit@bello.example.test"}');
  assert r->'engagement'->>'kind' = 'own' and r->'engagement'->>'status' = 'recorded' and r->'engagement'->>'own_name' = 'Bello & Partners',
    format('own_and_cancel: own auditor, got %s', r->'engagement');
  perform tests.throws(format($q$select public.audit_request(%L, 2025, %L)$q$, g, tests.id('pr')), '%already have an auditor%');
  r := public.audit_cancel((r->'engagement'->>'id')::uuid);
  assert r->'engagement'->>'status' = 'cancelled', 'own_and_cancel: cancelled';

  r := public.audit_request(g, 2025, tests.id('pr'));
  e := (r->'engagement'->>'id')::uuid;
  perform tests.as_user(tests.id('bisi'));
  perform public.practice_audit_answer(e, true);
  perform tests.as_user(tests.id('gina'));
  v_tx := public.audit_pay_start(e)->>'tx_ref';
  perform tests.throws(format($q$select public.audit_cancel(%L)$q$, e), '%payment for this audit started a few minutes ago%');
  perform tests.as_postgres();
  update audit_charges set created_at = now() - interval '1 hour' where tx_ref = v_tx;
  select bill_id into v_bill from audit_engagements where id = e;
  perform tests.as_user(tests.id('gina'));
  r := public.audit_cancel(e);
  perform tests.as_postgres();
  assert (select status from bills where id = v_bill) = 'void' and pg_temp.told(tests.id('bisi'), 'Gina Plant Ltd withdrew its request for the 2025 audit') = 1,
    'own_and_cancel: draft bill voided, firm told';
  -- A payment that arrives after cancelling still counts; its bill stays void and the engagement says so.
  perform tests.as_service();
  r := public.svc_audit_charge_update(v_tx, '{"status": "successful", "paid_amount": 99999999}');
  perform tests.as_postgres();
  assert (select status from audit_engagements where id = e) = 'paid'
     and (select bill_error from audit_engagements where id = e) = 'The bill for the audit was changed by hand; check it under Bills.',
    format('own_and_cancel: paid after cancelling, got %s', r);
end $$;

-- test: tick
-- Requests unanswered past the days lapse; companies above the limits hear once a year; business names and small companies
-- never.
do $$
declare r jsonb; v_id uuid;
begin
  -- Chi asks Head Partners for a voluntary audit; it is not answered.
  perform tests.as_user(tests.id('chi'));
  v_id := (public.audit_request(tests.id('c'), 2025, tests.id('hp'))->'engagement'->>'id')::uuid;
  perform tests.as_postgres();
  update audit_engagements set requested_at = now() - interval '8 days' where id = v_id;
  delete from audit_notices;
  r := private.audit_tick();
  assert (r->>'lapsed')::int = 1, format('tick: lapsed, got %s', r);
  assert (select status from audit_engagements where id = v_id) = 'lapsed'
     and pg_temp.told(tests.id('chi'), 'Head Partners did not answer your audit request') = 1
     and pg_temp.told(tests.id('uche'), 'The request to audit Chi Consult Ltd lapsed') = 1, 'tick: both told';
  -- Ada and Gina have an audit for 2025 already; nobody has crossed for 2026; Femi is a business name, Chi is small.
  assert (r->>'told')::int = 0, format('tick: nobody new, got %s', r);
  perform private.post_entry(tests.id('c'), 'Fees 2026', 'manual', null, null, null, jsonb_build_array(
    jsonb_build_object('code', '1101', 'debit', 120000000), jsonb_build_object('code', '4107', 'credit', 120000000)), now());
  r := private.audit_tick();
  assert (r->>'told')::int = 1 and pg_temp.told(tests.id('chi'), 'Your 2026 accounts need an audit') = 1, format('tick: Chi crossed in 2026, got %s', r);
  assert (select body from notifications where user_id = tests.id('chi') and title = 'Your 2026 accounts need an audit')
    = 'Turnover of ₦120,000,000.00 is above the small company limit of ₦100,000,000.00. Choose a TaxStreem partner firm to audit them, or tell Counta who your auditor is.',
    'tick: what Chi is told';
  r := private.audit_tick();
  assert (r->>'told')::int = 0, 'tick: once a year';
end $$;

-- test: grants
do $$
begin
  perform tests.as_user(tests.id('ada'));
  perform tests.throws($q$select public.svc_audit_open()$q$, '%permission denied%');
  perform tests.throws(format($q$select public.svc_audit_subaccount(%L)$q$, tests.id('pr')), '%permission denied%');
  perform tests.throws($q$select private.audit_tick()$q$, '%permission denied%');
  perform tests.throws($q$select public.admin_audits()$q$, '%only for TaxStreem%');
  perform tests.as_anon();
  perform tests.throws(format($q$select public.audit_state(%L, 2025)$q$, tests.id('o')), '%permission denied%');
  perform tests.as_service();
  assert jsonb_typeof(public.svc_audit_open()) = 'array', 'grants: the poll reads open checkouts';
  perform tests.as_postgres();
end $$;

rollback;
