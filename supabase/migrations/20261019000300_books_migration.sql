-- Counta: moving a business's books from QuickBooks, Zoho Books, Xero or Sage. The opening position at a cut-over date:
-- the trial balance mapped to Counta's chart (rules first, then the AI; anything under 80% sure waits for a person),
-- customers, suppliers and items, and every unpaid invoice and bill, reconciled to the control accounts before it posts.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table if not exists public.books_migrations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  source text not null check (source in ('quickbooks', 'zoho', 'xero', 'sage', 'other')),
  as_of date not null,
  status text not null default 'draft' check (status in ('draft', 'posted', 'reversed')),
  tb_file text,
  ar_file text,
  ap_file text,
  journal_id uuid references public.journals(id) on delete set null,
  reversal_journal_id uuid references public.journals(id) on delete set null,
  summary jsonb not null default '{}',
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  posted_by uuid references public.members(id) on delete set null,
  posted_at timestamptz,
  reversed_by uuid references public.members(id) on delete set null,
  reversed_at timestamptz
);
create unique index if not exists books_migrations_one_draft on public.books_migrations(org_id) where status = 'draft';
create index if not exists books_migrations_org on public.books_migrations(org_id, created_at desc);
create index if not exists books_migrations_journal_fk on public.books_migrations(journal_id);
create index if not exists books_migrations_reversal_fk on public.books_migrations(reversal_journal_id);
create index if not exists books_migrations_created_by_fk on public.books_migrations(created_by);
create index if not exists books_migrations_posted_by_fk on public.books_migrations(posted_by);
create index if not exists books_migrations_reversed_by_fk on public.books_migrations(reversed_by);

create table if not exists public.migration_accounts (
  id uuid primary key default gen_random_uuid(),
  migration_id uuid not null references public.books_migrations(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  line_no int not null,
  source_code text,
  source_name text not null,
  source_type text,
  debit numeric(16,2) not null default 0 check (debit >= 0),
  credit numeric(16,2) not null default 0 check (credit >= 0),
  mapped_code text,
  new_bank boolean not null default false,
  bank_name text,
  confidence numeric(4,3),
  reason text,
  mapped_by text check (mapped_by in ('rule', 'ai', 'person')),
  confirmed boolean not null default false
);
create index if not exists migration_accounts_migration on public.migration_accounts(migration_id, line_no);
create index if not exists migration_accounts_org on public.migration_accounts(org_id);

create table if not exists public.migration_open_items (
  id uuid primary key default gen_random_uuid(),
  migration_id uuid not null references public.books_migrations(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  kind text not null check (kind in ('invoice', 'bill')),
  line_no int not null,
  party_name text not null,
  number text,
  issue_date date,
  due_date date,
  amount numeric(16,2) not null check (amount > 0),
  doc_id uuid
);
create index if not exists migration_open_items_migration on public.migration_open_items(migration_id, kind, line_no);
create index if not exists migration_open_items_org on public.migration_open_items(org_id);

alter table public.books_migrations enable row level security;
alter table public.migration_accounts enable row level security;
alter table public.migration_open_items enable row level security;
drop policy if exists books_migrations_read on public.books_migrations;
create policy books_migrations_read on public.books_migrations for select to authenticated using ((select private.can_handle_money(org_id)));
drop policy if exists migration_accounts_read on public.migration_accounts;
create policy migration_accounts_read on public.migration_accounts for select to authenticated using ((select private.can_handle_money(org_id)));
drop policy if exists migration_open_items_read on public.migration_open_items;
create policy migration_open_items_read on public.migration_open_items for select to authenticated using ((select private.can_handle_money(org_id)));

-- Opening documents carry the old system's revenue and VAT already: they stay out of sales analysis and the VAT return.
create or replace function private.vat_rows(p_org uuid, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = public, private as $$
  with sl as (select s.doc_type, s.export, l.vat_treatment, l.net, l.vat from sales s join sale_lines l on l.sale_id = s.id
              where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import' and s.issue_date between p_from and p_to),
  so as (select coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'standard'), 0) std,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'zero'), 0) zero,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'zero' and export), 0) exports,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'exempt'), 0) exempt,
                coalesce(sum(case when doc_type = 'credit_note' then -vat else vat end), 0) vat from sl),
  bi as (select coalesce(sum(bl.vat) filter (where bl.vat_recoverable), 0) vat, coalesce(sum(bl.net) filter (where bl.vat > 0), 0) base from bills b join bill_lines bl on bl.bill_id = b.id
         where b.org_id = p_org and b.source not in ('receipt', 'import') and b.journal_id is not null and b.status <> 'void' and b.bill_date between p_from and p_to),
  rc as (select coalesce(sum(input_vat), 0) vat, coalesce(sum(net) filter (where input_vat > 0), 0) base from receipts
         where org_id = p_org and status = 'posted' and private.local_day(org_id, coalesce(posted_at, created_at)) between p_from and p_to),
  led as (select coalesce(sum(mv.cr - mv.dr) filter (where mv.code = '2201'), 0) out_ledger, coalesce(sum(mv.dr - mv.cr) filter (where mv.code = '1402'), 0) in_ledger
          from (select l.account_code code, sum(l.debit) dr, sum(l.credit) cr from journal_lines l join journals j on j.id = l.journal_id
                where l.org_id = p_org and j.entry_date between p_from and p_to and j.source_type in ('sale', 'bill', 'receipt') group by 1) mv)
  select jsonb_build_array(
    private.fr('Output VAT', null, null, 'heading', 0),
    private.fr('Standard-rated supplies, status 0 (7.5%)', so.std, null, 'line', 1),
    private.fr('Exempt supplies, status 1', so.exempt, null, 'line', 1),
    private.fr('Zero-rated supplies, status 2', so.zero, null, 'line', 1),
    private.fr('of which exports to customers outside Nigeria', so.exports, null, 'line', 2),
    private.fr('Output VAT charged', so.vat, null, 'subtotal', 0),
    private.fr('Input VAT', null, null, 'heading', 0),
    private.fr('Purchases and expenses on bills (taxable value ' || to_char(bi.base, 'FM999,999,999,990.00') || ')', bi.vat, null, 'line', 1),
    private.fr('Stock received (taxable value ' || to_char(rc.base, 'FM999,999,999,990.00') || ')', rc.vat, null, 'line', 1),
    private.fr('Input VAT recoverable', bi.vat + rc.vat, null, 'subtotal', 0),
    private.fr('VAT payable / (refundable) for the month', so.vat - bi.vat - rc.vat, null, 'total', 0),
    private.fr('Ledger check', null, null, 'heading', 0),
    private.fr('Output VAT in the ledger (2201) from sales', led.out_ledger, null, 'line', 1),
    private.fr('Input VAT in the ledger (1402) from bills and receipts', led.in_ledger, null, 'line', 1),
    private.fr('Difference to explain', (so.vat - led.out_ledger) - (bi.vat + rc.vat - led.in_ledger), null, 'subtotal', 0))
  from so, bi, rc, led
$$;


-- Sales analysis: opening documents stay out; sales can also be read by VAT status (0 VATable, 1 exempt, 2 zero-rated).
create or replace function private.sales_analysis(p_org uuid, p_from date, p_to date, p_by text, p_cost boolean) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', k, 'documents', docs, 'qty', qty, 'net', net, 'vat', vat, 'gross', gross,
      'cost', case when p_cost then cost end, 'margin', case when p_cost then net - cost end,
      'margin_pct', case when p_cost and net <> 0 then round((net - cost) / net * 100, 1) end) order by net desc), '[]'::jsonb)
  from (
    select case p_by when 'customer' then s.customer_name when 'channel' then initcap(s.channel) when 'branch' then (select name from locations where id = s.location_id)
                when 'cashier' then coalesce((select display_name from members where id = s.created_by), 'Online') when 'month' then to_char(s.issue_date, 'YYYY-MM')
                when 'day' then to_char(s.issue_date, 'YYYY-MM-DD')
                when 'vat_status' then case l.vat_status when 0 then '0 · VATable (7.5%)' when 1 then '1 · Exempt' else '2 · Zero-rated' end
                  || case when s.export and l.vat_status = 2 then ', export' else '' end
                else l.description end k,
      count(distinct s.id) docs, sum(case when s.doc_type = 'credit_note' then -l.qty else l.qty end * l.unit_factor) qty,
      sum(case when s.doc_type = 'credit_note' then -l.net else l.net end) net, sum(case when s.doc_type = 'credit_note' then -l.vat else l.vat end) vat,
      sum(case when s.doc_type = 'credit_note' then -l.gross else l.gross end) gross, sum(case when s.doc_type = 'credit_note' then -coalesce(l.cost, 0) else coalesce(l.cost, 0) end) cost
    from sales s join sale_lines l on l.sale_id = s.id
    where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import' and s.issue_date between p_from and p_to
      and (p_by <> 'item' or l.kind <> 'delivery')
    group by 1) x
$$;

-- ---------------------------------------------------------------------------
-- 2. Mapping rules: the old system's account to Counta's chart, with how sure the rule is
-- ---------------------------------------------------------------------------
create or replace function private.guess_account(p_org uuid, p_name text, p_type text, p_balance numeric)
returns table (code text, confidence numeric, reason text, new_bank boolean)
language plpgsql stable security definer set search_path = public, private as $$
declare n text := lower(coalesce(p_name, '')); t text := lower(coalesce(p_type, '')); v_rev text := private.acct(p_org, 'sales_revenue');
  v_asset boolean; v_liab boolean; v_eq boolean; v_inc boolean; v_exp boolean; v_cogs boolean; k text; c numeric; why text;
