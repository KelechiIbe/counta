-- The admin portal's mandates page and the last fixes of the full mandate: an approved handover is no longer a handover
-- review; a 'handover' flag is decided through the identity review while its handover waits; the admin read carries each
-- handover flag's identity and the mandates setting; admins edit the extra free-mail domains; the admin businesses list
-- marks full-mandate, kept and handed-over-in-review businesses; a letter whose stored file changed is recorded.
begin;

do $$
declare v_partner uuid; v_pr uuid;
begin
  v_partner := tests.remember('partner', tests.user('partner@adm.example.test', 'Femi Partner'));
  v_pr := tests.remember('pr', tests.practice(v_partner, 'Admin View Partners', true));
  perform tests.remember('admin', tests.admin_user('admin12@example.test'));
  perform tests.remember('reviewer', tests.user('reviewer12@example.test'));
  insert into platform_reviewers (user_id) values (tests.id('reviewer'));
  perform tests.remember('someone', tests.user('someone12@example.test', 'Some One'));
  perform tests.hooks_on();
end $$;

-- Puts a business into a handover review as practice_handover_accept leaves it, with its open 'handover' flag.
create function pg_temp.in_handover_review(p_client uuid, p_before text) returns uuid language plpgsql as $f$
declare o uuid; f uuid;
begin
  o := (select org_id from practice_clients where id = p_client);
  update orgs set managed_by = null, identity_status = 'review',
    identity = coalesce(identity, '{}'::jsonb) || jsonb_build_object('reason', 'handover', 'handover', jsonb_build_object('id', gen_random_uuid(), 'at', now(), 'status_before', p_before))
  where id = o;
  insert into practice_mandate_flags (practice_id, client_id, kind, detail)
  values ((select practice_id from practice_clients where id = p_client), p_client, 'handover',
    jsonb_build_object('org_id', o, 'reason', 'not_director', 'identity_before', p_before))
  returning id into f;
  return f;
end $f$;

-- test: approved_handover_drops_reason
-- Approving a handover of a business confirmed before it opens payments and drops the reason, keeping the handover's own
-- record: a later NIN slip of the business is an ordinary review, not a handover one.
do $$
declare c uuid; o uuid; f uuid;
begin
  c := tests.full_client(tests.id('pr'), tests.id('partner'));
  o := (select org_id from practice_clients where id = c);
  f := pg_temp.in_handover_review(c, 'verified');
  assert private.handover_pending('review', (select identity from orgs where id = o)), 'approved_handover_drops_reason: pending before';
  perform tests.as_user(tests.id('reviewer'), 'aal2');
  assert public.review_identity(o, true, null)->>'status' = 'approved', 'approved_handover_drops_reason: approved';
  perform tests.as_postgres();
  assert (select identity_status = 'approved' and not identity ? 'reason' and identity->'handover'->>'status_before' = 'verified' from orgs where id = o),
    'approved_handover_drops_reason: reason gone, record kept';
  assert (select resolved_at is not null from practice_mandate_flags where id = f), 'approved_handover_drops_reason: flag resolved';
  -- A later slip in review is not a handover.
  update orgs set identity_status = 'review' where id = o;
  assert not private.handover_pending('review', (select identity from orgs where id = o)), 'approved_handover_drops_reason: a later slip is ordinary';
  -- A rejection keeps the reason (TaxStreem decides again).
  c := tests.full_client(tests.id('pr'), tests.id('partner'));
  o := (select org_id from practice_clients where id = c);
  perform pg_temp.in_handover_review(c, 'verified');
  perform tests.as_user(tests.id('reviewer'), 'aal2');
  perform public.review_identity(o, false, 'Not the owner on our records');
  perform tests.as_postgres();
  assert (select identity_status = 'rejected' and identity->>'reason' = 'handover' from orgs where id = o), 'approved_handover_drops_reason: rejected keeps it';
  perform tests.as_user(tests.id('reviewer'), 'aal2');
  assert public.review_identity(o, true, 'Owner confirmed in person')->>'status' = 'approved', 'approved_handover_drops_reason: decided again';
  perform tests.as_postgres();
  assert (select not identity ? 'reason' from orgs where id = o), 'approved_handover_drops_reason: dropped after deciding again';
end $$;

