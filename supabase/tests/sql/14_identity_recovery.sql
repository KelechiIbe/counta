-- Release 1 of the identity work (20261125000100_director_identity.sql, 20261125000200_account_recovery.sql): the phone and
-- address helpers; a practice's intake filled from the CAC record and people's NINs checked from it; a company on Counta
-- once (the orgs trigger, the business profile told and refused); and a director recovering a business someone else set
-- up: their NIN matched to the CAC record, a code to the NIN's phone and their CAC email (never an address of the business's
-- people), the holder's 30 minutes, payments paused, the handover link, the dispute, TaxStreem's review and support. Only
-- fake people (example.test addresses); the edge-function calls are only recorded in net._requests.
begin;

-- Fixture: Termii set up; Ada owns Kano Steel Ltd (RC 5550001, Tax ID 1111111111111, identity verified) with Sola on her
-- staff; Bayo and Cleo are directors on its CAC record who want it; Dayo owns Benin Glass Ltd (RC 5550002); a verified
-- practice (partner Bisi) and TaxStreem's admin and reviewer.
do $$
declare v_ada uuid; v_dayo uuid; o uuid;
begin
  perform tests.hooks_on();
  insert into vault.secrets (name, secret) values ('TERMII_API_KEY', 'test-termii-key'), ('TERMII_SENDER_ID', 'TaxStreem');
  v_ada := tests.remember('ada', tests.user('ada.owner@kano.example.test', 'Ada Owner'));
  perform tests.remember('sola', tests.user('sola.staff@kano.example.test', 'Sola Staff'));
  perform tests.remember('bayo', tests.user('bayo@director.example.test', 'Bayo Adewale'));
  perform tests.remember('cleo', tests.user('cleo@director.example.test', 'Cleo Nwosu'));
  v_dayo := tests.remember('dayo', tests.user('dayo.owner@benin.example.test', 'Dayo Owner'));
  perform tests.remember('eze', tests.user('eze@director.example.test', 'Eze Obi'));
  perform tests.remember('partner', tests.user('bisi.partner@fourteen.example.test', 'Bisi Partner'));
  perform tests.remember('admin1', tests.admin_user('admin1@fourteen.example.test'));
  perform tests.remember('reviewer1', tests.user('reviewer1@fourteen.example.test'));
  insert into platform_reviewers (user_id) values (tests.id('reviewer1'));
  o := tests.remember('kano', tests.org(v_ada, 'Kano Steel Ltd'));
  update orgs set rc_number = 'RC 5550001', tin = '1111111111111', identity_status = 'verified' where id = o;
  update members set phone = '08077770000' where org_id = o and user_id = v_ada;
  perform tests.remember('sola_seat', tests.member(o, tests.id('sola'), 'staff'));
  o := tests.remember('benin', tests.org(v_dayo, 'Benin Glass Ltd'));
  update orgs set rc_number = 'RC 5550002', identity_status = 'verified' where id = o;
  perform tests.remember('pr', tests.practice(tests.id('partner'), 'Fourteen Partners', true));
  update practices set email = 'office@fourteen.example.test' where id = tests.id('pr');
end $$;

-- The CAC record of Kano Steel Ltd (as the CAC lookup stores it: names only), with Bayo, Cleo and Ada as its directors.
create function pg_temp.kano_cac(p_rc text default '5550001', p_tax text default null) returns jsonb language sql as $f$
  select jsonb_build_object('cac_id', 7701, 'profile', jsonb_build_object('approved_name', 'KANO STEEL LIMITED', 'rc_number', p_rc,
    'classification', 'COMPANY', 'tax_id', p_tax, 'directors', jsonb_build_array(
      jsonb_build_object('firstname', 'BAYO', 'surname', 'ADEWALE'), jsonb_build_object('firstname', 'CLEO', 'other_name', 'ADA', 'surname', 'NWOSU'),
      jsonb_build_object('firstname', 'ADA', 'surname', 'OWNER'))))
$f$;

-- A person's business profile draft holds a CAC record (the CAC lookup stores it).
create function pg_temp.found(p_user uuid, p_cac jsonb) returns void language plpgsql as $f$
begin
  perform tests.as_service();
  perform public.svc_kyc_store(p_user, 'cac', p_cac, null);
  perform tests.as_postgres();
end $f$;

-- The person proves who they are for their recovery, as the mono function does it: the NIN lookup's turn, then the NIN's
-- record and the directors' contacts on the CAC record. svc_recovery_identity's answer.
create function pg_temp.recovery_nin(p_user uuid, p_id uuid, p_first text, p_last text, p_phone text,
  p_cac_email text default null, p_cac_phone text default null) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  perform tests.as_user(p_user);
  r := public.recovery_nin_begin(p_id);
  perform tests.as_service();
  r := public.svc_recovery_identity(p_user, p_id, jsonb_build_object('first', p_first, 'last', p_last, 'last4', '9090', 'nin_phone', p_phone,
    'cac', jsonb_build_array(jsonb_build_object('surname', p_last, 'given', p_first, 'email', p_cac_email, 'phone', p_cac_phone))));
  perform tests.as_postgres();
  return r;
end $f$;

-- The code the messaging function would send for the recovery's check.
create function pg_temp.recovery_code(p_id uuid) returns text language plpgsql as $f$
declare v text;
begin
  perform tests.as_service();
  v := public.svc_identity_mail('identity_code', (select check_id from account_recoveries where id = p_id))->>'code';
  perform tests.as_postgres();
  return v;
end $f$;

-- A recovery started, the person's NIN matched through the NIN's phone, and the code entered: the holder's 30 minutes run.
create function pg_temp.verified_recovery(p_user uuid, p_first text, p_last text) returns uuid language plpgsql as $f$
declare v uuid; r jsonb; code text;
begin
  perform tests.as_user(p_user);
  v := (public.recovery_start()->>'id')::uuid;
  perform tests.as_postgres();
  r := pg_temp.recovery_nin(p_user, v, p_first, p_last, '08051234567', lower(p_first) || '.cac@director.example.test');
  if not coalesce((r->>'ok')::boolean, false) then raise exception 'pg_temp.verified_recovery: %', r; end if;
  code := pg_temp.recovery_code(v);
  perform tests.as_user(p_user);
  r := public.recovery_verify(v, code);
  perform tests.as_postgres();
  if not coalesce((r->>'ok')::boolean, false) then raise exception 'pg_temp.verified_recovery: %', r; end if;
  return v;
end $f$;

