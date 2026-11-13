-- call
select public.record_takings(tests.id('org'), (select id from locations where org_id = tests.id('org') and is_main), '2026-11-01', 1000, 200, 300)::text
select cash, pos, transfers, source from cash_takings where org_id = tests.id('org')
