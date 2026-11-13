-- Practice management, part 12: the admin portal's mandates page, and the last fixes of the full mandate.
--
-- 1. A handover TaxStreem has approved is no longer a handover review: review_identity drops the identity's reason
--    'handover' when it approves (the handover's own record, identity.handover, stays), so a later NIN slip of the business
--    is reviewed as any slip, not as a handover.
-- 2. A 'handover' flag is not resolved by hand while its handover waits for TaxStreem or was rejected: the identity review
--    decides it (and resolves the flag when it approves).
-- 3. The admin mandates read also gives each open handover flag the business's identity as it stands now (status, whether
--    the handover still waits, and the status before it), and the mandates setting (the extra free-mail domains).
-- 4. Admins edit the mandates setting: the free-mail domains anyone can have an address on, beyond the built-in list
--    (admin_mandate_settings_save).
-- 5. The admin businesses list marks a business a practice runs under full mandate, one kept read-only after its
--    engagement ended, and one whose handover waits for TaxStreem (mandate).
-- 6. A letter whose stored file no longer matches the fingerprint recorded when the firm signed it is recorded as an event
--    of the letter (document_changed, a kind private.letter_event now takes), and the firm's leads are told, by the practice edge function
--    (svc_letter_changed), instead of only in the function's log.
--
-- Redefined functions are their latest definitions with only the changes described at each one; signatures are unchanged,
-- so create or replace keeps every grant.

