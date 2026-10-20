-- Counta, 28 October 2026: tax returns filed through TaxStreem Flux, and each tax paid to the account Rev360 gives for it.
--
-- Flux files a business's returns on Rev360 with an RPA. Once a return is submitted, Rev360 issues a payment reference number
-- (PRN) and its payment page, through Flutterwave, shows a bank account made for that one payment. The account changes every
-- time, so the tax wallet cannot pay a fixed account for the NRS.
--
-- 1. Counta sends Flux a month's VAT return (once filed in Counta), WHT to the NRS and withholding VAT, as it already sends the
--    CIT return (flux_returns; the tax-files function makes the files and signs the request). Flux reports back on each.
-- 2. Flux posts the PRN, the amount and the account its RPA copied from the payment page (tax_payment_instructions, signed with
--    FLUX_SECRET). The payments function checks the account's name with the bank, then:
--    - pays it at once from the tax wallet when the amount agrees with the return (to within a naira), the wallet holds enough,
--      the name matches and the business has not switched automatic payment off;
--    - otherwise the owner is alerted (push, email, WhatsApp) and approves it with a tap, or pays it by transfer from any bank
--      and marks it paid.
-- 3. Flux reports Rev360's confirmation of the payment, and Counta tells Flux each payment it makes.
--
-- The tax wallet still pays nothing a person types in: only an account TaxStreem lists in the admin portal, or the account in a
-- signed instruction from Flux for that business's own return. What Rev360 asks for above the return is booked as a penalty
-- or interest (6514); CIT clears what the books provided for (2208, then 2209) and the rest is the year's tax expense (7501).

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table if not exists public.flux_returns (
  org_id uuid not null references public.orgs(id) on delete cascade,
  tax text not null check (tax in ('vat', 'wht', 'wvat')),
  period date not null check (period = date_trunc('month', period)::date),
  authority text not null default 'NRS' references public.tax_authorities(code),
  status text not null default 'sending' check (status in ('sending', 'send_failed', 'sent', 'processing', 'filed', 'rejected')),
  amount numeric(16,2) not null default 0,
  due date,
  flux_ref text,
  message text,
  acknowledgement_ref text,
  filed_at timestamptz,
  files jsonb not null default '[]'::jsonb,
  sent_by uuid references public.members(id) on delete set null,
  sent_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (org_id, tax, period, authority)
);
create index if not exists flux_returns_authority_fk on public.flux_returns(authority);
create index if not exists flux_returns_sent_by_fk on public.flux_returns(sent_by);
alter table public.flux_returns enable row level security;
revoke all on public.flux_returns from anon, authenticated;

create table if not exists public.tax_payment_instructions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  tax text not null check (tax in ('vat', 'wht', 'wvat', 'cit')),
  period date not null,
  accounting_year int,
  authority text not null default 'NRS' references public.tax_authorities(code),
  prn text not null check (prn ~ '^[A-Za-z0-9][A-Za-z0-9/._-]{3,59}$'),
  amount numeric(16,2) not null check (amount > 0),
  expected numeric(16,2),
  bank_name text not null,
  bank_code text,
  account_number text not null check (account_number ~ '^[0-9]{10}$'),
  account_name text not null,
  resolved_name text,
  name_ok boolean,
  expires_at timestamptz,
  flux_ref text,
  message text,
  status text not null default 'received'
    check (status in ('received', 'paying', 'needs_approval', 'paid', 'confirmed', 'expired', 'renewing', 'replaced', 'cancelled')),
  reason text,
  auto boolean not null default false,
  paid_outside boolean not null default false,
  payment_id uuid references public.tax_payments(id) on delete set null,
  journal_id uuid references public.journals(id) on delete set null,
  receipt_ref text,
  confirmed_at timestamptz,
  flux_notified_at timestamptz,
  received_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, prn)
);
create index if not exists tax_payment_instructions_open on public.tax_payment_instructions(org_id, status, received_at desc);
create index if not exists tax_payment_instructions_authority_fk on public.tax_payment_instructions(authority);
create index if not exists tax_payment_instructions_payment_fk on public.tax_payment_instructions(payment_id);
create index if not exists tax_payment_instructions_journal_fk on public.tax_payment_instructions(journal_id);
alter table public.tax_payment_instructions enable row level security;
revoke all on public.tax_payment_instructions from anon, authenticated;

alter table public.tax_payments add column if not exists instruction_id uuid references public.tax_payment_instructions(id) on delete set null;
create index if not exists tax_payments_instruction_fk on public.tax_payments(instruction_id);
create unique index if not exists tax_payments_one_live_per_instruction on public.tax_payments(instruction_id)
  where instruction_id is not null and status in ('approved', 'processing', 'successful');
alter table public.tax_payments drop constraint if exists tax_payments_kind_check;
alter table public.tax_payments add constraint tax_payments_kind_check check (kind in ('vat', 'wht', 'wvat', 'cit'));

alter table public.orgs add column if not exists tax_autopay boolean not null default true;
alter table public.cit_years add column if not exists tax_paid_at timestamptz;
alter table public.cit_years add column if not exists tax_paid_amount numeric(16,2);
alter table public.cit_years add column if not exists tax_payment_ref text;

-- ---------------------------------------------------------------------------
-- 2. What is due, and booking a tax paid
-- ---------------------------------------------------------------------------
create or replace function private.tax_label(p_tax text) returns text
language sql immutable set search_path = '' as $$
  select case p_tax when 'vat' then 'VAT' when 'wht' then 'WHT' when 'wvat' then 'Withholding VAT' when 'cit' then 'Companies income tax' else upper(p_tax) end
$$;

-- The return's month, or the CIT accounting year, as people say it.
create or replace function private.tax_when(p_tax text, p_period date, p_year int) returns text
language sql immutable set search_path = '' as $$
  select case when p_tax = 'cit' then coalesce(p_year::text, to_char(p_period, 'YYYY')) else to_char(p_period, 'FMMonth YYYY') end
$$;

