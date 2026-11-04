-- Counta · personal income tax for business names, sole proprietors and partnerships
--
-- A business on Counta is a company (companies income tax, as before), an NGO (incorporated trustees or a company limited by
-- guarantee: exempt unless it trades, NTA 2025 s.162(1)(a)(iii)), or a business name / partnership whose people pay
-- personal income tax to the state they belong to. This migration adds the third.
--
-- 1. Rule books. The old law for 2025 accounts (PITA rates, CRA, minimum tax, CGT kept apart) and the NTA 2025 for 2026
--    accounts onwards (Fourth Schedule rates, s.30 deductions, gains in income), stored as data beside the CIT ones.
--    private.rulebook() now returns CIT rule books only; private.pit_rulebook() the PIT ones.
-- 2. People: the proprietor or partners of the business (pit_people), and what each brings to a year (pit_person_years):
--    profit share, active or dormant, the office worked from or the state lived in, pay charged in the accounts, losses and
--    allowances brought forward, reliefs and other income. Personal figures are read only through the functions below.
-- 3. The year (pit_years): the private share of mixed-use expenses, the statement of accounts, the approval and its snapshot.
-- 4. The engine. The business's assessable profit comes from the CIT engine's adjustments to the books (one set of
--    figures and adjustments for both taxes), with the PIT rule book's own adjustments on top: mixed use, donations,
--    research above 5% of turnover. Capital allowances are worked out for the business and shared in the profit-sharing
--    ratio. private.pit_person_tax is a pure function: one person's computation from a bundle of inputs, the same shape
--    the Numen engine takes (docs/personal-income-tax.md).
-- 5. Which kind of business: private.income_tax_kind(). CIT is computed only for companies (and NGOs that trade); the
--    deadlines and the counts beside the menu follow.
-- 6. Filing: each person's return goes to Flux for the states it covers (Lagos first), or is marked filed by the
--    business; Flux reports back on /flux/pit-status and its files are kept under Documents, Tax, PIT.
-- Safe to run more than once.

-- ---------------------------------------------------------------------------
-- 1. Rule books
-- ---------------------------------------------------------------------------
alter table public.tax_rulebooks drop constraint if exists tax_rulebooks_regime_check;
alter table public.tax_rulebooks add constraint tax_rulebooks_regime_check check (regime in ('NTA_2025', 'LEGACY_CITA', 'PITA', 'NTA_2025_PIT'));

-- Drafts until TaxStreem signs off the points marked counta_reading (each computation lists them).
insert into public.tax_rulebooks (id, config_id, version, regime, yoa_from, yoa_to, status, config, approved_by, approved_at, note) values
  ('ng-pit-pita-legacy@1.0.0', 'ng-pit-pita-legacy', '1.0.0', 'PITA', null, 2026, 'draft', $rb${"$schema": "https://taxstreem.dev/schemas/pit-business-config-v1.json", "meta": {"config_id": "ng-pit-pita-legacy", "version": "1.0.0", "regime": "PITA", "governing_law": "Personal Income Tax Act (as amended to the Finance Act 2023)", "applies_to": "Accounts for years ending in 2025 (year of assessment 2026)", "sources": ["TaxStreem PIT rule book, s.1, s.2, s.4, s.5, s.9", "How personal tax reliefs are calculated in our engine (YOA 2025)", "TaxStreem answers of 4 November 2026"]}, "entity_kinds": {"sole_proprietor": "A business name with one proprietor, or a business that is not registered: taxed on the whole profit (PIT rule book s.1).", "partnership": "A business name with two or more proprietors, a limited partnership, or an unregistered partnership: the profit is shared and each partner is taxed on his share (s.15).", "exempt": "Incorporated trustees and companies limited by guarantee: exempt except on profits from a trade or business (s.162(1)(a)(iii))."}, "tax_bands": [{"label": "First ₦300,000", "width": 300000, "rate": 0.07}, {"label": "Next ₦300,000", "width": 300000, "rate": 0.11}, {"label": "Next ₦500,000", "width": 500000, "rate": 0.15}, {"label": "Next ₦500,000", "width": 500000, "rate": 0.19}, {"label": "Next ₦1,600,000", "width": 1600000, "rate": 0.21}, {"label": "Above ₦3,200,000", "width": null, "rate": 0.24}], "reliefs": {"method": "cra", "exempt_items": ["pension", "nhf", "nhis", "life_insurance", "gratuity"], "after_cra": ["home_loan_interest"], "cra": {"fixed_ngn": 200000, "fixed_pct": 0.01, "variable_pct": 0.2, "base": "Total income less the tax-exempt contributions (pension, NHF, NHIS, life insurance, gratuity)"}}, "minimum_tax": {"applies": true, "rate": 0.01, "base": "the same figure the CRA is worked on"}, "chargeable_gains": {"in_total_income": false, "separate_rate": 0.1, "law": "Capital Gains Tax Act"}, "losses": {"carry_forward_years": 4}, "capital_allowances": {"law": "legacy", "restriction_two_thirds": false}, "business": {"rd_cap_pct_of_turnover": 0.05, "donations_deductible": false, "mixed_use": {"business_pct": 50, "lines": [{"cell": "ADMINISTRATIVE_EXPENSES!C25", "group": "vehicle", "label": "Fuel and vehicle running costs"}, {"cell": "ADMINISTRATIVE_EXPENSES!C64", "group": "vehicle", "label": "Petrol (PMS)"}, {"cell": "ADMINISTRATIVE_EXPENSES!C28", "group": "internet", "label": "Internet and data"}, {"cell": "ADMINISTRATIVE_EXPENSES!C43", "group": "internet", "label": "Telephone"}, {"cell": "ADMINISTRATIVE_EXPENSES!C63", "group": "power", "label": "Electricity and power"}, {"cell": "ADMINISTRATIVE_EXPENSES!C47", "group": "power", "label": "Water and other utilities"}, {"cell": "ADMINISTRATIVE_EXPENSES!C26", "group": "power", "label": "Generator running"}, {"cell": "ADMINISTRATIVE_EXPENSES!C68", "group": "power", "label": "Diesel (AGO)"}, {"cell": "ADMINISTRATIVE_EXPENSES!C34", "group": "home", "label": "Rent of a home also used as the office"}]}}, "other_income": {"kinds": ["employment", "rent", "dividend", "interest", "royalty", "foreign_earned", "foreign_investment", "gov_bond_interest", "pension_gratuity", "other"], "final_tax_kinds": ["dividend", "interest"], "exempt_kinds": ["gov_bond_interest", "foreign_investment", "pension_gratuity"], "minimum_wage_monthly_ngn": 70000}, "filing": {"due_month": 3, "due_day": 31, "flux_authorities": ["SIRS:LA"]}, "configurable_flags": {"flags": {"P-1": {"title": "Old law for 2025", "reading": "Accounts for 2025 (filed in 2026) use the old rates and reliefs, with chargeable gains left out of taxable profit.", "source": "PIT rule book s.1, s.9", "status": "agreed"}, "P-2": {"title": "CRA and minimum tax", "reading": "CRA is the higher of ₦200,000 or 1%, plus 20%, of total income less pension, NHF, NHIS, life insurance and gratuity (the Finance Act 2020 meaning of gross income). Home loan interest comes off after the CRA. Minimum tax is 1% of the same figure the CRA is worked on, payable when the tax at the rates is lower.", "source": "Reliefs note (YOA 2025); TaxStreem answer, 4 November 2026", "status": "agreed"}, "P-7": {"title": "Gains under the old law", "reading": "Gains on disposals are left out of income and shown separately, with capital gains tax at 10% on each person's share, for the capital gains tax return.", "source": "PIT rule book s.1; Capital Gains Tax Act s.2", "status": "agreed"}, "P-3": {"title": "Due date", "reading": "The return is due on 31 March of the year after the accounting year ends, whatever month the year ends in.", "source": "TaxStreem answer, 4 November 2026", "status": "agreed"}, "P-4": {"title": "Whole return", "reading": "Each person's return covers their share of the business and any other income they declare (employment, rent, dividends, interest, royalties, foreign income), with their reliefs.", "source": "TaxStreem answer, 4 November 2026", "status": "agreed"}, "P-8": {"title": "Capital allowances", "reading": "Allowances are worked out for the business as one enterprise and shared in the profit-sharing ratio at the year end (First Schedule para 19(3)). An asset used partly for private life gets the business share of its allowance (para 16). 2025 accounts use the old initial and annual allowances with ₦10 kept on each asset, with no two-thirds restriction and no investment allowance for individuals; 2026 accounts onwards the First Schedule rates on cost with 1% kept.", "source": "NTA 2025 First Schedule paras 16, 19, 22, 23; PITA (as amended)", "status": "counta_reading"}, "P-9": {"title": "Losses", "reading": "A business loss is carried forward against the person's later business income only, never set against other income. Under the NTA there is no time limit (s.28(3)). Losses brought into 2025 accounts are taken as entered; the four-year limit of the old law is for the person to observe.", "source": "NTA 2025 s.15(2), s.28(3); PITA s.35", "status": "counta_reading"}, "P-10": {"title": "Partners' pay", "reading": "Salary, interest on capital and benefits charged in the accounts for a partner go to that partner before the profit is shared (s.15(1)(a)). A sole proprietor's own pay charged as an expense is his drawing and is added back to him. Private or domestic expenses of a partner are never deducted.", "source": "NTA 2025 s.15(1), s.21(c)", "status": "counta_reading"}, "P-11": {"title": "Which state", "reading": "A partner engaged in the business pays the state of the office he works from; a dormant partner pays the state he usually lives in; a dormant partner who does not live in Nigeria pays the NRS. A sole proprietor pays the state he lived in on 1 January of the year of assessment.", "source": "NTA 2025 Twelfth Schedule paras 4 and 6; NTAA 2025 s.3", "status": "counta_reading"}, "P-12": {"title": "WHT credit notes", "reading": "WHT credit notes the business holds at the year end (account 1401), less those already used in earlier returns, are shared in the profit-sharing ratio and set against each person's tax. What a person cannot use stays for later years.", "source": "Counta reading", "status": "counta_reading"}, "P-13": {"title": "Tax deducted at source", "reading": "Dividends and interest on which tax was deducted at source are taken as taxed in full (final tax) and left out of total income. Interest on government bonds, foreign dividends, interest, rent and royalties brought in through a domiciliary account, and pensions and gratuities are exempt. Employment income of the national minimum wage or less is exempt.", "source": "NTA 2025 s.28(2)(b)(iii) and (iv), s.162(1)(i), (n), (s) and (t); PIT rule book s.6", "status": "counta_reading"}, "P-14": {"title": "Research and development", "reading": "Research and development costs above 5% of turnover are added back, as the PIT rule book says. (The 5% limit in s.164 is written for companies; s.20(1)(i) gives no limit.)", "source": "PIT rule book s.2", "status": "counta_reading"}, "P-15": {"title": "Donations", "reading": "Donations are not deductible for a business name or partnership: the deduction in s.163 is for companies, and a gift is not an expense incurred in producing the income.", "source": "NTA 2025 s.20, s.163", "status": "counta_reading"}, "P-16": {"title": "Mixed use", "reading": "For each expense the business marks as used partly for private life (car, internet, power, a home that is also the office) only the business share is deducted, 50% unless the business sets another share. The business must confirm which apply before approving.", "source": "PIT rule book s.4", "status": "agreed"}}}}$rb$::jsonb, null, null,
   'Drafted by Counta from the TaxStreem PIT rule book, the reliefs note and PITA; P-1 to P-4, P-7 and P-16 agreed by TaxStreem (Kelechi Ibe), 4 November 2026.'),
  ('ng-pit-nta-2025@1.0.0', 'ng-pit-nta-2025', '1.0.0', 'NTA_2025_PIT', 2027, null, 'draft', $rb${"$schema": "https://taxstreem.dev/schemas/pit-business-config-v1.json", "meta": {"config_id": "ng-pit-nta-2025", "version": "1.0.0", "regime": "NTA_2025_PIT", "governing_law": "Nigeria Tax Act 2025 and Nigeria Tax Administration Act 2025", "applies_to": "Accounts for years ending in 2026 and later (year of assessment 2027 onwards)", "sources": ["TaxStreem PIT rule book, s.1 to s.10, s.12", "How personal tax reliefs are calculated in our engine (YOA 2026)", "NTA 2025 s.15, s.20, s.21, s.28, s.30, s.58, Fourth and Twelfth Schedules", "TaxStreem answers of 4 November 2026"]}, "entity_kinds": {"sole_proprietor": "A business name with one proprietor, or a business that is not registered: taxed on the whole profit (PIT rule book s.1).", "partnership": "A business name with two or more proprietors, a limited partnership, or an unregistered partnership: the profit is shared and each partner is taxed on his share (s.15).", "exempt": "Incorporated trustees and companies limited by guarantee: exempt except on profits from a trade or business (s.162(1)(a)(iii))."}, "tax_bands": [{"label": "First ₦800,000", "width": 800000, "rate": 0.0}, {"label": "Next ₦2,200,000", "width": 2200000, "rate": 0.15}, {"label": "Next ₦9,000,000", "width": 9000000, "rate": 0.18}, {"label": "Next ₦13,000,000", "width": 13000000, "rate": 0.21}, {"label": "Next ₦25,000,000", "width": 25000000, "rate": 0.23}, {"label": "Above ₦50,000,000", "width": null, "rate": 0.25}], "reliefs": {"method": "s30", "items": ["nhf", "nhis", "pension", "home_loan_interest", "life_insurance"], "rent_relief": {"pct": 0.2, "cap_ngn": 500000}}, "minimum_tax": {"applies": false}, "chargeable_gains": {"in_total_income": true}, "losses": {"carry_forward_years": null}, "capital_allowances": {"law": "nta", "restriction_two_thirds": false}, "business": {"rd_cap_pct_of_turnover": 0.05, "donations_deductible": false, "mixed_use": {"business_pct": 50, "lines": [{"cell": "ADMINISTRATIVE_EXPENSES!C25", "group": "vehicle", "label": "Fuel and vehicle running costs"}, {"cell": "ADMINISTRATIVE_EXPENSES!C64", "group": "vehicle", "label": "Petrol (PMS)"}, {"cell": "ADMINISTRATIVE_EXPENSES!C28", "group": "internet", "label": "Internet and data"}, {"cell": "ADMINISTRATIVE_EXPENSES!C43", "group": "internet", "label": "Telephone"}, {"cell": "ADMINISTRATIVE_EXPENSES!C63", "group": "power", "label": "Electricity and power"}, {"cell": "ADMINISTRATIVE_EXPENSES!C47", "group": "power", "label": "Water and other utilities"}, {"cell": "ADMINISTRATIVE_EXPENSES!C26", "group": "power", "label": "Generator running"}, {"cell": "ADMINISTRATIVE_EXPENSES!C68", "group": "power", "label": "Diesel (AGO)"}, {"cell": "ADMINISTRATIVE_EXPENSES!C34", "group": "home", "label": "Rent of a home also used as the office"}]}}, "other_income": {"kinds": ["employment", "rent", "dividend", "interest", "royalty", "foreign_earned", "foreign_investment", "gov_bond_interest", "pension_gratuity", "other"], "final_tax_kinds": ["dividend", "interest"], "exempt_kinds": ["gov_bond_interest", "foreign_investment", "pension_gratuity"], "minimum_wage_monthly_ngn": 70000}, "filing": {"due_month": 3, "due_day": 31, "flux_authorities": ["SIRS:LA"]}, "configurable_flags": {"flags": {"P-1": {"title": "New law from 2026", "reading": "Accounts for 2026 and later use the Fourth Schedule rates and the s.30 deductions, with chargeable gains in total income.", "source": "PIT rule book s.1, s.10", "status": "agreed"}, "P-5": {"title": "No minimum tax", "reading": "The NTA has no minimum tax for individuals, and the exemption for those earning the national minimum wage (s.162(1)(t)) covers employment income only, so neither applies to business profit. (The Numen contract applies both.)", "source": "NTA 2025 s.58, s.162(1)(t)", "status": "counta_reading"}, "P-6": {"title": "Gains in income", "reading": "Gains on the business's disposals are shared in the profit-sharing ratio and taxed with each person's income at the Fourth Schedule rates. A net loss on disposals is carried forward with the business loss (s.28(3)(b)).", "source": "NTA 2025 s.28(2)(a)(v), s.28(3)", "status": "counta_reading"}, "P-3": {"title": "Due date", "reading": "The return is due on 31 March of the year after the accounting year ends, whatever month the year ends in.", "source": "TaxStreem answer, 4 November 2026", "status": "agreed"}, "P-4": {"title": "Whole return", "reading": "Each person's return covers their share of the business and any other income they declare (employment, rent, dividends, interest, royalties, foreign income), with their reliefs.", "source": "TaxStreem answer, 4 November 2026", "status": "agreed"}, "P-8": {"title": "Capital allowances", "reading": "Allowances are worked out for the business as one enterprise and shared in the profit-sharing ratio at the year end (First Schedule para 19(3)). An asset used partly for private life gets the business share of its allowance (para 16). 2025 accounts use the old initial and annual allowances with ₦10 kept on each asset, with no two-thirds restriction and no investment allowance for individuals; 2026 accounts onwards the First Schedule rates on cost with 1% kept.", "source": "NTA 2025 First Schedule paras 16, 19, 22, 23; PITA (as amended)", "status": "counta_reading"}, "P-9": {"title": "Losses", "reading": "A business loss is carried forward against the person's later business income only, never set against other income. Under the NTA there is no time limit (s.28(3)). Losses brought into 2025 accounts are taken as entered; the four-year limit of the old law is for the person to observe.", "source": "NTA 2025 s.15(2), s.28(3); PITA s.35", "status": "counta_reading"}, "P-10": {"title": "Partners' pay", "reading": "Salary, interest on capital and benefits charged in the accounts for a partner go to that partner before the profit is shared (s.15(1)(a)). A sole proprietor's own pay charged as an expense is his drawing and is added back to him. Private or domestic expenses of a partner are never deducted.", "source": "NTA 2025 s.15(1), s.21(c)", "status": "counta_reading"}, "P-11": {"title": "Which state", "reading": "A partner engaged in the business pays the state of the office he works from; a dormant partner pays the state he usually lives in; a dormant partner who does not live in Nigeria pays the NRS. A sole proprietor pays the state he lived in on 1 January of the year of assessment.", "source": "NTA 2025 Twelfth Schedule paras 4 and 6; NTAA 2025 s.3", "status": "counta_reading"}, "P-12": {"title": "WHT credit notes", "reading": "WHT credit notes the business holds at the year end (account 1401), less those already used in earlier returns, are shared in the profit-sharing ratio and set against each person's tax. What a person cannot use stays for later years.", "source": "Counta reading", "status": "counta_reading"}, "P-13": {"title": "Tax deducted at source", "reading": "Dividends and interest on which tax was deducted at source are taken as taxed in full (final tax) and left out of total income. Interest on government bonds, foreign dividends, interest, rent and royalties brought in through a domiciliary account, and pensions and gratuities are exempt. Employment income of the national minimum wage or less is exempt.", "source": "NTA 2025 s.28(2)(b)(iii) and (iv), s.162(1)(i), (n), (s) and (t); PIT rule book s.6", "status": "counta_reading"}, "P-14": {"title": "Research and development", "reading": "Research and development costs above 5% of turnover are added back, as the PIT rule book says. (The 5% limit in s.164 is written for companies; s.20(1)(i) gives no limit.)", "source": "PIT rule book s.2", "status": "counta_reading"}, "P-15": {"title": "Donations", "reading": "Donations are not deductible for a business name or partnership: the deduction in s.163 is for companies, and a gift is not an expense incurred in producing the income.", "source": "NTA 2025 s.20, s.163", "status": "counta_reading"}, "P-16": {"title": "Mixed use", "reading": "For each expense the business marks as used partly for private life (car, internet, power, a home that is also the office) only the business share is deducted, 50% unless the business sets another share. The business must confirm which apply before approving.", "source": "PIT rule book s.4", "status": "agreed"}}}}$rb$::jsonb, null, null,
   'Drafted by Counta from the TaxStreem PIT rule book, the reliefs note and the NTA 2025; P-1, P-3, P-4 and P-16 agreed by TaxStreem (Kelechi Ibe), 4 November 2026.')
on conflict (id) do update set config = excluded.config, regime = excluded.regime,
  status = case when public.tax_rulebooks.status = 'approved' then public.tax_rulebooks.status else excluded.status end,
  yoa_from = excluded.yoa_from, yoa_to = excluded.yoa_to, note = excluded.note;

-- The companies income tax rule book for a year of assessment (CIT rule books only, now that PIT ones share the table).
CREATE OR REPLACE FUNCTION private.rulebook(p_yoa integer)
 RETURNS tax_rulebooks
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select r.* from tax_rulebooks r
  where r.regime in ('NTA_2025', 'LEGACY_CITA') and r.status in ('approved', 'draft') and (r.yoa_from is null or r.yoa_from <= p_yoa) and (r.yoa_to is null or r.yoa_to >= p_yoa)
  order by (r.status = 'approved') desc, r.created_at desc limit 1
$function$;

