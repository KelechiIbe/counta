-- Helpers for the SQL tests and the golden baseline, in schema tests. Loaded after the migrations.
-- Acting as someone: tests.as_user / as_definer / as_service / as_anon, back with tests.as_postgres.
-- Fixture helpers are called as postgres and leave the session as postgres.
drop schema if exists tests cascade;
create schema tests;

create table tests.ids (name text primary key, id uuid not null);
create table tests.golden_ignore (path text primary key);

-- ---------------------------------------------------------------------------
-- Named ids
-- ---------------------------------------------------------------------------
create function tests.remember(p_name text, p_id uuid) returns uuid
language sql security definer set search_path = tests as $$
  insert into tests.ids (name, id) values (p_name, p_id) on conflict (name) do update set id = excluded.id returning id
$$;

-- Volatile on purpose: a stable function can be pre-evaluated by the planner with an older snapshot.
create function tests.id(p_name text) returns uuid
language plpgsql security definer set search_path = tests as $$
declare v uuid;
begin
  select id into v from tests.ids where name = p_name;
  if v is null then raise exception 'tests.id: no id named %', p_name; end if;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Who is acting
-- ---------------------------------------------------------------------------
create function tests.set_claims(p_claims jsonb) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', coalesce(p_claims::text, ''), true);
  perform set_config('request.jwt.claim.sub', coalesce(p_claims->>'sub', ''), true);
  perform set_config('request.jwt.claim.role', coalesce(p_claims->>'role', ''), true);
end $$;

create function tests.user_claims(p_user uuid, p_aal text) returns jsonb
language sql stable security definer set search_path = auth as $$
  select jsonb_build_object('sub', p_user, 'role', 'authenticated', 'email', (select email from auth.users where id = p_user), 'aal', p_aal)
$$;

create function tests.as_user(p_user uuid, p_aal text default 'aal1') returns void
language plpgsql as $$
begin
  reset role;
  perform tests.set_claims(tests.user_claims(p_user, p_aal));
  set local role authenticated;
end $$;

-- The caller's identity while staying postgres: for private.* functions, which are revoked from authenticated.
create function tests.as_definer(p_user uuid, p_aal text default 'aal1') returns void
language plpgsql as $$
begin
  reset role;
  perform tests.set_claims(tests.user_claims(p_user, p_aal));
end $$;

create function tests.as_service() returns void
language plpgsql as $$
begin
  reset role;
  perform tests.set_claims(jsonb_build_object('role', 'service_role'));
  set local role service_role;
end $$;

create function tests.as_anon() returns void
language plpgsql as $$
begin
  reset role;
  perform tests.set_claims(jsonb_build_object('role', 'anon'));
  set local role anon;
end $$;

create function tests.as_postgres() returns void
language plpgsql as $$
begin
  reset role;
  perform tests.set_claims(null);
end $$;

-- ---------------------------------------------------------------------------
-- Errors and captured results
-- ---------------------------------------------------------------------------
create function tests.error_of(p_sql text) returns text
language plpgsql as $$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;

create function tests.throws(p_sql text, p_like text) returns void
language plpgsql as $$
declare e text := tests.error_of(p_sql);
begin
  if e is null or e not ilike p_like then
    raise exception 'expected error like %, got %', p_like, coalesce(e, 'no error');
  end if;
end $$;

-- Removes ignored keys: a bare key at any depth, parent.key only in the object under key parent,
-- parent[].key only in the elements of the array under key parent.
create function tests.strip_walk(p jsonb, p_paths text[], p_parent text, p_array_parent text) returns jsonb
language sql immutable as $$
  select case jsonb_typeof(p)
    when 'object' then (
      select coalesce(jsonb_object_agg(e.key, tests.strip_walk(e.value, p_paths, e.key, null)), '{}'::jsonb)
      from jsonb_each(p) e
      where not (e.key = any (p_paths)
              or (p_parent is not null and p_parent || '.' || e.key = any (p_paths))
              or (p_array_parent is not null and p_array_parent || '[].' || e.key = any (p_paths))))
    when 'array' then (
      select coalesce(jsonb_agg(tests.strip_walk(a.value, p_paths, null, p_parent) order by a.n), '[]'::jsonb)
      from jsonb_array_elements(p) with ordinality a(value, n))
    else p end
$$;

create function tests.strip_keys(p jsonb, p_paths text[]) returns jsonb
language sql immutable as $$
  select case when coalesce(cardinality(p_paths), 0) = 0 then p else tests.strip_walk(p, p_paths, null, null) end
