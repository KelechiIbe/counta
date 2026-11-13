-- Activity log: every write in a business run by a practice (or read-only after its engagement ended) is recorded with
-- who did it, what changed and nothing secret; the log cannot be changed; a read-only business refuses signed-in writes
-- while Counta's own system writes pass; the practice and the business read their log a page at a time.
begin;

-- Fixture: a verified practice (partner) running a business under full mandate, with a supplier; an ordinary business
-- (owner, staff); a second practice.
do $$
declare v_partner uuid; v_owner uuid; v_staff uuid; v_other uuid; v_pr uuid; v_o uuid; v_ord uuid; v_vendor uuid;
begin
  v_partner := tests.remember('partner', tests.user('al.partner@firm.example.test', 'Ngozi Partner'));
  v_owner := tests.remember('owner', tests.user('al.owner@example.test', 'Ada Owner'));
  v_staff := tests.remember('staff', tests.user('al.staff@example.test', 'Femi Staff'));
  v_other := tests.remember('other', tests.user('al.other@other.example.test', 'Kemi Other'));
  v_pr := tests.remember('pr', tests.practice(v_partner, 'Ledger Partners', true));
  perform tests.remember('other_pr', tests.practice(v_other, 'Other Partners', true));
  v_o := tests.remember('o', tests.managed_org(v_pr, 'Activity Managed Ltd'));
  perform tests.remember('c', (private.mandate(v_o)).id);
  perform tests.remember('partner_seat', (select id from members where org_id = v_o and user_id = v_partner));
  insert into vendors (org_id, name) values (v_o, 'Supplies Ltd') returning id into v_vendor;
  perform tests.remember('vendor', v_vendor);
  v_ord := tests.remember('ord', tests.org(v_owner, 'Activity Ordinary Ltd'));
  perform tests.remember('staff_seat', tests.member(v_ord, v_staff, 'staff'));
  perform tests.as_postgres();
end $$;

-- test: activity_trigger_coverage
do $$
begin
  assert not exists (select 1 from information_schema.columns c join information_schema.tables t using (table_schema, table_name)
    where c.table_schema = 'public' and c.column_name = 'org_id' and t.table_type = 'BASE TABLE'
      and c.table_name <> all (private.activity_exempt())
      and not exists (select 1 from pg_trigger g where g.tgrelid = ('public.' || c.table_name)::regclass and g.tgname = 'activity_row')),
    'activity_trigger_coverage: every org table has the trigger or is exempt';
  assert exists (select 1 from pg_trigger where tgrelid = 'public.orgs'::regclass and tgname = 'activity_row')
     and exists (select 1 from pg_trigger where tgrelid = 'public.members'::regclass and tgname = 'activity_row'),
    'activity_trigger_coverage: the business row and its places';
  assert not exists (select 1 from pg_trigger where tgname = 'activity_row'
                     and tgrelid in ('public.activity_log'::regclass, 'public.messages'::regclass, 'public.kyc_profiles'::regclass)),
    'activity_trigger_coverage: the log itself and exempt tables have none';
  -- A table added later gets it from private.activity_attach (dropped and made again, never twice).
  create table public.tmp_activity (id uuid primary key default gen_random_uuid(), org_id uuid not null references public.orgs(id), name text);
  perform private.activity_attach('public.tmp_activity');
  perform private.activity_attach('public.tmp_activity');
  assert (select count(*) from pg_trigger where tgrelid = 'public.tmp_activity'::regclass and tgname = 'activity_row') = 1,
    'activity_trigger_coverage: activity_attach';
  insert into public.tmp_activity (org_id, name) values (tests.id('o'), 'Attached');
  assert (select count(*) from activity_log where org_id = tests.id('o') and entity = 'tmp_activity' and label = 'Attached') = 1,
    'activity_trigger_coverage: an attached table is logged';
  drop table public.tmp_activity;
  perform tests.as_postgres();
end $$;

