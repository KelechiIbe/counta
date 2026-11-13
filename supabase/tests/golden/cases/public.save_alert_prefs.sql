-- call
select public.save_alert_prefs(tests.id('org'), '{"email": false}')
select alert_prefs from orgs where id = tests.id('org')
