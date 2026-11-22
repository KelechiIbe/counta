-- Output VAT on payment basis.
--
-- A business's output VAT now falls in the month its customers pay, by each payment's share of the invoice, instead of
-- the month the invoice is dated. Input VAT already followed payment (a bill's VAT is claimed when it is paid in full), and
-- the VAT set aside in the tax wallet already moved with each payment. Each business has a basis, payment or invoice; the
-- owner or the business's accountant can switch it, and a switch takes effect from the month after the last return filed,
-- so filed months never change. An invoice follows the basis in force in the month it is dated.
--
-- What settles an invoice: every confirmed payment allocated to it (cash, card, transfer, wallet, and what the customer
-- kept back: WHT, the NCD levy and VAT withheld) and credit notes allocated to it. Each part is dated by when the money came
-- (never before the invoice). By the end of a month an invoice is settled by a share of its total, capped at all of it, and
-- each line's value and VAT are taken in that share: what falls in a month is the share at its end less the share at the
-- end of the month before. Credit notes keep their own month, so a credit note on an unpaid invoice nets to nothing in its
-- month and the rest of the invoice's VAT follows the money. VAT a customer withheld is declared and credited in the month
-- it was withheld, as before.
--
-- The VAT return also says how many of the month's bank lines are still waiting in the Books inbox, since a line that is
-- not in the books cannot reach the return.

-- ---------------------------------------------------------------------------
-- 1. The basis, and when it changed
-- ---------------------------------------------------------------------------
create table if not exists public.vat_basis_changes (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  basis text not null check (basis in ('payment', 'invoice')),
  from_month date not null check (from_month = date_trunc('month', from_month)::date),
  changed_by uuid references public.members(id) on delete set null,
  changed_by_name text,
  changed_at timestamptz not null default clock_timestamp()
);
create index if not exists vat_basis_changes_org on public.vat_basis_changes(org_id, from_month desc, changed_at desc);
create index if not exists vat_basis_changes_changed_by_fk on public.vat_basis_changes(changed_by);
alter table public.vat_basis_changes enable row level security;
drop policy if exists vat_basis_changes_read on public.vat_basis_changes;
create policy vat_basis_changes_read on public.vat_basis_changes for select to authenticated using ((select private.can_handle_money(org_id)));
revoke insert, update, delete on public.vat_basis_changes from anon, authenticated;
revoke all on public.vat_basis_changes from anon;
select private.activity_attach('public.vat_basis_changes');

-- Businesses that filed returns keep the invoice basis for the months up to the last one filed; payment basis starts the
-- month after. A business with nothing filed is on payment basis from the start.
do $$
begin
  insert into public.vat_basis_changes (org_id, basis, from_month, changed_by_name)
  select vp.org_id, 'invoice', date '2000-01-01', 'Counta' from public.vat_periods vp
  where not exists (select 1 from public.vat_basis_changes c where c.org_id = vp.org_id) group by vp.org_id;
  insert into public.vat_basis_changes (org_id, basis, from_month, changed_by_name)
  select vp.org_id, 'payment', (max(vp.period) + interval '1 month')::date, 'Counta' from public.vat_periods vp
  where not exists (select 1 from public.vat_basis_changes c where c.org_id = vp.org_id and c.basis = 'payment') group by vp.org_id;
end $$;

-- The basis for invoices dated on a day: the latest change that started on or before it, else payment.
create or replace function private.vat_basis_on(p_org uuid, p_day date) returns text
language sql stable security definer set search_path = public, private as $$
  select coalesce((select basis from vat_basis_changes where org_id = p_org and from_month <= p_day order by from_month desc, changed_at desc limit 1), 'payment')
$$;

-- ---------------------------------------------------------------------------
-- 2. What of each sale falls in a period
-- ---------------------------------------------------------------------------
-- What settled a sale and when: each confirmed payment allocated to it (dated by when the money came) and each credit note
-- allocated to it (dated by the credit note), never before the sale's own date; anything else the sale counts as paid (a
-- sale recorded as paid when it was made, from a sales schedule, the bank or a POS terminal) on the sale's date.
create or replace function private.sale_settlements(p_sale uuid)
returns table (day date, amount numeric)
language sql stable security definer set search_path = public, private as $$
  with s as (select * from sales where id = p_sale),
  x as (select greatest(private.local_day(c.org_id, c.received_at), s.issue_date) d, a.amount
        from s join collection_allocations a on a.sale_id = s.id join collections c on c.id = a.collection_id
        where c.status = 'confirmed'
        union all
        select greatest(coalesce(cn.issue_date, private.local_day(ca.org_id, ca.created_at)), s.issue_date), ca.amount
        from s join credit_allocations ca on ca.sale_id = s.id left join sales cn on cn.id = ca.credit_note_id)
  select d, amount from x
  union all
  select s.issue_date, greatest(coalesce(s.amount_paid, 0) + coalesce(s.credited, 0) - coalesce((select sum(amount) from x), 0), 0) from s
  where coalesce(s.amount_paid, 0) + coalesce(s.credited, 0) - coalesce((select sum(amount) from x), 0) > 0.004
$$;

-- The day a sale became settled in full (null while it is not).
create or replace function private.sale_settled_day(p_sale uuid, p_total numeric) returns date
language sql stable security definer set search_path = public, private as $$
  select coalesce(min(d) filter (where cum >= p_total - 0.004), max(d))
  from (select d, sum(amount) over (order by d) cum from (select day d, sum(amount) amount from private.sale_settlements(p_sale) group by 1) y) z
$$;

alter table public.sales add column if not exists settled_on date;
comment on column public.sales.settled_on is
  'The day the sale became settled in full by payments, what the customer kept back and credit notes (never before the sale''s own date); null while it is not. Kept by a trigger; output VAT on payment basis reads it to skip sales settled before a period.';

create or replace function private.sales_settled_on() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.status not in ('paid', 'credited') then
    new.settled_on := null;
  elsif tg_op = 'INSERT' then
    new.settled_on := new.issue_date;
  elsif old.status is distinct from new.status or old.amount_paid is distinct from new.amount_paid or old.credited is distinct from new.credited
     or old.issue_date is distinct from new.issue_date or old.total is distinct from new.total or new.settled_on is null then
    new.settled_on := greatest(coalesce(private.sale_settled_day(new.id, new.total), new.issue_date), new.issue_date);
  end if;
  return new;
end $$;
drop trigger if exists sales_settled_on on public.sales;
create trigger sales_settled_on before insert or update of status, amount_paid, credited, issue_date, total on public.sales
  for each row execute function private.sales_settled_on();

-- Sales already settled.
update public.sales s set settled_on = greatest(coalesce(private.sale_settled_day(s.id, s.total), s.issue_date), s.issue_date)
where s.status in ('paid', 'credited') and s.settled_on is null;

