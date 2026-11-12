-- setup
update orgs set identity_status = 'pending' where id = tests.id('org');
-- call
select public.identity_state(tests.id('org'))
