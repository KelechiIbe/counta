-- Deleting a business for good, from the admin portal (docs/deleting-a-business.md).
--
-- An admin (never a reviewer) deletes a business with everything in it. The people who belong to no other business lose
-- their logins as well, so the same email can sign up again from the start. Anyone who is also in another business, in an
-- accountant practice, or on TaxStreem's own team keeps their login. The sample businesses of the people who lose their
-- logins go with them. Nothing is deleted while any of the business's wallets holds money, or while money is on its way in
-- or out.
--
-- The database part is one transaction (admin_business_delete). The admin server function then removes the files, the
-- logins, the bank feeds at Mono and any WhatsApp number the business linked on OpenWA. Whatever it could not finish stays
-- on the audit line as pending, and Try again finishes it (svc_business_delete_pending, svc_business_delete_done).

-- ---------------------------------------------------------------------------
-- 1. What deleting a business would take with it
-- ---------------------------------------------------------------------------
create or replace function private.business_purge_plan(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; v_people jsonb; v_removed uuid[]; v_orgs uuid[]; v_samples jsonb; v_blockers text[] := '{}'; v_moving text[];
  w record; v_bal numeric;
begin
  select * into o from orgs where id = p_org;
  if not found then return null; end if;

  -- Everyone with a login in the business, and whether that login stays.
  with ppl as (
    select distinct on (m.user_id) m.user_id, coalesce(nullif(trim(m.display_name), ''), u.email) as name, coalesce(u.email, m.email) as email, m.role,
      exists (select 1 from platform_admins a where a.user_id = m.user_id) or exists (select 1 from platform_reviewers r where r.user_id = m.user_id) as staff,
      exists (select 1 from practice_members pm where pm.user_id = m.user_id and pm.status <> 'disabled') as accountant,
      (select string_agg(o2.name, ', ' order by o2.name) from members m2 join orgs o2 on o2.id = m2.org_id
        where m2.user_id = m.user_id and m2.org_id <> p_org and not o2.is_sample and m2.status <> 'disabled') as elsewhere
    from members m left join auth.users u on u.id = m.user_id
    where m.org_id = p_org and m.user_id is not null
    order by m.user_id, case m.role when 'owner' then 0 else 1 end
  )
  select coalesce(jsonb_agg(jsonb_build_object('user_id', user_id, 'name', name, 'email', email, 'role', role,
      'login', case when staff or accountant or elsewhere is not null then 'kept' else 'removed' end,
      'why', case when staff then 'On TaxStreem''s team' when elsewhere is not null then 'Also in ' || elsewhere
                  when accountant then 'In an accountant practice' end) order by (role = 'owner') desc, name), '[]'::jsonb),
    coalesce(array_agg(user_id) filter (where not staff and not accountant and elsewhere is null), '{}')
  into v_people, v_removed from ppl;

  -- Sample businesses that belong only to people whose logins go.
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name), '[]'::jsonb), coalesce(array_agg(s.id), '{}')
  into v_samples, v_orgs
  from orgs s
  where s.is_sample and s.id <> p_org
    and (s.created_by = any(v_removed) or exists (select 1 from members m where m.org_id = s.id and m.user_id = any(v_removed)))
    and not exists (select 1 from members m where m.org_id = s.id and m.user_id is not null and m.status <> 'disabled' and not (m.user_id = any(v_removed)));
  v_orgs := array_prepend(p_org, v_orgs);

  -- Money held: the books' balance of each wallet, and the last balance the bank reported.
  for w in select 'The wallet' as what, x.id, x.bank_name, x.account_number, private.wallet_ledger(x.id) as books,
             greatest(coalesce(x.provider_available, 0), coalesce(x.provider_ledger, 0)) as bank from wallets x where x.org_id = any(v_orgs)
           union all
           select 'The tax wallet', t.id, t.bank_name, t.account_number, private.tax_wallet_ledger(t.id), greatest(coalesce(t.provider_available, 0), coalesce(t.provider_ledger, 0))
           from tax_wallets t where t.org_id = any(v_orgs) loop
    v_bal := greatest(abs(coalesce(w.books, 0)), coalesce(w.bank, 0));
    if v_bal > 0 then
      v_blockers := v_blockers || format('%s%s holds NGN %s. Move the money out first.', w.what,
        case when w.account_number is not null then format(' (%s %s)', coalesce(w.bank_name, ''), w.account_number) else '' end, to_char(v_bal, 'FM999,999,999,990.00'));
    end if;
  end loop;
  v_moving := array_remove(array[
    case when exists (select 1 from payouts where org_id = any(v_orgs) and status in ('approved', 'processing')) then 'a payout being sent' end,
    case when exists (select 1 from payout_batches where org_id = any(v_orgs) and status in ('approved', 'sending')) then 'a bulk payment being sent' end,
    case when exists (select 1 from tax_moves where org_id = any(v_orgs) and status in ('pending', 'sending')) then 'money moving between the wallets' end,
    case when exists (select 1 from tax_transfers where org_id = any(v_orgs) and status in ('pending', 'sent')) then 'a transfer to the tax wallet' end,
    case when exists (select 1 from tax_payments where org_id = any(v_orgs) and status in ('approved', 'processing'))
           or exists (select 1 from tax_payment_instructions where org_id = any(v_orgs) and status = 'paying') then 'a tax payment being made' end,
    case when exists (select 1 from subscription_charges where org_id = any(v_orgs) and status in ('pending', 'sent')) then 'a subscription payment' end], null);
  if array_length(v_moving, 1) > 0 then
    v_blockers := v_blockers || format('Money is on its way: %s. Wait until it has landed.', array_to_string(v_moving, ', '));
  end if;
  if o.is_sample then v_blockers := v_blockers || 'This is a sample business. It goes when its owner''s business is deleted.'::text; end if;

  return jsonb_build_object(
    'org', jsonb_build_object('id', o.id, 'name', o.name, 'is_sample', o.is_sample, 'created_at', o.created_at, 'rc_number', o.rc_number, 'tin', o.tin),
    'people', v_people,
    'invited', (select count(*) from members where org_id = p_org and user_id is null and status <> 'disabled'),
    'removed', to_jsonb(v_removed),
    'samples', v_samples,
    'orgs', to_jsonb(v_orgs),
    'counts', jsonb_build_object(
      'sales', (select count(*) from sales where org_id = p_org),
      'bills', (select count(*) from bills where org_id = p_org),
      'customers', (select count(*) from customers where org_id = p_org),
      'vendors', (select count(*) from vendors where org_id = p_org),
      'items', (select count(*) from items where org_id = p_org),
      'journals', (select count(*) from journals where org_id = p_org),
      'branches', (select count(*) from locations where org_id = p_org),
      'files', (select count(*) from storage.objects so where so.bucket_id in ('documents', 'item-photos')
                and split_part(so.name, '/', 1) = any(select x::text from unnest(v_orgs) x)),
      'bank_feeds', (select count(*) from bank_accounts where org_id = any(v_orgs) and provider = 'mono' and provider_ref is not null),
      'tools', (select count(*) from integrations where org_id = any(v_orgs))),
    'mono', (select coalesce(jsonb_agg(provider_ref), '[]'::jsonb) from bank_accounts where org_id = any(v_orgs) and provider = 'mono' and provider_ref is not null),
    'whatsapp', (select coalesce(jsonb_agg(id), '[]'::jsonb) from whatsapp_sessions where org_id = any(v_orgs) and kind <> 'counta'),
    'blockers', to_jsonb(v_blockers),
    'can_delete', coalesce(array_length(v_blockers, 1), 0) = 0);