-- test: handover_flag_waits_for_review
-- A 'handover' flag is refused by hand while its handover waits for TaxStreem or was rejected; once it is decided (or the
-- business is no longer in a handover review) it can be resolved by hand.
do $$
declare c uuid; o uuid; f uuid;
begin
  c := tests.full_client(tests.id('pr'), tests.id('partner'));
  o := (select org_id from practice_clients where id = c);
  f := pg_temp.in_handover_review(c, 'pending');
  perform tests.as_user(tests.id('reviewer'), 'aal2');
  perform tests.throws(format('select public.admin_mandate_flag_resolve(%L, %L)', f, 'Looked at it'), 'P0001: Decide the handover in the identity reviews instead.');
  perform public.review_identity(o, false, 'Could not reach the owner');
  perform tests.throws(format('select public.admin_mandate_flag_resolve(%L, %L)', f, 'Looked at it'), '%identity reviews%');
  -- Approved back to the ordinary check: the review resolved the flag already.
  assert public.review_identity(o, true, 'Reached the owner')->>'status' = 'pending', 'handover_flag_waits_for_review: back to pending';
  perform tests.throws(format('select public.admin_mandate_flag_resolve(%L, %L)', f, 'Looked at it'), '%resolved already%');
  perform tests.as_postgres();
  -- A handover flag on a business no longer waiting (say the flag was raised again by hand) resolves.
  insert into practice_mandate_flags (practice_id, client_id, kind, detail)
  values (tests.id('pr'), c, 'handover', jsonb_build_object('org_id', o, 'reason', 'not_director')) returning id into f;
  perform tests.as_user(tests.id('reviewer'), 'aal2');
  assert public.admin_mandate_flag_resolve(f, 'Already decided in review')->>'id' = f::text, 'handover_flag_waits_for_review: resolves once decided';
  perform tests.as_postgres();
end $$;

-- test: admin_mandates_identity_and_settings
-- Each open handover flag carries the business's identity now; the mandates setting is read with it (empty by default).
do $$
declare c uuid; o uuid; f uuid; x jsonb; r jsonb;
begin
  c := tests.full_client(tests.id('pr'), tests.id('partner'));
  o := (select org_id from practice_clients where id = c);
  f := pg_temp.in_handover_review(c, 'verified');
  perform tests.as_user(tests.id('reviewer'), 'aal2');
  r := public.admin_mandates();
  select v into x from jsonb_array_elements(r->'flags') v where v->>'id' = f::text;
  assert x->'identity' = '{"status": "review", "pending": true, "status_before": "verified"}'::jsonb, format('admin_mandates_identity_and_settings: identity, got %s', x->'identity');
  assert r->'settings' = '{"free_mail_domains": []}'::jsonb, format('admin_mandates_identity_and_settings: settings, got %s', r->'settings');
  -- Other flags carry no identity.
  perform tests.as_postgres();
  insert into practice_mandate_flags (practice_id, kind, detail) values (tests.id('pr'), 'duplicate_company', '{"rc_number":"RC 1"}') returning id into f;
  perform tests.as_user(tests.id('reviewer'), 'aal2');
  select v into x from jsonb_array_elements(public.admin_mandates()->'flags') v where v->>'id' = f::text;
  assert x ? 'identity' and x->'identity' = 'null'::jsonb, 'admin_mandates_identity_and_settings: none for other flags';
  perform tests.as_postgres();
end $$;

-- test: mandate_settings_save
-- Admins set the extra free-mail domains: trimmed, lower case, without @, no duplicates or blanks; anything else refused.
-- An address on one of them is no longer the firm's. Reviewers and others cannot.
do $$
declare r jsonb;
begin
  perform tests.as_user(tests.id('admin'), 'aal2');
  r := public.admin_mandate_settings_save('{"free_mail_domains":[" @Mail.Example.COM ","mail.example.com","","post.example.ng"]}');
  assert r->'free_mail_domains' = '["mail.example.com", "post.example.ng"]'::jsonb, format('mandate_settings_save: cleaned, got %s', r);
  assert public.admin_mandates()->'settings'->'free_mail_domains' = '["mail.example.com", "post.example.ng"]'::jsonb, 'mandate_settings_save: read back';
  perform tests.throws($q$select public.admin_mandate_settings_save('{"free_mail_domains":["not a domain"]}')$q$, '%is not a domain name%');
  perform tests.throws($q$select public.admin_mandate_settings_save('{"free_mail_domains":"mail.example.com"}')$q$, '%as a list%');
  perform tests.throws(format('select public.admin_mandate_settings_save(%L)', jsonb_build_object('free_mail_domains', (select jsonb_agg('d' || g || '.example.com') from generate_series(1, 201) g))),
    '%At most 200%');
  perform tests.as_postgres();
  assert 'post.example.ng' = any (private.free_mail_domains()) and 'gmail.com' = any (private.free_mail_domains()), 'mandate_settings_save: in use';
  assert exists (select 1 from admin_audit where action = 'save_mandates' and user_id = tests.id('admin')), 'mandate_settings_save: audited';
  -- The firm's people on that domain no longer make it the firm's.
  update practice_members set email = 'femi@post.example.ng' where practice_id = tests.id('pr') and user_id = tests.id('partner');
  assert private.firm_email(tests.id('pr'), 'someone.else@post.example.ng') is null, 'mandate_settings_save: free-mail is not the firm''s domain';
  perform tests.as_user(tests.id('reviewer'), 'aal2');
  perform tests.throws($q$select public.admin_mandate_settings_save('{"free_mail_domains":[]}')$q$, '42501: %only for TaxStreem%');
  perform tests.as_user(tests.id('someone'));
  perform tests.throws($q$select public.admin_mandate_settings_save('{"free_mail_domains":[]}')$q$, '42501: %');
  perform tests.as_postgres();
