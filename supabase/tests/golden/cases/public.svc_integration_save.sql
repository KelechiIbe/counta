-- The owner, or someone who manages settings, connects a tool.
-- call
select public.svc_integration_save(jsonb_build_object('org_id', tests.id('org'), 'member_id', tests.id('m_owner'), 'provider', 'slack', 'label', 'Owner Slack')) ->> 'label'
select public.svc_integration_save(jsonb_build_object('org_id', tests.id('org'), 'member_id', tests.id('m_admin'), 'provider', 'slack', 'label', 'Admin Slack')) ->> 'label'
select public.svc_integration_save(jsonb_build_object('org_id', tests.id('org'), 'member_id', tests.id('m_accountant'), 'provider', 'slack', 'label', 'Accountant Slack')) ->> 'label'
