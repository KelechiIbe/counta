-- The practice has an open request to the business: the owner and admins see it.
-- setup
insert into practice_requests (client_id, org_id, practice_id, title, status, asked_by) values (tests.id('client'), tests.id('org'), tests.id('practice'), 'Golden bank statements', 'open', (select id from practice_members where user_id = tests.id('partner')));
-- call
select public.get_attention(tests.id('org'))
