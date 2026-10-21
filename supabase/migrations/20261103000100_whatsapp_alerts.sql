-- Alerts on WhatsApp, to the numbers people linked to Martina (docs/messaging.md, "Alerts on WhatsApp").
--
-- Until now an owner alert looked for a phone number on the owner's entry in the team list, which nobody fills in, and
-- the sample business stopped before email and WhatsApp. Everything else that asks for action reached the bell and the
-- phone's push only. From here:
--   * WhatsApp alerts go to everyone whose role covers the work and who linked their WhatsApp to Martina (Settings,
--     Martina on WhatsApp). That number is the person's own, confirmed with a code. Nobody else is messaged.
--   * The morning alerts (tax returns due, invoices due, transactions to confirm, tax payments) keep their days: the
--     same days as the email.
--   * Push notifications that ask for action also go to WhatsApp: bills and receipts to review, payments and payouts to
--     approve or confirm, failed payouts, a bank to sign in to again, new orders, price checks, stock counts, a tool
--     that stopped working, a plan payment that failed, a question from the accountant. Money in and payments received
--     stay on the bell.
--   * Between 8:00 and 20:00 where the business is; one raised at night waits for 8:00. At most ten a day to one number.
--   * The sample business sends them too, to its own people only. Its customers still hear nothing from alerts.
--   * They come from TaxStreem's number, where Martina answers; a reply goes to her.
--   * Counta's own alerts do not count against the business's monthly email and WhatsApp allowance.

-- ---------------------------------------------------------------------------
-- 1. Messages that wait for a time
-- ---------------------------------------------------------------------------
alter table public.messages add column if not exists send_after timestamptz;
create index if not exists messages_send_after on public.messages(send_after) where status = 'queued' and send_after is not null;
-- The day's count of alerts to one number.
create index if not exists messages_alert_to on public.messages(to_address, created_at) where template = 'alert' and channel = 'whatsapp';

-- Messages still to go: those queued a while ago, those whose time has come, failed ones worth another try, and ones a
-- send left hanging.
create or replace function public.svc_messages_retry() returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(id), '[]'::jsonb) from (select id from messages
    where (status = 'queued' and send_after is null and created_at < now() - interval '2 minutes' and created_at > now() - interval '3 days')
       or (status = 'queued' and send_after is not null and send_after <= now() and send_after > now() - interval '3 days')
       or (status = 'failed' and attempts < 3 and updated_at < now() - interval '10 minutes')
       or (status = 'sending' and updated_at < now() - interval '10 minutes' and attempts < 5)
    order by coalesce(send_after, created_at) limit 100) x
$$;

