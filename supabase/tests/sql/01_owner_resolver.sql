-- The owner resolver: acting owners, businesses under full mandate, the business's contact, and create_org's core.
begin;

-- Shared fixture: an ordinary business (owner, staff) and a practice (partner, manager, staff).
do $$
declare v_partner uuid; v_manager uuid; v_pstaff uuid; v_owner uuid; v_staff uuid; v_pr uuid; v_ord uuid;
begin
  v_partner := tests.remember('partner', tests.user('or.partner@example.test', 'Ngozi Partner'));
  v_manager := tests.remember('manager', tests.user('or.manager@example.test', 'Tunde Manager'));
  v_pstaff := tests.remember('pstaff', tests.user('or.pstaff@example.test', 'Bola Staff'));
  v_owner := tests.remember('owner', tests.user('or.owner@example.test', 'Ada Owner'));
  v_staff := tests.remember('staff', tests.user('or.staff@example.test', 'Femi Staff'));
  v_pr := tests.remember('pr', tests.practice(v_partner, 'Resolver Partners', true));
  perform tests.remember('manager_pm', tests.practice_member(v_pr, v_manager, 'manager'));
  perform tests.practice_member(v_pr, v_pstaff, 'staff');
  v_ord := tests.remember('ord', tests.org(v_owner, 'Ordinary Resolver Ltd'));
  perform tests.member(v_ord, v_staff, 'staff');
  perform tests.as_postgres();
end $$;

-- test: acts_as_owner_check
-- Inside counta.seat_sync = 'on', so once the members guard of a later task exists the CHECK constraint is still what fires.
do $$
begin
  perform set_config('counta.seat_sync', 'on', true);
  perform tests.throws(format($q$insert into members (org_id, email, display_name, role, status, practice_id, acts_as_owner)
    values (%L, 'aao.one@example.test', 'Aao One', 'accountant', 'active', %L, true)$q$, tests.id('ord'), tests.id('pr')),
    '23514%members_acts_as_owner_check%');
  perform tests.throws(format($q$insert into members (org_id, email, display_name, role, status, acts_as_owner)
    values (%L, 'aao.two@example.test', 'Aao Two', 'admin', 'active', true)$q$, tests.id('ord')),
    '23514%members_acts_as_owner_check%');
  perform set_config('counta.seat_sync', '', true);
  perform tests.as_postgres();
end $$;

-- A business the practice runs under full mandate. The manager's seat is made a minute later than the partner's.
do $$
begin
  perform tests.remember('o', tests.managed_org(tests.id('pr')));
  update members set created_at = created_at + interval '1 minute' where org_id = tests.id('o') and user_id = tests.id('manager');
  perform tests.as_postgres();
end $$;

-- test: managed_org_fixture
do $$
begin
  assert (select count(*) from members where org_id = tests.id('o') and acts_as_owner and role = 'admin' and status = 'active'
            and practice_id = tests.id('pr') and p_make_payments and p_manage_team and p_record_sales and p_see_margins) = 2
     and not exists (select 1 from members where org_id = tests.id('o') and (user_id = tests.id('pstaff') or role = 'owner')),
    'managed_org_fixture: an acting-owner admin seat for the partner and the manager, no owner, none for staff';
  assert (select managed_by = tests.id('pr') and identity_status = 'pending' and email = 'books@firm.example.test'
            and created_by = tests.id('partner') from orgs where id = tests.id('o')),
    'managed_org_fixture: the business row';
  assert coalesce(current_setting('counta.seat_sync', true), '') = '', 'managed_org_fixture: seat sync switched off again';
  perform tests.as_postgres();
end $$;

