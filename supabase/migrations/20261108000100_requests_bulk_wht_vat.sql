-- Counta, 8 November 2026: four changes from TaxStreem.
--
-- 1. Requests from the business's accountant. An open request counts beside Settings, in the bell and on Home, for the
--    owners and admins who answer them, until it is answered (get_attention: accountant_requests).
-- 2. Withholding tax on bulk payments. A bulk payment can deduct WHT from every row or from the rows the person picks.
--    Such a row is paid like a contractor row: the bill is written and approved, and WHT is kept back at the rate the
--    rules give for the type of work and the payee. The amount in the file is the amount before WHT. The type of work
--    comes from the supplier on file, else from the account or the narration, else the person picks it. Staff pay, taxes
--    and what the business owes on a liability account never take WHT. A payee with no Tax ID waits for one (the hold of
--    26 October stands).
-- 3. Purchase invoices uploaded for input VAT. Counta looks for the payment that paid each one among the bank lines and
--    the wallet's payouts. Without one the person says when it was paid and from which account, or that it is not paid
--    yet. WHT is worked out from the rules and falls in the month of the payment (cash basis). An invoice paid in full
--    with no WHT taken off still carries the WHT the business should have deducted: it is owed to the tax office and
--    charged to the business as a cost (6512).
-- 4. Money in with no Counta invoice. The VAT on each such sale is decided per payment: a product the narration names,
--    else what the business usually sells, and then the AI looks at each payment with what the business sells in view.
--    A payment the AI is unsure of is marked to check, and a person can change any of them.

-- ---------------------------------------------------------------------------
-- 1. Requests from the accountant beside Settings
-- ---------------------------------------------------------------------------
-- The counts beside the menu. accountant_requests: requests waiting for an answer, for the owners and admins (the people
-- who answer them on Settings, Your accountant), from accountants still working on the books.
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
      case when coalesce(o.tin, '') = '' or coalesce(o.tin_status, '') not in ('verified', 'confirmed') then 1 else 0 end else 0 end,
    'accountant_requests', case when m.practice_id is null and m.role in ('owner', 'admin') then
      (select count(*) from practice_requests pr join practice_clients pc on pc.id = pr.client_id
       where pr.org_id = p_org and pr.status = 'open' and pc.status = 'active') else 0 end,
    -- Payments taken as sales whose VAT a person should check: once the AI has looked (or could not), not while it is about to.
    'receipts_vat', case when v_tax then (select count(*) from sales where org_id = p_org and channel = 'bank' and doc_type = 'receipt' and status <> 'void'
      and vat_check and (vat_ai_at is not null or vat_ai_tries >= 3 or vat_source is distinct from 'usual' or created_at < now() - interval '1 day')) else 0 end);
end $$;

-- ---------------------------------------------------------------------------
-- 2. Withholding tax on bulk payments
-- ---------------------------------------------------------------------------
-- The type of transaction an account's name or a narration points to, for WHT (null when it does not say). The kinds the
-- rules leave out come first: bank charges, insurance, fuel, telephone, internet and airline tickets.
create or replace function private.wht_guess(p text) returns text
language sql stable security definer set search_path = public, private as $$
  with t as (select lower(regexp_replace(trim(coalesce(p, '')), '\s+', ' ', 'g')) s)
  select case when t.s = '' then null
    when t.s ~ '(bank charge|sms alert|card maintenance|stamp duty|transfer levy|\mcot\M)' then 'ex_bank_charges'
    when t.s ~ '(insurance|\mpremiums?\M)' then 'ex_insurance'
    when t.s ~ '(\mfuel\M|diesel|petrol|\mpms\M|\mago\M|kerosene|cooking gas|\mlpg\M|\mcng\M)' then 'ex_petroleum'
    when t.s ~ '(airtime|internet|data plan|data subscription|telephone|\mmtn\M|airtel|\mglo\M|9mobile|flight|air ?tickets?|airline)' then 'ex_telecom_airline'
    else private.wht_code_for(p) end
  from t
$$;

-- Company, business name or individual, from the name a bank gives an account or a sheet gives a payee: the words a
-- company or a business name carries, else a person. Shown on the bulk payment page as a guess to change.
create or replace function private.payee_kind_guess(p text) returns text
language sql immutable set search_path = public, private as $$
  select case when nullif(trim(coalesce(p, '')), '') is null then null else coalesce(private.contractor_type(p),
    case when lower(p) ~ '(enterprises?|ventures?|\mglobal\M|concepts?|integrated|\mservices\M|solutions|resources|technolog|\mstores?\M|industr|international|agency|consult|investments?|holdings?|& ?sons|and sons|trading|merchants?|\mworks\M|\mnig\M|nigeria)'
      then 'business_name' end, 'individual') end
$$;

-- Why a payment to this account takes no WHT, or null when it can: staff pay (PAYE covers it), taxes and levies, and
-- money the business owes on a liability account.
create or replace function private.bulk_wht_skip(p_org uuid, p_code text) returns text
language plpgsql stable security definer set search_path = public, private as $$
declare v_name text;
begin
  if p_code is null or p_code !~ '^[0-9]' then return null; end if;
  v_name := coalesce(private.account_name(p_org, p_code), p_code);
  if p_code ~ '^2' then return format('No WHT: %s is money the business owes, not a payment for work or goods.', v_name); end if;
  if p_code <> '6112' and (p_code ~ '^61' or p_code in ('5201', '5304') or v_name ~* '(salar|wage|payroll|pension|gratuity|\mstaff\M|employee)') then
    return 'No WHT on staff pay: PAYE covers it.';
  end if;
  if p_code ~ '^75' or p_code = '6512' or v_name ~* '(\mtax(es)?\M|\mlev(y|ies)\M|\mduty\M)' then return 'No WHT on taxes and levies.'; end if;
  return null;
end $$;

