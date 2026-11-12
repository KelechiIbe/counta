-- Someone who keeps the books, or the owner, uploads a supplier's invoice.
-- setup
update members set p_keep_books = false where id = tests.id('m_owner');
-- call
select public.svc_si_open(jsonb_build_object('source', 'upload', 'org_id', tests.id('org'), 'member_id', tests.id('m_owner'), 'path', tests.id('org')::text || '/bills/golden-up.pdf')) ->> 'number'
select public.svc_si_open(jsonb_build_object('source', 'upload', 'org_id', tests.id('org'), 'member_id', tests.id('m_staff'), 'path', tests.id('org')::text || '/bills/golden-up2.pdf')) ->> 'number'
