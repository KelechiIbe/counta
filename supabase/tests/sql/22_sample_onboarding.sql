-- Setting up a business never makes the sample business that business (20261203000100_sample_onboarding.sql): the sample is
-- refused by every profile function, a draft already tied to it sets up a business of its own, and the repair gives the
-- sample back and the profile back as a draft. Only fake people (example.test addresses).
begin;

-- Fixture: Kel has opened the sample business; Remi built one too, untouched, to compare with.
do $$
begin
  perform tests.hooks_on();
  perform tests.remember('kel', tests.user('kel.owner@partners.example.test', 'Kel Owner'));
  perform tests.remember('remi', tests.user('remi.owner@shop.example.test', 'Remi Owner'));
  perform tests.as_user(tests.id('kel'));
  perform tests.remember('sample', public.create_sample_business());
  perform tests.as_user(tests.id('remi'));
  perform tests.remember('fresh', public.create_sample_business());
  perform tests.as_postgres();
end $$;

-- The CAC record of Kelan Partners, a business name, as the CAC lookup stores it.
create function pg_temp.kelan_cac(p_rc text) returns jsonb language sql as $f$
  select jsonb_build_object('cac_id', p_rc::int, 'profile', jsonb_build_object('approved_name', 'KELAN PARTNERS', 'rc_number', p_rc,
    'classification', 'BUSINESS_NAME', 'business_address', '3 Test Street, Gbagada, Lagos', 'state', 'LAGOS',
    'registration_date', '2021-10-05', 'directors', jsonb_build_array(jsonb_build_object('firstname', 'KEL', 'surname', 'OWNER'))))
$f$;

create function pg_temp.answers() returns jsonb language sql as $f$
  select '{"offering": "services", "category": "professional", "revenue_band": "0_50m", "receive_methods": ["bank_transfer"],
    "pay_methods": ["bank_transfer"], "reasons": ["tax_compliance"], "examples": ["legal"], "filing": {"vat": "never", "wht": "never", "cit": "never"}}'::jsonb
$f$;

-- The organisation as it compares across two samples: everything but its own ids, times and tokens.
create function pg_temp.org_shape(p_org uuid) returns jsonb language sql as $f$
  select to_jsonb(o) - array['id', 'created_at', 'updated_at', 'created_by', 'invoice_portal_token'] from orgs o where o.id = p_org
$f$;

-- test: sample_refused
-- Every way into a business profile refuses the sample: Martina's load, an answer, a CAC record stored for it, a submit.
do $$
begin
  perform tests.as_user(tests.id('kel'));
  perform tests.throws(format('select public.kyc_draft(%L)', tests.id('sample')), '%This is the sample business. To set up your own business, use Add a business.');
  perform tests.throws(format($q$select public.kyc_answer(jsonb_build_object('offering', 'services', 'org_id', %L))$q$, tests.id('sample')), '%This is the sample business%');
  perform tests.throws(format($q$select public.kyc_submit(jsonb_build_object('org_id', %L))$q$, tests.id('sample')), '%This is the sample business%');
  perform tests.as_service();
  perform tests.throws(format($q$select public.svc_kyc_store(%L, 'cac', '{}'::jsonb, %L)$q$, tests.id('kel'), tests.id('sample')), '%This is the sample business%');
  perform tests.as_postgres();
  assert not exists (select 1 from kyc_profiles where org_id = tests.id('sample')), 'sample_refused: no profile on the sample';
end $$;

-- test: setup_beside_sample
-- With the sample open, Martina's load is refused (her token carries on without it) and the person's own profile sets up a
-- new business; the sample keeps its name and has no registration number.
do $$
declare r jsonb; v uuid;
begin
  perform tests.as_user(tests.id('kel'));
  begin perform public.kyc_draft(tests.id('sample')); exception when others then null; end;
  perform public.kyc_draft();
  perform tests.as_service();
  perform public.svc_kyc_store(tests.id('kel'), 'cac', pg_temp.kelan_cac('3481999'), null);
  perform tests.as_user(tests.id('kel'));
  r := public.kyc_submit(jsonb_build_object('answers', pg_temp.answers()));
  v := (r->>'org_id')::uuid;
  perform tests.as_postgres();
  assert v is not null and v <> tests.id('sample'), format('setup_beside_sample: a business of its own, got %s', r);
  assert (select not is_sample and name = 'Kelan Partners' and legal_form = 'enterprise' and rc_number = '3481999' from orgs where id = v),
    format('setup_beside_sample: the new business, got %s', (select to_jsonb(o) - 'directors' from orgs o where id = v));
  assert exists (select 1 from members where org_id = v and user_id = tests.id('kel') and role = 'owner'), 'setup_beside_sample: Kel owns it';
  assert (select name = 'Kelandellen Company Limited' and rc_number is null and is_sample from orgs where id = tests.id('sample')),
    'setup_beside_sample: the sample is untouched';
  assert pg_temp.org_shape(tests.id('sample')) - 'email' - 'phone' = pg_temp.org_shape(tests.id('fresh')) - 'email' - 'phone',
    'setup_beside_sample: the sample matches a fresh one';
  -- Done: the profile is the new business's, for the next tests to start clean.
  delete from kyc_profiles where user_id = tests.id('kel');
  delete from members where org_id = v;
