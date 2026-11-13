-- callers: platform owner admin accountant staff
-- setup
update orgs set identity_status = 'review', identity = '{"slip": {"path": "x", "read": true}}' where id = tests.id('org');
-- call
select public.identity_reviews()