-- ---------------------------------------------------------------------------
-- 2. People and years
-- ---------------------------------------------------------------------------
-- The proprietor of a business name, or its partners. Filled from the names on the CAC record (or the owner) the first
-- time someone opens Income tax, and kept by the business from then on.
create table if not exists public.pit_people (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  name text not null check (length(trim(name)) between 2 and 120),
  tin text check (tin is null or tin ~ '^[0-9][0-9-]{6,15}$'),
  member_id uuid references public.members(id) on delete set null,
  source text not null default 'added' check (source in ('cac', 'owner', 'added')),
  active boolean not null default true,
  sort int not null default 100,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists pit_people_org on public.pit_people(org_id);
create index if not exists pit_people_member_fk on public.pit_people(member_id);
create index if not exists pit_people_created_by_fk on public.pit_people(created_by);
create unique index if not exists pit_people_one_member on public.pit_people(org_id, member_id) where member_id is not null;
alter table public.pit_people enable row level security;
revoke all on public.pit_people from anon, authenticated;

-- One row per business per accounting year once someone has worked on it. status: draft, approved (frozen in snapshot),
-- filed_outside (the business filed the year itself, before or outside Counta). settings: {mixed_use: {template cell:
-- business share %}, mixed_use_reviewed, notes, reopened}. soa_path: the statement of accounts (NTAA 2025 s.13(2)(d)).
create table if not exists public.pit_years (
  org_id uuid not null references public.orgs(id) on delete cascade,
  accounting_year int not null check (accounting_year between 2025 and 2100),
  status text not null default 'draft' check (status in ('draft', 'approved', 'filed_outside')),
  settings jsonb not null default '{}'::jsonb,
  soa_path text,
  snapshot jsonb,
  rulebook_id text references public.tax_rulebooks(id),
  approved_by uuid references public.members(id) on delete set null,
  approved_at timestamptz,
  updated_by uuid references public.members(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (org_id, accounting_year)
);
create index if not exists pit_years_rulebook_fk on public.pit_years(rulebook_id);
create index if not exists pit_years_approved_by_fk on public.pit_years(approved_by);
create index if not exists pit_years_updated_by_fk on public.pit_years(updated_by);
alter table public.pit_years enable row level security;
revoke all on public.pit_years from anon, authenticated;

-- What a person brings to a year. A person with no row for a year takes last year's share, role, office and state (or an
-- equal share and the head office). reliefs: {pension, nhf, nhis, life_insurance, home_loan_interest, gratuity, rent_paid};
-- other_income: [{kind, label, amount, tax_deducted, final_tax}]; opening: {losses_bf, ca_bf} for the first year Counta
-- prepares for the person. status follows the person's own return once the year is approved.
create table if not exists public.pit_person_years (
  org_id uuid not null references public.orgs(id) on delete cascade,
  accounting_year int not null check (accounting_year between 2025 and 2100),
  person_id uuid not null references public.pit_people(id) on delete cascade,
  included boolean not null default true,
  share_pct numeric(9,4) check (share_pct is null or share_pct between 0 and 100),
  role text check (role is null or role in ('proprietor', 'active', 'dormant')),
  office_location_id uuid references public.locations(id) on delete set null,
  residence text references public.tax_authorities(code),
  resident boolean,
  remuneration numeric(18,2) not null default 0 check (remuneration >= 0),
  remuneration_note text check (remuneration_note is null or length(remuneration_note) <= 300),
  opening jsonb not null default '{}'::jsonb,
  reliefs jsonb not null default '{}'::jsonb,
  other_income jsonb not null default '[]'::jsonb,
  status text not null default 'draft' check (status in ('draft', 'approved', 'sent', 'filed', 'rejected')),
  flux_ref text,
  flux_status text,
  flux_message text,
  flux_sent_at timestamptz,
  flux_updated_at timestamptz,
  filed_at timestamptz,
  filed_by_business boolean not null default false,
  acknowledgement_ref text,
  assessment jsonb,
  payment_url text,
  updated_by uuid references public.members(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (org_id, accounting_year, person_id)
);
create index if not exists pit_person_years_person_fk on public.pit_person_years(person_id);
create index if not exists pit_person_years_office_fk on public.pit_person_years(office_location_id);
create index if not exists pit_person_years_residence_fk on public.pit_person_years(residence);
create index if not exists pit_person_years_updated_by_fk on public.pit_person_years(updated_by);
alter table public.pit_person_years enable row level security;
revoke all on public.pit_person_years from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Documents: the files Flux sends back for a PIT return are kept under Tax, PIT
-- ---------------------------------------------------------------------------
alter table public.documents drop constraint if exists documents_tax_check;
alter table public.documents add constraint documents_tax_check check (tax is null or tax in ('vat', 'wht', 'wvat', 'cit', 'pit'));
CREATE OR REPLACE FUNCTION public.svc_document_add(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare v_org uuid := (p->>'org_id')::uuid; v_tax text := nullif(p->>'tax', ''); v_kind text := coalesce(nullif(p->>'kind', ''), 'other'); d public.documents;
  v_period date := case when p->>'period' ~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then (p->>'period' || '-01')::date end; t public.tax_payment_instructions;
begin
  -- A file sent with a payment's status names its PRN; the tax and period are the PRN's.
  if v_tax is null and nullif(p->>'prn', '') is not null then
    select * into t from tax_payment_instructions where org_id = v_org and prn = p->>'prn';
    if found then
      v_tax := t.tax;
      v_period := case when t.tax = 'cit' then null else date_trunc('month', t.period)::date end;
      p := p || jsonb_build_object('year', coalesce(t.accounting_year, extract(year from t.period)::int));
    end if;
  end if;
  if v_tax is null or v_tax not in ('vat', 'wht', 'wvat', 'cit', 'pit') then raise exception 'Unknown tax.'; end if;
  if coalesce(p->>'path', '') !~ ('^' || v_org::text || '/tax/flux/') then raise exception 'Flux files are stored under the business''s tax/flux folder.'; end if;
  insert into documents (org_id, cat, folder, sub, period, year, name, path, mime, size, source, kind, tax)
  values (v_org, 'tax', case v_tax when 'vat' then 'VAT' when 'wht' then 'WHT' when 'wvat' then 'Withholding VAT' when 'pit' then 'PIT' else 'CIT' end,
    case v_kind when 'acknowledgement' then 'Filing evidence' when 'filing_evidence' then 'Filing evidence' when 'assessment' then 'Filing evidence'
      when 'prn' then 'PRN and payment' when 'payment_receipt' then 'Payment receipts' when 'tax_clearance' then 'Payment receipts' else 'From Flux' end,
    case when v_tax in ('cit', 'pit') then null else v_period end,
    coalesce(nullif(p->>'year', '')::int, extract(year from v_period)::int),
    left(coalesce(nullif(trim(p->>'name'), ''), 'Flux file'), 200), p->>'path', nullif(left(p->>'mime', 120), ''), nullif(p->>'size', '')::bigint,
    'flux', left(v_kind, 40), v_tax)
  on conflict (path) do update set name = excluded.name, mime = excluded.mime, size = excluded.size, kind = excluded.kind
  returning * into d;
  return jsonb_build_object('id', d.id, 'folder', d.folder, 'sub', d.sub);
end $function$;

CREATE OR REPLACE FUNCTION private.doc_folder_rank(p_cat text, p_folder text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select coalesce(array_position(case p_cat
    when 'sales' then array['Invoices', 'Receipts', 'Till receipts', 'Credit notes', 'Quotes', 'Orders', 'Delivery proofs']
    when 'purchases' then array['Supplier invoices', 'From suppliers', 'Claim input VAT', 'Stock received', 'Supplier credit notes', 'Import entries']
    when 'tax' then array['VAT', 'WHT', 'Withholding VAT', 'CIT', 'PIT']
    else array[]::text[] end, p_folder), 50)
$function$;

CREATE OR REPLACE FUNCTION public.document_save(p_org uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; v_cat text := coalesce(nullif(p->>'cat', ''), 'other'); v_path text := p->>'path';
  v_period date; v_year int := nullif(p->>'year', '')::int; v_folder text := nullif(left(trim(p->>'folder'), 60), ''); d public.documents;
begin
  m := private.require(p_org, null);
  if v_cat not in ('sales', 'purchases', 'tax', 'bank', 'accountant', 'company', 'other') then raise exception 'Choose what kind of document it is.'; end if;
  if coalesce((private.doc_can(m)->>v_cat)::boolean, false) is not true then raise exception 'Your role does not keep that kind of document.' using errcode = '42501'; end if;
  if v_path is null or v_path !~ ('^' || p_org::text || case when v_cat = 'tax' then '/tax/uploads/' else '/documents/' || v_cat || '/' end || '[0-9a-f-]{36}-[^/]{1,160}$') then
    raise exception 'Upload the file through Counta.';
  end if;
  if nullif(p->>'period', '') is not null then
    if p->>'period' !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception 'The month looks like 2026-10.'; end if;
    v_period := (p->>'period' || '-01')::date; v_year := extract(year from v_period)::int;
  end if;
  if v_cat = 'company' then v_period := null; v_year := null; end if;
  if v_folder is null then
    v_folder := case v_cat when 'sales' then 'Uploaded' when 'purchases' then 'Uploaded' when 'tax' then 'Uploaded' when 'bank' then 'Statements'
      when 'accountant' then 'Uploaded' when 'company' then 'Company files' else 'Uploaded' end;
  end if;
  if v_cat = 'tax' and v_folder not in ('VAT', 'WHT', 'Withholding VAT', 'CIT', 'PIT', 'Uploaded') then raise exception 'Choose VAT, WHT, withholding VAT, CIT or PIT.'; end if;
  insert into documents (org_id, cat, folder, sub, period, year, name, path, mime, size, source, notes, uploaded_by,
    tax)
  values (p_org, v_cat, v_folder, case when v_cat = 'tax' and v_folder <> 'Uploaded' then 'Uploaded' end, v_period, v_year,
    left(coalesce(nullif(trim(p->>'name'), ''), regexp_replace(v_path, '^.*/[0-9a-f-]{36}-', '')), 200), v_path,
    nullif(left(p->>'mime', 120), ''), nullif(p->>'size', '')::bigint, 'upload', nullif(left(trim(p->>'notes'), 500), ''), m.id,
    case v_folder when 'VAT' then 'vat' when 'WHT' then 'wht' when 'Withholding VAT' then 'wvat' when 'CIT' then 'cit' when 'PIT' then 'pit' end)
  on conflict (path) do nothing returning * into d;
  if d.id is null then raise exception 'That file is in Documents already.'; end if;
  return jsonb_build_object('id', d.id, 'path', d.path);
end $function$;

-- ---------------------------------------------------------------------------
-- 5. Which kind of business, for income tax
-- ---------------------------------------------------------------------------
-- CAC calls a company limited by guarantee a company; for tax it is an NGO, exempt unless it trades. The CAC record Counta
-- reads through Mono gives the type of company, so the business is marked when its profile is submitted.
create or replace function private.cac_guarantee(p_cac jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select upper(coalesce(p_cac->'profile'->>'classification', '')) like 'COMPANY%'
     and coalesce(p_cac->'profile'->>'company_type_name', '') ~* 'guarantee'
$$;

-- CAC's record marks the business once; after that the owner's answer (save_income_tax_setup) stands, even when CAC is read again.
create or replace function private.kyc_guarantee_mark() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.org_id is not null and private.cac_guarantee(new.cac) then
    update orgs set cit_profile = coalesce(cit_profile, '{}'::jsonb) || '{"limited_by_guarantee": true}'::jsonb
    where id = new.org_id and not (coalesce(cit_profile, '{}'::jsonb) ? 'limited_by_guarantee');
  end if;
  return new;
end $$;
drop trigger if exists kyc_guarantee_mark on public.kyc_profiles;
create trigger kyc_guarantee_mark after insert or update of org_id, cac, status on public.kyc_profiles
  for each row execute function private.kyc_guarantee_mark();
update orgs o set cit_profile = coalesce(o.cit_profile, '{}'::jsonb) || '{"limited_by_guarantee": true}'::jsonb
from kyc_profiles k where k.org_id = o.id and private.cac_guarantee(k.cac) and not (coalesce(o.cit_profile, '{}'::jsonb) ? 'limited_by_guarantee');

-- The people in a year: those with a row for it (and included), and active people with no row for it.
create or replace function private.pit_headcount(p_org uuid, p_year int) returns int
language sql stable security definer set search_path = public, private as $$
  select count(*)::int from pit_people pp
  where pp.org_id = p_org
    and case when p_year is not null and exists (select 1 from pit_person_years y where y.org_id = p_org and y.accounting_year = p_year and y.person_id = pp.id)
             then exists (select 1 from pit_person_years y where y.org_id = p_org and y.accounting_year = p_year and y.person_id = pp.id and y.included)
             else pp.active end
$$;

-- 'company' (companies income tax), 'exempt' (an NGO that does not trade), 'sole' or 'partnership' (personal income tax
-- through its people). orgs.legal_form comes from the CAC classification: COMPANY..., BUSINESS_NAME (enterprise), IT (ngo),
-- LP (partnership), or individual for a business that is not registered. A business name with two or more people is a
-- partnership; an LP always is.
create or replace function private.income_tax_kind(p_org uuid, p_year int default null) returns text
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs;
begin
  select * into o from orgs where id = p_org;
  if o.id is null then return null; end if;
  if o.legal_form = 'ngo' or coalesce((o.cit_profile->>'limited_by_guarantee')::boolean, false) then
    return case when coalesce((o.cit_profile->>'ngo_trades')::boolean, false) then 'company' else 'exempt' end;
  end if;
  if coalesce(o.legal_form, 'company') = 'company' then return 'company'; end if;
  if o.legal_form = 'partnership' then return 'partnership'; end if;
  return case when private.pit_headcount(p_org, p_year) >= 2 then 'partnership' else 'sole' end;
end $$;

-- ---------------------------------------------------------------------------
-- 5b. The CIT engine: companies only (and NGOs that trade); capital allowances can follow the PIT boundary between the old
--     law and the NTA (2025 accounts) and always give the business share of a partly private asset; the figures behind an
--     approved PIT year stay as they were approved.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.cit_compute(p_org uuid, p_year integer, p_bf jsonb DEFAULT NULL::jsonb, p_as_of date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare o public.orgs; cy public.cit_years; rbr public.tax_rulebooks; rb jsonb; v_yoa int := p_year + 1; v_from date; v_to date; v_upto date;
  v_source text; bk jsonb; cells jsonb := '{}'::jsonb; det jsonb := '{}'::jsonb; codes jsonb := '{}'::jsonb; t jsonb; x record; k text; v_amt numeric;
  st jsonb; adj jsonb; prof jsonb; ca jsonb; items jsonb := '{}'::jsonb; pa jsonb := '{}'::jsonb; v_auto jsonb; i int;
  v_pbt numeric; v_turn numeric; v_fii numeric; v_fixed numeric; v_dep numeric; v_amort numeric; v_int numeric; v_ebitda numeric; v_conn numeric;
  v_cap_pct numeric; v_excess numeric := 0; v_capacity numeric := 0; v_relief numeric := 0; v_int_bf jsonb; v_int_cf jsonb := '[]'::jsonb; v_avail numeric;
  v_use numeric; v_don numeric; v_don_listed numeric; v_don_cap numeric; v_don_base numeric; v_don_out numeric; v_b numeric; v_c numeric; v_d numeric;
  v_loss_bf numeric; v_ca_bf numeric; v_e1 numeric; v_rem numeric; v_ca_avail numeric; v_e2 numeric; v_f numeric; v_g numeric; v_h numeric; v_lev numeric := 0;
  v_j numeric := 0; v_k numeric; v_class text; v_rate numeric; v_small boolean; v_company boolean; v_nonres boolean; v_etr boolean; v_ni numeric; v_cov numeric;
  v_ap numeric; v_bc numeric; v_cap numeric; v_restricted boolean; v_mt numeric := 0; v_mt_applies boolean := false; v_mt_used boolean := false; v_tet numeric := 0;
  v_tet_rate numeric; v_wht numeric; v_wht_used numeric; v_loss_new numeric; v_loss_cf numeric; v_ca_cf numeric; v_legacy boolean; v_rows jsonb := '[]'::jsonb;
  v_checks jsonb := '[]'::jsonb; v_flags jsonb; v_lev_base numeric; v_gain_inv numeric; v_gains_other numeric; v_loss_vs_gains numeric := 0; v_ntax numeric;
  v_short numeric := 1; v_first_open boolean; v_comm date; v_years_in int; v_exempt_sector boolean; v_manu numeric; v_sum numeric; v_others jsonb := '[]'::jsonb;
  v_books_pbt numeric; v_ended boolean; v_cell text; v_imp jsonb; v_ovr jsonb; v_cit_payable numeric; v_ca_used_detail jsonb; v_dlevy_applies boolean;
begin
  select * into o from orgs where id = p_org;
  select * into cy from cit_years where org_id = p_org and accounting_year = p_year;
  select pfrom, pto into v_from, v_to from private.cit_period(p_org, p_year);
  v_upto := least(coalesce(p_as_of, v_to), v_to);
  v_ended := private.local_day(p_org, now()) > v_to;
  rbr := private.rulebook(v_yoa); rb := rbr.config;
  v_legacy := rbr.regime = 'LEGACY_CITA';
  v_flags := coalesce(rb->'configurable_flags'->'flags', '{}'::jsonb);
  st := coalesce(cy.settings, '{}'::jsonb);
  adj := coalesce(cy.adjustments, '{}'::jsonb);
  prof := coalesce(o.cit_profile, '{}'::jsonb);
  v_source := coalesce(cy.source, private.cit_default_source(p_org, v_from, v_to));

  -- Figures: from the books (with any lines the business changed), or from audited accounts / a trial balance mapped onto the template.
  if v_source = 'books' then
    bk := private.cit_books_figures(p_org, v_from, v_upto);
    cells := bk->'cells'; det := bk->'detail'; codes := bk->'codes';
    v_books_pbt := (private.cit_totals(cells)->>'profit_before_tax')::numeric;
    for x in select key, value from jsonb_each(coalesce(cy.overrides, '{}'::jsonb)) loop
      cells := case when coalesce((x.value->>'amount')::numeric, 0) = 0 then cells - x.key else jsonb_set(cells, array[x.key], to_jsonb(round((x.value->>'amount')::numeric, 2))) end;
    end loop;
  else
    for x in select key, value from jsonb_each(coalesce(cy.imported, '{}'::jsonb)) where key not like 'PROFIT_ADJUSTMENT!%' and key <> 'INCOME_STATEMENT!D113' loop
      if coalesce((x.value->>'amount')::numeric, 0) <> 0 then cells := jsonb_set(cells, array[x.key], to_jsonb(round((x.value->>'amount')::numeric, 2))); end if;
    end loop;
  end if;
  cells := cells - 'INCOME_STATEMENT!D113';
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into cells from jsonb_each(cells) where key not like 'PROFIT_ADJUSTMENT!%';
  t := private.cit_totals(cells);
  v_pbt := round((t->>'profit_before_tax')::numeric, 2);
  v_turn := round((t->>'revenue')::numeric, 2);
  v_fii := private.v(cells, 'OTHER_INCOME!D8');
  v_fixed := private.v(t, 'ppe') + private.v(t, 'intangibles');
  v_dep := private.v(t, 'depreciation'); v_amort := private.v(t, 'amortisation'); v_int := private.v(t, 'interest_expense');
  v_company := private.income_tax_kind(p_org) = 'company';
  v_nonres := coalesce((prof->>'non_resident')::boolean, false);
  v_ntax := case when v_turn + private.v(t, 'other_income') > 0 then private.v(cells, 'OTHER_INCOME!D12') / (v_turn + private.v(t, 'other_income')) else 0 end;
  v_comm := coalesce(o.commenced_on, o.incorporation_date);
  if v_comm is not null and v_comm > v_from and v_comm <= v_to then v_short := round(((v_to - v_comm + 1)::numeric / 365), 6); end if;

  -- Amounts brought forward: from the previous year's computation, or this year's own settings when it opens the chain
  -- (or when the business has replaced them, with a reason).
  v_first_open := p_bf is null or coalesce((st->>'bf_override')::boolean, false);
  v_loss_bf := round(case when v_first_open then coalesce((st->>'losses_bf')::numeric, 0) else coalesce((p_bf->>'losses')::numeric, 0) end, 2);
  v_ca_bf := round(case when v_first_open then coalesce((st->>'ca_bf')::numeric, 0) else coalesce((p_bf->>'ca')::numeric, 0) end, 2);
  v_int_bf := case when v_first_open then coalesce(st->'interest_bf', '[]'::jsonb) else coalesce(p_bf->'interest', '[]'::jsonb) end;

  -- Capital allowances.
  ca := private.cit_ca(p_org, p_year, jsonb_build_object('nontax_share', v_ntax, 'short_factor', v_short,
    'opening_year', case when v_first_open and st ? 'opening_twdv' then p_year end, 'opening_twdv', coalesce(st->'opening_twdv', '{}'::jsonb)));

  -- Interest to connected persons above 30% of EBITDA is added back and carried forward up to five years.
  v_cap_pct := coalesce(private.rbn(rb, 'interest_restriction', 'ebitda_cap_pct'), 0.30);
  v_ebitda := v_pbt + v_int + v_dep + v_amort;
  v_conn := coalesce((st->>'connected_interest')::numeric, 0);
  if coalesce((prof->>'bank_or_insurer_subsidiary')::boolean, false) then v_conn := 0; end if;
  v_excess := round(greatest(v_conn - v_cap_pct * greatest(v_ebitda, 0), 0), 2);
  v_capacity := round(greatest(v_cap_pct * greatest(v_ebitda, 0) - v_conn, 0), 2);
  v_avail := v_capacity;
  for x in select value from jsonb_array_elements(v_int_bf) order by (value->>'yoa')::int loop
    continue when (x.value->>'yoa')::int < v_yoa - coalesce(private.rbn(rb, 'interest_restriction', 'carry_forward_years'), 5)::int;
    v_use := least(v_avail, coalesce((x.value->>'amount')::numeric, 0));
    v_relief := v_relief + v_use; v_avail := v_avail - v_use;
    if coalesce((x.value->>'amount')::numeric, 0) - v_use > 0 then
      v_int_cf := v_int_cf || jsonb_build_array(jsonb_build_object('yoa', (x.value->>'yoa')::int, 'amount', round((x.value->>'amount')::numeric - v_use, 2)));
    end if;
  end loop;
  if v_excess > 0 then v_int_cf := v_int_cf || jsonb_build_array(jsonb_build_object('yoa', v_yoa, 'amount', v_excess)); end if;

  -- Profit adjustments, row by row (PROFIT_ADJUSTMENT rows 14-32 add back, 36-40 deduct). Automatic rows come from named
  -- accounts in the books or named lines in the template; the business adds its own with reasons, or replaces a row.
  v_auto := '{}'::jsonb;
  if private.v(codes, '6704') > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D16}', jsonb_build_array(private.cit_item('Unrealised foreign exchange losses (account 6704)', private.v(codes, '6704'), 'Deductible when realised'))); end if;
  if private.v(cells, 'ADMINISTRATIVE_EXPENSES!C29') > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D17}', jsonb_build_array(private.cit_item('Loss on disposal of fixed assets', private.v(cells, 'ADMINISTRATIVE_EXPENSES!C29'),
    case when v_legacy then 'Capital allowance schedule gives the balancing allowance instead' else 'Capital: the disposal is dealt with in the capital allowance schedule and chargeable gains' end))); end if;
  if private.v(codes, '6803') > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D20}', jsonb_build_array(private.cit_item('Impairment of non-current assets (account 6803)', private.v(codes, '6803'), 'Capital in nature'))); end if;
  if private.v(codes, '6802') > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D25}', jsonb_build_array(private.cit_item('General provision for doubtful debts (expected credit loss charge, account 6802)', private.v(codes, '6802'),
    'Only specific debts written off are deductible'))); end if;
  if private.v(cells, 'ADMINISTRATIVE_EXPENSES!C57') + private.v(cells, 'ADMINISTRATIVE_EXPENSES!C58') > 0 then
    v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D29}', jsonb_build_array(private.cit_item('Fines and penalties', private.v(cells, 'ADMINISTRATIVE_EXPENSES!C57') + private.v(cells, 'ADMINISTRATIVE_EXPENSES!C58'), 'Never deductible'))); end if;
  v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D32}', '[]'::jsonb);
  if v_amort > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D32}', (v_auto->'PROFIT_ADJUSTMENT!D32') || jsonb_build_array(private.cit_item('Amortisation of intangible assets',
    v_amort, 'The template adds back depreciation only; capital allowances are given instead'))); end if;
  if v_excess > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D32}', (v_auto->'PROFIT_ADJUSTMENT!D32') || jsonb_build_array(private.cit_item('Interest to connected persons above 30% of EBITDA',
    v_excess, private.naira(v_conn) || ' paid; limit ' || private.naira(round(v_cap_pct * greatest(v_ebitda, 0), 2)) || ' (30% of EBITDA of ' || private.naira(round(v_ebitda, 2)) || ')'))); end if;
  if private.v(cells, 'OTHER_INCOME!D12') > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D36}', jsonb_build_array(private.cit_item('Non-taxable revenue', private.v(cells, 'OTHER_INCOME!D12'), 'Exempt income'))); end if;
  if private.v(cells, 'OTHER_INCOME!D11') > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D37}', jsonb_build_array(private.cit_item('Profit on disposal of fixed assets', private.v(cells, 'OTHER_INCOME!D11'),
    case when v_legacy then 'Any gain is for the capital gains tax return' else 'Dealt with as a chargeable gain' end))); end if;
  if v_fii > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D38}', jsonb_build_array(private.cit_item('Franked investment income (dividends received)', v_fii, 'Taxed at source'))); end if;
  v_amt := private.v(cells, 'OTHER_INCOME!D14') + greatest(private.v(codes, '4515') * -1, 0);
  if v_amt > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D39}', jsonb_build_array(private.cit_item('Unrealised exchange and fair value gains', v_amt, 'Taxed when realised'))); end if;
  v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D40}', '[]'::jsonb);
  if private.v(cells, 'OTHER_INCOME!D10') > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D40}', (v_auto->'PROFIT_ADJUSTMENT!D40') || jsonb_build_array(private.cit_item('Provisions written back',
    private.v(cells, 'OTHER_INCOME!D10'), 'The provision was not allowed when it was made'))); end if;
  v_gain_inv := private.v(cells, 'OTHER_INCOME!D9');
  if v_gain_inv > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D40}', (v_auto->'PROFIT_ADJUSTMENT!D40') || jsonb_build_array(private.cit_item('Gain on disposal of investments',
    v_gain_inv, case when v_legacy then 'Capital gains tax, not CIT' else 'Dealt with as a chargeable gain' end))); end if;
  if v_relief > 0 then v_auto := jsonb_set(v_auto, '{PROFIT_ADJUSTMENT!D40}', (v_auto->'PROFIT_ADJUSTMENT!D40') || jsonb_build_array(private.cit_item('Interest disallowed in earlier years, now within the 30% limit',
    v_relief, 'Third Schedule carry forward'))); end if;

  -- Rows: automatic items, then the business's own, unless the business replaced the row or audited accounts gave it.
  for x in select l.cell from cit_template_lines l where l.sheet = 'PROFIT_ADJUSTMENT' order by l.sort loop
    v_imp := case when v_source = 'imported' then cy.imported->x.cell end;
    v_ovr := adj->x.cell->'override';
    if x.cell = 'PROFIT_ADJUSTMENT!D23' then
      items := jsonb_set(items, array[x.cell], '[]'::jsonb);     -- the template starts from profit before tax: the tax charge is never added back
      continue;
    end if;
    if v_ovr is not null and v_ovr ? 'amount' then
      items := jsonb_set(items, array[x.cell], jsonb_build_array(private.cit_item(coalesce(v_ovr->>'label', 'Set by the business'), (v_ovr->>'amount')::numeric, coalesce(v_ovr->>'reason', ''), false)));
    elsif v_imp is not null and coalesce((v_imp->>'amount')::numeric, 0) <> 0 then
      items := jsonb_set(items, array[x.cell], jsonb_build_array(private.cit_item(coalesce(v_imp->>'note', 'From the tax computation imported'), (v_imp->>'amount')::numeric, 'Imported', false)));
    else
      items := jsonb_set(items, array[x.cell], coalesce(v_auto->x.cell, '[]'::jsonb));
    end if;
    for i in 0 .. coalesce(jsonb_array_length(adj->x.cell->'items'), 0) - 1 loop
      if coalesce((adj->x.cell->'items'->i->>'amount')::numeric, 0) > 0 then
        items := jsonb_set(items, array[x.cell], (items->x.cell) || jsonb_build_array(private.cit_item(adj->x.cell->'items'->i->>'label',
          (adj->x.cell->'items'->i->>'amount')::numeric, coalesce(adj->x.cell->'items'->i->>'reason', ''), false)));
      end if;
    end loop;
  end loop;

  -- Donations: allowed up to the cap of profit before the donation, and only to listed bodies; the rest is added back.
  v_don := private.v(cells, 'ADMINISTRATIVE_EXPENSES!C22');
  if v_don > 0 and not coalesce(adj->'PROFIT_ADJUSTMENT!D15' ? 'override', false) and not coalesce(v_source = 'imported' and cy.imported ? 'PROFIT_ADJUSTMENT!D15', false) then
    v_don_listed := greatest(v_don - coalesce((st->>'donations_unlisted')::numeric, 0), 0);
    select coalesce(sum((it->>'amount')::numeric), 0) into v_b from jsonb_each(items) e(c, arr), jsonb_array_elements(e.arr) it
      where e.c <> 'PROFIT_ADJUSTMENT!D15' and e.c between 'PROFIT_ADJUSTMENT!D14' and 'PROFIT_ADJUSTMENT!D32' and length(e.c) = length('PROFIT_ADJUSTMENT!D14');
    select coalesce(sum((it->>'amount')::numeric), 0) into v_c from jsonb_each(items) e(c, arr), jsonb_array_elements(e.arr) it
      where e.c in ('PROFIT_ADJUSTMENT!D36', 'PROFIT_ADJUSTMENT!D37', 'PROFIT_ADJUSTMENT!D38', 'PROFIT_ADJUSTMENT!D39', 'PROFIT_ADJUSTMENT!D40');
    v_don_base := greatest(v_pbt + v_dep + v_b - v_c + v_don, 0);
    v_don_cap := round(v_don_base * coalesce(case when v_legacy then private.rbn(rb, 'add_backs', 'donations', 'cap_pct') end, private.tax_rule('donations_cap', v_to), 0.10), 2);
    v_don_out := round(v_don - least(v_don_listed, v_don_cap), 2);
    if v_don_out > 0 then
      items := jsonb_set(items, '{PROFIT_ADJUSTMENT!D15}', jsonb_build_array(private.cit_item('Donations above the deductible limit', v_don_out,
        private.naira(v_don) || ' given; ' || private.naira(least(v_don_listed, v_don_cap)) || ' allowed (10% of ' || private.naira(v_don_base) || ' profit before donations'
        || case when v_don_listed < v_don then ', listed bodies only' else '' end || ')')) || (items->'PROFIT_ADJUSTMENT!D15'));
    end if;
  end if;

  for x in select l.cell from cit_template_lines l where l.sheet = 'PROFIT_ADJUSTMENT' loop
    select coalesce(sum((it->>'amount')::numeric), 0) into v_amt from jsonb_array_elements(coalesce(items->x.cell, '[]'::jsonb)) it;
    if v_amt <> 0 then pa := jsonb_set(pa, array[x.cell], to_jsonb(round(v_amt, 2))); end if;
  end loop;
  -- Expenses relating to non-taxable revenue (the template insists on them whenever non-taxable revenue is declared).
  if private.v(cells, 'OTHER_INCOME!D12') > 0 and private.v(pa, 'PROFIT_ADJUSTMENT!D14') + private.v(pa, 'PROFIT_ADJUSTMENT!D27') > 0 then
    cells := jsonb_set(cells, '{INCOME_STATEMENT!D113}', to_jsonb(private.v(pa, 'PROFIT_ADJUSTMENT!D14') + private.v(pa, 'PROFIT_ADJUSTMENT!D27')));
  end if;
  v_b := round(v_dep + (select coalesce(sum(value::numeric), 0) from jsonb_each_text(pa) where key between 'PROFIT_ADJUSTMENT!D14' and 'PROFIT_ADJUSTMENT!D32'
                        and length(key) = length('PROFIT_ADJUSTMENT!D14')), 2);
  v_c := round((select coalesce(sum(value::numeric), 0) from jsonb_each_text(pa) where key in ('PROFIT_ADJUSTMENT!D36', 'PROFIT_ADJUSTMENT!D37', 'PROFIT_ADJUSTMENT!D38',
                 'PROFIT_ADJUSTMENT!D39', 'PROFIT_ADJUSTMENT!D40')), 2);
  v_d := round(v_pbt + v_b - v_c, 2);

  -- Chargeable gains (NTA: in total profits at the CIT rate; old law: a separate capital gains tax return).
  v_gains_other := coalesce((st->>'chargeable_gains_other')::numeric, 0);
  v_f := case when v_legacy then 0 else greatest(private.v(ca->'totals', 'gains') - private.v(ca->'totals', 'losses') + v_gain_inv + v_gains_other, 0) end;
  v_bc := private.v(ca->'totals', 'balancing_charge');

  if v_legacy then
    -- Old law: CIT by size, minimum tax, tertiary education tax on assessable profit.
    v_class := case when v_turn <= coalesce(private.rbn(rb, 'company_classification', 'classes', 'SMALL', 'turnover_max_ngn'), 25000000) then 'SMALL'
                    when v_turn < coalesce(private.rbn(rb, 'company_classification', 'classes', 'LARGE', 'turnover_min_ngn'), 100000000) then 'MEDIUM' else 'LARGE' end;
    v_small := v_class = 'SMALL';
    v_rate := coalesce(private.rbn(rb, 'cit_rates', 'by_class', v_class), 0.30);
    v_ap := v_d + v_bc;
    v_e1 := least(v_loss_bf, greatest(v_ap, 0));
    v_rem := greatest(v_ap, 0) - v_e1;
    select coalesce(sum(case when l.addr in ('D7', 'D8') then private.v(cells, l.cell) end), 0), coalesce(sum(private.v(cells, l.cell)), 0) into v_manu, v_sum
      from cit_template_lines l where l.section = 'revenue';
    v_exempt_sector := o.industry in ('manufacturing', 'agro') or (v_sum > 0 and v_manu / v_sum >= 0.5);
    v_restricted := not v_exempt_sector;
    v_cap := case when v_restricted then round(greatest(v_ap, 0) * 2 / 3, 2) end;
    v_ca_avail := round(private.v(ca->'totals', 'allowance') + private.v(ca->'totals', 'investment') + private.v(ca->'totals', 'balancing_allowance') + v_ca_bf, 2);
    v_e2 := least(v_ca_avail, coalesce(v_cap, v_ca_avail), v_rem);
    v_g := greatest(v_ap - v_e1 - v_e2, 0);
    v_h := case when v_company then round(v_g * v_rate, 2) else 0 end;
    v_years_in := case when v_comm is not null then p_year - extract(year from v_comm)::int else 99 end;
    v_mt_applies := v_company and not v_small and v_years_in >= 4 and coalesce(o.industry, '') <> 'agro' and not coalesce((prof->>'agricultural_trade')::boolean, false)
                    and not coalesce((prof->>'imported_equity_25')::boolean, false);
    v_mt := case when v_mt_applies then round(greatest(v_turn - v_fii, 0) * coalesce(private.rbn(rb, 'minimum_tax', 'rate'), 0.005), 2) else 0 end;
    v_mt_used := v_mt_applies and v_mt > v_h;
    v_cit_payable := case when v_mt_used then v_mt else v_h end;
    v_tet_rate := coalesce(private.rbn(rb, 'tertiary_education_tax', 'rate_by_yoa', v_yoa::text), 0.03);
    v_tet := case when v_company and not (v_small and coalesce(private.rbb(rb, 'tertiary_education_tax', 'exempt_small_companies'), true)) then round(greatest(v_ap, 0) * v_tet_rate, 2) else 0 end;
    v_lev := v_tet;
    v_k := v_cit_payable + v_tet;
    v_loss_new := greatest(-v_ap, 0);
  else
    -- NTA 2025: classification, CIT on total profits, development levy on assessable profit, 15% minimum effective tax.
    v_small := v_turn <= coalesce(private.rbn(rb, 'company_classification', 'thresholds', 'small_company_turnover_max_ngn'), 100000000)
               and v_fixed <= coalesce(private.rbn(rb, 'company_classification', 'thresholds', 'small_company_fixed_assets_max_ngn'), 250000000)
               and not coalesce(o.professional_services, false);
    v_class := case when v_nonres then 'NON_RESIDENT' when v_small then 'SMALL' else 'REGULAR' end;
    v_rate := coalesce(private.rbn(rb, 'cit_rates', 'by_class', v_class), case when v_small then 0 else 0.30 end);
    v_ap := v_d + v_bc;
    v_e1 := least(v_loss_bf, greatest(v_ap, 0));
    v_rem := greatest(v_ap, 0) - v_e1;
    v_ca_avail := round(private.v(ca->'totals', 'allowance') + private.v(ca->'totals', 'balancing_allowance') + private.v(ca->'totals', 'residue_on_disposal') + v_ca_bf, 2);
    v_e2 := least(v_ca_avail, v_rem);
    v_loss_vs_gains := case when v_ap < 0 then least(-v_ap, v_f) else 0 end;
    v_g := greatest(v_ap - v_e1 - v_e2 + v_f, 0);
    v_h := case when v_company and not v_nonres then round(v_g * v_rate, 2) else 0 end;
    v_dlevy_applies := v_company and v_class = 'REGULAR' and not coalesce((prof->>'hydrocarbon')::boolean, false);
    v_lev_base := case when coalesce((v_flags->'development_levy_base_before_capital_allowances'->>'default')::boolean, true) then greatest(v_ap, 0)
                       else greatest(v_ap - v_e1 - v_e2, 0) end
                + case when coalesce((v_flags->'chargeable_gains_in_development_levy_base'->>'default')::boolean, false) then v_f else 0 end;
    v_lev := case when v_dlevy_applies then round(v_lev_base * coalesce(private.rbn(rb, 'development_levy', 'rate'), 0.04), 2) else 0 end;
    v_etr := v_company and (v_turn >= coalesce((v_flags->'etr_turnover_threshold_ngn'->>'default')::numeric, private.rbn(rb, 'company_classification', 'thresholds', 'etr_turnover_trigger_ngn'), 50000000000)
             or (coalesce((prof->>'mne_constituent')::boolean, false) and coalesce((prof->>'group_turnover_eur')::numeric, 0) >= coalesce(private.rbn(rb, 'company_classification', 'thresholds', 'etr_mne_group_turnover_trigger_eur'), 750000000)));
    v_ni := v_pbt - v_fii - (private.v(pa, 'PROFIT_ADJUSTMENT!D39') - private.v(pa, 'PROFIT_ADJUSTMENT!D16'));
    v_cov := v_h + v_lev;
    if v_etr and v_ni > 0 and v_cov / v_ni < coalesce(private.rbn(rb, 'etr_topup', 'minimum_rate'), 0.15) then
      v_j := round(coalesce(private.rbn(rb, 'etr_topup', 'minimum_rate'), 0.15) * v_ni - v_cov, 2);
    end if;
    v_cit_payable := v_h;
    v_k := v_h + v_lev + v_j;
    v_loss_new := greatest(-v_ap, 0) - v_loss_vs_gains;
  end if;

  select coalesce(sum(b.bal), 0) into v_wht from private.balances_at(p_org, v_upto) b where split_part(b.code, '-', 1) = '1401';
  if v_source = 'imported' then v_wht := private.v(cells, 'STATEMENT_OF_FINANCIAL_POSITION!D51'); end if;
  v_wht_used := round(least(greatest(v_wht, 0), v_cit_payable + v_j), 2);
  v_loss_cf := round(v_loss_bf - v_e1 + v_loss_new, 2);
  v_ca_cf := round(v_ca_avail - v_e2, 2);

  -- The computation, line by line, as the rule book stages it.
  v_rows := jsonb_build_array(
    jsonb_build_object('id', 'A', 'line', 'Profit / (loss) before tax', 'amount', v_pbt, 'basis', 'INCOME_STATEMENT!E115', '_style', 'subtotal'),
    jsonb_build_object('id', 'B', 'line', 'Add: disallowable expenses', 'amount', v_b, 'basis', 'PROFIT_ADJUSTMENT!E33 (depreciation ' || private.naira(v_dep) || ' and rows 14-32)', '_style', 'line'),
    jsonb_build_object('id', 'C', 'line', 'Less: non-taxable income and tax-only deductions', 'amount', -v_c, 'basis', 'PROFIT_ADJUSTMENT!E41', '_style', 'line'),
    jsonb_build_object('id', 'D', 'line', case when v_legacy then 'Adjusted profit / (loss)' else 'Assessable profit / (loss)' end, 'amount', v_d, '_style', 'subtotal'))
  || case when v_bc <> 0 then jsonb_build_array(jsonb_build_object('id', 'D2', 'line', 'Add: balancing charges', 'amount', v_bc, 'basis', 'Capital allowance schedule', '_style', 'line')) else '[]'::jsonb end
  || case when v_legacy then jsonb_build_array(jsonb_build_object('id', 'AP', 'line', 'Assessable profit / (loss)', 'amount', v_ap, '_style', 'subtotal')) else '[]'::jsonb end
  || jsonb_build_array(
    jsonb_build_object('id', 'E1', 'line', 'Less: losses brought forward', 'amount', -v_e1, 'basis', private.naira(v_loss_bf) || ' brought forward; no time limit', '_style', 'line'),
    jsonb_build_object('id', 'E2', 'line', 'Less: capital allowances', 'amount', -v_e2, 'basis', private.naira(v_ca_avail) || ' available'
      || case when v_ca_bf > 0 then ' (' || private.naira(v_ca_bf) || ' brought forward)' else '' end
      || case when v_legacy and v_restricted then '; limited to two-thirds of assessable profit' else '' end, '_style', 'line'))
  || case when not v_legacy then jsonb_build_array(jsonb_build_object('id', 'F', 'line', 'Add: net chargeable gains', 'amount', v_f, 'basis', 'Disposals in the year (s.27(1), s.33-55)', '_style', 'line')) else '[]'::jsonb end
  || jsonb_build_array(
    jsonb_build_object('id', 'G', 'line', 'Total profits', 'amount', v_g, '_style', 'subtotal'),
    jsonb_build_object('id', 'H', 'line', 'Companies income tax at ' || trim(to_char(coalesce(v_rate, 0) * 100, 'FM990.##')) || '% (' || lower(v_class) || ' company)', 'amount', v_h,
      'basis', case when v_legacy then 'CITA s.40' else 'NTA 2025 s.56' end, '_style', 'line'))
  || case when v_legacy then jsonb_build_array(
       jsonb_build_object('id', 'MT', 'line', 'Minimum tax (0.5% of turnover less franked investment income)', 'amount', v_mt,
         'basis', case when v_mt_applies then case when v_mt_used then 'Higher than the CIT computed, so it is payable instead' else 'Lower than the CIT computed' end
                  else 'Not applicable to this company' end, '_style', 'line'),
       jsonb_build_object('id', 'I', 'line', 'Tertiary education tax at ' || trim(to_char(v_tet_rate * 100, 'FM990.##')) || '% of assessable profit', 'amount', v_tet,
         'basis', case when v_small then 'Not charged on a small company' else 'TETFund Act s.1(2) as amended' end, '_style', 'line'))
     else jsonb_build_array(
       jsonb_build_object('id', 'I', 'line', 'Development levy at ' || trim(to_char(coalesce(private.rbn(rb, 'development_levy', 'rate'), 0.04) * 100, 'FM990.##')) || '% of assessable profit',
         'amount', v_lev, 'basis', case when v_dlevy_applies then 'NTA 2025 s.59' else 'Not charged on a ' || lower(v_class) || ' company' end, '_style', 'line'),
       jsonb_build_object('id', 'J', 'line', 'Minimum effective tax top-up (15%)', 'amount', v_j, 'basis', case when v_etr then 'NTA 2025 s.57' else 'Not in scope' end, '_style', 'line')) end
  || jsonb_build_array(
    jsonb_build_object('id', 'K', 'line', 'Total tax for the year', 'amount', v_k, '_style', 'subtotal'),
    jsonb_build_object('id', 'W', 'line', 'Less: withholding tax credit notes held', 'amount', -v_wht_used, 'basis', private.naira(v_wht) || ' held; set against companies income tax only', '_style', 'line'),
    jsonb_build_object('id', 'P', 'line', 'Tax payable', 'amount', v_k - v_wht_used, '_style', 'total'));

  -- Checks before the return can be approved.
  if v_source = 'books' and abs(coalesce(v_books_pbt, v_pbt) - v_pbt) >= 0.5 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'pbt_ties_to_books', 'severity', 'warn',
      'text', 'Profit before tax is ' || private.naira(v_pbt) || ' after the lines you changed; the books give ' || private.naira(v_books_pbt) || '.'));
  end if;
  if v_source = 'books' and not private.cit_books_cover(p_org, v_from, v_to) then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'books_partial', 'severity', 'block',
      'text', 'Counta''s books start on ' || private.fdate(coalesce(o.books_start, (select min(j.entry_date) from journals j where j.org_id = p_org))) || ', after this year began. '
        || 'Use the audited accounts or a trial balance for the whole year instead.'));
  end if;
  if abs(private.v(t, 'total_assets') - private.v(t, 'total_equity_liabilities')) >= 1 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'sfp_ties_to_accounts', 'severity', 'block',
      'text', 'Total assets (' || private.naira(private.v(t, 'total_assets')) || ') do not equal equity and liabilities (' || private.naira(private.v(t, 'total_equity_liabilities')) || ').'));
  end if;
  if v_source = 'imported' and cy.imported_from ? 'profit_before_tax' and abs(coalesce((cy.imported_from->>'profit_before_tax')::numeric, v_pbt) - v_pbt) >= 1 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'pbt_ties_to_afs', 'severity', 'block',
      'text', 'Profit before tax from the lines is ' || private.naira(v_pbt) || '; the audited accounts show ' || private.naira((cy.imported_from->>'profit_before_tax')::numeric) || '.'));
  end if;
  if v_source = 'imported' and cy.imported_from ? 'revenue' and abs(coalesce((cy.imported_from->>'revenue')::numeric, v_turn) - v_turn) >= 1 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'revenue_ties_to_pl', 'severity', 'block',
      'text', 'Revenue on the template is ' || private.naira(v_turn) || '; the audited accounts show ' || private.naira((cy.imported_from->>'revenue')::numeric) || '.'));
  end if;
  if v_source = 'imported' and jsonb_typeof(cy.imported) = 'object' and (select count(*) from jsonb_object_keys(cy.imported)) = 0 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'figures_missing', 'severity', 'block',
      'text', 'Counta does not hold this year in its books. Upload the audited accounts or a trial balance, or enter the figures.'));
  end if;
  if private.v(cells, 'OTHER_INCOME!D12') > 0 and private.v(cells, 'INCOME_STATEMENT!D113') <= 0 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'non_taxable_income_pairing', 'severity', 'block',
      'text', 'Non-taxable revenue of ' || private.naira(private.v(cells, 'OTHER_INCOME!D12')) || ' is declared: enter the expenses relating to it (profit adjustment row 14).'));
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('cell', l.cell, 'label', l.label, 'amount', private.v(cells, l.cell)) order by l.sort), '[]'::jsonb) into v_others
    from cit_template_lines l where l.cell in ('ADMINISTRATIVE_EXPENSES!C70', 'OTHER_INCOME!D17', 'STATEMENT_OF_FINANCIAL_POSITION!D62', 'STATEMENT_OF_FINANCIAL_POSITION!D92',
      'STATEMENT_OF_FINANCIAL_POSITION!D42', 'STATEMENT_OF_FINANCIAL_POSITION!D110', 'INCOME_STATEMENT!D27') and private.v(cells, l.cell) <> 0;
  if jsonb_array_length(v_others) > 0 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'no_expense_lumping', 'severity', 'warn', 'items', v_others,
      'text', 'Some amounts sit on "Others" lines: ' || (select string_agg(o2->>'label' || ' ' || private.naira((o2->>'amount')::numeric), '; ') from jsonb_array_elements(v_others) o2)
        || '. Rev360 asks for each expense on its own line where the template has one.'));
  end if;
  if private.v(cells, 'INCOME_STATEMENT!D27') > 0 and v_turn > 0 and private.v(cells, 'INCOME_STATEMENT!D27') / v_turn > 0.5 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'sector_revenue_block', 'severity', 'warn',
      'text', 'Most revenue is under "Others". Post sales to the revenue account for your sector so the right block is filled.'));
  end if;
  if exists (select 1 from jsonb_each(cells) where key in (select cell from cit_template_lines where positive_only) and value::numeric < 0) then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'positive_only', 'severity', 'block',
      'text', 'These lines only take amounts above zero on the template: ' || (select string_agg(l.label, ', ') from cit_template_lines l where l.positive_only and private.v(cells, l.cell) < 0) || '.'));
  end if;
  if not v_ended then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'year_not_ended', 'severity', 'block',
      'text', 'The year ends on ' || private.fdate(v_to) || '. Until then this is an estimate.'));
  end if;
  if cy.afs_path is null then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'afs_attached', 'severity', 'block',
      'text', 'Attach the audited financial statements (PDF): auditor''s report, statements, notes and the capital allowance schedule.'));
  end if;
  if rbr.status <> 'approved' then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'rulebook_pending', 'severity', 'warn',
      'text', 'The rules for this year (' || coalesce(rb->'meta'->>'config_id', '') || ' ' || rbr.version || ') are awaiting TaxStreem sign-off.'));
  end if;
  if jsonb_array_length(ca->'missing') > 0 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'ca_category_missing', 'severity', 'warn',
      'text', 'No Rev360 category for: ' || (select string_agg(value, ', ') from jsonb_array_elements_text(ca->'missing')) || '. They get no allowance until a category is chosen.'));
  end if;
  if not v_company then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'not_company', 'severity', 'block', 'text',
      case when private.income_tax_kind(p_org) = 'exempt' then 'The business is exempt from income tax unless it carries on a trade or business (NTA 2025 s.162(1)(a)(iii)). The owner says so under Income tax.'
           else 'The business is not a company: its owners file personal income tax instead, under Income tax.' end));
  end if;
  if v_nonres or coalesce(prof->>'sector_regime', '') <> '' or coalesce(o.industry, '') = 'other' and coalesce((prof->>'hydrocarbon')::boolean, false) then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'out_of_scope', 'severity', 'block',
      'text', 'This company is taxed under special rules (' || coalesce(nullif(prof->>'sector_regime', ''), case when v_nonres then 'non-resident' else 'sector regime' end) || ') that Counta does not compute yet.'));
  end if;
  if v_comm is not null and v_legacy and p_year - extract(year from v_comm)::int < 3 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'commencement_years', 'severity', 'warn',
      'text', 'The business started on ' || private.fdate(v_comm) || ': the first years use special basis periods under CITA s.29. Check the year of assessment with your adviser.'));
  end if;
  if v_small then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'small_company_still_files', 'severity', 'info', 'text', 'A small company still files a full return.'));
  end if;
  if private.v(cells, 'INCOME_STATEMENT!D116') = 0 and v_source = 'books' and private.v(codes, '7501') + private.v(codes, '7502') + private.v(codes, '7503') < 0 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'tax_credit', 'severity', 'info', 'text', 'The tax line in the accounts is a credit; the template takes a charge only, so it is left empty.'));
  end if;

  return jsonb_build_object('year', p_year, 'yoa', v_yoa, 'from', v_from, 'to', v_to, 'as_of', v_upto, 'ended', v_ended, 'source', v_source,
    'regime', rbr.regime, 'rulebook', jsonb_build_object('id', rbr.id, 'version', rbr.version, 'status', rbr.status, 'law', rb->'meta'->>'governing_law'),
    'class', v_class, 'small', v_small, 'company', v_company, 'cells', cells, 'detail', det, 'totals', t, 'adjustments', pa, 'items', items,
    'ca', ca, 'rows', v_rows,
    'figures', jsonb_build_object('profit_before_tax', v_pbt, 'turnover', v_turn, 'fixed_assets', v_fixed, 'addbacks', v_b, 'deductions', v_c, 'assessable', v_d,
      'balancing_charge', v_bc, 'assessable_after_bc', v_ap, 'loss_relief', v_e1, 'capital_allowances_available', v_ca_avail, 'capital_allowances', v_e2,
      'chargeable_gains', v_f, 'total_profits', v_g, 'cit_rate', v_rate, 'cit', v_h, 'minimum_tax', v_mt, 'minimum_tax_applies', v_mt_applies,
      'minimum_tax_used', v_mt_used, 'cit_payable', v_cit_payable, 'tertiary_education_tax', v_tet, 'development_levy', case when v_legacy then 0 else v_lev end,
      'etr_in_scope', coalesce(v_etr, false), 'etr_net_income', v_ni, 'topup', v_j, 'total_tax', v_k, 'wht_credit', v_wht_used, 'wht_held', v_wht,
      'payable', v_k - v_wht_used, 'ebitda', round(v_ebitda, 2), 'connected_interest', v_conn, 'interest_excess', v_excess, 'interest_relief', v_relief,
      'restricted', coalesce(v_restricted, false), 'cap', v_cap, 'short_factor', v_short),
    'bf', jsonb_build_object('losses', v_loss_bf, 'ca', v_ca_bf, 'interest', v_int_bf, 'from_previous_year', not v_first_open),
    'cf', jsonb_build_object('losses', v_loss_cf, 'ca', v_ca_cf, 'interest', v_int_cf),
    'checks', v_checks, 'due', (v_to + interval '6 months')::date,
    'status', coalesce(cy.status, 'draft'));