-- test: activity_ordinary_silent
-- An ordinary business is never logged, whoever writes and however.
do $$
declare ord uuid := tests.id('ord'); v uuid;
begin
  perform tests.as_user(tests.id('owner'));
  v := public.save_customer(ord, '{"name": "Walk Ordinary"}');
  perform public.save_customer(ord, jsonb_build_object('id', v, 'name', 'Ordinary Renamed'));
  insert into vendors (org_id, name) values (ord, 'Ordinary Supplies');
  update orgs set name = 'Activity Ordinary Group Ltd' where id = ord;
  perform tests.as_postgres();
  delete from customers where id = v;
  assert (select count(*) from activity_log where org_id = ord) = 0, 'activity_ordinary_silent';
  perform tests.as_postgres();
end $$;

-- test: activity_row_changes
do $$
declare o uuid := tests.id('o'); v uuid; a public.activity_log;
begin
  -- Making the business and its places is on record already.
  assert (select count(*) from activity_log where org_id = o and entity = 'orgs' and action = 'update' and 'managed_by' = any (changed)
            and actor_user = tests.id('partner') and actor_name = 'Ngozi Partner' and actor_member is null) = 1,
    'activity_row_changes: the business taken under full mandate, by a partner who has no place yet';
  assert (select count(*) from activity_log where org_id = o and entity = 'members' and action = 'insert' and label = 'Ngozi Partner') = 1,
    'activity_row_changes: the partner''s place';
  perform tests.as_user(tests.id('partner'));
  v := public.save_customer(o, '{"name": "Bola Stores", "phone": "08031234567"}');
  perform public.save_customer(o, jsonb_build_object('id', v, 'name', 'Bola Stores Ltd'));
  perform tests.as_postgres();
  assert (select count(*) from activity_log where org_id = o and entity = 'customers' and action = 'insert' and actor_user = tests.id('partner')) = 1,
    'activity_row_changes: insert';
  select * into a from activity_log where org_id = o and entity = 'customers' and action = 'insert';
  assert a.source = 'row' and a.practice_id = tests.id('pr') and a.actor_member = tests.id('partner_seat') and a.actor_name = 'Ngozi Partner'
     and a.entity_id = v::text and a.label = 'Bola Stores' and a.before is null and a.changed is null
     and a.after->>'name' = 'Bola Stores' and a.after ? 'phone' and a.after->>'org_id' = o::text,
    'activity_row_changes: the inserted row, whole';
  assert (select changed = '{name}' and before ? 'name' and not before ? 'phone' from activity_log where org_id = o and entity = 'customers' and action = 'update'),
    'activity_row_changes: changed keys only';
  select * into a from activity_log where org_id = o and entity = 'customers' and action = 'update';
  assert a.before = '{"name": "Bola Stores"}' and a.after = '{"name": "Bola Stores Ltd"}' and a.label = 'Bola Stores Ltd' and a.entity_id = v::text,
    'activity_row_changes: before and after';
  -- Nothing changed, nothing logged; updated_at alone is no change.
  update customers set name = name where id = v;
  insert into budgets (org_id, account_code, month, amount) values (o, '6000', date '2027-01-01', 1000);
  update budgets set updated_at = updated_at + interval '1 hour' where org_id = o and account_code = '6000';
  assert (select count(*) from activity_log where org_id = o and action = 'update' and entity in ('customers', 'budgets')) = 1,
    'activity_row_changes: no row when nothing changed';
  -- A delete keeps the row as it was; a table keyed otherwise has no entity_id; a system write is Counta's.
  delete from budgets where org_id = o and account_code = '6000';
  select * into a from activity_log where org_id = o and entity = 'budgets' and action = 'delete';
  assert a.before->>'account_code' = '6000' and (a.before->>'amount')::numeric = 1000 and a.after is null and a.entity_id is null and a.label is null
     and a.actor_user is null and a.actor_member is null and a.actor_name = 'Counta',
    'activity_row_changes: delete';
  perform tests.as_postgres();
end $$;

-- test: activity_row_moved
-- A row moved out of a business that is logged is logged there.
do $$
declare o uuid := tests.id('o'); ord uuid := tests.id('ord'); v uuid;
begin
  insert into vendors (org_id, name) values (ord, 'Moving Supplies') returning id into v;
  update vendors set org_id = o where id = v;
  update vendors set org_id = ord where id = v;
  assert (select count(*) from activity_log where org_id = o and entity = 'vendors' and entity_id = v::text and action = 'update' and changed = '{org_id}') = 2,
    'activity_row_moved: in and out';
  assert (select count(*) from activity_log where org_id = ord) = 0, 'activity_row_moved: the ordinary business stays silent';
  perform tests.as_postgres();
