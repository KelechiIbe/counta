-- A business that sells services only sees no stock, products or till; a professional services firm is treated as one for
-- tax (never a small company) and invoices to its own income account; the checklist and the compliance score speak to the
-- business as it is (a business name's income tax is its owners' personal income tax; a business CAC shows as inactive is
-- registered, not unregistered). A login the LIRS bot found wrong is marked so even when its report could not be saved.

-- ---------------------------------------------------------------------------
-- 1. The income account and the professional services flag follow the category
-- ---------------------------------------------------------------------------
-- The usual income account for a category of services, on TaxStreem's chart (null: keep the business's own).
create or replace function private.category_revenue_account(p_category text) returns text
language sql immutable set search_path = public as $$
  select case p_category
    when 'professional' then '4114' when 'creative' then '4114' when 'technology' then '4110' when 'logistics' then '4108'
    when 'construction' then '4106' when 'education' then '4116' when 'hospitality' then '4109' when 'food' then '4109'
    when 'real_estate' then '4113' when 'finance' then '4111' when 'facility' then '4115' when 'health' then '4121' end
$$;

-- When a category is chosen: a professional services firm says so and charges VAT, and a business still on the default
-- income account (4107, wholesale and retail) that sells services takes its category's account.
create or replace function private.org_category_defaults() returns trigger
language plpgsql set search_path = public, private as $$
begin
  if new.category_id is not null and (tg_op = 'INSERT' or new.category_id is distinct from old.category_id) then
    -- A professional services firm is never a small company, so it charges VAT whatever its size (NTA 2025 s.202).
    if new.category_id = 'professional' then new.professional_services := true; new.vat_registered := true; end if;
    if new.revenue_account = '4107' and coalesce(new.offering, '') in ('services', 'both') then
      new.revenue_account := coalesce(private.category_revenue_account(new.category_id), new.revenue_account);
    end if;
  end if;
  return new;
end $$;
drop trigger if exists orgs_category_defaults on public.orgs;
create trigger orgs_category_defaults before insert or update of category_id on public.orgs
  for each row execute function private.org_category_defaults();

-- Sales post to the posting rule for sales revenue, so the rule follows the income account: when the account changes and
-- the rule still matched the old one (or was never set), the rule moves with it. A rule the business set apart on the
-- chart of accounts stays as it is. The settings screen sets both itself.
create or replace function private.org_revenue_rule() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.revenue_account is not null and (tg_op = 'INSERT' or new.revenue_account is distinct from old.revenue_account)
     and private.acct(new.id, 'sales_revenue') is distinct from new.revenue_account
     and private.acct(new.id, 'sales_revenue') = coalesce(case when tg_op = 'UPDATE' then old.revenue_account end, '4107') then
    insert into posting_rules (org_id, role, account_code) values (new.id, 'sales_revenue', new.revenue_account)
    on conflict (org_id, role) do update set account_code = excluded.account_code, updated_at = now();
  end if;
  return null;
end $$;
drop trigger if exists orgs_revenue_rule on public.orgs;
-- On a change of category too: the account the category set comes from the trigger before, not the statement.
create trigger orgs_revenue_rule after insert or update of revenue_account, category_id on public.orgs
  for each row execute function private.org_revenue_rule();

-- The businesses set up before this.
update public.orgs set professional_services = true where category_id = 'professional' and not professional_services;
update public.orgs set revenue_account = private.category_revenue_account(category_id)
where revenue_account = '4107' and coalesce(offering, '') in ('services', 'both') and private.category_revenue_account(category_id) is not null;

