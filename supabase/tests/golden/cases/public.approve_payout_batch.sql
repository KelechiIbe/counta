-- Approvers may not approve a bulk payment they asked for, except the owner.
-- setup
insert into payout_batches (org_id, number, title, wallet_id, status, requested_by) values
  (tests.id('org'), 'BP-9001', 'Golden owner batch', tests.id('wallet'), 'pending_approval', tests.id('m_owner')),
  (tests.id('org'), 'BP-9002', 'Golden admin batch', tests.id('wallet'), 'pending_approval', tests.id('m_admin'));
select tests.remember('pb_owner', (select id from payout_batches where number = 'BP-9001'));
select tests.remember('pb_admin', (select id from payout_batches where number = 'BP-9002'));
-- call
select public.approve_payout_batch(tests.id('pb_owner'), true)->>'status'
select public.approve_payout_batch(tests.id('pb_admin'), true)->>'status'
