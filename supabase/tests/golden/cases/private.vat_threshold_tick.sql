-- A business not charging VAT whose sales this year pass 100 million: the owner is told.
-- callers: definer:owner
-- setup
update orgs set vat_registered = false where id = tests.id('org');
select tests.as_user(tests.id('owner'));
select public.save_sale_doc(tests.id('org'), jsonb_build_object('customer_id', tests.id('customer'), 'status', 'issue', 'lines', '[{"description": "Big contract", "qty": 1, "unit_price": 150000000, "vat_treatment": "exempt"}]'::jsonb));
select tests.as_postgres();
-- call
select private.vat_threshold_tick()::text
select u.email, n.kind from notifications n join auth.users u on u.id = n.user_id where n.org_id = tests.id('org') order by u.email, n.kind
