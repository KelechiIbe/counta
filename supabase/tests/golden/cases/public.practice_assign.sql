-- Assigning a practice's staff member to the client gives them an accountant's seat; every seat is read back.
-- callers: partner owner admin accountant staff
-- setup
select tests.remember('pstaff', tests.user('pstaff@example.test', 'Golden Practice Staff'));
select tests.remember('pm_staff', tests.practice_member(tests.id('practice'), tests.id('pstaff'), 'staff'));
-- call
select public.practice_assign(tests.id('client'), tests.id('pm_staff'), true) is not null as assigned
select display_name, role, status, practice_id is not null as practice_seat, p_keep_books, p_make_payments, p_manage_team from members where org_id = tests.id('org') order by display_name
