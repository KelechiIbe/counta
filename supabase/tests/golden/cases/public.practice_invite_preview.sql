-- callers: anon
-- setup
insert into practice_clients (practice_id, status, initiated_by, invite_email, invite_name, business_name, token_hash, token_expires, created_by) values (tests.id('practice'), 'invited', 'practice', 'new.client@example.test', 'New Client', 'New Client Ltd', encode(extensions.digest('pc_' || repeat('cd', 24), 'sha256'), 'hex'), now() + interval '7 days', tests.id('partner'));
insert into practice_members (practice_id, email, display_name, role, status, token_hash, token_expires) values (tests.id('practice'), 'joiner@example.test', 'Golden Joiner', 'staff', 'invited', encode(extensions.digest('pm_' || repeat('ef', 24), 'sha256'), 'hex'), now() + interval '7 days');
-- call
select public.practice_invite_preview('pc_' || repeat('cd', 24))
select public.practice_invite_preview('pm_' || repeat('ef', 24))
select public.practice_invite_preview('pc_' || repeat('00', 24))