-- ---------------------------------------------------------------------------
-- 2. Onboarding: a services business is not asked what products it sells
-- ---------------------------------------------------------------------------
create or replace function private.kyc_missing(a jsonb) returns text[] language sql immutable as $$
  select array_remove(array[
    case when a->>'offering' is null then 'offering' end,
    case when a->>'category' is null then 'category' end,
    case when a->>'revenue_band' is null then 'revenue_band' end,
    case when coalesce(jsonb_array_length(a->'receive_methods'), 0) = 0 then 'receive_methods' end,
    case when coalesce(jsonb_array_length(a->'pay_methods'), 0) = 0 then 'pay_methods' end,
    case when coalesce(jsonb_array_length(a->'reasons'), 0) = 0 and coalesce(a->>'reason_note', '') = '' then 'reasons' end,
    case when coalesce(a->>'offering', '') <> 'services' and coalesce(jsonb_array_length(a->'examples'), 0) = 0 then 'examples' end,
    case when a->'filing'->>'vat' is null then 'filing_vat' end,
    case when a->'filing'->>'wht' is null then 'filing_wht' end,
    case when a->'filing'->>'cit' is null then 'filing_cit' end], null)
$$;

-- The first steps: a business that sells services only has no products to add.
create or replace function private.guide_steps(p_user uuid, p_org uuid, p_marks jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare k public.kyc_profiles; o public.orgs; v jsonb := '[]'::jsonb; s record; v_services boolean;
begin
  select * into k from kyc_profiles
  where (p_org is not null and org_id = p_org) or (user_id = p_user and status = 'draft')
  order by (org_id is not distinct from p_org) desc, (status = 'submitted') desc, updated_at desc limit 1;
  select * into o from orgs where id = p_org;
  v_services := coalesce(o.offering, k.answers->>'offering', '') = 'services';
  for s in select * from (values
    ('find_business', 'profile', false, k.source is not null),
    ('questions', 'profile', false, k.id is not null and array_length(private.kyc_missing(k.answers), 1) is null),
    ('submitted', 'profile', false, k.status = 'submitted'),
    -- The director's NIN: done once confirmed, or once a slip waits for TaxStreem (the rest is TaxStreem's part).
    ('identity', 'profile', false, p_org is not null and o.identity_status in ('not_required', 'verified', 'approved', 'review')),
    ('cac_document', 'profile', true, k.doc ? 'path'),
    ('account_number', 'first_steps', false, p_org is not null and exists (select 1 from wallets where org_id = p_org and status = 'active')),
    ('voice', 'first_steps', false, p_org is not null and (o.voice_id is not null or p_marks ? 'voice_chosen')),
    ('first_sale', 'first_steps', false, p_org is not null and exists (select 1 from sales where org_id = p_org
      and ((doc_type = 'receipt' and status = 'paid') or (doc_type = 'invoice' and status in ('open', 'partially_paid', 'paid'))))),
    ('bank_connect', 'first_steps', true, p_org is not null and exists (select 1 from bank_accounts where org_id = p_org and provider = 'mono' and active)),
    ('bank_statement', 'first_steps', true, p_org is not null and exists (select 1 from bank_imports where org_id = p_org)),
    ('products', 'first_steps', true, p_org is not null and exists (select 1 from items where org_id = p_org and not archived)),
    ('team', 'first_steps', true, p_org is not null and exists (select 1 from members where org_id = p_org and user_id is distinct from p_user))
  ) t(id, phase, optional, done) loop
    continue when s.id = 'products' and v_services;
    v := v || jsonb_build_object('id', s.id, 'phase', s.phase, 'optional', s.optional, 'done', coalesce(s.done, false),
      'skipped', s.optional and not coalesce(s.done, false) and p_marks ? ('skip_' || s.id));
  end loop;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 3. The compliance score speaks to the business as it is
