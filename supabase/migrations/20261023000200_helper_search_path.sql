-- Two small helpers from the onboarding migration get a fixed search path, as Supabase's security linter asks.
-- They only use built-in functions, so an empty search path changes nothing else.
alter function private.person(jsonb) set search_path = '';
alter function private.kyc_missing(jsonb) set search_path = '';
