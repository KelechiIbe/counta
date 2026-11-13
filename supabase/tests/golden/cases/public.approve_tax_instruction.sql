-- setup
insert into tax_payment_instructions (org_id, tax, period, authority, prn, amount, expected, bank_name, bank_code, account_number, account_name, resolved_name, name_ok, status)
values (tests.id('org'), 'vat', '2026-09-01', 'NRS', 'PRN-GOLDEN-3', 7500, 7500, 'Test Bank', '058', '0123456781', 'NRS VAT Collection', 'NRS VAT COLLECTION', true, 'needs_approval');
select tests.remember('instruction', (select id from tax_payment_instructions where prn = 'PRN-GOLDEN-3'));
-- call
select public.approve_tax_instruction(tests.id('instruction'))
