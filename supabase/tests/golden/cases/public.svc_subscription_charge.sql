-- The charge is billed to the owner's email (the business has its own address too).
-- setup
update orgs set email = 'accounts@example.test' where id = tests.id('org');
insert into subscription_charges (org_id, plan_id, billing, amount, method, kind, tx_ref) values (tests.id('org'), private.default_plan_id(), 'month', 5000, 'wallet', 'start', 'golden-charge-1');
select tests.remember('charge', (select id from subscription_charges where tx_ref = 'golden-charge-1'));
-- call
select public.svc_subscription_charge(tests.id('charge'))
