-- Only the owner makes someone an admin.
-- call
select public.invite_member(tests.id('org'), 'Golden Newcomer', 'newcomer@example.test', 'admin') is not null as invited
select display_name, role, status from members where org_id = tests.id('org') and email = 'newcomer@example.test'