$$;

create function tests.capture(p_sql text) returns text
language plpgsql as $$
declare v jsonb;
begin
  execute format('select coalesce(jsonb_agg(to_jsonb(q)), ''[]'') from (%s) q', regexp_replace(p_sql, ';\s*$', '')) into v;
  return tests.strip_keys(v, (select array_agg(path) from tests.golden_ignore))::text;
exception when others then
  return 'ERROR ' || sqlstate || ': ' || sqlerrm;
end $$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function tests.user(p_email text, p_name text default null) returns uuid
language sql security definer set search_path = auth as $$
  insert into auth.users (email, raw_user_meta_data, email_confirmed_at)
  values (lower(trim(p_email)),
          jsonb_build_object('full_name', coalesce(nullif(trim(p_name), ''), initcap(split_part(trim(p_email), '@', 1)) || ' Test')), now())
  returning id
$$;

-- Edge-function hooks on: private.call_function then records each call in net._requests.
create function tests.hooks_on() returns void
language plpgsql security definer set search_path = private, vault as $$
begin
  insert into private.config (key, value) values ('functions_url', 'http://functions.test')
  on conflict (key) do update set value = excluded.value;
  if exists (select 1 from vault.secrets where name = 'PUSH_HOOK_SECRET') then
    update vault.secrets set secret = 'test-hook', updated_at = now() where name = 'PUSH_HOOK_SECRET';
  else
    perform vault.create_secret('test-hook', 'PUSH_HOOK_SECRET');
  end if;
end $$;

create function tests.org(p_owner uuid, p_name text) returns uuid
language plpgsql as $$
declare v uuid; v_name text;
begin
  perform tests.as_postgres();
  select raw_user_meta_data->>'full_name' into v_name from auth.users where id = p_owner;
  perform tests.as_user(p_owner);
  v := public.create_org(p_name, p_display_name => v_name);
  perform tests.as_postgres();
  return v;
end $$;

create function tests.member(p_org uuid, p_user uuid, p_role text) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare v uuid;
begin
  insert into members (org_id, user_id, email, display_name, role, status)
  select p_org, u.id, u.email, coalesce(u.raw_user_meta_data->>'full_name', split_part(u.email, '@', 1)), p_role, 'active'
  from auth.users u where u.id = p_user
  returning id into v;
  if v is null then raise exception 'tests.member: no user %', p_user; end if;
  perform private.apply_member_perms(v);
  return v;
end $$;

