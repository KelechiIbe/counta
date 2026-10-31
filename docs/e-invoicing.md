# E-invoicing with the NRS (MBS)

TaxStreem is applying to NITDA as both a System Integrator (SI) and an Access Point Provider (APP) on the NRS Merchant Buyer Solution (MBS), with Counta as the software. As the SI, Counta builds each invoice to the NRS schema, gets it validated and signed, and prints the IRN and QR code on it. As the APP, it sends signed invoices to buyers and receives invoices for Counta businesses.

The work comes in four parts:

1. The keys and the first checks against the sandbox.
   Part 2a: each business's own keys, the HS and service codes, NRS's place codes and what each invoice needs (below).
2. The SI side: invoices to business and government buyers validated and signed before anyone sees them, till receipts reported within 24 hours, corrections by credit note only, and the IRN and QR code on every copy.
   Part 2b: sending each sale to NRS (below).
3. The APP side: sending to buyers, receiving invoices as bills and checking their stamps, payment status, compliance reports and the copy of the data kept in Nigeria.
4. A full run in the sandbox on the QA business, which is also the working product shown to NITDA and the software testing firm.

## The NRS API

The API is version 1.1 of the MBS API, documented at einvoice.nrs.gov.ng (API Documentation) and in NRS's Postman collection, "E-Invoice Collection". Every call goes to `<base>/api/v1/...` with the headers `x-api-key` and `x-api-secret` from the NRS dashboard. The code lists under `/api/v1/invoice/resources/` (countries, currencies, tax categories, payment means, invoice types, service codes, VAT exemptions and HS codes) need no keys, according to the documentation.

| What | Call |
| --- | --- |
| Health | `GET /api` |
| A business on the MBS | `GET /api/v1/entity/{business_id}` |
| Check an IRN before use | `POST /api/v1/invoice/irn/validate` |
| Validate an invoice | `POST /api/v1/invoice/validate` |
| Sign it | `POST /api/v1/invoice/sign` |
| Confirm, download | `GET /api/v1/invoice/confirm/{irn}`, `GET /api/v1/invoice/download/{irn}` |
| Payment status | `PATCH /api/v1/invoice/update/{irn}` with `payment_status` PENDING, PAID or REJECTED |
| Send to the buyer, look up | `POST /api/v1/invoice/transmit/{irn}`, `GET /api/v1/invoice/transmit/lookup/{irn or tin}` |

The documentation has no sample answers, so the first test (below) records the shape of each answer before anything is mapped.

