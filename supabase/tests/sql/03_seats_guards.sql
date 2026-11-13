-- Seats and guards: the practice link gives the firm's people their places (admin acting as owner under full mandate, an
-- accountant's place when involved), departed staff lose every place in one call, a business under full mandate keeps out
-- everyone else, the admin kill switch, identity for a business with no CAC record, and the business profile for a
-- business the firm runs.
begin;

-- Fixture: a verified practice (partner, manager, staff) running a business under full mandate and involved with an
-- ordinary business (owner, admin); a second, unverified practice.
do $$
declare v_partner uuid; v_manager uuid; v_pstaff uuid; v_owner uuid; v_admin uuid; v_pr uuid; v_o uuid; v_ord uuid; v_other uuid;
begin
  v_partner := tests.remember('partner', tests.user('sg.partner@firm.example.test', 'Ngozi Partner'));
  v_manager := tests.remember('manager', tests.user('sg.manager@firm.example.test', 'Tunde Manager'));
  v_pstaff := tests.remember('pstaff', tests.user('sg.pstaff@firm.example.test', 'Bola Staff'));
  v_owner := tests.remember('owner', tests.user('sg.owner@example.test', 'Ada Owner'));
  v_admin := tests.remember('admin', tests.user('sg.admin@example.test', 'Femi Admin'));
  v_other := tests.remember('other', tests.user('sg.other@other.example.test', 'Kemi Other'));
  v_pr := tests.remember('pr', tests.practice(v_partner, 'Seat Partners', true));
  perform tests.remember('partner_pm', (select id from practice_members where practice_id = v_pr and user_id = v_partner));
  perform tests.remember('manager_pm', tests.practice_member(v_pr, v_manager, 'manager'));
  perform tests.remember('staff_pm', tests.practice_member(v_pr, v_pstaff, 'staff'));
  perform tests.remember('unverified_pr', tests.practice(v_other, 'Unverified Partners', false));
  perform tests.remember('other_pm', (select id from practice_members where practice_id = tests.id('unverified_pr') and user_id = v_other));
  v_o := tests.remember('o', tests.managed_org(v_pr, 'Seat Managed Ltd'));
  perform tests.remember('c', (private.mandate(v_o)).id);
  perform tests.remember('partner_seat', (select id from members where org_id = v_o and user_id = v_partner));
  perform tests.remember('manager_seat', (select id from members where org_id = v_o and user_id = v_manager));
  -- The manager's place is the newer one, so "the oldest acting place" is the partner's.
  update members set created_at = created_at + interval '1 minute' where id = tests.id('manager_seat');
  v_ord := tests.remember('ord', tests.org(v_owner, 'Seat Ordinary Ltd'));
  perform tests.remember('admin_seat', tests.member(v_ord, v_admin, 'admin'));
  perform tests.remember('ic', tests.involved_client(v_pr, v_ord));
  perform tests.as_postgres();
end $$;

-- test: sync_full_seats
-- The business has narrowed what admins may do; the firm's places still carry every permission. An assigned staff member
-- works the business as the others do; unassigned, their place is switched off and no longer acts as the owner.
do $$
declare o uuid := tests.id('o');
begin
  insert into role_permissions (org_id, role, perms) values (o, 'admin', '{"make_payments": false, "manage_team": false}');
  perform tests.as_user(tests.id('partner'));
  perform public.practice_assign(tests.id('c'), tests.id('staff_pm'), true);
  perform tests.as_postgres();
  assert (select role = 'admin' and acts_as_owner and p_make_payments and p_manage_team from members where org_id = o and user_id = tests.id('partner')),
    'sync_full_seats: admin, acting owner, all flags';
  assert (select count(*) from members where org_id = o and practice_id = tests.id('pr') and status = 'active' and role = 'admin' and acts_as_owner
            and perm_overrides = private.role_template('admin') and p_make_payments and p_manage_team and p_approve_payments and p_manage_settings) = 3,
    'sync_full_seats: the partner, the manager and the assigned staff member';
  perform tests.as_user(tests.id('partner'));
  perform public.practice_assign(tests.id('c'), tests.id('staff_pm'), false);
  perform tests.as_postgres();
  assert (select status = 'disabled' and not acts_as_owner from members where org_id = o and user_id = tests.id('pstaff')),
    'sync_full_seats: an unassigned staff member''s place is switched off and no longer acts as the owner';
  assert not private.acts_as_owner(o, tests.id('pstaff')), 'sync_full_seats: not the owner any more';
  perform tests.as_postgres();
end $$;

