-- call
select public.update_sales_settings(tests.id('org'), '{"invoice_terms_days": 14}')