An IRN is the invoice number with anything that is not a letter or digit taken out, the business's 8-character Service ID and the issue date: `INV0001-94ND90NR-20261110`. The QR code is the IRN with a Unix timestamp after a full stop, and the certificate from `crypto_keys.txt`, encrypted with NRS's public key (RSA, PKCS #1 v1.5) and base64-encoded.

## Keys

All of these are set as Supabase Edge Function secrets, or in TaxStreem's admin portal under Keys and services (Supabase Vault, which wins). The portal shows a secret by its last four characters only.

| Key | What it is |
| --- | --- |
| `NRS_BASE_URL` | The base address on the NRS dashboard, sandbox first. An address pasted with `/api` or `/api/v1` on the end is cut back to the host. |
| `NRS_API_KEY`, `NRS_API_SECRET` | The dashboard's key and secret |
| `NRS_BUSINESS_ID` | TaxStreem's Business ID on the MBS |
| `NRS_SERVICE_ID` | TaxStreem's 8-character Service ID, kept in capitals |
| `NRS_CRYPTO_KEYS` | The whole of `crypto_keys.txt` (My Account, Manage Cryptographic Keys): `{ "public_key": …, "certificate": … }`. Shown by the end of its certificate. |
| `NRS_APP_API_KEY`, `NRS_APP_API_SECRET` | Optional: only if the dashboard gives the APP role its own key pair |
| `GOOGLE_KMS_KEY_RING` | Optional: the Cloud KMS key ring, by default `projects/<project>/locations/us-central1/keyRings/counta-einvoice` |

## The HSM keys

NRS wants signing keys held in a hardware security module. Counta uses Google Cloud KMS keys with protection level HSM, in TaxStreem's Google Cloud project (`infrastructure-staging-477918`), reached with the same service account as Gemini (`GOOGLE_APPLICATION_CREDENTIALS_JSON`). The private halves never leave the HSM; Counta asks KMS to encrypt, decrypt and sign.

1. Turn on the Cloud Key Management Service API in the project.
2. Create the key ring `counta-einvoice` in `us-central1`.
3. Inside it, create two keys with protection level HSM:
   - `nrs-credentials`, symmetric encrypt and decrypt. It wraps each business's NRS key and secret before they are stored.
   - `invoice-signing`, asymmetric signing, Elliptic Curve P-256 with a SHA-256 digest (`EC_SIGN_P256_SHA256`). It makes TaxStreem's own signatures.
4. Give the service account Cloud KMS CryptoKey Encrypter/Decrypter on `nrs-credentials` and Cloud KMS CryptoKey Signer/Verifier on `invoice-signing`.

## The tests

Both are buttons on Keys and services, answered by the `einvoice` edge function (`platform_check`), for TaxStreem's admins signed in with the authenticator code.

**NRS e-invoicing (MBS), Test.** Asks NRS's health check, then each code list in turn with a short pause between calls. If NRS wants the key for the code lists after all, they are asked for again with it. Each list that comes back is copied into `nrs_codes`; an empty or failed one leaves the copy as it was. Then, with the dashboard's key, it asks for the entities the key can see (`GET /api/v1/entity`). The sandbox keeps entity records from TaxStreem's key (403, "access denied. user does not have access to this resource", on 31 October 2026), so the key is proved on the business itself. First it reads the Business ID's invoices (`GET /api/v1/invoice/{business_id}`), which only a key belonging to that business may do. Then it validates a test IRN made with the Service ID and that day's date in Lagos, `CNTCHK1-<Service ID>-<YYYYMMDD>` (`POST /api/v1/invoice/irn/validate`); NRS checks it and keeps nothing. Where NRS does open entity records, the test also finds the entity holding the Business ID, reads its record by the entity's own id and compares the Service ID with NRS's. `GET /api/v1/entity/{id}` takes an entity id, which is not the Business ID. A Service ID that is not 8 letters and numbers is described (its length, and whether it looks like a Business ID) and never repeated. It also tries the APP key pair on the business's invoices if there is one, and whether `crypto_keys.txt` can encrypt a QR code. What the test found goes into `einvoice_checks`: the status and timing of each call and the shape of each answer, with numbers of five or more digits cut to their last four and email addresses removed. No key, secret or certificate is written there.

What the sandbox serves (31 October 2026): 249 countries, 118 currencies, 27 tax categories (with `percent` as text, "Not Available" where there is no fixed rate), 12 payment means, 20 invoice types, 419 service codes (ISIC, 4 digits), 5,612 HS codes (`0101.21` style), 37 states (`NG-LA`) and 776 LGAs (`NG-AB-ANO`, each with its `state_code`), so state and LGA codes come from NRS. VAT exemptions come without a code field: each is kept under its `harmonized_system_code`, named by its `tariff`, with the heading, description and category in `extra`. NRS's own invoice type list names 380 "Credit Note" and 381 "Commercial Invoice", the other way round from the UN/CEFACT codes the schema page uses in its examples; part 2 uses NRS's list and confirms with the sandbox's validation.

**Google Cloud HSM, Test.** Needs only the two roles Counta is given. It encrypts a random value with `nrs-credentials` and decrypts it again, and KMS's answer says the version that did it is an HSM key. It reads the public key of `invoice-signing`, whose answer gives its algorithm and protection level, signs a test value inside the HSM and verifies the signature. The signing version is the newest enabled one when the service account may list versions (Cloud KMS Viewer); without that role it is version 1, the version a new key starts with. Reading a key's settings would take another role, so the test never does. A refusal names the role to give and to whom; a missing key names the key ring.

| Table | Who reads it | What it holds |
| --- | --- | --- |
| `nrs_codes` | Anyone signed in | NRS's code lists: `list`, `code`, `label`, and everything NRS sent with the code in `extra` |
| `einvoice_checks` | TaxStreem's admins (`admin_einvoice_checks`) | Each test: when, who, whether it passed, the note and what it found. Kept a year. |

## Getting each business ready (part 2a)

Each business sends invoices to NRS under its own NRS keys. Its owner, or whoever changes its settings, finds an E-invoicing (NRS) section in Settings. The first save starts it; Gemini then chooses the codes below while the rest is filled in.

| What | Where it lives | Who sets it |
| --- | --- | --- |
| Business ID, Service ID | `einvoice_settings` | The owner, from the business's NRS dashboard |
| API key, API secret, `crypto_keys.txt` | `einvoice_settings`, as Cloud KMS ciphertext | The owner, through the `einvoice` function (`settings_keys`) |
| Service code (ISIC, 4 digits, NRS's list) | `einvoice_settings.service_code` | Gemini, then the owner if they change it |
| HS code of each item (6 digits, NRS's list) | `items.hs_code` | Gemini, then a person who edits prices or keeps the books |
| Street, city, postcode, state and LGA | The main branch (`locations`) | The owner, under Locations |
| Government buyers | `customers.kind = 'government'` | Whoever records sales |

The key, secret and `crypto_keys.txt` are wrapped with `nrs-credentials` in the HSM before they are stored, each bound to the business and the field (`counta:einvoice:<business>:<field>` as additional authenticated data), so a value copied to another business or field does not decrypt. Only their last four characters come back to the app. Saving new keys tests them at once (`settings_check`): NRS must let the key read the business's invoices, accept a test IRN made with its Service ID (NRS keeps nothing) and `crypto_keys.txt` must encrypt a QR code. A test counts only for the keys and IDs it ran on: any change needs a new one, and switches e-invoicing off until it passes.

While NRS is in test mode, TaxStreem's admins can run a business on TaxStreem's own provider keys (admin portal, the business's page, E-invoicing). The QA business uses this for the sandbox demo. In production each business uses its own keys.

**Places.** NRS codes states (`NG-LA`) and LGAs (`NG-LA-IKE`) itself. Each of the 774 LGAs Counta keeps (`ng_lgas`) has its NRS code in `ng_lgas.nrs_code`, matched by name against NRS's list of 31 October 2026 and by hand for the 43 NRS spells differently (Obia/Akpor for Obio/Akpor, Yenegoa for Yenagoa, Abuja Municipal for the Municipal Area Council, Oyo West for Oyo, and so on). NRS's list has two entries that are not LGAs, Ibadan Central and Karawa, which nothing maps to. `private.nrs_place(state, lga)` gives both codes from names as people type them.

**HS codes.** Gemini gets each item's name, brand, category, description and the kind of business, and answers with a six-digit HS 2022 subheading. A code NRS lists is used; one it does not gets a second look among NRS's codes under the same heading (or chapter). Below the business's confidence threshold (at least 80%) the code is used and marked to confirm; with no code at all, invoice lines with that item will wait. A renamed item is coded again unless a person chose its code. The `counta-einvoice` cron job wakes Gemini every five minutes while anything waits, only for businesses that have started.

**Readiness.** Before e-invoicing can be switched on: the business's Tax ID, its email and phone, the main branch's street, city, state and LGA, the five keys (or TaxStreem's test keys), a passed test, and the service code when the business sells services. Items without a confirmed HS code and business customers without a Tax ID are counted but do not hold the business back.

**The IRN.** `private.nrs_irn(number, service_id, day)` makes it: the invoice number in letters and digits, the Service ID and the date.

## Sending sales to NRS (part 2b)

The owner switches sending on in Settings, E-invoicing, once everything above is in place (`einvoice_settings.enabled`). From then on each new invoice, till receipt and credit note goes to NRS as it is issued. Sales issued before the switch stay as they are. Imported sales, scheduled ones, those recorded from the bank feed and invoices that came from Bujeti are left out, because they were invoiced elsewhere.

**Clear or report.** The buyer decides. A sale to a business or government customer (not the walk-in customer) is cleared: NRS validates and signs it before the buyer can see it, including a receipt at the till. A sale to anyone else is reported: its IRN and QR code are made at once, so the receipt prints straight away, and it goes to NRS with the next batch, within five minutes (NRS expects it within 24 hours). NRS's API has no call that takes several invoices at once, and neither DigiTax's API nor Qorpy's Postman collection has one (checked 31 October 2026), so a batch is a queue the function sends one invoice at a time.

| State | Meaning |
| --- | --- |
| `waiting` | In line for NRS, with `next_try_at` |
| `sending` | The function has it; one left in this state more than five minutes is picked up again |
| `signed` | NRS signed it. A walk-in sale keeps the QR code made when it was issued |
| `refused` | NRS refused it, or something it needs is missing. The note says why, in words the owner can act on |
| `stopped` | Taken back, voided before sending, or a credit note whose sale was never signed |

Each sale has one row in `einvoice_docs`, readable only through the app's functions. `sales.irn` and `sales.irn_status` follow it, and the list of sales shows a chip for it.

**Invoices to a business or government.** Issuing one needs the buyer's Tax ID first. The invoice then goes to NRS as a draft that is held (`held`): nothing is in the books and nothing reaches the buyer. Once NRS signs it, it is issued and posted on its own date, or today if that month is closed. While NRS has it, the invoice cannot be edited or issued again; "Take it back to change" stops it if NRS has not started. If NRS refuses it, it is a draft again with NRS's reason, and the people who record sales get a notice. A refused till receipt to a business (already paid and in the books) can be sent again once the customer's details are put right; its amounts change only by voiding it.

**What the buyer sees.** A cleared sale cannot be printed, sent or opened by its link until NRS has signed it; the link says it is waiting for NRS. Once signed, the receipt, the till slip, the A4 copy and its PDF, and the customer's link carry the QR code and the IRN.

**After signing.** A signed sale cannot be voided; a credit note cancels it. A credit note goes to NRS as type 380 with the original's IRN in `billing_reference`, once the original is signed. When a sale sent as unpaid is paid later, the function tells NRS (`PATCH /api/v1/invoice/update/{irn}`, `PAID`).

**The function.** Issuing a sale asks the `einvoice` function at once (`private.call_function`, with the hook secret in `x-counta-hook`). For a reported sale that call only makes the QR code; for a cleared one it validates and signs. The cron job behind `einvoice_tick` sends whatever else is due every five minutes, with a short pause between calls (`NRS_GAP_MS`). The database gives the facts of each sale (`svc_einvoice_claim`), and `supabase/functions/einvoice/invoice.ts` writes them as NRS's invoice, so a change NRS asks for in the mapping needs no database update. Goods lines carry the item's HS code; service and delivery lines carry the business's service code. When NRS does not answer, the sale is tried again after 1, 5, 15 and 30 minutes, then hourly. A sale tried before is first looked up with `confirm`, so one NRS signed without Counta hearing back is not signed twice. Keys NRS refuses are tried again, with a note to check them. A sale missing something NRS needs (an HS code, the state and LGA of the branch) is tried four times, then marked refused with what to add.

**On TaxStreem's keys.** Businesses share TaxStreem's Service ID, so the number part of the IRN starts with four characters of the business's id (`848BRCT000015-94ND90NR-20261031`), and two businesses with the same invoice number never clash.

**Keeping an eye on it.** Settings, E-invoicing, shows how many sales NRS has signed, how many wait and how many it refused, and lists the sales that need a person: refused ones, and those waiting more than an hour or tried three times. A sale waiting 12 hours, and again at 20, sends an alert by push and email to whoever changes the settings. A service code Gemini was less sure of than the business's threshold (at least 80%) waits for the owner to confirm it before sending can start.

## The NITDA guideline

The National Regulatory Guideline for Electronic Invoicing in Nigeria 2025 (updated March 2026) sets the eligibility rules. An SI pays a ₦2 million application fee and needs ₦10 million paid-up capital (s.11). An APP pays ₦5 million, needs ₦100 million paid up and must present a minimum viable product for e-invoicing (s.18). Both need at least a third of their shares held by Nigerians and software tested by a licensed software quality assurance firm (s.10, s.17). An APP must store or back up invoice data on servers in Nigeria (s.23(vii)) and keep 99.9% uptime each month (s.25(i)). ISO 27001 is encouraged, not required (s.10(vi), s.17(v)).