end $function$;

CREATE OR REPLACE FUNCTION private.cit_ca(p_org uuid, p_year integer, p_opts jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare a record; rb_l jsonb := (private.rulebook(2025)).config; rb_n jsonb := (private.rulebook(2026)).config; y int; y0 int; yd int; v_twdv numeric;
  v_ia0 numeric; v_ini numeric; v_ann numeric; v_rate numeric; v_cls text; v_ret numeric; v_allow numeric; v_claim numeric; v_inv numeric; v_bc numeric; v_ba numeric;
  v_res numeric; v_gain numeric; v_rec jsonb; v_assets jsonb := '[]'::jsonb; v_flag_c boolean; v_use numeric; v_legacy boolean; v_disp_year boolean;
  v_bf numeric; v_add numeric; v_factor numeric := coalesce((p_opts->>'short_factor')::numeric, 1); v_ntax numeric := coalesce((p_opts->>'nontax_share')::numeric, 0);
  v_open_year int := (p_opts->>'opening_year')::int; v_open jsonb := coalesce(p_opts->'opening_twdv', '{}'::jsonb); t jsonb; v_cats jsonb := '{}'::jsonb; c jsonb;
  v_flags jsonb := '[]'::jsonb; v_missing text[] := '{}'; v_iaY numeric; v_aaY numeric; v_invY numeric; k text; v_rows jsonb := '[]'::jsonb; v_period_to date;
  v_restricted boolean;
begin
  v_flag_c := coalesce(private.rbb(rb_n, 'configurable_flags', 'flags', 'use_legacy_balancing_charge_allowance', 'default'), false);
  v_period_to := (private.cit_period(p_org, p_year)).pto;
  for a in select * from private.cit_assets(p_org) x where x.in_use <= v_period_to order by x.class_account, x.in_use, x.name loop
    y0 := private.cit_year_of(p_org, a.in_use);
    yd := case when a.disposed_at is not null then private.cit_year_of(p_org, a.disposed_at) end;
    if yd is not null and yd < p_year then continue; end if;                       -- gone before this year
    v_twdv := a.qce; v_ia0 := 0; v_bf := 0; v_add := 0; v_iaY := 0; v_aaY := 0; v_invY := 0; v_claim := 0; v_bc := 0; v_ba := 0; v_res := 0; v_gain := null;
    v_use := case when a.use_pct < 100 and (coalesce((p_opts->>'use_pct_always')::boolean, false) or v_ntax >= coalesce(private.rbn(rb_n, 'capital_allowances', 'rules', '5', 'threshold_pct'), 0.10)) then a.use_pct / 100 else 1 end;
    v_disp_year := false;
    if a.category is null or a.category = 'Land' or not a.qualifies then
      if a.category is null and a.class_account not in ('1520', '1521', '1501') then v_missing := v_missing || coalesce(a.name, a.key); end if;
      -- Recorded for the declaration, with no allowance.
      v_assets := v_assets || jsonb_build_array(jsonb_build_object('key', a.key, 'asset_id', a.asset_id, 'kind', a.kind, 'number', a.number, 'name', a.name,
        'class', a.class_account, 'category', a.category, 'qce', a.qce, 'in_use', a.in_use, 'first_year', y0, 'qualifies', false,
        'reason', case when a.category = 'Land' then 'Land is not qualifying expenditure' when not a.qualifies then coalesce('Marked as not qualifying', '')
                       when a.class_account in ('1520', '1521') then 'Not in use yet' else 'No allowance category for this class' end,
        'twdv_bf', 0, 'additions', 0, 'allowance', 0, 'twdv_cf', 0, 'disposed', yd = p_year, 'proceeds', case when yd = p_year then a.proceeds end));
      continue;
    end if;
    for y in y0 .. p_year loop
      v_legacy := case when p_opts ? 'legacy_upto' then y <= (p_opts->>'legacy_upto')::int else (private.rulebook(y + 1)).regime = 'LEGACY_CITA' end;
      if v_open_year is not null and y = v_open_year and v_open ? a.key then v_twdv := (v_open->>a.key)::numeric; end if;
      if y = p_year then v_bf := case when y = y0 then 0 else v_twdv end; v_add := case when y = y0 then a.qce else 0 end; end if;
      if yd is not null and yd = y then
        -- Disposed in the year: not owned at the year end, so no allowance; the tax value is settled against the proceeds.
        v_disp_year := true;
        if v_legacy or v_flag_c then
          if a.proceeds > v_twdv then v_bc := least(a.proceeds - v_twdv, a.qce - v_twdv); else v_ba := v_twdv - a.proceeds; end if;
          v_gain := greatest(a.proceeds - (a.qce + a.enhancement + a.disposal_costs), 0);
        else
          v_res := v_twdv;
          v_gain := a.proceeds - (a.qce + a.enhancement + a.disposal_costs);
        end if;
        v_twdv := 0;
        exit;
      end if;
      if v_legacy then
        c := rb_l->'capital_allowances'->'categories'->a.category;
        v_ini := coalesce((c->>'initial')::numeric, 0); v_ann := coalesce((c->>'annual')::numeric, 0);
        v_ret := coalesce(private.rbn(rb_l, 'capital_allowances', 'retention_ngn'), 10);
        if y = y0 then
          v_ia0 := round(a.qce * v_ini, 2);
          v_allow := least(v_ia0 + round((a.qce - v_ia0) * v_ann, 2), greatest(v_twdv - v_ret, 0));
          v_inv := case when a.category in (select jsonb_array_elements_text(rb_l->'capital_allowances'->'investment_allowance'->'categories'))
                        then round(a.qce * coalesce(private.rbn(rb_l, 'capital_allowances', 'investment_allowance', 'rate'), 0), 2) else 0 end;
          if y = p_year then v_iaY := least(v_ia0, v_allow); v_aaY := v_allow - v_iaY; v_invY := v_inv; end if;
        else
          v_allow := least(round((a.qce - v_ia0) * v_ann, 2), greatest(v_twdv - v_ret, 0));
          if y = p_year then v_aaY := v_allow; end if;
        end if;
      else
        v_cls := rb_n->'capital_allowances'->'category_to_class_map'->>a.category;
        v_rate := (select (x->>'rate')::numeric from jsonb_array_elements(rb_n->'capital_allowances'->'table_I'->'classes') x where x->>'class' = v_cls);
        v_ret := round(a.qce * coalesce(private.rbn(rb_n, 'capital_allowances', 'notional_retention_pct'), 0.01), 2);
        v_allow := least(round(a.qce * coalesce(v_rate, 0), 2), greatest(v_twdv - v_ret, 0));
        if y = p_year then v_allow := round(v_allow * v_factor, 2); v_aaY := v_allow; end if;
      end if;
      v_twdv := v_twdv - v_allow;
      if y = p_year then v_claim := round(v_allow * v_use, 2) + case when v_legacy then 0 else 0 end; end if;
    end loop;
    v_rec := jsonb_build_object('key', a.key, 'asset_id', a.asset_id, 'kind', a.kind, 'number', a.number, 'name', a.name, 'class', a.class_account,
      'category', a.category, 'rev360_category', private.rev360_category(a.category), 'qce', a.qce, 'in_use', a.in_use, 'first_year', y0, 'qualifies', true,
      'regime', case when (case when p_opts ? 'legacy_upto' then p_year <= (p_opts->>'legacy_upto')::int else (private.rulebook(p_year + 1)).regime = 'LEGACY_CITA' end) then 'LEGACY_CITA' else 'NTA_2025' end,
      'rate', case when (case when p_opts ? 'legacy_upto' then p_year <= (p_opts->>'legacy_upto')::int else (private.rulebook(p_year + 1)).regime = 'LEGACY_CITA' end) then null else v_rate end,
      'twdv_bf', round(v_bf, 2), 'additions', round(v_add, 2), 'initial', round(v_iaY, 2), 'annual', round(v_aaY, 2), 'investment', round(v_invY, 2),
      'use_pct', round(v_use * 100, 2), 'allowance', round(case when v_disp_year then 0 else v_claim end, 2),
      'disposed', v_disp_year, 'proceeds', case when v_disp_year then a.proceeds end, 'balancing_charge', round(v_bc, 2), 'balancing_allowance', round(v_ba, 2),
      'residue_on_disposal', round(v_res, 2), 'gain', case when v_gain is not null then round(v_gain, 2) end,
      'twdv_cf', round(case when v_disp_year then 0 else v_twdv end, 2));
    v_assets := v_assets || jsonb_build_array(v_rec);
    k := a.category;
    c := coalesce(v_cats->k, jsonb_build_object('category', k, 'twdv_bf', 0, 'additions', 0, 'allowance', 0, 'investment', 0, 'balancing_charge', 0,
      'balancing_allowance', 0, 'residue_on_disposal', 0, 'disposals', 0, 'twdv_cf', 0, 'assets', 0));
    c := c || jsonb_build_object('twdv_bf', (c->>'twdv_bf')::numeric + (v_rec->>'twdv_bf')::numeric, 'additions', (c->>'additions')::numeric + (v_rec->>'additions')::numeric,
      'allowance', (c->>'allowance')::numeric + (v_rec->>'allowance')::numeric, 'investment', (c->>'investment')::numeric + (v_rec->>'investment')::numeric,
      'balancing_charge', (c->>'balancing_charge')::numeric + v_bc, 'balancing_allowance', (c->>'balancing_allowance')::numeric + v_ba,
      'residue_on_disposal', (c->>'residue_on_disposal')::numeric + v_res, 'disposals', (c->>'disposals')::numeric + coalesce((v_rec->>'proceeds')::numeric, 0),
      'twdv_cf', (c->>'twdv_cf')::numeric + (v_rec->>'twdv_cf')::numeric, 'assets', (c->>'assets')::int + 1);
    v_cats := jsonb_set(v_cats, array[k], c);
  end loop;
  select jsonb_build_object(
      'twdv_bf', coalesce(sum((x->>'twdv_bf')::numeric), 0), 'additions', coalesce(sum((x->>'additions')::numeric), 0),
      'allowance', coalesce(sum((x->>'allowance')::numeric), 0), 'investment', coalesce(sum((x->>'investment')::numeric), 0),
      'balancing_charge', coalesce(sum((x->>'balancing_charge')::numeric), 0), 'balancing_allowance', coalesce(sum((x->>'balancing_allowance')::numeric), 0),
      'residue_on_disposal', coalesce(sum((x->>'residue_on_disposal')::numeric), 0), 'disposals', coalesce(sum((x->>'proceeds')::numeric), 0),
      'gains', coalesce(sum(greatest((x->>'gain')::numeric, 0)), 0), 'losses', coalesce(sum(greatest(-(x->>'gain')::numeric, 0)), 0),
      'twdv_cf', coalesce(sum((x->>'twdv_cf')::numeric), 0))
    into t from jsonb_array_elements(v_assets) x where (x->>'qualifies')::boolean;
  for k in select key from jsonb_each(v_cats) order by key loop v_rows := v_rows || jsonb_build_array(v_cats->k); end loop;
  return jsonb_build_object('assets', v_assets, 'categories', v_rows, 'totals', t, 'missing', to_jsonb(v_missing), 'flag_c', v_flag_c,
    'regime', case when (case when p_opts ? 'legacy_upto' then p_year <= (p_opts->>'legacy_upto')::int else (private.rulebook(p_year + 1)).regime = 'LEGACY_CITA' end)
    then 'LEGACY_CITA' else 'NTA_2025' end);
end $function$;

CREATE OR REPLACE FUNCTION public.save_cit_year(p_org uuid, p_year integer, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; cy public.cit_years; pr record; x record; v_adj jsonb; v_ovr jsonb; v_imp jsonb; v_set jsonb; it jsonb; v_items jsonb; v_cell text; v_amt numeric;
  v_allowed text[] := array['losses_bf', 'ca_bf', 'interest_bf', 'connected_interest', 'donations_unlisted', 'chargeable_gains_other', 'opening_twdv', 'bf_override',
    'bf_reason', 'notes'];
begin
  m := private.require(p_org, 'keep_books');
  select pfrom, pto into pr from private.cit_period(p_org, p_year);
  insert into cit_years (org_id, accounting_year, period_from, period_to, source, updated_by)
  values (p_org, p_year, pr.pfrom, pr.pto, private.cit_default_source(p_org, pr.pfrom, pr.pto), m.id)
  on conflict (org_id, accounting_year) do nothing;
  select * into cy from cit_years where org_id = p_org and accounting_year = p_year for update;
  if cy.status not in ('draft', 'rejected') then raise exception 'The % return is %. Reopen it to change it.', p_year, cy.status; end if;
  if exists (select 1 from pit_years where org_id = p_org and accounting_year = p_year and status = 'approved') then
    raise exception 'The % income tax return is approved. Reopen it under Income tax to change the figures.', p_year;
  end if;

  if p ? 'source' then
    if p->>'source' not in ('books', 'imported') then raise exception 'Choose where the figures come from.'; end if;
    update cit_years set source = p->>'source' where org_id = p_org and accounting_year = p_year;
  end if;
  if p ? 'settings' then
    v_set := coalesce(cy.settings, '{}'::jsonb);
    for x in select key, value from jsonb_each(p->'settings') loop
      if not x.key = any(v_allowed) then raise exception 'Unknown setting %.', x.key; end if;
      if x.key in ('losses_bf', 'ca_bf', 'connected_interest', 'donations_unlisted', 'chargeable_gains_other') then
        if jsonb_typeof(x.value) = 'null' then v_set := v_set - x.key; continue; end if;
        if private.num(x.value #>> '{}') is null or private.num(x.value #>> '{}') < 0 then raise exception 'Enter an amount of zero or more for %.', replace(x.key, '_', ' '); end if;
        v_set := jsonb_set(v_set, array[x.key], to_jsonb(round(private.num(x.value #>> '{}'), 2)));
      elsif x.key = 'interest_bf' then
        if jsonb_typeof(x.value) <> 'array' then raise exception 'Interest brought forward is a list of {yoa, amount}.'; end if;
        v_set := jsonb_set(v_set, '{interest_bf}', (select coalesce(jsonb_agg(jsonb_build_object('yoa', (e->>'yoa')::int, 'amount', round(private.num(e->>'amount'), 2))), '[]'::jsonb)
          from jsonb_array_elements(x.value) e where coalesce(private.num(e->>'amount'), 0) > 0));
      elsif x.key = 'opening_twdv' then
        if jsonb_typeof(x.value) <> 'object' then raise exception 'Opening tax values are {asset: amount}.'; end if;
        v_set := jsonb_set(v_set, '{opening_twdv}', x.value);
      else
        v_set := case when jsonb_typeof(x.value) = 'null' then v_set - x.key else jsonb_set(v_set, array[x.key], x.value) end;
      end if;
    end loop;
    if coalesce((v_set->>'bf_override')::boolean, false) and coalesce(trim(v_set->>'bf_reason'), '') = '' then
      raise exception 'Say why the amounts brought forward differ from last year''s computation.';
    end if;
    update cit_years set settings = v_set where org_id = p_org and accounting_year = p_year;
  end if;
  if p ? 'adjustments' then
    v_adj := coalesce(cy.adjustments, '{}'::jsonb);
    for x in select key, value from jsonb_each(p->'adjustments') loop
      if not exists (select 1 from cit_template_lines where cell = x.key and sheet = 'PROFIT_ADJUSTMENT') then raise exception 'Unknown adjustment row %.', x.key; end if;
      if x.key = 'PROFIT_ADJUSTMENT!D23' then raise exception 'The computation starts from profit before tax, so the tax charge is never added back.'; end if;
      if jsonb_typeof(x.value) = 'null' then v_adj := v_adj - x.key; continue; end if;
      v_items := '[]'::jsonb;
      for it in select * from jsonb_array_elements(coalesce(x.value->'items', '[]'::jsonb)) loop
        continue when coalesce(trim(it->>'label'), '') = '' and coalesce(private.num(it->>'amount'), 0) = 0;
        if coalesce(trim(it->>'label'), '') = '' then raise exception 'Describe each adjustment.'; end if;
        if coalesce(private.num(it->>'amount'), 0) <= 0 then raise exception 'Enter the amount of "%".', trim(it->>'label'); end if;
        if coalesce(trim(it->>'reason'), '') = '' then raise exception 'Give the reason for "%".', trim(it->>'label'); end if;
        v_items := v_items || jsonb_build_array(jsonb_build_object('label', left(trim(it->>'label'), 160), 'amount', round(private.num(it->>'amount'), 2),
          'reason', left(trim(it->>'reason'), 400), 'by', m.display_name, 'at', now()));
      end loop;
      if x.value ? 'override' and jsonb_typeof(x.value->'override') = 'object' then
        if private.num(x.value->'override'->>'amount') is null or private.num(x.value->'override'->>'amount') < 0 then raise exception 'Enter the amount for the row.'; end if;
        if coalesce(trim(x.value->'override'->>'reason'), '') = '' then raise exception 'Give the reason for replacing the row.'; end if;
        v_adj := jsonb_set(v_adj, array[x.key], jsonb_build_object('items', v_items, 'override', jsonb_build_object('amount', round(private.num(x.value->'override'->>'amount'), 2),
          'reason', left(trim(x.value->'override'->>'reason'), 400), 'label', nullif(left(trim(x.value->'override'->>'label'), 160), ''), 'by', m.display_name, 'at', now())));
      else
        v_adj := jsonb_set(v_adj, array[x.key], jsonb_build_object('items', v_items));
      end if;
    end loop;
    update cit_years set adjustments = v_adj where org_id = p_org and accounting_year = p_year;
  end if;
  if p ? 'overrides' then
    v_ovr := coalesce(cy.overrides, '{}'::jsonb);
    for x in select key, value from jsonb_each(p->'overrides') loop
      if not exists (select 1 from cit_template_lines where cell = x.key and sheet <> 'PROFIT_ADJUSTMENT' and cell <> 'USER_INPUT!D7') then raise exception 'Unknown template line %.', x.key; end if;
      if jsonb_typeof(x.value) = 'null' then v_ovr := v_ovr - x.key; continue; end if;
      if private.num(x.value->>'amount') is null then raise exception 'Enter the amount for %.', x.key; end if;
      if coalesce(trim(x.value->>'reason'), '') = '' then raise exception 'Give the reason for changing %.', (select label from cit_template_lines where cell = x.key); end if;
      v_ovr := jsonb_set(v_ovr, array[x.key], jsonb_build_object('amount', round(private.num(x.value->>'amount'), 2), 'reason', left(trim(x.value->>'reason'), 400),
        'by', m.display_name, 'at', now()));
    end loop;
    update cit_years set overrides = v_ovr where org_id = p_org and accounting_year = p_year;
  end if;
  if p ? 'imported' then
    v_imp := coalesce(cy.imported, '{}'::jsonb);
    for x in select key, value from jsonb_each(p->'imported') loop
      if not exists (select 1 from cit_template_lines where cell = x.key and cell <> 'USER_INPUT!D7') then raise exception 'Unknown template line %.', x.key; end if;
      if jsonb_typeof(x.value) = 'null' then v_imp := v_imp - x.key; continue; end if;
      v_amt := private.num(x.value #>> (case when jsonb_typeof(x.value) = 'object' then '{amount}' else '{}' end)::text[]);
      if v_amt is null then raise exception 'Enter the amount for %.', (select label from cit_template_lines where cell = x.key); end if;
      if v_amt = 0 then v_imp := v_imp - x.key; continue; end if;
      v_imp := jsonb_set(v_imp, array[x.key], jsonb_build_object('amount', round(v_amt, 2),
        'source', 'manual', 'by', m.display_name, 'at', now()) || case when jsonb_typeof(x.value) = 'object' and x.value ? 'note' then jsonb_build_object('note', x.value->>'note') else '{}'::jsonb end);
    end loop;
    update cit_years set imported = v_imp, source = 'imported' where org_id = p_org and accounting_year = p_year;
  end if;
  if p ? 'afs_path' then
    if nullif(p->>'afs_path', '') is not null and split_part(p->>'afs_path', '/', 1) <> p_org::text then raise exception 'That file is not this business''s.'; end if;
    update cit_years set afs_path = nullif(p->>'afs_path', '') where org_id = p_org and accounting_year = p_year;
  end if;
  update cit_years set updated_by = m.id, updated_at = now(), status = 'draft' where org_id = p_org and accounting_year = p_year;
  return public.cit_year(p_org, p_year);
end $function$;

CREATE OR REPLACE FUNCTION public.cit_import(p_org uuid, p_year integer, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; cy public.cit_years; pr record; v_imp jsonb; x jsonb; v_n int := 0;
begin
  m := private.require(p_org, 'keep_books');
  select pfrom, pto into pr from private.cit_period(p_org, p_year);
  insert into cit_years (org_id, accounting_year, period_from, period_to, source, updated_by) values (p_org, p_year, pr.pfrom, pr.pto, 'imported', m.id)
  on conflict (org_id, accounting_year) do nothing;
  select * into cy from cit_years where org_id = p_org and accounting_year = p_year for update;
  if cy.status not in ('draft', 'rejected') then raise exception 'The % return is %. Reopen it to change it.', p_year, cy.status; end if;
  if exists (select 1 from pit_years where org_id = p_org and accounting_year = p_year and status = 'approved') then
    raise exception 'The % income tax return is approved. Reopen it under Income tax to change the figures.', p_year;
  end if;
  if nullif(p->>'file_path', '') is not null and split_part(p->>'file_path', '/', 1) <> p_org::text then raise exception 'That file is not this business''s.'; end if;
  v_imp := case when coalesce((p->>'replace')::boolean, true) then '{}'::jsonb else coalesce(cy.imported, '{}'::jsonb) end;
  -- Several source lines can land on one template line: they add up, and the line keeps the lowest confidence among them.
  for x in
    select jsonb_build_object('cell', l->>'cell', 'amount', round(sum(private.num(l->>'amount')), 2), 'confidence', round(min(coalesce(private.num(l->>'confidence'), 1)), 3),
      'note', left(string_agg(nullif(trim(l->>'note'), ''), '; '), 300), 'n', count(*)) x
    from jsonb_array_elements(coalesce(p->'lines', '[]'::jsonb)) l
    where coalesce(private.num(l->>'amount'), 0) <> 0 and exists (select 1 from cit_template_lines t where t.cell = l->>'cell' and t.cell <> 'USER_INPUT!D7')
    group by l->>'cell'
  loop
    v_imp := jsonb_set(v_imp, array[x->>'cell'], jsonb_build_object('amount', (x->>'amount')::numeric, 'source', coalesce(nullif(p->>'kind', ''), 'afs'),
      'confidence', (x->>'confidence')::numeric, 'note', x->>'note', 'lines', (x->>'n')::int));
    v_n := v_n + (x->>'n')::int;
  end loop;
  update cit_years set imported = v_imp, source = 'imported', status = 'draft', updated_by = m.id, updated_at = now(),
    imported_from = jsonb_build_object('kind', coalesce(nullif(p->>'kind', ''), 'afs'), 'file_path', nullif(p->>'file_path', ''), 'lines', v_n, 'at', now(), 'by', m.display_name)
      || coalesce((select jsonb_object_agg(k, round(private.num(val), 2)) from jsonb_each_text(coalesce(p->'totals', '{}'::jsonb)) t(k, val)
                   where k in ('revenue', 'profit_before_tax', 'total_assets', 'total_equity_liabilities') and private.num(val) is not null), '{}'::jsonb)
  where org_id = p_org and accounting_year = p_year;
  return public.cit_year(p_org, p_year);
end $function$;

-- ---------------------------------------------------------------------------
-- 4. The PIT engine
-- ---------------------------------------------------------------------------
-- The PIT rule book for an accounting year (year of assessment = accounting year + 1): the approved one, else the newest draft.
create or replace function private.pit_rulebook(p_year int) returns public.tax_rulebooks
language sql stable security definer set search_path = public, private as $$
  select r.* from tax_rulebooks r
  where r.regime in ('PITA', 'NTA_2025_PIT') and r.status in ('approved', 'draft')
    and (r.yoa_from is null or r.yoa_from <= p_year + 1) and (r.yoa_to is null or r.yoa_to >= p_year + 1)
  order by (r.status = 'approved') desc, r.created_at desc limit 1
$$;

-- The return is due on the day the rule book gives (31 March) of the year after the accounting year ends.
create or replace function private.pit_due(p_org uuid, p_year int) returns date
language sql stable security definer set search_path = public, private as $$
  select make_date(extract(year from (private.cit_period(p_org, p_year)).pto)::int + 1,
    coalesce(((private.pit_rulebook(p_year)).config->'filing'->>'due_month')::int, 3),
    coalesce(((private.pit_rulebook(p_year)).config->'filing'->>'due_day')::int, 31))
$$;

-- Tax at graduated rates: [{label, width (null for the top band), rate}] → {tax, bands: [{label, from, to, rate, slice, tax}]}.
create or replace function private.pit_bands(p_income numeric, p_bands jsonb) returns jsonb
language plpgsql immutable set search_path = public, private as $$
declare b jsonb; v_left numeric := greatest(coalesce(p_income, 0), 0); v_from numeric := 0; v_w numeric; v_slice numeric; v_t numeric;
  v_tax numeric := 0; v_rows jsonb := '[]'::jsonb;
begin
  for b in select value from jsonb_array_elements(coalesce(p_bands, '[]'::jsonb)) loop
    v_w := case when jsonb_typeof(b->'width') = 'number' then (b->>'width')::numeric end;
    v_slice := case when v_w is null then v_left else least(v_left, v_w) end;
    v_t := round(v_slice * (b->>'rate')::numeric, 2);
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('label', b->>'label', 'from', v_from, 'to', case when v_w is not null then v_from + v_w end,
      'rate', (b->>'rate')::numeric, 'slice', round(v_slice, 2), 'tax', v_t));
    v_tax := v_tax + v_t;
    v_left := v_left - v_slice;
    v_from := v_from + coalesce(v_w, 0);
  end loop;
  return jsonb_build_object('tax', round(v_tax, 2), 'bands', v_rows);
end $$;

-- One person's computation. A pure function of the rule book and a bundle of inputs, so the same bundle always gives the
-- same answer (and Numen can be checked against it):
--   p: {name, sole (one proprietor), share_pct, assessable (the business's assessable profit), remuneration (pay, interest on
--       capital and benefits charged in the accounts for the person), ca_year (the business's allowances for the year),
--       gains_net (the business's net chargeable gains), wht_available (the business's WHT credit notes still unused),
--       losses_bf, ca_bf, reliefs: {pension, nhf, nhis, life_insurance, home_loan_interest, gratuity, rent_paid},
--       other_income: [{kind, label, amount, tax_deducted, final_tax}]}
-- Answers {rows, figures, bands, other_income (each line with its treatment), cf: {losses, ca}}.
create or replace function private.pit_person_tax(p_rb jsonb, p jsonb) returns jsonb
language plpgsql immutable set search_path = public, private as $$
declare
  v_nta boolean := coalesce(p_rb->'meta'->>'regime', '') = 'NTA_2025_PIT';
  v_sole boolean := coalesce((p->>'sole')::boolean, false);
  v_share numeric := round(coalesce(private.num(p->>'share_pct'), 0), 4);
  v_ap numeric := round(coalesce(private.num(p->>'assessable'), 0), 2);
  v_rem numeric := round(greatest(coalesce(private.num(p->>'remuneration'), 0), 0), 2);
  v_ca_year numeric := round(greatest(coalesce(private.num(p->>'ca_year'), 0), 0), 2);
  v_gains_all numeric := round(coalesce(private.num(p->>'gains_net'), 0), 2);
  v_wht_all numeric := round(greatest(coalesce(private.num(p->>'wht_available'), 0), 0), 2);
  v_loss_bf numeric := round(greatest(coalesce(private.num(p->>'losses_bf'), 0), 0), 2);
  v_ca_bf numeric := round(greatest(coalesce(private.num(p->>'ca_bf'), 0), 0), 2);
  rl jsonb := coalesce(p->'reliefs', '{}'::jsonb);
  oi jsonb := coalesce(p->'other_income', '[]'::jsonb);
  v_final text[] := coalesce(array(select jsonb_array_elements_text(p_rb->'other_income'->'final_tax_kinds')), '{}');
  v_exempt text[] := coalesce(array(select jsonb_array_elements_text(p_rb->'other_income'->'exempt_kinds')), '{}');
  v_minwage numeric := coalesce(private.num(p_rb->'other_income'->>'minimum_wage_monthly_ngn'), 70000) * 12;
  v_sh numeric; v_biz numeric; v_loss_use numeric; v_rem1 numeric; v_ca_share numeric; v_ca_avail numeric; v_ca_use numeric; v_biz_net numeric;
  v_new_loss numeric; v_g numeric; v_g_tax numeric := 0; v_off numeric; v_cgt numeric := 0;
  x jsonb; v_kind text; v_amt numeric; v_td numeric; v_treat text; v_lines jsonb := '[]'::jsonb; v_oth numeric := 0; v_oth_ex numeric := 0; v_oth_fin numeric := 0;
  v_cred numeric := 0; v_fx_inc numeric := 0; v_fx_tax numeric := 0;
  v_total numeric; v_pension numeric; v_nhf numeric; v_nhis numeric; v_life numeric; v_home numeric; v_grat numeric; v_rent numeric; v_rent_relief numeric := 0;
  v_exempt_tot numeric := 0; v_base numeric := 0; v_cra numeric := 0; v_cra_fixed numeric := 0; v_reliefs numeric; v_chargeable numeric; b jsonb; v_bt numeric;
  v_mt numeric := 0; v_mt_used boolean := false; v_tax numeric; v_ftc numeric := 0; v_after numeric; v_cred_use numeric; v_wht_share numeric; v_wht_use numeric;
  v_payable numeric; v_rows jsonb := '[]'::jsonb; v_pct text; v_law text; v_marg numeric;
begin
  v_pct := trim(to_char(v_share, 'FM990.####')) || '%';
  v_law := case when v_nta then 'NTA 2025' else 'PITA' end;

  -- Income from the business: the share of its assessable profit, and what the accounts charged for the person (s.15(1)).
  v_sh := round(v_ap * v_share / 100, 2);
  v_biz := v_sh + v_rem;
  v_loss_use := least(v_loss_bf, greatest(v_biz, 0));
  v_rem1 := greatest(v_biz, 0) - v_loss_use;
  v_ca_share := round(v_ca_year * v_share / 100, 2);
  v_ca_avail := v_ca_share + v_ca_bf;
  v_ca_use := least(v_ca_avail, v_rem1);
  v_biz_net := v_rem1 - v_ca_use;
  v_new_loss := greatest(-v_biz, 0);

  -- Chargeable gains on the business's disposals, shared like the profit.
  v_g := round(v_gains_all * v_share / 100, 2);
  if coalesce((p_rb->'chargeable_gains'->>'in_total_income')::boolean, false) then
    if v_g > 0 then
      v_off := least(v_new_loss, v_g); v_new_loss := v_new_loss - v_off; v_g_tax := v_g - v_off;
    else
      v_new_loss := v_new_loss - v_g;
    end if;
  else
    v_cgt := round(greatest(v_g, 0) * coalesce(private.num(p_rb->'chargeable_gains'->>'separate_rate'), 0.10), 2);
  end if;

  -- Other income, line by line: taxable (with any tax deducted as a credit), taxed in full at source, or exempt.
  for x in select value from jsonb_array_elements(oi) loop
    v_kind := coalesce(x->>'kind', 'other');
    v_amt := round(greatest(coalesce(private.num(x->>'amount'), 0), 0), 2);
    v_td := round(greatest(coalesce(private.num(x->>'tax_deducted'), 0), 0), 2);
    continue when v_amt = 0;
    v_treat := case
      when v_kind = any(v_exempt) then 'exempt'
      when v_kind = 'employment' and v_amt <= v_minwage then 'exempt_minimum_wage'
      when v_kind = any(v_final) and v_td > 0 and coalesce((x->>'final_tax')::boolean, true) then 'final'
      else 'taxable' end;
    if v_treat = 'taxable' then
      v_oth := v_oth + v_amt;
      if v_kind = 'foreign_earned' then v_fx_inc := v_fx_inc + v_amt; v_fx_tax := v_fx_tax + v_td; else v_cred := v_cred + v_td; end if;
    elsif v_treat = 'final' then v_oth_fin := v_oth_fin + v_amt;
    else v_oth_ex := v_oth_ex + v_amt; end if;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('kind', v_kind, 'label', coalesce(nullif(trim(x->>'label'), ''), initcap(replace(v_kind, '_', ' '))),
      'amount', v_amt, 'tax_deducted', v_td, 'treatment', v_treat));
  end loop;

  v_total := v_biz_net + v_g_tax + v_oth;

  -- Reliefs.
  v_pension := round(greatest(coalesce(private.num(rl->>'pension'), 0), 0), 2);
  v_nhf := round(greatest(coalesce(private.num(rl->>'nhf'), 0), 0), 2);
  v_nhis := round(greatest(coalesce(private.num(rl->>'nhis'), 0), 0), 2);
  v_life := round(greatest(coalesce(private.num(rl->>'life_insurance'), 0), 0), 2);
  v_home := round(greatest(coalesce(private.num(rl->>'home_loan_interest'), 0), 0), 2);
  v_grat := round(greatest(coalesce(private.num(rl->>'gratuity'), 0), 0), 2);
  v_rent := round(greatest(coalesce(private.num(rl->>'rent_paid'), 0), 0), 2);
  if v_nta then
    v_rent_relief := least(round(v_rent * coalesce(private.num(p_rb->'reliefs'->'rent_relief'->>'pct'), 0.20), 2),
                           coalesce(private.num(p_rb->'reliefs'->'rent_relief'->>'cap_ngn'), 500000));
    v_reliefs := v_nhf + v_nhis + v_pension + v_home + v_life + v_rent_relief;
  else
    -- PITA s.33 as amended by the Finance Act 2020: the tax-exempt contributions come off first, the CRA is worked on what
    -- is left, and home loan interest comes off after it.
    v_exempt_tot := v_pension + v_nhf + v_nhis + v_life + v_grat;
    v_base := greatest(v_total - v_exempt_tot, 0);
    v_cra_fixed := greatest(coalesce(private.num(p_rb->'reliefs'->'cra'->>'fixed_ngn'), 200000), round(v_base * coalesce(private.num(p_rb->'reliefs'->'cra'->>'fixed_pct'), 0.01), 2));
    v_cra := v_cra_fixed + round(v_base * coalesce(private.num(p_rb->'reliefs'->'cra'->>'variable_pct'), 0.20), 2);
    v_reliefs := v_exempt_tot + v_cra + v_home;
  end if;
  v_chargeable := greatest(v_total - v_reliefs, 0);

  b := private.pit_bands(v_chargeable, p_rb->'tax_bands');
  v_bt := (b->>'tax')::numeric;
  v_tax := v_bt;
  if coalesce((p_rb->'minimum_tax'->>'applies')::boolean, false) and v_total > 0 then
    v_mt := round(v_base * coalesce(private.num(p_rb->'minimum_tax'->>'rate'), 0.01), 2);
    if v_mt > v_bt then v_tax := v_mt; v_mt_used := true; end if;
  end if;

  -- Credits: foreign tax (the lower of the foreign tax and the Nigerian tax on that income), tax deducted from other income,
  -- then the person's share of the business's WHT credit notes. None makes the tax negative.
  if v_fx_inc > 0 and v_total > 0 then v_ftc := least(v_fx_tax, round(v_tax * least(v_fx_inc / v_total, 1), 2)); end if;
  v_after := v_tax - v_ftc;
  v_cred_use := least(v_cred, v_after);
  v_after := v_after - v_cred_use;
  v_wht_share := round(v_wht_all * v_share / 100, 2);
  v_wht_use := least(v_wht_share, v_after);
  v_payable := v_after - v_wht_use;
  v_marg := (select (x2->>'rate')::numeric from jsonb_array_elements(b->'bands') x2 where (x2->>'slice')::numeric > 0 order by (x2->>'from')::numeric desc limit 1);

  -- The computation, line by line.
  v_rows := jsonb_build_array(jsonb_build_object('id', 'S1',
    'line', case when v_sole then 'Assessable profit of the business' else 'Share of the business''s assessable profit (' || v_pct || ')' end,
    'amount', v_sh, 'basis', case when v_sole then 'PIT rule book s.1: the owner is taxed on the whole profit'
                                  else v_pct || ' of ' || private.naira(v_ap) || ' (s.15(1)(b) and (3))' end, '_style', 'line'));
  if v_rem <> 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'S2',
      'line', case when v_sole then 'Add: the owner''s own pay charged as an expense' else 'Add: pay, interest on capital and benefits charged in the accounts' end,
      'amount', v_rem, 'basis', case when v_sole then 'A drawing, not a business expense (s.21(c))' else 's.15(1)(a)' end, '_style', 'line'));
  end if;
  v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'S3', 'line', 'Income from the business', 'amount', v_biz, '_style', 'subtotal'));
  if v_loss_bf > 0 or v_loss_use > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'S4', 'line', 'Less: losses brought forward', 'amount', -v_loss_use,
      'basis', private.naira(v_loss_bf) || ' brought forward' || case when v_nta then '; no time limit (s.28(3))' else '' end, '_style', 'line'));
  end if;
  if v_ca_avail > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'S5', 'line', 'Less: capital allowances', 'amount', -v_ca_use,
      'basis', case when v_sole then private.naira(v_ca_share) || ' for the year' else private.naira(v_ca_share) || ', ' || v_pct || ' of the business''s ' || private.naira(v_ca_year) end
        || case when v_ca_bf > 0 then ' and ' || private.naira(v_ca_bf) || ' brought forward' else '' end, '_style', 'line'));
  end if;
  if v_nta and v_g <> 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'S6', 'line', 'Add: chargeable gains on the business''s disposals', 'amount', v_g_tax,
      'basis', case when v_sole then '' else v_pct || ' of ' || private.naira(v_gains_all) || '; ' end || 'taxed with income (s.28(2)(a)(v))'
        || case when v_g < 0 then '; the net loss is carried forward' when v_g_tax < v_g then '; reduced by the year''s business loss' else '' end, '_style', 'line'));
  end if;
  if v_oth > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'S7', 'line', 'Add: other income', 'amount', v_oth,
      'basis', (select string_agg((l->>'label') || ' ' || private.naira((l->>'amount')::numeric), '; ') from jsonb_array_elements(v_lines) l where l->>'treatment' = 'taxable'),
      '_style', 'line'));
  end if;
  v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'T', 'line', 'Total income', 'amount', v_total, '_style', 'subtotal'));
  if v_nta then
    v_rows := v_rows
      || case when v_nhf > 0 then jsonb_build_array(jsonb_build_object('id', 'R1', 'line', 'Less: National Housing Fund contributions', 'amount', -v_nhf, 'basis', 's.30(2)(a)(i)', '_style', 'line')) else '[]'::jsonb end
      || case when v_nhis > 0 then jsonb_build_array(jsonb_build_object('id', 'R2', 'line', 'Less: National Health Insurance contributions', 'amount', -v_nhis, 'basis', 's.30(2)(a)(ii)', '_style', 'line')) else '[]'::jsonb end
      || case when v_pension > 0 then jsonb_build_array(jsonb_build_object('id', 'R3', 'line', 'Less: pension contributions', 'amount', -v_pension, 'basis', 's.30(2)(a)(iii), Pension Reform Act', '_style', 'line')) else '[]'::jsonb end
      || case when v_home > 0 then jsonb_build_array(jsonb_build_object('id', 'R4', 'line', 'Less: interest on a loan for an owner-occupied home', 'amount', -v_home, 'basis', 's.30(2)(a)(iv)', '_style', 'line')) else '[]'::jsonb end
      || case when v_life > 0 then jsonb_build_array(jsonb_build_object('id', 'R5', 'line', 'Less: life insurance or deferred annuity premiums', 'amount', -v_life, 'basis', 's.30(2)(a)(v)', '_style', 'line')) else '[]'::jsonb end
      || case when v_rent > 0 then jsonb_build_array(jsonb_build_object('id', 'R6', 'line', 'Less: rent relief', 'amount', -v_rent_relief,
           'basis', '20% of ' || private.naira(v_rent) || ' rent paid, at most ' || private.naira(coalesce(private.num(p_rb->'reliefs'->'rent_relief'->>'cap_ngn'), 500000)) || ' (s.30(2)(a)(vi))', '_style', 'line')) else '[]'::jsonb end;
  else
    v_rows := v_rows
      || case when v_exempt_tot > 0 then jsonb_build_array(jsonb_build_object('id', 'R1', 'line', 'Less: pension, NHF, NHIS, life insurance and gratuity', 'amount', -v_exempt_tot,
           'basis', 'Tax-exempt contributions, taken off before the CRA (PITA s.33(2))', '_style', 'line')) else '[]'::jsonb end
      || jsonb_build_array(jsonb_build_object('id', 'R2', 'line', 'Less: consolidated relief allowance', 'amount', -v_cra,
           'basis', 'Higher of ' || private.naira(coalesce(private.num(p_rb->'reliefs'->'cra'->>'fixed_ngn'), 200000)) || ' or 1% (' || private.naira(v_cra_fixed) || '), plus 20%, of ' || private.naira(v_base)
             || ' (PITA s.33(1), Sixth Schedule)', '_style', 'line'))
      || case when v_home > 0 then jsonb_build_array(jsonb_build_object('id', 'R3', 'line', 'Less: interest on a loan for an owner-occupied home', 'amount', -v_home, 'basis', 'PITA s.20(1)(c)', '_style', 'line')) else '[]'::jsonb end;
  end if;
  v_rows := v_rows || jsonb_build_array(
    jsonb_build_object('id', 'C', 'line', 'Chargeable income', 'amount', v_chargeable, 'basis', case when v_reliefs > v_total and v_total > 0 then 'The reliefs are more than the income' end, '_style', 'subtotal'),
    jsonb_build_object('id', 'X', 'line', 'Tax at the ' || case when v_nta then 'Fourth' else 'Sixth' end || ' Schedule rates', 'amount', v_bt,
      'basis', coalesce((select string_agg(trim(to_char((x2->>'rate')::numeric * 100, 'FM990.##')) || '% on ' || private.naira((x2->>'slice')::numeric), ', ' order by (x2->>'from')::numeric)
        from jsonb_array_elements(b->'bands') x2 where (x2->>'slice')::numeric > 0), 'No tax at the rates'), '_style', 'line'));
  if coalesce((p_rb->'minimum_tax'->>'applies')::boolean, false) then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'M', 'line', 'Minimum tax (1% of ' || private.naira(v_base) || ')', 'amount', v_mt,
      'basis', case when v_total <= 0 then 'No income, so no minimum tax' when v_mt_used then 'Higher than the tax at the rates, so it is payable instead (PITA s.37)'
                    else 'Lower than the tax at the rates' end, '_style', 'line'));
  end if;
  v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'K', 'line', 'Income tax for the year', 'amount', v_tax, '_style', 'subtotal'));
  if v_ftc > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'F1', 'line', 'Less: foreign tax credit', 'amount', -v_ftc,
      'basis', 'Lower of the foreign tax (' || private.naira(v_fx_tax) || ') and the Nigerian tax on that income (PIT rule book s.7)', '_style', 'line'));
  end if;
  if v_cred > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'F2', 'line', 'Less: PAYE and tax deducted from other income', 'amount', -v_cred_use,
      'basis', private.naira(v_cred) || ' deducted' || case when v_cred_use < v_cred then '; ' || private.naira(v_cred - v_cred_use) || ' more than the tax' else '' end, '_style', 'line'));
  end if;
  if v_wht_share > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'F3', 'line', 'Less: ' || case when v_sole then 'the business''s' else 'share of the business''s' end || ' WHT credit notes',
      'amount', -v_wht_use, 'basis', private.naira(v_wht_share) || case when v_sole then '' else ' (' || v_pct || ')' end || ' held'
        || case when v_wht_use < v_wht_share then '; ' || private.naira(v_wht_share - v_wht_use) || ' kept for later years' else '' end, '_style', 'line'));
  end if;
  v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'P', 'line', 'Tax payable', 'amount', v_payable, '_style', 'total'));
  if v_cgt > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', 'CGT', 'line', 'Capital gains tax at 10% on ' || case when v_sole then 'the' else 'the share of the' end || ' gains (' || private.naira(v_g) || ')',
      'amount', v_cgt, 'basis', 'Filed on its own capital gains tax return (Capital Gains Tax Act); not part of the income tax above', '_style', 'memo'));
  end if;

  return jsonb_build_object('rows', v_rows, 'bands', b->'bands', 'other_income', v_lines, 'regime', case when v_nta then 'NTA_2025_PIT' else 'PITA' end,
    'figures', jsonb_build_object('share_pct', v_share, 'share_profit', v_sh, 'remuneration', v_rem, 'business_income', v_biz, 'losses_bf', v_loss_bf,
      'loss_relief', v_loss_use, 'ca_share', v_ca_share, 'ca_bf', v_ca_bf, 'ca_available', v_ca_avail, 'capital_allowances', v_ca_use, 'business_net', v_biz_net,
      'gains', v_g, 'gains_taxed', v_g_tax, 'other_income', v_oth, 'other_income_final_tax', v_oth_fin, 'other_income_exempt', v_oth_ex,
      'total_income', v_total, 'exempt_contributions', v_exempt_tot, 'cra_base', v_base, 'cra', v_cra, 'rent_relief', v_rent_relief, 'reliefs', v_reliefs,
      'chargeable_income', v_chargeable, 'tax_at_rates', v_bt, 'minimum_tax', v_mt, 'minimum_tax_used', v_mt_used, 'tax', v_tax,
      'foreign_income', v_fx_inc, 'foreign_tax', v_fx_tax, 'foreign_tax_credit', v_ftc, 'other_credits', v_cred, 'other_credits_used', v_cred_use,
      'wht_share', v_wht_share, 'wht_credit', v_wht_use, 'payable', v_payable, 'cgt', v_cgt,
      'effective_rate', case when v_total > 0 then round(v_tax / v_total, 4) else 0 end, 'marginal_rate', coalesce(v_marg, 0)),
    'cf', jsonb_build_object('losses', round(v_loss_bf - v_loss_use + v_new_loss, 2), 'ca', round(v_ca_avail - v_ca_use, 2)));
