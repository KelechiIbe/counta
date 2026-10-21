# Supplier invoices

Suppliers send invoices to a business on its own invoice link, and people who keep the books can upload invoices themselves (Purchases, Bills, Supplier invoices). Counta reads each one with Gemini, adds the supplier when it is new, checks the invoice and writes a draft bill. Problems the supplier must fix go to them by email or WhatsApp. The business then approves the bill for payment or rejects the invoice, and the supplier is told why.

## The invoice link

Every business has a link of the form `https://counta-taxstreem.netlify.app/v/<token>`, shown on the Supplier invoices tab with Copy, WhatsApp and Email buttons. A supplier opens it with no account, gives a name and an email or a WhatsApp number, and uploads a PDF or a photo (JPEG, PNG or WebP, up to 8 MB). The page shows the result at once: the reference (`SI-00001`), and anything the supplier must fix.

Someone who keeps the books can switch the link off, make a new one (the old one stops working), and choose whether suppliers are told about problems automatically. The link also follows the business's plan (the Supplier invoice portal module) and TaxStreem's switch of the same name. Sample businesses never take invoices on a link.

Limits keep the link from being abused: ten uploads an hour from one address, a hundred a day on one link, and 120 invoices an hour read for one business however they arrive.

## What Counta checks

Each check is graded. A check that stops payment holds the bill; the others are for the business to weigh, and errors in the sums or the VAT never stop payment on their own.

| Check | Grade | Told to the supplier |
| --- | --- | --- |
| No Tax ID on the invoice or on file, where withholding tax applies to the bill | Stops payment | Yes |
| The Tax ID on file not yet checked with the NRS, or found under another name, or not found | Stops payment while it lasts | No (the business checks it) |
| A business (company or business name) with no address on the invoice or on file | Stops payment | Yes |
| The same invoice number from the same supplier already in Counta, or the same file sent before | Stops payment | Yes |
| Not an invoice (a quotation, a receipt, a statement), or not readable | Stops payment | Yes |
| Line amounts, the subtotal or the total do not add up | To look at | Yes |
| VAT charged at a rate other than 7.5%, a VAT amount that is not 7.5% of the VATable value, VAT charged on goods the Nigeria Tax Act 2025 exempts or zero-rates | To look at | Yes |
| VAT charged with no Tax ID on the invoice | To look at | Yes |
| The invoice shows no address, though one is on file | To look at | Yes |
| No bank account on the invoice | To look at | Yes |
| The bank's name for the account differs from the supplier's, or the account differs from the one on file | To look at | No |
| The invoice is made out to someone else | To look at | Yes |
| No invoice number, no date, or a date in the future | To look at | Yes |
| The invoice is in a foreign currency | For information | No |

Where withholding tax does not apply, a missing Tax ID is something to look at, not a hold. A Tax ID already on file from earlier dealings with the supplier counts, so an invoice that leaves it off can still be paid; the supplier is asked to print it next time.

The draft bill uses Counta's own sums: VAT at the correct rate on what is VATable, withholding tax from the supplier's profile, and the account from the supplier's default or the business's expense account. The drawer shows the supplier's figures beside the bill's, so a corrected VAT is visible.

## The supplier

Counta looks for the supplier by Tax ID, then by bank account, then by name. A new one is added with what the invoice gives: name, Tax ID, address, state, email, phone and bank account. A new supplier's Tax ID is checked with the NRS (through Mono) while the invoice is read, so a clean invoice is ready to approve at once. An existing supplier's details are never overwritten; a clash is shown as a check.

## Telling the supplier

When an invoice has problems the supplier must fix, Counta sends one message listing them: to the email or WhatsApp number the supplier gave on the link (email first), otherwise to the supplier's email or phone on file. The message names the business and the invoice and says which problems stop payment. Messages go through the business's usual channels and count toward its plan. Rejecting an invoice sends the reason the business writes (the problems are filled in for it), unless the business unticks Send it to the supplier.

## Approving and rejecting

Approve for payment approves and posts the draft bill; the bill is then paid like any other, singly or in a bulk payment. A bill whose checks stop payment cannot be approved until the business adds what is missing to the supplier and presses Check again. Reject withdraws the draft bill (nothing is paid) and records who rejected it and why. Edit the bill opens the bill itself for any change before approval.

## Costs

Each invoice read is one AI read for the business's plan and is recorded in `usage_events` (service `gemini`, kind `supplier_invoice`) for the admin portal's cost of service page. The file is kept with the business's documents under `<org>/bills/`.