-- One row of a bulk payment sheet against the books. r: {row, name, bank_code, bank_name, account_number, account_name,
-- amount, narration, bill, supplier, account, reference, work, contractor_type, tin, address, state, gross,
-- wht (true: deduct WHT on a row with no bill and no type of work), work_choice (the type of work the person picked for it)}.
-- A row with WHT switched on is paid as a contractor's: its amount is the amount before WHT.
create or replace function private.bulk_row(p_org uuid, r jsonb, p_default text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_err text[] := '{}'; v_amt numeric := round(private.num(r->>'amount'), 2); b public.bills; v public.vendors; v_kind text; v_code text;
  v_gross numeric; v_wht numeric := 0; v_due numeric; v_left_wht numeric; v_full_net numeric; v_rate numeric; v_bill_ref text := nullif(trim(r->>'bill'), '');
  v_supplier text := nullif(trim(r->>'supplier'), ''); v_purpose text; v_lines jsonb; v_label text; sv public.vendors;
  cv public.vendors; v_wcode text; v_ctype text; v_vtype text; v_cname text; v_g numeric; v_tin text; v_tstatus text; tc public.tin_checks; v_contractor jsonb;
  v_corp boolean; v_base_rate numeric; v_check text;
  v_asked boolean := coalesce((r->>'wht')::boolean, false); v_on boolean := false; v_notes text[] := '{}'; v_wsrc text; v_guessed boolean := false;
  v_open numeric; v_acct0 text; v_skip text; v_needs text[] := '{}';
begin
  if coalesce(r->>'account_number', '') !~ '^[0-9]{10}$' then v_err := v_err || 'Account numbers have 10 digits.'::text; end if;
  if coalesce(trim(r->>'bank_code'), '') = '' then v_err := v_err || 'Choose the bank.'::text; end if;
  if coalesce(trim(r->>'account_name'), '') = '' then v_err := v_err || 'The bank has not confirmed the account name.'::text; end if;
  if v_supplier is not null then sv := private.find_vendor(p_org, v_supplier); end if;
  -- WHT asked for on a row that would otherwise pay with none: no bill and no type of work in the file.
  if v_asked and v_bill_ref is null and nullif(trim(r->>'work'), '') is null and not (v_supplier is not null and sv.id is null) then
    v_cname := left(coalesce(v_supplier, nullif(trim(r->>'name'), ''), nullif(trim(r->>'account_name'), '')), 120);
    if sv.id is not null then cv := sv; else cv := private.find_contractor(p_org, r->>'tin', r->>'account_number', v_cname); end if;
    v_acct0 := coalesce(private.find_account(p_org, nullif(trim(r->>'account'), '')), p_default,
      case when cv.id is not null and private.bill_account_ok(p_org, cv.default_account) then cv.default_account end);
    v_skip := private.bulk_wht_skip(p_org, v_acct0);
    if v_skip is not null then
      v_notes := v_notes || v_skip;
    elsif v_supplier is null and v_acct0 is null then
      null;  -- the row says nothing of what it pays for: the usual question comes first
    else
      if sv.id is not null then
        select coalesce(sum(total - amount_paid), 0) into v_open from bills where org_id = p_org and vendor_id = sv.id and status in ('approved', 'partially_paid');
      end if;
      if coalesce(v_open, 0) > 0.004 then
        v_err := v_err || format('%s has ₦%s unpaid on bills in Counta. Put the bill number in this row to pay a bill (its WHT comes from the bill), or switch WHT off for this row.',
          sv.name, to_char(v_open, 'FM999,999,999,990.00'));
      else
        v_on := true;
      end if;
    end if;
  end if;
  if v_bill_ref is not null then
    b := private.find_bill(p_org, v_bill_ref, sv.id);
    if b.id is null and sv.id is not null then b := private.find_bill(p_org, v_bill_ref, null); end if;
    if b.id is null then
      v_err := v_err || format('No bill %s in Counta%s.', v_bill_ref, case when sv.id is not null then ' from ' || sv.name else '' end);
    else
      select * into v from vendors where id = b.vendor_id;
      v_kind := 'bill'; v_label := b.number || ' · ' || v.name;
      if v_supplier is not null and sv.id is distinct from v.id then
        v_err := v_err || format('%s is from %s, not %s.', b.number, v.name, v_supplier);
      end if;
      if b.status not in ('approved', 'partially_paid') then
        v_err := v_err || format('%s is %s.', b.number, replace(b.status, '_', ' '));
      elsif private.bill_tin_hold(b.id) is not null then
        v_err := v_err || private.tin_hold_text(private.bill_tin_hold(b.id), v.name, b.number);
      else
        v_due := b.total - b.amount_paid - coalesce((select sum(gross) from bill_payments where bill_id = b.id and status = 'processing'), 0);
        v_left_wht := greatest(b.wht_expected + b.wvat_expected - coalesce((select sum(wht + wvat) from bill_payments where bill_id = b.id and status in ('paid', 'processing')), 0), 0);
        v_full_net := v_due - v_left_wht;
        v_rate := coalesce((b.wht_expected + b.wvat_expected) / nullif(b.total, 0), 0);
        if v_due <= 0.004 then
          v_err := v_err || format('Nothing is left to pay on %s.', b.number);
        elsif v_amt is null then
          v_gross := v_due; v_amt := v_full_net;
        elsif v_amt > v_full_net + 0.004 then
          v_err := v_err || format('%s has ₦%s left to pay, which is ₦%s after withholding tax.', b.number,
            to_char(v_due, 'FM999,999,999,990.00'), to_char(v_full_net, 'FM999,999,999,990.00'));
        elsif v_amt >= v_full_net - 0.004 then
          v_gross := v_due;
        else
          v_gross := round(v_amt / (1 - v_rate), 2);
        end if;
        v_purpose := 'vendor';
        if v_gross is not null then v_wht := v_gross - v_amt - coalesce((private.bill_withholding(b.id, v_gross)->>'wvat')::numeric, 0); end if;
        if coalesce((private.bill_tax_flags(b.id)->>'missing_state')::boolean, false) then
          v_err := v_err || format('Add the state of %s before paying %s: its withholding tax goes to that state''s revenue service.', v.name, b.number);
        end if;
      end if;
    end if;
  elsif nullif(trim(r->>'work'), '') is not null or v_on then
    -- A contractor paid with no bill in Counta, or a row with WHT switched on: the bill is written when the batch is saved,
    -- with withholding tax on it.
    if v_on then
      -- The type of work: what the person picked, else the supplier's own, else what the account or the narration says.
      v_wcode := (select code from wht_rates where code = nullif(trim(r->>'work_choice'), '')
                  and code not in ('compensation', 'dividend', 'interest', 'winnings', 'entertainment'));
      if v_wcode is not null then v_wsrc := 'you';
      elsif cv.id is not null and nullif(cv.wht_category, '') is not null then v_wcode := cv.wht_category; v_wsrc := 'supplier';
      else
        v_wcode := private.wht_guess(private.account_name(p_org, v_acct0));
        if v_wcode is not null then v_wsrc := 'account';
        else v_wcode := private.wht_guess(r->>'narration'); if v_wcode is not null then v_wsrc := 'narration'; end if; end if;
      end if;
    else
      v_wcode := private.wht_code_for(r->>'work');
      v_cname := left(coalesce(v_supplier, nullif(trim(r->>'name'), ''), nullif(trim(r->>'account_name'), '')), 120);
      cv := private.find_contractor(p_org, r->>'tin', r->>'account_number', v_cname);
    end if;
    v_ctype := private.contractor_type(r->>'contractor_type');
    if cv.id is not null then
      -- What is on file decides; the file only fills a gap, and a clash is shown.
      v_vtype := case when coalesce(cv.is_individual, false) or cv.entity_type = 'individual' then 'individual'
                      when cv.entity_type in ('business_name', 'sole_proprietor', 'partnership', 'lp') then 'business_name'
                      when cv.entity_type is not null or nullif(trim(coalesce(cv.rc_number, '')), '') is not null then 'company' end;
      if v_ctype is not null and v_vtype is not null and (v_ctype = 'individual') <> (v_vtype = 'individual') then
        v_err := v_err || format('%s is on file as %s, and the file says %s.', cv.name,
          case when v_vtype = 'individual' then 'an individual' else 'a business' end, case when v_ctype = 'individual' then 'an individual' else 'a business' end);
      end if;
      v_ctype := coalesce(v_vtype, v_ctype);
      if private.clean_tax_id(cv.tin) is not null and private.clean_tax_id(r->>'tin') is not null and private.clean_tax_id(cv.tin) <> private.clean_tax_id(r->>'tin') then
        v_err := v_err || format('%s has the Tax ID %s on file, and the file says %s.', cv.name, cv.tin, trim(r->>'tin'));
      end if;
    end if;
    -- A row with WHT switched on and no word on the payee: a guess from the bank's name for the account, shown to change.
    if v_on and v_ctype is null then
      v_ctype := private.payee_kind_guess(coalesce(nullif(trim(r->>'account_name'), ''), v_cname));
      v_guessed := v_ctype is not null;
    end if;
    if v_cname is null then v_err := v_err || 'Give the contractor''s name.'::text; end if;
    if v_wcode is null then
      if v_on then
        v_err := v_err || 'Choose the type of work for this payment, so Counta can work out the WHT.'::text; v_needs := v_needs || 'work'::text;
      else
        v_err := v_err || format('"%s" is not a type of work Counta knows. Use one from the template''s list.', left(trim(r->>'work'), 60));
      end if;
    elsif v_wcode in ('compensation', 'dividend', 'interest', 'winnings') then
      v_err := v_err || format('%s is not paid to a contractor. Record it on its own page.', (select name from wht_rates where code = v_wcode));
      v_wcode := null;
    end if;
    if v_ctype is null then v_err := v_err || format('Say whether %s is a company, a business name or an individual.', coalesce(v_cname, 'the contractor')); end if;
    v_code := coalesce(private.find_account(p_org, nullif(trim(r->>'account'), '')), p_default,
      case when cv.id is not null and private.bill_account_ok(p_org, cv.default_account) then cv.default_account end, private.acct(p_org, 'expenses_default'));
    if v_code !~ '^[0-9]' or not private.bill_account_ok(p_org, v_code) then
      v_err := v_err || format('Account %s cannot take a contractor''s bill. Use an expense or asset account.', v_code);
    end if;
    -- The amount before WHT: the contract amount column, or the amount itself on a row with WHT switched on.
    v_g := round(private.num(coalesce(nullif(r->>'gross', ''), case when v_on then r->>'amount' end)), 2);
    if v_wcode is not null and v_ctype is not null then
      -- The rate the bill will get (private.bill_wht): exempt types and suppliers, goods the supplier makes, then the matrix.
      v_corp := case when cv.id is not null and cv.entity_type is not null then (private.vendor_wht_profile(cv.id)->>'corporate')::boolean else v_ctype = 'company' end;
      v_rate := case when (select exemption from wht_rates where code = v_wcode) or coalesce(cv.wht_exempt, false) or cv.entity_type = 'government'
                       or (v_wcode = 'goods' and coalesce(cv.is_manufacturer, false)) then 0
                     else coalesce(private.wht_matrix_rate(v_wcode, v_corp, coalesce(cv.resident, true)), 0) end;
      v_base_rate := v_rate;
      v_tin := coalesce(private.clean_tax_id(cv.tin), private.clean_tax_id(r->>'tin'));
      -- A small business need not withhold from a supplier with a Tax ID while the month's purchases from them stay within ₦2 million.
      if v_rate > 0 and v_tin is not null and (select wht_small_company from orgs where id = p_org)
         and coalesce((select sum(subtotal) from bills where org_id = p_org and vendor_id = cv.id and status <> 'void'
           and date_trunc('month', bill_date) = date_trunc('month', private.local_day(p_org, now()))), 0) + coalesce(v_g, v_amt, 0) <= 2000000 then
        v_rate := 0;
      end if;
      if v_g is not null and v_g > 0 then
        v_gross := v_g; v_wht := round(v_g * v_rate, 2); v_amt := v_g - v_wht;
      elsif v_amt is not null then
        v_gross := round(v_amt / (1 - v_rate), 2); v_wht := v_gross - v_amt;
      end if;
      -- The Tax ID, wherever the work attracts withholding tax: on file and checked, or found by the NRS check the page runs first.
      if v_base_rate > 0 then
        if v_tin is null then
          v_err := v_err || format('%s has no Tax ID. The work attracts withholding tax, so the payment needs the contractor''s Tax ID (taxid.nrs.gov.ng).', v_cname);
          v_needs := v_needs || 'tin'::text;
        elsif cv.id is not null and private.clean_tax_id(cv.tin) = v_tin and cv.tin_status in ('verified', 'confirmed') then
          v_tstatus := cv.tin_status;
        elsif cv.id is not null and private.clean_tax_id(cv.tin) = v_tin and cv.tin_status in ('mismatch', 'not_found') then
          v_err := v_err || private.tin_hold_text('tin_' || cv.tin_status, cv.name, 'this payment');
        else
          select * into tc from tin_checks where org_id = p_org and number = v_tin and outcome in ('verified', 'mismatch', 'not_found') and at > now() - interval '90 days'
          order by at desc limit 1;
          if tc.id is null then
            v_err := v_err || format('Check %s''s Tax ID %s with the NRS first.', v_cname, v_tin);
            v_check := v_tin;
          elsif tc.outcome = 'not_found' then
            v_err := v_err || format('The NRS has no record of the Tax ID %s (%s).', v_tin, v_cname);
            v_needs := v_needs || 'tin'::text;
          elsif tc.taxpayer_name is not null and not (private.same_taxpayer(tc.taxpayer_name, v_cname)
              or private.same_taxpayer(tc.taxpayer_name, coalesce(nullif(trim(r->>'account_name'), ''), '-'))) then
            v_err := v_err || format('The NRS has the Tax ID %s under %s, not %s.', v_tin, tc.taxpayer_name, v_cname);
            v_needs := v_needs || 'tin'::text;
          else
            v_tstatus := 'verified';
          end if;
        end if;
      end if;
      -- A business is paid only with its address on file.
      if (case when cv.id is not null and cv.entity_type is not null then private.vendor_is_enterprise(cv) else v_ctype in ('company', 'business_name') end)
         and coalesce(nullif(trim(cv.address), ''), nullif(trim(r->>'address'), '')) is null then
        v_err := v_err || format('Add %s''s address: a business is paid only with its address on file.', v_cname);
        v_needs := v_needs || 'address'::text;
      end if;
      -- Withholding tax from an individual or a business name goes to the state revenue service, so the state must be known.
      if v_rate > 0 and not v_corp and coalesce(private.state_code(cv.state), private.state_code(cv.address), private.state_code(cv.location),
           private.state_code(r->>'state'), private.state_code(r->>'address')) is null then
        v_err := v_err || format('Add %s''s state (or an address with the state): withholding tax from an individual or a business name goes to the state revenue service.', v_cname);
        v_needs := v_needs || 'state'::text;
      end if;
    end if;
    v := cv; v_kind := 'contractor'; v_purpose := 'vendor';
    v_label := coalesce(cv.name, v_cname) || ' · ' || coalesce((select lower(name) from wht_rates where code = v_wcode), 'contract');
    v_contractor := jsonb_build_object('vendor_id', cv.id, 'name', v_cname, 'type', v_ctype, 'tin', v_tin, 'tin_status', v_tstatus, 'work', v_wcode,
      'rate', v_rate, 'address', nullif(trim(r->>'address'), ''), 'state', private.ng_state_of_address(coalesce(nullif(trim(r->>'state'), ''), r->>'address')),
      'tin_to_check', v_check, 'new', cv.id is null, 'work_source', v_wsrc, 'type_guessed', v_guessed,
      'on_file', jsonb_build_object('type', v_vtype, 'tin', cv.tin is not null and trim(cv.tin) <> '', 'address', nullif(trim(coalesce(cv.address, '')), '') is not null,
        'state', coalesce(private.state_code(cv.state), private.state_code(cv.address), private.state_code(cv.location)) is not null));
  elsif v_supplier is not null then
    if sv.id is null then
      v_err := v_err || format('No supplier named %s in Counta.', v_supplier);
    else
      v := sv;
      v_kind := 'vendor'; v_purpose := 'vendor'; v_gross := v_amt; v_label := v.name || ' · on account';
      v_lines := jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'payables'), 'debit', v_amt, 'party_type', 'vendor', 'party_id', v.id,
        'memo', 'Paid on account · ' || coalesce(nullif(trim(r->>'narration'), ''), v.name)));
    end if;
  else
    v_code := coalesce(private.find_account(p_org, nullif(trim(r->>'account'), '')), p_default);
    if v_code is null then
      v_err := v_err || 'Say what this payment is for: a bill number, a supplier or an account code.'::text;
    elsif v_code !~ '^[0-9]' then
      v_err := v_err || format('No account called %s in your chart. Use its code.', v_code);
    elsif not private.bulk_account_ok(p_org, v_code) then
      v_err := v_err || format('Account %s cannot take a payment. Use an expense or liability account, or a bill.', v_code);
    else
      v_kind := 'account'; v_gross := v_amt; v_label := v_code || ' ' || private.account_name(p_org, v_code);
      v_purpose := case when v_code ~ '^[5-7]' then 'expense' else 'other' end;
      v_lines := jsonb_build_array(jsonb_build_object('code', v_code, 'debit', v_amt, 'memo', coalesce(nullif(trim(r->>'narration'), ''), r->>'account_name')));
    end if;
  end if;
  if v_amt is null or v_amt < 100 then v_err := v_err || 'Each payment must be at least ₦100.'::text; end if;
  return jsonb_build_object('row', r->'row', 'ok', cardinality(v_err) = 0, 'errors', to_jsonb(v_err), 'kind', v_kind, 'label', v_label,
    'amount', v_amt, 'gross', v_gross, 'wht', v_wht, 'wvat', case when v_kind = 'bill' and v_gross is not null then (private.bill_withholding(b.id, v_gross)->>'wvat')::numeric else 0 end, 'fee', case when v_amt is not null then private.transfer_fee(v_amt) end,
    'bill_id', b.id, 'bill_number', b.number, 'vendor_id', v.id, 'vendor_name', coalesce(v.name, v_contractor->>'name'), 'account', v_code, 'purpose', v_purpose,
    'lines', v_lines, 'contractor', v_contractor,
    -- Whether WHT was asked for on this row, applied to it as a contractor's, or left off, and why; what the page should ask for.
    'wht_asked', v_asked, 'wht_on', v_on, 'notes', to_jsonb(v_notes), 'needs', to_jsonb(v_needs));
