-- E-invoicing for NRS onboarding: two-step sign-in for the people who manage a business, OAuth 2.0 for partners, TaxStreem's
-- JAdES seal on every invoice Counta sends to NRS, and the facts behind each invoice's UBL (PINT NG) copy.
--
-- 1. Two-step sign-in. Owners, and anyone allowed to change a business's settings, must use an authenticator app: the app
--    asks them to set one up, and the database refuses changes to e-invoicing settings from a session without the code
--    (assurance level aal2). Everyone else may turn it on. mfa_status() tells the app which applies.
-- 2. OAuth 2.0 (client credentials) for the partner API. TaxStreem's admins make API clients in the admin portal; the
--    secret is shown once and kept only as its SHA-256. A client trades its id and secret for a token that lasts an hour,
--    also kept only as its SHA-256. The einvoice function checks tokens with svc_api_token_check.
-- 3. The seal. When NRS signs an invoice, the einvoice function seals the exact invoice it sent with TaxStreem's HSM key
--    (JAdES, ES256) and keeps the text it sent and the seal on the invoice's einvoice_docs row. A seal that could not be made
--    is tried again by the five-minute run. The key's self-signed certificate is kept in signing_certs.
-- 4. UBL. svc_einvoice_facts gives the einvoice function an invoice's facts without claiming it, for its UBL copy;
--    einvoice_doc_copy tells the app whether the person may download an invoice's copies, with the seal.

-- ---------------------------------------------------------------------------
-- 1. Two-step sign-in
-- ---------------------------------------------------------------------------
create or replace function private.mfa_required(p_user uuid) returns boolean
language sql stable security definer set search_path = public, private as $$
  select p_user is not null and exists (select 1 from public.members m
    where m.user_id = p_user and m.status = 'active' and (m.role = 'owner' or coalesce(m.p_manage_settings, false)))
$$;

-- What the app needs: whether this person must use an authenticator app, and whether this session has used it.
create or replace function public.mfa_status() returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('required', private.mfa_required(auth.uid()), 'aal', private.jwt_aal())
$$;

create or replace function private.require_mfa() returns void
language plpgsql stable security definer set search_path = public, private as $$
begin
  if auth.uid() is not null and private.jwt_aal() <> 'aal2' and private.mfa_required(auth.uid()) then
    raise exception 'Enter the code from your authenticator app first. Changes to e-invoicing need two-step sign-in.' using errcode = 'PX403';
  end if;
end $$;

