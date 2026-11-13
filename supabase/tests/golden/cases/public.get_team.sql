-- The owner's own permission flags are off: the owner's permissions come from the role.
-- setup
update members set p_manage_team = false, p_file_tax = false where id = tests.id('m_owner');
-- call
select public.get_team(tests.id('org'))