-- What Counta says is due for one return, and where it stands: {amount (null when Counta has nothing to say), state, due}.
-- state: open (not filed in Counta), filed (filed and owed), paid, none (nothing deducted).
create or replace function private.tax_expected(p_org uuid, p_tax text, p_period date, p_authority text, p_year int) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare vp public.vat_periods; v_amt numeric; v_n int; v_paid int; v_due date; cy public.cit_years;
begin
  if p_tax = 'vat' then
    select * into vp from vat_periods where org_id = p_org and period = p_period;
    if not found then return jsonb_build_object('amount', null, 'state', 'open', 'due', (p_period + interval '1 month')::date + 20); end if;
    return jsonb_build_object('amount', vp.payable, 'state', case when vp.status = 'paid' then 'paid' else 'filed' end, 'due', (p_period + interval '1 month')::date + 20);
  elsif p_tax in ('wht', 'wvat') then
    select coalesce(sum(amount) filter (where status = 'deducted'), 0), count(*) filter (where status = 'deducted'), count(*) filter (where status = 'remitted'),
           min(due_date) filter (where status = 'deducted')
      into v_amt, v_n, v_paid, v_due
      from wht_deductions where org_id = p_org and authority = p_authority and period = p_period and (kind = 'wht') = (p_tax = 'wht');
    return jsonb_build_object('amount', case when v_n > 0 then round(v_amt, 2) end, 'state', case when v_n > 0 then 'filed' when v_paid > 0 then 'paid' else 'none' end,
      'due', coalesce(v_due, (p_period + interval '1 month')::date + 20),
      'total', (select round(coalesce(sum(amount), 0), 2) from wht_deductions where org_id = p_org and authority = p_authority and period = p_period
        and status in ('deducted', 'remitted') and (kind = 'wht') = (p_tax = 'wht')));
  elsif p_tax = 'cit' then
    select * into cy from cit_years where org_id = p_org and accounting_year = p_year;
    if not found then return jsonb_build_object('amount', null, 'state', 'open', 'due', null); end if;
    if cy.tax_paid_at is not null then return jsonb_build_object('amount', cy.tax_paid_amount, 'state', 'paid', 'due', (cy.period_to + interval '6 months')::date); end if;
    if cy.status not in ('approved', 'sent', 'filed') or cy.snapshot is null then
      return jsonb_build_object('amount', null, 'state', 'open', 'due', (cy.period_to + interval '6 months')::date);
    end if;
    return jsonb_build_object('amount', round((cy.snapshot->'figures'->>'payable')::numeric, 2), 'state', 'filed', 'due', (cy.period_to + interval '6 months')::date);
  end if;
  return jsonb_build_object('amount', null, 'state', 'none', 'due', null);
end $$;

-- Books a tax paid (from the tax wallet, or from a bank account) and marks the return paid.
create or replace function private.post_tax_paid(p_org uuid, p_tax text, p_period date, p_authority text, p_year int, p_amount numeric, p_expected numeric,
  p_credit_code text, p_fee numeric, p_ref text, p_by uuid, p_source_id uuid, p_bank_account uuid, p_at timestamptz, p_label text, p_payee text)
returns public.journals
language plpgsql security definer set search_path = public, private as $$
declare j public.journals; m public.members; v_lines jsonb := '[]'::jsonb; v_amt numeric := round(p_amount, 2); v_left numeric; v_liab numeric; v_extra numeric;
  v_bal numeric; v_d numeric; c text; rm public.wht_remittances;
begin
  select * into m from members where id = p_by;
  if p_tax = 'cit' then
    v_left := v_amt;
    foreach c in array array['2208', '2209'] loop
      v_bal := greatest(-(select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code = c), 0);
      v_d := least(v_left, v_bal);
      if v_d > 0.004 then
        v_lines := v_lines || jsonb_build_object('code', c, 'debit', v_d, 'memo', p_ref);
        v_left := v_left - v_d;
      end if;
    end loop;
    if v_left > 0.004 then v_lines := v_lines || jsonb_build_object('code', '7501', 'debit', v_left, 'memo', p_ref || ' · not provided for in the books'); end if;
  else
    v_liab := case when p_expected is null then v_amt else least(v_amt, round(p_expected, 2)) end;
    v_extra := v_amt - v_liab;
    v_lines := v_lines || jsonb_build_object('code', private.acct(p_org, case p_tax when 'vat' then 'output_vat' when 'wht' then 'wht_payable' else 'wvat_payable' end),
      'debit', v_liab, 'memo', p_ref);
    if v_extra > 0.004 then v_lines := v_lines || jsonb_build_object('code', '6514', 'debit', v_extra, 'memo', 'Above the return: penalty or interest · ' || p_ref); end if;
  end if;
  if coalesce(p_fee, 0) > 0 then v_lines := v_lines || jsonb_build_object('code', '6701', 'debit', round(p_fee, 2), 'memo', 'Transfer fee'); end if;
  v_lines := v_lines || jsonb_build_object('code', p_credit_code, 'credit', v_amt + round(coalesce(p_fee, 0), 2), 'memo', p_ref || coalesce(' · ' || p_payee, ''));
  j := private.post_entry(p_org, p_label, 'tax_payment', p_source_id, m.id, m.id, v_lines, p_at,
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'tax_payment', 'ref', p_ref, 'authority', p_authority, 'by', m.display_name))));
  if p_tax = 'vat' then
    update vat_periods set status = 'paid', paid_at = p_at, payment_journal_id = j.id, reference = p_ref where org_id = p_org and period = p_period and status <> 'paid';
  elsif p_tax in ('wht', 'wvat') then
    insert into wht_remittances (org_id, kind, authority, period, amount, paid_at, bank_account_id, reference, journal_id, created_by)
    values (p_org, p_tax, p_authority, p_period, v_amt, p_at, p_bank_account, p_ref, j.id, p_by) returning * into rm;
    update wht_deductions set status = 'remitted', remittance_id = rm.id where org_id = p_org and authority = p_authority and period = p_period and status = 'deducted'
      and (kind = 'wht') = (p_tax = 'wht');
  elsif p_tax = 'cit' then
    update cit_years set tax_paid_at = p_at, tax_paid_amount = v_amt, tax_payment_ref = p_ref where org_id = p_org and accounting_year = p_year;
  end if;
  return j;
end $$;

