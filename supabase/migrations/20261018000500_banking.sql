-- Counta · Banking and the books inbox: statement import, the match-before-classify pipeline (CLS-03), AI classification with
-- a confidence gate, suspense with plain questions, learned rules, and bank reconciliation.
--
-- Pipeline for each bank line, in order; the first stage that decides wins and is recorded on the line:
--   1 already in the books (a payout, a confirmed payment, a bill paid, a cash drop)        → matched to that journal
--   2 a transfer the till recorded and nobody has confirmed yet                              → confirmed into this account
--   3 statutory payee (NRS, state IRS, PFAs, NSITF, ITF, NHF)                                → clears the 22xx head (AP-06)
--   4 a customer paying open sales, including WHT short-payment                             → payment received (AR-03)
--   5 a vendor being paid for open bills, including WHT withheld                            → bill paid (AP-03)
--   6 the business moving money between its own accounts                                   → transfer, both legs (or 9002 until the other leg)
--   7 a rule learned from an earlier decision (CLS-05)                                        → posted
--   8 payee types: bank charges, power, telcos, fuel                                          → posted
--   9 the bookkeeper agent (AI). Confidence at or above the business's threshold (never below 0.80) posts and stays reviewable;
--     below it the line goes to 9001 suspense with a question in the books inbox until someone confirms.
-- Bank lines never create output VAT, input VAT or WHT on their own (TAX-01, TAX-02, TAX-03).

-- ---------------------------------------------------------------------------
-- 1. Imports, reconciliations, stage on lines
-- ---------------------------------------------------------------------------
create table if not exists public.bank_imports (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  bank_account_id uuid not null references public.bank_accounts(id) on delete cascade,
  file_name text,
  lines_in_file int not null default 0,
  lines_added int not null default 0,
  from_date date,
  to_date date,
  closing_balance numeric(16,2),
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists bank_imports_account on public.bank_imports(bank_account_id, created_at desc);
create index if not exists bank_imports_org on public.bank_imports(org_id);
create index if not exists bank_imports_created_by_fk on public.bank_imports(created_by);
alter table public.bank_lines drop constraint if exists bank_lines_import_fk;
alter table public.bank_lines add constraint bank_lines_import_fk foreign key (import_id) references public.bank_imports(id) on delete set null;
create index if not exists bank_lines_import_fk_idx on public.bank_lines(import_id);
alter table public.bank_lines add column if not exists stage text;
alter table public.bank_lines add column if not exists party_key text;
alter table public.bank_lines add column if not exists ai_attempts int not null default 0;

create table if not exists public.bank_reconciliations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  bank_account_id uuid not null references public.bank_accounts(id) on delete cascade,
  as_of date not null,
  statement_balance numeric(16,2) not null,
  book_balance numeric(16,2) not null,
  not_in_books numeric(16,2) not null,
  not_on_statement numeric(16,2) not null,
  difference numeric(16,2) not null,
  status text not null check (status in ('balanced', 'unbalanced')),
  items jsonb not null default '{}'::jsonb,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (bank_account_id, as_of)
);
create index if not exists bank_reconciliations_org on public.bank_reconciliations(org_id, as_of desc);
create index if not exists bank_reconciliations_created_by_fk on public.bank_reconciliations(created_by);

alter table public.bank_imports enable row level security;
alter table public.bank_reconciliations enable row level security;
drop policy if exists bank_imports_read on public.bank_imports;
create policy bank_imports_read on public.bank_imports for select to authenticated using ((select private.can_handle_money(org_id)));
drop policy if exists bank_reconciliations_read on public.bank_reconciliations;
create policy bank_reconciliations_read on public.bank_reconciliations for select to authenticated using ((select private.can_handle_money(org_id)));

create or replace function private.party_key(p text) returns text
language sql immutable set search_path = '' as $$
  -- Who a narration is about: upper case, punctuation and references removed, banking words dropped, whole words only.
  select nullif(trim(regexp_replace(regexp_replace(regexp_replace(upper(coalesce(p, '')), '[^A-Z0-9 ]+', ' ', 'g'),
    '\y(TRF|TRANSFER|TRANS|FROM|TO|NIP|FT|MOB|MOBILE|USSD|POS|WEB|REF|NARR|PAYMENT|PYMT|PMT|FOR|VIA|ACCOUNT|AC|ACCT|INV|INVOICE|BEING|IFO|LESS|WHT|WEEK|BO|FRM|CR|DR|[A-Z]|[A-Z0-9]*[0-9][A-Z0-9]*)\y', ' ', 'g'),
    '\s+', ' ', 'g')), '')
$$;

-- Payee patterns match whole words (\y), so LAGOS is not diesel (AGO) and MOBILE is not a fuel station (MOBIL).
update public.payee_registry set pattern = '(\yITF\y|INDUSTRIAL TRAINING FUND)' where kind = 'statutory_itf';
update public.payee_registry set pattern = '(\yNHF\y|FEDERAL MORTGAGE BANK|\yFMBN\y)' where kind = 'statutory_nhf';
update public.payee_registry set pattern = '(\yNSITF\y)' where kind = 'statutory_nsitf';
update public.payee_registry set pattern = '(\yIKEDC\y|\yEKEDC\y|\yAEDC\y|\yIBEDC\y|\yPHED\y|\yEEDC\y|\yKEDCO\y|\yJED\y|\yBEDC\y|\yKAEDCO\y|\yYEDC\y|PREPAID METER|ELECTRICITY)' where kind = 'utility_power';
update public.payee_registry set pattern = '(\yMTN\y|\yAIRTEL\y|\yGLO\y|GLOBACOM|9MOBILE|AIRTIME)' where kind = 'telco';
update public.payee_registry set pattern = '(SPECTRANET|\ySMILE\y|STARLINK|\yIPNX\y|FIBREONE|SWIFT NETWORKS|TIZETI|DATA PLAN)' where kind = 'internet';
update public.payee_registry set pattern = '(TOTAL ?ENERGIES|MRS OIL|CONOIL|ARDOVA|FORTE OIL|NNPC RETAIL|\yOANDO\y|\yETERNA\y|11 PLC|\yMOBIL\y|FUEL STATION|FILLING STATION|PETROL)' where kind = 'fuel';
update public.payee_registry set pattern = '(DIESEL|\yAGO\y)' where kind = 'fuel_diesel';
update public.payee_registry set pattern = '(\yCAC\y|CORPORATE AFFAIRS)' where kind = 'cac';
update public.payee_registry set pattern = '(SMS ALERT|SMS CHARGE|MAINTENANCE FEE|\yCOT\y|ACCOUNT MAINTENANCE|TRANSFER FEE|NIP CHARGE|VAT ON NIP|\yCHARGES?$|COMMISSION ON TURNOVER|CARD MAINTENANCE)' where kind = 'bank_charge' and pattern like '%SMS ALERT%';

