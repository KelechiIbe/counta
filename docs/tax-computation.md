# Tax computation and capital allowances

Financial statements has two tax sections, Tax computation and Capital allowances, built from the ledger and the fixed asset register under the Nigeria Tax Act 2025. Both export with the rest of the set (Word, PDF, Excel). The rates live in a rule table, so the TaxStreem rule book can change one without new code.

## The rules

`public.tax_rules` holds each rate with the day it takes effect. `private.tax_rule(key, day)` gives the one in force; for a day before the first rule, the first rule stands.

| Key | Value | Source |
| --- | --- | --- |
| `cit_rate` | 30% | NTA 2025 s.56 |
| `small_company_rate` | 0% | NTA 2025 s.56 |
| `small_company_turnover` | ₦100m | NTA 2025 s.202 |
| `small_company_fixed_assets` | ₦250m | NTA 2025 s.202 |
| `development_levy_rate` | 4% of assessable profits | NTA 2025 s.59 |
| `met_rate`, `met_turnover` | 15%, from ₦50bn turnover | NTA 2025 s.57 |
| `donations_cap` | 10% of profit before donations | NTA 2025 |
| `rd_cap` | 5% of turnover | NTA 2025 |
| `ca_retention` | 1% of cost kept until disposal | First Schedule |
| `ca_restriction` | 100% (no restriction) | NTA 2025 |
| `ca_rate:<class account>` | 10% buildings, agricultural assets, masts, heavy transport; 20% plant, equipment, furniture and fittings; 25% motor vehicles and other capital expenditure; 0% land and work in progress | First Schedule |

Petroleum development costs (1524) have no rate until the rule book sets one; the computation says so.

A professional services company is never a small company (`tax_settings.professional_services`).

## Capital allowances

`private.ca_schedule(org, from, to)` goes through the asset register:

- Straight line on cost at the class rate, with no initial allowance.
- A full year's allowance for each asset owned and in use at the end of the period. A period shorter than a year (a year-to-date view) gets its share.
- An asset in use before the period has had one year's allowance for each earlier year end, so its tax value brought forward is cost less those years, never below 1% of cost.
- 1% of cost stays until the asset is disposed of.
- Sold in the period: no allowance; proceeds above the tax value give a balancing charge (never more than the allowances given); below it, a balancing allowance.

The schedule shows each class and each asset: tax value brought forward, additions, disposals, allowance, balancing charge or allowance and tax value carried forward.

## Companies income tax

`public.tax_computation(org, from, to)` starts from profit before tax in the statement of profit or loss and adds back, from their own accounts:

- depreciation and amortisation (5204, 5205, 6901 to 6903), replaced by capital allowances
- loss on disposal of fixed assets (6804), replaced by the balancing allowance
- fines and penalties (6513, 6514)
- the expected credit loss charge (6802); a debt written off (6801) stays deductible
- impairment of other assets (6803) and unrealised exchange losses (6704)
- donations above the cap (6904) and research above its share of turnover (6905)

and takes out gains on disposal (4508), dividends received (4505), non-taxable income and grants (4509), unrealised exchange and fair value gains (4511, 4515) and provisions written back (4507).

Then: losses brought forward, assessable profit, balancing charges, capital allowances (with any unabsorbed allowances brought forward and carried forward), total profit, companies income tax at 30% (0% for a small company), the 4% development levy (not for a small company), an indicative minimum effective tax top-up when turnover reaches the threshold, and withholding tax credit notes held in 1401 set against companies income tax. A business that is not a company gets no companies income tax and is told so.

Each line says where its figure comes from. The business adds what only it knows (Adjustments and losses): whether it provides professional services, losses and unabsorbed allowances brought forward, and its own add-backs or deductions, each with a reason that prints on the computation (`save_tax_settings`). They are kept per financial year.

The computation also lists points to check: entertainment and gifts treated as allowed, interest to connected persons (30% of EBITDA), donations only to listed bodies, a period starting before 2026, a class with no rate, a short period.

## Posting the charge

Post the tax charge (`post_tax_charge(org, from, to)`) puts companies income tax and any top-up (7501, 7505 against 2208) and the development levy (7502 against 2209) in the accounts on the last day of the period. A financial year carries one charge from here: posting again (for the full year after a year-to-date charge, or after the figures change) reverses the earlier one on its own date. The statements' checklist warns when the charge in the accounts differs from the computation.

## Still to come

The TaxStreem rule book for VAT, WHT and CIT. When it arrives, rates change in `tax_rules`, and anything it adds to the computation goes in `private.tax_computation`.
