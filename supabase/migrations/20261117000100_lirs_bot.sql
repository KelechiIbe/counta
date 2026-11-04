-- Counta · personal income tax filed on LIRS e-Tax by Counta's own bot (docs/lirs-etax-bot.md)
--
-- TaxStreem files personal income tax on LIRS e-Tax itself, with each taxpayer's own e-Tax login and as the taxpayer,
-- without Flux. A bot (bots/lirs, on Google Cloud Run) takes jobs from public.lirs_jobs through the taxstreem function,
-- signs in to e-Tax, files the approved return, raises the bill, fetches the transfer account when someone pays, and checks
-- the Lagos State payments page until the bill shows paid.
--
-- 1. Data: each person's e-Tax login (the password in Supabase Vault, never in a table), their household staff for the
--    year, the bot's record of the return on e-Tax, and the job queue.
-- 2. What each relief needs, now as e-Tax's relief forms ask (life assurance: the company, the policy and three documents;
--    mortgage interest: the lender, the capital sum, a utility bill and the bank statements). Gratuity and rent relief have
--    no section on e-Tax: Counta computes them and keeps them on record, and does not post them.
-- 3. The year's computation, a person's year and the pack, with the above.
-- 4. Logins, jobs and the bot's service functions; the database wakes the bot every five minutes while a job is due.
-- Companies are not touched. Safe to run more than once.


-- ---------------------------------------------------------------------------
-- 1. Data
-- ---------------------------------------------------------------------------
-- household_staff: the person's own household staff for the year, for e-Tax's support staff section (kept on their e-Tax
--   profile): [{role: driver | cook | security | cleaner | gardener | other, registered, payer_id, name, address, income_paid}].
--   A registered member of staff is named by their Payer ID; anyone else by name and home address.
-- portal: what the bot recorded on e-Tax: {tax_payer_id, return_id, steps: {step: at}, bill_id, confirmed_at}.
alter table public.pit_person_years
  add column if not exists household_staff jsonb not null default '[]'::jsonb,
  add column if not exists portal jsonb not null default '{}'::jsonb;

-- Each person's own login to their state's portal (LIRS e-Tax): the Payer ID they sign in with, and the password as a
-- Supabase Vault secret (secret_id). Nobody reads the password back through the app; only the bot gets it, with its job.
-- tax_station: the e-Tax agency code of the person's tax station for bills (found by the bot from the profile, or chosen).
create table if not exists public.pit_etax_logins (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  person_id uuid not null references public.pit_people(id) on delete cascade,
  authority text not null default 'SIRS:LA' references public.tax_authorities(code),
  payer_id text not null check (payer_id ~ '^[NC]-[0-9]{4,12}$'),
  secret_id uuid,
  tax_station text check (tax_station is null or tax_station ~ '^[0-9]{3,10}$'),
  tax_station_name text check (tax_station_name is null or length(tax_station_name) <= 120),
  status text not null default 'saved' check (status in ('saved', 'verified', 'failed')),
  message text check (message is null or length(message) <= 1000),
  saved_by uuid references public.members(id) on delete set null,
  saved_at timestamptz not null default now(),
  checked_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (org_id, person_id, authority)
);
create index if not exists pit_etax_logins_person_fk on public.pit_etax_logins(person_id);
create index if not exists pit_etax_logins_authority_fk on public.pit_etax_logins(authority);
create index if not exists pit_etax_logins_saved_by_fk on public.pit_etax_logins(saved_by);
alter table public.pit_etax_logins enable row level security;
revoke all on public.pit_etax_logins from anon, authenticated;

-- The bot's work. kind: file (the return, up to Confirm), bill (raise the pay bill), pay_account (fetch the one-time
-- transfer account for the bill), status (check whether e-Tax shows the bill paid). One open job per person and kind.
-- log: [{at, step, note}] without secrets or personal identifiers.
create table if not exists public.lirs_jobs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  accounting_year int not null,
  person_id uuid not null references public.pit_people(id) on delete cascade,
  kind text not null check (kind in ('file', 'bill', 'pay_account', 'status')),
  status text not null default 'queued' check (status in ('queued', 'running', 'done', 'failed', 'cancelled')),
  request jsonb not null default '{}'::jsonb,
  result jsonb,
  error text check (error is null or length(error) <= 2000),
  attempts int not null default 0,
  max_attempts int not null default 3,
  not_before timestamptz not null default now(),
  locked_at timestamptz,
  worker text check (worker is null or length(worker) <= 120),
  log jsonb not null default '[]'::jsonb,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists lirs_jobs_due on public.lirs_jobs(status, not_before) where status in ('queued', 'running');
create index if not exists lirs_jobs_person on public.lirs_jobs(org_id, accounting_year, person_id, created_at desc);
create index if not exists lirs_jobs_person_fk on public.lirs_jobs(person_id);
create index if not exists lirs_jobs_created_by_fk on public.lirs_jobs(created_by);
create unique index if not exists lirs_jobs_one_open on public.lirs_jobs(org_id, accounting_year, person_id, kind) where status in ('queued', 'running');
alter table public.lirs_jobs enable row level security;
revoke all on public.lirs_jobs from anon, authenticated;

-- The states Counta's own bot files. Flux files the rule book's other states, if any.
create or replace function private.pit_bot_authorities() returns text[]
language sql immutable set search_path = '' as $$ select array['SIRS:LA'] $$;

-- e-Tax's relation types for household staff.
create or replace function private.pit_staff_roles() returns jsonb
language sql immutable set search_path = '' as $$
  select '{"other": {"type_id": 18, "label": "Other support staff"}, "driver": {"type_id": 19, "label": "Driver"}, "cook": {"type_id": 20, "label": "Cook"},
           "security": {"type_id": 21, "label": "Security"}, "cleaner": {"type_id": 22, "label": "Cleaner"}, "gardener": {"type_id": 23, "label": "Gardener"}}'::jsonb
$$;

-- ---------------------------------------------------------------------------
-- 2. What each relief needs before it is claimed, as e-Tax's relief forms ask
-- ---------------------------------------------------------------------------
-- docs: the files e-Tax asks for (each goes in its own field of the form); fields: details kept with the person's year
-- (pension_details) that the form asks for; portal: e-Tax's relief type, or false where e-Tax has no section (computed
-- and kept on record, not posted).
create or replace function private.pit_relief_needs() returns jsonb
language sql immutable set search_path = '' as $$
  select '{
    "pension": {"label": "Pension contributions", "portal": 3, "fields": ["rsa_number", "pfa"],
      "docs": [{"id": "rsa_statement", "label": "Retirement savings account (RSA) statement for the year", "portal_field": "rsaStatementForYear"}]},
    "nhis": {"label": "Health insurance", "portal": 2,
      "docs": [{"id": "policy", "label": "Health insurance policy and evidence of payment", "portal_field": "policyDocument"}]},
    "life_insurance": {"label": "Life insurance or deferred annuity", "portal": 1, "fields": ["life_company", "life_policy"],
      "docs": [{"id": "policy", "label": "Life insurance policy", "portal_field": "policyDocument"},
               {"id": "premium_certificate", "label": "Certificate of premium paid in the year", "portal_field": "certificateOfPremium"},
               {"id": "receipt", "label": "Receipt of payment", "portal_field": "receiptOfPayment"}]},
    "home_loan_interest": {"label": "Mortgage interest", "portal": 6, "fields": ["mortgage_institution", "mortgage_capital"],
      "docs": [{"id": "utility_bill", "label": "Utility bill for the home", "portal_field": "utilityBillForTheResidence"},
               {"id": "bank_statements", "label": "Bank statements showing the mortgage deductions", "portal_field": "bankStatementsReflectingMortgageDeductions"}]},
    "nhf": {"label": "National Housing Fund", "portal": 5,
      "docs": [{"id": "nhf_statement", "label": "National Housing Fund contribution statement", "portal_field": "policyDocument"}]},
    "gratuity": {"label": "Gratuity", "portal": false, "docs": [{"id": "gratuity_statement", "label": "Statement of the gratuity contributions"}]},
    "rent_paid": {"label": "Rent relief", "portal": false, "docs": [], "accommodation": true}
  }'::jsonb
$$;

-- What each detail is called when it is missing.
create or replace function private.pit_relief_field_label(p_field text) returns text
language sql immutable set search_path = '' as $$
  select case p_field when 'rsa_number' then 'the RSA number' when 'pfa' then 'the pension fund administrator'
    when 'life_company' then 'the insurance company' when 'life_policy' then 'the policy name'
    when 'mortgage_institution' then 'the mortgage lender' when 'mortgage_capital' then 'the capital sum on the mortgage' else replace(p_field, '_', ' ') end
$$;

-- The reliefs a person can claim now: {claimed: {relief: amount}, held: [{relief, label, amount, missing: [what]}]}.
-- p_pension: the person's relief details (pension_details): {rsa_number, pfa, life_company, life_policy,
-- mortgage_institution, mortgage_capital}.
create or replace function private.pit_relief_check(p_reliefs jsonb, p_docs jsonb, p_pension jsonb, p_acc jsonb) returns jsonb
language plpgsql immutable set search_path = public, private as $$
declare n jsonb := private.pit_relief_needs(); k text; v numeric; need jsonb; d jsonb; f text; miss text[]; v_claimed jsonb := '{}'::jsonb; v_held jsonb := '[]'::jsonb;
begin
  for k, v in select key, private.num(value #>> '{}') from jsonb_each(coalesce(p_reliefs, '{}'::jsonb)) loop
    continue when coalesce(v, 0) <= 0;
    need := n->k; miss := '{}';
    if need is null then v_claimed := v_claimed || jsonb_build_object(k, v); continue; end if;
    for d in select value from jsonb_array_elements(coalesce(need->'docs', '[]'::jsonb)) loop
      if not exists (select 1 from jsonb_array_elements(case when jsonb_typeof(p_docs->k) = 'array' then p_docs->k else '[]'::jsonb end) x
                     where x->>'doc' = d->>'id' and coalesce(x->>'path', '') <> '') then
        miss := miss || (d->>'label');
      end if;
    end loop;
    for f in select jsonb_array_elements_text(coalesce(need->'fields', '[]'::jsonb)) loop
      if coalesce(trim(coalesce(p_pension, '{}'::jsonb)->>f), '') = '' then miss := miss || private.pit_relief_field_label(f); end if;
    end loop;
    if coalesce((need->>'accommodation')::boolean, false) and not private.pit_accommodation_ok(coalesce(p_acc, '{}'::jsonb), true) then
      miss := miss || 'the accommodation details of a tenant (landlord, address, rent, dates)'::text;
    end if;
    if cardinality(miss) = 0 then v_claimed := v_claimed || jsonb_build_object(k, v);
    else v_held := v_held || jsonb_build_array(jsonb_build_object('relief', k, 'label', need->>'label', 'amount', v, 'missing', to_jsonb(miss))); end if;
  end loop;
  return jsonb_build_object('claimed', v_claimed, 'held', v_held);
end $$;

-- A person's e-Tax login as the screens show it: never the password.
create or replace function private.pit_etax_login_of(p_org uuid, p_person uuid, p_authority text) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('payer_id', l.payer_id, 'status', l.status, 'message', l.message, 'tax_station', l.tax_station,
    'tax_station_name', l.tax_station_name, 'saved_at', l.saved_at, 'checked_at', l.checked_at,
    'saved_by', (select display_name from members where id = l.saved_by))
  from pit_etax_logins l where l.org_id = p_org and l.person_id = p_person and l.authority = coalesce(p_authority, 'SIRS:LA')
$$;

-- The latest job of each kind for a person, as the screens show it.
create or replace function private.pit_jobs_of(p_org uuid, p_year int, p_person uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_object_agg(j.kind, jsonb_build_object('id', j.id, 'status', j.status, 'error', j.error, 'attempts', j.attempts,
      'request', j.request - 'secret', 'created_at', j.created_at, 'updated_at', j.updated_at, 'finished_at', j.finished_at,
      'step', j.log->-1->>'step', 'note', j.log->-1->>'note')), '{}'::jsonb)
  from (select distinct on (kind) * from lirs_jobs where org_id = p_org and accounting_year = p_year and person_id = p_person
        order by kind, created_at desc) j
$$;


-- ---------------------------------------------------------------------------
-- 3. The year with the bot's states, the household staff and the e-Tax logins
-- ---------------------------------------------------------------------------

-- The people in a year, with the accommodation, pension details and relief documents. Where a person has not entered
-- the year's accommodation, last year's home carries on (without its rent), unless they moved out of it.
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
      'accommodation', case when coalesce((x.yr).accommodation, '{}'::jsonb) <> '{}'::jsonb then (x.yr).accommodation
        when coalesce((x.prev).accommodation->>'ended_on', '') = '' then coalesce((x.prev).accommodation, '{}'::jsonb) - 'rent_paid' - 'rent_paid_by_employer'
        else '{}'::jsonb end,
      'accommodation_carried', coalesce((x.yr).accommodation, '{}'::jsonb) = '{}'::jsonb and coalesce((x.prev).accommodation, '{}'::jsonb) <> '{}'::jsonb
        and coalesce((x.prev).accommodation->>'ended_on', '') = '',
      'pension_details', coalesce(nullif((x.yr).pension_details, '{}'::jsonb), (x.prev).pension_details, '{}'::jsonb),
      'relief_docs', coalesce((x.yr).relief_docs, '{}'::jsonb),
      'household_staff', case when (x.yr).person_id is not null then coalesce((x.yr).household_staff, '[]'::jsonb) else coalesce((x.prev).household_staff, '[]'::jsonb) end,
      'portal', coalesce((x.yr).portal, '{}'::jsonb), 'etax_login', private.pit_etax_login_of(p_org, x.id, 'SIRS:LA'),
      'status', coalesce((x.yr).status, 'draft'), 'flux_ref', (x.yr).flux_ref, 'flux_status', (x.yr).flux_status, 'flux_message', (x.yr).flux_message,
      'flux_sent_at', (x.yr).flux_sent_at, 'filed_at', (x.yr).filed_at, 'filed_by_business', coalesce((x.yr).filed_by_business, false),
      'acknowledgement_ref', (x.yr).acknowledgement_ref, 'assessment', (x.yr).assessment, 'payment_url', (x.yr).payment_url,
      'in_previous_year', (x.prev).person_id is not null)
    order by x.sort, x.created_at), '[]'::jsonb)
  from ppl x