end $$;

-- The whole sheet against the books (as before), with the types of work a row with WHT can take, for the page's list.
create or replace function private.bulk_check(p_org uuid, p jsonb, m public.members) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
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
    'needs_approval', o.payout_approval_threshold > 0 and v_total >= o.payout_approval_threshold and m.role <> 'owner',
    'mode', case when exists (select 1 from payment_rails where code = w.rail and 'bulk_payout' = any(capabilities)) then 'bulk' else 'transfers' end,
    'wallet_id', w.id,
    'wht_types', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'exempt', exemption) order by sort, code), '[]'::jsonb) from wht_rates
      where code not in ('compensation', 'dividend', 'interest', 'winnings', 'entertainment', 'ex_securities_lending', 'ex_reit', 'ex_exempt_income',
        'ex_imported_goods', 'ex_broker_retained', 'ex_qualifying_winnings')));
end $$;

-- ---------------------------------------------------------------------------
-- 3. Purchase invoices uploaded for input VAT: the payment that paid each one, and WHT in the month it was paid
-- ---------------------------------------------------------------------------
-- WHT the business owes on a bill although it paid the supplier in full (no WHT taken off): owed to the tax office all the
-- same, and a cost to the business.
alter table public.bills add column if not exists wht_borne numeric(16,2) not null default 0;
comment on column public.bills.wht_borne is 'WHT the business owes on this bill although it paid the supplier in full; charged to 6512 when the payment is recorded.';

-- The supplier an uploaded invoice names: the same Tax ID under a name that agrees, else the same name. A Tax ID alone is
-- not enough (a misread number would put the invoice on another supplier).
create or replace function private.vat_purchase_vendor(p_org uuid, p_name text, p_tin text) returns public.vendors
language sql stable security definer set search_path = public, private as $$
  select v.* from vendors v
  where v.org_id = p_org and (lower(v.name) = lower(trim(coalesce(p_name, '')))
    or (length(coalesce(private.clean_tax_id(p_tin), '')) >= 8 and private.clean_tax_id(v.tin) = private.clean_tax_id(p_tin)
        and coalesce(private.same_taxpayer(v.name, p_name), false)))
  order by (length(coalesce(private.clean_tax_id(p_tin), '')) >= 8 and private.clean_tax_id(v.tin) = private.clean_tax_id(p_tin)) desc, v.created_at
  limit 1
$$;

-- The WHT an invoice carries before its bill exists, worked out the way private.bill_wht does for one line: exempt types
-- and suppliers, goods the supplier makes, the NRS table for a company or not, double with no Tax ID, and nothing within
-- the ₦2 million monthly limit of a small business. p_type (company, business_name, individual) is used for a supplier
-- not on file yet, or on file with no type.
create or replace function private.wht_preview(p_org uuid, p_vendor uuid, p_type text, p_has_tin boolean, p_category text, p_net numeric, p_day date) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v public.vendors; pf jsonb; r public.wht_rates; v_corp boolean; v_res boolean; v_tin boolean; v_rate numeric := 0; v_note text; v_doubled boolean := false;
  v_month numeric;
begin
  if p_vendor is not null then select * into v from vendors where id = p_vendor; pf := private.vendor_wht_profile(p_vendor); end if;
  v_corp := case when v.id is not null and (v.entity_type is not null or v.is_individual) then (pf->>'corporate')::boolean
                 else coalesce(nullif(p_type, ''), 'company') = 'company' end;
  v_res := coalesce((pf->>'resident')::boolean, true);
  v_tin := coalesce((pf->>'has_tin')::boolean, false) or coalesce(p_has_tin, false);
  select * into r from wht_rates where code = coalesce(nullif(p_category, ''), 'none');
  if r.code is null or r.exemption then
    v_note := case when r.code is not null and r.code <> 'none' then r.name end;
  elsif coalesce((pf->>'exempt')::boolean, false) then
    v_note := 'Supplier exempt from withholding tax';
  elsif r.code = 'goods' and coalesce(v.is_manufacturer, false) then
    v_note := 'Goods made by the supplier itself are not subject to WHT';
  else
    v_rate := private.wht_matrix_rate(r.code, v_corp, v_res);
    if v_rate is null then
      v_rate := 0; v_note := r.name || ': not withheld from ' || case when v_corp then 'a company' else 'this supplier' end;
    elsif not v_tin and v_rate > 0 then
      v_rate := v_rate * 2; v_doubled := true; v_note := 'No Tax ID: the rate is doubled';
    end if;
  end if;
  if v_rate > 0 and v_tin and (select wht_small_company from orgs where id = p_org) then
    select coalesce(sum(subtotal), 0) into v_month from bills where org_id = p_org and vendor_id = p_vendor and status <> 'void'
      and date_trunc('month', bill_date) = date_trunc('month', p_day);
    if coalesce(v_month, 0) + coalesce(p_net, 0) <= 2000000 then v_rate := 0; v_note := 'Within the ₦2 million monthly limit for a small business'; end if;
  end if;
  return jsonb_build_object('category', coalesce(r.code, 'none'), 'name', coalesce(r.name, 'No withholding tax'), 'rate', v_rate,
    'amount', round(coalesce(p_net, 0) * v_rate, 2), 'doubled', v_doubled, 'note', v_note, 'corporate', v_corp);
end $$;

