-- Counta, 13 November 2026: e-invoicing, part 3. TaxStreem as the access point provider (APP): signed invoices go to the
-- buyer through NRS, and invoices NRS brings for a Counta business become draft bills to review (docs/e-invoicing.md).
--
-- How NRS's exchange works (API 1.1, /docs/access-point-providers/exchange). The seller's access point asks NRS to transmit
-- a signed invoice (POST transmit/{irn}); NRS posts a notification, { irn, message }, to the webhook address every access
-- point involved has registered in NRS's APP portal, with message TRANSMITTING, TRANSMITTED, ACKNOWLEDGED or FAILED. The
-- buyer's access point downloads the invoice (encrypted; GET download/{irn}) and confirms that it arrived (PATCH
-- transmit/{irn}). Every call is made with TaxStreem's APP keys. NRS signs nothing it sends to the webhook, so the address
-- carries a secret, and nothing in a notification is believed until NRS answers for it.
--
-- 1. The webhook address: /functions/v1/einvoice/nrs-hook/<NRS_WEBHOOK_TOKEN>, the token kept in Vault. The admin portal
--    shows the address under NRS e-invoicing, to paste into the APP portal's Developer section.
-- 2. Sending to the buyer. A sale to a business or government (cleared) is sent to the buyer as soon as NRS signs it, and
--    tried again when NRS is down. Each notification moves it on: on its way, delivered, received by the buyer's access
--    point, or not delivered (with NRS's words). The sale shows where it stands, and a sale NRS could not deliver can be sent
--    again.
-- 3. Receiving. A notification about an invoice to a Counta business (found by the buyer's Tax ID) brings the invoice: it is
--    downloaded, decrypted, kept in the business's documents and written as a supplier invoice (source 'nrs') with a draft
--    bill, through the same checks as one a supplier uploads. Nothing reaches the books until someone approves it. Counta
--    then tells NRS the invoice arrived.
-- 4. Every notification is kept (einvoice_webhooks): the APP's record of transmissions that NRS asks APPs to keep.

-- ---------------------------------------------------------------------------
-- 1. The webhook address
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'NRS_WEBHOOK_TOKEN') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(24), 'hex'), 'NRS_WEBHOOK_TOKEN',
      'The secret part of the address NRS posts e-invoice exchange notifications to');
  end if;
end $$;

create or replace function public.svc_einvoice_hook_token() returns text
language sql stable security definer set search_path = public, vault as $$
  select s.decrypted_secret from vault.decrypted_secrets s where s.name = 'NRS_WEBHOOK_TOKEN' order by s.created_at desc limit 1
$$;

