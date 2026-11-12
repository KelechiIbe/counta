-- callers: definer:owner
-- setup
update orgs set alert_prefs = '{"whatsapp": false, "customer_calls": true}' where id = tests.id('org');
-- call
select private.alert_prefs(tests.id('org'))
