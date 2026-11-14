# The firm's letterhead and VAT turned on by itself

Release 3 of the identity and compliance work (`20261127000100_letterhead_and_vat_switch.sql`). A practice's engagement letters can be printed on its own letterhead, and a business that must charge VAT has it turned on the morning after it crosses the line.

## The letterhead

A partner sets it under Practice, Letterhead. Managers see it and can look at a sample letter on it. There are three choices.

**Plain** is how letters looked before: the firm's name heads the first page, set in Helvetica on A4.

**Our own letterhead.** The firm uploads its blank letterhead page as it saves it from Word: a PDF, or a PNG or JPG of the whole page. A PDF is kept as it is (5 MB at most, one upright A4 or US Letter page). A picture is redrawn in the browser as a JPG no wider than 2,480 pixels, and it must be at least 1,000 pixels wide and have the shape of a whole A4 or Letter page, so that a cropped header is refused before it is uploaded. The page is laid under every page of the letter. The following pages can carry the same page, a second page the firm uploads (often a lighter one), or nothing. The partner sets how much space to keep clear at the top and bottom of the first page and of the following pages, and at the sides, with sliders in millimetres, and the card shows each page with the letter's text area marked on it. The page number sits just below the text area. The headings take the colour the partner picks, and the letter is set in Helvetica or Times.

**Build one here.** The firm's logo (a PNG or JPG, redrawn as a PNG no larger than 1,000 pixels), its name in its colour, and under it the details it chooses from what The practice card holds: address, phone, email, registration number, and a website typed here. The logo sits on the left with the details on the right, or everything is centred. A footer of up to two lines (the partners' names, the regulator) goes at the foot of every page. The following pages carry the name in small type over a rule.

Files go to `practice/<practice>/letterhead/` in the documents bucket under a new name each time, so a file already printed on a signed letter is never overwritten. `practice_set_letterhead` checks every setting through `private.letterhead_norm`: the mode, the colour, the typeface, the margins (within limits that leave a text area at least 300 points tall and wide), the footer, and for each file its path, its SHA-256, its kind and its size, and that it is in storage with the size and type it claims (`private.letterhead_file`). It records who changed it and when.

### Which letters carry it

The letterhead in force when a partner signs a letter for the firm is printed on it and kept on the letter (`engagement_letters.letterhead`). It is part of the letter's fingerprint, so a letterhead changed between preparing a letter and signing it makes the partner sign again. Letters already signed keep the PDF they were signed as, and a letter the firm uploaded as a finished PDF is never printed on the letterhead.

When the `practice` function prints a letter (`letter_freeze`), it reads each letterhead file from storage and checks it again before using it (`letterhead.ts`): the SHA-256 must match what was saved, a PDF must open and have the size that was saved, a picture must be the kind and size that was saved, and a PNG must inflate to no more than its pixels would need. A file that fails stops the signature with a message that names the file and tells a partner to upload it again.

### Seeing a letter before it is signed

**Preview as PDF** on a draft letter, on a template, and **See a sample letter** on the letterhead card ask the `practice` function's `letter_preview` action for the letter as the PDF it will be. Every page is marked PREVIEW, the signature lines are left empty, and nothing is stored. A draft is previewed with its unsaved changes. A partner previewing the letterhead card sees the letterhead as it stands on the card, before it is saved; a manager sees the saved one. `practice_letter_preview` decides what may be shown: partners and managers of the practice, a letter of their own practice only, and a letter that is still a draft from a template.

## VAT turned on by itself

Every morning around 7am `private.vat_threshold_tick` looks at each business that does not charge VAT (sample businesses and businesses kept read-only are left alone). When the business must charge it, its VAT is turned on and the reason is recorded. A business must charge VAT when its sales this financial year pass ₦100 million, or when it is not a small company: turnover in the last full year above ₦100 million, fixed assets above ₦250 million, or professional services (`private.vat_must_reason`).

The owner, everyone who keeps the books and the business's accountant are told by push, email and WhatsApp (`alert_send`, kind `vat_on`), once, with the figures that decided it, what changes (VAT at 7.5% on invoices and receipts where it applies, a return every month by the 21st) and a link to the VAT tab (/tax/vat).

Each change, by Counta or by the owner, goes into `vat_changes` with the figures behind it. The VAT tab shows the last one (`vat_status.last_change`). While a business must charge VAT and does not, the tab says Counta turns it on at its next morning check (`vat_status.auto_on`), and the owner can turn it on sooner.

A draft invoice keeps whether VAT was on when it was saved (`sales.vat_registered`). One saved before VAT was turned on or off cannot be issued until it is saved again, so that its VAT is right (`private.issue_invoice_as`). The invoice says so, and its Issue button waits.

## Checking it

```
bash supabase/tests/run_tests.sh 16_letterhead      # the letterhead, the preview, the VAT switch
bash supabase/tests/golden/run.sh check
deno test --node-modules-dir=none --allow-all supabase/functions/practice/
```
