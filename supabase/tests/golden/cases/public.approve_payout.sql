-- Approvers may not approve what they asked for, except the owner.
-- setup
insert into payouts (org_id, number, wallet_id, purpose, amount, bank_code, account_number, account_name, narration, reference, status, requested_by)
values (tests.id('org'), 'PO-90001', tests.id('wallet'), 'expense', 5000, '058', '0123456789', 'Golden Payee', 'Supplies', 'CNTP-PO-90001', 'pending_approval', tests.id('m_owner'));
select tests.remember('po_owner', (select id from payouts where number = 'PO-90001'));
insert into payouts (org_id, number, wallet_id, purpose, amount, bank_code, account_number, account_name, narration, reference, status, requested_by)
values (tests.id('org'), 'PO-90002', tests.id('wallet'), 'expense', 5000, '058', '0123456789', 'Golden Payee', 'Supplies', 'CNTP-PO-90002', 'pending_approval', tests.id('m_admin'));
select tests.remember('po_admin', (select id from payouts where number = 'PO-90002'));
-- call
select public.approve_payout(tests.id('po_owner'), true)->>'status'
select public.approve_payout(tests.id('po_admin'), true)->>'status'
