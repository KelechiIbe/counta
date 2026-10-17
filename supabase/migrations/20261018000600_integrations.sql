-- Counta · Integrations: VAT treatment of items set by AI (Numens, Gemini for now), email (Resend) and WhatsApp messages,
-- payment reminders, sign-in from TaxStreem (single sign-on), and the log of what the agents did.

insert into private.config (key, value) values ('app_url', 'https://counta-taxstreem.netlify.app') on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 1. VAT treatment of items, by AI with a confidence gate
-- ---------------------------------------------------------------------------
-- vat_basis: {source: 'numens'|'gemini'|'manual'|'import', treatment, reason, law (e.g. 'NTA 2025 s.187(a)'), confidence, model, at}
alter table public.items add column if not exists vat_basis jsonb;
alter table public.items add column if not exists vat_confidence numeric(4,3);
alter table public.items add column if not exists vat_checked_at timestamptz;
alter table public.items add column if not exists vat_review boolean not null default false;
create index if not exists items_vat_unchecked on public.items(created_at) where vat_checked_at is null and not archived;

-- Items the tax agent should classify: new ones first, a few hundred at a time across all businesses.
create or replace function public.svc_items_for_vat(p_limit int default 60) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'org_id', i.org_id, 'name', i.name, 'category', i.category, 'brand', i.brand,
      'description', i.description, 'item_type', i.item_type, 'unit', i.selling_unit, 'current', i.vat_treatment, 'industry', o.industry)), '[]'::jsonb)
  from (select * from items where vat_checked_at is null and not archived and coalesce(vat_basis->>'source', '') <> 'manual'
        order by created_at desc limit greatest(p_limit, 1)) i join orgs o on o.id = i.org_id
$$;

-- p: {treatment: 'standard'|'zero'|'exempt', confidence, reason, law, source: 'numens'|'gemini', model}
create or replace function public.svc_set_item_vat(p_item uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare it public.items; v_conf numeric := least(greatest(coalesce(private.num(p->>'confidence'), 0), 0), 1); v_t text := p->>'treatment'; v_threshold numeric;
begin
  select * into it from items where id = p_item for update;
  if not found then return jsonb_build_object('ok', false); end if;
  if coalesce(it.vat_basis->>'source', '') = 'manual' then
    update items set vat_checked_at = now() where id = it.id;
    return jsonb_build_object('ok', true, 'kept', 'manual');
  end if;
  if v_t not in ('standard', 'zero', 'exempt') then
    update items set vat_checked_at = now(), vat_review = true where id = it.id;
    return jsonb_build_object('ok', false, 'reason', 'no_answer');
  end if;
  select greatest(coalesce(auto_post_threshold, 0.8), 0.8) into v_threshold from orgs where id = it.org_id;
  update items set vat_basis = jsonb_build_object('source', coalesce(nullif(p->>'source', ''), 'gemini'), 'treatment', v_t, 'reason', left(p->>'reason', 400),
      'law', left(p->>'law', 120), 'confidence', v_conf, 'model', p->>'model', 'at', now()),
    vat_confidence = v_conf, vat_checked_at = now(),
    vat_treatment = case when v_conf >= v_threshold then v_t else vat_treatment end,
    vat_review = v_conf < v_threshold
  where id = it.id;
  if v_conf < v_threshold then
    update ai_proposals set status = 'superseded' where org_id = it.org_id and kind = 'item_vat' and source_id = it.id and status = 'pending';
    insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, model)
    values (it.org_id, 'tax', 'item_vat', 'item', it.id, 'VAT on ' || it.name || ': ' || case v_t when 'zero' then 'zero-rated' when 'exempt' then 'exempt' else 'standard 7.5%' end,
      'Is ' || it.name || ' ' || case v_t when 'zero' then 'zero-rated' when 'exempt' then 'exempt from VAT' else 'charged VAT at 7.5%' end || '?',
      jsonb_build_object('treatment', v_t, 'law', p->>'law', 'current', it.vat_treatment), v_conf, p->>'reason', 'vat', 'pending', p->>'model');
  else
    update ai_proposals set status = 'superseded' where org_id = it.org_id and kind = 'item_vat' and source_id = it.id and status = 'pending';
  end if;
  return jsonb_build_object('ok', true, 'applied', v_conf >= v_threshold);
