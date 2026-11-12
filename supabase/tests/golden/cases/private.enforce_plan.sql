-- A plan with a seat limit already reached: a new person is refused, an owner's place is not counted.
-- callers: definer:owner
-- setup
insert into org_entitlement_overrides (org_id, module_key, included, quota, enforce) values (tests.id('org'), 'users', true, 4, 'block');
-- exec
insert into members (org_id, email, display_name, role, status) values (tests.id('org'), 'extra.staff@example.test', 'Extra Staff', 'staff', 'invited')
insert into members (org_id, email, display_name, role, status) values (tests.id('org'), 'co.owner@example.test', 'Co Owner', 'owner', 'invited')
-- call
select display_name, role, status from members where org_id = tests.id('org') order by display_name
