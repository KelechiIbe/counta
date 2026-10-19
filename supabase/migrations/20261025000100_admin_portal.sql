-- Counta · The admin portal: TaxStreem's own settings, applied to every business and kept out of customers' Settings.
--
-- Who may open it: TaxStreem's admins (platform_admins) and identity reviewers (platform_reviewers), and only in a session
-- confirmed with an authenticator code (Supabase Auth assurance level aal2). Everything here checks both, in the database.
-- What it holds: the keys Counta uses (written to Supabase Vault, never shown again), Martina's voice and the voices on offer,
-- currencies and exchange rates, daily limits, switches for everyone or for one business, the tax rule book, and read-only
-- views of businesses, people and what has failed. Every change is written to admin_audit.

-- ---------------------------------------------------------------------------
-- 1. Who runs the portal, and the authenticator code they must have used
-- ---------------------------------------------------------------------------
create table if not exists public.platform_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  added_by uuid references auth.users(id) on delete set null,
  added_at timestamptz not null default now()
);
create index if not exists platform_admins_added_by on public.platform_admins(added_by);
alter table public.platform_admins enable row level security;
revoke all on public.platform_admins from anon, authenticated;
alter table public.platform_reviewers add column if not exists added_by uuid references auth.users(id) on delete set null;
create index if not exists platform_reviewers_added_by on public.platform_reviewers(added_by);

-- How the caller signed in: aal2 once they entered a code from their authenticator app in this session.
create or replace function private.jwt_aal() returns text
language sql stable set search_path = public as $$
  select coalesce(nullif(current_setting('request.jwt.claim.aal', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'aal'), 'aal1')
$$;

create or replace function private.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid())
$$;

-- Reviewers (and admins) see NIN slips, but only in a session confirmed with an authenticator code.
create or replace function private.is_reviewer() returns boolean
language sql stable security definer set search_path = public, private as $$
  select (exists (select 1 from public.platform_reviewers where user_id = auth.uid()) or private.is_admin()) and private.jwt_aal() = 'aal2'
$$;

-- Every admin call starts here. p_admin false lets reviewers through too (the reviews screen).
create or replace function private.require_staff(p_admin boolean default true) returns uuid
language plpgsql stable security definer set search_path = public, private as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if not (private.is_admin() or (not p_admin and exists (select 1 from platform_reviewers where user_id = auth.uid()))) then
    raise exception 'This is only for TaxStreem''s admins.' using errcode = '42501';
  end if;
  if private.jwt_aal() <> 'aal2' then
    raise exception 'Enter the code from your authenticator app to open the admin portal.' using errcode = '42501';
  end if;
  return auth.uid();
end $$;

-- What the signed-in person is: the app shows the portal link to staff, and asks for the code before opening it.
create or replace function public.admin_me() returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object(
    'admin', private.is_admin(),
    'reviewer', exists (select 1 from platform_reviewers where user_id = auth.uid()),
    'staff', private.is_admin() or exists (select 1 from platform_reviewers where user_id = auth.uid()),
    'aal2', private.jwt_aal() = 'aal2')
$$;

-- The portal's record of every change: who, what and when. Values of keys are never written here, only their last four.
create table if not exists public.admin_audit (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  user_id uuid references auth.users(id) on delete set null,
  action text not null,
  target text,
  detail jsonb not null default '{}'::jsonb
);
create index if not exists admin_audit_at on public.admin_audit(at desc);
create index if not exists admin_audit_user on public.admin_audit(user_id);
alter table public.admin_audit enable row level security;
revoke all on public.admin_audit from anon, authenticated;

create or replace function private.audit(p_action text, p_target text, p_detail jsonb default '{}'::jsonb) returns void
language sql security definer set search_path = public as $$
  insert into admin_audit (user_id, action, target, detail) values (auth.uid(), p_action, p_target, coalesce(p_detail, '{}'::jsonb))
$$;

-- ---------------------------------------------------------------------------
-- 2. Platform settings: Martina, daily limits and switches
-- ---------------------------------------------------------------------------
create table if not exists public.platform_settings (
  key text primary key check (key in ('martina', 'limits', 'switches')),
  value jsonb not null default '{}'::jsonb,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);
create index if not exists platform_settings_updated_by on public.platform_settings(updated_by);
alter table public.platform_settings enable row level security;
revoke all on public.platform_settings from anon, authenticated;

-- What Counta did before the portal existed, so an empty table changes nothing.
create or replace function private.setting_defaults(p_key text) returns jsonb
language sql immutable set search_path = public as $$
  select case p_key
    when 'martina' then '{"tone": "calm", "default_voice_id": null}'::jsonb
    when 'limits' then '{"guide_day": 8, "guide_week": 25, "assistant_day": 30, "assistant_week": 150,
      "voice_org_phrases": 600, "voice_org_chars": 60000, "voice_user_phrases": 60, "voice_user_chars": 6000,
      "lookups": {"search": 20, "profile": 6, "tin": 6, "status_report": 3, "web": 8, "document": 6, "nin": 5, "nin_slip": 4, "product": 200}}'::jsonb
    when 'switches' then '{"new_businesses": true, "martina": true, "phone_calls": true, "payment_voice": true, "ai_reading": true,
      "email": true, "whatsapp": true, "payments": true}'::jsonb
    else '{}'::jsonb end
$$;

create or replace function private.setting(p_key text) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select private.setting_defaults(p_key) || coalesce((select value from platform_settings where key = p_key), '{}'::jsonb)
$$;

-- One daily limit; p_sub names a kind of lookup.
create or replace function private.limit_of(p_key text, p_sub text default null) returns int
language sql stable security definer set search_path = public, private as $$
  select coalesce(
    (select case when p_sub is null then (value->>p_key)::int else (value->p_key->>p_sub)::int end from platform_settings where key = 'limits'),
    case when p_sub is null then (private.setting_defaults('limits')->>p_key)::int else (private.setting_defaults('limits')->p_key->>p_sub)::int end)
$$;

create or replace function private.feature_keys() returns text[]
language sql immutable as $$
  select array['new_businesses', 'martina', 'phone_calls', 'payment_voice', 'ai_reading', 'email', 'whatsapp', 'payments']
$$;

-- A switch set for one business wins either way, so a feature can be paused for one business, or tried with one while it is
-- off for everyone else.
create table if not exists public.org_switches (
  org_id uuid not null references public.orgs(id) on delete cascade,
  feature text not null,
  enabled boolean not null,
  note text,
  set_by uuid references auth.users(id) on delete set null,
  set_at timestamptz not null default now(),
  primary key (org_id, feature)
);
create index if not exists org_switches_set_by on public.org_switches(set_by);
alter table public.org_switches enable row level security;
revoke all on public.org_switches from anon, authenticated;

create or replace function private.feature_on(p_org uuid, p_feature text) returns boolean
language sql stable security definer set search_path = public, private as $$
  select coalesce((select enabled from org_switches where org_id = p_org and feature = p_feature),
                  (private.setting('switches')->>p_feature)::boolean, true)
$$;

-- For the edge functions (service role): one switch, and everything the platform says at once.
create or replace function public.svc_feature(p_org uuid, p_feature text) returns boolean
language sql stable security definer set search_path = public, private as $$
  select private.feature_on(p_org, p_feature)
$$;
create or replace function public.svc_platform() returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('martina', private.setting('martina'), 'switches', private.setting('switches'), 'limits', private.setting('limits'))
$$;
revoke all on function public.svc_feature(uuid, text) from public, anon, authenticated;
revoke all on function public.svc_platform() from public, anon, authenticated;
grant execute on function public.svc_feature(uuid, text) to service_role;
grant execute on function public.svc_platform() to service_role;

