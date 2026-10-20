-- Counta, 28 October 2026 (second part): reconciling what Rev360 asks for with the return Counta sent.
--
-- The amount on Rev360's payment page is rarely the return's figure alone. Flutterwave adds its charge when it opens the
-- account, Rev360 adds penalties, interest and a late filing penalty to a late return, and Rev360 takes the input VAT credit
-- it holds for the business off the VAT. So Flux posts the amount with its parts (breakdown):
--   tax                  the tax Rev360 worked out on the return, before any credit
--   credit_applied       input VAT credit (VAT) or WHT credit notes (CIT) Rev360 took off
--   penalty, interest, late_filing_penalty   what Rev360 added
--   charges              Flutterwave's charge on the payment
-- and amount = tax - credit_applied + penalty + interest + late_filing_penalty + charges (to within a naira).
--
-- Counta checks each part against its own figures and pays by itself only when every part is explained:
--   - the tax agrees with the return (within a naira, or VAT rounding across the month's lines);
--   - the credit agrees with the credit Counta used for the month;
--   - penalties and interest only on a return that was filed after its due date, and only while the owner lets Counta pay
--     them (on unless switched off);
--   - Flutterwave's charge is at most 2% of the rest and never above 5,000 naira.
-- Anything else waits for the owner with the parts side by side. Each part is booked to its own account when paid:
-- the tax to the liability, penalties and interest to 6514, Flutterwave's charge to 6701, credit Rev360 held that the books
-- did not to 3999 (it belongs to the opening balances), credit Rev360 did not allow and tax it worked out above the return to
-- 6512. A CIT payment also clears the WHT credit notes (1401) Rev360 took off.
-- Without a breakdown Counta pays only an amount that agrees with the return, as before.

alter table public.tax_payment_instructions add column if not exists breakdown jsonb;
alter table public.tax_payment_instructions add column if not exists reconciliation jsonb;
alter table public.orgs add column if not exists tax_autopay_penalties boolean not null default true;

-- ---------------------------------------------------------------------------
-- What Counta says is due, now with the tax before credits, the credit and the rounding allowed
-- ---------------------------------------------------------------------------
-- {amount (what Counta expects to pay), tax (before credits), credit, tolerance, state, due}
create or replace function private.tax_expected(p_org uuid, p_tax text, p_period date, p_authority text, p_year int) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare vp public.vat_periods; v_amt numeric; v_n int; v_paid int; v_due date; cy public.cit_years; v_total numeric; v_pay numeric;
begin
  if p_tax = 'vat' then
    select * into vp from vat_periods where org_id = p_org and period = p_period;
    if not found then return jsonb_build_object('amount', null, 'state', 'open', 'due', (p_period + interval '1 month')::date + 20); end if;
    -- The template works VAT out on totals and Counta line by line: a kobo a line apart at most, a naira at least (as the
    -- VAT schedule allows when it ties the template to the month).
    select count(*) into v_n from journal_lines jl join journals j on j.id = jl.journal_id
    where jl.org_id = p_org and split_part(jl.account_code, '-', 1) in ('2201', '1402', '1405')
      and j.entry_date >= p_period and j.entry_date < (p_period + interval '1 month')::date and coalesce(j.source_type, '') not in ('vat_return', 'tax_payment');
    return jsonb_build_object('amount', vp.payable, 'tax', vp.payable + vp.credit_used, 'credit', vp.credit_used,
      'tolerance', greatest(1, round(0.01 * v_n, 2)),
      'state', case when vp.status = 'paid' then 'paid' else 'filed' end, 'due', (p_period + interval '1 month')::date + 20);
  elsif p_tax in ('wht', 'wvat') then
    select coalesce(sum(amount) filter (where status = 'deducted'), 0), count(*) filter (where status = 'deducted'), count(*) filter (where status = 'remitted'),
           min(due_date) filter (where status = 'deducted')
      into v_amt, v_n, v_paid, v_due
      from wht_deductions where org_id = p_org and authority = p_authority and period = p_period and (kind = 'wht') = (p_tax = 'wht');
    return jsonb_build_object('amount', case when v_n > 0 then round(v_amt, 2) end, 'tax', case when v_n > 0 then round(v_amt, 2) end, 'credit', 0, 'tolerance', 1,
      'state', case when v_n > 0 then 'filed' when v_paid > 0 then 'paid' else 'none' end,
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
    v_pay := round((cy.snapshot->'figures'->>'payable')::numeric, 2);
    v_total := round(coalesce((cy.snapshot->'figures'->>'total_tax')::numeric, v_pay), 2);
    return jsonb_build_object('amount', v_pay, 'tax', v_total, 'credit', greatest(v_total - v_pay, 0), 'tolerance', 1, 'state', 'filed',
      'due', (cy.period_to + interval '6 months')::date);
  end if;
  return jsonb_build_object('amount', null, 'state', 'none', 'due', null);
end $$;

-- ---------------------------------------------------------------------------
-- The parts Flux posts, and whether they explain the amount
-- ---------------------------------------------------------------------------
-- The breakdown as stored: every part a number of naira, none below zero, adding up to the amount.
create or replace function private.flux_breakdown(p jsonb, p_amount numeric) returns jsonb
language plpgsql stable set search_path = public, private as $$
declare k text; v numeric; out jsonb := '{}'::jsonb; v_sum numeric;
begin
  if p is null or jsonb_typeof(p) = 'null' then return null; end if;
  if jsonb_typeof(p) <> 'object' then raise exception 'breakdown must be an object.'; end if;
  if not (p ? 'tax') then raise exception 'breakdown.tax is required: the tax Rev360 worked out on the return, before any credit.'; end if;
  foreach k in array array['tax', 'credit_applied', 'penalty', 'interest', 'late_filing_penalty', 'charges'] loop
    if p ? k and jsonb_typeof(p->k) not in ('number', 'string', 'null') then raise exception 'breakdown.% must be a number.', k; end if;
    v := case when p ? k and jsonb_typeof(p->k) <> 'null' then private.num(p->>k) else 0 end;
    if v is null then raise exception 'breakdown.% must be a number.', k; end if;
    if v < 0 then raise exception 'breakdown.% cannot be below zero.', k; end if;
    out := out || jsonb_build_object(k, round(v, 2));
  end loop;
  v_sum := (out->>'tax')::numeric - (out->>'credit_applied')::numeric + (out->>'penalty')::numeric + (out->>'interest')::numeric
    + (out->>'late_filing_penalty')::numeric + (out->>'charges')::numeric;
  if abs(v_sum - p_amount) >= 1 then
    raise exception 'The breakdown comes to % (tax - credit_applied + penalty + interest + late_filing_penalty + charges), but amount is %.',
      private.naira(v_sum), private.naira(p_amount);
  end if;
  return out;
end $$;

-- The most Counta pays in Flutterwave charges without asking: 2% of the rest, never more than 5,000 naira (100 naira always).
create or replace function private.flux_charge_limit(p_rest numeric) returns numeric
language sql immutable set search_path = '' as $$
  select least(greatest(round(greatest(p_rest, 0) * 0.02, 2), 100), 5000)
$$;

-- When the return was due, when it was filed (as Flux reported, or when the PRN came), and whether that was late.
create or replace function private.return_timing(i public.tax_payment_instructions) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare e jsonb; v_due date; v_filed timestamptz;
begin
  e := private.tax_expected(i.org_id, i.tax, i.period, i.authority, i.accounting_year);
  v_due := (e->>'due')::date;
  if i.tax = 'cit' then
    select filed_at into v_filed from cit_years where org_id = i.org_id and accounting_year = i.accounting_year;
  else
    select filed_at into v_filed from flux_returns where org_id = i.org_id and tax = i.tax and period = i.period and authority = i.authority;
  end if;
  v_filed := coalesce(v_filed, i.received_at);
  return jsonb_build_object('due', v_due, 'filed_on', private.local_day(i.org_id, v_filed),
    'late', v_due is not null and private.local_day(i.org_id, v_filed) > v_due);
end $$;

-- Each part of what Rev360 asks for against Counta's own figures, and the first part that is not explained (reason).
create or replace function private.instruction_reconcile(i public.tax_payment_instructions) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare e jsonb; b jsonb := i.breakdown; t jsonb; v_ct numeric; v_cc numeric; v_tol numeric; v_adds numeric; v_lim numeric; v_rows jsonb := '[]'::jsonb;
  v_why text; v_tax_ok boolean; v_credit_ok boolean; v_charges_ok boolean; v_pen boolean;
begin
  e := private.tax_expected(i.org_id, i.tax, i.period, i.authority, i.accounting_year);
  if b is null then
    return jsonb_build_object('has_breakdown', false,
      'explained', i.expected is not null and abs(i.amount - i.expected) < 1,
      'rows', jsonb_build_array(jsonb_build_object('key', 'total', 'label', 'To pay', 'rev360', i.amount, 'counta', i.expected,
        'ok', i.expected is not null and abs(i.amount - i.expected) < 1)));
  end if;
  t := private.return_timing(i);
  v_ct := (e->>'tax')::numeric; v_cc := coalesce((e->>'credit')::numeric, 0); v_tol := coalesce((e->>'tolerance')::numeric, 1);
  v_adds := (b->>'penalty')::numeric + (b->>'interest')::numeric + (b->>'late_filing_penalty')::numeric;
  v_lim := private.flux_charge_limit(i.amount - (b->>'charges')::numeric);
  v_tax_ok := v_ct is not null and abs((b->>'tax')::numeric - v_ct) <= v_tol;
  v_credit_ok := abs((b->>'credit_applied')::numeric - v_cc) < 1;
  v_charges_ok := (b->>'charges')::numeric <= v_lim;
  v_pen := coalesce((select tax_autopay_penalties from orgs where id = i.org_id), true);
  v_rows := jsonb_build_array(jsonb_build_object('key', 'tax',
    'label', case i.tax when 'vat' then 'VAT on the return' when 'wht' then 'WHT on the schedule' when 'wvat' then 'Withholding VAT on the schedule' else 'Tax on the return' end,
    'rev360', b->'tax', 'counta', v_ct, 'ok', v_tax_ok));
  -- The credit line when either side took credit off (a mismatch shows even when Counta used none).
  if (b->>'credit_applied')::numeric > 0 or v_cc > 0 then
    v_rows := v_rows || jsonb_build_object('key', 'credit',
      'label', case i.tax when 'vat' then 'Less input VAT credit brought forward' when 'cit' then 'Less WHT credit notes' else 'Less credit' end,
      'rev360', b->'credit_applied', 'counta', v_cc, 'ok', v_credit_ok);
  end if;
  if (b->>'penalty')::numeric > 0 then v_rows := v_rows || jsonb_build_object('key', 'penalty', 'label', 'Penalty', 'rev360', b->'penalty', 'ok', (t->>'late')::boolean and v_pen); end if;
  if (b->>'interest')::numeric > 0 then v_rows := v_rows || jsonb_build_object('key', 'interest', 'label', 'Interest', 'rev360', b->'interest', 'ok', (t->>'late')::boolean and v_pen); end if;
  if (b->>'late_filing_penalty')::numeric > 0 then
    v_rows := v_rows || jsonb_build_object('key', 'late_filing_penalty', 'label', 'Late filing penalty', 'rev360', b->'late_filing_penalty', 'ok', (t->>'late')::boolean and v_pen);
  end if;
  if (b->>'charges')::numeric > 0 then v_rows := v_rows || jsonb_build_object('key', 'charges', 'label', 'Flutterwave charges', 'rev360', b->'charges', 'ok', v_charges_ok); end if;
  v_rows := v_rows || jsonb_build_object('key', 'total', 'label', 'To pay', 'rev360', i.amount, 'counta', i.expected);
  if v_ct is null then
    v_why := format('Counta has no %s for %s to check the amount against.',
      case i.tax when 'vat' then 'filed VAT return' when 'cit' then 'approved CIT return' else 'deductions' end, private.tax_when(i.tax, i.period, i.accounting_year));
  elsif not v_tax_ok then
    v_why := format('Rev360 worked the tax out as %s; the return in Counta comes to %s.', private.naira((b->>'tax')::numeric), private.naira(v_ct));
  elsif not v_credit_ok then
    v_why := case i.tax
      when 'vat' then format('Rev360 took %s of input VAT credit off; Counta used %s for this month. The credit carried forward differs, so check it before paying.',
        private.naira((b->>'credit_applied')::numeric), private.naira(v_cc))
      when 'cit' then format('Rev360 took %s of WHT credit notes off; Counta took off %s. Check the credit notes before paying.',
        private.naira((b->>'credit_applied')::numeric), private.naira(v_cc))
      else format('Rev360 took %s of credit off the tax. Check it before paying.', private.naira((b->>'credit_applied')::numeric)) end;
  elsif v_adds > 0 and not (t->>'late')::boolean then
    v_why := format('Rev360 added %s in penalties and interest, but Counta shows the return filed on time (due %s, filed %s). Check it before paying.',
      private.naira(v_adds), to_char((t->>'due')::date, 'FMDD Mon YYYY'), to_char((t->>'filed_on')::date, 'FMDD Mon YYYY'));
  elsif v_adds > 0 and not v_pen then
    v_why := format('Rev360 added %s in penalties and interest because the return was late. Paying those by itself is switched off for this business.', private.naira(v_adds));
  elsif not v_charges_ok then
    v_why := format('Flutterwave adds %s in charges, more than Counta pays without asking (%s). Check it before paying.',
      private.naira((b->>'charges')::numeric), private.naira(v_lim));
  end if;
  return jsonb_build_object('has_breakdown', true, 'explained', v_why is null, 'reason', v_why, 'rows', v_rows,
    'late', (t->>'late')::boolean, 'due', t->'due', 'filed_on', t->'filed_on', 'additions', v_adds, 'charges', b->'charges',
    'charge_limit', v_lim, 'tax_part', (b->>'tax')::numeric - (b->>'credit_applied')::numeric);
end $$;

-- ---------------------------------------------------------------------------
-- Taking the parts in
-- ---------------------------------------------------------------------------
-- p: as before, with breakdown: {tax, credit_applied, penalty, interest, late_filing_penalty, charges}
create or replace function public.svc_flux_payment_instruction(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_org uuid; v_tax text := lower(coalesce(p->>'tax', '')); v_period date; v_year int; v_auth text := coalesce(nullif(p->>'authority', ''), 'NRS');
  v_prn text := nullif(trim(coalesce(p->>'prn', '')), ''); v_amt numeric; a jsonb := coalesce(p->'account', '{}'::jsonb); v_no text; v_bank text; v_name text;
  v_exp timestamptz; i public.tax_payment_instructions; cy public.cit_years; e jsonb; v_bd jsonb;
begin
  begin v_org := (p->>'counta_org_id')::uuid; exception when others then v_org := null; end;
  if v_org is null then raise exception 'counta_org_id is required.'; end if;
  if not exists (select 1 from orgs where id = v_org) then raise exception 'This business is not on Counta.'; end if;
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
  v_bd := private.flux_breakdown(p->'breakdown', v_amt);
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
    update tax_payment_instructions set tax = v_tax, period = v_period, accounting_year = v_year, amount = v_amt, expected = (e->>'amount')::numeric, breakdown = v_bd,
      reconciliation = null, bank_name = left(v_bank, 120), bank_code = nullif(trim(coalesce(a->>'bank_code', '')), ''), account_number = v_no, account_name = left(v_name, 160),
      resolved_name = null, name_ok = null, expires_at = v_exp, flux_ref = coalesce(nullif(p->>'ref', ''), flux_ref), message = nullif(left(p->>'message', 500), ''),
      status = 'received', reason = null, updated_at = now()
    where id = i.id returning * into i;
  else
    insert into tax_payment_instructions (org_id, tax, period, accounting_year, authority, prn, amount, expected, breakdown, bank_name, bank_code, account_number,
      account_name, expires_at, flux_ref, message)
    values (v_org, v_tax, v_period, v_year, v_auth, v_prn, v_amt, (e->>'amount')::numeric, v_bd, left(v_bank, 120), nullif(trim(coalesce(a->>'bank_code', '')), ''), v_no,
      left(v_name, 160), v_exp, nullif(p->>'ref', ''), nullif(left(p->>'message', 500), ''))
    returning * into i;
  end if;
  -- An earlier PRN for the same return that was never paid gives way to this one.
  update tax_payment_instructions set status = 'replaced', updated_at = now()
  where org_id = v_org and tax = v_tax and period = v_period and authority = v_auth and id <> i.id and status in ('received', 'needs_approval', 'expired', 'renewing');
  return jsonb_build_object('id', i.id, 'status', i.status, 'duplicate', false);
end $$;

-- ---------------------------------------------------------------------------
-- Deciding: the amount check becomes the reconciliation when Flux sent the parts
-- ---------------------------------------------------------------------------
create or replace function private.instruction_block(i public.tax_payment_instructions) returns text
language plpgsql stable security definer set search_path = public, private as $$
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
end $$;

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
  update tax_payment_instructions set reconciliation = private.instruction_reconcile(i) where id = i.id returning * into i;
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

-- ---------------------------------------------------------------------------
-- Booking each part to its own account
-- ---------------------------------------------------------------------------
drop function if exists private.post_tax_paid(uuid, text, date, text, int, numeric, numeric, text, numeric, text, uuid, uuid, uuid, timestamptz, text, text);

-- p_breakdown: the parts Flux posted (null for a payment typed in, or a request without them).
create or replace function private.post_tax_paid(p_org uuid, p_tax text, p_period date, p_authority text, p_year int, p_amount numeric, p_expected numeric,
  p_credit_code text, p_fee numeric, p_ref text, p_by uuid, p_source_id uuid, p_bank_account uuid, p_at timestamptz, p_label text, p_payee text, p_breakdown jsonb)
returns public.journals
language plpgsql security definer set search_path = public, private as $$
declare j public.journals; m public.members; v_lines jsonb := '[]'::jsonb; v_amt numeric := round(p_amount, 2); v_left numeric; v_liab numeric; v_extra numeric;
  v_bal numeric; v_d numeric; c text; rm public.wht_remittances; e jsonb; b jsonb := p_breakdown; v_part numeric; v_credit numeric; v_dt numeric; v_dc numeric;
  v_remit numeric;
begin
  select * into m from members where id = p_by;
  e := private.tax_expected(p_org, p_tax, p_period, p_authority, p_year);
  -- The tax itself: what is left of the amount once Rev360's additions and Flutterwave's charge are taken out.
  v_part := case when b is null then v_amt
    else v_amt - (b->>'penalty')::numeric - (b->>'interest')::numeric - (b->>'late_filing_penalty')::numeric - (b->>'charges')::numeric end;
  if p_tax = 'cit' then
    -- What the books provided is cleared by the cash and the WHT credit notes Rev360 took off; the rest is the year's tax.
    v_credit := case when b is null then coalesce((e->>'credit')::numeric, 0) else (b->>'credit_applied')::numeric end;
    v_left := v_part + v_credit;
    foreach c in array array['2208', '2209'] loop
      v_bal := greatest(-(select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code = c), 0);
      v_d := least(v_left, v_bal);
      if v_d > 0.004 then
        v_lines := v_lines || jsonb_build_object('code', c, 'debit', v_d, 'memo', p_ref);
        v_left := v_left - v_d;
      end if;
    end loop;
    if v_left > 0.004 then v_lines := v_lines || jsonb_build_object('code', '7501', 'debit', v_left, 'memo', p_ref || ' · not provided for in the books'); end if;
    if v_credit > 0.004 then
      v_bal := greatest((select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and split_part(account_code, '-', 1) = '1401'), 0);
      v_d := least(v_credit, v_bal);
      if v_d > 0.004 then v_lines := v_lines || jsonb_build_object('code', private.acct(p_org, 'wht_receivable'), 'credit', v_d, 'memo', 'WHT credit notes used · ' || p_ref); end if;
      if v_credit - v_d > 0.004 then
        v_lines := v_lines || jsonb_build_object('code', '3999', 'credit', v_credit - v_d, 'memo', 'WHT credit notes on Rev360 that the books did not have · ' || p_ref);
      end if;
    end if;
    v_remit := v_part;
  elsif b is null then
    v_liab := case when p_expected is null then v_amt else least(v_amt, round(p_expected, 2)) end;
    v_extra := v_amt - v_liab;
    v_lines := v_lines || jsonb_build_object('code', private.acct(p_org, case p_tax when 'vat' then 'output_vat' when 'wht' then 'wht_payable' else 'wvat_payable' end),
      'debit', v_liab, 'memo', p_ref);
    if v_extra > 0.004 then v_lines := v_lines || jsonb_build_object('code', '6514', 'debit', v_extra, 'memo', 'Above the return: penalty or interest · ' || p_ref); end if;
    v_remit := v_liab;
  else
    -- The liability Counta holds for the return is cleared in full; where Rev360's tax or credit differs, the difference goes
    -- to its own account.
    v_liab := round(coalesce(p_expected, (e->>'amount')::numeric, v_part), 2);
    v_lines := v_lines || jsonb_build_object('code', private.acct(p_org, case p_tax when 'vat' then 'output_vat' when 'wht' then 'wht_payable' else 'wvat_payable' end),
      'debit', v_liab, 'memo', p_ref);
    v_dc := case when p_tax = 'vat' then (b->>'credit_applied')::numeric - coalesce((e->>'credit')::numeric, 0) else 0 end;
    v_dt := v_part - v_liab + v_dc;
    if v_dt > 0.004 then v_lines := v_lines || jsonb_build_object('code', '6512', 'debit', v_dt, 'memo', 'Rev360 worked the tax out above the return · ' || p_ref);
    elsif v_dt < -0.004 then v_lines := v_lines || jsonb_build_object('code', '6512', 'credit', -v_dt, 'memo', 'Rev360 worked the tax out below the return · ' || p_ref); end if;
    if v_dc > 0.004 then v_lines := v_lines || jsonb_build_object('code', '3999', 'credit', v_dc, 'memo', 'Input VAT credit on Rev360 that the books did not have · ' || p_ref);
    elsif v_dc < -0.004 then v_lines := v_lines || jsonb_build_object('code', '6512', 'debit', -v_dc, 'memo', 'Input VAT credit Rev360 did not allow · ' || p_ref); end if;
    v_remit := v_part;
  end if;
  if b is not null then
    if (b->>'penalty')::numeric > 0 then v_lines := v_lines || jsonb_build_object('code', '6514', 'debit', b->'penalty', 'memo', 'Penalty charged by the NRS · ' || p_ref); end if;
    if (b->>'late_filing_penalty')::numeric > 0 then
      v_lines := v_lines || jsonb_build_object('code', '6514', 'debit', b->'late_filing_penalty', 'memo', 'Late filing penalty · ' || p_ref);
    end if;
    if (b->>'interest')::numeric > 0 then v_lines := v_lines || jsonb_build_object('code', '6514', 'debit', b->'interest', 'memo', 'Interest charged by the NRS · ' || p_ref); end if;
    if (b->>'charges')::numeric > 0 then v_lines := v_lines || jsonb_build_object('code', '6701', 'debit', b->'charges', 'memo', 'Flutterwave charge on the payment · ' || p_ref); end if;
  end if;
  if coalesce(p_fee, 0) > 0 then v_lines := v_lines || jsonb_build_object('code', '6701', 'debit', round(p_fee, 2), 'memo', 'Transfer fee'); end if;
  v_lines := v_lines || jsonb_build_object('code', p_credit_code, 'credit', v_amt + round(coalesce(p_fee, 0), 2), 'memo', p_ref || coalesce(' · ' || p_payee, ''));
  j := private.post_entry(p_org, p_label, 'tax_payment', p_source_id, m.id, m.id, v_lines, p_at,
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'tax_payment', 'ref', p_ref, 'authority', p_authority, 'by', m.display_name)
      || case when b is not null then jsonb_build_object('breakdown', b) else '{}'::jsonb end)));
  if p_tax = 'vat' then
    update vat_periods set status = 'paid', paid_at = p_at, payment_journal_id = j.id, reference = p_ref where org_id = p_org and period = p_period and status <> 'paid';
  elsif p_tax in ('wht', 'wvat') then
    insert into wht_remittances (org_id, kind, authority, period, amount, paid_at, bank_account_id, reference, journal_id, created_by)
    values (p_org, p_tax, p_authority, p_period, greatest(round(v_remit, 2), 0.01), p_at, p_bank_account, p_ref, j.id, p_by) returning * into rm;
    update wht_deductions set status = 'remitted', remittance_id = rm.id where org_id = p_org and authority = p_authority and period = p_period and status = 'deducted'
      and (kind = 'wht') = (p_tax = 'wht');
  elsif p_tax = 'cit' then
    update cit_years set tax_paid_at = p_at, tax_paid_amount = v_amt, tax_payment_ref = p_ref where org_id = p_org and accounting_year = p_year;
  end if;
  return j;
