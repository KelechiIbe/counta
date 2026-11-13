-- setup
insert into platform_settings (key, value) values ('partners', '{"enabled": true}') on conflict (key) do update set value = platform_settings.value || '{"enabled": true}';
select tests.remember('other_partner', tests.user('other.partner@example.test', 'Other Partner'));
select tests.remember('other_practice', tests.practice(tests.id('other_partner'), 'Other Partners', true));
update practices set referral_code = 'GOLD-0001' where id = tests.id('other_practice');
-- call
select public.referral_offer(tests.id('org'), 'GOLD-0001')