-- Changing e-invoicing settings needs the code (as before, otherwise).
create or replace function public.einvoice_settings_set(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; s public.einvoice_settings; v_new uuid; v_biz text; v_svc text; v_code text; v_changed boolean := false;
  v_kick boolean := false; r jsonb;
begin
  m := private.require(p_org, 'manage_settings');
  perform private.require_mfa();
  p := coalesce(p, '{}'::jsonb);
  insert into einvoice_settings (org_id, updated_by) values (p_org, auth.uid()) on conflict (org_id) do nothing returning org_id into v_new;
  v_kick := v_new is not null;
  select * into s from einvoice_settings where org_id = p_org for update;
  if p ? 'business_id' then
    v_biz := lower(nullif(btrim(coalesce(p->>'business_id', '')), ''));
    if v_biz is not null and v_biz !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'The Business ID is the long code on your NRS dashboard, in five groups like 6dc03c76-1d83-4a39-a4de-51bd70547aef.';
    end if;
    if v_biz is distinct from s.business_id then update einvoice_settings set business_id = v_biz where org_id = p_org; v_changed := true; end if;
  end if;
  if p ? 'service_id' then
    v_svc := nullif(upper(regexp_replace(coalesce(p->>'service_id', ''), '\s', '', 'g')), '');
    if v_svc is not null and v_svc !~ '^[A-Z0-9]{8}$' then raise exception 'The Service ID is 8 letters and numbers, like 94ND90NR.'; end if;
    if v_svc is distinct from s.service_id then update einvoice_settings set service_id = v_svc where org_id = p_org; v_changed := true; end if;
  end if;
  if v_changed and not s.platform_keys then
    update einvoice_settings set keys_version = keys_version + 1, enabled = false where org_id = p_org;
  end if;
  if p ? 'service_code' then
    v_code := nullif(regexp_replace(coalesce(p->>'service_code', ''), '[^0-9]', '', 'g'), '');
    if v_code is null then
      update einvoice_settings set service_code = null, service_basis = null, service_checked_at = null, service_review = false where org_id = p_org;
      v_kick := true;
    else
      if v_code !~ '^[0-9]{4}$' or not private.nrs_code_ok('services-codes', v_code) then
        raise exception '% is not on NRS''s list of service codes.', coalesce(nullif(btrim(p->>'service_code'), ''), v_code);
      end if;
      update einvoice_settings set service_code = v_code, service_checked_at = now(), service_review = false,
        service_basis = jsonb_build_object('source', 'manual', 'code', v_code, 'by', m.display_name, 'at', now(),
          'ai', case when coalesce(s.service_basis->>'source', '') = 'manual' then s.service_basis->'ai' else s.service_basis end)
      where org_id = p_org;
    end if;
  end if;
  -- Gemini's code, confirmed as it is.
  if coalesce((p->>'service_confirm')::boolean, false) then
    if s.service_code is null then raise exception 'There is no service code to confirm yet.'; end if;
    update einvoice_settings set service_review = false,
      service_basis = coalesce(service_basis, '{}'::jsonb) || jsonb_build_object('confirmed_by', m.display_name, 'confirmed_at', now())
    where org_id = p_org;
  end if;
  if p ? 'enabled' then
    if coalesce((p->>'enabled')::boolean, false) then
      select x into r from jsonb_array_elements(private.einvoice_readiness(p_org)) x where (x->>'blocking')::boolean and not (x->>'ok')::boolean limit 1;
      if r is not null then raise exception 'Not ready yet. %', r->>'detail'; end if;
      update einvoice_settings set enabled = true, enabled_at = case when enabled then enabled_at else now() end where org_id = p_org;
    else
      update einvoice_settings set enabled = false where org_id = p_org;
    end if;
  end if;
  update einvoice_settings set updated_at = now(), updated_by = auth.uid() where org_id = p_org;
  if v_kick then perform private.call_function('ai', jsonb_build_object('action', 'nrs_codes_pending')); end if;
  return public.einvoice_settings_get(p_org);
end $$;

-- Someone who lost the phone with their authenticator: a TaxStreem admin removes it (the admin function does, through
-- Supabase Auth, after this check), and the person sets up a new one at their next sign-in.
create or replace function public.admin_mfa_reset_check(p_user uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_email text;
begin
  perform private.require_staff(true);
  select email into v_email from auth.users where id = p_user;
  if v_email is null then raise exception 'There is no such person.'; end if;
  perform private.audit('mfa.reset', v_email, jsonb_build_object('user_id', p_user));
  return jsonb_build_object('user_id', p_user, 'email', v_email);
end $$;

-- ---------------------------------------------------------------------------
-- 2. OAuth 2.0 clients and tokens for the partner API
-- ---------------------------------------------------------------------------
create table if not exists public.api_clients (
  id uuid primary key default gen_random_uuid(),
  client_id text not null unique check (client_id ~ '^cnt_[0-9a-f]{24}$'),
  name text not null check (length(btrim(name)) between 2 and 80),
  secret_hash text not null check (secret_hash ~ '^[0-9a-f]{64}$'),
  secret_hint text not null,
  scope text not null default 'einvoice' check (scope = 'einvoice'),
  created_by uuid,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid
);
create table if not exists public.api_tokens (
  token_hash text primary key check (token_hash ~ '^[0-9a-f]{64}$'),
  client uuid not null references public.api_clients(id) on delete cascade,
  scope text not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index if not exists api_tokens_client on public.api_tokens (client, expires_at);
alter table public.api_clients enable row level security;
alter table public.api_tokens enable row level security;
revoke all on public.api_clients, public.api_tokens from anon, authenticated;

create or replace function private.sha256_hex(p text) returns text
language sql immutable set search_path = public, private as $$
  select encode(sha256(convert_to(coalesce(p, ''), 'UTF8')), 'hex')
$$;

-- 256 bits from four random UUIDs (gen_random_uuid uses the server's strong random source), as hex.
create or replace function private.random_hex(p_uuids int) returns text
language sql volatile set search_path = public, private as $$
  select string_agg(replace(gen_random_uuid()::text, '-', ''), '') from generate_series(1, greatest(p_uuids, 1))
$$;

-- Client credentials: { access_token, token_type, expires_in, scope } or { error } as RFC 6749 names it.
create or replace function public.svc_api_token_issue(p_client_id text, p_secret text, p_scope text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.api_clients; v_token text; v_scope text;
begin
  select * into c from api_clients where client_id = btrim(coalesce(p_client_id, ''));
  if not found or c.revoked_at is not null or c.secret_hash <> private.sha256_hex(p_secret) then
    return jsonb_build_object('error', 'invalid_client');
  end if;
  v_scope := coalesce(nullif(btrim(coalesce(p_scope, '')), ''), c.scope);
  if v_scope <> c.scope then return jsonb_build_object('error', 'invalid_scope'); end if;
  delete from api_tokens where client = c.id and expires_at < now() - interval '1 day';
  -- At most 20 live tokens per client: the oldest give way.
  delete from api_tokens where token_hash in (select token_hash from api_tokens where client = c.id and expires_at > now()
    order by created_at desc offset 19);
  v_token := 'cat_' || private.random_hex(2);
  insert into api_tokens (token_hash, client, scope, expires_at) values (private.sha256_hex(v_token), c.id, v_scope, now() + interval '1 hour');
  update api_clients set last_used_at = now() where id = c.id;
  return jsonb_build_object('access_token', v_token, 'token_type', 'Bearer', 'expires_in', 3600, 'scope', v_scope);
end $$;

-- A bearer token: its client while it is live and the client is not revoked, else null.
create or replace function public.svc_api_token_check(p_token text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare t public.api_tokens; c public.api_clients;
begin
  if coalesce(p_token, '') !~ '^cat_[0-9a-f]{64}$' then return null; end if;
  select * into t from api_tokens where token_hash = private.sha256_hex(p_token);
  if not found or t.expires_at <= now() then return null; end if;
  select * into c from api_clients where id = t.client;
  if c.revoked_at is not null then return null; end if;
  if c.last_used_at is null or c.last_used_at < now() - interval '5 minutes' then update api_clients set last_used_at = now() where id = c.id; end if;
  return jsonb_build_object('client_id', c.client_id, 'name', c.name, 'scope', t.scope, 'expires_at', t.expires_at);
end $$;

create or replace function private.api_client_json(c public.api_clients) returns jsonb
language sql stable set search_path = public, private as $$
  select jsonb_build_object('id', c.id, 'client_id', c.client_id, 'name', c.name, 'secret_hint', c.secret_hint, 'scope', c.scope,
    'created_at', c.created_at, 'last_used_at', c.last_used_at, 'revoked_at', c.revoked_at,
    'live_tokens', (select count(*) from public.api_tokens t where t.client = c.id and t.expires_at > now()))
$$;

create or replace function public.admin_api_clients() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_staff(true);
  return coalesce((select jsonb_agg(private.api_client_json(c) order by c.revoked_at nulls first, c.created_at desc) from api_clients c), '[]'::jsonb);
end $$;

-- A new client. The secret is in this answer only; afterwards only its last four characters are shown.
create or replace function public.admin_api_client_create(p_name text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid; c public.api_clients; v_secret text; v_name text;
begin
  v_uid := private.require_staff(true);
  v_name := btrim(coalesce(p_name, ''));
  if length(v_name) < 2 or length(v_name) > 80 then raise exception 'Name the client in 2 to 80 characters, such as Prism.'; end if;
  v_secret := 'cs_' || private.random_hex(2);
  insert into api_clients (client_id, name, secret_hash, secret_hint, created_by)
  values ('cnt_' || left(private.random_hex(1), 24), v_name, private.sha256_hex(v_secret), '•••• ' || right(v_secret, 4), v_uid)
  returning * into c;
  perform private.audit('api_client.create', c.client_id, jsonb_build_object('name', v_name));
  return private.api_client_json(c) || jsonb_build_object('client_secret', v_secret);
end $$;

create or replace function public.admin_api_client_revoke(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid; c public.api_clients;
begin
  v_uid := private.require_staff(true);
  update api_clients set revoked_at = coalesce(revoked_at, now()), revoked_by = coalesce(revoked_by, v_uid) where id = p_id returning * into c;
  if not found then raise exception 'There is no such API client.'; end if;
  delete from api_tokens where client = c.id;
  perform private.audit('api_client.revoke', c.client_id, jsonb_build_object('name', c.name));
  return private.api_client_json(c);
end $$;

-- ---------------------------------------------------------------------------
-- 3. The seal: what Counta sent NRS, sealed with TaxStreem's HSM key
-- ---------------------------------------------------------------------------
alter table public.einvoice_docs add column if not exists sent_payload text;
alter table public.einvoice_docs add column if not exists jades text;
alter table public.einvoice_docs add column if not exists jades_at timestamptz;
alter table public.einvoice_docs add column if not exists seal_tries int not null default 0;
alter table public.einvoice_docs add column if not exists seal_note text;
create index if not exists einvoice_docs_seal on public.einvoice_docs (signed_at) where state = 'signed' and jades is null and sent_payload is not null;

create table if not exists public.signing_certs (
  key_version text primary key,
  pem text not null check (pem like '-----BEGIN CERTIFICATE-----%'),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  subject text not null,
  not_before timestamptz not null,
  not_after timestamptz not null,
  created_at timestamptz not null default now()
);
alter table public.signing_certs enable row level security;
revoke all on public.signing_certs from anon, authenticated;

create or replace function public.svc_signing_cert(p_version text) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select to_jsonb(c) from public.signing_certs c where c.key_version = p_version
$$;

-- The first certificate made for a key version stays; a second one made at the same moment gives way to it.
create or replace function public.svc_signing_cert_save(p_version text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  insert into signing_certs (key_version, pem, sha256, subject, not_before, not_after)
  values (p_version, p->>'pem', lower(p->>'sha256'), p->>'subject', (p->>'not_before')::timestamptz, (p->>'not_after')::timestamptz)
  on conflict (key_version) do nothing;
  return public.svc_signing_cert(p_version);
end $$;

-- What was sent, and its seal or why the seal could not be made. The text sent is kept from the first call.
create or replace function public.svc_einvoice_seal(p_doc uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare d public.einvoice_docs;
begin
  select * into d from einvoice_docs where sale_id = p_doc for update;
  if not found then return jsonb_build_object('skip', 'gone'); end if;
  if nullif(p->>'payload', '') is not null and d.sent_payload is null then
    update einvoice_docs set sent_payload = p->>'payload' where sale_id = p_doc;
  end if;
  if nullif(p->>'jades', '') is not null then
    if d.jades is null then
      update einvoice_docs set jades = p->>'jades', jades_at = now(), seal_note = null where sale_id = p_doc;
    end if;
    return jsonb_build_object('sealed', true);
  end if;
  update einvoice_docs set seal_tries = seal_tries + 1, seal_note = left(coalesce(p->>'error', 'The seal could not be made.'), 300) where sale_id = p_doc;
  return jsonb_build_object('sealed', false);
end $$;

-- Signed invoices whose seal could not be made yet, oldest first, up to five tries each.
create or replace function public.svc_einvoice_seal_due(p_limit int default 20) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('doc_id', x.sale_id, 'payload', x.sent_payload)), '[]'::jsonb)
  from (select sale_id, sent_payload from public.einvoice_docs
        where state = 'signed' and jades is null and sent_payload is not null and seal_tries < 5
        order by signed_at limit greatest(least(coalesce(p_limit, 20), 100), 1)) x
$$;

-- ---------------------------------------------------------------------------
-- 4. An invoice's facts for its UBL copy, and who may download its copies
-- ---------------------------------------------------------------------------
create or replace function public.svc_einvoice_facts(p_doc uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare d public.einvoice_docs; s public.sales;
begin
  select * into d from einvoice_docs where sale_id = p_doc;
  if not found then return null; end if;
  s := private.einvoice_doc_sale(p_doc);
  return jsonb_build_object('doc_id', d.sale_id, 'org_id', d.org_id, 'source', d.source, 'kind', d.kind, 'doc', d.doc, 'state', d.state,
    'irn', d.irn, 'number', s.number, 'signed_at', d.signed_at, 'facts', private.einvoice_facts(p_doc));
end $$;

-- The partner invoice's document, by the partner's ref.
create or replace function public.svc_prism_doc(p_org uuid, p_partner text, p_ref text) returns uuid
language sql stable security definer set search_path = public, private as $$
  select doc_id from public.prism_einvoices where org_id = p_org and partner_id = btrim(coalesce(p_partner, '')) and ref = btrim(coalesce(p_ref, ''))
$$;

-- Whether the person may download an invoice's copies (its UBL and its seal): those who see e-invoicing (settings, books or
-- tax), and for a sale those who record sales. Answers the seal with it.
create or replace function public.einvoice_doc_copy(p_doc uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare d public.einvoice_docs; m public.members; s public.sales;
begin
  select * into d from einvoice_docs where sale_id = p_doc;
  if not found then raise exception 'This invoice has not gone to NRS.' using errcode = 'PX404'; end if;
  m := private.require(d.org_id, null);
  if not (private.perm_of(m, 'manage_settings') or private.perm_of(m, 'keep_books') or private.perm_of(m, 'file_tax')
          or (d.source = 'sale' and private.perm_of(m, 'record_sales'))) then
    raise exception 'Your role does not see this invoice''s e-invoicing copies.' using errcode = '42501';
  end if;
  s := private.einvoice_doc_sale(p_doc);
  return jsonb_build_object('doc_id', d.sale_id, 'org_id', d.org_id, 'number', s.number, 'kind', d.kind, 'doc', d.doc, 'state', d.state,
    'irn', d.irn, 'signed_at', d.signed_at, 'sealed', d.jades is not null, 'jades', d.jades, 'jades_at', d.jades_at);
end $$;

-- ---------------------------------------------------------------------------
-- 5. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function public.svc_api_token_issue(text, text, text), public.svc_api_token_check(text), public.svc_signing_cert(text),
  public.svc_signing_cert_save(text, jsonb), public.svc_einvoice_seal(uuid, jsonb), public.svc_einvoice_seal_due(int),
  public.svc_einvoice_facts(uuid), public.svc_prism_doc(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.svc_api_token_issue(text, text, text), public.svc_api_token_check(text), public.svc_signing_cert(text),
  public.svc_signing_cert_save(text, jsonb), public.svc_einvoice_seal(uuid, jsonb), public.svc_einvoice_seal_due(int),
  public.svc_einvoice_facts(uuid), public.svc_prism_doc(uuid, text, text)
  to service_role;
revoke all on function public.mfa_status(), public.einvoice_doc_copy(uuid), public.admin_api_clients(), public.admin_api_client_create(text),
  public.admin_api_client_revoke(uuid), public.admin_mfa_reset_check(uuid) from public, anon;
grant execute on function public.mfa_status(), public.einvoice_doc_copy(uuid), public.admin_api_clients(), public.admin_api_client_create(text),
  public.admin_api_client_revoke(uuid), public.admin_mfa_reset_check(uuid) to authenticated;
revoke all on function private.mfa_required(uuid), private.require_mfa(), private.sha256_hex(text), private.random_hex(int),
  private.api_client_json(public.api_clients) from public, anon, authenticated;
