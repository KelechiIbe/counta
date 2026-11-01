# TaxStreem E-Invoicing API

Last updated: 1 November 2026

## Overview

The TaxStreem E-Invoicing API lets a platform that issues invoices for many businesses (a point-of-sale system, an ERP, a bank's merchant tools) send those invoices to the Nigeria Revenue Service (NRS) Merchant Buyer Solution (MBS). TaxStreem keeps an e-invoicing record for each business (a "merchant"), has NRS validate and sign each invoice, returns the Invoice Reference Number (IRN) and QR code, and reports every later change back to the platform.

Partners on TaxStreem's developer portal reach this API through Prism, TaxStreem's partner platform. TaxStreem issues credentials to approved integrators on request at [support@taxstreem.com](mailto:support@taxstreem.com). Service levels are in our [Service Level Agreement](/sla).

Base address:

```
https://krtqqhndmncarwusukrw.supabase.co/functions/v1/einvoice/prism/
```

Every call is a `POST` with a JSON body over HTTPS (TLS 1.2 or later).

## Authentication

TaxStreem gives each approved integrator a client ID and a client secret for OAuth 2.0 (RFC 6749, the client credentials grant). Exchange them for an access token, then send the token as a bearer token on every call. Prism, and integrators set up before OAuth was available, may instead sign each request with a shared secret, as described below; either way is accepted on every call.

### OAuth 2.0 client credentials

```
POST https://krtqqhndmncarwusukrw.supabase.co/functions/v1/einvoice/oauth/token
Authorization: Basic <base64 of "client_id:client_secret">
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials&scope=einvoice
```

`client_id` and `client_secret` may go in the form body instead of the `Authorization` header (one or the other, never both). The body may also be JSON. The answer, which must not be cached:

```json
{ "access_token": "cat_…", "token_type": "Bearer", "expires_in": 3600, "scope": "einvoice" }
```

Send the token with each call:

```
Authorization: Bearer cat_…
```

A token lasts one hour. Ask for a new one when it expires or when a call answers 401 with `WWW-Authenticate: Bearer error="invalid_token"`. A client holds at most 20 live tokens; asking for a 21st retires the oldest. When TaxStreem revokes a client, its tokens stop working at once.

| Token error | Status | Meaning |
| --- | --- | --- |
| `invalid_client` | 401 | The client ID or secret is wrong, or the client was revoked. |
| `unsupported_grant_type` | 400 | `grant_type` is not `client_credentials`. |
| `invalid_scope` | 400 | The only scope is `einvoice`. |
| `invalid_request` | 400, 405 | The credentials were sent twice, the body could not be read, or the method was not `POST`. |

TaxStreem keeps only a SHA-256 hash of each client secret and each token. Keep the client secret on your servers; never put it in an app or a web page.

### Signing with a shared secret

A request may instead carry a signature made with the signing secret TaxStreem gives you:

```
x-taxstreem-signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<raw body>">
```

TaxStreem refuses a signature more than 300 seconds old, a body changed after signing, and any request without a signature (401).

Signing in Node.js:

```js
import { createHmac } from 'node:crypto';
const raw = JSON.stringify(body);
const t = Math.floor(Date.now() / 1000);
const sig = `t=${t},v1=${createHmac('sha256', process.env.SIGNING_SECRET).update(`${t}.${raw}`).digest('hex')}`;
await fetch(base + 'einvoices', { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-taxstreem-signature': sig }, body: raw });
```

## Answers and errors

| Status | Meaning |
| --- | --- |
| 200 | Done. The body has `ok: true` and what was asked for. |
| 400 | The body is not JSON, or something required is missing (`org_id`, `partner`, `invoice`). |
| 401 | The access token is missing, wrong or expired, or the signature is missing, wrong or too old. |
| 404 | No merchant with that `org_id`, or no invoice with that `ref`. |
| 409 | TaxStreem cannot take it yet: e-invoicing is not on for the merchant (the answer says what is missing), the merchant has already used the invoice number that day, or an invoice's seal is not ready. |
| 422 | Something in the request needs correcting. `error` names the field: `Line 2 (Panadol): goods need hs_code, the HS code from NRS's list.` For a UBL copy, `missing` lists what the invoice lacks. |
| 502, 503 | The hardware security module that protects merchants' keys could not be reached. Send the call again later. |
| 500 | TaxStreem could not finish. Sending the same call again is safe. |

Every refusal has `ok: false` and an `error` in plain words that you can show to your user.

## Merchants

`org_id` is the merchant's TaxStreem business id. TaxStreem creates the merchant on the first call that names it, owned by the contact you give.

```
POST /merchant
{
  "org_id": "biz_900",
  "merchant": {
    "name": "Bright Pharmacy Ltd", "tin": "11223344-0001", "rc_number": "RC778899",
    "email": "accounts@brightpharm.ng", "phone": "08031234567",
    "vat_registered": true, "offering": "goods", "description": "Retail pharmacy",
    "address": { "street": "12 Allen Avenue", "city": "Ikeja", "state": "NG-LA", "lga": "Ikeja", "postcode": "100271" },
    "service_code": "4772",
    "contact": { "name": "Ada Obi", "email": "ada@brightpharm.ng", "phone": "08035550000" }
  },
  "nrs": {
    "business_id": "6dc03c76-1d83-4a39-a4de-51bd70547aef", "service_id": "94ND90NR",
    "api_key": "…", "api_secret": "…", "crypto_keys": "<the whole contents of crypto_keys.txt>"
  }
}
```

- `merchant.name` and `merchant.contact.email` are required the first time. Everything else can follow on a later call.
- `state` and `lga` take NRS's codes (`NG-LA`, `NG-LA-IKE`) or their names (`Lagos`, `Ikeja`). NRS prints the full address on every invoice, so it needs the street, city, state, local government area and a 6-digit postcode.
- `offering` is `goods`, `services` or `both`. `service_code` is the ISIC code from NRS's list, used for the merchant's service lines.
- The NRS keys come from the merchant's own NRS dashboard. TaxStreem encrypts each one with a key held in a hardware security module as it arrives, binds it to the merchant and the field, keeps only its last four characters readable, and never returns a key. Keys sent again replace the old ones, and new keys are tested with NRS at once.

The answer:

```json
{ "ok": true, "merchant": { "counta_org_id": "…", "created": true, "name": "Bright Pharmacy Ltd",
  "einvoicing": { "enabled": true, "platform_keys": false,
    "keys": { "api_key": "•••• 9f2c", "api_secret": "•••• 77ab", "crypto_keys": "certificate •••• T0=" },
    "check": { "ok": true, "note": "NRS let the key act for the Business ID. NRS accepted a test IRN made with the Service ID. crypto_keys.txt makes a QR code." },
    "missing": [] } } }
```

E-invoicing switches on by itself once `missing` is empty. Each entry in `missing` has an `id`:

| id | What NRS still needs |
| --- | --- |
| `tin` | The merchant's Tax ID |
| `contact` | The merchant's email address and phone number |
| `address` | The street, city, state, local government area and postcode |
| `keys` | The Business ID, Service ID, API key, API secret and crypto_keys.txt |
| `check` | NRS accepting the keys |
| `service` | The service code, for a merchant that sells services |

## Sending an invoice

```
POST /einvoices
{
  "org_id": "biz_900",
  "partner": { "id": "ptn_42", "name": "Shopwise POS", "books": false },
  "invoice": {
    "ref": "SW-2026-000981", "type": "invoice", "number": "SW-2026-000981",
    "issue_date": "2026-11-14", "due_date": "2026-11-28", "currency": "NGN", "prices_include_vat": false,
    "customer": { "kind": "business", "name": "Abuja Pharmacy Ltd", "tin": "22334455-0001", "email": "ap@abujapharm.ng", "phone": "08039998888",
      "address": { "street": "4 Aminu Kano Crescent", "city": "Wuse", "state": "FCT", "lga": "Municipal Area Council", "postcode": "900288", "country": "NG" } },
    "lines": [
      { "description": "Paracetamol 500mg x 1000", "kind": "goods", "hs_code": "3004.90", "sku": "PCM500", "qty": 20, "unit": "pack", "unit_price": 18500, "vat": "standard" },
      { "description": "Delivery to Wuse", "kind": "service", "qty": 1, "unit_price": 2000 }
    ],
    "total": 399900,
    "paid": { "amount": 399900, "method": "transfer", "reference": "TRF-7781", "paid_at": "2026-11-14T10:30:00+01:00" }
  }
}
```

`merchant` and `nrs` (as in [Merchants](#merchants)) may come with a merchant's first invoice, to set it up in the same call.

`partner.id` is your id for the partner whose invoice this is. Together with `invoice.ref` it identifies the invoice: the same `ref` from the same partner is the same invoice. `partner.books` decides where the invoice lives: `true` puts it in the merchant's books in Counta as a sale; `false` keeps it outside the books, for merchants whose books are kept elsewhere.

| Field | Meaning |
| --- | --- |
| `ref` | Required. Your own id for the invoice, up to 100 characters. |
| `type` | `invoice` (the default), `receipt` (paid at once, may be to an unnamed buyer) or `credit_note`. |
| `number` | The printed number. Outside the books, its letters and digits begin the IRN, so a merchant may use a number once a day. Defaults to `ref`. |
| `issue_date`, `due_date` | `YYYY-MM-DD`. Today by default; never in the future, nor more than a year ago. |
| `currency` | `NGN`. |
| `prices_include_vat` | Whether `unit_price` includes VAT. Default `false`. |
| `customer.kind` | `business`, `government` or `individual`. `business` by default when there is a `tin`. |
| `customer.tin` | Required for a business or government buyer in Nigeria. |
| `customer.name` | Required on an invoice or credit note. A receipt without it is to a walk-in customer. |
| `lines` | 1 to 300 lines, each with `description`, `qty` (above zero) and `unit_price`. |
| `lines[].kind` | `goods` or `service`. `goods` by default when there is an `hs_code`. |
| `lines[].hs_code` | Required for goods: the HS code from NRS's list, such as `3004.90`. |
| `lines[].vat` | `standard` (the default), `zero` or `exempt`. |
| `lines[].unit` | The unit in words (`pack`, `carton`, `kg`) or as NRS's quantity code (`XPK`, `KGM`). |
| `lines[].discount` | An amount off the line. |
| `total` | Optional. When sent, TaxStreem's total must agree within ₦1, or the invoice is refused with both figures. |
| `paid` | What was paid: `amount`, `method` (`cash`, `transfer`, `card`, `pos`, `cheque` or `other`), `reference`, `paid_at`. |
| `original_ref` | For a credit note: the `ref` of the invoice it corrects. |

An invoice to a business or government is cleared: NRS validates and signs it before the buyer receives it. An invoice or receipt to anyone else is reported to NRS within five minutes, with its QR code made at once.

TaxStreem sends the invoice to NRS during your call, so the answer usually says `signed` already, with the IRN and QR code. That takes a second or two; when NRS is slow it can take up to a minute, so allow 90 seconds for the call.

```json
{ "ok": true, "duplicate": false, "resubmitted": false,
  "invoice": { "id": "…", "ref": "SW-2026-000981", "partner_id": "ptn_42", "books": false, "type": "invoice",
    "number": "SW2026000981", "issue_date": "2026-11-14", "currency": "NGN", "subtotal": 372000, "vat": 27900, "total": 399900,
    "paid": true, "kind": "clear", "state": "signed", "irn": "SW2026000981-94ND90NR-20261114", "qr": "…",
    "signed_at": "2026-11-14T09:31:07Z", "note": "Signed by NRS.", "tries": 1, "next_try_at": null, "nrs_knows_paid": true,
    "buyer": { "state": "due", "note": null, "at": null } } }
```

## Invoice states

| state | Meaning |
| --- | --- |
| `waiting` | Not yet sent, or NRS did not answer and TaxStreem will try again (`next_try_at`, with NRS's words in `note`). |
| `sending` | NRS is checking it now. |
| `signed` | NRS signed it. `irn` and `qr` are final. |
| `refused` | NRS will not accept it as it stands. `note` gives NRS's reason. Send it again, corrected, under the same `ref`. |
| `stopped` | It will not go, such as a credit note whose invoice NRS never signed. |

`buyer.state` follows a signed invoice to a business or government on its way to the buyer: `due`, `sending`, `transmitting` (NRS has it), `transmitted` (delivered to the buyer's access point), `acknowledged` (the buyer's access point confirmed it) or `failed`.

The same invoice sent again under the same `ref` returns `duplicate: true` with the invoice as it stands, and nothing goes to NRS twice. An invoice NRS refused may be sent again under its `ref` with the problem corrected; the answer has `resubmitted: true`.

## Status and payments

```
POST /einvoice-status   { "org_id": "biz_900", "partner_id": "ptn_42", "ref": "SW-2026-000981" }
→ { "ok": true, "invoice": { … } }
```

```
POST /einvoice-paid
{ "org_id": "biz_900", "partner_id": "ptn_42", "ref": "SW-2026-000981",
  "paid": { "amount": 399900, "method": "transfer", "reference": "TRF-7781", "paid_at": "2026-11-20T14:05:00+01:00" } }
→ { "ok": true, "invoice": { … } }
```

`amount` defaults to what is still owed. Once a signed invoice is paid in full, TaxStreem tells NRS at once.

## Copies of an invoice

### UBL 2.1 (Peppol PINT NG)

```
POST /einvoice-ubl   { "org_id": "biz_900", "partner_id": "ptn_42", "ref": "SW-2026-000981" }
→ 200, Content-Type: application/xml, the invoice as a file
```

The copy is UBL 2.1 in OpenPeppol's PINT NG Billing 1.0.0 (`urn:peppol:pint:billing-1@ng-1`), the Nigerian form of the Peppol International invoice: an `Invoice`, or a `CreditNote` for a credit note. Its `UUID` is TaxStreem's id for the invoice and its IRN is an `AdditionalDocumentReference`. Seller and buyer are identified by Tax ID (`EndpointID` scheme `0244`), with state and local government area codes, and each line carries its HS or service code. Copies are checked against the UBL 2.1 schema and OpenPeppol's PINT NG rules.

PINT NG covers invoices to businesses and government. A receipt or invoice to a consumer, or an invoice missing something PINT NG requires, answers 422 with the list in `missing`, for example `["the buyer's postcode", "Line 1 (Rice): an HS code"]`.

### TaxStreem's seal

```
POST /einvoice-signed-copy   { "org_id": "biz_900", "partner_id": "ptn_42", "ref": "SW-2026-000981" }
→ { "ok": true, "seal": { "format": "JAdES baseline B-B (JWS compact, ES256)", "irn": "…", "sealed_at": "…", "jws": "eyJ…" } }
```

Once NRS signs an invoice, TaxStreem seals the invoice exactly as it was sent to NRS: a JAdES baseline B-B signature (ETSI TS 119 182-1), a JWS in compact form with the invoice attached as its payload. The key that makes the seal is held in a hardware security module and never leaves it. The protected header carries `alg` (`ES256`), `iat` (when it was sealed), `x5c` (TaxStreem's certificate) and `x5t#S256` (that certificate's SHA-256 thumbprint).

Until the seal exists the call answers 409: NRS has not signed the invoice yet, or the seal is still being made (when the security module cannot be reached, TaxStreem keeps the invoice and seals it within five minutes of the module returning).

### Checking a seal

TaxStreem's certificate is public:

```
GET https://krtqqhndmncarwusukrw.supabase.co/functions/v1/einvoice/certificate
→ the certificate (PEM), with its SHA-256 in x-certificate-sha256
```

To check a seal: confirm `x5t#S256` is the thumbprint of the certificate in `x5c`, that the certificate is TaxStreem's (the same as the one above), and that the ES256 signature verifies with its key. In Node.js:

```js
import { X509Certificate, createHash, createPublicKey, verify } from 'node:crypto';
const [h, p, s] = jws.split('.');
const header = JSON.parse(Buffer.from(h, 'base64url'));
const der = Buffer.from(header.x5c[0], 'base64');
const thumb = createHash('sha256').update(der).digest('base64url');
const cert = new X509Certificate(der);
const ok = thumb === header['x5t#S256'] && cert.fingerprint256 === published.fingerprint256 &&
  verify('sha256', Buffer.from(`${h}.${p}`), { key: cert.publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(s, 'base64url'));
const invoiceAsSent = JSON.parse(Buffer.from(p, 'base64url'));
```

`published` is the certificate fetched from the address above, as an `X509Certificate`.

## Callbacks

TaxStreem reports every change to the callback address you register with us, signed the same way you sign your calls:

```
POST <your callback address>
x-counta-signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<raw body>">
x-counta-event: einvoice.updated
x-counta-delivery: <the callback's id>

{ "event": "einvoice.updated", "id": "<the callback's id>", "change": "signed", "at": "2026-11-14T09:31:07Z",
  "org_id": "biz_900", "partner_id": "ptn_42", "ref": "SW-2026-000981", "invoice": { … } }
```

`change` is one of `signed`, `refused`, `stopped`, `buyer_transmitted`, `buyer_acknowledged`, `buyer_failed` and `paid_reported`. `invoice` is the invoice as it stands when the callback is sent, so treat `invoice` as the truth and `change` as the reason the callback came.

Answer with any 2xx status. Anything else, or no answer within 15 seconds, is retried after 1 minute, 5 minutes, 15 minutes, 30 minutes, 1 hour and then every 3 hours, 12 attempts in all. The same callback can arrive twice; its `id` tells them apart.

## Support

Write to [support@taxstreem.com](mailto:support@taxstreem.com), around the clock. Response and resolution times are in the [Service Level Agreement](/sla).
