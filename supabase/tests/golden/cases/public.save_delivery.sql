-- Payment on delivery needs the owner, a manager or someone who approves adjustments.
-- call
select public.save_delivery(tests.id('org'), jsonb_build_object('sale_id', tests.id('invoice'), 'collect_on_delivery', true)) - 'id' - 'sale_id'