-- ---------------------------------------------------------------------------
-- A business CAC lists but shows as inactive is registered: what it lacks is its annual returns. A business name's income
-- tax is its owners' personal income tax, filed with the state by 31 March. A professional services firm is never a small
-- company, so the ₦100 million line does not excuse its VAT. A services firm records its work by invoice.
create or replace function private.compliance_items(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; k public.kyc_profiles; a jsonb; v_out jsonb := '[]'::jsonb; r public.compliance_rules; v_ok boolean; v_cls text; v_small boolean;
  v_label text; v_text text; v_action text; v_inactive boolean; v_personal boolean; v_services boolean; v_till boolean; v_professional boolean;
begin
  select * into o from orgs where id = p_org;
  select * into k from kyc_profiles where org_id = p_org order by (status = 'submitted') desc, updated_at desc limit 1;
  a := coalesce(k.answers, '{}'::jsonb);
  v_cls := upper(coalesce(k.cac->'profile'->>'classification', ''));
  v_professional := coalesce(o.professional_services, false) or coalesce(o.category_id, a->>'category', '') = 'professional';
  v_small := a->>'revenue_band' in ('0_50m', '50_100m') and not v_professional;
  v_inactive := k.source = 'cac' and (k.cac->'profile'->>'active') = 'false';
  v_personal := private.income_tax_kind(p_org) in ('sole', 'partnership');
  v_services := coalesce(o.offering, a->>'offering', '') = 'services';
  v_till := not v_services or coalesce(o.category_id, a->>'category', '') in ('health', 'hospitality', 'education');
  for r in select * from compliance_rules where active order by sort loop
    v_ok := case r.id
      when 'cac_registered' then (k.source = 'cac' and coalesce((k.cac->'profile'->>'active')::boolean, true)) or (k.id is null and o.rc_number is not null)
      when 'tax_id' then o.tin is not null or coalesce(k.tin->>'nrs_tin', k.cac->'profile'->>'tax_id', '') <> ''
      when 'cac_document' then k.doc ? 'path'
      when 'owners_on_record' then k.source = 'cac' and (jsonb_array_length(coalesce(k.cac->'profile'->'directors', '[]'::jsonb)) > 0
        or jsonb_array_length(coalesce(k.cac->'profile'->'shareholders', '[]'::jsonb)) > 0 or jsonb_array_length(coalesce(k.cac->'psc', '[]'::jsonb)) > 0)
      when 'vat_filing' then a->'filing'->>'vat' = 'always' or (v_small and not o.vat_registered)
        or exists (select 1 from vat_periods where org_id = p_org and status = 'filed' and period >= (now() - interval '62 days')::date)
      when 'wht_filing' then a->'filing'->>'wht' in ('always', 'not_applicable')
        or exists (select 1 from wht_remittances where org_id = p_org and created_at > now() - interval '62 days')
      when 'cit_filing' then a->'filing'->>'cit' = 'always' or exists (select 1 from cit_years where org_id = p_org and status = 'filed')
        or (v_personal and exists (select 1 from pit_person_years where org_id = p_org and status = 'filed'))
      when 'business_account' then exists (select 1 from wallets where org_id = p_org and status = 'active')
        or exists (select 1 from jsonb_array_elements_text(coalesce(a->'receive_methods', '[]'::jsonb)) m where m in ('bank_transfer', 'pos', 'payment_links'))
      when 'bank_records' then exists (select 1 from bank_accounts where org_id = p_org and provider = 'mono' and active)
        or exists (select 1 from bank_imports where org_id = p_org)
      when 'books_current' then exists (select 1 from sales where org_id = p_org
        and ((doc_type = 'receipt' and status = 'paid') or (doc_type = 'invoice' and status in ('open', 'partially_paid', 'paid'))))
      else false end;
    v_ok := coalesce(v_ok, false);
    v_label := r.label; v_text := case when v_ok then r.done_text else r.todo_text end; v_action := r.action;
    if r.id = 'cac_registered' and v_inactive then
      v_label := 'Active on the CAC register';
      v_text := 'The business is registered with CAC, but CAC shows it as inactive, usually because annual returns are outstanding. File them on the CAC portal; Counta shows it as active once CAC does.';
    elsif r.id = 'vat_filing' and v_professional and not v_ok then
      v_text := 'A professional services firm charges VAT whatever its size. File a VAT return every month by the 21st, even when it is nil. Counta prepares it from your invoices and bills.';
    elsif r.id = 'cit_filing' and v_personal then
      v_label := 'Income tax returns filed';
      v_text := case when v_ok then 'The personal income tax returns for the business''s profit are filed.'
        else 'A business name pays no companies income tax: its profit is taxed as the owner''s personal income tax (each partner''s share in a partnership), filed with the state by 31 March every year. Counta prepares the returns from your books.' end;
      v_action := 'pit';
    elsif r.id = 'books_current' and v_services then
      -- A clinic, hotel or school keeps the till even when it is a professional firm for tax; other professional firms invoice.
      v_label := case when v_professional and not v_till then 'Invoices issued' else r.label end;
      v_text := case when v_ok then case when v_professional and not v_till then 'Your invoices are issued in Counta.' else r.done_text end
        when v_till then 'Record your sales in Counta, at the till, by invoice or by receipt, so your books and tax returns build themselves.'
        when v_professional then 'Issue your invoices in Counta, so your books and tax returns build themselves.'
        else 'Record your sales in Counta, by invoice or by receipt, so your books and tax returns build themselves.' end;
      v_action := case when v_till then 'first_sale' else 'first_invoice' end;
    end if;
    v_out := v_out || jsonb_build_object('id', r.id, 'label', v_label, 'ok', v_ok, 'text', v_text, 'action', v_action);
  end loop;
  return v_out;
end $$;

-- ---------------------------------------------------------------------------
-- 4. A login e-Tax refused is marked so with the failed check
-- ---------------------------------------------------------------------------
-- The bot says a login did not work in the same report as the job's failure. When only the failure arrives (an earlier
-- report about the login was lost, or an older bot), a check that failed for good before it ever signed in still marks
-- the login, so the person sees "e-Tax did not accept it" and not "checking". A check that failed for another reason
-- (e-Tax down) leaves the login as saved, with the reason shown beside it.
create or replace function private.lirs_fail(j public.lirs_jobs, p_error text, p_retry boolean) returns public.lirs_jobs
language plpgsql security definer set search_path = public, private as $$
declare v_name text; v_again boolean := p_retry and j.attempts < j.max_attempts;
begin
  select name into v_name from pit_people where id = j.person_id;
  update lirs_jobs set status = case when v_again then 'queued' else 'failed' end, error = left(coalesce(p_error, 'Something went wrong on e-Tax.'), 2000),
    not_before = case when v_again then now() + make_interval(mins => 2 * power(2, greatest(j.attempts - 1, 0))::int) else not_before end,
    locked_at = null, updated_at = now(), finished_at = case when v_again then null else now() end
  where id = j.id returning * into j;
  if v_again then return j; end if;
  if j.kind = 'file' then
    update pit_person_years set status = 'approved', flux_status = 'send_failed', flux_message = left(j.error, 1000), flux_updated_at = now()
    where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id and status = 'sent';
    perform private.notify_perm(j.org_id, 'file_tax', 'books', v_name || '''s ' || j.accounting_year || ' return was not filed', j.error,
      '/tax/pit?year=' || j.accounting_year, 'lirs-' || j.id, null);
  elsif j.kind = 'bill' then
    perform private.notify_perm(j.org_id, 'file_tax', 'books', 'Counta could not raise ' || v_name || '''s ' || j.accounting_year || ' bill', j.error,
      '/tax/pit?year=' || j.accounting_year, 'lirs-' || j.id, null);
  elsif j.kind = 'status' then
    -- Checking the bill is tried again later in any case, while there is still reason to expect the payment.
    perform private.lirs_enqueue(j.org_id, j.accounting_year, j.person_id, 'status', j.request, null, interval '15 minutes');
  elsif j.kind = 'check' and not p_retry
    -- Only a check that never signed in: a sign-in that worked was reported as such, whatever failed after it.
    and not exists (select 1 from jsonb_array_elements(coalesce(j.log, '[]'::jsonb)) x where x->>'step' in ('signed_in', 'signed_in_again')) then
    update pit_etax_logins set status = 'failed', message = left(j.error, 1000), checked_at = now(), updated_at = now()
    where org_id = j.org_id and person_id = j.person_id and authority = 'SIRS:LA' and status = 'saved'
      and (j.request->>'login_saved_at' is null or saved_at <= (j.request->>'login_saved_at')::timestamptz);
  end if;
  return j;
