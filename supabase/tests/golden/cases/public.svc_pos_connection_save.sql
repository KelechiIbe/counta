-- Only the owner connects a POS provider.
-- call
select public.svc_pos_connection_save(jsonb_build_object('org_id', tests.id('org'), 'member_id', tests.id('m_admin'), 'provider', 'moniepoint', 'key', 'golden-key'))
select public.svc_pos_connection_save(jsonb_build_object('org_id', tests.id('org'), 'member_id', tests.id('m_owner'), 'provider', 'moniepoint', 'key', 'golden-key', 'business_ref', 'GOLD1')) ? 'id'
select c.provider, c.status, mb.display_name as connected_by from pos_connections c left join members mb on mb.id = c.connected_by where c.org_id = tests.id('org')
