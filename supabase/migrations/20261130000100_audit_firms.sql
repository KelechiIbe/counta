-- Release 6 of the filing work: audits. Which companies need their accounts audited, the TaxStreem partner firms that audit
-- them, what each firm charges, and asking a firm and paying it through Flutterwave with TaxStreem's referral fee split off.
--
-- 1. The audit test. A company whose turnover for the year is above the small company limit (₦100 million) or whose fixed
--    assets are above theirs (₦250 million) has its financial statements audited (private.audit_need). The limits are the tax
--    rules TaxStreem keeps in the admin portal (small_company_turnover, small_company_fixed_assets), for every year, and the
--    figures are the year's CIT figures (private.cit_compute). A business name or partnership files a statement of accounts
--    and is never asked. Counta tells a company once for each year it crosses either limit (private.audit_tick, daily), and
--    the Filing page and the CIT tab show it for the year.
-- 2. Who audits. A partner firm offers audits once it has a partner with an ICAN or ANAN number and an FRC number, both
--    checked by TaxStreem (practice_members.frc_*); a bank account in the firm's or a partner's name, confirmed with the bank;
--    its Tax ID and state (clients deduct withholding tax); a price for at least one turnover band; and a Flutterwave
--    subaccount on that bank account, set up by the audits edge function. Then a partner switches audits on and businesses
--    see the firm with its price for their size, VAT added when the firm charges it. A firm that keeps the business's books
--    is shown with a warning about independence.
-- 3. The bands. TaxStreem sets the turnover bands in the admin portal (platform_settings 'audits': the upper end of each band;
--    the last band is everything above the last number). Each firm prices the bands it takes (practice_audit_offers.prices,
--    keyed by the band's upper end, 'top' for the last).
-- 4. Asking and paying. The business's owner or an admin asks one firm (audit_engagements, one live request or engagement a
--    year). The firm accepts or declines within the days TaxStreem sets (7), or the request lapses. Once accepted, the
--    business pays at Flutterwave's checkout: the fee and its VAT less the withholding tax it deducts. Counta enters the bill
--    from the firm in the business's books (audit fees, 6501, with the WHT due on it), as a draft when the payment starts and
--    approved when it is confirmed; the card payment's bank line pays it later as usual. Flutterwave splits the payment:
--    TaxStreem's referral fee (10% of the fee before VAT, set in the admin portal and fixed when the business asks) goes to
--    TaxStreem, and the rest, less Flutterwave's charge, settles to the firm's bank account (audit_charges).
-- 5. Small companies and CIT. A company providing professional services is small for companies income tax on its turnover
--    and fixed assets like any other: the rule that it is never small is a VAT rule only. private.cit_compute no longer applies
--    it to CIT. The VAT test is unchanged.
-- Run once, in the SQL Editor of the counta project, as one script.

-- ---------------------------------------------------------------------------
-- 1. Settings, FRC numbers, offers, engagements and payments
-- ---------------------------------------------------------------------------
alter table public.platform_settings drop constraint if exists platform_settings_key_check;
alter table public.platform_settings add constraint platform_settings_key_check
  check (key in ('martina', 'limits', 'switches', 'alerts', 'partners', 'mandates', 'audits'));

-- enabled: firms can be found and paid for audits. referral_rate: TaxStreem's share of each audit fee before VAT, split off at
-- payment. request_days: how long a firm has to answer. bands: the upper end of each turnover band in naira, rising; the last
-- band is everything above the last number.
create or replace function private.audit_defaults() returns jsonb
language sql immutable as $$
  select '{"enabled": true, "referral_rate": 0.10, "request_days": 7, "bands": [250000000, 500000000, 1000000000, 5000000000]}'::jsonb
$$;

create or replace function private.audit_settings() returns jsonb
language sql stable security definer set search_path = public, private as $$
  select private.audit_defaults() || coalesce((select value from platform_settings where key = 'audits'), '{}'::jsonb)
$$;

-- The FRC number of a person in a practice, checked by TaxStreem like the licence number. A partner signs audits with a
-- verified ICAN or ANAN number and a verified FRC number.
alter table public.practice_members add column if not exists frc_no text check (frc_no is null or frc_no ~ '^[A-Z0-9/.-]{6,40}$');
alter table public.practice_members add column if not exists frc_status text not null default 'none'
  check (frc_status in ('none', 'pending', 'verified', 'rejected'));
alter table public.practice_members add column if not exists frc_note text;
alter table public.practice_members add column if not exists frc_verified_by uuid references auth.users(id) on delete set null;
alter table public.practice_members add column if not exists frc_verified_at timestamptz;
create index if not exists practice_members_frc_pending on public.practice_members(frc_status) where frc_status = 'pending';
create index if not exists practice_members_frc_verified_by on public.practice_members(frc_verified_by);

-- A firm's audit offer. entity_type, tin: what clients' withholding tax goes by. prices: band key -> fee before VAT. The
-- subaccount_* columns are Flutterwave's split for the firm: its reference (RS_...), its number (for changes) and the bank
-- account it settles to, so a changed payout account is noticed.
create table if not exists public.practice_audit_offers (
  practice_id uuid primary key references public.practices(id) on delete cascade,
  active boolean not null default false,
  entity_type text not null default 'partnership' check (entity_type in ('partnership', 'llp', 'company', 'sole_proprietor')),
  tin text check (tin is null or tin ~ '^[0-9][0-9-]{7,14}$'),
  vat_registered boolean not null default false,
  prices jsonb not null default '{}'::jsonb check (jsonb_typeof(prices) = 'object'),
  note text check (note is null or length(note) <= 300),
  subaccount_ref text,
  subaccount_num bigint,
  subaccount_bank text,
  subaccount_account text,
  subaccount_status text not null default 'none' check (subaccount_status in ('none', 'ready', 'failed')),
  subaccount_error text,
  subaccount_at timestamptz,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);
create index if not exists practice_audit_offers_updated_by on public.practice_audit_offers(updated_by);
alter table public.practice_audit_offers enable row level security;
revoke all on public.practice_audit_offers from anon, authenticated;

