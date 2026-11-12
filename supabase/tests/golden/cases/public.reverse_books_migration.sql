-- setup
insert into books_migrations (org_id, source, as_of, status) values (tests.id('org'), 'other', '2026-01-01', 'draft');
select tests.remember('migration', (select id from books_migrations where org_id = tests.id('org')));
-- call
select public.reverse_books_migration(tests.id('migration'), 'Golden reason')
