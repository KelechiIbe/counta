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
- **Letters** (partners and managers): the practice's engagement letter templates and every letter, with its signing record.
- **Deadlines**: every client's returns and payments in one list.
- **Team**: the practice's people, their roles and their licence numbers.
- **Fees** (partners and managers): billing clients from the firm's own business, and the bills posted in full-mandate clients' books.
- **Earnings** (partners and managers): the Counta Partner programme.
- **Counta plans** (partners and managers): clients' plans the practice pays for, its card and payments. The route is still `billing`.
- **Practice**: the practice's details and the person's own licence number.

### Requests

The accountant asks the business for a document, an answer or an approval. The owner is told at once and answers in Settings, Your accountant, with words, a file or both. Files go to the business's documents (`<org>/requests/<request>/…`).

While a request waits for an answer, the owners and admins see it in four places: a count beside Settings in the menu, a row on Home among the things to review, the bell's count, and a note at the top of Settings that leads to the request. The count is `accountant_requests` in `get_attention`. It counts open requests from accountants still working on the books, and it does not count for the accountant's own people in the business. It goes as soon as the request is answered.

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

## Two ways to work for a client

A firm takes each client on in one of two modes (`practice_clients.mode`):

- **Involved** (`involved`): the owner runs the business on Counta and invites the firm, or accepts its invitation, as described above. The firm's people get Accountant's places and never move money.
- **Full mandate** (`full`): the firm runs the business for its owner, who is not involved at all. The firm sets the business up itself, its partners and managers act as the owner, and the client only sees what comes out of it (its invoices, receipts, returns and statements, sent in the firm's name).

Both start the same way, with due diligence on the prospect and an engagement letter. Only a firm with a partner whose licence TaxStreem verified, and that TaxStreem has not paused, may run full mandates (`private.practice_can_full`).

## Taking a client on: due diligence and the conflicts check

Clients, Add a client opens a step-by-step intake (`practice_intakes`, partners and managers):

1. **The business**: its legal name, kind of entity, RC or BN number, Tax ID, address and industry, and which mode the firm wants. **Find the business on CAC** fills these from the CAC record (the `mono` function's `intake_cac_search` and `intake_cac_select`, within the person's daily lookups): the registered name, kind, number with its registry, the Tax ID the NRS holds for it, the address and industry, and in step 2 its directors, shareholders of a quarter or more as beneficial owners, and the people with significant control. The partner checks them and saves; the record is kept with the intake (`practice_intakes.cac`), and when the firm sets the business up under full mandate it becomes the business's profile draft, so nobody looks the company up again.
2. **Its people**: directors, beneficial owners (with their share) and related parties, each with a nationality, whether they are a politically exposed person, and the type of ID seen. Only the last four characters of an ID number are ever kept; a full NIN, BVN or other number typed anywhere is refused. **Check a person's NIN** looks it up with NIMC (`intake_nin`) and keeps the name NIMC holds and the last four digits (`practice_intake_nin_checks`); a person of that name on the intake is marked as checked by NIN.
3. **Documents**: the CAC record, IDs, proof of address and others, kept with their SHA-256 (`practice_intake_docs`).
4. **Risk**: low, medium or high, with the reason. A politically exposed person among the people makes it high.
5. **Conflicts check** (`practice_conflict_run`): Counta compares the business, its numbers and its people with the firm's current and former clients, its other intakes and the people on them, and the opposing parties it recorded for its clients (and, when the practice switches it on, the names in its clients' books). Anything found must be cleared or refused by a partner with a note before the client can be taken on. A check counts only if it ran after the intake's last change.

An intake that is risk-rated and cleared is ready. The letter comes next. For a client the firm already has, the client's page records its **opposing parties**: the other side of a dispute, a deal or a tax matter, so that later checks find them.

A company is on Counta once (see [Recovering a business](recovering-a-business.md)). A full mandate is refused when the company (by RC number or Tax ID) is already on Counta under someone else: the business already has an owner who signs in, or another practice runs it. TaxStreem is told (a `duplicate_company` flag) and decides what happens. The firm's own second business for the same company is refused too. An owner who tries to set up a company a practice already runs is told it is on Counta already, with the firm's address masked, and may recover it as a director; nothing is set up, and the firm gets the same flag (marked as coming from an owner). RC and BN numbers with the same digits are different businesses; a number with no prefix takes its registry from the business's legal form.