-- One company's audit for one year (the year as the income tax return names it). kind: partner (a firm in Counta) or own
-- (an auditor the business names itself). status: requested, accepted, paid; declined, lapsed, cancelled when it ends before
-- payment; recorded for an own auditor. What was quoted is kept: band, turnover and fixed assets when asked, the fee, whether
-- the firm charged VAT, TaxStreem's rate. vat, wht, wvat, amount, referral: what the payment came to (amount is what the
-- business pays at checkout). keeps_books: the firm kept the business's books when it was asked.
create table if not exists public.audit_engagements (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  year int not null check (year between 2000 and 2100),
  kind text not null default 'partner' check (kind in ('partner', 'own')),
  practice_id uuid references public.practices(id) on delete set null,
  own_name text check (own_name is null or length(own_name) between 2 and 160),
  own_email text check (own_email is null or own_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  status text not null check (status in ('requested', 'accepted', 'paid', 'declined', 'lapsed', 'cancelled', 'recorded')),
  band text,
  turnover numeric(18,2),
  fixed_assets numeric(18,2),
  price numeric(16,2) check (price is null or price > 0),
  vat_registered boolean,
  vat numeric(16,2) not null default 0,
  wht numeric(16,2) not null default 0,
  wvat numeric(16,2) not null default 0,
  amount numeric(16,2),
  referral_rate numeric(6,4),
  referral numeric(16,2),
  keeps_books boolean not null default false,
  note text check (note is null or length(note) <= 500),
  answer_note text check (answer_note is null or length(answer_note) <= 500),
  bill_id uuid references public.bills(id) on delete set null,
  bill_error text,
  requested_by uuid references auth.users(id) on delete set null,
  requested_at timestamptz not null default now(),
  answered_by uuid references auth.users(id) on delete set null,
  answered_at timestamptz,
  paid_at timestamptz,
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (kind = 'own' or price is not null)
);
create unique index if not exists audit_engagements_live on public.audit_engagements(org_id, year)
  where status in ('requested', 'accepted', 'paid', 'recorded');
create index if not exists audit_engagements_org on public.audit_engagements(org_id, year);
create index if not exists audit_engagements_practice on public.audit_engagements(practice_id, status);
create index if not exists audit_engagements_waiting on public.audit_engagements(requested_at) where status = 'requested';
create index if not exists audit_engagements_bill on public.audit_engagements(bill_id);
create index if not exists audit_engagements_requested_by on public.audit_engagements(requested_by);
create index if not exists audit_engagements_answered_by on public.audit_engagements(answered_by);
alter table public.audit_engagements enable row level security;
revoke all on public.audit_engagements from anon, authenticated;

-- Each checkout for an engagement. referral: TaxStreem's flat share of it; subaccount_ref: the firm's split it settles to.
-- paid_amount and fee: what Flutterwave confirmed.
create table if not exists public.audit_charges (
  id uuid primary key default gen_random_uuid(),
  engagement_id uuid not null references public.audit_engagements(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  practice_id uuid references public.practices(id) on delete set null,
  tx_ref text not null unique check (tx_ref ~ '^AUD-[0-9A-F]{16}$'),
  amount numeric(16,2) not null check (amount > 0),
  referral numeric(16,2) not null check (referral >= 0),
  subaccount_ref text not null,
  status text not null default 'pending' check (status in ('pending', 'successful', 'failed', 'cancelled')),
  provider_ref text,
  paid_amount numeric(16,2),
  fee numeric(16,2),
  error text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  updated_at timestamptz not null default now()
);
create index if not exists audit_charges_engagement on public.audit_charges(engagement_id);
create index if not exists audit_charges_org on public.audit_charges(org_id);
create index if not exists audit_charges_practice on public.audit_charges(practice_id);
create index if not exists audit_charges_created_by on public.audit_charges(created_by);
create index if not exists audit_charges_open on public.audit_charges(created_at) where status = 'pending';
alter table public.audit_charges enable row level security;
revoke all on public.audit_charges from anon, authenticated;

-- The years a company was told its accounts need an audit (once each).
create table if not exists public.audit_notices (
  org_id uuid not null references public.orgs(id) on delete cascade,
  year int not null,
  notified_at timestamptz not null default now(),
  primary key (org_id, year)
);
alter table public.audit_notices enable row level security;
revoke all on public.audit_notices from anon, authenticated;

-- Bills Counta enters for an audit fee.
alter table public.bills drop constraint if exists bills_source_check;
alter table public.bills add constraint bills_source_check
  check (source in ('manual', 'receipt', 'prism', 'ai', 'import', 'landed_cost', 'supplier', 'bulk', 'practice_fee', 'audit'));

-- ---------------------------------------------------------------------------
-- 2. Existing functions, each with the change named above it
-- ---------------------------------------------------------------------------

-- private.cit_compute: a company is small for CIT on its turnover and fixed assets alone. The professional services rule is for VAT only.
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
    -- Small (s.202): turnover and fixed assets alone. A company providing professional services is classified like any other
    -- here; the rule that it is never small applies to VAT only.
    v_small := v_turn <= coalesce(private.rbn(rb, 'company_classification', 'thresholds', 'small_company_turnover_max_ngn'), 100000000)
               and v_fixed <= coalesce(private.rbn(rb, 'company_classification', 'thresholds', 'small_company_fixed_assets_max_ngn'), 250000000);
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

-- public.practice_set_licence: also takes the FRC number (frc_no), which TaxStreem checks before the person may sign audits.
CREATE OR REPLACE FUNCTION public.practice_set_licence(p_practice uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.practice_members; v_body text := nullif(p->>'licence_body', ''); v_no text := nullif(trim(p->>'licence_no'), ''); v_frc text;
begin
  m := private.practice_require(p_practice);
  if v_body is not null and v_body not in ('ICAN', 'ANAN', 'CITN') then raise exception 'Choose ICAN, ANAN or CITN.'; end if;
  if (v_body is null) <> (v_no is null) then raise exception 'Give the body and the membership number together.'; end if;
  update practice_members set licence_body = v_body, licence_no = v_no,
    licence_status = case when v_no is null then 'none' when v_body = licence_body and v_no = licence_no and licence_status = 'verified' then 'verified' else 'pending' end,
    licence_note = case when v_no is distinct from licence_no then null else licence_note end
  where id = m.id;
  if p ? 'frc_no' then
    v_frc := nullif(upper(regexp_replace(coalesce(p->>'frc_no', ''), '\s+', '', 'g')), '');
    if v_frc is not null and v_frc !~ '^[A-Z0-9/.-]{6,40}$' then
      raise exception 'Enter the FRC number as it appears on your certificate, such as FRC/2014/ICAN/00000001234.';
    end if;
    update practice_members set frc_no = v_frc,
      frc_status = case when v_frc is null then 'none' when v_frc = frc_no and frc_status = 'verified' then 'verified' else 'pending' end,
      frc_note = case when v_frc is distinct from frc_no then null else frc_note end
    where id = m.id;
  end if;
  return public.practice_home(p_practice);
end $function$;

-- public.create_practice: the founder may give an FRC number with the licence number.
CREATE OR REPLACE FUNCTION public.create_practice(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare v_id uuid; v_email text; v_name text;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if (select count(*) from practice_members where user_id = auth.uid() and role = 'partner') >= 3 then raise exception 'You run three practices already.'; end if;
  select lower(email), coalesce(nullif(trim(raw_user_meta_data->>'full_name'), ''), nullif(trim(raw_user_meta_data->>'name'), ''), split_part(email, '@', 1))
    into v_email, v_name from auth.users where id = auth.uid();
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'Enter the practice''s name.'; end if;
  insert into practices (name, kind, email, phone, address, state, firm_reg, created_by)
  values (trim(p->>'name'), coalesce(nullif(p->>'kind', ''), 'firm'), nullif(lower(trim(p->>'email')), ''), nullif(trim(p->>'phone'), ''), nullif(trim(p->>'address'), ''),
    nullif(trim(p->>'state'), ''), nullif(trim(p->>'firm_reg'), ''), auth.uid())
  returning id into v_id;
  if nullif(upper(regexp_replace(coalesce(p->>'frc_no', ''), '\s+', '', 'g')), '') !~ '^[A-Z0-9/.-]{6,40}$' then
    raise exception 'Enter the FRC number as it appears on your certificate, such as FRC/2014/ICAN/00000001234.';
  end if;
  insert into practice_members (practice_id, user_id, email, display_name, role, status, licence_body, licence_no, licence_status, frc_no, frc_status)
  values (v_id, auth.uid(), v_email, left(coalesce(nullif(trim(p->>'my_name'), ''), v_name), 80), 'partner', 'active', nullif(p->>'licence_body', ''),
    nullif(trim(p->>'licence_no'), ''), case when nullif(trim(p->>'licence_no'), '') is not null and nullif(p->>'licence_body', '') is not null then 'pending' else 'none' end,
    nullif(upper(regexp_replace(coalesce(p->>'frc_no', ''), '\s+', '', 'g')), ''),
    case when nullif(upper(regexp_replace(coalesce(p->>'frc_no', ''), '\s+', '', 'g')), '') is not null then 'pending' else 'none' end);
  return public.practice_home(v_id);
end $function$;

-- private.practice_member_json: the FRC number and its check, and whether the person may sign audits.
CREATE OR REPLACE FUNCTION private.practice_member_json(m practice_members, p_full boolean)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select jsonb_build_object('id', m.id, 'display_name', m.display_name, 'role', m.role, 'status', m.status, 'joined', m.user_id is not null,
    'licence_body', m.licence_body, 'licence_no', m.licence_no, 'licence_status', m.licence_status, 'licence_text', private.licence_text(m),
    'frc_no', m.frc_no, 'frc_status', m.frc_status,
    'signs_audits', m.role = 'partner' and m.status = 'active' and m.licence_body in ('ICAN', 'ANAN') and m.licence_status = 'verified' and m.frc_status = 'verified',
    'clients', (select count(*) from practice_assignments a join practice_clients c on c.id = a.client_id where a.member_id = m.id and c.status = 'active'))
    || case when p_full then jsonb_build_object('email', m.email, 'licence_note', m.licence_note, 'frc_note', m.frc_note, 'sent_at', m.sent_at, 'created_at', m.created_at) else '{}'::jsonb end
$function$;

-- public.admin_licences: FRC numbers too, each with its own check; Waiting lists a person with either waiting.
CREATE OR REPLACE FUNCTION public.admin_licences(p_status text DEFAULT 'pending'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
begin
  perform private.require_staff(false);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', m.display_name, 'email', m.email, 'role', m.role, 'practice', p.name, 'practice_id', p.id,
      'firm_reg', p.firm_reg, 'licence_body', m.licence_body, 'licence_no', m.licence_no, 'licence_status', m.licence_status, 'licence_note', m.licence_note,
      'verified_at', m.verified_at, 'created_at', m.created_at,
      'frc_no', m.frc_no, 'frc_status', m.frc_status, 'frc_note', m.frc_note, 'frc_verified_at', m.frc_verified_at,
      'clients', (select count(*) from practice_clients c where c.practice_id = p.id and c.status = 'active')) order by m.created_at), '[]'::jsonb)
    from practice_members m join practices p on p.id = m.practice_id
    where (m.licence_no is not null or m.frc_no is not null)
      and (coalesce(p_status, 'all') = 'all' or m.licence_status = p_status or m.frc_status = p_status) and m.status <> 'disabled');
end $function$;

-- ---------------------------------------------------------------------------
-- 3. Bands, signers, readiness and the audit test
-- ---------------------------------------------------------------------------
-- ₦250m, ₦1.5bn: short naira amounts for band names.
create or replace function private.audit_naira(p numeric) returns text
language sql immutable as $$
  select '₦' || case when p >= 1000000000 then rtrim(rtrim(to_char(p / 1000000000, 'FM999990.00'), '0'), '.') || 'bn'
                     when p >= 1000000 then rtrim(rtrim(to_char(p / 1000000, 'FM999990.00'), '0'), '.') || 'm'
                     else to_char(p, 'FM999,999,990') end
$$;

-- The bands in order: key (the upper end, or 'top'), from, up_to and a name.
create or replace function private.audit_bands() returns jsonb
language sql stable security definer set search_path = public, private as $$
  with b as (select x::numeric up_to, n from jsonb_array_elements_text(private.audit_settings()->'bands') with ordinality t(x, n)),
  r as (select up_to, lag(up_to) over (order by n) lo, n from b)
  select coalesce((select jsonb_agg(jsonb_build_object('key', round(up_to)::bigint::text, 'from', coalesce(lo, 0), 'up_to', up_to,
      'label', case when lo is null then 'Up to ' || private.audit_naira(up_to) else private.audit_naira(lo) || ' to ' || private.audit_naira(up_to) end)
      order by n) from r), '[]'::jsonb)
    || jsonb_build_array(jsonb_build_object('key', 'top', 'from', coalesce((select max(up_to) from b), 0), 'up_to', null,
      'label', case when exists (select 1 from b) then 'Above ' || private.audit_naira((select max(up_to) from b)) else 'Any size' end))
$$;

-- The band a turnover falls in.
create or replace function private.audit_band(p_turnover numeric) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(
    (select x from jsonb_array_elements(private.audit_bands()) x
     where x->>'key' <> 'top' and coalesce(p_turnover, 0) <= (x->>'up_to')::numeric order by (x->>'up_to')::numeric limit 1),
    (select x from jsonb_array_elements(private.audit_bands()) x where x->>'key' = 'top'))
$$;

-- The firm's partners who may sign an audit: a verified ICAN or ANAN number and a verified FRC number.
create or replace function private.audit_signers(p_practice uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', m.display_name, 'body', m.licence_body, 'licence_no', m.licence_no, 'frc_no', m.frc_no)
    order by m.display_name), '[]'::jsonb)
  from practice_members m
  where m.practice_id = p_practice and m.role = 'partner' and m.status = 'active'
    and m.licence_body in ('ICAN', 'ANAN') and m.licence_status = 'verified' and m.frc_status = 'verified'
