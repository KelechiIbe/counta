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
-- active full link (billed to the practice, that partner the engagement partner), and an admin place acting as the owner,
-- with every permission, for each active partner and manager.
create function tests.managed_org(p_practice uuid, p_name text default 'Managed Test Ltd') returns uuid
language plpgsql as $$
declare v uuid; pt public.practice_members;
begin
  perform tests.as_postgres();
  select * into pt from public.practice_members
  where practice_id = p_practice and role = 'partner' and status = 'active' and user_id is not null order by created_at limit 1;
  if pt.id is null then raise exception 'tests.managed_org: no active partner in practice %', p_practice; end if;
  perform tests.as_definer(pt.user_id);
  v := private.create_org_core(p_name, 'books@firm.example.test', null, '[]', true, false);
  update public.orgs set managed_by = p_practice, identity_status = 'pending' where id = v;
  insert into public.practice_clients (practice_id, org_id, status, initiated_by, business_name, billing, mode, engagement_partner_id, started_at)
  values (p_practice, v, 'active', 'practice', p_name, 'practice', 'full', pt.id, now());
  perform set_config('counta.seat_sync', 'on', true);
  insert into public.members (org_id, user_id, email, display_name, role, title, status, practice_id, acts_as_owner,
    p_record_sales, p_receive_stock, p_count_stock, p_approve_adjustments, p_edit_prices, p_approve_pos, p_transfer_stock, p_see_margins,
    p_issue_stock, p_keep_books, p_make_payments, p_add_items, p_approve_payments, p_file_tax, p_manage_team, p_manage_settings)
  select v, pm.user_id, lower(pm.email), pm.display_name, 'admin', left('Accountant, ' || pr.name, 80), 'active', p_practice, true,
    true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true
  from public.practice_members pm join public.practices pr on pr.id = pm.practice_id
  where pm.practice_id = p_practice and pm.status = 'active' and pm.role in ('partner', 'manager') and pm.user_id is not null
  order by pm.created_at;
  perform set_config('counta.seat_sync', '', true);
  perform tests.as_postgres();
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Grants: every caller can switch identity, read ids and capture results.
-- ---------------------------------------------------------------------------
grant usage on schema tests to anon, authenticated, service_role;
grant execute on all functions in schema tests to anon, authenticated, service_role;
grant select on all tables in schema tests to anon, authenticated, service_role;
