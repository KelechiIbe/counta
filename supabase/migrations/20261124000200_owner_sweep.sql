-- Practice management, part 2: the owner sweep.
--
-- Every function whose latest definition compared a role to 'owner' inline now asks the owner resolver (part 1) instead:
--   the caller's own authority             -> private.perm_of(m, 'owner'), or (m.role in (...) or m.acts_as_owner) for a role list;
--   a service function's member or user    -> private.acts_as_owner(p_org, p_user), or perm_of on the member row it fetched;
--   who receives something or acts for     -> private.org_contact(p_org).
-- For an ordinary business these give exactly what the role comparison gave (acts_as_owner is false, and org_contact is the
-- active owner), so nothing changes there; under full mandate the firm's acting owners pass and the engagement partner is
-- the contact. Three lookups that took the owner's place in any status (a Prism merchant's owner may still be an invitation)
-- keep that and add the contact's place: einvoice_issue_held, prism_owner, svc_subscription_charge.
-- Comparisons about another member's role, a role parameter, listing order, admin-portal display or the real owner's
-- identity stay; supabase/tests/golden/sweep_manifest.tsv classifies every one, and `golden/run.sh sweep` checks it.
--
-- Each function below is its latest definition (pg_get_functiondef on the local harness) with only the owner comparison
-- changed. Signatures are unchanged, so create or replace keeps every grant; the private functions are then revoked from
-- the signed-in roles (core.sql grants every private function to authenticated), except the storage-policy helper
-- private.document_may_delete, which the documents bucket's policy calls as the signed-in person.

-- private.alert_send: the alert email's recipient -> org_contact
CREATE OR REPLACE FUNCTION private.alert_send(p_org uuid, p_kind text, p_key text, p_channels text[], p jsonb)
 RETURNS text[]
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare o public.orgs; ow public.members; m public.members; v_prefs jsonb := private.alert_prefs(p_org); v_sent text[] := '{}'; v_link text; v_wa int := 0;
begin
  select * into o from orgs where id = p_org;
  ow := private.org_contact(p_org);
  v_link := coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app') || coalesce(p->>'url', '/home');
  if 'push' = any(p_channels) and private.alert_once(p_org, p_kind, p_key, 'push') then
    perform private.notify_perm(p_org, coalesce(p->>'perm', 'keep_books'), p_kind, p->>'title', p->>'body', p->>'url', p_kind || ':' || p_key);
    v_sent := v_sent || 'push'::text;
  end if;
  if 'email' = any(p_channels) and not o.is_sample and ow.id is not null and (v_prefs->>'email')::boolean and private.feature_on(p_org, 'email')
     and nullif(trim(coalesce(ow.email, '')), '') is not null and private.alert_once(p_org, p_kind, p_key, 'email') then
    begin
      perform private.queue_message(p_org, 'email', ow.email, 'alert', coalesce(p->>'subject', p->>'title'),
        jsonb_build_object('kind', p_kind, 'person_name', ow.display_name, 'business', o.name, 'heading', p->>'title', 'lines', coalesce(p->'lines', jsonb_build_array(p->>'body')),
          'button', coalesce(p->>'button', 'Open Counta'), 'link', v_link, 'automatic', true), null, null, ow.id);
      v_sent := v_sent || 'email'::text;
    exception when others then null;
    end;
  end if;
  if 'whatsapp' = any(p_channels) and (v_prefs->>'whatsapp')::boolean and private.feature_on(p_org, 'whatsapp') and not private.quiet(p_org) then
    for m in select * from members where org_id = p_org and status = 'active' and user_id is not null order by role = 'owner' desc, created_at loop
      continue when not private.perm_of(m, coalesce(p->>'perm', 'keep_books'));
      begin
        if private.wa_alert(p_org, m.user_id, p_kind, p_key, p) then v_wa := v_wa + 1; end if;
      exception when others then null;
      end;
    end loop;
    if v_wa > 0 then v_sent := v_sent || 'whatsapp'::text; end if;
  end if;
  return v_sent;
end $function$;

-- private.alerts_tick: businesses with someone to alert -> org_contact; the person alerted and called -> org_contact
CREATE OR REPLACE FUNCTION private.alerts_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare cfg jsonb := private.setting('alerts'); o record; d record; v_today date; v_left int; v_ch text[]; v_n int; v_amt numeric; v_oldest text; v_prefs jsonb;
  ow public.members; v_out jsonb := '{}'::jsonb; v_cnt int := 0; s record; v_calls int; v_per_day int; v_mth date; v_due21 date; v_key text; v_days int[];
begin
  for o in select x.* from orgs x where (private.org_contact(x.id)).id is not null loop
    v_today := private.local_day(o.id, now());
    v_prefs := private.alert_prefs(o.id);
    ow := private.org_contact(o.id);
    -- ---- tax deadlines
    v_days := array(select (jsonb_array_elements_text(cfg->'tax_deadline'->'days_before'))::int);
    for d in select * from private.tax_deadlines(o.id) loop
      v_left := d.due - v_today;
      v_key := d.tax || ':' || d.period || ':' || v_left;
      v_ch := '{}';
      if (cfg->'tax_deadline'->>'push')::boolean and (v_left = any(v_days) or v_left = 0 or (v_left < 0 and v_left % 3 = 0)) then v_ch := v_ch || 'push'::text; end if;
      if (v_left = any(array(select (jsonb_array_elements_text(cfg->'tax_deadline'->'message_days_before'))::int)) or v_left = 0 or (v_left < 0 and v_left % 7 = 0)) then
        if (cfg->'tax_deadline'->>'email')::boolean then v_ch := v_ch || 'email'::text; end if;
        if (cfg->'tax_deadline'->>'whatsapp')::boolean then v_ch := v_ch || 'whatsapp'::text; end if;
      end if;
      if cardinality(v_ch) > 0 then
        perform private.alert_send(o.id, 'tax_deadline', v_key, v_ch, jsonb_build_object('perm', 'file_tax',
          'title', d.label || ' for ' || to_char(d.period, 'FMMonth YYYY') || case when v_left > 1 then ' is due in ' || v_left || ' days'
            when v_left = 1 then ' is due tomorrow' when v_left = 0 then ' is due today' else ' is ' || -v_left || ' days late' end,
          'body', 'Due on ' || to_char(d.due, 'FMDD Mon YYYY') || coalesce(' · ' || private.naira(d.amount), '') || '. Open Counta to finish it.',
          'url', d.url, 'button', 'Open the return',
          'lines', jsonb_build_array(o.name || '''s ' || private.label_mid(d.label) || ' for ' || to_char(d.period, 'FMMonth YYYY') || ' is due on ' || to_char(d.due, 'FMDD Mon YYYY') || '.',
            case when d.amount is not null then private.naira(d.amount) || ' is due.' else 'Counta has prepared it from the books; check it and file.' end,
            case when v_left < 0 then 'It is late: penalties and interest grow each month it stays unfiled.' end),
          'wa_name', 'counta_tax_deadline', 'wa_params', jsonb_build_array(split_part(ow.display_name, ' ', 1), o.name, private.label_mid(d.label),
            to_char(d.period, 'FMMonth YYYY'), to_char(d.due, 'FMDD Mon YYYY'), coalesce(private.naira(d.amount), 'prepared in Counta'))));
        v_cnt := v_cnt + 1;
      end if;
      -- Martina calls the owner the day before.
      if v_left = coalesce((cfg->'tax_deadline'->>'call_days_before')::int, 1) and (cfg->'tax_deadline'->>'call')::boolean and (v_prefs->>'owner_calls')::boolean
         and not o.is_sample and private.feature_on(o.id, 'phone_calls') and private.e164(ow.phone) is not null
         and private.alert_once(o.id, 'tax_deadline', d.tax || ':' || d.period, 'call') then
        insert into voice_calls (org_id, kind, member_id, topic, to_number, variables, created_by, call_after)
        values (o.id, 'tax_deadline', ow.id, d.tax, private.e164(ow.phone), jsonb_build_object('business_name', o.name, 'person_name', ow.display_name,
            'person_first_name', split_part(ow.display_name, ' ', 1), 'tax_name', d.label, 'period', to_char(d.period, 'FMMonth YYYY'),
            'due_date', to_char(d.due, 'FMDay DD FMMonth'), 'amount', coalesce(private.naira(d.amount), 'the amount Counta worked out'),
            'what_to_do', case d.tax when 'vat' then 'Open Counta, go to Tax returns and VAT, check the month and file it, then pay what is due.'
              when 'cit' then 'Open Counta, go to Tax returns and Companies income tax, check the computation and approve it for filing.'
              else 'Open Counta, go to Tax returns and Withholding tax, and pay what was deducted with the schedule.' end),
          ow.id, greatest(now(), private.local_hour_at(o.id, v_today, coalesce((cfg->'calls'->'hours'->>0)::int, 9))));
      end if;
    end loop;
    -- ---- invoices due and overdue
    select count(*), coalesce(sum(s2.total - s2.amount_paid - s2.credited), 0), min(s2.number) filter (where s2.due_date = (select min(due_date) from sales s3 where s3.org_id = o.id
             and s3.doc_type = 'invoice' and s3.status in ('open', 'partially_paid') and s3.due_date <= v_today + coalesce((cfg->'invoices'->>'due_soon_days')::int, 3)))
      into v_n, v_amt, v_oldest
    from sales s2 where s2.org_id = o.id and s2.doc_type = 'invoice' and s2.status in ('open', 'partially_paid') and s2.journal_id is not null
      and s2.due_date <= v_today + coalesce((cfg->'invoices'->>'due_soon_days')::int, 3);
    if v_n > 0 then
      v_ch := case when (cfg->'invoices'->>'push')::boolean then array['push'] else '{}' end;
      -- The week's digest, and the day an invoice first goes overdue.
      if extract(isodow from v_today)::int = coalesce((cfg->'invoices'->>'digest_weekday')::int, 1)
         or exists (select 1 from sales s4 where s4.org_id = o.id and s4.doc_type = 'invoice' and s4.status in ('open', 'partially_paid') and s4.due_date = v_today - 1) then
        if (cfg->'invoices'->>'email')::boolean then v_ch := v_ch || 'email'::text; end if;
        if (cfg->'invoices'->>'whatsapp')::boolean then v_ch := v_ch || 'whatsapp'::text; end if;
      end if;
      perform private.alert_send(o.id, 'invoices', v_today::text, v_ch, jsonb_build_object('perm', 'record_sales',
        'title', v_n || ' invoice' || case when v_n = 1 then ' is' else 's are' end || ' due or overdue',
        'body', private.naira(v_amt) || ' in all' || coalesce(' · the oldest is ' || v_oldest, ''),
        'url', '/sell/sales?status=overdue', 'button', 'See the invoices',
        'lines', jsonb_build_array(o.name || ' has ' || v_n || ' invoice' || case when v_n = 1 then '' else 's' end || ' due in the next few days or overdue, ' || private.naira(v_amt) || ' in all.',
          'Counta reminds the customers on the days set in Settings; you can send a reminder or a statement from each invoice.'),
        'wa_name', 'counta_invoices_due', 'wa_params', jsonb_build_array(split_part(ow.display_name, ' ', 1), o.name, v_n::text, private.naira(v_amt),
          coalesce(v_oldest, '-'))));
    end if;
    -- ---- transactions to confirm before the month's VAT and WHT returns (from the 10th to the 20th)
    v_mth := (date_trunc('month', v_today) - interval '1 month')::date;
    v_due21 := (date_trunc('month', v_today))::date + 20;
    if extract(day from v_today) between coalesce((cfg->'confirm'->>'push_from_day')::int, 10) and 20 then
      select count(*) into v_n from bank_lines bl where bl.org_id = o.id and bl.status in ('unmatched', 'proposed') and bl.line_date between v_mth and (v_mth + interval '1 month' - interval '1 day')::date;
      v_n := v_n + (select count(*) from receipts r where r.org_id = o.id and r.status = 'needs_review' and r.created_at::date between v_mth and v_due21)
                 + (select count(*) from sales_schedules sc where sc.org_id = o.id and sc.status = 'draft');
      if v_n > 0 then
        v_ch := array['push'];
        if extract(day from v_today)::int = any(array(select (jsonb_array_elements_text(cfg->'confirm'->'message_days'))::int)) then
          if (cfg->'confirm'->>'email')::boolean then v_ch := v_ch || 'email'::text; end if;
          if (cfg->'confirm'->>'whatsapp')::boolean then v_ch := v_ch || 'whatsapp'::text; end if;
        end if;
        perform private.alert_send(o.id, 'confirm', v_today::text, v_ch, jsonb_build_object('perm', 'keep_books',
          'title', v_n || ' transaction' || case when v_n = 1 then '' else 's' end || ' to confirm before the returns',
          'body', 'From ' || to_char(v_mth, 'FMMonth') || '. The VAT and WHT returns are due on ' || to_char(v_due21, 'FMDD Mon') || '.',
          'url', '/accounting/inbox', 'button', 'Confirm them',
          'lines', jsonb_build_array(v_n || ' transaction' || case when v_n = 1 then '' else 's' end || ' from ' || to_char(v_mth, 'FMMonth YYYY') || ' still need your answer before they go into the returns.',
            'The VAT and WHT returns for ' || to_char(v_mth, 'FMMonth') || ' are due on ' || to_char(v_due21, 'FMDD Mon YYYY') || '.'),
          'wa_name', 'counta_confirm_items', 'wa_params', jsonb_build_array(split_part(ow.display_name, ' ', 1), o.name, v_n::text, to_char(v_mth, 'FMMonth YYYY'),
            to_char(v_due21, 'FMDD Mon'))));
      end if;
    end if;
    -- ---- Martina follows up customers' overdue invoices, when the business asked for it
    if (v_prefs->>'customer_calls')::boolean and (cfg->'customer_calls'->>'enabled')::boolean and not o.is_sample and private.feature_on(o.id, 'phone_calls') then
      v_per_day := coalesce((cfg->'customer_calls'->>'per_org_per_day')::int, 5);
      select count(*) into v_calls from voice_calls where org_id = o.id and kind = 'customer_followup' and created_at > now() - interval '20 hours';
      for s in select sa.*, cu.phone cphone, cu.name cname from sales sa join customers cu on cu.id = sa.customer_id
               where sa.org_id = o.id and sa.doc_type = 'invoice' and sa.status in ('open', 'partially_paid') and sa.journal_id is not null and not cu.is_walk_in
                 and sa.due_date <= v_today - coalesce((cfg->'customer_calls'->>'min_days_overdue')::int, 7)
                 and sa.total - sa.amount_paid - sa.credited >= coalesce((cfg->'customer_calls'->>'min_amount')::numeric, 10000)
                 and private.e164(cu.phone) is not null
                 -- a reminder went at least two days ago and was not answered with payment
                 and sa.reminded_at is not null and sa.reminded_at < now() - interval '2 days'
                 and not exists (select 1 from voice_calls vc where vc.sale_id = sa.id
                                 and vc.created_at > now() - make_interval(days => coalesce((cfg->'customer_calls'->>'repeat_days')::int, 7)))
               order by sa.total - sa.amount_paid - sa.credited desc limit 20 loop
        exit when v_calls >= v_per_day;
        insert into voice_calls (org_id, kind, sale_id, customer_id, topic, to_number, variables, created_by, call_after)
        values (o.id, 'customer_followup', s.id, s.customer_id, 'overdue_invoice', private.e164(s.cphone), jsonb_build_object('business_name', o.name,
            'customer_name', s.cname, 'customer_first_name', split_part(s.cname, ' ', 1), 'invoice_number', s.number,
            'amount_due', private.naira(s.total - s.amount_paid - s.credited), 'due_date', to_char(s.due_date, 'FMDD FMMonth YYYY'),
            'days_overdue', (v_today - s.due_date)::text, 'contact_name', ow.display_name, 'contact_phone', coalesce(o.phone, ow.phone, ''),
            'pay_link', private.doc_link(s.public_token)),
          ow.id, greatest(now(), private.local_hour_at(o.id, v_today, coalesce((cfg->'calls'->'hours'->>0)::int, 9))));
        v_calls := v_calls + 1;
      end loop;
    end if;
  end loop;
  delete from alert_log where sent_at < now() - interval '120 days';
  return jsonb_build_object('alerts', v_cnt);
end $function$;

-- private.bulk_check: needs_approval: the caller is not the owner -> perm_of
CREATE OR REPLACE FUNCTION private.bulk_check(p_org uuid, p jsonb, m members)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare o public.orgs; w public.wallets; v_default text := nullif(trim(p->>'default_account'), ''); x jsonb; res jsonb; v_rows jsonb := '[]'::jsonb;
  v_bills uuid[] := '{}'; v_total numeric := 0; v_wht numeric := 0; v_fees numeric := 0; v_ok int := 0; v_bad int := 0; v_avail numeric; v_n int;
begin
  select * into o from orgs where id = p_org;
  select * into w from wallets where org_id = p_org and rail = o.payment_rail and status = 'active';
  if not found then raise exception 'Open the business wallet in Payments first.'; end if;
  if v_default is not null and not private.bulk_account_ok(p_org, v_default) then
    raise exception 'Account % cannot take a payment. Choose an expense or liability account.', v_default;
  end if;
  v_n := jsonb_array_length(coalesce(p->'rows', '[]'::jsonb));
  if v_n = 0 then raise exception 'The file has no payments.'; end if;
  if v_n > 500 then raise exception 'Send at most 500 payments in one bulk payment.'; end if;
  for x in select value from jsonb_array_elements(p->'rows') loop
    res := private.bulk_row(p_org, x, v_default);
    if (res->>'bill_id') is not null then
      if (res->>'bill_id')::uuid = any(v_bills) then
        res := res || jsonb_build_object('ok', false, 'errors', (res->'errors') || to_jsonb(format('%s appears more than once in this file. Pay it on one row.', res->>'bill_number')));
      end if;
      v_bills := v_bills || (res->>'bill_id')::uuid;
    end if;
    if (res->>'ok')::boolean then
      v_ok := v_ok + 1; v_total := v_total + (res->>'amount')::numeric; v_wht := v_wht + coalesce((res->>'wht')::numeric, 0); v_fees := v_fees + (res->>'fee')::numeric;
    else
      v_bad := v_bad + 1;
    end if;
    v_rows := v_rows || jsonb_build_array(res);
  end loop;
  v_avail := private.wallet_balance(w.id) - coalesce((select sum(amount + fee) from payouts where wallet_id = w.id and status in ('approved', 'processing', 'pending_approval')), 0);
  return jsonb_build_object('rows', v_rows, 'ok_count', v_ok, 'error_count', v_bad, 'total', v_total, 'wht_total', v_wht, 'fee_estimate', v_fees,
    'available', v_avail, 'short', greatest(v_total + v_fees - v_avail, 0),
    'needs_approval', o.payout_approval_threshold > 0 and v_total >= o.payout_approval_threshold and not private.perm_of(m, 'owner'),
    'mode', case when exists (select 1 from payment_rails where code = w.rail and 'bulk_payout' = any(capabilities)) then 'bulk' else 'transfers' end,
    'wallet_id', w.id,
    'wht_types', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'exempt', exemption) order by sort, code), '[]'::jsonb) from wht_rates
      where code not in ('compensation', 'dividend', 'interest', 'winnings', 'entertainment', 'ex_securities_lending', 'ex_reit', 'ex_exempt_income',
        'ex_imported_goods', 'ex_broker_retained', 'ex_qualifying_winnings')));
end $function$;

-- private.chat_context: the chat user's own permissions -> perm_of
CREATE OR REPLACE FUNCTION private.chat_context(l chat_links)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select jsonb_build_object('link_id', l.id, 'channel', l.channel, 'org_id', l.org_id, 'user_id', l.user_id,
    'first_name', split_part(coalesce(nullif(trim(mb.display_name), ''), 'there'), ' ', 1), 'role', private.role_label(mb.role),
    'member_status', mb.status, 'business', o.name, 'offering', o.offering, 'category_id', o.category_id,
    'category', (select label from business_categories where id = o.category_id),
    'language', o.voice_lang, 'sample', o.is_sample,
    'perms', case when private.perm_of(mb, 'owner') then private.role_template('owner') else private.member_perms(mb) end,
    'businesses', (select coalesce(jsonb_agg(jsonb_build_object('id', x.org_id, 'name', xo.name) order by xo.name), '[]'::jsonb)
      from members x join orgs xo on xo.id = x.org_id where x.user_id = l.user_id and x.status = 'active'),
    'app_url', coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app'))
  from orgs o left join members mb on mb.org_id = o.id and mb.user_id = l.user_id
  where o.id = l.org_id
$function$;

-- private.check_grantable: the granting caller -> perm_of
CREATE OR REPLACE FUNCTION private.check_grantable(m members, p jsonb)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare k text;
begin
  if private.perm_of(m, 'owner') then return; end if;
  foreach k in array private.perm_keys() loop
    if coalesce((p->>k)::boolean, false) and not private.perm_of(m, k) then
      raise exception 'You cannot give a permission you do not have yourself (%).', replace(k, '_', ' ') using errcode = '42501';
    end if;
  end loop;
end $function$;

-- private.create_payout: the requesting caller's payout needs approval -> perm_of
CREATE OR REPLACE FUNCTION private.create_payout(p_org uuid, p jsonb, p_lines jsonb, m members)
 RETURNS payouts
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare o public.orgs; w public.wallets; po public.payouts; v_amt numeric := round(private.num(p->>'amount'), 2); v_status text; v_inflight numeric;
  v_batch uuid := nullif(current_setting('counta.payout_batch', true), '')::uuid; v_row jsonb := nullif(current_setting('counta.payout_row', true), '')::jsonb;
  pb public.payout_batches;
begin
  if nullif(p->>'client_uuid', '') is not null then
    select * into po from payouts where client_uuid = (p->>'client_uuid')::uuid;
    if found then return po; end if;
  end if;
  select * into o from orgs where id = p_org;
  perform private.require_payments_open(p_org);
  select * into w from wallets where org_id = p_org and rail = o.payment_rail and status = 'active';
  if not found then raise exception 'Open the business wallet in Payments first.'; end if;
  if not exists (select 1 from payment_rails where code = w.rail and 'payout' = any(capabilities)) then raise exception 'This payment rail does not make payouts.'; end if;
  if coalesce(v_amt, 0) < 100 then raise exception 'A payout must be at least ₦100.'; end if;
  if coalesce(p->>'account_number', '') !~ '^[0-9]{10}$' then raise exception 'Enter the 10-digit account number.'; end if;
  if coalesce(trim(p->>'bank_code'), '') = '' then raise exception 'Choose the bank.'; end if;
  if coalesce(trim(p->>'account_name'), '') = '' then raise exception 'Check the account name before paying.'; end if;
  select coalesce(sum(amount + fee), 0) into v_inflight from payouts where wallet_id = w.id and status in ('approved', 'processing', 'pending_approval');
  if v_amt > private.wallet_balance(w.id) - v_inflight + 0.004 then
    raise exception 'The wallet holds % after payouts already waiting. Fund it first.', to_char(private.wallet_balance(w.id) - v_inflight, 'FM999,999,999,990.00');
  end if;
  if v_batch is not null then
    select * into pb from payout_batches where id = v_batch and org_id = p_org;
    if not found then raise exception 'Bulk payment not found.'; end if;
    v_status := pb.status;
  else
    v_status := case when o.payout_approval_threshold > 0 and v_amt >= o.payout_approval_threshold and not private.perm_of(m, 'owner') then 'pending_approval' else 'approved' end;
  end if;
  insert into payouts (org_id, number, wallet_id, purpose, vendor_id, customer_id, to_bank_account_id, amount, bank_code, bank_name, account_number, account_name,
    narration, lines, reference, status, requested_by, approved_by, approved_at, client_uuid, batch_id, batch_row, your_reference)
  values (p_org, 'PO-' || lpad(private.next_no(p_org, 'PO', 1)::text, 5, '0'), w.id, coalesce(nullif(p->>'purpose', ''), 'other'),
    nullif(p->>'vendor_id', '')::uuid, nullif(p->>'customer_id', '')::uuid, nullif(p->>'to_bank_account_id', '')::uuid, v_amt, trim(p->>'bank_code'),
    nullif(trim(p->>'bank_name'), ''), p->>'account_number', left(trim(p->>'account_name'), 120), left(coalesce(nullif(trim(p->>'narration'), ''), o.name), 80),
    p_lines, 'CNTP-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)), v_status, m.id,
    case when v_status = 'approved' then m.id end, case when v_status = 'approved' then now() end, nullif(p->>'client_uuid', '')::uuid,
    pb.id, case when pb.id is not null then (v_row->>'row')::int end, case when pb.id is not null then nullif(left(trim(v_row->>'ref'), 60), '') end)
  returning * into po;
  if v_status = 'pending_approval' and pb.id is null then
    perform private.notify_perm(p_org, 'approve_payments', 'payout', 'Approve a payout of ₦' || to_char(v_amt, 'FM999,999,999,990.00'),
      po.account_name || ' · ' || po.narration || ' · asked by ' || coalesce(m.display_name, ''), '/payments', 'payout-' || po.id, m.id);
  end if;
  return po;
end $function$;

-- private.doc_can: the caller sees company documents -> perm_of
CREATE OR REPLACE FUNCTION private.doc_can(m members)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select jsonb_build_object(
    'sales', private.perm_of(m, 'record_sales') or private.perm_of(m, 'keep_books'),
    'purchases', private.perm_of(m, 'keep_books') or private.perm_of(m, 'make_payments') or private.perm_of(m, 'receive_stock'),
    'tax', (private.perm_of(m, 'keep_books') or private.perm_of(m, 'make_payments') or private.perm_of(m, 'see_margins'))
      and (private.perm_of(m, 'file_tax') or private.perm_of(m, 'keep_books')),
    'bank', private.perm_of(m, 'keep_books'),
    'accountant', private.perm_of(m, 'keep_books'),
    'company', private.perm_of(m, 'owner') or private.perm_of(m, 'manage_settings'),
    'other', true)
$function$;

-- private.doc_rows: the caller sees the CAC records (acting owners count as owner for KYC, as is_owner) -> perm_of
CREATE OR REPLACE FUNCTION private.doc_rows(p_org uuid, m members, p_from date, p_to date, p_undated boolean DEFAULT true)
 RETURNS TABLE(id text, cat text, folder text, sub text, period date, year integer, day date, name text, kind text, path text, mime text, size bigint, ref text, party text, amount numeric, at timestamp with time zone, source text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
#variable_conflict use_column
declare c jsonb := private.doc_can(m); v_pre text := p_org::text || '/';
begin
  if c->>'sales' = 'true' then
    -- Invoices, receipts for named customers, credit notes, quotes and orders.
    return query
      select 'sale:' || s.id, 'sales', case s.doc_type when 'invoice' then 'Invoices' when 'receipt' then 'Receipts' when 'credit_note' then 'Credit notes'
          when 'quote' then 'Quotes' else 'Orders' end, null::text, date_trunc('month', s.issue_date)::date, extract(year from s.issue_date)::int, s.issue_date,
        s.number || coalesce(' · ' || nullif(s.customer_name, ''), '') || case when s.status = 'void' then ' (void)' else '' end,
        'sale', null::text, 'application/pdf', null::bigint, s.id::text, s.customer_name, s.total, s.created_at, 'counta'
      from sales s left join customers cu on cu.id = s.customer_id
      where s.org_id = p_org and s.issue_date between p_from and p_to and s.status not in ('draft', 'converted')
        and s.doc_type in ('invoice', 'receipt', 'credit_note', 'quote', 'order')
        and not (s.doc_type = 'receipt' and (s.customer_id is null or coalesce(cu.is_walk_in, false)));
    -- Walk-in till receipts: one PDF a day.
    return query
      select 'till:' || s.issue_date::text, 'sales', 'Till receipts', null::text, date_trunc('month', s.issue_date)::date, extract(year from s.issue_date)::int,
        s.issue_date, 'Till receipts, ' || to_char(s.issue_date, 'FMDD Mon YYYY') || ' (' || count(*) || ' ' || case when count(*) = 1 then 'sale' else 'sales' end || ')',
        'till', null::text, 'application/pdf', null::bigint, s.issue_date::text, null::text, sum(s.total), max(s.created_at), 'counta'
      from sales s left join customers cu on cu.id = s.customer_id
      where s.org_id = p_org and s.issue_date between p_from and p_to and s.doc_type = 'receipt' and s.status not in ('draft', 'void', 'converted')
        and (s.customer_id is null or coalesce(cu.is_walk_in, false))
      group by s.issue_date;
    return query
      select 'delivery:' || d.id, 'sales', 'Delivery proofs', null::text, date_trunc('month', d.delivered_at)::date, extract(year from d.delivered_at)::int,
        d.delivered_at::date, d.number || coalesce(' · ' || nullif(d.received_by, ''), ''), 'file', d.proof_path, null::text, null::bigint, d.id::text,
        d.received_by, null::numeric, d.delivered_at, 'counta'
      from deliveries d where d.org_id = p_org and d.proof_path like v_pre || '%' and d.delivered_at::date between p_from and p_to;
  end if;

  if c->>'purchases' = 'true' then
    return query
      select 'bill:' || b.id, 'purchases', case when b.source = 'portal' or exists (select 1 from supplier_invoices si where si.bill_id = b.id) then 'From suppliers'
          else 'Supplier invoices' end,
        null::text, date_trunc('month', b.bill_date)::date, extract(year from b.bill_date)::int, b.bill_date,
        coalesce(nullif(b.vendor_ref, ''), b.number) || coalesce(' · ' || v.name, '') || case when b.status = 'void' then ' (void)' else '' end,
        'file', b.document_path, null::text, null::bigint, b.id::text, v.name, b.total, b.created_at, 'counta'
      from bills b left join vendors v on v.id = b.vendor_id
      where b.org_id = p_org and b.document_path like v_pre || '%' and b.bill_date between p_from and p_to;
    -- Invoices suppliers sent through the portal that are not bills (yet, or at all).
    return query
      select 'si:' || si.id, 'purchases', 'From suppliers', null::text, date_trunc('month', si.created_at)::date, extract(year from si.created_at)::int,
        si.created_at::date, coalesce(nullif(si.file_name, ''), si.number) || ' (' || replace(si.status, '_', ' ') || ')', 'file', si.document_path, si.mime,
        si.file_size::bigint, si.id::text, coalesce(si.submitter->>'name', si.submitter->>'business'), null::numeric, si.created_at, 'counta'
      from supplier_invoices si
      where si.org_id = p_org and si.bill_id is null and si.document_path like v_pre || '%' and si.created_at::date between p_from and p_to
        and not exists (select 1 from bills b where b.org_id = p_org and b.document_path = si.document_path);
    return query
      select 'receipt:' || r.id, 'purchases', 'Stock received', null::text, date_trunc('month', coalesce(r.invoice_date, r.created_at::date))::date,
        extract(year from coalesce(r.invoice_date, r.created_at::date))::int, coalesce(r.invoice_date, r.created_at::date),
        coalesce(nullif(r.invoice_no, ''), r.ref) || coalesce(' · ' || nullif(r.vendor_name, ''), ''), 'file', r.document_path, r.document_mime, null::bigint,
        r.id::text, r.vendor_name, r.gross, r.created_at, 'counta'
      from receipts r
      where r.org_id = p_org and r.document_path like v_pre || '%' and coalesce(r.invoice_date, r.created_at::date) between p_from and p_to
        and not exists (select 1 from bills b where b.org_id = p_org and b.document_path = r.document_path);
    -- Every bill whose input VAT is claimed, in the month it is claimed (the month it was paid in full): its own file, or the
    -- bill drawn as a PDF when it was typed in by hand.
    return query
      select 'vat:' || b.id, 'purchases', 'Input VAT invoices', null::text, date_trunc('month', vd.d)::date, extract(year from vd.d)::int, vd.d,
        coalesce(nullif(b.vendor_ref, ''), b.number) || coalesce(' · ' || v.name, ''),
        case when b.document_path like v_pre || '%' then 'file' else 'bill' end,
        case when b.document_path like v_pre || '%' then b.document_path end, case when b.document_path like v_pre || '%' then null::text else 'application/pdf' end,
        null::bigint, b.id::text, v.name, b.total, b.created_at, 'counta'
      from bills b left join vendors v on v.id = b.vendor_id cross join lateral (select private.bill_vat_day(b.id) d) vd
      where b.org_id = p_org and b.journal_id is not null and b.status = 'paid' and b.vat_total > 0 and b.source <> 'import'
        and b.bill_date <= p_to and (b.bill_date >= p_from or b.paid_in_full_on >= p_from) and vd.d between p_from and p_to;
    return query
      select 'vcredit:' || vc.id, 'purchases', 'Supplier credit notes', null::text, date_trunc('month', vc.credit_date)::date, extract(year from vc.credit_date)::int,
        vc.credit_date, coalesce(nullif(vc.vendor_ref, ''), vc.number) || coalesce(' · ' || v.name, ''), 'file', vc.document_path, null::text, null::bigint,
        vc.id::text, v.name, vc.total, vc.created_at, 'counta'
      from vendor_credits vc left join vendors v on v.id = vc.vendor_id
      where vc.org_id = p_org and vc.document_path like v_pre || '%' and vc.credit_date between p_from and p_to;
    return query
      select 'customs:' || ce.id, 'purchases', 'Import entries', null::text, date_trunc('month', ce.entry_date)::date, extract(year from ce.entry_date)::int,
        ce.entry_date, ce.number || coalesce(' · ' || nullif(ce.description, ''), ''), 'file', ce.document_path, null::text, null::bigint, ce.id::text,
        ce.importer, ce.value_ngn, ce.created_at, 'counta'
      from customs_entries ce where ce.org_id = p_org and ce.document_path like v_pre || '%' and ce.entry_date between p_from and p_to;
  end if;

  if c->>'tax' = 'true' then
    -- The files Counta made for each return (and the audited statements kept with a CIT year), as they are stored.
    return query
      select 'obj:' || o.id::text, 'tax',
        case x[1] when 'vat' then 'VAT' when 'wht' then 'WHT' when 'wvat' then 'Withholding VAT' else 'CIT' end,
        case when x[1] = 'cit' and o.name like v_pre || 'tax/cit/%/afs/%' then 'Audited statements' else 'Return files' end,
        case when x[1] = 'cit' then null::date else (x[2] || '-01')::date end,
        case when x[1] = 'cit' then x[2]::int else left(x[2], 4)::int end,
        case when x[1] = 'cit' then null::date else (x[2] || '-01')::date end,
        regexp_replace(o.name, '^.*/', ''), 'file', o.name, o.metadata->>'mimetype', nullif(o.metadata->>'size', '')::bigint, null::text, null::text,
        null::numeric, o.created_at, 'counta'
      from storage.objects o, lateral (select regexp_match(o.name, '^[^/]+/tax/(vat|wht|wvat|cit)/([0-9]{4}(?:-[0-9]{2})?)/')) r(x)
      where o.bucket_id = 'documents' and o.name like v_pre || 'tax/%' and x is not null
        and ((x[1] = 'cit' and x[2] ~ '^[0-9]{4}$' and make_date(x[2]::int, 12, 31) >= p_from and make_date(x[2]::int, 1, 1) <= p_to)
          or (x[1] <> 'cit' and x[2] ~ '^[0-9]{4}-[0-9]{2}$' and (x[2] || '-01')::date between date_trunc('month', p_from)::date and p_to));
    -- The accountant's versions of a schedule (financial statements are under Accountant). VAT and WHT periods are months
    -- ('2026-09'), CIT periods years ('2025'), financial statements a span ('2025-01-01:2025-12-31', kept with its last year).
    return query
      select 'version:' || fv.id, case when fv.kind = 'fs' then 'accountant' else 'tax' end,
        case fv.kind when 'vat' then 'VAT' when 'wht' then 'WHT' when 'cit' then 'CIT' else 'Financial statements' end,
        case when fv.kind = 'fs' then null else 'Accountant versions' end, pp.per, pp.yr, pp.per,
        fv.file_name || ' (version ' || fv.version || coalesce(', ' || nullif(fv.practice_name, ''), '') || ')', 'file', fv.file_path, null::text, fv.size_bytes::bigint,
        fv.id::text, fv.uploader_name, null::numeric, fv.created_at, 'accountant'
      from filing_versions fv,
        lateral (select case when fv.kind in ('vat', 'wht') and fv.period ~ '^[0-9]{4}-[0-9]{2}' then (left(fv.period, 7) || '-01')::date end as per,
          coalesce(case when fv.kind = 'fs' then substring(fv.period from '([0-9]{4})-[0-9]{2}-[0-9]{2}$') else substring(fv.period from '^([0-9]{4})') end,
            extract(year from fv.created_at)::text)::int as yr) pp
      where fv.org_id = p_org and fv.file_path like v_pre || '%' and (fv.kind <> 'fs' or c->>'accountant' = 'true')
        and ((pp.per is not null and pp.per between date_trunc('month', p_from)::date and p_to)
          or (pp.per is null and make_date(pp.yr, 12, 31) >= p_from and make_date(pp.yr, 1, 1) <= p_to));
    -- The PRN and payment Rev360 asked for: a slip Counta makes when it is opened.
    return query
      select 'prn:' || t.id, 'tax', case t.tax when 'vat' then 'VAT' when 'wht' then 'WHT' when 'wvat' then 'Withholding VAT' else 'CIT' end, 'PRN and payment',
        case when t.tax = 'cit' then null::date else date_trunc('month', t.period)::date end,
        coalesce(t.accounting_year, extract(year from t.period)::int), case when t.tax = 'cit' then null::date else t.period end,
        'PRN ' || t.prn || ' · ' || replace(t.status, '_', ' '), 'prn', null::text, 'application/pdf', null::bigint, t.id::text, t.authority, t.amount, t.received_at, 'flux'
      from tax_payment_instructions t where t.org_id = p_org and t.period between date_trunc('month', p_from)::date and p_to;
    return query
      select 'wrem:' || w.id, 'tax', case when w.kind = 'wvat' then 'Withholding VAT' else 'WHT' end, 'Payment receipts', date_trunc('month', w.period)::date,
        extract(year from w.period)::int, w.period, coalesce(nullif(w.reference, ''), 'Remittance') || ' · ' || w.authority, 'file', w.receipt_path, null::text,
        null::bigint, w.id::text, w.authority, w.amount, w.created_at, 'counta'
      from wht_remittances w where w.org_id = p_org and w.receipt_path like v_pre || '%' and w.period between date_trunc('month', p_from)::date and p_to;
  end if;

  if c->>'accountant' = 'true' then
    return query
      select 'request:' || pr.id, 'accountant', 'Requests', null::text, date_trunc('month', coalesce(pr.answered_at, pr.created_at))::date,
        extract(year from coalesce(pr.answered_at, pr.created_at))::int, coalesce(pr.answered_at, pr.created_at)::date,
        coalesce(nullif(pr.file_name, ''), 'File') || ' · ' || pr.title, 'file', pr.file_path, null::text, null::bigint, pr.id::text, null::text, null::numeric,
        coalesce(pr.answered_at, pr.created_at), 'accountant'
      from practice_requests pr where pr.org_id = p_org and pr.file_path like v_pre || '%' and coalesce(pr.answered_at, pr.created_at)::date between p_from and p_to;
  end if;

  -- The CAC records the owner filed in onboarding hold the directors' details: the owner's alone.
  if private.perm_of(m, 'owner') and p_undated then
    return query
      select 'kyc:' || k.id, 'company', 'Registration', null::text, null::date, null::int, null::date,
        coalesce(nullif(k.doc->>'file_name', ''), 'CAC records'), 'file', k.doc->>'path', nullif(k.doc->>'mime', ''), null::bigint, k.id::text, null::text,
        null::numeric, coalesce(k.updated_at, k.created_at), 'counta'
      from kyc_profiles k where k.org_id = p_org and k.doc->>'path' like v_pre || 'kyc/%' and k.doc->>'path' not like '%nin-slip%';
  end if;

  -- Uploaded files and what Flux sent back.
  return query
    select 'doc:' || d.id, d.cat, d.folder, d.sub, d.period, coalesce(d.year, extract(year from d.period)::int), d.period, d.name, 'file', d.path, d.mime, d.size,
      d.id::text, (select display_name from members where id = d.uploaded_by), null::numeric, d.created_at, d.source
    from documents d
    where d.org_id = p_org and coalesce(c->>d.cat, 'false') = 'true'
      and ((d.period is not null and d.period between date_trunc('month', p_from)::date and p_to)
        or (d.period is null and d.year is not null and make_date(d.year, 12, 31) >= p_from and make_date(d.year, 1, 1) <= p_to)
        or (d.period is null and d.year is null and p_undated));
end $function$;

-- private.document_may_delete: the signed-in person removes any upload -> perm_of
CREATE OR REPLACE FUNCTION private.document_may_delete(p_path text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select exists (select 1 from documents d join members mm on mm.org_id = d.org_id and mm.user_id = auth.uid() and mm.status = 'active'
    where d.path = p_path and d.source = 'upload' and (d.uploaded_by = mm.id or private.perm_of(mm, 'owner')))
$function$;

-- private.einvoice_issue_held: who issues a held invoice when its issuer is gone (an owner place in any status, as before, or the contact) -> org_contact
CREATE OR REPLACE FUNCTION private.einvoice_issue_held(p_sale uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare s public.sales; m public.members; v_closed date;
begin
  select * into s from sales where id = p_sale for update;
  if s.status <> 'draft' or s.journal_id is not null then return; end if;
  select * into m from members where id = coalesce((select issued_by from einvoice_docs where sale_id = p_sale), s.created_by);
  if m.id is null then select * into m from members where org_id = s.org_id and (role = 'owner' or id = (private.org_contact(s.org_id)).id) order by created_at limit 1; end if;
  update sales set status = 'open' where id = s.id;
  v_closed := private.closed_through(s.org_id);
  perform private.post_sale(s.id, m, case when v_closed is not null and s.issue_date <= v_closed then now() else private.posting_time(s.org_id, s.issue_date) end);
  perform private.refresh_sale(s.id);
  update einvoice_docs set held = false, updated_at = now() where sale_id = p_sale;
end $function$;

-- private.instruction_alert: the person named in the alert -> org_contact
CREATE OR REPLACE FUNCTION private.instruction_alert(i tax_payment_instructions, p_why text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare o public.orgs; ow public.members; v_what text := private.tax_label(i.tax) || ' payment'; v_when text := private.tax_when(i.tax, i.period, i.accounting_year); e jsonb;
begin
  select * into o from orgs where id = i.org_id;
  ow := private.org_contact(i.org_id);
  e := private.tax_expected(i.org_id, i.tax, i.period, i.authority, i.accounting_year);
  perform private.alert_send(i.org_id, 'tax_payment', i.id::text || ':' || p_why || ':' || coalesce(i.account_number, ''),
    case when p_why = 'expired' then array['push', 'email'] else array['push', 'email', 'whatsapp'] end,
    jsonb_build_object('perm', 'make_payments',
      'title', case when p_why = 'expired' then 'The payment account for the ' || lower(v_what) || ' (' || v_when || ') expired'
               else 'The ' || lower(v_what) || ' for ' || v_when || ' is waiting for you: ' || private.naira(i.amount) end,
      'body', case when p_why = 'expired' then 'Ask Flux for a new account in Counta, then pay it.' else coalesce(i.reason, 'Approve it in Counta.') end,
      'url', '/payments?tab=tax', 'button', 'Open the tax payment',
      'lines', jsonb_build_array(
        'Rev360 has given PRN ' || i.prn || ' for ' || o.name || '''s ' || lower(v_what) || ' for ' || v_when || ': ' || private.naira(i.amount) || '.',
        case when p_why = 'expired' then 'The account it gave expired before it was paid. Ask Flux for a new one in Counta.' else coalesce(i.reason, '') end,
        case when p_why <> 'expired' then 'Pay to ' || i.account_name || ', ' || i.account_number || ' (' || i.bank_name || ')'
          || coalesce(', before ' || to_char(i.expires_at at time zone coalesce(o.timezone, 'Africa/Lagos'), 'FMDD Mon, HH24:MI'), '') || '.' end),
      'wa_name', 'counta_tax_deadline', 'wa_params', jsonb_build_array(split_part(coalesce(ow.display_name, ''), ' ', 1), o.name, lower(v_what), v_when,
        to_char(coalesce((e->>'due')::date, i.received_at::date), 'FMDD Mon YYYY'), private.naira(i.amount))));