-- For every sale line with something in [p_from, p_to]: its value and VAT in that period (positive, credit notes too;
-- callers give credit notes their sign). An invoice on payment basis contributes its settled share; anything else falls
-- whole in the month it is dated.
create or replace function private.vat_sale_parts(p_org uuid, p_from date, p_to date)
returns table (sale_id uuid, line_id uuid, net numeric, vat numeric)
language sql stable security definer set search_path = public, private as $$
  with s as (
    select s.id, s.issue_date, s.total, s.settled_on,
      s.doc_type <> 'credit_note' and s.total > 0 and private.vat_basis_on(s.org_id, s.issue_date) = 'payment' as pay
    from sales s
    where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import' and s.issue_date <= p_to
      and (s.issue_date >= p_from
        or (s.doc_type <> 'credit_note' and s.total > 0 and (s.settled_on is null or s.settled_on >= p_from)
            and private.vat_basis_on(s.org_id, s.issue_date) = 'payment'))),
  st as (
    select s.id,
      case when not s.pay then case when s.issue_date < p_from then 1 else 0 end
           when s.issue_date >= p_from then 0
           when s.settled_on < p_from then 1
           else least(1, coalesce(g.before, 0) / s.total) end f0,
      case when not s.pay then 1
           when s.settled_on <= p_to then 1
           else least(1, coalesce(g.upto, 0) / s.total) end f1
    from s left join lateral (
      select sum(x.amount) filter (where x.day < p_from) before, sum(x.amount) filter (where x.day <= p_to) upto
      from private.sale_settlements(s.id) x) g
      on s.pay and (s.settled_on is null or s.settled_on > p_to or (s.issue_date < p_from and s.settled_on >= p_from)))
  select l.sale_id, l.id, round(l.net * st.f1, 2) - round(l.net * st.f0, 2), round(l.vat * st.f1, 2) - round(l.vat * st.f0, 2)
  from st join sale_lines l on l.sale_id = st.id
  where st.f1 > st.f0
$$;

