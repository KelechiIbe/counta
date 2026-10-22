-- Counta · Bujeti
--
-- A business that pays its suppliers, staff and subscriptions through Bujeti connects its Bujeti API key (read scopes only),
-- and Counta keeps its books from it:
--   Spending: every settled naira payment since 1 January 2026 (or the day the books start, if later) becomes a line in a
--     "Bujeti balance" account in Banking, with Bujeti's fee as a line of its own, booked to Bank charges. Bujeti's categories
--     are mapped once to Counta accounts: Counta suggests an account for each, a person confirms it, and from then on payments
--     in that category post on their own (or settle a bill Counta already has for that supplier). Payments in a category not
--     yet confirmed wait; payments with no category go through the same matching as bank lines.
--   Receipts: the receipts people attached in Bujeti are kept in Documents (Bank / Bujeti receipts).
--   Balances: Bujeti's balance is the account's "bank said" figure in Banking, so the books can be reconciled to it.
--   Vendors: Bujeti's vendors become Counta suppliers (matched by name first, so nobody is added twice).
--   Invoices: invoices sent from Bujeti become Counta invoices; when Bujeti marks one paid, the payment goes into the
--     Bujeti balance account.
--   Money the business sends to Bujeti from a bank account Counta already has (or takes back) is matched as a transfer.
-- Dollar payments and invoices are listed for recording by hand, as for the other tools. Bujeti's API has no notifications,
-- so Counta looks every fifteen minutes.

-- ---------------------------------------------------------------------------
-- 1. Bujeti among the tools
-- ---------------------------------------------------------------------------
alter table public.integrations drop constraint if exists integrations_provider_check;
alter table public.integrations add constraint integrations_provider_check
  check (provider in ('paystack', 'flutterwave', 'selar', 'woocommerce', 'shopify', 'zapier', 'bumpa', 'slack', 'bujeti'));
alter table public.documents drop constraint if exists documents_source_check;
alter table public.documents add constraint documents_source_check check (source in ('upload', 'flux', 'bujeti'));

-- Bujeti's expense categories, and the Counta account each posts to once a person has confirmed it.
create table if not exists public.bujeti_categories (
  org_id uuid not null references public.orgs(id) on delete cascade,
  code text not null check (length(code) between 4 and 60),
  name text not null check (length(name) between 1 and 120),
  parent_name text check (parent_name is null or length(parent_name) <= 120),
  suggested_code text,
  account_code text,
  confirmed_by uuid references public.members(id) on delete set null,
  confirmed_at timestamptz,
  seen_at timestamptz not null default now(),
  primary key (org_id, code)
);
create index if not exists bujeti_categories_confirmed_by on public.bujeti_categories(confirmed_by);
alter table public.bujeti_categories enable row level security;
revoke all on public.bujeti_categories from anon, authenticated;

-- What Counta did with each Bujeti payment, invoice and vendor.
--   payment: pending (not settled in Bujeti yet), waiting (its category is not confirmed), recorded (in Banking), skipped, failed
--   invoice: recorded (a Counta invoice), skipped, failed
--   vendor:  recorded (linked to a Counta supplier)
create table if not exists public.bujeti_items (
  org_id uuid not null references public.orgs(id) on delete cascade,
  kind text not null check (kind in ('payment', 'invoice', 'vendor')),
  code text not null check (length(code) between 4 and 60),
  status text not null check (status in ('pending', 'waiting', 'recorded', 'skipped', 'failed')),
  bujeti_status text check (bujeti_status is null or length(bujeti_status) <= 40),
  category_code text,
  amount numeric(16,2),
  fee numeric(16,2),
  currency text,
  occurred_on date,
  bank_line_id uuid references public.bank_lines(id) on delete set null,
  fee_line_id uuid references public.bank_lines(id) on delete set null,
  reversal_line_id uuid references public.bank_lines(id) on delete set null,
  sale_id uuid references public.sales(id) on delete set null,
  collection_id uuid references public.collections(id) on delete set null,
  vendor_id uuid references public.vendors(id) on delete set null,
  message text check (message is null or length(message) <= 400),
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (org_id, kind, code)
);
create index if not exists bujeti_items_status on public.bujeti_items(org_id, kind, status);
create index if not exists bujeti_items_category on public.bujeti_items(org_id, category_code) where kind = 'payment';
create index if not exists bujeti_items_line on public.bujeti_items(bank_line_id);
create index if not exists bujeti_items_fee_line on public.bujeti_items(fee_line_id);
create index if not exists bujeti_items_rev_line on public.bujeti_items(reversal_line_id);
create index if not exists bujeti_items_sale on public.bujeti_items(sale_id);
create index if not exists bujeti_items_collection on public.bujeti_items(collection_id);
create index if not exists bujeti_items_vendor on public.bujeti_items(vendor_id);
alter table public.bujeti_items enable row level security;
revoke all on public.bujeti_items from anon, authenticated;

-- The tools' names, the ones a business may connect, and the account each keeps its money in (Bujeti's: "Bujeti balance").
create or replace function private.integration_name(p text) returns text
language sql immutable set search_path = '' as $$
  select case p when 'paystack' then 'Paystack' when 'flutterwave' then 'Flutterwave' when 'selar' then 'Selar' when 'woocommerce' then 'WooCommerce'
    when 'shopify' then 'Shopify' when 'zapier' then 'Zapier or Make' when 'bumpa' then 'Bumpa' when 'slack' then 'Slack' when 'bujeti' then 'Bujeti' else p end
$$;

create or replace function public.integration_check(p_org uuid, p_provider text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, 'manage_settings');
  if (select is_sample from orgs where id = p_org) then raise exception 'The sample business cannot connect tools. Use your own business.'; end if;
  if p_provider not in ('paystack', 'flutterwave', 'selar', 'woocommerce', 'shopify', 'zapier', 'bumpa', 'slack', 'bujeti') then raise exception 'Unknown tool.'; end if;
  return jsonb_build_object('member_id', m.id, 'org_id', p_org, 'org_name', (select name from orgs where id = p_org),
    'existing', (select private.integration_json(i) from integrations i where i.org_id = p_org and i.provider = p_provider and i.status <> 'disconnected'));
end $$;

create or replace function private.integration_account(i public.integrations, p_author uuid) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare b public.bank_accounts;
begin
  if i.bank_account_id is not null and exists (select 1 from bank_accounts where id = i.bank_account_id and active) then return i.bank_account_id; end if;
  select * into b from bank_accounts where org_id = i.org_id and provider = 'integration' and provider_ref = i.org_id::text || ':' || i.provider;
  if not found then
    b := private.open_bank_account(i.org_id, 'wallet', private.integration_name(i.provider) || case when i.provider in ('paystack', 'flutterwave', 'selar', 'bujeti') then ' balance' else ' payments' end,
      jsonb_build_object('provider', 'integration', 'provider_ref', i.org_id::text || ':' || i.provider, 'provider_meta', jsonb_build_object('integration', i.provider)), p_author);
  elsif not b.active then
    update bank_accounts set active = true where id = b.id;
  end if;
  update integrations set bank_account_id = b.id where id = i.id;
  return b.id;
end $$;

-- Connections the poll looks at: payments and stores every few minutes, Slack with something to post, Bujeti every fifteen.
create or replace function public.svc_integrations_due() returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'provider', i.provider, 'org_id', i.org_id) order by i.last_sync_at nulls first), '[]'::jsonb)
  from integrations i where i.status in ('active', 'error')
    and (i.provider in ('paystack', 'flutterwave', 'woocommerce', 'shopify', 'slack') or (i.provider in ('bumpa', 'bujeti') and i.secret_id is not null))
    and (i.last_sync_at is null or i.last_sync_at < now() - case when i.provider = 'bujeti' then interval '14 minutes' else interval '4 minutes' end)
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'counta-integrations';
    perform cron.schedule('counta-integrations', '*/5 * * * *', $c$select private.call_function('integrations', '{"action":"poll"}'::jsonb)
      where exists (select 1 from public.integrations where status in ('active', 'error')
        and (provider in ('paystack', 'flutterwave', 'woocommerce', 'shopify', 'slack') or (provider in ('bumpa', 'bujeti') and secret_id is not null)))$c$);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------
-- The Bujeti connection and balance account of a business.
create or replace function private.bujeti_conn(p_org uuid) returns public.integrations
language sql stable security definer set search_path = public, private as $$
  select * from integrations where org_id = p_org and provider = 'bujeti' and status <> 'disconnected' order by connected_at desc limit 1
$$;
create or replace function private.bujeti_bank(p_org uuid) returns public.bank_accounts
language sql stable security definer set search_path = public, private as $$
  select * from bank_accounts where org_id = p_org and provider = 'integration' and provider_ref = p_org::text || ':bujeti' order by created_at limit 1
$$;

-- The first day Counta takes from Bujeti: 1 January 2026, or the day the books start if that is later.
create or replace function private.bujeti_start(p_org uuid) returns date
language sql stable security definer set search_path = public, private as $$
  select greatest(date '2026-01-01', coalesce((select books_start from orgs where id = p_org), date '2026-01-01'))
$$;

-- What a Bujeti payment's status means for the books. Bujeti does not publish the list, so the usual words are read.
create or replace function private.bujeti_class(p_status text) returns text
language sql immutable set search_path = '' as $$
  select case
    when s ~ '(revers|refund)' then 'reversed'
    when s ~ '(fail|declin|cancel|reject|expire|abandon|void)' then 'failed'
    when s ~ '^(success|successful|succeeded|completed?|approved|paid|processed|done|settled)$' then 'settled'
    when s ~ '(pend|process|queue|progress|initiat|schedul|await|review|hold)' or s = '' then 'pending'
    else 'unknown' end
  from (select lower(trim(coalesce(p_status, ''))) s) x
