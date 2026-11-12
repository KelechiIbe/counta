-- callers: definer:owner
-- setup
insert into role_permissions (org_id, role, perms) values (tests.id('org'), 'admin', '{"manage_settings": false}') on conflict do nothing;
-- call
select private.role_perms(tests.id('org'), 'owner')
select private.role_perms(tests.id('org'), 'admin')