-- ---------------------------------------------------------------------------
-- 2. Sending signed invoices to the buyer
-- ---------------------------------------------------------------------------
-- xm_state: due (to send), sending (asking NRS now), transmitting (NRS has it), transmitted (delivered to the buyer's access
-- point), acknowledged (the buyer's access point confirmed it), failed (NRS could not deliver it; a person decides).
alter table public.einvoice_docs add column if not exists xm_state text;
alter table public.einvoice_docs add column if not exists xm_tries int not null default 0;
alter table public.einvoice_docs add column if not exists xm_next_at timestamptz;
alter table public.einvoice_docs add column if not exists xm_note text;
alter table public.einvoice_docs add column if not exists xm_at timestamptz;
alter table public.einvoice_docs add column if not exists xm_sent_at timestamptz;
alter table public.einvoice_docs drop constraint if exists einvoice_docs_xm_state_check;
alter table public.einvoice_docs add constraint einvoice_docs_xm_state_check
  check (xm_state in ('due', 'sending', 'transmitting', 'transmitted', 'acknowledged', 'failed'));
create index if not exists einvoice_docs_xm on public.einvoice_docs (xm_next_at) where xm_state in ('due', 'sending');
create index if not exists einvoice_docs_irn_any on public.einvoice_docs (irn) where irn is not null;

-- Signed and cleared: on its way to the buyer.
create or replace function private.on_einvoice_signed_send() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.state = 'signed' and old.state is distinct from 'signed' and new.kind = 'clear' and new.xm_state is null then
    new.xm_state := 'due'; new.xm_next_at := now(); new.xm_at := now();
  end if;
  return new;
end $$;
drop trigger if exists einvoice_docs_signed_send on public.einvoice_docs;
create trigger einvoice_docs_signed_send before update of state on public.einvoice_docs for each row
  when (new.state = 'signed' and new.kind = 'clear') execute function private.on_einvoice_signed_send();

-- Sales NRS signed before this stay as they are: only sales signed from now on go to the buyer on their own.

-- ---------------------------------------------------------------------------
-- 3. Notifications from NRS, and invoices received
-- ---------------------------------------------------------------------------
create table if not exists public.einvoice_webhooks (
  id bigserial primary key,
  at timestamptz not null default now(),
  irn text,
  message text,
  body jsonb,
  matched text not null default 'none' check (matched in ('sale', 'inbound', 'both', 'none', 'invalid')),
  sale_id uuid references public.sales(id) on delete set null,
  inbound_id uuid
);
create index if not exists einvoice_webhooks_at on public.einvoice_webhooks (at desc);
create index if not exists einvoice_webhooks_irn on public.einvoice_webhooks (irn) where irn is not null;
create index if not exists einvoice_webhooks_sale on public.einvoice_webhooks (sale_id) where sale_id is not null;
alter table public.einvoice_webhooks enable row level security;
revoke all on public.einvoice_webhooks from anon, authenticated;

-- state: due (to download), fetching (downloading now), billed (a draft bill is written; NRS is still to hear it arrived),
-- confirmed (NRS heard), unmatched (no Counta business takes e-invoices under the buyer's Tax ID), skipped (Counta's own
-- sale to a buyer outside Counta), failed (could not be read; a person looks).
create table if not exists public.einvoice_inbound (
  id uuid primary key default gen_random_uuid(),
  irn text not null,
  org_id uuid references public.orgs(id) on delete cascade,
  state text not null default 'due' check (state in ('due', 'fetching', 'billed', 'confirmed', 'unmatched', 'skipped', 'failed')),
  tries int not null default 0,
  next_at timestamptz not null default now(),
  fetching_at timestamptz,
  note text,
  last_message text,
  supplier_name text,
  supplier_tin text,
  buyer_tin text,
  invoice_no text,
  invoice_type_code text,
  issue_date date,
  currency text,
  total numeric(18, 2),
  invoice jsonb,
  supplier_invoice_id uuid references public.supplier_invoices(id) on delete set null,
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists einvoice_inbound_irn on public.einvoice_inbound (irn);
create index if not exists einvoice_inbound_due on public.einvoice_inbound (next_at) where state in ('due', 'fetching', 'billed');
create index if not exists einvoice_inbound_org on public.einvoice_inbound (org_id, created_at desc) where org_id is not null;
create index if not exists einvoice_inbound_si on public.einvoice_inbound (supplier_invoice_id) where supplier_invoice_id is not null;
alter table public.einvoice_inbound enable row level security;
revoke all on public.einvoice_inbound from anon, authenticated;

alter table public.supplier_invoices drop constraint if exists supplier_invoices_source_check;
alter table public.supplier_invoices add constraint supplier_invoices_source_check check (source in ('portal', 'upload', 'nrs'));
alter table public.supplier_invoices add column if not exists nrs_irn text;
create unique index if not exists supplier_invoices_nrs_irn on public.supplier_invoices (org_id, nrs_irn) where nrs_irn is not null;

-- The Counta businesses an invoice to this Tax ID is for: those taking e-invoices, never a sample.
create or replace function private.einvoice_buyer_org(p_tin text) returns uuid
language sql stable security definer set search_path = public, private as $$
  select o.id from orgs o join einvoice_settings e on e.org_id = o.id
  where regexp_replace(coalesce(o.tin, ''), '[^0-9]', '', 'g') = regexp_replace(coalesce(p_tin, ''), '[^0-9]', '', 'g')
    and length(regexp_replace(coalesce(p_tin, ''), '[^0-9]', '', 'g')) >= 8
    and e.enabled and not coalesce(o.is_sample, false)
  order by o.created_at limit 1
$$;

-- A notification from NRS: kept, then it moves the sale it is about, and an invoice to a Counta business is fetched.
create or replace function public.svc_einvoice_webhook(p_irn text, p_message text, p_body jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_irn text := left(btrim(coalesce(p_irn, '')), 100); v_msg text := upper(left(btrim(coalesce(p_message, '')), 40));
  d public.einvoice_docs; s public.sales; v_sale uuid; v_in uuid; v_matched text := 'none'; v_buyer uuid; v_new boolean := false;
begin
  if v_irn !~ '^[A-Za-z0-9][A-Za-z0-9-]{6,99}$' then
    insert into einvoice_webhooks (irn, message, body, matched) values (nullif(v_irn, ''), nullif(v_msg, ''), p_body, 'invalid');
    return jsonb_build_object('ok', true, 'matched', 'invalid');
  end if;
  -- A sale Counta sent.
  select * into d from einvoice_docs where irn = v_irn and state = 'signed' order by signed_at desc limit 1 for update;
  if found then
    v_sale := d.sale_id; v_matched := 'sale';
    update einvoice_docs set
      xm_state = case
        when v_msg = 'ACKNOWLEDGED' then 'acknowledged'
        when v_msg = 'TRANSMITTED' and coalesce(xm_state, '') <> 'acknowledged' then 'transmitted'
        when v_msg = 'TRANSMITTING' and coalesce(xm_state, '') not in ('transmitted', 'acknowledged') then 'transmitting'
        when v_msg = 'FAILED' and coalesce(xm_state, '') not in ('transmitted', 'acknowledged') then 'failed'
        else xm_state end,
      xm_note = case when v_msg = 'FAILED' and coalesce(xm_state, '') not in ('transmitted', 'acknowledged')
        then 'NRS could not deliver it to the buyer''s access point.' when v_msg in ('TRANSMITTED', 'ACKNOWLEDGED') then null else xm_note end,
      xm_at = now(), updated_at = now()
    where sale_id = d.sale_id;
    if v_msg = 'FAILED' then
      select * into s from sales where id = d.sale_id;
      perform private.notify_perm(d.org_id, 'record_sales', 'einvoice_buyer', 'NRS could not deliver ' || s.number || ' to the buyer',
        'Open the sale to see why and send it again.', '/sell/sales?open=' || s.id, 'einvoice_buyer:' || s.id);
    end if;
  end if;
  -- An invoice to a Counta business: brought in, unless it is a sale Counta sent to a buyer outside Counta.
  if v_msg in ('TRANSMITTING', 'TRANSMITTED') then
    if v_sale is not null then
      select * into s from sales where id = v_sale;
      v_buyer := private.einvoice_buyer_org(s.customer_tin);
    end if;
    if v_sale is null or (v_buyer is not null and v_buyer <> d.org_id) then
      -- One NRS notifies about again after it could not be read is tried again at once.
      v_new := exists (select 1 from einvoice_inbound where irn = v_irn and state = 'failed');
      insert into einvoice_inbound (irn, org_id, last_message) values (v_irn, v_buyer, v_msg)
      on conflict (irn) do update set last_message = excluded.last_message, updated_at = now(),
        state = case when einvoice_inbound.state = 'failed' then 'due' else einvoice_inbound.state end,
        next_at = case when einvoice_inbound.state = 'failed' then now() else einvoice_inbound.next_at end,
        tries = case when einvoice_inbound.state = 'failed' then 0 else einvoice_inbound.tries end
      returning id, (xmax = 0) or v_new into v_in, v_new;
      v_matched := case when v_matched = 'sale' then 'both' else 'inbound' end;
    end if;
  elsif v_msg = 'ACKNOWLEDGED' then
    update einvoice_inbound set last_message = v_msg, updated_at = now() where irn = v_irn returning id into v_in;
  end if;
  insert into einvoice_webhooks (irn, message, body, matched, sale_id, inbound_id) values (v_irn, nullif(v_msg, ''), p_body, v_matched, v_sale, v_in);
  return jsonb_build_object('ok', true, 'matched', v_matched, 'sale_id', v_sale, 'inbound_id', v_in, 'fetch', v_in is not null and v_new);
end $$;

-- ---------------------------------------------------------------------------
-- 4. The queue: sending to buyers and invoices to bring in, with the sales and payments
-- ---------------------------------------------------------------------------
create or replace function public.svc_einvoice_due(p_limit int default 100) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('sale_id', x.sale_id, 'id', x.id, 'org_id', x.org_id, 'what', x.what) order by x.at), '[]'::jsonb)
  from (select * from (
      select d.sale_id, null::uuid id, d.org_id, 'send'::text what, d.next_try_at at from einvoice_docs d
      where (d.state = 'waiting' and d.next_try_at <= now()) or (d.state = 'sending' and d.sending_at < now() - interval '5 minutes')
      union all
      select d.sale_id, null, d.org_id, 'pay', d.pay_next_at from einvoice_docs d where d.state = 'signed' and d.pay_due is not null and d.pay_next_at <= now()
      union all
      select d.sale_id, null, d.org_id, 'transmit', d.xm_next_at from einvoice_docs d
      where d.state = 'signed' and d.xm_state in ('due', 'sending') and d.xm_next_at <= now()
      union all
      select null, i.id, i.org_id, 'inbound', i.next_at from einvoice_inbound i
      where (i.state in ('due', 'billed') and i.next_at <= now()) or (i.state = 'fetching' and i.fetching_at < now() - interval '5 minutes')
    ) y order by y.at limit greatest(least(coalesce(p_limit, 100), 500), 1)) x
$$;

-- Sending one sale to its buyer: what the function needs, and the sale marked as being sent (for ten minutes).
create or replace function public.svc_einvoice_xm_claim(p_sale uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.einvoice_docs; s public.sales;
begin
  select * into d from einvoice_docs where sale_id = p_sale for update;
  if not found then return jsonb_build_object('skip', 'gone'); end if;
  if d.state <> 'signed' or d.xm_state is null or d.xm_state not in ('due', 'sending') then return jsonb_build_object('skip', coalesce(d.xm_state, 'not to send')); end if;
  if d.xm_state = 'sending' and d.xm_next_at > now() then return jsonb_build_object('skip', 'busy'); end if;
  select * into s from sales where id = p_sale;
  update einvoice_docs set xm_state = 'sending', xm_tries = xm_tries + 1, xm_next_at = now() + interval '10 minutes', updated_at = now() where sale_id = p_sale;
  return jsonb_build_object('sale_id', p_sale, 'org_id', d.org_id, 'irn', d.irn, 'number', s.number, 'tries', d.xm_tries + 1,
    'buyer', s.customer_name, 'buyer_tin', s.customer_tin);
end $$;

-- What NRS said. outcome: sent (NRS took it; its notifications say the rest), retry (NRS down or busy, or the keys refused:
-- tried again later, then failed), wait (TaxStreem's APP keys are not set: tried again in half an hour, uncounted), failed
-- (NRS will not send it as it is).
create or replace function public.svc_einvoice_xm_done(p_sale uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.einvoice_docs; s public.sales; v_out text := p->>'outcome'; v_note text := left(nullif(p->>'note', ''), 600); v_wait interval;
begin
  select * into d from einvoice_docs where sale_id = p_sale for update;
  if not found or d.xm_state is distinct from 'sending' then return jsonb_build_object('ok', false, 'state', d.xm_state); end if;
  select * into s from sales where id = p_sale;
  if v_out = 'sent' then
    update einvoice_docs set xm_state = 'transmitting', xm_sent_at = now(), xm_note = null, xm_next_at = null, xm_at = now(), updated_at = now() where sale_id = p_sale;
  elsif v_out = 'wait' then
    update einvoice_docs set xm_state = 'due', xm_tries = greatest(xm_tries - 1, 0), xm_next_at = now() + interval '30 minutes', xm_note = v_note, updated_at = now()
    where sale_id = p_sale;
  elsif v_out = 'retry' and d.xm_tries < 6 then
    v_wait := case when d.xm_tries <= 1 then interval '1 minute' when d.xm_tries = 2 then interval '5 minutes' when d.xm_tries = 3 then interval '15 minutes'
                   when d.xm_tries = 4 then interval '30 minutes' else interval '1 hour' end;
    update einvoice_docs set xm_state = 'due', xm_next_at = now() + v_wait, xm_note = v_note, updated_at = now() where sale_id = p_sale;
  else
    update einvoice_docs set xm_state = 'failed', xm_next_at = null, xm_note = coalesce(v_note, 'NRS did not send it to the buyer.'), xm_at = now(), updated_at = now()
    where sale_id = p_sale;
    perform private.notify_perm(d.org_id, 'record_sales', 'einvoice_buyer', 'NRS could not deliver ' || s.number || ' to the buyer',
      left(coalesce(v_note, 'Open the sale to see why and send it again.'), 300), '/sell/sales?open=' || s.id, 'einvoice_buyer:' || s.id);
  end if;
  return jsonb_build_object('ok', true, 'state', (select xm_state from einvoice_docs where sale_id = p_sale));
end $$;

-- Someone who records sales sends one NRS could not deliver again (once the buyer has an access point, say).
create or replace function public.einvoice_send_to_buyer(p_sale uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; d public.einvoice_docs;
begin
  select * into s from sales where id = p_sale;
  if not found then raise exception 'Sale not found.'; end if;
  perform private.require(s.org_id, 'record_sales');
  select * into d from einvoice_docs where sale_id = p_sale for update;
  if not found or d.state <> 'signed' or d.kind <> 'clear' then raise exception 'Only a sale NRS signed for a business or government buyer goes to the buyer.'; end if;
  if d.xm_state in ('due', 'sending') then raise exception '% is on its way to the buyer already.', s.number; end if;
  if d.xm_state in ('transmitted', 'acknowledged') then raise exception 'The buyer''s access point has % already.', s.number; end if;
  update einvoice_docs set xm_state = 'due', xm_tries = 0, xm_next_at = now(), xm_note = null, xm_at = now(), updated_at = now() where sale_id = p_sale;
  perform private.call_function('einvoice', jsonb_build_object('action', 'send'));
  return private.sale_json(p_sale, private.can_see_costs(s.org_id));
end $$;

-- An invoice to bring in: downloading it (fetch), or telling NRS it arrived (confirm, once its bill is written).
create or replace function public.svc_einvoice_inbound_claim(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.einvoice_inbound;
begin
  select * into i from einvoice_inbound where id = p_id for update;
  if not found then return jsonb_build_object('skip', 'gone'); end if;
  if i.state = 'billed' then
    if i.next_at > now() then return jsonb_build_object('skip', 'later'); end if;
    update einvoice_inbound set tries = tries + 1, next_at = now() + interval '10 minutes', updated_at = now() where id = p_id;
    return jsonb_build_object('id', i.id, 'irn', i.irn, 'step', 'confirm', 'tries', i.tries + 1, 'org_id', i.org_id);
  end if;
  if not (i.state = 'due' or (i.state = 'fetching' and i.fetching_at < now() - interval '5 minutes')) then return jsonb_build_object('skip', i.state); end if;
  update einvoice_inbound set state = 'fetching', fetching_at = now(), tries = tries + 1, updated_at = now() where id = p_id;
  return jsonb_build_object('id', i.id, 'irn', i.irn, 'step', 'fetch', 'tries', i.tries + 1, 'org_id', i.org_id);
end $$;

-- The invoice NRS sent, read: kept, and the Counta business it is for found by the buyer's Tax ID. Answers what the bill
-- needs (the business's accounts and WHT types for the suggestions), or skip.
create or replace function public.svc_einvoice_inbound_match(p_id uuid, p_invoice jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.einvoice_inbound; v jsonb := coalesce(p_invoice, '{}'::jsonb); v_sup jsonb := coalesce(v->'accounting_supplier_party', '{}'::jsonb);
  v_buy jsonb := coalesce(v->'accounting_customer_party', '{}'::jsonb); v_org uuid; o public.orgs; v_day date;
begin
  select * into i from einvoice_inbound where id = p_id for update;
  if not found then return jsonb_build_object('skip', 'gone'); end if;
  begin v_day := nullif(v->>'issue_date', '')::date; exception when others then v_day := null; end;
  update einvoice_inbound set invoice = v, supplier_name = left(nullif(v_sup->>'party_name', ''), 200), supplier_tin = left(nullif(v_sup->>'tin', ''), 30),
    buyer_tin = left(nullif(v_buy->>'tin', ''), 30), invoice_type_code = left(nullif(v->>'invoice_type_code', ''), 10), issue_date = v_day,
    currency = left(nullif(upper(v->>'document_currency_code'), ''), 3), total = private.num(v->'legal_monetary_total'->>'payable_amount'),
    invoice_no = left(split_part(i.irn, '-', 1), 60), updated_at = now()
  where id = p_id;
  v_org := private.einvoice_buyer_org(v_buy->>'tin');
  if v_org is null then
    update einvoice_inbound set state = 'unmatched', org_id = null, fetching_at = null,
      note = 'No business on Counta takes e-invoices under the buyer''s Tax ID' || coalesce(' ending ' || right(regexp_replace(coalesce(v_buy->>'tin', ''), '[^0-9]', '', 'g'), 4), '') || '.',
      updated_at = now() where id = p_id;
    return jsonb_build_object('skip', 'unmatched');
  end if;
  -- Counta's own sale between two of its businesses: the seller's side is the sale, the buyer's this bill.
  if regexp_replace(coalesce(v_sup->>'tin', ''), '[^0-9]', '', 'g') = regexp_replace(coalesce((select tin from orgs where id = v_org), ''), '[^0-9]', '', 'g') then
    update einvoice_inbound set state = 'skipped', org_id = v_org, fetching_at = null, note = 'The business''s own sale.', updated_at = now() where id = p_id;
    return jsonb_build_object('skip', 'own sale');
  end if;
  select * into o from orgs where id = v_org;
  update einvoice_inbound set org_id = v_org where id = p_id;
  return jsonb_build_object('org_id', v_org, 'business', o.name, 'business_tin', o.tin,
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name) order by a.code), '[]'::jsonb)
      from (select code, name from accounts union select code, name from org_accounts where org_id = v_org) a
      where a.code ~ '^(5|6|15|12)' and private.bill_account_ok(v_org, a.code)),
    'wht', (select jsonb_agg(jsonb_build_object('code', code, 'name', name) order by sort) from wht_rates where not exemption and code <> 'none'),
    'states', (select coalesce(jsonb_object_agg(code, label), '{}'::jsonb) from nrs_codes where list = 'states'),
    'credit_note', coalesce((select code from nrs_codes where list = 'invoice-types' and lower(label) = 'credit note' limit 1), '380'));
end $$;

-- The supplier invoice and draft bill, from what was read off NRS's invoice (the same shape the invoice reader gives), and
-- the people who keep the books told. Written once per invoice.
create or replace function public.svc_einvoice_inbound_bill(p_id uuid, p_extract jsonb, p_path text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.einvoice_inbound; si public.supplier_invoices; v_checks jsonb; v_name text;
begin
  select * into i from einvoice_inbound where id = p_id for update;
  if not found or i.org_id is null then raise exception 'Invoice not found.'; end if;
  if i.supplier_invoice_id is not null then return private.si_json(i.supplier_invoice_id); end if;
  if coalesce(p_path, '') !~ ('^' || i.org_id::text || '/bills/nrs-[A-Za-z0-9-]+\.json$') then raise exception 'Keep NRS''s invoice in the business''s documents first.'; end if;
  select * into si from supplier_invoices where org_id = i.org_id and nrs_irn = i.irn;
  if not found then
    insert into supplier_invoices (org_id, number, source, document_path, mime, file_name, nrs_irn, submitter)
    values (i.org_id, 'SI-' || lpad(private.next_no(i.org_id, 'SI', 1)::text, 5, '0'), 'nrs', p_path, 'application/json', i.irn || '.json', i.irn,
      jsonb_build_object('name', i.supplier_name, 'note', 'Received through NRS e-invoicing, IRN ' || i.irn))
    returning * into si;
  end if;
  perform private.si_apply(si.id, p_extract, 'nrs', null);
  select * into si from supplier_invoices where id = si.id;
  if si.bill_id is not null then
    update bills set notes = 'Received through NRS e-invoicing · IRN ' || i.irn, vendor_ref = coalesce(vendor_ref, i.invoice_no) where id = si.bill_id;
  end if;
  update einvoice_inbound set state = 'billed', supplier_invoice_id = si.id, fetching_at = null, next_at = now(), tries = 0, note = null, updated_at = now() where id = p_id;
  select name into v_name from vendors where id = si.vendor_id;
  v_checks := coalesce(si.checks, '[]'::jsonb);
  perform private.notify_perm(si.org_id, 'keep_books', 'bill', 'Invoice from NRS to review: ' || coalesce(v_name, i.supplier_name, si.number),
    'Received through NRS e-invoicing'
      || coalesce(' · ' || nullif((select count(*)::text from jsonb_array_elements(v_checks) c where c->>'severity' in ('block', 'warn')), '0') || ' to look at', ''),
    '/purchases/bills?tab=invoices&open=' || si.id, 'si-' || si.id);
  return private.si_json(si.id);
end $$;

-- outcome: confirmed (NRS heard it arrived), retry (NRS down or busy: tried again, then failed), failed (could not be read).
create or replace function public.svc_einvoice_inbound_done(p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.einvoice_inbound; v_out text := p->>'outcome'; v_note text := left(nullif(p->>'note', ''), 600); v_wait interval; v_max int;
begin
  select * into i from einvoice_inbound where id = p_id for update;
  if not found then return jsonb_build_object('ok', false); end if;
  v_wait := case when i.tries <= 1 then interval '1 minute' when i.tries = 2 then interval '5 minutes' when i.tries = 3 then interval '15 minutes'
                 when i.tries = 4 then interval '30 minutes' else interval '1 hour' end;
  -- Telling NRS it arrived is tried longer: the bill is written either way.
  v_max := case when i.state = 'billed' then 10 else 6 end;
  if v_out = 'confirmed' and i.state = 'billed' then
    update einvoice_inbound set state = 'confirmed', confirmed_at = now(), next_at = now(), note = null, updated_at = now() where id = p_id;
  elsif v_out = 'retry' and i.tries < v_max then
    update einvoice_inbound set state = case when i.state = 'billed' then 'billed' else 'due' end, fetching_at = null, next_at = now() + v_wait, note = v_note, updated_at = now()
    where id = p_id;
  elsif i.state = 'billed' then
    update einvoice_inbound set note = coalesce(v_note, 'NRS did not hear that the invoice arrived.'), next_at = now() + interval '1 day', updated_at = now() where id = p_id;
  else
    update einvoice_inbound set state = 'failed', fetching_at = null, note = coalesce(v_note, 'The invoice could not be brought in.'), updated_at = now() where id = p_id;
  end if;
  return jsonb_build_object('ok', true, 'state', (select state from einvoice_inbound where id = p_id));
end $$;

-- ---------------------------------------------------------------------------
-- 5. What the sale shows, and Settings
-- ---------------------------------------------------------------------------
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
    'org', private.org_brand(s.org_id),
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

create or replace function private.einvoice_queue(p_org uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object(
    'waiting', (select count(*) from einvoice_docs where org_id = p_org and state in ('waiting', 'sending')),
    'oldest_at', (select min(created_at) from einvoice_docs where org_id = p_org and state in ('waiting', 'sending')),
    'signed_today', (select count(*) from einvoice_docs where org_id = p_org and state = 'signed' and signed_at >= date_trunc('day', now())),
    'signed', (select count(*) from einvoice_docs where org_id = p_org and state = 'signed'),
    'refused', (select count(*) from einvoice_docs where org_id = p_org and state = 'refused'),
    'pay_waiting', (select count(*) from einvoice_docs where org_id = p_org and pay_due is not null),
    'to_buyers', jsonb_build_object(
      'sending', (select count(*) from einvoice_docs where org_id = p_org and xm_state in ('due', 'sending', 'transmitting')),
      'delivered', (select count(*) from einvoice_docs where org_id = p_org and xm_state in ('transmitted', 'acknowledged')),
      'acknowledged', (select count(*) from einvoice_docs where org_id = p_org and xm_state = 'acknowledged'),
      'failed', (select count(*) from einvoice_docs where org_id = p_org and xm_state = 'failed')),
    'received', jsonb_build_object(
      'total', (select count(*) from einvoice_inbound where org_id = p_org and state in ('billed', 'confirmed')),
      'to_review', (select count(*) from einvoice_inbound i join supplier_invoices si on si.id = i.supplier_invoice_id
                    where i.org_id = p_org and si.status = 'review'),
      'failed', (select count(*) from einvoice_inbound where org_id = p_org and state = 'failed')),
    'attention', (select coalesce(jsonb_agg(y.x order by y.x->>'at' desc), '[]'::jsonb) from (
        select z.x from (
          select jsonb_build_object('sale_id', d.sale_id, 'number', s.number, 'doc_type', s.doc_type, 'customer_name', s.customer_name, 'total', s.total,
            'state', d.state, 'held', d.held, 'note', d.note, 'tries', d.tries, 'at', d.updated_at) x
          from einvoice_docs d join sales s on s.id = d.sale_id
          where d.org_id = p_org and (d.state = 'refused' or (d.state in ('waiting', 'sending') and (d.tries >= 3 or d.created_at < now() - interval '1 hour')))
          union all
          -- Signed, but NRS could not deliver it to the buyer.
          select jsonb_build_object('sale_id', d.sale_id, 'number', s.number, 'doc_type', s.doc_type, 'customer_name', s.customer_name, 'total', s.total,
            'state', 'not_delivered', 'held', false, 'note', d.xm_note, 'tries', d.xm_tries, 'at', d.xm_at)
          from einvoice_docs d join sales s on s.id = d.sale_id
          where d.org_id = p_org and d.xm_state = 'failed') z
        order by z.x->>'at' desc limit 20) y))
$$;

-- The five-minute tick asks the function whenever anything is due: sales, payments, buyers, invoices to bring in.
create or replace function private.einvoice_tick() returns void
language plpgsql security definer set search_path = public, private as $$
declare r record; v_h int;
begin
  if exists (select 1 from items i join einvoice_settings s on s.org_id = i.org_id
             where i.hs_checked_at is null and not i.archived and coalesce(i.hs_basis->>'source', '') <> 'manual')
     or exists (select 1 from einvoice_settings where service_checked_at is null and coalesce(service_basis->>'source', '') <> 'manual') then
    perform private.call_function('ai', jsonb_build_object('action', 'nrs_codes_pending'));
  end if;
  if exists (select 1 from einvoice_docs where (state = 'waiting' and next_try_at <= now()) or (state = 'sending' and sending_at < now() - interval '5 minutes')
             or (state = 'signed' and pay_due is not null and pay_next_at <= now())
             or (state = 'signed' and xm_state in ('due', 'sending') and xm_next_at <= now()))
     or exists (select 1 from einvoice_inbound where (state in ('due', 'billed') and next_at <= now()) or (state = 'fetching' and fetching_at < now() - interval '5 minutes')) then
    perform private.call_function('einvoice', jsonb_build_object('action', 'send'));
  end if;
  for r in select d.org_id, min(d.created_at) oldest, count(*) filter (where d.created_at < now() - interval '12 hours') n12,
             count(*) filter (where d.created_at < now() - interval '20 hours') n20
           from einvoice_docs d where d.state in ('waiting', 'sending')
           group by d.org_id having min(d.created_at) < now() - interval '12 hours' loop
    v_h := case when r.oldest < now() - interval '20 hours' then 20 else 12 end;
    perform private.alert_send(r.org_id, 'einvoice_late', v_h || 'h:' || to_char(r.oldest, 'YYYYMMDDHH24MISS'), array['push', 'email'], jsonb_build_object(
      'perm', 'manage_settings', 'url', '/settings#einvoicing',
      'title', case when (case when v_h = 20 then r.n20 else r.n12 end) = 1 then 'A sale has waited '
        else (case when v_h = 20 then r.n20 else r.n12 end) || ' sales have waited ' end || v_h || ' hours to reach NRS',
      'body', 'NRS expects each sale within 24 hours. Counta keeps trying; open E-invoicing in Settings to see why they are waiting.'));
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 6. The admin portal: the webhook address and what NRS has sent to it
-- ---------------------------------------------------------------------------
create or replace function public.admin_einvoice_webhook() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_staff();
  return jsonb_build_object('path', '/functions/v1/einvoice/nrs-hook/' || coalesce(public.svc_einvoice_hook_token(), ''),
    'last', (select jsonb_build_object('at', w.at, 'message', w.message, 'matched', w.matched) from einvoice_webhooks w order by w.at desc limit 1),
    'today', (select count(*) from einvoice_webhooks where at >= now() - interval '24 hours'),
    'to_buyers', (select count(*) from einvoice_docs where xm_state in ('transmitted', 'acknowledged')),
    'received', (select count(*) from einvoice_inbound where state in ('billed', 'confirmed')));
end $$;

-- The APP key and secret are needed now (the exchange), and the admin portal says where they come from. As of 31 October,
-- with only those two entries changed.
create or replace function private.secret_catalog() returns table (name text, grp text, label text, secret boolean, hint text, sort int)
language sql immutable as $$
  values
    ('GOOGLE_APPLICATION_CREDENTIALS_JSON', 'gemini', 'Service account key (JSON)', true, 'A Google Cloud service account with the Vertex AI User role. Paste the whole key file.', 101),
    ('GOOGLE_CLOUD_PROJECT', 'gemini', 'Google Cloud project', false, 'Leave empty to use the key''s own project.', 102),
    ('GOOGLE_CLOUD_LOCATION', 'gemini', 'Vertex AI region', false, 'us-central1 unless the project uses another region.', 103),
    ('GEMINI_MODEL', 'gemini', 'Gemini model', false, 'Leave empty for gemini-3.8-flash.', 104),
    ('GEMINI_API_KEY', 'gemini', 'Gemini API key (fallback)', true, 'Only used when there is no service account key.', 105),
    ('ELEVENLABS_API_KEY', 'elevenlabs', 'API key', true, 'Needs access to text to speech, voices, agents and phone numbers.', 201),
    ('ELEVENLABS_PHONE_NUMBER_ID', 'elevenlabs', 'Phone number for calls', false, 'Only needed when ElevenLabs has more than one number. The id from Phone Numbers in ElevenLabs.', 202),
    ('ELEVENLABS_TTS_MODEL', 'elevenlabs', 'Voice model for announcements', false, 'Leave empty for eleven_flash_v2_5.', 203),
    ('FLW_SECRET_KEY', 'flutterwave', 'Secret key', true, 'From Flutterwave, Settings, API keys. Live keys start FLWSECK-.', 301),
    ('FLW_PUBLIC_KEY', 'flutterwave', 'Public key', false, 'From the same page. Starts FLWPUBK-.', 302),
    ('FLW_WEBHOOK_HASH', 'flutterwave', 'Webhook secret hash', true, 'The same value as Secret hash in Flutterwave''s webhook settings.', 303),
    ('FLW_RELAY_URL', 'flutterwave', 'Transfer relay address', false, 'The https address of TaxStreem''s transfer relay (the server with the fixed IP address whitelisted on Flutterwave).', 304),
    ('FLW_RELAY_SECRET', 'flutterwave', 'Transfer relay secret', true, 'The 64 characters after RELAY_SECRET= in /etc/counta-relay.env on the relay server. Signs every request Counta sends through it.', 305),
    ('FLW_MERCHANT_ID', 'flutterwave', 'TaxStreem merchant ID', false, 'TaxStreem''s own Flutterwave merchant ID (Flutterwave, Settings, Business preferences). Counta plans paid from a business''s wallet go to this account.', 306),
    ('MONO_SECRET_KEY', 'mono', 'Secret key', true, 'From the Mono dashboard, for bank feeds.', 401),
    ('MONO_PUBLIC_KEY', 'mono', 'Public key', false, 'From the same app in the Mono dashboard.', 402),
    ('MONO_WEBHOOK_SECRET', 'mono', 'Webhook secret', true, 'The same value as the webhook secret in the Mono dashboard.', 403),
    ('MONO_LOOKUP_SECRET_KEY', 'mono', 'Lookup key (optional)', true, 'A separate key for CAC, Tax ID and NIN lookups. Without it the secret key is used.', 404),
    ('RESEND_API_KEY', 'email', 'Resend API key', true, 'From Resend, API keys, with sending access.', 501),
    ('RESEND_FROM', 'email', 'Sending address', false, 'An address on the domain verified in Resend, such as billing@taxstreem.com. Customers see "Business name via Counta".', 502),
    ('WHATSAPP_TOKEN', 'whatsapp', 'Access token', true, 'A permanent system user token from Meta Business, with WhatsApp messaging access.', 601),
    ('WHATSAPP_PHONE_NUMBER_ID', 'whatsapp', 'Phone number id', false, 'From WhatsApp, API setup, in the Meta app.', 602),
    ('WHATSAPP_BUSINESS_ACCOUNT_ID', 'whatsapp', 'Business account id', false, 'From the same page.', 603),
    ('WHATSAPP_APP_SECRET', 'whatsapp', 'App secret', true, 'From the Meta app''s basic settings. Checks that webhooks come from Meta.', 604),
    ('WHATSAPP_VERIFY_TOKEN', 'whatsapp', 'Webhook verify token', true, 'Any long random text, entered in the same place in the Meta app.', 605),
    ('WHATSAPP_TEMPLATE_LANG', 'whatsapp', 'Template language', false, 'en unless the message templates were approved in another language.', 606),
    ('WHATSAPP_PROVIDER', 'openwa', 'Which WhatsApp sends', false, 'openwa sends everything from TaxStreem''s number on the OpenWA server; meta uses the official WhatsApp Business API above. Leave empty for openwa once OpenWA is connected.', 650),
    ('OPENWA_URL', 'openwa', 'OpenWA server address', false, 'The https address of TaxStreem''s OpenWA server, such as https://wa.taxstreem.com.', 651),
    ('OPENWA_API_KEY', 'openwa', 'OpenWA API key', true, 'An Operator key made in the OpenWA dashboard, under API keys. Not the admin key.', 652),
    ('OPENWA_WEBHOOK_SECRET', 'openwa', 'Webhook secret', true, 'Counta makes this when you press Connect, and gives it to OpenWA. It proves that messages arriving at Counta came from your server.', 653),
    ('OPENWA_BUSINESS_NUMBERS', 'openwa', 'Businesses may link their own number', false, 'on lets businesses link their own WhatsApp number on the Integrations page, so their invoices come from it. Each linked number uses about 400 MB on the server. Leave empty for off.', 654),
    ('NUMENS_API_URL', 'numens', 'Numens address', false, 'The https address of TaxStreem''s tax model.', 701),
    ('NUMENS_API_KEY', 'numens', 'Numens key', true, null, 702),
    ('TAXSTREEM_SSO_SECRET', 'taxstreem', 'Single sign-on secret', true, 'Shared with TaxStreem, to sign people in from their TaxStreem account.', 801),
    ('TAXSTREEM_SSO_ISSUER', 'taxstreem', 'Single sign-on issuer', false, 'Leave empty for taxstreem.', 802),
    ('FLUX_URL', 'taxstreem', 'Flux address', false, 'The https address of TaxStreem Flux, which files returns on Rev360.', 803),
    ('FLUX_SECRET', 'taxstreem', 'Flux secret', true, 'Signs what Counta sends to Flux and checks what Flux sends back.', 804),
    ('FLUX_FILE_HOSTS', 'taxstreem', 'Flux file hosts', false, 'Other hosts Flux''s file links may point to, comma separated, such as files.taxstreem.com. Links on the Flux address itself are always allowed. Leave empty if Flux sends files only from there.', 805),
    ('APP_URL', 'counta', 'Counta web address', false, 'Used in links in emails and messages. Leave empty for https://counta-taxstreem.netlify.app.', 901),
    ('VAPID_SUBJECT', 'counta', 'Contact for push notifications', false, 'mailto: and an address browsers may write to about notifications.', 902),
    ('KYC_REVIEW_EMAIL', 'counta', 'Email for NIN slip reviews', false, 'Where Counta writes when a business''s NIN slip needs checking. Leave empty for admin@taxstreem.com. Reviewers on the Team page are told as well.', 903),
    ('NRS_BASE_URL', 'nrs', 'NRS e-invoicing address', false, 'The base address on the NRS e-invoicing dashboard (sandbox first, production after NRS''s review), such as https://… with nothing after the host.', 1001),
    ('NRS_API_KEY', 'nrs', 'API key', true, 'From the NRS e-invoicing dashboard. Sent as x-api-key.', 1002),
    ('NRS_API_SECRET', 'nrs', 'API secret', true, 'From the same page. Sent as x-api-secret.', 1003),
    ('NRS_BUSINESS_ID', 'nrs', 'TaxStreem''s Business ID', false, 'The Business ID NRS gave TaxStreem Technologies Limited when it was enabled for e-invoicing.', 1004),
    ('NRS_SERVICE_ID', 'nrs', 'TaxStreem''s Service ID', false, 'The 8-character Service ID NRS gave TaxStreem. It is the middle part of every IRN.', 1005),
    ('NRS_CRYPTO_KEYS', 'nrs', 'QR code keys (crypto_keys.txt)', true, 'The whole contents of crypto_keys.txt from My Account, Manage Cryptographic Keys: the public key and certificate the QR code is made with.', 1006),
    ('NRS_APP_API_KEY', 'nrs', 'APP API key', true, 'TaxStreem''s access point key, from NRS''s APP portal (einvoice.nrs.gov.ng/access-point), Developer section. Sends invoices to buyers and brings in invoices for businesses. Until it is set, the dashboard key above is tried.', 1007),
    ('NRS_APP_API_SECRET', 'nrs', 'APP API secret', true, 'The secret that goes with the APP key, from the same page.', 1008),
    ('GOOGLE_KMS_KEY_RING', 'kms', 'Key ring', false, 'Leave empty for projects/<project>/locations/us-central1/keyRings/counta-einvoice. It holds nrs-credentials (encrypt and decrypt) and invoice-signing (EC P-256, SHA-256), both HSM keys. The service account in Google Gemini above signs in, with Cloud KMS CryptoKey Encrypter/Decrypter on the first key and Signer/Verifier on the second.', 1101)
$$;

-- ---------------------------------------------------------------------------
-- 7. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function public.svc_einvoice_hook_token(), public.svc_einvoice_webhook(text, text, jsonb), public.svc_einvoice_due(int),
  public.svc_einvoice_xm_claim(uuid), public.svc_einvoice_xm_done(uuid, jsonb), public.svc_einvoice_inbound_claim(uuid),
  public.svc_einvoice_inbound_match(uuid, jsonb), public.svc_einvoice_inbound_bill(uuid, jsonb, text), public.svc_einvoice_inbound_done(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.svc_einvoice_hook_token(), public.svc_einvoice_webhook(text, text, jsonb), public.svc_einvoice_due(int),
  public.svc_einvoice_xm_claim(uuid), public.svc_einvoice_xm_done(uuid, jsonb), public.svc_einvoice_inbound_claim(uuid),
  public.svc_einvoice_inbound_match(uuid, jsonb), public.svc_einvoice_inbound_bill(uuid, jsonb, text), public.svc_einvoice_inbound_done(uuid, jsonb)
  to service_role;
revoke all on function public.einvoice_send_to_buyer(uuid), public.admin_einvoice_webhook() from public, anon;
grant execute on function public.einvoice_send_to_buyer(uuid), public.admin_einvoice_webhook() to authenticated;
revoke all on function private.on_einvoice_signed_send(), private.einvoice_buyer_org(text) from public, anon, authenticated;
