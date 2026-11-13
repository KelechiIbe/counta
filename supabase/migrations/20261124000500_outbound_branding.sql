-- Practice management, part 5: the outbound gate (silence) and the branding resolver.
--
-- A business run by a practice under full mandate (orgs.managed_by) is silent to its client: Counta writes only to the firm
-- and never calls. Its customers and suppliers still get their documents, unless the firm set it to download only
-- (orgs.send_mode). A business made read-only when its engagement ended (orgs.read_only_at) sends nothing at all.
--   private.firm_addresses(org)        the firm's email addresses: the managing practice's active people, the practice's
--                                      own address, the mandate's alert address.
--   private.outbound_check(org, channel, kind, to)
--                                      null when a message (or a call, channel 'call') may go, else why not: read_only,
--                                      calls_off, not_firm_address (an alert, invitation or practice message to someone
--                                      outside the firm), download_only. Always null for an ordinary business.
--   messages_outbound                  BEFORE INSERT on messages: an alert email to someone outside the firm goes to the
--                                      firm instead (the mandate's alert address, else the business's contact, while that
--                                      is the firm's); anything else that may not go is kept with status 'suppressed' and
--                                      logged (activity_event 'message_suppressed').
--   voice_calls_mandate                BEFORE INSERT on voice_calls: a call for a managed or read-only business is dropped
--                                      and logged (activity_event 'call_suppressed').
--   private.require_outbound(org, channel, kind)
--                                      the same check where a person presses send or call, with a plain refusal.
--   public.svc_message                 checks again when the message is picked up, and tells the messaging function
--                                      whether the business is managed and the address allowed (it fails closed).
-- private.alert_prefs turns the owner's and customers' calls off for a managed business, and private.queue_message calls the
-- messaging function only for a message still queued.
--
-- Branding: private.white_label(org, customer) is true for a managed business, and for the firm business's documents to
-- a full-mandate client it bills (practices.firm_org_id, practice_clients.fee_customer_id). private.org_brand(org, customer)
-- adds white_label and pay_online (payments_open) to the business's branding; sale_json passes the sale's customer, so the
-- public document carries it, svc_message passes the message's, and the public shop says whether it is white label.
--
-- For an ordinary business nothing changes: outbound_check is null, the gate and the call trigger return the row as it came,
-- and the call preferences are the business's own (the golden baseline proves the rewritten functions identical).

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------
alter table public.messages drop constraint if exists messages_status_check;
alter table public.messages add constraint messages_status_check
  check (status in ('queued', 'sending', 'sent', 'delivered', 'read', 'failed', 'suppressed'));

-- The practice's own Counta business (it bills its clients' fees from there).
alter table public.practices add column if not exists firm_org_id uuid references public.orgs(id) on delete set null;
create index if not exists practices_firm_org on public.practices(firm_org_id) where firm_org_id is not null;

-- Calls are written only by Counta's own functions. A signed-in person never had a policy to write one; the call trigger
-- below drops a managed business's call before row security looks at it, so the grant goes too (else a direct insert
-- would put an event in another business's log).
revoke insert on public.voice_calls from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The gate
-- ---------------------------------------------------------------------------
-- The firm's email addresses for a business it runs, lower-cased and trimmed.
create or replace function private.firm_addresses(p_org uuid) returns text[]
language sql stable set search_path = public, private as $$
  select coalesce(array_agg(distinct a.addr), '{}')
  from (
    select lower(trim(pm.email)) as addr from orgs o join practice_members pm on pm.practice_id = o.managed_by and pm.status = 'active' where o.id = p_org
    union all
    select lower(trim(p.email)) from orgs o join practices p on p.id = o.managed_by where o.id = p_org
    union all
    select lower(trim((private.mandate(p_org)).alert_email))
  ) a
  where coalesce(a.addr, '') <> ''
$$;