-- Payments in the records that could have paid an invoice: money out of a bank account, or a payout from the wallet, for
-- the invoice's total or its total less WHT (bank charges on top allowed), from 30 days before the invoice to 120 days
-- after it, and not yet tied to a bill, an invoice or a sale. The best first: the supplier's name in the payment, then
-- the nearest date after the invoice.
-- p: {supplier_name, supplier_tin, supplier_type, invoice_no, invoice_date, net, vat, total, wht_category, bank_line_id}
create or replace function public.vat_purchase_payments(p_org uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v public.vendors; v_name text := nullif(trim(p->>'supplier_name'), ''); v_tin text := private.clean_tax_id(regexp_replace(coalesce(p->>'supplier_tin', ''), '[^0-9]', '', 'g'));
  v_day date; v_net numeric; v_total numeric; w jsonb; v_wht numeric; v_tol numeric; v_cat text; v_dup text; v_today date; v_tokens text[]; v_matches jsonb;
begin
  m := private.require_vat_work(p_org);
  begin v_day := nullif(p->>'invoice_date', '')::date; exception when others then v_day := null; end;
  v_net := round(private.num(p->>'net'), 2);
  v_total := coalesce(round(private.num(p->>'total'), 2), v_net + coalesce(round(private.num(p->>'vat'), 2), 0));
  v_today := private.local_day(p_org, now());
  v := private.vat_purchase_vendor(p_org, v_name, v_tin);
  v_cat := coalesce(nullif(p->>'wht_category', ''), nullif(v.wht_category, ''), 'none');
  w := private.wht_preview(p_org, v.id, p->>'supplier_type', v_tin is not null, v_cat, v_net, coalesce(v_day, v_today));
  v_wht := coalesce((w->>'amount')::numeric, 0);
  if v.id is not null and nullif(trim(p->>'invoice_no'), '') is not null then
    select number into v_dup from bills where org_id = p_org and vendor_id = v.id and status <> 'void' and lower(vendor_ref) = lower(trim(p->>'invoice_no')) limit 1;
  end if;
  -- The words of the supplier's name worth looking for in a narration.
  select coalesce(array_agg(t), '{}') into v_tokens from regexp_split_to_table(lower(coalesce(v_name, '')), '[^a-z0-9]+') t
  where length(t) >= 4 and t not in ('limited', 'nigeria', 'company', 'enterprise', 'enterprises', 'services', 'global', 'ventures', 'international', 'nig', 'and');
  v_tol := greatest(100, round(coalesce(v_total, 0) * 0.005, 2));
  if v_day is null or coalesce(v_total, 0) <= 0 then
    v_matches := '[]'::jsonb;
  else
    with c as (
      select 'bank_line' kind, l.id, l.line_date as pday, abs(l.amount) amt, l.description, l.counterparty, ba.name account, l.status,
        coalesce(private.same_taxpayer(l.counterparty, v_name), false) named,
        exists (select 1 from unnest(v_tokens) t where lower(coalesce(l.description, '') || ' ' || coalesce(l.counterparty, '')) like '%' || t || '%') worded
      from bank_lines l join bank_accounts ba on ba.id = l.bank_account_id
      where l.org_id = p_org and l.amount < 0 and l.status in ('unmatched', 'posted', 'proposed') and coalesce(l.fingerprint, '') not like 'payout:%'
        and l.line_date between v_day - 30 and least(v_day + 120, v_today)
      union all
      select 'payout', po.id, private.local_day(p_org, coalesce(po.completed_at, po.created_at)), po.amount, po.narration, po.account_name, ba.name, po.status,
        po.vendor_id is not distinct from v.id and v.id is not null or coalesce(private.same_taxpayer(po.account_name, v_name), false),
        exists (select 1 from unnest(v_tokens) t where lower(coalesce(po.narration, '') || ' ' || coalesce(po.account_name, '')) like '%' || t || '%')
      from payouts po join wallets wl on wl.id = po.wallet_id join bank_accounts ba on ba.id = wl.bank_account_id
      where po.org_id = p_org and po.status = 'successful' and po.journal_id is not null and po.purpose in ('vendor', 'expense', 'other')
        and not exists (select 1 from bill_payments bp where bp.payout_id = po.id)
        and private.local_day(p_org, coalesce(po.completed_at, po.created_at)) between v_day - 30 and least(v_day + 120, v_today)),
    b as (
      select c.*, case when c.kind = 'payout' then case when abs(c.amt - v_total) <= 0.01 then 'full' when v_wht > 0 and abs(c.amt - (v_total - v_wht)) <= 0.01 then 'less_wht' end
                       else case when c.amt - v_total between -0.005 and v_tol then 'full' when v_wht > 0 and c.amt - (v_total - v_wht) between -0.005 and v_tol then 'less_wht' end end basis
      from c)
    select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'id', id, 'date', pday, 'amount', amt, 'description', description, 'counterparty', counterparty,
        'account', account, 'basis', basis, 'named', named or worded, 'wht', case when basis = 'less_wht' then v_wht else 0 end,
        'charge', case when kind = 'bank_line' then greatest(round(amt - case when basis = 'full' then v_total else v_total - v_wht end, 2), 0) else 0 end)
      order by (named or worded) desc, (pday >= v_day) desc, abs(pday - v_day), id), '[]'::jsonb)
    into v_matches
    from (select * from b where basis is not null order by (named or worded) desc, (pday >= v_day) desc, abs(pday - v_day) limit 6) z;
  end if;
  return jsonb_build_object('vendor', case when v.id is not null then jsonb_build_object('id', v.id, 'name', v.name, 'wht_category', v.wht_category,
      'type', case when coalesce(v.is_individual, false) or v.entity_type = 'individual' then 'individual'
                   when v.entity_type in ('business_name', 'sole_proprietor', 'partnership', 'lp') then 'business_name' when v.entity_type is not null then 'company' end,
      'has_tin', private.clean_tax_id(v.tin) is not null, 'state', coalesce(private.state_code(v.state), private.state_code(v.address), private.state_code(v.location)),
      'address', nullif(trim(coalesce(v.address, '')), '')) end,
    'wht', w, 'duplicate', v_dup, 'matches', v_matches, 'total', v_total, 'tolerance', v_tol);
end $$;

-- The WHT a bill carries, owed by the business because it paid the supplier in full: the tax office's share is recorded
-- for the WHT schedule in the payment's month (as private.sync_wht_deductions records WHT taken off), and the entry
-- that charges it to the business is posted unless the payment's own entry already carries it.
create or replace function private.book_borne_wht(p_payment uuid, m public.members, p_post boolean default true) returns numeric
language plpgsql security definer set search_path = public, private as $$
declare bp public.bill_payments; b public.bills; v public.vendors; pf jsonb; x record; v_day date; v_tot numeric; v_auth text; v_desc text; v_status text;
begin
  select * into bp from bill_payments where id = p_payment;
  select * into b from bills where id = bp.bill_id for update;
  v_tot := coalesce((select sum(wht) from bill_lines where bill_id = b.id), 0);
  if v_tot <= 0 then return 0; end if;
  select * into v from vendors where id = b.vendor_id;
  pf := private.vendor_wht_profile(v.id);
  v_day := private.local_day(b.org_id, bp.paid_at);
  v_status := case when bp.status = 'paid' then 'deducted' else 'pending' end;
  v_desc := b.number || coalesce(' / ' || b.vendor_ref, '');
  if p_post then
    perform private.post_entry(b.org_id, 'WHT on ' || b.number || ' borne by the business · ' || v.name || ' was paid in full', 'bill_payment', b.id, m.id, m.id,
      jsonb_build_array(
        jsonb_build_object('code', '6512', 'debit', v_tot, 'memo', 'WHT on ' || b.number || ' not taken off the payment to ' || v.name),
        jsonb_build_object('code', private.acct(b.org_id, 'wht_payable'), 'credit', v_tot, 'party_type', 'vendor', 'party_id', v.id, 'doc_type', 'bill', 'doc_id', b.id,
          'memo', 'WHT on ' || b.number || ', borne by the business')),
      bp.paid_at, jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'bill', 'id', b.id, 'ref', coalesce(b.vendor_ref, b.number)))));
  end if;
  for x in select coalesce(l.wht_category, b.wht_category) cat, sum(l.wht) wht, sum(l.wht_base) base, max(l.wht_rate) rate,
                  string_agg(l.description, '; ' order by l.line_no) descr
           from bill_lines l where l.bill_id = b.id and l.wht > 0 group by 1 order by 2 desc loop
    v_auth := case when x.cat = 'compensation' then pf->>'state' when (pf->>'corporate')::boolean or not (pf->>'resident')::boolean then 'NRS' else pf->>'state' end;
    insert into wht_deductions (org_id, kind, bill_id, bill_payment_id, vendor_id, category, nrs_code, description, recipient_type, resident, beneficiary_type,
      beneficiary_number, base, rate, doubled, amount, authority, state_missing, deducted_on, period, due_date, status, receipt_no)
    values (b.org_id, 'wht', b.id, bp.id, v.id, x.cat, (select nrs_code from wht_rates where code = x.cat), left(v_desc || ': ' || x.descr || ' (paid in full; WHT borne by the business)', 300),
      pf->>'recipient_type', (pf->>'resident')::boolean, pf->>'beneficiary_type', pf->>'beneficiary_number', x.base, x.rate,
      not (pf->>'has_tin')::boolean and x.cat <> 'compensation', x.wht, v_auth, v_auth is null,
      v_day, date_trunc('month', v_day)::date, private.wht_due('wht', v_auth, x.cat, v_day), v_status,
      'WHT-' || lpad(private.next_no(b.org_id, 'WHTR', 1)::text, 5, '0'))
    on conflict do nothing;
  end loop;
  update bills set wht_borne = v_tot where id = b.id;
  return v_tot;
end $$;

