-- Each person also has an older place in a second business; the business they own comes first.
-- setup
insert into orgs (id, name) values ('00000000-0000-4000-8000-000000000002', 'Golden Second Ltd');
insert into members (org_id, user_id, email, display_name, role, status, created_at)
select '00000000-0000-4000-8000-000000000002', m.user_id, m.email, m.display_name, 'staff', 'active', now() - interval '1 day' from members m where m.org_id = tests.id('org') and m.user_id is not null;
-- call
select private.user_org(auth.uid()) = tests.id('org') as first_is_golden