-- test: identity_helpers
-- Phones as Termii takes them and as pages show them, addresses cleaned and masked, Termii ready only with its key and
-- sender, the people on a CAC record who may speak for the business (a company's directors; a business name's
-- proprietors), and a name split as identity_match takes it.
do $$
begin
  assert private.sms_phone('0803 123 4567') = '2348031234567' and private.sms_phone('+234 803 123 4567') = '2348031234567'
     and private.sms_phone('2348031234567') = '2348031234567' and private.sms_phone('12345') is null and private.sms_phone(null) is null
     and private.sms_phone('0123 456 7890') is null, 'identity_helpers: sms_phone';
  assert private.mask_phone('2348031234567') = '+234 803 *** **67' and private.mask_phone(null) is null, 'identity_helpers: mask_phone';
  assert private.clean_email(' Ada@Kano.Example.Test ') = 'ada@kano.example.test' and private.clean_email('not an address') is null
     and private.clean_email(null) is null, 'identity_helpers: clean_email';
  assert private.mask_email('kelechi@gmail.com') = 'k******@g****.com', format('identity_helpers: mask_email, got %s', private.mask_email('kelechi@gmail.com'));
  assert private.sms_ready(), 'identity_helpers: Termii ready';
  update vault.secrets set secret = '' where name = 'TERMII_SENDER_ID';
  assert not private.sms_ready(), 'identity_helpers: no sender, no SMS';
  update vault.secrets set secret = 'TaxStreem' where name = 'TERMII_SENDER_ID';
  assert private.cac_people(pg_temp.kano_cac()) @> '[{"role": "director", "name": "Bayo Adewale", "surname": "ADEWALE", "given": "BAYO"}]'
     and jsonb_array_length(private.cac_people(pg_temp.kano_cac())) = 3, format('identity_helpers: directors, got %s', private.cac_people(pg_temp.kano_cac()));
  assert private.cac_people('{"profile": {"classification": "BUSINESS_NAME", "shareholders": [{"firstname": "MUSA", "surname": "BELLO"}]}}')
       @> '[{"role": "owner", "name": "Musa Bello"}]'
     and private.cac_people('{"profile": {"classification": "COMPANY", "shareholders": [{"firstname": "MUSA", "surname": "BELLO"}]}}') = '[]',
    'identity_helpers: a business name''s proprietors, not a company''s shareholders';
  assert private.name_parts('Cleo Ada Nwosu') = array['CLEO', 'ADA', 'NWOSU'] or private.name_parts('Cleo Ada Nwosu') = array['cleo', 'ada', 'nwosu'],
    format('identity_helpers: name_parts, got %s', private.name_parts('Cleo Ada Nwosu'));
  assert private.name_parts('Cleo') is null, 'identity_helpers: one word is no name';
end $$;

-- test: intake_from_cac
-- A partner or manager searches CAC from the intake (within their daily lookups), picks the company, and gets the intake's
-- fields from its record: the RC number with its registry, the Tax ID, directors, shareholders of a quarter or more as
-- beneficial owners, and the people with significant control. The record attached to the intake becomes the business's
-- profile draft when the firm sets it up under full mandate. A NIN checked from the intake keeps the name and last four
-- digits only. Staff do none of it.
do $$
declare pr uuid := tests.id('pr'); v_staff uuid; l uuid; r jsonb; i uuid; c uuid; o uuid; n int;
begin
  v_staff := tests.user('staff@fourteen.example.test', 'Femi Staff');
  perform tests.practice_member(pr, v_staff, 'staff');
  perform tests.as_user(tests.id('partner'));
  assert public.practice_lookup_take(pr, 'search'), 'intake_from_cac: a search allowed';
  perform tests.throws(format($q$select public.practice_lookup_take(%L, 'everything')$q$, pr), '%Unknown lookup%');
  perform tests.as_user(v_staff);
  perform tests.throws(format($q$select public.practice_lookup_take(%L, 'search')$q$, pr), '%partners and managers%');
  perform tests.as_service();
  perform tests.throws(format($q$select public.svc_practice_cac_search(%L, %L, 'Zaria', '[]')$q$, v_staff, pr), '%Only partners and managers%');
  r := public.svc_practice_cac_search(tests.id('partner'), pr, 'Zaria Mills',
    '[{"id": "881", "approved_name": "ZARIA MILLS LIMITED", "rc_number": "4440001"}, {"id": "882", "approved_name": "ZARIA MILLERS"}]');
  l := (r->>'lookup_id')::uuid;
  assert jsonb_array_length(r->'candidates') = 2, 'intake_from_cac: the candidates kept';
  assert public.svc_practice_cac_candidate(tests.id('partner'), l, '881')->>'approved_name' = 'ZARIA MILLS LIMITED', 'intake_from_cac: the pick';
  perform tests.throws(format($q$select public.svc_practice_cac_candidate(%L, %L, '999')$q$, tests.id('partner'), l), '%pick it from the list%');
  r := public.svc_practice_cac_record(tests.id('partner'), l,
    '{"cac_id": 881, "profile": {"approved_name": "ZARIA MILLS LIMITED", "rc_number": "4440001", "classification": "COMPANY", "address": "1 Mill Road, Zaria",
      "nature_of_business_name": "Flour milling", "active": true, "registration_date": "2011-03-04T00:00:00",
      "directors": [{"firstname": "HAUWA", "surname": "MUSA", "is_chairman": true, "nationality": "NIGERIAN"}, {"firstname": "IDRIS", "surname": "BELLO"}],
      "shareholders": [{"firstname": "HAUWA", "surname": "MUSA", "num_shares_alloted": "600"}, {"corporation_name": "MILL HOLDINGS LTD", "num_shares_alloted": "300"},
        {"firstname": "SMALL", "surname": "HOLDER", "num_shares_alloted": "100"}]},
     "psc": [{"firstname": "GARBA", "surname": "SANI"}]}',
    '{"nrs_tin": "22223333-4444", "taxpayer_name": "ZARIA MILLS LIMITED"}');
  perform tests.as_postgres();
  assert r->>'legal_name' = 'ZARIA MILLS LIMITED' and r->>'entity_type' = 'company' and r->>'rc_number' = 'RC 4440001' and r->>'tax_id' = '222233334444'
     and r->>'address' = '1 Mill Road, Zaria' and r->>'industry' = 'Flour milling' and (r->>'active')::boolean and r->>'registered_on' = '2011-03-04',
    format('intake_from_cac: the fields, got %s', r);
  assert r->'people' @> '[{"kind": "director", "name": "Hauwa Musa", "role": "Chairman", "nationality": "Nigerian"}, {"kind": "director", "name": "Idris Bello"},
      {"kind": "beneficial_owner", "name": "Mill Holdings Ltd", "ownership_pct": 30.00}, {"kind": "beneficial_owner", "name": "Garba Sani", "role": "Significant control"}]'
     and jsonb_array_length(r->'people') = 4, format('intake_from_cac: the people (Hauwa once, the small holder left out), got %s', r->'people');
  -- Attached to an intake, and the business's profile draft once the firm sets it up under full mandate.
  i := tests.cleared_intake(pr, 'Zaria Mills Ltd', 'full', 'RC 4440001');
  perform tests.as_user(v_staff);
  perform tests.throws(format('select public.practice_intake_attach_cac(%L, %L)', i, l), '%partners and managers%');
  perform tests.as_user(tests.id('partner'));
  perform public.practice_intake_attach_cac(i, l);
  r := public.practice_intake_lookups(i);
  assert r->'cac'->>'name' = 'ZARIA MILLS LIMITED' and r->'cac'->>'tax_id' = '22223333-4444' and r->'nin_checks' = '[]', format('intake_from_cac: the summary, got %s', r);
  perform public.practice_intake_declare(i, '{}');
  perform tests.as_postgres();
  perform tests.completed_letter(i);
  perform tests.as_user(tests.id('partner'));
  r := public.practice_create_business(i, '{"email": "zaria@fourteen.example.test"}');
  perform tests.as_postgres();
  o := (r->>'org_id')::uuid;
  assert (select status = 'draft' and for_business and source = 'cac' and cac->>'cac_id' = '881' and tin->>'nrs_tin' = '22223333-4444'
          from kyc_profiles where org_id = o), format('intake_from_cac: the business''s draft, got %s', r);
  -- A NIN checked from the intake.
  perform tests.as_service();
  r := public.svc_practice_intake_nin(tests.id('partner'), i, '{"first": "HAUWA", "middle": null, "last": "MUSA", "last4": "12345678"}');
  perform tests.throws(format($q$select public.svc_practice_intake_nin(%L, %L, '{"first": "HAUWA", "last4": "1"}')$q$, tests.id('partner'), i), '%full name%');
  perform tests.throws(format($q$select public.svc_practice_intake_nin(%L, %L, '{"first": "A", "last": "B", "last4": "1234"}')$q$, v_staff, i), '%Only partners%');
  perform tests.as_postgres();
  assert r = '{"name": "Hauwa Musa", "last4": "5678"}'::jsonb, format('intake_from_cac: the NIN, got %s', r);
  assert (select count(*) = 1 and bool_and(name = 'Hauwa Musa' and last4 = '5678') from practice_intake_nin_checks where intake_id = i), 'intake_from_cac: kept';
  -- An unattached lookup goes after a month.
  update practice_cac_lookups set created_at = now() - interval '31 days' where id = l;
  n := private.practice_cac_lookups_tick();
  assert n >= 1 and not exists (select 1 from practice_cac_lookups where id = l)
     and (select cac is not null from practice_intakes where id = i), format('intake_from_cac: the lookup goes, the intake keeps the record, got %s, %s, %s', n,
       (select count(*) from practice_cac_lookups where id = l), (select cac is not null from practice_intakes where id = i));
