-- The CAC records filed in onboarding are listed for the owner only.
-- setup
insert into kyc_profiles (user_id, org_id, status, doc) values (tests.id('owner'), tests.id('org'), 'submitted', jsonb_build_object('path', tests.id('org')::text || '/kyc/cac-golden.pdf', 'file_name', 'cac-golden.pdf', 'mime', 'application/pdf'));
-- call
select cat, folder, name, kind, source from private.doc_rows(tests.id('org'), (select m from members m where m.org_id = tests.id('org') and m.user_id = auth.uid()), '2000-01-01', '2100-12-31') order by cat, folder, name
