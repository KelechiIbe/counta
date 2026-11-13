-- Practice management, part 13: fixes found in review, and three product rules.
--
-- Fixes
-- 1. A business with posted entries deleted directly (not from the admin portal) is refused with a plain answer, instead of
--    failing on a column the journals table does not have (guard_journals read journal_lines' party_id for every table).
-- 2. Changing the role of an admin (or anyone) to a role that may not edit prices writes the new role and its permissions
--    in one update, so the members check (sales_cannot_edit) never sees the new role with the old permissions.
-- 3. require_not_managed answers only the business's own people: someone outside it is refused by the caller's own check
--    ("not a member"), not told whether the business is run by a firm.
-- 4. Company numbers: an RC number and a BN number with the same digits are different companies (same_reg), in the
--    conflicts check, in company_taken and in kyc_submit. Company names are compared word by word: a short name inside a
--    longer word ("Bisi" in "Olubisi Foods") is no longer a match.
-- 5. kyc_submit: an org_id that is not a UUID gets a plain answer; the owner check comes before anything else for an
--    existing business (so nobody else can raise a flag on it).
-- 6. Messages: the full-mandate gate runs before the plan's limits (messages_gate, renamed from messages_suppress), and a
--    message not sent is not held to the limits at all, so it raises no "80% used" or "past your limit" notice. The admin
--    average usage leaves out messages not sent, as each business's own usage does.
-- 7. Signing for the firm: practice_letter_prepare gives the letter's fingerprint (its content, the firm's details and the
--    time it last changed), and svc_letter_frozen refuses a letter that changed after it was prepared, so the file the
--    partner signs is the letter as it stands.
-- 8. An intake ending its engagement is kept for the longest of the client's retention years and those of its letters
--    signed or sent (letters default to six years; the client link to five).
--
-- Product rules
-- 9. A prospect the firm refused after its conflicts check does not become its client another way: a link the business
--    starts, or a referral link, is refused when the practice has a declined intake for the same business (the same
--    business, RC number or Tax ID).
-- 10. An ordinary owner who submits the profile of a company a practice already runs under full mandate is refused (no
--    business is made), and TaxStreem is flagged (duplicate_company, source 'owner').
-- 11. Ongoing due diligence: the intake of a client the firm has taken on can be updated by its leads (not the way the firm
--    works with it, and the authority declared stays). Each change keeps the intake as it was before in its history
--    (practice_intake_history), and a change to the name, numbers or people needs the conflicts check again (the client is
--    marked "due diligence incomplete" until then). Only an intake with a retention date (the engagement ended, refused,
--    or the business deleted) is kept as it is.
-- 12. Credit notes on fee invoices: a credit note against a fee invoice whose bill is posted in a full-mandate client's
--    books waits for a lead of the practice to confirm it (practice_fee_credits, pending); confirming records it as a
--    supplier credit note against the bill in the client's books (record_vendor_credit, as the lead), dismissing it (a
--    partner, with a reason) leaves the books alone. The fees overview lists them.
--
-- Redefined functions are their latest definitions with only the changes described at each one; signatures are unchanged,
-- so create or replace keeps every grant.

-- ---------------------------------------------------------------------------
-- 1. Posted journals
-- ---------------------------------------------------------------------------
-- Latest definition (20261018000900_advisor_fixes.sql). The party tagging exception is read only for journal_lines; a
-- journal or line deleted with its business (the business row already gone) is refused with how to delete a business.
create or replace function private.guard_journals() returns trigger
language plpgsql set search_path = public, private as $$
begin
  if coalesce(current_setting('app.allow_purge', true), '') = 'on' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if tg_op = 'UPDATE' and tg_table_name = 'journal_lines' then
    if coalesce(current_setting('app.tag_party', true), '') = 'on'
       and old.party_id is null and new.journal_id = old.journal_id and new.account_code = old.account_code and new.debit = old.debit
       and new.credit = old.credit and new.org_id = old.org_id and new.location_id is not distinct from old.location_id
       and new.item_id is not distinct from old.item_id then
      return new;
    end if;
  end if;
  if tg_op = 'DELETE' and not exists (select 1 from orgs where id = old.org_id) then
    raise exception 'A business with posted entries is deleted from the admin portal, which keeps the records the law requires.';
  end if;
  raise exception 'Posted journals cannot be changed. Post a reversing entry instead.';
end $$;

-- ---------------------------------------------------------------------------
-- 2. Changing a person's role
-- ---------------------------------------------------------------------------
-- Latest definition (20261024000100_team_identity_martina.sql). The role, the exceptions and the permission columns are
-- written in the one update (apply_member_perms after it changes nothing more).
create or replace function public.update_member(p_member uuid, p_patch jsonb) returns void
language plpgsql security definer set search_path = public, private as $$
declare t public.members; m public.members; v_role text; v_over jsonb; e jsonb; k text; v_set boolean;
begin
  select * into t from members where id = p_member;
  if not found then raise exception 'Person not found.'; end if;
  m := private.require(t.org_id, 'manage_team');
  if t.role = 'owner' and (p_patch ? 'role' or p_patch ? 'perms' or p_patch ? 'status' or p_patch ? 'reset_perms') then
    raise exception 'The owner keeps every permission.';
  end if;
  if t.id = m.id and not private.perm_of(m, 'owner') and (p_patch ? 'role' or p_patch ? 'perms' or p_patch ? 'status' or p_patch ? 'reset_perms') then
    raise exception 'Ask the owner to change your own role or permissions.' using errcode = '42501';
  end if;
  if t.role = 'admin' and not private.perm_of(m, 'owner') and (p_patch ? 'role' or p_patch ? 'perms' or p_patch ? 'status' or p_patch ? 'reset_perms') then
    raise exception 'Only the owner changes an admin.' using errcode = '42501';
  end if;
  v_role := coalesce(p_patch->>'role', t.role);
  if v_role not in ('owner', 'admin', 'manager', 'staff', 'cashier', 'accountant') then raise exception 'Unknown role.'; end if;
  if v_role = 'owner' and t.role <> 'owner' then raise exception 'Ownership transfer is not available here.'; end if;
  if v_role = 'admin' and t.role <> 'admin' and not private.perm_of(m, 'owner') then raise exception 'Only the owner makes someone an admin.' using errcode = '42501'; end if;
  if coalesce(p_patch->>'status', t.status) not in ('active', 'invited', 'disabled') then raise exception 'Unknown status.'; end if;
  if p_patch->>'status' = 'active' and t.status = 'invited' then raise exception '% joins by accepting the invitation.', t.display_name; end if;

  -- Their own exceptions: what differs from the role. A new role starts clean unless permissions come with it.
  v_over := case when v_role <> t.role and not (p_patch ? 'perms') then '{}'::jsonb else private.clean_perms(t.perm_overrides) end;
  if coalesce((p_patch->>'reset_perms')::boolean, false) then v_over := '{}'::jsonb; end if;
  if p_patch ? 'perms' then
    e := private.role_perms(t.org_id, v_role) || v_over || private.clean_perms(p_patch->'perms');
    v_over := '{}'::jsonb;
    foreach k in array private.perm_keys() loop
      if e->k is distinct from private.role_perms(t.org_id, v_role)->k then v_over := v_over || jsonb_build_object(k, e->k); end if;
    end loop;
  end if;
  e := private.role_perms(t.org_id, v_role) || v_over;
  if v_role <> 'owner' then
    perform private.check_grantable(m, e);
    perform private.check_split(v_role, e, t.display_name);
  end if;
  v_set := v_role <> 'owner';
  update members set
    role = v_role,
    perm_overrides = v_over,
    p_record_sales = case when v_set then (e->>'record_sales')::boolean else p_record_sales end,
    p_edit_prices = case when v_set then (e->>'edit_prices')::boolean else p_edit_prices end,
    p_add_items = case when v_set then (e->>'add_items')::boolean else p_add_items end,
    p_receive_stock = case when v_set then (e->>'receive_stock')::boolean else p_receive_stock end,
    p_count_stock = case when v_set then (e->>'count_stock')::boolean else p_count_stock end,
    p_transfer_stock = case when v_set then (e->>'transfer_stock')::boolean else p_transfer_stock end,
    p_issue_stock = case when v_set then (e->>'issue_stock')::boolean else p_issue_stock end,
    p_approve_adjustments = case when v_set then (e->>'approve_adjustments')::boolean else p_approve_adjustments end,
    p_approve_pos = case when v_set then (e->>'approve_pos')::boolean else p_approve_pos end,
    p_make_payments = case when v_set then (e->>'make_payments')::boolean else p_make_payments end,
    p_approve_payments = case when v_set then (e->>'approve_payments')::boolean else p_approve_payments end,
    p_keep_books = case when v_set then (e->>'keep_books')::boolean else p_keep_books end,
    p_see_margins = case when v_set then (e->>'see_margins')::boolean else p_see_margins end,
    p_file_tax = case when v_set then (e->>'file_tax')::boolean else p_file_tax end,
    p_manage_team = case when v_set then (e->>'manage_team')::boolean else p_manage_team end,
    p_manage_settings = case when v_set then (e->>'manage_settings')::boolean else p_manage_settings end,
    display_name = coalesce(nullif(trim(p_patch->>'display_name'), ''), display_name),
    title = case when p_patch ? 'title' then nullif(trim(p_patch->>'title'), '') else title end,
    phone = case when p_patch ? 'phone' then nullif(trim(p_patch->>'phone'), '') else phone end,
    location_id = case when p_patch ? 'location_id' then nullif(p_patch->>'location_id', '')::uuid else location_id end,
    status = coalesce(p_patch->>'status', status)
  where id = p_member;
  if v_role <> 'owner' then perform private.apply_member_perms(p_member); end if;
  if p_patch->>'status' = 'disabled' then update member_invites set token_hash = null where member_id = p_member; end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Blocked under full mandate: for the business's own people only
-- ---------------------------------------------------------------------------
-- Latest definition (20261124000300_seats_guards.sql). Someone signed in who is not an active member of the business is
-- left to the caller's own check, which refuses them without saying how the business is run.
create or replace function private.require_not_managed(p_org uuid) returns void
language plpgsql stable set search_path = public, private as $$
begin
  if auth.uid() is not null
     and not exists (select 1 from members where org_id = p_org and user_id = auth.uid() and status = 'active') then
    return;
  end if;
  if private.is_managed(p_org) then
    raise exception 'Under full mandate this is done from the accountant portal.' using errcode = '42501';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Company numbers and names