end $$;

-- test: company_on_counta_once
-- A second business with a registration number (in its registry) or Tax ID already on Counta is refused, whichever way it
-- is written; a business name with a company's digits is another company; samples and businesses kept read-only do not
-- count.
do $$
declare x uuid; y uuid; e text;
begin
  x := tests.org(tests.id('cleo'), 'Copy Steel Ltd');
  e := tests.error_of(format($q$update orgs set rc_number = 'rc-5550001' where id = %L$q$, x));
  assert e like '%registration number (rc-5550001). A company is on Counta once.%' and e like '23505%', format('company_on_counta_once: RC, got %s', e);
  assert tests.error_of(format($q$update orgs set rc_number = '5550001' where id = %L$q$, x)) like '%A company is on Counta once%', 'company_on_counta_once: digits alone, a company';
  e := tests.error_of(format($q$update orgs set tin = '11111111-11111' where id = %L$q$, x));
  assert e like '%Tax ID (11111111-11111)%', format('company_on_counta_once: Tax ID, got %s', e);
  -- The same digits as a business name are another registry's.
  update orgs set rc_number = 'BN 5550001' where id = x;
  y := tests.org(tests.id('cleo'), 'Copy Steel Enterprises');
  assert tests.error_of(format($q$update orgs set legal_form = 'enterprise', rc_number = '5550001' where id = %L$q$, y)) like '%A company is on Counta once%',
    'company_on_counta_once: a business name''s digits under its legal form';
  assert tests.error_of(format($q$update orgs set legal_form = 'company', rc_number = '5550009' where id = %L$q$, y)) is null, 'company_on_counta_once: another number';
  -- A business name turned company with the same digits as Kano Steel: refused when the legal form changes.
  assert tests.error_of(format($q$update orgs set legal_form = 'company', rc_number = '5550001' where id = %L$q$, x)) like '%A company is on Counta once%',
    'company_on_counta_once: the legal form decides the registry';
  -- Samples, and businesses kept read-only, do not count; one coming back does.
  assert tests.error_of(format($q$update orgs set is_sample = true, rc_number = 'RC 5550001' where id = %L$q$, y)) is null, 'company_on_counta_once: a sample';
  update orgs set is_sample = false, rc_number = 'RC 5550010' where id = y;
  update orgs set read_only_at = now(), rc_number = 'RC 5550001' where id = y;
  assert tests.error_of(format('update orgs set read_only_at = null where id = %L', y)) like '%A company is on Counta once%', 'company_on_counta_once: read-only back';
  assert (private.reg_holder('RC 5550001', null, null)).id = tests.id('kano') and (private.reg_holder(null, '1111111111111', null)).id = tests.id('kano')
     and (private.reg_holder('BN 5550001', null, null)).id = x and private.reg_holder('IT 5550001', null, null) is null
     and (private.reg_holder('RC 5550001', null, tests.id('kano'))).id is null, 'company_on_counta_once: reg_holder';
  delete from orgs where id in (x, y);
end $$;

-- test: profile_told_and_refused
-- Someone setting up a company already on Counta is told on their profile (the business, the holder's address masked,
-- whether it is theirs) and kyc_submit refuses it with the same; no business is made. The owner setting it up again is
-- told it is theirs.
do $$
declare v_ans jsonb := '{"offering": "goods", "category": "food", "revenue_band": "0_50m", "receive_methods": ["bank_transfer"], "pay_methods": ["bank_transfer"], "reasons": ["tax_compliance"], "examples": ["steel"], "filing": {"vat": "always", "wht": "never", "cit": "always"}}';
  r jsonb; n bigint; v_ada text := private.mask_email('ada.owner@kano.example.test');
begin
  perform pg_temp.found(tests.id('bayo'), pg_temp.kano_cac());
  n := (select count(*) from orgs);
  perform tests.as_user(tests.id('bayo'));
  r := public.kyc_draft();
  assert r->'taken' = jsonb_build_object('name', 'Kano Steel Ltd', 'masked_email', v_ada, 'yours', false, 'recovery_id', null),
    format('profile_told_and_refused: told, got %s', r->'taken');
  r := public.kyc_submit(jsonb_build_object('answers', v_ans));
  perform tests.as_postgres();
  assert r = jsonb_build_object('ok', false, 'reason', 'exists', 'business', 'Kano Steel Ltd', 'masked_email', v_ada, 'yours', false),
    format('profile_told_and_refused: refused, got %s', r);
  assert (select count(*) from orgs) = n and (select status = 'draft' from kyc_profiles where user_id = tests.id('bayo') and not for_business),
    format('profile_told_and_refused: nothing made, got %s orgs (were %s), %s', (select count(*) from orgs), n,
      (select jsonb_agg(jsonb_build_object('status', status, 'org', org_id)) from kyc_profiles where user_id = tests.id('bayo')));
  -- By Tax ID too.
  perform pg_temp.found(tests.id('eze'), pg_temp.kano_cac('5559999', '11111111-11111'));
  perform tests.as_user(tests.id('eze'));
  assert public.kyc_draft()->'taken'->>'name' = 'Kano Steel Ltd', 'profile_told_and_refused: by Tax ID';
  -- The owner herself.
  perform pg_temp.found(tests.id('ada'), pg_temp.kano_cac());
  perform tests.as_user(tests.id('ada'));
  assert (public.kyc_draft()->'taken'->>'yours')::boolean, 'profile_told_and_refused: hers';
  assert (public.kyc_submit(jsonb_build_object('answers', v_ans))->>'yours')::boolean, 'profile_told_and_refused: hers, refused';
  -- Another company: nothing said.
  perform tests.as_postgres();
  perform pg_temp.found(tests.id('cleo'), pg_temp.kano_cac('5550077'));
  perform tests.as_user(tests.id('cleo'));
  assert public.kyc_draft()->'taken' = 'null', 'profile_told_and_refused: not on Counta';
  perform tests.as_postgres();
  delete from kyc_profiles where user_id in (tests.id('ada'), tests.id('eze'), tests.id('cleo')) and status = 'draft';
