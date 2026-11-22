-- Martina's cache and how plans count her messages (20261211000100_martina_cache_counting.sql): tokens Gemini took from a
-- cache and the cache's storage priced on the costs page, one count per message Martina answers (her further steps, voice
-- notes written down and customers' pictures described ride along), and platform averages without team alerts.
-- Only fake people (example.test addresses).
begin;

do $$
begin
  perform tests.remember('ada', tests.user('ada.owner@ikeja.example.test', 'Ada Owner'));
  perform tests.remember('o', tests.org(tests.id('ada'), 'Ikeja Grocers Ltd'));
  delete from usage_events;
  delete from exchange_rates where currency = 'USD';
  insert into exchange_rates (currency, day, rate_ngn, source) values ('USD', current_date - 1, 1000, 'manual');
end $$;

-- svc_usage keeps how many input tokens came from a cache, never more than the input itself.
do $$
declare o uuid := tests.id('o');
begin
  perform public.svc_usage(jsonb_build_object('org_id', o, 'service', 'gemini', 'kind', 'chat', 'item', 'gemini-3.8-flash', 'qty_in', 6000, 'qty_out', 200, 'qty_cached', 5000));
  perform public.svc_usage(jsonb_build_object('org_id', o, 'service', 'gemini', 'kind', 'chat_step', 'item', 'gemini-3.8-flash', 'qty_in', 7000, 'qty_out', 250, 'qty_cached', 9000));
  perform public.svc_usage(jsonb_build_object('org_id', o, 'service', 'gemini', 'kind', 'customer_chat', 'item', 'gemini-3.8-flash', 'qty_in', 3000, 'qty_out', 100));
  perform public.svc_usage(jsonb_build_object('org_id', o, 'service', 'gemini', 'kind', 'transcribe', 'item', 'gemini-3.8-flash', 'qty_in', 1000, 'qty_out', 50));
  perform public.svc_usage(jsonb_build_object('org_id', o, 'service', 'gemini', 'kind', 'customer_chat_step', 'item', 'gemini-3.8-flash', 'qty_in', 3500, 'qty_out', 80, 'qty_cached', -5));
  assert (select qty_cached from usage_events where kind = 'chat') = 5000, 'usage_cached: kept';
  assert (select qty_cached from usage_events where kind = 'chat_step') = 7000, 'usage_cached: never more than the input';
  assert (select qty_cached from usage_events where kind = 'customer_chat') = 0, 'usage_cached: none unless sent';
  assert (select qty_cached from usage_events where kind = 'customer_chat_step') = 0, 'usage_cached: never below nothing';
  -- An older chat function sends no qty_cached at all: still recorded.
  perform public.svc_usage('{"service": "gemini", "kind": "ask", "qty_in": 10, "qty_out": 1}');
  assert (select qty_cached from usage_events where kind = 'ask') = 0, 'usage_cached: older callers still work';
  delete from usage_events where kind = 'ask';
end $$;

-- One count per message Martina answers.
do $$
declare o uuid := tests.id('o');
begin
  assert private.meter_usage(o, 'assistant') = 2, 'one_per_message: a turn of three calls and a customer reply count two';
  perform public.svc_usage(jsonb_build_object('org_id', o, 'service', 'gemini', 'kind', 'whatsapp_media', 'qty_in', 1500, 'qty_out', 100));
  perform public.svc_usage(jsonb_build_object('org_id', o, 'service', 'gemini', 'kind', 'customer_media', 'qty_in', 1500, 'qty_out', 100));
  assert private.meter_usage(o, 'assistant') = 3, 'one_per_message: a picture to Martina counts once, a customer''s picture rides with her reply';
  assert 'customer_chat' = any(private.ai_assistant_kinds()) and not ('chat_step' = any(private.ai_assistant_kinds())), 'one_per_message: kinds';
  assert (select count(*) from usage_events where kind = any(private.ai_assistant_kinds()) and kind = any(private.ai_assistant_extra_kinds())) = 0,
    'one_per_message: a kind is counted or rides along, never both';
  assert (select name from plan_modules where key = 'assistant') = 'Messages to Martina a month', 'one_per_message: the quota says messages';
end $$;

