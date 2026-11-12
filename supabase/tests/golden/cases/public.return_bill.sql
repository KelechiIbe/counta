-- The approved bill goes back to the supplier by email.
-- call
select public.return_bill(tests.id('bill'), '{"reason": "missing_tin", "send": "email"}')
select to_address, channel, status, template, subject from messages where org_id = tests.id('org') order by to_address, channel, template
