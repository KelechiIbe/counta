-- Full mandate I: the gate (a partner with a verified licence, a firm TaxStreem lets run full mandates, a risk-rated and
-- cleared intake, a signed full-mandate letter, the partner's declaration of written authority); the business the firm sets
-- up (no owner, identity pending, billed to the practice, refused when the company is already on Counta); the director's
-- one confirmation (a director on the CAC record, a dc_ link, their NIN matched to that director, and a code to the NIN's
-- phone and their CAC email, held for TaxStreem when NIMC has no phone for the NIN or there is no way to send a code);
-- money locked until then and while TaxStreem lets the firm run full mandates. Also: no partner-programme referral for a business the practice pays for itself, a business profile per
-- business the firm runs, and the firm's places outside the plan's limit on people. Edge-function calls are only recorded
-- in net._requests.
begin;

-- Fixture: a verified practice (partner Bisi, an unverified partner Kunle, a manager, a staff member on a free-mail domain
-- the mandates setting adds), another practice, two TaxStreem admins and a reviewer; one business set up under full
-- mandate (Ikenna Textiles Ltd); hooks on.
do $$
declare v_partner uuid; v_partner2 uuid; v_manager uuid; v_ada uuid; v_other uuid; v_pr uuid;
begin
  v_partner := tests.remember('partner', tests.user('partner@firm.example.test', 'Bisi Partner'));
  v_partner2 := tests.remember('partner2', tests.user('kunle.partner@firm.example.test', 'Kunle Partner'));
  v_manager := tests.remember('manager', tests.user('tola.manager@firm.example.test', 'Tola Manager'));
  v_ada := tests.remember('ada', tests.user('ada@freemail.example.test', 'Ada Staff'));
  v_other := tests.remember('other_partner', tests.user('kemi.other@other.example.test', 'Kemi Other'));
  perform tests.remember('owner', tests.user('dupe.owner@client.example.test', 'Dupe Owner'));
  v_pr := tests.remember('pr', tests.practice(v_partner, 'Mandate Partners', true));
  update practices set email = 'office@firm.example.test' where id = v_pr;
  perform tests.remember('partner_pm', (select id from practice_members where practice_id = v_pr and user_id = v_partner));
  perform tests.remember('partner2_pm', tests.practice_member(v_pr, v_partner2, 'partner'));
  perform tests.remember('manager_pm', tests.practice_member(v_pr, v_manager, 'manager'));
  perform tests.remember('ada_pm', tests.practice_member(v_pr, v_ada, 'staff'));
  -- Bisi is the practice's first partner (in one transaction everyone would join at the same moment).
  update practice_members set created_at = created_at + interval '1 minute' where practice_id = v_pr and user_id <> v_partner;
  perform tests.remember('pr2', tests.practice(v_other, 'Other Partners', true));
  perform tests.remember('admin1', tests.admin_user('admin1@example.test'));
  perform tests.remember('admin2', tests.admin_user('admin2@example.test'));
  perform tests.remember('reviewer1', tests.user('reviewer1@example.test'));
  insert into platform_reviewers (user_id) values (tests.id('reviewer1'));
  insert into platform_settings (key, value) values ('mandates', '{"free_mail_domains": [" FreeMail.example.test "]}');
  perform tests.hooks_on();
  -- Termii is set up, so a code can go by SMS.
  insert into vault.secrets (name, secret) values ('TERMII_API_KEY', 'test-termii-key'), ('TERMII_SENDER_ID', 'TaxStreem');
  perform tests.remember('c', tests.full_client(v_pr, v_partner, 'Ikenna Textiles Ltd'));
  perform tests.remember('o', (select org_id from practice_clients where id = tests.id('c')));
end $$;

-- The business's identity checked against a CAC record with two directors (Tunde Bello; Amina Bola Yusuf), in the
-- business's own profile (as kyc_row makes it for a business the firm runs).
create function pg_temp.verify_identity(p_org uuid) returns void language sql as $f$
  insert into kyc_profiles (user_id, org_id, status, source, cac, submitted_at, for_business)
  values (tests.id('partner'), p_org, 'submitted', 'cac', '{"cac_id": 4242, "profile": {"classification": "COMPANY", "directors": [{"firstname": "TUNDE", "surname": "BELLO"}, {"firstname": "AMINA", "other_name": "BOLA", "surname": "YUSUF"}]}}', now(), true);
  update orgs set identity_status = 'verified' where id = p_org;
$f$;

-- The partner asks a director to confirm; returns the confirmation's id.
create function pg_temp.director_request(p_client uuid, p_name text default 'Tunde Bello', p_email text default 'tunde.bello@director.example.test')
returns uuid language plpgsql as $f$
declare v uuid;
begin
  perform tests.as_user(tests.id('partner'));
  v := (public.practice_director_request(p_client, jsonb_build_object('name', p_name, 'email', p_email))->>'id')::uuid;
  perform tests.as_postgres();
  return v;
end $f$;

-- The link the messaging function would email (svc_practice_mail mints it), as its dc_ token.
create function pg_temp.director_link(p_dc uuid) returns text language plpgsql as $f$
declare v text;
begin
  perform tests.as_service();
  v := substring(public.svc_practice_mail('director_confirm', p_dc)->>'link' from 'dc_[0-9a-f]{48}$');
  perform tests.as_postgres();
  return v;
end $f$;

-- The director proves who they are, as the practice function does it: the NIN lookup's turn, then the NIN's record (Tunde
-- Bello, with the phone NIMC holds, or none) and the directors' contacts as CAC holds them. svc_director_identity's answer.
create function pg_temp.director_nin(p_token text, p_phone text default '08031234567', p_cac_email text default 'tunde.cac@director.example.test',
  p_cac_phone text default '08039876543', p_first text default 'TUNDE', p_last text default 'BELLO') returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  perform tests.as_service();
  r := public.svc_director_nin_begin(p_token, '203.0.113.1', 'Test browser');
  if coalesce((r->>'ok')::boolean, false) then
    r := public.svc_director_identity(p_token, jsonb_build_object('first', p_first, 'last', p_last, 'last4', '4321', 'nin_phone', p_phone,
      'cac', jsonb_build_array(jsonb_build_object('surname', 'BELLO', 'given', 'TUNDE', 'email', p_cac_email, 'phone', p_cac_phone),
        jsonb_build_object('surname', 'YUSUF', 'given', 'AMINA BOLA', 'email', 'amina.cac@director.example.test', 'phone', '08021112222'))),
      '203.0.113.1', 'Test browser');
  end if;
  perform tests.as_postgres();
  return r;
end $f$;

-- The code the messaging function would send for the confirmation's check (each ask mints a new one).
create function pg_temp.check_code(p_dc uuid) returns text language plpgsql as $f$
declare v text;
begin
  perform tests.as_service();
  v := public.svc_identity_mail('identity_code', (select check_id from practice_director_confirmations where id = p_dc))->>'code';
  perform tests.as_postgres();
  return v;
end $f$;

-- The director proves who they are through the NIN's phone, and the code sent.
create function pg_temp.director_code(p_token text, p_dc uuid) returns text language plpgsql as $f$
declare r jsonb;
begin
  r := pg_temp.director_nin(p_token);
  if not coalesce((r->>'ok')::boolean, false) then raise exception 'pg_temp.director_code: no code: %', r; end if;
  return pg_temp.check_code(p_dc);
end $f$;

-- test: mandate_gate_conditions
-- Each condition on its own: a fresh full-mandate intake has none of the intake's; then risk, an RC number, the check, the
-- declaration and the signed letter open it, for a partner whose own licence is verified, while TaxStreem lets the firm
-- run full mandates.
do $$
declare pr uuid := tests.id('pr'); i uuid; g jsonb;
begin
  perform tests.as_user(tests.id('partner'));
  i := (public.practice_intake_save(pr, '{"legal_name":"Gate Check Ltd","mode_requested":"full"}')->>'id')::uuid;
  perform tests.as_definer(tests.id('partner'));
  g := private.mandate_gate(i);
  assert g = '{"partner_verified": true, "practice_can_full": true, "risk_rated": false, "rc_or_tax_id": false, "conflicts_cleared": false, "letter_completed": false, "authority_declared": false, "ok": false}'::jsonb,
    format('mandate_gate_conditions: blocked, got %s', g);
  perform tests.as_user(tests.id('partner'));
  perform public.practice_intake_save(pr, jsonb_build_object('id', i, 'risk_rating', 'low', 'risk_reason', 'Test client'));
  g := public.practice_mandate_gate(i);
  assert (g->>'risk_rated')::boolean and not (g->>'rc_or_tax_id')::boolean and not (g->>'conflicts_cleared')::boolean,
    'mandate_gate_conditions: risk rated, no number, not checked';
  perform public.practice_intake_save(pr, jsonb_build_object('id', i, 'rc_number', 'RC 3030301'));
  assert (public.practice_mandate_gate(i)->>'rc_or_tax_id')::boolean, 'mandate_gate_conditions: an RC number';
  perform public.practice_conflict_run(i);
  assert (public.practice_mandate_gate(i)->>'conflicts_cleared')::boolean, 'mandate_gate_conditions: cleared';
  perform tests.throws(format($q$select public.practice_create_business(%L, '{"email":"books@firm.example.test"}')$q$, i),
    'P0001: Full mandate needs: letter_completed, authority_declared');
  perform public.practice_intake_declare(i, '{}');
  assert not (public.practice_mandate_gate(i)->>'ok')::boolean and (public.practice_mandate_gate(i)->>'authority_declared')::boolean,
    'mandate_gate_conditions: declared, no letter yet';
  perform tests.as_postgres();
  perform tests.completed_letter(i);
  perform tests.as_definer(tests.id('partner'));
  assert (private.mandate_gate(i)->>'ok')::boolean, 'mandate_gate_conditions: open';
  -- The personal licence: another partner whose own licence is not verified, and a manager.
  perform tests.as_definer(tests.id('partner2'));
  g := private.mandate_gate(i);
  assert not (g->>'partner_verified')::boolean and (g->>'practice_can_full')::boolean and not (g->>'ok')::boolean,
    'mandate_gate_conditions: personal licence';
  perform tests.as_user(tests.id('partner2'));
  perform tests.throws(format($q$select public.practice_create_business(%L, '{"email":"books@firm.example.test"}')$q$, i),
    'P0001: Full mandate needs: partner_verified');
  perform tests.as_user(tests.id('manager'));
  assert not (public.practice_mandate_gate(i)->>'partner_verified')::boolean, 'mandate_gate_conditions: a manager is not a partner';
  perform tests.as_user(tests.id('ada'));
  perform tests.throws(format('select public.practice_mandate_gate(%L)', i), '%partners and managers%');
  perform tests.as_user(tests.id('other_partner'));
  perform tests.throws(format('select public.practice_mandate_gate(%L)', i), '%not on this practice%');
  -- TaxStreem's kill switch.
  perform tests.as_postgres();
  update practices set mandate_suspended_at = now() where id = pr;
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_create_business(%L, '{"email":"books@firm.example.test"}')$q$, i),
    'P0001: Full mandate needs: practice_can_full');
  perform tests.as_postgres();
  update practices set mandate_suspended_at = null where id = pr;
  perform tests.remember('gi', i);