-- test: sync_involved_seats
do $$
begin
  assert (select role = 'accountant' and not acts_as_owner from members where org_id = tests.id('ord') and user_id = tests.id('partner')),
    'sync_involved_seats';
  assert (select status = 'active' and p_keep_books and p_file_tax and not p_make_payments and not p_manage_team
            from members where org_id = tests.id('ord') and user_id = tests.id('manager')),
    'sync_involved_seats: the accountant''s permissions';
  perform tests.as_postgres();
end $$;

-- test: seat_sync_not_left_on
do $$
begin
  perform tests.as_user(tests.id('partner'));
  perform public.practice_assign(tests.id('c'), tests.id('staff_pm'), true);
  assert coalesce(current_setting('counta.seat_sync', true), '') <> 'on', 'seat_sync_not_left_on';
  perform public.practice_assign(tests.id('c'), tests.id('staff_pm'), false);
  perform tests.as_postgres();
  perform private.practice_sync_seats(tests.id('ic'));
  assert coalesce(current_setting('counta.seat_sync', true), '') <> 'on', 'seat_sync_not_left_on: after a direct sync';
  perform tests.as_postgres();
end $$;

-- test: guard_blocks_seat_edits
do $$
declare o uuid := tests.id('o');
begin
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.update_member(%L, '{"role":"manager"}')$q$, tests.id('manager_seat')),
    '42501: Under full mandate the firm''s places change from the accountant portal.');
  perform tests.throws(format($q$select public.update_member(%L, '{"status":"disabled"}')$q$, tests.id('manager_seat')),
    '%change from the accountant portal%');
  -- What is not about the place itself still changes.
  perform public.update_member(tests.id('manager_seat'), '{"title": "Senior accountant"}');
  perform tests.as_postgres();
  assert (select title = 'Senior accountant' and role = 'admin' and acts_as_owner and status = 'active' from members where id = tests.id('manager_seat')),
    'guard_blocks_seat_edits: a title still changes';
  perform tests.throws(format($q$insert into members (org_id, email, display_name, role, status) values (%L, 'x@example.test', 'X', 'staff', 'active')$q$, o),
    '42501: Under full mandate only the firm''s people work in this business.');
  perform tests.throws(format($q$insert into members (org_id, email, display_name, role, status) values (%L, 'y@example.test', 'Y', 'staff', 'invited')$q$, o),
    '%only the firm''s people%');
  perform tests.throws(format($q$insert into members (org_id, email, display_name, role, status, practice_id) values (%L, 'z@example.test', 'Z', 'staff', 'active', %L)$q$,
    o, tests.id('unverified_pr')), '%only the firm''s people%');
  -- The firm's own place, made outside the seat sync.
  perform tests.throws(format($q$insert into members (org_id, email, display_name, role, status, practice_id) values (%L, 'w@firm.example.test', 'W', 'staff', 'active', %L)$q$,
    o, tests.id('pr')), '%change from the accountant portal%');
  perform tests.throws(format('update members set p_make_payments = false where id = %L', tests.id('partner_seat')), '%change from the accountant portal%');
  perform tests.throws(format('update members set perm_overrides = ''{}'' where id = %L', tests.id('partner_seat')), '%change from the accountant portal%');
  perform tests.throws(format('update members set user_id = %L where id = %L', tests.id('pstaff'), tests.id('partner_seat')), '%change from the accountant portal%');
  perform tests.throws(format('update members set acts_as_owner = true where id = %L', tests.id('admin_seat')), '42501: Only the practice link sets that.');
  perform tests.throws(format('update members set acts_as_owner = false where id = %L', tests.id('partner_seat')), '%Only the practice link sets that.%');
  -- Inside the seat sync the same changes go through.
  perform set_config('counta.seat_sync', 'on', true);
  update members set status = 'disabled' where id = tests.id('manager_seat');
  update members set status = 'active' where id = tests.id('manager_seat');
  perform set_config('counta.seat_sync', '', true);
  -- An ordinary business's team changes as before.
  perform tests.as_user(tests.id('owner'));
  perform public.update_member(tests.id('admin_seat'), '{"status": "disabled"}');
  perform tests.as_postgres();
  assert (select status = 'disabled' from members where id = tests.id('admin_seat')), 'guard_blocks_seat_edits: an ordinary business is untouched';
  perform tests.as_user(tests.id('owner'));
  perform public.update_member(tests.id('admin_seat'), '{"status": "active"}');
  perform tests.as_postgres();
end $$;

