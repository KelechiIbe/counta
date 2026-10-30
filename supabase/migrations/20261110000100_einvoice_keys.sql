-- E-invoicing with the NRS Merchant Buyer Solution (MBS), part 1: the keys and the first checks.
--
-- TaxStreem is applying to NITDA as both a System Integrator and an Access Point Provider, with Counta as the software.
-- Before any invoice is mapped, the sandbox is asked what its answers look like (the NRS documentation has no sample
-- responses), and the Google Cloud HSM keys that will hold each business's NRS credentials and sign invoices are checked.
--
--   * Keys and services in TaxStreem's admin portal gets two groups: NRS e-invoicing (the dashboard's address, key and
--     secret, TaxStreem's Business ID and Service ID, crypto_keys.txt, and an optional APP key pair) and Google Cloud HSM
--     (the key ring). Each has a Test button, answered by the einvoice edge function.
--   * nrs_codes keeps NRS's own code lists (countries, currencies, tax categories, payment means, invoice types, service
--     codes, VAT exemptions and HS codes), copied from the sandbox by the NRS test. Anyone signed in may read them.
--   * einvoice_checks keeps what each test found: the shape of NRS's answers and of TaxStreem's entity record, with
--     numbers cut to their last four and email addresses removed. No key, secret or certificate is ever written there.

-- ---------------------------------------------------------------------------
-- 1. NRS's code lists
-- ---------------------------------------------------------------------------
create table if not exists public.nrs_codes (
  list text not null check (list in ('countries', 'currencies', 'tax-categories', 'payment-means', 'invoice-types', 'services-codes',
    'vat-exemptions', 'hs-codes', 'states', 'lgas')),
  code text not null check (length(code) between 1 and 80),
  label text,
  extra jsonb not null default '{}'::jsonb,
  synced_at timestamptz not null default now(),
  primary key (list, code)
);
alter table public.nrs_codes enable row level security;
drop policy if exists nrs_codes_read on public.nrs_codes;
create policy nrs_codes_read on public.nrs_codes for select to authenticated using (true);
revoke all on public.nrs_codes from anon, authenticated;
grant select on public.nrs_codes to authenticated;

-- One list as NRS sent it. A list that came back empty is left as it was, so a bad answer never wipes the codes.
create or replace function public.svc_nrs_codes_sync(p_list text, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare n int; gone int := 0; v_in jsonb;
begin
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'rows must be an array'; end if;
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_in from (
    select distinct on (btrim(r->>'code')) jsonb_build_object('code', btrim(r->>'code'),
      'label', nullif(left(btrim(coalesce(r->>'label', '')), 500), ''), 'extra', coalesce(r->'extra', '{}'::jsonb)) x
    from jsonb_array_elements(p_rows) r
    where length(btrim(coalesce(r->>'code', ''))) between 1 and 80
    order by btrim(r->>'code')) q;
  n := jsonb_array_length(v_in);
  if n = 0 then return jsonb_build_object('list', p_list, 'received', 0, 'kept', (select count(*) from nrs_codes where list = p_list)); end if;
  insert into nrs_codes (list, code, label, extra, synced_at)
    select p_list, x->>'code', x->>'label', x->'extra', now() from jsonb_array_elements(v_in) x
  on conflict (list, code) do update set label = excluded.label, extra = excluded.extra, synced_at = excluded.synced_at;
  delete from nrs_codes c where c.list = p_list and not exists (select 1 from jsonb_array_elements(v_in) x where x->>'code' = c.code);
  get diagnostics gone = row_count;
  return jsonb_build_object('list', p_list, 'received', n, 'removed', gone);
end $$;

-- ---------------------------------------------------------------------------
-- 2. What each test found
-- ---------------------------------------------------------------------------
create table if not exists public.einvoice_checks (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  kind text not null check (kind in ('nrs', 'kms')),
  by_user uuid references auth.users(id) on delete set null,
  ok boolean not null,
  note text not null,
  results jsonb not null default '{}'::jsonb
);
create index if not exists einvoice_checks_at on public.einvoice_checks(kind, at desc);
create index if not exists einvoice_checks_by on public.einvoice_checks(by_user);
alter table public.einvoice_checks enable row level security;
revoke all on public.einvoice_checks from anon, authenticated;

create or replace function public.svc_einvoice_check_save(p jsonb) returns bigint
language plpgsql security definer set search_path = public, private as $$
declare v_id bigint;
begin
  insert into einvoice_checks (kind, by_user, ok, note, results)
  values (p->>'kind', nullif(p->>'by_user', '')::uuid, coalesce((p->>'ok')::boolean, false), left(coalesce(p->>'note', ''), 2000), coalesce(p->'results', '{}'::jsonb))
  returning id into v_id;
  -- A year of tests is plenty.
  delete from einvoice_checks where at < now() - interval '365 days';
  return v_id;
end $$;

-- The einvoice function asks this with the person's own token before a platform test: TaxStreem's admins, with the
-- authenticator code.
create or replace function public.admin_einvoice_allowed() returns boolean
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_staff();
  return true;
end $$;

create or replace function public.admin_einvoice_checks(p_kind text default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_staff();
  return (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'at', c.at, 'kind', c.kind, 'ok', c.ok, 'note', c.note, 'results', c.results,
      'by', (select email from auth.users u where u.id = c.by_user)) order by c.at desc), '[]'::jsonb)
    from (select * from einvoice_checks where p_kind is null or kind = p_kind order by at desc limit 20) c);
