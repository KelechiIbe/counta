-- The Bujeti account is opened in the owner's name.
-- setup
insert into integrations (org_id, provider, status, settings) values (tests.id('org'), 'bujeti', 'active', '{}');
-- call
select public.svc_bujeti_invoices((select id from integrations where org_id = tests.id('org') and provider = 'bujeti'), '[]')
select b.name, b.kind, mb.display_name as created_by from integrations i join bank_accounts b on b.id = i.bank_account_id left join members mb on mb.id = b.created_by where i.org_id = tests.id('org') and i.provider = 'bujeti'
