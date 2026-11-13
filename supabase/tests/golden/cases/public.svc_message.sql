-- The messaging function picks up a queued message, with the business's branding.
-- setup
select tests.remember('message', (private.queue_message(tests.id('org'), 'email', 'customer@example.test', 'document', 'Golden subject', '{}', tests.id('invoice'), tests.id('customer'), tests.id('m_owner'))).id);
-- call
select public.svc_message(tests.id('message'))
select status, attempts from messages where id = tests.id('message')
