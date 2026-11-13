-- Outbound gate and branding: a business run under full mandate (or read-only after its engagement ended) has Counta write
-- to nobody but the firm and never call; its customers' documents go only while it sends (not in download-only mode); a
-- read-only business sends nothing. A managed business's documents, and the firm business's fee invoices to a full-mandate
-- client, carry no Counta branding. An ordinary business is untouched.
begin;

-- Fixture: a verified practice (engagement partner partner@firm.example.test, office address office@firm.example.test)
-- running a business under full mandate, with a customer, an issued invoice, an approved bill, a supplier invoice waiting
-- for review and a draft purchase order; an ordinary business (owner) with a customer and an issued invoice; the firm's own
-- business (the partner its owner) with two customers and an issued invoice to each.
do $$
declare v_partner uuid; v_owner uuid; v_pr uuid; v_o uuid; v_ord uuid; v_firm uuid; v_cu uuid; v_sale jsonb; v_bill jsonb; v_vendor uuid;
begin
  perform tests.hooks_on();
  v_partner := tests.remember('partner', tests.user('partner@firm.example.test', 'Ngozi Partner'));
  v_owner := tests.remember('owner', tests.user('ob.owner@example.test', 'Ada Owner'));
  perform tests.remember('stranger', tests.user('ob.stranger@example.test', 'Kemi Stranger'));
  v_pr := tests.remember('pr', tests.practice(v_partner, 'Outbound Partners', true));
  update practices set email = 'office@firm.example.test' where id = v_pr;
  v_o := tests.remember('o', tests.managed_org(v_pr, 'Outbound Managed Ltd'));
  perform tests.remember('c', (private.mandate(v_o)).id);
  perform tests.remember('partner_seat', (select id from members where org_id = v_o and user_id = v_partner));
  v_ord := tests.remember('ord', tests.org(v_owner, 'Outbound Ordinary Ltd'));
  v_firm := tests.remember('firm', tests.org(v_partner, 'Outbound Partners Business'));
  update orgs set shop_slug = 'outbound-managed', shop_enabled = true where id = v_o;
  update orgs set shop_slug = 'outbound-ordinary', shop_enabled = true where id = v_ord;

  perform tests.as_user(v_partner);
  v_cu := tests.remember('o_customer', public.save_customer(v_o, '{"name": "Bola Stores", "email": "bola@example.test", "phone": "08031234567"}'));
  v_sale := public.save_sale_doc(v_o, jsonb_build_object('customer_id', v_cu, 'status', 'issue',
    'lines', '[{"description": "Catering", "qty": 1, "unit_price": 20000, "vat_treatment": "standard"}]'::jsonb));
  perform tests.remember('o_invoice', (v_sale->>'id')::uuid);
  v_bill := public.save_bill(v_o, jsonb_build_object('status', 'approve',
    'vendor', '{"name": "Outbound Supplier Ltd", "email": "supplier@example.test", "phone": "08030000003"}'::jsonb,
    'lines', '[{"description": "Flour", "account_code": "5101", "qty": 4, "unit_cost": 5000}]'::jsonb));
  perform tests.remember('o_bill', (v_bill->>'id')::uuid);
  -- The firm's fee customers: the full-mandate client, and another.
  v_cu := tests.remember('fee_cu', public.save_customer(v_firm, '{"name": "Outbound Managed Ltd", "email": "books@firm.example.test"}'));
  v_sale := public.save_sale_doc(v_firm, jsonb_build_object('customer_id', v_cu, 'status', 'issue',
    'lines', '[{"description": "Professional fees", "qty": 1, "unit_price": 250000, "vat_treatment": "standard"}]'::jsonb));
  perform tests.remember('fee_invoice', (v_sale->>'id')::uuid);
  v_cu := tests.remember('other_cu', public.save_customer(v_firm, '{"name": "Other Client Ltd", "email": "other@example.test"}'));
  v_sale := public.save_sale_doc(v_firm, jsonb_build_object('customer_id', v_cu, 'status', 'issue',
    'lines', '[{"description": "Professional fees", "qty": 1, "unit_price": 100000, "vat_treatment": "standard"}]'::jsonb));
  perform tests.remember('other_invoice', (v_sale->>'id')::uuid);
  perform tests.as_user(v_owner);
  v_cu := tests.remember('ord_customer', public.save_customer(v_ord, '{"name": "Tunde Traders", "email": "tunde@example.test", "phone": "08032223333"}'));
  v_sale := public.save_sale_doc(v_ord, jsonb_build_object('customer_id', v_cu, 'status', 'issue',
    'lines', '[{"description": "Catering", "qty": 1, "unit_price": 30000, "vat_treatment": "standard"}]'::jsonb));
  perform tests.remember('ord_invoice', (v_sale->>'id')::uuid);
  perform tests.as_postgres();

  update sales set public_token = 'outbound-fee-token-000000000001' where id = tests.id('fee_invoice');
  update sales set public_token = 'outbound-other-token-0000000001' where id = tests.id('other_invoice');
  update sales set public_token = 'outbound-ordinary-token-000001' where id = tests.id('ord_invoice');
  v_vendor := tests.remember('o_vendor', (select vendor_id from bills where id = tests.id('o_bill')));
  insert into supplier_invoices (org_id, number, source, status, document_path, vendor_id, submitter)
  values (v_o, 'SI-OB-1', 'portal', 'review', v_o::text || '/bills/outbound-portal.pdf', v_vendor, '{"name": "Outbound Supplier", "email": "supplier@example.test"}');
  perform tests.remember('o_si', (select id from supplier_invoices where number = 'SI-OB-1'));
  insert into purchase_orders (org_id, ref, vendor_id, location_id, status, total)
  values (v_o, 'PO-OB-1', v_vendor, (select id from locations where org_id = v_o and is_main), 'draft', 20000);
  perform tests.remember('o_po', (select id from purchase_orders where ref = 'PO-OB-1'));
  update members set phone = '+2348031110000' where id = tests.id('partner_seat');
  -- The partner's WhatsApp, linked to the managed business.
  insert into chat_links (user_id, org_id, channel, phone, status, linked_at) values (v_partner, v_o, 'whatsapp', '2348031110000', 'active', now());
  perform tests.as_postgres();