-- What a member's screens need to know: features TaxStreem has paused for their business.
create or replace function public.org_features(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare k text; v_out jsonb := '{}'::jsonb;
begin
  perform private.require(p_org, null);
  foreach k in array private.feature_keys() loop
    if k <> 'new_businesses' then v_out := v_out || jsonb_build_object(k, private.feature_on(p_org, k)); end if;
  end loop;
  return v_out;
end $$;

-- New businesses, when TaxStreem has paused sign-ups. The sample business and TaxStreem's own single sign-on still work.
create or replace function private.orgs_new_guard() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if not coalesce(new.is_sample, false) and auth.uid() is not null and (private.setting('switches')->>'new_businesses')::boolean is false then
    raise exception 'TaxStreem has paused new businesses for a short while. Try again later.' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists orgs_new_guard on public.orgs;
create trigger orgs_new_guard before insert on public.orgs for each row execute function private.orgs_new_guard();

-- Vendor and reminder calls, when TaxStreem has paused phone calls for the business (or for everyone).
create or replace function private.voice_calls_guard() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.kind in ('vendor_order', 'reminder') and not private.feature_on(new.org_id, 'phone_calls') then
    raise exception 'Phone calls are paused for this business. Send the order or reminder by WhatsApp or email for now.' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists voice_calls_guard on public.voice_calls;
create trigger voice_calls_guard before insert on public.voice_calls for each row execute function private.voice_calls_guard();

-- ---------------------------------------------------------------------------
-- 4. The portal's settings screens: Martina and voices, limits, switches
-- ---------------------------------------------------------------------------
create or replace function public.admin_settings() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_staff();
  return jsonb_build_object(
    'martina', private.setting('martina'), 'limits', private.setting('limits'), 'switches', private.setting('switches'),
    'defaults', jsonb_build_object('martina', private.setting_defaults('martina'), 'limits', private.setting_defaults('limits'),
      'switches', private.setting_defaults('switches')),
    'voices', (select coalesce(jsonb_agg(jsonb_build_object('voice_id', v.voice_id, 'name', v.name, 'gender', v.gender, 'age', v.age, 'accent', v.accent,
        'description', v.description, 'preview_url', v.preview_url, 'source', v.source, 'active', v.active, 'sort', v.sort,
        'businesses', (select count(*) from orgs o where o.voice_id = v.voice_id)) order by v.active desc, v.sort, v.name), '[]'::jsonb) from tts_voices v),
    'overrides', (select coalesce(jsonb_agg(jsonb_build_object('org_id', s.org_id, 'business', o.name, 'feature', s.feature, 'enabled', s.enabled,
        'note', s.note, 'set_at', s.set_at) order by o.name, s.feature), '[]'::jsonb) from org_switches s join orgs o on o.id = s.org_id),
    'updated', (select coalesce(jsonb_object_agg(p.key, jsonb_build_object('at', p.updated_at, 'by', (select email from auth.users u where u.id = p.updated_by))), '{}'::jsonb)
      from platform_settings p));
end $$;

-- Saves one group. Only known fields, in range; whatever is not sent keeps its value.
create or replace function public.admin_save_setting(p_key text, p_value jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_cur jsonb := private.setting(p_key); v_new jsonb; k text; x jsonb; n numeric; v_old jsonb;
begin
  perform private.require_staff();
  if p_key not in ('martina', 'limits', 'switches') then raise exception 'Unknown setting.'; end if;
  if jsonb_typeof(coalesce(p_value, 'null'::jsonb)) <> 'object' then raise exception 'Nothing to save.'; end if;
  v_new := v_cur;
  if p_key = 'martina' then
    if p_value ? 'tone' then
      if p_value->>'tone' not in ('calm', 'warm', 'lively') then raise exception 'Choose calm, warm or lively.'; end if;
      v_new := v_new || jsonb_build_object('tone', p_value->>'tone');
    end if;
    if p_value ? 'default_voice_id' then
      if nullif(p_value->>'default_voice_id', '') is not null
         and not exists (select 1 from tts_voices where voice_id = p_value->>'default_voice_id' and active) then
        raise exception 'Choose one of the voices on offer.';
      end if;
      v_new := v_new || jsonb_build_object('default_voice_id', nullif(p_value->>'default_voice_id', ''));
    end if;
  elsif p_key = 'limits' then
    for k, x in select * from jsonb_each(p_value) loop
      if k = 'lookups' then
        if jsonb_typeof(x) <> 'object' then raise exception 'Unknown limit.'; end if;
        for k, x in select * from jsonb_each(p_value->'lookups') loop
          if not (private.setting_defaults('limits')->'lookups' ? k) then raise exception 'Unknown lookup: %.', k; end if;
          begin n := (x #>> '{}')::numeric; exception when others then raise exception 'Limits are whole numbers.'; end;
          if n is null or n <> trunc(n) or n < 0 or n > 100000 then raise exception 'Limits are whole numbers from 0 to 100,000.'; end if;
          v_new := jsonb_set(v_new, array['lookups', k], to_jsonb(n::int));
        end loop;
      else
        if not (private.setting_defaults('limits') ? k) then raise exception 'Unknown limit: %.', k; end if;
        begin n := (x #>> '{}')::numeric; exception when others then raise exception 'Limits are whole numbers.'; end;
        if n is null or n <> trunc(n) or n < 0 or n > 10000000 then raise exception 'Limits are whole numbers from 0 to 10,000,000.'; end if;
        v_new := v_new || jsonb_build_object(k, n::int);
      end if;
    end loop;
    if (v_new->>'guide_week')::int < (v_new->>'guide_day')::int or (v_new->>'assistant_week')::int < (v_new->>'assistant_day')::int then
      raise exception 'A week''s limit cannot be smaller than a day''s.';
    end if;
  else
    for k, x in select * from jsonb_each(p_value) loop
      if not (k = any (private.feature_keys())) then raise exception 'Unknown switch: %.', k; end if;
      if jsonb_typeof(x) <> 'boolean' then raise exception 'Switches are on or off.'; end if;
      v_new := v_new || jsonb_build_object(k, x);
    end loop;
  end if;
  select value into v_old from platform_settings where key = p_key;
  insert into platform_settings (key, value, updated_by, updated_at) values (p_key, v_new, auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  perform private.audit('save_' || p_key, p_key, jsonb_build_object('from', coalesce(v_old, v_cur), 'to', v_new));
  return v_new;
end $$;

-- One business's switch: on, off, or back to what everyone has (p_enabled null).
create or replace function public.admin_org_switch(p_org uuid, p_feature text, p_enabled boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.require_staff();
  if not (p_feature = any (private.feature_keys())) or p_feature = 'new_businesses' then raise exception 'Unknown switch.'; end if;
  if not exists (select 1 from orgs where id = p_org) then raise exception 'Business not found.'; end if;
  if p_enabled is null then
    delete from org_switches where org_id = p_org and feature = p_feature;
  else
    insert into org_switches (org_id, feature, enabled, note, set_by, set_at) values (p_org, p_feature, p_enabled, nullif(left(trim(coalesce(p_note, '')), 300), ''), auth.uid(), now())
    on conflict (org_id, feature) do update set enabled = excluded.enabled, note = excluded.note, set_by = excluded.set_by, set_at = excluded.set_at;
  end if;
  perform private.audit('org_switch', p_org::text, jsonb_build_object('feature', p_feature, 'enabled', p_enabled, 'note', p_note));
  return jsonb_build_object('feature', p_feature, 'enabled', private.feature_on(p_org, p_feature), 'override', p_enabled);
end $$;

-- Which voices businesses may choose. One stays on, and Martina's default voice cannot be switched off.
create or replace function public.admin_set_voice(p_voice text, p_active boolean, p_sort int default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v public.tts_voices;
begin
  perform private.require_staff();
  select * into v from tts_voices where voice_id = p_voice for update;
  if not found then raise exception 'Voice not found.'; end if;
  if not p_active and v.active then
    if (select count(*) from tts_voices where active) <= 1 then raise exception 'Keep at least one voice on offer.'; end if;
    if private.setting('martina')->>'default_voice_id' = p_voice then raise exception 'This is Martina''s voice. Choose another one for her first.'; end if;
  end if;
  update tts_voices set active = p_active, sort = coalesce(p_sort, sort), updated_at = now() where voice_id = p_voice;
  perform private.audit('set_voice', p_voice, jsonb_build_object('name', v.name, 'active', p_active, 'sort', p_sort));
  return jsonb_build_object('voice_id', p_voice, 'active', p_active);
end $$;

-- ---------------------------------------------------------------------------
-- 3. Keys and services, written to Supabase Vault from the portal
-- ---------------------------------------------------------------------------
-- Every key and setting the portal manages, in the groups it shows them. A secret is written once and never shown again
-- (the portal shows its last four characters, or the service account's address); a plain setting is shown as it is.
-- The edge functions read Vault first and fall back to their Edge Function secrets, so a value set here takes over.
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
    ('VAPID_SUBJECT', 'counta', 'Contact for push notifications', false, 'mailto: and an address browsers may write to about notifications.', 902)
$$;

-- Who set each key and when, and what the portal may show of it.
create table if not exists public.platform_secrets (
  name text primary key,
  shown text,
  set_by uuid references auth.users(id) on delete set null,
  set_at timestamptz not null default now()
);
create index if not exists platform_secrets_set_by on public.platform_secrets(set_by);
alter table public.platform_secrets enable row level security;
revoke all on public.platform_secrets from anon, authenticated;

-- The service role reads every key in the catalogue from Vault (the names it read before stay as they were).
create or replace function public.app_secret(p_name text) returns text
language sql stable security definer set search_path = public, vault, private as $$
  select s.decrypted_secret from vault.decrypted_secrets s
  where s.name = p_name
    and (p_name in ('GEMINI_API_KEY', 'GEMINI_MODEL', 'ELEVENLABS_API_KEY', 'ELEVENLABS_PHONE_NUMBER_ID', 'ELEVENLABS_VOICE_ID',
                    'VAPID_PUBLIC_KEY', 'VAPID_PRIVATE_KEY', 'VAPID_SUBJECT', 'PUSH_HOOK_SECRET')
         or p_name in (select c.name from private.secret_catalog() c))
  order by s.created_at desc
  limit 1
$$;
revoke all on function public.app_secret(text) from public, anon, authenticated;
grant execute on function public.app_secret(text) to service_role;

create or replace function public.svc_secret(p_name text) returns text
language sql stable security definer set search_path = public, vault, private as $$
  select s.decrypted_secret from vault.decrypted_secrets s
  where s.name = p_name
    and (p_name in (select c.name from private.secret_catalog() c)
         or p_name in (select api_key_secret from public.payment_rails where api_key_secret is not null
                       union select webhook_secret from public.payment_rails where webhook_secret is not null))
  order by s.created_at desc limit 1
$$;
revoke all on function public.svc_secret(text) from public, anon, authenticated;
grant execute on function public.svc_secret(text) to service_role;

-- The catalogue as the portal shows it. Secrets: whether set, and the last four characters (or the service account).
create or replace function public.admin_integrations() returns jsonb
language plpgsql stable security definer set search_path = public, private, vault as $$
begin
  perform private.require_staff();
  return (select coalesce(jsonb_agg(jsonb_build_object('name', c.name, 'group', c.grp, 'label', c.label, 'secret', c.secret, 'hint', c.hint,
      'set', coalesce(s.decrypted_secret, '') <> '',
      'shown', case when coalesce(s.decrypted_secret, '') = '' then null
                    when c.secret then coalesce(p.shown, '•••• ' || right(s.decrypted_secret, 4)) else s.decrypted_secret end,
      'set_at', coalesce(p.set_at, s.created_at), 'set_by', (select email from auth.users u where u.id = p.set_by)) order by c.sort), '[]'::jsonb)
    from private.secret_catalog() c
    left join lateral (select v.decrypted_secret, v.created_at from vault.decrypted_secrets v where v.name = c.name order by v.created_at desc limit 1) s on true
    left join platform_secrets p on p.name = c.name);
end $$;

-- Writes one key or setting. A secret is checked for shape, stored in Vault and never returned.
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
  elsif c.secret then
    if length(v) < 8 then raise exception 'That is too short for a key.'; end if;
    v_shown := '•••• ' || right(v, 4);
  else
    if p_name in ('NUMENS_API_URL', 'FLUX_URL', 'APP_URL') and v !~ '^https://[^\s]+$' then raise exception 'Enter an https:// address.'; end if;
    if p_name = 'RESEND_FROM' and v !~* '[A-Z0-9._%+-]+@[A-Z0-9-]+(\.[A-Z0-9-]+)*\.[A-Z]{2,}' then raise exception 'Enter an email address, such as billing@taxstreem.com.'; end if;
    if p_name = 'VAPID_SUBJECT' and v !~ '^(mailto:[^\s@]+@[^\s@]+|https://[^\s]+)$' then raise exception 'Enter mailto: and an email address.'; end if;
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

-- Clears a key in Vault, so the Edge Function secret (if any) applies again.
create or replace function public.admin_clear_secret(p_name text) returns jsonb
language plpgsql security definer set search_path = public, private, vault as $$
declare v_id uuid;
begin
  perform private.require_staff();
  if not exists (select 1 from private.secret_catalog() c where c.name = p_name) then raise exception 'Unknown setting.'; end if;
  select id into v_id from vault.secrets where name = p_name order by created_at desc limit 1;
  if v_id is not null then perform vault.update_secret(v_id, ''); end if;
  delete from platform_secrets where name = p_name;
  perform private.audit('clear_key', p_name, '{}'::jsonb);
  return jsonb_build_object('name', p_name, 'set', false);
end $$;

-- ---------------------------------------------------------------------------
-- 5. Currencies and exchange rates
-- ---------------------------------------------------------------------------
-- Naira is the base. TaxStreem chooses which other currencies businesses may use (import entries now; foreign-currency
-- invoices and bills when they come), and the rates Counta uses: fetched every day, or set by hand for a day, which wins.
create table if not exists public.currencies (
  code text primary key check (code ~ '^[A-Z]{3}$'),
  name text not null,
  symbol text,
  allowed boolean not null default false,
  sort int not null default 100,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);
create index if not exists currencies_updated_by on public.currencies(updated_by);
insert into public.currencies (code, name, symbol, allowed, sort) values
  ('NGN', 'Nigerian naira', '₦', true, 0), ('USD', 'US dollar', '$', true, 1), ('GBP', 'British pound', '£', true, 2),
  ('EUR', 'Euro', '€', true, 3), ('CNY', 'Chinese yuan', '¥', true, 4), ('AED', 'UAE dirham', 'AED', true, 5),
  ('INR', 'Indian rupee', '₹', true, 6), ('JPY', 'Japanese yen', '¥', true, 7), ('ZAR', 'South African rand', 'R', true, 8),
  ('GHS', 'Ghanaian cedi', 'GH₵', false, 20), ('KES', 'Kenyan shilling', 'KSh', false, 21), ('XOF', 'West African CFA franc', 'CFA', false, 22),
  ('CAD', 'Canadian dollar', 'C$', false, 23), ('CHF', 'Swiss franc', 'CHF', false, 24), ('SAR', 'Saudi riyal', 'SAR', false, 25),
  ('EGP', 'Egyptian pound', 'E£', false, 26), ('TRY', 'Turkish lira', '₺', false, 27), ('BRL', 'Brazilian real', 'R$', false, 28)
on conflict (code) do nothing;
alter table public.currencies enable row level security;
drop policy if exists currencies_read on public.currencies;
create policy currencies_read on public.currencies for select to authenticated using (true);

create table if not exists public.exchange_rates (
  currency text not null references public.currencies(code) on delete cascade,
  day date not null,
  rate_ngn numeric(18,6) not null check (rate_ngn > 0),
  source text not null check (source in ('auto', 'manual')),
  set_by uuid references auth.users(id) on delete set null,
  at timestamptz not null default now(),
  primary key (currency, day, source)
);
create index if not exists exchange_rates_set_by on public.exchange_rates(set_by);
create index if not exists exchange_rates_day on public.exchange_rates(currency, day desc);
alter table public.exchange_rates enable row level security;
drop policy if exists exchange_rates_read on public.exchange_rates;
create policy exchange_rates_read on public.exchange_rates for select to authenticated using (true);
-- The dollar rates Counta already kept count as fetched rates.
insert into public.exchange_rates (currency, day, rate_ngn, source)
select 'USD', day, usd_ngn, 'auto' from public.fx_rates where usd_ngn > 0
on conflict do nothing;

-- Naira for one unit of the currency on a day: the latest rate on or before it, a rate set by hand winning that day.
create or replace function private.fx_rate(p_currency text, p_day date) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select case when upper(p_currency) = 'NGN' then jsonb_build_object('currency', 'NGN', 'rate', 1, 'day', p_day, 'source', 'base')
    else (select jsonb_build_object('currency', currency, 'rate', rate_ngn, 'day', day, 'source', source) from exchange_rates
          where currency = upper(p_currency) and day <= coalesce(p_day, current_date) order by day desc, (source = 'manual') desc limit 1) end
$$;
create or replace function public.fx_rate_on(p_currency text, p_day date default null) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select private.fx_rate(p_currency, coalesce(p_day, (now() at time zone 'Africa/Lagos')::date))
$$;

-- For the fx function: the currencies to fetch, and the day's rates it fetched (never over a rate set by hand).
create or replace function public.svc_fx_currencies() returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(code order by sort), '{}') from currencies where allowed and code <> 'NGN'
$$;
create or replace function public.svc_save_rates(p_day date, p_rates jsonb) returns int
language plpgsql security definer set search_path = public, private as $$
declare k text; v text; n int := 0; r numeric;
begin
  for k, v in select * from jsonb_each_text(coalesce(p_rates, '{}'::jsonb)) loop
    begin r := v::numeric; exception when others then continue; end;
    if r is null or r <= 0 or not exists (select 1 from currencies where code = upper(k)) then continue; end if;
    insert into exchange_rates (currency, day, rate_ngn, source) values (upper(k), p_day, round(r, 6), 'auto')
    on conflict (currency, day, source) do update set rate_ngn = excluded.rate_ngn, at = now();
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.svc_fx_currencies() from public, anon, authenticated;
revoke all on function public.svc_save_rates(date, jsonb) from public, anon, authenticated;
grant execute on function public.svc_fx_currencies() to service_role;
grant execute on function public.svc_save_rates(date, jsonb) to service_role;

create or replace function public.admin_currencies() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_today date := (now() at time zone 'Africa/Lagos')::date;
begin
  perform private.require_staff();
  return (select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'name', c.name, 'symbol', c.symbol, 'allowed', c.allowed, 'base', c.code = 'NGN',
      'rate', private.fx_rate(c.code, v_today),
      'manual', (select coalesce(jsonb_agg(jsonb_build_object('day', e.day, 'rate', e.rate_ngn, 'by', (select email from auth.users u where u.id = e.set_by), 'at', e.at)
                  order by e.day desc), '[]'::jsonb) from (select * from exchange_rates where currency = c.code and source = 'manual' order by day desc limit 10) e),
      'history', (select coalesce(jsonb_agg(jsonb_build_object('day', e.day, 'rate', e.rate_ngn, 'source', e.source) order by e.day desc), '[]'::jsonb)
                  from (select distinct on (day) * from exchange_rates where currency = c.code and day > v_today - 14 order by day desc, (source = 'manual') desc) e))
    order by c.sort, c.code), '[]'::jsonb) from currencies c);
end $$;

create or replace function public.admin_set_currency(p_code text, p_allowed boolean) returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.require_staff();
  if upper(p_code) = 'NGN' and not p_allowed then raise exception 'Naira is the base currency and stays on.'; end if;
  update currencies set allowed = p_allowed, updated_by = auth.uid(), updated_at = now() where code = upper(p_code);
  if not found then raise exception 'Unknown currency.'; end if;
  perform private.audit('set_currency', upper(p_code), jsonb_build_object('allowed', p_allowed));
  return jsonb_build_object('code', upper(p_code), 'allowed', p_allowed);
end $$;

-- A rate set by hand for one day (it stands until a later rate exists). The dollar rate also feeds the reorder timing advice.
create or replace function public.admin_set_rate(p_code text, p_day date, p_rate numeric) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_code text := upper(coalesce(p_code, ''));
begin
  perform private.require_staff();
  if v_code = 'NGN' then raise exception 'Naira is the base: its rate is always 1.'; end if;
  if not exists (select 1 from currencies where code = v_code) then raise exception 'Unknown currency.'; end if;
  if p_day is null or p_day > (now() at time zone 'Africa/Lagos')::date + 7 or p_day < date '2020-01-01' then raise exception 'Choose a day from 2020 up to a week ahead.'; end if;
  if p_rate is null or p_rate <= 0 or p_rate > 100000 then raise exception 'Enter how many naira one unit is worth.'; end if;
  insert into exchange_rates (currency, day, rate_ngn, source, set_by, at) values (v_code, p_day, round(p_rate, 6), 'manual', auth.uid(), now())
  on conflict (currency, day, source) do update set rate_ngn = excluded.rate_ngn, set_by = excluded.set_by, at = excluded.at;
  if v_code = 'USD' then
    insert into fx_rates (day, usd_ngn, source, fetched_at) values (p_day, round(p_rate, 4), 'manual', now())
    on conflict (day) do update set usd_ngn = excluded.usd_ngn, source = 'manual', fetched_at = now();
  end if;
  perform private.audit('set_rate', v_code, jsonb_build_object('day', p_day, 'rate', p_rate));
  return private.fx_rate(v_code, p_day);
end $$;

create or replace function public.admin_clear_rate(p_code text, p_day date) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_code text := upper(coalesce(p_code, ''));
begin
  perform private.require_staff();
  delete from exchange_rates where currency = v_code and day = p_day and source = 'manual';
  if v_code = 'USD' then
    delete from fx_rates where day = p_day and source = 'manual';
    insert into fx_rates (day, usd_ngn, source) select day, rate_ngn, 'currency-api' from exchange_rates
    where currency = 'USD' and day = p_day and source = 'auto' on conflict (day) do nothing;
  end if;
  perform private.audit('clear_rate', v_code, jsonb_build_object('day', p_day));
  return private.fx_rate(v_code, p_day);
end $$;

-- Import entries are in a currency TaxStreem allows.
create or replace function private.customs_currency_guard() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if tg_op = 'UPDATE' then
    if new.currency is not distinct from old.currency then return new; end if;
  end if;
  if not exists (select 1 from currencies where code = upper(new.currency) and allowed) then
    raise exception '% is not a currency Counta takes yet.', upper(new.currency);
  end if;
  return new;
end $$;
drop trigger if exists customs_currency_guard on public.customs_entries;
create trigger customs_currency_guard before insert or update of currency on public.customs_entries for each row execute function private.customs_currency_guard();

-- ---------------------------------------------------------------------------
-- 6. The tax rule book: VAT, companies income tax, capital allowances and withholding tax rates
-- ---------------------------------------------------------------------------
-- Rules are dated: a new rate starts on a day and earlier periods keep the rate they had. VAT joins the rule book, and
-- every calculation that used 7.5% now asks for the rate on the day it is about.
alter table public.tax_rules add column if not exists set_by uuid references auth.users(id) on delete set null;
alter table public.tax_rules add column if not exists set_at timestamptz;
create index if not exists tax_rules_set_by on public.tax_rules(set_by);
insert into public.tax_rules (key, effective_from, value, label, source) values
  ('vat_rate', '2020-02-01', 0.075, 'VAT rate', 'Finance Act 2019; kept by the Nigeria Tax Act 2025')
on conflict (key, effective_from) do nothing;

create or replace function private.vat_rate(p_day date) returns numeric
language sql stable security definer set search_path = public, private as $$
  select coalesce(private.tax_rule('vat_rate', coalesce(p_day, current_date)), 0.075)
$$;
-- The rate for screens and the edge functions.
create or replace function public.current_vat_rate(p_day date default null) returns numeric
language sql stable security definer set search_path = public, private as $$
  select private.vat_rate(coalesce(p_day, (now() at time zone 'Africa/Lagos')::date))
$$;
alter table public.wht_rates add column if not exists updated_by uuid references auth.users(id) on delete set null;
alter table public.wht_rates add column if not exists updated_at timestamptz;
create index if not exists wht_rates_updated_by on public.wht_rates(updated_by);

create or replace function public.admin_tax() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_today date := (now() at time zone 'Africa/Lagos')::date;
begin
  perform private.require_staff();
  return jsonb_build_object(
    'rules', (select coalesce(jsonb_agg(jsonb_build_object('key', k.key, 'label', k.label, 'source', k.source, 'current', private.tax_rule(k.key, v_today),
        'history', (select jsonb_agg(jsonb_build_object('from', r.effective_from, 'value', r.value, 'source', r.source, 'set_at', r.set_at,
            'set_by', (select email from auth.users u where u.id = r.set_by), 'removable', r.set_by is not null) order by r.effective_from desc)
          from tax_rules r where r.key = k.key)) order by k.ord, k.key), '[]'::jsonb)
      from (select distinct on (key) key, label, source,
              case when key = 'vat_rate' then 0 when key like 'ca_rate:%' then 2 else 1 end ord
            from tax_rules order by key, effective_from desc) k),
    'wht', (select coalesce(jsonb_agg(jsonb_build_object('code', w.code, 'name', w.name, 'company', w.rate_company, 'individual', w.rate_individual,
        'note', w.note, 'updated_at', w.updated_at, 'updated_by', (select email from auth.users u where u.id = w.updated_by)) order by w.sort), '[]'::jsonb) from wht_rates w),
    'today', v_today);
end $$;

-- Sets a rule from a day. A rate is a fraction (0.075 for 7.5%); thresholds are naira.
create or replace function public.admin_set_tax_rule(p_key text, p_from date, p_value numeric, p_source text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.tax_rules; v_old numeric;
begin
  perform private.require_staff();
  select * into r from tax_rules where key = p_key order by effective_from desc limit 1;
  if not found then raise exception 'Unknown rule.'; end if;
  if p_from is null or p_from < date '2020-01-01' or p_from > (now() at time zone 'Africa/Lagos')::date + 3660 then raise exception 'Choose the day the rule starts.'; end if;
  if p_value is null or p_value < 0 then raise exception 'Enter a value of 0 or more.'; end if;
  if (p_key like '%rate%' or p_key like '%cap' or p_key in ('ca_retention', 'ca_restriction')) and p_value > 1 then
    raise exception 'Rates are fractions: 0.075 for 7.5%%.';
  end if;
  if p_key = 'vat_rate' and (p_value <= 0 or p_value > 0.5) then raise exception 'The VAT rate must be above 0%% and at most 50%%.'; end if;
  select value into v_old from tax_rules where key = p_key and effective_from = p_from;
  insert into tax_rules (key, effective_from, value, label, source, set_by, set_at)
  values (p_key, p_from, p_value, r.label, coalesce(nullif(trim(p_source), ''), 'Set by TaxStreem in the admin portal'), auth.uid(), now())
  on conflict (key, effective_from) do update set value = excluded.value, source = excluded.source, set_by = excluded.set_by, set_at = excluded.set_at;
  perform private.audit('set_tax_rule', p_key, jsonb_build_object('from', p_from, 'value', p_value, 'was', v_old));
  return jsonb_build_object('key', p_key, 'from', p_from, 'value', p_value);
end $$;

-- Removes a dated rule added in the portal. The rule book's own rules stay.
create or replace function public.admin_remove_tax_rule(p_key text, p_from date) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.tax_rules;
begin
  perform private.require_staff();
  select * into r from tax_rules where key = p_key and effective_from = p_from;
  if not found then raise exception 'Rule not found.'; end if;
  if r.set_by is null then raise exception 'This rule comes from the law Counta was built on. Add a new rule from a later day instead.'; end if;
  if (select count(*) from tax_rules where key = p_key) <= 1 then raise exception 'Keep at least one rule.'; end if;
  delete from tax_rules where key = p_key and effective_from = p_from;
  perform private.audit('remove_tax_rule', p_key, jsonb_build_object('from', p_from, 'value', r.value));
  return jsonb_build_object('key', p_key, 'removed', p_from);
end $$;

-- Withholding tax rates by kind of payment. A change applies to bills recorded from now on.
create or replace function public.admin_set_wht_rate(p_code text, p_company numeric, p_individual numeric) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare w public.wht_rates;
begin
  perform private.require_staff();
  select * into w from wht_rates where code = p_code;
  if not found then raise exception 'Unknown withholding tax category.'; end if;
  if p_code = 'none' then raise exception 'No withholding tax stays at 0.'; end if;
  if p_company is null or p_individual is null or p_company < 0 or p_individual < 0 or p_company > 0.5 or p_individual > 0.5 then
    raise exception 'Rates are fractions from 0 to 0.5: 0.05 for 5%%.';
  end if;
  update wht_rates set rate_company = p_company, rate_individual = p_individual, updated_by = auth.uid(), updated_at = now() where code = p_code;
  perform private.audit('set_wht_rate', p_code, jsonb_build_object('company', p_company, 'individual', p_individual,
    'was', jsonb_build_object('company', w.rate_company, 'individual', w.rate_individual)));
  return jsonb_build_object('code', p_code, 'company', p_company, 'individual', p_individual);
end $$;

-- ---------------------------------------------------------------------------
-- 7. Businesses, people, activity and the portal's own team
-- ---------------------------------------------------------------------------
-- What has gone wrong lately, across every business: one row per failure, newest first.
create or replace function private.platform_failures(p_since timestamptz, p_org uuid default null, p_limit int default 100) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(f order by (f->>'at') desc), '[]'::jsonb) from (
    select f from (
      select jsonb_build_object('at', m.updated_at, 'kind', 'message', 'what', initcap(m.channel) || ' ' || m.template, 'org_id', m.org_id, 'business', o.name,
               'error', left(coalesce(m.error, 'Failed'), 300)) f
      from messages m join orgs o on o.id = m.org_id where m.status = 'failed' and m.updated_at >= p_since and (p_org is null or m.org_id = p_org)
      union all
      select jsonb_build_object('at', coalesce(c.ended_at, c.created_at), 'kind', 'call', 'what', replace(c.kind, '_', ' ') || ' call', 'org_id', c.org_id, 'business', o.name,
               'error', left(coalesce(c.error, 'The call failed'), 300))
      from voice_calls c left join orgs o on o.id = c.org_id where c.status = 'failed' and c.created_at >= p_since and (p_org is null or c.org_id = p_org)
      union all
      select jsonb_build_object('at', p.created_at, 'kind', 'payout', 'what', 'Payout of ₦' || to_char(p.amount, 'FM999,999,999,990.00'), 'org_id', p.org_id, 'business', o.name,
               'error', left(coalesce(p.error, 'The payout failed'), 300))
      from payouts p join orgs o on o.id = p.org_id where p.status in ('failed', 'reversed') and p.created_at >= p_since and (p_org is null or p.org_id = p_org)
      union all
      select jsonb_build_object('at', r.created_at, 'kind', 'payment', 'what', 'Payment request of ₦' || to_char(r.amount, 'FM999,999,999,990.00'), 'org_id', r.org_id, 'business', o.name,
               'error', left(coalesce(r.error, 'Could not be created'), 300))
      from payment_requests r join orgs o on o.id = r.org_id where r.status = 'failed' and r.created_at >= p_since and (p_org is null or r.org_id = p_org)
      union all
      select jsonb_build_object('at', w.created_at, 'kind', 'wallet', 'what', 'Wallet on ' || w.rail, 'org_id', w.org_id, 'business', o.name,
               'error', left(coalesce(w.error, 'Could not be opened'), 300))
      from wallets w join orgs o on o.id = w.org_id where w.status = 'failed' and w.created_at >= p_since and (p_org is null or w.org_id = p_org)
      union all
      select jsonb_build_object('at', e.received_at, 'kind', 'webhook', 'what', e.rail || ' ' || coalesce(e.event, 'event'), 'org_id', e.org_id, 'business', o.name,
               'error', left(e.error, 300))
      from payment_events e left join orgs o on o.id = e.org_id where e.error is not null and e.received_at >= p_since and (p_org is null or e.org_id = p_org)
      union all
      select jsonb_build_object('at', r.created_at, 'kind', 'ai', 'what', 'Reading invoice ' || r.ref, 'org_id', r.org_id, 'business', o.name,
               'error', left(r.ai_error, 300))
      from receipts r join orgs o on o.id = r.org_id where r.ai_error is not null and r.created_at >= p_since and (p_org is null or r.org_id = p_org)
      union all
      select jsonb_build_object('at', a.started_at, 'kind', 'books', 'what', a.agent || ' ' || a.action, 'org_id', a.org_id, 'business', o.name,
               'error', left(a.error, 300))
      from agent_runs a left join orgs o on o.id = a.org_id where a.error is not null and a.started_at >= p_since and (p_org is null or a.org_id = p_org)
    ) x order by (f->>'at') desc limit greatest(1, least(p_limit, 500))
  ) y
$$;

create or replace function public.admin_overview() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_day timestamptz := now() - interval '1 day'; v_week timestamptz := now() - interval '7 days';
begin
  perform private.require_staff(false);
  return jsonb_build_object(
    'admin', private.is_admin(),
    'reviews', (select count(*) from orgs where identity_status = 'review'),
    'businesses', case when private.is_admin() then (select jsonb_build_object('total', count(*) filter (where not is_sample), 'week', count(*) filter (where not is_sample and created_at >= v_week),
        'locked', count(*) filter (where not is_sample and identity_status in ('pending', 'review', 'rejected'))) from orgs) end,
    'people', case when private.is_admin() then (select jsonb_build_object('total', count(*), 'week', count(*) filter (where created_at >= v_week)) from auth.users) end,
    'failures_day', case when private.is_admin() then jsonb_array_length(private.platform_failures(v_day, null, 500)) end,
    'paused', case when private.is_admin() then (select coalesce(jsonb_agg(key), '[]'::jsonb) from jsonb_each(private.setting('switches')) where value = 'false'::jsonb) end,
    'business_overrides', case when private.is_admin() then (select count(*) from org_switches) end);
end $$;

create or replace function public.admin_businesses(p_search text default null, p_filter text default 'all', p_limit int default 50, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_q text := nullif(trim(coalesce(p_search, '')), ''); v_rows jsonb; v_total int;
begin
  perform private.require_staff();
  with base as (
    select o.* from orgs o
    where (v_q is null or o.name ilike '%' || v_q || '%' or o.rc_number ilike '%' || v_q || '%' or o.id::text = v_q
           or exists (select 1 from members mb left join auth.users u on u.id = mb.user_id where mb.org_id = o.id
                      and (coalesce(mb.email, u.email) ilike '%' || v_q || '%' or mb.display_name ilike '%' || v_q || '%')))
      and case coalesce(p_filter, 'all')
            when 'review' then o.identity_status = 'review'
            when 'locked' then o.identity_status in ('pending', 'review', 'rejected')
            when 'paused' then exists (select 1 from org_switches s where s.org_id = o.id and not s.enabled)
            when 'sample' then o.is_sample
            else v_q is not null or not o.is_sample end)
  select count(*)::int, coalesce((select jsonb_agg(r order by (r->>'created_at') desc) from (
      select jsonb_build_object('id', b.id, 'name', b.name, 'rc_number', b.rc_number, 'created_at', b.created_at, 'is_sample', b.is_sample,
        'identity_status', b.identity_status, 'offering', b.offering, 'industry', b.industry,
        'owner', (select jsonb_build_object('name', mb.display_name, 'email', coalesce(mb.email, u.email)) from members mb left join auth.users u on u.id = mb.user_id
                  where mb.org_id = b.id and mb.role = 'owner' order by mb.created_at limit 1),
        'people', (select count(*) from members mb where mb.org_id = b.id and mb.status = 'active'),
        'paused', (select coalesce(jsonb_agg(s.feature), '[]'::jsonb) from org_switches s where s.org_id = b.id and not s.enabled),
        'last_activity', (select max(j.created_at) from journals j where j.org_id = b.id)) r
      from base b order by b.created_at desc limit greatest(1, least(p_limit, 200)) offset greatest(p_offset, 0)) x), '[]'::jsonb)
  into v_total, v_rows from base;
  return jsonb_build_object('total', v_total, 'rows', v_rows);
end $$;

create or replace function public.admin_business(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; v_owner uuid; v_month timestamptz := now() - interval '30 days'; k text; v_sw jsonb := '[]'::jsonb;
begin
  perform private.require_staff();
  select * into o from orgs where id = p_org;
  if not found then raise exception 'Business not found.'; end if;
  select user_id into v_owner from members where org_id = p_org and role = 'owner' order by created_at limit 1;
  foreach k in array private.feature_keys() loop
    if k <> 'new_businesses' then
      v_sw := v_sw || jsonb_build_object('feature', k, 'on', private.feature_on(p_org, k),
        'override', (select jsonb_build_object('enabled', s.enabled, 'note', s.note, 'at', s.set_at, 'by', (select email from auth.users u where u.id = s.set_by))
                     from org_switches s where s.org_id = p_org and s.feature = k));
    end if;
  end loop;
  return jsonb_build_object(
    'org', jsonb_build_object('id', o.id, 'name', o.name, 'rc_number', o.rc_number, 'legal_form', o.legal_form, 'tin', o.tin, 'industry', o.industry,
      'offering', o.offering, 'category_id', o.category_id, 'email', o.email, 'phone', o.phone, 'address', o.address, 'created_at', o.created_at,
      'is_sample', o.is_sample, 'vat_registered', o.vat_registered, 'payment_rail', o.payment_rail, 'taxstreem_org_id', o.taxstreem_org_id,
      'voice_id', o.voice_id, 'voice_lang', o.voice_lang),
    'identity', jsonb_build_object('status', o.identity_status, 'last4', o.identity->'nin'->>'last4', 'checked_at', o.identity->'nin'->>'at',
      'slip', (o.identity->'slip') is not null, 'review', o.identity->'review', 'attempts', coalesce((o.identity->>'attempts')::int, 0)),
    'people', (select coalesce(jsonb_agg(jsonb_build_object('name', mb.display_name, 'role', mb.role, 'title', mb.title, 'status', mb.status,
        'email', coalesce(mb.email, u.email), 'joined', mb.created_at, 'last_sign_in', u.last_sign_in_at) order by mb.role = 'owner' desc, mb.created_at), '[]'::jsonb)
      from members mb left join auth.users u on u.id = mb.user_id where mb.org_id = p_org),
    'onboarding', case when v_owner is null then null else (select jsonb_build_object('steps', private.guide_steps(v_owner, p_org, coalesce(g.marks, '{}'::jsonb)),
        'last_seen', g.last_seen_at, 'completed', g.completed_at, 'language', g.language) from (select 1) one left join guide_progress g on g.user_id = v_owner) end,
    'wallet', (select jsonb_build_object('status', w.status, 'rail', w.rail, 'bank', w.bank_name, 'account_number', w.account_number, 'error', w.error, 'opened', w.created_at)
      from wallets w where w.org_id = p_org order by w.created_at desc limit 1),
    'payments_open', o.identity_status in ('not_required', 'verified', 'approved') and private.feature_on(p_org, 'payments'),
    'switches', v_sw,
    'usage', jsonb_build_object(
      'sales', (select count(*) from sales where org_id = p_org and created_at >= v_month),
      'messages', (select coalesce(jsonb_object_agg(st, n), '{}'::jsonb) from (select status st, count(*) n from messages where org_id = p_org and created_at >= v_month group by status) x),
      'calls', (select coalesce(jsonb_object_agg(st, n), '{}'::jsonb) from (select status st, count(*) n from voice_calls where org_id = p_org and created_at >= v_month group by status) x),
      'ai_reads', (select count(*) from ai_logs where org_id = p_org and created_at >= v_month),
      'martina', (select count(*) from guide_sessions gs where gs.started_at >= v_month and gs.user_id in (select user_id from members where org_id = p_org and user_id is not null))),
    'failures', private.platform_failures(now() - interval '30 days', p_org, 30));
end $$;

create or replace function public.admin_people(p_search text default null, p_limit int default 50, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_q text := nullif(trim(coalesce(p_search, '')), ''); v_rows jsonb; v_total int;
begin
  perform private.require_staff();
  with base as (
    select u.* from auth.users u
    where v_q is null or u.email ilike '%' || v_q || '%' or coalesce(u.raw_user_meta_data->>'full_name', '') ilike '%' || v_q || '%'
       or exists (select 1 from members mb join orgs o on o.id = mb.org_id where mb.user_id = u.id and o.name ilike '%' || v_q || '%'))
  select count(*)::int, coalesce((select jsonb_agg(r order by (r->>'created_at') desc) from (
      select jsonb_build_object('id', b.id, 'email', b.email, 'name', coalesce(nullif(b.raw_user_meta_data->>'full_name', ''), nullif(b.raw_user_meta_data->>'name', '')),
        'created_at', b.created_at, 'last_sign_in', b.last_sign_in_at, 'confirmed', b.email_confirmed_at is not null,
        'staff', case when exists (select 1 from platform_admins a where a.user_id = b.id) then 'admin'
                      when exists (select 1 from platform_reviewers r where r.user_id = b.id) then 'reviewer' end,
        'authenticator', exists (select 1 from auth.mfa_factors f where f.user_id = b.id and f.status = 'verified'),
        'businesses', (select coalesce(jsonb_agg(jsonb_build_object('org_id', o.id, 'name', o.name, 'role', mb.role, 'status', mb.status, 'sample', o.is_sample)
                         order by o.is_sample, o.name), '[]'::jsonb) from members mb join orgs o on o.id = mb.org_id where mb.user_id = b.id)) r
      from base b order by b.created_at desc limit greatest(1, least(p_limit, 200)) offset greatest(p_offset, 0)) x), '[]'::jsonb)
  into v_total, v_rows from base;
  return jsonb_build_object('total', v_total, 'rows', v_rows);
end $$;

-- How much of each thing happened, and what failed, over the last few days.
create or replace function public.admin_activity(p_days int default 7) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_since timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 90)));
begin
  perform private.require_staff();
  return jsonb_build_object('since', v_since,
    'messages', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (select channel || ':' || status k, count(*) n from messages where created_at >= v_since group by 1) x),
    'calls', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (select kind || ':' || status k, count(*) n from voice_calls where created_at >= v_since group by 1) x),
    'ai', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (
        select k, sum(n) n from (select kind k, count(*) n from ai_logs where created_at >= v_since group by 1
                                 union all select kind, count(*) from kyc_lookups where at >= v_since group by 1) y group by k) x),
    'martina', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (select kind k, count(*) n from guide_sessions where started_at >= v_since group by 1) x),
    'payouts', (select coalesce(jsonb_object_agg(k, jsonb_build_object('count', n, 'amount', a)), '{}'::jsonb)
                from (select status k, count(*) n, sum(amount) a from payouts where created_at >= v_since group by 1) x),
    'payments', (select coalesce(jsonb_object_agg(k, jsonb_build_object('count', n, 'amount', a)), '{}'::jsonb)
                from (select status k, count(*) n, sum(coalesce(paid_amount, amount)) a from payment_requests where created_at >= v_since group by 1) x),
    'signups', (select count(*) from auth.users where created_at >= v_since),
    'businesses', (select count(*) from orgs where created_at >= v_since and not is_sample),
    'failures', private.platform_failures(v_since, null, 200));