end $$;

-- What the login card shows while a check is open. "Checking" means the bot has it now (running, and heard from in the last
-- ten minutes) or is about to (queued and due, for half an hour after it was asked). A check waiting to be tried again
-- after e-Tax did not answer says when; one the bot has not reached says so, rather than spinning for ever.
create or replace function private.pit_etax_login_of(p_org uuid, p_person uuid, p_authority text) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('payer_id', l.payer_id, 'status', l.status, 'message', l.message, 'tax_station', l.tax_station,
    'tax_station_name', l.tax_station_name, 'saved_at', l.saved_at, 'checked_at', l.checked_at,
    'saved_by', (select display_name from members where id = l.saved_by), 'etax_name', l.etax_name,
    'checking', exists (select 1 from lirs_jobs j where j.org_id = l.org_id and j.person_id = l.person_id and j.kind = 'check'
      and ((j.status = 'running' and coalesce(j.locked_at, j.updated_at) > now() - interval '10 minutes')
        or (j.status = 'queued' and j.not_before <= now() and j.created_at > now() - interval '30 minutes'))),
    'check_retry_at', (select min(j.not_before) from lirs_jobs j where j.org_id = l.org_id and j.person_id = l.person_id and j.kind = 'check'
      and j.status = 'queued' and j.not_before > now()),
    'check_waiting', exists (select 1 from lirs_jobs j where j.org_id = l.org_id and j.person_id = l.person_id and j.kind = 'check'
      and ((j.status = 'queued' and j.not_before <= now() and j.created_at <= now() - interval '30 minutes')
        or (j.status = 'running' and coalesce(j.locked_at, j.updated_at) <= now() - interval '10 minutes'))),
    'check_error', case when l.status = 'saved' then (select j.error from lirs_jobs j where j.org_id = l.org_id and j.person_id = l.person_id and j.kind = 'check'
      and j.error is not null and ((j.status = 'failed' and j.finished_at >= l.saved_at) or j.status = 'queued')
      order by coalesce(j.finished_at, j.updated_at) desc limit 1) end)
  from pit_etax_logins l where l.org_id = p_org and l.person_id = p_person and l.authority = coalesce(p_authority, 'SIRS:LA')