end $$;

-- test: admin_businesses_mandate
-- The admin list marks a business run under full mandate (with the practice), one kept read-only, and one whose handover
-- waits; an ordinary business has none.
do $$
declare c uuid; o uuid; c2 uuid; o2 uuid; o3 uuid; rows jsonb;
begin
  c := tests.full_client(tests.id('pr'), tests.id('partner'), 'Mandated Pens Ltd');
  o := (select org_id from practice_clients where id = c);
  c2 := tests.full_client(tests.id('pr'), tests.id('partner'), 'Kept Inks Ltd');
  o2 := (select org_id from practice_clients where id = c2);
  update practice_clients set status = 'ended', end_kind = 'ended', ended_at = now() where id = c2;
  update orgs set read_only_at = now(), retain_until = current_date + 1825 where id = o2;
  o3 := tests.org(tests.id('someone'), 'Ordinary Paper Ltd');
  perform tests.as_user(tests.id('admin'), 'aal2');
  rows := public.admin_businesses(null, 'all', 200, 0)->'rows';
  perform tests.as_postgres();
  assert (select x->'mandate' = jsonb_build_object('practice', 'Admin View Partners', 'read_only_at', null, 'retain_until', null, 'handover_review', false)
          from jsonb_array_elements(rows) x where x->>'id' = o::text), 'admin_businesses_mandate: full mandate';
  assert (select x->'mandate'->>'practice' = 'Admin View Partners' and x->'mandate'->>'read_only_at' is not null and x->'mandate'->>'retain_until' = (current_date + 1825)::text
          from jsonb_array_elements(rows) x where x->>'id' = o2::text), 'admin_businesses_mandate: kept read-only';
  assert (select x->'mandate' = 'null'::jsonb from jsonb_array_elements(rows) x where x->>'id' = o3::text), 'admin_businesses_mandate: ordinary';
end $$;

-- test: letter_changed_recorded
-- The practice function records a letter whose stored file changed: an event with the fingerprint found, and the firm's
-- leads told once a day. Only the service role calls it.
do $$
declare v_intake uuid; l uuid; n int;
begin
  v_intake := tests.cleared_intake(tests.id('pr'), 'Changed Letter Ltd', 'involved');
  perform tests.as_user(tests.id('partner'));
  l := (public.practice_letter_draft(v_intake, '{}')->>'id')::uuid;
  perform tests.as_service();
  assert public.svc_letter_changed(l, upper(repeat('ef', 32)), '203.0.113.7', 'Test browser') = '{"ok": true}'::jsonb, 'letter_changed_recorded: ok';
  perform public.svc_letter_changed(l, 'not a hash', '203.0.113.7', 'Test browser');
  assert public.svc_letter_changed(gen_random_uuid(), repeat('ef', 32), null, null)->>'reason' = 'not_found', 'letter_changed_recorded: unknown letter';
  perform tests.as_postgres();
  assert (select count(*) from engagement_letter_events where letter_id = l and kind = 'document_changed') = 2, 'letter_changed_recorded: two events';
  assert (select detail->>'found' = repeat('ef', 32) and ip = '203.0.113.7' from engagement_letter_events where letter_id = l and kind = 'document_changed' order by id limit 1),
    'letter_changed_recorded: fingerprint and address';
  assert (select detail->'found' = 'null'::jsonb from engagement_letter_events where letter_id = l and kind = 'document_changed' order by id desc limit 1),
    'letter_changed_recorded: a malformed fingerprint is not kept';
  select count(*) into n from notifications where user_id = tests.id('partner') and title = 'An engagement letter could not be signed';
  assert n = 1, format('letter_changed_recorded: told once, got %s', n);
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format('select public.svc_letter_changed(%L, %L, null, null)', l, repeat('ef', 32)), '42501: %');
  perform tests.as_postgres();
end $$;

rollback;