end $$;

-- The portal's own team: admins (everything) and reviewers (identity reviews only).
create or replace function public.admin_staff() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_staff();
  return jsonb_build_object(
    'staff', (select coalesce(jsonb_agg(x order by x->>'role', x->>'email'), '[]'::jsonb) from (
        select jsonb_build_object('user_id', u.id, 'email', u.email, 'role', 'admin', 'added_at', a.added_at, 'me', u.id = auth.uid(),
          'authenticator', exists (select 1 from auth.mfa_factors f where f.user_id = u.id and f.status = 'verified')) x
        from platform_admins a join auth.users u on u.id = a.user_id
        union all
        select jsonb_build_object('user_id', u.id, 'email', u.email, 'role', 'reviewer', 'added_at', r.added_at, 'me', u.id = auth.uid(),
          'authenticator', exists (select 1 from auth.mfa_factors f where f.user_id = u.id and f.status = 'verified'))
        from platform_reviewers r join auth.users u on u.id = r.user_id) s),
    'audit', (select coalesce(jsonb_agg(jsonb_build_object('at', a.at, 'email', u.email, 'action', a.action, 'target', a.target, 'detail', a.detail) order by a.at desc), '[]'::jsonb)
      from (select * from admin_audit order by at desc limit 200) a left join auth.users u on u.id = a.user_id));
end $$;

