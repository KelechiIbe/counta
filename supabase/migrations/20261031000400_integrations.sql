-- Counta · Connected tools
--
-- A business connects the tools it already uses, and Counta records what they sell, or tells its team where it works:
--   Paystack and Flutterwave (its own accounts): every successful payment becomes a paid sale, the provider's fee booked,
--     the money held in a "<provider> balance" account until the provider settles it to the bank (matched in Banking).
--   Selar, WooCommerce, Shopify, and anything through Zapier or Make: paid orders become paid sales the same way.
--   Bumpa: orders exported from Bumpa (CSV) are imported as paid sales.
--   Slack: Counta's alerts (payments in, tax deadlines, books) post to a channel.
--   WhatsApp Business: the business's own number sends its messages (OpenWA, in 20261031000200).
-- No accounting tools: the books live in Counta.
--
-- Keys and tokens are kept in Supabase Vault and only the integrations edge function reads them. A webhook address
-- carries a random token that Counta keeps only as a hash; Paystack's and Flutterwave's webhooks are checked against the
-- business's own key or the secret hash Counta made for it.

alter table public.bank_accounts drop constraint if exists bank_accounts_provider_check;
alter table public.bank_accounts add constraint bank_accounts_provider_check check (provider in ('manual', 'flutterwave', 'mono', 'rail', 'statement', 'integration'));

create table if not exists public.integrations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  provider text not null check (provider in ('paystack', 'flutterwave', 'selar', 'woocommerce', 'shopify', 'zapier', 'bumpa', 'slack')),
  status text not null default 'active' check (status in ('active', 'paused', 'error', 'disconnected')),
  label text check (label is null or length(label) <= 80),
  settings jsonb not null default '{}'::jsonb,
  secret_id uuid,
  secret_hint text check (secret_hint is null or length(secret_hint) <= 12),
  hook_token_hash text,
  hook_secret_id uuid,
  bank_account_id uuid references public.bank_accounts(id) on delete set null,
  connected_by uuid references public.members(id) on delete set null,
  connected_at timestamptz not null default now(),
  last_sync_at timestamptz,
  last_event_at timestamptz,
  last_error text,
  last_error_at timestamptz,
  cursor jsonb not null default '{}'::jsonb,
  recorded int not null default 0,
  created_at timestamptz not null default now()
);
create unique index if not exists integrations_live on public.integrations(org_id, provider) where status <> 'disconnected';
create unique index if not exists integrations_hook on public.integrations(hook_token_hash) where hook_token_hash is not null;
create index if not exists integrations_bank on public.integrations(bank_account_id);
create index if not exists integrations_connected_by on public.integrations(connected_by);
create index if not exists integrations_due on public.integrations(provider, last_sync_at) where status in ('active', 'error');
alter table public.integrations enable row level security;
revoke all on public.integrations from anon, authenticated;

-- What each connection did: a sale recorded, a payment seen twice, something skipped and why.
create table if not exists public.integration_events (
  id bigint generated always as identity primary key,
  integration_id uuid not null references public.integrations(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  external_id text not null check (length(external_id) between 1 and 200),
  status text not null check (status in ('recorded', 'skipped', 'failed')),
  amount numeric(16,2),
  sale_id uuid references public.sales(id) on delete set null,
  message text check (message is null or length(message) <= 400),
  created_at timestamptz not null default now(),
  unique (integration_id, external_id)
);
create index if not exists integration_events_org on public.integration_events(org_id, created_at desc);
create index if not exists integration_events_sale on public.integration_events(sale_id);
create index if not exists integration_events_ext on public.integration_events(org_id, external_id);
alter table public.integration_events enable row level security;
revoke all on public.integration_events from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. What a business sees and changes
-- ---------------------------------------------------------------------------
create or replace function private.integration_name(p text) returns text
language sql immutable set search_path = '' as $$
  select case p when 'paystack' then 'Paystack' when 'flutterwave' then 'Flutterwave' when 'selar' then 'Selar' when 'woocommerce' then 'WooCommerce'
    when 'shopify' then 'Shopify' when 'zapier' then 'Zapier or Make' when 'bumpa' then 'Bumpa' when 'slack' then 'Slack' else p end
$$;

create or replace function private.integration_json(i public.integrations) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', i.id, 'provider', i.provider, 'name', private.integration_name(i.provider), 'status', i.status, 'label', i.label,
    'settings', i.settings, 'secret_hint', i.secret_hint, 'has_hook', i.hook_token_hash is not null, 'connected_at', i.connected_at,
    'connected_by', (select display_name from members where id = i.connected_by), 'last_sync_at', i.last_sync_at, 'last_event_at', i.last_event_at,
    'last_error', i.last_error, 'last_error_at', i.last_error_at, 'recorded', i.recorded,
    'account', (select jsonb_build_object('id', b.id, 'name', b.name, 'code', b.ledger_code) from bank_accounts b where b.id = i.bank_account_id),
    'today', (select count(*) from integration_events e where e.integration_id = i.id and e.status = 'recorded' and e.created_at > now() - interval '1 day'))