end $$;

-- test: outbound_ordinary_untouched
-- An ordinary business: messages go where they are addressed, calls are kept, call preferences are its own, nothing logged.
do $$
declare ord uuid := tests.id('ord'); msg public.messages;
begin
  msg := private.queue_message(ord, 'email', 'c@example.test', 'document', 'Invoice', '{}', null, null, null);
  assert msg.status = 'queued', 'outbound_ordinary_untouched';
  assert exists (select 1 from net._requests where body->>'message_id' = msg.id::text), 'outbound_ordinary_untouched: the messaging hook is called';
  insert into messages (org_id, channel, to_address, template, subject, params) values (ord, 'email', 'anyone@example.test', 'alert', 'Ordinary alert', '{}');
  assert (select status = 'queued' and to_address = 'anyone@example.test' and params = '{}' from messages where org_id = ord and subject = 'Ordinary alert'),
    'outbound_ordinary_untouched: an alert stays as addressed';
  insert into voice_calls (org_id, kind, to_number, status) values (ord, 'reminder', '+2348000000000', 'queued');
  assert (select count(*) from voice_calls where org_id = ord) = 1, 'outbound_ordinary_untouched: the call is kept';
  update orgs set alert_prefs = '{"owner_calls": true, "customer_calls": true}' where id = ord;
  assert (private.alert_prefs(ord)->>'owner_calls')::boolean and (private.alert_prefs(ord)->>'customer_calls')::boolean,
    'outbound_ordinary_untouched: call preferences are the business''s';
  update orgs set alert_prefs = '{}' where id = ord;
  assert (private.alert_prefs(ord)->>'owner_calls')::boolean and not (private.alert_prefs(ord)->>'customer_calls')::boolean,
    'outbound_ordinary_untouched: call preference defaults';
  assert not exists (select 1 from activity_log where org_id = ord), 'outbound_ordinary_untouched: nothing logged';
  perform tests.as_postgres();
end $$;