end $$;

-- test: recovery_start_refused
-- A recovery starts from the person's profile draft holding the company's CAC record: not for a company not on Counta, not
-- for one the person already runs, not by Tax ID alone (the directors are matched on the record of the registration
-- number), and not without signing in.
do $$
begin
  perform pg_temp.found(tests.id('cleo'), pg_temp.kano_cac('5550077'));
  perform tests.as_user(tests.id('cleo'));
  perform tests.throws('select public.recovery_start()', '%not on Counta yet%');
  perform tests.as_postgres();
  perform pg_temp.found(tests.id('cleo'), pg_temp.kano_cac('5559999', '1111111111111'));
  perform tests.as_user(tests.id('cleo'));
  perform tests.throws('select public.recovery_start()', '%CAC record of its registration number%');
  perform tests.as_postgres();
  perform pg_temp.found(tests.id('ada'), pg_temp.kano_cac());
  perform tests.as_user(tests.id('ada'));
  perform tests.throws('select public.recovery_start()', '%You run this business on Counta already%');
  perform tests.as_user(tests.id('eze'));
  perform tests.throws('select public.recovery_start()', '%Find the business on CAC first%');
  perform tests.as_anon();
  perform tests.throws('select public.recovery_start()', '%permission denied%');
  perform tests.as_postgres();
  delete from kyc_profiles where user_id in (tests.id('ada'), tests.id('cleo'), tests.id('eze')) and status = 'draft';
  assert not exists (select 1 from account_recoveries), 'recovery_start_refused: none started';
end $$;

-- test: recovery_flow
-- Bayo recovers Kano Steel: his NIN matches a director on the record, the code goes to the NIN's phone and his CAC email
-- (from Counta, not a firm), a wrong code is counted, the right one gives Ada 30 minutes (she is emailed and told in the
-- app) and pauses payments. She hands it over: Bayo gets a link, takes it signed in with his own login, and becomes the
-- owner; Ada's place ends, Sola's stays, the identity stands verified by the recovery, and Ada is emailed.
do $$
declare o uuid := tests.id('kano'); v uuid; r jsonb; k public.identity_checks; code text; tok text; v_old bigint; rec public.account_recoveries;
  v_ada text := private.mask_email('ada.owner@kano.example.test'); v_bayo_cac text := private.mask_email('bayo.cac@director.example.test');
  v_bayo text := private.mask_email('bayo@director.example.test');