$$;

create or replace function public.org_integrations(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  return jsonb_build_object(
    'can_manage', (m.role = 'owner' or private.perm_of(m, 'manage_settings')) and not (select is_sample from orgs where id = p_org),
    'sample', (select is_sample from orgs where id = p_org),
    'connected', (select coalesce(jsonb_agg(private.integration_json(i) order by i.connected_at), '[]'::jsonb) from integrations i
      where i.org_id = p_org and i.status <> 'disconnected'),
    'whatsapp', public.org_whatsapp(p_org),
    'bank_feeds', (select count(*) from bank_accounts where org_id = p_org and provider = 'mono' and active),
    'locations', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name) order by l.is_main desc, l.name), '[]'::jsonb) from locations l where l.org_id = p_org));
end $$;

-- What a connection did lately.
create or replace function public.integration_events_list(p_integration uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare i public.integrations;
begin
  select * into i from integrations where id = p_integration;
  if not found then raise exception 'Not found.'; end if;
  perform private.require(i.org_id, null);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'external_id', e.external_id, 'status', e.status, 'amount', e.amount, 'message', e.message,
      'created_at', e.created_at, 'sale', (select jsonb_build_object('id', s.id, 'number', s.number, 'total', s.total) from sales s where s.id = e.sale_id))
      order by e.created_at desc), '[]'::jsonb)
    from (select * from integration_events where integration_id = i.id order by created_at desc limit 50) e);
end $$;