-- test: outbound_alert_readdressed
-- An alert email to an address that is not the firm's goes to the firm instead: the mandate's alert address, else the
-- business's contact (the engagement partner); other messages to such addresses are not sent.
do $$
declare o uuid := tests.id('o'); c uuid := tests.id('c'); msg public.messages;
begin
  insert into messages (org_id, channel, to_address, template, params) values (o, 'email', 'client-owner@example.test', 'alert', '{}');
  assert (select to_address from messages where org_id = o and template = 'alert') = 'partner@firm.example.test', 'outbound_alert_readdressed';
  assert (select status = 'queued' and (params->>'readdressed')::boolean and error is null from messages where org_id = o and template = 'alert'),
    'outbound_alert_readdressed: queued, marked readdressed';
  -- Through queue_message: the mandate's alert address first, and the messaging hook is called for it.
  update practice_clients set alert_email = 'Alerts@Firm.Example.Test' where id = c;
  msg := private.queue_message(o, 'email', 'Client-Owner@Example.Test', 'alert', 'Readdressed', '{"kind": "invoices"}', null, null, null);
  assert msg.to_address = 'alerts@firm.example.test' and msg.status = 'queued' and (msg.params->>'readdressed')::boolean and msg.params->>'kind' = 'invoices',
    'outbound_alert_readdressed: to the mandate''s alert address';
  assert exists (select 1 from net._requests where body->>'message_id' = msg.id::text), 'outbound_alert_readdressed: the messaging hook is called';
  -- No firm address to turn to (the contact's address is not the firm's either): not sent.
  update practice_clients set alert_email = null where id = c;
  update members set email = 'client-owner@example.test' where id = tests.id('partner_seat');
  msg := private.queue_message(o, 'email', 'client-owner@example.test', 'alert', 'Nowhere to go', '{}', null, null, null);
  assert msg.status = 'suppressed' and msg.error = 'Not sent: not_firm_address' and msg.to_address = 'client-owner@example.test',
    'outbound_alert_readdressed: no firm address, not sent';
  assert not exists (select 1 from net._requests where body->>'message_id' = msg.id::text), 'outbound_alert_readdressed: no hook for a message not sent';
  update members set email = 'partner@firm.example.test' where id = tests.id('partner_seat');
  -- An invitation or a WhatsApp alert to someone outside the firm is not sent, and is logged.
  insert into messages (org_id, channel, to_address, template, subject, params) values (o, 'email', 'client-owner@example.test', 'invite', 'Join', '{}');
  insert into messages (org_id, channel, to_address, template, subject, params) values (o, 'whatsapp', '+2348099999999', 'alert', 'WhatsApp out', '{}');
  assert (select count(*) from messages where org_id = o and subject in ('Join', 'WhatsApp out') and status = 'suppressed' and error = 'Not sent: not_firm_address'
            and to_address in ('client-owner@example.test', '+2348099999999')) = 2,
    'outbound_alert_readdressed: invitation and WhatsApp alert not sent';
  assert (select count(*) from activity_log where org_id = o and action = 'message_suppressed' and after->>'reason' = 'not_firm_address') = 3,
    'outbound_alert_readdressed: each logged';
  assert (select after = '{"reason": "not_firm_address", "channel": "whatsapp", "template": "alert"}' and label = 'alert' and source = 'event'
            and practice_id = tests.id('pr') from activity_log where org_id = o and action = 'message_suppressed' and after->>'channel' = 'whatsapp'),
    'outbound_alert_readdressed: what the log keeps';
  perform tests.as_postgres();
end $$;

