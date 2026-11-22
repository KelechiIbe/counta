-- Counta on WhatsApp, almost everywhere (docs/whatsapp-martina.md).
--
-- 1. Books inbox alerts. A question Atlas could not answer on its own pushes to everyone who keeps the books as it lands
--    (one push for a burst, by tag). Every morning while questions wait, each of them gets one email and one WhatsApp
--    listing what waits. On the days before the returns, the same message carries the count of transactions to confirm,
--    and the separate "transactions to confirm" email and WhatsApp of that morning are not sent again. Which invoice or
--    bill a payment settles waits for the morning message too, instead of a WhatsApp for each one.
-- 2. An approval PIN. Approving a tax return on WhatsApp files it, so after Martina reads the figures back the person
--    types a six-digit PIN they set in Counta. The chat function checks it before Martina sees the message; five wrong
--    tries lock it for an hour.
-- 3. Martina does more on WhatsApp: the books inbox, orders and deliveries, stock, purchase orders, quotes, payment links,
--    credit notes, customers, products, approvals, tax returns and the daily report. Every step still runs as the person
--    through svc_chat_rpc, so the database's own checks decide; money still moves only from Counta.
-- 4. A daily PDF report of the day's activity, by WhatsApp and email: the owner and whoever keeps the books get it at
--    19:00 unless they turn it off; anyone else may turn it on for themselves. Each section shows only what the person's
--    role sees.
-- 5. Customers talk to Martina. A customer writing back to the number that sent them an invoice, receipt or order reaches
--    Martina answering for that business: their own orders and invoices with links to pay, a word that they paid, an order
--    from the business's shop, or a hand-off to the team, who answer from Sell, Customer chats.

-- ---------------------------------------------------------------------------
-- 1. Books inbox alerts
-- ---------------------------------------------------------------------------
-- Which push notifications also go to WhatsApp at once. As before, except: a payment to match ('bank') now waits for the
-- morning message, and a customer waiting for an answer on WhatsApp ('customer_chat') goes at once.
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
    when 'bank' then false               -- which invoice or bill a payment settles: in the morning's books inbox message
    when 'books_inbox' then false        -- the same
    when 'customer_chat' then true       -- a customer on WhatsApp waiting for a person
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

-- A new question in the books inbox: a push to everyone who keeps the books. A burst (a statement read, a feed) makes one
-- push, since notify keeps one per tag for ten minutes. Payments to match and a customer's word that they paid push on their
-- own already.
create or replace function private.inbox_push() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_n int;
begin
  if new.status <> 'pending' or new.kind = 'payment_claim' or coalesce(new.proposal->>'kind', '') in ('invoice_match', 'bill_match') then return null; end if;
  if private.quiet(new.org_id) then return null; end if;
  select count(*) into v_n from ai_proposals where org_id = new.org_id and status = 'pending';
  perform private.notify_perm(new.org_id, 'keep_books', 'books_inbox',
    case when v_n <= 1 then 'A question in the books inbox' else v_n || ' questions in the books inbox' end,
    left(coalesce(nullif(new.title, ''), new.question, 'Atlas needs your answer.'), 200) || coalesce(' · ' || private.naira(abs(new.amount)), ''),
    '/accounting/inbox', 'books-inbox');
  return null;
end $$;
drop trigger if exists ai_proposals_inbox_push on public.ai_proposals;
create trigger ai_proposals_inbox_push after insert on public.ai_proposals for each row execute function private.inbox_push();

-- One WhatsApp alert to one person (as before), carrying the line that says what a reply does when the alert asks for one
-- of its own ("Reply here with \"inbox\" ...").
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
      || case when p ? 'wa_name' then jsonb_build_object('wa', jsonb_build_object('name', p->>'wa_name', 'params', coalesce(p->'wa_params', '[]'::jsonb))) else '{}'::jsonb end
      || case when coalesce(p->>'reply_line', '') <> '' then jsonb_build_object('reply_line', left(p->>'reply_line', 200)) else '{}'::jsonb end,
    m.id, v_after)
  returning * into msg;
  if msg.status <> 'queued' then return false; end if;
  if v_after is null then perform private.call_function('messaging', jsonb_build_object('message_id', msg.id)); end if;
  return true;
end $$;

-- What the books inbox holds for the morning message: how many, the oldest, and a few of them.
create or replace function private.inbox_summary(p_org uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('n', count(*), 'oldest', min(p.created_at),
    'matches', count(*) filter (where p.proposal->>'kind' in ('invoice_match', 'bill_match')),
    'examples', coalesce((select jsonb_agg(left(coalesce(nullif(x.title, ''), x.question, 'A question'), 90)
        || coalesce(' (' || private.naira(abs(x.amount)) || ')', '') order by x.created_at)
      from (select title, question, amount, created_at from ai_proposals where org_id = p_org and status = 'pending' order by created_at limit 4) x), '[]'::jsonb))
  from ai_proposals p where p.org_id = p_org and p.status = 'pending'
$$;

-- The morning message for one business: one email and one WhatsApp to each person who keeps the books, once a day while
-- questions wait. Between the 10th and the 20th it also counts what is still to confirm before the month's returns, and
-- takes the place of that morning's separate "transactions to confirm" email and WhatsApp. Returns who was messaged.
create or replace function private.inbox_digest(p_org uuid) returns int
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; s jsonb := private.inbox_summary(p_org); v_today date; v_prefs jsonb; m public.members; v_n int; v_c int := 0; v_mth date; v_due21 date;
  v_lines jsonb; v_wa_lines jsonb; v_title text; v_link text; v_sent int := 0; w record; v_any boolean; v_email boolean; v_wa boolean;
begin
  select * into o from orgs where id = p_org;
  v_n := coalesce((s->>'n')::int, 0);
  if not found or v_n = 0 or o.read_only_at is not null or private.quiet(p_org) then return 0; end if;
  v_today := private.local_day(p_org, now());
  v_prefs := private.alert_prefs(p_org);
  v_mth := (date_trunc('month', v_today) - interval '1 month')::date;
  v_due21 := (date_trunc('month', v_today))::date + 20;
  if extract(day from v_today) between coalesce((private.setting('alerts')->'confirm'->>'push_from_day')::int, 10) and 20 then
    select count(*) into v_c from bank_lines bl where bl.org_id = p_org and bl.status in ('unmatched', 'proposed')
      and bl.line_date between v_mth and (v_mth + interval '1 month' - interval '1 day')::date;
    v_c := v_c + (select count(*) from receipts r where r.org_id = p_org and r.status = 'needs_review' and r.created_at::date between v_mth and v_due21)
               + (select count(*) from sales_schedules sc where sc.org_id = p_org and sc.status = 'draft');
  end if;
  v_title := case when v_n = 1 then 'A question waits in the books inbox' else v_n || ' questions wait in the books inbox' end;
  v_lines := jsonb_build_array(
    'Atlas could not be sure about ' || case when v_n = 1 then 'one transaction' else v_n || ' transactions' end
      || ', the oldest from ' || to_char(((s->>'oldest')::timestamptz at time zone coalesce(o.timezone, 'Africa/Lagos'))::date, 'FMDD Mon') || '.')
    || coalesce((select jsonb_agg('- ' || e) from jsonb_array_elements_text(s->'examples') e), '[]'::jsonb)
    || case when v_n > 4 then jsonb_build_array('and ' || (v_n - 4) || ' more.') else '[]'::jsonb end
    || case when v_c > 0 then jsonb_build_array(v_c || ' transaction' || case when v_c = 1 then '' else 's' end || ' from ' || to_char(v_mth, 'FMMonth')
      || ' still need an answer before the VAT and WHT returns due on ' || to_char(v_due21, 'FMDD Mon') || '.') else '[]'::jsonb end;
  v_link := coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app') || '/accounting/inbox';
  v_email := not o.is_sample and (v_prefs->>'email')::boolean and private.feature_on(p_org, 'email');
  v_wa := (v_prefs->>'whatsapp')::boolean and private.feature_on(p_org, 'whatsapp');
  for m in select * from members where org_id = p_org and status = 'active' and user_id is not null order by created_at loop
    continue when not private.perm_of(m, 'keep_books');
    v_any := false;
    if v_email and nullif(trim(coalesce(m.email, '')), '') is not null and private.alert_once(p_org, 'books_inbox', v_today || ':' || m.user_id, 'email') then
      begin
        perform private.queue_message(p_org, 'email', m.email, 'alert', v_title,
          jsonb_build_object('kind', 'books_inbox', 'person_name', m.display_name, 'business', o.name, 'heading', v_title, 'lines', v_lines,
            'button', 'Answer them', 'link', v_link, 'automatic', true), null, null, m.id);
        v_any := true;
      exception when others then null;
      end;
    end if;
    if v_wa then
      select * into w from private.wa_number(m.user_id, p_org);
      v_wa_lines := v_lines;
      begin
        if private.wa_alert(p_org, m.user_id, 'books_inbox', v_today::text, jsonb_build_object('title', v_title, 'lines', v_wa_lines, 'url', '/accounting/inbox',
            'button', 'Answer them', 'reply_line', 'Reply here with "inbox" and Martina goes through them with you, one at a time.',
            'wa_name', 'counta_books_inbox', 'wa_params', jsonb_build_array(split_part(coalesce(m.display_name, 'there'), ' ', 1), o.name, v_n::text,
              to_char(((s->>'oldest')::timestamptz at time zone coalesce(o.timezone, 'Africa/Lagos'))::date, 'FMDD Mon')))) then
          v_any := true;
          -- The morning's "transactions to confirm" WhatsApp to this person is in this one.
          if v_c > 0 then perform private.alert_once(p_org, 'confirm', v_today::text || ':' || m.user_id, 'whatsapp'); end if;
        end if;
      exception when others then null;
      end;
    end if;
    if v_any then v_sent := v_sent + 1; end if;
  end loop;
  -- The owner's "transactions to confirm" email of this morning is in this one too.
  if v_sent > 0 and v_c > 0 and v_email then perform private.alert_once(p_org, 'confirm', v_today::text, 'email'); end if;
  return v_sent;
end $$;

-- Every morning, before the other alerts (which run at :05).
create or replace function private.inbox_digest_tick() returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r record; v_people int := 0; v_orgs int := 0; v int;
begin
  for r in select distinct org_id from ai_proposals where status = 'pending' loop
    begin
      v := private.inbox_digest(r.org_id);
      if v > 0 then v_orgs := v_orgs + 1; v_people := v_people + v; end if;
    exception when others then null;
    end;
  end loop;
  return jsonb_build_object('businesses', v_orgs, 'people', v_people);
end $$;

-- ---------------------------------------------------------------------------
-- 2. The approval PIN
-- ---------------------------------------------------------------------------
-- One PIN per person, for every business they are on. Only a bcrypt hash is kept.
create table if not exists public.approval_pins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  pin_hash text not null,
  set_at timestamptz not null default now(),
  tries int not null default 0,
  locked_until timestamptz,
  last_used_at timestamptz
);
alter table public.approval_pins enable row level security;
revoke all on public.approval_pins from anon, authenticated;