end $$;

-- The first year Counta prepares a PIT return for: 2025 accounts, or the first year of the books if later.
create or replace function private.pit_first_year(p_org uuid) returns int
language sql stable security definer set search_path = public, private as $$
  select greatest(2025, private.cit_first_year(p_org))
$$;

-- The business's side of the year: its assessable profit, allowances, gains and WHT credit notes, from the same figures and
-- adjustments as companies income tax, with the PIT rule book's own adjustments on top.
create or replace function private.pit_business(p_org uuid, p_year int) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare rbr public.tax_rulebooks; rb jsonb; c jsonb; cells jsonb; pa jsonb; fig jsonb; cy public.cit_years; py public.pit_years; st jsonb; mu jsonb;
  v_legacy boolean; v_turn numeric; v_pbt numeric; v_b numeric; v_c numeric; v_d numeric; x jsonb; v_amt numeric; v_pct numeric; v_back numeric;
  v_mu numeric := 0; v_mu_lines jsonb := '[]'::jsonb; v_don numeric; v_don_out numeric; v_don_back numeric := 0; v_rd numeric; v_rd_cap numeric; v_rd_back numeric := 0;
  v_adj numeric; ca jsonb; v_open_year int; v_open jsonb; v_ntax numeric; v_bc numeric; v_ap numeric; v_ca_year numeric; v_gain_inv numeric; v_gains_other numeric;
  v_gains numeric; v_wht numeric; v_to date; v_source text; v_rows jsonb; v_checks jsonb;
