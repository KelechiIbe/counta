-- 21 November: the books inbox asks from a short list, and short payments that are exactly the WHT and the NCD levy settle.
--
-- 1. Atlas always names a best guess and up to four other likely accounts for a bank line (the short list in the books
--    inbox). The guess and the list are stored on the question; questions already waiting get theirs on the next run.
-- 2. A payment short of what an invoice says by exactly the WHT the customer was expected to deduct, the 1% Nigerian
--    Content Development levy (on the value before VAT or the total), VAT a withholding agent kept, or any of them together,
--    settles the invoice in full: the WHT goes to the WHT credit notes (1401), the levy to statutory charges (6512 unless the
--    business chose another), the VAT withheld to 1405. This holds for every way money comes in: the bank feed, the books
--    inbox, Record a payment, pay-by-transfer requests and sales schedules. A naira of rounding is allowed for WHT and the
--    levy. The customer is then marked as deducting the levy, and the rate they deducted is remembered.
-- 3. Each invoice can carry the WHT rate expected on it (internal; never printed). Without one, the customer's remembered
--    rate is used, and then the business's usual rate from its type of work (doubled when the business has no Tax ID).
--
-- Safe to run twice.

-- ---------------------------------------------------------------------------
-- 1. Atlas's short list
-- ---------------------------------------------------------------------------
-- The other accounts the agent offered for a bank line: postable, never a control or tax account, none twice, never the
-- guess itself, at most four, in the agent's order. p_alts: [{account_code, why}] (plain codes are accepted too).
create or replace function private.alt_codes(p_org uuid, p_alts jsonb, p_code text) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('account_code', c, 'why', w) order by n), '[]'::jsonb)
  from (select c, w, n from (
          select distinct on (c) c, w, n from (
            select trim(coalesce(e->>'account_code', case when jsonb_typeof(e) = 'string' then e #>> '{}' end, '')) c,
              left(trim(coalesce(e->>'why', '')), 120) w, n
            from jsonb_array_elements(case when jsonb_typeof(p_alts) = 'array' then p_alts else '[]'::jsonb end) with ordinality t(e, n)) y
          where c <> '' and c is distinct from p_code and private.postable(p_org, c) and c !~ '^(101|1101|1102|1201|1202|1203|2101|2102|2201|1402|1401|2202|9)'
          order by c, n) z
        order by n limit 4) q
$$;

-- The agent's answer for a bank line now carries its short list of other likely accounts.
create or replace function public.svc_classify_line(p_line uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
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
      jsonb_build_object('account_code', v_code, 'party_type', p->>'party_type', 'party_id', p->>'party_id')
        || case when p ? 'alternatives' then jsonb_build_object('alternatives', private.alt_codes(bl.org_id, p->'alternatives', v_code)) else '{}'::jsonb end,
      v_conf, p->>'rationale', 'ai', 'auto_posted', abs(bl.amount), j.id, p->>'model')
    returning id into v_pid;
    update bank_lines set proposal_id = v_pid where id = bl.id;
    return jsonb_build_object('ok', true, 'posted', true, 'journal_id', j.id);
  end if;
  v_pid := private.suspend_line(bl.id, coalesce(nullif(p->>'title', ''), bl.description),
    coalesce(nullif(p->>'question', ''), case when bl.amount > 0 then 'What was this money for?' else 'What was this payment for?' end),
    jsonb_build_object('account_code', v_code, 'party_type', p->>'party_type', 'party_id', p->>'party_id', 'kind', p->>'kind')
      || case when p ? 'alternatives' then jsonb_build_object('alternatives', private.alt_codes(bl.org_id, p->'alternatives', v_code)) else '{}'::jsonb end, v_conf, p->>'rationale', 'ai', p->>'model');
  return jsonb_build_object('ok', true, 'posted', false, 'proposal_id', v_pid);
end $function$;


-- Questions waiting in the books inbox that have no short list yet, with what the agent needs to give one. Each line's id
-- is the question's id. Questions about matching a document (an invoice or a bill) are left out: they have their own list.
create or replace function public.svc_questions_for_ai(p_org uuid, p_limit int default 40) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object(
    'org', (select jsonb_build_object('id', o.id, 'name', o.name, 'industry', o.industry, 'vat_registered', o.vat_registered,
       'cash_sales_without_invoices', o.cash_sales_without_invoices, 'threshold', greatest(o.auto_post_threshold, 0.8)) from orgs o where o.id = p_org),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'date', bl.line_date, 'amount', bl.amount, 'narration', bl.description,
        'reference', bl.reference, 'counterparty', bl.counterparty, 'account', b.name, 'account_kind', b.kind,
        'history', (select jsonb_agg(h) from (select l.account_code code, count(*) n from bank_lines x join journal_lines l on l.journal_id = x.journal_id
            and l.account_code <> b.ledger_code where x.org_id = p_org and x.party_key = bl.party_key and x.status in ('posted', 'matched') and x.id <> bl.id
            group by 1 order by 2 desc limit 3) h)) order by bl.line_date), '[]'::jsonb)
      from (select * from ai_proposals where org_id = p_org and status = 'pending' and source_type = 'bank_line' and not (proposal ? 'alternatives')
              and coalesce(proposal->>'kind', '') not in ('invoice_match', 'bill_match') order by created_at limit greatest(p_limit, 1)) pr
      join bank_lines bl on bl.id = pr.source_id
      join bank_accounts b on b.id = bl.bank_account_id),
    'accounts', (select jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name, 'category', a.category, 'ifrs_line', a.ifrs_line) order by a.code)
      from private.accounts_of(p_org) a
      where a.active and not a.is_group and private.postable(p_org, a.code) and a.code !~ '^(101|1101|1102|1203|1201|1202|2101|2102|2201|1402|1401|2202|9)'),
    'customers', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name)), '[]'::jsonb) from customers where org_id = p_org and not is_walk_in and not archived),
    'vendors', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name)), '[]'::jsonb) from vendors where org_id = p_org),
    'directors', (select coalesce(jsonb_agg(display_name), '[]'::jsonb) from members where org_id = p_org and role = 'owner'))
$$;

-- Businesses with such questions.
create or replace function public.svc_orgs_with_questions() returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(distinct org_id), '[]'::jsonb) from ai_proposals
  where status = 'pending' and source_type = 'bank_line' and not (proposal ? 'alternatives') and coalesce(proposal->>'kind', '') not in ('invoice_match', 'bill_match')
$$;

