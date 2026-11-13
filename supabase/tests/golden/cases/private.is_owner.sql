-- Policy helper, called as the signed-in person.
-- callers: owner admin accountant staff
-- call
select private.is_owner(tests.id('org'))
