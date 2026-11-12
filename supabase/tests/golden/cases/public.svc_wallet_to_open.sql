-- The wallet is open already; only the owner or someone who keeps the books or pays may ask.
-- call
select public.svc_wallet_to_open(tests.id('org'), tests.id('m_owner'))->'ready'
select public.svc_wallet_to_open(tests.id('org'), tests.id('m_staff'))->'ready'