end $$;

-- ---------------------------------------------------------------------------
-- 3. The keys, in the admin portal
-- ---------------------------------------------------------------------------
-- The catalogue as of 1 November, with the NRS and Google Cloud HSM groups added.
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
    ('NRS_APP_API_KEY', 'nrs', 'APP API key (optional)', true, 'Only if the dashboard gives TaxStreem''s Access Point Provider role a key of its own.', 1007),
    ('NRS_APP_API_SECRET', 'nrs', 'APP API secret (optional)', true, 'The secret that goes with the APP key.', 1008),
    ('GOOGLE_KMS_KEY_RING', 'kms', 'Key ring', false, 'Leave empty for projects/<project>/locations/us-central1/keyRings/counta-einvoice. It holds nrs-credentials (encrypt and decrypt) and invoice-signing (EC P-256, SHA-256), both HSM keys. The service account in Google Gemini above signs in, with Cloud KMS CryptoKey Encrypter/Decrypter on the first key and Signer/Verifier on the second.', 1101)
$$;

-- As of 31 October, with the checks for the NRS keys and the key ring added.
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
  elsif p_name = 'NRS_CRYPTO_KEYS' then
    -- crypto_keys.txt is a small JSON file: the NRS public key (a PEM, base64-encoded) and the certificate.
    begin j := v::jsonb; exception when others then raise exception 'Paste the whole of crypto_keys.txt, from { to }.'; end;
    if jsonb_typeof(j) <> 'object' or coalesce(j->>'public_key', '') = '' or coalesce(j->>'certificate', '') = '' then
      raise exception 'That file has no public_key or no certificate. Download crypto_keys.txt again from the NRS dashboard.';
    end if;
    v := j::text;
    v_shown := 'certificate •••• ' || right(j->>'certificate', 4);
  elsif c.secret then
    if length(v) < 8 then raise exception 'That is too short for a key.'; end if;
    v_shown := '•••• ' || right(v, 4);
  else
    if p_name in ('NUMENS_API_URL', 'FLUX_URL', 'APP_URL', 'FLW_RELAY_URL', 'OPENWA_URL', 'NRS_BASE_URL') and v !~ '^https://[^\s]+$' then raise exception 'Enter an https:// address.'; end if;
    if p_name = 'OPENWA_URL' then v := regexp_replace(v, '/+(api/?)?$', ''); end if;
    -- The calls add /api/v1/..., so an address pasted with /api or /api/v1 on the end is cut back to the host.
    if p_name = 'NRS_BASE_URL' then v := regexp_replace(v, '/+(api(/v1)?/?)?$', ''); end if;
    if p_name = 'NRS_BUSINESS_ID' and v !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'The Business ID looks like 6dc03c76-1d83-4a39-a4de-51bd70547aef.';
    end if;
    if p_name = 'NRS_SERVICE_ID' then
      v := upper(v);
      if v !~ '^[A-Z0-9]{8}$' then raise exception 'The Service ID is 8 letters and numbers, such as 94ND90NR.'; end if;
    end if;
    if p_name = 'GOOGLE_KMS_KEY_RING' and v !~ '^projects/[a-z0-9-]{4,40}/locations/[a-z0-9-]{2,40}/keyRings/[A-Za-z0-9_-]{1,63}$' then
      raise exception 'Enter it as projects/<project>/locations/<region>/keyRings/<name>.';
    end if;
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

-- ---------------------------------------------------------------------------
-- 4. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function public.svc_nrs_codes_sync(text, jsonb), public.svc_einvoice_check_save(jsonb) from public, anon, authenticated;
grant execute on function public.svc_nrs_codes_sync(text, jsonb), public.svc_einvoice_check_save(jsonb) to service_role;
revoke all on function public.admin_einvoice_allowed(), public.admin_einvoice_checks(text) from public, anon;
grant execute on function public.admin_einvoice_allowed(), public.admin_einvoice_checks(text) to authenticated;
