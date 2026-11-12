-- call
select private.doc_can((select m from members m where m.org_id = tests.id('org') and m.user_id = auth.uid()))