end $$;

-- What the admin sees before deleting: the business, who loses their login and who keeps it, what goes, and anything that
-- stops it. Internal lists (ids at Mono and OpenWA) are left out.
create or replace function public.admin_business_delete_preview(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v jsonb;
begin
  perform private.require_staff();
  v := private.business_purge_plan(p_org);
  if v is null then raise exception 'This business is no longer on Counta.'; end if;
  return v - 'mono' - 'whatsapp' - 'removed' - 'orgs';
end $$;

-- ---------------------------------------------------------------------------
-- 2. Deleting it
-- ---------------------------------------------------------------------------
-- p_confirm: the business's name, typed by the admin. Everything the business owns goes in this one transaction: the rows
-- in every table that points at it (the ones that would otherwise be kept with an empty business, too), and the keys its
-- tools kept in Vault. Answers what the server function still has to do outside the database.
create or replace function public.admin_business_delete(p_org uuid, p_confirm text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_staff(); o public.orgs; v jsonb; v_org uuid; r record; v_audit bigint; v_removed uuid[];
  norm text := lower(regexp_replace(trim(coalesce(p_confirm, '')), '\s+', ' ', 'g'));
begin
  select * into o from orgs where id = p_org for update;
  if not found then raise exception 'This business is no longer on Counta.'; end if;
  if norm = '' or norm <> lower(regexp_replace(trim(o.name), '\s+', ' ', 'g')) then
    raise exception 'Type the business''s name exactly as it shows, to confirm.';
  end if;
  v := private.business_purge_plan(p_org);
  if not (v->>'can_delete')::boolean then raise exception '%', v->'blockers'->>0; end if;
  select coalesce(array_agg(x::uuid), '{}') into v_removed from jsonb_array_elements_text(v->'removed') x;

  perform set_config('app.allow_purge', 'on', true);
  for v_org in select x::uuid from jsonb_array_elements_text(v->'orgs') x loop
    -- Keys its tools kept in Vault.
    delete from vault.secrets where id in (select secret_id from integrations where org_id = v_org and secret_id is not null
                                           union select hook_secret_id from integrations where org_id = v_org and hook_secret_id is not null);
    -- Tables that keep their rows (with no business) when a business goes: deleted here, so nothing of it stays behind.
    for r in select c.conrelid::regclass as tbl, a.attname as col from pg_constraint c
             join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
             where c.contype = 'f' and c.confrelid = 'public.orgs'::regclass and c.confdeltype <> 'c' and cardinality(c.conkey) = 1 loop
      execute format('delete from %s where %I = $1', r.tbl, r.col) using v_org;
    end loop;
    delete from orgs where id = v_org;
  end loop;
  perform set_config('app.allow_purge', 'off', true);

  insert into admin_audit (user_id, action, target, detail)
  values (v_uid, 'delete_business', p_org::text, jsonb_build_object('name', o.name,
    'logins_removed', cardinality(v_removed), 'logins_kept', (select count(*) from jsonb_array_elements(v->'people') p where p->>'login' = 'kept'),
    'samples', jsonb_array_length(v->'samples'), 'counts', v->'counts',
    'pending', jsonb_build_object('users', to_jsonb(v_removed), 'orgs', v->'orgs', 'mono', v->'mono', 'whatsapp', v->'whatsapp')))
  returning id into v_audit;
  return jsonb_build_object('ok', true, 'audit_id', v_audit, 'name', o.name, 'logins', cardinality(v_removed));
end $$;

-- ---------------------------------------------------------------------------
-- 3. What the server function finishes outside the database
-- ---------------------------------------------------------------------------
-- What is still to do for a deletion: logins (only those still in no business and not staff), files by bucket (up to 1,000
-- at a time), bank feeds at Mono and WhatsApp numbers on OpenWA.
create or replace function public.svc_business_delete_pending(p_audit bigint) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare d jsonb; v_orgs text[];
begin
  select detail->'pending' into d from admin_audit where id = p_audit and action = 'delete_business';
  if d is null then return null; end if;
  select coalesce(array_agg(x), '{}') into v_orgs from jsonb_array_elements_text(d->'orgs') x;
  return jsonb_build_object(
    'users', (select coalesce(jsonb_agg(u.id), '[]'::jsonb) from auth.users u
              where u.id in (select x::uuid from jsonb_array_elements_text(d->'users') x)
                and not exists (select 1 from members m where m.user_id = u.id and m.status <> 'disabled')
                and not exists (select 1 from practice_members pm where pm.user_id = u.id and pm.status <> 'disabled')
                and not exists (select 1 from platform_admins a where a.user_id = u.id)
                and not exists (select 1 from platform_reviewers r where r.user_id = u.id)),
    'files', (select coalesce(jsonb_agg(jsonb_build_object('bucket', f.bucket_id, 'name', f.name)), '[]'::jsonb) from (
              select so.bucket_id, so.name from storage.objects so
              where so.bucket_id in ('documents', 'item-photos') and split_part(so.name, '/', 1) = any(v_orgs) limit 1000) f),
    'mono', coalesce(d->'mono', '[]'::jsonb),
    'whatsapp', coalesce(d->'whatsapp', '[]'::jsonb));
end $$;

-- p: {logins, files, mono, whatsapp, errors, pending}: what was done this time, and what is left (pending true or false).
create or replace function public.svc_business_delete_done(p_audit bigint, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v jsonb;
begin
  update admin_audit set detail = (detail - 'result') || jsonb_build_object('result', jsonb_build_object(
      'logins', coalesce((detail->'result'->>'logins')::int, 0) + coalesce((p->>'logins')::int, 0),
      'files', coalesce((detail->'result'->>'files')::int, 0) + coalesce((p->>'files')::int, 0),
      'mono', coalesce((detail->'result'->>'mono')::int, 0) + coalesce((p->>'mono')::int, 0),
      'whatsapp', coalesce((detail->'result'->>'whatsapp')::int, 0) + coalesce((p->>'whatsapp')::int, 0),
      'errors', coalesce(p->'errors', '[]'::jsonb), 'at', now()))
    || case when coalesce((p->>'pending')::boolean, false) then '{}'::jsonb else jsonb_build_object('finished', true) end
  where id = p_audit and action = 'delete_business'
  returning detail into v;
  -- Once finished, the lists of ids are dropped: nothing about the business stays but its name and the counts.
  if v ? 'finished' then update admin_audit set detail = detail - 'pending' where id = p_audit returning detail into v; end if;
  return v - 'pending';
end $$;

-- Deletions the server function could not finish, for the admin portal to offer Try again.
create or replace function public.admin_business_deletions() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_staff();
  return (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'at', a.at, 'name', a.detail->>'name', 'by', u.email, 'result', a.detail->'result')
      order by a.at desc), '[]'::jsonb)
    from admin_audit a left join auth.users u on u.id = a.user_id
    where a.action = 'delete_business' and a.detail ? 'pending');
end $$;

-- ---------------------------------------------------------------------------
-- 4. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function private.business_purge_plan(uuid) from public, anon, authenticated;
revoke all on function public.admin_business_delete_preview(uuid), public.admin_business_delete(uuid, text), public.admin_business_deletions() from public, anon;
grant execute on function public.admin_business_delete_preview(uuid), public.admin_business_delete(uuid, text), public.admin_business_deletions() to authenticated;
revoke all on function public.svc_business_delete_pending(bigint), public.svc_business_delete_done(bigint, jsonb) from public, anon, authenticated;
grant execute on function public.svc_business_delete_pending(bigint), public.svc_business_delete_done(bigint, jsonb) to service_role;
