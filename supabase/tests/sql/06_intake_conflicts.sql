-- Due-diligence intake and the conflicts check: a firm records who a prospective client is (registration details, directors
-- and beneficial owners with ID numbers as their last 4 characters only, politically exposed persons, a risk rating,
-- documents) and checks for conflicts inside its own practice only; a partner clears or refuses what the check finds.
-- Inviting a business owner needs a cleared intake; a link the business starts gets a draft intake marked "due diligence
-- incomplete". The records are kept until five years after the engagement ends.
begin;

-- Fixture: a verified practice (partner, manager, staff) with an existing client OLA ADE FOODS LIMITED (RC 123456; a
-- customer and a supplier in its books); another practice with a client ZED LOGISTICS LTD (RC 7777777, a customer in
-- its books), an intake with a director and an opposing party, all under the name Yemi Crafts.
do $$
declare v_partner uuid; v_manager uuid; v_staff uuid; v_owner uuid; v_owner2 uuid; v_other uuid; v_pr uuid; v_pr2 uuid; v_ola uuid; v_zed uuid;
  v_i uuid;
begin
  v_partner := tests.remember('partner', tests.user('dd.partner@firm.example.test', 'Ngozi Partner'));
  v_manager := tests.remember('manager', tests.user('dd.manager@firm.example.test', 'Tunde Manager'));
  v_staff := tests.remember('staff', tests.user('dd.staff@firm.example.test', 'Bola Staff'));
  v_owner := tests.remember('owner', tests.user('dd.owner@example.test', 'Ada Owner'));
  v_owner2 := tests.remember('owner2', tests.user('dd.owner2@example.test', 'Femi Owner'));
  v_other := tests.remember('other_partner', tests.user('dd.other@other.example.test', 'Kemi Other'));
  v_pr := tests.remember('pr', tests.practice(v_partner, 'Diligent Partners', true));
  perform tests.remember('partner_pm', (select id from practice_members where practice_id = v_pr and user_id = v_partner));
  perform tests.remember('manager_pm', tests.practice_member(v_pr, v_manager, 'manager'));
  perform tests.remember('staff_pm', tests.practice_member(v_pr, v_staff, 'staff'));
  v_pr2 := tests.remember('pr2', tests.practice(v_other, 'Other Partners', true));

  v_ola := tests.remember('ola', tests.org(v_owner, 'OLA ADE FOODS LIMITED'));
  update orgs set rc_number = '123456' where id = v_ola;
  insert into customers (org_id, name, kind) values (v_ola, 'Zenith Paints Ltd', 'business');
  insert into vendors (org_id, name, rc_number) values (v_ola, 'Kudi Supplies Ltd', 'RC5555555');
  perform tests.remember('ola_client', tests.involved_client(v_pr, v_ola));

  v_zed := tests.remember('zed', tests.org(v_owner2, 'ZED LOGISTICS LTD'));
  update orgs set rc_number = '7777777', tin = '11112222-0001' where id = v_zed;
  insert into customers (org_id, name, kind) values (v_zed, 'Yemi Crafts Ltd', 'business');
  perform tests.remember('zed_client', tests.involved_client(v_pr2, v_zed));
  perform tests.as_user(v_other);
  v_i := public.practice_intake_save(v_pr2, '{"legal_name": "Yemi Crafts Ltd", "people": [{"kind": "director", "name": "Kunle Bakare"}]}')->>'id';
  perform public.practice_opposing_save(v_pr2, '{"name": "Yemi Crafts Ltd", "rc_number": "RC 7777777"}');
  perform tests.as_postgres();
  update practices set conflict_scan_books = true where id = v_pr2;
end $$;

-- test: intake_pep_forces_high
-- A politically exposed person makes the risk high whatever the firm chose, and keeps it high.
do $$
declare pr uuid := tests.id('pr'); i uuid;
begin
  perform tests.as_user(tests.id('partner'));
  i := public.practice_intake_save(pr, '{"legal_name":"Kola Ventures Ltd","risk_rating":"low","people":[{"kind":"director","name":"Kola Ade","is_pep":true}]}')->>'id';
  perform tests.as_postgres();
  perform tests.remember('kola', i);
  assert (select risk_rating = 'high' and pep_present from practice_intakes where id = i), 'intake_pep_forces_high';
  assert (select status = 'draft' and conflict_status = 'pending' and mode_requested = 'involved' and not dd_incomplete
            and created_by = tests.id('partner') and practice_id = pr from practice_intakes where id = i),
    'intake_pep_forces_high: a new draft, its check pending';
  perform tests.as_user(tests.id('partner'));
  assert public.practice_intake(i)->'letters' = '[]'::jsonb, 'intake_pep_forces_high: no letters before Task 9';
  perform public.practice_intake_save(pr, jsonb_build_object('id', i, 'risk_rating', 'low'));
  perform tests.as_postgres();
  assert (select risk_rating = 'high' and pep_present from practice_intakes where id = i), 'intake_pep_forces_high: stays high while a PEP is recorded';
  -- Without a PEP the rating is the firm's.
  perform tests.as_user(tests.id('manager'));
  i := public.practice_intake_save(pr, '{"legal_name":"Calm Waters Ltd","risk_rating":"low","people":[{"kind":"director","name":"Sola Bello","is_pep":false}]}')->>'id';
  perform tests.as_postgres();
  assert (select risk_rating = 'low' and not pep_present from practice_intakes where id = i), 'intake_pep_forces_high: no PEP, the firm''s rating';
  -- Staff do not take on clients.
  perform tests.as_user(tests.id('staff'));
  perform tests.throws(format($q$select public.practice_intake_save(%L, '{"legal_name":"Staff Pick Ltd"}')$q$, pr), '%partners and managers%');
  perform tests.as_postgres();
end $$;

