-- Counta · TaxStreem chart of accounts
--
-- Counta now posts into the same chart of accounts as TaxStreem's Accounting module
-- (Accounting > Chart of accounts: 393 accounts from 1000 ASSETS to 9007). The posting
-- functions no longer name an account code. Each one asks for a posting role and
-- private.acct() resolves it, using the business's own choice in posting_rules when it
-- has made one and TaxStreem's default in posting_roles otherwise. An item can also point
-- at its own inventory account (raw materials, consumables and so on) through
-- items.inventory_account.
--
-- Default mapping
--   inventory            1203 Inventory - Finished Goods (items may override)
--   goods_in_transit     1204 Goods in Transit
--   purchases            5101 Purchases - Local
--   input_vat            1402 VAT Input (Recoverable)
--   payables             2101 Trade Payables - Local
--   inventory_movement   5400 Inventory Movement (System)
--   stock_variance       5400 Inventory Movement (System): miscounts, unrecorded sales, stock found
--   stock_loss           6805 Inventory Write-Downs: breakage, expiry, theft, quarantine
--   opening_equity       3999 Opening Balance Equity (System)
--   landed_duty          5105 Import Duties & Landing Costs
--   landed_freight       5104 Carriage Inwards & Clearing
--
-- A receipt posts on the purchases method with perpetual stock:
--   Dr 5101 purchases (net)    Dr 1402 input VAT    Cr 2101 vendor (gross)
--   Dr 1203 inventory (net)    Cr 5400 inventory movement (net)
-- A sale relieves stock at weighted average cost with Dr 5400 / Cr 1203, so the 5000 group
-- reads purchases + landed charges + inventory movement = cost of goods sold.
--
-- Existing journal lines move from Counta's interim codes to the TaxStreem codes in place,
-- and the interim accounts are switched off.

-- ---------------------------------------------------------------------------
-- 1. Accounts take the TaxStreem shape and the full chart
-- ---------------------------------------------------------------------------
alter table public.accounts
  add column if not exists category text,
  add column if not exists normal_balance text check (normal_balance in ('debit', 'credit')),
  add column if not exists parent_code text references public.accounts(code),
  add column if not exists is_group boolean not null default false,
  add column if not exists is_system boolean not null default false,
  add column if not exists active boolean not null default true,
  add column if not exists sort int;
create index if not exists accounts_parent_code_fk on public.accounts(parent_code);

comment on table public.accounts is 'TaxStreem chart of accounts. Group rows (is_group) are headers and never take postings.';
comment on column public.accounts.kind is 'Coarse type used by reports: asset, liability, equity, income or expense. 8000 OCI sits under income; 9000 system accounts follow their normal balance.';