$$;

-- A person's income as the LIRS statement of income asks for it, from Counta's computation: the taxable figures only
-- (trade income after losses and capital allowances; income exempt or taxed in full at source left out), so the tax the
-- portal works out is the tax Counta worked out. The fields add up to total income.
create or replace function private.pit_portal_income(t jsonb) returns jsonb
language sql immutable set search_path = public, private as $$
  with l as (
    select x->>'kind' kind, coalesce(x->>'field', '') field, coalesce(private.num(x->>'amount'), 0) amt, x->>'treatment' tr, x->>'label' label
    from jsonb_array_elements(coalesce(t->'other_income', '[]'::jsonb)) x),
  s as (select
    coalesce(sum(amt) filter (where tr = 'taxable' and kind = 'employment' and field not in ('commission', 'allowance')), 0) salary,
    coalesce(sum(amt) filter (where tr = 'taxable' and kind = 'employment' and field = 'commission'), 0) commission,
    coalesce(sum(amt) filter (where tr = 'taxable' and kind = 'employment' and field = 'allowance'), 0) allowance,
    coalesce(sum(amt) filter (where tr = 'taxable' and kind = 'pension_gratuity' and field not in ('annuity', 'gratuities')), 0) pension,
    coalesce(sum(amt) filter (where tr = 'taxable' and kind = 'pension_gratuity' and field = 'gratuities'), 0) gratuities,
    coalesce(sum(amt) filter (where tr = 'taxable' and kind = 'pension_gratuity' and field = 'annuity'), 0) annuity,
    coalesce(sum(amt) filter (where tr = 'taxable' and kind in ('foreign_earned', 'foreign_investment')), 0) foreign_income,
    coalesce(sum(amt) filter (where tr = 'taxable' and kind = 'dividend'), 0) dividend,
    coalesce(sum(amt) filter (where tr = 'taxable' and kind in ('interest', 'gov_bond_interest')), 0) interest,
    coalesce(sum(amt) filter (where tr = 'taxable' and kind = 'rent'), 0) rent,
    coalesce(sum(amt) filter (where tr = 'taxable' and kind not in ('employment', 'pension_gratuity', 'foreign_earned', 'foreign_investment', 'dividend', 'interest',
      'gov_bond_interest', 'rent')), 0) other
    from l),
  g as (select coalesce(private.num(t->'figures'->>'gains_taxed'), 0) gains)
  select jsonb_build_object(
    'fields', jsonb_build_object('salary', s.salary, 'commission', s.commission, 'trade_income', coalesce(private.num(t->'figures'->>'business_net'), 0),
      'allowance', s.allowance, 'pension', s.pension, 'annuity', s.annuity, 'gratuities', s.gratuities, 'foreign_income', s.foreign_income, 'dividend', s.dividend,
      'interest', s.interest, 'rent', s.rent, 'other_income', s.other + g.gains),
    'total', coalesce(private.num(t->'figures'->>'total_income'), 0),
    'other_lines', (select coalesce(jsonb_agg(jsonb_build_object('label', l.label, 'amount', l.amt)), '[]'::jsonb) from l
                    where l.tr = 'taxable' and l.kind not in ('employment', 'pension_gratuity', 'foreign_earned', 'foreign_investment', 'dividend', 'interest', 'gov_bond_interest', 'rent'))
      || case when g.gains > 0 then jsonb_build_array(jsonb_build_object('label', 'Chargeable gains on the business''s disposals', 'amount', g.gains)) else '[]'::jsonb end,
    'left_out', (select coalesce(jsonb_agg(jsonb_build_object('label', l.label, 'kind', l.kind, 'amount', l.amt, 'treatment', l.tr)), '[]'::jsonb) from l where l.tr <> 'taxable'))
  from s, g
$$;

