# Personal income tax on LIRS e-Tax: Counta's own filing bot

Counta files personal income tax on LIRS e-Tax itself, without TaxStreem Flux. A small bot signs in to e-Tax as each
taxpayer (the proprietor, or each partner) with that person's own e-Tax login, files the approved return, raises the pay
bill, fetches the bank-transfer account for the bill when someone chooses to pay, and watches the bill until the payment
shows. TaxStreem's terms are that a return is filed with the taxpayer's login and as the taxpayer, so the bot never uses the
e-Tax consultant module.

The e-Tax side below comes from filing a real nil return and paying a NGN 500 bill on 4 November 2026, with the taxpayer's
consent, and from e-Tax's own screen code. Ids, names and account numbers from that run are left out of this document.

## 1. What e-Tax is underneath

e-Tax is a Vue single-page app on `https://etax.lirs.net` that talks to its own JSON API at `/api/v1/`. Every call is a
`POST` whose body names the real method:

```
reads    {"method":"GET","params":"filters=[...]&embeds=[...]&order_by=year&is_asc=false&page_size=20&page=1"}
writes   {"method":"POST"|"PUT","body":{...}}
uploads  multipart/form-data, no wrapper
```

The app sets `Accept`, `Content-Type` and `X-Requested-With`; there is no Authorization header, the session is a cookie.
`params` are sent as the app sends them, not URL-encoded (encoding them made the server answer `INTERNAL_ERROR`). Errors come
back as HTTP 200 with `{"status":"error","code":"NO_AUTH"|"INVALID_INPUT"|"INTERNAL_ERROR","message":...,"error":true}`;
uploads wrap theirs in `body`. A list answers `{"pagination":{...},"list":[...]}`. Removing something is `PUT {status_id: 3}`.

Signing in. The taxpayer login page (`/login`) asks `GET /api/v1/get_csrf` for a token as it opens, then posts
`auth/local/payers/authenticate {method: "POST", body: {identifier: <Payer ID>, password}}` with the token in
`x-csrf-token`. The answer is the user (`id` is the taxpayer id, `entity_id` the individual), and `auth_data` with the
permissions. When the permissions include `auth.updatepassword`, or `extra_details.force_password_reset` is set, e-Tax wants
a new password before anything else. The password box trims spaces. There is no CAPTCHA and no one-time code on the
taxpayer side; registration has a reCAPTCHA and an emailed code, so a person without an e-Tax account registers once
themselves. Signing out is `auth/logout`.

Three things about the session shape the bot:

- A session lasts 10 minutes without activity (the app sends `touch` every 4 minutes). The bot's calls keep it alive.
- One session per account: signing in somewhere else ends the first session (every call then answers `NO_AUTH`). Counta
  tells the person that the bot signs them out of e-Tax if they are signed in while it works; the bot signs in again once
  and picks up where it was.
- A call the taxpayer's role may not make ends the session. The bot makes only the calls the taxpayer's own screens make.

The bot fills the login page in a real browser (Playwright), then moves to a plain file on e-Tax's own address and makes the
API calls from there, so they go out from e-Tax's origin with its cookie and nothing in the app moves under them.

## 2. Filing a return

All writes are made as the signed-in taxpayer, in the order of the screens. Each step first reads what e-Tax already has,
so a job that stopped part way picks up where it was and never adds anything twice.