end $function$;

-- private.instruction_block: someone to pay the tax for -> org_contact
CREATE OR REPLACE FUNCTION private.instruction_block(i tax_payment_instructions)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare t public.tax_wallets; e jsonb; v_spend numeric; r jsonb;
begin
  if i.expires_at is not null and i.expires_at < now() + interval '2 minutes' then return 'expired'; end if;
  select * into t from tax_wallets where org_id = i.org_id and status = 'active';
  if not found then return 'The business has no tax wallet. Pay it by transfer from a bank account to the account shown, then mark it paid.'; end if;
  if (select is_sample from orgs where id = i.org_id) then return 'This is a sample business, so Counta does not pay its tax by itself.'; end if;
  -- Payments paused by TaxStreem, or not open yet (the NIN check): the same as for every other payment.
  begin
    perform private.require_payments_open(i.org_id);
  exception when others then
    return sqlerrm;
  end;
  if i.bank_code is null then return format('Counta could not find the bank "%s" to pay into. Pay it by transfer from a bank account, then mark it paid.', i.bank_name); end if;
  if i.name_ok is false then
    return format('The bank says account %s belongs to %s, but Flux read the name as %s. The tax wallet will not pay it: ask Flux for a new account, or pay it from a bank if you are sure.',
      i.account_number, coalesce(nullif(i.resolved_name, ''), 'someone else'), i.account_name);
  end if;
  if i.name_ok is null then return 'Counta could not check the account name with the bank. Check it before paying.'; end if;
  if not private.tax_payee_name_ok(i.resolved_name) then
    return format('The bank shows account %s as %s, which does not look like a tax collection account. The tax wallet will not pay it: ask Flux for a new account, or pay it from a bank if you are sure.',
      i.account_number, i.resolved_name);
  end if;
  if (private.org_contact(i.org_id)).id is null then return 'The business has no owner to pay it for.'; end if;
  e := private.tax_expected(i.org_id, i.tax, i.period, i.authority, i.accounting_year);
  if e->>'state' = 'paid' then return 'Counta shows this return as paid already.'; end if;
  if exists (select 1 from tax_payments where org_id = i.org_id and kind = i.tax and period = i.period and authority = i.authority
             and status in ('approved', 'processing', 'successful') and instruction_id is distinct from i.id) then
    return 'A payment for this return is already on its way or made.';
  end if;
  if i.expected is null then
    return format('Counta has no %s for %s to check the amount against.',
      case i.tax when 'vat' then 'filed VAT return' when 'cit' then 'approved CIT return' else 'deductions' end, private.tax_when(i.tax, i.period, i.accounting_year));
  end if;
  if i.breakdown is not null then
    r := private.instruction_reconcile(i);
    if not (r->>'explained')::boolean then return r->>'reason'; end if;
  elsif abs(i.amount - i.expected) >= 1 then
    return format('Rev360 asks for %s; the return in Counta comes to %s. Flux did not say what the difference is for.', private.naira(i.amount), private.naira(i.expected));
  end if;
  if not coalesce((select tax_autopay from orgs where id = i.org_id), true) then return 'Paying these automatically is switched off for this business.'; end if;
  v_spend := private.tax_wallet_spendable(t.id);
  if i.amount > v_spend + 0.004 then
    return format('The tax wallet can pay %s; %s is due. Top it up, or pay it by transfer from a bank.', private.naira(v_spend), private.naira(i.amount));
  end if;
  return null;
end $function$;

-- private.match_bank_line: who the matching acts as -> org_contact
CREATE OR REPLACE FUNCTION private.match_bank_line(p_line uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare bl public.bank_lines; b public.bank_accounts; v_amt numeric; v_in boolean; r record; c public.collections; v_cnt int; m public.members;
  v_cust public.customers; v_vendor public.vendors; v_due numeric; v_rate numeric; v_gross numeric; v_wht numeric; v_head numeric; j public.journals;
  other public.bank_lines; ob public.bank_accounts; v_key text; v_rule public.entity_rules; v_at timestamptz; v_text text; s public.sales; bb public.bills;
  v_left_wht numeric; v_pid uuid; v_split jsonb; v_cands jsonb; v_pos text;
begin
  select * into bl from bank_lines where id = p_line for update;
  if bl.status <> 'unmatched' then return bl.stage; end if;
  select * into b from bank_accounts where id = bl.bank_account_id;
  v_amt := abs(bl.amount); v_in := bl.amount > 0;
  v_key := private.party_key(coalesce(nullif(bl.counterparty, ''), bl.description));
  update bank_lines set party_key = v_key where id = bl.id;
  v_at := private.line_time(bl.org_id, bl.line_date);
  v_text := coalesce(bl.description, '') || ' ' || coalesce(bl.reference, '') || ' ' || coalesce(bl.counterparty, '');
  -- Actions are taken in the name of the business owner; the line and its evidence say why.
  m := private.org_contact(bl.org_id);

  -- 1 Already in the books on this account, same amount, within three days, not yet tied to another line.
  select l.journal_id into r from journal_lines l join journals jj on jj.id = l.journal_id
  where l.org_id = bl.org_id and l.account_code = b.ledger_code and (case when v_in then l.debit else l.credit end) = v_amt
    and jj.entry_date between bl.line_date - 3 and bl.line_date + 3
    and not exists (select 1 from bank_lines x where x.bank_account_id = b.id and x.journal_id = l.journal_id and x.id <> bl.id)
  order by abs(jj.entry_date - bl.line_date), jj.created_at limit 1;
  if r.journal_id is not null then
    update bank_lines set status = 'matched', journal_id = r.journal_id, stage = 'in_books', matched_by = 'system', confidence = 1 where id = bl.id;
    return 'in_books';
  end if;
  -- 1b A POS provider settling payments Counta already holds in 9002 (see pos_settle_line).
  if v_in then
    v_pos := private.pos_settle_line(bl, b, m);
    if v_pos is not null then return v_pos; end if;
  end if;

  if v_in then
    -- 2 A transfer recorded at the till or against an invoice, waiting for confirmation: the statement confirms it.
    select count(*) into v_cnt from collections col where col.org_id = bl.org_id and col.status = 'pending' and col.direction = 'in'
      and col.amount = v_amt and col.method in ('transfer', 'card', 'pos', 'cheque', 'other') and col.received_at::date between bl.line_date - 5 and bl.line_date + 1;
    if v_cnt >= 1 then
      select col.* into c from collections col join customers cu on cu.id = col.customer_id
      where col.org_id = bl.org_id and col.status = 'pending' and col.direction = 'in' and col.amount = v_amt
        and col.method in ('transfer', 'card', 'pos', 'cheque', 'other') and col.received_at::date between bl.line_date - 5 and bl.line_date + 1
      order by private.name_in(cu.name, bl.description) desc, (col.reference is not null and position(upper(col.reference) in upper(bl.description || ' ' || coalesce(bl.reference, ''))) > 0) desc,
        abs(col.received_at::date - bl.line_date), col.received_at limit 1;
      if v_cnt = 1 or private.name_in((select name from customers where id = c.customer_id), bl.description) then
        update collections set status = 'confirmed', bank_account_id = b.id, confirmed_at = now(), note = concat_ws(' · ', note, 'Confirmed by the bank statement')
        where id = c.id;
        c := private.post_collection(c.id, m);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'pending_payment', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'pending_payment';
      end if;
    end if;

    -- 2b The invoice or order the narration names, whoever paid it (a director paying for the company, a relative).
    select * into s from sales x where x.org_id = bl.org_id and x.doc_type in ('invoice', 'order') and x.status in ('open', 'partially_paid') and x.journal_id is not null
      and x.issue_date <= bl.line_date + 1 and private.doc_in_text(x.number, v_text)
    order by x.issue_date desc limit 1;
    if s.id is not null then
      v_due := s.total - s.amount_paid - s.credited - coalesce((select sum(a.amount) from collection_allocations a join collections cc on cc.id = a.collection_id
        where a.sale_id = s.id and cc.status = 'pending'), 0);
      -- The invoice's own number and exactly what is owed (or that less WHT, and VAT for a customer who withholds VAT): settled.
      -- Any other amount is put to a person below.
      v_split := private.customer_short_split(s.id, v_due, v_amt);
      if abs(v_due - v_amt) < 0.005 or v_split is not null then
        if v_split is not null then
          perform private.book_customer_withholding(bl.org_id, s.customer_id, s.id, v_split, v_at, m);
        end if;
        c := private.add_collection(bl.org_id, s.customer_id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
          'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'Matched from the bank by ' || s.number, 'spread', false), m, 'confirmed', array[s.id]);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'invoice_ref', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'invoice_ref';
      end if;
    end if;
  else
    -- 3 Statutory payees clear the tax head, never an expense (AP-06).
    select * into r from payee_registry pr where pr.kind like 'statutory%' and pr.direction in ('out', 'both')
      and upper(bl.description || ' ' || coalesce(bl.counterparty, '')) ~ pr.pattern order by pr.id limit 1;
    if r.id is not null then
      j := private.post_bank_line(bl.id, coalesce(case when r.role is not null then private.acct(bl.org_id, r.role) end, r.account_code), null, null,
        r.description || ' · ' || bl.description, 'statutory', jsonb_build_object('matched_by', 'rule'));
      select coalesce(sum(credit - debit), 0) into v_head from journal_lines where org_id = bl.org_id and account_code = coalesce(case when r.role is not null then private.acct(bl.org_id, r.role) end, r.account_code);
      if v_head < -0.004 then
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'tax', 'remittance_without_accrual', 'bank_line', bl.id, 'Paid more ' || r.description || ' than the books owed',
          'This remittance is more than the liability on record. Is a return missing, or was this paid in advance?',
          jsonb_build_object('account', r.account_code, 'overpaid', -v_head), 1, 'AP-06 exception', 'statutory', 'info', v_amt, j.id) on conflict do nothing;
      end if;
      return 'statutory';
    end if;

    -- 3b The bill the narration names: Counta's number, or the supplier's own invoice number together with the amount
    --    owed or the supplier's name (a short invoice number alone could be a coincidence).
    select bb2.* into bb from bills bb2 where bb2.org_id = bl.org_id and bb2.status in ('approved', 'partially_paid')
      and (private.doc_in_text(bb2.number, v_text)
           or private.ref_in_text(bb2.vendor_ref, v_text) and (abs(bb2.total - bb2.amount_paid - v_amt) < 0.005
             or abs(bb2.total - bb2.amount_paid - greatest(bb2.wht_expected + bb2.wvat_expected - bb2.wht_withheld - bb2.wvat_withheld, 0) - v_amt) < 0.005
             or private.name_in((select name from vendors where id = bb2.vendor_id), coalesce(bl.counterparty, '') || ' ' || bl.description)))
    order by bb2.due_date limit 1;
    if bb.id is not null then
      v_due := bb.total - bb.amount_paid - coalesce((select sum(gross) from bill_payments where bill_id = bb.id and status = 'processing'), 0);
      v_left_wht := greatest(bb.wht_expected + bb.wvat_expected - bb.wht_withheld - bb.wvat_withheld
        - coalesce((select sum(wht + wvat) from bill_payments where bill_id = bb.id and status = 'processing'), 0), 0);
      v_rate := coalesce((bb.wht_expected + bb.wvat_expected) / nullif(bb.total, 0), 0);
      v_gross := case when abs(v_due - v_amt) < 0.005 then v_due
                      when v_left_wht > 0 and abs(v_due - v_left_wht - v_amt) < 0.005 then v_due end;
      if v_gross is not null then
        v_wht := greatest(v_gross - v_amt, 0);
        j := private.record_bill_payment(bb.id, b.id, v_gross, v_wht, v_at, coalesce(bl.reference, left(bl.description, 60)), m);
        update bank_lines set status = 'matched', journal_id = j.id, stage = 'bill_ref', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'bill_ref';
      end if;
    end if;
  end if;

  if v_in then
    -- 4 A customer named in the narration: their open invoices that fit are put to a person to confirm (AR-03).
    for v_cust in select cu.* from customers cu where cu.org_id = bl.org_id and not cu.is_walk_in and not cu.archived
        and private.name_in(cu.name, coalesce(bl.counterparty, '') || ' ' || bl.description)
        order by length(cu.name) desc limit 1 loop
      v_cands := private.match_candidates(bl.id);
      if jsonb_array_length(v_cands) > 0 then
        perform private.propose_match(bl.id, v_cands, 'customer');
        return 'customer';
      end if;
      select coalesce(sum(s2.total - s2.amount_paid - s2.credited), 0) into v_due from sales s2
      where s2.customer_id = v_cust.id and s2.status in ('open', 'partially_paid') and s2.journal_id is not null;
      -- Paying with nothing owed: held as an advance, flagged (AR rule).
      if v_due <= 0.004 then
        c := private.add_collection(bl.org_id, v_cust.id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
          'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'No invoice open: held as customer credit', 'spread', true), m, 'confirmed', null);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'customer_advance', matched_by = 'system', confidence = 0.8 where id = bl.id;
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'bookkeeper', 'advance_without_invoice', 'bank_line', bl.id, v_cust.name || ' paid with nothing owed',
          'Held as customer credit. Raise the invoice it was for, or refund it.', jsonb_build_object('customer_id', v_cust.id), 0.8,
          'AR: inflow from a known customer with no open invoice', 'customer', 'info', v_amt, c.journal_id) on conflict do nothing;
        return 'customer_advance';
      end if;
    end loop;
  else
    -- 5 A vendor named in the narration being paid for open bills (AP-03).
    for v_vendor in select v.* from vendors v where v.org_id = bl.org_id
        and (private.name_in(v.name, coalesce(bl.counterparty, '') || ' ' || bl.description)
             or (v.account_number is not null and position(v.account_number in coalesce(bl.counterparty_account, '') || bl.description) > 0))
        order by length(v.name) desc limit 1 loop
      v_cands := private.match_candidates(bl.id);
      if jsonb_array_length(v_cands) > 0 then
        perform private.propose_match(bl.id, v_cands, 'vendor_bill');
        return 'vendor_bill';
      end if;
      -- A known vendor with no matching bill: post to their usual account and ask for the bill (AP-05).
      if v_vendor.default_account is not null then
        j := private.post_bank_line(bl.id, v_vendor.default_account, null, null, v_vendor.name || ' · no bill', 'vendor_no_bill',
          jsonb_build_object('matched_by', 'rule', 'ai_confidence', 0.85));
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'bookkeeper', 'payment_without_bill', 'bank_line', bl.id, 'Paid ' || v_vendor.name || ' without a bill',
          'Posted to their usual account with no VAT claimed and no WHT. Upload the bill if there is one.', jsonb_build_object('vendor_id', v_vendor.id),
          0.85, 'AP-05', 'vendor_no_bill', 'info', v_amt, j.id) on conflict do nothing;
        return 'vendor_no_bill';
      end if;
    end loop;
  end if;

  -- 6 Money moving between the business's own accounts.
  select x.* into other from bank_lines x join bank_accounts xa on xa.id = x.bank_account_id
  where x.org_id = bl.org_id and x.bank_account_id <> bl.bank_account_id and x.amount = -bl.amount and x.status in ('unmatched', 'posted')
    and x.line_date between bl.line_date - 2 and bl.line_date + 2 and (x.status = 'unmatched' or x.stage = 'transfer_one_leg')
  order by abs(x.line_date - bl.line_date) limit 1;
  if other.id is not null then
    select * into ob from bank_accounts where id = other.bank_account_id;
    if other.status = 'unmatched' then
      j := private.post_entry(bl.org_id, 'Transfer between own accounts · ' || b.name || ' and ' || ob.name, 'bank', bl.id, m.id, null,
        private.reclass_pair(case when v_in then b.ledger_code else ob.ledger_code end, case when v_in then ob.ledger_code else b.ledger_code end, v_amt, null, null),
        v_at, jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id), jsonb_build_object('type', 'bank_line', 'id', other.id))));
      update bank_lines set status = 'matched', journal_id = j.id, stage = 'transfer', matched_by = 'system', confidence = 1 where id in (bl.id, other.id);
    else
      j := private.post_bank_line(bl.id, private.acct(bl.org_id, 'bank_clearing'), null, null, 'Transfer between own accounts · ' || ob.name, 'transfer',
        jsonb_build_object('matched_by', 'system'), 'matched');
      update bank_lines set stage = 'transfer' where id = other.id;
    end if;
    return 'transfer';
  end if;
  -- 6b Money sent to Bujeti from this account (or taken back from it): a transfer to or from the Bujeti balance.
  if upper(v_text) ~ '\yBUJETI\y' then
    select xa.* into ob from bank_accounts xa where xa.org_id = bl.org_id and xa.id <> b.id and xa.active and xa.provider = 'integration'
      and xa.provider_ref = bl.org_id::text || ':bujeti';
    if ob.id is not null then
      perform private.post_bank_line(bl.id, ob.ledger_code, null, null, case when v_in then 'Money back from Bujeti · ' else 'Money sent to Bujeti · ' end || bl.description,
        'transfer', jsonb_build_object('matched_by', 'system'));
      return 'transfer';
    end if;
  end if;
  if exists (select 1 from bank_accounts xa where xa.org_id = bl.org_id and xa.id <> b.id and xa.active
             and ((xa.account_number is not null and position(xa.account_number in coalesce(bl.counterparty_account, '') || ' ' || bl.description) > 0)
                  or upper(bl.description) ~ '(OWN ACCOUNT|SELF TRANSFER|TRF TO SELF|SWEEP)')) then
    perform private.post_bank_line(bl.id, private.acct(bl.org_id, 'bank_clearing'), null, null, 'Transfer between own accounts, other side to come', 'transfer_one_leg',
      jsonb_build_object('matched_by', 'system'));
    return 'transfer_one_leg';
  end if;

  -- 7 A rule learned from an earlier decision.
  select * into v_rule from entity_rules er where er.org_id = bl.org_id and er.direction = case when v_in then 'in' else 'out' end
    and v_key is not null and (er.party_key = v_key or position(er.party_key in v_key) > 0) order by length(er.party_key) desc limit 1;
  if v_rule.id is not null and private.postable(bl.org_id, v_rule.account_code) then
    perform private.post_bank_line(bl.id, v_rule.account_code,
      case when v_rule.customer_id is not null then 'customer' when v_rule.vendor_id is not null then 'vendor' end, coalesce(v_rule.customer_id, v_rule.vendor_id),
      null, 'rule', jsonb_build_object('matched_by', 'rule', 'ai_confidence', 0.95));
    update entity_rules set hits = hits + 1 where id = v_rule.id;
    return 'rule';
  end if;

  -- 8 Payee types: bank charges, power, telcos, internet, fuel, CAC, interest received.
  select * into r from payee_registry pr where pr.kind not like 'statutory%' and pr.direction in (case when v_in then 'in' else 'out' end, 'both')
    and upper(bl.description || ' ' || coalesce(bl.counterparty, '')) ~ pr.pattern order by pr.id limit 1;
  if r.id is not null then
    perform private.post_bank_line(bl.id, coalesce(case when r.role is not null then private.acct(bl.org_id, r.role) end, r.account_code), null, null,
      r.description || ' · ' || bl.description, 'registry', jsonb_build_object('matched_by', 'rule', 'ai_confidence', 0.9));
    return 'registry';
  end if;

  -- 9 Nobody named: the open invoices (or bills) the amount fits, as it stands, less WHT or less bank charges, are put to a
  --   person to confirm in one tap.
  v_cands := private.match_candidates(bl.id);
  if jsonb_array_length(v_cands) > 0 then
    perform private.propose_match(bl.id, v_cands, case when v_in then 'invoice_amount' else 'bill_amount' end);
    return case when v_in then 'invoice_amount' else 'bill_amount' end;
  end if;
  return null;
end $function$;

-- private.mfa_required: the person's own places that need MFA -> perm_of
CREATE OR REPLACE FUNCTION private.mfa_required(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select p_user is not null and exists (select 1 from public.members m
    where m.user_id = p_user and m.status = 'active' and (private.perm_of(m, 'owner') or coalesce(m.p_manage_settings, false)))
$function$;

-- private.migration_member: the caller moves the books -> perm_of
CREATE OR REPLACE FUNCTION private.migration_member(p_org uuid)
 RETURNS members
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'owner') or private.perm_of(m, 'keep_books')) then
    raise exception 'Only the owner or the bookkeeper moves the books into Counta.' using errcode = '42501';
  end if;
  return m;
end $function$;

