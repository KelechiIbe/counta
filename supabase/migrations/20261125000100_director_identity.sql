-- Counta · a director proves who they are with their NIN and a code
--
-- Full mandate: the business wallet and the tax wallet open only once a director of the company confirms. Until now the
-- firm typed the director's email and Counta sent a code there, with a check of the address the confirmation came from
-- (a firm's own office). That check goes. The director now proves who they are:
--
--   1. The firm chooses a director from the company's CAC record and either emails them the link or copies it to send
--      another way. The link proves nothing by itself.
--   2. On the page (/confirm) the director types their NIN. The practice function looks it up (Mono) and reads the
--      company's directors from CAC again, with the email and phone CAC holds for each.
--   3. The NIN's names must match a director (or, for a business name, a proprietor) on the CAC record. Then one code goes
--      to the phone number NIMC holds for the NIN (by SMS, through Termii) and to the director's email on the CAC record,
--      unless that address is one of the firm's (agents often register a company with their own address).
--   4. The right code confirms: the wallets may open, and the business's identity is verified by the same check.
--   5. With no phone on the NIN record (or before Termii is set up), the code still goes to the CAC email and phone, and
--      the confirmation waits for TaxStreem's reviewers. With no way to reach the director at all, the director uploads
--      their NIN slip, and TaxStreem reviews it.
--
-- Nothing of the NIN is kept but its last four digits. The phone and email the code goes to are kept on the check only
-- while it is open (at most an hour), then wiped; what the pages show are masked forms (+234 803 *** **12, k****@g****.com).
-- The same check (identity_checks) serves account recovery (20261125000200_account_recovery.sql).
--
-- Intake: the accountant finds the prospective client on CAC (Mono) and checks a person's NIN from the intake instead of
-- typing their details. The CAC record found is kept on the intake and, under full mandate, becomes the new business's
-- profile draft, so it is not looked up again.
--
-- Keys: TERMII_API_KEY, TERMII_SENDER_ID, TERMII_BASE_URL and TERMII_CHANNEL (admin portal, Termii), SUPPORT_EMAIL (Counta).

-- ---------------------------------------------------------------------------
-- 1. Keys: Termii, and where support requests go
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
    ('TAXSTREEM_SSO_SECRET', 'taxstreem', 'Single sign-on secret', true, 'Shared with TaxStreem, to sign people in from their TaxStreem account. Prism signs its bills and partners'' invoices with it too.', 801),
    ('TAXSTREEM_SSO_ISSUER', 'taxstreem', 'Single sign-on issuer', false, 'Leave empty for taxstreem.', 802),
    ('FLUX_URL', 'taxstreem', 'Flux address', false, 'The https address of TaxStreem Flux, which files returns on Rev360.', 803),
    ('FLUX_SECRET', 'taxstreem', 'Flux secret', true, 'Signs what Counta sends to Flux and checks what Flux sends back.', 804),
    ('FLUX_FILE_HOSTS', 'taxstreem', 'Flux file hosts', false, 'Other hosts Flux''s file links may point to, comma separated, such as files.taxstreem.com. Links on the Flux address itself are always allowed. Leave empty if Flux sends files only from there.', 805),
    ('PRISM_CALLBACK_URL', 'taxstreem', 'Prism callback address', false, 'The https address on Prism where Counta says how each partner invoice went with NRS (signed, refused, delivered to the buyer). Each call is signed with the single sign-on secret. Until it is set, the callbacks wait.', 806),
    ('LIRS_BOT_URL', 'taxstreem', 'LIRS bot address', false, 'The https address of Counta''s own LIRS e-Tax bot on Google Cloud Run (bots/lirs), such as https://counta-lirs-bot-xxxx.a.run.app. Counta wakes it when a return is sent or a transfer account is asked for.', 807),
    ('LIRS_BOT_SECRET', 'taxstreem', 'LIRS bot secret', true, 'The same value as the bot''s LIRS_BOT_SECRET (in Google Secret Manager), at least 32 characters. Signs what Counta and the bot send each other.', 808),
    ('APP_URL', 'counta', 'Counta web address', false, 'Used in links in emails and messages. Leave empty for https://counta-taxstreem.netlify.app.', 901),
    ('VAPID_SUBJECT', 'counta', 'Contact for push notifications', false, 'mailto: and an address browsers may write to about notifications.', 902),
    ('KYC_REVIEW_EMAIL', 'counta', 'Email for NIN slip reviews', false, 'Where Counta writes when a business''s NIN slip needs checking. Leave empty for admin@taxstreem.com. Reviewers on the Team page are told as well.', 903),
    ('NRS_BASE_URL', 'nrs', 'NRS e-invoicing address', false, 'The base address on the NRS e-invoicing dashboard (sandbox first, production after NRS''s review), such as https://… with nothing after the host.', 1001),
    ('NRS_API_KEY', 'nrs', 'API key', true, 'From the NRS e-invoicing dashboard. Sent as x-api-key.', 1002),
    ('NRS_API_SECRET', 'nrs', 'API secret', true, 'From the same page. Sent as x-api-secret.', 1003),
    ('NRS_BUSINESS_ID', 'nrs', 'TaxStreem''s Business ID', false, 'The Business ID NRS gave TaxStreem Technologies Limited when it was enabled for e-invoicing.', 1004),
    ('NRS_SERVICE_ID', 'nrs', 'TaxStreem''s Service ID', false, 'The 8-character Service ID NRS gave TaxStreem. It is the middle part of every IRN.', 1005),
    ('NRS_CRYPTO_KEYS', 'nrs', 'QR code keys (crypto_keys.txt)', true, 'The whole contents of crypto_keys.txt from My Account, Manage Cryptographic Keys: the public key and certificate the QR code is made with.', 1006),
    ('NRS_APP_API_KEY', 'nrs', 'APP API key', true, 'TaxStreem''s access point key, from NRS''s APP portal (einvoice.nrs.gov.ng/access-point), Developer section, once TaxStreem is an accredited access point. Sends invoices to buyers and brings in invoices for businesses. Until it is set, signed sales wait to go to the buyer.', 1007),
    ('NRS_APP_API_SECRET', 'nrs', 'APP API secret', true, 'The secret that goes with the APP key, from the same page.', 1008),
    ('GOOGLE_KMS_KEY_RING', 'kms', 'Key ring', false, 'Leave empty for projects/<project>/locations/us-central1/keyRings/counta-einvoice. It holds nrs-credentials (encrypt and decrypt) and invoice-signing (EC P-256, SHA-256), both HSM keys. The service account in Google Gemini above signs in, with Cloud KMS CryptoKey Encrypter/Decrypter on the first key and Signer/Verifier on the second.', 1101),
    ('TERMII_API_KEY', 'termii', 'API key', true, 'From the Termii dashboard, on its API page. Sends the one-time codes that prove a director is who they say.', 1101),
    ('TERMII_SENDER_ID', 'termii', 'Sender ID', false, 'The sender ID Termii approved for the account, 3 to 11 letters, such as TaxStreem. It is the name people see on the SMS.', 1102),
    ('TERMII_BASE_URL', 'termii', 'Base URL', false, 'The base URL shown on the Termii dashboard, such as https://v3.api.termii.com. Leave empty for https://api.ng.termii.com.', 1103),
    ('TERMII_CHANNEL', 'termii', 'Route', false, 'dnd (the default) reaches numbers on Do-Not-Disturb and must be switched on for the account by Termii; generic uses the ordinary route.', 1104),
    ('SUPPORT_EMAIL', 'counta', 'Support email', false, 'Where support requests from the app go, such as support@taxstreem.com. Leave empty for the address for NIN slip reviews.', 904)
$$;

-- ---------------------------------------------------------------------------
-- 2. Phones, addresses and what the pages show of them
-- ---------------------------------------------------------------------------
-- A Nigerian mobile number as Termii takes it (234 and ten digits), from any way it is written; else null.
create or replace function private.sms_phone(p text) returns text
language sql immutable set search_path = public, private as $$
  select case when private.local_phone(p) ~ '^0[789][01][0-9]{8}$' then '234' || substr(private.local_phone(p), 2) end
$$;

-- +234 803 *** **12
create or replace function private.mask_phone(p text) returns text
language sql immutable set search_path = public, private as $$
  select case when private.sms_phone(p) is null then null
    else '+234 ' || substr(private.sms_phone(p), 4, 3) || ' *** **' || right(private.sms_phone(p), 2) end
$$;

-- An email address, lower-cased and trimmed, or null when it is not one.
create or replace function private.clean_email(p text) returns text
language sql immutable set search_path = public, private as $$
  select case when lower(btrim(coalesce(p, ''))) ~ '^[a-z0-9._%+''-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$' and length(btrim(p)) <= 254
    then lower(btrim(p)) end
$$;

-- k****@g****.com: the first letter of the name and of the domain, the rest of each starred, the last part of the domain kept.
create or replace function private.mask_email(p text) returns text
language sql immutable set search_path = public, private as $$
  select case when e is null then null else
    left(split_part(e, '@', 1), 1) || repeat('*', greatest(length(split_part(e, '@', 1)) - 1, 3)) || '@'
    || left(d, 1) || repeat('*', greatest(length(regexp_replace(d, '\.[^.]+$', '')) - 1, 3)) || substring(d from '\.[^.]+$') end
  from (select private.clean_email(p) as e, split_part(private.clean_email(p), '@', 2) as d) x
$$;

-- Whether Counta can send an SMS: the Termii key and sender ID are set in the admin portal.
create or replace function private.sms_ready() returns boolean
language sql stable security definer set search_path = public, vault, private as $$
  select coalesce(btrim(public.svc_secret('TERMII_API_KEY')), '') <> '' and coalesce(btrim(public.svc_secret('TERMII_SENDER_ID')), '') <> ''
$$;

-- The business's CAC record as Counta last read it (its submitted profile first, else its draft); null when there is none.
create or replace function private.org_cac(p_org uuid) returns jsonb
language sql stable set search_path = public, private as $$
  select k.cac from kyc_profiles k where k.org_id = p_org and k.cac is not null
  order by (k.status = 'submitted') desc, k.updated_at desc limit 1
$$;

-- The people on a CAC record who may speak for the business: its directors, and for a business name, limited partnership or
-- other unincorporated registration its proprietors (CAC lists them as shareholders or people with significant control).
-- Names only, in the shape private.identity_match reads.
create or replace function private.cac_people(p_cac jsonb) returns jsonb
language sql immutable set search_path = public, private as $$
  with cls as (select upper(coalesce(p_cac->'profile'->>'classification', '')) as c),
  people as (
    select 'director' as role, d as p from jsonb_array_elements(coalesce(p_cac->'profile'->'directors', '[]'::jsonb)) d
    union all
    select 'owner', s from cls, jsonb_array_elements(coalesce(p_cac->'profile'->'shareholders', '[]'::jsonb)) s where cls.c not like 'COMPANY%'
    union all
    select 'owner', s from cls, jsonb_array_elements(coalesce(p_cac->'psc', '[]'::jsonb)) s where cls.c not like 'COMPANY%')
  select coalesce(jsonb_agg(distinct jsonb_build_object('role', role, 'name', private.person(p),
      'surname', upper(coalesce(p->>'surname', '')), 'given', upper(concat_ws(' ', p->>'firstname', p->>'other_name'))))
    filter (where private.person(p) is not null), '[]'::jsonb)
  from people
$$;

-- A name split as identity_match takes it: the first word, the words between, the last word.
create or replace function private.name_parts(p text) returns text[]
language sql immutable set search_path = public, private as $$
  select case when cardinality(t) < 2 then null else array[t[1], array_to_string(t[2:cardinality(t) - 1], ' '), t[cardinality(t)]] end
  from (select private.name_tokens(private.fold_name(p)) as t) x
$$;

-- ---------------------------------------------------------------------------
-- 3. The check: a NIN matched to a person on the CAC record, then a code to the NIN's phone and the CAC email
-- ---------------------------------------------------------------------------
create table public.identity_checks (
  id uuid primary key default gen_random_uuid(),
  purpose text not null check (purpose in ('director_confirm', 'recovery')),
  ref_id uuid not null,
  org_id uuid references public.orgs(id) on delete cascade,
  matched_name text check (length(matched_name) <= 160),
  matched_role text check (matched_role in ('director', 'owner')),
  nin_last4 text check (nin_last4 ~ '^[0-9]{4}$'),
  -- NIMC held a phone number for the NIN.
  nin_phone boolean not null default false,
  -- code: the code confirms; review: the code is entered, then TaxStreem decides; slip: no way to send a code.
  route text not null check (route in ('code', 'review', 'slip')),
  why text check (why in ('no_nin_phone', 'sms_not_ready', 'no_channel')),
  sms_to text check (sms_to ~ '^234[0-9]{10}$'),
  email_to text check (length(email_to) <= 254),
  sms_masked text check (length(sms_masked) <= 40),
  email_masked text check (length(email_masked) <= 260),
  -- What was not used, and why ({"email": "firm_address"}).
  skipped jsonb not null default '{}' check (jsonb_typeof(skipped) = 'object'),
  otp_hash text,
  otp_expires timestamptz,
  otp_tries int not null default 0,
  otp_failures int not null default 0,
  locked_at timestamptz,
  sends_day date,
  sends_today int not null default 0,
  status text not null default 'open' check (status in ('open', 'verified', 'cancelled', 'expired')),
  created_at timestamptz not null default now(),
  verified_at timestamptz,
  wiped_at timestamptz
);
create index identity_checks_ref on public.identity_checks(ref_id, created_at desc);
create index identity_checks_org on public.identity_checks(org_id) where org_id is not null;
create index identity_checks_wipe on public.identity_checks(created_at) where sms_to is not null or email_to is not null;
alter table public.identity_checks enable row level security;
revoke all on public.identity_checks from anon, authenticated;

-- Asks the messaging function to send one of these (it asks svc_identity_mail for the words, the code and where they go).
create or replace function private.identity_mail(p_kind text, p_id uuid) returns void
language plpgsql set search_path = public, private as $$
begin
  perform private.call_function('messaging', jsonb_build_object('action', 'identity_mail', 'kind', p_kind, 'id', p_id));
end $$;

-- A new check for a confirmation or a recovery, replacing any open one. p: {matched_name, matched_role, last4, nin_phone
-- (the NIN's phone, or null), cac_email, cac_phone, avoid_emails (addresses never to use, with the reason: {"a@b.c":
-- "firm_address"})}. The route follows from what can be reached. Returns the check.
create or replace function private.identity_check_new(p_purpose text, p_ref uuid, p_org uuid, p jsonb) returns public.identity_checks
language plpgsql set search_path = public, private as $$
declare c public.identity_checks; v_sms text := private.sms_phone(p->>'nin_phone'); v_cac_sms text := private.sms_phone(p->>'cac_phone');
  v_email text := private.clean_email(p->>'cac_email'); v_skip jsonb := '{}'; v_route text; v_why text; v_ready boolean := private.sms_ready();