-- test: outbound_firm_address_case
-- The firm's addresses, whatever their case or spacing: its people's, its own, the mandate's alert address, and its
-- people's linked WhatsApp numbers.
do $$
declare o uuid := tests.id('o'); c uuid := tests.id('c'); v_off uuid;
begin
  insert into messages (org_id, channel, to_address, template, subject, params) values (o, 'email', ' Partner@Firm.Example.Test ', 'alert', 'Case', '{}');
  assert (select status = 'queued' and coalesce(params->>'readdressed', '') = '' from messages where org_id = o and subject = 'Case'),
    'outbound_firm_address_case: firm address kept';
  update practice_clients set alert_email = 'alerts@firm.example.test' where id = c;
  insert into messages (org_id, channel, to_address, template, subject, params) values
    (o, 'email', 'OFFICE@firm.example.test', 'alert', 'Office', '{}'),
    (o, 'email', 'alerts@firm.example.test', 'invite', 'Alert address', '{}'),
    (o, 'whatsapp', '+2348031110000', 'alert', 'Partner WhatsApp', '{}');
  assert (select count(*) from messages where org_id = o and subject in ('Office', 'Alert address', 'Partner WhatsApp') and status = 'queued'
            and params = '{}') = 3,
    'outbound_firm_address_case: the practice''s address, the alert address, the partner''s WhatsApp';
  assert private.firm_addresses(o) @> array['partner@firm.example.test', 'office@firm.example.test', 'alerts@firm.example.test'],
    'outbound_firm_address_case: firm_addresses';
  -- Someone who left the firm, or is in another practice, is not the firm.
  v_off := tests.user('ob.former@firm.example.test', 'Femi Former');
  perform tests.practice_member(tests.id('pr'), v_off, 'staff');
  update practice_members set status = 'disabled' where user_id = v_off;
  perform tests.practice(tests.id('stranger'), 'Elsewhere Partners', true);
  assert not (private.firm_addresses(o) && array['ob.former@firm.example.test', 'ob.stranger@example.test']),
    'outbound_firm_address_case: not a disabled member or another practice''s';
  insert into messages (org_id, channel, to_address, template, subject, params) values (o, 'email', 'ob.former@firm.example.test', 'alert', 'Former', '{}');
  assert (select to_address = 'alerts@firm.example.test' and (params->>'readdressed')::boolean from messages where org_id = o and subject = 'Former'),
    'outbound_firm_address_case: a former member''s address is readdressed';
  -- Customers' documents still go while the business sends; a signed-in partner's send fires the gate as Counta.
  perform tests.as_user(tests.id('partner'));
  perform public.send_document(tests.id('o_invoice'), 'email');
  perform tests.as_postgres();
  assert (select status = 'queued' and to_address = 'bola@example.test' from messages where org_id = o and template = 'document'),
    'outbound_firm_address_case: a customer document goes';
  perform tests.as_postgres();
end $$;

-- test: outbound_download_only
do $$
declare o uuid := tests.id('o'); msg public.messages;
begin
  update orgs set send_mode = 'download_only' where id = o;
  insert into messages (org_id, channel, to_address, template, subject, params) values (o, 'email', 'bola@example.test', 'document', 'Download only', '{}');
  assert (select status = 'suppressed' and error = 'Not sent: download_only' from messages where org_id = o and subject = 'Download only'), 'outbound_download_only';
  assert exists (select 1 from activity_log where org_id = o and action = 'message_suppressed' and label = 'document'
                 and after = '{"reason": "download_only", "channel": "email", "template": "document"}'), 'outbound_download_only: logged';
  msg := private.queue_message(o, 'whatsapp', '08031234567', 'reminder', 'Reminder', '{}', null, null, null);
  assert msg.status = 'suppressed' and not exists (select 1 from net._requests where body->>'message_id' = msg.id::text),
    'outbound_download_only: queue_message does not call the hook';
  -- Alerts to the firm still go.
  insert into messages (org_id, channel, to_address, template, subject, params) values (o, 'email', 'partner@firm.example.test', 'alert', 'Firm in download only', '{}');
  assert (select status = 'queued' from messages where org_id = o and subject = 'Firm in download only'), 'outbound_download_only: alerts to the firm go';
  -- What a person presses says so.
  perform tests.as_user(tests.id('partner'));
  perform tests.throws($q$select public.send_document(tests.id('o_invoice'), 'email')$q$, '%set to download only%');
  perform tests.throws($q$select public.send_document(tests.id('o_invoice'), 'email')$q$,
    '42501: This business is set to download only. Download the document and send it yourself.');
  perform tests.throws($q$select public.send_reminder(tests.id('o_invoice'), 'whatsapp')$q$, '42501: %set to download only%');
  perform tests.throws($q$select public.send_statement(tests.id('o_customer'), 'email')$q$, '42501: %set to download only%');
  perform tests.throws($q$select public.return_bill(tests.id('o_bill'), '{"reason": "missing_tin", "send": "email"}')$q$, '42501: %set to download only%');
  perform tests.throws($q$select public.reject_supplier_invoice(tests.id('o_si'), '{"reason": "Wrong amount."}')$q$, '42501: %set to download only%');
  -- Without sending, the same actions work.
  perform public.reject_supplier_invoice(tests.id('o_si'), '{"reason": "Wrong amount.", "send": false}');
  perform public.return_bill(tests.id('o_bill'), '{"reason": "missing_tin"}');
  perform tests.as_postgres();
  assert (select status from supplier_invoices where id = tests.id('o_si')) = 'rejected' and (select status from bills where id = tests.id('o_bill')) = 'void',
    'outbound_download_only: no sending, no refusal';
  -- The permission check comes first.
  perform tests.as_user(tests.id('stranger'));
  perform tests.throws($q$select public.send_document(tests.id('o_invoice'), 'email')$q$, '%not a member of this business%');
  perform tests.as_postgres();
  update orgs set send_mode = 'send' where id = o;
  perform tests.as_postgres();
