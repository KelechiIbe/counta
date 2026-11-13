-- A second practice's invitation to the business: only its owner connects it. Its partner's seat, the links and the
-- notices are read back.
-- setup
select tests.remember('other_partner', tests.user('other.partner@example.test', 'Other Partner'));
select tests.remember('other_practice', tests.practice(tests.id('other_partner'), 'Other Partners', true));
insert into practice_clients (practice_id, status, initiated_by, invite_email, invite_name, token_hash, token_expires, created_by)
values (tests.id('other_practice'), 'invited', 'practice', 'owner@example.test', 'Golden Owner', encode(extensions.digest('pc_' || repeat('ab', 24), 'sha256'), 'hex'), now() + interval '7 days', tests.id('other_partner'));
-- call
select public.practice_accept('pc_' || repeat('ab', 24), jsonb_build_object('org_id', tests.id('org'))) - 'client_id'
select golden.readback($r$select m.* from members m where m.org_id = tests.id('org') order by m.display_name, m.email$r$)
select golden.readback($r$select p.name as practice, c.status, c.initiated_by, c.via from practice_clients c join practices p on p.id = c.practice_id where c.org_id = tests.id('org') order by p.name, c.status$r$)
select golden.readback($r$select u.email, n.kind, n.title from notifications n join auth.users u on u.id = n.user_id order by u.email, n.kind, n.title$r$)