end $$;

-- A person sets or confirms an item's VAT treatment. That decision is final for the agent.
create or replace function public.set_item_vat(p_item uuid, p_treatment text, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare it public.items; m public.members;
begin
  select * into it from items where id = p_item for update;
  if not found then raise exception 'Item not found.'; end if;
  m := private.require(it.org_id, null);
  if not (private.perm_of(m, 'edit_prices') or private.perm_of(m, 'keep_books')) then raise exception 'Only someone who edits prices or keeps the books sets VAT.' using errcode = '42501'; end if;
  if p_treatment not in ('standard', 'zero', 'exempt') then raise exception 'Choose standard, zero-rated or exempt.'; end if;
  update items set vat_treatment = p_treatment, vat_review = false, vat_checked_at = now(),
    vat_basis = jsonb_build_object('source', 'manual', 'treatment', p_treatment, 'reason', nullif(trim(p_reason), ''), 'by', m.display_name, 'at', now(),
      'ai', case when it.vat_basis->>'source' <> 'manual' then it.vat_basis end)
  where id = it.id;
  update ai_proposals set status = case when proposal->>'treatment' = p_treatment then 'approved' else 'rejected' end, decided_by = m.id, decided_at = now(),
    decision = jsonb_build_object('treatment', p_treatment)
  where org_id = it.org_id and kind = 'item_vat' and source_id = it.id and status = 'pending';
  return jsonb_build_object('id', it.id, 'vat_treatment', p_treatment);
end $$;

-- Ask the tax agent to look again (after a rename, or when the person is unsure).
create or replace function public.recheck_item_vat(p_item uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare it public.items;
begin
  select * into it from items where id = p_item;
  if not found then raise exception 'Item not found.'; end if;
  perform private.require(it.org_id, 'edit_prices');
  update items set vat_checked_at = null, vat_basis = case when vat_basis->>'source' = 'manual' then null else vat_basis end where id = it.id;
  perform private.call_function('ai', jsonb_build_object('action', 'vat_classify_pending'));
end $$;

-- A renamed item is checked again unless a person set its VAT.
create or replace function private.on_item_renamed() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if (new.name is distinct from old.name or new.category is distinct from old.category) and coalesce(new.vat_basis->>'source', '') <> 'manual' then
    new.vat_checked_at := null;
  end if;
  return new;
end $$;
drop trigger if exists items_vat_recheck on public.items;
create trigger items_vat_recheck before update of name, category on public.items for each row execute function private.on_item_renamed();

create or replace function private.vat_tick() returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if exists (select 1 from items where vat_checked_at is null and not archived and coalesce(vat_basis->>'source', '') <> 'manual') then
    perform private.call_function('ai', jsonb_build_object('action', 'vat_classify_pending'));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Messages: email through Resend, WhatsApp through the WhatsApp Business Cloud API
-- ---------------------------------------------------------------------------
alter table public.orgs add column if not exists reminders_enabled boolean not null default false;
alter table public.orgs add column if not exists reminder_days int[] not null default '{-3,0,3,7,14}';
alter table public.orgs add column if not exists reply_to_email text;

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  channel text not null check (channel in ('email', 'whatsapp')),
  to_address text not null,
  template text not null check (template in ('document', 'reminder', 'receipt', 'statement', 'order', 'custom')),
  subject text,
  params jsonb not null default '{}'::jsonb,
  sale_id uuid references public.sales(id) on delete set null,
  customer_id uuid references public.customers(id) on delete set null,
  status text not null default 'queued' check (status in ('queued', 'sending', 'sent', 'delivered', 'read', 'failed')),
  provider_id text,
  error text,
  attempts int not null default 0,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  updated_at timestamptz not null default now()
);
create index if not exists messages_org on public.messages(org_id, created_at desc);
create index if not exists messages_sale on public.messages(sale_id);
create index if not exists messages_customer_fk on public.messages(customer_id);
create index if not exists messages_created_by_fk on public.messages(created_by);
create index if not exists messages_queued on public.messages(status, created_at) where status in ('queued', 'sending');
create unique index if not exists messages_provider on public.messages(channel, provider_id) where provider_id is not null;
alter table public.messages enable row level security;
drop policy if exists messages_read on public.messages;
create policy messages_read on public.messages for select to authenticated using ((select private.is_member(org_id)));

create or replace function private.doc_link(p_token text) returns text
language sql stable security definer set search_path = public, private as $$
  select coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app') || '/p/' || p_token
$$;

create or replace function private.queue_message(p_org uuid, p_channel text, p_to text, p_template text, p_subject text, p_params jsonb, p_sale uuid,
  p_customer uuid, p_by uuid) returns public.messages
language plpgsql security definer set search_path = public, private as $$
declare msg public.messages; v_to text;
begin
  if p_channel = 'whatsapp' then
    v_to := private.clean_phone(p_to);
    if v_to is null or length(v_to) < 11 then raise exception 'Add a WhatsApp number for the customer.'; end if;
  elsif p_channel = 'email' then
    v_to := lower(trim(p_to));
    if v_to is null or v_to !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Add an email address for the customer.'; end if;
  else
    raise exception 'Send by email or WhatsApp.';
  end if;
  if (select count(*) from messages where org_id = p_org and created_at > now() - interval '1 hour') >= 500 then
    raise exception 'Too many messages this hour. Try again later.';
  end if;
  insert into messages (org_id, channel, to_address, template, subject, params, sale_id, customer_id, created_by)
  values (p_org, p_channel, v_to, p_template, p_subject, p_params, p_sale, p_customer, p_by) returning * into msg;
  perform private.call_function('messaging', jsonb_build_object('message_id', msg.id));
  return msg;
end $$;

-- Send a receipt, invoice, quote, order confirmation or credit note to the customer.
create or replace function public.send_document(p_sale uuid, p_channel text, p_to text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members; msg public.messages; o public.orgs; v_label text;
begin
  select * into s from sales where id = p_sale;
  if not found then raise exception 'Sale not found.'; end if;
  m := private.require(s.org_id, 'record_sales');
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

-- Remind a customer of what they owe, with a link to pay.
create or replace function public.send_reminder(p_sale uuid, p_channel text default 'whatsapp') returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members; msg public.messages; o public.orgs;
begin
  select * into s from sales where id = p_sale;
  if not found then raise exception 'Sale not found.'; end if;
  m := private.require(s.org_id, 'record_sales');
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

-- Overnight: reminders on the days the business chose (before, on and after the due date), once a day per invoice.
create or replace function private.queue_reminders() returns int
language plpgsql security definer set search_path = public, private as $$
declare s record; n int := 0;
begin
  for s in
    select sa.*, o.name org_name, o.reply_to_email, o.email org_email, o.phone org_phone, cu.whatsapp_opt_in, cu.phone cphone, cu.email cemail
    from sales sa join orgs o on o.id = sa.org_id join customers cu on cu.id = sa.customer_id
    where o.reminders_enabled and sa.status in ('open', 'partially_paid') and sa.doc_type in ('invoice', 'receipt') and not cu.is_walk_in
      and sa.due_date is not null and (sa.due_date - private.local_day(sa.org_id, now())) * -1 = any(o.reminder_days)
      and (sa.reminded_at is null or private.local_day(sa.org_id, sa.reminded_at) < private.local_day(sa.org_id, now()))
      and (cu.phone is not null and cu.whatsapp_opt_in or cu.email is not null)
    limit 2000
  loop
    begin
      perform private.queue_message(s.org_id, case when s.cphone is not null and s.whatsapp_opt_in then 'whatsapp' else 'email' end,
        case when s.cphone is not null and s.whatsapp_opt_in then s.cphone else s.cemail end, 'reminder', 'Payment reminder: ' || s.number || ' from ' || s.org_name,
        jsonb_build_object('customer_name', s.customer_name, 'business', s.org_name, 'number', s.number, 'balance', s.total - s.amount_paid - s.credited,
          'due_date', s.due_date, 'link', private.doc_link(s.public_token), 'reply_to', coalesce(s.reply_to_email, s.org_email), 'business_phone', s.org_phone,
          'automatic', true), s.id, s.customer_id, null);
      update sales set reminded_at = now() where id = s.id;
      n := n + 1;
    exception when others then
      null;  -- one bad address does not stop the rest
    end;
  end loop;
  return n;
end $$;

create or replace function public.update_message_settings(p_org uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; v_days int[];
begin
  m := private.require(p_org, null);
  if m.role <> 'owner' then raise exception 'Only the owner changes message settings.' using errcode = '42501'; end if;
  if jsonb_typeof(p_patch->'reminder_days') = 'array' then
    select array_agg(distinct d::int order by d::int) into v_days from jsonb_array_elements_text(p_patch->'reminder_days') d where d ~ '^-?[0-9]{1,3}$' and d::int between -30 and 120;
  end if;
  if coalesce(p_patch->>'reply_to_email', '') <> '' and p_patch->>'reply_to_email' !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address.'; end if;
  update orgs set reminders_enabled = coalesce((p_patch->>'reminders_enabled')::boolean, reminders_enabled), reminder_days = coalesce(v_days, reminder_days),
    reply_to_email = case when p_patch ? 'reply_to_email' then nullif(lower(trim(p_patch->>'reply_to_email')), '') else reply_to_email end
  where id = p_org returning * into o;
  return jsonb_build_object('reminders_enabled', o.reminders_enabled, 'reminder_days', o.reminder_days, 'reply_to_email', o.reply_to_email);
end $$;

create or replace function public.get_messages(p_org uuid, p_sale uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require(p_org, null);
  return jsonb_build_object('messages', (select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb)
      from (select * from messages where org_id = p_org and (p_sale is null or sale_id = p_sale) order by created_at desc limit 300) x),
    'settings', (select jsonb_build_object('reminders_enabled', reminders_enabled, 'reminder_days', reminder_days, 'reply_to_email', reply_to_email) from orgs where id = p_org));
end $$;

create or replace function public.svc_message(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare msg public.messages;
begin
  update messages set status = 'sending', attempts = attempts + 1, updated_at = now() where id = p_id and status in ('queued', 'failed') and attempts < 5
  returning * into msg;
  if not found then return null; end if;
  return to_jsonb(msg) || jsonb_build_object('org', (select jsonb_build_object('name', name, 'email', email, 'phone', phone, 'logo_path', logo_path) from orgs where id = msg.org_id));
end $$;

create or replace function public.svc_message_update(p_id uuid, p_status text, p_provider_id text default null, p_error text default null) returns void
language sql security definer set search_path = public, private as $$
  -- Back to 'queued' means the channel has no keys yet: that try does not count, so it goes out once the keys are added.
  update public.messages set status = p_status, provider_id = coalesce(p_provider_id, provider_id), error = left(p_error, 1000), updated_at = now(),
    sent_at = case when p_status = 'sent' then now() else sent_at end,
    attempts = case when p_status = 'queued' then greatest(attempts - 1, 0) else attempts end
  where id = p_id and p_status in ('sent', 'failed', 'queued');
$$;

-- WhatsApp delivery and read receipts.
create or replace function public.svc_message_status(p_provider_id text, p_status text, p_error text default null) returns void
language sql security definer set search_path = public, private as $$
  update public.messages set status = case when p_status in ('delivered', 'read', 'failed', 'sent') then p_status else status end,
    error = coalesce(left(p_error, 1000), error), updated_at = now()
  where channel = 'whatsapp' and provider_id = p_provider_id
    and not (status = 'read' and p_status in ('sent', 'delivered')) and not (status = 'delivered' and p_status = 'sent');
$$;

create or replace function public.svc_messages_retry() returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(id), '[]'::jsonb) from (select id from messages
    where (status = 'queued' and created_at < now() - interval '2 minutes' and created_at > now() - interval '3 days') or (status = 'failed' and attempts < 3 and updated_at < now() - interval '10 minutes')
       or (status = 'sending' and updated_at < now() - interval '10 minutes' and attempts < 5)
    order by created_at limit 100) x
$$;

-- ---------------------------------------------------------------------------
-- 3. Signing in from TaxStreem
-- ---------------------------------------------------------------------------
alter table public.orgs add column if not exists taxstreem_org_id text;
create unique index if not exists orgs_taxstreem on public.orgs(taxstreem_org_id) where taxstreem_org_id is not null;

create table if not exists public.sso_logins (
  jti text primary key,
  taxstreem_user_id text not null,
  email text not null,
  org_id uuid references public.orgs(id) on delete set null,
  user_id uuid,
  at timestamptz not null default now()
);
create index if not exists sso_logins_org on public.sso_logins(org_id);
alter table public.sso_logins enable row level security;

-- Accountant joins the roles that can be invited.
create or replace function public.invite_member(p_org uuid, p_name text, p_email text, p_role text, p_title text default null,
  p_location uuid default null, p_phone text default null) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare m public.members; p jsonb; v_id uuid; v_email text := nullif(lower(trim(coalesce(p_email, ''))), ''); v_uid uuid;
begin
  m := private.require(p_org, 'owner');
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter the person''s name.'; end if;
  if p_role not in ('manager', 'staff', 'cashier', 'accountant') then raise exception 'Choose a role.'; end if;
  if v_email is not null and exists (select 1 from members where org_id = p_org and lower(email) = v_email) then
    raise exception '% is already on your team.', v_email;
  end if;
  if p_location is not null and not exists (select 1 from locations where id = p_location and org_id = p_org) then raise exception 'Unknown branch.'; end if;
  if v_email is not null then select id into v_uid from auth.users where lower(email) = v_email; end if;
  p := private.role_template(p_role);
  insert into members (org_id, user_id, email, display_name, phone, role, title, location_id, status,
    p_record_sales, p_receive_stock, p_count_stock, p_approve_adjustments, p_edit_prices, p_approve_pos, p_transfer_stock, p_see_margins,
    p_issue_stock, p_keep_books, p_make_payments)
  values (p_org, v_uid, v_email, trim(p_name), nullif(trim(p_phone), ''), p_role, coalesce(nullif(trim(p_title), ''), initcap(p_role)), p_location,
    case when v_uid is not null or v_email is null then 'active' else 'invited' end,
    (p->>'record_sales')::boolean, (p->>'receive_stock')::boolean, (p->>'count_stock')::boolean, (p->>'approve_adjustments')::boolean,
    (p->>'edit_prices')::boolean, (p->>'approve_pos')::boolean, (p->>'transfer_stock')::boolean, (p->>'see_margins')::boolean,
    (p->>'issue_stock')::boolean, (p->>'keep_books')::boolean, (p->>'make_payments')::boolean)
  returning id into v_id;
  return v_id;
end $$;

-- The taxstreem edge function verified the signed token; this records it once and makes sure the business and the person exist.
-- c: {jti, sub (TaxStreem user id), email, name, phone, org:{id, name, email, phone, tin, rc_number, vat_registered}, role, rail, exp}
create or replace function public.svc_sso_login(c jsonb, p_user uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_org uuid; v_email text := lower(trim(c->>'email')); v_role text; mm public.members; p jsonb; v_new boolean := false;
begin
  if coalesce(c->>'jti', '') = '' or v_email is null or coalesce(c->'org'->>'id', '') = '' then raise exception 'The sign-in token is incomplete.'; end if;
  insert into sso_logins (jti, taxstreem_user_id, email, user_id) values (c->>'jti', coalesce(c->>'sub', v_email), v_email, p_user)
  on conflict (jti) do nothing;
  if not found then raise exception 'This sign-in link was already used.'; end if;
  v_role := case lower(coalesce(c->>'role', 'owner')) when 'owner' then 'owner' when 'admin' then 'manager' when 'manager' then 'manager'
    when 'accountant' then 'accountant' when 'cashier' then 'cashier' else 'staff' end;
  select id into v_org from orgs where taxstreem_org_id = c->'org'->>'id';
  if v_org is null then
    -- First visit from this TaxStreem business: create it, owned by the person signing in.
    perform set_config('request.jwt.claim.sub', p_user::text, true);
    v_org := public.create_org(coalesce(nullif(trim(c->'org'->>'name'), ''), 'My business'), coalesce(nullif(c->'org'->>'email', ''), v_email),
      nullif(c->'org'->>'phone', ''), coalesce(nullif(trim(c->>'name'), ''), split_part(v_email, '@', 1)), '[]'::jsonb,
      coalesce((c->'org'->>'vat_registered')::boolean, true), false);
    update orgs set taxstreem_org_id = c->'org'->>'id', tin = coalesce(nullif(c->'org'->>'tin', ''), tin), rc_number = coalesce(nullif(c->'org'->>'rc_number', ''), rc_number)
    where id = v_org;
    v_new := true;
  end if;
  if nullif(c->>'rail', '') is not null and exists (select 1 from payment_rails where code = c->>'rail' and active) then
    update orgs set payment_rail = c->>'rail' where id = v_org and payment_rail <> c->>'rail'
      and not exists (select 1 from wallets w where w.org_id = v_org and w.status = 'active');
  end if;
  select * into mm from members where org_id = v_org and (user_id = p_user or (user_id is null and lower(email) = v_email)) order by user_id nulls last limit 1;
  if mm.id is null then
    p := private.role_template(v_role);
    insert into members (org_id, user_id, email, display_name, phone, role, title, status, p_record_sales, p_receive_stock, p_count_stock, p_approve_adjustments,
      p_edit_prices, p_approve_pos, p_transfer_stock, p_see_margins, p_issue_stock, p_keep_books, p_make_payments)
    values (v_org, p_user, v_email, coalesce(nullif(trim(c->>'name'), ''), split_part(v_email, '@', 1)), nullif(c->>'phone', ''), v_role, initcap(v_role), 'active',
      (p->>'record_sales')::boolean, (p->>'receive_stock')::boolean, (p->>'count_stock')::boolean, (p->>'approve_adjustments')::boolean,
      (p->>'edit_prices')::boolean, (p->>'approve_pos')::boolean, (p->>'transfer_stock')::boolean, (p->>'see_margins')::boolean,
      (p->>'issue_stock')::boolean, (p->>'keep_books')::boolean, (p->>'make_payments')::boolean);
  elsif mm.user_id is null then
    update members set user_id = p_user, status = 'active' where id = mm.id;
  elsif mm.status = 'disabled' then
    raise exception 'Your access to this business has been switched off. Ask the owner.';
  end if;
  update sso_logins set org_id = v_org where jti = c->>'jti';
  return jsonb_build_object('org_id', v_org, 'new_business', v_new);
end $$;

-- ---------------------------------------------------------------------------
-- 4. What the agents did, for the activity log and for limits
-- ---------------------------------------------------------------------------
create table if not exists public.agent_runs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid references public.orgs(id) on delete cascade,
  agent text not null,
  action text not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  items int not null default 0,
  posted int not null default 0,
  asked int not null default 0,
  model text,
  error text
);
create index if not exists agent_runs_org on public.agent_runs(org_id, started_at desc);
alter table public.agent_runs enable row level security;
drop policy if exists agent_runs_read on public.agent_runs;
create policy agent_runs_read on public.agent_runs for select to authenticated using ((select private.can_handle_money(org_id)));

create or replace function public.svc_agent_run(p_org uuid, p_agent text, p_action text, p jsonb) returns uuid
language sql security definer set search_path = public, private as $$
  insert into public.agent_runs (org_id, agent, action, finished_at, items, posted, asked, model, error)
  values (p_org, p_agent, p_action, now(), coalesce((p->>'items')::int, 0), coalesce((p->>'posted')::int, 0), coalesce((p->>'asked')::int, 0), p->>'model', left(p->>'error', 1000))
  returning id
$$;

-- Businesses with bank lines waiting for the bookkeeper agent.
create or replace function public.svc_orgs_with_lines() returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(distinct org_id), '[]'::jsonb) from bank_lines where status = 'unmatched' and ai_attempts < 3
$$;

create or replace function private.agents_tick() returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if exists (select 1 from bank_lines where status = 'unmatched' and ai_attempts < 3) then
    perform private.call_function('atlas', jsonb_build_object('action', 'classify_all'));
  end if;
  perform private.vat_tick();
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname in ('counta-agents', 'counta-reminders', 'counta-messages-retry');
    perform cron.schedule('counta-agents', '*/3 * * * *', 'select private.agents_tick()');
    perform cron.schedule('counta-reminders', '50 7 * * *', 'select private.queue_reminders()');
    perform cron.schedule('counta-messages-retry', '*/10 * * * *',
      $c$select private.call_function('messaging', jsonb_build_object('action', 'retry')) where exists (select 1 from public.messages where status in ('queued', 'failed', 'sending') and created_at > now() - interval '1 day')$c$);
  end if;
end $$;

grant execute on function public.set_item_vat(uuid, text, text), public.recheck_item_vat(uuid), public.send_document(uuid, text, text),
  public.send_reminder(uuid, text), public.send_statement(uuid, text), public.update_message_settings(uuid, jsonb), public.get_messages(uuid, uuid),
  public.invite_member(uuid, text, text, text, text, uuid, text) to authenticated;
revoke execute on function public.set_item_vat(uuid, text, text), public.recheck_item_vat(uuid), public.send_document(uuid, text, text),
  public.send_reminder(uuid, text), public.send_statement(uuid, text), public.update_message_settings(uuid, jsonb), public.get_messages(uuid, uuid),
  public.invite_member(uuid, text, text, text, text, uuid, text) from public, anon;
revoke execute on function public.svc_items_for_vat(int), public.svc_set_item_vat(uuid, jsonb), public.svc_message(uuid), public.svc_message_update(uuid, text, text, text),
  public.svc_message_status(text, text, text), public.svc_messages_retry(), public.svc_sso_login(jsonb, uuid), public.svc_agent_run(uuid, text, text, jsonb),
  public.svc_orgs_with_lines() from public, anon, authenticated;
grant execute on function public.svc_items_for_vat(int), public.svc_set_item_vat(uuid, jsonb), public.svc_message(uuid), public.svc_message_update(uuid, text, text, text),
  public.svc_message_status(text, text, text), public.svc_messages_retry(), public.svc_sso_login(jsonb, uuid), public.svc_agent_run(uuid, text, text, jsonb),
  public.svc_orgs_with_lines() to service_role;
revoke execute on function private.on_item_renamed(), private.vat_tick(), private.doc_link(text), private.queue_message(uuid, text, text, text, text, jsonb, uuid, uuid, uuid),
  private.queue_reminders(), private.agents_tick() from public, anon, authenticated;
