-- Only the owner confirms a director's identity; the owner's own name matches.
-- setup
update orgs set identity_status = 'pending' where id = tests.id('org');
-- call
select public.svc_identity_nin(tests.id('admin'), tests.id('org'), '1234', 'Golden', null, 'Admin')
select public.svc_identity_nin(tests.id('owner'), tests.id('org'), '1234', 'Golden', null, 'Owner')
select identity_status, identity->>'matched' as matched from orgs where id = tests.id('org')