-- test: intake_rejects_full_id_numbers          (Review Focus 4)
-- A full NIN or BVN typed or pasted anywhere in a person's details is refused; only the last 4 characters are kept.
do $$
declare pr uuid := tests.id('pr'); y uuid;
begin
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_intake_save(%L, '{"legal_name":"X Ltd","people":[{"kind":"director","name":"Ada 12345678901"}]}')$q$, pr),
    '%last 4 characters%');
  perform tests.throws(format($q$select public.practice_intake_save(%L, '{"legal_name":"X Ltd","people":[{"kind":"director","name":"Ada Eze","role":"Director, NIN 12345678901"}]}')$q$, pr),
    '%last 4 characters%');
  perform tests.throws(format($q$select public.practice_intake_save(%L, '{"legal_name":"X Ltd","people":[{"kind":"director","name":"Ada Eze","nationality":"Nigerian 22345678901"}]}')$q$, pr),
    '%last 4 characters%');
  perform tests.throws(format($q$select public.practice_intake_save(%L, '{"legal_name":"X Ltd","people":[{"kind":"director","name":"Ada Eze","id_last4":"12345678901"}]}')$q$, pr),
    '%last 4 characters%');
  perform tests.throws(format($q$select public.practice_intake_save(%L, '{"legal_name":"X Ltd","people":[{"kind":"director","name":"Ada Eze","id_last4":"78901"}]}')$q$, pr),
    '%last 4 characters%');
  perform tests.throws(format($q$select public.practice_intake_save(%L, '{"legal_name":"X Ltd","people":[{"kind":"director","name":"Ada Eze","nin":"12345678901"}]}')$q$, pr),
    '%last 4 characters%');
  perform tests.throws(format($q$select public.practice_intake_save(%L, '{"legal_name":"X Ltd","people":[{"kind":"director","name":"Ada Eze","bvn":"22345678901"}]}')$q$, pr),
    '%last 4 characters%');
  perform tests.throws(format($q$select public.practice_intake_save(%L, '{"legal_name":"X Ltd","people":[{"kind":"director","name":"Ada Eze","id_number":"A01234567"}]}')$q$, pr),
    '%last 4 characters%');
  perform tests.as_postgres();
  assert not exists (select 1 from practice_intakes where legal_name = 'X Ltd'), 'intake_rejects_full_id_numbers: nothing saved';
  perform tests.as_user(tests.id('partner'));
  assert tests.error_of(format($q$select public.practice_intake_save(%L, '{"legal_name":"Y Ltd","people":[{"kind":"director","name":"Ada Eze","id_type":"nin","id_last4":"8901"}]}')$q$, pr)) is null,
    'intake_rejects_full_id_numbers: last 4 accepted';
  perform tests.as_postgres();
  y := (select id from practice_intakes where legal_name = 'Y Ltd');
  assert (select count(*) = 1 and bool_and(p.id_type = 'nin' and p.id_last4 = '8901' and p.practice_id = pr) from practice_intake_people p where p.intake_id = y),
    'intake_rejects_full_id_numbers: last 4 kept';
  -- Editing an intake: a full number is refused and the people stay as they were.
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_intake_save(%L, jsonb_build_object('id', %L::uuid, 'people', '[{"kind":"director","name":"Ada Eze","id_last4":"12345678901"}]'::jsonb))$q$, pr, y),
    '%last 4 characters%');
  perform tests.as_postgres();
  assert (select id_last4 from practice_intake_people where intake_id = y) = '8901', 'intake_rejects_full_id_numbers: edit refused, people unchanged';
  -- The table holds the same rules.
  perform tests.throws(format($q$insert into practice_intake_people (intake_id, practice_id, kind, name, id_last4) values (%L, %L, 'director', 'Ada Eze', '12345678901')$q$, y, pr),
    '%check constraint%');
  perform tests.throws(format($q$insert into practice_intake_people (intake_id, practice_id, kind, name) values (%L, %L, 'director', 'Ada 12345678901')$q$, y, pr),
    '%check constraint%');
  perform tests.as_postgres();
end $$;

-- test: conflict_diacritics_suffix_rc           (Review Focus 2)
-- "Ọlá Àdé Foods Ltd" / "RC 123456" hits the existing client "OLA ADE FOODS LIMITED" / "123456".
do $$
declare pr uuid := tests.id('pr'); i uuid; r jsonb;
begin
  assert private.fold_name('Ọlá Àdé Foods Ltd') = 'Ola Ade Foods Ltd' and private.fold_name(null) = '', 'conflict_diacritics_suffix_rc: accents folded';
  assert private.norm_id('RC 123456') = '123456' and private.norm_id('rc-123456') = '123456' and private.norm_id('BN 98765') = '98765'
     and private.norm_id('12345678-0001') = '123456780001' and private.norm_id(' - ') is null and private.norm_id(null) is null,
    'conflict_diacritics_suffix_rc: numbers normalised';
  perform tests.as_user(tests.id('partner'));
  i := public.practice_intake_save(pr, '{"legal_name":"Ọlá Àdé Foods Ltd","rc_number":"RC 123456","entity_type":"company"}')->>'id';
  r := public.practice_conflict_run(i);
  perform tests.as_postgres();
  perform tests.remember('ola_intake', i);
  assert exists (select 1 from practice_conflict_hits where intake_id = i and matched_on = 'name' and kind = 'client'), 'conflict_diacritics_suffix_rc: name';
  assert exists (select 1 from practice_conflict_hits where intake_id = i and matched_on = 'rc_number'), 'conflict_diacritics_suffix_rc: RC';
  assert r->>'conflict_status' = 'hits' and jsonb_array_length(r->'hits') = 2 and (select checked_at is not null from practice_intakes where id = i),
    'conflict_diacritics_suffix_rc: the run returns the intake with its hits';
  -- One hit per client and match, however many of the client's names match (the business, the link, its intake).
  assert (select count(*) = 1 and bool_and(source_client_id = tests.id('ola_client') and match_name = 'OLA ADE FOODS LIMITED' and score = 1
            and subject = 'Ọlá Àdé Foods Ltd' and practice_id = pr)
          from practice_conflict_hits where intake_id = i and matched_on = 'name' and kind = 'client'),
    'conflict_diacritics_suffix_rc: the client named once';
  assert (select subject = 'RC 123456' and kind = 'client' and source_client_id = tests.id('ola_client')
          from practice_conflict_hits where intake_id = i and matched_on = 'rc_number'), 'conflict_diacritics_suffix_rc: RC from the client';
  -- A name three-quarters the same is a possible conflict too.
  assert private.name_score(private.fold_name('Ọlá Àdé Foods and Bakeries Ltd'), private.fold_name('OLA ADE FOODS LIMITED')) = 0.75,
    'conflict_diacritics_suffix_rc: three of four words';
