-- The practice's lead or someone who manages the business's team ends the work; the practice's seats are switched off.
-- callers: definer:partner definer:owner definer:admin definer:accountant definer:staff
-- call
select public.practice_end(tests.id('client'))
select display_name, role, status, practice_id is not null as practice_seat, p_keep_books, p_make_payments, p_manage_team from members where org_id = tests.id('org') order by display_name
select status, ended_by is not null as ended_by from practice_clients where id = tests.id('client')
select u.email, n.kind, n.title from notifications n join auth.users u on u.id = n.user_id order by u.email, n.kind, n.title
