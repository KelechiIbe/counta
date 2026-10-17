-- Counta · Atlas ledger core
--
-- Counta becomes TaxStreem's accounting product as well as its inventory and sales product. This
-- migration gives the ledger what a full set of books needs:
--   * IFRS presentation and cash-flow metadata on every account, so statements are built from the chart;
--   * business-level accounts (custom accounts and one sub-account per bank account or wallet);
--   * a party (customer, vendor, staff) and source document on each journal line, so receivables and
--     payables are sub-ledgers of their control accounts;
--   * reversals instead of edits, manual journals with guardrails, and automatic account numbering;
--   * customers, richer vendors, bank and wallet accounts, the AI proposal queue ("books inbox"),
--     learned rules and the statutory payee registry.

-- ---------------------------------------------------------------------------
-- 1. Presentation metadata on the chart
-- ---------------------------------------------------------------------------
alter table public.accounts add column if not exists ifrs_line text;
alter table public.accounts add column if not exists cash_flow_class text;
alter table public.accounts add column if not exists statement text;

-- statement: sofp (financial position), pl (profit or loss), oci, system.
-- ifrs_line: the line on the face of the statement the account rolls into.
-- cash_flow_class: how its movements appear in the statement of cash flows.
create or replace function private.ifrs_meta(p_code text, p_parent text default null)
returns table (statement text, ifrs_line text, cash_flow_class text)
language plpgsql immutable set search_path = '' as $$
declare c text := coalesce(nullif(split_part(p_code, '-', 1), ''), p_code); n int;
begin
  -- Sub-accounts (1012-01) take their parent's metadata.
  begin n := c::int; exception when others then n := null; end;
  if n is null then return query select 'system'::text, 'Unclassified'::text, 'system'::text; return; end if;
  return query select * from (values (
    case when n between 1000 and 3999 then 'sofp' when n between 4000 and 7999 then 'pl' when n between 8000 and 8999 then 'oci' else 'system' end,
    case
      when n between 1011 and 1019 then 'Cash and cash equivalents'
      when n between 1101 and 1108 or n = 1110 then 'Trade and other receivables'
      when n = 1109 then 'Other current financial assets'
      when n between 1201 and 1207 then 'Inventories'
      when n between 1301 and 1303 then 'Prepayments'
      when n in (1304, 1305, 1308) then 'Other current financial assets'
      when n = 1306 then 'Assets held for sale'
      when n = 1307 then 'Contract assets'
      when n between 1401 and 1404 then 'Current tax assets'
      when n between 1501 and 1574 then 'Property, plant and equipment'
      when n between 1601 and 1610 then 'Intangible assets'
      when n between 1651 and 1654 then 'Right-of-use assets'
      when n in (1701, 1702) then 'Investments in subsidiaries and associates'
      when n = 1706 then 'Investment property'
      when n between 1703 and 1711 then 'Other financial assets'
      when n = 1803 then 'Deferred tax assets'
      when n between 1801 and 1809 then 'Other non-current assets'
      when n between 2101 and 2106 or n in (2108, 2109) then 'Trade and other payables'
      when n in (2107, 2110) then 'Contract liabilities'
      when n in (2208, 2209) then 'Current tax liabilities'
      when n between 2201 and 2210 then 'Other statutory liabilities'
      when n = 2304 then 'Lease liabilities (current)'
      when n between 2301 and 2306 then 'Borrowings (current)'
      when n between 2401 and 2403 then 'Provisions (current)'
      when n = 2504 then 'Lease liabilities (non-current)'
      when n between 2501 and 2505 then 'Borrowings (non-current)'
      when n = 2601 then 'Deferred tax liabilities'
      when n between 2602 and 2608 then 'Other non-current liabilities'
      when n in (3001, 3002) then 'Share capital'
      when n = 3003 then 'Share premium'
      when n = 3004 then 'Deposit for shares'
      when n = 3005 then 'Retained earnings'
      when n = 3016 then 'Non-controlling interests'
      when n = 3999 then 'Opening balances to be confirmed'
      when n between 3006 and 3017 then 'Other reserves'
      when n between 4101 and 4132 then 'Revenue'
      when n in (4502, 4503) then 'Finance income'
      when n in (4510, 4511, 4515) then 'Other gains and losses'
      when n between 4501 and 4516 then 'Other income'
      when n between 5101 and 5401 then 'Cost of sales'
      when n between 6401 and 6410 then 'Selling and distribution expenses'
      when n in (6801, 6802) then 'Impairment losses on financial assets'
      when n in (6703, 6704) then 'Other gains and losses'
      when n in (6803, 6804, 6805) then 'Other operating expenses'
      when n = 6702 then 'Finance costs'
      when n between 6101 and 6907 then 'Administrative expenses'
      when n between 7101 and 7105 then 'Finance costs'
      when n between 7501 and 7505 then 'Income tax expense'
      when n in (8001, 8002) then 'Items that will not be reclassified to profit or loss'
      when n = 8008 then 'Income tax relating to other comprehensive income'
      when n between 8003 and 8009 then 'Items that may be reclassified to profit or loss'
      when n between 9001 and 9007 then 'Unreconciled balances'
      else 'Unclassified' end,
    case
      when n between 1011 and 1019 then 'cash'
      when n between 1101 and 1110 or n between 1201 and 1207 or n between 1301 and 1303 or n in (1307, 1308)
        or n between 2101 and 2110 or n between 2201 and 2207 or n = 2210 or n between 2401 and 2403 or n in (1401, 1402, 1404) then 'working_capital'
      when n in (1403, 2208, 2209) then 'tax_paid'
      when n between 1501 and 1527 or n between 1601 and 1608 or n = 1610 or n between 1701 and 1711 or n in (1304, 1305, 1306, 1801, 1802, 1806, 1808) then 'investing'
      when n between 1550 and 1574 or n = 1609 or n between 1651 and 1654 or n in (1803, 1804, 1805, 1807, 1809, 2601, 2602, 2603, 2604, 2605, 2606, 2607, 2608) then 'noncash'
      when n between 2301 and 2306 or n between 2501 and 2505 or n between 3001 and 3004 or n between 3006 and 3017 or n = 2108 then 'financing'
      when n = 3005 or n = 3999 then 'equity_other'
      when n in (5204, 5205, 6802, 6803, 6805, 6901, 6902, 6903, 6704, 4511, 4507, 4515, 7503, 7104) then 'noncash'
      when n in (4508, 6804, 4506) then 'investing_gain'
      when n between 4000 and 8999 then 'profit'
      when n between 9001 and 9007 then 'system'
      else 'system' end
  )) v(a, b, c2);
end $$;

update public.accounts a set statement = m.statement, ifrs_line = m.ifrs_line, cash_flow_class = m.cash_flow_class
from (select code, (private.ifrs_meta(code)).* from public.accounts) m where m.code = a.code;

-- ---------------------------------------------------------------------------
-- 2. Accounts that belong to one business: custom accounts and bank / wallet sub-accounts
-- ---------------------------------------------------------------------------
create table if not exists public.org_accounts (
  org_id uuid not null references public.orgs(id) on delete cascade,
  code text not null,
  name text not null check (length(trim(name)) > 0),
  parent_code text not null references public.accounts(code),
  kind text not null default 'custom' check (kind in ('custom', 'bank', 'wallet', 'cash')),
  category text not null,
  normal_balance text not null check (normal_balance in ('debit', 'credit')),
  statement text not null,
  ifrs_line text not null,
  cash_flow_class text not null,
  description text,
  active boolean not null default true,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (org_id, code)
);
create index if not exists org_accounts_parent_fk on public.org_accounts(parent_code);
create index if not exists org_accounts_created_by_fk on public.org_accounts(created_by);
alter table public.org_accounts enable row level security;
drop policy if exists org_accounts_read on public.org_accounts;
create policy org_accounts_read on public.org_accounts for select to authenticated using ((select private.is_member(org_id)));