$$;

-- What a firm still needs before businesses can find it for audits, step by step. ready: every step done; listed: ready,
-- switched on, and audits open in Counta.
create or replace function private.audit_ready(p_practice uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare pr public.practices; f public.practice_audit_offers; b public.practice_payout_accounts; v_signers jsonb; v_priced int; v_flw boolean;
  v_steps jsonb; v_ready boolean;
begin
  select * into pr from practices where id = p_practice;
  select * into f from practice_audit_offers where practice_id = p_practice;
  select * into b from practice_payout_accounts where practice_id = p_practice;
  v_signers := private.audit_signers(p_practice);
  select count(*) into v_priced from jsonb_array_elements(private.audit_bands()) x
  where coalesce((f.prices->>(x->>'key'))::numeric, 0) > 0;
  v_flw := coalesce(f.subaccount_status = 'ready' and f.subaccount_bank = b.bank_code and f.subaccount_account = b.account_number, false);
  v_steps := jsonb_build_array(
    jsonb_build_object('id', 'signer', 'done', jsonb_array_length(v_signers) > 0,
      'text', 'A partner with an ICAN or ANAN number and an FRC number, both verified by TaxStreem'),
    jsonb_build_object('id', 'bank', 'done', coalesce(b.practice_id is not null and b.name_match, false),
      'text', case when b.practice_id is not null and not b.name_match
        then 'The bank holds the payout account in another name: use an account in the practice''s or a partner''s name'
        else 'A bank account in the practice''s or a partner''s name, confirmed with the bank' end),
    jsonb_build_object('id', 'tax', 'done', coalesce(f.tin is not null and nullif(trim(pr.state), '') is not null, false),
      'text', 'The firm''s Tax ID and state, for the withholding tax clients deduct'),
    jsonb_build_object('id', 'prices', 'done', v_priced > 0, 'text', 'A price for at least one turnover band'),
    jsonb_build_object('id', 'flutterwave', 'done', v_flw,
      'text', case when f.subaccount_status = 'failed' then 'Flutterwave could not set up the split: ' || coalesce(f.subaccount_error, 'try again')
        when f.subaccount_status = 'ready' and not v_flw then 'The payout account changed: set up Flutterwave again'
        else 'Flutterwave set up to pay your share straight to that bank account' end));
  v_ready := not exists (select 1 from jsonb_array_elements(v_steps) s where not (s->>'done')::boolean);
  return jsonb_build_object('steps', v_steps, 'ready', v_ready, 'active', coalesce(f.active, false),
    'listed', v_ready and coalesce(f.active, false) and coalesce((private.audit_settings()->>'enabled')::boolean, false),
    'signers', v_signers);
end $$;

-- A firm as a business sees it, with its price for one band.
create or replace function private.audit_firm_public(p_practice uuid, p_band text) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', p.id, 'name', p.name, 'kind', p.kind, 'state', p.state, 'note', f.note, 'entity_type', f.entity_type,
    'vat_registered', f.vat_registered, 'price', (f.prices->>p_band)::numeric, 'signers', private.audit_signers(p.id))
  from practices p left join practice_audit_offers f on f.practice_id = p.id where p.id = p_practice
$$;

-- Whether a company's accounts for a year need an audit: turnover above the small company limit, or fixed assets above
-- theirs, on the year's CIT figures (to date while the year runs). Only companies.
create or replace function private.audit_need(p_org uuid, p_year int) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_from date; v_to date; v_tmax numeric; v_fmax numeric; c jsonb; v_turn numeric; v_fa numeric; v_company boolean;
begin
  select pfrom, pto into v_from, v_to from private.cit_period(p_org, p_year);
  v_tmax := coalesce(private.tax_rule('small_company_turnover', greatest(v_to, date '2026-01-01')), 100000000);
  v_fmax := coalesce(private.tax_rule('small_company_fixed_assets', greatest(v_to, date '2026-01-01')), 250000000);
  v_company := private.income_tax_kind(p_org, p_year) = 'company';
  if v_company then
    c := private.cit_compute(p_org, p_year);
    v_turn := coalesce((c->'figures'->>'turnover')::numeric, 0);
    v_fa := coalesce((c->'figures'->>'fixed_assets')::numeric, 0);
  end if;
  return jsonb_build_object('year', p_year, 'from', v_from, 'to', v_to, 'company', v_company,
    'ended', private.local_day(p_org, now()) > v_to, 'turnover', v_turn, 'fixed_assets', v_fa,
    'turnover_max', v_tmax, 'fixed_assets_max', v_fmax,
    'over_turnover', coalesce(v_turn > v_tmax, false), 'over_assets', coalesce(v_fa > v_fmax, false),
    'required', v_company and (v_turn > v_tmax or v_fa > v_fmax),
    'band', private.audit_band(v_turn));
end $$;

-- An engagement for the business (p_firm false) or the firm and TaxStreem (true, with the referral fee).
create or replace function private.audit_engagement_json(e public.audit_engagements, p_firm boolean) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select case when e.id is null then null else jsonb_build_object(
    'id', e.id, 'year', e.year, 'kind', e.kind, 'status', e.status, 'own_name', e.own_name, 'own_email', e.own_email,
    'band', (select x from jsonb_array_elements(private.audit_bands()) x where x->>'key' = e.band),
    'turnover', e.turnover, 'fixed_assets', e.fixed_assets, 'price', e.price, 'vat_registered', e.vat_registered,
    'vat', case when e.amount is not null then e.vat when e.vat_registered then round(e.price * private.vat_rate(private.local_day(e.org_id, now())), 2) else 0 end,
    'wht', e.wht, 'wvat', e.wvat, 'amount', e.amount, 'keeps_books', e.keeps_books, 'note', e.note, 'answer_note', e.answer_note,
    'bill', (select jsonb_build_object('id', b.id, 'number', b.number, 'status', b.status) from bills b where b.id = e.bill_id), 'bill_error', e.bill_error,
    'requested_at', e.requested_at, 'answered_at', e.answered_at, 'paid_at', e.paid_at, 'ended_at', e.ended_at,
    'lapses_at', case when e.status = 'requested' then e.requested_at + make_interval(days => coalesce((private.audit_settings()->>'request_days')::int, 7)) end,
    'business', (select jsonb_build_object('id', o.id, 'name', o.name, 'tin', o.tin, 'rc_number', o.rc_number) from orgs o where o.id = e.org_id),
    'firm', case when e.practice_id is not null then private.audit_firm_public(e.practice_id, e.band) - 'price' end,
    'charge', (select jsonb_build_object('tx_ref', c.tx_ref, 'status', c.status, 'amount', c.amount, 'paid_amount', c.paid_amount, 'at', c.created_at,
        'paid_at', c.paid_at)
      from audit_charges c where c.engagement_id = e.id order by (c.status = 'successful') desc, c.created_at desc limit 1))
    || case when p_firm then jsonb_build_object('referral_rate', e.referral_rate,
      'referral', coalesce(e.referral, round(e.price * coalesce(e.referral_rate, 0), 2))) else '{}'::jsonb end
  end