-- ---------------------------------------------------------------------------
-- 2. Posting from a bank line
-- ---------------------------------------------------------------------------
create or replace function private.line_time(p_org uuid, p_day date) returns timestamptz
language sql stable security definer set search_path = public, private as $$
  select (p_day::timestamp + interval '12 hours') at time zone coalesce((select timezone from orgs where id = p_org), 'Africa/Lagos')
$$;

-- Posts a bank line against one account: money in Dr bank / Cr account; money out Dr account / Cr bank.
create or replace function private.post_bank_line(p_line uuid, p_account text, p_party_type text, p_party uuid, p_memo text, p_stage text,
  p_meta jsonb, p_status text default 'posted') returns public.journals
language plpgsql security definer set search_path = public, private as $$
declare bl public.bank_lines; b public.bank_accounts; j public.journals; v_amt numeric;
begin
  select * into bl from bank_lines where id = p_line for update;
  select * into b from bank_accounts where id = bl.bank_account_id;
  if not private.postable(bl.org_id, p_account) then raise exception 'Account % cannot take postings.', p_account; end if;
  if p_account = b.ledger_code then raise exception 'A bank line cannot post to its own account.'; end if;
  v_amt := abs(bl.amount);
  j := private.post_entry(bl.org_id, coalesce(p_memo, bl.description), 'bank', bl.id, null, null, case when bl.amount > 0 then jsonb_build_array(
      jsonb_build_object('code', b.ledger_code, 'debit', v_amt, 'memo', bl.description),
      jsonb_build_object('code', p_account, 'credit', v_amt, 'party_type', p_party_type, 'party_id', p_party, 'memo', coalesce(p_memo, bl.description)))
    else jsonb_build_array(
      jsonb_build_object('code', p_account, 'debit', v_amt, 'party_type', p_party_type, 'party_id', p_party, 'memo', coalesce(p_memo, bl.description)),
      jsonb_build_object('code', b.ledger_code, 'credit', v_amt, 'memo', bl.description)) end,
    private.line_time(bl.org_id, bl.line_date),
    coalesce(p_meta, '{}'::jsonb) || jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id, 'source', bl.source,
      'date', bl.line_date, 'amount', bl.amount, 'narration', bl.description, 'stage', p_stage))));
  update bank_lines set status = p_status, journal_id = j.id, stage = p_stage,
    matched_by = coalesce(nullif(p_meta->>'matched_by', ''), case when p_stage = 'ai' then 'ai' when p_stage = 'user' then 'user' else 'rule' end),
    confidence = coalesce(nullif(p_meta->>'ai_confidence', '')::numeric, 1)
  where id = bl.id;
  return j;
end $$;

-- A line nobody can place yet goes to suspense (9001) with one plain question.
create or replace function private.suspend_line(p_line uuid, p_title text, p_question text, p_proposal jsonb, p_confidence numeric, p_rationale text,
  p_stage text, p_model text default null) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare bl public.bank_lines; j public.journals; v_id uuid;
begin
  select * into bl from bank_lines where id = p_line;
  if bl.status <> 'unmatched' then return bl.proposal_id; end if;
  j := private.post_bank_line(bl.id, private.acct(bl.org_id, 'suspense'), null, null, 'Suspense · ' || bl.description, p_stage,
    jsonb_build_object('origin', 'system', 'matched_by', 'system', 'ai_confidence', p_confidence), 'proposed');
  insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, holding_journal_id, model)
  values (bl.org_id, 'bookkeeper', 'bank_line', 'bank_line', bl.id, left(p_title, 200), p_question, coalesce(p_proposal, '{}'::jsonb), coalesce(p_confidence, 0),
    p_rationale, p_stage, 'pending', abs(bl.amount), j.id, p_model)
  returning id into v_id;
  update bank_lines set proposal_id = v_id where id = bl.id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Paying a bill (shared by pay_bill and the matcher)
-- ---------------------------------------------------------------------------
create or replace function private.record_bill_payment(p_bill uuid, p_bank uuid, p_gross numeric, p_wht numeric, p_at timestamptz, p_reference text,
  m public.members, p_method text default 'bank') returns public.journals
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; v public.vendors; ba public.bank_accounts; j public.journals;
begin
  select * into b from bills where id = p_bill for update;
  select * into v from vendors where id = b.vendor_id;
  select * into ba from bank_accounts where id = p_bank;
  j := private.post_entry(b.org_id, 'Paid ' || v.name || ' · ' || b.number, 'bill_payment', b.id, m.id, m.id, jsonb_build_array(
      jsonb_build_object('code', private.acct(b.org_id, 'payables'), 'debit', p_gross, 'party_type', 'vendor', 'party_id', v.id, 'doc_type', 'bill', 'doc_id', b.id, 'memo', b.number),
      jsonb_build_object('code', ba.ledger_code, 'credit', p_gross - p_wht, 'memo', b.number || ' · ' || v.name || coalesce(' · ' || nullif(trim(p_reference), ''), '')),
      jsonb_build_object('code', private.acct(b.org_id, 'wht_payable'), 'credit', p_wht, 'party_type', 'vendor', 'party_id', v.id, 'doc_type', 'bill', 'doc_id', b.id,
        'memo', 'WHT ' || trim(to_char(b.wht_rate * 100, 'FM990.##')) || '% on ' || b.number)), p_at,
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'payment', 'ref', nullif(trim(p_reference), ''), 'by', m.display_name))));
  insert into bill_payments (org_id, bill_id, method, status, gross, wht, net, bank_account_id, paid_at, reference, journal_id, created_by)
  values (b.org_id, b.id, p_method, 'paid', p_gross, p_wht, p_gross - p_wht, ba.id, p_at, nullif(trim(p_reference), ''), j.id, m.id);
  perform private.refresh_bill(b.id);
  return j;
