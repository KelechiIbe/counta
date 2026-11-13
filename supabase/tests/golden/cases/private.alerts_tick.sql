-- An invoice that went overdue yesterday: the invoices alert goes to the owner by email and to the sellers by push.
-- Only that alert is read back (tax deadline alerts depend on the day).
-- callers: definer:owner
-- setup
update sales set due_date = private.local_day(tests.id('org'), now()) - 1 where id = tests.id('invoice');
-- call
select private.alerts_tick() ? 'alerts'
select to_address, channel, status, template from messages where org_id = tests.id('org') and params->>'kind' = 'invoices' order by to_address, channel
select u.email, n.kind from notifications n join auth.users u on u.id = n.user_id where n.org_id = tests.id('org') and n.kind = 'invoices' order by u.email
