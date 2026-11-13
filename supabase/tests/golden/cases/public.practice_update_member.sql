-- A practice partner makes a staff member a manager: the manager gets a seat in every active client.
-- callers: partner owner
-- setup
select tests.remember('pstaff', tests.user('pstaff@example.test', 'Golden Practice Staff'));
select tests.remember('pm_staff', tests.practice_member(tests.id('practice'), tests.id('pstaff'), 'staff'));
-- call
select public.practice_update_member(tests.id('pm_staff'), '{"role": "manager"}') is not null as updated
select golden.readback($r$select m.* from members m where m.org_id = tests.id('org') order by m.display_name, m.email$r$)
