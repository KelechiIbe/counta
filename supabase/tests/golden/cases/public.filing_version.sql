-- An accountant's version of a VAT return waiting for review. The statement preview names today's date, which is
-- masked.
-- callers: owner admin accountant staff partner
-- setup
insert into filing_versions (org_id, kind, period, version, status, file_path, file_name, sha256, practice_id, practice_name, uploaded_member, uploader_name)
values (tests.id('org'), 'vat', '2026-09', 1, 'review', tests.id('org')::text || '/tax/vat/2026-09/golden-v1.xlsx', 'golden-v1.xlsx', repeat('a', 64), tests.id('practice'), 'Golden Partners', tests.id('m_partner'), 'Golden Partner');
select tests.remember('version', (select id from filing_versions where file_name = 'golden-v1.xlsx'));
-- call
select v - 'statement_preview' as version, regexp_replace(v->>'statement_preview', '[0-9]{1,2} [A-Z][a-z]+ [0-9]{4}', '<today>') as statement_preview from (select public.filing_version(tests.id('version')) v) x
