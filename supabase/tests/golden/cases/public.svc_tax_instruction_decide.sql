-- Flux's account for September's filed VAT, matching the return, with the tax wallet holding enough: Counta pays it by
-- itself, in the owner's name. A second instruction with nothing filed waits for approval and the owner is told.
-- setup
insert into vat_periods (org_id, period, payable, credit_used, status) values (tests.id('org'), '2026-09-01', 7500, 0, 'filed');
do $$
declare v_code text;
begin
  select b.ledger_code into v_code from bank_accounts b join tax_wallets t on t.bank_account_id = b.id where t.id = tests.id('tax_wallet');
  perform tests.as_user(tests.id('owner'));
  perform public.post_manual_journal(tests.id('org'), private.local_day(tests.id('org'), now()), 'Money set aside for tax',
    jsonb_build_array(jsonb_build_object('code', v_code, 'debit', 10000), jsonb_build_object('code', '3001', 'credit', 10000)));
  perform tests.as_postgres();
end $$;
insert into tax_payment_instructions (org_id, tax, period, authority, prn, amount, bank_name, bank_code, account_number, account_name, status) values
  (tests.id('org'), 'vat', '2026-09-01', 'NRS', 'PRN-GOLDEN-4', 7500, 'Test Bank', '058', '0123456781', 'NRS VAT Collection', 'received'),
  (tests.id('org'), 'vat', '2026-08-01', 'NRS', 'PRN-GOLDEN-5', 7500, 'Test Bank', '058', '0123456781', 'NRS VAT Collection', 'received');
select tests.remember('instruction', (select id from tax_payment_instructions where prn = 'PRN-GOLDEN-4'));
select tests.remember('instruction_wait', (select id from tax_payment_instructions where prn = 'PRN-GOLDEN-5'));
-- call
select public.svc_tax_instruction_decide(tests.id('instruction'), '{"name_ok": true, "resolved_name": "NRS VAT COLLECTION"}') - 'payment_id'
select public.svc_tax_instruction_decide(tests.id('instruction_wait'), '{"name_ok": true, "resolved_name": "NRS VAT COLLECTION"}')
select p.kind, p.amount, p.status, mb.display_name as requested_by from tax_payments p left join members mb on mb.id = p.requested_by where p.org_id = tests.id('org')
select to_address, channel, status, template from messages where org_id = tests.id('org') order by to_address, channel, template, status
select mb.email, n.kind from notifications n join members mb on mb.user_id = n.user_id and mb.org_id = n.org_id where n.org_id = tests.id('org') order by mb.email, n.kind