end $$;

-- test: draft_tied_to_sample
-- A draft tied to the sample before the fix is freed when it is next used, and submitting it sets up a business of its own.
do $$
declare r jsonb; v uuid;
begin
  insert into kyc_profiles (user_id, org_id) values (tests.id('kel'), tests.id('sample'));
  perform tests.as_service();
  perform public.svc_kyc_store(tests.id('kel'), 'cac', pg_temp.kelan_cac('3481998'), null);
  perform tests.as_user(tests.id('kel'));
  perform public.kyc_draft();
  r := public.kyc_submit(jsonb_build_object('answers', pg_temp.answers()));
  v := (r->>'org_id')::uuid;
  perform tests.as_postgres();
  assert v is not null and v <> tests.id('sample'), format('draft_tied_to_sample: a business of its own, got %s', r);
  assert (select org_id = v and status = 'submitted' from kyc_profiles where user_id = tests.id('kel')), 'draft_tied_to_sample: the profile is the new business''s';
  assert (select name = 'Kelandellen Company Limited' from orgs where id = tests.id('sample')), 'draft_tied_to_sample: the sample kept its name';
  delete from kyc_profiles where user_id = tests.id('kel');
  delete from members where org_id = v;
end $$;

-- test: repair
-- A profile submitted to the sample (as before the fix): the repair gives the sample back as the builder made it and the
-- profile back as a draft, CAC record, answers and Tax ID check kept, the document in the sample's folder let go. Submitting
-- again sets up the business, its registration number no longer held by the sample.
do $$
declare v_id uuid; r jsonb; v uuid; n int;
begin
  insert into kyc_profiles (user_id, org_id, status, submitted_at, source, cac, answers, tin, doc)
  values (tests.id('kel'), tests.id('sample'), 'submitted', now(), 'cac', pg_temp.kelan_cac('3481997'), pg_temp.answers(),
    '{"nrs_tin": "2522594119999", "source": "cac"}'::jsonb,
    jsonb_build_object('path', tests.id('sample')::text || '/kyc/certificate.pdf', 'kind', 'certificate', 'file_name', 'certificate.pdf'))
  returning id into v_id;
  -- What the old submit and the Tax ID check wrote on the sample.
  update orgs set name = 'Kelan Partners', phone = '08031112222', rc_number = '3481997', tin = '2522594119999', legal_form = 'enterprise',
    address = '3 Test Street, Gbagada, Lagos', registered_office = '3 TEST STREET', incorporation_date = '2021-10-05', commenced_on = '2021-10-05',
    principal_activity = 'Professional services', directors = '[{"name": "Kel Owner", "appointed": "2021-10-05"}]', industry = 'other',
    offering = 'services', category_id = 'professional', tin_check = '{"source": "onboarding"}', tin_checked_at = now(), tin_status = 'verified'
  where id = tests.id('sample');
  update locations set state = 'Lagos' where org_id = tests.id('sample') and is_main;

  n := private.sample_profiles_repair();
  assert n = 1, format('repair: one profile, got %s', n);
  assert pg_temp.org_shape(tests.id('sample')) - 'email' = pg_temp.org_shape(tests.id('fresh')) - 'email',
    format('repair: the sample as the builder makes it; differs in %s', (select jsonb_object_agg(key, value) from jsonb_each(pg_temp.org_shape(tests.id('sample')))
      where value is distinct from pg_temp.org_shape(tests.id('fresh'))->key and key <> 'email'));
  assert not exists (select 1 from locations where org_id = tests.id('sample') and (state is not null or lga is not null)), 'repair: branch states cleared';
  assert (select status = 'draft' and org_id is null and submitted_at is null and doc is null and cac is not null and tin is not null
            and answers = pg_temp.answers() from kyc_profiles where id = v_id), 'repair: the profile is a draft again, its findings kept';
  assert private.sample_profiles_repair() = 0, 'repair: runs once';

  perform tests.as_user(tests.id('kel'));
  r := public.kyc_submit('{}'::jsonb);
  v := (r->>'org_id')::uuid;
  perform tests.as_postgres();
  assert v is not null and v <> tests.id('sample'), format('repair: submitting again sets up a business, got %s', r);
  assert (select not is_sample and name = 'Kelan Partners' and rc_number = '3481997' and tin = '2522594119999' from orgs where id = v),
    'repair: the business has its numbers';
end $$;

rollback;