-- test: perm_of_acting_owner
do $$
declare seat members; plain members;
begin
  select * into seat from members where org_id = tests.id('o') and user_id = tests.id('partner');
  assert private.perm_of(seat, 'owner') and private.perm_of(seat, 'make_payments') and private.perm_of(seat, 'manage_team'),
    'perm_of_acting_owner: owner and all flags';
  select * into plain from members where org_id = tests.id('ord') and user_id = tests.id('staff');
  assert not private.perm_of(plain, 'owner') and not private.perm_of(plain, 'make_payments'),
    'perm_of_acting_owner: an ordinary staff member is not the owner';
  plain.acts_as_owner := false; plain.role := 'admin'; plain.p_make_payments := true;
  assert not private.perm_of(plain, 'owner') and private.perm_of(plain, 'make_payments'),
    'perm_of_acting_owner: an admin who does not act as owner has the flags but not owner';
  perform tests.as_postgres();
end $$;

-- test: is_owner_acting
do $$
begin
  perform tests.as_user(tests.id('partner'));
  assert private.is_owner(tests.id('o')), 'is_owner_acting: acting owner counts';
  assert not private.is_owner(tests.id('ord')), 'is_owner_acting: not in a business they have no seat in';
  perform tests.as_user(tests.id('manager'));
  assert private.is_owner(tests.id('o')), 'is_owner_acting: the manager''s acting seat counts too';
  perform tests.as_user(tests.id('staff'));
  assert not private.is_owner(tests.id('ord')), 'is_owner_acting: staff does not';
  perform tests.as_user(tests.id('owner'));
  assert private.is_owner(tests.id('ord')), 'is_owner_acting: the real owner still does';
  perform tests.as_definer(tests.id('partner'));
  assert private.acts_as_owner(tests.id('o'), tests.id('partner')) and private.acts_as_owner(tests.id('ord'), tests.id('owner'))
    and not private.acts_as_owner(tests.id('ord'), tests.id('staff')) and not private.acts_as_owner(tests.id('o'), tests.id('pstaff'))
    and not private.acts_as_owner(tests.id('o'), null), 'is_owner_acting: acts_as_owner by user';
  perform tests.as_postgres();
  update members set status = 'disabled' where org_id = tests.id('o') and user_id = tests.id('manager');
  assert not private.acts_as_owner(tests.id('o'), tests.id('manager')), 'is_owner_acting: a disabled seat does not act';
  update members set status = 'active' where org_id = tests.id('o') and user_id = tests.id('manager');
  perform tests.as_postgres();
end $$;

-- test: orgs_guard_new_columns
do $$
declare col text;
begin
  foreach col in array array[
    'managed_by = ' || quote_literal(tests.id('pr')), 'director_confirmed_at = now()', 'read_only_at = now()',
    'retain_until = current_date', 'send_mode = ''download_only''']
  loop
    perform tests.as_user(tests.id('owner'));
    perform tests.throws(format('update orgs set %s where id = %L', col, tests.id('ord')), '42501: That cannot be changed here.');
    -- The acting owner of the managed business may not either (managed_by is already set there: it would clear it).
    perform tests.as_user(tests.id('partner'));
    perform tests.throws(format('update orgs set %s where id = %L', replace(col, quote_literal(tests.id('pr')), 'null'), tests.id('o')),
      '42501: That cannot be changed here.');
  end loop;
  perform tests.as_user(tests.id('owner'));
  update orgs set name = 'Ordinary Resolver Renamed' where id = tests.id('ord');
  perform tests.as_user(tests.id('partner'));
  update orgs set invoice_note = 'Managed note' where id = tests.id('o');
  perform tests.as_postgres();
  assert (select name from orgs where id = tests.id('ord')) = 'Ordinary Resolver Renamed'
     and (select invoice_note from orgs where id = tests.id('o')) = 'Managed note',
    'orgs_guard_new_columns: other columns still change as before (acting owner counts as owner)';
  update orgs set send_mode = 'download_only', read_only_at = now() where id = tests.id('o');
  assert (select send_mode from orgs where id = tests.id('o')) = 'download_only', 'orgs_guard_new_columns: Counta''s own functions may';
  update orgs set send_mode = 'send', read_only_at = null where id = tests.id('o');
  perform tests.throws(format('update orgs set send_mode = ''loud'' where id = %L', tests.id('o')), '23514%');
  perform tests.as_postgres();
