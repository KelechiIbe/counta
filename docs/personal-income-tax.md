# Personal income tax for business names and partnerships

A business on Counta pays income tax in one of three ways, and the Tax returns menu shows the one that applies:

| What CAC says (through Mono) | `orgs.legal_form` | How it is taxed | Menu |
| --- | --- | --- | --- |
| COMPANY... | `company` | Companies income tax (docs/tax-engines.md) | Companies income tax |
| COMPANY... with a type of "limited by guarantee" | `company`, `cit_profile.limited_by_guarantee` | Exempt, unless it trades (NTA 2025 s.162(1)(a)(iii)) | Income tax |
| IT (incorporated trustees) | `ngo` | Exempt, unless it trades | Income tax |
| BUSINESS_NAME | `enterprise` | Personal income tax through its owner, or its partners when it has two or more | Personal income tax |
| LP (limited partnership) | `partnership` | Personal income tax through its partners | Personal income tax |
| Not registered | `individual` | Personal income tax through its owner (or partners) | Personal income tax |

`private.income_tax_kind(org, year)` gives `company`, `exempt`, `sole` or `partnership`, and the app's `incomeTaxKind()` (src/lib/tax.ts) the same split for the menu. A trigger on `kyc_profiles` marks a company limited by guarantee the first time its CAC profile is read. The owner can say an NGO trades (`save_income_tax_setup`, `ngo_trades`): it then files companies income tax on its profit. The owner can also say a company CAC marked is not an NGO; that answer is kept as `limited_by_guarantee: false`, so reading CAC again does not mark it a second time. An LLP stays a company, as the NTA's definition of "company" includes it.

The engine lives in the database, like the CIT engine, so the books, the screens, the files and Flux all read one computation. Migration: `supabase/migrations/20261116000100_personal_income_tax.sql`.

## Which law, which year

The year of assessment is the accounting year plus one (preceding-year basis, NTA 2025 s.22; NTAA 2025 s.13(2)(b)).

| Accounts for | Year of assessment | Rule book | Law |
| --- | --- | --- | --- |
| 2025 | 2026 | `ng-pit-pita-legacy@1.1.0` (`PITA`) | Personal Income Tax Act as amended: Sixth Schedule rates, consolidated relief allowance, minimum tax, capital gains tax kept apart |
| 2026 onwards | 2027 onwards | `ng-pit-nta-2025@1.1.0` (`NTA_2025_PIT`) | NTA 2025: Fourth Schedule rates, s.30 deductions, chargeable gains in total income, no minimum tax |

The rule books are data in `tax_rulebooks` (files in `supabase/rulebooks/`), beside the CIT ones. `private.pit_rulebook(accounting year)` picks the PIT one; `private.rulebook(yoa)` now returns CIT rule books only. Earlier years are not prepared (the PRD leaves them out). Note that companies move to the NTA a year earlier (2025 accounts), as signed off for CIT; the PIT rule book puts 2025 income under the old law.

The return is due on 31 March of the year after the accounting year ends, whatever month the year ends in (agreed 4 November 2026). A June 2026 year end is due on 31 March 2027.

### The points TaxStreem signed off

TaxStreem (Kelechi Ibe) signed off both rule books on 4 November 2026: every point as Counta drafted it, except P-15, which was changed so that donations are deductible as for a company. The signed-off books are version 1.1.0 and approved (migration `20261116000200_pit_rulebooks_signed_off.sql`); the 1.0.0 drafts are retired. Each point is in `configurable_flags.flags` with `status` `agreed`. Before the sign-off a computation listed the points still open; it no longer does.

