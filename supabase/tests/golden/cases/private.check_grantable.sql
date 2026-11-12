-- call
select private.check_grantable((select m from members m where m.org_id = tests.id('org') and m.user_id = auth.uid()), '{"manage_team": true, "make_payments": true}')::text
