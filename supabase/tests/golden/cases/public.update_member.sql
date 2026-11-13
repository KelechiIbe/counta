-- Nobody changes the owner's role or permissions; only the owner changes an admin, makes someone an admin, or changes
-- their own role or permissions. A second admin is added for the admin to act on.
-- setup
select tests.remember('admin2', tests.user('admin2@example.test', 'Golden Second Admin'));
select tests.remember('m_admin2', tests.member(tests.id('org'), tests.id('admin2'), 'admin'));
-- call
select public.update_member(tests.id('m_admin2'), '{"title": "Deputy"}')::text
select public.update_member(tests.id('m_admin2'), '{"status": "disabled"}')::text
select public.update_member(tests.id('m_admin'), '{"perms": {"file_tax": false}}')::text
select public.update_member(tests.id('m_staff'), '{"role": "accountant"}')::text
select public.update_member(tests.id('m_owner'), '{"role": "admin"}')::text
select public.update_member(tests.id('m_staff'), '{"role": "admin"}')::text
select golden.readback($r$select m.* from members m where m.org_id = tests.id('org') order by m.display_name, m.email$r$)