-- What a counted message costs: every call in it, cached tokens at their own rate.
do $$
declare ri numeric; rc numeric; ro numeric; want numeric; d date := (now() at time zone 'Africa/Lagos')::date;
begin
  delete from usage_events where kind in ('whatsapp_media', 'customer_media');
  select price / unit_qty into ri from private.cost_rate_for('gemini', '*', 'input_tokens', d);
  select price / unit_qty into rc from private.cost_rate_for('gemini', '*', 'cached_input_tokens', d);
  select price / unit_qty into ro from private.cost_rate_for('gemini', '*', 'output_tokens', d);
  assert rc * 10 = ri, 'unit_cost: cached input at a tenth of the input price';
  -- Two counted messages (chat, customer_chat); uncached input 1000 + 0 + 3000 + 1000 + 3500, cached 12000, output 680.
  want := round((8500 / 2.0 * ri + 12000 / 2.0 * rc + 680 / 2.0 * ro) * 1000, 2);
  assert private.gemini_unit_cost(private.ai_assistant_kinds(), private.ai_assistant_extra_kinds(), 8000, 450) = want,
    format('unit_cost: per message, got %s want %s', private.gemini_unit_cost(private.ai_assistant_kinds(), private.ai_assistant_extra_kinds(), 8000, 450), want);
  assert private.module_unit_cost('assistant') = want, 'unit_cost: the plan calculator uses it';
  -- The reading quota as before: one call, one count.
  assert private.gemini_call_cost(array['chat'], 0, 0) = round((1000 * ri + 5000 * rc + 200 * ro) * 1000, 2), 'unit_cost: gemini_call_cost unchanged for one call';
  -- Nothing used yet: the stand-in sizes.
  assert private.gemini_unit_cost(array['nothing_yet'], '{}', 8000, 450) = round((8000 * ri + 450 * ro) * 1000, 2), 'unit_cost: stand-in';
end $$;

-- The costs page: input split from cached input, and the cache's own cost with no business named.
do $$
declare o uuid := tests.id('o');
begin
  perform public.svc_usage('{"service": "gemini", "kind": "context_cache", "item": "gemini-3.8-flash", "qty_in": 5000}');
  perform public.svc_usage('{"service": "gemini_cache", "kind": "storage", "item": "gemini-3.8-flash", "qty_in": 1250}');
  assert (select qty from private.cost_usage(now() - interval '1 hour', now() + interval '1 hour') where org_id = o and measure = 'input_tokens') = 8500,
    'costs_page: input without cached tokens';
  assert (select qty from private.cost_usage(now() - interval '1 hour', now() + interval '1 hour') where org_id = o and measure = 'cached_input_tokens') = 12000,
    'costs_page: cached tokens on their own line';
  assert (select qty from private.cost_usage(now() - interval '1 hour', now() + interval '1 hour') where org_id is null and measure = 'input_tokens') = 5000,
    'costs_page: making the cache, at the input price';
  assert (select qty from private.cost_usage(now() - interval '1 hour', now() + interval '1 hour') where org_id is null and measure = 'cache_storage') = 1250,
    'costs_page: storage in token-hours';
  assert (select count(*) from private.cost_usage(now() - interval '1 hour', now() + interval '1 hour') where service = 'gemini_cache') = 0, 'costs_page: storage is Gemini''s';
  assert (select price from private.cost_rate_for('gemini', '*', 'cache_storage', current_date)) = 1.00, 'costs_page: storage rate';
  assert (select price from private.cost_rate_for('gemini', '*', 'cached_input_tokens', '2027-01-02')) = 0.15, 'costs_page: January rate';
end $$;

-- Platform averages leave team alerts out, as each business's own count does.
do $$
declare o uuid := tests.id('o'); v_n int; m uuid;
begin
  select count(*) into v_n from orgs g where not g.is_sample and exists (select 1 from members mb where mb.org_id = g.id and mb.status = 'active');
  delete from messages;
  insert into messages (org_id, channel, to_address, template, subject) values (o, 'whatsapp', '2348030000001', 'alert', 'A question in the books inbox') returning id into m;
  insert into messages (org_id, channel, to_address, template, subject) values (o, 'whatsapp', '2348030000001', 'alert', 'Another alert');
  insert into messages (org_id, channel, to_address, template, subject) values (o, 'whatsapp', '2348030001111', 'reminder', 'Invoice reminder');
  insert into messages (org_id, channel, to_address, template, subject) values (o, 'email', 'ada.owner@ikeja.example.test', 'alert', 'Alert');
  insert into messages (org_id, channel, to_address, template, subject) values (o, 'email', 'chidi@example.test', 'document', 'Invoice');
  update messages set status = 'sent' where org_id = o;
  assert private.meter_usage(o, 'whatsapp') = 1 and private.meter_usage(o, 'emails') = 1, 'averages: each business counts customer messages only';
  assert private.meter_average('whatsapp') = round(1.0 / v_n, 2), format('averages: WhatsApp without alerts (%s)', private.meter_average('whatsapp'));
  assert private.meter_average('emails') = round(1.0 / v_n, 2), 'averages: emails without alerts';
end $$;

rollback;