-- Every account a business can see: the TaxStreem chart plus its own accounts.
create or replace function private.accounts_of(p_org uuid)
returns table (code text, name text, parent_code text, category text, normal_balance text, is_group boolean, is_system boolean,
  active boolean, statement text, ifrs_line text, cash_flow_class text, kind text, own boolean)
language sql stable security definer set search_path = public, private as $$
  select a.code, a.name, a.parent_code, a.category, a.normal_balance,
    a.is_group or exists (select 1 from org_accounts o where o.org_id = p_org and o.parent_code = a.code and o.kind in ('bank', 'wallet', 'cash')),
    a.is_system, a.active, a.statement, a.ifrs_line, a.cash_flow_class, 'standard', false
  from accounts a
  union all
  select o.code, o.name, o.parent_code, o.category, o.normal_balance, false, false, o.active, o.statement, o.ifrs_line, o.cash_flow_class, o.kind, true
  from org_accounts o where o.org_id = p_org
$$;

-- Can a line be posted to this account for this business?
-- A standard account stops taking postings once the business has bank or wallet sub-accounts under it.
create or replace function private.postable(p_org uuid, p_code text) returns boolean
language sql stable security definer set search_path = public, private as $$
  select coalesce(
    (select o.active from org_accounts o where o.org_id = p_org and o.code = p_code),
    (select a.active and not a.is_group
        and not exists (select 1 from org_accounts o where o.org_id = p_org and o.parent_code = a.code and o.kind in ('bank', 'wallet', 'cash'))
     from accounts a where a.code = p_code),
    false)
$$;

create or replace function private.account_name(p_org uuid, p_code text) returns text
language sql stable security definer set search_path = public, private as $$
  select coalesce((select name from org_accounts where org_id = p_org and code = p_code), (select name from accounts where code = p_code), p_code)
$$;

-- ---------------------------------------------------------------------------
-- 3. Journals: party, document and evidence on lines; reversals; origin and confidence
-- ---------------------------------------------------------------------------
alter table public.journal_lines drop constraint if exists journal_lines_account_code_fkey;
alter table public.journal_lines add column if not exists party_type text check (party_type in ('customer', 'vendor', 'member', 'asset'));
alter table public.journal_lines add column if not exists party_id uuid;
alter table public.journal_lines add column if not exists doc_type text;
alter table public.journal_lines add column if not exists doc_id uuid;
create index if not exists journal_lines_party on public.journal_lines(org_id, party_type, party_id) where party_id is not null;
create index if not exists journal_lines_doc on public.journal_lines(doc_type, doc_id) where doc_id is not null;
create index if not exists journal_lines_org_code on public.journal_lines(org_id, account_code, journal_id);

alter table public.journals add column if not exists reversal_of uuid references public.journals(id);
alter table public.journals add column if not exists origin text not null default 'system';
alter table public.journals add column if not exists evidence jsonb not null default '[]'::jsonb;
alter table public.journals add column if not exists ai_confidence numeric(4,3);
alter table public.journals add column if not exists ai_proposal_id uuid;
alter table public.journals drop constraint if exists journals_origin_check;
alter table public.journals add constraint journals_origin_check check (origin in ('system', 'manual', 'ai', 'import', 'close'));
create index if not exists journals_reversal_of on public.journals(reversal_of) where reversal_of is not null;
create index if not exists journals_entry on public.journals(org_id, entry_date);
create index if not exists journals_source on public.journals(source_type, source_id);

-- Lines must post to an account the business can use. Replaces the foreign key so business-level
-- accounts (1012-01, 6217) are valid targets.
create or replace function private.check_journal_line() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if not exists (select 1 from accounts where code = new.account_code)
     and not exists (select 1 from org_accounts where org_id = new.org_id and code = new.account_code) then
    raise exception 'Account % does not exist.', new.account_code;
  end if;
  return new;
end $$;
drop trigger if exists journal_lines_account on public.journal_lines;
create trigger journal_lines_account before insert on public.journal_lines for each row execute function private.check_journal_line();

-- The single writer. Lines: [{code, debit, credit, location_id, item_id, memo, party_type, party_id, doc_type, doc_id}].
-- p_meta: {origin, evidence[], ai_confidence, ai_proposal_id, reversal_of}.
create or replace function private.post_entry(
  p_org uuid, p_memo text, p_source_type text, p_source_id uuid,
  p_author uuid, p_approver uuid, p_lines jsonb, p_at timestamptz default now(), p_meta jsonb default '{}'::jsonb
) returns public.journals
language plpgsql security definer set search_path = public, private as $$
declare j public.journals; v_dr numeric := 0; v_cr numeric := 0; x jsonb; v_d numeric; v_c numeric; v_n int := 0;
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then raise exception 'A journal needs lines.'; end if;
  for x in select * from jsonb_array_elements(p_lines) loop
    v_d := round(coalesce((x->>'debit')::numeric, 0), 2);
    v_c := round(coalesce((x->>'credit')::numeric, 0), 2);
    if v_d < 0 or v_c < 0 then raise exception 'Journal amounts cannot be negative.'; end if;
    if v_d <> 0 and v_c <> 0 then raise exception 'A journal line is either a debit or a credit.'; end if;
    if (v_d <> 0 or v_c <> 0) then
      if not private.postable(p_org, x->>'code') then
        raise exception 'Account % (%) cannot take postings.', coalesce(x->>'code', '(none)'), private.account_name(p_org, x->>'code');
      end if;
      v_n := v_n + 1;
    end if;
    v_dr := v_dr + v_d;
    v_cr := v_cr + v_c;
  end loop;
  if v_dr <> v_cr then
    raise exception 'Journal does not balance (Dr % / Cr %).', v_dr, v_cr;
  end if;
  if v_n = 0 then raise exception 'A journal needs at least one amount.'; end if;
  insert into public.journals (org_id, je_no, entry_date, memo, source_type, source_id, posted_by, approved_by, created_at,
    origin, evidence, ai_confidence, ai_proposal_id, reversal_of)
  values (p_org, private.next_no(p_org, 'JE', 1001), private.local_day(p_org, p_at), left(p_memo, 500), p_source_type, p_source_id,
    p_author, p_approver, p_at, coalesce(nullif(p_meta->>'origin', ''), 'system'), coalesce(p_meta->'evidence', '[]'::jsonb),
    nullif(p_meta->>'ai_confidence', '')::numeric, nullif(p_meta->>'ai_proposal_id', '')::uuid, nullif(p_meta->>'reversal_of', '')::uuid)
  returning * into j;
  insert into public.journal_lines (journal_id, org_id, account_code, debit, credit, location_id, item_id, memo, party_type, party_id, doc_type, doc_id)
  select j.id, p_org, e->>'code',
         round(coalesce((e->>'debit')::numeric, 0), 2), round(coalesce((e->>'credit')::numeric, 0), 2),
         nullif(e->>'location_id', '')::uuid, nullif(e->>'item_id', '')::uuid, e->>'memo',
         nullif(e->>'party_type', ''), nullif(e->>'party_id', '')::uuid, nullif(e->>'doc_type', ''), nullif(e->>'doc_id', '')::uuid
  from jsonb_array_elements(p_lines) e
  where round(coalesce((e->>'debit')::numeric, 0), 2) <> 0 or round(coalesce((e->>'credit')::numeric, 0), 2) <> 0;
  return j;
