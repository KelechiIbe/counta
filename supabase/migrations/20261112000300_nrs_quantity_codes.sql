-- E-invoicing: NRS's quantity code list (docs/e-invoicing.md).
--
-- NRS refused an invoice whose lines gave their price unit as "NGN per 1", then as "NGN": "Enter a valid price unit,
-- check the invoice quantity code list for valid price unit" (31 October 2026). The list is UN/ECE Recommendation 20 with
-- Recommendation 21's packaging codes. The admin portal's NRS test now copies it with NRS's other code lists, so each line
-- can go with its own unit's code (a bottle as XBO, a pack as XPK); until it is copied, every line goes as C62 ("one").
-- This lets nrs_codes keep that list, under either name NRS may serve it by. Nothing else changes.

alter table public.nrs_codes drop constraint if exists nrs_codes_list_check;
alter table public.nrs_codes add constraint nrs_codes_list_check check (list in ('countries', 'currencies', 'tax-categories', 'payment-means',
  'invoice-types', 'services-codes', 'vat-exemptions', 'hs-codes', 'states', 'lgas', 'invoice-quantity-codes', 'quantity-codes'));
