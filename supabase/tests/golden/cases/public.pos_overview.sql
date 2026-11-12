-- setup
insert into bank_accounts (org_id, name, kind, ledger_code, bank_name, account_number) values (tests.id('org'), 'Golden Bank', 'bank', '1202', 'Test Bank', '0123456782');
-- call
select public.pos_overview(tests.id('org'))
