-- A bulk payment above the approval threshold needs approval unless the owner asks.
-- setup
update orgs set payout_approval_threshold = 1000 where id = tests.id('org');
-- call
select private.bulk_check(tests.id('org'), '{"default_account": "5101", "rows": [{"account_number": "0123456789", "bank_code": "058", "account_name": "Golden Payee", "amount": 5000, "narration": "Supplies"}]}', (select m from members m where m.org_id = tests.id('org') and m.user_id = auth.uid()))
