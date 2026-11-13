-- The fixes found in review and the three product rules of part 13: deleting a business with posted entries, changing a
-- person's role, the full-mandate block for people outside a business, RC and BN numbers, company names word by word,
-- the profile of a company a practice already runs, the retention of an intake by its letters, and a prospect the firm
-- refused coming back another way. (Messages: 05; ongoing due diligence: 06; the letter's fingerprint: 07; credit notes
-- on fee invoices: 11.) Only fake people (example.test addresses).
begin;

-- Fixture: a verified practice (partner Bisi) running Zamfara Gold Ltd (RC 7171701) under full mandate; owners Ngozi,
-- Femi and Lara, and someone outside.
do $$
declare v_partner uuid; pr uuid;
begin
  v_partner := tests.remember('partner', tests.user('partner@thirteen.example.test', 'Bisi Partner'));
  perform tests.remember('ngozi', tests.user('ngozi@owner.example.test', 'Ngozi Owner'));
  perform tests.remember('femi', tests.user('femi@owner.example.test', 'Femi Owner'));
  perform tests.remember('lara', tests.user('lara@owner.example.test', 'Lara Owner'));
  perform tests.remember('someone', tests.user('someone@outside.example.test', 'Some One'));
  pr := tests.remember('pr', tests.practice(v_partner, 'Thirteen Partners', true));
  update practices set referral_code = 'THIRTEEN13' where id = pr;
  perform tests.remember('cz', tests.full_client(pr, v_partner, 'Zamfara Gold Ltd', 'RC 7171701'));
  perform tests.remember('oz', (select org_id from practice_clients where id = tests.id('cz')));
end $$;

-- test: delete_business_with_entries
-- A business with posted entries deleted directly is refused with how to delete it (not a database error about a column);
-- posted lines still only take a party tag.
do $$
declare o uuid; cu uuid; s uuid; j uuid; e text;
begin
  o := tests.org(tests.id('ngozi'), 'Ngozi Posted Ltd');
  perform tests.as_postgres();
  insert into customers (org_id, name) values (o, 'Ade Buyer') returning id into cu;
  perform tests.as_user(tests.id('ngozi'));
  s := (public.save_sale_doc(o, jsonb_build_object('customer_id', cu, 'status', 'issue',
    'lines', '[{"description": "Goods", "qty": 1, "unit_price": 1000, "vat_treatment": "exempt"}]'::jsonb))->>'id')::uuid;
  perform tests.as_postgres();
  j := (select journal_id from sales where id = s);
  assert j is not null, 'delete_business_with_entries: posted';
  e := tests.error_of(format('delete from orgs where id = %L', o));
  assert e like '%deleted from the admin portal%', format('delete_business_with_entries, got %s', e);
  assert tests.error_of(format('delete from journals where id = %L', j)) like '%Posted journals cannot be changed%', 'delete_business_with_entries: a journal alone';
  assert tests.error_of(format('update journal_lines set debit = debit + 1 where journal_id = %L and debit > 0', j)) like '%Posted journals%',
    'delete_business_with_entries: amounts stay';
  perform set_config('app.tag_party', 'on', true);
  update journal_lines set party_type = 'customer', party_id = cu where journal_id = j and party_id is null;
  perform set_config('app.tag_party', '', true);
  assert exists (select 1 from orgs where id = o), 'delete_business_with_entries: still there';
end $$;

-- test: role_change_from_admin
-- The owner moves an admin to each other role and back: the new role and its permissions are written together.
do $$
declare o uuid; v_m uuid; v_role text; mb public.members;
begin
  o := tests.org(tests.id('femi'), 'Femi Roles Ltd');
  perform tests.as_user(tests.id('femi'));
  v_m := public.invite_member(o, 'Ada Admin', 'ada.admin@owner.example.test', 'admin');
  foreach v_role in array array['manager', 'admin', 'staff', 'admin', 'cashier', 'admin', 'accountant', 'manager', 'staff'] loop
    perform public.update_member(v_m, jsonb_build_object('role', v_role));
    perform tests.as_postgres();
    select * into mb from members where id = v_m;
    assert mb.role = v_role and mb.perm_overrides = '{}'::jsonb
       and mb.p_edit_prices = (private.role_perms(o, v_role)->>'edit_prices')::boolean
       and mb.p_record_sales = (private.role_perms(o, v_role)->>'record_sales')::boolean
       and mb.p_manage_team = (private.role_perms(o, v_role)->>'manage_team')::boolean, format('role_change_from_admin: %s, got %s', v_role, to_jsonb(mb));
    perform tests.as_user(tests.id('femi'));
  end loop;
  perform tests.as_postgres();
