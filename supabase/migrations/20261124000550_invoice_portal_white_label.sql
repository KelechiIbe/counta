-- The supplier invoice portal page says whether the business is white-labelled, so it can drop "Powered by Counta" and the
-- Counta wording for a managed business. Otherwise as before (supplier_invoices.sql), no new grants (create or replace keeps them).
create or replace function public.invoice_portal(p_token text) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('business', o.name, 'logo_path', o.logo_path, 'brand_color', o.brand_color,
    'open', o.invoice_portal_on and not o.is_sample and private.feature_on(o.id, 'supplier_portal'),
    'sample', o.is_sample, 'white_label', private.white_label(o.id))
  from orgs o where o.invoice_portal_token = p_token and p_token ~ '^[0-9a-f]{32}$'
$$;