-- private.notify_perm: a recipient's own all-branches scope (the owner hears from every branch) -> perm_of
CREATE OR REPLACE FUNCTION private.notify_perm(p_org uuid, p_perm text, p_kind text, p_title text, p_body text, p_url text, p_tag text DEFAULT NULL::text, p_except uuid DEFAULT NULL::uuid, p_location uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members;
begin
  if private.quiet(p_org) then return; end if;
  for m in select * from members where org_id = p_org and status = 'active' and user_id is not null loop
    if (p_except is null or m.id <> p_except)
       and private.perm_of(m, p_perm)
       and (p_location is null or m.location_id is null or m.location_id = p_location or private.perm_of(m, 'owner')) then
      perform private.notify(p_org, m.user_id, p_kind, p_title, p_body, p_url, p_tag);
    end if;
  end loop;
end $function$;

-- private.pit_access: the caller's owner flag -> perm_of
CREATE OR REPLACE FUNCTION private.pit_access(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; v_all boolean; v_money boolean; v_me uuid;
begin
  m := private.require(p_org, null);
  v_all := private.perm_of(m, 'file_tax');
  v_money := private.can_handle_money(p_org);
  select id into v_me from pit_people where org_id = p_org and member_id = m.id;
  if not (v_all or v_money or v_me is not null) then
    raise exception 'Income tax returns need File tax, or Keep the books, See margins or Make payments.' using errcode = '42501';
  end if;
  return jsonb_build_object('member_id', m.id, 'name', m.display_name, 'all', v_all, 'money', v_money, 'books', private.perm_of(m, 'keep_books'),
    'me', v_me, 'owner', private.perm_of(m, 'owner'));
end $function$;

-- private.pit_pay_remind: the reminder's recipients -> org_contact
CREATE OR REPLACE FUNCTION private.pit_pay_remind()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare y record; o public.orgs; v_tr jsonb; v_asker uuid; v_asker_name text; v_at text; v_amt text; v_link text; v_n int := 0; r record; v_lines jsonb;
  v_seen text[];
begin
  v_link := coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app');
  for y in
    select py.org_id, py.accounting_year, py.person_id, py.bill, p.name person_name from pit_person_years py join pit_people p on p.id = py.person_id
    where py.paid_at is null and py.bill ? 'transfer' and py.bill->'transfer'->>'reminded_at' is null
      and private.pit_ts(py.bill->'transfer'->>'fetched_at') between now() - interval '1 day' and now() - interval '30 minutes'
      and not (py.pay_round_at is not null and (py.pay_round_ended_at is null or py.pay_round_at >= private.pit_ts(py.bill->'transfer'->>'fetched_at') - interval '1 hour'))
    for update of py skip locked
  loop
    update pit_person_years set bill = jsonb_set(bill, '{transfer,reminded_at}', to_jsonb(now()))
    where org_id = y.org_id and accounting_year = y.accounting_year and person_id = y.person_id;
    select * into o from orgs where id = y.org_id;
    continue when o.is_sample or not private.feature_on(o.id, 'email');
    v_tr := y.bill->'transfer';
    v_asker := coalesce(nullif(v_tr->>'asked_by', '')::uuid, (select created_by from lirs_jobs where org_id = y.org_id and accounting_year = y.accounting_year
      and person_id = y.person_id and kind = 'pay_account' and status = 'done' order by finished_at desc nulls last limit 1));
    select display_name into v_asker_name from members where id = v_asker;
    v_at := to_char(private.pit_ts(v_tr->>'fetched_at') at time zone coalesce(nullif(o.timezone, ''), 'Africa/Lagos'), 'HH24:MI');
    v_amt := '₦' || to_char(round(coalesce(private.num(v_tr->>'amount'), private.num(y.bill->>'amount'), 0), 2), 'FM999,999,999,990.00');
    v_seen := '{}';
    for r in
      select mb.id, mb.user_id, mb.display_name, lower(trim(coalesce(nullif(trim(coalesce(mb.email, '')), ''), u.email))) email, mb.id = v_asker is_asker
      from members mb left join auth.users u on u.id = mb.user_id
      where mb.org_id = y.org_id and mb.status = 'active' and (mb.id = v_asker or mb.id = (private.org_contact(y.org_id)).id)
      order by mb.id = v_asker desc, mb.created_at
    loop
      continue when r.email is null or r.email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or r.email = any(v_seen);
      v_seen := v_seen || r.email;
      v_lines := jsonb_build_array(
        case when r.is_asker then 'You asked for an account at ' || v_at else coalesce(v_asker_name, 'Someone in ' || o.name) || ' asked for an account at ' || v_at end
          || ' to pay ' || y.person_name || '''s ' || y.accounting_year || ' Lagos State income tax of ' || v_amt
          || '. Counta has not seen the money go out, and that account has now expired.',
        'Log in to Counta, open Tax, then Personal income tax, and press Pay for a fresh account. Have your bank app ready first: each account works for 15 minutes.',
        'If the money has already gone, open the bill and tap I''ve paid, and Counta will confirm the payment with LIRS.');
      begin
        perform private.queue_message(y.org_id, 'email', r.email, 'alert', y.person_name || '''s ' || y.accounting_year || ' income tax is not paid yet',
          jsonb_build_object('kind', 'pit_pay_remind', 'person_name', r.display_name, 'business', o.name, 'heading', 'Pay ' || y.person_name || '''s ' || y.accounting_year || ' income tax',
            'lines', v_lines, 'button', 'Log in and pay', 'link', v_link || '/tax/pit?year=' || y.accounting_year, 'automatic', true,
            'footer', 'Counta sends this when a tax payment it set up for ' || o.name || ' has not gone through.'),
          null, null, v_asker);
        v_n := v_n + 1;
      exception when others then
        null;
      end;
      perform private.notify(y.org_id, r.user_id, 'books', y.person_name || '''s ' || y.accounting_year || ' income tax is not paid yet',
        'The account for it has expired. Press Pay for a fresh one, or tap I''ve paid if the money has gone.', '/tax/pit?year=' || y.accounting_year,
        'lirs-remind-' || y.person_id || '-' || y.accounting_year);
    end loop;
  end loop;
  return v_n;
end $function$;

-- private.pos_owner_member: who POS postings act as -> org_contact
CREATE OR REPLACE FUNCTION private.pos_owner_member(p_org uuid)
 RETURNS members
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select * from private.org_contact(p_org) where id is not null
$function$;

-- private.pos_require_manager: the caller looks after POS terminals -> perm_of
CREATE OR REPLACE FUNCTION private.pos_require_manager(p_org uuid)
 RETURNS members
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'owner') or coalesce(private.perm_of(m, 'manage_settings'), false)) then
    raise exception 'Only the owner or someone who manages settings looks after POS terminals.' using errcode = '42501';
  end if;
  return m;
end $function$;

-- private.pos_require_owner: the caller connects a POS provider -> perm_of
CREATE OR REPLACE FUNCTION private.pos_require_owner(p_org uuid)
 RETURNS members
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not private.perm_of(m, 'owner') then raise exception 'Only the owner connects a POS provider or changes its key.' using errcode = '42501'; end if;
  return m;
end $function$;

-- private.prism_owner: who Prism postings act as (the merchant's owner, still possibly an invitation, as before, or the contact) -> org_contact
CREATE OR REPLACE FUNCTION private.prism_owner(p_org uuid)
 RETURNS members
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select * from public.members where org_id = p_org and (role = 'owner' or id = (private.org_contact(p_org)).id) and status <> 'disabled' order by (status = 'active') desc, created_at limit 1
$function$;

-- private.si_apply: who writes the bill when the uploader is gone -> org_contact
CREATE OR REPLACE FUNCTION private.si_apply(p_id uuid, p_extract jsonb, p_model text, p_resolved text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare si public.supplier_invoices; o public.orgs; m public.members; s jsonb; bk jsonb; v public.vendors; v_vendor uuid; v_new boolean := false; x jsonb;
  ln jsonb; v_lines jsonb := '[]'::jsonb; v_code text; v_treat text; v_qty numeric; v_up numeric; v_amt numeric; b public.bills; v_checks jsonb;
  v_day date; v_due date; v_state text; v_addr text; v_tin text; v_acct text; v_wht text; v_entity text; v_mail text; v_phone text; v_vat boolean;
  v_item uuid; v_newi jsonb; v_type text;
begin
  select * into si from supplier_invoices where id = p_id for update;
  if not found then raise exception 'Invoice not found.'; end if;
  select * into o from orgs where id = si.org_id;
  -- The person who uploaded it, else the owner, is who wrote the bill.
  select * into m from members where id = si.submitted_by;
  if m.id is null then m := private.org_contact(si.org_id); end if;
  x := coalesce(p_extract, '{}'::jsonb); s := coalesce(x->'supplier', '{}'::jsonb); bk := coalesce(x->'bank', '{}'::jsonb);
  update supplier_invoices set extract = x, model = p_model, bank_resolved_name = private.si_text(p_resolved, 160), read_at = now(), error = null where id = si.id
  returning * into si;
  if coalesce((x->>'is_invoice')::boolean, true) = false or private.si_text(s->>'name', 160) is null then
    v_checks := private.si_checks(si.id);
    update supplier_invoices set status = 'review', checks = v_checks,
      blocks = (select count(*) from jsonb_array_elements(v_checks) c where c->>'severity' = 'block') where id = si.id;
    return private.si_json(si.id);
  end if;

  -- The supplier.
  v_vendor := private.si_find_vendor(si.org_id, s, bk);
  v_tin := private.clean_tax_id(s->>'tax_id');
  if v_tin is not null and v_tin !~ '^[0-9]{8,13}$' then v_tin := null; end if;
  v_acct := private.si_nuban(bk->>'account_number');
  v_addr := private.si_text(s->>'address', 300);
  v_state := coalesce(private.ng_state(s->>'state'), case when v_addr is not null then private.ng_state_of_address(v_addr) end);
  v_entity := private.si_entity(s->>'entity_kind');
  v_mail := lower(coalesce(nullif(trim(s->>'email'), ''), nullif(trim(si.submitter->>'email'), '')));
  if v_mail is not null and v_mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_mail := null; end if;
  v_phone := private.clean_phone(coalesce(nullif(trim(s->>'phone'), ''), nullif(trim(si.submitter->>'phone'), '')));
  v_wht := case when x->>'wht_category' in (select code from wht_rates where not exemption) then x->>'wht_category' end;
  v_vat := coalesce(private.si_num(x->'vat_amount'), 0) > 0 or coalesce((x->>'vat_shown')::boolean, false);
  if v_vendor is null then
    insert into vendors (org_id, name, address, state, tin, rc_number, email, phone, channel, entity_type, is_individual, resident, country,
      bank_name, account_number, account_name, vat_registered, wht_category)
    values (si.org_id, private.si_text(s->>'name', 120), v_addr, v_state, v_tin, private.si_text(s->>'rc_number', 20), v_mail,
      v_phone, case when v_mail is not null then 'email' else 'whatsapp' end, v_entity, coalesce(v_entity = 'individual', false),
      coalesce(s->>'entity_kind', '') <> 'foreign', coalesce(nullif(upper(s->>'country'), ''), case when s->>'entity_kind' = 'foreign' then 'XX' else 'NG' end),
      private.si_text(bk->>'bank_name', 80), v_acct, private.si_text(bk->>'account_name', 120), v_vat and v_tin is not null, v_wht)
    returning id into v_vendor;
    v_new := true;
  else
    -- Filled in where the record is empty; nothing on file is overwritten.
    update vendors set address = coalesce(nullif(trim(address), ''), v_addr), state = coalesce(state, v_state), tin = coalesce(private.clean_tax_id(tin), v_tin),
      rc_number = coalesce(nullif(trim(rc_number), ''), private.si_text(s->>'rc_number', 20)), email = coalesce(nullif(trim(email), ''), v_mail),
      phone = coalesce(nullif(trim(phone), ''), v_phone), entity_type = coalesce(entity_type, v_entity),
      bank_name = case when account_number is null then coalesce(bank_name, private.si_text(bk->>'bank_name', 80)) else bank_name end,
      account_name = case when account_number is null then coalesce(account_name, private.si_text(bk->>'account_name', 120)) else account_name end,
      account_number = coalesce(account_number, v_acct), wht_category = coalesce(wht_category, v_wht)
    where id = v_vendor;
  end if;
  select * into v from vendors where id = v_vendor;

  -- The draft bill, with the arithmetic put right: each line is its quantity times its price, and VAT is worked out at the
  -- rate on the invoice's day on the lines that carry it.
  for ln in select value from jsonb_array_elements(coalesce(x->'lines', '[]'::jsonb)) loop
    v_qty := coalesce(nullif(private.si_num(ln->'qty'), 0), 1); v_up := private.si_num(ln->'unit_price'); v_amt := private.si_num(ln->'amount');
    if v_up is null and v_amt is not null then v_up := round(v_amt / v_qty, 2); end if;
    if v_up is null or v_up < 0 then continue; end if;
    v_code := nullif(trim(ln->>'account_code'), '');
    if v_code is null or not private.bill_account_ok(si.org_id, v_code) then
      v_code := coalesce(case when private.bill_account_ok(si.org_id, v.default_account) then v.default_account end, private.acct(si.org_id, 'expenses_default'));
    end if;
    v_treat := case when ln->>'vat_treatment' in ('exempt', 'zero') then ln->>'vat_treatment' else 'standard' end;
    -- Stock: an item on the list the reader matched, or a new product it describes (added only if the person ticks it when
    -- approving; otherwise the line stays an expense on the account above).
    v_item := null; v_newi := null;
    if ln->>'line_kind' = 'stock' then
      v_item := (select id from items where id = case when ln->>'item_id' ~ '^[0-9a-f-]{36}$' then (ln->>'item_id')::uuid end and org_id = si.org_id
        and not archived and item_type is distinct from 'service');
      if v_item is null and private.si_text(ln->'new_item'->>'name', 120) is not null then
        v_type := case when ln->'new_item'->>'item_type' in ('merchandise', 'raw_material', 'packaging', 'consumable', 'spare_part', 'chemical', 'finished_good')
          then ln->'new_item'->>'item_type' else 'merchandise' end;
        v_newi := jsonb_strip_nulls(jsonb_build_object('name', private.si_text(ln->'new_item'->>'name', 120), 'item_type', v_type,
          'purchase_unit', coalesce(private.si_text(ln->'new_item'->>'purchase_unit', 30), 'Carton'),
          'pack_size', greatest(1, least(10000, coalesce(round(private.si_num(ln->'new_item'->'pack_size'))::int, 1))),
          'selling_unit', coalesce(private.si_text(ln->'new_item'->>'selling_unit', 30), 'piece'), 'category', private.si_text(ln->'new_item'->>'category', 60),
          'expense_account', v_code));
      end if;
    end if;
    v_lines := v_lines || jsonb_strip_nulls(jsonb_build_object('description', private.si_text(ln->>'description', 300), 'qty', v_qty, 'unit_cost', v_up, 'account_code', v_code,
      'vat_treatment', v_treat, 'ai_confidence', least(greatest(coalesce(private.num(x->>'confidence'), 70) / 100, 0), 1),
      'stock', v_item is not null or v_newi is not null, 'item_id', v_item, 'new_item', v_newi,
      'unit_kind', case when ln->>'unit_kind' = 'selling' then 'selling' else 'purchase' end));
  end loop;
  if jsonb_array_length(v_lines) = 0 and private.si_num(x->'total') is not null then
    v_lines := jsonb_build_array(jsonb_build_object('description', coalesce(private.si_text(x->>'description', 300), 'Invoice ' || coalesce(x->>'invoice_no', '')),
      'qty', 1, 'unit_cost', coalesce(private.si_num(x->'subtotal'), private.si_num(x->'total') - coalesce(private.si_num(x->'vat_amount'), 0)),
      'account_code', coalesce(case when private.bill_account_ok(si.org_id, v.default_account) then v.default_account end, private.acct(si.org_id, 'expenses_default'))));
  end if;
  begin v_day := least(nullif(x->>'invoice_date', '')::date, private.local_day(si.org_id, now())); exception when others then v_day := null; end;
  begin v_due := nullif(x->>'due_date', '')::date; exception when others then v_due := null; end;
  if v_due is not null and v_day is not null and v_due < v_day then v_due := null; end if;
  if jsonb_array_length(v_lines) > 0 then
    b := private.write_bill(si.org_id, jsonb_strip_nulls(jsonb_build_object('id', (select id from bills where id = si.bill_id and status = 'draft'),
      'vendor_id', v.id, 'vendor_ref', private.si_text(x->>'invoice_no', 60), 'bill_date', v_day, 'due_date', v_due,
      'source', 'supplier', 'vat_charged', v_vat, 'prices_include_vat', coalesce((x->>'prices_include_vat')::boolean, false),
      'document_path', si.document_path, 'lines', v_lines,
      'notes', concat_ws(' · ', case when si.source = 'portal' then 'Uploaded by the supplier on the invoice portal' else 'Uploaded and read by Counta' end,
        private.si_text(si.submitter->>'note', 300)))), m);
    update bills set invoice_tin = coalesce(private.si_text(s->>'tax_id', 30), invoice_tin), created_by = coalesce(created_by, m.id) where id = b.id;
  end if;
  update supplier_invoices set vendor_id = v.id, vendor_created = vendor_created or v_new, bill_id = coalesce(b.id, bill_id) where id = si.id;
  v_checks := private.si_checks(si.id);
  update supplier_invoices set status = 'review', checks = v_checks,
    blocks = (select count(*) from jsonb_array_elements(v_checks) c where c->>'severity' = 'block') where id = si.id;
  return private.si_json(si.id);
end $function$;

-- private.vat_threshold_tick: the push's recipient -> org_contact
CREATE OR REPLACE FUNCTION private.vat_threshold_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare o record; st jsonb;
begin
  for o in select id from orgs where not vat_registered and not is_sample loop
    st := private.vat_small_status(o.id);
    if (st->>'crossed')::boolean then
      perform private.notify(o.id, (private.org_contact(o.id)).user_id, 'tax',
        'Turnover has passed ₦100 million: start charging VAT',
        'Sales this year come to ' || private.naira((st->>'year_to_date')::numeric) || '. A business above the small company limit must charge VAT. Turn it on under Accounting, Tax returns, VAT.',
        '/accounting/tax?tab=vat', 'vat-threshold-' || extract(year from (st->>'year_from')::date));
    end if;
  end loop;
end $function$;

-- public.approve_payout: the owner may approve their own request -> perm_of
CREATE OR REPLACE FUNCTION public.approve_payout(p_payout uuid, p_approve boolean, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare po public.payouts; m public.members;
begin
  select * into po from payouts where id = p_payout for update;
  if not found then raise exception 'Payout not found.'; end if;
  m := private.require(po.org_id, 'approve_payments');
  if po.batch_id is not null then
    raise exception 'Approve % with its bulk payment %.', po.number, (select number from payout_batches where id = po.batch_id);
  end if;
  if po.status <> 'pending_approval' then raise exception '% is %.', po.number, replace(po.status, '_', ' '); end if;
  if po.requested_by = m.id and not private.perm_of(m, 'owner') then raise exception 'Someone other than the person who asked must approve it.'; end if;
  update payouts set status = case when p_approve then 'approved' else 'cancelled' end, approved_by = m.id, approved_at = now(),
    error = case when not p_approve then nullif(trim(p_note), '') else error end
  where id = po.id returning * into po;
  return to_jsonb(po);
end $function$;

-- public.approve_payout_batch: the owner may approve their own request -> perm_of
CREATE OR REPLACE FUNCTION public.approve_payout_batch(p_batch uuid, p_approve boolean, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare pb public.payout_batches; m public.members;
begin
  select * into pb from payout_batches where id = p_batch for update;
  if not found then raise exception 'Bulk payment not found.'; end if;
  m := private.require(pb.org_id, 'approve_payments');
  if pb.status <> 'pending_approval' then raise exception '% is %.', pb.number, replace(pb.status, '_', ' '); end if;
  if pb.requested_by = m.id and not private.perm_of(m, 'owner') then raise exception 'Someone other than the person who asked must approve it.'; end if;
  update payout_batches set approved_by = m.id, approved_at = now(), note = case when not p_approve then nullif(trim(p_note), '') else note end where id = pb.id;
  update payouts set status = case when p_approve then 'approved' else 'cancelled' end, approved_by = m.id, approved_at = now(),
    error = case when not p_approve then coalesce(nullif(trim(p_note), ''), 'Not approved') else error end
  where batch_id = pb.id and status = 'pending_approval';
  if not p_approve then perform private.void_bulk_bills(pb.id, m); end if;
  return private.batch_json(pb.id);
end $function$;

-- public.approve_tax_instruction: the caller approves a tax payment -> perm_of
CREATE OR REPLACE FUNCTION public.approve_tax_instruction(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare i public.tax_payment_instructions; m public.members; t public.tax_wallets; x public.tax_payments; v_spend numeric;
begin
  select * into i from tax_payment_instructions where id = p_id for update;
  if not found then raise exception 'Not found.'; end if;
  m := private.require(i.org_id, 'make_payments');
  if not (private.perm_of(m, 'owner') or private.perm_of(m, 'approve_payments')) then
    raise exception 'Tax payments from the tax wallet need someone who approves payments.' using errcode = '42501';
  end if;
  perform private.require_payments_open(i.org_id);
  if i.status not in ('needs_approval', 'received') then
    raise exception 'This payment is %.', case i.status when 'paying' then 'being paid already' when 'expired' then 'past its account''s expiry: ask Flux for a new account'
      when 'renewing' then 'waiting for a new account from Flux' else i.status end;
  end if;
  if i.expires_at is not null and i.expires_at < now() + interval '1 minute' then raise exception 'The account Rev360 gave has expired. Ask Flux for a new one.'; end if;
  select * into t from tax_wallets where org_id = i.org_id and status = 'active';
  if not found then raise exception 'Open the tax wallet first, or pay it by transfer from a bank and mark it paid.'; end if;
  if i.bank_code is null then raise exception 'Counta could not find the bank "%". Pay it by transfer from a bank and mark it paid.', i.bank_name; end if;
  -- The tax wallet pays only tax: never an account the bank says belongs to someone else.
  if not private.instruction_wallet_ok(i) then
    raise exception 'The tax wallet pays only tax collection accounts, and the bank shows % as %. Ask Flux for a new account, or pay it from a bank if you are sure.',
      i.account_number, coalesce(nullif(i.resolved_name, ''), 'someone else');
  end if;
  if exists (select 1 from tax_payments where org_id = i.org_id and kind = i.tax and period = i.period and authority = i.authority
             and status in ('approved', 'processing', 'successful') and instruction_id is distinct from i.id) then
    raise exception 'A payment for this return is already on its way or made.';
  end if;
  v_spend := private.tax_wallet_spendable(t.id);
  if i.amount > v_spend + 0.004 then raise exception 'The tax wallet can pay %; % is due. Top it up first.', private.naira(v_spend), private.naira(i.amount); end if;
  x := private.instruction_payment(i, m.id, false);
  return to_jsonb(x);
end $function$;

-- public.bujeti_overview: the caller sees, maps and lists accounts -> perm_of
CREATE OR REPLACE FUNCTION public.bujeti_overview(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; i public.integrations; b public.bank_accounts;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'owner') or private.perm_of(m, 'keep_books') or private.perm_of(m, 'manage_settings')) then
    raise exception 'Your role does not allow this. The owner, the bookkeeper or someone who manages settings sees Bujeti here.';
  end if;
  i := private.bujeti_conn(p_org);
  if i.id is null then return jsonb_build_object('connected', false); end if;
  b := private.bujeti_bank(p_org);
  return jsonb_build_object('connected', true,
    'can_map', private.perm_of(m, 'owner') or private.perm_of(m, 'keep_books'),
    'start', private.bujeti_start(p_org),
    'scopes', i.settings->'scopes',
    'account', case when b.id is not null then jsonb_build_object('id', b.id, 'name', b.name, 'code', b.ledger_code,
      'books', (select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code = b.ledger_code),
      'bujeti', b.anchor_balance, 'balance_at', b.provider_meta->>'balance_at', 'balances', coalesce(b.provider_meta->'bujeti_balances', '[]'::jsonb),
      'unmatched', (select count(*) from bank_lines where bank_account_id = b.id and status in ('unmatched', 'proposed'))) end,
    'counts', (select jsonb_build_object(
        'recorded', count(*) filter (where kind = 'payment' and status = 'recorded'),
        'waiting', count(*) filter (where kind = 'payment' and status = 'waiting'),
        'waiting_total', coalesce(sum(amount + coalesce(fee, 0)) filter (where kind = 'payment' and status = 'waiting'), 0),
        'pending', count(*) filter (where kind = 'payment' and status = 'pending'),
        'other_currency', count(*) filter (where kind = 'payment' and status = 'skipped' and currency <> 'NGN'),
        'invoices', count(*) filter (where kind = 'invoice' and status = 'recorded'),
        'vendors', count(*) filter (where kind = 'vendor' and status = 'recorded'),
        'receipts', coalesce(sum((data->>'receipts')::int) filter (where kind = 'payment'), 0))
      from bujeti_items where org_id = p_org),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'name', c.name, 'parent', c.parent_name, 'suggested', c.suggested_code,
        'account', c.account_code, 'confirmed_at', c.confirmed_at, 'confirmed_by', (select display_name from members where id = c.confirmed_by),
        'waiting', (select count(*) from bujeti_items it where it.org_id = p_org and it.kind = 'payment' and it.status = 'waiting' and it.category_code = c.code),
        'waiting_total', (select coalesce(sum(it.amount + coalesce(it.fee, 0)), 0) from bujeti_items it where it.org_id = p_org and it.kind = 'payment' and it.status = 'waiting' and it.category_code = c.code),
        'recorded', (select count(*) from bujeti_items it where it.org_id = p_org and it.kind = 'payment' and it.status = 'recorded' and it.category_code = c.code))
      order by (c.confirmed_at is null) desc, c.name), '[]'::jsonb) from bujeti_categories c where c.org_id = p_org),
    'accounts', case when private.perm_of(m, 'owner') or private.perm_of(m, 'keep_books') then private.bujeti_accounts(p_org) else '[]'::jsonb end);
end $function$;

-- public.cit_pack: the caller approves -> perm_of
CREATE OR REPLACE FUNCTION public.cit_pack(p_org uuid, p_year integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; cy public.cit_years; comp jsonb; o public.orgs; v_draft boolean; v_org jsonb; v_tin text;
begin
  m := private.cit_can_see(p_org);
  if p_year < 2000 or p_year > 2100 then raise exception 'Choose the year.'; end if;
  select * into cy from cit_years where org_id = p_org and accounting_year = p_year;
  select * into o from orgs where id = p_org;
  v_draft := cy.accounting_year is null or cy.status = 'draft' or cy.snapshot is null;
  if v_draft then
    comp := private.cit_run(p_org, p_year, null);
    v_org := jsonb_build_object('name', o.name, 'tin', o.tin, 'rc_number', o.rc_number, 'address', o.address, 'taxstreem_org_id', o.taxstreem_org_id);
  else
    comp := cy.snapshot->'computation';
    v_org := cy.snapshot->'org';
  end if;
  v_tin := nullif(regexp_replace(coalesce(v_org->>'tin', ''), '[^0-9A-Za-z-]', '', 'g'), '');
  return jsonb_build_object(
    'org_id', p_org, 'year', p_year, 'yoa', (comp->>'yoa')::int, 'regime', comp->>'regime', 'from', comp->>'from', 'to', comp->>'to',
    'status', coalesce(cy.status, 'draft'), 'draft', v_draft, 'org', v_org,
    'cell_map', case when v_draft then private.cit_cell_map(comp) else cy.snapshot->'cell_map' end,
    'declaration', case when v_draft then private.cit_declaration(p_org, comp) else cy.snapshot->'declaration' end,
    'figures', comp->'figures', 'rows', comp->'rows', 'checks', comp->'checks', 'due', comp->>'due',
    'file_name', p_year || '_' || coalesce(v_tin, 'NO-TIN') || '_CIT' || case when v_draft then '_DRAFT' else '' end || '.xlsx',
    'afs_path', cy.afs_path, 'template_path', case when v_draft then null else cy.template_path end,
    'approved_by', cy.snapshot->>'approved_by', 'approved_at', cy.snapshot->>'approved_at',
    'flux', jsonb_build_object('status', cy.flux_status, 'ref', cy.flux_ref, 'message', cy.flux_message, 'sent_at', cy.flux_sent_at,
      'updated_at', cy.flux_updated_at, 'acknowledgement_ref', cy.acknowledgement_ref, 'filed_at', cy.filed_at),
    'can_send', not v_draft and cy.status in ('approved', 'rejected') and cy.afs_path is not null
      and private.perm_of(m, 'keep_books') and (private.perm_of(m, 'owner') or private.perm_of(m, 'approve_adjustments')));
end $function$;

-- public.cit_year: the caller approves -> perm_of
CREATE OR REPLACE FUNCTION public.cit_year(p_org uuid, p_year integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; cy public.cit_years; comp jsonb; p record;
begin
  m := private.cit_can_see(p_org);
  if p_year < 2000 or p_year > 2100 then raise exception 'Choose the year.'; end if;
  select * into cy from cit_years where org_id = p_org and accounting_year = p_year;
  select pfrom, pto into p from private.cit_period(p_org, p_year);
  comp := private.cit_run(p_org, p_year);
  return jsonb_build_object('computation', comp,
    'row', jsonb_build_object('status', coalesce(cy.status, 'draft'), 'source', comp->>'source', 'settings', coalesce(cy.settings, '{}'::jsonb),
      'adjustments', coalesce(cy.adjustments, '{}'::jsonb), 'overrides', coalesce(cy.overrides, '{}'::jsonb), 'imported', coalesce(cy.imported, '{}'::jsonb),
      'imported_from', cy.imported_from, 'afs_path', cy.afs_path, 'template_path', cy.template_path, 'approved_at', cy.approved_at,
      'approved_by', (select display_name from members where id = cy.approved_by), 'flux_status', cy.flux_status, 'flux_ref', cy.flux_ref,
      'flux_message', cy.flux_message, 'flux_sent_at', cy.flux_sent_at, 'filed_at', cy.filed_at, 'acknowledgement_ref', cy.acknowledgement_ref,
      'rev360_computation', cy.rev360_computation, 'updated_at', cy.updated_at),
    'lines', (select jsonb_agg(jsonb_build_object('cell', l.cell, 'sheet', l.sheet, 'addr', l.addr, 'section', l.section, 'label', l.label, 'note', l.note,
        'codes', l.codes, 'positive_only', l.positive_only, 'config_id', l.config_id,
        'amount', coalesce((comp->'cells'->>l.cell)::numeric, (comp->'adjustments'->>l.cell)::numeric, 0),
        'detail', comp->'detail'->l.cell, 'items', comp->'items'->l.cell,
        'source', case when l.sheet = 'PROFIT_ADJUSTMENT' then 'adjustment' when cy.overrides ? l.cell then 'override'
                       when comp->>'source' = 'imported' then coalesce(cy.imported->l.cell->>'source', 'imported') else 'books' end,
        'imported', cy.imported->l.cell, 'override', cy.overrides->l.cell) order by l.sort) from cit_template_lines l),
    'declaration', private.cit_declaration(p_org, comp),
    'tax_assets', (select coalesce(jsonb_agg(to_jsonb(t) order by t.in_use_from, t.name), '[]'::jsonb) from tax_assets t where t.org_id = p_org),
    'can_edit', private.perm_of(m, 'keep_books') and coalesce(cy.status, 'draft') in ('draft', 'rejected'),
    'can_approve', private.perm_of(m, 'keep_books') and (private.perm_of(m, 'owner') or private.perm_of(m, 'approve_adjustments')),
    'period', jsonb_build_object('from', p.pfrom, 'to', p.pto));
end $function$;

-- public.close_books: only the owner closes the books -> perm_of
CREATE OR REPLACE FUNCTION public.close_books(p_org uuid, p_period_end date, p_policy jsonb DEFAULT '{}'::jsonb, p_overrides jsonb DEFAULT '[]'::jsonb, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; v_check jsonb; v_accrued int; v_dep jsonb; v_res jsonb;
begin
  m := private.require(p_org, null);
  if not private.perm_of(m, 'owner') then raise exception 'Only the owner closes the books.' using errcode = '42501'; end if;
  if p_period_end <> (date_trunc('month', p_period_end) + interval '1 month' - interval '1 day')::date and coalesce((p_policy->>'allow_mid_month')::boolean, false) is false then
    raise exception 'The books close at a month end.';
  end if;
  v_check := public.close_checklist(p_org, p_period_end);
  if not (v_check->>'ready')::boolean then
    raise exception 'Not ready to close: %.', (select string_agg(s->>'title', '; ') from jsonb_array_elements(v_check->'steps') s
      where (s->>'blocking')::boolean and not (s->>'ok')::boolean and not (s->>'waived')::boolean);
  end if;
  v_accrued := private.accrue_bills(p_org, p_period_end, m);
  if exists (select 1 from fixed_assets where org_id = p_org and status = 'active') then v_dep := private.depreciate(p_org, p_period_end, m); end if;
  v_res := public.close_period(p_org, p_period_end, p_policy, p_overrides, p_note);
  return v_res || jsonb_build_object('accrued_bills', v_accrued, 'depreciation', v_dep, 'checklist', v_check);
end $function$;

-- public.close_year: only the owner closes the year -> perm_of
CREATE OR REPLACE FUNCTION public.close_year(p_org uuid, p_year_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; v_jl jsonb; j public.journals; v_profit numeric; v_tz text;
begin
  m := private.require(p_org, null);
  if not private.perm_of(m, 'owner') then raise exception 'Only the owner closes the year.' using errcode = '42501'; end if;
  if p_year_end <> (private.fy_start(p_org, p_year_end) + interval '1 year' - interval '1 day')::date then raise exception 'That is not the last day of a financial year.'; end if;
  if coalesce(private.closed_through(p_org), '1900-01-01') < p_year_end then raise exception 'Close every month of the year first.'; end if;
  if exists (select 1 from journals where org_id = p_org and source_type = 'year_end' and entry_date = p_year_end) then raise exception 'This year is already closed.'; end if;
  select timezone into v_tz from orgs where id = p_org;
  select jsonb_agg(jsonb_build_object('code', b.code, 'debit', greatest(-b.bal, 0), 'credit', greatest(b.bal, 0), 'memo', 'Closed to retained earnings')), coalesce(-sum(b.bal), 0)
  into v_jl, v_profit
  from private.balances_at(p_org, p_year_end) b join private.acct_meta(p_org) a on a.code = b.code where a.statement = 'pl' and b.bal <> 0;
  if v_jl is null then raise exception 'There is nothing to close.'; end if;
  v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'retained_earnings'), 'debit', greatest(-v_profit, 0), 'credit', greatest(v_profit, 0),
    'memo', 'Profit for the year'));
  perform set_config('app.period_close', 'on', true);
  j := private.post_entry(p_org, 'Year end ' || to_char(p_year_end, 'YYYY') || ' · profit to retained earnings', 'year_end', null, m.id, m.id, v_jl,
    ((p_year_end + 1)::timestamp at time zone coalesce(v_tz, 'Africa/Lagos')) - interval '1 second');
  perform set_config('app.period_close', '', true);
  return jsonb_build_object('journal_ref', j.ref, 'profit', v_profit);
end $function$;

-- public.compliance_score: the caller sees the score -> perm_of
CREATE OR REPLACE FUNCTION public.compliance_score(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; v_items jsonb;
begin
  m := private.require(p_org, null);
  if not private.perm_of(m, 'owner') and not private.perm_of(m, 'keep_books') then raise exception 'Only the owner and the bookkeepers see the compliance score.' using errcode = '42501'; end if;
  v_items := private.compliance_items(p_org);
  return jsonb_build_object('score', (select count(*) from jsonb_array_elements(v_items) i where (i->>'ok')::boolean),
    'total', jsonb_array_length(v_items), 'items', v_items,
    'next', (select i from jsonb_array_elements(v_items) i where not (i->>'ok')::boolean and i->>'action' is not null limit 1));
end $function$;

-- public.document_delete: the caller removes another's upload -> perm_of
CREATE OR REPLACE FUNCTION public.document_delete(p_org uuid, p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; d public.documents;
begin
  m := private.require(p_org, null);
  select * into d from documents where id = p_id and org_id = p_org;
  if not found then raise exception 'That document is not in this business.'; end if;
  if d.source <> 'upload' then raise exception 'Only uploaded files can be taken out. Counta keeps the rest with what they belong to.'; end if;
  if d.uploaded_by is distinct from m.id and not private.perm_of(m, 'owner') then raise exception 'Only the person who uploaded it, or the owner, takes it out.' using errcode = '42501'; end if;
  delete from documents where id = d.id;
  return jsonb_build_object('ok', true, 'path', d.path);
end $function$;

-- public.filing_version: can_withdraw -> perm_of
CREATE OR REPLACE FUNCTION public.filing_version(p_version uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare v public.filing_versions; m public.members; pm public.practice_members; v_can boolean; v_check jsonb;
begin
  select * into v from filing_versions where id = p_version;
  if not found then raise exception 'That version was not found.'; end if;
  m := private.require(v.org_id, null);
  if not (private.perm_of(m, private.filing_perm(v.kind)) or private.can_handle_money(v.org_id)) then
    raise exception 'Your role does not see tax returns.' using errcode = '42501';
  end if;
  v_can := m.role = 'accountant' and private.perm_of(m, private.filing_perm(v.kind)) and private.perm_of(m, 'keep_books') and v.status = 'review';
  select * into pm from practice_members where practice_id = m.practice_id and user_id = auth.uid();
  if v_can then v_check := private.filing_lines_check(v, v.proposal); end if;
  return private.filing_version_brief(v) || jsonb_build_object('org_id', v.org_id, 'figures', v.figures, 'changes', v.changes, 'checks', v.checks, 'proposal', v.proposal,
    'proposal_check', v_check, 'note', v.note, 'file_path', v.file_path, 'sha256', v.sha256, 'no_journal_reason', v.no_journal_reason,
    'locked', private.filing_locked(v.org_id, v.kind, v.period, v.authority),
    'base', case when v.base_version is not null then (select jsonb_build_object('id', b.id, 'version', b.version, 'accepted_name', b.accepted_name) from filing_versions b where b.id = v.base_version) end,
    'can_apply', v_can,
    'can_withdraw', v.status in ('review', 'in_use') and (private.perm_of(m, 'owner') or (m.role = 'accountant' and private.perm_of(m, private.filing_perm(v.kind)))),
    'statement_preview', case when v_can then private.filing_statement(v, m.display_name, case when pm.id is not null then private.licence_text(pm) end,
      (select name from practices where id = m.practice_id), 'JE-…', null) end,
    'accounts', case when v_can then (select coalesce(jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name, 'line', a.ifrs_line, 'statement', a.statement) order by a.code), '[]'::jsonb)
      from private.acct_meta(v.org_id) a where private.postable(v.org_id, a.code) and split_part(a.code, '-', 1) not in ('1101', '1102', '2101', '2102')) end);
end $function$;

-- public.filing_version_withdraw: the caller withdraws -> perm_of; the owner's side withdrew: tell the practice -> perm_of; the accountant's side withdrew: tell the owner -> perm_of
CREATE OR REPLACE FUNCTION public.filing_version_withdraw(p_version uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare v public.filing_versions; m public.members; r public.journals; v_lock text;
begin
  select * into v from filing_versions where id = p_version for update;
  if not found then raise exception 'That version was not found.'; end if;
  m := private.require(v.org_id, null);
  if not (private.perm_of(m, 'owner') or (m.role = 'accountant' and private.perm_of(m, private.filing_perm(v.kind)))) then
    raise exception 'The owner or an accountant of the business withdraws a changed version.' using errcode = '42501';
  end if;
  if v.status not in ('review', 'in_use') then raise exception 'This version is no longer in use.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then raise exception 'Say why it is withdrawn.'; end if;
  if v.status = 'in_use' then
    v_lock := private.filing_locked(v.org_id, v.kind, v.period, v.authority);
    if v_lock is not null then raise exception 'The % is already %: the version filed stays.', private.filing_label(v.kind, v.period, v.authority), v_lock; end if;
    if v.journal_id is not null then r := private.reverse_entry(v.journal_id, m.id, 'Accountant''s version withdrawn: ' || left(trim(p_reason), 200)); end if;
  end if;
  update filing_versions set status = 'withdrawn', withdrawn_by = auth.uid(), withdrawn_at = now(), withdrawn_reason = left(trim(p_reason), 300), reversal_journal_id = r.id
  where id = v.id returning * into v;
  if private.perm_of(m, 'owner') and v.practice_id is not null then
    perform private.practice_notify(v.practice_id, (select name from orgs where id = v.org_id) || ' withdrew your ' || private.filing_label(v.kind, v.period, v.authority),
      left(trim(p_reason), 200), '/practice');
  elsif not private.perm_of(m, 'owner') and v.accepted_at is not null then
    perform private.notify_perm(v.org_id, 'owner', 'practice', 'Counta''s own ' || private.filing_label(v.kind, v.period, v.authority) || ' is back in use',
      m.display_name || ' withdrew their version: ' || left(trim(p_reason), 160), case when v.kind = 'fs' then '/accounting/statements' else '/tax/' || v.kind end, null);
  end if;
  return private.filing_version_brief(v);
end $function$;

-- public.get_alert_prefs: can_change -> perm_of; the contact shown as who gets alerts -> org_contact
CREATE OR REPLACE FUNCTION public.get_alert_prefs(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members;
begin
  m := private.require(p_org, null);
  return private.alert_prefs(p_org) || jsonb_build_object('can_change', private.perm_of(m, 'owner') or private.perm_of(m, 'manage_settings'),
    'owner', (select jsonb_build_object('name', display_name, 'phone', phone, 'email', email) from private.org_contact(p_org) where id is not null),
    'calls', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'status', c.status, 'summary', c.summary, 'outcome', c.outcome,
        'created_at', c.created_at, 'to', (select name from customers where id = c.customer_id), 'sale', (select number from sales where id = c.sale_id))
        order by c.created_at desc), '[]'::jsonb)
      from (select * from voice_calls where org_id = p_org and kind in ('tax_deadline', 'customer_followup') order by created_at desc limit 30) c),
    -- Who gets WhatsApp alerts here: the people who linked WhatsApp to Martina. Names only; the person's own number, masked.
    'whatsapp_people', (select coalesce(jsonb_agg(x.name order by x.name), '[]'::jsonb) from (
        select distinct coalesce(nullif(trim(mm.display_name), ''), 'A team member') as name from members mm
        where mm.org_id = p_org and mm.status = 'active' and mm.user_id is not null
          and exists (select 1 from chat_links l where l.user_id = mm.user_id and l.channel = 'whatsapp' and l.status = 'active')) x),
    'my_whatsapp', (select '+' || left(w.phone, 3) || ' ••• ••• ' || right(w.phone, 4) from private.wa_number(auth.uid(), p_org) w));
end $function$;

-- public.get_attention: tax_id count -> perm_of; accountant_requests count -> perm_of
CREATE OR REPLACE FUNCTION public.get_attention(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; o public.orgs; v_today date; v_books boolean; v_pay boolean; v_sales boolean; v_tax boolean; v_vat int := 0; v_wht int := 0; v_cit int := 0;
  r record;
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  v_today := private.local_day(p_org, now());
  v_books := private.perm_of(m, 'keep_books');
  v_pay := private.perm_of(m, 'make_payments');
  v_sales := private.perm_of(m, 'record_sales') or v_books;
  v_tax := v_books or private.perm_of(m, 'file_tax');
  if v_tax then
    for r in select * from private.tax_deadlines(p_org) where due <= v_today + 7 loop
      if r.tax = 'vat' then v_vat := v_vat + 1; elsif r.tax in ('cit', 'pit') then v_cit := v_cit + 1; else v_wht := v_wht + 1; end if;
    end loop;
    v_cit := case when exists (select 1 from private.tax_deadlines(p_org) t where t.tax in ('cit', 'pit') and t.due <= v_today + 30) then 1 else 0 end;
  end if;
  return jsonb_build_object(
    'invoices_overdue', case when v_sales then (select count(*) from sales where org_id = p_org and doc_type = 'invoice' and status in ('open', 'partially_paid')
      and journal_id is not null and due_date < v_today) else 0 end,
    'orders_to_confirm', case when v_sales then (select count(*) from sales where org_id = p_org and doc_type = 'order' and status = 'pending') else 0 end,
    'payments_to_confirm', case when v_books or private.perm_of(m, 'approve_adjustments') then (select count(*) from collections where org_id = p_org and status = 'pending') else 0 end,
    'bills_overdue', case when v_books or v_pay then (select count(*) from bills where org_id = p_org and status in ('approved', 'partially_paid') and due_date < v_today) else 0 end,
    'bank_lines', case when v_books then (select count(*) from bank_lines where org_id = p_org and status = 'unmatched') else 0 end,
    'proposals', case when v_books then (select count(*) from ai_proposals where org_id = p_org and status = 'pending') else 0 end,
    'schedules_draft', case when v_tax then (select count(*) from sales_schedules where org_id = p_org and status = 'draft') else 0 end,
    'vat', v_vat, 'wht', v_wht, 'cit', v_cit,
    'tax_wallet', case when v_pay or v_books then
      (case when exists (select 1 from wallets where org_id = p_org and status = 'active') and not exists (select 1 from tax_wallets where org_id = p_org and status = 'active') then 1 else 0 end)
      + (select count(*) from tax_payments where org_id = p_org and status = 'failed' and created_at > now() - interval '7 days')
      + (select count(*) from tax_payment_instructions where org_id = p_org
         and (status in ('needs_approval', 'expired') or (status = 'confirmed' and journal_id is null and payment_id is null))) else 0 end,
    'tax_id', case when private.perm_of(m, 'owner') or private.perm_of(m, 'manage_settings') then
      case when coalesce(o.tin, '') = '' or coalesce(o.tin_status, '') not in ('verified', 'confirmed') then 1 else 0 end else 0 end,
    'accountant_requests', case when m.practice_id is null and (m.role in ('owner', 'admin') or m.acts_as_owner) then
      (select count(*) from practice_requests pr join practice_clients pc on pc.id = pr.client_id
       where pr.org_id = p_org and pr.status = 'open' and pc.status = 'active') else 0 end,
    -- Payments taken as sales whose VAT a person should check: once the AI has looked (or could not), not while it is about to.
    'receipts_vat', case when v_tax then (select count(*) from sales where org_id = p_org and channel = 'bank' and doc_type = 'receipt' and status <> 'void'
      and vat_check and (vat_ai_at is not null or vat_ai_tries >= 3 or vat_source is distinct from 'usual' or created_at < now() - interval '1 day')) else 0 end);
end $function$;

-- public.get_flux_tax: can approve -> perm_of; can change autopay -> perm_of
CREATE OR REPLACE FUNCTION public.get_flux_tax(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; o public.orgs; t public.tax_wallets;
begin
  m := private.require(p_org, null);
  if not (private.can_handle_money(p_org) or private.perm_of(m, 'file_tax')) then
    raise exception 'Tax payments need See margins, Keep the books, Make payments or File tax.' using errcode = '42501';
  end if;
  select * into o from orgs where id = p_org;
  select * into t from tax_wallets where org_id = p_org and status = 'active';
  return jsonb_build_object(
    'instructions', coalesce((select jsonb_agg(to_jsonb(i) || jsonb_build_object('label', private.tax_label(i.tax), 'when', private.tax_when(i.tax, i.period, i.accounting_year),
        'payment_status', p.status, 'payment_error', p.error, 'journal_ref', j.ref, 'expired', i.expires_at is not null and i.expires_at < now(),
        'wallet_ok', private.instruction_wallet_ok(i),
        -- Waiting ones are compared again now (a month filed or paid since changes it); the rest show what was compared.
        'reconciliation', case when i.breakdown is null then null
          when i.status in ('received', 'needs_approval', 'expired', 'renewing') then private.instruction_reconcile(i) else coalesce(i.reconciliation, private.instruction_reconcile(i)) end)
        order by case when i.status in ('needs_approval', 'expired', 'received', 'renewing', 'paying') then 0 else 1 end, i.received_at desc)
      from tax_payment_instructions i left join tax_payments p on p.id = i.payment_id left join journals j on j.id = i.journal_id
      where i.org_id = p_org and i.status not in ('replaced', 'cancelled')
        and (i.status in ('received', 'needs_approval', 'expired', 'renewing', 'paying') or i.received_at > now() - interval '120 days')), '[]'::jsonb),
    'returns', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object('label', private.tax_label(r.tax), 'sent_by_name', mm.display_name) order by r.period desc, r.tax)
      from flux_returns r left join members mm on mm.id = r.sent_by where r.org_id = p_org), '[]'::jsonb),
    'autopay', o.tax_autopay, 'autopay_penalties', o.tax_autopay_penalties,
    'tax_wallet', case when t.id is not null then jsonb_build_object('spendable', private.tax_wallet_spendable(t.id), 'account_number', t.account_number, 'bank_name', t.bank_name) end,
    'can', jsonb_build_object(
      'approve', private.perm_of(m, 'owner') or (private.perm_of(m, 'make_payments') and private.perm_of(m, 'approve_payments')),
      'record', private.perm_of(m, 'make_payments') or private.perm_of(m, 'keep_books'),
      'renew', private.perm_of(m, 'make_payments') or private.perm_of(m, 'file_tax'),
      'send', private.perm_of(m, 'file_tax'),
      'autopay', private.perm_of(m, 'owner') or private.perm_of(m, 'manage_settings')));