end $$;

-- test: managed_block_outsiders
-- Someone outside a business the firm runs is told they are not a member, not how the business is run; its own people
-- other than the firm are told it is done from the portal.
do $$
declare o uuid := tests.id('oz');
begin
  perform tests.as_user(tests.id('someone'));
  perform tests.throws(format($q$select public.invite_member(%L, 'X Person', 'x@outside.example.test', 'staff')$q$, o), '42501: You are not a member%');
  perform tests.throws(format($q$select public.subscription_method(%L, '{"method":"card"}')$q$, o), '42501: You are not a member%');
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.invite_member(%L, 'X Person', 'x@outside.example.test', 'staff')$q$, o), '%accountant portal%');
  perform tests.as_postgres();
end $$;

-- test: rc_bn_and_names
-- RC and BN numbers with the same digits are two businesses; a number without a prefix matches either. Names are compared
-- word by word.
do $$
declare pr uuid := tests.id('pr'); o uuid; i uuid; r jsonb;
begin
  assert private.reg_kind('RC 123456') = 'RC' and private.reg_kind('bn-123456') = 'BN' and private.reg_kind('IT 55') = 'IT'
     and private.reg_kind('123456') is null and private.reg_kind(null) is null, 'rc_bn_and_names: the registry';
  assert private.same_reg('RC 123456', 'rc123456') and private.same_reg('RC 123456', '123456') and private.same_reg('123456', 'BN 123456')
     and not private.same_reg('RC 123456', 'BN 123456') and not private.same_reg('RC 123456', 'RC 1234567') and not private.same_reg(null, null)
     and not private.same_reg('RC', 'BN'), 'rc_bn_and_names: the same number';
  assert private.company_name_score('Bisi Ltd', 'Olubisi Foods Ltd') = 0 and private.company_name_score('Olubisi Foods Ltd', 'Bisi Ltd') = 0
     and private.company_name_score('Ade Stores', 'Adebayo Stores Ltd') = 0, 'rc_bn_and_names: no match inside a word';
  assert private.company_name_score('Olubisi Foods Ltd', 'OLUBISI FOODS LIMITED') = 1 and private.company_name_score('Okafor Logistics Ltd', 'Okafor Logistics and Haulage Ltd') = 1
     and private.company_name_score('Marigold Ltd', 'Marigold Cement Ltd') = 1, 'rc_bn_and_names: still a match';
  -- A business name with the company's digits is someone else's: the conflicts check and company_taken pass it by.
  o := tests.org(tests.id('lara'), 'Lara Gold Enterprises');
  update orgs set rc_number = 'BN 7171701' where id = o;
  assert private.company_taken('RC 7171701', null, null, null)->>'org_id' = tests.id('oz')::text, 'rc_bn_and_names: the company is taken';
  assert private.company_taken('BN 7171701', null, pr, null)->>'org_id' = o::text, 'rc_bn_and_names: the business name too';
  assert private.company_taken('RC 7171701', null, pr, tests.id('oz')) is null, 'rc_bn_and_names: not the business name';
  perform tests.as_user(tests.id('partner'));
  i := public.practice_intake_save(pr, '{"legal_name":"Kebbi Rice Mills Ltd","rc_number":"BN 7171701","entity_type":"business_name"}')->>'id';
  r := public.practice_conflict_run(i);
  assert not exists (select 1 from jsonb_array_elements(r->'hits') h where h->>'matched_on' = 'rc_number'), format('rc_bn_and_names: no RC hit, got %s', r->'hits');
  r := public.practice_intake_save(pr, jsonb_build_object('id', i, 'rc_number', 'RC 7171701', 'entity_type', 'company'));
  r := public.practice_conflict_run(i);
  assert exists (select 1 from jsonb_array_elements(r->'hits') h where h->>'matched_on' = 'rc_number' and h->>'source_client_id' = tests.id('cz')::text),
    format('rc_bn_and_names: the RC hit, got %s', r->'hits');
  perform tests.as_postgres();
end $$;

