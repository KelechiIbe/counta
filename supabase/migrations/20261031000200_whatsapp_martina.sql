-- Counta · WhatsApp through OpenWA, and Martina on WhatsApp and Siri
--
-- 1. WhatsApp through OpenWA. TaxStreem runs OpenWA (github.com/rmyndharis/OpenWA) on its own server with a number used
--    only for Counta. The admin portal connects it: Counta creates the WhatsApp session there, gives OpenWA a webhook
--    secret, and shows the QR code to scan. WHATSAPP_PROVIDER says which WhatsApp sends (openwa or meta, the official API).
--    A business may also link its own WhatsApp number (when TaxStreem allows it: OPENWA_BUSINESS_NUMBERS), so its invoices
--    and reminders come from that number. whatsapp_sessions keeps each session's state as OpenWA reports it.
--    OpenWA is unofficial: WhatsApp may restrict any number linked to it. Counta never sends money on WhatsApp's word.
-- 2. Martina on WhatsApp. Someone links their WhatsApp number to their place in a business (chat_links): they type their
--    number in Counta, Counta gives a six-digit code, and they send "LINK <code>" from that number to TaxStreem's number.
--    After that, what they write or say (voice notes) to the number goes to Martina, who answers as she would in Counta,
--    acting only as that person and only within what their role allows (svc_chat_rpc runs each step as them).
-- 3. Martina on Siri. Someone makes a personal key (a chat_links row with a hashed key, shown once); an iPhone shortcut
--    sends what they say to Counta with that key and speaks the answer.
-- Actions on a yes work as in the app: Martina prepares the action and reads it back; it is carried out only when the
-- person's own next words are a yes. Money out is never done here: Martina sends a link to open it in Counta.

-- ---------------------------------------------------------------------------
-- 1. Settings, sessions and webhook deliveries
-- ---------------------------------------------------------------------------
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
    ('APP_URL', 'counta', 'Counta web address', false, 'Used in links in emails and messages. Leave empty for https://counta-taxstreem.netlify.app.', 901),
    ('VAPID_SUBJECT', 'counta', 'Contact for push notifications', false, 'mailto: and an address browsers may write to about notifications.', 902),
    ('KYC_REVIEW_EMAIL', 'counta', 'Email for NIN slip reviews', false, 'Where Counta writes when a business''s NIN slip needs checking. Leave empty for admin@taxstreem.com. Reviewers on the Team page are told as well.', 903)
$$;