begin
  rbr := private.pit_rulebook(p_year); rb := rbr.config;
  v_legacy := coalesce(rb->'capital_allowances'->>'law', 'nta') = 'legacy';
  c := private.cit_compute(p_org, p_year, '{"losses": 0, "ca": 0, "interest": []}'::jsonb);
  cells := coalesce(c->'cells', '{}'::jsonb); pa := coalesce(c->'adjustments', '{}'::jsonb); fig := coalesce(c->'figures', '{}'::jsonb);
  select * into cy from cit_years where org_id = p_org and accounting_year = p_year;
  select * into py from pit_years where org_id = p_org and accounting_year = p_year;
  st := coalesce(py.settings, '{}'::jsonb); mu := coalesce(st->'mixed_use', '{}'::jsonb);
  v_turn := private.v(fig, 'turnover'); v_pbt := private.v(fig, 'profit_before_tax');
  v_b := private.v(fig, 'addbacks'); v_c := private.v(fig, 'deductions'); v_d := private.v(fig, 'assessable');
  v_to := (c->>'to')::date; v_source := c->>'source';

  -- Mixed use (rule book s.4): only the business share of each line marked is deducted.
  for x in select value from jsonb_array_elements(coalesce(rb->'business'->'mixed_use'->'lines', '[]'::jsonb)) loop
    v_amt := private.v(cells, x->>'cell');
    v_pct := case when mu ? (x->>'cell') then least(greatest(coalesce(private.num(mu->>(x->>'cell')), 100), 0), 100) end;
    v_back := case when v_pct is not null and v_amt > 0 then round(v_amt * (100 - v_pct) / 100, 2) else 0 end;
    v_mu := v_mu + v_back;
    if v_amt <> 0 or v_pct is not null then
      v_mu_lines := v_mu_lines || jsonb_build_array(jsonb_build_object('cell', x->>'cell', 'group', x->>'group', 'label', x->>'label', 'amount', v_amt,
        'marked', v_pct is not null, 'business_pct', coalesce(v_pct, 100), 'addback', v_back));
    end if;
  end loop;
  -- Donations: not an expense of producing the income, and the deduction in s.163 is for companies.
  if not coalesce((rb->'business'->>'donations_deductible')::boolean, false) then
    v_don := private.v(cells, 'ADMINISTRATIVE_EXPENSES!C22');
    v_don_out := private.v(pa, 'PROFIT_ADJUSTMENT!D15');
    v_don_back := greatest(round(v_don - v_don_out, 2), 0);
  end if;
  -- Research and development above 5% of turnover (rule book s.2).
  v_rd := private.v(cells, 'ADMINISTRATIVE_EXPENSES!C36');
  v_rd_cap := round(greatest(v_turn, 0) * coalesce(private.num(rb->'business'->>'rd_cap_pct_of_turnover'), 0.05), 2);
  v_rd_back := greatest(round(v_rd - v_rd_cap, 2), 0);
  v_adj := round(v_d + v_mu + v_don_back + v_rd_back, 2);

  -- Capital allowances for the business as one enterprise, under the law of each year (old law to 2025 accounts), with the
  -- business share of partly private assets. Tax values given for the first year Counta prepares are taken from that year on.
  select c2.accounting_year, c2.settings->'opening_twdv' into v_open_year, v_open from cit_years c2
    where c2.org_id = p_org and c2.accounting_year between private.pit_first_year(p_org) and p_year
      and jsonb_typeof(c2.settings->'opening_twdv') = 'object' and c2.settings->'opening_twdv' <> '{}'::jsonb
    order by c2.accounting_year limit 1;
  v_ntax := case when v_turn + private.v(c->'totals', 'other_income') > 0
                 then private.v(cells, 'OTHER_INCOME!D12') / (v_turn + private.v(c->'totals', 'other_income')) else 0 end;
  ca := private.cit_ca(p_org, p_year, jsonb_build_object('nontax_share', v_ntax, 'short_factor', coalesce(private.num(fig->>'short_factor'), 1),
    'opening_year', v_open_year, 'opening_twdv', coalesce(v_open, '{}'::jsonb), 'legacy_upto', 2025, 'use_pct_always', true));
  v_bc := case when v_legacy then private.v(ca->'totals', 'balancing_charge') else 0 end;
  v_ap := round(v_adj + v_bc, 2);
  v_ca_year := round(private.v(ca->'totals', 'allowance') + private.v(ca->'totals', 'balancing_allowance')
    + case when v_legacy then 0 else private.v(ca->'totals', 'residue_on_disposal') end, 2);   -- no investment allowance for individuals (P-8)

  -- Gains on disposals: fixed assets from the schedule, investments from the accounts, and others the business adds.
  v_gain_inv := private.v(cells, 'OTHER_INCOME!D9');
  v_gains_other := coalesce(private.num(cy.settings->>'chargeable_gains_other'), 0);
  v_gains := round(private.v(ca->'totals', 'gains') - private.v(ca->'totals', 'losses') + v_gain_inv + v_gains_other, 2);

  -- WHT credit notes held at the year end (account 1401).
  if v_source = 'imported' then v_wht := private.v(cells, 'STATEMENT_OF_FINANCIAL_POSITION!D51');
  else select coalesce(sum(b.bal), 0) into v_wht from private.balances_at(p_org, v_to) b where split_part(b.code, '-', 1) = '1401'; end if;
  v_wht := round(greatest(coalesce(v_wht, 0), 0), 2);

  v_rows := jsonb_build_array(
    jsonb_build_object('id', 'A', 'line', 'Profit / (loss) before tax', 'amount', v_pbt,
      'basis', case when v_source = 'imported' then 'From the accounts read in' else 'From the books' end, '_style', 'subtotal'),
    jsonb_build_object('id', 'B', 'line', 'Add: disallowable expenses', 'amount', v_b, 'basis', 'Depreciation and the other add-backs under Adjustments', '_style', 'line'),
    jsonb_build_object('id', 'C', 'line', 'Less: income not taxed and tax-only deductions', 'amount', -v_c, 'basis', 'Under Adjustments', '_style', 'line'))
  || case when v_mu <> 0 then jsonb_build_array(jsonb_build_object('id', 'B2', 'line', 'Add: private share of mixed-use expenses', 'amount', v_mu,
       'basis', (select string_agg((l->>'label') || ' ' || trim(to_char(100 - (l->>'business_pct')::numeric, 'FM990.##')) || '% private', '; ')
                 from jsonb_array_elements(v_mu_lines) l where (l->>'addback')::numeric > 0) || ' (PIT rule book s.4)', '_style', 'line')) else '[]'::jsonb end
  || case when v_don_back <> 0 then jsonb_build_array(jsonb_build_object('id', 'B3', 'line', 'Add: donations', 'amount', v_don_back,
       'basis', 'Not deductible for a business name or partnership (s.163 is for companies)', '_style', 'line')) else '[]'::jsonb end
  || case when v_rd_back <> 0 then jsonb_build_array(jsonb_build_object('id', 'B4', 'line', 'Add: research and development above 5% of turnover', 'amount', v_rd_back,
       'basis', private.naira(v_rd) || ' spent; ' || private.naira(v_rd_cap) || ' allowed (PIT rule book s.2)', '_style', 'line')) else '[]'::jsonb end
  || jsonb_build_array(jsonb_build_object('id', 'D', 'line', 'Adjusted profit / (loss)', 'amount', v_adj, '_style', 'subtotal'))
  || case when v_bc <> 0 then jsonb_build_array(jsonb_build_object('id', 'D2', 'line', 'Add: balancing charges', 'amount', v_bc,
       'basis', 'Capital allowance schedule', '_style', 'line')) else '[]'::jsonb end
  || jsonb_build_array(
    jsonb_build_object('id', 'AP', 'line', 'Assessable profit / (loss) of the business', 'amount', v_ap, '_style', 'total'),
    jsonb_build_object('id', 'CA', 'line', 'Capital allowances for the year', 'amount', v_ca_year,
      'basis', 'Shared like the profit and set against each person''s income (First Schedule para 19(3))', '_style', 'memo'))
  || case when v_gains <> 0 then jsonb_build_array(jsonb_build_object('id', 'G', 'line', 'Net chargeable gains on disposals', 'amount', v_gains,
       'basis', case when v_legacy then 'Old law: for the capital gains tax return, not income tax' else 'Shared like the profit and taxed with income' end,
       '_style', 'memo')) else '[]'::jsonb end
  || case when v_wht <> 0 then jsonb_build_array(jsonb_build_object('id', 'W', 'line', 'WHT credit notes held at the year end', 'amount', v_wht,
       'basis', 'Account 1401; shared like the profit', '_style', 'memo')) else '[]'::jsonb end;

  -- The checks on the figures that matter for any return (the Rev360 template's own rules do not apply here).
  select coalesce(jsonb_agg(k), '[]'::jsonb) into v_checks from jsonb_array_elements(coalesce(c->'checks', '[]'::jsonb)) k
    where k->>'id' in ('pbt_ties_to_books', 'books_partial', 'sfp_ties_to_accounts', 'pbt_ties_to_afs', 'revenue_ties_to_pl', 'figures_missing',
                       'year_not_ended', 'ca_category_missing');

  return jsonb_build_object('year', p_year, 'from', c->>'from', 'to', c->>'to', 'ended', (c->>'ended')::boolean, 'source', v_source,
    'regime', rbr.regime, 'rows', v_rows, 'ca', ca, 'mixed_use', v_mu_lines, 'checks', v_checks,
    'figures', jsonb_build_object('profit_before_tax', v_pbt, 'turnover', v_turn, 'addbacks', v_b, 'deductions', v_c, 'adjusted_cit', v_d,
      'mixed_use', v_mu, 'donations', v_don_back, 'rd_excess', v_rd_back, 'adjusted', v_adj, 'balancing_charge', v_bc, 'assessable', v_ap,
      'ca_year', v_ca_year, 'gains', private.v(ca->'totals', 'gains'), 'losses_on_disposal', private.v(ca->'totals', 'losses'),
      'investment_gains', v_gain_inv, 'gains_other', v_gains_other, 'gains_net', v_gains, 'wht_held', v_wht,
      'salaries', private.v(cells, 'ADMINISTRATIVE_EXPENSES!C4') + private.v(cells, 'ADMINISTRATIVE_EXPENSES!C6')));
end $$;

-- The people in a year with what each brings to it. A person with no row for the year takes the latest earlier row's
-- share, role, office and state (or an equal share, the head office and its state).
create or replace function private.pit_people_year(p_org uuid, p_year int) returns jsonb
language sql stable security definer set search_path = public, private as $$
  with main as (select l.id, l.state from locations l where l.org_id = p_org order by l.is_main desc, l.created_at limit 1),
  ppl as (
    select pp.*, y.person_id is not null has_row, y as yr,
      (select p2 from pit_person_years p2 where p2.org_id = p_org and p2.person_id = pp.id and p2.accounting_year < p_year order by p2.accounting_year desc limit 1) prev
    from pit_people pp
    left join pit_person_years y on y.org_id = p_org and y.accounting_year = p_year and y.person_id = pp.id
    where pp.org_id = p_org and case when y.person_id is not null then y.included else pp.active end),
  n as (select count(*)::numeric n from ppl)
  select coalesce(jsonb_agg(jsonb_build_object(
      'person_id', x.id, 'name', x.name, 'tin', x.tin, 'member_id', x.member_id, 'source', x.source, 'has_row', x.has_row,
      'share_pct', coalesce((x.yr).share_pct, (x.prev).share_pct, round(100 / nullif((select n from n), 0), 4)),
      'role', coalesce((x.yr).role, (x.prev).role),
      'office_location_id', coalesce((x.yr).office_location_id, (x.prev).office_location_id, (select id from main)),
      'residence', coalesce((x.yr).residence, (x.prev).residence, private.state_code((select state from main))),
      'resident', coalesce((x.yr).resident, (x.prev).resident, true),
      'remuneration', coalesce((x.yr).remuneration, 0), 'remuneration_note', (x.yr).remuneration_note,
      'opening', coalesce((x.yr).opening, '{}'::jsonb), 'reliefs', coalesce((x.yr).reliefs, '{}'::jsonb), 'other_income', coalesce((x.yr).other_income, '[]'::jsonb),
      'status', coalesce((x.yr).status, 'draft'), 'flux_ref', (x.yr).flux_ref, 'flux_status', (x.yr).flux_status, 'flux_message', (x.yr).flux_message,
      'flux_sent_at', (x.yr).flux_sent_at, 'filed_at', (x.yr).filed_at, 'filed_by_business', coalesce((x.yr).filed_by_business, false),
      'acknowledgement_ref', (x.yr).acknowledgement_ref, 'assessment', (x.yr).assessment, 'payment_url', (x.yr).payment_url,
      'in_previous_year', (x.prev).person_id is not null)
    order by x.sort, x.created_at), '[]'::jsonb)
  from ppl x
$$;

-- The state that taxes a person (NTA 2025 Twelfth Schedule): a partner engaged in the business, the state of the office he
-- works from (para 4(a)); a dormant partner, the state he usually lives in (para 4(b)), or the NRS if he does not live in
-- Nigeria (para 4(c), NTAA s.3(1)(a)(iv)); a sole proprietor, the state he lived in on 1 January (para 6).
create or replace function private.pit_authority(p_kind text, p_role text, p_office uuid, p_residence text, p_resident boolean) returns text
language sql stable security definer set search_path = public, private as $$
  select case
    when not coalesce(p_resident, true) then 'NRS'
    when p_kind = 'sole' or p_role = 'dormant' then p_residence
    else coalesce((select private.state_code(l.state) from locations l where l.id = p_office), null) end
$$;

-- The whole year: the business, then each person. p_bf: what the previous year carried forward
-- ({people: {person id: {losses, ca}}, wht_used}); null when the year opens the chain (each person's opening amounts apply).
create or replace function private.pit_compute(p_org uuid, p_year int, p_bf jsonb default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; rbr public.tax_rulebooks; rb jsonb; v_kind text; b jsonb; bf jsonb; ppl jsonb; x jsonb; v_out jsonb := '[]'::jsonb; t jsonb;
  py public.pit_years; v_wht_used_bf numeric; v_wht_avail numeric; v_role text; v_auth text; v_share numeric; v_sum numeric := 0; v_n int;
  v_tax numeric := 0; v_payable numeric := 0; v_wht_used numeric := 0; v_cgt numeric := 0; v_cf jsonb := '{}'::jsonb; v_checks jsonb := '[]'::jsonb;
  v_flags jsonb; v_open text; v_rem numeric := 0; v_lb numeric; v_cb numeric; v_loc record; v_auth_name text; v_lines jsonb; v_flux text[];
  v_new text; v_gone text; v_prev_n int;
begin
  select * into o from orgs where id = p_org;
  select * into py from pit_years where org_id = p_org and accounting_year = p_year;
  rbr := private.pit_rulebook(p_year); rb := rbr.config;
  v_kind := private.income_tax_kind(p_org, p_year);
  v_flux := coalesce(array(select jsonb_array_elements_text(rb->'filing'->'flux_authorities')), '{}');
  b := private.pit_business(p_org, p_year);
  ppl := private.pit_people_year(p_org, p_year);
  v_n := jsonb_array_length(ppl);
  bf := coalesce(p_bf, '{}'::jsonb);
  v_wht_used_bf := coalesce(private.num(bf->>'wht_used'), 0);
  v_wht_avail := greatest(private.v(b->'figures', 'wht_held') - v_wht_used_bf, 0);
  v_cf := coalesce(bf->'people', '{}'::jsonb);

  for x in select value from jsonb_array_elements(ppl) loop
    v_role := case when v_kind = 'sole' then 'proprietor' when coalesce(x->>'role', 'proprietor') = 'proprietor' then 'active' else x->>'role' end;
    v_share := case when v_kind = 'sole' then 100 else coalesce(private.num(x->>'share_pct'), 0) end;
    v_sum := v_sum + v_share;
    -- Brought forward: last year's computation for the person, or the amounts entered for the first year Counta prepares.
    if p_bf is not null and bf->'people' ? (x->>'person_id') then
      v_lb := coalesce(private.num(bf->'people'->(x->>'person_id')->>'losses'), 0); v_cb := coalesce(private.num(bf->'people'->(x->>'person_id')->>'ca'), 0);
    else
      v_lb := coalesce(private.num(x->'opening'->>'losses_bf'), 0); v_cb := coalesce(private.num(x->'opening'->>'ca_bf'), 0);
    end if;
    t := private.pit_person_tax(rb, jsonb_build_object('name', x->>'name', 'sole', v_kind = 'sole', 'share_pct', v_share,
      'assessable', b->'figures'->'assessable', 'remuneration', x->'remuneration', 'ca_year', b->'figures'->'ca_year',
      'gains_net', b->'figures'->'gains_net', 'wht_available', v_wht_avail, 'losses_bf', v_lb, 'ca_bf', v_cb,
      'reliefs', x->'reliefs', 'other_income', x->'other_income'));
    v_auth := private.pit_authority(v_kind, v_role, (x->>'office_location_id')::uuid, x->>'residence', coalesce((x->>'resident')::boolean, true));
    select a.name, a.short_name, a.state into v_loc from tax_authorities a where a.code = v_auth;
    v_out := v_out || jsonb_build_array(x || jsonb_build_object('role', v_role, 'share_pct', v_share, 'authority', v_auth,
      'authority_name', v_loc.name, 'authority_short', v_loc.short_name, 'authority_state', v_loc.state,
      'office', (select jsonb_build_object('id', l.id, 'name', l.name, 'state', l.state, 'address', l.address) from locations l where l.id = (x->>'office_location_id')::uuid),
      'flux', v_auth = any(v_flux), 'computation', t, 'bf', jsonb_build_object('losses', v_lb, 'ca', v_cb, 'from_previous_year', p_bf is not null and bf->'people' ? (x->>'person_id'))));
    v_cf := jsonb_set(v_cf, array[x->>'person_id'], t->'cf');
    v_tax := v_tax + private.v(t->'figures', 'tax');
    v_payable := v_payable + private.v(t->'figures', 'payable');
    v_wht_used := v_wht_used + private.v(t->'figures', 'wht_credit');
    v_cgt := v_cgt + private.v(t->'figures', 'cgt');
    v_rem := v_rem + coalesce(private.num(x->>'remuneration'), 0);
  end loop;

  -- Checks before the year can be approved.
  v_checks := coalesce(b->'checks', '[]'::jsonb);
  if v_kind not in ('sole', 'partnership') then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'not_pit', 'severity', 'block', 'text',
      case when v_kind = 'company' then 'The business is a company: it files companies income tax, not personal income tax.'
           else 'The business is exempt from income tax unless it carries on a trade or business (NTA 2025 s.162(1)(a)(iii)).' end));
  end if;
  if v_n = 0 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'no_people', 'severity', 'block',
      'text', 'Add the owner of the business, or its partners, under People.'));
  elsif v_kind = 'partnership' and abs(v_sum - 100) >= 0.005 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'shares_total', 'severity', 'block',
      'text', 'The partners'' shares of the profit add up to ' || trim(to_char(v_sum, 'FM990.####')) || '%, not 100%.'));
  end if;
  if o.legal_form = 'partnership' and v_n = 1 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'lp_partners', 'severity', 'block',
      'text', 'A limited partnership has at least two partners. Add the others under People.'));
  end if;
  select string_agg(p->>'name', ', ') into v_open from jsonb_array_elements(v_out) p where p->>'authority' is null;
  if v_open is not null then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'authority_missing', 'severity', 'block',
      'text', 'Counta cannot tell which state taxes ' || v_open || '. ' || case when v_kind = 'sole' then 'Choose the state the owner lived in on 1 January.'
        else 'Choose the office each active partner works from (with its state in Settings, Branches), or the state a dormant partner lives in.' end));
  end if;
  if py.soa_path is null then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'soa_missing', 'severity', 'block',
      'text', 'Attach the statement of accounts (or use Counta''s financial statements). The state revenue service asks for it with the return (NTAA 2025 s.13(2)(d)).'));
  end if;
  if exists (select 1 from jsonb_array_elements(coalesce(b->'mixed_use', '[]'::jsonb)) l where (l->>'amount')::numeric > 0)
     and not coalesce((py.settings->>'mixed_use_reviewed')::boolean, false) then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'mixed_use_review', 'severity', 'block',
      'text', 'Say under Mixed use which of these expenses are partly private (a car, internet, power, a home that is also the office), or that none are. '
        || 'Only the business share is deductible (PIT rule book s.4).'));
  end if;
  if v_kind = 'partnership' and v_rem > private.v(b->'figures', 'salaries') + 0.5 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'pay_vs_books', 'severity', 'warn',
      'text', 'The pay charged for the partners (' || private.naira(v_rem) || ') is more than the salaries in the accounts (' || private.naira(private.v(b->'figures', 'salaries')) || ').'));
  end if;
  select string_agg(p->>'name', ', ') into v_new from jsonb_array_elements(v_out) p where not coalesce((p->>'in_previous_year')::boolean, false);
  select count(*) into v_prev_n from pit_person_years y where y.org_id = p_org and y.accounting_year = p_year - 1 and y.included;
  select string_agg(pp.name, ', ') into v_gone from pit_person_years y join pit_people pp on pp.id = y.person_id
    where y.org_id = p_org and y.accounting_year = p_year - 1 and y.included
      and not exists (select 1 from jsonb_array_elements(v_out) p where (p->>'person_id')::uuid = y.person_id);
  if v_kind = 'partnership' and v_prev_n > 0 and (v_new is not null or v_gone is not null) then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'partner_change', 'severity', 'warn',
      'text', concat_ws(' ', case when v_new is not null then v_new || ' joined.' end, case when v_gone is not null then v_gone || ' left.' end)
        || ' When a partner joins or leaves during the year, the year splits at that date (First Schedule para 19(2)); Counta treats it as one year. Check the split with your adviser.'));
  end if;
  if exists (select 1 from jsonb_array_elements(v_out) p where p->>'authority' = 'NRS') then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'non_resident', 'severity', 'info',
      'text', 'A partner who does not live in Nigeria files with the NRS (NTAA 2025 s.3(1)(a)(iv)).'));
  end if;
  if rbr.regime = 'PITA' and private.v(b->'figures', 'gains_net') > 0 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'cgt_separate', 'severity', 'info',
      'text', 'Under the old law, gains on disposals go on a separate capital gains tax return at 10%. Each person''s share is shown below the income tax.'));
  end if;
  v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'evidence', 'severity', 'info',
    'text', 'Keep the evidence for every relief and deduction (pension and NHF statements, receipts, the tenancy agreement): the state may ask for it (NTA 2025 s.32).'));
  if rbr.status <> 'approved' then
    select string_agg(k || ' ' || (v->>'title'), ', ' order by k) into v_open from jsonb_each(coalesce(rb->'configurable_flags'->'flags', '{}'::jsonb)) f(k, v)
      where v->>'status' <> 'agreed';
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'rulebook_pending', 'severity', 'warn',
      'text', 'The rules for this year (' || rbr.id || ') are awaiting TaxStreem sign-off' || coalesce(': ' || v_open, '') || '.'));
  end if;

  return jsonb_build_object('year', p_year, 'yoa', p_year + 1, 'from', b->>'from', 'to', b->>'to', 'ended', (b->>'ended')::boolean, 'source', b->>'source',
    'kind', v_kind, 'regime', rbr.regime, 'rulebook', jsonb_build_object('id', rbr.id, 'version', rbr.version, 'status', rbr.status, 'law', rb->'meta'->>'governing_law'),
    'business', b, 'people', v_out, 'checks', v_checks, 'due', private.pit_due(p_org, p_year), 'flux_authorities', to_jsonb(v_flux),
    'figures', jsonb_build_object('assessable', b->'figures'->'assessable', 'tax', v_tax, 'payable', v_payable, 'wht_held', b->'figures'->'wht_held',
      'wht_available', v_wht_avail, 'wht_credit_used', v_wht_used, 'cgt', v_cgt, 'people', v_n, 'shares_total', v_sum),
    'bf', jsonb_build_object('wht_used', v_wht_used_bf, 'from_previous_year', p_bf is not null),
    'cf', jsonb_build_object('people', v_cf, 'wht_used', round(v_wht_used_bf + v_wht_used, 2)),
    'status', coalesce(py.status, 'draft'));
