-- Uploaded by the admin: the admin or the owner takes it out.
-- setup
insert into documents (org_id, cat, folder, name, path, source, uploaded_by) values (tests.id('org'), 'other', 'Other', 'golden.pdf', tests.id('org')::text || '/docs/golden.pdf', 'upload', tests.id('m_admin'));
select tests.remember('document', (select id from documents where org_id = tests.id('org') and name = 'golden.pdf'));
-- call
select public.document_delete(tests.id('org'), tests.id('document'))->>'ok'
