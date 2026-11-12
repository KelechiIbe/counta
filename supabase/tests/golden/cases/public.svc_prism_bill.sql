-- A bill from Prism is written in the owner's name (seen on the new supplier's NIN record; the number is a dummy and
-- is not read back).
-- call
select public.svc_prism_bill(tests.id('org'), '{"prism_id": "PR-GOLD-1", "vendor": {"name": "Golden Prism Vendor", "nin": "00000000001"}, "lines": [{"description": "Flour", "account_code": "5101", "qty": 1, "unit_cost": 1000}]}')->'duplicate'
select b.external_ref, b.total, b.created_by from bills b where b.org_id = tests.id('org') and b.source = 'prism'
select v.name, mb.display_name as nin_recorded_by from vendor_nins n join vendors v on v.id = n.vendor_id left join members mb on mb.id = n.updated_by where n.org_id = tests.id('org')