end $$;

-- test: outbound_read_only
-- A read-only business sends nothing, not even to the firm.
do $$
declare o uuid := tests.id('o'); ord uuid := tests.id('ord');
begin
  update orgs set read_only_at = now() where id = o;
  insert into messages (org_id, channel, to_address, template, subject, params) values (o, 'email', 'partner@firm.example.test', 'alert', 'Read only', '{}');
  assert (select status = 'suppressed' and error = 'Not sent: read_only' and to_address = 'partner@firm.example.test' from messages where org_id = o and subject = 'Read only'),
    'outbound_read_only';
  assert private.outbound_check(o, 'call', 'reminder', null) = 'read_only' and private.outbound_check(o, 'email', 'document', 'bola@example.test') = 'read_only',
    'outbound_read_only: read-only before anything else';
  perform tests.as_user(tests.id('partner'));
  perform tests.throws($q$select public.send_document(tests.id('o_invoice'), 'email')$q$, '42501: This business is read-only: its engagement has ended.');
  perform tests.throws($q$select public.prepare_vendor_call(tests.id('o_po'))$q$, '42501: This business is read-only: its engagement has ended.');
  perform tests.as_postgres();
  insert into voice_calls (org_id, kind, to_number, status) values (o, 'tax_deadline', '+2348031110000', 'queued');
  assert not exists (select 1 from voice_calls where org_id = o), 'outbound_read_only: no call';
  update orgs set read_only_at = null where id = o;
  -- A business that is not run by a practice but is read-only sends nothing either.
  update orgs set read_only_at = now() where id = ord;
  assert private.outbound_check(ord, 'email', 'alert', 'ob.owner@example.test') = 'read_only', 'outbound_read_only: any read-only business';
  update orgs set read_only_at = null where id = ord;
  perform tests.as_postgres();
end $$;

-- test: outbound_calls
do $$
declare o uuid := tests.id('o'); p uuid := tests.id('partner');
begin
  insert into voice_calls (org_id, kind, to_number, status) values (o, 'reminder', '+2348000000000', 'queued');
  assert (select count(*) from voice_calls where org_id = o) = 0 and exists (select 1 from activity_log where org_id = o and action = 'call_suppressed'), 'outbound_calls';
  assert (select count(*) from activity_log where org_id = o and action = 'call_suppressed' and label = 'reminder' and after = '{"kind": "reminder"}') = 1,
    'outbound_calls: the call''s kind is kept';
  update orgs set alert_prefs = '{"owner_calls": true, "customer_calls": true}' where id = o;
  assert not (private.alert_prefs(o)->>'owner_calls')::boolean and not (private.alert_prefs(o)->>'customer_calls')::boolean, 'outbound_calls: prefs off';
  perform tests.as_user(p);
  perform tests.throws(format('select public.prepare_reminder_call(%L, %L)', tests.id('partner_seat'), 'count_approval'),
    '42501: Counta does not make calls for a business run under full mandate.');
  perform tests.throws($q$select public.prepare_vendor_call(tests.id('o_po'))$q$, '42501: Counta does not make calls for a business run under full mandate.');
  -- A signed-in person cannot write a call (or a log entry through one) directly.
  perform tests.throws(format('insert into voice_calls (org_id, kind, to_number, topic) values (%L, %L, %L, %L)', o, 'reminder', '+2348000000000', 'Forged'),
    '42501: permission denied for table voice_calls');
  perform tests.as_anon();
  perform tests.throws(format('insert into voice_calls (org_id, kind, to_number, topic) values (%L, %L, %L, %L)', o, 'reminder', '+2348000000000', 'Forged'),
    '42501: permission denied for table voice_calls');
  perform tests.as_postgres();
  assert not exists (select 1 from activity_log where org_id = o and label = 'Forged'), 'outbound_calls: nothing forged';
  perform tests.as_postgres();