begin
  perform tests.as_user(tests.id('bayo'));
  r := public.recovery_start();
  v := (r->>'id')::uuid;
  assert r->>'status' = 'started' and r->>'step' = 'nin' and r->>'business' = 'Kano Steel Ltd'
     and r->>'holder_email' = v_ada and (r->>'support_open')::boolean, format('recovery_flow: started, got %s', r);
  assert (public.recovery_start()->>'id')::uuid = v and public.kyc_draft()->'taken'->>'recovery_id' = v::text, 'recovery_flow: the same recovery';
  r := public.recovery_nin_begin(v);
  assert r = '{"cac_id": "7701", "classification": "COMPANY", "tries_left": 2}'::jsonb, format('recovery_flow: the NIN lookup''s turn, got %s', r);
  perform tests.as_user(tests.id('cleo'));
  perform tests.throws(format('select public.recovery_get(%L)', v), '%Recovery not found%');
  perform tests.throws(format('select public.recovery_nin_begin(%L)', v), '%Recovery not found%');
  perform tests.as_service();
  r := public.svc_recovery_identity(tests.id('bayo'), v, '{"first": "TUNDE", "last": "BELLO", "last4": "1111", "nin_phone": "08051234567"}');
  assert r = '{"ok": false, "reason": "no_match"}'::jsonb, format('recovery_flow: not a director, got %s', r);
  perform tests.as_postgres();
  v_old := (select coalesce(max(id), 0) from net._requests);
  r := pg_temp.recovery_nin(tests.id('bayo'), v, 'BAYO', 'ADEWALE', '0805 123 4567', 'Bayo.CAC@director.example.test', '08059998888');
  assert (r->>'ok')::boolean and r->>'step' = 'code' and r->>'route' = 'code' and r->>'sms' = '+234 805 *** **67'
     and r->>'email' = v_bayo_cac and r->>'matched_name' = 'Bayo Adewale', format('recovery_flow: matched, got %s', r);
  select * into k from identity_checks where ref_id = v and status = 'open';
  assert k.purpose = 'recovery' and k.org_id = o and k.sms_to = '2348051234567' and k.email_to = 'bayo.cac@director.example.test' and k.nin_last4 = '9090',
    format('recovery_flow: the check, got %s', to_jsonb(k));
  assert exists (select 1 from net._requests where id > v_old and body->>'action' = 'identity_mail' and body->>'kind' = 'identity_code' and body->>'id' = k.id::text),
    'recovery_flow: the code queued';
  perform tests.as_service();
  r := public.svc_identity_mail('identity_code', k.id);
  perform tests.as_postgres();
  code := r->>'code';
  assert r->>'to' = 'bayo.cac@director.example.test' and r->>'from_name' = 'Counta' and not (r->>'white_label')::boolean
     and r->>'subject' = 'Your Counta code to recover Kano Steel Ltd' and r->'sms'->>'to' = '2348051234567'
     and r->'sms'->>'text' = code || ' is your Counta code to recover Kano Steel Ltd. It expires in 10 minutes. Do not share it.',
    format('recovery_flow: the code email and SMS, got %s', r);
  perform tests.as_user(tests.id('bayo'));
  assert (public.recovery_code(v)->>'ok')::boolean, 'recovery_flow: the code again';
  code := pg_temp.recovery_code(v);
  perform tests.as_user(tests.id('bayo'));
  r := public.recovery_verify(v, case when code = '000000' then '111111' else '000000' end);
  assert r = '{"ok": false, "reason": "wrong_code", "tries_left": 4, "locked": false}'::jsonb, format('recovery_flow: a wrong code, got %s', r);
  perform tests.as_postgres();
  assert private.payments_open(o), 'recovery_flow: payments open while he proves who he is';
  v_old := (select coalesce(max(id), 0) from net._requests);
  perform tests.as_user(tests.id('bayo'));
  r := public.recovery_verify(v, code);
  perform tests.as_postgres();
  select * into rec from account_recoveries where id = v;
  assert (r->>'ok')::boolean and r->>'status' = 'verified' and not (r->>'support_open')::boolean
     and rec.handover_due between now() + interval '29 minutes' and now() + interval '31 minutes' and rec.owner_told_at is not null,
    format('recovery_flow: verified, got %s', r);
  assert (select status = 'verified' and sms_to is null and email_to is null from identity_checks where id = k.id), 'recovery_flow: where the code went is wiped';
  assert exists (select 1 from net._requests where id > v_old and body->>'action' = 'identity_mail' and body->>'kind' = 'recovery_owner' and body->>'id' = v::text)
     and exists (select 1 from notifications where user_id = tests.id('ada') and kind = 'security' and title = 'A director asked to take over Kano Steel Ltd')
     and exists (select 1 from activity_log where org_id = o and action = 'recovery_verified'), 'recovery_flow: Ada told';
  perform tests.as_service();
  r := public.svc_identity_mail('recovery_owner', v);
  perform tests.as_postgres();
  assert r->'to' = '["ada.owner@kano.example.test"]' and r->>'subject' = 'A director asked to take over Kano Steel Ltd on Counta'
     and (r->'lines')::text like '%Bayo Adewale proved with their NIN%' and (r->'lines')::text like '%within 30 minutes%' and r->>'link' like '%/settings#ownership',
    format('recovery_flow: the email to Ada, got %s', r);
  -- Payments paused.
  assert not private.payments_open(o) and tests.error_of(format('select private.require_payments_open(%L)', o)) like '%Payments are paused%',
    'recovery_flow: payments paused';
  -- Ada sees it; Sola and Bayo do not answer for the business.
  perform tests.as_user(tests.id('ada'));
  r := public.recovery_for_org(o);
  assert r->>'id' = v::text and r->'claimant' = jsonb_build_object('name', 'Bayo Adewale', 'email', v_bayo)
     and r->>'matched_name' = 'Bayo Adewale', format('recovery_flow: Ada sees it, got %s', r);
  perform tests.as_user(tests.id('sola'));
  perform tests.throws(format('select public.recovery_for_org(%L)', o), '%Only the owner%');
  perform tests.throws(format('select public.recovery_handover_start(%L)', v), '%Only the owner%');
  perform tests.as_user(tests.id('bayo'));
  perform tests.throws(format('select public.recovery_handover_start(%L)', v), '%Only the owner%');
  -- Ada hands it over.
  perform tests.as_postgres();
  v_old := (select coalesce(max(id), 0) from net._requests);
  perform tests.as_user(tests.id('ada'));
  r := public.recovery_handover_start(v);
  perform tests.as_postgres();
  assert r->>'status' = 'handover_sent' and exists (select 1 from net._requests where id > v_old and body->>'kind' = 'recovery_handover' and body->>'id' = v::text)
     and exists (select 1 from notifications where user_id = tests.id('bayo') and title = 'The business is ready for you'), 'recovery_flow: handed over';
  perform tests.as_service();
  r := public.svc_identity_mail('recovery_handover', v);
  perform tests.as_postgres();
  tok := substring(r->>'link' from 'rh_[0-9a-f]{48}$');
  assert r->>'to' = 'bayo@director.example.test' and r->>'link' like '%/recover/accept/rh_%' and tok is not null
     and (select token_hash = private.sha256_hex(tok) and token_expires > now() + interval '6 days' from account_recoveries where id = v),
    format('recovery_flow: the link, got %s', r);
  assert not private.payments_open(o), 'recovery_flow: still paused';
  perform tests.as_user(tests.id('cleo'));
  perform tests.throws(format('select public.recovery_accept(%L)', tok), '%for the person who asked%');
  perform tests.throws($q$select public.recovery_accept('rh_nonsense')$q$, '%not valid%');
  perform tests.as_postgres();
  update auth.users set email_confirmed_at = null where id = tests.id('bayo');
  perform tests.as_user(tests.id('bayo'));
  perform tests.throws(format('select public.recovery_accept(%L)', tok), '%Confirm your email address first%');
  perform tests.as_postgres();
  update auth.users set email_confirmed_at = now() where id = tests.id('bayo');
  v_old := (select coalesce(max(id), 0) from net._requests);
  perform tests.as_user(tests.id('bayo'));
  r := public.recovery_accept(tok);
  perform tests.as_postgres();
  assert (r->>'org_id')::uuid = o and r->'recovery'->>'status' = 'completed', format('recovery_flow: taken, got %s', r);
  assert (select role = 'owner' and status = 'active' and title = 'Owner' and p_make_payments from members where org_id = o and user_id = tests.id('bayo'))
     and (select role = 'staff' and status = 'disabled' and title = 'Former owner' and not p_make_payments and not p_manage_team
          from members where org_id = o and user_id = tests.id('ada'))
     and (select status = 'active' from members where id = tests.id('sola_seat')), 'recovery_flow: the places';
  assert (select identity_status = 'verified' and identity->>'method' = 'recovery' and identity->>'matched' = 'Bayo Adewale' and identity->>'last4' = '9090'
          from orgs where id = o), 'recovery_flow: identity by the recovery';
  select * into rec from account_recoveries where id = v;
  assert rec.status = 'completed' and rec.token_hash is null and rec.previous->'emails' = '["ada.owner@kano.example.test"]'
     and rec.previous->'owners'->0->>'name' = 'Ada Owner', format('recovery_flow: recorded, got %s', to_jsonb(rec));
  assert not exists (select 1 from kyc_profiles where user_id = tests.id('bayo') and status = 'draft' and not for_business)
     and (select org_id = o from guide_progress where user_id = tests.id('bayo')), 'recovery_flow: his draft done with';
  assert exists (select 1 from net._requests where id > v_old and body->>'kind' = 'recovery_done' and body->>'id' = v::text)
     and exists (select 1 from activity_log where org_id = o and action = 'recovered'), 'recovery_flow: Ada emailed, logged';
  perform tests.as_service();
  r := public.svc_identity_mail('recovery_done', v);
  assert r->'to' = '["ada.owner@kano.example.test"]' and (r->'lines')::text like '%Your place in it has ended%', format('recovery_flow: the email to Ada, got %s', r);
  assert public.svc_identity_mail('recovery_handover', v) is null and public.svc_identity_mail('recovery_owner', v) is null, 'recovery_flow: nothing more to send';
  perform tests.as_postgres();
  assert private.payments_open(o), 'recovery_flow: payments open again';
  perform tests.as_user(tests.id('bayo'));
  perform tests.throws(format('select public.recovery_accept(%L)', tok), '%not valid%');
  perform tests.as_user(tests.id('ada'));
  perform tests.throws(format('select public.recovery_for_org(%L)', o), '%Only the owner%');
  perform tests.as_postgres();
end $$;