-- A sale's output VAT by the month it falls in, and what still waits for payment.
create or replace function private.sale_vat_months(p_sale uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare s public.sales; v_basis text; v_months jsonb := '[]'::jsonb; v_done numeric := 0; mth date; f0 numeric := 0; f1 numeric; v_vat numeric; v_net numeric;
begin
  select * into s from sales where id = p_sale;
  if s.id is null or s.journal_id is null or s.status = 'void' or s.doc_type = 'credit_note' or s.channel = 'import' then return null; end if;
  v_basis := private.vat_basis_on(s.org_id, s.issue_date);
  if v_basis = 'invoice' or coalesce(s.total, 0) <= 0 then
    return jsonb_build_object('basis', v_basis, 'vat', s.vat_total, 'months', jsonb_build_array(jsonb_build_object('month', date_trunc('month', s.issue_date)::date,
      'vat', s.vat_total, 'net', s.total - s.vat_total)), 'waiting', 0);
  end if;
  for mth in select distinct date_trunc('month', day)::date from private.sale_settlements(s.id) order by 1 loop
    f1 := least(1, coalesce((select sum(amount) from private.sale_settlements(s.id) where day < (mth + interval '1 month')::date), 0) / s.total);
    select coalesce(sum(round(l.vat * f1, 2) - round(l.vat * f0, 2)), 0), coalesce(sum(round(l.net * f1, 2) - round(l.net * f0, 2)), 0) into v_vat, v_net
    from sale_lines l where l.sale_id = s.id;
    if f1 > f0 then
      v_months := v_months || jsonb_build_object('month', mth, 'vat', v_vat, 'net', v_net);
      v_done := v_done + v_vat;
    end if;
    f0 := f1;
  end loop;
  return jsonb_build_object('basis', v_basis, 'vat', s.vat_total, 'months', v_months, 'waiting', round(s.vat_total - v_done, 2));
end $$;

-- Output VAT on payment-basis sales still waiting for their customers to pay (as at today).
create or replace function private.vat_output_waiting(p_org uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('vat', coalesce(sum(round(s.vat_total * (1 - least(1, (s.amount_paid + s.credited) / s.total)), 2)), 0), 'sales', count(*))
  from sales s
  where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import' and s.doc_type <> 'credit_note'
    and s.vat_total > 0 and s.total > 0 and s.amount_paid + s.credited < s.total - 0.004
    and private.vat_basis_on(s.org_id, s.issue_date) = 'payment'
$$;

-- Bank lines dated in a month that are not in the books yet (in the Books inbox, or not looked at).
create or replace function private.vat_bank_waiting(p_org uuid, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('lines', count(*), 'money_in', coalesce(sum(l.amount) filter (where l.amount > 0), 0),
    'money_out', coalesce(-sum(l.amount) filter (where l.amount < 0), 0), 'in_lines', count(*) filter (where l.amount > 0))
  from bank_lines l join bank_accounts ba on ba.id = l.bank_account_id
  where l.org_id = p_org and l.status in ('unmatched', 'proposed') and l.line_date between p_from and p_to
    and not exists (select 1 from tax_wallets t where t.bank_account_id = ba.id)
$$;

-- What the screens show about the basis.
create or replace function private.vat_basis_json(p_org uuid, m public.members) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object(
    'current', private.vat_basis_on(p_org, date '9999-12-01'),
    'from', (select from_month from vat_basis_changes where org_id = p_org order by from_month desc, changed_at desc limit 1),
    'changes', (select coalesce(jsonb_agg(jsonb_build_object('basis', basis, 'from', from_month, 'by', coalesce(changed_by_name, 'Counta'), 'at', changed_at)
        order by changed_at desc), '[]'::jsonb) from (select * from vat_basis_changes where org_id = p_org order by changed_at desc limit 10) c),
    'next_from', coalesce((select (max(period) + interval '1 month')::date from vat_periods where org_id = p_org), null),
    'waiting', private.vat_output_waiting(p_org),
    'can_change', m.id is not null and (m.role = 'owner' or m.acts_as_owner or (m.role = 'accountant' and private.perm_of(m, 'file_tax'))))
$$;

-- The owner or the business's accountant switches the basis. It applies from the month after the last return filed (from
-- the start, when nothing is filed), to invoices dated from then on.
create or replace function public.set_vat_basis(p_org uuid, p_basis text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_from date;
begin
  m := private.require(p_org, null);
  if not (m.role = 'owner' or m.acts_as_owner or (m.role = 'accountant' and private.perm_of(m, 'file_tax'))) then
    raise exception 'Only the owner or the business''s accountant can change when output VAT falls due.' using errcode = '42501';
  end if;
  if p_basis is null or p_basis not in ('payment', 'invoice') then raise exception 'Choose payment or invoice.'; end if;
  if (select read_only_at is not null from orgs where id = p_org) then raise exception 'This business is read-only.'; end if;
  v_from := coalesce((select (max(period) + interval '1 month')::date from vat_periods where org_id = p_org), date '2000-01-01');
  if private.vat_basis_on(p_org, v_from) <> p_basis or exists (select 1 from vat_basis_changes where org_id = p_org and from_month > v_from) then
    insert into vat_basis_changes (org_id, basis, from_month, changed_by, changed_by_name) values (p_org, p_basis, v_from, m.id, m.display_name);
  end if;
  return private.vat_basis_json(p_org, m);
end $$;

-- A sale's VAT months for its page.
create or replace function public.sale_vat_months(p_sale uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare s public.sales; m public.members;
begin
  select * into s from sales where id = p_sale;
  if s.id is null then raise exception 'Sale not found.'; end if;
  m := private.require(s.org_id, null);
  return private.sale_vat_months(p_sale);
end $$;

revoke all on function private.vat_basis_on(uuid, date), private.sale_settlements(uuid), private.sale_settled_day(uuid, numeric), private.sales_settled_on(),
  private.vat_sale_parts(uuid, date, date), private.sale_vat_months(uuid),
  private.vat_output_waiting(uuid), private.vat_bank_waiting(uuid, date, date), private.vat_basis_json(uuid, public.members) from public, anon, authenticated;
revoke all on function public.set_vat_basis(uuid, text), public.sale_vat_months(uuid) from public, anon;
grant execute on function public.set_vat_basis(uuid, text), public.sale_vat_months(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. The month, the summary rows, the NRS return and the position read it
-- ---------------------------------------------------------------------------

create or replace function private.vat_month(p_org uuid, p_month date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  with b as (select date_trunc('month', p_month)::date f, (date_trunc('month', p_month) + interval '1 month' - interval '1 day')::date t),
  -- Output VAT: what of each sale falls in the month (its settled share on payment basis, else all of it in its own month).
  so as (select coalesce(sum(case when s.doc_type = 'credit_note' then -p.vat else p.vat end), 0) vat,
                coalesce(sum(case when s.doc_type = 'credit_note' then -p.net else p.net end) filter (where l.vat_treatment = 'standard'), 0) std,
                coalesce(sum(case when s.doc_type = 'credit_note' then -p.net else p.net end) filter (where l.vat_treatment = 'zero'), 0) zero,
                coalesce(sum(case when s.doc_type = 'credit_note' then -p.net else p.net end) filter (where l.vat_treatment = 'exempt'), 0) exempt
         from b cross join lateral private.vat_sale_parts(p_org, b.f, b.t) p join sales s on s.id = p.sale_id join sale_lines l on l.id = p.line_id),
  cut as (select vat_claim_on_payment_from d from orgs where id = p_org),
  -- A bill's VAT is claimed in the month it is paid in full (never before the invoice's month); VAT self-charged on services from
  -- abroad stays in the bill's month, beside the self-charge itself.
  bi as (select coalesce(sum(l.vat) filter (where l.vat_recoverable and private.vat_claim_day(x.bill_date, x.status = 'paid', x.paid_in_full_on, cut.d) between b.f and b.t), 0) vat,
                coalesce(sum(l.reverse_charge_vat) filter (where l.vat_recoverable and x.bill_date between b.f and b.t), 0) rc
         from bills x join bill_lines l on l.bill_id = x.id, b, cut
         where x.org_id = p_org and x.source not in ('receipt', 'import') and x.journal_id is not null and x.status <> 'void' and x.bill_date <= b.t
           and (x.bill_date >= b.f or x.paid_in_full_on >= b.f)),
  rc as (select coalesce(sum(r.input_vat), 0) vat from receipts r left join bills rb on rb.receipt_id = r.id and rb.source = 'receipt', b, cut
         where r.org_id = p_org and r.status = 'posted' and r.input_vat <> 0
           and private.vat_claim_day(private.local_day(r.org_id, coalesce(r.posted_at, r.created_at)), coalesce(rb.status = 'paid', true), rb.paid_in_full_on, cut.d) between b.f and b.t),
  vc as (select coalesce(sum(vat_total), 0) vat from vendor_credits, b where org_id = p_org and status <> 'void' and journal_id is not null and credit_date between b.f and b.t),
  wv as (select coalesce(sum(amount), 0) vat from collections, b where org_id = p_org and method = 'wvat_credit' and status = 'confirmed' and journal_id is not null
           and private.local_day(org_id, received_at) between b.f and b.t),
  im as (select coalesce(sum(import_vat), 0) vat from customs_entries, b where org_id = p_org and status = 'posted' and entry_date between b.f and b.t),
  wo as (select coalesce(round(sum(x.cost) * private.vat_rate(max(b.t)), 2), 0) vat from b, private.vat_stock_writeoffs(p_org, b.f, b.t) x)
  select jsonb_build_object('period', b.f, 'output', round(so.vat, 2), 'input', round(bi.vat + bi.rc + rc.vat - vc.vat + im.vat - wo.vat, 2), 'reverse_charge', round(bi.rc, 2),
    'import_vat', round(im.vat, 2), 'stock_writeoff_vat', wo.vat,
    'wvat_credit', round(wv.vat, 2), 'standard_sales', so.std, 'zero_rated_sales', so.zero, 'exempt_sales', so.exempt)
  from b, so, bi, rc, vc, wv, im, wo
$function$;

create or replace function private.vat_rows(p_org uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  -- Output VAT: what of each sale falls in the period (its settled share on payment basis, else all of it in its own month).
  with sl as (select s.doc_type, s.export, l.vat_treatment, p.net, p.vat
              from private.vat_sale_parts(p_org, p_from, p_to) p join sales s on s.id = p.sale_id join sale_lines l on l.id = p.line_id),
  -- Output VAT booked on sales dated in the period, for the ledger check.
  bk as (select coalesce(sum(case when s.doc_type = 'credit_note' then -l.vat else l.vat end), 0) vat from sales s join sale_lines l on l.sale_id = s.id
         where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import' and s.issue_date between p_from and p_to),
  so as (select coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'standard'), 0) std,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'zero'), 0) zero,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'zero' and export), 0) exports,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'exempt'), 0) exempt,
                coalesce(sum(case when doc_type = 'credit_note' then -vat else vat end), 0) vat from sl),
  cut as (select vat_claim_on_payment_from d from orgs where id = p_org),
  -- Bills: claimed in the period they are paid in full (never before the invoice), and, for the ledger check, as recorded.
  bl0 as (select bl.vat, bl.net, bl.vat_recoverable, bl.reverse_charge_vat, b.bill_date between p_from and p_to booked,
                 private.vat_claim_day(b.bill_date, b.status = 'paid', b.paid_in_full_on, cut.d) between p_from and p_to claimed
          from bills b join bill_lines bl on bl.bill_id = b.id, cut
          where b.org_id = p_org and b.source not in ('receipt', 'import') and b.journal_id is not null and b.status <> 'void' and b.bill_date <= p_to
            and (b.bill_date >= p_from or b.paid_in_full_on >= p_from)),
  bi as (select coalesce(sum(vat) filter (where vat_recoverable and claimed), 0) vat, coalesce(sum(net) filter (where vat > 0 and claimed), 0) base,
                coalesce(sum(reverse_charge_vat) filter (where vat_recoverable and booked), 0) rc, coalesce(sum(net) filter (where reverse_charge_vat > 0 and booked), 0) rc_base,
                coalesce(sum(vat) filter (where vat_recoverable and booked), 0) - coalesce(sum(vat) filter (where vat_recoverable and claimed), 0) timing
         from bl0),
  rc0 as (select r.input_vat, r.net, private.local_day(r.org_id, coalesce(r.posted_at, r.created_at)) between p_from and p_to booked,
                 private.vat_claim_day(private.local_day(r.org_id, coalesce(r.posted_at, r.created_at)), coalesce(rb.status = 'paid', true), rb.paid_in_full_on, cut.d)
                   between p_from and p_to claimed
          from receipts r left join bills rb on rb.receipt_id = r.id and rb.source = 'receipt', cut
          where r.org_id = p_org and r.status = 'posted' and r.input_vat <> 0),
  rc as (select coalesce(sum(input_vat) filter (where claimed), 0) vat, coalesce(sum(net) filter (where input_vat > 0 and claimed), 0) base,
                coalesce(sum(input_vat) filter (where booked), 0) - coalesce(sum(input_vat) filter (where claimed), 0) timing from rc0),
  vcr as (select coalesce(sum(vat_total), 0) vat, coalesce(sum(subtotal) filter (where vat_total > 0), 0) base from vendor_credits
          where org_id = p_org and status <> 'void' and journal_id is not null and credit_date between p_from and p_to),
  wv as (select coalesce(sum(amount), 0) vat from collections where org_id = p_org and method = 'wvat_credit' and status = 'confirmed' and journal_id is not null
           and private.local_day(org_id, received_at) between p_from and p_to),
  im as (select coalesce(sum(import_vat), 0) vat, coalesce(sum(vat_base), 0) base from customs_entries
         where org_id = p_org and status = 'posted' and entry_date between p_from and p_to),
  wo as (select coalesce(round(sum(cost) * private.vat_rate(p_to), 2), 0) vat, coalesce(sum(cost), 0) base from private.vat_stock_writeoffs(p_org, p_from, p_to)),
  led as (select coalesce(sum(mv.cr - mv.dr) filter (where mv.code = '2201'), 0) out_ledger, coalesce(sum(mv.dr - mv.cr) filter (where mv.code = '1402'), 0) in_ledger
          from (select l.account_code code, sum(l.debit) dr, sum(l.credit) cr from journal_lines l join journals j on j.id = l.journal_id
                where l.org_id = p_org and j.entry_date between p_from and p_to and j.source_type in ('sale', 'bill', 'receipt', 'customs_entry') group by 1) mv)
  select jsonb_build_array(
    private.fr('Output VAT', null, null, 'heading', 0),
    private.fr('Standard-rated supplies, status 0 (7.5%)', so.std, null, 'line', 1),
    private.fr('Exempt supplies, status 1', so.exempt, null, 'line', 1),
    private.fr('Zero-rated supplies, status 2', so.zero, null, 'line', 1),
    private.fr('of which exports to customers outside Nigeria', so.exports, null, 'line', 2),
    private.fr('Output VAT for the period', so.vat, null, 'subtotal', 0),
    private.fr('Input VAT', null, null, 'heading', 0),
    private.fr('Purchases and expenses on bills (taxable value ' || to_char(bi.base, 'FM999,999,999,990.00') || ')', bi.vat, null, 'line', 1),
    private.fr('VAT self-charged on services from abroad (value ' || to_char(bi.rc_base, 'FM999,999,999,990.00') || ')', bi.rc, null, 'line', 1),
    private.fr('Stock received (taxable value ' || to_char(rc.base, 'FM999,999,999,990.00') || ')', rc.vat, null, 'line', 1),
    private.fr('VAT paid at customs on imports (value ' || to_char(im.base, 'FM999,999,999,990.00') || ')', im.vat, null, 'line', 1),
    private.fr('Less credit notes from suppliers (taxable value ' || to_char(vcr.base, 'FM999,999,999,990.00') || ')', -vcr.vat, null, 'line', 1),
    private.fr('Less VAT on standard-rated stock written off (cost ' || to_char(wo.base, 'FM999,999,999,990.00') || ')', -wo.vat, null, 'line', 1),
    private.fr('Input VAT recoverable', bi.vat + bi.rc + rc.vat + im.vat - vcr.vat - wo.vat, null, 'subtotal', 0),
    private.fr('VAT withheld by customers (credited)', wv.vat, null, 'line', 0),
    private.fr('VAT payable / (credit) for the period, before credit brought forward', so.vat - bi.vat - bi.rc - rc.vat - im.vat + vcr.vat + wo.vat - wv.vat, null, 'total', 0),
    private.fr('Ledger check', null, null, 'heading', 0),
    private.fr('Output VAT in the ledger (2201) from sales', led.out_ledger, null, 'line', 1),
    private.fr('Less output VAT on sales dated in the period and not yet paid, net of earlier sales paid in it', -(bk.vat - so.vat), null, 'line', 1),
    private.fr('Input VAT in the ledger (1402) from bills, receipts, customs and supplier credit notes', led.in_ledger, null, 'line', 1),
    private.fr('Less VAT on bills recorded in the period and not yet paid in full, net of earlier bills paid in full in it', -(bi.timing + rc.timing), null, 'line', 1),
    private.fr('Difference to explain', (so.vat - (led.out_ledger - (bk.vat - so.vat))) - (bi.vat + bi.rc + rc.vat + im.vat - vcr.vat - (led.in_ledger - bi.timing - rc.timing)), null, 'subtotal', 0,
      case when wo.vat <> 0 then 'The VAT on stock written off leaves 1402 when the month is filed.' end))
  from so, bk, bi, rc, vcr, wv, im, wo, led
