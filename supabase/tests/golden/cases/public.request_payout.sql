-- A refund to a customer in credit: only a manager or the owner refunds.
-- call
select public.request_payout(tests.id('org'), jsonb_build_object('purpose', 'refund', 'customer_id', tests.id('customer'), 'amount', 100, 'account_number', '0123456789', 'bank_code', '058', 'account_name', 'Golden Customer Ltd'))