end $$;

-- test: mandate_gate_letter_and_intake
-- The letter that opens the gate is a full-mandate one, for this intake, signed by the client or uploaded signed, and fixed
-- by the firm after the intake last changed its name, numbers or people; the declaration stands only for the name and mode
-- it was made for; and the company is named by a number.
do $$
declare pr uuid := tests.id('pr'); ia uuid; ib uuid; ic uuid; inn uuid; l uuid; g jsonb;
begin
  ia := tests.cleared_intake(pr, 'Kebbi Salt Ltd', 'full', 'RC 4040401');
  ib := tests.cleared_intake(pr, 'Yobe Gum Ltd', 'full', 'RC 4040403');
  ic := tests.cleared_intake(pr, 'Kwara Shea Ltd', 'full', 'RC 4040404');
  inn := tests.cleared_intake(pr, 'Bauchi Tin Ltd', 'full');
  perform tests.as_user(tests.id('partner'));
  perform public.practice_intake_declare(ia, '{}');
  perform public.practice_intake_declare(ib, '{}');
  perform public.practice_intake_declare(ic, '{}');
  perform public.practice_intake_declare(inn, '{}');
  -- An involved-mandate letter, signed and uploaded, keeps the gate shut.
  l := (public.practice_letter_draft(ia, '{"variant":"involved"}')->>'id')::uuid;
  perform public.practice_letter_upload_signed(l, jsonb_build_object('path', 'practice/' || pr || '/letters/' || l || '/signed.pdf', 'sha256', repeat('ef', 32)));
  g := public.practice_mandate_gate(ia);
  assert not (g->>'letter_completed')::boolean and not (g->>'ok')::boolean and (g->>'authority_declared')::boolean,
    'mandate_gate_letter_and_intake: an involved letter does not count';
  -- A full-mandate letter uploaded signed opens it.
  l := (public.practice_letter_draft(ia, '{}')->>'id')::uuid;
  perform public.practice_letter_upload_signed(l, jsonb_build_object('path', 'practice/' || pr || '/letters/' || l || '/signed.pdf', 'sha256', repeat('ef', 32)));
  assert (public.practice_mandate_gate(ia)->>'ok')::boolean, 'mandate_gate_letter_and_intake: an uploaded full letter opens it';
  -- Another intake's full letter does not.
  assert not (public.practice_mandate_gate(ib)->>'letter_completed')::boolean, 'mandate_gate_letter_and_intake: not another intake''s letter';
  -- The intake changes its RC number after the letter was fixed (a minute later), and is checked again: the letter no
  -- longer describes it.
  perform public.practice_intake_save(pr, jsonb_build_object('id', ia, 'rc_number', 'RC 4040402'));
  perform tests.as_postgres();
  update practice_intakes set edited_at = edited_at + interval '1 minute' where id = ia;
  perform tests.as_user(tests.id('partner'));
  perform public.practice_conflict_run(ia);
  perform tests.as_postgres();
  update practice_intakes set checked_at = edited_at + interval '1 second' where id = ia;
  perform tests.as_user(tests.id('partner'));
  g := public.practice_mandate_gate(ia);
  assert not (g->>'letter_completed')::boolean and (g->>'conflicts_cleared')::boolean and (g->>'authority_declared')::boolean
     and (g->>'rc_or_tax_id')::boolean, format('mandate_gate_letter_and_intake: a letter for the intake as it was, got %s', g);
  perform tests.throws(format($q$select public.practice_create_business(%L, '{"email":"books@firm.example.test"}')$q$, ia),
    'P0001: Full mandate needs: letter_completed');
  -- A new name, or a new mode, withdraws the declaration.
  perform public.practice_intake_save(pr, jsonb_build_object('id', ib, 'legal_name', 'Yobe Gum Exports Ltd'));
  assert not (public.practice_mandate_gate(ib)->>'authority_declared')::boolean, 'mandate_gate_letter_and_intake: a new name';
  perform public.practice_intake_save(pr, jsonb_build_object('id', ic, 'mode_requested', 'involved'));
  g := public.practice_mandate_gate(ic);
  assert not (g->>'authority_declared')::boolean and not (g->>'ok')::boolean, 'mandate_gate_letter_and_intake: a new mode';
  -- No RC, BN or IT number and no Tax ID: the company cannot be told apart from one already on Counta.
  perform tests.as_postgres();
  perform tests.completed_letter(inn);
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_create_business(%L, '{"email":"books@firm.example.test"}')$q$, inn),
    'P0001: Full mandate needs: rc_or_tax_id');
  perform tests.as_postgres();
end $$;

-- test: create_business_full
-- The business the firm sets up: its name from the intake, the email the firm chooses, the client's bank details for
-- invoices, run by the practice with identity pending (payments shut); a full, active client link billed to the practice
-- on the intake, the caller the engagement partner, kept as long as the letter says; no owner, the firm's partners and
-- managers acting as the owner; logged.
do $$
declare pr uuid := tests.id('pr'); i uuid := tests.id('gi'); r jsonb; o uuid; c uuid;
begin
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_create_business(%L, '{"phone":"08030000000"}')$q$, i), '%email address%');
  perform tests.throws(format($q$select public.practice_create_business(%L, '{"email":"books@firm.example.test","alert_email":"someone@client.example.test"}')$q$, i),
    '%address of the firm%');
  perform tests.throws(format($q$select public.practice_create_business(%L, %L)$q$, i, jsonb_build_object('email', 'books@firm.example.test', 'bank_details', repeat('x', 501))),
    '%500 characters%');
  perform tests.throws(format($q$select public.practice_create_business(%L, %L)$q$, i, jsonb_build_object('email', 'books@firm.example.test', 'engagement_partner_id', tests.id('ada_pm'))),
    '%active partners or managers%');
  r := public.practice_create_business(i, '{"email":" Books@Firm.example.test ","bank_details":"Pay to Test Bank 0123456789","alert_email":"Alerts@firm.example.test","vat_registered":false}');
  perform tests.as_postgres();
  o := (r->>'org_id')::uuid; c := (r->>'client_id')::uuid;
  assert (r->>'ok')::boolean and o is not null and c is not null, 'create_business_full: ok';
  assert (select managed_by = pr and identity_status = 'pending' and email = 'books@firm.example.test' and invoice_note like 'Pay to Test Bank%'
            and name = 'Gate Check Ltd' and not vat_registered and director_confirmed_at is null and created_by = tests.id('partner') from orgs where id = o),
    'create_business_full: org';
  assert (select mode = 'full' and billing = 'practice' and status = 'active' and initiated_by = 'practice' and intake_id = i
            and engagement_partner_id = tests.id('partner_pm') and alert_email = 'alerts@firm.example.test' and retention_years = 6 and started_at is not null
          from practice_clients where id = c), 'create_business_full: client';
  assert not exists (select 1 from members where org_id = o and role = 'owner'), 'create_business_full: no owner member';
  assert (select count(*) from members where org_id = o and status = 'active' and role = 'admin' and acts_as_owner and practice_id = pr) = 3
     and (select array_agg(user_id order by user_id) from members where org_id = o and status = 'active')
         = (select array_agg(u order by u) from unnest(array[tests.id('partner'), tests.id('partner2'), tests.id('manager')]) u),
    'create_business_full: the partners and the manager act as the owner; unassigned staff do not';
  assert (select status = 'engaged' and client_id = c and org_id = o from practice_intakes where id = i), 'create_business_full: intake engaged';
  assert exists (select 1 from activity_log where org_id = o and action = 'mandate_started' and source = 'event' and actor_user = tests.id('partner')),
    'create_business_full: logged';
  assert not private.payments_open(o), 'create_business_full: payments shut';
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_create_business(%L, '{"email":"books@firm.example.test"}')$q$, i), '%has a client already%');
  perform tests.as_postgres();
