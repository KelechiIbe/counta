-- Only the owner changes what admins can do; nobody but the owner changes their own role.
-- call
select public.save_role_permissions(tests.id('org'), 'admin', '{"manage_settings": false}')
select public.save_role_permissions(tests.id('org'), 'accountant', '{"make_payments": true}')
