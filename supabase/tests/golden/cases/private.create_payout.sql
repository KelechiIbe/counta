-- A payout above the approval threshold waits for approval unless the owner asks for it.
-- setup
update orgs set payout_approval_threshold = 1000 where id = tests.id('org');
-- call
select p.status, p.amount from private.create_payout(tests.id('org'), '{"amount": 5000, "account_number": "0123456789", "bank_code": "058", "account_name": "Golden Payee", "narration": "Supplies"}', '[]', (select m from members m where m.org_id = tests.id('org') and m.user_id = auth.uid())) p
select u.email, n.kind from notifications n join auth.users u on u.id = n.user_id where n.org_id = tests.id('org') order by u.email, n.kind
