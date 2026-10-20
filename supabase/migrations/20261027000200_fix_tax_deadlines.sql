-- Counta, 27 October 2026, fix 1: the tax deadlines of a VAT-registered business.
--
-- private.tax_deadlines returns a column called "period", and one of its queries named vat_periods.period without the
-- table, so Postgres could not tell the two apart and stopped with "column reference period is ambiguous" for any
-- VAT-registered business whose books began before this month. The morning alerts and the counts beside the menu
-- (get_attention) both read the deadlines, so for those businesses the counts did not load and the alerts would not
-- have gone out. The column is now named with its table; nothing else changes. Safe to run more than once.

create or replace function private.tax_deadlines(p_org uuid) returns table (tax text, label text, period date, due date, amount numeric, url text)
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; v_today date := private.local_day(p_org, now()); v_last date; vp public.vat_periods; r record; v_year int; v_from date; v_to date; cy record;
begin
  select * into o from orgs where id = p_org;
  -- VAT: every month that ended since the books started, not filed (or filed and not paid), due on the 21st after it.
  if o.vat_registered then
    for r in select g::date mth from generate_series(date_trunc('month', greatest(coalesce(o.books_start, o.created_at::date), v_today - 400))::date,
                                                      (date_trunc('month', v_today) - interval '1 month')::date, interval '1 month') g loop
      select * into vp from vat_periods where vat_periods.org_id = p_org and vat_periods.period = r.mth;
      if vp.period is null or (vp.status = 'filed' and vp.payable > 0) then
        tax := 'vat'; label := case when vp.period is null then 'VAT return' else 'VAT payment' end; period := r.mth;
        due := (r.mth + interval '1 month')::date + 20; amount := case when vp.period is not null then vp.payable end; url := '/tax/vat';
        return next;
      end if;
    end loop;
  end if;
  -- WHT and withholding VAT deducted and not yet paid over, by month and authority.
  for r in select d.period, d.authority, d.kind, min(d.due_date) due_date, sum(d.amount) amt from wht_deductions d
           where d.org_id = p_org and d.status = 'deducted' and d.kind in ('wht', 'wvat') group by d.period, d.authority, d.kind loop
    tax := case when r.kind = 'wht' then 'wht' else 'wvat' end; label := case when r.kind = 'wht' then 'WHT to ' || r.authority else 'Withholding VAT' end;
    period := r.period; due := r.due_date; amount := r.amt; url := '/tax/wht';
    return next;
  end loop;
  -- CIT: the year that ended most recently, due six months after its end.
  v_year := extract(year from v_today)::int;
  select pfrom, pto into v_from, v_to from private.cit_period(p_org, v_year);
  if v_to >= v_today then v_year := v_year - 1; select pfrom, pto into v_from, v_to from private.cit_period(p_org, v_year); end if;
  if v_to is not null and coalesce(o.books_start, v_to) <= v_to
     and not exists (select 1 from cit_years where org_id = p_org and accounting_year = v_year and status in ('sent', 'filed')) then
    tax := 'cit'; label := 'Companies income tax return'; period := v_from; due := (v_to + interval '6 months')::date; amount := null; url := '/tax/cit?year=' || v_year;
    return next;
  end if;
end $$;