end $$;

-- test: conflict_people_and_opposing
-- A beneficial owner who is a director in another of the practice's intakes, and a prospect the practice faces on a
-- client's matter.
do $$
declare pr uuid := tests.id('pr'); a uuid; b uuid; op jsonb;
begin
  perform tests.as_user(tests.id('manager'));
  op := public.practice_opposing_save(pr, jsonb_build_object('client_id', tests.id('ola_client'), 'name', 'Babatunde Holdings Ltd', 'rc_number', 'RC 8888888',
    'note', 'Landlord in the rent dispute'));
  a := public.practice_intake_save(pr, '{"legal_name":"Kemi Stores Ltd","people":[{"kind":"director","name":"Adaeze Okafor","role":"Managing director"}]}')->>'id';
  b := public.practice_intake_save(pr, '{"legal_name":"Babatunde Holdings Limited","rc_number":"8888888",
    "people":[{"kind":"beneficial_owner","name":"Chief (Mrs) Adaeze N. Okafor","ownership_pct":60}]}')->>'id';
  perform public.practice_conflict_run(b);
  perform tests.as_postgres();
  perform tests.remember('kemi', a);
  perform tests.remember('babatunde', b);
  perform tests.remember('opposing', (op->>'id')::uuid);
  assert exists (select 1 from practice_conflict_hits where intake_id = b and matched_on = 'person' and kind = 'related_party')
     and exists (select 1 from practice_conflict_hits where intake_id = b and kind = 'opposing_party'), 'conflict_people_and_opposing';
  assert (select source_intake_id = a and subject = 'Chief (Mrs) Adaeze N. Okafor' and match_name = 'Adaeze Okafor'
          from practice_conflict_hits where intake_id = b and matched_on = 'person' and kind = 'related_party'),
    'conflict_people_and_opposing: the person and where they are recorded';
  assert (select count(*) from practice_conflict_hits where intake_id = b and kind = 'opposing_party' and source_opposing_id = tests.id('opposing')
          and source_client_id = tests.id('ola_client') and matched_on in ('name', 'rc_number')) = 2,
    'conflict_people_and_opposing: the opposing party by name and RC';
  -- The other intake sees the same person.
  perform tests.as_user(tests.id('manager'));
  perform public.practice_conflict_run(a);
  perform tests.as_postgres();
  assert (select source_intake_id = b from practice_conflict_hits where intake_id = a and matched_on = 'person' and kind = 'related_party'),
    'conflict_people_and_opposing: both ways';
end $$;

-- test: conflict_never_crosses_practices
-- The same name, RC number, Tax ID and director as the other practice's client, intake, opposing party and a customer in
-- its client's books: nothing, with or without the books.
do $$
declare pr uuid := tests.id('pr'); i2 uuid;
begin
  perform tests.as_user(tests.id('partner'));
  i2 := public.practice_intake_save(pr, '{"legal_name":"Yemi Crafts Ltd","rc_number":"RC7777777","tax_id":"11112222-0001",
    "people":[{"kind":"director","name":"Kunle Bakare"}]}')->>'id';
  assert (public.practice_conflict_run(i2)->>'conflict_status') = 'none', 'conflict_never_crosses_practices';
  perform tests.as_postgres();
  update practices set conflict_scan_books = true where id = pr;
  perform tests.as_user(tests.id('partner'));
  assert (public.practice_conflict_run(i2)->>'conflict_status') = 'none', 'conflict_never_crosses_practices: books of this practice only';
  perform tests.as_postgres();
  update practices set conflict_scan_books = false where id = pr;
  -- The other practice does find them, in its own records.
  perform tests.as_user(tests.id('other_partner'));
  i2 := public.practice_intake_save(tests.id('pr2'), '{"legal_name":"Yemi Crafts Nigeria Ltd","rc_number":"RC 7777777"}')->>'id';
  perform public.practice_conflict_run(i2);
  perform tests.as_postgres();
  assert (select array_agg(distinct kind order by kind) from practice_conflict_hits where intake_id = i2) = '{books,client,opposing_party,prospect}',
    'conflict_never_crosses_practices: the other practice''s own records';
end $$;