end $$;

-- Existing callers keep their signature.
create or replace function private.post_journal(
  p_org uuid, p_memo text, p_source_type text, p_source_id uuid,
  p_author uuid, p_approver uuid, p_lines jsonb, p_at timestamptz default now()
) returns public.journals
language sql security definer set search_path = public, private as $$
  select private.post_entry(p_org, p_memo, p_source_type, p_source_id, p_author, p_approver, p_lines, p_at, '{}'::jsonb)
$$;

-- Reverse a posted journal: equal and opposite, linked to the original, dated the original's day
-- (a closed month moves it to the first open day through the period lock).
create or replace function private.reverse_entry(p_journal uuid, p_author uuid, p_reason text, p_at timestamptz default null)
returns public.journals
language plpgsql security definer set search_path = public, private as $$
declare o public.journals; r public.journals; v_at timestamptz;
begin
  select * into o from journals where id = p_journal;
  if not found then raise exception 'Journal not found.'; end if;
  if o.reversal_of is not null then raise exception '% is itself a reversal.', o.ref; end if;
  if exists (select 1 from journals where reversal_of = o.id) then raise exception '% was already reversed.', o.ref; end if;
  v_at := coalesce(p_at, o.created_at);
  r := private.post_entry(o.org_id, 'Reversal of ' || o.ref || coalesce(' · ' || nullif(trim(p_reason), ''), ''), o.source_type, o.source_id,
    p_author, p_author,
    (select jsonb_agg(jsonb_build_object('code', l.account_code, 'debit', l.credit, 'credit', l.debit, 'location_id', l.location_id,
       'item_id', l.item_id, 'memo', l.memo, 'party_type', l.party_type, 'party_id', l.party_id, 'doc_type', l.doc_type, 'doc_id', l.doc_id))
     from journal_lines l where l.journal_id = o.id),
    v_at, jsonb_build_object('origin', case when o.origin = 'ai' then 'ai' else 'manual' end, 'reversal_of', o.id,
      'evidence', jsonb_build_array(jsonb_build_object('type', 'journal', 'id', o.id, 'ref', o.ref))));
  return r;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Business accounting settings
-- ---------------------------------------------------------------------------
alter table public.orgs add column if not exists tin text;
alter table public.orgs add column if not exists rc_number text;
alter table public.orgs add column if not exists address text;
alter table public.orgs add column if not exists logo_path text;
alter table public.orgs add column if not exists legal_form text not null default 'company';
alter table public.orgs add column if not exists fiscal_year_start int not null default 1;
alter table public.orgs add column if not exists prices_include_vat boolean not null default true;
alter table public.orgs add column if not exists invoice_terms_days int not null default 30;
alter table public.orgs add column if not exists invoice_note text;
alter table public.orgs add column if not exists revenue_account text not null default '4107';
alter table public.orgs add column if not exists cash_sales_without_invoices boolean not null default true;
alter table public.orgs add column if not exists capitalisation_threshold numeric(16,2) not null default 100000;
alter table public.orgs add column if not exists auto_post_threshold numeric(4,3) not null default 0.800;
alter table public.orgs add column if not exists books_start date;
alter table public.orgs drop constraint if exists orgs_fiscal_year_start_check;
alter table public.orgs add constraint orgs_fiscal_year_start_check check (fiscal_year_start between 1 and 12);
alter table public.orgs drop constraint if exists orgs_auto_post_threshold_check;
alter table public.orgs add constraint orgs_auto_post_threshold_check check (auto_post_threshold >= 0.8 and auto_post_threshold <= 1);
alter table public.orgs drop constraint if exists orgs_legal_form_check;
alter table public.orgs add constraint orgs_legal_form_check check (legal_form in ('company', 'enterprise', 'partnership', 'ngo', 'individual'));

-- ---------------------------------------------------------------------------
-- 5. New posting roles
-- ---------------------------------------------------------------------------
insert into public.posting_roles (role, label, description, default_code, allowed, sort) values
  ('sales_revenue', 'Sales', 'Revenue from goods and services sold, net of VAT. Set to the sector your business is in.', '4107', '^41(0[1-9]|1[0-9]|2[01])$', 20),
  ('sales_returns', 'Sales returns', 'Goods customers return and credit notes issued.', '4131', '^(4131)$', 21),
  ('discounts_allowed', 'Discounts given', 'Discounts given at the till or on invoices, when shown separately.', '4132', '^(4132|4131)$', 22),
  ('output_vat', 'VAT on sales', 'VAT charged on taxable sales, owed to the NRS.', '2201', '^(2201)$', 23),
  ('receivables', 'Owed by customers', 'Invoices and credit sales not yet paid.', '1101', '^(1101|1102)$', 24),
  ('customer_advances', 'Paid in advance by customers', 'Customer money received before an invoice or delivery.', '2107', '^(2107|2505)$', 25),
  ('cash_on_hand', 'Cash in the till', 'Cash taken at the till, until it is banked.', '1011', '^(1011)$', 26),
  ('bank_clearing', 'Payments being confirmed', 'Payments a cashier recorded that the bank has not yet shown.', '9002', '^(9002)$', 27),
  ('payment_fees', 'Payment and bank charges', 'Fees charged by banks and payment providers.', '6701', '^(6701|7105)$', 28),
  ('suspense', 'To be confirmed', 'Bank lines the AI could not classify with enough confidence. Must be cleared before a month closes.', '9001', '^(9001)$', 29),
  ('wht_receivable', 'WHT deducted by customers', 'Withholding tax customers deducted from what they paid you. A credit against your income tax.', '1401', '^(1401)$', 30),
  ('wht_payable', 'WHT deducted from vendors', 'Withholding tax you deducted from vendor payments, owed to the NRS.', '2202', '^(2202)$', 31),
  ('accrued_expenses', 'Accrued expenses', 'Costs of the period not yet billed.', '2103', '^(2103)$', 32),
  ('ecl_allowance', 'Allowance for bad debts', 'Expected credit losses on receivables (IFRS 9).', '1103', '^(1103)$', 33),
  ('ecl_expense', 'Bad debt charge', 'Movement in the expected credit loss allowance.', '6802', '^(6802|6801)$', 34),
  ('bad_debts', 'Bad debts written off', 'Debts written off after recovery efforts.', '6801', '^(6801)$', 35),
  ('cash_over_short', 'Till over and short', 'Differences between counted cash and expected cash at the end of a shift.', '6907', '^(6907|4516|6114)$', 36),
  ('depreciation', 'Depreciation', 'Depreciation of property, plant and equipment used in administration.', '6901', '^(6901|5204)$', 37),
  ('retained_earnings', 'Retained earnings', 'Profits kept in the business. The year-end close moves the year''s profit here.', '3005', '^(3005)$', 38),
  ('rounding', 'Rounding', 'Kobo differences from VAT and price rounding.', '9006', '^(9006|6907)$', 39),
  ('other_income', 'Other income', 'Income that is not from sales, such as cash found in the till or sundry income.', '4516', '^45(0[1-9]|1[0-6])$', 40),
  ('delivery_income', 'Delivery charges', 'Delivery fees charged to customers. They are revenue under IFRS 15 and carry VAT.', '4108', '^(4108|4107|4121|4516)$', 41),
  ('expenses_default', 'General expenses', 'Last resort for an expense with no better account. Never used by the AI at high confidence.', '6907', '^6[0-9]{3}$', 42),
  ('fx_gain', 'Exchange gains', 'Gains on foreign currency balances.', '4510', '^(4510|4511)$', 43),
  ('fx_loss', 'Exchange losses', 'Losses on foreign currency balances.', '6703', '^(6703|6704)$', 44)