end $$;

-- test: create_business_duplicate
-- A company someone already owns on Counta, or that another practice runs, is not set up again: a plain refusal and a flag
-- for TaxStreem (once while it is open). The RC number and Tax ID are compared without prefixes and punctuation. A company
-- is on Counta once, so the same RC number on a business this practice itself runs is refused too (orgs_reg_unique), with
-- no flag.
do $$
declare pr uuid := tests.id('pr'); v_dup uuid; v_mg uuid; v_own uuid; i2 uuid; i3 uuid; i4 uuid; r jsonb; v_orgs int;
begin
  v_dup := tests.org(tests.id('owner'), 'Dupe Holdings Ltd');
  update orgs set rc_number = '7654321' where id = v_dup;
  v_mg := tests.managed_org(tests.id('pr2'), 'Other Managed Ltd');
  update orgs set tin = '12345678-0001' where id = v_mg;
  v_own := tests.managed_org(pr, 'Own Managed Ltd');
  update orgs set rc_number = 'RC 9990001' where id = v_own;

  i2 := tests.cleared_intake(pr, 'Kaduna Cement Ltd', 'full');
  update practice_intakes set rc_number = 'RC-7654321' where id = i2;
  i3 := tests.cleared_intake(pr, 'Benue Yams Ltd', 'full');
  update practice_intakes set tax_id = '1234567800 01' where id = i3;
  i4 := tests.cleared_intake(pr, 'Owerri Glass Ltd', 'full');
  update practice_intakes set rc_number = '9990001' where id = i4;
  perform tests.as_user(tests.id('partner'));
  perform public.practice_intake_declare(i2, '{}');
  perform public.practice_intake_declare(i3, '{}');
  perform public.practice_intake_declare(i4, '{}');
  perform tests.as_postgres();
  perform tests.completed_letter(i2);
  perform tests.completed_letter(i3);
  perform tests.completed_letter(i4);
  v_orgs := (select count(*) from orgs);

  perform tests.as_user(tests.id('partner'));
  r := public.practice_create_business(i2, '{"email":"b@firm.example.test"}');
  assert r = '{"ok": false, "reason": "duplicate"}'::jsonb, format('create_business_duplicate: refused, got %s', r);
  r := public.practice_create_business(i2, '{"email":"b@firm.example.test"}');
  assert r->>'reason' = 'duplicate', 'create_business_duplicate: refused again';
  r := public.practice_create_business(i3, '{"email":"b@firm.example.test"}');
  assert r->>'reason' = 'duplicate', 'create_business_duplicate: the Tax ID of a business another practice runs';
  perform tests.as_postgres();
  assert (select count(*) from practice_mandate_flags where intake_id = i2 and kind = 'duplicate_company' and resolved_at is null) = 1
     and (select detail->>'matched_on' = 'rc_number' and (detail->>'org_id')::uuid = v_dup and practice_id = pr
          from practice_mandate_flags where intake_id = i2), 'create_business_duplicate: flag kept, once';
  assert (select detail->>'matched_on' = 'tax_id' and (detail->>'org_id')::uuid = v_mg from practice_mandate_flags where intake_id = i3),
    'create_business_duplicate: Tax ID flag';
  assert (select count(*) from orgs) = v_orgs and (select status = 'draft' and client_id is null from practice_intakes where id = i2),
    'create_business_duplicate: nothing set up';
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_create_business(%L, '{"email":"b@firm.example.test"}')$q$, i4),
    '%registration number (9990001). A company is on Counta once.%');
  perform tests.as_postgres();
  assert (select count(*) from orgs) = v_orgs and not exists (select 1 from practice_mandate_flags where intake_id = i4),
    'create_business_duplicate: the practice''s own company is not set up twice, and TaxStreem is not flagged';
end $$;

-- test: director_email_free_mail_and_case
-- The director's own address may be on a free-mail domain that a firm person also uses (the mandates setting adds one);
-- a firm address, or the firm's own domain, is refused however it is typed.
do $$
declare c uuid := tests.id('c'); pr uuid := tests.id('pr');
begin
  perform pg_temp.verify_identity(tests.id('o'));
  assert private.free_mail_domains() @> '{gmail.com,yahoo.co.uk,proton.me,mail.com,freemail.example.test}', 'director_email_free_mail_and_case: free-mail domains';
  perform tests.as_user(tests.id('partner'));
  assert tests.error_of(format($q$select public.practice_director_request(%L, '{"name":"Tunde Bello","email":"tunde.bello@freemail.example.test"}')$q$, c)) is null,
    'director_email_free_mail_and_case: shared free-mail domain allowed';
  perform tests.throws(format($q$select public.practice_director_request(%L, '{"name":"Tunde Bello","email":" Ada@FreeMail.example.test "}')$q$, c), '%director''s own email%');
  perform tests.throws(format($q$select public.practice_director_request(%L, '{"name":"Tunde Bello","email":"tunde@FIRM.example.test"}')$q$, c), '%director''s own email%');
  perform tests.throws(format($q$select public.practice_director_request(%L, '{"name":"Tunde Bello","email":"OFFICE@firm.example.test"}')$q$, c), '%director''s own email%');
  perform tests.throws(format($q$select public.practice_director_request(%L, '{"name":"Tunde Bello","email":"Kunle.Partner@Firm.Example.Test"}')$q$, c), '%director''s own email%');
  perform tests.throws(format($q$select public.practice_director_request(%L, '{"name":"Tunde Bello","email":"tunde@Mail.Firm.example.test"}')$q$, c), '%director''s own email%');
  perform tests.as_postgres();
  assert private.firm_email(pr, 'x@mail.firm.example.test') = 'domain' and private.firm_email(pr, 'x@a.b.firm.example.test') = 'domain'
     and private.firm_email(pr, 'x@notfirm.example.test') is null and private.firm_email(pr, 'x@mail.freemail.example.test') is null,
    'director_email_free_mail_and_case: subdomains of the firm''s own domain, not of a free-mail one';
  assert private.firm_email(pr, ' Partner@Firm.example.test ') = 'member' and private.firm_email(pr, 'x@firm.example.test') = 'domain'
     and private.firm_email(pr, 'tunde.bello@freemail.example.test') is null, 'director_email_free_mail_and_case: firm_email';
  assert private.firm_email(pr, 'Office@Firm.Example.Test') = 'practice' and private.firm_email(pr, 'someone@gmail.com') is null
     and private.firm_email(pr, 'ada@freemail.example.test') = 'member' and private.firm_email(pr, null) is null
     and private.firm_email(pr, 'not an address') is null and private.firm_email(tests.id('pr2'), 'x@firm.example.test') is null,
    'director_email_free_mail_and_case: firm_email kinds';
  -- Without the setting, the staff member's domain would be the firm's.
  update platform_settings set value = '{}' where key = 'mandates';
  assert private.firm_email(pr, 'tunde.bello@freemail.example.test') = 'domain', 'director_email_free_mail_and_case: the setting decides';
  update platform_settings set value = '{"free_mail_domains": [" FreeMail.example.test "]}' where key = 'mandates';
end $$;