-- ---------------------------------------------------------------------------
-- The registry a CAC number is from, by its prefix: RC (companies), BN (business names) or IT (incorporated trustees);
-- null when it has none.
create or replace function private.reg_kind(p text) returns text
language sql immutable set search_path = '' as $$
  select substring(regexp_replace(upper(coalesce(p, '')), '[^A-Z0-9]', '', 'g') from '^(RC|BN|IT)')
$$;

-- The same CAC number: the same digits, from the same registry when both say which (RC 123456 and BN 123456 are two
-- different businesses; RC 123456 and 123456 are taken as the same).
create or replace function private.same_reg(a text, b text) returns boolean
language sql immutable set search_path = public, private as $$
  select coalesce(private.norm_id(a) = private.norm_id(b)
    and (private.reg_kind(a) is null or private.reg_kind(b) is null or private.reg_kind(a) = private.reg_kind(b)), false)
$$;

-- Latest definition (20261124000800_mandate_gate.sql); the RC number compared with same_reg.
create or replace function private.company_taken(p_rc text, p_tax text, p_practice uuid, p_except uuid) returns jsonb
language plpgsql set search_path = public, private as $$
declare v_rc text := private.norm_id(p_rc); v_tax text := private.norm_id(p_tax); r jsonb;
begin
  perform private.company_lock(p_rc, p_tax);
  if v_rc is null and v_tax is null then return null; end if;
  select jsonb_build_object('org_id', o.id, 'matched_on', case when private.same_reg(o.rc_number, p_rc) then 'rc_number' else 'tax_id' end) into r
  from orgs o
  where o.id is distinct from p_except and not o.is_sample and (private.same_reg(o.rc_number, p_rc) or private.norm_id(o.tin) = v_tax)
    and ((o.managed_by is not null and o.managed_by is distinct from p_practice)
      or exists (select 1 from members x where x.org_id = o.id and x.role = 'owner' and x.status = 'active' and x.user_id is not null))
  order by o.created_at, o.id
  limit 1;
  return r;
end $$;

-- Latest definition (20261124000600_intake_conflicts.sql). Word by word, either way round, without accents: 1 when every
-- word that tells one name apart is in the other, and that name has two such words or one of six letters or more;
-- otherwise the share of the prospect's words found in the other name, or of the other's found in the prospect's when it
-- has two words or more. ("Zenith Paints Distribution Ltd" and "Zenith Paints Ltd": 1. "Bisi Ltd" and "Olubisi Foods":
-- 0, where a match by letters found one inside the other.)
create or replace function private.company_name_score(p_prospect text, p_other text) returns numeric
language sql immutable set search_path = public, private as $$
  select case
    when cardinality(a) = 0 or cardinality(b) = 0 then 0
    when (a <@ b and (cardinality(a) >= 2 or length(a[1]) >= 6)) or (b <@ a and (cardinality(b) >= 2 or length(b[1]) >= 6)) then 1.00
    else greatest(private.name_score(x, y), case when cardinality(b) >= 2 then private.name_score(y, x) else 0 end) end
  from (select private.fold_name(p_prospect) as x, private.fold_name(p_other) as y) z
  cross join lateral (select private.name_words(z.x) as a, private.name_words(z.y) as b) w
$$;

-- Latest definition (20261124000600_intake_conflicts.sql); the RC number compared with same_reg.
create or replace function private.conflict_scan(p_intake uuid) returns integer
language plpgsql set search_path = public, private as $$
declare i public.practice_intakes; v_books boolean; v_n integer;
begin
  select * into i from practice_intakes where id = p_intake;
  if not found then raise exception 'Intake not found.'; end if;
  select conflict_scan_books into v_books from practices where id = i.practice_id;
  delete from practice_conflict_hits where intake_id = i.id;
  with
  -- The prospect's people: first name, middle names and surname, without accents or titles.
  mine as (
    select p.name, z.t[1] as first, array_to_string(z.t[2:cardinality(z.t) - 1], ' ') as middle, z.t[cardinality(z.t)] as last
    from practice_intake_people p cross join lateral (select private.name_tokens(private.fold_name(p.name)) as t) z
    where p.intake_id = i.id and cardinality(z.t) > 0),
  -- The prospect's own name, read as a person's.
  me as (
    select z.t[1] as first, array_to_string(z.t[2:cardinality(z.t) - 1], ' ') as middle, z.t[cardinality(z.t)] as last
    from (select private.name_tokens(private.fold_name(i.legal_name)) as t) z
    where cardinality(z.t) > 0),
  -- The practice's parties: what they are, a name, an RC number and a Tax ID, and where they are recorded.
  parties as (
    -- Its clients whatever the state of the link: the business, the name on the link, and the client's intake (not the
    -- prospect's own link, nor an invitation that carries this intake).
    select 'client' as kind, v.name, v.rc, v.tax, pc.id as client_id, pc.intake_id, null::uuid as opposing_id
    from practice_clients pc
    left join orgs o on o.id = pc.org_id
    left join practice_intakes x on x.id = pc.intake_id and x.practice_id = i.practice_id
    cross join lateral (values (o.name, o.rc_number, o.tin), (pc.business_name, null, null), (x.legal_name, x.rc_number, x.tax_id)) v(name, rc, tax)
    where pc.practice_id = i.practice_id and pc.id is distinct from i.client_id and pc.intake_id is distinct from i.id and v.name is not null
    union all
    -- Its other intakes with no client link: prospects, and former clients whose business is gone.
    select case when x.status = 'engaged' then 'client' else 'prospect' end, x.legal_name, x.rc_number, x.tax_id, x.client_id, x.id, null
    from practice_intakes x
    where x.practice_id = i.practice_id and x.id <> i.id
      and not exists (select 1 from practice_clients pc where pc.intake_id = x.id and pc.practice_id = i.practice_id)
    union all
    select 'opposing_party', op.name, op.rc_number, null, op.client_id, null, op.id
    from practice_opposing_parties op where op.practice_id = i.practice_id
    union all
    -- Its active clients' customers and suppliers, when the firm asks for them.
    select 'books', cu.name, null, cu.tin, pc.id, null, null
    from practice_clients pc join customers cu on cu.org_id = pc.org_id
    where v_books and pc.practice_id = i.practice_id and pc.status = 'active' and pc.id is distinct from i.client_id
      and pc.intake_id is distinct from i.id and not cu.is_walk_in
    union all
    select 'books', ve.name, ve.rc_number, ve.tin, pc.id, null, null
    from practice_clients pc join vendors ve on ve.org_id = pc.org_id
    where v_books and pc.practice_id = i.practice_id and pc.status = 'active' and pc.id is distinct from i.client_id
      and pc.intake_id is distinct from i.id),
  matches as (
    select kind, 'rc_number' as matched_on, i.rc_number as subject, name as match_name, 1.00 as score, client_id, intake_id, opposing_id
    from parties where private.same_reg(rc, i.rc_number)
    union all
    select kind, 'tax_id', i.tax_id, name, 1.00, client_id, intake_id, opposing_id
    from parties where private.norm_id(tax) = private.norm_id(i.tax_id)
    union all
    select kind, 'name', i.legal_name, name, s.score, client_id, intake_id, opposing_id
    from parties cross join lateral (select private.company_name_score(i.legal_name, name) as score) s
    where s.score >= 0.75
    union all
    -- The prospect's people among the names of the clients, prospects and opposing parties.
    select p.kind, 'person', m.name, p.name, 1.00, p.client_id, p.intake_id, p.opposing_id
    from mine m join parties p on p.kind <> 'books'
    where private.identity_match(m.first, m.middle, m.last, jsonb_build_array(jsonb_build_object('name', private.fold_name(p.name)))) is not null
    union all
    -- ... and among the people recorded on the practice's other intakes.
    select 'related_party', 'person', m.name, rp.name, 1.00, x.client_id, x.id, null
    from mine m
    join practice_intake_people rp on rp.practice_id = i.practice_id and rp.intake_id <> i.id
    join practice_intakes x on x.id = rp.intake_id and x.practice_id = i.practice_id
    where private.identity_match(m.first, m.middle, m.last, jsonb_build_array(jsonb_build_object('name', private.fold_name(rp.name)))) is not null
    union all
    -- The prospect's own name among those people.
    select 'related_party', 'name', i.legal_name, rp.name, 1.00, x.client_id, x.id, null
    from me
    join practice_intake_people rp on rp.practice_id = i.practice_id and rp.intake_id <> i.id
    join practice_intakes x on x.id = rp.intake_id and x.practice_id = i.practice_id
    where private.identity_match(me.first, me.middle, me.last, jsonb_build_array(jsonb_build_object('name', private.fold_name(rp.name)))) is not null)
  insert into practice_conflict_hits (intake_id, practice_id, kind, matched_on, subject, match_name, score, source_client_id, source_intake_id, source_opposing_id)
  select distinct on (kind, matched_on, subject, client_id, intake_id, opposing_id)
    i.id, i.practice_id, kind, matched_on, subject, match_name, score, client_id, intake_id, opposing_id
  from matches
  order by kind, matched_on, subject, client_id, intake_id, opposing_id, score desc, match_name;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Submitting a business profile