on conflict (role) do nothing;

-- ---------------------------------------------------------------------------
-- 6. Permissions: keep the books, make payments; the accountant role
-- ---------------------------------------------------------------------------
alter table public.members add column if not exists p_keep_books boolean;
alter table public.members add column if not exists p_make_payments boolean;
update public.members set p_keep_books = (role = 'owner') where p_keep_books is null;
update public.members set p_make_payments = (role = 'owner') where p_make_payments is null;
alter table public.members alter column p_keep_books set not null;
alter table public.members alter column p_make_payments set not null;
alter table public.members drop constraint if exists members_role_check;
alter table public.members add constraint members_role_check check (role in ('owner', 'manager', 'staff', 'cashier', 'accountant'));

create or replace function private.role_template(p_role text) returns jsonb
language sql immutable set search_path = public, private as $$
  select case p_role
    when 'owner' then '{"record_sales":true,"receive_stock":true,"count_stock":true,"approve_adjustments":true,"edit_prices":true,"approve_pos":true,"transfer_stock":true,"see_margins":true,"issue_stock":true,"keep_books":true,"make_payments":true}'
    when 'manager' then '{"record_sales":true,"receive_stock":true,"count_stock":true,"approve_adjustments":false,"edit_prices":false,"approve_pos":false,"transfer_stock":true,"see_margins":true,"issue_stock":true,"keep_books":false,"make_payments":false}'
    when 'accountant' then '{"record_sales":false,"receive_stock":false,"count_stock":false,"approve_adjustments":true,"edit_prices":false,"approve_pos":false,"transfer_stock":false,"see_margins":true,"issue_stock":false,"keep_books":true,"make_payments":false}'
    when 'staff' then '{"record_sales":true,"receive_stock":true,"count_stock":true,"approve_adjustments":false,"edit_prices":false,"approve_pos":false,"transfer_stock":false,"see_margins":false,"issue_stock":true,"keep_books":false,"make_payments":false}'
    else '{"record_sales":true,"receive_stock":false,"count_stock":false,"approve_adjustments":false,"edit_prices":false,"approve_pos":false,"transfer_stock":false,"see_margins":false,"issue_stock":false,"keep_books":false,"make_payments":false}'
  end::jsonb
$$;

create or replace function private.member_defaults() returns trigger
language plpgsql set search_path = public, private as $$
declare t jsonb := private.role_template(new.role);
begin
  if new.p_issue_stock is null then new.p_issue_stock := coalesce((t->>'issue_stock')::boolean, false); end if;
  if new.p_keep_books is null then new.p_keep_books := coalesce((t->>'keep_books')::boolean, false); end if;
  if new.p_make_payments is null then new.p_make_payments := coalesce((t->>'make_payments')::boolean, false); end if;
  return new;
end $$;

create or replace function private.perm_of(m public.members, p_perm text) returns boolean
language sql immutable set search_path = public, private as $$
  select case
    when m.id is null then false
    when m.role = 'owner' then true
    else case p_perm
      when 'record_sales' then m.p_record_sales
      when 'receive_stock' then m.p_receive_stock
      when 'count_stock' then m.p_count_stock
      when 'approve_adjustments' then m.p_approve_adjustments
      when 'edit_prices' then m.p_edit_prices
      when 'approve_pos' then m.p_approve_pos
      when 'transfer_stock' then m.p_transfer_stock
      when 'see_margins' then m.p_see_margins
      when 'issue_stock' then coalesce(m.p_issue_stock, false)
      when 'keep_books' then coalesce(m.p_keep_books, false)
      when 'make_payments' then coalesce(m.p_make_payments, false)
      when 'owner' then false
      else false end
  end
$$;

create or replace function public.update_member(p_member uuid, p_patch jsonb) returns void
language plpgsql security definer set search_path = public, private as $$
declare t public.members; m public.members; p jsonb; v_role text;
begin
  select * into t from members where id = p_member;
  if not found then raise exception 'Person not found.'; end if;
  m := private.require(t.org_id, 'owner');
  if t.role = 'owner' and (p_patch ? 'role' or p_patch ? 'perms' or p_patch ? 'status') then
    raise exception 'The owner keeps every permission.';
  end if;
  v_role := coalesce(p_patch->>'role', t.role);
  if v_role not in ('owner', 'manager', 'staff', 'cashier', 'accountant') then raise exception 'Unknown role.'; end if;
  if v_role = 'owner' and t.role <> 'owner' then raise exception 'Ownership transfer is not available here.'; end if;
  p := case when p_patch ? 'role' and p_patch->>'role' <> t.role and not (p_patch ? 'perms')
            then private.role_template(v_role) else coalesce(p_patch->'perms', '{}'::jsonb) end;
  update members set
    role = v_role,
    display_name = coalesce(nullif(trim(p_patch->>'display_name'), ''), display_name),
    title = case when p_patch ? 'title' then nullif(trim(p_patch->>'title'), '') else title end,
    phone = case when p_patch ? 'phone' then nullif(trim(p_patch->>'phone'), '') else phone end,
    location_id = case when p_patch ? 'location_id' then nullif(p_patch->>'location_id', '')::uuid else location_id end,
    status = coalesce(p_patch->>'status', status),
    p_record_sales = coalesce((p->>'record_sales')::boolean, p_record_sales),
    p_receive_stock = coalesce((p->>'receive_stock')::boolean, p_receive_stock),
    p_count_stock = coalesce((p->>'count_stock')::boolean, p_count_stock),
    p_approve_adjustments = coalesce((p->>'approve_adjustments')::boolean, p_approve_adjustments),
    p_edit_prices = coalesce((p->>'edit_prices')::boolean, p_edit_prices),
    p_approve_pos = coalesce((p->>'approve_pos')::boolean, p_approve_pos),
    p_transfer_stock = coalesce((p->>'transfer_stock')::boolean, p_transfer_stock),
    p_see_margins = coalesce((p->>'see_margins')::boolean, p_see_margins),
    p_issue_stock = coalesce((p->>'issue_stock')::boolean, p_issue_stock),
    p_keep_books = coalesce((p->>'keep_books')::boolean, p_keep_books),
    p_make_payments = coalesce((p->>'make_payments')::boolean, p_make_payments)
  where id = p_member;
exception when check_violation then
  raise exception 'Someone who records sales cannot also edit prices or approve adjustments.';
end $$;