| Step | Call | Body |
|---|---|---|
| Find the return | `tax/returns` GET | filters `tax_payer_id`, `year`; embeds individual, accommodations, returnDocuments.document, status |
| Documents | `tax/returns/documents` multipart | `type_code=statement_account`, `year`, `tax_payer_id`, `file` (PDF only), `label`. Creates the return when there is none. Counta attaches the statement of accounts and the person's computation. |
| Statement of income | `tax/returns/individual/extract` POST | `{data: {salary, commission, trade_income, allowance, pension, annuity, gratuities, foreign_income, dividend, interest, rent, others}, tax_payer_id, year, breakdowns: [{name, amount}]}`, the figures as text with two decimals (`"45260000.00"`), 0 for none; `others` is the sum of `breakdowns` |
| Accommodation | `accommodations` POST, or `accommodations/<id>` PUT | `{individual_id, accommodation_user_type_id, started_at, ended_at, address, rent_paid, rent_paid_by_employer, owner_tax_payer_number, owner_name, owner_address, accommodation_type, return_id}` |
| Household staff | `tax/payers/<tax_payer_id>/relations` POST | unregistered: `{type_id, data: {fullName, address, incomePaid}}` |
| | `tax/payers/<tax_payer_id>/relations/links` POST | registered: `{type_id, relation_tax_payer_number, incomePaid}` |
| Assets | `tax/returns/<return id>/assets` POST | `{type_id, data: {...}}` |
| Relief files | `documents` multipart | `type_code=taxpayer.doc`, `entity_type_id=9`, `entity_id=<tax_payer_id>`, `name=Relief`, `file` (PDF or picture) → `{id, url}` |
| Reliefs | `tax/returns/<return id>/relief` POST, or `tax/returns/relief/<id>` PUT | `{type_id, data: {..., <file field>: <url>}}`; numbers as numbers |
| Confirm | `tax/returns/<return id>/status/complete` POST | none. The return becomes "Confirmed" (status 7). |

After the statement of income and the accommodation the app removes its drafts (`drafts/soi-<year>-<tax_payer_id>/remove`,
`drafts/accommodation-<year>-<tax_payer_id>/remove`); the bot does the same.

Rules the screens apply, which the bot applies before it sends anything:

- Accommodation: `accommodation_user_type_id` 1 Tenant, 2 Landlord (an owner-occupier), 3 Others (provided by an employer, or
  living with family). `started_at` and `ended_at` are `YYYY-MM-DD`, both inside the year in view, the end after the start:
  a person who moved in before the year shows from 1 January. `rent_paid` must not be empty or zero, so an owner's nil rent
  is sent as the text `"0.00"`. For a Landlord the owner's name, Payer ID and address are the taxpayer's own; for a tenant
  they are the landlord's (the landlord's Payer ID only when Counta has one).
- Household staff (relation types): 18 Other Support Staff, 19 Driver, 20 Cook, 21 Security, 22 Cleaner, 23 Gardener. They
  sit on the taxpayer's profile, not on one return; the bot adds only the ones e-Tax does not already list. The business's
  employees are not sent.
- Assets (types): 2 Vehicle `{dateOfPurchase, cost, brand, model, yearOfManufacture}`; 3 House or real estate `{address,
  dateOfAcquisition, valueOfProperty}`; 4 Farmland; 5 Others `{dateOfPurchase, address, costOfAcquisition}`. On a
  proprietor's own return Counta lists the business's fixed assets: land and buildings as real estate, everything else as
  Others with the business address (Counta's register has no make or model for a vehicle, and the bot does not make them
  up). A partner's return leaves out the partnership's assets.
- Reliefs (types and fields; files marked *):

  | e-Tax relief | type | fields | Counta relief |
  |---|---|---|---|
  | Life Assurance | 1 | nameOfCompany, policyName, premiumPayment, policyDocument*, certificateOfPremium*, receiptOfPayment* | life_insurance |
  | NHIS | 2 | amount, policyDocument* | nhis |
  | National Pension Scheme | 3 | retirementSavingsAccount, pensionFundAdministrator, totalContribution, rsaStatementForYear* | pension |
  | Voluntary RSA contributions | 4 | same as type 3 | (not claimed yet) |
  | NHF | 5 | amount, policyDocument* | nhf |
  | Interest on owner-occupied accommodation | 6 | primaryMortgageInstitution, capitalSumonMortgage, totalInterestPaidInYear, utilityBillForTheResidence*, bankStatementsReflectingMortgageDeductions* | home_loan_interest |

  Every field is required, and the page warns that a relief without its evidence is denied, so Counta counts a relief only
  once its documents and details are in. Where a person attached several files for one field, the bot makes them one PDF.
  Gratuity relief and rent relief have no section on the form: Counta computes them, they are in the computation attached
  to the return, and nothing is posted for them. A relief already on the draft return that Counta does not claim comes off,
  so the return matches the approved computation.