-- test: director_name_and_identity
-- The business's CAC record comes first (the director's NIN check verifies its identity); the director is named as on the
-- CAC record (accents, order and middle names aside); the email is optional; only the practice's partners and managers ask, for a business it runs under full mandate; a new request
-- replaces the one waiting, whose link stops working.
do $$
declare pr uuid := tests.id('pr'); c uuid := tests.id('c'); cp uuid; v_ord uuid; ic uuid; d1 uuid; d2 uuid; tok text; r jsonb;
begin
  cp := tests.full_client(pr, tests.id('partner'), 'Pending Shoes Ltd');
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_director_request(%L, '{"name":"Tunde Bello","email":"tunde@director.example.test"}')$q$, cp),
    '%Add the business''s CAC record first%');
  perform tests.throws(format($q$select public.practice_director_request(%L, '{"name":"Someone Else","email":"tunde@director.example.test"}')$q$, c),
    '%not a director on the CAC record%');
  perform tests.throws(format($q$select public.practice_director_request(%L, '{"name":"Bello","email":"tunde@director.example.test"}')$q$, c),
    '%not a director on the CAC record%');
  assert tests.error_of(format($q$select public.practice_director_request(%L, '{"name":"Túndé Bello","email":"tunde@director.example.test"}')$q$, c)) is null,
    'director_name_and_identity: diacritics folded';
  assert tests.error_of(format($q$select public.practice_director_request(%L, '{"name":"BELLO, Tunde","email":"tunde@director.example.test"}')$q$, c)) is null
     and tests.error_of(format($q$select public.practice_director_request(%L, '{"name":"Amina Yusuf","email":"amina@director.example.test"}')$q$, c)) is null,
    'director_name_and_identity: order and middle names';
  perform tests.throws(format($q$select public.practice_director_request(%L, '{"name":"Tunde Bello","email":"not-an-address"}')$q$, c), '%email address is not valid%');
  perform tests.as_user(tests.id('ada'));
  perform tests.throws(format($q$select public.practice_director_request(%L, '{"name":"Tunde Bello","email":"tunde@director.example.test"}')$q$, c), '%partners and managers%');
  perform tests.as_user(tests.id('other_partner'));
  perform tests.throws(format($q$select public.practice_director_request(%L, '{"name":"Tunde Bello","email":"tunde@director.example.test"}')$q$, c), '%not on this practice%');
  -- A manager of the practice with no place acting as the business's owner (not synced yet) does not read its CAC record.
  perform tests.as_postgres();
  perform tests.practice_member(pr, tests.user('new.manager@firm.example.test', 'Nkem Manager'), 'manager');
  perform tests.as_user((select id from auth.users where email = 'new.manager@firm.example.test'));
  perform tests.throws(format($q$select public.practice_director_request(%L, '{"name":"Tunde Bello","email":"tunde@director.example.test"}')$q$, c),
    '42501: Only the firm''s people acting as the business''s owner%');
  perform tests.as_postgres();
  update practice_members set status = 'disabled' where email = 'new.manager@firm.example.test';
  -- An involved client: the business's own owner deals with its money.
  v_ord := tests.org(tests.id('owner'), 'Involved Director Ltd');
  ic := tests.involved_client(pr, v_ord);
  perform pg_temp.verify_identity(v_ord);
  perform tests.as_user(tests.id('manager'));
  perform tests.throws(format($q$select public.practice_director_request(%L, '{"name":"Tunde Bello","email":"tunde@director.example.test"}')$q$, ic), '%full mandate%');
  perform tests.as_postgres();
  -- Only the latest request waits; the earlier link no longer opens.
  assert (select count(*) from practice_director_confirmations where client_id = c and status = 'pending') = 1
     and (select count(*) from practice_director_confirmations where client_id = c and status = 'cancelled' and token_hash is null) >= 2,
    'director_name_and_identity: one waiting';
  -- (Five requests a day for a business: the day starts afresh here.)
  update practice_director_confirmations set created_at = created_at - interval '2 days' where client_id = c;
  d1 := pg_temp.director_request(c);
  tok := pg_temp.director_link(d1);
  d2 := pg_temp.director_request(c, 'Amina Bola Yusuf', 'amina@director.example.test');
  assert (select status = 'cancelled' and token_hash is null from practice_director_confirmations where id = d1)
     and (select status = 'pending' and name = 'Amina Bola Yusuf' and email = 'amina@director.example.test' and requested_by = tests.id('partner_pm')
          from practice_director_confirmations where id = d2), 'director_name_and_identity: replaced';
  perform tests.as_service();
  r := public.svc_director_open(tok, '203.0.113.2', 'Test browser');
  assert r = '{"ok": false, "reason": "invalid"}'::jsonb, format('director_name_and_identity: the old link, got %s', r);
  assert public.svc_practice_mail('director_confirm', d1) is null, 'director_name_and_identity: no email for a cancelled request';
  perform tests.as_postgres();
  -- Five requests a day for a business.
  perform pg_temp.director_request(c);
  perform pg_temp.director_request(c);
  perform pg_temp.director_request(c);
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_director_request(%L, '{"name":"Tunde Bello","email":"tunde@director.example.test"}')$q$, c), '%five requests%');
  perform tests.as_postgres();
  -- (The next tests start the day afresh.)
  update practice_director_confirmations set created_at = created_at - interval '2 days' where client_id = c;
end $$;

-- test: director_confirm_flow
-- The director opens the link, proves with their NIN that they are a director on the CAC record, and enters the code that
-- went to the NIN's phone and their CAC email: a wrong code is counted and never raises; the right one confirms the
-- business's director, once. The emails go in the firm's name only and name TaxStreem and Flutterwave as the wallet
-- provider; the SMS comes from TaxStreem's sender. Counta keeps the NIN's last four digits and whom it matched, not where
-- the code went.
do $$
declare c uuid := tests.id('c'); o uuid := tests.id('o'); dc uuid; tok text; code text; r jsonb; v_old bigint; k public.identity_checks;
begin
  dc := pg_temp.director_request(c);
  assert exists (select 1 from net._requests where url = 'http://functions.test/messaging' and body->>'action' = 'practice_mail'
                 and body->>'kind' = 'director_confirm' and body->>'id' = dc::text), 'director_confirm_flow: link email queued';
  perform tests.as_service();
  r := public.svc_practice_mail('director_confirm', dc);
  perform tests.as_postgres();
  tok := substring(r->>'link' from 'dc_[0-9a-f]{48}$');
  assert r->>'link' ~ '/confirm/dc_[0-9a-f]{48}$' and r->>'to' = 'tunde.bello@director.example.test' and r->>'from_name' = 'Mandate Partners'
     and (r->>'white_label')::boolean and r->>'reply_to' = 'partner@firm.example.test' and (r->'lines')::text like '%TaxStreem through Flutterwave%'
     and (r->'lines')::text like '%NIN%' and (r - 'link')::text not ilike '%counta%', format('director_confirm_flow: the link email, got %s', r);
  assert (select token_hash = private.sha256_hex(tok) and token_expires > now() + interval '13 days' from practice_director_confirmations where id = dc),
    'director_confirm_flow: only the hash kept, 14 days';
  perform tests.as_service();
  r := public.svc_director_open(tok, '203.0.113.2', 'Test browser');
  assert r = jsonb_build_object('ok', true, 'firm_name', 'Mandate Partners', 'business_name', 'Ikenna Textiles Ltd', 'director_name', 'Tunde Bello',
      'status', 'pending', 'step', 'nin', 'route', null, 'sms', null, 'email', null),
    format('director_confirm_flow: opened, got %s', r);
  assert public.svc_director_open('dc_' || repeat('0', 48), null, null) = '{"ok": false, "reason": "invalid"}'::jsonb
     and public.svc_director_open('nonsense', null, null)->>'reason' = 'invalid', 'director_confirm_flow: unknown links';
  assert public.svc_director_confirm(tok, '123456', '198.51.100.7', 'UA')->>'reason' = 'nin_first'
     and public.svc_director_code(tok, null, null)->>'reason' = 'nin_first', 'director_confirm_flow: the NIN first';
  -- A NIN that is not a director's.
  perform tests.as_postgres();
  r := pg_temp.director_nin(tok, p_first => 'CHIDI', p_last => 'OKAFOR');
  assert r = '{"ok": false, "reason": "no_match"}'::jsonb and (select check_id is null and flags->'last_try'->>'last4' = '4321' from practice_director_confirmations where id = dc),
    format('director_confirm_flow: not a director, got %s', r);
  -- Tunde Bello's NIN: the code goes to the NIN's phone, and to his email on the CAC record.
  v_old := (select coalesce(max(id), 0) from net._requests);
  r := pg_temp.director_nin(tok);
  assert r = '{"ok": true, "step": "code", "route": "code", "sms": "+234 803 *** **67", "email": "t********@d***************.test", "matched": "Tunde Bello"}'::jsonb,
    format('director_confirm_flow: matched, got %s', r);
  select * into k from identity_checks where id = (select check_id from practice_director_confirmations where id = dc);
  assert k.purpose = 'director_confirm' and k.route = 'code' and k.sms_to = '2348031234567' and k.email_to = 'tunde.cac@director.example.test'
     and k.nin_phone and k.nin_last4 = '4321' and k.matched_role = 'director' and k.org_id = o, format('director_confirm_flow: the check, got %s', to_jsonb(k));
  assert (select count(*) from net._requests where id > v_old and body->>'action' = 'identity_mail' and body->>'kind' = 'identity_code'
          and body->>'id' = k.id::text) = 1, 'director_confirm_flow: code queued';
  perform tests.as_service();
  r := public.svc_director_open(tok, null, null);
  assert r->>'step' = 'code' and r->>'route' = 'code' and r->>'sms' = k.sms_masked and r->>'email' = k.email_masked, format('director_confirm_flow: the page, got %s', r);
  r := public.svc_identity_mail('identity_code', k.id);
  code := r->>'code';
  assert code ~ '^[0-9]{6}$' and r->>'to' = 'tunde.cac@director.example.test' and r->>'from_name' = 'Mandate Partners' and (r->>'white_label')::boolean
     and r->'sms'->>'to' = '2348031234567' and r->'sms'->>'text' like code || ' is your code to confirm the wallets for Ikenna Textiles Ltd.%'
     and r::text not ilike '%counta%', format('director_confirm_flow: the code, got %s', r);
  r := public.svc_director_confirm(tok, case when code = '000000' then '111111' else '000000' end, '198.51.100.7', 'UA');
  assert not (r->>'ok')::boolean and r->>'reason' = 'wrong_code' and (r->>'tries_left')::int = 4, 'director_confirm_flow: a wrong code';
  perform tests.as_postgres();
  assert (select otp_failures = 1 and otp_tries = 1 and status = 'open' from identity_checks where id = k.id)
     and (select status = 'pending' from practice_director_confirmations where id = dc), 'director_confirm_flow: the failure is counted';
  v_old := (select coalesce(max(id), 0) from net._requests);
  perform tests.as_service();
  r := public.svc_director_confirm(tok, code, '198.51.100.7', 'UA');
  perform tests.as_postgres();
  assert r = '{"ok": true, "status": "confirmed"}'::jsonb and (select director_confirmed_at is not null from orgs where id = o), 'director_confirm_flow';
  assert (select status = 'confirmed' and confirmed_at is not null and ip = '198.51.100.7' and ua = 'UA' and matched_name = 'Tunde Bello' and nin_last4 = '4321'
          from practice_director_confirmations where id = dc), 'director_confirm_flow: recorded';
  assert (select status = 'verified' and sms_to is null and email_to is null and otp_hash is null and wiped_at is not null from identity_checks where id = k.id),
    'director_confirm_flow: where the code went is wiped';
  assert exists (select 1 from activity_log where org_id = o and action = 'director_confirmed' and source = 'event'), 'director_confirm_flow: logged';
  assert exists (select 1 from notifications where kind = 'practice' and user_id = tests.id('partner') and title like '%Ikenna Textiles Ltd confirmed%'),
    'director_confirm_flow: the firm told';
  assert not exists (select 1 from net._requests where id > v_old and body->>'kind' = 'director_admin'), 'director_confirm_flow: nothing for TaxStreem to check';
  -- Done once.
  perform tests.as_service();
  assert public.svc_director_code(tok, null, null) = '{"ok": false, "reason": "confirmed"}'::jsonb
     and public.svc_director_open(tok, null, null)->>'status' = 'confirmed' and public.svc_identity_mail('identity_code', k.id) is null
     and public.svc_director_confirm(tok, code, '198.51.100.7', 'UA')->>'reason' = 'confirmed'
     and public.svc_director_nin_begin(tok, null, null)->>'reason' = 'confirmed', 'director_confirm_flow: once';
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_director_request(%L, '{"name":"Tunde Bello","email":"tunde@director.example.test"}')$q$, c), '%confirmed already%');
  perform tests.as_postgres();
