-- Everyone works at the main branch; a notice for another branch reaches only the owner.
-- callers: definer:owner
-- setup
insert into locations (org_id, name, code) values (tests.id('org'), 'Second shop', 'SEC');
update members set location_id = (select id from locations where org_id = tests.id('org') and is_main) where org_id = tests.id('org');
-- call
select private.notify_perm(tests.id('org'), 'record_sales', 'golden', 'Golden notice', 'Body', '/home', null, null, (select id from locations where org_id = tests.id('org') and code = 'SEC'))::text
select u.email, n.kind from notifications n join auth.users u on u.id = n.user_id where n.org_id = tests.id('org') order by u.email, n.kind
