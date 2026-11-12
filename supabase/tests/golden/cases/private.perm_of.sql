-- call
select private.perm_of((select m from members m where m.org_id = tests.id('org') and m.user_id = auth.uid()), 'owner') as owner, private.perm_of((select m from members m where m.org_id = tests.id('org') and m.user_id = auth.uid()), 'manage_team') as manage_team, private.perm_of((select m from members m where m.org_id = tests.id('org') and m.user_id = auth.uid()), 'file_tax') as file_tax