end $$;

-- test: outbound_alerts_tick
-- The morning alerts reach the managed business, and the gate keeps them with the firm: no message queued to an address that
-- is not the firm's, no call. An ordinary business with the same invoices gets its customer call.
do $$
declare o uuid := tests.id('o'); ord uuid := tests.id('ord');
begin
  -- An invoice that went overdue yesterday (the invoices alert) and one long overdue, reminded three days ago (a customer call).
  update sales set due_date = private.local_day(org_id, now()) - 1 where id = tests.id('o_invoice');
  update sales set due_date = private.local_day(org_id, now()) - 10, reminded_at = now() - interval '3 days' where id = tests.id('ord_invoice');
  perform tests.as_user(tests.id('partner'));
  perform public.save_sale_doc(o, jsonb_build_object('customer_id', tests.id('o_customer'), 'status', 'issue',
    'lines', '[{"description": "Long overdue", "qty": 1, "unit_price": 50000, "vat_treatment": "standard"}]'::jsonb));
  perform tests.as_postgres();
  update sales set due_date = private.local_day(org_id, now()) - 10, reminded_at = now() - interval '3 days'
  where org_id = o and id <> tests.id('o_invoice') and doc_type = 'invoice';
  update orgs set alert_prefs = '{"owner_calls": true, "customer_calls": true}' where id in (o, ord);
  -- The contact's address on the business is not the firm's; the mandate has an alert address.
  update members set email = 'client-owner@example.test' where id = tests.id('partner_seat');
  update practice_clients set alert_email = 'alerts@firm.example.test' where id = tests.id('c');
  perform private.alerts_tick();
  assert exists (select 1 from messages where org_id = o and params->>'automatic' = 'true' and params->>'kind' = 'invoices' and channel = 'email'
                 and to_address = 'alerts@firm.example.test' and status = 'queued' and (params->>'readdressed')::boolean),
    'outbound_alerts_tick: the invoices alert reached the business and went to the firm';
  assert not exists (select 1 from messages where org_id = o and params->>'automatic' = 'true' and status <> 'suppressed'
                     and ((channel = 'email' and lower(trim(to_address)) <> all (private.firm_addresses(o)))
                       or (channel = 'whatsapp' and to_address <> '+2348031110000'))),
    'outbound_alerts_tick: nothing queued to an address that is not the firm''s';
  assert not exists (select 1 from voice_calls where org_id = o), 'outbound_alerts_tick: no call';
  assert exists (select 1 from voice_calls where org_id = ord and kind = 'customer_followup'), 'outbound_alerts_tick: the ordinary business''s call';
  update members set email = 'partner@firm.example.test' where id = tests.id('partner_seat');
  update orgs set alert_prefs = '{}' where id in (o, ord);
  perform tests.as_postgres();
end $$;

-- test: svc_message_flags
do $$
declare o uuid := tests.id('o'); ord uuid := tests.id('ord'); v uuid; r jsonb;
begin
  v := (private.queue_message(o, 'email', 'partner@firm.example.test', 'alert', 'Flags', '{}', null, null, null)).id;
  perform tests.as_service();
  r := public.svc_message(v);
  perform tests.as_postgres();
  assert (r->>'managed')::boolean and (r->>'alert_to_allowed')::boolean and (r->'org'->>'white_label')::boolean, 'svc_message_flags';
  assert not (r->'org'->>'pay_online')::boolean and r->>'status' = 'sending', 'svc_message_flags: no online payment before identity';
  -- An ordinary business's message.
  v := (private.queue_message(ord, 'email', 'tunde@example.test', 'document', 'Ordinary flags', '{}', tests.id('ord_invoice'), tests.id('ord_customer'), null)).id;
  perform tests.as_service();
  r := public.svc_message(v);
  perform tests.as_postgres();
  assert not (r->>'managed')::boolean and (r->>'alert_to_allowed')::boolean and not (r->'org'->>'white_label')::boolean
     and (r->'org'->>'pay_online')::boolean = private.payments_open(ord),
    'svc_message_flags: an ordinary business';
  -- Picked up after the business stopped sending: not sent, and logged; one already sent is left alone.
  v := (private.queue_message(o, 'email', 'bola@example.test', 'document', 'Then download only', '{}', null, null, null)).id;
  perform private.queue_message(o, 'email', 'bola@example.test', 'document', 'Sent earlier', '{}', null, null, null);
  update messages set status = 'sent' where org_id = o and subject = 'Sent earlier';
  update orgs set send_mode = 'download_only' where id = o;
  perform tests.as_service();
  r := public.svc_message(v);
  perform tests.as_postgres();
  assert r is null and (select status = 'suppressed' and error = 'Not sent: download_only' and attempts = 0 from messages where id = v),
    'svc_message_flags: suppressed when picked up';
  assert (select count(*) from activity_log where org_id = o and action = 'message_suppressed' and after->>'reason' = 'download_only') = 3,
    'svc_message_flags: logged';
  perform tests.as_service();
  r := public.svc_message((select id from messages where org_id = o and subject = 'Sent earlier'));
  perform tests.as_postgres();
  assert r is null and (select status = 'sent' and error is null from messages where org_id = o and subject = 'Sent earlier'),
    'svc_message_flags: a sent message stays sent';
  update orgs set send_mode = 'send' where id = o;
  perform tests.as_postgres();