-- A purchase invoice uploaded to claim its input VAT, as read by the AI and checked by a person: a bill for the VAT shown
-- on it, approved, with WHT at the rules' rate for the type of transaction, and the payment that paid it.
-- p: {document_path, supplier_name, supplier_tin, supplier_type, supplier_address, supplier_state, invoice_no, invoice_date,
--     description, net, vat, total, account_code, wht_category,
--     payment: bank_line (bank_line_id) | payout (payout_id) | paid (paid_from, paid_on, wht_taken) | unpaid}
-- WHT falls in the month of the payment. A payment of the whole invoice with no WHT taken off leaves the business owing the
-- WHT itself (private.book_borne_wht). Without wht_category the bill takes no WHT, as before.
create or replace function public.save_vat_purchase(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; v public.vendors; v_vendor uuid; v_name text := nullif(trim(p->>'supplier_name'), '');
  v_tin text := nullif(regexp_replace(coalesce(p->>'supplier_tin', ''), '[^0-9]', '', 'g'), '');
  v_net numeric := round(private.num(p->>'net'), 2); v_vat numeric := round(private.num(p->>'vat'), 2); v_total numeric; v_day date; v_rate numeric; v_vatable numeric;
  v_rest numeric; b public.bills; v_code text; v_lines jsonb; bl public.bank_lines; ba public.bank_accounts; j public.journals; po public.payouts; bp public.bill_payments;
  v_mode text; v_type text := nullif(p->>'supplier_type', ''); v_cat text; v_paid date; v_taken boolean; v_tol numeric; v_amt numeric; v_jl jsonb; x jsonb;
  v_borne numeric := 0; v_today date; v_state text; v_wl numeric; v_keep numeric;
begin
  m := private.require_vat_work(p_org);
  select * into o from orgs where id = p_org;
  v_today := private.local_day(p_org, now());
  if not o.vat_registered then raise exception 'Input VAT is claimed only by a business that charges VAT.'; end if;
  if v_name is null then raise exception 'Name the supplier on the invoice.'; end if;
  if coalesce(v_vat, 0) <= 0 then raise exception 'This invoice shows no VAT, so there is no input VAT to claim.'; end if;
  if coalesce(v_net, 0) <= 0 then raise exception 'Enter the amount before VAT.'; end if;
  v_total := coalesce(round(private.num(p->>'total'), 2), v_net + v_vat);
  if abs(v_total - (v_net + v_vat)) > 1 then raise exception 'The total (%) is not the amount before VAT plus the VAT (%).', private.naira(v_total), private.naira(v_net + v_vat); end if;
  begin v_day := nullif(p->>'invoice_date', '')::date; exception when others then raise exception 'Check the invoice date.'; end;
  if v_day is null then raise exception 'Enter the invoice date.'; end if;
  if v_day > v_today then raise exception 'The invoice is dated in the future.'; end if;
  v_rate := private.vat_rate(v_day);
  if v_vat > round(v_net * v_rate, 2) + 1 then raise exception 'The VAT (%) is more than % of the amount before VAT. Check the figures.', private.naira(v_vat), (v_rate * 100)::numeric(5,2) || '%'; end if;
  if v_type is not null and v_type not in ('company', 'business_name', 'individual') then raise exception 'Say whether the supplier is a company, a business name or an individual.'; end if;
  v_mode := coalesce(nullif(p->>'payment', ''), case when nullif(p->>'bank_line_id', '') is not null then 'bank_line' when nullif(p->>'payout_id', '') is not null then 'payout' else 'paid' end);
  if v_mode not in ('bank_line', 'payout', 'paid', 'unpaid') then raise exception 'Say how this invoice was paid.'; end if;
  -- Checked before anything is written, so a mistake leaves nothing behind.
  if v_mode = 'paid' then
    select * into ba from bank_accounts where id = nullif(p->>'paid_from', '')::uuid and org_id = p_org and active;
    if not found then raise exception 'Say which account paid this invoice.'; end if;
    begin v_paid := coalesce(nullif(p->>'paid_on', '')::date, v_day); exception when others then raise exception 'Check the date it was paid.'; end;
    if v_paid > v_today then raise exception 'The payment date is in the future.'; end if;
    if v_paid < v_day - 365 then raise exception 'The payment date is more than a year before the invoice.'; end if;
  end if;
  -- The supplier: by Tax ID, else by name, else a new one with what the invoice gives.
  v := private.vat_purchase_vendor(p_org, v_name, v_tin);
  v_vendor := v.id;
  v_state := coalesce(private.ng_state_of_address(nullif(trim(p->>'supplier_state'), '')), private.ng_state_of_address(nullif(trim(p->>'supplier_address'), '')));
  if v_vendor is null then
    insert into vendors (org_id, name, tin, vat_registered, channel, entity_type, is_individual, address, state)
    values (p_org, left(v_name, 120), v_tin, true, 'email', coalesce(v_type, 'company'), coalesce(v_type, 'company') = 'individual',
      left(nullif(trim(p->>'supplier_address'), ''), 300), v_state)
    returning id into v_vendor;
  else
    -- What is on file stays; the invoice fills only what is missing.
    update vendors set tin = coalesce(nullif(trim(tin), ''), v_tin),
      entity_type = coalesce(entity_type, case when not coalesce(is_individual, false) then v_type end),
      address = coalesce(nullif(trim(address), ''), left(nullif(trim(p->>'supplier_address'), ''), 300)),
      state = coalesce(nullif(trim(state), ''), v_state)
    where id = v_vendor;
  end if;
  select * into v from vendors where id = v_vendor;
  if nullif(trim(p->>'invoice_no'), '') is not null and exists (select 1 from bills where org_id = p_org and vendor_id = v_vendor and status <> 'void'
       and lower(vendor_ref) = lower(trim(p->>'invoice_no'))) then
    raise exception 'Invoice % from % is already in the books.', trim(p->>'invoice_no'), v_name;
  end if;
  v_cat := case when p ? 'wht_category' then coalesce(nullif(p->>'wht_category', ''), nullif(v.wht_category, ''), 'none') else 'none' end;
  if not exists (select 1 from wht_rates where code = v_cat) then raise exception 'Choose the kind of purchase for withholding tax.'; end if;
  v_code := coalesce(nullif(p->>'account_code', ''), v.default_account,
    case when exists (select 1 from items where org_id = p_org) then private.acct(p_org, 'purchases') else private.acct(p_org, 'expenses_default') end);
  -- The part of the price that carries VAT, from the VAT shown; whatever else is on the invoice carries none.
  v_vatable := least(round(v_vat / v_rate, 2), v_net);
  v_rest := round(v_net - v_vatable, 2);
  v_lines := jsonb_build_array(jsonb_build_object('description', left(coalesce(nullif(trim(p->>'description'), ''), 'Purchase'), 300), 'account_code', v_code,
    'qty', 1, 'unit_cost', v_vatable, 'vat_treatment', 'standard'));
  if v_rest >= 0.01 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('description', 'Part of the invoice with no VAT', 'account_code', v_code, 'qty', 1, 'unit_cost', v_rest,
      'vat_treatment', 'exempt'));
  end if;
  b := private.write_bill(p_org, jsonb_build_object('vendor_id', v_vendor, 'vendor_ref', nullif(trim(p->>'invoice_no'), ''), 'source', 'ai', 'bill_date', v_day,
    'due_date', case when v_mode <> 'unpaid' then v_day end, 'prices_include_vat', false, 'vat_charged', true, 'wht_category', v_cat,
    'document_path', nullif(p->>'document_path', ''), 'notes', 'Input VAT claim from an uploaded invoice', 'lines', v_lines), m);
  -- The VAT as printed (the bill worked it out from the rate; a kobo or two of rounding is the invoice's).
  update bill_lines set vat = v_vat, gross = net + v_vat where bill_id = b.id and line_no = 1;
  update bills set vat_total = (select sum(vat) from bill_lines where bill_id = b.id), total = (select sum(gross) from bill_lines where bill_id = b.id) where id = b.id;
  b := private.bill_wht(b.id);
  b := private.post_bill(b.id, m);
  select * into b from bills where id = b.id;
  v_tol := greatest(100, round(b.total * 0.005, 2));
  -- What a payment keeps back: the WHT, and the VAT withheld by a business that withholds VAT.
  v_keep := b.wht_expected + b.wvat_expected;
  if v_mode = 'bank_line' then
    select * into bl from bank_lines where id = nullif(p->>'bank_line_id', '')::uuid and org_id = p_org for update;
    if not found or bl.amount >= 0 then raise exception 'Choose the payment out of the bank that paid this invoice.'; end if;
    if bl.status in ('matched', 'ignored') then raise exception 'That bank line is already settled. Choose another.'; end if;
    v_amt := abs(bl.amount);
    if not (v_amt - b.total between -0.005 and v_tol) and not (v_keep > 0 and v_amt - (b.total - v_keep) between -0.005 and v_tol) then
      raise exception 'The bank line (%) and the invoice (%) differ by more than bank charges%.', private.naira(v_amt), private.naira(b.total),
        case when v_keep > 0 then ', with or without the WHT of ' || private.naira(v_keep) else '' end;
    end if;
    -- Whatever the line was posted to before (suspense, or an expense with no VAT) is taken back.
    if bl.journal_id is not null then perform private.reverse_entry(bl.journal_id, m.id, 'Paid ' || b.number || ' with input VAT from the invoice', null); end if;
    update ai_proposals set status = 'superseded' where source_type = 'bank_line' and source_id = bl.id and status in ('pending', 'info', 'auto_posted');
    update bank_lines set status = 'unmatched', journal_id = null, proposal_id = null where id = bl.id;
    perform private.apply_match(bl.id, jsonb_build_object('kind', 'bill', 'id', b.id, 'basis', 'exact'), m, null);
    select * into bp from bill_payments where bill_id = b.id and status = 'paid' order by created_at desc limit 1;
    if b.wht_expected > 0 and coalesce(bp.wht, 0) = 0 then v_borne := private.book_borne_wht(bp.id, m, true); end if;
  elsif v_mode = 'payout' then
    select * into po from payouts where id = nullif(p->>'payout_id', '')::uuid and org_id = p_org for update;
    if not found or po.status <> 'successful' or po.journal_id is null then raise exception 'Choose a payout from the wallet that went through.'; end if;
    if exists (select 1 from bill_payments where payout_id = po.id) then raise exception 'That payout already paid a bill. Choose another.'; end if;
    v_taken := v_keep > 0 and abs(po.amount - (b.total - v_keep)) <= 0.01;
    if not v_taken and abs(po.amount - b.total) > 0.01 then
      raise exception 'The payout (%) is neither the invoice''s total (%) nor its total less WHT (%).', private.naira(po.amount), private.naira(b.total),
        private.naira(b.total - v_keep);
    end if;
    select coalesce(sum((l->>'debit')::numeric), 0) into v_wl from jsonb_array_elements(po.lines) l;
    if abs(v_wl - po.amount) > 0.01 then raise exception 'Payout % cannot be moved onto a bill. Attach the invoice to its bank line instead.', po.number; end if;
    select * into ba from bank_accounts where id = (select bank_account_id from wallets where id = po.wallet_id);
    -- What the payout was posted to moves onto the bill: the supplier's account now carries it, with the WHT kept back.
    v_jl := jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'payables'), 'debit', b.total, 'party_type', 'vendor', 'party_id', v.id,
      'doc_type', 'bill', 'doc_id', b.id, 'memo', b.number || ' paid by payout ' || po.number));
    for x in select value from jsonb_array_elements(po.lines) loop
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', x->>'code', 'credit', (x->>'debit')::numeric, 'party_type', x->>'party_type', 'party_id', x->>'party_id',
        'memo', 'Payout ' || po.number || ' moved onto ' || b.number));
    end loop;
    if v_taken then
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'wht_payable'), 'credit', b.wht_expected, 'party_type', 'vendor', 'party_id', v.id,
        'doc_type', 'bill', 'doc_id', b.id, 'memo', 'WHT ' || trim(to_char(b.wht_rate * 100, 'FM990.##')) || '% on ' || b.number),
        jsonb_build_object('code', private.acct(p_org, 'wvat_payable'), 'credit', b.wvat_expected, 'party_type', 'vendor', 'party_id', v.id, 'doc_type', 'bill', 'doc_id', b.id,
          'memo', 'VAT withheld on ' || b.number));
    elsif b.wht_expected > 0 then
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', '6512', 'debit', b.wht_expected, 'memo', 'WHT on ' || b.number || ' not taken off the payment to ' || v.name),
        jsonb_build_object('code', private.acct(p_org, 'wht_payable'), 'credit', b.wht_expected, 'party_type', 'vendor', 'party_id', v.id, 'doc_type', 'bill', 'doc_id', b.id,
          'memo', 'WHT on ' || b.number || ', borne by the business'));
    end if;
    j := private.post_entry(p_org, 'Paid ' || v.name || ' · ' || b.number || ' by payout ' || po.number, 'bill_payment', b.id, m.id, m.id, v_jl, coalesce(po.completed_at, po.created_at),
      jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'payout', 'id', po.id, 'ref', po.number))));
    insert into bill_payments (org_id, bill_id, method, status, gross, wht, wvat, net, bank_account_id, payout_id, paid_at, reference, journal_id, created_by)
    values (p_org, b.id, 'wallet', 'paid', b.total, case when v_taken then b.wht_expected else 0 end, case when v_taken then b.wvat_expected else 0 end, po.amount, ba.id, po.id,
      coalesce(po.completed_at, po.created_at),
      coalesce(po.reference, po.number), j.id, m.id)
    returning * into bp;
    if not v_taken and b.wht_expected > 0 then v_borne := private.book_borne_wht(bp.id, m, false); end if;
    perform private.refresh_bill(b.id);
  elsif v_mode = 'paid' then
    v_taken := coalesce((p->>'wht_taken')::boolean, true) and v_keep > 0;
    j := private.record_bill_payment(b.id, ba.id, b.total, case when v_taken then v_keep else 0 end, private.posting_time(p_org, v_paid),
      coalesce(nullif(trim(p->>'invoice_no'), ''), b.number), m);
    select * into bp from bill_payments where journal_id = j.id;
    if not v_taken and b.wht_expected > 0 then v_borne := private.book_borne_wht(bp.id, m, true); end if;
  end if;
  select * into b from bills where id = b.id;
  return jsonb_build_object('bill', jsonb_build_object('id', b.id, 'number', b.number, 'status', b.status, 'net', b.subtotal, 'vat', b.vat_total, 'total', b.total,
      'wht', b.wht_expected, 'wht_withheld', b.wht_withheld, 'wht_borne', b.wht_borne, 'wht_category', b.wht_category, 'due_date', b.due_date),
    'vendor_id', v_vendor, 'payment', v_mode,
    'paid_on', case when bp.id is not null then private.local_day(p_org, bp.paid_at) end,
    'wht_month', case when bp.id is not null and b.wht_expected > 0 then date_trunc('month', private.local_day(p_org, bp.paid_at))::date end);