end $$;

-- ---------------------------------------------------------------------------
-- 4. The deterministic stages
-- ---------------------------------------------------------------------------
create or replace function private.name_in(p_name text, p_narration text) returns boolean
language sql immutable set search_path = public, private as $$
  select length(coalesce(private.party_key(p_name), '')) >= 4 and (
    position(private.party_key(p_name) in coalesce(private.party_key(p_narration), '')) > 0
    or (length(coalesce(private.party_key(p_narration), '')) >= 6 and position(private.party_key(p_narration) in private.party_key(p_name)) > 0))
$$;

create or replace function private.match_bank_line(p_line uuid) returns text
language plpgsql security definer set search_path = public, private as $$
declare bl public.bank_lines; b public.bank_accounts; v_amt numeric; v_in boolean; r record; c public.collections; v_cnt int; m public.members;
  v_cust public.customers; v_vendor public.vendors; v_due numeric; v_rate numeric; v_gross numeric; v_wht numeric; v_head numeric; j public.journals;
  other public.bank_lines; ob public.bank_accounts; v_key text; v_rule public.entity_rules; v_at timestamptz;
begin
  select * into bl from bank_lines where id = p_line for update;
  if bl.status <> 'unmatched' then return bl.stage; end if;
  select * into b from bank_accounts where id = bl.bank_account_id;
  v_amt := abs(bl.amount); v_in := bl.amount > 0;
  v_key := private.party_key(coalesce(nullif(bl.counterparty, ''), bl.description));
  update bank_lines set party_key = v_key where id = bl.id;
  v_at := private.line_time(bl.org_id, bl.line_date);
  -- Actions are taken in the name of the business owner; the line and its evidence say why.
  select * into m from members where org_id = bl.org_id and role = 'owner' and status = 'active' order by created_at limit 1;

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
  end if;

  if v_in then
    -- 4 A customer named in the narration paying open sales (AR-03).
    for v_cust in select cu.* from customers cu where cu.org_id = bl.org_id and not cu.is_walk_in and not cu.archived
        and private.name_in(cu.name, coalesce(bl.counterparty, '') || ' ' || bl.description)
        order by length(cu.name) desc limit 1 loop
      select coalesce(sum(s.total - s.amount_paid - s.credited), 0) into v_due from sales s
      where s.customer_id = v_cust.id and s.status in ('open', 'partially_paid') and s.journal_id is not null;
      -- Exactly what is owed on one sale, or on all of them.
      select s.id into r from sales s where s.customer_id = v_cust.id and s.status in ('open', 'partially_paid') and s.journal_id is not null
        and s.total - s.amount_paid - s.credited = v_amt order by s.due_date limit 1;
      if r.id is not null or abs(v_due - v_amt) < 0.005 then
        c := private.add_collection(bl.org_id, v_cust.id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
          'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'Matched from the bank statement', 'spread', r.id is null), m, 'confirmed',
          case when r.id is not null then array[r.id] end);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'customer', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'customer';
      end if;
      -- Short by withholding tax at a standard rate: the difference is a WHT credit (AR-03, TAX-03).
      foreach v_rate in array array[0.02, 0.05, 0.10] loop
        select s.id, s.total - s.amount_paid - s.credited due into r from sales s where s.customer_id = v_cust.id and s.status in ('open', 'partially_paid')
          and s.journal_id is not null and abs(round((s.total - s.amount_paid - s.credited) - round(s.subtotal * v_rate, 2), 2) - v_amt) < 0.005
        order by s.due_date limit 1;
        if r.id is not null then
          perform private.add_collection(bl.org_id, v_cust.id, r.due - v_amt, 'wht_credit', jsonb_build_object('reference', 'WHT deducted', 'wht_rate', v_rate,
            'received_at', v_at, 'note', 'Collect the WHT credit note', 'spread', false), m, 'confirmed', array[r.id]);
          c := private.add_collection(bl.org_id, v_cust.id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
            'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'Matched from the bank statement', 'spread', false), m, 'confirmed', array[r.id]);
          update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'customer_wht', matched_by = 'system', confidence = 1 where id = bl.id;
          return 'customer_wht';
        end if;
      end loop;
      -- Paying part of what is owed: oldest first. Paying with nothing owed: held as an advance, flagged (AR rule).
      c := private.add_collection(bl.org_id, v_cust.id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
        'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', case when v_due > 0 then 'Part payment matched from the bank statement'
          else 'No invoice open: held as customer credit' end, 'spread', true), m, 'confirmed', null);
      update bank_lines set status = 'matched', journal_id = c.journal_id, stage = case when v_due > 0 then 'customer_part' else 'customer_advance' end,
        matched_by = 'system', confidence = case when v_due > 0 then 0.9 else 0.8 end where id = bl.id;
      if v_due <= 0 then
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'bookkeeper', 'advance_without_invoice', 'bank_line', bl.id, v_cust.name || ' paid with nothing owed',
          'Held as customer credit. Raise the invoice it was for, or refund it.', jsonb_build_object('customer_id', v_cust.id), 0.8,
          'AR: inflow from a known customer with no open invoice', 'customer', 'info', v_amt, c.journal_id) on conflict do nothing;
      end if;
      return case when v_due > 0 then 'customer_part' else 'customer_advance' end;
    end loop;
  else
    -- 5 A vendor named in the narration being paid for open bills (AP-03).
    for v_vendor in select v.* from vendors v where v.org_id = bl.org_id
        and (private.name_in(v.name, coalesce(bl.counterparty, '') || ' ' || bl.description)
             or (v.account_number is not null and position(v.account_number in coalesce(bl.counterparty_account, '') || bl.description) > 0))
        order by length(v.name) desc limit 1 loop
      for r in select bb.*, bb.total - bb.amount_paid due, greatest(bb.wht_expected - bb.wht_withheld, 0) wht_left from bills bb
          where bb.vendor_id = v_vendor.id and bb.status in ('approved', 'partially_paid') order by bb.due_date loop
        v_gross := null;
        if abs(r.due - v_amt) < 0.005 then v_gross := r.due; v_wht := 0;
        elsif r.wht_left > 0 and abs(r.due - r.wht_left - v_amt) < 0.005 then v_gross := r.due; v_wht := r.wht_left;
        end if;
        if v_gross is not null then
          j := private.record_bill_payment(r.id, b.id, v_gross, v_wht, v_at, coalesce(bl.reference, left(bl.description, 60)), m);
          update bank_lines set status = 'matched', journal_id = j.id, stage = 'vendor_bill', matched_by = 'system', confidence = 1 where id = bl.id;
          return 'vendor_bill';
        end if;
      end loop;
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
      -- The other leg already sits in 9002 clearing: this leg clears it.
      j := private.post_bank_line(bl.id, private.acct(bl.org_id, 'bank_clearing'), null, null, 'Transfer between own accounts · ' || ob.name, 'transfer',
        jsonb_build_object('matched_by', 'system'), 'matched');
      update bank_lines set stage = 'transfer' where id = other.id;
    end if;
    return 'transfer';
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
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Import and run
-- ---------------------------------------------------------------------------
-- p_lines: [{date, amount (+in / -out) | credit, debit, description, reference, balance, counterparty, counterparty_account}]
create or replace function public.import_bank_lines(p_org uuid, p_bank_account uuid, p_lines jsonb, p_meta jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; b public.bank_accounts; imp public.bank_imports; x jsonb; v_day date; v_amt numeric; v_desc text; v_fp text; v_seen jsonb := '{}'::jsonb;
  v_n int; v_added int := 0; v_in int := 0; v_ids uuid[] := '{}'; v_id uuid; v_last_bal numeric; v_last_day date; v_res jsonb;
begin
  m := private.require(p_org, 'keep_books');
  select * into b from bank_accounts where id = p_bank_account and org_id = p_org and active;
  if not found then raise exception 'Choose the bank account this statement is for.'; end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'The statement has no lines.'; end if;
  if jsonb_array_length(p_lines) > 5000 then raise exception 'Import up to 5,000 lines at a time.'; end if;
  insert into bank_imports (org_id, bank_account_id, file_name, lines_in_file, created_by)
  values (p_org, b.id, left(p_meta->>'file_name', 200), jsonb_array_length(p_lines), m.id) returning * into imp;
  for x in select * from jsonb_array_elements(p_lines) loop
    v_in := v_in + 1;
    v_day := private.date_or_null(x->>'date');
    v_amt := coalesce(private.num(x->>'amount'), coalesce(private.num(x->>'credit'), 0) - coalesce(private.num(x->>'debit'), 0));
    v_desc := left(regexp_replace(coalesce(x->>'description', ''), '\s+', ' ', 'g'), 500);
    if v_day is null then raise exception 'Line %: the date is not readable.', v_in; end if;
    continue when coalesce(round(v_amt, 2), 0) = 0;
    -- The same line twice in one statement is real (two SMS charges a day); the same line in two overlapping statements is not.
    v_fp := md5(b.id::text || '|' || v_day || '|' || round(v_amt, 2) || '|' || coalesce(upper(trim(x->>'reference')), '') || '|' || upper(v_desc));
    v_n := coalesce((v_seen->>v_fp)::int, 0) + 1;
    v_seen := jsonb_set(v_seen, array[v_fp], to_jsonb(v_n));
    insert into bank_lines (org_id, bank_account_id, line_date, amount, balance_after, description, reference, counterparty, counterparty_account, source, import_id, fingerprint)
    values (p_org, b.id, v_day, round(v_amt, 2), round(private.num(x->>'balance'), 2), v_desc, nullif(trim(x->>'reference'), ''), nullif(trim(x->>'counterparty'), ''),
      nullif(trim(x->>'counterparty_account'), ''), 'statement', imp.id, v_fp || ':' || v_n)
    on conflict do nothing returning id into v_id;
    if v_id is not null then v_added := v_added + 1; v_ids := v_ids || v_id; end if;
    if private.num(x->>'balance') is not null and (v_last_day is null or v_day >= v_last_day) then v_last_bal := round(private.num(x->>'balance'), 2); v_last_day := v_day; end if;
  end loop;
  update bank_imports set lines_added = v_added, from_date = (select min(line_date) from bank_lines where import_id = imp.id),
    to_date = (select max(line_date) from bank_lines where import_id = imp.id), closing_balance = coalesce(private.num(p_meta->>'closing_balance'), v_last_bal)
  where id = imp.id returning * into imp;
  if imp.closing_balance is not null and imp.to_date is not null then
    update bank_accounts set anchor_balance = imp.closing_balance, anchor_at = private.line_time(p_org, imp.to_date) + interval '11 hours 59 minutes', anchor_source = 'statement'
    where id = b.id and (anchor_at is null or anchor_at <= private.line_time(p_org, imp.to_date) + interval '11 hours 59 minutes');
  end if;
  v_res := private.run_matching(p_org, b.id);
  return jsonb_build_object('import_id', imp.id, 'in_file', v_in, 'added', v_added, 'duplicates', v_in - v_added) || v_res;
end $$;

create or replace function private.run_matching(p_org uuid, p_bank_account uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare bl record; v_stage text; v_counts jsonb := '{}'::jsonb; v_left int := 0;
begin
  for bl in select id from bank_lines where org_id = p_org and status = 'unmatched' and (p_bank_account is null or bank_account_id = p_bank_account)
            order by line_date, created_at loop
    v_stage := private.match_bank_line(bl.id);
    if v_stage is null then v_left := v_left + 1;
    else v_counts := jsonb_set(v_counts, array[v_stage], to_jsonb(coalesce((v_counts->>v_stage)::int, 0) + 1)); end if;
  end loop;
  -- What is left goes to the bookkeeper agent.
  if v_left > 0 then perform private.call_function('atlas', jsonb_build_object('action', 'classify_lines', 'org_id', p_org)); end if;
  return jsonb_build_object('matched', v_counts, 'for_ai', v_left);
end $$;

create or replace function public.run_bank_matching(p_org uuid, p_bank_account uuid default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.require(p_org, 'keep_books');
  return private.run_matching(p_org, p_bank_account);
end $$;

-- ---------------------------------------------------------------------------
-- 6. The bookkeeper agent's answers (service role)
-- ---------------------------------------------------------------------------
-- Lines the agent should look at, with what it needs to decide.
create or replace function public.svc_lines_for_ai(p_org uuid, p_limit int default 40) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object(
    'org', (select jsonb_build_object('id', o.id, 'name', o.name, 'industry', o.industry, 'vat_registered', o.vat_registered,
       'cash_sales_without_invoices', o.cash_sales_without_invoices, 'threshold', greatest(o.auto_post_threshold, 0.8)) from orgs o where o.id = p_org),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('id', bl.id, 'date', bl.line_date, 'amount', bl.amount, 'narration', bl.description,
        'reference', bl.reference, 'counterparty', bl.counterparty, 'account', b.name, 'account_kind', b.kind,
        'history', (select jsonb_agg(h) from (select l.account_code code, count(*) n from bank_lines x join journal_lines l on l.journal_id = x.journal_id
            and l.account_code <> b.ledger_code where x.org_id = p_org and x.party_key = bl.party_key and x.status in ('posted', 'matched') and x.id <> bl.id
            group by 1 order by 2 desc limit 3) h)) order by bl.line_date), '[]'::jsonb)
      from (select * from bank_lines where org_id = p_org and status = 'unmatched' and ai_attempts < 3 order by line_date limit greatest(p_limit, 1)) bl
      join bank_accounts b on b.id = bl.bank_account_id),
    'accounts', (select jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name, 'category', a.category, 'ifrs_line', a.ifrs_line) order by a.code)
      from private.accounts_of(p_org) a
      where a.active and not a.is_group and private.postable(p_org, a.code) and a.code !~ '^(101|1101|1102|1203|1201|1202|2101|2102|2201|1402|1401|2202|9)'),
    'customers', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name)), '[]'::jsonb) from customers where org_id = p_org and not is_walk_in and not archived),
    'vendors', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name)), '[]'::jsonb) from vendors where org_id = p_org),
    'directors', (select coalesce(jsonb_agg(display_name), '[]'::jsonb) from members where org_id = p_org and role = 'owner'))