-- ---------------------------------------------------------------------------
-- 1. review_identity
-- ---------------------------------------------------------------------------
-- Latest definition (20261124000900_mandate_end_handover.sql); approving a handover also drops the reason 'handover'.
create or replace function public.review_identity(p_org uuid, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; v_handover boolean; v_status text;
begin
  if not private.is_reviewer() then raise exception 'Only TaxStreem reviewers decide this.' using errcode = '42501'; end if;
  select * into o from orgs where id = p_org for update;
  if not found then raise exception 'Business not found.'; end if;
  if o.identity_status not in ('review', 'approved', 'rejected') then raise exception 'There is nothing to review for %.', o.name; end if;
  if not p_approve and length(trim(coalesce(p_note, ''))) < 5 then raise exception 'Say why, so the business knows what to do next.'; end if;
  v_handover := coalesce(o.identity->>'reason' = 'handover', false);
  v_status := case when not p_approve then 'rejected'
    when v_handover and coalesce(o.identity->'handover'->>'status_before', '') not in ('verified', 'approved', 'not_required') then 'pending'
    else 'approved' end;
  update orgs set identity_status = v_status,
    identity = case when v_handover and p_approve then identity - 'reason' else identity end
      || jsonb_build_object('review', jsonb_build_object('approved', p_approve, 'note', nullif(left(trim(coalesce(p_note, '')), 500), ''),
      'at', now(), 'by', auth.uid()))
  where id = p_org;
  perform private.audit('review_identity', p_org::text, jsonb_build_object('approved', p_approve, 'note', nullif(trim(coalesce(p_note, '')), '')));
  if v_handover then
    update practice_mandate_flags set resolved_at = now(), resolved_by = auth.uid(),
      resolution_note = left('Identity review: approved' || coalesce('. ' || nullif(trim(p_note), ''), ''), 1000)
    where p_approve and kind = 'handover' and detail->>'org_id' = p_org::text and resolved_at is null;
    perform private.notify_perm(p_org, 'owner', 'identity',
      case when v_status = 'approved' then 'Payments are open' when v_status = 'pending' then 'TaxStreem checked the handover'
        else 'TaxStreem did not accept the handover' end,
      case when v_status = 'approved' then 'TaxStreem checked the handover of the business. Your wallet, payment links and payouts are ready.'
        when v_status = 'pending' then 'Confirm a director''s NIN in Settings, Business identity, to open payments.'
        else coalesce(nullif(trim(p_note), ''), 'Contact TaxStreem about it.') end, '/settings#identity', 'identity-' || p_org);
    return jsonb_build_object('status', v_status);
  end if;
  perform private.notify_perm(p_org, 'owner', 'identity', case when p_approve then 'Payments are open' else 'We could not confirm the NIN slip' end,
    case when p_approve then 'TaxStreem confirmed the director''s identity. Your wallet, payment links and payouts are ready.'
      else coalesce(nullif(trim(p_note), ''), 'Check the NIN slip and try again.') end, '/settings#identity', 'identity-' || p_org);
  return jsonb_build_object('status', case when p_approve then 'approved' else 'rejected' end);
end $$;

-- ---------------------------------------------------------------------------
-- 2. admin_mandate_flag_resolve
-- ---------------------------------------------------------------------------
-- Latest definition (20261124000900_mandate_end_handover.sql); a 'handover' flag whose handover TaxStreem has still to
-- decide, or rejected, is refused: the identity review decides it.
create or replace function public.admin_mandate_flag_resolve(p_id uuid, p_note text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_note text := trim(coalesce(p_note, '')); f public.practice_mandate_flags;
begin
  perform private.require_staff(false);
  if length(v_note) < 5 then raise exception 'Write a note of at least 5 characters.'; end if;
  if length(v_note) > 1000 then raise exception 'Keep the note under 1,000 characters.'; end if;
  select * into f from practice_mandate_flags where id = p_id for update;
  if f.id is null then raise exception 'Flag not found.'; end if;
  if f.resolved_at is not null then raise exception 'That flag is resolved already.'; end if;
  if f.kind = 'director_review' and exists (select 1 from practice_director_confirmations d
                                            where d.id = private.uuid_of(f.detail->>'confirmation_id') and d.status = 'review') then
    raise exception 'Accept or decline the director''s confirmation instead.';
  end if;
  if f.kind = 'handover' and exists (select 1 from orgs o where o.id = private.uuid_of(f.detail->>'org_id')
                                     and private.handover_pending(o.identity_status, o.identity)) then
    raise exception 'Decide the handover in the identity reviews instead.';
  end if;
  update practice_mandate_flags set resolved_at = now(), resolved_by = auth.uid(), resolution_note = v_note where id = f.id
  returning * into f;
  perform private.audit('mandate_flag_resolved', f.id::text, jsonb_build_object('kind', f.kind, 'practice_id', f.practice_id, 'note', v_note));
  return jsonb_build_object('id', f.id, 'resolved_at', f.resolved_at);
end $$;

-- ---------------------------------------------------------------------------
-- 3. admin_mandates
-- ---------------------------------------------------------------------------
-- Latest definition (20261124000900_mandate_end_handover.sql); each open 'handover' flag also with the business's identity
-- now (identity: {status, pending: the handover still waits for TaxStreem or was rejected, status_before}); and the
-- mandates setting (settings: {free_mail_domains}, the extra domains only).
create or replace function public.admin_mandates() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_staff(false);
  return jsonb_build_object(
    'reviews', (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'status', d.status, 'created_at', d.created_at,
        'practice', jsonb_build_object('id', pr.id, 'name', pr.name),
        'business', jsonb_build_object('client_id', c.id, 'org_id', c.org_id, 'name', coalesce(o.name, c.business_name)),
        'director', jsonb_build_object('name', d.name, 'email', d.email, 'phone', d.phone),
        'ip', d.ip, 'ua', d.ua, 'reason', d.flags->>'review_reason') order by d.created_at, d.id), '[]'::jsonb)
      from practice_director_confirmations d join practices pr on pr.id = d.practice_id
      join practice_clients c on c.id = d.client_id left join orgs o on o.id = c.org_id
      where d.status = 'review'),
    'practices', (select coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'name', pr.name,
        'full_clients', (select count(*) from practice_clients c where c.practice_id = pr.id and c.mode = 'full' and c.status = 'active'),
        'suspended_at', pr.mandate_suspended_at, 'partner_verified', private.partner_verified(pr.id)) order by pr.name, pr.id), '[]'::jsonb)
      from practices pr
      where private.partner_verified(pr.id) or pr.mandate_suspended_at is not null
        or exists (select 1 from practice_clients c where c.practice_id = pr.id and c.mode = 'full')),
    'flags', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'kind', f.kind, 'detail', f.detail, 'created_at', f.created_at,
        'practice', jsonb_build_object('id', pr.id, 'name', pr.name),
        'intake', case when i.id is not null then jsonb_build_object('id', i.id, 'legal_name', i.legal_name, 'rc_number', i.rc_number, 'tax_id', i.tax_id) end,
        'business', case when c.id is not null then jsonb_build_object('client_id', c.id, 'org_id', c.org_id, 'name', coalesce(o.name, c.business_name)) end,
        'identity', case when f.kind = 'handover' then (select jsonb_build_object('status', ho.identity_status,
            'pending', private.handover_pending(ho.identity_status, ho.identity), 'status_before', f.detail->>'identity_before')
          from orgs ho where ho.id = private.uuid_of(f.detail->>'org_id')) end)
        order by f.created_at desc, f.id), '[]'::jsonb)
      from practice_mandate_flags f join practices pr on pr.id = f.practice_id
      left join practice_intakes i on i.id = f.intake_id
      left join practice_clients c on c.id = f.client_id left join orgs o on o.id = c.org_id
      where f.resolved_at is null),
    'settings', jsonb_build_object('free_mail_domains',
      case when jsonb_typeof(coalesce(private.setting('mandates'), '{}')->'free_mail_domains') = 'array'
           then coalesce(private.setting('mandates'), '{}')->'free_mail_domains' else '[]'::jsonb end));
