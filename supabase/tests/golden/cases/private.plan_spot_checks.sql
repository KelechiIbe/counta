-- Spot checks go to someone who counts stock other than the owner, even one who sold some of the items lately (only
-- the owner and the staff member count stock here).
-- callers: definer:owner
-- setup
insert into items (org_id, name, price) values (tests.id('org'), 'Golden Flour', 1500);
insert into stock_levels (item_id, location_id, org_id, qty)
select i.id, l.id, tests.id('org'), 10 from items i, locations l where i.org_id = tests.id('org') and i.name = 'Golden Flour' and l.org_id = tests.id('org') and l.is_main;
update members set p_count_stock = false where id = tests.id('m_admin');
insert into movements (org_id, type, item_id, location_id, qty, author_id, recorded_at)
select tests.id('org'), 'sale', i.id, l.id, -2, tests.id('m_staff'), now() - interval '1 day'
from items i, locations l where i.org_id = tests.id('org') and i.name = 'Golden Flour' and l.org_id = tests.id('org') and l.is_main;
-- call
select private.plan_spot_checks(tests.id('org'), 1)
select cs.area, mb.display_name as assignee from count_sessions cs join members mb on mb.id = cs.assignee_id where cs.org_id = tests.id('org')
select u.email, n.kind from notifications n join auth.users u on u.id = n.user_id where n.org_id = tests.id('org') order by u.email, n.kind