begin
  if v_email is not null and coalesce(p->'avoid_emails', '{}'::jsonb) ? v_email then
    v_skip := v_skip || jsonb_build_object('email', p->'avoid_emails'->>v_email);
    v_email := null;
  end if;
  if v_sms is not null and v_ready then
    v_route := 'code';
  else
    v_why := case when v_sms is null then 'no_nin_phone' else 'sms_not_ready' end;
    if v_sms is not null then v_skip := v_skip || jsonb_build_object('sms', 'sms_not_ready'); end if;
    -- Without the NIN's phone, the CAC record's phone (when Counta can send an SMS) and email, then TaxStreem decides.
    v_sms := case when v_ready then v_cac_sms end;
    v_route := case when v_sms is null and v_email is null then 'slip' else 'review' end;
    if v_route = 'slip' then v_why := 'no_channel'; end if;
  end if;
  update identity_checks set status = 'cancelled', sms_to = null, email_to = null, otp_hash = null, wiped_at = coalesce(wiped_at, now())
  where ref_id = p_ref and status = 'open';
  insert into identity_checks (purpose, ref_id, org_id, matched_name, matched_role, nin_last4, nin_phone, route, why, sms_to, email_to,
    sms_masked, email_masked, skipped)
  values (p_purpose, p_ref, p_org, left(p->>'matched_name', 160), p->>'matched_role',
    nullif(right(regexp_replace(coalesce(p->>'last4', ''), '\D', '', 'g'), 4), ''), private.sms_phone(p->>'nin_phone') is not null,
    v_route, v_why, v_sms, case when v_route = 'slip' then null else v_email end,
    private.mask_phone(v_sms), case when v_route = 'slip' then null else private.mask_email(v_email) end, v_skip)
  returning * into c;
  return c;
end $$;

-- Sends the check's code again (five a Lagos day). {ok, sends_left} or {ok: false, reason}.
create or replace function private.identity_send(p_check uuid) returns jsonb
language plpgsql set search_path = public, private as $$
declare c public.identity_checks; r jsonb;
begin
  select * into c from identity_checks where id = p_check for update;
  if c.id is null or c.status <> 'open' or c.route = 'slip' or (c.sms_to is null and c.email_to is null) then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;
  if c.locked_at is not null or c.otp_failures >= 15 then return jsonb_build_object('ok', false, 'reason', 'locked'); end if;
  r := private.otp_send_ok(c.sends_day, c.sends_today);
  if not (r->>'ok')::boolean then return jsonb_build_object('ok', false, 'reason', r->>'reason'); end if;
  update identity_checks set sends_day = (r->>'sends_day')::date, sends_today = (r->>'sends_today')::int where id = c.id;
  perform private.identity_mail('identity_code', c.id);
  return jsonb_build_object('ok', true, 'sends_left', 5 - (r->>'sends_today')::int);
end $$;

-- A code entered: {ok, reason, tries_left, locked} as otp_check answers; a right code closes the check and wipes where the
-- code went.
create or replace function private.identity_verify(p_check uuid, p_code text) returns jsonb
language plpgsql set search_path = public, private as $$
declare c public.identity_checks; r jsonb;
begin
  select * into c from identity_checks where id = p_check for update;
  if c.id is null or c.status <> 'open' or c.route = 'slip' then
    return jsonb_build_object('ok', false, 'reason', 'expired', 'tries_left', 0, 'locked', false);
  end if;
  r := private.otp_check(c.id, p_code, c.otp_hash, c.otp_expires, c.otp_tries, c.otp_failures, c.locked_at);
  update identity_checks set otp_tries = (r->>'otp_tries')::int, otp_failures = (r->>'otp_failures')::int,
    locked_at = case when (r->>'locked')::boolean then coalesce(locked_at, now()) else locked_at end,
    otp_hash = case when (r->>'ok')::boolean then null else otp_hash end,
    status = case when (r->>'ok')::boolean then 'verified' else status end,
    verified_at = case when (r->>'ok')::boolean then now() else verified_at end,
    sms_to = case when (r->>'ok')::boolean then null else sms_to end,
    email_to = case when (r->>'ok')::boolean then null else email_to end,
    wiped_at = case when (r->>'ok')::boolean then now() else wiped_at end
  where id = c.id;
  return r;
end $$;

-- Closes a check (a decline, a new request): the code and where it went are wiped.
create or replace function private.identity_close(p_ref uuid) returns void
language sql set search_path = public, private as $$
  update identity_checks set status = 'cancelled', sms_to = null, email_to = null, otp_hash = null, wiped_at = coalesce(wiped_at, now())
  where ref_id = p_ref and status = 'open'
$$;