$$;

-- ---------------------------------------------------------------------------
-- 5. A supplier's invoice is taken at once and read afterwards
-- ---------------------------------------------------------------------------
-- The upload answers as soon as the file is saved; Counta reads it afterwards and tells the supplier what to fix: by email
-- when they gave an address, else on the WhatsApp number they gave (private.si_contact, unchanged).

-- An invoice sent on the portal that Counta could not read: the supplier hears that the business will enter it by hand,
-- and that a clearer copy on the same link is quicker. Nothing is sent for the sample business or with notices off.
create or replace function private.si_tell_unread(p_id uuid) returns text
language plpgsql security definer set search_path = public, private as $$
declare si public.supplier_invoices; o public.orgs; v public.vendors; v_to text; v_ch text; msg public.messages;
begin
  select * into si from supplier_invoices where id = p_id for update;
  if not found or si.source <> 'portal' then return null; end if;
  if si.notice_status = 'sent' then return 'sent'; end if;
  select * into o from orgs where id = si.org_id;
  select * into v from vendors where id = si.vendor_id;
  if not o.invoice_notices or o.is_sample then update supplier_invoices set notice_status = 'off' where id = si.id; return 'off'; end if;
  select r.channel, r.address into v_ch, v_to from private.si_contact(si.submitter, v) r;
  if v_to is null then update supplier_invoices set notice_status = 'no_contact' where id = si.id; return 'no_contact'; end if;
  begin
    msg := private.queue_message(si.org_id, v_ch, v_to, 'invoice_issues', 'Your invoice ' || si.number || ' to ' || o.name || ' could not be read',
      jsonb_build_object('customer_name', coalesce(nullif(trim(si.submitter->>'name'), ''), v.name), 'business', o.name, 'number', si.number,
        'issues', jsonb_build_array('Counta could not read the file automatically, so ' || o.name || ' will enter it by hand. A clearer PDF or photo of the whole invoice, sent on the same link, is quicker.'),
        'reference', si.number), null, null, si.submitted_by);
  exception when others then
    update supplier_invoices set notice_status = 'skipped' where id = si.id;
    return 'skipped';
  end;
  update messages set vendor_id = v.id, supplier_invoice_id = si.id where id = msg.id;
  update supplier_invoices set notice_status = 'sent', notice_message_id = msg.id, notice_at = now() where id = si.id;
  return 'sent';