-- ---------------------------------------------------------------------------
-- 7. Customers and richer vendors
-- ---------------------------------------------------------------------------
create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  kind text not null default 'individual' check (kind in ('individual', 'business')),
  phone text,
  email text,
  tin text,
  address text,
  price_list_id uuid,
  credit_limit numeric(16,2) not null default 0 check (credit_limit >= 0),
  terms_days int not null default 0 check (terms_days between 0 and 365),
  whatsapp_opt_in boolean not null default true,
  is_walk_in boolean not null default false,
  notes text,
  tags text[] not null default '{}',
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  archived boolean not null default false
);
create index if not exists customers_org on public.customers(org_id, name);
create unique index if not exists customers_org_phone on public.customers(org_id, phone) where phone is not null and phone <> '' and not archived;
create unique index if not exists customers_walk_in on public.customers(org_id) where is_walk_in;
create index if not exists customers_created_by_fk on public.customers(created_by);
alter table public.customers enable row level security;
drop policy if exists customers_read on public.customers;
create policy customers_read on public.customers for select to authenticated using ((select private.is_member(org_id)));

alter table public.vendors add column if not exists tin text;
alter table public.vendors add column if not exists rc_number text;
alter table public.vendors add column if not exists is_individual boolean not null default false;
alter table public.vendors add column if not exists wht_category text;
alter table public.vendors add column if not exists bank_code text;
alter table public.vendors add column if not exists bank_name text;
alter table public.vendors add column if not exists account_number text;
alter table public.vendors add column if not exists account_name text;
alter table public.vendors add column if not exists default_account text;
alter table public.vendors add column if not exists address text;

-- ---------------------------------------------------------------------------
-- 8. Bank accounts, wallets and cash drawers; each has its own ledger sub-account
-- ---------------------------------------------------------------------------
create table if not exists public.bank_accounts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  name text not null,
  kind text not null check (kind in ('bank', 'wallet', 'cash')),
  bank_name text,
  bank_code text,
  account_number text,
  account_name text,
  currency text not null default 'NGN',
  ledger_code text not null,
  provider text not null default 'manual' check (provider in ('manual', 'flutterwave', 'mono', 'rail', 'statement')),
  provider_ref text,
  provider_meta jsonb not null default '{}'::jsonb,
  location_id uuid references public.locations(id) on delete set null,
  is_collection boolean not null default false,
  overdraft_facility boolean not null default false,
  anchor_balance numeric(16,2),
  anchor_at timestamptz,
  anchor_source text,
  active boolean not null default true,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (org_id, ledger_code)
);
create index if not exists bank_accounts_org on public.bank_accounts(org_id);
create index if not exists bank_accounts_location_fk on public.bank_accounts(location_id);
create index if not exists bank_accounts_created_by_fk on public.bank_accounts(created_by);
create unique index if not exists bank_accounts_provider_ref on public.bank_accounts(provider, provider_ref) where provider_ref is not null;
alter table public.bank_accounts enable row level security;
drop policy if exists bank_accounts_read on public.bank_accounts;
create policy bank_accounts_read on public.bank_accounts for select to authenticated using ((select private.is_member(org_id)));

-- Creates the ledger sub-account (1012-01, 1013-01, 1014-01, 1011-01) and the bank account row.
create or replace function private.open_bank_account(p_org uuid, p_kind text, p_name text, p_meta jsonb, p_author uuid)
returns public.bank_accounts
language plpgsql security definer set search_path = public, private as $$
declare v_parent text; v_code text; v_n int; b public.bank_accounts; m record; v_cur text := upper(coalesce(nullif(p_meta->>'currency', ''), 'NGN'));
begin
  v_parent := case p_kind when 'wallet' then '1014' when 'cash' then '1011' else case when v_cur = 'NGN' then '1012' else '1013' end end;
  select coalesce(max(nullif(split_part(code, '-', 2), '')::int), 0) + 1 into v_n
  from org_accounts where org_id = p_org and parent_code = v_parent and code ~ ('^' || v_parent || '-[0-9]+$');
  v_code := v_parent || '-' || lpad(v_n::text, 2, '0');
  select * into m from private.ifrs_meta(v_parent);
  insert into org_accounts (org_id, code, name, parent_code, kind, category, normal_balance, statement, ifrs_line, cash_flow_class, created_by)
  values (p_org, v_code, left(trim(p_name), 120), v_parent, p_kind, 'Assets', 'debit', m.statement, m.ifrs_line, m.cash_flow_class, p_author);
  -- Anything already posted to the parent moves to the first sub-account so the parent can become a heading.
  insert into bank_accounts (org_id, name, kind, bank_name, bank_code, account_number, account_name, currency, ledger_code, provider, provider_ref,
    provider_meta, location_id, is_collection, overdraft_facility, created_by)
  values (p_org, left(trim(p_name), 120), p_kind, nullif(trim(p_meta->>'bank_name'), ''), nullif(trim(p_meta->>'bank_code'), ''),
    nullif(regexp_replace(coalesce(p_meta->>'account_number', ''), '\s', '', 'g'), ''), nullif(trim(p_meta->>'account_name'), ''), v_cur, v_code,
    coalesce(nullif(p_meta->>'provider', ''), 'manual'), nullif(p_meta->>'provider_ref', ''), coalesce(p_meta->'provider_meta', '{}'::jsonb),
    nullif(p_meta->>'location_id', '')::uuid, coalesce((p_meta->>'is_collection')::boolean, false),
    coalesce((p_meta->>'overdraft_facility')::boolean, false), p_author)
  returning * into b;
  if v_n = 1 then perform private.move_parent_balance(p_org, v_parent, v_code, p_author); end if;
  return b;
end $$;