end $$;

-- The chain of years from the first one Counta prepares: each passes losses, unused allowances and the WHT credit notes it
-- used to the next. An approved year passes what it was approved with.
create or replace function private.pit_chain(p_org uuid, p_upto int) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare y int; y0 int := least(private.pit_first_year(p_org), p_upto); bf jsonb := null; comp jsonb; py public.pit_years; v jsonb := '[]'::jsonb; v_has boolean;
begin
  for y in y0 .. p_upto loop
    select * into py from pit_years where org_id = p_org and accounting_year = y;
    v_has := private.cit_has_data(p_org, y);
    if not v_has and py.accounting_year is null and y < p_upto then
      v := v || jsonb_build_array(jsonb_build_object('year', y, 'yoa', y + 1, 'has_data', false));
      bf := null; continue;
    end if;
    if py.snapshot is not null and py.status = 'approved' then comp := py.snapshot->'computation';
    else comp := private.pit_compute(p_org, y, bf); end if;
    v := v || jsonb_build_array(comp || jsonb_build_object('has_data', v_has));
    bf := case when v_has or py.status = 'filed_outside' then comp->'cf' end;
  end loop;
  return v;
end $$;

create or replace function private.pit_run(p_org uuid, p_year int) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select c from jsonb_array_elements(private.pit_chain(p_org, p_year)) c where (c->>'year')::int = p_year
$$;