end $function$;

-- public.get_payments: can change settings -> perm_of
CREATE OR REPLACE FUNCTION public.get_payments(p_org uuid, p_filter jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; o public.orgs; w public.wallets; v_money boolean; v_from date := nullif(p_filter->>'from', '')::date;
  v_to date := nullif(p_filter->>'to', '')::date; v_lo timestamptz; v_hi timestamptz;
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  v_lo := case when v_from is not null then (v_from::timestamp) at time zone coalesce(o.timezone, 'Africa/Lagos') end;
  v_hi := case when v_to is not null then ((v_to + 1)::timestamp) at time zone coalesce(o.timezone, 'Africa/Lagos') end;
  select * into w from wallets where org_id = p_org and rail = o.payment_rail;
  v_money := private.can_handle_money(p_org);
  return jsonb_build_object(
    'rail', (select to_jsonb(r) - 'api_key_secret' - 'webhook_secret' from payment_rails r where r.code = o.payment_rail),
    'rails', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'capabilities', capabilities) order by code = 'flutterwave' desc, name), '[]'::jsonb)
              from payment_rails where active),
    'wallet', case when w.id is not null then to_jsonb(w) - 'provider_available' - 'provider_ledger' || jsonb_build_object(
        'books_balance', case when v_money then private.wallet_balance(w.id) end,
        'provider_balance', case when v_money then coalesce(w.provider_ledger, w.provider_available) end,
        'available', case when v_money then private.wallet_balance(w.id) - coalesce((select sum(amount + fee) from payouts where wallet_id = w.id
           and status in ('approved', 'processing', 'pending_approval')), 0) end) end,
    'settings', jsonb_build_object('payment_methods', o.payment_methods, 'payout_approval_threshold', o.payout_approval_threshold),
    'requests', (select coalesce(jsonb_agg(private.request_json(r) || jsonb_build_object('created_at', r.created_at, 'customer_name', c.name,
        'created_by_name', (select display_name from members where id = r.created_by), 'sweep_status', case when v_money then r.sweep_status end,
        'fee', case when v_money then r.fee end) order by r.created_at desc), '[]'::jsonb)
      from (select * from payment_requests where org_id = p_org
              and created_at >= coalesce(v_lo, case when v_hi is null then now() - interval '60 days' end, '-infinity') and created_at < coalesce(v_hi, 'infinity')
            order by created_at desc limit case when v_lo is null and v_hi is null then 300 else 2000 end) r
      left join customers c on c.id = r.customer_id),
    'payouts', case when v_money then (select coalesce(jsonb_agg(to_jsonb(p) - 'raw' - 'lines' || jsonb_build_object(
        'requested_by_name', (select display_name from members where id = p.requested_by), 'approved_by_name', (select display_name from members where id = p.approved_by),
        'journal_ref', (select ref from journals where id = p.journal_id)) order by p.created_at desc), '[]'::jsonb)
      from (select * from payouts where org_id = p_org and batch_id is null and created_at >= coalesce(v_lo, '-infinity') and created_at < coalesce(v_hi, 'infinity')
            order by created_at desc limit case when v_lo is null and v_hi is null then 300 else 2000 end) p) end,
    'batches', case when v_money then (select coalesce(jsonb_agg(private.batch_json(b.id, false) order by b.created_at desc), '[]'::jsonb)
      from (select id, created_at from payout_batches where org_id = p_org and created_at >= coalesce(v_lo, '-infinity') and created_at < coalesce(v_hi, 'infinity')
            order by created_at desc limit case when v_lo is null and v_hi is null then 100 else 500 end) b) end,
    'reconciliations', case when v_money then (select coalesce(jsonb_agg(to_jsonb(x) order by x.at desc), '[]'::jsonb)
      from (select * from wallet_reconciliations where org_id = p_org order by at desc limit 30) x) end,
    'can', jsonb_build_object('pay_out', private.perm_of(m, 'make_payments'), 'open_wallet', private.perm_of(m, 'keep_books') or private.perm_of(m, 'make_payments'),
      'settings', private.perm_of(m, 'owner')),
    'me', m.id, 'period', case when v_from is not null or v_to is not null then jsonb_build_object('from', v_from, 'to', v_to) end);
end $function$;

-- public.get_payout_batch: can approve -> perm_of
CREATE OR REPLACE FUNCTION public.get_payout_batch(p_batch uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare pb public.payout_batches; m public.members;
begin
  select * into pb from payout_batches where id = p_batch;
  if not found then raise exception 'Bulk payment not found.'; end if;
  m := private.require(pb.org_id, null);
  if not private.can_handle_money(pb.org_id) then raise exception 'Your role does not see payments.' using errcode = '42501'; end if;
  return private.batch_json(pb.id) || jsonb_build_object('can', jsonb_build_object('pay_out', private.perm_of(m, 'make_payments'),
    'approve', private.perm_of(m, 'make_payments') and (pb.requested_by is distinct from m.id or private.perm_of(m, 'owner'))));
end $function$;

-- public.get_tax_wallet: can open -> perm_of; can pay -> perm_of
CREATE OR REPLACE FUNCTION public.get_tax_wallet(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; t public.tax_wallets; w public.wallets; o public.orgs; v_vat numeric; v_wht numeric;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'The tax wallet needs See margins, Keep the books or Make payments.' using errcode = '42501'; end if;
  select * into o from orgs where id = p_org;
  select * into t from tax_wallets where org_id = p_org;
  select * into w from wallets where org_id = p_org and rail = o.payment_rail and status = 'active';
  -- Tax owed in the books: output VAT less input VAT (and VAT customers withheld), and WHT and withholding VAT not yet paid over.
  v_vat := greatest(-(select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and (account_code = private.acct(p_org, 'output_vat')
            or account_code = private.acct(p_org, 'input_vat') or account_code = private.acct(p_org, 'vat_withheld_by_customers'))), 0);
  v_wht := greatest(-(select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and (account_code = private.acct(p_org, 'wht_payable')
            or account_code = private.acct(p_org, 'wvat_payable'))), 0);
  return jsonb_build_object(
    'tax_wallet', case when t.id is not null then to_jsonb(t) - 'provider_available' - 'provider_ledger' || jsonb_build_object(
      'books_balance', private.tax_wallet_ledger(t.id), 'spendable', private.tax_wallet_spendable(t.id), 'provider_balance', coalesce(t.provider_ledger, t.provider_available)) end,
    'business_wallet', case when w.id is not null then jsonb_build_object('id', w.id, 'account_number', w.account_number, 'bank_name', w.bank_name) end,
    'owed', jsonb_build_object('vat', round(v_vat, 2), 'wht', round(v_wht, 2), 'total', round(v_vat + v_wht, 2)),
    'reserve', case when t.id is not null then private.vault_reserve(p_org) end,
    'waiting', (select coalesce(sum(amount), 0) from tax_moves where org_id = p_org and direction = 'in' and status in ('pending', 'sending')),
    'set_aside', jsonb_build_object(
      'vat', (select coalesce(sum(amount), 0) from tax_moves where org_id = p_org and kind = 'vat' and status = 'done'),
      'wht', (select coalesce(sum(amount), 0) from tax_moves where org_id = p_org and kind = 'wht' and status = 'done'),
      'released', (select coalesce(sum(amount), 0) from tax_moves where org_id = p_org and kind = 'release' and status = 'done')),
    'moves', (select coalesce(jsonb_agg(jsonb_build_object('id', mv.id, 'kind', mv.kind, 'direction', mv.direction, 'amount', mv.amount, 'period', mv.period,
        'description', mv.description, 'status', mv.status, 'created_at', mv.created_at, 'done_at', mv.done_at,
        'error', case when mv.status in ('pending', 'sending') then tr.error end) order by mv.created_at desc), '[]'::jsonb)
      from (select * from tax_moves where org_id = p_org order by created_at desc limit 200) mv left join tax_transfers tr on tr.id = mv.transfer_id),
    'payments', (select coalesce(jsonb_agg(to_jsonb(x) || jsonb_build_object('requested_by_name', (select display_name from members where id = x.requested_by),
        'journal_ref', (select ref from journals where id = x.journal_id)) order by x.created_at desc), '[]'::jsonb)
      from (select * from tax_payments where org_id = p_org order by created_at desc limit 100) x),
    'payees', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'kinds', kinds, 'authority', authority, 'bank_name', bank_name,
        'account_number', account_number, 'account_name', account_name, 'note', note) order by name), '[]'::jsonb) from tax_payees where active),
    'due', jsonb_build_object(
      'vat', (select coalesce(jsonb_agg(jsonb_build_object('period', period, 'payable', payable) order by period), '[]'::jsonb)
              from vat_periods where org_id = p_org and status = 'filed' and payable > 0),
      'wht', (select coalesce(jsonb_agg(jsonb_build_object('period', period, 'authority', authority, 'kind', kind, 'amount', amt) order by period, authority), '[]'::jsonb)
              from (select period, authority, kind, sum(amount) amt from wht_deductions where org_id = p_org and status = 'deducted' and kind in ('wht', 'wvat')
                    group by period, authority, kind) z)),
    'can', jsonb_build_object('open', private.perm_of(m, 'owner') or private.perm_of(m, 'keep_books') or private.perm_of(m, 'make_payments'),
      'pay', private.perm_of(m, 'make_payments') and (private.perm_of(m, 'owner') or private.perm_of(m, 'approve_payments'))));
end $function$;

-- public.get_team: is_owner -> perm_of; my_perms -> perm_of
CREATE OR REPLACE FUNCTION public.get_team(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; v_all boolean;
begin
  m := private.require(p_org, null);
  v_all := private.perm_of(m, 'manage_team');
  return jsonb_build_object(
    'can_manage', v_all,
    'is_owner', private.perm_of(m, 'owner'),
    'me', m.id,
    'my_perms', case when private.perm_of(m, 'owner') then private.role_template('owner') else private.member_perms(m) end,
    'roles', (select jsonb_agg(jsonb_build_object('role', r, 'label', private.role_label(r), 'perms', private.role_perms(p_org, r),
        'standard', private.role_template(r), 'changed', exists (select 1 from role_permissions rp where rp.org_id = p_org and rp.role = r),
        'people', (select count(*) from members mb where mb.org_id = p_org and mb.role = r and mb.status <> 'disabled'))
      order by array_position(array['admin', 'manager', 'accountant', 'staff', 'cashier'], r))
      from unnest(array['admin', 'manager', 'accountant', 'staff', 'cashier']) r),
    'members', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', mb.id, 'display_name', mb.display_name, 'email', mb.email, 'phone', mb.phone, 'role', mb.role, 'role_label', private.role_label(mb.role),
        'title', mb.title, 'location_id', mb.location_id, 'status', mb.status, 'has_login', mb.user_id is not null, 'is_me', mb.id = m.id,
        'perms', case when mb.role = 'owner' then private.role_template('owner') else private.member_perms(mb) end,
        'overrides', private.clean_perms(mb.perm_overrides),
        'invite', (select jsonb_build_object('sent_at', i.sent_at, 'expires_at', i.expires_at, 'sent_count', i.sent_count,
            'expired', i.expires_at < now()) from member_invites i where i.member_id = mb.id))
      order by (mb.role = 'owner') desc, mb.status = 'disabled', mb.created_at), '[]'::jsonb)
      from members mb where mb.org_id = p_org and (v_all or mb.id = m.id))
  );
end $function$;