| Point | Reading | Status |
| --- | --- | --- |
| P-1 | 2025 accounts under the old law; 2026 onwards under the NTA (rule book s.1) | agreed |
| P-2 | Old law CRA: higher of ₦200,000 or 1%, plus 20%, of total income less pension, NHF, NHIS, life insurance and gratuity; home loan interest after it; minimum tax 1% of the same figure | agreed 4 Nov 2026 |
| P-3 | Due 31 March after the year ends | agreed 4 Nov 2026 |
| P-4 | Each return covers the person's share of the business and their other income, with their reliefs | agreed 4 Nov 2026 |
| P-5 | NTA: no minimum tax for individuals; the minimum wage exemption (s.162(1)(t)) is for employment income only | agreed 4 Nov 2026 |
| P-6 | NTA: gains on the business's disposals are shared like the profit and taxed with income; a net loss on disposals carries forward with the business loss (s.28) | agreed 4 Nov 2026 |
| P-7 | Old law: gains kept out of income, with CGT at 10% shown for each person's share | agreed (rule book s.1) |
| P-8 | Capital allowances for the business as one enterprise, shared in the profit-sharing ratio (First Schedule para 19(3)), business share of partly private assets (para 16); 2025 under the old initial and annual allowances with ₦10 retained, no two-thirds limit and no investment allowance for individuals | agreed 4 Nov 2026 |
| P-9 | A business loss carries forward against the person's later business income only; no time limit under the NTA; losses brought into 2025 taken as entered | agreed 4 Nov 2026 |
| P-10 | Partners' pay, interest on capital and benefits charged in the accounts go to that partner before the split (s.15(1)(a)); a sole proprietor's own pay is added back to him | agreed 4 Nov 2026 |
| P-11 | State: the office an active partner works from; where a dormant partner lives, or the NRS if abroad; where a sole proprietor lived on 1 January (Twelfth Schedule paras 4 and 6) | agreed 4 Nov 2026 |
| P-12 | WHT credit notes held at the year end (1401), less those used in earlier returns, shared in the profit-sharing ratio | agreed 4 Nov 2026 |
| P-13 | Dividends and interest taxed at source are final tax; government bond interest, foreign investment income through a domiciliary account, pensions and gratuities exempt; employment pay of the minimum wage or less exempt | agreed 4 Nov 2026 |
| P-14 | Research and development above 5% of turnover added back (rule book s.2; the s.164 limit is written for companies) | agreed 4 Nov 2026 |
| P-15 | Donations deductible on the same terms as a company: gifts to the bodies the law lists (NTA 2025 s.163(3); CITA s.25 and the Fifth Schedule for 2025 accounts), at most 10% of the profit before the donations, the rest added back. Changed at sign-off from Counta's draft, which added all donations back | agreed 4 Nov 2026 (changed) |
| P-16 | Mixed use: the business marks each partly private cost and its business share (50% by default); it must confirm before approving (rule book s.4) | agreed (rule book s.4) |

A change to a rule book is a new version: insert it approved (with `approved_by` and `approved_at`) and retire the one it replaces, as `20261116000200` does. An approved return keeps the rule book it was computed with (`pit_years.rulebook_id`).

## The data

| Table | What it holds | Read by |
| --- | --- | --- |
| `pit_people` | The proprietor or partners: name, Tax ID, an optional link to a team member, active or not. Filled from the names on the CAC record (or the owner) by `pit_setup` the first time someone opens Income tax | functions only |
| `pit_person_years` | What a person brings to a year: share, role (proprietor, active, dormant), office worked from, state lived in, living in Nigeria or not, pay charged in the accounts, amounts brought forward for the first year, reliefs, other income (each line with the portal line it goes on), the accommodation disclosure, the pension details (RSA number, administrator) and the documents for each relief; and, once approved, the computation made for the portal and where their return stands (Flux reference and status, acknowledgement, assessment, the pay bill, the payment, the tax clearance certificate) | functions only |
| `pit_years` | The year: status (`draft`, `approved`, `filed_outside`), mixed use, the statement of accounts, the business's employees for the year, the approval and its snapshot | functions only |
| `portal_logins` | The business's logins to the tax portals, one per tax authority: which portal, a hint of the username, the tax office, Flux's reference to the login, whether it worked. Never the password: Flux keeps that | functions only |

A person with no row for a year takes the latest earlier row's share, role, office and state, or an equal share and the head office. The accommodation (without the rent, unless they moved out) and the pension details also carry on from the year before. Pay, reliefs, other income, the rent and the documents are entered for each year. RLS is on and no signed-in role reads the tables directly: reliefs and other income are personal data.

The business's figures and adjustments are the companies income tax ones (`cit_years`: figures from the books or from accounts read in, line overrides, adjustment rows), so the Figures and Adjustments tabs are the same screens. `save_cit_year` and `cit_import` refuse changes while the PIT year is approved.

## The computation

### The business (`private.pit_business`)