end $$;

-- The two callers, now passing the parts.
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
      private.tax_label(x.kind) || ' paid from the tax wallet for ' || private.tax_when(x.kind, x.period, i.accounting_year), x.account_name,
      case when i.id is null then null else i.breakdown end);
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
    v_at, private.tax_label(i.tax) || ' paid to the NRS for ' || private.tax_when(i.tax, i.period, i.accounting_year), i.account_name, i.breakdown);
  update tax_payment_instructions set status = case when status = 'confirmed' then 'confirmed' else 'paid' end, paid_outside = true, journal_id = j.id, reason = null, updated_at = now()
  where id = i.id returning * into i;
  return to_jsonb(i) || jsonb_build_object('journal_ref', j.ref);
end $$;

-- ---------------------------------------------------------------------------
-- The screens: the parts side by side, and the owner's second switch
-- ---------------------------------------------------------------------------
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
      'approve', m.role = 'owner' or (private.perm_of(m, 'make_payments') and private.perm_of(m, 'approve_payments')),
      'record', private.perm_of(m, 'make_payments') or private.perm_of(m, 'keep_books'),
      'renew', private.perm_of(m, 'make_payments') or private.perm_of(m, 'file_tax'),
      'send', private.perm_of(m, 'file_tax'),
      'autopay', m.role = 'owner' or private.perm_of(m, 'manage_settings')));