-- Where a code went is kept for an hour at most: an open check older than that expires.
create or replace function private.identity_wipe_tick() returns integer
language sql security definer set search_path = public, private as $$
  with w as (
    update identity_checks set sms_to = null, email_to = null, otp_hash = null, wiped_at = now(),
      status = case when status = 'open' and route <> 'slip' then 'expired' else status end
    where (sms_to is not null or email_to is not null or (status = 'open' and route <> 'slip')) and created_at < now() - interval '1 hour'
    returning 1)
  select count(*)::int from w
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('counta-identity-wipe', '*/10 * * * *', 'select private.identity_wipe_tick()');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. A director's confirmation of the wallets
-- ---------------------------------------------------------------------------
alter table public.practice_director_confirmations alter column email drop not null;
alter table public.practice_director_confirmations add column if not exists nin_day date;
alter table public.practice_director_confirmations add column if not exists nin_tries int not null default 0;
alter table public.practice_director_confirmations add column if not exists check_id uuid references public.identity_checks(id) on delete set null;
alter table public.practice_director_confirmations add column if not exists matched_name text check (length(matched_name) <= 160);
alter table public.practice_director_confirmations add column if not exists nin_last4 text check (nin_last4 ~ '^[0-9]{4}$');
alter table public.practice_director_confirmations add column if not exists slip_path text check (length(slip_path) <= 300);
create index if not exists practice_director_confirmations_check on public.practice_director_confirmations(check_id) where check_id is not null;