-- test: conflict_books_scan_setting
-- The prospect is a customer of an active client: found only when the firm turns the setting on (a partner's choice).
do $$
declare pr uuid := tests.id('pr'); i uuid; j uuid; r jsonb;
begin
  assert not (select conflict_scan_books from practices where id = pr), 'conflict_books_scan_setting: off by default';
  perform tests.as_user(tests.id('partner'));
  i := public.practice_intake_save(pr, '{"legal_name":"Zenith Paints Nigeria Ltd"}')->>'id';
  r := public.practice_conflict_run(i);
  perform tests.as_postgres();
  perform tests.remember('zenith', i);
  assert r->>'conflict_status' = 'none' and not exists (select 1 from practice_conflict_hits where intake_id = i and kind = 'books'),
    'conflict_books_scan_setting: off by default';
  perform tests.as_user(tests.id('manager'));
  perform tests.throws(format('select public.practice_set_conflict_scan(%L, true)', pr), '%partner%');
  perform tests.as_user(tests.id('partner'));
  r := public.practice_set_conflict_scan(pr, true);
  assert (r->'practice'->>'conflict_scan_books')::boolean, 'conflict_books_scan_setting: the setting returned';
  perform public.practice_conflict_run(i);
  -- A supplier in the client's books by its RC number.
  j := public.practice_intake_save(pr, '{"legal_name":"Northern Star Ltd","rc_number":"RC 5555555"}')->>'id';
  perform public.practice_conflict_run(j);
  perform tests.as_postgres();
  assert exists (select 1 from practice_conflict_hits where intake_id = i and kind = 'books'), 'conflict_books_scan_setting: on';
  assert (select source_client_id = tests.id('ola_client') and matched_on = 'name' and match_name = 'Zenith Paints Ltd'
          from practice_conflict_hits where intake_id = i and kind = 'books'), 'conflict_books_scan_setting: the customer and whose books';
  assert (select match_name = 'Kudi Supplies Ltd' and source_client_id = tests.id('ola_client')
          from practice_conflict_hits where intake_id = j and kind = 'books' and matched_on = 'rc_number'), 'conflict_books_scan_setting: a supplier by RC';
  perform tests.as_user(tests.id('partner'));
  perform public.practice_set_conflict_scan(pr, false);
  perform tests.as_postgres();
  assert not (select conflict_scan_books from practices where id = pr), 'conflict_books_scan_setting: off again';
end $$;

-- test: opposing_parties
-- Partners and managers record the other side of a client's matters; they can change and remove them.
do $$
declare pr uuid := tests.id('pr'); r jsonb; v uuid;
begin
  perform tests.as_user(tests.id('manager'));
  r := public.practice_opposing_save(pr, jsonb_build_object('client_id', tests.id('ola_client'), 'name', 'Lagos Rentals Ltd'));
  v := (r->>'id')::uuid;
  assert r->>'name' = 'Lagos Rentals Ltd' and (r->>'client_id')::uuid = tests.id('ola_client'), 'opposing_parties: recorded';
  r := public.practice_opposing_save(pr, jsonb_build_object('id', v, 'note', 'Tenant in the 2026 claim'));
  assert r->>'name' = 'Lagos Rentals Ltd' and r->>'note' = 'Tenant in the 2026 claim', 'opposing_parties: changed, the rest kept';
  perform tests.throws(format($q$select public.practice_opposing_save(%L, jsonb_build_object('client_id', %L::uuid, 'name', 'Another Ltd'))$q$, pr, tests.id('zed_client')),
    '%Client not found%');
  perform tests.throws(format($q$select public.practice_opposing_save(%L, '{"name": "X"}')$q$, pr), '%opposing party%');
  r := public.practice_opposing_save(pr, jsonb_build_object('id', v, 'remove', true));
  perform tests.as_postgres();
  assert (r->>'removed')::boolean and not exists (select 1 from practice_opposing_parties where id = v), 'opposing_parties: removed';
  perform tests.as_user(tests.id('staff'));
  perform tests.throws(format($q$select public.practice_opposing_save(%L, '{"name": "Staff Ltd"}')$q$, pr), '%partners and managers%');
  perform tests.as_user(tests.id('other_partner'));
  perform tests.throws(format($q$select public.practice_opposing_save(%L, jsonb_build_object('id', %L::uuid, 'remove', true))$q$, tests.id('pr2'), tests.id('opposing')),
    '%not found%');
  perform tests.as_postgres();
end $$;

-- test: conflict_decide_rules
-- Only a partner decides, with a note of at least 10 characters, on hits found after the intake's last change.
do $$
declare pr uuid := tests.id('pr'); i uuid := tests.id('ola_intake'); b uuid := tests.id('babatunde'); q uuid; r jsonb;
begin
  perform tests.as_user(tests.id('manager'));
  perform tests.throws(format($q$select public.practice_conflict_decide(%L, '{"outcome":"cleared","note":"Different company"}')$q$, i), '%partner%');
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_conflict_decide(%L, '{"outcome":"cleared","note":"short"}')$q$, i), '%10%');
  perform tests.throws(format($q$select public.practice_conflict_decide(%L, '{"outcome":"maybe","note":"Different company"}')$q$, i), '%cleared or refused%');
  -- Nothing found, nothing to decide.
  q := public.practice_intake_save(pr, '{"legal_name":"Quiet Waters Ltd"}')->>'id';
  perform public.practice_conflict_run(q);
  perform tests.throws(format($q$select public.practice_conflict_decide(%L, '{"outcome":"cleared","note":"Nothing to see here"}')$q$, q), '%found nothing%');
  -- Changed since the check: run it again first.
  perform tests.as_postgres();
  update practice_intakes set edited_at = checked_at + interval '1 second' where id = i;
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_conflict_decide(%L, '{"outcome":"cleared","note":"Different company"}')$q$, i), '%Run the conflicts check%');
  perform tests.as_postgres();
  update practice_intakes set edited_at = checked_at where id = i;
  -- Cleared, with the partner's name and note.
  perform tests.as_user(tests.id('partner'));
  r := public.practice_conflict_decide(i, '{"outcome":"cleared","note":"A different company: other directors and address"}');
  assert r->>'conflict_status' = 'cleared' and r->>'conflict_decided_by_name' = 'Ngozi Partner', 'conflict_decide_rules: cleared';
  perform tests.throws(format($q$select public.practice_conflict_decide(%L, '{"outcome":"refused","note":"Changed my mind now"}')$q$, i), '%recorded%');
  perform tests.as_postgres();
  assert (select conflict_decided_by = tests.id('partner_pm') and conflict_decided_at is not null and status = 'draft'
            and conflict_note = 'A different company: other directors and address' from practice_intakes where id = i),
    'conflict_decide_rules: decision recorded';
  -- Not ready for an engagement until it has a risk rating; rating it is not a change to what was checked.
  assert not private.intake_cleared((select x from practice_intakes x where id = i)), 'conflict_decide_rules: no risk rating yet';
  perform tests.as_user(tests.id('partner'));
  perform public.practice_intake_save(pr, jsonb_build_object('id', i, 'risk_rating', 'medium', 'risk_reason', 'Food manufacturer, cash sales'));
  perform tests.as_postgres();
  assert private.intake_cleared((select x from practice_intakes x where id = i)) and (select conflict_status = 'cleared' from practice_intakes where id = i),
    'conflict_decide_rules: rated and cleared';
  -- Refused: the intake is declined and kept for five years.
  perform tests.as_user(tests.id('partner'));
  r := public.practice_conflict_decide(b, '{"outcome":"refused","note":"We act for the other side in a rent dispute"}');
  assert r->>'conflict_status' = 'refused' and r->>'status' = 'declined', 'conflict_decide_rules: refused';
  perform tests.throws(format($q$select public.practice_intake_save(%L, jsonb_build_object('id', %L::uuid, 'legal_name', 'Babatunde Holdings Plc'))$q$, pr, b), '%declined%');
  perform tests.throws(format('select public.practice_conflict_run(%L)', b), '%declined%');
  perform tests.as_postgres();
  assert (select status = 'declined' and conflict_status = 'refused' and retain_until = private.retain_date(5) and legal_name = 'Babatunde Holdings Limited'
          from practice_intakes where id = b), 'conflict_decide_rules: declined and kept';
