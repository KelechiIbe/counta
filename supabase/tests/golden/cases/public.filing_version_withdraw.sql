-- Withdrawing a practice's version tells the practice when the owner does it; withdrawing an accepted version tells
-- the owner when someone else does.
-- callers: definer:owner definer:admin definer:accountant definer:staff definer:partner
-- setup
insert into filing_versions (org_id, kind, period, version, status, file_path, file_name, sha256, practice_id, practice_name, uploaded_member, uploader_name)
values (tests.id('org'), 'vat', '2026-09', 1, 'review', tests.id('org')::text || '/tax/vat/2026-09/golden-v1.xlsx', 'golden-v1.xlsx', repeat('a', 64), tests.id('practice'), 'Golden Partners', tests.id('m_partner'), 'Golden Partner');
insert into filing_versions (org_id, kind, period, version, status, file_path, file_name, sha256, uploaded_member, uploader_name, accepted_at, accepted_name)
values (tests.id('org'), 'wht', '2026-09', 1, 'in_use', tests.id('org')::text || '/tax/wht/2026-09/golden-v1.xlsx', 'golden-wht-v1.xlsx', repeat('b', 64), tests.id('m_accountant'), 'Golden Accountant', now(), 'Golden Owner');
select tests.remember('version', (select id from filing_versions where file_name = 'golden-v1.xlsx'));
select tests.remember('version_wht', (select id from filing_versions where file_name = 'golden-wht-v1.xlsx'));
-- call
select public.filing_version_withdraw(tests.id('version'), 'Golden reason one')->>'status'
select public.filing_version_withdraw(tests.id('version_wht'), 'Golden reason two')->>'status'
select file_name, status from filing_versions where org_id = tests.id('org') order by file_name
select u.email, n.kind, n.title from notifications n join auth.users u on u.id = n.user_id order by u.email, n.kind, n.title
