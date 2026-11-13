-- Each person has a finished draft for the golden business: only its owner submits it.
-- setup
insert into kyc_profiles (user_id, org_id, status, source, manual, answers) select m.user_id, m.org_id, 'draft', 'manual', '{"name": "Golden Foods Ltd", "address": "1 Test Street, Lagos", "state": "Lagos"}', '{"offering": "goods", "category": "retail_food", "revenue_band": "under_25m", "receive_methods": ["transfer"], "pay_methods": ["transfer"], "reasons": ["tax"], "examples": ["flour"], "filing": {"vat": "always", "wht": "never", "cit": "always"}}' from members m where m.org_id = tests.id('org') and m.user_id is not null;
-- call
select public.kyc_submit('{}') - 'org_id'
select name, identity_status, legal_form, vat_registered from orgs where id = tests.id('org')
