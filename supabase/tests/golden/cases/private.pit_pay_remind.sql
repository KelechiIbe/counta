-- A personal income tax account fetched an hour ago and not paid: the person who asked for it and the owner are
-- reminded.
-- callers: definer:owner
-- setup
insert into pit_people (org_id, name, source) values (tests.id('org'), 'Golden Director', 'cac');
insert into pit_person_years (org_id, accounting_year, person_id, bill)
select tests.id('org'), 2025, p.id, jsonb_build_object('amount', 5000, 'transfer', jsonb_build_object('amount', 5000, 'asked_by', tests.id('m_admin'),
  'fetched_at', to_char((now() - interval '1 hour') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))
from pit_people p where p.org_id = tests.id('org');
-- call
select private.pit_pay_remind()
select to_address, channel, status, template from messages where org_id = tests.id('org') order by to_address, channel, template, status
select u.email, n.kind from notifications n join auth.users u on u.id = n.user_id where n.org_id = tests.id('org') order by u.email, n.kind
