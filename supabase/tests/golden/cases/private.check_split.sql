-- callers: definer:owner
-- call
select private.check_split('owner', '{"record_sales": true, "edit_prices": true}', 'Owner')::text
select private.check_split('admin', '{"record_sales": true, "edit_prices": true}', 'Admin')::text
select private.check_split('staff', '{"record_sales": true, "edit_prices": true}', 'Staff')::text