- Confirming shows a declaration in the taxpayer's name under section 124 of the Nigeria Tax Administration Act 2025.
  **A confirmed return cannot be withdrawn by the taxpayer**: "Unconfirm Submission" exists only in LIRS's admin view. The
  bot confirms only a return the business approved in Counta, after every earlier step succeeded and a last read of the
  return, and only once. A return someone else already confirmed is left alone and reported.

The return carries no tax figure. LIRS assesses from it; the person pays the self-assessed tax by bill.

## 3. The bill

Paying is separate from filing (Payments, Generate/Pay Bill). The bot raises one bill per person (each partner's tax goes to
their own Payer ID with their own receipt), in the same session as the filing.

```
abc/agencies/internal GET (&no_pages=1&order_by=name&is_asc=1)   -> e-Tax's tax stations [{AgencyRef, FullName, orcAgency2, HeadRef}]
abc/agencies/revenues?HeadRef=<HeadRef> GET                      -> the station's revenues [{RevCode, RevName, orcRev}]
tax/bills POST {agency_code: <orcAgency2>, revenue_code: "32102", tax_payer_id, recipients: [{tax_payer_number, name, amount}],
                amount: "<tax>", generate_now: true, start_date: "<year>-01-01", end_date: "<year>-12-31",
                payment_currency_id: 1, remark}
  -> {id, system_reference (the bill reference), amount_due, amount_paid, status_id 25 Unpaid, ...}
```

The tax station is the one saved with the person's login in Counta, or else the one on their e-Tax profile
(`tax_payer.preferred_tax_office_id`, then `tax/offices/<id>`), matched to e-Tax's list of stations by name (e-Tax spells
some its own way, such as "Lekki II Tax Stattion"); Counta keeps the match. `revenue_code` 32102 is Direct Assessment
(RevCode 4010002). A bill already raised for the same year and amount is used again rather than raised twice.

## 4. Paying by bank transfer

Pay Now on a bill opens e-Tax's list of 17 payment channels. Flutterwave's is the Lagos State payments page
`https://payments.lasg-public.com/tax-confirm?bill_type=<bill reference>`, which needs no e-Tax sign-in. It shows the
amount, the name, the tax station, the revenue and the bill reference, and asks for an email address and phone number
(the business's, in Counta). Make Payment offers Card, Bank transfer or USSD, with a processing fee (NGN 5 on NGN 500).
Bank transfer opens Flutterwave's checkout for "LASG Collection", which gives a one-time account: the exact amount (bill plus
fee), a 10-digit account number at Flutterwave MFB, beneficiary LASG Collection, valid for this payment only and for about
an hour. The bot reads the account from Flutterwave's own answer (or the checkout, failing that), then closes the page; it
never presses "I have made this bank transfer" and never pays. A page holding an earlier unused account is reset first
("Reset Payment").

The account expires, so the bot fetches it only when someone chooses to pay. In Counta the person chooses each time how to
pay: by their own bank transfer now (Counta shows the account, the exact amount and when it expires, with a button for a new
one); from the tax wallet or the business account next.

The same payments page shows the bill paid once the transfer lands ("Payment successfully completed"). The bot checks it
every 15 minutes for three days after the account was fetched, which never signs the person out of e-Tax, and Counta then
records the payment and tells whoever files tax. e-Tax's own bill list lagged the payments page in the live test.

## 5. How Counta runs the bot

