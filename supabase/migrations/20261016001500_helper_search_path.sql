-- Pin the search path of the small import helpers (Supabase linter 0011). They only use built-in functions.
alter function private.sells(text) set search_path = '';
alter function private.type_account(text) set search_path = '';
alter function private.num(text) set search_path = '';
alter function private.date_or_null(text) set search_path = '';
alter function private.clean_attrs(jsonb) set search_path = '';
