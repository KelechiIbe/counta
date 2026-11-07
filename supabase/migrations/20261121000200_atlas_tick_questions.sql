-- The three-minute tick also wakes Atlas when questions in the books inbox are waiting for their short list of likely
-- accounts (not only when new bank lines arrive), for businesses with AI reading on. Each tick gives forty questions per
-- business their list, so the backlog clears over a few ticks. Safe to run twice.

create or replace function public.svc_orgs_with_questions() returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(distinct org_id), '[]'::jsonb) from ai_proposals
  where status = 'pending' and source_type = 'bank_line' and not (proposal ? 'alternatives') and coalesce(proposal->>'kind', '') not in ('invoice_match', 'bill_match')
    and private.feature_on(org_id, 'ai_reading') is not false
$$;

create or replace function private.agents_tick() returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if exists (select 1 from bank_lines where status = 'unmatched' and ai_attempts < 3)
     or jsonb_array_length(public.svc_orgs_with_questions()) > 0 then
    perform private.call_function('atlas', jsonb_build_object('action', 'classify_all'));
  end if;
  perform private.vat_tick();
end $$;

revoke execute on function public.svc_orgs_with_questions() from public, anon, authenticated;
grant execute on function public.svc_orgs_with_questions() to service_role;