begin
  v_asset := t ~ '(asset|bank|cash|receivable|inventory|stock|prepayment|fixed)';
  v_liab := t ~ '(liabilit|payable|credit card|loan)';
  v_eq := t ~ '(equity|capital)';
  v_cogs := t ~ '(cost of (goods|sales)|direct cost|cogs)';
  v_inc := t ~ '(income|revenue|sales)' and not v_cogs;
  v_exp := t ~ '(expense|overhead|depreciation)' and not v_cogs;
  -- Cash and banks become Counta bank accounts of their own.
  if n ~ '(undeposited|clearing|in transit)' then k := '9002'; c := 0.85; why := 'Money in transit between accounts';
  elsif n ~ '(petty cash|cash in hand|cash on hand|^cash$|cash float|till)' and not v_liab then k := '1011'; c := 0.9; why := 'Cash in hand';
  elsif n ~ '(paystack|flutterwave|opay|moniepoint|palmpay|wallet|paypal|stripe)' and not v_liab then k := '1014'; c := 0.85; why := 'Payment wallet';
  elsif (t ~ 'bank' or n ~ '(bank|current account|savings|domiciliary|\mdom\M|gtb|guaranty|zenith|access|first bank|uba|fcmb|fidelity|stanbic|sterling|wema|union bank|polaris|ecobank|keystone|providus|kuda)')
        and not n ~ '(charge|fee|loan|interest|overdraft)' and not v_liab then
    k := case when n ~ '(domiciliary|\mdom\M|usd|gbp|eur|dollar|pound|euro)' then '1013' else '1012' end; c := 0.9; why := 'Bank account';
  elsif n ~ 'overdraft' then k := '2301'; c := 0.9; why := 'Bank overdraft';
  -- Receivables
  elsif t ~ 'receivable' or n ~ '(accounts receivable|trade receivable|debtors|\ma/r\M|trade debtors)' then
    k := case when n ~ '(foreign|export|usd)' then '1102' else '1101' end; c := 0.95; why := 'Trade receivables (control account)';
  elsif n ~ '(doubtful|bad debt provision|allowance for|expected credit|impairment of receivable)' then k := '1103'; c := 0.85; why := 'Loss allowance on receivables';
  elsif n ~ '(staff advance|staff loan|employee advance|salary advance)' then k := case when v_liab then '2104' else '1104' end; c := 0.8; why := 'Staff advances';
  elsif n ~ '(director)' and n ~ '(current|loan|account)' then k := case when v_liab or p_balance < 0 then '2106' else '1105' end; c := 0.8; why := 'Directors'' current account';
  elsif n ~ '(withholding|wht)' then k := case when v_liab or p_balance < 0 then '2202' else '1401' end; c := 0.85; why := 'Withholding tax';
  elsif n ~ '(vat|value added)' then
    k := case when n ~ '(input|receivable|recoverable|paid)' then '1402' when n ~ '(output|payable|collected)' then '2201' when v_liab or p_balance < 0 then '2201' else '1402' end;
    c := case when n ~ '(input|output|receivable|payable|recoverable|collected)' then 0.9 else 0.7 end; why := 'VAT';
  elsif n ~ '(prepaid|prepayment)' then k := case when n ~ 'rent' then '1301' when n ~ 'insurance' then '1302' else '1303' end; c := 0.85; why := 'Prepayment';
  elsif n ~ '(accrued income)' then k := '1107'; c := 0.85; why := 'Accrued income';
  -- Inventory
  elsif n ~ '(raw material)' then k := '1201'; c := 0.9; why := 'Raw materials';
  elsif n ~ '(work in progress|work-in-progress|\mwip\M)' and not v_exp then k := '1202'; c := 0.9; why := 'Work in progress';
  elsif n ~ '(goods in transit)' then k := '1204'; c := 0.9; why := 'Goods in transit';
  elsif n ~ '(consumable|spares)' and not v_exp then k := '1205'; c := 0.8; why := 'Consumables';
  elsif t ~ '(inventory|stock)' or n ~ '(inventory|stock|merchandise|finished goods)' and not v_exp and not v_cogs then k := '1203'; c := 0.9; why := 'Inventory';
  -- Property, plant and equipment, and their depreciation
  elsif n ~ '(accumulated depreciation|acc\.? dep|provision for depreciation|accum)' then
    k := case when n ~ '(vehicle|motor|car)' then '1560' when n ~ '(computer|laptop|it equipment)' then '1566' when n ~ '(furniture|fitting|fixture)' then '1568'
      when n ~ '(office equipment)' then '1563' when n ~ '(building)' then '1551' when n ~ '(plant|machinery)' then '1553' when n ~ '(leasehold)' then '1573'
      when n ~ '(tools|equipment)' then '1562' when n ~ '(software|intangible|amortis)' then '1609' else '1574' end;
    c := case when k = '1574' then 0.7 else 0.85 end; why := 'Accumulated depreciation';
  elsif n ~ '(land)' and not v_exp then k := '1501'; c := 0.85; why := 'Land';
  elsif n ~ '(building)' and not v_exp then k := '1502'; c := 0.8; why := 'Buildings';
  elsif n ~ '(plant|machinery|generator)' and (v_asset or t ~ 'fixed') then k := '1504'; c := 0.8; why := 'Plant and machinery';
  elsif n ~ '(motor vehicle|vehicle|car|truck|van)' and (v_asset or t ~ 'fixed') then k := '1511'; c := 0.85; why := 'Motor vehicles';
  elsif n ~ '(computer|laptop|it equipment)' and (v_asset or t ~ 'fixed') then k := '1517'; c := 0.85; why := 'Computer hardware';
  elsif n ~ '(office equipment)' and (v_asset or t ~ 'fixed') then k := '1514'; c := 0.85; why := 'Office equipment';
  elsif n ~ '(furniture|fitting|fixture)' and (v_asset or t ~ 'fixed') then k := '1519'; c := 0.85; why := 'Furniture and fittings';
  elsif n ~ '(leasehold improvement)' then k := '1526'; c := 0.85; why := 'Leasehold improvements';
  elsif n ~ '(tools|equipment)' and (v_asset or t ~ 'fixed') then k := '1513'; c := 0.75; why := 'Tools and equipment';
  elsif n ~ '(goodwill)' then k := '1601'; c := 0.85; why := 'Goodwill';
  elsif n ~ '(software|website development)' and v_asset then k := '1607'; c := 0.8; why := 'Software';
  elsif n ~ '(trademark|patent|intangible)' and v_asset then k := '1610'; c := 0.75; why := 'Intangible assets';
  elsif t ~ 'fixed' then k := '1527'; c := 0.6; why := 'Other property, plant and equipment';
  -- Payables and other liabilities
  elsif t ~ 'payable' and t !~ 'other' or n ~ '(accounts payable|trade payable|creditors|\ma/p\M|trade creditors)' then
    k := case when n ~ '(foreign|import|usd)' then '2102' else '2101' end; c := 0.95; why := 'Trade payables (control account)';
  elsif n ~ '(accrual|accrued)' then k := '2103'; c := 0.85; why := 'Accrued expenses';
  elsif n ~ '(paye|pay as you earn)' then k := '2203'; c := 0.9; why := 'PAYE payable';
  elsif n ~ '(pension)' and (v_liab or p_balance < 0) then k := '2204'; c := 0.85; why := 'Pension payable';
  elsif n ~ '(\mnhf\M|housing fund)' then k := '2205'; c := 0.9; why := 'NHF payable';
  elsif n ~ '(nsitf)' then k := '2206'; c := 0.9; why := 'NSITF payable';
  elsif n ~ '(\mitf\M|industrial training)' then k := '2207'; c := 0.9; why := 'ITF payable';
  elsif n ~ '(education tax|tertiary|development levy)' and (v_liab or p_balance < 0) then k := '2209'; c := 0.85; why := 'Development levy / education tax payable';
  elsif n ~ '(income tax|company tax|companies income|\mcit\M)' and (v_liab or p_balance < 0) then k := '2208'; c := 0.85; why := 'Income tax payable';
  elsif n ~ '(customer deposit|unearned|deferred revenue|deferred income|advance from customer|customer advance)' then k := '2107'; c := 0.85; why := 'Advances from customers';
  elsif n ~ '(dividend)' and (v_liab or p_balance < 0) then k := '2108'; c := 0.85; why := 'Dividend payable';
  elsif n ~ '(lease liabilit)' then k := case when n ~ '(non-current|long)' then '2504' else '2304' end; c := 0.8; why := 'Lease liabilities';
  elsif n ~ '(shareholder|related party)' and n ~ '(loan)' then k := '2502'; c := 0.85; why := 'Loans from shareholders';
  elsif n ~ '(loan|borrowing)' then k := case when t ~ '(long|non-current)' or n ~ '(long|term loan)' then '2501' else '2302' end; c := 0.75; why := 'Borrowings';
  elsif t ~ 'credit card' or n ~ 'credit card' then k := '2302'; c := 0.75; why := 'Credit card balance (short-term borrowing)';
  -- Equity
  elsif n ~ '(opening balance equity|opening bal)' then k := '3999'; c := 0.7; why := 'Opening balance equity: split it into capital and reserves when you can';
  elsif n ~ '(share premium)' then k := '3003'; c := 0.9; why := 'Share premium';
  elsif n ~ '(share capital|capital stock|common stock|ordinary share|issued capital|paid.?up capital)' then k := '3001'; c := 0.9; why := 'Share capital';
  elsif n ~ '(retained|accumulated profit|accumulated loss|profit and loss account|revenue reserve)' then k := '3005'; c := 0.9; why := 'Retained earnings';
  elsif n ~ '(drawing|owner.?s? (equity|capital|contribution|investment)|capital account)' then k := '3005'; c := 0.6; why := 'Owner''s capital and drawings (check how it should be shown)';
  elsif n ~ '(reserve)' and v_eq then k := '3015'; c := 0.7; why := 'Other reserves';
  -- Income
  elsif n ~ '(discount allowed|sales discount)' then k := '4132'; c := 0.85; why := 'Discounts allowed';
  elsif n ~ '(sales return|returns inward|refund)' and (v_inc or p_balance > 0) then k := '4131'; c := 0.85; why := 'Sales returns';
  elsif n ~ '(interest)' and (v_inc or p_balance < 0) and not v_exp then k := '4502'; c := 0.85; why := 'Interest income';
  elsif n ~ '(rent)' and v_inc then k := '4504'; c := 0.85; why := 'Rental income';
  elsif n ~ '(commission)' and v_inc then k := '4501'; c := 0.85; why := 'Commission income';
  elsif n ~ '(exchange|forex|\mfx\M)' and (v_inc or p_balance < 0) and not v_exp then k := '4510'; c := 0.8; why := 'Foreign exchange gains';
  elsif n ~ '(gain on (sale|disposal))' then k := '4508'; c := 0.85; why := 'Gain on disposal of assets';
  elsif t ~ 'other income' or n ~ '(other income|sundry income|miscellaneous income)' then k := '4516'; c := 0.75; why := 'Other income';
  elsif v_inc or n ~ '(^sales|revenue|turnover|income from|fees earned|service income)' then k := v_rev; c := 0.85; why := 'Revenue';
  -- Cost of sales
  elsif n ~ '(carriage in|freight in|clearing|haulage in)' then k := '5104'; c := 0.8; why := 'Carriage inwards';
  elsif n ~ '(import dut|customs dut|landing)' then k := '5105'; c := 0.85; why := 'Import duties';
  elsif n ~ '(direct labour|direct labor|direct wage)' then k := '5201'; c := 0.85; why := 'Direct wages';
  elsif n ~ '(subcontract)' then k := '5203'; c := 0.8; why := 'Subcontractors';
  elsif n ~ '(purchase return|returns outward)' then k := '5103'; c := 0.85; why := 'Purchase returns';
  elsif v_cogs or n ~ '(cost of goods sold|cost of sales|\mcogs\M|purchases)' then k := '5101'; c := 0.85; why := 'Cost of sales';
  -- Taxes on profit
  elsif n ~ '(deferred tax)' then k := case when v_asset or (p_balance > 0 and not v_exp) then '1803' when v_liab then '2601' else '7503' end; c := 0.75; why := 'Deferred tax';
  elsif n ~ '(education tax|tertiary|development levy)' then k := '7502'; c := 0.8; why := 'Development levy / education tax';
  elsif n ~ '(income tax|company tax|companies income|\mcit\M|taxation)' then k := '7501'; c := 0.8; why := 'Income tax expense';
  -- Operating expenses
  elsif n ~ '(salar|wage|payroll)' then k := '6101'; c := 0.9; why := 'Salaries and wages';
  elsif n ~ '(allowance)' and not v_asset then k := '6102'; c := 0.8; why := 'Staff allowances';
  elsif n ~ '(pension)' then k := '6104'; c := 0.85; why := 'Employer pension';
  elsif n ~ '(gratuity)' then k := '6105'; c := 0.85; why := 'Gratuity';
  elsif n ~ '(medical|hmo|health insurance)' then k := '6106'; c := 0.85; why := 'Medical';
  elsif n ~ '(training|course|seminar)' then k := '6107'; c := 0.85; why := 'Training';
  elsif n ~ '(staff welfare|welfare|canteen|refreshment)' then k := '6108'; c := 0.8; why := 'Staff welfare';
  elsif n ~ '(director)' and n ~ '(fee|remuneration|emolument|salary)' then k := '6109'; c := 0.9; why := 'Directors'' emoluments';
  elsif n ~ '(recruit)' then k := '6113'; c := 0.85; why := 'Recruitment';
  elsif n ~ '(rent)' then k := '6201'; c := 0.85; why := 'Rent';
  elsif n ~ '(rates|tenement)' then k := '6202'; c := 0.8; why := 'Rates';
  elsif n ~ '(service charge)' then k := '6203'; c := 0.85; why := 'Service charge';
  elsif n ~ '(water)' then k := '6204'; c := 0.8; why := 'Water';
  elsif n ~ '(electric|power|phcn|nepa|ikedc|ekedc|aedc|prepaid meter)' then k := '6205'; c := 0.85; why := 'Electricity';
  elsif n ~ '(diesel|\mago\M)' then k := '6206'; c := 0.9; why := 'Diesel';
  elsif n ~ '(fuel|petrol|\mpms\M)' then k := '6207'; c := 0.85; why := 'Fuel';
  elsif n ~ '(generator)' then k := '6208'; c := 0.85; why := 'Generator running';
  elsif n ~ '(repair|maintenance)' then k := '6209'; c := 0.8; why := 'Repairs and maintenance';
  elsif n ~ '(clean|janitor)' then k := '6210'; c := 0.85; why := 'Cleaning';
  elsif n ~ '(security)' then k := '6211'; c := 0.85; why := 'Security';
  elsif n ~ '(stationer|printing)' then k := '6212'; c := 0.85; why := 'Stationery and printing';
  elsif n ~ '(postage|courier|dispatch)' then k := '6213'; c := 0.85; why := 'Postage and courier';
  elsif n ~ '(insurance)' then k := '6215'; c := 0.85; why := 'Insurance';
  elsif n ~ '(office)' then k := '6216'; c := 0.7; why := 'Office expenses';
  elsif n ~ '(telephone|phone|airtime|communication)' then k := '6301'; c := 0.85; why := 'Telephone';
  elsif n ~ '(internet|data|broadband)' then k := '6302'; c := 0.85; why := 'Internet and data';
  elsif n ~ '(software|subscription|saas|licence fee)' then k := '6303'; c := 0.8; why := 'Software subscriptions';
  elsif n ~ '(website|hosting|domain)' then k := '6304'; c := 0.8; why := 'Website';
  elsif n ~ '(it support|computer maintenance)' then k := '6305'; c := 0.8; why := 'IT support';
  elsif n ~ '(advert|marketing|promotion|branding)' then k := '6401'; c := 0.85; why := 'Advertising and marketing';
  elsif n ~ '(entertainment)' then k := '6409'; c := 0.85; why := 'Entertainment';
  elsif n ~ '(gift)' then k := '6410'; c := 0.8; why := 'Gifts';
  elsif n ~ '(audit)' then k := '6501'; c := 0.9; why := 'Audit fees';
  elsif n ~ '(accounting fee|accountancy|bookkeeping)' then k := '6502'; c := 0.85; why := 'Accountancy fees';
  elsif n ~ '(legal)' then k := '6503'; c := 0.85; why := 'Legal fees';
  elsif n ~ '(consult)' then k := '6504'; c := 0.85; why := 'Consultancy';
  elsif n ~ '(professional)' then k := '6507'; c := 0.8; why := 'Professional fees';
  elsif n ~ '(cac|secretarial|annual return|filing fee)' then k := '6506'; c := 0.85; why := 'Secretarial and CAC fees';
  elsif n ~ '(licen|permit)' then k := '6509'; c := 0.8; why := 'Licences and permits';
  elsif n ~ '(dues|membership)' then k := '6510'; c := 0.8; why := 'Subscriptions and dues';
  elsif n ~ '(fine)' then k := '6513'; c := 0.8; why := 'Fines';
  elsif n ~ '(penalt)' then k := '6514'; c := 0.8; why := 'Penalties';
  elsif n ~ '(international travel|foreign travel|overseas)' then k := '6603'; c := 0.85; why := 'International travel';
  elsif n ~ '(travel)' then k := '6602'; c := 0.85; why := 'Travel';
  elsif n ~ '(hotel|accommodation|lodging)' then k := '6604'; c := 0.85; why := 'Hotel and accommodation';
  elsif n ~ '(vehicle running|motor running|motor expense|vehicle expense|car expense)' then k := '6605'; c := 0.85; why := 'Vehicle running costs';
  elsif n ~ '(freight|delivery|shipping|carriage out|logistics|transport)' then k := case when n ~ '(transport|logistics)' then '6601' else '6606' end; c := 0.8; why := 'Transport and delivery';
  elsif n ~ '(bank charge|bank fee|charges|commission on turnover|\mcot\M|transfer fee|sms alert|stamp duty)' then k := '6701'; c := 0.85; why := 'Bank charges';
  elsif n ~ '(interest)' then k := '6702'; c := 0.8; why := 'Interest expense';
  elsif n ~ '(exchange|forex|\mfx\M)' then k := '6703'; c := 0.8; why := 'Foreign exchange losses';
  elsif n ~ '(bad debt)' then k := '6801'; c := 0.85; why := 'Bad debts';
  elsif n ~ '(loss on (sale|disposal))' then k := '6804'; c := 0.85; why := 'Loss on disposal';
  elsif n ~ '(amortis|amortiz)' then k := '6903'; c := 0.85; why := 'Amortisation';
  elsif n ~ '(depreciation)' then k := '6901'; c := 0.85; why := 'Depreciation';
  elsif n ~ '(donation|charity|csr)' then k := '6904'; c := 0.85; why := 'Donations';
  elsif n ~ '(research)' then k := '6905'; c := 0.8; why := 'Research';
  elsif n ~ '(sundr|miscellaneous|general expense|other expense)' then k := '6907'; c := 0.65; why := 'Sundry expenses';
  -- By type only
  elsif v_exp then k := '6907'; c := 0.4; why := 'An expense the rules could not place';
  elsif v_inc then k := '4516'; c := 0.45; why := 'Income the rules could not place';
  elsif v_eq then k := '3015'; c := 0.4; why := 'Equity the rules could not place';
  elsif v_liab then k := '2104'; c := 0.4; why := 'A liability the rules could not place';
  elsif v_asset then k := '1308'; c := 0.4; why := 'An asset the rules could not place';
  else k := null; c := 0; why := 'Not recognised: choose the Counta account';
  end if;
  if k is not null and not private.postable(p_org, k) and k not in ('1011', '1012', '1013', '1014') then
    k := null; c := 0; why := why || '; the usual account is not open in this chart';
  end if;
  return query select k, c, why, coalesce(k in ('1011', '1012', '1013', '1014'), false);