-- ---------------------------------------------------------------------------
-- What the screens, the files and Flux read and write
-- ---------------------------------------------------------------------------
-- Who may see what. Everyone with File tax (the owner always) sees every person's return; those who keep the books or see
-- the money see the business's side and each person's share of it; a person linked to a team member sees their own return.
create or replace function private.pit_access(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_all boolean; v_money boolean; v_me uuid;
begin
  m := private.require(p_org, null);
  v_all := private.perm_of(m, 'file_tax');
  v_money := private.can_handle_money(p_org);
  select id into v_me from pit_people where org_id = p_org and member_id = m.id;
  if not (v_all or v_money or v_me is not null) then
    raise exception 'Income tax returns need File tax, or Keep the books, See margins or Make payments.' using errcode = '42501';
  end if;
  return jsonb_build_object('member_id', m.id, 'name', m.display_name, 'all', v_all, 'money', v_money, 'books', private.perm_of(m, 'keep_books'),
    'me', v_me, 'owner', m.role = 'owner');
end $$;

-- A person's own figures (reliefs, other income, tax) are left out for those who may not see them.
create or replace function private.pit_mask(p_comp jsonb, p_acc jsonb) returns jsonb
language sql stable set search_path = public, private as $$
  select case when coalesce((p_acc->>'all')::boolean, false) or p_comp is null or p_comp->'people' is null then p_comp
  else p_comp || jsonb_build_object(
    'people', (select coalesce(jsonb_agg(case when p->>'person_id' = p_acc->>'me' then p
        else (p - 'reliefs' - 'other_income' - 'opening' - 'assessment' - 'payment_url' - 'bf') || jsonb_build_object('hidden', true,
          'computation', jsonb_build_object('rows', (select coalesce(jsonb_agg(r), '[]'::jsonb) from jsonb_array_elements(p->'computation'->'rows') r where r->>'id' in ('S1', 'S2', 'S3')),
            'figures', jsonb_build_object('share_pct', p->'computation'->'figures'->'share_pct', 'share_profit', p->'computation'->'figures'->'share_profit',
              'remuneration', p->'computation'->'figures'->'remuneration', 'business_income', p->'computation'->'figures'->'business_income'))) end), '[]'::jsonb)
      from jsonb_array_elements(p_comp->'people') p),
    'figures', (p_comp->'figures') - 'tax' - 'payable' - 'cgt' - 'wht_credit_used',
    'cf', null) end
$$;

-- Why a year cannot be changed.
create or replace function private.pit_locked(p_year int, p_status text) returns text
language sql immutable set search_path = '' as $$
  select case p_status when 'filed_outside' then 'The ' || p_year || ' return is marked as filed outside Counta. Undo that to change it.'
    else 'The ' || p_year || ' return is approved. Reopen it to change it.' end
$$;

-- Where a year stands: draft, approved, with Flux (sent), sent back (rejected), filed (every person's return), or filed
-- outside Counta.
create or replace function private.pit_state(p_org uuid, p_year int) returns text
language sql stable security definer set search_path = public, private as $$
  select case
    when z.s = 'filed_outside' then 'filed_outside'
    when z.s = 'approved' then case
      when exists (select 1 from pit_person_years y where y.org_id = p_org and y.accounting_year = p_year and y.included and y.status = 'rejected') then 'rejected'
      when not exists (select 1 from pit_person_years y where y.org_id = p_org and y.accounting_year = p_year and y.included and y.status <> 'filed') then 'filed'
      when exists (select 1 from pit_person_years y where y.org_id = p_org and y.accounting_year = p_year and y.included and y.status in ('sent', 'filed')) then 'sent'
      else 'approved' end
    else 'draft' end
  from (select (select py.status from pit_years py where py.org_id = p_org and py.accounting_year = p_year) s) z
$$;

-- Is there nothing left to file for the year?
create or replace function private.pit_year_done(p_org uuid, p_year int) returns boolean
language sql stable security definer set search_path = public, private as $$
  select private.pit_state(p_org, p_year) in ('filed', 'filed_outside')
    or (private.pit_state(p_org, p_year) = 'sent' and not exists (select 1 from pit_person_years y where y.org_id = p_org and y.accounting_year = p_year
          and y.included and y.status in ('approved', 'rejected')))
$$;

-- The years: 2025 accounts (or the first year of the books) to the year running now.
create or replace function public.pit_years(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare acc jsonb; v_now int := private.cit_year_of(p_org, private.local_day(p_org, now())); v_kind text; ch jsonb; v_all boolean;
begin
  acc := private.pit_access(p_org);
  v_all := (acc->>'all')::boolean;
  v_kind := private.income_tax_kind(p_org, v_now);
  if v_kind not in ('sole', 'partnership') or v_now < 2025 then
    return jsonb_build_object('kind', v_kind, 'years', '[]'::jsonb, 'current_year', v_now, 'first_year', private.pit_first_year(p_org));
  end if;
  ch := private.pit_chain(p_org, v_now);
  return jsonb_build_object('kind', v_kind, 'current_year', v_now, 'first_year', private.pit_first_year(p_org),
    'years', (select coalesce(jsonb_agg(jsonb_build_object('year', (c->>'year')::int, 'yoa', (c->>'yoa')::int, 'from', c->>'from', 'to', c->>'to',
        'regime', c->>'regime', 'kind', c->>'kind', 'has_data', coalesce((c->>'has_data')::boolean, false), 'ended', (c->>'ended')::boolean,
        'state', private.pit_state(p_org, (c->>'year')::int), 'due', c->>'due', 'people', (c->'figures'->>'people')::int,
        'tax', case when v_all then (c->'figures'->>'tax')::numeric end, 'payable', case when v_all then (c->'figures'->>'payable')::numeric end,
        'assessable', (c->'figures'->>'assessable')::numeric,
        'blocks', (select count(*) from jsonb_array_elements(coalesce(c->'checks', '[]'::jsonb)) k where k->>'severity' = 'block'))
      order by (c->>'year')::int desc), '[]'::jsonb) from jsonb_array_elements(ch) c where c ? 'people' or not coalesce((c->>'has_data')::boolean, true)));
end $$;

-- An approved year's people with where each return stands now (the snapshot keeps the figures; Flux and the business move
-- the statuses on).
create or replace function private.pit_live(p_org uuid, p_year int, p_comp jsonb) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select case when p_comp is null or p_comp->'people' is null then p_comp else p_comp || jsonb_build_object('people',
    (select coalesce(jsonb_agg(case when y.person_id is null then x else x || jsonb_build_object('status', y.status, 'flux_ref', y.flux_ref, 'flux_status', y.flux_status,
        'flux_message', y.flux_message, 'flux_sent_at', y.flux_sent_at, 'filed_at', y.filed_at, 'filed_by_business', y.filed_by_business,
        'acknowledgement_ref', y.acknowledgement_ref, 'assessment', y.assessment, 'payment_url', y.payment_url) end order by o.n), '[]'::jsonb)
     from jsonb_array_elements(p_comp->'people') with ordinality o(x, n)
     left join pit_person_years y on y.org_id = p_org and y.accounting_year = p_year and y.person_id = (o.x->>'person_id')::uuid)) end
$$;

-- One year, for its screens.
create or replace function public.pit_year(p_org uuid, p_year int) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare acc jsonb; py public.pit_years; comp jsonb; v_cit jsonb; v_draft boolean; v_all boolean; v_books boolean; p record;
begin
  acc := private.pit_access(p_org);
  if p_year < 2025 or p_year > 2100 then raise exception 'Counta prepares personal income tax from 2025 accounts.'; end if;
  v_all := (acc->>'all')::boolean;
  v_books := (acc->>'books')::boolean or v_all;
  select * into py from pit_years where org_id = p_org and accounting_year = p_year;
  v_draft := coalesce(py.status, 'draft') = 'draft';
  select pfrom, pto into p from private.cit_period(p_org, p_year);
  comp := private.pit_live(p_org, p_year, private.pit_run(p_org, p_year));
  if private.can_handle_money(p_org) then
    v_cit := public.cit_year(p_org, p_year);
    v_cit := v_cit || jsonb_build_object('can_edit', coalesce((v_cit->>'can_edit')::boolean, false) and v_draft);
  end if;
  return jsonb_build_object('kind', private.income_tax_kind(p_org, p_year), 'computation', private.pit_mask(comp, acc), 'state', private.pit_state(p_org, p_year),
    'row', jsonb_build_object('status', coalesce(py.status, 'draft'), 'settings', coalesce(py.settings, '{}'::jsonb), 'soa_path', py.soa_path,
      'approved_at', py.approved_at, 'approved_by', (select display_name from members where id = py.approved_by), 'attested', py.snapshot->'attested',
      'updated_at', py.updated_at),
    'cit', v_cit,
    'people_all', (select coalesce(jsonb_agg(jsonb_build_object('id', pp.id, 'name', pp.name, 'tin', pp.tin, 'member_id', pp.member_id, 'active', pp.active,
        'source', pp.source) order by pp.sort, pp.created_at), '[]'::jsonb) from pit_people pp where pp.org_id = p_org),
    'members', case when v_all then (select coalesce(jsonb_agg(jsonb_build_object('id', mm.id, 'name', mm.display_name, 'role', mm.role) order by mm.display_name), '[]'::jsonb)
        from members mm where mm.org_id = p_org and mm.status = 'active' and mm.practice_id is null) end,
    'locations', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'state', l.state, 'authority', private.state_code(l.state), 'is_main', l.is_main)
        order by l.is_main desc, l.name), '[]'::jsonb) from locations l where l.org_id = p_org),
    'authorities', (select jsonb_agg(jsonb_build_object('code', a.code, 'state', a.state, 'name', a.name, 'short_name', a.short_name) order by a.sort) from tax_authorities a),
    'needs_setup', not exists (select 1 from pit_people where org_id = p_org),
    'suggested', case when not exists (select 1 from pit_people where org_id = p_org) then
        coalesce((select jsonb_agg(d->>'name') from orgs o, jsonb_array_elements(case when jsonb_typeof(o.directors) = 'array' then o.directors else '[]'::jsonb end) d
                  where o.id = p_org and coalesce(d->>'name', '') <> ''), '[]'::jsonb) end,
    'can', jsonb_build_object('see_all', v_all, 'edit_business', v_books and v_draft, 'edit_people', v_all and v_draft,
      'edit_self', acc->>'me' is not null and v_draft, 'approve', v_all, 'owner', (acc->>'owner')::boolean),
    'me', acc->'me', 'period', jsonb_build_object('from', p.pfrom, 'to', p.pto));
end $$;