-- Moves any balance posted directly to a standard account onto its first sub-account.
create or replace function private.move_parent_balance(p_org uuid, p_parent text, p_child text, p_author uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_bal numeric; v_id uuid;
begin
  select coalesce(sum(debit - credit), 0) into v_bal from journal_lines where org_id = p_org and account_code = p_parent;
  if v_bal = 0 then return; end if;
  -- Written directly: the parent stops taking postings the moment its first sub-account exists.
  insert into public.journals (org_id, je_no, entry_date, memo, source_type, source_id, posted_by, created_at, origin)
  values (p_org, private.next_no(p_org, 'JE', 1001), private.local_day(p_org, now()), 'Balance on ' || p_parent || ' moved to ' || p_child,
    'reclass', null, p_author, now(), 'system')
  returning id into v_id;
  insert into public.journal_lines (journal_id, org_id, account_code, debit, credit, memo)
  select v_id, p_org, x.code, x.d, x.c, 'Sub-account opened'
  from (values (p_child, greatest(v_bal, 0), greatest(-v_bal, 0)), (p_parent, greatest(-v_bal, 0), greatest(v_bal, 0))) x(code, d, c);
end $$;

create or replace function public.open_bank_account(p_org uuid, p_kind text, p_name text, p_meta jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; b public.bank_accounts; v_open numeric; v_day date; v_at timestamptz;
begin
  m := private.require(p_org, 'keep_books');
  if p_kind not in ('bank', 'cash') then raise exception 'Open a bank account or a cash drawer here. Wallets are opened from Payments.'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Give the account a name.'; end if;
  b := private.open_bank_account(p_org, p_kind, p_name, p_meta, m.id);
  -- Opening balance as reported by the bank (CASH-04): Dr bank / Cr 3999 on the day before the books start.
  v_open := private.num(p_meta->>'opening_balance');
  if coalesce(v_open, 0) <> 0 then
    v_day := coalesce(private.date_or_null(p_meta->>'opening_date'), (select books_start - 1 from orgs where id = p_org), private.local_day(p_org, now()));
    v_at := (v_day::timestamp + interval '23 hours 59 minutes') at time zone coalesce((select timezone from orgs where id = p_org), 'Africa/Lagos');
    perform private.post_entry(p_org, 'Opening balance · ' || b.name, 'opening', b.id, m.id, m.id,
      private.reclass_pair(b.ledger_code, private.acct(p_org, 'opening_equity'), v_open, null, null), v_at,
      jsonb_build_object('origin', 'manual', 'evidence', jsonb_build_array(jsonb_build_object('type', 'bank_statement', 'note', 'Opening balance entered by ' || m.display_name))));
    update bank_accounts set anchor_balance = v_open, anchor_at = v_at, anchor_source = 'opening' where id = b.id;
  end if;
  return jsonb_build_object('id', b.id, 'ledger_code', b.ledger_code);
end $$;

create or replace function public.update_bank_account(p_account uuid, p_patch jsonb) returns void
language plpgsql security definer set search_path = public, private as $$
declare b public.bank_accounts; m public.members;
begin
  select * into b from bank_accounts where id = p_account;
  if not found then raise exception 'Account not found.'; end if;
  m := private.require(b.org_id, 'keep_books');
  update bank_accounts set
    name = coalesce(nullif(trim(p_patch->>'name'), ''), name),
    bank_name = case when p_patch ? 'bank_name' then nullif(trim(p_patch->>'bank_name'), '') else bank_name end,
    account_number = case when b.provider = 'manual' and p_patch ? 'account_number' then nullif(trim(p_patch->>'account_number'), '') else account_number end,
    location_id = case when p_patch ? 'location_id' then nullif(p_patch->>'location_id', '')::uuid else location_id end,
    overdraft_facility = coalesce((p_patch->>'overdraft_facility')::boolean, overdraft_facility),
    active = coalesce((p_patch->>'active')::boolean, active)
  where id = p_account;
  update org_accounts set name = coalesce(nullif(trim(p_patch->>'name'), ''), name), active = coalesce((p_patch->>'active')::boolean, active)
  where org_id = b.org_id and code = b.ledger_code;
end $$;

-- ---------------------------------------------------------------------------
-- 9. The books inbox: AI proposals, learned rules, statutory payees
-- ---------------------------------------------------------------------------
create table if not exists public.ai_proposals (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  agent text not null check (agent in ('bookkeeper', 'reconciler', 'closer', 'auditor', 'tax', 'narrator')),
  kind text not null,
  source_type text,
  source_id uuid,
  title text not null,
  question text,
  proposal jsonb not null default '{}'::jsonb,
  confidence numeric(4,3) not null default 0 check (confidence between 0 and 1),
  rationale text,
  stage text,
  status text not null default 'pending' check (status in ('pending', 'auto_posted', 'approved', 'rejected', 'superseded', 'info')),
  amount numeric(16,2),
  journal_id uuid references public.journals(id) on delete set null,
  holding_journal_id uuid references public.journals(id) on delete set null,
  decided_by uuid references public.members(id) on delete set null,
  decided_at timestamptz,
  decision jsonb,
  model text,
  created_at timestamptz not null default now()
);
create index if not exists ai_proposals_org on public.ai_proposals(org_id, status, created_at desc);
create unique index if not exists ai_proposals_source on public.ai_proposals(org_id, kind, source_type, source_id) where status in ('pending', 'auto_posted', 'approved', 'info') and source_id is not null;
create index if not exists ai_proposals_journal_fk on public.ai_proposals(journal_id);
create index if not exists ai_proposals_holding_fk on public.ai_proposals(holding_journal_id);
create index if not exists ai_proposals_decided_by_fk on public.ai_proposals(decided_by);
alter table public.ai_proposals enable row level security;
drop policy if exists ai_proposals_read on public.ai_proposals;
create policy ai_proposals_read on public.ai_proposals for select to authenticated using ((select private.can_see_costs(org_id)));

create table if not exists public.entity_rules (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  party_key text not null,
  direction text not null check (direction in ('in', 'out')),
  account_code text not null,
  vendor_id uuid references public.vendors(id) on delete set null,
  customer_id uuid references public.customers(id) on delete set null,
  note text,
  source text not null default 'reviewer' check (source in ('reviewer', 'ai', 'import')),
  hits int not null default 0,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (org_id, party_key, direction)
);
create index if not exists entity_rules_vendor_fk on public.entity_rules(vendor_id);
create index if not exists entity_rules_customer_fk on public.entity_rules(customer_id);
create index if not exists entity_rules_created_by_fk on public.entity_rules(created_by);
alter table public.entity_rules enable row level security;
drop policy if exists entity_rules_read on public.entity_rules;
create policy entity_rules_read on public.entity_rules for select to authenticated using ((select private.is_member(org_id)));

-- Normalises a bank narration or counterparty into a stable key: upper case, no digits or punctuation.
create or replace function private.party_key(p text) returns text
language sql immutable set search_path = '' as $$
  -- Who a narration is about: upper case, punctuation and references removed, banking words dropped, whole words only.
  select nullif(trim(regexp_replace(regexp_replace(regexp_replace(upper(coalesce(p, '')), '[^A-Z0-9 ]+', ' ', 'g'),
    '\y(TRF|TRANSFER|TRANS|FROM|TO|NIP|FT|MOB|MOBILE|USSD|POS|WEB|REF|NARR|PAYMENT|PYMT|PMT|FOR|VIA|ACCOUNT|AC|ACCT|INV|INVOICE|BEING|IFO|LESS|WHT|WEEK|BO|FRM|CR|DR|[A-Z]|[A-Z0-9]*[0-9][A-Z0-9]*)\y', ' ', 'g'),
    '\s+', ' ', 'g')), '')
$$;

create table if not exists public.payee_registry (
  id serial primary key,
  pattern text not null,
  kind text not null,
  role text,
  account_code text,
  description text not null,
  direction text not null default 'out' check (direction in ('in', 'out', 'both'))
);
alter table public.payee_registry enable row level security;
drop policy if exists payee_registry_read on public.payee_registry;
create policy payee_registry_read on public.payee_registry for select to authenticated using (true);
insert into public.payee_registry (pattern, kind, role, account_code, description, direction)
select * from (values
  ('(FIRS|NRS|NIGERIA REVENUE SERVICE|FEDERAL INLAND REVENUE).*(VAT|VALUE ADDED)', 'statutory_vat', 'output_vat', '2201', 'VAT remitted to the NRS', 'out'),
  ('(FIRS|NRS|NIGERIA REVENUE SERVICE|FEDERAL INLAND REVENUE).*(WHT|WITHHOLDING)', 'statutory_wht', 'wht_payable', '2202', 'WHT remitted to the NRS', 'out'),
  ('(FIRS|NRS|NIGERIA REVENUE SERVICE|FEDERAL INLAND REVENUE).*(CIT|COMPANY INCOME|INCOME TAX)', 'statutory_cit', null, '2208', 'Company income tax paid', 'out'),
  ('(FIRS|NRS).*(DEV|DEVELOPMENT) ?LEVY', 'statutory_levy', null, '2209', 'Development levy paid', 'out'),
  ('(LIRS|IRS|INTERNAL REVENUE|BIRS|OGIRS|RIRS|FCT-IRS).*(PAYE|P\.A\.Y\.E)', 'statutory_paye', null, '2203', 'PAYE remitted to a state tax office', 'out'),
  ('(PENSION|PFA|STANBIC IBTC PENSION|ARM PENSION|LEADWAY PENSURE|PREMIUM PENSION|CRUSADER STERLING|TRUSTFUND|FIDELITY PENSION|NLPC|NPF PENSIONS|OAK PENSIONS|PAL PENSIONS|TANGERINE PENSIONS|NORRENBERGER)', 'statutory_pension', null, '2204', 'Pension contributions remitted', 'out'),
  ('(\yNSITF\y)', 'statutory_nsitf', null, '2206', 'NSITF remitted', 'out'),
  ('(\yITF\y|INDUSTRIAL TRAINING FUND)', 'statutory_itf', null, '2207', 'ITF remitted', 'out'),
  ('(\yNHF\y|FEDERAL MORTGAGE BANK|\yFMBN\y)', 'statutory_nhf', null, '2205', 'NHF remitted', 'out'),
  ('(EMTL|ELECTRONIC MONEY TRANSFER LEVY|STAMP DUTY)', 'bank_charge', 'payment_fees', '6701', 'Stamp duty or electronic transfer levy', 'out'),
  ('(SMS ALERT|SMS CHARGE|MAINTENANCE FEE|\yCOT\y|ACCOUNT MAINTENANCE|TRANSFER FEE|NIP CHARGE|VAT ON NIP|\yCHARGES?$|COMMISSION ON TURNOVER|CARD MAINTENANCE)', 'bank_charge', 'payment_fees', '6701', 'Bank charges', 'out'),
  ('(\yIKEDC\y|\yEKEDC\y|\yAEDC\y|\yIBEDC\y|\yPHED\y|\yEEDC\y|\yKEDCO\y|\yJED\y|\yBEDC\y|\yKAEDCO\y|\yYEDC\y|PREPAID METER|ELECTRICITY)', 'utility_power', null, '6205', 'Electricity', 'out'),
  ('(\yMTN\y|\yAIRTEL\y|\yGLO\y|GLOBACOM|9MOBILE|AIRTIME)', 'telco', null, '6301', 'Telephone and airtime', 'out'),
  ('(SPECTRANET|\ySMILE\y|STARLINK|\yIPNX\y|FIBREONE|SWIFT NETWORKS|TIZETI|DATA PLAN)', 'internet', null, '6302', 'Internet and data', 'out'),
  ('(TOTAL ?ENERGIES|MRS OIL|CONOIL|ARDOVA|FORTE OIL|NNPC RETAIL|\yOANDO\y|\yETERNA\y|11 PLC|\yMOBIL\y|FUEL STATION|FILLING STATION|PETROL)', 'fuel', null, '6207', 'Fuel (petrol)', 'out'),
  ('(DIESEL|\yAGO\y)', 'fuel_diesel', null, '6206', 'Diesel', 'out'),
  ('(\yCAC\y|CORPORATE AFFAIRS)', 'cac', null, '6506', 'CAC filings', 'out'),
  ('(INTEREST PAID|CREDIT INTEREST|INT\. ?PAID)', 'interest_in', null, '4502', 'Interest received', 'in'),
  ('(LOAN DISBURSEMENT|LOAN DRAWDOWN)', 'loan', null, '2302', 'Loan drawdown', 'in')
) v(pattern, kind, role, account_code, description, direction)
where not exists (select 1 from public.payee_registry);

-- ---------------------------------------------------------------------------
-- 10. Chart of accounts: list, add (AI-classified, code-numbered), rename, switch off
-- ---------------------------------------------------------------------------
create or replace function public.get_chart(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  return jsonb_build_object(
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name, 'parent_code', a.parent_code, 'category', a.category,
        'normal_balance', a.normal_balance, 'is_group', a.is_group, 'is_system', a.is_system, 'active', a.active, 'statement', a.statement,
        'ifrs_line', a.ifrs_line, 'cash_flow_class', a.cash_flow_class, 'kind', a.kind, 'own', a.own,
        'balance', case when private.can_see_costs(p_org) then (select coalesce(sum(l.debit - l.credit), 0) from journal_lines l where l.org_id = p_org and l.account_code = a.code) end
      ) order by a.code), '[]'::jsonb) from private.accounts_of(p_org) a),
    'roles', (select coalesce(jsonb_agg(jsonb_build_object('role', pr.role, 'label', pr.label, 'description', pr.description, 'default_code', pr.default_code,
        'allowed', pr.allowed, 'code', private.acct(p_org, pr.role)) order by pr.sort), '[]'::jsonb) from posting_roles pr));