A prospect a partner refused after the conflicts check stays refused. It cannot come back as a client through the firm's referral link or a link the business starts: Counta matches it on the business itself, its RC number or its Tax ID.

**Ongoing due diligence.** Once a business is the firm's client, its intake stays open for partners and managers to keep up to date (a new director, a change of address, a fresh risk rating). The way the firm works with it does not change there, and the partner's declaration of authority stays. Each change keeps the intake as it stood before in its history (`practice_intake_history`), shown on the intake as earlier versions. A new name, number or person needs the conflicts check again, and the client is marked "due diligence incomplete" until it is clear.

Intakes are kept for as long as the engagement's records are (`retain_until`): the longest of five years after the work ends and the years its letters promise (six by default). From then on an intake is kept exactly as it was.

## Engagement letters

Every practice starts with Counta's default letter: a full engagement letter for Nigerian accountants with variants for an involved client and a full mandate. Partners and managers keep their own templates under Letters:

- **Edit the default** or make a new one from it. A letter is a list of blocks (headings, numbered clauses, list items, paragraphs, signature blocks), numbered for you as the PDF will be, so moving a clause never leaves a gap. A block can be for one variant only, or only while a field (such as an expenses deposit) is filled in. Fields go in double braces: `{{client.name}}`.
- **Import the firm's own letter from Word** (.docx). The paragraphs become blocks: headings, clauses and list items from Word's styles and numbering. It is read in the browser, and a file that unpacks too large is refused.
- **Upload a PDF** when the firm's letter must stay exactly as it is.

For one client the firm drafts a letter from a template (`practice_letter_draft`), fills in the fields (fees, dates, the services, the addressee), and changes the clauses if it needs to. Then:

