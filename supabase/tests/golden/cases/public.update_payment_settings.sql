-- call
select public.update_payment_settings(tests.id('org'), '{"payout_approval_threshold": 50000}')