end $$;

-- test: intake_reedit_needs_rerun
-- A change to the name, RC number, Tax ID or people needs a new check; other changes keep it.
do $$
declare pr uuid := tests.id('pr'); i uuid := tests.id('kola'); r jsonb;
begin
  perform tests.as_user(tests.id('partner'));
  r := public.practice_conflict_run(i);
  perform tests.as_postgres();
  assert r->>'conflict_status' = 'none' and (r->>'cleared')::boolean, 'intake_reedit_needs_rerun: cleared after the check';
  -- As if checked a while ago.
  update practice_intakes set edited_at = now() - interval '1 hour', checked_at = now() - interval '30 minutes' where id = i;
  perform tests.as_user(tests.id('partner'));
  perform public.practice_intake_save(pr, jsonb_build_object('id', i, 'risk_reason', 'A director is a PEP', 'address', '12 Marina, Lagos', 'industry', 'Trading',
    'entity_type', 'company', 'people', '[{"kind":"director","name":"Kola Ade","is_pep":true}]'::jsonb));
  perform tests.as_postgres();
  assert (select conflict_status = 'none' and edited_at = now() - interval '1 hour' from practice_intakes where id = i)
     and private.intake_cleared((select x from practice_intakes x where id = i)), 'intake_reedit_needs_rerun: other changes keep the check';
  perform tests.as_user(tests.id('partner'));
  perform public.practice_intake_save(pr, jsonb_build_object('id', i, 'legal_name', 'Kola Ventures Nigeria Ltd'));
  perform tests.as_postgres();
  assert (select conflict_status from practice_intakes where id = i) = 'pending' and not private.intake_cleared((select x from practice_intakes x where id = i)), 'intake_reedit_needs_rerun';
  assert (select edited_at = now() from practice_intakes where id = i), 'intake_reedit_needs_rerun: the change is dated';
  -- Run again: cleared again. A new person, or a new RC number, needs another run.
  perform tests.as_user(tests.id('partner'));
  perform public.practice_conflict_run(i);
  perform public.practice_intake_save(pr, jsonb_build_object('id', i, 'people',
    '[{"kind":"director","name":"Kola Ade","is_pep":true},{"kind":"beneficial_owner","name":"Funke Ade","ownership_pct":40}]'::jsonb));
  perform tests.as_postgres();
  assert (select conflict_status from practice_intakes where id = i) = 'pending', 'intake_reedit_needs_rerun: people changed';
  perform tests.as_user(tests.id('partner'));
  perform public.practice_conflict_run(i);
  perform public.practice_intake_save(pr, jsonb_build_object('id', i, 'rc_number', 'RC 246810'));
  perform tests.as_postgres();
  assert (select conflict_status from practice_intakes where id = i) = 'pending', 'intake_reedit_needs_rerun: RC changed';
  perform tests.as_user(tests.id('partner'));
  perform public.practice_conflict_run(i);
  perform tests.as_postgres();
  assert private.intake_cleared((select x from practice_intakes x where id = i)), 'intake_reedit_needs_rerun: cleared after the new check';
  -- Checked before its last change: not cleared, whatever the status says.
  update practice_intakes set edited_at = checked_at + interval '1 second' where id = i;
  assert not private.intake_cleared((select x from practice_intakes x where id = i)), 'intake_reedit_needs_rerun: checked before the last change';
  update practice_intakes set edited_at = checked_at where id = i;
end $$;

-- test: declaration_keeps_clearance
-- A partner declares the firm holds the client's written authority for a full mandate; that is not a change to what was
-- checked.
do $$
declare pr uuid := tests.id('pr'); k uuid; r jsonb;
begin
  k := tests.cleared_intake(pr, 'Clear Ventures Ltd', 'full');
  perform tests.remember('clear_full', k);
  update practice_intakes set edited_at = now() - interval '1 hour', checked_at = now() - interval '30 minutes' where id = k;
  perform tests.as_user(tests.id('manager'));
  perform tests.throws(format($q$select public.practice_intake_declare(%L, '{}')$q$, k), '%partner%');
  perform tests.as_user(tests.id('partner'));
  perform public.practice_intake_declare(k, '{}');
  perform tests.as_postgres();
  assert private.intake_cleared((select x from practice_intakes x where id = k)), 'declaration_keeps_clearance: only substantive edits move edited_at';
  assert (select authority_statement = 'I confirm that Diligent Partners holds the written authority of Clear Ventures Ltd to set up and run its accounting '
                 || 'records and tax affairs on its behalf under full mandate, as set out in the engagement letter, and that I am a partner of Diligent Partners.'
            and authority_declared_by = tests.id('partner_pm') and authority_declared_at is not null and authority_doc_path is null
            and edited_at = now() - interval '1 hour' from practice_intakes where id = k),
    'declaration_keeps_clearance: the statement and who made it';
  -- With the signed authority on file; only from the intake's own folder.
  perform tests.as_user(tests.id('partner'));
  r := public.practice_intake_declare(k, jsonb_build_object('doc_path', 'practice/' || pr || '/intake/' || k || '/authority.pdf'));
  assert r->>'authority_doc_path' = 'practice/' || pr || '/intake/' || k || '/authority.pdf' and r->>'authority_declared_by_name' = 'Ngozi Partner',
    'declaration_keeps_clearance: the authority document';
  perform tests.throws(format($q$select public.practice_intake_declare(%L, jsonb_build_object('doc_path', 'practice/%s/intake/%s/authority.pdf'))$q$,
    k, tests.id('pr2'), k), '%intake''s folder%');
  -- Only for a full mandate.
  perform tests.throws(format($q$select public.practice_intake_declare(%L, '{}')$q$, tests.id('ola_intake')), '%full mandate%');
  -- A new name withdraws it: the statement names the client.
  perform public.practice_intake_save(pr, jsonb_build_object('id', k, 'legal_name', 'Clear Ventures Nigeria Ltd'));
  perform tests.as_postgres();
  assert (select authority_declared_at is null and authority_statement is null and authority_declared_by is null and authority_doc_path is null
          from practice_intakes where id = k), 'declaration_keeps_clearance: withdrawn when the name changes';
