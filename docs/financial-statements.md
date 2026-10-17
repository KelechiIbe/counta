# Financial statements ready to sign

Accounting, Financial statements builds the full annual (or interim) financial statements of a Nigerian company from the books, under IFRS Accounting Standards or the IFRS for SMEs Accounting Standard, whichever the business reports under (Settings, Books and tax). One database call, `financial_statements_pack(org, from, to)`, returns everything; the screen, Word, PDF and Excel all draw from it, so they always agree.

## What is in the set

| Section | Contents |
| --- | --- |
| Corporate information | Directors, company secretary, registered office, RC number, date of incorporation, TIN, principal activity, auditors (or the small-company exemption), bankers and solicitors |
| Report of the directors | Legal form and principal activity, business review, results, dividend, directors, directors' interests, property, plant and equipment, donations, employment and employees, events after the reporting period, auditors, signed by order of the Board by the company secretary (CAMA 2020) |
| Statement of directors' responsibilities | The CAMA 2020 and FRC Act wording, going concern, signed by two directors with their FRC numbers |
| Statement of profit or loss and other comprehensive income | By function, with note references and comparatives |
| Statement of financial position | With the approval date and two directors' signatures |
| Statement of changes in equity | By component |
| Statement of cash flows | Indirect method, tied to the cash in the books |
| Notes | 1 General information, 2 Basis of preparation (compliance, measurement, currency, going concern, judgements, comparatives, new standards), 3 Material accounting policies, 4 Judgements and estimates, 5 Revenue (with disaggregation and contract balances), 6 Cost of sales, 7 Expenses, 8 Finance income and costs, 9 Profit before tax, 10 Staff costs and directors' emoluments, 11 Taxation (charge, reconciliation, current tax, deferred tax), 12 Property, plant and equipment, 13 Intangible assets, 14 Inventories, 15 Trade and other receivables (with expected credit losses), 16 Cash and cash equivalents, 17 Share capital and reserves, 18 Borrowings, 19 Trade and other payables, 20 Other statutory liabilities, 21 Related parties, 22 Financial risk management, 23 Capital management, 24 Contingencies and commitments, 25 Events after the reporting period, 26 Approval, and 27 Unreconciled bank items when there are any |
| Statement of value added | Value added and how it was applied (other national disclosure) |
| Five-year financial summary | Up to five year ends, with earnings per share when the issued shares are recorded |

Tax wording follows the period: the Nigeria Tax Act 2025 (company income tax at 30%, the 4% development levy, the 15% minimum effective tax rate, small companies exempt) for periods ending on or after 1 January 2026, and CITA with tertiary education tax before that. The new-standards note follows the financial year.

## Company details

"Company details" on the statements page holds what only the directors can give:

- Directors: name, role, FRC number, appointed and resigned dates. They usually arrive from TaxStreem onboarding (see [taxstreem-sso.md](taxstreem-sso.md)). The chair and the managing director (or the first two still serving) sign.
- Company secretary, auditors or the small-company audit exemption, bankers, solicitors, registered office, date of incorporation, authorised and issued shares and their nominal value.
- The approval date, the number of employees, and the paragraphs the directors write themselves: business review, dividend, going concern, events after the reporting period, contingent liabilities, capital commitments, future developments, directors' interests, assets pledged and employment policy. Any left empty prints the standard sentence.

The owner or the bookkeeper edits them (`update_corporate_info`).

## Before signing

The page lists what to fix first. Errors: no directors, a statement of financial position that does not cast, cash flows that do not end on the cash in the books, unreconciled bank items, transactions waiting in suspense. Warnings: one director only, opening balances still in 3999, books not closed to the period end, no RC number or TIN, no company secretary. Notes: standard wording used where the directors have not written their own, and no approval date yet (a blank line prints).

## Export

Export full set gives:

- Word (.docx): cover, contents with page numbers, each section on its own page (the statement of changes in equity in landscape), accounting lines under subtotals and double lines under totals, signature blocks with names, roles and FRC numbers. Edit it in Word before printing if the directors want changes.
- PDF: the same, laid out on A4, ready to print and sign.
- Excel: a cover with links to one sheet per section, amounts as numbers in accounting format, set to print on A4.
