-- Counta — hardening after the Supabase advisors:
--   1. every function pins its search_path
--   2. every RPC stays signed-in only (anon and PUBLIC lose execute on functions added since the first lockdown)
--   3. members can read their own numbering counters (silences "RLS enabled, no policy")
--   4. a covering index for every single-column foreign key in public

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'private') and p.prokind = 'f'
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and not exists (select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) c where c like 'search_path=%')
  loop
    execute format('alter function %s set search_path = public, private', f.sig);
  end loop;
end $$;

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'private') and p.prokind = 'f'
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;

create policy org_counters_read on public.org_counters for select to authenticated using ((select private.is_member(org_id)));

do $$
declare r record;
begin
  for r in
    select c.conrelid::regclass as tbl, a.attname as col, cl.relname as tname
    from pg_constraint c
    join pg_class cl on cl.oid = c.conrelid
    join pg_namespace n on n.oid = cl.relnamespace
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
    where c.contype = 'f' and n.nspname = 'public' and array_length(c.conkey, 1) = 1
      and not exists (
        select 1 from pg_index i where i.indrelid = c.conrelid and i.indkey[0] = c.conkey[1])
  loop
    execute format('create index if not exists %I on %s (%I)', left(r.tname || '_' || r.col || '_fk', 63), r.tbl, r.col);
  end loop;
end $$;
