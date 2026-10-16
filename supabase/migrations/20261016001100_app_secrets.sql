-- Edge functions read their API keys from Supabase Vault when the key is not set as an Edge
-- Function secret. Only the service role (used inside edge functions) may call this, and only
-- for the names listed here. Store a key with:
--   select vault.create_secret('<value>', 'GEMINI_API_KEY', 'Gemini key for the ai function');
create or replace function public.app_secret(p_name text) returns text
language sql stable security definer set search_path = public, vault as $$
  select s.decrypted_secret from vault.decrypted_secrets s
  where s.name = p_name
    and p_name in ('GEMINI_API_KEY', 'GEMINI_MODEL', 'ELEVENLABS_API_KEY', 'ELEVENLABS_PHONE_NUMBER_ID',
                   'ELEVENLABS_VOICE_ID', 'VAPID_PUBLIC_KEY', 'VAPID_PRIVATE_KEY', 'VAPID_SUBJECT', 'PUSH_HOOK_SECRET')
  order by s.created_at desc
  limit 1
$$;
revoke all on function public.app_secret(text) from public, anon, authenticated;
grant execute on function public.app_secret(text) to service_role;
