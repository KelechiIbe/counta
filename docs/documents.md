# Documents

`/documents` (Documents in the sidebar) is where a business finds every file it keeps in Counta: customer invoices and
receipts, supplier invoices, input VAT claims, stock delivery notes, the tax return files Counta made, what TaxStreem Flux
sent back from Rev360 (filing evidence, acknowledgements, PRNs, payment receipts), what the accountant sent, company papers,
and anything uploaded straight in.

Nothing is copied into Documents. Each file stays with what it belongs to (a bill keeps its invoice, a delivery its proof),
and Documents lists them in one tree, as they are now.

## How the folders are laid out

Year, then month, then kind, then folder, then (for tax) the part of the return:

```
2026
  October
    Sales        Invoices · Receipts · Till receipts · Credit notes · Quotes · Orders · Delivery proofs
    Purchases    Supplier invoices · From suppliers · Claim input VAT · Stock received · Supplier credit notes · Import entries
    Tax          VAT · WHT · Withholding VAT
                   Return files · Accountant versions · Filing evidence · PRN and payment · Payment receipts · Uploaded · From Flux
    Accountant   Requests (files the accountant asked for, or sent)
  Full year
    Tax          CIT   Return files · Audited statements · Filing evidence · PRN and payment
    Accountant   Financial statements
No date
  Company        Registration · Company files (and the folders uploads were put in)
```

- A month holds what is dated in it: an invoice by its issue date, a bill by its date, a tax file by the month of the return.
- **Full year** holds what belongs to a whole year: the CIT return and its files, audited statements, the accountant's
  financial statements.
- **No date** holds company papers. The CAC records filed in onboarding (with the directors' details) show to the owner only.
  The NIN slip is never listed.
- **Till receipts** are one file a day: every walk-in sale of the day in one PDF, with a summary and what each receipt held.
  Receipts to named customers are listed one by one under Receipts.

The pills at the top (All, Sales, Purchases, Tax, Bank, Accountant, Company, Other) show only the kinds this person may see
and the business has files in. With a kind chosen, the kind column is left out.

## Who sees what

| Kind | Who |
| --- | --- |
| Sales | Whoever records sales, or keeps the books |
| Purchases | Whoever keeps the books, makes payments or receives stock |
| Tax | Whoever handles money (books, payments or margins) and files tax or keeps the books |
| Bank, Accountant | Whoever keeps the books |
| Company | The owner, and whoever manages settings (the CAC records: the owner only) |
| Other | Everyone on the team |

The same rules hold in storage: a file kept in Documents (`<business>/documents/<kind>/…`) can be read or added only by
those who see its kind, and tax files only by those who handle money.

## Looking, opening and downloading

- **Columns** (the default): each level in its own column, with the path above. Where the screen is narrow, the columns
  that fit show and the path leads back up. **Icons** shows one level at a time as folders and files.
- **Preview**: choosing a file shows it beside the list (images and PDFs), with its kind, tax, period, year, format, file
  name, who it is from, the amount and where it came from (made in Counta, sent by Flux, from the accountant, uploaded).
  **Hide preview** gives the list the whole width. On a phone the preview opens over the list.
- **Open** shows the file in a new tab. **Download** saves it under its own name.
- **Search** looks through names, customers and suppliers in every year at once.

Sales documents, till days and PRN slips have no stored file. Counta draws them as PDFs when they are opened, from what is
in the books, so they always match: an invoice as the customer's copy shows it (with the business's colour, logo, Tax ID,
VAT status and payment details), and a PRN slip with the PRN, the account, what the amount is made of and where the payment
stands. A voided invoice is stamped VOID.

## Zip

**Download zip** packs whatever is chosen: a folder, a kind in a month, a whole month, a year, a kind across every year
(choose its pill), or the results of a search. Inside, the zip is laid out as Documents is:

```
Kelandellen Company Limited documents/2026/10 October/Sales/Invoices/INV-0017 · First Bank of Nigeria Ltd.pdf
```

The zip is made in the browser from the person's own session, so it holds only what they may see. Up to 2,000 files go in
one zip; with more, choose a year or a month first. A file that could not be added is listed in a note inside the zip.

## Uploading

**Upload** takes PDFs, photos, spreadsheets and Word files, up to 25 MB each, several at a time. Choose the kind, the folder
and the month (the year of account for CIT; company papers keep no date). Files go to `<business>/documents/<kind>/` (tax
files to `<business>/tax/uploads/`). An upload can be taken out again by whoever uploaded it, or the owner; that deletes the
file. Files Counta made or Flux sent cannot be taken out.

## Files Flux sends back

Flux can attach files to each status it posts (the return's status, the CIT status, the payment and the payment's status).
Counta stores them under `<business>/tax/flux/<tax>/<month or year>/` and files them by kind: acknowledgements, assessments
and evidence under **Filing evidence**, the PRN page under **PRN and payment**, receipts and tax clearance under **Payment
receipts**, anything else under **From Flux**. See [flux-tax-returns.md](flux-tax-returns.md#6-files-flux-sends-back).

## For developers

- Migration `20261101000200_documents_bumpa.sql`: the `documents` table (uploads and Flux's files), `private.doc_rows`
  (every file a person may see, from the tables that keep them), `documents_tree`, `documents_files`, `documents_sales`,
  `documents_till`, `documents_prn`, `document_save`, `document_delete`, `svc_document_add`, and the storage rules.
- `src/pages/documents/Documents.tsx` (the page), `src/lib/documents.ts` (reads, uploads, the zip with fflate) and
  `src/lib/docPdf.ts` (the PDFs, with jsPDF; ₦ is written NGN because the built-in font covers Latin-1 only).