end $$;

-- New account under a heading. Code = the next free number in the heading's block (6200 → 6217).
create or replace function public.create_account(p_org uuid, p_name text, p_parent text, p_description text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; pa public.accounts; v_base int; v_next int; v_code text; v_span int; meta record; v_dup text;
begin
  m := private.require(p_org, 'keep_books');
  if coalesce(trim(p_name), '') = '' then raise exception 'Give the account a name.'; end if;
  select * into pa from accounts where code = p_parent;
  if not found or not pa.is_group then raise exception 'Choose a heading (such as 6200 Occupancy, Office & Utilities) for the new account.'; end if;
  if pa.parent_code is null then raise exception 'Choose a heading below the top level, such as 6200 rather than 6000.'; end if;
  if pa.code in ('9000') then raise exception 'System accounts cannot be added.'; end if;
  -- Reuse check: an existing account with nearly the same name.
  select a.code || ' ' || a.name into v_dup from private.accounts_of(p_org) a
  where not a.is_group and lower(regexp_replace(a.name, '[^a-zA-Z0-9]', '', 'g')) = lower(regexp_replace(p_name, '[^a-zA-Z0-9]', '', 'g')) limit 1;
  if v_dup is not null then raise exception 'There is already an account called %.', v_dup; end if;
  v_base := pa.code::int;
  -- The block runs to the next heading at the same level (6200 → 6299; 1550 → 1599).
  select coalesce(min(code::int), v_base + 100) - v_base into v_span from accounts
  where is_group and code ~ '^[0-9]+$' and code::int > v_base and left(code, 1) = left(pa.code, 1) and parent_code is not null;
  select greatest(v_base, coalesce(max(code::int), v_base)) + 1 into v_next from (
    select code from accounts where parent_code = pa.code and code ~ '^[0-9]+$'
    union all select code from org_accounts where org_id = p_org and parent_code = pa.code and code ~ '^[0-9]+$') x;
  if v_next >= v_base + v_span then raise exception 'The % block is full. Choose another heading.', pa.name; end if;
  v_code := v_next::text;
  select * into meta from private.ifrs_meta(v_code);
  insert into org_accounts (org_id, code, name, parent_code, kind, category, normal_balance, statement, ifrs_line, cash_flow_class, description, created_by)
  values (p_org, v_code, left(trim(p_name), 120), pa.code, 'custom', pa.category, pa.normal_balance, meta.statement, meta.ifrs_line, meta.cash_flow_class,
    nullif(trim(p_description), ''), m.id);
  return jsonb_build_object('code', v_code, 'name', trim(p_name), 'parent_code', pa.code, 'ifrs_line', meta.ifrs_line);
end $$;

create or replace function public.update_account(p_org uuid, p_code text, p_patch jsonb) returns void
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.org_accounts;
begin
  m := private.require(p_org, 'keep_books');
  select * into o from org_accounts where org_id = p_org and code = p_code;
  if not found then raise exception 'Only accounts your business added can be changed. TaxStreem standard accounts stay as they are.'; end if;
  if o.kind <> 'custom' and p_patch ? 'active' then raise exception 'Switch bank and wallet accounts off from Banking.'; end if;
  if coalesce((p_patch->>'active')::boolean, true) = false
     and exists (select 1 from journal_lines where org_id = p_org and account_code = p_code having sum(debit - credit) <> 0) then
    raise exception 'Move the balance off % before switching it off.', p_code;
  end if;
  update org_accounts set name = coalesce(nullif(trim(p_patch->>'name'), ''), name),
    description = case when p_patch ? 'description' then nullif(trim(p_patch->>'description'), '') else description end,
    active = coalesce((p_patch->>'active')::boolean, active)
  where org_id = p_org and code = p_code;
end $$;

-- ---------------------------------------------------------------------------
-- 11. Manual journals and reversals
-- ---------------------------------------------------------------------------
-- Control accounts are written by their sub-ledgers. A manual line on a receivable or payable needs
-- the customer or vendor it belongs to.
create or replace function public.post_manual_journal(p_org uuid, p_date date, p_memo text, p_lines jsonb, p_evidence jsonb default '[]'::jsonb)
returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; j public.journals; x jsonb; v_tz text; v_lines jsonb := '[]'::jsonb;
begin
  m := private.require(p_org, 'keep_books');
  if coalesce(trim(p_memo), '') = '' then raise exception 'Say what the journal is for. It appears in the ledger.'; end if;
  if p_date is null then raise exception 'Choose the journal date.'; end if;
  if p_date > private.local_day(p_org, now()) + 31 then raise exception 'A journal cannot be dated more than a month ahead.'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    if x->>'code' in ('1101', '1102') and nullif(x->>'party_id', '') is null then
      raise exception 'Lines on % need the customer they belong to.', x->>'code';
    end if;
    if x->>'code' in ('2101', '2102') and nullif(x->>'party_id', '') is null then
      raise exception 'Lines on % need the vendor they belong to.', x->>'code';
    end if;
    if x->>'code' in ('2201', '1402') and jsonb_array_length(coalesce(p_evidence, '[]'::jsonb)) = 0 then
      raise exception 'VAT accounts are written by sales and bills. A manual VAT line needs a supporting document attached.';
    end if;
    v_lines := v_lines || jsonb_build_array(x || jsonb_build_object('party_type',
      case when x->>'code' in ('1101', '1102') then 'customer' when x->>'code' in ('2101', '2102') then 'vendor' else x->>'party_type' end));
  end loop;
  select timezone into v_tz from orgs where id = p_org;
  j := private.post_entry(p_org, trim(p_memo), 'manual', null, m.id, m.id, v_lines,
    (p_date::timestamp + interval '12 hours') at time zone coalesce(v_tz, 'Africa/Lagos'),
    jsonb_build_object('origin', 'manual', 'evidence', coalesce(p_evidence, '[]'::jsonb)));
  return jsonb_build_object('id', j.id, 'ref', j.ref, 'entry_date', j.entry_date);
end $$;

create or replace function public.reverse_journal(p_journal uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare o public.journals; m public.members; r public.journals;
begin
  select * into o from journals where id = p_journal;
  if not found then raise exception 'Journal not found.'; end if;
  m := private.require(o.org_id, 'keep_books');
  if coalesce(trim(p_reason), '') = '' then raise exception 'Give a reason for the reversal.'; end if;
  if o.source_type not in ('manual', 'ai', 'bank', 'opening', 'reclass', 'accrual', 'depreciation', 'close_adj') then
    raise exception '% came from % and is reversed there (void the document) so the sub-ledger stays right.', o.ref, o.source_type;
  end if;
  r := private.reverse_entry(o.id, m.id, p_reason, null);
  return jsonb_build_object('id', r.id, 'ref', r.ref);
end $$;

-- ---------------------------------------------------------------------------
-- 12. Settings
-- ---------------------------------------------------------------------------
create or replace function public.update_org_settings(p_org uuid, p_patch jsonb) returns void
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_rev text;
begin
  m := private.require(p_org, 'owner');
  v_rev := nullif(p_patch->>'revenue_account', '');
  if v_rev is not null and v_rev !~ '^41(0[1-9]|1[0-9]|2[01])$' then raise exception 'Choose a revenue account from 4101 to 4121.'; end if;
  update orgs set
    name = coalesce(nullif(trim(p_patch->>'name'), ''), name),
    email = case when p_patch ? 'email' then nullif(trim(p_patch->>'email'), '') else email end,
    phone = case when p_patch ? 'phone' then nullif(trim(p_patch->>'phone'), '') else phone end,
    tin = case when p_patch ? 'tin' then nullif(trim(p_patch->>'tin'), '') else tin end,
    rc_number = case when p_patch ? 'rc_number' then nullif(trim(p_patch->>'rc_number'), '') else rc_number end,
    address = case when p_patch ? 'address' then nullif(trim(p_patch->>'address'), '') else address end,
    logo_path = case when p_patch ? 'logo_path' then nullif(trim(p_patch->>'logo_path'), '') else logo_path end,
    legal_form = coalesce(nullif(p_patch->>'legal_form', ''), legal_form),
    fiscal_year_start = coalesce((p_patch->>'fiscal_year_start')::int, fiscal_year_start),
    vat_registered = coalesce((p_patch->>'vat_registered')::boolean, vat_registered),
    prices_include_vat = coalesce((p_patch->>'prices_include_vat')::boolean, prices_include_vat),
    invoice_terms_days = coalesce((p_patch->>'invoice_terms_days')::int, invoice_terms_days),
    invoice_note = case when p_patch ? 'invoice_note' then nullif(trim(p_patch->>'invoice_note'), '') else invoice_note end,
    revenue_account = coalesce(v_rev, revenue_account),
    cash_sales_without_invoices = coalesce((p_patch->>'cash_sales_without_invoices')::boolean, cash_sales_without_invoices),
    capitalisation_threshold = coalesce((p_patch->>'capitalisation_threshold')::numeric, capitalisation_threshold),
    auto_post_threshold = coalesce((p_patch->>'auto_post_threshold')::numeric, auto_post_threshold),
    books_start = case when p_patch ? 'books_start' then private.date_or_null(p_patch->>'books_start') else books_start end
  where id = p_org;
  if v_rev is not null then
    insert into posting_rules (org_id, role, account_code, updated_by) values (p_org, 'sales_revenue', v_rev, m.id)
    on conflict (org_id, role) do update set account_code = excluded.account_code, updated_by = excluded.updated_by, updated_at = now();
  end if;
end $$;

grant execute on function public.get_chart(uuid), public.create_account(uuid, text, text, text), public.update_account(uuid, text, jsonb),
  public.post_manual_journal(uuid, date, text, jsonb, jsonb), public.reverse_journal(uuid, text), public.update_org_settings(uuid, jsonb),
  public.open_bank_account(uuid, text, text, jsonb), public.update_bank_account(uuid, jsonb) to authenticated;
revoke execute on function private.ifrs_meta(text, text), private.accounts_of(uuid), private.postable(uuid, text), private.account_name(uuid, text),
  private.check_journal_line(), private.post_entry(uuid, text, text, uuid, uuid, uuid, jsonb, timestamptz, jsonb),
  private.reverse_entry(uuid, uuid, text, timestamptz), private.open_bank_account(uuid, text, text, jsonb, uuid),
  private.move_parent_balance(uuid, text, text, uuid), private.party_key(text) from public, anon, authenticated;