-- The agent's short list for a question already waiting. Nothing posts from here: a question with no guess takes the
-- agent's guess (kept below the threshold), and a question that had one keeps it, with a different new guess put first
-- in the list. p: {account_code, confidence, rationale, question, alternatives: [{account_code, why}], model}
create or replace function public.svc_suggest_proposal(p_proposal uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare pr public.ai_proposals; v_code text := nullif(trim(coalesce(p->>'account_code', '')), ''); v_old text; v_alts jsonb;
begin
  select * into pr from ai_proposals where id = p_proposal for update;
  if not found or pr.status <> 'pending' or pr.source_type <> 'bank_line' then return jsonb_build_object('ok', false, 'reason', 'not_open'); end if;
  if v_code is not null and (not private.postable(pr.org_id, v_code) or v_code ~ '^(101|1101|1102|1201|1202|1203|2101|2102|2201|1402|1401|2202|9)') then v_code := null; end if;
  v_old := nullif(pr.proposal->>'account_code', '');
  if v_old is null and v_code is not null then
    update ai_proposals set
      proposal = proposal || jsonb_build_object('account_code', v_code, 'alternatives', private.alt_codes(pr.org_id, p->'alternatives', v_code), 'suggested_at', now(),
        'model', p->>'model'),
      confidence = least(greatest(coalesce(private.num(p->>'confidence'), 0), 0), 0.79),
      rationale = coalesce(nullif(left(p->>'rationale', 600), ''), rationale),
      question = coalesce(question, nullif(p->>'question', ''))
    where id = pr.id;
  else
    v_alts := case when v_code is not null and v_code is distinct from v_old
      then jsonb_build_array(jsonb_build_object('account_code', v_code, 'why', coalesce(nullif(left(p->>'rationale', 120), ''), 'Atlas''s guess this time')))
           || coalesce(case when jsonb_typeof(p->'alternatives') = 'array' then p->'alternatives' end, '[]'::jsonb)
      else p->'alternatives' end;
    update ai_proposals set proposal = proposal || jsonb_build_object('alternatives', private.alt_codes(pr.org_id, v_alts, v_old), 'suggested_at', now(),
        'model', p->>'model')
    where id = pr.id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

revoke execute on function private.alt_codes(uuid, jsonb, text), public.svc_questions_for_ai(uuid, int), public.svc_orgs_with_questions(),
  public.svc_suggest_proposal(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.svc_questions_for_ai(uuid, int), public.svc_orgs_with_questions(), public.svc_suggest_proposal(uuid, jsonb) to service_role;

-- The books inbox: what Atlas posted shows its bank line, for the short list under "Wrong account".
create or replace function public.get_books_inbox(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
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
        'line', (select jsonb_build_object('date', bl.line_date, 'amount', bl.amount, 'narration', bl.description, 'counterparty', bl.counterparty)
           from bank_lines bl where bl.id = p.source_id and p.source_type = 'bank_line'),
        'journal_ref', (select ref from journals where id = p.journal_id)) order by p.created_at desc), '[]'::jsonb)
      from (select * from ai_proposals where org_id = p_org and status in ('auto_posted', 'info') and created_at > now() - interval '45 days' order by created_at desc limit 200) p),
    'payments_to_confirm', (select count(*) from collections where org_id = p_org and status = 'pending'),
    'bills_to_approve', (select count(*) from bills where org_id = p_org and status = 'draft'),
    'assets_to_confirm', (select count(*) from fixed_assets where org_id = p_org and status = 'pending_confirmation'),
    'payouts_to_approve', (select count(*) from payouts where org_id = p_org and status = 'pending_approval'),
    'suspense', (select coalesce(sum(debit - credit), 0) from journal_lines where org_id = p_org and account_code = '9001'));
end $function$;


-- ---------------------------------------------------------------------------
-- 2. What a customer may keep back from a payment
-- ---------------------------------------------------------------------------
alter table public.sales add column if not exists wht_rate numeric(6,4);
alter table public.customers add column if not exists wht_rate numeric(6,4);
alter table public.customers add column if not exists ncd_levy boolean not null default false;
comment on column public.sales.wht_rate is 'The WHT rate the customer is expected to deduct from this invoice (internal; null: the customer''s or the business''s usual rate)';
comment on column public.customers.wht_rate is 'The WHT rate this customer deducts, set when a payment shows it or by a person';
comment on column public.customers.ncd_levy is 'Deducts the 1% Nigerian Content Development levy (an oil and gas operator or contractor)';
do $$ begin
  alter table public.sales add constraint sales_wht_rate_check check (wht_rate is null or (wht_rate >= 0 and wht_rate <= 0.25));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.customers add constraint customers_wht_rate_check check (wht_rate is null or (wht_rate >= 0 and wht_rate <= 0.25));
exception when duplicate_object then null; end $$;

-- The levy a customer deducted is a new kind of payment line.
do $$ declare c record; begin
  for c in select conname from pg_constraint where conrelid = 'public.collections'::regclass and contype = 'c' and pg_get_constraintdef(oid) ~ 'wht_credit' loop
    execute format('alter table public.collections drop constraint %I', c.conname);
  end loop;
  alter table public.collections add constraint collections_method_check
    check (method in ('cash', 'transfer', 'card', 'pos', 'flutterwave', 'rail', 'cheque', 'wht_credit', 'wvat_credit', 'ncd_levy', 'advance', 'other'));
end $$;

-- Where the levy is charged: Other statutory charges and levies, unless the business picks another statutory account.
insert into public.posting_roles (role, label, description, default_code, allowed, sort)
values ('ncd_levy', 'NCD levy deducted by customers', 'The 1% Nigerian Content Development levy oil and gas customers deduct from payments. A cost to the business.',
  '6512', '^65[0-9]{2}$', 47)
on conflict (role) do nothing;