-- Null when the message or call may go, else the reason. p_channel is 'email', 'whatsapp' or 'call'; p_kind the message
-- template (or the call's kind).
create or replace function private.outbound_check(p_org uuid, p_channel text, p_kind text, p_to text) returns text
language plpgsql stable set search_path = public, private as $$
declare o public.orgs;
begin
  select * into o from orgs where id = p_org;
  if not found or (o.managed_by is null and o.read_only_at is null) then return null; end if;
  if o.read_only_at is not null then return 'read_only'; end if;
  if p_channel = 'call' then return 'calls_off'; end if;
  if p_kind in ('alert', 'invite', 'practice') then
    if p_channel = 'email' and lower(trim(p_to)) = any (private.firm_addresses(p_org)) then return null; end if;
    -- The WhatsApp number linked by someone working the business for the practice.
    if p_channel = 'whatsapp' and exists (
        select 1 from members m cross join lateral private.wa_number(m.user_id, p_org) w
        where m.org_id = p_org and m.status = 'active' and m.practice_id = o.managed_by and m.user_id is not null
          and private.clean_phone(w.phone) = private.clean_phone(p_to)) then
      return null;
    end if;
    return 'not_firm_address';
  end if;
  if o.send_mode = 'download_only' then return 'download_only'; end if;
  return null;
end $$;

-- Every message as it is written. Security definer: it records an event (activity_event is not the signed-in person's to
-- call) whoever writes the message.
create or replace function private.messages_outbound() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_reason text := private.outbound_check(new.org_id, new.channel, new.template, new.to_address); v_to text;
begin
  if v_reason is null then return new; end if;
  -- An alert email to someone outside the firm goes to the firm instead, while there is a firm address to turn to.
  if v_reason = 'not_firm_address' and new.channel = 'email' and new.template = 'alert' then
    v_to := coalesce(lower(trim((private.mandate(new.org_id)).alert_email)), lower((private.org_contact(new.org_id)).email));
    if v_to = any (private.firm_addresses(new.org_id)) then
      new.to_address := v_to;
      new.params := coalesce(new.params, '{}'::jsonb) || jsonb_build_object('readdressed', true);
      return new;
    end if;
  end if;
  new.status := 'suppressed';
  new.error := 'Not sent: ' || v_reason;
  perform private.activity_event(new.org_id, 'message_suppressed', new.template,
    jsonb_build_object('template', new.template, 'channel', new.channel, 'reason', v_reason));
  return new;
end $$;

drop trigger if exists messages_outbound on public.messages;
create trigger messages_outbound before insert on public.messages for each row execute function private.messages_outbound();

-- Every call as it is written: none for a business run by a practice or read-only. Security definer, as above.
create or replace function private.voice_calls_mandate() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.org_id is null or private.outbound_check(new.org_id, 'call', new.kind, new.to_number) is null then return new; end if;
  perform private.activity_event(new.org_id, 'call_suppressed', coalesce(new.topic, new.kind), jsonb_build_object('kind', new.kind));
  return null;
end $$;

drop trigger if exists voice_calls_mandate on public.voice_calls;
create trigger voice_calls_mandate before insert on public.voice_calls for each row execute function private.voice_calls_mandate();

-- Where a person presses send or call: the same check, refused in plain words.
create or replace function private.require_outbound(p_org uuid, p_channel text, p_kind text) returns void
language plpgsql stable set search_path = public, private as $$
declare v_reason text := private.outbound_check(p_org, p_channel, p_kind, null);
begin
  if v_reason is null then return; end if;
  raise exception '%', case v_reason
    when 'read_only' then 'This business is read-only: its engagement has ended.'
    when 'download_only' then 'This business is set to download only. Download the document and send it yourself.'
    when 'calls_off' then 'Counta does not make calls for a business run under full mandate.'
    else 'Under full mandate Counta only writes to the firm.' end
    using errcode = '42501';
end $$;

-- ---------------------------------------------------------------------------
-- 3. Alerts and the message queue
-- ---------------------------------------------------------------------------
-- The business's alert preferences: no calls to the owner or to customers for a business run by a practice.
create or replace function private.alert_prefs(p_org uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object(
    'email', coalesce((o.alert_prefs->>'email')::boolean, true),
    'whatsapp', coalesce((o.alert_prefs->>'whatsapp')::boolean, true),
    'owner_calls', o.managed_by is null and coalesce((o.alert_prefs->>'owner_calls')::boolean, true),
    'customer_calls', o.managed_by is null and coalesce((o.alert_prefs->>'customer_calls')::boolean, false),
    'platform', private.setting('alerts'))
  from orgs o where o.id = p_org
$$;

-- As before, except that the messaging function is called only for a message still queued (not one the gate kept back).
create or replace function private.queue_message(p_org uuid, p_channel text, p_to text, p_template text, p_subject text, p_params jsonb,
  p_sale uuid, p_customer uuid, p_by uuid) returns public.messages
language plpgsql security definer set search_path = public, private as $$
declare msg public.messages; v_to text; v_cc text[];
begin
  if p_channel = 'whatsapp' then
    v_to := private.clean_phone(p_to);
    if v_to is null or length(v_to) < 11 then raise exception 'Add a WhatsApp number for the customer.'; end if;
  elsif p_channel = 'email' then
    v_to := lower(trim(p_to));
    if v_to is null or v_to !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Add an email address for the customer.'; end if;
    if p_customer is not null then
      select array(select e from unnest(cc_emails) e where e <> v_to) into v_cc from customers where id = p_customer;
    end if;
  else
    raise exception 'Send by email or WhatsApp.';
  end if;
  if (select count(*) from messages where org_id = p_org and created_at > now() - interval '1 hour') >= 500 then
    raise exception 'Too many messages this hour. Try again later.';
  end if;
  insert into messages (org_id, channel, to_address, template, subject, params, sale_id, customer_id, created_by)
  values (p_org, p_channel, v_to, p_template, p_subject,
    coalesce(p_params, '{}'::jsonb) || case when coalesce(array_length(v_cc, 1), 0) > 0 then jsonb_build_object('cc', to_jsonb(v_cc)) else '{}'::jsonb end,
    p_sale, p_customer, p_by) returning * into msg;
  if msg.status = 'queued' then
    perform private.call_function('messaging', jsonb_build_object('message_id', msg.id));
  end if;
  return msg;
end $$;

-- The messaging function's pick-up: a message that may no longer go (the business went read-only or download-only since,
-- or the address is no longer the firm's) is suppressed instead. Otherwise as before, with the branding for the message's
-- customer, whether the business is managed, and whether the address is allowed (the function refuses to send if not).
create or replace function public.svc_message(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare msg public.messages; v_reason text;
begin
  select * into msg from messages where id = p_id;
  if found and msg.status in ('queued', 'failed') then
    v_reason := private.outbound_check(msg.org_id, msg.channel, msg.template, msg.to_address);
    if v_reason is not null then
      update messages set status = 'suppressed', error = 'Not sent: ' || v_reason, updated_at = now() where id = p_id;
      perform private.activity_event(msg.org_id, 'message_suppressed', msg.template,
        jsonb_build_object('template', msg.template, 'channel', msg.channel, 'reason', v_reason));
      return null;
    end if;
  end if;
  if found and msg.template = 'alert' and msg.channel = 'whatsapp' and msg.status in ('queued', 'failed') and msg.params ? 'link_id'
     and not exists (select 1 from chat_links l where l.id = (msg.params->>'link_id')::uuid and l.status = 'active' and l.channel = 'whatsapp') then
    update messages set status = 'failed', error = 'The WhatsApp number was unlinked before this alert went.', updated_at = now() where id = p_id;
    return null;
  end if;
  update messages set status = 'sending', attempts = attempts + 1, updated_at = now()
  where id = p_id and status in ('queued', 'failed') and attempts < 5 and (send_after is null or send_after <= now())
  returning * into msg;
  if not found then return null; end if;
  return to_jsonb(msg) || jsonb_build_object('org', private.org_brand(msg.org_id, msg.customer_id), 'managed', private.is_managed(msg.org_id),
    'alert_to_allowed', private.outbound_check(msg.org_id, msg.channel, msg.template, msg.to_address) is null);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Sends and calls a person presses
-- ---------------------------------------------------------------------------
-- Each is its latest definition with the outbound check added after the permission check.
create or replace function public.send_document(p_sale uuid, p_channel text, p_to text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members; msg public.messages; o public.orgs; v_label text;
begin
  select * into s from sales where id = p_sale;
  if not found then raise exception 'Sale not found.'; end if;
  m := private.require(s.org_id, 'record_sales');
  perform private.require_outbound(s.org_id, p_channel, case when s.doc_type = 'receipt' then 'receipt' when s.doc_type = 'order' then 'order' else 'document' end);
  if exists (select 1 from einvoice_docs d where d.sale_id = s.id and d.kind = 'clear' and d.state in ('waiting', 'sending')) then
    raise exception 'NRS has not signed % yet. It can be sent once NRS signs it.', s.number;
  end if;
  if exists (select 1 from einvoice_docs d where d.sale_id = s.id and d.kind = 'clear' and d.state = 'refused') then
    raise exception 'NRS refused %. Put it right and send it to NRS again first.', s.number;
  end if;
  if s.status = 'draft' then raise exception 'Issue it before sending.'; end if;
  select * into o from orgs where id = s.org_id;
  v_label := case s.doc_type when 'receipt' then 'Receipt' when 'invoice' then 'Invoice' when 'quote' then 'Quote' when 'order' then 'Order' else 'Credit note' end;
  msg := private.queue_message(s.org_id, p_channel, coalesce(nullif(trim(p_to), ''), case when p_channel = 'whatsapp' then s.customer_phone else s.customer_email end),
    case when s.doc_type = 'receipt' then 'receipt' when s.doc_type = 'order' then 'order' else 'document' end,
    v_label || ' ' || s.number || ' from ' || o.name,
    jsonb_build_object('customer_name', s.customer_name, 'business', o.name, 'doc_label', v_label, 'number', s.number, 'total', s.total,
      'balance', case when s.doc_type in ('invoice', 'order', 'receipt') then s.total - s.amount_paid - s.credited else 0 end,
      'due_date', s.due_date, 'link', private.doc_link(s.public_token), 'reply_to', coalesce(o.reply_to_email, o.email), 'business_phone', o.phone),
    s.id, s.customer_id, m.id);
  update sales set sent_at = now() where id = s.id;
  return to_jsonb(msg);
end $$;

create or replace function public.send_reminder(p_sale uuid, p_channel text default 'whatsapp') returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members; msg public.messages; o public.orgs;
begin
  select * into s from sales where id = p_sale;
  if not found then raise exception 'Sale not found.'; end if;
  m := private.require(s.org_id, 'record_sales');
  perform private.require_outbound(s.org_id, p_channel, 'reminder');
  if s.status not in ('open', 'partially_paid') then raise exception '% has nothing owed.', s.number; end if;
  if (select is_walk_in from customers where id = s.customer_id) then raise exception 'There is no customer to remind.'; end if;
  select * into o from orgs where id = s.org_id;
  msg := private.queue_message(s.org_id, p_channel, case when p_channel = 'whatsapp' then s.customer_phone else s.customer_email end, 'reminder',
    'Payment reminder: ' || s.number || ' from ' || o.name,
    jsonb_build_object('customer_name', s.customer_name, 'business', o.name, 'number', s.number, 'balance', s.total - s.amount_paid - s.credited,
      'due_date', s.due_date, 'link', private.doc_link(s.public_token), 'reply_to', coalesce(o.reply_to_email, o.email), 'business_phone', o.phone),
    s.id, s.customer_id, m.id);
  update sales set reminded_at = now() where id = s.id;
  return to_jsonb(msg);
end $$;

create or replace function public.send_statement(p_customer uuid, p_channel text default 'email') returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.customers; m public.members; msg public.messages; o public.orgs; v_bal numeric; v_token text;
begin
  select * into c from customers where id = p_customer;
  if not found then raise exception 'Customer not found.'; end if;
  m := private.require(c.org_id, 'record_sales');
  perform private.require_outbound(c.org_id, p_channel, 'statement');
  select * into o from orgs where id = c.org_id;
  v_bal := private.customer_balance(c.org_id, c.id);
  -- The statement links to the oldest open document, which shows everything still owed.
  select public_token into v_token from sales where customer_id = c.id and status in ('open', 'partially_paid') order by due_date limit 1;
  msg := private.queue_message(c.org_id, p_channel, case when p_channel = 'whatsapp' then c.phone else c.email end, 'statement',
    'Your statement from ' || o.name,
    jsonb_build_object('customer_name', c.name, 'business', o.name, 'balance', v_bal, 'link', case when v_token is not null then private.doc_link(v_token) end,
      'open_items', (select coalesce(jsonb_agg(jsonb_build_object('number', number, 'due_date', due_date, 'balance', total - amount_paid - credited) order by due_date), '[]'::jsonb)
        from sales where customer_id = c.id and status in ('open', 'partially_paid')),
      'reply_to', coalesce(o.reply_to_email, o.email), 'business_phone', o.phone),
    null, c.id, m.id);
  return to_jsonb(msg);
end $$;

-- Only a bill sent back with a note to the supplier is checked; without sending it goes back as before.
create or replace function public.return_bill(p_bill uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; v public.vendors; m public.members; v_reason text := coalesce(nullif(p->>'reason', ''), 'other'); v_note text;
  v_send text := nullif(p->>'send', ''); v_to text; msg public.messages; v_ref text; v_label text;
begin
  select * into b from bills where id = p_bill for update;
  if not found then raise exception 'Bill not found.'; end if;
  m := private.require(b.org_id, 'keep_books');
  if v_send is not null then perform private.require_outbound(b.org_id, v_send, 'bill_returned'); end if;
  if v_reason not in ('missing_tin', 'missing_state', 'other') then raise exception 'Say why the bill goes back.'; end if;
  if b.status not in ('draft', 'approved') then raise exception '% is %. Only a bill not yet paid goes back to the supplier.', b.number, replace(b.status, '_', ' '); end if;
  if b.source = 'receipt' then
    raise exception '% came from a stock receipt, so the goods are in. Add the Tax ID or the state to the supplier instead.', b.number;
  end if;
  if exists (select 1 from bill_payments where bill_id = b.id and status in ('paid', 'processing')) then
    raise exception '% has payments. Ask the supplier for a credit note instead.', b.number;
  end if;
  if exists (select 1 from fixed_assets where bill_id = b.id and status = 'active') then raise exception 'An asset from % is in use.', b.number; end if;
  select * into v from vendors where id = b.vendor_id;
  v_note := coalesce(nullif(trim(p->>'note'), ''), private.return_note(v_reason));
  if v_note is null then raise exception 'Write what the supplier should know.'; end if;
  -- One line of plain text: it goes in an email subject and a WhatsApp template.
  v_ref := left(coalesce(nullif(trim(regexp_replace(b.vendor_ref, '[[:cntrl:]\s]+', ' ', 'g')), ''), b.number), 60);
  v_label := case v_reason when 'missing_tin' then 'no Tax ID' when 'missing_state' then 'no address for the state revenue service' else 'see the note' end;
  -- Out of the books first, as a void bill.
  if b.journal_id is not null then
    perform private.reverse_entry(b.journal_id, m.id, 'Bill ' || b.number || ' sent back to ' || v.name || ': ' || v_label, null);
    update fixed_assets set status = 'rejected', notes = concat_ws(' · ', notes, 'Bill sent back') where bill_id = b.id and status = 'pending_confirmation';
  end if;
  update bills set status = 'void', voided_by = m.id, voided_at = now(), void_reason = 'Sent back to the supplier: ' || v_label,
    returned_reason = v_reason, returned_note = left(v_note, 2000), returned_at = now(), returned_by = m.id
  where id = b.id;
  if v_send is not null then
    if v_send not in ('email', 'whatsapp') then raise exception 'Send it by email or WhatsApp.'; end if;
    v_to := coalesce(nullif(trim(p->>'to'), ''), case when v_send = 'email' then v.email else v.phone end);
    if v_to is null or (v_send = 'whatsapp' and length(coalesce(private.clean_phone(v_to), '')) < 11)
       or (v_send = 'email' and v_to !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then
      raise exception 'Add % for %, or send the note yourself.', case when v_send = 'email' then 'an email address' else 'a WhatsApp number' end, v.name;
    end if;
    msg := private.queue_message(b.org_id, v_send, v_to, 'bill_returned', 'Invoice ' || v_ref || ' returned',
      jsonb_build_object('customer_name', v.name, 'business', (select name from orgs where id = b.org_id), 'number', v_ref, 'total', b.total,
        'reason', v_reason, 'note', left(v_note, 2000)), null, null, m.id);
    update messages set vendor_id = v.id, bill_id = b.id where id = msg.id;
  end if;
  return private.bill_json(b.id);
end $$;

-- Only a rejection that tells the supplier is checked, once the channel is known.
create or replace function public.reject_supplier_invoice(p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare si public.supplier_invoices; m public.members; b public.bills; v public.vendors; o public.orgs; v_note text := private.si_text(p->>'reason', 1000);
  v_send boolean := coalesce((p->>'send')::boolean, true); v_to text; v_ch text; msg public.messages; v_ref text;
begin
  select * into si from supplier_invoices where id = p_id for update;
  if not found then raise exception 'Invoice not found.'; end if;
  m := private.require(si.org_id, 'keep_books');
  if si.status not in ('review', 'failed') then raise exception '% is %.', si.number, si.status; end if;
  if v_note is null then raise exception 'Write why the invoice is rejected; the supplier sees it.'; end if;
  select * into b from bills where id = si.bill_id;
  select * into v from vendors where id = si.vendor_id;
  select * into o from orgs where id = si.org_id;
  if v_send then
    select r.channel, r.address into v_ch, v_to from private.si_contact(si.submitter, v) r;
    perform private.require_outbound(si.org_id, v_ch, 'bill_returned');
    if v_to is null then raise exception 'There is no email address or WhatsApp number for the supplier. Add one to %, or reject it without telling them.', coalesce(v.name, 'the supplier'); end if;
  end if;
  if b.id is not null and b.status = 'draft' then
    perform public.return_bill(b.id, jsonb_build_object('reason', 'other', 'note', v_note));
  elsif b.id is not null and b.status = 'approved' then
    raise exception '% is already approved. Send the bill back from Bills instead.', b.number;
  end if;
  if v_send then
    v_ref := left(coalesce(nullif(trim(regexp_replace(si.extract->>'invoice_no', '[[:cntrl:]\s]+', ' ', 'g')), ''), b.vendor_ref, si.number), 60);
    msg := private.queue_message(si.org_id, v_ch, v_to, 'bill_returned', 'Invoice ' || v_ref || ' returned',
      jsonb_build_object('customer_name', coalesce(nullif(trim(si.submitter->>'name'), ''), v.name, 'there'), 'business', o.name, 'number', v_ref,
        'total', coalesce(b.total, private.si_num(si.extract->'total')), 'reason', 'other', 'note', v_note), null, null, m.id);
    update messages set vendor_id = v.id, bill_id = b.id, supplier_invoice_id = si.id where id = msg.id;
  end if;
  update supplier_invoices set status = 'rejected', rejected_reason = v_note, decided_by = m.id, decided_at = now() where id = si.id;
  return private.si_json(si.id) || jsonb_build_object('sent_to', v_to, 'sent_by', v_ch);
end $$;

create or replace function public.prepare_reminder_call(p_member uuid, p_topic text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare t public.members; m public.members; o public.orgs; v_to text; v_details text; v_action text; v_n int; v_id uuid; v_vars jsonb;
begin
  select * into t from members where id = p_member;
  if not found then raise exception 'Team member not found.'; end if;
  m := private.require(t.org_id, null);
  if not (m.role in ('owner', 'manager') or m.acts_as_owner) and m.id <> t.id then raise exception 'Only owners and managers can send reminder calls.' using errcode = '42501'; end if;
  perform private.require_outbound(t.org_id, 'call', 'reminder');
  if t.status <> 'active' then raise exception '% is not active in this business.', t.display_name; end if;
  v_to := private.e164(t.phone);
  if v_to is null then raise exception 'Add a phone number for % first (for example 0803 123 4567).', t.display_name; end if;
  select * into o from orgs where id = t.org_id;
  case p_topic
    when 'count_approval' then
      select count(*), string_agg(c.ref || ' (' || c.area || ' at ' || lc.name || ')', ', ') into v_n, v_details
      from count_sessions c join locations lc on lc.id = c.location_id
      where c.org_id = t.org_id and c.status in ('awaiting_approval', 'awaiting_reasons');
      if v_n = 0 then raise exception 'No counts are waiting for approval.'; end if;
      v_details := v_n || ' stock count' || case when v_n > 1 then 's are' else ' is' end || ' waiting for approval: ' || v_details || '.';
      v_action := 'Open Counta, go to Stock counts, give a reason for each difference and approve or reject the count.';
    when 'count_due' then
      select count(*), string_agg(c.ref || ' (' || c.area || ' at ' || lc.name || ')', ', ') into v_n, v_details
      from count_sessions c join locations lc on lc.id = c.location_id
      where c.org_id = t.org_id and c.status = 'open' and (c.assignee_id = t.id or c.assignee_id is null);
      if v_n = 0 then raise exception 'No open counts are assigned to %.', t.display_name; end if;
      v_details := v_n || ' stock count' || case when v_n > 1 then 's are' else ' is' end || ' waiting to be done: ' || v_details || '.';
      v_action := 'Open the Counta phone app, tap Count, and count the shelf without looking at the expected numbers.';
    when 'receipts_review' then
      select count(*), string_agg(r.ref || ' from ' || coalesce(nullif(r.vendor_name, ''), 'a vendor'), ', ') into v_n, v_details
      from receipts r where r.org_id = t.org_id and r.status = 'needs_review';
      if v_n = 0 then raise exception 'No invoices are waiting to be confirmed.'; end if;
      v_details := v_n || ' supplier invoice' || case when v_n > 1 then 's are' else ' is' end || ' read and waiting to be confirmed: ' || v_details || '.';
      v_action := 'Open Counta, go to Receive stock, check the lines Martina was unsure about and post the receipt.';
    when 'transfer_confirm' then
      select count(*), string_agg(tr.ref || ', ' || private.fmt_qty(tr.qty) || ' ' || i.selling_unit || ' of ' || i.name, '; ') into v_n, v_details
      from transfers tr join items i on i.id = tr.item_id
      where tr.org_id = t.org_id and tr.status = 'in_transit' and (t.location_id is null or tr.to_location_id = t.location_id);
      if v_n = 0 then raise exception 'No transfers are waiting to be confirmed for %.', t.display_name; end if;
      v_details := v_n || ' transfer' || case when v_n > 1 then 's are' else ' is' end || ' on the way and not yet confirmed: ' || v_details || '.';
      v_action := 'When the goods arrive, open the Counta phone app and confirm the transfer so the stock moves into the branch.';
    when 'price_proposals' then
      select count(*), string_agg(i.name, ', ') into v_n, v_details
      from price_proposals p join items i on i.id = p.item_id where p.org_id = t.org_id and p.status = 'open';
      if v_n = 0 then raise exception 'No price checks are open.'; end if;
      v_details := v_n || ' price check' || case when v_n > 1 then 's are' else ' is' end || ' open because costs moved: ' || v_details || '.';
      v_action := 'Open Counta, go to Pricing, and apply or keep each suggested price.';
    else raise exception 'Choose what the call is about.';
  end case;
  v_vars := jsonb_build_object('business_name', o.name, 'person_name', t.display_name, 'person_first_name', split_part(t.display_name, ' ', 1),
    'caller_name', m.display_name, 'task_details', v_details, 'task_action', v_action);
  insert into voice_calls (org_id, kind, member_id, topic, to_number, variables, created_by)
  values (t.org_id, 'reminder', t.id, p_topic, v_to, v_vars, m.id)
  returning id into v_id;
  return jsonb_build_object('call_id', v_id, 'to_number', v_to, 'variables', v_vars);
end $$;

create or replace function public.prepare_vendor_call(p_po uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare po public.purchase_orders; m public.members; v public.vendors; o public.orgs; l public.locations; v_to text; v_lines text; v_id uuid; v_vars jsonb;
begin
  select * into po from purchase_orders where id = p_po;
  if not found then raise exception 'Purchase order not found.'; end if;
  m := private.require(po.org_id, 'approve_pos');
  perform private.require_outbound(po.org_id, 'call', 'vendor_order');
  if po.status not in ('draft', 'sent') then raise exception 'This order is already %.', po.status; end if;
  select * into v from vendors where id = po.vendor_id;
  if v.id is null then raise exception 'This order has no vendor.'; end if;
  v_to := private.e164(v.phone);
  if v_to is null then raise exception 'Add a phone number for % first (for example 0803 123 4567).', v.name; end if;
  if exists (select 1 from voice_calls where po_id = po.id and status in ('queued', 'ringing', 'in_progress') and created_at > now() - interval '15 minutes') then
    raise exception 'Martina is already on a call about %.', po.ref;
  end if;
  select * into o from orgs where id = po.org_id;
  select * into l from locations where id = po.location_id;
  select string_agg(private.fmt_qty(pl.qty) || ' ' || lower(i.purchase_unit) || case when pl.qty <> 1 and right(lower(i.purchase_unit), 1) <> 's' then 's' else '' end
           || ' of ' || i.name
           || case when pl.unit_cost > 0 then ' at ₦' || to_char(pl.unit_cost, 'FM999,999,990') || ' each' else '' end, '; ' order by i.name)
    into v_lines
  from po_lines pl join items i on i.id = pl.item_id where pl.po_id = po.id;
  v_vars := jsonb_build_object(
    'business_name', o.name, 'vendor_name', v.name, 'po_ref', po.ref, 'order_lines', coalesce(v_lines, 'no lines'),
    'order_total', case when po.total > 0 then '₦' || to_char(po.total, 'FM999,999,990') else 'to be confirmed' end,
    'delivery_branch', coalesce(l.name, 'the main branch') || coalesce(', ' || nullif(l.address, ''), ''),
    'contact_name', m.display_name, 'contact_phone', coalesce(nullif(m.phone, ''), nullif(o.phone, ''), 'the number on the order'),
    'lead_time_days', v.lead_time_days);
  insert into voice_calls (org_id, kind, po_id, vendor_id, to_number, variables, created_by)
  values (po.org_id, 'vendor_order', po.id, v.id, v_to, v_vars, m.id)
  returning id into v_id;
  return jsonb_build_object('call_id', v_id, 'to_number', v_to, 'variables', v_vars);
end $$;

-- ---------------------------------------------------------------------------
-- 5. Branding
-- ---------------------------------------------------------------------------
-- No Counta branding: a business run by a practice, or the firm business's documents to a full-mandate client it bills.
create or replace function private.white_label(p_org uuid, p_customer uuid default null) returns boolean
language sql stable set search_path = public, private as $$
  select private.is_managed(p_org) or exists (
    select 1 from practice_clients c join practices p on p.id = c.practice_id
    where p.firm_org_id = p_org and c.fee_customer_id = p_customer and c.mode = 'full' and c.status = 'active')
$$;

-- The business's branding for a document or message, for the customer it goes to (if any). The signature changes, so the
-- one-argument function goes; its callers pass one argument and get the customer default.
drop function if exists private.org_brand(uuid);
create function private.org_brand(p_org uuid, p_customer uuid default null) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('name', o.name, 'address', o.address, 'phone', o.phone, 'email', o.email, 'tin', o.tin, 'rc_number', o.rc_number,
    'logo_path', o.logo_path, 'receipt_footer', o.receipt_footer, 'vat_registered', o.vat_registered, 'timezone', o.timezone,
    'brand_color', o.brand_color, 'invoice_template', o.invoice_template, 'website', o.website, 'invoice_footer', o.invoice_footer,
    'payment_details', o.invoice_note, 'invoice_show', o.invoice_show, 'reply_to_email', coalesce(o.reply_to_email, o.email),
    'white_label', private.white_label(o.id, p_customer), 'pay_online', private.payments_open(o.id))
  from orgs o where o.id = p_org
$$;

-- As before, with the sale's customer passed to the branding.
create or replace function private.sale_json(p_sale uuid, p_cost boolean) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select to_jsonb(s) || jsonb_build_object(
    'cost_total', case when p_cost then (select sum(cost) from sale_lines where sale_id = s.id) end,
    'balance', case when s.doc_type in ('receipt', 'invoice', 'order') and s.status not in ('void', 'draft', 'converted', 'cancelled') then s.total - s.amount_paid - s.credited
                    when s.doc_type = 'credit_note' then s.total - s.credited else 0 end,
    'pending', (select coalesce(sum(a.amount), 0) from collection_allocations a join collections c on c.id = a.collection_id where a.sale_id = s.id and c.status = 'pending'),
    'confirmed', s.journal_id is not null,
    'location_name', (select name from locations where id = s.location_id),
    'created_by_name', (select display_name from members where id = s.created_by),
    'overdue_days', case when s.status in ('open', 'partially_paid') and s.due_date is not null then greatest(private.local_day(s.org_id, now()) - s.due_date, 0) end,
    'org', private.org_brand(s.org_id, s.customer_id),
    'customer', (select jsonb_build_object('city', c.city, 'state', c.state, 'country', c.country, 'contact_person', c.contact_person)
      from customers c where c.id = s.customer_id),
    'vat_statuses', (select coalesce(jsonb_agg(distinct l.vat_status), '[]'::jsonb) from sale_lines l where l.sale_id = s.id),
    'lines', (select coalesce(jsonb_agg(to_jsonb(l) - 'cost' - 'org_id' || jsonb_build_object('cost', case when p_cost then l.cost end) order by l.line_no), '[]'::jsonb)
              from sale_lines l where l.sale_id = s.id),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'number', c.number, 'method', c.method, 'status', c.status, 'direction', c.direction,
        'amount', a.amount, 'collection_amount', c.amount, 'fee', c.fee, 'received_at', c.received_at, 'reference', c.reference, 'bank_account_id', c.bank_account_id,
        'confirmed_by_name', (select display_name from members where id = c.confirmed_by)) order by c.received_at), '[]'::jsonb)
      from collection_allocations a join collections c on c.id = a.collection_id where a.sale_id = s.id),
    'refunds', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'number', c.number, 'method', c.method, 'amount', c.amount, 'received_at', c.received_at)), '[]'::jsonb)
      from collections c where c.sale_id = s.id and c.direction = 'out'),
    'credits', (select coalesce(jsonb_agg(jsonb_build_object('credit_note_id', ca.credit_note_id, 'number', cn.number, 'amount', ca.amount)), '[]'::jsonb)
      from credit_allocations ca join sales cn on cn.id = ca.credit_note_id where ca.sale_id = s.id and ca.credit_note_id <> s.id),
    'applied_to', (select coalesce(jsonb_agg(jsonb_build_object('sale_id', ca.sale_id, 'number', x.number, 'amount', ca.amount)), '[]'::jsonb)
      from credit_allocations ca join sales x on x.id = ca.sale_id where ca.credit_note_id = s.id and ca.sale_id <> s.id),
    'credit_notes', (select coalesce(jsonb_agg(jsonb_build_object('id', cn.id, 'number', cn.number, 'total', cn.total, 'status', cn.status)), '[]'::jsonb)
      from sales cn where cn.original_sale_id = s.id and cn.doc_type = 'credit_note'),
    'original_number', (select number from sales where id = s.original_sale_id),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'method', r.method, 'status', r.status, 'amount', r.amount, 'account_number', r.account_number,
        'bank_name', r.bank_name, 'account_name', r.account_name, 'link_url', r.link_url, 'expires_at', r.expires_at, 'tx_ref', r.tx_ref,
        'direct', r.direct, 'pay_ref', r.pay_ref) order by r.created_at desc), '[]'::jsonb)
      from payment_requests r where r.sale_id = s.id),
    'deliveries', (select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at), '[]'::jsonb) from deliveries d where d.sale_id = s.id),
    'journal_ref', (select ref from journals where id = s.journal_id),
    'customer_credit', case when s.doc_type in ('receipt', 'invoice', 'order') and not (select is_walk_in from customers where id = s.customer_id) then
        (select coalesce(sum(total - credited), 0) from sales cn where cn.customer_id = s.customer_id and cn.doc_type = 'credit_note' and cn.status = 'open')
        + greatest(private.customer_advance(s.org_id, s.customer_id), 0) end,
    'einvoice', (select jsonb_build_object('irn', e.irn, 'kind', e.kind, 'state', e.state, 'held', e.held, 'qr', e.qr, 'note', e.note, 'signed_at', e.signed_at,
        'tries', e.tries, 'next_try_at', e.next_try_at, 'pay_status', e.pay_status, 'platform_keys', e.platform_keys,
        'buyer', case when e.xm_state is null then null else jsonb_build_object('state', e.xm_state, 'note', e.xm_note, 'at', e.xm_at, 'sent_at', e.xm_sent_at,
          'tries', e.xm_tries, 'next_at', e.xm_next_at) end)
      from einvoice_docs e where e.sale_id = s.id))
  from sales s where s.id = p_sale