-- test: owner_profile_managed_elsewhere
-- An ordinary owner submitting the profile of a company a practice runs under full mandate is refused: no business is
-- made, the profile stays a draft, and TaxStreem is flagged once. A business name with the same digits is someone else's.
-- An org_id that is not one is answered plainly.
do $$
declare v_ans jsonb := '{"offering": "goods", "category": "food", "revenue_band": "0_50m", "receive_methods": ["bank_transfer"], "pay_methods": ["bank_transfer"], "reasons": ["tax_compliance"], "examples": ["gold"], "filing": {"vat": "always", "wht": "never", "cit": "always"}}';
  r jsonb; n bigint; v_ngozi uuid := tests.id('ngozi'); f public.practice_mandate_flags;
begin
  perform tests.as_user(v_ngozi);
  perform tests.throws($q$select public.kyc_submit('{"org_id": "not-a-uuid"}')$q$, '%Choose the business%');
  perform tests.as_postgres();
  n := (select count(*) from members where user_id = v_ngozi and role = 'owner');
  perform tests.as_service();
  perform public.svc_kyc_store(v_ngozi, 'cac', '{"cac_id": 31, "profile": {"approved_name": "ZAMFARA GOLD LIMITED", "rc_number": "7171701", "classification": "COMPANY", "directors": [{"firstname": "NGOZI", "surname": "OWNER"}]}}', null);
  perform tests.as_user(v_ngozi);
  r := public.kyc_submit(jsonb_build_object('answers', v_ans));
  assert r = '{"ok": false, "reason": "managed_elsewhere"}'::jsonb, format('owner_profile_managed_elsewhere, got %s', r);
  r := public.kyc_submit('{}');
  assert r->>'reason' = 'managed_elsewhere', 'owner_profile_managed_elsewhere: again';
  perform tests.as_postgres();
  assert (select count(*) from members where user_id = v_ngozi and role = 'owner') = n, 'owner_profile_managed_elsewhere: no business made';
  assert (select status = 'draft' and org_id is null from kyc_profiles where user_id = v_ngozi and not for_business), 'owner_profile_managed_elsewhere: still a draft';
  assert (select count(*) from practice_mandate_flags where kind = 'duplicate_company' and detail->>'source' = 'owner' and detail->>'user_id' = v_ngozi::text) = 1,
    'owner_profile_managed_elsewhere: flagged once';
  select * into f from practice_mandate_flags where kind = 'duplicate_company' and detail->>'source' = 'owner' and detail->>'user_id' = v_ngozi::text;
  assert f.practice_id = tests.id('pr') and f.client_id = tests.id('cz') and f.detail->>'business_org_id' = tests.id('oz')::text
     and f.detail->>'matched_on' = 'rc_number' and f.detail->>'email' = 'ngozi@owner.example.test' and f.resolved_at is null,
    format('owner_profile_managed_elsewhere: the flag, got %s', to_jsonb(f));
  -- A business name with the company's digits goes ahead.
  perform tests.as_service();
  perform public.svc_kyc_store(tests.id('lara'), 'cac', '{"cac_id": 32, "profile": {"approved_name": "ZAMFARA GOLDSMITHS", "rc_number": "7171701", "classification": "BUSINESS_NAME", "directors": [{"firstname": "LARA", "surname": "OWNER"}]}}', null);
  perform tests.as_user(tests.id('lara'));
  r := public.kyc_submit(jsonb_build_object('answers', v_ans));
  perform tests.as_postgres();
  assert (r->>'org_id') is not null and (select rc_number = '7171701' from orgs where id = (r->>'org_id')::uuid), format('owner_profile_managed_elsewhere: a business name, got %s', r);
end $$;

-- test: intake_retention_by_letters
-- An involved client's intake is kept, once the work ends, for its letter's six years, not the link's five.
do $$
declare pr uuid := tests.id('pr'); i uuid; c uuid; o uuid;
begin
  i := tests.cleared_intake(pr, 'Kano Leather Ltd');
  perform tests.completed_letter(i);
  perform tests.as_user(tests.id('partner'));
  c := public.practice_invite_client(pr, jsonb_build_object('email', 'femi@owner.example.test', 'intake_id', i));
  perform tests.as_postgres();
  o := tests.org(tests.id('femi'), 'Kano Leather Ltd');
  update practice_clients set token_hash = encode(extensions.digest('pc_' || repeat('ab', 24), 'sha256'), 'hex'), token_expires = now() + interval '7 days' where id = c;
  perform tests.as_user(tests.id('femi'));
  perform public.practice_accept('pc_' || repeat('ab', 24), jsonb_build_object('org_id', o));
  perform public.practice_end(c);
  perform tests.as_postgres();
  assert (select retention_years from practice_clients where id = c) is null
     and (select retain_until = private.retain_date(6) from practice_intakes where id = i), 'intake_retention_by_letters';