-- ---------------------------------------------------------------------------
-- Latest definition (20261124000800_mandate_gate.sql), with:
--   * an org_id that is not a UUID refused plainly ("Choose the business.");
--   * for a profile of an existing business, the owner check first;
--   * the RC numbers compared with same_reg, the CAC record's number taken with its registry (from its classification
--     when the number has no prefix);
--   * an ordinary profile (not of a business a practice runs) of a company a practice runs under full mandate refused:
--     nothing is made, TaxStreem is flagged once while the flag is open (duplicate_company, source 'owner'), and the
--     answer is {ok: false, reason: 'managed_elsewhere'}.
create or replace function public.kyc_submit(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid(); k public.kyc_profiles; c jsonb; v_org uuid; v_name text; v_addr text; v_vat boolean; v_cat public.business_categories;
  v_form text; v_cls text; v_tin text; v_dir jsonb; v_display text; v_branch text; v_email text; v_state text; v_lga text; v_shares numeric;
  v_new boolean := false; v_for uuid; v_to jsonb; v_rc text; mc public.practice_clients; v_intake_rc text;
  v_dup jsonb; v_practice uuid; mo public.orgs; v_reg text;
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  v_for := private.uuid_of(p->>'org_id');
  if nullif(trim(coalesce(p->>'org_id', '')), '') is not null and v_for is null then raise exception 'Choose the business.'; end if;
  if v_for is not null and not private.is_owner(v_for) then
    raise exception 'Only the owner submits the business profile.' using errcode = '42501';
  end if;
  v_to := case when v_for is not null then jsonb_build_object('org_id', v_for) else '{}'::jsonb end;
  if p ? 'answers' then
    perform public.kyc_answer(case when jsonb_typeof(p->'answers') = 'object' then (p->'answers') || v_to else p->'answers' end);
  end if;
  if p ? 'charges_vat' then perform public.kyc_answer(jsonb_build_object('charges_vat', p->'charges_vat') || v_to); end if;
  k := private.kyc_row(v_uid, v_for);
  if v_for is not null and k.org_id is distinct from v_for then
    raise exception 'You have another business profile in progress. Finish it first, then come back to this business.';
  end if;
  if k.org_id is not null and not private.is_owner(k.org_id) then
    raise exception 'Only the owner submits the business profile.' using errcode = '42501';
  end if;
  if k.status = 'submitted' then raise exception 'This profile is already submitted.'; end if;
  if k.source is null then raise exception 'Find the business on CAC first, or tell us it is not registered.'; end if;
  if array_length(private.kyc_missing(k.answers), 1) > 0 then
    raise exception 'A few questions are still open: %.', array_to_string(private.kyc_missing(k.answers), ', ');
  end if;
  c := k.cac->'profile';
  select * into v_cat from business_categories where id = k.answers->>'category';
  v_cls := upper(coalesce(c->>'classification', ''));
  v_form := case when v_cls like 'COMPANY%' then 'company' when v_cls = 'BUSINESS_NAME' then 'enterprise' when v_cls = 'IT' then 'ngo'
                 when v_cls = 'LP' then 'partnership' when k.source = 'manual' then 'individual' else null end;
  v_name := coalesce(nullif(left(trim(p->>'trading_name'), 120), ''), initcap(lower(c->>'approved_name')), k.manual->>'name');
  v_addr := coalesce(nullif(left(trim(p->>'address'), 300), ''), nullif(trim(c->>'business_address'), ''), nullif(trim(c->>'address'), ''), k.manual->>'address');
  v_vat := coalesce((k.answers->>'charges_vat')::boolean, k.answers->>'revenue_band' = 'over_100m' or k.answers->'filing'->>'vat' in ('always', 'sometimes'));
  v_tin := coalesce(nullif(regexp_replace(coalesce(k.tin->>'nrs_tin', ''), '\D', '', 'g'), ''), nullif(regexp_replace(coalesce(c->>'tax_id', ''), '\D', '', 'g'), ''));
  if v_tin !~ '^[0-9]{13}$' then v_tin := null; end if;
  v_dir := (select jsonb_agg(jsonb_build_object('name', private.person(d), 'appointed', left(d->>'date_of_appointment', 10)))
            from jsonb_array_elements(coalesce(c->'directors', '[]'::jsonb)) d where private.person(d) is not null);
  v_shares := (select sum(case when s->>'num_shares_alloted' ~ '^[0-9]+$' then (s->>'num_shares_alloted')::numeric else 0 end)
               from jsonb_array_elements(coalesce(c->'shareholders', '[]'::jsonb)) s);
  select coalesce(nullif(trim(raw_user_meta_data->>'full_name'), ''), split_part(email, '@', 1)), email into v_display, v_email from auth.users where id = v_uid;
  v_branch := coalesce(nullif(left(trim(p->>'branch_name'), 60), ''), 'Head office');

  -- The company: its turn on its numbers, and for a business a practice runs, the one the firm took on and nobody else's.
  v_rc := coalesce(nullif(c->>'rc_number', ''), nullif(k.manual->>'rc_number', ''));
  perform private.company_lock(v_rc, v_tin);
  -- The number with its registry, from the CAC classification when the number does not say (RC for a company, BN for a
  -- business name, IT for incorporated trustees), to compare it.
  v_reg := case when private.reg_kind(v_rc) is null and private.norm_id(v_rc) is not null and v_form in ('company', 'enterprise', 'ngo')
    then case v_form when 'company' then 'RC ' when 'enterprise' then 'BN ' else 'IT ' end || v_rc else v_rc end;
  if k.org_id is not null and private.is_managed(k.org_id) then
    select managed_by into v_practice from orgs where id = k.org_id;
    mc := private.mandate(k.org_id);
    select x.rc_number into v_intake_rc from practice_intakes x where x.id = mc.intake_id;
    if private.norm_id(v_rc) is not null and private.norm_id(v_intake_rc) is not null and not private.same_reg(v_reg, v_intake_rc) then
      raise exception 'This CAC record is for RC %, but the firm took this business on as RC %. Choose the right company.',
        private.norm_id(v_rc), private.norm_id(v_intake_rc);
    end if;
    v_dup := private.company_taken(v_reg, v_tin, v_practice, k.org_id);
    if v_dup is not null then
      insert into practice_mandate_flags (practice_id, intake_id, client_id, kind, detail)
      select v_practice, mc.intake_id, mc.id, 'duplicate_company', v_dup || jsonb_build_object('source', 'cac', 'business_org_id', k.org_id)
      where not exists (select 1 from practice_mandate_flags f where f.practice_id = v_practice and f.kind = 'duplicate_company' and f.resolved_at is null
                        and f.detail->>'business_org_id' = k.org_id::text);
      return jsonb_build_object('ok', false, 'reason', 'duplicate');
    end if;
  elsif private.norm_id(v_rc) is not null or v_tin is not null then
    -- An ordinary owner's company that a practice already runs under full mandate: the firm hands it over instead.
    select o.* into mo from orgs o
    where o.managed_by is not null and not o.is_sample and o.id is distinct from k.org_id
      and (private.same_reg(o.rc_number, v_reg) or private.norm_id(o.tin) = private.norm_id(v_tin))
    order by o.created_at, o.id
    limit 1;
    if mo.id is not null then
      mc := private.mandate(mo.id);
      insert into practice_mandate_flags (practice_id, intake_id, client_id, kind, detail)
      select mo.managed_by, mc.intake_id, mc.id, 'duplicate_company',
        jsonb_build_object('source', 'owner', 'matched_on', case when private.same_reg(mo.rc_number, v_reg) then 'rc_number' else 'tax_id' end,
          'business_org_id', mo.id, 'user_id', v_uid, 'email', v_email, 'name', v_name, 'org_id', k.org_id)
      where not exists (select 1 from practice_mandate_flags f where f.kind = 'duplicate_company' and f.resolved_at is null
                        and f.detail->>'source' = 'owner' and f.detail->>'business_org_id' = mo.id::text and f.detail->>'user_id' = v_uid::text);
      return jsonb_build_object('ok', false, 'reason', 'managed_elsewhere');
    end if;
  end if;

  v_org := k.org_id;
  if v_org is null then
    v_org := public.create_org(v_name, coalesce(nullif(trim(p->>'email'), ''), v_email), nullif(trim(p->>'phone'), ''), v_display,
      jsonb_build_array(jsonb_build_object('name', v_branch, 'address', v_addr)), v_vat, false);
    v_new := true;
  elsif not private.is_owner(v_org) then
    raise exception 'Only the owner submits the business profile.' using errcode = '42501';
  else
    update orgs set name = v_name, vat_registered = v_vat, phone = coalesce(nullif(trim(p->>'phone'), ''), phone) where id = v_org;
  end if;
  update orgs set
    rc_number = coalesce(nullif(c->>'rc_number', ''), nullif(k.manual->>'rc_number', ''), rc_number),
    tin = coalesce(v_tin, tin),
    legal_form = coalesce(v_form, legal_form),
    address = coalesce(v_addr, address),
    registered_office = coalesce(nullif(trim(c->>'address'), ''), nullif(trim(c->>'head_office_address'), ''), registered_office),
    incorporation_date = coalesce(nullif(left(c->>'registration_date', 10), '')::date, incorporation_date),
    commenced_on = coalesce(nullif(left(c->>'business_commencement_date', 10), '')::date, commenced_on),
    principal_activity = coalesce(nullif(left(trim(c->>'objectives'), 500), ''), v_cat.label, principal_activity),
    directors = coalesce(v_dir, directors),
    industry = coalesce(v_cat.industry, industry),
    offering = coalesce(nullif(k.answers->>'offering', ''), v_cat.kind, offering),
    category_id = coalesce(v_cat.id, category_id),
    identity_status = case when v_new then 'pending' else identity_status end,
    website = coalesce(website, nullif(left(k.web->>'website', 200), '')),
    -- The shares CAC has on record, when the statements have none yet.
    share_info = case when share_info = '{}'::jsonb and v_shares > 0 then jsonb_build_object('issued_shares', v_shares) else share_info end,
    company_secretary = coalesce(nullif(company_secretary, ''), (select coalesce(private.person(s), nullif(trim(s->>'corporation_name'), ''))
      from jsonb_array_elements(coalesce(k.cac->'secretary', '[]'::jsonb)) s limit 1))
  where id = v_org;
  -- The head office's state (and local government area, when CAC names one the NRS list knows) from the CAC record or the address.
  v_state := coalesce(private.ng_state(nullif(c->>'state', '')), private.ng_state(k.manual->>'state'), private.ng_state_of_address(v_addr));
  if v_state is not null then
    v_lga := private.ng_lga(v_state, nullif(trim(regexp_replace(coalesce(nullif(c->>'lga', ''), c->>'city', ''), '\s*L\.?G\.?A\.?$', '', 'i')), ''));
    update locations set state = v_state, lga = coalesce(v_lga, lga) where org_id = v_org and is_main and state is null;
  end if;
  update kyc_profiles set status = 'submitted', submitted_at = now(), org_id = v_org, updated_at = now() where id = k.id;
  insert into guide_progress (user_id, org_id) values (v_uid, v_org) on conflict (user_id) do update set org_id = excluded.org_id, last_seen_at = now();
  return jsonb_build_object('org_id', v_org, 'name', v_name, 'compliance', public.compliance_score(v_org));
end $$;

-- ---------------------------------------------------------------------------
-- 6. Messages: the gate before the plan's limits
-- ---------------------------------------------------------------------------
-- Same-event triggers fire in name order: messages_gate runs before messages_plan.
drop trigger if exists messages_suppress on public.messages;
drop trigger if exists messages_gate on public.messages;
create trigger messages_gate before insert on public.messages for each row execute function private.messages_outbound();

-- Latest definition (20261124000900_mandate_end_handover.sql); a message the gate kept back is not held to the limits.
create or replace function private.enforce_plan() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if tg_table_name = 'sales' then
    -- Partners' invoices through Prism are charged by Prism in credits.
    if new.doc_type in ('receipt', 'invoice') and new.status not in ('draft', 'void', 'cancelled') and new.channel is distinct from 'api' then
      perform private.check_quota(new.org_id, 'sales');
    end if;
  elsif tg_table_name = 'members' then
    -- The practice's places in a business it runs, or handed over and still works on, use none of the plan's places.
    if private.seat_exempt(new.org_id, new.practice_id) then return new; end if;
    if new.role <> 'owner' and new.status in ('active', 'invited') then perform private.check_quota(new.org_id, 'users'); end if;
  elsif tg_table_name = 'locations' then
    perform private.check_quota(new.org_id, 'locations');
  elsif tg_table_name = 'payouts' then
    if new.batch_id is not null and not private.feature_on(new.org_id, 'bulk_payments') then
      raise exception 'Bulk payments are not in your plan. The owner can change the plan in Settings, Subscription.';
    end if;
    perform private.check_quota(new.org_id, 'payouts');
  elsif tg_table_name = 'supplier_invoices' then
    if new.source = 'portal' and not private.feature_on(new.org_id, 'supplier_portal') then
      raise exception 'This business is not taking invoices on its portal right now.';
    end if;
    perform private.check_quota(new.org_id, 'supplier_invoices');
  elsif tg_table_name = 'tin_checks' then
    perform private.check_quota(new.org_id, 'tin_checks');
  elsif tg_table_name = 'bank_accounts' then
    if new.provider = 'mono' and (tg_op = 'INSERT' or old.provider is distinct from 'mono') then
      if not private.feature_on(new.org_id, 'bank_feeds') then
        raise exception 'Bank feeds are not in your plan. The owner can change the plan in Settings, Subscription.';
      end if;
      perform private.check_quota(new.org_id, 'bank_feeds');
    end if;
  elsif tg_table_name = 'voice_calls' then
    perform private.check_quota(new.org_id, 'call_minutes');
  elsif tg_table_name = 'messages' then
    -- Not sent (the full-mandate gate kept it back): nothing to count.
    if new.status = 'suppressed' then return new; end if;
    -- A message over a blocking limit is kept, marked failed with the reason, so whatever queued it carries on. Counta's
    -- own alerts to the team are not counted.
    if new.template is distinct from 'alert' then
      begin
        perform private.check_quota(new.org_id, case when new.channel = 'whatsapp' then 'whatsapp' else 'emails' end);
      exception when sqlstate 'P0001' then
        new.status := 'failed'; new.error := left(sqlerrm, 300);
      end;
    end if;
  end if;
  return new;
end $$;

-- Latest definition (20261030000500_service_costs.sql); WhatsApp messages and emails not sent (suppressed) are left out.
create or replace function private.meter_average(p_meter text) returns numeric
language plpgsql stable security definer set search_path = public, private as $$
declare v_from timestamptz := now() - interval '30 days'; v_n int; v numeric;
begin
  select count(*) into v_n from orgs o where not o.is_sample and exists (select 1 from members mb where mb.org_id = o.id and mb.status = 'active');
  if v_n = 0 then return 0; end if;
  case p_meter
    when 'sales' then select count(*) into v from sales s join orgs o on o.id = s.org_id where not o.is_sample and s.created_at >= v_from and s.doc_type in ('receipt', 'invoice') and s.status not in ('draft', 'void', 'cancelled');
    when 'ai_reads' then select count(*) into v from usage_events u join orgs o on o.id = u.org_id where not o.is_sample and u.service = 'gemini' and u.kind = any(private.ai_read_kinds()) and u.at >= v_from;
    when 'assistant' then select count(*) into v from usage_events u join orgs o on o.id = u.org_id where not o.is_sample and u.service = 'gemini' and u.kind = any(private.ai_assistant_kinds()) and u.at >= v_from;
    when 'call_minutes' then select coalesce(sum(ceil(coalesce(v.duration_secs, 0) / 60.0)), 0) into v from voice_calls v join orgs o on o.id = v.org_id where not o.is_sample and v.created_at >= v_from;
    when 'whatsapp' then select count(*) into v from messages m join orgs o on o.id = m.org_id where not o.is_sample and m.channel = 'whatsapp' and m.status not in ('failed', 'suppressed') and m.created_at >= v_from;
    when 'emails' then select count(*) into v from messages m join orgs o on o.id = m.org_id where not o.is_sample and m.channel = 'email' and m.status not in ('failed', 'suppressed') and m.created_at >= v_from;
    when 'tin_checks' then select count(*) into v from tin_checks t join orgs o on o.id = t.org_id where not o.is_sample and t.at >= v_from;
    when 'supplier_invoices' then select count(*) into v from supplier_invoices t join orgs o on o.id = t.org_id where not o.is_sample and t.created_at >= v_from;
    when 'payouts' then select count(*) into v from payouts t join orgs o on o.id = t.org_id where not o.is_sample and t.created_at >= v_from and t.status <> 'cancelled';
    when 'users' then select count(*) into v from members t join orgs o on o.id = t.org_id where not o.is_sample and t.status in ('active', 'invited');
    when 'locations' then select count(*) into v from locations t join orgs o on o.id = t.org_id where not o.is_sample;
    when 'bank_feeds' then select count(*) into v from bank_accounts t join orgs o on o.id = t.org_id where not o.is_sample and t.provider = 'mono' and t.active;
    else v := 0;
  end case;
  return round(coalesce(v, 0)::numeric / v_n, 2);
end $$;

-- ---------------------------------------------------------------------------
-- 7. Signing for the firm: the letter as it was prepared
-- ---------------------------------------------------------------------------
-- A draft letter's fingerprint: SHA-256 of its content (body, merge values, variant, title, source and file), the time it
-- last changed and the firm's details printed on it. Any change between preparing and signing changes it.
create or replace function private.letter_fingerprint(p_letter uuid) returns text
language sql stable set search_path = public, private as $$
  select encode(sha256(convert_to(jsonb_build_object('blocks', l.blocks, 'merge', l.merge, 'variant', l.variant, 'title', l.title,
      'source', l.source, 'doc_path', l.doc_path, 'updated_at', extract(epoch from l.updated_at)::text,
      'firm', jsonb_build_object('name', pr.name, 'email', pr.email, 'phone', pr.phone, 'address', pr.address, 'state', pr.state))::text, 'UTF8')), 'hex')
  from engagement_letters l join practices pr on pr.id = l.practice_id
  where l.id = p_letter
$$;

-- Latest definition (20261124000700_engagement_letters.sql); also gives the letter's fingerprint.
create or replace function public.practice_letter_prepare(p_letter uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.engagement_letters; m public.practice_members; pr public.practices; v_err text;
begin
  l := private.letter_require(p_letter);
  m := private.practice_me(l.practice_id);
  if m.role <> 'partner' then raise exception 'Only a partner signs letters for the firm.' using errcode = '42501'; end if;
  if l.status <> 'draft' then raise exception 'Only a draft letter is signed by the firm.'; end if;
  perform private.letter_intake_ready(l.intake_id);
  if l.source = 'template' then
    v_err := private.letter_body_ok(l.blocks);
    if v_err is not null then raise exception '%', v_err; end if;
  end if;
  select * into pr from practices where id = l.practice_id;
  return jsonb_build_object('letter_id', l.id, 'practice_id', l.practice_id, 'source', l.source, 'doc_path', l.doc_path, 'title', l.title,
    'variant', l.variant, 'blocks', l.blocks, 'merge', l.merge, 'fingerprint', private.letter_fingerprint(l.id),
    'firm', jsonb_build_object('name', pr.name, 'email', pr.email, 'phone', pr.phone, 'address', pr.address, 'state', pr.state),
    'partner', jsonb_build_object('id', m.id, 'name', m.display_name, 'email', m.email, 'title', 'Partner'));
end $$;

-- Latest definition (20261124000700_engagement_letters.sql); p.fingerprint must be the letter's as it stands (what
-- practice_letter_prepare gave), after every other check.
create or replace function public.svc_letter_frozen(p_letter uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.engagement_letters; pm public.practice_members; v_path text := nullif(trim(coalesce(p->>'doc_path', '')), '');
  v_sha text := lower(trim(coalesce(p->>'doc_sha256', ''))); v_sig text; v_err text;
begin
  select * into l from engagement_letters where id = p_letter for update;
  if l.id is null then raise exception 'Letter not found.'; end if;
  if l.status <> 'draft' then raise exception 'Only a draft letter is signed by the firm.'; end if;
  select * into pm from practice_members
  where practice_id = l.practice_id and user_id = private.uuid_of(p->>'by_user') and role = 'partner' and status = 'active';
  if pm.id is null then raise exception 'Only a partner of the practice signs its letters.' using errcode = '42501'; end if;
  perform private.letter_intake_ready(l.intake_id);
  if l.source = 'pdf' then
    if v_path is distinct from l.doc_path then raise exception 'A PDF letter is signed as it stands: its file cannot change.'; end if;
  elsif not private.letter_file_ok(v_path, l.practice_id, l.id::text) then
    raise exception 'The signed letter must be stored in the letter''s folder.';
  end if;
  if v_sha !~ '^[0-9a-f]{64}$' then raise exception 'The letter''s SHA-256 fingerprint is missing.'; end if;
  if l.source = 'template' then
    v_err := private.letter_body_ok(l.blocks);
    if v_err is not null then raise exception '%', v_err; end if;
  end if;
  v_sig := coalesce(nullif(trim(p->>'signature_name'), ''), pm.display_name);
  if length(v_sig) not between 2 and 120 then raise exception 'Type the partner''s name to sign (2 to 120 characters).'; end if;
  if coalesce(p->>'fingerprint', '') is distinct from private.letter_fingerprint(l.id) then
    raise exception 'The letter changed while it was being signed. Sign it again.';
  end if;
  perform private.set_actor(pm.user_id);
  update engagement_letters set status = 'partner_signed', doc_path = v_path, doc_sha256 = v_sha, partner_id = pm.id, partner_signature = v_sig,
    partner_name = pm.display_name, partner_email = lower(trim(pm.email)), partner_signed_at = now(), partner_ip = left(nullif(trim(p->>'ip'), ''), 64),
    partner_ua = left(nullif(p->>'ua', ''), 300), updated_at = now()
  where id = l.id
  returning * into l;
  perform private.letter_event(l.id, 'partner_signed', pm.display_name, l.partner_ip, l.partner_ua, jsonb_build_object('signature', v_sig));
  return private.letter_json(l);
end $$;

-- ---------------------------------------------------------------------------
-- 8 and 9. The client link: retention, and prospects the firm refused
-- ---------------------------------------------------------------------------
-- Latest definition (20261124000600_intake_conflicts.sql). A link that ends dates its intake's retention by the longest of
-- the link's retention years and those of the intake's letters signed or sent (never under five).
create or replace function private.practice_clients_intake() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare x public.practice_intakes; v_years int;
begin
  if new.practice_id is null or (tg_op = 'UPDATE' and new.status is not distinct from old.status) then return null; end if;
  if new.status = 'active' then
    if new.intake_id is null then
      perform private.intake_for_client(new.id);
      return null;
    end if;
    select * into x from practice_intakes where id = new.intake_id for update;
    if x.practice_id is distinct from new.practice_id then raise exception 'That due-diligence intake belongs to another practice.'; end if;
    -- (A link taken up again keeps the intake it was engaged on, cleared or not.)
    if not (x.status = 'engaged' and x.client_id = new.id) and (x.status = 'declined' or not private.intake_cleared(x)) then
      raise exception 'This cannot go ahead yet: the practice has not finished its checks on the business. Ask the practice about it.';
    end if;
    update practice_intakes set status = 'engaged', org_id = new.org_id, client_id = new.id, retain_until = null, updated_at = now() where id = x.id;
    perform private.intake_settle(x.id);
  elsif new.status in ('ended', 'declined') and new.intake_id is not null then
    v_years := greatest(coalesce(new.retention_years, 5), coalesce((select max(l.retention_years) from engagement_letters l
      where l.intake_id = new.intake_id and l.status in ('partner_signed', 'sent', 'completed', 'uploaded')), 5));
    update practice_intakes set retain_until = greatest(retain_until, private.retain_date(v_years)), updated_at = now()
    where id = new.intake_id and status = 'engaged';
  end if;
  return null;
end $$;

-- Latest definition (20261124000600_intake_conflicts.sql). A business the practice refused after a conflicts check (a
-- declined intake for the same business, RC number or Tax ID) does not become its client through a link with no intake.
create or replace function private.intake_for_client(p_client uuid) returns uuid
language plpgsql set search_path = public, private as $$
declare c public.practice_clients; o public.orgs; v_name text; v_id uuid;
begin
  select * into c from practice_clients where id = p_client;
  if c.id is null or c.intake_id is not null or c.practice_id is null or c.org_id is null then return c.intake_id; end if;
  select * into o from orgs where id = c.org_id;
  if exists (select 1 from practice_intakes d
             where d.practice_id = c.practice_id and d.status = 'declined'
               and (d.org_id = c.org_id or private.same_reg(d.rc_number, o.rc_number) or private.norm_id(d.tax_id) = private.norm_id(o.tin))) then
    raise exception 'This practice cannot take this business on. Ask the practice about it.';
  end if;
  v_name := coalesce(nullif(trim(c.business_name), ''), trim(o.name));
  -- A one-letter business name is still a name to confirm.
  v_name := case when length(v_name) >= 2 then left(v_name, 160) else coalesce(v_name, '') || ' (name to confirm)' end;
  insert into practice_intakes (practice_id, status, mode_requested, legal_name, rc_number, tax_id, dd_incomplete, client_id, org_id)
  values (c.practice_id, 'engaged', c.mode, v_name, left(o.rc_number, 40), left(o.tin, 40), true, c.id, c.org_id)
  returning id into v_id;
  update practice_clients set intake_id = v_id where id = c.id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 10. Ongoing due diligence
-- ---------------------------------------------------------------------------
-- An intake kept as it is: one with a retention date (the engagement ended, a partner refused it, or the business was
-- deleted). The intake of a client the firm has taken on stays up to date instead, with its history.
create or replace function private.intake_kept(i public.practice_intakes) returns boolean
language sql immutable set search_path = public, private as $$
  select i.retain_until is not null
$$;

-- The intake of a client as it was before each change: its details, the outcome of its last check and its people.
-- changed_by: the lead who changed it. Kept as long as the intake.
create table if not exists public.practice_intake_history (
  id uuid primary key default gen_random_uuid(),
  intake_id uuid not null references public.practice_intakes(id) on delete cascade,
  practice_id uuid not null references public.practices(id) on delete cascade,
  snapshot jsonb not null check (jsonb_typeof(snapshot) = 'object'),
  changed_by uuid references public.practice_members(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists practice_intake_history_intake on public.practice_intake_history(intake_id, created_at desc);
create index if not exists practice_intake_history_practice on public.practice_intake_history(practice_id);
create index if not exists practice_intake_history_changed_by on public.practice_intake_history(changed_by) where changed_by is not null;
alter table public.practice_intake_history enable row level security;
revoke all on public.practice_intake_history from anon, authenticated;
drop trigger if exists practice_intakes_retention on public.practice_intake_history;
create trigger practice_intakes_retention before delete on public.practice_intake_history
  for each row execute function private.practice_intakes_retention();

-- What the history keeps of an intake.
create or replace function private.intake_snapshot(p_intake uuid) returns jsonb
language sql stable set search_path = public, private as $$
  select jsonb_build_object('legal_name', i.legal_name, 'mode_requested', i.mode_requested, 'entity_type', i.entity_type, 'rc_number', i.rc_number,
    'tax_id', i.tax_id, 'address', i.address, 'industry', i.industry, 'risk_rating', i.risk_rating, 'risk_reason', i.risk_reason,
    'pep_present', i.pep_present, 'conflict_status', i.conflict_status, 'conflict_note', i.conflict_note, 'checked_at', i.checked_at,
    'people', (select coalesce(jsonb_agg(x order by x::text), '[]'::jsonb) from (
        select jsonb_build_object('kind', p.kind, 'name', p.name, 'role', p.role, 'ownership_pct', p.ownership_pct, 'nationality', p.nationality,
          'is_pep', p.is_pep, 'id_type', p.id_type, 'id_last4', p.id_last4) as x
        from practice_intake_people p where p.intake_id = i.id) z))
  from practice_intakes i where i.id = p_intake
$$;

-- Latest definition (20261124000600_intake_conflicts.sql). For the intake of a client already taken on (engaged): the way
-- the firm works with it does not change here, the authority declared stays, and the intake as it was goes into its
-- history when anything changes. A change to the name, numbers or people still needs the conflicts check again.
create or replace function public.practice_intake_save(p_practice uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.practice_members; i public.practice_intakes; x jsonb; v_people jsonb := '[]'; v_old_people jsonb := '[]';
  v_name text; v_mode text; v_type text; v_rc text; v_tax text; v_address text; v_industry text; v_risk text; v_reason text;
  v_pname text; v_prole text; v_pnat text; v_kind text; v_idtype text; v_last4 text; v_pct numeric;
  v_people_changed boolean := false; v_edit boolean; v_pep boolean; v_withdraw boolean; v_engaged boolean := false; v_before jsonb;
begin
  m := private.practice_require(p_practice, true);
  if jsonb_typeof(p) is distinct from 'object' then raise exception 'Nothing to save.'; end if;
  if nullif(p->>'id', '') is not null then
    select * into i from practice_intakes where id = private.uuid_of(p->>'id') and practice_id = p_practice for update;
    if i.id is null then raise exception 'Intake not found.'; end if;
    if i.status = 'declined' then raise exception 'This intake was declined after the conflicts check. Start a new one.'; end if;
    if private.intake_kept(i) then raise exception 'This intake is kept as the record of the engagement. Start a new intake to record changes.'; end if;
    v_engaged := i.status = 'engaged';
    if v_engaged then v_before := private.intake_snapshot(i.id); end if;
  end if;

  -- The intake's details: those given, else as they were.
  v_name := case when p ? 'legal_name' then nullif(trim(p->>'legal_name'), '') else i.legal_name end;
  v_mode := case when p ? 'mode_requested' then nullif(p->>'mode_requested', '') else i.mode_requested end;
  v_type := case when p ? 'entity_type' then nullif(p->>'entity_type', '') else i.entity_type end;
  v_rc := case when p ? 'rc_number' then nullif(trim(p->>'rc_number'), '') else i.rc_number end;
  v_tax := case when p ? 'tax_id' then nullif(trim(p->>'tax_id'), '') else i.tax_id end;
  v_address := case when p ? 'address' then nullif(trim(p->>'address'), '') else i.address end;
  v_industry := case when p ? 'industry' then nullif(trim(p->>'industry'), '') else i.industry end;
  v_risk := case when p ? 'risk_rating' then nullif(p->>'risk_rating', '') else i.risk_rating end;
  v_reason := case when p ? 'risk_reason' then nullif(trim(p->>'risk_reason'), '') else i.risk_reason end;
  if v_name is null or length(v_name) not between 2 and 160 then raise exception 'Enter the business''s registered name (2 to 160 characters).'; end if;
  if coalesce(v_mode, 'involved') not in ('involved', 'full') then raise exception 'Choose involved or full mandate.'; end if;
  if v_engaged and coalesce(v_mode, i.mode_requested) is distinct from i.mode_requested then
    raise exception 'This business is already your client: the way you work with it is set by its engagement, not on its intake.';
  end if;
  if v_type is not null and v_type not in ('company', 'business_name', 'incorporated_trustees', 'partnership', 'individual') then
    raise exception 'Choose the kind of business.';
  end if;
  if length(v_rc) > 40 or length(v_tax) > 40 then raise exception 'That RC number or Tax ID is too long.'; end if;
  if length(v_address) > 300 then raise exception 'Keep the address under 300 characters.'; end if;
  if length(v_industry) > 80 then raise exception 'Keep the industry under 80 characters.'; end if;
  if v_risk is not null and v_risk not in ('low', 'medium', 'high') then raise exception 'Choose a low, medium or high risk.'; end if;
  if length(v_reason) > 1000 then raise exception 'Keep the reason for the risk under 1,000 characters.'; end if;

  -- The people, checked before anything is kept.
  if p ? 'people' then
    if jsonb_typeof(p->'people') is distinct from 'array' then raise exception 'List the people as a list.'; end if;
    if jsonb_array_length(p->'people') > 100 then raise exception 'Record up to 100 people.'; end if;
    for x in select e from jsonb_array_elements(p->'people') e loop
      if jsonb_typeof(x) is distinct from 'object' then raise exception 'Each person needs a name.'; end if;
      v_pname := nullif(trim(x->>'name'), ''); v_prole := nullif(trim(x->>'role'), ''); v_pnat := nullif(trim(x->>'nationality'), '');
      v_last4 := nullif(trim(x->>'id_last4'), '');
      if x ?| array['id_number', 'nin', 'bvn'] or v_last4 !~ '^[A-Za-z0-9]{4}$'
         or private.has_id_number(v_pname) or private.has_id_number(v_prole) or private.has_id_number(v_pnat) then
        raise exception 'Record only the last 4 characters of an ID number.';
      end if;
      v_kind := coalesce(nullif(x->>'kind', ''), 'director');
      if v_kind not in ('director', 'beneficial_owner', 'related') then raise exception 'Choose director, beneficial owner or related person.'; end if;
      if v_pname is null or length(v_pname) not between 2 and 120 then raise exception 'Enter each person''s name (2 to 120 characters).'; end if;
      if length(v_prole) > 80 then raise exception 'Keep %''s role under 80 characters.', v_pname; end if;
      if length(v_pnat) > 60 then raise exception 'Keep %''s nationality under 60 characters.', v_pname; end if;
      v_pct := null;
      if nullif(trim(x->>'ownership_pct'), '') is not null then
        if trim(x->>'ownership_pct') !~ '^[0-9]{1,3}(\.[0-9]+)?$' or trim(x->>'ownership_pct')::numeric > 100 then
          raise exception 'Ownership is a percentage from 0 to 100.';
        end if;
        v_pct := round(trim(x->>'ownership_pct')::numeric, 2);
      end if;
      if jsonb_typeof(x->'is_pep') not in ('boolean', 'null') and coalesce(x->>'is_pep', '') not in ('true', 'false') then
        raise exception 'Say yes or no to whether % is a politically exposed person.', v_pname;
      end if;
      v_idtype := nullif(x->>'id_type', '');
      if v_idtype is not null and v_idtype not in ('nin', 'bvn', 'passport', 'drivers_licence', 'voters_card', 'cac', 'other') then
        raise exception 'Choose the kind of ID.';
      end if;
      v_people := v_people || jsonb_build_array(jsonb_build_object('kind', v_kind, 'name', v_pname, 'role', v_prole, 'ownership_pct', v_pct,
        'nationality', v_pnat, 'is_pep', coalesce((x->>'is_pep')::boolean, false), 'id_type', v_idtype, 'id_last4', v_last4));
    end loop;
    select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'name', name, 'role', role, 'ownership_pct', ownership_pct, 'nationality', nationality,
        'is_pep', is_pep, 'id_type', id_type, 'id_last4', id_last4)), '[]'::jsonb)
      into v_old_people from practice_intake_people where intake_id = i.id;
    v_people_changed := (select coalesce(jsonb_agg(e order by e::text), '[]'::jsonb) from jsonb_array_elements(v_people) e)
      is distinct from (select coalesce(jsonb_agg(e order by e::text), '[]'::jsonb) from jsonb_array_elements(v_old_people) e);
    v_pep := exists (select 1 from jsonb_array_elements(v_people) e where (e->>'is_pep')::boolean);
  else
    v_pep := coalesce(i.pep_present, false);
  end if;
  if v_pep then v_risk := 'high'; end if;
  v_edit := i.id is null or v_people_changed or v_name is distinct from i.legal_name or v_rc is distinct from i.rc_number or v_tax is distinct from i.tax_id;
  v_withdraw := not v_engaged and (v_name is distinct from i.legal_name or coalesce(v_mode, i.mode_requested) is distinct from i.mode_requested);
  if i.id is not null and private.intake_invited(i.id) and (v_edit or v_risk is null or coalesce(v_mode, i.mode_requested) <> 'involved') then
    raise exception 'Withdraw the invitation first: it was sent on this intake as it stands.';
  end if;

  if i.id is null then
    insert into practice_intakes (practice_id, mode_requested, legal_name, entity_type, rc_number, tax_id, address, industry, risk_rating, risk_reason,
      pep_present, created_by)
    values (p_practice, coalesce(v_mode, 'involved'), v_name, v_type, v_rc, v_tax, v_address, v_industry, v_risk, v_reason, v_pep, auth.uid())
    returning * into i;
  else
    update practice_intakes set mode_requested = coalesce(v_mode, mode_requested), legal_name = v_name, entity_type = v_type, rc_number = v_rc,
      tax_id = v_tax, address = v_address, industry = v_industry, risk_rating = v_risk, risk_reason = v_reason, pep_present = v_pep,
      conflict_status = case when v_edit then 'pending' else conflict_status end,
      conflict_note = case when v_edit then null else conflict_note end,
      conflict_decided_by = case when v_edit then null else conflict_decided_by end,
      conflict_decided_at = case when v_edit then null else conflict_decided_at end,
      edited_at = case when v_edit then now() else edited_at end,
      authority_declared_by = case when v_withdraw then null else authority_declared_by end,
      authority_declared_at = case when v_withdraw then null else authority_declared_at end,
      authority_statement = case when v_withdraw then null else authority_statement end,
      authority_doc_path = case when v_withdraw then null else authority_doc_path end,
      updated_at = now()
    where id = i.id
    returning * into i;
  end if;
  if v_people_changed then
    perform set_config('counta.intake_save', 'on', true);
    delete from practice_intake_people where intake_id = i.id;
    perform set_config('counta.intake_save', '', true);
    insert into practice_intake_people (intake_id, practice_id, kind, name, role, ownership_pct, nationality, is_pep, id_type, id_last4)
    select i.id, i.practice_id, e->>'kind', e->>'name', e->>'role', (e->>'ownership_pct')::numeric, e->>'nationality', (e->>'is_pep')::boolean,
      e->>'id_type', e->>'id_last4'
    from jsonb_array_elements(v_people) e;
  end if;
  if v_engaged and v_before is distinct from private.intake_snapshot(i.id) then
    insert into practice_intake_history (intake_id, practice_id, snapshot, changed_by, created_at)
    values (i.id, i.practice_id, v_before, m.id, clock_timestamp());
  end if;
  perform private.intake_settle(i.id);
  return public.practice_intake(i.id);
end $$;

-- Latest definition (20261124000600_intake_conflicts.sql); a client already taken on was declared for when it was.
create or replace function public.practice_intake_declare(p_intake uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.practice_intakes; m public.practice_members; v_firm text; v_doc text := nullif(trim(coalesce(p->>'doc_path', '')), '');
begin
  i := private.intake_require(p_intake, true);
  m := private.practice_me(i.practice_id);
  if m.role <> 'partner' then raise exception 'Only a partner makes the declaration.' using errcode = '42501'; end if;
  if i.status = 'declined' then raise exception 'This intake was declined after the conflicts check.'; end if;
  if private.intake_kept(i) then raise exception 'This intake is kept as the record of the engagement.'; end if;
  if i.status = 'engaged' then raise exception 'This business is already your client: the declaration is made before it is taken on.'; end if;
  if i.mode_requested <> 'full' then raise exception 'The declaration is for a full mandate.'; end if;
  if v_doc is not null and v_doc not like 'practice/' || i.practice_id || '/intake/' || i.id || '/_%' then
    raise exception 'Upload the signed authority to the intake''s folder first.';
  end if;
  select name into v_firm from practices where id = i.practice_id;
  update practice_intakes set authority_declared_by = m.id, authority_declared_at = now(), authority_doc_path = v_doc,
    authority_statement = format('I confirm that %s holds the written authority of %s to set up and run its accounting records and tax affairs on its '
      || 'behalf under full mandate, as set out in the engagement letter, and that I am a partner of %s.', v_firm, i.legal_name, v_firm),
    updated_at = now()
  where id = i.id;
  return public.practice_intake(i.id);
end $$;

-- Latest definition (20261124000600_intake_conflicts.sql); a client already taken on is not invited again on its intake.
create or replace function public.practice_invite_client(p_practice uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare m public.practice_members; i public.practice_intakes; v_email text := lower(trim(coalesce(p->>'email', ''))); v_id uuid; v_services text[];
begin
  m := private.practice_require(p_practice, true);
  select * into i from practice_intakes where id = private.uuid_of(p->>'intake_id') and practice_id = p_practice for update;
  if i.id is null or i.mode_requested <> 'involved' or i.status = 'declined' or not private.intake_cleared(i) then
    raise exception 'Finish the due diligence and conflicts check first.';
  end if;
  if private.intake_kept(i) then raise exception 'This intake is kept as the record of the engagement. Start a new intake to invite the business.'; end if;
  if i.status = 'engaged' then raise exception 'This business is already your client.'; end if;
  if exists (select 1 from practice_clients where intake_id = i.id and status in ('invited', 'active')) then
    raise exception 'This business has been invited already.';
  end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter the business owner''s email address.'; end if;
  if (select count(*) from practice_clients where practice_id = p_practice and created_at > now() - interval '1 day') >= 50 then
    raise exception 'That is fifty invitations today. Try again tomorrow.';
  end if;
  select coalesce(array_agg(distinct x) filter (where x in ('bookkeeping', 'vat', 'wht', 'cit', 'statements', 'payroll', 'advisory')), '{bookkeeping,vat,wht,cit,statements}')
    into v_services from jsonb_array_elements_text(coalesce(p->'services', '[]'::jsonb)) x;
  if exists (select 1 from practice_clients where practice_id = p_practice and status = 'invited' and lower(invite_email) = v_email) then
    raise exception 'An invitation to % is already waiting. Send it again from the list.', v_email;
  end if;
  insert into practice_clients (practice_id, status, initiated_by, invite_email, invite_name, business_name, services, billing, note, created_by, intake_id)
  values (p_practice, 'invited', 'practice', v_email, nullif(left(trim(p->>'name'), 80), ''),
    coalesce(nullif(left(trim(p->>'business_name'), 120), ''), left(i.legal_name, 120)), v_services,
    case when p->>'billing' = 'practice' then 'practice' else 'business' end, nullif(left(trim(p->>'note'), 500), ''), auth.uid(), i.id)
  returning id into v_id;
  return v_id;
end $$;

-- Latest definition (20261124000600_intake_conflicts.sql); in full, also its history, newest first (50 at most):
-- [{id, created_at, changed_by_name, snapshot}].
create or replace function private.intake_json(i public.practice_intakes, p_full boolean) returns jsonb
language sql stable set search_path = public, private as $$
  select case when not p_full then jsonb_build_object('id', i.id, 'status', i.status, 'mode_requested', i.mode_requested, 'legal_name', i.legal_name,
      'entity_type', i.entity_type, 'rc_number', i.rc_number, 'tax_id', i.tax_id, 'risk_rating', i.risk_rating, 'pep_present', i.pep_present,
      'dd_incomplete', i.dd_incomplete, 'conflict_status', i.conflict_status, 'checked_at', i.checked_at, 'cleared', private.intake_cleared(i),
      'authority_declared', i.authority_declared_at is not null, 'client_id', i.client_id, 'org_id', i.org_id, 'retain_until', i.retain_until,
      'created_at', i.created_at, 'updated_at', i.updated_at)
  else to_jsonb(i) || jsonb_build_object(
      'cleared', private.intake_cleared(i),
      'conflict_decided_by_name', (select display_name from practice_members where id = i.conflict_decided_by),
      'authority_declared_by_name', (select display_name from practice_members where id = i.authority_declared_by),
      'people', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'kind', p.kind, 'name', p.name, 'role', p.role,
          'ownership_pct', p.ownership_pct, 'nationality', p.nationality, 'is_pep', p.is_pep, 'id_type', p.id_type, 'id_last4', p.id_last4)
          order by case p.kind when 'director' then 1 when 'beneficial_owner' then 2 else 3 end, p.name, p.id), '[]'::jsonb)
        from practice_intake_people p where p.intake_id = i.id),
      'docs', (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'name', d.name, 'path', d.path, 'sha256', d.sha256,
          'added_by_name', pm.display_name, 'created_at', d.created_at) order by d.created_at, d.name), '[]'::jsonb)
        from practice_intake_docs d left join practice_members pm on pm.id = d.added_by where d.intake_id = i.id),
      'hits', (select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'kind', h.kind, 'matched_on', h.matched_on, 'subject', h.subject,
          'match_name', h.match_name, 'score', h.score, 'source_client_id', h.source_client_id, 'source_intake_id', h.source_intake_id,
          'source_opposing_id', h.source_opposing_id) order by h.kind, h.matched_on, h.score desc, h.match_name), '[]'::jsonb)
        from practice_conflict_hits h where h.intake_id = i.id),
      'history', (select coalesce(jsonb_agg(jsonb_build_object('id', z.id, 'created_at', z.created_at, 'changed_by_name', z.changed_by_name,
          'snapshot', z.snapshot) order by z.created_at desc, z.id), '[]'::jsonb)
        from (select hh.id, hh.created_at, hh.snapshot, pm.display_name as changed_by_name
              from practice_intake_history hh left join practice_members pm on pm.id = hh.changed_by
              where hh.intake_id = i.id order by hh.created_at desc, hh.id limit 50) z)) end
