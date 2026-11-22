-- WHT worked out line by line on what the business sells.
--
-- When a customer pays an invoice short, Counta tried one WHT rate on the whole invoice (the rate expected on it, then
-- none, 2%, 5% and 10%). An invoice whose lines carry different rates (technical services at 5%, nappies at 2%) never
-- matched, so the payment waited in the Books inbox. Each invoice line now has a WHT type: Numens' answer for the line's
-- words (Gemini until Numens is connected), or a person's choice, which is used for those words from then on and which
-- Numens never replaces. The WHT expected on an invoice is worked out line by line at each type's rate for this business
-- (doubled when it has no Tax ID; nothing on types that are not subject to WHT), and a short payment is tried against that
-- amount first, then against the single rates as before. A rate a person set on the invoice still overrides the lines, and
-- a customer who is a person or a walk-in still keeps nothing back.

-- ---------------------------------------------------------------------------
-- 1. What Numens, or a person, decided for the words of a line
-- ---------------------------------------------------------------------------
create table if not exists public.line_wht (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  key text not null check (key <> ''),
  description text not null,
  category text references public.wht_rates(code) on update cascade,
  source text not null default 'gemini' check (source in ('numens', 'gemini', 'person')),
  confidence numeric check (confidence between 0 and 1),
  reason text,
  model text,
  ai jsonb,
  by_name text,
  decided_by uuid references public.members(id) on delete set null,
  tries int not null default 0,
  asked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, key)
);
create index if not exists line_wht_category_fk on public.line_wht(category);
create index if not exists line_wht_decided_by_fk on public.line_wht(decided_by);
alter table public.line_wht enable row level security;
revoke all on public.line_wht from anon, authenticated;
select private.activity_attach('public.line_wht');

alter table public.sale_lines add column if not exists wht_type text references public.wht_rates(code) on update cascade;
alter table public.sale_lines add column if not exists wht_basis jsonb;
create index if not exists sale_lines_wht_type_fk on public.sale_lines(wht_type) where wht_type is not null;
comment on column public.sale_lines.wht_type is
  'The WHT type a person chose for this line (wht_rates.code); null means the one on record for the line''s words (line_wht), if any.';

-- The rate a customer withholds on a type of supply from this business: the corporate or individual column by the
-- business's legal form, doubled when the business has no Tax ID; nothing on a type that is not subject to WHT.
create or replace function private.wht_rate_of(p_org uuid, p_code text) returns numeric
language sql stable security definer set search_path = public, private as $$
  select case when p_code is null then null
    when p_code = 'none' or p_code like 'ex\_%' then 0
    else round(coalesce(case when coalesce(o.legal_form, 'company') in ('enterprise', 'partnership', 'individual') then r.rate_ind_res else r.rate_corp_res end,
      r.rate_company, 0) * case when nullif(trim(o.tin), '') is null then 2 else 1 end, 4) end
  from orgs o left join wht_rates r on r.code = p_code
  where o.id = p_org
$$;