-- One message for the server function to send. Not before its time; an alert whose WhatsApp number was unlinked since it
-- was queued does not go.
create or replace function public.svc_message(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare msg public.messages;
begin
  select * into msg from messages where id = p_id;
  if found and msg.template = 'alert' and msg.channel = 'whatsapp' and msg.status in ('queued', 'failed') and msg.params ? 'link_id'
     and not exists (select 1 from chat_links l where l.id = (msg.params->>'link_id')::uuid and l.status = 'active' and l.channel = 'whatsapp') then
    update messages set status = 'failed', error = 'The WhatsApp number was unlinked before this alert went.', updated_at = now() where id = p_id;
    return null;
  end if;
  update messages set status = 'sending', attempts = attempts + 1, updated_at = now()
  where id = p_id and status in ('queued', 'failed') and attempts < 5 and (send_after is null or send_after <= now())
  returning * into msg;
  if not found then return null; end if;
  return to_jsonb(msg) || jsonb_build_object('org', private.org_brand(msg.org_id));
end $$;

-- ---------------------------------------------------------------------------
-- 2. Counta's own alerts are not the business's messages
-- ---------------------------------------------------------------------------
create or replace function private.meter_usage(p_org uuid, p_meter text) returns numeric
language plpgsql stable security definer set search_path = public, private as $$
declare v_from timestamptz := private.month_start(); v numeric;
begin
  case p_meter
    when 'sales' then
      select count(*) into v from sales where org_id = p_org and created_at >= v_from and doc_type in ('receipt', 'invoice') and status not in ('draft', 'void', 'cancelled');
    when 'ai_reads' then
      select count(*) into v from usage_events where org_id = p_org and service = 'gemini' and kind = any(private.ai_read_kinds()) and at >= v_from;
    when 'assistant' then
      select count(*) into v from usage_events where org_id = p_org and service = 'gemini' and kind = any(private.ai_assistant_kinds()) and at >= v_from;
    when 'call_minutes' then
      select coalesce(sum(ceil(coalesce(duration_secs, 0) / 60.0)), 0) into v from voice_calls where org_id = p_org and created_at >= v_from;
    when 'whatsapp' then
      select count(*) into v from messages where org_id = p_org and channel = 'whatsapp' and template <> 'alert' and status <> 'failed' and created_at >= v_from;
    when 'emails' then
      select count(*) into v from messages where org_id = p_org and channel = 'email' and template <> 'alert' and status <> 'failed' and created_at >= v_from;
    when 'tin_checks' then
      select count(*) into v from tin_checks where org_id = p_org and at >= v_from;
    when 'supplier_invoices' then
      select count(*) into v from supplier_invoices where org_id = p_org and created_at >= v_from;
    when 'payouts' then
      select count(*) into v from payouts where org_id = p_org and created_at >= v_from and status <> 'cancelled';
    when 'users' then
      select count(*) into v from members where org_id = p_org and status in ('active', 'invited');
    when 'locations' then
      select count(*) into v from locations where org_id = p_org;
    when 'bank_feeds' then
      select count(*) into v from bank_accounts where org_id = p_org and provider = 'mono' and active;
    else v := 0;
  end case;
  return coalesce(v, 0);
end $$;

create or replace function private.enforce_plan() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if tg_table_name = 'sales' then
    if new.doc_type in ('receipt', 'invoice') and new.status not in ('draft', 'void', 'cancelled') then perform private.check_quota(new.org_id, 'sales'); end if;
  elsif tg_table_name = 'members' then
    if new.role <> 'owner' and new.status in ('active', 'invited') then perform private.check_quota(new.org_id, 'users'); end if;
  elsif tg_table_name = 'locations' then
    perform private.check_quota(new.org_id, 'locations');
  elsif tg_table_name = 'payouts' then
    if new.batch_id is not null and not private.feature_on(new.org_id, 'bulk_payments') then
      raise exception 'Bulk payments are not in your plan. The owner can change the plan in Settings, Subscription.';
    end if;
    perform private.check_quota(new.org_id, 'payouts');
  elsif tg_table_name = 'supplier_invoices' then
    if new.source = 'portal' and not private.feature_on(new.org_id, 'supplier_portal') then
      raise exception 'This business is not taking invoices on its portal right now.';
    end if;
    perform private.check_quota(new.org_id, 'supplier_invoices');
  elsif tg_table_name = 'tin_checks' then
    perform private.check_quota(new.org_id, 'tin_checks');
  elsif tg_table_name = 'bank_accounts' then
    if new.provider = 'mono' and (tg_op = 'INSERT' or old.provider is distinct from 'mono') then
      if not private.feature_on(new.org_id, 'bank_feeds') then
        raise exception 'Bank feeds are not in your plan. The owner can change the plan in Settings, Subscription.';
      end if;
      perform private.check_quota(new.org_id, 'bank_feeds');
    end if;
  elsif tg_table_name = 'voice_calls' then
    perform private.check_quota(new.org_id, 'call_minutes');
  elsif tg_table_name = 'messages' then
    -- A message over a blocking limit is kept, marked failed with the reason, so whatever queued it carries on. Counta's
    -- own alerts to the team are not counted.
    if new.template is distinct from 'alert' then
      begin
        perform private.check_quota(new.org_id, case when new.channel = 'whatsapp' then 'whatsapp' else 'emails' end);
      exception when sqlstate 'P0001' then
        new.status := 'failed'; new.error := left(sqlerrm, 300);
      end;
    end if;
  end if;
  return new;
end $$;

-- The business's message log (Settings, Customer messages) is for its customers and suppliers. Alerts to its own people,
-- with their WhatsApp numbers, stay out of it.
create or replace function public.get_messages(p_org uuid, p_sale uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require(p_org, null);
  return jsonb_build_object('messages', (select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb)
      from (select * from messages where org_id = p_org and (p_sale is null or sale_id = p_sale) and template <> 'alert' order by created_at desc limit 300) x),
    'settings', (select jsonb_build_object('reminders_enabled', reminders_enabled, 'reminder_days', reminder_days, 'reply_to_email', reply_to_email) from orgs where id = p_org));
end $$;

-- ---------------------------------------------------------------------------
-- 3. One WhatsApp alert to one person
-- ---------------------------------------------------------------------------
-- The WhatsApp number a person linked to Martina: the link in this business first, then the newest.
create or replace function private.wa_number(p_user uuid, p_org uuid) returns table (link_id uuid, phone text, same_org boolean)
language sql stable security definer set search_path = public, private as $$
  select l.id, l.phone, l.org_id = p_org from chat_links l
  where l.user_id = p_user and l.channel = 'whatsapp' and l.status = 'active' and l.phone is not null
  order by (l.org_id = p_org) desc, l.linked_at desc nulls last, l.created_at desc
  limit 1
$$;

-- Whether a push notification asks for action, so it goes to WhatsApp as well. The morning alerts (tax deadlines,
-- invoices due, items to confirm, tax payments) choose their own days in alert_send and are not here.
create or replace function private.wa_worthy(p_kind text, p_title text) returns boolean
language sql immutable set search_path = '' as $$
  select case p_kind
    when 'bill' then true                -- a supplier's invoice to review, or one Counta could not read
    when 'banking' then true             -- sign in to the bank again
    when 'price_proposal' then true
    when 'receipt_ready' then true       -- a delivery or receipt to confirm
    when 'count_submitted' then true     -- a stock count to approve
    when 'count_rejected' then true      -- a stock count to do again
    when 'spot_check' then true
    when 'order' then true
    when 'transfer_sent' then true       -- stock on its way, to receive
    when 'bank' then t not like 'Money into the wallet%'                -- which invoice or bill a bank line pays
    when 'payment' then t like 'Confirm %'
    when 'payout' then t like 'Approve %' or t like '% failed'
    when 'identity' then t like 'We could not confirm%'
    when 'books' then t like '% stopped working'
    when 'tax' then t like 'Turnover has passed%' or t like 'Rev360 has not seen%' or t like '% was sent back by Flux'
    when 'plan' then t in ('Counta plan payment failed', 'Choose how to pay for Counta', 'Your accountant will stop paying for Counta')
                     or t like '%past your plan''s limit'
    when 'practice' then t like 'Your accountant asks:%'
    else false end
  from (select coalesce(p_title, '') t) x
$$;

-- One WhatsApp alert to one person, at the number they linked to Martina. Once for its key; between 8:00 and 20:00 where
-- the business is (one raised at night waits for 8:00); at most ten a day to one number. Returns whether it was queued.
-- p: {title, lines[], body, url, button, subject, wa_name, wa_params[]}
create or replace function private.wa_alert(p_org uuid, p_user uuid, p_kind text, p_key text, p jsonb) returns boolean
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; m public.members; w record; v_to text; v_tz text; v_local timestamp; v_after timestamptz; v_day date; msg public.messages;
begin
  if p_org is null or p_user is null or p_key is null then return false; end if;
  select * into o from orgs where id = p_org;
  if not found then return false; end if;
  -- The business's own switch (Settings, Alerts) and TaxStreem's.
  if not coalesce((o.alert_prefs->>'whatsapp')::boolean, true) or not private.feature_on(p_org, 'whatsapp') then return false; end if;
  select * into m from members where org_id = p_org and user_id = p_user and status = 'active' order by created_at limit 1;
  if not found then return false; end if;
  select * into w from private.wa_number(p_user, p_org);
  if w.phone is null then return false; end if;
  v_to := private.clean_phone(w.phone);
  -- Now, or 8:00 when it is night where the business is.
  v_tz := coalesce(o.timezone, 'Africa/Lagos');
  v_local := now() at time zone v_tz;
  if extract(hour from v_local) < 8 then v_after := private.local_hour_at(p_org, v_local::date, 8);
  elsif extract(hour from v_local) >= 20 then v_after := private.local_hour_at(p_org, v_local::date + 1, 8);
  end if;
  v_day := (coalesce(v_after, now()) at time zone v_tz)::date;
  -- Ten a day to one number, counted on the day each goes.
  if (select count(*) from messages where template = 'alert' and channel = 'whatsapp' and to_address = v_to and status <> 'failed'
        and created_at > now() - interval '2 days' and (coalesce(send_after, created_at) at time zone v_tz)::date = v_day) >= 10 then
    return false;
  end if;
  if not private.alert_once(p_org, p_kind, p_key || ':' || p_user, 'whatsapp') then return false; end if;
  insert into messages (org_id, channel, to_address, template, subject, params, created_by, send_after)
  values (p_org, 'whatsapp', v_to, 'alert', left(coalesce(p->>'subject', p->>'title'), 200),
    jsonb_build_object('kind', p_kind, 'person_name', m.display_name, 'business', o.name, 'heading', p->>'title',
      'lines', case when jsonb_typeof(p->'lines') = 'array' then p->'lines' else jsonb_build_array(coalesce(p->>'body', '')) end,
      'button', coalesce(p->>'button', 'Open Counta'),
      'link', coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app') || coalesce(nullif(p->>'url', ''), '/home'),
      'link_id', w.link_id, 'reply_hint', coalesce(w.same_org, false), 'automatic', true)
      || case when p ? 'wa_name' then jsonb_build_object('wa', jsonb_build_object('name', p->>'wa_name', 'params', coalesce(p->'wa_params', '[]'::jsonb))) else '{}'::jsonb end,
    m.id, v_after)
  returning * into msg;
  if msg.status <> 'queued' then return false; end if;
  if v_after is null then perform private.call_function('messaging', jsonb_build_object('message_id', msg.id)); end if;
  return true;
end $$;

-- ---------------------------------------------------------------------------
-- 4. The morning alerts, and the push notifications that ask for action
-- ---------------------------------------------------------------------------
-- Push to whoever the work is for, email to the owner, WhatsApp to everyone the work is for who linked their number; each
-- once for its key. A sample business never emails; it sends WhatsApp alerts to its own people only.
-- p: {perm, title, body, url, lines[], button, wa_name, wa_params[], subject}
create or replace function private.alert_send(p_org uuid, p_kind text, p_key text, p_channels text[], p jsonb) returns text[]
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; ow public.members; m public.members; v_prefs jsonb := private.alert_prefs(p_org); v_sent text[] := '{}'; v_link text; v_wa int := 0;
begin
  select * into o from orgs where id = p_org;
  select * into ow from members where org_id = p_org and role = 'owner' and status = 'active' order by created_at limit 1;
  v_link := coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app') || coalesce(p->>'url', '/home');
  if 'push' = any(p_channels) and private.alert_once(p_org, p_kind, p_key, 'push') then
    perform private.notify_perm(p_org, coalesce(p->>'perm', 'keep_books'), p_kind, p->>'title', p->>'body', p->>'url', p_kind || ':' || p_key);
    v_sent := v_sent || 'push'::text;
  end if;
  if 'email' = any(p_channels) and not o.is_sample and ow.id is not null and (v_prefs->>'email')::boolean and private.feature_on(p_org, 'email')
     and nullif(trim(coalesce(ow.email, '')), '') is not null and private.alert_once(p_org, p_kind, p_key, 'email') then
    begin
      perform private.queue_message(p_org, 'email', ow.email, 'alert', coalesce(p->>'subject', p->>'title'),
        jsonb_build_object('kind', p_kind, 'person_name', ow.display_name, 'business', o.name, 'heading', p->>'title', 'lines', coalesce(p->'lines', jsonb_build_array(p->>'body')),
          'button', coalesce(p->>'button', 'Open Counta'), 'link', v_link, 'automatic', true), null, null, ow.id);
      v_sent := v_sent || 'email'::text;
    exception when others then null;
    end;
  end if;
  if 'whatsapp' = any(p_channels) and (v_prefs->>'whatsapp')::boolean and private.feature_on(p_org, 'whatsapp') and not private.quiet(p_org) then
    for m in select * from members where org_id = p_org and status = 'active' and user_id is not null order by role = 'owner' desc, created_at loop
      continue when not private.perm_of(m, coalesce(p->>'perm', 'keep_books'));
      begin
        if private.wa_alert(p_org, m.user_id, p_kind, p_key, p) then v_wa := v_wa + 1; end if;
      exception when others then null;
      end;
    end loop;
    if v_wa > 0 then v_sent := v_sent || 'whatsapp'::text; end if;
  end if;
  return v_sent;
end $$;

-- A notification on the bell and the phone's push; one that asks for action also goes to the person's WhatsApp.
create or replace function private.notify(p_org uuid, p_user uuid, p_kind text, p_title text, p_body text, p_url text, p_tag text default null) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if p_user is null or private.quiet(p_org) then return; end if;
  if p_tag is not null and exists (
    select 1 from notifications where user_id = p_user and tag = p_tag and created_at > now() - interval '10 minutes') then
    return;
  end if;
  insert into notifications (org_id, user_id, kind, title, body, url, tag)
  values (p_org, p_user, p_kind, left(p_title, 120), left(coalesce(p_body, ''), 300), coalesce(p_url, '/'), p_tag);
  if p_org is not null and private.wa_worthy(p_kind, p_title) then
    begin
      perform private.wa_alert(p_org, p_user, p_kind,
        coalesce(p_tag, md5(coalesce(p_title, '') || '|' || coalesce(p_url, ''))) || ':' || private.local_day(p_org, now()),
        jsonb_build_object('title', left(p_title, 120), 'body', left(coalesce(p_body, ''), 300), 'url', p_url, 'button', 'Open Counta'));
    exception when others then null;
    end;
  end if;
end $$;

-- A tax's name inside a sentence: "VAT return" and "WHT to NRS" keep their capitals, "Companies income tax return" does not.
create or replace function private.label_mid(p text) returns text
language sql immutable set search_path = '' as $$
  select case when p ~ '^[A-Z]{2}' then p else lower(left(p, 1)) || substr(p, 2) end
$$;

-- Every morning: tax deadlines, invoices due, transactions to confirm before the returns, and customers' overdue invoices.
-- (As before; the tax's name now keeps its capitals in the middle of a sentence: "VAT return", "WHT to NRS", "companies
-- income tax return".)
create or replace function private.alerts_tick() returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare cfg jsonb := private.setting('alerts'); o record; d record; v_today date; v_left int; v_ch text[]; v_n int; v_amt numeric; v_oldest text; v_prefs jsonb;
  ow public.members; v_out jsonb := '{}'::jsonb; v_cnt int := 0; s record; v_calls int; v_per_day int; v_mth date; v_due21 date; v_key text; v_days int[];
begin
  for o in select x.* from orgs x where exists (select 1 from members m where m.org_id = x.id and m.role = 'owner' and m.status = 'active') loop
    v_today := private.local_day(o.id, now());
    v_prefs := private.alert_prefs(o.id);
    select * into ow from members where org_id = o.id and role = 'owner' and status = 'active' order by created_at limit 1;
    -- ---- tax deadlines
    v_days := array(select (jsonb_array_elements_text(cfg->'tax_deadline'->'days_before'))::int);
    for d in select * from private.tax_deadlines(o.id) loop
      v_left := d.due - v_today;
      v_key := d.tax || ':' || d.period || ':' || v_left;
      v_ch := '{}';
      if (cfg->'tax_deadline'->>'push')::boolean and (v_left = any(v_days) or v_left = 0 or (v_left < 0 and v_left % 3 = 0)) then v_ch := v_ch || 'push'::text; end if;
      if (v_left = any(array(select (jsonb_array_elements_text(cfg->'tax_deadline'->'message_days_before'))::int)) or v_left = 0 or (v_left < 0 and v_left % 7 = 0)) then
        if (cfg->'tax_deadline'->>'email')::boolean then v_ch := v_ch || 'email'::text; end if;
        if (cfg->'tax_deadline'->>'whatsapp')::boolean then v_ch := v_ch || 'whatsapp'::text; end if;
      end if;
      if cardinality(v_ch) > 0 then
        perform private.alert_send(o.id, 'tax_deadline', v_key, v_ch, jsonb_build_object('perm', 'file_tax',
          'title', d.label || ' for ' || to_char(d.period, 'FMMonth YYYY') || case when v_left > 1 then ' is due in ' || v_left || ' days'
            when v_left = 1 then ' is due tomorrow' when v_left = 0 then ' is due today' else ' is ' || -v_left || ' days late' end,
          'body', 'Due on ' || to_char(d.due, 'FMDD Mon YYYY') || coalesce(' · ' || private.naira(d.amount), '') || '. Open Counta to finish it.',
          'url', d.url, 'button', 'Open the return',
          'lines', jsonb_build_array(o.name || '''s ' || private.label_mid(d.label) || ' for ' || to_char(d.period, 'FMMonth YYYY') || ' is due on ' || to_char(d.due, 'FMDD Mon YYYY') || '.',
            case when d.amount is not null then private.naira(d.amount) || ' is due.' else 'Counta has prepared it from the books; check it and file.' end,
            case when v_left < 0 then 'It is late: penalties and interest grow each month it stays unfiled.' end),
          'wa_name', 'counta_tax_deadline', 'wa_params', jsonb_build_array(split_part(ow.display_name, ' ', 1), o.name, private.label_mid(d.label),
            to_char(d.period, 'FMMonth YYYY'), to_char(d.due, 'FMDD Mon YYYY'), coalesce(private.naira(d.amount), 'prepared in Counta'))));
        v_cnt := v_cnt + 1;
      end if;
      -- Martina calls the owner the day before.
      if v_left = coalesce((cfg->'tax_deadline'->>'call_days_before')::int, 1) and (cfg->'tax_deadline'->>'call')::boolean and (v_prefs->>'owner_calls')::boolean
         and not o.is_sample and private.feature_on(o.id, 'phone_calls') and private.e164(ow.phone) is not null
         and private.alert_once(o.id, 'tax_deadline', d.tax || ':' || d.period, 'call') then
        insert into voice_calls (org_id, kind, member_id, topic, to_number, variables, created_by, call_after)
        values (o.id, 'tax_deadline', ow.id, d.tax, private.e164(ow.phone), jsonb_build_object('business_name', o.name, 'person_name', ow.display_name,
            'person_first_name', split_part(ow.display_name, ' ', 1), 'tax_name', d.label, 'period', to_char(d.period, 'FMMonth YYYY'),
            'due_date', to_char(d.due, 'FMDay DD FMMonth'), 'amount', coalesce(private.naira(d.amount), 'the amount Counta worked out'),
            'what_to_do', case d.tax when 'vat' then 'Open Counta, go to Tax returns and VAT, check the month and file it, then pay what is due.'
              when 'cit' then 'Open Counta, go to Tax returns and Companies income tax, check the computation and approve it for filing.'
              else 'Open Counta, go to Tax returns and Withholding tax, and pay what was deducted with the schedule.' end),
          ow.id, greatest(now(), private.local_hour_at(o.id, v_today, coalesce((cfg->'calls'->'hours'->>0)::int, 9))));
      end if;
    end loop;
    -- ---- invoices due and overdue
    select count(*), coalesce(sum(s2.total - s2.amount_paid - s2.credited), 0), min(s2.number) filter (where s2.due_date = (select min(due_date) from sales s3 where s3.org_id = o.id
             and s3.doc_type = 'invoice' and s3.status in ('open', 'partially_paid') and s3.due_date <= v_today + coalesce((cfg->'invoices'->>'due_soon_days')::int, 3)))
      into v_n, v_amt, v_oldest
    from sales s2 where s2.org_id = o.id and s2.doc_type = 'invoice' and s2.status in ('open', 'partially_paid') and s2.journal_id is not null
      and s2.due_date <= v_today + coalesce((cfg->'invoices'->>'due_soon_days')::int, 3);
    if v_n > 0 then
      v_ch := case when (cfg->'invoices'->>'push')::boolean then array['push'] else '{}' end;
      -- The week's digest, and the day an invoice first goes overdue.
      if extract(isodow from v_today)::int = coalesce((cfg->'invoices'->>'digest_weekday')::int, 1)
         or exists (select 1 from sales s4 where s4.org_id = o.id and s4.doc_type = 'invoice' and s4.status in ('open', 'partially_paid') and s4.due_date = v_today - 1) then
        if (cfg->'invoices'->>'email')::boolean then v_ch := v_ch || 'email'::text; end if;
        if (cfg->'invoices'->>'whatsapp')::boolean then v_ch := v_ch || 'whatsapp'::text; end if;
      end if;
      perform private.alert_send(o.id, 'invoices', v_today::text, v_ch, jsonb_build_object('perm', 'record_sales',
        'title', v_n || ' invoice' || case when v_n = 1 then ' is' else 's are' end || ' due or overdue',
        'body', private.naira(v_amt) || ' in all' || coalesce(' · the oldest is ' || v_oldest, ''),
        'url', '/sell/sales?status=overdue', 'button', 'See the invoices',
        'lines', jsonb_build_array(o.name || ' has ' || v_n || ' invoice' || case when v_n = 1 then '' else 's' end || ' due in the next few days or overdue, ' || private.naira(v_amt) || ' in all.',
          'Counta reminds the customers on the days set in Settings; you can send a reminder or a statement from each invoice.'),
        'wa_name', 'counta_invoices_due', 'wa_params', jsonb_build_array(split_part(ow.display_name, ' ', 1), o.name, v_n::text, private.naira(v_amt),
          coalesce(v_oldest, '-'))));
    end if;
    -- ---- transactions to confirm before the month's VAT and WHT returns (from the 10th to the 20th)
    v_mth := (date_trunc('month', v_today) - interval '1 month')::date;
    v_due21 := (date_trunc('month', v_today))::date + 20;
    if extract(day from v_today) between coalesce((cfg->'confirm'->>'push_from_day')::int, 10) and 20 then
      select count(*) into v_n from bank_lines bl where bl.org_id = o.id and bl.status in ('unmatched', 'proposed') and bl.line_date between v_mth and (v_mth + interval '1 month' - interval '1 day')::date;
      v_n := v_n + (select count(*) from receipts r where r.org_id = o.id and r.status = 'needs_review' and r.created_at::date between v_mth and v_due21)
                 + (select count(*) from sales_schedules sc where sc.org_id = o.id and sc.status = 'draft');
      if v_n > 0 then
        v_ch := array['push'];
        if extract(day from v_today)::int = any(array(select (jsonb_array_elements_text(cfg->'confirm'->'message_days'))::int)) then
          if (cfg->'confirm'->>'email')::boolean then v_ch := v_ch || 'email'::text; end if;
          if (cfg->'confirm'->>'whatsapp')::boolean then v_ch := v_ch || 'whatsapp'::text; end if;
        end if;
        perform private.alert_send(o.id, 'confirm', v_today::text, v_ch, jsonb_build_object('perm', 'keep_books',
          'title', v_n || ' transaction' || case when v_n = 1 then '' else 's' end || ' to confirm before the returns',
          'body', 'From ' || to_char(v_mth, 'FMMonth') || '. The VAT and WHT returns are due on ' || to_char(v_due21, 'FMDD Mon') || '.',
          'url', '/accounting/inbox', 'button', 'Confirm them',
          'lines', jsonb_build_array(v_n || ' transaction' || case when v_n = 1 then '' else 's' end || ' from ' || to_char(v_mth, 'FMMonth YYYY') || ' still need your answer before they go into the returns.',
            'The VAT and WHT returns for ' || to_char(v_mth, 'FMMonth') || ' are due on ' || to_char(v_due21, 'FMDD Mon YYYY') || '.'),
          'wa_name', 'counta_confirm_items', 'wa_params', jsonb_build_array(split_part(ow.display_name, ' ', 1), o.name, v_n::text, to_char(v_mth, 'FMMonth YYYY'),
            to_char(v_due21, 'FMDD Mon'))));
      end if;
    end if;
    -- ---- Martina follows up customers' overdue invoices, when the business asked for it
    if (v_prefs->>'customer_calls')::boolean and (cfg->'customer_calls'->>'enabled')::boolean and not o.is_sample and private.feature_on(o.id, 'phone_calls') then
      v_per_day := coalesce((cfg->'customer_calls'->>'per_org_per_day')::int, 5);
      select count(*) into v_calls from voice_calls where org_id = o.id and kind = 'customer_followup' and created_at > now() - interval '20 hours';
      for s in select sa.*, cu.phone cphone, cu.name cname from sales sa join customers cu on cu.id = sa.customer_id
               where sa.org_id = o.id and sa.doc_type = 'invoice' and sa.status in ('open', 'partially_paid') and sa.journal_id is not null and not cu.is_walk_in
                 and sa.due_date <= v_today - coalesce((cfg->'customer_calls'->>'min_days_overdue')::int, 7)
                 and sa.total - sa.amount_paid - sa.credited >= coalesce((cfg->'customer_calls'->>'min_amount')::numeric, 10000)
                 and private.e164(cu.phone) is not null
                 -- a reminder went at least two days ago and was not answered with payment
                 and sa.reminded_at is not null and sa.reminded_at < now() - interval '2 days'
                 and not exists (select 1 from voice_calls vc where vc.sale_id = sa.id
                                 and vc.created_at > now() - make_interval(days => coalesce((cfg->'customer_calls'->>'repeat_days')::int, 7)))
               order by sa.total - sa.amount_paid - sa.credited desc limit 20 loop
        exit when v_calls >= v_per_day;
        insert into voice_calls (org_id, kind, sale_id, customer_id, topic, to_number, variables, created_by, call_after)
        values (o.id, 'customer_followup', s.id, s.customer_id, 'overdue_invoice', private.e164(s.cphone), jsonb_build_object('business_name', o.name,
            'customer_name', s.cname, 'customer_first_name', split_part(s.cname, ' ', 1), 'invoice_number', s.number,
            'amount_due', private.naira(s.total - s.amount_paid - s.credited), 'due_date', to_char(s.due_date, 'FMDD FMMonth YYYY'),
            'days_overdue', (v_today - s.due_date)::text, 'contact_name', ow.display_name, 'contact_phone', coalesce(o.phone, ow.phone, ''),
            'pay_link', private.doc_link(s.public_token)),
          ow.id, greatest(now(), private.local_hour_at(o.id, v_today, coalesce((cfg->'calls'->'hours'->>0)::int, 9))));
        v_calls := v_calls + 1;
      end loop;
    end if;
  end loop;
  delete from alert_log where sent_at < now() - interval '120 days';
  return jsonb_build_object('alerts', v_cnt);
end $$;

-- ---------------------------------------------------------------------------
-- 5. What Settings, Alerts shows
-- ---------------------------------------------------------------------------
create or replace function public.get_alert_prefs(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  return private.alert_prefs(p_org) || jsonb_build_object('can_change', m.role = 'owner' or private.perm_of(m, 'manage_settings'),
    'owner', (select jsonb_build_object('name', display_name, 'phone', phone, 'email', email) from members where org_id = p_org and role = 'owner' and status = 'active'
              order by created_at limit 1),
    'calls', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'status', c.status, 'summary', c.summary, 'outcome', c.outcome,
        'created_at', c.created_at, 'to', (select name from customers where id = c.customer_id), 'sale', (select number from sales where id = c.sale_id))
        order by c.created_at desc), '[]'::jsonb)
      from (select * from voice_calls where org_id = p_org and kind in ('tax_deadline', 'customer_followup') order by created_at desc limit 30) c),
    -- Who gets WhatsApp alerts here: the people who linked WhatsApp to Martina. Names only; the person's own number, masked.
    'whatsapp_people', (select coalesce(jsonb_agg(x.name order by x.name), '[]'::jsonb) from (
        select distinct coalesce(nullif(trim(mm.display_name), ''), 'A team member') as name from members mm
        where mm.org_id = p_org and mm.status = 'active' and mm.user_id is not null
          and exists (select 1 from chat_links l where l.user_id = mm.user_id and l.channel = 'whatsapp' and l.status = 'active')) x),
    'my_whatsapp', (select '+' || left(w.phone, 3) || ' ••• ••• ' || right(w.phone, 4) from private.wa_number(auth.uid(), p_org) w));
end $$;

-- ---------------------------------------------------------------------------
-- 6. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function private.wa_number(uuid, uuid), private.wa_worthy(text, text), private.wa_alert(uuid, uuid, text, text, jsonb), private.label_mid(text)
  from public, anon, authenticated;