end $$;

-- test: refused_prospect_stays_refused
-- A prospect the partner refused after the conflicts check does not become a client through a referral link or a link the
-- business starts (the same RC number, Tax ID or business). Another business is not held back.
do $$
declare pr uuid := tests.id('pr'); i uuid; o uuid; o2 uuid; req uuid; v_lara uuid := tests.id('lara');
begin
  perform tests.as_user(tests.id('partner'));
  i := public.practice_intake_save(pr, '{"legal_name":"Sokoto Cattle Ltd","rc_number":"RC 7272701","tax_id":"7272701-0001","entity_type":"company","risk_rating":"low"}')->>'id';
  perform tests.as_postgres();
  update practice_intakes set conflict_status = 'hits', checked_at = edited_at where id = i;
  perform tests.as_user(tests.id('partner'));
  perform public.practice_conflict_decide(i, '{"outcome":"refused","note":"Acts against an existing client"}');
  perform tests.as_postgres();
  assert (select status from practice_intakes where id = i) = 'declined', 'refused_prospect_stays_refused: declined';
  -- Through the referral link.
  o := tests.org(v_lara, 'Sokoto Cattle Ltd');
  update orgs set rc_number = '7272701' where id = o;
  perform tests.as_user(v_lara);
  perform tests.throws(format($q$select public.referral_connect(%L, 'THIRTEEN13')$q$, o), '%cannot take this business on%');
  perform tests.as_postgres();
  assert not exists (select 1 from practice_clients where org_id = o and practice_id = pr), 'refused_prospect_stays_refused: no link';
  -- By its Tax ID, through a link the business starts.
  update orgs set rc_number = null, tin = '72727010001' where id = o;
  perform tests.as_user(v_lara);
  req := public.business_invite_accountant(o, '{"email": "partner@thirteen.example.test"}');
  perform tests.as_postgres();
  update practice_clients set token_hash = encode(extensions.digest('pc_' || repeat('cd', 24), 'sha256'), 'hex'), token_expires = now() + interval '7 days' where id = req;
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_accept(%L, %L)$q$, 'pc_' || repeat('cd', 24), jsonb_build_object('practice_id', pr)), '%cannot take this business on%');
  perform tests.as_postgres();
  assert (select status = 'requested' and practice_id is null from practice_clients where id = req), 'refused_prospect_stays_refused: still waiting';
  -- A business name with the same digits, and nothing else in common, joins.
  o2 := tests.org(v_lara, 'Sokoto Cattle Traders');
  update orgs set rc_number = 'BN 7272701' where id = o2;
  perform tests.as_user(v_lara);
  perform public.referral_connect(o2, 'THIRTEEN13');
  perform tests.as_postgres();
  assert (select status = 'active' and intake_id is not null from practice_clients where org_id = o2 and practice_id = pr), 'refused_prospect_stays_refused: another business';
end $$;

-- test: fixes_helpers_revoked
-- The new helpers are not callable by the signed-in person; the history table is closed.
do $$
declare v_fn text;
begin
  foreach v_fn in array array['private.reg_kind(text)', 'private.same_reg(text, text)', 'private.letter_fingerprint(uuid)', 'private.intake_snapshot(uuid)',
    'private.guard_journals()'] loop
    assert not has_function_privilege('anon', v_fn, 'execute') and not has_function_privilege('authenticated', v_fn, 'execute'), 'fixes_helpers_revoked: ' || v_fn;
  end loop;
  assert (select relrowsecurity from pg_class where oid = 'public.practice_intake_history'::regclass)
     and not has_table_privilege('authenticated', 'public.practice_intake_history', 'select')
     and not has_table_privilege('anon', 'public.practice_intake_history', 'select'), 'fixes_helpers_revoked: history table';
end $$;

rollback;