create or replace function public.approval_pin_status() returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('set', p.user_id is not null, 'set_at', p.set_at, 'last_used_at', p.last_used_at,
    'locked_until', case when p.locked_until > now() then p.locked_until end)
  from (select 1) x left join approval_pins p on p.user_id = auth.uid()
$$;

-- Six digits, not all one digit and not a run (123456, 654321).
create or replace function private.pin_weak(p_pin text) returns boolean
language sql immutable set search_path = '' as $$
  select p_pin ~ '^(\d)\1{5}$' or position(p_pin in '01234567890123456789') > 0 or position(p_pin in '98765432109876543210') > 0
$$;

create or replace function public.set_approval_pin(p_pin text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_pin text := regexp_replace(coalesce(p_pin, ''), '\s', '', 'g');
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if v_pin !~ '^[0-9]{6}$' then raise exception 'The PIN is six digits.'; end if;
  if private.pin_weak(v_pin) then raise exception 'Choose a PIN that is harder to guess than a run or a repeated digit.'; end if;
  insert into approval_pins (user_id, pin_hash) values (auth.uid(), extensions.crypt(v_pin, extensions.gen_salt('bf', 8)))
  on conflict (user_id) do update set pin_hash = excluded.pin_hash, set_at = now(), tries = 0, locked_until = null;
  return public.approval_pin_status();
end $$;

create or replace function public.clear_approval_pin() returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  delete from approval_pins where user_id = auth.uid();
  return public.approval_pin_status();
end $$;

-- The chat function, when a person types digits while a tax return waits for their PIN. Five wrong tries lock it for an
-- hour, and the person is told on their phone and the bell.
create or replace function public.svc_check_pin(p_link uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.chat_links; p public.approval_pins; v_pin text := regexp_replace(coalesce(p_pin, ''), '\s', '', 'g');
begin
  select * into l from chat_links where id = p_link and status = 'active';
  if not found then return jsonb_build_object('ok', false, 'reason', 'no_link'); end if;
  select * into p from approval_pins where user_id = l.user_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_set'); end if;
  if p.locked_until > now() then return jsonb_build_object('ok', false, 'reason', 'locked', 'until', p.locked_until); end if;
  if v_pin ~ '^[0-9]{6}$' and extensions.crypt(v_pin, p.pin_hash) = p.pin_hash then
    update approval_pins set tries = 0, locked_until = null, last_used_at = now() where user_id = l.user_id;
    return jsonb_build_object('ok', true);
  end if;
  if p.tries + 1 >= 5 then
    update approval_pins set tries = 0, locked_until = now() + interval '1 hour' where user_id = l.user_id;
    perform private.notify(l.org_id, l.user_id, 'identity', 'Your approval PIN is locked for an hour',
      'Someone typed a wrong approval PIN five times on WhatsApp. If it was not you, change the PIN in Settings, Martina on WhatsApp, and unlink the number.',
      '/settings#martina-anywhere', 'pin-locked');
    return jsonb_build_object('ok', false, 'reason', 'locked', 'until', now() + interval '1 hour');
  end if;
  update approval_pins set tries = p.tries + 1 where user_id = l.user_id;
  return jsonb_build_object('ok', false, 'reason', 'wrong', 'left', 4 - p.tries);
end $$;

-- ---------------------------------------------------------------------------
-- 3. What Martina may do on WhatsApp
-- ---------------------------------------------------------------------------
alter table public.chat_pending drop constraint if exists chat_pending_kind_check;
alter table public.chat_pending add constraint chat_pending_kind_check check (kind in ('sale', 'invoice', 'bill', 'reminder', 'inbox', 'order_confirm',
  'order_cancel', 'delivery', 'transfer', 'transfer_receive', 'count', 'po', 'quote', 'payment_link', 'credit', 'customer', 'product', 'approval',
  'tax_return', 'supplier_invoice', 'send_doc'));
alter table public.chat_pending add column if not exists needs_pin boolean not null default false;

-- p: {kind, title, read_back, payload, needs_pin}. Replaces anything waiting.
create or replace function public.svc_chat_pending_set(p_link uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into chat_pending (link_id, kind, title, read_back, payload, needs_pin)
  values (p_link, p->>'kind', left(p->>'title', 200), left(p->>'read_back', 1000), p->'payload', coalesce((p->>'needs_pin')::boolean, false))
  on conflict (link_id) do update set action_id = gen_random_uuid(), kind = excluded.kind, title = excluded.title, read_back = excluded.read_back,
    payload = excluded.payload, needs_pin = excluded.needs_pin, at = now()
  returning action_id into v_id;
  return v_id;
end $$;

create or replace function public.svc_chat_pending(p_link uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('action_id', action_id, 'kind', kind, 'title', title, 'read_back', read_back, 'payload', payload, 'at', at,
    'needs_pin', needs_pin, 'expired', at < now() - interval '10 minutes') from chat_pending where link_id = p_link
$$;

-- Whether a record a call names is in the business. Calls that name a record outside it are refused before the record's
-- own function runs.
create or replace function private.chat_owns(p_org uuid, p_kind text, p_id uuid) returns boolean
language sql stable security definer set search_path = public, private as $$
  select p_id is not null and case p_kind
    when 'sale' then exists (select 1 from sales where id = p_id and org_id = p_org)
    when 'customer' then exists (select 1 from customers where id = p_id and org_id = p_org)
    when 'bill' then exists (select 1 from bills where id = p_id and org_id = p_org)
    when 'delivery' then exists (select 1 from deliveries where id = p_id and org_id = p_org)
    when 'transfer' then exists (select 1 from transfers where id = p_id and org_id = p_org)
    when 'count' then exists (select 1 from count_sessions where id = p_id and org_id = p_org)
    when 'po' then exists (select 1 from purchase_orders where id = p_id and org_id = p_org)
    when 'vendor' then exists (select 1 from vendors where id = p_id and org_id = p_org)
    when 'item' then exists (select 1 from items where id = p_id and org_id = p_org)
    when 'location' then exists (select 1 from locations where id = p_id and org_id = p_org)
    when 'proposal' then exists (select 1 from ai_proposals where id = p_id and org_id = p_org)
    when 'approval' then exists (select 1 from approvals where id = p_id and org_id = p_org)
    else false end
$$;

-- Every step Martina takes runs here, as the person: the database's own checks decide what they may see and do, in the
-- business the link is for and no other. Only these calls are possible. (As before, with the calls for the books inbox,
-- orders and deliveries, stock, purchase orders, customers, products, payment links, credit notes, approvals, tax returns
-- and the tax files Flux receives.)
create or replace function public.svc_chat_rpc(p_link uuid, p_fn text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.chat_links; v_org uuid; r jsonb; v_id uuid; v_need text; v_key text;
begin
  select * into l from chat_links where id = p_link and status = 'active';
  if not found then raise exception 'This link is not active any more.' using errcode = '42501'; end if;
  if not exists (select 1 from members where org_id = l.org_id and user_id = l.user_id and status = 'active') then
    raise exception 'You are no longer on this business''s team.' using errcode = '42501';
  end if;
  v_org := l.org_id;
  p := coalesce(p, '{}'::jsonb);
  perform set_config('request.jwt.claim.sub', l.user_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', l.user_id, 'role', 'authenticated', 'aud', 'authenticated', 'aal', 'aal1',
    'via', 'martina_' || l.channel)::text, true);
  -- The record each call names, and the kind it must be.
  v_need := case
    when p_fn in ('send_document', 'send_reminder', 'get_sale', 'confirm_order', 'cancel_order', 'credit_sale', 'sale_creditable') then 'sale'
    when p_fn = 'send_statement' then 'customer'
    when p_fn = 'approve_bill' then 'bill'
    when p_fn = 'receive_transfer' then 'transfer'
    when p_fn in ('approve_count', 'reject_count') then 'count'
    when p_fn = 'send_po' then 'po'
    when p_fn = 'resolve_proposal' then 'proposal'
    when p_fn = 'set_item_vat' then 'item'
    when p_fn = 'approval_decide' then 'approval'
    end;
  v_key := case v_need when 'sale' then 'sale_id' when 'customer' then 'customer_id' when 'bill' then 'bill_id' when 'transfer' then 'transfer_id'
    when 'count' then 'session_id' when 'po' then 'po_id' when 'proposal' then 'proposal_id' when 'item' then 'item_id' when 'approval' then 'approval_id' end;
  if v_need is not null then
    v_id := nullif(p->>v_key, '')::uuid;
    if not private.chat_owns(v_org, v_need, v_id) then raise exception 'That % is not in this business.', replace(v_need, '_', ' '); end if;
  end if;
  -- Records named inside a call's own payload.
  if p_fn = 'save_delivery' then
    if nullif(p->'delivery'->>'id', '') is not null and not private.chat_owns(v_org, 'delivery', (p->'delivery'->>'id')::uuid) then raise exception 'That delivery is not in this business.'; end if;
    if nullif(p->'delivery'->>'sale_id', '') is not null and not private.chat_owns(v_org, 'sale', (p->'delivery'->>'sale_id')::uuid) then raise exception 'That sale is not in this business.'; end if;
  elsif p_fn = 'create_transfer' then
    if not (private.chat_owns(v_org, 'item', nullif(p->>'item_id', '')::uuid) and private.chat_owns(v_org, 'location', nullif(p->>'from', '')::uuid)
            and private.chat_owns(v_org, 'location', nullif(p->>'to', '')::uuid)) then raise exception 'That product or branch is not in this business.'; end if;
  elsif p_fn = 'save_po' then
    if not private.chat_owns(v_org, 'vendor', nullif(p->>'vendor_id', '')::uuid) then raise exception 'That supplier is not in this business.'; end if;
    if nullif(p->>'location_id', '') is not null and not private.chat_owns(v_org, 'location', (p->>'location_id')::uuid) then raise exception 'That branch is not in this business.'; end if;
  elsif p_fn in ('save_customer', 'upsert_item') then
    -- New records only: changing an existing one is done in Counta.
    if nullif(coalesce(p->'customer'->>'id', p->'item'->>'id'), '') is not null then raise exception 'Martina adds new ones here; change existing ones in Counta.'; end if;
  end if;
  case p_fn
    when 'get_finance_overview' then r := public.get_finance_overview(v_org);
    when 'get_inventory' then r := public.get_inventory(v_org);
    when 'accounting_report' then
      r := public.accounting_report(v_org, p->>'report', nullif(p->>'from', '')::date, nullif(p->>'to', '')::date, coalesce(p->'options', '{}'::jsonb));
    when 'get_sales' then r := public.get_sales(v_org, coalesce(p->'filter', '{}'::jsonb));
    when 'get_customers' then r := public.get_customers(v_org);
    when 'get_banking' then r := public.get_banking(v_org);
    when 'get_payments' then r := public.get_payments(v_org);
    when 'get_bills' then r := public.get_bills(v_org);
    when 'vat_position' then r := public.vat_position(v_org);
    when 'withholding_overview' then r := public.withholding_overview(v_org);
    when 'cit_years' then r := public.cit_years(v_org);
    when 'get_books_inbox' then r := public.get_books_inbox(v_org);
    when 'compliance_score' then r := public.compliance_score(v_org);
    when 'get_team' then r := public.get_team(v_org);
    when 'record_quick_sale' then r := public.record_quick_sale(v_org, p->'sale');
    when 'save_sale_doc' then r := public.save_sale_doc(v_org, p->'doc');
    when 'send_document' then r := public.send_document(v_id, p->>'channel', p->>'to');
    when 'send_reminder' then r := public.send_reminder(v_id, p->>'channel');
    when 'send_statement' then r := public.send_statement(v_id, p->>'channel');
    when 'approve_bill' then r := public.approve_bill(v_id);
    -- The books inbox
    when 'get_chart' then r := public.get_chart(v_org);
    when 'resolve_proposal' then r := public.resolve_proposal(v_id, coalesce(p->'answer', '{}'::jsonb));
    when 'set_item_vat' then r := public.set_item_vat(v_id, p->>'treatment', p->>'reason');
    -- Orders and deliveries
    when 'get_sale' then r := public.get_sale(v_id);
    when 'get_deliveries' then r := public.get_deliveries(v_org, coalesce(nullif(p->>'days', '')::int, 30));
    when 'confirm_order' then r := public.confirm_order(v_id);
    when 'cancel_order' then r := public.cancel_order(v_id, p->>'reason');
    when 'save_delivery' then r := public.save_delivery(v_org, p->'delivery');
    -- Stock and purchasing
    when 'create_transfer' then
      r := to_jsonb(public.create_transfer(v_org, (p->>'item_id')::uuid, (p->>'from')::uuid, (p->>'to')::uuid, private.num(p->>'qty'),
        nullif(p->>'client_uuid', '')::uuid, 'whatsapp', false));
    when 'receive_transfer' then r := to_jsonb(public.receive_transfer(v_id));
    when 'approve_count' then r := to_jsonb(public.approve_count(v_id));
    when 'reject_count' then perform public.reject_count(v_id); r := jsonb_build_object('rejected', true);
    when 'save_po' then
      r := to_jsonb(public.save_po(v_org, (p->>'vendor_id')::uuid, coalesce(p->'lines', '[]'::jsonb), nullif(p->>'location_id', '')::uuid,
        coalesce((p->>'send')::boolean, false), nullif(p->>'sent_via', ''), null, nullif(p->>'note', '')));
    when 'send_po' then r := to_jsonb(public.send_po(v_id, p->>'sent_via', null));
    when 'get_price_proposals' then r := public.get_price_proposals(v_org);
    -- Stock on its way between branches, and counts waiting for approval (the app reads these tables directly).
    when 'stock_waiting' then
      perform private.require(v_org, null);
      r := jsonb_build_object(
        'transfers', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'ref', t.ref, 'item', i.name, 'qty', t.qty, 'unit', i.selling_unit,
            'from', (select name from locations where id = t.from_location_id), 'to', (select name from locations where id = t.to_location_id), 'sent_at', t.created_at)
            order by t.created_at), '[]'::jsonb)
          from transfers t join items i on i.id = t.item_id where t.org_id = v_org and t.status = 'in_transit'),
        'counts', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'ref', c.ref, 'area', c.area, 'location', (select name from locations where id = c.location_id),
            'submitted_at', c.submitted_at, 'counted_by', (select display_name from members where id = c.assignee_id)) order by c.submitted_at), '[]'::jsonb)
          from count_sessions c where c.org_id = v_org and c.status = 'awaiting_approval'));
    -- Customers, products, payment links and credit notes
    when 'save_customer' then r := to_jsonb(public.save_customer(v_org, p->'customer'));
    when 'upsert_item' then
      r := to_jsonb(public.upsert_item(v_org, p->'item'));
      -- The product photo they sent Martina becomes the new item's picture (saved by the chat function under the business).
      if coalesce(p->>'photo', '') ~ ('^' || v_org::text || '/wa-[0-9a-f-]{36}\.(jpg|png|webp)$') then
        update items set photo_path = p->>'photo' where id = (r #>> '{}')::uuid and org_id = v_org;
      end if;
    when 'sale_creditable' then r := public.sale_creditable(v_id);
    when 'credit_sale' then r := public.credit_sale(v_id, coalesce(p->'credit', '{}'::jsonb));
    -- Approvals
    when 'approvals_list' then r := public.approvals_list(v_org);
    when 'approval_decide' then r := public.approval_decide(v_id, (p->>'approve')::boolean, nullif(p->>'note', ''));
    when 'get_attention' then r := public.get_attention(v_org);
    -- Tax returns, and the files Flux receives (the tax-files function asks for these as the person)
    when 'file_vat_return' then r := public.file_vat_return(v_org, (p->>'period')::date, coalesce(p->'filing', '{}'::jsonb));
    when 'cit_year' then r := public.cit_year(v_org, (p->>'year')::int);
    when 'approve_cit_year' then r := to_jsonb(public.approve_cit_year(v_org, (p->>'year')::int));
    when 'get_flux_tax' then r := public.get_flux_tax(v_org);
    when 'vat_schedule' then r := public.vat_schedule(v_org, (p->>'period')::date);
    when 'wht_schedule' then r := public.wht_schedule(v_org, (p->>'period')::date, p->>'authority', p->>'kind');
    when 'filing_version_current' then r := public.filing_version_current(v_org, p->>'kind', p->>'period', nullif(p->>'authority', ''));
    when 'flux_return_pack' then r := public.flux_return_pack(v_org, p->>'tax', (p->>'period')::date, p->>'authority');
    when 'cit_pack' then r := public.cit_pack(v_org, (p->>'year')::int);
    else raise exception 'Martina cannot do that here.';
  end case;
  return r;
end $$;

-- ---------------------------------------------------------------------------
-- 4. The daily report
-- ---------------------------------------------------------------------------
-- A person's own choice for a business; without one, the owner and whoever keeps the books get it at 19:00.
create table if not exists public.daily_report_prefs (
  org_id uuid not null references public.orgs(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  enabled boolean not null,
  hour int not null default 19 check (hour between 6 and 22),
  email boolean not null default true,
  whatsapp boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key (org_id, user_id)
);
create index if not exists daily_report_prefs_user on public.daily_report_prefs(user_id);
alter table public.daily_report_prefs enable row level security;
revoke all on public.daily_report_prefs from anon, authenticated;

-- Each report made: the evening's (once a day) and any a person asked Martina for.
create table if not exists public.daily_reports (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  kind text not null default 'scheduled' check (kind in ('scheduled', 'asked')),
  status text not null default 'queued' check (status in ('queued', 'sending', 'sent', 'empty', 'failed')),
  channels text[] not null default '{}',
  path text,
  error text,
  attempts int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists daily_reports_once on public.daily_reports(org_id, user_id, day) where kind = 'scheduled';
create index if not exists daily_reports_user on public.daily_reports(user_id, created_at desc);
create index if not exists daily_reports_open on public.daily_reports(status, created_at) where status in ('queued', 'sending', 'failed');
alter table public.daily_reports enable row level security;
revoke all on public.daily_reports from anon, authenticated;

-- Who may have it, and when. A read-only business sends none; a business a firm runs sends only to the firm's own people,
-- and only to those who turned it on; a sample business only to those who turned it on.
create or replace function private.report_pref(o public.orgs, m public.members) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select case
    when o.read_only_at is not null or m.status <> 'active' then jsonb_build_object('enabled', false, 'hour', 19, 'email', true, 'whatsapp', true, 'explicit', false, 'allowed', false)
    when o.managed_by is not null and m.practice_id is distinct from o.managed_by then jsonb_build_object('enabled', false, 'hour', 19, 'email', true, 'whatsapp', true, 'explicit', false, 'allowed', false)
    when p.org_id is not null then jsonb_build_object('enabled', p.enabled, 'hour', p.hour, 'email', p.email, 'whatsapp', p.whatsapp, 'explicit', true, 'allowed', true)
    else jsonb_build_object('enabled', not o.is_sample and o.managed_by is null and (private.perm_of(m, 'keep_books')),
      'hour', 19, 'email', true, 'whatsapp', true, 'explicit', false, 'allowed', true) end
  from (select 1) x left join daily_report_prefs p on p.org_id = o.id and p.user_id = m.user_id
$$;

-- What the report covers for this person: each part only when their role sees it.
create or replace function private.report_parts(m public.members) returns text[]
language sql stable security definer set search_path = public, private as $$
  select array_remove(array[
    case when private.perm_of(m, 'record_sales') or private.perm_of(m, 'keep_books') then 'sales' end,
    case when private.perm_of(m, 'keep_books') or private.perm_of(m, 'see_margins') or private.perm_of(m, 'make_payments') then 'money' end,
    case when private.perm_of(m, 'record_sales') or private.perm_of(m, 'keep_books') then 'orders' end,
    case when private.perm_of(m, 'keep_books') or private.perm_of(m, 'receive_stock') or private.perm_of(m, 'count_stock')
      or private.perm_of(m, 'approve_adjustments') or private.perm_of(m, 'transfer_stock') then 'stock' end,
    case when private.perm_of(m, 'keep_books') then 'books' end,
    case when private.perm_of(m, 'keep_books') or private.perm_of(m, 'file_tax') then 'tax' end,
    -- Who did what comes from the activity log, which Counta keeps for a business a practice runs (and one gone read-only).
    case when (private.perm_of(m, 'manage_team') or private.perm_of(m, 'keep_books'))
      and exists (select 1 from orgs where id = m.org_id and (managed_by is not null or read_only_at is not null)) then 'people' end], null)
$$;

create or replace function public.get_daily_report_prefs(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs;
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  return private.report_pref(o, m) || jsonb_build_object('parts', to_jsonb(private.report_parts(m)), 'email_to', m.email,
    'whatsapp_linked', exists (select 1 from private.wa_number(auth.uid(), p_org)),
    'last', (select jsonb_build_object('day', r.day, 'status', r.status, 'channels', r.channels, 'at', r.updated_at, 'error', r.error)
      from daily_reports r where r.org_id = p_org and r.user_id = auth.uid() order by r.created_at desc limit 1));
end $$;

-- p: {enabled, hour, email, whatsapp}
create or replace function public.save_daily_report_prefs(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; v_hour int := coalesce(nullif(p->>'hour', '')::int, 19);
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  if not coalesce((private.report_pref(o, m)->>'allowed')::boolean, false) then raise exception 'Daily reports are not sent for this business.'; end if;
  if v_hour < 6 or v_hour > 22 then raise exception 'Choose a time between 6:00 and 22:00.'; end if;
  insert into daily_report_prefs (org_id, user_id, enabled, hour, email, whatsapp)
  values (p_org, auth.uid(), coalesce((p->>'enabled')::boolean, true), v_hour, coalesce((p->>'email')::boolean, true), coalesce((p->>'whatsapp')::boolean, true))
  on conflict (org_id, user_id) do update set enabled = excluded.enabled, hour = excluded.hour, email = excluded.email, whatsapp = excluded.whatsapp, updated_at = now();
  return public.get_daily_report_prefs(p_org);
end $$;

-- The day's figures for one person, each part only when their role sees it. Amounts in naira; empty when nothing happened.
create or replace function private.daily_report_data(p_org uuid, m public.members, p_day date) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; v_tz text; v_from timestamptz; v_to timestamptz; v_parts text[] := private.report_parts(m); r jsonb := '{}'::jsonb; x jsonb;
  v_busy boolean := false; v_n int; v_prev numeric;
begin
  select * into o from orgs where id = p_org;
  v_tz := coalesce(o.timezone, 'Africa/Lagos');
  v_from := (p_day::timestamp) at time zone v_tz;
  v_to := v_from + interval '1 day';
  if 'sales' = any(v_parts) then
    select jsonb_build_object('count', count(*), 'total', coalesce(sum(total), 0), 'vat', coalesce(sum(vat_total), 0),
        'receipts', count(*) filter (where doc_type = 'receipt'), 'invoices', count(*) filter (where doc_type = 'invoice'),
        'invoiced', coalesce(sum(total) filter (where doc_type = 'invoice'), 0))
      into x from sales where org_id = p_org and doc_type in ('receipt', 'invoice') and status not in ('draft', 'void', 'cancelled') and journal_id is not null
        and coalesce(issued_at, created_at) >= v_from and coalesce(issued_at, created_at) < v_to;
    select coalesce(sum(total), 0) into v_prev from sales where org_id = p_org and doc_type in ('receipt', 'invoice') and status not in ('draft', 'void', 'cancelled')
      and journal_id is not null and coalesce(issued_at, created_at) >= v_from - interval '1 day' and coalesce(issued_at, created_at) < v_from;
    x := x || jsonb_build_object('previous_day', v_prev,
      'top', (select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'qty', t.qty, 'value', t.value) order by t.value desc), '[]'::jsonb) from (
        select max(l.description) name, sum(l.qty) qty, sum(l.gross) value from sale_lines l join sales s on s.id = l.sale_id
        where s.org_id = p_org and s.doc_type in ('receipt', 'invoice') and s.status not in ('draft', 'void', 'cancelled') and s.journal_id is not null
          and coalesce(s.issued_at, s.created_at) >= v_from and coalesce(s.issued_at, s.created_at) < v_to and l.kind is distinct from 'delivery'
        group by coalesce(l.item_id::text, lower(l.description)) order by sum(l.gross) desc limit 5) t),
      'overdue', (select jsonb_build_object('count', count(*), 'owed', coalesce(sum(total - amount_paid - credited), 0)) from sales
        where org_id = p_org and doc_type = 'invoice' and status in ('open', 'partially_paid') and journal_id is not null and due_date < p_day),
      'paid_in_full', (select count(*) from sales where org_id = p_org and doc_type = 'invoice' and settled_on = p_day));
    r := r || jsonb_build_object('sales', x);
    v_busy := v_busy or (x->>'count')::int > 0;
  end if;
  if 'money' = any(v_parts) then
    x := jsonb_build_object(
      'in', (select coalesce(jsonb_object_agg(method, amt), '{}'::jsonb) from (select method, sum(amount) amt from collections
        where org_id = p_org and direction = 'in' and status = 'confirmed' and method not in ('wht_credit', 'wvat_credit', 'ncd_levy', 'advance')
          and coalesce(confirmed_at, received_at, created_at) >= v_from and coalesce(confirmed_at, received_at, created_at) < v_to group by method) q),
      'out_bills', (select coalesce(sum(net), 0) from bill_payments where org_id = p_org and status = 'paid' and method in ('wallet', 'bank', 'cash')
        and paid_at >= v_from and paid_at < v_to),
      'out_payouts', (select coalesce(sum(amount), 0) from payouts po where po.org_id = p_org and po.status = 'successful'
        and coalesce(po.completed_at, po.sent_at) >= v_from and coalesce(po.completed_at, po.sent_at) < v_to
        and not exists (select 1 from bill_payments bp where bp.payout_id = po.id)),
      'cash_and_bank', (select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code like '101%'),
      'payouts_waiting', (select count(*) from payouts where org_id = p_org and status = 'pending_approval'));
    x := x || jsonb_build_object('in_total', (select coalesce(sum(value::numeric), 0) from jsonb_each_text(x->'in')));
    r := r || jsonb_build_object('money', x);
    v_busy := v_busy or (x->>'in_total')::numeric > 0 or (x->>'out_bills')::numeric > 0 or (x->>'out_payouts')::numeric > 0;
  end if;
  if 'orders' = any(v_parts) then
    x := jsonb_build_object(
      'new', (select jsonb_build_object('count', count(*), 'total', coalesce(sum(total), 0)) from sales
        where org_id = p_org and doc_type = 'order' and status not in ('draft') and created_at >= v_from and created_at < v_to),
      'to_confirm', (select count(*) from sales where org_id = p_org and doc_type = 'order' and status = 'pending'),
      'dispatched', (select count(*) from deliveries where org_id = p_org and dispatched_at >= v_from and dispatched_at < v_to),
      'delivered', (select count(*) from deliveries where org_id = p_org and delivered_at >= v_from and delivered_at < v_to),
      'failed', (select count(*) from deliveries where org_id = p_org and status = 'failed' and created_at >= v_from - interval '7 days'),
      'waiting', (select count(*) from deliveries where org_id = p_org and status = 'pending'));
    r := r || jsonb_build_object('orders', x);
    v_busy := v_busy or ((x->'new'->>'count')::int + (x->>'dispatched')::int + (x->>'delivered')::int) > 0;
  end if;
  if 'stock' = any(v_parts) and exists (select 1 from items where org_id = p_org and not archived) then
    x := jsonb_build_object(
      'moves', (select coalesce(jsonb_object_agg(type, n), '{}'::jsonb) from (select type, count(*) n from movements
        where org_id = p_org and created_at >= v_from and created_at < v_to group by type) q),
      'received_value', case when 'money' = any(v_parts) then (select coalesce(sum(value), 0) from movements where org_id = p_org and type = 'receipt'
        and created_at >= v_from and created_at < v_to) end,
      'out', (select coalesce(jsonb_agg(name order by name), '[]'::jsonb) from (select i.name from items i
        where i.org_id = p_org and not i.archived and i.item_type in ('merchandise', 'finished_good')
          and coalesce((select sum(qty) from stock_levels sl where sl.item_id = i.id), 0) <= 0
          and exists (select 1 from movements mv where mv.item_id = i.id) order by i.name limit 8) q),
      'low', (select coalesce(jsonb_agg(name order by name), '[]'::jsonb) from (select i.name from items i
        where i.org_id = p_org and not i.archived and i.reorder_floor is not null
          and coalesce((select sum(qty) from stock_levels sl where sl.item_id = i.id), 0) > 0
          and coalesce((select sum(qty) from stock_levels sl where sl.item_id = i.id), 0) <= i.reorder_floor order by i.name limit 8) q),
      'counts_waiting', (select count(*) from count_sessions where org_id = p_org and status = 'awaiting_approval'),
      'transfers_waiting', (select count(*) from transfers where org_id = p_org and status = 'in_transit'));
    r := r || jsonb_build_object('stock', x);
    v_busy := v_busy or (select coalesce(sum(value::int), 0) from jsonb_each_text(x->'moves')) > 0;
  end if;
  if 'books' = any(v_parts) then
    r := r || jsonb_build_object('books', jsonb_build_object(
      'questions', (select count(*) from ai_proposals where org_id = p_org and status = 'pending'),
      'posted_by_atlas', (select count(*) from ai_proposals where org_id = p_org and status = 'auto_posted' and created_at >= v_from and created_at < v_to),
      'bills_to_approve', (select count(*) from bills where org_id = p_org and status = 'draft'),
      'approvals', case when private.perm_of(m, 'owner') or m.role = 'admin' then (select count(*) from approvals where org_id = p_org and status = 'pending' and approver <> 'director') end));
  end if;
  if 'tax' = any(v_parts) then
    r := r || jsonb_build_object('tax', (select coalesce(jsonb_agg(jsonb_build_object('label', d.label, 'period', d.period, 'due', d.due, 'amount', d.amount) order by d.due), '[]'::jsonb)
      from private.tax_deadlines(p_org) d where d.due between p_day - 30 and p_day + 30));
  end if;
  if 'people' = any(v_parts) then
    select jsonb_build_object('actions', count(*), 'by', coalesce((select jsonb_agg(jsonb_build_object('name', q.who, 'actions', q.n) order by q.n desc) from (
        select coalesce(nullif(actor_name, ''), 'Counta') who, count(*) n from activity_log where org_id = p_org and at >= v_from and at < v_to
        group by 1 order by 2 desc limit 8) q), '[]'::jsonb))
      into x from activity_log where org_id = p_org and at >= v_from and at < v_to;
    r := r || jsonb_build_object('people', x);
    v_busy := v_busy or (x->>'actions')::int > 0;
  end if;
  return jsonb_build_object('day', p_day, 'parts', to_jsonb(v_parts), 'empty', not v_busy) || r;
end $$;

-- Every hour: the evening reports due now (from each person's hour until three hours after, once a day).
create or replace function private.daily_report_tick() returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; m public.members; v_pref jsonb; v_local timestamp; v_day date; v_id uuid; v_n int := 0;
begin
  for o in select * from orgs where read_only_at is null loop
    v_local := now() at time zone coalesce(o.timezone, 'Africa/Lagos');
    v_day := v_local::date;
    for m in select * from members where org_id = o.id and status = 'active' and user_id is not null loop
      v_pref := private.report_pref(o, m);
      continue when not coalesce((v_pref->>'enabled')::boolean, false);
      continue when extract(hour from v_local) < (v_pref->>'hour')::int or extract(hour from v_local) >= (v_pref->>'hour')::int + 3;
      insert into daily_reports (org_id, user_id, day, kind) values (o.id, m.user_id, v_day, 'scheduled')
      on conflict (org_id, user_id, day) where kind = 'scheduled' do nothing returning id into v_id;
      continue when v_id is null;
      perform private.call_function('messaging', jsonb_build_object('action', 'daily_report', 'id', v_id));
      v_n := v_n + 1;
      exit when v_n >= 500;
    end loop;
  end loop;
  -- One the messaging function did not finish is tried again, twice.
  for v_id in select id from daily_reports where status in ('queued', 'sending', 'failed') and attempts < 3 and created_at > now() - interval '6 hours'
      and updated_at < now() - interval '20 minutes' limit 50 loop
    perform private.call_function('messaging', jsonb_build_object('action', 'daily_report', 'id', v_id));
  end loop;
  delete from daily_reports where created_at < now() - interval '120 days';
  return jsonb_build_object('queued', v_n);
end $$;

-- Martina, when someone asks for a report: one for the link's business and person. Ten a day.
create or replace function public.svc_daily_report_ask(p_link uuid, p_day date) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare l public.chat_links; o public.orgs; m public.members; v_day date; v_id uuid;
begin
  select * into l from chat_links where id = p_link and status = 'active';
  if not found then raise exception 'This link is not active any more.'; end if;
  select * into o from orgs where id = l.org_id;
  select * into m from members where org_id = l.org_id and user_id = l.user_id and status = 'active';
  if not found then raise exception 'You are no longer on this business''s team.'; end if;
  if not coalesce((private.report_pref(o, m)->>'allowed')::boolean, false) then raise exception 'Daily reports are not sent for this business.'; end if;
  v_day := least(coalesce(p_day, private.local_day(o.id, now())), private.local_day(o.id, now()));
  if v_day < private.local_day(o.id, now()) - 92 then raise exception 'Ask for a day in the last three months.'; end if;
  if (select count(*) from daily_reports where user_id = l.user_id and kind = 'asked' and created_at > now() - interval '1 day') >= 10 then
    raise exception 'That is ten reports today already. The evening report comes as usual.';
  end if;
  insert into daily_reports (org_id, user_id, day, kind) values (o.id, l.user_id, v_day, 'asked') returning id into v_id;
  return v_id;
end $$;

-- The messaging function: the report to make and where it goes. Null when it is done or gone.
create or replace function public.svc_daily_report(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.daily_reports; o public.orgs; m public.members; v_pref jsonb; w record;
begin
  update daily_reports set status = 'sending', attempts = attempts + 1, updated_at = now()
  where id = p_id and status in ('queued', 'sending', 'failed') and attempts < 4 returning * into d;
  if not found then return null; end if;
  select * into o from orgs where id = d.org_id;
  select * into m from members where org_id = d.org_id and user_id = d.user_id and status = 'active';
  if not found or o.read_only_at is not null then
    update daily_reports set status = 'failed', error = 'No longer on the team, or the business is closed.' where id = p_id;
    return null;
  end if;
  v_pref := private.report_pref(o, m);
  select * into w from private.wa_number(d.user_id, d.org_id);
  return jsonb_build_object('id', d.id, 'kind', d.kind, 'day', d.day, 'org_id', o.id,
    'business', jsonb_build_object('name', o.name, 'brand_color', o.brand_color, 'logo_path', o.logo_path, 'white_label', private.white_label(o.id),
      'timezone', coalesce(o.timezone, 'Africa/Lagos')),
    'person', jsonb_build_object('name', m.display_name, 'email', case when d.kind = 'scheduled' and (v_pref->>'email')::boolean then nullif(trim(m.email), '') end,
      'whatsapp', case when d.kind = 'asked' or (v_pref->>'whatsapp')::boolean then w.phone end, 'link_id', w.link_id),
    'channels', jsonb_build_object('email', not o.is_sample and private.feature_on(o.id, 'email'), 'whatsapp', private.feature_on(o.id, 'whatsapp')),
    'app_url', coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app'),
    'data', private.daily_report_data(o.id, m, d.day));
end $$;

-- p: {status: 'sent' | 'empty' | 'failed', channels[], path, error}
create or replace function public.svc_daily_report_done(p_id uuid, p jsonb) returns void
language sql security definer set search_path = public, private as $$
  update daily_reports set status = coalesce(p->>'status', status),
    channels = coalesce((select array_agg(x) from jsonb_array_elements_text(p->'channels') x), channels),
    path = coalesce(p->>'path', path), error = left(p->>'error', 300), updated_at = now()
  where id = p_id
$$;

-- ---------------------------------------------------------------------------
-- 5. Customers talk to Martina
-- ---------------------------------------------------------------------------
-- on: Martina answers customers who write back to TaxStreem's number; own_number: also on the business's own linked number
-- (off unless the business turns it on, since people may chat with customers on that phone themselves).
alter table public.orgs add column if not exists customer_chat jsonb not null default '{"on": true, "own_number": false}'::jsonb;

create table if not exists public.customer_chats (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete set null,
  phone text not null check (phone ~ '^[0-9]{8,15}$'),
  name text check (name is null or length(name) <= 120),
  via text not null default 'counta' check (via in ('counta', 'own')),
  session_id text,
  status text not null default 'open' check (status in ('open', 'needs_reply', 'closed')),
  martina_paused_until timestamptz,
  pending jsonb,
  last_at timestamptz not null default now(),
  last_text text,
  unread int not null default 0,
  handed_at timestamptz,
  handed_reason text,
  created_at timestamptz not null default now()
);
create unique index if not exists customer_chats_one on public.customer_chats(org_id, phone, via);
create index if not exists customer_chats_phone on public.customer_chats(phone, last_at desc);
create index if not exists customer_chats_org on public.customer_chats(org_id, last_at desc);
create index if not exists customer_chats_customer on public.customer_chats(customer_id);
alter table public.customer_chats enable row level security;
revoke all on public.customer_chats from anon, authenticated;

create table if not exists public.customer_chat_turns (
  id bigint generated always as identity primary key,
  chat_id uuid not null references public.customer_chats(id) on delete cascade,
  role text not null check (role in ('customer', 'martina', 'team')),
  text text not null,
  member_id uuid references public.members(id) on delete set null,
  media_path text,
  meta jsonb not null default '{}'::jsonb,
  at timestamptz not null default now()
);
create index if not exists customer_chat_turns_chat on public.customer_chat_turns(chat_id, at desc);
create index if not exists customer_chat_turns_member on public.customer_chat_turns(member_id);
alter table public.customer_chat_turns enable row level security;
revoke all on public.customer_chat_turns from anon, authenticated;

-- WhatsApp messages to a number, found by the number as WhatsApp writes it.
create index if not exists messages_wa_to on public.messages (private.wa_phone(to_address), created_at desc) where channel = 'whatsapp';

-- A reply the team types to a customer on WhatsApp.
alter table public.messages drop constraint if exists messages_template_check;
alter table public.messages add constraint messages_template_check check (template in ('document', 'reminder', 'receipt', 'statement', 'order', 'custom',
  'bill_returned', 'invite', 'alert', 'invoice_issues', 'chat'));

-- The customer records a chat speaks for: the one it was opened with and any other in the business with the same number.
create or replace function private.chat_customers(c public.customer_chats) returns uuid[]
language sql stable security definer set search_path = public, private as $$
  select array(select x from (select c.customer_id x where c.customer_id is not null
    union select id from customers where org_id = c.org_id and not archived and not is_walk_in and private.wa_phone(phone) = c.phone) q)
$$;

-- What Martina starts from when a customer writes.
create or replace function private.customer_chat_ctx(c public.customer_chats) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('chat_id', c.id, 'org_id', o.id, 'business', o.name, 'phone', c.phone, 'via', c.via,
    'customer_id', cu.id, 'customer_name', coalesce(cu.name, c.name), 'first_name', split_part(coalesce(nullif(trim(cu.name), ''), nullif(trim(c.name), ''), 'there'), ' ', 1),
    'paused', coalesce(c.martina_paused_until > now(), false), 'status', c.status, 'pending', c.pending, 'white_label', private.white_label(o.id),
    'language', o.voice_lang, 'offering', o.offering, 'category', (select label from business_categories where id = o.category_id),
    'contact', jsonb_strip_nulls(jsonb_build_object('phone', o.phone, 'email', coalesce(o.reply_to_email, o.email), 'address', o.address, 'website', o.website)),
    'shop', jsonb_build_object('on', coalesce(o.shop_enabled, false) and o.shop_slug is not null, 'delivery', o.shop_delivery, 'pickup', o.shop_pickup,
      'pay_on_delivery', o.shop_pay_on_delivery, 'delivery_fee', o.shop_delivery_fee,
      'link', case when o.shop_enabled and o.shop_slug is not null then coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app') || '/shop/' || o.shop_slug end),
    'others', (select coalesce(jsonb_agg(jsonb_build_object('org_id', z.org_id, 'name', z.name)), '[]'::jsonb) from (
        select distinct m.org_id, xo.name from messages m join orgs xo on xo.id = m.org_id
        where c.via = 'counta' and m.channel = 'whatsapp' and private.wa_phone(m.to_address) = c.phone and m.org_id <> c.org_id
          and m.template in ('document', 'receipt', 'order', 'reminder', 'statement', 'chat') and m.created_at > now() - interval '45 days'
          and coalesce((xo.customer_chat->>'on')::boolean, true) and xo.read_only_at is null and not xo.is_sample limit 5) z),
    'app_url', coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app'))
  from orgs o left join customers cu on cu.id = c.customer_id
  where o.id = c.org_id
$$;

-- The chat function, when someone with no Martina link writes to a WhatsApp number Counta runs. On TaxStreem's number: the
-- business that sent that number an invoice, receipt, order, reminder or statement most recently (a thread still going
-- wins). On a business's own number: that business, when it turned customer chats on for it. Null when there is none.
create or replace function public.svc_customer_chat_find(p_phone text, p_session text, p_name text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_phone text := private.wa_phone(p_phone); s public.whatsapp_sessions; o public.orgs; c public.customer_chats; v_org uuid; v_cust uuid; v_via text; msg record;
begin
  if v_phone is null then return null; end if;
  select * into s from whatsapp_sessions where id = p_session;
  if not found then return null; end if;
  if s.kind = 'business' then
    v_org := s.org_id; v_via := 'own';
    select * into o from orgs where id = v_org;
    if not found or not coalesce((o.customer_chat->>'own_number')::boolean, false) then return null; end if;
  else
    v_via := 'counta';
    select * into c from customer_chats where phone = v_phone and via = 'counta' and last_at > now() - interval '14 days' order by last_at desc limit 1;
    if found then
      v_org := c.org_id;
    else
      select m.org_id, m.customer_id into msg from messages m
      where m.channel = 'whatsapp' and private.wa_phone(m.to_address) = v_phone and m.template in ('document', 'receipt', 'order', 'reminder', 'statement', 'chat')
        and m.status in ('sent', 'delivered', 'read') and m.created_at > now() - interval '45 days'
      order by m.created_at desc limit 1;
      if msg.org_id is null then return null; end if;
      v_org := msg.org_id; v_cust := msg.customer_id;
    end if;
    select * into o from orgs where id = v_org;
  end if;
  if o.id is null or not coalesce((o.customer_chat->>'on')::boolean, true) or o.read_only_at is not null or o.is_sample then return null; end if;
  if v_cust is null then
    select id into v_cust from customers where org_id = v_org and not archived and not is_walk_in and private.wa_phone(phone) = v_phone order by created_at limit 1;
  end if;
  insert into customer_chats (org_id, phone, via, session_id, customer_id, name)
  values (v_org, v_phone, v_via, p_session, v_cust, nullif(left(trim(coalesce(p_name, '')), 120), ''))
  on conflict (org_id, phone, via) do update set session_id = excluded.session_id, customer_id = coalesce(customer_chats.customer_id, excluded.customer_id),
    name = coalesce(customer_chats.name, excluded.name)
  returning * into c;
  return private.customer_chat_ctx(c);
end $$;

-- A customer of two businesses on TaxStreem's number moves the chat to the other one (one that wrote to them lately).
create or replace function public.svc_customer_chat_switch(p_chat uuid, p_org uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.customer_chats; n public.customer_chats;
begin
  select * into c from customer_chats where id = p_chat;
  if not found or c.via <> 'counta' then raise exception 'This chat cannot move.'; end if;
  if not exists (select 1 from messages m join orgs o on o.id = m.org_id where m.org_id = p_org and m.channel = 'whatsapp' and private.wa_phone(m.to_address) = c.phone
      and m.template in ('document', 'receipt', 'order', 'reminder', 'statement', 'chat') and m.created_at > now() - interval '45 days'
      and coalesce((o.customer_chat->>'on')::boolean, true) and o.read_only_at is null and not o.is_sample) then
    raise exception 'That business has not written to this number lately.';
  end if;
  insert into customer_chats (org_id, phone, via, session_id, name,
    customer_id) values (p_org, c.phone, 'counta', c.session_id, c.name,
    (select id from customers where org_id = p_org and not archived and not is_walk_in and private.wa_phone(phone) = c.phone order by created_at limit 1))
  on conflict (org_id, phone, via) do update set last_at = now() returning * into n;
  update customer_chats set pending = null where id = c.id;
  return private.customer_chat_ctx(n);
end $$;

-- Records a turn of a customer chat. Returns how many messages the customer sent in the past hour.
create or replace function public.svc_customer_chat_log(p_chat uuid, p_role text, p_text text, p_media text default null, p_meta jsonb default '{}'::jsonb) returns int
language plpgsql security definer set search_path = public, private as $$
begin
  insert into customer_chat_turns (chat_id, role, text, media_path, meta)
  values (p_chat, p_role, left(coalesce(nullif(p_text, ''), case when p_media is not null then '(a picture)' else '' end), 4000), p_media, coalesce(p_meta, '{}'::jsonb));
  update customer_chats set last_at = now(), last_text = left(coalesce(nullif(p_text, ''), '(a picture)'), 300),
    unread = unread + case when p_role = 'customer' then 1 else 0 end,
    status = case when p_role = 'customer' and status = 'closed' then 'open' else status end
  where id = p_chat;
  if random() < 0.02 then delete from customer_chat_turns where at < now() - interval '180 days'; end if;
  return (select count(*) from customer_chat_turns where chat_id = p_chat and role = 'customer' and at > now() - interval '1 hour');
end $$;

-- The conversation so far: the last sixteen turns of the past two days.
create or replace function public.svc_customer_chat_history(p_chat uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('role', t.role, 'text', t.text, 'at', t.at) order by t.at), '[]'::jsonb)
  from (select * from customer_chat_turns where chat_id = p_chat and at > now() - interval '2 days' order by at desc limit 16) t
$$;

-- p: {action, read_back, payload} or null. What waits for the customer's yes (ten minutes).
create or replace function public.svc_customer_chat_pending(p_chat uuid, p jsonb) returns jsonb
language sql security definer set search_path = public as $$
  update customer_chats set pending = case when p is null then null else p || jsonb_build_object('at', now()) end where id = p_chat returning pending
$$;

-- What a customer may see of their own dealings with the business, and of its shop. Nothing about anyone else.
-- p_what: documents ({unpaid}) | products ({q}) | business
create or replace function public.svc_customer_view(p_chat uuid, p_what text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare c public.customer_chats; o public.orgs; v_ids uuid[];
begin
  select * into c from customer_chats where id = p_chat;
  if not found then raise exception 'Chat not found.'; end if;
  select * into o from orgs where id = c.org_id;
  v_ids := private.chat_customers(c);
  p := coalesce(p, '{}'::jsonb);
  if p_what = 'documents' then
    return jsonb_build_object('customer_known', cardinality(v_ids) > 0, 'documents', (select coalesce(jsonb_agg(jsonb_build_object(
        'number', s.number, 'kind', s.doc_type, 'date', s.issue_date, 'due', s.due_date, 'total', s.total, 'owed', round(s.total - s.amount_paid - s.credited, 2),
        'status', s.status, 'link', private.doc_link(s.public_token),
        'delivery', (select jsonb_build_object('number', d.number, 'status', d.status, 'scheduled_for', d.scheduled_for, 'dispatched_at', d.dispatched_at,
            'delivered_at', d.delivered_at, 'waiting_for_payment', o.release_after_payment and d.status = 'pending' and not d.collect_on_delivery
              and (s.total - s.amount_paid - s.credited > 0.004))
          from deliveries d where d.sale_id = s.id order by d.created_at desc limit 1)) order by s.created_at desc), '[]'::jsonb)
      from (select * from sales where org_id = c.org_id and customer_id = any(v_ids) and doc_type in ('invoice', 'order', 'receipt', 'quote', 'credit_note')
              and status not in ('draft', 'void') and created_at > now() - interval '18 months'
              and (not coalesce((p->>'unpaid')::boolean, false) or (doc_type in ('invoice', 'order') and total - amount_paid - credited > 0.004 and status not in ('cancelled', 'expired')))
            order by created_at desc limit 10) s),
      'owed', (select coalesce(round(sum(total - amount_paid - credited), 2), 0) from sales where org_id = c.org_id and customer_id = any(v_ids)
        and doc_type in ('invoice', 'order') and status in ('open', 'partially_paid', 'pending') and journal_id is not null));
  elsif p_what = 'products' then
    if not (coalesce(o.shop_enabled, false) and o.shop_slug is not null) then return jsonb_build_object('shop', false); end if;
    return jsonb_build_object('shop', true, 'products', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'price', i.price, 'unit', i.selling_unit,
        'in_stock', coalesce((select sum(qty) from stock_levels sl where sl.item_id = i.id and (o.shop_location_id is null or sl.location_id = o.shop_location_id)), 0) > 0)
        order by i.name), '[]'::jsonb)
      from (select * from items i0 where i0.org_id = c.org_id and not i0.archived and i0.price > 0 and i0.item_type in ('merchandise', 'finished_good')
              and (o.shop_categories is null or i0.category = any(o.shop_categories))
              and (coalesce(trim(p->>'q'), '') = '' or i0.name ilike '%' || trim(p->>'q') || '%' or coalesce(i0.brand, '') ilike '%' || trim(p->>'q') || '%')
            order by i0.name limit case when coalesce((p->>'all')::boolean, false) then 300 else 15 end) i));
  elsif p_what = 'business' then
    return (private.customer_chat_ctx(c))->'contact' || jsonb_build_object('name', o.name, 'shop', (private.customer_chat_ctx(c))->'shop');
  end if;
  raise exception 'Unknown view.';
end $$;

-- A customer's word on WhatsApp that they paid. With a payment request waiting on the document, the chat function passes it
-- to the payments function as if they said it on the document's page (Counta then looks for the money at once). Otherwise
-- the people who keep the books are asked to check the bank. Nothing is settled on the customer's word.
-- p: {number, amount, name, proof_path}
create or replace function public.svc_customer_claim(p_chat uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.customer_chats; v_ids uuid[]; s public.sales; v_n int; v_amt numeric := round(private.num(p->>'amount'), 2); v_who text; v_title text; v_q text;
  v_name text := nullif(left(regexp_replace(trim(coalesce(p->>'name', '')), '\s+', ' ', 'g'), 80), '');
begin
  select * into c from customer_chats where id = p_chat;
  if not found then raise exception 'Chat not found.'; end if;
  v_ids := private.chat_customers(c);
  select count(*) into v_n from sales where org_id = c.org_id and customer_id = any(v_ids) and doc_type in ('invoice', 'order', 'receipt')
    and status not in ('draft', 'void', 'cancelled', 'expired') and total - amount_paid - credited > 0.004;
  if nullif(trim(p->>'number'), '') is not null then
    select * into s from sales where org_id = c.org_id and customer_id = any(v_ids) and lower(number) = lower(trim(p->>'number'))
      and status not in ('draft', 'void', 'cancelled', 'expired') and total - amount_paid - credited > 0.004;
  elsif v_n = 1 then
    select * into s from sales where org_id = c.org_id and customer_id = any(v_ids) and doc_type in ('invoice', 'order', 'receipt')
      and status not in ('draft', 'void', 'cancelled', 'expired') and total - amount_paid - credited > 0.004;
  end if;
  if s.id is null then
    return jsonb_build_object('ok', false, 'reason', case when v_n = 0 then 'nothing_owed' else 'which' end,
      'numbers', (select coalesce(jsonb_agg(number order by created_at desc), '[]'::jsonb) from (select number, created_at from sales where org_id = c.org_id
        and customer_id = any(v_ids) and doc_type in ('invoice', 'order', 'receipt') and status not in ('draft', 'void', 'cancelled', 'expired')
        and total - amount_paid - credited > 0.004 order by created_at desc limit 6) z));
  end if;
  if v_amt is null or v_amt <= 0 then return jsonb_build_object('ok', false, 'reason', 'amount', 'number', s.number, 'owed', round(s.total - s.amount_paid - s.credited, 2)); end if;
  if exists (select 1 from payment_requests where sale_id = s.id and status = 'pending') then
    return jsonb_build_object('ok', true, 'mode', 'request', 'token', s.public_token, 'number', s.number);
  end if;
  v_who := coalesce(nullif(s.customer_name, ''), c.name, 'A customer');
  v_title := v_who || ' says they paid ' || s.number;
  v_q := v_who || ' said on WhatsApp that they sent ' || private.naira(v_amt) || coalesce(' from an account named ' || v_name, '') || ' for ' || s.number
    || '. Check the bank, then record the payment on ' || s.number || ' when you see it.';
  insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount)
  values (c.org_id, 'bookkeeper', 'payment_claim', 'customer_chat', s.id, left(v_title, 200), v_q,
    jsonb_build_object('sale_id', s.id, 'number', s.number, 'amount', v_amt, 'name', v_name, 'chat_id', c.id, 'proof_path', nullif(p->>'proof_path', '')),
    0.5, 'The customer''s word on WhatsApp; nothing matched in the books yet', 'claim', 'pending', v_amt)
  on conflict do nothing;
  perform private.notify_perm(c.org_id, 'keep_books', 'payment', v_title, v_q, '/sell/chats?open=' || c.id, 'cclaim-' || s.id);
  return jsonb_build_object('ok', true, 'mode', 'asked', 'number', s.number);
end $$;

-- A claim from a chat closes itself once the document is paid.
create or replace function private.close_chat_claims() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.status = 'paid' and old.status is distinct from 'paid' then
    update ai_proposals set status = 'superseded', decided_at = now(), decision = jsonb_build_object('reason', 'The document was paid.')
    where org_id = new.org_id and kind = 'payment_claim' and source_type = 'customer_chat' and source_id = new.id and status = 'pending';
  end if;
  return null;
end $$;
drop trigger if exists sales_close_chat_claims on public.sales;
create trigger sales_close_chat_claims after update of status on public.sales for each row execute function private.close_chat_claims();

-- The customer wants a person (a complaint, a return, a price, anything Martina does not handle): the chat waits for the
-- team, and everyone who records sales hears at once, by push and WhatsApp.
create or replace function public.svc_customer_handoff(p_chat uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.customer_chats; v_who text;
begin
  update customer_chats set status = 'needs_reply', handed_at = now(), handed_reason = left(coalesce(nullif(trim(p_reason), ''), last_text), 300)
  where id = p_chat returning * into c;
  if not found then raise exception 'Chat not found.'; end if;
  v_who := coalesce((select name from customers where id = c.customer_id), c.name, '+' || c.phone);
  perform private.notify_perm(c.org_id, 'record_sales', 'customer_chat', left(v_who || ' on WhatsApp needs a reply', 120), c.handed_reason,
    '/sell/chats?open=' || c.id, 'cchat-' || c.id);
  return jsonb_build_object('ok', true);
end $$;

-- An order from the business's online shop, placed for the customer by Martina after they said yes. p: as shop_place_order's
-- p_order without the customer: {lines, delivery_method, address, city, state, note, payment, client_uuid}
create or replace function public.svc_customer_order(p_chat uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.customer_chats; o public.orgs; cu public.customers; r jsonb;
begin
  select * into c from customer_chats where id = p_chat;
  if not found then raise exception 'Chat not found.'; end if;
  select * into o from orgs where id = c.org_id;
  if not (coalesce(o.shop_enabled, false) and o.shop_slug is not null) then raise exception '% does not take orders here yet. The team will help you.', o.name; end if;
  select * into cu from customers where id = c.customer_id;
  r := public.shop_place_order(o.shop_slug, coalesce(p, '{}'::jsonb) || jsonb_build_object(
    'customer', jsonb_strip_nulls(jsonb_build_object('name', coalesce(cu.name, c.name, 'WhatsApp customer'), 'phone', '+' || c.phone, 'email', cu.email)),
    'note', left(trim('Ordered on WhatsApp with Martina. ' || coalesce(p->>'note', '')), 500)));
  update customer_chats set customer_id = coalesce(customer_id, (select customer_id from sales where org_id = c.org_id and public_token = r->>'token')) where id = c.id;
  return r || jsonb_build_object('link', private.doc_link(r->>'token'));
end $$;

-- ---- The team's side (Sell, Customer chats)
create or replace function public.get_customer_chats(p_org uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs;
begin
  m := private.require(p_org, 'record_sales');
  select * into o from orgs where id = p_org;
  return jsonb_build_object(
    'chats', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'customer_id', c.customer_id, 'name', coalesce(cu.name, c.name), 'phone', '+' || c.phone,
        'via', c.via, 'status', c.status, 'last_at', c.last_at, 'last_text', c.last_text, 'unread', c.unread, 'paused', coalesce(c.martina_paused_until > now(), false),
        'handed_reason', case when c.status = 'needs_reply' then c.handed_reason end) order by (c.status = 'needs_reply') desc, c.last_at desc), '[]'::jsonb)
      from (select * from customer_chats where org_id = p_org and (coalesce(p->>'status', '') = '' or status = p->>'status') order by last_at desc limit 200) c
      left join customers cu on cu.id = c.customer_id),
    'settings', jsonb_build_object('on', coalesce((o.customer_chat->>'on')::boolean, true), 'own_number', coalesce((o.customer_chat->>'own_number')::boolean, false),
      'own_linked', exists (select 1 from whatsapp_sessions where kind = 'business' and org_id = p_org and status = 'ready')),
    'can_change', private.perm_of(m, 'manage_settings'));
end $$;

create or replace function public.get_customer_chat(p_chat uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.customer_chats; m public.members;
begin
  select * into c from customer_chats where id = p_chat;
  if not found then raise exception 'Chat not found.'; end if;
  m := private.require(c.org_id, 'record_sales');
  update customer_chats set unread = 0 where id = p_chat;
  return jsonb_build_object('chat', jsonb_build_object('id', c.id, 'customer_id', c.customer_id, 'name', coalesce((select name from customers where id = c.customer_id), c.name),
      'phone', '+' || c.phone, 'via', c.via, 'status', c.status, 'paused_until', case when c.martina_paused_until > now() then c.martina_paused_until end,
      'handed_reason', c.handed_reason, 'last_at', c.last_at),
    'turns', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'role', t.role, 'text', t.text, 'at', t.at, 'media_path', t.media_path,
        'by', (select display_name from members where id = t.member_id)) order by t.at), '[]'::jsonb)
      from (select * from customer_chat_turns where chat_id = p_chat order by at desc limit 200) t));
