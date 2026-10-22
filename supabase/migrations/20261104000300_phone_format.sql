-- Counta · phone numbers as Nigerians write them
--
-- A business's phone number, a team member's and a practice's are kept the way people in Nigeria write and read them: eleven
-- digits from 0, such as 09031571395. "+234 903 157 1395", "2349031571395", "+234 0903 157 1395" and "903 157 1395" are all
-- kept as 09031571395, whichever screen or function saves them. A number from another country keeps its country code, with
-- a plus. Counta still turns a number into +2349031571395 (or 2349031571395) on its own where WhatsApp, Martina's calls and
-- Flutterwave need that, so nothing else changes. Customers' and suppliers' numbers are left as they are.

-- A phone number in the form Counta keeps: 11 digits from 0 for a Nigerian number, + and the digits for a number abroad,
-- and anything else exactly as it was typed. Never fails.
create or replace function private.local_phone(p text) returns text
language plpgsql immutable set search_path = '' as $$
declare
  t text := btrim(coalesce(p, ''));
  d text := regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g');
  abroad boolean;
begin
  if t = '' then return null; end if;
  if d = '' then return t; end if;
  abroad := left(t, 1) = '+' or left(d, 2) = '00';
  if left(d, 2) = '00' then d := substr(d, 3); end if;
  if d ~ '^2340[0-9]{10}$' then return substr(d, 4); end if;          -- +234 0903 157 1395
  if d ~ '^234[0-9]{10}$' then return '0' || substr(d, 4); end if;    -- +234 903 157 1395, 2349031571395
  if d ~ '^0[0-9]{10}$' then return d; end if;                        -- 0903 157 1395
  if not abroad and d ~ '^[789][01][0-9]{8}$' then return '0' || d; end if;   -- 903 157 1395
  if abroad and length(d) between 8 and 15 then return '+' || d; end if;      -- +44 7911 123456
  return t;
end $$;

-- Every way a phone number is saved on a business, a team member or a practice goes through it: Settings, onboarding,
-- invitations, TaxStreem sign-in and the functions that write these rows.
create or replace function private.phone_format() returns trigger
language plpgsql set search_path = public, private as $$
begin
  new.phone := private.local_phone(new.phone);
  return new;
end $$;
revoke all on function private.phone_format() from public, anon, authenticated;

drop trigger if exists orgs_phone_format on public.orgs;
create trigger orgs_phone_format before insert or update of phone on public.orgs for each row execute function private.phone_format();
drop trigger if exists members_phone_format on public.members;
create trigger members_phone_format before insert or update of phone on public.members for each row execute function private.phone_format();
drop trigger if exists practices_phone_format on public.practices;
create trigger practices_phone_format before insert or update of phone on public.practices for each row execute function private.phone_format();

-- The numbers already saved, once.
update public.orgs set phone = private.local_phone(phone) where phone is distinct from private.local_phone(phone);
update public.members set phone = private.local_phone(phone) where phone is distinct from private.local_phone(phone);
update public.practices set phone = private.local_phone(phone) where phone is distinct from private.local_phone(phone);