-- The whole year. A relief counts only with its documents; the person's figures also come as the lines of the portal's
-- statement of income; and a return Flux files needs the accommodation disclosure, the business's staff and a login.
create or replace function private.pit_compute(p_org uuid, p_year int, p_bf jsonb default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; rbr public.tax_rulebooks; rb jsonb; v_kind text; b jsonb; bf jsonb; ppl jsonb; x jsonb; v_out jsonb := '[]'::jsonb; t jsonb;
  py public.pit_years; v_wht_used_bf numeric; v_wht_avail numeric; v_role text; v_auth text; v_share numeric; v_sum numeric := 0; v_n int;
  v_tax numeric := 0; v_payable numeric := 0; v_wht_used numeric := 0; v_cgt numeric := 0; v_cf jsonb := '{}'::jsonb; v_checks jsonb := '[]'::jsonb;
  v_flags jsonb; v_open text; v_rem numeric := 0; v_lb numeric; v_cb numeric; v_loc record; v_auth_name text; v_lines jsonb; v_flux text[];
  v_new text; v_gone text; v_prev_n int; rc jsonb; v_reliefs jsonb; v_has_flux boolean; v_staff_pay numeric;
  v_bot text[] := private.pit_bot_authorities();
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
    -- A relief counts only with its documents (pension also with the RSA number and administrator; rent relief with a
    -- tenant's accommodation disclosure). Rent relief is for 2026 accounts onwards, gratuity for 2025 accounts only.
    v_reliefs := coalesce(x->'reliefs', '{}'::jsonb) - case when rbr.regime = 'NTA_2025_PIT' then 'gratuity' else 'rent_paid' end;
    rc := private.pit_relief_check(v_reliefs, x->'relief_docs', x->'pension_details', x->'accommodation');
    t := private.pit_person_tax(rb, jsonb_build_object('name', x->>'name', 'sole', v_kind = 'sole', 'share_pct', v_share,
      'assessable', b->'figures'->'assessable', 'remuneration', x->'remuneration', 'ca_year', b->'figures'->'ca_year',
      'gains_net', b->'figures'->'gains_net', 'wht_available', v_wht_avail, 'losses_bf', v_lb, 'ca_bf', v_cb,
      'reliefs', rc->'claimed', 'other_income', x->'other_income'));
    v_auth := private.pit_authority(v_kind, v_role, (x->>'office_location_id')::uuid, x->>'residence', coalesce((x->>'resident')::boolean, true));
    select a.name, a.short_name, a.state into v_loc from tax_authorities a where a.code = v_auth;
    v_out := v_out || jsonb_build_array(x || jsonb_build_object('role', v_role, 'share_pct', v_share, 'authority', v_auth,
      'authority_name', v_loc.name, 'authority_short', v_loc.short_name, 'authority_state', v_loc.state,
      'office', (select jsonb_build_object('id', l.id, 'name', l.name, 'state', l.state, 'address', l.address) from locations l where l.id = (x->>'office_location_id')::uuid),
      'flux', v_auth = any(v_flux) or v_auth = any(v_bot), 'bot', v_auth = any(v_bot), 'reliefs_claimed', rc->'claimed', 'reliefs_held', rc->'held', 'income_fields', private.pit_portal_income(t),
      'computation', t, 'bf', jsonb_build_object('losses', v_lb, 'ca', v_cb, 'from_previous_year', p_bf is not null and bf->'people' ? (x->>'person_id'))));
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
    'text', 'Keep the evidence for the deductions in the accounts (receipts, the tenancy agreement): the state may ask for it (NTA 2025 s.32).'));

  -- What the state portal needs. A relief entered without its documents is left out (the portal refuses it), and says so to
  -- the person and those who file tax only.
  for x in select value from jsonb_array_elements(v_out) loop
    continue when jsonb_array_length(coalesce(x->'reliefs_held', '[]'::jsonb)) = 0;
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'relief_docs', 'severity', 'warn', 'person_id', x->>'person_id',
      'text', 'Left out of ' || (x->>'name') || '''s return until attached: '
        || (select string_agg((h->>'label') || ' (' || (select string_agg(mm, ', ') from jsonb_array_elements_text(h->'missing') mm) || ')', '; ')
            from jsonb_array_elements(x->'reliefs_held') h)
        || '. The state portal refuses a relief without its documents. Attach them under People.'));
  end loop;
  -- The business's staff screen is for the states Flux files; on e-Tax each person lists their own household staff.
  v_has_flux := exists (select 1 from jsonb_array_elements(v_out) p where (p->>'flux')::boolean and not coalesce((p->>'bot')::boolean, false));
  select string_agg(p->>'name', ', ') into v_open from jsonb_array_elements(v_out) p
    where (p->>'flux')::boolean and not private.pit_accommodation_ok(coalesce(p->'accommodation', '{}'::jsonb));
  if v_open is not null then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'accommodation_missing', 'severity', 'block',
      'text', 'Enter where ' || v_open || ' lived during the year under People: the address, the kind of home, whether it is rented or owned and since when, '
        || 'and for a tenant the landlord and the rent. The state portal will not take the return without it.'));
  end if;
  if v_has_flux and not coalesce((py.settings->>'staff_reviewed')::boolean, false) then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'staff_review', 'severity', 'block',
      'text', 'List the business''s employees for the year under Staff, or confirm it had none. The state portal asks for them with the return.'));
  end if;
  if coalesce((py.settings->>'staff_reviewed')::boolean, false) then
    select coalesce(sum(private.num(s->>'annual_pay')), 0) into v_staff_pay from jsonb_array_elements(coalesce(py.staff, '[]'::jsonb)) s;
    if abs(v_staff_pay + v_rem - private.v(b->'figures', 'salaries')) > greatest(1, 0.01 * private.v(b->'figures', 'salaries')) then
      v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'staff_pay', 'severity', 'info',
        'text', 'The pay listed under Staff (' || private.naira(v_staff_pay) || ')' || case when v_rem > 0 then ' and for the ' || case when v_kind = 'sole' then 'owner' else 'partners' end
          || ' (' || private.naira(v_rem) || ')' else '' end || ' differs from the salaries in the accounts (' || private.naira(private.v(b->'figures', 'salaries')) || ').'));
    end if;
  end if;
  select string_agg(distinct coalesce(p->>'authority_short', p->>'authority_name', p->>'authority'), ', ') into v_open from jsonb_array_elements(v_out) p
    where (p->>'flux')::boolean and not coalesce((p->>'bot')::boolean, false)
      and not exists (select 1 from portal_logins l where l.org_id = p_org and l.authority = p->>'authority');
  if v_open is not null then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'portal_login', 'severity', 'warn',
      'text', 'Save the business''s ' || v_open || ' login under Settings, Tax portal logins, so Flux can file the return.'));
  end if;
  select string_agg(p->>'name', ', ') into v_open from jsonb_array_elements(v_out) p
    where coalesce((p->>'bot')::boolean, false)
      and not exists (select 1 from pit_etax_logins l where l.org_id = p_org and l.person_id = (p->>'person_id')::uuid and l.authority = p->>'authority');
  if v_open is not null then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'etax_login', 'severity', 'warn',
      'text', 'Save the e-Tax login (Payer ID and password) of ' || v_open || ' under People, so Counta can file the return on LIRS e-Tax.'));
  end if;
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
    'status', coalesce(py.status, 'draft'), 'staff', coalesce(py.staff, '[]'::jsonb),
    'staff_review', jsonb_build_object('reviewed', coalesce((py.settings->>'staff_reviewed')::boolean, false), 'by', py.settings->>'staff_by', 'at', py.settings->>'staff_at'));
end $$;

-- A person's own figures (reliefs, other income, accommodation, documents, tax, bill, certificate) are left out for those
-- who may not see them, and so are the checks about them. The staff and their pay are for those who see the money.
create or replace function private.pit_mask(p_comp jsonb, p_acc jsonb) returns jsonb
language sql stable set search_path = public, private as $$
  select case when coalesce((p_acc->>'all')::boolean, false) or p_comp is null or p_comp->'people' is null then p_comp
  else p_comp || jsonb_build_object(
    'people', (select coalesce(jsonb_agg(case when p->>'person_id' = p_acc->>'me' then p
        else (p - 'reliefs' - 'other_income' - 'opening' - 'assessment' - 'payment_url' - 'bf' - 'accommodation' - 'accommodation_carried' - 'pension_details'
            - 'relief_docs' - 'reliefs_claimed' - 'reliefs_held' - 'income_fields' - 'bill' - 'paid_at' - 'payment_ref' - 'tcc' - 'computation_path' - 'household_staff' - 'portal' - 'etax_login' - 'jobs') || jsonb_build_object('hidden', true,
          'computation', jsonb_build_object('rows', (select coalesce(jsonb_agg(r), '[]'::jsonb) from jsonb_array_elements(p->'computation'->'rows') r where r->>'id' in ('S1', 'S2', 'S3')),
            'figures', jsonb_build_object('share_pct', p->'computation'->'figures'->'share_pct', 'share_profit', p->'computation'->'figures'->'share_profit',
              'remuneration', p->'computation'->'figures'->'remuneration', 'business_income', p->'computation'->'figures'->'business_income'))) end), '[]'::jsonb)
      from jsonb_array_elements(p_comp->'people') p),
    'figures', (p_comp->'figures') - 'tax' - 'payable' - 'cgt' - 'wht_credit_used',
    'cf', null, 'staff', case when coalesce((p_acc->>'money')::boolean, false) then p_comp->'staff' end,
    'checks', (select coalesce(jsonb_agg(k), '[]'::jsonb) from jsonb_array_elements(coalesce(p_comp->'checks', '[]'::jsonb)) k
               where (k->>'person_id' is null or k->>'person_id' = p_acc->>'me') and (k->>'id' is distinct from 'staff_pay' or coalesce((p_acc->>'money')::boolean, false)))) end
$$;

-- An approved year's people with where each return stands now, its bill, payment and certificate.
create or replace function private.pit_live(p_org uuid, p_year int, p_comp jsonb) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select case when p_comp is null or p_comp->'people' is null then p_comp else p_comp || jsonb_build_object('people',
    (select coalesce(jsonb_agg(case when y.person_id is null then x else x || jsonb_build_object('status', y.status, 'flux_ref', y.flux_ref, 'flux_status', y.flux_status,
        'flux_message', y.flux_message, 'flux_sent_at', y.flux_sent_at, 'filed_at', y.filed_at, 'filed_by_business', y.filed_by_business,
        'acknowledgement_ref', y.acknowledgement_ref, 'assessment', y.assessment, 'payment_url', y.payment_url, 'bill', y.bill, 'paid_at', y.paid_at,
        'payment_ref', y.payment_ref, 'tcc', coalesce(y.tcc, '{}'::jsonb) || jsonb_build_object('years', private.pit_tcc_years(p_org, p_year, y.person_id, y.tcc)),
        'computation_path', y.computation_path, 'portal', y.portal, 'household_staff', y.household_staff,
        'etax_login', private.pit_etax_login_of(p_org, y.person_id, 'SIRS:LA'), 'jobs', private.pit_jobs_of(p_org, p_year, y.person_id)) end order by o.n), '[]'::jsonb)
     from jsonb_array_elements(p_comp->'people') with ordinality o(x, n)
     left join pit_person_years y on y.org_id = p_org and y.accounting_year = p_year and y.person_id = (o.x->>'person_id')::uuid)) end
$$;

-- One year, for its screens: also the documents each relief needs and which portal logins the business has saved.
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
    'me', acc->'me', 'period', jsonb_build_object('from', p.pfrom, 'to', p.pto), 'relief_needs', private.pit_relief_needs(), 'staff_roles', private.pit_staff_roles(),
    'bot_authorities', to_jsonb(private.pit_bot_authorities()),
    'logins', case when v_all then (select coalesce(jsonb_agg(jsonb_build_object('authority', l.authority, 'status', l.status, 'tax_office', l.tax_office,
        'username_hint', l.username_hint)), '[]'::jsonb) from portal_logins l where l.org_id = p_org) end);
end $$;

-- ---------------------------------------------------------------------------
-- 8. What a person brings to a year, now with what the portal asks for
-- ---------------------------------------------------------------------------
-- Partners' shares, roles, offices and pay are set by those who file tax; a person linked to a team member may enter their
-- own state, reliefs, other income, amounts brought forward, accommodation, pension details and documents.
-- p: {share_pct, role, office_location_id, residence, resident, remuneration, remuneration_note, included,
--     opening: {losses_bf, ca_bf}, reliefs: {pension, nhf, nhis, life_insurance, home_loan_interest, gratuity, rent_paid},
--     other_income: [{kind, field, label, amount, tax_deducted, final_tax}],
--     accommodation: {address, type, occupancy, landlord_name, landlord_id, landlord_address, rent_paid, rent_paid_by_employer, started_on, ended_on},
--     pension_details: {rsa_number, pfa}, relief_docs: {relief: [{doc, path, name}] | null}}
-- field says which line of the portal's statement of income a line goes on: salary, commission or allowance for a job;
-- pension or annuity for a pension. For a tenant, rent relief is the rent in the accommodation, less what an employer paid.
create or replace function public.save_pit_person_year(p_org uuid, p_year int, p_person uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare acc jsonb; m public.members; py public.pit_years; d jsonb; k text; v_kinds text[]; x jsonb; v_oi jsonb := '[]'::jsonb; v_rl jsonb := '{}'::jsonb; v_n numeric;
  v_self_keys text[] := array['residence', 'resident', 'reliefs', 'other_income', 'opening', 'accommodation', 'pension_details', 'relief_docs', 'household_staff'];
  v_field text; a jsonb; v_acc jsonb; v_pen jsonb; v_rsa text; y public.pit_person_years; v_docs jsonb; v_needs jsonb := private.pit_relief_needs();
  v_ids text[]; v_list jsonb; f jsonb; v_pre text; v_at text; per record; v_net numeric; v_hs jsonb; v_reg boolean; v_pid text;
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
    if not k = any(array['share_pct', 'role', 'office_location_id', 'residence', 'resident', 'remuneration', 'remuneration_note', 'included', 'opening', 'reliefs', 'other_income',
                         'accommodation', 'pension_details', 'relief_docs', 'household_staff']) then
      raise exception 'Unknown field %.', k;
    end if;
  end loop;
  select * into py from pit_years where org_id = p_org and accounting_year = p_year;
  if coalesce(py.status, 'draft') <> 'draft' then raise exception '%', private.pit_locked(p_year, py.status); end if;
  select pfrom, pto into per from private.cit_period(p_org, p_year);

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
      v_field := nullif(x->>'field', '');
      if v_field is not null and not ((x->>'kind' = 'employment' and v_field in ('salary', 'commission', 'allowance'))
                                      or (x->>'kind' = 'pension_gratuity' and v_field in ('pension', 'annuity', 'gratuities'))) then
        raise exception 'The return has no % line for that kind of income.', v_field;
      end if;
      v_oi := v_oi || jsonb_build_array(jsonb_build_object('kind', x->>'kind', 'label', left(coalesce(nullif(trim(x->>'label'), ''), initcap(replace(x->>'kind', '_', ' '))), 120),
        'amount', round(private.num(x->>'amount'), 2), 'tax_deducted', round(coalesce(private.num(x->>'tax_deducted'), 0), 2))
        || case when x ? 'final_tax' and jsonb_typeof(x->'final_tax') = 'boolean' then jsonb_build_object('final_tax', (x->>'final_tax')::boolean) else '{}'::jsonb end
        || case when v_field is not null then jsonb_build_object('field', v_field) else '{}'::jsonb end);
    end loop;
    if jsonb_array_length(v_oi) > 40 then raise exception 'At most 40 lines of other income.'; end if;
  end if;
  if p ? 'opening' and (jsonb_typeof(p->'opening') <> 'object' or coalesce(private.num(p->'opening'->>'losses_bf'), 0) < 0 or coalesce(private.num(p->'opening'->>'ca_bf'), 0) < 0) then
    raise exception 'Amounts brought forward are zero or more.';
  end if;

  -- Where the person lived: the portal's accommodation disclosure.
  if p ? 'accommodation' then
    a := p->'accommodation';
    if jsonb_typeof(a) <> 'object' then raise exception 'The accommodation is {address, type, occupancy, ...}.'; end if;
    for k in select jsonb_object_keys(a) loop
      if not k = any(array['address', 'type', 'occupancy', 'landlord_name', 'landlord_id', 'landlord_address', 'rent_paid', 'rent_paid_by_employer', 'started_on', 'ended_on']) then
        raise exception 'Unknown accommodation field %.', k;
      end if;
    end loop;
    if nullif(a->>'type', '') is not null and a->>'type' not in ('flat', 'room', 'bungalow', 'duplex', 'terrace', 'detached', 'other') then raise exception 'Choose the kind of home.'; end if;
    if nullif(a->>'occupancy', '') is not null and a->>'occupancy' not in ('tenant', 'owner', 'employer', 'family') then raise exception 'Choose whether they rent the home, own it, or live there another way.'; end if;
    for k in select unnest(array['rent_paid', 'rent_paid_by_employer']) loop
      if coalesce(a->>k, '') <> '' and (private.num(a->>k) is null or private.num(a->>k) < 0) then raise exception 'Enter the rent as an amount of zero or more.'; end if;
    end loop;
    if coalesce(private.num(a->>'rent_paid_by_employer'), 0) > coalesce(private.num(a->>'rent_paid'), 0) and a->>'occupancy' = 'tenant' then
      raise exception 'The rent an employer paid is more than the rent.';
    end if;
    for k in select unnest(array['started_on', 'ended_on']) loop
      if coalesce(a->>k, '') <> '' and a->>k !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Enter the dates as days.'; end if;
    end loop;
    if coalesce(a->>'started_on', '') <> '' and (a->>'started_on')::date > per.pto then raise exception 'They moved in after the year ended: enter the home they lived in during %.', p_year; end if;
    if coalesce(a->>'ended_on', '') <> '' and (a->>'ended_on')::date < coalesce(nullif(a->>'started_on', '')::date, per.pfrom) then raise exception 'They moved out before they moved in.'; end if;
    if coalesce(a->>'ended_on', '') <> '' and (a->>'ended_on')::date < per.pfrom then raise exception 'They moved out before the year began: enter the home they lived in during %.', p_year; end if;
    v_acc := jsonb_strip_nulls(jsonb_build_object('address', left(nullif(trim(coalesce(a->>'address', '')), ''), 300), 'type', nullif(a->>'type', ''),
      'occupancy', nullif(a->>'occupancy', ''), 'landlord_name', left(nullif(trim(coalesce(a->>'landlord_name', '')), ''), 120),
      'landlord_id', left(nullif(trim(coalesce(a->>'landlord_id', '')), ''), 60), 'landlord_address', left(nullif(trim(coalesce(a->>'landlord_address', '')), ''), 300),
      'rent_paid', round(nullif(private.num(a->>'rent_paid'), 0), 2), 'rent_paid_by_employer', round(nullif(private.num(a->>'rent_paid_by_employer'), 0), 2),
      'started_on', nullif(a->>'started_on', ''), 'ended_on', nullif(a->>'ended_on', '')));
  end if;
  if p ? 'pension_details' then
    if jsonb_typeof(p->'pension_details') <> 'object' then raise exception 'The relief details are {rsa_number, pfa, life_company, life_policy, mortgage_institution, mortgage_capital}.'; end if;
    v_pen := '{}'::jsonb;
    for k in select jsonb_object_keys(p->'pension_details') loop
      if k not in ('rsa_number', 'pfa', 'life_company', 'life_policy', 'mortgage_institution', 'mortgage_capital') then raise exception 'Unknown relief detail %.', k; end if;
      if k = 'rsa_number' then
        v_rsa := nullif(upper(regexp_replace(coalesce(p->'pension_details'->>'rsa_number', ''), '\s', '', 'g')), '');
        if v_rsa is not null and v_rsa !~ '^[A-Z]{0,4}[0-9]{6,20}$' then raise exception 'An RSA number is PEN followed by twelve digits.'; end if;
        v_pen := v_pen || jsonb_build_object('rsa_number', v_rsa);
      elsif k = 'mortgage_capital' then
        v_n := private.num(p->'pension_details'->>k);
        if coalesce(p->'pension_details'->>k, '') <> '' and (v_n is null or v_n <= 0) then raise exception 'Enter the capital sum on the mortgage as an amount.'; end if;
        v_pen := v_pen || jsonb_build_object(k, round(v_n, 2));
      else
        v_pen := v_pen || jsonb_build_object(k, left(nullif(trim(coalesce(p->'pension_details'->>k, '')), ''), 120));
      end if;
    end loop;
  end if;

  -- Household staff (e-Tax's support staff, kept on the person's e-Tax profile).
  if p ? 'household_staff' then
    if jsonb_typeof(p->'household_staff') <> 'array' then raise exception 'The household staff are a list.'; end if;
    if jsonb_array_length(p->'household_staff') > 30 then raise exception 'At most 30 household staff.'; end if;
    v_hs := '[]'::jsonb;
    for x in select value from jsonb_array_elements(p->'household_staff') loop
      if not (private.pit_staff_roles() ? coalesce(x->>'role', '')) then raise exception 'Choose what each member of staff does.'; end if;
      v_reg := coalesce((x->>'registered')::boolean, false);
      v_n := private.num(x->>'income_paid');
      if v_n is null or v_n < 0 then raise exception 'Enter what % was paid in the year.', coalesce(nullif(trim(x->>'name'), ''), 'each member of staff'); end if;
      if v_reg then
        v_pid := upper(regexp_replace(coalesce(x->>'payer_id', ''), '\s', '', 'g'));
        if v_pid !~ '^[NC]-[0-9]{4,12}$' then raise exception 'A Payer ID is N- followed by digits, as e-Tax shows it.'; end if;
        v_hs := v_hs || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('role', x->>'role', 'registered', true, 'payer_id', v_pid,
          'name', left(nullif(trim(coalesce(x->>'name', '')), ''), 120), 'income_paid', round(v_n, 2))));
      else
        if length(trim(coalesce(x->>'name', ''))) < 2 then raise exception 'Enter the name of each member of staff.'; end if;
        if length(trim(coalesce(x->>'address', ''))) < 5 then raise exception 'Enter the home address of %.', trim(x->>'name'); end if;
        v_hs := v_hs || jsonb_build_array(jsonb_build_object('role', x->>'role', 'registered', false, 'name', left(trim(x->>'name'), 120),
          'address', left(trim(x->>'address'), 300), 'income_paid', round(v_n, 2)));
      end if;
    end loop;
  end if;

  -- The person's row for the year starts from what the year already gives them.
  select x2 into d from jsonb_array_elements(private.pit_people_year(p_org, p_year)) x2 where (x2->>'person_id')::uuid = p_person;
  insert into pit_years (org_id, accounting_year, updated_by) values (p_org, p_year, m.id) on conflict (org_id, accounting_year) do nothing;
  insert into pit_person_years (org_id, accounting_year, person_id, share_pct, role, office_location_id, residence, resident, household_staff, updated_by)
  values (p_org, p_year, p_person, private.num(d->>'share_pct'), d->>'role', nullif(d->>'office_location_id', '')::uuid, nullif(d->>'residence', ''),
    coalesce((d->>'resident')::boolean, true), coalesce(d->'household_staff', '[]'::jsonb), m.id)
  on conflict (org_id, accounting_year, person_id) do nothing;
  select * into y from pit_person_years where org_id = p_org and accounting_year = p_year and person_id = p_person for update;

  -- The documents for each relief, replacing those of each relief given (null or [] removes them).
  if p ? 'relief_docs' then
    if jsonb_typeof(p->'relief_docs') <> 'object' then raise exception 'The documents are {relief: [file]}.'; end if;
    v_docs := coalesce(y.relief_docs, '{}'::jsonb);
    for k in select jsonb_object_keys(p->'relief_docs') loop
      if not (v_needs ? k) or jsonb_array_length(coalesce(v_needs->k->'docs', '[]'::jsonb)) = 0 then raise exception 'There are no documents to attach for %.', replace(k, '_', ' '); end if;
      if jsonb_typeof(p->'relief_docs'->k) = 'null' then v_docs := v_docs - k; continue; end if;
      if jsonb_typeof(p->'relief_docs'->k) <> 'array' then raise exception 'The documents for % are a list.', replace(k, '_', ' '); end if;
      if jsonb_array_length(p->'relief_docs'->k) > 10 then raise exception 'At most 10 documents for each relief.'; end if;
      v_ids := array(select e->>'id' from jsonb_array_elements(v_needs->k->'docs') e);
      v_pre := p_org::text || '/tax/pit/' || p_year || '/people/' || p_person::text || '/' || k || '/';
      v_list := '[]'::jsonb;
      for f in select value from jsonb_array_elements(p->'relief_docs'->k) loop
        if not coalesce(f->>'doc', '') = any(v_ids) then raise exception 'That is not one of the documents for %.', replace(k, '_', ' '); end if;
        if left(coalesce(f->>'path', ''), length(v_pre)) <> v_pre or f->>'path' ~ '\.\.' or length(f->>'path') > 400 then raise exception 'That file is not this person''s.'; end if;
        select e->>'at' into v_at from jsonb_array_elements(case when jsonb_typeof(y.relief_docs->k) = 'array' then y.relief_docs->k else '[]'::jsonb end) e where e->>'path' = f->>'path' limit 1;
        v_list := v_list || jsonb_build_array(jsonb_build_object('doc', f->>'doc', 'path', f->>'path',
          'name', left(coalesce(nullif(trim(coalesce(f->>'name', '')), ''), split_part(f->>'path', '/', -1)), 160), 'at', coalesce(v_at, now()::text)));
      end loop;
      v_docs := case when jsonb_array_length(v_list) = 0 then v_docs - k else v_docs || jsonb_build_object(k, v_list) end;
    end loop;
  end if;

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
    accommodation = case when p ? 'accommodation' then v_acc else accommodation end,
    pension_details = case when p ? 'pension_details' then jsonb_strip_nulls(coalesce(pension_details, '{}'::jsonb) || v_pen) else pension_details end,
    household_staff = case when p ? 'household_staff' then v_hs else household_staff end,
    relief_docs = case when p ? 'relief_docs' then v_docs else relief_docs end,
    updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year and person_id = p_person
  returning * into y;

  -- Rent relief follows the accommodation: a tenant's rent, less any part an employer paid. Saving a home that is not
  -- rented takes the rent relief away.
  if y.accommodation->>'occupancy' = 'tenant' then
    v_net := round(coalesce(private.num(y.accommodation->>'rent_paid'), 0) - coalesce(private.num(y.accommodation->>'rent_paid_by_employer'), 0), 2);
    update pit_person_years set reliefs = case when v_net > 0 then reliefs || jsonb_build_object('rent_paid', v_net) else reliefs - 'rent_paid' end
    where org_id = p_org and accounting_year = p_year and person_id = p_person;
  elsif p ? 'accommodation' then
    update pit_person_years set reliefs = reliefs - 'rent_paid' where org_id = p_org and accounting_year = p_year and person_id = p_person;
  end if;
  update pit_years set updated_by = m.id, updated_at = now() where org_id = p_org and accounting_year = p_year;
  return public.pit_year(p_org, p_year);
end $$;

-- Approving keeps each person's accommodation and pension details with their row, so the next year starts from them.
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
    insert into pit_person_years (org_id, accounting_year, person_id, share_pct, role, office_location_id, residence, resident, remuneration, reliefs, other_income, opening,
      accommodation, pension_details, household_staff, status, updated_by)
    values (p_org, p_year, (x->>'person_id')::uuid, private.num(x->>'share_pct'), x->>'role', nullif(x->>'office_location_id', '')::uuid, nullif(x->>'residence', ''),
      coalesce((x->>'resident')::boolean, true), coalesce(private.num(x->>'remuneration'), 0), coalesce(x->'reliefs', '{}'::jsonb), coalesce(x->'other_income', '[]'::jsonb),
      coalesce(x->'opening', '{}'::jsonb), coalesce(x->'accommodation', '{}'::jsonb), coalesce(x->'pension_details', '{}'::jsonb), coalesce(x->'household_staff', '[]'::jsonb), 'approved', m.id)
    on conflict (org_id, accounting_year, person_id) do update set share_pct = excluded.share_pct, role = excluded.role, status = 'approved',
      accommodation = case when pit_person_years.accommodation = '{}'::jsonb then excluded.accommodation else pit_person_years.accommodation end,
      pension_details = case when pit_person_years.pension_details = '{}'::jsonb then excluded.pension_details else pit_person_years.pension_details end,
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

-- Reopening also drops the computation made for the portal: the next approval makes a new one.
create or replace function public.reopen_pit_year(p_org uuid, p_year int, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; py public.pit_years;
begin
  m := private.require(p_org, 'file_tax');
  select * into py from pit_years where org_id = p_org and accounting_year = p_year for update;
  if not found or py.status <> 'approved' then raise exception 'Only an approved return can be reopened.'; end if;
  if exists (select 1 from pit_person_years where org_id = p_org and accounting_year = p_year and status in ('sent', 'filed')) then
    raise exception 'A return in this year is being filed or is filed. File an amended return with the state instead.';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Say why the return is reopened.'; end if;
  update pit_years set status = 'draft', snapshot = null, approved_by = null, approved_at = null,
    settings = settings || jsonb_build_object('reopened', jsonb_build_object('by', m.display_name, 'at', now(), 'reason', left(trim(p_reason), 300))),
    updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year;
  update lirs_jobs set status = 'cancelled', error = 'The return was reopened.', finished_at = now(), updated_at = now()
  where org_id = p_org and accounting_year = p_year and status = 'queued';
  update pit_person_years set status = 'draft', flux_ref = null, flux_status = null, flux_message = null, flux_sent_at = null, computation_path = null,
    updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year;
  return public.pit_year(p_org, p_year);
end $$;

-- For the tax-files function, asked as the person: the approved year and each person's return, for Flux, with the
-- portal's lines, the staff, the fixed assets and the business's logins (Flux's references, never a password).
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
    'bot_authorities', to_jsonb(private.pit_bot_authorities()), 'staff', coalesce(comp->'staff', '[]'::jsonb), 'staff_review', comp->'staff_review', 'portal_ready', comp ? 'staff_review', 'relief_needs', private.pit_relief_needs(),
    'assets', (select coalesce(jsonb_agg(jsonb_build_object('number', a->>'number', 'name', a->>'name', 'category', a->>'category', 'cost', a->'qce', 'in_use', a->>'in_use',
        'first_year', a->'first_year', 'use_pct', a->'use_pct', 'tax_value_bf', a->'twdv_bf', 'allowance', a->'allowance', 'tax_value_cf', a->'twdv_cf',
        'disposed', a->'disposed', 'proceeds', a->'proceeds', 'qualifies', a->'qualifies')), '[]'::jsonb)
      from jsonb_array_elements(coalesce(comp->'business'->'ca'->'assets', '[]'::jsonb)) a),
    'logins', (select coalesce(jsonb_object_agg(l.authority, jsonb_build_object('flux_ref', l.flux_ref, 'tax_office', l.tax_office, 'status', l.status)), '{}'::jsonb)
      from portal_logins l where l.org_id = p_org),
    'people', (select coalesce(jsonb_agg(x || jsonb_build_object('status', y.status, 'flux_ref', y.flux_ref, 'flux_status', y.flux_status,
        'computation_path', y.computation_path, 'household_staff', y.household_staff, 'portal', y.portal,
        'etax_login', private.pit_etax_login_of(p_org, y.person_id, x->>'authority'), 'income_fields', coalesce(x->'income_fields', private.pit_portal_income(x->'computation')))), '[]'::jsonb)
      from jsonb_array_elements(comp->'people') x
      left join pit_person_years y on y.org_id = p_org and y.accounting_year = p_year and y.person_id = (x->>'person_id')::uuid));
end $$;


-- ---------------------------------------------------------------------------
-- 4. Each person's e-Tax login
-- ---------------------------------------------------------------------------
-- Asked by the tax-files function as the person, before a login is saved or removed: the person (linked to their own
-- Counta login) or whoever files the business's tax, signed in with two-step.
create or replace function public.pit_etax_login_begin(p_org uuid, p_person uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare acc jsonb; m public.members; pp public.pit_people; l public.pit_etax_logins;
begin
  acc := private.pit_access(p_org);
  m := private.require(p_org, null);
  select * into pp from pit_people where id = p_person and org_id = p_org;
  if not found then raise exception 'That person is not in this business.'; end if;
  if not ((acc->>'all')::boolean or acc->>'me' is not distinct from p_person::text) then
    raise exception 'Only the person, or whoever files the business''s tax, saves their e-Tax login.' using errcode = '42501';
  end if;
  if private.jwt_aal() <> 'aal2' and private.mfa_required(auth.uid()) then
    raise exception 'Enter the code from your authenticator app first: e-Tax logins need two-step sign-in.' using errcode = 'PX403';
  end if;
  select * into l from pit_etax_logins where org_id = p_org and person_id = p_person and authority = 'SIRS:LA';
  return jsonb_build_object('member_id', m.id, 'person', jsonb_build_object('id', pp.id, 'name', pp.name),
    'existing', case when l.id is not null then jsonb_build_object('payer_id', l.payer_id, 'status', l.status) end);
end $$;

-- Saving (service role, from the tax-files function after the check above): the password goes into Supabase Vault.
-- p: {payer_id, password, tax_station?, tax_station_name?, member_id}
create or replace function public.svc_pit_etax_login_save(p_org uuid, p_person uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.pit_etax_logins; v_pid text := upper(regexp_replace(coalesce(p->>'payer_id', ''), '\s', '', 'g')); v_pw text := p->>'password'; v_sid uuid;
  v_st text := nullif(regexp_replace(coalesce(p->>'tax_station', ''), '\s', '', 'g'), '');
begin
  if not exists (select 1 from pit_people where id = p_person and org_id = p_org) then raise exception 'That person is not in this business.'; end if;
  if v_pid !~ '^[NC]-[0-9]{4,12}$' then raise exception 'A Payer ID is N- (or C-) followed by digits, as e-Tax shows it.'; end if;
  if v_pw is null or length(v_pw) = 0 or length(v_pw) > 200 then raise exception 'Enter the e-Tax password (at most 200 characters).'; end if;
  if v_st is not null and v_st !~ '^[0-9]{3,10}$' then raise exception 'Choose the tax station.'; end if;
  select * into l from pit_etax_logins where org_id = p_org and person_id = p_person and authority = 'SIRS:LA' for update;
  if l.secret_id is not null and exists (select 1 from vault.secrets where id = l.secret_id) then
    perform vault.update_secret(l.secret_id, v_pw);
    v_sid := l.secret_id;
  else
    v_sid := vault.create_secret(v_pw, 'etax:' || gen_random_uuid()::text, 'LIRS e-Tax password of a person in a Counta business');
  end if;
  insert into pit_etax_logins (org_id, person_id, authority, payer_id, secret_id, tax_station, tax_station_name, status, message, saved_by, saved_at, checked_at, updated_at)
  values (p_org, p_person, 'SIRS:LA', v_pid, v_sid, v_st, left(nullif(trim(coalesce(p->>'tax_station_name', '')), ''), 120), 'saved', null,
    nullif(p->>'member_id', '')::uuid, now(), null, now())
  on conflict (org_id, person_id, authority) do update set payer_id = excluded.payer_id, secret_id = excluded.secret_id,
    tax_station = coalesce(excluded.tax_station, case when pit_etax_logins.payer_id = excluded.payer_id then pit_etax_logins.tax_station end),
    tax_station_name = coalesce(excluded.tax_station_name, case when pit_etax_logins.payer_id = excluded.payer_id then pit_etax_logins.tax_station_name end),
    status = 'saved', message = null, saved_by = excluded.saved_by, saved_at = now(), checked_at = null, updated_at = now();
  return private.pit_etax_login_of(p_org, p_person, 'SIRS:LA');
end $$;

-- Removing it removes the Vault secret too. A login with a job under way stays until the job ends.
create or replace function public.svc_pit_etax_login_remove(p_org uuid, p_person uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.pit_etax_logins;
begin
  select * into l from pit_etax_logins where org_id = p_org and person_id = p_person and authority = 'SIRS:LA' for update;
  if not found then return jsonb_build_object('removed', false); end if;
  if exists (select 1 from lirs_jobs where org_id = p_org and person_id = p_person and status = 'running') then
    raise exception 'Counta''s bot is working on e-Tax with this login. Remove it once it finishes.';
  end if;
  update lirs_jobs set status = 'cancelled', error = 'The e-Tax login was removed.', finished_at = now(), updated_at = now()
  where org_id = p_org and person_id = p_person and status = 'queued';
  if l.secret_id is not null then delete from vault.secrets where id = l.secret_id; end if;
  delete from pit_etax_logins where id = l.id;
  return jsonb_build_object('removed', true);
end $$;

-- ---------------------------------------------------------------------------
-- 5. Jobs for the bot
-- ---------------------------------------------------------------------------
-- What Counta says the person owes on the bill: the approved computation's tax payable.
create or replace function private.pit_person_payable(p_org uuid, p_year int, p_person uuid) returns numeric
language sql stable security definer set search_path = public, private as $$
  select round(coalesce(private.num(x->'computation'->'figures'->>'payable'), 0), 2)
  from pit_years py, jsonb_array_elements(py.snapshot->'computation'->'people') x
  where py.org_id = p_org and py.accounting_year = p_year and (x->>'person_id')::uuid = p_person
$$;

-- Adds a job (the one open job of its kind for the person, if there is one already).
create or replace function private.lirs_enqueue(p_org uuid, p_year int, p_person uuid, p_kind text, p_request jsonb, p_by uuid, p_after interval default interval '0')
returns public.lirs_jobs
language plpgsql security definer set search_path = public, private as $$
declare j public.lirs_jobs;
begin
  select * into j from lirs_jobs where org_id = p_org and accounting_year = p_year and person_id = p_person and kind = p_kind and status in ('queued', 'running');
  if found then return j; end if;
  insert into lirs_jobs (org_id, accounting_year, person_id, kind, request, created_by, not_before)
  values (p_org, p_year, p_person, p_kind, coalesce(p_request, '{}'::jsonb), p_by, now() + p_after)
  returning * into j;
  return j;
end $$;

-- The approved person, for the checks below.
create or replace function private.pit_snapshot_person(p_org uuid, p_year int, p_person uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select x from pit_years py, jsonb_array_elements(py.snapshot->'computation'->'people') x
  where py.org_id = p_org and py.accounting_year = p_year and py.status = 'approved' and (x->>'person_id')::uuid = p_person
$$;

-- Asked by the tax-files function as the person. p_kind: file (whoever files tax; the app has made the computation), bill
-- (again, after a bill failed), pay_account (whoever files tax or handles money). p_request for pay_account:
-- {pay_with: transfer} (the tax wallet and the business account follow).
create or replace function public.pit_lirs_queue(p_org uuid, p_year int, p_person uuid, p_kind text, p_request jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; py public.pit_years; y public.pit_person_years; x jsonb; j public.lirs_jobs; l public.pit_etax_logins; v_with text;
begin
  m := private.require(p_org, null);
  if p_kind not in ('file', 'bill', 'pay_account') then raise exception 'Unknown job.'; end if;
  if p_kind in ('file', 'bill') and not private.perm_of(m, 'file_tax') then raise exception 'Your role does not allow this (file tax).' using errcode = '42501'; end if;
  if p_kind = 'pay_account' and not (private.perm_of(m, 'file_tax') or private.can_handle_money(p_org)) then
    raise exception 'Your role does not allow this (file tax, or make payments).' using errcode = '42501';
  end if;
  select * into py from pit_years where org_id = p_org and accounting_year = p_year;
  if not found or py.status <> 'approved' then raise exception 'Approve the % return first.', p_year; end if;
  x := private.pit_snapshot_person(p_org, p_year, p_person);
  if x is null then raise exception 'That person is not in the % return.', p_year; end if;
  if not ((x->>'authority') = any(private.pit_bot_authorities())) then raise exception 'Counta files on LIRS e-Tax only: % files with %.', x->>'name', coalesce(x->>'authority_name', 'another state'); end if;
  select * into y from pit_person_years where org_id = p_org and accounting_year = p_year and person_id = p_person for update;
  select * into l from pit_etax_logins where org_id = p_org and person_id = p_person and authority = x->>'authority';
  if l.id is null then raise exception 'Save %''s e-Tax login (Payer ID and password) under People first.', x->>'name'; end if;
  if l.status = 'failed' then raise exception '%''s e-Tax login did not work: %. Save it again under People.', x->>'name', coalesce(l.message, 'e-Tax refused it'); end if;

  if p_kind = 'file' then
    if y.status = 'filed' then raise exception '%''s % return is already filed.', x->>'name', p_year; end if;
    if y.status = 'sent' and exists (select 1 from lirs_jobs where org_id = p_org and accounting_year = p_year and person_id = p_person and kind = 'file' and status in ('queued', 'running')) then
      return jsonb_build_object('job', (select to_jsonb(z) - 'log' - 'request' from lirs_jobs z where org_id = p_org and accounting_year = p_year and person_id = p_person and kind = 'file' and status in ('queued', 'running')), 'already', true);
    end if;
    if py.soa_path is null then raise exception 'Attach the statement of accounts first.'; end if;
    if y.computation_path is null then raise exception 'The computation for % is not ready yet. Send again from the app, which makes it.', x->>'name'; end if;
    j := private.lirs_enqueue(p_org, p_year, p_person, 'file', '{}'::jsonb, m.id);
    update pit_person_years set status = 'sent', flux_status = 'queued', flux_message = 'Waiting for Counta''s bot to file it on LIRS e-Tax.', flux_sent_at = now(),
      flux_updated_at = now(), updated_by = m.id, updated_at = now()
    where org_id = p_org and accounting_year = p_year and person_id = p_person;
  elsif p_kind = 'bill' then
    if y.status <> 'filed' then raise exception 'File the return first: the bill follows the filing.'; end if;
    if y.paid_at is not null then raise exception 'The % income tax of % is paid.', p_year, x->>'name'; end if;
    if private.pit_person_payable(p_org, p_year, p_person) <= 0 then raise exception 'There is no tax to pay for % in %.', x->>'name', p_year; end if;
    j := private.lirs_enqueue(p_org, p_year, p_person, 'bill', '{}'::jsonb, m.id);
  else
    v_with := coalesce(nullif(p_request->>'pay_with', ''), 'transfer');
    if v_with in ('tax_wallet', 'business') then raise exception 'Paying from the tax wallet or the business account comes next. Pay this bill by transfer for now.'; end if;
    if v_with <> 'transfer' then raise exception 'Choose how to pay.'; end if;
    if y.status <> 'filed' or y.bill is null or coalesce(y.bill->>'reference', '') = '' then raise exception 'There is no bill to pay yet.'; end if;
    if y.paid_at is not null then raise exception 'This bill is paid.'; end if;
    j := private.lirs_enqueue(p_org, p_year, p_person, 'pay_account', jsonb_build_object('pay_with', v_with), m.id);
  end if;
  return jsonb_build_object('job', to_jsonb(j) - 'log' - 'request', 'already', false);
end $$;

-- What the bot needs for a job. The password is read from Vault here, for the bot only.
create or replace function private.lirs_context(j public.lirs_jobs) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare py public.pit_years; y public.pit_person_years; x jsonb; l public.pit_etax_logins; o public.orgs; v_pw text; v_needs jsonb := private.pit_relief_needs();
  v_reliefs jsonb := '[]'::jsonb; k text; v numeric;
begin
  select * into py from pit_years where org_id = j.org_id and accounting_year = j.accounting_year;
  select * into y from pit_person_years where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id;
  x := private.pit_snapshot_person(j.org_id, j.accounting_year, j.person_id);
  select * into l from pit_etax_logins where org_id = j.org_id and person_id = j.person_id and authority = coalesce(x->>'authority', 'SIRS:LA');
  select * into o from orgs where id = j.org_id;
  if l.secret_id is not null then select decrypted_secret into v_pw from vault.decrypted_secrets where id = l.secret_id; end if;
  -- Each relief Counta counted, with e-Tax's form and the files for each of its fields.
  for k, v in select key, private.num(value #>> '{}') from jsonb_each(coalesce(x->'reliefs_claimed', '{}'::jsonb)) loop
    continue when coalesce(v, 0) <= 0;
    v_reliefs := v_reliefs || jsonb_build_array(jsonb_build_object('relief', k, 'label', v_needs->k->>'label', 'amount', v, 'portal_type', v_needs->k->'portal',
      'details', (select coalesce(jsonb_object_agg(f, coalesce(y.pension_details, '{}'::jsonb)->f), '{}'::jsonb) from jsonb_array_elements_text(coalesce(v_needs->k->'fields', '[]'::jsonb)) f),
      'files', (select coalesce(jsonb_agg(jsonb_build_object('doc', d->>'id', 'label', d->>'label', 'portal_field', d->>'portal_field',
          'paths', (select coalesce(jsonb_agg(e->>'path'), '[]'::jsonb) from jsonb_array_elements(case when jsonb_typeof(y.relief_docs->k) = 'array' then y.relief_docs->k else '[]'::jsonb end) e
                    where e->>'doc' = d->>'id'))), '[]'::jsonb)
        from jsonb_array_elements(coalesce(v_needs->k->'docs', '[]'::jsonb)) d)));
  end loop;
  return jsonb_build_object(
    'login', jsonb_build_object('payer_id', l.payer_id, 'password', v_pw, 'tax_station', l.tax_station, 'tax_station_name', l.tax_station_name),
    'taxpayer', jsonb_build_object('person_id', j.person_id, 'name', x->>'name', 'tin', x->>'tin', 'authority', x->>'authority', 'role', x->>'role', 'share_pct', x->'share_pct'),
    'year', j.accounting_year, 'yoa', j.accounting_year + 1,
    'org', jsonb_build_object('name', o.name, 'address', coalesce(o.registered_office, o.address), 'email', o.email, 'phone', o.phone),
    'portal', coalesce(y.portal, '{}'::jsonb),
    'return', case when j.kind = 'file' then jsonb_build_object(
        'income', x->'income_fields', 'accommodation', coalesce(y.accommodation, x->'accommodation', '{}'::jsonb),
        'household_staff', coalesce(y.household_staff, '[]'::jsonb), 'staff_roles', private.pit_staff_roles(), 'reliefs', v_reliefs,
        'reliefs_on_record', (select coalesce(jsonb_agg(jsonb_build_object('relief', r.key, 'label', v_needs->r.key->>'label', 'amount', r.value)), '[]'::jsonb)
          from jsonb_each(coalesce(x->'reliefs_claimed', '{}'::jsonb)) r where v_needs->r.key->'portal' = 'false'::jsonb),
        'assets', (select coalesce(jsonb_agg(jsonb_build_object('number', a->>'number', 'name', a->>'name', 'category', a->>'category', 'class', a->>'class',
            'cost', a->'qce', 'first_year', a->'first_year', 'acquired_on', a->>'in_use', 'disposed', a->'disposed')), '[]'::jsonb)
          from jsonb_array_elements(coalesce(py.snapshot->'computation'->'business'->'ca'->'assets', '[]'::jsonb)) a where not coalesce((a->>'disposed')::boolean, false)),
        'files', jsonb_build_object('statement_of_accounts', py.soa_path, 'computation', y.computation_path)) end,
    'bill', case when j.kind in ('bill', 'pay_account', 'status') then jsonb_build_object('amount', private.pit_person_payable(j.org_id, j.accounting_year, j.person_id),
        'existing', y.bill, 'revenue_code', '32102', 'start_date', make_date(j.accounting_year, 1, 1), 'end_date', make_date(j.accounting_year, 12, 31),
        'remark', left(coalesce(o.name, '') || ' ' || j.accounting_year || ' personal income tax (direct assessment)', 200)) end,
    'request', j.request);
end $$;

-- The bot takes its next job (service role). A job left running for 20 minutes counts as a failed attempt. One person at a
-- time: e-Tax keeps one session per account.
create or replace function public.svc_lirs_next(p_worker text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare j public.lirs_jobs; s public.lirs_jobs;
begin
  for s in select * from lirs_jobs where status = 'running' and locked_at < now() - interval '20 minutes' for update skip locked loop
    perform private.lirs_fail(s, 'The bot stopped without reporting back.', true);
  end loop;
  select * into j from lirs_jobs q where q.status = 'queued' and q.not_before <= now()
    and not exists (select 1 from lirs_jobs r where r.status = 'running' and r.org_id = q.org_id and r.person_id = q.person_id)
  order by q.not_before, q.created_at limit 1 for update skip locked;
  if not found then return jsonb_build_object('job', null); end if;
  update lirs_jobs set status = 'running', attempts = attempts + 1, locked_at = now(), worker = left(coalesce(p_worker, 'bot'), 120), error = null, updated_at = now()
  where id = j.id returning * into j;
  if j.kind = 'file' then
    update pit_person_years set flux_status = 'processing', flux_message = 'Counta''s bot is filing it on LIRS e-Tax.', flux_updated_at = now()
    where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id and status = 'sent';
  end if;
  return jsonb_build_object('job', jsonb_build_object('id', j.id, 'kind', j.kind, 'attempt', j.attempts, 'max_attempts', j.max_attempts, 'org_id', j.org_id,
    'year', j.accounting_year, 'person_id', j.person_id), 'context', private.lirs_context(j));
end $$;

-- A job that did not work: tried again later (p_retry), or given up, with what that means for the return.
create or replace function private.lirs_fail(j public.lirs_jobs, p_error text, p_retry boolean) returns public.lirs_jobs
language plpgsql security definer set search_path = public, private as $$
declare v_name text; v_again boolean := p_retry and j.attempts < j.max_attempts;
begin
  select name into v_name from pit_people where id = j.person_id;
  update lirs_jobs set status = case when v_again then 'queued' else 'failed' end, error = left(coalesce(p_error, 'Something went wrong on e-Tax.'), 2000),
    not_before = case when v_again then now() + make_interval(mins => 2 * power(2, greatest(j.attempts - 1, 0))::int) else not_before end,
    locked_at = null, updated_at = now(), finished_at = case when v_again then null else now() end
  where id = j.id returning * into j;
  if v_again then return j; end if;
  if j.kind = 'file' then
    update pit_person_years set status = 'approved', flux_status = 'send_failed', flux_message = left(j.error, 1000), flux_updated_at = now()
    where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id and status = 'sent';
    perform private.notify_perm(j.org_id, 'file_tax', 'books', v_name || '''s ' || j.accounting_year || ' return was not filed', j.error,
      '/tax/pit?year=' || j.accounting_year, 'lirs-' || j.id, null);
  elsif j.kind = 'bill' then
    perform private.notify_perm(j.org_id, 'file_tax', 'books', 'Counta could not raise ' || v_name || '''s ' || j.accounting_year || ' bill', j.error,
      '/tax/pit?year=' || j.accounting_year, 'lirs-' || j.id, null);
  elsif j.kind = 'status' then
    -- Checking the bill is tried again later in any case, while there is still reason to expect the payment.
    perform private.lirs_enqueue(j.org_id, j.accounting_year, j.person_id, 'status', j.request, null, interval '15 minutes');
  end if;
  return j;
end $$;

-- The bot reporting (service role). p: {step, note} to log a step; {login: verified | failed, login_message}; {tax_station:
-- {code, name}}; {portal: {...}} to keep e-Tax's ids; then {done: true, result} or {failed: true, error, retry}.
-- Results: file {return_id, tax_payer_id, confirmed_at}; bill {bill_id, reference, amount, agency, revenue, payer_id,
-- generated_at, paid}; pay_account {account_number, bank_name, account_name, amount, fee, expires_at} or {paid: true} when
-- the bill is paid already; status {paid, amount_paid, paid_at, reference}.
create or replace function public.svc_lirs_report(p_job uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare j public.lirs_jobs; y public.pit_person_years; r jsonb := coalesce(p->'result', '{}'::jsonb); v_name text; v_due numeric; v_ref text; v_tr jsonb;
  v_since timestamptz; v_out jsonb;
begin
  select * into j from lirs_jobs where id = p_job for update;
  if not found then raise exception 'No such job.'; end if;
  if j.status <> 'running' then return jsonb_build_object('job_id', j.id, 'status', j.status, 'ignored', true); end if;
  select name into v_name from pit_people where id = j.person_id;
  if nullif(p->>'step', '') is not null then
    update lirs_jobs set log = (case when jsonb_array_length(log) >= 200 then log - 0 else log end)
        || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('at', now(), 'step', left(p->>'step', 80), 'note', left(nullif(p->>'note', ''), 500)))),
      locked_at = now(), updated_at = now()
    where id = j.id returning * into j;
  end if;
  if p->>'login' in ('verified', 'failed') then
    update pit_etax_logins set status = p->>'login', message = case when p->>'login' = 'failed' then left(coalesce(nullif(p->>'login_message', ''), 'e-Tax did not accept the Payer ID and password.'), 1000) end,
      checked_at = now(), updated_at = now()
    where org_id = j.org_id and person_id = j.person_id and authority = 'SIRS:LA';
    if p->>'login' = 'failed' then
      perform private.notify_perm(j.org_id, 'file_tax', 'books', v_name || '''s e-Tax login did not work',
        coalesce(nullif(p->>'login_message', ''), 'e-Tax did not accept the Payer ID and password.') || ' Save it again under People.',
        '/tax/pit?year=' || j.accounting_year, 'lirs-login-' || j.person_id || '-' || to_char(now(), 'YYYYMMDDHH24MI'), null);
    end if;
  end if;
  if jsonb_typeof(p->'tax_station') = 'object' and coalesce(p->'tax_station'->>'code', '') ~ '^[0-9]{3,10}$' then
    update pit_etax_logins set tax_station = p->'tax_station'->>'code', tax_station_name = left(nullif(p->'tax_station'->>'name', ''), 120), updated_at = now()
    where org_id = j.org_id and person_id = j.person_id and authority = 'SIRS:LA';
  end if;
  if jsonb_typeof(p->'portal') = 'object' then
    update pit_person_years set portal = coalesce(portal, '{}'::jsonb) || ((p->'portal') - 'steps')
        || case when jsonb_typeof(p->'portal'->'steps') = 'object' then jsonb_build_object('steps', coalesce(portal->'steps', '{}'::jsonb) || (p->'portal'->'steps')) else '{}'::jsonb end
    where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id;
  end if;

  if coalesce((p->>'failed')::boolean, false) then
    j := private.lirs_fail(j, p->>'error', coalesce((p->>'retry')::boolean, true));
    return jsonb_build_object('job_id', j.id, 'status', j.status, 'not_before', j.not_before);
  end if;
  if not coalesce((p->>'done')::boolean, false) then return jsonb_build_object('job_id', j.id, 'status', j.status); end if;

  select * into y from pit_person_years where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id for update;
  if j.kind = 'file' then
    if coalesce(r->>'return_id', '') !~ '^[0-9]{1,15}$' then raise exception 'result.return_id is e-Tax''s return reference.'; end if;
    update pit_person_years set portal = coalesce(portal, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object('return_id', r->>'return_id',
      'tax_payer_id', r->>'tax_payer_id', 'confirmed_at', coalesce(nullif(r->>'confirmed_at', ''), now()::text)))
    where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id;
    v_out := public.svc_pit_flux_update(j.org_id, j.accounting_year, j.person_id, jsonb_build_object('status', 'filed', 'ref', 'ETAX-' || (r->>'return_id'),
      'acknowledgement_ref', r->>'return_id', 'filed_at', coalesce(nullif(r->>'confirmed_at', ''), now()::text),
      'message', 'Filed and confirmed on LIRS e-Tax by Counta''s bot (return ' || (r->>'return_id') || ').'));
    if private.pit_person_payable(j.org_id, j.accounting_year, j.person_id) > 0 then
      perform private.lirs_enqueue(j.org_id, j.accounting_year, j.person_id, 'bill', '{}'::jsonb, j.created_by);
    end if;
  elsif j.kind = 'bill' then
    v_ref := nullif(trim(coalesce(r->>'reference', '')), '');
    if v_ref is null or v_ref !~ '^[0-9A-Za-z][0-9A-Za-z-]{5,60}$' then raise exception 'result.reference is the bill reference.'; end if;
    v_out := public.svc_pit_flux_update(j.org_id, j.accounting_year, j.person_id, jsonb_build_object('bill', jsonb_build_object('amount', r->'amount', 'reference', v_ref,
      'agency', r->>'agency', 'revenue', coalesce(nullif(r->>'revenue', ''), 'Direct Assessment'), 'payer_id', r->>'payer_id',
      'payment_url', 'https://payments.lasg-public.com/tax-confirm?bill_type=' || v_ref, 'generated_at', coalesce(nullif(r->>'generated_at', ''), now()::text))));
    update pit_person_years set portal = coalesce(portal, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object('bill_id', r->>'bill_id'))
    where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id;
    -- A bill e-Tax already shows as paid (raised and paid before Counta's bot reported back).
    if coalesce((r->>'paid')::boolean, false) then
      v_out := public.svc_pit_flux_update(j.org_id, j.accounting_year, j.person_id, jsonb_build_object('paid', jsonb_strip_nulls(jsonb_build_object(
        'paid_at', now()::text, 'reference', v_ref, 'amount', r->'amount'))));
    end if;
  elsif j.kind = 'pay_account' and coalesce((r->>'paid')::boolean, false) then
    -- The payments page shows the bill paid already: nothing to pay.
    v_out := public.svc_pit_flux_update(j.org_id, j.accounting_year, j.person_id, jsonb_build_object('paid', jsonb_strip_nulls(jsonb_build_object(
      'paid_at', coalesce(nullif(r->>'paid_at', ''), now()::text), 'reference', coalesce(nullif(r->>'reference', ''), y.bill->>'reference'), 'amount', y.bill->'amount'))));
  elsif j.kind = 'pay_account' then
    if coalesce(regexp_replace(r->>'account_number', '\s', '', 'g'), '') !~ '^[0-9]{10}$' then raise exception 'result.account_number is the 10-digit account number.'; end if;
    if coalesce(private.num(r->>'amount'), 0) <= 0 then raise exception 'result.amount is the exact amount to transfer.'; end if;
    v_tr := jsonb_strip_nulls(jsonb_build_object('account_number', regexp_replace(r->>'account_number', '\s', '', 'g'), 'bank_name', left(coalesce(nullif(r->>'bank_name', ''), 'Flutterwave MFB'), 120),
      'account_name', left(coalesce(nullif(r->>'account_name', ''), 'LASG Collection'), 160), 'amount', round(private.num(r->>'amount'), 2),
      'fee', round(private.num(r->>'fee'), 2), 'expires_at', nullif(r->>'expires_at', '')::timestamptz, 'fetched_at', now(), 'pay_with', j.request->>'pay_with',
      'channel', coalesce(nullif(r->>'channel', ''), 'Flutterwave')));
    update pit_person_years set bill = coalesce(bill, '{}'::jsonb) || jsonb_build_object('transfer', v_tr)
    where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id;
    perform private.lirs_enqueue(j.org_id, j.accounting_year, j.person_id, 'status', jsonb_build_object('since', now()), j.created_by, interval '15 minutes');
  elsif j.kind = 'status' then
    if coalesce((r->>'paid')::boolean, false) then
      v_out := public.svc_pit_flux_update(j.org_id, j.accounting_year, j.person_id, jsonb_build_object('paid', jsonb_strip_nulls(jsonb_build_object(
        'paid_at', coalesce(nullif(r->>'paid_at', ''), now()::text), 'reference', coalesce(nullif(r->>'reference', ''), y.bill->>'reference'),
        'amount', coalesce(r->'amount_paid', y.bill->'amount')))));
    else
      v_since := coalesce(nullif(j.request->>'since', '')::timestamptz, (y.bill->'transfer'->>'fetched_at')::timestamptz, j.created_at);
      if v_since > now() - interval '3 days' then
        update lirs_jobs set status = 'done', result = r, locked_at = null, finished_at = now(), updated_at = now() where id = j.id returning * into j;
        perform private.lirs_enqueue(j.org_id, j.accounting_year, j.person_id, 'status', jsonb_build_object('since', v_since), j.created_by, interval '15 minutes');
        return jsonb_build_object('job_id', j.id, 'status', j.status, 'next_check', 'in 15 minutes');
      end if;
      perform private.notify_perm(j.org_id, 'file_tax', 'books', v_name || '''s ' || j.accounting_year || ' bill is not showing as paid',
        'e-Tax still shows bill ' || coalesce(y.bill->>'reference', '') || ' unpaid three days on. If it was paid, raise it with LIRS with the transfer receipt.',
        '/tax/pit?year=' || j.accounting_year, 'lirs-unpaid-' || j.person_id || '-' || j.accounting_year, null);
    end if;
  end if;
  -- Paid: the checks and transfer accounts still waiting are not needed any more.
  if exists (select 1 from pit_person_years where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id and paid_at is not null) then
    update lirs_jobs set status = 'cancelled', finished_at = now(), updated_at = now()
    where org_id = j.org_id and accounting_year = j.accounting_year and person_id = j.person_id and kind in ('status', 'pay_account') and status = 'queued' and id <> j.id;
  end if;
  update lirs_jobs set status = 'done', result = r, locked_at = null, finished_at = now(), updated_at = now() where id = j.id returning * into j;
  return jsonb_build_object('job_id', j.id, 'status', j.status);
end $$;


-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
revoke execute on function public.pit_etax_login_begin(uuid, uuid), public.pit_lirs_queue(uuid, int, uuid, text, jsonb) from public, anon;
grant execute on function public.pit_etax_login_begin(uuid, uuid), public.pit_lirs_queue(uuid, int, uuid, text, jsonb) to authenticated;
revoke execute on function public.svc_pit_etax_login_save(uuid, uuid, jsonb), public.svc_pit_etax_login_remove(uuid, uuid), public.svc_lirs_next(text),
  public.svc_lirs_report(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.svc_pit_etax_login_save(uuid, uuid, jsonb), public.svc_pit_etax_login_remove(uuid, uuid), public.svc_lirs_next(text),
  public.svc_lirs_report(uuid, jsonb) to service_role;
-- The private functions are for the database's own functions; the storage rule's check stays open to the app.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'private' and (p.proname like 'pit\_%' or p.proname like 'lirs\_%' or p.proname = 'portal_of') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;
grant execute on function private.pit_doc_path_ok(text) to authenticated;

-- ---------------------------------------------------------------------------
-- The bot's round: every five minutes, while a job is due (a retry, a payment check, or a job left running), the
-- database asks the taxstreem function to wake the bot. Nothing is called when there is nothing to do.
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'counta-lirs-bot';
    perform cron.schedule('counta-lirs-bot', '*/5 * * * *', $c$select private.call_function('taxstreem', '{"action":"lirs_wake"}'::jsonb)
      where exists (select 1 from public.lirs_jobs where (status = 'queued' and not_before <= now()) or (status = 'running' and locked_at < now() - interval '20 minutes'))$c$);
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- The admin portal's keys: the bot's address and the secret shared with it, with the others as they were.
-- ---------------------------------------------------------------------------
create or replace function private.secret_catalog() returns table (name text, grp text, label text, secret boolean, hint text, sort int)
language sql immutable as $$
  values
    ('GOOGLE_APPLICATION_CREDENTIALS_JSON', 'gemini', 'Service account key (JSON)', true, 'A Google Cloud service account with the Vertex AI User role. Paste the whole key file.', 101),
    ('GOOGLE_CLOUD_PROJECT', 'gemini', 'Google Cloud project', false, 'Leave empty to use the key''s own project.', 102),
    ('GOOGLE_CLOUD_LOCATION', 'gemini', 'Vertex AI region', false, 'us-central1 unless the project uses another region.', 103),
    ('GEMINI_MODEL', 'gemini', 'Gemini model', false, 'Leave empty for gemini-3.8-flash.', 104),
    ('GEMINI_API_KEY', 'gemini', 'Gemini API key (fallback)', true, 'Only used when there is no service account key.', 105),
    ('ELEVENLABS_API_KEY', 'elevenlabs', 'API key', true, 'Needs access to text to speech, voices, agents and phone numbers.', 201),
    ('ELEVENLABS_PHONE_NUMBER_ID', 'elevenlabs', 'Phone number for calls', false, 'Only needed when ElevenLabs has more than one number. The id from Phone Numbers in ElevenLabs.', 202),
    ('ELEVENLABS_TTS_MODEL', 'elevenlabs', 'Voice model for announcements', false, 'Leave empty for eleven_flash_v2_5.', 203),
    ('FLW_SECRET_KEY', 'flutterwave', 'Secret key', true, 'From Flutterwave, Settings, API keys. Live keys start FLWSECK-.', 301),
    ('FLW_PUBLIC_KEY', 'flutterwave', 'Public key', false, 'From the same page. Starts FLWPUBK-.', 302),
    ('FLW_WEBHOOK_HASH', 'flutterwave', 'Webhook secret hash', true, 'The same value as Secret hash in Flutterwave''s webhook settings.', 303),
    ('FLW_RELAY_URL', 'flutterwave', 'Transfer relay address', false, 'The https address of TaxStreem''s transfer relay (the server with the fixed IP address whitelisted on Flutterwave).', 304),
    ('FLW_RELAY_SECRET', 'flutterwave', 'Transfer relay secret', true, 'The 64 characters after RELAY_SECRET= in /etc/counta-relay.env on the relay server. Signs every request Counta sends through it.', 305),
    ('FLW_MERCHANT_ID', 'flutterwave', 'TaxStreem merchant ID', false, 'TaxStreem''s own Flutterwave merchant ID (Flutterwave, Settings, Business preferences). Counta plans paid from a business''s wallet go to this account.', 306),
    ('MONO_SECRET_KEY', 'mono', 'Secret key', true, 'From the Mono dashboard, for bank feeds.', 401),
    ('MONO_PUBLIC_KEY', 'mono', 'Public key', false, 'From the same app in the Mono dashboard.', 402),
    ('MONO_WEBHOOK_SECRET', 'mono', 'Webhook secret', true, 'The same value as the webhook secret in the Mono dashboard.', 403),
    ('MONO_LOOKUP_SECRET_KEY', 'mono', 'Lookup key (optional)', true, 'A separate key for CAC, Tax ID and NIN lookups. Without it the secret key is used.', 404),
    ('RESEND_API_KEY', 'email', 'Resend API key', true, 'From Resend, API keys, with sending access.', 501),
    ('RESEND_FROM', 'email', 'Sending address', false, 'An address on the domain verified in Resend, such as billing@taxstreem.com. Customers see "Business name via Counta".', 502),
    ('WHATSAPP_TOKEN', 'whatsapp', 'Access token', true, 'A permanent system user token from Meta Business, with WhatsApp messaging access.', 601),
    ('WHATSAPP_PHONE_NUMBER_ID', 'whatsapp', 'Phone number id', false, 'From WhatsApp, API setup, in the Meta app.', 602),
    ('WHATSAPP_BUSINESS_ACCOUNT_ID', 'whatsapp', 'Business account id', false, 'From the same page.', 603),
    ('WHATSAPP_APP_SECRET', 'whatsapp', 'App secret', true, 'From the Meta app''s basic settings. Checks that webhooks come from Meta.', 604),
    ('WHATSAPP_VERIFY_TOKEN', 'whatsapp', 'Webhook verify token', true, 'Any long random text, entered in the same place in the Meta app.', 605),
    ('WHATSAPP_TEMPLATE_LANG', 'whatsapp', 'Template language', false, 'en unless the message templates were approved in another language.', 606),
    ('WHATSAPP_PROVIDER', 'openwa', 'Which WhatsApp sends', false, 'openwa sends everything from TaxStreem''s number on the OpenWA server; meta uses the official WhatsApp Business API above. Leave empty for openwa once OpenWA is connected.', 650),
    ('OPENWA_URL', 'openwa', 'OpenWA server address', false, 'The https address of TaxStreem''s OpenWA server, such as https://wa.taxstreem.com.', 651),
    ('OPENWA_API_KEY', 'openwa', 'OpenWA API key', true, 'An Operator key made in the OpenWA dashboard, under API keys. Not the admin key.', 652),
    ('OPENWA_WEBHOOK_SECRET', 'openwa', 'Webhook secret', true, 'Counta makes this when you press Connect, and gives it to OpenWA. It proves that messages arriving at Counta came from your server.', 653),
    ('OPENWA_BUSINESS_NUMBERS', 'openwa', 'Businesses may link their own number', false, 'on lets businesses link their own WhatsApp number on the Integrations page, so their invoices come from it. Each linked number uses about 400 MB on the server. Leave empty for off.', 654),
    ('NUMENS_API_URL', 'numens', 'Numens address', false, 'The https address of TaxStreem''s tax model.', 701),
    ('NUMENS_API_KEY', 'numens', 'Numens key', true, null, 702),
    ('TAXSTREEM_SSO_SECRET', 'taxstreem', 'Single sign-on secret', true, 'Shared with TaxStreem, to sign people in from their TaxStreem account. Prism signs its bills and partners'' invoices with it too.', 801),
    ('TAXSTREEM_SSO_ISSUER', 'taxstreem', 'Single sign-on issuer', false, 'Leave empty for taxstreem.', 802),
    ('FLUX_URL', 'taxstreem', 'Flux address', false, 'The https address of TaxStreem Flux, which files returns on Rev360.', 803),
    ('FLUX_SECRET', 'taxstreem', 'Flux secret', true, 'Signs what Counta sends to Flux and checks what Flux sends back.', 804),
    ('FLUX_FILE_HOSTS', 'taxstreem', 'Flux file hosts', false, 'Other hosts Flux''s file links may point to, comma separated, such as files.taxstreem.com. Links on the Flux address itself are always allowed. Leave empty if Flux sends files only from there.', 805),
    ('PRISM_CALLBACK_URL', 'taxstreem', 'Prism callback address', false, 'The https address on Prism where Counta says how each partner invoice went with NRS (signed, refused, delivered to the buyer). Each call is signed with the single sign-on secret. Until it is set, the callbacks wait.', 806),
    ('LIRS_BOT_URL', 'taxstreem', 'LIRS bot address', false, 'The https address of Counta''s own LIRS e-Tax bot on Google Cloud Run (bots/lirs), such as https://counta-lirs-bot-xxxx.a.run.app. Counta wakes it when a return is sent or a transfer account is asked for.', 807),
    ('LIRS_BOT_SECRET', 'taxstreem', 'LIRS bot secret', true, 'The same value as the bot''s LIRS_BOT_SECRET (in Google Secret Manager), at least 32 characters. Signs what Counta and the bot send each other.', 808),
    ('APP_URL', 'counta', 'Counta web address', false, 'Used in links in emails and messages. Leave empty for https://counta-taxstreem.netlify.app.', 901),
    ('VAPID_SUBJECT', 'counta', 'Contact for push notifications', false, 'mailto: and an address browsers may write to about notifications.', 902),
    ('KYC_REVIEW_EMAIL', 'counta', 'Email for NIN slip reviews', false, 'Where Counta writes when a business''s NIN slip needs checking. Leave empty for admin@taxstreem.com. Reviewers on the Team page are told as well.', 903),
    ('NRS_BASE_URL', 'nrs', 'NRS e-invoicing address', false, 'The base address on the NRS e-invoicing dashboard (sandbox first, production after NRS''s review), such as https://… with nothing after the host.', 1001),
    ('NRS_API_KEY', 'nrs', 'API key', true, 'From the NRS e-invoicing dashboard. Sent as x-api-key.', 1002),
    ('NRS_API_SECRET', 'nrs', 'API secret', true, 'From the same page. Sent as x-api-secret.', 1003),
    ('NRS_BUSINESS_ID', 'nrs', 'TaxStreem''s Business ID', false, 'The Business ID NRS gave TaxStreem Technologies Limited when it was enabled for e-invoicing.', 1004),
    ('NRS_SERVICE_ID', 'nrs', 'TaxStreem''s Service ID', false, 'The 8-character Service ID NRS gave TaxStreem. It is the middle part of every IRN.', 1005),
    ('NRS_CRYPTO_KEYS', 'nrs', 'QR code keys (crypto_keys.txt)', true, 'The whole contents of crypto_keys.txt from My Account, Manage Cryptographic Keys: the public key and certificate the QR code is made with.', 1006),
    ('NRS_APP_API_KEY', 'nrs', 'APP API key', true, 'TaxStreem''s access point key, from NRS''s APP portal (einvoice.nrs.gov.ng/access-point), Developer section, once TaxStreem is an accredited access point. Sends invoices to buyers and brings in invoices for businesses. Until it is set, signed sales wait to go to the buyer.', 1007),
    ('NRS_APP_API_SECRET', 'nrs', 'APP API secret', true, 'The secret that goes with the APP key, from the same page.', 1008),
    ('GOOGLE_KMS_KEY_RING', 'kms', 'Key ring', false, 'Leave empty for projects/<project>/locations/us-central1/keyRings/counta-einvoice. It holds nrs-credentials (encrypt and decrypt) and invoice-signing (EC P-256, SHA-256), both HSM keys. The service account in Google Gemini above signs in, with Cloud KMS CryptoKey Encrypter/Decrypter on the first key and Signer/Verifier on the second.', 1101)
$$;
