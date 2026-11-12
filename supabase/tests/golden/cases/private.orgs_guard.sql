-- Direct updates of the business row: details by the owner or someone who manages settings, other columns by the owner
-- only, identity never.
-- callers: owner admin accountant staff
-- exec
update orgs set name = 'Golden Foods Renamed' where id = tests.id('org')
update orgs set invoice_note = 'Pay within 14 days' where id = tests.id('org')
update orgs set identity_status = 'verified' where id = tests.id('org')
-- call
select name, invoice_note, identity_status from orgs where id = tests.id('org')