end $$;

-- test: white_label_fee_customer
-- The firm's own business (F) is not white label, except to the full-mandate client it bills (its fee customer).
do $$
declare f uuid := tests.id('firm'); cu uuid := tests.id('fee_cu'); other_cu uuid := tests.id('other_cu'); c uuid := tests.id('c');
begin
  update practices set firm_org_id = f where id = tests.id('pr');
  update practice_clients set fee_customer_id = cu where id = c;
  assert private.white_label(f, cu) and not private.white_label(f, other_cu) and not private.white_label(f), 'white_label_fee_customer';
  assert private.white_label(tests.id('o')) and not private.white_label(tests.id('ord')) and not private.white_label(tests.id('ord'), cu),
    'white_label_fee_customer: a managed business, an ordinary one';
  -- Only while the full mandate is active, and only for the practice whose firm business it is.
  update practice_clients set status = 'ended' where id = c;
  assert not private.white_label(f, cu), 'white_label_fee_customer: mandate ended';
  update practice_clients set status = 'active' where id = c;
  update practices set firm_org_id = null where id = tests.id('pr');
  assert not private.white_label(f, cu), 'white_label_fee_customer: not the practice''s firm business';
  update practices set firm_org_id = f where id = tests.id('pr');
  assert private.white_label(f, cu), 'white_label_fee_customer: back';
  perform tests.as_postgres();
end $$;

-- test: org_brand_keys
-- The business's branding gains white_label and pay_online; the customer's documents, the public page, the shop and the
-- messages carry them.
do $$
declare ord uuid := tests.id('ord'); o uuid := tests.id('o'); f uuid := tests.id('firm'); b jsonb; r jsonb; v uuid;
begin
  b := private.org_brand(ord);
  assert not (private.org_brand(ord)->>'white_label')::boolean and (private.org_brand(ord)->>'pay_online')::boolean = private.payments_open(ord), 'org_brand_keys';
  assert (select array_agg(k order by k) from jsonb_object_keys(b) k) = (select array_agg(k order by k) from unnest(array['name', 'address', 'phone',
      'email', 'tin', 'rc_number', 'logo_path', 'receipt_footer', 'vat_registered', 'timezone', 'brand_color', 'invoice_template', 'website',
      'invoice_footer', 'payment_details', 'invoice_show', 'reply_to_email', 'white_label', 'pay_online']) k),
    'org_brand_keys: today''s keys and the two new ones';
  assert (private.org_brand(o)->>'white_label')::boolean and not (private.org_brand(o)->>'pay_online')::boolean, 'org_brand_keys: a managed business';
  assert to_regprocedure('private.org_brand(uuid)') is null, 'org_brand_keys: the one-argument function is gone';
  -- The firm business's invoice to its full-mandate client (practices.firm_org_id and fee_customer_id from the test above).
  perform tests.as_anon();
  assert (public.public_document('outbound-fee-token-000000000001')->'org'->>'white_label')::boolean, 'org_brand_keys: public document';
  assert not (public.public_document('outbound-other-token-0000000001')->'org'->>'white_label')::boolean, 'org_brand_keys: public document, another client';
  assert not (public.public_document('outbound-ordinary-token-000001')->'org'->>'white_label')::boolean, 'org_brand_keys: public document, ordinary';
  assert (public.shop_catalog('outbound-managed')->'shop'->>'white_label')::boolean, 'org_brand_keys: shop';
  assert not (public.shop_catalog('outbound-ordinary')->'shop'->>'white_label')::boolean, 'org_brand_keys: ordinary shop';
  perform tests.as_postgres();
  -- The fee invoice's message to the client is white label; to another customer it is not.
  v := (private.queue_message(f, 'email', 'books@firm.example.test', 'document', 'Fee invoice', '{}', tests.id('fee_invoice'), tests.id('fee_cu'), null)).id;
  perform tests.as_service();
  r := public.svc_message(v);
  perform tests.as_postgres();
  assert (r->'org'->>'white_label')::boolean and not (r->>'managed')::boolean and (r->>'alert_to_allowed')::boolean, 'org_brand_keys: fee invoice message';
  v := (private.queue_message(f, 'email', 'other@example.test', 'document', 'Other fee invoice', '{}', tests.id('other_invoice'), tests.id('other_cu'), null)).id;
  perform tests.as_service();
  r := public.svc_message(v);
  perform tests.as_postgres();
  assert not (r->'org'->>'white_label')::boolean, 'org_brand_keys: another customer''s message';
  -- The signed-in view of a sale carries it too.
  perform tests.as_user(tests.id('partner'));
  assert (public.get_sale(tests.id('fee_invoice'))->'org'->>'white_label')::boolean, 'org_brand_keys: get_sale';
  perform tests.as_postgres();
