-- A supplier's invoice uploaded with no one recorded: the bill it becomes is written in the owner's name.
-- callers: definer:owner
-- setup
insert into supplier_invoices (org_id, number, source, document_path) values (tests.id('org'), 'SI-90001', 'upload', tests.id('org')::text || '/bills/golden-si.pdf');
select tests.remember('si', (select id from supplier_invoices where number = 'SI-90001'));
-- call
select private.si_apply(tests.id('si'), '{"supplier": {"name": "Golden Supplier Ltd"}, "invoice_no": "GS-1", "total": 1000, "lines": [{"description": "Flour", "qty": 1, "unit_price": 1000, "account_code": "5101"}]}', 'golden-model', null) ? 'id'
select b.vendor_ref, b.total, mb.display_name as created_by from bills b left join members mb on mb.id = b.created_by where b.vendor_ref = 'GS-1'