end $$;

-- test: money_locked_until_director
-- Payments (the wallet, the tax wallet and all that needs them) stay shut until the business's identity is verified and a
-- director has confirmed, and while TaxStreem lets the firm run full mandates.
do $$
declare pr uuid := tests.id('pr'); c uuid; o uuid; v_seat uuid; dc uuid; tok text; code text;
begin
  c := tests.full_client(pr, tests.id('partner'), 'Lagoon Plastics Ltd');
  o := (select org_id from practice_clients where id = c);
  v_seat := (select id from members where org_id = o and user_id = tests.id('partner'));
  perform tests.as_service();
  perform tests.throws(format('select public.svc_wallet_to_open(%L, %L)', o, v_seat), '%confirms their NIN%');
  perform tests.as_postgres();
  perform pg_temp.verify_identity(o);
  assert not private.payments_open(o), 'money_locked_until_director: locked';
  perform tests.as_service();
  perform tests.throws(format('select public.svc_wallet_to_open(%L, %L)', o, v_seat), '%director of the business confirms%');
  perform tests.throws(format('select public.svc_tax_wallet_to_open(%L, %L)', o, v_seat), '%director of the business confirms%');
  perform tests.as_user(tests.id('partner'));
  assert not (public.get_inventory(o)->'org'->>'payments_open')::boolean and not (public.identity_state(o)->>'payments_open')::boolean
     and public.identity_state(o)->>'status' = 'verified', 'money_locked_until_director: the app is told';
  perform tests.as_user(tests.id('admin1'), 'aal2');
  assert not (public.admin_business(o)->>'payments_open')::boolean, 'money_locked_until_director: so is TaxStreem';
  perform tests.as_postgres();
  dc := pg_temp.director_request(c);
  tok := pg_temp.director_link(dc);
  code := pg_temp.director_code(tok, dc);
  perform tests.as_service();
  assert public.svc_director_confirm(tok, code, '198.51.100.17', 'UA')->>'status' = 'confirmed', 'money_locked_until_director: confirmed';
  perform tests.as_postgres();
  assert private.payments_open(o), 'money_locked_until_director: open';
  perform tests.as_user(tests.id('partner'));
  assert (public.get_inventory(o)->'org'->>'payments_open')::boolean and (public.identity_state(o)->>'payments_open')::boolean,
    'money_locked_until_director: the app is told it is open';
  perform tests.as_user(tests.id('admin1'), 'aal2');
  assert (public.admin_business(o)->>'payments_open')::boolean, 'money_locked_until_director: TaxStreem sees it open';
  -- TaxStreem's kill switch: admins only, with a reason.
  perform tests.as_user(tests.id('reviewer1'), 'aal2');
  perform tests.throws(format($q$select public.admin_practice_suspend(%L, true, 'Licence lapsed')$q$, pr), '%only for TaxStreem''s admins%');
  perform tests.as_user(tests.id('admin2'), 'aal2');
  perform tests.throws(format($q$select public.admin_practice_suspend(%L, true, 'No')$q$, pr), '%reason%');
  perform public.admin_practice_suspend(pr, true, 'Licence lapsed');
  assert not (public.admin_business(o)->>'payments_open')::boolean, 'money_locked_until_director: TaxStreem sees the kill switch';
  perform tests.as_postgres();
  assert not private.payments_open(o), 'money_locked_until_director: kill switch';
  perform tests.as_service();
  perform tests.throws(format('select public.svc_wallet_to_open(%L, %L)', o, v_seat), '%while the firm may run full mandates%');
  perform tests.as_postgres();
  assert exists (select 1 from admin_audit where action = 'mandates_suspended' and target = pr::text and user_id = tests.id('admin2'))
     and exists (select 1 from notifications where kind = 'practice' and user_id = tests.id('partner') and title like '%paused%'),
    'money_locked_until_director: recorded and the firm told';
  perform tests.as_user(tests.id('admin2'), 'aal2');
  perform public.admin_practice_suspend(pr, false, 'Licence renewed');
  perform tests.as_postgres();
  assert private.payments_open(o) and (select mandate_suspended_at is null from practices where id = pr)
     and exists (select 1 from admin_audit where action = 'mandates_resumed' and target = pr::text), 'money_locked_until_director: resumed';
  -- An ordinary business is as before.
  o := tests.org(tests.id('owner'), 'Ordinary Money Ltd');
  assert private.payments_open(o), 'money_locked_until_director: ordinary business';
end $$;

