-- The owner is on the practice's team: the referral is the practice's own business (void, self).
-- callers: definer:owner
-- setup
delete from partner_referrals where org_id = tests.id('org');
insert into platform_settings (key, value) values ('partners', '{"enabled": true}') on conflict (key) do update set value = platform_settings.value || '{"enabled": true}';
select tests.practice_member(tests.id('practice'), tests.id('owner'), 'staff');
-- call
select private.partner_referral_start(c)::text from practice_clients c where c.id = tests.id('client')
select source, status, void_reason from partner_referrals where org_id = tests.id('org') order by created_at