end $$;

-- What Counta read, or why it could not: tell_supplier asks for the supplier to be told when the reading failed.
create or replace function public.svc_si_read(p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare si public.supplier_invoices; r jsonb;
begin
  select * into si from supplier_invoices where id = p_id;
  if not found then raise exception 'Invoice not found.'; end if;
  if p ? 'path' then update supplier_invoices set document_path = p->>'path', file_size = coalesce(nullif(p->>'file_size', '')::int, file_size),
    file_sha256 = coalesce(nullif(p->>'sha256', ''), file_sha256), mime = coalesce(private.si_text(p->>'mime', 60), mime) where id = si.id; end if;
  if p ? 'error' then
    -- Once only: a reading that ended (read, or failed already) is not failed again by a late report.
    if si.status <> 'reading' then return private.si_json(si.id); end if;
    update supplier_invoices set status = 'failed', error = left(p->>'error', 500), read_at = now() where id = si.id;
    perform private.notify_perm(si.org_id, 'keep_books', 'bill', 'An invoice could not be read: ' || si.number, left(p->>'error', 200), '/purchases/bills?tab=invoices&open=' || si.id);
    if coalesce((p->>'tell_supplier')::boolean, false) then perform private.si_tell_unread(si.id); end if;
    return private.si_json(si.id);
  end if;
  r := private.si_apply(si.id, p->'extract', p->>'model', p->>'bank_resolved_name');
  return r || jsonb_build_object('tin_check', (select case when v.id is not null and coalesce(v.resident, true) and private.clean_tax_id(v.tin) is not null and v.tin_status is null
      then v.id end from supplier_invoices x join vendors v on v.id = x.vendor_id where x.id = si.id));
end $$;

-- An invoice still being read ten minutes on was lost on the way (the reading stopped before it finished): it fails, the
-- business is told, and so is a supplier who sent it on the portal.
create or replace function private.si_stale() returns int
language plpgsql security definer set search_path = public, private as $$
declare v_id uuid; n int := 0;
begin
  for v_id in select id from supplier_invoices where status = 'reading' and created_at < now() - interval '10 minutes' order by created_at limit 50 loop
    perform public.svc_si_read(v_id, jsonb_build_object('error', 'Counta could not finish reading it. Enter the bill by hand from the invoice, or upload it again.', 'tell_supplier', true));
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function private.si_stale(), private.si_tell_unread(uuid) from public;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'counta-si-stale';
    perform cron.schedule('counta-si-stale', '*/10 * * * *',
      $c$select private.si_stale() where exists (select 1 from public.supplier_invoices where status = 'reading' and created_at < now() - interval '10 minutes')$c$);
  end if;
end $$;
