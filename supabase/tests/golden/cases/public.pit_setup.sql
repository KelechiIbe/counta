-- No directors on record: the owner is the person whose income tax is filed.
-- call
select public.pit_setup(tests.id('org'))
select golden.readback($r$select p.name, p.source, p.member_id = tests.id('m_owner') as is_owner from pit_people p where p.org_id = tests.id('org') order by p.name$r$)