$function$;

create or replace function private.vat_schedule(p_org uuid, p_period date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare v_f date := date_trunc('month', p_period)::date; v_t date := (date_trunc('month', p_period) + interval '1 month' - interval '1 day')::date;
  v_vr numeric := private.vat_rate((date_trunc('month', p_period) + interval '1 month' - interval '1 day')::date);
  o public.orgs; mn public.locations; a jsonb; b jsonb; c2 jsonb; c2v jsonb; c1 jsonb; d jsonb; e jsonb; f jsonb; checks jsonb := '[]'::jsonb;
  mo jsonb; vp public.vat_periods; v_zs numeric; v_std numeric; v_zero numeric; l jsonb; v_tol numeric; v_lines int; v_net numeric; v_place_state text;
  v_e_place text; v_today date := private.local_day(p_org, now()); rw record; v_wgap numeric; v_bw jsonb; v_wait record;
begin
  select * into o from orgs where id = p_org;
  select * into mn from locations where org_id = p_org order by is_main desc, created_at limit 1;
  mo := private.vat_month(p_org, v_f);
  select * into vp from vat_periods where org_id = p_org and period = v_f;
  v_std := (mo->>'standard_sales')::numeric; v_zero := (mo->>'zero_rated_sales')::numeric;
  v_zs := case when v_std + v_zero > 0 then round(greatest(v_zero, 0) / (v_std + v_zero), 6) else 0 end;

  -- ---- A: every sale line (standard credit notes go to B), by customer, product, VAT status, description and place ----
  create temp table if not exists vat_a_lines (line_id uuid, item_id uuid, description text, treatment text, label text, cust_key text, cname text, ctin text,
    product text, cat int, st text, lga text, place_from text, branch_id uuid, branch_name text, customer_id uuid, c_state text, c_lga text, amount numeric) on commit drop;
  truncate vat_a_lines;
  insert into vat_a_lines
  select l.id, coalesce(l.item_id, ol.item_id), coalesce(ol.description, l.description), l.vat_treatment,
    case when l.vat_treatment = 'standard' then null
      when l.vat_treatment = 'zero' and s.export then case when coalesce(ol.kind, l.kind) = 'service' or i.item_type = 'service' then 'Exported services' else 'Exported goods excluding oil and gas' end
      -- The description chosen for the line or the product, else the one its words point to (TaxStreem sign-off N-3: Counta
      -- applies it without asking).
      else coalesce(l.nrs_vat_label, ol.nrs_vat_label, i.nrs_vat_label,
        private.nrs_label_guess(l.vat_treatment, concat_ws(' ', i.name, i.category, coalesce(ol.description, l.description)))) end,
    case when w.walk_in then 'walkin:' || coalesce(s.location_id, mn.id)::text else 'c:' || coalesce(s.customer_id::text, lower(coalesce(s.customer_name, ''))) end,
    case when w.walk_in then 'Walk-in customers' else coalesce(c.name, s.customer_name, 'Customer') end,
    case when w.walk_in then null else private.vat_tin(coalesce(c.tin, s.customer_tin)) end,
    left(case when coalesce(ol.kind, l.kind) = 'delivery' then 'Delivery' else coalesce(i.name, nullif(trim(coalesce(ol.description, l.description)), ''), 'Sale') end, 120),
    case l.vat_treatment when 'exempt' then 1 when 'zero' then 2 else 0 end,
    case when pc.by_customer then cs.st else br.state end,
    case when pc.by_customer then private.ng_lga(cs.st, c.lga) else br.lga end,
    case when pc.by_customer then 'customer' else 'branch' end,
    br.id, br.name, c.id, c.state, c.lga,
    case when s.doc_type = 'credit_note' then -p.net else p.net end
  -- A credit note's line names the line it credits, so it nets against that product.
  -- What of each sale falls in the month: its settled share on payment basis, else all of it in its own month.
  from private.vat_sale_parts(p_org, v_f, v_t) p join sales s on s.id = p.sale_id join sale_lines l on l.id = p.line_id
    left join sale_lines ol on ol.id = l.original_line_id
    left join customers c on c.id = s.customer_id left join items i on i.id = coalesce(l.item_id, ol.item_id)
    left join locations br on br.id = coalesce(s.location_id, mn.id)
    cross join lateral (select coalesce(c.is_walk_in, s.customer_id is null and s.channel in ('till', 'voice')) walk_in) w
    -- The customer's state as chosen, else as its address names it.
    cross join lateral (select case when c.id is not null and coalesce(upper(c.country), 'NG') = 'NG'
      then coalesce(private.ng_state(c.state), private.ng_state_of_address(c.address)) end st) cs
    cross join lateral (select not w.walk_in and not coalesce(s.export, false) and cs.st is not null by_customer) pc
  where not (s.doc_type = 'credit_note' and l.vat_treatment = 'standard') and p.net <> 0;

  select coalesce(jsonb_agg(jsonb_build_object('customer', cname, 'tin', ctin, 'product', product, 'category', cat, 'label', label, 'state', st, 'lga', lga,
      'amount', amount, 'place_from', place_from) order by cat, cname, product), '[]'::jsonb)
  into a
  from (select cust_key, cname, ctin, product, cat, label, st, lga, place_from, round(sum(amount), 2) amount from vat_a_lines
        group by cust_key, cname, ctin, product, cat, label, st, lga, place_from having round(sum(amount), 2) <> 0) g;

  -- ---- B: credit notes on standard-rated lines, one row each ----
  select coalesce(jsonb_agg(jsonb_build_object('description', descr, 'tin', ctin, 'customer', cname, 'date', issue_date, 'invoice', inv_no,
      'invoice_amount', inv_amount, 'adjusted', adjusted) order by issue_date, number), '[]'::jsonb)
  into b
  from (select s.number, s.issue_date,
          left('Credit note ' || s.number || coalesce(' against ' || orig.number, '') || coalesce(': ' || nullif(trim(s.notes), ''), ''), 200) descr,
          case when coalesce(c.is_walk_in, false) then null else private.vat_tin(coalesce(c.tin, s.customer_tin)) end ctin,
          case when coalesce(c.is_walk_in, false) then 'Walk-in customers' else coalesce(c.name, s.customer_name, 'Customer') end cname,
          coalesce(orig.number, s.number) inv_no,
          round(coalesce((select sum(ol.net) from sale_lines ol where ol.sale_id = orig.id), sum(l.net)), 2) inv_amount,
          round(sum(l.net), 2) adjusted
        from sales s join sale_lines l on l.sale_id = s.id left join customers c on c.id = s.customer_id left join sales orig on orig.id = s.original_sale_id
        where s.org_id = p_org and s.doc_type = 'credit_note' and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import'
          and s.issue_date between v_f and v_t and l.vat_treatment = 'standard' and l.net <> 0
        group by s.id, s.number, s.issue_date, s.notes, s.customer_tin, s.customer_name, c.is_walk_in, c.tin, c.name, orig.id, orig.number) x;

  -- ---- C_2: standard-rated purchases whose VAT is claimed, by bill (and stock receipt), as goods, services or fixed assets ----
  select coalesce(jsonb_object_agg(kind, rows), '{}'::jsonb) into c2
  from (select kind, jsonb_agg(jsonb_build_object('seller', seller, 'tin', tin, 'description', descr, 'amount', amount, 'ref', ref) order by pday, ref) rows
        from (select private.vat_purchase_kind(bl.account_code, coalesce(bl.wht_category, x.wht_category)) kind,
                private.vat_claim_day(x.bill_date, x.status = 'paid', x.paid_in_full_on, o.vat_claim_on_payment_from) as pday, x.number as ref,
                v.name seller, private.vat_tin(v.tin) tin,
                left(x.number || coalesce(' (their ' || nullif(x.vendor_ref, '') || ')', '') || ': ' || string_agg(distinct coalesce(nullif(trim(bl.description), ''), 'Purchase'), ', '), 200) descr,
                round(sum(bl.net), 2) amount
              from bills x join bill_lines bl on bl.bill_id = x.id join vendors v on v.id = x.vendor_id
              where x.org_id = p_org and x.source not in ('receipt', 'import') and x.journal_id is not null and x.status <> 'void' and x.bill_date <= v_t
                and (x.bill_date >= v_f or x.paid_in_full_on >= v_f)
                and private.vat_claim_day(x.bill_date, x.status = 'paid', x.paid_in_full_on, o.vat_claim_on_payment_from) between v_f and v_t
                and bl.vat_recoverable and bl.vat > 0
              group by 1, 2, x.id, x.number, x.vendor_ref, v.name, v.tin
              union all
              select 'goods', dd.d, r.ref, coalesce(v.name, r.vendor_name, 'Supplier'), private.vat_tin(v.tin),
                left('Stock received ' || r.ref || coalesce(' (their ' || nullif(r.invoice_no, '') || ')', ''), 200), round(r.input_vat / v_vr, 2)
              from receipts r left join vendors v on v.id = r.vendor_id left join bills rb on rb.receipt_id = r.id and rb.source = 'receipt'
                cross join lateral (select private.vat_claim_day(private.local_day(r.org_id, coalesce(r.posted_at, r.created_at)), coalesce(rb.status = 'paid', true),
                  rb.paid_in_full_on, o.vat_claim_on_payment_from) d) dd
              where r.org_id = p_org and r.status = 'posted' and r.input_vat > 0 and dd.d between v_f and v_t) y
        group by kind) z;
  -- Suppliers' credit notes reduce the purchases (the reconciliation column of schedule C).
  select jsonb_build_object('goods', coalesce(sum(n) filter (where kind = 'goods'), 0), 'services', coalesce(sum(n) filter (where kind = 'services'), 0),
      'fixed_assets', coalesce(sum(n) filter (where kind = 'fixed_assets'), 0))
  into c2v
  from (select private.vat_purchase_kind(cl.account_code, ob.wht_category) kind, -round(cl.net, 2) n
        from vendor_credits vc join vendor_credit_lines cl on cl.credit_id = vc.id left join bill_lines ob on ob.id = cl.bill_line_id
        where vc.org_id = p_org and vc.status <> 'void' and vc.journal_id is not null and vc.credit_date between v_f and v_t and cl.vat > 0) q;

  -- ---- C1: standard-rated stock written off (its VAT is taken back), grouped by why ----
  select coalesce(jsonb_agg(jsonb_build_object('description', descr, 'amount', amount, 'zero', round(amount * v_zs, 2)) order by descr), '[]'::jsonb) into c1
  from (select case reason when 'Breakage' then 'Damaged or broken stock written off' when 'Expired' then 'Expired stock written off'
            when 'Theft suspected' then 'Stock lost to theft' when 'Written off' then 'Stock written off' else 'Other stock losses written off' end descr,
          round(sum(cost), 2) amount
        from private.vat_stock_writeoffs(p_org, v_f, v_t) group by 1) w;

  -- ---- D: imports, from the customs entries ----
  select coalesce(jsonb_agg(jsonb_build_object('number', number, 'importer', importer, 'description', left(description || coalesce(' (HS ' || hs_code || ')', ''), 250),
      'vessel', vessel, 'country', country, 'form_m', form_m, 'bill_of_lading', bill_of_lading, 'quantity', quantity, 'currency', currency, 'invoice_value', invoice_value,
      'fx_rate', fx_rate, 'value_ngn', value_ngn, 'other_charges', other_charges, 'total_cost', vat_base, 'import_vat', import_vat) order by entry_date, number), '[]'::jsonb)
  into d
  from customs_entries where org_id = p_org and status = 'posted' and entry_date between v_f and v_t;

  -- ---- E: VAT self-charged on services (and goods) from suppliers abroad, whose VAT is claimed back ----
  v_place_state := coalesce(mn.state, private.ng_state_of_address(coalesce(o.registered_office, o.address)));
  select coalesce(jsonb_agg(jsonb_build_object('name', name, 'tin', tin, 'status', 'Self Charge', 'description', descr,
      'category', case kind when 'goods' then 'VATable Local Goods Purchased (Relating to VATable purchases)'
        when 'fixed_assets' then 'VATable Fixed Assets Purchased Locally (Relating to VATable purchases)'
        else 'VATable Local Services Received (Relating to VATable purchases)' end,
      'place', case when st = 'FCT' then 'Federal Capital Territory' else st end, 'amount', amount) order by name, descr), '[]'::jsonb)
  into e
  from (select v.name, private.vat_tin(v.tin) tin, private.vat_purchase_kind(bl.account_code, coalesce(bl.wht_category, x.wht_category)) kind,
          coalesce(lb.state, v_place_state) st,
          left(x.number || ': ' || string_agg(distinct coalesce(nullif(trim(bl.description), ''), 'Service'), ', '), 200) descr, round(sum(bl.net), 2) amount
        from bills x join bill_lines bl on bl.bill_id = x.id join vendors v on v.id = x.vendor_id left join locations lb on lb.id = bl.location_id
        where x.org_id = p_org and x.source not in ('receipt', 'import') and x.journal_id is not null and x.status <> 'void' and x.bill_date between v_f and v_t
          and bl.vat_recoverable and bl.reverse_charge_vat > 0
        group by v.name, v.tin, 3, 4, x.id, x.number) r;

  -- ---- F: VAT kept by withholding agents (MDAs, banks, oil and gas companies) on what we sold them ----
  select coalesce(jsonb_agg(jsonb_build_object('agent', agent, 'address', address, 'tin', tin, 'nature', nature, 'date', day, 'invoice', invoice,
      'currency', 'NGN', 'invoice_value', value, 'fx_rate', 1, 'value_ngn', value, 'vat', vat) order by day, invoice), '[]'::jsonb)
  into f
  from (select coalesce(cu.name, s.customer_name, 'Customer') agent, left(concat_ws(', ', nullif(trim(cu.address), ''), nullif(trim(cu.city), ''), nullif(trim(cu.state), '')), 250) address,
          private.vat_tin(coalesce(cu.tin, s.customer_tin)) tin,
          case when bool_and(sl.kind = 'service') then 'Supply of services' when bool_or(sl.kind = 'service') then 'Supply of goods and services' else 'Supply of goods' end nature,
          private.local_day(co.org_id, co.received_at) as day, coalesce(s.number, co.number) as invoice,
          -- The invoice's own value before VAT (its VATable lines, less credit notes on them), shared across the agent's payments
          -- on it by the VAT each kept (TaxStreem sign-off N-5). The template credits 7.5% of it; where that differs from what the
          -- agent kept, a check says so. A payment with no invoice keeps the value its VAT implies.
          coalesce(round(iv.vatable * co.amount / nullif(iv.kept, 0), 2), round(co.amount / v_vr, 2)) value, co.amount vat
        from collections co left join sales s on s.id = co.sale_id left join customers cu on cu.id = co.customer_id left join sale_lines sl on sl.sale_id = s.id
          left join lateral (select nullif(greatest((select coalesce(sum(x.net), 0) from sale_lines x where x.sale_id = s.id and x.vat > 0)
              - (select coalesce(sum(x.net), 0) from sales cn join sale_lines x on x.sale_id = cn.id
                 where cn.original_sale_id = s.id and cn.doc_type = 'credit_note' and cn.status <> 'void' and cn.journal_id is not null and x.vat > 0), 0), 0) vatable,
            (select sum(k.amount) from collections k where k.sale_id = s.id and k.method = 'wvat_credit' and k.status = 'confirmed' and k.journal_id is not null) kept) iv on s.id is not null
        where co.org_id = p_org and co.method = 'wvat_credit' and co.status = 'confirmed' and co.journal_id is not null
          and private.local_day(co.org_id, co.received_at) between v_f and v_t
        group by co.id, co.org_id, co.received_at, co.number, co.amount, cu.name, cu.address, cu.city, cu.state, cu.tin, s.customer_name, s.customer_tin, s.number,
          iv.vatable, iv.kept) w;

  -- ---- The form's lines, as the template's formulas work them out ----
  l := jsonb_build_object(
    '10', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(a) r),
    '15', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(a) r where (r->>'category')::int = 1),
    '20', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(a) r where (r->>'category')::int = 2),
    '22', (select coalesce(sum((r->>'adjusted')::numeric), 0) from jsonb_array_elements(b) r),
    '40', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_each(c2) k, jsonb_array_elements(k.value) r)
      + coalesce((c2v->>'goods')::numeric, 0) + coalesce((c2v->>'services')::numeric, 0) + coalesce((c2v->>'fixed_assets')::numeric, 0),
    '45', -(select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(c1) r),
    '85', (select coalesce(sum((r->>'total_cost')::numeric), 0) from jsonb_array_elements(d) r),
    '105_base', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(e) r),
    '110', (select coalesce(sum(round(v_vr * (r->>'value_ngn')::numeric, 10)), 0) from jsonb_array_elements(f) r));
  l := l || jsonb_build_object('25', (l->>'10')::numeric - (l->>'15')::numeric - (l->>'20')::numeric - (l->>'22')::numeric);
  l := l || jsonb_build_object('35', round((l->>'25')::numeric * v_vr, 2), '55', round(((l->>'40')::numeric + (l->>'45')::numeric) * v_vr, 2),
    '90', round((l->>'85')::numeric * v_vr, 2), '105', round((l->>'105_base')::numeric * v_vr, 2));
  l := l || jsonb_build_object('95', (l->>'55')::numeric + (l->>'90')::numeric);
  l := l || jsonb_build_object('100', (l->>'35')::numeric - (l->>'95')::numeric);
  l := l || jsonb_build_object('115', round((l->>'100')::numeric - ((l->>'105')::numeric + (l->>'110')::numeric), 2));

  -- ---- What to fix, and how the return ties to Counta's VAT for the month ----
  v_net := (mo->>'output')::numeric - (mo->>'wvat_credit')::numeric - (mo->>'input')::numeric;
  -- What line 110 credits beyond the VAT agents kept (their own check explains it, so the tie leaves it out).
  v_wgap := (select coalesce(round(sum(v_vr * (r->>'value_ngn')::numeric - (r->>'vat')::numeric), 2), 0) from jsonb_array_elements(f) r);
  select count(*) into v_lines from vat_a_lines;
  v_tol := greatest(1, round(0.01 * (v_lines + jsonb_array_length(b) + jsonb_array_length(e) + jsonb_array_length(f)
    + (select count(*) from jsonb_each(c2) k, jsonb_array_elements(k.value) r)), 2));
  if v_t >= v_today then
    checks := checks || jsonb_build_object('severity', 'info', 'code', 'month_open', 'text', 'The month has not ended, so these figures can still change.');
  end if;
  -- Bank lines of the month not in the books yet: what they turn out to be can change the return.
  v_bw := private.vat_bank_waiting(p_org, v_f, v_t);
  if (v_bw->>'lines')::int > 0 then
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'bank_waiting', 'lines', (v_bw->>'lines')::int, 'money_in', v_bw->'money_in', 'money_out', v_bw->'money_out',
      'text', (v_bw->>'lines') || case when (v_bw->>'lines')::int = 1 then ' bank line from this month is' else ' bank lines from this month are' end
        || ' not in the books yet (' || private.naira((v_bw->>'money_in')::numeric) || ' in, ' || private.naira((v_bw->>'money_out')::numeric) || ' out). '
        || 'Confirm them in the Books inbox before you file: money in that is a sale adds output VAT, and a payment for a supplier''s invoice that shows VAT adds input VAT once the invoice is recorded.');
  end if;
  -- On payment basis, invoices of the month not paid in full by its end: their VAT falls in the months their customers pay.
  select count(*) n, coalesce(sum(round(s.vat_total * (1 - least(1, coalesce((select sum(x.amount) from private.sale_settlements(s.id) x where x.day <= v_t), 0) / s.total)), 2)), 0) vat
  into v_wait
  from sales s
  where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import' and s.doc_type <> 'credit_note' and s.vat_total > 0 and s.total > 0
    and s.issue_date between v_f and v_t and (s.settled_on is null or s.settled_on > v_t) and private.vat_basis_on(p_org, s.issue_date) = 'payment';
  if v_wait.n > 0 and v_wait.vat > 0 then
    checks := checks || jsonb_build_object('severity', 'info', 'code', 'unpaid_invoices', 'count', v_wait.n, 'vat', v_wait.vat,
      'text', v_wait.n || case when v_wait.n = 1 then ' invoice' else ' invoices' end || ' dated this month ' || case when v_wait.n = 1 then 'was' else 'were' end
        || ' not paid in full by its end. Output VAT follows payments, so ' || private.naira(v_wait.vat) || ' of VAT on ' || case when v_wait.n = 1 then 'it' else 'them' end
        || ' falls in the months the customers pay.');
  end if;
  if vp.period is not null and (abs((mo->>'output')::numeric - vp.output_vat) >= 0.01 or abs((mo->>'input')::numeric - vp.input_vat) >= 0.01
     or abs((mo->>'wvat_credit')::numeric - vp.wvat_credit) >= 0.01) then
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'changed_since_filing',
      'text', 'Documents for this month changed after the return was filed. The file shows the books as they are now; reopen the return to file the change.');
  end if;
  -- Places.
  for rw in select branch_id, branch_name, bool_or(st is null) no_state, bool_or(st is not null and lga is null) no_lga, count(*) n
           from vat_a_lines where place_from = 'branch' group by branch_id, branch_name having bool_or(st is null) or bool_or(lga is null) loop
    checks := checks || jsonb_build_object('severity', 'warn', 'code', case when rw.no_state then 'branch_state' else 'branch_lga' end,
      'text', case when rw.branch_id is null then 'The business has no branch with a state. Add the state and local government area of the main branch.'
        else 'Add the ' || case when rw.no_state then 'state and local government area' else 'local government area' end || ' of ' || rw.branch_name
          || ': its sales (and those of customers whose state is not known) are placed there.' end,
      'fix', jsonb_build_object('kind', 'branch', 'id', rw.branch_id, 'name', rw.branch_name));
  end loop;
  for rw in select customer_id, max(cname) cname, max(st) st from vat_a_lines where place_from = 'customer' and lga is null and customer_id is not null group by customer_id
           order by 2 limit 50 loop
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'customer_lga', 'text', 'Add the local government area of ' || rw.cname || ' (' || rw.st || ').',
      'fix', jsonb_build_object('kind', 'customer', 'id', rw.customer_id, 'name', rw.cname, 'state', rw.st));
  end loop;
  for rw in select customer_id, max(cname) cname, max(c_state) c_state from vat_a_lines
           where place_from = 'branch' and customer_id is not null and nullif(trim(c_state), '') is not null and private.ng_state(c_state) is null
             and not cust_key like 'walkin:%'
             and exists (select 1 from customers cc where cc.id = customer_id and coalesce(upper(cc.country), 'NG') = 'NG')
           group by customer_id order by 2 limit 20 loop
    checks := checks || jsonb_build_object('severity', 'info', 'code', 'customer_state', 'text', rw.cname || '''s state "' || rw.c_state
      || '" is not a Nigerian state Counta knows, so the branch''s state is used. Choose it from the list if the customer is in Nigeria.',
      'fix', jsonb_build_object('kind', 'customer', 'id', rw.customer_id, 'name', rw.cname));
  end loop;
  -- Descriptions of exempt and zero-rated supplies.
  for rw in select item_id, coalesce(max(i.name), max(vl.description)) name, max(vl.treatment) treatment, min(vl.line_id::text)::uuid line_id, sum(vl.amount) amount
           from vat_a_lines vl left join items i on i.id = vl.item_id where vl.cat in (1, 2) and vl.label is null
           group by vl.item_id, case when vl.item_id is null then vl.line_id end order by 2 limit 50 loop
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'label',
      'text', 'Choose the NRS description for ' || rw.name || ' (' || case rw.treatment when 'zero' then 'zero-rated' else 'exempt' end || ', '
        || private.naira(rw.amount) || '). The template takes only its own list.',
      'fix', case when rw.item_id is not null then jsonb_build_object('kind', 'item', 'id', rw.item_id, 'name', rw.name, 'treatment', rw.treatment)
        else jsonb_build_object('kind', 'line', 'id', rw.line_id, 'name', rw.name, 'treatment', rw.treatment) end);
  end loop;
  -- Descriptions in the Act's words that the template's list does not carry yet.
  for rw in select vl.label, count(distinct vl.product) n, (array_agg(distinct vl.product order by vl.product))[1:5] names
           from vat_a_lines vl join nrs_vat_labels nl on nl.label = vl.label and not nl.on_template group by vl.label order by 1 loop
    checks := checks || jsonb_build_object('severity', 'info', 'code', 'label_off_list',
      'text', 'Schedule A describes ' || array_to_string(rw.names, ', ') || case when rw.n > 5 then ' and ' || (rw.n - 5) || ' more' else '' end
        || ' as "' || rw.label || '", the Act''s words. The NRS template''s list does not have them yet; '
        || 'if the portal refuses the file, choose the nearest description on the list for them.');
  end loop;
  -- An agent that kept a different amount from 7.5% of the invoice value: line 110 credits 7.5% of it.
  for rw in select r->>'agent' agent, r->>'invoice' invoice, (r->>'vat')::numeric kept, round(v_vr * (r->>'value_ngn')::numeric, 2) credited
           from jsonb_array_elements(f) r where abs((r->>'vat')::numeric - round(v_vr * (r->>'value_ngn')::numeric, 2)) >= 1 order by 2 limit 50 loop
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'wvat_partial',
      'text', 'On ' || rw.invoice || ', ' || rw.agent || ' kept ' || private.naira(rw.kept) || ' of VAT, but the template credits 7.5% of the invoice value, '
        || private.naira(rw.credited) || '. Check what the agent withheld before you file.');
  end loop;
  if exists (select 1 from jsonb_array_elements(a) r where (r->>'amount')::numeric < 0) then
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'negative_row',
      'text', 'Credit notes on exempt or zero-rated sales are more than the sales they net against for some rows. Those rows go in as negative amounts, which the portal may refuse.');
  end if;
  -- What the template holds.
  if jsonb_array_length(a) > 9973 then
    checks := checks || jsonb_build_object('severity', 'block', 'code', 'too_many_a', 'text', 'Schedule A holds 9,973 rows and this month has ' || jsonb_array_length(a) || '.');
  end if;
  if jsonb_array_length(e) > 37 then
    checks := checks || jsonb_build_object('severity', 'block', 'code', 'too_many_e', 'text', 'Schedule E holds 37 rows and this month has ' || jsonb_array_length(e) || ' bills with VAT self-charged.');
  end if;
  if jsonb_array_length(f) > 2299 then
    checks := checks || jsonb_build_object('severity', 'block', 'code', 'too_many_f', 'text', 'Schedule F holds 2,299 rows and this month has ' || jsonb_array_length(f) || '.');
  end if;
  if exists (select 1 from customs_entries where org_id = p_org and status = 'posted' and entry_date between v_f and v_t and abs(import_vat - round(vat_base * v_vr, 2)) >= 1) then
    checks := checks || jsonb_build_object('severity', 'info', 'code', 'import_vat', 'text', 'The template takes import VAT as 7.5% of the total cost of each import; '
      || 'some customs entries paid a different amount, so line 90 differs from what was paid.');
  end if;
  if abs((l->>'115')::numeric + v_wgap - v_net) > v_tol then
    checks := checks || jsonb_build_object('severity', 'warn', 'code', 'tie',
      'text', 'The return comes to ' || private.naira((l->>'115')::numeric) || ' (line 115) and Counta''s VAT for the month to ' || private.naira(v_net)
        || '. The template works VAT out on totals, Counta line by line; a gap of more than ' || private.naira(v_tol) || ' needs a look.');
  end if;

  return jsonb_build_object('period', v_f, 'to', v_t,
    'org', jsonb_build_object('name', o.name, 'tin', o.tin, 'tax_id', private.vat_tin(o.tin), 'state', v_place_state),
    'file_name', to_char(v_f, 'YYYY') || '_' || coalesce(private.vat_tin(o.tin), regexp_replace(coalesce(o.tin, 'NO-TAX-ID'), '[^0-9A-Za-z-]', '', 'g')) || '_VAT_'
      || extract(month from v_f)::int || '.xlsx',
    'a', a, 'b', b, 'c2', jsonb_build_object('goods', coalesce(c2->'goods', '[]'::jsonb), 'services', coalesce(c2->'services', '[]'::jsonb),
      'fixed_assets', coalesce(c2->'fixed_assets', '[]'::jsonb)), 'c_variance', c2v, 'zero_share', v_zs,
    'c1', c1, 'd', d, 'e', e, 'f', f, 'lines', l,
    'counta', mo || jsonb_build_object('net', v_net, 'filed', vp.period is not null, 'status', coalesce(vp.status, 'open')),
    'tolerance', v_tol, 'difference', round((l->>'115')::numeric - v_net, 2), 'wvat_gap', v_wgap,
    'checks', checks, 'blocked', exists (select 1 from jsonb_array_elements(checks) c where c->>'severity' = 'block'));
end $function$;

create or replace function public.vat_position(p_org uuid, p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; v_to date := date_trunc('month', coalesce(nullif(p->>'to', '')::date, private.local_day(p_org, now())))::date;
  v_from date := date_trunc('month', coalesce(nullif(p->>'from', '')::date, (v_to - interval '11 months')::date))::date; ch jsonb; v_today date := private.local_day(p_org, now());
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'VAT returns need See margins, Keep the books or Make payments.' using errcode = '42501'; end if;
  ch := private.vat_chain(p_org, v_to);
  return jsonb_build_object('from', v_from, 'to', v_to,
    'months', (select coalesce(jsonb_agg(x || jsonb_build_object('ended', (x->>'period')::date + interval '1 month' <= v_today + 1,
        'overdue', (x->>'payable')::numeric > 0 and x->>'status' <> 'paid' and (x->>'due_date')::date < v_today) order by (x->>'period')::date desc), '[]'::jsonb)
      from jsonb_array_elements(ch) x where (x->>'period')::date >= v_from),
    'credit_cf', coalesce((ch->-1->>'credit_cf')::numeric, 0),
    'expiring', (select coalesce(jsonb_agg(l order by (l->>'from')::date), '[]'::jsonb) from jsonb_array_elements(coalesce(ch->-1->'layers', '[]'::jsonb)) l
      where (l->>'from')::date < (v_to - interval '54 months')::date),
    'refundable', (select coalesce(sum((l->>'amount')::numeric), 0) from jsonb_array_elements(coalesce(ch->-1->'layers', '[]'::jsonb)) l
      where (l->>'from')::date >= (v_to - interval '11 months')::date),
    'wvat_due', (select coalesce(sum(amount), 0) from wht_deductions where org_id = p_org and kind <> 'wht' and status = 'deducted'),
    'status', public.vat_status(p_org),
    'basis', private.vat_basis_json(p_org, m),
    -- Bank lines of each month not in the books yet.
    'bank_waiting', (select coalesce(jsonb_object_agg(mth, w), '{}'::jsonb)
      from (select gs::date mth, private.vat_bank_waiting(p_org, gs::date, (gs + interval '1 month' - interval '1 day')::date) w
            from generate_series(v_from, v_to, interval '1 month') gs) z where (w->>'lines')::int > 0),
    'can_file', private.perm_of(m, 'keep_books'), 'can_pay', private.perm_of(m, 'keep_books') or private.perm_of(m, 'make_payments'));
end $function$;

-- ---------------------------------------------------------------------------
-- 4. What a customer kept back, typed with a payment, is dated with the payment
-- ---------------------------------------------------------------------------
-- The WHT, VAT withheld and NCD levy typed beside a payment were dated the day they were recorded, while the money took the
-- day it came; on payment basis that put part of the invoice in another month. They now take the payment's day.
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
    perform private.add_collection(p_org, v_cust, v_wht, 'wht_credit', jsonb_build_object('reference', 'WHT deducted', 'wht_rate', nullif(p_payment->>'wht_rate', ''), 'received_at', p_payment->>'received_at',
      'note', 'Collect the withholding tax credit note from the customer', 'spread', v_sale is null), m, 'confirmed', case when v_sale is not null then array[v_sale] end);
  end if;
  -- VAT a customer who is a withholding VAT agent kept: credited in our VAT return (Dr 1405 / Cr 1101).
  if coalesce(v_wvat, 0) > 0 then
    if v_sale is not null and v_wvat > s.vat_total + 0.004 then raise exception 'The VAT withheld cannot be more than the VAT on %.', s.number; end if;
    perform private.add_collection(p_org, v_cust, v_wvat, 'wvat_credit', jsonb_build_object('reference', 'VAT withheld', 'received_at', p_payment->>'received_at',
      'note', 'VAT the customer withholds and pays to the NRS; credited in the VAT return', 'spread', v_sale is null), m, 'confirmed', case when v_sale is not null then array[v_sale] end);
  end if;
  -- The 1% Nigerian Content Development levy an oil and gas customer deducted: a cost to the business (Dr 6512 / Cr 1101).
  if coalesce(v_ncd, 0) > 0 then
    perform private.add_collection(p_org, v_cust, v_ncd, 'ncd_levy', jsonb_build_object('reference', 'NCD levy deducted', 'received_at', p_payment->>'received_at',
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