end $$;

-- test: org_contact
do $$
declare c members;
begin
  c := private.org_contact(tests.id('ord'));
  assert c.role = 'owner' and c.user_id = tests.id('owner'), 'org_contact: owner when unmanaged';
  c := private.org_contact(tests.id('o'));
  assert c.user_id = tests.id('partner') and c.acts_as_owner, 'org_contact: engagement partner seat when managed';
  update practice_clients set engagement_partner_id = tests.id('manager_pm') where org_id = tests.id('o') and mode = 'full';
  assert (private.org_contact(tests.id('o'))).user_id = tests.id('manager'), 'org_contact: follows the engagement partner';
  update members set status = 'disabled' where org_id = tests.id('o') and user_id = tests.id('manager');
  c := private.org_contact(tests.id('o'));
  assert c.user_id = tests.id('partner') and c.acts_as_owner, 'org_contact: the oldest active acting seat when the engagement partner has none';
  update members set status = 'active' where org_id = tests.id('o') and user_id = tests.id('manager');
  update practice_clients set engagement_partner_id = null where org_id = tests.id('o') and mode = 'full';
  assert (private.org_contact(tests.id('o'))).user_id = tests.id('partner'), 'org_contact: the oldest active acting seat with no engagement partner';
  update practice_clients set engagement_partner_id = (select id from practice_members where practice_id = tests.id('pr') and user_id = tests.id('partner'))
  where org_id = tests.id('o') and mode = 'full';
  assert (private.org_contact(gen_random_uuid())).id is null, 'org_contact: none for an unknown business';
  perform tests.as_postgres();
end $$;

-- test: mandate_and_is_managed
do $$
declare c practice_clients;
begin
  assert private.is_managed(tests.id('o')) and (private.mandate(tests.id('o'))).mode = 'full' and not private.is_managed(tests.id('ord')),
    'mandate_and_is_managed';
  c := private.mandate(tests.id('o'));
  assert c.practice_id = tests.id('pr') and c.status = 'active' and c.billing = 'practice', 'mandate_and_is_managed: the active full link';
  assert (private.mandate(tests.id('ord'))).id is null and not private.is_managed(gen_random_uuid()),
    'mandate_and_is_managed: none for an ordinary or unknown business';
  update practice_clients set status = 'ended', ended_at = now(), end_kind = 'ended' where id = c.id;
  assert (private.mandate(tests.id('o'))).id = c.id and private.is_managed(tests.id('o')),
    'mandate_and_is_managed: still found after an end without handover';
  update practice_clients set status = 'active', ended_at = null, end_kind = null where id = c.id;
  perform tests.as_postgres();
end $$;

-- test: create_org_core_no_member
do $$
declare core_org uuid; two_org uuid;
begin
  perform tests.as_definer(tests.id('partner'));
  core_org := private.create_org_core('Core Test Ltd', 'core@firm.example.test', null, '[]', true, false);
  two_org := private.create_org_core(' Core Two Ltd ', '  ', null, '[{"name": "Ikeja shop"}, {"name": " "}, {"name": "Lekki shop", "code": "lek"}]', false, false);
  perform tests.as_postgres();
  assert (select count(*) from members where org_id = core_org) = 0 and (select name from locations where org_id = core_org and is_main) = 'Main store',
    'create_org_core_no_member';
  assert (select created_by = tests.id('partner') and email = 'core@firm.example.test' and vat_registered and not is_sample
            and identity_status = 'not_required' and managed_by is null from orgs where id = core_org),
    'create_org_core_no_member: the business row';
  assert (select name = 'Core Two Ltd' and email is null and not vat_registered from orgs where id = two_org)
     and (select string_agg(code || ':' || is_main, ',' order by code) from locations where org_id = two_org) = 'IKE:true,LEK:false',
    'create_org_core_no_member: no default email, locations as given';
  perform tests.as_definer(null);
  perform tests.throws($q$select private.create_org_core('Nobody Ltd', null, null, '[]', true, false)$q$, '%Sign in first.%');
  perform tests.as_definer(tests.id('partner'));
  perform tests.throws($q$select private.create_org_core('  ', null, null, '[]', true, false)$q$, '%Business name is required.%');
  perform tests.as_postgres();