-- public.guide_language: the caller sets the business's voice language -> perm_of (written out: an acting seat counts only while
-- active, as require() would have it; the place is found here without require)
CREATE OR REPLACE FUNCTION public.guide_language(p_lang text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare v_uid uuid := auth.uid(); g public.guide_progress;
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if p_lang not in ('en', 'pcm') then raise exception 'Choose English or Pidgin.'; end if;
  insert into guide_progress (user_id) values (v_uid) on conflict do nothing;
  update guide_progress set language = p_lang, last_seen_at = now() where user_id = v_uid returning * into g;
  if g.org_id is not null and exists (select 1 from members where org_id = g.org_id and user_id = v_uid and (role in ('owner', 'manager') or (acts_as_owner and status = 'active'))) then
    update orgs set voice_lang = p_lang where id = g.org_id;
  end if;
  return public.guide_state(null);
end $function$;

-- public.guide_state: the caller's own latest business -> perm_of; the caller's guide language becomes the business's -> perm_of; is_owner -> perm_of
-- (written out: an acting seat counts only while active, as require() would have it; the places are found here without require)
CREATE OR REPLACE FUNCTION public.guide_state(p_org uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare v_uid uuid := auth.uid(); g public.guide_progress; v_org uuid; o public.orgs; v_steps jsonb; v_done int; v_next text; v_name text;
begin
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  insert into guide_progress (user_id) values (v_uid) on conflict do nothing;
  if p_org is not null then
    perform private.require(p_org, null);
    v_org := p_org;
  else
    select m.org_id into v_org from members m join orgs x on x.id = m.org_id
    where m.user_id = v_uid and (m.role = 'owner' or (m.acts_as_owner and m.status = 'active')) and not coalesce(x.is_sample, false)
    order by x.created_at desc limit 1;
  end if;
  select * into g from guide_progress where user_id = v_uid;
  -- A business they have just set up speaks the language they chose for the guide, until they choose otherwise.
  if v_org is not null and g.org_id is distinct from v_org and g.language <> 'en' then
    update orgs set voice_lang = g.language where id = v_org and voice_id is null and voice_lang = 'en'
      and exists (select 1 from members where org_id = v_org and user_id = v_uid and (role = 'owner' or (acts_as_owner and status = 'active')));
  end if;
  update guide_progress set org_id = coalesce(v_org, org_id), last_seen_at = now() where user_id = v_uid returning * into g;
  if g.org_id is not null and not exists (select 1 from members where org_id = g.org_id and user_id = v_uid) then
    update guide_progress set org_id = null where user_id = v_uid returning * into g;
  end if;
  select * into o from orgs where id = g.org_id;
  v_steps := private.guide_steps(v_uid, g.org_id, g.marks);
  select count(*) filter (where (s->>'done')::boolean or (s->>'skipped')::boolean) into v_done from jsonb_array_elements(v_steps) s;
  select s->>'id' into v_next from jsonb_array_elements(v_steps) with ordinality t(s, ord)
  where not (s->>'done')::boolean and not (s->>'skipped')::boolean order by ord limit 1;
  if v_done = jsonb_array_length(v_steps) and g.completed_at is null then
    update guide_progress set completed_at = now() where user_id = v_uid returning * into g;
  end if;
  select coalesce(nullif(trim(raw_user_meta_data->>'full_name'), ''), nullif(trim(raw_user_meta_data->>'name'), '')) into v_name
  from auth.users where id = v_uid;
  if v_name is null and o.id is not null then select display_name into v_name from members where org_id = o.id and user_id = v_uid; end if;
  return jsonb_build_object(
    'steps', v_steps, 'done', v_done, 'total', jsonb_array_length(v_steps), 'next', v_next,
    'completed', g.completed_at is not null, 'dismissed', g.dismissed_at is not null,
    'org', case when o.id is null then null else jsonb_build_object('id', o.id, 'name', o.name, 'industry', o.industry, 'created_at', o.created_at,
      'voice_id', o.voice_id, 'voice_lang', o.voice_lang, 'is_owner', exists (select 1 from members where org_id = o.id and user_id = v_uid and (role = 'owner' or (acts_as_owner and status = 'active')))) end,
    'first_name', coalesce(split_part(v_name, ' ', 1), ''),
    'language', g.language, 'marks', g.marks,
    'call', jsonb_build_object('consent', g.call_consent, 'phone', g.call_phone, 'status', g.followup_status));
end $function$;

-- public.identity_slip: only the owner adds the NIN slip -> perm_of
CREATE OR REPLACE FUNCTION public.identity_slip(p_org uuid, p_path text, p_file_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not private.perm_of(m, 'owner') then raise exception 'Only the owner adds the NIN slip.' using errcode = '42501'; end if;
  if coalesce(p_path, '') !~ ('^' || p_org::text || '/kyc/nin-slip-[A-Za-z0-9._-]{1,120}$') then raise exception 'Upload the NIN slip again.'; end if;
  if (select identity_status from orgs where id = p_org) in ('verified', 'approved', 'not_required') then
    raise exception 'The business''s identity is already confirmed.';
  end if;
  update orgs set identity = identity || jsonb_build_object('slip', jsonb_build_object('path', p_path, 'file_name', left(coalesce(p_file_name, 'NIN slip'), 120),
    'at', now(), 'read', false)) where id = p_org;
  return public.identity_state(p_org);
end $function$;

-- public.identity_state: the caller's identity view -> perm_of
CREATE OR REPLACE FUNCTION public.identity_state(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members;
begin
  m := private.require(p_org, null);
  return private.identity_json(p_org, private.perm_of(m, 'owner'));
end $function$;

-- public.invite_member: only the owner makes an admin -> perm_of
CREATE OR REPLACE FUNCTION public.invite_member(p_org uuid, p_name text, p_email text, p_role text, p_title text DEFAULT NULL::text, p_location uuid DEFAULT NULL::uuid, p_phone text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; p jsonb; v_id uuid; v_email text := nullif(lower(trim(coalesce(p_email, ''))), '');
begin
  m := private.require(p_org, 'manage_team');
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter the person''s name.'; end if;
  if p_role not in ('admin', 'manager', 'staff', 'cashier', 'accountant') then raise exception 'Choose a role.'; end if;
  if p_role = 'admin' and not private.perm_of(m, 'owner') then raise exception 'Only the owner makes someone an admin.' using errcode = '42501'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email address does not look right.'; end if;
  if v_email is not null and exists (select 1 from members where org_id = p_org and lower(email) = v_email) then
    raise exception '% is already on your team.', v_email;
  end if;
  if p_location is not null and not exists (select 1 from locations where id = p_location and org_id = p_org) then raise exception 'Unknown branch.'; end if;
  -- The role's permissions as this business has set them, which the person inviting must hold themselves.
  p := private.role_perms(p_org, p_role);
  perform private.check_grantable(m, p);
  insert into members (org_id, user_id, email, display_name, phone, role, title, location_id, status,
    p_record_sales, p_receive_stock, p_count_stock, p_approve_adjustments, p_edit_prices, p_approve_pos, p_transfer_stock, p_see_margins,
    p_issue_stock, p_keep_books, p_make_payments, p_add_items, p_approve_payments, p_file_tax, p_manage_team, p_manage_settings)
  values (p_org, null, v_email, trim(p_name), nullif(trim(p_phone), ''), p_role, coalesce(nullif(trim(p_title), ''), private.role_label(p_role)), p_location,
    case when v_email is null then 'active' else 'invited' end,
    (p->>'record_sales')::boolean, (p->>'receive_stock')::boolean, (p->>'count_stock')::boolean, (p->>'approve_adjustments')::boolean,
    (p->>'edit_prices')::boolean, (p->>'approve_pos')::boolean, (p->>'transfer_stock')::boolean, (p->>'see_margins')::boolean,
    (p->>'issue_stock')::boolean, (p->>'keep_books')::boolean, (p->>'make_payments')::boolean, (p->>'add_items')::boolean,
    (p->>'approve_payments')::boolean, (p->>'file_tax')::boolean, (p->>'manage_team')::boolean, (p->>'manage_settings')::boolean)
  returning id into v_id;
  -- Someone with an email gets the invitation by email; someone without one is on the team without a login.
  if v_email is not null then perform private.queue_invite(v_id, m); end if;
  return v_id;
end $function$;

-- public.leak_radar: can_see_people -> perm_of
CREATE OR REPLACE FUNCTION public.leak_radar(p_org uuid, p_days integer DEFAULT 90)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; v_tz text; v_from timestamptz; v_today date; v_days int; v_out jsonb; v_owner boolean;
begin
  m := private.require(p_org, 'see_margins');
  v_owner := private.perm_of(m, 'owner');
  v_days := least(greatest(coalesce(p_days, 90), 14), 365);
  select timezone into v_tz from orgs where id = p_org;
  v_today := (now() at time zone v_tz)::date;
  v_from := now() - make_interval(days => v_days);
  with adj as (
    select mv.* from movements mv
    where mv.org_id = p_org and mv.recorded_at >= v_from and mv.type in ('adjustment', 'write_off', 'quarantine')),
  tot as (
    select
      coalesce(sum(-value) filter (where type = 'adjustment' and qty < 0 and coalesce(reason, '') not in ('Breakage', 'Expired')), 0) unexplained,
      coalesce(sum(value) filter (where type = 'adjustment' and qty > 0), 0) gained,
      coalesce(sum(-value) filter (where (type = 'adjustment' and qty < 0 and reason in ('Breakage', 'Expired')) or type in ('write_off', 'quarantine')), 0) damage
    from adj),
  sales as (
    select coalesce(sum(-value), 0) cogs, coalesce(sum(-qty * coalesce(unit_price, 0)), 0) rev
    from movements where org_id = p_org and recorded_at >= v_from and type in ('sale', 'voice_sale')),
  ira as (
    select cs.location_id, count(*) n, count(*) filter (where abs(cl.counted - cl.expected) <= cl.expected * 0.02) ok
    from count_lines cl join count_sessions cs on cs.id = cl.session_id
    where cs.org_id = p_org and cl.counted is not null and cl.expected is not null and coalesce(cs.submitted_at, cs.created_at) >= v_from
    group by rollup (cs.location_id)),
  wk as (
    select date_trunc('week', (recorded_at at time zone v_tz))::date wk,
      coalesce(sum(-value) filter (where type = 'adjustment' and qty < 0 and coalesce(reason, '') not in ('Breakage', 'Expired')), 0) unexplained,
      coalesce(sum(value) filter (where type = 'adjustment' and qty > 0), 0) gained,
      coalesce(sum(-value) filter (where (type = 'adjustment' and qty < 0 and reason in ('Breakage', 'Expired')) or type in ('write_off', 'quarantine')), 0) damage
    from adj group by 1),
  cash as (
    select ct.location_id, ct.day, ct.cash + ct.pos + ct.transfers recorded,
      coalesce((select sum(-mv.qty * coalesce(mv.unit_price, 0)) from movements mv where mv.org_id = p_org and mv.location_id = ct.location_id
        and mv.type in ('sale', 'voice_sale') and (mv.recorded_at at time zone v_tz)::date = ct.day), 0) implied
    from cash_takings ct where ct.org_id = p_org and ct.day >= (v_from at time zone v_tz)::date),
  byloc as (
    select l.id, l.name,
      coalesce((select sum(-a.value) from adj a where a.location_id = l.id and a.type = 'adjustment' and a.qty < 0 and coalesce(a.reason, '') not in ('Breakage', 'Expired')), 0) unexplained,
      coalesce((select sum(a.value) from adj a where a.location_id = l.id and a.type = 'adjustment' and a.qty > 0), 0) gained,
      coalesce((select sum(-a.value) from adj a where a.location_id = l.id and ((a.type = 'adjustment' and a.qty < 0 and a.reason in ('Breakage', 'Expired')) or a.type in ('write_off', 'quarantine'))), 0) damage,
      coalesce((select sum(-mv.value) from movements mv where mv.org_id = p_org and mv.location_id = l.id and mv.type in ('sale', 'voice_sale') and mv.recorded_at >= v_from), 0) cogs,
      coalesce((select sum(greatest(c.implied - c.recorded, 0)) from cash c where c.location_id = l.id), 0) cash_short,
      (select round(100.0 * ok / nullif(n, 0), 1) from ira where ira.location_id = l.id) ira
    from locations l where l.org_id = p_org),
  risk as (select * from private.item_risk(p_org, v_days) r where r.risk > 0 order by r.risk desc limit 30)
  select jsonb_build_object(
    'days', v_days, 'today', v_today,
    'unexplained', t.unexplained, 'found', t.gained, 'net_unexplained', t.unexplained - t.gained, 'damage', t.damage,
    'cogs', s.cogs, 'revenue', s.rev,
    'shrink_pct', case when s.cogs > 0 then round(100 * (t.unexplained - t.gained) / s.cogs, 4) end,
    'monthly_leak', round((t.unexplained - t.gained + t.damage) * 30.0 / v_days, 2),
    'ira', (select round(100.0 * ok / nullif(n, 0), 1) from ira where ira.location_id is null),
    'lines_counted', (select n from ira where ira.location_id is null),
    'cash_short', (select coalesce(sum(greatest(implied - recorded, 0)), 0) from cash),
    'cash_days', (select count(*) from cash),
    'weeks', coalesce((select jsonb_agg(jsonb_build_object('week', wk, 'unexplained', unexplained, 'found', gained, 'damage', damage) order by wk)
                       from wk where wk >= (v_today - 84)), '[]'::jsonb),
    'locations', coalesce((select jsonb_agg(jsonb_build_object('location_id', id, 'name', name, 'unexplained', unexplained, 'found', gained,
        'damage', damage, 'cogs', cogs, 'shrink_pct', case when cogs > 0 then round(100 * (unexplained - gained) / cogs, 4) end,
        'cash_short', cash_short, 'ira', ira) order by name) from byloc), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(jsonb_build_object('item_id', r.item_id, 'location_id', r.location_id, 'item', i.name,
        'location', l.name, 'unit', i.selling_unit, 'on_hand', r.on_hand, 'unit_cost', r.unit_cost, 'per_day', r.per_day,
        'days_unchecked', r.days_unchecked, 'lost_qty', r.lost_qty, 'sold_qty', r.sold_qty, 'loss_rate', r.loss_rate,
        'risk', r.risk, 'flags', r.flags) order by r.risk desc)
      from risk r join items i on i.id = r.item_id join locations l on l.id = r.location_id), '[]'::jsonb),
    'spot_checks_per_day', (select spot_checks_per_day from orgs where id = p_org),
    'spot_check_last', (select spot_check_last from orgs where id = p_org),
    'spot_checks', coalesce((select jsonb_agg(jsonb_build_object('id', cs.id, 'ref', cs.ref, 'location_id', cs.location_id, 'area', cs.area,
        'status', cs.status, 'assignee', (select display_name from members where id = cs.assignee_id), 'created_at', cs.created_at,
        'items', (select count(*) from count_lines where session_id = cs.id),
        'differences', (select count(*) from count_lines where session_id = cs.id and counted is not null and expected is not null and counted <> expected))
      order by cs.created_at desc)
      from count_sessions cs where cs.org_id = p_org and cs.source = 'spot_check' and cs.created_at > now() - interval '14 days'), '[]'::jsonb),
    'can_see_people', v_owner
  ) into v_out
  from tot t, sales s;

  if v_owner then
    with ev as (
      select a.id, a.item_id, a.location_id, a.recorded_at at, -a.value v,
        coalesce((select max(coalesce(cs2.submitted_at, cs2.approved_at)) from count_lines cl2 join count_sessions cs2 on cs2.id = cl2.session_id
                  where cs2.location_id = a.location_id and cl2.item_id = a.item_id and cl2.counted is not null
                    and cs2.id is distinct from a.count_session_id and coalesce(cs2.submitted_at, cs2.approved_at) < a.recorded_at),
                 v_from - interval '30 days') prev
      from movements a
      where a.org_id = p_org and a.type = 'adjustment' and a.qty < 0 and a.recorded_at >= v_from
        and coalesce(a.reason, '') not in ('Breakage', 'Expired')),
    shares as (
      select ev.id, s.author_id, sum(-s.qty) q, ev.v
      from ev join movements s on s.org_id = p_org and s.item_id = ev.item_id and s.location_id = ev.location_id
        and s.type in ('sale', 'voice_sale', 'issue') and s.recorded_at > ev.prev and s.recorded_at <= ev.at and s.author_id is not null
      group by ev.id, s.author_id, ev.v),
    alloc as (
      select author_id, sum(v * q / nullif((select sum(q) from shares s2 where s2.id = shares.id), 0)) loss, count(distinct id) events
      from shares group by 1),
    sold as (
      select author_id, sum(-qty * coalesce(unit_price, 0)) rev, count(*) n, count(*) filter (where offline) offline_n,
        count(*) filter (where type = 'voice_sale') voice_n
      from movements where org_id = p_org and type in ('sale', 'voice_sale') and recorded_at >= v_from group by 1),
    ppl as (
      select mb.id, mb.display_name, mb.role, mb.location_id, coalesce(sd.rev, 0) rev, coalesce(sd.n, 0) n, coalesce(sd.offline_n, 0) offline_n,
        coalesce(sd.voice_n, 0) voice_n, coalesce(al.loss, 0) loss, coalesce(al.events, 0) events
      from members mb left join sold sd on sd.author_id = mb.id left join alloc al on al.author_id = mb.id
      where mb.org_id = p_org and (sd.n > 0 or al.events > 0))
    select v_out || jsonb_build_object(
      'loss_events', (select count(*) from ev),
      'people', coalesce((select jsonb_agg(jsonb_build_object('member_id', id, 'name', display_name, 'role', role, 'location_id', location_id,
          'sales', n, 'sales_value', rev, 'offline_sales', offline_n, 'voice_sales', voice_n, 'loss', round(loss, 2), 'events', events,
          'loss_pct', case when rev > 0 then round(100 * loss / rev, 2) end) order by loss desc, rev desc) from ppl), '[]'::jsonb))
    into v_out;
  end if;
  return v_out;
end $function$;

-- public.org_integrations: can_manage -> perm_of
CREATE OR REPLACE FUNCTION public.org_integrations(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members;
begin
  m := private.require(p_org, null);
  return jsonb_build_object(
    'can_manage', (private.perm_of(m, 'owner') or private.perm_of(m, 'manage_settings')) and not (select is_sample from orgs where id = p_org),
    'sample', (select is_sample from orgs where id = p_org),
    'connected', (select coalesce(jsonb_agg(private.integration_json(i) order by i.connected_at), '[]'::jsonb) from integrations i
      where i.org_id = p_org and i.status <> 'disconnected'),
    'whatsapp', public.org_whatsapp(p_org),
    'bank_feeds', (select count(*) from bank_accounts where org_id = p_org and provider = 'mono' and active),
    'locations', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name) order by l.is_main desc, l.name), '[]'::jsonb) from locations l where l.org_id = p_org));
end $function$;

-- public.org_whatsapp: can_change -> perm_of
CREATE OR REPLACE FUNCTION public.org_whatsapp(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; s public.whatsapp_sessions; o public.orgs;
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  select * into s from whatsapp_sessions where kind = 'business' and org_id = p_org;
  return jsonb_build_object('sender', o.whatsapp_sender,
    'own', case when s.id is not null then jsonb_build_object('status', s.status, 'phone', s.phone, 'push_name', s.push_name, 'status_at', s.status_at,
      'connected_at', s.connected_at, 'last_error', s.last_error) end,
    'counta', (select jsonb_build_object('status', c.status, 'phone', c.phone) from whatsapp_sessions c where c.kind = 'counta'),
    'can_change', private.perm_of(m, 'owner') or private.perm_of(m, 'manage_settings'));
end $function$;

-- public.portal_login_begin: only the owner saves portal logins -> perm_of
CREATE OR REPLACE FUNCTION public.portal_login_begin(p_org uuid, p_authority text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; a public.tax_authorities; o public.orgs; l public.portal_logins;
begin
  m := private.require(p_org, null);
  if not private.perm_of(m, 'owner') then raise exception 'Only the owner saves or removes the business''s tax portal logins.' using errcode = '42501'; end if;
  if private.jwt_aal() <> 'aal2' and private.mfa_required(auth.uid()) then
    raise exception 'Enter the code from your authenticator app first: tax portal logins need two-step sign-in.' using errcode = 'PX403';
  end if;
  select * into a from tax_authorities where code = p_authority;
  if not found then raise exception 'Choose the tax authority.'; end if;
  select * into o from orgs where id = p_org;
  select * into l from portal_logins where org_id = p_org and authority = p_authority;
  return jsonb_build_object('member_id', m.id, 'org', jsonb_build_object('name', o.name, 'tin', o.tin, 'rc_number', o.rc_number, 'taxstreem_org_id', o.taxstreem_org_id),
    'authority', jsonb_build_object('code', a.code, 'name', a.name, 'short_name', a.short_name, 'state', a.state, 'portal', private.portal_of(a.code)),
    'existing', case when l.id is not null then jsonb_build_object('flux_ref', l.flux_ref, 'username_hint', l.username_hint) end);
end $function$;

-- public.portal_logins: the caller sees the logins -> perm_of; can_manage -> perm_of
CREATE OR REPLACE FUNCTION public.portal_logins(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'owner') or private.perm_of(m, 'file_tax')) then
    raise exception 'Tax portal logins are for the owner and those who file tax.' using errcode = '42501';
  end if;
  return jsonb_build_object('can_manage', private.perm_of(m, 'owner'),
    'logins', (select coalesce(jsonb_agg(jsonb_build_object('authority', l.authority, 'authority_name', a.name, 'short_name', a.short_name, 'portal', private.portal_of(l.authority),
        'username_hint', l.username_hint, 'tax_office', l.tax_office, 'status', l.status, 'message', l.message, 'saved_at', l.saved_at, 'checked_at', l.checked_at,
        'saved_by', (select display_name from members where id = l.saved_by)) order by a.sort), '[]'::jsonb)
      from portal_logins l join tax_authorities a on a.code = l.authority where l.org_id = p_org),
    'authorities', (select jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name, 'short_name', a.short_name, 'state', a.state, 'kind', a.kind,
        'portal', private.portal_of(a.code)) order by a.sort) from tax_authorities a));
end $function$;

-- public.pos_overview: can connect -> perm_of
CREATE OR REPLACE FUNCTION public.pos_overview(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; v_owner boolean; v_manage boolean; v_books boolean;
begin
  m := private.require(p_org, null);
  v_owner := private.perm_of(m, 'owner');
  v_manage := v_owner or coalesce(private.perm_of(m, 'manage_settings'), false);
  v_books := coalesce(private.perm_of(m, 'keep_books'), false) or coalesce(private.perm_of(m, 'approve_adjustments'), false);
  return jsonb_build_object(
    'can', jsonb_build_object('connect', v_owner, 'manage', v_manage, 'assign', v_books),
    'sample', coalesce((select is_sample from orgs where id = p_org), false),
    'connections', coalesce((select jsonb_agg(private.pos_conn_json(c) order by c.connected_at) from pos_connections c where c.org_id = p_org and c.status <> 'removed'), '[]'::jsonb),
    'accounts', case when v_owner then coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'bank_name', b.bank_name,
        'account_number', b.account_number) order by b.name) from bank_accounts b where b.org_id = p_org and b.active and b.kind = 'bank'), '[]'::jsonb) else '[]'::jsonb end,
    'locations', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name) order by l.is_main desc, l.name) from locations l where l.org_id = p_org), '[]'::jsonb),
    'unassigned', case when v_books or v_manage then coalesce((select jsonb_agg(private.pos_txn_json(t) order by t.occurred_at desc)
        from pos_transactions t where t.org_id = p_org and t.outcome = 'unassigned'), '[]'::jsonb) else '[]'::jsonb end,
    'recent', case when v_books or v_manage then coalesce((select jsonb_agg(x.j order by x.at desc) from (select private.pos_txn_json(t) j, t.occurred_at at
        from pos_transactions t where t.org_id = p_org and t.status = 'approved' order by t.occurred_at desc limit 40) x), '[]'::jsonb) else '[]'::jsonb end);
end $function$;