$$;

-- p: {account_code, confidence, rationale, question, title, party_type, party_id, kind, model}
create or replace function public.svc_classify_line(p_line uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare bl public.bank_lines; o public.orgs; v_conf numeric := least(greatest(coalesce(private.num(p->>'confidence'), 0), 0), 1); v_code text := nullif(p->>'account_code', '');
  j public.journals; v_threshold numeric; v_pid uuid;
begin
  select * into bl from bank_lines where id = p_line for update;
  if not found or bl.status <> 'unmatched' then return jsonb_build_object('ok', false, 'reason', 'not_open'); end if;
  update bank_lines set ai_attempts = ai_attempts + 1 where id = bl.id;
  select * into o from orgs where id = bl.org_id;
  v_threshold := greatest(coalesce(o.auto_post_threshold, 0.8), 0.8);
  -- The agent may only use accounts a bank line is allowed to reach (CLS-01, TAX-01..03).
  if v_code is not null and (not private.postable(bl.org_id, v_code) or v_code ~ '^(101|1101|1102|1201|1202|1203|2101|2102|2201|1402|1401|2202|9)') then
    v_code := null; v_conf := least(v_conf, 0.5);
  end if;
  if v_code is not null and v_conf >= v_threshold then
    j := private.post_bank_line(bl.id, v_code, nullif(p->>'party_type', ''), nullif(p->>'party_id', '')::uuid, coalesce(nullif(p->>'title', ''), bl.description), 'ai',
      jsonb_build_object('origin', 'ai', 'ai_confidence', v_conf, 'matched_by', 'ai'));
    insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id, model)
    values (bl.org_id, 'bookkeeper', coalesce(nullif(p->>'kind', ''), 'bank_line'), 'bank_line', bl.id, coalesce(nullif(p->>'title', ''), bl.description), null,
      jsonb_build_object('account_code', v_code, 'party_type', p->>'party_type', 'party_id', p->>'party_id'), v_conf, p->>'rationale', 'ai', 'auto_posted', abs(bl.amount), j.id, p->>'model')
    returning id into v_pid;
    update bank_lines set proposal_id = v_pid where id = bl.id;
    return jsonb_build_object('ok', true, 'posted', true, 'journal_id', j.id);
  end if;
  v_pid := private.suspend_line(bl.id, coalesce(nullif(p->>'title', ''), bl.description),
    coalesce(nullif(p->>'question', ''), case when bl.amount > 0 then 'What was this money for?' else 'What was this payment for?' end),
    jsonb_build_object('account_code', v_code, 'party_type', p->>'party_type', 'party_id', p->>'party_id', 'kind', p->>'kind'), v_conf, p->>'rationale', 'ai', p->>'model');
  return jsonb_build_object('ok', true, 'posted', false, 'proposal_id', v_pid);