$$;

-- ---------------------------------------------------------------------------
-- 11. Credit notes on fee invoices, confirmed before they go into the client's books
-- ---------------------------------------------------------------------------
-- One record per credit note against a fee invoice whose bill is posted in a full-mandate client's books (sale_id: the
-- fee invoice; credit_sale_id: the credit note, both in the firm business; amount: the credit note's total).
--   pending    waits for a lead to confirm it (error: why the last try failed, if it did);
--   posted     recorded as a supplier credit note against the bill in the client's books (vendor_credit_id);
--   dismissed  a partner chose to leave the books alone (note: why).
-- decided_by, decided_at: who confirmed or dismissed it, and when.
create table if not exists public.practice_fee_credits (
  id uuid primary key default gen_random_uuid(),
  practice_id uuid not null references public.practices(id) on delete cascade,
  client_id uuid not null references public.practice_clients(id) on delete cascade,
  fee_bill_id uuid not null references public.practice_fee_bills(id) on delete cascade,
  sale_id uuid not null references public.sales(id) on delete cascade,
  credit_sale_id uuid not null unique references public.sales(id) on delete cascade,
  amount numeric not null check (amount > 0),
  status text not null default 'pending' check (status in ('pending', 'posted', 'dismissed')),
  vendor_credit_id uuid references public.vendor_credits(id) on delete set null,
  error text check (error is null or length(error) <= 500),
  note text check (note is null or length(note) <= 500),
  decided_by uuid references auth.users(id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists practice_fee_credits_client on public.practice_fee_credits(client_id, created_at);
create index if not exists practice_fee_credits_practice on public.practice_fee_credits(practice_id) where status = 'pending';
create index if not exists practice_fee_credits_practice_all on public.practice_fee_credits(practice_id);
create index if not exists practice_fee_credits_fee_bill on public.practice_fee_credits(fee_bill_id);
create index if not exists practice_fee_credits_sale on public.practice_fee_credits(sale_id);
create index if not exists practice_fee_credits_vendor_credit on public.practice_fee_credits(vendor_credit_id) where vendor_credit_id is not null;
create index if not exists practice_fee_credits_decided_by on public.practice_fee_credits(decided_by) where decided_by is not null;
alter table public.practice_fee_credits enable row level security;
revoke all on public.practice_fee_credits from anon, authenticated;

-- A credit note posted in the firm business against a fee invoice whose bill is posted: recorded to be confirmed, and the
-- practice's leads told (once). The record, or nothing when there is nothing to confirm.
create or replace function private.fee_credit_note(p_credit uuid) returns public.practice_fee_credits
language plpgsql security definer set search_path = public, private as $$
declare cn public.sales; inv public.sales; x public.practice_fee_bills; r public.practice_fee_credits; v_client text;
begin
  select * into cn from sales where id = p_credit;
  if cn.id is null or cn.doc_type <> 'credit_note' or cn.original_sale_id is null or cn.journal_id is null or coalesce(cn.total, 0) <= 0 then return r; end if;
  select * into x from practice_fee_bills where sale_id = cn.original_sale_id;
  if x.id is null or x.status <> 'posted' or x.bill_id is null then return r; end if;
  insert into practice_fee_credits (practice_id, client_id, fee_bill_id, sale_id, credit_sale_id, amount)
  values (x.practice_id, x.client_id, x.id, x.sale_id, cn.id, cn.total)
  on conflict (credit_sale_id) do nothing
  returning * into r;
  if r.id is null then
    select * into r from practice_fee_credits where credit_sale_id = cn.id;
    return r;
  end if;
  select * into inv from sales where id = x.sale_id;
  select coalesce(o.name, pc.business_name) into v_client from practice_clients pc left join orgs o on o.id = pc.org_id where pc.id = x.client_id;
  perform private.practice_notify(x.practice_id, 'A fee credit note to confirm',
    format('Credit note %s takes ₦%s off fee invoice %s for %s. Confirm it on the Fees page before it goes into their books.',
      cn.number, to_char(cn.total, 'FM999,999,999,990.00'), inv.number, v_client), '/practice/fees');
  return r;
end $$;

create or replace function private.fee_credit_on_post() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if exists (select 1 from practices where firm_org_id = new.org_id) then
    begin
      perform private.fee_credit_note(new.id);
    exception when others then
      raise warning 'Credit note % was not recorded for confirmation: %', new.number, sqlerrm;
    end;
  end if;
  return null;
end $$;

drop trigger if exists sales_fee_credit on public.sales;
create trigger sales_fee_credit after update of journal_id on public.sales
  for each row when (old.journal_id is null and new.journal_id is not null and new.doc_type = 'credit_note' and new.original_sale_id is not null)
  execute function private.fee_credit_on_post();

-- A lead confirms a credit note waiting: it is recorded as the supplier's credit note against the fee bill in the
-- client's books (record_vendor_credit, as the lead, dated the credit note's day or the bill's if later, its number as
-- the supplier's reference), each credited invoice line against the bill line made from it (else the amount across the
-- bill's lines in order). p_note: the reason recorded (else "Credit note X on fee invoice Y"). A refusal by the books
-- (a closed period, the bill paid off differently) keeps it waiting with the reason: {ok: false, error, credit}.
-- Otherwise {ok: true, credit}.
create or replace function public.practice_fee_credit_confirm(p_id uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare fc public.practice_fee_credits; c public.practice_clients; o public.orgs; x public.practice_fee_bills; b public.bills;
  cn public.sales; inv public.sales; v_note text := nullif(trim(coalesce(p_note, '')), ''); v_lines jsonb; v_left numeric; v_take numeric;
  bl record; vc jsonb; v_firm text; v_err text;
begin
  select * into fc from practice_fee_credits where id = p_id for update;
  if fc.id is null then raise exception 'Credit note not found.'; end if;
  perform private.practice_require(fc.practice_id, true);
  if fc.status <> 'pending' then raise exception 'This credit note is % already.', fc.status; end if;
  if length(v_note) > 500 then raise exception 'Keep the note under 500 characters.'; end if;
  select * into c from practice_clients where id = fc.client_id;
  select * into o from orgs where id = c.org_id;
  if not (c.status = 'active' and c.mode = 'full' and o.managed_by is not distinct from c.practice_id and o.read_only_at is null) then
    raise exception 'You no longer keep %''s books under full mandate, so the credit note cannot go into them. A partner can dismiss it.',
      coalesce(o.name, c.business_name);
  end if;
  select * into x from practice_fee_bills where id = fc.fee_bill_id;
  select * into b from bills where id = x.bill_id;
  if x.status <> 'posted' or b.id is null or b.status not in ('approved', 'partially_paid', 'paid') then
    raise exception 'The fee bill is no longer in the client''s books, so the credit note cannot go against it. A partner can dismiss it.';
  end if;
  select * into cn from sales where id = fc.credit_sale_id;
  select * into inv from sales where id = fc.sale_id;
  select name into v_firm from practices where id = fc.practice_id;

  -- Each credited invoice line against the bill line made from it: the bill's lines follow the invoice's, in order.
  with orig as (select id, row_number() over (order by line_no, id) as rk from sale_lines where sale_id = fc.sale_id),
    bls as (select id, row_number() over (order by line_no, id) as rk, private.bill_line_creditable(id) as cr from bill_lines where bill_id = b.id),
    want as (select o2.rk, sum(l.gross) as amt from sale_lines l join orig o2 on o2.id = l.original_line_id where l.sale_id = cn.id group by o2.rk)
  select case when count(*) > 0 and bool_and(bls.id is not null and w.amt > 0 and w.amt <= bls.cr + 0.004) and abs(sum(w.amt) - fc.amount) < 0.005
    then jsonb_agg(jsonb_build_object('bill_line_id', bls.id, 'amount', w.amt) order by w.rk) end
  into v_lines
  from want w left join bls on bls.rk = w.rk;
  -- Else the amount across the bill's lines in order, each up to what it can still take.
  if v_lines is null then
    v_left := fc.amount; v_lines := '[]'::jsonb;
    for bl in select id, private.bill_line_creditable(id) as cr from bill_lines where bill_id = b.id order by line_no, id loop
      exit when v_left <= 0.004;
      v_take := least(v_left, bl.cr);
      if v_take > 0 then
        v_lines := v_lines || jsonb_build_array(jsonb_build_object('bill_line_id', bl.id, 'amount', v_take));
        v_left := v_left - v_take;
      end if;
    end loop;
    if v_left > 0.004 then
      raise exception 'Bill % can take only ₦% more in credit notes, less than this credit note''s ₦%. A partner can dismiss it.', b.number,
        to_char(fc.amount - v_left, 'FM999,999,999,990.00'), to_char(fc.amount, 'FM999,999,999,990.00');
    end if;
  end if;

  begin
    vc := public.record_vendor_credit(o.id, jsonb_build_object('bill_id', b.id, 'credit_date', greatest(cn.issue_date, b.bill_date),
      'vendor_ref', cn.number, 'reason', coalesce(v_note, 'Credit note ' || cn.number || ' on fee invoice ' || inv.number), 'lines', v_lines));
  exception when others then
    v_err := left(sqlerrm, 500);
    update practice_fee_credits set error = v_err, updated_at = now() where id = fc.id returning * into fc;
    return jsonb_build_object('ok', false, 'error', v_err, 'credit', to_jsonb(fc));
  end;
  update practice_fee_credits set status = 'posted', vendor_credit_id = (vc->>'id')::uuid, error = null, note = v_note, decided_by = auth.uid(),
    decided_at = now(), updated_at = now()
  where id = fc.id
  returning * into fc;
  perform private.activity_event(o.id, 'fee_credit_posted', 'Credit note ' || (vc->>'number') || ' from ' || v_firm || ' for fee credit note ' || cn.number,
    jsonb_build_object('practice_id', fc.practice_id, 'client_id', fc.client_id, 'credit_sale_id', cn.id, 'credit_note', cn.number,
      'vendor_credit_id', vc->>'id', 'vendor_credit', vc->>'number', 'bill_id', b.id, 'bill', b.number, 'total', fc.amount));
  return jsonb_build_object('ok', true, 'credit', to_jsonb(fc));
end $$;

-- A partner leaves a credit note waiting out of the client's books, with a reason of 5 to 500 characters. The record.
create or replace function public.practice_fee_credit_dismiss(p_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare fc public.practice_fee_credits; m public.practice_members; v_reason text := trim(coalesce(p_reason, ''));
begin
  select * into fc from practice_fee_credits where id = p_id for update;
  if fc.id is null then raise exception 'Credit note not found.'; end if;
  m := private.practice_require(fc.practice_id, true);
  if m.role <> 'partner' then raise exception 'Only a partner dismisses a credit note.' using errcode = '42501'; end if;
  if fc.status <> 'pending' then raise exception 'This credit note is % already.', fc.status; end if;
  if length(v_reason) < 5 then raise exception 'Give the reason for dismissing it.'; end if;
  if length(v_reason) > 500 then raise exception 'Keep the reason under 500 characters.'; end if;
  update practice_fee_credits set status = 'dismissed', note = v_reason, decided_by = auth.uid(), decided_at = now(), updated_at = now()
  where id = fc.id
  returning * into fc;
  return to_jsonb(fc);
end $$;

-- Latest definition (20261124001100_practice_fees.sql), with each client's credit notes on fee invoices (fee_credits,
-- waiting first, then newest: [{id, fee_bill_id, sale_id, invoice, credit_sale_id, credit_note, issue_date, amount, status,
-- error, note, decided_at, decided_by_name, created_at}]), and each posted fee bill's note: a credit note waits to be
-- confirmed, or the invoice was credited by more than the credit notes posted on the bill.
create or replace function public.practice_fees(p_practice uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.practice_members; f public.orgs; w public.wallets; t public.tax_wallets; v jsonb;
begin
  m := private.practice_require(p_practice, true);
  select o.* into f from practices p join orgs o on o.id = p.firm_org_id where p.id = p_practice;
  v := jsonb_build_object(
    'firm_org', case when f.id is not null then jsonb_build_object('id', f.id, 'name', f.name, 'identity_status', f.identity_status) end,
    'clients', coalesce((
      select jsonb_agg(jsonb_build_object(
          'client_id', c.id, 'business_name', coalesce(o.name, c.business_name), 'mode', c.mode, 'fee_customer_id', c.fee_customer_id,
          'outstanding', coalesce((select sum(s.total - s.amount_paid - s.credited) from sales s
            where s.org_id = f.id and s.customer_id = c.fee_customer_id and s.doc_type = 'invoice' and s.status in ('open', 'partially_paid')), 0),
          'invoices', coalesce((
            select jsonb_agg(jsonb_build_object('id', s.id, 'number', s.number, 'issue_date', s.issue_date, 'total', s.total, 'credited', s.credited,
                'balance', case when s.status in ('open', 'partially_paid') then s.total - s.amount_paid - s.credited else 0 end, 'status', s.status)
              order by s.issue_date desc, s.created_at desc)
            from (select * from sales where org_id = f.id and customer_id = c.fee_customer_id and doc_type = 'invoice'
                  order by issue_date desc, created_at desc limit 100) s), '[]'::jsonb),
          'schedules', coalesce((
            select jsonb_agg(jsonb_build_object('id', r.id, 'frequency', r.frequency, 'day_of_month', r.day_of_month, 'next_run', r.next_run,
                'status', r.status, 'total', (
                  select coalesce(sum(round(round((l->>'qty')::numeric * (l->>'unit_price')::numeric, 2)
                    * (1 + case when f.vat_registered and l->>'vat_treatment' = 'standard' then private.vat_rate(r.next_run) else 0 end), 2)), 0)
                  from jsonb_array_elements(r.lines) l where not coalesce((l->>'once')::boolean, false)))
              order by r.created_at)
            from recurring_invoices r
            where r.org_id = f.id and (r.practice_client_id = c.id or (c.fee_customer_id is not null and r.customer_id = c.fee_customer_id))), '[]'::jsonb),
          'fee_bills', coalesce((
            select jsonb_agg(jsonb_build_object('id', x.id, 'sale_id', x.sale_id, 'status', x.status, 'error', x.error, 'bill_id', x.bill_id,
                'dismiss_reason', x.dismiss_reason, 'credited', coalesce(fs.credited, 0),
                'note', case
                  when x.status = 'posted' and exists (select 1 from practice_fee_credits k where k.fee_bill_id = x.id and k.status = 'pending')
                    then 'a credit note waits to be confirmed for the bill'
                  when x.status = 'posted' and coalesce(fs.credited, 0) - coalesce((select sum(k.amount) from practice_fee_credits k
                    where k.fee_bill_id = x.id and k.status = 'posted'), 0) > 0.004
                    then 'credited on the invoice, not on the bill' end)
              order by x.created_at desc)
            from practice_fee_bills x left join sales fs on fs.id = x.sale_id where x.client_id = c.id), '[]'::jsonb),
          'fee_credits', coalesce((
            select jsonb_agg(jsonb_build_object('id', k.id, 'fee_bill_id', k.fee_bill_id, 'sale_id', k.sale_id, 'invoice', si.number,
                'credit_sale_id', k.credit_sale_id, 'credit_note', sc.number, 'issue_date', sc.issue_date, 'amount', k.amount, 'status', k.status,
                'error', k.error, 'note', k.note, 'decided_at', k.decided_at,
                'decided_by_name', (select pm.display_name from practice_members pm where pm.practice_id = k.practice_id and pm.user_id = k.decided_by
                                    order by pm.created_at limit 1),
                'created_at', k.created_at)
              order by (k.status = 'pending') desc, k.created_at desc, k.id)
            from practice_fee_credits k join sales si on si.id = k.sale_id join sales sc on sc.id = k.credit_sale_id where k.client_id = c.id), '[]'::jsonb))
        order by lower(coalesce(o.name, c.business_name)), c.id)
      from practice_clients c left join orgs o on o.id = c.org_id
      where c.practice_id = p_practice and (c.status = 'active' or (c.status = 'ended' and c.fee_customer_id is not null))), '[]'::jsonb));
  if m.role = 'partner' then
    select * into w from wallets where org_id = f.id order by (rail = f.payment_rail) desc, created_at desc limit 1;
    select * into t from tax_wallets where org_id = f.id;
    v := v || jsonb_build_object('wallets', jsonb_build_object(
      'wallet', jsonb_build_object('status', w.status, 'balance', case when w.id is not null then private.wallet_ledger(w.id) else 0 end),
      'tax_wallet', jsonb_build_object('status', t.status, 'balance', case when t.id is not null then private.tax_wallet_ledger(t.id) else 0 end)));
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 12. Grants
-- ---------------------------------------------------------------------------
-- core.sql grants every private function to authenticated: the helpers this migration creates are not callable by the
-- signed-in person.
revoke all on function private.reg_kind(text), private.same_reg(text, text), private.letter_fingerprint(uuid), private.intake_snapshot(uuid),
  private.fee_credit_note(uuid), private.fee_credit_on_post(), private.guard_journals()
  from public, anon, authenticated;
revoke execute on function public.practice_fee_credit_confirm(uuid, text), public.practice_fee_credit_dismiss(uuid, text) from public, anon;
grant execute on function public.practice_fee_credit_confirm(uuid, text), public.practice_fee_credit_dismiss(uuid, text) to authenticated;