$$;

-- An invoice's status: draft (never recorded), void, paid or open.
create or replace function private.bujeti_invoice_class(p_status text) returns text
language sql immutable set search_path = '' as $$
  select case
    when s ~ 'draft' then 'draft'
    when s ~ '(cancel|void|delet|declin|reject|archiv)' then 'void'
    when s ~ '(partial|unpaid|not.?paid)' then 'open'
    when s ~ '(paid|complete|settled|success)' then 'paid'
    else 'open' end
  from (select lower(trim(coalesce(p_status, ''))) s) x
$$;

-- The Counta account Counta suggests for a Bujeti category, from its name (and its parent's): one the business can post to.
create or replace function private.bujeti_suggest(p_org uuid, p_name text, p_parent text default null) returns text
language plpgsql stable security definer set search_path = public, private as $$
declare s text := lower(coalesce(p_name, '') || ' ' || coalesce(p_parent, '')); v text;
begin
  v := case
    when s ~ '(bank charge|bank fee|transfer fee|charges|commission|stamp duty)' then '6701'
    when s ~ '(salar|payroll|wage|staff pay)' then '6101'
    when s ~ 'allowance' then '6102'
    when s ~ 'pension' then '6104'
    when s ~ '(medical|health|hmo|hospital|pharma|drug)' then '6106'
    when s ~ '(training|course|learning|conference|seminar|workshop)' then '6107'
    when s ~ '(welfare|staff meal|lunch|meal|food|refreshment|groceries)' then '6108'
    when s ~ '(contractor|freelanc|outsourc)' then '6112'
    when s ~ '(recruit|hiring)' then '6113'
    when s ~ 'service charge' then '6203'
    when s ~ '(rent|lease|office space|cowork)' then '6201'
    when s ~ '(water|sewage)' then '6204'
    when s ~ '(electric|power|prepaid meter|nepa|phcn|disco)' then '6205'
    when s ~ '(diesel|\yago\y)' then '6206'
    when s ~ '(fuel|petrol|\ypms\y|gas station|filling)' then '6207'
    when s ~ 'generator' then '6208'
    when s ~ '(repair|maintenance|fix)' then '6209'
    when s ~ '(clean|janitor|fumigat)' then '6210'
    when s ~ '(security|guard)' then '6211'
    when s ~ '(stationer|printing|print)' then '6212'
    when s ~ '(postage|courier|dhl|gig logistics)' then '6213'
    when s ~ 'insurance' then '6215'
    when s ~ '(office suppl|consumable|supplies|toiletr)' then '6216'
    when s ~ '(airtime|telephone|phone|call|mobile)' then '6301'
    when s ~ '(internet|\ydata\y|wifi|broadband|starlink)' then '6302'
    when s ~ '(software|subscription|saas|cloud|hosting|aws|google workspace|microsoft|zoom|slack|notion|figma|license fee|app store)' then '6303'
    when s ~ '(website|domain)' then '6304'
    when s ~ '(\yit\y|hardware|computer|laptop|gadget)' then '6305'
    when s ~ '(advert|marketing|\yads?\y|facebook|instagram|promotion|campaign|influencer|branding)' then '6401'
    when s ~ '(entertain|hospitality|client)' then '6409'
    when s ~ '(gift|souvenir|hamper)' then '6410'
    when s ~ 'audit' then '6501'
    when s ~ '(accounting|bookkeep|tax filing)' then '6502'
    when s ~ '(legal|lawyer|attorney|solicitor)' then '6503'
    when s ~ 'consult' then '6504'
    when s ~ '(\ycac\y|registration|filing|corporate affairs)' then '6506'
    when s ~ '(professional)' then '6507'
    when s ~ '(licen[cs]e|permit)' then '6509'
    when s ~ '(dues|membership)' then '6510'
    when s ~ '(international|foreign|abroad)' and s ~ '(travel|flight|trip)' then '6603'
    when s ~ '(hotel|accommodation|lodging|airbnb)' then '6604'
    when s ~ '(travel|flight|airfare|air ticket|trip)' then '6602'
    when s ~ '(freight|haulage|cargo|clearing)' then '6606'
    when s ~ '(vehicle|fleet|car )' then '6605'
    when s ~ '(transport|uber|bolt|taxi|ride|logistics|delivery|dispatch)' then '6601'
    when s ~ 'interest' then '6702'
    when s ~ '(donation|charity|csr)' then '6904'
    when s ~ '(inventory|stock|purchase|goods|raw material|materials|merchandise)' then '5101'
    else '6907' end;
  if private.postable(p_org, v) then return v; end if;
  -- The business keeps sub-accounts under it: the first that takes postings.
  select a.code into v from private.accounts_of(p_org) a where a.parent_code = v and a.active and not a.is_group and private.postable(p_org, a.code) order by a.code limit 1;
  if v is not null then return v; end if;
  return case when private.postable(p_org, '6907') then '6907' end;
end $$;

-- The accounts a Bujeti category may post to: what the books inbox offers for a payment (not the bank, the receivables or
-- the tax heads, which other parts of Counta keep).
create or replace function private.bujeti_accounts(p_org uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name, 'category', a.category)
    order by case a.category when 'Expenses' then 0 when 'Cost of Sales' then 1 else 2 end, a.code), '[]'::jsonb)
  from private.accounts_of(p_org) a
  where a.active and not a.is_group and private.postable(p_org, a.code)
    and a.code !~ '^(101|1101|1102|1203|1201|1202|2101|2102|2201|1402|1401|2202|9)'
$$;

-- A Bujeti vendor as a Counta supplier: the one already linked, one with the same name or email, or a new one.
-- v: {code, name, email, type, status}
create or replace function private.bujeti_vendor(p_org uuid, v jsonb) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare v_code text := nullif(left(trim(v->>'code'), 60), ''); v_name text := nullif(left(trim(regexp_replace(coalesce(v->>'name', ''), '\s+', ' ', 'g')), 120), '');
  v_email text := nullif(lower(trim(v->>'email')), ''); v_id uuid; v_new boolean := false;
begin
  if v_code is null or length(v_code) < 4 or v_name is null then return null; end if;
  if v_email is not null and v_email !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' then v_email := null; end if;
  select it.vendor_id into v_id from bujeti_items it join vendors vv on vv.id = it.vendor_id where it.org_id = p_org and it.kind = 'vendor' and it.code = v_code;
  if v_id is null then
    select id into v_id from vendors where org_id = p_org and lower(trim(name)) = lower(v_name) order by created_at limit 1;
    if v_id is null and v_email is not null then select id into v_id from vendors where org_id = p_org and lower(email) = v_email order by created_at limit 1; end if;
    if v_id is null and lower(coalesce(v->>'status', 'active')) !~ '(inactive|delet|archiv|block|disabl)' then
      insert into vendors (org_id, name, email, channel, is_individual, notes)
      values (p_org, v_name, v_email, case when v_email is not null then 'email' else 'whatsapp' end, lower(coalesce(v->>'type', '')) = 'individual', 'Added from Bujeti')
      returning id into v_id;
      v_new := true;
    end if;
    if v_id is not null then
      insert into bujeti_items (org_id, kind, code, status, vendor_id, data, message)
      values (p_org, 'vendor', v_code, 'recorded', v_id, jsonb_build_object('name', v_name), case when v_new then 'Added as a supplier' else 'Linked to a supplier Counta had' end)
      on conflict (org_id, kind, code) do update set vendor_id = excluded.vendor_id, status = 'recorded', data = bujeti_items.data || excluded.data, updated_at = now();
    end if;
  end if;
  return v_id;
end $$;

-- A Bujeti category seen in a list or on a payment: kept, with Counta's suggestion the first time.
create or replace function private.bujeti_category(p_org uuid, c jsonb) returns public.bujeti_categories
language plpgsql security definer set search_path = public, private as $$
declare r public.bujeti_categories; v_code text := nullif(left(trim(c->>'code'), 60), ''); v_name text := nullif(left(trim(c->>'name'), 120), '');
  v_parent text := nullif(left(trim(case when jsonb_typeof(c->'parent') = 'object' then c->'parent'->>'name' else c->>'parent' end), 120), '');
begin
  if v_code is null or length(v_code) < 4 then return null; end if;
  insert into bujeti_categories (org_id, code, name, parent_name, suggested_code)
  values (p_org, v_code, coalesce(v_name, v_code), v_parent, private.bujeti_suggest(p_org, v_name, v_parent))
  on conflict (org_id, code) do update set name = coalesce(v_name, bujeti_categories.name), parent_name = coalesce(v_parent, bujeti_categories.parent_name), seen_at = now()
  returning * into r;
  return r;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Booking a payment
