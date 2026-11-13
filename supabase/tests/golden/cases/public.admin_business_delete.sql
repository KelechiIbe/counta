-- The wallet is emptied first (moved back out of the books), so the business can go; the platform admin deletes it.
-- callers: platform owner admin accountant staff
-- setup
select tests.as_user(tests.id('owner'));
select public.post_manual_journal(tests.id('org'), private.local_day(tests.id('org'), now()), 'Share capital returned', jsonb_build_array(
  jsonb_build_object('code', '3001', 'debit', 1000000),
  jsonb_build_object('code', (select b.ledger_code from bank_accounts b join wallets w on w.bank_account_id = b.id where w.id = tests.id('wallet')), 'credit', 1000000)));
select tests.as_postgres();
-- call
select public.admin_business_delete(tests.id('org'), 'Golden Foods Ltd')
select tests.error_of($q$select public.admin_business_delete(tests.id('org'), 'Wrong Name')$q$)