-- test: director_review
-- Without a phone on the NIN record, the code goes to the director's email and phone on the CAC record (never a firm
-- address), and the confirmation then waits for TaxStreem (a flag, and an email to its reviewers); a reviewer or admin
-- decides, with a note. With no way to send a code at all, the director uploads their NIN slip for TaxStreem. The firm
-- cannot go round the check by asking again. Three NIN lookups a day per request.
do $$
declare pr uuid := tests.id('pr'); c2 uuid; o2 uuid; dc1 uuid; dc2 uuid; tok text; code text; r jsonb; k public.identity_checks; v_path text;
begin
  c2 := tests.full_client(pr, tests.id('partner'), 'Review Ceramics Ltd');
  o2 := (select org_id from practice_clients where id = c2);
  perform pg_temp.verify_identity(o2);
  -- No phone on the NIN record.
  dc1 := pg_temp.director_request(c2);
  tok := pg_temp.director_link(dc1);
  r := pg_temp.director_nin(tok, p_phone => null);
  assert (r->>'ok')::boolean and r->>'step' = 'code' and r->>'route' = 'review', format('director_review: no NIN phone, got %s', r);
  select * into k from identity_checks where id = (select check_id from practice_director_confirmations where id = dc1);
  assert k.route = 'review' and k.why = 'no_nin_phone' and not k.nin_phone and k.sms_to = '2348039876543' and k.email_to = 'tunde.cac@director.example.test',
    format('director_review: the CAC contacts, got %s', to_jsonb(k));
  code := pg_temp.check_code(dc1);
  perform tests.as_service();
  r := public.svc_director_confirm(tok, code, '198.51.100.20', 'UA');
  perform tests.as_postgres();
  assert r = '{"ok": true, "status": "review"}'::jsonb and (select director_confirmed_at is null from orgs where id = o2), 'director_review: waits';
  assert (select status = 'review' and flags->>'review_reason' = 'no_nin_phone' from practice_director_confirmations where id = dc1), 'director_review: why';
  assert exists (select 1 from practice_mandate_flags where kind = 'director_review' and client_id = c2 and detail->>'confirmation_id' = dc1::text
                 and detail->>'reason' = 'no_nin_phone' and resolved_at is null), 'director_review: flag';
  assert exists (select 1 from net._requests where url = 'http://functions.test/messaging' and body->>'action' = 'practice_mail' and body->>'kind' = 'director_admin'
                 and body->>'id' = dc1::text), 'director_review: TaxStreem reviewers told';
  perform tests.as_service();
  r := public.svc_practice_mail('director_admin', dc1);
  assert public.svc_director_open(tok, null, null)->>'status' = 'review' and public.svc_director_code(tok, null, null)->>'reason' = 'review',
    'director_review: waiting';
  perform tests.as_postgres();
  assert r->>'subject' = 'Director confirmation to review: Review Ceramics Ltd' and r->>'link' like '%/admin/mandates' and not (r->>'white_label')::boolean
     and (r->'lines')::text like '%no phone number for the NIN%' and r::text not like '%director.example.test%', format('director_review: the email to TaxStreem, got %s', r);
  -- The firm cannot go round TaxStreem's check by asking again.
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_director_request(%L, '{"name":"Tunde Bello","email":"tunde@director.example.test"}')$q$, c2),
    '%TaxStreem is checking%');
  -- TaxStreem's reviewers see whom the NIN matched and where the code went, masked.
  perform tests.as_user(tests.id('reviewer1'), 'aal2');
  r := (select x from jsonb_array_elements(public.admin_mandates()->'reviews') x where x->>'id' = dc1::text);
  assert r->'director'->>'matched_name' = 'Tunde Bello' and r->'director'->>'nin_last4' = '4321' and r->'director'->>'sms' = k.sms_masked
     and r->'director'->>'code_email' = k.email_masked and r->>'reason' = 'no_nin_phone', format('director_review: the review, got %s', r);
  -- A reviewer declines it.
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.admin_director_decide(%L, true, 'Looks fine')$q$, dc1), '%only for TaxStreem%');
  perform tests.as_user(tests.id('reviewer1'), 'aal2');
  perform tests.throws(format($q$select public.admin_director_decide(%L, false, 'No')$q$, dc1), '%note%');
  r := public.admin_director_decide(dc1, false, 'Could not reach the director');
  assert r->>'status' = 'declined', 'director_review: declined';
  perform tests.throws(format($q$select public.admin_director_decide(%L, true, 'Changed my mind')$q$, dc1), '%waiting for review%');
  perform tests.as_postgres();
  assert (select status = 'declined' and decided_by = tests.id('reviewer1') and decided_at is not null from practice_director_confirmations where id = dc1)
     and (select director_confirmed_at is null from orgs where id = o2)
     and exists (select 1 from admin_audit where action = 'director_declined' and target = dc1::text)
     and (select resolved_at is not null and resolved_by = tests.id('reviewer1') from practice_mandate_flags where kind = 'director_review' and detail->>'confirmation_id' = dc1::text),
    'director_review: recorded, flag resolved';

  -- No phone on the NIN record, the CAC email is the firm's and no CAC phone: nothing to send a code to, so the NIN slip.
  dc2 := pg_temp.director_request(c2);
  tok := pg_temp.director_link(dc2);
  r := pg_temp.director_nin(tok, p_phone => null, p_cac_email => 'Office@Firm.example.test', p_cac_phone => null);
  assert r = '{"ok": true, "step": "slip", "route": "slip", "sms": null, "email": null, "matched": "Tunde Bello"}'::jsonb,
    format('director_review: the slip, got %s', r);
  select * into k from identity_checks where id = (select check_id from practice_director_confirmations where id = dc2);
  assert k.route = 'slip' and k.why = 'no_channel' and k.email_to is null and k.sms_to is null and k.skipped->>'email' = 'firm_address',
    format('director_review: never the firm''s address, got %s', to_jsonb(k));
  assert not exists (select 1 from net._requests where body->>'action' = 'identity_mail' and body->>'id' = k.id::text), 'director_review: no code sent';
  perform tests.as_service();
  assert public.svc_director_open(tok, null, null)->>'step' = 'slip', 'director_review: the page asks for the slip';
  assert public.svc_director_slip(tok, o2 || '/kyc/nin-slip-x.pdf', null, null)->>'reason' = 'invalid'
     and public.svc_director_slip(tok, gen_random_uuid() || '/kyc/director-slip-' || gen_random_uuid() || '.pdf', null, null)->>'reason' = 'invalid',
    'director_review: only a slip in the business''s own folder';
  assert public.svc_director_slip_target(tok, 'exe')->>'reason' = 'invalid', 'director_review: only a PDF or a picture';
  v_path := public.svc_director_slip_target(tok, 'pdf')->>'path';
  assert v_path ~ ('^' || o2 || '/kyc/director-slip-[0-9a-f-]{36}\.pdf$'), format('director_review: where the slip goes, got %s', v_path);
  r := public.svc_director_slip(tok, v_path, '198.51.100.21', 'UA');
  assert public.svc_director_slip_target(tok, 'pdf')->>'reason' = 'review', 'director_review: one slip';
  perform tests.as_postgres();
  assert r = '{"ok": true, "status": "review"}'::jsonb and (select status = 'review' and slip_path = v_path and flags->>'review_reason' = 'no_channel'
          from practice_director_confirmations where id = dc2), format('director_review: the slip sent, got %s', r);
  -- A reviewer reads the slip while the confirmation is with them.
  perform tests.as_user(tests.id('reviewer1'), 'aal2');
  assert private.reviewer_may_read(v_path) and not private.reviewer_may_read(o2 || '/kyc/director-slip-' || gen_random_uuid() || '.pdf'),
    'director_review: the reviewer reads the slip';
  perform tests.as_user(tests.id('admin1'), 'aal2');
  perform public.admin_director_decide(dc2, true, 'Checked the slip by phone');
  perform tests.as_postgres();
  assert (select director_confirmed_at is not null from orgs where id = o2), 'director_review: admin approves';
  assert (select status = 'confirmed' and confirmed_at is not null and decided_by = tests.id('admin1') from practice_director_confirmations where id = dc2)
     and exists (select 1 from admin_audit where action = 'director_confirmed' and target = dc2::text)
     and exists (select 1 from activity_log where org_id = o2 and action = 'director_confirmed'), 'director_review: recorded';
  assert private.payments_open(o2), 'director_review: money opens';

  -- Hosts as the handover compares them (practice_handover_accept still reads the firm's sign-in addresses).
  assert private.ip_host('::ffff:198.51.100.8') = '198.51.100.8'::inet and private.ip_host('198.51.100.8/24') = '198.51.100.8'::inet
     and private.ip_host('2001:db8::1/64') = '2001:db8::1'::inet and private.ip_host(null) is null, 'director_review: hosts';
end $$;

-- test: director_nin_limits
-- Three NIN lookups a Lagos day for a request, five codes a day for a check, and a request without an email: the firm gets
-- the link to send itself, and no link email goes. The identity check's contacts are wiped within the hour.
do $$
declare pr uuid := tests.id('pr'); c4 uuid; o4 uuid; dc uuid; r jsonb; tok text; k public.identity_checks; i int;
begin
  c4 := tests.full_client(pr, tests.id('partner'), 'Limits Cables Ltd');
  o4 := (select org_id from practice_clients where id = c4);
  perform pg_temp.verify_identity(o4);
  perform tests.as_user(tests.id('partner'));
  r := public.practice_director_request(c4, '{"name":"Amina Bola Yusuf"}');
  perform tests.as_postgres();
  dc := (r->>'id')::uuid;
  tok := substring(r->>'link' from 'dc_[0-9a-f]{48}$');
  assert not (r->>'sent')::boolean and r->>'email' is null and tok is not null and r->>'link' like '%/confirm/dc_%', format('director_nin_limits: the link, got %s', r);
  assert not exists (select 1 from net._requests where body->>'action' = 'practice_mail' and body->>'kind' = 'director_confirm' and body->>'id' = dc::text),
    'director_nin_limits: no link email';
  perform tests.as_service();
  assert public.svc_practice_mail('director_confirm', dc) is null, 'director_nin_limits: nothing to email';
  perform tests.as_postgres();
  -- Amina's NIN matched to her place on the record.
  r := pg_temp.director_nin(tok, p_first => 'AMINA', p_last => 'YUSUF');
  assert (r->>'ok')::boolean and r->>'matched' = 'Amina Bola Yusuf' and r->>'email' = 'a********@d***************.test', format('director_nin_limits: Amina, got %s', r);
  r := pg_temp.director_nin(tok, p_first => 'CHIDI', p_last => 'OKAFOR');
  assert r->>'reason' = 'no_match', 'director_nin_limits: a second lookup';
  r := pg_temp.director_nin(tok, p_first => 'CHIDI', p_last => 'OKAFOR');
  assert r->>'reason' = 'no_match', 'director_nin_limits: a third lookup';
  r := pg_temp.director_nin(tok);
  assert r = '{"ok": false, "reason": "too_many_nin"}'::jsonb, format('director_nin_limits: three a day, got %s', r);
  -- Five codes a day: the first went with the match.
  perform tests.as_service();
  for i in 1..4 loop
    assert (public.svc_director_code(tok, null, null)->>'ok')::boolean, format('director_nin_limits: code %s', i + 1);
  end loop;
  r := public.svc_director_code(tok, null, null);
  perform tests.as_postgres();
  assert not (r->>'ok')::boolean, format('director_nin_limits: five a day, got %s', r);
  -- The contacts go within the hour.
  select * into k from identity_checks where id = (select check_id from practice_director_confirmations where id = dc);
  update identity_checks set created_at = now() - interval '61 minutes' where id = k.id;
  perform private.identity_wipe_tick();
  assert (select status = 'expired' and sms_to is null and email_to is null and otp_hash is null and wiped_at is not null from identity_checks where id = k.id),
    'director_nin_limits: wiped';
  perform tests.as_service();
  assert public.svc_director_open(tok, null, null)->>'step' = 'nin', 'director_nin_limits: the NIN again';
  perform tests.as_postgres();
end $$;

-- test: director_decline
-- A director who declines: a flag, the firm told, and TaxStreem's reviewers emailed (with the reason, without the
-- director's contact details). The link then only says so.
do $$
declare pr uuid := tests.id('pr'); c3 uuid; o3 uuid; dc3 uuid; tok text; r jsonb;
begin
  c3 := tests.full_client(pr, tests.id('partner'), 'Decline Paints Ltd');
  o3 := (select org_id from practice_clients where id = c3);
  perform pg_temp.verify_identity(o3);
  dc3 := pg_temp.director_request(c3);
  tok := pg_temp.director_link(dc3);
  perform tests.as_service();
  r := public.svc_director_decline(tok, 'I did not agree to this', '198.51.100.9', 'UA');
  perform tests.as_postgres();
  assert r = '{"ok": true, "status": "declined"}'::jsonb, 'director_decline: answered';
  assert exists (select 1 from practice_mandate_flags where kind = 'director_declined' and client_id = c3 and detail->>'reason' = 'I did not agree to this'), 'director_decline';
  assert exists (select 1 from notifications where kind = 'practice' and user_id = tests.id('partner') and title like '%Decline Paints Ltd declined%'), 'director_decline: firm told';
  assert exists (select 1 from net._requests where url = 'http://functions.test/messaging' and body->>'action' = 'practice_mail' and body->>'kind' = 'director_admin'
                 and body->>'id' = dc3::text), 'director_decline: TaxStreem reviewers told';
  assert (select status = 'declined' and decline_reason = 'I did not agree to this' and ip = '198.51.100.9' from practice_director_confirmations where id = dc3),
    'director_decline: recorded';
  perform tests.as_service();
  r := public.svc_practice_mail('director_admin', dc3);
  perform tests.as_postgres();
  assert r->'to' = to_jsonb(public.svc_review_recipients()) and r->'to' ? 'reviewer1@example.test' and not (r->>'white_label')::boolean, 'director_decline: sent to the review recipients';
  assert r->>'from_name' = 'Counta' and r->>'subject' = 'A director declined: Decline Paints Ltd' and (r->'lines')::text like '%I did not agree to this%'
     and (r->'lines')::text like '%Mandate Partners%' and r::text not like '%director.example.test%', format('director_decline: the email, got %s', r);
  perform tests.as_service();
  assert public.svc_director_confirm(tok, '123456', '198.51.100.9', 'UA')->>'reason' = 'declined'
     and public.svc_director_decline(tok, 'again', null, null)->>'reason' = 'declined' and public.svc_director_open(tok, null, null)->>'status' = 'declined',
    'director_decline: the link only says so';
  perform tests.as_postgres();
  assert not private.payments_open(o3) and exists (select 1 from activity_log where org_id = o3 and action = 'director_declined'), 'director_decline: money shut, logged';
end $$;

-- test: full_mandate_no_referral
-- The partner programme pays a practice for the businesses it brings that pay for Counta; a practice pays for a full-mandate
-- business's plan itself, so that business starts no referral. An involved client still does.
do $$
declare pr uuid := tests.id('pr'); c uuid; v_ord uuid;
begin
  insert into platform_settings (key, value) values ('partners', '{"enabled": true}')
  on conflict (key) do update set value = platform_settings.value || '{"enabled": true}';
  c := tests.full_client(pr, tests.id('partner'), 'Ogun Timber Ltd');
  assert not exists (select 1 from partner_referrals where client_id = c or org_id = (select org_id from practice_clients where id = c)),
    'full_mandate_no_referral';
  v_ord := tests.org(tests.id('owner'), 'Referral Ordinary Ltd');
  perform tests.involved_client(pr, v_ord);
  assert exists (select 1 from partner_referrals where org_id = v_ord and practice_id = pr and status = 'waiting'), 'full_mandate_no_referral: an involved client does';
end $$;

-- test: kyc_drafts_per_business
-- Each business the firm runs has its own business profile draft, shared by the firm's people, apart from each person's
-- own: a firm person completes two such profiles one after the other, and two more side by side, without one touching
-- another.
do $$
declare pr uuid := tests.id('pr'); a uuid; b uuid; c uuid; d uuid; r jsonb;
  v_ans jsonb := '{"offering": "goods", "category": "food", "revenue_band": "0_50m", "receive_methods": ["bank_transfer"], "pay_methods": ["bank_transfer"], "reasons": ["tax_compliance"], "examples": ["flour"], "filing": {"vat": "always", "wht": "never", "cit": "always"}}';
begin
  a := tests.managed_org(pr, 'Abia Rice Ltd');
  b := tests.managed_org(pr, 'Ondo Cocoa Ltd');
  c := tests.managed_org(pr, 'Enugu Coal Ltd');
  d := tests.managed_org(pr, 'Delta Fish Ltd');
  perform tests.as_service();
  perform public.svc_kyc_store(tests.id('partner'), 'search', '{"query":"mine"}');
  -- One after the other.
  perform public.svc_kyc_store(tests.id('partner'), 'cac', '{"cac_id": 1, "profile": {"approved_name": "ABIA RICE LIMITED", "rc_number": "100001", "classification": "COMPANY", "directors": [{"firstname": "ADA", "surname": "ABIA"}]}}', a);
  perform tests.as_user(tests.id('partner'));
  perform public.kyc_answer(v_ans || jsonb_build_object('org_id', a));
  r := public.kyc_submit(jsonb_build_object('org_id', a));
  assert (r->>'org_id')::uuid = a, 'kyc_drafts_per_business: first business';
  perform tests.as_service();
  perform public.svc_kyc_store(tests.id('partner'), 'cac', '{"cac_id": 2, "profile": {"approved_name": "ONDO COCOA LIMITED", "rc_number": "100002", "classification": "COMPANY", "directors": [{"firstname": "OBI", "surname": "ONDO"}]}}', b);
  perform tests.as_user(tests.id('partner'));
  r := public.kyc_submit(jsonb_build_object('org_id', b, 'answers', v_ans));
  assert (r->>'org_id')::uuid = b, 'kyc_drafts_per_business: second business';
  -- Side by side, by the manager; the partner sees the same drafts.
  perform tests.as_service();
  perform public.svc_kyc_store(tests.id('manager'), 'cac', '{"cac_id": 3, "profile": {"approved_name": "ENUGU COAL LIMITED", "rc_number": "100003", "classification": "COMPANY", "directors": [{"firstname": "EKE", "surname": "ENUGU"}]}}', c);
  perform public.svc_kyc_store(tests.id('manager'), 'cac', '{"cac_id": 4, "profile": {"approved_name": "DELTA FISH LIMITED", "rc_number": "100004", "classification": "COMPANY", "directors": [{"firstname": "DAYO", "surname": "DELTA"}]}}', d);
  perform tests.as_user(tests.id('manager'));
  perform public.kyc_answer(v_ans || jsonb_build_object('org_id', d));
  perform public.kyc_answer(jsonb_build_object('org_id', c, 'offering', 'goods'));
  assert public.kyc_draft(c)->'business'->>'rc_number' = '100003' and public.kyc_draft(d)->'business'->>'rc_number' = '100004'
     and public.kyc_draft(c)->'answers' = '{"offering": "goods"}'::jsonb, 'kyc_drafts_per_business: each its own';
  r := public.kyc_draft(c);
  perform tests.as_user(tests.id('partner'));
  assert public.kyc_draft(c)->>'id' = r->>'id' and public.kyc_draft(c)->'answers' = '{"offering": "goods"}'::jsonb, 'kyc_drafts_per_business: shared by the firm';
  perform tests.as_user(tests.id('manager'));
  perform tests.throws(format($q$select public.kyc_submit('{"org_id":"%s"}')$q$, c), '%questions are still open%');
  r := public.kyc_submit(jsonb_build_object('org_id', d));
  r := public.kyc_submit(jsonb_build_object('org_id', c, 'answers', v_ans));
  perform tests.as_user(tests.id('ada'));
  perform tests.throws(format($q$select public.kyc_answer('{"org_id":"%s","offering":"goods"}')$q$, c), '42501:%');
  perform tests.as_postgres();
  assert (select array_agg(rc_number order by rc_number) from orgs where id in (a, b, c, d)) = '{100001,100002,100003,100004}'
     and (select count(*) from kyc_profiles where org_id in (a, b, c, d) and status = 'submitted') = 4
     and (select bool_and(identity_status = 'pending' and managed_by = pr) from orgs where id in (a, b, c, d)), 'kyc_drafts_per_business: four profiles';
  assert private.identity_people(c) @> '[{"surname": "ENUGU"}]' and private.identity_people(d) @> '[{"surname": "DELTA"}]'
     and not private.identity_people(c) @> '[{"surname": "DELTA"}]', 'kyc_drafts_per_business: each business''s own directors';
  assert (select org_id is null and search->>'query' = 'mine' and cac is null from kyc_profiles where user_id = tests.id('partner') and status = 'draft' and not for_business),
    'kyc_drafts_per_business: the personal draft untouched';
  perform tests.as_user(tests.id('partner'));
  assert public.kyc_draft(null)->'search'->>'query' = 'mine', 'kyc_drafts_per_business: the personal draft is the person''s';
  -- With no draft of their own, the person's own profile is empty: a business's submitted profile is not theirs.
  perform tests.as_postgres();
  delete from kyc_profiles where user_id = tests.id('partner') and status = 'draft' and not for_business;
  perform tests.as_user(tests.id('partner'));
  r := public.kyc_draft(null);
  assert r->>'id' is null and r->>'org_id' is null and r->>'status' = 'draft', format('kyc_drafts_per_business: no business profile as their own, got %s', r);
  perform tests.as_postgres();
end $$;

-- test: kyc_submit_same_company
-- The CAC record a firm submits for a business it runs must be the company it took on (the intake's RC number, compared as
-- the conflicts check compares numbers) and not a company that is someone else's on Counta (by RC number or Tax ID): then
-- nothing is submitted and TaxStreem is flagged, once. The company's numbers are the transaction's while it submits.
do $$
declare pr uuid := tests.id('pr'); cx uuid; ox uuid; cy uuid; oy uuid; v_own uuid; r jsonb;
  v_ans jsonb := '{"offering": "goods", "category": "food", "revenue_band": "0_50m", "receive_methods": ["bank_transfer"], "pay_methods": ["bank_transfer"], "reasons": ["tax_compliance"], "examples": ["flour"], "filing": {"vat": "always", "wht": "never", "cit": "always"}}';
begin
  cx := tests.full_client(pr, tests.id('partner'), 'Sokoto Hides Ltd', 'RC 6060601');
  ox := (select org_id from practice_clients where id = cx);
  cy := tests.full_client(pr, tests.id('partner'), 'Taraba Honey Ltd', 'RC 6060602');
  oy := (select org_id from practice_clients where id = cy);
  -- A different company's record.
  perform tests.as_service();
  perform public.svc_kyc_store(tests.id('partner'), 'cac', '{"cac_id": 11, "profile": {"approved_name": "OTHER HIDES LIMITED", "rc_number": "6060699", "classification": "COMPANY", "directors": [{"firstname": "ABU", "surname": "SOKOTO"}]}}', ox);
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.kyc_submit(%L)$q$, jsonb_build_object('org_id', ox, 'answers', v_ans)), '%took this business on as RC 6060601%');
  -- The right company, which someone else has since set up on Counta.
  perform tests.as_postgres();
  v_own := tests.org(tests.id('owner'), 'Sokoto Hides Owner Ltd');
  -- (Two businesses with one number can only be left from before orgs_reg_unique: made here with it off.)
  alter table public.orgs disable trigger orgs_reg_unique;
  update orgs set rc_number = '6060601' where id = v_own;
  alter table public.orgs enable trigger orgs_reg_unique;
  perform tests.as_service();
  perform public.svc_kyc_store(tests.id('partner'), 'cac', '{"cac_id": 12, "profile": {"approved_name": "SOKOTO HIDES LIMITED", "rc_number": "6060601", "classification": "COMPANY", "directors": [{"firstname": "ABU", "surname": "SOKOTO"}]}}', ox);
  perform tests.as_user(tests.id('partner'));
  r := public.kyc_submit(jsonb_build_object('org_id', ox, 'answers', v_ans));
  assert r = '{"ok": false, "reason": "duplicate"}'::jsonb, format('kyc_submit_same_company: refused, got %s', r);
  assert exists (select 1 from pg_locks where locktype = 'advisory' and pid = pg_backend_pid()
                 and ((classid::bigint << 32) | objid::bigint) = hashtextextended('company:rc:6060601', 0)), 'kyc_submit_same_company: the RC number''s turn taken';
  r := public.kyc_submit(jsonb_build_object('org_id', ox));
  perform tests.as_postgres();
  assert r->>'reason' = 'duplicate' and (select count(*) from practice_mandate_flags where client_id = cx and kind = 'duplicate_company' and resolved_at is null) = 1
     and (select detail->>'matched_on' = 'rc_number' and (detail->>'org_id')::uuid = v_own and detail->>'source' = 'cac' and practice_id = pr
          from practice_mandate_flags where client_id = cx and kind = 'duplicate_company'), 'kyc_submit_same_company: flagged once';
  assert (select status = 'draft' from kyc_profiles where org_id = ox) and (select name = 'Sokoto Hides Ltd' and rc_number = 'RC 6060601' from orgs where id = ox),
    'kyc_submit_same_company: nothing submitted';
  -- By Tax ID.
  alter table public.orgs disable trigger orgs_reg_unique;
  update orgs set tin = '1234567890123' where id = v_own;
  alter table public.orgs enable trigger orgs_reg_unique;
  perform tests.as_service();
  perform public.svc_kyc_store(tests.id('partner'), 'cac', '{"cac_id": 13, "profile": {"approved_name": "TARABA HONEY LIMITED", "rc_number": "RC6060602", "tax_id": "12345678-90123", "classification": "COMPANY", "directors": [{"firstname": "TANI", "surname": "TARABA"}]}}', oy);
  perform tests.as_user(tests.id('partner'));
  r := public.kyc_submit(jsonb_build_object('org_id', oy, 'answers', v_ans));
  perform tests.as_postgres();
  assert r->>'reason' = 'duplicate' and (select detail->>'matched_on' = 'tax_id' from practice_mandate_flags where client_id = cy and kind = 'duplicate_company'),
    'kyc_submit_same_company: by Tax ID';
  -- Nobody else's any more: the same RC number, written differently, is submitted.
  update orgs set rc_number = null where id = v_own;
  perform tests.as_user(tests.id('partner'));
  r := public.kyc_submit(jsonb_build_object('org_id', ox));
  perform tests.as_postgres();
  assert (r->>'org_id')::uuid = ox and (select rc_number = '6060601' and name = 'Sokoto Hides Limited' from orgs where id = ox)
     and (select status = 'submitted' from kyc_profiles where org_id = ox), 'kyc_submit_same_company: the company the firm took on';