end $$;

-- Without AI (no key, or it failed three times): suspense with a question.
create or replace function public.svc_suspend_rest(p_org uuid) returns int
language plpgsql security definer set search_path = public, private as $$
declare bl record; n int := 0;
begin
  for bl in select id, amount from bank_lines where org_id = p_org and status = 'unmatched' and (ai_attempts >= 3 or created_at < now() - interval '1 hour') loop
    perform private.suspend_line(bl.id, 'Unexplained ' || case when bl.amount > 0 then 'money in' else 'payment' end,
      case when bl.amount > 0 then 'What was this money for?' else 'What was this payment for?' end, '{}'::jsonb, 0, 'Nothing in the books or the rules explains it',
      'suspense');
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- 7. The books inbox: confirm, change or dismiss
-- ---------------------------------------------------------------------------
-- p: {action: 'approve'|'change'|'ignore'|'dismiss', account_code, party_type, party_id, remember, note}
create or replace function public.resolve_proposal(p_proposal uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare pr public.ai_proposals; m public.members; bl public.bank_lines; v_code text; v_action text := coalesce(nullif(p->>'action', ''), 'approve'); j public.journals;
  b public.bank_accounts; v_amt numeric; v_party_type text := nullif(p->>'party_type', ''); v_party uuid := nullif(p->>'party_id', '')::uuid;
begin
  select * into pr from ai_proposals where id = p_proposal for update;
  if not found then raise exception 'Not found.'; end if;
  m := private.require(pr.org_id, 'keep_books');
  if pr.status not in ('pending', 'auto_posted', 'info') then raise exception 'This was already decided.'; end if;
  if v_action = 'dismiss' then
    if pr.status = 'pending' and pr.holding_journal_id is not null then raise exception 'Choose where this goes, or mark it as not a real transaction.'; end if;
    update ai_proposals set status = 'approved', decided_by = m.id, decided_at = now(), decision = p where id = pr.id;
    return jsonb_build_object('status', 'dismissed');
  end if;
  if pr.source_type <> 'bank_line' then
    raise exception 'Open the % to decide it.', replace(pr.kind, '_', ' ');
  end if;
  select * into bl from bank_lines where id = pr.source_id for update;
  select * into b from bank_accounts where id = bl.bank_account_id;
  v_amt := abs(bl.amount);
  if v_action = 'ignore' then
    -- Not a real transaction (a duplicate or a reversed transfer on the statement): the suspense entry is taken back.
    if pr.holding_journal_id is not null then perform private.reverse_entry(pr.holding_journal_id, m.id, 'Not a real transaction: ' || coalesce(p->>'note', ''), null); end if;
    if pr.status = 'auto_posted' and pr.journal_id is not null then perform private.reverse_entry(pr.journal_id, m.id, 'Not a real transaction', null); end if;
    update bank_lines set status = 'ignored', note = nullif(trim(p->>'note'), '') where id = bl.id;
    update ai_proposals set status = 'rejected', decided_by = m.id, decided_at = now(), decision = p where id = pr.id;
    return jsonb_build_object('status', 'ignored');
  end if;
  v_code := coalesce(nullif(p->>'account_code', ''), pr.proposal->>'account_code');
  if v_code is null or not private.postable(pr.org_id, v_code) or v_code = b.ledger_code then raise exception 'Choose the account this belongs to.'; end if;
  if v_code ~ '^(1101|1102)' and v_party_type is distinct from 'customer' then raise exception 'Say which customer.'; end if;
  if v_code ~ '^(2101|2102)' and v_party_type is distinct from 'vendor' then raise exception 'Say which vendor.'; end if;
  if v_code ~ '^(2201|1402|2202|1401)' then raise exception 'VAT and WHT come only from invoices and bills, not from bank lines.'; end if;
  if pr.status = 'pending' and pr.holding_journal_id is not null then
    -- Out of suspense into the account chosen.
    j := private.post_entry(pr.org_id, 'Confirmed: ' || bl.description, 'reclass', bl.id, m.id, m.id,
      case when bl.amount > 0 then jsonb_build_array(
          jsonb_build_object('code', private.acct(pr.org_id, 'suspense'), 'debit', v_amt, 'memo', 'Out of suspense'),
          jsonb_build_object('code', v_code, 'credit', v_amt, 'party_type', v_party_type, 'party_id', v_party, 'memo', bl.description))
        else jsonb_build_array(
          jsonb_build_object('code', v_code, 'debit', v_amt, 'party_type', v_party_type, 'party_id', v_party, 'memo', bl.description),
          jsonb_build_object('code', private.acct(pr.org_id, 'suspense'), 'credit', v_amt, 'memo', 'Out of suspense')) end,
      private.line_time(pr.org_id, bl.line_date),
      jsonb_build_object('origin', 'manual', 'ai_confidence', pr.confidence, 'ai_proposal_id', pr.id,
        'evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id), jsonb_build_object('type', 'decision', 'by', m.display_name, 'note', p->>'note'))));
    update bank_lines set status = 'posted', stage = 'user', matched_by = 'user', confidence = 1 where id = bl.id;
  elsif pr.status = 'auto_posted' and v_action = 'change' and v_code <> pr.proposal->>'account_code' then
    -- The agent posted it, a person says otherwise: move it.
    j := private.post_entry(pr.org_id, 'Corrected: ' || bl.description, 'reclass', bl.id, m.id, m.id,
      private.reclass_pair(v_code, pr.proposal->>'account_code', case when bl.amount > 0 then -v_amt else v_amt end, null, null), now(),
      jsonb_build_object('origin', 'manual', 'ai_proposal_id', pr.id));
  end if;
  update ai_proposals set status = 'approved', decided_by = m.id, decided_at = now(), decision = p || jsonb_build_object('account_code', v_code),
    journal_id = coalesce(j.id, journal_id) where id = pr.id;
  -- Learn the party for next time (CLS-05).
  if coalesce((p->>'remember')::boolean, false) and bl.party_key is not null then
    insert into entity_rules (org_id, party_key, direction, account_code, vendor_id, customer_id, note, source, created_by)
    values (pr.org_id, bl.party_key, case when bl.amount > 0 then 'in' else 'out' end, v_code,
      case when v_party_type = 'vendor' then v_party end, case when v_party_type = 'customer' then v_party end, nullif(trim(p->>'note'), ''), 'reviewer', m.id)
    on conflict (org_id, party_key, direction) do update set account_code = excluded.account_code, vendor_id = excluded.vendor_id, customer_id = excluded.customer_id,
      note = coalesce(excluded.note, entity_rules.note);
  end if;
  return jsonb_build_object('status', 'approved', 'journal_ref', j.ref);
end $$;

-- Tie a line to something already in the books (a journal on the same account), by hand.
create or replace function public.match_bank_line_to(p_line uuid, p_journal uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare bl public.bank_lines; m public.members; b public.bank_accounts;
begin
  select * into bl from bank_lines where id = p_line for update;
  if not found then raise exception 'Line not found.'; end if;
  m := private.require(bl.org_id, 'keep_books');
  if bl.status <> 'unmatched' then raise exception 'This line is already %.', bl.status; end if;
  select * into b from bank_accounts where id = bl.bank_account_id;
  if not exists (select 1 from journal_lines where journal_id = p_journal and org_id = bl.org_id and account_code = b.ledger_code
                 and (case when bl.amount > 0 then debit else credit end) = abs(bl.amount)) then
    raise exception 'That entry does not move this account by the same amount.';
  end if;
  update bank_lines set status = 'matched', journal_id = p_journal, stage = 'user', matched_by = 'user', confidence = 1 where id = bl.id;
  return jsonb_build_object('status', 'matched');
end $$;

-- ---------------------------------------------------------------------------
-- 8. Reconciliation
-- ---------------------------------------------------------------------------
create or replace function private.reconcile(p_bank_account uuid, p_as_of date, p_statement numeric) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare b public.bank_accounts; v_book numeric; v_stmt numeric; v_not_in_books numeric; v_not_on_stmt numeric; v_items jsonb; v_first date;
begin
  select * into b from bank_accounts where id = p_bank_account;
  select coalesce(sum(l.debit - l.credit), 0) into v_book from journal_lines l join journals j on j.id = l.journal_id
  where l.org_id = b.org_id and l.account_code = b.ledger_code and j.entry_date <= p_as_of;
  v_stmt := coalesce(p_statement,
    (select balance_after from bank_lines where bank_account_id = b.id and line_date <= p_as_of and balance_after is not null order by line_date desc, created_at desc limit 1),
    case when b.anchor_at is not null and private.local_day(b.org_id, b.anchor_at) <= p_as_of then b.anchor_balance end);
  select min(line_date) into v_first from bank_lines where bank_account_id = b.id;
  select coalesce(sum(amount), 0) into v_not_in_books from bank_lines where bank_account_id = b.id and line_date <= p_as_of and status = 'unmatched';
  -- Entries in the books not yet seen on a statement (only from the first statement date on, so opening entries are not counted).
  select coalesce(sum(l.debit - l.credit), 0) into v_not_on_stmt from journal_lines l join journals j on j.id = l.journal_id
  where l.org_id = b.org_id and l.account_code = b.ledger_code and j.entry_date <= p_as_of and v_first is not null and j.entry_date >= v_first
    and j.source_type not in ('opening') and not exists (select 1 from bank_lines x where x.bank_account_id = b.id and x.journal_id = l.journal_id);
  v_items := jsonb_build_object(
    'not_in_books', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'date', line_date, 'amount', amount, 'description', description) order by line_date), '[]'::jsonb)
      from bank_lines where bank_account_id = b.id and line_date <= p_as_of and status = 'unmatched'),
    'not_on_statement', (select coalesce(jsonb_agg(jsonb_build_object('journal_id', j.id, 'ref', j.ref, 'date', j.entry_date, 'memo', j.memo, 'amount', l.debit - l.credit)
        order by j.entry_date), '[]'::jsonb)
      from journal_lines l join journals j on j.id = l.journal_id
      where l.org_id = b.org_id and l.account_code = b.ledger_code and j.entry_date <= p_as_of and v_first is not null and j.entry_date >= v_first
        and j.source_type not in ('opening') and not exists (select 1 from bank_lines x where x.bank_account_id = b.id and x.journal_id = l.journal_id)));
  return jsonb_build_object('bank_account_id', b.id, 'name', b.name, 'ledger_code', b.ledger_code, 'as_of', p_as_of, 'book_balance', v_book,
    'statement_balance', v_stmt, 'not_in_books', v_not_in_books, 'not_on_statement', v_not_on_stmt,
    'difference', case when v_stmt is null then null else round(v_stmt - (v_book + v_not_in_books - v_not_on_stmt), 2) end, 'items', v_items);