end $$;

-- Whether Counta also pays the penalties and interest Rev360 adds to a late return without asking.
create or replace function public.set_tax_autopay_penalties(p_org uuid, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not (m.role = 'owner' or private.perm_of(m, 'manage_settings')) then raise exception 'Only the owner changes this.' using errcode = '42501'; end if;
  update orgs set tax_autopay_penalties = coalesce(p_on, true) where id = p_org;
  return jsonb_build_object('autopay_penalties', coalesce(p_on, true));
end $$;

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
grant execute on function public.set_tax_autopay_penalties(uuid, boolean) to authenticated;
revoke execute on function public.set_tax_autopay_penalties(uuid, boolean) from public, anon;
revoke all on function public.svc_flux_payment_instruction(jsonb), public.svc_tax_instruction_decide(uuid, jsonb), public.svc_tax_payment_update(text, jsonb)
  from public, anon, authenticated;
grant execute on function public.svc_flux_payment_instruction(jsonb), public.svc_tax_instruction_decide(uuid, jsonb), public.svc_tax_payment_update(text, jsonb)
  to service_role;
revoke all on function private.tax_expected(uuid, text, date, text, int), private.flux_breakdown(jsonb, numeric), private.flux_charge_limit(numeric),
  private.return_timing(public.tax_payment_instructions), private.instruction_reconcile(public.tax_payment_instructions),
  private.instruction_block(public.tax_payment_instructions),
  private.post_tax_paid(uuid, text, date, text, int, numeric, numeric, text, numeric, text, uuid, uuid, uuid, timestamptz, text, text, jsonb)
  from public, anon, authenticated;