end $$;

-- test: activity_direct_write
-- Signed-in people write some tables directly, through their RLS policies: the definer trigger logs them all, while they
-- have no rights on the log itself.
do $$
declare o uuid := tests.id('o'); p uuid := tests.id('partner');
begin
  perform tests.as_user(p);
  update vendors set name = 'Renamed Supplies Ltd' where id = tests.id('vendor');
  update orgs set name = 'Activity Managed Group Ltd' where id = o;
  update locations set name = 'Head office' where org_id = o;
  insert into receipts (org_id, ref, source, status) values (o, 'RCV-ACT-1', 'manual', 'reading');
  perform tests.as_postgres();
  assert (select count(*) from activity_log where org_id = o and entity = 'vendors' and action = 'update' and actor_user = p) = 1,
    'activity_direct_write: logged through the definer trigger';
  assert (select count(*) from activity_log where org_id = o and actor_user = p and actor_member = tests.id('partner_seat')
            and ((entity = 'orgs' and action = 'update' and changed = '{name}' and entity_id = o::text and label = 'Activity Managed Group Ltd')
              or (entity = 'locations' and action = 'update' and changed = '{name}')
              or (entity = 'receipts' and action = 'insert' and label is null and after->>'ref' = 'RCV-ACT-1'))) = 3,
    'activity_direct_write: the business row, a location and a receipt';
  perform tests.as_user(p);
  perform tests.throws('select count(*) from activity_log', '42501: permission denied%');
  perform tests.throws(format($q$insert into activity_log (org_id, action) values (%L, 'forged')$q$, o), '42501: permission denied%');
  perform tests.as_postgres();
  -- Read-only, the same direct write is refused.
  update orgs set read_only_at = now(), retain_until = date '2031-11-13' where id = o;
  perform tests.as_user(p);
  perform tests.throws(format($q$update vendors set name = 'After Ltd' where id = %L$q$, tests.id('vendor')), '42501%');
  perform tests.as_postgres();
  update orgs set read_only_at = null, retain_until = null where id = o;
  assert (select name from vendors where id = tests.id('vendor')) = 'Renamed Supplies Ltd', 'activity_direct_write: the refused write left nothing';
  perform tests.as_postgres();
end $$;

-- test: activity_redaction
do $$
declare o uuid := tests.id('o'); v uuid;
begin
  assert private.redact_key('token_hash') and private.redact_key('nin_last4') and private.redact_key('api_key_secret') and private.redact_key('otp_hash')
     and private.redact_key('password'), 'activity_redaction: secrets';
  assert private.redact_key('invoice_portal_token') and private.redact_key('API_KEY_CT') and private.redact_key('secret_id') and private.redact_key('nin'),
    'activity_redaction: secrets anywhere in the key';
  assert not private.redact_key('opening_balance') and not private.redact_key('margin_threshold') and not private.redact_key('pinned'),
    'activity_redaction: no over-match';
  assert not private.redact_key('tokens') and not private.redact_key('hashtag') and not private.redact_key('nineteen'), 'activity_redaction: whole words only';
  assert private.redact(jsonb_build_object('notes', repeat('x', 5000)))->>'notes' like '%…[truncated]', 'activity_redaction: 4 KB cap';
  assert private.redact(jsonb_build_object('notes', repeat('x', 5000)))->>'notes' = repeat('x', 4096) || '…[truncated]'
     and private.redact(jsonb_build_object('notes', repeat('y', 4096)))->>'notes' = repeat('y', 4096),
    'activity_redaction: cut at 4096 characters, not before';
  assert private.redact('{"token_hash": "abc", "name": "Kept", "n": 3, "lines": [1, 2], "none": null}')
         = '{"token_hash": "[redacted]", "name": "Kept", "n": 3, "lines": [1, 2], "none": null}',
    'activity_redaction: only secrets change';
  assert private.redact(null) is null, 'activity_redaction: null';
  -- In the log itself: a secret column is listed as changed, its values are not kept; long values are cut.
  update orgs set invoice_portal_token = 'portal-secret-value' where id = o;
  assert (select changed = '{invoice_portal_token}' and before->>'invoice_portal_token' = '[redacted]' and after->>'invoice_portal_token' = '[redacted]'
          from activity_log where org_id = o and entity = 'orgs' and 'invoice_portal_token' = any (changed)),
    'activity_redaction: secrets never reach the log';
  insert into customers (org_id, name, notes) values (o, 'Long Notes Ltd', repeat('n', 5000)) returning id into v;
  assert (select after->>'notes' = repeat('n', 4096) || '…[truncated]' from activity_log where org_id = o and entity_id = v::text),
    'activity_redaction: long values cut in the log';
  perform tests.as_postgres();
