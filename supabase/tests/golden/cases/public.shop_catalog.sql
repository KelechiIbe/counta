-- callers: anon
-- setup
update orgs set shop_enabled = true, shop_slug = 'golden-foods', shop_title = 'Golden Foods Shop' where id = tests.id('org');
insert into items (org_id, name, price, item_type, category) values (tests.id('org'), 'Golden Bread', 1200, 'merchandise', 'Bakery');
-- call
select public.shop_catalog('golden-foods')
