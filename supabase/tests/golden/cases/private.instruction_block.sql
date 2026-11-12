-- Every earlier check passes, so the answer depends on the business having an active owner.
-- callers: definer:owner
-- setup
insert into tax_payment_instructions (org_id, tax, period, authority, prn, amount, expected, bank_name, bank_code, account_number, account_name, resolved_name, name_ok) values (tests.id('org'), 'vat', '2026-09-01', 'NRS', 'PRN-GOLDEN-2', 7500, 7500, 'Test Bank', '058', '0123456781', 'NRS VAT Collection', 'NRS VAT COLLECTION', true);
-- call
select private.instruction_block(i) from tax_payment_instructions i where i.org_id = tests.id('org')
