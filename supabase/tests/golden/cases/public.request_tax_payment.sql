-- call
select public.request_tax_payment(tests.id('org'), '{"kind": "vat", "period": "2026-09-01", "tax_reference": "REF-1"}')