end $$;

-- test: full_needs_practice_billing
do $$
begin
  perform tests.throws(format($q$insert into practice_clients (practice_id, org_id, status, initiated_by, mode, billing)
    values (%L, %L, 'active', 'practice', 'full', 'business')$q$, tests.id('pr'), tests.id('ord')), '23514%practice_clients_full_billing%');
  perform tests.as_postgres();
end $$;

-- test: one_full_per_org
do $$
declare v_pr2 uuid;
begin
  v_pr2 := tests.practice(tests.user('or.partner2@example.test'), 'Second Partners', true);
  perform tests.throws(format($q$insert into practice_clients (practice_id, org_id, status, initiated_by, mode, billing)
    values (%L, %L, 'active', 'practice', 'full', 'practice')$q$, v_pr2, tests.id('o')), '23505%practice_clients_one_full%');
  insert into practice_clients (practice_id, org_id, status, initiated_by, mode, billing)
  values (v_pr2, tests.id('o'), 'ended', 'practice', 'full', 'practice');
  perform tests.as_postgres();
end $$;

-- test: practice_clients_new_checks
do $$
declare c uuid; ic uuid;
begin
  c := (private.mandate(tests.id('o'))).id;
  perform tests.throws(format('update practice_clients set alert_email = ''not-an-email'' where id = %L', c), '23514%');
  perform tests.throws(format('update practice_clients set retention_years = 4 where id = %L', c), '23514%');
  perform tests.throws(format('update practice_clients set end_kind = ''paused'' where id = %L', c), '23514%');
  perform tests.throws(format('update practice_clients set mode = ''half'' where id = %L', c), '23514%');
  update practice_clients set alert_email = 'alerts@firm.example.test', retention_years = 6 where id = c;
  ic := tests.involved_client(tests.id('pr'), tests.id('ord'));
  assert (select mode = 'involved' and billing = 'business' and engagement_partner_id is null from practice_clients where id = ic),
    'practice_clients_new_checks: involved by default';
  perform tests.as_postgres();
end $$;

-- test: helpers_revoked
do $$
begin
  assert not has_function_privilege('authenticated', 'private.acts_as_owner(uuid,uuid)', 'execute')
     and not has_function_privilege('authenticated', 'private.org_contact(uuid)', 'execute')
     and not has_function_privilege('authenticated', 'private.mandate(uuid)', 'execute')
     and not has_function_privilege('authenticated', 'private.is_managed(uuid)', 'execute')
     and not has_function_privilege('authenticated', 'private.create_org_core(text,text,text,jsonb,boolean,boolean)', 'execute'), 'helpers_revoked';
  assert not has_function_privilege('authenticated', 'private.perm_of(members,text)', 'execute')
     and not has_function_privilege('anon', 'private.perm_of(members,text)', 'execute')
     and not has_function_privilege('authenticated', 'private.orgs_guard()', 'execute'),
    'helpers_revoked: redefined perm_of and orgs_guard';
  assert has_function_privilege('authenticated', 'private.is_owner(uuid)', 'execute')
     and not has_function_privilege('anon', 'private.is_owner(uuid)', 'execute'),
    'helpers_revoked: is_owner stays callable by policies as the signed-in person';
  perform tests.as_postgres();
end $$;

rollback;