end $$;

-- test: invite_needs_cleared_intake
-- Inviting a business owner needs a cleared involved intake of the practice; the link then carries the intake, which the
-- owner's acceptance engages and the end of the work dates.
do $$
declare pr uuid := tests.id('pr'); u uuid; f uuid; e uuid; c uuid; o uuid; v_owner uuid;
begin
  f := tests.cleared_intake(pr, 'Full Only Ltd', 'full');
  e := tests.cleared_intake(tests.id('pr2'), 'Elsewhere Ltd');
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_invite_client(%L, '{"email":"o@example.test","intake_id":"%s"}')$q$, pr, tests.id('zenith')), '%due diligence%');
  perform tests.throws(format($q$select public.practice_invite_client(%L, '{"email":"o@example.test"}')$q$, pr), '%due diligence%');
  perform tests.throws(format($q$select public.practice_invite_client(%L, '{"email":"o@example.test","intake_id":"not-an-id"}')$q$, pr), '%due diligence%');
  perform tests.throws(format($q$select public.practice_invite_client(%L, '{"email":"o@example.test","intake_id":"%s"}')$q$, pr, f), '%due diligence%');
  perform tests.throws(format($q$select public.practice_invite_client(%L, '{"email":"o@example.test","intake_id":"%s"}')$q$, pr, e), '%due diligence%');
  perform tests.throws(format($q$select public.practice_invite_client(%L, '{"email":"o@example.test","intake_id":"%s"}')$q$, pr, tests.id('babatunde')), '%due diligence%');
  perform tests.as_postgres();
  assert not exists (select 1 from practice_clients where lower(invite_email) = 'o@example.test'), 'invite_needs_cleared_intake: nothing sent';

  u := tests.cleared_intake(pr, 'Invite Me Ltd');
  perform tests.as_user(tests.id('partner'));
  c := public.practice_invite_client(pr, jsonb_build_object('email', 'im.owner@example.test', 'name', 'Ife Owner', 'intake_id', u));
  perform tests.throws(format($q$select public.practice_invite_client(%L, '{"email":"im2.owner@example.test","intake_id":"%s"}')$q$, pr, u), '%already%');
  perform tests.as_postgres();
  assert (select intake_id = u and business_name = 'Invite Me Ltd' and status = 'invited' and invite_email = 'im.owner@example.test' from practice_clients where id = c),
    'invite_needs_cleared_intake: the invitation carries the intake';
  assert (select status = 'draft' and client_id is null from practice_intakes where id = u), 'invite_needs_cleared_intake: not engaged until accepted';

  -- The owner accepts with their business.
  v_owner := tests.user('im.owner@example.test', 'Ife Owner');
  o := tests.org(v_owner, 'Invite Me Ltd');
  update practice_clients set token_hash = encode(extensions.digest('pc_' || repeat('ef', 24), 'sha256'), 'hex'), token_expires = now() + interval '7 days' where id = c;
  perform tests.as_user(v_owner);
  perform public.practice_accept('pc_' || repeat('ef', 24), jsonb_build_object('org_id', o));
  perform tests.as_postgres();
  assert (select status = 'engaged' and org_id = o and client_id = c and not dd_incomplete and retain_until is null from practice_intakes where id = u),
    'invite_needs_cleared_intake: engaged on acceptance';
  assert (select intake_id = u from practice_clients where id = c) and (select count(*) from practice_intakes where client_id = c) = 1,
    'invite_needs_cleared_intake: no second intake';
  assert private.intake_cleared((select x from practice_intakes x where id = u)), 'invite_needs_cleared_intake: still cleared';
  -- The work ends: kept for five years from today.
  perform tests.as_user(v_owner);
  perform public.practice_end(c);
  perform tests.as_postgres();
  assert (select retain_until = private.retain_date(null) and retain_until = (current_date + interval '5 years')::date from practice_intakes where id = u),
    'invite_needs_cleared_intake: kept five years after the end';
end $$;

-- test: business_link_creates_draft_intake
-- A business invites the firm's partner, who accepts: the client gets a draft intake marked "due diligence incomplete",
-- with the business's name and numbers and none of the people in its CAC record.
do $$
declare pr uuid := tests.id('pr'); o uuid; v_owner uuid; req uuid; c uuid; x public.practice_intakes; r jsonb;
begin
  v_owner := tests.remember('lb_owner', tests.user('lb.owner@example.test', 'Lara Owner'));
  o := tests.remember('linked', tests.org(v_owner, 'Linked Biz Ltd'));
  update orgs set rc_number = 'RC 4444444', tin = '22223333-0001', directors = '[{"name": "Secret Director"}]' where id = o;
  perform tests.as_user(v_owner);
  req := public.business_invite_accountant(o, '{"email": "dd.partner@firm.example.test"}');
  perform tests.as_postgres();
  update practice_clients set token_hash = encode(extensions.digest('pc_' || repeat('cd', 24), 'sha256'), 'hex'), token_expires = now() + interval '7 days' where id = req;
  perform tests.as_user(tests.id('partner'));
  c := public.practice_accept('pc_' || repeat('cd', 24), jsonb_build_object('practice_id', pr))->>'client_id';
  perform tests.as_postgres();
  assert (select dd_incomplete and status = 'engaged' from practice_intakes where client_id = c), 'business_link_creates_draft_intake';
  select * into x from practice_intakes where client_id = c;
  perform tests.remember('linked_intake', x.id);
  assert x.legal_name = 'Linked Biz Ltd' and x.rc_number = 'RC 4444444' and x.tax_id = '22223333-0001' and x.org_id = o and x.practice_id = pr
     and x.conflict_status = 'pending' and x.risk_rating is null and x.mode_requested = 'involved' and x.retain_until is null,
    'business_link_creates_draft_intake: the business''s name and numbers';
  assert (select intake_id = x.id from practice_clients where id = c), 'business_link_creates_draft_intake: the link carries it';
  assert not exists (select 1 from practice_intake_people where intake_id = x.id), 'business_link_creates_draft_intake: CAC directors not copied';
  -- Doing the due diligence takes the flag off.
  perform tests.as_user(tests.id('partner'));
  perform public.practice_intake_save(pr, jsonb_build_object('id', x.id, 'risk_rating', 'low'));
  perform tests.as_postgres();
  assert (select dd_incomplete from practice_intakes where id = x.id), 'business_link_creates_draft_intake: still incomplete before the check';
  perform tests.as_user(tests.id('partner'));
  r := public.practice_conflict_run(x.id);
  perform tests.as_postgres();
  assert r->>'conflict_status' = 'none' and not (r->>'dd_incomplete')::boolean, 'business_link_creates_draft_intake: complete once cleared';