-- p: {location_id, kinds (Slack), paused: true|false, label}
create or replace function public.integration_settings(p_integration uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.integrations; m public.members; v_set jsonb;
begin
  select * into i from integrations where id = p_integration and status <> 'disconnected';
  if not found then raise exception 'Not found.'; end if;
  m := private.require(i.org_id, 'manage_settings');
  v_set := i.settings;
  if p ? 'location_id' then
    if nullif(p->>'location_id', '') is not null and not exists (select 1 from locations where id = (p->>'location_id')::uuid and org_id = i.org_id) then raise exception 'Unknown branch.'; end if;
    v_set := v_set || jsonb_build_object('location_id', nullif(p->>'location_id', ''));
  end if;
  if p ? 'kinds' then
    if jsonb_typeof(p->'kinds') <> 'array' or exists (select 1 from jsonb_array_elements_text(p->'kinds') k where k not in ('payments', 'tax', 'books', 'team')) then
      raise exception 'Choose what to post: payments, tax, books or team.';
    end if;
    v_set := v_set || jsonb_build_object('kinds', p->'kinds');
  end if;
  update integrations set settings = v_set, label = case when p ? 'label' then nullif(left(trim(p->>'label'), 80), '') else label end,
    status = case when p ? 'paused' then case when (p->>'paused')::boolean then 'paused' else 'active' end else status end
  where id = i.id returning * into i;
  return private.integration_json(i);
end $$;

-- Disconnecting forgets the keys at once; what was recorded stays in the books.
create or replace function public.integration_disconnect(p_integration uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.integrations; m public.members;
begin
  select * into i from integrations where id = p_integration and status <> 'disconnected' for update;
  if not found then raise exception 'Not found.'; end if;
  m := private.require(i.org_id, 'manage_settings');
  delete from vault.secrets where id in (i.secret_id, i.hook_secret_id);
  update integrations set status = 'disconnected', secret_id = null, hook_secret_id = null, hook_token_hash = null, secret_hint = null where id = i.id;
  return jsonb_build_object('disconnected', true, 'provider', i.provider);
end $$;

-- Before the integrations function talks to a provider for a business: who is asking, and may they.
create or replace function public.integration_check(p_org uuid, p_provider text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, 'manage_settings');
  if (select is_sample from orgs where id = p_org) then raise exception 'The sample business cannot connect tools. Use your own business.'; end if;
  if p_provider not in ('paystack', 'flutterwave', 'selar', 'woocommerce', 'shopify', 'zapier', 'bumpa', 'slack') then raise exception 'Unknown tool.'; end if;
  return jsonb_build_object('member_id', m.id, 'org_id', p_org, 'org_name', (select name from orgs where id = p_org),
    'existing', (select private.integration_json(i) from integrations i where i.org_id = p_org and i.provider = p_provider and i.status <> 'disconnected'));
end $$;

-- An integration of this business, for the function (sync now, a new webhook address, the events), as its manager.
create or replace function public.integration_manage(p_integration uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare i public.integrations;
begin
  select * into i from integrations where id = p_integration and status <> 'disconnected';
  if not found then raise exception 'Not found.'; end if;
  perform private.require(i.org_id, 'manage_settings');
  return private.integration_json(i) || jsonb_build_object('org_id', i.org_id);
end $$;

-- ---------------------------------------------------------------------------
-- 2. For the integrations function only
-- ---------------------------------------------------------------------------
-- The account a tool's money sits in until it is settled: one per connection, made the first time.
create or replace function private.integration_account(i public.integrations, p_author uuid) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare b public.bank_accounts;
begin
  if i.bank_account_id is not null and exists (select 1 from bank_accounts where id = i.bank_account_id and active) then return i.bank_account_id; end if;
  select * into b from bank_accounts where org_id = i.org_id and provider = 'integration' and provider_ref = i.org_id::text || ':' || i.provider;
  if not found then
    b := private.open_bank_account(i.org_id, 'wallet', private.integration_name(i.provider) || case when i.provider in ('paystack', 'flutterwave', 'selar') then ' balance' else ' payments' end,
      jsonb_build_object('provider', 'integration', 'provider_ref', i.org_id::text || ':' || i.provider, 'provider_meta', jsonb_build_object('integration', i.provider)), p_author);
  elsif not b.active then
    update bank_accounts set active = true where id = b.id;
  end if;
  update integrations set bank_account_id = b.id where id = i.id;
  return b.id;
end $$;

-- p: {org_id, provider, member_id, secret, secret_hint, hook_token (plain; kept as a hash), hook_secret, settings, label}
create or replace function public.svc_integration_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.integrations; v_org uuid := (p->>'org_id')::uuid; v_prov text := p->>'provider'; m public.members; v_secret uuid; v_hook uuid;
begin
  select * into m from members where id = (p->>'member_id')::uuid and org_id = v_org and status = 'active';
  if not found or not (m.role = 'owner' or private.perm_of(m, 'manage_settings')) then raise exception 'Only the owner or someone who manages settings connects tools.'; end if;
  select * into i from integrations where org_id = v_org and provider = v_prov and status <> 'disconnected' for update;
  if nullif(p->>'secret', '') is not null then
    if i.secret_id is not null then perform vault.update_secret(i.secret_id, p->>'secret'); v_secret := i.secret_id;
    else v_secret := vault.create_secret(p->>'secret', 'integration:' || gen_random_uuid()::text, 'A ' || private.integration_name(v_prov) || ' key for ' || v_org::text); end if;
  else v_secret := i.secret_id; end if;
  if nullif(p->>'hook_secret', '') is not null then
    if i.hook_secret_id is not null then perform vault.update_secret(i.hook_secret_id, p->>'hook_secret'); v_hook := i.hook_secret_id;
    else v_hook := vault.create_secret(p->>'hook_secret', 'integration-hook:' || gen_random_uuid()::text, 'A webhook secret for ' || v_org::text); end if;
  else v_hook := i.hook_secret_id; end if;
  if i.id is null then
    insert into integrations (org_id, provider, status, label, settings, secret_id, secret_hint, hook_token_hash, hook_secret_id, connected_by)
    values (v_org, v_prov, 'active', nullif(left(trim(p->>'label'), 80), ''), coalesce(p->'settings', '{}'::jsonb), v_secret, nullif(left(p->>'secret_hint', 12), ''),
      case when nullif(p->>'hook_token', '') is not null then encode(extensions.digest(p->>'hook_token', 'sha256'), 'hex') end, v_hook, m.id)
    returning * into i;
  else
    update integrations set status = 'active', label = coalesce(nullif(left(trim(p->>'label'), 80), ''), label), settings = settings || coalesce(p->'settings', '{}'::jsonb),
      secret_id = v_secret, secret_hint = coalesce(nullif(left(p->>'secret_hint', 12), ''), secret_hint),
      hook_token_hash = case when nullif(p->>'hook_token', '') is not null then encode(extensions.digest(p->>'hook_token', 'sha256'), 'hex') else hook_token_hash end,
      hook_secret_id = v_hook, connected_by = m.id, connected_at = case when status = 'active' then connected_at else now() end, last_error = null, last_error_at = null
    where id = i.id returning * into i;
  end if;
  if v_prov <> 'slack' then perform private.integration_account(i, m.id); select * into i from integrations where id = i.id; end if;
  return private.integration_json(i) || jsonb_build_object('org_id', i.org_id);
end $$;

-- The keys, for the function as it talks to the provider.
create or replace function public.svc_integration(p_integration uuid) returns jsonb
language sql stable security definer set search_path = public, private, vault as $$
  select private.integration_json(i) || jsonb_build_object('org_id', i.org_id, 'cursor', i.cursor,
    'secret', (select decrypted_secret from vault.decrypted_secrets where id = i.secret_id),
    'hook_secret', (select decrypted_secret from vault.decrypted_secrets where id = i.hook_secret_id))
  from integrations i where i.id = p_integration and i.status <> 'disconnected'
$$;

-- A webhook address's connection, by the token in it.
create or replace function public.svc_integration_by_token(p_provider text, p_token text) returns uuid
language sql stable security definer set search_path = public, private as $$
  select id from integrations where provider = p_provider and status in ('active', 'error')
    and hook_token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
$$;

-- Connections the poll looks at: payments and stores every few minutes, Slack with something to post.
create or replace function public.svc_integrations_due() returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'provider', i.provider, 'org_id', i.org_id) order by i.last_sync_at nulls first), '[]'::jsonb)
  from integrations i where i.status in ('active', 'error') and i.provider in ('paystack', 'flutterwave', 'woocommerce', 'shopify', 'slack')
    and (i.last_sync_at is null or i.last_sync_at < now() - interval '4 minutes')