-- test: org_contact_acting_seat_only
-- Under full mandate the contact is the engagement partner's active acting place, never a place that does not act as the
-- owner or is switched off: then the oldest active acting place.
do $$
declare o uuid := tests.id('o');
begin
  assert (private.org_contact(o)).id = tests.id('partner_seat'), 'org_contact_acting_seat_only: the engagement partner';
  perform set_config('counta.seat_sync', 'on', true);
  update members set acts_as_owner = false where id = tests.id('partner_seat');
  perform set_config('counta.seat_sync', '', true);
  assert (private.org_contact(o)).id = tests.id('manager_seat'), 'org_contact_acting_seat_only: a place that does not act as the owner is not the contact';
  perform set_config('counta.seat_sync', 'on', true);
  update members set acts_as_owner = true, status = 'disabled' where id = tests.id('partner_seat');
  perform set_config('counta.seat_sync', '', true);
  assert (private.org_contact(o)).id = tests.id('manager_seat'), 'org_contact_acting_seat_only: a switched-off place is not the contact';
  perform private.practice_sync_seats(tests.id('c'));
  assert (private.org_contact(o)).id = tests.id('partner_seat'), 'org_contact_acting_seat_only: the sync brings the partner''s place back';
  perform tests.as_postgres();
end $$;

-- test: engagement_partner_is_lead
do $$
declare c uuid := tests.id('c');
begin
  perform tests.throws(format('update practice_clients set engagement_partner_id = %L where id = %L', tests.id('staff_pm'), c),
    '%engagement partner must be one of the firm''s active partners or managers%');
  perform tests.throws(format('update practice_clients set engagement_partner_id = %L where id = %L', tests.id('other_pm'), c),
    '%engagement partner must be one of the firm''s active partners or managers%');
  perform tests.throws(format($q$insert into practice_clients (practice_id, org_id, status, initiated_by, engagement_partner_id)
    values (%L, %L, 'ended', 'practice', %L)$q$, tests.id('pr'), tests.id('ord'), tests.id('staff_pm')), '%engagement partner%');
  update practice_clients set engagement_partner_id = tests.id('manager_pm') where id = c;
  assert (private.org_contact(tests.id('o'))).id = tests.id('manager_seat'), 'engagement_partner_is_lead: a manager may be the engagement partner';
  update practice_clients set engagement_partner_id = tests.id('partner_pm') where id = c;
  perform tests.as_postgres();
end $$;

-- test: managed_cannot_connect
do $$
declare o uuid := tests.id('o');
begin
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.business_invite_accountant(%L, '{"email":"acc@example.test"}')$q$, o),
    '42501: This business is run by its accountant under full mandate and cannot connect to another practice.');
  perform tests.throws(format($q$select public.practice_request_create(%L, '{"title":"Bank statement"}')$q$, tests.id('c')), '%Requests are not sent%');
  -- An involved client still gets requests.
  assert public.practice_request_create(tests.id('ic'), '{"title": "Bank statement"}') is not null, 'managed_cannot_connect: requests to an involved client';
  perform tests.as_postgres();
  -- Another practice's invitation, accepted for the business by its acting owner.
  insert into practice_clients (practice_id, status, initiated_by, invite_email, invite_name, token_hash, token_expires, created_by)
  values (tests.id('unverified_pr'), 'invited', 'practice', 'sg.partner@firm.example.test', 'Ngozi Partner',
    encode(extensions.digest('pc_' || repeat('cd', 24), 'sha256'), 'hex'), now() + interval '7 days', tests.id('other'));
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_accept('pc_' || repeat('cd', 24), jsonb_build_object('org_id', %L::uuid))$q$, o),
    '%cannot connect to another practice%');
  perform tests.as_postgres();
  perform tests.throws(format($q$insert into practice_clients (practice_id, org_id, status, initiated_by) values (%L, %L, 'requested', 'business')$q$,
    tests.id('unverified_pr'), o), '%cannot connect to another practice%');
  -- A past link with another practice is not a connection.
  insert into practice_clients (practice_id, org_id, status, initiated_by) values (tests.id('unverified_pr'), o, 'declined', 'business');
  assert not exists (select 1 from practice_clients where org_id = o and practice_id is distinct from tests.id('pr') and status in ('invited', 'requested', 'active')),
    'managed_cannot_connect: no other practice connected';
  perform tests.as_postgres();
end $$;