end $$;

-- test: intake_reads
-- Partners and managers see the practice's intakes, with their people, documents and hits; staff and other practices do not.
do $$
declare pr uuid := tests.id('pr'); r jsonb; v_count int := (select count(*) from practice_intakes where practice_id = tests.id('pr'));
begin
  perform tests.as_user(tests.id('manager'));
  r := public.practice_intakes(pr);
  assert jsonb_array_length(r) = v_count and v_count > 10
     and (select bool_and(e ? 'conflict_status' and e ? 'cleared' and e ? 'dd_incomplete' and not e ? 'people') from jsonb_array_elements(r) e),
    'intake_reads: the list';
  r := public.practice_intakes(pr, '{"status": "declined"}');
  assert jsonb_array_length(r) = 1 and (r->0->>'id')::uuid = tests.id('babatunde'), 'intake_reads: by status';
  -- A document.
  r := public.practice_intake_doc_add(tests.id('kola'), jsonb_build_object('path', 'practice/' || pr || '/intake/' || tests.id('kola') || '/cac-certificate.pdf',
    'sha256', repeat('ab', 32), 'kind', 'cac'));
  assert r->'docs'->0->>'name' = 'cac-certificate.pdf' and r->'docs'->0->>'kind' = 'cac' and r->'docs'->0->>'added_by_name' = 'Tunde Manager',
    'intake_reads: a document added';
  perform tests.throws(format($q$select public.practice_intake_doc_add(%L, jsonb_build_object('path', 'practice/%s/intake/%s/cac-certificate.pdf', 'sha256', repeat('ab', 32)))$q$,
    tests.id('kola'), pr, tests.id('kola')), '%already%');
  perform tests.throws(format($q$select public.practice_intake_doc_add(%L, jsonb_build_object('path', 'practice/%s/intake/%s/x.pdf', 'sha256', repeat('ab', 32)))$q$,
    tests.id('kola'), pr, tests.id('zenith')), '%intake''s folder%');
  perform tests.throws(format($q$select public.practice_intake_doc_add(%L, jsonb_build_object('path', 'practice/%s/intake/%s/y.pdf', 'sha256', 'abc'))$q$,
    tests.id('kola'), pr, tests.id('kola')), '%SHA-256%');
  r := public.practice_intake(tests.id('kola'));
  assert jsonb_array_length(r->'people') = 2 and r->'people'->0->>'name' = 'Kola Ade' and r->'people'->0->>'id_last4' is null
     and jsonb_array_length(r->'docs') = 1 and r ? 'hits' and r->>'legal_name' = 'Kola Ventures Nigeria Ltd' and r->'letters' = '[]',
    'intake_reads: one intake in full';
  perform tests.as_user(tests.id('staff'));
  perform tests.throws(format('select public.practice_intakes(%L)', pr), '%partners and managers%');
  perform tests.throws(format('select public.practice_intake(%L)', tests.id('kola')), '%partners and managers%');
  perform tests.as_user(tests.id('other_partner'));
  perform tests.throws(format('select public.practice_intake(%L)', tests.id('kola')), '%not on this practice%');
  perform tests.throws(format('select public.practice_conflict_run(%L)', tests.id('kola')), '%not on this practice%');
  perform tests.as_postgres();
end $$;

-- test: practice_files
-- Practice files in the documents bucket: intake and letter files for the practice's people, exports for its partners.
do $$
declare pr uuid := tests.id('pr'); i uuid := tests.id('ola_intake'); v_intake text; v_export text;
begin
  v_intake := 'practice/' || pr || '/intake/' || i || '/cac.pdf';
  v_export := 'practice/' || pr || '/exports/' || tests.id('ola_client') || '/records.zip';
  perform tests.as_definer(tests.id('partner'));
  assert private.practice_file_ok('practice/' || pr || '/intake/' || i || '/cac.pdf'), 'practice_files';
  assert private.practice_file_ok('practice/' || pr || '/letters/' || i || '/letter.pdf') and private.practice_file_ok(v_export), 'practice_files: a partner, every area';
  assert not private.practice_file_ok('practice/' || pr || '/other/x.pdf') and not private.practice_file_ok('practice/' || pr || '/intake/')
     and not private.practice_file_ok('practice/not-a-practice/intake/x/y.pdf') and not private.practice_file_ok(pr || '/intake/x/y.pdf')
     and not private.practice_file_ok(null), 'practice_files: only practice areas';
  perform tests.as_definer(tests.id('staff'));
  assert private.practice_file_ok(v_intake) and not private.practice_file_ok(v_export), 'practice_files: staff, not exports';
  perform tests.as_definer(tests.id('manager'));
  assert not private.practice_file_ok(v_export), 'practice_files: managers, not exports';
  perform tests.as_definer(tests.id('other_partner'));
  assert not private.practice_file_ok(v_intake), 'practice_files: another practice''s partner';
  assert private.practice_file_ok('practice/' || tests.id('pr2') || '/intake/' || i || '/x.pdf'), 'practice_files: their own practice';
  perform tests.as_postgres();
  update practice_members set status = 'disabled' where id = tests.id('staff_pm');
  perform tests.as_definer(tests.id('staff'));
  assert not private.practice_file_ok(v_intake), 'practice_files: not once they have left';
  perform tests.as_postgres();
  update practice_members set status = 'active' where id = tests.id('staff_pm');

  -- Through the documents bucket's policies, as the signed-in person (Supabase grants the table; the policies decide).
  grant select, insert, delete on storage.objects to authenticated;
  perform tests.as_user(tests.id('partner'));
  assert tests.error_of(format($q$insert into storage.objects (bucket_id, name) values ('documents', 'practice/%s/intake/%s/cac.pdf')$q$, pr, i)) is null,
    'practice_files: partner uploads as authenticated through the policy';
  assert (select count(*) from storage.objects where name = v_intake) = 1, 'practice_files: and reads it';
  perform tests.as_user(tests.id('staff'));
  assert (select count(*) from storage.objects where name = v_intake) = 1, 'practice_files: staff read it';
  assert tests.error_of(format($q$insert into storage.objects (bucket_id, name) values ('documents', %L)$q$, v_export)) like '%row-level security%',
    'practice_files: staff cannot put exports';
  perform tests.as_user(tests.id('other_partner'));
  assert (select count(*) from storage.objects where name = v_intake) = 0, 'practice_files: another practice does not see it';
  assert tests.error_of(format($q$insert into storage.objects (bucket_id, name) values ('documents', 'practice/%s/intake/%s/x.pdf')$q$, pr, i)) like '%row-level security%',
    'practice_files: another practice cannot upload';
  perform tests.as_user(tests.id('partner'));
  delete from storage.objects where name = v_intake;
  perform tests.as_postgres();
  assert (select count(*) from storage.objects where name = v_intake) = 1, 'practice_files: no one deletes them';
  assert has_function_privilege('authenticated', 'private.practice_file_ok(text)', 'execute') and not has_function_privilege('anon', 'private.practice_file_ok(text)', 'execute'),
    'practice_files: policy helper granted to authenticated only';
  assert (select prosecdef from pg_proc where oid = 'private.practice_file_ok(text)'::regprocedure), 'practice_files: it reads the practice as its owner';
  revoke select, insert, delete on storage.objects from authenticated;