-- The first time Income tax is opened: the people on the CAC record (or the owner) become the business's people.
create or replace function public.pit_setup(p_org uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_n int := 0; d jsonb; ow public.members;
begin
  m := private.require(p_org, 'file_tax');
  if exists (select 1 from pit_people where org_id = p_org) then return jsonb_build_object('added', 0); end if;
  for d in select x from orgs o, jsonb_array_elements(case when jsonb_typeof(o.directors) = 'array' then o.directors else '[]'::jsonb end) x
           where o.id = p_org and length(trim(coalesce(x->>'name', ''))) >= 2 loop
    insert into pit_people (org_id, name, source, sort, created_by) values (p_org, left(initcap(lower(trim(d->>'name'))), 120), 'cac', 100 + v_n, m.id);
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then
    select * into ow from members where org_id = p_org and role = 'owner' and status = 'active' order by created_at limit 1;
    insert into pit_people (org_id, name, member_id, source, created_by) values (p_org, left(coalesce(nullif(trim(ow.display_name), ''), 'The owner'), 120), ow.id, 'owner', m.id);
    v_n := 1;
  end if;
  return jsonb_build_object('added', v_n);
end $$;

-- Add, rename, link or remove a person. p: {id, name, tin, member_id, active, sort, delete}.
create or replace function public.save_pit_person(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; pp public.pit_people; v_id uuid := nullif(p->>'id', '')::uuid; v_tin text;
begin
  m := private.require(p_org, 'file_tax');
  if v_id is not null then
    select * into pp from pit_people where id = v_id and org_id = p_org for update;
    if not found then raise exception 'That person is not in this business.'; end if;
  end if;
  if coalesce((p->>'delete')::boolean, false) then
    if exists (select 1 from pit_person_years y where y.person_id = v_id and y.status <> 'draft') then
      update pit_people set active = false, updated_at = now() where id = v_id;
      return jsonb_build_object('id', v_id, 'removed', false, 'inactive', true);
    end if;
    delete from pit_people where id = v_id;
    return jsonb_build_object('id', v_id, 'removed', true);
  end if;
  if p ? 'name' and length(trim(coalesce(p->>'name', ''))) < 2 then raise exception 'Enter the person''s name.'; end if;
  v_tin := nullif(regexp_replace(coalesce(p->>'tin', ''), '\s', '', 'g'), '');
  if p ? 'tin' and v_tin is not null and v_tin !~ '^[0-9][0-9-]{6,15}$' then raise exception 'A Tax ID is digits (with dashes, if any).'; end if;
  if nullif(p->>'member_id', '') is not null and not exists (select 1 from members where id = (p->>'member_id')::uuid and org_id = p_org) then
    raise exception 'Link the person to someone on the team.';
  end if;
  if nullif(p->>'member_id', '') is not null and exists (select 1 from pit_people where org_id = p_org and member_id = (p->>'member_id')::uuid and id is distinct from v_id) then
    raise exception 'That team member is already linked to another person.';
  end if;
  if v_id is null then
    if length(trim(coalesce(p->>'name', ''))) < 2 then raise exception 'Enter the person''s name.'; end if;
    insert into pit_people (org_id, name, tin, member_id, source, sort, created_by)
    values (p_org, left(trim(p->>'name'), 120), v_tin, nullif(p->>'member_id', '')::uuid, 'added',
      coalesce(private.num(p->>'sort')::int, (select coalesce(max(sort), 99) + 1 from pit_people where org_id = p_org)), m.id)
    returning * into pp;
  else
    update pit_people set name = case when p ? 'name' then left(trim(p->>'name'), 120) else name end,
      tin = case when p ? 'tin' then v_tin else tin end,
      member_id = case when p ? 'member_id' then nullif(p->>'member_id', '')::uuid else member_id end,
      active = coalesce((p->>'active')::boolean, active), sort = coalesce(private.num(p->>'sort')::int, sort), updated_at = now()
    where id = v_id returning * into pp;
  end if;
  return to_jsonb(pp);
end $$;

-- What a person brings to a year. Partners' shares, roles, offices and pay are set by those who file tax; a person linked
-- to a team member may enter their own state, reliefs, other income and amounts brought forward.
-- p: {share_pct, role, office_location_id, residence, resident, remuneration, remuneration_note, included,
--     opening: {losses_bf, ca_bf}, reliefs: {pension, nhf, nhis, life_insurance, home_loan_interest, gratuity, rent_paid},
--     other_income: [{kind, label, amount, tax_deducted, final_tax}]}
create or replace function public.save_pit_person_year(p_org uuid, p_year int, p_person uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare acc jsonb; m public.members; py public.pit_years; d jsonb; k text; v_kinds text[]; x jsonb; v_oi jsonb := '[]'::jsonb; v_rl jsonb := '{}'::jsonb; v_n numeric;
  v_self_keys text[] := array['residence', 'resident', 'reliefs', 'other_income', 'opening'];
begin
  acc := private.pit_access(p_org);
  m := private.require(p_org, null);
  if p_year < 2025 or p_year > 2100 then raise exception 'Choose the year.'; end if;
  if not exists (select 1 from pit_people where id = p_person and org_id = p_org) then raise exception 'That person is not in this business.'; end if;
  if not (acc->>'all')::boolean then
    if acc->>'me' is distinct from p_person::text then raise exception 'Only those who file tax change another person''s return.' using errcode = '42501'; end if;
    for k in select jsonb_object_keys(p) loop
      if not k = any(v_self_keys) then raise exception 'Your share, role, office and pay are set by whoever files the business''s tax.' using errcode = '42501'; end if;
    end loop;
  end if;
  for k in select jsonb_object_keys(p) loop
    if not k = any(array['share_pct', 'role', 'office_location_id', 'residence', 'resident', 'remuneration', 'remuneration_note', 'included', 'opening', 'reliefs', 'other_income']) then
      raise exception 'Unknown field %.', k;
    end if;
  end loop;
  select * into py from pit_years where org_id = p_org and accounting_year = p_year;
  if coalesce(py.status, 'draft') <> 'draft' then raise exception '%', private.pit_locked(p_year, py.status); end if;

  -- Validate.
  if p ? 'share_pct' and (private.num(p->>'share_pct') is null or private.num(p->>'share_pct') < 0 or private.num(p->>'share_pct') > 100) then
    raise exception 'A share of the profit is between 0%% and 100%%.';
  end if;
  if p ? 'role' and p->>'role' not in ('proprietor', 'active', 'dormant') then raise exception 'Choose whether the partner works in the business or is dormant.'; end if;
  if nullif(p->>'office_location_id', '') is not null and not exists (select 1 from locations where id = (p->>'office_location_id')::uuid and org_id = p_org) then
    raise exception 'Choose one of the business''s offices.';
  end if;
  if nullif(p->>'residence', '') is not null and not exists (select 1 from tax_authorities where code = p->>'residence' and kind = 'state') then
    raise exception 'Choose the state.';
  end if;
  if p ? 'remuneration' and (private.num(p->>'remuneration') is null or private.num(p->>'remuneration') < 0) then raise exception 'Enter the pay as an amount of zero or more.'; end if;
  if p ? 'reliefs' then
    if jsonb_typeof(p->'reliefs') <> 'object' then raise exception 'Reliefs are {pension, nhf, ...}.'; end if;
    for k in select jsonb_object_keys(p->'reliefs') loop
      if not k = any(array['pension', 'nhf', 'nhis', 'life_insurance', 'home_loan_interest', 'gratuity', 'rent_paid']) then raise exception 'Unknown relief %.', k; end if;
      continue when jsonb_typeof(p->'reliefs'->k) = 'null' or coalesce(p->'reliefs'->>k, '') = '';
      v_n := private.num(p->'reliefs'->>k);
      if v_n is null or v_n < 0 then raise exception 'Enter % as an amount of zero or more.', replace(k, '_', ' '); end if;
      if v_n > 0 then v_rl := jsonb_set(v_rl, array[k], to_jsonb(round(v_n, 2))); end if;
    end loop;
  end if;
  if p ? 'other_income' then
    if jsonb_typeof(p->'other_income') <> 'array' then raise exception 'Other income is a list.'; end if;
    v_kinds := array(select jsonb_array_elements_text((private.pit_rulebook(p_year)).config->'other_income'->'kinds'));
    for x in select value from jsonb_array_elements(p->'other_income') loop
      continue when coalesce(private.num(x->>'amount'), 0) = 0 and coalesce(trim(x->>'label'), '') = '';
      if not coalesce(x->>'kind', '') = any(v_kinds) then raise exception 'Choose what kind of income "%" is.', coalesce(nullif(trim(x->>'label'), ''), x->>'kind', 'this line'); end if;
      if private.num(x->>'amount') is null or private.num(x->>'amount') <= 0 then raise exception 'Enter the amount of "%".', coalesce(nullif(x->>'label', ''), x->>'kind'); end if;
      if coalesce(private.num(x->>'tax_deducted'), 0) < 0 or coalesce(private.num(x->>'tax_deducted'), 0) > private.num(x->>'amount') then
        raise exception 'The tax deducted from "%" is more than the income.', coalesce(nullif(x->>'label', ''), x->>'kind');
      end if;
      v_oi := v_oi || jsonb_build_array(jsonb_build_object('kind', x->>'kind', 'label', left(coalesce(nullif(trim(x->>'label'), ''), initcap(replace(x->>'kind', '_', ' '))), 120),
        'amount', round(private.num(x->>'amount'), 2), 'tax_deducted', round(coalesce(private.num(x->>'tax_deducted'), 0), 2))
        || case when x ? 'final_tax' and jsonb_typeof(x->'final_tax') = 'boolean' then jsonb_build_object('final_tax', (x->>'final_tax')::boolean) else '{}'::jsonb end);
    end loop;
    if jsonb_array_length(v_oi) > 40 then raise exception 'At most 40 lines of other income.'; end if;
  end if;
  if p ? 'opening' and (jsonb_typeof(p->'opening') <> 'object' or coalesce(private.num(p->'opening'->>'losses_bf'), 0) < 0 or coalesce(private.num(p->'opening'->>'ca_bf'), 0) < 0) then
    raise exception 'Amounts brought forward are zero or more.';
  end if;

  -- The person's row for the year starts from what the year already gives them.
  select x2 into d from jsonb_array_elements(private.pit_people_year(p_org, p_year)) x2 where (x2->>'person_id')::uuid = p_person;
  insert into pit_years (org_id, accounting_year, updated_by) values (p_org, p_year, m.id) on conflict (org_id, accounting_year) do nothing;
  insert into pit_person_years (org_id, accounting_year, person_id, share_pct, role, office_location_id, residence, resident, updated_by)
  values (p_org, p_year, p_person, private.num(d->>'share_pct'), d->>'role', nullif(d->>'office_location_id', '')::uuid, nullif(d->>'residence', ''),
    coalesce((d->>'resident')::boolean, true), m.id)
  on conflict (org_id, accounting_year, person_id) do nothing;
  update pit_person_years set
    share_pct = case when p ? 'share_pct' then round(private.num(p->>'share_pct'), 4) else share_pct end,
    role = case when p ? 'role' then p->>'role' else role end,
    office_location_id = case when p ? 'office_location_id' then nullif(p->>'office_location_id', '')::uuid else office_location_id end,
    residence = case when p ? 'residence' then nullif(p->>'residence', '') else residence end,
    resident = case when p ? 'resident' then coalesce((p->>'resident')::boolean, true) else resident end,
    remuneration = case when p ? 'remuneration' then round(private.num(p->>'remuneration'), 2) else remuneration end,
    remuneration_note = case when p ? 'remuneration_note' then nullif(left(trim(p->>'remuneration_note'), 300), '') else remuneration_note end,
    included = case when p ? 'included' then coalesce((p->>'included')::boolean, true) else included end,
    opening = case when p ? 'opening' then jsonb_strip_nulls(jsonb_build_object('losses_bf', round(nullif(private.num(p->'opening'->>'losses_bf'), 0), 2),
      'ca_bf', round(nullif(private.num(p->'opening'->>'ca_bf'), 0), 2))) else opening end,
    reliefs = case when p ? 'reliefs' then v_rl else reliefs end,
    other_income = case when p ? 'other_income' then v_oi else other_income end,
    updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year and person_id = p_person;
  update pit_years set updated_by = m.id, updated_at = now() where org_id = p_org and accounting_year = p_year;
  return public.pit_year(p_org, p_year);
end $$;

-- The business's side of the year. p: {mixed_use: {template cell: business share % | null}, mixed_use_reviewed, soa_path, notes}.
create or replace function public.save_pit_year(p_org uuid, p_year int, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare acc jsonb; m public.members; py public.pit_years; v_set jsonb; x record; v_cells text[]; v_n numeric;
begin
  acc := private.pit_access(p_org);
  m := private.require(p_org, null);
  if not ((acc->>'all')::boolean or (acc->>'books')::boolean) then raise exception 'Your role does not allow this (keep books).' using errcode = '42501'; end if;
  if p_year < 2025 or p_year > 2100 then raise exception 'Choose the year.'; end if;
  insert into pit_years (org_id, accounting_year, updated_by) values (p_org, p_year, m.id) on conflict (org_id, accounting_year) do nothing;
  select * into py from pit_years where org_id = p_org and accounting_year = p_year for update;
  if coalesce(py.status, 'draft') <> 'draft' then raise exception '%', private.pit_locked(p_year, py.status); end if;
  v_set := coalesce(py.settings, '{}'::jsonb);
  for x in select key, value from jsonb_each(p) loop
    if x.key not in ('mixed_use', 'mixed_use_reviewed', 'soa_path', 'notes') then raise exception 'Unknown setting %.', x.key; end if;
  end loop;
  if p ? 'mixed_use' then
    if jsonb_typeof(p->'mixed_use') <> 'object' then raise exception 'Mixed use is {line: business share %%}.'; end if;
    v_cells := array(select l->>'cell' from jsonb_array_elements((private.pit_rulebook(p_year)).config->'business'->'mixed_use'->'lines') l);
    for x in select key, value from jsonb_each(p->'mixed_use') loop
      if not x.key = any(v_cells) then raise exception 'That line is not one the rule book treats as mixed use.'; end if;
      if jsonb_typeof(x.value) = 'null' then v_set := jsonb_set(v_set, '{mixed_use}', coalesce(v_set->'mixed_use', '{}'::jsonb) - x.key); continue; end if;
      v_n := private.num(x.value #>> '{}');
      if v_n is null or v_n < 0 or v_n > 100 then raise exception 'The business share of a mixed-use expense is between 0%% and 100%%.'; end if;
      v_set := jsonb_set(v_set, '{mixed_use}', coalesce(v_set->'mixed_use', '{}'::jsonb) || jsonb_build_object(x.key, round(v_n, 2)));
    end loop;
    v_set := v_set || jsonb_build_object('mixed_use_reviewed', true, 'mixed_use_by', m.display_name, 'mixed_use_at', now());
  end if;
  if p ? 'mixed_use_reviewed' then v_set := v_set || jsonb_build_object('mixed_use_reviewed', coalesce((p->>'mixed_use_reviewed')::boolean, false)); end if;
  if p ? 'notes' then v_set := case when coalesce(trim(p->>'notes'), '') = '' then v_set - 'notes' else v_set || jsonb_build_object('notes', left(trim(p->>'notes'), 2000)) end; end if;
  if p ? 'soa_path' then
    if nullif(p->>'soa_path', '') is not null and split_part(p->>'soa_path', '/', 1) <> p_org::text then raise exception 'That file is not this business''s.'; end if;
  end if;
  update pit_years set settings = v_set, soa_path = case when p ? 'soa_path' then nullif(p->>'soa_path', '') else soa_path end,
    updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year;
  return public.pit_year(p_org, p_year);
end $$;

-- Approving freezes the year. The person approving attests the statement of accounts (NTAA 2025 s.13(2)(d)).
create or replace function public.approve_pit_year(p_org uuid, p_year int, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; py public.pit_years; comp jsonb; v_blocks text; x jsonb; v_statement text;
begin
  m := private.require(p_org, 'file_tax');
  insert into pit_years (org_id, accounting_year, updated_by) values (p_org, p_year, m.id) on conflict (org_id, accounting_year) do nothing;
  select * into py from pit_years where org_id = p_org and accounting_year = p_year for update;
  if py.status <> 'draft' then raise exception 'The % return is already %.', p_year, replace(py.status, '_', ' '); end if;
  if not coalesce((p->>'attest')::boolean, false) then raise exception 'Confirm the statement of accounts before approving.'; end if;
  comp := private.pit_run(p_org, p_year);
  select string_agg(k->>'text', ' ') into v_blocks from jsonb_array_elements(comp->'checks') k where k->>'severity' = 'block';
  if v_blocks is not null then raise exception 'Not ready: %', v_blocks; end if;
  v_statement := 'I confirm that the statement of accounts for ' || coalesce((select name from orgs where id = p_org), 'the business') || ' for the year ended '
    || private.fdate((comp->>'to')::date) || ' is a true and correct account of its income and expenses, and that the people, shares and reliefs in this return are as stated.';
  for x in select value from jsonb_array_elements(comp->'people') loop
    insert into pit_person_years (org_id, accounting_year, person_id, share_pct, role, office_location_id, residence, resident, remuneration, reliefs, other_income, opening, status, updated_by)
    values (p_org, p_year, (x->>'person_id')::uuid, private.num(x->>'share_pct'), x->>'role', nullif(x->>'office_location_id', '')::uuid, nullif(x->>'residence', ''),
      coalesce((x->>'resident')::boolean, true), coalesce(private.num(x->>'remuneration'), 0), coalesce(x->'reliefs', '{}'::jsonb), coalesce(x->'other_income', '[]'::jsonb),
      coalesce(x->'opening', '{}'::jsonb), 'approved', m.id)
    on conflict (org_id, accounting_year, person_id) do update set share_pct = excluded.share_pct, role = excluded.role, status = 'approved',
      flux_status = null, flux_message = null, updated_by = m.id, updated_at = now();
  end loop;
  update pit_years set status = 'approved', approved_by = m.id, approved_at = now(), rulebook_id = comp->'rulebook'->>'id',
    snapshot = jsonb_build_object('computation', comp,
      'org', (select jsonb_build_object('name', name, 'tin', tin, 'rc_number', rc_number, 'address', coalesce(registered_office, address), 'taxstreem_org_id', taxstreem_org_id,
        'legal_form', legal_form) from orgs where id = p_org),
      'attested', jsonb_build_object('by', m.display_name, 'at', now(), 'statement', v_statement),
      'approved_by', m.display_name, 'approved_at', now()),
    updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year;
  return public.pit_year(p_org, p_year);
end $$;

create or replace function public.reopen_pit_year(p_org uuid, p_year int, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; py public.pit_years;
begin
  m := private.require(p_org, 'file_tax');
  select * into py from pit_years where org_id = p_org and accounting_year = p_year for update;
  if not found or py.status <> 'approved' then raise exception 'Only an approved return can be reopened.'; end if;
  if exists (select 1 from pit_person_years where org_id = p_org and accounting_year = p_year and status in ('sent', 'filed')) then
    raise exception 'A return in this year is with Flux or filed. File an amended return with the state instead.';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Say why the return is reopened.'; end if;
  update pit_years set status = 'draft', snapshot = null, approved_by = null, approved_at = null,
    settings = settings || jsonb_build_object('reopened', jsonb_build_object('by', m.display_name, 'at', now(), 'reason', left(trim(p_reason), 300))),
    updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year;
  update pit_person_years set status = 'draft', flux_ref = null, flux_status = null, flux_message = null, flux_sent_at = null, updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year;
  return public.pit_year(p_org, p_year);
end $$;

-- A return the business filed itself: one person's (after approval, for a state Flux does not cover), or the whole year
-- filed before or outside Counta. p: {person_id, acknowledgement_ref, filed_on} | {outside: true, note} | {outside: false}.
create or replace function public.mark_pit_filed(p_org uuid, p_year int, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; py public.pit_years; y public.pit_person_years; v_on date;
begin
  m := private.require(p_org, 'file_tax');
  insert into pit_years (org_id, accounting_year, updated_by) values (p_org, p_year, m.id) on conflict (org_id, accounting_year) do nothing;
  select * into py from pit_years where org_id = p_org and accounting_year = p_year for update;
  v_on := coalesce(nullif(p->>'filed_on', '')::date, private.local_day(p_org, now()));
  if v_on > private.local_day(p_org, now()) then raise exception 'A return cannot be filed in the future.'; end if;
  if p ? 'outside' then
    if coalesce((p->>'outside')::boolean, false) then
      if py.status <> 'draft' then raise exception 'The % return is %.', p_year, replace(py.status, '_', ' '); end if;
      update pit_years set status = 'filed_outside', settings = settings || jsonb_build_object('filed_outside', jsonb_build_object('by', m.display_name, 'at', now(),
        'on', v_on, 'note', nullif(left(trim(coalesce(p->>'note', '')), 300), ''))), updated_by = m.id, updated_at = now()
      where org_id = p_org and accounting_year = p_year;
    else
      if py.status <> 'filed_outside' then raise exception 'The year was not marked as filed outside Counta.'; end if;
      update pit_years set status = 'draft', settings = settings - 'filed_outside', updated_by = m.id, updated_at = now() where org_id = p_org and accounting_year = p_year;
    end if;
    return public.pit_year(p_org, p_year);
  end if;
  if py.status <> 'approved' then raise exception 'Approve the % return first.', p_year; end if;
  select * into y from pit_person_years where org_id = p_org and accounting_year = p_year and person_id = nullif(p->>'person_id', '')::uuid for update;
  if not found then raise exception 'Choose the person.'; end if;
  if y.status not in ('approved', 'rejected') then raise exception 'That return is %.', y.status; end if;
  if length(trim(coalesce(p->>'acknowledgement_ref', ''))) < 3 then raise exception 'Enter the acknowledgement or assessment number the state gave.'; end if;
  update pit_person_years set status = 'filed', filed_by_business = true, filed_at = v_on::timestamptz, acknowledgement_ref = left(trim(p->>'acknowledgement_ref'), 80),
    flux_message = null, updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year and person_id = y.person_id;
  return public.pit_year(p_org, p_year);
end $$;

-- An NGO's standing for income tax, set by the owner: whether CAC registered it as a company limited by guarantee, and
-- whether it carries on a trade or business (whose profit is taxable).
create or replace function public.save_income_tax_setup(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_prof jsonb; k text;
begin
  m := private.require(p_org, null);
  if m.role <> 'owner' then raise exception 'Only the owner changes how the business is taxed.' using errcode = '42501'; end if;
  select coalesce(cit_profile, '{}'::jsonb) into v_prof from orgs where id = p_org;
  for k in select jsonb_object_keys(p) loop
    if k not in ('limited_by_guarantee', 'ngo_trades') then raise exception 'Unknown setting %.', k; end if;
    -- Kept as an explicit true or false: "not an NGO" must outlast the next read of the CAC record (kyc_guarantee_mark).
    v_prof := v_prof || jsonb_build_object(k, coalesce((p->>k)::boolean, false));
  end loop;
  update orgs set cit_profile = v_prof where id = p_org;
  return jsonb_build_object('kind', private.income_tax_kind(p_org), 'cit_profile', v_prof);
end $$;

-- For the tax-files function, asked as the person: the approved year and each person's return, for Flux.
create or replace function public.pit_pack(p_org uuid, p_year int) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; py public.pit_years; comp jsonb;
begin
  m := private.require(p_org, 'file_tax');
  select * into py from pit_years where org_id = p_org and accounting_year = p_year;
  if not found or py.status <> 'approved' or py.snapshot is null then raise exception 'Approve the % return before sending it.', p_year; end if;
  comp := py.snapshot->'computation';
  return jsonb_build_object('org_id', p_org, 'year', p_year, 'yoa', (comp->>'yoa')::int, 'from', comp->>'from', 'to', comp->>'to', 'regime', comp->>'regime',
    'kind', comp->>'kind', 'due', comp->>'due', 'org', py.snapshot->'org', 'attested', py.snapshot->'attested', 'approved_by', py.snapshot->>'approved_by',
    'approved_at', py.snapshot->>'approved_at', 'soa_path', py.soa_path, 'business', comp->'business'->'rows', 'business_figures', comp->'business'->'figures',
    'flux_authorities', comp->'flux_authorities', 'rulebook', comp->'rulebook',
    'people', (select coalesce(jsonb_agg(x || jsonb_build_object('status', y.status, 'flux_ref', y.flux_ref, 'flux_status', y.flux_status)), '[]'::jsonb)
      from jsonb_array_elements(comp->'people') x
      left join pit_person_years y on y.org_id = p_org and y.accounting_year = p_year and y.person_id = (x->>'person_id')::uuid));
end $$;

-- Flux reporting on one person's return (service role).
create or replace function public.svc_pit_flux_update(p_org uuid, p_year int, p_person uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare py public.pit_years; y public.pit_person_years; v_status text := nullif(p->>'status', ''); v_name text;
begin
  select * into py from pit_years where org_id = p_org and accounting_year = p_year;
  if not found or py.status <> 'approved' then raise exception 'The % return is not approved.', p_year; end if;
  select * into y from pit_person_years where org_id = p_org and accounting_year = p_year and person_id = p_person for update;
  if not found then raise exception 'No such person in the % return.', p_year; end if;
  if v_status is not null and v_status not in ('sent', 'processing', 'filed', 'rejected', 'send_failed') then raise exception 'Unknown status %.', v_status; end if;
  if y.status = 'filed' and v_status in ('sent', 'processing', 'rejected', 'send_failed') then
    return jsonb_build_object('person_id', p_person, 'status', y.status, 'flux_ref', y.flux_ref, 'unchanged', true);
  end if;
  update pit_person_years set
    status = case when v_status in ('sent', 'filed', 'rejected') then v_status else status end,
    flux_ref = coalesce(nullif(p->>'ref', ''), flux_ref),
    flux_status = coalesce(v_status, flux_status),
    flux_message = case when p ? 'message' then left(p->>'message', 1000) else flux_message end,
    flux_sent_at = case when v_status = 'sent' then now() else flux_sent_at end,
    flux_updated_at = now(),
    filed_at = case when v_status = 'filed' then coalesce(nullif(p->>'filed_at', '')::timestamptz, now()) else filed_at end,
    acknowledgement_ref = coalesce(nullif(p->>'acknowledgement_ref', ''), acknowledgement_ref),
    assessment = coalesce(case when jsonb_typeof(p->'assessment') = 'object' then p->'assessment' end, assessment),
    payment_url = coalesce(case when p->>'payment_url' ~ '^https://' then left(p->>'payment_url', 1000) end, payment_url)
  where org_id = p_org and accounting_year = p_year and person_id = p_person
  returning * into y;
  if v_status in ('filed', 'rejected') then
    select name into v_name from pit_people where id = p_person;
    perform private.notify_perm(p_org, 'file_tax', 'books', v_name || '''s ' || p_year || ' income tax return ' || v_status,
      coalesce(nullif(p->>'message', ''), case when v_status = 'filed' then 'Acknowledgement ' || coalesce(p->>'acknowledgement_ref', '') else 'The state did not accept it' end),
      '/tax/pit?year=' || p_year, 'pit-' || p_year || '-' || p_person || '-' || v_status, null);
  end if;
  return jsonb_build_object('person_id', p_person, 'status', y.status, 'flux_ref', y.flux_ref, 'flux_status', y.flux_status, 'year_state', private.pit_state(p_org, p_year));
end $$;

-- ---------------------------------------------------------------------------
-- 5c. Deadlines: companies income tax for companies, personal income tax for business names and partnerships. The count
--     beside the menu ('cit') is for income tax of either kind.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.tax_deadlines(p_org uuid)
 RETURNS TABLE(tax text, label text, period date, due date, amount numeric, url text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare v_kind text; o public.orgs; v_today date := private.local_day(p_org, now()); v_last date; vp public.vat_periods; r record; v_year int; v_from date; v_to date; cy record;
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
  v_kind := private.income_tax_kind(p_org);
  -- CIT (companies, and NGOs that trade): the year that ended most recently, due six months after its end.
  if v_kind = 'company' then
    v_year := extract(year from v_today)::int;
    select pfrom, pto into v_from, v_to from private.cit_period(p_org, v_year);
    if v_to >= v_today then v_year := v_year - 1; select pfrom, pto into v_from, v_to from private.cit_period(p_org, v_year); end if;
    if v_to is not null and coalesce(o.books_start, v_to) <= v_to
       and not exists (select 1 from cit_years where org_id = p_org and accounting_year = v_year and status in ('sent', 'filed')) then
      tax := 'cit'; label := 'Companies income tax return'; period := v_from; due := (v_to + interval '6 months')::date; amount := null; url := '/tax/cit?year=' || v_year;
      return next;
    end if;
  end if;
  -- Personal income tax (business names and partnerships): the year that ended most recently, due 31 March after it,
  -- until every person's return is with Flux or filed. Also for a year before the books start once its accounts are read in
  -- or its return is begun, as for a business that moved to Counta after the year ended.
  if v_kind in ('sole', 'partnership') then
    v_year := extract(year from v_today)::int;
    select pfrom, pto into v_from, v_to from private.cit_period(p_org, v_year);
    if v_to >= v_today then v_year := v_year - 1; select pfrom, pto into v_from, v_to from private.cit_period(p_org, v_year); end if;
    if v_year >= 2025 and v_to is not null and not private.pit_year_done(p_org, v_year)
       and (coalesce(o.books_start, v_to) <= v_to or exists (select 1 from pit_years y where y.org_id = p_org and y.accounting_year = v_year)
            or exists (select 1 from cit_years c where c.org_id = p_org and c.accounting_year = v_year and c.imported <> '{}'::jsonb)) then
      tax := 'pit'; label := 'Personal income tax return'; period := v_from; due := private.pit_due(p_org, v_year); amount := null; url := '/tax/pit?year=' || v_year;
      return next;
    end if;
  end if;
end $function$;

CREATE OR REPLACE FUNCTION public.get_attention(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
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
      if r.tax = 'vat' then v_vat := v_vat + 1; elsif r.tax in ('cit', 'pit') then v_cit := v_cit + 1; else v_wht := v_wht + 1; end if;
    end loop;
    v_cit := case when exists (select 1 from private.tax_deadlines(p_org) t where t.tax in ('cit', 'pit') and t.due <= v_today + 30) then 1 else 0 end;
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
end $function$;

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
revoke execute on function public.pit_years(uuid), public.pit_year(uuid, int), public.pit_setup(uuid), public.save_pit_person(uuid, jsonb),
  public.save_pit_person_year(uuid, int, uuid, jsonb), public.save_pit_year(uuid, int, jsonb), public.approve_pit_year(uuid, int, jsonb),
  public.reopen_pit_year(uuid, int, text), public.mark_pit_filed(uuid, int, jsonb), public.save_income_tax_setup(uuid, jsonb), public.pit_pack(uuid, int)
  from public, anon;
grant execute on function public.pit_years(uuid), public.pit_year(uuid, int), public.pit_setup(uuid), public.save_pit_person(uuid, jsonb),
  public.save_pit_person_year(uuid, int, uuid, jsonb), public.save_pit_year(uuid, int, jsonb), public.approve_pit_year(uuid, int, jsonb),
  public.reopen_pit_year(uuid, int, text), public.mark_pit_filed(uuid, int, jsonb), public.save_income_tax_setup(uuid, jsonb), public.pit_pack(uuid, int)
  to authenticated;
revoke execute on function public.svc_pit_flux_update(uuid, int, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.svc_pit_flux_update(uuid, int, uuid, jsonb) to service_role;
