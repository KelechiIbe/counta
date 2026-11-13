-- A sale from a connected tool is recorded in the owner's name.
-- setup
insert into integrations (org_id, provider, status, settings, connected_by) values (tests.id('org'), 'paystack', 'active', '{}', tests.id('m_admin'));
-- call
select public.svc_integration_sale((select id from integrations where org_id = tests.id('org') and provider = 'paystack'), '{"external_id": "ps:golden-1", "amount": 2500, "customer": {"name": "Golden Buyer", "email": "buyer@example.test"}}') - 'sale_id'
select s.total, s.status, mb.display_name as created_by from sales s left join members mb on mb.id = s.created_by where s.org_id = tests.id('org') and s.number not in ('INV-0001', 'INV-0002') order by s.number
