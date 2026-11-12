-- A tax payment waiting for approval: email to the owner, push to those who pay, and WhatsApp (whose template greets
-- the owner by first name) to the owner's linked number.
-- callers: definer:owner
-- setup
insert into tax_payment_instructions (org_id, tax, period, authority, prn, amount, bank_name, account_number, account_name) values (tests.id('org'), 'vat', '2026-09-01', 'NRS', 'PRN-GOLDEN-1', 7500, 'Test Bank', '0123456781', 'NRS VAT Collection');
insert into chat_links (user_id, org_id, channel, status, phone) values (tests.id('owner'), tests.id('org'), 'whatsapp', 'active', '2348030000001');
-- call
select private.instruction_alert(i, 'approve')::text from tax_payment_instructions i where i.org_id = tests.id('org')
select to_address, channel, status, template, params->'wa'->>'name' as wa_template, params->'wa'->'params'->>0 as greeting from messages where org_id = tests.id('org') order by channel, to_address
select u.email, n.kind from notifications n join auth.users u on u.id = n.user_id where n.org_id = tests.id('org') order by u.email, n.kind
