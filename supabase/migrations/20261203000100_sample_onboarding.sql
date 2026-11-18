-- Setting up a business never makes the sample business that business.
--
-- Martina's token loaded the onboarding profile for the business open in the app. With the sample business open, that
-- tied the person's new profile to the sample, and submitting the profile renamed the sample and filled in the real
-- business's details (its registration number, Tax ID, directors and address) while it stayed a sample. kyc_row, which
-- every profile function goes through, now refuses the sample business and frees a draft that was tied to one. The app no
-- longer hands Martina the open business while a business is being set up (src/guide/GuideProvider.tsx).
--
-- Repair: a profile submitted to a sample business goes back to a draft with its answers, CAC record and Tax ID check
-- kept. The CAC document it filed in the sample's folder is let go, so it is uploaded again under the real business. The
-- sample gets back what the sample builder gave it. Submitting the draft again sets the business up as a business of its
-- own.

create or replace function private.kyc_row(p_user uuid, p_org uuid default null) returns public.kyc_profiles
language plpgsql security definer set search_path = public, private as $$
declare k public.kyc_profiles; v_found boolean;
begin
  -- The sample business is there to look around in: no business profile belongs to it.
  if p_org is not null and coalesce((select is_sample from orgs where id = p_org), false) then
    raise exception 'This is the sample business. To set up your own business, use Add a business.';
  end if;
  if p_org is not null then
    select * into k from kyc_profiles where org_id = p_org order by (status = 'submitted') desc, updated_at desc limit 1;
    if found then return k; end if;
    if private.is_managed(p_org) then
      insert into kyc_profiles (user_id, org_id, for_business) values (p_user, p_org, true) on conflict do nothing returning * into k;
      if k.id is null then select * into k from kyc_profiles where org_id = p_org and status = 'draft' and for_business; end if;
      return k;
    end if;
  end if;
  select * into k from kyc_profiles where user_id = p_user and status = 'draft' and not for_business;
  v_found := found;
  -- A draft tied to a sample business (before that was refused) belongs to no business yet: submitting it sets one up.
  if v_found and k.org_id is not null and coalesce((select is_sample from orgs where id = k.org_id), false) then
    update kyc_profiles set org_id = null, updated_at = now() where id = k.id returning * into k;
  end if;
  if not v_found then
    insert into kyc_profiles (user_id, org_id) values (p_user, p_org) on conflict do nothing returning * into k;
    if k.id is null then select * into k from kyc_profiles where user_id = p_user and status = 'draft' and not for_business; end if;
  elsif p_org is not null and (k.org_id is not null and k.org_id <> p_org
      or k.org_id is null and (k.search <> '{}'::jsonb or k.cac is not null or k.manual is not null or k.tin is not null or k.web is not null
                               or k.doc is not null or k.answers <> '{}'::jsonb)) then
    raise exception 'You have another business profile in progress. Finish it first, then come back to this business.';
  elsif p_org is not null and k.org_id is null then
    update kyc_profiles set org_id = p_org where id = k.id returning * into k;
  end if;
  return k;
end $$;
revoke all on function private.kyc_row(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Repair: profiles submitted to a sample business (run once below; the tests run it too)
-- ---------------------------------------------------------------------------
create or replace function private.sample_profiles_repair() returns int
language plpgsql security definer set search_path = public, private as $$
declare r record; v_fixed int := 0;
begin
  for r in
    select k.id, k.user_id, k.org_id from kyc_profiles k join orgs o on o.id = k.org_id
    where o.is_sample and not k.for_business order by k.created_at
  loop
    -- The person started another profile since: both are left as they are, for TaxStreem to sort out by hand.
    if exists (select 1 from kyc_profiles x where x.user_id = r.user_id and x.status = 'draft' and not x.for_business and x.id <> r.id) then
      raise notice 'Profile % is tied to sample business % but its owner has another draft: left as it is.', r.id, r.org_id;
      continue;
    end if;
    -- The sample as the sample builder makes it (private.create_sample_business_build).
    update orgs set name = 'Kelandellen Company Limited', phone = '+234 803 555 0142', vat_registered = true,
      rc_number = null, tin = null, tin_check = null, tin_checked_at = null, tin_status = null, legal_form = 'company',
      address = null, registered_office = null, incorporation_date = null, commenced_on = null, principal_activity = null,
      directors = '[]'::jsonb, industry = 'retail', offering = null, category_id = null, professional_services = false,
      revenue_account = '4107', website = null, share_info = '{}'::jsonb, company_secretary = null
    where id = r.org_id;
    update locations set state = null, lga = null where org_id = r.org_id;
    update kyc_profiles set status = 'draft', submitted_at = null, org_id = null, doc = null, updated_at = now() where id = r.id;
    v_fixed := v_fixed + 1;
  end loop;
  return v_fixed;
end $$;
revoke all on function private.sample_profiles_repair() from public, anon, authenticated;

select private.sample_profiles_repair() as profiles_taken_back_from_samples;