end $$;

-- ---------------------------------------------------------------------------
-- 4. The mandates setting
-- ---------------------------------------------------------------------------
-- An admin sets the extra free-mail domains (p = {free_mail_domains: [...]}): each a domain name (letters, digits, dots and
-- hyphens, a dot in it, 4 to 253 characters), stored lower case without a leading @, at most 200, no duplicates. An address
-- on one of them never counts as the firm's. Audited. The setting as saved.
create or replace function public.admin_mandate_settings_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_list text[] := '{}'; d text; v_new jsonb; v_old jsonb;
begin
  perform private.require_staff(true);
  if jsonb_typeof(p) is distinct from 'object' or jsonb_typeof(p->'free_mail_domains') is distinct from 'array' then
    raise exception 'Send the free-mail domains as a list.';
  end if;
  if jsonb_array_length(p->'free_mail_domains') > 200 then raise exception 'At most 200 domains.'; end if;
  for d in select ltrim(lower(trim(x)), '@') from jsonb_array_elements_text(p->'free_mail_domains') x loop
    if d = '' then continue; end if;
    if length(d) not between 4 and 253 or d !~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' then
      raise exception '"%" is not a domain name, such as mail.example.com.', left(d, 80);
    end if;
    if not d = any (v_list) then v_list := v_list || d; end if;
  end loop;
  v_old := private.setting('mandates');
  v_new := coalesce(v_old, '{}'::jsonb) || jsonb_build_object('free_mail_domains', to_jsonb(v_list));
  insert into platform_settings (key, value, updated_by, updated_at) values ('mandates', v_new, auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  perform private.audit('save_mandates', 'mandates', jsonb_build_object('from', v_old, 'to', v_new));
  return v_new;
end $$;

-- ---------------------------------------------------------------------------
-- 5. admin_businesses
-- ---------------------------------------------------------------------------
-- Latest definition (20261025000100_admin_portal.sql); each business also with mandate: null for an ordinary one, else
-- {practice: the name of the practice running it, read_only_at, retain_until, handover_review: a handover waiting for
-- TaxStreem or rejected}.
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
        'last_activity', (select max(j.created_at) from journals j where j.org_id = b.id),
        'mandate', case when b.managed_by is not null or b.read_only_at is not null or private.handover_pending(b.identity_status, b.identity) then jsonb_build_object(
          'practice', (select name from practices where id = coalesce(b.managed_by,
            (select pc.practice_id from practice_clients pc where pc.org_id = b.id and pc.mode = 'full' and pc.end_kind = 'ended' order by pc.ended_at desc nulls last limit 1)))
          , 'read_only_at', b.read_only_at, 'retain_until', b.retain_until,
          'handover_review', private.handover_pending(b.identity_status, b.identity)) end) r
      from base b order by b.created_at desc limit greatest(1, least(p_limit, 200)) offset greatest(p_offset, 0)) x), '[]'::jsonb)
  into v_total, v_rows from base;
  return jsonb_build_object('total', v_total, 'rows', v_rows);