end $$;

-- test: activity_immutable
do $$
declare v_gone uuid;
begin
  perform tests.throws($q$update activity_log set label = 'x'$q$, '%cannot be changed%');
  perform tests.throws($q$delete from activity_log$q$, '%cannot be changed%');
  perform tests.throws('truncate activity_log', '%cannot be changed%');
  perform tests.as_service();
  perform tests.throws(format('delete from activity_log where org_id = %L', tests.id('o')), '42501: The activity log cannot be changed.');
  perform tests.as_postgres();
  -- A business deleted takes its log with it.
  v_gone := tests.managed_org(tests.id('pr'), 'Activity Gone Ltd');
  insert into vendors (org_id, name) values (v_gone, 'Gone Supplies');
  assert (select count(*) from activity_log where org_id = v_gone) > 0, 'activity_immutable: the deleted business had a log';
  delete from orgs where id = v_gone;
  assert (select count(*) from activity_log where org_id = v_gone) = 0, 'activity_immutable: org delete cascades';
  perform tests.as_postgres();
end $$;

-- test: activity_actor_setting
-- A system write on someone's behalf (svc_*, the fee mirror, the recurring job) names them through counta.actor.
do $$
declare o uuid := tests.id('o'); a public.activity_log;
begin
  perform private.set_actor(tests.id('partner'));
  assert current_setting('counta.actor', true) = tests.id('partner')::text, 'activity_actor_setting: set for the transaction';
  perform tests.as_service();
  insert into customers (org_id, name) values (o, 'Actor Stores');
  perform tests.as_postgres();
  assert (select actor_user from activity_log where org_id = o order by id desc limit 1) = tests.id('partner'), 'activity_actor_setting';
  select * into a from activity_log where org_id = o order by id desc limit 1;
  assert a.actor_member = tests.id('partner_seat') and a.actor_name = 'Ngozi Partner' and a.label = 'Actor Stores', 'activity_actor_setting: their place and name';
  -- The signed-in person comes first.
  perform tests.as_definer(tests.id('partner'));
  perform private.set_actor(tests.id('owner'));
  insert into customers (org_id, name) values (o, 'Signed In Stores');
  assert (select actor_user from activity_log where org_id = o order by id desc limit 1) = tests.id('partner'), 'activity_actor_setting: auth.uid() first';
  perform tests.as_postgres();
  perform private.set_actor(null);
  insert into customers (org_id, name) values (o, 'Nobody Stores');
  select * into a from activity_log where org_id = o order by id desc limit 1;
  assert a.actor_user is null and a.actor_member is null and a.actor_name = 'Counta', 'activity_actor_setting: cleared';
  perform tests.as_postgres();
end $$;

-- test: activity_event
do $$
declare o uuid := tests.id('o'); v bigint; a public.activity_log;
begin
  perform tests.as_definer(tests.id('partner'));
  v := private.activity_event(o, 'letter_signed', 'Engagement letter signed', '{"letter": "EL-1"}');
  perform tests.as_postgres();
  select * into a from activity_log where id = v;
  assert a.org_id = o and a.source = 'event' and a.action = 'letter_signed' and a.label = 'Engagement letter signed' and a.after = '{"letter": "EL-1"}'
     and a.practice_id = tests.id('pr') and a.entity is null and a.before is null and a.actor_user = tests.id('partner') and a.actor_name = 'Ngozi Partner',
    'activity_event: from managed_by';
  -- A business no practice runs (after a handover): the practice comes from the event.
  v := private.activity_event(tests.id('ord'), 'handover', 'Handed over to the owner', jsonb_build_object('practice_id', tests.id('pr')));
  assert (select practice_id = tests.id('pr') and source = 'event' and actor_name = 'Counta' from activity_log where id = v), 'activity_event: from p_meta';
  v := private.activity_event(tests.id('ord'), 'note', 'No practice');
  assert (select practice_id is null and after = '{}' from activity_log where id = v), 'activity_event: default meta';
  perform tests.as_postgres();
