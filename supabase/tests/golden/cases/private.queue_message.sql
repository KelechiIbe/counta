-- Messages are queued and the messaging hook is called; a customer's copy addresses go along.
-- callers: definer:owner
-- setup
update customers set cc_emails = array['accounts@example.test'] where id = tests.id('customer');
-- call
select q.to_address, q.channel, q.template, q.subject, q.params, q.status from private.queue_message(tests.id('org'), 'email', ' Customer@Example.test ', 'document', 'Golden subject', '{"x": 1}', tests.id('invoice'), tests.id('customer'), tests.id('m_owner')) q
select q.to_address, q.channel, q.template, q.status from private.queue_message(tests.id('org'), 'whatsapp', '0803 000 0002', 'reminder', 'Golden reminder', '{}', null, null, tests.id('m_owner')) q
select tests.error_of($q$select private.queue_message(tests.id('org'), 'sms', '0803', 'x', 'y', '{}', null, null, null)$q$)
select url, body ? 'message_id' as has_message from net._requests order by id
