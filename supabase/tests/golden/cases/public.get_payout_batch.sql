-- Asked for by the owner.
-- setup
insert into payout_batches (org_id, number, title, wallet_id, status, requested_by) values (tests.id('org'), 'BP-9001', 'Golden owner batch', tests.id('wallet'), 'pending_approval', tests.id('m_owner'));
select tests.remember('pb_owner', (select id from payout_batches where number = 'BP-9001'));
-- call
select public.get_payout_batch(tests.id('pb_owner'))