-- One row per account: code, name, normal balance, and whether it is a header (group) or a
-- system account. Kind, category, parent and sort order follow from the code.
with v(code, name, bal, type) as (values
  ('1000', 'ASSETS', 'Dr', 'group'),
  ('1010', 'Cash & Cash Equivalents', 'Dr', 'group'),
  ('1011', 'Petty Cash / Cash in Hand', 'Dr', ''),
  ('1012', 'Cash at Bank - NGN Current Accounts', 'Dr', ''),
  ('1013', 'Cash at Bank - Domiciliary Accounts (FCY)', 'Dr', ''),
  ('1014', 'Mobile Money & Payment Wallets', 'Dr', ''),
  ('1015', 'Short-Term Deposits (< 90 days)', 'Dr', ''),
  ('1016', 'Marketable Securities (Cash Equivalents)', 'Dr', ''),
  ('1019', 'Other Cash Equivalents', 'Dr', ''),
  ('1100', 'Trade & Other Receivables', 'Dr', 'group'),
  ('1101', 'Trade Receivables - Local', 'Dr', ''),
  ('1102', 'Trade Receivables - Export/Foreign', 'Dr', ''),
  ('1103', 'Allowance for Expected Credit Losses', 'Cr', ''),
  ('1104', 'Staff Advances & Receivables', 'Dr', ''),
  ('1105', 'Directors'' Current Accounts (Receivable)', 'Dr', ''),
  ('1106', 'Advances to Vendors / Suppliers', 'Dr', ''),
  ('1107', 'Accrued Income', 'Dr', ''),
  ('1108', 'Intercompany / Related-Party Receivables', 'Dr', ''),
  ('1109', 'Interbank Placements & Advances', 'Dr', ''),
  ('1110', 'Other Receivables', 'Dr', ''),
  ('1200', 'Inventories', 'Dr', 'group'),
  ('1201', 'Inventory - Raw Materials', 'Dr', ''),
  ('1202', 'Inventory - Work in Progress', 'Dr', ''),
  ('1203', 'Inventory - Finished Goods', 'Dr', ''),
  ('1204', 'Goods in Transit', 'Dr', ''),
  ('1205', 'Consumables, Spares & Small Tools', 'Dr', ''),
  ('1206', 'Chemicals, Materials & Supplies', 'Dr', ''),
  ('1207', 'Allowance for Inventory Obsolescence', 'Cr', ''),
  ('1300', 'Prepayments & Other Current Assets', 'Dr', 'group'),
  ('1301', 'Prepaid Rent', 'Dr', ''),
  ('1302', 'Prepaid Insurance', 'Dr', ''),
  ('1303', 'Other Prepaid Expenses', 'Dr', ''),
  ('1304', 'Short-Term Investments', 'Dr', ''),
  ('1305', 'Current Portion of Long-Term Loans Receivable', 'Dr', ''),
  ('1306', 'Assets Classified as Held for Sale', 'Dr', ''),
  ('1307', 'Contract Assets - Current', 'Dr', ''),
  ('1308', 'Other Current Assets', 'Dr', ''),
  ('1400', 'Tax Assets (Current)', 'Dr', 'group'),
  ('1401', 'Withholding Tax Receivable (WHT Credit Notes)', 'Dr', ''),
  ('1402', 'VAT Input (Recoverable)', 'Dr', ''),
  ('1403', 'Income Tax Advance Payments / Instalments', 'Dr', ''),
  ('1404', 'Other Tax Recoverables', 'Dr', ''),
  ('1500', 'Property, Plant & Equipment (Cost)', 'Dr', 'group'),
  ('1501', 'PPE - Freehold Land', 'Dr', ''),
  ('1502', 'PPE - Non-Industrial Building', 'Dr', ''),
  ('1503', 'PPE - Industrial Building', 'Dr', ''),
  ('1504', 'PPE - Plants', 'Dr', ''),
  ('1505', 'PPE - Ships, Boats & Yachts', 'Dr', ''),
  ('1506', 'PPE - Heavy Equipment', 'Dr', ''),
  ('1507', 'PPE - Aircraft Engine & Fuselage', 'Dr', ''),
  ('1508', 'PPE - Aircraft & Vessel Furnishing', 'Dr', ''),
  ('1509', 'PPE - Communications & Electricity Towers & Cables', 'Dr', ''),
  ('1510', 'PPE - Trains & Tracks', 'Dr', ''),
  ('1511', 'PPE - Motor Vehicles', 'Dr', ''),
  ('1512', 'PPE - Motor Vehicles (Bus, Truck & Mass Transit)', 'Dr', ''),
  ('1513', 'PPE - Tools & Equipment', 'Dr', ''),
  ('1514', 'PPE - Office Equipment', 'Dr', ''),
  ('1515', 'PPE - Medical Equipment', 'Dr', ''),
  ('1516', 'PPE - Household Equipment', 'Dr', ''),
  ('1517', 'PPE - Computer Hardware', 'Dr', ''),
  ('1518', 'PPE - Office Fixtures', 'Dr', ''),
  ('1519', 'PPE - Furniture & Fittings', 'Dr', ''),
  ('1520', 'PPE - Assets Under Construction', 'Dr', ''),
  ('1521', 'PPE - Capital Work in Progress', 'Dr', ''),
  ('1522', 'PPE - Agricultural Plantations (Bearer Plants)', 'Dr', ''),
  ('1523', 'PPE - Biological Assets (Poultry, Fisheries, Livestock)', 'Dr', ''),
  ('1524', 'PPE - Petroleum Development Costs', 'Dr', ''),
  ('1525', 'PPE - Distribution Network Assets', 'Dr', ''),
  ('1526', 'PPE - Leasehold Improvements', 'Dr', ''),
  ('1527', 'PPE - Other Property, Plant & Equipment', 'Dr', ''),
  ('1550', 'Accumulated Depreciation - PPE', 'Cr', 'group'),
  ('1551', 'Acc. Depreciation - Non-Industrial Building', 'Cr', ''),
  ('1552', 'Acc. Depreciation - Industrial Building', 'Cr', ''),
  ('1553', 'Acc. Depreciation - Plants', 'Cr', ''),
  ('1554', 'Acc. Depreciation - Ships, Boats & Yachts', 'Cr', ''),
  ('1555', 'Acc. Depreciation - Heavy Equipment', 'Cr', ''),
  ('1556', 'Acc. Depreciation - Aircraft Engine & Fuselage', 'Cr', ''),
  ('1557', 'Acc. Depreciation - Aircraft & Vessel Furnishing', 'Cr', ''),
  ('1558', 'Acc. Depreciation - Communications & Electricity Towers & Cables', 'Cr', ''),
  ('1559', 'Acc. Depreciation - Trains & Tracks', 'Cr', ''),
  ('1560', 'Acc. Depreciation - Motor Vehicles', 'Cr', ''),
  ('1561', 'Acc. Depreciation - Motor Vehicles (Bus, Truck & Mass Transit)', 'Cr', ''),
  ('1562', 'Acc. Depreciation - Tools & Equipment', 'Cr', ''),
  ('1563', 'Acc. Depreciation - Office Equipment', 'Cr', ''),
  ('1564', 'Acc. Depreciation - Medical Equipment', 'Cr', ''),
  ('1565', 'Acc. Depreciation - Household Equipment', 'Cr', ''),
  ('1566', 'Acc. Depreciation - Computer Hardware', 'Cr', ''),
  ('1567', 'Acc. Depreciation - Office Fixtures', 'Cr', ''),
  ('1568', 'Acc. Depreciation - Furniture & Fittings', 'Cr', ''),
  ('1569', 'Acc. Depreciation - Agricultural Plantations (Bearer Plants)', 'Cr', ''),
  ('1570', 'Acc. Depreciation - Biological Assets (Poultry, Fisheries, Livestock)', 'Cr', ''),
  ('1571', 'Acc. Depreciation - Petroleum Development Costs', 'Cr', ''),
  ('1572', 'Acc. Depreciation - Distribution Network Assets', 'Cr', ''),
  ('1573', 'Acc. Depreciation - Leasehold Improvements', 'Cr', ''),
  ('1574', 'Acc. Depreciation - Other Property, Plant & Equipment', 'Cr', ''),
  ('1600', 'Intangible Assets', 'Dr', 'group'),
  ('1601', 'Goodwill', 'Dr', ''),
  ('1602', 'Patents', 'Dr', ''),
  ('1603', 'Trademarks', 'Dr', ''),
  ('1604', 'Brands', 'Dr', ''),
  ('1605', 'Customer Relationships', 'Dr', ''),
  ('1606', 'Copyrights', 'Dr', ''),
  ('1607', 'Computer Software & Development Costs', 'Dr', ''),
  ('1608', 'Concession & Service Rights', 'Dr', ''),
  ('1609', 'Accumulated Amortisation - Intangibles', 'Cr', ''),
  ('1610', 'Other Intangible Assets', 'Dr', ''),
  ('1650', 'Right-of-Use Assets (IFRS 16)', 'Dr', 'group'),
  ('1651', 'ROU Asset - Buildings & Premises', 'Dr', ''),
  ('1652', 'ROU Asset - Motor Vehicles', 'Dr', ''),
  ('1653', 'ROU Asset - Plant & Equipment', 'Dr', ''),
  ('1654', 'Accumulated Depreciation - ROU Assets', 'Cr', ''),
  ('1700', 'Investments', 'Dr', 'group'),
  ('1701', 'Investment in Subsidiaries', 'Dr', ''),
  ('1702', 'Investment in Associates & Joint Ventures', 'Dr', ''),
  ('1703', 'Investment Securities - FVTPL', 'Dr', ''),
  ('1704', 'Investment Securities - FVOCI', 'Dr', ''),
  ('1705', 'Investment Securities - Amortised Cost', 'Dr', ''),
  ('1706', 'Investment Properties', 'Dr', ''),
  ('1707', 'Net Investment in Finance Leases', 'Dr', ''),
  ('1708', 'Staff Loans - Long Term', 'Dr', ''),
  ('1709', 'Digital Assets', 'Dr', ''),
  ('1710', 'Investment in Commodities', 'Dr', ''),
  ('1711', 'Other Investments', 'Dr', ''),
  ('1800', 'Other Non-Current Assets', 'Dr', 'group'),
  ('1801', 'Leasehold Land', 'Dr', ''),
  ('1802', 'Leasehold Buildings', 'Dr', ''),
  ('1803', 'Deferred Tax Assets', 'Dr', ''),
  ('1804', 'Contract Assets - Non-Current', 'Dr', ''),
  ('1805', 'Derivative Financial Assets', 'Dr', ''),
  ('1806', 'Long-Term Loans & Receivables', 'Dr', ''),
  ('1807', 'Defined Benefit Plan Assets', 'Dr', ''),
  ('1808', 'Other Financial Assets', 'Dr', ''),
  ('1809', 'Other Non-Current Assets', 'Dr', ''),
  ('2000', 'LIABILITIES', 'Cr', 'group'),
  ('2100', 'Trade & Other Payables', 'Cr', 'group'),
  ('2101', 'Trade Payables - Local', 'Cr', ''),
  ('2102', 'Trade Payables - Foreign', 'Cr', ''),
  ('2103', 'Accrued Expenses', 'Cr', ''),
  ('2104', 'Other Payables', 'Cr', ''),
  ('2105', 'Intercompany / Related-Party Payables', 'Cr', ''),
  ('2106', 'Directors'' Current Accounts (Payable)', 'Cr', ''),
  ('2107', 'Contract Liabilities / Advances from Customers', 'Cr', ''),
  ('2108', 'Dividend Payable', 'Cr', ''),
  ('2109', 'Refund Liabilities', 'Cr', ''),
  ('2110', 'Deferred Income - Current', 'Cr', ''),
  ('2200', 'Statutory & Tax Liabilities', 'Cr', 'group'),
  ('2201', 'Output VAT Payable', 'Cr', ''),
  ('2202', 'Withholding Tax Payable (Agent)', 'Cr', ''),
  ('2203', 'PAYE Payable', 'Cr', ''),
  ('2204', 'Pension Contributions Payable', 'Cr', ''),
  ('2205', 'NHF Payable', 'Cr', ''),
  ('2206', 'NSITF Payable', 'Cr', ''),
  ('2207', 'ITF Payable', 'Cr', ''),
  ('2208', 'Current Income Tax Payable (CIT)', 'Cr', ''),
  ('2209', 'Development Levy Payable', 'Cr', ''),
  ('2210', 'Other Statutory Levies Payable', 'Cr', ''),
  ('2300', 'Borrowings - Current', 'Cr', 'group'),
  ('2301', 'Bank Overdrafts', 'Cr', ''),
  ('2302', 'Short-Term Loans', 'Cr', ''),
  ('2303', 'Current Portion of Long-Term Borrowings', 'Cr', ''),
  ('2304', 'Lease Liabilities - Current', 'Cr', ''),
  ('2305', 'Interest Payable', 'Cr', ''),
  ('2306', 'Commercial Papers & Other Short-Term Debt', 'Cr', ''),
  ('2400', 'Provisions - Current', 'Cr', 'group'),
  ('2401', 'Provision for Warranties', 'Cr', ''),
  ('2402', 'Provision for Bonuses & Employee Benefits', 'Cr', ''),
  ('2403', 'Other Provisions - Current', 'Cr', ''),
  ('2500', 'Borrowings - Non-Current', 'Cr', 'group'),
  ('2501', 'Long-Term Bank Loans', 'Cr', ''),
  ('2502', 'Shareholder & Related-Party Loans', 'Cr', ''),
  ('2503', 'Bonds & Debt Securities Issued', 'Cr', ''),
  ('2504', 'Lease Liabilities - Non-Current', 'Cr', ''),
  ('2505', 'Deposits from Customers', 'Cr', ''),
  ('2600', 'Other Non-Current Liabilities', 'Cr', 'group'),
  ('2601', 'Deferred Tax Liabilities', 'Cr', ''),
  ('2602', 'Deferred Revenue - Non-Current', 'Cr', ''),
  ('2603', 'Retirement Benefit Obligations', 'Cr', ''),
  ('2604', 'Decommissioning & Restoration Provisions', 'Cr', ''),
  ('2605', 'Long-Term Provisions & Contingencies', 'Cr', ''),
  ('2606', 'Derivative Financial Liabilities', 'Cr', ''),
  ('2607', 'Stock Warrant Obligations', 'Cr', ''),
  ('2608', 'Other Non-Current Liabilities', 'Cr', ''),
  ('3000', 'EQUITY', 'Cr', 'group'),
  ('3001', 'Issued Share Capital - Ordinary', 'Cr', ''),
  ('3002', 'Issued Share Capital - Preference', 'Cr', ''),
  ('3003', 'Share Premium', 'Cr', ''),
  ('3004', 'Deposit for Shares', 'Cr', ''),
  ('3005', 'Retained Earnings', 'Cr', ''),
  ('3006', 'Revaluation Reserve', 'Cr', ''),
  ('3007', 'Statutory Reserve', 'Cr', ''),
  ('3008', 'Foreign Currency Translation Reserve', 'Cr', ''),
  ('3009', 'Cash Flow Hedge Reserve', 'Cr', ''),
  ('3010', 'FVOCI Reserve', 'Cr', ''),
  ('3011', 'Share-Based Payment Reserve', 'Cr', ''),
  ('3012', 'Capital Reserve', 'Cr', ''),
  ('3013', 'Contingency Reserve', 'Cr', ''),
  ('3014', 'Reserve for Bonus Issue', 'Cr', ''),
  ('3015', 'Other Reserves', 'Cr', ''),
  ('3016', 'Non-Controlling Interests', 'Cr', ''),
  ('3017', 'Treasury Shares', 'Dr', ''),
  ('3999', 'Opening Balance Equity (System)', 'Cr', 'system'),
  ('4000', 'INCOME', 'Cr', 'group'),
  ('4100', 'Operating Revenue', 'Cr', 'group'),
  ('4101', 'Revenue - Manufacturing', 'Cr', ''),
  ('4102', 'Revenue - Agriculture, Forestry & Fishing', 'Cr', ''),
  ('4103', 'Revenue - Mining & Quarrying', 'Cr', ''),
  ('4104', 'Revenue - Electricity', 'Cr', ''),
  ('4105', 'Revenue - Water Supply, Sewerage & Waste Management', 'Cr', ''),
  ('4106', 'Revenue - Construction', 'Cr', ''),
  ('4107', 'Revenue - Wholesale & Retail Trade', 'Cr', ''),
  ('4108', 'Revenue - Transportation & Haulage', 'Cr', ''),
  ('4109', 'Revenue - Accommodation & Food Service Activities', 'Cr', ''),
  ('4110', 'Revenue - Communication & Information', 'Cr', ''),
  ('4111', 'Revenue - Banks & Other Financial Activities', 'Cr', ''),
  ('4112', 'Revenue - Insurance Activities', 'Cr', ''),
  ('4113', 'Revenue - Real Estate Activities', 'Cr', ''),
  ('4114', 'Revenue - Professional, Scientific & Technical Activities', 'Cr', ''),
  ('4115', 'Revenue - Administrative & Support Activities', 'Cr', ''),
  ('4116', 'Revenue - Education', 'Cr', ''),
  ('4117', 'Revenue - Oil & Gas', 'Cr', ''),
  ('4118', 'Revenue - NGOs, NFPOs & Religious Institutions', 'Cr', ''),
  ('4119', 'Revenue - Art, Entertainment & Recreation', 'Cr', ''),
  ('4120', 'Revenue - Digital & Virtual Assets', 'Cr', ''),
  ('4121', 'Revenue - Other Sectors', 'Cr', ''),
  ('4131', 'Sales Returns & Allowances', 'Dr', ''),
  ('4132', 'Discounts Allowed', 'Dr', ''),
  ('4500', 'Other Income', 'Cr', 'group'),
  ('4501', 'Commission Income', 'Cr', ''),
  ('4502', 'Interest Income', 'Cr', ''),
  ('4503', 'Finance Lease Income', 'Cr', ''),
  ('4504', 'Rental Income', 'Cr', ''),
  ('4505', 'Dividend Income (Franked Investment Income)', 'Cr', ''),
  ('4506', 'Gain on Disposal of Investments / Subsidiaries', 'Cr', ''),
  ('4507', 'Write-Back of Provisions', 'Cr', ''),
  ('4508', 'Gain on Disposal of PPE', 'Cr', ''),
  ('4509', 'Non-Taxable Revenue, Grants & Donations Received', 'Cr', ''),
  ('4510', 'Realised Foreign Exchange Gains', 'Cr', ''),
  ('4511', 'Unrealised Foreign Exchange Gains', 'Cr', ''),
  ('4512', 'Bad Debts Recovered', 'Cr', ''),
  ('4513', 'Other Investment Income', 'Cr', ''),
  ('4514', 'Insurance Claims Received', 'Cr', ''),
  ('4515', 'Fair Value Gains (P&L)', 'Cr', ''),
  ('4516', 'Sundry Income', 'Cr', ''),
  ('5000', 'COST OF SALES / DIRECT COSTS', 'Dr', 'group'),
  ('5100', 'Purchases', 'Dr', 'group'),
  ('5101', 'Purchases - Local', 'Dr', ''),
  ('5102', 'Purchases - Imports', 'Dr', ''),
  ('5103', 'Purchase Returns (Returns Outwards)', 'Cr', ''),
  ('5104', 'Carriage Inwards & Clearing', 'Dr', ''),
  ('5105', 'Import Duties & Landing Costs', 'Dr', ''),
  ('5200', 'Other Direct Costs', 'Dr', 'group'),
  ('5201', 'Direct Wages', 'Dr', ''),
  ('5202', 'Direct Materials & Expenses', 'Dr', ''),
  ('5203', 'Subcontractor & Direct Service Costs', 'Dr', ''),
  ('5204', 'Depreciation - Production Assets', 'Dr', ''),
  ('5205', 'Amortisation - Direct Intangibles', 'Dr', ''),
  ('5206', 'Mining Costs', 'Dr', ''),
  ('5207', 'Direct Construction Costs', 'Dr', ''),
  ('5208', 'Storage & Handling Costs', 'Dr', ''),
  ('5209', 'Other Direct Costs', 'Dr', ''),
  ('5300', 'Factory Overheads', 'Dr', 'group'),
  ('5301', 'Factory Rent', 'Dr', ''),
  ('5302', 'Factory Rates', 'Dr', ''),
  ('5303', 'Fuel & Power - Factory', 'Dr', ''),
  ('5304', 'Indirect Wages', 'Dr', ''),
  ('5305', 'Factory Repairs & Maintenance', 'Dr', ''),
  ('5306', 'Other Factory Overheads', 'Dr', ''),
  ('5400', 'Inventory Movement (System)', 'Dr', 'system'),
  ('5401', 'Change in Inventories (Periodic)', 'Dr', ''),
  ('6000', 'OPERATING & ADMINISTRATIVE EXPENSES', 'Dr', 'group'),
  ('6100', 'Personnel Costs', 'Dr', 'group'),
  ('6101', 'Salaries & Wages', 'Dr', ''),
  ('6102', 'Staff Allowances', 'Dr', ''),
  ('6103', 'Employee Benefit Expenses', 'Dr', ''),
  ('6104', 'Pension Contributions - Employer', 'Dr', ''),
  ('6105', 'Staff Gratuity', 'Dr', ''),
  ('6106', 'Medical Expenses - Staff', 'Dr', ''),
  ('6107', 'Training & Development', 'Dr', ''),
  ('6108', 'Staff Welfare', 'Dr', ''),
  ('6109', 'Directors'' Emoluments', 'Dr', ''),
  ('6110', 'Directors'' Expenses', 'Dr', ''),
  ('6111', 'Staff Loans Written Off', 'Dr', ''),
  ('6112', 'Outsourced Services & Contract Staff', 'Dr', ''),
  ('6113', 'Recruitment Costs', 'Dr', ''),
  ('6114', 'Other Staff Costs', 'Dr', ''),
  ('6200', 'Occupancy, Office & Utilities', 'Dr', 'group'),
  ('6201', 'Rent - Office & Premises', 'Dr', ''),
  ('6202', 'Rates & Tenement Charges', 'Dr', ''),
  ('6203', 'Service Charge', 'Dr', ''),
  ('6204', 'Utilities - Water & Sewage', 'Dr', ''),
  ('6205', 'Electricity & Power', 'Dr', ''),
  ('6206', 'Diesel (AGO)', 'Dr', ''),
  ('6207', 'Petrol (PMS)', 'Dr', ''),
  ('6208', 'Generator Running & Maintenance', 'Dr', ''),
  ('6209', 'Repairs & Maintenance', 'Dr', ''),
  ('6210', 'Cleaning & Janitorial Services', 'Dr', ''),
  ('6211', 'Security Expenses', 'Dr', ''),
  ('6212', 'Stationery & Printing', 'Dr', ''),
  ('6213', 'Postage & Courier', 'Dr', ''),
  ('6214', 'Newspapers & Periodicals', 'Dr', ''),
  ('6215', 'Insurance - General Business', 'Dr', ''),
  ('6216', 'Office Consumables', 'Dr', ''),
  ('6300', 'Technology & Communication', 'Dr', 'group'),
  ('6301', 'Telephone & Communication', 'Dr', ''),
  ('6302', 'Internet & Data', 'Dr', ''),
  ('6303', 'Software Subscriptions & Maintenance', 'Dr', ''),
  ('6304', 'Website Design & Maintenance', 'Dr', ''),
  ('6305', 'IT Support & Hardware Maintenance', 'Dr', ''),
  ('6400', 'Marketing & Business Development', 'Dr', 'group'),
  ('6401', 'Advertising & Promotion', 'Dr', ''),
  ('6402', 'Corporate Promotion', 'Dr', ''),
  ('6403', 'Public Relations', 'Dr', ''),
  ('6404', 'Publication Costs', 'Dr', ''),
  ('6405', 'Trade Fairs & Exhibitions', 'Dr', ''),
  ('6406', 'Sponsorships', 'Dr', ''),
  ('6407', 'Selling & Distribution Expenses', 'Dr', ''),
  ('6408', 'Corporate Social Responsibility', 'Dr', ''),
  ('6409', 'Entertainment - Business', 'Dr', ''),
  ('6410', 'Gifts & Souvenirs', 'Dr', ''),
  ('6500', 'Professional, Regulatory & Statutory', 'Dr', 'group'),
  ('6501', 'Audit Fees', 'Dr', ''),
  ('6502', 'Accountancy & Bookkeeping Fees', 'Dr', ''),
  ('6503', 'Legal Fees', 'Dr', ''),
  ('6504', 'Consultancy Fees', 'Dr', ''),
  ('6505', 'Management & Technical Fees', 'Dr', ''),
  ('6506', 'Secretarial & CAC Filing Fees', 'Dr', ''),
  ('6507', 'Other Professional Fees', 'Dr', ''),
  ('6508', 'Government & Regulatory Costs', 'Dr', ''),
  ('6509', 'Licences & Permits', 'Dr', ''),
  ('6510', 'Subscriptions & Dues', 'Dr', ''),
  ('6511', 'AMCON Levy', 'Dr', ''),
  ('6512', 'Other Statutory Charges & Levies', 'Dr', ''),
  ('6513', 'Fines', 'Dr', ''),
  ('6514', 'Penalties', 'Dr', ''),
  ('6515', 'Royalties', 'Dr', ''),
  ('6600', 'Travel & Transport', 'Dr', 'group'),
  ('6601', 'Local Transport & Logistics', 'Dr', ''),
  ('6602', 'Travel - Local', 'Dr', ''),
  ('6603', 'Travel - International', 'Dr', ''),
  ('6604', 'Hotel & Accommodation', 'Dr', ''),
  ('6605', 'Vehicle Running Costs', 'Dr', ''),
  ('6606', 'Freight & Transport Expenses', 'Dr', ''),
  ('6607', 'Head Office Costs', 'Dr', ''),
  ('6700', 'Finance Charges & FX (Operating)', 'Dr', 'group'),
  ('6701', 'Bank Charges', 'Dr', ''),
  ('6702', 'Interest Expense', 'Dr', ''),
  ('6703', 'Realised Foreign Exchange Losses', 'Dr', ''),
  ('6704', 'Unrealised Foreign Exchange Losses', 'Dr', ''),
  ('6800', 'Impairments, Write-Offs & Disposals', 'Dr', 'group'),
  ('6801', 'Bad Debts Written Off', 'Dr', ''),
  ('6802', 'Impairment of Receivables (ECL Charge)', 'Dr', ''),
  ('6803', 'Impairment of Other Assets', 'Dr', ''),
  ('6804', 'Loss on Disposal of PPE', 'Dr', ''),
  ('6805', 'Inventory Write-Downs', 'Dr', ''),
  ('6900', 'Depreciation, Amortisation & Other', 'Dr', 'group'),
  ('6901', 'Depreciation - PPE (Admin)', 'Dr', ''),
  ('6902', 'Depreciation - Right-of-Use Assets', 'Dr', ''),
  ('6903', 'Amortisation - Intangible Assets', 'Dr', ''),
  ('6904', 'Donations', 'Dr', ''),
  ('6905', 'Research Costs', 'Dr', ''),
  ('6906', 'Health, Safety & Environment', 'Dr', ''),
  ('6907', 'General / Sundry Expenses', 'Dr', ''),
  ('7000', 'FINANCE COSTS & TAXATION', 'Dr', 'group'),
  ('7100', 'Finance Costs (Excluding Interest)', 'Dr', 'group'),
  ('7101', 'Loan Arrangement & Facility Fees', 'Dr', ''),
  ('7102', 'Letter of Credit & Trade Finance Charges', 'Dr', ''),
  ('7103', 'Interest on Lease Liabilities', 'Dr', ''),
  ('7104', 'Unwinding of Discount on Provisions', 'Dr', ''),
  ('7105', 'Other Finance Costs', 'Dr', ''),
  ('7500', 'Taxation', 'Dr', 'group'),
  ('7501', 'Current Income Tax Expense (CIT)', 'Dr', ''),
  ('7502', 'Development Levy Expense', 'Dr', ''),
  ('7503', 'Deferred Tax Expense / (Credit)', 'Dr', ''),
  ('7504', 'Prior-Year Under/(Over) Provision', 'Dr', ''),
  ('7505', 'Minimum ETR Top-Up Tax', 'Dr', ''),
  ('8000', 'OTHER COMPREHENSIVE INCOME', 'Cr', 'group'),
  ('8001', 'Revaluation Gains / (Losses) - PPE', 'Cr', ''),
  ('8002', 'Remeasurement of Defined Benefit Plans', 'Cr', ''),
  ('8003', 'Foreign Currency Translation Differences', 'Cr', ''),
  ('8004', 'Cash Flow Hedge Gains / (Losses)', 'Cr', ''),
  ('8005', 'FVOCI Fair Value Changes', 'Cr', ''),
  ('8006', 'Gains / (Losses) on Derivative Contracts (OCI)', 'Cr', ''),
  ('8007', 'Unrealised FX Gain (OCI, per NRS line)', 'Cr', ''),
  ('8008', 'Income Tax on OCI Items', 'Cr', ''),
  ('8009', 'Other Comprehensive Income - Others', 'Cr', ''),
  ('9000', 'SYSTEM & CONTROL ACCOUNTS', 'Dr', 'group'),
  ('9001', 'Uncategorised Transactions (AI Suspense)', 'Dr', 'system'),
  ('9002', 'Bank Clearing / In-Transit', 'Dr', 'system'),
  ('9003', 'Payroll Clearing', 'Cr', 'system'),
  ('9004', 'Intercompany Clearing', 'Dr', 'system'),
  ('9005', 'Goods Received Not Invoiced (GRNI)', 'Cr', 'system'),
  ('9006', 'Rounding Differences', 'Dr', 'system'),
  ('9007', 'Migration / Opening Balance Offset', 'Dr', 'system')
)
insert into public.accounts (code, name, kind, category, normal_balance, parent_code, is_group, is_system, sort)
select v.code, v.name,
  case left(v.code, 1) when '1' then 'asset' when '2' then 'liability' when '3' then 'equity'
    when '4' then 'income' when '8' then 'income'
    when '9' then case v.bal when 'Dr' then 'asset' else 'liability' end
    else 'expense' end,
  case left(v.code, 1) when '1' then 'Assets' when '2' then 'Liabilities' when '3' then 'Equity' when '4' then 'Income'
    when '5' then 'Cost of Sales' when '6' then 'Expenses' when '7' then 'Finance Costs & Taxation'
    when '8' then 'Other Comprehensive Income' else 'System & Control' end,
  case v.bal when 'Cr' then 'credit' else 'debit' end,
  case when v.code like '_000' then null
       when v.type = 'group' or v.code in ('5400', '5401') then left(v.code, 1) || '000'
       else (select max(g.code) from v g where g.type = 'group' and left(g.code, 1) = left(v.code, 1) and g.code < v.code) end,
  v.type = 'group', v.type = 'system', v.code::int
