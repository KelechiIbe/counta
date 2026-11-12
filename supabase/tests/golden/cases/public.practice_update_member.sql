-- A practice partner makes a staff member a manager: the manager gets a seat in every active client.
-- callers: definer:partner definer:owner
-- setup
select tests.remember('pstaff', tests.user('pstaff@example.test', 'Golden Practice Staff'));
select tests.remember('pm_staff', tests.practice_member(tests.id('practice'), tests.id('pstaff'), 'staff'));
-- call
select public.practice_update_member(tests.id('pm_staff'), '{"role": "manager"}') is not null as updated
select display_name, role, status, practice_id is not null as practice_seat, p_keep_books, p_make_payments, p_manage_team from members where org_id = tests.id('org') order by display_name
