-- A practice's link: only the owner connects the business (the golden practice is already connected, so a second one
-- is used).
-- setup
select tests.remember('other_partner', tests.user('other.partner@example.test', 'Other Partner'));
select tests.remember('other_practice', tests.practice(tests.id('other_partner'), 'Other Partners', true));
update practices set referral_code = 'GOLD-0001' where id = tests.id('other_practice');
-- call
select public.referral_connect(tests.id('org'), 'GOLD-0001') - 'client_id'