$$;

-- Tells the business's owners and admins (and anyone acting as owner).
create or replace function private.audit_notify_business(p_org uuid, p_title text, p_body text) returns void
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_url text;
begin
  if private.quiet(p_org) then return; end if;
  v_url := case when (select filing_only from orgs where id = p_org) then '/filing' else '/tax/cit' end;
  for m in select * from members where org_id = p_org and status = 'active' and user_id is not null and (role in ('owner', 'admin') or acts_as_owner) loop
    perform private.notify(p_org, m.user_id, 'audit', p_title, p_body, v_url, null);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 4. The business: the year's audit, the firms, asking, an auditor of its own, cancelling
-- ---------------------------------------------------------------------------
create or replace function private.audit_can_act(m public.members) returns boolean
language sql immutable as $$
  select m.id is not null and (m.role in ('owner', 'admin') or m.acts_as_owner)
$$;

create or replace function public.audit_state(p_org uuid, p_year int) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; o public.orgs; e public.audit_engagements; s jsonb := private.audit_settings();
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  select * into e from audit_engagements where org_id = p_org and year = p_year
  order by (status in ('requested', 'accepted', 'paid', 'recorded')) desc, created_at desc limit 1;
  return jsonb_build_object('year', p_year, 'enabled', coalesce((s->>'enabled')::boolean, false), 'need', private.audit_need(p_org, p_year),
    'audit_exempt', o.audit_exempt, 'auditors', o.auditors,
    'can_act', private.audit_can_act(m) and not o.is_sample and o.read_only_at is null,
    'engagement', private.audit_engagement_json(e, false));
end $$;

create or replace function public.audit_firms(p_org uuid, p_year int) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_need jsonb; v_band text; v_rate numeric; s jsonb := private.audit_settings();
begin
  m := private.require(p_org, null);
  v_need := private.audit_need(p_org, p_year);
  v_band := v_need->'band'->>'key';
  v_rate := private.vat_rate(private.local_day(p_org, now()));
  if not coalesce((s->>'enabled')::boolean, false) then return jsonb_build_object('band', v_need->'band', 'firms', '[]'::jsonb); end if;
  return jsonb_build_object('band', v_need->'band', 'firms', (
    select coalesce(jsonb_agg(x.j order by (x.j->>'keeps_books')::boolean, (x.j->>'price')::numeric, x.j->>'name'), '[]'::jsonb)
    from (select private.audit_firm_public(p.id, v_band) || jsonb_build_object(
            'keeps_books', exists (select 1 from practice_clients c where c.practice_id = p.id and c.org_id = p_org and c.status = 'active'),
            'vat', case when f.vat_registered then round((f.prices->>v_band)::numeric * v_rate, 2) else 0 end) j
          from practices p join practice_audit_offers f on f.practice_id = p.id
          where f.active and coalesce((f.prices->>v_band)::numeric, 0) > 0 and (private.audit_ready(p.id)->>'listed')::boolean) x));
end $$;