1. Profit before tax, add-backs and deductions from the CIT engine (`private.cit_compute`, with nothing brought forward): depreciation, fines, general provisions, unrealised exchange differences, disposals and the business's own items, each with its reason.
2. The PIT rule book's own adjustments: the private share of each cost marked as mixed use (`pit_years.settings.mixed_use`, template cell to business share %) and research above 5% of turnover. Donations follow the CIT engine's limit (`business.donations_deductible` is true, P-15): gifts to listed bodies up to 10% of the profit before the donations, with gifts to bodies not listed entered under Adjustments (`cit_years.settings.donations_unlisted`).
3. Adjusted profit, plus balancing charges under the old law: the **assessable profit** of the business.
4. Capital allowances for the year (`private.cit_ca` with `legacy_upto: 2025` and `use_pct_always`): old-law initial and annual allowances to 2025 accounts, First Schedule rates from 2026, the business share of a partly private asset. Not deducted here: shared below.
5. Net chargeable gains: gains less losses on fixed assets from the schedule, gains on investments, and others entered.
6. WHT credit notes held at the year end (account 1401, or the line read in).

### Each person (`private.pit_person_tax`)

A pure function of the rule book and one bundle of inputs; it reads no table, so the same bundle always gives the same answer and Numen can be checked against it.

Input:

```json
{ "sole": false, "share_pct": 40, "assessable": 104400000, "remuneration": 6000000, "ca_year": 6250000, "gains_net": 0,
  "wht_available": 5000000, "losses_bf": 0, "ca_bf": 0,
  "reliefs": { "pension": 2000000, "nhf": 0, "nhis": 0, "life_insurance": 0, "home_loan_interest": 0, "gratuity": 0, "rent_paid": 0 },
  "other_income": [ { "kind": "rent", "label": "Flat in Yaba", "amount": 3000000, "tax_deducted": 300000 } ] }
```

Steps:

1. Share of the assessable profit (share % × assessable), plus pay, interest on capital and benefits charged in the accounts for the person (s.15(1)). A negative total is the person's loss (s.15(2)).
2. Less losses brought forward, as far as there is income from the business.
3. Less capital allowances: the share of the year's allowances (para 19(3)) plus those brought forward, as far as income is left. What is not used carries forward (para 22(3)).
4. NTA: plus the share of net chargeable gains (a loss in the year is set against them first; a net loss on disposals carries forward). Old law: gains are left out and CGT at 10% is shown separately.
5. Plus other income, line by line: `taxable` (PAYE or WHT deducted is credited), `final` (dividends and interest taxed at source: left out), `exempt` (government bond interest, foreign investment income through a domiciliary account, pensions and gratuities), `exempt_minimum_wage` (pay of the national minimum wage or less). Kinds: `employment`, `rent`, `dividend`, `interest`, `royalty`, `foreign_earned`, `foreign_investment`, `gov_bond_interest`, `pension_gratuity`, `other`.
6. Total income.
7. Reliefs. NTA s.30: NHF, NHIS, pension, interest on a loan for an owner-occupied home, life insurance or deferred annuity premiums, and rent relief of 20% of rent paid, at most ₦500,000. Old law: pension, NHF, NHIS, life insurance and gratuity first; CRA of the higher of ₦200,000 or 1%, plus 20%, of what is left; then home loan interest.
8. Chargeable income (never below nil), taxed band by band (`private.pit_bands`).
9. Old law only: minimum tax of 1% of the CRA base when it is higher than the tax at the rates and there is income.
10. Credits, none making the tax negative: foreign tax (the lower of the foreign tax and the Nigerian tax on that income, rule book s.7), PAYE and WHT deducted from other income, then the person's share of the business's WHT credit notes (unused credit notes stay for later years).
11. Tax payable.

Output: `rows` (each line with its basis, for the screen and the files), `figures`, `bands`, `other_income` (each line with its treatment) and `cf` (`losses`, `ca`).

### The state that taxes each person (`private.pit_authority`)