end $$;

-- ---------------------------------------------------------------------------
-- 2b. Cash flows start from the balances brought in, not through them
-- ---------------------------------------------------------------------------
-- Movement for the statement of cash flows: no year-end closing entries and no migration entries.
create or replace function private.movement_cf(p_org uuid, p_from date, p_to date) returns table (code text, dr numeric, cr numeric, net numeric)
language sql stable security definer set search_path = public, private as $$
  select l.account_code, sum(l.debit), sum(l.credit), sum(l.debit - l.credit) from journal_lines l join journals j on j.id = l.journal_id
  where l.org_id = p_org and j.entry_date between p_from and p_to and j.source_type is distinct from 'year_end' and j.source_type is distinct from 'migration'
  group by l.account_code
$$;
revoke all on function private.movement_cf(uuid, date, date) from public, anon, authenticated;

create or replace function private.cash_flow_parts(p_org uuid, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = public, private as $$
  with meta as (select * from private.acct_meta(p_org)),
  cashacc as (select code from meta where ifrs_line = 'Cash and cash equivalents'),
  jl as (select l.*, j.source_type from journal_lines l join journals j on j.id = l.journal_id
         where l.org_id = p_org and j.entry_date between p_from and p_to and j.source_type is distinct from 'year_end' and j.source_type is distinct from 'migration'),
  -- Balances brought in from the old system are where Counta's cash flows start, not cash flows themselves.
  mig as (select l.account_code code, sum(l.debit - l.credit) amt from journal_lines l join journals j on j.id = l.journal_id
          where l.org_id = p_org and j.entry_date between p_from and p_to and j.source_type = 'migration' group by 1),
  cj as (select journal_id, sum(debit - credit) cash from jl where account_code in (select code from cashacc) group by journal_id having sum(debit - credit) <> 0),
  -- Only lines on the other side from the cash take a share of it (a WHT line beside a payment does not).
  counter as (
    -- Payables settled for a bill count as what the bill bought.
    select l.journal_id, abs(bl.gross / nullif(b.total, 0) * (l.debit - l.credit)) w, coalesce(m.cf, 'system') cf, coalesce(m.ifrs_line, 'Unclassified') line, l.source_type
    from jl l join cj on cj.journal_id = l.journal_id join bills b on b.id = l.doc_id and l.doc_type = 'bill' join bill_lines bl on bl.bill_id = b.id
    left join meta m on m.code = bl.account_code
    where l.account_code in ('2101', '2102') and sign(l.debit - l.credit) = -sign(cj.cash)
    union all
    select l.journal_id, abs(l.debit - l.credit), case when l.source_type = 'asset_disposal' then 'investing' else coalesce(m.cf, 'system') end,
      coalesce(m.ifrs_line, 'Unclassified'), l.source_type
    from jl l join cj on cj.journal_id = l.journal_id left join meta m on m.code = l.account_code
    where l.account_code not in (select code from cashacc) and sign(l.debit - l.credit) = -sign(cj.cash)
      and not (l.account_code in ('2101', '2102') and l.doc_type = 'bill')),
  tot as (select journal_id, sum(w) w from counter group by journal_id),
  alloc as (
    select c.journal_id, cj.cash * c.w / nullif(t.w, 0) amt,
      case when c.cf in ('investing', 'investing_gain') then 'investing' when c.cf in ('financing', 'equity_other') then 'financing'
           when c.cf = 'tax_paid' then 'tax' else 'operating' end section, c.line
    from counter c join tot t on t.journal_id = c.journal_id join cj on cj.journal_id = c.journal_id where t.w > 0)
  select jsonb_build_object(
    'operating_direct', coalesce((select sum(amt) from alloc where section in ('operating', 'tax')), 0),
    'tax_paid', coalesce((select sum(amt) from alloc where section = 'tax'), 0),
    'investing', coalesce((select jsonb_object_agg(k, v) from (select case when line = 'Property, plant and equipment' and sum(amt) < 0 then 'Purchase of property, plant and equipment'
        when line = 'Property, plant and equipment' then 'Proceeds from disposal of property, plant and equipment'
        when line = 'Intangible assets' then 'Purchase of intangible assets'
        when line in ('Other income', 'Other gains and losses', 'Other expenses') then 'Proceeds from disposal of property, plant and equipment'
        else line end k, sum(amt) v from alloc where section = 'investing' group by line) x), '{}'::jsonb),
    'financing', coalesce((select jsonb_object_agg(k, v) from (select case line when 'Share capital' then 'Proceeds from issue of shares'
        when 'Share premium' then 'Proceeds from issue of shares' when 'Deposit for shares' then 'Deposits for shares received'
        when 'Retained earnings' then 'Dividends and drawings paid' when 'Opening balances to be confirmed' then 'Owner''s funds introduced or withdrawn'
        when 'Trade and other payables' then 'Dividends paid' else line end k, sum(amt) v from alloc where section = 'financing' group by 1) x), '{}'::jsonb),
    'cash_open', (select coalesce(sum(b.bal), 0) from private.balances_at(p_org, p_from - 1) b where b.code in (select code from cashacc))
      + (select coalesce(sum(amt), 0) from mig where code in (select code from cashacc)),
    'migrated_pbt', (select coalesce(-sum(mig.amt), 0) from mig join meta m on m.code = mig.code where m.statement = 'pl' and m.ifrs_line <> 'Income tax expense'),
    'cash_close', (select coalesce(sum(b.bal), 0) from private.balances_at(p_org, p_to) b where b.code in (select code from cashacc)),
    'depreciation', (select coalesce(sum(mv.net), 0) from private.movement_cf(p_org, p_from, p_to) mv where mv.code in ('6901', '6902', '6903', '5204', '5205')),
    'impairment', (select coalesce(sum(mv.net), 0) from private.movement_cf(p_org, p_from, p_to) mv where mv.code in ('6802', '6803', '6805', '6704', '4511', '4515', '4507')),
    'disposal_result', (select coalesce(sum(mv.net), 0) from private.movement_cf(p_org, p_from, p_to) mv where mv.code in ('4508', '6804', '4506')),
    'wc', (select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from (select m.ifrs_line k, -sum(mv.net) v from private.movement_cf(p_org, p_from, p_to) mv
        join meta m on m.code = mv.code where m.cf = 'working_capital' group by m.ifrs_line) x))
$$;

create or replace function private.cash_flow_rows(p_org uuid, p_from date, p_to date, p_pfrom date, p_pto date) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare c jsonb := private.cash_flow_parts(p_org, p_from, p_to); p jsonb; v jsonb := '[]'::jsonb; pc jsonb; pp jsonb; k text; v_op numeric; v_opp numeric;
  v_inv numeric; v_invp numeric; v_fin numeric; v_finp numeric; v_other numeric; v_otherp numeric; v_ind numeric; v_indp numeric; v_keys text[];
begin
  p := case when p_pfrom is null then '{}'::jsonb else private.cash_flow_parts(p_org, p_pfrom, p_pto) end;
  pc := private.pl_totals(private.pl_map(p_org, p_from, p_to));
  pp := case when p_pfrom is null then '{}'::jsonb else private.pl_totals(private.pl_map(p_org, p_pfrom, p_pto)) end;
  v := v || private.fr('Cash flows from operating activities', null, null, 'heading', 0)
    || private.fr('Profit before tax', private.v(pc, 'profit_before_tax'), private.v(pp, 'profit_before_tax'), 'line', 1)
    || case when private.v(c, 'migrated_pbt') <> 0 or private.v(p, 'migrated_pbt') <> 0 then jsonb_build_array(private.fr(
         'Less profit before the move to Counta, whose cash flows were recorded in the previous system', -private.v(c, 'migrated_pbt'), -private.v(p, 'migrated_pbt'), 'line', 1))
       else '[]'::jsonb end
    || private.fr('Adjustments for:', null, null, 'subheading', 1)
    || private.fr('Depreciation and amortisation', private.v(c, 'depreciation'), private.v(p, 'depreciation'), 'line', 2)
    || private.fr('Impairment and write-downs', private.v(c, 'impairment'), private.v(p, 'impairment'), 'line', 2)
    || private.fr('(Gain) / loss on disposal of assets', private.v(c, 'disposal_result'), private.v(p, 'disposal_result'), 'line', 2)
    || private.fr('Changes in working capital:', null, null, 'subheading', 1);
  v_ind := private.v(pc, 'profit_before_tax') - private.v(c, 'migrated_pbt') + private.v(c, 'depreciation') + private.v(c, 'impairment') + private.v(c, 'disposal_result');
  v_indp := private.v(pp, 'profit_before_tax') - private.v(p, 'migrated_pbt') + private.v(p, 'depreciation') + private.v(p, 'impairment') + private.v(p, 'disposal_result');
  select array_agg(distinct key) into v_keys from (select key from jsonb_each(c->'wc') union select key from jsonb_each(coalesce(p->'wc', '{}'::jsonb))) x;
  foreach k in array coalesce(v_keys, '{}') loop
    v := v || private.fr(case when k in (select unnest(private.asset_lines())) then '(Increase) / decrease in ' || lower(k) else 'Increase / (decrease) in ' || lower(k) end,
      private.v(c->'wc', k), private.v(p->'wc', k), 'line', 2);
    v_ind := v_ind + private.v(c->'wc', k); v_indp := v_indp + private.v(p->'wc', k);
  end loop;
  v_op := private.v(c, 'operating_direct'); v_opp := private.v(p, 'operating_direct');
  -- Whatever the indirect method does not explain (accruals moved between heads, journals with no cash in them) is shown, not hidden.
  v_other := v_op - private.v(c, 'tax_paid') - v_ind; v_otherp := v_opp - private.v(p, 'tax_paid') - v_indp;
  if abs(v_other) >= 0.01 or abs(v_otherp) >= 0.01 then
    v := v || private.fr('Other non-cash items', v_other, v_otherp, 'line', 2);
  end if;
  v := v || private.fr('Cash generated from operations', v_op - private.v(c, 'tax_paid'), v_opp - private.v(p, 'tax_paid'), 'subtotal', 1)
    || private.fr('Income taxes paid', private.v(c, 'tax_paid'), private.v(p, 'tax_paid'), 'line', 1)
    || private.fr('Net cash from operating activities', v_op, v_opp, 'subtotal', 0)
    || private.fr('Cash flows from investing activities', null, null, 'heading', 0);
  v_inv := 0; v_invp := 0;
  select array_agg(distinct key) into v_keys from (select key from jsonb_each(c->'investing') union select key from jsonb_each(coalesce(p->'investing', '{}'::jsonb))) x;
  foreach k in array coalesce(v_keys, '{}') loop
    v := v || private.fr(k, private.v(c->'investing', k), private.v(p->'investing', k), 'line', 1);
    v_inv := v_inv + private.v(c->'investing', k); v_invp := v_invp + private.v(p->'investing', k);
  end loop;
  v := v || private.fr('Net cash used in investing activities', v_inv, v_invp, 'subtotal', 0) || private.fr('Cash flows from financing activities', null, null, 'heading', 0);
  v_fin := 0; v_finp := 0;
  select array_agg(distinct key) into v_keys from (select key from jsonb_each(c->'financing') union select key from jsonb_each(coalesce(p->'financing', '{}'::jsonb))) x;
  foreach k in array coalesce(v_keys, '{}') loop
    v := v || private.fr(k, private.v(c->'financing', k), private.v(p->'financing', k), 'line', 1);
    v_fin := v_fin + private.v(c->'financing', k); v_finp := v_finp + private.v(p->'financing', k);
  end loop;
  v := v || private.fr('Net cash from financing activities', v_fin, v_finp, 'subtotal', 0)
    || private.fr('Net increase / (decrease) in cash and cash equivalents', v_op + v_inv + v_fin, v_opp + v_invp + v_finp, 'subtotal', 0)
    || private.fr('Cash and cash equivalents at the start of the period', private.v(c, 'cash_open'), private.v(p, 'cash_open'), 'line', 0)
    || private.fr('Cash and cash equivalents at the end of the period', private.v(c, 'cash_open') + v_op + v_inv + v_fin,
         private.v(p, 'cash_open') + v_opp + v_invp + v_finp, 'total', 0, private.note_no('cash'));
  return jsonb_build_object('rows', v, 'check', jsonb_build_object('computed_close', private.v(c, 'cash_open') + v_op + v_inv + v_fin, 'ledger_close', private.v(c, 'cash_close'),
    'ties', abs(private.v(c, 'cash_open') + v_op + v_inv + v_fin - private.v(c, 'cash_close')) < 0.01));
end $$;


-- ---------------------------------------------------------------------------
-- 3. Working on a migration
-- ---------------------------------------------------------------------------
create or replace function private.migration_member(p_org uuid) returns public.members
language plpgsql security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not (m.role = 'owner' or private.perm_of(m, 'keep_books')) then
    raise exception 'Only the owner or the bookkeeper moves the books into Counta.' using errcode = '42501';
  end if;
  return m;
end $$;

-- Starts the migration, or changes the source and cut-over date of the one in progress.
create or replace function public.start_books_migration(p_org uuid, p_source text, p_as_of date) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; b public.books_migrations; v_closed date;
begin
  m := private.migration_member(p_org);
  if p_source not in ('quickbooks', 'zoho', 'xero', 'sage', 'other') then raise exception 'Choose QuickBooks, Zoho Books, Xero or Sage.'; end if;
  if p_as_of is null then raise exception 'Choose the cut-over date.'; end if;
  if p_as_of > private.local_day(p_org, now()) then raise exception 'The cut-over date cannot be in the future.'; end if;
  v_closed := private.closed_through(p_org);
  if v_closed is not null and p_as_of <= v_closed then raise exception 'The books are closed up to %. Choose a later cut-over date.', private.fdate(v_closed); end if;
  select * into b from books_migrations where org_id = p_org and status = 'draft';
  if found then
    update books_migrations set source = p_source, as_of = p_as_of where id = b.id;
  else
    insert into books_migrations (org_id, source, as_of, created_by) values (p_org, p_source, p_as_of, m.id) returning * into b;
  end if;
  return public.get_books_migration(p_org);
end $$;

-- rows: [{code, name, type, debit, credit}] or [{code, name, type, balance}] (debit positive). Replaces what was uploaded before.
create or replace function public.set_migration_trial_balance(p_migration uuid, p_rows jsonb, p_file text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.books_migrations; m public.members; x jsonb; v_no int := 0; v_code text; v_name text; v_dr numeric; v_cr numeric; v_bal numeric; g record;
begin
  select * into b from books_migrations where id = p_migration for update;
  if not found then raise exception 'Migration not found.'; end if;
  m := private.migration_member(b.org_id);
  if b.status <> 'draft' then raise exception 'This migration has already posted.'; end if;
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'The trial balance has no rows.'; end if;
  if jsonb_array_length(p_rows) > 2000 then raise exception 'A trial balance can have up to 2,000 accounts.'; end if;
  delete from migration_accounts where migration_id = b.id;
  for x in select * from jsonb_array_elements(p_rows) loop
    v_name := left(regexp_replace(trim(coalesce(x->>'name', '')), '\s+', ' ', 'g'), 200);
    v_code := nullif(left(trim(coalesce(x->>'code', '')), 40), '');
    -- "1000 · Cash", "1000 - Cash" or "Cash (1000)": the code is taken out of the name.
    if v_code is null and v_name ~ '^\d{2,10}\s*[·\-:.]?\s+\S' then v_code := substring(v_name from '^(\d{2,10})'); v_name := regexp_replace(v_name, '^\d{2,10}\s*[·\-:.]?\s+', ''); end if;
    if v_code is null and v_name ~ '\((\d{2,10})\)\s*$' then v_code := substring(v_name from '\((\d{2,10})\)\s*$'); v_name := trim(regexp_replace(v_name, '\(\d{2,10}\)\s*$', '')); end if;
    continue when v_name = '' or v_name ~* '^(total|totals|net income|grand total)\M';
    v_dr := round(coalesce(private.num(x->>'debit'), 0), 2); v_cr := round(coalesce(private.num(x->>'credit'), 0), 2);
    if x ? 'balance' and nullif(x->>'balance', '') is not null then
      v_bal := round(private.num(x->>'balance'), 2);
      v_dr := greatest(v_bal, 0); v_cr := greatest(-v_bal, 0);
    end if;
    -- A negative debit is a credit, and the other way round.
    if v_dr < 0 then v_cr := v_cr - v_dr; v_dr := 0; end if;
    if v_cr < 0 then v_dr := v_dr - v_cr; v_cr := 0; end if;
    if v_dr > 0 and v_cr > 0 then
      if v_dr >= v_cr then v_dr := v_dr - v_cr; v_cr := 0; else v_cr := v_cr - v_dr; v_dr := 0; end if;
    end if;
    continue when v_dr = 0 and v_cr = 0;
    v_no := v_no + 1;
    select * into g from private.guess_account(b.org_id, v_name, x->>'type', v_dr - v_cr);
    insert into migration_accounts (migration_id, org_id, line_no, source_code, source_name, source_type, debit, credit, mapped_code, new_bank, bank_name,
      confidence, reason, mapped_by, confirmed)
    values (b.id, b.org_id, v_no, v_code, v_name, nullif(left(trim(coalesce(x->>'type', '')), 60), ''), v_dr, v_cr, g.code, g.new_bank,
      case when g.new_bank then v_name end, g.confidence, g.reason, case when g.code is not null then 'rule' end, coalesce(g.confidence, 0) >= 0.8);
  end loop;
  if v_no = 0 then raise exception 'No account in the file has a balance.'; end if;
  update books_migrations set tb_file = left(nullif(trim(p_file), ''), 200) where id = b.id;
  return public.get_books_migration(b.org_id);
end $$;

-- A person chooses the account (or a new bank account). Confirmed from then on, whatever the AI says later.
create or replace function public.map_migration_account(p_line uuid, p_code text, p_bank_name text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.migration_accounts; b public.books_migrations; m public.members; v_new boolean := false;
begin
  select * into l from migration_accounts where id = p_line for update;
  if not found then raise exception 'Account line not found.'; end if;
  select * into b from books_migrations where id = l.migration_id;
  m := private.migration_member(b.org_id);
  if b.status <> 'draft' then raise exception 'This migration has already posted.'; end if;
  if p_code in ('1011', '1012', '1013', '1014') then
    v_new := true;
    if coalesce(trim(p_bank_name), '') = '' then raise exception 'Name the new account.'; end if;
  elsif not private.postable(b.org_id, p_code) then
    raise exception 'Account % cannot take postings. Choose an account that is not a heading.', coalesce(p_code, '(none)');
  end if;
  update migration_accounts set mapped_code = p_code, new_bank = v_new, bank_name = case when v_new then left(trim(p_bank_name), 120) end,
    mapped_by = 'person', confidence = 1, reason = 'Chosen by ' || m.display_name, confirmed = true where id = l.id;
  return public.get_books_migration(b.org_id);
end $$;

-- Accepts suggestions a person has looked at (the ones under 80% sure need this before posting).
create or replace function public.confirm_migration_accounts(p_migration uuid, p_lines uuid[]) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.books_migrations; m public.members;
begin
  select * into b from books_migrations where id = p_migration;
  if not found then raise exception 'Migration not found.'; end if;
  m := private.migration_member(b.org_id);
  if b.status <> 'draft' then raise exception 'This migration has already posted.'; end if;
  update migration_accounts set confirmed = true where migration_id = b.id and id = any(p_lines) and mapped_code is not null;
  return public.get_books_migration(b.org_id);
end $$;

-- The AI's suggestions: [{id, code, confidence, reason}]. Never overrides a person's choice.
create or replace function public.migration_ai_map(p_migration uuid, p_maps jsonb, p_model text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.books_migrations; m public.members; x jsonb; v_c numeric; v_code text; n int := 0;
begin
  select * into b from books_migrations where id = p_migration;
  if not found then raise exception 'Migration not found.'; end if;
  m := private.migration_member(b.org_id);
  if b.status <> 'draft' then raise exception 'This migration has already posted.'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_maps, '[]'::jsonb)) loop
    v_code := nullif(trim(x->>'code'), '');
    v_c := least(greatest(coalesce(private.num(x->>'confidence'), 0), 0), 1);
    continue when v_code is null or not (private.postable(b.org_id, v_code) or v_code in ('1011', '1012', '1013', '1014'));
    update migration_accounts l set mapped_code = v_code, new_bank = v_code in ('1011', '1012', '1013', '1014'),
      bank_name = case when v_code in ('1011', '1012', '1013', '1014') then coalesce(l.bank_name, l.source_name) end,
      confidence = v_c, reason = left(coalesce(nullif(trim(x->>'reason'), ''), 'Suggested by the AI'), 300) || coalesce(' (' || p_model || ')', ''),
      mapped_by = 'ai', confirmed = v_c >= 0.8
    where l.id = nullif(x->>'id', '')::uuid and l.migration_id = b.id and l.mapped_by is distinct from 'person'
      -- Only where the AI is surer than the rule was.
      and (l.mapped_code is null or coalesce(l.confidence, 0) < v_c);
    if found then n := n + 1; end if;
  end loop;
  return public.get_books_migration(b.org_id) || jsonb_build_object('ai_updated', n);
end $$;

-- rows: [{party, number, issue_date, due_date, amount}] where amount is what is still unpaid. Replaces earlier uploads of that kind.
create or replace function public.set_migration_open_items(p_migration uuid, p_kind text, p_rows jsonb, p_file text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.books_migrations; m public.members; x jsonb; v_no int := 0; v_amt numeric; v_issue date; v_due date; v_party text;
begin
  select * into b from books_migrations where id = p_migration for update;
  if not found then raise exception 'Migration not found.'; end if;
  m := private.migration_member(b.org_id);
  if b.status <> 'draft' then raise exception 'This migration has already posted.'; end if;
  if p_kind not in ('invoice', 'bill') then raise exception 'Upload unpaid invoices or unpaid bills.'; end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'No rows.'; end if;
  if jsonb_array_length(p_rows) > 5000 then raise exception 'Up to 5,000 open items at a time.'; end if;
  delete from migration_open_items where migration_id = b.id and kind = p_kind;
  for x in select * from jsonb_array_elements(p_rows) loop
    v_party := left(regexp_replace(trim(coalesce(x->>'party', '')), '\s+', ' ', 'g'), 120);
    v_amt := round(coalesce(private.num(x->>'amount'), 0), 2);
    continue when v_party = '' or v_party ~* '^(total|totals|grand total)\M' or v_amt <= 0;
    v_issue := private.date_or_null(x->>'issue_date'); v_due := private.date_or_null(x->>'due_date');
    if v_issue is not null and v_issue > b.as_of then raise exception '% % is dated after the cut-over date.', case when p_kind = 'invoice' then 'Invoice' else 'Bill' end, coalesce(x->>'number', v_party); end if;
    v_no := v_no + 1;
    insert into migration_open_items (migration_id, org_id, kind, line_no, party_name, number, issue_date, due_date, amount)
    values (b.id, b.org_id, p_kind, v_no, v_party, nullif(left(trim(coalesce(x->>'number', '')), 60), ''), coalesce(v_issue, b.as_of),
      coalesce(v_due, v_issue, b.as_of), v_amt);
  end loop;
  update books_migrations set ar_file = case when p_kind = 'invoice' then left(nullif(trim(p_file), ''), 200) else ar_file end,
    ap_file = case when p_kind = 'bill' then left(nullif(trim(p_file), ''), 200) else ap_file end where id = b.id;
  return public.get_books_migration(b.org_id);
end $$;

-- Customers from the old system: [{name, phone, email, tin, address, city, state, country, contact_person, credit_limit, terms_days}].
-- Matched by phone, then email, then name; existing customers are filled in, not overwritten.
create or replace function public.import_customers(p_org uuid, p_rows jsonb, p_options jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; x jsonb; v_id uuid; v_created int := 0; v_updated int := 0; v_skipped jsonb := '[]'::jsonb; v_i int := 0; v_phone text; v_email text; v_name text;
  c public.customers;
begin
  m := private.require(p_org, 'record_sales');
  if jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'No rows to import.'; end if;
  if jsonb_array_length(p_rows) > 2000 then raise exception 'Send at most 2,000 customers at a time.'; end if;
  for x in select * from jsonb_array_elements(p_rows) loop
    v_i := v_i + 1;
    v_name := left(regexp_replace(trim(coalesce(x->>'name', '')), '\s+', ' ', 'g'), 120);
    if v_name = '' then v_skipped := v_skipped || jsonb_build_object('row', v_i, 'reason', 'No name'); continue; end if;
    v_phone := private.clean_phone(x->>'phone');
    v_email := nullif(lower(trim(x->>'email')), '');
    if v_email is not null and v_email !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' then v_email := null; end if;
    select * into c from customers where org_id = p_org and not archived and not is_walk_in and (
      (v_phone is not null and phone = v_phone) or (v_email is not null and lower(email) = v_email) or lower(name) = lower(v_name))
    order by (v_phone is not null and phone = v_phone) desc, (v_email is not null and lower(email) = v_email) desc limit 1;
    begin
      if c.id is null then
        v_id := private.upsert_customer(p_org, jsonb_strip_nulls(jsonb_build_object('name', v_name, 'kind', coalesce(nullif(x->>'kind', ''), 'business'), 'phone', v_phone, 'email', v_email,
          'tin', nullif(trim(x->>'tin'), ''), 'address', nullif(trim(x->>'address'), ''), 'city', nullif(trim(x->>'city'), ''), 'state', nullif(trim(x->>'state'), ''),
          'country', upper(nullif(trim(x->>'country'), '')), 'contact_person', nullif(trim(x->>'contact_person'), ''),
          'credit_limit', case when private.perm_of(m, 'keep_books') or private.perm_of(m, 'approve_adjustments') then private.num(x->>'credit_limit') end,
          'terms_days', case when private.perm_of(m, 'keep_books') or private.perm_of(m, 'approve_adjustments') then private.num(x->>'terms_days')::int end,
          'notes', 'Imported from ' || coalesce(nullif(p_options->>'source', ''), 'a spreadsheet'))), m);
        v_created := v_created + 1;
      else
        update customers set phone = coalesce(phone, v_phone), email = coalesce(email, v_email), tin = coalesce(tin, nullif(trim(x->>'tin'), '')),
          address = coalesce(address, nullif(trim(x->>'address'), '')), city = coalesce(city, nullif(trim(x->>'city'), '')),
          state = coalesce(state, nullif(trim(x->>'state'), '')), contact_person = coalesce(contact_person, nullif(trim(x->>'contact_person'), '')),
          country = case when country = 'NG' and upper(coalesce(nullif(trim(x->>'country'), ''), 'NG')) ~ '^[A-Z]{2}$' then upper(coalesce(nullif(trim(x->>'country'), ''), 'NG')) else country end
        where id = c.id;
        v_updated := v_updated + 1;
      end if;
    exception when others then
      v_skipped := v_skipped || jsonb_build_object('row', v_i, 'name', v_name, 'reason', sqlerrm);
    end;
    c := null;
  end loop;
  return jsonb_build_object('created', v_created, 'updated', v_updated, 'skipped', v_skipped);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Reading it, with the checks that decide whether it can post
-- ---------------------------------------------------------------------------
create or replace function private.migration_stock(p_org uuid, p_as_of date) returns jsonb
language sql stable security definer set search_path = public, private as $$
  -- Opening stock already brought in by item uploads for the same cut-over date, by inventory account.
  select coalesce(jsonb_object_agg(code, amt), '{}'::jsonb) from (
    select l.account_code code, sum(l.debit - l.credit) amt from imports i join journal_lines l on l.journal_id = any(i.journal_ids)
    where i.org_id = p_org and i.kind = 'items' and i.status = 'posted' and i.as_of = p_as_of and l.account_code ~ '^12(0[1-6])'
    group by l.account_code having sum(l.debit - l.credit) <> 0) x
$$;

create or replace function public.get_books_migration(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare b public.books_migrations; v_dr numeric; v_cr numeric; v_ar numeric; v_ap numeric; v_inv numeric; v_oi numeric; v_ob numeric; v_stock jsonb; v_s numeric;
  v_unmapped int; v_unconfirmed int; v_block jsonb := '[]'::jsonb; v_warn jsonb := '[]'::jsonb;
begin
  perform private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Moving the books needs Keep the books.' using errcode = '42501'; end if;
  select * into b from books_migrations where org_id = p_org order by (status = 'draft') desc, created_at desc limit 1;
  if not found then return jsonb_build_object('migration', null, 'history', '[]'::jsonb); end if;
  select coalesce(sum(debit), 0), coalesce(sum(credit), 0),
         coalesce(sum(debit - credit) filter (where split_part(mapped_code, '-', 1) in ('1101', '1102')), 0),
         coalesce(sum(credit - debit) filter (where split_part(mapped_code, '-', 1) in ('2101', '2102')), 0),
         coalesce(sum(debit - credit) filter (where mapped_code ~ '^12(0[1-6])'), 0),
         count(*) filter (where mapped_code is null), count(*) filter (where mapped_code is not null and not confirmed)
    into v_dr, v_cr, v_ar, v_ap, v_inv, v_unmapped, v_unconfirmed
  from migration_accounts where migration_id = b.id;
  select coalesce(sum(amount) filter (where kind = 'invoice'), 0), coalesce(sum(amount) filter (where kind = 'bill'), 0) into v_oi, v_ob
  from migration_open_items where migration_id = b.id;
  v_stock := private.migration_stock(p_org, b.as_of);
  select coalesce(sum(value::numeric), 0) into v_s from jsonb_each_text(v_stock);
  if not exists (select 1 from migration_accounts where migration_id = b.id) then v_block := v_block || '"Upload the trial balance."'::jsonb; end if;
  if abs(v_dr - v_cr) >= 0.01 then v_block := v_block || to_jsonb('The trial balance does not balance: debits ' || private.naira(v_dr) || ', credits ' || private.naira(v_cr) || '.'); end if;
  if v_unmapped > 0 then v_block := v_block || to_jsonb(v_unmapped || ' account(s) still need a Counta account.'); end if;
  if v_unconfirmed > 0 then v_block := v_block || to_jsonb(v_unconfirmed || ' suggestion(s) under 80% sure need you to confirm them.'); end if;
  if abs(v_ar - v_oi) >= 0.01 then v_warn := v_warn || to_jsonb('Unpaid invoices (' || private.naira(v_oi) || ') differ from receivables in the trial balance (' || private.naira(v_ar) || ') by ' || private.naira(v_ar - v_oi) || '.'); end if;
  if abs(v_ap - v_ob) >= 0.01 then v_warn := v_warn || to_jsonb('Unpaid bills (' || private.naira(v_ob) || ') differ from payables in the trial balance (' || private.naira(v_ap) || ') by ' || private.naira(v_ap - v_ob) || '.'); end if;
  if abs(v_inv - v_s) >= 0.01 then v_warn := v_warn || to_jsonb('Stock brought in with items (' || private.naira(v_s) || ') differs from inventory in the trial balance (' || private.naira(v_inv) || ') by ' || private.naira(v_inv - v_s) || '.'); end if;
  return jsonb_build_object(
    'migration', to_jsonb(b) || jsonb_build_object('created_by_name', (select display_name from members where id = b.created_by),
      'posted_by_name', (select display_name from members where id = b.posted_by), 'journal_ref', (select ref from journals where id = b.journal_id)),
    'accounts', (select coalesce(jsonb_agg(to_jsonb(l) - 'org_id' || jsonb_build_object('mapped_name', case when l.new_bank then 'New account: ' || coalesce(l.bank_name, l.source_name)
        else private.account_name(p_org, l.mapped_code) end) order by l.line_no), '[]'::jsonb) from migration_accounts l where l.migration_id = b.id),
    'open_items', (select coalesce(jsonb_agg(to_jsonb(i) - 'org_id' || jsonb_build_object('known', case when i.kind = 'invoice'
        then exists (select 1 from customers c where c.org_id = p_org and not c.archived and lower(c.name) = lower(i.party_name))
        else exists (select 1 from vendors v where v.org_id = p_org and lower(v.name) = lower(i.party_name)) end) order by i.kind, i.line_no), '[]'::jsonb)
      from migration_open_items i where i.migration_id = b.id),
    'checks', jsonb_build_object('debits', v_dr, 'credits', v_cr, 'balances', abs(v_dr - v_cr) < 0.01, 'receivables_tb', v_ar, 'receivables_open', v_oi,
      'payables_tb', v_ap, 'payables_open', v_ob, 'inventory_tb', v_inv, 'inventory_items', v_s, 'unmapped', v_unmapped, 'unconfirmed', v_unconfirmed,
      'blockers', v_block, 'warnings', v_warn, 'ready', jsonb_array_length(v_block) = 0),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'source', h.source, 'as_of', h.as_of, 'status', h.status, 'posted_at', h.posted_at,
        'journal_ref', (select ref from journals where id = h.journal_id), 'summary', h.summary) order by h.created_at desc), '[]'::jsonb)
      from books_migrations h where h.org_id = p_org and h.id <> b.id));
end $$;

-- ---------------------------------------------------------------------------
-- 5. Posting the opening position
-- ---------------------------------------------------------------------------
-- p_options: {accept_differences: true} posts receivables or payables the open items do not explain to the control account without a
-- customer or supplier, and inventory the items do not explain to the inventory account, to be cleared later.
create or replace function public.post_books_migration(p_migration uuid, p_options jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.books_migrations; m public.members; o public.orgs; st jsonb; l record; i record; v_jl jsonb := '[]'::jsonb; j public.journals; v_at timestamptz;
  v_code text; v_bank public.bank_accounts; v_amt numeric; v_ar_tb numeric := 0; v_ap_tb numeric := 0; v_oi numeric := 0; v_ob numeric := 0;
  v_stock jsonb; v_s numeric := 0; v_party uuid; v_accept boolean := coalesce((p_options->>'accept_differences')::boolean, false);
  v_ar_code text; v_ap_code text; v_label text; s public.sales; bl public.bills; v_sales int := 0; v_bills int := 0; v_banks int := 0; v_newc int := 0; v_newv int := 0;
  v_by_code jsonb := '{}'::jsonb; k text; v numeric; v_inv_tb jsonb := '{}'::jsonb;
begin
  select * into b from books_migrations where id = p_migration for update;
  if not found then raise exception 'Migration not found.'; end if;
  m := private.migration_member(b.org_id);
  if b.status <> 'draft' then raise exception 'This migration has already posted.'; end if;
  select * into o from orgs where id = b.org_id;
  st := (public.get_books_migration(b.org_id))->'checks';
  if not (st->>'ready')::boolean then raise exception '%', (select string_agg(value, ' ') from jsonb_array_elements_text(st->'blockers')); end if;
  if jsonb_array_length(st->'warnings') > 0 and not v_accept then
    raise exception 'Reconcile first or accept the differences: %', (select string_agg(value, ' ') from jsonb_array_elements_text(st->'warnings'));
  end if;
  if private.closed_through(b.org_id) is not null and b.as_of <= private.closed_through(b.org_id) then raise exception 'The books are closed up to the cut-over date.'; end if;
  v_label := case b.source when 'quickbooks' then 'QuickBooks' when 'zoho' then 'Zoho Books' when 'xero' then 'Xero' when 'sage' then 'Sage' else 'the old system' end;
  v_at := least(((b.as_of + 1)::timestamp at time zone o.timezone) - interval '1 second', now());
  v_ar_code := private.acct(b.org_id, 'receivables'); v_ap_code := private.acct(b.org_id, 'payables');
  v_stock := private.migration_stock(b.org_id, b.as_of);
  -- 1. Each mapped account, banks opened as Counta bank accounts. Control accounts and inventory are handled below.
  for l in select * from migration_accounts where migration_id = b.id order by line_no loop
    v_amt := l.debit - l.credit;
    if l.new_bank then
      v_bank := private.open_bank_account(b.org_id, case split_part(l.mapped_code, '-', 1) when '1011' then 'cash' when '1014' then 'wallet' else 'bank' end,
        coalesce(l.bank_name, l.source_name), jsonb_build_object('currency', case when l.mapped_code = '1013' then 'USD' else 'NGN' end), m.id);
      v_code := v_bank.ledger_code; v_banks := v_banks + 1;
      update migration_accounts set mapped_code = v_code, new_bank = false where id = l.id;
    else
      v_code := l.mapped_code;
    end if;
    if split_part(v_code, '-', 1) in ('1101', '1102') then v_ar_tb := v_ar_tb + v_amt; continue; end if;
    if split_part(v_code, '-', 1) in ('2101', '2102') then v_ap_tb := v_ap_tb - v_amt; continue; end if;
    if v_code ~ '^12(0[1-6])' then v_inv_tb := jsonb_set(v_inv_tb, array[v_code], to_jsonb(private.v(v_inv_tb, v_code) + v_amt)); continue; end if;
    v_by_code := jsonb_set(v_by_code, array[v_code], to_jsonb(private.v(v_by_code, v_code) + v_amt));
  end loop;
  for k, v in select key, value::numeric from jsonb_each_text(v_by_code) order by key loop
    continue when v = 0;
    v_jl := v_jl || jsonb_build_object('code', k, 'debit', greatest(v, 0), 'credit', greatest(-v, 0), 'memo', 'Opening balance from ' || v_label);
  end loop;
  -- 2. Inventory: what item uploads already brought in stays; only the difference posts here, and their 3999 credit is cleared.
  for k, v in select key, value::numeric from jsonb_each_text(v_inv_tb) order by key loop
    v_amt := v - private.v(v_stock, k);
    if v_amt <> 0 then
      v_jl := v_jl || jsonb_build_object('code', k, 'debit', greatest(v_amt, 0), 'credit', greatest(-v_amt, 0), 'memo', 'Opening inventory from ' || v_label || ' not covered by item uploads');
    end if;
  end loop;
  for k, v in select key, value::numeric from jsonb_each_text(v_stock) where not (v_inv_tb ? key) loop
    v_jl := v_jl || jsonb_build_object('code', k, 'debit', greatest(-v, 0), 'credit', greatest(v, 0), 'memo', 'Item uploads above the trial balance inventory');
  end loop;
  select coalesce(sum(value::numeric), 0) into v_s from jsonb_each_text(v_stock);
  if v_s <> 0 then
    v_jl := v_jl || jsonb_build_object('code', '3999', 'debit', greatest(v_s, 0), 'credit', greatest(-v_s, 0), 'memo', 'Opening stock from item uploads, now in the opening position');
  end if;
  -- 3. Receivables by customer and payables by supplier, one line per open document.
  for i in select * from migration_open_items where migration_id = b.id order by kind, line_no loop
    if i.kind = 'invoice' then
      select id into v_party from customers where org_id = b.org_id and not archived and not is_walk_in and lower(name) = lower(i.party_name) order by created_at limit 1;
      if v_party is null then
        v_party := private.upsert_customer(b.org_id, jsonb_build_object('name', i.party_name, 'kind', 'business', 'notes', 'Added from ' || v_label || ' open invoices'), m);
        v_newc := v_newc + 1;
      end if;
      insert into sales (org_id, doc_type, number, status, customer_id, customer_name, location_id, channel, issue_date, due_date, prices_include_vat, vat_registered,
        reference, notes, created_by, created_at, issued_at)
      values (b.org_id, 'invoice', private.doc_number(b.org_id, 'invoice'), 'open', v_party, i.party_name,
        (select id from locations where org_id = b.org_id order by is_main desc, created_at limit 1), 'import', i.issue_date, i.due_date, false, o.vat_registered,
        coalesce(i.number, 'Opening balance'), 'Unpaid ' || v_label || ' invoice ' || coalesce(i.number, '') || ' brought into Counta at ' || private.fdate(b.as_of), m.id, v_at, v_at)
      returning * into s;
      insert into sale_lines (sale_id, org_id, line_no, kind, description, qty, unit_label, unit_price, vat_treatment, item_vat_treatment, vat_rate, net, vat, gross, revenue_account)
      values (s.id, b.org_id, 1, 'service', 'Balance of ' || v_label || ' invoice ' || coalesce(i.number, '(no number)'), 1, 'balance', i.amount, 'exempt', 'exempt', 0, i.amount, 0, i.amount, '9007');
      update sales set subtotal = i.amount, total = i.amount where id = s.id;
      update migration_open_items set doc_id = s.id where id = i.id;
      v_jl := v_jl || jsonb_build_object('code', v_ar_code, 'debit', i.amount, 'party_type', 'customer', 'party_id', v_party, 'doc_type', 'sale', 'doc_id', s.id,
        'memo', 'Opening balance · ' || coalesce(i.number, i.party_name));
      v_oi := v_oi + i.amount; v_sales := v_sales + 1;
    else
      select id into v_party from vendors where org_id = b.org_id and lower(name) = lower(i.party_name) order by created_at limit 1;
      if v_party is null then
        insert into vendors (org_id, name, notes) values (b.org_id, i.party_name, 'Added from ' || v_label || ' open bills') returning id into v_party;
        v_newv := v_newv + 1;
      end if;
      insert into bills (org_id, number, vendor_id, vendor_ref, source, external_ref, bill_date, due_date, prices_include_vat, vat_charged, status, subtotal, total,
        notes, created_by, approved_by, approved_at, created_at)
      values (b.org_id, 'BILL-' || lpad(private.next_no(b.org_id, 'BILL', 1)::text, 4, '0'), v_party, i.number, 'import', 'migration:' || b.id || ':' || i.line_no,
        i.issue_date, i.due_date, false, false, 'approved', i.amount, i.amount,
        'Unpaid ' || v_label || ' bill ' || coalesce(i.number, '') || ' brought into Counta at ' || private.fdate(b.as_of), m.id, m.id, v_at, v_at)
      returning * into bl;
      insert into bill_lines (bill_id, org_id, line_no, description, account_code, qty, unit_cost, vat_treatment, vat_recoverable, net, vat, gross)
      values (bl.id, b.org_id, 1, 'Balance of ' || v_label || ' bill ' || coalesce(i.number, '(no number)'), '9007', 1, i.amount, 'none', false, i.amount, 0, i.amount);
      update migration_open_items set doc_id = bl.id where id = i.id;
      v_jl := v_jl || jsonb_build_object('code', v_ap_code, 'credit', i.amount, 'party_type', 'vendor', 'party_id', v_party, 'doc_type', 'bill', 'doc_id', bl.id,
        'memo', 'Opening balance · ' || coalesce(i.number, i.party_name));
      v_ob := v_ob + i.amount; v_bills := v_bills + 1;
    end if;
  end loop;
  -- What the open items do not explain stays on the control account, without a customer or supplier.
  if abs(v_ar_tb - v_oi) >= 0.01 then
    v_jl := v_jl || jsonb_build_object('code', v_ar_code, 'debit', greatest(v_ar_tb - v_oi, 0), 'credit', greatest(v_oi - v_ar_tb, 0), 'memo', 'Opening receivables not matched to an invoice');
  end if;
  if abs(v_ap_tb - v_ob) >= 0.01 then
    v_jl := v_jl || jsonb_build_object('code', v_ap_code, 'credit', greatest(v_ap_tb - v_ob, 0), 'debit', greatest(v_ob - v_ap_tb, 0), 'memo', 'Opening payables not matched to a bill');
  end if;
  j := private.post_entry(b.org_id, 'Opening balances from ' || v_label || ' at ' || private.fdate(b.as_of), 'migration', b.id, m.id, m.id, v_jl, v_at,
    jsonb_build_object('origin', 'import', 'evidence', jsonb_build_array(jsonb_build_object('type', 'migration', 'id', b.id, 'file', b.tb_file))));
  update sales set journal_id = j.id where id in (select doc_id from migration_open_items where migration_id = b.id and kind = 'invoice');
  update bills set journal_id = j.id where id in (select doc_id from migration_open_items where migration_id = b.id and kind = 'bill');
  update orgs set books_start = case when books_start is null or books_start <= b.as_of then b.as_of + 1 else books_start end where id = b.org_id;
  update books_migrations set status = 'posted', journal_id = j.id, posted_by = m.id, posted_at = now(),
    summary = jsonb_build_object('accounts', (select count(*) from migration_accounts where migration_id = b.id), 'invoices', v_sales, 'bills', v_bills,
      'bank_accounts', v_banks, 'new_customers', v_newc, 'new_suppliers', v_newv, 'receivables', v_ar_tb, 'payables', v_ap_tb,
      'unmatched_receivables', v_ar_tb - v_oi, 'unmatched_payables', v_ap_tb - v_ob, 'stock_from_items', v_s, 'journal_ref', j.ref)
  where id = b.id returning * into b;
  perform private.notify_perm(b.org_id, 'keep_books', 'books', 'Opening balances from ' || v_label || ' posted',
    j.ref || ' · ' || v_sales || ' invoices, ' || v_bills || ' bills', '/accounting/migrate', 'migration-' || b.id, m.id);
  return public.get_books_migration(b.org_id);
end $$;

-- Undo, owner only, while nothing has happened to the opening documents.
create or replace function public.reverse_books_migration(p_migration uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.books_migrations; m public.members; r public.journals;
begin
  select * into b from books_migrations where id = p_migration for update;
  if not found then raise exception 'Migration not found.'; end if;
  m := private.require(b.org_id, null);
  if m.role <> 'owner' then raise exception 'Only the owner undoes a migration.' using errcode = '42501'; end if;
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
end $$;

-- ---------------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------------
revoke all on function public.start_books_migration(uuid, text, date), public.set_migration_trial_balance(uuid, jsonb, text), public.map_migration_account(uuid, text, text),
  public.confirm_migration_accounts(uuid, uuid[]), public.migration_ai_map(uuid, jsonb, text), public.set_migration_open_items(uuid, text, jsonb, text),
  public.import_customers(uuid, jsonb, jsonb), public.get_books_migration(uuid), public.post_books_migration(uuid, jsonb), public.reverse_books_migration(uuid, text)
  from public, anon;
grant execute on function public.start_books_migration(uuid, text, date), public.set_migration_trial_balance(uuid, jsonb, text), public.map_migration_account(uuid, text, text),
  public.confirm_migration_accounts(uuid, uuid[]), public.migration_ai_map(uuid, jsonb, text), public.set_migration_open_items(uuid, text, jsonb, text),
  public.import_customers(uuid, jsonb, jsonb), public.get_books_migration(uuid), public.post_books_migration(uuid, jsonb), public.reverse_books_migration(uuid, text)
  to authenticated;
revoke all on function private.guess_account(uuid, text, text, numeric), private.migration_member(uuid), private.migration_stock(uuid, date)
  from public, anon, authenticated;
