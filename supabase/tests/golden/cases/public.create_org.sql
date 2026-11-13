-- Whoever creates a business is its owner; its email defaults to theirs.
-- callers: owner admin accountant staff anon
-- call
select public.create_org('Golden New Ltd', null, null, 'Golden Founder') is not null as created
select o.name, o.email, o.identity_status, o.vat_registered, m.role, m.title, m.display_name, m.p_manage_team, m.p_make_payments from orgs o join members m on m.org_id = o.id where o.name = 'Golden New Ltd'
