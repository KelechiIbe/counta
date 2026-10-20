-- Counta, 29 October 2026: who hears about a NIN slip waiting for review, and the relay secret as pasted.
--
-- When a business owner's NIN slip does not match a director on the CAC record, the business waits for a TaxStreem
-- reviewer and its payments stay locked. Until now nobody was told. Counta now emails the review address (set in the
-- admin portal under Keys and services, Counta: "Email for NIN slip reviews", admin@taxstreem.com when empty) and every
-- reviewer on the admin portal's Team page. The email names the business and links to the review page; it carries no NIN
-- and nothing from the slip.
--
-- The transfer relay's secret is 64 hex characters. The admin portal now keeps only those when the paste carries more (the
-- "RELAY_SECRET=" before it, or the server's prompt after it), and refuses a paste without them.

-- ---------------------------------------------------------------------------
-- The setting, and its check
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
    if p_name in ('NUMENS_API_URL', 'FLUX_URL', 'APP_URL', 'FLW_RELAY_URL') and v !~ '^https://[^\s]+$' then raise exception 'Enter an https:// address.'; end if;
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
-- Who to tell: the review address (admin@taxstreem.com unless set) and each reviewer, once each
-- ---------------------------------------------------------------------------
create or replace function public.svc_review_recipients() returns text[]
language sql stable security definer set search_path = public, vault, private as $$
  select coalesce(array_agg(distinct e order by e), '{}') from (
    select lower(btrim(coalesce(nullif(btrim((select s.decrypted_secret from vault.decrypted_secrets s where s.name = 'KYC_REVIEW_EMAIL'
      order by s.created_at desc limit 1)), ''), 'admin@taxstreem.com'))) e
    union
    select lower(u.email) from platform_reviewers r join auth.users u on u.id = r.user_id where u.email is not null
  ) x where e ~* '^[A-Z0-9._%+-]+@[A-Z0-9-]+(\.[A-Z0-9-]+)*\.[A-Z]{2,}$'
$$;
revoke all on function public.svc_review_recipients() from public, anon, authenticated;
grant execute on function public.svc_review_recipients() to service_role;
