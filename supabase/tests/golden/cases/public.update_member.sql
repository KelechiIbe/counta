-- Nobody changes the owner's role; only the owner changes an admin's role or their own.
-- call
select public.update_member(tests.id('m_admin'), '{"title": "Head of finance"}')::text
select public.update_member(tests.id('m_admin'), '{"role": "accountant"}')::text
select public.update_member(tests.id('m_owner'), '{"role": "admin"}')::text
select display_name, role, title, status from members where org_id = tests.id('org') order by display_name
