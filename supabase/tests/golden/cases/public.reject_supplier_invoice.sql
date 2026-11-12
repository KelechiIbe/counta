-- An invoice a supplier sent through the portal, waiting for review.
-- setup
insert into supplier_invoices (org_id, number, source, status, document_path, vendor_id, submitter) values (tests.id('org'), 'SI-90002', 'portal', 'review', tests.id('org')::text || '/bills/golden-portal.pdf', tests.id('vendor'), '{"name": "Golden Supplier", "email": "supplier@example.test"}');
select tests.remember('si', (select id from supplier_invoices where number = 'SI-90002'));
-- call
select public.reject_supplier_invoice(tests.id('si'), '{"reason": "Wrong amount on the invoice."}')
select to_address, channel, status, template, subject from messages where org_id = tests.id('org') order by to_address, channel, template