-- ---------------------------------------------------------------------------
-- A settled payment goes into Banking: its line (and its fee's), then where it belongs. A confirmed category posts it, unless
-- it pays a bill Counta has from that supplier (then the bill is put to a person to confirm, as for a bank line). With no
-- category it is matched as any bank line is. Answers the stage, or null when the line waits for the bookkeeper agent.
create or replace function private.bujeti_book(p_org uuid, p_code text) returns text
language plpgsql security definer set search_path = public, private as $$
declare it public.bujeti_items; b public.bank_accounts; c public.bujeti_categories; v_line uuid; v_fee uuid; v_cands jsonb; v_stage text; v_desc text; v_note text;
  bl public.bank_lines; v_integ uuid;
begin
  select * into it from bujeti_items where org_id = p_org and kind = 'payment' and code = p_code for update;
  if not found or it.status not in ('waiting', 'pending', 'failed') then return null; end if;
  b := private.bujeti_bank(p_org);
  if b.id is null then raise exception 'The Bujeti balance account is missing. Connect Bujeti again.'; end if;
  if it.category_code is not null then select * into c from bujeti_categories where org_id = p_org and code = it.category_code; end if;
  v_desc := left(regexp_replace(coalesce(nullif(trim(it.data->>'narration'), ''), nullif(trim(it.data->>'description'), ''), 'Bujeti payment'), '\s+', ' ', 'g'), 500);
  v_note := left('Bujeti' || coalesce(' · ' || c.name, '') || coalesce(' · paid by ' || nullif(it.data->>'payer', ''), ''), 300);
  insert into bank_lines (org_id, bank_account_id, line_date, amount, description, reference, counterparty, source, provider_ref, fingerprint, note)
  values (p_org, b.id, it.occurred_on, -it.amount, v_desc, it.code, nullif(left(it.data->'recipient'->>'name', 200), ''), 'api', it.code, 'bujeti:' || it.code, v_note)
  on conflict do nothing returning id into v_line;
  if v_line is null then select id into v_line from bank_lines where bank_account_id = b.id and provider_ref = it.code; end if;
  if coalesce(it.fee, 0) > 0 then
    insert into bank_lines (org_id, bank_account_id, line_date, amount, description, reference, source, provider_ref, fingerprint, note)
    values (p_org, b.id, it.occurred_on, -it.fee, left('Bujeti fee · ' || v_desc, 500), it.code, 'api', it.code || ':fee', 'bujeti:' || it.code || ':fee', 'Bujeti fee')
    on conflict do nothing returning id into v_fee;
    if v_fee is null then select id into v_fee from bank_lines where bank_account_id = b.id and provider_ref = it.code || ':fee'; end if;
  end if;
  update bujeti_items set status = 'recorded', bank_line_id = v_line, fee_line_id = v_fee, message = null, updated_at = now()
  where org_id = p_org and kind = 'payment' and code = it.code;
  update integrations set recorded = recorded + 1, last_event_at = now() where org_id = p_org and provider = 'bujeti' and status <> 'disconnected' returning id into v_integ;
  -- What the connection's list shows.
  if v_integ is not null then
    insert into integration_events (integration_id, org_id, external_id, status, amount, message)
    values (v_integ, p_org, 'bujeti:' || it.code, 'recorded', it.amount + coalesce(it.fee, 0),
      left(concat_ws(' · ', nullif(it.data->'recipient'->>'name', ''), v_desc, c.name), 400))
    on conflict (integration_id, external_id) do update set status = excluded.status, amount = excluded.amount, message = excluded.message, created_at = now();
  end if;

  -- The fee is a bank charge.
  if v_fee is not null and (select status from bank_lines where id = v_fee) = 'unmatched' then
    begin
      perform private.post_bank_line(v_fee, private.acct(p_org, 'payment_fees'), null, null, 'Bujeti fee · ' || v_desc, 'bujeti_fee',
        jsonb_build_object('matched_by', 'rule', 'ai_confidence', 1));
    exception when others then
      update bujeti_items set message = left('The fee was not posted: ' || sqlerrm, 400) where org_id = p_org and kind = 'payment' and code = it.code;
    end;
  end if;

  select * into bl from bank_lines where id = v_line;
  if bl.status <> 'unmatched' then return bl.stage; end if;
  begin
    if c.account_code is not null and c.confirmed_at is not null then
      -- A bill from this supplier that the payment fits comes first, so the cost is not booked twice.
      if it.vendor_id is not null then
        select coalesce(jsonb_agg(x), '[]'::jsonb) into v_cands from jsonb_array_elements(private.match_candidates(v_line)) x where x->>'party_id' = it.vendor_id::text;
        if jsonb_array_length(v_cands) > 0 then
          perform private.propose_match(v_line, v_cands, 'vendor_bill');
          return 'vendor_bill';
        end if;
      end if;
      perform private.post_bank_line(v_line, c.account_code, case when it.vendor_id is not null then 'vendor' end, it.vendor_id,
        coalesce(c.name || ' · ', '') || v_desc, 'bujeti', jsonb_build_object('matched_by', 'rule', 'ai_confidence', 1, 'bujeti_category', c.name));
      return 'bujeti';
    end if;
    v_stage := private.match_bank_line(v_line);
  exception when others then
    update bujeti_items set message = left('Waiting in Banking: ' || sqlerrm, 400) where org_id = p_org and kind = 'payment' and code = it.code;
    return null;
  end;
  return v_stage;
end $$;

-- A payment Bujeti reversed after Counta recorded it: the money back, as a line of its own. It goes back to the account the
-- payment was posted to; otherwise it is matched as any money in.
create or replace function private.bujeti_reverse(p_org uuid, p_code text) returns text
language plpgsql security definer set search_path = public, private as $$
declare it public.bujeti_items; b public.bank_accounts; v_line uuid; orig public.bank_lines; v_acct text; v_n int;
begin
  select * into it from bujeti_items where org_id = p_org and kind = 'payment' and code = p_code for update;
  if not found or it.bank_line_id is null or it.reversal_line_id is not null then return null; end if;
  b := private.bujeti_bank(p_org);
  select * into orig from bank_lines where id = it.bank_line_id;
  insert into bank_lines (org_id, bank_account_id, line_date, amount, description, reference, counterparty, source, provider_ref, fingerprint, note)
  values (p_org, b.id, private.local_day(p_org, now()), it.amount, left('Reversed in Bujeti · ' || coalesce(orig.description, ''), 500), it.code, orig.counterparty, 'api',
    it.code || ':rev', 'bujeti:' || it.code || ':rev', 'Bujeti reversal')
  on conflict do nothing returning id into v_line;
  if v_line is null then return null; end if;
  update bujeti_items set reversal_line_id = v_line, bujeti_status = 'reversed', message = 'Reversed in Bujeti: the money is back in the balance', updated_at = now()
  where org_id = p_org and kind = 'payment' and code = it.code;
  begin
    if orig.journal_id is not null and orig.stage = 'bujeti' then
      select count(*), min(account_code) into v_n, v_acct from journal_lines where journal_id = orig.journal_id and account_code <> b.ledger_code;
      if v_n = 1 then
        perform private.post_bank_line(v_line, v_acct, null, null, 'Reversed in Bujeti · ' || coalesce(orig.description, ''), 'bujeti',
          jsonb_build_object('matched_by', 'rule', 'ai_confidence', 1));
        return 'bujeti';
      end if;
    end if;
    return private.match_bank_line(v_line);
  exception when others then
    return null;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 4. For the integrations function
-- ---------------------------------------------------------------------------
-- Where a look starts, and what it has to fetch again: payments still pending in Bujeti, and receipts not yet kept.
-- p: {scopes} to keep what the key may read.
create or replace function public.svc_bujeti_state(p_integration uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.integrations;
begin
  select * into i from integrations where id = p_integration and provider = 'bujeti' and status <> 'disconnected';
  if not found then return null; end if;
  if jsonb_typeof(p->'scopes') = 'object' then
    update integrations set settings = settings || jsonb_build_object('scopes', p->'scopes') where id = i.id returning * into i;
  end if;
  return jsonb_build_object('start', private.bujeti_start(i.org_id), 'org_id', i.org_id,
    'recheck', (select coalesce(jsonb_agg(code), '[]'::jsonb) from (select code from bujeti_items where org_id = i.org_id and kind = 'payment'
        and status = 'pending' and updated_at < now() - interval '1 day' and occurred_on > current_date - 120 order by updated_at limit 20) x),
    'receipts', (select coalesce(jsonb_agg(code), '[]'::jsonb) from (select code from bujeti_items where org_id = i.org_id and kind = 'payment'
        and status in ('recorded', 'waiting') and coalesce((data->>'assets')::int, 0) > 0 and data->>'receipts' is null
        and coalesce((data->>'receipt_tries')::int, 0) < 3 order by occurred_on desc limit 10) x));
end $$;

-- Bujeti's balances: kept on the account, the naira ones held in Bujeti (not a linked bank account) as what Bujeti says.
-- p_list: [{code, name, amount (naira), currency, type, purpose, status}]
create or replace function public.svc_bujeti_balances(p_integration uuid, p_list jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.integrations; b public.bank_accounts; v_ngn numeric; v_list jsonb;
begin
  select * into i from integrations where id = p_integration and provider = 'bujeti' and status in ('active', 'error');
  if not found or jsonb_typeof(p_list) <> 'array' then return null; end if;
  b := private.bujeti_bank(i.org_id);
  if b.id is null then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object('code', left(x->>'code', 60), 'name', left(x->>'name', 120), 'amount', round(private.num(x->>'amount'), 2),
      'currency', upper(left(coalesce(x->>'currency', 'NGN'), 3)), 'type', left(x->>'type', 40), 'purpose', left(x->>'purpose', 60), 'status', left(x->>'status', 40))), '[]'::jsonb)
    into v_list from (select value x from jsonb_array_elements(p_list) limit 50) y;
  select sum(round(private.num(x->>'amount'), 2)) into v_ngn from jsonb_array_elements(v_list) x
  where x->>'currency' = 'NGN' and lower(coalesce(x->>'type', '')) not in ('linked', 'direct-debit', 'direct_debit') and lower(coalesce(x->>'status', 'active')) !~ '(inactive|closed|delet)';
  update bank_accounts set provider_meta = coalesce(provider_meta, '{}'::jsonb) || jsonb_build_object('bujeti_balances', v_list, 'balance_at', now())
    || case when v_ngn is not null then jsonb_build_object('balance', v_ngn) else '{}'::jsonb end
  where id = b.id;
  if v_ngn is not null then update bank_accounts set anchor_balance = v_ngn, anchor_at = now(), anchor_source = 'bujeti' where id = b.id; end if;
  return jsonb_build_object('naira', v_ngn, 'balances', jsonb_array_length(v_list));
end $$;

-- Bujeti's categories. p_list: [{code, name, parent}]
create or replace function public.svc_bujeti_categories(p_integration uuid, p_list jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.integrations; x jsonb; n int := 0;
begin
  select * into i from integrations where id = p_integration and provider = 'bujeti' and status in ('active', 'error');
  if not found or jsonb_typeof(p_list) <> 'array' then return null; end if;
  for x in select value from jsonb_array_elements(p_list) limit 2000 loop
    if (private.bujeti_category(i.org_id, x)).code is not null then n := n + 1; end if;
  end loop;
  return jsonb_build_object('categories', n, 'to_confirm', (select count(*) from bujeti_categories where org_id = i.org_id and confirmed_at is null));
end $$;

-- Bujeti's vendors. p_list: [{code, name, email, type, status}]
create or replace function public.svc_bujeti_vendors(p_integration uuid, p_list jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.integrations; x jsonb; v_before int; n int := 0;
begin
  select * into i from integrations where id = p_integration and provider = 'bujeti' and status in ('active', 'error');
  if not found or jsonb_typeof(p_list) <> 'array' then return null; end if;
  select count(*) into v_before from vendors where org_id = i.org_id;
  for x in select value from jsonb_array_elements(p_list) limit 2000 loop
    if private.bujeti_vendor(i.org_id, x) is not null then n := n + 1; end if;
  end loop;
  return jsonb_build_object('linked', n, 'added', (select count(*) from vendors where org_id = i.org_id) - v_before);
end $$;

-- Bujeti's payments, oldest first. p_list: [{code, amount (naira, what left the balance before the fee), fee, currency, status,
-- narration, description, at, category: {code, name, parent}, recipient: {kind: vendor|user, code, name, email}, payer, assets (count)}]
create or replace function public.svc_bujeti_payments(p_integration uuid, p_list jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.integrations; x jsonb; it public.bujeti_items; v_code text; v_class text; v_amt numeric; v_fee numeric; v_cur text; v_day date; v_start date;
  c public.bujeti_categories; v_vendor uuid; v_msg text; v_stage text; v_ai boolean := false; v_wait int := 0; v_inv public.bujeti_items;
  r jsonb := jsonb_build_object('recorded', 0, 'waiting', 0, 'pending', 0, 'skipped', 0, 'failed', 0, 'reversed', 0, 'seen', 0);
  bump text;
begin
  select * into i from integrations where id = p_integration and provider = 'bujeti' and status in ('active', 'error');
  if not found then return jsonb_build_object('status', 'skipped', 'message', 'The connection is paused or gone.'); end if;
  if jsonb_typeof(p_list) <> 'array' then return r; end if;
  v_start := private.bujeti_start(i.org_id);
  perform private.integration_account(i, coalesce(i.connected_by, (select id from members where org_id = i.org_id and role = 'owner' and status = 'active' order by created_at limit 1)));
  for x in select value from jsonb_array_elements(p_list) order by value->>'at', value->>'code' limit 1000 loop
    bump := null; v_msg := null;
    v_code := nullif(left(trim(x->>'code'), 60), '');
    continue when v_code is null or length(v_code) < 4;
    r := jsonb_set(r, '{seen}', to_jsonb((r->>'seen')::int + 1));
    v_class := private.bujeti_class(x->>'status');
    v_amt := round(abs(coalesce(private.num(x->>'amount'), 0)), 2);
    v_fee := round(abs(coalesce(private.num(x->>'fee'), 0)), 2);
    v_cur := upper(left(coalesce(nullif(trim(x->>'currency'), ''), 'NGN'), 3));
    v_day := private.local_day(i.org_id, least(coalesce(nullif(x->>'at', '')::timestamptz, now()), now()));
    select * into it from bujeti_items where org_id = i.org_id and kind = 'payment' and code = v_code for update;

    if found then
      -- Known already: only a change of status matters.
      if it.status = 'recorded' then
        if v_class in ('reversed', 'failed') and it.reversal_line_id is null and it.bank_line_id is not null then
          perform private.bujeti_reverse(i.org_id, v_code); bump := 'reversed';
        end if;
        continue when bump is null;
      elsif it.status in ('skipped') or (it.status = 'waiting' and v_class = 'settled') then
        if it.status = 'waiting' and nullif(x->'category'->>'code', '') is distinct from it.category_code and nullif(x->'category'->>'code', '') is not null then
          c := private.bujeti_category(i.org_id, x->'category');
          update bujeti_items set category_code = c.code, updated_at = now() where org_id = i.org_id and kind = 'payment' and code = v_code;
          if c.confirmed_at is not null then perform private.bujeti_book(i.org_id, v_code); bump := 'recorded'; end if;
        end if;
        continue when bump is null;
      elsif it.status = 'waiting' and v_class in ('reversed', 'failed') then
        update bujeti_items set status = 'skipped', bujeti_status = left(x->>'status', 40), message = 'Not paid in the end: ' || coalesce(x->>'status', 'cancelled'), updated_at = now()
        where org_id = i.org_id and kind = 'payment' and code = v_code;
        bump := 'skipped';
      end if;
    end if;

    if bump is null then
      c := null; v_vendor := null;
      if jsonb_typeof(x->'category') = 'object' then c := private.bujeti_category(i.org_id, x->'category'); end if;
      if x->'recipient'->>'kind' = 'vendor' then v_vendor := private.bujeti_vendor(i.org_id, x->'recipient'); end if;
      if v_class = 'settled' then
        if v_cur <> 'NGN' then v_msg := 'Paid in ' || v_cur || '. Counta records naira payments from Bujeti; record this one by hand.';
        elsif v_day < v_start then v_msg := 'Before ' || to_char(v_start, 'FMDD Mon YYYY') || ', when Counta''s books from Bujeti start.';
        elsif v_amt <= 0 then v_msg := 'Nothing was paid.';
        end if;
        -- Money in for a Bujeti invoice Counta recorded with the invoice.
        if v_msg is null then
          select * into v_inv from bujeti_items b2 where b2.org_id = i.org_id and b2.kind = 'invoice' and b2.status = 'recorded' and b2.collection_id is not null
            and length(coalesce(b2.data->>'number', '')) >= 3 and abs(b2.amount - v_amt) < 1
            and position(upper(b2.data->>'number') in upper(coalesce(x->>'narration', '') || ' ' || coalesce(x->>'description', ''))) > 0 limit 1;
          if v_inv.code is not null then v_msg := 'The payment for Bujeti invoice ' || (v_inv.data->>'number') || ', recorded with the invoice.'; end if;
        end if;
      end if;
      insert into bujeti_items (org_id, kind, code, status, bujeti_status, category_code, amount, fee, currency, occurred_on, vendor_id, message, data)
      values (i.org_id, 'payment', v_code,
        case when v_msg is not null then 'skipped' when v_class = 'settled' then 'waiting' when v_class in ('failed', 'reversed') then 'skipped' else 'pending' end,
        left(x->>'status', 40), c.code, v_amt, v_fee, v_cur, v_day, v_vendor,
        coalesce(v_msg, case when v_class in ('failed', 'reversed') then 'Not paid: ' || coalesce(x->>'status', 'failed') || ' in Bujeti'
                             when v_class = 'unknown' then 'Bujeti says "' || left(x->>'status', 30) || '": Counta waits until it is paid' end),
        jsonb_strip_nulls(jsonb_build_object('narration', left(x->>'narration', 300), 'description', left(x->>'description', 300), 'at', x->>'at',
          'recipient', x->'recipient', 'payer', left(x->>'payer', 120), 'assets', nullif(coalesce(private.num(x->>'assets'), 0), 0))))
      on conflict (org_id, kind, code) do update set status = excluded.status, bujeti_status = excluded.bujeti_status, category_code = excluded.category_code,
        amount = excluded.amount, fee = excluded.fee, currency = excluded.currency, occurred_on = excluded.occurred_on, vendor_id = excluded.vendor_id,
        message = excluded.message, data = bujeti_items.data || excluded.data, updated_at = now()
      returning * into it;
      if it.status = 'waiting' then
        if c.code is null or c.confirmed_at is not null then
          v_stage := private.bujeti_book(i.org_id, v_code);
          if v_stage is null then v_ai := true; end if;
          bump := 'recorded';
        else
          bump := 'waiting'; v_wait := v_wait + 1;
        end if;
      else
        bump := it.status;
      end if;
      -- What the connection's list shows: payments left out, and why (recorded ones are listed as they are booked; one still
      -- pending in Bujeti, or waiting for its category, is not listed yet).
      if it.status in ('skipped', 'failed') and it.message is not null then
        insert into integration_events (integration_id, org_id, external_id, status, amount, message)
        values (i.id, i.org_id, 'bujeti:' || v_code, it.status, it.amount + coalesce(it.fee, 0), left(it.message, 400))
        on conflict (integration_id, external_id) do update set status = excluded.status, amount = excluded.amount, message = excluded.message, created_at = now();
      end if;
    end if;
    r := jsonb_set(r, array[bump], to_jsonb(coalesce((r->>bump)::int, 0) + 1));
  end loop;
  update integrations set last_event_at = now() where id = i.id and (r->>'seen')::int > 0;
  -- Lines nothing explained go to the bookkeeper agent, as for a bank feed.
  if v_ai then perform private.call_function('atlas', jsonb_build_object('action', 'classify_lines', 'org_id', i.org_id)); end if;
  -- Payments waiting for a category: said once a day at most.
  if v_wait > 0 and not exists (select 1 from notifications where org_id = i.org_id and tag = 'bujeti-categories' and created_at > now() - interval '1 day') then
    perform private.notify_perm(i.org_id, 'keep_books', 'books', 'Bujeti categories to confirm',
      (select count(*) from bujeti_items where org_id = i.org_id and kind = 'payment' and status = 'waiting') || ' Bujeti payments wait until you confirm the account for their category.',
      '/integrations?tool=bujeti', 'bujeti-categories');
  end if;
  return r;
end $$;

-- A receipt from Bujeti, once the function has stored it under the business's Documents (Bank).
-- p: {code (the payment), asset, name, path, mime, size}, or {code, none: true} when there is nothing to keep, or {code, failed: true}.
create or replace function public.svc_bujeti_receipt(p_integration uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.integrations; it public.bujeti_items; d public.documents; v_path text := p->>'path';
begin
  select * into i from integrations where id = p_integration and provider = 'bujeti' and status <> 'disconnected';
  if not found then return null; end if;
  select * into it from bujeti_items where org_id = i.org_id and kind = 'payment' and code = p->>'code' for update;
  if not found then return null; end if;
  if coalesce((p->>'failed')::boolean, false) then
    update bujeti_items set data = data || jsonb_build_object('receipt_tries', coalesce((data->>'receipt_tries')::int, 0) + 1) where org_id = i.org_id and kind = 'payment' and code = it.code;
    return jsonb_build_object('ok', false);
  end if;
  if coalesce((p->>'none')::boolean, false) then
    update bujeti_items set data = data || jsonb_build_object('receipts', coalesce((data->>'receipts')::int, 0)) where org_id = i.org_id and kind = 'payment' and code = it.code;
    return jsonb_build_object('ok', true, 'receipts', coalesce((it.data->>'receipts')::int, 0));
  end if;
  if coalesce(v_path, '') !~ ('^' || i.org_id::text || '/documents/bank/bujeti/') or v_path ~ '\.\.' then raise exception 'Bujeti receipts are stored under the business''s Documents, Bank.'; end if;
  insert into documents (org_id, cat, folder, period, year, name, path, mime, size, source, kind, notes)
  values (i.org_id, 'bank', 'Bujeti receipts', date_trunc('month', it.occurred_on)::date, extract(year from it.occurred_on)::int,
    left(coalesce(nullif(trim(p->>'name'), ''), 'Receipt') , 200), v_path, nullif(left(p->>'mime', 120), ''), nullif(p->>'size', '')::bigint, 'bujeti', 'receipt',
    left('Bujeti payment ' || it.code || coalesce(' · ' || nullif(it.data->>'narration', ''), '') || ' · ' || private.naira(it.amount), 500))
  on conflict (path) do update set name = excluded.name, mime = excluded.mime, size = excluded.size
  returning * into d;
  update bujeti_items set data = data || jsonb_build_object('receipts', (select count(*) from documents where org_id = i.org_id and source = 'bujeti'
      and path like i.org_id::text || '/documents/bank/bujeti/' || it.code || '/%'))
  where org_id = i.org_id and kind = 'payment' and code = it.code;
  return jsonb_build_object('ok', true, 'id', d.id);
end $$;

-- Bujeti's invoices to customers. p_list: [{code, number, title, description, amount (naira, the total), vat_amount, currency,
-- status, issued_at, due_date, paid_at, customer: {code, name, email}}]
create or replace function public.svc_bujeti_invoices(p_integration uuid, p_list jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.integrations; o public.orgs; m public.members; x jsonb; it public.bujeti_items; v_code text; v_class text; v_cur text; v_total numeric; v_vat numeric;
  v_day date; v_start date; v_cust uuid; v_email text; v_name text; s public.sales; col public.collections; v_bank uuid; v_msg text; v_ok boolean; v_paid_at timestamptz;
  r jsonb := jsonb_build_object('recorded', 0, 'paid', 0, 'skipped', 0, 'failed', 0, 'seen', 0); v_no text; v_due date; v_known boolean;
begin
  select * into i from integrations where id = p_integration and provider = 'bujeti' and status in ('active', 'error');
  if not found or jsonb_typeof(p_list) <> 'array' then return r; end if;
  select * into o from orgs where id = i.org_id;
  select * into m from members where org_id = i.org_id and role = 'owner' and status = 'active' order by created_at limit 1;
  v_start := private.bujeti_start(i.org_id);
  v_bank := private.integration_account(i, m.id);
  for x in select value from jsonb_array_elements(p_list) order by value->>'issued_at', value->>'code' limit 2000 loop
    v_code := nullif(left(trim(x->>'code'), 60), '');
    continue when v_code is null or length(v_code) < 4;
    r := jsonb_set(r, '{seen}', to_jsonb((r->>'seen')::int + 1));
    v_class := private.bujeti_invoice_class(x->>'status');
    v_cur := upper(left(coalesce(nullif(trim(x->>'currency'), ''), 'NGN'), 3));
    v_total := round(abs(coalesce(private.num(x->>'amount'), 0)), 2);
    v_vat := round(abs(coalesce(private.num(x->>'vat_amount'), 0)), 2);
    v_day := private.local_day(i.org_id, least(coalesce(nullif(x->>'issued_at', '')::timestamptz, now()), now()));
    v_no := nullif(left(trim(coalesce(x->>'number', '')), 60), '');
    v_msg := null; v_ok := false;
    select * into it from bujeti_items where org_id = i.org_id and kind = 'invoice' and code = v_code for update;
    v_known := found;
    if v_known and it.status = 'recorded' and it.sale_id is not null then
      select * into s from sales where id = it.sale_id;
      -- Paid since Counta recorded it.
      if v_class = 'paid' and it.collection_id is null and s.status in ('open', 'partially_paid') then
        begin
          v_paid_at := least(coalesce(nullif(x->>'paid_at', '')::timestamptz, now()), now());
          col := private.add_collection(i.org_id, s.customer_id, round(s.total - s.amount_paid - s.credited, 2), 'transfer',
            jsonb_build_object('bank_account_id', v_bank, 'provider_ref', 'bujeti-inv:' || v_code, 'reference', left(coalesce(v_no, v_code), 80),
              'received_at', v_paid_at, 'spread', false, 'note', 'Paid through Bujeti'), m, 'confirmed', array[s.id]);
          update bujeti_items set collection_id = col.id, bujeti_status = left(x->>'status', 40), updated_at = now() where org_id = i.org_id and kind = 'invoice' and code = v_code;
          insert into integration_events (integration_id, org_id, external_id, status, amount, sale_id, message)
          values (i.id, i.org_id, 'bujeti-paid:' || v_code, 'recorded', col.amount, s.id, 'Paid through Bujeti')
          on conflict (integration_id, external_id) do nothing;
          r := jsonb_set(r, '{paid}', to_jsonb((r->>'paid')::int + 1));
        exception when others then
          update bujeti_items set message = left('The payment was not recorded: ' || sqlerrm, 400), updated_at = now() where org_id = i.org_id and kind = 'invoice' and code = v_code;
        end;
      elsif v_class = 'void' and it.data->>'void_noticed' is null then
        update bujeti_items set data = data || '{"void_noticed": true}'::jsonb, bujeti_status = left(x->>'status', 40),
          message = 'Cancelled in Bujeti. Void ' || s.number || ' in Counta if it should not stand.', updated_at = now()
        where org_id = i.org_id and kind = 'invoice' and code = v_code;
        perform private.notify_perm(i.org_id, 'record_sales', 'books', 'Invoice cancelled in Bujeti', s.number || ' was cancelled in Bujeti. Void it in Counta if it should not stand.',
          '/sell/sales?open=' || s.id, 'bujeti-void-' || v_code);
      end if;
      continue;
    end if;
    continue when v_known and it.status = 'skipped' and v_class = it.data->>'class';
    if v_class in ('draft', 'void') then continue; end if;
    if v_cur <> 'NGN' then v_msg := 'Invoiced in ' || v_cur || '. Counta records naira invoices from Bujeti; record this one by hand.';
    elsif v_day < v_start then continue;
    elsif v_total <= 0 then v_msg := 'Nothing was invoiced.';
    elsif v_vat >= v_total then v_msg := 'The VAT is more than the invoice.';
    end if;
    if v_msg is null then
      begin
        -- The customer: one the business already has (by email, then name), or a new one.
        v_email := nullif(lower(trim(x->'customer'->>'email')), '');
        if v_email is not null and v_email !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' then v_email := null; end if;
        v_name := nullif(left(trim(regexp_replace(coalesce(x->'customer'->>'name', ''), '\s+', ' ', 'g')), 120), '');
        v_cust := null;
        if v_email is not null then select id into v_cust from customers where org_id = i.org_id and not archived and not is_walk_in and lower(email) = v_email order by created_at limit 1; end if;
        if v_cust is null and v_name is not null then select id into v_cust from customers where org_id = i.org_id and not archived and not is_walk_in and lower(name) = lower(v_name) order by created_at limit 1; end if;
        if v_cust is null then
          v_cust := private.upsert_customer(i.org_id, jsonb_strip_nulls(jsonb_build_object('name', coalesce(v_name, split_part(v_email, '@', 1), 'Bujeti customer'), 'email', v_email)), m);
        end if;
        v_due := greatest(coalesce(private.local_day(i.org_id, nullif(x->>'due_date', '')::timestamptz), v_day), v_day);
        -- One line for the invoice. Bujeti's VAT, when it shows any, stays as it was; an invoice with none is taken as including VAT
        -- for a business registered for VAT, as for the other tools.
        s := private.create_sale(i.org_id, jsonb_strip_nulls(jsonb_build_object('doc_type', 'invoice', 'status', 'issue', 'channel', 'invoice',
          'customer_id', v_cust, 'issue_date', v_day, 'recorded_at', private.line_time(i.org_id, v_day), 'due_date', v_due,
          'location_id', nullif(i.settings->>'location_id', ''), 'reference', left(coalesce(v_no, v_code), 80),
          'notes', left('Bujeti · ' || coalesce(v_no, v_code) || coalesce(' · ' || nullif(trim(x->>'title'), ''), ''), 500),
          'prices_include_vat', not (v_vat > 0),
          'lines', jsonb_build_array(jsonb_build_object('description', left(coalesce(nullif(trim(x->>'title'), ''), nullif(trim(x->>'description'), ''), 'Bujeti invoice ' || coalesce(v_no, v_code)), 300),
            'qty', 1, 'unit_price', case when v_vat > 0 and o.vat_registered then v_total - v_vat else v_total end,
            'vat_treatment', case when o.vat_registered then 'standard' else 'exempt' end)))), m);
        v_msg := case when not o.vat_registered and v_vat > 0 then 'Bujeti showed VAT, but the business is not registered for VAT in Counta; recorded at the full amount.'
          when not o.vat_registered then null
          when v_vat = 0 then 'Bujeti showed no VAT; Counta took the total as including VAT. Change the line if this supply is exempt or zero-rated.'
          when abs(s.total - v_total) > 1 then 'Counta''s total is ' || private.naira(s.total) || '; Bujeti''s was ' || private.naira(v_total) || '. Check the VAT.' end;
        insert into bujeti_items (org_id, kind, code, status, bujeti_status, amount, currency, occurred_on, sale_id, message, data)
        values (i.org_id, 'invoice', v_code, 'recorded', left(x->>'status', 40), v_total, v_cur, v_day, s.id, v_msg,
          jsonb_strip_nulls(jsonb_build_object('number', v_no, 'title', left(x->>'title', 200), 'class', v_class)))
        on conflict (org_id, kind, code) do update set status = 'recorded', bujeti_status = excluded.bujeti_status, amount = excluded.amount, sale_id = excluded.sale_id,
          message = excluded.message, data = bujeti_items.data || excluded.data, updated_at = now();
        update integrations set recorded = recorded + 1 where id = i.id;
        insert into integration_events (integration_id, org_id, external_id, status, amount, sale_id, message)
        values (i.id, i.org_id, 'bujeti-inv:' || v_code, 'recorded', s.total, s.id, left(coalesce(v_msg, 'Invoice ' || coalesce(v_no, v_code) || ' from Bujeti'), 400))
        on conflict (integration_id, external_id) do update set status = excluded.status, amount = excluded.amount, sale_id = excluded.sale_id, message = excluded.message, created_at = now();
        r := jsonb_set(r, '{recorded}', to_jsonb((r->>'recorded')::int + 1));
        v_ok := true;
        if v_class = 'paid' then
          v_paid_at := least(coalesce(nullif(x->>'paid_at', '')::timestamptz, now()), now());
          col := private.add_collection(i.org_id, s.customer_id, s.total, 'transfer',
            jsonb_build_object('bank_account_id', v_bank, 'provider_ref', 'bujeti-inv:' || v_code, 'reference', left(coalesce(v_no, v_code), 80),
              'received_at', greatest(v_paid_at, private.line_time(i.org_id, v_day)), 'spread', false, 'note', 'Paid through Bujeti'), m, 'confirmed', array[s.id]);
          update bujeti_items set collection_id = col.id where org_id = i.org_id and kind = 'invoice' and code = v_code;
          r := jsonb_set(r, '{paid}', to_jsonb((r->>'paid')::int + 1));
        end if;
      exception when others then
        v_msg := left(sqlerrm, 300); v_ok := false;
      end;
    end if;
    if not v_ok then
      insert into bujeti_items (org_id, kind, code, status, bujeti_status, amount, currency, occurred_on, message, data)
      values (i.org_id, 'invoice', v_code, case when v_msg like 'Invoiced in%' or v_msg = 'Nothing was invoiced.' then 'skipped' else 'failed' end, left(x->>'status', 40),
        v_total, v_cur, v_day, v_msg, jsonb_strip_nulls(jsonb_build_object('number', v_no, 'class', v_class)))
      on conflict (org_id, kind, code) do update set status = excluded.status, bujeti_status = excluded.bujeti_status, message = excluded.message, data = bujeti_items.data || excluded.data, updated_at = now();
      insert into integration_events (integration_id, org_id, external_id, status, amount, message)
      values (i.id, i.org_id, 'bujeti-inv:' || v_code, case when v_msg like 'Invoiced in%' or v_msg = 'Nothing was invoiced.' then 'skipped' else 'failed' end, v_total,
        left('Invoice ' || coalesce(v_no, v_code) || ': ' || v_msg, 400))
      on conflict (integration_id, external_id) do update set status = excluded.status, amount = excluded.amount, message = excluded.message, created_at = now();
      r := jsonb_set(r, array[case when v_msg like 'Invoiced in%' or v_msg = 'Nothing was invoiced.' then 'skipped' else 'failed' end],
        to_jsonb((r->>(case when v_msg like 'Invoiced in%' or v_msg = 'Nothing was invoiced.' then 'skipped' else 'failed' end))::int + 1));
    end if;
  end loop;
  return r;
end $$;

-- ---------------------------------------------------------------------------
-- 5. What a business sees and confirms
-- ---------------------------------------------------------------------------
-- The Bujeti connection at a glance: balances, what waits, and the categories with the account each posts to. For the
-- people who connect tools or keep the books; only those who keep the books confirm categories.
create or replace function public.bujeti_overview(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; i public.integrations; b public.bank_accounts;
begin
  m := private.require(p_org, null);
  if not (m.role = 'owner' or private.perm_of(m, 'keep_books') or private.perm_of(m, 'manage_settings')) then
    raise exception 'Your role does not allow this. The owner, the bookkeeper or someone who manages settings sees Bujeti here.';
  end if;
  i := private.bujeti_conn(p_org);
  if i.id is null then return jsonb_build_object('connected', false); end if;
  b := private.bujeti_bank(p_org);
  return jsonb_build_object('connected', true,
    'can_map', m.role = 'owner' or private.perm_of(m, 'keep_books'),
    'start', private.bujeti_start(p_org),
    'scopes', i.settings->'scopes',
    'account', case when b.id is not null then jsonb_build_object('id', b.id, 'name', b.name, 'code', b.ledger_code,
      'books', (select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code = b.ledger_code),
      'bujeti', b.anchor_balance, 'balance_at', b.provider_meta->>'balance_at', 'balances', coalesce(b.provider_meta->'bujeti_balances', '[]'::jsonb),
      'unmatched', (select count(*) from bank_lines where bank_account_id = b.id and status in ('unmatched', 'proposed'))) end,
    'counts', (select jsonb_build_object(
        'recorded', count(*) filter (where kind = 'payment' and status = 'recorded'),
        'waiting', count(*) filter (where kind = 'payment' and status = 'waiting'),
        'waiting_total', coalesce(sum(amount + coalesce(fee, 0)) filter (where kind = 'payment' and status = 'waiting'), 0),
        'pending', count(*) filter (where kind = 'payment' and status = 'pending'),
        'other_currency', count(*) filter (where kind = 'payment' and status = 'skipped' and currency <> 'NGN'),
        'invoices', count(*) filter (where kind = 'invoice' and status = 'recorded'),
        'vendors', count(*) filter (where kind = 'vendor' and status = 'recorded'),
        'receipts', coalesce(sum((data->>'receipts')::int) filter (where kind = 'payment'), 0))
      from bujeti_items where org_id = p_org),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'name', c.name, 'parent', c.parent_name, 'suggested', c.suggested_code,
        'account', c.account_code, 'confirmed_at', c.confirmed_at, 'confirmed_by', (select display_name from members where id = c.confirmed_by),
        'waiting', (select count(*) from bujeti_items it where it.org_id = p_org and it.kind = 'payment' and it.status = 'waiting' and it.category_code = c.code),
        'waiting_total', (select coalesce(sum(it.amount + coalesce(it.fee, 0)), 0) from bujeti_items it where it.org_id = p_org and it.kind = 'payment' and it.status = 'waiting' and it.category_code = c.code),
        'recorded', (select count(*) from bujeti_items it where it.org_id = p_org and it.kind = 'payment' and it.status = 'recorded' and it.category_code = c.code))
      order by (c.confirmed_at is null) desc, c.name), '[]'::jsonb) from bujeti_categories c where c.org_id = p_org),
    'accounts', case when m.role = 'owner' or private.perm_of(m, 'keep_books') then private.bujeti_accounts(p_org) else '[]'::jsonb end);