end $$;

-- test: read_only_enforced
do $$
declare o uuid := tests.id('o'); p uuid := tests.id('partner'); v_msg text := '42501: This business is read-only: its engagement has ended. Its records are kept until 13 Nov 2031.';
begin
  -- The statement that makes the business read-only is not itself blocked, even run for a signed-in partner.
  perform tests.as_definer(p);
  update orgs set read_only_at = now(), retain_until = date '2031-11-13' where id = o;
  perform tests.as_postgres();
  assert (select changed = '{read_only_at,retain_until}' and actor_user = p from activity_log where org_id = o and entity = 'orgs' and 'read_only_at' = any (changed)
          order by id desc limit 1),
    'read_only_enforced: becoming read-only is logged';
  perform tests.as_user(p);
  perform tests.throws(format($q$select public.save_customer(%L, '{"name":"New"}')$q$, o), '42501%');
  perform tests.throws(format($q$select public.save_customer(%L, '{"name":"New"}')$q$, o), v_msg);
  perform tests.throws(format($q$update orgs set name = 'Read Only Ltd' where id = %L$q$, o), v_msg);
  perform tests.throws(format($q$update vendors set name = 'After Ltd' where id = %L$q$, tests.id('vendor')), v_msg);
  -- Counta's own functions run for a signed-in person are refused too, deletes and moves out included.
  perform tests.as_definer(p);
  perform tests.throws(format('delete from vendors where id = %L', tests.id('vendor')), v_msg);
  perform tests.throws(format('update vendors set org_id = %L where id = %L', tests.id('ord'), tests.id('vendor')), v_msg);
  perform tests.throws(format($q$update orgs set read_only_at = null where id = %L$q$, o), v_msg);
  perform tests.as_service();
  assert tests.error_of(format($q$insert into customers (org_id, name) values (%L, 'System')$q$, o)) is null, 'read_only_enforced: system writes pass';
  perform tests.as_postgres();
  assert (select actor_name = 'Counta' from activity_log where org_id = o and entity = 'customers' and label = 'System'), 'read_only_enforced: and are logged';
  -- Without a retention date the message stops at the first sentence; ordinary businesses write as before.
  update orgs set retain_until = null where id = o;
  perform tests.as_user(p);
  perform tests.throws(format($q$select public.save_customer(%L, '{"name":"New"}')$q$, o), '42501: This business is read-only: its engagement has ended.');
  perform tests.as_user(tests.id('owner'));
  perform public.save_customer(tests.id('ord'), '{"name": "Still Ordinary"}');
  perform tests.as_postgres();
  update orgs set retain_until = date '2031-11-13' where id = o;
  perform tests.as_postgres();
end $$;