-- The firm asks a director: one named on the CAC record. p: {name, email (optional)}. With an email, the link goes there;
-- without one, the answer carries the link for the firm to send another way (it works for 14 days, and a new link or a new
-- request replaces it). Whoever opens it still proves with their NIN that they are a director.
create or replace function public.practice_director_request(p_client uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients; m public.practice_members; o public.orgs; d public.practice_director_confirmations;
  v_name text; v_email text; v_parts text[]; v_people jsonb; t jsonb;
begin
  select * into c from practice_clients where id = p_client for update;
  if c.id is null or c.practice_id is null then raise exception 'Client not found.'; end if;
  m := private.practice_require(c.practice_id, true);
  select * into o from orgs where id = c.org_id;
  if c.mode <> 'full' or c.status <> 'active' or o.managed_by is distinct from c.practice_id then
    raise exception 'A director confirms only for a business the firm runs under full mandate.';
  end if;
  -- The CAC record is read only by someone acting as the business's owner (the firm's partners and managers have such a
  -- place while they are active).
  if not private.acts_as_owner(o.id, auth.uid()) then
    raise exception 'Only the firm''s people acting as the business''s owner ask a director to confirm.' using errcode = '42501';
  end if;
  if o.director_confirmed_at is not null then raise exception 'A director of the business has confirmed already.'; end if;
  if exists (select 1 from practice_director_confirmations where client_id = c.id and status = 'review') then
    raise exception 'TaxStreem is checking the director''s last confirmation. Wait for its decision.';
  end if;
  v_people := private.cac_people(private.org_cac(o.id));
  if jsonb_array_length(v_people) = 0 then
    raise exception 'Add the business''s CAC record first (Settings, Business profile), so Counta knows its directors.';
  end if;
  if jsonb_typeof(p) is distinct from 'object' then raise exception 'Choose the director.'; end if;
  v_name := btrim(regexp_replace(coalesce(p->>'name', ''), '\s+', ' ', 'g'));
  v_email := nullif(lower(btrim(coalesce(p->>'email', ''))), '');
  if length(v_name) not between 2 and 120 then raise exception 'Choose the director from the CAC record.'; end if;
  if v_email is not null and private.clean_email(v_email) is null then raise exception 'That email address is not valid.'; end if;
  v_parts := private.name_parts(v_name);
  if v_parts is null or private.identity_match(v_parts[1], v_parts[2], v_parts[3], v_people) is null then
    raise exception 'That name is not a director on the CAC record.';
  end if;
  if v_email is not null and private.firm_email(c.practice_id, v_email) is not null then
    raise exception 'Send it to the director''s own email address, not the firm''s.';
  end if;
  if (select count(*) from practice_director_confirmations where client_id = c.id and created_at > now() - interval '1 day') >= 5 then
    raise exception 'That is five requests for this business today. Try again tomorrow.';
  end if;
  for d in select * from practice_director_confirmations where client_id = c.id and status = 'pending' loop
    perform private.identity_close(d.id);
  end loop;
  update practice_director_confirmations set status = 'cancelled', token_hash = null, token_expires = null, otp_hash = null, otp_expires = null
  where client_id = c.id and status = 'pending';
  insert into practice_director_confirmations (practice_id, client_id, name, email, requested_by)
  values (c.practice_id, c.id, v_name, v_email, m.id)
  returning * into d;
  perform private.activity_event(c.org_id, 'director_requested', 'A director''s confirmation was asked for',
    jsonb_build_object('practice_id', c.practice_id, 'confirmation_id', d.id));
  if v_email is not null then
    perform private.practice_mail('director_confirm', d.id);
    return jsonb_build_object('id', d.id, 'status', d.status, 'name', d.name, 'email', d.email, 'sent', true, 'created_at', d.created_at);
  end if;
  t := private.token_new('dc');
  update practice_director_confirmations set token_hash = t->>'hash', token_expires = now() + interval '14 days' where id = d.id;
  return jsonb_build_object('id', d.id, 'status', d.status, 'name', d.name, 'email', null, 'sent', false, 'created_at', d.created_at,
    'link', coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app') || '/confirm/' || (t->>'token'));
end $$;

-- A new link for the firm's request waiting for the director (the last link stops working).
create or replace function public.practice_director_link(p_confirmation uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.practice_director_confirmations; c public.practice_clients; t jsonb;
begin
  select * into d from practice_director_confirmations where id = p_confirmation for update;
  if d.id is null then raise exception 'Request not found.'; end if;
  select * into c from practice_clients where id = d.client_id;
  perform private.practice_require(d.practice_id, true);
  if not private.acts_as_owner(c.org_id, auth.uid()) then
    raise exception 'Only the firm''s people acting as the business''s owner ask a director to confirm.' using errcode = '42501';
  end if;
  if d.status <> 'pending' or not private.director_mandate_open(d.client_id, d.practice_id) then
    raise exception 'This request is no longer waiting for the director.';
  end if;
  t := private.token_new('dc');
  update practice_director_confirmations set token_hash = t->>'hash', token_expires = now() + interval '14 days' where id = d.id;
  return jsonb_build_object('id', d.id, 'link',
    coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app') || '/confirm/' || (t->>'token'));
end $$;

-- For the firm's Full mandate tab: the directors it may ask (names from the CAC record) and the latest request.
create or replace function public.practice_director_state(p_client uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare c public.practice_clients; o public.orgs; d public.practice_director_confirmations; k public.identity_checks;
begin
  select * into c from practice_clients where id = p_client;
  if c.id is null or c.practice_id is null then raise exception 'Client not found.'; end if;
  perform private.practice_require(c.practice_id, true);
  select * into o from orgs where id = c.org_id;
  select * into d from practice_director_confirmations where client_id = c.id order by created_at desc, id limit 1;
  if d.check_id is not null then select * into k from identity_checks where id = d.check_id; end if;
  return jsonb_build_object(
    'confirmed_at', o.director_confirmed_at,
    'cac', private.org_cac(o.id) is not null,
    'directors', case when private.acts_as_owner(o.id, auth.uid()) then
        (select coalesce(jsonb_agg(jsonb_build_object('name', x->>'name', 'role', x->>'role') order by x->>'name'), '[]'::jsonb)
         from jsonb_array_elements(private.cac_people(private.org_cac(o.id))) x) else '[]'::jsonb end,
    'latest', case when d.id is not null then jsonb_build_object('id', d.id, 'status', d.status, 'name', d.name, 'email', d.email,
        'created_at', d.created_at, 'confirmed_at', d.confirmed_at, 'matched_name', d.matched_name,
        'review_reason', d.flags->>'review_reason', 'decline_reason', d.decline_reason,
        'step', case when d.status <> 'pending' then null when k.id is null or k.status <> 'open' then 'nin' when k.route = 'slip' then 'slip' else 'code' end,
        'link_live', d.token_hash is not null and d.token_expires > now()) end);
end $$;

-- The confirmation page opens a link: who asks, for which business, where it stands and what the director does next
-- (step: nin, code or slip). Never raises.
create or replace function public.svc_director_open(p_token text, p_ip text, p_ua text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.practice_director_confirmations; v_state text; k public.identity_checks;
begin
  d := private.director_by_token(p_token);
  v_state := private.director_state(d);
  if v_state in ('invalid', 'expired', 'closed') then return jsonb_build_object('ok', false, 'reason', v_state); end if;
  if d.check_id is not null then select * into k from identity_checks where id = d.check_id; end if;
  return jsonb_build_object('ok', true, 'firm_name', (select name from practices where id = d.practice_id),
    'business_name', (select o.name from practice_clients c join orgs o on o.id = c.org_id where c.id = d.client_id),
    'director_name', d.name, 'status', d.status,
    'step', case when d.status <> 'pending' then null
      when k.id is null or k.status <> 'open' or (k.route <> 'slip' and k.sms_to is null and k.email_to is null) then 'nin'
      when k.route = 'slip' then 'slip' else 'code' end,
    'route', case when d.status = 'pending' and k.status = 'open' then k.route end,
    'sms', case when d.status = 'pending' and k.status = 'open' then k.sms_masked end,
    'email', case when d.status = 'pending' and k.status = 'open' then k.email_masked end);
end $$;

-- Before the NIN is looked up: the link is live, three NIN lookups a Lagos day at most, and the CAC record to read the
-- directors' contacts from (with its classification: a business name's proprietors are read too). {ok, cac_id,
-- classification, tries_left} or {ok: false, reason}. Never raises.
create or replace function public.svc_director_nin_begin(p_token text, p_ip text, p_ua text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.practice_director_confirmations; v_state text; v_today date := (now() at time zone 'Africa/Lagos')::date; v_cac jsonb; v_tries int;
begin
  d := private.director_by_token(p_token);
  v_state := private.director_state(d);
  if v_state is not null then return jsonb_build_object('ok', false, 'reason', v_state); end if;
  v_tries := case when d.nin_day = v_today then d.nin_tries else 0 end;
  if v_tries >= 3 then return jsonb_build_object('ok', false, 'reason', 'too_many_nin'); end if;
  v_cac := private.org_cac((select org_id from practice_clients where id = d.client_id));
  if v_cac is null or coalesce(v_cac->>'cac_id', '') = '' then return jsonb_build_object('ok', false, 'reason', 'no_cac'); end if;
  update practice_director_confirmations set nin_day = v_today, nin_tries = v_tries + 1 where id = d.id;
  return jsonb_build_object('ok', true, 'cac_id', v_cac->>'cac_id', 'classification', v_cac->'profile'->>'classification', 'tries_left', 2 - v_tries);
end $$;

-- Where the director's NIN slip goes, before the practice function stores it: only while the page asks for the slip, in
-- the business's own KYC folder under a new name. p_ext: pdf, jpg, png or webp. {ok, path} or {ok: false, reason}.
-- Never raises.
create or replace function public.svc_director_slip_target(p_token text, p_ext text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.practice_director_confirmations; v_state text; k public.identity_checks; v_org uuid;
begin
  d := private.director_by_token(p_token);
  v_state := private.director_state(d);
  if v_state is not null then return jsonb_build_object('ok', false, 'reason', v_state); end if;
  if d.check_id is not null then select * into k from identity_checks where id = d.check_id; end if;
  if k.id is null or k.status <> 'open' or k.route <> 'slip' then return jsonb_build_object('ok', false, 'reason', 'nin_first'); end if;
  if coalesce(p_ext, '') not in ('pdf', 'jpg', 'png', 'webp') then return jsonb_build_object('ok', false, 'reason', 'invalid'); end if;
  select org_id into v_org from practice_clients where id = d.client_id;
  return jsonb_build_object('ok', true, 'path', v_org::text || '/kyc/director-slip-' || gen_random_uuid()::text || '.' || p_ext);
end $$;

-- The NIN's record as the practice function read it, and the company's directors as CAC holds them.
-- p: {first, middle, last, last4, nin_phone, cac: [{surname, given, email, phone}]}. The NIN's names must match a director
-- (or proprietor) on the business's CAC record; the code then goes as private.identity_check_new decides, never to an
-- address of the firm's. {ok, step: code|slip, route, sms, email, matched} or {ok: false, reason}. Never raises.
create or replace function public.svc_director_identity(p_token text, p jsonb, p_ip text, p_ua text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.practice_director_confirmations; v_state text; v_org uuid; v_match jsonb; v_contact jsonb; v_avoid jsonb := '{}';
  k public.identity_checks; v_email text; r jsonb;
begin
  d := private.director_by_token(p_token);
  v_state := private.director_state(d);
  if v_state is not null then return jsonb_build_object('ok', false, 'reason', v_state); end if;
  if jsonb_typeof(p) is distinct from 'object' then return jsonb_build_object('ok', false, 'reason', 'no_match'); end if;
  select org_id into v_org from practice_clients where id = d.client_id;
  v_match := private.identity_match(p->>'first', p->>'middle', p->>'last', private.cac_people(private.org_cac(v_org)));
  if v_match is null then
    update practice_director_confirmations set flags = flags || jsonb_build_object('last_try', jsonb_build_object('at', now(), 'result', 'no_match',
      'last4', nullif(right(regexp_replace(coalesce(p->>'last4', ''), '\D', '', 'g'), 4), '')))
    where id = d.id;
    return jsonb_build_object('ok', false, 'reason', 'no_match');
  end if;
  v_contact := private.identity_match(p->>'first', p->>'middle', p->>'last',
    case when jsonb_typeof(p->'cac') = 'array' then p->'cac' else '[]'::jsonb end);
  v_email := private.clean_email(v_contact->>'email');
  if v_email is not null and private.firm_email(d.practice_id, v_email) is not null then
    v_avoid := jsonb_build_object(v_email, 'firm_address');
  end if;
  k := private.identity_check_new('director_confirm', d.id, v_org, jsonb_build_object('matched_name', v_match->>'name',
    'matched_role', v_match->>'role', 'last4', p->>'last4', 'nin_phone', p->>'nin_phone', 'cac_email', v_email,
    'cac_phone', v_contact->>'phone', 'avoid_emails', v_avoid));
  update practice_director_confirmations set check_id = k.id, matched_name = k.matched_name, nin_last4 = k.nin_last4,
    ip = left(nullif(trim(p_ip), ''), 64), ua = left(nullif(p_ua, ''), 300)
  where id = d.id;
  if k.route <> 'slip' then
    r := private.identity_send(k.id);
    if not (r->>'ok')::boolean then return jsonb_build_object('ok', false, 'reason', r->>'reason'); end if;
  end if;
  return jsonb_build_object('ok', true, 'step', case when k.route = 'slip' then 'slip' else 'code' end, 'route', k.route,
    'sms', k.sms_masked, 'email', k.email_masked, 'matched', k.matched_name);
end $$;

-- The director asks for the code again: five a Lagos day. Never raises.
create or replace function public.svc_director_code(p_token text, p_ip text, p_ua text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.practice_director_confirmations; v_state text;
begin
  d := private.director_by_token(p_token);
  v_state := private.director_state(d);
  if v_state is not null then return jsonb_build_object('ok', false, 'reason', v_state); end if;
  if d.check_id is null then return jsonb_build_object('ok', false, 'reason', 'nin_first'); end if;
  return private.identity_send(d.check_id);
end $$;

-- The code entered. Through the NIN's phone, the director has confirmed: the wallets may open, and the business's identity
-- is verified by the same check. Without it, the confirmation waits for TaxStreem. Never raises.
create or replace function public.svc_director_confirm(p_token text, p_code text, p_ip text, p_ua text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.practice_director_confirmations; v_state text; r jsonb; k public.identity_checks; v_org uuid; v_business text;
begin
  d := private.director_by_token(p_token);
  v_state := private.director_state(d);
  if v_state is not null then return jsonb_build_object('ok', false, 'reason', v_state, 'tries_left', 0); end if;
  if d.check_id is null then return jsonb_build_object('ok', false, 'reason', 'nin_first', 'tries_left', 0); end if;
  r := private.identity_verify(d.check_id, p_code);
  if not (r->>'ok')::boolean then
    return jsonb_build_object('ok', false, 'reason', r->>'reason', 'tries_left', (r->>'tries_left')::int, 'locked', (r->>'locked')::boolean);
  end if;
  select * into k from identity_checks where id = d.check_id;
  select c.org_id, o.name into v_org, v_business from practice_clients c join orgs o on o.id = c.org_id where c.id = d.client_id;
  if k.route = 'review' then
    update practice_director_confirmations set status = 'review', ip = left(nullif(trim(p_ip), ''), 64), ua = left(nullif(p_ua, ''), 300),
      otp_hash = null, flags = flags || jsonb_build_object('review_reason', k.why)
    where id = d.id;
    insert into practice_mandate_flags (practice_id, client_id, kind, detail)
    values (d.practice_id, d.client_id, 'director_review', jsonb_build_object('confirmation_id', d.id, 'reason', k.why));
    perform private.activity_event(v_org, 'director_review', 'A director''s confirmation is waiting for TaxStreem''s check',
      jsonb_build_object('practice_id', d.practice_id, 'confirmation_id', d.id));
    perform private.practice_mail('director_admin', d.id);
    return jsonb_build_object('ok', true, 'status', 'review');
  end if;
  update practice_director_confirmations set status = 'confirmed', confirmed_at = now(), ip = left(nullif(trim(p_ip), ''), 64),
    ua = left(nullif(p_ua, ''), 300), otp_hash = null
  where id = d.id;
  perform private.director_settle(v_org, k.matched_name, k.matched_role, k.nin_last4, d.id);
  perform private.activity_event(v_org, 'director_confirmed', 'A director of the business confirmed the business wallet and tax wallet',
    jsonb_build_object('practice_id', d.practice_id, 'confirmation_id', d.id));
  perform private.practice_notify(d.practice_id, 'A director of ' || v_business || ' confirmed',
    'The business wallet and tax wallet can be opened now.', '/practice/clients');
  return jsonb_build_object('ok', true, 'status', 'confirmed');
end $$;

-- A director's confirmation that stands (by code, or accepted by TaxStreem): the wallets may open, and the business's
-- identity is verified by it when it was not already.
create or replace function private.director_settle(p_org uuid, p_name text, p_role text, p_last4 text, p_confirmation uuid) returns void
language sql set search_path = public, private as $$
  update orgs set director_confirmed_at = coalesce(director_confirmed_at, now()),
    identity_status = case when identity_status in ('verified', 'approved', 'not_required') then identity_status else 'verified' end,
    identity = case when identity_status in ('verified', 'approved', 'not_required') then identity
      else (identity - 'review' - 'reason') || jsonb_build_object('method', 'director_nin', 'matched', p_name, 'matched_role', coalesce(p_role, 'director'),
        'last4', p_last4, 'at', now(), 'confirmation_id', p_confirmation) end
  where id = p_org
$$;

-- No way to reach the director: their NIN slip, uploaded on the page (the practice function stores it), goes to TaxStreem.
-- Never raises.
create or replace function public.svc_director_slip(p_token text, p_path text, p_ip text, p_ua text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.practice_director_confirmations; v_state text; k public.identity_checks; v_org uuid;
begin
  d := private.director_by_token(p_token);
  v_state := private.director_state(d);
  if v_state is not null then return jsonb_build_object('ok', false, 'reason', v_state); end if;
  if d.check_id is not null then select * into k from identity_checks where id = d.check_id; end if;
  if k.id is null or k.status <> 'open' or k.route <> 'slip' then return jsonb_build_object('ok', false, 'reason', 'nin_first'); end if;
  select org_id into v_org from practice_clients where id = d.client_id;
  if coalesce(p_path, '') !~ ('^' || v_org::text || '/kyc/director-slip-[0-9a-f-]{36}\.(pdf|jpg|png|webp)$') then
    return jsonb_build_object('ok', false, 'reason', 'invalid');
  end if;
  update identity_checks set status = 'verified', verified_at = now(), wiped_at = now() where id = k.id;
  update practice_director_confirmations set status = 'review', slip_path = p_path, ip = left(nullif(trim(p_ip), ''), 64), ua = left(nullif(p_ua, ''), 300),
    flags = flags || jsonb_build_object('review_reason', 'no_channel')
  where id = d.id;
  insert into practice_mandate_flags (practice_id, client_id, kind, detail)
  values (d.practice_id, d.client_id, 'director_review', jsonb_build_object('confirmation_id', d.id, 'reason', 'no_channel'));
  perform private.activity_event(v_org, 'director_review', 'A director''s confirmation is waiting for TaxStreem''s check',
    jsonb_build_object('practice_id', d.practice_id, 'confirmation_id', d.id));
  perform private.practice_mail('director_admin', d.id);
  return jsonb_build_object('ok', true, 'status', 'review');
end $$;

-- The director declines (p_reason up to 500 characters): the firm is told, and TaxStreem's reviewers. Never raises.
create or replace function public.svc_director_decline(p_token text, p_reason text, p_ip text, p_ua text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.practice_director_confirmations; v_state text; v_reason text := nullif(left(trim(coalesce(p_reason, '')), 500), '');
  v_org uuid; v_business text;
begin
  d := private.director_by_token(p_token);
  v_state := private.director_state(d);
  if v_state is not null then return jsonb_build_object('ok', false, 'reason', v_state); end if;
  perform private.identity_close(d.id);
  update practice_director_confirmations set status = 'declined', decline_reason = v_reason, ip = left(nullif(trim(p_ip), ''), 64),
    ua = left(nullif(p_ua, ''), 300), otp_hash = null, otp_expires = null
  where id = d.id;
  select c.org_id, o.name into v_org, v_business from practice_clients c join orgs o on o.id = c.org_id where c.id = d.client_id;
  insert into practice_mandate_flags (practice_id, client_id, kind, detail)
  values (d.practice_id, d.client_id, 'director_declined', jsonb_build_object('confirmation_id', d.id, 'reason', v_reason));
  perform private.activity_event(v_org, 'director_declined', 'A director of the business declined the business wallet and tax wallet',
    jsonb_build_object('practice_id', d.practice_id, 'confirmation_id', d.id));
  perform private.practice_notify(d.practice_id, 'A director of ' || v_business || ' declined',
    coalesce('They said: ' || v_reason, 'They gave no reason.'), '/practice/clients');
  perform private.practice_mail('director_admin', d.id);
  return jsonb_build_object('ok', true, 'status', 'declined');
end $$;

-- Latest definition (20261124000800_mandate_gate.sql), with: a request with no email has no link email (the firm sent the
-- link itself); the code goes through svc_identity_mail now, so director_code sends nothing; the reviewers' email says why
-- the confirmation waits.
create or replace function public.svc_practice_mail(p_kind text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.engagement_letter_signers; l public.engagement_letters; pr public.practices; v_app text; v_client text; v_reply text; t jsonb;
  d public.practice_director_confirmations; v_business text;
begin
  if p_kind in ('director_confirm', 'director_code', 'director_admin') then
    select * into d from practice_director_confirmations where id = p_id for update;
    if d.id is null then return null; end if;
    if p_kind in ('director_confirm', 'director_code')
       and (d.status <> 'pending' or not private.director_mandate_open(d.client_id, d.practice_id)) then
      return null;
    end if;
    -- The director's code goes through svc_identity_mail (20261125000100_director_identity.sql).
    if p_kind = 'director_code' then return null; end if;
    if p_kind = 'director_admin' and d.status not in ('review', 'declined') then return null; end if;
    v_app := coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app');
    select * into pr from practices where id = d.practice_id;
    select o.name into v_business from practice_clients c join orgs o on o.id = c.org_id where c.id = d.client_id;
    if p_kind = 'director_admin' then
      return jsonb_build_object('to', to_jsonb(public.svc_review_recipients()), 'reply_to', null, 'from_name', 'Counta',
        'subject', case when d.status = 'review' then 'Director confirmation to review: ' else 'A director declined: ' end || v_business,
        'heading', case when d.status = 'review' then 'A director''s confirmation to check' else 'A director declined' end,
        'greet', null,
        'lines', jsonb_build_array('Firm: ' || pr.name || '.', 'Business: ' || v_business || '.',
            case when d.status = 'review' then case d.flags->>'review_reason'
                when 'no_nin_phone' then 'The director matched a director on the CAC record with their NIN and entered the code, but NIMC holds no phone number for the NIN, so the code went only to the CAC record''s email or phone. Check it before the wallets open.'
                when 'sms_not_ready' then 'The director matched a director on the CAC record with their NIN and entered the code, but SMS is not set up yet, so the code went only to the CAC record''s email. Check it before the wallets open.'
                when 'no_channel' then 'The director matched a director on the CAC record with their NIN, but Counta had no phone or email to send a code to, so they uploaded their NIN slip. Check it before the wallets open.'
                else 'The director confirmed the business wallet and tax wallet. Check it before the wallets open.' end
              else 'The director declined the business wallet and tax wallet.' end)
          || case when d.status = 'declined' then jsonb_build_array('Reason given: ' || coalesce(d.decline_reason, 'none') || '.') else '[]'::jsonb end,
        'button', 'Open mandates', 'link', v_app || '/admin/mandates', 'white_label', false);
    end if;
    -- Replies go to the engagement partner while they are in the practice, else the practice.
    v_reply := coalesce((select pm.email from practice_clients c join practice_members pm on pm.id = c.engagement_partner_id
                         where c.id = d.client_id and pm.status = 'active'), pr.email);
    if p_kind = 'director_confirm' then
      if d.email is null then return null; end if;
      t := private.token_new('dc');
      update practice_director_confirmations set token_hash = t->>'hash', token_expires = now() + interval '14 days' where id = d.id;
      return jsonb_build_object('to', d.email, 'reply_to', v_reply, 'from_name', pr.name,
        'subject', pr.name || ' asks you to confirm the wallets for ' || v_business,
        'heading', 'Confirm the business wallets',
        'greet', split_part(trim(d.name), ' ', 1),
        'lines', jsonb_build_array(pr.name || ' asks you, as a director of ' || v_business || ', to confirm that it may open a business wallet and a tax wallet for '
            || v_business || '. The wallets are provided by TaxStreem through Flutterwave and hold the company''s money.',
          'Use the button to confirm or decline. You will be asked for your NIN, and a 6-digit code then goes to the phone number on your NIN record and to your email on the company''s CAC record, to confirm it is you. The link works for fourteen days.'),
        'button', 'Confirm or decline', 'link', v_app || '/confirm/' || (t->>'token'), 'white_label', true);
    end if;
    return null;
  end if;

  -- The letter, then its signer, locked in that order.
  if p_kind in ('letter_sign', 'letter_code') then
    select * into l from engagement_letters where id = (select letter_id from engagement_letter_signers where id = p_id) for update;
    select * into s from engagement_letter_signers where id = p_id and letter_id = l.id for update;
    if s.id is null or l.status is distinct from 'sent' or s.signed_at is not null then return null; end if;
    if p_kind = 'letter_code' and s.locked_at is not null then return null; end if;
  elsif p_kind = 'letter_done' then
    select * into l from engagement_letters where id = p_id for update;
    if l.id is null or l.status <> 'completed' then return null; end if;
    select * into s from engagement_letter_signers where letter_id = l.id and signed_at is not null for update;
    if s.id is null then return null; end if;
  else
    raise exception 'Unknown practice email: %.', p_kind;
  end if;
  v_app := coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app');
  select * into pr from practices where id = l.practice_id;
  select legal_name into v_client from practice_intakes where id = l.intake_id;
  -- Replies go to the partner who signed (at their address now while they are in the practice), else the practice.
  v_reply := coalesce((select email from practice_members where id = l.partner_id and status = 'active'), l.partner_email, pr.email);

  if p_kind = 'letter_sign' then
    t := private.token_new('es');
    update engagement_letter_signers set token_hash = t->>'hash', token_expires = now() + interval '14 days', updated_at = now() where id = s.id;
    return jsonb_build_object('to', s.email, 'reply_to', v_reply, 'from_name', pr.name,
      'subject', 'Letter of engagement from ' || pr.name || ' to sign',
      'heading', 'Your letter of engagement',
      'greet', split_part(trim(s.name), ' ', 1),
      'lines', jsonb_build_array(pr.name || ' has signed its letter of engagement with ' || v_client || ' and sent it to you to read and sign.',
        'Use the button to open it. Before you sign, a 6-digit code is emailed to this address to confirm it is you. The link works for fourteen days.'),
      'button', 'Read and sign', 'link', v_app || '/sign/' || (t->>'token'), 'white_label', l.white_label);
  elsif p_kind = 'letter_code' then
    t := private.otp_new(s.id);
    update engagement_letter_signers set otp_hash = t->>'otp_hash', otp_expires = (t->>'otp_expires')::timestamptz, otp_tries = 0, updated_at = now()
    where id = s.id;
    return jsonb_build_object('to', s.email, 'reply_to', v_reply, 'from_name', pr.name,
      'subject', 'Your code to sign the letter of engagement',
      'heading', 'Your signing code',
      'greet', split_part(trim(s.name), ' ', 1),
      'lines', jsonb_build_array('Enter this code to sign the letter of engagement from ' || pr.name || '. It works for ten minutes.',
        'If you did not ask for a code, you can ignore this email.'),
      'button', null, 'link', null, 'code', t->>'code', 'white_label', l.white_label);
  end if;
  t := private.token_new('es');
  update engagement_letter_signers set token_hash = t->>'hash', token_expires = now() + interval '14 days', updated_at = now() where id = s.id;
  return jsonb_build_object('to', s.email, 'cc', v_reply, 'reply_to', v_reply, 'from_name', pr.name,
    'subject', 'Letter of engagement signed: ' || v_client,
    'heading', 'Your letter of engagement is signed',
    'greet', split_part(trim(s.name), ' ', 1),
    'lines', jsonb_build_array(pr.name || ' and ' || v_client || ' have both signed the letter of engagement.',
      'Use the button to download the signed letter with its certificate of signing. The link works for fourteen days.'),
    'button', 'Download the signed letter', 'link', v_app || '/sign/' || (t->>'token'), 'white_label', l.white_label);
end $$;

-- Latest definition (20261124000800_mandate_gate.sql); an accepted confirmation also verifies the business's identity
-- (private.director_settle), as a confirmation by code does.
create or replace function public.admin_director_decide(p_id uuid, p_approve boolean, p_note text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_note text := trim(coalesce(p_note, '')); d public.practice_director_confirmations; v_org uuid; v_business text; k public.identity_checks;
begin
  perform private.require_staff(false);
  if length(v_note) < 5 then raise exception 'Write a note of at least 5 characters.'; end if;
  if length(v_note) > 1000 then raise exception 'Keep the note under 1,000 characters.'; end if;
  if p_approve is null then raise exception 'Accept or decline the confirmation.'; end if;
  select * into d from practice_director_confirmations where id = p_id for update;
  if d.id is null then raise exception 'Confirmation not found.'; end if;
  if d.status <> 'review' then raise exception 'Only a confirmation waiting for review is decided here.'; end if;
  select c.org_id, o.name into v_org, v_business from practice_clients c join orgs o on o.id = c.org_id where c.id = d.client_id;
  if p_approve and not private.director_mandate_open(d.client_id, d.practice_id) then
    raise exception 'The firm no longer runs this business under full mandate.';
  end if;
  update practice_director_confirmations set status = case when p_approve then 'confirmed' else 'declined' end,
    confirmed_at = case when p_approve then now() else confirmed_at end, decided_by = auth.uid(), decided_at = now(),
    flags = flags || jsonb_build_object('review_note', v_note)
  where id = d.id
  returning * into d;
  update practice_mandate_flags set resolved_at = now(), resolved_by = auth.uid(), resolution_note = v_note
  where kind = 'director_review' and detail->>'confirmation_id' = d.id::text and resolved_at is null;
  if p_approve then
    if d.check_id is not null then select * into k from identity_checks where id = d.check_id; end if;
    perform private.director_settle(v_org, coalesce(d.matched_name, d.name), coalesce(k.matched_role, 'director'), d.nin_last4, d.id);
    perform private.activity_event(v_org, 'director_confirmed', 'TaxStreem accepted a director''s confirmation of the business wallet and tax wallet',
      jsonb_build_object('practice_id', d.practice_id, 'confirmation_id', d.id));
    perform private.audit('director_confirmed', d.id::text, jsonb_build_object('practice_id', d.practice_id, 'client_id', d.client_id, 'org_id', v_org, 'note', v_note));
    perform private.practice_notify(d.practice_id, 'A director of ' || v_business || ' confirmed',
      'TaxStreem checked the confirmation. The business wallet and tax wallet can be opened now.', '/practice/clients');
  else
    perform private.activity_event(v_org, 'director_declined', 'TaxStreem did not accept a director''s confirmation',
      jsonb_build_object('practice_id', d.practice_id, 'confirmation_id', d.id));
    perform private.audit('director_declined', d.id::text, jsonb_build_object('practice_id', d.practice_id, 'client_id', d.client_id, 'org_id', v_org, 'note', v_note));
    perform private.practice_notify(d.practice_id, 'TaxStreem did not accept the director''s confirmation for ' || v_business,
      'Ask the director to confirm again, or ask another director.', '/practice/clients');
  end if;
  return jsonb_build_object('id', d.id, 'status', d.status);
end $$;

-- Latest definition (20261124001200_mandates_admin.sql); each review also says whom the NIN matched on the CAC record, the
-- NIN's last four digits, where the code went (masked) and the NIN slip, when one was uploaded.
create or replace function public.admin_mandates() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_staff(false);
  return jsonb_build_object(
    'reviews', (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'status', d.status, 'created_at', d.created_at,
        'practice', jsonb_build_object('id', pr.id, 'name', pr.name),
        'business', jsonb_build_object('client_id', c.id, 'org_id', c.org_id, 'name', coalesce(o.name, c.business_name)),
        'director', jsonb_build_object('name', d.name, 'email', d.email, 'phone', d.phone, 'matched_name', d.matched_name, 'nin_last4', d.nin_last4,
          'sms', k.sms_masked, 'code_email', k.email_masked, 'skipped', k.skipped),
        'slip_path', d.slip_path,
        'ip', d.ip, 'ua', d.ua, 'reason', d.flags->>'review_reason') order by d.created_at, d.id), '[]'::jsonb)
      from practice_director_confirmations d join practices pr on pr.id = d.practice_id
      join practice_clients c on c.id = d.client_id left join orgs o on o.id = c.org_id
      left join identity_checks k on k.id = d.check_id
      where d.status = 'review'),
    'practices', (select coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'name', pr.name,
        'full_clients', (select count(*) from practice_clients c where c.practice_id = pr.id and c.mode = 'full' and c.status = 'active'),
        'suspended_at', pr.mandate_suspended_at, 'partner_verified', private.partner_verified(pr.id)) order by pr.name, pr.id), '[]'::jsonb)
      from practices pr
      where private.partner_verified(pr.id) or pr.mandate_suspended_at is not null
        or exists (select 1 from practice_clients c where c.practice_id = pr.id and c.mode = 'full')),
    'flags', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'kind', f.kind, 'detail', f.detail, 'created_at', f.created_at,
        'practice', jsonb_build_object('id', pr.id, 'name', pr.name),
        'intake', case when i.id is not null then jsonb_build_object('id', i.id, 'legal_name', i.legal_name, 'rc_number', i.rc_number, 'tax_id', i.tax_id) end,
        'business', case when c.id is not null then jsonb_build_object('client_id', c.id, 'org_id', c.org_id, 'name', coalesce(o.name, c.business_name)) end,
        'identity', case when f.kind = 'handover' then (select jsonb_build_object('status', ho.identity_status,
            'pending', private.handover_pending(ho.identity_status, ho.identity), 'status_before', f.detail->>'identity_before')
          from orgs ho where ho.id = private.uuid_of(f.detail->>'org_id')) end)
        order by f.created_at desc, f.id), '[]'::jsonb)
      from practice_mandate_flags f join practices pr on pr.id = f.practice_id
      left join practice_intakes i on i.id = f.intake_id
      left join practice_clients c on c.id = f.client_id left join orgs o on o.id = c.org_id
      where f.resolved_at is null),
    'settings', jsonb_build_object('free_mail_domains',
      case when jsonb_typeof(coalesce(private.setting('mandates'), '{}')->'free_mail_domains') = 'array'
           then coalesce(private.setting('mandates'), '{}')->'free_mail_domains' else '[]'::jsonb end));
end $$;

-- Latest definition (20261024000100_team_identity_martina.sql); reviewers also read a director's NIN slip while its
-- confirmation is with them or was decided.
create or replace function private.reviewer_may_read(p_name text) returns boolean
language sql stable security definer set search_path = public, private as $$
  select private.is_reviewer() and (
    (coalesce(p_name, '') ~ '^[0-9a-f-]{36}/kyc/nin-slip-'
     and exists (select 1 from public.orgs o where o.id::text = split_part(p_name, '/', 1) and o.identity_status in ('review', 'approved', 'rejected')))
    or (coalesce(p_name, '') ~ '^[0-9a-f-]{36}/kyc/director-slip-'
     and exists (select 1 from public.practice_director_confirmations d where d.slip_path = p_name and d.status in ('review', 'confirmed', 'declined'))))
$$;

-- What the messaging function sends for a check (kind identity_code): the code, minted as it goes, by email to email_to
-- and by SMS to sms_to. A director's code goes in the firm's name (no Counta name; the SMS sender is TaxStreem's).
-- {to, reply_to, from_name, subject, heading, greet, lines, code, white_label, sms: {to, text}}, or null when there is
-- nothing to send.
create or replace function public.svc_identity_mail(p_kind text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.identity_checks; d public.practice_director_confirmations; t jsonb; v_firm text; v_business text; v_reply text;
begin
  if p_kind <> 'identity_code' then raise exception 'Unknown identity email: %.', p_kind; end if;
  select * into c from identity_checks where id = p_id for update;
  if c.id is null or c.status <> 'open' or c.route = 'slip' or (c.sms_to is null and c.email_to is null)
     or c.locked_at is not null or c.otp_failures >= 15 then
    return null;
  end if;
  if c.purpose = 'director_confirm' then
    select * into d from practice_director_confirmations where id = c.ref_id;
    if d.id is null or d.status <> 'pending' or d.check_id is distinct from c.id or not private.director_mandate_open(d.client_id, d.practice_id) then
      return null;
    end if;
    select name into v_firm from practices where id = d.practice_id;
    select o.name into v_business from practice_clients pc join orgs o on o.id = pc.org_id where pc.id = d.client_id;
    v_reply := coalesce((select pm.email from practice_clients pc join practice_members pm on pm.id = pc.engagement_partner_id
                         where pc.id = d.client_id and pm.status = 'active'), (select email from practices where id = d.practice_id));
    t := private.otp_new(c.id);
    update identity_checks set otp_hash = t->>'otp_hash', otp_expires = (t->>'otp_expires')::timestamptz, otp_tries = 0 where id = c.id;
    return jsonb_build_object('to', c.email_to, 'reply_to', v_reply, 'from_name', v_firm, 'org_id', c.org_id, 'purpose', c.purpose,
      'subject', 'Your code to confirm the wallets for ' || v_business,
      'heading', 'Your confirmation code',
      'greet', split_part(btrim(coalesce(c.matched_name, d.name)), ' ', 1),
      'lines', jsonb_build_array('Enter this code to answer ' || v_firm || '''s request about the wallets for ' || v_business || '. It works for ten minutes.',
        'If you did not ask for a code, you can ignore this email.'),
      'button', null, 'link', null, 'code', t->>'code', 'white_label', true,
      'sms', case when c.sms_to is not null then jsonb_build_object('to', c.sms_to,
        'text', (t->>'code') || ' is your code to confirm the wallets for ' || left(v_business, 60) || '. It expires in 10 minutes. Do not share it.') end);
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- 5. The intake: the prospective client found on CAC, and people's NINs checked
-- ---------------------------------------------------------------------------
-- A CAC search from a practice's intake, and the record chosen from it (names only, as for a business's own profile),
-- with the Tax ID the NRS holds for its RC number. Kept for a month while it may be attached to an intake.
create table public.practice_cac_lookups (
  id uuid primary key default gen_random_uuid(),
  practice_id uuid not null references public.practices(id) on delete cascade,
  query text not null check (length(query) between 2 and 100),
  candidates jsonb not null default '[]' check (jsonb_typeof(candidates) = 'array'),
  cac_id text check (length(cac_id) <= 40),
  record jsonb check (record is null or jsonb_typeof(record) = 'object'),
  tin jsonb check (tin is null or jsonb_typeof(tin) = 'object'),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  selected_at timestamptz
);
create index practice_cac_lookups_practice on public.practice_cac_lookups(practice_id, created_at desc);
create index practice_cac_lookups_created_by on public.practice_cac_lookups(created_by) where created_by is not null;
alter table public.practice_cac_lookups enable row level security;
revoke all on public.practice_cac_lookups from anon, authenticated;

alter table public.practice_intakes add column if not exists cac jsonb check (cac is null or jsonb_typeof(cac) = 'object');
alter table public.practice_intakes add column if not exists cac_tin jsonb check (cac_tin is null or jsonb_typeof(cac_tin) = 'object');
alter table public.practice_intakes add column if not exists cac_at timestamptz;

-- A person's NIN checked from the intake: the name NIMC holds and the NIN's last four digits, nothing more. A person on the
-- intake with the same name (without accents, either order) and last four digits shows as checked.
create table public.practice_intake_nin_checks (
  id uuid primary key default gen_random_uuid(),
  intake_id uuid not null references public.practice_intakes(id) on delete cascade,
  practice_id uuid not null references public.practices(id) on delete cascade,
  name text not null check (length(name) between 2 and 160 and regexp_replace(name, '[[:space:]-]', '', 'g') !~ '[0-9]{10,}'),
  last4 text not null check (last4 ~ '^[0-9]{4}$'),
  checked_by uuid references public.practice_members(id) on delete set null,
  created_at timestamptz not null default now()
);
create index practice_intake_nin_checks_intake on public.practice_intake_nin_checks(intake_id, created_at desc);
create index practice_intake_nin_checks_practice on public.practice_intake_nin_checks(practice_id);
create index practice_intake_nin_checks_by on public.practice_intake_nin_checks(checked_by) where checked_by is not null;
alter table public.practice_intake_nin_checks enable row level security;
revoke all on public.practice_intake_nin_checks from anon, authenticated;

-- The practice's partner or manager who asks (the mono function passes the signed-in person).
create or replace function private.practice_lead_of(p_practice uuid, p_user uuid) returns public.practice_members
language plpgsql stable set search_path = public, private as $$
declare m public.practice_members;
begin
  select * into m from practice_members where practice_id = p_practice and user_id = p_user and status = 'active' and role in ('partner', 'manager');
  if m.id is null then raise exception 'Only partners and managers of the practice do this.' using errcode = '42501'; end if;
  return m;
end $$;

-- A lookup from the intake: only a partner or manager, and within the person's daily lookups (search, profile, tin or nin,
-- as for a business's own onboarding). True when it may go ahead.
create or replace function public.practice_lookup_take(p_practice uuid, p_kind text) returns boolean
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.practice_require(p_practice, true);
  if p_kind not in ('search', 'profile', 'tin', 'nin') then raise exception 'Unknown lookup.'; end if;
  return public.svc_kyc_take(auth.uid(), p_kind);
end $$;

-- The search's results, kept for the record to be chosen from. {lookup_id, candidates}.
create or replace function public.svc_practice_cac_search(p_user uuid, p_practice uuid, p_query text, p_candidates jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.practice_cac_lookups;
begin
  perform private.practice_lead_of(p_practice, p_user);
  insert into practice_cac_lookups (practice_id, query, candidates, created_by)
  values (p_practice, left(btrim(coalesce(p_query, '')), 100),
    case when jsonb_typeof(p_candidates) = 'array' then (select coalesce(jsonb_agg(x), '[]'::jsonb) from (select x from jsonb_array_elements(p_candidates) x limit 10) y) else '[]'::jsonb end,
    p_user)
  returning * into l;
  return jsonb_build_object('lookup_id', l.id, 'candidates', l.candidates);
end $$;

-- The candidate chosen, as the search returned it (the record is looked up for it alone).
create or replace function public.svc_practice_cac_candidate(p_user uuid, p_lookup uuid, p_cac_id text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.practice_cac_lookups; v jsonb;
begin
  select * into l from practice_cac_lookups where id = p_lookup;
  if l.id is null or l.created_at < now() - interval '1 day' then raise exception 'Search for the business again and pick it from the list.'; end if;
  perform private.practice_lead_of(l.practice_id, p_user);
  select x into v from jsonb_array_elements(l.candidates) x where x->>'id' = coalesce(p_cac_id, '') limit 1;
  if v is null then raise exception 'Search for the business again and pick it from the list.'; end if;
  return v;
end $$;

-- The record read for the candidate, and the Tax ID found for it. Answers what the intake's fields become (the person
-- saves them): {lookup_id, legal_name, entity_type, rc_number, tax_id, address, industry, people: [{kind, name, role,
-- ownership_pct, nationality}], notes}.
create or replace function public.svc_practice_cac_record(p_user uuid, p_lookup uuid, p_record jsonb, p_tin jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.practice_cac_lookups; c jsonb; v_cls text; v_type text; v_total numeric; v_people jsonb; v_tin text;
begin
  select * into l from practice_cac_lookups where id = p_lookup for update;
  if l.id is null then raise exception 'Search for the business again and pick it from the list.'; end if;
  perform private.practice_lead_of(l.practice_id, p_user);
  if jsonb_typeof(p_record) is distinct from 'object' then raise exception 'The CAC record came back empty.'; end if;
  update practice_cac_lookups set record = p_record, cac_id = left(p_record->>'cac_id', 40),
    tin = case when jsonb_typeof(p_tin) = 'object' then p_tin end, selected_at = now()
  where id = l.id;
  c := p_record->'profile';
  v_cls := upper(coalesce(c->>'classification', ''));
  v_type := case when v_cls like 'COMPANY%' then 'company' when v_cls = 'BUSINESS_NAME' then 'business_name'
                 when v_cls = 'IT' then 'incorporated_trustees' when v_cls = 'LP' then 'partnership' end;
  v_total := (select sum(case when s->>'num_shares_alloted' ~ '^[0-9]+(\.[0-9]+)?$' then (s->>'num_shares_alloted')::numeric else 0 end)
              from jsonb_array_elements(coalesce(c->'shareholders', '[]'::jsonb)) s);
  -- Directors, then shareholders of a quarter or more as beneficial owners (anyone holding 25% of a company is one under
  -- the CAMA's significant-control rule), then the people with significant control CAC lists.
  v_people := coalesce((select jsonb_agg(p order by n) from (
      select 1 as n, jsonb_build_object('kind', 'director', 'name', private.person(d), 'role', case when (d->>'is_chairman')::boolean then 'Chairman' else 'Director' end,
        'nationality', nullif(initcap(lower(d->>'nationality')), '')) as p
      from jsonb_array_elements(coalesce(c->'directors', '[]'::jsonb)) d where private.person(d) is not null
      union all
      select 2, jsonb_build_object('kind', 'beneficial_owner', 'name', coalesce(private.person(s), initcap(lower(s->>'corporation_name'))), 'role', 'Shareholder',
        'ownership_pct', round((s->>'num_shares_alloted')::numeric * 100 / v_total, 2), 'nationality', nullif(initcap(lower(s->>'nationality')), ''))
      from jsonb_array_elements(coalesce(c->'shareholders', '[]'::jsonb)) s
      where v_total > 0 and s->>'num_shares_alloted' ~ '^[0-9]+(\.[0-9]+)?$' and (s->>'num_shares_alloted')::numeric * 4 >= v_total
        and coalesce(private.person(s), nullif(btrim(s->>'corporation_name'), '')) is not null
      union all
      select 3, jsonb_build_object('kind', 'beneficial_owner', 'name', coalesce(private.person(s), initcap(lower(s->>'corporation_name'))), 'role', 'Significant control',
        'nationality', nullif(initcap(lower(s->>'nationality')), ''))
      from jsonb_array_elements(coalesce(p_record->'psc', '[]'::jsonb)) s
      where coalesce(private.person(s), nullif(btrim(s->>'corporation_name'), '')) is not null) z), '[]'::jsonb);
  -- One entry per name (a director who is also a shareholder appears once, as a director).
  v_people := (select coalesce(jsonb_agg(p order by n), '[]'::jsonb) from (
    select distinct on (private.fold_name(lower(p->>'name'))) p, n from jsonb_array_elements(v_people) with ordinality e(p, n)
    order by private.fold_name(lower(p->>'name')), n) q);
  v_tin := coalesce(nullif(regexp_replace(coalesce(p_tin->>'nrs_tin', ''), '\D', '', 'g'), ''), nullif(regexp_replace(coalesce(c->>'tax_id', ''), '\D', '', 'g'), ''));
  return jsonb_build_object('lookup_id', l.id,
    'legal_name', coalesce(nullif(btrim(c->>'approved_name'), ''), l.query),
    'entity_type', v_type,
    'rc_number', case when nullif(btrim(c->>'rc_number'), '') is null then null
      when private.reg_kind(c->>'rc_number') is not null then btrim(c->>'rc_number')
      else case v_type when 'company' then 'RC ' when 'business_name' then 'BN ' when 'incorporated_trustees' then 'IT ' else '' end || btrim(c->>'rc_number') end,
    'tax_id', v_tin,
    'address', left(coalesce(nullif(btrim(c->>'address'), ''), nullif(btrim(c->>'business_address'), ''), nullif(btrim(c->>'head_office_address'), '')), 300),
    'industry', left(coalesce(nullif(btrim(c->>'nature_of_business_name'), ''), nullif(btrim(left(c->>'objectives', 80)), '')), 80),
    'people', v_people,
    'active', (c->>'active')::boolean,
    'registered_on', left(c->>'registration_date', 10));
end $$;

-- The CAC record found, attached to the intake (kept with it, and given to the business when the firm sets it up under full
-- mandate). The person saves the intake's fields themselves.
create or replace function public.practice_intake_attach_cac(p_intake uuid, p_lookup uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.practice_intakes; l public.practice_cac_lookups;
begin
  i := private.intake_require(p_intake, true);
  if i.status = 'declined' then raise exception 'This intake was declined after the conflicts check. Start a new one.'; end if;
  if private.intake_kept(i) then raise exception 'This intake is kept as the record of the engagement. Start a new intake to record changes.'; end if;
  select * into l from practice_cac_lookups where id = p_lookup;
  if l.id is null or l.practice_id <> i.practice_id or l.record is null then raise exception 'Find the business on CAC again.'; end if;
  update practice_intakes set cac = l.record, cac_tin = l.tin, cac_at = coalesce(l.selected_at, now()), updated_at = now() where id = i.id;
  return public.practice_intake(i.id);
end $$;

-- A NIN looked up from the intake (the mono function): the names NIMC holds, kept with the last four digits.
-- p: {first, middle, last, last4}. Answers {name, last4}.
create or replace function public.svc_practice_intake_nin(p_user uuid, p_intake uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.practice_intakes; m public.practice_members; v_name text; v_last4 text;
begin
  select * into i from practice_intakes where id = p_intake;
  if i.id is null then raise exception 'Intake not found.'; end if;
  m := private.practice_lead_of(i.practice_id, p_user);
  if i.status = 'declined' then raise exception 'This intake was declined after the conflicts check. Start a new one.'; end if;
  if private.intake_kept(i) then raise exception 'This intake is kept as the record of the engagement. Start a new intake to record changes.'; end if;
  v_name := left(initcap(lower(btrim(regexp_replace(concat_ws(' ', p->>'first', p->>'middle', p->>'last'), '\s+', ' ', 'g')))), 160);
  v_last4 := right(regexp_replace(coalesce(p->>'last4', ''), '\D', '', 'g'), 4);
  if length(v_name) < 2 or v_last4 !~ '^[0-9]{4}$' then raise exception 'The NIN record came back without a full name.'; end if;
  insert into practice_intake_nin_checks (intake_id, practice_id, name, last4, checked_by) values (i.id, i.practice_id, v_name, v_last4, m.id);
  return jsonb_build_object('name', v_name, 'last4', v_last4);
end $$;

-- What the intake page shows of its lookups: the CAC record attached (a summary) and the NINs checked.
create or replace function public.practice_intake_lookups(p_intake uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.practice_intakes;
begin
  i := private.intake_require(p_intake);
  return jsonb_build_object(
    'cac', case when i.cac is not null then jsonb_build_object('name', i.cac->'profile'->>'approved_name', 'rc_number', i.cac->'profile'->>'rc_number',
      'classification', i.cac->'profile'->>'classification', 'active', (i.cac->'profile'->>'active')::boolean, 'at', i.cac_at,
      'tax_id', coalesce(i.cac_tin->>'nrs_tin', i.cac->'profile'->>'tax_id')) end,
    'nin_checks', (select coalesce(jsonb_agg(jsonb_build_object('name', n.name, 'last4', n.last4, 'at', n.created_at, 'by', pm.display_name)
        order by n.created_at desc), '[]'::jsonb)
      from practice_intake_nin_checks n left join practice_members pm on pm.id = n.checked_by where n.intake_id = i.id));
end $$;

-- A business set up under full mandate starts with the intake's CAC record as its profile draft (the firm checks it and
-- submits it under Settings, Business profile, without looking the company up again).
create or replace function private.practice_clients_cac() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare i public.practice_intakes;
begin
  if new.mode <> 'full' or new.intake_id is null or new.org_id is null then return new; end if;
  select * into i from practice_intakes where id = new.intake_id;
  if i.cac is null or exists (select 1 from kyc_profiles where org_id = new.org_id) then return new; end if;
  insert into kyc_profiles (user_id, org_id, status, source, cac, tin, for_business, search)
  values (coalesce(new.created_by, auth.uid(), i.created_by), new.org_id, 'draft', 'cac', i.cac, i.cac_tin, true,
    jsonb_build_object('query', i.legal_name, 'candidates', '[]'::jsonb, 'at', i.cac_at))
  on conflict do nothing;
  return new;
end $$;
drop trigger if exists practice_clients_cac on public.practice_clients;
create trigger practice_clients_cac after insert on public.practice_clients for each row execute function private.practice_clients_cac();

-- A month after the search, an unattached lookup is gone (an attached one lives on in its intake).
create or replace function private.practice_cac_lookups_tick() returns integer
language sql security definer set search_path = public, private as $$
  with g as (delete from practice_cac_lookups where created_at < now() - interval '30 days' returning 1)
  select count(*)::int from g
$$;
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('counta-cac-lookups', '25 3 * * *', 'select private.practice_cac_lookups_tick()');
  end if;
end $$;

-- The identity checks hold where a code went and nothing a person typed: they stay out of the business's activity log,
-- as the KYC profiles do (latest definition, 20261124000600_intake_conflicts.sql, with identity_checks).
create or replace function private.activity_exempt() returns text[]
language sql immutable set search_path = public, private as $$
  select array['activity_log', 'messages', 'notifications', 'alert_log', 'usage_events', 'ai_logs', 'shop_hits', 'payment_events', 'org_counters',
    'stock_levels', 'agent_runs', 'guide_progress', 'lookup_failures', 'sso_logins', 'whatsapp_sessions', 'chat_links', 'voice_calls',
    'integration_events', 'prism_callbacks', 'kyc_profiles', 'practice_intakes', 'identity_checks']
$$;

-- ---------------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------------
revoke all on function private.sms_phone(text), private.mask_phone(text), private.clean_email(text), private.mask_email(text), private.sms_ready(),
  private.org_cac(uuid), private.cac_people(jsonb), private.name_parts(text), private.identity_mail(text, uuid),
  private.identity_check_new(text, uuid, uuid, jsonb), private.identity_send(uuid), private.identity_verify(uuid, text), private.identity_close(uuid),
  private.identity_wipe_tick(), private.director_settle(uuid, text, text, text, uuid), private.practice_lead_of(uuid, uuid),
  private.practice_clients_cac(), private.practice_cac_lookups_tick(), private.activity_exempt()
  from public, anon, authenticated;
revoke execute on function public.svc_director_nin_begin(text, text, text), public.svc_director_identity(text, jsonb, text, text),
  public.svc_director_slip(text, text, text, text), public.svc_director_slip_target(text, text), public.svc_identity_mail(text, uuid),
  public.svc_practice_cac_search(uuid, uuid, text, jsonb), public.svc_practice_cac_candidate(uuid, uuid, text),
  public.svc_practice_cac_record(uuid, uuid, jsonb, jsonb), public.svc_practice_intake_nin(uuid, uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.svc_director_nin_begin(text, text, text), public.svc_director_identity(text, jsonb, text, text),
  public.svc_director_slip(text, text, text, text), public.svc_director_slip_target(text, text), public.svc_identity_mail(text, uuid),
  public.svc_practice_cac_search(uuid, uuid, text, jsonb), public.svc_practice_cac_candidate(uuid, uuid, text),
  public.svc_practice_cac_record(uuid, uuid, jsonb, jsonb), public.svc_practice_intake_nin(uuid, uuid, jsonb)
  to service_role;
revoke execute on function public.practice_director_link(uuid), public.practice_director_state(uuid), public.practice_lookup_take(uuid, text),
  public.practice_intake_attach_cac(uuid, uuid), public.practice_intake_lookups(uuid)
  from public, anon;
grant execute on function public.practice_director_link(uuid), public.practice_director_state(uuid), public.practice_lookup_take(uuid, text),
  public.practice_intake_attach_cac(uuid, uuid), public.practice_intake_lookups(uuid)
  to authenticated;
