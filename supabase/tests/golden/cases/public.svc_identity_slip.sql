-- Only the owner's NIN slip is read; the owner's own name matches.
-- setup
update orgs set identity_status = 'pending', identity = jsonb_build_object('slip', jsonb_build_object('path', tests.id('org')::text || '/kyc/nin-slip-golden.jpg', 'read', false)) where id = tests.id('org');
-- call
select public.svc_identity_slip(tests.id('admin'), tests.id('org'), '{"is_nin_document": true, "first_name": "Golden", "surname": "Admin", "nin_last4": "1234"}')
select public.svc_identity_slip(tests.id('owner'), tests.id('org'), '{"is_nin_document": true, "first_name": "Golden", "surname": "Owner", "nin_last4": "1234"}')
select identity_status, identity->>'matched' as matched from orgs where id = tests.id('org')