create or replace function public.admin_set_secret(p_name text, p_value text) returns jsonb
language plpgsql security definer set search_path = public, private, vault as $$
declare c record; v text := btrim(coalesce(p_value, '')); v_id uuid; v_shown text; j jsonb;
begin
  perform private.require_staff();
  select * into c from private.secret_catalog() x where x.name = p_name;
  if not found then raise exception 'Unknown setting.'; end if;
  if v = '' then raise exception 'Paste the value first. To clear it, use Remove.'; end if;
  if length(v) > 20000 then raise exception 'That is too long for a key.'; end if;
  if p_name = 'GOOGLE_APPLICATION_CREDENTIALS_JSON' then
    begin j := v::jsonb; exception when others then raise exception 'Paste the whole JSON key file, from { to }.'; end;
    if jsonb_typeof(j) <> 'object' or coalesce(j->>'type', '') = '' then raise exception 'That JSON has no "type". Paste the whole key file.'; end if;
    v_shown := coalesce(j->>'client_email', j->>'type');
  elsif p_name = 'FLW_RELAY_SECRET' then
    -- The relay's secret is 64 hex characters. A paste from the server often brings the "RELAY_SECRET=" before it or the
    -- terminal prompt after it; only the 64 characters are kept.
    v := lower(substring(v from '(?i)([0-9a-f]{64})'));
    if v is null then raise exception 'Paste the 64 characters after RELAY_SECRET= in /etc/counta-relay.env on the relay server.'; end if;
    v_shown := '•••• ' || right(v, 4);
  elsif c.secret then
    if length(v) < 8 then raise exception 'That is too short for a key.'; end if;
    v_shown := '•••• ' || right(v, 4);
  else
    if p_name in ('NUMENS_API_URL', 'FLUX_URL', 'APP_URL', 'FLW_RELAY_URL', 'OPENWA_URL') and v !~ '^https://[^\s]+$' then raise exception 'Enter an https:// address.'; end if;
    if p_name = 'OPENWA_URL' then v := regexp_replace(v, '/+(api/?)?$', ''); end if;
    if p_name = 'WHATSAPP_PROVIDER' and lower(v) not in ('openwa', 'meta') then raise exception 'Enter openwa or meta.'; end if;
    if p_name = 'OPENWA_BUSINESS_NUMBERS' and lower(v) not in ('on', 'off') then raise exception 'Enter on or off.'; end if;
    if p_name in ('WHATSAPP_PROVIDER', 'OPENWA_BUSINESS_NUMBERS') then v := lower(v); end if;
    if p_name = 'RESEND_FROM' and v !~* '[A-Z0-9._%+-]+@[A-Z0-9-]+(\.[A-Z0-9-]+)*\.[A-Z]{2,}' then raise exception 'Enter an email address, such as billing@taxstreem.com.'; end if;
    if p_name = 'VAPID_SUBJECT' and v !~ '^(mailto:[^\s@]+@[^\s@]+|https://[^\s]+)$' then raise exception 'Enter mailto: and an email address.'; end if;
    if p_name = 'KYC_REVIEW_EMAIL' and v !~* '^[A-Z0-9._%+-]+@[A-Z0-9-]+(\.[A-Z0-9-]+)*\.[A-Z]{2,}$' then
      raise exception 'Enter one email address, such as admin@taxstreem.com.';
    end if;
    if p_name in ('GOOGLE_CLOUD_LOCATION', 'GEMINI_MODEL', 'ELEVENLABS_TTS_MODEL', 'TAXSTREEM_SSO_ISSUER', 'GOOGLE_CLOUD_PROJECT') and v !~ '^[A-Za-z0-9._-]{2,80}$' then
      raise exception 'Use letters, numbers, dots and dashes only.';
    end if;
    if p_name in ('ELEVENLABS_PHONE_NUMBER_ID', 'WHATSAPP_PHONE_NUMBER_ID', 'WHATSAPP_BUSINESS_ACCOUNT_ID', 'FLW_PUBLIC_KEY', 'MONO_PUBLIC_KEY')
       and v !~ '^[A-Za-z0-9_-]{3,120}$' then raise exception 'That does not look like an id or a public key.'; end if;
    if p_name = 'WHATSAPP_TEMPLATE_LANG' and v !~ '^[a-z]{2}(_[A-Z]{2})?$' then raise exception 'Use a language code such as en or en_US.'; end if;
    v_shown := left(v, 200);
  end if;
  select id into v_id from vault.secrets where name = p_name order by created_at desc limit 1;
  if v_id is null then perform vault.create_secret(v, p_name, 'Set in the Counta admin portal');
  else perform vault.update_secret(v_id, v); end if;
  insert into platform_secrets (name, shown, set_by, set_at) values (p_name, v_shown, auth.uid(), now())
  on conflict (name) do update set shown = excluded.shown, set_by = excluded.set_by, set_at = excluded.set_at;
  perform private.audit('set_key', p_name, jsonb_build_object('shown', v_shown));
  return jsonb_build_object('name', p_name, 'shown', v_shown, 'secret', c.secret);
end $$;


-- Which number a business's WhatsApp messages come from: TaxStreem's (counta) or its own linked number (own).
alter table public.orgs add column if not exists whatsapp_sender text not null default 'counta';
alter table public.orgs drop constraint if exists orgs_whatsapp_sender_check;
alter table public.orgs add constraint orgs_whatsapp_sender_check check (whatsapp_sender in ('counta', 'own'));

-- Each WhatsApp session on the OpenWA server: TaxStreem's own, and any a business linked.
create table if not exists public.whatsapp_sessions (
  id text primary key check (id ~ '^[A-Za-z0-9_-]{1,80}$'),
  kind text not null check (kind in ('counta', 'business')),
  org_id uuid references public.orgs(id) on delete cascade,
  name text not null,
  status text not null default 'created',
  phone text,
  push_name text,
  last_error text,
  connected_at timestamptz,
  status_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  check ((kind = 'counta' and org_id is null) or (kind = 'business' and org_id is not null))
);
create unique index if not exists whatsapp_sessions_one_counta on public.whatsapp_sessions(kind) where kind = 'counta';
create unique index if not exists whatsapp_sessions_one_per_org on public.whatsapp_sessions(org_id) where kind = 'business';
create index if not exists whatsapp_sessions_created_by on public.whatsapp_sessions(created_by);
alter table public.whatsapp_sessions enable row level security;
revoke all on public.whatsapp_sessions from anon, authenticated;

