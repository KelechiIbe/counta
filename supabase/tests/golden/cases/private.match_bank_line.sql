-- A customer's transfer waiting for the bank to confirm it: the statement line confirms it and the collection is
-- posted in the owner's name.
-- callers: definer:owner
-- setup
do $$
declare b public.bank_accounts;
begin
  b := private.open_bank_account(tests.id('org'), 'bank', 'Golden Bank', '{"bank_name": "Test Bank", "account_number": "0123456782"}', tests.id('m_owner'));
  insert into collections (org_id, number, customer_id, amount, method, status, received_at, created_by)
  values (tests.id('org'), 'COL-GOLD1', tests.id('customer'), 5000, 'transfer', 'pending', now(), tests.id('m_staff'));
  insert into bank_lines (org_id, bank_account_id, line_date, amount, description, source, fingerprint)
  values (tests.id('org'), b.id, private.local_day(tests.id('org'), now()), 5000, 'Transfer from Golden Customer Ltd', 'manual', 'golden-line-1');
end $$;
-- call
select private.match_bank_line((select id from bank_lines where fingerprint = 'golden-line-1'))
select c.status, mb.display_name as posted_by from collections c join journals j on j.id = c.journal_id left join members mb on mb.id = j.posted_by where c.number = 'COL-GOLD1'