$$;

-- As before, with shop.white_label.
create or replace function public.shop_catalog(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs;
begin
  select * into o from orgs where shop_slug = lower(trim(p_slug)) and shop_enabled;
  if not found then raise exception 'This shop is not open.'; end if;
  return jsonb_build_object(
    'shop', jsonb_build_object('slug', o.shop_slug, 'name', o.name, 'title', coalesce(o.shop_title, o.name), 'note', o.shop_note, 'whatsapp', o.shop_whatsapp,
      'phone', o.phone, 'email', o.email, 'address', o.address, 'website', o.website, 'logo_path', o.logo_path, 'banner_path', o.shop_banner_path,
      'tagline', o.shop_tagline, 'brand_color', o.brand_color, 'socials', o.shop_socials, 'delivery_fee', o.shop_delivery_fee, 'pickup', o.shop_pickup,
      'delivery', o.shop_delivery, 'pay_on_delivery', o.shop_pay_on_delivery, 'min_order', o.shop_min_order,
      'pickup_address', (select coalesce(nullif(l.address, ''), o.address) from locations l where l.id = coalesce(o.shop_location_id,
        (select id from locations where org_id = o.id order by is_main desc, created_at limit 1))),
      'vat_registered', o.vat_registered, 'prices_include_vat', o.prices_include_vat,
      'online_payments', exists (select 1 from wallets w where w.org_id = o.id and w.rail = o.payment_rail and w.status = 'active'),
      'white_label', private.white_label(o.id)),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'category', i.category, 'brand', i.brand,
        'description', i.shop_description, 'price', i.price, 'unit', i.selling_unit, 'photo_path', i.photo_path,
        'available', coalesce(st.qty, 0) > 0,
        'stock', case when o.shop_show_stock then greatest(floor(coalesce(st.qty, 0)), 0) end) order by i.category nulls last, i.name), '[]'::jsonb)
      from items i
      left join (select item_id, sum(qty) qty from stock_levels where org_id = o.id and (o.shop_location_id is null or location_id = o.shop_location_id) group by item_id) st
        on st.item_id = i.id
      where i.org_id = o.id and not i.archived and i.price > 0 and i.item_type in ('merchandise', 'finished_good')
        and (o.shop_categories is null or i.category = any(o.shop_categories))));
end $$;

-- ---------------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------------
-- core.sql grants every private function to authenticated: the helpers this migration creates or redefines are not callable
-- by the signed-in person (the trigger functions still fire for them). The public functions keep their grants (create or
-- replace, same signatures).
revoke all on function private.firm_addresses(uuid), private.outbound_check(uuid, text, text, text), private.messages_outbound(),
  private.voice_calls_mandate(), private.require_outbound(uuid, text, text), private.alert_prefs(uuid),
  private.queue_message(uuid, text, text, text, text, jsonb, uuid, uuid, uuid), private.white_label(uuid, uuid), private.org_brand(uuid, uuid),
  private.sale_json(uuid, boolean)
  from public, anon, authenticated;
