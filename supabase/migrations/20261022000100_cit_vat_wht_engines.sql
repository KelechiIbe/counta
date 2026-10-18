-- Counta · companies income tax returns (prior, current and later years), and the VAT and WHT engines on TaxStreem's rule books
--
-- 1. Rule books. The NTA 2025 config (YOA 2026 onwards: accounts for years ending in 2025 and later) and the pre-NTA
--    CITA/TET config (accounts for years ending in 2024 and earlier) are stored as data. The engine reads rates, thresholds and
--    the sign-off flags from them. TaxStreem changes them; businesses cannot.
-- 2. The Rev360 CIT template (IT Excel template, version V2): every input cell, its label and where its figure comes from.
-- 3. CIT years: one row per business per accounting year, from 2023 accounts. Figures come from the books where Counta has them
--    for the whole year, otherwise from audited accounts or a trial balance mapped onto the template lines.
-- 4. WHT: the NRS rate matrix (resident / non-resident, corporate / non-corporate), exemptions, NRS or state service,
--    due dates, receipts to suppliers and the NRS and SIRS schedules.
-- 5. VAT: withholding VAT (as an agent, and when customers withhold it), self-charged VAT on services from abroad,
--    the small-company test, and the monthly position with the input VAT credit carried forward.

-- ---------------------------------------------------------------------------
-- 1. Rule books
-- ---------------------------------------------------------------------------
create table if not exists public.tax_rulebooks (
  id text primary key,
  config_id text not null,
  version text not null,
  regime text not null check (regime in ('NTA_2025', 'LEGACY_CITA')),
  yoa_from int,
  yoa_to int,
  status text not null check (status in ('draft', 'approved', 'retired')),
  config jsonb not null,
  approved_by text,
  approved_at timestamptz,
  note text,
  created_at timestamptz not null default now()
);
alter table public.tax_rulebooks enable row level security;
drop policy if exists tax_rulebooks_read on public.tax_rulebooks;
create policy tax_rulebooks_read on public.tax_rulebooks for select to authenticated using (true);

insert into public.tax_rulebooks (id, config_id, version, regime, yoa_from, yoa_to, status, config, approved_by, approved_at, note) values
  ('ng-cit-devlevy-engine@1.0.0', 'ng-cit-devlevy-engine', '1.0.0', 'NTA_2025', 2026, null, 'approved', $rb${"$schema": "https://taxstreem.dev/schemas/cit-config-v1.json", "meta": {"config_id": "ng-cit-devlevy-engine", "version": "1.0.0", "governing_law": "Nigeria Tax Act, 2025 (Act No. 7)", "gazette_date": "2025-06-26", "commencement_date": "2026-01-01", "applies_from_yoa": 2026, "filing_channel": "NRS Rev360 Self-Service Portal (IT Excel template)", "currency": "NGN", "description": "Canonical computation config: PBT -> CIT + Development Levy. The engine MUST select a rule set by year of assessment (YOA): YOA < 2026 uses the repealed CITA/TET/CGT regime (not in this config); YOA >= 2026 uses this config.", "rule_set_selector": {"field": "year_of_assessment", "branches": [{"when": "yoa < 2026", "engine": "LEGACY_CITA_TET_CGT", "note": "Out of scope for this config."}, {"when": "yoa >= 2026", "engine": "NTA_2025", "note": "This config."}]}}, "company_classification": {"description": "Run first. Gates CIT rate, Development Levy applicability, and ETR top-up.", "thresholds": {"small_company_turnover_max_ngn": 100000000, "small_company_fixed_assets_max_ngn": 250000000, "etr_turnover_trigger_ngn": 50000000000, "etr_mne_group_turnover_trigger_eur": 750000000}, "classes": {"SMALL": {"rule": "grossTurnover <= small_company_turnover_max_ngn AND totalFixedAssets <= small_company_fixed_assets_max_ngn", "logic": "AND", "statute": "s.202 (interpretation)", "cit_rate": 0.0, "subject_to_development_levy": false, "note": "Both conditions must hold. Still files a full return."}, "REGULAR": {"rule": "resident company that is not SMALL", "statute": "s.56(b)", "cit_rate": 0.3, "subject_to_development_levy": true}, "NON_RESIDENT": {"rule": "non-resident company taxed under s.17/s.18", "statute": "s.59(1)", "cit_basis": "source/PE/deemed-profit (out of scope for v1)", "subject_to_development_levy": false}}, "etr_in_scope": {"description": "Independent flag layered on top of class. Triggers s.57 15% minimum effective-tax-rate top-up.", "rule": "(isMNEConstituentEntity AND groupTurnoverEUR >= etr_mne_group_turnover_trigger_eur) OR (annualTurnoverNGN >= etr_turnover_trigger_ngn)", "statute": "s.57(2)", "carve_outs": ["Approved activities of a free-zone enterprise are excluded EXCEPT sales into the customs territory or where the entity is an MNE constituent under s.57(2)(a). [s.57(3)]"]}}, "cit_rates": {"description": "Applied to TOTAL PROFITS. Keep keyed by YOA + commencement order.", "statute": "s.56", "by_class": {"SMALL": 0.0, "REGULAR": 0.3, "NON_RESIDENT": null}, "future_rate_change": {"planned_rate": 0.25, "trigger": "Presidential order on the advice of the National Economic Council", "effective_date": null, "note": "Not yet effective. Do not hardcode 30%; resolve rate by YOA against the commencement order."}}, "development_levy": {"description": "Applied to ASSESSABLE PROFITS (Stage D), NOT total profits. Consolidates former TET/NITDA/NASENI/etc.", "statute": "s.59", "rate": 0.04, "base": "ASSESSABLE_PROFIT", "applies_when": "companyClass == 'REGULAR' AND NOT isNonResident AND NOT isHydrocarbonAssessableProfit", "exclusions": ["Small companies [s.59(1)]", "Non-resident companies [s.59(1)]", "Assessable profits computed for hydrocarbon tax [s.59(4)]"], "note": "Capital allowances and loss relief do NOT reduce this base. A company can owe NGN 0 CIT and still owe Development Levy."}, "etr_topup": {"description": "Domestic minimum top-up to a 15% effective tax rate. Only for etr_in_scope companies.", "statute": "s.57", "minimum_rate": 0.15, "net_income": {"formula": "PBT - frankedInvestmentIncome - unrealisedGainsLosses", "statute": "s.57(1)(c)", "life_insurer_adjustment": "Also exclude policyholders' gross income and investment income (s.57 proviso)."}, "covered_taxes": {"formula": "CIT + petroleumProfitTax + hydrocarbonTax + developmentLevy + prioritySectorTaxCredit", "statute": "s.57(1)(b)", "components": ["companies_income_tax", "petroleum_profit_tax", "hydrocarbon_tax", "development_levy", "priority_sector_tax_credit"]}, "topup_formula": "etr = coveredTaxes / netIncome ; topup = (etrInScope AND netIncome > 0 AND etr < 0.15) ? (0.15 * netIncome - coveredTaxes) : 0"}, "general_minimum_tax": {"exists": false, "note": "The legacy CITA turnover-based minimum tax is NOT carried into NTA 2025 for YOA 2026+. Functional floors are: SMALL @ 0%, 15% ETR (s.57), and sector-specific floors (e.g. s.18(6) 2% gross-revenue floor for non-resident shipping/air)."}, "capital_allowances": {"description": "Replace accounting depreciation. Reduce CIT only (via total profits); never reduce Development Levy.", "statute": "First Schedule, Part I", "single_flat_annual_rate": true, "no_initial_allowance_split": true, "no_two_thirds_restriction": true, "notional_retention_pct": 0.01, "notional_retention_note": "Record 1% of QCE for statistics until disposal (First Sched. para 6(a)); notional, does not change allowance claimable.", "table_I": {"statute": "First Schedule, para 6, Table I", "classes": [{"class": 1, "rate": 0.1, "qce_types": ["BUILDING", "AGRICULTURAL", "MAST", "INTANGIBLE_ASSETS", "HEAVY_TRANSPORTATION"]}, {"class": 2, "rate": 0.2, "qce_types": ["PLANT", "AGRICULTURAL_EQUIPMENT", "FURNITURE_AND_FITTINGS", "MINING", "OTHER_EQUIPMENT"]}, {"class": 3, "rate": 0.25, "qce_types": ["MOTOR_VEHICLE", "SOFTWARE", "OTHER_CAPITAL"]}]}, "category_to_class_map": {"description": "Maps Rev360 config!K2:K16 PPE/asset categories and common asset descriptions to a statutory class.", "Building Industrial": 1, "Building Non-Industrial": 1, "Agricultural plants expenditure": 1, "research and development expenditure": 1, "Housing estate expenditure": 1, "Plants (excluding Furniture and fittings)": 2, "Furnitures & Fittings expenditure": 2, "Plantation equipments expenditure": 2, "Construction Plants expenditure (excluding furniture & fittings)": 2, "ranching and plantation": 2, "Public Transport motor vehicles": 3, "Motor vehicles expenditure": 3, "software": 3, "Land": null, "Others": 2, "_land_note": "Land is not depreciable / not QCE on its own; exclude from capital allowances. Allocate building/works component to class 1."}, "rules": [{"id": "in_use_at_period_end", "rule": "Allowance only if at end of basis period the company OWNS the asset AND used it for the trade.", "statute": "1st Sched. para 6,7"}, {"id": "qualifying_expenditure", "rule": "Acquisition + refurbishment/improvement cost bringing asset to first use.", "statute": "1st Sched. para 1"}, {"id": "vat_duty_bar", "rule": "QCE disqualified if VAT due but not charged, or import duty/levy not paid on the asset.", "statute": "s.27(2)(b); 1st Sched. para 14"}, {"id": "priority_sector_certificate", "rule": "Priority-sector companies need Industrial Inspectorate certificate of acceptance for the QCE.", "statute": "s.27(2)(a)"}, {"id": "partial_use_proration", "rule": "Pro-rate allowance to the taxable-use portion where asset only partly used to generate assessable profit.", "statute": "s.27(3)"}, {"id": "de_minimis_no_proration", "rule": "Do NOT pro-rate where non-taxable income is < 10% of total income.", "threshold_pct": 0.1, "statute": "s.27(4)"}, {"id": "short_basis_period", "rule": "Pro-rate the allowance where the basis period is < 1 year (by days/365).", "statute": "1st Sched. para 6(b)"}, {"id": "hire_purchase_finance_lease", "rule": "Hirer/lessee treated as owner; QCE limited to instalments paid excluding interest; lessor gets no allowance.", "statute": "1st Sched. para 2,15"}, {"id": "operating_lease", "rule": "Lessor/owner claims the allowance as if used in its own trade.", "statute": "1st Sched. para 15(1)"}, {"id": "carry_forward_unused", "rule": "Unutilised allowance carries forward to succeeding years until fully utilised.", "statute": "1st Sched. para 20,22(3)"}, {"id": "order_of_deduction", "rule": "CA subtracted from remainder of assessable profit AFTER loss relief.", "statute": "1st Sched. para 22"}], "per_asset_pseudocode": "class=mapCategoryToClass(asset.category); rate=table_I[class].rate; qce=asset.cost (ex disallowed FX/duty); residue=qce - cumulativeAllowanceClaimed; annual=min(rate*qce, residue - notional_retention_pct*qce); if basisPeriodDays<365: annual*=basisPeriodDays/365; if assetPartlyUsed AND nonTaxableIncomePct>=0.10: annual*=taxableUsePct; capitalAllowanceYOA += asset.inUseAtPeriodEnd ? annual : 0"}, "loss_relief": {"description": "Reduces CIT only (applied to assessable profit before capital allowances).", "statute": "s.27(6)", "rules": {"direction": "CARRY_FORWARD_ONLY", "carry_back": false, "time_limit_years": null, "time_limit_note": "No cap; carry forward until fully recouped (legacy 4-year limit removed).", "same_trade_ring_fence": true, "aggregate_cap_equals_loss": true, "digital_asset_ring_fence": true, "order": "Deduct loss BEFORE capital allowances", "order_statute": "s.27(1); 1st Sched. para 22(2)"}}, "interest_restriction": {"description": "Thin-cap / EBITDA rule. Excess connected-person interest is an add-back.", "statute": "Third Schedule", "ebitda_cap_pct": 0.3, "ebitda_formula": "PBT + interestExpense + depreciation + amortisation (accounting basis)", "excess_formula": "excessInterest = max(0, connectedPersonInterest - 0.30 * EBITDA)", "treatment": "Add back excessInterest; carry forward up to 5 YOA.", "carry_forward_years": 5, "exemption": "Does NOT apply to a Nigerian subsidiary of a foreign bank or insurer (Third Sched. para 3)."}, "computation_pipeline": {"description": "Ordered stages A-K. starting_point and base outputs are critical.", "starting_point": "PROFIT_BEFORE_TAX", "stages": [{"id": "A", "name": "Profit Before Tax (PBT)", "op": "input", "source": "INCOME_STATEMENT!E763", "ref": "audited P&L before income-tax charge"}, {"id": "B", "name": "Add disallowable expenses / add-backs", "op": "add", "source": "sum(add_backs)", "statute": "s.21 + specific"}, {"id": "C", "name": "Deduct non-taxable income / tax-only deductions", "op": "subtract", "source": "sum(deductions)", "statute": "s.20, s.4 exemptions"}, {"id": "D", "name": "ASSESSABLE PROFIT", "op": "result", "formula": "A + B - C", "is_base_for": ["development_levy"], "statute": "s.22"}, {"id": "E1", "name": "Deduct loss relief brought forward", "op": "subtract", "source": "min(lossBfSameTrade, max(0, assessableProfit))", "statute": "s.27(6)"}, {"id": "E2", "name": "Deduct capital allowances (current + b/f)", "op": "subtract", "source": "min(capitalAllowanceTotal, remainderAfterLoss)", "statute": "First Schedule"}, {"id": "F", "name": "Add net chargeable gains for the YOA", "op": "add", "source": "net_chargeable_gains", "statute": "s.33-55, s.27(1)"}, {"id": "G", "name": "TOTAL PROFITS", "op": "result", "formula": "max(0, D - E1 - E2 + F)", "is_base_for": ["cit"], "statute": "s.27(1)"}, {"id": "H", "name": "CIT", "op": "charge", "formula": "G * cit_rate(class, yoa)", "statute": "s.56"}, {"id": "I", "name": "Development Levy", "op": "charge", "formula": "applies ? D * 0.04 : 0", "statute": "s.59"}, {"id": "J", "name": "ETR top-up", "op": "charge", "formula": "etr_topup (s.57)", "statute": "s.57"}, {"id": "K", "name": "Total liability", "op": "result", "formula": "H + I + J + sectorMinima"}], "tax_charge_addback_convention": {"description": "Lock one convention. Mixing double-counts/under-counts tax.", "selected": "START_FROM_PBT", "START_FROM_PBT": "Do NOT add back the income-tax provision (already below PBT). 'Taxes on profit or income' add-back = 0.", "START_FROM_PAT": "Rev360 template apparent design (PROFIT_ADJUSTMENT!D11 -> E765 = PAT). MUST add back full accounting tax charge (E764) to climb to PBT.", "statute": "s.21(e)"}}, "add_backs": {"description": "Disallowable expenses. Maps to PROFIT_ADJUSTMENT rows 13-35.", "items": [{"id": "depreciation_amortisation", "label": "Depreciation & amortisation", "statute": "s.21(g)", "rev360_row": 13}, {"id": "expenses_exempt_income", "label": "Expenses related to exempt income", "statute": "s.21(j)", "rev360_row": 14}, {"id": "donations_disallowed", "label": "Donations (to the extent not allowed)", "statute": "s.20(1), s.21", "rev360_row": 15}, {"id": "unrealised_fx_loss", "label": "Unrealised foreign-exchange loss", "statute": "s.21(g)", "rev360_row": 16}, {"id": "loss_on_disposal_fixed_assets", "label": "Loss on disposal of fixed assets", "statute": "s.21(b)", "rev360_row": 17}, {"id": "entertainment_disallowed", "label": "Entertainment expenses (to the extent not allowed)", "statute": "s.20(1)", "rev360_row": 18}, {"id": "capital_repaid_withdrawn", "label": "Capital repaid/withdrawn", "statute": "s.21(a)", "rev360_row": 19}, {"id": "capital_nature_expenses", "label": "Expenses of capital nature", "statute": "s.21(b)", "rev360_row": 20}, {"id": "assets_not_for_trade", "label": "Expenditure on assets not used for the purpose of trade", "statute": "s.21(c)", "rev360_row": 21}, {"id": "sum_recoverable_insurance", "label": "Sum recoverable under an insurance or contract of indemnity", "statute": "s.21(d)", "rev360_row": 22}, {"id": "taxes_on_profit_income", "label": "Taxes on profit or incomes", "statute": "s.21(e)", "rev360_row": 23, "note": "Only add back if starting from PAT. See computation_pipeline.tax_charge_addback_convention."}, {"id": "unapproved_pension", "label": "Payment to unapproved retirement fund/scheme", "statute": "s.21(f)", "rev360_row": 24}, {"id": "reserved_out_of_profits", "label": "Sums reserved out of profits", "statute": "s.21(h)", "rev360_row": 25}, {"id": "tp_contravention", "label": "Related-party payments contravening Transfer Pricing Regulations", "statute": "s.21(i)", "rev360_row": 26}, {"id": "expense_deriving_exempt_income", "label": "Expense incurred deriving exempt income", "statute": "s.21(j)", "rev360_row": 27}, {"id": "deductible_for_chargeable_gains", "label": "Expense allowable in determining chargeable gains", "statute": "s.21(k)", "rev360_row": 28}, {"id": "penalty_fine", "label": "Penalty or fine imposed under any law", "statute": "s.21(l)", "rev360_row": 29}, {"id": "vat_duty_uncharged_expense", "label": "Expenses liable to VAT/import duty but not charged or paid", "statute": "s.21(p)", "rev360_row": 30}, {"id": "securities_lending_compensating", "label": "Compensating payments (securities lending) qualifying as dividend/interest", "statute": "s.21(n),(o)", "rev360_row": 31}, {"id": "tax_penalty_borne_for_another", "label": "Tax or penalty borne on behalf of another person", "statute": "s.21(m)", "rev360_row": null}, {"id": "other_disallowable", "label": "Other disallowable expenses (free-text: description + amount)", "statute": "s.21", "rev360_row": 32}], "computed_not_prelisted": [{"id": "excess_connected_interest", "label": "Excess connected-party interest (> 30% EBITDA)", "statute": "Third Schedule", "see": "interest_restriction", "rev360_row": "use 'Other disallowable' with description"}, {"id": "general_provisions", "label": "General (non-specific) provisions e.g. general doubtful-debt provision", "statute": "s.20(1)(h)", "note": "Only specific/GAAP-justified doubtful debts allowed."}, {"id": "fx_naira_equivalent_excess", "label": "Excess over Naira equivalent at official CBN rate for foreign-currency expense", "statute": "s.20(4)"}]}, "deductions": {"description": "Non-taxable income removed / tax-only deductions added. Maps to PROFIT_ADJUSTMENT rows 40-49.", "items": [{"id": "profit_on_disposal_fixed_assets", "label": "Profit on disposal of fixed assets", "statute": "s.21(b), Part VIII", "rev360_row": 40, "note": "Capital; dealt with under chargeable gains."}, {"id": "franked_investment_income", "label": "Franked investment income (dividends already taxed)", "statute": "s.8, s.57(1)(c)", "rev360_row": 41, "note": "Also excluded from ETR net income."}, {"id": "unrealised_gains", "label": "Unrealised FX / fair-value gains", "statute": "general", "rev360_row": 42}, {"id": "other_non_taxable_income", "label": "Other non-taxable income (free-text: description + amount)", "statute": "s.4 exemptions", "rev360_row": 43}], "non_taxable_income_linkage": {"rule": "If non-taxable revenue present (INCOME_STATEMENT!D631 > 0) THEN 'Expenses Relating To Non-taxable revenue' (INCOME_STATEMENT!D641) MUST be populated.", "statute": "s.21(j)", "enforced_by": "CHECK_BEFORE_UPLOAD progress gate (will not reach 100% otherwise)."}}, "chargeable_gains": {"description": "CGT repealed; chargeable gains folded into income tax and taxed at the company's CIT rate (no separate 10% CGT).", "statute": "s.27(1), Part VIII (s.33-55)", "gain_formula": "disposalConsideration - allowableCostBase (acquisition + enhancement + disposal costs)", "gain_statute": "s.39, s.40", "basis": "Net chargeable gains over chargeable assets disposed in the basis period (s.26(3))", "rev360_source": "Chargeable Assets Disposal Return (portal computes and posts to income-tax computation).", "in_development_levy_base": false, "in_development_levy_base_note": "FLAG G-B: s.59 levies on 'assessable profits'; s.27 separates gains. Default excluded; confirm with NRS guidance. Configurable.", "selected_exemptions": [{"statute": "s.51", "label": "Principal private residence"}, {"statute": "s.52", "label": "Personal chattels"}, {"statute": "s.53", "label": "Up to 2 private-use motor vehicles per YOA"}, {"statute": "s.54", "label": "Gifts where no consideration passes"}, {"statute": "s.55", "label": "Assets held in trust for charities"}]}, "validation_rules": {"description": "Hard rules that BLOCK upload/submission until satisfied.", "rules": [{"id": "progress_100", "severity": "block", "rule": "CHECK_BEFORE_UPLOAD progress must equal 100%.", "source": "Rev360 manual"}, {"id": "revenue_ties_to_pl", "severity": "block", "rule": "Revenue declared must equal revenue in audited P&L."}, {"id": "sfp_ties_to_accounts", "severity": "block", "rule": "STATEMENT_OF_FINANCIAL_POSITION balances must equal audited balances."}, {"id": "no_expense_lumping", "severity": "block", "rule": "Each expense on its own line item; reject single-bucket 'Other expenses' lumping."}, {"id": "non_taxable_income_pairing", "severity": "block", "rule": "If INCOME_STATEMENT!D631 > 0 then INCOME_STATEMENT!D641 (related expenses) must be populated."}, {"id": "do_not_edit_formulas", "severity": "block", "rule": "Populate input cells only; do not alter embedded template formulas."}, {"id": "afs_attached_and_ties", "severity": "block", "rule": "Audited FS PDF attached (auditor report, P&L, SFP, cash flows, changes in equity, notes, capital-allowance schedule) and ties to template."}, {"id": "yoa_set", "severity": "block", "rule": "USER_INPUT!D7 (ASSESSMENT YEAR) set; selects rule set (see meta.rule_set_selector)."}, {"id": "sector_revenue_block", "severity": "warn", "rule": "Revenue entered against the correct sector block (one of 19 in config!C2:C20)."}, {"id": "small_company_still_files", "severity": "info", "rule": "SMALL companies still file a full return despite 0% CIT and no levy."}], "do_not_use_as_tax_rates": {"fields": "CHECK_BEFORE_UPLOAD percentages (0.28, 0.27, 0.25, 0.16, 0.04)", "rule": "These are completion-bar weights, NOT tax rates. Never feed into tax math."}}, "rev360_mapping": {"description": "Input/output contract. Emit data in this shape; never alter formulas.", "workbook": "CIT IT Excel template", "sheets": {"USER_INPUT": {"assessment_year_cell": "D7"}, "INCOME_STATEMENT": {"operating_profit_before_tax": "E763", "taxation_charge": "E764", "profit_after_tax": "E765", "operating_income": "E639", "administrative_expenses": "E640", "finance_cost_ex_interest": "E762", "total_revenue": "E526", "non_taxable_revenue": "D631", "expenses_relating_to_non_taxable_revenue": "D641", "depreciation_factory": "D593", "depreciation_admin": "D654"}, "PROFIT_ADJUSTMENT": {"profit_before_tax_ref": "D11", "profit_before_tax_points_to": "INCOME_STATEMENT!E765", "flag": "FLAG G-D: D11 points at E765 (PAT), not PBT. See computation_pipeline.tax_charge_addback_convention.", "addbacks_rows": "13-35", "total_addbacks": "D36", "deductions_rows": "40-49", "total_deductions": "D50"}, "STATEMENT_OF_FINANCIAL_POSITION": {"role": "assets/liabilities/equity; must tie to audited accounts"}, "CHECK_BEFORE_UPLOAD": {"completion_target": "D17 = 100%", "remaining": "D18"}, "config": {"sectors": "C2:C20 (19 sectors)", "ppe_categories": "K2:K16 (15 capital-allowance categories)", "income_statement_codes": "T/U columns", "cit_type": "AP2 = REGULAR"}}, "portal_workflow": ["Login", "Self Tax Filing", "Taxes Due", "select earliest CIT form", "File Now", "Fixed Assets Declaration (date, category, description, cost, depreciation)", "MNE disclosure (group turnover EUR)", "CFC disclosure", "download IT template", "complete offline", "upload", "Preview computation", "upload audited FS", "tick declaration", "Submit Return", "save acknowledgment"]}, "configurable_flags": {"description": "Items requiring tax-legal sign-off before go-live (rule book section 13). Defaults reflect the best statutory reading; make each configurable and reconcile against the live Rev360 preview.", "flags": {"development_levy_base_before_capital_allowances": {"default": true, "ref": "FLAG A", "note": "true => levy on assessable profit BEFORE capital allowances and loss relief (s.59 read with s.27)."}, "chargeable_gains_in_development_levy_base": {"default": false, "ref": "FLAG B", "note": "false => gains excluded from levy base; enter only at total-profits stage."}, "use_legacy_balancing_charge_allowance": {"default": false, "ref": "FLAG C", "note": "false => use residue + chargeable-gains path on disposal; terms absent from the Act."}, "tax_charge_addback_start_point": {"default": "START_FROM_PBT", "ref": "FLAG D", "enum": ["START_FROM_PBT", "START_FROM_PAT"]}, "treat_check_before_upload_pct_as_progress_only": {"default": true, "ref": "FLAG E", "note": "true => never treat 0.28/0.27/0.25/0.16/0.04 as tax rates."}, "rule_set_by_yoa": {"default": true, "ref": "FLAG F", "note": "true => branch engine by YOA (pre-2026 legacy; 2026+ NTA 2025)."}, "cit_rate_resolved_by_commencement_order": {"default": true, "ref": "FLAG G", "note": "true => 30% until a Presidential order sets 25%; do not hardcode."}, "etr_turnover_threshold_ngn": {"default": 50000000000, "ref": "FLAG H", "note": "NRS may raise by regulation (s.57(4)). EUR->NGN conversion convention for the EUR750m group test must be defined."}}}, "out_of_scope_sector_overrides": {"description": "Override the standard chain; gate behind sector flags before coding. v1 targets the regular resident company.", "regimes": [{"id": "petroleum", "statute": "Ch.3 s.65-88; 1st Sched. Part II"}, {"id": "insurance", "statute": "s.61"}, {"id": "lottery_gaming", "statute": "s.62"}, {"id": "collective_investment_scheme", "statute": "s.63"}, {"id": "mining", "statute": "s.64"}, {"id": "export_processing_free_zone", "statute": "s.60; 2nd Sched."}, {"id": "non_resident_deemed_profit", "statute": "s.17, s.18 (2% gross-revenue floor for shipping/air)"}, {"id": "economic_development_incentive_priority_sector", "statute": "s.165-166, s.27(5)"}, {"id": "real_estate_investment_company", "statute": "s.20(1)(k)"}]}, "worked_example": {"description": "Regular company, YOA 2026. Illustrates the two distinct bases.", "classification": "REGULAR (turnover NGN 2,000,000,000 > 100m; fixed assets 400m; not MNE; turnover < 50bn => not ETR_IN_SCOPE)", "lines": {"A_pbt": 300000000, "B_addbacks_total": 110000000, "B_detail": {"depreciation_amortisation": 80000000, "loss_on_disposal_fixed_asset": 3000000, "donations_disallowed": 5000000, "penalties_fines": 2000000, "general_provision": 10000000, "unrealised_fx_loss": 4000000, "excess_connected_interest": 6000000}, "C_deductions_total": 25000000, "C_detail": {"profit_on_disposal_fixed_assets": 8000000, "franked_investment_income": 12000000, "unrealised_gains": 5000000}, "D_assessable_profit": 385000000, "E1_loss_relief_bf": 20000000, "remainder_after_loss": 365000000, "E2_capital_allowances": 95000000, "remainder_after_allowances": 270000000, "F_net_chargeable_gains": 6000000, "G_total_profits": 276000000, "H_cit": 82800000, "I_development_levy": 15400000, "J_etr_topup": 0, "K_total_liability": 98200000}, "small_company_contrast": {"classification": "SMALL (turnover NGN 90,000,000; fixed assets 200,000,000)", "cit": 0, "development_levy": 0, "note": "Still files a full return."}}, "statutory_index": {"imposition_chargeability": "s.3-5", "nigerian_company_dividends": "s.6-10", "deductions_allowed": "s.20", "deductions_not_allowed": "s.21", "assessable_profits_basis_period": "s.22-25", "total_profits_of_companies": "s.27", "chargeable_gains": "s.33-55", "cit_rates": "s.56", "effective_tax_rate": "s.57", "development_levy": "s.59", "specialised_trades": "s.60-64", "petroleum_hydrocarbon": "s.65-88", "capital_allowances": "First Schedule Part I (Table I)", "interest_restriction": "Third Schedule", "individual_rates": "Fourth Schedule", "small_company_definition": "s.202", "commencement": "enacting clause (1 January 2026)"}}$rb$::jsonb,
   'TaxStreem', '2026-10-18', 'Supplied by TaxStreem (Kelechi Ibe), 18 October 2026.'),
  ('ng-cit-cita-legacy-engine@0.9.0', 'ng-cit-cita-legacy-engine', '0.9.0', 'LEGACY_CITA', null, 2025, 'draft', $rb${"$schema": "https://taxstreem.dev/schemas/cit-config-v1.json", "meta": {"config_id": "ng-cit-cita-legacy-engine", "version": "0.9.0", "status": "draft_pending_signoff", "drafted_by": "Counta (for TaxStreem tax-legal sign-off)", "governing_law": "Companies Income Tax Act Cap C21 LFN 2004 as amended by the Finance Acts 2019, 2020, 2021 and 2023; Tertiary Education Trust Fund (Establishment, etc.) Act 2011 as amended", "currency": "NGN", "applies_to_yoa": 2025, "accounting_years_covered": "Accounts for years ending in 2024 or earlier (year of assessment = accounting year + 1). Counta prepares returns from 2023 accounts (YOA 2024); earlier years are used only to roll capital allowance tax values forward.", "description": "Pre-NTA regime: CIT by company size, tertiary education tax, minimum tax, CITA capital allowances (initial + annual, two-thirds restriction, NGN10 retention). The engine selects this rule set when YOA <= 2025 (meta.rule_set_selector of the NTA config).", "filing_channel": "NRS Rev360 Self-Service Portal (IT Excel template; same template version as YOA 2026)"}, "company_classification": {"description": "Run first. Gates the CIT rate, tertiary education tax and minimum tax.", "statute": "CITA s.40(1) and s.105 as amended by Finance Act 2019", "measure": "Gross turnover of the accounting year (revenue in the profit or loss account, before cost of sales)", "classes": {"SMALL": {"turnover_max_ngn": 25000000, "cit_rate": 0.0, "tertiary_education_tax": false, "minimum_tax": false, "note": "Gross turnover of NGN25m or less. Still files a full return."}, "MEDIUM": {"turnover_min_exclusive_ngn": 25000000, "turnover_max_exclusive_ngn": 100000000, "cit_rate": 0.2, "tertiary_education_tax": true, "minimum_tax": true}, "LARGE": {"turnover_min_ngn": 100000000, "cit_rate": 0.3, "tertiary_education_tax": true, "minimum_tax": true}}, "professional_services_exclusion": false, "professional_services_note": "The professional-services exclusion is an NTA 2025 (s.202) rule; under CITA a professional firm is classified on turnover like any other company."}, "tertiary_education_tax": {"statute": "TETFund Act 2011 s.1(2), as amended by Finance Act 2021 (2.5%) and Finance Act 2023 (3%)", "rate_by_yoa": {"2021": 0.02, "2022": 0.025, "2023": 0.03, "2024": 0.03, "2025": 0.03}, "base": "ASSESSABLE_PROFIT", "base_note": "Assessable profit as defined by CITA s.30: adjusted profit after balancing charges, before loss relief and before capital allowances.", "exempt_small_companies": true, "exempt_small_companies_note": "Finance Act 2021 took small companies out of the tax.", "signoff_flag": "FLAG L-A: confirm the base (before loss relief and capital allowances)."}, "minimum_tax": {"statute": "CITA s.33 as amended by Finance Acts 2019 and 2020", "rate": 0.005, "base": "GROSS_TURNOVER_LESS_FRANKED_INVESTMENT_INCOME", "applies_when": "Total profits give no tax, or tax lower than the minimum tax: CIT payable = max(CIT computed, minimum tax).", "rate_history": [{"returns_due_from": "2020-01-01", "returns_due_to": "2021-12-31", "rate": 0.0025, "note": "COVID relief (Finance Act 2020)."}], "exemptions": [{"id": "small_company", "rule": "Gross turnover of NGN25m or less (Finance Act 2019)."}, {"id": "first_four_years", "rule": "First four calendar years from commencement of business (uses the incorporation date when no commencement date is recorded)."}, {"id": "agricultural_trade", "rule": "Company carrying on agricultural trade or business."}, {"id": "imported_equity", "rule": "At least 25% of share capital imported (paid in foreign currency)."}], "signoff_flag": "FLAG L-B: confirm the exemption list and that medium companies pay minimum tax."}, "cit_rates": {"statute": "CITA s.40(1)", "by_class": {"SMALL": 0.0, "MEDIUM": 0.2, "LARGE": 0.3}, "applies_to": "TOTAL_PROFITS"}, "capital_allowances": {"statute": "CITA Second Schedule (Tables I and II), paras 7-24", "method": "INITIAL_PLUS_ANNUAL", "description": "Initial allowance in the year the asset is first in use; annual allowance each year on cost less initial allowance (straight line), from the first year, until NGN10 is left. Both need the asset owned and in use for the trade at the end of the basis period.", "retention_ngn": 10, "retention_note": "NGN10 stays in the tax value of each asset until disposal (para 24).", "categories": {"Building Industrial": {"initial": 0.15, "annual": 0.1}, "Building Non-Industrial": {"initial": 0.15, "annual": 0.1}, "Plants (excluding Furniture and fittings)": {"initial": 0.5, "annual": 0.25}, "Agricultural plants expenditure": {"initial": 0.95, "annual": 0.0}, "Furnitures & Fittings expenditure": {"initial": 0.25, "annual": 0.2}, "Public Transport motor vehicles": {"initial": 0.95, "annual": 0.0}, "Motor vehicles expenditure": {"initial": 0.5, "annual": 0.25}, "Plantation equipments expenditure": {"initial": 0.95, "annual": 0.0}, "Construction Plants expenditure (excluding furniture & fittings)": {"initial": 0.5, "annual": 0.0}, "research and development expenditure": {"initial": 0.95, "annual": 0.0}, "Housing estate expenditure": {"initial": 0.5, "annual": 0.25}, "ranching and plantation": {"initial": 0.3, "annual": 0.5}, "software": {"initial": 0.5, "annual": 0.25, "note": "No software class in the Second Schedule; treated as plant. FLAG L-C."}, "Others": {"initial": 0.5, "annual": 0.25, "note": "Treated as plant. FLAG L-C."}, "Land": null}, "investment_allowance": {"statute": "CITA s.32", "rate": 0.1, "categories": ["Plants (excluding Furniture and fittings)", "Agricultural plants expenditure", "Plantation equipments expenditure", "Construction Plants expenditure (excluding furniture & fittings)"], "note": "10% of the cost of plant and equipment in the year first used; does not reduce the tax value. FLAG L-D: confirm it is still claimed and on which categories."}, "restriction": {"statute": "CITA s.31 / Second Schedule para 24(8)", "fraction_of_assessable_profit": 0.6667, "exact_fraction": "2/3", "exempt_sectors": ["MANUFACTURING", "AGRICULTURE, FORESTRY & FISHING"], "note": "Allowances used in a year cannot exceed two-thirds of assessable profit, except for manufacturing and agro-allied companies. Unused allowances carry forward without time limit. FLAG L-E: confirm the cap is on assessable profit before loss relief."}, "balancing_adjustments": {"statute": "CITA Second Schedule paras 12-14", "balancing_charge": "min(proceeds - tax value, allowances claimed) when proceeds exceed tax value; added to assessable profit", "balancing_allowance": "tax value - proceeds when proceeds are below tax value; added to the year's allowances", "chargeable_gain_note": "Any gain above original cost is a chargeable gain under the Capital Gains Tax Act (10%, separate return), not part of CIT."}, "rules": [{"id": "in_use_at_period_end", "rule": "Allowance only if the asset is owned and in use for the trade at the end of the basis period."}, {"id": "land_excluded", "rule": "Land is not qualifying expenditure."}, {"id": "carry_forward_unused", "rule": "Unused allowances carry forward indefinitely."}, {"id": "order_of_deduction", "rule": "Loss relief first, then capital allowances (within the two-thirds cap)."}]}, "loss_relief": {"statute": "CITA s.31(1)(b) as amended", "rules": {"direction": "CARRY_FORWARD_ONLY", "time_limit_years": null, "time_limit_note": "No time limit for companies (the four-year limit for insurers was removed by Finance Act 2021).", "same_trade_ring_fence": true, "order": "Deduct loss BEFORE capital allowances"}}, "interest_restriction": {"statute": "CITA s.24(2) proviso as inserted by Finance Act 2019", "applies_to": "Interest paid to a foreign connected person", "ebitda_cap_pct": 0.3, "ebitda_formula": "PBT + interestExpense + depreciation + amortisation (accounting basis)", "excess_formula": "excessInterest = max(0, connectedForeignInterest - 0.30 * EBITDA)", "carry_forward_years": 5, "exemption": "Does not apply to a Nigerian subsidiary of a foreign bank or insurer."}, "computation_pipeline": {"starting_point": "PROFIT_BEFORE_TAX", "stages": [{"id": "A", "name": "Profit before tax", "source": "INCOME_STATEMENT!E115"}, {"id": "B", "name": "Add disallowable expenses", "source": "PROFIT_ADJUSTMENT!E33"}, {"id": "C", "name": "Deduct non-taxable income", "source": "PROFIT_ADJUSTMENT!E41"}, {"id": "D", "name": "Adjusted profit", "formula": "A + B - C"}, {"id": "D2", "name": "Add balancing charges", "source": "capital allowance schedule"}, {"id": "AP", "name": "ASSESSABLE PROFIT", "formula": "D + D2", "is_base_for": ["tertiary_education_tax"]}, {"id": "E1", "name": "Loss relief brought forward", "formula": "min(lossBf, max(0, AP))"}, {"id": "E2", "name": "Capital allowances used", "formula": "min(CA available, cap (2/3 of AP unless exempt sector), AP - E1)"}, {"id": "G", "name": "TOTAL PROFITS", "formula": "max(0, AP - E1 - E2)", "is_base_for": ["cit"]}, {"id": "H", "name": "CIT", "formula": "G * cit_rate(class)"}, {"id": "MT", "name": "Minimum tax", "formula": "applies ? rate * (turnover - FII) : 0"}, {"id": "H2", "name": "CIT payable", "formula": "minimumTaxApplies ? max(H, MT) : H"}, {"id": "I", "name": "Tertiary education tax", "formula": "class <> SMALL ? rate(yoa) * max(0, AP) : 0"}, {"id": "K", "name": "Total liability", "formula": "H2 + I"}], "tax_charge_addback_convention": {"selected": "START_FROM_PBT", "note": "The template starts from profit before tax (PROFIT_ADJUSTMENT!E11 = INCOME_STATEMENT!E115), so the tax charge is not added back."}}, "add_backs": {"description": "Same template rows as the NTA config (PROFIT_ADJUSTMENT rows 13-32). Statutory basis is CITA s.27 (deductions not allowed) and s.24 (allowable deductions).", "donations": {"statute": "CITA s.25 and Fifth Schedule", "rule": "Donations to listed bodies allowed up to 10% of total profits before the donation; the rest, and donations to unlisted bodies, are added back.", "cap_pct": 0.1}, "general_provisions": {"statute": "CITA s.24(d)", "rule": "Only specific bad debts are deductible; general provisions are added back."}, "depreciation": {"statute": "CITA s.27", "rule": "Depreciation and amortisation are added back; capital allowances are given instead."}}, "deductions": {"description": "Same template rows as the NTA config (PROFIT_ADJUSTMENT rows 36-40).", "chargeable_gains": "Profit on disposal of fixed assets and investments is removed from CIT; any chargeable gain goes to the separate capital gains tax return (10%)."}, "out_of_scope_v1": [{"id": "commencement_cessation", "statute": "CITA s.29(3)-(4)", "note": "First, second and third years of a new business and the last years of a ceasing business use special basis periods. Counta flags these years for manual review."}, {"id": "excess_dividend_tax", "statute": "CITA s.19 as amended by Finance Act 2019"}, {"id": "police_trust_fund_levy", "statute": "Nigeria Police Trust Fund (Establishment) Act 2019, 0.005% of net profit", "note": "Separate levy, not in the CIT template."}, {"id": "nitda_levy", "statute": "NITDA Act 2007 s.12, 1% of profit before tax for specified companies", "note": "Separate levy."}, {"id": "naseni_levy", "statute": "NASENI Act 2023, 0.25% of profit before tax for specified sectors", "note": "Separate levy."}, {"id": "capital_gains_tax", "statute": "Capital Gains Tax Act, 10%", "note": "Separate return."}, {"id": "petroleum_insurance_special_regimes", "note": "As in the NTA config."}], "signoff_flags": {"L-A": "Tertiary education tax base: assessable profit before loss relief and capital allowances.", "L-B": "Minimum tax: 0.5% of turnover less franked investment income; applies to medium and large companies; exemption list as above.", "L-C": "Software and 'Others' categories treated as plant (50% initial, 25% annual).", "L-D": "Investment allowance of 10% on plant and equipment categories.", "L-E": "Two-thirds cap measured on assessable profit before loss relief; manufacturing and agro-allied exempt.", "L-F": "TET exempts small companies (Finance Act 2021)."}}$rb$::jsonb,
   null, null, 'Drafted by Counta from CITA as amended; awaiting TaxStreem tax-legal sign-off.')
on conflict (id) do update set config = excluded.config, status = case when public.tax_rulebooks.status = 'approved' then public.tax_rulebooks.status else excluded.status end,
  yoa_from = excluded.yoa_from, yoa_to = excluded.yoa_to, note = excluded.note;

-- The rule book for a year of assessment: the approved one when there is one, otherwise the newest draft.
create or replace function private.rulebook(p_yoa int) returns public.tax_rulebooks
language sql stable security definer set search_path = public, private as $$
  select r.* from tax_rulebooks r
  where r.status in ('approved', 'draft') and (r.yoa_from is null or r.yoa_from <= p_yoa) and (r.yoa_to is null or r.yoa_to >= p_yoa)
  order by (r.status = 'approved') desc, r.created_at desc limit 1
$$;
create or replace function private.rb(p_rb jsonb, variadic p_path text[]) returns jsonb
language sql immutable set search_path = '' as $$ select p_rb #> p_path $$;
create or replace function private.rbn(p_rb jsonb, variadic p_path text[]) returns numeric
language sql immutable set search_path = '' as $$ select case when jsonb_typeof(p_rb #> p_path) = 'number' then (p_rb #>> p_path)::numeric end $$;
create or replace function private.rbb(p_rb jsonb, variadic p_path text[]) returns boolean
language sql immutable set search_path = '' as $$ select case when jsonb_typeof(p_rb #> p_path) = 'boolean' then (p_rb #>> p_path)::boolean end $$;

-- ---------------------------------------------------------------------------
-- 2. The Rev360 CIT template (V2): input cells and where each figure comes from
-- ---------------------------------------------------------------------------
-- basis: movement (profit or loss for the year), balance_start / balance_end (account balances), adjustment (profit
-- adjustment rows), retained_start, computed. sign: dr = debit-positive (expenses, assets), cr = credit-positive.
-- positive_only: the template accepts only amounts above zero there. negative_to: where a debit balance on an income line goes.
create table if not exists public.cit_template_lines (
  cell text primary key,
  sheet text not null,
  addr text not null,
  sort int not null,
  section text not null,
  label text not null,
  codes text[] not null default '{}',
  basis text,
  sign text,
  positive_only boolean not null default false,
  negative_to text,
  config_id text,
  note text
);
alter table public.cit_template_lines enable row level security;
drop policy if exists cit_template_lines_read on public.cit_template_lines;
create policy cit_template_lines_read on public.cit_template_lines for select to authenticated using (true);
insert into public.cit_template_lines (cell, sheet, addr, sort, section, label, codes, basis, sign, positive_only, negative_to, config_id, note) values
  ('USER_INPUT!D7', 'USER_INPUT', 'D7', 1, 'year', 'ACCOUNTING YEAR', '{}', 'computed', null, false, null, null, 'Accounting year'),
  ('INCOME_STATEMENT!D7', 'INCOME_STATEMENT', 'D7', 2, 'revenue', 'MANUFACTURING', array['4101'], 'movement', 'cr', true, null, null, 'Sales returns (4131) and discounts allowed (4132) are shared across the sectors in proportion to their sales.'),
  ('INCOME_STATEMENT!D8', 'INCOME_STATEMENT', 'D8', 3, 'revenue', 'AGRICULTURE, FORESTRY & FISHING', array['4102'], 'movement', 'cr', true, null, null, 'Sales returns (4131) and discounts allowed (4132) are shared across the sectors in proportion to their sales.'),
  ('INCOME_STATEMENT!D9', 'INCOME_STATEMENT', 'D9', 4, 'revenue', 'MINNING & QUARRY', array['4103'], 'movement', 'cr', true, null, null, 'Sales returns (4131) and discounts allowed (4132) are shared across the sectors in proportion to their sales.'),
  ('INCOME_STATEMENT!D10', 'INCOME_STATEMENT', 'D10', 5, 'revenue', 'ELECTRICITY', array['4104'], 'movement', 'cr', true, null, null, 'Sales returns (4131) and discounts allowed (4132) are shared across the sectors in proportion to their sales.'),
  ('INCOME_STATEMENT!D11', 'INCOME_STATEMENT', 'D11', 6, 'revenue', 'WATER SUPPLY, SEWERAGE & WASTE MANAGEMENT', array['4105'], 'movement', 'cr', true, null, null, 'Sales returns (4131) and discounts allowed (4132) are shared across the sectors in proportion to their sales.'),
  ('INCOME_STATEMENT!D12', 'INCOME_STATEMENT', 'D12', 7, 'revenue', 'CONSTRUCTION', array['4106'], 'movement', 'cr', true, null, null, 'Sales returns (4131) and discounts allowed (4132) are shared across the sectors in proportion to their sales.'),
  ('INCOME_STATEMENT!D13', 'INCOME_STATEMENT', 'D13', 8, 'revenue', 'WHOLESALE AND RETAIL TRADE', array['4107'], 'movement', 'cr', true, null, null, 'Sales returns (4131) and discounts allowed (4132) are shared across the sectors in proportion to their sales.'),
  ('INCOME_STATEMENT!D14', 'INCOME_STATEMENT', 'D14', 9, 'revenue', 'TRANSPORTATION AND HAULAGE', array['4108'], 'movement', 'cr', true, null, null, 'Sales returns (4131) and discounts allowed (4132) are shared across the sectors in proportion to their sales.'),
  ('INCOME_STATEMENT!D15', 'INCOME_STATEMENT', 'D15', 10, 'revenue', 'ACCOMODATION AND FOOD SERVICE ACTIVITIES', array['4109'], 'movement', 'cr', true, null, null, 'Sales returns (4131) and discounts allowed (4132) are shared across the sectors in proportion to their sales.'),
  ('INCOME_STATEMENT!D16', 'INCOME_STATEMENT', 'D16', 11, 'revenue', 'COMMUNICATION &. INFORMATION', array['4110'], 'movement', 'cr', true, null, null, 'Sales returns (4131) and discounts allowed (4132) are shared across the sectors in proportion to their sales.'),
  ('INCOME_STATEMENT!D17', 'INCOME_STATEMENT', 'D17', 12, 'revenue', 'BANKS & OTHER FINANCIAL AND  ACTIVITIES', array['4111'], 'movement', 'cr', true, null, null, 'Sales returns (4131) and discounts allowed (4132) are shared across the sectors in proportion to their sales.'),
  ('INCOME_STATEMENT!D18', 'INCOME_STATEMENT', 'D18', 13, 'revenue', 'INSURANCE ACTIVITIES', array['4112'], 'movement', 'cr', true, null, null, 'Sales returns (4131) and discounts allowed (4132) are shared across the sectors in proportion to their sales.'),
  ('INCOME_STATEMENT!D19', 'INCOME_STATEMENT', 'D19', 14, 'revenue', 'REAL ESTATE ACTIVITIES', array['4113'], 'movement', 'cr', true, null, null, 'Sales returns (4131) and discounts allowed (4132) are shared across the sectors in proportion to their sales.'),
  ('INCOME_STATEMENT!D20', 'INCOME_STATEMENT', 'D20', 15, 'revenue', 'PROFESSIONAL, SCIENTIFIC AND TECHNICAL ACTIVITIES', array['4114'], 'movement', 'cr', true, null, null, 'Sales returns (4131) and discounts allowed (4132) are shared across the sectors in proportion to their sales.'),
  ('INCOME_STATEMENT!D21', 'INCOME_STATEMENT', 'D21', 16, 'revenue', 'ADMINISTRATIVE AND SUPPORT ACTIVITIES', array['4115'], 'movement', 'cr', true, null, null, 'Sales returns (4131) and discounts allowed (4132) are shared across the sectors in proportion to their sales.'),
  ('INCOME_STATEMENT!D22', 'INCOME_STATEMENT', 'D22', 17, 'revenue', 'EDUCATION', array['4116'], 'movement', 'cr', true, null, null, 'Sales returns (4131) and discounts allowed (4132) are shared across the sectors in proportion to their sales.'),
  ('INCOME_STATEMENT!D23', 'INCOME_STATEMENT', 'D23', 18, 'revenue', 'OIL AND GAS', array['4117'], 'movement', 'cr', true, null, null, 'Sales returns (4131) and discounts allowed (4132) are shared across the sectors in proportion to their sales.'),
  ('INCOME_STATEMENT!D24', 'INCOME_STATEMENT', 'D24', 19, 'revenue', 'NGOs, NFPOs, RELIGIOUS INSTITUTIONS', array['4118'], 'movement', 'cr', true, null, null, 'Sales returns (4131) and discounts allowed (4132) are shared across the sectors in proportion to their sales.'),
  ('INCOME_STATEMENT!D25', 'INCOME_STATEMENT', 'D25', 20, 'revenue', 'ART, ENTERTAINMENT AND RECREATION', array['4119'], 'movement', 'cr', true, null, null, 'Sales returns (4131) and discounts allowed (4132) are shared across the sectors in proportion to their sales.'),
  ('INCOME_STATEMENT!D26', 'INCOME_STATEMENT', 'D26', 21, 'revenue', 'DIGITAL AND VIRTUAL ASSETS', array['4120'], 'movement', 'cr', true, null, null, 'Sales returns (4131) and discounts allowed (4132) are shared across the sectors in proportion to their sales.'),
  ('INCOME_STATEMENT!D27', 'INCOME_STATEMENT', 'D27', 22, 'revenue', 'Others', array['4121'], 'movement', 'cr', true, null, null, 'Sales returns (4131) and discounts allowed (4132) are shared across the sectors in proportion to their sales.'),
  ('INCOME_STATEMENT!D66', 'INCOME_STATEMENT', 'D66', 23, 'cost_of_sales', 'Raw materials', array['1201'], 'balance_start', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D67', 'INCOME_STATEMENT', 'D67', 24, 'cost_of_sales', 'Work in progress', array['1202'], 'balance_start', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D68', 'INCOME_STATEMENT', 'D68', 25, 'cost_of_sales', 'Finished goods', array['1203','1207'], 'balance_start', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D71', 'INCOME_STATEMENT', 'D71', 26, 'cost_of_sales', 'Local Purchases', array['5101'], 'movement', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D72', 'INCOME_STATEMENT', 'D72', 27, 'cost_of_sales', 'Import Purchases', array['5102','5105'], 'movement', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D73', 'INCOME_STATEMENT', 'D73', 28, 'cost_of_sales', 'Returns Outwards', array['5103'], 'movement', 'cr', false, null, null, null),
  ('INCOME_STATEMENT!D76', 'INCOME_STATEMENT', 'D76', 29, 'cost_of_sales', 'Direct wages', array['5201'], 'movement', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D77', 'INCOME_STATEMENT', 'D77', 30, 'cost_of_sales', 'Direct expenses', array['5202','5203'], 'movement', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D78', 'INCOME_STATEMENT', 'D78', 31, 'cost_of_sales', 'Carriage Inwards', array['5104'], 'movement', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D79', 'INCOME_STATEMENT', 'D79', 32, 'cost_of_sales', 'Depreciation', array['5204'], 'movement', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D80', 'INCOME_STATEMENT', 'D80', 33, 'cost_of_sales', 'Mining Cost', array['5206'], 'movement', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D81', 'INCOME_STATEMENT', 'D81', 34, 'cost_of_sales', 'Direct construction cost', array['5207'], 'movement', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D82', 'INCOME_STATEMENT', 'D82', 35, 'cost_of_sales', 'Cost of Storage', array['5208'], 'movement', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D83', 'INCOME_STATEMENT', 'D83', 36, 'cost_of_sales', 'Amortisation of intangible assets', array['5205'], 'movement', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D84', 'INCOME_STATEMENT', 'D84', 37, 'cost_of_sales', 'Other Direct costs', array['5209','5401','5400'], 'movement', 'dr', false, null, null, 'Other direct costs, plus the difference between the inventory movement in the books (5400) and opening less closing inventory, so cost of sales agrees with the accounts.'),
  ('INCOME_STATEMENT!D87', 'INCOME_STATEMENT', 'D87', 38, 'cost_of_sales', 'Factory Rent', array['5301'], 'movement', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D88', 'INCOME_STATEMENT', 'D88', 39, 'cost_of_sales', 'Factory Rates', array['5302'], 'movement', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D89', 'INCOME_STATEMENT', 'D89', 40, 'cost_of_sales', 'Fuel and Power', array['5303'], 'movement', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D90', 'INCOME_STATEMENT', 'D90', 41, 'cost_of_sales', 'Indirect Wages', array['5304'], 'movement', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D91', 'INCOME_STATEMENT', 'D91', 42, 'cost_of_sales', 'Other Factory Overheads', array['5305','5306'], 'movement', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D94', 'INCOME_STATEMENT', 'D94', 43, 'cost_of_sales', 'Raw materials', array['1201'], 'balance_end', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D95', 'INCOME_STATEMENT', 'D95', 44, 'cost_of_sales', 'Work In Progress', array['1202'], 'balance_end', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D96', 'INCOME_STATEMENT', 'D96', 45, 'cost_of_sales', 'Finished goods', array['1203','1207'], 'balance_end', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D113', 'INCOME_STATEMENT', 'D113', 46, 'pl', 'Expenses Relating To Non-taxable revenue', '{}', 'adjustment', 'dr', true, null, null, 'Expenses relating to non-taxable revenue: needed whenever non-taxable revenue is declared. Taken from the add-back for expenses on exempt income.'),
  ('INCOME_STATEMENT!D114', 'INCOME_STATEMENT', 'D114', 47, 'pl', 'Finance Cost (Excluding Interest Expense)', array['7101','7102','7104','7105'], 'movement', 'dr', false, null, null, null),
  ('INCOME_STATEMENT!D116', 'INCOME_STATEMENT', 'D116', 48, 'pl', 'Taxation', array['7501','7502','7503','7504','7505'], 'movement', 'dr', true, null, null, null),
  ('INCOME_STATEMENT!D119', 'INCOME_STATEMENT', 'D119', 49, 'oci', 'Revaluation Gain/Loss', array['8001'], 'movement', 'cr', true, null, null, null),
  ('INCOME_STATEMENT!D120', 'INCOME_STATEMENT', 'D120', 50, 'oci', 'Unrealized foreign exchange gainX', array['8007'], 'movement', 'cr', true, null, null, null),
  ('INCOME_STATEMENT!D121', 'INCOME_STATEMENT', 'D121', 51, 'oci', 'Currency Translation Adjustments', array['8003'], 'movement', 'cr', true, null, null, null),
  ('INCOME_STATEMENT!D122', 'INCOME_STATEMENT', 'D122', 52, 'oci', 'Cash Flow Hedge', array['8004'], 'movement', 'cr', true, null, null, null),
  ('INCOME_STATEMENT!D123', 'INCOME_STATEMENT', 'D123', 53, 'oci', 'Gain Or Loss On Derivative Contracts', array['8006'], 'movement', 'cr', true, null, null, null),
  ('INCOME_STATEMENT!D124', 'INCOME_STATEMENT', 'D124', 54, 'oci', 'Pension Plans Adustments', array['8002'], 'movement', 'cr', true, null, null, null),
  ('INCOME_STATEMENT!D125', 'INCOME_STATEMENT', 'D125', 55, 'oci', 'Others', array['8005','8008','8009'], 'movement', 'cr', true, null, null, null),
  ('INCOME_STATEMENT!D127', 'INCOME_STATEMENT', 'D127', 56, 'pl', 'Retained Earnings Brought Forward', '{}', 'retained_start', 'cr', false, null, null, 'Retained earnings at the start of the year, including profit not yet closed.'),
  ('OTHER_INCOME!D4', 'OTHER_INCOME', 'D4', 57, 'other_income', 'Commision Income', array['4501'], 'movement', 'cr', true, 'ADMINISTRATIVE_EXPENSES!C70', null, null),
  ('OTHER_INCOME!D5', 'OTHER_INCOME', 'D5', 58, 'other_income', 'Interest Income', array['4502'], 'movement', 'cr', true, 'ADMINISTRATIVE_EXPENSES!C70', null, null),
  ('OTHER_INCOME!D6', 'OTHER_INCOME', 'D6', 59, 'other_income', 'Lease Income-Finance', array['4503'], 'movement', 'cr', true, 'ADMINISTRATIVE_EXPENSES!C70', null, null),
  ('OTHER_INCOME!D7', 'OTHER_INCOME', 'D7', 60, 'other_income', 'Rental Income', array['4504'], 'movement', 'cr', true, 'ADMINISTRATIVE_EXPENSES!C70', null, null),
  ('OTHER_INCOME!D8', 'OTHER_INCOME', 'D8', 61, 'other_income', 'Dividend Income', array['4505'], 'movement', 'cr', true, 'ADMINISTRATIVE_EXPENSES!C70', null, null),
  ('OTHER_INCOME!D9', 'OTHER_INCOME', 'D9', 62, 'other_income', 'Profit from disposal of investment in subsidiary income', array['4506'], 'movement', 'cr', true, 'ADMINISTRATIVE_EXPENSES!C70', null, null),
  ('OTHER_INCOME!D10', 'OTHER_INCOME', 'D10', 63, 'other_income', 'Decrease in provision', array['4507'], 'movement', 'cr', true, 'ADMINISTRATIVE_EXPENSES!C70', null, null),
  ('OTHER_INCOME!D11', 'OTHER_INCOME', 'D11', 64, 'other_income', 'Gain on sale of asset', array['4508'], 'movement', 'cr', true, 'ADMINISTRATIVE_EXPENSES!C29', null, null),
  ('OTHER_INCOME!D12', 'OTHER_INCOME', 'D12', 65, 'other_income', 'Non-taxable revenue', array['4509'], 'movement', 'cr', true, 'ADMINISTRATIVE_EXPENSES!C70', null, null),
  ('OTHER_INCOME!D13', 'OTHER_INCOME', 'D13', 66, 'other_income', 'Realized foreign exchange gain', array['4510'], 'movement', 'cr', true, 'ADMINISTRATIVE_EXPENSES!C60', null, null),
  ('OTHER_INCOME!D14', 'OTHER_INCOME', 'D14', 67, 'other_income', 'Unrealized foreign exchange gain', array['4511'], 'movement', 'cr', true, 'ADMINISTRATIVE_EXPENSES!C70', null, null),
  ('OTHER_INCOME!D15', 'OTHER_INCOME', 'D15', 68, 'other_income', 'Bad debt recovered', array['4512'], 'movement', 'cr', true, 'ADMINISTRATIVE_EXPENSES!C70', null, null),
  ('OTHER_INCOME!D16', 'OTHER_INCOME', 'D16', 69, 'other_income', 'Other investment income', array['4513','4515'], 'movement', 'cr', true, 'ADMINISTRATIVE_EXPENSES!C70', null, null),
  ('OTHER_INCOME!D17', 'OTHER_INCOME', 'D17', 70, 'other_income', 'Others', array['4514','4516'], 'movement', 'cr', true, 'ADMINISTRATIVE_EXPENSES!C70', null, null),
  ('ADMINISTRATIVE_EXPENSES!C4', 'ADMINISTRATIVE_EXPENSES', 'C4', 71, 'admin', 'Salary and Wages', array['6101'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C5', 'ADMINISTRATIVE_EXPENSES', 'C5', 72, 'admin', 'Employee Benefit Expenses', array['6103'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C6', 'ADMINISTRATIVE_EXPENSES', 'C6', 73, 'admin', 'Directors Emoluments', array['6109'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C7', 'ADMINISTRATIVE_EXPENSES', 'C7', 74, 'admin', 'Directors expenses', array['6110'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C8', 'ADMINISTRATIVE_EXPENSES', 'C8', 75, 'admin', 'Staff Allowances', array['6102'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C9', 'ADMINISTRATIVE_EXPENSES', 'C9', 76, 'admin', 'Staff Loan written off', array['6111'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C10', 'ADMINISTRATIVE_EXPENSES', 'C10', 77, 'admin', 'Staff Gratuity', array['6105'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C11', 'ADMINISTRATIVE_EXPENSES', 'C11', 78, 'admin', 'Pension and Gratuity', array['6104'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C12', 'ADMINISTRATIVE_EXPENSES', 'C12', 79, 'admin', 'Other staff & related Cost', array['6108','6113','6114'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C13', 'ADMINISTRATIVE_EXPENSES', 'C13', 80, 'admin', 'depreciation', array['6901','6902'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C14', 'ADMINISTRATIVE_EXPENSES', 'C14', 81, 'admin', 'Amortisation of intangible assetsX', array['6903'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C15', 'ADMINISTRATIVE_EXPENSES', 'C15', 82, 'admin', 'Government and regulatory costs', array['6508','6506'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C16', 'ADMINISTRATIVE_EXPENSES', 'C16', 83, 'admin', 'Advertisement & Promotion', array['6401'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C17', 'ADMINISTRATIVE_EXPENSES', 'C17', 84, 'admin', 'Bad Debt written off', array['6801','6802'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C18', 'ADMINISTRATIVE_EXPENSES', 'C18', 85, 'admin', 'Bank charges', array['6701'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C19', 'ADMINISTRATIVE_EXPENSES', 'C19', 86, 'admin', 'Interest Expense', array['6702','7103'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C20', 'ADMINISTRATIVE_EXPENSES', 'C20', 87, 'admin', 'Rooms/ Accomodation cost', array['6604'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C21', 'ADMINISTRATIVE_EXPENSES', 'C21', 88, 'admin', 'Audit fees', array['6501'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C22', 'ADMINISTRATIVE_EXPENSES', 'C22', 89, 'admin', 'Donations', array['6904'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C23', 'ADMINISTRATIVE_EXPENSES', 'C23', 90, 'admin', 'Entertainment expenses', array['6409','6410'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C24', 'ADMINISTRATIVE_EXPENSES', 'C24', 91, 'admin', 'Postages', array['6213'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C25', 'ADMINISTRATIVE_EXPENSES', 'C25', 92, 'admin', 'Fuel expenses', array['6605'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C26', 'ADMINISTRATIVE_EXPENSES', 'C26', 93, 'admin', 'Generator expenses', array['6208'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C27', 'ADMINISTRATIVE_EXPENSES', 'C27', 94, 'admin', 'Head office cost', array['6607'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C28', 'ADMINISTRATIVE_EXPENSES', 'C28', 95, 'admin', 'Internet Cost', array['6302'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C29', 'ADMINISTRATIVE_EXPENSES', 'C29', 96, 'admin', 'Loss on sale of property, plants and equipments', array['6804'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C30', 'ADMINISTRATIVE_EXPENSES', 'C30', 97, 'admin', 'Medical Expenses', array['6106'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C31', 'ADMINISTRATIVE_EXPENSES', 'C31', 98, 'admin', 'Newspaper & Periodicals', array['6214'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C32', 'ADMINISTRATIVE_EXPENSES', 'C32', 99, 'admin', 'Outsourcing Services expenses', array['6112'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C33', 'ADMINISTRATIVE_EXPENSES', 'C33', 100, 'admin', 'Rates', array['6202'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C34', 'ADMINISTRATIVE_EXPENSES', 'C34', 101, 'admin', 'Rent & Rates', array['6201'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C35', 'ADMINISTRATIVE_EXPENSES', 'C35', 102, 'admin', 'Repairs and Maintenance', array['6209','6305'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C36', 'ADMINISTRATIVE_EXPENSES', 'C36', 103, 'admin', 'Research cost', array['6905'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C37', 'ADMINISTRATIVE_EXPENSES', 'C37', 104, 'admin', 'Security expenses', array['6211'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C38', 'ADMINISTRATIVE_EXPENSES', 'C38', 105, 'admin', 'Selling & Distribution Expenses', array['6407'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C39', 'ADMINISTRATIVE_EXPENSES', 'C39', 106, 'admin', 'Service Charge', array['6203'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C40', 'ADMINISTRATIVE_EXPENSES', 'C40', 107, 'admin', 'Public Relation', array['6403'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C41', 'ADMINISTRATIVE_EXPENSES', 'C41', 108, 'admin', 'Publication Cost', array['6404'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C42', 'ADMINISTRATIVE_EXPENSES', 'C42', 109, 'admin', 'Permits', '{}', 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C43', 'ADMINISTRATIVE_EXPENSES', 'C43', 110, 'admin', 'Telephone', array['6301'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C44', 'ADMINISTRATIVE_EXPENSES', 'C44', 111, 'admin', 'Trade fairs & exhibitions', array['6405'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C45', 'ADMINISTRATIVE_EXPENSES', 'C45', 112, 'admin', 'Training and Development', array['6107'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C46', 'ADMINISTRATIVE_EXPENSES', 'C46', 113, 'admin', 'Transport of supplies', array['6601'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C47', 'ADMINISTRATIVE_EXPENSES', 'C47', 114, 'admin', 'Utilities', array['6204'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C48', 'ADMINISTRATIVE_EXPENSES', 'C48', 115, 'admin', 'Website Design & Maintenance', array['6304'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C49', 'ADMINISTRATIVE_EXPENSES', 'C49', 116, 'admin', 'Software maintenance', array['6303'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C50', 'ADMINISTRATIVE_EXPENSES', 'C50', 117, 'admin', 'Cleaning & Janitory Services', array['6210'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C51', 'ADMINISTRATIVE_EXPENSES', 'C51', 118, 'admin', 'Corporate promotion', array['6402'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C52', 'ADMINISTRATIVE_EXPENSES', 'C52', 119, 'admin', 'Freight & Transport Expenses', array['6606'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C53', 'ADMINISTRATIVE_EXPENSES', 'C53', 120, 'admin', 'Subscription & Dues', array['6510'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C54', 'ADMINISTRATIVE_EXPENSES', 'C54', 121, 'admin', 'Sponsorship', array['6406'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C55', 'ADMINISTRATIVE_EXPENSES', 'C55', 122, 'admin', 'Stationeries expenses', array['6212','6216'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C56', 'ADMINISTRATIVE_EXPENSES', 'C56', 123, 'admin', 'other professional fees', array['6502','6503','6504','6505','6507'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C57', 'ADMINISTRATIVE_EXPENSES', 'C57', 124, 'admin', 'Fines', array['6513'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C58', 'ADMINISTRATIVE_EXPENSES', 'C58', 125, 'admin', 'penalties', array['6514'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C59', 'ADMINISTRATIVE_EXPENSES', 'C59', 126, 'admin', 'AMCON charges', array['6511'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C60', 'ADMINISTRATIVE_EXPENSES', 'C60', 127, 'admin', 'Realized foreign exchange loss', array['6703'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C61', 'ADMINISTRATIVE_EXPENSES', 'C61', 128, 'admin', 'Corporate Social Responsibilities', array['6408'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C62', 'ADMINISTRATIVE_EXPENSES', 'C62', 129, 'admin', 'Royalties', array['6515'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C63', 'ADMINISTRATIVE_EXPENSES', 'C63', 130, 'admin', 'Electricity & Power', array['6205'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C64', 'ADMINISTRATIVE_EXPENSES', 'C64', 131, 'admin', 'PMS', array['6207'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C65', 'ADMINISTRATIVE_EXPENSES', 'C65', 132, 'admin', 'Health, safety and environmental expenses', array['6906'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C66', 'ADMINISTRATIVE_EXPENSES', 'C66', 133, 'admin', 'Licences & leases charges', array['6509'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C67', 'ADMINISTRATIVE_EXPENSES', 'C67', 134, 'admin', 'Other statutory charges & levies', array['6512'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C68', 'ADMINISTRATIVE_EXPENSES', 'C68', 135, 'admin', 'AGO-Diesel', array['6206'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C69', 'ADMINISTRATIVE_EXPENSES', 'C69', 136, 'admin', 'Travel Expenses', array['6602','6603'], 'movement', 'dr', false, null, null, null),
  ('ADMINISTRATIVE_EXPENSES!C70', 'ADMINISTRATIVE_EXPENSES', 'C70', 137, 'admin', 'Others', array['6215','6704','6803','6805','6907'], 'movement', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D8', 'STATEMENT_OF_FINANCIAL_POSITION', 'D8', 138, 'sofp_assets', 'Properties, Plants and Equipments', array['1501','1502','1503','1504','1505','1506','1507','1508','1509','1510','1511','1512','1513','1514','1515','1516','1517','1518','1519','1520','1521','1522','1523','1524','1525','1526','1527','1551','1552','1553','1554','1555','1556','1557','1558','1559','1560','1561','1562','1563','1564','1565','1566','1567','1568','1569','1570','1571','1572','1573','1574'], 'balance_end', 'dr', false, null, null, 'Cost less accumulated depreciation.'),
  ('STATEMENT_OF_FINANCIAL_POSITION!D10', 'STATEMENT_OF_FINANCIAL_POSITION', 'D10', 139, 'sofp_assets', 'Investment in securities', array['1703','1704','1705'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D11', 'STATEMENT_OF_FINANCIAL_POSITION', 'D11', 140, 'sofp_assets', 'Investment in stock and bonds', '{}', 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D12', 'STATEMENT_OF_FINANCIAL_POSITION', 'D12', 141, 'sofp_assets', 'Investment in Properties', array['1706'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D13', 'STATEMENT_OF_FINANCIAL_POSITION', 'D13', 142, 'sofp_assets', 'Investment in Associate & Joint Ventures', array['1702'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D14', 'STATEMENT_OF_FINANCIAL_POSITION', 'D14', 143, 'sofp_assets', 'Investment in Subsidiaries', array['1701'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D15', 'STATEMENT_OF_FINANCIAL_POSITION', 'D15', 144, 'sofp_assets', 'Investment in finance lease', array['1707'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D16', 'STATEMENT_OF_FINANCIAL_POSITION', 'D16', 145, 'sofp_assets', 'Investment in staff loan', array['1708'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D17', 'STATEMENT_OF_FINANCIAL_POSITION', 'D17', 146, 'sofp_assets', 'Investment in digital assets', array['1709'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D18', 'STATEMENT_OF_FINANCIAL_POSITION', 'D18', 147, 'sofp_assets', 'Investment in Commodities', array['1710'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D19', 'STATEMENT_OF_FINANCIAL_POSITION', 'D19', 148, 'sofp_assets', 'Others', array['1711'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D21', 'STATEMENT_OF_FINANCIAL_POSITION', 'D21', 149, 'sofp_assets', 'Goodwill', array['1601'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D22', 'STATEMENT_OF_FINANCIAL_POSITION', 'D22', 150, 'sofp_assets', 'Patent', array['1602'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D23', 'STATEMENT_OF_FINANCIAL_POSITION', 'D23', 151, 'sofp_assets', 'Trademarks', array['1603'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D24', 'STATEMENT_OF_FINANCIAL_POSITION', 'D24', 152, 'sofp_assets', 'Terminal and service concession rights', array['1608'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D25', 'STATEMENT_OF_FINANCIAL_POSITION', 'D25', 153, 'sofp_assets', 'Brands', array['1604'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D26', 'STATEMENT_OF_FINANCIAL_POSITION', 'D26', 154, 'sofp_assets', 'Customer relationships', array['1605'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D27', 'STATEMENT_OF_FINANCIAL_POSITION', 'D27', 155, 'sofp_assets', 'Right of use', array['1651','1652','1653','1654'], 'balance_end', 'dr', false, null, null, 'Right-of-use assets less their depreciation.'),
  ('STATEMENT_OF_FINANCIAL_POSITION!D28', 'STATEMENT_OF_FINANCIAL_POSITION', 'D28', 156, 'sofp_assets', 'Copyrights', array['1606'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D29', 'STATEMENT_OF_FINANCIAL_POSITION', 'D29', 157, 'sofp_assets', 'Others', array['1607','1610'], 'balance_end', 'dr', false, null, null, 'Accumulated amortisation (1609) is shared across the intangible lines in proportion to their cost.'),
  ('STATEMENT_OF_FINANCIAL_POSITION!D31', 'STATEMENT_OF_FINANCIAL_POSITION', 'D31', 158, 'sofp_assets', 'Lease-hold Land', array['1801'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D32', 'STATEMENT_OF_FINANCIAL_POSITION', 'D32', 159, 'sofp_assets', 'Lease-hold Building', array['1802'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D33', 'STATEMENT_OF_FINANCIAL_POSITION', 'D33', 160, 'sofp_assets', 'Building and Real estate lease', '{}', 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D34', 'STATEMENT_OF_FINANCIAL_POSITION', 'D34', 161, 'sofp_assets', 'Other leases', '{}', 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D35', 'STATEMENT_OF_FINANCIAL_POSITION', 'D35', 162, 'sofp_assets', 'Non-Current Assets Held for Sale', '{}', 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D36', 'STATEMENT_OF_FINANCIAL_POSITION', 'D36', 163, 'sofp_assets', 'Contract assets', array['1804'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D37', 'STATEMENT_OF_FINANCIAL_POSITION', 'D37', 164, 'sofp_assets', 'Deferred tax asset', array['1803'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D38', 'STATEMENT_OF_FINANCIAL_POSITION', 'D38', 165, 'sofp_assets', 'Other financial assets', array['1808'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D39', 'STATEMENT_OF_FINANCIAL_POSITION', 'D39', 166, 'sofp_assets', 'Derivative financial instrument', array['1805'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D40', 'STATEMENT_OF_FINANCIAL_POSITION', 'D40', 167, 'sofp_assets', 'Long-term borrowings and debts', array['1806'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D41', 'STATEMENT_OF_FINANCIAL_POSITION', 'D41', 168, 'sofp_assets', 'Defined Benefits Assets', array['1807'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D42', 'STATEMENT_OF_FINANCIAL_POSITION', 'D42', 169, 'sofp_assets', 'Others', array['1809'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D46', 'STATEMENT_OF_FINANCIAL_POSITION', 'D46', 170, 'sofp_assets', 'Inventories', array['1201','1202','1203','1207'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D47', 'STATEMENT_OF_FINANCIAL_POSITION', 'D47', 171, 'sofp_assets', 'Other Receivables', array['1104','1105','1108','1110'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D48', 'STATEMENT_OF_FINANCIAL_POSITION', 'D48', 172, 'sofp_assets', 'Trade recievables', array['1101','1102','1103'], 'balance_end', 'dr', false, null, null, 'Includes customers in credit, which also show as unearned income, as in the financial statements.'),
  ('STATEMENT_OF_FINANCIAL_POSITION!D50', 'STATEMENT_OF_FINANCIAL_POSITION', 'D50', 173, 'sofp_assets', 'Other Interbank Advances', array['1109'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D51', 'STATEMENT_OF_FINANCIAL_POSITION', 'D51', 174, 'sofp_assets', 'Withholding tax recievables', array['1401'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D52', 'STATEMENT_OF_FINANCIAL_POSITION', 'D52', 175, 'sofp_assets', 'Other  receivables', array['1402','1403','1404','1405'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D53', 'STATEMENT_OF_FINANCIAL_POSITION', 'D53', 176, 'sofp_assets', 'Current portion of Long Term Loan', array['1305'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D54', 'STATEMENT_OF_FINANCIAL_POSITION', 'D54', 177, 'sofp_assets', 'Short Term Investments', array['1304'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D55', 'STATEMENT_OF_FINANCIAL_POSITION', 'D55', 178, 'sofp_assets', 'Accrued Income', array['1107'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D56', 'STATEMENT_OF_FINANCIAL_POSITION', 'D56', 179, 'sofp_assets', 'Asset classified as held for sale', array['1306'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D57', 'STATEMENT_OF_FINANCIAL_POSITION', 'D57', 180, 'sofp_assets', 'Advance payment to vendor', array['1106'], 'balance_end', 'dr', false, null, null, 'Includes suppliers in debit, as in the financial statements.'),
  ('STATEMENT_OF_FINANCIAL_POSITION!D58', 'STATEMENT_OF_FINANCIAL_POSITION', 'D58', 181, 'sofp_assets', 'Prepaid Expenses', array['1301','1302','1303'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D59', 'STATEMENT_OF_FINANCIAL_POSITION', 'D59', 182, 'sofp_assets', 'Small Tools', array['1205'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D60', 'STATEMENT_OF_FINANCIAL_POSITION', 'D60', 183, 'sofp_assets', 'Goods in transit', array['1204'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D61', 'STATEMENT_OF_FINANCIAL_POSITION', 'D61', 184, 'sofp_assets', 'chemicals, materials supplies and others', array['1206'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D62', 'STATEMENT_OF_FINANCIAL_POSITION', 'D62', 185, 'sofp_assets', 'Others', array['1307','1308'], 'balance_end', 'dr', false, null, null, 'Includes uncleared suspense and clearing balances in debit.'),
  ('STATEMENT_OF_FINANCIAL_POSITION!D64', 'STATEMENT_OF_FINANCIAL_POSITION', 'D64', 186, 'sofp_assets', 'Cash in hand', array['1011'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D65', 'STATEMENT_OF_FINANCIAL_POSITION', 'D65', 187, 'sofp_assets', 'Cash at Bank', array['1012','1013'], 'balance_end', 'dr', false, null, null, 'Overdrawn bank accounts are shown as short-term debt.'),
  ('STATEMENT_OF_FINANCIAL_POSITION!D66', 'STATEMENT_OF_FINANCIAL_POSITION', 'D66', 188, 'sofp_assets', 'marketable securities', array['1016'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D67', 'STATEMENT_OF_FINANCIAL_POSITION', 'D67', 189, 'sofp_assets', 'Others', array['1014','1015','1019'], 'balance_end', 'dr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D73', 'STATEMENT_OF_FINANCIAL_POSITION', 'D73', 190, 'sofp_liabilities', 'Trade Payables', array['2101','2102'], 'balance_end', 'cr', false, null, null, 'Includes suppliers in debit, as in the financial statements.'),
  ('STATEMENT_OF_FINANCIAL_POSITION!D74', 'STATEMENT_OF_FINANCIAL_POSITION', 'D74', 191, 'sofp_liabilities', 'Current tax liabilities', array['2208','2209'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D76', 'STATEMENT_OF_FINANCIAL_POSITION', 'D76', 192, 'sofp_liabilities', 'Other payables', array['2104','2105','2106'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D77', 'STATEMENT_OF_FINANCIAL_POSITION', 'D77', 193, 'sofp_liabilities', 'Financial liabilities', '{}', 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D78', 'STATEMENT_OF_FINANCIAL_POSITION', 'D78', 194, 'sofp_liabilities', 'Accruals', array['2103'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D79', 'STATEMENT_OF_FINANCIAL_POSITION', 'D79', 195, 'sofp_liabilities', 'Unearned income (advance from customers)', array['2107','2110'], 'balance_end', 'cr', false, null, null, 'Includes customers in credit.'),
  ('STATEMENT_OF_FINANCIAL_POSITION!D80', 'STATEMENT_OF_FINANCIAL_POSITION', 'D80', 196, 'sofp_liabilities', 'Interest payable', array['2305'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D81', 'STATEMENT_OF_FINANCIAL_POSITION', 'D81', 197, 'sofp_liabilities', 'Short-term debt', array['2301','2302','2306'], 'balance_end', 'cr', false, null, null, 'Includes overdrawn bank accounts.'),
  ('STATEMENT_OF_FINANCIAL_POSITION!D82', 'STATEMENT_OF_FINANCIAL_POSITION', 'D82', 198, 'sofp_liabilities', 'Provision for warranty expenses', array['2401'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D83', 'STATEMENT_OF_FINANCIAL_POSITION', 'D83', 199, 'sofp_liabilities', 'Provision for bonuses and employee benefit', array['2402'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D84', 'STATEMENT_OF_FINANCIAL_POSITION', 'D84', 200, 'sofp_liabilities', 'Current portion of lease liability', array['2304'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D85', 'STATEMENT_OF_FINANCIAL_POSITION', 'D85', 201, 'sofp_liabilities', 'Current portion of long-term debt', array['2303'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D86', 'STATEMENT_OF_FINANCIAL_POSITION', 'D86', 202, 'sofp_liabilities', 'Dividend payable', array['2108'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D87', 'STATEMENT_OF_FINANCIAL_POSITION', 'D87', 203, 'sofp_liabilities', 'Provisions', array['2403'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D88', 'STATEMENT_OF_FINANCIAL_POSITION', 'D88', 204, 'sofp_liabilities', 'Short-term debt', '{}', 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D89', 'STATEMENT_OF_FINANCIAL_POSITION', 'D89', 205, 'sofp_liabilities', 'Income taxes payable', '{}', 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D90', 'STATEMENT_OF_FINANCIAL_POSITION', 'D90', 206, 'sofp_liabilities', 'Decommissioning and other provisions', '{}', 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D91', 'STATEMENT_OF_FINANCIAL_POSITION', 'D91', 207, 'sofp_liabilities', 'Other payables', array['2109','2201','2202','2203','2204','2205','2206','2207','2210','2211'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D92', 'STATEMENT_OF_FINANCIAL_POSITION', 'D92', 208, 'sofp_liabilities', 'Others', '{}', 'balance_end', 'cr', false, null, null, 'Uncleared suspense and clearing balances in credit.'),
  ('STATEMENT_OF_FINANCIAL_POSITION!D95', 'STATEMENT_OF_FINANCIAL_POSITION', 'D95', 209, 'sofp_noncurrent', 'Long Term Debt', array['2501'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D96', 'STATEMENT_OF_FINANCIAL_POSITION', 'D96', 210, 'sofp_noncurrent', 'Long term Borrowings', array['2502'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D97', 'STATEMENT_OF_FINANCIAL_POSITION', 'D97', 211, 'sofp_noncurrent', 'Pension and Employee Benefit obligation', array['2603'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D98', 'STATEMENT_OF_FINANCIAL_POSITION', 'D98', 212, 'sofp_noncurrent', 'Deferred Revenue (Long Term Portion)', array['2602'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D99', 'STATEMENT_OF_FINANCIAL_POSITION', 'D99', 213, 'sofp_noncurrent', 'Contigent Liability (Long Term Provision)', array['2605'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D100', 'STATEMENT_OF_FINANCIAL_POSITION', 'D100', 214, 'sofp_noncurrent', 'Employees Benefits obligations', '{}', 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D101', 'STATEMENT_OF_FINANCIAL_POSITION', 'D101', 215, 'sofp_noncurrent', 'Non-current Portion of Lease Obligation', array['2504'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D102', 'STATEMENT_OF_FINANCIAL_POSITION', 'D102', 216, 'sofp_noncurrent', 'Deferred Tax Liabilities', array['2601'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D103', 'STATEMENT_OF_FINANCIAL_POSITION', 'D103', 217, 'sofp_noncurrent', 'Stock warrant obligations', array['2607'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D104', 'STATEMENT_OF_FINANCIAL_POSITION', 'D104', 218, 'sofp_noncurrent', 'Debt Securities', array['2503'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D105', 'STATEMENT_OF_FINANCIAL_POSITION', 'D105', 219, 'sofp_noncurrent', 'Lease liabilities', '{}', 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D106', 'STATEMENT_OF_FINANCIAL_POSITION', 'D106', 220, 'sofp_noncurrent', 'Derivaties liabilities held for risk Management', array['2606'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D107', 'STATEMENT_OF_FINANCIAL_POSITION', 'D107', 221, 'sofp_noncurrent', 'Deposit from Customers', array['2505'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D108', 'STATEMENT_OF_FINANCIAL_POSITION', 'D108', 222, 'sofp_noncurrent', 'Retirement benefits', '{}', 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D109', 'STATEMENT_OF_FINANCIAL_POSITION', 'D109', 223, 'sofp_noncurrent', 'Derivative financial instruments liabilities', '{}', 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D110', 'STATEMENT_OF_FINANCIAL_POSITION', 'D110', 224, 'sofp_noncurrent', 'Others', array['2604','2608'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D112', 'STATEMENT_OF_FINANCIAL_POSITION', 'D112', 225, 'sofp_equity', 'Issued Share Capital', array['3001','3002'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D113', 'STATEMENT_OF_FINANCIAL_POSITION', 'D113', 226, 'sofp_equity', 'Share premium', array['3003'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D114', 'STATEMENT_OF_FINANCIAL_POSITION', 'D114', 227, 'sofp_equity', 'Retained earnings', array['3005'], 'balance_end', 'cr', false, null, null, 'Retained earnings include profit for the year not yet closed.'),
  ('STATEMENT_OF_FINANCIAL_POSITION!D115', 'STATEMENT_OF_FINANCIAL_POSITION', 'D115', 228, 'sofp_equity', 'Revaluation reserve', array['3006'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D116', 'STATEMENT_OF_FINANCIAL_POSITION', 'D116', 229, 'sofp_equity', 'Statutory reserve', array['3007'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D117', 'STATEMENT_OF_FINANCIAL_POSITION', 'D117', 230, 'sofp_equity', 'Non-controlling interest', array['3016'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D119', 'STATEMENT_OF_FINANCIAL_POSITION', 'D119', 231, 'sofp_equity', 'Contigency reserve', array['3013'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D120', 'STATEMENT_OF_FINANCIAL_POSITION', 'D120', 232, 'sofp_equity', 'Cumulative Translation Adjustment', array['3008'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D121', 'STATEMENT_OF_FINANCIAL_POSITION', 'D121', 233, 'sofp_equity', 'Share based payment reserve', array['3011'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D122', 'STATEMENT_OF_FINANCIAL_POSITION', 'D122', 234, 'sofp_equity', 'Reserve for bonus issue', array['3014'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D123', 'STATEMENT_OF_FINANCIAL_POSITION', 'D123', 235, 'sofp_equity', 'Capital reserve', array['3012'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D124', 'STATEMENT_OF_FINANCIAL_POSITION', 'D124', 236, 'sofp_equity', 'Other reserves', array['3009','3010','3015','3017'], 'balance_end', 'cr', false, null, null, null),
  ('STATEMENT_OF_FINANCIAL_POSITION!D125', 'STATEMENT_OF_FINANCIAL_POSITION', 'D125', 237, 'sofp_equity', 'Equity contribution to shareholders/ Equity holders', array['3004','3999'], 'balance_end', 'cr', false, null, null, null),
  ('PROFIT_ADJUSTMENT!D14', 'PROFIT_ADJUSTMENT', 'D14', 238, 'add_back', 'Expenses Related To Exempt Income', '{}', 'adjustment', 'dr', false, null, 'expenses_exempt_income', null),
  ('PROFIT_ADJUSTMENT!D15', 'PROFIT_ADJUSTMENT', 'D15', 239, 'add_back', 'Donations (To The Extent Not Allowed)', '{}', 'adjustment', 'dr', false, null, 'donations_disallowed', null),
  ('PROFIT_ADJUSTMENT!D16', 'PROFIT_ADJUSTMENT', 'D16', 240, 'add_back', 'Unrealised Foreign Exchange Loss', '{}', 'adjustment', 'dr', false, null, 'unrealised_fx_loss', null),
  ('PROFIT_ADJUSTMENT!D17', 'PROFIT_ADJUSTMENT', 'D17', 241, 'add_back', 'Loss On Disposal Of Fixed Assets', '{}', 'adjustment', 'dr', false, null, 'loss_on_disposal_fixed_assets', null),
  ('PROFIT_ADJUSTMENT!D18', 'PROFIT_ADJUSTMENT', 'D18', 242, 'add_back', 'Entertainment Expenses (To The Extent Not Allowed)', '{}', 'adjustment', 'dr', false, null, 'entertainment_disallowed', null),
  ('PROFIT_ADJUSTMENT!D19', 'PROFIT_ADJUSTMENT', 'D19', 243, 'add_back', 'Capital Repaid/Withdrawn', '{}', 'adjustment', 'dr', false, null, 'capital_repaid_withdrawn', null),
  ('PROFIT_ADJUSTMENT!D20', 'PROFIT_ADJUSTMENT', 'D20', 244, 'add_back', 'Expenses of Capital Nature', '{}', 'adjustment', 'dr', false, null, 'capital_nature_expenses', null),
  ('PROFIT_ADJUSTMENT!D21', 'PROFIT_ADJUSTMENT', 'D21', 245, 'add_back', 'Expenditure on assets not used for the purpose of trade', '{}', 'adjustment', 'dr', false, null, 'assets_not_for_trade', null),
  ('PROFIT_ADJUSTMENT!D22', 'PROFIT_ADJUSTMENT', 'D22', 246, 'add_back', 'Sum recoverable under an insurance or contract of indemnity', '{}', 'adjustment', 'dr', false, null, 'sum_recoverable_insurance', null),
  ('PROFIT_ADJUSTMENT!D23', 'PROFIT_ADJUSTMENT', 'D23', 247, 'add_back', 'Taxes on Profit or Incomes', '{}', 'adjustment', 'dr', false, null, 'taxes_on_profit_income', null),
  ('PROFIT_ADJUSTMENT!D24', 'PROFIT_ADJUSTMENT', 'D24', 248, 'add_back', 'Payment to any unapproved retirement fund or scheme under the Pension Reform Act.', '{}', 'adjustment', 'dr', false, null, 'unapproved_pension', null),
  ('PROFIT_ADJUSTMENT!D25', 'PROFIT_ADJUSTMENT', 'D25', 249, 'add_back', 'Any sum reserved out of profits subject to the provisions of section 20(1)(h) of this Act', '{}', 'adjustment', 'dr', false, null, 'reserved_out_of_profits', null),
  ('PROFIT_ADJUSTMENT!D26', 'PROFIT_ADJUSTMENT', 'D26', 250, 'add_back', 'Any payment to a related party that contravenes the Transfer Pricing Regulations.', '{}', 'adjustment', 'dr', false, null, 'tp_contravention', null),
  ('PROFIT_ADJUSTMENT!D27', 'PROFIT_ADJUSTMENT', 'D27', 251, 'add_back', 'Any expense incurred in deriving an income that is exempt from income tax', '{}', 'adjustment', 'dr', false, null, 'expense_deriving_exempt_income', null),
  ('PROFIT_ADJUSTMENT!D28', 'PROFIT_ADJUSTMENT', 'D28', 252, 'add_back', 'Any expense allowable as a deduction in determining chargeable gains', '{}', 'adjustment', 'dr', false, null, 'deductible_for_chargeable_gains', null),
  ('PROFIT_ADJUSTMENT!D29', 'PROFIT_ADJUSTMENT', 'D29', 253, 'add_back', 'Penalty or fine imposed under any law', '{}', 'adjustment', 'dr', false, null, 'penalty_fine', null),
  ('PROFIT_ADJUSTMENT!D30', 'PROFIT_ADJUSTMENT', 'D30', 254, 'add_back', 'Expenses liable to VAT or import duties but not charged or paid', '{}', 'adjustment', 'dr', false, null, 'vat_duty_uncharged_expense', null),
  ('PROFIT_ADJUSTMENT!D31', 'PROFIT_ADJUSTMENT', 'D31', 255, 'add_back', 'Compensating payments in regulated securities lending that qualify as dividends or interest under this Act', '{}', 'adjustment', 'dr', false, null, 'securities_lending_compensating', null),
  ('PROFIT_ADJUSTMENT!D32', 'PROFIT_ADJUSTMENT', 'D32', 256, 'add_back', 'Others', '{}', 'adjustment', 'dr', false, null, 'other_disallowable', null),
  ('PROFIT_ADJUSTMENT!D36', 'PROFIT_ADJUSTMENT', 'D36', 257, 'deduction', 'Deduct Non Taxable Items', '{}', 'adjustment', 'cr', false, null, 'other_non_taxable_income_items', null),
  ('PROFIT_ADJUSTMENT!D37', 'PROFIT_ADJUSTMENT', 'D37', 258, 'deduction', 'Profit From Sales Of Fixed Assets', '{}', 'adjustment', 'cr', false, null, 'profit_on_disposal_fixed_assets', null),
  ('PROFIT_ADJUSTMENT!D38', 'PROFIT_ADJUSTMENT', 'D38', 259, 'deduction', 'Frank Investment Income', '{}', 'adjustment', 'cr', false, null, 'franked_investment_income', null),
  ('PROFIT_ADJUSTMENT!D39', 'PROFIT_ADJUSTMENT', 'D39', 260, 'deduction', 'Unrealised Gains', '{}', 'adjustment', 'cr', false, null, 'unrealised_gains', null),
  ('PROFIT_ADJUSTMENT!D40', 'PROFIT_ADJUSTMENT', 'D40', 261, 'deduction', 'Others', '{}', 'adjustment', 'cr', false, null, 'other_non_taxable_income', null)
on conflict (cell) do update set sheet = excluded.sheet, addr = excluded.addr, sort = excluded.sort, section = excluded.section, label = excluded.label, codes = excluded.codes,
  basis = excluded.basis, sign = excluded.sign, positive_only = excluded.positive_only, negative_to = excluded.negative_to, config_id = excluded.config_id, note = excluded.note;

-- ---------------------------------------------------------------------------
-- 3. Accounts and fields the engines need
-- ---------------------------------------------------------------------------
-- VAT withheld from us by customers who are withholding VAT agents (credited in the VAT return), and withholding VAT we owe as
-- an agent or self-charge on services bought from abroad.
insert into public.accounts (code, name, kind, category, normal_balance, parent_code, is_group, is_system, active, sort, ifrs_line, cash_flow_class, statement)
values ('1405', 'VAT Withheld by Customers (Credit)', 'asset', 'Assets', 'debit', '1400', false, false, true, 1405, 'Current tax assets', 'working_capital', 'sofp'),
       ('2211', 'Withholding VAT Payable (Agent / Self-Charged)', 'liability', 'Liabilities', 'credit', '2200', false, false, true, 2211, 'Other statutory liabilities', 'working_capital', 'sofp')
on conflict (code) do nothing;
insert into public.posting_roles (role, label, description, default_code, allowed, sort) values
  ('vat_withheld_by_customers', 'VAT withheld by customers', 'VAT on your invoices that a customer who is a withholding VAT agent kept and pays to the NRS for you; credited in your VAT return.', '1405', '^(1405)$', 5),
  ('wvat_payable', 'Withholding VAT to remit', 'VAT you withheld from suppliers as an agent, or self-charged on services bought from abroad, owed to the NRS by the 14th.', '2211', '^(2211)$', 32)
on conflict (role) do nothing;

-- The business. professional_services: provides professional services (never a small company, NTA 2025 s.202).
-- wvat_agent: the kind of withholding VAT agent the business is, when it is one. vat_opt_in: a small company that has told
-- the NRS in writing it will keep filing VAT returns (to recover input VAT). commenced_on: first day of business, for the
-- minimum tax exemption of the first four years.
alter table public.orgs add column if not exists professional_services boolean not null default false;
alter table public.orgs add column if not exists wvat_agent text check (wvat_agent in ('bank', 'telecom', 'oil_gas', 'government', 'digital_platform', 'other'));
alter table public.orgs add column if not exists vat_opt_in boolean not null default false;
alter table public.orgs add column if not exists commenced_on date;
alter table public.orgs add column if not exists cit_profile jsonb not null default '{}'::jsonb;
-- cit_profile: {non_resident, mne_constituent, group_turnover_eur, eur_ngn_rate, bank_or_insurer_subsidiary, imported_equity_25,
--               agricultural_trade, free_zone, sector_regime}

-- Suppliers. entity_type decides corporate or not: company, plc, llp and ltd_gte are corporate (WHT to the NRS); business_name,
-- sole_proprietor, partnership, lp and individual are not (WHT to the state service of the state on their invoice address).
alter table public.vendors add column if not exists entity_type text check (entity_type in ('company', 'plc', 'llp', 'ltd_gte', 'business_name', 'sole_proprietor',
  'partnership', 'lp', 'individual', 'government', 'ngo'));
alter table public.vendors add column if not exists resident boolean not null default true;
alter table public.vendors add column if not exists state text;
alter table public.vendors add column if not exists country text not null default 'NG';
alter table public.vendors add column if not exists nin text;
alter table public.vendors add column if not exists is_manufacturer boolean not null default false;
alter table public.vendors add column if not exists wht_exempt boolean not null default false;
alter table public.vendors add column if not exists digital_supplier boolean not null default false;
alter table public.vendors add column if not exists connected_person boolean not null default false;
update public.vendors set entity_type = case when is_individual then 'individual' else 'company' end where entity_type is null;

-- Customers that withhold VAT (and usually WHT) from what they pay us.
alter table public.customers add column if not exists wvat_agent boolean not null default false;

-- Tax view of an asset in the register: the Rev360 category it is declared under (it decides the allowance), the share used for
-- the taxable trade, costs that add to the base for chargeable gains, and the declaration description code.
alter table public.fixed_assets add column if not exists tax_category text;
alter table public.fixed_assets add column if not exists tax_use_pct numeric(5,2) not null default 100 check (tax_use_pct between 0 and 100);
alter table public.fixed_assets add column if not exists tax_enhancement numeric(16,2) not null default 0;
alter table public.fixed_assets add column if not exists tax_disposal_costs numeric(16,2) not null default 0;
alter table public.fixed_assets add column if not exists tax_qualifies boolean not null default true;
alter table public.fixed_assets add column if not exists tax_note text;

-- Assets that are in the tax computations but not in Counta's register: owned before the books started, or listed only in an
-- earlier capital allowance schedule. They post nothing to the books.
create table if not exists public.tax_assets (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  name text not null,
  class_account text references public.asset_classes(cost_account),
  tax_category text not null,
  in_use_from date not null,
  cost numeric(16,2) not null check (cost >= 0),
  accumulated_depreciation numeric(16,2) not null default 0,
  depreciation_as_at date,
  disposed_at date,
  proceeds numeric(16,2),
  tax_enhancement numeric(16,2) not null default 0,
  tax_disposal_costs numeric(16,2) not null default 0,
  tax_use_pct numeric(5,2) not null default 100 check (tax_use_pct between 0 and 100),
  tax_qualifies boolean not null default true,
  source text not null default 'manual' check (source in ('manual', 'import', 'ai')),
  note text,
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists tax_assets_org on public.tax_assets(org_id);
create index if not exists tax_assets_class_fk on public.tax_assets(class_account);
create index if not exists tax_assets_created_by_fk on public.tax_assets(created_by);
alter table public.tax_assets enable row level security;
drop policy if exists tax_assets_read on public.tax_assets;
create policy tax_assets_read on public.tax_assets for select to authenticated using ((select private.can_handle_money(org_id)));

-- Tax authorities: the NRS and the 36 state services and the FCT's (compiled from their own sites, October 2026).
create table if not exists public.tax_authorities (
  code text primary key,
  kind text not null check (kind in ('federal', 'state')),
  state text,
  name text not null,
  short_name text,
  website text,
  sort int not null default 100
);
alter table public.tax_authorities enable row level security;
drop policy if exists tax_authorities_read on public.tax_authorities;
create policy tax_authorities_read on public.tax_authorities for select to authenticated using (true);
insert into public.tax_authorities (code, kind, state, name, short_name, website, sort) values
  ('NRS', 'federal', null, 'Nigeria Revenue Service', 'NRS', 'nrs.gov.ng', 0),
  ('SIRS:AB', 'state', 'Abia', 'Abia State Internal Revenue Service', 'ABIRS', 'abiairs.gov.ng', 101),
  ('SIRS:AD', 'state', 'Adamawa', 'Adamawa State Internal Revenue Service', 'ADIRS', 'ad-irs.adamawastate.gov.ng', 102),
  ('SIRS:AK', 'state', 'Akwa Ibom', 'Akwa Ibom State Internal Revenue Service', 'AKIRS', 'akirs.ak.gov.ng', 103),
  ('SIRS:AN', 'state', 'Anambra', 'Anambra State Internal Revenue Service', 'AIRS', 'tax.services.an.gov.ng', 104),
  ('SIRS:BA', 'state', 'Bauchi', 'Bauchi State Internal Revenue Service', 'BIRS', 'birs.bu.gov.ng', 105),
  ('SIRS:BY', 'state', 'Bayelsa', 'Bayelsa State Board of Internal Revenue', 'BIR', 'bir.by.gov.ng', 106),
  ('SIRS:BE', 'state', 'Benue', 'Benue State Internal Revenue Service', 'BIRS', 'birs.be.gov.ng', 107),
  ('SIRS:BO', 'state', 'Borno', 'Borno State Internal Revenue Service', 'BIRS', 'birs.bo.gov.ng', 108),
  ('SIRS:CR', 'state', 'Cross River', 'Cross River State Internal Revenue Service', 'CRIRS', 'crirs.crossriverstate.gov.ng', 109),
  ('SIRS:DE', 'state', 'Delta', 'Delta State Internal Revenue Service', 'DSIRS', 'deltairs.com', 110),
  ('SIRS:EB', 'state', 'Ebonyi', 'Ebonyi State Internal Revenue Service', 'EBSIRS', 'tax.ebsirb.eb.gov.ng', 111),
  ('SIRS:ED', 'state', 'Edo', 'Edo State Internal Revenue Service', 'EIRS', 'eirs.gov.ng', 112),
  ('SIRS:EK', 'state', 'Ekiti', 'Ekiti State Internal Revenue Service', 'EKIRS', 'ekitistaterevenue.com', 113),
  ('SIRS:EN', 'state', 'Enugu', 'Enugu State Internal Revenue Service', 'ESIRS', 'irs.en.gov.ng', 114),
  ('SIRS:FC', 'state', 'FCT', 'Federal Capital Territory Internal Revenue Service', 'FCT-IRS', 'fctirs.gov.ng', 115),
  ('SIRS:GO', 'state', 'Gombe', 'Gombe State Internal Revenue Service', 'GIRS', 'irs.gm.gov.ng', 116),
  ('SIRS:IM', 'state', 'Imo', 'Imo State Internal Revenue Service', 'IIRS', 'iirs.im.gov.ng', 117),
  ('SIRS:JI', 'state', 'Jigawa', 'Jigawa State Internal Revenue Service', 'JSIRS', 'jsirs.org.ng', 118),
  ('SIRS:KD', 'state', 'Kaduna', 'Kaduna State Internal Revenue Service', 'KADIRS', 'kadirs.kdsg.gov.ng', 119),
  ('SIRS:KN', 'state', 'Kano', 'Kano State Internal Revenue Service', 'KIRS', 'kirs.gov.ng', 120),
  ('SIRS:KT', 'state', 'Katsina', 'Katsina State Internal Revenue Service', 'KTIRS', 'irs.kt.gov.ng', 121),
  ('SIRS:KE', 'state', 'Kebbi', 'Kebbi State Internal Revenue Service', 'KBIRS', 'irs.kb.gov.ng', 122),
  ('SIRS:KO', 'state', 'Kogi', 'Kogi State Internal Revenue Service', 'KGIRS', 'irs.kg.gov.ng', 123),
  ('SIRS:KW', 'state', 'Kwara', 'Kwara State Internal Revenue Service', 'KW-IRS', 'irs.kw.gov.ng', 124),
  ('SIRS:LA', 'state', 'Lagos', 'Lagos State Internal Revenue Service', 'LIRS', 'lirs.gov.ng', 125),
  ('SIRS:NA', 'state', 'Nasarawa', 'Nasarawa State Internal Revenue Service', 'NIRS', 'irs.na.gov.ng', 126),
  ('SIRS:NI', 'state', 'Niger', 'Niger State Internal Revenue Service', 'NG-IRS', 'ngsirs.gov.ng', 127),
  ('SIRS:OG', 'state', 'Ogun', 'Ogun State Internal Revenue Service', 'OGIRS', 'portal.ogetax.ogunstate.gov.ng', 128),
  ('SIRS:ON', 'state', 'Ondo', 'Ondo State Internal Revenue Service', 'ODIRS', 'odirs.ng', 129),
  ('SIRS:OS', 'state', 'Osun', 'Osun State Internal Revenue Service', 'OSIRS', 'irs.os.gov.ng', 130),
  ('SIRS:OY', 'state', 'Oyo', 'Oyo State Internal Revenue Service', 'OYSIRS', 'bir.oyostate.gov.ng', 131),
  ('SIRS:PL', 'state', 'Plateau', 'Plateau State Internal Revenue Service', 'PSIRS', 'psirs.gov.ng', 132),
  ('SIRS:RI', 'state', 'Rivers', 'Rivers State Internal Revenue Service', 'RIRS', 'riversbirs.gov.ng', 133),
  ('SIRS:SO', 'state', 'Sokoto', 'Sokoto State Internal Revenue Service', 'SIRS', 'irs.sk.gov.ng', 134),
  ('SIRS:TA', 'state', 'Taraba', 'Taraba State Internal Revenue Service', 'TIRS', 'tarababir.gov.ng', 135),
  ('SIRS:YO', 'state', 'Yobe', 'Yobe State Internal Revenue Service', 'YIRS', 'irs.yb.gov.ng', 136),
  ('SIRS:ZA', 'state', 'Zamfara', 'Zamfara State Internal Revenue Service', 'ZIRS', 'irs.zm.gov.ng', 137)
on conflict (code) do update set name = excluded.name, short_name = excluded.short_name, website = excluded.website, state = excluded.state;

-- The state a free-text state or address names (for routing WHT to a state service).
create or replace function private.state_code(p text) returns text
language sql immutable set search_path = public, private as $$
  select a.code from public.tax_authorities a
  where a.kind = 'state' and p is not null and (
    lower(trim(p)) = lower(a.state) or lower(trim(p)) = lower(a.state) || ' state'
    or (a.state = 'FCT' and lower(p) ~ '(^|[^a-z])(fct|abuja|federal capital territory)([^a-z]|$)')
    or (a.state = 'Lagos' and lower(p) ~ '(^|[^a-z])(lagos|ikeja|lekki|victoria island|ikoyi|yaba|surulere|apapa|ajah|ikorodu|festac)([^a-z]|$)')
    or (a.state = 'Rivers' and lower(p) ~ '(^|[^a-z])(port harcourt|rivers)([^a-z]|$)')
    or (a.state = 'Oyo' and lower(p) ~ '(^|[^a-z])(ibadan|oyo)([^a-z]|$)')
    or (a.state = 'Kano' and lower(p) ~ '(^|[^a-z])kano([^a-z]|$)')
    or (a.state = 'Kaduna' and lower(p) ~ '(^|[^a-z])(kaduna|zaria)([^a-z]|$)')
    or (a.state = 'Ogun' and lower(p) ~ '(^|[^a-z])(ogun|abeokuta|ota|sango|ijebu)([^a-z]|$)')
    or (a.state = 'Enugu' and lower(p) ~ '(^|[^a-z])(enugu|nsukka)([^a-z]|$)')
    or (a.state = 'Edo' and lower(p) ~ '(^|[^a-z])(edo|benin city)([^a-z]|$)')
    or (a.state = 'Delta' and lower(p) ~ '(^|[^a-z])(delta|warri|asaba)([^a-z]|$)')
    or (a.state = 'Anambra' and lower(p) ~ '(^|[^a-z])(anambra|onitsha|awka|nnewi)([^a-z]|$)')
    or (a.state = 'Akwa Ibom' and lower(p) ~ '(^|[^a-z])(akwa ibom|uyo|eket)([^a-z]|$)')
    or (a.state = 'Cross River' and lower(p) ~ '(^|[^a-z])(cross river|calabar)([^a-z]|$)')
    or (a.state not in ('FCT', 'Lagos', 'Rivers', 'Oyo', 'Kano', 'Kaduna', 'Ogun', 'Enugu', 'Edo', 'Delta', 'Anambra', 'Akwa Ibom', 'Cross River')
        and lower(p) ~ ('(^|[^a-z])' || lower(a.state) || '([^a-z]|$)'))
  ) order by length(a.state) desc limit 1
$$;

-- ---------------------------------------------------------------------------
-- 4. CIT years
-- ---------------------------------------------------------------------------
-- One row per business per accounting year (the year in which the accounting period ends). A row exists once someone has
-- looked at or prepared the year. imported: template figures for a year the books do not cover in full
-- ({cell: {amount, source, confidence, note}}); overrides: changes to figures taken from the books ({cell: {amount, reason}});
-- adjustments: profit adjustment rows ({cell: {items: [{label, amount, reason}], override: {amount, reason}}});
-- settings: {losses_bf, ca_bf, interest_cf_bf, connected_interest, donations_unlisted, chargeable_gains_other, opening_twdv, notes};
-- snapshot: the figures, computation, cell map and declaration frozen when the year is approved.
create table if not exists public.cit_years (
  org_id uuid not null references public.orgs(id) on delete cascade,
  accounting_year int not null check (accounting_year between 2000 and 2100),
  period_from date not null,
  period_to date not null,
  source text not null default 'books' check (source in ('books', 'imported')),
  status text not null default 'draft' check (status in ('draft', 'approved', 'sent', 'filed', 'rejected')),
  imported jsonb not null default '{}'::jsonb,
  imported_from jsonb,
  overrides jsonb not null default '{}'::jsonb,
  adjustments jsonb not null default '{}'::jsonb,
  settings jsonb not null default '{}'::jsonb,
  snapshot jsonb,
  rulebook_id text references public.tax_rulebooks(id),
  template_path text,
  afs_path text,
  approved_by uuid references public.members(id) on delete set null,
  approved_at timestamptz,
  flux_ref text,
  flux_status text,
  flux_message text,
  flux_sent_at timestamptz,
  flux_updated_at timestamptz,
  filed_at timestamptz,
  acknowledgement_ref text,
  rev360_computation jsonb,
  updated_by uuid references public.members(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (org_id, accounting_year)
);
create index if not exists cit_years_rulebook_fk on public.cit_years(rulebook_id);
create index if not exists cit_years_approved_by_fk on public.cit_years(approved_by);
create index if not exists cit_years_updated_by_fk on public.cit_years(updated_by);
alter table public.cit_years enable row level security;
drop policy if exists cit_years_read on public.cit_years;
create policy cit_years_read on public.cit_years for select to authenticated using ((select private.can_handle_money(org_id)));

-- ---------------------------------------------------------------------------
-- 5. CIT engine: the year, its figures and the template's own totals
-- ---------------------------------------------------------------------------
-- The accounting period that ends in p_year (fiscal_year_start is the first month of the business's year).
create or replace function private.cit_period(p_org uuid, p_year int, out pfrom date, out pto date)
language sql stable security definer set search_path = public, private as $$
  select case when x.m = 1 then make_date(p_year, 1, 1) else make_date(p_year - 1, x.m, 1) end,
         case when x.m = 1 then make_date(p_year, 12, 31) else (make_date(p_year, x.m, 1) - 1) end
  from (select coalesce((select fiscal_year_start from orgs where id = p_org), 1) m) x
$$;

-- Year of assessment for an accounting year: the preceding-year basis (accounts ending in 2025 are YOA 2026).
create or replace function private.cit_yoa(p_year int) returns int language sql immutable set search_path = '' as $$ select p_year + 1 $$;

-- Does Counta hold the whole year in its books? Yes when the books start on or before the first day, or when the opening
-- balances were brought in during the year from a trial balance that carries the profit or loss to that date.
create or replace function private.cit_books_cover(p_org uuid, p_from date, p_to date) returns boolean
language sql stable security definer set search_path = public, private as $$
  select coalesce((select books_start from orgs where id = p_org), (select min(j.entry_date) from journals j where j.org_id = p_org)) <= p_from
    or exists (select 1 from books_migrations b where b.org_id = p_org and b.status = 'posted' and b.as_of >= p_from - 1 and b.as_of < p_to)
$$;

-- Which figures a year uses until the business says otherwise: the books whenever they reach into the year (a year they only
-- partly cover is held back from approval by the books_partial check), audited accounts or a trial balance before that.
create or replace function private.cit_default_source(p_org uuid, p_from date, p_to date) returns text
language sql stable security definer set search_path = public, private as $$
  select case when private.cit_books_cover(p_org, p_from, p_to)
           or coalesce((select books_start from orgs where id = p_org), (select min(j.entry_date) from journals j where j.org_id = p_org)) <= p_to
         then 'books' else 'imported' end
$$;

-- Every account code a business posts to, with the standard TaxStreem account it rolls up to.
create or replace function private.cit_std(p_org uuid) returns table (code text, std text, statement text, category text)
language sql stable security definer set search_path = public, private as $$
  select a.code, a.code, a.statement, a.category from accounts a
  union all
  select o.code, o.parent_code, o.statement, o.category from org_accounts o where o.org_id = p_org
$$;

-- Template figures from the books for a period: {cells: {cell: amount}, detail: {cell: {code: amount}}, codes: {code: amount}}.
-- Every account lands on exactly one line, so the template's profit before tax and balance sheet agree with the accounts.
create or replace function private.cit_books_figures(p_org uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v jsonb := '{}'::jsonb; d jsonb := '{}'::jsonb; c jsonb := '{}'::jsonb; r record; v_cell text; v_amt numeric; v_sum numeric; v_rd numeric;
  v_open numeric; v_close numeric; v_amort numeric; v_gross numeric; v_alloc numeric; v_left numeric; v_last text; v_ret numeric; s jsonb;
  v_cust numeric; v_vend numeric; v_neg_to text;
begin
  -- Profit or loss for the year, by template line.
  for r in
    with std as (select * from private.cit_std(p_org)),
    mv as (select m.code, coalesce(s.std, m.code) std, coalesce(s.statement, 'pl') statement, s.category, m.net from private.movement(p_org, p_from, p_to) m
           left join std s on s.code = m.code where m.net <> 0)
    select mv.code, mv.std, mv.statement, mv.category, mv.net,
      coalesce((select l.cell from cit_template_lines l where l.basis = 'movement' and mv.std = any(l.codes) limit 1),
               (select l.cell from cit_template_lines l where l.basis = 'movement' and split_part(mv.std, '-', 1) = any(l.codes) limit 1)) cell,
      (select l.sign from cit_template_lines l where l.basis = 'movement' and (mv.std = any(l.codes) or split_part(mv.std, '-', 1) = any(l.codes)) limit 1) sign
    from mv where mv.statement in ('pl', 'oci')
  loop
    if split_part(r.std, '-', 1) in ('4131', '4132') then continue; end if;   -- shared across the sectors below
    v_cell := coalesce(r.cell, case
      when r.statement = 'oci' then 'INCOME_STATEMENT!D125'
      when r.std like '41%' then 'INCOME_STATEMENT!D27'
      when r.category = 'Income' then 'OTHER_INCOME!D17'
      when r.category = 'Cost of Sales' then 'INCOME_STATEMENT!D84'
      when r.std like '75%' then 'INCOME_STATEMENT!D116'
      when r.category = 'Finance Costs & Taxation' then 'INCOME_STATEMENT!D114'
      else 'ADMINISTRATIVE_EXPENSES!C70' end);
    v_amt := case when coalesce(r.sign, case when r.category = 'Income' or r.statement = 'oci' then 'cr' else 'dr' end) = 'cr' then -r.net else r.net end;
    v := jsonb_set(v, array[v_cell], to_jsonb(private.v(v, v_cell) + v_amt));
    d := jsonb_set(d, array[v_cell], coalesce(d->v_cell, '{}'::jsonb) || jsonb_build_object(r.code, private.v(d->v_cell, r.code) + v_amt));
    c := jsonb_set(c, array[r.code], to_jsonb(private.v(c, r.code) + r.net));
  end loop;

  -- Sales returns and discounts allowed come off the sectors in proportion to their sales.
  select coalesce(sum(m.net), 0) into v_rd from private.movement(p_org, p_from, p_to) m left join private.cit_std(p_org) s on s.code = m.code
  where split_part(coalesce(s.std, m.code), '-', 1) in ('4131', '4132');
  if v_rd <> 0 then
    select coalesce(sum(greatest(private.v(v, l.cell), 0)), 0) into v_gross from cit_template_lines l where l.section = 'revenue';
    v_left := v_rd; v_last := null;
    for r in select l.cell, private.v(v, l.cell) amt from cit_template_lines l where l.section = 'revenue' and private.v(v, l.cell) > 0 order by private.v(v, l.cell) loop
      v_alloc := round(v_rd * r.amt / v_gross, 2);
      v := jsonb_set(v, array[r.cell], to_jsonb(r.amt - v_alloc));
      v_left := v_left - v_alloc; v_last := r.cell;
    end loop;
    v_last := coalesce(v_last, 'INCOME_STATEMENT!D27');
    v := jsonb_set(v, array[v_last], to_jsonb(private.v(v, v_last) - v_left));
    d := jsonb_set(d, '{_returns_discounts}', to_jsonb(v_rd));
  end if;

  -- Other income lines take positive amounts only: a net debit moves to the matching expense line.
  for r in select l.cell, l.negative_to from cit_template_lines l where l.section = 'other_income' and private.v(v, l.cell) < 0 loop
    v_neg_to := coalesce(r.negative_to, 'ADMINISTRATIVE_EXPENSES!C70');
    v := jsonb_set(v, array[v_neg_to], to_jsonb(private.v(v, v_neg_to) - private.v(v, r.cell)));
    d := jsonb_set(d, array[v_neg_to], coalesce(d->v_neg_to, '{}'::jsonb) || jsonb_build_object('moved from ' || r.cell, -private.v(v, r.cell)));
    v := v - r.cell;
  end loop;

  -- Opening and closing inventory, and the difference to the inventory movement posted in the books.
  for r in
    select l.cell, l.basis, coalesce(sum(b.bal), 0) amt from cit_template_lines l
    left join lateral (select bb.bal from private.balances_at(p_org, case when l.basis = 'balance_start' then p_from - 1 else p_to end) bb
                       left join private.cit_std(p_org) s on s.code = bb.code where split_part(coalesce(s.std, bb.code), '-', 1) = any(l.codes)) b on true
    where l.section = 'cost_of_sales' and l.basis in ('balance_start', 'balance_end') group by l.cell, l.basis
  loop
    v := jsonb_set(v, array[r.cell], to_jsonb(r.amt));
  end loop;
  v_open := private.v(v, 'INCOME_STATEMENT!D66') + private.v(v, 'INCOME_STATEMENT!D67') + private.v(v, 'INCOME_STATEMENT!D68');
  v_close := private.v(v, 'INCOME_STATEMENT!D94') + private.v(v, 'INCOME_STATEMENT!D95') + private.v(v, 'INCOME_STATEMENT!D96');
  v := jsonb_set(v, '{INCOME_STATEMENT!D84}', to_jsonb(private.v(v, 'INCOME_STATEMENT!D84') - (v_open - v_close)));
  d := jsonb_set(d, '{INCOME_STATEMENT!D84}', coalesce(d->'INCOME_STATEMENT!D84', '{}'::jsonb) || jsonb_build_object('opening less closing inventory', -(v_open - v_close)));

  -- Retained earnings at the start of the year (with any profit not yet closed).
  v := jsonb_set(v, '{INCOME_STATEMENT!D127}', to_jsonb(private.v(private.sofp_map(p_org, p_from - 1), 'Retained earnings')));

  -- Statement of financial position at the year end.
  for r in
    with std as (select * from private.cit_std(p_org))
    select b.code, coalesce(s.std, b.code) std, coalesce(s.statement, 'sofp') statement, s.category, b.bal,
      (select l.cell from cit_template_lines l where l.basis = 'balance_end' and l.section like 'sofp%' and split_part(coalesce(s.std, b.code), '-', 1) = any(l.codes) limit 1) cell,
      (select l.sign from cit_template_lines l where l.basis = 'balance_end' and l.section like 'sofp%' and split_part(coalesce(s.std, b.code), '-', 1) = any(l.codes) limit 1) sign
    from private.balances_at(p_org, p_to) b left join std s on s.code = b.code
    where b.bal <> 0 and coalesce(s.statement, 'sofp') not in ('pl', 'oci')
  loop
    if split_part(r.std, '-', 1) = '1609' or split_part(r.std, '-', 1) = '3005' then continue; end if;
    if split_part(r.std, '-', 1) in ('1011', '1012', '1013', '1014', '1015', '1016', '1019') and r.bal < 0 then
      v_cell := 'STATEMENT_OF_FINANCIAL_POSITION!D81'; v_amt := -r.bal;          -- an overdrawn account is a borrowing
    elsif r.cell is null then
      v_cell := case
        when r.std like '9%' or r.statement = 'system' then case when r.bal > 0 then 'STATEMENT_OF_FINANCIAL_POSITION!D62' else 'STATEMENT_OF_FINANCIAL_POSITION!D92' end
        when r.category = 'Assets' then case when r.std < '1500' then 'STATEMENT_OF_FINANCIAL_POSITION!D62' else 'STATEMENT_OF_FINANCIAL_POSITION!D42' end
        when r.category = 'Liabilities' then case when r.std < '2500' then 'STATEMENT_OF_FINANCIAL_POSITION!D92' else 'STATEMENT_OF_FINANCIAL_POSITION!D110' end
        else 'STATEMENT_OF_FINANCIAL_POSITION!D124' end;
      v_amt := case when v_cell in ('STATEMENT_OF_FINANCIAL_POSITION!D62', 'STATEMENT_OF_FINANCIAL_POSITION!D42') then r.bal else -r.bal end;
    else
      v_cell := r.cell; v_amt := case when r.sign = 'dr' then r.bal else -r.bal end;
    end if;
    v := jsonb_set(v, array[v_cell], to_jsonb(private.v(v, v_cell) + v_amt));
    d := jsonb_set(d, array[v_cell], coalesce(d->v_cell, '{}'::jsonb) || jsonb_build_object(r.code, private.v(d->v_cell, r.code) + v_amt));
  end loop;
  -- Accumulated amortisation is shared across the intangible lines by their cost.
  select coalesce(sum(b.bal), 0) into v_amort from private.balances_at(p_org, p_to) b left join private.cit_std(p_org) s on s.code = b.code
  where split_part(coalesce(s.std, b.code), '-', 1) = '1609';
  if v_amort <> 0 then
    select coalesce(sum(greatest(private.v(v, l.cell), 0)), 0) into v_gross from cit_template_lines l
    where l.sheet = 'STATEMENT_OF_FINANCIAL_POSITION' and l.addr in ('D21', 'D22', 'D23', 'D24', 'D25', 'D26', 'D28', 'D29');
    v_left := v_amort; v_last := null;
    if v_gross > 0 then
      for r in select l.cell, private.v(v, l.cell) amt from cit_template_lines l
               where l.sheet = 'STATEMENT_OF_FINANCIAL_POSITION' and l.addr in ('D21', 'D22', 'D23', 'D24', 'D25', 'D26', 'D28', 'D29') and private.v(v, l.cell) > 0 order by 2 loop
        v_alloc := round(v_amort * r.amt / v_gross, 2);
        v := jsonb_set(v, array[r.cell], to_jsonb(r.amt + v_alloc));
        v_left := v_left - v_alloc; v_last := r.cell;
      end loop;
    end if;
    v_last := coalesce(v_last, 'STATEMENT_OF_FINANCIAL_POSITION!D29');
    v := jsonb_set(v, array[v_last], to_jsonb(private.v(v, v_last) + v_left));
  end if;
  -- Retained earnings with the profit not yet closed, and the reclassification of customers in credit and suppliers in debit,
  -- as in the financial statements.
  s := private.sofp_map(p_org, p_to);
  v := jsonb_set(v, '{STATEMENT_OF_FINANCIAL_POSITION!D114}', to_jsonb(private.v(s, 'Retained earnings')));
  v_cust := private.v(s, '_customer_credit_reclass'); v_vend := private.v(s, '_vendor_debit_reclass');
  if v_cust <> 0 then
    v := jsonb_set(v, '{STATEMENT_OF_FINANCIAL_POSITION!D48}', to_jsonb(private.v(v, 'STATEMENT_OF_FINANCIAL_POSITION!D48') + v_cust));
    v := jsonb_set(v, '{STATEMENT_OF_FINANCIAL_POSITION!D79}', to_jsonb(private.v(v, 'STATEMENT_OF_FINANCIAL_POSITION!D79') + v_cust));
  end if;
  if v_vend <> 0 then
    v := jsonb_set(v, '{STATEMENT_OF_FINANCIAL_POSITION!D57}', to_jsonb(private.v(v, 'STATEMENT_OF_FINANCIAL_POSITION!D57') + v_vend));
    v := jsonb_set(v, '{STATEMENT_OF_FINANCIAL_POSITION!D73}', to_jsonb(private.v(v, 'STATEMENT_OF_FINANCIAL_POSITION!D73') + v_vend));
  end if;

  -- Round every line; drop zeros.
  select coalesce(jsonb_object_agg(k, round(val::numeric, 2)) filter (where round(val::numeric, 2) <> 0), '{}'::jsonb) into v
  from jsonb_each_text(v) x(k, val);
  return jsonb_build_object('cells', v, 'detail', d, 'codes', c);
end $$;

-- The template's own totals, with exactly its formulas (so the computation starts from the same profit before tax that Rev360 reads).
create or replace function private.cit_totals(c jsonb) returns jsonb
language plpgsql immutable set search_path = public, private as $$
declare t jsonb; v_rev numeric := 0; v_cos numeric; v_oi numeric := 0; v_admin numeric := 0; v_pbt numeric; i int; v_e9 numeric := 0; v_e20 numeric := 0; v_e30 numeric := 0;
  v_e49 numeric := 0; v_e63s numeric := 0; v_e75 numeric := 0; v_e94 numeric := 0; v_e126 numeric; v_oci numeric := 0; v_add numeric := 0; v_less numeric := 0;
  f text := 'INCOME_STATEMENT!'; s text := 'STATEMENT_OF_FINANCIAL_POSITION!'; p text := 'PROFIT_ADJUSTMENT!';
begin
  for i in 7..27 loop v_rev := v_rev + private.v(c, f || 'D' || i); end loop;
  v_cos := (private.v(c, f || 'D66') + private.v(c, f || 'D67') + private.v(c, f || 'D68'))
         + (private.v(c, f || 'D71') + private.v(c, f || 'D72') - private.v(c, f || 'D73'))
         + (select coalesce(sum(private.v(c, f || 'D' || g)), 0) from generate_series(76, 84) g)
         + (select coalesce(sum(private.v(c, f || 'D' || g)), 0) from generate_series(87, 91) g)
         - (private.v(c, f || 'D94') + private.v(c, f || 'D95') + private.v(c, f || 'D96'));
  for i in 4..17 loop v_oi := v_oi + private.v(c, 'OTHER_INCOME!D' || i); end loop;
  for i in 4..70 loop v_admin := v_admin + private.v(c, 'ADMINISTRATIVE_EXPENSES!C' || i); end loop;
  v_pbt := v_rev - v_cos + v_oi - v_admin - private.v(c, f || 'D114');
  for i in 119..125 loop v_oci := v_oci + private.v(c, f || 'D' || i); end loop;
  for i in 10..19 loop v_e9 := v_e9 + private.v(c, s || 'D' || i); end loop;
  for i in 21..29 loop v_e20 := v_e20 + private.v(c, s || 'D' || i); end loop;
  for i in 31..42 loop v_e30 := v_e30 + private.v(c, s || 'D' || i); end loop;
  for i in 50..62 loop v_e49 := v_e49 + private.v(c, s || 'D' || i); end loop;
  for i in 64..67 loop v_e63s := v_e63s + private.v(c, s || 'D' || i); end loop;
  for i in 76..92 loop v_e75 := v_e75 + private.v(c, s || 'D' || i); end loop;
  for i in 95..110 loop v_e94 := v_e94 + private.v(c, s || 'D' || i); end loop;
  v_e126 := private.v(c, s || 'D112') + private.v(c, s || 'D113') + private.v(c, s || 'D114') + private.v(c, s || 'D115') + private.v(c, s || 'D116')
          + private.v(c, s || 'D117') + (select coalesce(sum(private.v(c, s || 'D' || g)), 0) from generate_series(119, 125) g);
  for i in 14..32 loop v_add := v_add + private.v(c, p || 'D' || i); end loop;
  for i in 36..40 loop v_less := v_less + private.v(c, p || 'D' || i); end loop;
  t := jsonb_build_object(
    'revenue', v_rev, 'cost_of_sales', v_cos, 'gross_profit', v_rev - v_cos, 'other_income', v_oi, 'operating_income', v_rev - v_cos + v_oi,
    'administrative_expenses', v_admin, 'finance_cost', private.v(c, f || 'D114'), 'profit_before_tax', v_pbt, 'taxation', private.v(c, f || 'D116'),
    'profit_after_tax', v_pbt - private.v(c, f || 'D116'), 'oci', v_oci, 'profit_for_year', v_pbt - private.v(c, f || 'D116') + v_oci,
    'retained_bf', private.v(c, f || 'D127'), 'retained_cf', v_pbt - private.v(c, f || 'D116') + v_oci + private.v(c, f || 'D127'),
    'depreciation', private.v(c, 'ADMINISTRATIVE_EXPENSES!C13') + private.v(c, f || 'D79'),
    'amortisation', private.v(c, 'ADMINISTRATIVE_EXPENSES!C14') + private.v(c, f || 'D83'),
    'interest_expense', private.v(c, 'ADMINISTRATIVE_EXPENSES!C19'),
    'ppe', private.v(c, s || 'D8'), 'investments', v_e9, 'intangibles', v_e20, 'other_non_current', v_e30,
    'non_current_assets', private.v(c, s || 'D8') + v_e9 + v_e20 + v_e30,
    'current_assets', private.v(c, s || 'D46') + private.v(c, s || 'D47') + private.v(c, s || 'D48') + v_e49 + v_e63s,
    'total_assets', private.v(c, s || 'D8') + v_e9 + v_e20 + v_e30 + private.v(c, s || 'D46') + private.v(c, s || 'D47') + private.v(c, s || 'D48') + v_e49 + v_e63s,
    'current_liabilities', private.v(c, s || 'D73') + private.v(c, s || 'D74') + v_e75, 'non_current_liabilities', v_e94, 'equity', v_e126,
    'total_equity_liabilities', private.v(c, s || 'D73') + private.v(c, s || 'D74') + v_e75 + v_e94 + v_e126,
    'addbacks', v_add + private.v(c, 'ADMINISTRATIVE_EXPENSES!C13') + private.v(c, f || 'D79'), 'deductions', v_less);
  return t;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Capital allowances under both regimes, asset by asset
-- ---------------------------------------------------------------------------
-- The Rev360 fixed-asset category an asset class is declared under. The category decides the allowance (config
-- category_to_class_map for the NTA; Second Schedule rates for the old law). null: not qualifying (land), not yet in use
-- (assets under construction) or outside these rules (petroleum).
create or replace function private.cit_default_category(p_class text) returns text
language sql immutable set search_path = '' as $$
  select case p_class
    when '1501' then 'Land' when '1502' then 'Building Non-Industrial' when '1503' then 'Building Industrial'
    when '1504' then 'Plants (excluding Furniture and fittings)' when '1505' then 'Others' when '1506' then 'Plants (excluding Furniture and fittings)'
    when '1507' then 'Others' when '1508' then 'Furnitures & Fittings expenditure' when '1509' then 'Others' when '1510' then 'Others'
    when '1511' then 'Motor vehicles expenditure' when '1512' then 'Motor vehicles expenditure' when '1513' then 'Plants (excluding Furniture and fittings)'
    when '1514' then 'Plants (excluding Furniture and fittings)' when '1515' then 'Plants (excluding Furniture and fittings)'
    when '1516' then 'Furnitures & Fittings expenditure' when '1517' then 'Plants (excluding Furniture and fittings)'
    when '1518' then 'Furnitures & Fittings expenditure' when '1519' then 'Furnitures & Fittings expenditure'
    when '1522' then 'Agricultural plants expenditure' when '1523' then 'ranching and plantation' when '1525' then 'Others'
    when '1526' then 'Building Non-Industrial' when '1527' then 'Others' else null end
$$;

-- The categories Rev360 offers (its own spelling) and Counta's asset description and accumulated depreciation codes.
create or replace function private.rev360_category(p_cat text) returns text
language sql immutable set search_path = '' as $$
  select case p_cat when 'Agricultural plants expenditure' then 'Agricultural plants exenditure' else p_cat end
$$;
create or replace function private.rev360_asset_code(p_class text) returns text
language sql immutable set search_path = '' as $$
  select case p_class
    when '1501' then '05.06.00100 - Freehold Land' when '1502' then '05.06.00200 - Non-Industrial Building' when '1503' then '05.06.00300 - Industrial Building'
    when '1504' then '05.06.00400 - Plants' when '1505' then '05.06.00500 - Ships, Boats & Yachts' when '1506' then '05.06.00600 - Heavy Equipment'
    when '1507' then '05.06.00700 - Aircraft Engine & Fuselage' when '1508' then '05.06.00800 - Aircraft & Vessel Furnishing'
    when '1509' then '05.06.00900 - Communications & Electricity Towers & Cables' when '1510' then '05.06.01000 - Trains & Tracks'
    when '1511' then '05.06.01100 - Motor vehicle' when '1512' then '05.06.01200 - Motor vehicle (bus, truck & mass transit coach)'
    when '1513' then '05.06.01300 - Tools & Equipments' when '1514' then '05.06.01400 - Office Equipment' when '1515' then '05.06.01500 - Medical equipments'
    when '1516' then '05.06.01600 - Household equipments' when '1517' then '05.06.01700 - Computer hardware ' when '1518' then '05.06.01800 - Office fixtures '
    when '1519' then '05.06.01900 - Furniture and fittings' when '1520' then '05.06.02000 - Asset under construction' when '1521' then '05.06.02100 - Capital Work in Progress'
    when '1522' then '05.06.02200 - Agricultural Plantations ( Bearers Plants)' when '1523' then '05.06.02300 - Biological Assets (poultry, fisheries & other livestock etc)'
    when '1524' then '05.06.02400 - Petroleum Development cost' when '1525' then '05.06.02500 - Distribution networks assets' when '1526' then '05.06.02600 - Leasehold improvement'
    else '05.06.02700 - Other plant, properties and equipments' end
$$;

-- The accounting year a day falls in (the year in which its accounting period ends).
create or replace function private.cit_year_of(p_org uuid, p_day date) returns int
language sql stable security definer set search_path = public, private as $$
  select case when x.m = 1 then extract(year from p_day)::int else extract(year from (p_day + make_interval(months => 13 - x.m)))::int end
  from (select coalesce((select fiscal_year_start from orgs where id = p_org), 1) m) x
$$;

-- Every asset the computations see: the register (owned and confirmed) and assets kept for tax only.
create or replace function private.cit_assets(p_org uuid) returns table (key text, asset_id uuid, kind text, number text, name text, class_account text, category text,
  qce numeric, in_use date, disposed_at date, proceeds numeric, enhancement numeric, disposal_costs numeric, use_pct numeric, qualifies boolean,
  accumulated numeric, accumulated_at date)
language sql stable security definer set search_path = public, private as $$
  select 'fa:' || fa.id, fa.id, 'register', fa.number, fa.name, fa.class_account, coalesce(fa.tax_category, private.cit_default_category(fa.class_account)),
    fa.cost, coalesce(fa.available_date, fa.created_at::date), case when fa.status = 'disposed' then fa.disposed_at end, coalesce(fa.proceeds, 0),
    fa.tax_enhancement, fa.tax_disposal_costs, fa.tax_use_pct, fa.tax_qualifies, null::numeric, null::date
  from fixed_assets fa where fa.org_id = p_org and fa.status in ('active', 'disposed')
  union all
  select 'ta:' || t.id, t.id, 'tax_only', null, t.name, t.class_account, t.tax_category, t.cost, t.in_use_from, t.disposed_at, coalesce(t.proceeds, 0),
    t.tax_enhancement, t.tax_disposal_costs, t.tax_use_pct, t.tax_qualifies, t.accumulated_depreciation, t.depreciation_as_at
  from tax_assets t where t.org_id = p_org
$$;

-- Capital allowance schedule for an accounting year. Each asset is rolled forward from the year it was first in use, under
-- the rule book of each year (old law to 2024 accounts, NTA from 2025 accounts), so the tax value carried into the year is
-- what the rules give. p_opts: {nontax_share (share of income that is not taxable, for partial-use pro-rating),
-- short_factor (days in a short first period / 365), opening_twdv: {asset key: tax value at the start of opening_year}, opening_year}.
create or replace function private.cit_ca(p_org uuid, p_year int, p_opts jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
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
    v_use := case when a.use_pct < 100 and v_ntax >= coalesce(private.rbn(rb_n, 'capital_allowances', 'rules', '5', 'threshold_pct'), 0.10) then a.use_pct / 100 else 1 end;
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
      v_legacy := (private.rulebook(y + 1)).regime = 'LEGACY_CITA';
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
      'regime', case when (private.rulebook(p_year + 1)).regime = 'LEGACY_CITA' then 'LEGACY_CITA' else 'NTA_2025' end,
      'rate', case when (private.rulebook(p_year + 1)).regime = 'LEGACY_CITA' then null else v_rate end,
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
    'regime', (private.rulebook(p_year + 1)).regime);
end $$;

-- ---------------------------------------------------------------------------
-- 7. The computation
-- ---------------------------------------------------------------------------
-- A profit adjustment row: {line, amount, basis, auto}. Amounts are positive; the row's place decides add or deduct.
create or replace function private.cit_item(p_label text, p_amount numeric, p_basis text, p_auto boolean default true) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object('label', p_label, 'amount', round(p_amount, 2), 'basis', p_basis, 'auto', p_auto)
$$;

-- The computation for one accounting year. p_bf: what the previous year carries forward ({losses, ca, interest: [{yoa, amount}]});
-- null means the year opens the chain and takes the amounts brought forward from its own settings. p_as_of: an earlier day for
-- an estimate of a year still running.
create or replace function private.cit_compute(p_org uuid, p_year int, p_bf jsonb default null, p_as_of date default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
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
  v_company := coalesce(o.legal_form, 'company') = 'company';
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
    v_checks := v_checks || jsonb_build_array(jsonb_build_object('id', 'not_company', 'severity', 'block', 'text', 'The business is not a company: its owners file personal income tax instead.'));
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
end $$;

-- The year's computation in the chain: earlier years (from the first one Counta prepares) pass their losses, unused allowances
-- and disallowed interest forward. Approved years pass what they were approved with.
create or replace function private.cit_first_year(p_org uuid) returns int
language sql stable security definer set search_path = public, private as $$
  select greatest(2023, least(
    coalesce((select min(c.accounting_year) from cit_years c where c.org_id = p_org and (c.source = 'books' or c.imported <> '{}'::jsonb or c.snapshot is not null)), 9999),
    coalesce((select private.cit_year_of(p_org, coalesce(o.books_start, (select min(j.entry_date) from journals j where j.org_id = p_org))) from orgs o where o.id = p_org), 9999)))
$$;

create or replace function private.cit_has_data(p_org uuid, p_year int) returns boolean
language sql stable security definer set search_path = public, private as $$
  select coalesce((select c.snapshot is not null or (c.source = 'imported' and c.imported <> '{}'::jsonb)
                          or (c.source = 'books' and private.cit_books_cover(p_org, (private.cit_period(p_org, p_year)).pfrom, (private.cit_period(p_org, p_year)).pto))
                   from cit_years c where c.org_id = p_org and c.accounting_year = p_year),
                  private.cit_books_cover(p_org, (private.cit_period(p_org, p_year)).pfrom, (private.cit_period(p_org, p_year)).pto))
$$;

create or replace function private.cit_run(p_org uuid, p_year int, p_as_of date default null) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare y int; y0 int := least(private.cit_first_year(p_org), p_year); bf jsonb := null; comp jsonb; cy public.cit_years;
begin
  for y in y0 .. p_year loop
    select * into cy from cit_years where org_id = p_org and accounting_year = y;
    if y < p_year and not private.cit_has_data(p_org, y) then bf := null; continue; end if;
    if cy.snapshot is not null and cy.status <> 'draft' then comp := cy.snapshot->'computation';
    else comp := private.cit_compute(p_org, y, bf, case when y = p_year then p_as_of end); end if;
    bf := comp->'cf';
  end loop;
  return comp;
end $$;

-- ---------------------------------------------------------------------------
-- 8. What the screens, the template file and Flux read
-- ---------------------------------------------------------------------------
-- Input cells to write into the Rev360 template: the year, every figure line and every profit adjustment row (zeros left blank).
create or replace function private.cit_cell_map(p_comp jsonb) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_array(jsonb_build_object('sheet', 'USER_INPUT', 'addr', 'D7', 'value', (p_comp->>'year')::int, 'label', 'Accounting year'))
    || coalesce((select jsonb_agg(jsonb_build_object('sheet', l.sheet, 'addr', l.addr, 'value', round(coalesce((p_comp->'cells'->>l.cell)::numeric, (p_comp->'adjustments'->>l.cell)::numeric), 2),
         'label', l.label) order by l.sort)
       from cit_template_lines l
       where l.cell <> 'USER_INPUT!D7' and coalesce((p_comp->'cells'->>l.cell)::numeric, (p_comp->'adjustments'->>l.cell)::numeric, 0) <> 0), '[]'::jsonb)
$$;

-- The fixed-asset declaration Rev360 asks for before the template: date, category, description, cost and depreciation.
create or replace function private.cit_declaration(p_org uuid, p_comp jsonb) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'key', x->>'key', 'name', x->>'name', 'number', x->>'number', 'date', x->>'in_use',
      'category', private.rev360_category(coalesce(x->>'category', 'Others')), 'description', private.rev360_asset_code(x->>'class'),
      'cost', (x->>'qce')::numeric,
      'accumulated_depreciation', case when x->>'kind' = 'register' then
          (select a.opening_accumulated + coalesce((select sum(l.credit - l.debit) from journal_lines l join journals j on j.id = l.journal_id
             where l.org_id = a.org_id and l.party_type = 'asset' and l.party_id = a.id and l.account_code = ac.accum_account and j.entry_date <= (p_comp->>'to')::date), 0)
           from fixed_assets a join asset_classes ac on ac.cost_account = a.class_account where a.id = (x->>'asset_id')::uuid)
        else (select t.accumulated_depreciation from tax_assets t where t.id = (x->>'asset_id')::uuid) end,
      'charge_for_year', case when x->>'kind' = 'register' then
          (select coalesce(sum(l.credit - l.debit), 0) from journal_lines l join journals j on j.id = l.journal_id join fixed_assets a on a.id = l.party_id
             join asset_classes ac on ac.cost_account = a.class_account
           where l.org_id = p_org and l.party_type = 'asset' and l.party_id = (x->>'asset_id')::uuid and l.account_code = ac.accum_account
             and j.entry_date between (p_comp->>'from')::date and (p_comp->>'to')::date) end,
      'disposed', (x->>'disposed')::boolean, 'proceeds', (x->>'proceeds')::numeric, 'allowance', (x->>'allowance')::numeric, 'twdv_cf', (x->>'twdv_cf')::numeric)
    order by x->>'in_use', x->>'name'), '[]'::jsonb)
  from jsonb_array_elements(coalesce(p_comp->'ca'->'assets', '[]'::jsonb)) x
  where coalesce(x->>'class', '') not in ('1520', '1521') and not (coalesce((x->>'disposed')::boolean, false) and x->>'kind' = 'register' and false)
$$;

-- Every year from the first one Counta prepares (2023 accounts at the earliest) to the year running now, with its computation.
create or replace function private.cit_chain(p_org uuid, p_upto int) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare y int; y0 int := least(private.cit_first_year(p_org), p_upto); bf jsonb := null; comp jsonb; cy public.cit_years; v jsonb := '[]'::jsonb; v_has boolean;
begin
  for y in y0 .. p_upto loop
    select * into cy from cit_years where org_id = p_org and accounting_year = y;
    v_has := private.cit_has_data(p_org, y);
    if not v_has and cy.accounting_year is null and y < p_upto then
      v := v || jsonb_build_array(jsonb_build_object('year', y, 'yoa', y + 1, 'has_data', false));
      bf := null; continue;
    end if;
    if cy.snapshot is not null and cy.status <> 'draft' then comp := cy.snapshot->'computation';
    else comp := private.cit_compute(p_org, y, bf, null); end if;
    v := v || jsonb_build_array(comp || jsonb_build_object('has_data', v_has));
    bf := case when v_has then comp->'cf' end;
  end loop;
  return v;
end $$;

create or replace function private.cit_can_see(p_org uuid) returns public.members
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Tax returns need See margins, Keep the books or Make payments.' using errcode = '42501'; end if;
  return m;
end $$;

-- The years list: 2023 accounts (or the first year of the books, if later) to the year running now.
create or replace function public.cit_years(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_now int := private.cit_year_of(p_org, private.local_day(p_org, now())); ch jsonb;
begin
  m := private.cit_can_see(p_org);
  ch := private.cit_chain(p_org, v_now);
  return jsonb_build_object('years', (select coalesce(jsonb_agg(jsonb_build_object(
      'year', (c->>'year')::int, 'yoa', (c->>'yoa')::int, 'from', c->>'from', 'to', c->>'to', 'regime', c->>'regime', 'rulebook', c->'rulebook',
      'source', c->>'source', 'has_data', coalesce((c->>'has_data')::boolean, false), 'ended', (c->>'ended')::boolean, 'class', c->>'class',
      'status', coalesce(cy.status, 'draft'), 'flux_status', cy.flux_status, 'filed_at', cy.filed_at, 'acknowledgement_ref', cy.acknowledgement_ref,
      'total_tax', (c->'figures'->>'total_tax')::numeric, 'payable', (c->'figures'->>'payable')::numeric, 'profit_before_tax', (c->'figures'->>'profit_before_tax')::numeric,
      'due', c->>'due', 'blocks', (select count(*) from jsonb_array_elements(coalesce(c->'checks', '[]'::jsonb)) k where k->>'severity' = 'block'),
      'warnings', (select count(*) from jsonb_array_elements(coalesce(c->'checks', '[]'::jsonb)) k where k->>'severity' = 'warn'))
      order by (c->>'year')::int desc), '[]'::jsonb)
    from jsonb_array_elements(ch) c left join cit_years cy on cy.org_id = p_org and cy.accounting_year = (c->>'year')::int),
    'first_year', private.cit_first_year(p_org), 'current_year', v_now, 'books_start', (select books_start from orgs where id = p_org),
    'profile', (select jsonb_build_object('legal_form', legal_form, 'industry', industry, 'professional_services', professional_services, 'commenced_on', commenced_on,
       'incorporation_date', incorporation_date, 'tin', tin, 'rc_number', rc_number, 'cit_profile', cit_profile, 'fiscal_year_start', fiscal_year_start) from orgs where id = p_org));
end $$;

-- One year, for its screens: the computation, the template lines with their amounts and where each came from, the capital
-- allowance schedule, the declaration and what the business has set.
create or replace function public.cit_year(p_org uuid, p_year int) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; cy public.cit_years; comp jsonb; p record;
begin
  m := private.cit_can_see(p_org);
  if p_year < 2000 or p_year > 2100 then raise exception 'Choose the year.'; end if;
  select * into cy from cit_years where org_id = p_org and accounting_year = p_year;
  select pfrom, pto into p from private.cit_period(p_org, p_year);
  comp := private.cit_run(p_org, p_year);
  return jsonb_build_object('computation', comp,
    'row', jsonb_build_object('status', coalesce(cy.status, 'draft'), 'source', comp->>'source', 'settings', coalesce(cy.settings, '{}'::jsonb),
      'adjustments', coalesce(cy.adjustments, '{}'::jsonb), 'overrides', coalesce(cy.overrides, '{}'::jsonb), 'imported', coalesce(cy.imported, '{}'::jsonb),
      'imported_from', cy.imported_from, 'afs_path', cy.afs_path, 'template_path', cy.template_path, 'approved_at', cy.approved_at,
      'approved_by', (select display_name from members where id = cy.approved_by), 'flux_status', cy.flux_status, 'flux_ref', cy.flux_ref,
      'flux_message', cy.flux_message, 'flux_sent_at', cy.flux_sent_at, 'filed_at', cy.filed_at, 'acknowledgement_ref', cy.acknowledgement_ref,
      'rev360_computation', cy.rev360_computation, 'updated_at', cy.updated_at),
    'lines', (select jsonb_agg(jsonb_build_object('cell', l.cell, 'sheet', l.sheet, 'addr', l.addr, 'section', l.section, 'label', l.label, 'note', l.note,
        'codes', l.codes, 'positive_only', l.positive_only, 'config_id', l.config_id,
        'amount', coalesce((comp->'cells'->>l.cell)::numeric, (comp->'adjustments'->>l.cell)::numeric, 0),
        'detail', comp->'detail'->l.cell, 'items', comp->'items'->l.cell,
        'source', case when l.sheet = 'PROFIT_ADJUSTMENT' then 'adjustment' when cy.overrides ? l.cell then 'override'
                       when comp->>'source' = 'imported' then coalesce(cy.imported->l.cell->>'source', 'imported') else 'books' end,
        'imported', cy.imported->l.cell, 'override', cy.overrides->l.cell) order by l.sort) from cit_template_lines l),
    'declaration', private.cit_declaration(p_org, comp),
    'tax_assets', (select coalesce(jsonb_agg(to_jsonb(t) order by t.in_use_from, t.name), '[]'::jsonb) from tax_assets t where t.org_id = p_org),
    'can_edit', private.perm_of(m, 'keep_books') and coalesce(cy.status, 'draft') in ('draft', 'rejected'),
    'can_approve', private.perm_of(m, 'keep_books') and (m.role = 'owner' or private.perm_of(m, 'approve_adjustments')),
    'period', jsonb_build_object('from', p.pfrom, 'to', p.pto));
end $$;

-- What the business sets for a year. p: {source, settings: {...}, adjustments: {cell: {items: [{label, amount, reason}], override: {amount, reason, label}|null}},
-- overrides: {cell: {amount, reason}|null}, imported: {cell: amount|null}, afs_path}. Keys left out stay as they are.
create or replace function public.save_cit_year(p_org uuid, p_year int, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
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
end $$;

-- Figures read from audited accounts or a trial balance (by the AI reader or an upload), replacing or adding to the year's lines.
-- p: {lines: [{cell, amount, confidence, note}], totals: {revenue, profit_before_tax, total_assets}, file_path, kind: 'afs'|'trial_balance', replace}
create or replace function public.cit_import(p_org uuid, p_year int, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; cy public.cit_years; pr record; v_imp jsonb; x jsonb; v_n int := 0;
begin
  m := private.require(p_org, 'keep_books');
  select pfrom, pto into pr from private.cit_period(p_org, p_year);
  insert into cit_years (org_id, accounting_year, period_from, period_to, source, updated_by) values (p_org, p_year, pr.pfrom, pr.pto, 'imported', m.id)
  on conflict (org_id, accounting_year) do nothing;
  select * into cy from cit_years where org_id = p_org and accounting_year = p_year for update;
  if cy.status not in ('draft', 'rejected') then raise exception 'The % return is %. Reopen it to change it.', p_year, cy.status; end if;
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
end $$;

-- Approve a year: everything that blocks must be settled. The figures, computation, template cells and the declaration are
-- frozen, so the file sent to Rev360 and the books can be compared later.
create or replace function public.approve_cit_year(p_org uuid, p_year int) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; cy public.cit_years; comp jsonb; v_blocks text;
begin
  m := private.require(p_org, 'keep_books');
  if not (m.role = 'owner' or private.perm_of(m, 'approve_adjustments')) then raise exception 'Only the owner or someone who approves adjustments approves a tax return.' using errcode = '42501'; end if;
  perform public.save_cit_year(p_org, p_year, '{}'::jsonb);
  select * into cy from cit_years where org_id = p_org and accounting_year = p_year for update;
  comp := private.cit_run(p_org, p_year);
  select string_agg(k->>'text', ' ') into v_blocks from jsonb_array_elements(comp->'checks') k where k->>'severity' = 'block';
  if v_blocks is not null then raise exception 'Not ready: %', v_blocks; end if;
  update cit_years set status = 'approved', approved_by = m.id, approved_at = now(), rulebook_id = comp->'rulebook'->>'id',
    snapshot = jsonb_build_object('computation', comp, 'cell_map', private.cit_cell_map(comp), 'declaration', private.cit_declaration(p_org, comp),
      'org', (select jsonb_build_object('name', name, 'tin', tin, 'rc_number', rc_number, 'address', address, 'taxstreem_org_id', taxstreem_org_id) from orgs where id = p_org),
      'approved_by', m.display_name, 'approved_at', now()),
    flux_status = null, flux_message = null, updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year;
  return public.cit_year(p_org, p_year);
end $$;

create or replace function public.reopen_cit_year(p_org uuid, p_year int, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; cy public.cit_years;
begin
  m := private.require(p_org, 'keep_books');
  select * into cy from cit_years where org_id = p_org and accounting_year = p_year for update;
  if not found or cy.status = 'draft' then raise exception 'The % return is not approved.', p_year; end if;
  if cy.status in ('sent', 'filed') then raise exception 'The % return is % on Rev360. File an amended return there; Counta keeps this one as filed.', p_year, cy.status; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Say why the return is reopened.'; end if;
  update cit_years set status = 'draft', snapshot = null, template_path = null, approved_by = null, approved_at = null,
    settings = settings || jsonb_build_object('reopened', jsonb_build_object('reason', left(trim(p_reason), 300), 'by', m.display_name, 'at', now())),
    updated_by = m.id, updated_at = now()
  where org_id = p_org and accounting_year = p_year;
  return public.cit_year(p_org, p_year);
end $$;

-- Assets kept for tax only (before the books, or from an earlier capital allowance schedule). p: {id, name, class_account, tax_category, in_use_from,
-- cost, accumulated_depreciation, depreciation_as_at, disposed_at, proceeds, tax_enhancement, tax_disposal_costs, tax_use_pct, tax_qualifies, note, delete}
create or replace function public.save_tax_asset(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_id uuid := nullif(p->>'id', '')::uuid; v_cat text;
begin
  m := private.require(p_org, 'keep_books');
  if v_id is not null and not exists (select 1 from tax_assets where id = v_id and org_id = p_org) then raise exception 'Asset not found.'; end if;
  if coalesce((p->>'delete')::boolean, false) then delete from tax_assets where id = v_id and org_id = p_org; return jsonb_build_object('ok', true); end if;
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'Name the asset.'; end if;
  v_cat := coalesce(nullif(p->>'tax_category', ''), private.cit_default_category(nullif(p->>'class_account', '')));
  if v_cat is null or not ((private.rulebook(2026)).config->'capital_allowances'->'category_to_class_map') ? v_cat then raise exception 'Choose the Rev360 category.'; end if;
  if nullif(p->>'in_use_from', '') is null then raise exception 'Enter the date it was first used.'; end if;
  if coalesce(private.num(p->>'cost'), -1) < 0 then raise exception 'Enter the cost.'; end if;
  if nullif(p->>'disposed_at', '') is not null and (p->>'disposed_at')::date < (p->>'in_use_from')::date then raise exception 'It cannot be disposed of before it was used.'; end if;
  if v_id is null then
    insert into tax_assets (org_id, name, class_account, tax_category, in_use_from, cost, accumulated_depreciation, depreciation_as_at, disposed_at, proceeds,
      tax_enhancement, tax_disposal_costs, tax_use_pct, tax_qualifies, source, note, created_by)
    values (p_org, left(trim(p->>'name'), 160), (select cost_account from asset_classes where cost_account = p->>'class_account'), v_cat, (p->>'in_use_from')::date,
      round(private.num(p->>'cost'), 2), round(coalesce(private.num(p->>'accumulated_depreciation'), 0), 2), nullif(p->>'depreciation_as_at', '')::date,
      nullif(p->>'disposed_at', '')::date, round(private.num(p->>'proceeds'), 2), round(coalesce(private.num(p->>'tax_enhancement'), 0), 2),
      round(coalesce(private.num(p->>'tax_disposal_costs'), 0), 2), coalesce(private.num(p->>'tax_use_pct'), 100), coalesce((p->>'tax_qualifies')::boolean, true),
      coalesce(nullif(p->>'source', ''), 'manual'), nullif(trim(p->>'note'), ''), m.id)
    returning id into v_id;
  else
    update tax_assets set name = left(trim(p->>'name'), 160), class_account = (select cost_account from asset_classes where cost_account = p->>'class_account'),
      tax_category = v_cat, in_use_from = (p->>'in_use_from')::date, cost = round(private.num(p->>'cost'), 2),
      accumulated_depreciation = round(coalesce(private.num(p->>'accumulated_depreciation'), 0), 2), depreciation_as_at = nullif(p->>'depreciation_as_at', '')::date,
      disposed_at = nullif(p->>'disposed_at', '')::date, proceeds = round(private.num(p->>'proceeds'), 2),
      tax_enhancement = round(coalesce(private.num(p->>'tax_enhancement'), 0), 2), tax_disposal_costs = round(coalesce(private.num(p->>'tax_disposal_costs'), 0), 2),
      tax_use_pct = coalesce(private.num(p->>'tax_use_pct'), 100), tax_qualifies = coalesce((p->>'tax_qualifies')::boolean, true), note = nullif(trim(p->>'note'), '')
    where id = v_id;
  end if;
  return (select to_jsonb(t) from tax_assets t where t.id = v_id);
end $$;

-- The tax view of an asset in the register. p: {tax_category, tax_use_pct, tax_enhancement, tax_disposal_costs, tax_qualifies, tax_note}
create or replace function public.set_asset_tax(p_asset uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; a public.fixed_assets;
begin
  select * into a from fixed_assets where id = p_asset;
  if not found then raise exception 'Asset not found.'; end if;
  m := private.require(a.org_id, 'keep_books');
  if nullif(p->>'tax_category', '') is not null and not ((private.rulebook(2026)).config->'capital_allowances'->'category_to_class_map') ? (p->>'tax_category') then
    raise exception 'Choose one of the Rev360 categories.';
  end if;
  if p ? 'tax_use_pct' and (private.num(p->>'tax_use_pct') is null or private.num(p->>'tax_use_pct') not between 0 and 100) then raise exception 'The share used for the business is between 0 and 100%%.'; end if;
  update fixed_assets set tax_category = case when p ? 'tax_category' then nullif(p->>'tax_category', '') else tax_category end,
    tax_use_pct = coalesce(private.num(p->>'tax_use_pct'), tax_use_pct), tax_enhancement = coalesce(round(private.num(p->>'tax_enhancement'), 2), tax_enhancement),
    tax_disposal_costs = coalesce(round(private.num(p->>'tax_disposal_costs'), 2), tax_disposal_costs),
    tax_qualifies = coalesce((p->>'tax_qualifies')::boolean, tax_qualifies), tax_note = case when p ? 'tax_note' then nullif(trim(p->>'tax_note'), '') else tax_note end
  where id = a.id;
  return private.asset_json(a.id);
end $$;

-- The business's tax profile.
-- p: {professional_services, commenced_on, cit_profile: {...}, wvat_agent: bank|telecom|oil_gas|government|digital_platform|other|null,
--     wht_small_company: bool}
create or replace function public.save_tax_profile(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_prof jsonb; x record;
begin
  m := private.require(p_org, 'keep_books');
  select cit_profile into v_prof from orgs where id = p_org;
  for x in select key, value from jsonb_each(coalesce(p->'cit_profile', '{}'::jsonb)) loop
    if x.key not in ('non_resident', 'mne_constituent', 'group_turnover_eur', 'eur_ngn_rate', 'bank_or_insurer_subsidiary', 'imported_equity_25', 'agricultural_trade',
                     'free_zone', 'sector_regime', 'hydrocarbon') then raise exception 'Unknown setting %.', x.key; end if;
    v_prof := case when jsonb_typeof(x.value) = 'null' then v_prof - x.key else jsonb_set(v_prof, array[x.key], x.value) end;
  end loop;
  if p ? 'wvat_agent' and nullif(p->>'wvat_agent', '') is not null and p->>'wvat_agent' not in ('bank', 'telecom', 'oil_gas', 'government', 'digital_platform', 'other') then
    raise exception 'Choose what kind of withholding VAT agent the business is.';
  end if;
  if p ? 'commenced_on' and nullif(p->>'commenced_on', '')::date > private.local_day(p_org, now()) then raise exception 'The business cannot start in the future.'; end if;
  update orgs set professional_services = coalesce((p->>'professional_services')::boolean, professional_services),
    commenced_on = case when p ? 'commenced_on' then nullif(p->>'commenced_on', '')::date else commenced_on end,
    wvat_agent = case when p ? 'wvat_agent' then nullif(p->>'wvat_agent', '') else wvat_agent end,
    wht_small_company = coalesce((p->>'wht_small_company')::boolean, wht_small_company),
    cit_profile = v_prof
  where id = p_org;
  -- Draft bills follow a change to how the business withholds.
  if p ? 'wvat_agent' or p ? 'wht_small_company' then perform private.bill_wht(b.id) from bills b where b.org_id = p_org and b.status = 'draft'; end if;
  return public.cit_years(p_org);
end $$;

-- For the tax-files function (service role): the approved year's frozen pack.
create or replace function public.svc_cit_pack(p_org uuid, p_year int) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('org_id', c.org_id, 'year', c.accounting_year, 'status', c.status, 'snapshot', c.snapshot, 'afs_path', c.afs_path,
    'template_path', c.template_path, 'flux_ref', c.flux_ref)
  from cit_years c where c.org_id = p_org and c.accounting_year = p_year
$$;

-- Flux reports back (service role). p: {status: sent|filed|rejected, ref, message, acknowledgement_ref, rev360_computation, template_path}
create or replace function public.svc_cit_flux_update(p_org uuid, p_year int, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare cy public.cit_years; v_status text := p->>'status';
begin
  select * into cy from cit_years where org_id = p_org and accounting_year = p_year for update;
  if not found then raise exception 'No % return for this business.', p_year; end if;
  if v_status is not null and v_status not in ('sent', 'filed', 'rejected', 'template_ready') then raise exception 'Unknown status %.', v_status; end if;
  if v_status in ('sent', 'filed', 'rejected') and cy.status = 'draft' then raise exception 'The % return is not approved.', p_year; end if;
  update cit_years set
    status = case when v_status in ('sent', 'filed', 'rejected') then v_status else status end,
    template_path = coalesce(nullif(p->>'template_path', ''), template_path),
    flux_ref = coalesce(nullif(p->>'ref', ''), flux_ref),
    flux_status = coalesce(nullif(p->>'flux_status', ''), v_status, flux_status),
    flux_message = case when p ? 'message' then left(p->>'message', 1000) else flux_message end,
    flux_sent_at = case when v_status = 'sent' then now() else flux_sent_at end,
    flux_updated_at = now(),
    filed_at = case when v_status = 'filed' then coalesce(nullif(p->>'filed_at', '')::timestamptz, now()) else filed_at end,
    acknowledgement_ref = coalesce(nullif(p->>'acknowledgement_ref', ''), acknowledgement_ref),
    rev360_computation = coalesce(p->'rev360_computation', rev360_computation)
  where org_id = p_org and accounting_year = p_year;
  if v_status in ('filed', 'rejected') then
    perform private.notify_perm(p_org, 'keep_books', 'books', p_year || ' companies income tax return ' || v_status,
      coalesce(nullif(p->>'message', ''), case when v_status = 'filed' then 'Acknowledgement ' || coalesce(p->>'acknowledgement_ref', '') else 'Rev360 did not accept it' end),
      '/accounting/tax?year=' || p_year, 'cit-' || p_year || '-' || v_status, null);
  end if;
  return public.svc_cit_pack(p_org, p_year);
end $$;

-- ---------------------------------------------------------------------------
-- CIT file pack: what the Rev360 template and the Flux hand-off need for one year.
-- ---------------------------------------------------------------------------
-- A draft is computed now and marked as a draft; an approved (or sent, filed, rejected) return is the frozen snapshot, so the
-- file Flux files is exactly what the owner approved.
create or replace function public.cit_pack(p_org uuid, p_year int) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; cy public.cit_years; comp jsonb; o public.orgs; v_draft boolean; v_org jsonb; v_tin text;
begin
  m := private.cit_can_see(p_org);
  if p_year < 2000 or p_year > 2100 then raise exception 'Choose the year.'; end if;
  select * into cy from cit_years where org_id = p_org and accounting_year = p_year;
  select * into o from orgs where id = p_org;
  v_draft := cy.accounting_year is null or cy.status = 'draft' or cy.snapshot is null;
  if v_draft then
    comp := private.cit_run(p_org, p_year, null);
    v_org := jsonb_build_object('name', o.name, 'tin', o.tin, 'rc_number', o.rc_number, 'address', o.address, 'taxstreem_org_id', o.taxstreem_org_id);
  else
    comp := cy.snapshot->'computation';
    v_org := cy.snapshot->'org';
  end if;
  v_tin := nullif(regexp_replace(coalesce(v_org->>'tin', ''), '[^0-9A-Za-z-]', '', 'g'), '');
  return jsonb_build_object(
    'org_id', p_org, 'year', p_year, 'yoa', (comp->>'yoa')::int, 'regime', comp->>'regime', 'from', comp->>'from', 'to', comp->>'to',
    'status', coalesce(cy.status, 'draft'), 'draft', v_draft, 'org', v_org,
    'cell_map', case when v_draft then private.cit_cell_map(comp) else cy.snapshot->'cell_map' end,
    'declaration', case when v_draft then private.cit_declaration(p_org, comp) else cy.snapshot->'declaration' end,
    'figures', comp->'figures', 'rows', comp->'rows', 'checks', comp->'checks', 'due', comp->>'due',
    'file_name', p_year || '_' || coalesce(v_tin, 'NO-TIN') || '_CIT' || case when v_draft then '_DRAFT' else '' end || '.xlsx',
    'afs_path', cy.afs_path, 'template_path', case when v_draft then null else cy.template_path end,
    'approved_by', cy.snapshot->>'approved_by', 'approved_at', cy.snapshot->>'approved_at',
    'flux', jsonb_build_object('status', cy.flux_status, 'ref', cy.flux_ref, 'message', cy.flux_message, 'sent_at', cy.flux_sent_at,
      'updated_at', cy.flux_updated_at, 'acknowledgement_ref', cy.acknowledgement_ref, 'filed_at', cy.filed_at),
    'can_send', not v_draft and cy.status in ('approved', 'rejected') and cy.afs_path is not null
      and private.perm_of(m, 'keep_books') and (m.role = 'owner' or private.perm_of(m, 'approve_adjustments')));
end $$;

-- ---------------------------------------------------------------------------
-- Storage: tax files (returns, schedules, financial statements) are for the people who can see tax returns.
-- ---------------------------------------------------------------------------
create or replace function private.can_handle_money_text(p_org text) returns boolean
language sql stable security definer set search_path = public, private as $$
  select case when p_org ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then private.can_handle_money(p_org::uuid) else false end
$$;

do $$
begin
  if to_regclass('storage.objects') is not null then
    drop policy if exists "documents read by members" on storage.objects;
    create policy "documents read by members" on storage.objects for select to authenticated
      using (bucket_id = 'documents' and (select private.is_member_text((storage.foldername(name))[1]))
        and ((storage.foldername(name))[2] is distinct from 'tax' or (select private.can_handle_money_text((storage.foldername(name))[1]))));
    drop policy if exists "documents upload by members" on storage.objects;
    create policy "documents upload by members" on storage.objects for insert to authenticated
      with check (bucket_id = 'documents' and (select private.is_member_text((storage.foldername(name))[1]))
        and ((storage.foldername(name))[2] is distinct from 'tax' or (select private.can_handle_money_text((storage.foldername(name))[1]))));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- The statements pack, the Tax tab and the posted charge now come from the CIT engine above (one computation everywhere).
-- ---------------------------------------------------------------------------
-- The old per-period settings move onto the tax years: professional services onto the business, losses and allowances
-- brought forward and the business's own adjustments onto that year (added back under "Others", row 32; deducted under
-- "Others", row 40). tax_settings keeps only the record of the charge posted from the computation.
do $$
declare s record; v_year int; x jsonb; v_add jsonb; v_less jsonb; per record;
begin
  for s in select * from tax_settings loop
    v_year := private.cit_year_of(s.org_id, s.period_end);
    select pfrom, pto into per from private.cit_period(s.org_id, v_year);
    if s.professional_services then update orgs set professional_services = true where id = s.org_id; end if;
    v_add := '[]'::jsonb; v_less := '[]'::jsonb;
    for x in select * from jsonb_array_elements(coalesce(s.adjustments, '[]'::jsonb)) loop
      if x->>'kind' = 'deduct' then v_less := v_less || jsonb_build_array(jsonb_build_object('label', x->>'label', 'amount', abs((x->>'amount')::numeric), 'reason', x->>'reason'));
      else v_add := v_add || jsonb_build_array(jsonb_build_object('label', x->>'label', 'amount', abs((x->>'amount')::numeric), 'reason', x->>'reason')); end if;
    end loop;
    insert into cit_years (org_id, accounting_year, period_from, period_to, source, settings, adjustments, updated_by, updated_at)
    values (s.org_id, v_year, per.pfrom, per.pto, private.cit_default_source(s.org_id, per.pfrom, per.pto),
      jsonb_strip_nulls(jsonb_build_object('losses_bf', nullif(s.losses_bf, 0), 'ca_bf', nullif(s.unabsorbed_ca_bf, 0), 'notes', s.notes)),
      jsonb_strip_nulls(jsonb_build_object(
        'PROFIT_ADJUSTMENT!D32', case when jsonb_array_length(v_add) > 0 then jsonb_build_object('items', v_add) end,
        'PROFIT_ADJUSTMENT!D40', case when jsonb_array_length(v_less) > 0 then jsonb_build_object('items', v_less) end)),
      s.updated_by, s.updated_at)
    on conflict (org_id, accounting_year) do nothing;
  end loop;
end $$;

-- The computation for a statements period, in the shape the statements pack and the Tax tab read. The period's financial
-- year is computed by the engine (to the period's last day when the year is still running).
create or replace function private.tax_computation(p_org uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; st public.tax_settings; comp jsonb; v_year int; per record; v_as_of date; r jsonb; v_rows jsonb := '[]'::jsonb; v_det jsonb;
  l record; it jsonb; v_flags jsonb := '[]'::jsonb; k jsonb; f jsonb; v_tax_exp numeric; mv jsonb; c jsonb; v_ca_rows jsonb := '[]'::jsonb; v_adj jsonb := '[]'::jsonb;
  v_dep numeric; v_int_cf numeric;
begin
  select * into o from orgs where id = p_org;
  v_year := private.cit_year_of(p_org, p_to);
  select pfrom, pto into per from private.cit_period(p_org, v_year);
  v_as_of := case when p_to < per.pto then p_to end;
  comp := private.cit_run(p_org, v_year, v_as_of);
  f := comp->'figures';
  select * into st from tax_settings where org_id = p_org and period_end = per.pto;
  select coalesce(jsonb_object_agg(code, net), '{}'::jsonb) into mv from private.movement(p_org, per.pfrom, p_to);
  v_tax_exp := private.sum_codes(mv, array['7501', '7502', '7505']);
  v_dep := coalesce((comp->'totals'->>'depreciation')::numeric, 0);

  for r in select * from jsonb_array_elements(comp->'rows') loop
    if r->>'id' in ('B', 'C') then
      -- The adjustment rows, item by item with where each figure comes from.
      v_det := '[]'::jsonb;
      if r->>'id' = 'B' and v_dep <> 0 then
        v_det := v_det || jsonb_build_array(jsonb_build_object('line', 'Depreciation', 'current', v_dep, 'basis', 'Capital allowances are given instead', '_style', 'line', '_indent', 1));
      end if;
      for l in select t.cell, t.label from cit_template_lines t where t.sheet = 'PROFIT_ADJUSTMENT'
                 and ((r->>'id' = 'B' and t.addr between 'D14' and 'D32' and length(t.addr) = 3) or (r->>'id' = 'C' and t.addr between 'D36' and 'D40'))
               order by t.sort loop
        if coalesce((comp->'adjustments'->>l.cell)::numeric, 0) = 0 then continue; end if;
        if jsonb_array_length(coalesce(comp->'items'->l.cell, '[]'::jsonb)) = 0 then
          v_det := v_det || jsonb_build_array(jsonb_build_object('line', l.label, 'current', (case when r->>'id' = 'C' then -1 else 1 end) * (comp->'adjustments'->>l.cell)::numeric,
            'basis', 'Profit adjustment row ' || substr(l.cell, length(l.cell) - 1), '_style', 'line', '_indent', 1));
        else
          for it in select * from jsonb_array_elements(comp->'items'->l.cell) loop
            continue when coalesce((it->>'amount')::numeric, 0) = 0;
            v_det := v_det || jsonb_build_array(jsonb_build_object('line', case when it->>'label' = 'Set by the business' then l.label else it->>'label' end,
              'current', (case when r->>'id' = 'C' then -1 else 1 end) * (it->>'amount')::numeric, 'basis', it->>'basis', '_style', 'line', '_indent', 1,
              'manual', not coalesce((it->>'auto')::boolean, true)));
            if not coalesce((it->>'auto')::boolean, true) and l.cell in ('PROFIT_ADJUSTMENT!D32', 'PROFIT_ADJUSTMENT!D40') then
              v_adj := v_adj || jsonb_build_array(jsonb_build_object('label', it->>'label', 'amount', (it->>'amount')::numeric,
                'kind', case when r->>'id' = 'C' then 'deduct' else 'add' end, 'reason', it->>'basis', 'cell', l.cell));
            end if;
          end loop;
        end if;
      end loop;
      if jsonb_array_length(v_det) > 0 then
        v_rows := v_rows || jsonb_build_array(jsonb_build_object('line', case when r->>'id' = 'B' then 'Add: expenses not allowed' else 'Less: income not taxed here, and tax-only deductions' end,
          '_style', 'heading', '_indent', 0)) || v_det;
      end if;
    else
      v_rows := v_rows || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('line', r->>'line', 'current', (r->>'amount')::numeric, 'basis', r->>'basis',
        '_style', coalesce(r->>'_style', 'line'), '_indent', case when coalesce(r->>'_style', 'line') = 'line' then 1 else 0 end, 'id', r->>'id')));
    end if;
  end loop;
  if coalesce((comp->'cf'->>'losses')::numeric, 0) > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('line', 'Loss carried forward', 'current', (comp->'cf'->>'losses')::numeric, '_style', 'line', '_indent', 0, 'memo', true));
  end if;
  if coalesce((comp->'cf'->>'ca')::numeric, 0) > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('line', 'Unabsorbed capital allowances carried forward', 'current', (comp->'cf'->>'ca')::numeric, '_style', 'line', '_indent', 0, 'memo', true));
  end if;
  v_int_cf := case jsonb_typeof(comp->'cf'->'interest') when 'number' then (comp->'cf'->>'interest')::numeric
    when 'array' then (select coalesce(sum((e->>'amount')::numeric), 0) from jsonb_array_elements(comp->'cf'->'interest') e) else 0 end;
  if v_int_cf > 0 then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('line', 'Interest to connected persons carried forward', 'current', v_int_cf, '_style', 'line', '_indent', 0, 'memo', true));
  end if;

  -- The return's own checks, less the ones about filing it (the statements are what the audited accounts become).
  for k in select * from jsonb_array_elements(coalesce(comp->'checks', '[]'::jsonb)) where value->>'id' not in ('afs_attached', 'tax_credit', 'small_company_still_files') loop
    v_flags := v_flags || jsonb_build_array(jsonb_build_object('level', case when k->>'id' = 'year_not_ended' then 'info' when k->>'severity' = 'block' then 'error'
      when k->>'severity' = 'warn' then 'warn' else 'info' end, 'text', k->>'text', 'key', k->>'id'));
  end loop;
  if p_from > per.pfrom then v_flags := v_flags || jsonb_build_array(jsonb_build_object('level', 'info', 'text',
    'Tax is computed on the financial year: this one runs from ' || private.fdate(per.pfrom) || ', so the computation covers ' || private.fdate(per.pfrom) || ' to ' || private.fdate(p_to) || '.')); end if;
  if v_tax_exp <> 0 and st.posted_journal_id is null then v_flags := v_flags || jsonb_build_array(jsonb_build_object('level', 'info', 'text',
    'Tax of ' || private.naira(v_tax_exp) || ' is already in the accounts for this year. Posting this computation replaces only a charge posted from here.')); end if;

  -- Capital allowances by Rev360 category, then asset by asset.
  for c in select * from jsonb_array_elements(coalesce(comp->'ca'->'categories', '[]'::jsonb)) loop
    v_ca_rows := v_ca_rows || jsonb_build_array(jsonb_build_object('line', c->>'category', 'class_name', c->>'category', 'twdv_bf', c->'twdv_bf', 'additions', c->'additions',
      'disposals', c->'disposals', 'allowance', coalesce((c->>'allowance')::numeric, 0) + coalesce((c->>'investment')::numeric, 0), 'investment', c->'investment',
      'balancing_charge', c->'balancing_charge', 'balancing_allowance', c->'balancing_allowance', 'twdv_cf', c->'twdv_cf', 'assets', c->'assets', '_style', 'line', '_indent', 1));
  end loop;
  c := coalesce(comp->'ca'->'totals', '{}'::jsonb);
  v_ca_rows := v_ca_rows || jsonb_build_array(jsonb_build_object('line', 'Total', '_style', 'total', '_indent', 0, 'twdv_bf', c->'twdv_bf', 'additions', c->'additions',
    'disposals', c->'disposals', 'allowance', coalesce((c->>'allowance')::numeric, 0) + coalesce((c->>'investment')::numeric, 0), 'investment', c->'investment',
    'balancing_charge', c->'balancing_charge', 'balancing_allowance', c->'balancing_allowance', 'twdv_cf', c->'twdv_cf'));

  return jsonb_build_object('rows', v_rows, 'from', per.pfrom, 'to', p_to, 'flags', v_flags,
    'ca', jsonb_build_object('rows', v_ca_rows,
      'assets', (select coalesce(jsonb_agg(a || jsonb_build_object('number', coalesce(a->>'number', ''), 'allowance', coalesce((a->>'allowance')::numeric, 0) + coalesce((a->>'investment')::numeric, 0))
        order by a->>'in_use', a->>'name'), '[]'::jsonb) from jsonb_array_elements(coalesce(comp->'ca'->'assets', '[]'::jsonb)) a where coalesce((a->>'qualifies')::boolean, true)),
      'months', round(12 * coalesce((f->>'short_factor')::numeric, 1)), 'factor', coalesce((f->>'short_factor')::numeric, 1),
      'retention', case when comp->>'regime' = 'LEGACY_CITA' then 0 else 0.01 end, 'regime', comp->>'regime',
      'totals', c, 'missing_rates', coalesce(comp->'ca'->'missing', '[]'::jsonb)),
    'figures', jsonb_build_object('profit_before_tax', f->'profit_before_tax', 'turnover', f->'turnover', 'fixed_assets', f->'fixed_assets', 'adjusted', f->'assessable',
      'assessable', f->'assessable', 'balancing_charge', f->'balancing_charge', 'capital_allowances', f->'capital_allowances', 'total_profit', f->'total_profits',
      'small_company', comp->'small', 'rate', f->'cit_rate', 'cit', coalesce((f->>'cit_payable')::numeric, 0),
      'levy', coalesce((f->>'development_levy')::numeric, 0) + coalesce((f->>'tertiary_education_tax')::numeric, 0),
      'development_levy', f->'development_levy', 'tertiary_education_tax', f->'tertiary_education_tax', 'minimum_tax_used', f->'minimum_tax_used',
      'topup', coalesce((f->>'topup')::numeric, 0), 'wht_credit', f->'wht_credit', 'payable', f->'payable', 'total_tax', f->'total_tax',
      'loss_cf', coalesce((comp->'cf'->>'losses')::numeric, 0), 'ca_cf', coalesce((comp->'cf'->>'ca')::numeric, 0), 'company', comp->'company',
      'tax_in_accounts', v_tax_exp, 'regime', comp->>'regime', 'law', comp->'rulebook'->>'law', 'year', v_year, 'yoa', comp->'yoa', 'class', comp->>'class',
      'year_ended', comp->'ended'),
    'settings', jsonb_build_object('professional_services', coalesce(o.professional_services, false), 'losses_bf', coalesce((comp->'bf'->>'losses')::numeric, 0),
      'unabsorbed_ca_bf', coalesce((comp->'bf'->>'ca')::numeric, 0), 'adjustments', v_adj,
      'notes', (select settings->>'notes' from cit_years where org_id = p_org and accounting_year = v_year),
      'posted_journal_id', st.posted_journal_id, 'posted_at', st.posted_at, 'posted_cit', st.posted_cit, 'posted_levy', st.posted_levy,
      'posted_from', st.posted_from, 'posted_to', st.posted_to, 'posted_ref', (select ref from journals where id = st.posted_journal_id),
      'year_end', per.pto, 'year', v_year, 'cit_status', coalesce(comp->>'status', 'draft')),
    'rulebook', comp->'rulebook');
end $$;

-- p: {professional_services, losses_bf, unabsorbed_ca_bf, adjustments:[{label, amount, kind: add|deduct, reason}], notes}. Kept for the Tax tab;
-- writes the same things the Tax returns page does (the business, and the year's settings and "Others" rows).
create or replace function public.save_tax_settings(p_org uuid, p_period_end date, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; x jsonb; v_add jsonb := '[]'::jsonb; v_less jsonb := '[]'::jsonb; v_year int;
begin
  m := private.require(p_org, 'keep_books');
  if p_period_end is null then raise exception 'Choose the year.'; end if;
  v_year := private.cit_year_of(p_org, p_period_end);
  for x in select * from jsonb_array_elements(coalesce(p->'adjustments', '[]'::jsonb)) loop
    continue when coalesce(trim(x->>'label'), '') = '' and coalesce(private.num(x->>'amount'), 0) = 0;
    if coalesce(trim(x->>'label'), '') = '' then raise exception 'Name each adjustment.'; end if;
    if coalesce(trim(x->>'reason'), '') = '' then raise exception 'Give the reason for "%".', trim(x->>'label'); end if;
    if coalesce(private.num(x->>'amount'), 0) <= 0 then raise exception 'Enter the amount of "%".', trim(x->>'label'); end if;
    if x->>'kind' = 'deduct' then v_less := v_less || jsonb_build_array(jsonb_build_object('label', trim(x->>'label'), 'amount', private.num(x->>'amount'), 'reason', trim(x->>'reason')));
    else v_add := v_add || jsonb_build_array(jsonb_build_object('label', trim(x->>'label'), 'amount', private.num(x->>'amount'), 'reason', trim(x->>'reason'))); end if;
  end loop;
  if coalesce(private.num(p->>'losses_bf'), 0) < 0 or coalesce(private.num(p->>'unabsorbed_ca_bf'), 0) < 0 then raise exception 'Amounts brought forward cannot be negative.'; end if;
  if p ? 'professional_services' then
    perform public.save_tax_profile(p_org, jsonb_build_object('professional_services', coalesce((p->>'professional_services')::boolean, false)));
  end if;
  perform public.save_cit_year(p_org, v_year, jsonb_build_object(
    'settings', jsonb_build_object('losses_bf', coalesce(private.num(p->>'losses_bf'), 0), 'ca_bf', coalesce(private.num(p->>'unabsorbed_ca_bf'), 0), 'notes', nullif(trim(p->>'notes'), '')),
    'adjustments', jsonb_build_object('PROFIT_ADJUSTMENT!D32', jsonb_build_object('items', v_add), 'PROFIT_ADJUSTMENT!D40', jsonb_build_object('items', v_less))));
  return public.tax_computation(p_org, null, p_period_end);
end $$;

-- Posts the year's charge from the computation, dated the last day of the period: companies income tax (or minimum tax)
-- Dr 7501 / Cr 2208, any top-up Dr 7505 / Cr 2208, and the development levy (tertiary education tax for years under the old
-- law) Dr 7502 / Cr 2209. A financial year carries one charge from here: posting again reverses the earlier one on its own date.
create or replace function public.post_tax_charge(p_org uuid, p_from date, p_to date) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; c jsonb; st public.tax_settings; j public.journals; v_cit numeric; v_levy numeric; v_topup numeric; v_tet numeric; v_jl jsonb; v_end date; v_old date;
  v_legacy boolean; v_min boolean;
begin
  m := private.require(p_org, 'keep_books');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose the period.'; end if;
  perform private.require_open_day(p_org, p_to);
  c := private.tax_computation(p_org, p_from, p_to);
  v_end := (c->'settings'->>'year_end')::date;
  if not coalesce((c->'figures'->>'company')::boolean, false) then raise exception 'The business is not a company, so there is no companies income tax to post.'; end if;
  v_legacy := c->'figures'->>'regime' = 'LEGACY_CITA';
  v_min := coalesce((c->'figures'->>'minimum_tax_used')::boolean, false);
  v_cit := coalesce((c->'figures'->>'cit')::numeric, 0);
  v_topup := coalesce((c->'figures'->>'topup')::numeric, 0);
  v_levy := coalesce((c->'figures'->>'development_levy')::numeric, 0);
  v_tet := coalesce((c->'figures'->>'tertiary_education_tax')::numeric, 0);
  select * into st from tax_settings where org_id = p_org and period_end = v_end for update;
  if st.posted_journal_id is not null and not exists (select 1 from journals where reversal_of = st.posted_journal_id) then
    select entry_date into v_old from journals where id = st.posted_journal_id;
    perform private.require_open_day(p_org, v_old);
    perform private.reverse_entry(st.posted_journal_id, m.id, 'Tax charge recomputed', null);
  end if;
  if v_cit + v_levy + v_topup + v_tet > 0 then
    v_jl := jsonb_build_array(
      jsonb_build_object('code', '7501', 'debit', v_cit, 'memo', case when v_min then 'Minimum tax' else 'Companies income tax' end),
      jsonb_build_object('code', '2208', 'credit', v_cit, 'memo', case when v_min then 'Minimum tax' else 'Companies income tax' end),
      jsonb_build_object('code', '7505', 'debit', v_topup, 'memo', 'Minimum effective tax top-up'),
      jsonb_build_object('code', '2208', 'credit', v_topup, 'memo', 'Minimum effective tax top-up'),
      jsonb_build_object('code', '7502', 'debit', v_levy, 'memo', 'Development levy'),
      jsonb_build_object('code', '2209', 'credit', v_levy, 'memo', 'Development levy'),
      jsonb_build_object('code', '7502', 'debit', v_tet, 'memo', 'Tertiary education tax'),
      jsonb_build_object('code', '2209', 'credit', v_tet, 'memo', 'Tertiary education tax'));
    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_jl from jsonb_array_elements(v_jl) x
      where coalesce((x->>'debit')::numeric, 0) <> 0 or coalesce((x->>'credit')::numeric, 0) <> 0;
    j := private.post_entry(p_org, 'Tax charge for ' || to_char(p_from, 'DD Mon YYYY') || ' to ' || to_char(p_to, 'DD Mon YYYY'), 'tax', null, m.id, m.id, v_jl,
      private.posting_time(p_org, p_to), jsonb_build_object('origin', 'manual', 'evidence', jsonb_build_array(jsonb_build_object('type', 'tax_computation', 'from', p_from, 'to', p_to,
        'year', c->'figures'->'year', 'regime', c->'figures'->>'regime', 'total_profit', c->'figures'->'total_profit', 'assessable', c->'figures'->'assessable'))));
  end if;
  insert into tax_settings (org_id, period_end, posted_journal_id, posted_from, posted_to, posted_cit, posted_levy, posted_at, posted_by, computed, updated_by)
  values (p_org, v_end, j.id, p_from, p_to, v_cit + v_topup, v_levy + v_tet, now(), m.id, c->'figures', m.id)
  on conflict (org_id, period_end) do update set posted_journal_id = excluded.posted_journal_id, posted_from = p_from, posted_to = p_to,
    posted_cit = excluded.posted_cit, posted_levy = excluded.posted_levy, posted_at = now(), posted_by = m.id, computed = excluded.computed;
  return public.tax_computation(p_org, p_from, p_to) || jsonb_build_object('journal_ref', j.ref);
end $$;

-- ===========================================================================
-- WITHHOLDING TAX AND VAT ENGINES (TaxStreem rule books, October 2026)
-- ===========================================================================
-- WHT: rates by transaction and by recipient (corporate or not, resident or not) as on the NRS schedule; deducted on the
-- amount before VAT when a bill is paid; doubled when the supplier has no Tax ID; remitted to the NRS (companies, and
-- anyone abroad) by the 21st, or to the state service of the supplier's state (enterprises, sole traders, partnerships)
-- by the 30th; compensation for loss of office at 5% of the excess over ₦50 million to the state of residence by the 10th.
-- VAT: withheld by agents and self-charged on services bought from abroad (2211, to the NRS by the 14th); VAT customers
-- withhold credited in the return (1405); input VAT carried forward up to five years, oldest first.

-- ---------------------------------------------------------------------------
-- Rates by transaction and recipient (null: not applicable, nothing withheld)
-- ---------------------------------------------------------------------------
alter table public.wht_rates add column if not exists nrs_code text;
alter table public.wht_rates add column if not exists rate_corp_res numeric(6,4);
alter table public.wht_rates add column if not exists rate_corp_nonres numeric(6,4);
alter table public.wht_rates add column if not exists rate_ind_res numeric(6,4);
alter table public.wht_rates add column if not exists rate_ind_nonres numeric(6,4);
alter table public.wht_rates add column if not exists exemption boolean not null default false;
alter table public.wht_rates add column if not exists rule text;

insert into public.wht_rates (code, name, rate_company, rate_individual, note, sort) values
  ('colocation', 'Co-location and telecommunication tower services', 0.02, 0.02, null, 16),
  ('compensation', 'Compensation for loss of employment or office', 0, 0.05, '5% of the amount above ₦50 million, to the state of residence', 23),
  ('winnings', 'Winnings from lottery, gaming and reality shows', 0, 0.05, null, 24),
  ('ex_securities_lending', 'Not subject: compensating payments under registered securities lending', 0, 0, null, 50),
  ('ex_reit', 'Not subject: dividends to a REIT or real estate investment company', 0, 0, null, 51),
  ('ex_over_counter', 'Not subject: across-the-counter purchase paid on the spot', 0, 0, null, 52),
  ('ex_bank_charges', 'Not subject: interest and fees a Nigerian bank debits directly', 0, 0, null, 53),
  ('ex_manufacturer', 'Not subject: goods made by the supplier itself', 0, 0, null, 54),
  ('ex_imported_goods', 'Not subject: imported goods from a supplier abroad', 0, 0, null, 55),
  ('ex_exempt_income', 'Not subject: income exempt from tax (NTA 2025 s.163)', 0, 0, null, 56),
  ('ex_telecom_airline', 'Not subject: telephone, internet data and airline tickets', 0, 0, null, 57),
  ('ex_reimbursable', 'Not subject: out-of-pocket costs reimbursed', 0, 0, null, 58),
  ('ex_insurance', 'Not subject: insurance premiums', 0, 0, null, 59),
  ('ex_petroleum', 'Not subject: LPG, CNG, PMS, AGO, LPFO, DPK and JET-A1', 0, 0, null, 60),
  ('ex_broker_retained', 'Not subject: commission a broker keeps from collections', 0, 0, null, 61),
  ('ex_qualifying_winnings', 'Not subject: winnings from shows promoting enterprise, learning or innovation', 0, 0, null, 62)
on conflict (code) do nothing;

update public.wht_rates r set nrs_code = x.nrs, rate_corp_res = x.cr, rate_corp_nonres = x.cn, rate_ind_res = x.ir, rate_ind_nonres = x.inr,
  rate_company = coalesce(x.cr, 0), rate_individual = coalesce(x.ir, 0), exemption = x.ex, rule = x.rule
from (values
  ('none', null, null, null, null, null, true, null),
  ('dividend', 'DIVIDENDS', 0.10, 0.10, 0.10, 0.10, false, null),
  ('interest', 'RENT_HIRE_OR_LEASE_AND_INTEREST', 0.10, 0.10, 0.10, 0.10, false, null),
  ('rent', 'RENT_HIRE_OR_LEASE_AND_INTEREST', 0.10, 0.10, 0.10, 0.10, false, null),
  ('royalty', 'ROYALTY', 0.10, 0.10, 0.05, 0.05, false, null),
  ('professional', 'COMMISSION_CONSULTANCY_TECHNICAL_MANAGEMENT_AND_PROFESSIONAL_FEES', 0.05, 0.10, 0.05, 0.10, false, null),
  ('commission', 'COMMISSION_CONSULTANCY_TECHNICAL_MANAGEMENT_AND_PROFESSIONAL_FEES', 0.05, 0.10, 0.05, 0.10, false, null),
  ('goods', 'SUPPLY_OF_GOODS_OR_MATERIALS_OTHER_THAN_BY_THE_MANUFACTURER_OR_PRODUCER', 0.02, null, 0.02, null, false, null),
  ('colocation', 'CO_LOCATION_AND_TELECOMMUNICATION_TOWER_SERVICES', 0.02, 0.05, 0.02, 0.05, false, null),
  ('services', 'SUPPLYING_OR_RENDERING_OF_SERVICES_OTHER_THAN_THOSE_SPECIFICALLY_LISTED_IN_THIS_SCHEDULE', 0.02, 0.05, 0.02, 0.05, false, null),
  ('construction_roads', 'CONSTRUCTION_ROADS_BRIDGES_BUILDING_AND_POWER_PLANTS', 0.02, 0.05, 0.02, 0.05, false, null),
  ('construction_other', 'ANY_OTHER_FORM_OF_CONSTRUCTION_AND_RELATED_ACTIVITIES', 0.05, 0.10, 0.05, 0.10, false, null),
  ('brokerage', 'BROKERAGE_FEE', 0.05, 0.10, 0.05, 0.10, false, null),
  ('directors_fees', 'DIRECTORS_FEES', null, null, 0.15, 0.20, false, null),
  ('compensation', 'COMPENSATION_FOR_LOSS_OF_EMPLOYMENT', null, null, 0.05, 0.05, false, 'excess_over_50m'),
  ('entertainment', 'ENTERTAINERS_AND_SPORT_PERSONS', null, 0.15, null, 0.15, false, null),
  ('winnings', 'WINNINGS_FROM_LOTTERY_GAMING_REALITY_SHOWS_ETC', null, null, 0.05, 0.15, false, null)
) as x(code, nrs, cr, cn, ir, inr, ex, rule)
where r.code = x.code;
update public.wht_rates set exemption = true, rate_company = 0, rate_individual = 0 where code like 'ex\_%';
update public.wht_rates set name = 'Rent, hire or lease', note = 'Rent of property and hire or lease of equipment' where code = 'rent';
update public.wht_rates set name = 'Entertainers and sports persons (from abroad)', note = 'Only on performers resident abroad' where code = 'entertainment';
update public.wht_rates set note = 'Individual directors only: 15%, or 20% when resident abroad' where code = 'directors_fees';

-- ---------------------------------------------------------------------------
-- Bills: WHT line by line, VAT withheld as an agent, VAT self-charged on services from abroad
-- ---------------------------------------------------------------------------
alter table public.bill_lines add column if not exists wht_category text references public.wht_rates(code);
alter table public.bill_lines add column if not exists wht_rate numeric(6,4) not null default 0;
alter table public.bill_lines add column if not exists wht numeric(16,2) not null default 0;
alter table public.bill_lines add column if not exists wht_base numeric(16,2) not null default 0;
alter table public.bill_lines add column if not exists reverse_charge_vat numeric(16,2) not null default 0;
create index if not exists bill_lines_wht_fk on public.bill_lines(wht_category);

alter table public.bills add column if not exists wvat_expected numeric(16,2) not null default 0;
alter table public.bills add column if not exists wvat_withheld numeric(16,2) not null default 0;
alter table public.bills add column if not exists reverse_charge_vat numeric(16,2) not null default 0;
alter table public.bills add column if not exists wht_note text;

alter table public.bill_payments add column if not exists wvat numeric(16,2) not null default 0 check (wvat >= 0);
do $$
declare c record;
begin
  for c in select conname from pg_constraint where conrelid = 'public.bill_payments'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) ~ 'gross = \(net \+ wht\)' loop
    execute format('alter table public.bill_payments drop constraint %I', c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conrelid = 'public.bill_payments'::regclass and conname = 'bill_payments_split') then
    alter table public.bill_payments add constraint bill_payments_split check (gross = net + wht + wvat);
  end if;
end $$;

-- Money from customers: VAT a customer who is a withholding VAT agent kept and pays to the NRS for us (Dr 1405).
do $$
declare c record;
begin
  for c in select conname from pg_constraint where conrelid = 'public.collections'::regclass and contype = 'c' and pg_get_constraintdef(oid) ~ 'wht_credit' loop
    execute format('alter table public.collections drop constraint %I', c.conname);
  end loop;
  alter table public.collections add constraint collections_method_check
    check (method in ('cash', 'transfer', 'card', 'pos', 'flutterwave', 'rail', 'cheque', 'wht_credit', 'wvat_credit', 'advance', 'other'));
end $$;

-- ---------------------------------------------------------------------------
-- What was withheld, for whom, and where it goes
-- ---------------------------------------------------------------------------
-- One row per payment and kind of deduction: WHT by transaction type, VAT withheld as an agent, VAT self-charged on a bill
-- from abroad. The NRS and state schedules, the receipts to suppliers and the remittances are built from these rows.
create table if not exists public.wht_deductions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  kind text not null check (kind in ('wht', 'wvat', 'reverse_charge')),
  bill_id uuid not null references public.bills(id) on delete cascade,
  bill_payment_id uuid references public.bill_payments(id) on delete cascade,
  vendor_id uuid not null references public.vendors(id),
  category text references public.wht_rates(code),
  nrs_code text,
  description text not null,
  recipient_type text check (recipient_type in ('CORPORATE', 'NON-CORPORATE')),
  resident boolean not null default true,
  beneficiary_type text check (beneficiary_type in ('TAX ID', 'RC', 'NIN')),
  beneficiary_number text,
  base numeric(16,2) not null default 0,
  rate numeric(6,4) not null default 0,
  doubled boolean not null default false,
  amount numeric(16,2) not null check (amount >= 0),
  authority text references public.tax_authorities(code),
  state_assumed boolean not null default false,
  deducted_on date not null,
  period date not null,
  due_date date not null,
  status text not null default 'deducted' check (status in ('pending', 'deducted', 'remitted', 'void')),
  remittance_id uuid,
  receipt_no text,
  created_at timestamptz not null default now()
);
create unique index if not exists wht_deductions_payment on public.wht_deductions(bill_payment_id, kind, coalesce(category, '')) where bill_payment_id is not null;
create unique index if not exists wht_deductions_reverse on public.wht_deductions(bill_id) where kind = 'reverse_charge';
create unique index if not exists wht_deductions_receipt on public.wht_deductions(org_id, receipt_no) where receipt_no is not null;
create index if not exists wht_deductions_org on public.wht_deductions(org_id, period, authority, status);
create index if not exists wht_deductions_bill_fk on public.wht_deductions(bill_id);
create index if not exists wht_deductions_vendor_fk on public.wht_deductions(vendor_id);
create index if not exists wht_deductions_category_fk on public.wht_deductions(category);
create index if not exists wht_deductions_authority_fk on public.wht_deductions(authority);
create index if not exists wht_deductions_remittance on public.wht_deductions(remittance_id);
alter table public.wht_deductions enable row level security;
drop policy if exists wht_deductions_read on public.wht_deductions;
create policy wht_deductions_read on public.wht_deductions for select to authenticated using ((select private.can_handle_money(org_id)));

-- Payments of what was withheld to the NRS or a state service.
create table if not exists public.wht_remittances (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  kind text not null check (kind in ('wht', 'wvat')),
  authority text not null references public.tax_authorities(code),
  period date not null,
  amount numeric(16,2) not null check (amount > 0),
  paid_at timestamptz not null,
  bank_account_id uuid references public.bank_accounts(id),
  reference text,
  receipt_path text,
  journal_id uuid references public.journals(id) on delete set null,
  status text not null default 'posted' check (status in ('posted', 'reversed')),
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists wht_remittances_org on public.wht_remittances(org_id, period);
create index if not exists wht_remittances_authority_fk on public.wht_remittances(authority);
create index if not exists wht_remittances_bank_fk on public.wht_remittances(bank_account_id);
create index if not exists wht_remittances_journal_fk on public.wht_remittances(journal_id);
create index if not exists wht_remittances_created_by_fk on public.wht_remittances(created_by);
alter table public.wht_remittances enable row level security;
drop policy if exists wht_remittances_read on public.wht_remittances;
create policy wht_remittances_read on public.wht_remittances for select to authenticated using ((select private.can_handle_money(org_id)));
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'wht_deductions_remittance_fk') then
    alter table public.wht_deductions add constraint wht_deductions_remittance_fk foreign key (remittance_id) references public.wht_remittances(id) on delete set null;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- VAT returns filed from Counta (a month's figures frozen, and the journal that settles 2201, 1402 and 1405 for it)
-- ---------------------------------------------------------------------------
create table if not exists public.vat_periods (
  org_id uuid not null references public.orgs(id) on delete cascade,
  period date not null check (extract(day from period) = 1),
  output_vat numeric(16,2) not null default 0,
  input_vat numeric(16,2) not null default 0,
  wvat_credit numeric(16,2) not null default 0,
  credit_bf numeric(16,2) not null default 0,
  credit_used numeric(16,2) not null default 0,
  credit_expired numeric(16,2) not null default 0,
  payable numeric(16,2) not null default 0,
  new_credit numeric(16,2) not null default 0,
  refund_claimed numeric(16,2) not null default 0,
  credit_cf numeric(16,2) not null default 0,
  layers jsonb not null default '[]'::jsonb,
  status text not null default 'filed' check (status in ('filed', 'paid')),
  filed_at timestamptz,
  filed_by uuid references public.members(id) on delete set null,
  journal_id uuid references public.journals(id) on delete set null,
  payment_journal_id uuid references public.journals(id) on delete set null,
  paid_at timestamptz,
  reference text,
  notes text,
  primary key (org_id, period)
);
create index if not exists vat_periods_filed_by_fk on public.vat_periods(filed_by);
create index if not exists vat_periods_journal_fk on public.vat_periods(journal_id);
create index if not exists vat_periods_payment_fk on public.vat_periods(payment_journal_id);
alter table public.vat_periods enable row level security;
drop policy if exists vat_periods_read on public.vat_periods;
create policy vat_periods_read on public.vat_periods for select to authenticated using ((select private.can_handle_money(org_id)));

-- ---------------------------------------------------------------------------
-- Who a supplier is for withholding tax
-- ---------------------------------------------------------------------------
-- corporate: Ltd, Plc, LLP, Ltd/Gte (and NGOs and government bodies, which are incorporated); not corporate: business names,
-- sole traders, partnerships, LPs and individuals. The NRS schedule names the supplier by Tax ID, RC number or NIN; anything
-- other than a Tax ID doubles the rate. state: the supplier's state service (from its state, else its address), else the
-- business's own state, marked as assumed.
create or replace function private.vendor_wht_profile(p_vendor uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object(
    'corporate', c.corporate, 'resident', coalesce(v.resident, true),
    'recipient_type', case when c.corporate then 'CORPORATE' else 'NON-CORPORATE' end,
    'beneficiary_type', case when nullif(trim(v.tin), '') is not null then 'TAX ID' when nullif(trim(v.rc_number), '') is not null then 'RC'
                             when nullif(trim(v.nin), '') is not null then 'NIN' end,
    'beneficiary_number', coalesce(nullif(trim(v.tin), ''), nullif(trim(v.rc_number), ''), nullif(trim(v.nin), '')),
    'has_tin', nullif(trim(v.tin), '') is not null,
    'exempt', coalesce(v.wht_exempt, false) or v.entity_type = 'government',
    'state', coalesce(st.own, st.org), 'state_assumed', st.own is null and st.org is not null)
  from vendors v
  cross join lateral (select case when v.entity_type in ('company', 'plc', 'llp', 'ltd_gte', 'ngo', 'government') then true
                                  when v.entity_type in ('business_name', 'sole_proprietor', 'partnership', 'lp', 'individual') then false
                                  else not coalesce(v.is_individual, false) end corporate) c
  cross join lateral (select coalesce(private.state_code(v.state), private.state_code(v.address), private.state_code(v.location)) own,
                             (select private.state_code(coalesce(o.registered_office, o.address)) from orgs o where o.id = v.org_id) org) st
  where v.id = p_vendor
$$;

-- The rate on the NRS table for a transaction and a recipient (null: not applicable to that recipient).
create or replace function private.wht_matrix_rate(p_category text, p_corporate boolean, p_resident boolean) returns numeric
language sql stable security definer set search_path = public, private as $$
  select case when r.exemption then 0 when p_corporate then case when p_resident then r.rate_corp_res else r.rate_corp_nonres end
              else case when p_resident then r.rate_ind_res else r.rate_ind_nonres end end
  from wht_rates r where r.code = p_category
$$;

-- The rate to withhold from a supplier for a kind of transaction: the NRS table, doubled with no limit when the supplier has
-- no Tax ID (as the NRS schedule computes it).
create or replace function private.wht_rate(p_vendor uuid, p_category text) returns numeric
language plpgsql stable security definer set search_path = public, private as $$
declare pf jsonb := private.vendor_wht_profile(p_vendor); v_cat text; v_rate numeric;
begin
  v_cat := coalesce(nullif(p_category, ''), (select wht_category from vendors where id = p_vendor), 'none');
  if pf is null or v_cat = 'none' or coalesce((pf->>'exempt')::boolean, false) then return 0; end if;
  if v_cat = 'compensation' then return 0.05; end if;
  v_rate := coalesce(private.wht_matrix_rate(v_cat, (pf->>'corporate')::boolean, (pf->>'resident')::boolean), 0);
  return case when (pf->>'has_tin')::boolean then v_rate else v_rate * 2 end;
end $$;

-- When a deduction is due: NRS by the 21st of the next month, a state service by the 30th (the last day of February),
-- compensation for loss of office by the 10th, withholding VAT by the 14th.
create or replace function private.wht_due(p_kind text, p_authority text, p_category text, p_day date) returns date
language sql immutable set search_path = public, private as $$
  select case when p_kind in ('wvat', 'reverse_charge') then n + 13
              when p_category = 'compensation' then n + 9
              when coalesce(p_authority, 'NRS') = 'NRS' then n + 20
              else least(n + 29, (n + interval '1 month' - interval '1 day')::date) end
  from (select (date_trunc('month', p_day) + interval '1 month')::date n) x
$$;

-- ---------------------------------------------------------------------------
-- A bill's withholding: WHT line by line, VAT withheld as an agent, VAT self-charged on services from abroad
-- ---------------------------------------------------------------------------
create or replace function private.bill_wht(p_bill uuid) returns public.bills
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; o public.orgs; v public.vendors; pf jsonb; l record; v_cat text; r public.wht_rates; v_rate numeric; v_base numeric; v_wht numeric;
  v_small boolean := false; v_notes text[] := '{}'; v_rc numeric; v_month numeric; v_note text; v_doubled boolean := false;
begin
  select * into b from bills where id = p_bill for update;
  select * into o from orgs where id = b.org_id;
  select * into v from vendors where id = b.vendor_id;
  pf := private.vendor_wht_profile(v.id);
  -- A small business need not withhold from a supplier with a Tax ID while the month's purchases from them stay within ₦2 million.
  if o.wht_small_company and (pf->>'has_tin')::boolean then
    select coalesce(sum(subtotal), 0) into v_month from bills where org_id = b.org_id and vendor_id = b.vendor_id and status <> 'void'
      and date_trunc('month', bill_date) = date_trunc('month', b.bill_date);
    v_small := v_month <= 2000000;
  end if;
  for l in select * from bill_lines where bill_id = b.id order by line_no loop
    v_cat := coalesce(l.wht_category, b.wht_category, v.wht_category, 'none');
    select * into r from wht_rates where code = v_cat;
    v_rate := 0; v_base := l.net; v_note := null;
    if r.code is null or r.exemption then
      v_note := case when r.code is not null and r.code <> 'none' then r.name end;
    elsif (pf->>'exempt')::boolean then
      v_note := 'Supplier exempt from withholding tax';
    elsif v_cat = 'goods' and v.is_manufacturer then
      v_note := 'Goods made by the supplier itself are not subject to WHT';
    elsif v_cat = 'compensation' then
      v_base := greatest(l.net - 50000000, 0); v_rate := 0.05;
      v_note := '5% of the amount above ₦50 million';
    else
      v_rate := private.wht_matrix_rate(v_cat, (pf->>'corporate')::boolean, (pf->>'resident')::boolean);
      if v_rate is null then
        v_rate := 0; v_note := r.name || ': not withheld from ' || case when (pf->>'corporate')::boolean then 'a company' else 'this supplier' end
          || case when not (pf->>'resident')::boolean then ' abroad' else '' end;
      elsif not (pf->>'has_tin')::boolean and v_rate > 0 then
        v_rate := v_rate * 2; v_doubled := true;
      end if;
    end if;
    if v_small and v_rate > 0 and v_cat <> 'compensation' then v_rate := 0; v_note := 'Within the ₦2 million monthly limit for a small business'; end if;
    v_wht := round(v_base * v_rate, 2);
    -- VAT self-charged on services bought from a supplier abroad (goods pay VAT at the port).
    v_rc := case when not (pf->>'resident')::boolean and not v.digital_supplier and l.vat = 0 and l.vat_treatment not in ('exempt', 'zero')
                   and l.account_code !~ '^(12|15)' then round(l.net * 0.075, 2) else 0 end;
    update bill_lines set wht_category = coalesce(wht_category, case when v_cat <> coalesce(b.wht_category, 'none') then v_cat end),
      wht_rate = v_rate, wht = v_wht, wht_base = case when v_wht > 0 then v_base else 0 end, reverse_charge_vat = v_rc
    where id = l.id;
    if v_note is not null and not v_note = any(v_notes) then v_notes := v_notes || v_note; end if;
  end loop;
  if v_doubled then v_notes := array['No Tax ID: the rate is doubled'] || v_notes; end if;
  update bills set
    wht_expected = (select coalesce(sum(wht), 0) from bill_lines where bill_id = b.id),
    wht_rate = case when subtotal > 0 then least(round((select coalesce(sum(wht), 0) from bill_lines where bill_id = b.id) / subtotal, 4), 0.99) else 0 end,
    wvat_expected = case when o.wvat_agent is not null and (pf->>'resident')::boolean then vat_total else 0 end,
    reverse_charge_vat = (select coalesce(sum(reverse_charge_vat), 0) from bill_lines where bill_id = b.id),
    wht_note = nullif(array_to_string(v_notes, '. '), '')
  where id = b.id returning * into b;
  return b;
end $$;

-- What a payment of p_gross keeps back: WHT and withholding VAT in proportion to what it settles, the rest when it settles
-- the bill.
create or replace function private.bill_withholding(p_bill uuid, p_gross numeric) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare b public.bills; v_due numeric; v_wl numeric; v_vl numeric; v_full boolean;
begin
  select * into b from bills where id = p_bill;
  v_due := b.total - b.amount_paid - coalesce((select sum(gross) from bill_payments where bill_id = b.id and status = 'processing'), 0);
  select greatest(b.wht_expected - coalesce(sum(wht), 0), 0), greatest(b.wvat_expected - coalesce(sum(wvat), 0), 0) into v_wl, v_vl
    from bill_payments where bill_id = b.id and status in ('paid', 'processing');
  v_full := p_gross >= v_due - 0.004;
  return jsonb_build_object('due', v_due, 'wht_left', v_wl, 'wvat_left', v_vl, 'full', v_full,
    'wht', case when v_full then v_wl else least(round(b.wht_expected * p_gross / nullif(b.total, 0), 2), v_wl) end,
    'wvat', case when v_full then v_vl else least(round(b.wvat_expected * p_gross / nullif(b.total, 0), 2), v_vl) end,
    'rate', coalesce((b.wht_expected + b.wvat_expected) / nullif(b.total, 0), 0));
end $$;

-- ---------------------------------------------------------------------------
-- Bills: written, posted, paid
-- ---------------------------------------------------------------------------
create or replace function private.write_bill(p_org uuid, p jsonb, m public.members) returns public.bills
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; v public.vendors; o public.orgs; x jsonb; v_no int := 0; v_qty numeric; v_cost numeric; v_base numeric; v_net numeric; v_vat numeric;
  v_treat text; v_rate numeric; v_id uuid := nullif(p->>'id', '')::uuid; v_vendor uuid := nullif(p->>'vendor_id', '')::uuid; v_day date; v_code text;
  v_wht_cat text; v_recov boolean; v_line_cat text;
begin
  select * into o from orgs where id = p_org;
  if nullif(p->>'client_uuid', '') is not null and v_id is null then
    select * into b from bills where client_uuid = (p->>'client_uuid')::uuid;
    if found then return b; end if;
  end if;
  if v_vendor is null and coalesce(trim(p->'vendor'->>'name'), '') <> '' then
    select id into v_vendor from vendors where org_id = p_org and (lower(name) = lower(trim(p->'vendor'->>'name'))
      or (nullif(trim(p->'vendor'->>'tin'), '') is not null and tin = trim(p->'vendor'->>'tin'))) limit 1;
    if v_vendor is null then
      insert into vendors (org_id, name, tin, is_individual, wht_category, bank_code, bank_name, account_number, account_name, vat_registered, channel, phone, email,
        entity_type, resident, state, address, rc_number, nin, country)
      values (p_org, left(trim(p->'vendor'->>'name'), 120), nullif(trim(p->'vendor'->>'tin'), ''), coalesce((p->'vendor'->>'is_individual')::boolean, false),
        nullif(p->'vendor'->>'wht_category', ''), nullif(p->'vendor'->>'bank_code', ''), nullif(p->'vendor'->>'bank_name', ''),
        nullif(p->'vendor'->>'account_number', ''), nullif(p->'vendor'->>'account_name', ''), coalesce((p->>'vat_charged')::boolean, true), 'email',
        nullif(p->'vendor'->>'phone', ''), nullif(p->'vendor'->>'email', ''),
        coalesce(nullif(p->'vendor'->>'entity_type', ''), case when coalesce((p->'vendor'->>'is_individual')::boolean, false) then 'individual' end),
        coalesce((p->'vendor'->>'resident')::boolean, true), nullif(trim(p->'vendor'->>'state'), ''), nullif(trim(p->'vendor'->>'address'), ''),
        nullif(trim(p->'vendor'->>'rc_number'), ''), nullif(trim(p->'vendor'->>'nin'), ''), coalesce(nullif(p->'vendor'->>'country', ''), 'NG'))
      returning id into v_vendor;
    end if;
  end if;
  select * into v from vendors where id = v_vendor and org_id = p_org;
  if not found then raise exception 'Choose the vendor.'; end if;
  v_day := coalesce(nullif(p->>'bill_date', '')::date, private.local_day(p_org, now()));
  if v_day > private.local_day(p_org, now()) + 1 then raise exception 'A bill cannot be dated in the future.'; end if;
  v_wht_cat := coalesce(nullif(p->>'wht_category', ''), v.wht_category, 'none');
  if not exists (select 1 from wht_rates where code = v_wht_cat) then raise exception 'Unknown withholding tax category.'; end if;
  if v_id is null then
    insert into bills (org_id, number, vendor_id, vendor_ref, source, external_ref, bill_date, due_date, prices_include_vat, vat_charged, wht_category,
      notes, document_path, created_by, client_uuid)
    values (p_org, 'BILL-' || lpad(private.next_no(p_org, 'BILL', 1)::text, 4, '0'), v.id, nullif(trim(p->>'vendor_ref'), ''),
      coalesce(nullif(p->>'source', ''), 'manual'), nullif(p->>'external_ref', ''), v_day,
      coalesce(nullif(p->>'due_date', '')::date, v_day + coalesce(nullif(v.credit_days, 0), 30)), coalesce((p->>'prices_include_vat')::boolean, false),
      coalesce((p->>'vat_charged')::boolean, coalesce(v.vat_registered, true) and coalesce(v.resident, true)), v_wht_cat, nullif(trim(p->>'notes'), ''),
      nullif(p->>'document_path', ''), m.id, nullif(p->>'client_uuid', '')::uuid)
    returning * into b;
  else
    select * into b from bills where id = v_id and org_id = p_org for update;
    if not found then raise exception 'Bill not found.'; end if;
    if b.status <> 'draft' then raise exception '% is already approved. Void it and enter it again.', b.number; end if;
    update bills set vendor_id = v.id, vendor_ref = case when p ? 'vendor_ref' then nullif(trim(p->>'vendor_ref'), '') else vendor_ref end, bill_date = v_day,
      due_date = coalesce(nullif(p->>'due_date', '')::date, v_day + coalesce(nullif(v.credit_days, 0), 30)),
      prices_include_vat = coalesce((p->>'prices_include_vat')::boolean, prices_include_vat), vat_charged = coalesce((p->>'vat_charged')::boolean, vat_charged),
      wht_category = v_wht_cat, notes = case when p ? 'notes' then nullif(trim(p->>'notes'), '') else notes end,
      document_path = coalesce(nullif(p->>'document_path', ''), document_path)
    where id = b.id returning * into b;
  end if;
  if b.due_date < b.bill_date then raise exception 'The due date is before the bill date.'; end if;
  if p ? 'lines' then
    delete from bill_lines where bill_id = b.id;
    if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then raise exception 'Add at least one line.'; end if;
    for x in select * from jsonb_array_elements(p->'lines') loop
      v_no := v_no + 1;
      v_code := nullif(trim(x->>'account_code'), '');
      if v_code is null or not private.bill_account_ok(p_org, v_code) then
        raise exception 'Line %: choose an expense, stock or asset account.', v_no;
      end if;
      v_qty := coalesce(round(private.num(x->>'qty'), 3), 1);
      v_cost := round(private.num(x->>'unit_cost'), 2);
      if v_qty <= 0 or v_cost is null or v_cost < 0 then raise exception 'Line %: enter the quantity and cost.', v_no; end if;
      v_treat := case when not b.vat_charged then 'none' else coalesce(nullif(x->>'vat_treatment', ''), 'standard') end;
      if v_treat not in ('standard', 'zero', 'exempt', 'none') then raise exception 'Line %: unknown VAT treatment.', v_no; end if;
      v_line_cat := nullif(x->>'wht_category', '');
      if v_line_cat is not null and not exists (select 1 from wht_rates where code = v_line_cat) then raise exception 'Line %: unknown withholding tax category.', v_no; end if;
      v_rate := case when v_treat = 'standard' then 0.075 else 0 end;
      v_base := round(v_qty * v_cost, 2);
      if b.prices_include_vat then v_net := round(v_base / (1 + v_rate), 2); v_vat := v_base - v_net;
      else v_net := v_base; v_vat := round(v_net * v_rate, 2); end if;
      -- Input VAT is recoverable when the business is VAT-registered (NTA 2025 s.156), unless marked otherwise.
      v_recov := o.vat_registered and coalesce((x->>'vat_recoverable')::boolean, true);
      insert into bill_lines (bill_id, org_id, line_no, description, account_code, qty, unit_cost, vat_treatment, vat_recoverable, net, vat, gross,
        asset_life_months, location_id, ai_confidence, wht_category)
      values (b.id, p_org, v_no, left(coalesce(nullif(trim(x->>'description'), ''), 'Line ' || v_no), 300), v_code, v_qty, v_cost, v_treat, v_recov,
        v_net, v_vat, v_net + v_vat, nullif(x->>'asset_life_months', '')::int,
        (select id from locations where id = nullif(x->>'location_id', '')::uuid and org_id = p_org), nullif(x->>'ai_confidence', '')::numeric,
        case when v_line_cat is distinct from v_wht_cat then v_line_cat end);
    end loop;
  end if;
  update bills set subtotal = (select coalesce(sum(net), 0) from bill_lines where bill_id = b.id),
    vat_total = (select coalesce(sum(vat), 0) from bill_lines where bill_id = b.id),
    total = (select coalesce(sum(gross), 0) from bill_lines where bill_id = b.id)
  where id = b.id;
  return private.bill_wht(b.id);
end $$;

-- Bill approved: Dr expense / asset per line (+ VAT that cannot be recovered), Dr 1402 input VAT, Cr 2101 vendor. VAT
-- self-charged on services from abroad: Dr 1402 (or the cost when the business cannot recover VAT) / Cr 2211.
create or replace function private.post_bill(p_bill uuid, m public.members) returns public.bills
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; l public.bill_lines; v_jl jsonb := '[]'::jsonb; j public.journals; v_vat numeric := 0; v_vendor text; v_at timestamptz; v_rc_base numeric := 0;
begin
  select * into b from bills where id = p_bill for update;
  if b.journal_id is not null then return b; end if;
  select name into v_vendor from vendors where id = b.vendor_id;
  for l in select * from bill_lines where bill_id = b.id order by line_no loop
    v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', l.account_code, 'debit', l.net + case when l.vat_recoverable then 0 else l.vat end,
      'location_id', l.location_id, 'memo', l.description, 'doc_type', 'bill', 'doc_id', b.id));
    if l.vat_recoverable then v_vat := v_vat + l.vat; end if;
    if l.reverse_charge_vat > 0 then
      v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', case when l.vat_recoverable then private.acct(b.org_id, 'input_vat') else l.account_code end,
        'debit', l.reverse_charge_vat, 'location_id', l.location_id, 'memo', 'VAT self-charged · ' || l.description, 'doc_type', 'bill', 'doc_id', b.id));
      v_rc_base := v_rc_base + l.net;
    end if;
  end loop;
  v_jl := v_jl || jsonb_build_array(
    jsonb_build_object('code', private.acct(b.org_id, 'input_vat'), 'debit', v_vat, 'memo', 'Input VAT · ' || v_vendor, 'doc_type', 'bill', 'doc_id', b.id),
    jsonb_build_object('code', private.acct(b.org_id, 'payables'), 'credit', b.total, 'party_type', 'vendor', 'party_id', b.vendor_id, 'doc_type', 'bill', 'doc_id', b.id,
      'memo', b.number || coalesce(' · ' || b.vendor_ref, '')),
    jsonb_build_object('code', private.acct(b.org_id, 'wvat_payable'), 'credit', b.reverse_charge_vat, 'party_type', 'vendor', 'party_id', b.vendor_id,
      'doc_type', 'bill', 'doc_id', b.id, 'memo', 'VAT self-charged on services from abroad · ' || b.number));
  v_at := private.posting_time(b.org_id, b.bill_date);
  j := private.post_entry(b.org_id, 'Bill ' || b.number || ' · ' || v_vendor || coalesce(' · ' || b.vendor_ref, ''), 'bill', b.id, b.created_by, m.id, v_jl, v_at,
    jsonb_build_object('origin', case when b.source = 'ai' then 'ai' else 'system' end, 'ai_confidence', b.ai_confidence,
      'evidence', jsonb_build_array(jsonb_build_object('type', 'bill', 'id', b.id, 'ref', coalesce(b.vendor_ref, b.number), 'document', b.document_path))));
  update bills set journal_id = j.id, status = 'approved', approved_by = m.id, approved_at = now() where id = b.id returning * into b;
  if b.reverse_charge_vat > 0 then
    insert into wht_deductions (org_id, kind, bill_id, vendor_id, description, recipient_type, resident, beneficiary_type, beneficiary_number, base, rate, amount,
      authority, deducted_on, period, due_date, status, receipt_no)
    select b.org_id, 'reverse_charge', b.id, b.vendor_id, left(b.number || coalesce(' / ' || b.vendor_ref, '') || ': VAT self-charged on services from abroad', 300),
      pf->>'recipient_type', false, pf->>'beneficiary_type', pf->>'beneficiary_number', v_rc_base, 0.075, b.reverse_charge_vat, 'NRS', b.bill_date,
      date_trunc('month', b.bill_date)::date, private.wht_due('reverse_charge', 'NRS', null, b.bill_date), 'deducted', null
    from (select private.vendor_wht_profile(b.vendor_id) pf) x
    on conflict do nothing;
  end if;
  -- Capital lines become register records waiting for someone to confirm the class, date in use and life (FA-02).
  insert into fixed_assets (org_id, number, name, class_account, cost, life_months, available_date, status, location_id, bill_id, bill_line_id, journal_id, created_by)
  select b.org_id, 'FA-' || lpad(private.next_no(b.org_id, 'FA', 1)::text, 4, '0'), bl.description, bl.account_code,
    bl.net + case when bl.vat_recoverable then 0 else bl.vat end, coalesce(bl.asset_life_months, ac.default_life_months), b.bill_date, 'pending_confirmation',
    bl.location_id, b.id, bl.id, j.id, m.id
  from bill_lines bl join asset_classes ac on ac.cost_account = bl.account_code where bl.bill_id = b.id order by bl.line_no;
  return b;
end $$;

create or replace function private.refresh_bill(p_bill uuid) returns public.bills
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; v_paid numeric; v_wht numeric; v_wvat numeric;
begin
  select * into b from bills where id = p_bill for update;
  if b.status in ('draft', 'void') then return b; end if;
  select coalesce(sum(gross), 0), coalesce(sum(wht), 0), coalesce(sum(wvat), 0) into v_paid, v_wht, v_wvat from bill_payments where bill_id = b.id and status = 'paid';
  update bills set amount_paid = v_paid, wht_withheld = v_wht, wvat_withheld = v_wvat,
    status = case when v_paid >= total - 0.004 then 'paid' when v_paid > 0 then 'partially_paid' else 'approved' end
  where id = b.id returning * into b;
  return b;
end $$;

-- Paying a bill. p: {method: wallet|bank|cash, amount (gross settled), wht, wvat (to override what is kept back), bank_account_id, paid_at, reference, ...}
create or replace function public.pay_bill(p_bill uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; m public.members; v public.vendors; v_gross numeric; v_wht numeric; v_wvat numeric; v_net numeric; v_due numeric;
  v_method text := coalesce(nullif(p->>'method', ''), 'wallet'); ba public.bank_accounts; j public.journals; po public.payouts; bp public.bill_payments;
  v_at timestamptz; v_split jsonb; v_jl jsonb;
begin
  select * into b from bills where id = p_bill for update;
  if not found then raise exception 'Bill not found.'; end if;
  m := private.require(b.org_id, 'make_payments');
  if b.status not in ('approved', 'partially_paid') then raise exception '% is %.', b.number, b.status; end if;
  select * into v from vendors where id = b.vendor_id;
  v_due := b.total - b.amount_paid - coalesce((select sum(gross) from bill_payments where bill_id = b.id and status = 'processing'), 0);
  v_gross := round(coalesce(private.num(p->>'amount'), v_due), 2);
  if v_gross <= 0 or v_gross > v_due + 0.004 then raise exception 'Up to % is still owed on %.', to_char(v_due, 'FM999,999,999,990.00'), b.number; end if;
  -- WHT and withholding VAT are kept back in proportion to what this payment settles, so part payments add up to the bill's.
  v_split := private.bill_withholding(b.id, v_gross);
  v_wht := greatest(round(coalesce(private.num(p->>'wht'), (v_split->>'wht')::numeric), 2), 0);
  v_wvat := greatest(round(coalesce(private.num(p->>'wvat'), (v_split->>'wvat')::numeric), 2), 0);
  if v_wht + v_wvat >= v_gross then raise exception 'What is withheld cannot be the whole payment.'; end if;
  v_net := v_gross - v_wht - v_wvat;
  v_at := least(coalesce(nullif(p->>'paid_at', '')::timestamptz, now()), now());
  v_jl := jsonb_build_array(
    jsonb_build_object('code', private.acct(b.org_id, 'payables'), 'debit', v_gross, 'party_type', 'vendor', 'party_id', v.id, 'doc_type', 'bill', 'doc_id', b.id, 'memo', b.number),
    jsonb_build_object('code', private.acct(b.org_id, 'wht_payable'), 'credit', v_wht, 'party_type', 'vendor', 'party_id', v.id, 'doc_type', 'bill', 'doc_id', b.id,
      'memo', 'WHT ' || trim(to_char(b.wht_rate * 100, 'FM990.##')) || '% on ' || b.number),
    jsonb_build_object('code', private.acct(b.org_id, 'wvat_payable'), 'credit', v_wvat, 'party_type', 'vendor', 'party_id', v.id, 'doc_type', 'bill', 'doc_id', b.id,
      'memo', 'VAT withheld on ' || b.number));
  if v_method = 'wallet' then
    po := private.create_payout(b.org_id, jsonb_build_object('purpose', 'vendor', 'vendor_id', v.id, 'amount', v_net,
      'bank_code', coalesce(nullif(p->>'bank_code', ''), v.bank_code), 'bank_name', coalesce(nullif(p->>'bank_name', ''), v.bank_name),
      'account_number', coalesce(nullif(p->>'account_number', ''), v.account_number), 'account_name', coalesce(nullif(p->>'account_name', ''), v.account_name),
      'narration', left(coalesce(nullif(trim(p->>'narration'), ''), b.number || coalesce(' ' || b.vendor_ref, '')), 80), 'client_uuid', p->>'client_uuid'), v_jl, m);
    -- Keep the vendor's account details for next time.
    update vendors set bank_code = coalesce(bank_code, po.bank_code), bank_name = coalesce(bank_name, po.bank_name),
      account_number = coalesce(account_number, po.account_number), account_name = coalesce(account_name, po.account_name) where id = v.id;
    insert into bill_payments (org_id, bill_id, method, status, gross, wht, wvat, net, payout_id, paid_at, reference, created_by)
    values (b.org_id, b.id, 'wallet', 'processing', v_gross, v_wht, v_wvat, v_net, po.id, v_at, po.reference, m.id) returning * into bp;
    return jsonb_build_object('bill', private.bill_json(b.id), 'payout', to_jsonb(po) - 'lines' - 'raw');
  end if;
  if v_method not in ('bank', 'cash') then raise exception 'Pay from the wallet, a bank account or cash.'; end if;
  select * into ba from bank_accounts where id = nullif(p->>'bank_account_id', '')::uuid and org_id = b.org_id and active and kind = case when v_method = 'cash' then 'cash' else 'bank' end;
  if not found then raise exception 'Choose the account it was paid from.'; end if;
  perform private.require_open_day(b.org_id, private.local_day(b.org_id, v_at));
  j := private.post_entry(b.org_id, 'Paid ' || v.name || ' · ' || b.number, 'bill_payment', b.id, m.id, m.id,
    v_jl || jsonb_build_array(jsonb_build_object('code', ba.ledger_code, 'credit', v_net, 'memo', b.number || ' · ' || v.name || coalesce(' · ' || nullif(trim(p->>'reference'), ''), ''))),
    v_at, jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'payment', 'ref', nullif(trim(p->>'reference'), ''), 'by', m.display_name))));
  insert into bill_payments (org_id, bill_id, method, status, gross, wht, wvat, net, bank_account_id, paid_at, reference, journal_id, created_by)
  values (b.org_id, b.id, v_method, 'paid', v_gross, v_wht, v_wvat, v_net, ba.id, v_at, nullif(trim(p->>'reference'), ''), j.id, m.id);
  b := private.refresh_bill(b.id);
  return jsonb_build_object('bill', private.bill_json(b.id));
end $$;

-- A bank line settling a bill: p_wht is everything kept back (gross less what left the bank); it is split between WHT and
-- withholding VAT in proportion to what is still to be withheld of each.
create or replace function private.record_bill_payment(p_bill uuid, p_bank uuid, p_gross numeric, p_wht numeric, p_at timestamptz, p_reference text,
  m public.members, p_method text default 'bank') returns public.journals
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; v public.vendors; ba public.bank_accounts; j public.journals; v_split jsonb; v_wl numeric; v_vl numeric; v_wvat numeric := 0; v_wht numeric;
begin
  select * into b from bills where id = p_bill for update;
  select * into v from vendors where id = b.vendor_id;
  select * into ba from bank_accounts where id = p_bank;
  v_split := private.bill_withholding(b.id, p_gross);
  v_wl := (v_split->>'wht_left')::numeric; v_vl := (v_split->>'wvat_left')::numeric;
  if coalesce(p_wht, 0) > 0 and v_vl > 0 then v_wvat := least(round(p_wht * v_vl / (v_wl + v_vl), 2), v_vl); end if;
  v_wht := coalesce(p_wht, 0) - v_wvat;
  j := private.post_entry(b.org_id, 'Paid ' || v.name || ' · ' || b.number, 'bill_payment', b.id, m.id, m.id, jsonb_build_array(
      jsonb_build_object('code', private.acct(b.org_id, 'payables'), 'debit', p_gross, 'party_type', 'vendor', 'party_id', v.id, 'doc_type', 'bill', 'doc_id', b.id, 'memo', b.number),
      jsonb_build_object('code', ba.ledger_code, 'credit', p_gross - v_wht - v_wvat, 'memo', b.number || ' · ' || v.name || coalesce(' · ' || nullif(trim(p_reference), ''), '')),
      jsonb_build_object('code', private.acct(b.org_id, 'wht_payable'), 'credit', v_wht, 'party_type', 'vendor', 'party_id', v.id, 'doc_type', 'bill', 'doc_id', b.id,
        'memo', 'WHT ' || trim(to_char(b.wht_rate * 100, 'FM990.##')) || '% on ' || b.number),
      jsonb_build_object('code', private.acct(b.org_id, 'wvat_payable'), 'credit', v_wvat, 'party_type', 'vendor', 'party_id', v.id, 'doc_type', 'bill', 'doc_id', b.id,
        'memo', 'VAT withheld on ' || b.number)), p_at,
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'payment', 'ref', nullif(trim(p_reference), ''), 'by', m.display_name))));
  insert into bill_payments (org_id, bill_id, method, status, gross, wht, wvat, net, bank_account_id, paid_at, reference, journal_id, created_by)
  values (b.org_id, b.id, p_method, 'paid', p_gross, v_wht, v_wvat, p_gross - v_wht - v_wvat, ba.id, p_at, nullif(trim(p_reference), ''), j.id, m.id);
  perform private.refresh_bill(b.id);
  return j;
end $$;

-- Uses part of a supplier credit against one of their bills (no journal: both sit in payables). The WHT and withholding VAT
-- still to come fall with the value the credit takes off the bill.
create or replace function private.use_vendor_credit(p_credit uuid, p_bill uuid, p_amount numeric, m public.members) returns numeric
language plpgsql security definer set search_path = public, private as $$
declare vc public.vendor_credits; b public.bills; v_due numeric; v_take numeric; v_net_off numeric; v_withheld numeric; v_vat_off numeric; v_vwithheld numeric;
begin
  select * into vc from vendor_credits where id = p_credit for update;
  select * into b from bills where id = p_bill for update;
  if b.vendor_id <> vc.vendor_id then raise exception '% is not from the same supplier.', b.number; end if;
  if b.status not in ('approved', 'partially_paid') then return 0; end if;
  v_due := b.total - b.amount_paid - coalesce((select sum(gross) from bill_payments where bill_id = b.id and status = 'processing'), 0);
  v_take := least(greatest(v_due, 0), vc.total - vc.applied - vc.refunded, coalesce(p_amount, vc.total));
  if v_take <= 0 then return 0; end if;
  insert into bill_payments (org_id, bill_id, method, status, gross, wht, net, paid_at, reference, journal_id, created_by, vendor_credit_id)
  values (b.org_id, b.id, 'credit_note', 'paid', v_take, 0, v_take, now(), vc.number || coalesce(' · ' || vc.vendor_ref, ''), vc.journal_id, m.id, vc.id);
  if b.total > 0 then
    select coalesce(sum(wht), 0), coalesce(sum(wvat), 0) into v_withheld, v_vwithheld from bill_payments where bill_id = b.id and status in ('paid', 'processing');
    if b.wht_expected > 0 then
      v_net_off := round(v_take * b.subtotal / b.total, 2);
      update bills set wht_expected = greatest(round(wht_expected - v_net_off * wht_rate, 2), v_withheld, 0) where id = b.id;
    end if;
    if b.wvat_expected > 0 then
      v_vat_off := round(v_take * b.vat_total / b.total, 2);
      update bills set wvat_expected = greatest(round(wvat_expected - v_vat_off, 2), v_vwithheld, 0) where id = b.id;
    end if;
  end if;
  update vendor_credits set applied = applied + v_take, status = case when applied + v_take + refunded >= total - 0.004 then 'used' else 'open' end where id = vc.id;
  perform private.refresh_bill(b.id);
  return v_take;
end $$;

-- ---------------------------------------------------------------------------
-- Deductions: one row per payment and kind, kept in step with the payment
-- ---------------------------------------------------------------------------
create or replace function private.sync_wht_deductions() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare b public.bills; v public.vendors; pf jsonb; v_day date; v_status text; x record; v_tot numeric; v_left numeric; v_left_base numeric; v_n int; v_i int := 0;
  v_amt numeric; v_base numeric; v_auth text; v_desc text; v_assumed boolean;
begin
  if new.status in ('failed', 'reversed') then
    update wht_deductions set status = 'void' where bill_payment_id = new.id and status in ('pending', 'deducted');
    return new;
  end if;
  v_status := case when new.status = 'paid' then 'deducted' else 'pending' end;
  v_day := private.local_day(new.org_id, new.paid_at);
  if exists (select 1 from wht_deductions where bill_payment_id = new.id) then
    update wht_deductions set status = v_status, deducted_on = v_day, period = date_trunc('month', v_day)::date,
      due_date = private.wht_due(kind, authority, category, v_day)
    where bill_payment_id = new.id and status in ('pending', 'deducted');
    return new;
  end if;
  if coalesce(new.wht, 0) = 0 and coalesce(new.wvat, 0) = 0 then return new; end if;
  select * into b from bills where id = new.bill_id;
  select * into v from vendors where id = b.vendor_id;
  pf := private.vendor_wht_profile(v.id);
  v_desc := b.number || coalesce(' / ' || b.vendor_ref, '');
  if new.wht > 0 then
    select coalesce(sum(wht), 0) into v_tot from bill_lines where bill_id = b.id;
    if v_tot = 0 then
      -- Withheld although the bill expected none: on the bill's own category.
      v_base := round(new.gross * b.subtotal / nullif(b.total, 0), 2);
      v_auth := case when (pf->>'corporate')::boolean or not (pf->>'resident')::boolean then 'NRS' else pf->>'state' end;
      insert into wht_deductions (org_id, kind, bill_id, bill_payment_id, vendor_id, category, nrs_code, description, recipient_type, resident, beneficiary_type,
        beneficiary_number, base, rate, doubled, amount, authority, state_assumed, deducted_on, period, due_date, status, receipt_no)
      values (b.org_id, 'wht', b.id, new.id, v.id, coalesce(nullif(b.wht_category, 'none'), 'services'), (select nrs_code from wht_rates where code = coalesce(nullif(b.wht_category, 'none'), 'services')),
        left(v_desc || ': ' || (select string_agg(description, '; ' order by line_no) from bill_lines where bill_id = b.id), 300), pf->>'recipient_type',
        (pf->>'resident')::boolean, pf->>'beneficiary_type', pf->>'beneficiary_number', v_base, round(new.wht / nullif(v_base, 0), 4), false, new.wht, v_auth,
        v_auth <> 'NRS' and coalesce((pf->>'state_assumed')::boolean, false), v_day, date_trunc('month', v_day)::date,
        private.wht_due('wht', v_auth, b.wht_category, v_day), v_status, 'WHT-' || lpad(private.next_no(b.org_id, 'WHTR', 1)::text, 5, '0'));
    else
      -- Spread over the bill's kinds of transaction by their share of the bill's WHT; the last takes the pennies.
      select count(*) into v_n from (select 1 from bill_lines where bill_id = b.id and wht > 0 group by coalesce(wht_category, b.wht_category)) z;
      v_left := new.wht;
      for x in select coalesce(l.wht_category, b.wht_category) cat, sum(l.wht) wht, sum(l.wht_base) base, max(l.wht_rate) rate,
                      string_agg(l.description, '; ' order by l.line_no) descr
               from bill_lines l where l.bill_id = b.id and l.wht > 0 group by 1 order by 2 desc loop
        v_i := v_i + 1;
        v_amt := case when v_i = v_n then v_left else round(new.wht * x.wht / v_tot, 2) end;
        v_left := v_left - v_amt;
        v_base := round(x.base * new.wht / v_tot, 2);
        v_auth := case when x.cat = 'compensation' then pf->>'state'
                       when (pf->>'corporate')::boolean or not (pf->>'resident')::boolean then 'NRS' else pf->>'state' end;
        insert into wht_deductions (org_id, kind, bill_id, bill_payment_id, vendor_id, category, nrs_code, description, recipient_type, resident, beneficiary_type,
          beneficiary_number, base, rate, doubled, amount, authority, state_assumed, deducted_on, period, due_date, status, receipt_no)
        values (b.org_id, 'wht', b.id, new.id, v.id, x.cat, (select nrs_code from wht_rates where code = x.cat), left(v_desc || ': ' || x.descr, 300),
          pf->>'recipient_type', (pf->>'resident')::boolean, pf->>'beneficiary_type', pf->>'beneficiary_number', v_base, x.rate,
          not (pf->>'has_tin')::boolean and x.cat <> 'compensation', v_amt, v_auth, v_auth <> 'NRS' and coalesce((pf->>'state_assumed')::boolean, false),
          v_day, date_trunc('month', v_day)::date, private.wht_due('wht', v_auth, x.cat, v_day), v_status,
          'WHT-' || lpad(private.next_no(b.org_id, 'WHTR', 1)::text, 5, '0'));
      end loop;
    end if;
  end if;
  if new.wvat > 0 then
    insert into wht_deductions (org_id, kind, bill_id, bill_payment_id, vendor_id, description, recipient_type, resident, beneficiary_type, beneficiary_number,
      base, rate, amount, authority, deducted_on, period, due_date, status, receipt_no)
    values (b.org_id, 'wvat', b.id, new.id, v.id, left(v_desc || ': VAT withheld', 300), pf->>'recipient_type', (pf->>'resident')::boolean,
      pf->>'beneficiary_type', pf->>'beneficiary_number', round(new.wvat / 0.075, 2), 0.075, new.wvat, 'NRS', v_day, date_trunc('month', v_day)::date,
      private.wht_due('wvat', 'NRS', null, v_day), v_status, 'WHT-' || lpad(private.next_no(b.org_id, 'WHTR', 1)::text, 5, '0'));
  end if;
  return new;
end $$;
drop trigger if exists bill_payments_wht on public.bill_payments;
create trigger bill_payments_wht after insert or update of status on public.bill_payments for each row execute function private.sync_wht_deductions();

-- A bill voided after payment: its deductions not yet remitted fall away with it.
create or replace function private.void_bill_deductions() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.status = 'void' and old.status <> 'void' then
    update wht_deductions set status = 'void' where bill_id = new.id and status in ('pending', 'deducted');
  end if;
  return new;
end $$;
drop trigger if exists bills_void_deductions on public.bills;
create trigger bills_void_deductions after update of status on public.bills for each row execute function private.void_bill_deductions();

-- Bills entered before this engine: drafts are worked out again; approved bills keep the WHT they were approved with, spread
-- over their lines; payments already made get their deduction rows, so schedules and receipts cover them.
do $$
declare bp record; bl record;
begin
  for bl in select id from bills where status = 'draft' loop perform private.bill_wht(bl.id); end loop;
  update bill_lines l set wht = round(b.wht_expected * l.net / b.subtotal, 2), wht_rate = b.wht_rate, wht_base = l.net
  from bills b where b.id = l.bill_id and b.status not in ('draft', 'void') and b.wht_expected > 0 and b.subtotal > 0 and l.wht = 0;
  for bp in select p.* from bill_payments p where (p.wht > 0 or p.wvat > 0) and p.status in ('paid', 'processing')
             and not exists (select 1 from wht_deductions d where d.bill_payment_id = p.id) order by p.paid_at loop
    update bill_payments set status = status where id = bp.id;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Bank matching, the books inbox and bulk payments know about withholding VAT
-- ---------------------------------------------------------------------------
-- The bank matcher (from 20261021000100), with withholding VAT on bills and VAT withheld by customers.
create or replace function private.match_bank_line(p_line uuid) returns text
language plpgsql security definer set search_path = public, private as $$
declare bl public.bank_lines; b public.bank_accounts; v_amt numeric; v_in boolean; r record; c public.collections; v_cnt int; m public.members;
  v_cust public.customers; v_vendor public.vendors; v_due numeric; v_rate numeric; v_gross numeric; v_wht numeric; v_head numeric; j public.journals;
  other public.bank_lines; ob public.bank_accounts; v_key text; v_rule public.entity_rules; v_at timestamptz; v_text text; s public.sales; bb public.bills;
  v_left_wht numeric; v_pid uuid; v_split jsonb;
begin
  select * into bl from bank_lines where id = p_line for update;
  if bl.status <> 'unmatched' then return bl.stage; end if;
  select * into b from bank_accounts where id = bl.bank_account_id;
  v_amt := abs(bl.amount); v_in := bl.amount > 0;
  v_key := private.party_key(coalesce(nullif(bl.counterparty, ''), bl.description));
  update bank_lines set party_key = v_key where id = bl.id;
  v_at := private.line_time(bl.org_id, bl.line_date);
  v_text := coalesce(bl.description, '') || ' ' || coalesce(bl.reference, '') || ' ' || coalesce(bl.counterparty, '');
  -- Actions are taken in the name of the business owner; the line and its evidence say why.
  select * into m from members where org_id = bl.org_id and role = 'owner' and status = 'active' order by created_at limit 1;

  -- 1 Already in the books on this account, same amount, within three days, not yet tied to another line.
  select l.journal_id into r from journal_lines l join journals jj on jj.id = l.journal_id
  where l.org_id = bl.org_id and l.account_code = b.ledger_code and (case when v_in then l.debit else l.credit end) = v_amt
    and jj.entry_date between bl.line_date - 3 and bl.line_date + 3
    and not exists (select 1 from bank_lines x where x.bank_account_id = b.id and x.journal_id = l.journal_id and x.id <> bl.id)
  order by abs(jj.entry_date - bl.line_date), jj.created_at limit 1;
  if r.journal_id is not null then
    update bank_lines set status = 'matched', journal_id = r.journal_id, stage = 'in_books', matched_by = 'system', confidence = 1 where id = bl.id;
    return 'in_books';
  end if;

  if v_in then
    -- 2 A transfer recorded at the till or against an invoice, waiting for confirmation: the statement confirms it.
    select count(*) into v_cnt from collections col where col.org_id = bl.org_id and col.status = 'pending' and col.direction = 'in'
      and col.amount = v_amt and col.method in ('transfer', 'card', 'pos', 'cheque', 'other') and col.received_at::date between bl.line_date - 5 and bl.line_date + 1;
    if v_cnt >= 1 then
      select col.* into c from collections col join customers cu on cu.id = col.customer_id
      where col.org_id = bl.org_id and col.status = 'pending' and col.direction = 'in' and col.amount = v_amt
        and col.method in ('transfer', 'card', 'pos', 'cheque', 'other') and col.received_at::date between bl.line_date - 5 and bl.line_date + 1
      order by private.name_in(cu.name, bl.description) desc, (col.reference is not null and position(upper(col.reference) in upper(bl.description || ' ' || coalesce(bl.reference, ''))) > 0) desc,
        abs(col.received_at::date - bl.line_date), col.received_at limit 1;
      if v_cnt = 1 or private.name_in((select name from customers where id = c.customer_id), bl.description) then
        update collections set status = 'confirmed', bank_account_id = b.id, confirmed_at = now(), note = concat_ws(' · ', note, 'Confirmed by the bank statement')
        where id = c.id;
        c := private.post_collection(c.id, m);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'pending_payment', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'pending_payment';
      end if;
    end if;

    -- 2b The invoice or order the narration names, whoever paid it (a director paying for the company, a relative).
    select * into s from sales x where x.org_id = bl.org_id and x.doc_type in ('invoice', 'order') and x.status in ('open', 'partially_paid') and x.journal_id is not null
      and x.issue_date <= bl.line_date + 1 and private.doc_in_text(x.number, v_text)
    order by x.issue_date desc limit 1;
    if s.id is not null then
      v_due := s.total - s.amount_paid - s.credited - coalesce((select sum(a.amount) from collection_allocations a join collections cc on cc.id = a.collection_id
        where a.sale_id = s.id and cc.status = 'pending'), 0);
      -- Short by withholding tax at a standard rate, and for a customer who withholds VAT by the invoice's VAT: the difference
      -- is the customer's WHT credit and VAT credit.
      v_split := private.customer_short_split(s.id, v_due, v_amt);
      if v_split is not null then
        perform private.book_customer_withholding(bl.org_id, s.customer_id, s.id, v_split, v_at, m);
      end if;
      c := private.add_collection(bl.org_id, s.customer_id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
        'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'Matched from the bank by ' || s.number, 'spread', false), m, 'confirmed', array[s.id]);
      update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'invoice_ref', matched_by = 'system',
        confidence = case when v_amt <= v_due + 0.004 then 1 else 0.9 end where id = bl.id;
      if v_amt > v_due + 0.004 then
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'bookkeeper', 'overpaid_invoice', 'bank_line', bl.id, s.customer_name || ' paid more than ' || s.number,
          'The extra is held as customer credit. Refund it or use it on their next invoice.', jsonb_build_object('sale_id', s.id, 'customer_id', s.customer_id), 0.9,
          'AR: payment names the invoice and exceeds what is owed', 'invoice_ref', 'info', v_amt - v_due, c.journal_id) on conflict do nothing;
      end if;
      return 'invoice_ref';
    end if;
  else
    -- 3 Statutory payees clear the tax head, never an expense (AP-06).
    select * into r from payee_registry pr where pr.kind like 'statutory%' and pr.direction in ('out', 'both')
      and upper(bl.description || ' ' || coalesce(bl.counterparty, '')) ~ pr.pattern order by pr.id limit 1;
    if r.id is not null then
      j := private.post_bank_line(bl.id, coalesce(case when r.role is not null then private.acct(bl.org_id, r.role) end, r.account_code), null, null,
        r.description || ' · ' || bl.description, 'statutory', jsonb_build_object('matched_by', 'rule'));
      select coalesce(sum(credit - debit), 0) into v_head from journal_lines where org_id = bl.org_id and account_code = coalesce(case when r.role is not null then private.acct(bl.org_id, r.role) end, r.account_code);
      if v_head < -0.004 then
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'tax', 'remittance_without_accrual', 'bank_line', bl.id, 'Paid more ' || r.description || ' than the books owed',
          'This remittance is more than the liability on record. Is a return missing, or was this paid in advance?',
          jsonb_build_object('account', r.account_code, 'overpaid', -v_head), 1, 'AP-06 exception', 'statutory', 'info', v_amt, j.id) on conflict do nothing;
      end if;
      return 'statutory';
    end if;

    -- 3b The bill the narration names: Counta's number, or the supplier's own invoice number together with the amount
    --    owed or the supplier's name (a short invoice number alone could be a coincidence).
    select bb2.* into bb from bills bb2 where bb2.org_id = bl.org_id and bb2.status in ('approved', 'partially_paid')
      and (private.doc_in_text(bb2.number, v_text)
           or private.ref_in_text(bb2.vendor_ref, v_text) and (abs(bb2.total - bb2.amount_paid - v_amt) < 0.005
             or abs(bb2.total - bb2.amount_paid - greatest(bb2.wht_expected + bb2.wvat_expected - bb2.wht_withheld - bb2.wvat_withheld, 0) - v_amt) < 0.005
             or private.name_in((select name from vendors where id = bb2.vendor_id), coalesce(bl.counterparty, '') || ' ' || bl.description)))
    order by bb2.due_date limit 1;
    if bb.id is not null then
      v_due := bb.total - bb.amount_paid - coalesce((select sum(gross) from bill_payments where bill_id = bb.id and status = 'processing'), 0);
      v_left_wht := greatest(bb.wht_expected + bb.wvat_expected - bb.wht_withheld - bb.wvat_withheld
        - coalesce((select sum(wht + wvat) from bill_payments where bill_id = bb.id and status = 'processing'), 0), 0);
      v_rate := coalesce((bb.wht_expected + bb.wvat_expected) / nullif(bb.total, 0), 0);
      v_gross := case when abs(v_due - v_amt) < 0.005 then v_due
                      when v_left_wht > 0 and abs(v_due - v_left_wht - v_amt) < 0.005 then v_due
                      when v_amt < v_due - v_left_wht then round(v_amt / (1 - v_rate), 2) end;
      if v_gross is not null then
        v_wht := greatest(v_gross - v_amt, 0);
        j := private.record_bill_payment(bb.id, b.id, v_gross, v_wht, v_at, coalesce(bl.reference, left(bl.description, 60)), m);
        update bank_lines set status = 'matched', journal_id = j.id, stage = 'bill_ref', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'bill_ref';
      end if;
    end if;
  end if;

  if v_in then
    -- 4 A customer named in the narration paying open sales (AR-03).
    for v_cust in select cu.* from customers cu where cu.org_id = bl.org_id and not cu.is_walk_in and not cu.archived
        and private.name_in(cu.name, coalesce(bl.counterparty, '') || ' ' || bl.description)
        order by length(cu.name) desc limit 1 loop
      select coalesce(sum(s2.total - s2.amount_paid - s2.credited), 0) into v_due from sales s2
      where s2.customer_id = v_cust.id and s2.status in ('open', 'partially_paid') and s2.journal_id is not null;
      -- Exactly what is owed on one sale, or on all of them.
      select s2.id into r from sales s2 where s2.customer_id = v_cust.id and s2.status in ('open', 'partially_paid') and s2.journal_id is not null
        and s2.total - s2.amount_paid - s2.credited = v_amt order by s2.due_date limit 1;
      if r.id is not null or abs(v_due - v_amt) < 0.005 then
        c := private.add_collection(bl.org_id, v_cust.id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
          'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'Matched from the bank statement', 'spread', r.id is null), m, 'confirmed',
          case when r.id is not null then array[r.id] end);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'customer', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'customer';
      end if;
      -- Short by withholding tax at a standard rate (and, for a customer who withholds VAT, by the VAT): WHT and VAT credits (AR-03, TAX-03).
      for r in select s2.id, s2.total - s2.amount_paid - s2.credited due from sales s2 where s2.customer_id = v_cust.id and s2.status in ('open', 'partially_paid')
          and s2.journal_id is not null order by s2.due_date loop
        v_split := private.customer_short_split(r.id, r.due, v_amt);
        if v_split is not null then
          perform private.book_customer_withholding(bl.org_id, v_cust.id, r.id, v_split, v_at, m);
          c := private.add_collection(bl.org_id, v_cust.id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
            'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'Matched from the bank statement', 'spread', false), m, 'confirmed', array[r.id]);
          update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'customer_wht', matched_by = 'system', confidence = 1 where id = bl.id;
          return 'customer_wht';
        end if;
      end loop;
      -- Paying part of what is owed: oldest first. Paying with nothing owed: held as an advance, flagged (AR rule).
      c := private.add_collection(bl.org_id, v_cust.id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
        'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', case when v_due > 0 then 'Part payment matched from the bank statement'
          else 'No invoice open: held as customer credit' end, 'spread', true), m, 'confirmed', null);
      update bank_lines set status = 'matched', journal_id = c.journal_id, stage = case when v_due > 0 then 'customer_part' else 'customer_advance' end,
        matched_by = 'system', confidence = case when v_due > 0 then 0.9 else 0.8 end where id = bl.id;
      if v_due <= 0 then
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'bookkeeper', 'advance_without_invoice', 'bank_line', bl.id, v_cust.name || ' paid with nothing owed',
          'Held as customer credit. Raise the invoice it was for, or refund it.', jsonb_build_object('customer_id', v_cust.id), 0.8,
          'AR: inflow from a known customer with no open invoice', 'customer', 'info', v_amt, c.journal_id) on conflict do nothing;
      end if;
      return case when v_due > 0 then 'customer_part' else 'customer_advance' end;
    end loop;
  else
    -- 5 A vendor named in the narration being paid for open bills (AP-03).
    for v_vendor in select v.* from vendors v where v.org_id = bl.org_id
        and (private.name_in(v.name, coalesce(bl.counterparty, '') || ' ' || bl.description)
             or (v.account_number is not null and position(v.account_number in coalesce(bl.counterparty_account, '') || bl.description) > 0))
        order by length(v.name) desc limit 1 loop
      for r in select bb2.*, bb2.total - bb2.amount_paid due, greatest(bb2.wht_expected + bb2.wvat_expected - bb2.wht_withheld - bb2.wvat_withheld, 0) wht_left from bills bb2
          where bb2.vendor_id = v_vendor.id and bb2.status in ('approved', 'partially_paid') order by bb2.due_date loop
        v_gross := null;
        if abs(r.due - v_amt) < 0.005 then v_gross := r.due; v_wht := 0;
        elsif r.wht_left > 0 and abs(r.due - r.wht_left - v_amt) < 0.005 then v_gross := r.due; v_wht := r.wht_left;
        end if;
        if v_gross is not null then
          j := private.record_bill_payment(r.id, b.id, v_gross, v_wht, v_at, coalesce(bl.reference, left(bl.description, 60)), m);
          update bank_lines set status = 'matched', journal_id = j.id, stage = 'vendor_bill', matched_by = 'system', confidence = 1 where id = bl.id;
          return 'vendor_bill';
        end if;
      end loop;
      -- A known vendor with no matching bill: post to their usual account and ask for the bill (AP-05).
      if v_vendor.default_account is not null then
        j := private.post_bank_line(bl.id, v_vendor.default_account, null, null, v_vendor.name || ' · no bill', 'vendor_no_bill',
          jsonb_build_object('matched_by', 'rule', 'ai_confidence', 0.85));
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'bookkeeper', 'payment_without_bill', 'bank_line', bl.id, 'Paid ' || v_vendor.name || ' without a bill',
          'Posted to their usual account with no VAT claimed and no WHT. Upload the bill if there is one.', jsonb_build_object('vendor_id', v_vendor.id),
          0.85, 'AP-05', 'vendor_no_bill', 'info', v_amt, j.id) on conflict do nothing;
        return 'vendor_no_bill';
      end if;
    end loop;
  end if;

  -- 6 Money moving between the business's own accounts.
  select x.* into other from bank_lines x join bank_accounts xa on xa.id = x.bank_account_id
  where x.org_id = bl.org_id and x.bank_account_id <> bl.bank_account_id and x.amount = -bl.amount and x.status in ('unmatched', 'posted')
    and x.line_date between bl.line_date - 2 and bl.line_date + 2 and (x.status = 'unmatched' or x.stage = 'transfer_one_leg')
  order by abs(x.line_date - bl.line_date) limit 1;
  if other.id is not null then
    select * into ob from bank_accounts where id = other.bank_account_id;
    if other.status = 'unmatched' then
      j := private.post_entry(bl.org_id, 'Transfer between own accounts · ' || b.name || ' and ' || ob.name, 'bank', bl.id, m.id, null,
        private.reclass_pair(case when v_in then b.ledger_code else ob.ledger_code end, case when v_in then ob.ledger_code else b.ledger_code end, v_amt, null, null),
        v_at, jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id), jsonb_build_object('type', 'bank_line', 'id', other.id))));
      update bank_lines set status = 'matched', journal_id = j.id, stage = 'transfer', matched_by = 'system', confidence = 1 where id in (bl.id, other.id);
    else
      j := private.post_bank_line(bl.id, private.acct(bl.org_id, 'bank_clearing'), null, null, 'Transfer between own accounts · ' || ob.name, 'transfer',
        jsonb_build_object('matched_by', 'system'), 'matched');
      update bank_lines set stage = 'transfer' where id = other.id;
    end if;
    return 'transfer';
  end if;
  if exists (select 1 from bank_accounts xa where xa.org_id = bl.org_id and xa.id <> b.id and xa.active
             and ((xa.account_number is not null and position(xa.account_number in coalesce(bl.counterparty_account, '') || ' ' || bl.description) > 0)
                  or upper(bl.description) ~ '(OWN ACCOUNT|SELF TRANSFER|TRF TO SELF|SWEEP)')) then
    perform private.post_bank_line(bl.id, private.acct(bl.org_id, 'bank_clearing'), null, null, 'Transfer between own accounts, other side to come', 'transfer_one_leg',
      jsonb_build_object('matched_by', 'system'));
    return 'transfer_one_leg';
  end if;

  -- 7 A rule learned from an earlier decision.
  select * into v_rule from entity_rules er where er.org_id = bl.org_id and er.direction = case when v_in then 'in' else 'out' end
    and v_key is not null and (er.party_key = v_key or position(er.party_key in v_key) > 0) order by length(er.party_key) desc limit 1;
  if v_rule.id is not null and private.postable(bl.org_id, v_rule.account_code) then
    perform private.post_bank_line(bl.id, v_rule.account_code,
      case when v_rule.customer_id is not null then 'customer' when v_rule.vendor_id is not null then 'vendor' end, coalesce(v_rule.customer_id, v_rule.vendor_id),
      null, 'rule', jsonb_build_object('matched_by', 'rule', 'ai_confidence', 0.95));
    update entity_rules set hits = hits + 1 where id = v_rule.id;
    return 'rule';
  end if;

  -- 8 Payee types: bank charges, power, telcos, internet, fuel, CAC, interest received.
  select * into r from payee_registry pr where pr.kind not like 'statutory%' and pr.direction in (case when v_in then 'in' else 'out' end, 'both')
    and upper(bl.description || ' ' || coalesce(bl.counterparty, '')) ~ pr.pattern order by pr.id limit 1;
  if r.id is not null then
    perform private.post_bank_line(bl.id, coalesce(case when r.role is not null then private.acct(bl.org_id, r.role) end, r.account_code), null, null,
      r.description || ' · ' || bl.description, 'registry', jsonb_build_object('matched_by', 'rule', 'ai_confidence', 0.9));
    return 'registry';
  end if;

  -- 9 Nobody named, but exactly one open invoice (or bill) is for this amount, as it stands or less a standard WHT rate:
  --   held in suspense and put to a person to confirm in one tap.
  if v_in then
    select count(*) into v_cnt from sales x where x.org_id = bl.org_id and x.doc_type in ('invoice', 'order') and x.status in ('open', 'partially_paid')
      and x.journal_id is not null and x.issue_date between bl.line_date - 180 and bl.line_date + 1
      and (abs(x.total - x.amount_paid - x.credited - v_amt) < 0.005
           or exists (select 1 from unnest(array[0.02, 0.05, 0.10]) w where abs(round(x.total - x.amount_paid - x.credited - round(x.subtotal * w, 2), 2) - v_amt) < 0.005));
    if v_cnt = 1 then
      select * into s from sales x where x.org_id = bl.org_id and x.doc_type in ('invoice', 'order') and x.status in ('open', 'partially_paid')
        and x.journal_id is not null and x.issue_date between bl.line_date - 180 and bl.line_date + 1
        and (abs(x.total - x.amount_paid - x.credited - v_amt) < 0.005
             or exists (select 1 from unnest(array[0.02, 0.05, 0.10]) w where abs(round(x.total - x.amount_paid - x.credited - round(x.subtotal * w, 2), 2) - v_amt) < 0.005));
      v_pid := private.suspend_line(bl.id, 'Payment for ' || s.number || '?',
        'Is this ₦' || to_char(v_amt, 'FM999,999,999,990.00') || ' from ' || s.customer_name || ' for ' || s.number || '? Confirm it, or say what it was.',
        jsonb_build_object('kind', 'invoice_match', 'sale_id', s.id, 'number', s.number, 'customer_id', s.customer_id, 'customer_name', s.customer_name,
          'party_type', 'customer', 'party_id', s.customer_id, 'account_code', private.acct(bl.org_id, 'receivables')),
        0.75, 'Only open invoice for this amount', 'invoice_amount');
      return 'invoice_amount';
    end if;
  else
    select count(*) into v_cnt from bills x where x.org_id = bl.org_id and x.status in ('approved', 'partially_paid') and x.bill_date <= bl.line_date + 1
      and (abs(x.total - x.amount_paid - v_amt) < 0.005 or (x.wht_expected - x.wht_withheld > 0 and abs(x.total - x.amount_paid - (x.wht_expected - x.wht_withheld) - v_amt) < 0.005));
    if v_cnt = 1 then
      select * into bb from bills x where x.org_id = bl.org_id and x.status in ('approved', 'partially_paid') and x.bill_date <= bl.line_date + 1
        and (abs(x.total - x.amount_paid - v_amt) < 0.005 or (x.wht_expected - x.wht_withheld > 0 and abs(x.total - x.amount_paid - (x.wht_expected - x.wht_withheld) - v_amt) < 0.005));
      v_pid := private.suspend_line(bl.id, 'Payment of ' || bb.number || '?',
        'Is this ₦' || to_char(v_amt, 'FM999,999,999,990.00') || ' paid to ' || (select name from vendors where id = bb.vendor_id) || ' for ' || bb.number
          || coalesce(' (their ' || bb.vendor_ref || ')', '') || '? Confirm it, or say what it was.',
        jsonb_build_object('kind', 'bill_match', 'bill_id', bb.id, 'number', bb.number, 'vendor_id', bb.vendor_id, 'vendor_name', (select name from vendors where id = bb.vendor_id),
          'party_type', 'vendor', 'party_id', bb.vendor_id, 'account_code', private.acct(bl.org_id, 'payables')),
        0.75, 'Only open bill for this amount', 'bill_amount');
      return 'bill_amount';
    end if;
  end if;
  return null;
end $$;
-- Resolving a books-inbox proposal (from 20261021000100), with withholding VAT on bills and VAT withheld by customers.
create or replace function public.resolve_proposal(p_proposal uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare pr public.ai_proposals; m public.members; bl public.bank_lines; v_code text; v_action text := coalesce(nullif(p->>'action', ''), 'approve'); j public.journals;
  b public.bank_accounts; v_amt numeric; v_party_type text := nullif(p->>'party_type', ''); v_party uuid := nullif(p->>'party_id', '')::uuid;
  s public.sales; bb public.bills; c public.collections; v_due numeric; v_rate numeric; v_gross numeric; v_left_wht numeric; v_at timestamptz; v_split jsonb;
begin
  select * into pr from ai_proposals where id = p_proposal for update;
  if not found then raise exception 'Not found.'; end if;
  m := private.require(pr.org_id, 'keep_books');
  if pr.status not in ('pending', 'auto_posted', 'info') then raise exception 'This was already decided.'; end if;
  if v_action = 'dismiss' then
    if pr.status = 'pending' and pr.holding_journal_id is not null then raise exception 'Choose where this goes, or mark it as not a real transaction.'; end if;
    update ai_proposals set status = 'approved', decided_by = m.id, decided_at = now(), decision = p where id = pr.id;
    return jsonb_build_object('status', 'dismissed');
  end if;
  if pr.source_type <> 'bank_line' then
    raise exception 'Open the % to decide it.', replace(pr.kind, '_', ' ');
  end if;
  select * into bl from bank_lines where id = pr.source_id for update;
  select * into b from bank_accounts where id = bl.bank_account_id;
  v_amt := abs(bl.amount);
  if v_action = 'ignore' then
    -- Not a real transaction (a duplicate or a reversed transfer on the statement): the suspense entry is taken back.
    if pr.holding_journal_id is not null then perform private.reverse_entry(pr.holding_journal_id, m.id, 'Not a real transaction: ' || coalesce(p->>'note', ''), null); end if;
    if pr.status = 'auto_posted' and pr.journal_id is not null then perform private.reverse_entry(pr.journal_id, m.id, 'Not a real transaction', null); end if;
    update bank_lines set status = 'ignored', note = nullif(trim(p->>'note'), '') where id = bl.id;
    update ai_proposals set status = 'rejected', decided_by = m.id, decided_at = now(), decision = p where id = pr.id;
    return jsonb_build_object('status', 'ignored');
  end if;
  v_at := private.line_time(pr.org_id, bl.line_date);
  -- Confirming the invoice or bill the matcher proposed.
  -- (Approving with the proposal's own account and party, as the generic answer form sends it, is the same yes.)
  if pr.status = 'pending' and pr.proposal->>'kind' in ('invoice_match', 'bill_match') and v_action = 'approve'
     and (nullif(p->>'account_code', '') is null or (p->>'account_code' = pr.proposal->>'account_code' and coalesce(p->>'party_id', pr.proposal->>'party_id') = pr.proposal->>'party_id')) then
    if pr.proposal->>'kind' = 'invoice_match' then
      select * into s from sales where id = (pr.proposal->>'sale_id')::uuid for update;
      if s.id is null or s.status not in ('open', 'partially_paid') then raise exception '% is no longer open. Say what this payment was.', coalesce(s.number, 'The invoice'); end if;
      v_due := s.total - s.amount_paid - s.credited;
      if pr.holding_journal_id is not null then perform private.reverse_entry(pr.holding_journal_id, m.id, 'Matched to ' || s.number, null); end if;
      v_split := private.customer_short_split(s.id, v_due, v_amt);
      if v_split is not null then
        perform private.book_customer_withholding(pr.org_id, s.customer_id, s.id, v_split, v_at, m);
      end if;
      c := private.add_collection(pr.org_id, s.customer_id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
        'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'Confirmed from the bank by ' || coalesce(m.display_name, 'a person'), 'spread', false),
        m, 'confirmed', array[s.id]);
      update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'user', matched_by = 'user', confidence = 1 where id = bl.id;
      update ai_proposals set status = 'approved', decided_by = m.id, decided_at = now(), decision = p, journal_id = c.journal_id where id = pr.id;
      return jsonb_build_object('status', 'approved', 'journal_ref', (select ref from journals where id = c.journal_id), 'settled', s.number);
    else
      select * into bb from bills where id = (pr.proposal->>'bill_id')::uuid for update;
      if bb.id is null or bb.status not in ('approved', 'partially_paid') then raise exception '% is no longer open. Say what this payment was.', coalesce(bb.number, 'The bill'); end if;
      v_due := bb.total - bb.amount_paid;
      v_left_wht := greatest(bb.wht_expected + bb.wvat_expected - bb.wht_withheld - bb.wvat_withheld, 0);
      v_gross := case when abs(v_due - v_amt) < 0.005 then v_due when abs(v_due - v_left_wht - v_amt) < 0.005 then v_due
                      when v_amt < v_due then round(v_amt / (1 - coalesce((bb.wht_expected + bb.wvat_expected) / nullif(bb.total, 0), 0)), 2) end;
      if v_gross is null then raise exception '% has only % left to pay.', bb.number, to_char(v_due, 'FM999,999,999,990.00'); end if;
      if pr.holding_journal_id is not null then perform private.reverse_entry(pr.holding_journal_id, m.id, 'Matched to ' || bb.number, null); end if;
      j := private.record_bill_payment(bb.id, b.id, v_gross, greatest(v_gross - v_amt, 0), v_at, coalesce(bl.reference, left(bl.description, 60)), m);
      update bank_lines set status = 'matched', journal_id = j.id, stage = 'user', matched_by = 'user', confidence = 1 where id = bl.id;
      update ai_proposals set status = 'approved', decided_by = m.id, decided_at = now(), decision = p, journal_id = j.id where id = pr.id;
      return jsonb_build_object('status', 'approved', 'journal_ref', j.ref, 'settled', bb.number);
    end if;
  end if;
  v_code := coalesce(nullif(p->>'account_code', ''), pr.proposal->>'account_code');
  if v_code is null or not private.postable(pr.org_id, v_code) or v_code = b.ledger_code then raise exception 'Choose the account this belongs to.'; end if;
  if v_code ~ '^(1101|1102)' and v_party_type is distinct from 'customer' then raise exception 'Say which customer.'; end if;
  if v_code ~ '^(2101|2102)' and v_party_type is distinct from 'vendor' then raise exception 'Say which vendor.'; end if;
  if v_code ~ '^(2201|1402|2202|1401)' then raise exception 'VAT and WHT come only from invoices and bills, not from bank lines.'; end if;
  if pr.status = 'pending' and pr.holding_journal_id is not null then
    -- Out of suspense into the account chosen.
    j := private.post_entry(pr.org_id, 'Confirmed: ' || bl.description, 'reclass', bl.id, m.id, m.id,
      case when bl.amount > 0 then jsonb_build_array(
          jsonb_build_object('code', private.acct(pr.org_id, 'suspense'), 'debit', v_amt, 'memo', 'Out of suspense'),
          jsonb_build_object('code', v_code, 'credit', v_amt, 'party_type', v_party_type, 'party_id', v_party, 'memo', bl.description))
        else jsonb_build_array(
          jsonb_build_object('code', v_code, 'debit', v_amt, 'party_type', v_party_type, 'party_id', v_party, 'memo', bl.description),
          jsonb_build_object('code', private.acct(pr.org_id, 'suspense'), 'credit', v_amt, 'memo', 'Out of suspense')) end,
      v_at,
      jsonb_build_object('origin', 'manual', 'ai_confidence', pr.confidence, 'ai_proposal_id', pr.id,
        'evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id), jsonb_build_object('type', 'decision', 'by', m.display_name, 'note', p->>'note'))));
    update bank_lines set status = 'posted', stage = 'user', matched_by = 'user', confidence = 1 where id = bl.id;
  elsif pr.status = 'auto_posted' and v_action = 'change' and v_code <> pr.proposal->>'account_code' then
    -- The agent posted it, a person says otherwise: move it.
    j := private.post_entry(pr.org_id, 'Corrected: ' || bl.description, 'reclass', bl.id, m.id, m.id,
      private.reclass_pair(v_code, pr.proposal->>'account_code', case when bl.amount > 0 then -v_amt else v_amt end, null, null), now(),
      jsonb_build_object('origin', 'manual', 'ai_proposal_id', pr.id));
  end if;
  update ai_proposals set status = 'approved', decided_by = m.id, decided_at = now(), decision = p || jsonb_build_object('account_code', v_code),
    journal_id = coalesce(j.id, journal_id) where id = pr.id;
  -- Learn the party for next time (CLS-05).
  if coalesce((p->>'remember')::boolean, false) and bl.party_key is not null then
    insert into entity_rules (org_id, party_key, direction, account_code, vendor_id, customer_id, note, source, created_by)
    values (pr.org_id, bl.party_key, case when bl.amount > 0 then 'in' else 'out' end, v_code,
      case when v_party_type = 'vendor' then v_party end, case when v_party_type = 'customer' then v_party end, nullif(trim(p->>'note'), ''), 'reviewer', m.id)
    on conflict (org_id, party_key, direction) do update set account_code = excluded.account_code, vendor_id = excluded.vendor_id, customer_id = excluded.customer_id,
      note = coalesce(excluded.note, entity_rules.note);
  end if;
  return jsonb_build_object('status', 'approved', 'journal_ref', j.ref);
end $$;
-- Checking a bulk payment row (from 20261021000100): the withholding kept back includes withholding VAT.
create or replace function private.bulk_row(p_org uuid, r jsonb, p_default text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_err text[] := '{}'; v_amt numeric := round(private.num(r->>'amount'), 2); b public.bills; v public.vendors; v_kind text; v_code text;
  v_gross numeric; v_wht numeric := 0; v_due numeric; v_left_wht numeric; v_full_net numeric; v_rate numeric; v_bill_ref text := nullif(trim(r->>'bill'), '');
  v_supplier text := nullif(trim(r->>'supplier'), ''); v_purpose text; v_lines jsonb; v_label text; sv public.vendors;
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
      end if;
    end if;
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
    'bill_id', b.id, 'bill_number', b.number, 'vendor_id', v.id, 'vendor_name', v.name, 'account', v_code, 'purpose', v_purpose, 'lines', v_lines);
end $$;

-- ---------------------------------------------------------------------------
-- VAT: the month's figures, credits carried forward, returns filed and paid
-- ---------------------------------------------------------------------------
-- A month's VAT from the documents: output VAT on sales (less credit notes), input VAT on bills, stock receipts and VAT
-- self-charged on services from abroad (less suppliers' credit notes), and VAT customers withheld (credited in the return).
create or replace function private.vat_month(p_org uuid, p_month date) returns jsonb
language sql stable security definer set search_path = public, private as $$
  with b as (select date_trunc('month', p_month)::date f, (date_trunc('month', p_month) + interval '1 month' - interval '1 day')::date t),
  so as (select coalesce(sum(case when s.doc_type = 'credit_note' then -l.vat else l.vat end), 0) vat,
                coalesce(sum(case when s.doc_type = 'credit_note' then -l.net else l.net end) filter (where l.vat_treatment = 'standard'), 0) std,
                coalesce(sum(case when s.doc_type = 'credit_note' then -l.net else l.net end) filter (where l.vat_treatment = 'zero'), 0) zero,
                coalesce(sum(case when s.doc_type = 'credit_note' then -l.net else l.net end) filter (where l.vat_treatment = 'exempt'), 0) exempt
         from sales s join sale_lines l on l.sale_id = s.id, b
         where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import' and s.issue_date between b.f and b.t),
  bi as (select coalesce(sum(l.vat) filter (where l.vat_recoverable), 0) vat, coalesce(sum(l.reverse_charge_vat) filter (where l.vat_recoverable), 0) rc
         from bills x join bill_lines l on l.bill_id = x.id, b
         where x.org_id = p_org and x.source not in ('receipt', 'import') and x.journal_id is not null and x.status <> 'void' and x.bill_date between b.f and b.t),
  rc as (select coalesce(sum(input_vat), 0) vat from receipts, b
         where org_id = p_org and status = 'posted' and private.local_day(org_id, coalesce(posted_at, created_at)) between b.f and b.t),
  vc as (select coalesce(sum(vat_total), 0) vat from vendor_credits, b where org_id = p_org and status <> 'void' and journal_id is not null and credit_date between b.f and b.t),
  wv as (select coalesce(sum(amount), 0) vat from collections, b where org_id = p_org and method = 'wvat_credit' and status = 'confirmed' and journal_id is not null
           and private.local_day(org_id, received_at) between b.f and b.t)
  select jsonb_build_object('period', b.f, 'output', round(so.vat, 2), 'input', round(bi.vat + bi.rc + rc.vat - vc.vat, 2), 'reverse_charge', round(bi.rc, 2),
    'wvat_credit', round(wv.vat, 2), 'standard_sales', so.std, 'zero_rated_sales', so.zero, 'exempt_sales', so.exempt)
  from b, so, bi, rc, vc, wv
$$;

-- Month by month up to p_to: what is payable, and the input VAT credit carried forward in layers by the month it arose (used
-- oldest first; a layer more than five years old lapses; a refund claim takes the newest, which are within 12 months).
-- Filed months keep the figures they were filed with.
create or replace function private.vat_chain(p_org uuid, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_start date; mth date; f jsonb; vp public.vat_periods; layers jsonb := '[]'::jsonb; v_out jsonb := '[]'::jsonb; v_net numeric; v_used numeric; v_need numeric;
  v_exp numeric; v_new numeric; v_refund numeric; v_bf numeric; v_pay numeric; x jsonb; v_keep jsonb; v_take numeric; v_live jsonb; i int;
begin
  -- From the start of the books (or the earliest return filed), so a month reads the same whichever month the position runs to.
  v_start := date_trunc('month', least(coalesce((select books_start from orgs where id = p_org), (select min(entry_date) from journals where org_id = p_org), p_to),
    coalesce((select min(period) from vat_periods where org_id = p_org), p_to)))::date;
  mth := v_start;
  while mth <= date_trunc('month', p_to)::date loop
    select * into vp from vat_periods where org_id = p_org and period = mth;
    v_live := private.vat_month(p_org, mth);
    f := case when vp.period is not null then jsonb_build_object('period', mth, 'output', vp.output_vat, 'input', vp.input_vat, 'wvat_credit', vp.wvat_credit,
      'reverse_charge', v_live->'reverse_charge', 'standard_sales', v_live->'standard_sales', 'zero_rated_sales', v_live->'zero_rated_sales',
      'exempt_sales', v_live->'exempt_sales') else v_live end;
    v_bf := (select coalesce(sum((l->>'amount')::numeric), 0) from jsonb_array_elements(layers) l);
    -- Credits more than five years old lapse.
    v_exp := (select coalesce(sum((l->>'amount')::numeric), 0) from jsonb_array_elements(layers) l where (l->>'from')::date < (mth - interval '60 months')::date);
    layers := (select coalesce(jsonb_agg(l), '[]'::jsonb) from jsonb_array_elements(layers) l where (l->>'from')::date >= (mth - interval '60 months')::date);
    v_net := (f->>'output')::numeric - (f->>'wvat_credit')::numeric - (f->>'input')::numeric;
    v_used := 0; v_new := 0;
    if v_net > 0 then
      v_need := v_net; v_keep := '[]'::jsonb;
      for x in select l from jsonb_array_elements(layers) l order by (l->>'from')::date loop
        v_take := least(v_need, (x->>'amount')::numeric);
        v_need := v_need - v_take; v_used := v_used + v_take;
        if (x->>'amount')::numeric - v_take > 0.004 then v_keep := v_keep || jsonb_build_array(jsonb_set(x, '{amount}', to_jsonb(round((x->>'amount')::numeric - v_take, 2)))); end if;
      end loop;
      layers := v_keep;
      v_pay := round(v_net - v_used, 2);
    else
      v_new := round(-v_net, 2); v_pay := 0;
      if v_new > 0 then layers := layers || jsonb_build_array(jsonb_build_object('from', mth, 'amount', v_new)); end if;
    end if;
    v_refund := coalesce(vp.refund_claimed, 0);
    if v_refund > 0 then
      v_need := v_refund; v_keep := '[]'::jsonb;
      for x in select l from jsonb_array_elements(layers) l order by (l->>'from')::date desc loop
        v_take := least(v_need, (x->>'amount')::numeric); v_need := v_need - v_take;
        if (x->>'amount')::numeric - v_take > 0.004 then v_keep := jsonb_build_array(jsonb_set(x, '{amount}', to_jsonb(round((x->>'amount')::numeric - v_take, 2)))) || v_keep; end if;
      end loop;
      layers := v_keep;
    end if;
    v_out := v_out || jsonb_build_array(f || jsonb_build_object('credit_bf', round(v_bf, 2), 'credit_expired', round(v_exp, 2), 'net', round(v_net, 2),
      'credit_used', round(v_used, 2), 'payable', v_pay, 'new_credit', v_new, 'refund_claimed', v_refund,
      'credit_cf', (select coalesce(round(sum((l->>'amount')::numeric), 2), 0) from jsonb_array_elements(layers) l), 'layers', layers,
      'due_date', (mth + interval '1 month' + interval '20 days')::date, 'filed', vp.period is not null, 'status', coalesce(vp.status, 'open'),
      'filed_at', vp.filed_at, 'paid_at', vp.paid_at, 'journal_ref', (select ref from journals where id = vp.journal_id),
      'payment_ref', (select ref from journals where id = vp.payment_journal_id),
      'changed_since_filing', case when vp.period is not null and (abs((v_live->>'output')::numeric - vp.output_vat) >= 0.01 or abs((v_live->>'input')::numeric - vp.input_vat) >= 0.01
        or abs((v_live->>'wvat_credit')::numeric - vp.wvat_credit) >= 0.01) then jsonb_build_object('output', v_live->'output', 'input', v_live->'input', 'wvat_credit', v_live->'wvat_credit') end));
    mth := (mth + interval '1 month')::date;
  end loop;
  return v_out;
end $$;

-- Whether the business is a small company for VAT: on the last full financial year (the current one when there is none yet),
-- turnover up to ₦100 million, fixed assets up to ₦250 million, and no professional services.
create or replace function private.vat_small_status(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; v_today date := private.local_day(p_org, now()); v_cur date; v_from date; v_to date; v_basis text; v_turn numeric; v_fa numeric; v_ytd numeric; s jsonb;
  v_first date;
begin
  select * into o from orgs where id = p_org;
  v_cur := private.fy_start(p_org, v_today);
  v_first := coalesce(o.books_start, (select min(entry_date) from journals where org_id = p_org), v_today);
  if v_first <= (v_cur - interval '1 year')::date then v_from := (v_cur - interval '1 year')::date; v_to := v_cur - 1; v_basis := 'last_year';
  else v_from := v_cur; v_to := v_today; v_basis := 'this_year'; end if;
  v_turn := round(coalesce((private.pl_totals(private.pl_map(p_org, v_from, v_to))->>'revenue')::numeric, 0), 2);
  s := private.sofp_map(p_org, v_to);
  v_fa := round(private.v(s, 'Property, plant and equipment') + private.v(s, 'Intangible assets'), 2);
  v_ytd := round(coalesce((private.pl_totals(private.pl_map(p_org, v_cur, v_today))->>'revenue')::numeric, 0), 2);
  return jsonb_build_object('basis', v_basis, 'from', v_from, 'to', v_to, 'turnover', v_turn, 'fixed_assets', v_fa, 'professional_services', o.professional_services,
    'small', v_turn <= 100000000 and v_fa <= 250000000 and not o.professional_services, 'year_to_date', v_ytd, 'year_from', v_cur,
    'crossed', v_ytd > 100000000, 'charging', o.vat_registered, 'opt_in', o.vat_opt_in);
end $$;

-- What Counta advises: a small company need not charge or file VAT (unless it opts in to recover input VAT); everyone else must.
create or replace function public.vat_status(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; st jsonb;
begin
  m := private.require(p_org, null);
  st := private.vat_small_status(p_org);
  return st || jsonb_build_object('advice', case
      when not (st->>'charging')::boolean and ((st->>'crossed')::boolean or not (st->>'small')::boolean) then 'must_start'
      when (st->>'charging')::boolean and (st->>'small')::boolean and not (st->>'opt_in')::boolean then 'may_stop'
      else 'ok' end,
    'can_change', m.role = 'owner');
end $$;

-- The owner turns VAT charging on or off. p: {charge: bool}. Only a small company may stop; a small company that keeps
-- charging has opted in (it must then file returns every month).
create or replace function public.set_vat_charging(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; st jsonb; v_charge boolean := (p->>'charge')::boolean;
begin
  m := private.require(p_org, null);
  if m.role <> 'owner' then raise exception 'Only the owner turns VAT on or off.' using errcode = '42501'; end if;
  if v_charge is null then raise exception 'Say whether the business charges VAT.'; end if;
  st := private.vat_small_status(p_org);
  if not v_charge and not (st->>'small')::boolean then
    raise exception 'Only a small company (turnover up to ₦100 million, fixed assets up to ₦250 million, no professional services) may stop charging VAT.';
  end if;
  if not v_charge and (st->>'crossed')::boolean then raise exception 'Turnover this year is above ₦100 million, so VAT must be charged.'; end if;
  update orgs set vat_registered = v_charge, vat_opt_in = v_charge and (st->>'small')::boolean where id = p_org;
  return public.vat_status(p_org);
end $$;

-- p: {from, to} -> the months with their VAT, credits and status, and the business's VAT status.
create or replace function public.vat_position(p_org uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
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
    'can_file', private.perm_of(m, 'keep_books'), 'can_pay', private.perm_of(m, 'keep_books') or private.perm_of(m, 'make_payments'));
end $$;

-- Files a month: freezes its figures and settles 2201, 1402 and 1405 for it, leaving what is payable in 2201 and the credit
-- carried forward in 1402. Lapsed credits go to 6512; a refund claimed moves to 1404. p: {refund_claim, notes}.
create or replace function public.file_vat_return(p_org uuid, p_period date, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_period date := date_trunc('month', p_period)::date; x jsonb; ch jsonb; j public.journals; v_refund numeric := round(coalesce(private.num(p->>'refund_claim'), 0), 2);
  v_jl jsonb; v_refundable numeric; v_end date;
begin
  m := private.require(p_org, 'keep_books');
  if v_period is null then raise exception 'Choose the month.'; end if;
  v_end := (v_period + interval '1 month' - interval '1 day')::date;
  if v_end >= private.local_day(p_org, now()) then raise exception 'File % after the month ends.', to_char(v_period, 'FMMonth YYYY'); end if;
  if exists (select 1 from vat_periods where org_id = p_org and period = v_period) then raise exception 'The % return is already filed.', to_char(v_period, 'FMMonth YYYY'); end if;
  perform private.require_open_day(p_org, v_end);
  ch := private.vat_chain(p_org, v_period);
  x := ch->-1;
  if x is null or (x->>'period')::date <> v_period then raise exception 'Nothing to file for %.', to_char(v_period, 'FMMonth YYYY'); end if;
  if v_refund < 0 then raise exception 'The refund cannot be negative.'; end if;
  v_refundable := (select coalesce(sum((l->>'amount')::numeric), 0) from jsonb_array_elements(x->'layers') l where (l->>'from')::date >= (v_period - interval '11 months')::date);
  if v_refund > v_refundable + 0.004 then
    raise exception 'A refund can only be claimed within 12 months; up to % of the credit qualifies.', private.naira(v_refundable);
  end if;
  v_jl := jsonb_build_array(
    jsonb_build_object('code', private.acct(p_org, 'output_vat'), 'debit', (x->>'output')::numeric - (x->>'payable')::numeric, 'memo', 'Output VAT for ' || to_char(v_period, 'FMMonth YYYY')),
    jsonb_build_object('code', private.acct(p_org, 'vat_withheld_by_customers'), 'credit', (x->>'wvat_credit')::numeric, 'memo', 'VAT withheld by customers, credited'),
    jsonb_build_object('code', private.acct(p_org, 'input_vat'), 'credit', (x->>'input')::numeric + (x->>'credit_used')::numeric - (x->>'new_credit')::numeric,
      'memo', 'Input VAT claimed' || case when (x->>'credit_used')::numeric > 0 then ', with ' || private.naira((x->>'credit_used')::numeric) || ' brought forward' else '' end),
    jsonb_build_object('code', '6512', 'debit', (x->>'credit_expired')::numeric, 'memo', 'Input VAT credit more than five years old'),
    jsonb_build_object('code', private.acct(p_org, 'input_vat'), 'credit', (x->>'credit_expired')::numeric, 'memo', 'Input VAT credit lapsed'),
    jsonb_build_object('code', '1404', 'debit', v_refund, 'memo', 'VAT refund claimed from the NRS'),
    jsonb_build_object('code', private.acct(p_org, 'input_vat'), 'credit', v_refund, 'memo', 'Input VAT credit claimed as a refund'));
  if exists (select 1 from jsonb_array_elements(v_jl) l where coalesce((l->>'debit')::numeric, 0) <> 0 or coalesce((l->>'credit')::numeric, 0) <> 0) then
    j := private.post_entry(p_org, 'VAT return for ' || to_char(v_period, 'FMMonth YYYY'), 'vat_return', null, m.id, m.id, v_jl, private.posting_time(p_org, v_end),
      jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'vat_return', 'period', v_period, 'payable', x->'payable', 'by', m.display_name))));
  end if;
  insert into vat_periods (org_id, period, output_vat, input_vat, wvat_credit, credit_bf, credit_used, credit_expired, payable, new_credit, refund_claimed, credit_cf,
    layers, status, filed_at, filed_by, journal_id, notes)
  values (p_org, v_period, (x->>'output')::numeric, (x->>'input')::numeric, (x->>'wvat_credit')::numeric, (x->>'credit_bf')::numeric, (x->>'credit_used')::numeric,
    (x->>'credit_expired')::numeric, (x->>'payable')::numeric, (x->>'new_credit')::numeric, v_refund, (x->>'credit_cf')::numeric - v_refund, x->'layers',
    case when (x->>'payable')::numeric = 0 then 'paid' else 'filed' end, now(), m.id, j.id, nullif(trim(p->>'notes'), ''));
  return public.vat_position(p_org, jsonb_build_object('from', v_period, 'to', v_period));
end $$;

-- Pays a filed month: Dr 2201 / Cr bank. p: {bank_account_id, paid_at, reference}.
create or replace function public.record_vat_payment(p_org uuid, p_period date, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; vp public.vat_periods; ba public.bank_accounts; j public.journals; v_at timestamptz;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'make_payments') or private.perm_of(m, 'keep_books')) then
    raise exception 'Only someone who makes payments or keeps the books records a tax payment.' using errcode = '42501';
  end if;
  select * into vp from vat_periods where org_id = p_org and period = date_trunc('month', p_period)::date for update;
  if not found then raise exception 'File the % return first.', to_char(p_period, 'FMMonth YYYY'); end if;
  if vp.status = 'paid' then raise exception 'The % VAT is already paid.', to_char(vp.period, 'FMMonth YYYY'); end if;
  select * into ba from bank_accounts where id = nullif(p->>'bank_account_id', '')::uuid and org_id = p_org and active;
  if not found then raise exception 'Choose the account it was paid from.'; end if;
  v_at := least(coalesce(nullif(p->>'paid_at', '')::timestamptz, now()), now());
  perform private.require_open_day(p_org, private.local_day(p_org, v_at));
  j := private.post_entry(p_org, 'VAT paid to the NRS for ' || to_char(vp.period, 'FMMonth YYYY'), 'tax_payment', null, m.id, m.id, jsonb_build_array(
      jsonb_build_object('code', private.acct(p_org, 'output_vat'), 'debit', vp.payable, 'memo', 'VAT for ' || to_char(vp.period, 'FMMonth YYYY')),
      jsonb_build_object('code', ba.ledger_code, 'credit', vp.payable, 'memo', coalesce(nullif(trim(p->>'reference'), ''), 'NRS VAT'))), v_at,
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'tax_payment', 'ref', nullif(trim(p->>'reference'), ''), 'authority', 'NRS', 'by', m.display_name))));
  update vat_periods set status = 'paid', paid_at = v_at, payment_journal_id = j.id, reference = nullif(trim(p->>'reference'), '') where org_id = p_org and period = vp.period;
  return public.vat_position(p_org, jsonb_build_object('from', vp.period, 'to', vp.period));
end $$;

-- Takes a filed (unpaid) month back: its journal is reversed and the month is open again.
create or replace function public.reopen_vat_return(p_org uuid, p_period date, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; vp public.vat_periods;
begin
  m := private.require(p_org, 'keep_books');
  select * into vp from vat_periods where org_id = p_org and period = date_trunc('month', p_period)::date for update;
  if not found then raise exception 'The % return is not filed.', to_char(p_period, 'FMMonth YYYY'); end if;
  if vp.payment_journal_id is not null then raise exception 'The % VAT is paid. File a correction with the NRS instead.', to_char(vp.period, 'FMMonth YYYY'); end if;
  if exists (select 1 from vat_periods where org_id = p_org and period > vp.period) then raise exception 'Reopen the later months first.'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Say why the return is reopened.'; end if;
  if vp.journal_id is not null then perform private.reverse_entry(vp.journal_id, m.id, 'VAT return reopened: ' || left(trim(p_reason), 200), null); end if;
  delete from vat_periods where org_id = p_org and period = vp.period;
  return public.vat_position(p_org, jsonb_build_object('from', vp.period, 'to', vp.period));
end $$;

-- Every morning: a business not charging VAT whose turnover this year has passed ₦100 million is told it must start.
create or replace function private.vat_threshold_tick() returns void
language plpgsql security definer set search_path = public, private as $$
declare o record; st jsonb;
begin
  for o in select id from orgs where not vat_registered and not is_sample loop
    st := private.vat_small_status(o.id);
    if (st->>'crossed')::boolean then
      perform private.notify(o.id, (select user_id from members where org_id = o.id and role = 'owner' and status = 'active' order by created_at limit 1), 'tax',
        'Turnover has passed ₦100 million: start charging VAT',
        'Sales this year come to ' || private.naira((st->>'year_to_date')::numeric) || '. A business above the small company limit must charge VAT. Turn it on under Accounting, Tax returns, VAT.',
        '/accounting/tax?tab=vat', 'vat-threshold-' || extract(year from (st->>'year_from')::date));
    end if;
  end loop;
end $$;
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'counta-vat-threshold';
    perform cron.schedule('counta-vat-threshold', '10 6 * * *', 'select private.vat_threshold_tick()');
  end if;
end $$;

-- The VAT return report for any period, with VAT self-charged on services from abroad and VAT customers withheld.
create or replace function private.vat_rows(p_org uuid, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = public, private as $$
  with sl as (select s.doc_type, s.export, l.vat_treatment, l.net, l.vat from sales s join sale_lines l on l.sale_id = s.id
              where s.org_id = p_org and s.journal_id is not null and s.status <> 'void' and s.channel <> 'import' and s.issue_date between p_from and p_to),
  so as (select coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'standard'), 0) std,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'zero'), 0) zero,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'zero' and export), 0) exports,
                coalesce(sum(case when doc_type = 'credit_note' then -net else net end) filter (where vat_treatment = 'exempt'), 0) exempt,
                coalesce(sum(case when doc_type = 'credit_note' then -vat else vat end), 0) vat from sl),
  bi as (select coalesce(sum(bl.vat) filter (where bl.vat_recoverable), 0) vat, coalesce(sum(bl.net) filter (where bl.vat > 0), 0) base,
                coalesce(sum(bl.reverse_charge_vat) filter (where bl.vat_recoverable), 0) rc, coalesce(sum(bl.net) filter (where bl.reverse_charge_vat > 0), 0) rc_base
         from bills b join bill_lines bl on bl.bill_id = b.id
         where b.org_id = p_org and b.source not in ('receipt', 'import') and b.journal_id is not null and b.status <> 'void' and b.bill_date between p_from and p_to),
  rc as (select coalesce(sum(input_vat), 0) vat, coalesce(sum(net) filter (where input_vat > 0), 0) base from receipts
         where org_id = p_org and status = 'posted' and private.local_day(org_id, coalesce(posted_at, created_at)) between p_from and p_to),
  vcr as (select coalesce(sum(vat_total), 0) vat, coalesce(sum(subtotal) filter (where vat_total > 0), 0) base from vendor_credits
          where org_id = p_org and status <> 'void' and journal_id is not null and credit_date between p_from and p_to),
  wv as (select coalesce(sum(amount), 0) vat from collections where org_id = p_org and method = 'wvat_credit' and status = 'confirmed' and journal_id is not null
           and private.local_day(org_id, received_at) between p_from and p_to),
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
    private.fr('VAT self-charged on services from abroad (value ' || to_char(bi.rc_base, 'FM999,999,999,990.00') || ')', bi.rc, null, 'line', 1),
    private.fr('Stock received (taxable value ' || to_char(rc.base, 'FM999,999,999,990.00') || ')', rc.vat, null, 'line', 1),
    private.fr('Less credit notes from suppliers (taxable value ' || to_char(vcr.base, 'FM999,999,999,990.00') || ')', -vcr.vat, null, 'line', 1),
    private.fr('Input VAT recoverable', bi.vat + bi.rc + rc.vat - vcr.vat, null, 'subtotal', 0),
    private.fr('VAT withheld by customers (credited)', wv.vat, null, 'line', 0),
    private.fr('VAT payable / (credit) for the period, before credit brought forward', so.vat - bi.vat - bi.rc - rc.vat + vcr.vat - wv.vat, null, 'total', 0),
    private.fr('Ledger check', null, null, 'heading', 0),
    private.fr('Output VAT in the ledger (2201) from sales', led.out_ledger, null, 'line', 1),
    private.fr('Input VAT in the ledger (1402) from bills, receipts and supplier credit notes', led.in_ledger, null, 'line', 1),
    private.fr('Difference to explain', (so.vat - led.out_ledger) - (bi.vat + bi.rc + rc.vat - vcr.vat - led.in_ledger), null, 'subtotal', 0))
  from so, bi, rc, vcr, wv, led
$$;

-- Items the AI classified under the earlier lists are checked again against the rule book (choices people made stay).
update public.items set vat_checked_at = null where coalesce(vat_basis->>'source', '') in ('gemini', 'numens') and not archived;

-- ---------------------------------------------------------------------------
-- Suppliers, stock receipts and bills as the app reads them
-- ---------------------------------------------------------------------------
create or replace function public.save_vendor_details(p_org uuid, p_vendor uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v public.vendors;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'keep_books') or private.perm_of(m, 'make_payments') or private.perm_of(m, 'approve_pos')) then
    raise exception 'Your role does not change vendor details.' using errcode = '42501';
  end if;
  if p_patch ? 'wht_category' and nullif(p_patch->>'wht_category', '') is not null and not exists (select 1 from wht_rates where code = p_patch->>'wht_category') then
    raise exception 'Unknown withholding tax category.';
  end if;
  if coalesce(p_patch->>'account_number', '') <> '' and p_patch->>'account_number' !~ '^[0-9]{10}$' then raise exception 'Account numbers have 10 digits.'; end if;
  if nullif(p_patch->>'default_account', '') is not null and not private.bill_account_ok(p_org, p_patch->>'default_account') then
    raise exception 'Choose an expense, stock or asset account.';
  end if;
  if nullif(p_patch->>'entity_type', '') is not null and p_patch->>'entity_type' not in ('company', 'plc', 'llp', 'ltd_gte', 'business_name', 'sole_proprietor',
       'partnership', 'lp', 'individual', 'government', 'ngo') then
    raise exception 'Choose what kind of business the supplier is.';
  end if;
  if nullif(trim(p_patch->>'state'), '') is not null and private.state_code(p_patch->>'state') is null then raise exception 'Choose the supplier''s state.'; end if;
  if nullif(trim(p_patch->>'nin'), '') is not null and regexp_replace(p_patch->>'nin', '\D', '', 'g') !~ '^[0-9]{11}$' then raise exception 'A NIN has 11 digits.'; end if;
  update vendors set
    tin = case when p_patch ? 'tin' then private.tax_id_input(p_patch->>'tin', tin, 'The vendor''s Tax ID') else tin end,
    rc_number = case when p_patch ? 'rc_number' then nullif(trim(p_patch->>'rc_number'), '') else rc_number end,
    is_individual = coalesce((p_patch->>'is_individual')::boolean, case when p_patch ? 'entity_type' then p_patch->>'entity_type' = 'individual' end, is_individual),
    wht_category = case when p_patch ? 'wht_category' then nullif(p_patch->>'wht_category', '') else wht_category end,
    bank_code = case when p_patch ? 'bank_code' then nullif(p_patch->>'bank_code', '') else bank_code end,
    bank_name = case when p_patch ? 'bank_name' then nullif(p_patch->>'bank_name', '') else bank_name end,
    account_number = case when p_patch ? 'account_number' then nullif(p_patch->>'account_number', '') else account_number end,
    account_name = case when p_patch ? 'account_name' then nullif(trim(p_patch->>'account_name'), '') else account_name end,
    default_account = case when p_patch ? 'default_account' then nullif(p_patch->>'default_account', '') else default_account end,
    address = case when p_patch ? 'address' then nullif(trim(p_patch->>'address'), '') else address end,
    credit_days = coalesce((p_patch->>'credit_days')::int, credit_days),
    vat_registered = coalesce((p_patch->>'vat_registered')::boolean, vat_registered),
    entity_type = case when p_patch ? 'entity_type' then nullif(p_patch->>'entity_type', '') else entity_type end,
    resident = coalesce((p_patch->>'resident')::boolean, resident),
    country = case when p_patch ? 'country' then coalesce(nullif(upper(trim(p_patch->>'country')), ''), 'NG') else country end,
    state = case when p_patch ? 'state' then (select a.state from tax_authorities a where a.code = private.state_code(p_patch->>'state')) else state end,
    nin = case when p_patch ? 'nin' then nullif(regexp_replace(p_patch->>'nin', '\D', '', 'g'), '') else nin end,
    is_manufacturer = coalesce((p_patch->>'is_manufacturer')::boolean, is_manufacturer),
    wht_exempt = coalesce((p_patch->>'wht_exempt')::boolean, wht_exempt),
    digital_supplier = coalesce((p_patch->>'digital_supplier')::boolean, digital_supplier),
    connected_person = coalesce((p_patch->>'connected_person')::boolean, connected_person)
  where id = p_vendor and org_id = p_org returning * into v;
  if not found then raise exception 'Vendor not found.'; end if;
  -- Draft bills from the supplier follow the change.
  perform private.bill_wht(b.id) from bills b where b.vendor_id = v.id and b.status = 'draft';
  return to_jsonb(v) || jsonb_build_object('wht_profile', private.vendor_wht_profile(v.id));
end $$;

create or replace function private.bill_from_receipt(p_receipt uuid) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare r public.receipts; v public.vendors; b public.bills; v_paid numeric;
begin
  select * into r from receipts where id = p_receipt;
  if r.status <> 'posted' or r.vendor_id is null or r.journal_id is null then return null; end if;
  select id into b.id from bills where receipt_id = r.id;
  if b.id is not null then return b.id; end if;
  select * into v from vendors where id = r.vendor_id;
  insert into bills (org_id, number, vendor_id, vendor_ref, source, receipt_id, bill_date, due_date, prices_include_vat, vat_charged, status, subtotal, vat_total,
    total, wht_category, wht_rate, journal_id, document_path, created_by, approved_by, approved_at)
  values (r.org_id, 'BILL-' || lpad(private.next_no(r.org_id, 'BILL', 1)::text, 4, '0'), r.vendor_id, r.invoice_no, 'receipt', r.id,
    coalesce(r.invoice_date, private.local_day(r.org_id, coalesce(r.posted_at, r.created_at))),
    coalesce(r.invoice_date, private.local_day(r.org_id, coalesce(r.posted_at, r.created_at))) + coalesce(nullif(v.credit_days, 0), 30),
    coalesce(r.prices_include_vat, false), coalesce(r.vendor_vat_registered, true), 'approved', coalesce(r.net, 0), coalesce(r.input_vat, 0),
    coalesce(r.gross, coalesce(r.net, 0) + coalesce(r.input_vat, 0)), coalesce(v.wht_category, 'goods'), 0,
    r.journal_id, r.document_path, coalesce(r.posted_by, r.created_by), r.posted_by, r.posted_at)
  returning * into b;
  insert into bill_lines (bill_id, org_id, line_no, description, account_code, qty, unit_cost, vat_treatment, vat_recoverable, net, vat, gross)
  values (b.id, b.org_id, 1, 'Stock received · ' || r.ref, private.acct(r.org_id, 'inventory'), 1, b.subtotal, case when b.vat_total > 0 then 'standard' else 'none' end,
    true, b.subtotal, b.vat_total, b.total);
  b := private.bill_wht(b.id);
  -- Anything already paid against this receipt in the ledger counts.
  select coalesce(sum(debit), 0) into v_paid from journal_lines where org_id = r.org_id and account_code in ('2101', '2102') and doc_type = 'receipt' and doc_id = r.id
    and journal_id <> r.journal_id;
  if v_paid > 0 then
    insert into bill_payments (org_id, bill_id, method, status, gross, wht, net, paid_at, reference)
    values (b.org_id, b.id, 'bank', 'paid', least(v_paid, b.total), 0, least(v_paid, b.total), now(), 'Paid before bills were kept');
    perform private.refresh_bill(b.id);
  end if;
  return b.id;
end $$;

create or replace function private.bill_json(p_bill uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select to_jsonb(b) || jsonb_build_object(
    'vendor', (select jsonb_build_object('id', v.id, 'name', v.name, 'tin', v.tin, 'is_individual', v.is_individual, 'bank_code', v.bank_code, 'bank_name', v.bank_name,
        'account_number', v.account_number, 'account_name', v.account_name, 'wht_category', v.wht_category, 'entity_type', v.entity_type, 'resident', v.resident,
        'state', v.state, 'rc_number', v.rc_number, 'nin', v.nin, 'is_manufacturer', v.is_manufacturer, 'wht_exempt', v.wht_exempt,
        'wht_profile', private.vendor_wht_profile(v.id)) from vendors v where v.id = b.vendor_id),
    'balance', case when b.status in ('approved', 'partially_paid') then b.total - b.amount_paid else 0 end,
    'in_progress', (select coalesce(sum(gross), 0) from bill_payments where bill_id = b.id and status = 'processing'),
    'to_withhold', case when b.status in ('approved', 'partially_paid') then private.bill_withholding(b.id, b.total - b.amount_paid) end,
    'overdue_days', case when b.status in ('approved', 'partially_paid') then greatest(private.local_day(b.org_id, now()) - b.due_date, 0) end,
    'lines', (select coalesce(jsonb_agg(to_jsonb(l) - 'org_id' || jsonb_build_object('account_name', private.account_name(b.org_id, l.account_code),
        'creditable', private.bill_line_creditable(l.id), 'wht_category_effective', coalesce(l.wht_category, b.wht_category)) order by l.line_no), '[]'::jsonb)
              from bill_lines l where l.bill_id = b.id),
    'payments', (select coalesce(jsonb_agg(to_jsonb(p) - 'org_id' || jsonb_build_object('payout_number', (select number from payouts where id = p.payout_id),
        'payout_status', (select status from payouts where id = p.payout_id)) order by p.paid_at), '[]'::jsonb) from bill_payments p where p.bill_id = b.id),
    'deductions', (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'category', d.category, 'amount', d.amount, 'base', d.base, 'rate', d.rate,
        'authority', d.authority, 'authority_name', (select case when a.code = 'NRS' then 'NRS' else a.state || ' (' || coalesce(a.short_name, a.name) || ')' end
          from tax_authorities a where a.code = d.authority),
        'due_date', d.due_date, 'status', d.status, 'receipt_no', d.receipt_no) order by d.created_at), '[]'::jsonb)
        from wht_deductions d where d.bill_id = b.id and d.status <> 'void'),
    'credit_notes', (select coalesce(jsonb_agg(jsonb_build_object('id', vc.id, 'number', vc.number, 'vendor_ref', vc.vendor_ref, 'total', vc.total, 'credit_date', vc.credit_date,
        'reason', vc.reason, 'status', vc.status) order by vc.credit_date), '[]'::jsonb) from vendor_credits vc where vc.bill_id = b.id and vc.status <> 'void'),
    'supplier_credit', (select coalesce(sum(vc.total - vc.applied - vc.refunded), 0) from vendor_credits vc where vc.vendor_id = b.vendor_id and vc.status = 'open'),
    'assets', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'number', a.number, 'name', a.name, 'status', a.status)), '[]'::jsonb) from fixed_assets a where a.bill_id = b.id),
    'journal_ref', (select ref from journals where id = b.journal_id),
    'created_by_name', (select display_name from members where id = b.created_by),
    'approved_by_name', (select display_name from members where id = b.approved_by))
  from bills b where b.id = p_bill
$$;

-- ---------------------------------------------------------------------------
-- Customers who withhold: WHT credit notes (1401) and VAT a withholding VAT agent kept (1405)
-- ---------------------------------------------------------------------------
-- What a short payment of p_amt against a sale with p_due left means: WHT at a standard rate and, for a customer who is a
-- withholding VAT agent, the sale's VAT not yet credited. Null when the shortfall is something else.
create or replace function private.customer_short_split(p_sale uuid, p_due numeric, p_amt numeric) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare s public.sales; v_agent boolean; v_vat numeric := 0; r numeric;
begin
  select * into s from sales where id = p_sale;
  if s.id is null or p_amt >= p_due - 0.004 then return null; end if;
  select coalesce(wvat_agent, false) into v_agent from customers where id = s.customer_id;
  if v_agent then
    v_vat := greatest(s.vat_total - coalesce((select sum(a.amount) from collection_allocations a join collections c on c.id = a.collection_id
      where a.sale_id = s.id and c.method = 'wvat_credit' and c.status = 'confirmed'), 0), 0);
  end if;
  foreach r in array array[0, 0.02, 0.05, 0.10] loop
    continue when r = 0 and v_vat = 0;
    if abs(round(p_due - v_vat - round(s.subtotal * r, 2), 2) - p_amt) < 0.005 then
      return jsonb_build_object('wht', round(s.subtotal * r, 2), 'wht_rate', r, 'wvat', v_vat);
    end if;
  end loop;
  return null;
end $$;

create or replace function private.book_customer_withholding(p_org uuid, p_customer uuid, p_sale uuid, p_split jsonb, p_at timestamptz, m public.members) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if coalesce((p_split->>'wvat')::numeric, 0) > 0 then
    perform private.add_collection(p_org, p_customer, (p_split->>'wvat')::numeric, 'wvat_credit', jsonb_build_object('reference', 'VAT withheld',
      'received_at', p_at, 'note', 'VAT the customer withholds and pays to the NRS; credited in the VAT return', 'spread', false), m, 'confirmed', array[p_sale]);
  end if;
  if coalesce((p_split->>'wht')::numeric, 0) > 0 then
    perform private.add_collection(p_org, p_customer, (p_split->>'wht')::numeric, 'wht_credit', jsonb_build_object('reference', 'WHT deducted',
      'wht_rate', p_split->'wht_rate', 'received_at', p_at, 'note', 'Collect the WHT credit note', 'spread', false), m, 'confirmed', array[p_sale]);
  end if;
end $$;

create or replace function private.post_collection(p_collection uuid, m public.members) returns public.collections
language plpgsql security definer set search_path = public, private as $$
declare c public.collections; b public.bank_accounts; v_alloc numeric := 0; v_jl jsonb; j public.journals; v_target text; a record; v_due numeric;
  v_cust text; v_party_target boolean;
begin
  select * into c from collections where id = p_collection for update;
  if c.journal_id is not null then return c; end if;
  if c.status <> 'confirmed' then raise exception 'Only confirmed payments post.'; end if;
  select name into v_cust from customers where id = c.customer_id;
  if c.method not in ('wht_credit', 'wvat_credit', 'advance') then
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
                when 'advance' then private.acct(c.org_id, 'customer_advances') else b.ledger_code end;
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
      when c.method = 'wvat_credit' then 'VAT withheld by customer ' else 'Payment received ' end || c.number || ' · ' || v_cust,
    'collection', c.id, coalesce(m.id, c.confirmed_by, c.created_by), c.confirmed_by, v_jl, c.received_at,
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', case when c.provider_ref is not null then 'provider' else 'confirmation' end,
      'ref', coalesce(c.provider_ref, c.reference), 'method', c.method, 'confirmed_by', c.confirmed_by))));
  update collections set journal_id = j.id where id = c.id returning * into c;
  for a in select sale_id from collection_allocations where collection_id = c.id loop
    perform private.refresh_sale(a.sale_id);
  end loop;
  return c;
end $$;

-- p_payment: {customer_id | sale_id, amount, method, bank_account_id, confirmed, reference, wht_amount, wht_rate, wvat_amount, ...}
create or replace function public.record_payment(p_org uuid, p_payment jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; c public.collections; v_cust uuid := nullif(p_payment->>'customer_id', '')::uuid; v_sale uuid := nullif(p_payment->>'sale_id', '')::uuid;
  v_method text := coalesce(nullif(p_payment->>'method', ''), 'transfer'); v_status text; v_wht numeric; v_wvat numeric; s public.sales;
  v_amt numeric := round(private.num(p_payment->>'amount'), 2); v_confirmer boolean; v_bank uuid := nullif(p_payment->>'bank_account_id', '')::uuid;
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
  -- WHT the customer deducted is a credit against tax, not money (AR-03): Dr 1401 / Cr 1101.
  v_wht := round(private.num(p_payment->>'wht_amount'), 2);
  if coalesce(v_wht, 0) > 0 then
    perform private.add_collection(p_org, v_cust, v_wht, 'wht_credit', jsonb_build_object('reference', 'WHT deducted', 'wht_rate', nullif(p_payment->>'wht_rate', ''),
      'note', 'Collect the withholding tax credit note from the customer', 'spread', v_sale is null), m, 'confirmed', case when v_sale is not null then array[v_sale] end);
  end if;
  -- VAT a customer who is a withholding VAT agent kept: credited in our VAT return (Dr 1405 / Cr 1101).
  v_wvat := round(private.num(p_payment->>'wvat_amount'), 2);
  if coalesce(v_wvat, 0) > 0 then
    if v_sale is not null and v_wvat > s.vat_total + 0.004 then raise exception 'The VAT withheld cannot be more than the VAT on %.', s.number; end if;
    perform private.add_collection(p_org, v_cust, v_wvat, 'wvat_credit', jsonb_build_object('reference', 'VAT withheld',
      'note', 'VAT the customer withholds and pays to the NRS; credited in the VAT return', 'spread', v_sale is null), m, 'confirmed', case when v_sale is not null then array[v_sale] end);
  end if;
  if coalesce(v_amt, 0) > 0 then
    c := private.add_collection(p_org, v_cust, v_amt, v_method, (p_payment - 'wht_amount' - 'wvat_amount' - 'confirmed' - 'fee') || jsonb_build_object('bank_account_id', v_bank),
      m, v_status, case when v_sale is not null then array[v_sale] end);
  elsif coalesce(v_wht, 0) = 0 and coalesce(v_wvat, 0) = 0 then
    raise exception 'Enter the amount paid.';
  end if;
  return jsonb_build_object('collection', to_jsonb(c), 'sale', case when v_sale is not null then private.sale_json(v_sale, private.can_see_costs(p_org)) end);
end $$;

-- ---------------------------------------------------------------------------
-- Remitting, receipts, schedules
-- ---------------------------------------------------------------------------
-- p: {kind: wht|wvat, authority, period: 'YYYY-MM-01', bank_account_id, paid_at, reference, amount (optional check)}. Pays what was
-- deducted for that authority and month: Dr 2202 (WHT) or 2211 (withholding and self-charged VAT) / Cr bank.
create or replace function public.record_wht_remittance(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; v_kind text := coalesce(nullif(p->>'kind', ''), 'wht'); v_auth text := nullif(p->>'authority', ''); v_period date; v_amt numeric;
  ba public.bank_accounts; j public.journals; rm public.wht_remittances; v_at timestamptz; v_n int;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'make_payments') or private.perm_of(m, 'keep_books')) then
    raise exception 'Only someone who makes payments or keeps the books records a tax payment.' using errcode = '42501';
  end if;
  if v_kind not in ('wht', 'wvat') then raise exception 'Say whether this pays WHT or withholding VAT.'; end if;
  if v_auth is null or not exists (select 1 from tax_authorities where code = v_auth) then raise exception 'Choose who it was paid to.'; end if;
  if v_kind = 'wvat' and v_auth <> 'NRS' then raise exception 'Withholding VAT is paid to the NRS.'; end if;
  v_period := date_trunc('month', nullif(p->>'period', '')::date)::date;
  if v_period is null then raise exception 'Choose the month it covers.'; end if;
  select coalesce(sum(amount), 0), count(*) into v_amt, v_n from wht_deductions where org_id = p_org and authority = v_auth and period = v_period and status = 'deducted'
    and (kind = 'wht') = (v_kind = 'wht');
  if v_n = 0 then raise exception 'Nothing deducted for % in % is waiting to be paid.', v_auth, to_char(v_period, 'FMMonth YYYY'); end if;
  if nullif(p->>'amount', '') is not null and abs(private.num(p->>'amount') - v_amt) >= 0.005 then
    raise exception 'The % schedule for % comes to %, not %.', v_auth, to_char(v_period, 'FMMonth YYYY'), private.naira(v_amt), private.naira(private.num(p->>'amount'));
  end if;
  select * into ba from bank_accounts where id = nullif(p->>'bank_account_id', '')::uuid and org_id = p_org and active;
  if not found then raise exception 'Choose the account it was paid from.'; end if;
  v_at := least(coalesce(nullif(p->>'paid_at', '')::timestamptz, now()), now());
  perform private.require_open_day(p_org, private.local_day(p_org, v_at));
  j := private.post_entry(p_org, case when v_kind = 'wht' then 'WHT' else 'Withholding VAT' end || ' paid to ' || (select coalesce(short_name, name) from tax_authorities where code = v_auth)
      || ' for ' || to_char(v_period, 'FMMonth YYYY'), 'tax_payment', null, m.id, m.id, jsonb_build_array(
      jsonb_build_object('code', private.acct(p_org, case when v_kind = 'wht' then 'wht_payable' else 'wvat_payable' end), 'debit', v_amt,
        'memo', v_n || ' deduction' || case when v_n = 1 then '' else 's' end || ' · ' || v_auth),
      jsonb_build_object('code', ba.ledger_code, 'credit', v_amt, 'memo', coalesce(nullif(trim(p->>'reference'), ''), v_auth))), v_at,
    jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'tax_payment', 'ref', nullif(trim(p->>'reference'), ''), 'authority', v_auth, 'by', m.display_name))));
  insert into wht_remittances (org_id, kind, authority, period, amount, paid_at, bank_account_id, reference, receipt_path, journal_id, created_by)
  values (p_org, v_kind, v_auth, v_period, v_amt, v_at, ba.id, nullif(trim(p->>'reference'), ''), nullif(p->>'receipt_path', ''), j.id, m.id) returning * into rm;
  update wht_deductions set status = 'remitted', remittance_id = rm.id where org_id = p_org and authority = v_auth and period = v_period and status = 'deducted'
    and (kind = 'wht') = (v_kind = 'wht');
  return jsonb_build_object('remittance', to_jsonb(rm), 'journal_ref', j.ref, 'deductions', v_n);
end $$;

-- The receipt a supplier claims its credit with: who deducted, from whom, for what, how much, for which month.
create or replace function private.wht_receipt_json(p_deduction uuid) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('id', d.id, 'receipt_no', d.receipt_no, 'kind', d.kind, 'issued_on', d.deducted_on, 'month', d.period, 'status', d.status,
    'payer', jsonb_build_object('name', o.name, 'address', coalesce(o.registered_office, o.address), 'tin', o.tin, 'rc_number', o.rc_number),
    'beneficiary', jsonb_build_object('name', v.name, 'address', v.address, 'tin', v.tin, 'rc_number', v.rc_number, 'nin', v.nin,
      'id_type', d.beneficiary_type, 'id_number', d.beneficiary_number),
    'nature', case d.kind when 'wht' then coalesce(r.name, 'Withholding tax') when 'wvat' then 'VAT withheld' else 'VAT self-charged' end,
    'description', d.description, 'transaction_amount', d.base, 'amount_settled', coalesce(bp.gross, d.base), 'rate', d.rate, 'doubled', d.doubled, 'deducted', d.amount,
    'authority', jsonb_build_object('code', a.code, 'name', a.name, 'short_name', a.short_name), 'due_date', d.due_date,
    'bill', jsonb_build_object('number', b.number, 'vendor_ref', b.vendor_ref, 'bill_date', b.bill_date))
  from wht_deductions d join orgs o on o.id = d.org_id join vendors v on v.id = d.vendor_id join bills b on b.id = d.bill_id
  left join bill_payments bp on bp.id = d.bill_payment_id left join wht_rates r on r.code = d.category left join tax_authorities a on a.code = d.authority
  where d.id = p_deduction
$$;

-- p: {vendor_id, from, to, id} -> the receipts (one when id is given).
create or replace function public.wht_receipts(p_org uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Withholding tax records need See margins, Keep the books or Make payments.' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(private.wht_receipt_json(d.id) order by d.deducted_on desc, d.receipt_no desc), '[]'::jsonb)
    from wht_deductions d where d.org_id = p_org and d.status in ('deducted', 'remitted') and d.receipt_no is not null and d.kind <> 'reverse_charge'
      and (nullif(p->>'id', '') is null or d.id = (p->>'id')::uuid)
      and (nullif(p->>'vendor_id', '') is null or d.vendor_id = (p->>'vendor_id')::uuid)
      and (nullif(p->>'from', '') is null or d.deducted_on >= (p->>'from')::date)
      and (nullif(p->>'to', '') is null or d.deducted_on <= (p->>'to')::date));
end $$;

-- A month's schedule for one authority, in the columns of its template. kind wht: the NRS schedule (or a state's); kind wvat:
-- the withholding VAT schedule (supplier, Tax ID, address, invoice, amount, VAT, month).
create or replace function private.wht_schedule(p_org uuid, p_period date, p_authority text, p_kind text default 'wht') returns jsonb
language sql stable security definer set search_path = public, private as $$
  with d as (
    select d.*, v.name vname, v.address vaddress, b.number bnumber, b.vendor_ref, b.bill_date, b.subtotal bsubtotal, b.vat_total bvat
    from wht_deductions d join vendors v on v.id = d.vendor_id join bills b on b.id = d.bill_id
    where d.org_id = p_org and d.period = date_trunc('month', p_period)::date and d.authority is not distinct from p_authority
      and d.status in ('deducted', 'remitted') and case when p_kind = 'wht' then d.kind = 'wht' else d.kind in ('wvat', 'reverse_charge') end)
  select jsonb_build_object('authority', p_authority, 'kind', p_kind, 'period', date_trunc('month', p_period)::date,
    'authority_name', (select name from tax_authorities where code = p_authority),
    'due_date', private.wht_due(case when p_kind = 'wht' then 'wht' else 'wvat' end, p_authority, null, date_trunc('month', p_period)::date),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'beneficiary_name', d.vname, 'beneficiary_type', d.beneficiary_type,
        'beneficiary_number', d.beneficiary_number, 'address', d.vaddress, 'transaction_date', d.deducted_on, 'description', d.description, 'amount', d.base,
        'transaction_type', d.nrs_code, 'recipient_type', d.recipient_type, 'resident_type', case when d.resident then 'RESIDENT' else 'NON_RESIDENT' end,
        'rate', d.rate, 'wht', d.amount, 'invoice', coalesce(d.vendor_ref, d.bnumber), 'invoice_amount', d.bsubtotal + d.bvat, 'category', d.category,
        'receipt_no', d.receipt_no, 'status', d.status, 'state_assumed', d.state_assumed) order by d.deducted_on, d.vname) from d), '[]'::jsonb),
    'total', (select coalesce(sum(amount), 0) from d), 'outstanding', (select coalesce(sum(amount), 0) from d where status = 'deducted'),
    'checks', coalesce((select jsonb_agg(x) from (
        select jsonb_build_object('severity', 'block', 'text', vname || ' has no Tax ID, RC number or NIN; the schedule needs one of them.') x from d where beneficiary_type is null
        union all
        select jsonb_build_object('severity', 'warn', 'text', 'The state of ' || vname || ' is not known; this assumes your own state. Add it to the supplier.') from d where state_assumed
        union all
        select jsonb_build_object('severity', 'warn', 'text', vname || ': no NRS transaction type for ' || coalesce(category, 'this deduction') || '.') from d
          where p_kind = 'wht' and p_authority = 'NRS' and nrs_code is null) y), '[]'::jsonb))
$$;

create or replace function public.wht_schedule(p_org uuid, p_period date, p_authority text, p_kind text default 'wht') returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Withholding tax records need See margins, Keep the books or Make payments.' using errcode = '42501'; end if;
  if p_kind not in ('wht', 'wvat') then raise exception 'Choose the WHT or the withholding VAT schedule.'; end if;
  return private.wht_schedule(p_org, p_period, p_authority, p_kind)
    || jsonb_build_object('org', (select jsonb_build_object('name', name, 'tin', tin, 'rc_number', rc_number, 'address', coalesce(registered_office, address)) from orgs where id = p_org));
end $$;

-- Everything withheld, by month and authority: deducted, paid over, still to pay and when; with the ledger alongside.
create or replace function public.withholding_overview(p_org uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v_from date := coalesce(nullif(p->>'from', '')::date, (date_trunc('month', private.local_day(p_org, now())) - interval '11 months')::date);
  v_to date := coalesce(nullif(p->>'to', '')::date, private.local_day(p_org, now())); v_today date := private.local_day(p_org, now());
begin
  m := private.require(p_org, null);
  if not private.can_handle_money(p_org) then raise exception 'Withholding tax records need See margins, Keep the books or Make payments.' using errcode = '42501'; end if;
  return jsonb_build_object('from', v_from, 'to', v_to,
    'groups', (select coalesce(jsonb_agg(g order by g->>'period' desc, g->>'kind', g->>'authority'), '[]'::jsonb) from (
      select jsonb_build_object('period', d.period, 'kind', case when d.kind = 'wht' then 'wht' else 'wvat' end, 'authority', d.authority,
        'authority_name', a.name, 'short_name', a.short_name, 'deductions', count(*), 'deducted', sum(d.amount),
        'remitted', coalesce(sum(d.amount) filter (where d.status = 'remitted'), 0), 'outstanding', coalesce(sum(d.amount) filter (where d.status = 'deducted'), 0),
        'pending', coalesce(sum(d.amount) filter (where d.status = 'pending'), 0), 'due_date', min(d.due_date),
        'overdue', bool_or(d.status = 'deducted' and d.due_date < v_today), 'state_assumed', bool_or(d.state_assumed),
        'missing_id', bool_or(d.beneficiary_type is null and d.kind = 'wht')) g
      from wht_deductions d left join tax_authorities a on a.code = d.authority
      where d.org_id = p_org and d.status <> 'void' and d.period between date_trunc('month', v_from)::date and v_to
      group by d.period, case when d.kind = 'wht' then 'wht' else 'wvat' end, d.authority, a.name, a.short_name) z),
    'remittances', (select coalesce(jsonb_agg(to_jsonb(r) || jsonb_build_object('journal_ref', (select ref from journals where id = r.journal_id)) order by r.paid_at desc), '[]'::jsonb)
      from wht_remittances r where r.org_id = p_org and r.period between date_trunc('month', v_from)::date and v_to),
    'ledger', jsonb_build_object(
      'wht_payable', (select coalesce(sum(credit - debit), 0) from journal_lines where org_id = p_org and split_part(account_code, '-', 1) = '2202'),
      'wht_outstanding', (select coalesce(sum(amount), 0) from wht_deductions where org_id = p_org and kind = 'wht' and status in ('deducted', 'pending')),
      'wvat_payable', (select coalesce(sum(credit - debit), 0) from journal_lines where org_id = p_org and split_part(account_code, '-', 1) = '2211'),
      'wvat_outstanding', (select coalesce(sum(amount), 0) from wht_deductions where org_id = p_org and kind <> 'wht' and status in ('deducted', 'pending'))),
    'rates', (select jsonb_agg(jsonb_build_object('code', code, 'name', name, 'nrs_code', nrs_code, 'corp_res', rate_corp_res, 'corp_nonres', rate_corp_nonres,
        'ind_res', rate_ind_res, 'ind_nonres', rate_ind_nonres, 'exemption', exemption, 'note', note) order by sort) from wht_rates),
    'authorities', (select jsonb_agg(jsonb_build_object('code', code, 'name', name, 'short_name', short_name, 'state', state, 'website', website) order by sort) from tax_authorities));
end $$;

-- ---------------------------------------------------------------------------
-- The business's tax profile in one place (the Tax returns page and Settings read and write it)
-- ---------------------------------------------------------------------------
create or replace function public.tax_profile(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  return (select jsonb_build_object('legal_form', o.legal_form, 'industry', o.industry, 'tin', o.tin, 'rc_number', o.rc_number,
      'address', coalesce(o.registered_office, o.address), 'state_authority', private.state_code(coalesce(o.registered_office, o.address)),
      'state', (select a.state from tax_authorities a where a.code = private.state_code(coalesce(o.registered_office, o.address))),
      'fiscal_year_start', o.fiscal_year_start, 'books_start', o.books_start, 'commenced_on', o.commenced_on,
      'professional_services', o.professional_services, 'cit_profile', o.cit_profile, 'wvat_agent', o.wvat_agent, 'wht_small_company', o.wht_small_company,
      'vat_registered', o.vat_registered, 'vat_opt_in', o.vat_opt_in,
      'can_edit', private.perm_of(m, 'keep_books'), 'is_owner', m.role = 'owner',
      'authorities', (select jsonb_agg(jsonb_build_object('code', a.code, 'state', a.state, 'name', a.name, 'short_name', a.short_name, 'website', a.website) order by a.sort)
        from tax_authorities a),
      'wht_rates', (select jsonb_agg(to_jsonb(r) order by r.sort) from wht_rates r))
    from orgs o where o.id = p_org);
end $$;

-- A supplier's tax details for its screen: what was entered, and what follows from it for withholding tax.
create or replace function public.vendor_tax_details(p_org uuid, p_vendor uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; v public.vendors; pf jsonb; v_auth text;
begin
  m := private.require(p_org, null);
  select * into v from vendors where id = p_vendor and org_id = p_org;
  if not found then raise exception 'Vendor not found.'; end if;
  pf := private.vendor_wht_profile(v.id);
  v_auth := case when (pf->>'corporate')::boolean or not (pf->>'resident')::boolean then 'NRS' else pf->>'state' end;
  return jsonb_build_object('id', v.id, 'name', v.name, 'tin', v.tin, 'rc_number', v.rc_number, 'nin', v.nin, 'entity_type', v.entity_type,
    'is_individual', v.is_individual, 'resident', coalesce(v.resident, true), 'country', coalesce(v.country, 'NG'), 'state', v.state, 'address', v.address,
    'wht_category', v.wht_category, 'is_manufacturer', coalesce(v.is_manufacturer, false), 'wht_exempt', coalesce(v.wht_exempt, false),
    'digital_supplier', coalesce(v.digital_supplier, false), 'connected_person', coalesce(v.connected_person, false), 'vat_registered', v.vat_registered,
    'wht_profile', pf || jsonb_build_object('authority', v_auth, 'authority_name', (select coalesce(short_name, name) from tax_authorities where code = v_auth)),
    'wht_withheld', (select coalesce(sum(amount), 0) from wht_deductions where vendor_id = v.id and kind = 'wht' and status in ('deducted', 'remitted')));
end $$;

-- Customers: as before, and whether the customer is a withholding VAT agent (a bank, a telecom, an oil company, a government
-- body...) that keeps the VAT on our invoices and pays it to the NRS for us. Only a manager, an accountant or the owner sets it.
create or replace function public.save_customer(p_org uuid, p_customer jsonb) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare m public.members; c public.customers; v_country text; v_id uuid; v_agent boolean := (p_customer->>'wvat_agent')::boolean;
begin
  m := private.require(p_org, 'record_sales');
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
  v_id := private.upsert_customer(p_org, p_customer, m);
  if v_agent is not null then update customers set wvat_agent = v_agent where id = v_id; end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
revoke execute on function public.approve_cit_year(uuid, int),
  public.cit_import(uuid, int, jsonb),
  public.cit_pack(uuid, int),
  public.cit_year(uuid, int),
  public.cit_years(uuid),
  public.file_vat_return(uuid, date, jsonb),
  public.pay_bill(uuid, jsonb),
  public.post_tax_charge(uuid, date, date),
  public.record_payment(uuid, jsonb),
  public.record_vat_payment(uuid, date, jsonb),
  public.record_wht_remittance(uuid, jsonb),
  public.reopen_cit_year(uuid, int, text),
  public.reopen_vat_return(uuid, date, text),
  public.resolve_proposal(uuid, jsonb),
  public.save_cit_year(uuid, int, jsonb),
  public.save_customer(uuid, jsonb),
  public.save_tax_asset(uuid, jsonb),
  public.save_tax_profile(uuid, jsonb),
  public.save_tax_settings(uuid, date, jsonb),
  public.save_vendor_details(uuid, uuid, jsonb),
  public.set_asset_tax(uuid, jsonb),
  public.set_vat_charging(uuid, jsonb),
  public.tax_profile(uuid),
  public.vat_position(uuid, jsonb),
  public.vat_status(uuid),
  public.vendor_tax_details(uuid, uuid),
  public.wht_receipts(uuid, jsonb),
  public.wht_schedule(uuid, date, text, text),
  public.withholding_overview(uuid, jsonb)
  from public, anon;
grant execute on function public.approve_cit_year(uuid, int),
  public.cit_import(uuid, int, jsonb),
  public.cit_pack(uuid, int),
  public.cit_year(uuid, int),
  public.cit_years(uuid),
  public.file_vat_return(uuid, date, jsonb),
  public.pay_bill(uuid, jsonb),
  public.post_tax_charge(uuid, date, date),
  public.record_payment(uuid, jsonb),
  public.record_vat_payment(uuid, date, jsonb),
  public.record_wht_remittance(uuid, jsonb),
  public.reopen_cit_year(uuid, int, text),
  public.reopen_vat_return(uuid, date, text),
  public.resolve_proposal(uuid, jsonb),
  public.save_cit_year(uuid, int, jsonb),
  public.save_customer(uuid, jsonb),
  public.save_tax_asset(uuid, jsonb),
  public.save_tax_profile(uuid, jsonb),
  public.save_tax_settings(uuid, date, jsonb),
  public.save_vendor_details(uuid, uuid, jsonb),
  public.set_asset_tax(uuid, jsonb),
  public.set_vat_charging(uuid, jsonb),
  public.tax_profile(uuid),
  public.vat_position(uuid, jsonb),
  public.vat_status(uuid),
  public.vendor_tax_details(uuid, uuid),
  public.wht_receipts(uuid, jsonb),
  public.wht_schedule(uuid, date, text, text),
  public.withholding_overview(uuid, jsonb)
  to authenticated;
revoke execute on function public.svc_cit_flux_update(uuid, int, jsonb),
  public.svc_cit_pack(uuid, int)
  from public, anon, authenticated;
grant execute on function public.svc_cit_flux_update(uuid, int, jsonb),
  public.svc_cit_pack(uuid, int)
  to service_role;
revoke execute on function private.bill_from_receipt(uuid),
  private.bill_json(uuid),
  private.bill_wht(uuid),
  private.bill_withholding(uuid, numeric),
  private.book_customer_withholding(uuid, uuid, uuid, jsonb, timestamptz, public.members),
  private.bulk_row(uuid, jsonb, text),
  private.cit_assets(uuid),
  private.cit_books_cover(uuid, date, date),
  private.cit_books_figures(uuid, date, date),
  private.cit_ca(uuid, int, jsonb),
  private.cit_can_see(uuid),
  private.cit_cell_map(jsonb),
  private.cit_chain(uuid, int),
  private.cit_compute(uuid, int, jsonb, date),
  private.cit_declaration(uuid, jsonb),
  private.cit_default_category(text),
  private.cit_default_source(uuid, date, date),
  private.cit_first_year(uuid),
  private.cit_has_data(uuid, int),
  private.cit_item(text, numeric, text, boolean),
  private.cit_period(uuid, int),
  private.cit_run(uuid, int, date),
  private.cit_std(uuid),
  private.cit_totals(jsonb),
  private.cit_year_of(uuid, date),
  private.cit_yoa(int),
  private.customer_short_split(uuid, numeric, numeric),
  private.match_bank_line(uuid),
  private.post_bill(uuid, public.members),
  private.post_collection(uuid, public.members),
  private.rb(jsonb, variadic text[]),
  private.rbb(jsonb, variadic text[]),
  private.rbn(jsonb, variadic text[]),
  private.record_bill_payment(uuid, uuid, numeric, numeric, timestamptz, text, public.members, text),
  private.refresh_bill(uuid),
  private.rev360_asset_code(text),
  private.rev360_category(text),
  private.rulebook(int),
  private.state_code(text),
  private.sync_wht_deductions(),
  private.tax_computation(uuid, date, date),
  private.use_vendor_credit(uuid, uuid, numeric, public.members),
  private.vat_chain(uuid, date),
  private.vat_month(uuid, date),
  private.vat_rows(uuid, date, date),
  private.vat_small_status(uuid),
  private.vat_threshold_tick(),
  private.vendor_wht_profile(uuid),
  private.void_bill_deductions(),
  private.wht_due(text, text, text, date),
  private.wht_matrix_rate(text, boolean, boolean),
  private.wht_rate(uuid, text),
  private.wht_receipt_json(uuid),
  private.wht_schedule(uuid, date, text, text),
  private.write_bill(uuid, jsonb, public.members)
  from public, anon, authenticated;