-- Webhook deliveries already handled, so a retry or a replay is not handled twice. Kept three days.
create table if not exists public.openwa_deliveries (
  id text primary key,
  at timestamptz not null default now()
);
create index if not exists openwa_deliveries_at on public.openwa_deliveries(at);
alter table public.openwa_deliveries enable row level security;
revoke all on public.openwa_deliveries from anon, authenticated;

-- True the first time a delivery id is seen.
create or replace function public.svc_openwa_seen(p_id text) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_new boolean;
begin
  if coalesce(p_id, '') = '' then return true; end if;
  insert into openwa_deliveries (id) values (left(p_id, 200)) on conflict (id) do nothing;
  get diagnostics v_new = row_count;
  if random() < 0.02 then delete from openwa_deliveries where at < now() - interval '3 days'; end if;
  return v_new;
end $$;

-- p: {id, kind, org_id, name, status, phone, push_name, last_error, created_by}. Returns the row as it was before
-- (so the caller can tell a session that just dropped) and as it is now.
create or replace function public.svc_wa_session_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare old public.whatsapp_sessions; cur public.whatsapp_sessions; v_status text := nullif(p->>'status', '');
begin
  select * into old from whatsapp_sessions where id = p->>'id';
  if not found and p ? 'kind' then
    if p->>'kind' = 'counta' then delete from whatsapp_sessions where kind = 'counta'; end if;
    if p->>'kind' = 'business' then delete from whatsapp_sessions where kind = 'business' and org_id = (p->>'org_id')::uuid; end if;
    insert into whatsapp_sessions (id, kind, org_id, name, status, created_by)
    values (p->>'id', p->>'kind', nullif(p->>'org_id', '')::uuid, coalesce(nullif(p->>'name', ''), p->>'id'), coalesce(v_status, 'created'),
      nullif(p->>'created_by', '')::uuid);
  elsif not found then
    return jsonb_build_object('before', null, 'now', null);
  end if;
  update whatsapp_sessions set
    status = coalesce(v_status, status),
    status_at = case when v_status is not null and v_status is distinct from status then now() else status_at end,
    phone = coalesce(nullif(regexp_replace(coalesce(p->>'phone', ''), '[^0-9]', '', 'g'), ''), phone),
    push_name = coalesce(nullif(left(p->>'push_name', 80), ''), push_name),
    last_error = case when p ? 'last_error' then left(nullif(p->>'last_error', ''), 300) else last_error end,
    connected_at = case when v_status = 'ready' and status is distinct from 'ready' then now() else connected_at end
  where id = p->>'id' returning * into cur;
  -- A business whose own number dropped goes back to TaxStreem's number until it is linked again.
  if cur.kind = 'business' and cur.status <> 'ready' and old.status = 'ready' then
    update orgs set whatsapp_sender = 'counta' where id = cur.org_id and whatsapp_sender = 'own';
    perform private.notify_perm(cur.org_id, 'manage_settings', 'whatsapp', 'Your WhatsApp number was unlinked',
      'Invoices and reminders go from TaxStreem''s WhatsApp number until you link yours again on the Integrations page.', '/integrations', 'wa-drop-' || cur.org_id);
  end if;
  return jsonb_build_object('before', case when old.id is not null then to_jsonb(old) end, 'now', to_jsonb(cur));
end $$;

create or replace function public.svc_wa_session(p_id text) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(s) from whatsapp_sessions s where s.id = p_id
$$;

-- The session a business's WhatsApp messages go out on: its own number when linked and chosen, else TaxStreem's.
create or replace function public.svc_wa_sender(p_org uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select jsonb_build_object('session', s.id, 'kind', 'business', 'status', s.status) from whatsapp_sessions s join orgs o on o.id = s.org_id
     where s.kind = 'business' and s.org_id = p_org and s.status = 'ready' and o.whatsapp_sender = 'own'),
    (select jsonb_build_object('session', s.id, 'kind', 'counta', 'status', s.status) from whatsapp_sessions s where s.kind = 'counta'),
    '{}'::jsonb)