-- The business asks one firm to audit a year's accounts, at the firm's price for the business's size.
create or replace function public.audit_request(p_org uuid, p_year int, p_practice uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; v_need jsonb; v_band text; pr public.practices; f public.practice_audit_offers;
  s jsonb := private.audit_settings(); v_price numeric; v_keeps boolean; v_id uuid;
begin
  m := private.require(p_org, null);
  if not private.audit_can_act(m) then raise exception 'The owner or an admin of the business chooses its auditor.' using errcode = '42501'; end if;
  select * into o from orgs where id = p_org;
  if o.is_sample then raise exception 'The sample business cannot engage an auditor. Use your own business.'; end if;
  if o.read_only_at is not null then raise exception 'This business is read-only.'; end if;
  if not coalesce((s->>'enabled')::boolean, false) then raise exception 'Audits through Counta are not open yet.'; end if;
  if p_year is null or p_year < 2020 or p_year > private.cit_year_of(p_org, private.local_day(p_org, now())) then raise exception 'Choose the year to audit.'; end if;
  v_need := private.audit_need(p_org, p_year);
  if not (v_need->>'company')::boolean then
    raise exception 'Only a company has its accounts audited. A business name or partnership files a statement of accounts.';
  end if;
  if exists (select 1 from audit_engagements where org_id = p_org and year = p_year and status in ('requested', 'accepted', 'paid', 'recorded')) then
    raise exception 'The % accounts already have an auditor or a request waiting. Cancel it first to choose another.', p_year;
  end if;
  if (select count(*) from audit_engagements where org_id = p_org and created_at > now() - interval '1 day') >= 10 then
    raise exception 'That is enough requests for today.';
  end if;
  v_band := v_need->'band'->>'key';
  select * into pr from practices where id = p_practice;
  select * into f from practice_audit_offers where practice_id = p_practice;
  if pr.id is null or not coalesce((private.audit_ready(p_practice)->>'listed')::boolean, false) then
    raise exception 'That firm is not taking audits through Counta.';
  end if;
  v_price := (f.prices->>v_band)::numeric;
  if coalesce(v_price, 0) <= 0 then raise exception '% does not audit businesses of this size through Counta.', pr.name; end if;
  v_keeps := exists (select 1 from practice_clients c where c.practice_id = p_practice and c.org_id = p_org and c.status = 'active');
  insert into audit_engagements (org_id, year, kind, practice_id, status, band, turnover, fixed_assets, price, vat_registered, referral_rate,
    keeps_books, note, requested_by)
  values (p_org, p_year, 'partner', p_practice, 'requested', v_band, (v_need->>'turnover')::numeric, (v_need->>'fixed_assets')::numeric, v_price,
    f.vat_registered, coalesce((s->>'referral_rate')::numeric, 0), v_keeps, nullif(left(trim(coalesce(p->>'note', '')), 500), ''), auth.uid())
  returning id into v_id;
  perform private.activity_event(p_org, 'audit_requested', 'Asked ' || pr.name || ' to audit the ' || p_year || ' accounts',
    jsonb_build_object('engagement_id', v_id, 'firm_id', p_practice, 'year', p_year, 'price', v_price));
  perform private.practice_notify(p_practice, o.name || ' asks you to audit its ' || p_year || ' accounts',
    'Your price for its size is ' || private.naira(v_price) || case when f.vat_registered then ' plus VAT' else '' end
      || '. Answer under Audits within ' || coalesce(s->>'request_days', '7') || ' days.', '/practice/audits');
  return public.audit_state(p_org, p_year);
end $$;

-- The business names an auditor of its own for the year (one outside Counta).
create or replace function public.audit_own(p_org uuid, p_year int, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; o public.orgs; v_name text := left(trim(coalesce(p->>'name', '')), 160); v_email text := nullif(lower(trim(coalesce(p->>'email', ''))), '');
begin
  m := private.require(p_org, null);
  if not private.audit_can_act(m) then raise exception 'The owner or an admin of the business chooses its auditor.' using errcode = '42501'; end if;
  select * into o from orgs where id = p_org;
  if o.is_sample then raise exception 'The sample business cannot engage an auditor. Use your own business.'; end if;
  if o.read_only_at is not null then raise exception 'This business is read-only.'; end if;
  if p_year is null or p_year < 2020 or p_year > private.cit_year_of(p_org, private.local_day(p_org, now())) then raise exception 'Choose the year to audit.'; end if;
  if private.income_tax_kind(p_org, p_year) <> 'company' then raise exception 'Only a company has its accounts audited.'; end if;
  if length(v_name) < 2 then raise exception 'Enter the audit firm''s name.'; end if;
  if v_email is not null and v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email address does not look right.'; end if;
  if exists (select 1 from audit_engagements where org_id = p_org and year = p_year and status in ('requested', 'accepted', 'paid', 'recorded')) then
    raise exception 'The % accounts already have an auditor or a request waiting. Cancel it first to choose another.', p_year;
  end if;
  insert into audit_engagements (org_id, year, kind, status, own_name, own_email, requested_by, answered_at)
  values (p_org, p_year, 'own', 'recorded', v_name, v_email, auth.uid(), now());
  perform private.activity_event(p_org, 'audit_own', v_name || ' audits the ' || p_year || ' accounts', jsonb_build_object('year', p_year));
  return public.audit_state(p_org, p_year);
end $$;

-- Withdraws a request, an accepted audit not yet paid, or an auditor the business named. A draft bill for it is voided.
create or replace function public.audit_cancel(p_engagement uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare e public.audit_engagements; m public.members; v_org text;
begin
  select * into e from audit_engagements where id = p_engagement for update;
  if not found then raise exception 'Audit not found.'; end if;
  m := private.require(e.org_id, null);
  if not private.audit_can_act(m) then raise exception 'The owner or an admin of the business chooses its auditor.' using errcode = '42501'; end if;
  if e.status = 'paid' then raise exception 'This audit is paid for. Ask TaxStreem if it has to end.'; end if;
  if e.status not in ('requested', 'accepted', 'recorded') then raise exception 'This request has already ended.'; end if;
  if exists (select 1 from audit_charges where engagement_id = e.id and status = 'pending' and created_at > now() - interval '30 minutes') then
    raise exception 'A payment for this audit started a few minutes ago. Wait for it to finish, or try again in half an hour.';
  end if;
  update audit_engagements set status = 'cancelled', ended_at = now(), updated_at = now() where id = e.id;
  update bills set status = 'void', voided_by = m.id, voided_at = now(), void_reason = 'The audit was cancelled before it was paid.'
  where id = e.bill_id and status = 'draft';
  select name into v_org from orgs where id = e.org_id;
  if e.practice_id is not null then
    perform private.practice_notify(e.practice_id, v_org || ' withdrew its request for the ' || e.year || ' audit', 'Nothing is owed.', '/practice/audits');
  end if;
  perform private.activity_event(e.org_id, 'audit_cancelled', 'Withdrew the ' || e.year || ' audit request', jsonb_build_object('engagement_id', e.id));
  return public.audit_state(e.org_id, e.year);
end $$;

-- ---------------------------------------------------------------------------
-- 5. The firm: its offer, switching audits on, answering requests
-- ---------------------------------------------------------------------------
create or replace function public.practice_audit(p_practice uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare me public.practice_members; pr public.practices; f public.practice_audit_offers; b public.practice_payout_accounts; v_lead boolean;
  s jsonb := private.audit_settings();
begin
  me := private.practice_require(p_practice);
  v_lead := me.role in ('partner', 'manager');
  select * into pr from practices where id = p_practice;
  select * into f from practice_audit_offers where practice_id = p_practice;
  select * into b from practice_payout_accounts where practice_id = p_practice;
  return jsonb_build_object(
    'enabled', coalesce((s->>'enabled')::boolean, false), 'referral_rate', (s->>'referral_rate')::numeric, 'request_days', (s->>'request_days')::int,
    'bands', private.audit_bands(), 'state', pr.state, 'kind', pr.kind,
    'offer', jsonb_build_object('active', coalesce(f.active, false),
      'entity_type', coalesce(f.entity_type, case when pr.kind = 'sole' then 'sole_proprietor' else 'partnership' end),
      'tin', f.tin, 'vat_registered', coalesce(f.vat_registered, false), 'prices', coalesce(f.prices, '{}'::jsonb), 'note', f.note,
      'flutterwave', jsonb_build_object('status', coalesce(f.subaccount_status, 'none'), 'error', f.subaccount_error, 'at', f.subaccount_at)),
    'ready', private.audit_ready(p_practice),
    'bank', case when b.practice_id is not null then jsonb_build_object('bank_name', b.bank_name, 'last4', right(b.account_number, 4),
      'account_name', b.account_name, 'name_match', b.name_match) end,
    'me', jsonb_build_object('id', me.id, 'role', me.role, 'licence_body', me.licence_body, 'licence_no', me.licence_no, 'licence_status', me.licence_status,
      'frc_no', me.frc_no, 'frc_status', me.frc_status, 'frc_note', me.frc_note,
      'signs', coalesce(me.role = 'partner' and me.licence_body in ('ICAN', 'ANAN') and me.licence_status = 'verified' and me.frc_status = 'verified', false)),
    'requests', case when v_lead then (select coalesce(jsonb_agg(private.audit_engagement_json(e, true) order by e.requested_at), '[]'::jsonb)
      from audit_engagements e where e.practice_id = p_practice and e.status = 'requested') else '[]'::jsonb end,
    'engagements', case when v_lead then (select coalesce(jsonb_agg(private.audit_engagement_json(e, true) order by e.status = 'accepted' desc, coalesce(e.paid_at, e.answered_at, e.requested_at) desc), '[]'::jsonb)
      from audit_engagements e where e.practice_id = p_practice
        and (e.status in ('accepted', 'paid') or (e.status in ('declined', 'lapsed', 'cancelled') and coalesce(e.ended_at, e.created_at) > now() - interval '90 days'))) else '[]'::jsonb end);
end $$;

-- A partner sets the offer: the firm's form and Tax ID, whether it charges VAT, its prices by band and a short note.
create or replace function public.practice_audit_save(p_practice uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare me public.practice_members; f public.practice_audit_offers; v_prices jsonb; v_tin text; k text; v text; v_keys text[];
begin
  me := private.practice_require(p_practice, true);
  if me.role <> 'partner' then raise exception 'Only a partner sets the firm''s audit offer.' using errcode = '42501'; end if;
  select * into f from practice_audit_offers where practice_id = p_practice for update;
  if f.practice_id is null then
    insert into practice_audit_offers (practice_id, entity_type, updated_by)
    values (p_practice, case when (select kind from practices where id = p_practice) = 'sole' then 'sole_proprietor' else 'partnership' end, auth.uid())
    returning * into f;
  end if;
  if p ? 'entity_type' and coalesce(p->>'entity_type', '') not in ('partnership', 'llp', 'company', 'sole_proprietor') then
    raise exception 'Choose what the firm is: a partnership, an LLP, a company or a sole practitioner.';
  end if;
  v_tin := case when p ? 'tin' then nullif(regexp_replace(coalesce(p->>'tin', ''), '\s', '', 'g'), '') else f.tin end;
  if v_tin is not null and v_tin !~ '^[0-9][0-9-]{7,14}$' then raise exception 'Enter the firm''s Tax ID as digits, such as 12345678-0001.'; end if;
  if p ? 'note' and length(coalesce(p->>'note', '')) > 300 then raise exception 'Keep the note to 300 characters.'; end if;
  v_prices := f.prices;
  if p ? 'prices' then
    if jsonb_typeof(p->'prices') <> 'object' then raise exception 'Prices go by band.'; end if;
    select array_agg(x->>'key') into v_keys from jsonb_array_elements(private.audit_bands()) x;
    v_prices := '{}'::jsonb;
    for k, v in select key, value from jsonb_each_text(p->'prices') loop
      if not k = any(v_keys) then continue; end if;
      if nullif(trim(coalesce(v, '')), '') is null then continue; end if;
      if v !~ '^[0-9]+(\.[0-9]{1,2})?$' or v::numeric <= 0 or v::numeric > 100000000000 then
        raise exception 'Enter each price in naira, above zero.';
      end if;
      v_prices := v_prices || jsonb_build_object(k, round(v::numeric, 2));
    end loop;
  end if;
  update practice_audit_offers set
    entity_type = coalesce(nullif(p->>'entity_type', ''), entity_type), tin = v_tin,
    vat_registered = coalesce((p->>'vat_registered')::boolean, vat_registered), prices = v_prices,
    note = case when p ? 'note' then nullif(trim(p->>'note'), '') else note end,
    updated_by = auth.uid(), updated_at = now()
  where practice_id = p_practice;
  return public.practice_audit(p_practice);
end $$;

-- A partner switches audits on (every step done) or off. Requests already made carry on either way.
create or replace function public.practice_audit_switch(p_practice uuid, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare me public.practice_members; r jsonb;
begin
  me := private.practice_require(p_practice, true);
  if me.role <> 'partner' then raise exception 'Only a partner switches audits on or off.' using errcode = '42501'; end if;
  if coalesce(p_on, false) then
    r := private.audit_ready(p_practice);
    if not (r->>'ready')::boolean then
      raise exception 'Finish these first. %', (select string_agg(s->>'text' || '.', ' ') from jsonb_array_elements(r->'steps') s
        where not (s->>'done')::boolean);
    end if;
  end if;
  insert into practice_audit_offers (practice_id, active, updated_by) values (p_practice, coalesce(p_on, false), auth.uid())
  on conflict (practice_id) do update set active = excluded.active, updated_by = excluded.updated_by, updated_at = now();
  return public.practice_audit(p_practice);
end $$;

-- A partner or manager accepts a request (the business then pays) or declines it, with a note to the business.
create or replace function public.practice_audit_answer(p_engagement uuid, p_accept boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare e public.audit_engagements; pr public.practices; v_note text := nullif(left(trim(coalesce(p_note, '')), 500), '');
begin
  select * into e from audit_engagements where id = p_engagement for update;
  if not found or e.status <> 'requested' or e.practice_id is null then raise exception 'That request was withdrawn or answered.'; end if;
  perform private.practice_require(e.practice_id, true);
  select * into pr from practices where id = e.practice_id;
  if coalesce(p_accept, false) then
    if not (private.audit_ready(e.practice_id)->>'ready')::boolean then
      raise exception 'Finish setting up audits first: the business pays through Flutterwave to your bank account.';
    end if;
    update audit_engagements set status = 'accepted', answered_by = auth.uid(), answered_at = now(), answer_note = v_note, updated_at = now() where id = e.id;
    perform private.audit_notify_business(e.org_id, pr.name || ' will audit your ' || e.year || ' accounts',
      'Pay the fee in Counta to start: ' || private.naira(e.price) || case when e.vat_registered then ' plus VAT' else '' end || ', less withholding tax.');
  else
    update audit_engagements set status = 'declined', answered_by = auth.uid(), answered_at = now(), answer_note = v_note, ended_at = now(), updated_at = now()
    where id = e.id;
    perform private.audit_notify_business(e.org_id, pr.name || ' cannot audit your ' || e.year || ' accounts',
      coalesce(v_note || ' ', '') || 'Choose another firm in Counta.');
  end if;
  perform private.activity_event(e.org_id, case when p_accept then 'audit_accepted' else 'audit_declined' end,
    pr.name || case when p_accept then ' accepted' else ' declined' end || ' the ' || e.year || ' audit', jsonb_build_object('engagement_id', e.id));
  return public.practice_audit(e.practice_id);
end $$;

-- Before the audits function sets up the firm's Flutterwave split: a partner, with a confirmed bank account.
create or replace function public.practice_audit_flutterwave_check(p_practice uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare me public.practice_members; b public.practice_payout_accounts;
begin
  me := private.practice_require(p_practice, true);
  if me.role <> 'partner' then raise exception 'Only a partner sets up payments for audits.' using errcode = '42501'; end if;
  select * into b from practice_payout_accounts where practice_id = p_practice;
  if b.practice_id is null then raise exception 'Add the bank account first, under Earnings.'; end if;
  if not b.name_match then raise exception 'The bank holds that account in another name. Use an account in the practice''s or a partner''s name.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- 6. Paying: the bill, the checkout record, and what Flutterwave confirms
-- ---------------------------------------------------------------------------
-- The business starts paying an accepted audit. The bill from the firm is entered (a draft until the payment is confirmed)
-- and works out the withholding tax; the checkout charges the fee and its VAT less that tax. Returns the checkout record.
create or replace function public.audit_pay_start(p_engagement uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare e public.audit_engagements; m public.members; o public.orgs; pr public.practices; f public.practice_audit_offers; b public.bills;
  v_to date; v_code text; v_amount numeric; v_ref text; v_referral numeric;
begin
  select * into e from audit_engagements where id = p_engagement for update;
  if not found then raise exception 'Audit not found.'; end if;
  m := private.require(e.org_id, null);
  if not private.audit_can_act(m) then raise exception 'The owner or an admin of the business pays for the audit.' using errcode = '42501'; end if;
  if e.status = 'paid' then raise exception 'This audit is paid for already.'; end if;
  if e.status <> 'accepted' or e.kind <> 'partner' then raise exception 'Pay once the firm has agreed to do the audit.'; end if;
  select * into o from orgs where id = e.org_id;
  if o.read_only_at is not null then raise exception 'This business is read-only.'; end if;
  select * into pr from practices where id = e.practice_id;
  select * into f from practice_audit_offers where practice_id = e.practice_id;
  if pr.id is null or not (private.audit_ready(e.practice_id)->>'ready')::boolean then
    raise exception '% cannot take payments through Counta right now. Try again later, or ask the firm.', coalesce(pr.name, 'The firm');
  end if;
  select pto into v_to from private.cit_period(e.org_id, e.year);
  v_code := case when private.bill_account_ok(e.org_id, '6501') then '6501' else private.acct(e.org_id, 'expenses_default') end;
  b := private.write_bill(e.org_id, jsonb_build_object(
      'id', (select id from bills where id = e.bill_id and status = 'draft'),
      'bill_date', private.local_day(e.org_id, now()), 'vendor_ref', 'AUDIT-' || e.year, 'source', 'audit',
      'vat_charged', coalesce(e.vat_registered, false), 'prices_include_vat', false, 'wht_category', 'professional',
      'notes', 'Audit of the ' || e.year || ' accounts, agreed in Counta and paid at Counta''s checkout less withholding tax.',
      'vendor', jsonb_build_object('name', pr.name, 'tin', f.tin, 'email', pr.email, 'phone', pr.phone, 'wht_category', 'professional',
        'entity_type', f.entity_type, 'is_individual', f.entity_type = 'sole_proprietor', 'state', pr.state, 'address', pr.address),
      'lines', jsonb_build_array(jsonb_build_object('description', 'Audit of the financial statements for the year ended ' || private.fdate(v_to),
        'qty', 1, 'unit_cost', e.price, 'account_code', v_code, 'vat_treatment', case when coalesce(e.vat_registered, false) then 'standard' else 'none' end))), m);
  v_amount := b.total - b.wht_expected - b.wvat_expected;
  v_referral := round(e.price * coalesce(e.referral_rate, 0), 2);
  if v_amount <= v_referral then
    raise exception 'After withholding tax the payment would not cover TaxStreem''s referral fee. Ask TaxStreem to look at this audit.';
  end if;
  update audit_engagements set bill_id = b.id, vat = b.vat_total, wht = b.wht_expected, wvat = b.wvat_expected, amount = v_amount, referral = v_referral,
    updated_at = now()
  where id = e.id;
  v_ref := 'AUD-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16));
  insert into audit_charges (engagement_id, org_id, practice_id, tx_ref, amount, referral, subaccount_ref, created_by)
  values (e.id, e.org_id, e.practice_id, v_ref, v_amount, v_referral, f.subaccount_ref, auth.uid());
  return jsonb_build_object('tx_ref', v_ref, 'amount', v_amount, 'fee', e.price, 'vat', b.vat_total, 'wht', b.wht_expected, 'wvat', b.wvat_expected,
    'bill', b.number);
end $$;

-- What the audits function needs for a checkout or a check: the charge, the business, the firm.
create or replace function public.svc_audit_charge(p_tx_ref text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare c public.audit_charges; e public.audit_engagements; o public.orgs; pr public.practices;
begin
  select * into c from audit_charges where tx_ref = p_tx_ref;
  if not found then return null; end if;
  select * into e from audit_engagements where id = c.engagement_id;
  select * into o from orgs where id = c.org_id;
  select * into pr from practices where id = c.practice_id;
  return jsonb_build_object('charge', to_jsonb(c), 'engagement', jsonb_build_object('id', e.id, 'year', e.year, 'status', e.status, 'price', e.price),
    'org', jsonb_build_object('id', o.id, 'name', o.name, 'phone', o.phone,
      'email', coalesce(o.email, (select u.email from auth.users u where u.id = (private.org_contact(o.id)).user_id))),
    'firm', jsonb_build_object('id', pr.id, 'name', pr.name),
    'description', left('Audit of the ' || e.year || ' accounts by ' || coalesce(pr.name, 'the firm'), 120),
    'return_path', case when o.filing_only then '/filing' else '/tax/cit' end);
end $$;

-- What Flutterwave confirmed for a checkout. Paid: the bill is approved in the business's books (when its month is open; else
-- it stays a draft and the engagement says why), the engagement is paid, and both sides hear of it. A second payment for an
-- engagement already paid is kept and marked for TaxStreem to refund.
create or replace function public.svc_audit_charge_update(p_tx_ref text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare c public.audit_charges; e public.audit_engagements; m public.members; v_status text := p->>'status'; v_err text; v_actor text; v_org text; v_firm text;
begin
  select * into c from audit_charges where tx_ref = p_tx_ref for update;
  if not found then raise exception 'Unknown payment.'; end if;
  if c.status = 'successful' then return jsonb_build_object('status', 'successful', 'engagement_id', c.engagement_id); end if;
  if v_status not in ('successful', 'failed', 'cancelled') then raise exception 'Unknown status.'; end if;
  if v_status <> 'successful' then
    update audit_charges set status = v_status, error = nullif(left(coalesce(p->>'error', ''), 300), ''),
      provider_ref = coalesce(nullif(p->>'provider_ref', ''), provider_ref), updated_at = now()
    where id = c.id;
    return jsonb_build_object('status', v_status, 'engagement_id', c.engagement_id);
  end if;
  if coalesce(private.num(p->>'paid_amount'), 0) < c.amount then
    raise exception 'Flutterwave confirmed % but % was due.', private.naira(coalesce(private.num(p->>'paid_amount'), 0)), private.naira(c.amount);
  end if;
  update audit_charges set status = 'successful', paid_amount = round(private.num(p->>'paid_amount'), 2), fee = round(private.num(p->>'fee'), 2),
    provider_ref = coalesce(nullif(p->>'provider_ref', ''), provider_ref), error = null, paid_at = now(), updated_at = now()
  where id = c.id returning * into c;
  select * into e from audit_engagements where id = c.engagement_id for update;
  if e.status = 'paid' then
    update audit_charges set error = 'Paid twice: TaxStreem refunds this payment.' where id = c.id;
    return jsonb_build_object('status', 'successful', 'engagement_id', e.id, 'duplicate', true);
  end if;
  -- Paid after the business withdrew and chose another auditor for the year: kept for TaxStreem to refund.
  if e.status <> 'accepted' and exists (select 1 from audit_engagements a where a.org_id = e.org_id and a.year = e.year and a.id <> e.id
      and a.status in ('requested', 'accepted', 'paid', 'recorded')) then
    update audit_charges set error = 'Paid after the request was withdrawn: TaxStreem refunds this payment.' where id = c.id;
    return jsonb_build_object('status', 'successful', 'engagement_id', e.id, 'duplicate', true);
  end if;
  select name into v_org from orgs where id = e.org_id;
  select name into v_firm from practices where id = e.practice_id;
  v_actor := current_setting('counta.actor', true);
  begin
    select * into m from members where org_id = e.org_id and user_id = c.created_by and status = 'active';
    if m.id is null then m := private.org_contact(e.org_id); end if;
    if m.id is null then raise exception 'Nobody can approve the bill in the business.'; end if;
    perform private.set_actor(m.user_id);
    if (select status from bills where id = e.bill_id) is distinct from 'draft' then
      raise exception 'The bill for the audit was changed by hand; check it under Bills.';
    end if;
    perform private.require_open_day(e.org_id, (select bill_date from bills where id = e.bill_id));
    perform private.post_bill(e.bill_id, m);
  exception when others then
    v_err := left(sqlerrm, 300);
  end;
  perform set_config('counta.actor', coalesce(v_actor, ''), true);
  update audit_engagements set status = case when e.status in ('accepted', 'cancelled') then 'paid' else e.status end, paid_at = now(), bill_error = v_err,
    ended_at = null, updated_at = now()
  where id = e.id returning * into e;
  perform private.activity_event(e.org_id, 'audit_paid', 'Paid ' || coalesce(v_firm, 'the firm') || ' for the ' || e.year || ' audit',
    jsonb_build_object('engagement_id', e.id, 'tx_ref', c.tx_ref, 'amount', c.paid_amount, 'bill_error', v_err));
  perform private.audit_notify_business(e.org_id, 'The ' || e.year || ' audit is paid for',
    private.naira(c.paid_amount) || ' to ' || coalesce(v_firm, 'the firm') || '. '
      || case when v_err is null then 'The bill is in your books with the withholding tax you owe on it.' else 'The bill is still a draft: ' || v_err end);
  if e.practice_id is not null then
    perform private.practice_notify(e.practice_id, v_org || ' paid for the ' || e.year || ' audit',
      private.naira(c.paid_amount) || ' paid. Your bank receives it less TaxStreem''s referral fee (' || private.naira(c.referral)
        || ') and Flutterwave''s charge. The business deducted ' || private.naira(e.wht) || ' withholding tax.', '/practice/audits');
  end if;
  return jsonb_build_object('status', 'successful', 'engagement_id', e.id, 'bill_error', v_err);
end $$;

-- Checkouts still open, for the five-minute poll (and older than a day: given up).
create or replace function public.svc_audit_open() returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('tx_ref', tx_ref, 'age_minutes', floor(extract(epoch from now() - created_at) / 60)) order by created_at), '[]'::jsonb)
  from audit_charges where status = 'pending' and created_at < now() - interval '2 minutes'
$$;

-- The firm's details and bank account, for setting up its Flutterwave split.
create or replace function public.svc_audit_subaccount(p_practice uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare pr public.practices; f public.practice_audit_offers; b public.practice_payout_accounts;
begin
  select * into pr from practices where id = p_practice;
  select * into f from practice_audit_offers where practice_id = p_practice;
  select * into b from practice_payout_accounts where practice_id = p_practice;
  if pr.id is null or b.practice_id is null then return null; end if;
  return jsonb_build_object('practice', jsonb_build_object('id', pr.id, 'name', pr.name, 'email', pr.email, 'phone', pr.phone),
    'bank', jsonb_build_object('bank_code', b.bank_code, 'account_number', b.account_number, 'account_name', b.account_name, 'name_match', b.name_match),
    'subaccount', jsonb_build_object('ref', f.subaccount_ref, 'num', f.subaccount_num, 'bank', f.subaccount_bank, 'account', f.subaccount_account,
      'status', coalesce(f.subaccount_status, 'none')),
    'referral_rate', coalesce((private.audit_settings()->>'referral_rate')::numeric, 0));
end $$;

-- Records what Flutterwave did with the firm's split: ready (with its reference and the account it settles to) or failed.
create or replace function public.svc_audit_subaccount_save(p_practice uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  if coalesce(p->>'status', '') not in ('ready', 'failed') then raise exception 'Unknown status.'; end if;
  insert into practice_audit_offers (practice_id, entity_type, subaccount_status) values (p_practice,
    case when (select kind from practices where id = p_practice) = 'sole' then 'sole_proprietor' else 'partnership' end, p->>'status')
  on conflict (practice_id) do nothing;
  update practice_audit_offers set subaccount_status = p->>'status',
    subaccount_ref = case when p->>'status' = 'ready' then p->>'ref' else subaccount_ref end,
    subaccount_num = case when p->>'status' = 'ready' then nullif(p->>'num', '')::bigint else subaccount_num end,
    subaccount_bank = case when p->>'status' = 'ready' then p->>'bank' else subaccount_bank end,
    subaccount_account = case when p->>'status' = 'ready' then p->>'account' else subaccount_account end,
    subaccount_error = case when p->>'status' = 'failed' then left(coalesce(p->>'error', 'Flutterwave said no.'), 300) end,
    subaccount_at = now(), updated_at = now()
  where practice_id = p_practice;
  return private.audit_ready(p_practice);
end $$;

-- ---------------------------------------------------------------------------
-- 7. Daily: requests that lapse, and companies told their accounts need an audit
-- ---------------------------------------------------------------------------
create or replace function private.audit_tick() returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s jsonb := private.audit_settings(); e public.audit_engagements; o record; y int; v_cur int; v jsonb; v_lapsed int := 0; v_told int := 0;
  v_org text; v_firm text;
begin
  for e in select * from audit_engagements where status = 'requested'
             and requested_at < now() - make_interval(days => coalesce((s->>'request_days')::int, 7)) for update skip locked loop
    update audit_engagements set status = 'lapsed', ended_at = now(), updated_at = now() where id = e.id;
    select name into v_org from orgs where id = e.org_id;
    select name into v_firm from practices where id = e.practice_id;
    perform private.audit_notify_business(e.org_id, coalesce(v_firm, 'The firm') || ' did not answer your audit request',
      'Choose another firm for the ' || e.year || ' accounts.');
    if e.practice_id is not null then
      perform private.practice_notify(e.practice_id, 'The request to audit ' || v_org || ' lapsed', 'It was not answered in time.', '/practice/audits');
    end if;
    v_lapsed := v_lapsed + 1;
  end loop;
  if not coalesce((s->>'enabled')::boolean, false) then return jsonb_build_object('lapsed', v_lapsed, 'told', 0); end if;
  -- Companies with books in use this year or last: the year running and the one before, unless already told, already
  -- audited or asked, or its return filed.
  for o in select x.id from orgs x where not x.is_sample and x.read_only_at is null and coalesce(x.legal_form, 'company') in ('company', 'ngo')
             and exists (select 1 from journals j where j.org_id = x.id and j.created_at > now() - interval '400 days') loop
    v_cur := private.cit_year_of(o.id, private.local_day(o.id, now()));
    for y in select generate_series(v_cur - 1, v_cur) loop
      continue when exists (select 1 from audit_notices n where n.org_id = o.id and n.year = y);
      continue when exists (select 1 from audit_engagements a where a.org_id = o.id and a.year = y and a.status in ('requested', 'accepted', 'paid', 'recorded'));
      continue when exists (select 1 from cit_years c where c.org_id = o.id and c.accounting_year = y and c.filed_at is not null);
      begin
        v := private.audit_need(o.id, y);
      exception when others then
        continue;
      end;
      continue when not coalesce((v->>'required')::boolean, false);
      insert into audit_notices (org_id, year) values (o.id, y) on conflict do nothing;
      perform private.audit_notify_business(o.id, 'Your ' || y || ' accounts need an audit',
        case when (v->>'over_turnover')::boolean then 'Turnover of ' || private.naira((v->>'turnover')::numeric) || ' is above the small company limit of '
          || private.naira((v->>'turnover_max')::numeric) else 'Fixed assets of ' || private.naira((v->>'fixed_assets')::numeric)
          || ' are above the small company limit of ' || private.naira((v->>'fixed_assets_max')::numeric) end
          || '. Choose a TaxStreem partner firm to audit them, or tell Counta who your auditor is.');
      v_told := v_told + 1;
    end loop;
  end loop;
  return jsonb_build_object('lapsed', v_lapsed, 'told', v_told);
end $$;

-- ---------------------------------------------------------------------------
-- 8. TaxStreem: settings, firms, engagements and payments; FRC checks
-- ---------------------------------------------------------------------------
create or replace function public.admin_audits() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_staff(true);
  return jsonb_build_object('settings', private.audit_settings(), 'bands', private.audit_bands(),
    'firms', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'state', p.state, 'entity_type', f.entity_type, 'tin', f.tin,
        'vat_registered', f.vat_registered, 'prices', f.prices, 'flutterwave', jsonb_build_object('status', f.subaccount_status, 'ref', f.subaccount_ref,
          'error', f.subaccount_error, 'at', f.subaccount_at), 'ready', private.audit_ready(p.id)) order by p.name), '[]'::jsonb)
      from practices p join practice_audit_offers f on f.practice_id = p.id),
    'engagements', (select coalesce(jsonb_agg(private.audit_engagement_json(e, true) || jsonb_build_object('charges',
        (select coalesce(jsonb_agg(jsonb_build_object('tx_ref', c.tx_ref, 'status', c.status, 'amount', c.amount, 'referral', c.referral,
          'paid_amount', c.paid_amount, 'fee', c.fee, 'error', c.error, 'at', c.created_at, 'paid_at', c.paid_at) order by c.created_at), '[]'::jsonb)
         from audit_charges c where c.engagement_id = e.id)) order by e.created_at desc), '[]'::jsonb)
      from (select * from audit_engagements where kind = 'partner' order by created_at desc limit 200) e),
    'totals', (select jsonb_build_object('paid', count(*) filter (where e.status = 'paid'),
        'fees', coalesce(sum(e.price) filter (where e.status = 'paid'), 0),
        'referral', coalesce(sum(e.referral) filter (where e.status = 'paid'), 0),
        'waiting', count(*) filter (where e.status in ('requested', 'accepted')),
        'refunds', (select count(*) from audit_charges c where c.status = 'successful' and c.error like 'Paid twice%'))
      from audit_engagements e where e.kind = 'partner'));
end $$;

-- enabled, referral_rate (0 to 50%), request_days (1 to 30), bands (1 to 8 upper ends, rising). A rate changed here applies to
-- requests made from now on.
create or replace function public.admin_audit_settings_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v jsonb := private.audit_settings(); r numeric; d int; b jsonb; x text; v_last numeric := 0;
begin
  perform private.require_staff(true);
  if p ? 'enabled' then v := v || jsonb_build_object('enabled', coalesce((p->>'enabled')::boolean, true)); end if;
  if p ? 'referral_rate' then
    r := private.num(p->>'referral_rate');
    if r is null or r < 0 or r > 0.5 then raise exception 'The referral fee is between 0%% and 50%%.'; end if;
    v := v || jsonb_build_object('referral_rate', round(r, 4));
  end if;
  if p ? 'request_days' then
    d := nullif(p->>'request_days', '')::int;
    if d is null or d < 1 or d > 30 then raise exception 'Firms have between 1 and 30 days to answer.'; end if;
    v := v || jsonb_build_object('request_days', d);
  end if;
  if p ? 'bands' then
    if jsonb_typeof(p->'bands') <> 'array' or jsonb_array_length(p->'bands') not between 1 and 8 then raise exception 'Give between 1 and 8 bands.'; end if;
    b := '[]'::jsonb;
    for x in select value from jsonb_array_elements_text(p->'bands') loop
      if private.num(x) is null or round(private.num(x)) <= v_last then raise exception 'Each band''s upper end must be above the one before.'; end if;
      v_last := round(private.num(x));
      b := b || to_jsonb(v_last);
    end loop;
    v := v || jsonb_build_object('bands', b);
  end if;
  insert into platform_settings (key, value, updated_by, updated_at) values ('audits', v, auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
  perform private.audit('audit_settings', 'audits', v);
  return public.admin_audits();
end $$;

create or replace function public.admin_frc_decide(p_member uuid, p_status text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.practice_members;
begin
  perform private.require_staff(false);
  if p_status not in ('verified', 'rejected') then raise exception 'Verify or reject.'; end if;
  if p_status = 'rejected' and length(trim(coalesce(p_note, ''))) < 5 then raise exception 'Say why, so the accountant can put it right.'; end if;
  update practice_members set frc_status = p_status, frc_note = nullif(left(trim(p_note), 300), ''), frc_verified_by = auth.uid(), frc_verified_at = now()
  where id = p_member and frc_no is not null returning * into m;
  if not found then raise exception 'That accountant has no FRC number to check.'; end if;
  perform private.audit('frc_' || p_status, m.id::text, jsonb_build_object('practice_id', m.practice_id, 'number', m.frc_no, 'note', p_note));
  if m.user_id is not null then
    perform private.notify(null, m.user_id, 'practice',
      case when p_status = 'verified' then 'TaxStreem verified your FRC number' else 'TaxStreem could not confirm your FRC number' end,
      case when p_status = 'rejected' then left(p_note, 200)
        when m.licence_body in ('ICAN', 'ANAN') and m.licence_status = 'verified' then 'You can sign audits through Counta. Set them up under Audits.'
        else 'Audits also need your ICAN or ANAN number verified.' end, '/practice/audits', null);
  end if;
  return jsonb_build_object('id', m.id, 'frc_status', m.frc_status);
end $$;

-- ---------------------------------------------------------------------------
-- 9. Schedules and grants
-- ---------------------------------------------------------------------------
-- Daily at 06:35 UTC: lapsed requests and audit notices. Every five minutes while a checkout is open: the audits function
-- asks Flutterwave about it.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname in ('counta-audits', 'counta-audit-payments');
    perform cron.schedule('counta-audits', '35 6 * * *', 'select private.audit_tick()');
    perform cron.schedule('counta-audit-payments', '*/5 * * * *', $c$select private.call_function('audits', '{"action":"poll"}'::jsonb)
      where exists (select 1 from public.audit_charges where status = 'pending')$c$);
  end if;
end $$;

-- Changes to a business's audits are in its activity log, like its other records.
select private.activity_attach('public.audit_engagements');
select private.activity_attach('public.audit_charges');
select private.activity_attach('public.audit_notices');

revoke all on function private.audit_defaults(), private.audit_settings(), private.audit_naira(numeric), private.audit_bands(), private.audit_band(numeric),
  private.audit_signers(uuid), private.audit_ready(uuid), private.audit_firm_public(uuid, text), private.audit_need(uuid, integer),
  private.audit_engagement_json(public.audit_engagements, boolean), private.audit_notify_business(uuid, text, text), private.audit_can_act(public.members),
  private.audit_tick() from public, anon, authenticated;

revoke all on function public.audit_state(uuid, integer), public.audit_firms(uuid, integer), public.audit_request(uuid, integer, uuid, jsonb),
  public.audit_own(uuid, integer, jsonb), public.audit_cancel(uuid), public.audit_pay_start(uuid), public.practice_audit(uuid),
  public.practice_audit_save(uuid, jsonb), public.practice_audit_switch(uuid, boolean), public.practice_audit_answer(uuid, boolean, text),
  public.practice_audit_flutterwave_check(uuid), public.admin_audits(), public.admin_audit_settings_save(jsonb),
  public.admin_frc_decide(uuid, text, text) from public, anon;
grant execute on function public.audit_state(uuid, integer), public.audit_firms(uuid, integer), public.audit_request(uuid, integer, uuid, jsonb),
  public.audit_own(uuid, integer, jsonb), public.audit_cancel(uuid), public.audit_pay_start(uuid), public.practice_audit(uuid),
  public.practice_audit_save(uuid, jsonb), public.practice_audit_switch(uuid, boolean), public.practice_audit_answer(uuid, boolean, text),
  public.practice_audit_flutterwave_check(uuid), public.admin_audits(), public.admin_audit_settings_save(jsonb),
  public.admin_frc_decide(uuid, text, text) to authenticated;

revoke all on function public.svc_audit_charge(text), public.svc_audit_charge_update(text, jsonb), public.svc_audit_open(),
  public.svc_audit_subaccount(uuid), public.svc_audit_subaccount_save(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.svc_audit_charge(text), public.svc_audit_charge_update(text, jsonb), public.svc_audit_open(),
  public.svc_audit_subaccount(uuid), public.svc_audit_subaccount_save(uuid, jsonb) to service_role;
