-- Payments are locked until a director's identity is checked; only the owner adds the NIN slip.
-- setup
update orgs set identity_status = 'pending' where id = tests.id('org');
-- call
select public.identity_slip(tests.id('org'), tests.id('org')::text || '/kyc/nin-slip-golden.jpg', 'nin-slip.jpg')