$$;

-- For the admin portal.
create or replace function public.admin_whatsapp() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_staff();
  return jsonb_build_object(
    'counta', (select to_jsonb(s) from whatsapp_sessions s where s.kind = 'counta'),
    'businesses', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'org_id', s.org_id, 'business', o.name, 'status', s.status, 'phone', s.phone,
        'status_at', s.status_at, 'sender', o.whatsapp_sender) order by o.name), '[]'::jsonb)
      from whatsapp_sessions s join orgs o on o.id = s.org_id where s.kind = 'business'),
    'links', (select count(*) from chat_links where channel = 'whatsapp' and status = 'active'),
    'siri', (select count(*) from chat_links where channel = 'siri' and status = 'active'),
    'turns_today', (select count(*) from chat_turns where role = 'user' and at > now() - interval '1 day'));
end $$;

-- A business's own number, for its Integrations page.
create or replace function public.org_whatsapp(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; s public.whatsapp_sessions; o public.orgs;
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  select * into s from whatsapp_sessions where kind = 'business' and org_id = p_org;
  return jsonb_build_object('sender', o.whatsapp_sender,
    'own', case when s.id is not null then jsonb_build_object('status', s.status, 'phone', s.phone, 'push_name', s.push_name, 'status_at', s.status_at,
      'connected_at', s.connected_at, 'last_error', s.last_error) end,
    'counta', (select jsonb_build_object('status', c.status, 'phone', c.phone) from whatsapp_sessions c where c.kind = 'counta'),
    'can_change', m.role = 'owner' or private.perm_of(m, 'manage_settings'));
end $$;

create or replace function public.set_whatsapp_sender(p_org uuid, p_sender text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, 'manage_settings');
  if p_sender not in ('counta', 'own') then raise exception 'Choose TaxStreem''s number or your own.'; end if;
  if p_sender = 'own' and not exists (select 1 from whatsapp_sessions where kind = 'business' and org_id = p_org and status = 'ready') then
    raise exception 'Link your WhatsApp number first.';
  end if;
  update orgs set whatsapp_sender = p_sender where id = p_org;
  return public.org_whatsapp(p_org);
end $$;

-- The messaging function checks who may link or unlink a business's own number before it talks to OpenWA.
create or replace function public.whatsapp_link_check(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, 'manage_settings');
  if (select is_sample from orgs where id = p_org) then raise exception 'The sample business sends from TaxStreem''s number.'; end if;
  return jsonb_build_object('org_id', p_org, 'name', (select name from orgs where id = p_org), 'user_id', auth.uid(),
    'session', (select to_jsonb(s) from whatsapp_sessions s where s.kind = 'business' and s.org_id = p_org));
end $$;

-- ---------------------------------------------------------------------------
-- 2. Martina on WhatsApp and Siri: links, the conversation, actions waiting for a yes
-- ---------------------------------------------------------------------------
create table if not exists public.chat_links (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  channel text not null check (channel in ('whatsapp', 'siri')),
  phone text check (phone is null or phone ~ '^[0-9]{8,15}$'),
  key_hash text,
  key_last4 text,
  label text check (label is null or length(label) <= 60),
  status text not null default 'pending' check (status in ('pending', 'active', 'revoked')),
  code_hash text,
  code_expires timestamptz,
  code_tries int not null default 0,
  created_at timestamptz not null default now(),
  linked_at timestamptz,
  last_used_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid references auth.users(id) on delete set null,
  check ((channel = 'whatsapp' and phone is not null) or (channel = 'siri' and key_hash is not null))
);
-- One active WhatsApp link per number; a Siri key is unique.
create unique index if not exists chat_links_phone on public.chat_links(phone) where channel = 'whatsapp' and status = 'active';
create unique index if not exists chat_links_key on public.chat_links(key_hash) where key_hash is not null;
create index if not exists chat_links_user on public.chat_links(user_id, org_id);
create index if not exists chat_links_org on public.chat_links(org_id);
create index if not exists chat_links_revoked_by on public.chat_links(revoked_by);
alter table public.chat_links enable row level security;
revoke all on public.chat_links from anon, authenticated;

-- The conversation, kept fourteen days so Martina remembers the thread; then deleted.
create table if not exists public.chat_turns (
  id bigint generated always as identity primary key,
  link_id uuid not null references public.chat_links(id) on delete cascade,
  role text not null check (role in ('user', 'assistant')),
  text text not null,
  meta jsonb not null default '{}'::jsonb,
  at timestamptz not null default now()
);
create index if not exists chat_turns_link on public.chat_turns(link_id, at desc);
create index if not exists chat_turns_at on public.chat_turns(at);
alter table public.chat_turns enable row level security;
revoke all on public.chat_turns from anon, authenticated;

-- The action Martina read back, waiting for the person's yes. One per link, ten minutes.
create table if not exists public.chat_pending (
  link_id uuid primary key references public.chat_links(id) on delete cascade,
  action_id uuid not null default gen_random_uuid(),
  kind text not null check (kind in ('sale', 'invoice', 'bill', 'reminder')),
  title text not null,
  read_back text not null,
  payload jsonb not null,
  at timestamptz not null default now()
);
alter table public.chat_pending enable row level security;
revoke all on public.chat_pending from anon, authenticated;

-- Numbers that wrote to TaxStreem's number without a link get one reply a day, no more.
create table if not exists public.chat_strangers (
  phone text primary key,
  replied_at timestamptz not null default now(),
  tries int not null default 1
);
alter table public.chat_strangers enable row level security;
revoke all on public.chat_strangers from anon, authenticated;

-- A Nigerian number as WhatsApp writes it: 2348012345678.
create or replace function private.wa_phone(p text) returns text
language sql immutable set search_path = '' as $$
  select case
    when d ~ '^0[0-9]{10}$' then '234' || substr(d, 2)
    when d ~ '^[7-9][0-9]{9}$' then '234' || d
    when d ~ '^[0-9]{8,15}$' then d end
  from (select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') d) x
$$;

create or replace function private.link_json(l public.chat_links) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', l.id, 'channel', l.channel, 'status', l.status, 'label', l.label,
    'phone', case when l.phone is not null then '+' || left(l.phone, 3) || ' ••• ••• ' || right(l.phone, 4) end,
    'key_last4', l.key_last4, 'created_at', l.created_at, 'linked_at', l.linked_at, 'last_used_at', l.last_used_at,
    'business', (select name from orgs where id = l.org_id))
$$;

-- The person's own links for this business, and how to reach Martina.
create or replace function public.chat_links_mine(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; c public.whatsapp_sessions;
begin
  m := private.require(p_org, null);
  select * into c from whatsapp_sessions where kind = 'counta';
  return jsonb_build_object(
    'links', (select coalesce(jsonb_agg(private.link_json(l) order by l.created_at desc), '[]'::jsonb) from chat_links l
              where l.user_id = auth.uid() and l.org_id = p_org and l.status <> 'revoked' and not (l.status = 'pending' and l.code_expires < now())),
    'whatsapp', jsonb_build_object('ready', coalesce(c.status = 'ready', false), 'number', case when c.status = 'ready' then c.phone end),
    'martina', private.feature_on(p_org, 'martina'),
    'team_links', case when private.perm_of(m, 'manage_team') then (select count(*) from chat_links where org_id = p_org and status = 'active') end);
end $$;

-- Starts linking a WhatsApp number: the person sends "LINK <code>" from that number within fifteen minutes.
create or replace function public.chat_whatsapp_start(p_org uuid, p_phone text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_phone text := private.wa_phone(p_phone); v_code text; c public.whatsapp_sessions; v_id uuid;
begin
  m := private.require(p_org, null);
  if v_phone is null then raise exception 'Enter your WhatsApp number, such as 0803 123 4567.'; end if;
  select * into c from whatsapp_sessions where kind = 'counta';
  if c.status is distinct from 'ready' or c.phone is null then raise exception 'Martina is not on WhatsApp yet. TaxStreem is connecting the number.'; end if;
  if v_phone = c.phone then raise exception 'That is TaxStreem''s own number. Enter yours.'; end if;
  if (select count(*) from chat_links where user_id = auth.uid() and channel = 'whatsapp' and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'That is enough tries for an hour. Try again later.';
  end if;
  v_code := lpad((floor(random() * 1000000))::int::text, 6, '0');
  delete from chat_links where user_id = auth.uid() and org_id = p_org and channel = 'whatsapp' and status = 'pending';
  insert into chat_links (user_id, org_id, channel, phone, status, code_hash, code_expires)
  values (auth.uid(), p_org, 'whatsapp', v_phone, 'pending', encode(extensions.digest(v_code, 'sha256'), 'hex'), now() + interval '15 minutes')
  returning id into v_id;
  return jsonb_build_object('link_id', v_id, 'code', v_code, 'number', c.phone, 'expires_in', 900,
    'wa_link', 'https://wa.me/' || c.phone || '?text=' || replace('LINK ' || v_code, ' ', '%20'));
end $$;

-- A personal key for the iPhone shortcut, shown once.
create or replace function public.chat_siri_key(p_org uuid, p_label text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_key text := 'ck_' || encode(extensions.gen_random_bytes(24), 'hex'); v_id uuid;
begin
  m := private.require(p_org, null);
  if (select count(*) from chat_links where user_id = auth.uid() and channel = 'siri' and status = 'active') >= 5 then
    raise exception 'You have five shortcut keys already. Remove one first.';
  end if;
  insert into chat_links (user_id, org_id, channel, key_hash, key_last4, label, status, linked_at)
  values (auth.uid(), p_org, 'siri', encode(extensions.digest(v_key, 'sha256'), 'hex'), right(v_key, 4),
    left(coalesce(nullif(trim(p_label), ''), 'iPhone'), 60), 'active', now())
  returning id into v_id;
  return jsonb_build_object('link_id', v_id, 'key', v_key);
end $$;

-- The person removes their own link; whoever manages the team may remove anyone's in the business.
create or replace function public.chat_link_revoke(p_link uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.chat_links;
begin
  select * into l from chat_links where id = p_link;
  if not found then raise exception 'Link not found.'; end if;
  if l.user_id <> auth.uid() then perform private.require(l.org_id, 'manage_team'); end if;
  update chat_links set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(), code_hash = null where id = p_link;
  delete from chat_pending where link_id = p_link;
  return jsonb_build_object('revoked', true);
end $$;

-- Everyone's links in a business, for whoever manages the team.
create or replace function public.chat_links_team(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require(p_org, 'manage_team');
  return (select coalesce(jsonb_agg(private.link_json(l) || jsonb_build_object('person', coalesce(mb.display_name, 'Someone')) order by l.linked_at desc), '[]'::jsonb)
    from chat_links l left join members mb on mb.org_id = l.org_id and mb.user_id = l.user_id where l.org_id = p_org and l.status = 'active');
end $$;

-- What Martina starts a conversation knowing about the person and the business.
create or replace function private.chat_context(l public.chat_links) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('link_id', l.id, 'channel', l.channel, 'org_id', l.org_id, 'user_id', l.user_id,
    'first_name', split_part(coalesce(nullif(trim(mb.display_name), ''), 'there'), ' ', 1), 'role', private.role_label(mb.role),
    'member_status', mb.status, 'business', o.name, 'offering', o.offering, 'category_id', o.category_id,
    'category', (select label from business_categories where id = o.category_id),
    'language', o.voice_lang, 'sample', o.is_sample,
    'perms', case when mb.role = 'owner' then private.role_template('owner') else private.member_perms(mb) end,
    'businesses', (select coalesce(jsonb_agg(jsonb_build_object('id', x.org_id, 'name', xo.name) order by xo.name), '[]'::jsonb)
      from members x join orgs xo on xo.id = x.org_id where x.user_id = l.user_id and x.status = 'active'),
    'app_url', coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app'))
  from orgs o left join members mb on mb.org_id = o.id and mb.user_id = l.user_id
  where o.id = l.org_id
$$;

-- From the chat function, when someone sends "LINK <code>" from their number: the pending link for that number and code.
-- Five wrong codes for a number end its pending link.
create or replace function public.svc_chat_claim(p_phone text, p_code text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.chat_links; v_phone text := private.wa_phone(p_phone);
begin
  if v_phone is null or coalesce(p_code, '') !~ '^[0-9]{6}$' then return jsonb_build_object('ok', false, 'reason', 'bad_code'); end if;
  select * into l from chat_links where channel = 'whatsapp' and status = 'pending' and phone = v_phone and code_expires > now()
  order by created_at desc limit 1 for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no_pending'); end if;
  if l.code_hash <> encode(extensions.digest(p_code, 'sha256'), 'hex') then
    update chat_links set code_tries = code_tries + 1, status = case when code_tries + 1 >= 5 then 'revoked' else status end,
      revoked_at = case when code_tries + 1 >= 5 then now() else revoked_at end where id = l.id;
    return jsonb_build_object('ok', false, 'reason', 'wrong_code');
  end if;
  if not exists (select 1 from members where org_id = l.org_id and user_id = l.user_id and status = 'active') then
    return jsonb_build_object('ok', false, 'reason', 'not_member');
  end if;
  -- The number now speaks for this person and business only.
  update chat_links set status = 'revoked', revoked_at = now() where channel = 'whatsapp' and status = 'active' and phone = v_phone;
  update chat_links set status = 'active', linked_at = now(), code_hash = null, code_expires = null, code_tries = 0 where id = l.id returning * into l;
  delete from chat_strangers where phone = v_phone;
  return jsonb_build_object('ok', true, 'context', private.chat_context(l));
end $$;

-- The active link for a WhatsApp number, or a Siri key's hash, with what Martina starts from.
create or replace function public.svc_chat_link(p_phone text, p_key_hash text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.chat_links;
begin
  if p_key_hash is not null then
    select * into l from chat_links where key_hash = p_key_hash and channel = 'siri' and status = 'active';
  else
    select * into l from chat_links where phone = private.wa_phone(p_phone) and channel = 'whatsapp' and status = 'active';
  end if;
  if not found then return null; end if;
  if not exists (select 1 from members where org_id = l.org_id and user_id = l.user_id and status = 'active') then
    return jsonb_build_object('inactive', true, 'link_id', l.id);
  end if;
  update chat_links set last_used_at = now() where id = l.id;
  return private.chat_context(l);
end $$;

-- A number with no link: true when it should get the one reply a day.
create or replace function public.svc_chat_stranger(p_phone text) returns boolean
language plpgsql security definer set search_path = public, private as $$
declare v_phone text := coalesce(private.wa_phone(p_phone), left(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'), 15)); s public.chat_strangers;
begin
  if v_phone = '' then return false; end if;
  select * into s from chat_strangers where phone = v_phone for update;
  if not found then insert into chat_strangers (phone) values (v_phone); return true; end if;
  if s.replied_at < now() - interval '1 day' then update chat_strangers set replied_at = now(), tries = tries + 1 where phone = v_phone; return true; end if;
  update chat_strangers set tries = tries + 1 where phone = v_phone;
  return false;
end $$;

-- Moves the conversation to another business the person belongs to.
create or replace function public.svc_chat_switch(p_link uuid, p_org uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.chat_links;
begin
  select * into l from chat_links where id = p_link and status = 'active' for update;
  if not found then raise exception 'This link is not active.'; end if;
  if not exists (select 1 from members where org_id = p_org and user_id = l.user_id and status = 'active') then
    raise exception 'You are not on that business''s team.';
  end if;
  if l.channel = 'whatsapp' then update chat_links set org_id = p_org where id = l.id returning * into l; end if;
  delete from chat_pending where link_id = l.id;
  return private.chat_context(l);
end $$;

-- The conversation so far (the last sixteen turns of the past twelve hours), and what was said.
create or replace function public.svc_chat_history(p_link uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if random() < 0.05 then delete from chat_turns where at < now() - interval '14 days'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('role', t.role, 'text', t.text, 'at', t.at) order by t.at), '[]'::jsonb)
    from (select * from chat_turns where link_id = p_link and at > now() - interval '12 hours' order by at desc limit 16) t);
end $$;

-- Records a turn. Returns how many turns the person sent in the past hour (the function stops at sixty).
create or replace function public.svc_chat_log(p_link uuid, p_role text, p_text text, p_meta jsonb default '{}'::jsonb) returns int
language plpgsql security definer set search_path = public as $$
begin
  insert into chat_turns (link_id, role, text, meta) values (p_link, p_role, left(coalesce(p_text, ''), 4000), coalesce(p_meta, '{}'::jsonb));
  return (select count(*) from chat_turns where link_id = p_link and role = 'user' and at > now() - interval '1 hour');
end $$;

-- p: {kind, title, read_back, payload}. Replaces anything waiting.
create or replace function public.svc_chat_pending_set(p_link uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into chat_pending (link_id, kind, title, read_back, payload) values (p_link, p->>'kind', left(p->>'title', 200), left(p->>'read_back', 1000), p->'payload')
  on conflict (link_id) do update set action_id = gen_random_uuid(), kind = excluded.kind, title = excluded.title, read_back = excluded.read_back,
    payload = excluded.payload, at = now()
  returning action_id into v_id;
  return v_id;
end $$;

create or replace function public.svc_chat_pending(p_link uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('action_id', action_id, 'kind', kind, 'title', title, 'read_back', read_back, 'payload', payload, 'at', at,
    'expired', at < now() - interval '10 minutes') from chat_pending where link_id = p_link
$$;

-- Takes the action waiting (once). Null when nothing matches or it waited more than ten minutes.
create or replace function public.svc_chat_pending_take(p_link uuid, p_action uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.chat_pending;
begin
  delete from chat_pending where link_id = p_link and (p_action is null or action_id = p_action) returning * into c;
  if c.link_id is null or c.at < now() - interval '10 minutes' then return null; end if;
  return jsonb_build_object('action_id', c.action_id, 'kind', c.kind, 'title', c.title, 'payload', c.payload);
end $$;

-- Every step Martina takes runs here, as the person: the database's own checks decide what they may see and do, in the
-- business the link is for and no other. Only these calls are possible.
create or replace function public.svc_chat_rpc(p_link uuid, p_fn text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.chat_links; v_org uuid; r jsonb; v_id uuid;
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
  -- Calls that name a record outside the business are refused here, before the record's own function runs.
  if p_fn in ('send_document', 'send_reminder') then
    v_id := nullif(p->>'sale_id', '')::uuid;
    if not exists (select 1 from sales where id = v_id and org_id = v_org) then raise exception 'That document is not in this business.'; end if;
  elsif p_fn = 'send_statement' then
    v_id := nullif(p->>'customer_id', '')::uuid;
    if not exists (select 1 from customers where id = v_id and org_id = v_org) then raise exception 'That customer is not in this business.'; end if;
  elsif p_fn = 'approve_bill' then
    v_id := nullif(p->>'bill_id', '')::uuid;
    if not exists (select 1 from bills where id = v_id and org_id = v_org) then raise exception 'That bill is not in this business.'; end if;
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
    else raise exception 'Martina cannot do that here.';
  end case;
  return r;
end $$;

revoke execute on function public.svc_openwa_seen(text), public.svc_wa_session_save(jsonb), public.svc_wa_session(text), public.svc_wa_sender(uuid),
  public.svc_chat_claim(text, text), public.svc_chat_link(text, text), public.svc_chat_stranger(text), public.svc_chat_switch(uuid, uuid),
  public.svc_chat_history(uuid), public.svc_chat_log(uuid, text, text, jsonb), public.svc_chat_pending_set(uuid, jsonb), public.svc_chat_pending(uuid),
  public.svc_chat_pending_take(uuid, uuid), public.svc_chat_rpc(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.svc_openwa_seen(text), public.svc_wa_session_save(jsonb), public.svc_wa_session(text), public.svc_wa_sender(uuid),
  public.svc_chat_claim(text, text), public.svc_chat_link(text, text), public.svc_chat_stranger(text), public.svc_chat_switch(uuid, uuid),
  public.svc_chat_history(uuid), public.svc_chat_log(uuid, text, text, jsonb), public.svc_chat_pending_set(uuid, jsonb), public.svc_chat_pending(uuid),
  public.svc_chat_pending_take(uuid, uuid), public.svc_chat_rpc(uuid, text, jsonb) to service_role;
revoke execute on function public.admin_whatsapp(), public.org_whatsapp(uuid), public.set_whatsapp_sender(uuid, text), public.whatsapp_link_check(uuid),
  public.chat_links_mine(uuid), public.chat_whatsapp_start(uuid, text), public.chat_siri_key(uuid, text), public.chat_link_revoke(uuid), public.chat_links_team(uuid)
  from public, anon;
grant execute on function public.admin_whatsapp(), public.org_whatsapp(uuid), public.set_whatsapp_sender(uuid, text), public.whatsapp_link_check(uuid),
  public.chat_links_mine(uuid), public.chat_whatsapp_start(uuid, text), public.chat_siri_key(uuid, text), public.chat_link_revoke(uuid), public.chat_links_team(uuid)
  to authenticated;
