-- Policy helper, called as the signed-in person: the uploader or the owner may delete.
-- callers: owner admin accountant staff
-- setup
insert into documents (org_id, cat, folder, name, path, source, uploaded_by) values (tests.id('org'), 'other', 'Other', 'golden.pdf', tests.id('org')::text || '/docs/golden.pdf', 'upload', tests.id('m_admin'));
-- call
select private.document_may_delete(tests.id('org')::text || '/docs/golden.pdf')