end $$;

-- A payout the bank sends back after it paid a bill: the bill's payment is taken back with it, including an entry of its
-- own (an invoice claimed against the payout later), so the supplier's account and the WHT owed come back too.
create or replace function private.on_payout_change() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare bp record;
begin
  for bp in select * from bill_payments where payout_id = new.id loop
    if new.status = 'successful' and new.journal_id is not null then
      update bill_payments set status = 'paid', journal_id = coalesce(case when bp.journal_id is distinct from new.journal_id and bp.status = 'paid' then bp.journal_id end, new.journal_id),
        paid_at = coalesce(case when bp.status = 'paid' then bp.paid_at end, new.completed_at, now()) where id = bp.id;
    elsif new.status in ('failed', 'cancelled') then
      update bill_payments set status = 'failed' where id = bp.id;
    elsif new.status = 'reversed' then
      if bp.status = 'paid' and bp.journal_id is not null and bp.journal_id is distinct from new.journal_id
         and not exists (select 1 from journals where reversal_of = bp.journal_id) then
        perform private.reverse_entry(bp.journal_id, new.requested_by, 'Payout ' || new.number || ' sent back by the bank', null);
      end if;
      update bill_payments set status = 'reversed' where id = bp.id;
    end if;
    perform private.refresh_bill(bp.bill_id);
  end loop;
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Money in with no Counta invoice: the VAT decided per payment
-- ---------------------------------------------------------------------------
-- Where a payment's VAT came from: person (someone chose it), product (the narration names one of the business's
-- products), usual (what the business usually sells, until the AI looks), ai (the AI decided). vat_check: a person
-- should look at it.
alter table public.sales add column if not exists vat_source text;
alter table public.sales add column if not exists vat_check boolean not null default false;
alter table public.sales add column if not exists vat_reason text;
alter table public.sales add column if not exists vat_confidence numeric(4,3);
alter table public.sales add column if not exists vat_ai_at timestamptz;
alter table public.sales add column if not exists vat_ai_tries int not null default 0;
alter table public.sales drop constraint if exists sales_vat_source_check;
alter table public.sales add constraint sales_vat_source_check check (vat_source in ('person', 'product', 'usual', 'ai'));
create index if not exists sales_vat_ai_waiting on public.sales(created_at) where channel = 'bank' and vat_source = 'usual' and vat_ai_at is null;
create index if not exists sales_vat_to_check on public.sales(org_id) where channel = 'bank' and vat_check;
-- A rise in a sale's VAT after its VAT moved to the tax wallet moves the rest on its own.
alter table public.tax_moves drop constraint if exists tax_moves_source_type_check;
alter table public.tax_moves add constraint tax_moves_source_type_check check (source_type in ('allocation', 'bill_payment', 'release', 'sale', 'sale_vat_change'));

create or replace function private.vat_word(p_treatment text) returns text
language sql immutable set search_path = public as $$
  select case p_treatment when 'standard' then 'VAT at 7.5%' when 'zero' then 'no VAT (zero-rated)' when 'exempt' then 'no VAT (exempt)' else p_treatment end
$$;

-- The VAT on a payment taken as a sale before the AI looks: a product of the business the narration names, else what the
-- business sells (its products' treatment, or standard when it has none). Unsure when the business's products differ
-- or it has none. A treatment a person set for everything the business sells still holds.
create or replace function private.receipt_vat_default(p_org uuid, p_text text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; v_t text := lower(coalesce(p_text, '')); v_item text; v_treat text; v_n int; v_usual text;
begin
  select * into o from orgs where id = p_org;
  if coalesce(o.receipts_vat_treatment, 'standard') in ('zero', 'exempt') then
    return jsonb_build_object('treatment', o.receipts_vat_treatment, 'source', 'person', 'check', false,
      'reason', 'You said everything the business sells is ' || case when o.receipts_vat_treatment = 'zero' then 'zero-rated' else 'exempt' end || '.');
  end if;
  select i.name, i.vat_treatment into v_item, v_treat from items i
  where i.org_id = p_org and not i.archived and length(trim(i.name)) >= 4
    and v_t ~ ('\m' || regexp_replace(lower(trim(i.name)), '([.*+?^${}()|\[\]\\])', '\\\1', 'g') || '\M')
  order by length(i.name) desc limit 1;
  if v_item is not null then
    return jsonb_build_object('treatment', v_treat, 'source', 'product', 'check', false, 'reason', 'The payment names ' || v_item || ', which carries ' || private.vat_word(v_treat) || '.');
  end if;
  select count(distinct vat_treatment) into v_n from items where org_id = p_org and not archived;
  select vat_treatment into v_usual from items where org_id = p_org and not archived group by vat_treatment order by count(*) desc, (vat_treatment = 'standard') desc limit 1;
  return jsonb_build_object('treatment', coalesce(v_usual, 'standard'), 'source', 'usual', 'check', v_n <> 1,
    'reason', case when v_n = 1 then 'Everything the business sells in Counta carries ' || private.vat_word(v_usual) || '.'
                   when v_n > 1 then 'The business sells things with different VAT. Most carry ' || private.vat_word(v_usual) || '.'
                   else 'Counta has no products for this business yet, so it starts from VAT at 7.5%.' end);
end $$;

-- Money in posted to sales with no Counta invoice behind it: a receipt for the walk-in customer (or the customer named), its
-- VAT worked back from the amount or added on top as the business answered, and decided per payment: p_meta.vat_treatment
-- when a person chose it, else private.receipt_vat_default until the AI looks.
create or replace function private.bank_line_sale(p_line uuid, p_account text, p_party_type text, p_party uuid, p_stage text, p_meta jsonb,
  m public.members) returns public.journals
language plpgsql security definer set search_path = public, private as $$
declare bl public.bank_lines; b public.bank_accounts; o public.orgs; s public.sales; j public.journals; v_amt numeric; v_rate numeric; v_net numeric; v_vat numeric;
  v_absorbed numeric; v_cust uuid; v_name text; v_treat text; v_incl boolean; v_def jsonb;
begin
  select * into bl from bank_lines where id = p_line for update;
  select * into b from bank_accounts where id = bl.bank_account_id;
  select * into o from orgs where id = bl.org_id;
  v_amt := abs(bl.amount);
  v_def := case when coalesce(p_meta->>'vat_treatment', '') in ('standard', 'zero', 'exempt')
                then jsonb_build_object('treatment', p_meta->>'vat_treatment', 'source', 'person', 'check', false, 'reason', nullif(p_meta->>'vat_reason', ''))
                else private.receipt_vat_default(bl.org_id, concat_ws(' ', bl.description, bl.reference, bl.counterparty)) end;
  v_treat := v_def->>'treatment';
  v_incl := coalesce(o.vat_on_receipts, 'inclusive') = 'inclusive';
  v_rate := case when v_treat = 'standard' then private.vat_rate(bl.line_date) else 0 end;
  if v_incl then v_net := round(v_amt / (1 + v_rate), 2); v_vat := v_amt - v_net; v_absorbed := 0;
  else v_net := v_amt; v_vat := round(v_amt * v_rate, 2); v_absorbed := v_vat; end if;
  v_cust := case when p_party_type = 'customer' and p_party is not null and exists (select 1 from customers where id = p_party and org_id = bl.org_id) then p_party
             else private.walk_in(bl.org_id) end;
  select name into v_name from customers where id = v_cust;
  insert into sales (org_id, doc_type, number, status, customer_id, customer_name, location_id, channel, issue_date, prices_include_vat, vat_registered,
    subtotal, vat_total, total, amount_paid, reference, notes, created_by, issued_at, vat_source, vat_check, vat_reason)
  values (bl.org_id, 'receipt', private.doc_number(bl.org_id, 'receipt'), 'paid', v_cust, v_name, private.main_location(bl.org_id), 'bank', bl.line_date, v_incl, true,
    v_net, v_vat, v_net + v_vat, v_net + v_vat, nullif(left(coalesce(bl.reference, ''), 60), ''),
    left('Received into ' || b.name || ' with no Counta invoice: ' || coalesce(nullif(bl.description, ''), 'payment'), 300), m.id, now(),
    v_def->>'source', coalesce((v_def->>'check')::boolean, false), left(v_def->>'reason', 300))
  returning * into s;
  insert into sale_lines (sale_id, org_id, line_no, kind, description, qty, unit_label, unit_price, vat_treatment, vat_rate, net, vat, gross, revenue_account, nrs_vat_label)
  values (s.id, bl.org_id, 1, 'goods', left(coalesce(nullif(trim(bl.description), ''), 'Sale'), 300), 1, 'sale', v_net, v_treat, v_rate, v_net, v_vat, v_net + v_vat, p_account,
    case when v_treat <> 'standard' then private.nrs_label_guess(v_treat, bl.description) end);
  j := private.post_entry(bl.org_id, 'Sale ' || s.number || ' · received with no invoice · ' || left(coalesce(bl.description, ''), 80), 'sale', s.id, m.id, null,
    jsonb_build_array(
      jsonb_build_object('code', b.ledger_code, 'debit', v_amt, 'memo', bl.description),
      jsonb_build_object('code', '6512', 'debit', v_absorbed, 'memo', 'VAT on ' || s.number || ' not charged to the customer'),
      jsonb_build_object('code', p_account, 'credit', v_net, 'location_id', s.location_id, 'doc_type', 'sale', 'doc_id', s.id, 'memo', s.number || ' · ' || v_name),
      jsonb_build_object('code', private.acct(bl.org_id, 'output_vat'), 'credit', v_vat, 'location_id', s.location_id, 'doc_type', 'sale', 'doc_id', s.id,
        'memo', 'Output VAT ' || s.number)),
    private.line_time(bl.org_id, bl.line_date),
    coalesce(p_meta, '{}'::jsonb) || jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id, 'source', bl.source,
      'date', bl.line_date, 'amount', bl.amount, 'narration', bl.description, 'stage', p_stage), jsonb_build_object('type', 'sale', 'id', s.id, 'ref', s.number))));
  update sales set journal_id = j.id where id = s.id;
  perform private.queue_sale_vat_move(s.id, b.id);
  update bank_lines set status = 'posted', journal_id = j.id, stage = p_stage,
    matched_by = coalesce(nullif(p_meta->>'matched_by', ''), case when p_stage = 'ai' then 'ai' when p_stage = 'user' then 'user' else 'rule' end),
    confidence = coalesce(nullif(p_meta->>'ai_confidence', '')::numeric, 1)
  where id = bl.id;
  return j;