```
Counta app ── tax-files (pit_send, pit_pay, pit_bill) ──► lirs_jobs ◄── svc_lirs_next / svc_lirs_report
                     │  wakes                                                  ▲
                     ▼                                                         │ taxstreem /lirs/next, /lirs/report
               Cloud Run: bots/lirs  ── POST /tick ── works the jobs ──────────┘   (signed with LIRS_BOT_SECRET)
                     │
                     ├── LIRS e-Tax, as the person
                     └── Lagos State payments page and Flutterwave's checkout
```

- The bot is `bots/lirs` in this repo: Node, TypeScript and Playwright, built into a container for Google Cloud Run
  (`docs/lirs-bot-cloud-run.md` has the set-up). It keeps no data of its own and holds no Supabase key.
- Jobs wait in `public.lirs_jobs`: `file` (the return, to Confirm), `bill`, `pay_account` (the transfer account) and
  `status` (has it been paid). The bot asks `POST /functions/v1/taxstreem/lirs/next` for the next job, gets the job, what it
  needs (the person's figures, home, staff, reliefs and the password, read from Vault for that job) and links to the files
  for an hour, and reports each step and the result to `/lirs/report`. Both calls are signed with `LIRS_BOT_SECRET`
  (`x-counta-signature: t=<seconds>,v1=<HMAC-SHA256 of "<t>.<body>">`, as with Flux).
- Counta wakes the bot when it adds a job (`POST <LIRS_BOT_URL>/tick`, signed the same way); Cloud Scheduler also calls
  `/tick` every five minutes, which is when payment checks and retries run.
- One person is worked at a time (e-Tax keeps one session per account), with a pause between calls. A job that fails for a
  reason worth another try (e-Tax's internal error, a page that did not load, a session ended part way) is tried again after
  2, 4 and 8 minutes; one e-Tax refused (bad data, a wrong password) stops and tells whoever files tax, with e-Tax's own
  words. A job silent for 20 minutes counts as failed. A wrong password marks the login as not working until it is saved
  again.
- e-Tax passwords are kept in Supabase Vault, one secret per person's login (Google Secret Manager after the move to GCP).
  Only the service role can read one, through the function that hands the bot its job. Counta shows the Payer ID and never
  the password; the bot scrubs it from every message and log line.

Settings, in the admin portal or as Edge Function secrets: `LIRS_BOT_URL` (the bot's Cloud Run address) and
`LIRS_BOT_SECRET` (at least 32 characters, the same value as the bot's). The bot's own settings are its environment:
`COUNTA_BOT_URL` (`https://<project>.supabase.co/functions/v1/taxstreem/lirs`) and `LIRS_BOT_SECRET`; `ETAX_BASE` and
`LASG_BASE` change only for tests.

## 6. What Counta collects for this

Per person: the LIRS Payer ID and the Tax ID, their own e-Tax login (Payer ID and password, saved by the person or by whoever
files the business's tax), the household staff for the year, and the accommodation and relief details with the documents
e-Tax asks for (life assurance needs the insurer, the policy name, the policy, the certificate of premium and the receipt;
mortgage interest needs the lender, the capital sum, a utility bill for the home and the bank statements showing the
mortgage deductions; pension needs the RSA number, the administrator and the RSA statement).

## 7. Tests

- `bots/lirs`: `npm test` runs the bot against a stand-in e-Tax, payments page and checkout (`test/mock.ts`), strict where
  e-Tax was strict, with a stand-in Counta: filing, the bill in the same session, the transfer account, the payment, a second
  run, a session ended part way, wrong and expired passwords, a station it cannot place, and the signature on `/tick`.
- The SQL suite covers logins in Vault, the queue, retries, reports, the bill, the account, the payment checks and who may
  call what. The browser test files a partner's return from the app through the real edge functions and the real bot.
- What only the live portal can confirm, on the first live run: that e-Tax takes the documents and reliefs as the bot sends
  them, the tax station match for each person, and the shape of Flutterwave's answer with the account.
