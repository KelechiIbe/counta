-- The owner is who gets the alert email; push goes to everyone who keeps the books.
-- callers: definer:owner
-- call
select private.alert_send(tests.id('org'), 'golden', 'k1', array['push', 'email'], '{"title": "Golden alert", "body": "Check the books.", "perm": "keep_books"}')
select to_address, channel, status, template from messages where org_id = tests.id('org') order by to_address, channel, template, status
select u.email, n.kind from notifications n join auth.users u on u.id = n.user_id where n.org_id = tests.id('org') order by u.email, n.kind