Twelfth Schedule to the NTA 2025: a partner engaged in the business, the state of the office he works from (para 4(a), the office's state on the branch); a dormant partner, the state he usually lives in (para 4(b)), or the NRS if he does not live in Nigeria (para 4(c), NTAA s.3(1)(a)(iv)); a sole proprietor, the state he lived in on 1 January of the year of assessment (para 6), taken as the head office's state until the owner says otherwise. Codes are `tax_authorities` codes (`SIRS:LA`, `SIRS:RI`, `SIRS:FC`, `NRS`).

### The chain (`private.pit_chain`)

Years run from 2025 accounts (or the first year of the books) to the year running now. Each passes forward, person by person, losses and unused allowances, and the total of WHT credit notes used. An approved year passes what it was approved with; a year filed outside Counta is still computed so its amounts pass on. A person new to the business starts from the amounts entered for them.

### No document, no relief (`private.pit_relief_check`)

The LIRS portal refuses a relief claim without its documents, so a relief entered without them is left out of the computation until they are attached, and the year says so. `private.pit_relief_needs()` lists what each relief needs: the RSA statement, the RSA number and the pension fund administrator for pension; the policy and evidence of payment for health and life insurance; the mortgage agreement and a statement of the interest for mortgage interest; the contribution statement for the NHF and for gratuity (Counta's reading: TaxStreem's list names the first four). Rent relief (2026 accounts onwards) needs the accommodation disclosure of a tenant, and comes from it: the year's rent less what an employer paid. Documents are kept under `<business>/tax/pit/<year>/people/<person>/<relief>/`, which only the person (when linked to their own login) and those who file tax can open.

### The portal's statement of income (`private.pit_portal_income`)

Each person's figures also come as the lines of the portal's statement of income (salary, commission, trade income, allowance, pension, annuity, foreign income, dividend, interest, rent, other income), from Counta's taxable figures, so the tax the portal works out is the tax Counta worked out. Trade income is the income from the business after losses and capital allowances; other income goes on the line its kind (and, for a job or a pension, the line the person chose) says; income that is exempt or taxed in full at source is left off. The lines add up to total income.

### Checks

Blocks: no people; the partners' shares do not add up to 100%; a limited partnership with one partner; a person whose state Counta cannot tell; no statement of accounts; mixed use not confirmed; the year has not ended; and the figure checks shared with CIT (books that start inside the year, a balance sheet that does not balance, accounts read in that do not tie). For a return Flux files (Lagos to begin with), also: the person's accommodation disclosure is not complete, and the business's staff for the year are not confirmed. Warnings: partners' pay above the salaries in the accounts; a partner joined or left (the year is not split at that date, para 19(2)); a relief left out for want of its documents (seen only by that person and those who file tax); no login saved for the portal of a state Flux files; the rule book awaits sign-off (none do since 4 November 2026). Notes: a non-resident partner files with the NRS; old-law gains go on a CGT return; the pay listed for the staff and the partners differs from the salaries in the accounts; keep the evidence for the deductions in the accounts (s.32).

## Who may do what

| Who | Sees | Changes |
| --- | --- | --- |
| Owner, or File tax | Every person's return, and which portal logins are saved | People, shares, roles, offices, pay, reliefs, other income, homes, documents; approves, reopens, sends to Flux, asks for the certificate, marks returns filed |
| Owner only, signed in with two-step | | The business's tax portal logins (Settings), which go straight to Flux |
| Keep the books, See margins or Make payments | The business's side and each person's share of it, and the staff; not their reliefs, other income, homes, documents or tax | Figures, adjustments, mixed use, capital allowances, the staff, the statement of accounts |
| A partner linked to their own login | Their own return in full, and the others' shares | Their own state, reliefs, other income, amounts brought forward, home, pension details and documents |

## Approval and filing

Approving (`approve_pit_year`, File tax) needs no blocks and the attestation of the statement of accounts (NTAA s.13(2)(d)): the text is kept in the snapshot with who confirmed it and when. Approval freezes the computation and marks each person's return approved. Reopening is refused once any return is with Flux or filed.

Each return then goes its own way:

- For a state Flux files (`filing.flux_authorities` in the rule book, Lagos to begin with), the app makes the person's computation as a PDF from the approved figures (`save_pit_computation_file`) and `tax-files` (`pit_send`) sends it to Flux with what each screen of the state portal asks for: the statement of income, the accommodation, the staff, the fixed assets and each relief with its documents, the statement of accounts and Flux's reference to the business's login for that portal. Flux files it and reports back on `/taxstreem/flux/pit-status`: the filing, then the pay bill (the partner or the business pays through its link), the payment, and the tax clearance certificate, which whoever files tax asks for with a picture of the person, the two earlier returns and the authority to file anything outstanding (`save_pit_tcc`, `pit_tcc_request`). See docs/flux-pit-handoff.md.
- For other states and the NRS, the business files it and marks it filed with the acknowledgement number (`mark_pit_filed`).
- A year already filed before Counta, or by an accountant, can be marked filed outside Counta.

The deadline (`private.tax_deadlines`, tax `pit`) is for the year that ended most recently, from 2025. It shows when the books cover that year, and also for a year before the books start once its accounts are read in or its return is begun (a business that moved to Counta after the year ended). It stays until every return is with Flux or filed; it counts beside the menu with the CIT count (`get_attention.cit`). Personal income tax is not posted as a cost of the business: when the business pays a partner's tax, it is that partner's drawing.

## The functions

| Function | For |
| --- | --- |
| `pit_years(org)` | The year list with each year's state, tax and blocks |
| `pit_year(org, year)` | One year: the computation (masked for those who may not see it), the CIT figures for the shared tabs, the people, branches and states, and what the caller may do |
| `pit_setup(org)` | The first people, from the CAC record or the owner |
| `save_pit_person(org, p)` | Add, rename, link or remove a person |
| `save_pit_person_year(org, year, person, p)` | A person's share, role, office, state, pay, reliefs, other income, amounts brought forward, accommodation, pension details and relief documents |
| `save_pit_year(org, year, p)` | Mixed use, the statement of accounts, the staff, notes |
| `save_pit_computation_file(org, year, person, path)` | The person's computation (PDF) made for the portal when the return is sent |
| `save_pit_tcc`, `pit_tcc_pack` | What a tax clearance certificate needs, and the pack `tax-files` sends to Flux for it |
| `portal_logins(org)`, `portal_login_begin(org, authority)` | The saved logins (no secrets), and the owner's check before a login goes to Flux |
| `svc_portal_login_saved`, `svc_portal_login_removed`, `svc_portal_login_status` | What Counta keeps of a login once Flux has it, and whether it worked (service role) |
| `approve_pit_year`, `reopen_pit_year`, `mark_pit_filed` | Approval, reopening, returns filed by the business or outside Counta |
| `save_income_tax_setup(org, p)` | The owner says an NGO trades, or that it is not an NGO |
| `pit_pack(org, year)` | The approved year for `tax-files` |
| `svc_pit_flux_update(org, year, person, p)` | Flux's status for one return, its pay bill, the payment and the certificate (service role) |

The screens are `src/pages/accounting/tax/PitTab.tsx` and, for the logins, `src/pages/settings/PortalLogins.tsx`; the computation file (Word, PDF, Excel, and the one-person PDF for the portal) is built by `src/lib/pitPack.ts` on the same model as the financial statements.

## Moving it to the main TaxStreem codebase

Counta computes the business's assessable profit from its books, so in the main codebase the person step can run in Numen if Numen's engine is brought into line with the law and the points above. Counta's `pit_person_tax` bundle maps onto `POST /api/v1/ingestion/pit/compute-tax-band` like this:

| Counta | Numen contract |
| --- | --- |
| accounting year (2025, 2026) | `year_of_assessment` (the contract uses the income year: 2025 means old rates). Counta's own year of assessment is one later. |
| `sole` / partnership | `filer_type` `SOLOPRENEUR` / `PARTNERSHIP`, one call per partner |
| share of assessable profit + pay charged | `gross_business_income_ngn`, with `deductions` empty (the business's adjustments are already made) |
| share of the year's allowances + brought forward | No field: the contract computes allowances from `assets`. A pre-computed allowance input is needed. |
| `losses_bf` | `prior_losses` (one entry) |
| `other_income` taxable lines | `other_income_ngn`; exempt and final-tax lines in `exempt_income_ngn` |
| reliefs | `reliefs[]` with the same codes, plus `RENT` for rent paid |
| foreign income and tax | `fx_entries[]`, `foreign_tax_paid_ngn` |
| WHT credit notes, PAYE | No field: credits are needed |

Where the contract and the law (or the agreed points) differ, and Numen should change:

1. It applies a 1% minimum tax to year of assessment 2026 (income year 2026). The NTA has none for individuals (P-5).
2. It exempts a filer earning ₦70,000 a month or less. Section 162(1)(t) exempts employment income of the minimum wage or less, not business profit (P-5).
3. Its old-law CRA is ₦200,000 plus 20% of gross income. Agreed: the higher of ₦200,000 or 1%, plus 20%, of total income less the exempt contributions (P-2, as the reliefs note has it).
4. Its minimum tax base is "gross income". Agreed: 1% of the CRA base (P-2).
5. It computes CGT at 10% on its own for 2026 income too. Under the NTA, gains are part of total income (s.28(2)(a)(v)); the separate 10% applies to 2025 income only (P-6, P-7).
6. It limits operating losses to four years. Section 28(3) of the NTA sets no limit (P-9).
7. It applies the PITA initial and annual allowances in both years. From 2026, the First Schedule rates on cost apply (P-8).
8. It has no partnership step: no profit-sharing ratio, no partners' pay, no state per partner (s.15, Twelfth Schedule).
9. Its 50/50 rule is fixed; the business sets the share (P-16).

The PRD's worked example (Persona B) also gives ₦1,290,400; chargeable income of ₦8,780,000 gives ₦1,370,400 at the Fourth Schedule rates. Counta's tests reproduce the corrected figure.

## Tested

`t_pit.sql` (179 checks) on a copy of production: the reliefs note's two examples to the naira; the PRD's sole proprietor corrected; a law firm with partners in Lagos, Port Harcourt and Abuja and a dormant partner abroad, under the old law and the NTA; losses and allowances carried from 2025 to 2026; other income of every kind with PAYE and foreign tax credits; minimum tax under the old law and none under the NTA; who may see and change what; approval, Flux, returns filed by the business, years filed outside Counta, deadlines and documents. For the portal: reliefs held until their documents (and the RSA number) are there; documents only for the person's own folder; rent relief from a tenant's accommodation, less what an employer paid; the statement of income adding up to total income; the accommodation and staff blocks for a return Flux files; the storage rules (a partner attaches and opens her own documents, the bookkeeper neither); the pay bill, payment and certificate only after filing; the logins (owner with two-step only, no password anywhere, a failed login flagged); reopening drops the portal's computation. The CIT suite gives the same results before and after.

`pit.py`, in the browser at 1440 and 390 pixels against the local stack: a law firm registered as a business name starts its income tax with the owner, adds three partners in the drawer (one in Port Harcourt, one in Abuja with rent and dividends, one dormant and abroad), confirms mixed use, attaches its statement of accounts, sees each partner's payable (₦5,994,096, ₦4,633,172, ₦2,687,848 and ₦1,128,480), approves with the attestation, downloads the computation in PDF, Word and Excel, sends the Lagos return to a stand-in for Flux (the request is signed and carries the figures and a working link to the statement), gets Flux's "filed" back with a payment link, and marks the Rivers return filed. On the way, Ada enters her home and attaches her RSA statement, Chi's life insurance waits until her policy is attached, and the staff are confirmed; the owner saves the business's LIRS login under Settings (a refusal from Flux that quotes the password is shown without it, and the password is in no table and on no page); Send makes Ada's computation as a PDF of her return alone, and the request carries her statement of income, home, pension with its statement, the staff and the assets; Flux sends the pay bill and the payment; and the owner asks for her tax clearance certificate with her picture and the 2023 and 2024 returns, which Flux reports issued. The bookkeeper sees the business, each share and the staff, not the partners' tax, and has no tax portal logins in Settings. Incorporated trustees see the exemption until the owner says it trades; a company CAC records as limited by guarantee is taxed as a company once the owner says it is not an NGO, and stays so when CAC is read again. Nothing runs off the side of a phone screen.

## Not covered yet

- A partner joining or leaving during the year: the year is not split at that date (para 19(2)); the computation warns.
- The interest restriction for connected persons (Third Schedule) carries nothing forward between PIT years.
- Business-name presentation of the statements (proprietor's capital and drawings): the statement of accounts is Counta's financial statements as they are.
- Paying PIT from Counta: the pay bill Flux sends back is shown with its link; Counta does not pay it from the business's wallet.
- Filing with states other than Lagos: the logins can be saved for every state now; Flux files once TaxStreem adds the state to the rule book.
- Presumptive tax (s.29) for a business without records.
