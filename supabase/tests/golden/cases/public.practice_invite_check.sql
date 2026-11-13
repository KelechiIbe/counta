-- A practice's invitation to a business (checked by the practice's lead) and a business's invitation to an accountant
-- (checked by whoever manages the business's team).
-- callers: partner owner admin accountant staff
-- setup
insert into practice_clients (practice_id, status, initiated_by, invite_email, invite_name, created_by) values (tests.id('practice'), 'invited', 'practice', 'new.client@example.test', 'New Client', tests.id('partner'));
insert into practice_clients (org_id, status, initiated_by, invite_email, invite_name, business_name, created_by) values (tests.id('org'), 'requested', 'business', 'new.accountant@example.test', 'New Accountant', 'Golden Foods Ltd', tests.id('owner'));
select tests.remember('pc_invited', (select id from practice_clients where invite_email = 'new.client@example.test'));
select tests.remember('pc_requested', (select id from practice_clients where invite_email = 'new.accountant@example.test'));
-- call
select public.practice_invite_check('client', tests.id('pc_invited')) - 'id'
select public.practice_invite_check('accountant', tests.id('pc_requested')) - 'id'
