-- Only the owner sees the business profile.
-- setup
insert into kyc_profiles (user_id, org_id, status, source, answers) values (tests.id('owner'), tests.id('org'), 'submitted', 'manual', '{"offering": "goods"}');
-- call
select public.kyc_draft(tests.id('org'))
select public.kyc_draft(null)