end $$;

create or replace function public.bank_reconciliation(p_bank_account uuid, p_as_of date default null, p_statement_balance numeric default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare b public.bank_accounts;
begin
  select * into b from bank_accounts where id = p_bank_account;
  if not found then raise exception 'Account not found.'; end if;
  perform private.require(b.org_id, null);
  if not private.can_handle_money(b.org_id) then raise exception 'Your role does not see bank balances.' using errcode = '42501'; end if;
  return private.reconcile(b.id, coalesce(p_as_of, private.local_day(b.org_id, now())), p_statement_balance);
end $$;

create or replace function public.save_bank_reconciliation(p_bank_account uuid, p_as_of date, p_statement_balance numeric) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.bank_accounts; m public.members; r jsonb; rec public.bank_reconciliations;
begin
  select * into b from bank_accounts where id = p_bank_account;
  if not found then raise exception 'Account not found.'; end if;
  m := private.require(b.org_id, 'keep_books');
  if p_statement_balance is null then raise exception 'Enter the balance on the bank statement.'; end if;
  r := private.reconcile(b.id, p_as_of, p_statement_balance);
  insert into bank_reconciliations (org_id, bank_account_id, as_of, statement_balance, book_balance, not_in_books, not_on_statement, difference, status, items, created_by)
  values (b.org_id, b.id, p_as_of, p_statement_balance, (r->>'book_balance')::numeric, (r->>'not_in_books')::numeric, (r->>'not_on_statement')::numeric,
    (r->>'difference')::numeric, case when abs((r->>'difference')::numeric) < 0.01 then 'balanced' else 'unbalanced' end, r->'items', m.id)
  on conflict (bank_account_id, as_of) do update set statement_balance = excluded.statement_balance, book_balance = excluded.book_balance,
    not_in_books = excluded.not_in_books, not_on_statement = excluded.not_on_statement, difference = excluded.difference, status = excluded.status,
    items = excluded.items, created_by = excluded.created_by, created_at = now()
  returning * into rec;
  update bank_accounts set anchor_balance = p_statement_balance, anchor_at = private.line_time(b.org_id, p_as_of) + interval '11 hours 59 minutes', anchor_source = 'reconciliation'
  where id = b.id;
  return to_jsonb(rec);
end $$;

-- ---------------------------------------------------------------------------
-- 9. Reading
-- ---------------------------------------------------------------------------
create or replace function public.get_banking(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Your role does not see bank accounts.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'accounts', (select coalesce(jsonb_agg(to_jsonb(b) - 'provider_meta' || jsonb_build_object(
        'book_balance', (select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code = b.ledger_code),
        'unmatched', (select count(*) from bank_lines where bank_account_id = b.id and status = 'unmatched'),
        'questions', (select count(*) from bank_lines where bank_account_id = b.id and status = 'proposed'),
        'last_line', (select max(line_date) from bank_lines where bank_account_id = b.id),
        'last_reconciliation', (select jsonb_build_object('as_of', as_of, 'status', status, 'difference', difference) from bank_reconciliations
           where bank_account_id = b.id order by as_of desc limit 1)) order by b.kind, b.name), '[]'::jsonb)
      from bank_accounts b where b.org_id = p_org and b.active),
    'lines', (select coalesce(jsonb_agg(to_jsonb(x) - 'fingerprint' || jsonb_build_object('journal_ref', (select ref from journals where id = x.journal_id),
        'account_name', (select name from bank_accounts where id = x.bank_account_id)) order by x.line_date desc, x.created_at desc), '[]'::jsonb)
      from (select * from bank_lines where org_id = p_org order by line_date desc, created_at desc limit 1000) x),
    'suspense', (select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code = '9001'),
    'clearing', (select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code = '9002'),
    'rules', (select coalesce(jsonb_agg(to_jsonb(r) order by r.hits desc), '[]'::jsonb) from entity_rules r where r.org_id = p_org));
end $$;

-- Everything waiting for a person: questions from the agents, payments to confirm, bills to approve, assets to confirm, items whose VAT needs a look.
create or replace function public.get_books_inbox(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Your role does not see the books inbox.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'questions', (select coalesce(jsonb_agg(to_jsonb(p) || jsonb_build_object(
        'line', (select jsonb_build_object('date', bl.line_date, 'amount', bl.amount, 'narration', bl.description, 'counterparty', bl.counterparty,
           'account', (select name from bank_accounts where id = bl.bank_account_id)) from bank_lines bl where bl.id = p.source_id and p.source_type = 'bank_line'),
        'account_name', private.account_name(p_org, p.proposal->>'account_code')) order by p.created_at), '[]'::jsonb)
      from ai_proposals p where p.org_id = p_org and p.status = 'pending'),
    'review', (select coalesce(jsonb_agg(to_jsonb(p) || jsonb_build_object('account_name', private.account_name(p_org, p.proposal->>'account_code'),
        'journal_ref', (select ref from journals where id = p.journal_id)) order by p.created_at desc), '[]'::jsonb)
      from (select * from ai_proposals where org_id = p_org and status in ('auto_posted', 'info') and created_at > now() - interval '45 days' order by created_at desc limit 200) p),
    'payments_to_confirm', (select count(*) from collections where org_id = p_org and status = 'pending'),
    'bills_to_approve', (select count(*) from bills where org_id = p_org and status = 'draft'),
    'assets_to_confirm', (select count(*) from fixed_assets where org_id = p_org and status = 'pending_confirmation'),
    'payouts_to_approve', (select count(*) from payouts where org_id = p_org and status = 'pending_approval'),
    'suspense', (select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code = '9001'));
end $$;

grant execute on function public.import_bank_lines(uuid, uuid, jsonb, jsonb), public.run_bank_matching(uuid, uuid), public.resolve_proposal(uuid, jsonb),
  public.match_bank_line_to(uuid, uuid), public.bank_reconciliation(uuid, date, numeric), public.save_bank_reconciliation(uuid, date, numeric),
  public.get_banking(uuid), public.get_books_inbox(uuid) to authenticated;
revoke execute on function public.import_bank_lines(uuid, uuid, jsonb, jsonb), public.run_bank_matching(uuid, uuid), public.resolve_proposal(uuid, jsonb),
  public.match_bank_line_to(uuid, uuid), public.bank_reconciliation(uuid, date, numeric), public.save_bank_reconciliation(uuid, date, numeric),
  public.get_banking(uuid), public.get_books_inbox(uuid) from public, anon;
revoke execute on function public.svc_lines_for_ai(uuid, int), public.svc_classify_line(uuid, jsonb), public.svc_suspend_rest(uuid) from public, anon, authenticated;
grant execute on function public.svc_lines_for_ai(uuid, int), public.svc_classify_line(uuid, jsonb), public.svc_suspend_rest(uuid) to service_role;
revoke execute on function private.line_time(uuid, date), private.post_bank_line(uuid, text, text, uuid, text, text, jsonb, text),
  private.suspend_line(uuid, text, text, jsonb, numeric, text, text, text), private.record_bill_payment(uuid, uuid, numeric, numeric, timestamptz, text, public.members, text),
  private.name_in(text, text), private.match_bank_line(uuid), private.run_matching(uuid, uuid), private.reconcile(uuid, date, numeric) from public, anon, authenticated;