-- test: recovery_dispute_and_support
-- Dayo says no to Cleo's recovery of Benin Glass (with a reason): TaxStreem decides and payments stay paused. Cleo asks
-- support (once while it is open); the request reaches the support address. Only TaxStreem's admins hand a business over,
-- with a note.
do $$
declare o uuid := tests.id('benin'); v uuid; r jsonb; s uuid; v_old bigint;
begin
  perform pg_temp.found(tests.id('cleo'), jsonb_build_object('cac_id', 7702, 'profile', jsonb_build_object('approved_name', 'BENIN GLASS LIMITED',
    'rc_number', '5550002', 'classification', 'COMPANY', 'directors', '[{"firstname": "CLEO", "surname": "NWOSU"}]'::jsonb)));
  v := pg_temp.verified_recovery(tests.id('cleo'), 'CLEO', 'NWOSU');
  v_old := (select coalesce(max(id), 0) from net._requests);
  perform tests.as_user(tests.id('dayo'));
  perform tests.throws(format($q$select public.recovery_dispute(%L, 'No')$q$, v), '%at least 10 characters%');
  r := public.recovery_dispute(v, 'Cleo resigned as a director last year.');
  perform tests.as_postgres();
  s := (select id from support_cases where recovery_id = v and kind = 'recovery_dispute');
  assert r->>'status' = 'disputed' and s is not null and exists (select 1 from net._requests where id > v_old and body->>'kind' = 'support_case' and body->>'id' = s::text)
     and exists (select 1 from notifications where user_id = tests.id('cleo') and title = 'The holder of the business said no'), 'recovery_dispute_and_support: disputed';
  assert not private.payments_open(o), 'recovery_dispute_and_support: payments stay paused';
  perform tests.as_user(tests.id('dayo'));
  perform tests.throws(format('select public.recovery_handover_start(%L)', v), '%not waiting for a handover%');
  perform tests.as_user(tests.id('cleo'));
  r := public.recovery_get(v);
  assert r->>'status' = 'disputed' and r->>'dispute_reason' = 'Cleo resigned as a director last year.' and (r->>'support_open')::boolean
     and r->'support' = 'null', format('recovery_dispute_and_support: Cleo sees it (the holder''s request is not hers), got %s', r);
  perform tests.throws($q$select public.support_request('{"kind": "recovery_waiting"}')$q$, '%Choose the recovery%');
  perform tests.throws($q$select public.support_request('{"kind": "other", "message": "help"}')$q$, '%at least 10 characters%');
  perform tests.throws($q$select public.support_request('{"kind": "refund"}')$q$, '%Choose what the request is about%');
  r := public.support_request(jsonb_build_object('kind', 'recovery_waiting', 'recovery_id', v, 'message', 'I am a director; please check my request.'));
  assert r->>'status' = 'open' and public.recovery_get(v)->'support'->>'kind' = 'recovery_waiting', 'recovery_dispute_and_support: asked';
  perform tests.throws(format($q$select public.support_request(%L)$q$, jsonb_build_object('kind', 'recovery_no_access', 'recovery_id', v)), '%has your request about this already%');
  perform tests.as_user(tests.id('eze'));
  perform tests.throws(format($q$select public.support_request(%L)$q$, jsonb_build_object('kind', 'recovery_waiting', 'recovery_id', v)), '%Recovery not found%');
  perform tests.as_service();
  r := public.svc_identity_mail('support_case', s);
  assert r->>'to' = 'admin@taxstreem.com' and r->>'reply_to' = 'dayo.owner@benin.example.test' and r->>'subject' like 'Support request: a recovery was disputed (Benin Glass Ltd)%'
     and (r->'lines')::text like '%Cleo resigned%', format('recovery_dispute_and_support: to support, got %s', r);
  perform tests.as_postgres();
  insert into vault.secrets (name, secret) values ('SUPPORT_EMAIL', ' Help@TaxStreem.example.test ');
  perform tests.as_service();
  assert public.svc_identity_mail('support_case', s)->>'to' = 'help@taxstreem.example.test', 'recovery_dispute_and_support: the support address set';
  perform tests.as_postgres();
  -- TaxStreem's side.
  perform tests.as_user(tests.id('reviewer1'), 'aal2');
  r := public.admin_recoveries();
  assert exists (select 1 from jsonb_array_elements(r->'recoveries') x where x->>'id' = v::text and x->>'status' = 'disputed'
                 and x->'holder_emails' = '["dayo.owner@benin.example.test"]' and x->>'claimant_email' = 'cleo@director.example.test'
                 and x->'code_went'->>'route' = 'code')
     and (select count(*) from jsonb_array_elements(r->'cases') x where x->>'recovery_id' = v::text) = 2, format('recovery_dispute_and_support: the portal, got %s', r);
  perform tests.throws(format($q$select public.admin_recovery_decide(%L, 'transfer', 'Checked with CAC')$q$, v), '%admin%');
  perform tests.as_user(tests.id('admin1'), 'aal2');
  perform tests.throws(format($q$select public.admin_recovery_decide(%L, 'transfer', 'ok')$q$, v), '%note of at least 5%');
  perform tests.throws(format($q$select public.admin_recovery_decide(%L, 'approve', 'Checked with CAC')$q$, v), '%waiting for TaxStreem%');
  r := public.admin_recovery_decide(v, 'transfer', 'CAC confirms Cleo is still a director.');
  perform tests.as_postgres();
  assert r->>'status' = 'completed' and (select role = 'owner' and status = 'active' from members where org_id = o and user_id = tests.id('cleo'))
     and (select status = 'disabled' from members where org_id = o and user_id = tests.id('dayo')), format('recovery_dispute_and_support: handed over by TaxStreem, got %s', r);
  assert not exists (select 1 from support_cases where recovery_id = v and status = 'open')
     and exists (select 1 from admin_audit where action = 'recovery_transfer' and target = v::text and user_id = tests.id('admin1'))
     and (select decided_by = tests.id('admin1') and decision_note = 'CAC confirms Cleo is still a director.' from account_recoveries where id = v),
    'recovery_dispute_and_support: recorded, cases closed';
  assert private.payments_open(o), 'recovery_dispute_and_support: payments open';
  s := (select id from support_cases where user_id = tests.id('cleo') order by created_at desc limit 1);
  perform tests.as_user(tests.id('admin1'), 'aal2');
  perform tests.throws(format($q$select public.admin_support_close(%L, 'Done already')$q$, s), '%closed already%');
  perform tests.as_postgres();
  -- Another request, closed with a note.
  insert into support_cases (kind, user_id, message, contact_email) values ('other', tests.id('eze'), 'I cannot sign in to my old business.', 'eze@director.example.test')
  returning id into s;
  perform tests.as_user(tests.id('reviewer1'), 'aal2');
  perform tests.throws(format($q$select public.admin_support_close(%L, 'ok')$q$, s), '%at least 5%');
  assert public.admin_support_close(s, 'Replied by email.')->>'status' = 'closed', 'recovery_dispute_and_support: closed';
  perform tests.as_postgres();
  assert (select closed_by = tests.id('reviewer1') and close_note = 'Replied by email.' from support_cases where id = s)
     and exists (select 1 from admin_audit where action = 'support_close' and target = s::text), 'recovery_dispute_and_support: recorded';