end $$;

-- Confirms the account for Bujeti categories, and books the payments that waited for them. An empty account stops a category
-- posting by itself again (its new payments wait); what it already posted stays.
-- p: [{code, account}]
create or replace function public.bujeti_categories_set(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; x jsonb; v_acct text; v_n int := 0; v_booked int := 0; v_ai boolean := false; it record; v_allowed jsonb;
begin
  m := private.require(p_org, 'keep_books');
  if private.bujeti_conn(p_org) is null then raise exception 'Bujeti is not connected.'; end if;
  if jsonb_typeof(p) <> 'array' or jsonb_array_length(p) = 0 then raise exception 'Choose an account for at least one category.'; end if;
  v_allowed := private.bujeti_accounts(p_org);
  for x in select value from jsonb_array_elements(p) limit 500 loop
    if not exists (select 1 from bujeti_categories where org_id = p_org and code = x->>'code') then raise exception 'Unknown Bujeti category.'; end if;
    v_acct := nullif(trim(x->>'account'), '');
    if v_acct is not null and not exists (select 1 from jsonb_array_elements(v_allowed) a where a->>'code' = v_acct) then
      raise exception 'Account % cannot take Bujeti payments. Choose an expense or another account from the list.', v_acct;
    end if;
    update bujeti_categories set account_code = v_acct, confirmed_by = case when v_acct is not null then m.id end, confirmed_at = case when v_acct is not null then now() end
    where org_id = p_org and code = x->>'code';
    v_n := v_n + 1;
  end loop;
  -- The payments that waited for these categories go into Banking now, oldest first.
  for it in select b.code from bujeti_items b join bujeti_categories c on c.org_id = b.org_id and c.code = b.category_code
            where b.org_id = p_org and b.kind = 'payment' and b.status = 'waiting' and c.confirmed_at is not null order by b.occurred_on, b.code limit 1000 loop
    if private.bujeti_book(p_org, it.code) is null then v_ai := true; end if;
    v_booked := v_booked + 1;
  end loop;
  if v_ai then perform private.call_function('atlas', jsonb_build_object('action', 'classify_lines', 'org_id', p_org)); end if;
  return jsonb_build_object('confirmed', v_n, 'booked', v_booked,
    'waiting', (select count(*) from bujeti_items where org_id = p_org and kind = 'payment' and status = 'waiting'));
end $$;

revoke all on function private.bujeti_conn(uuid), private.bujeti_bank(uuid), private.bujeti_start(uuid), private.bujeti_class(text), private.bujeti_invoice_class(text),
  private.bujeti_suggest(uuid, text, text), private.bujeti_accounts(uuid), private.bujeti_vendor(uuid, jsonb), private.bujeti_category(uuid, jsonb),
  private.bujeti_book(uuid, text), private.bujeti_reverse(uuid, text), private.integration_account(public.integrations, uuid), private.integration_name(text)
  from public, anon, authenticated;
revoke all on function public.svc_bujeti_state(uuid, jsonb), public.svc_bujeti_balances(uuid, jsonb), public.svc_bujeti_categories(uuid, jsonb),
  public.svc_bujeti_vendors(uuid, jsonb), public.svc_bujeti_payments(uuid, jsonb), public.svc_bujeti_receipt(uuid, jsonb), public.svc_bujeti_invoices(uuid, jsonb),
  public.svc_integrations_due() from public, anon, authenticated;
grant execute on function public.svc_bujeti_state(uuid, jsonb), public.svc_bujeti_balances(uuid, jsonb), public.svc_bujeti_categories(uuid, jsonb),
  public.svc_bujeti_vendors(uuid, jsonb), public.svc_bujeti_payments(uuid, jsonb), public.svc_bujeti_receipt(uuid, jsonb), public.svc_bujeti_invoices(uuid, jsonb),
  public.svc_integrations_due() to service_role;
revoke execute on function public.bujeti_overview(uuid), public.bujeti_categories_set(uuid, jsonb), public.integration_check(uuid, text) from public, anon;
grant execute on function public.bujeti_overview(uuid), public.bujeti_categories_set(uuid, jsonb), public.integration_check(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Bank matching: money sent to Bujeti (or taken back) from another account is a transfer to its balance
-- ---------------------------------------------------------------------------
-- The matching of 27 October, with 6b added.
create or replace function private.match_bank_line(p_line uuid) returns text
language plpgsql security definer set search_path = public, private as $$
declare bl public.bank_lines; b public.bank_accounts; v_amt numeric; v_in boolean; r record; c public.collections; v_cnt int; m public.members;
  v_cust public.customers; v_vendor public.vendors; v_due numeric; v_rate numeric; v_gross numeric; v_wht numeric; v_head numeric; j public.journals;
  other public.bank_lines; ob public.bank_accounts; v_key text; v_rule public.entity_rules; v_at timestamptz; v_text text; s public.sales; bb public.bills;
  v_left_wht numeric; v_pid uuid; v_split jsonb; v_cands jsonb;
begin
  select * into bl from bank_lines where id = p_line for update;
  if bl.status <> 'unmatched' then return bl.stage; end if;
  select * into b from bank_accounts where id = bl.bank_account_id;
  v_amt := abs(bl.amount); v_in := bl.amount > 0;
  v_key := private.party_key(coalesce(nullif(bl.counterparty, ''), bl.description));
  update bank_lines set party_key = v_key where id = bl.id;
  v_at := private.line_time(bl.org_id, bl.line_date);
  v_text := coalesce(bl.description, '') || ' ' || coalesce(bl.reference, '') || ' ' || coalesce(bl.counterparty, '');
  -- Actions are taken in the name of the business owner; the line and its evidence say why.
  select * into m from members where org_id = bl.org_id and role = 'owner' and status = 'active' order by created_at limit 1;

  -- 1 Already in the books on this account, same amount, within three days, not yet tied to another line.
  select l.journal_id into r from journal_lines l join journals jj on jj.id = l.journal_id
  where l.org_id = bl.org_id and l.account_code = b.ledger_code and (case when v_in then l.debit else l.credit end) = v_amt
    and jj.entry_date between bl.line_date - 3 and bl.line_date + 3
    and not exists (select 1 from bank_lines x where x.bank_account_id = b.id and x.journal_id = l.journal_id and x.id <> bl.id)
  order by abs(jj.entry_date - bl.line_date), jj.created_at limit 1;
  if r.journal_id is not null then
    update bank_lines set status = 'matched', journal_id = r.journal_id, stage = 'in_books', matched_by = 'system', confidence = 1 where id = bl.id;
    return 'in_books';
  end if;

  if v_in then
    -- 2 A transfer recorded at the till or against an invoice, waiting for confirmation: the statement confirms it.
    select count(*) into v_cnt from collections col where col.org_id = bl.org_id and col.status = 'pending' and col.direction = 'in'
      and col.amount = v_amt and col.method in ('transfer', 'card', 'pos', 'cheque', 'other') and col.received_at::date between bl.line_date - 5 and bl.line_date + 1;
    if v_cnt >= 1 then
      select col.* into c from collections col join customers cu on cu.id = col.customer_id
      where col.org_id = bl.org_id and col.status = 'pending' and col.direction = 'in' and col.amount = v_amt
        and col.method in ('transfer', 'card', 'pos', 'cheque', 'other') and col.received_at::date between bl.line_date - 5 and bl.line_date + 1
      order by private.name_in(cu.name, bl.description) desc, (col.reference is not null and position(upper(col.reference) in upper(bl.description || ' ' || coalesce(bl.reference, ''))) > 0) desc,
        abs(col.received_at::date - bl.line_date), col.received_at limit 1;
      if v_cnt = 1 or private.name_in((select name from customers where id = c.customer_id), bl.description) then
        update collections set status = 'confirmed', bank_account_id = b.id, confirmed_at = now(), note = concat_ws(' · ', note, 'Confirmed by the bank statement')
        where id = c.id;
        c := private.post_collection(c.id, m);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'pending_payment', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'pending_payment';
      end if;
    end if;

    -- 2b The invoice or order the narration names, whoever paid it (a director paying for the company, a relative).
    select * into s from sales x where x.org_id = bl.org_id and x.doc_type in ('invoice', 'order') and x.status in ('open', 'partially_paid') and x.journal_id is not null
      and x.issue_date <= bl.line_date + 1 and private.doc_in_text(x.number, v_text)
    order by x.issue_date desc limit 1;
    if s.id is not null then
      v_due := s.total - s.amount_paid - s.credited - coalesce((select sum(a.amount) from collection_allocations a join collections cc on cc.id = a.collection_id
        where a.sale_id = s.id and cc.status = 'pending'), 0);
      -- The invoice's own number and exactly what is owed (or that less WHT, and VAT for a customer who withholds VAT): settled.
      -- Any other amount is put to a person below.
      v_split := private.customer_short_split(s.id, v_due, v_amt);
      if abs(v_due - v_amt) < 0.005 or v_split is not null then
        if v_split is not null then
          perform private.book_customer_withholding(bl.org_id, s.customer_id, s.id, v_split, v_at, m);
        end if;
        c := private.add_collection(bl.org_id, s.customer_id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
          'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'Matched from the bank by ' || s.number, 'spread', false), m, 'confirmed', array[s.id]);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'invoice_ref', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'invoice_ref';
      end if;
    end if;
  else
    -- 3 Statutory payees clear the tax head, never an expense (AP-06).
    select * into r from payee_registry pr where pr.kind like 'statutory%' and pr.direction in ('out', 'both')
      and upper(bl.description || ' ' || coalesce(bl.counterparty, '')) ~ pr.pattern order by pr.id limit 1;
    if r.id is not null then
      j := private.post_bank_line(bl.id, coalesce(case when r.role is not null then private.acct(bl.org_id, r.role) end, r.account_code), null, null,
        r.description || ' · ' || bl.description, 'statutory', jsonb_build_object('matched_by', 'rule'));
      select coalesce(sum(credit - debit), 0) into v_head from journal_lines where org_id = bl.org_id and account_code = coalesce(case when r.role is not null then private.acct(bl.org_id, r.role) end, r.account_code);
      if v_head < -0.004 then
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'tax', 'remittance_without_accrual', 'bank_line', bl.id, 'Paid more ' || r.description || ' than the books owed',
          'This remittance is more than the liability on record. Is a return missing, or was this paid in advance?',
          jsonb_build_object('account', r.account_code, 'overpaid', -v_head), 1, 'AP-06 exception', 'statutory', 'info', v_amt, j.id) on conflict do nothing;
      end if;
      return 'statutory';
    end if;

    -- 3b The bill the narration names: Counta's number, or the supplier's own invoice number together with the amount
    --    owed or the supplier's name (a short invoice number alone could be a coincidence).
    select bb2.* into bb from bills bb2 where bb2.org_id = bl.org_id and bb2.status in ('approved', 'partially_paid')
      and (private.doc_in_text(bb2.number, v_text)
           or private.ref_in_text(bb2.vendor_ref, v_text) and (abs(bb2.total - bb2.amount_paid - v_amt) < 0.005
             or abs(bb2.total - bb2.amount_paid - greatest(bb2.wht_expected + bb2.wvat_expected - bb2.wht_withheld - bb2.wvat_withheld, 0) - v_amt) < 0.005
             or private.name_in((select name from vendors where id = bb2.vendor_id), coalesce(bl.counterparty, '') || ' ' || bl.description)))
    order by bb2.due_date limit 1;
    if bb.id is not null then
      v_due := bb.total - bb.amount_paid - coalesce((select sum(gross) from bill_payments where bill_id = bb.id and status = 'processing'), 0);
      v_left_wht := greatest(bb.wht_expected + bb.wvat_expected - bb.wht_withheld - bb.wvat_withheld
        - coalesce((select sum(wht + wvat) from bill_payments where bill_id = bb.id and status = 'processing'), 0), 0);
      v_rate := coalesce((bb.wht_expected + bb.wvat_expected) / nullif(bb.total, 0), 0);
      v_gross := case when abs(v_due - v_amt) < 0.005 then v_due
                      when v_left_wht > 0 and abs(v_due - v_left_wht - v_amt) < 0.005 then v_due end;
      if v_gross is not null then
        v_wht := greatest(v_gross - v_amt, 0);
        j := private.record_bill_payment(bb.id, b.id, v_gross, v_wht, v_at, coalesce(bl.reference, left(bl.description, 60)), m);
        update bank_lines set status = 'matched', journal_id = j.id, stage = 'bill_ref', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'bill_ref';
      end if;
    end if;
  end if;

  if v_in then
    -- 4 A customer named in the narration: their open invoices that fit are put to a person to confirm (AR-03).
    for v_cust in select cu.* from customers cu where cu.org_id = bl.org_id and not cu.is_walk_in and not cu.archived
        and private.name_in(cu.name, coalesce(bl.counterparty, '') || ' ' || bl.description)
        order by length(cu.name) desc limit 1 loop
      v_cands := private.match_candidates(bl.id);
      if jsonb_array_length(v_cands) > 0 then
        perform private.propose_match(bl.id, v_cands, 'customer');
        return 'customer';
      end if;
      select coalesce(sum(s2.total - s2.amount_paid - s2.credited), 0) into v_due from sales s2
      where s2.customer_id = v_cust.id and s2.status in ('open', 'partially_paid') and s2.journal_id is not null;
      -- Paying with nothing owed: held as an advance, flagged (AR rule).
      if v_due <= 0.004 then
        c := private.add_collection(bl.org_id, v_cust.id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
          'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'No invoice open: held as customer credit', 'spread', true), m, 'confirmed', null);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'customer_advance', matched_by = 'system', confidence = 0.8 where id = bl.id;
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'bookkeeper', 'advance_without_invoice', 'bank_line', bl.id, v_cust.name || ' paid with nothing owed',
          'Held as customer credit. Raise the invoice it was for, or refund it.', jsonb_build_object('customer_id', v_cust.id), 0.8,
          'AR: inflow from a known customer with no open invoice', 'customer', 'info', v_amt, c.journal_id) on conflict do nothing;
        return 'customer_advance';
      end if;
    end loop;
  else
    -- 5 A vendor named in the narration being paid for open bills (AP-03).
    for v_vendor in select v.* from vendors v where v.org_id = bl.org_id
        and (private.name_in(v.name, coalesce(bl.counterparty, '') || ' ' || bl.description)
             or (v.account_number is not null and position(v.account_number in coalesce(bl.counterparty_account, '') || bl.description) > 0))
        order by length(v.name) desc limit 1 loop
      v_cands := private.match_candidates(bl.id);
      if jsonb_array_length(v_cands) > 0 then
        perform private.propose_match(bl.id, v_cands, 'vendor_bill');
        return 'vendor_bill';
      end if;
      -- A known vendor with no matching bill: post to their usual account and ask for the bill (AP-05).
      if v_vendor.default_account is not null then
        j := private.post_bank_line(bl.id, v_vendor.default_account, null, null, v_vendor.name || ' · no bill', 'vendor_no_bill',
          jsonb_build_object('matched_by', 'rule', 'ai_confidence', 0.85));
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'bookkeeper', 'payment_without_bill', 'bank_line', bl.id, 'Paid ' || v_vendor.name || ' without a bill',
          'Posted to their usual account with no VAT claimed and no WHT. Upload the bill if there is one.', jsonb_build_object('vendor_id', v_vendor.id),
          0.85, 'AP-05', 'vendor_no_bill', 'info', v_amt, j.id) on conflict do nothing;
        return 'vendor_no_bill';
      end if;
    end loop;
  end if;

  -- 6 Money moving between the business's own accounts.
  select x.* into other from bank_lines x join bank_accounts xa on xa.id = x.bank_account_id
  where x.org_id = bl.org_id and x.bank_account_id <> bl.bank_account_id and x.amount = -bl.amount and x.status in ('unmatched', 'posted')
    and x.line_date between bl.line_date - 2 and bl.line_date + 2 and (x.status = 'unmatched' or x.stage = 'transfer_one_leg')
  order by abs(x.line_date - bl.line_date) limit 1;
  if other.id is not null then
    select * into ob from bank_accounts where id = other.bank_account_id;
    if other.status = 'unmatched' then
      j := private.post_entry(bl.org_id, 'Transfer between own accounts · ' || b.name || ' and ' || ob.name, 'bank', bl.id, m.id, null,
        private.reclass_pair(case when v_in then b.ledger_code else ob.ledger_code end, case when v_in then ob.ledger_code else b.ledger_code end, v_amt, null, null),
        v_at, jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id), jsonb_build_object('type', 'bank_line', 'id', other.id))));
      update bank_lines set status = 'matched', journal_id = j.id, stage = 'transfer', matched_by = 'system', confidence = 1 where id in (bl.id, other.id);
    else
      j := private.post_bank_line(bl.id, private.acct(bl.org_id, 'bank_clearing'), null, null, 'Transfer between own accounts · ' || ob.name, 'transfer',
        jsonb_build_object('matched_by', 'system'), 'matched');
      update bank_lines set stage = 'transfer' where id = other.id;
    end if;
    return 'transfer';
  end if;
  -- 6b Money sent to Bujeti from this account (or taken back from it): a transfer to or from the Bujeti balance.
  if upper(v_text) ~ '\yBUJETI\y' then
    select xa.* into ob from bank_accounts xa where xa.org_id = bl.org_id and xa.id <> b.id and xa.active and xa.provider = 'integration'
      and xa.provider_ref = bl.org_id::text || ':bujeti';
    if ob.id is not null then
      perform private.post_bank_line(bl.id, ob.ledger_code, null, null, case when v_in then 'Money back from Bujeti · ' else 'Money sent to Bujeti · ' end || bl.description,
        'transfer', jsonb_build_object('matched_by', 'system'));
      return 'transfer';
    end if;
  end if;
  if exists (select 1 from bank_accounts xa where xa.org_id = bl.org_id and xa.id <> b.id and xa.active
             and ((xa.account_number is not null and position(xa.account_number in coalesce(bl.counterparty_account, '') || ' ' || bl.description) > 0)
                  or upper(bl.description) ~ '(OWN ACCOUNT|SELF TRANSFER|TRF TO SELF|SWEEP)')) then
    perform private.post_bank_line(bl.id, private.acct(bl.org_id, 'bank_clearing'), null, null, 'Transfer between own accounts, other side to come', 'transfer_one_leg',
      jsonb_build_object('matched_by', 'system'));
    return 'transfer_one_leg';
  end if;

  -- 7 A rule learned from an earlier decision.
  select * into v_rule from entity_rules er where er.org_id = bl.org_id and er.direction = case when v_in then 'in' else 'out' end
    and v_key is not null and (er.party_key = v_key or position(er.party_key in v_key) > 0) order by length(er.party_key) desc limit 1;
  if v_rule.id is not null and private.postable(bl.org_id, v_rule.account_code) then
    perform private.post_bank_line(bl.id, v_rule.account_code,
      case when v_rule.customer_id is not null then 'customer' when v_rule.vendor_id is not null then 'vendor' end, coalesce(v_rule.customer_id, v_rule.vendor_id),
      null, 'rule', jsonb_build_object('matched_by', 'rule', 'ai_confidence', 0.95));
    update entity_rules set hits = hits + 1 where id = v_rule.id;
    return 'rule';
  end if;

  -- 8 Payee types: bank charges, power, telcos, internet, fuel, CAC, interest received.
  select * into r from payee_registry pr where pr.kind not like 'statutory%' and pr.direction in (case when v_in then 'in' else 'out' end, 'both')
    and upper(bl.description || ' ' || coalesce(bl.counterparty, '')) ~ pr.pattern order by pr.id limit 1;
  if r.id is not null then
    perform private.post_bank_line(bl.id, coalesce(case when r.role is not null then private.acct(bl.org_id, r.role) end, r.account_code), null, null,
      r.description || ' · ' || bl.description, 'registry', jsonb_build_object('matched_by', 'rule', 'ai_confidence', 0.9));
    return 'registry';
  end if;

  -- 9 Nobody named: the open invoices (or bills) the amount fits, as it stands, less WHT or less bank charges, are put to a
  --   person to confirm in one tap.
  v_cands := private.match_candidates(bl.id);
  if jsonb_array_length(v_cands) > 0 then
    perform private.propose_match(bl.id, v_cands, case when v_in then 'invoice_amount' else 'bill_amount' end);
    return case when v_in then 'invoice_amount' else 'bill_amount' end;
  end if;
  return null;
end $$;
revoke all on function private.match_bank_line(uuid) from public, anon, authenticated;
