-- E-invoicing: the main branch's postcode is required (docs/e-invoicing.md).
--
-- NRS refused the first invoices sent from production (31 October 2026) because the seller's address had no postcode:
-- "invoicerequest.invoice.accountingsupplierparty.postaladdress.postalzone is a required field". Counta had asked for the
-- postcode without requiring it. Now e-invoicing cannot be switched on without it, and a business already sending sees it
-- as the one thing to put right. (The einvoice function also stops such an invoice before it reaches NRS, and says what to
-- add.) Only the readiness check changes; no record is touched.

create or replace function private.einvoice_readiness(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; s public.einvoice_settings; b public.locations; v jsonb := '[]'::jsonb; v_missing text[];
  n_items int; n_coded int; n_wait int; n_review int; n_cust int; v_tin text;
begin
  select * into o from orgs where id = p_org;
  select * into s from einvoice_settings where org_id = p_org;
  select * into b from locations where org_id = p_org order by is_main desc, created_at limit 1;

  -- The business's Tax ID.
  v_tin := regexp_replace(coalesce(o.tin, ''), '[^0-9]', '', 'g');
  v := v || jsonb_build_object('id', 'tin', 'blocking', true, 'ok', v_tin <> '', 'title', 'The business''s Tax ID', 'link', '/settings#books',
    'detail', case when v_tin = '' then 'Add the business''s Tax ID in Settings, under Books and tax.'
      when o.tin_status in ('verified', 'confirmed') then 'Tax ID ending ' || right(v_tin, 4) || ', checked with NRS.'
      else 'Tax ID ending ' || right(v_tin, 4) || '. It has not been checked with NRS yet.' end);

  -- Email and phone: NRS puts both on the supplier's side of each invoice.
  v_missing := array_remove(array[case when nullif(btrim(coalesce(o.email, '')), '') is null then 'email' end,
    case when nullif(btrim(coalesce(o.phone, '')), '') is null then 'phone number' end], null);
  v := v || jsonb_build_object('id', 'contact', 'blocking', true, 'ok', cardinality(v_missing) = 0, 'title', 'Email and phone', 'link', '/settings#business',
    'detail', case when cardinality(v_missing) = 0 then o.email || ' and ' || o.phone || '.' else 'Add the business''s ' || private.words_and(v_missing) || ' in Settings.' end);

  -- The address on the invoice: the main branch's street, city, state, LGA and postcode. NRS refuses an invoice whose
  -- seller has no postcode (postal_zone), as the sandbox showed on 31 October 2026.
  v_missing := array_remove(array[case when nullif(btrim(coalesce(b.address, '')), '') is null then 'street address' end,
    case when b.city is null then 'city' end, case when b.state is null then 'state' end, case when b.lga is null then 'LGA' end,
    case when b.postcode is null then 'postcode' end], null);
  v := v || jsonb_build_object('id', 'address', 'blocking', true, 'ok', b.id is not null and cardinality(v_missing) = 0, 'title', 'The business address', 'link', '/inventory/locations',
    'detail', case when b.id is null then 'Add the main branch under Locations.'
      when cardinality(v_missing) = 0 then b.address || ', ' || b.city || ', ' || b.lga || ', ' || b.state || ' ' || b.postcode || '.'
      else 'Add the ' || private.words_and(v_missing) || ' of ' || b.name || ' under Locations. NRS needs the full address on every invoice.' end);

  -- The keys.
  v_missing := array_remove(array[case when s.business_id is null then 'Business ID' end, case when s.service_id is null then 'Service ID' end,
    case when s.api_key_ct is null then 'API key' end, case when s.api_secret_ct is null then 'API secret' end,
    case when s.crypto_ct is null then 'crypto_keys.txt' end], null);
  v := v || jsonb_build_object('id', 'keys', 'blocking', true, 'ok', coalesce(s.platform_keys, false) or (s.org_id is not null and cardinality(v_missing) = 0),
    'title', 'Your NRS keys', 'link', '/settings#einvoicing',
    'detail', case when s.platform_keys then 'Running on TaxStreem''s keys while NRS is in test mode. Add your own before you go live.'
      when s.org_id is null or cardinality(v_missing) = 5 then 'Add the Business ID, Service ID, API key, API secret and crypto_keys.txt from your NRS dashboard.'
      when cardinality(v_missing) = 0 then 'All five are saved.'
      else 'Add the ' || private.words_and(v_missing) || '.' end);

  -- NRS has accepted them.
  v := v || jsonb_build_object('id', 'check', 'blocking', true, 'ok', coalesce(s.check_ok and s.check_version = s.keys_version, false),
    'title', 'NRS accepts the keys', 'link', '/settings#einvoicing',
    'detail', case when s.checked_at is null or s.check_version is distinct from s.keys_version then 'Test the keys with NRS.'
      else coalesce(s.check_note, case when s.check_ok then 'NRS accepted them.' else 'NRS did not accept them.' end) end);

  -- The service code. Required when the business sells services; goods sellers use it for delivery and other service lines.
  -- One Gemini was unsure of counts once the owner confirms it.
  v := v || jsonb_build_object('id', 'service', 'blocking', coalesce(o.offering, 'goods') in ('services', 'both'),
    'ok', s.service_code is not null and not coalesce(s.service_review, false),
    'title', 'Service code', 'link', '/settings#einvoicing',
    'detail', case when s.service_code is not null and coalesce(s.service_review, false) then s.service_code || ' ' || coalesce(private.nrs_label('services-codes', s.service_code), '')
        || '. Gemini is ' || round(coalesce(private.num(s.service_basis->>'confidence'), 0) * 100) || '% sure: confirm it or choose another.'
      when s.service_code is not null then s.service_code || ' ' || coalesce(private.nrs_label('services-codes', s.service_code), '') || '.'
      when s.org_id is not null and s.service_checked_at is null then 'Gemini is choosing it.'
      else 'Choose the code for the services you sell.' end);

  -- HS codes on items: Gemini chooses them; an invoice line waits for its item's code.
  select count(*), count(*) filter (where hs_code is not null), count(*) filter (where hs_checked_at is null and coalesce(hs_basis->>'source', '') <> 'manual'),
         count(*) filter (where hs_review)
    into n_items, n_coded, n_wait, n_review
  from items where org_id = p_org and not archived;
  v := v || jsonb_build_object('id', 'items', 'blocking', false, 'ok', n_coded = n_items and n_review = 0, 'title', 'HS codes on items', 'link', '/inventory/items',
    'counts', jsonb_build_object('items', n_items, 'coded', n_coded, 'waiting', n_wait, 'review', n_review),
    'detail', case when n_items = 0 then 'No items yet.'
      else n_coded || ' of ' || n_items || case when n_items = 1 then ' item has' else ' items have' end || ' an HS code.'
        || case when n_wait > 0 and s.org_id is not null then ' Gemini is choosing ' || n_wait || ' more.' else '' end
        || case when n_review > 0 then ' ' || n_review || ' to confirm.' else '' end end);

  -- Business and government customers need a Tax ID on their invoices.
  select count(*) into n_cust from customers where org_id = p_org and not archived and kind in ('business', 'government')
    and coalesce(upper(country), 'NG') = 'NG' and nullif(btrim(coalesce(tin, '')), '') is null;
  v := v || jsonb_build_object('id', 'customers', 'blocking', false, 'ok', n_cust = 0, 'title', 'Tax IDs of business customers', 'link', '/sell/customers',
    'detail', case when n_cust = 0 then 'Every business and government customer has a Tax ID.'
      else n_cust || case when n_cust = 1 then ' business or government customer has' else ' business or government customers have' end
        || ' no Tax ID. Invoices to them wait until one is added.' end);
  return v;
end $$;


revoke all on function private.einvoice_readiness(uuid) from public, anon, authenticated;