create or replace function public.admin_add_staff(p_email text, p_role text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_user uuid;
begin
  perform private.require_staff();
  if p_role not in ('admin', 'reviewer') then raise exception 'Choose admin or reviewer.'; end if;
  select id into v_user from auth.users where lower(email) = lower(trim(coalesce(p_email, '')));
  if v_user is null then raise exception 'Nobody has signed up to Counta with that email yet. Ask them to create an account first.'; end if;
  if p_role = 'admin' then
    insert into platform_admins (user_id, added_by) values (v_user, auth.uid()) on conflict do nothing;
  else
    insert into platform_reviewers (user_id, added_by) values (v_user, auth.uid()) on conflict do nothing;
  end if;
  perform private.audit('add_staff', lower(trim(p_email)), jsonb_build_object('role', p_role));
  return jsonb_build_object('user_id', v_user, 'role', p_role);
end $$;

create or replace function public.admin_remove_staff(p_user uuid, p_role text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_email text;
begin
  perform private.require_staff();
  select email into v_email from auth.users where id = p_user;
  if p_role = 'admin' then
    if p_user = auth.uid() then raise exception 'Another admin has to remove you.'; end if;
    delete from platform_admins where user_id = p_user;
  elsif p_role = 'reviewer' then
    delete from platform_reviewers where user_id = p_user;
  else raise exception 'Choose admin or reviewer.'; end if;
  perform private.audit('remove_staff', v_email, jsonb_build_object('role', p_role));
  return jsonb_build_object('removed', p_user, 'role', p_role);
end $$;

-- For the admin edge function: the addresses that hear about every key change.
create or replace function public.svc_admin_emails() returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(u.email order by a.added_at), '{}') from platform_admins a join auth.users u on u.id = a.user_id where u.email is not null
$$;
revoke all on function public.svc_admin_emails() from public, anon, authenticated;
grant execute on function public.svc_admin_emails() to service_role;

-- ---------------------------------------------------------------------------
-- 8. Limits and switches where Counta enforces them
-- ---------------------------------------------------------------------------
-- Lookups a person may make in a day, as TaxStreem sets them.
create or replace function public.svc_kyc_take(p_user uuid, p_kind text) returns boolean
language plpgsql security definer set search_path = public, private as $$
declare v_max int;
begin
  v_max := private.limit_of('lookups', p_kind);
  if v_max is null then raise exception 'Unknown lookup.'; end if;
  perform pg_advisory_xact_lock(hashtext('kyc:' || p_user::text));
  if (select count(*) from kyc_lookups where user_id = p_user and kind = p_kind and at > now() - interval '1 day') >= v_max then return false; end if;
  insert into kyc_lookups (user_id, kind) values (p_user, p_kind);
  return true;
end $$;

-- What the Nigerian voices may say in a day, for a business and for one person.
create or replace function public.svc_tts_take(p_subject text, p_chars int, p_cached boolean) returns boolean
language plpgsql security definer set search_path = public, private as $$
declare v_day date := (now() at time zone 'Africa/Lagos')::date; u public.tts_usage; v_max_p int; v_max_c int;
begin
  if p_subject !~ '^(org|user):[0-9a-f-]{36}$' then raise exception 'Unknown subject.'; end if;
  v_max_p := case when p_subject like 'org:%' then private.limit_of('voice_org_phrases') else private.limit_of('voice_user_phrases') end;
  v_max_c := case when p_subject like 'org:%' then private.limit_of('voice_org_chars') else private.limit_of('voice_user_chars') end;
  insert into tts_usage (subject, day) values (p_subject, v_day) on conflict do nothing;
  select * into u from tts_usage where subject = p_subject and day = v_day for update;
  if u.phrases + 1 > v_max_p or (not p_cached and u.chars + greatest(p_chars, 0) > v_max_c) then return false; end if;
  update tts_usage set phrases = phrases + 1, chars = chars + case when p_cached then 0 else greatest(p_chars, 0) end
  where subject = p_subject and day = v_day;
  return true;
end $$;

-- Conversations with Martina a person may start in a day and a week.
create or replace function public.svc_guide_session(p_user uuid, p_conversation text default null, p_kind text default 'guide') returns uuid
language plpgsql security definer set search_path = public, private as $$
declare v_id uuid; v_kind text := case when p_kind = 'assistant' then 'assistant' else 'guide' end;
  v_day int := private.limit_of(case when p_kind = 'assistant' then 'assistant_day' else 'guide_day' end);
  v_week int := private.limit_of(case when p_kind = 'assistant' then 'assistant_week' else 'guide_week' end);
begin
  perform pg_advisory_xact_lock(hashtext('guide:' || p_user::text));
  if (select count(*) from guide_sessions where user_id = p_user and kind = v_kind and started_at > now() - interval '1 day') >= v_day
     or (select count(*) from guide_sessions where user_id = p_user and kind = v_kind and started_at > now() - interval '7 days') >= v_week then
    return null;
  end if;
  insert into guide_sessions (user_id, conversation_id, kind) values (p_user, nullif(p_conversation, ''), v_kind) returning id into v_id;
  return v_id;
end $$;

-- Payments wait while TaxStreem has paused them for the business, as well as until a director is confirmed.
create or replace function private.require_payments_open(p_org uuid) returns void
language plpgsql stable security definer set search_path = public, private as $$
declare v_status text;
begin
  if not private.feature_on(p_org, 'payments') then
    raise exception 'TaxStreem has paused payments for this business for now. The books still work; contact TaxStreem to find out more.' using errcode = '42501';
  end if;
  select identity_status into v_status from orgs where id = p_org;
  if v_status in ('not_required', 'verified', 'approved') then return; end if;
  raise exception '%', case v_status
    when 'review' then 'Payments open once TaxStreem has checked the NIN slip. This usually takes a working day.'
    when 'rejected' then 'Payments are locked: TaxStreem could not confirm a director''s identity. A director can do the NIN check in Settings.'
    else 'Payments open once a director confirms their NIN. Do the NIN check in Settings, Business identity, or ask Martina.' end
    using errcode = '42501';
end $$;

-- Spoken announcements stay quiet while TaxStreem has paused them.
create or replace function public.voice_say(p_org uuid, p_kind text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs; r public.payment_requests; i public.items; v_qty numeric; v_amount numeric; v_vars jsonb;
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  case p_kind
    when 'payment_received' then
      select * into r from payment_requests where id = nullif(p->>'request_id', '')::uuid and org_id = p_org;
      if r.id is null then raise exception 'Payment not found.'; end if;
      if r.status <> 'paid' then raise exception 'That payment has not arrived yet.'; end if;
      v_vars := jsonb_build_object('amount', coalesce(r.paid_amount, r.amount),
        'payer', left(coalesce(nullif(trim(r.payer->>'name'), ''), ''), 60));
    when 'sale_recorded' then
      select * into i from items where id = nullif(p->>'item_id', '')::uuid and org_id = p_org;
      if i.id is null then raise exception 'Item not found.'; end if;
      begin
        v_qty := (p->>'qty')::numeric; v_amount := coalesce((p->>'amount')::numeric, 0);
      exception when others then raise exception 'Quantity and amount must be numbers.';
      end;
      if v_qty is null or v_qty <= 0 or v_qty > 1000000 or v_amount < 0 or v_amount > 10000000000 then
        raise exception 'Quantity and amount are out of range.';
      end if;
      v_vars := jsonb_build_object('item', left(i.name, 80), 'unit', i.selling_unit, 'qty', v_qty, 'amount', v_amount);
    when 'payment_demo' then
      v_vars := jsonb_build_object('amount', 15000, 'payer', 'Chidi Okafor');
    else raise exception 'Unknown announcement.';
  end case;
  return jsonb_build_object('kind', p_kind, 'business', o.name, 'voice_id', o.voice_id, 'lang', o.voice_lang,
    'offering', coalesce(o.offering, 'goods'), 'enabled', private.feature_on(p_org, 'payment_voice') and (p_kind = 'payment_demo' or coalesce((o.voice_events->>p_kind)::boolean, true)), 'vars', v_vars);
end $$;

-- Onboarding follow-up calls wait while phone calls are paused.
create or replace function public.svc_guide_followups_due(p_limit int default 10, p_at timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare g public.guide_progress; v_out jsonb := '[]'::jsonb; v_state jsonb; v_vars jsonb; v_id uuid; v_name text; v_org public.orgs; v_step text;
begin
  for g in select * from private.guide_due(p_at) order by last_seen_at limit greatest(1, least(p_limit, 25)) loop
    perform 1 from guide_progress where user_id = g.user_id and followup_status in ('none', 'no_answer') for update skip locked;
    if not found then continue; end if;
    select * into v_org from orgs where id = g.org_id;
    if not private.feature_on(g.org_id, 'phone_calls') then continue; end if;
    select coalesce(nullif(trim(raw_user_meta_data->>'full_name'), ''), nullif(trim(raw_user_meta_data->>'name'), ''), '') into v_name from auth.users where id = g.user_id;
    v_state := private.guide_steps(g.user_id, g.org_id, g.marks);
    select s->>'id' into v_step from jsonb_array_elements(v_state) with ordinality t(s, ord)
    where not (s->>'done')::boolean and not (s->>'skipped')::boolean order by ord limit 1;
    v_vars := jsonb_build_object(
      'first_name', coalesce(nullif(split_part(v_name, ' ', 1), ''), 'there'),
      'business_name', coalesce(v_org.name, 'your business'),
      'has_business', case when v_org.id is null then 'no' else 'yes' end,
      'next_step', case v_step when 'find_business' then 'finding the business on CAC' when 'questions' then 'answering a few questions about the business'
        when 'submitted' then 'checking and submitting the business profile' when 'cac_document' then 'uploading the CAC status report'
        when 'account_number' then 'getting the business account number' when 'voice' then 'choosing the voice that announces payments'
        when 'first_sale' then 'recording the first sale' when 'bank_connect' then 'connecting the bank account'
        when 'bank_statement' then 'uploading a bank statement' when 'products' then 'adding the first products'
        when 'identity' then 'confirming a director''s NIN' when 'team' then 'inviting the team' else 'finishing setup' end,
      'steps_done', (select count(*) from jsonb_array_elements(v_state) s where (s->>'done')::boolean or (s->>'skipped')::boolean),
      'steps_total', jsonb_array_length(v_state),
      'language_style', case when g.language = 'pcm' then 'pidgin' else 'english' end);
    insert into voice_calls (org_id, user_id, kind, to_number, variables)
    values (g.org_id, g.user_id, 'guide_followup', g.call_phone, v_vars) returning id into v_id;
    update guide_progress set followup_status = 'calling', followup_attempts = followup_attempts + 1, followup_last_at = p_at where user_id = g.user_id;
    v_out := v_out || jsonb_build_object('call_id', v_id, 'to_number', g.call_phone, 'variables', v_vars, 'org_id', g.org_id,
      'voice_id', v_org.voice_id, 'lang', g.language);
  end loop;
  return v_out;
end $$;

-- Identity decisions go in the portal's record too.
create or replace function public.review_identity(p_org uuid, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs;
begin
  if not private.is_reviewer() then raise exception 'Only TaxStreem reviewers decide this.' using errcode = '42501'; end if;
  select * into o from orgs where id = p_org for update;
  if not found then raise exception 'Business not found.'; end if;
  if o.identity_status not in ('review', 'approved', 'rejected') then raise exception 'There is nothing to review for %.', o.name; end if;
  if not p_approve and length(trim(coalesce(p_note, ''))) < 5 then raise exception 'Say why, so the business knows what to do next.'; end if;
  update orgs set identity_status = case when p_approve then 'approved' else 'rejected' end,
    identity = identity || jsonb_build_object('review', jsonb_build_object('approved', p_approve, 'note', nullif(left(trim(coalesce(p_note, '')), 500), ''),
      'at', now(), 'by', auth.uid()))
  where id = p_org;
  perform private.audit('review_identity', p_org::text, jsonb_build_object('approved', p_approve, 'note', nullif(trim(coalesce(p_note, '')), '')));
  perform private.notify_perm(p_org, 'owner', 'identity', case when p_approve then 'Payments are open' else 'We could not confirm the NIN slip' end,
    case when p_approve then 'TaxStreem confirmed the director''s identity. Your wallet, payment links and payouts are ready.'
      else coalesce(nullif(trim(p_note), ''), 'Check the NIN slip and try again.') end, '/settings#identity', 'identity-' || p_org);
  return jsonb_build_object('status', case when p_approve then 'approved' else 'rejected' end);
end $$;


-- ---------------------------------------------------------------------------
-- 9. The VAT rate from the rule book, on the day each calculation is about
-- ---------------------------------------------------------------------------
create or replace function private.bill_wht(p_bill uuid) returns public.bills
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; o public.orgs; v public.vendors; pf jsonb; l record; v_cat text; r public.wht_rates; v_rate numeric; v_base numeric; v_wht numeric;
  v_small boolean := false; v_notes text[] := '{}'; v_rc numeric; v_month numeric; v_note text; v_doubled boolean := false; v_no_state boolean := false;
begin
  select * into b from bills where id = p_bill for update;
  select * into o from orgs where id = b.org_id;
  select * into v from vendors where id = b.vendor_id;
  pf := private.vendor_wht_profile(v.id);
  -- A small business need not withhold from a supplier with a Tax ID while the month's purchases from them stay within ₦2 million.
  if o.wht_small_company and (pf->>'has_tin')::boolean then
    select coalesce(sum(subtotal), 0) into v_month from bills where org_id = b.org_id and vendor_id = b.vendor_id and status <> 'void'
      and date_trunc('month', bill_date) = date_trunc('month', b.bill_date);
    v_small := v_month <= 2000000;
  end if;
  for l in select * from bill_lines where bill_id = b.id order by line_no loop
    v_cat := coalesce(l.wht_category, b.wht_category, v.wht_category, 'none');
    select * into r from wht_rates where code = v_cat;
    v_rate := 0; v_base := l.net; v_note := null;
    if r.code is null or r.exemption then
      v_note := case when r.code is not null and r.code <> 'none' then r.name end;
    elsif (pf->>'exempt')::boolean then
      v_note := 'Supplier exempt from withholding tax';
    elsif v_cat = 'goods' and v.is_manufacturer then
      v_note := 'Goods made by the supplier itself are not subject to WHT';
    elsif v_cat = 'compensation' then
      v_base := greatest(l.net - 50000000, 0); v_rate := 0.05;
      v_note := '5% of the amount above ₦50 million';
    else
      v_rate := private.wht_matrix_rate(v_cat, (pf->>'corporate')::boolean, (pf->>'resident')::boolean);
      if v_rate is null then
        v_rate := 0; v_note := r.name || ': not withheld from ' || case when (pf->>'corporate')::boolean then 'a company' else 'this supplier' end
          || case when not (pf->>'resident')::boolean then ' abroad' else '' end;
      elsif not (pf->>'has_tin')::boolean and v_rate > 0 then
        v_rate := v_rate * 2; v_doubled := true;
      end if;
    end if;
    if v_small and v_rate > 0 and v_cat <> 'compensation' then v_rate := 0; v_note := 'Within the ₦2 million monthly limit for a small business'; end if;
    v_wht := round(v_base * v_rate, 2);
    if v_wht > 0 and (pf->>'state_missing')::boolean and (v_cat = 'compensation' or (not (pf->>'corporate')::boolean and (pf->>'resident')::boolean)) then
      v_no_state := true;
    end if;
    -- VAT self-charged on services bought from a supplier abroad (goods pay VAT at the port).
    v_rc := case when not (pf->>'resident')::boolean and not v.digital_supplier and l.vat = 0 and l.vat_treatment not in ('exempt', 'zero')
                   and l.account_code !~ '^(12|15)' then round(l.net * private.vat_rate(b.bill_date), 2) else 0 end;
    update bill_lines set wht_category = coalesce(wht_category, case when v_cat <> coalesce(b.wht_category, 'none') then v_cat end),
      wht_rate = v_rate, wht = v_wht, wht_base = case when v_wht > 0 then v_base else 0 end, reverse_charge_vat = v_rc
    where id = l.id;
    if v_note is not null and not v_note = any(v_notes) then v_notes := v_notes || v_note; end if;
  end loop;
  if v_doubled then v_notes := array['No Tax ID: the rate is doubled'] || v_notes; end if;
  if v_no_state then v_notes := array['The supplier''s state is not known, and its WHT goes to a state revenue service'] || v_notes; end if;
  update bills set
    wht_expected = (select coalesce(sum(wht), 0) from bill_lines where bill_id = b.id),
    wht_rate = case when subtotal > 0 then least(round((select coalesce(sum(wht), 0) from bill_lines where bill_id = b.id) / subtotal, 4), 0.99) else 0 end,
    wvat_expected = case when o.wvat_agent is not null and (pf->>'resident')::boolean then vat_total else 0 end,
    reverse_charge_vat = (select coalesce(sum(reverse_charge_vat), 0) from bill_lines where bill_id = b.id),
    wht_note = nullif(array_to_string(v_notes, '. '), '')
  where id = b.id returning * into b;
  return b;
end $$;

create or replace function private.post_bill(p_bill uuid, m public.members) returns public.bills
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; l public.bill_lines; v_jl jsonb := '[]'::jsonb; j public.journals; v_vat numeric := 0; v_vendor text; v_at timestamptz; v_rc_base numeric := 0;
begin
  select * into b from bills where id = p_bill for update;
  if b.journal_id is not null then return b; end if;
  select name into v_vendor from vendors where id = b.vendor_id;
  if coalesce((private.bill_tax_flags(b.id)->>'missing_state')::boolean, false) then
    raise exception 'Add the state of % first: the withholding tax on % goes to its state revenue service. Or send the bill back to ask for the address.', v_vendor, b.number;
  end if;
  for l in select * from bill_lines where bill_id = b.id order by line_no loop
    v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', l.account_code, 'debit', l.net + case when l.vat_recoverable then 0 else l.vat end,
      'location_id', l.location_id, 'memo', l.description, 'doc_type', 'bill', 'doc_id', b.id));
    if l.vat_recoverable then v_vat := v_vat + l.vat; end if;
    if l.reverse_charge_vat > 0 then
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', case when l.vat_recoverable then private.acct(b.org_id, 'input_vat') else l.account_code end,
        'debit', l.reverse_charge_vat, 'location_id', l.location_id, 'memo', 'VAT self-charged · ' || l.description, 'doc_type', 'bill', 'doc_id', b.id));
      v_rc_base := v_rc_base + l.net;
    end if;
  end loop;
  v_jl := v_jl || jsonb_build_array(
    jsonb_build_object('code', private.acct(b.org_id, 'input_vat'), 'debit', v_vat, 'memo', 'Input VAT · ' || v_vendor, 'doc_type', 'bill', 'doc_id', b.id),
    jsonb_build_object('code', private.acct(b.org_id, 'payables'), 'credit', b.total, 'party_type', 'vendor', 'party_id', b.vendor_id, 'doc_type', 'bill', 'doc_id', b.id,
      'memo', b.number || coalesce(' · ' || b.vendor_ref, '')),
    jsonb_build_object('code', private.acct(b.org_id, 'wvat_payable'), 'credit', b.reverse_charge_vat, 'party_type', 'vendor', 'party_id', b.vendor_id,
      'doc_type', 'bill', 'doc_id', b.id, 'memo', 'VAT self-charged on services from abroad · ' || b.number));
  v_at := private.posting_time(b.org_id, b.bill_date);
  j := private.post_entry(b.org_id, 'Bill ' || b.number || ' · ' || v_vendor || coalesce(' · ' || b.vendor_ref, ''), 'bill', b.id, b.created_by, m.id, v_jl, v_at,
    jsonb_build_object('origin', case when b.source = 'ai' then 'ai' else 'system' end, 'ai_confidence', b.ai_confidence,
      'evidence', jsonb_build_array(jsonb_build_object('type', 'bill', 'id', b.id, 'ref', coalesce(b.vendor_ref, b.number), 'document', b.document_path))));
  update bills set journal_id = j.id, status = 'approved', approved_by = m.id, approved_at = now() where id = b.id returning * into b;
  if b.reverse_charge_vat > 0 then
    insert into wht_deductions (org_id, kind, bill_id, vendor_id, description, recipient_type, resident, beneficiary_type, beneficiary_number, base, rate, amount,
      authority, deducted_on, period, due_date, status, receipt_no)
    select b.org_id, 'reverse_charge', b.id, b.vendor_id, left(b.number || coalesce(' / ' || b.vendor_ref, '') || ': VAT self-charged on services from abroad', 300),
      pf->>'recipient_type', false, pf->>'beneficiary_type', pf->>'beneficiary_number', v_rc_base, private.vat_rate(b.bill_date), b.reverse_charge_vat, 'NRS', b.bill_date,
      date_trunc('month', b.bill_date)::date, private.wht_due('reverse_charge', 'NRS', null, b.bill_date), 'deducted', null
    from (select private.vendor_wht_profile(b.vendor_id) pf) x
    on conflict do nothing;
  end if;
  -- Capital lines become register records waiting for someone to confirm the class, date in use and life (FA-02).
  insert into fixed_assets (org_id, number, name, class_account, cost, life_months, available_date, status, location_id, bill_id, bill_line_id, journal_id, created_by)
  select b.org_id, 'FA-' || lpad(private.next_no(b.org_id, 'FA', 1)::text, 4, '0'), bl.description, bl.account_code,
    bl.net + case when bl.vat_recoverable then 0 else bl.vat end, coalesce(bl.asset_life_months, ac.default_life_months), b.bill_date, 'pending_confirmation',
    bl.location_id, b.id, bl.id, j.id, m.id
  from bill_lines bl join asset_classes ac on ac.cost_account = bl.account_code where bl.bill_id = b.id order by bl.line_no;
  return b;
end $$;