$$;

-- p: {cursor, error (text, or null to clear), hard: true when the tool refused the key, synced: true}
-- last_error_at is when the current run of failures began. A refused key needs attention at once; anything else (the tool down,
-- a timeout) only once it has kept failing for half an hour, so a passing outage does not alarm the owner.
create or replace function public.svc_integration_note(p_integration uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.integrations; v_was text; v_err text := nullif(left(p->>'error', 300), ''); v_since timestamptz;
begin
  select * into i from integrations where id = p_integration for update;
  if not found then return null; end if;
  v_was := i.status;
  v_since := case when v_err is not null then coalesce(i.last_error_at, now()) end;
  update integrations set cursor = case when p ? 'cursor' then cursor || coalesce(p->'cursor', '{}'::jsonb) else cursor end,
    last_sync_at = case when coalesce((p->>'synced')::boolean, false) then now() else last_sync_at end,
    last_error = case when p ? 'error' then v_err else last_error end,
    last_error_at = case when p ? 'error' then v_since else last_error_at end,
    status = case when status in ('paused', 'disconnected') then status
      when v_err is not null and (coalesce((p->>'hard')::boolean, false) or v_since <= now() - interval '30 minutes') then 'error'
      when p ? 'error' and v_err is null then 'active' else status end
  where id = i.id returning * into i;
  -- A connection that stops working is told to the owner once.
  if i.status = 'error' and v_was <> 'error' then
    perform private.notify_perm(i.org_id, 'owner', 'books', private.integration_name(i.provider) || ' stopped working', left(i.last_error, 200), '/integrations', 'integration-' || i.id);
  end if;
  return private.integration_json(i);
end $$;

-- A sale from a connected tool, as the business's owner records it: paid, into the tool's own account, the fee booked.
-- p: {external_id, occurred_at, amount, fee, currency, reference, method, note, customer: {name, email, phone}, lines: [{name, sku, qty, unit_price}]}
create or replace function public.svc_integration_sale(p_integration uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.integrations; o public.orgs; m public.members; s public.sales; v_ext text := left(trim(coalesce(p->>'external_id', '')), 200); v_amt numeric; v_fee numeric;
  v_cust uuid; v_email text; v_phone text; v_name text; x jsonb; v_lines jsonb := '[]'::jsonb; it public.items; v_sum numeric := 0; v_rate numeric; v_q numeric; v_p numeric;
  v_bank uuid; v_at timestamptz; v_msg text; c public.collections; v_ok boolean := false;
begin
  select * into i from integrations where id = p_integration and status in ('active', 'error') for update;
  if not found then return jsonb_build_object('status', 'skipped', 'message', 'The connection is paused or gone.'); end if;
  if v_ext = '' then raise exception 'A sale from % needs its id.', private.integration_name(i.provider); end if;
  -- Recorded already: by this connection, or by an earlier one of the same tool (disconnected and connected again), whose payment
  -- carries the same id. The tools' ids carry their own prefix (ps:, flw:, woo:...), so they cannot clash across tools.
  if exists (select 1 from integration_events where org_id = i.org_id and external_id = v_ext and status = 'recorded')
     or exists (select 1 from collections where org_id = i.org_id and provider_ref = v_ext) then
    return jsonb_build_object('status', 'duplicate', 'sale_id', (select e.sale_id from integration_events e where e.org_id = i.org_id and e.external_id = v_ext
      and e.status = 'recorded' order by e.created_at desc limit 1));
  end if;
  select * into o from orgs where id = i.org_id;
  v_amt := round(coalesce(private.num(p->>'amount'), 0), 2);
  v_fee := round(greatest(coalesce(private.num(p->>'fee'), 0), 0), 2);
  v_at := least(coalesce(nullif(p->>'occurred_at', '')::timestamptz, now()), now());
  begin
    if upper(coalesce(nullif(p->>'currency', ''), 'NGN')) <> 'NGN' then
      v_msg := 'Paid in ' || upper(p->>'currency') || '. Counta records naira payments from connected tools; record this one by hand.';
    elsif v_amt <= 0 then
      v_msg := 'Nothing was paid.';
    elsif v_fee >= v_amt then
      v_msg := 'The fee is more than the payment.';
    end if;
    if v_msg is null then
      -- The business's owner records it (the person who connected the tool may leave; the owner stays).
      select * into m from members where org_id = i.org_id and role = 'owner' and status = 'active' order by created_at limit 1;
      -- The customer: one the business already has (by email or phone), a new one with the details paid with, or walk-in.
      v_email := nullif(lower(trim(p->'customer'->>'email')), '');
      if v_email is not null and v_email !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' then v_email := null; end if;
      v_phone := private.clean_phone(p->'customer'->>'phone');
      v_name := nullif(left(trim(regexp_replace(coalesce(p->'customer'->>'name', ''), '\s+', ' ', 'g')), 120), '');
      select id into v_cust from customers where org_id = i.org_id and not archived and not is_walk_in
        and ((v_email is not null and lower(email) = v_email) or (v_phone is not null and phone = v_phone)) order by created_at limit 1;
      if v_cust is null and (v_name is not null or v_email is not null) then
        v_cust := private.upsert_customer(i.org_id, jsonb_strip_nulls(jsonb_build_object('name', coalesce(v_name, split_part(v_email, '@', 1)), 'email', v_email, 'phone', v_phone)), m);
      end if;
      -- The lines: products the business sells, matched by SKU or name; anything else as a line with the tool's description.
      v_rate := case when o.vat_registered and not o.prices_include_vat then private.vat_rate(private.local_day(i.org_id, v_at)) else 0 end;
      for x in select value from jsonb_array_elements(case when jsonb_typeof(p->'lines') = 'array' and jsonb_array_length(p->'lines') > 0 then p->'lines'
               else jsonb_build_array(jsonb_build_object('name', coalesce(nullif(trim(p->>'note'), ''), private.integration_name(i.provider) || ' sale'), 'qty', 1, 'unit_price', v_amt)) end) loop
        v_q := greatest(coalesce(round(private.num(x->>'qty'), 3), 1), 0.001);
        v_p := round(coalesce(private.num(x->>'unit_price'), 0), 2);
        it := null;
        if nullif(trim(x->>'sku'), '') is not null then
          select * into it from items where org_id = i.org_id and not archived and (lower(sku) = lower(trim(x->>'sku')) or barcode = trim(x->>'sku')) limit 1;
        end if;
        if it.id is null and nullif(trim(x->>'name'), '') is not null then
          select * into it from items where org_id = i.org_id and not archived and lower(name) = lower(trim(x->>'name')) limit 1;
        end if;
        -- The tool's price includes VAT; a business whose prices exclude VAT records the price before VAT, so the total is what was paid.
        v_p := round(v_p / (1 + case when coalesce(it.vat_treatment, 'standard') = 'standard' then v_rate else 0 end), 2);
        if it.id is not null then
          v_lines := v_lines || jsonb_build_array(jsonb_build_object('item_id', it.id, 'qty', v_q, 'unit_price', v_p));
        else
          v_lines := v_lines || jsonb_build_array(jsonb_build_object('description', left(coalesce(nullif(trim(x->>'name'), ''), private.integration_name(i.provider) || ' sale'), 300),
            'qty', v_q, 'unit_price', v_p, 'vat_treatment', case when o.vat_registered then 'standard' else 'exempt' end));
        end if;
        v_sum := v_sum + v_q * v_p;
      end loop;
      v_bank := private.integration_account(i, m.id);
      s := private.create_sale(i.org_id, jsonb_strip_nulls(jsonb_build_object('doc_type', 'receipt', 'status', 'issue', 'channel', 'online',
        'location_id', nullif(i.settings->>'location_id', ''), 'customer_id', v_cust, 'recorded_at', v_at,
        'reference', left(coalesce(nullif(trim(p->>'reference'), ''), v_ext), 80),
        'notes', left(private.integration_name(i.provider) || ' · ' || coalesce(nullif(trim(p->>'reference'), ''), v_ext) || coalesce(' · ' || nullif(trim(p->>'note'), ''), ''), 500),
        'pay_in_full', 'later', 'lines', v_lines)), m);
      if v_name is not null and v_cust is null then update sales set customer_name = v_name where id = s.id; end if;
      -- Paid: the money is in the tool's account, the fee booked as a payment fee. A kobo or two of rounding stays with the sale.
      c := private.add_collection(i.org_id, s.customer_id, case when abs(v_amt - s.total) <= 1 then s.total else v_amt end,
        case when p->>'method' in ('transfer', 'card') then p->>'method' else 'other' end,
        jsonb_build_object('bank_account_id', v_bank, 'fee', least(v_fee, s.total), 'provider_ref', v_ext, 'reference', left(coalesce(nullif(trim(p->>'reference'), ''), v_ext), 80),
          'received_at', v_at, 'spread', false, 'note', 'Paid through ' || private.integration_name(i.provider)), m, 'confirmed', array[s.id]);
      update sales set settle_later = false where id = s.id;
      select * into s from sales where id = s.id;
      v_ok := true;
    end if;
  exception when others then
    v_msg := left(sqlerrm, 300);
  end;
  insert into integration_events (integration_id, org_id, external_id, status, amount, sale_id, message)
  values (i.id, i.org_id, v_ext, case when v_ok then 'recorded' when v_msg like 'Paid in%' or v_msg = 'Nothing was paid.' then 'skipped' else 'failed' end, v_amt,
    case when v_ok then s.id end, v_msg)
  on conflict (integration_id, external_id) do update set status = excluded.status, amount = excluded.amount, sale_id = excluded.sale_id, message = excluded.message, created_at = now();
  update integrations set last_event_at = now(), recorded = recorded + case when v_ok then 1 else 0 end where id = i.id;
  if v_ok then
    return jsonb_build_object('status', 'recorded', 'sale_id', s.id, 'number', s.number, 'total', s.total, 'customer_id', s.customer_id);
  end if;
  return jsonb_build_object('status', case when v_msg like 'Paid in%' or v_msg = 'Nothing was paid.' then 'skipped' else 'failed' end, 'message', v_msg);
end $$;

-- What Slack should hear: the business's notifications since the last post, once each (every person gets their own copy).
create or replace function public.svc_slack_outbox(p_integration uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare i public.integrations; v_since timestamptz; v_kinds text[];
begin
  select * into i from integrations where id = p_integration and provider = 'slack' and status in ('active', 'error');
  if not found then return '[]'::jsonb; end if;
  v_since := coalesce(nullif(i.cursor->>'since', '')::timestamptz, i.connected_at);
  select coalesce(array_agg(k), '{payments,tax}') into v_kinds from jsonb_array_elements_text(coalesce(i.settings->'kinds', '["payments","tax"]'::jsonb)) k;
  return (select coalesce(jsonb_agg(jsonb_build_object('title', x.title, 'body', x.body, 'url', x.url, 'at', x.at) order by x.at), '[]'::jsonb) from (
    select n.title, n.body, n.url, max(n.created_at) at from notifications n
    where n.org_id = i.org_id and n.created_at > v_since and n.created_at > now() - interval '2 days'
      and (case when n.kind in ('payment', 'payout', 'transfer_sent', 'receipt_ready', 'order') then 'payments'
                when n.kind in ('tax', 'alert', 'identity') then 'tax'
                when n.kind in ('books', 'bank', 'banking', 'bill', 'price_proposal', 'count_submitted') then 'books'
                else 'team' end) = any (v_kinds)
    group by n.title, n.body, n.url order by max(n.created_at) limit 30) x);
end $$;

revoke execute on function public.org_integrations(uuid), public.integration_events_list(uuid), public.integration_settings(uuid, jsonb), public.integration_disconnect(uuid),
  public.integration_check(uuid, text), public.integration_manage(uuid) from public, anon;
grant execute on function public.org_integrations(uuid), public.integration_events_list(uuid), public.integration_settings(uuid, jsonb), public.integration_disconnect(uuid),
  public.integration_check(uuid, text), public.integration_manage(uuid) to authenticated;
revoke all on function public.svc_integration_save(jsonb), public.svc_integration(uuid), public.svc_integration_by_token(text, text), public.svc_integrations_due(),
  public.svc_integration_note(uuid, jsonb), public.svc_integration_sale(uuid, jsonb), public.svc_slack_outbox(uuid) from public, anon, authenticated;
grant execute on function public.svc_integration_save(jsonb), public.svc_integration(uuid), public.svc_integration_by_token(text, text), public.svc_integrations_due(),
  public.svc_integration_note(uuid, jsonb), public.svc_integration_sale(uuid, jsonb), public.svc_slack_outbox(uuid) to service_role;
revoke all on function private.integration_name(text), private.integration_json(public.integrations), private.integration_account(public.integrations, uuid)
  from public, anon, authenticated;

-- Every five minutes: new payments and orders from the connected tools, and Slack's posts.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'counta-integrations';
    -- Only when some business has a tool to look at, so the function is not called for nothing.
    perform cron.schedule('counta-integrations', '*/5 * * * *', $c$select private.call_function('integrations', '{"action":"poll"}'::jsonb)
      where exists (select 1 from public.integrations where status in ('active', 'error') and provider in ('paystack', 'flutterwave', 'woocommerce', 'shopify', 'slack'))$c$);
  end if;
end $$;
