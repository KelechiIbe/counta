-- Bulk payments to contractors with no bill in Counta (TaxStreem item 3).
--
-- A row of the bulk payment file that says what work was done ("Type of work") pays a contractor without a bill: Counta
-- finds the contractor among the suppliers (by Tax ID, account number or name) or adds it, writes and approves a bill
-- for the work with withholding tax at the bill's rate, and pays it from the wallet like any bill. The amount in the file
-- is what the contractor receives, or the contract amount before WHT goes in its own column.
--
-- The same rules as a bill decide whether it can be paid:
--   * where the work attracts withholding tax, the contractor's Tax ID must be on file and checked, or checked with the
--     NRS from the bulk payment page (tin_check_number and the mono function's verify_number), with the NRS name
--     matching the contractor's;
--   * a business (company or business name) is paid only with its address on file;
--   * withholding tax from an individual or a business name needs the state its revenue service is in.
-- Declining or cancelling the batch voids the bills it wrote for payments that never left.

-- What the NRS answered for a number checked without a supplier record.
alter table public.tin_checks add column if not exists taxpayer_name text;
alter table public.tin_checks add column if not exists nrs_tin text;
create index if not exists tin_checks_number on public.tin_checks(org_id, number, at desc);

-- The withholding tax type for what a sheet calls the work: a code, a name from wht_rates, or a common word for it.
create or replace function private.wht_code_for(p text) returns text
language sql stable security definer set search_path = public, private as $$
  with t as (select lower(regexp_replace(trim(coalesce(p, '')), '\s+', ' ', 'g')) s)
  select case when t.s = '' then null else coalesce(
    (select r.code from wht_rates r where lower(r.code) = t.s or lower(replace(r.code, '_', ' ')) = t.s or lower(r.name) = t.s limit 1),
    case
      when t.s ~ '(no wht|no withholding|not subject)' then 'none'
      when t.s ~ 'reimburs' then 'ex_reimbursable'
      when t.s ~ '(road|bridge|building|power plant)' then 'construction_roads'
      when t.s ~ '(construct|civil work|renovat|installation)' then 'construction_other'
      when t.s ~ '(consult|professional|legal|lawyer|solicitor|audit|accounting|technical|management|advis|architect|engineer|survey|valuer|medical|doctor)' then 'professional'
      when t.s ~ 'broker' then 'brokerage'
      when t.s ~ '(commission|agency fee)' then 'commission'
      when t.s ~ '(rent|lease|hire)' then 'rent'
      when t.s ~ '(director)' then 'directors_fees'
      when t.s ~ '(royalt)' then 'royalty'
      when t.s ~ '(supply of goods|goods|supplies|materials|purchase)' then 'goods'
      when t.s ~ '(service|labour|labor|repair|maintenance|cleaning|security|transport|haulage|logistics|delivery|catering|event|printing|design|training|casual|artisan|freelance|contract)' then 'services'
    end) end
  from t
$$;

-- "Company", "Ltd", "business name", "BN", "individual", "person": the three kinds of contractor.
create or replace function private.contractor_type(p text) returns text
language sql immutable set search_path = public as $$
  select case
    when lower(coalesce(p, '')) ~ '(individual|person|self.?employed|freelance|natural)' then 'individual'
    when lower(coalesce(p, '')) ~ '(business name|enterprise|sole|^bn|partnership|venture)' then 'business_name'
    when lower(coalesce(p, '')) ~ '(company|ltd|limited|plc|corporate|incorporated|^rc)' then 'company'
  end
$$;

-- The supplier a contractor row means: the same Tax ID, else the same account number with a name that agrees, else the name.
create or replace function private.find_contractor(p_org uuid, p_tin text, p_account text, p_name text) returns public.vendors
language plpgsql stable security definer set search_path = public, private as $$
declare v public.vendors; v_tin text := private.clean_tax_id(p_tin); v_acct text := regexp_replace(coalesce(p_account, ''), '\D', '', 'g');
begin
  if v_tin is not null then
    select * into v from vendors where org_id = p_org and private.clean_tax_id(tin) = v_tin order by created_at limit 1;
    if found then return v; end if;
  end if;
  if v_acct ~ '^[0-9]{10}$' and p_name is not null then
    select * into v from vendors where org_id = p_org and account_number = v_acct
      and (private.same_taxpayer(name, p_name) or private.same_taxpayer(coalesce(account_name, '-'), p_name)) order by created_at limit 1;
    if found then return v; end if;
  end if;
  return private.find_vendor(p_org, p_name);
end $$;

-- Bills a declined or cancelled batch wrote for its contractors, voided when nothing was paid on them.
create or replace function private.void_bulk_bills(p_batch uuid, m public.members) returns int
language plpgsql security definer set search_path = public, private as $$
declare pb public.payout_batches; b public.bills; v_n int := 0;
begin
  select * into pb from payout_batches where id = p_batch;
  for b in select * from bills where org_id = pb.org_id and source = 'bulk' and external_ref like pb.id::text || ':%' and status <> 'void' for update loop
    if exists (select 1 from bill_payments where bill_id = b.id and status in ('paid', 'processing')) then continue; end if;
    if b.journal_id is not null then
      perform private.reverse_entry(b.journal_id, m.id, 'Bill ' || b.number || ' voided: bulk payment ' || pb.number || ' did not go ahead', null);
    end if;
    update bills set status = 'void', voided_by = m.id, voided_at = now(), void_reason = 'Bulk payment ' || pb.number || ' did not go ahead' where id = b.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- A Tax ID from a bulk payment file checked with the NRS before the contractor is on file. Counted against the business's
-- 60 lookups a day; a number checked in the last day is not asked again.
create or replace function public.tin_check_number(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_num text := regexp_replace(coalesce(p->>'number', ''), '\D', '', 'g'); tc public.tin_checks; v_id uuid;
begin
  m := private.require(p_org, 'make_payments');
  if v_num !~ '^[0-9]{10,13}$' then raise exception '% is not a Tax ID. Tax IDs have 10 to 13 digits.', coalesce(nullif(trim(p->>'number'), ''), 'That'); end if;
  select * into tc from tin_checks where org_id = p_org and number = v_num and outcome in ('verified', 'mismatch', 'not_found') and at > now() - interval '1 day'
  order by at desc limit 1;
  if found then
    return jsonb_build_object('done', true, 'number', v_num, 'status', tc.outcome, 'taxpayer_name', tc.taxpayer_name);
  end if;
  if (select count(*) from tin_checks where org_id = p_org and at > now() - interval '1 day') >= 60 then
    raise exception 'Counta has checked many Tax IDs for this business today. Try again tomorrow.';
  end if;
  insert into tin_checks (org_id, number, channel, member_id) values (p_org, v_num, 'tin', m.id) returning id into v_id;
  return jsonb_build_object('check_id', v_id, 'number', v_num, 'channel', 'tin', 'name', left(nullif(trim(p->>'name'), ''), 120));
end $$;

-- The NRS answer for such a number (through the mono edge function). p: {check_id, found, nrs_tin, taxpayer_name, name}.
create or replace function public.svc_tin_number_result(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare tc public.tin_checks; v_found boolean := coalesce((p->>'found')::boolean, false); v_tp text := left(nullif(trim(p->>'taxpayer_name'), ''), 200);
  v_nrs text := regexp_replace(coalesce(p->>'nrs_tin', ''), '\D', '', 'g'); v_status text;
begin
  select * into tc from tin_checks where id = nullif(p->>'check_id', '')::uuid and org_id = p_org and vendor_id is null for update;
  if not found then raise exception 'Check not found.'; end if;
  v_status := case when not v_found then 'not_found' when v_tp is null or nullif(trim(p->>'name'), '') is null then 'verified'
                   when private.same_taxpayer(v_tp, p->>'name') then 'verified' else 'mismatch' end;
  update tin_checks set outcome = v_status, taxpayer_name = v_tp, nrs_tin = case when v_nrs ~ '^[0-9]{13}$' then v_nrs end where id = tc.id;
  return jsonb_build_object('number', tc.number, 'status', v_status, 'taxpayer_name', v_tp);
end $$;

create or replace function private.bulk_row(p_org uuid, r jsonb, p_default text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_err text[] := '{}'; v_amt numeric := round(private.num(r->>'amount'), 2); b public.bills; v public.vendors; v_kind text; v_code text;
  v_gross numeric; v_wht numeric := 0; v_due numeric; v_left_wht numeric; v_full_net numeric; v_rate numeric; v_bill_ref text := nullif(trim(r->>'bill'), '');
  v_supplier text := nullif(trim(r->>'supplier'), ''); v_purpose text; v_lines jsonb; v_label text; sv public.vendors;
  cv public.vendors; v_wcode text; v_ctype text; v_vtype text; v_cname text; v_g numeric; v_tin text; v_tstatus text; tc public.tin_checks; v_contractor jsonb;
  v_corp boolean; v_base_rate numeric; v_check text;
begin
  if coalesce(r->>'account_number', '') !~ '^[0-9]{10}$' then v_err := v_err || 'Account numbers have 10 digits.'::text; end if;
  if coalesce(trim(r->>'bank_code'), '') = '' then v_err := v_err || 'Choose the bank.'::text; end if;
  if coalesce(trim(r->>'account_name'), '') = '' then v_err := v_err || 'The bank has not confirmed the account name.'::text; end if;
  if v_supplier is not null then sv := private.find_vendor(p_org, v_supplier); end if;
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
        -- What pay_bill keeps back for this gross: WHT for the WHT column; withholding VAT on top.
        if v_gross is not null then v_wht := v_gross - v_amt - coalesce((private.bill_withholding(b.id, v_gross)->>'wvat')::numeric, 0); end if;
        -- A supplier whose WHT goes to a state revenue service needs its state first (TaxStreem sign-off W-2).
        if coalesce((private.bill_tax_flags(b.id)->>'missing_state')::boolean, false) then
          v_err := v_err || format('Add the state of %s before paying %s: its withholding tax goes to that state''s revenue service.', v.name, b.number);
        end if;
      end if;
    end if;
  elsif nullif(trim(r->>'work'), '') is not null then
    -- A contractor paid with no bill in Counta: the bill is written when the batch is saved, with withholding tax on it.
    v_wcode := private.wht_code_for(r->>'work');
    v_cname := left(coalesce(v_supplier, nullif(trim(r->>'name'), ''), nullif(trim(r->>'account_name'), '')), 120);
    cv := private.find_contractor(p_org, r->>'tin', r->>'account_number', v_cname);
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
    if v_cname is null then v_err := v_err || 'Give the contractor''s name.'::text; end if;
    if v_wcode is null then
      v_err := v_err || format('"%s" is not a type of work Counta knows. Use one from the template''s list.', left(trim(r->>'work'), 60));
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
    if v_wcode is not null and v_ctype is not null then
      -- The rate the bill will get (private.bill_wht): exempt types and suppliers, goods the supplier makes, then the matrix.
      v_corp := case when cv.id is not null and cv.entity_type is not null then (private.vendor_wht_profile(cv.id)->>'corporate')::boolean else v_ctype = 'company' end;
      v_rate := case when (select exemption from wht_rates where code = v_wcode) or coalesce(cv.wht_exempt, false) or cv.entity_type = 'government'
                       or (v_wcode = 'goods' and coalesce(cv.is_manufacturer, false)) then 0
                     else coalesce(private.wht_matrix_rate(v_wcode, v_corp, coalesce(cv.resident, true)), 0) end;
      v_base_rate := v_rate;
      v_tin := coalesce(private.clean_tax_id(cv.tin), private.clean_tax_id(r->>'tin'));
      v_g := round(private.num(r->>'gross'), 2);
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
          elsif tc.taxpayer_name is not null and not (private.same_taxpayer(tc.taxpayer_name, v_cname)
              or private.same_taxpayer(tc.taxpayer_name, coalesce(nullif(trim(r->>'account_name'), ''), '-'))) then
            v_err := v_err || format('The NRS has the Tax ID %s under %s, not %s.', v_tin, tc.taxpayer_name, v_cname);
          else
            v_tstatus := 'verified';
          end if;
        end if;
      end if;
      -- A business is paid only with its address on file.
      if (case when cv.id is not null and cv.entity_type is not null then private.vendor_is_enterprise(cv) else v_ctype in ('company', 'business_name') end)
         and coalesce(nullif(trim(cv.address), ''), nullif(trim(r->>'address'), '')) is null then
        v_err := v_err || format('Add %s''s address: a business is paid only with its address on file.', v_cname);
      end if;
      -- Withholding tax from an individual or a business name goes to the state revenue service, so the state must be known.
      if v_rate > 0 and not v_corp and coalesce(private.state_code(cv.state), private.state_code(cv.address), private.state_code(cv.location),
           private.state_code(r->>'state'), private.state_code(r->>'address')) is null then
        v_err := v_err || format('Add %s''s state (or an address with the state): withholding tax from an individual or a business name goes to the state revenue service.', v_cname);
      end if;
    end if;
    v := cv; v_kind := 'contractor'; v_purpose := 'vendor';
    v_label := coalesce(cv.name, v_cname) || ' · ' || coalesce((select lower(name) from wht_rates where code = v_wcode), 'contract');
    v_contractor := jsonb_build_object('vendor_id', cv.id, 'name', v_cname, 'type', v_ctype, 'tin', v_tin, 'tin_status', v_tstatus, 'work', v_wcode,
      'rate', v_rate, 'address', nullif(trim(r->>'address'), ''), 'state', private.ng_state_of_address(coalesce(nullif(trim(r->>'state'), ''), r->>'address')),
      'tin_to_check', v_check, 'new', cv.id is null);
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
    'lines', v_lines, 'contractor', v_contractor);
end $$;

create or replace function public.create_payout_batch(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; c jsonb; pb public.payout_batches; r jsonb; v_src jsonb; v_status text; v_title text; v_first text;
  v_vid uuid; b public.bills; k jsonb;
begin
  m := private.require(p_org, 'make_payments');
  perform private.require_payments_open(p_org);
  if nullif(p->>'client_uuid', '') is not null then
    select * into pb from payout_batches where client_uuid = (p->>'client_uuid')::uuid and org_id = p_org;
    if found then return private.batch_json(pb.id); end if;
  end if;
  select * into o from orgs where id = p_org;
  c := private.bulk_check(p_org, p, m);
  if (c->>'error_count')::int > 0 then
    select format('Row %s: %s', x->>'row', x->'errors'->>0) into v_first from jsonb_array_elements(c->'rows') x where not (x->>'ok')::boolean limit 1;
    raise exception '%', v_first;
  end if;
  if (c->>'total')::numeric + (c->>'fee_estimate')::numeric > (c->>'available')::numeric + 0.004 then
    raise exception 'The wallet has ₦% available. These payments need ₦% with transfer fees. Fund the wallet first.',
      to_char((c->>'available')::numeric, 'FM999,999,999,990.00'), to_char((c->>'total')::numeric + (c->>'fee_estimate')::numeric, 'FM999,999,999,990.00');
  end if;
  v_status := case when (c->>'needs_approval')::boolean then 'pending_approval' else 'approved' end;
  v_title := left(coalesce(nullif(trim(p->>'title'), ''), 'Bulk payment ' || to_char(now() at time zone 'Africa/Lagos', 'DD Mon YYYY')), 80);
  insert into payout_batches (org_id, number, title, wallet_id, default_account, status, mode, row_count, total, wht_total, fee_estimate, file_name, requested_by,
    approved_by, approved_at, client_uuid)
  values (p_org, 'BP-' || lpad(private.next_no(p_org, 'BP', 1)::text, 5, '0'), v_title, (c->>'wallet_id')::uuid, nullif(trim(p->>'default_account'), ''), v_status,
    c->>'mode', (c->>'ok_count')::int, (c->>'total')::numeric, (c->>'wht_total')::numeric, (c->>'fee_estimate')::numeric, left(nullif(trim(p->>'file_name'), ''), 200),
    m.id, case when v_status = 'approved' then m.id end, case when v_status = 'approved' then now() end, nullif(p->>'client_uuid', '')::uuid)
  returning * into pb;
  perform set_config('counta.payout_batch', pb.id::text, true);
  for r in select value from jsonb_array_elements(c->'rows') loop
    select value into v_src from jsonb_array_elements(p->'rows') where value->'row' = r->'row' limit 1;
    perform set_config('counta.payout_row', jsonb_build_object('row', r->'row', 'ref', v_src->>'reference')::text, true);
    if r->>'kind' = 'contractor' then
      -- The contractor (added when new, gaps filled when on file) and its bill, written and approved, then paid like any bill.
      k := r->'contractor';
      v_vid := nullif(k->>'vendor_id', '')::uuid;
      if v_vid is null then
        insert into vendors (org_id, name, entity_type, is_individual, tin, tin_status, tin_checked_at, address, state, bank_code, bank_name, account_number,
          account_name, wht_category, channel, resident, default_account)
        values (p_org, k->>'name', k->>'type', k->>'type' = 'individual', k->>'tin', k->>'tin_status', case when k->>'tin_status' is not null then now() end,
          k->>'address', k->>'state', v_src->>'bank_code', v_src->>'bank_name', v_src->>'account_number', v_src->>'account_name', k->>'work', 'email', true,
          r->>'account')
        returning id into v_vid;
      else
        update vendors set
          tin_status = case when k->>'tin_status' = 'verified' and coalesce(tin_status, '') not in ('verified', 'confirmed')
                              and coalesce(private.clean_tax_id(tin), k->>'tin') = k->>'tin' then 'verified' else tin_status end,
          tin_checked_at = case when k->>'tin_status' = 'verified' and coalesce(tin_status, '') not in ('verified', 'confirmed')
                              and coalesce(private.clean_tax_id(tin), k->>'tin') = k->>'tin' then now() else tin_checked_at end,
          tin = coalesce(nullif(trim(tin), ''), k->>'tin'),
          address = coalesce(nullif(trim(address), ''), k->>'address'), state = coalesce(nullif(trim(state), ''), k->>'state'),
          entity_type = coalesce(entity_type, k->>'type'), is_individual = coalesce(is_individual, k->>'type' = 'individual'),
          bank_code = coalesce(bank_code, v_src->>'bank_code'), bank_name = coalesce(bank_name, v_src->>'bank_name'),
          account_name = case when account_number is null then v_src->>'account_name' else account_name end, account_number = coalesce(account_number, v_src->>'account_number')
        where id = v_vid;
      end if;
      b := private.write_bill(p_org, jsonb_build_object('vendor_id', v_vid, 'vendor_ref', nullif(trim(v_src->>'reference'), ''), 'source', 'bulk', 'external_ref', pb.id::text || ':' || (r->>'row'),
        'vat_charged', false, 'wht_category', k->>'work', 'notes', 'Written for bulk payment ' || pb.number || ' · ' || pb.title,
        'lines', jsonb_build_array(jsonb_build_object('description', coalesce(nullif(trim(v_src->>'narration'), ''), v_title), 'account_code', r->>'account',
          'qty', 1, 'unit_cost', (r->>'gross')::numeric))), m);
      -- What the check showed is what is paid: a bill whose withholding tax works out differently stops the batch.
      if abs(b.wht_expected - coalesce((r->>'wht')::numeric, 0)) > 0.01 then
        raise exception 'Row %: the withholding tax on % now works out at ₦%, not ₦%. Check the file again.', r->>'row', (select name from vendors where id = v_vid),
          to_char(b.wht_expected, 'FM999,999,999,990.00'), to_char(coalesce((r->>'wht')::numeric, 0), 'FM999,999,999,990.00');
      end if;
      b := private.post_bill(b.id, m);
      perform public.pay_bill(b.id, jsonb_build_object('method', 'wallet', 'amount', (r->>'gross')::numeric,
        'bank_code', v_src->>'bank_code', 'bank_name', v_src->>'bank_name', 'account_number', v_src->>'account_number', 'account_name', v_src->>'account_name',
        'narration', nullif(trim(v_src->>'narration'), '')));
    elsif r->>'kind' = 'bill' then
      perform public.pay_bill((r->>'bill_id')::uuid, jsonb_build_object('method', 'wallet', 'amount', (r->>'gross')::numeric, 'wht', (r->>'wht')::numeric,
        'bank_code', v_src->>'bank_code', 'bank_name', v_src->>'bank_name', 'account_number', v_src->>'account_number', 'account_name', v_src->>'account_name',
        'narration', nullif(trim(v_src->>'narration'), '')));
    else
      perform private.create_payout(p_org, jsonb_build_object('purpose', r->>'purpose', 'vendor_id', r->>'vendor_id', 'amount', (r->>'amount')::numeric,
        'bank_code', v_src->>'bank_code', 'bank_name', v_src->>'bank_name', 'account_number', v_src->>'account_number', 'account_name', v_src->>'account_name',
        'narration', coalesce(nullif(trim(v_src->>'narration'), ''), v_title)), r->'lines', m);
    end if;
  end loop;
  perform set_config('counta.payout_batch', '', true);
  perform set_config('counta.payout_row', '', true);
  perform private.refresh_payout_batch(pb.id);
  if v_status = 'pending_approval' then
    perform private.notify_perm(p_org, 'approve_payments', 'payout',
      'Approve a bulk payment of ₦' || to_char(pb.total, 'FM999,999,999,990.00') || ' to ' || pb.row_count || ' account' || case when pb.row_count = 1 then '' else 's' end,
      pb.number || ' · ' || pb.title || ' · asked by ' || coalesce(m.display_name, ''), '/payments?tab=bulk&batch=' || pb.id, 'batch-' || pb.id, m.id);
  end if;
  return private.batch_json(pb.id);
end $$;

create or replace function public.approve_payout_batch(p_batch uuid, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare pb public.payout_batches; m public.members;
begin
  select * into pb from payout_batches where id = p_batch for update;
  if not found then raise exception 'Bulk payment not found.'; end if;
  m := private.require(pb.org_id, 'approve_payments');
  if pb.status <> 'pending_approval' then raise exception '% is %.', pb.number, replace(pb.status, '_', ' '); end if;
  if pb.requested_by = m.id and m.role <> 'owner' then raise exception 'Someone other than the person who asked must approve it.'; end if;
  update payout_batches set approved_by = m.id, approved_at = now(), note = case when not p_approve then nullif(trim(p_note), '') else note end where id = pb.id;
  update payouts set status = case when p_approve then 'approved' else 'cancelled' end, approved_by = m.id, approved_at = now(),
    error = case when not p_approve then coalesce(nullif(trim(p_note), ''), 'Not approved') else error end
  where batch_id = pb.id and status = 'pending_approval';
  if not p_approve then perform private.void_bulk_bills(pb.id, m); end if;
  return private.batch_json(pb.id);
end $$;

create or replace function public.cancel_payout_batch(p_batch uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare pb public.payout_batches; m public.members; v_n int;
begin
  select * into pb from payout_batches where id = p_batch for update;
  if not found then raise exception 'Bulk payment not found.'; end if;
  m := private.require(pb.org_id, 'make_payments');
  if pb.status not in ('pending_approval', 'approved', 'sending') then raise exception '% is %.', pb.number, replace(pb.status, '_', ' '); end if;
  update payouts set status = 'cancelled', error = coalesce(error, 'Cancelled by ' || coalesce(m.display_name, 'a user'))
  where batch_id = pb.id and status in ('pending_approval', 'approved');
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'Nothing is left to cancel: the rest of % has gone to the bank.', pb.number; end if;
  perform private.void_bulk_bills(pb.id, m);
  return private.batch_json(pb.id);
end $$;

revoke execute on function private.wht_code_for(text), private.contractor_type(text), private.find_contractor(uuid, text, text, text),
  private.void_bulk_bills(uuid, public.members) from public, anon, authenticated;
revoke execute on function public.tin_check_number(uuid, jsonb), public.svc_tin_number_result(uuid, jsonb) from public, anon;
grant execute on function public.tin_check_number(uuid, jsonb) to authenticated;
revoke execute on function public.svc_tin_number_result(uuid, jsonb) from authenticated;
grant execute on function public.svc_tin_number_result(uuid, jsonb) to service_role;