-- A TaxStreem admin; acts with tests.as_user(u, 'aal2').
create function tests.admin_user(p_email text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid := tests.user(p_email);
begin
  insert into platform_admins (user_id) values (v);
  return v;
end $$;

create function tests.practice(p_partner uuid, p_name text, p_verified boolean default true) returns uuid
language plpgsql as $$
declare v uuid;
begin
  perform tests.as_user(p_partner);
  v := (public.create_practice(jsonb_build_object('name', p_name, 'licence_body', 'ICAN', 'licence_no', 'TEST/0001'))->'practice'->>'id')::uuid;
  perform tests.as_postgres();
  if p_verified then
    update practice_members set licence_status = 'verified', verified_at = now() where practice_id = v and user_id = p_partner;
  end if;
  return v;
end $$;

create function tests.practice_member(p_practice uuid, p_user uuid, p_role text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  insert into practice_members (practice_id, user_id, email, display_name, role, status)
  select p_practice, u.id, u.email, coalesce(u.raw_user_meta_data->>'full_name', split_part(u.email, '@', 1)), p_role, 'active'
  from auth.users u where u.id = p_user
  returning id into v;
  if v is null then raise exception 'tests.practice_member: no user %', p_user; end if;
  return v;
end $$;

-- An active (involved) link between a practice and a business, with the practice's seats synced.
create function tests.involved_client(p_practice uuid, p_org uuid) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare v uuid;
begin
  insert into practice_clients (practice_id, org_id, status, initiated_by, business_name, started_at, accepted_by)
  select p_practice, o.id, 'active', 'practice', o.name, now(),
         (select user_id from members where org_id = o.id and role = 'owner' limit 1)
  from orgs o where o.id = p_org
  returning id into v;
  if v is null then raise exception 'tests.involved_client: no business %', p_org; end if;
  perform private.practice_sync_seats(v);
  return v;
end $$;

-- A business the practice runs under full mandate, made by its first active partner: no owner, identity pending, an
-- active full link (billed to the practice, that partner the engagement partner), and the seat sync's places: an admin
-- place acting as the owner, with every permission, for each active partner and manager.
create function tests.managed_org(p_practice uuid, p_name text default 'Managed Test Ltd') returns uuid
language plpgsql as $$
declare v uuid; v_client uuid; pt public.practice_members;
begin
  perform tests.as_postgres();
  select * into pt from public.practice_members
  where practice_id = p_practice and role = 'partner' and status = 'active' and user_id is not null order by created_at limit 1;
  if pt.id is null then raise exception 'tests.managed_org: no active partner in practice %', p_practice; end if;
  perform tests.as_definer(pt.user_id);
  v := private.create_org_core(p_name, 'books@firm.example.test', null, '[]', true, false);
  update public.orgs set managed_by = p_practice, identity_status = 'pending' where id = v;
  insert into public.practice_clients (practice_id, org_id, status, initiated_by, business_name, billing, mode, engagement_partner_id, started_at)
  values (p_practice, v, 'active', 'practice', p_name, 'practice', 'full', pt.id, now())
  returning id into v_client;
  perform private.practice_sync_seats(v_client);
  perform tests.as_postgres();
  return v;
end $$;

-- A due-diligence intake ready for an engagement, made by the practice's first active partner: risk rated low (with the RC
-- number p_rc, when given) and the conflicts check run with nothing found (it raises if the check finds anything).
create function tests.cleared_intake(p_practice uuid, p_name text, p_mode text default 'involved', p_rc text default null) returns uuid
language plpgsql as $$
declare v uuid; v_partner uuid; r jsonb;
begin
  perform tests.as_postgres();
  select user_id into v_partner from public.practice_members
  where practice_id = p_practice and role = 'partner' and status = 'active' and user_id is not null order by created_at limit 1;
  if v_partner is null then raise exception 'tests.cleared_intake: no active partner in practice %', p_practice; end if;
  perform tests.as_user(v_partner);
  v := (public.practice_intake_save(p_practice, jsonb_build_object('legal_name', p_name, 'mode_requested', p_mode, 'risk_rating', 'low',
    'risk_reason', 'Test client') || case when p_rc is not null then jsonb_build_object('rc_number', p_rc) else '{}'::jsonb end)->>'id')::uuid;
  r := public.practice_conflict_run(v);
  perform tests.as_postgres();
  if r->>'conflict_status' <> 'none' then raise exception 'tests.cleared_intake: the conflicts check found %', r->'hits'; end if;
  return v;
end $$;

-- An engagement letter for the intake signed by both sides, as the practice's first active partner: drafted from the
-- default template (the intake's mode is the variant), signed by the firm with a stand-in rendered file, sent to a client
-- signer, then e-signed through the link and the code the messaging function would email (svc_practice_mail mints both;
-- practice_letter_send only queues the email). The intake must be cleared. Returns the letter's id.
create function tests.completed_letter(p_intake uuid) returns uuid
language plpgsql as $$
declare v_practice uuid; v_partner uuid; v_name text; l uuid; s uuid; v_tok text; v_code text; r jsonb; v_fp text;
begin
  perform tests.as_postgres();
  select practice_id into v_practice from public.practice_intakes where id = p_intake;
  select user_id, display_name into v_partner, v_name from public.practice_members
  where practice_id = v_practice and role = 'partner' and status = 'active' and user_id is not null order by created_at limit 1;
  if v_partner is null then raise exception 'tests.completed_letter: no active partner for intake %', p_intake; end if;
  perform tests.as_user(v_partner);
  l := (public.practice_letter_draft(p_intake, '{}')->>'id')::uuid;
  perform tests.as_postgres();
  v_fp := private.letter_fingerprint(l);
  perform tests.as_service();
  perform public.svc_letter_frozen(l, jsonb_build_object('doc_path', 'practice/' || v_practice || '/letters/' || l || '/letter.pdf',
    'doc_sha256', repeat('ab', 32), 'by_user', v_partner, 'signature_name', v_name, 'ip', '203.0.113.5', 'ua', 'Test browser', 'fingerprint', v_fp));
  perform tests.as_user(v_partner);
  s := (public.practice_letter_send(l, '{"name":"Dayo Client","email":"dayo.client@client.example.test","title":"Director"}')->'signers'->0->>'id')::uuid;
  perform tests.as_service();
  v_tok := substring(public.svc_practice_mail('letter_sign', s)->>'link' from 'es_[0-9a-f]{48}$');
  v_code := public.svc_practice_mail('letter_code', s)->>'code';
  r := public.svc_sign_verify(v_tok, v_code, '203.0.113.9', 'Test browser');
  if not coalesce((r->>'ok')::boolean, false) then raise exception 'tests.completed_letter: the code was refused: %', r; end if;
  r := public.svc_sign_complete(v_tok, jsonb_build_object('signature_path', 'practice/' || v_practice || '/letters/' || l || '/signature-' || s || '.png',
    'final_path', 'practice/' || v_practice || '/letters/' || l || '/final.pdf', 'final_sha256', repeat('cd', 32), 'typed_name', 'Dayo Client',
    'ip', '203.0.113.9', 'ua', 'Test browser'));
  if not coalesce((r->>'ok')::boolean, false) then raise exception 'tests.completed_letter: signing was refused: %', r; end if;
  perform tests.as_postgres();
  return l;
end $$;

-- A business the practice takes on under full mandate the way a firm does it: a cleared full-mandate intake with an RC
-- number, the partner's declaration of the client's written authority, a full-mandate letter signed by both sides, then
-- practice_create_business as p_partner (who must be a partner with a verified licence). The name and RC number default to
-- ones made from the number of intakes so far (one word, so two of them never look alike to the conflicts check); a name
-- given must not match another of the practice's clients or intakes. Returns the client link's id.
create function tests.full_client(p_practice uuid, p_partner uuid, p_name text default null, p_rc text default null) returns uuid
language plpgsql as $$
declare v_intake uuid; r jsonb; v_n bigint;
begin
  perform tests.as_postgres();
  v_n := (select count(*) from public.practice_intakes) + 1;
  v_intake := tests.cleared_intake(p_practice,
    coalesce(p_name, initcap('fullco' || translate(lpad(v_n::text, 6, '0'), '0123456789', 'abcdefghij')) || ' Ltd'), 'full',
    coalesce(p_rc, 'RC 8' || lpad(v_n::text, 6, '0')));
  perform tests.as_user(p_partner);
  perform public.practice_intake_declare(v_intake, '{}');
  perform tests.as_postgres();
  perform tests.completed_letter(v_intake);
  perform tests.as_user(p_partner);
  r := public.practice_create_business(v_intake, '{"email":"books@firm.example.test"}');
  perform tests.as_postgres();
  if not coalesce((r->>'ok')::boolean, false) then raise exception 'tests.full_client: the business was not set up: %', r; end if;
  return (r->>'client_id')::uuid;
end $$;

-- The director of a business the practice runs under full mandate, confirmed and reachable for approvals: what their code
-- reached is kept on the confirmation, as when they confirm the wallets by code. Returns the confirmation's id.
create function tests.director_approver(p_org uuid, p_name text default 'Dayo Director', p_email text default 'director@example.test',
  p_phone text default '2348031234567') returns uuid
language plpgsql as $$
declare c public.practice_clients; v_id uuid;
begin
  select * into c from public.practice_clients where org_id = p_org and status = 'active' and mode = 'full' order by created_at desc limit 1;
  if c.id is null then raise exception 'tests.director_approver: % has no full mandate', p_org; end if;
  insert into public.practice_director_confirmations (practice_id, client_id, name, email, status, confirmed_at, matched_name, approver_email,
    approver_phone)
  values (c.practice_id, c.id, p_name, p_email, 'confirmed', now(), upper(p_name), p_email, p_phone)
  returning id into v_id;
  update public.orgs set director_confirmed_at = coalesce(director_confirmed_at, now()) where id = p_org;
  return v_id;
end $$;

-- Every request waiting for the director of p_org, approved by them as their link and code would. Call as postgres.
-- Returns how many.
create function tests.director_approves(p_org uuid) returns integer
language plpgsql as $$
declare a record; v_n int := 0;
begin
  for a in select id from public.approvals where org_id = p_org and status = 'pending' and approver = 'director' order by created_at loop
    perform private.approval_settle(a.id, true, null, null, 'Dayo Director (director)', null, null);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- ---------------------------------------------------------------------------
-- Grants: every caller can switch identity, read ids and capture results.
-- ---------------------------------------------------------------------------
grant usage on schema tests to anon, authenticated, service_role;
grant execute on all functions in schema tests to anon, authenticated, service_role;
grant select on all tables in schema tests to anon, authenticated, service_role;
