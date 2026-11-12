-- A second practice's invitation to the business: only its owner connects it.
-- setup
select tests.remember('other_partner', tests.user('other.partner@example.test', 'Other Partner'));
select tests.remember('other_practice', tests.practice(tests.id('other_partner'), 'Other Partners', true));
insert into practice_clients (practice_id, status, initiated_by, invite_email, invite_name, token_hash, token_expires, created_by)
values (tests.id('other_practice'), 'invited', 'practice', 'owner@example.test', 'Golden Owner', encode(extensions.digest('pc_' || repeat('ab', 24), 'sha256'), 'hex'), now() + interval '7 days', tests.id('other_partner'));
-- call
select public.practice_accept('pc_' || repeat('ab', 24), jsonb_build_object('org_id', tests.id('org'))) - 'client_id'
