-- The owner is also a manager of the practice: their own place stays the owner's. Then the link ends and the
-- practice's seats are switched off.
-- callers: definer:owner
-- setup
select tests.practice_member(tests.id('practice'), tests.id('owner'), 'manager');
-- exec
select private.practice_sync_seats(tests.id('client'))
update practice_clients set status = 'ended', ended_at = now() where id = tests.id('client')
select private.practice_sync_seats(tests.id('client'))
-- call
select golden.readback($r$select m.* from members m where m.org_id = tests.id('org') order by m.display_name, m.email$r$)
