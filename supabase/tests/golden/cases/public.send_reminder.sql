-- call
select public.send_reminder(tests.id('invoice'), 'email') #- '{params,link}'
select to_address, channel, status, template, subject from messages where org_id = tests.id('org') order by to_address, channel, template
