# The accountant portal

Accountants look after many businesses on Counta from one place: `/practice`. A practice is a firm, or a sole practitioner set up as a firm of one. It has its own people, and businesses connect to it by invitation, from either side.

## Who is who

| Role in the practice | Sees | Does |
| --- | --- | --- |
| Partner | Every client | Everything below, changes the practice's details, adds partners |
| Manager | Every client | Invites businesses and staff, assigns staff, pays for clients' plans, ends work with a client |
| Staff | The clients a partner or manager assigns | Works on those clients |

Once a business is connected, each partner and manager (and each staff member assigned to it) gets an **Accountant's place in the business**: a normal member row with the Accountant role, marked with the practice (`members.practice_id`). The business's own role settings decide what that place may do, so the owner stays in control. By default the Accountant role keeps the books, approves adjustments, sees margins and files tax returns. It never makes payments. Ending the work, taking staff off a client or switching a person off in the practice switches their places off at once.

## Connecting a business

Either side starts it:

- **The practice invites the owner.** Clients, Invite a business: the owner's email, the services and who pays for Counta. The owner opens the email's link, signs in (or signs up) and chooses which of their businesses to connect. Only an owner connects a business; the sample business cannot be connected.
- **The business invites its accountant.** Settings, Your accountant: the accountant's email. The accountant opens the link (signed in with that email), or finds the invitation in the portal, and takes the business on into their practice. An accountant without a practice sets one up first, and the invitation waits for them.

Invitation emails come from the inviting side through the `messaging` function (`action: practice_email`). The link is made as the email goes out: sending again makes a new link and the old one stops working. Links work once, for fourteen days. The join page (`/practice/join?t=…`) says what the invitation is before anyone signs in.

Either side can end the work at any time. The practice's notes stay with the practice; the business never sees them.

## The portal

- **Clients**: every client with what needs doing, the most urgent first: tax deadlines passed or due within 14 days, changed files waiting to be booked, answers from the client, questions in the books, bank lines to match, an unpaid Counta plan.
- **A client**: its deadlines and books, the returns and statements, requests to the business, the practice's own notes, and who works on it. *Open the books* switches Counta to the business through the accountant's own place in it.
- **Deadlines**: every client's returns and payments in one list.
- **Team**: the practice's people, their roles and their licence numbers.
- **Billing**: clients' plans the practice pays for, its card and payments.
- **Practice**: the practice's details and the person's own licence number.

### Requests

The accountant asks the business for a document, an answer or an approval. The owner is told at once and answers in Settings, Your accountant, with words, a file or both. Files go to the business's documents (`<org>/requests/<request>/…`).

### Licence numbers

Each accountant may give an ICAN, ANAN or CITN membership number. TaxStreem checks it in the admin portal (Accountants) against the professional body's register and verifies it, or says why not. Until then clients see it as unverified. The number, as checked, goes into the statement the accountant accepts when they change a return.

## Changed returns and statements

An accountant can download a return or the financial statements, change them in Excel and upload them again. Counta then uses the accountant's version, with a note that the accountant changed it and takes responsibility.

1. **Download.** The client's *Returns and statements* tab gives Counta's own file: the VAT return (NRS Form VAT 002), a WHT schedule (NRS or a state), the CIT return (Rev360 template) or the financial statements (Excel).
2. **Change and upload.** The accountant changes figures in that file, keeping its layout, and uploads it with a note. Counta reads the figures that matter from the known cells:
   - VAT: the form's sixteen lines (column U on *VAT RETURNS FORM*).
   - WHT: the schedule's rows, the total of the payments and the total WHT.
   - CIT: revenue to profit after tax, the totals added back and deducted, and the statement of financial position's totals.
   - Statements: every line of *Profit or loss and OCI* and *Financial position*.
   It compares them with Counta's own figures (or with the version already in use) and lists every change. A formula the file holds no result for is worked out. The file is kept exactly as uploaded, with its SHA-256.
3. **Book the differences.** Counta suggests the journal that brings the books to the accountant's figures, and the accountant changes it as they need:
   - VAT: the change in net VAT (line 115) against Output VAT Payable.
   - WHT: the change in WHT against WHT Payable.
   - CIT: the change in the tax charge, Current Income Tax Payable against Income Tax Expense.
   - Statements: each changed line to the account of that line used most in the period; a change in retained earnings that profit does not explain to 3005.
   The journal must balance. Lines on customer and supplier control accounts are refused: those go through Sales or Bills. Counta shows what the file still shows that the journal does not book. When the changes need no entry (they only move figures between lines), the accountant says why instead.
4. **Accept responsibility.** The accountant ticks that they take professional responsibility, in their own name and with their licence. The journal posts (dated the last day the return covers) and the statement is kept with the version.

From then on:

- The VAT, WHT and CIT downloads give the accountant's file, and the Tax pages show who changed it and that they take responsibility. *Original* downloads still give Counta's own file.
- Flux receives the accountant's file and a `prepared_by_accountant` block with the name, licence, practice and statement.
- What Counta expects to pay for VAT and WHT follows the accountant's version: the books' figure moved by the change in tax payable the file shows.
- The Statements page offers the accountant's file beside Counta's own.

Only someone with the Accountant role uploads and accepts. The owner, or an accountant, can withdraw a version: its journal is reversed and Counta's own file is used again. Once a return has gone to Flux or been filed, a changed version can no longer replace it, and the version filed cannot be withdrawn.

## Paying for clients' plans

A partner or manager can pay for a client's Counta plan with the practice's card (Billing, or the client's *Team and billing* tab). The first payment goes through Flutterwave's page and comes back to the portal; the card is kept for the practice (never shown to the business) and used for renewals. The business sees that the practice pays, and can take it back by choosing a plan in Settings, Subscription. When the practice stops paying, or the work ends, the plan runs to the end of the period the practice paid for.

## Database

| Table | What it holds |
| --- | --- |
| `practices` | The practice |
| `practice_members` | Its people, roles and licence numbers |
| `practice_clients` | Invitations either way and connections (invited, requested, active, ended, declined) |
| `practice_assignments` | Staff on a client |
| `practice_requests` | Requests to a business and the answers |
| `practice_notes` | The practice's notes on a client |
| `filing_versions` | Changed returns and statements, their figures, the journal and the statement |

Nobody reads these tables directly; the functions in `20261031000300_practices.sql` check who may do what.