-- A tax payment from the tax wallet finished at the rail (now also CIT, and payments to the account in a Flux instruction).
-- d: {status: 'successful'|'failed'|'processing', provider_ref, fee, error}
create or replace function public.svc_tax_payment_update(p_reference text, d jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare x public.tax_payments; t public.tax_wallets; tb public.bank_accounts; j public.journals; v_status text := lower(coalesce(d->>'status', ''));
  v_fee numeric; i public.tax_payment_instructions;
begin
  select * into x from tax_payments where reference = p_reference for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown_reference'); end if;
  if x.status in ('successful', 'failed') then return jsonb_build_object('ok', true, 'duplicate', true, 'status', x.status); end if;
  select * into t from tax_wallets where id = x.tax_wallet_id;
  select * into tb from bank_accounts where id = t.bank_account_id;
  if x.instruction_id is not null then select * into i from tax_payment_instructions where id = x.instruction_id for update; end if;
  if v_status in ('successful', 'success', 'completed') then
    v_fee := round(greatest(coalesce(private.num(d->>'fee'), 0), 0), 2);
    -- Marked done first: marking the return paid lets go of what the tax wallet holds beyond the tax still owed, and that
    -- must no longer count this payment as on its way.
    update tax_payments set status = 'successful', completed_at = now(), fee = v_fee, provider_ref = coalesce(nullif(d->>'provider_ref', ''), provider_ref), error = null
    where id = x.id returning * into x;
    j := private.post_tax_paid(x.org_id, x.kind, x.period, x.authority, i.accounting_year, x.amount, case when i.id is null then x.amount else i.expected end,
      tb.ledger_code, v_fee, x.tax_reference, x.requested_by, x.id, tb.id, now(),
      private.tax_label(x.kind) || ' paid from the tax wallet for ' || private.tax_when(x.kind, x.period, i.accounting_year), x.account_name);
    update tax_payments set journal_id = j.id where id = x.id returning * into x;
    if i.id is not null then
      update tax_payment_instructions set status = case when status = 'confirmed' then 'confirmed' else 'paid' end, payment_id = x.id, journal_id = j.id, reason = null, updated_at = now()
      where id = i.id returning * into i;
    end if;
    perform private.notify_perm(x.org_id, 'make_payments', 'payout', 'Paid ' || private.tax_label(x.kind) || ' of ' || private.naira(x.amount) || ' from the tax wallet',
      private.tax_when(x.kind, x.period, i.accounting_year) || ' · ' || x.tax_reference, '/payments?tab=tax', 'taxpay-' || x.id);
  elsif v_status in ('failed', 'error', 'reversed') then
    update tax_payments set status = 'failed', error = left(coalesce(d->>'error', 'The transfer failed.'), 500), provider_ref = coalesce(nullif(d->>'provider_ref', ''), provider_ref)
    where id = x.id returning * into x;
    perform private.notify_perm(x.org_id, 'make_payments', 'payout', 'Tax payment from the tax wallet failed', coalesce(x.error, ''), '/payments?tab=tax', 'taxpay-fail-' || x.id);
    if i.id is not null and i.status = 'paying' then
      update tax_payment_instructions set status = 'needs_approval', payment_id = null, reason = 'The transfer failed: ' || coalesce(x.error, 'no reason given') || ' Try again, or pay it by transfer from a bank.',
        updated_at = now() where id = i.id returning * into i;
      perform private.instruction_alert(i, 'failed');
    end if;
  else
    update tax_payments set provider_ref = coalesce(nullif(d->>'provider_ref', ''), provider_ref) where id = x.id returning * into x;
  end if;
  return jsonb_build_object('ok', true, 'status', x.status,
    'instruction', case when i.id is not null then jsonb_build_object('id', i.id, 'org_id', i.org_id, 'prn', i.prn, 'status', i.status) end);
end $$;

-- What the tax wallet keeps when a month is paid and the rest goes back to the business wallet: also the payments Rev360 has
-- asked for that are waiting (so money put in for one is not sent back before it is paid). A month's VAT already set aside
-- may be counted twice while its request waits; that only keeps more in the tax wallet until it is paid.
create or replace function private.vault_reserve(p_org uuid) returns numeric
language sql stable security definer set search_path = public, private as $$
  select coalesce((select sum(mv.amount) from tax_moves mv
                   where mv.org_id = p_org and mv.kind = 'vat' and mv.status = 'done'
                     and not exists (select 1 from vat_periods vp where vp.org_id = p_org and vp.period = mv.period and vp.status = 'paid')), 0)
       + coalesce((select sum(mv.amount) from tax_moves mv
                   where mv.org_id = p_org and mv.kind = 'wht' and mv.status = 'done'
                     and exists (select 1 from wht_deductions d where d.bill_payment_id = mv.source_id and d.status in ('pending', 'deducted'))), 0)
       + coalesce((select sum(i.amount) from tax_payment_instructions i
                   where i.org_id = p_org and (i.status in ('received', 'needs_approval', 'renewing') or (i.status = 'expired' and i.updated_at > now() - interval '14 days'))), 0)
$$;

-- ---------------------------------------------------------------------------
-- 3. Returns sent to Flux
-- ---------------------------------------------------------------------------
-- What the tax-files function sends to Flux for a month's VAT return, WHT to the NRS or withholding VAT, after checking the
-- person may file tax and the return is ready; the return is marked as being sent.
create or replace function public.flux_return_pack(p_org uuid, p_tax text, p_period date, p_authority text default 'NRS') returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; v_period date := date_trunc('month', p_period)::date; v_auth text := coalesce(nullif(p_authority, ''), 'NRS');
  r public.flux_returns; e jsonb; vp public.vat_periods; v_summary jsonb := '{}'::jsonb;
begin
  m := private.require(p_org, 'file_tax');
  if p_tax not in ('vat', 'wht', 'wvat') then raise exception 'Flux takes VAT, WHT and withholding VAT returns here; a CIT return is sent from its year.'; end if;
  if v_auth <> 'NRS' then raise exception 'Flux files with the NRS on Rev360. WHT for a state revenue service is paid to the state.'; end if;
  if v_period is null then raise exception 'Choose the month.'; end if;
  select * into o from orgs where id = p_org;
  e := private.tax_expected(p_org, p_tax, v_period, v_auth, null);
  if p_tax = 'vat' then
    select * into vp from vat_periods where org_id = p_org and period = v_period;
    if not found then raise exception 'File the % VAT return in Counta first: filing freezes the figures Flux files.', to_char(v_period, 'FMMonth YYYY'); end if;
    v_summary := jsonb_build_object('output', vp.output_vat, 'input', vp.input_vat, 'withheld_by_customers', vp.wvat_credit, 'credit_brought_forward', vp.credit_bf,
      'credit_used', vp.credit_used, 'payable', vp.payable, 'credit_carried_forward', vp.credit_cf, 'refund_claimed', vp.refund_claimed, 'filed_in_counta_at', vp.filed_at);
  elsif e->>'state' = 'none' then
    raise exception '% for the NRS in %: nothing is waiting to be filed.', private.tax_label(p_tax), to_char(v_period, 'FMMonth YYYY');
  end if;
  select * into r from flux_returns where org_id = p_org and tax = p_tax and period = v_period and authority = v_auth for update;
  if found and (r.status in ('sent', 'processing', 'filed') or (r.status = 'sending' and r.updated_at > now() - interval '5 minutes')) then
    raise exception 'The % % return is already with Flux (%).', to_char(v_period, 'FMMonth YYYY'), private.tax_label(p_tax),
      case r.status when 'filed' then 'filed' when 'sending' then 'being sent' else 'with Flux' end;
  end if;
  insert into flux_returns (org_id, tax, period, authority, status, amount, due, sent_by, sent_at, updated_at)
  values (p_org, p_tax, v_period, v_auth, 'sending', coalesce((e->>'total')::numeric, (e->>'amount')::numeric, 0), (e->>'due')::date, m.id, now(), now())
  on conflict (org_id, tax, period, authority) do update set status = 'sending', amount = excluded.amount, due = excluded.due, sent_by = excluded.sent_by,
    sent_at = now(), updated_at = now(), message = null, flux_ref = null;
  return jsonb_build_object('org', jsonb_build_object('id', o.id, 'name', o.name, 'tin', o.tin, 'rc_number', o.rc_number, 'address', o.address,
      'taxstreem_org_id', o.taxstreem_org_id),
    'tax', p_tax, 'period', to_char(v_period, 'YYYY-MM'), 'authority', v_auth, 'amount', coalesce((e->>'total')::numeric, (e->>'amount')::numeric, 0),
    'to_pay', coalesce((e->>'amount')::numeric, 0), 'due', e->>'due',
    'summary', v_summary, 'sent_by', m.display_name);
end $$;

-- What Flux says of a return Counta sent it (and the tax-files function's own record of the send).
-- p: {status: send_failed|sent|processing|filed|rejected, ref, message, acknowledgement_ref, filed_at, files}
create or replace function public.svc_flux_return_update(p_org uuid, p_tax text, p_period date, p_authority text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.flux_returns; v_status text := nullif(p->>'status', ''); v_period date := date_trunc('month', p_period)::date;
begin
  select * into r from flux_returns where org_id = p_org and tax = p_tax and period = v_period and authority = coalesce(nullif(p_authority, ''), 'NRS') for update;
  if not found then raise exception 'Counta has not sent this return to Flux.'; end if;
  if v_status is not null and v_status not in ('send_failed', 'sent', 'processing', 'filed', 'rejected') then
    raise exception 'status must be processing, sent, filed or rejected.';
  end if;
  -- A return Flux has filed stays filed.
  if r.status = 'filed' and v_status is distinct from 'filed' then return to_jsonb(r); end if;
  update flux_returns set status = coalesce(v_status, status), flux_ref = coalesce(nullif(p->>'ref', ''), flux_ref),
    message = case when p ? 'message' then nullif(left(p->>'message', 500), '') else message end,
    acknowledgement_ref = coalesce(nullif(p->>'acknowledgement_ref', ''), acknowledgement_ref),
    filed_at = case when v_status = 'filed' then coalesce(nullif(p->>'filed_at', '')::timestamptz, now()) else filed_at end,
    files = case when jsonb_typeof(p->'files') = 'array' then p->'files' else files end, updated_at = now()
  where org_id = r.org_id and tax = r.tax and period = r.period and authority = r.authority returning * into r;
  if v_status in ('filed', 'rejected') then
    perform private.notify_perm(r.org_id, 'file_tax', 'tax',
      private.tax_label(r.tax) || ' for ' || to_char(r.period, 'FMMonth YYYY') || case when v_status = 'filed' then ' is filed on Rev360' else ' was sent back by Flux' end,
      coalesce(r.message, case when v_status = 'filed' then coalesce('Acknowledgement ' || r.acknowledgement_ref, 'Filed.') else 'Check it and send it again.' end),
      case when r.tax = 'vat' then '/tax/vat' else '/tax/wht' end, 'flux-' || r.tax || '-' || r.period || '-' || v_status);
  end if;
  return to_jsonb(r);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Payment instructions from Flux
-- ---------------------------------------------------------------------------
-- The owner hears of a payment waiting for them, of an account that expired, or of a transfer that failed.
create or replace function private.instruction_alert(i public.tax_payment_instructions, p_why text) returns void
language plpgsql security definer set search_path = public, private as $$
declare o public.orgs; ow public.members; v_what text := private.tax_label(i.tax) || ' payment'; v_when text := private.tax_when(i.tax, i.period, i.accounting_year); e jsonb;
begin
  select * into o from orgs where id = i.org_id;
  select * into ow from members where org_id = i.org_id and role = 'owner' and status = 'active' order by created_at limit 1;
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
end $$;

-- Flux posts the PRN Rev360 gave and the account its payment page shows. One instruction per PRN; a new account for the same PRN
-- (the last one expired) replaces it while it is not being paid, and a new PRN for the same return replaces an unpaid old one.
-- p: {counta_org_id, tax: vat|wht|wvat|cit, period: 'YYYY-MM' (accounting_year for cit), authority: 'NRS', prn, amount,
--     account: {number, bank_name, bank_code, name}, expires_at, ref, message}
create or replace function public.svc_flux_payment_instruction(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_org uuid; o public.orgs; v_tax text := lower(coalesce(p->>'tax', '')); v_period date; v_year int; v_auth text := coalesce(nullif(p->>'authority', ''), 'NRS');
  v_prn text := nullif(trim(coalesce(p->>'prn', '')), ''); v_amt numeric; a jsonb := coalesce(p->'account', '{}'::jsonb); v_no text; v_bank text; v_name text;
  v_exp timestamptz; i public.tax_payment_instructions; cy public.cit_years; e jsonb;
begin
  begin v_org := (p->>'counta_org_id')::uuid; exception when others then v_org := null; end;
  if v_org is null then raise exception 'counta_org_id is required.'; end if;
  select * into o from orgs where id = v_org;
  if not found then raise exception 'This business is not on Counta.'; end if;
  if v_tax not in ('vat', 'wht', 'wvat', 'cit') then raise exception 'tax must be vat, wht, wvat or cit.'; end if;
  if v_auth <> 'NRS' then raise exception 'Only payments to the NRS come through Flux.'; end if;
  if v_tax = 'cit' then
    begin v_year := nullif(p->>'accounting_year', '')::int; exception when others then v_year := null; end;
    if v_year is null then raise exception 'accounting_year is required for CIT.'; end if;
    select * into cy from cit_years where org_id = v_org and accounting_year = v_year;
    v_period := coalesce(cy.period_from, make_date(v_year, 1, 1));
  else
    if coalesce(p->>'period', '') !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception 'period must be YYYY-MM.'; end if;
    v_period := (p->>'period' || '-01')::date;
  end if;
  if v_prn is null or v_prn !~ '^[A-Za-z0-9][A-Za-z0-9/._-]{3,59}$' then raise exception 'prn is required: 4 to 60 letters, digits, / . _ or -.'; end if;
  v_amt := round(private.num(p->>'amount'), 2);
  if v_amt is null or v_amt <= 0 then raise exception 'amount must be more than zero.'; end if;
  v_no := regexp_replace(coalesce(a->>'number', ''), '\s', '', 'g');
  if v_no !~ '^[0-9]{10}$' then raise exception 'account.number must be the 10-digit account number.'; end if;
  v_bank := nullif(trim(coalesce(a->>'bank_name', '')), ''); v_name := nullif(trim(coalesce(a->>'name', '')), '');
  if v_bank is null or v_name is null then raise exception 'account.bank_name and account.name are required.'; end if;
  if nullif(p->>'expires_at', '') is not null then
    begin v_exp := (p->>'expires_at')::timestamptz; exception when others then raise exception 'expires_at must be a date and time (ISO 8601).'; end;
  end if;
  e := private.tax_expected(v_org, v_tax, v_period, v_auth, v_year);
  select * into i from tax_payment_instructions where org_id = v_org and prn = v_prn for update;
  if found then
    if i.status in ('paying', 'paid', 'confirmed') then
      if i.account_number = v_no and i.amount = v_amt then return jsonb_build_object('id', i.id, 'status', i.status, 'duplicate', true); end if;
      raise exception 'Counta is already paying PRN % (%), so it was not changed.', v_prn, i.status;
    end if;
    update tax_payment_instructions set tax = v_tax, period = v_period, accounting_year = v_year, amount = v_amt, expected = (e->>'amount')::numeric,
      bank_name = left(v_bank, 120), bank_code = nullif(trim(coalesce(a->>'bank_code', '')), ''), account_number = v_no, account_name = left(v_name, 160),
      resolved_name = null, name_ok = null, expires_at = v_exp, flux_ref = coalesce(nullif(p->>'ref', ''), flux_ref), message = nullif(left(p->>'message', 500), ''),
      status = 'received', reason = null, updated_at = now()
    where id = i.id returning * into i;
  else
    insert into tax_payment_instructions (org_id, tax, period, accounting_year, authority, prn, amount, expected, bank_name, bank_code, account_number, account_name,
      expires_at, flux_ref, message)
    values (v_org, v_tax, v_period, v_year, v_auth, v_prn, v_amt, (e->>'amount')::numeric, left(v_bank, 120), nullif(trim(coalesce(a->>'bank_code', '')), ''), v_no,
      left(v_name, 160), v_exp, nullif(p->>'ref', ''), nullif(left(p->>'message', 500), ''))
    returning * into i;
  end if;
  -- An earlier PRN for the same return that was never paid gives way to this one.
  update tax_payment_instructions set status = 'replaced', updated_at = now()
  where org_id = v_org and tax = v_tax and period = v_period and authority = v_auth and id <> i.id and status in ('received', 'needs_approval', 'expired', 'renewing');
  return jsonb_build_object('id', i.id, 'status', i.status, 'duplicate', false);
end $$;

-- What the payments function needs to check and pay an instruction.
create or replace function public.svc_tax_instruction_context(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('instruction', to_jsonb(i),
    'tax_wallet', case when t.id is not null then jsonb_build_object('id', t.id, 'rail', t.rail, 'account_ref', t.account_ref) end)
  from tax_payment_instructions i left join tax_wallets t on t.org_id = i.org_id and t.status = 'active'
  where i.id = p_id
$$;

-- Whether the name the bank gives for a payment account looks like a tax collection account (Rev360's payment page, through
-- Flutterwave, opens accounts in the revenue service's name). Anything else waits for a person, however the instruction came.
create or replace function private.tax_payee_name_ok(p_name text) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(lower(p_name) ~ '(revenue|\mnrs\M|\mfirs\M|rev ?360|\mtax)', false)
$$;

-- Whether a person may pay an instruction from the tax wallet at all: not when the bank named someone other than the name
-- Flux read, or a name that is not a tax collection account. (When the bank could not be asked, the person decides.)
create or replace function private.instruction_wallet_ok(i public.tax_payment_instructions) returns boolean
language sql immutable set search_path = public, private as $$
  select i.name_ok is not false and (nullif(i.resolved_name, '') is null or private.tax_payee_name_ok(i.resolved_name))
$$;

-- Why an instruction cannot be paid from the tax wallet without a person (null when it can).
create or replace function private.instruction_block(i public.tax_payment_instructions) returns text
language plpgsql stable security definer set search_path = public, private as $$
declare t public.tax_wallets; e jsonb; v_spend numeric;
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
  if not exists (select 1 from members where org_id = i.org_id and role = 'owner' and status = 'active') then return 'The business has no owner to pay it for.'; end if;
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
  if abs(i.amount - i.expected) >= 1 then
    return format('Rev360 asks for %s; the return in Counta comes to %s.', private.naira(i.amount), private.naira(i.expected));
  end if;
  if not coalesce((select tax_autopay from orgs where id = i.org_id), true) then return 'Paying these automatically is switched off for this business.'; end if;
  v_spend := private.tax_wallet_spendable(t.id);
  if i.amount > v_spend + 0.004 then
    return format('The tax wallet can pay %s; %s is due. Top it up, or pay it by transfer from a bank.', private.naira(v_spend), private.naira(i.amount));
  end if;
  return null;
end $$;

-- A tax payment from the tax wallet for an instruction: to its account, for its amount, with the PRN as the reference.
create or replace function private.instruction_payment(i public.tax_payment_instructions, p_member uuid, p_auto boolean) returns public.tax_payments
language plpgsql security definer set search_path = public, private as $$
declare t public.tax_wallets; x public.tax_payments;
begin
  select * into t from tax_wallets where org_id = i.org_id and status = 'active';
  insert into tax_payments (org_id, tax_wallet_id, kind, authority, period, amount, tax_reference, reference, bank_code, account_number, account_name, requested_by, instruction_id)
  values (i.org_id, t.id, i.tax, i.authority, i.period, i.amount, i.prn, 'CNTX-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)), i.bank_code,
    i.account_number, coalesce(i.resolved_name, i.account_name), p_member, i.id)
  returning * into x;
  update tax_payment_instructions set status = 'paying', auto = p_auto, payment_id = x.id, reason = null, updated_at = now() where id = i.id;
  return x;
end $$;

-- After the payments function has checked the bank and the name: pay now, or wait for the owner.
-- p: {bank_code, resolved_name, name_ok (true|false, absent when the bank could not be asked)}
create or replace function public.svc_tax_instruction_decide(p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
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
  v_why := private.instruction_block(i);
  if v_why = 'expired' then
    update tax_payment_instructions set status = 'expired', reason = 'The account Rev360 gave expired before it was paid. Ask Flux for a new one.', updated_at = now()
    where id = i.id returning * into i;
    perform private.instruction_alert(i, 'expired');
    return jsonb_build_object('decision', 'expired', 'status', 'expired');
  end if;
  if v_why is null then
    select * into ow from members where org_id = i.org_id and role = 'owner' and status = 'active' order by created_at limit 1;
    x := private.instruction_payment(i, ow.id, true);
    return jsonb_build_object('decision', 'pay', 'status', 'paying', 'payment_id', x.id);
  end if;
  update tax_payment_instructions set status = 'needs_approval', reason = v_why, updated_at = now() where id = i.id returning * into i;
  perform private.instruction_alert(i, 'approve');
  return jsonb_build_object('decision', 'wait', 'status', 'needs_approval', 'reason', v_why);
end $$;

-- The person who approves payments pays a waiting instruction from the tax wallet (the app then sends it).
create or replace function public.approve_tax_instruction(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.tax_payment_instructions; m public.members; t public.tax_wallets; x public.tax_payments; v_spend numeric;
begin
  select * into i from tax_payment_instructions where id = p_id for update;
  if not found then raise exception 'Not found.'; end if;
  m := private.require(i.org_id, 'make_payments');
  if not (m.role = 'owner' or private.perm_of(m, 'approve_payments')) then
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
end $$;

-- Paid by transfer from a bank account instead: the payment is booked from that account and the return marked paid.
-- p: {bank_account_id, paid_at}
create or replace function public.mark_tax_instruction_paid(p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.tax_payment_instructions; m public.members; ba public.bank_accounts; v_at timestamptz; j public.journals; e jsonb;
begin
  select * into i from tax_payment_instructions where id = p_id for update;
  if not found then raise exception 'Not found.'; end if;
  m := private.require(i.org_id, null);
  if not (private.perm_of(m, 'make_payments') or private.perm_of(m, 'keep_books')) then
    raise exception 'Only someone who makes payments or keeps the books records a tax payment.' using errcode = '42501';
  end if;
  if i.status = 'paying' then raise exception 'Counta is paying this from the tax wallet already.'; end if;
  if i.journal_id is not null then raise exception 'This payment is recorded already.'; end if;
  if i.status in ('replaced', 'cancelled') then raise exception 'Flux has replaced this payment request with a newer one.'; end if;
  select * into ba from bank_accounts where id = nullif(p->>'bank_account_id', '')::uuid and org_id = i.org_id and active;
  if not found then raise exception 'Choose the account it was paid from.'; end if;
  v_at := least(coalesce(nullif(p->>'paid_at', '')::timestamptz, now()), now());
  perform private.require_open_day(i.org_id, private.local_day(i.org_id, v_at));
  e := private.tax_expected(i.org_id, i.tax, i.period, i.authority, i.accounting_year);
  if e->>'state' = 'paid' then raise exception 'Counta shows this return as paid already.'; end if;
  j := private.post_tax_paid(i.org_id, i.tax, i.period, i.authority, i.accounting_year, i.amount, (e->>'amount')::numeric, ba.ledger_code, 0, 'PRN ' || i.prn, m.id, i.id, ba.id,
    v_at, private.tax_label(i.tax) || ' paid to the NRS for ' || private.tax_when(i.tax, i.period, i.accounting_year), i.account_name);
  update tax_payment_instructions set status = case when status = 'confirmed' then 'confirmed' else 'paid' end, paid_outside = true, journal_id = j.id, reason = null, updated_at = now()
  where id = i.id returning * into i;
  return to_jsonb(i) || jsonb_build_object('journal_ref', j.ref);
end $$;

-- Asking Flux for a new account when the last one expired: who may, and what to send. The tax-files function posts it to Flux
-- and then marks the request as renewing (svc_tax_instruction_note).
create or replace function public.flux_instruction_renew(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.tax_payment_instructions; m public.members; o public.orgs;
begin
  select * into i from tax_payment_instructions where id = p_id for update;
  if not found then raise exception 'Not found.'; end if;
  m := private.require(i.org_id, null);
  if not (private.perm_of(m, 'make_payments') or private.perm_of(m, 'file_tax')) then
    raise exception 'Only someone who makes payments or files tax asks for a new account.' using errcode = '42501';
  end if;
  if i.status not in ('expired', 'needs_approval', 'renewing') then raise exception 'This payment is %; it needs no new account.', i.status; end if;
  select * into o from orgs where id = i.org_id;
  return jsonb_build_object('id', i.id, 'counta_org_id', i.org_id, 'taxstreem_org_id', o.taxstreem_org_id, 'tax', i.tax,
    'period', case when i.tax = 'cit' then null else to_char(i.period, 'YYYY-MM') end, 'accounting_year', i.accounting_year, 'authority', i.authority, 'prn', i.prn,
    'amount', i.amount, 'requested_by', m.display_name);
end $$;

-- The tax-files function's record of asking Flux for a new account: renewing once Flux has the request, or a note saying it
-- could not be reached.
create or replace function public.svc_tax_instruction_note(p_id uuid, p_status text, p_reason text) returns void
language sql security definer set search_path = public, private as $$
  update tax_payment_instructions set status = case when p_status = 'renewing' and status in ('expired', 'needs_approval', 'renewing') then 'renewing' else status end,
    reason = coalesce(nullif(left(p_reason, 500), ''), reason), updated_at = now()
  where id = p_id
$$;

-- Flux reports what Rev360 says of a payment. p: {counta_org_id, prn, status: confirmed|not_received|expired, receipt_ref, confirmed_at, message}
create or replace function public.svc_flux_payment_status(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_org uuid; i public.tax_payment_instructions; v_status text := lower(coalesce(p->>'status', '')); v_msg text := nullif(left(coalesce(p->>'message', ''), 500), '');
begin
  begin v_org := (p->>'counta_org_id')::uuid; exception when others then v_org := null; end;
  if v_org is null then raise exception 'counta_org_id is required.'; end if;
  select * into i from tax_payment_instructions where org_id = v_org and prn = nullif(trim(coalesce(p->>'prn', '')), '') for update;
  if not found then raise exception 'Counta has no payment request with that PRN for this business.'; end if;
  if v_status not in ('confirmed', 'not_received', 'expired') then raise exception 'status must be confirmed, not_received or expired.'; end if;
  if v_status = 'confirmed' then
    update tax_payment_instructions set status = 'confirmed', receipt_ref = coalesce(nullif(p->>'receipt_ref', ''), receipt_ref),
      confirmed_at = coalesce(nullif(p->>'confirmed_at', '')::timestamptz, now()), message = coalesce(v_msg, message),
      reason = case when journal_id is null and status <> 'paying' then 'Rev360 has the payment. If it came from a bank account, mark it paid here so the books show it.' else null end,
      updated_at = now()
    where id = i.id returning * into i;
    perform private.notify_perm(i.org_id, 'make_payments', 'tax', 'Rev360 confirmed the ' || lower(private.tax_label(i.tax)) || ' payment for '
      || private.tax_when(i.tax, i.period, i.accounting_year), 'PRN ' || i.prn || coalesce(' · receipt ' || i.receipt_ref, ''), '/payments?tab=tax', 'taxconf-' || i.id);
  elsif v_status = 'not_received' then
    update tax_payment_instructions set message = coalesce(v_msg, 'Rev360 has not seen the payment yet.'), updated_at = now() where id = i.id returning * into i;
    perform private.notify_perm(i.org_id, 'make_payments', 'tax', 'Rev360 has not seen the ' || lower(private.tax_label(i.tax)) || ' payment for '
      || private.tax_when(i.tax, i.period, i.accounting_year), coalesce(v_msg, 'PRN ' || i.prn), '/payments?tab=tax', 'taxnr-' || i.id || '-' || to_char(now(), 'YYYYMMDDHH24'));
  elsif i.status in ('received', 'needs_approval', 'renewing') then
    update tax_payment_instructions set status = 'expired', reason = coalesce(v_msg, 'The account Rev360 gave expired before it was paid. Ask Flux for a new one.'), updated_at = now()
    where id = i.id returning * into i;
    perform private.instruction_alert(i, 'expired');
  end if;
  return jsonb_build_object('id', i.id, 'status', i.status);
end $$;

-- The same checks as tax_payment_to_send, for a payment Counta sends without a person (an instruction paid automatically, or
-- one approved while transfers were off). Marks it processing.
create or replace function public.svc_tax_payment_to_send(p_payment uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare x public.tax_payments; t public.tax_wallets; i public.tax_payment_instructions;
begin
  select * into x from tax_payments where id = p_payment for update;
  if not found then raise exception 'Not found.'; end if;
  if x.status <> 'approved' then raise exception 'This payment is already %.', x.status; end if;
  select * into t from tax_wallets where id = x.tax_wallet_id and status = 'active';
  if not found then raise exception 'The tax wallet is not open.'; end if;
  if x.instruction_id is not null then
    select * into i from tax_payment_instructions where id = x.instruction_id;
    if i.expires_at is not null and i.expires_at < now() + interval '1 minute' then raise exception 'The account Rev360 gave for this payment has expired.'; end if;
  end if;
  update tax_payments set status = 'processing', sent_at = now() where id = x.id returning * into x;
  return jsonb_build_object('payment', jsonb_build_object('reference', x.reference, 'amount', x.amount, 'bank_code', x.bank_code, 'account_number', x.account_number,
      'account_name', x.account_name, 'narration', private.tax_narration(x, i)),
    'rail', t.rail, 'tax_wallet', jsonb_build_object('account_ref', t.account_ref));
end $$;

-- What the receiving bank shows: the PRN first for a Rev360 payment, or the tax, month and reference.
create or replace function private.tax_narration(x public.tax_payments, i public.tax_payment_instructions) returns text
language sql immutable set search_path = public, private as $$
  select left(case when i.id is not null then 'PRN ' || i.prn || ' ' || upper(x.kind) || ' ' || private.tax_when(x.kind, x.period, i.accounting_year)
    else upper(x.kind) || ' ' || to_char(x.period, 'Mon YYYY') || ' ' || x.tax_reference end, 80)
$$;

-- A person sending a tax payment from the tax wallet (now also an instruction's).
create or replace function public.tax_payment_to_send(p_payment uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare x public.tax_payments; m public.members; t public.tax_wallets; i public.tax_payment_instructions;
begin
  select * into x from tax_payments where id = p_payment for update;
  if not found then raise exception 'Not found.'; end if;
  m := private.require(x.org_id, 'make_payments');
  if x.status <> 'approved' then raise exception 'This payment is already %.', x.status; end if;
  select * into t from tax_wallets where id = x.tax_wallet_id and status = 'active';
  if not found then raise exception 'The tax wallet is not open.'; end if;
  if x.instruction_id is not null then
    select * into i from tax_payment_instructions where id = x.instruction_id;
    if i.expires_at is not null and i.expires_at < now() + interval '1 minute' then
      raise exception 'The account Rev360 gave for this payment has expired. Ask Flux for a new one.';
    end if;
  end if;
  update tax_payments set status = 'processing', sent_at = now() where id = x.id returning * into x;
  return jsonb_build_object('payment', jsonb_build_object('reference', x.reference, 'amount', x.amount, 'bank_code', x.bank_code, 'account_number', x.account_number,
      'account_name', x.account_name, 'narration', private.tax_narration(x, i)),
    'rail', t.rail, 'tax_wallet', jsonb_build_object('account_ref', t.account_ref));
end $$;

-- The payments function's five-minute work for instructions: accounts that expired unpaid are marked, approved payments whose
-- account expired fail, and it is told which requests to check with the bank, which payments to send and which payments to
-- tell Flux about.
create or replace function public.svc_tax_instruction_work() returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.tax_payment_instructions; x public.tax_payments;
begin
  for x in select p.* from tax_payments p join tax_payment_instructions i on i.id = p.instruction_id
           where p.status = 'approved' and i.expires_at is not null and i.expires_at < now() loop
    update tax_payment_instructions set status = 'expired', payment_id = null, updated_at = now(),
      reason = 'The account Rev360 gave expired before the payment went. Nothing left the tax wallet. Ask Flux for a new one.'
    where id = x.instruction_id returning * into r;
    perform public.svc_tax_payment_update(x.reference, jsonb_build_object('status', 'failed', 'error', 'The account expired before the payment went.'));
    perform private.instruction_alert(r, 'expired');
  end loop;
  for r in select * from tax_payment_instructions where status in ('received', 'needs_approval') and expires_at is not null and expires_at < now() for update skip locked loop
    update tax_payment_instructions set status = 'expired', reason = 'The account Rev360 gave expired before it was paid. Ask Flux for a new one.', updated_at = now()
    where id = r.id returning * into r;
    perform private.instruction_alert(r, 'expired');
  end loop;
  return jsonb_build_object(
    -- Requests Flux posted that were not checked with the bank when they came in.
    'to_check', coalesce((select jsonb_agg(i.id order by i.received_at) from tax_payment_instructions i
      where i.status = 'received' and i.updated_at < now() - interval '1 minute'), '[]'::jsonb),
    'to_send', coalesce((select jsonb_agg(jsonb_build_object('payment_id', p.id, 'rail', t.rail, 'reference', p.reference) order by p.created_at)
      from tax_payments p join tax_wallets t on t.id = p.tax_wallet_id join tax_payment_instructions i on i.id = p.instruction_id
      where p.status = 'approved' and (i.expires_at is null or i.expires_at > now() + interval '1 minute')), '[]'::jsonb),
    'to_notify', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'counta_org_id', i.org_id, 'prn', i.prn, 'tax', i.tax, 'amount', i.amount,
        'paid_at', coalesce(p.completed_at, i.updated_at), 'from', case when i.paid_outside then 'bank_account' else 'tax_wallet' end, 'transfer_reference', p.reference,
        'provider_ref', p.provider_ref) order by i.updated_at)
      from tax_payment_instructions i left join tax_payments p on p.id = i.payment_id
      where i.status in ('paid', 'confirmed') and i.journal_id is not null and i.flux_notified_at is null and i.updated_at > now() - interval '7 days'), '[]'::jsonb));
end $$;

create or replace function public.svc_tax_instruction_notified(p_id uuid) returns void
language sql security definer set search_path = public, private as $$
  update tax_payment_instructions set flux_notified_at = now() where id = p_id
$$;

-- ---------------------------------------------------------------------------
-- 5. For the screens
-- ---------------------------------------------------------------------------
-- The payment requests from Flux and the returns sent to it, for the Payments page (tax wallet) and the VAT, WHT and CIT pages.
create or replace function public.get_flux_tax(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
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
        'wallet_ok', private.instruction_wallet_ok(i))
        order by case when i.status in ('needs_approval', 'expired', 'received', 'renewing', 'paying') then 0 else 1 end, i.received_at desc)
      from tax_payment_instructions i left join tax_payments p on p.id = i.payment_id left join journals j on j.id = i.journal_id
      where i.org_id = p_org and i.status not in ('replaced', 'cancelled')
        and (i.status in ('received', 'needs_approval', 'expired', 'renewing', 'paying') or i.received_at > now() - interval '120 days')), '[]'::jsonb),
    'returns', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object('label', private.tax_label(r.tax), 'sent_by_name', mm.display_name) order by r.period desc, r.tax)
      from flux_returns r left join members mm on mm.id = r.sent_by where r.org_id = p_org), '[]'::jsonb),
    'autopay', o.tax_autopay,
    'tax_wallet', case when t.id is not null then jsonb_build_object('spendable', private.tax_wallet_spendable(t.id), 'account_number', t.account_number, 'bank_name', t.bank_name) end,
    'can', jsonb_build_object(
      'approve', m.role = 'owner' or (private.perm_of(m, 'make_payments') and private.perm_of(m, 'approve_payments')),
      'record', private.perm_of(m, 'make_payments') or private.perm_of(m, 'keep_books'),
      'renew', private.perm_of(m, 'make_payments') or private.perm_of(m, 'file_tax'),
      'send', private.perm_of(m, 'file_tax'),
      'autopay', m.role = 'owner' or private.perm_of(m, 'manage_settings')));
end $$;

-- Whether a payment request from Flux that matches the return is paid from the tax wallet without a tap.
create or replace function public.set_tax_autopay(p_org uuid, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not (m.role = 'owner' or private.perm_of(m, 'manage_settings')) then raise exception 'Only the owner changes this.' using errcode = '42501'; end if;
  update orgs set tax_autopay = coalesce(p_on, true) where id = p_org;
  return jsonb_build_object('autopay', coalesce(p_on, true));
end $$;

-- The counts beside the menu: payment requests from Flux waiting for someone count on Payments.
create or replace function public.get_attention(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
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
      if r.tax = 'vat' then v_vat := v_vat + 1; elsif r.tax = 'cit' then v_cit := v_cit + 1; else v_wht := v_wht + 1; end if;
    end loop;
    v_cit := case when exists (select 1 from private.tax_deadlines(p_org) t where t.tax = 'cit' and t.due <= v_today + 30) then 1 else 0 end;
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
    'tax_id', case when m.role = 'owner' or private.perm_of(m, 'manage_settings') then
      case when coalesce(o.tin, '') = '' or coalesce(o.tin_status, '') not in ('verified', 'confirmed') then 1 else 0 end else 0 end);
end $$;

-- ---------------------------------------------------------------------------
-- 6. Who may call what
-- ---------------------------------------------------------------------------
grant execute on function public.flux_return_pack(uuid, text, date, text), public.approve_tax_instruction(uuid), public.mark_tax_instruction_paid(uuid, jsonb),
  public.flux_instruction_renew(uuid), public.get_flux_tax(uuid), public.set_tax_autopay(uuid, boolean), public.get_attention(uuid), public.tax_payment_to_send(uuid)
  to authenticated;
revoke execute on function public.flux_return_pack(uuid, text, date, text), public.approve_tax_instruction(uuid), public.mark_tax_instruction_paid(uuid, jsonb),
  public.flux_instruction_renew(uuid), public.get_flux_tax(uuid), public.set_tax_autopay(uuid, boolean), public.get_attention(uuid), public.tax_payment_to_send(uuid)
  from public, anon;
revoke all on function public.svc_flux_return_update(uuid, text, date, text, jsonb), public.svc_flux_payment_instruction(jsonb), public.svc_tax_instruction_context(uuid),
  public.svc_tax_instruction_decide(uuid, jsonb), public.svc_tax_instruction_note(uuid, text, text), public.svc_flux_payment_status(jsonb),
  public.svc_tax_payment_to_send(uuid), public.svc_tax_instruction_work(), public.svc_tax_instruction_notified(uuid), public.svc_tax_payment_update(text, jsonb)
  from public, anon, authenticated;
grant execute on function public.svc_flux_return_update(uuid, text, date, text, jsonb), public.svc_flux_payment_instruction(jsonb), public.svc_tax_instruction_context(uuid),
  public.svc_tax_instruction_decide(uuid, jsonb), public.svc_tax_instruction_note(uuid, text, text), public.svc_flux_payment_status(jsonb),
  public.svc_tax_payment_to_send(uuid), public.svc_tax_instruction_work(), public.svc_tax_instruction_notified(uuid), public.svc_tax_payment_update(text, jsonb)
  to service_role;
revoke all on function private.tax_label(text), private.tax_when(text, date, int), private.tax_payee_name_ok(text), private.tax_expected(uuid, text, date, text, int),
  private.post_tax_paid(uuid, text, date, text, int, numeric, numeric, text, numeric, text, uuid, uuid, uuid, timestamptz, text, text),
  private.instruction_alert(public.tax_payment_instructions, text), private.instruction_block(public.tax_payment_instructions),
  private.instruction_payment(public.tax_payment_instructions, uuid, boolean), private.tax_narration(public.tax_payments, public.tax_payment_instructions),
  private.instruction_wallet_ok(public.tax_payment_instructions)
  from public, anon, authenticated;
