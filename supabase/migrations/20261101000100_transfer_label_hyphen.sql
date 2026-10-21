-- Counta · the name on one-time accounts, with a hyphen
--
-- One-time accounts were named "TaxStreem/<business>". The bank's name lookup drops the slash, so customers saw
-- "TaxStreemKelandellen". They are now named "TaxStreem-<business>". The character between the prefix and the business's
-- name is private.config 'va_separator' (a hyphen unless TaxStreem changes it).

insert into private.config (key, value) values ('va_separator', '-') on conflict (key) do nothing;

create or replace function private.transfer_label(o public.orgs) returns text
language sql stable security definer set search_path = public, private as $$
  select left(coalesce((select value from private.config where key = 'va_prefix'), 'TaxStreem')
    || coalesce((select value from private.config where key = 'va_separator'), '-')
    || coalesce(nullif(trim(o.transfer_name), ''), nullif(private.transfer_short(o.name), ''), o.name), 50)
$$;

-- The transfer settings for the Payments screen, now with the separator the screen shows after the prefix.
create or replace function public.transfer_settings(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs; c public.transfer_name_checks;
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  select * into c from transfer_name_checks where org_id = p_org and label = private.transfer_label(o) order by at desc limit 1;
  return jsonb_build_object('mode', o.transfer_mode, 'name', o.transfer_name, 'default_name', private.transfer_short(o.name),
    'prefix', coalesce((select value from private.config where key = 'va_prefix'), 'TaxStreem'),
    'separator', coalesce((select value from private.config where key = 'va_separator'), '-'), 'label', private.transfer_label(o),
    'seen', case when c.id is not null then jsonb_build_object('label', c.label, 'shown', c.shown, 'bank', c.bank, 'error', c.error, 'at', c.at) end,
    'checks_today', (select count(*) from transfer_name_checks where org_id = p_org and at > now() - interval '1 day'),
    'can_change', m.role = 'owner');
end $$;

grant execute on function public.transfer_settings(uuid) to authenticated;
revoke execute on function public.transfer_settings(uuid) from public, anon;
