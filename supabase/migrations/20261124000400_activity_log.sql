-- Practice management, part 4: the activity log.
--
-- Every write in a business run by a practice (orgs.managed_by) or read-only after its engagement ended (orgs.read_only_at)
-- is recorded in public.activity_log: who did it, what changed (updates keep only the changed keys), nothing secret and
-- no person's details copied from the CAC record.
--   private.activity_row()      AFTER row trigger named activity_row on orgs, members and every public table with org_id
--                               except private.activity_exempt() (logs, counters, sessions, KYC). For an ordinary business
--                               it returns after one primary-key lookup and changes nothing. It is security definer because
--                               signed-in people write some tables directly (orgs, locations, vendors, receipts,
--                               receipt_lines, ocr_corrections) and have no rights on the log. The same trigger keeps a
--                               read-only business read-only: a signed-in person's or an anonymous visitor's write is
--                               refused; Counta's own system writes (service role, the scheduled jobs), a business's purge,
--                               the seat sync, and anything after the retention date pass and are logged.
--   private.activity_attach(t)  puts the trigger on a table (a later migration's new table with org_id).
--   private.activity_event(...) a business event (mode change, handover, end, export, a letter step, a suppressed message).
--   private.set_actor(user)     names the person a system write is done for (svc_*, the fee mirror, the recurring job),
--                               when no one is signed in.
-- The log cannot be changed: updates and deletes are refused, except a business's own deletion, which takes its log with it.
-- Reads: practice_activity(client) for the practice's people on the client, org_activity(org) for the owner, an acting
-- owner or someone who manages the team.

-- ---------------------------------------------------------------------------
-- 1. The log
-- ---------------------------------------------------------------------------
create table public.activity_log (
  id bigint generated always as identity primary key,
  org_id uuid not null references public.orgs(id) on delete cascade,
  practice_id uuid,
  at timestamptz not null default now(),
  actor_user uuid,
  actor_member uuid,
  actor_name text,
  source text check (source in ('row', 'event')),
  action text not null,
  entity text,
  entity_id text,
  label text,
  before jsonb,
  after jsonb,
  changed text[]
);
create index activity_log_org on public.activity_log(org_id, at desc);
create index activity_log_practice on public.activity_log(practice_id, at desc);
-- The reads page by id.
create index activity_log_org_id on public.activity_log(org_id, id desc);
alter table public.activity_log enable row level security;
revoke all on public.activity_log from anon, authenticated;

-- Nothing in the log changes. A business's deletion removes its log through the foreign key's cascade, which runs inside
-- the deletion's own trigger (depth 2); any delete issued directly runs at depth 1.
create or replace function private.activity_guard() returns trigger
language plpgsql set search_path = public, private as $$
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then return null; end if;
  raise exception 'The activity log cannot be changed.' using errcode = '42501';
end $$;

create trigger activity_log_immutable before update or delete or truncate on public.activity_log
  for each statement execute function private.activity_guard();

-- ---------------------------------------------------------------------------
-- 2. What is not logged, and what is never kept
-- ---------------------------------------------------------------------------
-- Tables with org_id that are logs, counters, caches or sessions themselves, or hold KYC data (CAC directors stay with the
-- owner).
create or replace function private.activity_exempt() returns text[]
language sql immutable set search_path = public, private as $$
  select array['activity_log', 'messages', 'notifications', 'alert_log', 'usage_events', 'ai_logs', 'shop_hits', 'payment_events', 'org_counters',
    'stock_levels', 'agent_runs', 'guide_progress', 'lookup_failures', 'sso_logins', 'whatsapp_sessions', 'chat_links', 'voice_calls',
    'integration_events', 'prism_callbacks', 'kyc_profiles']
$$;

-- A key that holds a secret: token, secret, hash, password, otp, nin or api_key as a whole word of the name.
create or replace function private.redact_key(p_key text) returns boolean
language sql immutable set search_path = public, private as $$
  select p_key ~* '(^|_)(token|secret|hash|password|otp|nin|api_key)(_|$)'
$$;

-- A row as it may be kept: secrets replaced by "[redacted]", values longer than 4096 characters cut there.
create or replace function private.redact(p jsonb) returns jsonb
language sql immutable set search_path = public, private as $$
  select case when p is null or jsonb_typeof(p) <> 'object' then p else (
    select coalesce(jsonb_object_agg(e.key, case
        when private.redact_key(e.key) then to_jsonb('[redacted]'::text)
        when length(e.value #>> '{}') > 4096 then to_jsonb(left(e.value #>> '{}', 4096) || '…[truncated]')
        else e.value end), '{}'::jsonb)
    from jsonb_each(p) e) end
$$;

-- The row with the given keys' values replaced by "[redacted]" (keys it lacks are not added).
create or replace function private.activity_hide(p jsonb, p_keys text[]) returns jsonb
language sql immutable set search_path = public, private as $$
  select case when p is null then null
    else p || coalesce((select jsonb_object_agg(k, to_jsonb('[redacted]'::text)) from unnest(p_keys) k where p ? k), '{}'::jsonb) end
$$;

-- ---------------------------------------------------------------------------
-- 3. Writing to the log
-- ---------------------------------------------------------------------------
-- The person a system write is done for, for this transaction (null clears it).
create or replace function private.set_actor(p_user uuid) returns void
language plpgsql set search_path = public, private as $$
begin
  perform set_config('counta.actor', p_user::text, true);
end $$;

-- One entry. The actor is the signed-in person, else the one set with set_actor; their name is their place's in the
-- business, else theirs in the practice, else Public for an anonymous visitor (the public shop), else Counta.
create or replace function private.activity_add(p_org uuid, p_practice uuid, p_source text, p_action text, p_entity text, p_entity_id text,
  p_label text, p_before jsonb, p_after jsonb, p_changed text[]) returns bigint
language plpgsql set search_path = public, private as $$
declare v_actor uuid := coalesce(auth.uid(), nullif(current_setting('counta.actor', true), '')::uuid); v_member uuid; v_name text; v_id bigint;
begin
  if v_actor is not null then
    select id, display_name into v_member, v_name from members where org_id = p_org and user_id = v_actor;
    if v_name is null and p_practice is not null then
      select display_name into v_name from practice_members where practice_id = p_practice and user_id = v_actor;
    end if;
  end if;
  insert into activity_log (org_id, practice_id, actor_user, actor_member, actor_name, source, action, entity, entity_id, label, before, after, changed)
  values (p_org, p_practice, v_actor, v_member, coalesce(v_name, case when auth.role() = 'anon' then 'Public' else 'Counta' end), p_source,
    p_action, p_entity, p_entity_id, left(p_label, 120), p_before, p_after, p_changed)
  returning id into v_id;
  return v_id;
end $$;

-- Every write to a business table. Returns at once for an ordinary business (neither run by a practice nor read-only) and
-- for a row whose business is gone (deleted by this statement's cascade).
create or replace function private.activity_row() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_org uuid; v_practice uuid; v_read_only timestamptz; v_retain date; f record;
  v_new jsonb; v_old jsonb; v_hide text[]; v_row jsonb; v_before jsonb; v_after jsonb; v_changed text[];
begin
  -- 1. The business, and how it is kept.
  if tg_table_name = 'orgs' then
    -- The business row itself, read without a lookup. It is read-only as it was before this statement, so the statement
    -- that makes it read-only goes through; a handover (managed_by cleared) is still logged.
    v_org := coalesce(new.id, old.id);
    v_practice := coalesce(new.managed_by, old.managed_by);
    if tg_op = 'INSERT' then
      v_read_only := new.read_only_at; v_retain := new.retain_until;
    else
      v_read_only := old.read_only_at; v_retain := old.retain_until;
    end if;
  else
    v_org := case when tg_op = 'DELETE' then old.org_id else new.org_id end;
    select managed_by, read_only_at, retain_until into v_practice, v_read_only, v_retain from orgs where id = v_org;
    -- A row moved to another business is judged and logged in the business it leaves when that one is read-only or the
    -- new one is ordinary.
    if tg_op = 'UPDATE' and old.org_id is distinct from new.org_id then
      select managed_by, read_only_at, retain_until into f from orgs where id = old.org_id;
      if f.read_only_at is not null or (v_practice is null and v_read_only is null) then
        v_org := old.org_id; v_practice := f.managed_by; v_read_only := f.read_only_at; v_retain := f.retain_until;
      end if;
    end if;
  end if;
  if v_practice is null and v_read_only is null then return null; end if;

  -- 2. Read-only: no signed-in person and no anonymous visitor (the public shop) writes. Counta's own system writes pass, and
  -- so do a business's purge (app.allow_purge), the seat sync (counta.seat_sync) and anything once the records are past
  -- their retention date.
  if v_read_only is not null and (auth.uid() is not null or auth.role() = 'anon')
     and coalesce(current_setting('app.allow_purge', true), '') <> 'on'
     and coalesce(current_setting('counta.seat_sync', true), '') <> 'on'
     and not coalesce(v_retain < current_date, false) then
    raise exception 'This business is read-only: its engagement has ended.%',
      coalesce(' Its records are kept until ' || to_char(v_retain, 'DD Mon YYYY') || '.', '') using errcode = '42501';
  end if;
  -- A business deleted takes its log with it: nothing to write.
  if tg_table_name = 'orgs' and tg_op = 'DELETE' then return null; end if;

  -- 3. What was written. An update keeps only the keys whose values changed (updated_at aside); none, no entry.
  if tg_op <> 'DELETE' then v_new := to_jsonb(new); end if;
  if tg_op <> 'INSERT' then v_old := to_jsonb(old); end if;
  if tg_op = 'UPDATE' then
    select array_agg(n.key order by n.key), jsonb_object_agg(n.key, o.value), jsonb_object_agg(n.key, n.value)
      into v_changed, v_before, v_after
    from jsonb_each(v_new) n join jsonb_each(v_old) o on o.key = n.key
    where n.key <> 'updated_at' and n.value is distinct from o.value;
    if v_changed is null then return null; end if;
  else
    v_before := v_old;
    v_after := v_new;
  end if;
  -- People's details copied from the CAC record stay with the owner (kyc_profiles): the business row's identity check,
  -- directors and company secretary, and the names of income-tax people taken from CAC. Their keys are still listed as
  -- changed.
  v_hide := case
    when tg_table_name = 'orgs' then array['identity', 'directors', 'company_secretary']
    when tg_table_name = 'pit_people' and 'cac' in (v_old->>'source', v_new->>'source') then array['name'] end;
  v_row := private.activity_hide(coalesce(v_new, v_old), v_hide);
  perform private.activity_add(v_org, v_practice, 'row', lower(tg_op), tg_table_name, v_row->>'id',
    coalesce(v_row->>'number', v_row->>'name', v_row->>'display_name', v_row->>'title', v_row->>'description'),
    private.redact(private.activity_hide(v_before, v_hide)), private.redact(private.activity_hide(v_after, v_hide)), v_changed);
  return null;
end $$;

-- Puts the trigger on a table (again if it is there).
create or replace function private.activity_attach(p_table regclass) returns void
language plpgsql set search_path = public, private as $$
begin
  execute format('drop trigger if exists activity_row on %s', p_table);
  execute format('create trigger activity_row after insert or update or delete on %s for each row execute function private.activity_row()', p_table);
end $$;

-- A business event. The practice is the one running the business, else the one the event names (p_meta.practice_id).
-- Security definer, so its callers need no rights on the log. It stays revoked from users: a trigger that records an event
-- while a signed-in person writes (on messages, on voice calls) is itself security definer to call it.
create or replace function private.activity_event(p_org uuid, p_action text, p_label text, p_meta jsonb default '{}') returns bigint
language plpgsql security definer set search_path = public, private as $$
declare v_practice uuid;
begin
  select coalesce(managed_by, nullif(p_meta->>'practice_id', '')::uuid) into v_practice from orgs where id = p_org;
  return private.activity_add(p_org, v_practice, 'event', p_action, null, null, p_label, null, private.redact(coalesce(p_meta, '{}'::jsonb)), null);
end $$;

do $$
declare t text;
begin
  perform private.activity_attach('public.orgs');
  for t in
    select c.table_name from information_schema.columns c join information_schema.tables tb using (table_schema, table_name)
    where c.table_schema = 'public' and c.column_name = 'org_id' and tb.table_type = 'BASE TABLE' and c.table_name <> all (private.activity_exempt())
    order by c.table_name
  loop
    perform private.activity_attach(format('public.%I', t)::regclass);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Reading the log
-- ---------------------------------------------------------------------------
-- A page of a business's log, newest first, optionally one practice's entries only.
-- p = {before?: id, limit?: 1..200 (default 50), entity?: table name} -> {rows, next_before (null on the last page)}.
-- A limit that is not a number is the default, one out of range is brought within it; a before that is not an id is ignored.
create or replace function private.activity_page(p_org uuid, p_practice uuid, p jsonb) returns jsonb
language plpgsql stable set search_path = public, private as $$
declare v_limit int := least(greatest(coalesce(
    case when p->>'limit' ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$' then round(trim(p->>'limit')::numeric) end, 50), 1), 200);
  v_before bigint := case when p->>'before' ~ '^\s*[0-9]{1,18}\s*$' then trim(p->>'before')::bigint end;
  v_entity text := nullif(trim(p->>'entity'), ''); v_rows jsonb; v_next bigint;
begin
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'at', a.at, 'actor_name', a.actor_name, 'source', a.source, 'action', a.action,
      'entity', a.entity, 'entity_id', a.entity_id, 'label', a.label, 'before', a.before, 'after', a.after, 'changed', a.changed) order by a.id desc), '[]'::jsonb)
    into v_rows
  from (select * from activity_log l
        where l.org_id = p_org and (p_practice is null or l.practice_id = p_practice)
          and (v_before is null or l.id < v_before) and (v_entity is null or l.entity = v_entity)
        order by l.id desc limit v_limit + 1) a;
  -- One row more than the page only says there is another page.
  if jsonb_array_length(v_rows) > v_limit then
    v_rows := v_rows - v_limit;
    v_next := (v_rows->-1->>'id')::bigint;
  end if;
  return jsonb_build_object('rows', v_rows, 'next_before', v_next);
end $$;

-- The practice's entries for a client business: anyone of the practice on the client.
create or replace function public.practice_activity(p_client uuid, p jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.practice_clients;
begin
  c := private.practice_client_require(p_client);
  return private.activity_page(c.org_id, c.practice_id, coalesce(p, '{}'::jsonb));
end $$;

-- A business's whole log: its owner or acting owner, or someone who manages the team.
create or replace function public.org_activity(p_org uuid, p jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.require(p_org, 'manage_team');
  return private.activity_page(p_org, null, coalesce(p, '{}'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- 5. Grants
-- ---------------------------------------------------------------------------
-- core.sql grants every private function to authenticated: the helpers this migration creates are not callable by the
-- signed-in person (the trigger functions still fire for them).
revoke all on function private.activity_guard(), private.activity_exempt(), private.redact_key(text), private.redact(jsonb), private.activity_hide(jsonb, text[]),
  private.set_actor(uuid),
  private.activity_add(uuid, uuid, text, text, text, text, text, jsonb, jsonb, text[]), private.activity_row(), private.activity_attach(regclass),
  private.activity_event(uuid, text, text, jsonb), private.activity_page(uuid, uuid, jsonb)
  from public, anon, authenticated;
revoke execute on function public.practice_activity(uuid, jsonb), public.org_activity(uuid, jsonb) from public, anon;
grant execute on function public.practice_activity(uuid, jsonb), public.org_activity(uuid, jsonb) to authenticated;
