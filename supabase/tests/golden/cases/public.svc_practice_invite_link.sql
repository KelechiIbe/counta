-- setup
insert into practice_clients (practice_id, status, initiated_by, invite_email, invite_name, business_name, created_by) values (tests.id('practice'), 'invited', 'practice', 'new.client@example.test', 'New Client', 'New Client Ltd', tests.id('partner'));
insert into practice_clients (org_id, status, initiated_by, invite_email, invite_name, business_name, created_by) values (tests.id('org'), 'requested', 'business', 'new.accountant@example.test', 'New Accountant', 'Golden Foods Ltd', tests.id('owner'));
insert into practice_members (practice_id, email, display_name, role, status, invited_by) values (tests.id('practice'), 'joiner@example.test', 'Golden Joiner', 'staff', 'invited', (select id from practice_members where user_id = tests.id('partner')));
select tests.remember('pc_invited', (select id from practice_clients where invite_email = 'new.client@example.test'));
select tests.remember('pc_requested', (select id from practice_clients where invite_email = 'new.accountant@example.test'));
select tests.remember('pm_invited', (select id from practice_members where email = 'joiner@example.test'));
-- call
select public.svc_practice_invite_link('client', tests.id('pc_invited'))
select public.svc_practice_invite_link('accountant', tests.id('pc_requested'))
select public.svc_practice_invite_link('member', tests.id('pm_invited'))