create or replace function private.post_receipt_internal(p_receipt uuid, p_member uuid, p_at timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.receipts; m public.members; l public.receipt_lines; it public.items; v public.vendors; o public.orgs;
  v_bad int; v_net numeric := 0; v_vat_base numeric := 0; v_vat numeric := 0; v_gross numeric; v_line numeric;
  v_vat_t text; v_pack int; v_su_qty numeric; v_cost_su numeric; v_old_last numeric; v_on_hand numeric; v_wac numeric;
  j public.journals; v_item uuid; v_batch uuid; v_new jsonb; v_price numeric; v_props int := 0; v_can_price boolean; v_pid uuid;
  v_memo text; v_acct text; v_amt numeric; v_by_acct jsonb := '{}'::jsonb; v_jl jsonb;
begin
  select * into r from receipts where id = p_receipt for update;
  if not found then raise exception 'Receipt not found.'; end if;
  select * into m from members where id = p_member;
  select * into o from orgs where id = r.org_id;
  if r.status <> 'needs_review' then raise exception 'This receipt is already %.', replace(r.status, '_', ' '); end if;
  if r.location_id is null then raise exception 'Choose the branch receiving this stock.'; end if;
  if r.vendor_id is null and coalesce(trim(r.vendor_name), '') = '' then raise exception 'Choose or name the vendor.'; end if;
  if not exists (select 1 from receipt_lines where receipt_id = r.id) then raise exception 'Add at least one line.'; end if;
  select count(*) into v_bad from receipt_lines
  where receipt_id = r.id and (not confirmed or qty <= 0 or unit_cost <= 0
    or (item_id is null and coalesce(trim(new_item->>'name'), '') = ''));
  if v_bad > 0 then
    raise exception '% line% still need% confirmation before posting.', v_bad,
      case when v_bad > 1 then 's' else '' end, case when v_bad > 1 then '' else 's' end;
  end if;

  if r.vendor_id is null then
    select id into r.vendor_id from vendors where org_id = r.org_id and lower(name) = lower(trim(r.vendor_name)) limit 1;
    if r.vendor_id is null then
      insert into vendors (org_id, name, vat_registered, channel)
      values (r.org_id, trim(r.vendor_name), r.vendor_vat_registered, 'whatsapp') returning id into r.vendor_id;
    end if;
    update receipts set vendor_id = r.vendor_id where id = r.id;
  end if;
  select * into v from vendors where id = r.vendor_id;
  v_can_price := private.perm_of(m, 'edit_prices');

  -- Totals first: the journal must exist before any movement references it.
  for l in select * from receipt_lines where receipt_id = r.id order by line_no loop
    v_line := round(l.qty * l.unit_cost, 2);
    if l.item_id is not null then
      select vat_treatment into v_vat_t from items where id = l.item_id;
      v_acct := private.inv_acct(l.item_id);
    else
      v_vat_t := coalesce(nullif(l.new_item->>'vat_treatment', ''), 'standard');
      v_acct := private.acct(r.org_id, 'inventory');
    end if;
    v_net := v_net + v_line;
    v_by_acct := jsonb_set(v_by_acct, array[v_acct], to_jsonb(coalesce((v_by_acct->>v_acct)::numeric, 0) + v_line));
    if v_vat_t = 'standard' then v_vat_base := v_vat_base + v_line; end if;
  end loop;
  v_vat := case when r.vendor_vat_registered then round(v_vat_base * private.vat_rate(coalesce(r.invoice_date, p_at::date)), 2) else 0 end;
  v_gross := v_net + v_vat;
  v_memo := v.name || coalesce(' · ' || nullif(r.invoice_no, ''), '');

  v_jl := jsonb_build_array(
    jsonb_build_object('code', private.acct(r.org_id, 'purchases'), 'debit', v_net, 'memo', 'Stock bought from ' || v.name),
    jsonb_build_object('code', private.acct(r.org_id, 'input_vat'), 'debit', v_vat, 'memo', 'Input VAT 7.5%'),
    jsonb_build_object('code', private.acct(r.org_id, 'payables'), 'credit', v_gross, 'memo', 'Payable to ' || v.name));
  for v_acct, v_amt in select key, value::numeric from jsonb_each_text(v_by_acct) order by key loop
    v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', v_acct, 'debit', v_amt, 'location_id', r.location_id, 'memo', 'Stock received'));
  end loop;
  v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(r.org_id, 'inventory_movement'), 'credit', v_net,
    'location_id', r.location_id, 'memo', 'Purchases moved into stock'));
  j := private.post_journal(r.org_id, v_memo, 'receipt', r.id, m.id, null, v_jl, p_at);

  for l in select * from receipt_lines where receipt_id = r.id order by line_no loop
    v_item := l.item_id;
    if v_item is null then
      v_new := l.new_item;
      v_pack := greatest(1, coalesce(nullif(v_new->>'pack_size', '')::numeric, 1)::int);
      v_cost_su := l.unit_cost / case when l.unit_kind = 'purchase' then v_pack else 1 end;
      v_price := nullif(v_new->>'price', '')::numeric;
      if not v_can_price or v_price is null or v_price <= 0 then
        v_price := private.round_price(v_cost_su * 1.15);
      end if;
      insert into items (org_id, name, category, vat_treatment, purchase_unit, pack_size, selling_unit, informal_unit, track_batches,
        preferred_vendor_id, price, needs_review, created_by, barcode)
      values (r.org_id, trim(v_new->>'name'), coalesce(nullif(trim(v_new->>'category'), ''), 'General'),
        coalesce(nullif(v_new->>'vat_treatment', ''), 'standard'), coalesce(nullif(trim(v_new->>'purchase_unit'), ''), 'Carton'), v_pack,
        coalesce(nullif(trim(v_new->>'selling_unit'), ''), 'piece'),
        coalesce(nullif(trim(v_new->>'selling_unit'), ''), 'piece') in ('derica', 'mudu', 'paint bucket'),
        coalesce((v_new->>'track_batches')::boolean, false), r.vendor_id, v_price,
        not coalesce(v_can_price and nullif(v_new->>'price', '')::numeric > 0, false), m.id,
        case when nullif(trim(v_new->>'barcode'), '') is not null
              and not exists (select 1 from items where org_id = r.org_id and barcode = trim(v_new->>'barcode'))
             then trim(v_new->>'barcode') end)
      returning id into v_item;
      insert into item_costs (item_id, org_id, wac) values (v_item, r.org_id, 0);
      update receipt_lines set item_id = v_item where id = l.id;
    end if;

    select * into it from items where id = v_item;
    v_pack := it.pack_size;
    v_su_qty := l.qty * case when l.unit_kind = 'purchase' then v_pack else 1 end;
    v_cost_su := round(l.unit_cost / case when l.unit_kind = 'purchase' then v_pack else 1 end, 4);

    -- Weighted average cost, recalculated on every receipt.
    select coalesce(sum(qty), 0) into v_on_hand from stock_levels where item_id = v_item;
    select wac, last_cost into v_wac, v_old_last from item_costs where item_id = v_item for update;
    if v_on_hand <= 0 or coalesce(v_wac, 0) = 0 then v_wac := v_cost_su;
    else v_wac := round((v_on_hand * v_wac + v_su_qty * v_cost_su) / (v_on_hand + v_su_qty), 4); end if;
    update item_costs set wac = v_wac, last_cost = v_cost_su, replacement_cost = v_cost_su,
      replacement_source = j.ref || ' · ' || v.name, updated_at = now()
    where item_id = v_item;

    v_batch := null;
    if it.track_batches then
      insert into batches (org_id, item_id, location_id, batch_no, expiry_date, qty_received, qty_remaining, receipt_id, created_at)
      values (r.org_id, v_item, r.location_id, coalesce(nullif(trim(l.batch_no), ''), 'R' || j.je_no || '-' || l.line_no),
        l.expiry_date, v_su_qty, v_su_qty, r.id, p_at)
      returning id into v_batch;
    end if;

    perform private.add_movement(r.org_id, 'receipt', v_item, r.location_id, v_su_qty, v_cost_su, null, j.id, m.id,
      private.channel_for(r.source), p_at,
      jsonb_build_object('receipt_id', r.id, 'batch_id', v_batch, 'device_id', r.device_id, 'offline', r.offline,
        'note', coalesce(l.raw_text, '')));

    if it.preferred_vendor_id is null then update items set preferred_vendor_id = r.vendor_id where id = v_item; end if;

    if v_old_last is not null and v_cost_su > v_old_last + 0.004 then
      v_pid := private.propose_price(v_item, 'cost_increase', v_old_last, v_cost_su,
        j.ref || ' · ' || v.name || ' · ' || to_char(private.local_day(r.org_id, p_at), 'DD Mon'));
      if v_pid is not null then v_props := v_props + 1; end if;
    end if;
  end loop;

  update receipts set status = 'posted', net = v_net, input_vat = v_vat, gross = v_gross, journal_id = j.id, ref = j.ref,
    posted_by = m.id, posted_at = p_at, vendor_id = r.vendor_id
  where id = r.id;
  if r.po_id is not null then
    update purchase_orders set status = 'received', received_at = p_at where id = r.po_id and status = 'sent';
  end if;
  return jsonb_build_object('journal_ref', j.ref, 'net', v_net, 'vat', v_vat, 'gross', v_gross, 'proposals', v_props);
end $$;

create or replace function private.sync_wht_deductions() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; v public.vendors; pf jsonb; v_day date; v_status text; x record; v_tot numeric; v_left numeric; v_left_base numeric; v_n int; v_i int := 0;
  v_amt numeric; v_base numeric; v_auth text; v_desc text;
begin
  if new.status in ('failed', 'reversed') then
    update wht_deductions set status = 'void' where bill_payment_id = new.id and status in ('pending', 'deducted');
    return new;
  end if;
  v_status := case when new.status = 'paid' then 'deducted' else 'pending' end;
  v_day := private.local_day(new.org_id, new.paid_at);
  if exists (select 1 from wht_deductions where bill_payment_id = new.id) then
    update wht_deductions set status = v_status, deducted_on = v_day, period = date_trunc('month', v_day)::date,
      due_date = private.wht_due(kind, authority, category, v_day)
    where bill_payment_id = new.id and status in ('pending', 'deducted');
    return new;
  end if;
  if coalesce(new.wht, 0) = 0 and coalesce(new.wvat, 0) = 0 then return new; end if;
  select * into b from bills where id = new.bill_id;
  select * into v from vendors where id = b.vendor_id;
  pf := private.vendor_wht_profile(v.id);
  v_desc := b.number || coalesce(' / ' || b.vendor_ref, '');
  if new.wht > 0 then
    select coalesce(sum(wht), 0) into v_tot from bill_lines where bill_id = b.id;
    if v_tot = 0 then
      -- Withheld although the bill expected none: on the bill's own category.
      v_base := round(new.gross * b.subtotal / nullif(b.total, 0), 2);
      v_auth := case when (pf->>'corporate')::boolean or not (pf->>'resident')::boolean then 'NRS' else pf->>'state' end;
      insert into wht_deductions (org_id, kind, bill_id, bill_payment_id, vendor_id, category, nrs_code, description, recipient_type, resident, beneficiary_type,
        beneficiary_number, base, rate, doubled, amount, authority, state_missing, deducted_on, period, due_date, status, receipt_no)
      values (b.org_id, 'wht', b.id, new.id, v.id, coalesce(nullif(b.wht_category, 'none'), 'services'), (select nrs_code from wht_rates where code = coalesce(nullif(b.wht_category, 'none'), 'services')),
        left(v_desc || ': ' || (select string_agg(description, '; ' order by line_no) from bill_lines where bill_id = b.id), 300), pf->>'recipient_type',
        (pf->>'resident')::boolean, pf->>'beneficiary_type', pf->>'beneficiary_number', v_base, round(new.wht / nullif(v_base, 0), 4), false, new.wht, v_auth,
        v_auth is null, v_day, date_trunc('month', v_day)::date,
        private.wht_due('wht', v_auth, b.wht_category, v_day), v_status, 'WHT-' || lpad(private.next_no(b.org_id, 'WHTR', 1)::text, 5, '0'));
    else
      -- Spread over the bill's kinds of transaction by their share of the bill's WHT; the last takes the pennies.
      select count(*) into v_n from (select 1 from bill_lines where bill_id = b.id and wht > 0 group by coalesce(wht_category, b.wht_category)) z;
      v_left := new.wht;
      for x in select coalesce(l.wht_category, b.wht_category) cat, sum(l.wht) wht, sum(l.wht_base) base, max(l.wht_rate) rate,
                      string_agg(l.description, '; ' order by l.line_no) descr
               from bill_lines l where l.bill_id = b.id and l.wht > 0 group by 1 order by 2 desc loop
        v_i := v_i + 1;
        v_amt := case when v_i = v_n then v_left else round(new.wht * x.wht / v_tot, 2) end;
        v_left := v_left - v_amt;
        v_base := round(x.base * new.wht / v_tot, 2);
        v_auth := case when x.cat = 'compensation' then pf->>'state'
                       when (pf->>'corporate')::boolean or not (pf->>'resident')::boolean then 'NRS' else pf->>'state' end;
        insert into wht_deductions (org_id, kind, bill_id, bill_payment_id, vendor_id, category, nrs_code, description, recipient_type, resident, beneficiary_type,
          beneficiary_number, base, rate, doubled, amount, authority, state_missing, deducted_on, period, due_date, status, receipt_no)
        values (b.org_id, 'wht', b.id, new.id, v.id, x.cat, (select nrs_code from wht_rates where code = x.cat), left(v_desc || ': ' || x.descr, 300),
          pf->>'recipient_type', (pf->>'resident')::boolean, pf->>'beneficiary_type', pf->>'beneficiary_number', v_base, x.rate,
          not (pf->>'has_tin')::boolean and x.cat <> 'compensation', v_amt, v_auth, v_auth is null,
          v_day, date_trunc('month', v_day)::date, private.wht_due('wht', v_auth, x.cat, v_day), v_status,
          'WHT-' || lpad(private.next_no(b.org_id, 'WHTR', 1)::text, 5, '0'));
      end loop;
    end if;
  end if;
  if new.wvat > 0 then
    insert into wht_deductions (org_id, kind, bill_id, bill_payment_id, vendor_id, description, recipient_type, resident, beneficiary_type, beneficiary_number,
      base, rate, amount, authority, deducted_on, period, due_date, status, receipt_no)
    values (b.org_id, 'wvat', b.id, new.id, v.id, left(v_desc || ': VAT withheld', 300), pf->>'recipient_type', (pf->>'resident')::boolean,
      pf->>'beneficiary_type', pf->>'beneficiary_number', round(new.wvat / private.vat_rate(v_day), 2), private.vat_rate(v_day), new.wvat, 'NRS', v_day, date_trunc('month', v_day)::date,
      private.wht_due('wvat', 'NRS', null, v_day), v_status, 'WHT-' || lpad(private.next_no(b.org_id, 'WHTR', 1)::text, 5, '0'));
  end if;
  return new;
end $$;

create or replace function private.vat_month(p_org uuid, p_month date) returns jsonb
language sql stable security definer set search_path = public, private as $$
  with b as (select date_trunc('month', p_month)::date f, (date_trunc('month', p_month) + interval '1 month' - interval '1 day')::date t),
  so as (select coalesce(sum(case when s.doc_type = 'credit_note' then -l.vat else l.vat end), 0) vat,
                coalesce(sum(case when s.doc_type = 'credit_note' then -l.net else l.net end) filter (where l.vat_treatment = 'standard'), 0) std,
                coalesce(sum(case when s.doc_type = 'credit_note' then -l.net else l.net end) filter (where l.vat_treatment = 'zero'), 0) zero,
                coalesce(sum(case when s.doc_type = 'credit_note' then -l.net else l.net end) filter (where l.vat_treatment = 'exempt'), 0) exempt
         from sales s join sale_lines l on l.sale_id = s.id, b
         where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import' and s.issue_date between b.f and b.t),
  bi as (select coalesce(sum(l.vat) filter (where l.vat_recoverable), 0) vat, coalesce(sum(l.reverse_charge_vat) filter (where l.vat_recoverable), 0) rc
         from bills x join bill_lines l on l.bill_id = x.id, b
         where x.org_id = p_org and x.source not in ('receipt', 'import') and x.journal_id is not null and x.status <> 'void' and x.bill_date between b.f and b.t),
  rc as (select coalesce(sum(input_vat), 0) vat from receipts, b
         where org_id = p_org and status = 'posted' and private.local_day(org_id, coalesce(posted_at, created_at)) between b.f and b.t),
  vc as (select coalesce(sum(vat_total), 0) vat from vendor_credits, b where org_id = p_org and status <> 'void' and journal_id is not null and credit_date between b.f and b.t),
  wv as (select coalesce(sum(amount), 0) vat from collections, b where org_id = p_org and method = 'wvat_credit' and status = 'confirmed' and journal_id is not null
           and private.local_day(org_id, received_at) between b.f and b.t),
  im as (select coalesce(sum(import_vat), 0) vat from customs_entries, b where org_id = p_org and status = 'posted' and entry_date between b.f and b.t),
  wo as (select coalesce(round(sum(x.cost) * private.vat_rate(max(b.t)), 2), 0) vat from b, private.vat_stock_writeoffs(p_org, b.f, b.t) x)
  select jsonb_build_object('period', b.f, 'output', round(so.vat, 2), 'input', round(bi.vat + bi.rc + rc.vat - vc.vat + im.vat - wo.vat, 2), 'reverse_charge', round(bi.rc, 2),
    'import_vat', round(im.vat, 2), 'stock_writeoff_vat', wo.vat,
    'wvat_credit', round(wv.vat, 2), 'standard_sales', so.std, 'zero_rated_sales', so.zero, 'exempt_sales', so.exempt)
  from b, so, bi, rc, vc, wv, im, wo
$$;

create or replace function private.vat_rows(p_org uuid, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = public, private as $$
  with sl as (select s.doc_type, s.export, l.vat_treatment, l.net, l.vat from sales s join sale_lines l on l.sale_id = s.id
              where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import' and s.issue_date between p_from and p_to),
  so as (select coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'standard'), 0) std,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'zero'), 0) zero,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'zero' and export), 0) exports,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'exempt'), 0) exempt,
                coalesce(sum(case when doc_type = 'credit_note' then -vat else vat end), 0) vat from sl),
  bi as (select coalesce(sum(bl.vat) filter (where bl.vat_recoverable), 0) vat, coalesce(sum(bl.net) filter (where bl.vat > 0), 0) base,
                coalesce(sum(bl.reverse_charge_vat) filter (where bl.vat_recoverable), 0) rc, coalesce(sum(bl.net) filter (where bl.reverse_charge_vat > 0), 0) rc_base
         from bills b join bill_lines bl on bl.bill_id = b.id
         where b.org_id = p_org and b.source not in ('receipt', 'import') and b.journal_id is not null and b.status <> 'void' and b.bill_date between p_from and p_to),
  rc as (select coalesce(sum(input_vat), 0) vat, coalesce(sum(net) filter (where input_vat > 0), 0) base from receipts
         where org_id = p_org and status = 'posted' and private.local_day(org_id, coalesce(posted_at, created_at)) between p_from and p_to),
  vcr as (select coalesce(sum(vat_total), 0) vat, coalesce(sum(subtotal) filter (where vat_total > 0), 0) base from vendor_credits
          where org_id = p_org and status <> 'void' and journal_id is not null and credit_date between p_from and p_to),
  wv as (select coalesce(sum(amount), 0) vat from collections where org_id = p_org and method = 'wvat_credit' and status = 'confirmed' and journal_id is not null
           and private.local_day(org_id, received_at) between p_from and p_to),
  im as (select coalesce(sum(import_vat), 0) vat, coalesce(sum(vat_base), 0) base from customs_entries
         where org_id = p_org and status = 'posted' and entry_date between p_from and p_to),
  wo as (select coalesce(round(sum(cost) * private.vat_rate(p_to), 2), 0) vat, coalesce(sum(cost), 0) base from private.vat_stock_writeoffs(p_org, p_from, p_to)),
  led as (select coalesce(sum(mv.cr - mv.dr) filter (where mv.code = '2201'), 0) out_ledger, coalesce(sum(mv.dr - mv.cr) filter (where mv.code = '1402'), 0) in_ledger
          from (select l.account_code code, sum(l.debit) dr, sum(l.credit) cr from journal_lines l join journals j on j.id = l.journal_id
                where l.org_id = p_org and j.entry_date between p_from and p_to and j.source_type in ('sale', 'bill', 'receipt', 'customs_entry') group by 1) mv)
  select jsonb_build_array(
    private.fr('Output VAT', null, null, 'heading', 0),
    private.fr('Standard-rated supplies, status 0 (7.5%)', so.std, null, 'line', 1),
    private.fr('Exempt supplies, status 1', so.exempt, null, 'line', 1),
    private.fr('Zero-rated supplies, status 2', so.zero, null, 'line', 1),
    private.fr('of which exports to customers outside Nigeria', so.exports, null, 'line', 2),
    private.fr('Output VAT charged', so.vat, null, 'subtotal', 0),
    private.fr('Input VAT', null, null, 'heading', 0),
    private.fr('Purchases and expenses on bills (taxable value ' || to_char(bi.base, 'FM999,999,999,990.00') || ')', bi.vat, null, 'line', 1),
    private.fr('VAT self-charged on services from abroad (value ' || to_char(bi.rc_base, 'FM999,999,999,990.00') || ')', bi.rc, null, 'line', 1),
    private.fr('Stock received (taxable value ' || to_char(rc.base, 'FM999,999,999,990.00') || ')', rc.vat, null, 'line', 1),
    private.fr('VAT paid at customs on imports (value ' || to_char(im.base, 'FM999,999,999,990.00') || ')', im.vat, null, 'line', 1),
    private.fr('Less credit notes from suppliers (taxable value ' || to_char(vcr.base, 'FM999,999,999,990.00') || ')', -vcr.vat, null, 'line', 1),
    private.fr('Less VAT on standard-rated stock written off (cost ' || to_char(wo.base, 'FM999,999,999,990.00') || ')', -wo.vat, null, 'line', 1),
    private.fr('Input VAT recoverable', bi.vat + bi.rc + rc.vat + im.vat - vcr.vat - wo.vat, null, 'subtotal', 0),
    private.fr('VAT withheld by customers (credited)', wv.vat, null, 'line', 0),
    private.fr('VAT payable / (credit) for the period, before credit brought forward', so.vat - bi.vat - bi.rc - rc.vat - im.vat + vcr.vat + wo.vat - wv.vat, null, 'total', 0),
    private.fr('Ledger check', null, null, 'heading', 0),
    private.fr('Output VAT in the ledger (2201) from sales', led.out_ledger, null, 'line', 1),
    private.fr('Input VAT in the ledger (1402) from bills, receipts, customs and supplier credit notes', led.in_ledger, null, 'line', 1),
    private.fr('Difference to explain', (so.vat - led.out_ledger) - (bi.vat + bi.rc + rc.vat + im.vat - vcr.vat - led.in_ledger), null, 'subtotal', 0,
      case when wo.vat <> 0 then 'The VAT on stock written off leaves 1402 when the month is filed.' end))
  from so, bi, rc, vcr, wv, im, wo, led
$$;

create or replace function private.vat_schedule(p_org uuid, p_period date) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_f date := date_trunc('month', p_period)::date; v_t date := (date_trunc('month', p_period) + interval '1 month' - interval '1 day')::date;
  v_vr numeric := private.vat_rate((date_trunc('month', p_period) + interval '1 month' - interval '1 day')::date);
  o public.orgs; mn public.locations; a jsonb; b jsonb; c2 jsonb; c2v jsonb; c1 jsonb; d jsonb; e jsonb; f jsonb; checks jsonb := '[]'::jsonb;
  mo jsonb; vp public.vat_periods; v_zs numeric; v_std numeric; v_zero numeric; l jsonb; v_tol numeric; v_lines int; v_net numeric; v_place_state text;
  v_e_place text; v_today date := private.local_day(p_org, now()); rw record;
