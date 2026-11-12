-- No directors on record: the owner is the person whose income tax is filed.
-- callers: definer:owner definer:admin definer:accountant definer:staff
-- call
select public.pit_setup(tests.id('org'))
select name, source, member_id = tests.id('m_owner') as is_owner from pit_people where org_id = tests.id('org')