-- The WHT a business's customers usually deduct, from its type of work: professional, consultancy, technical and
-- management services 5%, construction 5%, rent 10%, goods 2%, other services 2%; doubled when it has no Tax ID.
create or replace function private.org_wht_rate(p_org uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('code', k.code, 'rate', round(coalesce(r.rate_corp_res, r.rate_company) * case when nullif(trim(o.tin), '') is null then 2 else 1 end, 4),
    'doubled', nullif(trim(o.tin), '') is null)
  from orgs o
  cross join lateral (select case
      when o.category_id in ('professional', 'creative', 'technology', 'finance') or coalesce(o.professional_services, false) then 'professional'
      when o.category_id = 'construction' then 'construction_other'
      when o.category_id = 'real_estate' then 'rent'
      when coalesce(o.offering, 'goods') = 'goods' then 'goods'
      else 'services' end code) k
  join wht_rates r on r.code = k.code
  where o.id = p_org
$$;

-- The WHT rate expected on an invoice and where it comes from: the invoice, the customer, or the business.
-- A person buying for themselves rarely deducts WHT, so their invoices expect none unless someone says otherwise.
create or replace function private.expected_wht(p_sale uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select case
    when s.wht_rate is not null then jsonb_build_object('rate', s.wht_rate, 'source', 'invoice')
    when cu.wht_rate is not null then jsonb_build_object('rate', cu.wht_rate, 'source', 'customer')
    when cu.kind = 'individual' or coalesce(cu.is_walk_in, true) then jsonb_build_object('rate', 0, 'source', 'person')
    else private.org_wht_rate(s.org_id) || jsonb_build_object('source', 'business') end
  from sales s left join customers cu on cu.id = s.customer_id
  where s.id = p_sale
$$;

-- What a short payment of p_amt against a sale with p_due left means, when the shortfall is what the customer was
-- allowed to keep back: WHT (the expected rate first, then 2%, 5%, 10%, and 4% and 20% for a business with no Tax ID), the 1% NCD levy on the
-- value before VAT or on the total, and, for a withholding VAT agent, the VAT not yet credited; alone or together. What
-- was already booked on the sale is taken off. WHT and the levy may be a naira out (the customer's rounding, which goes
-- to the WHT or else the levy); VAT withheld on its own must be exact. Exact answers win over rounded ones. Null when the
-- shortfall is something else.
create or replace function private.customer_short_split(p_sale uuid, p_due numeric, p_amt numeric) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare s public.sales; cu public.customers; v_vat numeric := 0; v_gap numeric; v_net numeric; v_tol numeric; v_exp jsonb; v_exp_rate numeric;
  v_wht_done numeric; v_ncd_done numeric; v_vat_done numeric; r numeric; v_wb numeric; nb text; v_wv numeric; v_pass int;
  v_wht numeric; v_ncd numeric; v_sum numeric; v_diff numeric; v_rates numeric[];
begin
  select * into s from sales where id = p_sale;
  if s.id is null or coalesce(p_amt, 0) <= 0 or p_amt >= p_due - 0.004 then return null; end if;
  select * into cu from customers where id = s.customer_id;
  if cu.id is null or cu.is_walk_in then return null; end if;
  select coalesce(sum(a.amount) filter (where c.method = 'wht_credit'), 0), coalesce(sum(a.amount) filter (where c.method = 'ncd_levy'), 0),
         coalesce(sum(a.amount) filter (where c.method = 'wvat_credit'), 0)
    into v_wht_done, v_ncd_done, v_vat_done
  from collection_allocations a join collections c on c.id = a.collection_id where a.sale_id = s.id and c.status = 'confirmed';
  if coalesce(cu.wvat_agent, false) then v_vat := greatest(s.vat_total - v_vat_done, 0); end if;
  v_net := s.total - s.vat_total;
  v_gap := round(p_due - p_amt, 2);
  v_tol := least(1.00, round(v_net * 0.001, 2));
  v_exp := private.expected_wht(s.id);
  v_exp_rate := (v_exp->>'rate')::numeric;
  -- The expected rate, none (the levy or VAT alone), the usual rates, and the doubled ones only for a business with no Tax ID.
  v_rates := array[v_exp_rate, 0, 0.02, 0.05, 0.10]
    || case when (select nullif(trim(o.tin), '') is null from orgs o where o.id = s.org_id) then array[0.04, 0.20]::numeric[] else '{}'::numeric[] end;
  for v_pass in 1..2 loop
    foreach r in array (select array_agg(x order by o) from (select distinct on (x) x, o from unnest(v_rates) with ordinality u(x, o)
                        where x is not null order by x, o) z) loop
      -- WHT on the value before VAT; on the lines before any discount and delivery too, when that differs.
      foreach v_wb in array case when s.subtotal > 0 and abs(s.subtotal - v_net) >= 0.005 then array[v_net, s.subtotal] else array[v_net] end loop
        v_wht := case when r = 0 then 0 else greatest(round(v_wb * r, 2) - v_wht_done, 0) end;
        continue when r > 0 and v_wht = 0;
        foreach nb in array case when cu.ncd_levy then array['net', 'gross', 'none'] else array['none', 'net', 'gross'] end loop
          v_ncd := case nb when 'none' then 0 when 'net' then greatest(round(v_net * 0.01, 2) - v_ncd_done, 0)
                   else greatest(round(s.total * 0.01, 2) - v_ncd_done, 0) end;
          continue when nb <> 'none' and v_ncd = 0;
          foreach v_wv in array case when v_vat > 0 then array[v_vat, 0] else array[0::numeric] end loop
            v_sum := v_wht + v_ncd + v_wv;
            continue when v_sum <= 0;
            v_diff := round(v_gap - v_sum, 2);
            if (v_pass = 1 and abs(v_diff) < 0.005) or (v_pass = 2 and abs(v_diff) <= v_tol and (v_wht > 0 or v_ncd > 0)) then
              if v_wht > 0 then v_wht := v_wht + v_diff; else v_ncd := v_ncd + v_diff; end if;
              return jsonb_build_object('wht', round(v_wht, 2), 'wht_rate', case when v_wht > 0 then r end, 'wvat', v_wv, 'ncd', round(v_ncd, 2),
                'ncd_base', case when v_ncd > 0 then nb end, 'expected_rate', v_exp_rate, 'expected', coalesce(r = v_exp_rate, false),
                'deducted', v_gap, 'rounding', v_diff);
            end if;
          end loop;
        end loop;
      end loop;
    end loop;
  end loop;
  return null;
end $$;

-- Books what the customer kept back: VAT withheld (1405), WHT (1401) and the NCD levy (a cost), each against the sale.
-- A split worked out from a payment ('deducted' is set) also marks the customer as deducting the levy, remembers the WHT
-- rate they used, and tells the people who keep the books (all but the person who recorded it, when they saw it: 'seen').
create or replace function private.book_customer_withholding(p_org uuid, p_customer uuid, p_sale uuid, p_split jsonb, p_at timestamptz, m public.members) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_wht numeric := coalesce((p_split->>'wht')::numeric, 0); v_wvat numeric := coalesce((p_split->>'wvat')::numeric, 0);
  v_ncd numeric := coalesce((p_split->>'ncd')::numeric, 0); v_rate numeric := nullif(p_split->>'wht_rate', '')::numeric;
  cu public.customers; v_num text; v_marked boolean := false; v_kept text[] := '{}'; v_ask text[] := '{}';
begin
  if v_wvat > 0 then
    perform private.add_collection(p_org, p_customer, v_wvat, 'wvat_credit', jsonb_build_object('reference', 'VAT withheld',
      'received_at', p_at, 'note', 'VAT the customer withholds and pays to the NRS; credited in the VAT return', 'spread', false), m, 'confirmed', array[p_sale]);
  end if;
  if v_wht > 0 then
    perform private.add_collection(p_org, p_customer, v_wht, 'wht_credit', jsonb_build_object('reference', 'WHT deducted',
      'wht_rate', p_split->'wht_rate', 'received_at', p_at, 'note', 'Collect the WHT credit note', 'spread', false), m, 'confirmed', array[p_sale]);
  end if;
  if v_ncd > 0 then
    perform private.add_collection(p_org, p_customer, v_ncd, 'ncd_levy', jsonb_build_object('reference', 'NCD levy deducted',
      'received_at', p_at, 'note', 'The 1% Nigerian Content Development levy the customer deducted; ask them for the NCDF remittance receipt', 'spread', false),
      m, 'confirmed', array[p_sale]);
  end if;
  if not (p_split ? 'deducted') then return; end if;
  select * into cu from customers where id = p_customer for update;
  if v_ncd > 0 and not coalesce(cu.ncd_levy, false) then update customers set ncd_levy = true where id = p_customer; v_marked := true; end if;
  if v_wht > 0 and v_rate > 0 and cu.wht_rate is distinct from v_rate then update customers set wht_rate = v_rate where id = p_customer; end if;
  select number into v_num from sales where id = p_sale;
  if v_wht > 0 then v_kept := v_kept || (private.naira(v_wht) || ' WHT' || coalesce(' (' || rtrim(rtrim(to_char(v_rate * 100, 'FM990.00'), '0'), '.') || '%)', '')); v_ask := v_ask || 'the WHT credit note'::text; end if;
  if v_ncd > 0 then v_kept := v_kept || (private.naira(v_ncd) || ' NCD levy (1%)'); v_ask := v_ask || 'the NCDF receipt'::text; end if;
  if v_wvat > 0 then v_kept := v_kept || (private.naira(v_wvat) || ' VAT withheld'); end if;
  perform private.notify_perm(p_org, 'keep_books', 'payment', coalesce(v_num, 'An invoice') || ' settled in full',
    coalesce(cu.name, 'The customer') || ' kept back ' || array_to_string(v_kept, ' and ') || '.'
      || case when cardinality(v_ask) > 0 then ' Ask them for ' || array_to_string(v_ask, ' and ') || '.' else '' end
      || case when v_marked then ' Counta now expects the levy from them.' else '' end,
    '/sell/sales?open=' || p_sale, 'withheld-' || p_sale, case when p_split ? 'seen' then m.id end);
end $$;

-- The levy a customer deducted posts to the levy account (Dr 6512 / Cr receivables).
create or replace function private.post_collection(p_collection uuid, m members)
 RETURNS collections
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare c public.collections; b public.bank_accounts; v_alloc numeric := 0; v_jl jsonb; j public.journals; v_target text; a record; v_due numeric;
  v_cust text; v_party_target boolean;
begin
  select * into c from collections where id = p_collection for update;
  if c.journal_id is not null then return c; end if;
  if c.status <> 'confirmed' then raise exception 'Only confirmed payments post.'; end if;
  select name into v_cust from customers where id = c.customer_id;
  if c.method not in ('wht_credit', 'wvat_credit', 'ncd_levy', 'advance') then
    select * into b from bank_accounts where id = c.bank_account_id;
    if not found then raise exception 'Choose the account the money went into.'; end if;
  end if;
  if c.direction = 'out' then
    v_jl := jsonb_build_array(
      jsonb_build_object('code', private.acct(c.org_id, 'receivables'), 'debit', c.amount - c.advance_part, 'party_type', 'customer', 'party_id', c.customer_id,
        'doc_type', 'collection', 'doc_id', c.id, 'memo', 'Refund ' || c.number),
      jsonb_build_object('code', private.acct(c.org_id, 'customer_advances'), 'debit', c.advance_part, 'party_type', 'customer', 'party_id', c.customer_id,
        'doc_type', 'collection', 'doc_id', c.id, 'memo', 'Refund ' || c.number),
      jsonb_build_object('code', b.ledger_code, 'credit', c.amount, 'doc_type', 'collection', 'doc_id', c.id, 'memo', 'Refund ' || c.number || ' · ' || v_cust));
  else
    -- A payment confirmed after the sale was settled another way keeps only what is still owed; the rest becomes customer credit.
    for a in select ca.sale_id, ca.amount from collection_allocations ca where ca.collection_id = c.id for update loop
      select s.total - s.credited - coalesce((select sum(x.amount) from collection_allocations x join collections cc on cc.id = x.collection_id
          where x.sale_id = s.id and cc.status = 'confirmed' and cc.id <> c.id), 0)
        into v_due from sales s where s.id = a.sale_id and s.status not in ('void', 'cancelled');
      if coalesce(v_due, 0) <= 0.004 then
        delete from collection_allocations where collection_id = c.id and sale_id = a.sale_id;
      elsif a.amount > v_due then
        update collection_allocations set amount = v_due where collection_id = c.id and sale_id = a.sale_id;
      end if;
    end loop;
    v_party_target := c.method in ('wht_credit', 'wvat_credit', 'advance');
    v_target := case c.method when 'wht_credit' then private.acct(c.org_id, 'wht_receivable') when 'wvat_credit' then private.acct(c.org_id, 'vat_withheld_by_customers')
                when 'advance' then private.acct(c.org_id, 'customer_advances') when 'ncd_levy' then private.acct(c.org_id, 'ncd_levy') else b.ledger_code end;
    v_jl := jsonb_build_array(jsonb_build_object('code', v_target, 'debit', c.amount - c.fee, 'doc_type', 'collection', 'doc_id', c.id,
      'party_type', case when v_party_target then 'customer' end, 'party_id', case when v_party_target then c.customer_id end,
      'memo', c.number || ' · ' || v_cust || coalesce(' · ' || c.reference, '')));
    if c.fee > 0 then
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(c.org_id, 'payment_fees'), 'debit', c.fee, 'doc_type', 'collection',
        'doc_id', c.id, 'memo', 'Payment fee ' || c.number));
    end if;
    for a in select ca.*, s.number, s.journal_id sale_journal from collection_allocations ca join sales s on s.id = ca.sale_id where ca.collection_id = c.id loop
      v_alloc := v_alloc + a.amount;
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code',
          case when a.sale_journal is null then private.acct(c.org_id, 'customer_advances') else private.acct(c.org_id, 'receivables') end,
        'credit', a.amount, 'party_type', 'customer', 'party_id', c.customer_id, 'doc_type', 'sale', 'doc_id', a.sale_id, 'memo', c.number || ' for ' || a.number));
      update collection_allocations set posted_as = case when a.sale_journal is null then 'advance' else 'receivable' end
      where collection_id = c.id and sale_id = a.sale_id;
    end loop;
    if c.amount - v_alloc > 0.004 then
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(c.org_id, 'customer_advances'), 'credit', c.amount - v_alloc,
        'party_type', 'customer', 'party_id', c.customer_id, 'doc_type', 'collection', 'doc_id', c.id, 'memo', 'Customer credit ' || c.number));
    end if;
  end if;
  j := private.post_entry(c.org_id,
    case when c.direction = 'out' then 'Refund ' when c.method = 'advance' then 'Customer credit used ' when c.method = 'wht_credit' then 'WHT deducted by customer '
      when c.method = 'wvat_credit' then 'VAT withheld by customer ' when c.method = 'ncd_levy' then 'NCD levy deducted by customer ' else 'Payment received ' end || c.number || ' · ' || v_cust,
    'collection', c.id, coalesce(m.id, c.confirmed_by, c.created_by), c.confirmed_by, v_jl, c.received_at,
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', case when c.provider_ref is not null then 'provider' else 'confirmation' end,
      'ref', coalesce(c.provider_ref, c.reference), 'method', c.method, 'confirmed_by', c.confirmed_by))));
  update collections set journal_id = j.id where id = c.id returning * into c;
  for a in select sale_id from collection_allocations where collection_id = c.id loop
    perform private.refresh_sale(a.sale_id);
  end loop;
  return c;