end $$;

-- test: full_client_defaults
-- tests.full_client with only the practice and the partner, twice: two businesses with names and RC numbers of their own.
do $$
declare c1 uuid; c2 uuid;
begin
  c1 := tests.full_client(tests.id('pr'), tests.id('partner'));
  c2 := tests.full_client(tests.id('pr'), tests.id('partner'));
  assert c1 <> c2 and (select count(distinct o.rc_number) = 2 and count(distinct o.name) = 2 and bool_and(o.rc_number is not null)
                       from practice_clients c join orgs o on o.id = c.org_id where c.id in (c1, c2)), 'full_client_defaults';
end $$;

-- test: firm_seats_free_of_plan_limit
-- The practice pays for a full-mandate business's plan, and its people's places there are the practice's: they use none of
-- the plan's places, while an ordinary business at its limit takes no one more.
do $$
declare pr uuid := tests.id('pr'); c uuid; o uuid; v_ord uuid; v_u uuid;
begin
  insert into plan_entitlements (plan_id, module_key, included, quota, enforce) values (private.default_plan_id(), 'users', true, 1, 'block');
  v_ord := tests.org(tests.id('owner'), 'Limit Ordinary Ltd');
  v_u := tests.user('limit.staff@client.example.test');
  perform tests.throws(format('select tests.member(%L, %L, %L)', v_ord, v_u, 'staff'), '%Your plan%');
  c := tests.full_client(pr, tests.id('partner'), 'Kano Leather Ltd');
  o := (select org_id from practice_clients where id = c);
  assert (select count(*) from members where org_id = o and status = 'active' and acts_as_owner) = 3, 'firm_seats_free_of_plan_limit: three places';
  assert private.meter_usage(o, 'users') = 0 and private.meter_usage(v_ord, 'users') = 1, 'firm_seats_free_of_plan_limit: not counted';
  perform tests.as_user(tests.id('partner'));
  perform public.practice_assign(c, tests.id('ada_pm'), true);
  perform tests.as_postgres();
  assert exists (select 1 from members where org_id = o and user_id = tests.id('ada') and status = 'active'), 'firm_seats_free_of_plan_limit: an assigned person too';
  delete from plan_entitlements where plan_id = private.default_plan_id() and module_key = 'users';