from v
on conflict (code) do update set
  name = excluded.name, kind = excluded.kind, category = excluded.category, normal_balance = excluded.normal_balance,
  parent_code = excluded.parent_code, is_group = excluded.is_group, is_system = excluded.is_system, sort = excluded.sort,
  active = true;

-- ---------------------------------------------------------------------------
-- 2. Posting roles (TaxStreem defaults) and posting rules (a business's own choices)
-- ---------------------------------------------------------------------------
create table public.posting_roles (
  role text primary key,
  label text not null,
  description text not null,
  default_code text not null references public.accounts(code),
  allowed text not null,
  sort int not null
);
comment on column public.posting_roles.allowed is 'Regular expression an account code must match before it can be mapped to this role.';
create index posting_roles_default_code_fk on public.posting_roles(default_code);

insert into public.posting_roles (role, label, description, default_code, allowed, sort) values
  ('inventory', 'Stock on hand', 'Stock in your branches at weighted average cost. An item can use its own inventory account.', '1203', '^(1201|1202|1203|1205|1206)$', 1),
  ('goods_in_transit', 'Stock moving between branches', 'Holds a transfer from the moment it leaves one branch until the other branch confirms it.', '1204', '^(1204)$', 2),
  ('purchases', 'Stock bought', 'Net cost of the stock on a vendor invoice, before VAT.', '5101', '^(5101|5102)$', 3),
  ('input_vat', 'VAT on purchases', 'Input VAT charged by a VAT-registered vendor, claimable against output VAT.', '1402', '^(1402|1404)$', 4),
  ('payables', 'Owed to vendors', 'What a posted receipt or shipment charge leaves you owing. Paying the vendor in TaxStreem clears it.', '2101', '^(2101|2102|2104|2105|9005)$', 5),
  ('inventory_movement', 'Stock in and out', 'Cost of stock sold, less purchases that went into stock. Reported inside cost of sales.', '5400', '^(5400|5401)$', 6),
  ('stock_variance', 'Count differences', 'Miscounts, unrecorded sales and stock found during a count.', '5400', '^(5400|5401|5209|6805)$', 7),
  ('stock_loss', 'Stock lost or written off', 'Breakage, expiry, suspected theft and quarantined batches.', '6805', '^(6805|6803|5209|5400)$', 8),
  ('opening_equity', 'Opening stock', 'Balancing entry for stock you already held when you started on Counta.', '3999', '^(3999|9007|3005)$', 9),
  ('landed_duty', 'Import duty', 'Duty and levies paid to clear imported stock.', '5105', '^(5104|5105)$', 10),
  ('landed_freight', 'Clearing and haulage', 'Clearing, haulage and agent fees on a shipment.', '5104', '^(5104|5105|6606)$', 11);

create table public.posting_rules (
  org_id uuid not null references public.orgs(id) on delete cascade,
  role text not null references public.posting_roles(role),
  account_code text not null references public.accounts(code),
  updated_by uuid references public.members(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (org_id, role)
);
create index posting_rules_role_fk on public.posting_rules(role);
create index posting_rules_account_code_fk on public.posting_rules(account_code);
create index posting_rules_updated_by_fk on public.posting_rules(updated_by);

alter table public.posting_roles enable row level security;
alter table public.posting_rules enable row level security;
create policy posting_roles_read on public.posting_roles for select to authenticated using (true);
create policy posting_rules_read on public.posting_rules for select to authenticated using ((select private.is_member(org_id)));

-- Item-level inventory account. Only set_item_inventory_account() may change it, because the
-- item's stock value has to move with it.
alter table public.items add column if not exists inventory_account text references public.accounts(code);
create index if not exists items_inventory_account_fk on public.items(inventory_account);

create or replace function private.guard_item_account() returns trigger
language plpgsql set search_path = public, private as $$
begin
  if new.inventory_account is distinct from old.inventory_account
     and coalesce(current_setting('app.reclass', true), '') <> 'on' then
    raise exception 'Change an item''s inventory account from its drawer so the stock value moves with it.';
  end if;
  return new;
end $$;
create trigger items_account_guard before update of inventory_account on public.items
  for each row execute function private.guard_item_account();

-- ---------------------------------------------------------------------------
-- 3. Resolving accounts
-- ---------------------------------------------------------------------------
create or replace function private.acct(p_org uuid, p_role text) returns text
language sql stable security definer set search_path = public, private as $$
  select coalesce(
    (select r.account_code from public.posting_rules r where r.org_id = p_org and r.role = p_role),
    (select pr.default_code from public.posting_roles pr where pr.role = p_role))
$$;

create or replace function private.inv_acct(p_item uuid) returns text
language sql stable security definer set search_path = public, private as $$
  select coalesce(i.inventory_account, private.acct(i.org_id, 'inventory')) from public.items i where i.id = p_item
$$;

-- Two lines that move p_val from one account to another; a negative value runs the other way.
create or replace function private.reclass_pair(p_to text, p_from text, p_val numeric, p_loc uuid, p_item uuid default null)
returns jsonb
language sql immutable set search_path = public, private as $$
  select jsonb_build_array(
    jsonb_build_object('code', case when p_val >= 0 then p_to else p_from end, 'debit', abs(p_val), 'location_id', p_loc, 'item_id', p_item),
    jsonb_build_object('code', case when p_val >= 0 then p_from else p_to end, 'credit', abs(p_val), 'location_id', p_loc, 'item_id', p_item))
$$;

create or replace function private.post_journal(
  p_org uuid, p_memo text, p_source_type text, p_source_id uuid,
  p_author uuid, p_approver uuid, p_lines jsonb, p_at timestamptz default now()
) returns public.journals
language plpgsql security definer set search_path = public, private as $$
declare j public.journals; v_dr numeric := 0; v_cr numeric := 0; x jsonb; v_d numeric; v_c numeric;
begin
  for x in select * from jsonb_array_elements(p_lines) loop
    v_d := round(coalesce((x->>'debit')::numeric, 0), 2);
    v_c := round(coalesce((x->>'credit')::numeric, 0), 2);
    if v_d < 0 or v_c < 0 then raise exception 'Journal amounts cannot be negative.'; end if;
    if (v_d <> 0 or v_c <> 0) and not exists (
      select 1 from public.accounts a where a.code = x->>'code' and a.active and not a.is_group) then
      raise exception 'Account % cannot take postings. Check the posting rules in Settings.', coalesce(x->>'code', '(none)');
    end if;
    v_dr := v_dr + v_d;
    v_cr := v_cr + v_c;
  end loop;
  if v_dr <> v_cr then
    raise exception 'Journal does not balance (Dr % / Cr %).', v_dr, v_cr;
  end if;
  insert into public.journals (org_id, je_no, entry_date, memo, source_type, source_id, posted_by, approved_by, created_at)
  values (p_org, private.next_no(p_org, 'JE', 1001), private.local_day(p_org, p_at), p_memo, p_source_type, p_source_id, p_author, p_approver, p_at)
  returning * into j;
  insert into public.journal_lines (journal_id, org_id, account_code, debit, credit, location_id, item_id, memo)
  select j.id, p_org, e->>'code',
         round(coalesce((e->>'debit')::numeric, 0), 2), round(coalesce((e->>'credit')::numeric, 0), 2),
         nullif(e->>'location_id', '')::uuid, nullif(e->>'item_id', '')::uuid, e->>'memo'
  from jsonb_array_elements(p_lines) e
  where round(coalesce((e->>'debit')::numeric, 0), 2) <> 0 or round(coalesce((e->>'credit')::numeric, 0), 2) <> 0;
  return j;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Posting functions resolve accounts through the rules
-- ---------------------------------------------------------------------------
create or replace function public.import_items(p_org uuid, p_location uuid, p_rows jsonb, p_file_name text default null)
returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; r jsonb; v_idx int := 0; v_id uuid; v_created int := 0; v_skipped jsonb := '[]'::jsonb;
  v_total numeric := 0; v_lines jsonb := '[]'::jsonb; v_name text; v_price numeric; v_cost numeric; v_qty numeric; v_pack numeric;
  j public.journals; v_ops jsonb := '[]'::jsonb; op jsonb; v_su text; v_barcode text;
begin
  m := private.require(p_org, 'edit_prices');
  if not exists (select 1 from locations where id = p_location and org_id = p_org) then raise exception 'Choose a branch for the opening stock.'; end if;
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    v_idx := v_idx + 1;
    v_name := trim(coalesce(r->>'name', ''));
    begin
      v_price := nullif(regexp_replace(coalesce(r->>'price', ''), '[^0-9.\-]', '', 'g'), '')::numeric;
      v_cost := nullif(regexp_replace(coalesce(r->>'cost', ''), '[^0-9.\-]', '', 'g'), '')::numeric;
      v_qty := nullif(regexp_replace(coalesce(r->>'qty', ''), '[^0-9.\-]', '', 'g'), '')::numeric;
      v_pack := nullif(regexp_replace(coalesce(r->>'pack_size', ''), '[^0-9.]', '', 'g'), '')::numeric;
    exception when others then
      v_skipped := v_skipped || jsonb_build_object('row', v_idx, 'name', v_name, 'reason', 'Numbers could not be read');
      continue;
    end;
    if v_name = '' then v_skipped := v_skipped || jsonb_build_object('row', v_idx, 'name', '', 'reason', 'No product name'); continue; end if;
    if v_price is null or v_price <= 0 then v_skipped := v_skipped || jsonb_build_object('row', v_idx, 'name', v_name, 'reason', 'No selling price'); continue; end if;
    if v_pack is null or v_pack < 1 then v_pack := 1; end if;
    v_pack := floor(v_pack);
    v_barcode := nullif(regexp_replace(coalesce(r->>'barcode', ''), '\s', '', 'g'), '');
    if v_barcode is not null and exists (select 1 from items where org_id = p_org and barcode = v_barcode) then v_barcode := null; end if;
    if exists (select 1 from items where org_id = p_org and lower(name) = lower(v_name) and not archived) then
      v_skipped := v_skipped || jsonb_build_object('row', v_idx, 'name', v_name, 'reason', 'Already in your items'); continue;
    end if;
    v_su := coalesce(nullif(trim(r->>'selling_unit'), ''), 'piece');
    insert into items (org_id, name, sku, barcode, category, vat_treatment, purchase_unit, pack_size, selling_unit, informal_unit,
      price, notes, needs_review, created_by, track_batches, reorder_floor)
    values (p_org, v_name, nullif(trim(r->>'sku'), ''), v_barcode, coalesce(nullif(trim(r->>'category'), ''), 'General'),
      case when r->>'vat_treatment' in ('standard', 'zero', 'exempt') then r->>'vat_treatment' else 'standard' end,
      coalesce(nullif(trim(r->>'purchase_unit'), ''), case when v_pack > 1 then 'Carton' else 'Pack' end), v_pack::int, v_su,
      v_su in ('derica', 'mudu', 'paint bucket'), v_price, coalesce(r->'notes', '{}'::jsonb),
      coalesce(r->'notes', '{}'::jsonb) <> '{}'::jsonb, m.id, coalesce((r->>'track_batches')::boolean, false),
      coalesce(nullif(regexp_replace(coalesce(r->>'reorder_floor', ''), '[^0-9.]', '', 'g'), '')::numeric, 0))
    returning id into v_id;
    insert into item_costs (item_id, org_id, wac, last_cost) values (v_id, p_org, greatest(coalesce(v_cost, 0), 0), v_cost);
    v_created := v_created + 1;
    if coalesce(v_qty, 0) > 0 then
      v_total := v_total + round(v_qty * greatest(coalesce(v_cost, 0), 0), 2);
      v_ops := v_ops || jsonb_build_object('item_id', v_id, 'qty', v_qty, 'cost', greatest(coalesce(v_cost, 0), 0));
    end if;
  end loop;

  if jsonb_array_length(v_ops) > 0 then
    j := private.post_journal(p_org, 'Opening stock · ' || coalesce(p_file_name, 'import'), 'opening', null, m.id, null,
      jsonb_build_array(
        jsonb_build_object('code', private.acct(p_org, 'inventory'), 'debit', v_total, 'location_id', p_location, 'memo', 'Opening stock'),
        jsonb_build_object('code', private.acct(p_org, 'opening_equity'), 'credit', v_total, 'location_id', p_location)));
    for op in select * from jsonb_array_elements(v_ops) loop
      perform private.add_movement(p_org, 'opening', (op->>'item_id')::uuid, p_location, (op->>'qty')::numeric,
        (op->>'cost')::numeric, null, j.id, m.id, 'Import', now(), jsonb_build_object('note', coalesce(p_file_name, 'Spreadsheet import')));
    end loop;
  end if;
  return jsonb_build_object('created', v_created, 'skipped', v_skipped, 'journal_ref', j.ref, 'opening_value', v_total);
end $$;

create or replace function private.post_receipt_internal(p_receipt uuid, p_member uuid, p_at timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.receipts; m public.members; l public.receipt_lines; it public.items; v public.vendors; o public.orgs;
  v_bad int; v_net numeric := 0; v_vat_base numeric := 0; v_vat numeric := 0; v_gross numeric; v_line numeric;
  v_vat_t text; v_pack int; v_su_qty numeric; v_cost_su numeric; v_old_last numeric; v_on_hand numeric; v_wac numeric;
  j public.journals; v_item uuid; v_batch uuid; v_new jsonb; v_price numeric; v_props int := 0; v_can_price boolean; v_pid uuid;
  v_memo text; v_acct text; v_amt numeric; v_by_acct jsonb := '{}'::jsonb; v_jl jsonb;
begin
  select * into r from receipts where id = p_receipt for update;
  if not found then raise exception 'Receipt not found.'; end if;
  select * into m from members where id = p_member;
  select * into o from orgs where id = r.org_id;
  if r.status <> 'needs_review' then raise exception 'This receipt is already %.', replace(r.status, '_', ' '); end if;
  if r.location_id is null then raise exception 'Choose the branch receiving this stock.'; end if;
  if r.vendor_id is null and coalesce(trim(r.vendor_name), '') = '' then raise exception 'Choose or name the vendor.'; end if;
  if not exists (select 1 from receipt_lines where receipt_id = r.id) then raise exception 'Add at least one line.'; end if;
  select count(*) into v_bad from receipt_lines
  where receipt_id = r.id and (not confirmed or qty <= 0 or unit_cost <= 0
    or (item_id is null and coalesce(trim(new_item->>'name'), '') = ''));
  if v_bad > 0 then
    raise exception '% line% still need% confirmation before posting.', v_bad,
      case when v_bad > 1 then 's' else '' end, case when v_bad > 1 then '' else 's' end;
  end if;

  if r.vendor_id is null then
    select id into r.vendor_id from vendors where org_id = r.org_id and lower(name) = lower(trim(r.vendor_name)) limit 1;
    if r.vendor_id is null then
      insert into vendors (org_id, name, vat_registered, channel)
      values (r.org_id, trim(r.vendor_name), r.vendor_vat_registered, 'whatsapp') returning id into r.vendor_id;
    end if;
    update receipts set vendor_id = r.vendor_id where id = r.id;
  end if;
  select * into v from vendors where id = r.vendor_id;
  v_can_price := private.perm_of(m, 'edit_prices');

  -- Totals first: the journal must exist before any movement references it.
  for l in select * from receipt_lines where receipt_id = r.id order by line_no loop
    v_line := round(l.qty * l.unit_cost, 2);
    if l.item_id is not null then
      select vat_treatment into v_vat_t from items where id = l.item_id;
      v_acct := private.inv_acct(l.item_id);
    else
      v_vat_t := coalesce(nullif(l.new_item->>'vat_treatment', ''), 'standard');
      v_acct := private.acct(r.org_id, 'inventory');
    end if;
    v_net := v_net + v_line;
    v_by_acct := jsonb_set(v_by_acct, array[v_acct], to_jsonb(coalesce((v_by_acct->>v_acct)::numeric, 0) + v_line));
    if v_vat_t = 'standard' then v_vat_base := v_vat_base + v_line; end if;
  end loop;
  v_vat := case when r.vendor_vat_registered then round(v_vat_base * 0.075, 2) else 0 end;
  v_gross := v_net + v_vat;
  v_memo := v.name || coalesce(' · ' || nullif(r.invoice_no, ''), '');

  v_jl := jsonb_build_array(
    jsonb_build_object('code', private.acct(r.org_id, 'purchases'), 'debit', v_net, 'memo', 'Stock bought from ' || v.name),
    jsonb_build_object('code', private.acct(r.org_id, 'input_vat'), 'debit', v_vat, 'memo', 'Input VAT 7.5%'),
    jsonb_build_object('code', private.acct(r.org_id, 'payables'), 'credit', v_gross, 'memo', 'Payable to ' || v.name));
  for v_acct, v_amt in select key, value::numeric from jsonb_each_text(v_by_acct) order by key loop
    v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', v_acct, 'debit', v_amt, 'location_id', r.location_id, 'memo', 'Stock received'));
  end loop;
  v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(r.org_id, 'inventory_movement'), 'credit', v_net,
    'location_id', r.location_id, 'memo', 'Purchases moved into stock'));
  j := private.post_journal(r.org_id, v_memo, 'receipt', r.id, m.id, null, v_jl, p_at);

  for l in select * from receipt_lines where receipt_id = r.id order by line_no loop
    v_item := l.item_id;
    if v_item is null then
      v_new := l.new_item;
      v_pack := greatest(1, coalesce(nullif(v_new->>'pack_size', '')::numeric, 1)::int);
      v_cost_su := l.unit_cost / case when l.unit_kind = 'purchase' then v_pack else 1 end;
      v_price := nullif(v_new->>'price', '')::numeric;
      if not v_can_price or v_price is null or v_price <= 0 then
        v_price := private.round_price(v_cost_su * 1.15);
      end if;
      insert into items (org_id, name, category, vat_treatment, purchase_unit, pack_size, selling_unit, informal_unit, track_batches,
        preferred_vendor_id, price, needs_review, created_by, barcode)
      values (r.org_id, trim(v_new->>'name'), coalesce(nullif(trim(v_new->>'category'), ''), 'General'),
        coalesce(nullif(v_new->>'vat_treatment', ''), 'standard'), coalesce(nullif(trim(v_new->>'purchase_unit'), ''), 'Carton'), v_pack,
        coalesce(nullif(trim(v_new->>'selling_unit'), ''), 'piece'),
        coalesce(nullif(trim(v_new->>'selling_unit'), ''), 'piece') in ('derica', 'mudu', 'paint bucket'),
        coalesce((v_new->>'track_batches')::boolean, false), r.vendor_id, v_price,
        not coalesce(v_can_price and nullif(v_new->>'price', '')::numeric > 0, false), m.id,
        case when nullif(trim(v_new->>'barcode'), '') is not null
              and not exists (select 1 from items where org_id = r.org_id and barcode = trim(v_new->>'barcode'))
             then trim(v_new->>'barcode') end)
      returning id into v_item;
      insert into item_costs (item_id, org_id, wac) values (v_item, r.org_id, 0);
      update receipt_lines set item_id = v_item where id = l.id;
    end if;

    select * into it from items where id = v_item;
    v_pack := it.pack_size;
    v_su_qty := l.qty * case when l.unit_kind = 'purchase' then v_pack else 1 end;
    v_cost_su := round(l.unit_cost / case when l.unit_kind = 'purchase' then v_pack else 1 end, 4);

    -- Weighted average cost, recalculated on every receipt.
    select coalesce(sum(qty), 0) into v_on_hand from stock_levels where item_id = v_item;
    select wac, last_cost into v_wac, v_old_last from item_costs where item_id = v_item for update;
    if v_on_hand <= 0 or coalesce(v_wac, 0) = 0 then v_wac := v_cost_su;
    else v_wac := round((v_on_hand * v_wac + v_su_qty * v_cost_su) / (v_on_hand + v_su_qty), 4); end if;
    update item_costs set wac = v_wac, last_cost = v_cost_su, replacement_cost = v_cost_su,
      replacement_source = j.ref || ' · ' || v.name, updated_at = now()
    where item_id = v_item;

    v_batch := null;
    if it.track_batches then
      insert into batches (org_id, item_id, location_id, batch_no, expiry_date, qty_received, qty_remaining, receipt_id, created_at)
      values (r.org_id, v_item, r.location_id, coalesce(nullif(trim(l.batch_no), ''), 'R' || j.je_no || '-' || l.line_no),
        l.expiry_date, v_su_qty, v_su_qty, r.id, p_at)
      returning id into v_batch;
    end if;

    perform private.add_movement(r.org_id, 'receipt', v_item, r.location_id, v_su_qty, v_cost_su, null, j.id, m.id,
      private.channel_for(r.source), p_at,
      jsonb_build_object('receipt_id', r.id, 'batch_id', v_batch, 'device_id', r.device_id, 'offline', r.offline,
        'note', coalesce(l.raw_text, '')));

    if it.preferred_vendor_id is null then update items set preferred_vendor_id = r.vendor_id where id = v_item; end if;

    if v_old_last is not null and v_cost_su > v_old_last + 0.004 then
      v_pid := private.propose_price(v_item, 'cost_increase', v_old_last, v_cost_su,
        j.ref || ' · ' || v.name || ' · ' || to_char(private.local_day(r.org_id, p_at), 'DD Mon'));
      if v_pid is not null then v_props := v_props + 1; end if;
    end if;
  end loop;

  update receipts set status = 'posted', net = v_net, input_vat = v_vat, gross = v_gross, journal_id = j.id, ref = j.ref,
    posted_by = m.id, posted_at = p_at, vendor_id = r.vendor_id
  where id = r.id;
  if r.po_id is not null then
    update purchase_orders set status = 'received', received_at = p_at where id = r.po_id and status = 'sent';
  end if;
  return jsonb_build_object('journal_ref', j.ref, 'net', v_net, 'vat', v_vat, 'gross', v_gross, 'proposals', v_props);
end $$;

create or replace function private.sale_internal(
  p_org uuid, p_item uuid, p_location uuid, p_qty numeric, p_unit_price numeric, p_author uuid, p_channel text,
  p_type text, p_at timestamptz, p_extra jsonb, p_journal uuid default null
) returns public.movements
language plpgsql security definer set search_path = public, private as $$
declare it public.items; v_wac numeric; v_alloc jsonb; j public.journals; v_journal uuid := p_journal; v_price numeric; mv public.movements;
begin
  select * into it from items where id = p_item and org_id = p_org;
  if not found then raise exception 'Item not found.'; end if;
  if not exists (select 1 from locations where id = p_location and org_id = p_org) then raise exception 'Unknown branch.'; end if;
  select wac into v_wac from item_costs where item_id = p_item;
  v_price := coalesce(p_unit_price, it.price);
  v_alloc := private.consume_batches(p_item, p_location, p_qty, private.local_day(p_org, p_at));
  if v_journal is null then
    j := private.post_journal(p_org, 'Sale · ' || it.name, 'sale', null, p_author, null,
      jsonb_build_array(
        jsonb_build_object('code', private.acct(p_org, 'inventory_movement'), 'debit', round(p_qty * coalesce(v_wac, 0), 2), 'location_id', p_location, 'item_id', p_item),
        jsonb_build_object('code', private.inv_acct(p_item), 'credit', round(p_qty * coalesce(v_wac, 0), 2), 'location_id', p_location, 'item_id', p_item)), p_at);
    v_journal := j.id;
  end if;
  mv := private.add_movement(p_org, p_type, p_item, p_location, -p_qty, coalesce(v_wac, 0), v_price, v_journal, p_author, p_channel, p_at,
    coalesce(p_extra, '{}'::jsonb) || jsonb_build_object('batch_id', (v_alloc->0->>'batch_id')));
  return mv;
end $$;

create or replace function private.post_day_close(p_org uuid, p_location uuid, p_author uuid, p_lines jsonb, p_at timestamptz, p_channel text default 'Invoicing rail')
returns uuid
language plpgsql security definer set search_path = public, private as $$
declare x jsonb; v_cogs numeric := 0; j public.journals; v_wac numeric; v_loc text; v_amt numeric; v_acct text;
  v_by_acct jsonb := '{}'::jsonb; v_jl jsonb;
begin
  for x in select * from jsonb_array_elements(p_lines) loop
    select wac into v_wac from item_costs where item_id = (x->>'item_id')::uuid;
    v_amt := round((x->>'qty')::numeric * coalesce(v_wac, 0), 2);
    v_acct := coalesce(private.inv_acct((x->>'item_id')::uuid), private.acct(p_org, 'inventory'));
    v_by_acct := jsonb_set(v_by_acct, array[v_acct], to_jsonb(coalesce((v_by_acct->>v_acct)::numeric, 0) + v_amt));
    v_cogs := v_cogs + v_amt;
  end loop;
  if v_cogs = 0 and jsonb_array_length(p_lines) = 0 then return null; end if;
  select name into v_loc from locations where id = p_location;
  v_jl := jsonb_build_array(jsonb_build_object('code', private.acct(p_org, 'inventory_movement'), 'debit', v_cogs, 'location_id', p_location));
  for v_acct, v_amt in select key, value::numeric from jsonb_each_text(v_by_acct) order by key loop
    v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', v_acct, 'credit', v_amt, 'location_id', p_location));
  end loop;
  j := private.post_journal(p_org, 'Day close · ' || v_loc, 'sale', null, p_author, null, v_jl, p_at);
  for x in select * from jsonb_array_elements(p_lines) loop
    perform private.sale_internal(p_org, (x->>'item_id')::uuid, p_location, (x->>'qty')::numeric, nullif(x->>'price', '')::numeric,
      p_author, p_channel, 'sale', p_at, '{}'::jsonb, j.id);
  end loop;
  return j.id;
end $$;

create or replace function public.create_transfer(
  p_org uuid, p_item uuid, p_from uuid, p_to uuid, p_qty numeric,
  p_client_uuid uuid default null, p_device text default null, p_offline boolean default false
) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; it public.items; v_avail numeric; v_wac numeric; v_ref text; v_id uuid; j public.journals;
  v_from text; v_to text; v_alloc jsonb; v_val numeric;
begin
  m := private.require(p_org, 'transfer_stock');
  if p_client_uuid is not null and exists (select 1 from transfers where client_uuid = p_client_uuid) then
    return (select jsonb_build_object('duplicate', true, 'ref', ref) from transfers where client_uuid = p_client_uuid);
  end if;
  select * into it from items where id = p_item and org_id = p_org;
  if not found then raise exception 'Choose an item.'; end if;
  if p_from is null or p_to is null or p_from = p_to then raise exception 'Choose two different locations.'; end if;
  if p_qty is null or p_qty < 1 then raise exception 'Enter a quantity.'; end if;
  select name into v_from from locations where id = p_from and org_id = p_org;
  select name into v_to from locations where id = p_to and org_id = p_org;
  if v_from is null or v_to is null then raise exception 'Unknown branch.'; end if;
  select coalesce(qty, 0) into v_avail from stock_levels where item_id = p_item and location_id = p_from;
  v_avail := coalesce(v_avail, 0);
  if p_qty > v_avail then
    raise exception 'Only % % available at %.', private.fmt_qty(v_avail), it.selling_unit, v_from;
  end if;
  select wac into v_wac from item_costs where item_id = p_item;
  v_val := round(p_qty * coalesce(v_wac, 0), 2);
  v_ref := 'TR-' || lpad(private.next_no(p_org, 'TR', 1)::text, 4, '0');
  v_alloc := private.consume_batches(p_item, p_from, p_qty);
  insert into transfers (org_id, ref, item_id, qty, unit_cost, from_location_id, to_location_id, batch_alloc, created_by, client_uuid)
  values (p_org, v_ref, p_item, p_qty, coalesce(v_wac, 0), p_from, p_to, v_alloc, m.id, p_client_uuid) returning id into v_id;
  j := private.post_journal(p_org, 'Transfer ' || v_ref || ' · ' || v_from || ' → ' || v_to, 'transfer', v_id, m.id, null,
    jsonb_build_array(
      jsonb_build_object('code', private.acct(p_org, 'goods_in_transit'), 'debit', v_val, 'item_id', p_item, 'memo', 'In transit to ' || v_to),
      jsonb_build_object('code', private.inv_acct(p_item), 'credit', v_val, 'location_id', p_from, 'item_id', p_item)));
  perform private.add_movement(p_org, 'transfer_out', p_item, p_from, -p_qty, coalesce(v_wac, 0), null, j.id, m.id,
    case when p_device is not null then 'Phone app' else 'App' end, now(),
    jsonb_build_object('transfer_id', v_id, 'device_id', p_device, 'offline', p_offline, 'note', v_from || ' → ' || v_to));
  return jsonb_build_object('ref', v_ref, 'id', v_id);
end $$;

create or replace function private.receive_transfer_internal(p_transfer uuid, p_member uuid, p_at timestamptz) returns text
language plpgsql security definer set search_path = public, private as $$
declare t public.transfers; j public.journals; v_val numeric; a jsonb; v_from text; v_to text; v_batch uuid;
begin
  select * into t from transfers where id = p_transfer for update;
  if t.status <> 'in_transit' then raise exception 'This transfer was already received.'; end if;
  select name into v_from from locations where id = t.from_location_id;
  select name into v_to from locations where id = t.to_location_id;
  v_val := round(t.qty * t.unit_cost, 2);
  j := private.post_journal(t.org_id, 'Transfer ' || t.ref || ' received at ' || v_to, 'transfer_receive', t.id, p_member, null,
    jsonb_build_array(
      jsonb_build_object('code', private.inv_acct(t.item_id), 'debit', v_val, 'location_id', t.to_location_id, 'item_id', t.item_id),
      jsonb_build_object('code', private.acct(t.org_id, 'goods_in_transit'), 'credit', v_val, 'item_id', t.item_id)), p_at);
  for a in select * from jsonb_array_elements(t.batch_alloc) loop
    insert into batches (org_id, item_id, location_id, batch_no, expiry_date, qty_received, qty_remaining, created_at)
    values (t.org_id, t.item_id, t.to_location_id, a->>'batch_no', nullif(a->>'expiry_date', '')::date, (a->>'qty')::numeric, (a->>'qty')::numeric, p_at)
    returning id into v_batch;
  end loop;
  perform private.add_movement(t.org_id, 'transfer_in', t.item_id, t.to_location_id, t.qty, t.unit_cost, null, j.id, p_member,
    'App', p_at, jsonb_build_object('transfer_id', t.id, 'note', v_from || ' → ' || v_to || ' · received'));
  update transfers set status = 'received', received_by = p_member, received_at = p_at where id = t.id;
  return j.ref;
end $$;

-- A shortfall with a loss reason (breakage, expiry, theft, other) is a write-down. Miscounts,
-- unrecorded sales and any stock found stay inside cost of sales.
create or replace function private.approve_count_internal(p_session uuid, p_member uuid, p_at timestamptz) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.count_sessions; cl record; v_wac numeric; v_diff numeric; v_val numeric; j public.journals; v_refs jsonb := '[]'::jsonb;
  v_total numeric := 0; v_left int; v_batch uuid; v_alloc jsonb; v_acct text; v_inv text;
begin
  select * into s from count_sessions where id = p_session for update;
  if s.status not in ('awaiting_approval', 'awaiting_reasons') then raise exception 'Only submitted counts can be approved.'; end if;
  select count(*) into v_left from count_lines where session_id = s.id and counted <> expected and reason is null;
  if v_left > 0 then raise exception '% variance% still need% a reason.', v_left, case when v_left > 1 then 's' else '' end, case when v_left > 1 then '' else 's' end; end if;
  for cl in select c.*, i.name as item_name from count_lines c join items i on i.id = c.item_id
            where c.session_id = s.id and c.counted <> c.expected order by i.name loop
    v_diff := cl.counted - cl.expected;
    select wac into v_wac from item_costs where item_id = cl.item_id;
    v_val := round(abs(v_diff) * coalesce(v_wac, 0), 2);
    v_total := v_total + sign(v_diff) * v_val;
    v_acct := private.acct(s.org_id, case when v_diff < 0 and cl.reason not in ('Miscount', 'Unrecorded sale') then 'stock_loss' else 'stock_variance' end);
    v_inv := private.inv_acct(cl.item_id);
    j := private.post_journal(s.org_id, 'Count ' || s.ref || ' · ' || cl.item_name || ' · ' || cl.reason, 'adjustment', s.id,
      (select assignee_id from count_sessions where id = s.id), p_member,
      case when v_diff < 0 then jsonb_build_array(
        jsonb_build_object('code', v_acct, 'debit', v_val, 'location_id', s.location_id, 'item_id', cl.item_id),
        jsonb_build_object('code', v_inv, 'credit', v_val, 'location_id', s.location_id, 'item_id', cl.item_id))
      else jsonb_build_array(
        jsonb_build_object('code', v_inv, 'debit', v_val, 'location_id', s.location_id, 'item_id', cl.item_id),
        jsonb_build_object('code', v_acct, 'credit', v_val, 'location_id', s.location_id, 'item_id', cl.item_id)) end, p_at);
    v_batch := null;
    if v_diff < 0 then
      v_alloc := private.consume_batches(cl.item_id, s.location_id, -v_diff);
      v_batch := (v_alloc->0->>'batch_id')::uuid;
    else
      select id into v_batch from batches where item_id = cl.item_id and location_id = s.location_id and not quarantined
        order by expiry_date desc nulls first limit 1;
      if v_batch is not null then update batches set qty_remaining = qty_remaining + v_diff where id = v_batch; end if;
    end if;
    perform private.add_movement(s.org_id, 'adjustment', cl.item_id, s.location_id, v_diff, coalesce(v_wac, 0), null, j.id,
      s.assignee_id, 'Camera count', p_at,
      jsonb_build_object('count_session_id', s.id, 'reason', cl.reason, 'note', cl.note, 'approver_id', p_member,
        'batch_id', v_batch, 'device_id', s.device_id, 'offline', s.offline));
    v_refs := v_refs || to_jsonb(j.ref);
  end loop;
  update count_sessions set status = 'approved', approved_by = p_member, approved_at = p_at where id = s.id;
  return jsonb_build_object('journals', v_refs, 'net_value', v_total);
end $$;

create or replace function private.quarantine_internal(p_batch uuid, p_member uuid, p_channel text, p_at timestamptz) returns text
language plpgsql security definer set search_path = public, private as $$
declare b public.batches; it public.items; v_wac numeric; v_val numeric; j public.journals;
begin
  select * into b from batches where id = p_batch for update;
  if b.quarantined then raise exception 'Batch % is already quarantined.', b.batch_no; end if;
  select * into it from items where id = b.item_id;
  select wac into v_wac from item_costs where item_id = b.item_id;
  if b.qty_remaining > 0 then
    v_val := round(b.qty_remaining * coalesce(v_wac, 0), 2);
    j := private.post_journal(b.org_id, 'Batch ' || b.batch_no || ' quarantined · ' || it.name ||
        coalesce(' · expiry ' || to_char(b.expiry_date, 'DD Mon YYYY'), ''), 'quarantine', b.id, p_member, p_member,
      jsonb_build_array(
        jsonb_build_object('code', private.acct(b.org_id, 'stock_loss'), 'debit', v_val, 'location_id', b.location_id, 'item_id', b.item_id),
        jsonb_build_object('code', private.inv_acct(b.item_id), 'credit', v_val, 'location_id', b.location_id, 'item_id', b.item_id)), p_at);
    perform private.add_movement(b.org_id, 'quarantine', b.item_id, b.location_id, -b.qty_remaining, coalesce(v_wac, 0), null, j.id,
      p_member, p_channel, p_at, jsonb_build_object('batch_id', b.id, 'reason', case when b.expiry_date < private.local_day(b.org_id, p_at) then 'Expired' else 'Quarantined' end,
        'note', 'Batch ' || b.batch_no || ' · out of sellable stock'));
  end if;
  update batches set quarantined = true, quarantined_at = p_at, quarantined_by = p_member where id = b.id;
  return j.ref;
end $$;

-- Shipment charges post to 5105 (duty and levies) and 5104 (everything else). The share on
-- stock still on hand then moves into inventory through 5400; the share on stock already
-- sold stays in cost of sales.
create or replace function public.post_landed_cost(p_receipt uuid, p_charges jsonb, p_payee text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.receipts; m public.members; k text; v numeric; v_total numeric := 0; v_lines numeric; v_alloc numeric; v_left numeric;
  x record; v_onhand numeric; v_absorb numeric := 0; v_expense numeric := 0; v_out jsonb := '[]'::jsonb; j public.journals; v_n int; v_i int := 0;
  v_duty numeric := 0; v_acct text; v_by_acct jsonb := '{}'::jsonb; v_jl jsonb;
begin
  select * into r from receipts where id = p_receipt;
  if not found then raise exception 'Receipt not found.'; end if;
  m := private.require(r.org_id, 'edit_prices');
  if r.status <> 'posted' then raise exception 'Post the receipt before allocating landed cost.'; end if;
  for k, v in select key, nullif(value #>> '{}', '')::numeric from jsonb_each(coalesce(p_charges, '{}'::jsonb)) loop
    if v is null then continue; end if;
    if v < 0 then raise exception 'Charges cannot be negative.'; end if;
    v_total := v_total + v;
    if k ~* '(duty|levy|tariff|customs|excise)' then v_duty := v_duty + v; end if;
  end loop;
  v_total := round(v_total, 2);
  v_duty := round(v_duty, 2);
  if v_total <= 0 then raise exception 'Enter at least one charge.'; end if;
  select coalesce(sum(value), 0), count(*) into v_lines, v_n from movements where receipt_id = r.id and type = 'receipt';
  if v_lines <= 0 then raise exception 'This receipt has no stock lines to allocate to.'; end if;
  v_left := v_total;
  for x in select mv.item_id, sum(mv.qty) qty, sum(mv.value) val, max(i.name) name from movements mv join items i on i.id = mv.item_id
           where mv.receipt_id = r.id and mv.type = 'receipt' group by mv.item_id order by sum(mv.value) desc loop
    v_i := v_i + 1;
    v_alloc := case when v_i = (select count(distinct item_id) from movements where receipt_id = r.id and type = 'receipt') then v_left
                    else round(v_total * x.val / v_lines, 2) end;
    v_left := v_left - v_alloc;
    select coalesce(sum(qty), 0) into v_onhand from stock_levels where item_id = x.item_id;
    if v_onhand > 0 then
      update item_costs set wac = round(wac + v_alloc / v_onhand, 4), updated_at = now() where item_id = x.item_id;
      v_absorb := v_absorb + v_alloc;
      v_acct := private.inv_acct(x.item_id);
      v_by_acct := jsonb_set(v_by_acct, array[v_acct], to_jsonb(coalesce((v_by_acct->>v_acct)::numeric, 0) + v_alloc));
    else
      v_expense := v_expense + v_alloc;
    end if;
    v_out := v_out || jsonb_build_object('item_id', x.item_id, 'name', x.name, 'invoice', x.val, 'share', round(x.val / v_lines, 4), 'allocated', v_alloc,
      'absorbed', v_onhand > 0);
  end loop;
  v_jl := jsonb_build_array(
    jsonb_build_object('code', private.acct(r.org_id, 'landed_duty'), 'debit', v_duty, 'memo', 'Duty on the shipment'),
    jsonb_build_object('code', private.acct(r.org_id, 'landed_freight'), 'debit', v_total - v_duty, 'memo', 'Clearing, haulage and agent fees'),
    jsonb_build_object('code', private.acct(r.org_id, 'payables'), 'credit', v_total, 'memo', coalesce(nullif(trim(p_payee), ''), 'Clearing and haulage')));
  for v_acct, v in select key, value::numeric from jsonb_each_text(v_by_acct) order by key loop
    v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', v_acct, 'debit', v, 'location_id', r.location_id, 'memo', 'Charges added to stock value'));
  end loop;
  v_jl := v_jl || jsonb_build_array(jsonb_build_object('code', private.acct(r.org_id, 'inventory_movement'), 'credit', v_absorb,
    'location_id', r.location_id, 'memo', 'Charges moved into stock'));
  j := private.post_journal(r.org_id, 'Landed cost · ' || r.ref || coalesce(' · ' || nullif(trim(p_payee), ''), ''), 'landed_cost', r.id, m.id, m.id, v_jl);
  insert into landed_costs (org_id, receipt_id, charges, total, allocation, journal_id, created_by)
  values (r.org_id, r.id, p_charges, v_total, v_out, j.id, m.id);
  return jsonb_build_object('journal_ref', j.ref, 'total', v_total, 'absorbed', v_absorb, 'expensed', v_expense, 'allocation', v_out);
end $$;

-- The sample business (Kelandellen) posts through the same rules.
create or replace function public.create_sample_business() returns uuid
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := auth.uid(); v_org uuid; v_owner uuid; v_sur uuid; v_yab uuid;
  v_musa uuid; v_blessing uuid; v_tunde uuid; v_name text; v_tz text := 'Africa/Lagos'; v_today date;
  v_dufil uuid; v_chidi uuid; v_ojodu uuid; v_ebuka uuid; v_nbc uuid; v_nkechi uuid;
  r record; d int; v_day date; v_at timestamptz; j public.journals; v_lines jsonb; v_total numeric;
  v_cs uuid; v_tr uuid; v_id uuid; v_loc uuid; v_code text; v_ref text; v_val numeric; v_qty numeric;
  v_raw jsonb; v_si jsonb := '[]'::jsonb; v_ids jsonb := '{}'::jsonb; v_open jsonb;
begin
  if v_uid is null then raise exception 'Sign in first.'; end if;
  select o.id into v_org from orgs o join members m on m.org_id = o.id
  where o.is_sample and m.user_id = v_uid and m.status = 'active' limit 1;
  if v_org is not null then return v_org; end if;

  select coalesce(nullif(trim(raw_user_meta_data->>'full_name'), ''), initcap(split_part(email, '@', 1))) into v_name
  from auth.users where id = v_uid;
  v_org := public.create_org('Kelandellen Company Limited', 'kelandellen@outlook.com', '+234 803 555 0142', v_name,
    '[{"name":"Surulere","code":"SUR","address":"14 Adeniran Ogunsanya St · main"},{"name":"Yaba","code":"YAB","address":"23 Herbert Macaulay Way"}]'::jsonb,
    true, true);
  update orgs set cash_available = 1840000 where id = v_org;
  v_today := (now() at time zone v_tz)::date;
  select id into v_owner from members where org_id = v_org and user_id = v_uid;
  select id into v_sur from locations where org_id = v_org and code = 'SUR';
  select id into v_yab from locations where org_id = v_org and code = 'YAB';

  -- Team without logins (sample staff)
  insert into members (org_id, display_name, role, title, location_id, status, phone,
    p_record_sales, p_receive_stock, p_count_stock, p_approve_adjustments, p_edit_prices, p_approve_pos, p_transfer_stock, p_see_margins)
  values (v_org, 'Musa Ibrahim', 'manager', 'Branch manager', v_yab, 'active', '+2348035550101', true, true, true, false, false, false, true, true)
  returning id into v_musa;
  insert into members (org_id, display_name, role, title, location_id, status, phone,
    p_record_sales, p_receive_stock, p_count_stock, p_approve_adjustments, p_edit_prices, p_approve_pos, p_transfer_stock, p_see_margins)
  values (v_org, 'Blessing Okafor', 'staff', 'Store assistant', v_sur, 'active', '+2348035550102', true, true, true, false, false, false, false, false)
  returning id into v_blessing;
  insert into members (org_id, display_name, role, title, location_id, status, phone,
    p_record_sales, p_receive_stock, p_count_stock, p_approve_adjustments, p_edit_prices, p_approve_pos, p_transfer_stock, p_see_margins)
  values (v_org, 'Tunde Adeyemi', 'cashier', 'Cashier', v_sur, 'active', '+2348035550103', true, false, false, false, false, false, false, false)
  returning id into v_tunde;

  -- Vendors
  insert into vendors (org_id, name, location, channel, phone, email, vat_registered, lead_time_days, credit_days, fill_rate, price_stability, notes)
  values (v_org, 'Dufil Prima Foods', 'Ota depot', 'email', '+2348035550201', 'orders.dufil@example.com', true, 2, 14, 98, 'High', 'Direct from manufacturer')
  returning id into v_dufil;
  insert into vendors (org_id, name, location, channel, phone, email, vat_registered, lead_time_days, credit_days, fill_rate, price_stability, notes)
  values (v_org, 'Chidi & Sons Distribution', 'Trade Fair, Lagos', 'whatsapp', '+2348035550202', null, true, 1, 7, 94, 'Medium', null)
  returning id into v_chidi;
  insert into vendors (org_id, name, location, channel, phone, email, vat_registered, lead_time_days, credit_days, fill_rate, price_stability, notes)
  values (v_org, 'Ojodu Foods (Nestlé)', 'Ojodu Berger', 'whatsapp', '+2348035550203', null, true, 3, 0, 88, 'High', null)
  returning id into v_ojodu;
  insert into vendors (org_id, name, location, channel, phone, email, vat_registered, lead_time_days, credit_days, fill_rate, price_stability, notes)
  values (v_org, 'Ebuka Stores', 'Onitsha Main Market', 'whatsapp', '+2348035550204', null, false, 4, 30, 100, 'Low', null)
  returning id into v_ebuka;
  insert into vendors (org_id, name, location, channel, phone, email, vat_registered, lead_time_days, credit_days, fill_rate, price_stability, notes)
  values (v_org, 'NBC Depot Ijora', 'Ijora, Lagos', 'email', '+2348035550205', 'ijora.depot@example.com', true, 1, 7, 97, 'High', 'Bottler depot')
  returning id into v_nbc;
  insert into vendors (org_id, name, location, channel, phone, email, vat_registered, lead_time_days, credit_days, fill_rate, price_stability, notes)
  values (v_org, 'Mama Nkechi Stores', 'Idumota market', 'whatsapp', '+2348035550206', null, false, 0, 0, 100, 'Low', 'Same-day cash purchases')
  returning id into v_nkechi;

  -- Item master; sur/yab are today's on-hand per branch, vel is units/day across both.
  v_raw := jsonb_build_array(
    jsonb_build_object('k','indomie','name','Indomie Chicken 70g','cat','Noodles','barcode','6156000012345','pu','Carton','pack',40,'su','pack','cost',265,'price',300,'sur',4440,'yab',960,'floor',1200,'vel',310,'vendor',v_dufil,'alt',v_chidi,'vat','standard','informal',false,'imp',false,'uplift',0.18),
    jsonb_build_object('k','peak','name','Peak Evaporated Milk 160g','cat','Dairy','barcode','8716200321234','pu','Carton','pack',48,'su','tin','cost',505,'price',550,'sur',384,'yab',144,'floor',480,'vel',62,'vendor',v_chidi,'alt',v_ojodu,'vat','standard','informal',false,'imp',true,'uplift',0),
    jsonb_build_object('k','milo','name','Milo Activ-Go 400g','cat','Beverages','barcode','7613036123457','pu','Carton','pack',12,'su','tin','cost',2650,'price',2950,'sur',72,'yab',36,'floor',48,'vel',9,'vendor',v_ojodu,'alt',v_chidi,'vat','standard','informal',false,'imp',false,'uplift',0.12),
    jsonb_build_object('k','semo','name','Golden Penny Semovita 1kg','cat','Staples','barcode','6151100021116','pu','Bag','pack',10,'su','pack','cost',1480,'price',1650,'sur',210,'yab',80,'floor',100,'vel',18,'vendor',v_chidi,'vat','zero','informal',false,'imp',false,'uplift',0),
    jsonb_build_object('k','rice','name','Mama''s Pride Rice 50kg','cat','Staples','pu','Bag','pack',52,'su','derica','cost',1750,'price',2000,'sur',416,'yab',0,'floor',208,'vel',35,'vendor',v_ebuka,'alt',v_chidi,'vat','zero','informal',true,'imp',false,'uplift',0),
    jsonb_build_object('k','sugar','name','Dangote Sugar 1kg','cat','Staples','barcode','6154000011220','pu','Bale','pack',20,'su','pack','cost',1380,'price',1500,'sur',140,'yab',60,'floor',120,'vel',14,'vendor',v_chidi,'vat','standard','informal',false,'imp',false,'uplift',0),
    jsonb_build_object('k','coke','name','Coca-Cola 50cl PET','cat','Drinks','barcode','5449000000996','pu','Pack','pack',12,'su','bottle','cost',245,'price',300,'sur',600,'yab',276,'floor',360,'vel',85,'vendor',v_nbc,'alt',v_chidi,'vat','standard','informal',false,'imp',false,'uplift',0),
    jsonb_build_object('k','eva','name','Eva Water 75cl','cat','Drinks','barcode','6156000234567','pu','Pack','pack',12,'su','bottle','cost',180,'price',250,'sur',216,'yab',120,'floor',360,'vel',70,'vendor',v_nbc,'alt',v_chidi,'vat','standard','informal',false,'imp',false,'uplift',0),
    jsonb_build_object('k','dettol','name','Dettol Soap 110g','cat','Personal care','barcode','6001106110086','pu','Carton','pack',72,'su','bar','cost',520,'price',600,'sur',288,'yab',144,'floor',144,'vel',11,'vendor',v_chidi,'vat','standard','informal',false,'imp',false,'uplift',0),
    jsonb_build_object('k','omo','name','OMO Detergent 900g','cat','Household','barcode','6001087357623','pu','Bag','pack',12,'su','sachet','cost',1900,'price',2200,'sur',48,'yab',24,'floor',36,'vel',4,'vendor',v_chidi,'vat','standard','informal',false,'imp',false,'uplift',0),
    jsonb_build_object('k','goldenmorn','name','Golden Morn 1kg','cat','Breakfast','barcode','7613035012349','pu','Carton','pack',10,'su','pack','cost',3400,'price',3600,'sur',60,'yab',20,'floor',30,'vel',2.5,'vendor',v_ojodu,'vat','standard','informal',false,'imp',true,'uplift',0.15),
    jsonb_build_object('k','kingsoil','name','Kings Vegetable Oil 3L','cat','Staples','barcode','6156000345678','pu','Carton','pack',6,'su','bottle','cost',7400,'price',7900,'sur',36,'yab',12,'floor',24,'vel',3,'vendor',v_chidi,'vat','zero','informal',false,'imp',true,'uplift',0),
    jsonb_build_object('k','panadol','name','Panadol Extra (24 tabs)','cat','OTC medicine','barcode','5000347012345','pu','Carton','pack',100,'su','pack','cost',900,'price',1100,'sur',100,'yab',60,'floor',60,'vel',5,'vendor',v_ojodu,'vat','exempt','informal',false,'nafdac','A4-0271','imp',false,'uplift',0),
    jsonb_build_object('k','harpic','name','Harpic Toilet Cleaner 500ml','cat','Household','barcode','8901396350019','pu','Carton','pack',12,'su','bottle','cost',1650,'price',1900,'sur',84,'yab',0,'floor',24,'vel',0,'vendor',v_chidi,'vat','standard','informal',false,'imp',false,'uplift',0),
    jsonb_build_object('k','ovaltine','name','Ovaltine 400g','cat','Beverages','barcode','7612100055366','pu','Carton','pack',12,'su','tin','cost',2400,'price',2700,'sur',60,'yab',0,'floor',24,'vel',0,'vendor',v_ojodu,'vat','standard','informal',false,'imp',false,'uplift',0),
    jsonb_build_object('k','closeup','name','Close-Up Red Hot 140g','cat','Personal care','barcode','6001087378024','pu','Carton','pack',72,'su','tube','cost',780,'price',900,'sur',216,'yab',72,'floor',144,'vel',12,'vendor',v_chidi,'vat','standard','informal',false,'imp',false,'uplift',0));

  for r in select * from private.seed_items(v_raw) loop
    insert into items (org_id, name, barcode, category, vat_treatment, nafdac_no, purchase_unit, pack_size, selling_unit, informal_unit,
      track_batches, reorder_floor, preferred_vendor_id, alt_vendor_id, price, import_priced, created_by, created_at)
    values (v_org, r.name, r.barcode, r.cat, r.vat, r.nafdac, r.pu, r.pack, r.su, coalesce(r.informal, false), false, r.floor, r.vendor, r.alt,
      r.price, coalesce(r.imp, false), v_owner, now() - interval '140 days')
    returning id into v_id;
    insert into item_costs (item_id, org_id, wac, last_cost) values (v_id, v_org, r.cost, r.cost);
    v_ids := v_ids || jsonb_build_object(r.k, v_id);
    v_si := v_si || jsonb_build_array(to_jsonb(r) || jsonb_build_object('id', v_id,
      'share', case when r.yab = 0 then 1 else least(0.85, greatest(0.55, r.sur / (r.sur + r.yab))) end));
  end loop;

  -- Back-solve opening balances: today's stock, minus planned receipts/transfers/adjustments, plus 60 days of sales.
  with pe(k, code, qty) as (values
    ('indomie', 'SUR', 2400), ('indomie', 'SUR', 200), ('peak', 'SUR', 96), ('sugar', 'SUR', 10), ('closeup', 'SUR', 216), ('eva', 'SUR', 120),
    ('coke', 'SUR', 240), ('eva', 'SUR', 480),
    ('peak', 'SUR', 480), ('semo', 'SUR', 100), ('sugar', 'SUR', 80), ('dettol', 'SUR', 144), ('kingsoil', 'SUR', 24),
    ('indomie', 'SUR', -400), ('indomie', 'YAB', 400), ('peak', 'SUR', -192), ('peak', 'YAB', 192),
    ('coke', 'YAB', -6), ('eva', 'YAB', -4), ('indomie', 'YAB', -120),
    ('harpic', 'SUR', -6), ('ovaltine', 'SUR', -4))
  select jsonb_object_agg(s.k || '|' || c.code,
      (case when c.code = 'SUR' then s.sur else s.yab end)
      - coalesce((select sum(pe.qty) from pe where pe.k = s.k and pe.code = c.code), 0)
      + coalesce((select sum(private.seed_qty(s.k, s.vel, s.share, s.uplift, g.day::date, c.code, v_today))
                  from generate_series(v_today - 60, v_today - 1, interval '1 day') g(day)), 0))
  into v_open
  from private.seed_items(v_si) s cross join (values ('SUR'), ('YAB')) c(code);

  for v_code in select unnest(array['SUR', 'YAB']) loop
    v_loc := case when v_code = 'SUR' then v_sur else v_yab end;
    v_at := ((v_today - 130) + time '08:00') at time zone v_tz;
    select coalesce(sum(round((v_open->>(s.k || '|' || v_code))::numeric * s.cost, 2)), 0) into v_total
    from private.seed_items(v_si) s where (v_open->>(s.k || '|' || v_code))::numeric > 0;
    j := private.post_journal(v_org, 'Opening stock · ' || case when v_code = 'SUR' then 'Surulere' else 'Yaba' end || ' · stock_list_jun.xlsx',
      'opening', null, v_owner, null,
      jsonb_build_array(jsonb_build_object('code', private.acct(v_org, 'inventory'), 'debit', v_total, 'location_id', v_loc, 'memo', 'Opening stock'),
                        jsonb_build_object('code', private.acct(v_org, 'opening_equity'), 'credit', v_total, 'location_id', v_loc)), v_at);
    for r in select * from private.seed_items(v_si) s where (v_open->>(s.k || '|' || v_code))::numeric > 0 loop
      perform private.add_movement(v_org, 'opening', r.id, v_loc, (v_open->>(r.k || '|' || v_code))::numeric,
        r.cost, null, j.id, v_owner, 'Import', v_at, '{"note":"stock_list_jun.xlsx"}'::jsonb);
    end loop;
  end loop;

  -- The last sales of what is now dead stock
  perform private.sale_internal(v_org, (v_ids->>'harpic')::uuid, v_sur, 6, null, v_tunde, 'Invoicing rail', 'sale',
    ((v_today - 118) + time '17:40') at time zone v_tz, '{}'::jsonb);
  perform private.sale_internal(v_org, (v_ids->>'ovaltine')::uuid, v_sur, 4, null, v_tunde, 'Invoicing rail', 'sale',
    ((v_today - 96) + time '12:15') at time zone v_tz, '{}'::jsonb);

  -- Walk forward day by day
  for d in reverse 60..0 loop
    v_day := v_today - d;

    if d = 16 then
      insert into count_sessions (org_id, ref, location_id, area, assignee_id, status, created_by, submitted_at, approved_by, approved_at, device_id, offline, created_at)
      values (v_org, 'CS-' || lpad(private.next_no(v_org, 'CS', 12)::text, 3, '0'), v_sur, 'Aisle 1 · Staples', v_blessing, 'approved', v_owner,
        (v_day + time '18:05') at time zone v_tz, v_owner, (v_day + time '21:00') at time zone v_tz, 'Itel A70 · Blessing', true,
        (v_day + time '09:00') at time zone v_tz)
      returning id into v_cs;
      insert into count_lines (session_id, org_id, item_id, expected, counted)
      select v_cs, v_org, s.id, coalesce(sl.qty, 0), coalesce(sl.qty, 0)
      from private.seed_items(v_si) s left join stock_levels sl on sl.item_id = s.id and sl.location_id = v_sur where s.cat = 'Staples';
    end if;

    if d = 13 then
      perform private.seed_receipt(v_org, v_chidi, v_sur, 'photo_typed', 'CSD/24/1187', true, jsonb_build_array(
        jsonb_build_object('item_id', v_ids->>'peak', 'raw', 'PEAK EVAP MILK 160G x48 — 10 CTN', 'qty', 10, 'unit', 'ctn', 'cost', 24240),
        jsonb_build_object('item_id', v_ids->>'semo', 'raw', 'G/PENNY SEMOVITA 1KG x10 — 10 BAG', 'qty', 10, 'unit', 'bag', 'cost', 14800),
        jsonb_build_object('item_id', v_ids->>'sugar', 'raw', 'DANGOTE SUGAR 1KG x20 — 4 BALE', 'qty', 4, 'unit', 'bale', 'cost', 27600),
        jsonb_build_object('item_id', v_ids->>'dettol', 'raw', 'DETTOL SOAP 110G x72 — 2 CTN', 'qty', 2, 'unit', 'ctn', 'cost', 37440),
        jsonb_build_object('item_id', v_ids->>'kingsoil', 'raw', 'KINGS VEG OIL 3L x6 — 4 CTN', 'qty', 4, 'unit', 'ctn', 'cost', 44400)),
        v_blessing, (v_day + time '10:20') at time zone v_tz, true);
    end if;

    if d = 9 then
      insert into count_sessions (org_id, ref, location_id, area, assignee_id, status, created_by, submitted_at, device_id, offline, created_at)
      values (v_org, 'CS-' || lpad(private.next_no(v_org, 'CS', 12)::text, 3, '0'), v_yab, 'Whole store', v_musa, 'awaiting_approval', v_owner,
        (v_day + time '19:10') at time zone v_tz, 'Tecno Spark 10 · Musa', false, (v_day + time '08:30') at time zone v_tz)
      returning id into v_cs;
      insert into count_lines (session_id, org_id, item_id, expected, counted, reason)
      select v_cs, v_org, s.id, coalesce(sl.qty, 0),
        coalesce(sl.qty, 0) + case s.k when 'coke' then -6 when 'eva' then -4 else 0 end,
        case s.k when 'coke' then 'Breakage' when 'eva' then 'Unrecorded sale' end
      from private.seed_items(v_si) s left join stock_levels sl on sl.item_id = s.id and sl.location_id = v_yab
      where coalesce(sl.qty, 0) > 0 or s.k in ('coke', 'eva');
      perform private.approve_count_internal(v_cs, v_owner, (v_day + time '21:15') at time zone v_tz);
    end if;

    if d = 8 then
      perform private.seed_receipt(v_org, v_ebuka, v_sur, 'photo_handwritten', null, false, jsonb_build_array(
        jsonb_build_object('item_id', v_ids->>'rice', 'raw', '2 bag Mama Pride rice', 'qty', 2, 'unit', 'bag', 'cost', 91000, 'conf', 93),
        jsonb_build_object('item_id', v_ids->>'semo', 'raw', '1 bag semo', 'qty', 1, 'unit', 'bag', 'cost', 14800, 'conf', 61,
          'ok', false, 'alt', jsonb_build_object('label', '11 bags', 'qty', 11))),
        v_blessing, (v_day + time '16:05') at time zone v_tz, false);
    end if;

    if d = 7 then
      perform private.seed_receipt(v_org, v_nbc, v_sur, 'pdf', 'NBC-IJR-55120', true, jsonb_build_array(
        jsonb_build_object('item_id', v_ids->>'coke', 'raw', 'COKE 50CL PET x12 — 20 PK', 'qty', 20, 'unit', 'pk', 'cost', 2940),
        jsonb_build_object('item_id', v_ids->>'eva', 'raw', 'EVA WATER 75CL x12 — 40 PK', 'qty', 40, 'unit', 'pk', 'cost', 2160)),
        v_owner, (v_day + time '11:00') at time zone v_tz, true);
    end if;

    if d in (6, 1) then
      v_id := (v_ids->>(case when d = 6 then 'indomie' else 'peak' end))::uuid;
      v_qty := case when d = 6 then 400 else 192 end;
      v_at := (v_day + case when d = 6 then time '12:00' else time '15:40' end) at time zone v_tz;
      v_val := round(v_qty * (select wac from item_costs where item_id = v_id), 2);
      v_ref := 'TR-' || lpad(private.next_no(v_org, 'TR', 6)::text, 4, '0');
      insert into transfers (org_id, ref, item_id, qty, unit_cost, from_location_id, to_location_id, created_by, created_at)
      values (v_org, v_ref, v_id, v_qty, (select wac from item_costs where item_id = v_id), v_sur, v_yab, v_owner, v_at)
      returning id into v_tr;
      j := private.post_journal(v_org, 'Transfer ' || v_ref || ' · Surulere → Yaba', 'transfer', v_tr, v_owner, null,
        jsonb_build_array(jsonb_build_object('code', private.acct(v_org, 'goods_in_transit'), 'debit', v_val, 'item_id', v_id, 'memo', 'In transit to Yaba'),
                          jsonb_build_object('code', private.inv_acct(v_id), 'credit', v_val, 'location_id', v_sur, 'item_id', v_id)), v_at);
      perform private.add_movement(v_org, 'transfer_out', v_id, v_sur, -v_qty, (select wac from item_costs where item_id = v_id),
        null, j.id, v_owner, 'App', v_at, jsonb_build_object('transfer_id', v_tr, 'note', 'Surulere → Yaba'));
      perform private.receive_transfer_internal(v_tr, v_musa, v_at + interval '90 minutes');
    end if;

    if d = 4 then
      perform private.sale_internal(v_org, (v_ids->>'indomie')::uuid, v_yab, 120, null, v_musa, 'Voice (Pidgin)', 'voice_sale',
        (v_day + time '09:30') at time zone v_tz,
        jsonb_build_object('note', '"I don sell three cartons of Indomie"', 'review_status', 'reviewed', 'device_id', 'Tecno Spark 10 · Musa'));
    end if;

    if d = 3 then
      perform private.seed_receipt(v_org, v_nkechi, v_sur, 'photo_handwritten', null, false, jsonb_build_array(
        jsonb_build_object('item_id', v_ids->>'indomie', 'raw', '5 ctn Indomie chikin', 'qty', 5, 'unit', 'ctn', 'cost', 10600, 'conf', 97),
        jsonb_build_object('item_id', v_ids->>'peak', 'raw', '2 ctn Peak milk', 'qty', 2, 'unit', 'ctn', 'cost', 25200, 'conf', 91),
        jsonb_build_object('item_id', v_ids->>'sugar', 'raw', 'half bag Dangote sugar', 'qty', 10, 'kind', 'selling', 'unit', 'pack', 'cost', 1380, 'conf', 58,
          'alt', jsonb_build_object('label', '1 bag (20 packs)', 'qty', 20)),
        jsonb_build_object('item_id', v_ids->>'closeup', 'raw', '3 ctn Close Up 140g', 'qty', 3, 'unit', 'ctn', 'cost', 56160, 'conf', 88),
        jsonb_build_object('item_id', v_ids->>'eva', 'raw', '10 pk Eva water', 'qty', 10, 'unit', 'pk', 'cost', 2160, 'conf', 44,
          'alt', jsonb_build_object('label', '16 packs', 'qty', 16))),
        v_blessing, (v_day + time '13:48') at time zone v_tz, true);
    end if;

    if d = 0 then
      perform private.seed_receipt(v_org, v_dufil, v_sur, 'pdf', 'INV-88231', true, jsonb_build_array(
        jsonb_build_object('item_id', v_ids->>'indomie', 'raw', 'Indomie Chicken 70g × 40 — 60 CTN', 'qty', 60, 'unit', 'ctn', 'cost', 10600, 'conf', 99)),
        v_owner, least(now() - interval '5 minutes', (v_day + time '09:12') at time zone v_tz), true);
    end if;

    -- Day close at each branch (Saturdays at Surulere are split across two cashiers)
    if d >= 1 then
      v_at := (v_day + time '20:05') at time zone v_tz;
      for v_code in select unnest(array['SUR', 'YAB']) loop
        v_loc := case when v_code = 'SUR' then v_sur else v_yab end;
        if v_code = 'SUR' and extract(isodow from v_day) = 6 then
          select coalesce(jsonb_agg(jsonb_build_object('item_id', s.id, 'qty', q.qty, 'price', s.price)), '[]'::jsonb) into v_lines
          from private.seed_items(v_si) s cross join lateral (select private.seed_qty(s.k, s.vel, s.share, s.uplift, v_day, v_code, v_today) qty) q
          where q.qty > 0 and abs(hashtext(s.k)::bigint) % 2 = 0;
          if jsonb_array_length(v_lines) > 0 then perform private.post_day_close(v_org, v_loc, v_tunde, v_lines, v_at); end if;
          select coalesce(jsonb_agg(jsonb_build_object('item_id', s.id, 'qty', q.qty, 'price', s.price)), '[]'::jsonb) into v_lines
          from private.seed_items(v_si) s cross join lateral (select private.seed_qty(s.k, s.vel, s.share, s.uplift, v_day, v_code, v_today) qty) q
          where q.qty > 0 and abs(hashtext(s.k)::bigint) % 2 = 1;
          if jsonb_array_length(v_lines) > 0 then perform private.post_day_close(v_org, v_loc, v_blessing, v_lines, v_at + interval '2 minutes'); end if;
        else
          select coalesce(jsonb_agg(jsonb_build_object('item_id', s.id, 'qty', q.qty, 'price', s.price)), '[]'::jsonb) into v_lines
          from private.seed_items(v_si) s cross join lateral (select private.seed_qty(s.k, s.vel, s.share, s.uplift, v_day, v_code, v_today) qty) q
          where q.qty > 0;
          if jsonb_array_length(v_lines) > 0 then
            perform private.post_day_close(v_org, v_loc, case when v_code = 'SUR' then v_tunde else v_musa end, v_lines,
              v_at + case when v_code = 'SUR' then interval '0 minutes' else interval '4 minutes' end);
          end if;
        end if;
      end loop;
    end if;
  end loop;

  -- Batch tracking for regulated / perishable lines, matching today's stock
  update items set track_batches = true where id in ((v_ids->>'peak')::uuid, (v_ids->>'panadol')::uuid, (v_ids->>'goldenmorn')::uuid);
  insert into batches (org_id, item_id, location_id, batch_no, expiry_date, qty_received, qty_remaining, created_at) values
    (v_org, (v_ids->>'peak')::uuid, v_sur, 'PK24020', v_today - 16, 240, 24, now() - interval '120 days'),
    (v_org, (v_ids->>'peak')::uuid, v_sur, 'PK24091', v_today + 17, 480, 144, now() - interval '40 days'),
    (v_org, (v_ids->>'peak')::uuid, v_sur, 'PK25033', v_today + 150, 480, 216, now() - interval '13 days'),
    (v_org, (v_ids->>'peak')::uuid, v_yab, 'PK25033', v_today + 150, 192, 144, now() - interval '1 day'),
    (v_org, (v_ids->>'panadol')::uuid, v_sur, 'PE7731', v_today + 12, 100, 40, now() - interval '100 days'),
    (v_org, (v_ids->>'panadol')::uuid, v_sur, 'PE8104', v_today + 472, 100, 60, now() - interval '60 days'),
    (v_org, (v_ids->>'panadol')::uuid, v_yab, 'PE8104', v_today + 472, 60, 60, now() - interval '60 days'),
    (v_org, (v_ids->>'goldenmorn')::uuid, v_sur, 'GM26C', v_today + 65, 100, 60, now() - interval '50 days'),
    (v_org, (v_ids->>'goldenmorn')::uuid, v_yab, 'GM26C', v_today + 65, 30, 20, now() - interval '50 days');

  -- A fresh supplier quote that sits above the current shelf price
  update item_costs set replacement_cost = 8200, replacement_source = 'Chidi quote · ' || to_char(v_today - 1, 'DD Mon')
  where item_id = (v_ids->>'kingsoil')::uuid;

  -- Count waiting for the owner: Aisle 3 at Surulere
  insert into count_sessions (org_id, ref, location_id, area, assignee_id, status, created_by, submitted_at, device_id, offline, created_at)
  values (v_org, 'CS-' || lpad(private.next_no(v_org, 'CS', 12)::text, 3, '0'), v_sur, 'Aisle 3 · Drinks & dairy', v_blessing, 'awaiting_approval',
    v_owner, ((v_today - 2) + time '17:22') at time zone v_tz, 'Itel A70 · Blessing', true, ((v_today - 2) + time '09:00') at time zone v_tz)
  returning id into v_cs;
  insert into count_lines (session_id, org_id, item_id, expected, counted, reason)
  select v_cs, v_org, s.id, coalesce(sl.qty, 0),
    coalesce(sl.qty, 0) + case s.k when 'coke' then -12 when 'eva' then -6 when 'peak' then 2 else 0 end,
    case s.k when 'coke' then 'Breakage' when 'eva' then 'Unrecorded sale' when 'peak' then 'Miscount' end
  from private.seed_items(v_si) s left join stock_levels sl on sl.item_id = s.id and sl.location_id = v_sur
  where s.k in ('coke', 'eva', 'peak', 'milo');

  -- Recorded takings (cash + POS + transfers). Saturdays at Surulere run short for four weeks.
  insert into cash_takings (org_id, location_id, day, cash, pos, transfers, source)
  select v_org, x.location_id, x.d, round(t.rec * 0.41), round(t.rec * 0.44), t.rec - round(t.rec * 0.41) - round(t.rec * 0.44), 'sample'
  from (
    select (mv.recorded_at at time zone v_tz)::date d, mv.location_id, round(sum(-mv.qty * coalesce(mv.unit_price, 0))) implied
    from movements mv where mv.org_id = v_org and mv.type in ('sale', 'voice_sale') and mv.recorded_at > now() - interval '43 days'
    group by 1, 2
  ) x
  cross join lateral (select case
      when x.location_id = v_sur and extract(isodow from x.d) = 6 and x.d >= v_today - 28
        then x.implied - (40000 + (abs(hashtext(x.d::text)::bigint) % 25000))
      else round(x.implied * (0.994 + (abs(hashtext(x.d::text || x.location_id::text)::bigint) % 6) / 1000.0)) end as rec) t
  where x.d < v_today;

  perform private.refresh_price_alerts_internal(v_org);
  return v_org;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Changing the mapping
-- ---------------------------------------------------------------------------
-- Owner only. Moving the inventory or goods-in-transit role posts a reclass journal so the
-- stock value follows the new account. The other roles apply to new postings from now on.
create or replace function public.set_posting_rule(p_org uuid, p_role text, p_code text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; pr public.posting_roles; v_old text; v_name text; v_lines jsonb := '[]'::jsonb; x record; j public.journals;
begin
  m := private.require(p_org, 'owner');
  select * into pr from posting_roles where role = p_role;
  if not found then raise exception 'Unknown posting rule.'; end if;
  select name into v_name from accounts where code = p_code and active and not is_group;
  if v_name is null or p_code !~ pr.allowed then
    raise exception '% cannot be used for %.', coalesce(p_code, 'That account'), lower(pr.label);
  end if;
  v_old := private.acct(p_org, p_role);
  if v_old = p_code then return jsonb_build_object('changed', false, 'account_code', p_code, 'account_name', v_name); end if;

  -- When no item names the old account itself, its whole ledger balance moves, so not even a
  -- rounding cent is left behind. Otherwise only the stock of items on the default moves, at WAC.
  if p_role = 'goods_in_transit'
     or (p_role = 'inventory' and not exists (select 1 from items where org_id = p_org and inventory_account = v_old)) then
    for x in select l.location_id, sum(l.debit - l.credit) as val from journal_lines l
             where l.org_id = p_org and l.account_code = v_old
             group by l.location_id having sum(l.debit - l.credit) <> 0 loop
      v_lines := v_lines || private.reclass_pair(p_code, v_old, x.val, x.location_id);
    end loop;
  elsif p_role = 'inventory' then
    for x in select s.location_id, round(sum(s.qty * coalesce(c.wac, 0)), 2) as val
             from stock_levels s join items i on i.id = s.item_id left join item_costs c on c.item_id = s.item_id
             where s.org_id = p_org and i.inventory_account is null
             group by s.location_id having round(sum(s.qty * coalesce(c.wac, 0)), 2) <> 0 loop
      v_lines := v_lines || private.reclass_pair(p_code, v_old, x.val, x.location_id);
    end loop;
  end if;
  if jsonb_array_length(v_lines) > 0 then
    j := private.post_journal(p_org, 'Reclass · ' || pr.label || ' from ' || v_old || ' to ' || p_code, 'reclass', null, m.id, m.id, v_lines);
  end if;

  insert into posting_rules (org_id, role, account_code, updated_by) values (p_org, p_role, p_code, m.id)
  on conflict (org_id, role) do update set account_code = excluded.account_code, updated_by = excluded.updated_by, updated_at = now();
  return jsonb_build_object('changed', true, 'account_code', p_code, 'account_name', v_name, 'journal_ref', j.ref);
end $$;

-- Owner only. p_code null puts the item back on the business's default inventory account.
create or replace function public.set_item_inventory_account(p_item uuid, p_code text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare it public.items; m public.members; v_old text; v_new text; v_wac numeric; v_lines jsonb := '[]'::jsonb; x record; j public.journals;
begin
  select * into it from items where id = p_item;
  if not found then raise exception 'Item not found.'; end if;
  m := private.require(it.org_id, 'owner');
  p_code := nullif(trim(coalesce(p_code, '')), '');
  if p_code is not null and (p_code !~ (select allowed from posting_roles where role = 'inventory')
     or not exists (select 1 from accounts where code = p_code and active and not is_group)) then
    raise exception '% is not an inventory account.', p_code;
  end if;
  v_old := private.inv_acct(p_item);
  v_new := coalesce(p_code, private.acct(it.org_id, 'inventory'));
  if v_old <> v_new then
    select wac into v_wac from item_costs where item_id = p_item;
    for x in select location_id, round(qty * coalesce(v_wac, 0), 2) as val from stock_levels
             where item_id = p_item and round(qty * coalesce(v_wac, 0), 2) <> 0 loop
      v_lines := v_lines || private.reclass_pair(v_new, v_old, x.val, x.location_id, p_item);
    end loop;
    if jsonb_array_length(v_lines) > 0 then
      j := private.post_journal(it.org_id, 'Reclass · ' || it.name || ' from ' || v_old || ' to ' || v_new, 'reclass', p_item, m.id, m.id, v_lines);
    end if;
  end if;
  perform set_config('app.reclass', 'on', true);
  update items set inventory_account = p_code where id = p_item;
  perform set_config('app.reclass', 'off', true);
  return jsonb_build_object('account_code', v_new, 'account_name', (select name from accounts where code = v_new), 'journal_ref', j.ref);
end $$;

-- What each posting role resolves to for a business, for screens and for TaxStreem.
create or replace function public.posting_map(p_org uuid)
returns table (role text, label text, description text, account_code text, account_name text, default_code text, allowed text, sort int)
language sql stable security definer set search_path = public, private as $$
  select pr.role, pr.label, pr.description, a.code, a.name, pr.default_code, pr.allowed, pr.sort
  from public.posting_roles pr
  join public.accounts a on a.code = coalesce(
    (select r.account_code from public.posting_rules r where r.org_id = p_org and r.role = pr.role), pr.default_code)
  where private.is_member(p_org)
  order by pr.sort
$$;

-- ---------------------------------------------------------------------------
-- 6. Existing journal lines move to the TaxStreem codes
-- ---------------------------------------------------------------------------
do $$
begin
perform set_config('app.allow_purge', 'on', true);

update public.journal_lines l set account_code = case
    when l.account_code = '5200' and (l.credit > 0 or exists (
      select 1 from public.movements mv where mv.journal_id = l.journal_id and mv.reason in ('Miscount', 'Unrecorded sale'))) then '5400'
    when l.account_code = '5200' then '6805'
    when l.account_code = '5100' and j.source_type = 'landed_cost' then '5104'
    when l.account_code = '5100' then '5400'
    when l.account_code = '1310' then coalesce((select i.inventory_account from public.items i where i.id = l.item_id), '1203')
    when l.account_code = '1315' then '1204'
    when l.account_code = '1420' then '1402'
    when l.account_code = '2010' then '2101'
    when l.account_code = '3100' then '3999'
  end
from public.journals j
where j.id = l.journal_id and l.account_code in ('1310', '1315', '1420', '2010', '3100', '5100', '5200');

-- Receipts and landed costs posted before today went straight to inventory. Give each one the
-- purchases-method pair so old and new entries read the same way.
insert into public.journal_lines (journal_id, org_id, account_code, debit, credit, location_id, memo)
select j.id, j.org_id, x.code, x.dr, x.cr, x.loc, x.memo
from public.journals j
cross join lateral (
  select coalesce(sum(jl.debit), 0) as amt, (array_agg(jl.location_id))[1] as loc
  from public.journal_lines jl where jl.journal_id = j.id and jl.account_code ~ '^120[1-6]$') n
cross join lateral (values
  (case when j.source_type = 'receipt' then '5101' else '5104' end, n.amt, 0::numeric, null::uuid,
   case when j.source_type = 'receipt' then 'Stock bought' else 'Charges on stock still on hand' end),
  ('5400', 0::numeric, n.amt, n.loc, case when j.source_type = 'receipt' then 'Purchases moved into stock' else 'Charges moved into stock' end)
) as x(code, dr, cr, loc, memo)
where j.source_type in ('receipt', 'landed_cost') and n.amt > 0;

perform set_config('app.allow_purge', 'off', true);
end $$;

-- Counta's interim accounts are no longer used.
update public.accounts set active = false, category = 'Retired', parent_code = null, sort = null
where code in ('1310', '1315', '1420', '2010', '3100');

do $$
begin
  if exists (select 1 from public.journal_lines l join public.accounts a on a.code = l.account_code where a.is_group or not a.active) then
    raise exception 'Journal lines still sit on header or retired accounts.';
  end if;
  if exists (select 1 from public.journal_lines group by journal_id having sum(debit) <> sum(credit)) then
    raise exception 'A journal no longer balances after the remap.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Signed-in callers only, as with every other function
-- ---------------------------------------------------------------------------
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'private') and p.prokind = 'f'
      and p.proname in ('acct', 'inv_acct', 'reclass_pair', 'guard_item_account', 'set_posting_rule', 'set_item_inventory_account', 'posting_map')
  loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;
