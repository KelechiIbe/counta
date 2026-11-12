-- The customer's link to the issued invoice; covers private.sale_json and private.org_brand.
-- callers: anon
-- setup
update sales set public_token = 'golden-public-token-000000000001' where id = tests.id('invoice');
-- call
select public.public_document('golden-public-token-000000000001')
