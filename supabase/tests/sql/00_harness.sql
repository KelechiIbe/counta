-- The harness itself: cluster, stubs, Supabase defaults, and the tests helpers.
begin;

-- test: harness_utf8
do $$
begin
  assert current_setting('server_encoding') = 'UTF8', 'harness_utf8: cluster is UTF8';
  perform tests.as_postgres();
end $$;

-- test: harness_as_user
do $$
declare v uuid;
begin
  v := tests.user('a@example.test');
  perform tests.as_user(v);
  assert auth.uid() = v and current_user = 'authenticated', 'harness_as_user: uid and role set';
  perform tests.as_user(v, 'aal2');
  assert auth.jwt()->>'aal' = 'aal2' and current_user = 'authenticated', 'harness_as_user: aal claim';
  -- private.jwt_aal is revoked from authenticated: read it with the same claims as postgres.
  perform tests.as_definer(v, 'aal2');
  assert private.jwt_aal() = 'aal2' and auth.uid() = v and current_user = 'postgres', 'harness_as_user: aal claim';
  perform tests.as_postgres();
end $$;

-- test: harness_errors
do $$
begin
  perform tests.throws('select 1/0', '%division by zero%');
  assert tests.error_of('select 1') is null, 'harness_errors: no error is null';
  perform tests.as_postgres();
end $$;

-- test: harness_capture_strip
do $$
begin
  assert tests.capture('select 1 as a, ''x'' as b;') = '[{"a": 1, "b": "x"}]', 'harness_capture_strip: rows as jsonb';
  assert tests.capture('select 1/0') = 'ERROR 22012: division by zero', 'harness_capture_strip: error text';
  assert tests.strip_keys('{"p": {"k": 1, "q": {"k": 2}}, "k": 3}', '{p.k}') = '{"k": 3, "p": {"q": {"k": 2}}}',
    'harness_capture_strip: parent.key only under parent';
  assert tests.strip_keys('{"l": [{"k": 1, "m": 2}], "k": 3}', '{"l[].k"}') = '{"k": 3, "l": [{"m": 2}]}',
    'harness_capture_strip: parent[].key only in the array elements';
  assert tests.strip_keys('{"a": {"k": 1}, "k": 2}', '{k}') = '{"a": {}}', 'harness_capture_strip: bare key at any depth';
  insert into tests.golden_ignore (path) values ('p.k');
  assert tests.capture('select ''{"k": 1, "p": {"k": 2}}''::jsonb as v') = '[{"v": {"k": 1, "p": {}}}]', 'harness_capture_strip: ignored keys stripped';
  perform tests.as_postgres();
end $$;

-- test: harness_net_requests
do $$
begin
  perform tests.hooks_on();
  perform private.call_function('messaging', '{"x":1}');
  assert (select count(*) from net._requests where url = 'http://functions.test/messaging' and body->>'x' = '1') = 1,
    'harness_net_requests: call recorded';
  perform tests.as_postgres();
end $$;

-- test: harness_default_privileges
do $$
begin
  create table public.tmp_priv (x int);
  assert has_table_privilege('anon', 'public.tmp_priv', 'select'), 'harness_default_privileges: Supabase defaults active';
  assert not has_table_privilege('anon', 'public.practices', 'select'), 'harness_default_privileges: migration revoke wins';
  perform tests.as_postgres();
end $$;

-- test: harness_auth_sessions
do $$
begin
  assert (select data_type from information_schema.columns
          where table_schema = 'auth' and table_name = 'sessions' and column_name = 'ip') = 'inet',
    'harness_auth_sessions: ip column';
  perform tests.as_postgres();
end $$;

-- test: harness_fixtures
do $$
declare o uuid; p uuid;
begin
  o := tests.org(tests.user('o@example.test'), 'Fixture Ltd');
  assert (select role from members where org_id = o) = 'owner', 'harness_fixtures: create_org owner';
  p := tests.practice(tests.user('p@example.test'), 'Fixture Partners', true);
  assert private.partner_verified(p), 'harness_fixtures: verified partner';
  perform tests.as_postgres();
end $$;

-- test: harness_new_private_revoked
-- Every private function created or redefined by a 20261124... migration is revoked from anon and authenticated,
-- except the policy helpers that RLS and storage policies call as the signed-in person. Trivially true until Task 2.
do $$
begin
  assert to_regclass('harness.private_baseline') is not null, 'harness_new_private_revoked: baseline taken';
  assert not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private' and p.prokind = 'f'
      and p.oid::regprocedure::text not in ('private.is_owner(uuid)', 'private.practice_file_ok(text)', 'private.document_may_delete(text)')
      and not exists (select 1 from harness.private_baseline b
                      where b.sig = p.oid::regprocedure::text and b.def_md5 = md5(pg_get_functiondef(p.oid)))
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))),
    'harness_new_private_revoked: new and redefined private functions are revoked from anon and authenticated';
  perform tests.as_postgres();
end $$;

rollback;