begin
  select * into o from orgs where id = p_org;
  select * into mn from locations where org_id = p_org order by is_main desc, created_at limit 1;
  mo := private.vat_month(p_org, v_f);
  select * into vp from vat_periods where org_id = p_org and period = v_f;
  v_std := (mo->>'standard_sales')::numeric; v_zero := (mo->>'zero_rated_sales')::numeric;
  v_zs := case when v_std + v_zero > 0 then round(greatest(v_zero, 0) / (v_std + v_zero), 6) else 0 end;

  -- ---- A: every sale line (standard credit notes go to B), by customer, product, VAT status, description and place ----
  create temp table if not exists vat_a_lines (line_id uuid, item_id uuid, description text, treatment text, label text, cust_key text, cname text, ctin text,
    product text, cat int, st text, lga text, place_from text, branch_id uuid, branch_name text, customer_id uuid, c_state text, c_lga text, amount numeric) on commit drop;
  truncate vat_a_lines;
  insert into vat_a_lines
  select l.id, coalesce(l.item_id, ol.item_id), coalesce(ol.description, l.description), l.vat_treatment,
    case when l.vat_treatment = 'standard' then null
      when l.vat_treatment = 'zero' and s.export then case when coalesce(ol.kind, l.kind) = 'service' or i.item_type = 'service' then 'Exported services' else 'Exported goods excluding oil and gas' end
      else coalesce(l.nrs_vat_label, ol.nrs_vat_label, i.nrs_vat_label,
        case when i.id is null then private.nrs_label_guess(l.vat_treatment, coalesce(ol.description, l.description)) end) end,
    case when w.walk_in then 'walkin:' || coalesce(s.location_id, mn.id)::text else 'c:' || coalesce(s.customer_id::text, lower(coalesce(s.customer_name, ''))) end,
    case when w.walk_in then 'Walk-in customers' else coalesce(c.name, s.customer_name, 'Customer') end,
    case when w.walk_in then null else private.vat_tin(coalesce(c.tin, s.customer_tin)) end,
    left(case when coalesce(ol.kind, l.kind) = 'delivery' then 'Delivery' else coalesce(i.name, nullif(trim(coalesce(ol.description, l.description)), ''), 'Sale') end, 120),
    case l.vat_treatment when 'exempt' then 1 when 'zero' then 2 else 0 end,
    case when pc.by_customer then cs.st else br.state end,
    case when pc.by_customer then private.ng_lga(cs.st, c.lga) else br.lga end,
    case when pc.by_customer then 'customer' else 'branch' end,
    br.id, br.name, c.id, c.state, c.lga,
    case when s.doc_type = 'credit_note' then -l.net else l.net end
  -- A credit note's line names the line it credits, so it nets against that product.
  from sales s join sale_lines l on l.sale_id = s.id left join sale_lines ol on ol.id = l.original_line_id
    left join customers c on c.id = s.customer_id left join items i on i.id = coalesce(l.item_id, ol.item_id)
    left join locations br on br.id = coalesce(s.location_id, mn.id)
    cross join lateral (select coalesce(c.is_walk_in, s.customer_id is null and s.channel in ('till', 'voice')) walk_in) w
    -- The customer's state as chosen, else as its address names it.
    cross join lateral (select case when c.id is not null and coalesce(upper(c.country), 'NG') = 'NG'
      then coalesce(private.ng_state(c.state), private.ng_state_of_address(c.address)) end st) cs
    cross join lateral (select not w.walk_in and not coalesce(s.export, false) and cs.st is not null by_customer) pc
  where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import' and s.issue_date between v_f and v_t
    and not (s.doc_type = 'credit_note' and l.vat_treatment = 'standard') and l.net <> 0;

  select coalesce(jsonb_agg(jsonb_build_object('customer', cname, 'tin', ctin, 'product', product, 'category', cat, 'label', label, 'state', st, 'lga', lga,
      'amount', amount, 'place_from', place_from) order by cat, cname, product), '[]'::jsonb)
  into a
  from (select cust_key, cname, ctin, product, cat, label, st, lga, place_from, round(sum(amount), 2) amount from vat_a_lines
        group by cust_key, cname, ctin, product, cat, label, st, lga, place_from having round(sum(amount), 2) <> 0) g;

  -- ---- B: credit notes on standard-rated lines, one row each ----
  select coalesce(jsonb_agg(jsonb_build_object('description', descr, 'tin', ctin, 'customer', cname, 'date', issue_date, 'invoice', inv_no,
      'invoice_amount', inv_amount, 'adjusted', adjusted) order by issue_date, number), '[]'::jsonb)
  into b
  from (select s.number, s.issue_date,
          left('Credit note ' || s.number || coalesce(' against ' || orig.number, '') || coalesce(': ' || nullif(trim(s.notes), ''), ''), 200) descr,
          case when coalesce(c.is_walk_in, false) then null else private.vat_tin(coalesce(c.tin, s.customer_tin)) end ctin,
          case when coalesce(c.is_walk_in, false) then 'Walk-in customers' else coalesce(c.name, s.customer_name, 'Customer') end cname,
          coalesce(orig.number, s.number) inv_no,
          round(coalesce((select sum(ol.net) from sale_lines ol where ol.sale_id = orig.id), sum(l.net)), 2) inv_amount,
          round(sum(l.net), 2) adjusted
        from sales s join sale_lines l on l.sale_id = s.id left join customers c on c.id = s.customer_id left join sales orig on orig.id = s.original_sale_id
        where s.org_id = p_org and s.doc_type = 'credit_note' and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import'
          and s.issue_date between v_f and v_t and l.vat_treatment = 'standard' and l.net <> 0
        group by s.id, s.number, s.issue_date, s.notes, s.customer_tin, s.customer_name, c.is_walk_in, c.tin, c.name, orig.id, orig.number) x;

  -- ---- C_2: standard-rated purchases whose VAT is claimed, by bill (and stock receipt), as goods, services or fixed assets ----
  select coalesce(jsonb_object_agg(kind, rows), '{}'::jsonb) into c2
  from (select kind, jsonb_agg(jsonb_build_object('seller', seller, 'tin', tin, 'description', descr, 'amount', amount, 'ref', ref) order by pday, ref) rows
        from (select private.vat_purchase_kind(bl.account_code, coalesce(bl.wht_category, x.wht_category)) kind, x.bill_date as pday, x.number as ref,
                v.name seller, private.vat_tin(v.tin) tin,
                left(x.number || coalesce(' (their ' || nullif(x.vendor_ref, '') || ')', '') || ': ' || string_agg(distinct coalesce(nullif(trim(bl.description), ''), 'Purchase'), ', '), 200) descr,
                round(sum(bl.net), 2) amount
              from bills x join bill_lines bl on bl.bill_id = x.id join vendors v on v.id = x.vendor_id
              where x.org_id = p_org and x.source not in ('receipt', 'import') and x.journal_id is not null and x.status <> 'void' and x.bill_date between v_f and v_t
                and bl.vat_recoverable and bl.vat > 0
              group by 1, x.id, x.bill_date, x.number, x.vendor_ref, v.name, v.tin
              union all
              select 'goods', private.local_day(r.org_id, coalesce(r.posted_at, r.created_at)), r.ref, coalesce(v.name, r.vendor_name, 'Supplier'), private.vat_tin(v.tin),
                left('Stock received ' || r.ref || coalesce(' (their ' || nullif(r.invoice_no, '') || ')', ''), 200), round(r.input_vat / v_vr, 2)
              from receipts r left join vendors v on v.id = r.vendor_id
              where r.org_id = p_org and r.status = 'posted' and r.input_vat > 0 and private.local_day(r.org_id, coalesce(r.posted_at, r.created_at)) between v_f and v_t) y
        group by kind) z;
  -- Suppliers' credit notes reduce the purchases (the reconciliation column of schedule C).
  select jsonb_build_object('goods', coalesce(sum(n) filter (where kind = 'goods'), 0), 'services', coalesce(sum(n) filter (where kind = 'services'), 0),
      'fixed_assets', coalesce(sum(n) filter (where kind = 'fixed_assets'), 0))
  into c2v
  from (select private.vat_purchase_kind(cl.account_code, ob.wht_category) kind, -round(cl.net, 2) n
        from vendor_credits vc join vendor_credit_lines cl on cl.credit_id = vc.id left join bill_lines ob on ob.id = cl.bill_line_id
        where vc.org_id = p_org and vc.status <> 'void' and vc.journal_id is not null and vc.credit_date between v_f and v_t and cl.vat > 0) q;

  -- ---- C1: standard-rated stock written off (its VAT is taken back), grouped by why ----
  select coalesce(jsonb_agg(jsonb_build_object('description', descr, 'amount', amount, 'zero', round(amount * v_zs, 2)) order by descr), '[]'::jsonb) into c1
  from (select case reason when 'Breakage' then 'Damaged or broken stock written off' when 'Expired' then 'Expired stock written off'
            when 'Theft suspected' then 'Stock lost to theft' when 'Written off' then 'Stock written off' else 'Other stock losses written off' end descr,
          round(sum(cost), 2) amount
        from private.vat_stock_writeoffs(p_org, v_f, v_t) group by 1) w;

  -- ---- D: imports, from the customs entries ----
  select coalesce(jsonb_agg(jsonb_build_object('number', number, 'importer', importer, 'description', left(description || coalesce(' (HS ' || hs_code || ')', ''), 250),
      'vessel', vessel, 'country', country, 'form_m', form_m, 'bill_of_lading', bill_of_lading, 'quantity', quantity, 'currency', currency, 'invoice_value', invoice_value,
      'fx_rate', fx_rate, 'value_ngn', value_ngn, 'other_charges', other_charges, 'total_cost', vat_base, 'import_vat', import_vat) order by entry_date, number), '[]'::jsonb)
  into d
  from customs_entries where org_id = p_org and status = 'posted' and entry_date between v_f and v_t;

  -- ---- E: VAT self-charged on services (and goods) from suppliers abroad, whose VAT is claimed back ----
  v_place_state := coalesce(mn.state, private.ng_state_of_address(coalesce(o.registered_office, o.address)));
  select coalesce(jsonb_agg(jsonb_build_object('name', name, 'tin', tin, 'status', 'Self Charge', 'description', descr,
      'category', case kind when 'goods' then 'VATable Local Goods Purchased (Relating to VATable purchases)'
        when 'fixed_assets' then 'VATable Fixed Assets Purchased Locally (Relating to VATable purchases)'
        else 'VATable Local Services Received (Relating to VATable purchases)' end,
      'place', case when st = 'FCT' then 'Federal Capital Territory' else st end, 'amount', amount) order by name, descr), '[]'::jsonb)
  into e
  from (select v.name, private.vat_tin(v.tin) tin, private.vat_purchase_kind(bl.account_code, coalesce(bl.wht_category, x.wht_category)) kind,
          coalesce(lb.state, v_place_state) st,
          left(x.number || ': ' || string_agg(distinct coalesce(nullif(trim(bl.description), ''), 'Service'), ', '), 200) descr, round(sum(bl.net), 2) amount
        from bills x join bill_lines bl on bl.bill_id = x.id join vendors v on v.id = x.vendor_id left join locations lb on lb.id = bl.location_id
        where x.org_id = p_org and x.source not in ('receipt', 'import') and x.journal_id is not null and x.status <> 'void' and x.bill_date between v_f and v_t
          and bl.vat_recoverable and bl.reverse_charge_vat > 0
        group by v.name, v.tin, 3, 4, x.id, x.number) r;

  -- ---- F: VAT kept by withholding agents (MDAs, banks, oil and gas companies) on what we sold them ----
  select coalesce(jsonb_agg(jsonb_build_object('agent', agent, 'address', address, 'tin', tin, 'nature', nature, 'date', day, 'invoice', invoice,
      'currency', 'NGN', 'invoice_value', value, 'fx_rate', 1, 'value_ngn', value, 'vat', vat) order by day, invoice), '[]'::jsonb)
  into f
  from (select coalesce(cu.name, s.customer_name, 'Customer') agent, left(concat_ws(', ', nullif(trim(cu.address), ''), nullif(trim(cu.city), ''), nullif(trim(cu.state), '')), 250) address,
          private.vat_tin(coalesce(cu.tin, s.customer_tin)) tin,
          case when bool_and(sl.kind = 'service') then 'Supply of services' when bool_or(sl.kind = 'service') then 'Supply of goods and services' else 'Supply of goods' end nature,
          private.local_day(co.org_id, co.received_at) as day, coalesce(s.number, co.number) as invoice, round(co.amount / v_vr, 2) value, co.amount vat
        from collections co left join sales s on s.id = co.sale_id left join customers cu on cu.id = co.customer_id left join sale_lines sl on sl.sale_id = s.id
        where co.org_id = p_org and co.method = 'wvat_credit' and co.status = 'confirmed' and co.journal_id is not null
          and private.local_day(co.org_id, co.received_at) between v_f and v_t
        group by co.id, co.org_id, co.received_at, co.number, co.amount, cu.name, cu.address, cu.city, cu.state, cu.tin, s.customer_name, s.customer_tin, s.number) w;

  -- ---- The form's lines, as the template's formulas work them out ----
  l := jsonb_build_object(
    '10', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(a) r),
    '15', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(a) r where (r->>'category')::int = 1),
    '20', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(a) r where (r->>'category')::int = 2),
    '22', (select coalesce(sum((r->>'adjusted')::numeric), 0) from jsonb_array_elements(b) r),
    '40', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_each(c2) k, jsonb_array_elements(k.value) r)
      + coalesce((c2v->>'goods')::numeric, 0) + coalesce((c2v->>'services')::numeric, 0) + coalesce((c2v->>'fixed_assets')::numeric, 0),
    '45', -(select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(c1) r),
    '85', (select coalesce(sum((r->>'total_cost')::numeric), 0) from jsonb_array_elements(d) r),
    '105_base', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(e) r),
    '110', (select coalesce(sum(round(v_vr * (r->>'value_ngn')::numeric, 10)), 0) from jsonb_array_elements(f) r));
  l := l || jsonb_build_object('25', (l->>'10')::numeric - (l->>'15')::numeric - (l->>'20')::numeric - (l->>'22')::numeric);
  l := l || jsonb_build_object('35', round((l->>'25')::numeric * v_vr, 2), '55', round(((l->>'40')::numeric + (l->>'45')::numeric) * v_vr, 2),
    '90', round((l->>'85')::numeric * v_vr, 2), '105', round((l->>'105_base')::numeric * v_vr, 2));
  l := l || jsonb_build_object('95', (l->>'55')::numeric + (l->>'90')::numeric);
  l := l || jsonb_build_object('100', (l->>'35')::numeric - (l->>'95')::numeric);
  l := l || jsonb_build_object('115', round((l->>'100')::numeric - ((l->>'105')::numeric + (l->>'110')::numeric), 2));

  -- ---- What to fix, and how the return ties to Counta's VAT for the month ----
  v_net := (mo->>'output')::numeric - (mo->>'wvat_credit')::numeric - (mo->>'input')::numeric;
  select count(*) into v_lines from vat_a_lines;
  v_tol := greatest(1, round(0.01 * (v_lines + jsonb_array_length(b) + jsonb_array_length(e) + jsonb_array_length(f)
    + (select count(*) from jsonb_each(c2) k, jsonb_array_elements(k.value) r)), 2));
  if v_t >= v_today then
    checks := checks || jsonb_build_object('severity', 'info', 'code', 'month_open', 'text', 'The month has not ended, so these figures can still change.');
  end if;
  if vp.period is not null and (abs((mo->>'output')::numeric - vp.output_vat) >= 0.01 or abs((mo->>'input')::numeric - vp.input_vat) >= 0.01
     or abs((mo->>'wvat_credit')::numeric - vp.wvat_credit) >= 0.01) then
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'changed_since_filing',
      'text', 'Documents for this month changed after the return was filed. The file shows the books as they are now; reopen the return to file the change.');
  end if;
  -- Places.
  for rw in select branch_id, branch_name, bool_or(st is null) no_state, bool_or(st is not null and lga is null) no_lga, count(*) n
           from vat_a_lines where place_from = 'branch' group by branch_id, branch_name having bool_or(st is null) or bool_or(lga is null) loop
    checks := checks || jsonb_build_object('severity', 'warn', 'code', case when rw.no_state then 'branch_state' else 'branch_lga' end,
      'text', case when rw.branch_id is null then 'The business has no branch with a state. Add the state and local government area of the main branch.'
        else 'Add the ' || case when rw.no_state then 'state and local government area' else 'local government area' end || ' of ' || rw.branch_name
          || ': its sales (and those of customers whose state is not known) are placed there.' end,
      'fix', jsonb_build_object('kind', 'branch', 'id', rw.branch_id, 'name', rw.branch_name));
  end loop;
  for rw in select customer_id, max(cname) cname, max(st) st from vat_a_lines where place_from = 'customer' and lga is null and customer_id is not null group by customer_id
           order by 2 limit 50 loop
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'customer_lga', 'text', 'Add the local government area of ' || rw.cname || ' (' || rw.st || ').',
      'fix', jsonb_build_object('kind', 'customer', 'id', rw.customer_id, 'name', rw.cname, 'state', rw.st));
  end loop;
  for rw in select customer_id, max(cname) cname, max(c_state) c_state from vat_a_lines
           where place_from = 'branch' and customer_id is not null and nullif(trim(c_state), '') is not null and private.ng_state(c_state) is null
             and not cust_key like 'walkin:%'
             and exists (select 1 from customers cc where cc.id = customer_id and coalesce(upper(cc.country), 'NG') = 'NG')
           group by customer_id order by 2 limit 20 loop
    checks := checks || jsonb_build_object('severity', 'info', 'code', 'customer_state', 'text', rw.cname || '''s state "' || rw.c_state
      || '" is not a Nigerian state Counta knows, so the branch''s state is used. Choose it from the list if the customer is in Nigeria.',
      'fix', jsonb_build_object('kind', 'customer', 'id', rw.customer_id, 'name', rw.cname));
  end loop;
  -- Descriptions of exempt and zero-rated supplies.
  for rw in select item_id, coalesce(max(i.name), max(vl.description)) name, max(vl.treatment) treatment, min(vl.line_id::text)::uuid line_id, sum(vl.amount) amount
           from vat_a_lines vl left join items i on i.id = vl.item_id where vl.cat in (1, 2) and vl.label is null
           group by vl.item_id, case when vl.item_id is null then vl.line_id end order by 2 limit 50 loop
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'label',
      'text', 'Choose the NRS description for ' || rw.name || ' (' || case rw.treatment when 'zero' then 'zero-rated' else 'exempt' end || ', '
        || private.naira(rw.amount) || '). The template takes only its own list.',
      'fix', case when rw.item_id is not null then jsonb_build_object('kind', 'item', 'id', rw.item_id, 'name', rw.name, 'treatment', rw.treatment)
        else jsonb_build_object('kind', 'line', 'id', rw.line_id, 'name', rw.name, 'treatment', rw.treatment) end);
  end loop;
  if exists (select 1 from jsonb_array_elements(a) r where (r->>'amount')::numeric < 0) then
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'negative_row',
      'text', 'Credit notes on exempt or zero-rated sales are more than the sales they net against for some rows. Those rows go in as negative amounts, which the portal may refuse.');
  end if;
  -- What the template holds.
  if jsonb_array_length(a) > 9973 then
    checks := checks || jsonb_build_object('severity', 'block', 'code', 'too_many_a', 'text', 'Schedule A holds 9,973 rows and this month has ' || jsonb_array_length(a) || '.');
  end if;
  if jsonb_array_length(e) > 37 then
    checks := checks || jsonb_build_object('severity', 'block', 'code', 'too_many_e', 'text', 'Schedule E holds 37 rows and this month has ' || jsonb_array_length(e) || ' bills with VAT self-charged.');
  end if;
  if jsonb_array_length(f) > 2299 then
    checks := checks || jsonb_build_object('severity', 'block', 'code', 'too_many_f', 'text', 'Schedule F holds 2,299 rows and this month has ' || jsonb_array_length(f) || '.');
  end if;
  if exists (select 1 from customs_entries where org_id = p_org and status = 'posted' and entry_date between v_f and v_t and abs(import_vat - round(vat_base * v_vr, 2)) >= 1) then
    checks := checks || jsonb_build_object('severity', 'info', 'code', 'import_vat', 'text', 'The template takes import VAT as 7.5% of the total cost of each import; '
      || 'some customs entries paid a different amount, so line 90 differs from what was paid.');
  end if;
  if abs((l->>'115')::numeric - v_net) > v_tol then
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'tie',
      'text', 'The return comes to ' || private.naira((l->>'115')::numeric) || ' (line 115) and Counta''s VAT for the month to ' || private.naira(v_net)
        || '. The template works VAT out on totals, Counta line by line; a gap of more than ' || private.naira(v_tol) || ' needs a look.');
  end if;

  return jsonb_build_object('period', v_f, 'to', v_t,
    'org', jsonb_build_object('name', o.name, 'tin', o.tin, 'tax_id', private.vat_tin(o.tin), 'state', v_place_state),
    'file_name', to_char(v_f, 'YYYY') || '_' || coalesce(private.vat_tin(o.tin), regexp_replace(coalesce(o.tin, 'NO-TAX-ID'), '[^0-9A-Za-z-]', '', 'g')) || '_VAT_'
      || extract(month from v_f)::int || '.xlsx',
    'a', a, 'b', b, 'c2', jsonb_build_object('goods', coalesce(c2->'goods', '[]'::jsonb), 'services', coalesce(c2->'services', '[]'::jsonb),
      'fixed_assets', coalesce(c2->'fixed_assets', '[]'::jsonb)), 'c_variance', c2v, 'zero_share', v_zs,
    'c1', c1, 'd', d, 'e', e, 'f', f, 'lines', l,
    'counta', mo || jsonb_build_object('net', v_net, 'filed', vp.period is not null, 'status', coalesce(vp.status, 'open')),
    'tolerance', v_tol, 'difference', round((l->>'115')::numeric - v_net, 2),
    'checks', checks, 'blocked', exists (select 1 from jsonb_array_elements(checks) c where c->>'severity' = 'block'));
end $$;

create or replace function private.write_bill(p_org uuid, p jsonb, m public.members) returns public.bills
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; v public.vendors; o public.orgs; x jsonb; v_no int := 0; v_qty numeric; v_cost numeric; v_base numeric; v_net numeric; v_vat numeric;
  v_treat text; v_rate numeric; v_id uuid := nullif(p->>'id', '')::uuid; v_vendor uuid := nullif(p->>'vendor_id', '')::uuid; v_day date; v_code text;
  v_wht_cat text; v_recov boolean; v_line_cat text;
begin
  select * into o from orgs where id = p_org;
  if nullif(p->>'client_uuid', '') is not null and v_id is null then
    select * into b from bills where client_uuid = (p->>'client_uuid')::uuid;
    if found then return b; end if;
  end if;
  if v_vendor is null and coalesce(trim(p->'vendor'->>'name'), '') <> '' then
    select id into v_vendor from vendors where org_id = p_org and (lower(name) = lower(trim(p->'vendor'->>'name'))
      or (nullif(trim(p->'vendor'->>'tin'), '') is not null and tin = trim(p->'vendor'->>'tin'))) limit 1;
    if v_vendor is null then
      insert into vendors (org_id, name, tin, is_individual, wht_category, bank_code, bank_name, account_number, account_name, vat_registered, channel, phone, email,
        entity_type, resident, state, address, rc_number, country)
      values (p_org, left(trim(p->'vendor'->>'name'), 120), nullif(trim(p->'vendor'->>'tin'), ''), coalesce((p->'vendor'->>'is_individual')::boolean, false),
        nullif(p->'vendor'->>'wht_category', ''), nullif(p->'vendor'->>'bank_code', ''), nullif(p->'vendor'->>'bank_name', ''),
        nullif(p->'vendor'->>'account_number', ''), nullif(p->'vendor'->>'account_name', ''), coalesce((p->>'vat_charged')::boolean, true), 'email',
        nullif(p->'vendor'->>'phone', ''), nullif(p->'vendor'->>'email', ''),
        coalesce(nullif(p->'vendor'->>'entity_type', ''), case when coalesce((p->'vendor'->>'is_individual')::boolean, false) then 'individual' end),
        coalesce((p->'vendor'->>'resident')::boolean, true), nullif(trim(p->'vendor'->>'state'), ''), nullif(trim(p->'vendor'->>'address'), ''),
        nullif(trim(p->'vendor'->>'rc_number'), ''), coalesce(nullif(p->'vendor'->>'country', ''), 'NG'))
      returning id into v_vendor;
      if regexp_replace(coalesce(p->'vendor'->>'nin', ''), '\D', '', 'g') ~ '^[0-9]{11}$' then perform private.set_vendor_nin(v_vendor, p->'vendor'->>'nin', m.id); end if;
    end if;
  end if;
  select * into v from vendors where id = v_vendor and org_id = p_org;
  if not found then raise exception 'Choose the vendor.'; end if;
  v_day := coalesce(nullif(p->>'bill_date', '')::date, private.local_day(p_org, now()));
  if v_day > private.local_day(p_org, now()) + 1 then raise exception 'A bill cannot be dated in the future.'; end if;
  v_wht_cat := coalesce(nullif(p->>'wht_category', ''), v.wht_category, 'none');
  if not exists (select 1 from wht_rates where code = v_wht_cat) then raise exception 'Unknown withholding tax category.'; end if;
  if v_id is null then
    insert into bills (org_id, number, vendor_id, vendor_ref, source, external_ref, bill_date, due_date, prices_include_vat, vat_charged, wht_category,
      notes, document_path, created_by, client_uuid)
    values (p_org, 'BILL-' || lpad(private.next_no(p_org, 'BILL', 1)::text, 4, '0'), v.id, nullif(trim(p->>'vendor_ref'), ''),
      coalesce(nullif(p->>'source', ''), 'manual'), nullif(p->>'external_ref', ''), v_day,
      coalesce(nullif(p->>'due_date', '')::date, v_day + coalesce(nullif(v.credit_days, 0), 30)), coalesce((p->>'prices_include_vat')::boolean, false),
      coalesce((p->>'vat_charged')::boolean, coalesce(v.vat_registered, true) and coalesce(v.resident, true)), v_wht_cat, nullif(trim(p->>'notes'), ''),
      nullif(p->>'document_path', ''), m.id, nullif(p->>'client_uuid', '')::uuid)
    returning * into b;
  else
    select * into b from bills where id = v_id and org_id = p_org for update;
    if not found then raise exception 'Bill not found.'; end if;
    if b.status <> 'draft' then raise exception '% is already approved. Void it and enter it again.', b.number; end if;
    update bills set vendor_id = v.id, vendor_ref = case when p ? 'vendor_ref' then nullif(trim(p->>'vendor_ref'), '') else vendor_ref end, bill_date = v_day,
      due_date = coalesce(nullif(p->>'due_date', '')::date, v_day + coalesce(nullif(v.credit_days, 0), 30)),
      prices_include_vat = coalesce((p->>'prices_include_vat')::boolean, prices_include_vat), vat_charged = coalesce((p->>'vat_charged')::boolean, vat_charged),
      wht_category = v_wht_cat, notes = case when p ? 'notes' then nullif(trim(p->>'notes'), '') else notes end,
      document_path = coalesce(nullif(p->>'document_path', ''), document_path)
    where id = b.id returning * into b;
  end if;
  if b.due_date < b.bill_date then raise exception 'The due date is before the bill date.'; end if;
  if p ? 'lines' then
    delete from bill_lines where bill_id = b.id;
    if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then raise exception 'Add at least one line.'; end if;
    for x in select * from jsonb_array_elements(p->'lines') loop
      v_no := v_no + 1;
      v_code := nullif(trim(x->>'account_code'), '');
      if v_code is null or not private.bill_account_ok(p_org, v_code) then
        raise exception 'Line %: choose an expense, stock or asset account.', v_no;
      end if;
      v_qty := coalesce(round(private.num(x->>'qty'), 3), 1);
      v_cost := round(private.num(x->>'unit_cost'), 2);
      if v_qty <= 0 or v_cost is null or v_cost < 0 then raise exception 'Line %: enter the quantity and cost.', v_no; end if;
      v_treat := case when not b.vat_charged then 'none' else coalesce(nullif(x->>'vat_treatment', ''), 'standard') end;
      if v_treat not in ('standard', 'zero', 'exempt', 'none') then raise exception 'Line %: unknown VAT treatment.', v_no; end if;
      v_line_cat := nullif(x->>'wht_category', '');
      if v_line_cat is not null and not exists (select 1 from wht_rates where code = v_line_cat) then raise exception 'Line %: unknown withholding tax category.', v_no; end if;
      v_rate := case when v_treat = 'standard' then private.vat_rate(v_day) else 0 end;
      v_base := round(v_qty * v_cost, 2);
      if b.prices_include_vat then v_net := round(v_base / (1 + v_rate), 2); v_vat := v_base - v_net;
      else v_net := v_base; v_vat := round(v_net * v_rate, 2); end if;
      -- Input VAT is recoverable when the business is VAT-registered (NTA 2025 s.156), unless marked otherwise.
      v_recov := o.vat_registered and coalesce((x->>'vat_recoverable')::boolean, true);
      insert into bill_lines (bill_id, org_id, line_no, description, account_code, qty, unit_cost, vat_treatment, vat_recoverable, net, vat, gross,
        asset_life_months, location_id, ai_confidence, wht_category)
      values (b.id, p_org, v_no, left(coalesce(nullif(trim(x->>'description'), ''), 'Line ' || v_no), 300), v_code, v_qty, v_cost, v_treat, v_recov,
        v_net, v_vat, v_net + v_vat, nullif(x->>'asset_life_months', '')::int,
        (select id from locations where id = nullif(x->>'location_id', '')::uuid and org_id = p_org), nullif(x->>'ai_confidence', '')::numeric,
        case when v_line_cat is distinct from v_wht_cat then v_line_cat end);
    end loop;
  end if;
  update bills set subtotal = (select coalesce(sum(net), 0) from bill_lines where bill_id = b.id),
    vat_total = (select coalesce(sum(vat), 0) from bill_lines where bill_id = b.id),
    total = (select coalesce(sum(gross), 0) from bill_lines where bill_id = b.id)
  where id = b.id;
  return private.bill_wht(b.id);
end $$;

create or replace function private.write_lines(s public.sales, p_lines jsonb, p_cart_discount numeric, m public.members) returns public.sales
language plpgsql security definer set search_path = public, private as $$
declare x jsonb; it public.items; v_no int := 0; v_factor numeric; v_qty numeric; v_price numeric; v_list numeric; v_disc numeric;
  v_rate numeric; v_gross numeric; v_net numeric; v_vat numeric; v_base numeric;
  v_lines jsonb := '[]'::jsonb; v_sum_before numeric := 0; v_line_disc numeric := 0; v_cart numeric := round(greatest(coalesce(p_cart_discount, 0), 0), 2);
  v_share numeric; v_alloc numeric := 0; v_i int := 0; v_n int; o public.orgs; v_can_price boolean; v_rev text; v_acct text; v_treat text; v_final text;
begin
  select * into o from orgs where id = s.org_id;
  v_can_price := coalesce(private.perm_of(m, 'edit_prices') or private.perm_of(m, 'approve_adjustments'), false);
  v_rev := private.acct(s.org_id, 'sales_revenue');
  delete from sale_lines where sale_id = s.id;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Add at least one item.'; end if;
  if jsonb_array_length(p_lines) > 300 then raise exception 'A sale can have up to 300 lines.'; end if;
  for x in select * from jsonb_array_elements(p_lines) loop
    v_qty := round(private.num(x->>'qty'), 3);
    if coalesce(v_qty, 0) <= 0 then raise exception 'Every line needs a quantity above zero.'; end if;
    if nullif(x->>'item_id', '') is not null then
      select * into it from items where id = (x->>'item_id')::uuid and org_id = s.org_id and not archived;
      if not found then raise exception 'An item on this sale no longer exists.'; end if;
      v_factor := case when x->>'unit' = 'purchase' then it.pack_size else 1 end;
      v_list := round(private.list_price(s.org_id, it.id, s.price_list_id, v_qty * v_factor) * v_factor, 2);
      v_price := coalesce(round(private.num(x->>'unit_price'), 2), v_list);
      if v_price < 0 then raise exception 'A price cannot be negative.'; end if;
      if abs(v_price - v_list) > 0.004 and not v_can_price then
        raise exception 'Only someone who can edit prices can change the price of %. Give a discount instead.', it.name;
      end if;
      v_lines := v_lines || jsonb_build_object('kind', 'goods', 'item_id', it.id, 'desc', it.name, 'qty', v_qty, 'factor', v_factor, 'price', v_price,
        'list', v_list, 'treat', it.vat_treatment, 'label', case when v_factor > 1 then it.purchase_unit else it.selling_unit end, 'acct', v_rev);
    else
      if coalesce(trim(x->>'description'), '') = '' then raise exception 'A line without an item needs a description.'; end if;
      v_price := round(private.num(x->>'unit_price'), 2);
      if v_price is null or v_price < 0 then raise exception 'Enter a price for "%".', trim(x->>'description'); end if;
      if not v_can_price and s.doc_type in ('receipt', 'order') then
        raise exception 'Only someone who can edit prices can sell "%" without an item.', trim(x->>'description');
      end if;
      v_treat := coalesce(nullif(x->>'item_vat_treatment', ''), nullif(x->>'vat_treatment', ''), 'standard');
      if v_treat not in ('standard', 'zero', 'exempt') then raise exception 'Unknown VAT treatment %.', v_treat; end if;
      v_acct := coalesce(nullif(x->>'revenue_account', ''), v_rev);
      if v_acct !~ '^4' or not private.postable(s.org_id, v_acct) then raise exception 'Choose an income account for "%".', trim(x->>'description'); end if;
      v_lines := v_lines || jsonb_build_object('kind', 'service', 'item_id', null, 'desc', left(trim(x->>'description'), 300), 'qty', v_qty, 'factor', 1,
        'price', v_price, 'list', null, 'treat', v_treat, 'label', coalesce(nullif(trim(x->>'unit_label'), ''), 'unit'), 'acct', v_acct);
    end if;
    v_disc := round(greatest(coalesce(private.num(x->>'discount'), 0), 0), 2);
    if v_disc > round(v_qty * v_price, 2) then raise exception 'The discount on a line is more than the line.'; end if;
    v_lines := jsonb_set(v_lines, array[(jsonb_array_length(v_lines) - 1)::text, 'disc'], to_jsonb(v_disc));
    v_sum_before := v_sum_before + round(v_qty * v_price, 2) - v_disc;
    v_line_disc := v_line_disc + v_disc;
  end loop;
  if v_cart > v_sum_before then raise exception 'The discount is more than the sale.'; end if;
  -- Discounts beyond the cashier allowance need someone who can edit prices or approve adjustments.
  if not v_can_price and v_line_disc + v_cart > 0
     and (v_line_disc + v_cart) * 100 > o.max_cashier_discount_pct * (v_sum_before + v_line_disc) + 0.001 then
    raise exception 'Discounts above % percent need a manager or the owner.', trim(to_char(o.max_cashier_discount_pct, 'FM990.##'));
  end if;
  v_n := jsonb_array_length(v_lines);
  for x in select * from jsonb_array_elements(v_lines) loop
    v_i := v_i + 1;
    v_base := round((x->>'qty')::numeric * (x->>'price')::numeric, 2) - (x->>'disc')::numeric;
    v_share := case when v_cart = 0 or v_sum_before = 0 then 0 when v_i = v_n then v_cart - v_alloc else round(v_cart * v_base / v_sum_before, 2) end;
    v_share := least(v_share, v_base);
    v_alloc := v_alloc + v_share;
    v_final := case when s.export then 'zero' else x->>'treat' end;
    v_rate := case when not s.vat_registered then 0 when v_final = 'standard' then private.vat_rate(s.issue_date) else 0 end;
    if s.prices_include_vat then
      v_gross := v_base - v_share;
      v_net := round(v_gross / (1 + v_rate), 2);
      v_vat := v_gross - v_net;
    else
      v_net := v_base - v_share;
      v_vat := round(v_net * v_rate, 2);
      v_gross := v_net + v_vat;
    end if;
    v_no := v_no + 1;
    insert into sale_lines (sale_id, org_id, line_no, kind, item_id, description, qty, unit_label, unit_factor, unit_price, list_price, discount,
      vat_treatment, item_vat_treatment, vat_rate, net, vat, gross, revenue_account)
    values (s.id, s.org_id, v_no, x->>'kind', nullif(x->>'item_id', '')::uuid, x->>'desc', (x->>'qty')::numeric, x->>'label', (x->>'factor')::numeric,
      (x->>'price')::numeric, nullif(x->>'list', '')::numeric, (x->>'disc')::numeric + v_share, v_final, x->>'treat', v_rate, v_net, v_vat, v_gross, x->>'acct');
  end loop;
  -- Delivery is a service and carries VAT like any other, unless the goods are exported.
  if s.delivery_fee > 0 then
    v_final := case when s.export then 'zero' else 'standard' end;
    v_rate := case when s.vat_registered and v_final = 'standard' then private.vat_rate(s.issue_date) else 0 end;
    if s.prices_include_vat then v_gross := s.delivery_fee; v_net := round(v_gross / (1 + v_rate), 2); v_vat := v_gross - v_net;
    else v_net := s.delivery_fee; v_vat := round(v_net * v_rate, 2); v_gross := v_net + v_vat; end if;
    insert into sale_lines (sale_id, org_id, line_no, kind, description, qty, unit_label, unit_price, vat_treatment, item_vat_treatment, vat_rate, net, vat, gross,
      revenue_account)
    values (s.id, s.org_id, v_no + 1, 'delivery', 'Delivery', 1, 'trip', s.delivery_fee, v_final, 'standard', v_rate, v_net, v_vat, v_gross,
      private.acct(s.org_id, 'delivery_income'));
  end if;
  update sales set
    subtotal = (select coalesce(sum(net), 0) from sale_lines where sale_id = s.id),
    discount_total = (select coalesce(sum(discount), 0) from sale_lines where sale_id = s.id),
    vat_total = (select coalesce(sum(vat), 0) from sale_lines where sale_id = s.id),
    total = (select coalesce(sum(gross), 0) from sale_lines where sale_id = s.id)
  where id = s.id returning * into s;
  return s;
end $$;

create or replace function public.record_vendor_credit(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; b public.bills; v public.vendors; vc public.vendor_credits; x jsonb; bl public.bill_lines; v_no int := 0;
  v_amt numeric; v_vat numeric; v_net numeric; v_code text; v_treat text; v_left numeric; v_jl jsonb := '[]'::jsonb; v_vat_total numeric := 0; v_total numeric := 0;
  v_item public.items; v_qty numeric; v_loc uuid; v_wac numeric; v_cost numeric; v_avail numeric; v_alloc jsonb; j public.journals; v_day date; v_desc text;
  v_inv boolean; fa public.fixed_assets; v_stock jsonb := '[]'::jsonb; s jsonb; v_recov boolean;
begin
  m := private.require(p_org, 'keep_books');
  select * into o from orgs where id = p_org;
  if nullif(p->>'bill_id', '') is not null then
    select * into b from bills where id = (p->>'bill_id')::uuid and org_id = p_org for update;
    if not found then raise exception 'Bill not found.'; end if;
    if b.status not in ('approved', 'partially_paid', 'paid') then raise exception '% is %; only an approved bill takes a credit note.', b.number, b.status; end if;
    select * into v from vendors where id = b.vendor_id;
  else
    select * into v from vendors where id = nullif(p->>'vendor_id', '')::uuid and org_id = p_org;
    if not found then raise exception 'Choose the supplier.'; end if;
  end if;
  if coalesce(trim(p->>'reason'), '') = '' then raise exception 'Give the reason for the credit note.'; end if;
  v_day := coalesce(nullif(p->>'credit_date', '')::date, private.local_day(p_org, now()));
  if v_day > private.local_day(p_org, now()) + 1 then raise exception 'A credit note cannot be dated in the future.'; end if;
  if b.id is not null and v_day < b.bill_date then raise exception 'The credit note is dated before % itself.', b.number; end if;
  perform private.require_open_day(p_org, v_day);
  if nullif(trim(p->>'vendor_ref'), '') is not null and exists (select 1 from vendor_credits where org_id = p_org and vendor_id = v.id
      and lower(vendor_ref) = lower(trim(p->>'vendor_ref')) and status <> 'void') then
    raise exception 'Credit note % from % is already recorded.', trim(p->>'vendor_ref'), v.name;
  end if;
  if jsonb_typeof(p->'lines') is distinct from 'array' or jsonb_array_length(p->'lines') = 0 then raise exception 'Add what the credit note is for.'; end if;
  insert into vendor_credits (org_id, number, vendor_id, bill_id, vendor_ref, credit_date, reason, document_path, created_by)
  values (p_org, 'VCN-' || lpad(private.next_no(p_org, 'VCN', 1)::text, 4, '0'), v.id, b.id, nullif(trim(p->>'vendor_ref'), ''), v_day, trim(p->>'reason'),
    nullif(p->>'document_path', ''), m.id)
  returning * into vc;
  for x in select * from jsonb_array_elements(p->'lines') loop
    v_amt := round(coalesce(private.num(x->>'amount'), 0), 2);
    continue when v_amt <= 0 and coalesce(private.num(x->>'qty'), 0) <= 0;
    v_no := v_no + 1;
    bl := null; v_item := null; v_qty := null; v_loc := null; v_cost := null;
    if nullif(x->>'bill_line_id', '') is not null then
      select * into bl from bill_lines where id = (x->>'bill_line_id')::uuid and bill_id = b.id;
      if not found then raise exception 'Line %: that line is not on %.', v_no, b.number; end if;
      v_left := private.bill_line_creditable(bl.id);
      if v_amt > v_left + 0.004 then raise exception 'Line %: only % can still be credited on "%".', v_no, to_char(v_left, 'FM999,999,999,990.00'), bl.description; end if;
      v_code := bl.account_code; v_recov := bl.vat_recoverable;
      v_vat := case when bl.gross = 0 then 0 else round(v_amt * bl.vat / bl.gross, 2) end;
      v_desc := coalesce(nullif(trim(x->>'description'), ''), bl.description);
    else
      v_code := coalesce(nullif(trim(x->>'account_code'), ''), case when b.id is not null then (select account_code from bill_lines where bill_id = b.id order by line_no limit 1) end);
      if v_code is null or not private.bill_account_ok(p_org, v_code) then raise exception 'Line %: choose the account the credit reduces.', v_no; end if;
      v_treat := coalesce(nullif(x->>'vat_treatment', ''), case when coalesce(b.vat_charged, v.vat_registered, true) then 'standard' else 'none' end);
      if v_treat not in ('standard', 'zero', 'exempt', 'none') then raise exception 'Line %: unknown VAT treatment.', v_no; end if;
      v_vat := case when v_treat = 'standard' then round(v_amt * private.vat_rate(v_day) / (1 + private.vat_rate(v_day)), 2) else 0 end;
      v_recov := o.vat_registered;
      v_desc := coalesce(nullif(trim(x->>'description'), ''), 'Credit from ' || v.name);
    end if;
    v_net := v_amt - case when v_recov then v_vat else 0 end;
    if not v_recov then v_vat := 0; end if;
    v_inv := v_code ~ '^120[1-7]' or v_code = private.acct(p_org, 'inventory');
    -- Goods going back to the supplier leave stock at what they cost us; what the supplier credits beyond that cost (or
    -- short of it) is a purchase return.
    if nullif(x->>'item_id', '') is not null and coalesce(private.num(x->>'qty'), 0) > 0 then
      select * into v_item from items where id = (x->>'item_id')::uuid and org_id = p_org;
      if not found then raise exception 'Line %: item not found.', v_no; end if;
      v_qty := round(private.num(x->>'qty'), 3);
      v_loc := coalesce(nullif(x->>'location_id', '')::uuid, bl.location_id, (select id from locations where org_id = p_org order by created_at limit 1));
      if not exists (select 1 from locations where id = v_loc and org_id = p_org) then raise exception 'Line %: unknown branch.', v_no; end if;
      select coalesce(qty, 0) into v_avail from stock_levels where item_id = v_item.id and location_id = v_loc;
      if coalesce(v_avail, 0) < v_qty - 0.0005 then
        raise exception 'Line %: only % % of % at that branch.', v_no, private.fmt_qty(coalesce(v_avail, 0)), v_item.selling_unit, v_item.name;
      end if;
      select wac into v_wac from item_costs where item_id = v_item.id;
      v_cost := round(v_qty * coalesce(v_wac, 0), 2);
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.inv_acct(v_item.id), 'credit', v_cost, 'location_id', v_loc, 'item_id', v_item.id,
        'memo', 'Returned to ' || v.name || ' · ' || v_item.name, 'doc_type', 'vendor_credit', 'doc_id', vc.id));
      if v_net - v_cost <> 0 then
        v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'purchase_returns'),
          case when v_net > v_cost then 'credit' else 'debit' end, abs(v_net - v_cost), 'location_id', v_loc, 'memo', 'Price difference on goods returned · ' || v_item.name,
          'doc_type', 'vendor_credit', 'doc_id', vc.id));
      end if;
      v_stock := v_stock || jsonb_build_array(jsonb_build_object('item_id', v_item.id, 'qty', v_qty, 'location_id', v_loc, 'wac', coalesce(v_wac, 0), 'cost', v_cost));
      v_desc := coalesce(nullif(trim(x->>'description'), ''), v_item.name || ' returned');
    elsif v_inv then
      -- Stock cannot lose value without units leaving it: an allowance on stock bought is a purchase return.
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'purchase_returns'), 'credit', v_net, 'memo', v_desc, 'doc_type', 'vendor_credit', 'doc_id', vc.id));
    else
      if exists (select 1 from asset_classes where cost_account = v_code) then
        select * into fa from fixed_assets where bill_line_id = bl.id and status <> 'rejected' limit 1;
        if fa.id is not null and fa.status = 'active' then
          raise exception 'Line %: % is already in use. Correct its cost from the asset register instead.', v_no, fa.number;
        elsif fa.id is not null then
          update fixed_assets set cost = greatest(cost - v_net, 0), residual = least(residual, greatest(cost - v_net, 0)) where id = fa.id;
        end if;
      end if;
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', v_code, 'credit', v_net, 'memo', v_desc, 'doc_type', 'vendor_credit', 'doc_id', vc.id,
        'location_id', bl.location_id));
    end if;
    insert into vendor_credit_lines (credit_id, org_id, line_no, description, account_code, bill_line_id, item_id, qty, location_id, net, vat, gross, stock_cost)
    values (vc.id, p_org, v_no, left(v_desc, 300), case when v_item.id is not null then private.inv_acct(v_item.id) when v_inv then private.acct(p_org, 'purchase_returns') else v_code end,
      bl.id, v_item.id, v_qty, v_loc, v_net, v_vat, v_amt, v_cost);
    v_vat_total := v_vat_total + v_vat; v_total := v_total + v_amt;
  end loop;
  if v_total <= 0 then raise exception 'Enter the amount the supplier credits.'; end if;
  v_jl := jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'payables'), 'debit', v_total, 'party_type', 'vendor', 'party_id', v.id,
      'doc_type', 'vendor_credit', 'doc_id', vc.id, 'memo', vc.number || coalesce(' · ' || vc.vendor_ref, '') || coalesce(' for ' || b.number, '')))
    || v_jl
    || jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'input_vat'), 'credit', v_vat_total, 'memo', 'Input VAT given back · ' || v.name,
      'doc_type', 'vendor_credit', 'doc_id', vc.id));
  j := private.post_entry(p_org, 'Credit note ' || vc.number || ' from ' || v.name || coalesce(' for ' || b.number, '') || ' · ' || trim(p->>'reason'), 'bill', vc.id,
    m.id, m.id, v_jl, private.posting_time(p_org, v_day),
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'vendor_credit', 'id', vc.id, 'ref', coalesce(vc.vendor_ref, vc.number), 'document', vc.document_path))));
  update vendor_credits set subtotal = v_total - v_vat_total, vat_total = v_vat_total, total = v_total, journal_id = j.id where id = vc.id returning * into vc;
  for s in select * from jsonb_array_elements(v_stock) loop
    v_alloc := private.consume_batches((s->>'item_id')::uuid, (s->>'location_id')::uuid, (s->>'qty')::numeric, v_day);
    perform private.add_movement(p_org, 'purchase_return', (s->>'item_id')::uuid, (s->>'location_id')::uuid, -(s->>'qty')::numeric, (s->>'wac')::numeric, null, j.id, m.id,
      'Credit note', private.posting_time(p_org, v_day), jsonb_build_object('note', vc.number || ' · returned to ' || v.name, 'reason', 'Returned to supplier',
        'batch_id', v_alloc->0->>'batch_id'));
  end loop;
  if b.id is not null then perform private.use_vendor_credit(vc.id, b.id, null, m); end if;
  return private.vendor_credit_json(vc.id);
end $$;

create or replace function public.save_customs_entry(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; e public.customs_entries; ba public.bank_accounts; j public.journals; v_day date := nullif(p->>'entry_date', '')::date;
  v_cur text := upper(coalesce(nullif(trim(p->>'currency'), ''), 'USD')); v_inv numeric := round(private.num(p->>'invoice_value'), 2);
  v_fx numeric := round(coalesce(private.num(p->>'fx_rate'), case when upper(coalesce(p->>'currency', '')) = 'NGN' then 1 end), 6);
  v_ngn numeric; v_other numeric := round(coalesce(private.num(p->>'other_charges'), 0), 2); v_base numeric; v_vat numeric; v_at timestamptz;
  v_paid_in uuid; v_in1402 numeric; v_country text := upper(nullif(trim(p->>'country'), ''));
begin
  m := private.require(p_org, 'keep_books');
  if v_day is null then raise exception 'Enter the date the import VAT was paid.'; end if;
  if v_day > private.local_day(p_org, now()) then raise exception 'The date cannot be in the future.'; end if;
  perform private.require_open_day(p_org, v_day);
  if exists (select 1 from vat_periods where org_id = p_org and period = date_trunc('month', v_day)::date) then
    raise exception 'The % VAT return is filed. Reopen it first, or date the entry in a month not yet filed.', to_char(v_day, 'FMMonth YYYY');
  end if;
  if coalesce(trim(p->>'description'), '') = '' then raise exception 'Describe the goods imported.'; end if;
  if v_cur !~ '^[A-Z]{3}$' then raise exception 'Enter the currency as a three-letter code, such as USD.'; end if;
  if v_country is not null and v_country !~ '^[A-Z]{2}$' then raise exception 'Choose the country the goods came from.'; end if;
  if v_inv is null or v_inv <= 0 then raise exception 'Enter the invoice value of the goods.'; end if;
  if v_fx is null or v_fx <= 0 then raise exception 'Enter the exchange rate customs used.'; end if;
  if v_other < 0 then raise exception 'Other charges cannot be negative.'; end if;
  v_ngn := round(coalesce(private.num(p->>'value_ngn'), v_inv * v_fx), 2);
  if v_ngn <= 0 then raise exception 'Enter the value of the import in naira.'; end if;
  v_base := v_ngn + v_other;
  v_vat := round(coalesce(private.num(p->>'import_vat'), v_base * private.vat_rate(v_day)), 2);
  if v_vat < 0 then raise exception 'The import VAT cannot be negative.'; end if;
  if nullif(p->>'vendor_id', '') is not null and not exists (select 1 from vendors where id = (p->>'vendor_id')::uuid and org_id = p_org) then raise exception 'Supplier not found.'; end if;
  if nullif(p->>'receipt_id', '') is not null and not exists (select 1 from receipts where id = (p->>'receipt_id')::uuid and org_id = p_org) then raise exception 'Stock receipt not found.'; end if;
  -- A document is kept only under the business's own folder in storage.
  if nullif(p->>'document_path', '') is not null and (p->>'document_path' not like p_org::text || '/%' or p->>'document_path' like '%..%') then
    raise exception 'Upload the customs document again.';
  end if;
  if nullif(p->>'journal_ref', '') is not null then
    select * into j from journals where org_id = p_org and ref = trim(p->>'journal_ref');
    if not found then raise exception 'No entry % in the books.', trim(p->>'journal_ref'); end if;
    select coalesce(sum(debit - credit), 0) into v_in1402 from journal_lines where journal_id = j.id and account_code = private.acct(p_org, 'input_vat');
    if v_in1402 < v_vat - 0.005 then
      raise exception '% puts % in input VAT (%), less than the % paid at customs.', j.ref, private.naira(v_in1402), private.acct(p_org, 'input_vat'), private.naira(v_vat);
    end if;
    if exists (select 1 from customs_entries where org_id = p_org and status = 'posted' and (paid_in_journal_id = j.id or journal_id = j.id)) then
      raise exception '% is already linked to another customs entry.', j.ref;
    end if;
    v_paid_in := j.id; j := null;
  elsif nullif(p->>'bank_account_id', '') is not null then
    select * into ba from bank_accounts where id = (p->>'bank_account_id')::uuid and org_id = p_org and active;
    if not found then raise exception 'Choose the account the import VAT was paid from.'; end if;
    v_at := least(coalesce(nullif(p->>'paid_at', '')::timestamptz, private.posting_time(p_org, v_day)), now());
  elsif v_vat > 0 then
    raise exception 'Say how the import VAT was paid: from an account, or by an entry already in the books.';
  end if;
  insert into customs_entries (org_id, number, entry_date, importer, description, hs_code, vessel, country, form_m, bill_of_lading, quantity, currency,
    invoice_value, fx_rate, value_ngn, other_charges, vat_base, import_vat, vendor_id, receipt_id, bank_account_id, paid_at, reference, paid_in_journal_id,
    document_path, notes, created_by)
  values (p_org, 'CUS-' || lpad(private.next_no(p_org, 'CUSTOMS', 1)::text, 4, '0'), v_day,
    coalesce(nullif(trim(p->>'importer'), ''), (select name from orgs where id = p_org)), left(trim(p->>'description'), 300), nullif(trim(p->>'hs_code'), ''),
    nullif(trim(p->>'vessel'), ''), v_country, nullif(trim(p->>'form_m'), ''), nullif(trim(p->>'bill_of_lading'), ''), round(private.num(p->>'quantity'), 3), v_cur,
    v_inv, v_fx, v_ngn, v_other, v_base, v_vat, nullif(p->>'vendor_id', '')::uuid, nullif(p->>'receipt_id', '')::uuid, ba.id, v_at,
    nullif(trim(p->>'reference'), ''), v_paid_in, nullif(p->>'document_path', ''), nullif(trim(p->>'notes'), ''), m.id)
  returning * into e;
  if ba.id is not null and v_vat > 0 then
    j := private.post_entry(p_org, 'Import VAT paid at customs: ' || left(e.description, 120) || coalesce(' (Form M ' || e.form_m || ')', ''), 'customs_entry', e.id, m.id, m.id,
      jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'input_vat'), 'debit', v_vat, 'memo', 'Import VAT ' || e.number),
        jsonb_build_object('code', ba.ledger_code, 'credit', v_vat, 'memo', coalesce(e.reference, 'Import VAT ' || e.number))), v_at,
      jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'customs_entry', 'number', e.number, 'form_m', e.form_m,
        'bill_of_lading', e.bill_of_lading, 'by', m.display_name))));
    update customs_entries set journal_id = j.id where id = e.id returning * into e;
  end if;
  return private.customs_json(e.id);
end $$;

-- Every morning at 06:05 Lagos time: the day's exchange rates for the currencies TaxStreem allows.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'counta-fx-daily';
    perform cron.schedule('counta-fx-daily', '5 5 * * *', $c$select private.call_function('fx', '{}'::jsonb)$c$);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 10. Who may call what
-- ---------------------------------------------------------------------------
revoke execute on function private.jwt_aal(), private.is_admin(), private.require_staff(boolean), private.audit(text, text, jsonb),
  private.setting_defaults(text), private.setting(text), private.limit_of(text, text), private.feature_keys(), private.feature_on(uuid, text),
  private.orgs_new_guard(), private.voice_calls_guard(), private.secret_catalog(), private.fx_rate(text, date), private.customs_currency_guard(),
  private.vat_rate(date), private.platform_failures(timestamptz, uuid, int)
  from public, anon, authenticated;
-- The portal's calls check for an admin (or reviewer) with an authenticator code themselves; nobody signed out reaches them.
revoke execute on function public.admin_me(), public.admin_integrations(), public.admin_set_secret(text, text), public.admin_clear_secret(text),
  public.admin_settings(), public.admin_save_setting(text, jsonb), public.admin_org_switch(uuid, text, boolean, text), public.admin_set_voice(text, boolean, int),
  public.admin_currencies(), public.admin_set_currency(text, boolean), public.admin_set_rate(text, date, numeric), public.admin_clear_rate(text, date),
  public.admin_tax(), public.admin_set_tax_rule(text, date, numeric, text), public.admin_remove_tax_rule(text, date), public.admin_set_wht_rate(text, numeric, numeric),
  public.admin_overview(), public.admin_businesses(text, text, int, int), public.admin_business(uuid), public.admin_people(text, int, int),
  public.admin_activity(int), public.admin_staff(), public.admin_add_staff(text, text), public.admin_remove_staff(uuid, text),
  public.org_features(uuid), public.fx_rate_on(text, date), public.current_vat_rate(date)
  from public, anon;
grant execute on function public.admin_me(), public.admin_integrations(), public.admin_set_secret(text, text), public.admin_clear_secret(text),
  public.admin_settings(), public.admin_save_setting(text, jsonb), public.admin_org_switch(uuid, text, boolean, text), public.admin_set_voice(text, boolean, int),
  public.admin_currencies(), public.admin_set_currency(text, boolean), public.admin_set_rate(text, date, numeric), public.admin_clear_rate(text, date),
  public.admin_tax(), public.admin_set_tax_rule(text, date, numeric, text), public.admin_remove_tax_rule(text, date), public.admin_set_wht_rate(text, numeric, numeric),
  public.admin_overview(), public.admin_businesses(text, text, int, int), public.admin_business(uuid), public.admin_people(text, int, int),
  public.admin_activity(int), public.admin_staff(), public.admin_add_staff(text, text), public.admin_remove_staff(uuid, text),
  public.org_features(uuid), public.fx_rate_on(text, date), public.current_vat_rate(date)
  to authenticated, service_role;
