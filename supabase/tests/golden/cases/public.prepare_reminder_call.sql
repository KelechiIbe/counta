-- The staff member may ask for their own reminder; the owner (or a manager) for anyone's.
-- setup
update members set phone = '+2348030000004' where id = tests.id('m_staff');
-- call
select public.prepare_reminder_call(tests.id('m_staff'), 'count_approval')