end $$;

-- test: mandate_helpers_revoked
do $$
declare f text;
begin
  foreach f in array array['private.mandate_gate(uuid)', 'private.free_mail_domains()', 'private.firm_email(uuid, text)',
    'private.director_by_token(text)', 'private.director_state(practice_director_confirmations)', 'private.director_mandate_open(uuid, uuid)',
    'private.payments_open(uuid)', 'private.require_payments_open(uuid)', 'private.partner_referral_start(practice_clients)', 'private.kyc_row(uuid, uuid)',
    'private.enforce_plan()', 'private.meter_usage(uuid, text)'] loop
    assert not has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute'), format('mandate_helpers_revoked: %s', f);
  end loop;
  foreach f in array array['public.svc_director_open(text, text, text)', 'public.svc_director_code(text, text, text)',
    'public.svc_director_confirm(text, text, text, text)', 'public.svc_director_decline(text, text, text, text)', 'public.svc_practice_mail(text, uuid)'] loop
    assert not has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute')
       and has_function_privilege('service_role', f, 'execute'), format('mandate_helpers_revoked: %s for the service only', f);
  end loop;
  foreach f in array array['public.practice_mandate_gate(uuid)', 'public.practice_create_business(uuid, jsonb)', 'public.practice_director_request(uuid, jsonb)',
    'public.admin_director_decide(uuid, boolean, text)', 'public.admin_practice_suspend(uuid, boolean, text)'] loop
    assert has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute'), format('mandate_helpers_revoked: %s for signed-in people', f);
  end loop;
  foreach f in array array['public.practice_director_confirmations', 'public.practice_mandate_flags'] loop
    assert not has_table_privilege('authenticated', f, 'select') and not has_table_privilege('anon', f, 'select')
       and not has_table_privilege('authenticated', f, 'insert') and not has_table_privilege('authenticated', f, 'update')
       and (select relrowsecurity from pg_class where oid = f::regclass), format('mandate_helpers_revoked: table %s', f);
  end loop;
end $$;

rollback;
