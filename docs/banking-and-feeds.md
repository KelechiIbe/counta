# Bank statements, bank feeds and matching

Accounting, Banking brings a business's bank transactions into the books two ways: a statement file uploaded by hand, or a bank feed through Mono Connect. Both go through the same checks and the same matching, so a line is never counted twice and the feed and a statement of the same days agree.

## Statements from any Nigerian bank

The upload takes PDF, Excel (.xlsx, .xls, including the HTML files some banks save as .xls) and CSV. The file is read in the browser, so a statement's password never leaves the person's device.

What the reader does:

- Finds the column headings, whatever the bank calls them: Trans Date, Posted Date, Date Posted, TransDate, Date/Time or Value Date; Narration, Description, Details, Transaction Detail, Remarks or Particulars; Reference, Ref No or Cheque No; Debit, Debits, Withdrawals or Money Out; Credit, Credits, Deposits, Lodgements or Money In; Balance or Balance After; or one Amount column with a sign (OPay's signed Debit/Credit column), a DR/CR suffix or a separate Dr/Cr column. Channel and category columns are left out of the narration.
- Tested on statements laid out as Zenith, First Bank, UBA, Kuda, OPay, Moniepoint, Fidelity, Ecobank, PalmPay, Wema (ALAT), GTBank, Access and Stanbic IBTC print them, as PDF and as Excel exports (`stmt/banks.mjs` in the test harness).
- Reads dates day first (01/10/2026 is 1 October), with or without a time, in any of the forms banks print (01-Oct-2026, 1 Oct 26, 2026-10-01).
- Joins narrations that run onto a second or third printed line, and leaves page footers out.
- Puts statements printed newest first into date order.
- Works out the direction of an unsigned amount from the running balance.
- Reads the account number, account name, period and opening and closing balances from the top of the statement (or an Opening Balance and Closing Balance row in the table).
- Checks every balance against the one before and the whole statement against its opening and closing figures. Lines that do not follow are marked on the review screen.
- Marks dates to check: after today, well outside the statement's period, or far from the lines either side. A line dated after today stops the upload, because the statement was misread.

A PDF with a password asks for it. A scanned PDF (pictures of pages, no text) goes to the AI reader (`ai` function, action `read_statement`); a PDF whose layout the column reader cannot follow can be sent to the AI reader from the review screen. The pages go two at a time, three parts at once, each tried a second time if it fails, and scans are sent about 2,000 pixels wide so small print stays legible. The parts are joined in date order, and the AI's answer passes the same checks, with two corrections the running balance makes certain: a line read as money in that the balances show went out (or the other way) is turned round and marked, a page's first or last balance given as the statement's opening or closing balance is not used, and a year misread on a scan (2027 among 2026 lines) takes the year of the lines around it. Remarks a part makes about pages it was not shown are left out.

If the account number on the statement does not end in the same four digits as the account chosen in Counta, the upload waits until the person ticks that it is the right account (`import_bank_lines` refuses it otherwise).

`import_bank_lines(org, bank_account, lines, meta)` records the file on `bank_imports`: source (pdf, excel, csv), how it was read (columns or ai), bank, account number, period, opening and closing balance, and whether the balances agree. The closing balance becomes the account's latest bank balance.

## Bank feeds through Mono

Connect a bank on the Banking page opens Mono's window. The person signs in to their bank there; Counta receives a code, exchanges it for the account (`mono` function, action `link`) and fetches the history: from the start of the books or 90 days back, whichever is later, and never more than a year. Counta can read transactions and the balance. It cannot move money.

After that:

- Every four hours the database schedule (`counta-bank-feeds`, `private.feeds_tick`) asks the `mono` function to fetch new transactions for every linked account, from three days before the last line seen.
- Sync on the account's card fetches at once and asks Mono for fresh data from the bank (`x-realtime`). When the bank has more to send, Mono's webhook brings it when it is ready.
- When the bank asks for the login again (a one-time code, a changed password), the account shows Feed paused with a Sign in again button, which reopens Mono's window for that account. The bookkeeper is notified once.
- Unlink stops the feed at Mono and in Counta. Lines already in stay, and statements can be uploaded again.

A feed line that a statement already brought in (same account, amount and day, the same balance or a similar narration) is merged: the statement line takes the feed's id instead of coming in twice. The same check stops a statement from adding what the feed brought.

### Setting it up

1. In the Mono dashboard, create an app for Connect (financial data) and copy its public and secret keys.
2. In Supabase, Edge Functions, Secrets, add `MONO_SECRET_KEY` and `MONO_PUBLIC_KEY`.
3. In the Mono dashboard, set the webhook URL to `https://<project>.supabase.co/functions/v1/mono/webhook` and choose a webhook secret. Add the same value in Supabase as `MONO_WEBHOOK_SECRET`.
4. Deploy the `mono` function with JWT verification off (it checks the person's own token, the webhook secret or the schedule's hook secret itself).

The Connect a bank window shows the webhook URL and says which of these is missing.

## Matching

Each new line, from a statement or a feed, runs through the matcher in this order:

1. Already in the books on that account within three days (a payment recorded at the till or against a bill).
2. Money in: a transfer waiting for confirmation is confirmed.
3. Money in: the narration names an open invoice or order (INV-0042, inv 42, Invoice no. 42), whoever paid it. Short by 2%, 5% or 10% of the net amount, the difference is the customer's WHT credit. Paid over, the extra is held as the customer's credit and flagged.
4. Money out: tax and levy payments go to their tax account. A bill named in the narration is paid, with WHT if the amount is net of it: by Counta's number, or by the supplier's own invoice number (with or without its punctuation, standing on its own in the narration) when the amount is what is owed or the supplier is named too.
5. A customer or supplier named in the narration.
6. Transfers between the business's own accounts.
7. Rules learned from earlier answers, then known payees (bank charges, power, telecoms).
8. Nobody named, but exactly one open invoice (or bill) is for that amount, as it stands or less WHT: the line is held in suspense and the books inbox asks "Is this ₦25,216.04 from Mama Nkechi Stores for INV-0016?". Yes settles the invoice in one tap; No, it was something else opens the usual answer.
9. What is left goes to Atlas.

VAT and WHT treatment beyond this follows the rule book when TaxStreem shares it.
