-- Only the owner gets as far as the month-end check.
-- call
select public.close_books(tests.id('org'), '2026-10-15')