end $$;

-- test: outbound_helpers_revoked
do $$
declare f text;
begin
  foreach f in array array['private.firm_addresses(uuid)', 'private.outbound_check(uuid, text, text, text)', 'private.require_outbound(uuid, text, text)',
    'private.white_label(uuid, uuid)', 'private.org_brand(uuid, uuid)', 'private.messages_outbound()', 'private.voice_calls_mandate()',
    'private.alert_prefs(uuid)', 'private.queue_message(uuid, text, text, text, text, jsonb, uuid, uuid, uuid)', 'private.sale_json(uuid, boolean)'] loop
    assert not has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute'),
      format('outbound_helpers_revoked: %s', f);
  end loop;
  -- The triggers record events (activity_event is revoked from users) whoever writes, so they run as their owner.
  assert (select bool_and(prosecdef) from pg_proc where oid in ('private.messages_outbound()'::regprocedure, 'private.voice_calls_mandate()'::regprocedure)),
    'outbound_helpers_revoked: the trigger functions are security definer';
  assert exists (select 1 from pg_trigger where tgrelid = 'public.messages'::regclass and tgname = 'messages_outbound'
                 and tgfoid = 'private.messages_outbound()'::regprocedure)
     and exists (select 1 from pg_trigger where tgrelid = 'public.voice_calls'::regclass and tgname = 'voice_calls_mandate'
                 and tgfoid = 'private.voice_calls_mandate()'::regprocedure),
    'outbound_helpers_revoked: the triggers';
  assert not has_table_privilege('authenticated', 'public.voice_calls', 'insert') and not has_table_privilege('anon', 'public.voice_calls', 'insert'),
    'outbound_helpers_revoked: no direct call writes';
  assert has_function_privilege('service_role', 'public.svc_message(uuid)', 'execute')
     and not has_function_privilege('authenticated', 'public.svc_message(uuid)', 'execute')
     and not has_function_privilege('anon', 'public.svc_message(uuid)', 'execute'),
    'outbound_helpers_revoked: svc_message for the service only';
  assert has_function_privilege('anon', 'public.shop_catalog(text)', 'execute') and has_function_privilege('anon', 'public.public_document(text)', 'execute')
     and has_function_privilege('authenticated', 'public.send_document(uuid, text, text)', 'execute')
     and not has_function_privilege('anon', 'public.send_document(uuid, text, text)', 'execute'),
    'outbound_helpers_revoked: public grants kept';
  assert exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'practices' and column_name = 'firm_org_id'),
    'outbound_helpers_revoked: practices.firm_org_id';
  perform tests.as_postgres();
end $$;

rollback;