end $$;

-- A payment taken as a sale, booked again with another VAT treatment: its entry reversed and posted again with the new
-- split, the receipt and its line changed in place, the bank line pointed at the new entry, and the VAT waiting for the tax
-- wallet set to the new figure. Not once the month's VAT return is filed.
create or replace function private.rebook_bank_sale(p_sale uuid, p_treat text, p_author uuid) returns public.sales
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; sl public.sale_lines; bl public.bank_lines; ba public.bank_accounts; j public.journals; v_amt numeric; v_rate numeric; v_net numeric;
  v_vat numeric; v_abs numeric; v_moved numeric; v_name text;
begin
  select * into s from sales where id = p_sale for update;
  if s.id is null or s.channel <> 'bank' or s.doc_type <> 'receipt' or s.status = 'void' or s.journal_id is null then
    raise exception 'Only a payment taken as a sale with no Counta invoice changes its VAT here.';
  end if;
  if p_treat not in ('standard', 'zero', 'exempt') then raise exception 'Choose how VAT applies to this payment.'; end if;
  select * into sl from sale_lines where sale_id = s.id order by line_no limit 1;
  if sl.vat_treatment = p_treat then return s; end if;
  if exists (select 1 from vat_periods where org_id = s.org_id and period = date_trunc('month', s.issue_date)::date and status in ('filed', 'paid')) then
    raise exception 'The % VAT return including this sale is filed. Reopen it first.', to_char(s.issue_date, 'FMMonth YYYY');
  end if;
  select * into bl from bank_lines where journal_id = s.journal_id and org_id = s.org_id limit 1;
  if bl.id is null then raise exception 'The bank line behind % is not in Counta any more.', s.number; end if;
  select * into ba from bank_accounts where id = bl.bank_account_id;
  v_amt := abs(bl.amount);
  v_rate := case when p_treat = 'standard' then private.vat_rate(s.issue_date) else 0 end;
  if s.prices_include_vat then v_net := round(v_amt / (1 + v_rate), 2); v_vat := v_amt - v_net; v_abs := 0;
  else v_net := v_amt; v_vat := round(v_amt * v_rate, 2); v_abs := v_vat; end if;
  v_name := coalesce(s.customer_name, 'Walk-in customer');
  perform private.reverse_entry(s.journal_id, p_author, 'VAT on ' || s.number || ' changed to ' || private.vat_word(p_treat), null);
  j := private.post_entry(s.org_id, 'Sale ' || s.number || ' · received with no invoice · ' || private.vat_word(p_treat) || ' · ' || left(coalesce(bl.description, ''), 60),
    'sale', s.id, p_author, null,
    jsonb_build_array(
      jsonb_build_object('code', ba.ledger_code, 'debit', v_amt, 'memo', bl.description),
      jsonb_build_object('code', '6512', 'debit', v_abs, 'memo', 'VAT on ' || s.number || ' not charged to the customer'),
      jsonb_build_object('code', sl.revenue_account, 'credit', v_net, 'location_id', s.location_id, 'doc_type', 'sale', 'doc_id', s.id, 'memo', s.number || ' · ' || v_name),
      jsonb_build_object('code', private.acct(s.org_id, 'output_vat'), 'credit', v_vat, 'location_id', s.location_id, 'doc_type', 'sale', 'doc_id', s.id,
        'memo', 'Output VAT ' || s.number)),
    private.line_time(s.org_id, bl.line_date),
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id, 'source', bl.source, 'date', bl.line_date, 'amount', bl.amount,
      'narration', bl.description), jsonb_build_object('type', 'sale', 'id', s.id, 'ref', s.number))));
  update sales set subtotal = v_net, vat_total = v_vat, total = v_net + v_vat, amount_paid = v_net + v_vat, journal_id = j.id where id = s.id returning * into s;
  update sale_lines set vat_treatment = p_treat, vat_rate = v_rate, unit_price = v_net, net = v_net, vat = v_vat, gross = v_net + v_vat,
    nrs_vat_label = case when p_treat <> 'standard' then private.nrs_label_guess(p_treat, bl.description) end
  where id = sl.id;
  update bank_lines set journal_id = j.id where id = bl.id;
  -- The VAT set aside for the tax wallet follows the sale: what has not moved is changed; a rise after it moved moves the rest.
  update tax_moves set amount = case when v_vat > 0 then v_vat else amount end, status = case when v_vat > 0 then 'pending' else 'cancelled' end
  where source_type = 'sale' and source_id = s.id and kind = 'vat' and (status = 'pending' or (status = 'cancelled' and v_vat > 0));
  select coalesce(sum(amount), 0) into v_moved from tax_moves where kind = 'vat' and status in ('sending', 'done')
    and ((source_type = 'sale' and source_id = s.id) or (source_type = 'sale_vat_change' and description = 'More VAT on ' || s.number));
  if not exists (select 1 from tax_moves where source_type = 'sale' and source_id = s.id and kind = 'vat') then
    perform private.queue_sale_vat_move(s.id, ba.id);
  elsif v_moved > 0 and v_vat > v_moved + 0.004 then
    insert into tax_moves (org_id, tax_wallet_id, wallet_id, direction, kind, amount, period, source_type, source_id, description)
    select s.org_id, t.id, w.id, 'in', 'vat', v_vat - v_moved, date_trunc('month', s.issue_date)::date, 'sale_vat_change', gen_random_uuid(), 'More VAT on ' || s.number
    from wallets w join tax_wallets t on t.org_id = w.org_id and t.status = 'active' where w.bank_account_id = ba.id and w.status = 'active';
  end if;
  return s;
end $$;

-- What the page shows for one such payment.
create or replace function private.receipt_vat_json(p_sale uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', s.id, 'number', s.number, 'date', s.issue_date, 'amount', s.total, 'net', s.subtotal, 'vat', s.vat_total,
    'treatment', sl.vat_treatment, 'source', s.vat_source, 'check', s.vat_check, 'reason', s.vat_reason, 'confidence', s.vat_confidence,
    'ai_waiting', s.vat_source = 'usual' and s.vat_ai_at is null and s.vat_ai_tries < 3, 'ai_looked', s.vat_ai_at is not null,
    'narration', bl.description, 'counterparty', bl.counterparty, 'account', ba.name,
    'filed', exists (select 1 from vat_periods vp where vp.org_id = s.org_id and vp.period = date_trunc('month', s.issue_date)::date and vp.status in ('filed', 'paid')))
  from sales s
  join lateral (select * from sale_lines where sale_id = s.id order by line_no limit 1) sl on true
  left join bank_lines bl on bl.journal_id = s.journal_id and bl.org_id = s.org_id
  left join bank_accounts ba on ba.id = bl.bank_account_id
  where s.id = p_sale
