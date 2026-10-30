# E-invoicing with the NRS (MBS)

TaxStreem is applying to NITDA as both a System Integrator (SI) and an Access Point Provider (APP) on the NRS Merchant Buyer Solution (MBS), with Counta as the software. As the SI, Counta builds each invoice to the NRS schema, gets it validated and signed, and prints the IRN and QR code on it. As the APP, it sends signed invoices to buyers and receives invoices for Counta businesses.

The work comes in four parts:

1. The keys and the first checks against the sandbox (this part).
2. The SI side: invoices to business and government buyers validated and signed before anyone sees them, till receipts reported within 24 hours, corrections by credit note only, and the IRN and QR code on every copy.
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

**NRS e-invoicing (MBS), Test.** Asks NRS's health check, then each code list in turn with a short pause between calls, then TaxStreem's own entity record with the dashboard's key (which proves the key, the secret and the Business ID together), the APP key pair if there is one, and whether `crypto_keys.txt` can encrypt a QR code. If NRS wants the key for the code lists after all, they are asked for again with it. States and LGAs, which the invoice schema asks for but the Postman collection does not list, are asked for once each; their absence is not counted as a failure. Each list that comes back is copied into `nrs_codes` (an empty or failed one leaves the copy as it was). What the test found goes into `einvoice_checks`: the status and timing of each call and the shape of each answer, with numbers of five or more digits cut to their last four and email addresses removed. No key, secret or certificate is written there.

**Google Cloud HSM, Test.** Checks that `nrs-credentials` is a symmetric HSM key and that a random value encrypts and decrypts, then that `invoice-signing` is an HSM key of the right kind and that a signature from its newest enabled version verifies with its public key. A refusal names the role to give and to whom; a missing key names the key ring.

| Table | Who reads it | What it holds |
| --- | --- | --- |
| `nrs_codes` | Anyone signed in | NRS's code lists: `list`, `code`, `label`, and everything NRS sent with the code in `extra` |
| `einvoice_checks` | TaxStreem's admins (`admin_einvoice_checks`) | Each test: when, who, whether it passed, the note and what it found. Kept a year. |

## The NITDA guideline

The National Regulatory Guideline for Electronic Invoicing in Nigeria 2025 (updated March 2026) sets the eligibility rules. An SI pays a ₦2 million application fee and needs ₦10 million paid-up capital (s.11). An APP pays ₦5 million, needs ₦100 million paid up and must present a minimum viable product for e-invoicing (s.18). Both need at least a third of their shares held by Nigerians and software tested by a licensed software quality assurance firm (s.10, s.17). An APP must store or back up invoice data on servers in Nigeria (s.23(vii)) and keep 99.9% uptime each month (s.25(i)). ISO 27001 is encouraged, not required (s.10(vi), s.17(v)).
