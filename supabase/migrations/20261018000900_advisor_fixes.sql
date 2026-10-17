-- Counta: fixes from the Supabase advisors after the Atlas update (17 Oct 2026).

-- 1. Signed-in callers only. These were executable by anonymous callers through the default grant on new functions.
--    Each one already checks membership inside, so an anonymous call failed; this closes the door anyway.
revoke execute on function public.get_chart(uuid), public.create_account(uuid, text, text, text), public.update_account(uuid, text, jsonb),
  public.post_manual_journal(uuid, date, text, jsonb, jsonb), public.reverse_journal(uuid, text), public.update_org_settings(uuid, jsonb),
  public.open_bank_account(uuid, text, text, jsonb), public.update_bank_account(uuid, jsonb) from public, anon;
grant execute on function public.get_chart(uuid), public.create_account(uuid, text, text, text), public.update_account(uuid, text, jsonb),
  public.post_manual_journal(uuid, date, text, jsonb, jsonb), public.reverse_journal(uuid, text), public.update_org_settings(uuid, jsonb),
  public.open_bank_account(uuid, text, text, jsonb), public.update_bank_account(uuid, jsonb) to authenticated;

-- 2. The journal guard was recreated in the payables migration without a fixed search_path.
alter function private.guard_journals() set search_path = public, private;

-- 3. Index behind the payment rail foreign key on orgs.
create index if not exists orgs_payment_rail_fk on public.orgs(payment_rail);