end $$;

-- The team answers a customer on WhatsApp. Martina stays quiet in that chat for twelve hours, so the two do not talk over
-- each other; the team can hand it back sooner.
create or replace function public.customer_chat_reply(p_chat uuid, p_text text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.customer_chats; m public.members; o public.orgs; v_text text := trim(coalesce(p_text, '')); msg public.messages;
begin
  select * into c from customer_chats where id = p_chat;
  if not found then raise exception 'Chat not found.'; end if;
  m := private.require(c.org_id, 'record_sales');
  select * into o from orgs where id = c.org_id;
  if v_text = '' then raise exception 'Write the reply.'; end if;
  if length(v_text) > 2000 then raise exception 'Keep the reply under 2,000 characters.'; end if;
  msg := private.queue_message(c.org_id, 'whatsapp', '+' || c.phone, 'chat', null,
    jsonb_build_object('text', v_text, 'via', c.via, 'chat_id', c.id, 'business', o.name, 'customer_name', coalesce((select name from customers where id = c.customer_id), c.name)),
    null, c.customer_id, m.id);
  insert into customer_chat_turns (chat_id, role, text, member_id, meta) values (c.id, 'team', v_text, m.id, jsonb_build_object('message_id', msg.id));
  update customer_chats set martina_paused_until = now() + interval '12 hours', status = 'open', unread = 0, pending = null, last_at = now(), last_text = left(v_text, 300)
  where id = c.id;
  return jsonb_build_object('ok', true, 'message_id', msg.id, 'status', msg.status, 'error', msg.error);
end $$;

-- p: {status: 'open' | 'closed', martina: 'resume' | 'pause'}
create or replace function public.customer_chat_set(p_chat uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.customer_chats; m public.members;
begin
  select * into c from customer_chats where id = p_chat;
  if not found then raise exception 'Chat not found.'; end if;
  m := private.require(c.org_id, 'record_sales');
  update customer_chats set
    status = case when p->>'status' in ('open', 'closed') then p->>'status' else status end,
    martina_paused_until = case p->>'martina' when 'resume' then null when 'pause' then now() + interval '7 days' else martina_paused_until end
  where id = p_chat;
  return public.get_customer_chat(p_chat);
end $$;

-- p: {on, own_number}
create or replace function public.save_customer_chat_settings(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'manage_settings')) then raise exception 'Only the owner or someone who changes settings can change this.' using errcode = '42501'; end if;
  select * into o from orgs where id = p_org;
  update orgs set customer_chat = jsonb_build_object('on', coalesce((p->>'on')::boolean, (o.customer_chat->>'on')::boolean, true),
    'own_number', coalesce((p->>'own_number')::boolean, (o.customer_chat->>'own_number')::boolean, false)) where id = p_org;
  return public.get_customer_chats(p_org, '{"status": "none"}'::jsonb) - 'chats';
end $$;


-- ---------------------------------------------------------------------------
-- 6. The counts beside the menu: customers waiting for a reply on WhatsApp (Sell, Customer chats)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_attention(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; o public.orgs; v_today date; v_books boolean; v_pay boolean; v_sales boolean; v_tax boolean; v_vat int := 0; v_wht int := 0; v_cit int := 0;
  r record;
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  v_today := private.local_day(p_org, now());
  v_books := private.perm_of(m, 'keep_books');
  v_pay := private.perm_of(m, 'make_payments');
  v_sales := private.perm_of(m, 'record_sales') or v_books;
  v_tax := v_books or private.perm_of(m, 'file_tax');
  if v_tax then
    for r in select * from private.tax_deadlines(p_org) where due <= v_today + 7 loop
      if r.tax = 'vat' then v_vat := v_vat + 1; elsif r.tax in ('cit', 'pit') then v_cit := v_cit + 1; else v_wht := v_wht + 1; end if;
    end loop;
    v_cit := case when exists (select 1 from private.tax_deadlines(p_org) t where t.tax in ('cit', 'pit') and t.due <= v_today + 30) then 1 else 0 end;
  end if;
  return jsonb_build_object(
    'invoices_overdue', case when v_sales then (select count(*) from sales where org_id = p_org and doc_type = 'invoice' and status in ('open', 'partially_paid')
      and journal_id is not null and due_date < v_today) else 0 end,
    'orders_to_confirm', case when v_sales then (select count(*) from sales where org_id = p_org and doc_type = 'order' and status = 'pending') else 0 end,
    -- Customers on WhatsApp waiting for a person.
    'customer_chats', case when v_sales then (select count(*) from customer_chats where org_id = p_org and status = 'needs_reply') else 0 end,
    'payments_to_confirm', case when v_books or private.perm_of(m, 'approve_adjustments') then (select count(*) from collections where org_id = p_org and status = 'pending') else 0 end,
    'bills_overdue', case when v_books or v_pay then (select count(*) from bills where org_id = p_org and status in ('approved', 'partially_paid') and due_date < v_today) else 0 end,
    'bank_lines', case when v_books then (select count(*) from bank_lines where org_id = p_org and status = 'unmatched') else 0 end,
    'proposals', case when v_books then (select count(*) from ai_proposals where org_id = p_org and status = 'pending') else 0 end,
    'schedules_draft', case when v_tax then (select count(*) from sales_schedules where org_id = p_org and status = 'draft') else 0 end,
    'vat', v_vat, 'wht', v_wht, 'cit', v_cit,
    'tax_wallet', case when v_pay or v_books then
      (case when exists (select 1 from wallets where org_id = p_org and status = 'active') and not exists (select 1 from tax_wallets where org_id = p_org and status = 'active') then 1 else 0 end)
      + (select count(*) from tax_payments where org_id = p_org and status = 'failed' and created_at > now() - interval '7 days')
      + (select count(*) from tax_payment_instructions where org_id = p_org
         and (status in ('needs_approval', 'expired') or (status = 'confirmed' and journal_id is null and payment_id is null))) else 0 end,
    'tax_id', case when private.perm_of(m, 'owner') or private.perm_of(m, 'manage_settings') then
      case when coalesce(o.tin, '') = '' or coalesce(o.tin_status, '') not in ('verified', 'confirmed') then 1 else 0 end else 0 end,
    'accountant_requests', case when m.practice_id is null and (m.role in ('owner', 'admin') or m.acts_as_owner) then
      (select count(*) from practice_requests pr join practice_clients pc on pc.id = pr.client_id
       where pr.org_id = p_org and pr.status = 'open' and pc.status = 'active') else 0 end,
    -- What waits for this person's approval, and what they asked for that waits.
    'approvals', case when m.role in ('owner', 'admin') then (select count(*) from approvals a where a.org_id = p_org and a.status = 'pending'
      and a.approver = 'owner' and a.requested_by is distinct from m.id and (m.practice_id is null or not ('firm' = any(a.reasons)))) else 0 end,
    'approvals_mine', (select count(*) from approvals where org_id = p_org and status = 'pending' and requested_by = m.id),
    -- Payments taken as sales whose VAT a person should check: once the AI has looked (or could not), not while it is about to.
    'receipts_vat', case when v_tax then (select count(*) from sales where org_id = p_org and channel = 'bank' and doc_type = 'receipt' and status <> 'void'
      and vat_check and (vat_ai_at is not null or vat_ai_tries >= 3 or vat_source is distinct from 'usual' or created_at < now() - interval '1 day')) else 0 end);
end $function$;


-- ---------------------------------------------------------------------------
-- 6b. The activity log leaves out the chat and report tables: they change with every message, and what the team does in
--     a customer chat is kept in the chat itself.
-- ---------------------------------------------------------------------------
create or replace function private.activity_exempt() returns text[]
language sql immutable set search_path = public, private as $$
  select array['activity_log', 'messages', 'notifications', 'alert_log', 'usage_events', 'ai_logs', 'shop_hits', 'payment_events', 'org_counters',
    'stock_levels', 'agent_runs', 'guide_progress', 'lookup_failures', 'sso_logins', 'whatsapp_sessions', 'chat_links', 'voice_calls',
    'integration_events', 'prism_callbacks', 'kyc_profiles', 'practice_intakes', 'identity_checks', 'account_recoveries', 'support_cases',
    'approval_links', 'customer_chats', 'daily_reports', 'daily_report_prefs']
$$;

-- ---------------------------------------------------------------------------
-- 7. Schedules
-- ---------------------------------------------------------------------------
-- 07:00 UTC (08:00 in Lagos), before the morning alerts at :05: the books inbox message. Every hour at :02: the evening
-- reports due.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname in ('counta-inbox-digest', 'counta-daily-reports');
    perform cron.schedule('counta-inbox-digest', '0 7 * * *', 'select private.inbox_digest_tick()');
    perform cron.schedule('counta-daily-reports', '2 * * * *', 'select private.daily_report_tick()');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 8. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function private.inbox_push(), private.inbox_summary(uuid), private.inbox_digest(uuid), private.inbox_digest_tick(), private.pin_weak(text),
  private.chat_owns(uuid, text, uuid), private.report_pref(public.orgs, public.members), private.report_parts(public.members),
  private.daily_report_data(uuid, public.members, date), private.daily_report_tick(), private.chat_customers(public.customer_chats),
  private.customer_chat_ctx(public.customer_chats), private.close_chat_claims()
  from public, anon, authenticated;
revoke all on function public.svc_check_pin(uuid, text), public.svc_chat_pending_set(uuid, jsonb), public.svc_chat_pending(uuid),
  public.svc_chat_rpc(uuid, text, jsonb), public.svc_daily_report_ask(uuid, date), public.svc_daily_report(uuid), public.svc_daily_report_done(uuid, jsonb),
  public.svc_customer_chat_find(text, text, text), public.svc_customer_chat_switch(uuid, uuid), public.svc_customer_chat_log(uuid, text, text, text, jsonb),
  public.svc_customer_chat_history(uuid), public.svc_customer_chat_pending(uuid, jsonb), public.svc_customer_view(uuid, text, jsonb),
  public.svc_customer_claim(uuid, jsonb), public.svc_customer_handoff(uuid, text), public.svc_customer_order(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.svc_check_pin(uuid, text), public.svc_chat_pending_set(uuid, jsonb), public.svc_chat_pending(uuid),
  public.svc_chat_rpc(uuid, text, jsonb), public.svc_daily_report_ask(uuid, date), public.svc_daily_report(uuid), public.svc_daily_report_done(uuid, jsonb),
  public.svc_customer_chat_find(text, text, text), public.svc_customer_chat_switch(uuid, uuid), public.svc_customer_chat_log(uuid, text, text, text, jsonb),
  public.svc_customer_chat_history(uuid), public.svc_customer_chat_pending(uuid, jsonb), public.svc_customer_view(uuid, text, jsonb),
  public.svc_customer_claim(uuid, jsonb), public.svc_customer_handoff(uuid, text), public.svc_customer_order(uuid, jsonb)
  to service_role;
revoke all on function public.approval_pin_status(), public.set_approval_pin(text), public.clear_approval_pin(), public.get_daily_report_prefs(uuid),
  public.save_daily_report_prefs(uuid, jsonb), public.get_customer_chats(uuid, jsonb), public.get_customer_chat(uuid), public.customer_chat_reply(uuid, text),
  public.customer_chat_set(uuid, jsonb), public.save_customer_chat_settings(uuid, jsonb), public.get_attention(uuid)
  from public, anon;
grant execute on function public.approval_pin_status(), public.set_approval_pin(text), public.clear_approval_pin(), public.get_daily_report_prefs(uuid),
  public.save_daily_report_prefs(uuid, jsonb), public.get_customer_chats(uuid, jsonb), public.get_customer_chat(uuid), public.customer_chat_reply(uuid, text),
  public.customer_chat_set(uuid, jsonb), public.save_customer_chat_settings(uuid, jsonb), public.get_attention(uuid)
  to authenticated;