end $function$;

-- Record a payment: the levy as its own field, and a shortfall that is exactly the deductions settles the invoice.
create or replace function public.record_payment(p_org uuid, p_payment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; c public.collections; v_cust uuid := nullif(p_payment->>'customer_id', '')::uuid; v_sale uuid := nullif(p_payment->>'sale_id', '')::uuid;
  v_method text := coalesce(nullif(p_payment->>'method', ''), 'transfer'); v_status text; v_wht numeric; v_wvat numeric; s public.sales;
  v_amt numeric := round(private.num(p_payment->>'amount'), 2); v_confirmer boolean; v_bank uuid := nullif(p_payment->>'bank_account_id', '')::uuid;
  v_ncd numeric; v_due numeric; v_split jsonb;
begin
  m := private.require(p_org, 'record_sales');
  if nullif(p_payment->>'client_uuid', '') is not null then
    select * into c from collections where client_uuid = (p_payment->>'client_uuid')::uuid;
    if found then return jsonb_build_object('collection', to_jsonb(c), 'duplicate', true); end if;
  end if;
  if v_sale is not null then
    select * into s from sales where id = v_sale and org_id = p_org;
    if not found or s.doc_type not in ('receipt', 'invoice', 'order') then raise exception 'Sale not found.'; end if;
    if s.status in ('void', 'cancelled', 'draft') then raise exception '% is %.', s.number, s.status; end if;
    v_cust := s.customer_id;
  end if;
  if v_cust is null or not exists (select 1 from customers where id = v_cust and org_id = p_org) then raise exception 'Choose the customer who paid.'; end if;
  if v_method not in ('cash', 'transfer', 'card', 'pos', 'cheque', 'other') then raise exception 'Unknown payment method.'; end if;
  v_confirmer := private.perm_of(m, 'keep_books') or private.perm_of(m, 'approve_adjustments');
  v_status := case when v_method = 'cash' then 'confirmed'
                   when coalesce((p_payment->>'confirmed')::boolean, false) and v_confirmer then 'confirmed'
                   else 'pending' end;
  if v_method = 'cash' and v_bank is null then
    v_bank := (private.cash_drawer(p_org, coalesce(s.location_id, m.location_id, (select id from locations where org_id = p_org order by is_main desc, created_at limit 1)), m)).id;
  end if;
  if v_status = 'confirmed' and v_bank is null then raise exception 'Choose the account the money went into.'; end if;
  v_wht := round(private.num(p_payment->>'wht_amount'), 2);
  v_wvat := round(private.num(p_payment->>'wvat_amount'), 2);
  v_ncd := round(private.num(p_payment->>'ncd_amount'), 2);
  -- Nothing typed for WHT, VAT or the levy, and the payment leaves exactly what the customer was expected to keep back:
  -- that is booked as kept back and the invoice is settled (unless the person said the rest is still owed).
  if v_sale is not null and coalesce(v_amt, 0) > 0 and coalesce(v_wht, 0) = 0 and coalesce(v_wvat, 0) = 0 and coalesce(v_ncd, 0) = 0
     and coalesce((p_payment->>'auto_split')::boolean, true) and s.doc_type in ('invoice', 'order') and s.journal_id is not null then
    v_due := s.total - s.amount_paid - s.credited - coalesce((select sum(a.amount) from collection_allocations a join collections cc on cc.id = a.collection_id
      where a.sale_id = s.id and cc.status = 'pending'), 0);
    v_split := private.customer_short_split(s.id, v_due, v_amt);
    if v_split is not null then
      perform private.book_customer_withholding(p_org, v_cust, s.id, v_split || '{"seen": true}', least(coalesce(nullif(p_payment->>'received_at', '')::timestamptz, now()), now()), m);
    end if;
  end if;
  -- WHT the customer deducted is a credit against tax, not money (AR-03): Dr 1401 / Cr 1101.
  if coalesce(v_wht, 0) > 0 then
    perform private.add_collection(p_org, v_cust, v_wht, 'wht_credit', jsonb_build_object('reference', 'WHT deducted', 'wht_rate', nullif(p_payment->>'wht_rate', ''),
      'note', 'Collect the withholding tax credit note from the customer', 'spread', v_sale is null), m, 'confirmed', case when v_sale is not null then array[v_sale] end);
  end if;
  -- VAT a customer who is a withholding VAT agent kept: credited in our VAT return (Dr 1405 / Cr 1101).
  if coalesce(v_wvat, 0) > 0 then
    if v_sale is not null and v_wvat > s.vat_total + 0.004 then raise exception 'The VAT withheld cannot be more than the VAT on %.', s.number; end if;
    perform private.add_collection(p_org, v_cust, v_wvat, 'wvat_credit', jsonb_build_object('reference', 'VAT withheld',
      'note', 'VAT the customer withholds and pays to the NRS; credited in the VAT return', 'spread', v_sale is null), m, 'confirmed', case when v_sale is not null then array[v_sale] end);
  end if;
  -- The 1% Nigerian Content Development levy an oil and gas customer deducted: a cost to the business (Dr 6512 / Cr 1101).
  if coalesce(v_ncd, 0) > 0 then
    perform private.add_collection(p_org, v_cust, v_ncd, 'ncd_levy', jsonb_build_object('reference', 'NCD levy deducted',
      'note', 'The 1% Nigerian Content Development levy the customer deducted; ask them for the NCDF remittance receipt', 'spread', v_sale is null),
      m, 'confirmed', case when v_sale is not null then array[v_sale] end);
  end if;
  if coalesce(v_amt, 0) > 0 then
    c := private.add_collection(p_org, v_cust, v_amt, v_method, (p_payment - 'wht_amount' - 'wvat_amount' - 'ncd_amount' - 'auto_split' - 'confirmed' - 'fee') || jsonb_build_object('bank_account_id', v_bank),
      m, v_status, case when v_sale is not null then array[v_sale] end);
  elsif coalesce(v_wht, 0) = 0 and coalesce(v_wvat, 0) = 0 and coalesce(v_ncd, 0) = 0 then
    raise exception 'Enter the amount paid.';
  end if;
  return jsonb_build_object('collection', to_jsonb(c), 'withheld', v_split, 'sale', case when v_sale is not null then private.sale_json(v_sale, private.can_see_costs(p_org)) end);
end $function$;

-- Pay-by-transfer requests: the same rule for money that comes in through an invoice's own account.
create or replace function public.svc_payment_confirmed(p_tx_ref text, d jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare r public.payment_requests; w public.wallets; c public.collections; s public.sales; v_amt numeric; v_fee numeric; m public.members;
  v_due numeric; v_split jsonb;
begin
  select * into r from payment_requests where tx_ref = p_tx_ref for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown_reference'); end if;
  if r.status = 'paid' then return jsonb_build_object('ok', true, 'duplicate', true, 'request', private.request_json(r)); end if;
  v_amt := round(coalesce(private.num(d->>'amount'), 0), 2);
  if v_amt <= 0 then return jsonb_build_object('ok', false, 'reason', 'no_amount'); end if;
  v_fee := least(greatest(round(coalesce(private.num(d->>'fee'), 0), 2), 0), v_amt);
  select * into w from wallets where id = r.wallet_id;
  -- The money arrived even if the request was cancelled or expired in the meantime: it still belongs to this customer.
  update payment_requests set status = 'paid', paid_amount = v_amt, fee = v_fee, paid_at = coalesce(nullif(d->>'paid_at', '')::timestamptz, now()),
    provider_ref = coalesce(nullif(d->>'provider_ref', ''), provider_ref), payer = d->'payer',
    sweep_status = case when r.rail = 'flutterwave' and w.barter_id is not null and not r.direct then 'pending' else 'not_needed' end
  where id = r.id returning * into r;
  m := (select mm from members mm where mm.id = r.created_by);
  if r.sale_id is not null then
    select * into s from sales where id = r.sale_id for update;
    -- A till sale waiting for this transfer posts now, and takes its stock.
    if s.doc_type = 'receipt' and s.journal_id is null and s.status not in ('cancelled', 'void', 'draft') then
      perform private.post_sale(s.id, coalesce(m, jsonb_populate_record(null::public.members, jsonb_build_object('id', s.created_by))), r.paid_at);
      select * into s from sales where id = s.id;
    end if;
  end if;
  -- Paid short by exactly what the customer was expected to keep back (WHT, the NCD levy, VAT withheld): settled in full.
  if s.id is not null and s.doc_type in ('invoice', 'order') and s.journal_id is not null and s.status in ('open', 'partially_paid') then
    v_due := s.total - s.amount_paid - s.credited - coalesce((select sum(a.amount) from collection_allocations a join collections cc on cc.id = a.collection_id
      where a.sale_id = s.id and cc.status = 'pending'), 0);
    v_split := private.customer_short_split(s.id, v_due, v_amt);
    if v_split is not null then
      perform private.book_customer_withholding(r.org_id, s.customer_id, s.id, v_split, r.paid_at, m);
    end if;
  end if;
  c := private.add_collection(r.org_id, coalesce(r.customer_id, s.customer_id), v_amt, case when r.rail = 'flutterwave' then 'flutterwave' else 'rail' end,
    jsonb_build_object('bank_account_id', w.bank_account_id, 'fee', v_fee, 'provider_ref', coalesce(nullif(d->>'provider_ref', ''), r.tx_ref),
      'reference', r.tx_ref, 'payment_request_id', r.id, 'received_at', r.paid_at, 'shift_id', r.shift_id,
      'note', 'Paid by ' || coalesce(d->'payer'->>'name', 'customer') || coalesce(' from ' || (d->'payer'->>'bank'), ''),
      'spread', case when (s.id is null or s.status in ('void', 'cancelled'))
                      and not (select is_walk_in from customers where id = coalesce(r.customer_id, s.customer_id)) then 'true' else 'false' end),
    null::public.members, 'confirmed',
    case when s.id is not null and s.status not in ('void', 'cancelled') then array[s.id] end);
  -- The rail confirmed it, not a person; the request's author stays on record as who asked for it.
  update collections set created_by = r.created_by where id = c.id;
  update payment_requests set collection_id = c.id where id = r.id returning * into r;
  -- Tell whoever asked for it, and the people who look after money.
  if m.user_id is not null then
    perform private.notify(r.org_id, m.user_id, 'payment', 'Paid ₦' || to_char(v_amt, 'FM999,999,999,990.00') || coalesce(' for ' || s.number, ''),
      coalesce(d->'payer'->>'name', 'Customer') || ' paid by ' || case r.method when 'account' then 'transfer' when 'link' then 'payment link' else 'QR' end,
      case when s.id is not null then '/sell/sales?open=' || s.id else '/sell/customers' end, 'paid-' || r.id);
  end if;
  return jsonb_build_object('ok', true, 'request', private.request_json(r), 'collection', c.number, 'org_id', r.org_id,
    'sweep', case when r.sweep_status = 'pending' then jsonb_build_object('barter_id', w.barter_id, 'amount', v_amt - v_fee, 'reference', 'SWP-' || r.tx_ref) end);
end $function$;

-- Bank lines the books inbox asks about: a candidate invoice shows the levy among what was kept back.
create or replace function private.invoice_candidates(p_org uuid, p_amt numeric, p_text text, p_day date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare r record; v_out jsonb := '[]'::jsonb; v_tol numeric; v_split jsonb; v_basis text; v_wht numeric; v_wvat numeric; v_fee numeric; v_score numeric; v_ncd numeric;
  v_named boolean; v_ns numeric; v_ref boolean; v_items boolean; v_rate numeric; v_reasons text[]; v_cust record; v_sum numeric; v_ids uuid[]; v_nums text[]; s record;
begin
  for r in
    select x.id, x.number, x.subtotal, x.total, x.issue_date, x.due_date, x.customer_id, cu.name cust_name,
      x.total - x.amount_paid - x.credited - coalesce((select sum(a.amount) from collection_allocations a join collections cc on cc.id = a.collection_id
        where a.sale_id = x.id and cc.status = 'pending'), 0) due
    from sales x join customers cu on cu.id = x.customer_id
    where x.org_id = p_org and x.doc_type in ('invoice', 'order', 'receipt') and x.status in ('open', 'partially_paid') and x.journal_id is not null
      and not cu.is_walk_in and x.issue_date between p_day - 400 and p_day + 1
      and ((x.total - x.amount_paid - x.credited) between p_amt - 0.01 and p_amt * 1.25 + 300
           or private.doc_in_text(x.number, p_text) or private.name_match(cu.name, p_text))
  loop
    continue when r.due <= 0.004;
    v_tol := greatest(100, round(r.due * 0.005, 2));
    v_named := private.name_match(r.cust_name, p_text);
    v_ns := private.name_score(r.cust_name, p_text);
    v_ref := private.doc_in_text(r.number, p_text);
    v_items := exists (select 1 from sale_lines l where l.sale_id = r.id and private.words_in(l.description, p_text));
    v_basis := null; v_wht := 0; v_wvat := 0; v_fee := 0; v_ncd := 0;
    if abs(r.due - p_amt) < 0.005 then v_basis := 'exact';
    elsif p_amt < r.due then
      v_split := private.customer_short_split(r.id, r.due, p_amt);
      if v_split is not null then
        v_basis := 'less_wht'; v_wht := (v_split->>'wht')::numeric; v_wvat := coalesce((v_split->>'wvat')::numeric, 0); v_ncd := coalesce((v_split->>'ncd')::numeric, 0);
      elsif r.due - p_amt <= v_tol then
        v_basis := 'bank_charge'; v_fee := round(r.due - p_amt, 2);
      else
        foreach v_rate in array array[0.02, 0.05, 0.10] loop
          v_wht := round(r.subtotal * v_rate, 2);
          if r.due - v_wht - p_amt > 0.004 and r.due - v_wht - p_amt <= v_tol then v_basis := 'less_wht_charge'; v_fee := round(r.due - v_wht - p_amt, 2); exit; end if;
          v_wht := 0;
        end loop;
        if v_basis is null and (v_named or v_ref) then v_basis := 'part'; end if;
      end if;
    elsif v_named or v_ref then
      v_basis := 'over';
    end if;
    continue when v_basis is null;
    v_score := case v_basis when 'exact' then 40 when 'less_wht' then 36 when 'bank_charge' then 30 when 'less_wht_charge' then 28 when 'over' then 12 else 8 end
      + case when v_ref then 50 else 0 end + case when v_named then 30 else round(v_ns * 25) end + case when v_items then 8 else 0 end
      + case when p_day between r.issue_date - 1 and coalesce(r.due_date, r.issue_date) + 60 then 4 else 0 end;
    v_reasons := array_remove(array[
      case when v_ref then r.number || ' is in the narration' end,
      case when v_named then r.cust_name || ' is named' when v_ns > 0 then 'Part of ' || r.cust_name || '''s name is in the narration' end,
      case v_basis when 'exact' then 'Exactly what is owed'
        when 'less_wht' then 'What is owed less ' || array_to_string(array_remove(array[
          case when v_wht > 0 then 'WHT' || coalesce(' at ' || rtrim(rtrim(to_char((v_split->>'wht_rate')::numeric * 100, 'FM990.00'), '0'), '.') || '%', '') end,
          case when v_ncd > 0 then 'the 1% NCD levy' end, case when v_wvat > 0 then 'VAT withheld' end], null), ' and ')
        when 'bank_charge' then 'What is owed less ' || private.naira(v_fee) || ', likely a bank charge'
        when 'less_wht_charge' then 'What is owed less WHT and ' || private.naira(v_fee) || ' in charges'
        when 'over' then 'More than is owed'
        else 'Part of what is owed' end,
      case when v_items then 'The goods or service on it are in the narration' end], null);
    v_out := v_out || jsonb_build_array(jsonb_build_object('kind', 'sale', 'id', r.id, 'number', r.number, 'party_id', r.customer_id, 'party_name', r.cust_name,
      'due', r.due, 'basis', v_basis, 'wht', v_wht, 'wvat', v_wvat, 'ncd', v_ncd, 'fee', v_fee, 'score', v_score, 'reasons', to_jsonb(v_reasons)));
  end loop;
  -- A named customer paying several open invoices at once: the oldest ones adding up to the amount.
  for v_cust in select cu.id, cu.name from customers cu where cu.org_id = p_org and not cu.is_walk_in and not cu.archived and private.name_match(cu.name, p_text)
                order by length(cu.name) desc limit 2 loop
    v_sum := 0; v_ids := '{}'; v_nums := '{}';
    for s in select x.id, x.number, x.total - x.amount_paid - x.credited due from sales x where x.customer_id = v_cust.id and x.status in ('open', 'partially_paid')
             and x.journal_id is not null and x.doc_type in ('invoice', 'order', 'receipt') order by coalesce(x.due_date, x.issue_date), x.created_at limit 8 loop
      v_sum := v_sum + s.due; v_ids := v_ids || s.id; v_nums := v_nums || s.number;
      exit when v_sum >= p_amt - 0.004;
    end loop;
    if cardinality(v_ids) >= 2 and abs(v_sum - p_amt) < 0.005 then
      v_out := v_out || jsonb_build_array(jsonb_build_object('kind', 'sales', 'ids', to_jsonb(v_ids), 'number', array_to_string(v_nums, ', '),
        'party_id', v_cust.id, 'party_name', v_cust.name, 'due', v_sum, 'basis', 'several', 'wht', 0, 'wvat', 0, 'fee', 0, 'score', 85,
        'reasons', jsonb_build_array(v_cust.name || ' is named', 'Exactly what is owed on ' || cardinality(v_ids) || ' invoices')));
    end if;
  end loop;
  return (select coalesce(jsonb_agg(c order by (c->>'score')::numeric desc, c->>'number'), '[]'::jsonb)
          from (select c from jsonb_array_elements(v_out) c order by (c->>'score')::numeric desc, c->>'number' limit 3) z);
end $function$;

-- Customers: whether they deduct the NCD levy, and the WHT rate they deduct.
create or replace function public.save_customer(p_org uuid, p_customer jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; c public.customers; v_country text; v_id uuid; v_agent boolean := (p_customer->>'wvat_agent')::boolean;
  v_ncd boolean := (p_customer->>'ncd_levy')::boolean; v_rate numeric;
begin
  m := private.require(p_org, 'record_sales');
  if nullif(p_customer->>'kind', '') is not null and p_customer->>'kind' not in ('individual', 'business', 'government') then
    raise exception 'Choose whether the customer is a person, a business or a government body.';
  end if;
  if nullif(p_customer->>'id', '') is not null then
    select * into c from customers where id = (p_customer->>'id')::uuid and org_id = p_org;
  end if;
  if p_customer ? 'tin' then
    v_country := coalesce(upper(nullif(trim(p_customer->>'country'), '')), c.country, 'NG');
    p_customer := p_customer || jsonb_build_object('tin', case when v_country = 'NG' then private.tax_id_input(p_customer->>'tin', c.tin, 'The customer''s Tax ID')
      else nullif(left(trim(p_customer->>'tin'), 40), '') end);
  end if;
  if v_agent is not null and v_agent is distinct from coalesce(c.wvat_agent, false)
     and not (private.perm_of(m, 'approve_adjustments') or private.perm_of(m, 'keep_books')) then
    raise exception 'Only a manager, an accountant or the owner marks a customer as a withholding VAT agent.';
  end if;
  if p_customer ? 'wht_rate' then
    v_rate := case when nullif(trim(p_customer->>'wht_rate'), '') is null then null else round((p_customer->>'wht_rate')::numeric, 4) end;
    if v_rate is not null and (v_rate < 0 or v_rate > 0.25) then raise exception 'The WHT rate is between 0%% and 25%%.'; end if;
  end if;
  if ((v_ncd is not null and v_ncd is distinct from coalesce(c.ncd_levy, false)) or (p_customer ? 'wht_rate' and v_rate is distinct from c.wht_rate))
     and not (private.perm_of(m, 'approve_adjustments') or private.perm_of(m, 'keep_books')) then
    raise exception 'Only a manager, an accountant or the owner changes what a customer deducts.';
  end if;
  v_id := private.upsert_customer(p_org, p_customer, m);
  if v_ncd is not null then update customers set ncd_levy = v_ncd where id = v_id; end if;
  if p_customer ? 'wht_rate' then update customers set wht_rate = v_rate where id = v_id; end if;
  if v_agent is not null then update customers set wvat_agent = v_agent where id = v_id; end if;
  if p_customer ? 'lga' then update customers set lga = nullif(trim(p_customer->>'lga'), '') where id = v_id; end if;
  if p_customer ? 'postcode' then update customers set postcode = nullif(trim(p_customer->>'postcode'), '') where id = v_id; end if;
  return v_id;
end $function$;


-- What the customer may keep back from an invoice, and (with p_amount) what a payment of that amount would mean. For the
-- invoice screen and Record a payment; reads only.
create or replace function public.sale_withholding(p_sale uuid, p_amount numeric default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare s public.sales; cu public.customers; m public.members; v_exp jsonb; v_net numeric; v_due numeric; v_split jsonb;
begin
  select * into s from sales where id = p_sale;
  if not found then raise exception 'Sale not found.'; end if;
  m := private.require(s.org_id, null);
  select * into cu from customers where id = s.customer_id;
  v_exp := private.expected_wht(s.id);
  v_net := s.total - s.vat_total;
  v_due := s.total - s.amount_paid - s.credited - coalesce((select sum(a.amount) from collection_allocations a join collections cc on cc.id = a.collection_id
    where a.sale_id = s.id and cc.status = 'pending'), 0);
  if p_amount is not null and s.journal_id is not null and s.doc_type in ('invoice', 'order') then
    v_split := private.customer_short_split(s.id, v_due, round(p_amount, 2));
  end if;
  return jsonb_build_object('sale_id', s.id, 'expected', v_exp, 'wht', round(v_net * coalesce((v_exp->>'rate')::numeric, 0), 2), 'net', v_net,
    'ncd_net', round(v_net * 0.01, 2), 'ncd_gross', round(s.total * 0.01, 2), 'ncd_levy', coalesce(cu.ncd_levy, false),
    'wvat_agent', coalesce(cu.wvat_agent, false), 'vat', s.vat_total, 'due', v_due, 'walk_in', coalesce(cu.is_walk_in, true),
    'customer_rate', cu.wht_rate, 'business', private.org_wht_rate(s.org_id), 'split', v_split,
    'can_change', private.perm_of(m, 'approve_adjustments') or private.perm_of(m, 'keep_books'));
end $$;

-- Sets the WHT rate expected on one invoice (null: back to the customer's or the business's usual rate).
create or replace function public.set_sale_wht_rate(p_sale uuid, p_rate numeric) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; m public.members;
begin
  select * into s from sales where id = p_sale for update;
  if not found then raise exception 'Sale not found.'; end if;
  m := private.require(s.org_id, null);
  if not (private.perm_of(m, 'approve_adjustments') or private.perm_of(m, 'keep_books')) then
    raise exception 'Only a manager, an accountant or the owner changes the WHT expected on an invoice.';
  end if;
  if p_rate is not null and (p_rate < 0 or p_rate > 0.25) then raise exception 'The WHT rate is between 0%% and 25%%.'; end if;
  update sales set wht_rate = round(p_rate, 4) where id = s.id;
  return public.sale_withholding(s.id, null);
end $$;

revoke execute on function private.org_wht_rate(uuid), private.expected_wht(uuid), private.customer_short_split(uuid, numeric, numeric),
  private.book_customer_withholding(uuid, uuid, uuid, jsonb, timestamptz, public.members) from public, anon, authenticated;
revoke execute on function public.sale_withholding(uuid, numeric), public.set_sale_wht_rate(uuid, numeric) from public, anon;
grant execute on function public.sale_withholding(uuid, numeric), public.set_sale_wht_rate(uuid, numeric) to authenticated;