-- test: activity_reads
do $$
declare o uuid := tests.id('o'); c uuid := tests.id('c'); v jsonb; v1 jsonb; v2 jsonb; n int; r jsonb;
begin
  perform tests.as_user(tests.id('partner'));
  assert jsonb_array_length(public.practice_activity(c)->'rows') > 0, 'activity_reads: practice';
  v := public.practice_activity(c, '{"limit": 200}');
  perform tests.as_postgres();
  n := (select count(*) from activity_log where org_id = o);
  assert jsonb_array_length(v->'rows') = n and v ? 'next_before' and v->'next_before' = 'null', 'activity_reads: every row of the business, one page';
  r := v->'rows'->0;
  assert (select array_agg(k order by k) from jsonb_object_keys(r) k)
         = '{action,actor_name,after,at,before,changed,entity,entity_id,id,label,source}',
    'activity_reads: row keys';
  assert (r->>'id')::bigint = (select max(id) from activity_log where org_id = o), 'activity_reads: newest first';
  -- Pages.
  perform tests.as_user(tests.id('partner'));
  v1 := public.practice_activity(c, '{"limit": 2}');
  v2 := public.practice_activity(c, jsonb_build_object('limit', 2, 'before', v1->'next_before'));
  perform tests.as_postgres();
  assert jsonb_array_length(v1->'rows') = 2 and (v1->>'next_before')::bigint = (v1->'rows'->1->>'id')::bigint, 'activity_reads: first page';
  assert jsonb_array_length(v2->'rows') = 2 and (v2->'rows'->0->>'id')::bigint < (v1->>'next_before')::bigint
     and (v2->'rows'->0->>'id')::bigint = (select max(id) from activity_log where org_id = o and id < (v1->>'next_before')::bigint),
    'activity_reads: the next page carries on';
  perform tests.as_user(tests.id('partner'));
  v := public.practice_activity(c, '{"entity": "vendors", "limit": 200}');
  v1 := public.practice_activity(c, '{"limit": 0}');
  v2 := public.practice_activity(c, '{"limit": 5000}');
  perform tests.as_postgres();
  assert jsonb_array_length(v->'rows') = (select count(*) from activity_log where org_id = o and entity = 'vendors')
     and not exists (select 1 from jsonb_array_elements(v->'rows') x where x->>'entity' <> 'vendors'),
    'activity_reads: one kind of record';
  assert jsonb_array_length(v1->'rows') = 1 and jsonb_array_length(v2->'rows') = least(n, 200), 'activity_reads: limit kept within 1..200';
  -- The business reads its own log: the owner or acting owner, or someone who manages the team.
  perform tests.as_user(tests.id('partner'));
  v := public.org_activity(o, '{"limit": 200}');
  perform tests.as_postgres();
  assert jsonb_array_length(v->'rows') = n, 'activity_reads: business';
  -- An ordinary business has events only (activity_event above), never row changes.
  perform tests.as_user(tests.id('owner'));
  v := public.org_activity(tests.id('ord'));
  assert jsonb_array_length(v->'rows') = 2 and not exists (select 1 from jsonb_array_elements(v->'rows') x where x->>'source' <> 'event')
     and v->'next_before' = 'null',
    'activity_reads: an ordinary business';
  perform tests.as_user(tests.id('staff'));
  perform tests.throws(format('select public.org_activity(%L)', tests.id('ord')), '42501: Your role does not allow this (manage team).');
  perform tests.as_postgres();
  update members set p_manage_team = true where id = tests.id('staff_seat');
  perform tests.as_user(tests.id('staff'));
  perform public.org_activity(tests.id('ord'));
  -- Outsiders.
  perform tests.as_user(tests.id('other'));
  perform tests.throws(format('select public.practice_activity(%L)', c), '%not on this practice%');
  perform tests.throws(format('select public.org_activity(%L)', o), '%not a member of this business%');
  perform tests.as_anon();
  perform tests.throws(format('select public.practice_activity(%L)', c), '42501: permission denied%');
  perform tests.throws(format('select public.org_activity(%L)', o), '42501: permission denied%');
  perform tests.as_postgres();
end $$;

-- test: activity_helpers_revoked
do $$
declare f text;
begin
  foreach f in array array['private.activity_event(uuid, text, text, jsonb)', 'private.activity_row()', 'private.redact(jsonb)', 'private.redact_key(text)',
    'private.set_actor(uuid)', 'private.activity_attach(regclass)', 'private.activity_exempt()', 'private.activity_guard()',
    'private.activity_add(uuid, uuid, text, text, text, text, text, jsonb, jsonb, text[])', 'private.activity_page(uuid, uuid, jsonb)'] loop
    assert not has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute'),
      format('activity_helpers_revoked: %s', f);
  end loop;
  assert has_function_privilege('authenticated', 'public.practice_activity(uuid, jsonb)', 'execute')
     and has_function_privilege('authenticated', 'public.org_activity(uuid, jsonb)', 'execute')
     and not has_function_privilege('anon', 'public.practice_activity(uuid, jsonb)', 'execute')
     and not has_function_privilege('anon', 'public.org_activity(uuid, jsonb)', 'execute'),
    'activity_helpers_revoked: the reads are for signed-in people';
  assert not has_table_privilege('authenticated', 'public.activity_log', 'select') and not has_table_privilege('anon', 'public.activity_log', 'select')
     and not has_table_privilege('authenticated', 'public.activity_log', 'insert'),
    'activity_helpers_revoked: the table';
  assert (select relrowsecurity from pg_class where oid = 'public.activity_log'::regclass), 'activity_helpers_revoked: row level security on';
  perform tests.as_postgres();
end $$;

rollback;