-- public.practice_accept: the caller connects the business -> perm_of
CREATE OR REPLACE FUNCTION public.practice_accept(p_token text, p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare t public.practice_members; c public.practice_clients; v_email text; v_hash text; v_org uuid; v_practice uuid; cl record; mb public.members;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if coalesce(p_token, '') !~ '^p[mc]_[0-9a-f]{48}$' then raise exception 'This invitation link is not complete. Open it from the email again.'; end if;
  v_hash := encode(extensions.digest(p_token, 'sha256'), 'hex');
  select lower(email) into v_email from auth.users where id = auth.uid();
  if p_token like 'pm_%' then
    select * into t from practice_members where token_hash = v_hash for update;
    if not found then raise exception 'This invitation link has been replaced or used. Ask for a new one.'; end if;
    if t.status <> 'invited' then raise exception 'This invitation has already been used.'; end if;
    if t.token_expires < now() then raise exception 'This invitation has expired. Ask the practice for a new one.'; end if;
    if v_email is distinct from lower(t.email) then raise exception 'This invitation is for %. Sign in with that email address to join.', t.email using errcode = '42501'; end if;
    if exists (select 1 from practice_members where practice_id = t.practice_id and user_id = auth.uid()) then raise exception 'You are already on this practice.'; end if;
    update practice_members set user_id = auth.uid(), status = 'active', token_expires = least(token_expires, now()) where id = t.id;
    for cl in select id from practice_clients where practice_id = t.practice_id and status = 'active' loop perform private.practice_sync_seats(cl.id); end loop;
    perform private.practice_notify(t.practice_id, t.display_name || ' joined the practice', 'They can now work on the clients you assign.', '/practice/team');
    return jsonb_build_object('kind', 'member', 'practice_id', t.practice_id);
  end if;
  select * into c from practice_clients where token_hash = v_hash for update;
  if not found then raise exception 'This invitation link has been replaced or used. Ask for a new one.'; end if;
  if c.status not in ('invited', 'requested') then raise exception 'This invitation has already been used.'; end if;
  if c.token_expires < now() then raise exception 'This invitation has expired. Ask for a new one.'; end if;
  if c.status = 'invited' then
    -- A business owner connects one of their businesses to the practice.
    v_org := nullif(p->>'org_id', '')::uuid;
    if v_org is null then raise exception 'Choose the business to connect.'; end if;
    mb := private.require(v_org, null);
    if not private.perm_of(mb, 'owner') then raise exception 'Only the owner of the business connects it to an accountant.' using errcode = '42501'; end if;
    if (select is_sample from orgs where id = v_org) then raise exception 'The sample business cannot be connected. Choose your own business.'; end if;
    if exists (select 1 from practice_clients where practice_id = c.practice_id and org_id = v_org and status = 'active') then
      raise exception 'That business is already connected to this practice.';
    end if;
    update practice_clients set org_id = v_org, status = 'active', started_at = now(), accepted_by = auth.uid(), token_expires = least(token_expires, now()),
      business_name = (select name from orgs where id = v_org) where id = c.id returning * into c;
    perform private.practice_sync_seats(c.id);
    perform private.practice_notify(c.practice_id, c.business_name || ' accepted your invitation', 'It is now one of your clients.', '/practice/clients/' || c.id);
    return jsonb_build_object('kind', 'client', 'org_id', v_org, 'client_id', c.id);
  end if;
  -- An accountant takes on a business that invited them.
  if v_email is distinct from lower(c.invite_email) then raise exception 'This invitation is for %. Sign in with that email address.', c.invite_email using errcode = '42501'; end if;
  v_practice := nullif(p->>'practice_id', '')::uuid;
  if v_practice is null then raise exception 'Set up your practice first, then accept.'; end if;
  perform private.practice_require(v_practice, true);
  if exists (select 1 from practice_clients where practice_id = v_practice and org_id = c.org_id and status = 'active') then
    raise exception 'That business is already one of your clients.';
  end if;
  update practice_clients set practice_id = v_practice, status = 'active', started_at = now(), accepted_by = auth.uid(), token_expires = least(token_expires, now()) where id = c.id returning * into c;
  perform private.practice_sync_seats(c.id);
  perform private.notify_perm(c.org_id, 'manage_team', 'practice', (select name from practices where id = v_practice) || ' is now your accountant',
    'They can keep the books and prepare tax returns. See and change what they may do in Settings, Your accountant.', '/settings#accountant', 'practice-' || c.id);
  return jsonb_build_object('kind', 'accountant', 'org_id', c.org_id, 'client_id', c.id, 'practice_id', v_practice);
end $function$;

-- public.prepare_reminder_call: owners and managers send reminder calls -> perm_of
CREATE OR REPLACE FUNCTION public.prepare_reminder_call(p_member uuid, p_topic text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare t public.members; m public.members; o public.orgs; v_to text; v_details text; v_action text; v_n int; v_id uuid; v_vars jsonb;
begin
  select * into t from members where id = p_member;
  if not found then raise exception 'Team member not found.'; end if;
  m := private.require(t.org_id, null);
  if not (m.role in ('owner', 'manager') or m.acts_as_owner) and m.id <> t.id then raise exception 'Only owners and managers can send reminder calls.' using errcode = '42501'; end if;
  if t.status <> 'active' then raise exception '% is not active in this business.', t.display_name; end if;
  v_to := private.e164(t.phone);
  if v_to is null then raise exception 'Add a phone number for % first (for example 0803 123 4567).', t.display_name; end if;
  select * into o from orgs where id = t.org_id;
  case p_topic
    when 'count_approval' then
      select count(*), string_agg(c.ref || ' (' || c.area || ' at ' || lc.name || ')', ', ') into v_n, v_details
      from count_sessions c join locations lc on lc.id = c.location_id
      where c.org_id = t.org_id and c.status in ('awaiting_approval', 'awaiting_reasons');
      if v_n = 0 then raise exception 'No counts are waiting for approval.'; end if;
      v_details := v_n || ' stock count' || case when v_n > 1 then 's are' else ' is' end || ' waiting for approval: ' || v_details || '.';
      v_action := 'Open Counta, go to Stock counts, give a reason for each difference and approve or reject the count.';
    when 'count_due' then
      select count(*), string_agg(c.ref || ' (' || c.area || ' at ' || lc.name || ')', ', ') into v_n, v_details
      from count_sessions c join locations lc on lc.id = c.location_id
      where c.org_id = t.org_id and c.status = 'open' and (c.assignee_id = t.id or c.assignee_id is null);
      if v_n = 0 then raise exception 'No open counts are assigned to %.', t.display_name; end if;
      v_details := v_n || ' stock count' || case when v_n > 1 then 's are' else ' is' end || ' waiting to be done: ' || v_details || '.';
      v_action := 'Open the Counta phone app, tap Count, and count the shelf without looking at the expected numbers.';
    when 'receipts_review' then
      select count(*), string_agg(r.ref || ' from ' || coalesce(nullif(r.vendor_name, ''), 'a vendor'), ', ') into v_n, v_details
      from receipts r where r.org_id = t.org_id and r.status = 'needs_review';
      if v_n = 0 then raise exception 'No invoices are waiting to be confirmed.'; end if;
      v_details := v_n || ' supplier invoice' || case when v_n > 1 then 's are' else ' is' end || ' read and waiting to be confirmed: ' || v_details || '.';
      v_action := 'Open Counta, go to Receive stock, check the lines Martina was unsure about and post the receipt.';
    when 'transfer_confirm' then
      select count(*), string_agg(tr.ref || ', ' || private.fmt_qty(tr.qty) || ' ' || i.selling_unit || ' of ' || i.name, '; ') into v_n, v_details
      from transfers tr join items i on i.id = tr.item_id
      where tr.org_id = t.org_id and tr.status = 'in_transit' and (t.location_id is null or tr.to_location_id = t.location_id);
      if v_n = 0 then raise exception 'No transfers are waiting to be confirmed for %.', t.display_name; end if;
      v_details := v_n || ' transfer' || case when v_n > 1 then 's are' else ' is' end || ' on the way and not yet confirmed: ' || v_details || '.';
      v_action := 'When the goods arrive, open the Counta phone app and confirm the transfer so the stock moves into the branch.';
    when 'price_proposals' then
      select count(*), string_agg(i.name, ', ') into v_n, v_details
      from price_proposals p join items i on i.id = p.item_id where p.org_id = t.org_id and p.status = 'open';
      if v_n = 0 then raise exception 'No price checks are open.'; end if;
      v_details := v_n || ' price check' || case when v_n > 1 then 's are' else ' is' end || ' open because costs moved: ' || v_details || '.';
      v_action := 'Open Counta, go to Pricing, and apply or keep each suggested price.';
    else raise exception 'Choose what the call is about.';
  end case;
  v_vars := jsonb_build_object('business_name', o.name, 'person_name', t.display_name, 'person_first_name', split_part(t.display_name, ' ', 1),
    'caller_name', m.display_name, 'task_details', v_details, 'task_action', v_action);
  insert into voice_calls (org_id, kind, member_id, topic, to_number, variables, created_by)
  values (t.org_id, 'reminder', t.id, p_topic, v_to, v_vars, m.id)
  returning id into v_id;
  return jsonb_build_object('call_id', v_id, 'to_number', v_to, 'variables', v_vars);
end $function$;

-- public.record_takings: the owner or a manager records takings -> perm_of
CREATE OR REPLACE FUNCTION public.record_takings(p_org uuid, p_location uuid, p_day date, p_cash numeric, p_pos numeric, p_transfers numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members;
begin
  m := private.require(p_org, 'see_margins');
  if not (m.role in ('owner', 'manager') or m.acts_as_owner) then raise exception 'Only the owner or a manager records takings.'; end if;
  if not exists (select 1 from locations where id = p_location and org_id = p_org) then raise exception 'Unknown branch.'; end if;
  if coalesce(p_cash, 0) < 0 or coalesce(p_pos, 0) < 0 or coalesce(p_transfers, 0) < 0 then raise exception 'Amounts cannot be negative.'; end if;
  insert into cash_takings (org_id, location_id, day, cash, pos, transfers, source, created_by)
  values (p_org, p_location, p_day, coalesce(p_cash, 0), coalesce(p_pos, 0), coalesce(p_transfers, 0), 'manual', m.id)
  on conflict (org_id, location_id, day) do update set cash = excluded.cash, pos = excluded.pos, transfers = excluded.transfers,
    source = 'manual', created_by = excluded.created_by;
end $function$;

-- public.referral_connect: only the owner connects the business -> perm_of
CREATE OR REPLACE FUNCTION public.referral_connect(p_org uuid, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; pr public.practices; c public.practice_clients;
begin
  m := private.require(p_org, null);
  if not private.perm_of(m, 'owner') then raise exception 'Only the owner of the business connects it to an accountant.' using errcode = '42501'; end if;
  if (select is_sample from orgs where id = p_org) then raise exception 'The sample business cannot be connected. Choose your own business.'; end if;
  select * into pr from practices where referral_code = upper(coalesce(p_code, ''));
  if not found then raise exception 'That link is not complete. Ask your accountant for it again.'; end if;
  if exists (select 1 from practice_clients where practice_id = pr.id and org_id = p_org and status = 'active') then
    raise exception '% is already your accountant.', pr.name;
  end if;
  insert into practice_clients (practice_id, org_id, status, initiated_by, via, business_name, created_by, accepted_by, started_at)
  values (pr.id, p_org, 'active', 'practice', 'link', (select name from orgs where id = p_org), auth.uid(), auth.uid(), now())
  returning * into c;
  perform private.practice_sync_seats(c.id);
  perform private.practice_notify(pr.id, c.business_name || ' joined through your link', 'It is now one of your clients.', '/practice/clients/' || c.id);
  perform private.notify_perm(p_org, 'manage_team', 'practice', pr.name || ' is now your accountant',
    'They can keep the books and prepare tax returns. See and change what they may do in Settings, Your accountant.', '/settings#accountant', 'practice-' || c.id);
  return jsonb_build_object('client_id', c.id, 'practice', private.partner_public(pr.id), 'offer', private.partner_offer(p_org));
end $function$;

-- public.referral_offer: the offer is for the owner -> perm_of
CREATE OR REPLACE FUNCTION public.referral_offer(p_org uuid, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; v_id uuid; v_new boolean; s jsonb := private.partner_settings();
begin
  m := private.require(p_org, null);
  if not private.perm_of(m, 'owner') or (select is_sample from orgs where id = p_org) or not (s->>'enabled')::boolean then return null; end if;
  if coalesce(p_code, '') !~ '^[A-Za-z]{4}-[A-Za-z0-9]{4}$' then return null; end if;
  select id into v_id from practices where referral_code = upper(p_code);
  if v_id is null then return null; end if;
  if exists (select 1 from practice_clients where practice_id = v_id and org_id = p_org and status = 'active') then
    return jsonb_build_object('connected', true, 'practice', private.partner_public(v_id));
  end if;
  if exists (select 1 from practice_members where practice_id = v_id and user_id = auth.uid() and status = 'active') then return null; end if;
  v_new := not exists (select 1 from subscription_charges where org_id = p_org and status = 'successful')
    and not exists (select 1 from partner_referrals where org_id = p_org and status <> 'void');
  return jsonb_build_object('connected', false, 'practice', private.partner_public(v_id),
    'offer', case when v_new and (s->'welcome'->>'on')::boolean and (s->'welcome'->>'percent')::numeric > 0
      then jsonb_build_object('percent', (s->'welcome'->>'percent')::numeric, 'payments', (s->'welcome'->>'payments')::int) end);
end $function$;

-- public.request_payout: the caller refunds customers -> perm_of
CREATE OR REPLACE FUNCTION public.request_payout(p_org uuid, p_payout jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; v_purpose text := coalesce(nullif(p_payout->>'purpose', ''), 'other'); v_amt numeric := round(private.num(p_payout->>'amount'), 2);
  v_lines jsonb; v_code text; b public.bank_accounts; po public.payouts; v_bal numeric; v_ar numeric; v_adv numeric;
begin
  m := private.require(p_org, 'make_payments');
  if v_purpose = 'withdrawal' then
    select * into b from bank_accounts where id = nullif(p_payout->>'to_bank_account_id', '')::uuid and org_id = p_org and active and kind = 'bank';
    if not found then raise exception 'Choose which of the business''s bank accounts to send it to.'; end if;
    v_lines := jsonb_build_array(jsonb_build_object('code', b.ledger_code, 'debit', v_amt, 'memo', 'From wallet'));
    p_payout := p_payout || jsonb_build_object('account_number', coalesce(nullif(p_payout->>'account_number', ''), b.account_number),
      'account_name', coalesce(nullif(p_payout->>'account_name', ''), b.account_name, (select name from orgs where id = p_org)),
      'bank_code', coalesce(nullif(p_payout->>'bank_code', ''), b.bank_code),
      'bank_name', coalesce(nullif(p_payout->>'bank_name', ''), b.bank_name));
  elsif v_purpose = 'expense' then
    v_code := nullif(p_payout->>'expense_account', '');
    if v_code is null or v_code !~ '^[5-7]' or not private.postable(p_org, v_code) then raise exception 'Choose the expense account.'; end if;
    v_lines := jsonb_build_array(jsonb_build_object('code', v_code, 'debit', v_amt, 'memo', p_payout->>'narration'));
  elsif v_purpose = 'refund' then
    if nullif(p_payout->>'customer_id', '') is null or not exists (select 1 from customers where id = (p_payout->>'customer_id')::uuid and org_id = p_org) then
      raise exception 'Choose the customer being refunded.';
    end if;
    if not (private.perm_of(m, 'approve_adjustments') or private.perm_of(m, 'owner')) then raise exception 'Only a manager or the owner refunds customers.'; end if;
    v_bal := private.customer_balance(p_org, (p_payout->>'customer_id')::uuid);
    if v_amt > -v_bal + 0.004 then raise exception 'The customer has % of credit to refund.', to_char(greatest(-v_bal, 0), 'FM999,999,999,990.00'); end if;
    select coalesce(sum(debit - credit), 0) into v_ar from journal_lines where org_id = p_org and party_type = 'customer'
      and party_id = (p_payout->>'customer_id')::uuid and account_code in ('1101', '1102');
    v_adv := greatest(v_amt - greatest(-v_ar, 0), 0);
    v_lines := jsonb_build_array(
      jsonb_build_object('code', private.acct(p_org, 'receivables'), 'debit', v_amt - v_adv, 'party_type', 'customer', 'party_id', p_payout->>'customer_id'),
      jsonb_build_object('code', private.acct(p_org, 'customer_advances'), 'debit', v_adv, 'party_type', 'customer', 'party_id', p_payout->>'customer_id'));
  elsif v_purpose in ('vendor', 'staff', 'other') then
    raise exception 'Pay suppliers from their bill, and staff through payroll, so the books show what was paid for.';
  else
    raise exception 'Unknown payout purpose.';
  end if;
  po := private.create_payout(p_org, p_payout || jsonb_build_object('purpose', v_purpose), v_lines, m);
  return to_jsonb(po);
end $function$;

-- public.request_tax_payment: the caller pays tax from the tax wallet -> perm_of
CREATE OR REPLACE FUNCTION public.request_tax_payment(p_org uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; t public.tax_wallets; py public.tax_payees; v_kind text := coalesce(nullif(p->>'kind', ''), 'vat'); v_period date;
  v_auth text := nullif(p->>'authority', ''); v_amt numeric; vp public.vat_periods; v_ref text := nullif(trim(p->>'tax_reference'), ''); x public.tax_payments;
begin
  m := private.require(p_org, 'make_payments');
  if not (private.perm_of(m, 'owner') or private.perm_of(m, 'approve_payments')) then
    raise exception 'Tax payments from the tax wallet need someone who approves payments.' using errcode = '42501';
  end if;
  perform private.require_payments_open(p_org);
  select * into t from tax_wallets where org_id = p_org and status = 'active';
  if not found then raise exception 'Open the tax wallet first.'; end if;
  if v_kind not in ('vat', 'wht', 'wvat') then raise exception 'Pay VAT, WHT or withholding VAT from the tax wallet.'; end if;
  v_period := date_trunc('month', nullif(p->>'period', '')::date)::date;
  if v_period is null then raise exception 'Choose the month.'; end if;
  if v_ref is null or length(v_ref) > 60 then raise exception 'Enter the payment reference the tax authority gave for this payment.'; end if;
  select * into py from tax_payees where id = nullif(p->>'payee_id', '')::uuid and active;
  if not found or not (v_kind = any(py.kinds)) then raise exception 'Choose an account TaxStreem lists for this tax.'; end if;
  if v_kind = 'vat' then
    select * into vp from vat_periods where org_id = p_org and period = v_period;
    if not found then raise exception 'File the % VAT return first.', to_char(v_period, 'FMMonth YYYY'); end if;
    if vp.status = 'paid' then raise exception 'The % VAT is already paid.', to_char(v_period, 'FMMonth YYYY'); end if;
    v_amt := vp.payable;
    v_auth := 'NRS';
  else
    if v_kind = 'wvat' then v_auth := 'NRS'; end if;
    if v_auth is null then raise exception 'Choose who the WHT is paid to.'; end if;
    if py.authority is not null and py.authority <> v_auth then raise exception 'That account is for %, not %.', py.authority, v_auth; end if;
    select coalesce(sum(amount), 0) into v_amt from wht_deductions where org_id = p_org and authority = v_auth and period = v_period and status = 'deducted'
      and (kind = 'wht') = (v_kind = 'wht');
  end if;
  if coalesce(v_amt, 0) <= 0 then raise exception 'Nothing is due for % in %.', upper(v_kind), to_char(v_period, 'FMMonth YYYY'); end if;
  if exists (select 1 from tax_payments where org_id = p_org and kind = v_kind and period = v_period and authority is not distinct from v_auth
             and status in ('approved', 'processing', 'successful')) then
    raise exception 'A payment for this is already on its way or made.';
  end if;
  if v_amt > private.tax_wallet_spendable(t.id) + 0.004 then
    raise exception 'The tax wallet holds % that can be paid out; % is due. Top it up from the business wallet or a bank.',
      private.naira(private.tax_wallet_spendable(t.id)), private.naira(v_amt);
  end if;
  insert into tax_payments (org_id, tax_wallet_id, payee_id, kind, authority, period, amount, tax_reference, reference, bank_code, account_number, account_name, requested_by)
  values (p_org, t.id, py.id, v_kind, v_auth, v_period, v_amt, v_ref, 'CNTX-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
    py.bank_code, py.account_number, py.account_name, m.id)
  returning * into x;
  return to_jsonb(x);
end $function$;

-- public.reverse_books_migration: only the owner undoes a migration -> perm_of
CREATE OR REPLACE FUNCTION public.reverse_books_migration(p_migration uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare b public.books_migrations; m public.members; r public.journals;
begin
  select * into b from books_migrations where id = p_migration for update;
  if not found then raise exception 'Migration not found.'; end if;
  m := private.require(b.org_id, null);
  if not private.perm_of(m, 'owner') then raise exception 'Only the owner undoes a migration.' using errcode = '42501'; end if;
  if b.status <> 'posted' then raise exception 'Only a posted migration can be undone.'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Give a reason.'; end if;
  if exists (select 1 from sales s join migration_open_items i on i.doc_id = s.id where i.migration_id = b.id and i.kind = 'invoice' and (s.amount_paid > 0 or s.credited > 0)) then
    raise exception 'Customers have paid some of the opening invoices. Undo those payments first.';
  end if;
  if exists (select 1 from bills x join migration_open_items i on i.doc_id = x.id where i.migration_id = b.id and i.kind = 'bill'
             and (x.amount_paid > 0 or exists (select 1 from bill_payments bp where bp.bill_id = x.id and bp.status in ('paid', 'processing')))) then
    raise exception 'Some opening bills have been paid. Undo those payments first.';
  end if;
  r := private.reverse_entry(b.journal_id, m.id, 'Migration undone: ' || trim(p_reason));
  update sales set status = 'void', voided_by = m.id, voided_at = now(), void_reason = 'Migration undone' where id in (select doc_id from migration_open_items where migration_id = b.id and kind = 'invoice');
  update bills set status = 'void', voided_by = m.id, voided_at = now(), void_reason = 'Migration undone' where id in (select doc_id from migration_open_items where migration_id = b.id and kind = 'bill');
  update books_migrations set status = 'reversed', reversal_journal_id = r.id, reversed_by = m.id, reversed_at = now() where id = b.id;
  return jsonb_build_object('status', 'reversed', 'journal_ref', r.ref);
end $function$;

-- public.save_alert_prefs: the caller changes alerts -> perm_of
CREATE OR REPLACE FUNCTION public.save_alert_prefs(p_org uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; k text; x jsonb; v jsonb;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'owner') or private.perm_of(m, 'manage_settings')) then raise exception 'Only the owner or someone who manages settings changes alerts.' using errcode = '42501'; end if;
  select alert_prefs into v from orgs where id = p_org;
  for k, x in select * from jsonb_each(coalesce(p, '{}'::jsonb)) loop
    if k not in ('email', 'whatsapp', 'owner_calls', 'customer_calls') then raise exception 'Unknown alert setting: %.', k; end if;
    if jsonb_typeof(x) <> 'boolean' then raise exception 'Alert settings are on or off.'; end if;
    v := v || jsonb_build_object(k, x);
  end loop;
  update orgs set alert_prefs = v where id = p_org;
  return private.alert_prefs(p_org);
end $function$;

-- public.save_delivery: the caller manages deliveries -> perm_of
CREATE OR REPLACE FUNCTION public.save_delivery(p_org uuid, p_delivery jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; d public.deliveries; v_id uuid := nullif(p_delivery->>'id', '')::uuid; s public.sales; v_status text := nullif(p_delivery->>'status', '');
  o public.orgs; v_due numeric; v_manager boolean;
begin
  m := private.require(p_org, 'record_sales');
  select * into o from orgs where id = p_org;
  v_manager := (m.role in ('owner', 'manager') or m.acts_as_owner) or private.perm_of(m, 'approve_adjustments');
  if nullif(p_delivery->>'driver_id', '') is not null and not exists (select 1 from members where id = (p_delivery->>'driver_id')::uuid and org_id = p_org) then
    raise exception 'Choose a driver from the team.';
  end if;
  if nullif(p_delivery->>'vehicle_location_id', '') is not null
     and not exists (select 1 from locations where id = (p_delivery->>'vehicle_location_id')::uuid and org_id = p_org and kind = 'van') then
    raise exception 'Choose one of the business''s vans.';
  end if;
  if v_id is null then
    select * into s from sales where id = nullif(p_delivery->>'sale_id', '')::uuid and org_id = p_org;
    if not found or s.doc_type not in ('receipt', 'invoice', 'order') or s.status in ('void', 'cancelled', 'draft') then raise exception 'Choose the sale being delivered.'; end if;
    insert into deliveries (org_id, number, sale_id, driver_id, vehicle_location_id, address, contact_phone, scheduled_for, notes, created_by)
    values (p_org, 'DN-' || lpad(private.next_no(p_org, 'DN', 1)::text, 5, '0'), s.id, nullif(p_delivery->>'driver_id', '')::uuid,
      nullif(p_delivery->>'vehicle_location_id', '')::uuid, coalesce(nullif(trim(p_delivery->>'address'), ''), s.delivery_address, s.customer_address),
      coalesce(private.clean_phone(p_delivery->>'contact_phone'), s.customer_phone), nullif(p_delivery->>'scheduled_for', '')::date,
      nullif(trim(p_delivery->>'notes'), ''), m.id)
    returning * into d;
    -- Payment on delivery, agreed by a manager: the goods may leave unpaid and the driver collects.
    if coalesce((p_delivery->>'collect_on_delivery')::boolean, false) then
      if not v_manager then raise exception 'Only a manager can agree payment on delivery.'; end if;
      update deliveries set collect_on_delivery = true, collect_agreed_by = m.id where id = d.id returning * into d;
    end if;
  else
    select * into d from deliveries where id = v_id and org_id = p_org for update;
    if not found then raise exception 'Delivery not found.'; end if;
    if v_status is not null and v_status not in ('pending', 'dispatched', 'delivered', 'failed', 'cancelled') then raise exception 'Unknown delivery status.'; end if;
    if d.status in ('delivered', 'cancelled') and v_status is not null and v_status <> d.status then raise exception '% is already %.', d.number, d.status; end if;
    if v_status = 'delivered' and coalesce(nullif(trim(p_delivery->>'received_by'), ''), d.received_by, '') = '' then
      raise exception 'Enter the name of the person who received the goods.';
    end if;
    if p_delivery ? 'collect_on_delivery' and coalesce((p_delivery->>'collect_on_delivery')::boolean, false) <> d.collect_on_delivery then
      if not v_manager then raise exception 'Only a manager can agree payment on delivery.'; end if;
      update deliveries set collect_on_delivery = (p_delivery->>'collect_on_delivery')::boolean,
        collect_agreed_by = case when (p_delivery->>'collect_on_delivery')::boolean then m.id end where id = d.id returning * into d;
    end if;
    -- Goods leave only once the money is confirmed (the rail's confirmation, or a payment confirmed against the bank),
    -- unless a manager agreed payment on delivery.
    if v_status in ('dispatched', 'delivered') and d.status not in ('dispatched', 'delivered') and o.release_after_payment and not d.collect_on_delivery then
      select * into s from sales where id = d.sale_id;
      v_due := s.total - s.amount_paid - s.credited;
      if s.status = 'pending' or v_due > 0.004 then
        raise exception '% has % not yet confirmed as paid. Goods leave once the payment is confirmed: take it by Pay by transfer (confirmed in seconds) or confirm the transfer against the bank. A manager can agree payment on delivery instead.',
          s.number, private.naira(case when s.status = 'pending' then s.total else v_due end);
      end if;
    end if;
    update deliveries set status = coalesce(v_status, status),
      driver_id = case when p_delivery ? 'driver_id' then nullif(p_delivery->>'driver_id', '')::uuid else driver_id end,
      vehicle_location_id = case when p_delivery ? 'vehicle_location_id' then nullif(p_delivery->>'vehicle_location_id', '')::uuid else vehicle_location_id end,
      address = coalesce(nullif(trim(p_delivery->>'address'), ''), address),
      contact_phone = coalesce(private.clean_phone(p_delivery->>'contact_phone'), contact_phone),
      scheduled_for = case when p_delivery ? 'scheduled_for' then nullif(p_delivery->>'scheduled_for', '')::date else scheduled_for end,
      dispatched_at = case when v_status in ('dispatched', 'delivered') and dispatched_at is null then now() else dispatched_at end,
      delivered_at = case when v_status = 'delivered' then now() else delivered_at end,
      received_by = coalesce(nullif(trim(p_delivery->>'received_by'), ''), received_by),
      proof_path = coalesce(nullif(p_delivery->>'proof_path', ''), proof_path),
      notes = case when p_delivery ? 'notes' then nullif(trim(p_delivery->>'notes'), '') else notes end
    where id = d.id returning * into d;
  end if;
  return to_jsonb(d);
end $function$;

-- public.save_income_tax_setup: only the owner changes how the business is taxed -> perm_of
CREATE OR REPLACE FUNCTION public.save_income_tax_setup(p_org uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; v_prof jsonb; k text;
begin
  m := private.require(p_org, null);
  if not private.perm_of(m, 'owner') then raise exception 'Only the owner changes how the business is taxed.' using errcode = '42501'; end if;
  select coalesce(cit_profile, '{}'::jsonb) into v_prof from orgs where id = p_org;
  for k in select jsonb_object_keys(p) loop
    if k not in ('limited_by_guarantee', 'ngo_trades') then raise exception 'Unknown setting %.', k; end if;
    -- Kept as an explicit true or false: "not an NGO" must outlast the next read of the CAC record (kyc_guarantee_mark).
    v_prof := v_prof || jsonb_build_object(k, coalesce((p->>k)::boolean, false));
  end loop;
  update orgs set cit_profile = v_prof where id = p_org;
  return jsonb_build_object('kind', private.income_tax_kind(p_org), 'cit_profile', v_prof);
end $function$;

-- public.save_role_permissions: only the owner changes admins -> perm_of; nobody but the owner changes their own role -> perm_of
CREATE OR REPLACE FUNCTION public.save_role_permissions(p_org uuid, p_role text, p_perms jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; p jsonb; v_std jsonb; mb public.members; n int := 0;
begin
  m := private.require(p_org, 'manage_team');
  if p_role not in ('admin', 'manager', 'staff', 'cashier', 'accountant') then raise exception 'Choose a role.'; end if;
  if p_role = 'admin' and not private.perm_of(m, 'owner') then raise exception 'Only the owner changes what admins can do.' using errcode = '42501'; end if;
  if p_role = m.role and not private.perm_of(m, 'owner') then raise exception 'Ask the owner to change your own role.' using errcode = '42501'; end if;
  p := private.role_perms(p_org, p_role) || private.clean_perms(coalesce(p_perms, '{}'::jsonb));
  perform private.check_grantable(m, p);
  perform private.check_split(p_role, p, private.role_label(p_role));
  for mb in select * from members where org_id = p_org and role = p_role and status <> 'disabled' loop
    perform private.check_split(p_role, p || private.clean_perms(mb.perm_overrides), mb.display_name);
  end loop;
  v_std := private.role_template(p_role);
  if p = v_std then
    delete from role_permissions where org_id = p_org and role = p_role;
  else
    insert into role_permissions (org_id, role, perms, updated_by) values (p_org, p_role, p, m.id)
    on conflict (org_id, role) do update set perms = excluded.perms, updated_by = excluded.updated_by, updated_at = now();
  end if;
  for mb in select * from members where org_id = p_org and role = p_role loop
    -- An exception that now matches the role is no longer an exception.
    update members set perm_overrides = (select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from jsonb_each(private.clean_perms(mb.perm_overrides)) x(k, v) where v <> p->k)
    where id = mb.id;
    perform private.apply_member_perms(mb.id);
    n := n + 1;
  end loop;
  return jsonb_build_object('role', p_role, 'perms', p, 'people', n);
end $function$;

-- public.save_voice_settings: the owner or a manager chooses the voice -> perm_of
CREATE OR REPLACE FUNCTION public.save_voice_settings(p_org uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; v_voice text; v_lang text; v_events jsonb; k text;
begin
  m := private.require(p_org, null);
  if not (m.role in ('owner', 'manager') or m.acts_as_owner) then
    raise exception 'Only the owner or a manager chooses the voice.' using errcode = '42501';
  end if;
  if p ? 'voice_id' then
    v_voice := nullif(trim(p->>'voice_id'), '');
    if v_voice is not null and not exists (select 1 from tts_voices where voice_id = v_voice and active) then
      raise exception 'Choose one of the voices on the list.';
    end if;
  end if;
  if p ? 'voice_lang' then
    v_lang := p->>'voice_lang';
    if v_lang not in ('en', 'pcm') then raise exception 'Choose English or Pidgin.'; end if;
  end if;
  if p ? 'events' then
    if jsonb_typeof(p->'events') <> 'object' then raise exception 'Choose which events are spoken.'; end if;
    select voice_events into v_events from orgs where id = p_org;
    for k in select jsonb_object_keys(p->'events') loop
      if k not in ('payment_received', 'sale_recorded') then raise exception 'Unknown event %.', k; end if;
      if jsonb_typeof(p->'events'->k) <> 'boolean' then raise exception 'Say yes or no for %.', k; end if;
      v_events := v_events || jsonb_build_object(k, (p->'events'->>k)::boolean);
    end loop;
  end if;
  update orgs set
    voice_id = case when p ? 'voice_id' then v_voice else voice_id end,
    voice_lang = coalesce(v_lang, voice_lang),
    voice_events = coalesce(v_events, voice_events)
  where id = p_org;
  return public.voice_settings(p_org);
end $function$;

-- public.set_tax_autopay: the caller changes autopay -> perm_of
CREATE OR REPLACE FUNCTION public.set_tax_autopay(p_org uuid, p_on boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'owner') or private.perm_of(m, 'manage_settings')) then raise exception 'Only the owner changes this.' using errcode = '42501'; end if;
  update orgs set tax_autopay = coalesce(p_on, true) where id = p_org;
  return jsonb_build_object('autopay', coalesce(p_on, true));
end $function$;

-- public.set_tax_autopay_penalties: the caller changes autopay -> perm_of
CREATE OR REPLACE FUNCTION public.set_tax_autopay_penalties(p_org uuid, p_on boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'owner') or private.perm_of(m, 'manage_settings')) then raise exception 'Only the owner changes this.' using errcode = '42501'; end if;
  update orgs set tax_autopay_penalties = coalesce(p_on, true) where id = p_org;
  return jsonb_build_object('autopay_penalties', coalesce(p_on, true));
end $function$;

-- public.set_transfer_settings: only the owner changes payment settings -> perm_of
CREATE OR REPLACE FUNCTION public.set_transfer_settings(p_org uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; v_name text := nullif(regexp_replace(trim(coalesce(p->>'name', '')), '\s+', ' ', 'g'), '');
begin
  m := private.require(p_org, null);
  if not private.perm_of(m, 'owner') then raise exception 'Only the owner changes payment settings.' using errcode = '42501'; end if;
  if p ? 'mode' and coalesce(p->>'mode', '') not in ('wallet', 'one_time') then raise exception 'Choose the wallet number or a one-time account.'; end if;
  if v_name is not null and (length(v_name) < 2 or length(v_name) > 30) then raise exception 'The name on one-time accounts has 2 to 30 characters.'; end if;
  if v_name ~ '[<>{}\\/]' then raise exception 'Leave out slashes and brackets in the name.'; end if;
  update orgs set transfer_mode = coalesce(nullif(p->>'mode', ''), transfer_mode),
    transfer_name = case when p ? 'name' then case when v_name = private.transfer_short(name) then null else v_name end else transfer_name end
  where id = p_org;
  return public.transfer_settings(p_org);
end $function$;

-- public.set_vat_charging: only the owner turns VAT on or off -> perm_of
CREATE OR REPLACE FUNCTION public.set_vat_charging(p_org uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; st jsonb; v_charge boolean := (p->>'charge')::boolean;
begin
  m := private.require(p_org, null);
  if not private.perm_of(m, 'owner') then raise exception 'Only the owner turns VAT on or off.' using errcode = '42501'; end if;
  if v_charge is null then raise exception 'Say whether the business charges VAT.'; end if;
  st := private.vat_small_status(p_org);
  if not v_charge and not (st->>'small')::boolean then
    raise exception 'Only a small company (turnover up to ₦100 million, fixed assets up to ₦250 million, no professional services) may stop charging VAT.';
  end if;
  if not v_charge and (st->>'crossed')::boolean then raise exception 'Turnover this year is above ₦100 million, so VAT must be charged.'; end if;
  update orgs set vat_registered = v_charge, vat_opt_in = v_charge and (st->>'small')::boolean where id = p_org;
  return public.vat_status(p_org);
end $function$;

-- public.subscription_cancel: the owner or an admin changes the plan -> perm_of
CREATE OR REPLACE FUNCTION public.subscription_cancel(p_org uuid, p_on boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; s public.subscriptions;
begin
  m := private.require(p_org, 'manage_settings');
  if not (m.role in ('owner', 'admin') or m.acts_as_owner) then raise exception 'Only the owner or an admin of the business changes its plan.' using errcode = '42501'; end if;
  select * into s from subscriptions where org_id = p_org for update;
  if not found or s.plan_id = private.default_plan_id() then raise exception 'The business is on the standard plan; there is nothing to cancel.'; end if;
  update subscriptions set cancel_at_period_end = p_on, next_plan_id = case when p_on then null else next_plan_id end, updated_at = now() where org_id = p_org;
  return public.subscription_state(p_org);
end $function$;

-- public.subscription_method: the owner or an admin changes the plan -> perm_of
CREATE OR REPLACE FUNCTION public.subscription_method(p_org uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; v_card uuid;
begin
  m := private.require(p_org, 'manage_settings');
  if not (m.role in ('owner', 'admin') or m.acts_as_owner) then raise exception 'Only the owner or an admin of the business changes its plan.' using errcode = '42501'; end if;
  if p->>'method' in ('card', 'wallet') and exists (select 1 from subscriptions where org_id = p_org and paid_by is not null) then
    raise exception 'Your accountant pays for Counta. To pay for it yourself, choose a plan above.';
  end if;
  if nullif(p->>'remove_card_id', '') is not null then
    update subscription_cards set active = false where id = (p->>'remove_card_id')::uuid and org_id = p_org;
    update subscriptions set card_id = null, pay_method = case when pay_method = 'card' then null else pay_method end, updated_at = now()
    where org_id = p_org and card_id = (p->>'remove_card_id')::uuid;
  end if;
  if p->>'method' in ('card', 'wallet') then
    select id into v_card from subscription_cards where org_id = p_org and active order by created_at desc limit 1;
    if p->>'method' = 'card' and v_card is null then raise exception 'Add a card first: pay for the plan by card once, and Counta keeps it for renewals.'; end if;
    update subscriptions set pay_method = p->>'method', card_id = case when p->>'method' = 'card' then v_card else card_id end, updated_at = now() where org_id = p_org;
  end if;
  return public.subscription_state(p_org);
end $function$;

-- public.subscription_start: the owner or an admin changes the plan -> perm_of
CREATE OR REPLACE FUNCTION public.subscription_start(p_org uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; pl public.plans; cur public.plans; s public.subscriptions; v_billing text := coalesce(nullif(p->>'billing', ''), 'month');
  v_method text := nullif(p->>'method', ''); v_price numeric; v_cur_price numeric; c public.subscription_charges; v_card uuid; v_bal numeric;
begin
  m := private.require(p_org, 'manage_settings');
  if not (m.role in ('owner', 'admin') or m.acts_as_owner) then raise exception 'Only the owner or an admin of the business changes its plan.' using errcode = '42501'; end if;
  if (select is_sample from orgs where id = p_org) then raise exception 'The sample business stays on its plan.'; end if;
  if v_billing not in ('month', 'year') then raise exception 'Pay monthly or yearly.'; end if;
  select * into s from subscriptions where org_id = p_org for update;
  select * into cur from plans where id = private.org_plan_id(p_org);
  select * into pl from plans where id = nullif(p->>'plan_id', '')::uuid and active and (public or id = cur.id);
  if not found then raise exception 'Choose a plan.'; end if;
  v_price := private.plan_price(pl, v_billing);
  if pl.id = cur.id and coalesce(s.billing, 'month') = v_billing and coalesce(s.status, 'active') <> 'past_due' and not coalesce(s.cancel_at_period_end, false)
     and s.next_plan_id is null and (v_price = 0 or s.pay_method is not null) and s.paid_by is null then
    raise exception 'The business is on % already.', pl.name;
  end if;

  -- A free plan starts at once.
  if v_price = 0 then
    insert into subscriptions (org_id, plan_id, status, billing, pay_method, current_period_start, current_period_end)
    values (p_org, pl.id, 'active', v_billing, null, now(), now() + case when v_billing = 'year' then interval '1 year' else interval '1 month' end)
    on conflict (org_id) do update set plan_id = excluded.plan_id, status = 'active', billing = excluded.billing, pay_method = null, card_id = null,
      current_period_start = excluded.current_period_start, current_period_end = excluded.current_period_end, trial_ends_at = null,
      cancel_at_period_end = false, next_plan_id = null, next_billing = null, past_due_since = null, retry_at = null, attempts = 0, paid_by = null, updated_at = now();
    update subscription_charges set status = 'cancelled', updated_at = now() where org_id = p_org and status = 'pending';
    return jsonb_build_object('action', 'done', 'state', public.subscription_state(p_org));
  end if;

  if coalesce(v_method, '') not in ('card', 'wallet') then raise exception 'Pay by card or from the wallet.'; end if;
  select id into v_card from subscription_cards where org_id = p_org and active order by (id = s.card_id) desc, created_at desc limit 1;
  -- The business paying for itself again: the accountant's card is not used for it.
  if s.paid_by is not null then v_card := null; s.card_id := null; end if;

  -- A first trial of a plan with one: no charge until it ends.
  if pl.trial_days > 0 and not coalesce(s.trial_used, false) and not exists (select 1 from subscription_charges where org_id = p_org and status = 'successful') then
    insert into subscriptions (org_id, plan_id, status, billing, pay_method, card_id, current_period_start, current_period_end, trial_ends_at, trial_used)
    values (p_org, pl.id, 'trialing', v_billing, v_method, case when v_method = 'card' then v_card end, now(), now() + make_interval(days => pl.trial_days),
      now() + make_interval(days => pl.trial_days), true)
    on conflict (org_id) do update set plan_id = excluded.plan_id, status = 'trialing', billing = excluded.billing, pay_method = excluded.pay_method,
      card_id = excluded.card_id, current_period_start = excluded.current_period_start, current_period_end = excluded.current_period_end,
      trial_ends_at = excluded.trial_ends_at, trial_used = true, cancel_at_period_end = false, next_plan_id = null, next_billing = null,
      past_due_since = null, retry_at = null, attempts = 0, paid_by = null, updated_at = now();
    return jsonb_build_object('action', 'done', 'trial', true, 'state', public.subscription_state(p_org));
  end if;

  -- A cheaper plan while a paid period runs: it starts when the period ends.
  v_cur_price := private.plan_price(cur, coalesce(s.billing, 'month'));
  if s.status = 'active' and s.current_period_end > now() and v_cur_price > 0 and not coalesce(s.comp, false)
     and v_price < private.plan_price(cur, v_billing) then
    update subscriptions set next_plan_id = pl.id, next_billing = v_billing, pay_method = v_method, card_id = coalesce(v_card, card_id),
      cancel_at_period_end = false, paid_by = null, updated_at = now() where org_id = p_org;
    return jsonb_build_object('action', 'scheduled', 'at', s.current_period_end, 'state', public.subscription_state(p_org));
  end if;

  if v_method = 'wallet' then
    select private.wallet_balance(w.id) - coalesce((select sum(amount + fee) from payouts where wallet_id = w.id and status in ('approved', 'processing', 'pending_approval')), 0)
      into v_bal from wallets w join orgs o on o.id = w.org_id where w.org_id = p_org and w.rail = o.payment_rail and w.status = 'active';
    if v_bal is null then raise exception 'Open the business wallet in Payments first, or pay by card.'; end if;
    if v_bal < v_price then
      raise exception 'The wallet has ₦% available and the plan costs ₦%. Fund the wallet or pay by card.', to_char(v_bal, 'FM999,999,999,990.00'),
        to_char(v_price, 'FM999,999,999,990.00');
    end if;
  end if;
  -- The same choice made again within half an hour uses the charge already waiting.
  select * into c from subscription_charges where org_id = p_org and kind = 'start' and status = 'pending' and plan_id = pl.id and billing = v_billing
    and method = v_method and created_at > now() - interval '30 minutes' order by created_at desc limit 1;
  if not found then
    update subscription_charges set status = 'cancelled', updated_at = now() where org_id = p_org and kind = 'start' and status = 'pending';
    insert into subscription_charges (org_id, plan_id, billing, amount, method, kind, card_id, tx_ref, requested_by)
    values (p_org, pl.id, v_billing, v_price, v_method, 'start', case when v_method = 'card' and coalesce((p->>'use_saved')::boolean, true) then v_card end,
      'SUB-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)), m.id)
    returning * into c;
  end if;
  return jsonb_build_object('action', case when v_method = 'wallet' then 'wallet' when c.card_id is not null then 'charge_card' else 'checkout' end,
    'charge_id', c.id, 'tx_ref', c.tx_ref, 'amount', c.amount);
end $function$;

-- public.subscription_state: can_change -> perm_of
CREATE OR REPLACE FUNCTION public.subscription_state(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; v_plan uuid; k text; v_ents jsonb := '[]'::jsonb; w record;
begin
  m := private.require(p_org, 'manage_settings');
  v_plan := private.org_plan_id(p_org);
  for k in select key from plan_modules where active order by sort loop
    v_ents := v_ents || jsonb_build_array(private.entitlement(p_org, k, true));
  end loop;
  select wl.id, private.wallet_balance(wl.id) bal into w from wallets wl join orgs o on o.id = wl.org_id
  where wl.org_id = p_org and wl.rail = o.payment_rail and wl.status = 'active' limit 1;
  return jsonb_build_object(
    'plan', private.plan_json(v_plan), 'subscription', private.sub_json(p_org), 'entitlements', v_ents,
    'plans', (select coalesce(jsonb_agg(private.plan_json(p.id) order by p.sort, p.price_month), '[]'::jsonb) from plans p
              where p.active and (p.public or p.id = v_plan)),
    'charges', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'at', c.created_at, 'plan', pl.name, 'billing', c.billing, 'amount', c.amount,
        'method', c.method, 'kind', c.kind, 'status', c.status, 'error', c.error, 'paid_at', c.paid_at, 'tx_ref', c.tx_ref) order by c.created_at desc), '[]'::jsonb)
      from (select * from subscription_charges where org_id = p_org order by created_at desc limit 24) c join plans pl on pl.id = c.plan_id),
    'wallet', case when w.id is not null then jsonb_build_object('available', w.bal) end,
    'can_change', (m.role in ('owner', 'admin') or m.acts_as_owner), 'is_sample', (select is_sample from orgs where id = p_org));
end $function$;

-- public.svc_bujeti_invoices: who records Bujeti invoices -> org_contact
CREATE OR REPLACE FUNCTION public.svc_bujeti_invoices(p_integration uuid, p_list jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare i public.integrations; o public.orgs; m public.members; x jsonb; it public.bujeti_items; v_code text; v_class text; v_cur text; v_total numeric; v_vat numeric;
  v_day date; v_start date; v_cust uuid; v_email text; v_name text; s public.sales; col public.collections; v_bank uuid; v_msg text; v_ok boolean; v_paid_at timestamptz;
  r jsonb := jsonb_build_object('recorded', 0, 'paid', 0, 'skipped', 0, 'failed', 0, 'seen', 0); v_no text; v_due date; v_known boolean;
begin
  select * into i from integrations where id = p_integration and provider = 'bujeti' and status in ('active', 'error');
  if not found or jsonb_typeof(p_list) <> 'array' then return r; end if;
  select * into o from orgs where id = i.org_id;
  m := private.org_contact(i.org_id);
  v_start := private.bujeti_start(i.org_id);
  v_bank := private.integration_account(i, m.id);
  for x in select value from jsonb_array_elements(p_list) order by value->>'issued_at', value->>'code' limit 2000 loop
    v_code := nullif(left(trim(x->>'code'), 60), '');
    continue when v_code is null or length(v_code) < 4;
    r := jsonb_set(r, '{seen}', to_jsonb((r->>'seen')::int + 1));
    v_class := private.bujeti_invoice_class(x->>'status');
    v_cur := upper(left(coalesce(nullif(trim(x->>'currency'), ''), 'NGN'), 3));
    v_total := round(abs(coalesce(private.num(x->>'amount'), 0)), 2);
    v_vat := round(abs(coalesce(private.num(x->>'vat_amount'), 0)), 2);
    v_day := private.local_day(i.org_id, least(coalesce(nullif(x->>'issued_at', '')::timestamptz, now()), now()));
    v_no := nullif(left(trim(coalesce(x->>'number', '')), 60), '');
    v_msg := null; v_ok := false;
    select * into it from bujeti_items where org_id = i.org_id and kind = 'invoice' and code = v_code for update;
    v_known := found;
    if v_known and it.status = 'recorded' and it.sale_id is not null then
      select * into s from sales where id = it.sale_id;
      -- Paid since Counta recorded it.
      if v_class = 'paid' and it.collection_id is null and s.status in ('open', 'partially_paid') then
        begin
          v_paid_at := least(coalesce(nullif(x->>'paid_at', '')::timestamptz, now()), now());
          col := private.add_collection(i.org_id, s.customer_id, round(s.total - s.amount_paid - s.credited, 2), 'transfer',
            jsonb_build_object('bank_account_id', v_bank, 'provider_ref', 'bujeti-inv:' || v_code, 'reference', left(coalesce(v_no, v_code), 80),
              'received_at', v_paid_at, 'spread', false, 'note', 'Paid through Bujeti'), m, 'confirmed', array[s.id]);
          update bujeti_items set collection_id = col.id, bujeti_status = left(x->>'status', 40), updated_at = now() where org_id = i.org_id and kind = 'invoice' and code = v_code;
          insert into integration_events (integration_id, org_id, external_id, status, amount, sale_id, message)
          values (i.id, i.org_id, 'bujeti-paid:' || v_code, 'recorded', col.amount, s.id, 'Paid through Bujeti')
          on conflict (integration_id, external_id) do nothing;
          r := jsonb_set(r, '{paid}', to_jsonb((r->>'paid')::int + 1));
        exception when others then
          update bujeti_items set message = left('The payment was not recorded: ' || sqlerrm, 400), updated_at = now() where org_id = i.org_id and kind = 'invoice' and code = v_code;
        end;
      elsif v_class = 'void' and it.data->>'void_noticed' is null then
        update bujeti_items set data = data || '{"void_noticed": true}'::jsonb, bujeti_status = left(x->>'status', 40),
          message = 'Cancelled in Bujeti. Void ' || s.number || ' in Counta if it should not stand.', updated_at = now()
        where org_id = i.org_id and kind = 'invoice' and code = v_code;
        perform private.notify_perm(i.org_id, 'record_sales', 'books', 'Invoice cancelled in Bujeti', s.number || ' was cancelled in Bujeti. Void it in Counta if it should not stand.',
          '/sell/sales?open=' || s.id, 'bujeti-void-' || v_code);
      end if;
      continue;
    end if;
    continue when v_known and it.status = 'skipped' and v_class = it.data->>'class';
    if v_class in ('draft', 'void') then continue; end if;
    if v_cur <> 'NGN' then v_msg := 'Invoiced in ' || v_cur || '. Counta records naira invoices from Bujeti; record this one by hand.';
    elsif v_day < v_start then continue;
    elsif v_total <= 0 then v_msg := 'Nothing was invoiced.';
    elsif v_vat >= v_total then v_msg := 'The VAT is more than the invoice.';
    end if;
    if v_msg is null then
      begin
        -- The customer: one the business already has (by email, then name), or a new one.
        v_email := nullif(lower(trim(x->'customer'->>'email')), '');
        if v_email is not null and v_email !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' then v_email := null; end if;
        v_name := nullif(left(trim(regexp_replace(coalesce(x->'customer'->>'name', ''), '\s+', ' ', 'g')), 120), '');
        v_cust := null;
        if v_email is not null then select id into v_cust from customers where org_id = i.org_id and not archived and not is_walk_in and lower(email) = v_email order by created_at limit 1; end if;
        if v_cust is null and v_name is not null then select id into v_cust from customers where org_id = i.org_id and not archived and not is_walk_in and lower(name) = lower(v_name) order by created_at limit 1; end if;
        if v_cust is null then
          v_cust := private.upsert_customer(i.org_id, jsonb_strip_nulls(jsonb_build_object('name', coalesce(v_name, split_part(v_email, '@', 1), 'Bujeti customer'), 'email', v_email)), m);
        end if;
        v_due := greatest(coalesce(private.local_day(i.org_id, nullif(x->>'due_date', '')::timestamptz), v_day), v_day);
        -- One line for the invoice. Bujeti's VAT, when it shows any, stays as it was; an invoice with none is taken as including VAT
        -- for a business registered for VAT, as for the other tools.
        s := private.create_sale(i.org_id, jsonb_strip_nulls(jsonb_build_object('doc_type', 'invoice', 'status', 'issue', 'channel', 'invoice',
          'customer_id', v_cust, 'issue_date', v_day, 'recorded_at', private.line_time(i.org_id, v_day), 'due_date', v_due,
          'location_id', nullif(i.settings->>'location_id', ''), 'reference', left(coalesce(v_no, v_code), 80),
          'notes', left('Bujeti · ' || coalesce(v_no, v_code) || coalesce(' · ' || nullif(trim(x->>'title'), ''), ''), 500),
          'prices_include_vat', not (v_vat > 0),
          'lines', jsonb_build_array(jsonb_build_object('description', left(coalesce(nullif(trim(x->>'title'), ''), nullif(trim(x->>'description'), ''), 'Bujeti invoice ' || coalesce(v_no, v_code)), 300),
            'qty', 1, 'unit_price', case when v_vat > 0 and o.vat_registered then v_total - v_vat else v_total end,
            'vat_treatment', case when o.vat_registered then 'standard' else 'exempt' end)))), m);
        v_msg := case when not o.vat_registered and v_vat > 0 then 'Bujeti showed VAT, but the business is not registered for VAT in Counta; recorded at the full amount.'
          when not o.vat_registered then null
          when v_vat = 0 then 'Bujeti showed no VAT; Counta took the total as including VAT. Change the line if this supply is exempt or zero-rated.'
          when abs(s.total - v_total) > 1 then 'Counta''s total is ' || private.naira(s.total) || '; Bujeti''s was ' || private.naira(v_total) || '. Check the VAT.' end;
        insert into bujeti_items (org_id, kind, code, status, bujeti_status, amount, currency, occurred_on, sale_id, message, data)
        values (i.org_id, 'invoice', v_code, 'recorded', left(x->>'status', 40), v_total, v_cur, v_day, s.id, v_msg,
          jsonb_strip_nulls(jsonb_build_object('number', v_no, 'title', left(x->>'title', 200), 'class', v_class)))
        on conflict (org_id, kind, code) do update set status = 'recorded', bujeti_status = excluded.bujeti_status, amount = excluded.amount, sale_id = excluded.sale_id,
          message = excluded.message, data = bujeti_items.data || excluded.data, updated_at = now();
        update integrations set recorded = recorded + 1 where id = i.id;
        insert into integration_events (integration_id, org_id, external_id, status, amount, sale_id, message)
        values (i.id, i.org_id, 'bujeti-inv:' || v_code, 'recorded', s.total, s.id, left(coalesce(v_msg, 'Invoice ' || coalesce(v_no, v_code) || ' from Bujeti'), 400))
        on conflict (integration_id, external_id) do update set status = excluded.status, amount = excluded.amount, sale_id = excluded.sale_id, message = excluded.message, created_at = now();
        r := jsonb_set(r, '{recorded}', to_jsonb((r->>'recorded')::int + 1));
        v_ok := true;
        if v_class = 'paid' then
          v_paid_at := least(coalesce(nullif(x->>'paid_at', '')::timestamptz, now()), now());
          col := private.add_collection(i.org_id, s.customer_id, s.total, 'transfer',
            jsonb_build_object('bank_account_id', v_bank, 'provider_ref', 'bujeti-inv:' || v_code, 'reference', left(coalesce(v_no, v_code), 80),
              'received_at', greatest(v_paid_at, private.line_time(i.org_id, v_day)), 'spread', false, 'note', 'Paid through Bujeti'), m, 'confirmed', array[s.id]);
          update bujeti_items set collection_id = col.id where org_id = i.org_id and kind = 'invoice' and code = v_code;
          r := jsonb_set(r, '{paid}', to_jsonb((r->>'paid')::int + 1));
        end if;
      exception when others then
        v_msg := left(sqlerrm, 300); v_ok := false;
      end;
    end if;
    if not v_ok then
      insert into bujeti_items (org_id, kind, code, status, bujeti_status, amount, currency, occurred_on, message, data)
      values (i.org_id, 'invoice', v_code, case when v_msg like 'Invoiced in%' or v_msg = 'Nothing was invoiced.' then 'skipped' else 'failed' end, left(x->>'status', 40),
        v_total, v_cur, v_day, v_msg, jsonb_strip_nulls(jsonb_build_object('number', v_no, 'class', v_class)))
      on conflict (org_id, kind, code) do update set status = excluded.status, bujeti_status = excluded.bujeti_status, message = excluded.message, data = bujeti_items.data || excluded.data, updated_at = now();
      insert into integration_events (integration_id, org_id, external_id, status, amount, message)
      values (i.id, i.org_id, 'bujeti-inv:' || v_code, case when v_msg like 'Invoiced in%' or v_msg = 'Nothing was invoiced.' then 'skipped' else 'failed' end, v_total,
        left('Invoice ' || coalesce(v_no, v_code) || ': ' || v_msg, 400))
      on conflict (integration_id, external_id) do update set status = excluded.status, amount = excluded.amount, message = excluded.message, created_at = now();
      r := jsonb_set(r, array[case when v_msg like 'Invoiced in%' or v_msg = 'Nothing was invoiced.' then 'skipped' else 'failed' end],
        to_jsonb((r->>(case when v_msg like 'Invoiced in%' or v_msg = 'Nothing was invoiced.' then 'skipped' else 'failed' end))::int + 1));
    end if;
  end loop;
  return r;
end $function$;

-- public.svc_bujeti_payments: who the Bujeti account is made by -> org_contact
CREATE OR REPLACE FUNCTION public.svc_bujeti_payments(p_integration uuid, p_list jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare i public.integrations; x jsonb; it public.bujeti_items; v_code text; v_class text; v_amt numeric; v_fee numeric; v_cur text; v_day date; v_start date;
  c public.bujeti_categories; v_vendor uuid; v_msg text; v_stage text; v_ai boolean := false; v_wait int := 0; v_inv public.bujeti_items;
  r jsonb := jsonb_build_object('recorded', 0, 'waiting', 0, 'pending', 0, 'skipped', 0, 'failed', 0, 'reversed', 0, 'seen', 0);
  bump text;
begin
  select * into i from integrations where id = p_integration and provider = 'bujeti' and status in ('active', 'error');
  if not found then return jsonb_build_object('status', 'skipped', 'message', 'The connection is paused or gone.'); end if;
  if jsonb_typeof(p_list) <> 'array' then return r; end if;
  v_start := private.bujeti_start(i.org_id);
  perform private.integration_account(i, coalesce(i.connected_by, (private.org_contact(i.org_id)).id));
  for x in select value from jsonb_array_elements(p_list) order by value->>'at', value->>'code' limit 1000 loop
    bump := null; v_msg := null;
    v_code := nullif(left(trim(x->>'code'), 60), '');
    continue when v_code is null or length(v_code) < 4;
    r := jsonb_set(r, '{seen}', to_jsonb((r->>'seen')::int + 1));
    v_class := private.bujeti_class(x->>'status');
    v_amt := round(abs(coalesce(private.num(x->>'amount'), 0)), 2);
    v_fee := round(abs(coalesce(private.num(x->>'fee'), 0)), 2);
    v_cur := upper(left(coalesce(nullif(trim(x->>'currency'), ''), 'NGN'), 3));
    v_day := private.local_day(i.org_id, least(coalesce(nullif(x->>'at', '')::timestamptz, now()), now()));
    select * into it from bujeti_items where org_id = i.org_id and kind = 'payment' and code = v_code for update;

    if found then
      -- Known already: only a change of status matters.
      if it.status = 'recorded' then
        if v_class in ('reversed', 'failed') and it.reversal_line_id is null and it.bank_line_id is not null then
          perform private.bujeti_reverse(i.org_id, v_code); bump := 'reversed';
        end if;
        continue when bump is null;
      elsif it.status in ('skipped') or (it.status = 'waiting' and v_class = 'settled') then
        if it.status = 'waiting' and nullif(x->'category'->>'code', '') is distinct from it.category_code and nullif(x->'category'->>'code', '') is not null then
          c := private.bujeti_category(i.org_id, x->'category');
          update bujeti_items set category_code = c.code, updated_at = now() where org_id = i.org_id and kind = 'payment' and code = v_code;
          if c.confirmed_at is not null then perform private.bujeti_book(i.org_id, v_code); bump := 'recorded'; end if;
        end if;
        continue when bump is null;
      elsif it.status = 'waiting' and v_class in ('reversed', 'failed') then
        update bujeti_items set status = 'skipped', bujeti_status = left(x->>'status', 40), message = 'Not paid in the end: ' || coalesce(x->>'status', 'cancelled'), updated_at = now()
        where org_id = i.org_id and kind = 'payment' and code = v_code;
        bump := 'skipped';
      end if;
    end if;

    if bump is null then
      c := null; v_vendor := null;
      if jsonb_typeof(x->'category') = 'object' then c := private.bujeti_category(i.org_id, x->'category'); end if;
      if x->'recipient'->>'kind' = 'vendor' then v_vendor := private.bujeti_vendor(i.org_id, x->'recipient'); end if;
      if v_class = 'settled' then
        if v_cur <> 'NGN' then v_msg := 'Paid in ' || v_cur || '. Counta records naira payments from Bujeti; record this one by hand.';
        elsif v_day < v_start then v_msg := 'Before ' || to_char(v_start, 'FMDD Mon YYYY') || ', when Counta''s books from Bujeti start.';
        elsif v_amt <= 0 then v_msg := 'Nothing was paid.';
        end if;
        -- Money in for a Bujeti invoice Counta recorded with the invoice.
        if v_msg is null then
          select * into v_inv from bujeti_items b2 where b2.org_id = i.org_id and b2.kind = 'invoice' and b2.status = 'recorded' and b2.collection_id is not null
            and length(coalesce(b2.data->>'number', '')) >= 3 and abs(b2.amount - v_amt) < 1
            and position(upper(b2.data->>'number') in upper(coalesce(x->>'narration', '') || ' ' || coalesce(x->>'description', ''))) > 0 limit 1;
          if v_inv.code is not null then v_msg := 'The payment for Bujeti invoice ' || (v_inv.data->>'number') || ', recorded with the invoice.'; end if;
        end if;
      end if;
      insert into bujeti_items (org_id, kind, code, status, bujeti_status, category_code, amount, fee, currency, occurred_on, vendor_id, message, data)
      values (i.org_id, 'payment', v_code,
        case when v_msg is not null then 'skipped' when v_class = 'settled' then 'waiting' when v_class in ('failed', 'reversed') then 'skipped' else 'pending' end,
        left(x->>'status', 40), c.code, v_amt, v_fee, v_cur, v_day, v_vendor,
        coalesce(v_msg, case when v_class in ('failed', 'reversed') then 'Not paid: ' || coalesce(x->>'status', 'failed') || ' in Bujeti'
                             when v_class = 'unknown' then 'Bujeti says "' || left(x->>'status', 30) || '": Counta waits until it is paid' end),
        jsonb_strip_nulls(jsonb_build_object('narration', left(x->>'narration', 300), 'description', left(x->>'description', 300), 'at', x->>'at',
          'recipient', x->'recipient', 'payer', left(x->>'payer', 120), 'assets', nullif(coalesce(private.num(x->>'assets'), 0), 0))))
      on conflict (org_id, kind, code) do update set status = excluded.status, bujeti_status = excluded.bujeti_status, category_code = excluded.category_code,
        amount = excluded.amount, fee = excluded.fee, currency = excluded.currency, occurred_on = excluded.occurred_on, vendor_id = excluded.vendor_id,
        message = excluded.message, data = bujeti_items.data || excluded.data, updated_at = now()
      returning * into it;
      if it.status = 'waiting' then
        if c.code is null or c.confirmed_at is not null then
          v_stage := private.bujeti_book(i.org_id, v_code);
          if v_stage is null then v_ai := true; end if;
          bump := 'recorded';
        else
          bump := 'waiting'; v_wait := v_wait + 1;
        end if;
      else
        bump := it.status;
      end if;
      -- What the connection's list shows: payments left out, and why (recorded ones are listed as they are booked; one still
      -- pending in Bujeti, or waiting for its category, is not listed yet).
      if it.status in ('skipped', 'failed') and it.message is not null then
        insert into integration_events (integration_id, org_id, external_id, status, amount, message)
        values (i.id, i.org_id, 'bujeti:' || v_code, it.status, it.amount + coalesce(it.fee, 0), left(it.message, 400))
        on conflict (integration_id, external_id) do update set status = excluded.status, amount = excluded.amount, message = excluded.message, created_at = now();
      end if;
    end if;
    r := jsonb_set(r, array[bump], to_jsonb(coalesce((r->>bump)::int, 0) + 1));
  end loop;
  update integrations set last_event_at = now() where id = i.id and (r->>'seen')::int > 0;
  -- Lines nothing explained go to the bookkeeper agent, as for a bank feed.
  if v_ai then perform private.call_function('atlas', jsonb_build_object('action', 'classify_lines', 'org_id', i.org_id)); end if;
  -- Payments waiting for a category: said once a day at most.
  if v_wait > 0 and not exists (select 1 from notifications where org_id = i.org_id and tag = 'bujeti-categories' and created_at > now() - interval '1 day') then
    perform private.notify_perm(i.org_id, 'keep_books', 'books', 'Bujeti categories to confirm',
      (select count(*) from bujeti_items where org_id = i.org_id and kind = 'payment' and status = 'waiting') || ' Bujeti payments wait until you confirm the account for their category.',
      '/integrations?tool=bujeti', 'bujeti-categories');
  end if;
  return r;
end $function$;

-- public.svc_identity_nin: the person confirming a director's identity -> acts_as_owner
CREATE OR REPLACE FUNCTION public.svc_identity_nin(p_user uuid, p_org uuid, p_last4 text, p_first text, p_middle text, p_last text, p_conversation text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare o public.orgs; v_people jsonb; v_match jsonb; v_self text; v_registered boolean; v_attempts int;
begin
  if not private.acts_as_owner(p_org, p_user) then
    raise exception 'Only the owner confirms a director''s identity.' using errcode = '42501';
  end if;
  select * into o from orgs where id = p_org for update;
  if p_conversation is not null and p_conversation ~ '^[A-Za-z0-9_-]{6,80}$' then
    insert into voice_forget (conversation_id, user_id) values (p_conversation, p_user) on conflict (conversation_id) do nothing;
  end if;
  if o.identity_status in ('verified', 'approved', 'not_required') then
    return jsonb_build_object('verified', true, 'already', true, 'matched', o.identity->>'matched');
  end if;
  v_registered := exists (select 1 from kyc_profiles k where k.org_id = p_org and k.status = 'submitted' and k.source = 'cac');
  v_people := private.identity_people(p_org);
  if not v_registered then
    -- Not on CAC: the NIN must be the account holder's own.
    select coalesce(nullif(trim(raw_user_meta_data->>'full_name'), ''), '') into v_self from auth.users where id = p_user;
    v_people := jsonb_build_array(jsonb_build_object('role', 'owner', 'name', v_self, 'surname', '', 'given', ''));
  end if;
  v_match := private.identity_match(p_first, p_middle, p_last, v_people);
  v_attempts := coalesce((o.identity->>'attempts')::int, 0) + 1;
  if v_match is not null then
    update orgs set identity_status = 'verified', identity = identity || jsonb_build_object('method', 'nin', 'matched', v_match->>'name',
      'matched_role', v_match->>'role', 'last4', right(regexp_replace(coalesce(p_last4, ''), '\D', '', 'g'), 4), 'at', now(), 'by', p_user, 'attempts', v_attempts)
    where id = p_org;
    return jsonb_build_object('verified', true, 'matched', v_match->>'name', 'role', v_match->>'role');
  end if;
  update orgs set identity = identity || jsonb_build_object('attempts', v_attempts, 'last_try', jsonb_build_object('at', now(),
    'last4', right(regexp_replace(coalesce(p_last4, ''), '\D', '', 'g'), 4), 'result', 'no_match')) where id = p_org;
  return jsonb_build_object('verified', false, 'reason', case when not v_registered then 'not_account_holder'
    when jsonb_array_length(v_people) = 0 then 'no_directors_on_record' else 'no_match' end,
    'people', (select coalesce(jsonb_agg(x->>'name'), '[]'::jsonb) from jsonb_array_elements(v_people) x));
end $function$;

-- public.svc_identity_slip: the person adding the NIN slip -> acts_as_owner
CREATE OR REPLACE FUNCTION public.svc_identity_slip(p_user uuid, p_org uuid, p_extract jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare o public.orgs; v_people jsonb; v_match jsonb; v_self text; v_registered boolean; v_is_slip boolean := coalesce((p_extract->>'is_nin_document')::boolean, false);
begin
  if not private.acts_as_owner(p_org, p_user) then
    raise exception 'Only the owner adds the NIN slip.' using errcode = '42501';
  end if;
  select * into o from orgs where id = p_org for update;
  if o.identity->'slip' is null then raise exception 'Add the NIN slip first.'; end if;
  v_registered := exists (select 1 from kyc_profiles k where k.org_id = p_org and k.status = 'submitted' and k.source = 'cac');
  v_people := private.identity_people(p_org);
  if not v_registered then
    select coalesce(nullif(trim(raw_user_meta_data->>'full_name'), ''), '') into v_self from auth.users where id = p_user;
    v_people := jsonb_build_array(jsonb_build_object('role', 'owner', 'name', v_self, 'surname', '', 'given', ''));
  end if;
  v_match := case when v_is_slip then private.identity_match(p_extract->>'first_name', p_extract->>'middle_name', p_extract->>'surname', v_people) end;
  update orgs set
    identity = identity || jsonb_build_object('slip', (identity->'slip') || jsonb_build_object('read', true, 'read_at', now(),
      'name', left(concat_ws(' ', p_extract->>'first_name', p_extract->>'middle_name', p_extract->>'surname'), 160),
      'last4', right(regexp_replace(coalesce(p_extract->>'nin_last4', ''), '\D', '', 'g'), 4), 'is_nin_document', v_is_slip,
      'warnings', coalesce(p_extract->'warnings', '[]'::jsonb)))
      || case when v_match is not null then jsonb_build_object('method', 'slip', 'matched', v_match->>'name', 'matched_role', v_match->>'role',
           'last4', right(regexp_replace(coalesce(p_extract->>'nin_last4', ''), '\D', '', 'g'), 4), 'at', now(), 'by', p_user) else '{}'::jsonb end,
    identity_status = case when v_match is not null then 'verified' else 'review' end
  where id = p_org;
  return private.identity_json(p_org, true);
end $function$;

-- public.svc_integration_sale: who records the tool's sale -> org_contact
CREATE OR REPLACE FUNCTION public.svc_integration_sale(p_integration uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare i public.integrations; o public.orgs; m public.members; s public.sales; v_ext text := left(trim(coalesce(p->>'external_id', '')), 200); v_amt numeric; v_fee numeric;
  v_cust uuid; v_email text; v_phone text; v_name text; x jsonb; v_lines jsonb := '[]'::jsonb; it public.items; v_sum numeric := 0; v_rate numeric; v_q numeric; v_p numeric;
  v_bank uuid; v_at timestamptz; v_msg text; c public.collections; v_ok boolean := false;
begin
  select * into i from integrations where id = p_integration and status in ('active', 'error') for update;
  if not found then return jsonb_build_object('status', 'skipped', 'message', 'The connection is paused or gone.'); end if;
  if v_ext = '' then raise exception 'A sale from % needs its id.', private.integration_name(i.provider); end if;
  -- Recorded already: by this connection, or by an earlier one of the same tool (disconnected and connected again), whose payment
  -- carries the same id. The tools' ids carry their own prefix (ps:, flw:, woo:...), so they cannot clash across tools.
  if exists (select 1 from integration_events where org_id = i.org_id and external_id = v_ext and status = 'recorded')
     or exists (select 1 from collections where org_id = i.org_id and provider_ref = v_ext) then
    return jsonb_build_object('status', 'duplicate', 'sale_id', (select e.sale_id from integration_events e where e.org_id = i.org_id and e.external_id = v_ext
      and e.status = 'recorded' order by e.created_at desc limit 1));
  end if;
  select * into o from orgs where id = i.org_id;
  v_amt := round(coalesce(private.num(p->>'amount'), 0), 2);
  v_fee := round(greatest(coalesce(private.num(p->>'fee'), 0), 0), 2);
  v_at := least(coalesce(nullif(p->>'occurred_at', '')::timestamptz, now()), now());
  begin
    if upper(coalesce(nullif(p->>'currency', ''), 'NGN')) <> 'NGN' then
      v_msg := 'Paid in ' || upper(p->>'currency') || '. Counta records naira payments from connected tools; record this one by hand.';
    elsif v_amt <= 0 then
      v_msg := 'Nothing was paid.';
    elsif v_fee >= v_amt then
      v_msg := 'The fee is more than the payment.';
    end if;
    if v_msg is null then
      -- The business's owner records it (the person who connected the tool may leave; the owner stays).
      m := private.org_contact(i.org_id);
      -- The customer: one the business already has (by email or phone), a new one with the details paid with, or walk-in.
      v_email := nullif(lower(trim(p->'customer'->>'email')), '');
      if v_email is not null and v_email !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' then v_email := null; end if;
      v_phone := private.clean_phone(p->'customer'->>'phone');
      v_name := nullif(left(trim(regexp_replace(coalesce(p->'customer'->>'name', ''), '\s+', ' ', 'g')), 120), '');
      select id into v_cust from customers where org_id = i.org_id and not archived and not is_walk_in
        and ((v_email is not null and lower(email) = v_email) or (v_phone is not null and phone = v_phone)) order by created_at limit 1;
      if v_cust is null and (v_name is not null or v_email is not null) then
        v_cust := private.upsert_customer(i.org_id, jsonb_strip_nulls(jsonb_build_object('name', coalesce(v_name, split_part(v_email, '@', 1)), 'email', v_email, 'phone', v_phone)), m);
      end if;
      -- The lines: products the business sells, matched by SKU or name; anything else as a line with the tool's description.
      v_rate := case when o.vat_registered and not o.prices_include_vat then private.vat_rate(private.local_day(i.org_id, v_at)) else 0 end;
      for x in select value from jsonb_array_elements(case when jsonb_typeof(p->'lines') = 'array' and jsonb_array_length(p->'lines') > 0 then p->'lines'
               else jsonb_build_array(jsonb_build_object('name', coalesce(nullif(trim(p->>'note'), ''), private.integration_name(i.provider) || ' sale'), 'qty', 1, 'unit_price', v_amt)) end) loop
        v_q := greatest(coalesce(round(private.num(x->>'qty'), 3), 1), 0.001);
        v_p := round(coalesce(private.num(x->>'unit_price'), 0), 2);
        it := null;
        if nullif(trim(x->>'sku'), '') is not null then
          select * into it from items where org_id = i.org_id and not archived and (lower(sku) = lower(trim(x->>'sku')) or barcode = trim(x->>'sku')) limit 1;
        end if;
        if it.id is null and nullif(trim(x->>'name'), '') is not null then
          select * into it from items where org_id = i.org_id and not archived and lower(name) = lower(trim(x->>'name')) limit 1;
        end if;
        -- The tool's price includes VAT; a business whose prices exclude VAT records the price before VAT, so the total is what was paid.
        v_p := round(v_p / (1 + case when coalesce(it.vat_treatment, 'standard') = 'standard' then v_rate else 0 end), 2);
        if it.id is not null then
          v_lines := v_lines || jsonb_build_array(jsonb_build_object('item_id', it.id, 'qty', v_q, 'unit_price', v_p));
        else
          v_lines := v_lines || jsonb_build_array(jsonb_build_object('description', left(coalesce(nullif(trim(x->>'name'), ''), private.integration_name(i.provider) || ' sale'), 300),
            'qty', v_q, 'unit_price', v_p, 'vat_treatment', case when o.vat_registered then 'standard' else 'exempt' end));
        end if;
        v_sum := v_sum + v_q * v_p;
      end loop;
      v_bank := private.integration_account(i, m.id);
      s := private.create_sale(i.org_id, jsonb_strip_nulls(jsonb_build_object('doc_type', 'receipt', 'status', 'issue', 'channel', 'online',
        'location_id', nullif(i.settings->>'location_id', ''), 'customer_id', v_cust, 'recorded_at', v_at,
        'reference', left(coalesce(nullif(trim(p->>'reference'), ''), v_ext), 80),
        'notes', left(private.integration_name(i.provider) || ' · ' || coalesce(nullif(trim(p->>'reference'), ''), v_ext) || coalesce(' · ' || nullif(trim(p->>'note'), ''), ''), 500),
        'pay_in_full', 'later', 'lines', v_lines)), m);
      if v_name is not null and v_cust is null then update sales set customer_name = v_name where id = s.id; end if;
      -- Paid: the money is in the tool's account, the fee booked as a payment fee. A kobo or two of rounding stays with the sale.
      c := private.add_collection(i.org_id, s.customer_id, case when abs(v_amt - s.total) <= 1 then s.total else v_amt end,
        case when p->>'method' in ('transfer', 'card') then p->>'method' else 'other' end,
        jsonb_build_object('bank_account_id', v_bank, 'fee', least(v_fee, s.total), 'provider_ref', v_ext, 'reference', left(coalesce(nullif(trim(p->>'reference'), ''), v_ext), 80),
          'received_at', v_at, 'spread', false, 'note', 'Paid through ' || private.integration_name(i.provider)), m, 'confirmed', array[s.id]);
      update sales set settle_later = false where id = s.id;
      select * into s from sales where id = s.id;
      v_ok := true;
    end if;
  exception when others then
    v_msg := left(sqlerrm, 300);
  end;
  insert into integration_events (integration_id, org_id, external_id, status, amount, sale_id, message)
  values (i.id, i.org_id, v_ext, case when v_ok then 'recorded' when v_msg like 'Paid in%' or v_msg = 'Nothing was paid.' then 'skipped' else 'failed' end, v_amt,
    case when v_ok then s.id end, v_msg)
  on conflict (integration_id, external_id) do update set status = excluded.status, amount = excluded.amount, sale_id = excluded.sale_id, message = excluded.message, created_at = now();
  update integrations set last_event_at = now(), recorded = recorded + case when v_ok then 1 else 0 end where id = i.id;
  if v_ok then
    return jsonb_build_object('status', 'recorded', 'sale_id', s.id, 'number', s.number, 'total', s.total, 'customer_id', s.customer_id);
  end if;
  return jsonb_build_object('status', case when v_msg like 'Paid in%' or v_msg = 'Nothing was paid.' then 'skipped' else 'failed' end, 'message', v_msg);
end $function$;

-- public.svc_integration_save: the member connecting a tool (perm_of on the fetched row) -> acts_as_owner
CREATE OR REPLACE FUNCTION public.svc_integration_save(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare i public.integrations; v_org uuid := (p->>'org_id')::uuid; v_prov text := p->>'provider'; m public.members; v_secret uuid; v_hook uuid;
begin
  select * into m from members where id = (p->>'member_id')::uuid and org_id = v_org and status = 'active';
  if not found or not (private.perm_of(m, 'owner') or private.perm_of(m, 'manage_settings')) then raise exception 'Only the owner or someone who manages settings connects tools.'; end if;
  select * into i from integrations where org_id = v_org and provider = v_prov and status <> 'disconnected' for update;
  if nullif(p->>'secret', '') is not null then
    if i.secret_id is not null then perform vault.update_secret(i.secret_id, p->>'secret'); v_secret := i.secret_id;
    else v_secret := vault.create_secret(p->>'secret', 'integration:' || gen_random_uuid()::text, 'A ' || private.integration_name(v_prov) || ' key for ' || v_org::text); end if;
  else v_secret := i.secret_id; end if;
  if nullif(p->>'hook_secret', '') is not null then
    if i.hook_secret_id is not null then perform vault.update_secret(i.hook_secret_id, p->>'hook_secret'); v_hook := i.hook_secret_id;
    else v_hook := vault.create_secret(p->>'hook_secret', 'integration-hook:' || gen_random_uuid()::text, 'A webhook secret for ' || v_org::text); end if;
  else v_hook := i.hook_secret_id; end if;
  if i.id is null then
    insert into integrations (org_id, provider, status, label, settings, secret_id, secret_hint, hook_token_hash, hook_secret_id, connected_by)
    values (v_org, v_prov, 'active', nullif(left(trim(p->>'label'), 80), ''), coalesce(p->'settings', '{}'::jsonb), v_secret, nullif(left(p->>'secret_hint', 12), ''),
      case when nullif(p->>'hook_token', '') is not null then encode(extensions.digest(p->>'hook_token', 'sha256'), 'hex') end, v_hook, m.id)
    returning * into i;
  else
    update integrations set status = 'active', label = coalesce(nullif(left(trim(p->>'label'), 80), ''), label), settings = settings || coalesce(p->'settings', '{}'::jsonb),
      secret_id = v_secret, secret_hint = coalesce(nullif(left(p->>'secret_hint', 12), ''), secret_hint),
      hook_token_hash = case when nullif(p->>'hook_token', '') is not null then encode(extensions.digest(p->>'hook_token', 'sha256'), 'hex') else hook_token_hash end,
      hook_secret_id = v_hook, connected_by = m.id, connected_at = case when status = 'active' then connected_at else now() end, last_error = null, last_error_at = null
    where id = i.id returning * into i;
  end if;
  if v_prov <> 'slack' then perform private.integration_account(i, m.id); select * into i from integrations where id = i.id; end if;
  return private.integration_json(i) || jsonb_build_object('org_id', i.org_id);
end $function$;

-- public.svc_pos_connection_save: the member connecting a POS provider (perm_of on the fetched row) -> acts_as_owner
CREATE OR REPLACE FUNCTION public.svc_pos_connection_save(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare c public.pos_connections; m public.members; v_org uuid := (p->>'org_id')::uuid; v_prov text := p->>'provider'; v_bank uuid; b public.bank_accounts;
  v_key uuid; v_hs uuid; v_hp uuid; v_scopes text[];
begin
  select * into m from members where id = (p->>'member_id')::uuid and org_id = v_org and status = 'active';
  if not found or not private.perm_of(m, 'owner') then raise exception 'Only the owner connects a POS provider.'; end if;
  if (select is_sample from orgs where id = v_org) then raise exception 'The sample business cannot connect a POS provider. Use your own business.'; end if;
  if coalesce(v_prov, '') not in ('moniepoint') then raise exception 'Unknown POS provider.'; end if;
  select coalesce(array_agg(x), '{}') into v_scopes from jsonb_array_elements_text(coalesce(p->'scopes', '[]'::jsonb)) x;
  select * into c from pos_connections where org_id = v_org and provider = v_prov and coalesce(business_ref, '') = coalesce(p->>'business_ref', '')
    and status <> 'removed' for update;
  v_bank := nullif(p->>'bank_account_id', '')::uuid;
  if v_bank is not null and not exists (select 1 from bank_accounts where id = v_bank and org_id = v_org and active and kind = 'bank') then
    raise exception 'Choose one of your bank accounts, or let Counta open one for the terminals.';
  end if;
  v_bank := coalesce(v_bank, c.bank_account_id);
  if v_bank is null then
    b := private.open_bank_account(v_org, 'bank', coalesce(nullif(left(trim(p->>'new_account_name'), 80), ''), private.pos_provider_name(v_prov)),
      jsonb_build_object('bank_name', case v_prov when 'moniepoint' then 'Moniepoint MFB' end, 'account_number', nullif(p->>'account_number', '')), m.id);
    v_bank := b.id;
  end if;
  v_key := private.pos_vault_put(c.key_secret_id, p->>'key', 'A ' || private.pos_provider_name(v_prov) || ' POS key for ' || v_org::text);
  v_hs := private.pos_vault_put(c.hook_secret_id, p->>'hook_secret', 'A ' || private.pos_provider_name(v_prov) || ' webhook secret for ' || v_org::text);
  -- An empty password means the webhook has none (Moniepoint would not set one): the old one must not stay, or every event would be refused.
  if p ? 'hook_password' and coalesce(p->>'hook_password', '') = '' then
    if c.hook_password_secret_id is not null then perform vault.update_secret(c.hook_password_secret_id, ''); end if;
    v_hp := null;
  else
    v_hp := private.pos_vault_put(c.hook_password_secret_id, p->>'hook_password', 'A ' || private.pos_provider_name(v_prov) || ' webhook password for ' || v_org::text);
  end if;
  if c.id is null then
    insert into pos_connections (org_id, provider, label, environment, business_ref, business_name, bank_account_id, status, scopes, key_secret_id, key_hint,
      hook_token_hash, hook_secret_id, hook_password_secret_id, subscription_ref, connected_by)
    values (v_org, v_prov, coalesce(nullif(left(trim(p->>'label'), 80), ''), private.pos_provider_name(v_prov)),
      coalesce(nullif(p->>'environment', ''), 'production'), nullif(left(p->>'business_ref', 64), ''), nullif(left(p->>'business_name', 200), ''), v_bank, 'live',
      v_scopes, v_key, nullif(left(p->>'key_hint', 12), ''),
      case when nullif(p->>'hook_token', '') is not null then encode(extensions.digest(p->>'hook_token', 'sha256'), 'hex') end, v_hs, v_hp,
      nullif(left(p->>'subscription_ref', 64), ''), m.id)
    returning * into c;
  else
    update pos_connections set label = coalesce(nullif(left(trim(p->>'label'), 80), ''), label), environment = coalesce(nullif(p->>'environment', ''), environment),
      business_name = coalesce(nullif(left(p->>'business_name', 200), ''), business_name), bank_account_id = v_bank, status = 'live',
      scopes = case when cardinality(v_scopes) > 0 then v_scopes else scopes end, key_secret_id = v_key, key_hint = coalesce(nullif(left(p->>'key_hint', 12), ''), key_hint),
      hook_token_hash = case when nullif(p->>'hook_token', '') is not null then encode(extensions.digest(p->>'hook_token', 'sha256'), 'hex') else hook_token_hash end,
      hook_secret_id = v_hs, hook_password_secret_id = v_hp, subscription_ref = coalesce(nullif(left(p->>'subscription_ref', 64), ''), subscription_ref),
      connected_by = m.id, connected_at = now(), last_error = null, last_error_at = null
    where id = c.id returning * into c;
  end if;
  return private.pos_conn_json(c) || jsonb_build_object('org_id', c.org_id);
end $function$;

-- public.svc_prism_bill: who writes the Prism bill -> org_contact
CREATE OR REPLACE FUNCTION public.svc_prism_bill(p_org uuid, p_bill jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare b public.bills; m public.members; v_ref text := nullif(trim(p_bill->>'prism_id'), '');
begin
  if v_ref is null then raise exception 'prism_id is required.'; end if;
  select * into b from bills where org_id = p_org and source = 'prism' and external_ref = v_ref;
  if found then return jsonb_build_object('duplicate', true, 'bill', private.bill_json(b.id)); end if;
  m := private.org_contact(p_org);
  b := private.write_bill(p_org, (p_bill - 'id' - 'status') || jsonb_build_object('source', 'prism', 'external_ref', v_ref), m);
  update bills set created_by = null, invoice_tin = nullif(trim(coalesce(p_bill->'vendor'->>'tin', p_bill->>'vendor_tin')), '') where id = b.id;
  perform private.notify_perm(p_org, 'keep_books', 'bill', 'New bill from Prism: ' || (select name from vendors where id = b.vendor_id),
    '₦' || to_char(b.total, 'FM999,999,999,990.00') || coalesce(' · ' || b.vendor_ref, '') || ' · check and approve it', '/purchases/bills?open=' || b.id, 'bill-' || b.id);
  return jsonb_build_object('duplicate', false, 'bill', private.bill_json(b.id));
end $function$;

-- public.svc_si_open: the member uploading a bill (perm_of on the fetched row) -> acts_as_owner
CREATE OR REPLACE FUNCTION public.svc_si_open(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare o public.orgs; m public.members; v_src text := p->>'source'; si public.supplier_invoices; v_ip text := nullif(p->>'ip_hash', ''); v_sub jsonb;
begin
  if v_src = 'portal' then
    select * into o from orgs where invoice_portal_token = p->>'token' and coalesce(p->>'token', '') ~ '^[0-9a-f]{32}$';
    if not found then raise exception 'This invoice link is not valid. Ask the business for its current link.'; end if;
    if not o.invoice_portal_on or o.is_sample or not private.feature_on(o.id, 'supplier_portal') then
      raise exception '% is not taking invoices on this link just now. Send it to them directly.', o.name;
    end if;
    if v_ip is not null and (select count(*) from supplier_invoices where ip_hash = v_ip and created_at > now() - interval '1 hour') >= 10 then
      raise exception 'That is a lot of invoices in an hour. Try again later.';
    end if;
    if (select count(*) from supplier_invoices where org_id = o.id and source = 'portal' and created_at > now() - interval '1 day') >= 100 then
      raise exception '% has received many invoices today. Try again tomorrow, or send it to them directly.', o.name;
    end if;
    v_sub := jsonb_strip_nulls(jsonb_build_object('name', private.si_text(p->'submitter'->>'name', 120), 'email', lower(private.si_text(p->'submitter'->>'email', 160)),
      'phone', private.clean_phone(p->'submitter'->>'phone'), 'note', private.si_text(p->'submitter'->>'note', 500)));
    if v_sub->>'email' is not null and v_sub->>'email' !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Check the email address.'; end if;
    if v_sub->>'email' is null and coalesce(length(v_sub->>'phone'), 0) < 11 then
      raise exception 'Give an email address or a WhatsApp number, so the business can reach you about the invoice.';
    end if;
  elsif v_src = 'upload' then
    select * into o from orgs where id = (p->>'org_id')::uuid;
    if not found then raise exception 'Business not found.'; end if;
    select * into m from members where id = (p->>'member_id')::uuid and org_id = o.id and status = 'active';
    if not found then raise exception 'You are not a member of this business.'; end if;
    if not (private.perm_of(m, 'keep_books') or private.perm_of(m, 'owner')) then raise exception 'Your role does not enter bills.' using errcode = '42501'; end if;
    if coalesce(p->>'path', '') !~ ('^' || o.id::text || '/') or p->>'path' like '%..%' then raise exception 'Upload the invoice first.'; end if;
    v_sub := '{}'::jsonb;
  else
    raise exception 'Unknown source.';
  end if;
  if (select count(*) from supplier_invoices where org_id = o.id and created_at > now() - interval '1 hour') >= 120 then
    raise exception 'Counta is reading many invoices for this business. Try again in an hour.';
  end if;
  insert into supplier_invoices (org_id, number, source, document_path, mime, file_name, file_size, file_sha256, submitted_by, submitter, ip_hash)
  values (o.id, 'SI-' || lpad(private.next_no(o.id, 'SI', 1)::text, 5, '0'), v_src,
    coalesce(nullif(p->>'path', ''), o.id::text || '/bills/supplier-' || replace(gen_random_uuid()::text, '-', '') || '.bin'),
    private.si_text(p->>'mime', 60), private.si_text(p->>'file_name', 160), nullif(p->>'file_size', '')::int, nullif(p->>'sha256', ''), m.id, v_sub, v_ip)
  returning * into si;
  return jsonb_build_object('id', si.id, 'org_id', o.id, 'number', si.number, 'path', si.document_path, 'business', o.name,
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name) order by a.code), '[]'::jsonb)
      from (select code, name from accounts union select code, name from org_accounts where org_id = o.id) a
      where a.code ~ '^(5|6|15|12)' and private.bill_account_ok(o.id, a.code)),
    'wht', (select jsonb_agg(jsonb_build_object('code', code, 'name', name) order by sort) from wht_rates where not exemption and code <> 'none'),
    -- What the business does, and what it keeps in stock, so the reader can tell stock from assets and expenses.
    'profile', jsonb_strip_nulls(jsonb_build_object('industry', o.industry, 'activity', o.principal_activity, 'offering', o.offering, 'legal_form', o.legal_form,
      'capitalisation_threshold', o.capitalisation_threshold)),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'type', i.item_type, 'unit', i.purchase_unit, 'pack', i.pack_size,
        'selling_unit', i.selling_unit, 'category', i.category, 'brand', i.brand) order by i.recent desc nulls last, i.name), '[]'::jsonb)
      from (select i.*, (select max(mv.recorded_at) from movements mv where mv.item_id = i.id) recent from items i
            where i.org_id = o.id and not i.archived and i.item_type is distinct from 'service'
            order by recent desc nulls last, i.name limit 400) i));
end $function$;

-- public.svc_subscription_charge: the checkout email (an owner place in any status, as before, or the contact) -> org_contact
CREATE OR REPLACE FUNCTION public.svc_subscription_charge(p_charge uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select jsonb_build_object('charge', to_jsonb(c) - 'journal_id', 'plan', jsonb_build_object('name', pl.name, 'code', pl.code),
    'org', jsonb_build_object('id', o.id, 'name', o.name, 'phone', o.phone,
      'email', coalesce((select coalesce(mb.email, u.email) from members mb left join auth.users u on u.id = mb.user_id where mb.org_id = o.id and (mb.role = 'owner' or mb.id = (private.org_contact(o.id)).id)
        order by mb.created_at limit 1), o.email)),
    'card', (select jsonb_build_object('token', k.token, 'email', k.email, 'last4', k.last4) from subscription_cards k
             where k.active and (case when c.practice_id is not null then k.practice_id = c.practice_id else k.org_id = c.org_id end)
               and (c.card_id is null or k.id = c.card_id) order by (k.id = c.card_id) desc, k.created_at desc limit 1),
    'payer', case when c.practice_id is not null then (select jsonb_build_object('kind', 'practice', 'id', pr.id, 'name', pr.name,
        'email', coalesce(nullif(pr.email, ''), (select u.email from auth.users u where u.id = pr.created_by)), 'phone', pr.phone) from practices pr where pr.id = c.practice_id) end,
    'return_path', case when c.practice_id is not null then '/practice/billing' else '/settings/subscription' end,
    'wallet', (select jsonb_build_object('id', w.id, 'account_ref', w.account_ref, 'rail', w.rail) from wallets w
               where w.org_id = c.org_id and w.rail = o.payment_rail and w.status = 'active' limit 1))
  from subscription_charges c join orgs o on o.id = c.org_id join plans pl on pl.id = c.plan_id where c.id = p_charge
$function$;

-- public.svc_tax_instruction_decide: who the tax payment is made for -> org_contact
CREATE OR REPLACE FUNCTION public.svc_tax_instruction_decide(p_id uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare i public.tax_payment_instructions; v_why text; x public.tax_payments; ow public.members; e jsonb;
begin
  select * into i from tax_payment_instructions where id = p_id for update;
  if not found then raise exception 'Not found.'; end if;
  if i.status not in ('received', 'needs_approval') then return jsonb_build_object('decision', 'none', 'status', i.status); end if;
  e := private.tax_expected(i.org_id, i.tax, i.period, i.authority, i.accounting_year);
  update tax_payment_instructions set bank_code = coalesce(nullif(p->>'bank_code', ''), bank_code), resolved_name = nullif(left(coalesce(p->>'resolved_name', ''), 160), ''),
    name_ok = case when jsonb_typeof(p->'name_ok') = 'boolean' then (p->>'name_ok')::boolean end,
    expected = case when e->>'state' = 'paid' then expected else (e->>'amount')::numeric end, updated_at = now()
  where id = i.id returning * into i;
  update tax_payment_instructions set reconciliation = private.instruction_reconcile(i) where id = i.id returning * into i;
  v_why := private.instruction_block(i);
  if v_why = 'expired' then
    update tax_payment_instructions set status = 'expired', reason = 'The account Rev360 gave expired before it was paid. Ask Flux for a new one.', updated_at = now()
    where id = i.id returning * into i;
    perform private.instruction_alert(i, 'expired');
    return jsonb_build_object('decision', 'expired', 'status', 'expired');
  end if;
  if v_why is null then
    ow := private.org_contact(i.org_id);
    x := private.instruction_payment(i, ow.id, true);
    return jsonb_build_object('decision', 'pay', 'status', 'paying', 'payment_id', x.id);
  end if;
  update tax_payment_instructions set status = 'needs_approval', reason = v_why, updated_at = now() where id = i.id returning * into i;
  perform private.instruction_alert(i, 'approve');
  return jsonb_build_object('decision', 'wait', 'status', 'needs_approval', 'reason', v_why);
end $function$;

-- public.svc_tax_transfer_update: who the transfer's journal is posted by -> org_contact
CREATE OR REPLACE FUNCTION public.svc_tax_transfer_update(p_reference text, p_status text, p_error text DEFAULT NULL::text, p_provider_ref text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare tr public.tax_transfers; t public.tax_wallets; w public.wallets; tb public.bank_accounts; wb public.bank_accounts; j public.journals; v_owner public.members;
begin
  select * into tr from tax_transfers where reference = p_reference or (p_reference like reference || '-%') for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown_reference'); end if;
  select * into t from tax_wallets where id = tr.tax_wallet_id;
  select * into w from wallets where id = tr.wallet_id;
  select * into tb from bank_accounts where id = t.bank_account_id;
  select * into wb from bank_accounts where id = w.bank_account_id;
  if p_status = 'sent' then
    if tr.status in ('sent', 'done') then return jsonb_build_object('ok', true, 'duplicate', true); end if;
    v_owner := private.org_contact(tr.org_id);
    if tr.journal_id is null then
      j := private.post_entry(tr.org_id, case when tr.direction = 'in' then 'Tax set aside in the tax wallet' else 'Back from the tax wallet: set aside beyond the tax due' end,
        'tax_wallet', tr.id, v_owner.id, null,
        case when tr.direction = 'in' then jsonb_build_array(
            jsonb_build_object('code', tb.ledger_code, 'debit', tr.amount, 'memo', tr.reference),
            jsonb_build_object('code', wb.ledger_code, 'credit', tr.amount, 'memo', tr.reference))
          else jsonb_build_array(
            jsonb_build_object('code', wb.ledger_code, 'debit', tr.amount, 'memo', tr.reference),
            jsonb_build_object('code', tb.ledger_code, 'credit', tr.amount, 'memo', tr.reference)) end,
        now(), jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'tax_transfer', 'id', tr.id, 'ref', tr.reference))));
    end if;
    update tax_transfers set status = 'sent', sent_at = coalesce(sent_at, now()), error = null, journal_id = coalesce(journal_id, j.id),
      provider_ref = coalesce(nullif(p_provider_ref, ''), provider_ref) where id = tr.id returning * into tr;
    update tax_moves set status = 'done', done_at = now() where transfer_id = tr.id and status = 'sending';
  elsif p_status = 'done' then
    update tax_transfers set status = 'done', done_at = coalesce(done_at, now()) where id = tr.id and status = 'sent';
  elsif p_status = 'failed' then
    -- Refused after the books moved it: the entry is taken back and the moves wait for the next try.
    if tr.journal_id is not null then
      perform private.reverse_entry(tr.journal_id, null, 'Transfer between the wallets failed: ' || coalesce(p_error, ''), null);
      update tax_moves set status = 'sending', done_at = null where transfer_id = tr.id;
    end if;
    update tax_transfers set status = 'failed', journal_id = null, attempts = attempts + 1, error = left(coalesce(p_error, 'The transfer failed.'), 500),
      next_try_at = now() + least(interval '10 minutes' * (attempts + 1), interval '6 hours'),
      provider_ref = coalesce(nullif(p_provider_ref, ''), provider_ref) where id = tr.id returning * into tr;
  elsif p_status = 'waiting' then
    update tax_transfers set error = left(coalesce(p_error, 'Waiting for transfers to be switched on.'), 500), next_try_at = now() + interval '30 minutes'
    where id = tr.id returning * into tr;
  else
    raise exception 'Unknown status.';
  end if;
  return jsonb_build_object('ok', true, 'status', tr.status, 'reference', tr.reference);
end $function$;

-- public.svc_tax_wallet_to_open: the member opening the tax wallet (perm_of on the fetched row) -> acts_as_owner
CREATE OR REPLACE FUNCTION public.svc_tax_wallet_to_open(p_org uuid, p_member uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare o public.orgs; w public.wallets; t public.tax_wallets; pr public.payment_rails; m public.members;
begin
  select * into o from orgs where id = p_org;
  perform private.require_payments_open(p_org);
  select * into m from members where id = p_member and org_id = p_org and status = 'active';
  if m.id is null or not (private.perm_of(m, 'keep_books') or private.perm_of(m, 'make_payments') or private.perm_of(m, 'owner')) then
    raise exception 'Only the owner or someone who keeps the books opens the tax wallet.';
  end if;
  select * into w from wallets where org_id = p_org and rail = o.payment_rail and status = 'active';
  if not found then raise exception 'Open the business wallet first.'; end if;
  select * into pr from payment_rails where code = w.rail and active;
  if not found then raise exception 'Payments are not available for this business yet.'; end if;
  select * into t from tax_wallets where org_id = p_org;
  if found and t.status = 'active' then return jsonb_build_object('tax_wallet', to_jsonb(t), 'ready', true); end if;
  if not found then
    insert into tax_wallets (org_id, rail, status, created_by) values (p_org, w.rail, 'creating', m.id) returning * into t;
  else
    update tax_wallets set status = 'creating', error = null, rail = w.rail where id = t.id returning * into t;
  end if;
  return jsonb_build_object('tax_wallet', to_jsonb(t), 'ready', false, 'rail', to_jsonb(pr) - 'api_key_secret' - 'webhook_secret',
    'org', jsonb_build_object('name', o.name || ' Tax', 'email', o.email, 'phone', o.phone, 'id', o.id, 'purpose', 'tax'));
end $function$;

-- public.svc_wallet_to_open: the member opening the wallet (perm_of on the fetched row) -> acts_as_owner
CREATE OR REPLACE FUNCTION public.svc_wallet_to_open(p_org uuid, p_member uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare o public.orgs; w public.wallets; pr public.payment_rails; m public.members;
begin
  select * into o from orgs where id = p_org;
  perform private.require_payments_open(p_org);
  select * into m from members where id = p_member and org_id = p_org and status = 'active';
  if m.id is null or not (private.perm_of(m, 'keep_books') or private.perm_of(m, 'make_payments') or private.perm_of(m, 'owner')) then
    raise exception 'Only the owner or someone who keeps the books opens the wallet.';
  end if;
  select * into pr from payment_rails where code = o.payment_rail and active;
  if not found then raise exception 'Payments are not available for this business yet.'; end if;
  select * into w from wallets where org_id = p_org and rail = o.payment_rail;
  if found and w.status = 'active' then return jsonb_build_object('wallet', to_jsonb(w), 'ready', true); end if;
  if not found then
    insert into wallets (org_id, rail, status, created_by) values (p_org, o.payment_rail, 'creating', m.id) returning * into w;
  else
    update wallets set status = 'creating', error = null where id = w.id returning * into w;
  end if;
  return jsonb_build_object('wallet', to_jsonb(w), 'ready', false, 'rail', to_jsonb(pr) - 'api_key_secret' - 'webhook_secret',
    'api_key_secret', pr.api_key_secret, 'org', jsonb_build_object('name', o.name, 'email', o.email, 'phone', o.phone, 'id', o.id));
end $function$;

-- public.tax_profile: is_owner -> perm_of
CREATE OR REPLACE FUNCTION public.tax_profile(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members;
begin
  m := private.require(p_org, null);
  return (select jsonb_build_object('legal_form', o.legal_form, 'industry', o.industry, 'tin', o.tin, 'rc_number', o.rc_number,
      'address', coalesce(o.registered_office, o.address), 'state_authority', private.state_code(coalesce(o.registered_office, o.address)),
      'state', (select a.state from tax_authorities a where a.code = private.state_code(coalesce(o.registered_office, o.address))),
      'fiscal_year_start', o.fiscal_year_start, 'books_start', o.books_start, 'commenced_on', o.commenced_on,
      'professional_services', o.professional_services, 'cit_profile', o.cit_profile, 'wvat_agent', o.wvat_agent, 'wht_small_company', o.wht_small_company,
      'vat_registered', o.vat_registered, 'vat_opt_in', o.vat_opt_in,
      'can_edit', private.perm_of(m, 'keep_books'), 'is_owner', private.perm_of(m, 'owner'),
      'authorities', (select jsonb_agg(jsonb_build_object('code', a.code, 'state', a.state, 'name', a.name, 'short_name', a.short_name, 'website', a.website) order by a.sort)
        from tax_authorities a),
      'wht_rates', (select jsonb_agg(to_jsonb(r) order by r.sort) from wht_rates r))
    from orgs o where o.id = p_org);
end $function$;

-- public.transfer_name_check_start: only the owner changes payment settings -> perm_of
CREATE OR REPLACE FUNCTION public.transfer_name_check_start(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; o public.orgs; v_id uuid;
begin
  m := private.require(p_org, null);
  if not private.perm_of(m, 'owner') then raise exception 'Only the owner changes payment settings.' using errcode = '42501'; end if;
  perform private.require_payments_open(p_org);
  if (select count(*) from transfer_name_checks where org_id = p_org and at > now() - interval '1 day') >= 3 then
    raise exception 'That is three checks today. Try again tomorrow.';
  end if;
  select * into o from orgs where id = p_org;
  insert into transfer_name_checks (org_id, label, checked_by) values (p_org, private.transfer_label(o), m.id) returning id into v_id;
  return jsonb_build_object('check_id', v_id, 'label', private.transfer_label(o), 'org_name', o.name,
    'email', coalesce(nullif(o.email, ''), 'payments+' || left(o.id::text, 8) || '@counta.ng'), 'phone', o.phone);
end $function$;

-- public.transfer_settings: can_change -> perm_of
CREATE OR REPLACE FUNCTION public.transfer_settings(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
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
    'can_change', private.perm_of(m, 'owner'));
end $function$;

-- public.update_corporate_info: the caller changes corporate information -> perm_of
CREATE OR REPLACE FUNCTION public.update_corporate_info(p_org uuid, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; o public.orgs; v_share jsonb; v_narr jsonb; k text; v text;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'owner') or private.perm_of(m, 'keep_books')) then raise exception 'Only the owner or the bookkeeper changes the corporate information.' using errcode = '42501'; end if;
  if p_patch ? 'share_info' then
    if jsonb_typeof(p_patch->'share_info') <> 'object' then raise exception 'Enter the share details.'; end if;
    v_share := jsonb_strip_nulls(jsonb_build_object(
      'authorised_shares', round(private.num(p_patch->'share_info'->>'authorised_shares')),
      'issued_shares', round(private.num(p_patch->'share_info'->>'issued_shares')),
      'nominal_value', round(private.num(p_patch->'share_info'->>'nominal_value'), 4)));
    if (v_share->>'issued_shares')::numeric > (v_share->>'authorised_shares')::numeric then raise exception 'More shares are issued than authorised.'; end if;
    if exists (select 1 from jsonb_each_text(v_share) where value::numeric < 0) then raise exception 'Share numbers cannot be negative.'; end if;
  end if;
  if p_patch ? 'fs_narrative' then
    if jsonb_typeof(p_patch->'fs_narrative') <> 'object' then raise exception 'Enter the statements wording.'; end if;
    v_narr := '{}'::jsonb;
    for k, v in select key, value from jsonb_each_text(p_patch->'fs_narrative') loop
      continue when k not in ('approved_on', 'going_concern', 'dividend', 'events_after', 'contingencies', 'commitments', 'employees_count', 'employees',
        'review', 'future', 'directors_interests', 'pledged');
      v := nullif(trim(v), '');
      if k = 'approved_on' and v is not null and v !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Choose the date the board approves the statements.'; end if;
      if k = 'employees_count' and v is not null and v !~ '^\d{1,7}$' then raise exception 'Enter the number of employees as a whole number.'; end if;
      if v is not null then v_narr := v_narr || jsonb_build_object(k, left(v, 4000)); end if;
    end loop;
  end if;
  update orgs set
    directors = case when p_patch ? 'directors' then private.clean_directors(p_patch->'directors') else directors end,
    company_secretary = case when p_patch ? 'company_secretary' then nullif(left(trim(p_patch->>'company_secretary'), 300), '') else company_secretary end,
    auditors = case when p_patch ? 'auditors' then nullif(left(trim(p_patch->>'auditors'), 300), '') else auditors end,
    audit_exempt = coalesce((p_patch->>'audit_exempt')::boolean, audit_exempt),
    bankers = case when p_patch ? 'bankers' then nullif(left(trim(p_patch->>'bankers'), 500), '') else bankers end,
    solicitors = case when p_patch ? 'solicitors' then nullif(left(trim(p_patch->>'solicitors'), 300), '') else solicitors end,
    registered_office = case when p_patch ? 'registered_office' then nullif(left(trim(p_patch->>'registered_office'), 300), '') else registered_office end,
    incorporation_date = case when p_patch ? 'incorporation_date' then private.date_or_null(p_patch->>'incorporation_date') else incorporation_date end,
    share_info = case when p_patch ? 'share_info' then v_share else share_info end,
    -- Wording is merged: keys sent empty fall back to the standard sentence.
    fs_narrative = case when p_patch ? 'fs_narrative' then (fs_narrative - (select coalesce(array_agg(key), '{}') from jsonb_object_keys(p_patch->'fs_narrative') key)) || v_narr
                        else fs_narrative end
  where id = p_org returning * into o;
  return private.corporate_json(o.id);
end $function$;

-- public.update_member: nobody but the owner changes their own role -> perm_of; only the owner changes an admin -> perm_of; only the owner makes someone an admin -> perm_of
CREATE OR REPLACE FUNCTION public.update_member(p_member uuid, p_patch jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare t public.members; m public.members; v_role text; v_over jsonb; e jsonb; k text;
begin
  select * into t from members where id = p_member;
  if not found then raise exception 'Person not found.'; end if;
  m := private.require(t.org_id, 'manage_team');
  if t.role = 'owner' and (p_patch ? 'role' or p_patch ? 'perms' or p_patch ? 'status' or p_patch ? 'reset_perms') then
    raise exception 'The owner keeps every permission.';
  end if;
  if t.id = m.id and not private.perm_of(m, 'owner') and (p_patch ? 'role' or p_patch ? 'perms' or p_patch ? 'status' or p_patch ? 'reset_perms') then
    raise exception 'Ask the owner to change your own role or permissions.' using errcode = '42501';
  end if;
  if t.role = 'admin' and not private.perm_of(m, 'owner') and (p_patch ? 'role' or p_patch ? 'perms' or p_patch ? 'status' or p_patch ? 'reset_perms') then
    raise exception 'Only the owner changes an admin.' using errcode = '42501';
  end if;
  v_role := coalesce(p_patch->>'role', t.role);
  if v_role not in ('owner', 'admin', 'manager', 'staff', 'cashier', 'accountant') then raise exception 'Unknown role.'; end if;
  if v_role = 'owner' and t.role <> 'owner' then raise exception 'Ownership transfer is not available here.'; end if;
  if v_role = 'admin' and t.role <> 'admin' and not private.perm_of(m, 'owner') then raise exception 'Only the owner makes someone an admin.' using errcode = '42501'; end if;
  if coalesce(p_patch->>'status', t.status) not in ('active', 'invited', 'disabled') then raise exception 'Unknown status.'; end if;
  if p_patch->>'status' = 'active' and t.status = 'invited' then raise exception '% joins by accepting the invitation.', t.display_name; end if;

  -- Their own exceptions: what differs from the role. A new role starts clean unless permissions come with it.
  v_over := case when v_role <> t.role and not (p_patch ? 'perms') then '{}'::jsonb else private.clean_perms(t.perm_overrides) end;
  if coalesce((p_patch->>'reset_perms')::boolean, false) then v_over := '{}'::jsonb; end if;
  if p_patch ? 'perms' then
    e := private.role_perms(t.org_id, v_role) || v_over || private.clean_perms(p_patch->'perms');
    v_over := '{}'::jsonb;
    foreach k in array private.perm_keys() loop
      if e->k is distinct from private.role_perms(t.org_id, v_role)->k then v_over := v_over || jsonb_build_object(k, e->k); end if;
    end loop;
  end if;
  e := private.role_perms(t.org_id, v_role) || v_over;
  if v_role <> 'owner' then
    perform private.check_grantable(m, e);
    perform private.check_split(v_role, e, t.display_name);
  end if;
  update members set
    role = v_role,
    perm_overrides = v_over,
    display_name = coalesce(nullif(trim(p_patch->>'display_name'), ''), display_name),
    title = case when p_patch ? 'title' then nullif(trim(p_patch->>'title'), '') else title end,
    phone = case when p_patch ? 'phone' then nullif(trim(p_patch->>'phone'), '') else phone end,
    location_id = case when p_patch ? 'location_id' then nullif(p_patch->>'location_id', '')::uuid else location_id end,
    status = coalesce(p_patch->>'status', status)
  where id = p_member;
  if v_role <> 'owner' then perform private.apply_member_perms(p_member); end if;
  if p_patch->>'status' = 'disabled' then update member_invites set token_hash = null where member_id = p_member; end if;
end $function$;

-- public.update_payment_settings: only the owner changes payment settings -> perm_of
CREATE OR REPLACE FUNCTION public.update_payment_settings(p_org uuid, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; o public.orgs; v_methods text[];
begin
  m := private.require(p_org, null);
  if not private.perm_of(m, 'owner') then raise exception 'Only the owner changes payment settings.' using errcode = '42501'; end if;
  if p_patch ? 'payment_rail' then
    if not exists (select 1 from payment_rails where code = p_patch->>'payment_rail' and active) then raise exception 'Unknown payment rail.'; end if;
    if exists (select 1 from wallets where org_id = p_org and rail <> p_patch->>'payment_rail' and status = 'active' and private.wallet_balance(id) <> 0) then
      raise exception 'Empty the current wallet before moving to another payment rail.';
    end if;
  end if;
  if jsonb_typeof(p_patch->'payment_methods') = 'array' then
    select array_agg(distinct v) into v_methods from jsonb_array_elements_text(p_patch->'payment_methods') v where v in ('account', 'link', 'qr');
  end if;
  update orgs set payment_rail = coalesce(nullif(p_patch->>'payment_rail', ''), payment_rail),
    payment_methods = coalesce(v_methods, payment_methods),
    payout_approval_threshold = case when p_patch ? 'payout_approval_threshold' then greatest(coalesce(private.num(p_patch->>'payout_approval_threshold'), 0), 0)
                                     else payout_approval_threshold end
  where id = p_org returning * into o;
  return jsonb_build_object('payment_rail', o.payment_rail, 'payment_methods', o.payment_methods, 'payout_approval_threshold', o.payout_approval_threshold);
end $function$;

-- public.update_sales_settings: only the owner changes these settings -> perm_of
CREATE OR REPLACE FUNCTION public.update_sales_settings(p_org uuid, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; o public.orgs; v_slug text;
begin
  m := private.require(p_org, null);
  if not private.perm_of(m, 'owner') then raise exception 'Only the owner changes these settings.' using errcode = '42501'; end if;
  if p_patch ? 'shop_slug' then
    v_slug := nullif(lower(trim(p_patch->>'shop_slug')), '');
    if v_slug is not null and v_slug !~ '^[a-z0-9]([a-z0-9-]{1,38}[a-z0-9])$' then
      raise exception 'Use 3 to 40 letters, numbers or dashes for the shop link.';
    end if;
    if v_slug is not null and exists (select 1 from orgs where shop_slug = v_slug and id <> p_org) then raise exception 'That shop link is taken.'; end if;
  end if;
  if nullif(p_patch->>'shop_location_id', '') is not null and not exists (select 1 from locations where id = (p_patch->>'shop_location_id')::uuid and org_id = p_org) then
    raise exception 'Choose the branch the shop sells from.';
  end if;
  if private.num(p_patch->>'max_cashier_discount_pct') not between 0 and 100 then raise exception 'The cashier discount allowance is a percentage from 0 to 100.'; end if;
  update orgs set
    max_cashier_discount_pct = coalesce(private.num(p_patch->>'max_cashier_discount_pct'), max_cashier_discount_pct),
    receipt_footer = case when p_patch ? 'receipt_footer' then left(nullif(trim(p_patch->>'receipt_footer'), ''), 300) else receipt_footer end,
    shop_slug = case when p_patch ? 'shop_slug' then v_slug else shop_slug end,
    shop_enabled = coalesce((p_patch->>'shop_enabled')::boolean, shop_enabled),
    shop_title = case when p_patch ? 'shop_title' then left(nullif(trim(p_patch->>'shop_title'), ''), 80) else shop_title end,
    shop_note = case when p_patch ? 'shop_note' then left(nullif(trim(p_patch->>'shop_note'), ''), 500) else shop_note end,
    shop_whatsapp = case when p_patch ? 'shop_whatsapp' then private.clean_phone(p_patch->>'shop_whatsapp') else shop_whatsapp end,
    shop_location_id = case when p_patch ? 'shop_location_id' then nullif(p_patch->>'shop_location_id', '')::uuid else shop_location_id end,
    shop_delivery_fee = case when p_patch ? 'shop_delivery_fee' then round(greatest(coalesce(private.num(p_patch->>'shop_delivery_fee'), 0), 0), 2) else shop_delivery_fee end,
    shop_pickup = coalesce((p_patch->>'shop_pickup')::boolean, shop_pickup),
    shop_delivery = coalesce((p_patch->>'shop_delivery')::boolean, shop_delivery),
    shop_show_stock = coalesce((p_patch->>'shop_show_stock')::boolean, shop_show_stock),
    shop_categories = case when p_patch ? 'shop_categories' then
      (select nullif(array_agg(value), '{}') from jsonb_array_elements_text(case when jsonb_typeof(p_patch->'shop_categories') = 'array' then p_patch->'shop_categories' else '[]'::jsonb end))
      else shop_categories end
  where id = p_org returning * into o;
  if o.shop_enabled and o.shop_slug is null then raise exception 'Choose a link for the shop before opening it.'; end if;
  if o.shop_enabled and not o.shop_pickup and not o.shop_delivery then raise exception 'Offer pickup, delivery or both.'; end if;
  return jsonb_build_object('max_cashier_discount_pct', o.max_cashier_discount_pct, 'receipt_footer', o.receipt_footer, 'shop_slug', o.shop_slug,
    'shop_enabled', o.shop_enabled, 'shop_title', o.shop_title, 'shop_note', o.shop_note, 'shop_whatsapp', o.shop_whatsapp, 'shop_location_id', o.shop_location_id,
    'shop_delivery_fee', o.shop_delivery_fee, 'shop_pickup', o.shop_pickup, 'shop_delivery', o.shop_delivery, 'shop_show_stock', o.shop_show_stock,
    'shop_categories', o.shop_categories);
end $function$;

-- public.vat_status: can_change -> perm_of
CREATE OR REPLACE FUNCTION public.vat_status(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; st jsonb;
begin
  m := private.require(p_org, null);
  st := private.vat_small_status(p_org);
  return st || jsonb_build_object('advice', case
      when not (st->>'charging')::boolean and ((st->>'crossed')::boolean or not (st->>'small')::boolean) then 'must_start'
      when (st->>'charging')::boolean and (st->>'small')::boolean and not (st->>'opt_in')::boolean then 'may_stop'
      else 'ok' end,
    'can_change', private.perm_of(m, 'owner'));
end $function$;

-- public.voice_settings: can_edit -> perm_of
CREATE OR REPLACE FUNCTION public.voice_settings(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; o public.orgs;
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  return jsonb_build_object(
    'voice_id', o.voice_id, 'voice_lang', o.voice_lang, 'events', o.voice_events,
    'can_edit', (m.role in ('owner', 'manager') or m.acts_as_owner),
    'voices', coalesce((select jsonb_agg(jsonb_build_object('voice_id', v.voice_id, 'name', v.name, 'gender', v.gender, 'age', v.age,
        'accent', v.accent, 'description', v.description) order by v.sort, v.name)
      from tts_voices v where v.active), '[]'::jsonb));
end $function$;

-- public.waive_close_step: only the owner waives a close step -> perm_of
CREATE OR REPLACE FUNCTION public.waive_close_step(p_org uuid, p_period_end date, p_step text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not private.perm_of(m, 'owner') then raise exception 'Only the owner can waive a close step.' using errcode = '42501'; end if;
  if length(coalesce(trim(p_reason), '')) < 10 then raise exception 'Explain why this step is being waived.'; end if;
  insert into close_waivers (org_id, period_end, step, reason, waived_by) values (p_org, p_period_end, p_step, trim(p_reason), m.id)
  on conflict (org_id, period_end, step) do update set reason = excluded.reason, waived_by = excluded.waived_by, waived_at = now();
  return public.close_checklist(p_org, p_period_end);
end $function$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on function
  private.alert_send(uuid,text,text,text[],jsonb),
  private.alerts_tick(),
  private.bulk_check(uuid,jsonb,public.members),
  private.chat_context(public.chat_links),
  private.check_grantable(public.members,jsonb),
  private.create_payout(uuid,jsonb,jsonb,public.members),
  private.doc_can(public.members),
  private.doc_rows(uuid,public.members,date,date,boolean),
  private.einvoice_issue_held(uuid),
  private.instruction_alert(public.tax_payment_instructions,text),
  private.instruction_block(public.tax_payment_instructions),
  private.match_bank_line(uuid),
  private.mfa_required(uuid),
  private.migration_member(uuid),
  private.notify_perm(uuid,text,text,text,text,text,text,uuid,uuid),
  private.pit_access(uuid),
  private.pit_pay_remind(),
  private.pos_owner_member(uuid),
  private.pos_require_manager(uuid),
  private.pos_require_owner(uuid),
  private.prism_owner(uuid),
  private.si_apply(uuid,jsonb,text,text),
  private.vat_threshold_tick()
  from public, anon, authenticated;
revoke execute on function private.document_may_delete(text) from public, anon;
grant execute on function private.document_may_delete(text) to authenticated;