end $$;

-- test: recovery_review_and_holder_addresses
-- Without a phone on the NIN record, the code goes to the CAC email and phone and TaxStreem checks the recovery before the
-- holder is told; a reviewer approves (then the holder's 30 minutes) or rejects (the person is told why). The code never
-- goes to an address or phone of the business's people: with no other way to reach the person, they ask support.
do $$
declare o uuid; v uuid; r jsonb; k public.identity_checks; v_old bigint; code text;
begin
  o := tests.remember('jos', tests.org(tests.id('dayo'), 'Jos Tin Ltd'));
  update orgs set rc_number = 'RC 5550003', identity_status = 'verified' where id = o;
  update members set phone = '08066665555' where org_id = o and user_id = tests.id('dayo');
  perform pg_temp.found(tests.id('eze'), jsonb_build_object('cac_id', 7703, 'profile', jsonb_build_object('approved_name', 'JOS TIN LIMITED',
    'rc_number', '5550003', 'classification', 'COMPANY', 'directors', '[{"firstname": "EZE", "surname": "OBI"}, {"firstname": "DAYO", "surname": "OWNER"}]'::jsonb)));
  perform tests.as_user(tests.id('eze'));
  v := (public.recovery_start()->>'id')::uuid;
  perform tests.as_postgres();
  -- His CAC email is Dayo's and his CAC phone a phone of the business: nothing to send a code to.
  r := pg_temp.recovery_nin(tests.id('eze'), v, 'EZE', 'OBI', null, 'Dayo.Owner@benin.example.test', '0806 666 5555');
  select * into k from identity_checks where ref_id = v order by created_at desc limit 1;
  assert (r->>'ok')::boolean and r->>'step' = 'support' and k.route = 'slip' and k.email_to is null and k.sms_to is null
     and k.skipped->>'email' = 'holder_address' and k.skipped->>'sms' = 'holder_phone', format('recovery_review: nothing to send to, got %s / %s', r, to_jsonb(k));
  assert not exists (select 1 from net._requests where body->>'action' = 'identity_mail' and body->>'id' = k.id::text), 'recovery_review: no code sent';
  -- His own CAC contacts, no phone on the NIN record: TaxStreem checks first.
  r := pg_temp.recovery_nin(tests.id('eze'), v, 'EZE', 'OBI', null, 'eze.cac@director.example.test', '08044443333');
  select * into k from identity_checks where ref_id = v and status = 'open';
  assert r->>'step' = 'code' and r->>'route' = 'review' and k.why = 'no_nin_phone' and k.sms_to = '2348044443333' and k.email_to = 'eze.cac@director.example.test',
    format('recovery_review: the CAC contacts, got %s', r);
  v_old := (select coalesce(max(id), 0) from net._requests);
  code := pg_temp.recovery_code(v);
  perform tests.as_user(tests.id('eze'));
  r := public.recovery_verify(v, code);
  perform tests.as_postgres();
  assert r->>'status' = 'review' and r->>'review_reason' = 'no_nin_phone', format('recovery_review: for TaxStreem, got %s', r);
  assert exists (select 1 from net._requests where id > v_old and body->>'kind' = 'recovery_admin' and body->>'id' = v::text)
     and not exists (select 1 from net._requests where id > v_old and body->>'kind' = 'recovery_owner'), 'recovery_review: the holder not told yet';
  assert private.payments_open(o), 'recovery_review: payments carry on while TaxStreem checks';
  perform tests.as_service();
  r := public.svc_identity_mail('recovery_admin', v);
  perform tests.as_postgres();
  assert r->'to' ? 'reviewer1@fourteen.example.test' and r->>'subject' = 'A recovery to check: Jos Tin Ltd' and r::text not like '%eze.cac%',
    format('recovery_review: the reviewers'' email, got %s', r);
  perform tests.as_user(tests.id('reviewer1'), 'aal2');
  perform tests.throws(format($q$select public.admin_recovery_decide(%L, 'maybe', 'Checked it')$q$, v), '%approve, reject or transfer%');
  r := public.admin_recovery_decide(v, 'approve', 'Called Eze on the CAC phone.');
  perform tests.as_postgres();
  assert r->>'status' = 'verified' and (select handover_due > now() from account_recoveries where id = v)
     and exists (select 1 from notifications where user_id = tests.id('dayo') and title = 'A director asked to take over Jos Tin Ltd')
     and not private.payments_open(o), 'recovery_review: approved, the holder''s 30 minutes';
  -- Rejected after all: payments open again, and Eze is told why.
  perform tests.as_user(tests.id('reviewer1'), 'aal2');
  r := public.admin_recovery_decide(v, 'reject', 'Dayo showed the board minutes removing Eze.');
  perform tests.as_postgres();
  assert r->>'status' = 'rejected' and private.payments_open(o)
     and exists (select 1 from notifications where user_id = tests.id('eze') and title = 'TaxStreem did not approve your recovery' and body like 'Dayo showed%'),
    'recovery_review: rejected';
  perform tests.as_user(tests.id('eze'));
  assert public.recovery_get(v)->>'decision_note' = 'Dayo showed the board minutes removing Eze.', 'recovery_review: he sees why';
  perform tests.as_postgres();
end $$;

-- test: recovery_one_at_a_time
-- One recovery holds a business at a time: a second director who proves who they are while another's waits goes to
-- TaxStreem, which cannot approve it until the first is settled. A recovery stopped by its director opens payments again.
-- Three recoveries and three NIN checks a day.
do $$
declare o uuid := tests.id('jos'); v1 uuid; v2 uuid; r jsonb; i int; code text;
begin
  perform pg_temp.found(tests.id('bayo'), jsonb_build_object('cac_id', 7703, 'profile', jsonb_build_object('approved_name', 'JOS TIN LIMITED',
    'rc_number', 'RC5550003', 'classification', 'COMPANY', 'directors', '[{"firstname": "BAYO", "surname": "ADEWALE"}, {"firstname": "EZE", "surname": "OBI"}]'::jsonb)));
  v1 := pg_temp.verified_recovery(tests.id('bayo'), 'BAYO', 'ADEWALE');
  assert not private.payments_open(o), 'recovery_one_at_a_time: paused';
  perform pg_temp.found(tests.id('eze'), jsonb_build_object('cac_id', 7703, 'profile', jsonb_build_object('approved_name', 'JOS TIN LIMITED',
    'rc_number', '5550003', 'classification', 'COMPANY', 'directors', '[{"firstname": "EZE", "surname": "OBI"}]'::jsonb)));
  perform tests.as_user(tests.id('eze'));
  v2 := (public.recovery_start()->>'id')::uuid;
  perform tests.as_postgres();
  perform pg_temp.recovery_nin(tests.id('eze'), v2, 'EZE', 'OBI', '08051234567', 'eze.cac@director.example.test');
  code := pg_temp.recovery_code(v2);
  perform tests.as_user(tests.id('eze'));
  r := public.recovery_verify(v2, code);
  perform tests.as_postgres();
  assert r->>'status' = 'review' and r->>'review_reason' = 'another_recovery', format('recovery_one_at_a_time: the second waits, got %s', r);
  perform tests.as_user(tests.id('admin1'), 'aal2');
  perform tests.throws(format($q$select public.admin_recovery_decide(%L, 'approve', 'Checked it')$q$, v2), '%Decide that one first%');
  -- Bayo stops his.
  perform tests.as_user(tests.id('bayo'));
  r := public.recovery_cancel(v1);
  perform tests.throws(format('select public.recovery_cancel(%L)', v1), '%closed already%');
  perform tests.as_postgres();
  assert r->>'status' = 'cancelled' and private.payments_open(o) and exists (select 1 from activity_log where org_id = o and action = 'recovery_cancelled'),
    'recovery_one_at_a_time: cancelled';
  perform tests.as_user(tests.id('admin1'), 'aal2');
  assert public.admin_recovery_decide(v2, 'approve', 'Checked it by phone.')->>'status' = 'verified', 'recovery_one_at_a_time: now the second';
  perform tests.as_user(tests.id('eze'));
  perform public.recovery_cancel(v2);
  -- Three NIN checks a day.
  perform tests.as_postgres();
  perform pg_temp.found(tests.id('cleo'), jsonb_build_object('cac_id', 7703, 'profile', jsonb_build_object('approved_name', 'JOS TIN LIMITED',
    'rc_number', '5550003', 'classification', 'COMPANY', 'directors', '[{"firstname": "CLEO", "surname": "NWOSU"}]'::jsonb)));
  perform tests.as_postgres();
  perform tests.as_user(tests.id('cleo'));
  v1 := (public.recovery_start()->>'id')::uuid;
  for i in 1..3 loop perform public.recovery_nin_begin(v1); end loop;
  perform tests.throws(format('select public.recovery_nin_begin(%L)', v1), '%three NIN checks today%');
  perform public.recovery_cancel(v1);
  -- Three recoveries a day.
  v2 := (public.recovery_start()->>'id')::uuid;
  perform public.recovery_cancel(v2);
  perform tests.throws('select public.recovery_start()', '%three recoveries today%');
  perform tests.as_postgres();
end $$;

-- test: recovery_from_a_firm
-- A business a firm runs under full mandate: the firm is the holder (its engagement partner and office are emailed, its
-- leads told in the practice). Handed over, the business leaves the firm: the link ends, the firm's places are switched
-- off, and the director owns it.
do $$
declare pr uuid := tests.id('pr'); c uuid; o uuid; v uuid; r jsonb; tok text; code text;
begin
  c := tests.full_client(pr, tests.id('partner'), 'Lokoja Foods Ltd', 'RC 5550005');
  o := (select org_id from practice_clients where id = c);
  update orgs set identity_status = 'verified', director_confirmed_at = now() where id = o;
  assert private.holder_emails(o) = array['bisi.partner@fourteen.example.test', 'office@fourteen.example.test'], format('recovery_from_a_firm: holder, got %s', private.holder_emails(o));
  perform pg_temp.found(tests.id('eze'), jsonb_build_object('cac_id', 7705, 'profile', jsonb_build_object('approved_name', 'LOKOJA FOODS LIMITED',
    'rc_number', '5550005', 'classification', 'COMPANY', 'directors', '[{"firstname": "EZE", "surname": "OBI"}]'::jsonb)));
  -- The firm's office address on the CAC record is no proof.
  perform tests.as_user(tests.id('eze'));
  v := (public.recovery_start()->>'id')::uuid;
  perform tests.as_postgres();
  r := pg_temp.recovery_nin(tests.id('eze'), v, 'EZE', 'OBI', '08051234567', 'Office@Fourteen.example.test');
  assert r->>'email' is null and (select skipped->>'email' = 'holder_address' from identity_checks where ref_id = v and status = 'open'),
    format('recovery_from_a_firm: never the firm''s address, got %s', r);
  code := pg_temp.recovery_code(v);
  perform tests.as_user(tests.id('eze'));
  r := public.recovery_verify(v, code);
  perform tests.as_postgres();
  assert r->>'status' = 'verified' and exists (select 1 from notifications where user_id = tests.id('partner') and kind = 'practice'
                                               and title = 'A director asked to take over Lokoja Foods Ltd'), 'recovery_from_a_firm: the firm told';
  perform tests.as_service();
  r := public.svc_identity_mail('recovery_owner', v);
  perform tests.as_postgres();
  assert r->'to' = '["bisi.partner@fourteen.example.test", "office@fourteen.example.test"]' and r->>'link' like '%/practice/clients', 'recovery_from_a_firm: the firm emailed';
  perform tests.as_user(tests.id('partner'));
  assert public.recovery_for_org(o)->>'id' = v::text, 'recovery_from_a_firm: the partner sees it';
  perform public.recovery_handover_start(v);
  perform tests.as_service();
  tok := substring(public.svc_identity_mail('recovery_handover', v)->>'link' from 'rh_[0-9a-f]{48}$');
  perform tests.as_user(tests.id('eze'));
  r := public.recovery_accept(tok);
  perform tests.as_postgres();
  assert (select managed_by is null from orgs where id = o) and (select status = 'ended' and end_kind = 'handover' from practice_clients where id = c)
     and not exists (select 1 from members where org_id = o and practice_id = pr and status <> 'disabled')
     and (select role = 'owner' and status = 'active' from members where org_id = o and user_id = tests.id('eze')), 'recovery_from_a_firm: the business is his';
  assert exists (select 1 from notifications where user_id = tests.id('partner') and kind = 'practice' and title = 'Lokoja Foods Ltd was taken over by its director')
     and private.payments_open(o), 'recovery_from_a_firm: the firm told, money open';
end $$;

-- test: recovery_grants
-- The person's and the holder's functions are for signed-in people; the service's for the functions alone; the helpers
-- for nobody else.
do $$
begin
  perform tests.as_user(tests.id('cleo'));
  perform tests.throws(format($q$select public.svc_recovery_identity(%L, gen_random_uuid(), '{}')$q$, tests.id('cleo')), '%permission denied%');
  perform tests.throws($q$select public.svc_identity_mail('identity_code', gen_random_uuid())$q$, '%permission denied%');
  perform tests.throws($q$select private.recovery_transfer(gen_random_uuid(), null)$q$, '%permission denied%');
  perform tests.throws('select private.holder_emails(gen_random_uuid())', '%permission denied%');
  perform tests.throws('select public.admin_recoveries()', '%only for TaxStreem%');
  perform tests.as_anon();
  perform tests.throws($q$select public.support_request('{}')$q$, '%permission denied%');
  perform tests.throws($q$select public.recovery_accept('x')$q$, '%permission denied%');
  perform tests.as_postgres();
  assert not has_table_privilege('authenticated', 'public.account_recoveries', 'select')
     and not has_table_privilege('authenticated', 'public.support_cases', 'select')
     and not has_table_privilege('anon', 'public.identity_checks', 'select'), 'recovery_grants: tables';
end $$;

rollback;