end $$;

-- test: intake_retention
-- Due-diligence records cannot be deleted until their date (at least five years after the engagement ends).
do $$
declare i uuid := tests.id('kola'); b uuid := tests.id('babatunde');
begin
  assert private.retain_date(3) = (current_date + interval '5 years')::date and private.retain_date(7) = (current_date + interval '7 years')::date,
    'intake_retention: at least 5 years';
  assert private.retain_date(null) = (current_date + interval '5 years')::date, 'intake_retention: five by default';
  perform tests.throws(format($q$delete from practice_intakes where id = %L$q$, i), '%kept until%');
  perform tests.throws(format($q$delete from practice_intake_people where intake_id = %L$q$, i), '%kept until%');
  perform tests.throws(format($q$delete from practice_intake_docs where intake_id = %L$q$, i), '%kept until%');
  perform tests.throws(format($q$delete from practice_intakes where id = %L$q$, b), '%kept until ' || to_char(private.retain_date(5), 'DD Mon YYYY') || '%');
  perform tests.throws(format($q$delete from practices where id = %L$q$, tests.id('pr2')), '%kept until%');
  assert (select count(*) from practice_intake_people where intake_id = i) = 2 and (select count(*) from practice_intake_docs where intake_id = i) = 1,
    'intake_retention: all kept';
  -- Once the date has come, the intake goes with its people and documents.
  update practice_intakes set retain_until = current_date where id = i;
  delete from practice_intakes where id = i;
  assert not exists (select 1 from practice_intakes where id = i) and not exists (select 1 from practice_intake_people where intake_id = i)
     and not exists (select 1 from practice_intake_docs where intake_id = i), 'intake_retention: gone after the date';
end $$;

-- test: intake_outlives_business
-- A business deleted for good by a TaxStreem admin: the practice's due-diligence record of it stays, unlinked.
do $$
declare x uuid := tests.id('linked_intake'); v_admin uuid;
begin
  v_admin := tests.admin_user('dd.admin@example.test');
  perform tests.as_user(v_admin, 'aal2');
  perform public.admin_business_delete(tests.id('linked'), 'Linked Biz Ltd');
  perform tests.as_postgres();
  assert not exists (select 1 from orgs where id = tests.id('linked')), 'intake_outlives_business: the business is gone';
  assert (select org_id is null and client_id is null and legal_name = 'Linked Biz Ltd' from practice_intakes where id = x), 'intake_outlives_business: the record stays';
end $$;

-- test: intake_helpers_revoked
do $$
declare f text;
begin
  foreach f in array array['private.fold_name(text)', 'private.norm_id(text)', 'private.has_id_number(text)', 'private.uuid_of(text)', 'private.intake_cleared(practice_intakes)',
    'private.retain_date(integer)', 'private.conflict_scan(uuid)', 'private.intake_json(practice_intakes, boolean)', 'private.intake_require(uuid, boolean)',
    'private.intake_settle(uuid)', 'private.practice_intakes_retention()', 'private.practice_clients_intake()', 'private.activity_exempt()'] loop
    assert not has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute'), format('intake_helpers_revoked: %s', f);
  end loop;
  foreach f in array array['public.practice_intake_save(uuid, jsonb)', 'public.practice_intake(uuid)', 'public.practice_intakes(uuid, jsonb)',
    'public.practice_intake_doc_add(uuid, jsonb)', 'public.practice_opposing_save(uuid, jsonb)', 'public.practice_conflict_run(uuid)',
    'public.practice_conflict_decide(uuid, jsonb)', 'public.practice_set_conflict_scan(uuid, boolean)', 'public.practice_intake_declare(uuid, jsonb)'] loop
    assert has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute'), format('intake_helpers_revoked: %s for signed-in people', f);
  end loop;
  foreach f in array array['public.practice_intakes', 'public.practice_intake_people', 'public.practice_intake_docs', 'public.practice_opposing_parties',
    'public.practice_conflict_hits'] loop
    assert not has_table_privilege('authenticated', f, 'select') and not has_table_privilege('anon', f, 'select')
       and not has_table_privilege('authenticated', f, 'insert') and (select relrowsecurity from pg_class where oid = f::regclass),
      format('intake_helpers_revoked: table %s', f);
  end loop;
  assert 'practice_intakes' = any (private.activity_exempt()), 'intake_helpers_revoked: intakes are the practice''s, not the business''s';
  -- The triggers write the practice's records whoever changes a client link.
  assert (select bool_and(prosecdef) from pg_proc where oid in ('private.practice_intakes_retention()'::regprocedure, 'private.practice_clients_intake()'::regprocedure)),
    'intake_helpers_revoked: trigger functions are security definer';
end $$;

rollback;
