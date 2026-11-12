-- Martina calls the supplier about a draft purchase order.
-- setup
update vendors set phone = '+2348030000003' where id = tests.id('vendor');
insert into purchase_orders (org_id, ref, vendor_id, location_id, status, total) values (tests.id('org'), 'PO-GOLD-1', tests.id('vendor'), (select id from locations where org_id = tests.id('org') and is_main), 'draft', 20000);
select tests.remember('po', (select id from purchase_orders where ref = 'PO-GOLD-1'));
-- call
select public.prepare_vendor_call(tests.id('po')) - 'call_id'
