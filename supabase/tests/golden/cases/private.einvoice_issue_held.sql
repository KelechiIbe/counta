-- A held draft with no one recorded as issuing it is posted in the owner's name.
-- callers: definer:owner
-- setup
update sales set created_by = null where id = tests.id('invoice_draft');
-- call
select private.einvoice_issue_held(tests.id('invoice_draft'))::text
select s.status, mb.display_name from sales s join journals j on j.id = s.journal_id left join members mb on mb.id = j.posted_by where s.id = tests.id('invoice_draft')
