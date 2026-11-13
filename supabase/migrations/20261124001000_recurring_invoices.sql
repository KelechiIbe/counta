-- Practice management, part 10: recurring invoices. A general Counta feature (any business can bill a customer on a
-- schedule); firms use it for their retainers.
--
-- A schedule (recurring_invoices) bills one customer monthly on a day from 1 to 28 (so every month has it, February
-- included), quarterly or annually, from a start date to an optional end date, with 1 to 50 lines. A line marked once
-- (an expenses deposit, a set-up fee) goes on the schedule's first invoice only. Line prices are before VAT; a standard
-- line carries VAT at the rate of the invoice's date (7.5%), zero-rated and exempt lines none; the three treatments are the
-- ones the invoice lines accept (private.write_lines).
--
-- The hourly tick (private.recurring_tick, pg_cron job 'counta-recurring') takes each active schedule due on its
-- business's own day (orgs.timezone, Lagos by default: at 23:30 UTC it is already tomorrow in Lagos). For each, on its
-- own (one failing schedule never stops the others): one run per schedule and day (recurring_invoice_runs); the invoice
-- made and issued (channel 'recurring') in the name of the person who set the schedule up while their place in the
-- business is active, else of the business's contact (private.org_contact), whose name the activity log records for that
-- schedule alone (private.set_actor, cleared after each); sent to the customer when auto_send, or, when NRS has to sign it
-- first (e-invoicing to a business or government customer), held, and sent by a later tick once it is issued. The
-- schedule then moves past today: one invoice, dated the day it was due, however far behind it was, and no backfill; past
-- its end date it ends. A failure keeps the day, records the error, and pauses the schedule after three in a row. Paused
-- schedules and read-only businesses are skipped; ending a full mandate pauses the business's schedules
-- (private.org_pause_all). Sending goes through the outbound gate like a user's send (private.require_outbound): a
-- download-only business never sends.
--
-- issue_invoice and send_document keep their behaviour: their bodies after the permission check are now
-- private.issue_invoice_as and private.send_document_as, which the tick calls with the issuing member.
-- RPCs (record_sales in the schedule's business): recurring_save, recurring_list, recurring_set_status, recurring_run_now.
--
-- Redefined functions are their latest definitions with only the changes described at each one; signatures are unchanged,
-- so create or replace keeps every grant.

-- ---------------------------------------------------------------------------
-- 1. Schedules and runs
-- ---------------------------------------------------------------------------
alter table public.sales drop constraint if exists sales_channel_check;
alter table public.sales add constraint sales_channel_check
  check (channel in ('till', 'invoice', 'online', 'whatsapp', 'van', 'phone', 'voice', 'api', 'import', 'schedule', 'bank', 'recurring'));

-- lines: [{description, qty > 0, unit_price >= 0 (before VAT), vat_treatment standard|zero|exempt, once}], as
-- private.recurring_clean_lines leaves them. next_run: the day of the next invoice, in the business's time zone.
-- created_by: whose name the invoices are issued in while their place is active. failures: in a row; three pause it.
-- practice_client_id: the practice client a firm bills with this schedule (its firm business is the schedule's).
create table public.recurring_invoices (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  customer_id uuid not null references public.customers(id),
  status text not null default 'active' check (status in ('active', 'paused', 'ended')),
  frequency text not null check (frequency in ('monthly', 'quarterly', 'annually')),
  day_of_month int not null check (day_of_month between 1 and 28),
  start_date date not null,
  end_date date check (end_date >= start_date),
  next_run date not null,
  due_days int not null default 14 check (due_days between 0 and 365),
  lines jsonb not null check (jsonb_typeof(lines) = 'array' and jsonb_array_length(lines) between 1 and 50),
  auto_send boolean not null default true,
  send_channel text not null default 'email' check (send_channel in ('email', 'whatsapp')),
  notes text check (length(notes) <= 1000),
  created_by uuid references public.members(id) on delete set null,
  failures int not null default 0,
  last_error text,
  last_run_at timestamptz,
  practice_client_id uuid references public.practice_clients(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index recurring_invoices_org on public.recurring_invoices(org_id, created_at);
create index recurring_invoices_due on public.recurring_invoices(next_run) where status = 'active';
create index recurring_invoices_customer on public.recurring_invoices(customer_id);
create index recurring_invoices_client on public.recurring_invoices(practice_client_id) where practice_client_id is not null;
alter table public.recurring_invoices enable row level security;
revoke all on public.recurring_invoices from anon, authenticated;
select private.activity_attach('public.recurring_invoices');

-- One run per schedule and day. status: issued (made and issued, not sent: not to be sent, or the send failed with
-- send_error), waiting_nrs (held until NRS signs it; sent by a later tick once issued), sent, failed (error; the day is
-- tried again by the next tick while the schedule is active).
create table public.recurring_invoice_runs (
  id uuid primary key default gen_random_uuid(),
  schedule_id uuid not null references public.recurring_invoices(id) on delete cascade,
  run_date date not null,
  sale_id uuid references public.sales(id) on delete set null,
  status text not null check (status in ('issued', 'waiting_nrs', 'sent', 'failed')),
  error text,
  send_error text,
  created_at timestamptz not null default now(),
  unique (schedule_id, run_date)
);
create index recurring_invoice_runs_sale on public.recurring_invoice_runs(sale_id) where sale_id is not null;
create index recurring_invoice_runs_waiting on public.recurring_invoice_runs(created_at) where status = 'waiting_nrs';
alter table public.recurring_invoice_runs enable row level security;
revoke all on public.recurring_invoice_runs from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Issuing and sending as a given member
-- ---------------------------------------------------------------------------
-- issue_invoice's body after its permission check, for the member m (unchanged).
create or replace function private.issue_invoice_as(p_sale uuid, p_issue_date date, m public.members) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; c public.customers; v_owed numeric; v_day date; v_today date; d public.einvoice_docs;
begin
  select * into s from sales where id = p_sale for update;
  if not found then raise exception 'Invoice not found.'; end if;
  if s.doc_type <> 'invoice' or s.status <> 'draft' then raise exception '% is not a draft invoice.', s.number; end if;
  select * into d from einvoice_docs where sale_id = s.id;
  if d.state in ('waiting', 'sending') then raise exception 'NRS is already checking %.', s.number; end if;
  if s.total <= 0 then raise exception 'The invoice total must be above zero.'; end if;
  v_today := private.local_day(s.org_id, now());
  -- A draft left with the day it was started takes the day it is issued.
  v_day := coalesce(p_issue_date, case when s.issue_date = private.local_day(s.org_id, s.created_at) then v_today else s.issue_date end);
  if v_day > v_today then raise exception 'An invoice cannot be dated in the future.'; end if;
  perform private.require_open_day(s.org_id, v_day);
  select * into c from customers where id = s.customer_id;
  v_owed := private.customer_balance(s.org_id, c.id) + s.total;
  if c.credit_limit > 0 and v_owed > c.credit_limit + 0.004 and not (private.perm_of(m, 'approve_adjustments') or private.perm_of(m, 'keep_books')) then
    raise exception '% would owe % against a credit limit of %. A manager can issue it.', c.name, to_char(v_owed, 'FM999,999,999,990.00'), to_char(c.credit_limit, 'FM999,999,999,990.00');
  end if;
  -- To a business or government buyer, with e-invoicing on: NRS signs it first. It stays a draft, locked, until then.
  if private.einvoice_route(s.id) = 'clear' then
    if coalesce(upper(c.country), 'NG') = 'NG' and nullif(btrim(coalesce(c.tin, '')), '') is null then
      raise exception 'Add %''s Tax ID before issuing: NRS checks invoices to businesses and government, and needs it.', c.name;
    end if;
    update sales set due_date = coalesce(due_date, v_day) + (v_day - issue_date), issue_date = v_day,
      customer_name = c.name, customer_tin = c.tin, customer_email = c.email, customer_phone = c.phone, customer_address = c.address where id = s.id;
    perform private.einvoice_open(s.id, 'clear', true, m.id);
    return private.sale_json(s.id, private.can_see_costs(s.org_id));
  end if;
  update sales set status = 'open', due_date = coalesce(due_date, v_day) + (v_day - issue_date), issue_date = v_day where id = s.id;
  s := private.post_sale(s.id, m, private.posting_time(s.org_id, v_day));
  s := private.refresh_sale(s.id);
  return private.sale_json(s.id, private.can_see_costs(s.org_id));
end $$;

-- Latest definition (20261112000100_einvoice_send.sql), its body after the permission check moved to issue_invoice_as.
create or replace function public.issue_invoice(p_sale uuid, p_issue_date date default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members;
begin
  select * into s from sales where id = p_sale for update;
  if not found then raise exception 'Invoice not found.'; end if;
  m := private.require(s.org_id, 'record_sales');
  return private.issue_invoice_as(p_sale, p_issue_date, m);
end $$;

-- send_document's body after its permission check, for the member m (unchanged): the outbound gate, NRS's signature, then
-- the message.
create or replace function private.send_document_as(p_sale uuid, p_channel text, p_to text, m public.members) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; msg public.messages; o public.orgs; v_label text;
begin
  select * into s from sales where id = p_sale;
  if not found then raise exception 'Sale not found.'; end if;
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

-- Latest definition (20261124000500_outbound_branding.sql), its body after the permission check moved to send_document_as.
create or replace function public.send_document(p_sale uuid, p_channel text, p_to text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members;
begin
  select * into s from sales where id = p_sale;
  if not found then raise exception 'Sale not found.'; end if;
  m := private.require(s.org_id, 'record_sales');
  return private.send_document_as(p_sale, p_channel, p_to, m);
end $$;

-- ---------------------------------------------------------------------------
-- 3. The days
-- ---------------------------------------------------------------------------
-- The day p_day of the month 1, 3 or 12 months after p_after's month. Days 1 to 28 exist in every month.
create or replace function private.recurring_next(p_freq text, p_day int, p_after date) returns date
language plpgsql immutable set search_path = public, private as $$
declare v_month int;
begin
  if p_freq is null or p_freq not in ('monthly', 'quarterly', 'annually') then raise exception 'Choose how often: monthly, quarterly or annually.'; end if;
  if p_day is null or p_day not between 1 and 28 then raise exception 'Choose a day of the month from 1 to 28.'; end if;
  -- Months counted from year 0, January as 0.
  v_month := extract(year from p_after)::int * 12 + extract(month from p_after)::int - 1
    + case p_freq when 'monthly' then 1 when 'quarterly' then 3 else 12 end;
  return make_date(v_month / 12, v_month % 12 + 1, p_day);
end $$;

-- The first day p_day on or after p_start (the frequency only spaces the days after it).
create or replace function private.recurring_first(p_freq text, p_day int, p_start date) returns date
language plpgsql immutable set search_path = public, private as $$
declare v date;
begin
  if p_freq is null or p_freq not in ('monthly', 'quarterly', 'annually') then raise exception 'Choose how often: monthly, quarterly or annually.'; end if;
  if p_day is null or p_day not between 1 and 28 then raise exception 'Choose a day of the month from 1 to 28.'; end if;
  v := make_date(extract(year from p_start)::int, extract(month from p_start)::int, p_day);
  if v < p_start then v := private.recurring_next('monthly', p_day, v); end if;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Running a schedule
-- ---------------------------------------------------------------------------
-- A schedule's lines as they are kept, or an error saying what is wrong: 1 to 50 lines, each with a description, a
-- quantity above zero, a price of zero or more, VAT standard, zero or exempt (standard when not given), once or not; at
-- least one line repeats and the lines that repeat come to more than zero (an invoice of nothing cannot be issued).
create or replace function private.recurring_clean_lines(p jsonb) returns jsonb
language plpgsql immutable set search_path = public, private as $$
declare x jsonb; v_out jsonb := '[]'::jsonb; v_desc text; v_qty numeric; v_price numeric; v_treat text; v_once boolean;
  v_repeats boolean := false; v_repeat_total numeric := 0;
begin
  if p is null or jsonb_typeof(p) <> 'array' or jsonb_array_length(p) = 0 then raise exception 'Add at least one line.'; end if;
  if jsonb_array_length(p) > 50 then raise exception 'A recurring invoice can have up to 50 lines.'; end if;
  for x in select * from jsonb_array_elements(p) loop
    if jsonb_typeof(x) <> 'object' then raise exception 'Each line needs a description, a quantity and a price.'; end if;
    v_desc := trim(coalesce(x->>'description', ''));
    if v_desc = '' then raise exception 'Each line needs a description.'; end if;
    if length(v_desc) > 300 then raise exception 'Keep each line''s description under 300 characters.'; end if;
    v_qty := round(private.num(x->>'qty'), 3);
    if coalesce(v_qty, 0) <= 0 then raise exception 'Every line needs a quantity above zero.'; end if;
    v_price := round(private.num(x->>'unit_price'), 2);
    if v_price is null or v_price < 0 then raise exception 'Enter a price of zero or more for "%".', v_desc; end if;
    v_treat := coalesce(nullif(trim(x->>'vat_treatment'), ''), 'standard');
    if v_treat not in ('standard', 'zero', 'exempt') then
      raise exception 'Choose the VAT treatment of "%": standard, zero or exempt.', v_desc;
    end if;
    v_once := coalesce(lower(x->>'once') = 'true', false);
    if not v_once then
      v_repeats := true;
      v_repeat_total := v_repeat_total + round(v_qty * v_price, 2);
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object('description', v_desc, 'qty', v_qty, 'unit_price', v_price, 'vat_treatment', v_treat, 'once', v_once));
  end loop;
  if not v_repeats then raise exception 'Add at least one line that repeats: a line marked once goes on the first invoice only.'; end if;
  if v_repeat_total <= 0 then raise exception 'The lines that repeat must come to more than zero.'; end if;
  return v_out;
end $$;

-- Who issues a schedule's invoices: the person who set it up while their place in the business is active, else the
-- business's contact (the owner; under full mandate the engagement partner's place). Null when there is no one.
create or replace function private.recurring_actor(p_org uuid, p_created_by uuid) returns public.members
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  select * into m from members where id = p_created_by and org_id = p_org and status = 'active';
  if m.id is null then m := private.org_contact(p_org); end if;
  return m;
end $$;

-- Sends an issued invoice through send_document_as. Null when it went, else why not (the send is undone, the invoice kept).
create or replace function private.recurring_send(p_sale uuid, p_channel text, m public.members) returns text
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.send_document_as(p_sale, p_channel, null, m);
  return null;
exception when others then
  return left(sqlerrm, 500);
end $$;

-- One run of a schedule for the day p_run_date: the run recorded (a day already done, anything but failed, is not done
-- again: null), the invoice made as a draft dated that day and due due_days later (its lines priced before VAT, the once
-- lines only while no other run has made an invoice), issued; held while NRS signs it (waiting_nrs), else sent when the
-- schedule says so (sent; a send that fails leaves it issued with send_error). The issuing member's user is the actor
-- of the writes from here on (private.set_actor); the caller clears it. Returns the invoice. Errors are raised.
create or replace function private.recurring_run(p_id uuid, p_run_date date) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare r public.recurring_invoices; m public.members; s public.sales; v_run uuid; v_first boolean; v_lines jsonb; v_status text; v_send_error text;
begin
  select * into r from recurring_invoices where id = p_id for update;
  if r.id is null then raise exception 'Recurring invoice not found.'; end if;
  insert into recurring_invoice_runs (schedule_id, run_date, status) values (r.id, p_run_date, 'issued')
  on conflict (schedule_id, run_date) do update set status = 'issued', sale_id = null, error = null, send_error = null, created_at = now()
    where recurring_invoice_runs.status = 'failed'
  returning id into v_run;
  if v_run is null then return null; end if;

  m := private.recurring_actor(r.org_id, r.created_by);
  if m.id is null then raise exception 'No one in the business can issue this invoice.'; end if;
  perform private.set_actor(m.user_id);
  v_first := not exists (select 1 from recurring_invoice_runs x
    where x.schedule_id = r.id and x.id <> v_run and x.status in ('issued', 'waiting_nrs', 'sent'));
  select jsonb_agg(jsonb_build_object('description', e.l->>'description', 'kind', 'service', 'qty', e.l->'qty', 'unit_price', e.l->'unit_price',
      'vat_treatment', e.l->>'vat_treatment') order by e.n)
    into v_lines
  from jsonb_array_elements(r.lines) with ordinality as e(l, n)
  where v_first or not coalesce((e.l->>'once')::boolean, false);
  s := private.create_sale(r.org_id, jsonb_build_object('doc_type', 'invoice', 'status', 'draft', 'channel', 'recurring', 'customer_id', r.customer_id,
    'issue_date', p_run_date, 'due_date', p_run_date + r.due_days, 'prices_include_vat', false, 'notes', r.notes,
    'lines', coalesce(v_lines, '[]'::jsonb)), m);
  perform private.issue_invoice_as(s.id, p_run_date, m);
  select * into s from sales where id = s.id;
  if s.status = 'draft' and exists (select 1 from einvoice_docs d where d.sale_id = s.id and d.state in ('waiting', 'sending')) then
    v_status := 'waiting_nrs';
  elsif r.auto_send then
    v_send_error := private.recurring_send(s.id, r.send_channel, m);
    v_status := case when v_send_error is null then 'sent' else 'issued' end;
  else
    v_status := 'issued';
  end if;
  update recurring_invoice_runs set sale_id = s.id, status = v_status, send_error = v_send_error where id = v_run;
  update recurring_invoices set last_run_at = now(), updated_at = now() where id = r.id;
  return s.id;
end $$;

-- The hourly job. 1. Every active schedule of a business that is not read-only, due on the business's own day at p_now,
-- each on its own (its own exception block, its own actor, cleared after it): run for its day; then the next day after
-- today (one invoice however far behind, no backfill), the failures forgotten, ended past its end date. A failure keeps
-- the day, counts, records the error (and a failed run) and pauses the schedule at three. 2. Every held invoice NRS has
-- since signed (issued) of a schedule not paused, in a business not read-only: sent when the schedule says so (sent, or
-- issued with send_error), else issued. Returns {"issued", "sent", "failed"}.
create or replace function private.recurring_tick(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.recurring_invoices; x record; m public.members; v_today date; v_next date; v_sale uuid; v_status text; v_err text;
  v_issued int := 0; v_sent int := 0; v_failed int := 0;
begin
  for r in
    select ri.* from recurring_invoices ri join orgs o on o.id = ri.org_id
    where ri.status = 'active' and o.read_only_at is null
      -- No business's day is more than one day ahead of UTC's (the index's bound); then its own day.
      and ri.next_run <= (p_now at time zone 'UTC')::date + 1
      and ri.next_run <= private.local_day(ri.org_id, p_now)
    order by ri.next_run, ri.created_at, ri.id
    for update of ri skip locked
  loop
    perform private.set_actor(null);
    v_today := private.local_day(r.org_id, p_now);
    begin
      if r.end_date is not null and r.next_run > r.end_date then
        update recurring_invoices set status = 'ended', updated_at = now() where id = r.id;
      else
        v_sale := private.recurring_run(r.id, r.next_run);
        if v_sale is not null then
          v_issued := v_issued + 1;
          select status into v_status from recurring_invoice_runs where schedule_id = r.id and run_date = r.next_run;
          if v_status = 'sent' then v_sent := v_sent + 1; end if;
        end if;
        v_next := r.next_run;
        while v_next <= v_today loop
          v_next := private.recurring_next(r.frequency, r.day_of_month, v_next);
        end loop;
        update recurring_invoices set next_run = v_next, failures = 0, last_error = null,
          status = case when end_date is not null and v_next > end_date then 'ended' else status end, updated_at = now()
        where id = r.id;
      end if;
    exception when others then
      get stacked diagnostics v_err = message_text;
      v_err := left(v_err, 500);
      update recurring_invoices set failures = failures + 1, last_error = v_err,
        status = case when failures + 1 >= 3 then 'paused' else status end, updated_at = now()
      where id = r.id;
      insert into recurring_invoice_runs (schedule_id, run_date, status, error) values (r.id, r.next_run, 'failed', v_err)
      on conflict (schedule_id, run_date) do update set error = excluded.error where recurring_invoice_runs.status = 'failed';
      v_failed := v_failed + 1;
    end;
    perform private.set_actor(null);
  end loop;

  for x in
    select ru.id, ru.sale_id, ri.org_id, ri.created_by, ri.auto_send, ri.send_channel
    from recurring_invoice_runs ru
    join recurring_invoices ri on ri.id = ru.schedule_id
    join sales s on s.id = ru.sale_id
    join orgs o on o.id = ri.org_id
    where ru.status = 'waiting_nrs' and ri.status <> 'paused' and o.read_only_at is null and s.status in ('open', 'partially_paid', 'paid')
    order by ru.created_at, ru.id
    for update of ru skip locked
  loop
    perform private.set_actor(null);
    begin
      if x.auto_send then
        m := private.recurring_actor(x.org_id, x.created_by);
        if m.id is null then
          v_err := 'No one in the business can send this invoice.';
        else
          perform private.set_actor(m.user_id);
          v_err := private.recurring_send(x.sale_id, x.send_channel, m);
        end if;
        update recurring_invoice_runs set status = case when v_err is null then 'sent' else 'issued' end, send_error = v_err where id = x.id;
        if v_err is null then v_sent := v_sent + 1; end if;
      else
        update recurring_invoice_runs set status = 'issued' where id = x.id;
      end if;
    exception when others then
      get stacked diagnostics v_err = message_text;
      update recurring_invoice_runs set status = 'issued', send_error = left(v_err, 500) where id = x.id;
    end;
    perform private.set_actor(null);
  end loop;
  return jsonb_build_object('issued', v_issued, 'sent', v_sent, 'failed', v_failed);
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'counta-recurring';
    perform cron.schedule('counta-recurring', '7 * * * *', 'select private.recurring_tick()');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Ending a full mandate pauses the schedules
-- ---------------------------------------------------------------------------
-- Latest definition (20261124000900_mandate_end_handover.sql), and the business's active recurring invoices paused.
create or replace function private.org_pause_all(p_org uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare x uuid;
begin
  update integrations set status = 'paused' where org_id = p_org and status in ('active', 'error');
  for x in select id from pos_connections where org_id = p_org and status <> 'removed' loop
    perform public.svc_pos_remove(x);
  end loop;
  update bank_accounts set provider = 'manual', provider_meta = coalesce(provider_meta, '{}'::jsonb) || jsonb_build_object('unlinked_at', now(),
      'unlinked_reason', 'engagement ended', 'former_feed', provider_ref), provider_ref = null
  where org_id = p_org and provider = 'mono' and provider_ref is not null;
  update subscriptions set cancel_at_period_end = true, updated_at = now() where org_id = p_org and not cancel_at_period_end;
  update recurring_invoices set status = 'paused', updated_at = now() where org_id = p_org and status = 'active';
end $$;

-- ---------------------------------------------------------------------------
-- 6. RPCs
-- ---------------------------------------------------------------------------
-- A schedule with its customer's name, the name of the person who set it up, and its last 12 runs (newest first, with the
-- invoice's number and total).
create or replace function private.recurring_json(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', r.id, 'org_id', r.org_id, 'customer_id', r.customer_id, 'customer_name', c.name, 'status', r.status,
    'frequency', r.frequency, 'day_of_month', r.day_of_month, 'start_date', r.start_date, 'end_date', r.end_date, 'next_run', r.next_run,
    'due_days', r.due_days, 'lines', r.lines, 'auto_send', r.auto_send, 'send_channel', r.send_channel, 'notes', r.notes,
    'practice_client_id', r.practice_client_id, 'failures', r.failures, 'last_error', r.last_error, 'last_run_at', r.last_run_at,
    'created_by', r.created_by, 'created_by_name', cm.display_name, 'created_at', r.created_at, 'updated_at', r.updated_at,
    'runs', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.id, 'run_date', x.run_date, 'status', x.status, 'sale_id', x.sale_id, 'number', s.number,
          'total', s.total, 'error', x.error, 'send_error', x.send_error, 'created_at', x.created_at) order by x.run_date desc)
      from (select * from recurring_invoice_runs where schedule_id = r.id order by run_date desc limit 12) x
      left join sales s on s.id = x.sale_id), '[]'::jsonb))
  from recurring_invoices r
  join customers c on c.id = r.customer_id
  left join members cm on cm.id = r.created_by
  where r.id = p_id
$$;

-- Creates (no id) or edits a schedule of the business. p = {id?, customer_id, frequency, day_of_month, start_date,
-- end_date?, due_days? (14), lines, auto_send? (true), send_channel? ('email'), notes?, practice_client_id?}; an edit keeps
-- what p leaves out. The next invoice day is the first on or after the start date on creation; an edit that changes the
-- timing (frequency, day or start date) moves it to the first day on the new timing after the last invoice made, not
-- before the start date; other edits keep it. Sending each invoice must be allowed by the outbound gate (a download-only
-- business issues them for download). practice_client_id: a client of the practice whose firm business this is.
create or replace function public.recurring_save(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; r public.recurring_invoices; c public.customers; v_new boolean; v_freq text; v_day int; v_start date; v_end date;
  v_due_days int; v_lines jsonb; v_auto boolean; v_channel text; v_notes text; v_client uuid; v_next date; v_last date;
begin
  m := private.require(p_org, 'record_sales');
  if p is null or jsonb_typeof(p) <> 'object' then raise exception 'Send the recurring invoice''s details.'; end if;
  v_new := nullif(trim(p->>'id'), '') is null;
  if not v_new then
    select * into r from recurring_invoices where id = private.uuid_of(trim(p->>'id')) and org_id = p_org for update;
    if r.id is null then raise exception 'Recurring invoice not found.'; end if;
    -- What p leaves out stays as it is.
    p := to_jsonb(r) || p;
  end if;

  select * into c from customers where id = private.uuid_of(trim(p->>'customer_id')) and org_id = p_org and not archived and not is_walk_in;
  if c.id is null then raise exception 'Choose the customer.'; end if;
  v_freq := nullif(trim(p->>'frequency'), '');
  if v_freq is null or v_freq not in ('monthly', 'quarterly', 'annually') then raise exception 'Choose how often: monthly, quarterly or annually.'; end if;
  v_day := case when p->>'day_of_month' ~ '^\s*[0-9]{1,2}\s*$' then trim(p->>'day_of_month')::int end;
  if v_day is null or v_day not between 1 and 28 then raise exception 'Choose a day of the month from 1 to 28.'; end if;
  v_start := private.date_or_null(p->>'start_date');
  if v_start is null then raise exception 'Enter the start date.'; end if;
  if nullif(trim(p->>'end_date'), '') is not null then
    v_end := private.date_or_null(p->>'end_date');
    if v_end is null then raise exception 'Enter the end date as a date, or leave it out.'; end if;
    if v_end < v_start then raise exception 'The end date must be on or after the start date.'; end if;
  end if;
  if nullif(trim(p->>'due_days'), '') is null then
    v_due_days := 14;
  else
    v_due_days := case when p->>'due_days' ~ '^\s*[0-9]{1,3}\s*$' then trim(p->>'due_days')::int end;
    if v_due_days is null or v_due_days > 365 then raise exception 'Give the days to pay as a whole number from 0 to 365.'; end if;
  end if;
  v_lines := private.recurring_clean_lines(p->'lines');
  if p->'auto_send' is null or jsonb_typeof(p->'auto_send') = 'null' then
    v_auto := true;
  else
    v_auto := case lower(p->>'auto_send') when 'true' then true when 'false' then false end;
    if v_auto is null then raise exception 'Say whether each invoice is sent to the customer.'; end if;
  end if;
  v_channel := coalesce(nullif(trim(p->>'send_channel'), ''), 'email');
  if v_channel not in ('email', 'whatsapp') then raise exception 'Send by email or WhatsApp.'; end if;
  if v_auto then perform private.require_outbound(p_org, v_channel, 'document'); end if;
  v_notes := nullif(trim(p->>'notes'), '');
  if length(v_notes) > 1000 then raise exception 'Keep the notes under 1,000 characters.'; end if;
  if nullif(trim(p->>'practice_client_id'), '') is not null then
    select pc.id into v_client from practice_clients pc join practices pr on pr.id = pc.practice_id
    where pc.id = private.uuid_of(trim(p->>'practice_client_id')) and pr.firm_org_id = p_org;
    if v_client is null then raise exception 'Choose a client of the practice whose firm business this is.'; end if;
  end if;

  if v_new then
    v_next := private.recurring_first(v_freq, v_day, v_start);
  elsif v_freq is distinct from r.frequency or v_day is distinct from r.day_of_month or v_start is distinct from r.start_date then
    select max(run_date) into v_last from recurring_invoice_runs where schedule_id = r.id and status <> 'failed';
    v_next := private.recurring_first(v_freq, v_day, greatest(v_start, v_last + 1));
  else
    v_next := r.next_run;
  end if;
  if v_end is not null and v_next > v_end and coalesce(r.status, 'active') <> 'ended' then
    raise exception 'No invoice date falls before the end date: the next would be %.', to_char(v_next, 'DD Mon YYYY');
  end if;

  if v_new then
    insert into recurring_invoices (org_id, customer_id, frequency, day_of_month, start_date, end_date, next_run, due_days, lines, auto_send,
      send_channel, notes, created_by, practice_client_id)
    values (p_org, c.id, v_freq, v_day, v_start, v_end, v_next, v_due_days, v_lines, v_auto, v_channel, v_notes, m.id, v_client)
    returning * into r;
  else
    update recurring_invoices set customer_id = c.id, frequency = v_freq, day_of_month = v_day, start_date = v_start, end_date = v_end,
      next_run = v_next, due_days = v_due_days, lines = v_lines, auto_send = v_auto, send_channel = v_channel, notes = v_notes,
      practice_client_id = v_client, updated_at = now()
    where id = r.id;
  end if;
  return private.recurring_json(r.id);
end $$;

-- The business's schedules, active first, then by their next invoice day.
create or replace function public.recurring_list(p_org uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.require(p_org, 'record_sales');
  return coalesce((select jsonb_agg(private.recurring_json(r.id) order by (r.status = 'active') desc, r.status, r.next_run, r.created_at)
    from recurring_invoices r where r.org_id = p_org), '[]'::jsonb);
end $$;

-- Pauses, ends or resumes a schedule. Resuming forgets its failures and moves a next invoice day that has passed to the
-- first on its timing that is today or later (no catch-up of the days missed); refused when that is after the end date.
create or replace function public.recurring_set_status(p_id uuid, p_status text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.recurring_invoices; v_today date; v_next date;
begin
  select * into r from recurring_invoices where id = p_id for update;
  if r.id is null then raise exception 'Recurring invoice not found.'; end if;
  perform private.require(r.org_id, 'record_sales');
  if p_status is null or p_status not in ('active', 'paused', 'ended') then raise exception 'Choose active, paused or ended.'; end if;
  if p_status = 'active' then
    v_today := private.local_day(r.org_id, now());
    v_next := r.next_run;
    while v_next < v_today loop
      v_next := private.recurring_next(r.frequency, r.day_of_month, v_next);
    end loop;
    if r.end_date is not null and v_next > r.end_date then
      raise exception 'No invoice date falls before the end date: the next would be %. Change the end date first.', to_char(v_next, 'DD Mon YYYY');
    end if;
    update recurring_invoices set status = 'active', next_run = v_next, failures = 0, last_error = null, updated_at = now() where id = r.id;
  else
    update recurring_invoices set status = p_status, updated_at = now() where id = r.id;
  end if;
  return private.recurring_json(r.id);
end $$;

-- Issues the schedule's next invoice now: dated its day if that has come, else today; then the next invoice day moves one
-- period on (and past today). Refused for an ended schedule, or when the schedule already has an invoice for that day.
-- A paused schedule stays paused. {sale_id, number, status (the run's), send_error, schedule}.
create or replace function public.recurring_run_now(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.recurring_invoices; x public.recurring_invoice_runs; v_today date; v_run date; v_sale uuid; v_next date;
begin
  select * into r from recurring_invoices where id = p_id for update;
  if r.id is null then raise exception 'Recurring invoice not found.'; end if;
  perform private.require(r.org_id, 'record_sales');
  if r.status = 'ended' then raise exception 'This schedule has ended.'; end if;
  v_today := private.local_day(r.org_id, now());
  v_run := least(r.next_run, v_today);
  v_sale := private.recurring_run(r.id, v_run);
  perform private.set_actor(null);
  if v_sale is null then raise exception 'This schedule already has an invoice dated %.', to_char(v_run, 'DD Mon YYYY'); end if;
  v_next := private.recurring_next(r.frequency, r.day_of_month, r.next_run);
  while v_next <= v_today loop
    v_next := private.recurring_next(r.frequency, r.day_of_month, v_next);
  end loop;
  update recurring_invoices set next_run = v_next, failures = 0, last_error = null,
    status = case when end_date is not null and v_next > end_date then 'ended' else status end, updated_at = now()
  where id = r.id;
  select * into x from recurring_invoice_runs where schedule_id = r.id and run_date = v_run;
  return jsonb_build_object('sale_id', v_sale, 'number', (select number from sales where id = v_sale), 'status', x.status, 'send_error', x.send_error,
    'schedule', private.recurring_json(r.id));
end $$;

-- ---------------------------------------------------------------------------
-- 7. Grants
-- ---------------------------------------------------------------------------
-- core.sql grants every private function to authenticated: the helpers this migration creates or redefines are not
-- callable by the signed-in person.
revoke all on function private.issue_invoice_as(uuid, date, public.members), private.send_document_as(uuid, text, text, public.members),
  private.recurring_next(text, int, date), private.recurring_first(text, int, date), private.recurring_clean_lines(jsonb),
  private.recurring_actor(uuid, uuid), private.recurring_send(uuid, text, public.members), private.recurring_run(uuid, date),
  private.recurring_tick(timestamptz), private.org_pause_all(uuid), private.recurring_json(uuid)
  from public, anon, authenticated;
revoke execute on function public.recurring_save(uuid, jsonb), public.recurring_list(uuid), public.recurring_set_status(uuid, text),
  public.recurring_run_now(uuid)
  from public, anon;
grant execute on function public.recurring_save(uuid, jsonb), public.recurring_list(uuid), public.recurring_set_status(uuid, text),
  public.recurring_run_now(uuid)
  to authenticated;