-- test: blocked_under_full_mandate
do $$
declare o uuid := tests.id('o');
begin
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.invite_member(%L, 'X', 'x@example.test', 'staff')$q$, o),
    '42501: Under full mandate this is done from the accountant portal.');
  perform tests.throws(format($q$select public.subscription_start(%L, '{}')$q$, o), '%done from the accountant portal%');
  perform tests.throws(format($q$select public.subscription_method(%L, '{"method": "card"}')$q$, o), '%done from the accountant portal%');
  perform tests.throws(format($q$select public.practice_end(%L)$q$, tests.id('c')), '%Use handover or end the mandate for a full-mandate client.%');
  perform tests.as_postgres();
  assert (select status = 'active' from practice_clients where id = tests.id('c')), 'blocked_under_full_mandate: the mandate still runs';
  perform tests.throws(format($q$insert into subscription_charges (org_id, plan_id, billing, amount, method, kind, tx_ref)
    values (%L, (select id from plans order by sort limit 1), 'month', 5000, 'card', 'start', 'SG-TEST-1')$q$, o), '%Under full mandate the practice pays for Counta.%');
  insert into subscription_charges (org_id, practice_id, plan_id, billing, amount, method, kind, tx_ref)
  values (o, tests.id('pr'), (select id from plans order by sort limit 1), 'month', 5000, 'card', 'start', 'SG-TEST-2');
  -- An ordinary business invites its team as before.
  perform tests.as_user(tests.id('owner'));
  assert public.invite_member(tests.id('ord'), 'Bisi Staff', 'bisi.staff@example.test', 'staff') is not null, 'blocked_under_full_mandate: an ordinary business invites';
  perform tests.as_postgres();
end $$;

-- test: nin_cac_required
-- With no CAC record the NIN would be matched against the person checking it, a firm person: CAC comes first. With the CAC
-- record, the NIN is matched against its directors as for any business.
do $$
declare v_o uuid; r jsonb;
begin
  v_o := tests.managed_org(tests.id('pr'), 'Seat Identity Ltd');
  perform tests.as_service();
  assert public.svc_identity_nin(tests.id('partner'), v_o, '1234', 'Ada', null, 'Eze')->>'reason' = 'cac_required', 'nin_cac_required';
  assert public.svc_identity_nin(tests.id('partner'), v_o, '1234', 'Ngozi', null, 'Partner') = '{"verified": false, "reason": "cac_required"}',
    'nin_cac_required: not even the firm person''s own name';
  perform tests.as_postgres();
  assert (select identity_status = 'pending' from orgs where id = v_o), 'nin_cac_required: still pending';
  insert into kyc_profiles (user_id, org_id, status, source, cac, submitted_at)
  values (tests.id('partner'), v_o, 'submitted', 'cac', '{"profile": {"classification": "COMPANY", "directors": [{"firstname": "ADA", "surname": "EZE"}]}}', now());
  perform tests.as_service();
  r := public.svc_identity_nin(tests.id('partner'), v_o, '1234', 'Ngozi', null, 'Partner');
  assert r->>'reason' = 'no_match', 'nin_cac_required: with CAC data the firm person''s name is not a director';
  r := public.svc_identity_nin(tests.id('partner'), v_o, '1234', 'Ada', null, 'Eze');
  assert (r->>'verified')::boolean and r->>'role' = 'director', 'nin_cac_required: with CAC data a director matches';
  perform tests.as_postgres();
  assert (select identity_status = 'verified' from orgs where id = v_o), 'nin_cac_required: verified';
  perform tests.as_postgres();
end $$;

-- test: kyc_for_managed_org
do $$
declare o uuid := tests.id('o'); r jsonb; v_orgs int;
begin
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.kyc_submit('{"org_id":"%s"}')$q$, tests.id('ord')), '42501: Only the owner submits the business profile.');
  perform tests.as_postgres();
  assert not exists (select 1 from kyc_profiles where org_id = tests.id('ord')), 'kyc_for_managed_org: nothing made for a business the caller does not own';
  perform tests.as_service();
  r := public.svc_kyc_store(tests.id('partner'), 'search', '{"query":"x"}', o);
  perform tests.as_postgres();
  assert r is not null and exists (select 1 from kyc_profiles where org_id = o), 'kyc_for_managed_org: profile bound to org';
  update kyc_profiles set source = 'manual', manual = '{"name": "Seat Managed Ltd", "address": "2 Test Street, Lagos", "state": "Lagos"}',
    answers = '{"offering": "goods", "category": "retail_food", "revenue_band": "0_50m", "receive_methods": ["bank_transfer"], "pay_methods": ["bank_transfer"], "reasons": ["tax_compliance"], "examples": ["flour"], "filing": {"vat": "always", "wht": "never", "cit": "always"}}'
  where org_id = o;
  v_orgs := (select count(*) from orgs where created_by = tests.id('partner'));
  perform tests.as_user(tests.id('partner'));
  r := public.kyc_submit(jsonb_build_object('org_id', o));
  perform tests.as_postgres();
  assert (r->>'org_id')::uuid = o and (select count(*) from orgs where created_by = tests.id('partner')) = v_orgs,
    'kyc_for_managed_org: the business the firm runs, no new business';
  assert (select status = 'submitted' and user_id = tests.id('partner') from kyc_profiles where org_id = o), 'kyc_for_managed_org: submitted for it';
  assert (select address = '2 Test Street, Lagos' and managed_by = tests.id('pr') and identity_status = 'pending' from orgs where id = o),
    'kyc_for_managed_org: the business row';
  perform tests.as_postgres();
