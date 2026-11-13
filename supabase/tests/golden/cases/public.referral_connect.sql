-- A practice's link: only the owner connects the business (the golden practice is already connected, so a second one
-- is used). Its partner's seat, the links and the notices are read back.
-- setup
select tests.remember('other_partner', tests.user('other.partner@example.test', 'Other Partner'));
select tests.remember('other_practice', tests.practice(tests.id('other_partner'), 'Other Partners', true));
update practices set referral_code = 'GOLD-0001' where id = tests.id('other_practice');
-- call
select public.referral_connect(tests.id('org'), 'GOLD-0001') - 'client_id'
select golden.readback($r$select m.* from members m where m.org_id = tests.id('org') order by m.display_name, m.email$r$)
select golden.readback($r$select p.name as practice, c.status, c.initiated_by, c.via from practice_clients c join practices p on p.id = c.practice_id where c.org_id = tests.id('org') order by p.name, c.status$r$)
select golden.readback($r$select u.email, n.kind, n.title from notifications n join auth.users u on u.id = n.user_id order by u.email, n.kind, n.title$r$)