end $$;

-- ---------------------------------------------------------------------------
-- 6. A letter whose stored file changed
-- ---------------------------------------------------------------------------
alter table public.engagement_letter_events drop constraint if exists engagement_letter_events_kind_check;
alter table public.engagement_letter_events add constraint engagement_letter_events_kind_check
  check (kind in ('drafted', 'partner_signed', 'sent', 'opened', 'code_sent', 'code_failed', 'signed', 'uploaded', 'voided', 'document_changed'));

-- Latest definition (20261124000700_engagement_letters.sql), with the kind document_changed.
create or replace function private.letter_event(p_letter uuid, p_kind text, p_actor text, p_ip text, p_ua text, p_detail jsonb default '{}')
returns void
language plpgsql set search_path = public, private as $$
declare v_org uuid; v_practice uuid;
begin
  if coalesce(p_kind, '') not in ('drafted', 'partner_signed', 'sent', 'opened', 'code_sent', 'code_failed', 'signed', 'uploaded', 'voided', 'document_changed') then
    raise exception 'Unknown letter event kind: %.', p_kind;
  end if;
  insert into engagement_letter_events (letter_id, kind, actor, ip, ua, detail)
  values (p_letter, p_kind, left(nullif(trim(p_actor), ''), 120), left(nullif(trim(p_ip), ''), 64), left(nullif(p_ua, ''), 300), coalesce(p_detail, '{}'));
  select l.practice_id, coalesce(pc.org_id, x.org_id) into v_practice, v_org
  from engagement_letters l
  left join practice_clients pc on pc.id = l.client_id
  left join practice_intakes x on x.id = l.intake_id
  where l.id = p_letter;
  if v_org is not null then
    perform private.activity_event(v_org, 'letter_' || p_kind, case p_kind
        when 'drafted' then 'Engagement letter drafted'
        when 'partner_signed' then 'Engagement letter signed by the firm'
        when 'sent' then 'Engagement letter sent for signature'
        when 'opened' then 'Engagement letter opened by the client'
        when 'code_sent' then 'Engagement letter signing code sent'
        when 'code_failed' then 'Engagement letter signing code entered wrongly'
        when 'signed' then 'Engagement letter signed by the client'
        when 'uploaded' then 'Engagement letter signed copy uploaded'
        when 'document_changed' then 'Engagement letter refused for signing: its stored copy changed'
        else 'Engagement letter voided' end,
      jsonb_build_object('letter_id', p_letter, 'practice_id', v_practice));
  end if;
end $$;

-- The practice edge function found, as a signer was signing, that the letter's stored file no longer has the SHA-256
-- recorded when the firm signed it (p_found: the one it has now, 64 hex characters): an event of the letter with the
-- signer's IP address and browser, and the firm's leads told (once a day for a letter). Nothing else changes: the signing
-- was refused. {ok}.
create or replace function public.svc_letter_changed(p_letter uuid, p_found text, p_ip text, p_ua text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.engagement_letters; v_found text := lower(trim(coalesce(p_found, '')));
begin
  select * into l from engagement_letters where id = p_letter;
  if l.id is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_found !~ '^[0-9a-f]{64}$' then v_found := null; end if;
  perform private.letter_event(l.id, 'document_changed', 'Counta', left(p_ip, 64), left(p_ua, 300),
    jsonb_build_object('expected', l.doc_sha256, 'found', v_found));
  if not exists (select 1 from engagement_letter_events e where e.letter_id = l.id and e.kind = 'document_changed'
                 and e.at > now() - interval '1 day' and e.id < (select max(id) from engagement_letter_events where letter_id = l.id)) then
    perform private.practice_notify(l.practice_id, 'An engagement letter could not be signed',
      'The stored copy of "' || left(l.title, 80) || '" no longer matches the one the firm signed, so the signing was refused. Void it and send it again.',
      '/practice/letters');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- 7. Grants
-- ---------------------------------------------------------------------------
revoke execute on function public.admin_mandate_settings_save(jsonb) from public, anon;
grant execute on function public.admin_mandate_settings_save(jsonb) to authenticated;
revoke all on function public.svc_letter_changed(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.svc_letter_changed(uuid, text, text, text) to service_role;