-- The types a line can take, with this business's rate for each (types that are not about selling are left out).
create or replace function private.wht_sale_types(p_org uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', r.code, 'name', r.name, 'rate', private.wht_rate_of(p_org, r.code)) order by r.code like 'ex\_%', r.sort, r.name), '[]'::jsonb)
  from wht_rates r where r.code not in ('none', 'compensation', 'directors_fees', 'winnings', 'entertainment', 'dividend', 'ex_reit', 'ex_securities_lending', 'ex_qualifying_winnings')
$$;

-- ---------------------------------------------------------------------------
-- 2. A sale's lines with their WHT
-- ---------------------------------------------------------------------------
-- Each line with a value: its type (the person's choice on the line, else what is on record for its words), the value WHT
-- is worked out on (the line's share of the invoice before VAT, so an invoice discount or delivery charge is shared out),
-- the same with VAT (some customers work WHT out on that), and the WHT at this business's rate for the type.
create or replace function private.sale_line_wht(p_sale uuid)
returns table (line_id uuid, line_no int, description text, category text, category_name text, source text, confidence numeric, reason text,
  base numeric, base_total numeric, rate numeric, wht numeric, wht_total numeric)
language sql stable security definer set search_path = public, private as $$
  with s as (select * from sales where id = p_sale),
  f as (select case when coalesce(sum(l.net), 0) <> 0 and abs(sum(l.net) - (s.total - s.vat_total)) >= 0.005 then (s.total - s.vat_total) / sum(l.net) else 1 end k,
               case when coalesce(sum(l.gross), 0) <> 0 and abs(sum(l.gross) - s.total) >= 0.005 then s.total / sum(l.gross) else 1 end kt
        from s join sale_lines l on l.sale_id = s.id group by s.total, s.vat_total),
  x as (select l.id, l.line_no, l.description, l.net, l.gross,
          coalesce(l.wht_type, lw.category) cat,
          case when l.wht_type is not null then coalesce(l.wht_basis->>'source', 'person') else lw.source end src,
          case when l.wht_type is not null then (l.wht_basis->>'confidence')::numeric else lw.confidence end conf,
          case when l.wht_type is not null then l.wht_basis->>'reason' else lw.reason end why
        from s join sale_lines l on l.sale_id = s.id
          left join line_wht lw on lw.org_id = s.org_id and lw.key = private.line_vat_key(l.description) and lw.category is not null
        where l.net <> 0)
  select x.id, x.line_no, x.description, x.cat, r.name, x.src, x.conf, x.why, round(x.net * f.k, 2), round(x.gross * f.kt, 2),
    private.wht_rate_of(s.org_id, x.cat),
    case when x.cat is not null then round(round(x.net * f.k, 2) * private.wht_rate_of(s.org_id, x.cat), 2) end,
    case when x.cat is not null then round(round(x.gross * f.kt, 2) * private.wht_rate_of(s.org_id, x.cat), 2) end
  from x cross join f cross join s left join wht_rates r on r.code = x.cat
  order by x.line_no
$$;

-- The WHT expected on a sale. A rate a person set on the invoice wins; a person or a walk-in keeps nothing back; otherwise
-- the lines that have a type are worked out at their own rates and the rest at the customer's usual rate (what they kept
-- last time), else the business's usual rate for its work. amount is on the value before VAT, amount_total on the total
-- with VAT. rate is amount over the value before VAT.
create or replace function private.expected_wht(p_sale uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare s public.sales; cu public.customers; v_net numeric; v_fb jsonb; v_fb_rate numeric; v_lines jsonb; v_typed int; v_missing int; v_amt numeric; v_amt_t numeric;
begin
  select * into s from sales where id = p_sale;
  if s.id is null then return null; end if;
  select * into cu from customers where id = s.customer_id;
  v_net := s.total - s.vat_total;
  if s.wht_rate is not null then
    return jsonb_build_object('rate', s.wht_rate, 'source', 'invoice', 'amount', round(v_net * s.wht_rate, 2), 'amount_total', round(s.total * s.wht_rate, 2));
  end if;
  if cu.id is null or cu.kind = 'individual' or coalesce(cu.is_walk_in, true) then
    return jsonb_build_object('rate', 0, 'source', 'person', 'amount', 0, 'amount_total', 0);
  end if;
  v_fb := case when cu.wht_rate is not null then jsonb_build_object('rate', cu.wht_rate, 'source', 'customer')
               else private.org_wht_rate(s.org_id) || jsonb_build_object('source', 'business') end;
  v_fb_rate := coalesce((v_fb->>'rate')::numeric, 0);
  select coalesce(jsonb_agg(jsonb_build_object('line_id', x.line_id, 'description', x.description, 'category', x.category, 'name', x.category_name,
           'source', x.source, 'confidence', x.confidence, 'reason', x.reason, 'base', x.base, 'rate', coalesce(x.rate, v_fb_rate),
           'wht', coalesce(x.wht, round(x.base * v_fb_rate, 2)), 'typed', x.category is not null) order by x.line_no), '[]'::jsonb),
         count(*) filter (where x.category is not null), count(*) filter (where x.category is null),
         coalesce(sum(coalesce(x.wht, round(x.base * v_fb_rate, 2))), 0), coalesce(sum(coalesce(x.wht_total, round(x.base_total * v_fb_rate, 2))), 0)
    into v_lines, v_typed, v_missing, v_amt, v_amt_t
  from private.sale_line_wht(s.id) x;
  if v_typed > 0 then
    return jsonb_build_object('rate', case when v_net > 0 then round(v_amt / v_net, 4) else 0 end, 'source', 'lines', 'amount', v_amt, 'amount_total', v_amt_t,
      'lines', v_lines, 'missing', v_missing, 'fallback', v_fb);
  end if;
  return v_fb || jsonb_build_object('amount', round(v_net * v_fb_rate, 2), 'amount_total', round(s.total * v_fb_rate, 2), 'lines', v_lines, 'missing', v_missing);
end $$;

-- ---------------------------------------------------------------------------
-- 3. Telling a short payment's parts apart
-- ---------------------------------------------------------------------------
-- As before, with the WHT worked out line by line tried first. Exact first, then within the rounding tolerance; each time
-- on the value before VAT, then on the total with VAT, which some customers use.
create or replace function private.customer_short_split(p_sale uuid, p_due numeric, p_amt numeric) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare s public.sales; cu public.customers; v_vat numeric := 0; v_gap numeric; v_net numeric; v_tol numeric; v_exp jsonb; v_exp_rate numeric;
  v_wht_done numeric; v_ncd_done numeric; v_vat_done numeric; r numeric; v_wb numeric; nb text; v_wv numeric; v_pass int;
  v_wht numeric; v_ncd numeric; v_sum numeric; v_diff numeric; v_rates numeric[]; v_bases numeric[]; v_exact boolean; v_on_total boolean;
  v_by_line boolean; v_cands jsonb; cd jsonb; v_zero boolean;
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
  v_by_line := v_exp->>'source' = 'lines';
  -- The expected rate (or, when the lines set it, the customer's usual rate), none, the usual rates, and the doubled ones
  -- only for a business with no Tax ID.
  v_rates := array[case when v_by_line then cu.wht_rate else v_exp_rate end, 0, 0.02, 0.05, 0.10]
    || case when (select nullif(trim(o.tin), '') is null from orgs o where o.id = s.org_id) then array[0.04, 0.20]::numeric[] else '{}'::numeric[] end;
  for v_pass in 1..4 loop
    v_exact := v_pass in (1, 2);
    v_on_total := v_pass in (2, 4);
    v_cands := '[]'::jsonb;
    -- Line by line, at each line's own rate.
    if v_by_line then
      v_wht := greatest(round(coalesce((v_exp->>case when v_on_total then 'amount_total' else 'amount' end)::numeric, 0), 2) - v_wht_done, 0);
      if v_wht > 0 and (not v_on_total or s.vat_total > 0) then
        v_cands := v_cands || jsonb_build_object('wht', v_wht, 'rate', v_exp_rate, 'base', case when v_on_total then 'by_line_total' else 'by_line' end, 'by_line', true);
      end if;
    end if;
    -- One rate on the whole invoice.
    v_bases := case when not v_on_total then case when s.subtotal > 0 and abs(s.subtotal - v_net) >= 0.005 then array[v_net, s.subtotal] else array[v_net] end
                    when s.vat_total > 0 then array[s.total] else '{}'::numeric[] end;
    v_zero := false;
    foreach r in array (select array_agg(x order by o) from (select distinct on (x) x, o from unnest(v_rates) with ordinality u(x, o)
                        where x is not null order by x, o) z) loop
      continue when v_on_total and r = 0;
      if r = 0 then
        if not v_zero then v_cands := v_cands || jsonb_build_object('wht', 0, 'rate', 0, 'base', 'net'); v_zero := true; end if;
        continue;
      end if;
      foreach v_wb in array v_bases loop
        v_wht := greatest(round(v_wb * r, 2) - v_wht_done, 0);
        continue when v_wht = 0;
        v_cands := v_cands || jsonb_build_object('wht', v_wht, 'rate', r, 'base', case when v_on_total then 'total' when v_wb = v_net then 'net' else 'lines' end);
      end loop;
    end loop;
    for cd in select * from jsonb_array_elements(v_cands) loop
      foreach nb in array case when cu.ncd_levy then array['net', 'gross', 'none'] else array['none', 'net', 'gross'] end loop
        v_ncd := case nb when 'none' then 0 when 'net' then greatest(round(v_net * 0.01, 2) - v_ncd_done, 0)
                 else greatest(round(s.total * 0.01, 2) - v_ncd_done, 0) end;
        continue when nb <> 'none' and v_ncd = 0;
        foreach v_wv in array case when v_vat > 0 then array[v_vat, 0] else array[0::numeric] end loop
          v_wht := (cd->>'wht')::numeric;
          v_sum := v_wht + v_ncd + v_wv;
          continue when v_sum <= 0;
          v_diff := round(v_gap - v_sum, 2);
          if (v_exact and abs(v_diff) < 0.005) or (not v_exact and abs(v_diff) <= v_tol and (v_wht > 0 or v_ncd > 0)) then
            if v_wht > 0 then v_wht := v_wht + v_diff; else v_ncd := v_ncd + v_diff; end if;
            return jsonb_build_object('wht', round(v_wht, 2), 'wht_rate', case when v_wht > 0 then (cd->>'rate')::numeric end, 'wvat', v_wv, 'ncd', round(v_ncd, 2),
              'ncd_base', case when v_ncd > 0 then nb end, 'expected_rate', v_exp_rate,
              'expected', coalesce((cd->>'by_line')::boolean, false) or ((cd->>'rate')::numeric = v_exp_rate and not v_by_line),
              'deducted', v_gap, 'rounding', v_diff,
              'wht_base', case when v_wht > 0 then cd->>'base' end,
              'wht_lines', case when v_wht > 0 and coalesce((cd->>'by_line')::boolean, false) then
                (select jsonb_agg(jsonb_build_object('description', l->>'description', 'name', l->>'name', 'rate', l->'rate', 'base', l->'base', 'wht', l->'wht'))
                 from jsonb_array_elements(v_exp->'lines') l where (l->>'wht')::numeric > 0) end);
          end if;
        end loop;
      end loop;
    end loop;
  end loop;
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- 4. The screens
-- ---------------------------------------------------------------------------
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
  return jsonb_build_object('sale_id', s.id, 'expected', v_exp, 'wht', coalesce((v_exp->>'amount')::numeric, round(v_net * coalesce((v_exp->>'rate')::numeric, 0), 2)), 'net', v_net,
    'lines', coalesce(v_exp->'lines', '[]'::jsonb), 'missing', coalesce((v_exp->>'missing')::int, 0), 'types', private.wht_sale_types(s.org_id),
    'ncd_net', round(v_net * 0.01, 2), 'ncd_gross', round(s.total * 0.01, 2), 'ncd_levy', coalesce(cu.ncd_levy, false),
    'wvat_agent', coalesce(cu.wvat_agent, false), 'vat', s.vat_total, 'due', v_due, 'walk_in', coalesce(cu.is_walk_in, true),
    'customer_rate', cu.wht_rate, 'business', private.org_wht_rate(s.org_id), 'split', v_split,
    'can_change', private.perm_of(m, 'approve_adjustments') or private.perm_of(m, 'keep_books'));
end $$;

-- A person sets the WHT type of one line (null hands it back to Numens). The choice is used for those words from then on,
-- and a rate set on the whole invoice gives way to the lines.
create or replace function public.set_sale_line_wht(p_line uuid, p_category text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.sale_lines; s public.sales; m public.members; v_key text;
begin
  select * into l from sale_lines where id = p_line;
  if not found then raise exception 'Line not found.'; end if;
  select * into s from sales where id = l.sale_id for update;
  m := private.require(s.org_id, null);
  if not (private.perm_of(m, 'approve_adjustments') or private.perm_of(m, 'keep_books')) then
    raise exception 'Only a manager, an accountant or the owner changes the WHT expected on an invoice.';
  end if;
  if s.status in ('void', 'paid', 'credited') then raise exception '% is %; its WHT can no longer change.', s.number, s.status; end if;
  if p_category is not null and not exists (select 1 from wht_rates where code = p_category) then raise exception 'Unknown WHT type.'; end if;
  v_key := private.line_vat_key(l.description);
  if p_category is null then
    update sale_lines set wht_type = null, wht_basis = null where id = l.id;
    delete from line_wht where org_id = s.org_id and key = v_key and source = 'person';
  else
    update sale_lines set wht_type = p_category, wht_basis = jsonb_build_object('source', 'person', 'by', m.display_name, 'at', now()) where id = l.id;
    if v_key <> '' then
      insert into line_wht (org_id, key, description, category, source, confidence, by_name, decided_by)
      values (s.org_id, v_key, left(regexp_replace(trim(l.description), '\s+', ' ', 'g'), 300), p_category, 'person', 1, m.display_name, m.id)
      on conflict (org_id, key) do update set category = excluded.category, source = 'person', confidence = 1, by_name = excluded.by_name,
        decided_by = excluded.decided_by, ai = case when line_wht.source <> 'person' and line_wht.category is not null
          then jsonb_build_object('category', line_wht.category, 'confidence', line_wht.confidence, 'reason', line_wht.reason) else line_wht.ai end,
        updated_at = now();
    end if;
  end if;
  update sales set wht_rate = null where id = s.id and wht_rate is not null;
  return public.sale_withholding(s.id, null);
end $$;

-- For the ai function, under the person's own sign-in: the business and the lines of a sale with no WHT type yet.
create or replace function public.sale_wht_lines(p_sale uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare s public.sales; m public.members; o public.orgs;
begin
  select * into s from sales where id = p_sale;
  if not found then raise exception 'Sale not found.'; end if;
  m := private.require(s.org_id, null);
  select * into o from orgs where id = s.org_id;
  return jsonb_build_object('org_id', s.org_id, 'business', private.wht_business(s.org_id), 'types', private.wht_sale_types(s.org_id),
    'lines', (select coalesce(jsonb_agg(distinct x.description), '[]'::jsonb) from private.sale_line_wht(s.id) x where x.category is null and private.line_vat_key(x.description) <> ''));
end $$;

-- What the model is told about the business.
create or replace function private.wht_business(p_org uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('name', o.name, 'industry', o.industry, 'offering', o.offering, 'activity', o.principal_activity, 'legal_form', o.legal_form,
    'category', (select label from business_categories where id = o.category_id),
    'products', (select coalesce(jsonb_agg(i.name order by i.name), '[]'::jsonb) from (select name from items where org_id = o.id and not archived order by created_at desc limit 30) i))
  from orgs o where o.id = p_org
$$;

-- For the ai function: words of lines on recent invoices to business customers that have no WHT type, by business. Each
-- call counts as a try, so words the model cannot answer are not asked about forever.
create or replace function public.svc_lines_for_wht(p_limit int default 60) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_rows jsonb;
begin
  with cand as (
    select distinct on (l.org_id, private.line_vat_key(l.description)) l.org_id, private.line_vat_key(l.description) k,
      left(regexp_replace(trim(l.description), '\s+', ' ', 'g'), 300) d
    from sale_lines l join sales s on s.id = l.sale_id join customers cu on cu.id = s.customer_id
    where s.doc_type in ('invoice', 'order') and s.status in ('draft', 'open', 'partially_paid') and s.created_at > now() - interval '120 days'
      and cu.kind <> 'individual' and not coalesce(cu.is_walk_in, false) and s.wht_rate is null
      and l.wht_type is null and l.net <> 0 and private.line_vat_key(l.description) <> ''
      and not exists (select 1 from line_wht w where w.org_id = l.org_id and w.key = private.line_vat_key(l.description)
                      and (w.category is not null or w.tries >= 3 or w.asked_at > now() - interval '20 minutes'))
    order by l.org_id, private.line_vat_key(l.description)
    limit least(greatest(coalesce(p_limit, 60), 1), 200)),
  mark as (
    insert into line_wht (org_id, key, description, tries, asked_at)
    select org_id, k, d, 1, now() from cand
    on conflict (org_id, key) do update set tries = line_wht.tries + 1, asked_at = now() where line_wht.category is null
    returning org_id, description)
  select coalesce(jsonb_agg(jsonb_build_object('org_id', g.org_id, 'business', private.wht_business(g.org_id), 'types', private.wht_sale_types(g.org_id),
      'lines', g.lines)), '[]'::jsonb) into v_rows
  from (select org_id, jsonb_agg(description order by description) lines from mark group by org_id) g;
  return v_rows;
end $$;

-- The model's answers for a business: [{description, category, confidence, reason, source, model}]. A person's choice is
-- never replaced. Returns what is on record for those words.
create or replace function public.svc_line_wht_store(p_org uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare x jsonb; v_key text; v_cat text; v_out jsonb := '[]'::jsonb; w public.line_wht;
begin
  for x in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    v_key := private.line_vat_key(x->>'description');
    continue when v_key = '';
    v_cat := nullif(x->>'category', '');
    if v_cat is not null and not exists (select 1 from wht_rates where code = v_cat) then v_cat := null; end if;
    insert into line_wht (org_id, key, description, category, source, confidence, reason, model, tries, asked_at)
    values (p_org, v_key, left(regexp_replace(trim(x->>'description'), '\s+', ' ', 'g'), 300), v_cat, case when x->>'source' = 'numens' then 'numens' else 'gemini' end,
      least(greatest(coalesce(private.num(x->>'confidence'), 0), 0), 1), left(nullif(trim(x->>'reason'), ''), 300), left(x->>'model', 80), 1, now())
    on conflict (org_id, key) do update set category = excluded.category, source = excluded.source, confidence = excluded.confidence, reason = excluded.reason,
      model = excluded.model, updated_at = now()
      where line_wht.source <> 'person' and excluded.category is not null
    returning * into w;
    if w.id is null then select * into w from line_wht where org_id = p_org and key = v_key; end if;
    v_out := v_out || jsonb_build_object('description', w.description, 'category', w.category, 'source', w.source, 'confidence', w.confidence, 'reason', w.reason);
    w := null;
  end loop;
  return v_out;
end $$;

revoke all on function private.wht_rate_of(uuid, text), private.wht_sale_types(uuid), private.sale_line_wht(uuid), private.wht_business(uuid)
  from public, anon, authenticated;
revoke all on function public.set_sale_line_wht(uuid, text), public.sale_wht_lines(uuid), public.svc_lines_for_wht(int), public.svc_line_wht_store(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.set_sale_line_wht(uuid, text), public.sale_wht_lines(uuid) to authenticated;
grant execute on function public.svc_lines_for_wht(int), public.svc_line_wht_store(uuid, jsonb) to service_role;

-- What the customer kept back, booked: worked out line by line, the customer's single usual rate is left alone and the
-- people who keep the books are told each rate.
create or replace function private.book_customer_withholding(p_org uuid, p_customer uuid, p_sale uuid, p_split jsonb, p_at timestamp with time zone, m members)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare v_wht numeric := coalesce((p_split->>'wht')::numeric, 0); v_wvat numeric := coalesce((p_split->>'wvat')::numeric, 0);
  v_ncd numeric := coalesce((p_split->>'ncd')::numeric, 0); v_rate numeric := nullif(p_split->>'wht_rate', '')::numeric;
  cu public.customers; v_num text; v_marked boolean := false; v_kept text[] := '{}'; v_ask text[] := '{}';
  v_on_total boolean := p_split->>'wht_base' in ('total', 'by_line_total'); v_by_line boolean := p_split->>'wht_base' in ('by_line', 'by_line_total');
  v_detail text;
begin
  if v_wvat > 0 then
    perform private.add_collection(p_org, p_customer, v_wvat, 'wvat_credit', jsonb_build_object('reference', 'VAT withheld',
      'received_at', p_at, 'note', 'VAT the customer withholds and pays to the NRS; credited in the VAT return', 'spread', false), m, 'confirmed', array[p_sale]);
  end if;
  if v_wht > 0 then
    perform private.add_collection(p_org, p_customer, v_wht, 'wht_credit', jsonb_build_object('reference', 'WHT deducted',
      'wht_rate', p_split->'wht_rate', 'received_at', p_at, 'note', case when v_on_total then 'Worked out on the total with VAT; collect a WHT credit note for this amount'
        when v_by_line then 'Worked out line by line at each line''s rate; collect the WHT credit note'
        else 'Collect the WHT credit note' end, 'spread', false), m, 'confirmed', array[p_sale]);
  end if;
  if v_ncd > 0 then
    perform private.add_collection(p_org, p_customer, v_ncd, 'ncd_levy', jsonb_build_object('reference', 'NCD levy deducted',
      'received_at', p_at, 'note', 'The 1% Nigerian Content Development levy the customer deducted; ask them for the NCDF remittance receipt', 'spread', false),
      m, 'confirmed', array[p_sale]);
  end if;
  if not (p_split ? 'deducted') then return; end if;
  select * into cu from customers where id = p_customer for update;
  if v_ncd > 0 and not coalesce(cu.ncd_levy, false) then update customers set ncd_levy = true where id = p_customer; v_marked := true; end if;
  if v_wht > 0 and v_rate > 0 and not v_by_line and cu.wht_rate is distinct from v_rate then update customers set wht_rate = v_rate where id = p_customer; end if;
  select number into v_num from sales where id = p_sale;
  -- Worked out line by line: each rate and what it was on.
  if v_by_line then
    select string_agg(rtrim(rtrim(to_char((l->>'rate')::numeric * 100, 'FM990.00'), '0'), '.') || '% on ' || coalesce(l->>'name', l->>'description'), ', ')
      into v_detail from jsonb_array_elements(coalesce(p_split->'wht_lines', '[]'::jsonb)) l;
  end if;
  if v_wht > 0 and v_by_line then
    v_kept := v_kept || (private.naira(v_wht) || ' WHT (' || coalesce(v_detail, 'line by line') || case when v_on_total then ', on the totals with VAT' else '' end || ')');
    v_ask := v_ask || case when v_on_total then 'a WHT credit note for ' || private.naira(v_wht) else 'the WHT credit note' end;
  elsif v_wht > 0 then
    v_kept := v_kept || (private.naira(v_wht) || ' WHT' || coalesce(' (' || rtrim(rtrim(to_char(v_rate * 100, 'FM990.00'), '0'), '.') || '%'
      || case when v_on_total then ' of the total with VAT' else '' end || ')', ''));
    v_ask := v_ask || case when v_on_total then 'a WHT credit note for ' || private.naira(v_wht) else 'the WHT credit note' end;
  end if;
  if v_ncd > 0 then v_kept := v_kept || (private.naira(v_ncd) || ' NCD levy (1%)'); v_ask := v_ask || 'the NCDF receipt'::text; end if;
  if v_wvat > 0 then v_kept := v_kept || (private.naira(v_wvat) || ' VAT withheld'); end if;
  perform private.notify_perm(p_org, 'keep_books', 'payment', coalesce(v_num, 'An invoice') || ' settled in full',
    coalesce(cu.name, 'The customer') || ' kept back ' || array_to_string(v_kept, ' and ') || '.'
      || case when cardinality(v_ask) > 0 then ' Ask them for ' || array_to_string(v_ask, ' and ') || '.' else '' end
      || case when v_marked then ' Counta now expects the levy from them.' else '' end,
    '/sell/sales?open=' || p_sale, 'withheld-' || p_sale, case when p_split ? 'seen' then m.id end);
end $function$;

-- Every three minutes: also the lines waiting for their WHT type.
create or replace function private.vat_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
begin
  if exists (select 1 from items where vat_checked_at is null and not archived and coalesce(vat_basis->>'source', '') <> 'manual') then
    perform private.call_function('ai', jsonb_build_object('action', 'vat_classify_pending'));
  end if;
  if exists (select 1 from sales where channel = 'bank' and vat_source = 'usual' and vat_ai_at is null and vat_ai_tries < 3 and status <> 'void'
             and created_at > now() - interval '60 days') then
    perform private.call_function('ai', jsonb_build_object('action', 'vat_receipts_pending'));
  end if;
  -- Lines on recent invoices to business customers with no WHT type yet.
  if exists (select 1 from sale_lines l join sales s on s.id = l.sale_id join customers cu on cu.id = s.customer_id
             where s.doc_type in ('invoice', 'order') and s.status in ('draft', 'open', 'partially_paid') and s.created_at > now() - interval '120 days'
               and cu.kind <> 'individual' and not coalesce(cu.is_walk_in, false) and s.wht_rate is null and l.wht_type is null and l.net <> 0
               and private.line_vat_key(l.description) <> ''
               and not exists (select 1 from line_wht w where w.org_id = l.org_id and w.key = private.line_vat_key(l.description)
                               and (w.category is not null or w.tries >= 3 or w.asked_at > now() - interval '20 minutes'))) then
    perform private.call_function('ai', jsonb_build_object('action', 'wht_lines_pending'));
  end if;
end $function$;

-- A bank line that pays an invoice less WHT worked out line by line says so, instead of a blended rate.
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
          case when v_wht > 0 and v_split->>'wht_base' like 'by\_line%' then 'WHT line by line (' || private.naira(v_wht) || ')'
               when v_wht > 0 then 'WHT' || coalesce(' at ' || rtrim(rtrim(to_char((v_split->>'wht_rate')::numeric * 100, 'FM990.00'), '0'), '.') || '%', '') end,
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

-- The customer's page never shows what the business expects them to keep back.
create or replace function public.public_document(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare s public.sales; v jsonb; d public.deliveries;
begin
  if p_token is null or length(p_token) < 24 then raise exception 'Document not found.'; end if;
  select * into s from sales where public_token = p_token;
  if not found or s.status = 'draft' then raise exception 'Document not found.'; end if;
  if exists (select 1 from einvoice_docs e where e.sale_id = s.id and e.kind = 'clear' and e.state <> 'signed') then
    raise exception 'This document is waiting for NRS to sign it. Open the link again in a few minutes.';
  end if;
  if s.viewed_at is null then update sales set viewed_at = now() where id = s.id; end if;
  v := private.sale_json(s.id, false);
  select * into d from deliveries where sale_id = s.id and status <> 'cancelled' order by created_at desc limit 1;
  return (v - 'created_by' - 'voided_by' - 'shift_id' - 'device_id' - 'client_uuid' - 'journal_id' - 'journal_ref' - 'org_id' - 'cost_total' - 'location_id'
    - 'price_list_id' - 'created_by_name' - 'deliveries' - 'refunds' - 'void_reason' - 'offline' - 'customer_credit' - 'export_note' - 'einvoice'
    - 'approvals' - 'vat_relief_by' - 'relief_by_name')
    || jsonb_build_object(
      'lines', (select coalesce(jsonb_agg(l - 'cost' - 'item_id' - 'revenue_account' - 'list_price' - 'original_line_id' - 'returned_qty' - 'sale_id' - 'id'
          - 'vat_basis' - 'wht_type' - 'wht_basis'
          order by (l->>'line_no')::int), '[]'::jsonb) from jsonb_array_elements(v->'lines') l),
      'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', p->>'method', 'amount', p->'amount', 'status', p->>'status', 'received_at', p->'received_at')), '[]'::jsonb)
        from jsonb_array_elements(v->'payments') p where p->>'status' in ('confirmed', 'pending')),
      'requests', (select coalesce(jsonb_agg(r - 'id'), '[]'::jsonb) from jsonb_array_elements(v->'requests') r where r->>'status' = 'pending'),
      'shop_slug', (select shop_slug from orgs where id = s.org_id and shop_enabled),
      'einvoice', case when v->'einvoice' is not null and v->'einvoice'->>'state' in ('waiting', 'sending', 'signed') and v->'einvoice'->>'irn' is not null then
        jsonb_build_object('irn', v->'einvoice'->>'irn', 'qr', v->'einvoice'->>'qr', 'signed', v->'einvoice'->>'state' = 'signed',
          'kind', v->'einvoice'->>'kind', 'state', v->'einvoice'->>'state') end,
      'tracking', case when s.doc_type = 'order' then jsonb_build_object(
        'placed_at', s.created_at, 'confirmed', s.journal_id is not null, 'confirmed_at', s.issued_at, 'method', s.delivery_method,
        'cancelled', s.status in ('cancelled', 'void'),
        'delivery_status', d.status, 'scheduled_for', d.scheduled_for, 'dispatched_at', d.dispatched_at, 'delivered_at', d.delivered_at,
        'pickup_address', case when s.delivery_method = 'pickup' then (select coalesce(nullif(l.address, ''), o.address) from locations l join orgs o on o.id = l.org_id where l.id = s.location_id) end)
      end);
end $function$;