end $$;

-- test: practice_can_full
do $$
begin
  assert private.practice_can_full(tests.id('pr')), 'practice_can_full: verified partner';
  update practices set mandate_suspended_at = now() where id = tests.id('pr');
  assert not private.practice_can_full(tests.id('pr')), 'practice_can_full: suspended';
  update practices set mandate_suspended_at = null where id = tests.id('pr');
  assert not private.practice_can_full(tests.id('unverified_pr')), 'practice_can_full: unverified';
  assert not private.practice_can_full(gen_random_uuid()), 'practice_can_full: unknown practice';
  perform tests.as_postgres();
end $$;

-- test: departed_staff_disabled
-- A business the firm stopped running without a handover keeps its engagement partner's place (here the manager's). The
-- partner then switches the manager off: every place of theirs, in every client, goes in that one call.
do $$
declare v_o2 uuid; v_c2 uuid;
begin
  v_o2 := tests.managed_org(tests.id('pr'), 'Seat Ended Ltd');
  v_c2 := (private.mandate(v_o2)).id;
  update practice_clients set engagement_partner_id = tests.id('manager_pm'), status = 'ended', ended_at = now(), end_kind = 'ended' where id = v_c2;
  perform private.practice_sync_seats(v_c2);
  assert (select status = 'active' and acts_as_owner from members where org_id = v_o2 and user_id = tests.id('manager')),
    'departed_staff_disabled: the engagement partner keeps the ended business';
  assert (select status = 'disabled' and not acts_as_owner from members where org_id = v_o2 and user_id = tests.id('partner')),
    'departed_staff_disabled: the others'' places are switched off';
  assert (select count(*) from members where user_id = tests.id('manager') and status = 'active' and practice_id = tests.id('pr')
            and org_id in (tests.id('o'), tests.id('ord'), v_o2)) = 3,
    'departed_staff_disabled: before, the manager works in the running, the involved and the ended business';
  perform tests.as_user(tests.id('partner'));
  perform public.practice_update_member(tests.id('manager_pm'), '{"status": "disabled"}');
  perform tests.as_postgres();
  assert not exists (select 1 from members where user_id = tests.id('manager') and status = 'active' and practice_id = tests.id('pr')), 'departed_staff_disabled: every client seat';
  assert not exists (select 1 from members where user_id = tests.id('manager') and acts_as_owner), 'departed_staff_disabled: no place acts as the owner';
  assert not private.acts_as_owner(tests.id('o'), tests.id('manager')) and not private.acts_as_owner(v_o2, tests.id('manager')),
    'departed_staff_disabled: not the owner anywhere';
  assert (private.org_contact(v_o2)).id is null, 'departed_staff_disabled: the ended business has no contact left';
  assert (select count(*) from members where user_id = tests.id('partner') and status = 'active' and practice_id = tests.id('pr')
            and org_id in (tests.id('o'), tests.id('ord'))) = 2,
    'departed_staff_disabled: the partner keeps the running ones';
  perform tests.as_postgres();
end $$;

-- test: new_helpers_revoked
do $$
begin
  assert not has_function_privilege('authenticated', 'private.require_not_managed(uuid)', 'execute')
     and not has_function_privilege('authenticated', 'private.practice_can_full(uuid)', 'execute')
     and not has_function_privilege('authenticated', 'private.members_mandate_guard()', 'execute')
     and not has_function_privilege('authenticated', 'private.practice_clients_guard()', 'execute')
     and not has_function_privilege('authenticated', 'private.practice_requests_guard()', 'execute')
     and not has_function_privilege('authenticated', 'private.subscription_charges_guard()', 'execute')
     and not has_function_privilege('anon', 'private.require_not_managed(uuid)', 'execute')
     and not has_function_privilege('anon', 'private.practice_can_full(uuid)', 'execute'), 'new_helpers_revoked';
  assert not has_function_privilege('authenticated', 'private.practice_sync_seats(uuid)', 'execute')
     and not has_function_privilege('authenticated', 'private.org_contact(uuid)', 'execute'), 'new_helpers_revoked: redefined helpers';
  perform tests.as_postgres();
end $$;

rollback;
