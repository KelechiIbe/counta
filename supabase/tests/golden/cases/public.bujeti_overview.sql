-- setup
insert into integrations (org_id, provider, status, settings, connected_by, connected_at) values (tests.id('org'), 'bujeti', 'active', '{}', tests.id('m_owner'), now());
-- call
select public.bujeti_overview(tests.id('org'))