$$;

-- A person sets (or confirms) the VAT on a payment taken as a sale. p: {treatment: standard|zero|exempt}
create or replace function public.set_receipt_vat(p_sale uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members;
begin
  select * into s from sales where id = p_sale;
  if not found then raise exception 'Sale not found.'; end if;
  m := private.require_vat_work(s.org_id);
  if coalesce(p->>'treatment', '') not in ('standard', 'zero', 'exempt') then raise exception 'Choose how VAT applies to this payment.'; end if;
  perform private.rebook_bank_sale(s.id, p->>'treatment', m.id);
  update sales set vat_source = 'person', vat_check = false, vat_confidence = null,
    vat_reason = left('Set by ' || coalesce(m.display_name, 'a person') || ' to ' || private.vat_word(p->>'treatment') || '.', 300)
  where id = s.id;
  return private.receipt_vat_json(s.id);
end $$;

-- Ask the AI to look again at the payments marked to check (after products or the business's profile change).
create or replace function public.recheck_receipts_vat(p_org uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_n int;
begin
  m := private.require_vat_work(p_org);
  update sales set vat_source = 'usual', vat_ai_at = null, vat_ai_tries = 0
  where org_id = p_org and channel = 'bank' and doc_type = 'receipt' and status <> 'void' and vat_check and coalesce(vat_source, 'usual') in ('usual', 'ai');
  get diagnostics v_n = row_count;
  if v_n > 0 then perform private.call_function('ai', jsonb_build_object('action', 'vat_receipts_pending')); end if;
  return jsonb_build_object('asked', v_n);
end $$;

-- For the ai function: payments waiting for the AI, by business, with what each business sells. Each call counts as a
-- try, so a payment the AI cannot answer is not asked about forever.
create or replace function public.svc_receipts_for_vat(p_limit int default 40) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_ids uuid[];
begin
  select coalesce(array_agg(id), '{}') into v_ids from (
    select id from sales where channel = 'bank' and doc_type = 'receipt' and status <> 'void' and vat_source = 'usual' and vat_ai_at is null and vat_ai_tries < 3
      and created_at > now() - interval '60 days'
    order by created_at limit least(greatest(coalesce(p_limit, 40), 1), 100) for update skip locked) z;
  update sales set vat_ai_tries = vat_ai_tries + 1 where id = any(v_ids);
  return (select coalesce(jsonb_agg(jsonb_build_object('org_id', o.id,
      'business', jsonb_build_object('name', o.name, 'industry', o.industry, 'offering', o.offering, 'activity', o.principal_activity,
        'category', (select label from business_categories where id = o.category_id),
        'examples', (select k.answers->'examples' from kyc_profiles k where k.org_id = o.id and k.answers ? 'examples' order by k.updated_at desc limit 1)),
      'products', (select coalesce(jsonb_agg(jsonb_build_object('name', i.name, 'vat', i.vat_treatment) order by i.name), '[]'::jsonb)
        from (select name, vat_treatment from items where org_id = o.id and not archived order by created_at desc limit 60) i),
      'sales', (select jsonb_agg(jsonb_build_object('id', s.id, 'date', s.issue_date, 'amount', s.total, 'treatment', sl.vat_treatment,
          'narration', concat_ws(' · ', nullif(bl.description, ''), nullif(bl.reference, '')), 'sender', bl.counterparty) order by s.created_at)
        from sales s join lateral (select vat_treatment from sale_lines where sale_id = s.id order by line_no limit 1) sl on true
        left join bank_lines bl on bl.journal_id = s.journal_id and bl.org_id = s.org_id
        where s.id = any(v_ids) and s.org_id = o.id))), '[]'::jsonb)
    from orgs o where o.id in (select org_id from sales where id = any(v_ids)));
end $$;

-- The AI's answer for one payment. p: {treatment, confidence 0-1, reason}. At the business's threshold (never below 80%) the
-- answer is booked; below it the payment keeps its VAT and is marked to check. A choice a person made since stays.
create or replace function public.svc_set_receipt_vat(p_sale uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; v_t text := p->>'treatment'; v_conf numeric := least(greatest(coalesce(private.num(p->>'confidence'), 0), 0), 1); v_th numeric;
  v_reason text := left(nullif(trim(p->>'reason'), ''), 300);
begin
  select * into s from sales where id = p_sale for update;
  if not found or s.channel <> 'bank' or s.status = 'void' then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if s.vat_source is distinct from 'usual' or s.vat_ai_at is not null then return jsonb_build_object('ok', true, 'kept', coalesce(s.vat_source, 'none')); end if;
  select greatest(coalesce(auto_post_threshold, 0.8), 0.8) into v_th from orgs where id = s.org_id;
  if v_t in ('standard', 'zero', 'exempt') and v_conf >= v_th then
    begin
      perform private.rebook_bank_sale(s.id, v_t, null);
    exception when others then
      update sales set vat_ai_at = now(), vat_check = true, vat_confidence = v_conf,
        vat_reason = left('The AI says ' || private.vat_word(v_t) || ', but ' || sqlerrm, 300) where id = s.id;
      return jsonb_build_object('ok', true, 'applied', false, 'reason', sqlerrm);
    end;
    update sales set vat_source = 'ai', vat_check = false, vat_confidence = v_conf, vat_ai_at = now(),
      vat_reason = coalesce(v_reason, 'The AI decided ' || private.vat_word(v_t) || '.') where id = s.id;
    return jsonb_build_object('ok', true, 'applied', true, 'treatment', v_t);
  end if;
  update sales set vat_ai_at = now(), vat_check = true, vat_confidence = v_conf,
    vat_reason = coalesce(v_reason, 'The AI could not tell from the payment what was sold.') where id = s.id;
  return jsonb_build_object('ok', true, 'applied', false);
end $$;

-- Every three minutes (agents_tick): items waiting for their VAT, and payments taken as sales waiting for the AI.
create or replace function private.vat_tick() returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if exists (select 1 from items where vat_checked_at is null and not archived and coalesce(vat_basis->>'source', '') <> 'manual') then
    perform private.call_function('ai', jsonb_build_object('action', 'vat_classify_pending'));
  end if;
  if exists (select 1 from sales where channel = 'bank' and vat_source = 'usual' and vat_ai_at is null and vat_ai_tries < 3 and status <> 'void'
             and created_at > now() - interval '60 days') then
    perform private.call_function('ai', jsonb_build_object('action', 'vat_receipts_pending'));
  end if;
end $$;

-- The VAT work of the Sales from another POS and Input VAT tabs (as before), with the payments taken as sales and their VAT.
create or replace function public.get_sales_schedules(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Your role does not see VAT work.' using errcode = '42501'; end if;
  select * into o from orgs where id = p_org;
  return jsonb_build_object('schedules', (select coalesce(jsonb_agg(private.schedule_json(id, false) order by created_at desc), '[]'::jsonb)
      from (select id, created_at from sales_schedules where org_id = p_org order by created_at desc limit 60) x),
    'settings', jsonb_build_object('vat_on_receipts', o.vat_on_receipts, 'receipts_vat_treatment', o.receipts_vat_treatment, 'vat_registered', o.vat_registered),
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'kind', kind) order by kind, name), '[]'::jsonb)
      from bank_accounts where org_id = p_org and active),
    'purchases', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'number', b.number, 'vendor', v.name, 'vendor_ref', b.vendor_ref, 'bill_date', b.bill_date,
        'net', b.subtotal, 'vat', b.vat_total, 'total', b.total, 'status', b.status, 'document_path', b.document_path,
        'wht', b.wht_expected, 'wht_withheld', b.wht_withheld, 'wht_borne', b.wht_borne,
        'paid_on', (select private.local_day(p_org, max(bp.paid_at)) from bill_payments bp where bp.bill_id = b.id and bp.status = 'paid')) order by b.created_at desc), '[]'::jsonb)
      from (select * from bills where org_id = p_org and source = 'ai' and notes like 'Input VAT claim%' order by created_at desc limit 100) b join vendors v on v.id = b.vendor_id),
    'receipts', (select coalesce(jsonb_agg(private.receipt_vat_json(id) order by vat_check desc, issue_date desc, created_at desc), '[]'::jsonb)
      from (select id, vat_check, issue_date, created_at from sales where org_id = p_org and channel = 'bank' and doc_type = 'receipt' and status <> 'void'
            order by vat_check desc, issue_date desc, created_at desc limit 60) r),
    'receipt_counts', (select jsonb_build_object('to_check', count(*) filter (where vat_check),
        'ai_waiting', count(*) filter (where vat_source = 'usual' and vat_ai_at is null and vat_ai_tries < 3), 'total', count(*))
      from sales where org_id = p_org and channel = 'bank' and doc_type = 'receipt' and status <> 'void'),
    'can', jsonb_build_object('work', private.perm_of(m, 'keep_books') or private.perm_of(m, 'file_tax')));
end $$;

-- ---------------------------------------------------------------------------
-- 5. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function private.wht_guess(text), private.payee_kind_guess(text), private.bulk_wht_skip(uuid, text),
  private.vat_purchase_vendor(uuid, text, text), private.wht_preview(uuid, uuid, text, boolean, text, numeric, date),
  private.book_borne_wht(uuid, public.members, boolean), private.vat_word(text), private.receipt_vat_default(uuid, text),
  private.rebook_bank_sale(uuid, text, uuid), private.receipt_vat_json(uuid) from public, anon, authenticated;
revoke all on function public.vat_purchase_payments(uuid, jsonb), public.set_receipt_vat(uuid, jsonb), public.recheck_receipts_vat(uuid) from public, anon;
grant execute on function public.vat_purchase_payments(uuid, jsonb), public.set_receipt_vat(uuid, jsonb), public.recheck_receipts_vat(uuid) to authenticated;
revoke all on function public.svc_receipts_for_vat(int), public.svc_set_receipt_vat(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.svc_receipts_for_vat(int), public.svc_set_receipt_vat(uuid, jsonb) to service_role;
revoke execute on function public.get_attention(uuid), public.get_sales_schedules(uuid), public.save_vat_purchase(uuid, jsonb) from public, anon;
grant execute on function public.get_attention(uuid), public.get_sales_schedules(uuid), public.save_vat_purchase(uuid, jsonb) to authenticated;
