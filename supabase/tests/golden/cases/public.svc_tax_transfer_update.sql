-- A transfer into the tax wallet is posted in the owner's name.
-- setup
insert into tax_transfers (org_id, tax_wallet_id, wallet_id, direction, amount, reference, status) values (tests.id('org'), tests.id('tax_wallet'), tests.id('wallet'), 'in', 1000, 'TT-GOLDEN-1', 'pending');
-- call
select public.svc_tax_transfer_update('TT-GOLDEN-1', 'sent')
select t.status, mb.display_name as posted_by from tax_transfers t join journals j on j.id = t.journal_id left join members mb on mb.id = j.posted_by where t.reference = 'TT-GOLDEN-1'