1. **A partner signs it for the firm** (the `practice` function's `letter_freeze`): the PDF is made, stored write-once with its SHA-256, and the letter is frozen. The letter's fingerprint is taken when it is prepared for signing; if anyone changes the draft (or the firm's details printed on it) before the signature is recorded, the signature is refused and the partner signs again.
2. **It goes to the client's signer** (`practice_letter_send`). The email carries a one-time link to `/sign`, good for 14 days. The signer reads the letter, types or draws a signature, and enters a 6-digit code sent to the same email (good for 10 minutes; five wrong tries lock the link until the firm sends it again).
3. **Signing** (`sign_submit`): the stored letter is read again and refused if its SHA-256 no longer matches the one the firm signed (recorded on the letter as `document_changed`, and the firm's leads are told). Otherwise a signature page and a completion certificate (both sides' names, times, addresses, browsers and the letter's fingerprint) are added and the result is stored write-once.
4. **Or a signed copy is uploaded** when the client signed on paper (`practice_letter_upload_signed`), with its SHA-256.

Every step is in the letter's record (`engagement_letter_events`): drafted, signed by the firm, sent, opened, codes sent and failed, signed, uploaded, voided. A letter can be voided with a reason until it is signed. Letters are kept for the number of years they say (six by default, never fewer than five). A letter to a full-mandate client carries no Counta name, on the page or in the email.

## Full mandate

### The gate

A business is set up under full mandate (`practice_create_business`) only when every condition holds (`practice_mandate_gate`):

- the partner doing it has a verified licence, and TaxStreem lets the firm run full mandates;
- the intake is risk-rated, has an RC or BN number or a Tax ID, and its conflicts check is clear;
- a full-mandate engagement letter for the intake, as it now stands, is signed by both sides (or a signed copy is uploaded);
- a partner has declared, in their own name, that the client gave the firm written authority to act for it.

The business is then made with no owner and its identity check pending, billed to the practice, and with an engagement partner (the partner who set it up, unless another is chosen). Each active partner and manager gets an admin place that **acts as the owner** (`members.acts_as_owner`): they can do everything an owner can, from raising invoices and reconciling payments to managing stock, the team and the settings. Staff get ordinary Accountant's places when they are assigned.

### Silence and branding

Counta says nothing to the client of a full-mandate business (`private.outbound_check`):

- Alerts, invitations and practice emails go only to the firm's own addresses: the mandate's alert address when it has one, else the business's contact (the engagement partner). Anything else is not sent, and the activity log says so (`message_suppressed`).
- No Counta calls.
- The business may send its documents to its customers, or be set to **download only**, when nothing is sent at all.
- Documents, emails, the invoice portal and the signing page carry the firm's name and no Counta branding (`private.white_label`).

The business app shows a banner on every screen saying the person is acting for the owner.

### Money: the business's identity and a director's confirmation

The business wallet and the tax wallet (Flutterwave, through TaxStreem) open only when all of these hold (`private.payments_open`):

1. The business's identity is verified. Its own business profile holds its CAC record. The director's confirmation below verifies it; a partner or manager can also check a director's NIN in Settings, Business identity.
2. **A director of the company confirms the wallets.** A partner or manager picks a director from the CAC record (Full mandate tab, Ask a director) and sends the link to the director's own email, or, with no email, gets the link to send another way (`practice_director_link` makes a new one; 14 days). Whoever opens it (`/confirm`) reads which firm asks and that TaxStreem provides the wallets through Flutterwave, then proves they are that director:
   - Their **NIN** is looked up with NIMC (the `practice` function's `director_nin`, three a day) and must match a director (or, for a business name, a proprietor) on the CAC record, by name. Only the name it matched and the NIN's last four digits are kept.
   - A **6-digit code** goes to the phone number NIMC holds for the NIN (by SMS through Termii) and to the director's email on the CAC record, never to one of the firm's addresses (`identity_checks`, `svc_identity_mail`). The code confirms. Where the code went is wiped once it is right, or within the hour.
   - With **no phone on the NIN record** (or SMS not set up), the code goes to the director's email and phone on the CAC record, and once it is entered TaxStreem checks the confirmation (`director_review`, reason `no_nin_phone` or `sms_not_ready`).
   - With **no way to send a code** at all, the director uploads their NIN slip (`director_slip`) and TaxStreem checks it (reason `no_channel`).
   A decline tells TaxStreem (`director_declined`).
3. TaxStreem has not paused the firm's full mandates (`practices.mandate_suspended_at`).

### What the firm sees

The client's page has a **Full mandate** tab for partners and managers: where the mandate stands (payments, the director's confirmation, the engagement letter), the director's confirmation, how the business sends its documents and where its alerts go, the engagement partner, the handover, the export and the end. Its **activity log** (`activity_log`) records every change made in the business, by whom and when: each write to its tables, and events such as the director's confirmation, fee bills and the handover. People's details from the CAC record are kept out of it.

### Handing the business over

A partner hands the business to the person who will own it (`practice_handover_start`): their name and their own email address, never one of the firm's people or an address on the firm's domain. The email's link (`/practice/join?t=ph_…`, 14 days) opens a page where that person, signed in with that address, takes the business over (`practice_handover_accept`). They become its owner, Counta's silence and the white label lift, and the firm stays on with ordinary Accountant's places. The owner sees everything the firm did in Settings, Your accountant.

If the new owner is not the director who confirmed the wallets, TaxStreem checks the handover before payments open again: the business's identity goes into review with the reason `handover` and a `handover` flag is raised, recording whether the accepting address is one the firm's people use. Approved, payments open (or, for a business never verified before, the new owner does the ordinary NIN check); rejected, they stay shut until TaxStreem decides again.

### Ending without a handover

A partner can end a full mandate with a reason (the `practice` function's `end_mandate`), once both wallets are empty and no payment is moving. The business's connections pause, its bank feeds are unlinked at Mono (with **Unlink them again** if Mono did not answer), its plan stops at the end of its period, its recurring invoices pause, and only the engagement partner keeps a place. The business becomes **read-only** and its records are kept until the date the letter sets, at least five years (`orgs.read_only_at`, `orgs.retain_until`). Nothing can be written or deleted in it meanwhile, and it cannot be deleted in the admin portal.

A partner can **export** the business's records at any time while the firm runs it or keeps it (the `practice` function's `export`): every table, the ledger and the activity log in one ZIP, with private details left out, through a link that works for 10 minutes.

### TaxStreem's side

The admin portal's **Mandates** page (admins and reviewers) holds the director confirmations to check (whom the NIN matched, its last four digits, where the code went, masked, and the NIN slip), the open flags (a company already on Counta, a director who declined, a handover to someone else) and the practices that run or may run full mandates. Every decision takes a note. Admins can pause a practice's full mandates, which shuts the payments of every business it runs that way until resumed, and set the free-mail domains that never count as a firm's own address. Handovers waiting for TaxStreem are decided in **Identity reviews**.

## Fees

A firm bills its clients from its own Counta business, the **firm business** (`practices.firm_org_id`): an ordinary business with its own identity check, business wallet and tax wallet. A partner creates one on the Fees page, or links a business they really own. A business created there starts with its identity pending, so its payments open only once a director's identity is verified.

Each client gets a customer in the firm business (`practice_clients.fee_customer_id`): a business customer with the client's name and TIN. Fee invoices are ordinary invoices of the firm business, by hand or on a schedule (Recurring invoices). Those to a full-mandate client carry no Counta branding.

For a full-mandate client, each fee invoice is also posted as an approved bill in the client's own books (the fee mirror): the practice as the vendor, professional fees (6502) and the invoice's VAT to the kobo, entered in the name of the client's contact. The Fees page shows each such bill: posted, not posted (with why, and **Try again**), dismissed by a partner with a reason, voided with its invoice, or skipped because the engagement had ended. A credit note on a fee invoice waits on the Fees page (the leads are told) until a partner or manager confirms it: it then goes into the client's books as the firm's credit note against the bill, credited invoice line by bill line, which takes it off what the bill still owes. A partner can leave one out with a reason, for example when the client's accountant entered it by hand; the bill is then flagged as credited on the invoice only. A credit note that the books refuse (a closed period) keeps waiting with the reason. Partners also see the firm business's wallet balances there.

## Paying for clients' plans

A partner or manager can pay for a client's Counta plan with the practice's card (Counta plans, or the client's *Team and billing* tab). The first payment goes through Flutterwave's page and comes back to the portal; the card is kept for the practice (never shown to the business) and used for renewals. The business sees that the practice pays, and can take it back by choosing a plan in Settings, Subscription. When the practice stops paying, or the work ends, the plan runs to the end of the period the practice paid for.

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
| `practice_intakes`, `practice_intake_people`, `practice_intake_docs` | Due diligence on a prospect |
| `practice_intake_history` | A client's intake as it stood before each change |
| `practice_conflict_hits`, `practice_opposing_parties` | What the conflicts check found, and the other side of clients' matters |
| `practice_letter_templates`, `engagement_letters`, `engagement_letter_signers`, `engagement_letter_events` | Templates, letters, their signers and their record |
| `practice_director_confirmations` | A director's confirmation of the wallets |
| `identity_checks` | A NIN matched to the CAC record and the code sent for it (a confirmation or a recovery) |
| `practice_cac_lookups`, `practice_intake_nin_checks` | CAC searches from the intake, and NINs checked from it |
| `practice_handovers` | Handovers to the owner |
| `practice_mandate_flags` | What TaxStreem is told to look at |
| `activity_log` | What was done in a business a practice runs, or keeps read-only |
| `practice_fee_bills` | Fee invoices posted as bills in full-mandate clients' books |
| `practice_fee_credits` | Credit notes on those invoices, waiting, confirmed into the books or left out |
| `recurring_invoices`, `recurring_invoice_runs` | Invoices on a schedule (any business) |

Nobody reads these tables directly; the functions check who may do what. The practice management migrations are `20261124000100` to `20261124001300`.

## Checking it

On a local Postgres 16 (the harness in `supabase/tests`):

```
bash supabase/tests/run_tests.sh              # every scenario, ends "ALL PASS"
bash supabase/tests/run_tests.sh 99_full      # the full mandate from intake to handover
bash supabase/tests/golden/run.sh check       # the owner functions answer as before
bash supabase/tests/golden/run.sh sweep
deno test --node-modules-dir=none --allow-read supabase/functions/practice/ supabase/functions/_shared/letter_test.ts supabase/functions/messaging/
```
