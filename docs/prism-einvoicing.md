# Prism's channel for e-invoicing

Prism is TaxStreem's product for partners: point-of-sale systems, ERPs, banks' merchant tools and anyone else who sends invoices for many businesses. Prism holds the partners' API keys, counts their credits and runs the developer portal. Counta does the e-invoicing behind it. For each merchant it keeps a business, sends the partner's invoices to NRS (the Merchant Buyer Solution), sends signed invoices on to the buyer and tells Prism how each one went.

This page is the contract between Prism and Counta. The part partners see (keys, credits, the public API reference and the Postman collection) is Prism's.

## Signing, or an OAuth 2.0 token

Every call is a `POST` with a JSON body, authenticated one of two ways. Prism signs with the shared secret below. Other integrators get an OAuth 2.0 client (client credentials grant, RFC 6749), made by an admin on the admin portal's Keys page (API clients); the secret is shown once and only its SHA-256 is kept. The client asks for a token and sends it as `Authorization: Bearer cat_…`:

```
POST https://krtqqhndmncarwusukrw.supabase.co/functions/v1/einvoice/oauth/token
Authorization: Basic <base64 of "client_id:client_secret">     (or client_id and client_secret in the body)
grant_type=client_credentials&scope=einvoice
→ { "access_token": "cat_…", "token_type": "Bearer", "expires_in": 3600, "scope": "einvoice" }   (Cache-Control: no-store)
```

A token lasts an hour; a client keeps at most 20 live ones (the oldest give way); revoking a client on the Keys page ends its tokens at once. Errors follow RFC 6749: `invalid_client` (401, with a Basic challenge), `unsupported_grant_type`, `invalid_scope` and `invalid_request` (400), and 405 for anything but `POST`. A wrong or expired bearer token on a partner call answers 401 with `WWW-Authenticate: Bearer error="invalid_token"`. A request with a bearer token is not also checked for a signature.

The signature uses the secret Prism's bills already use (`TAXSTREEM_SSO_SECRET`, set on both sides):

```
x-taxstreem-signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<raw body>" with TAXSTREEM_SSO_SECRET>
```

Counta refuses a signature more than 300 seconds old, a body changed after signing, and anything unsigned (401). The base address is:

```
https://krtqqhndmncarwusukrw.supabase.co/functions/v1/einvoice/prism/
```

Signing in Node:

```js
import { createHmac } from 'node:crypto';
const raw = JSON.stringify(body);
const t = Math.floor(Date.now() / 1000);
const sig = `t=${t},v1=${createHmac('sha256', process.env.TAXSTREEM_SSO_SECRET).update(`${t}.${raw}`).digest('hex')}`;
await fetch(base + 'einvoices', { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-taxstreem-signature': sig }, body: raw });
```

## Answers

| Status | Meaning |
| --- | --- |
| 200 | Done. The body has `ok: true` and what was asked for. |
| 400 | The body is not JSON, or something required is missing (`org_id`, `partner`, `invoice`). |
| 401 | The bearer token is wrong or expired, or the signature is missing, wrong or too old. |
| 404 | Counta has no merchant with that `org_id`, or no invoice with that `ref`. |
| 409 | Counta cannot take it yet: e-invoicing is not on for the merchant (the answer says what is missing), the invoice number is already used by the merchant that day, or an invoice has no seal yet. |
| 422 | Something in what was sent needs putting right. `error` says what, by field: `Line 2 (Panadol): goods need hs_code, the HS code from NRS's list.` |
| 502, 503 | The HSM could not be reached to wrap the merchant's keys. Send them again later. |
| 500 | Counta could not finish. Send the same call again; it is safe. |

Every refusal has `ok: false` and `error` in plain words that can be shown to the partner.

## The merchant

`org_id` is always the merchant's TaxStreem business id, the same id single sign-on uses. Counta makes the merchant's business on the first call that names it, owned by the contact Prism gives. That person becomes its owner the first time they open Counta from TaxStreem; Counta sends them nothing.

```
POST /prism/merchant
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
- `state` and `lga` are NRS's codes (`NG-LA`, `NG-LA-IKE`) or their names (`Lagos`, `Ikeja`). NRS puts the full address on every invoice, so it needs the street, city, state, LGA and a 6-digit postcode.
- `offering` is `goods`, `services` or `both`. `service_code` is the ISIC code from NRS's list for the merchant's service lines; without it Gemini chooses one, and a merchant that sells services waits until it has.
- The NRS keys come from the merchant's NRS dashboard. Counta wraps each with TaxStreem's HSM key as it arrives, bound to the business and the field, keeps only its last four characters in the clear, and never gives a key back. Keys sent again replace the old ones. The merchant can also add them in Counta, under Settings, E-invoicing.
- New keys, or a new Business ID or Service ID, are tested with NRS at once.
- For a business Prism made, a later call changes what it names. For a business its owner set up in Counta, Prism only fills what is empty.

The answer:

```json
{ "ok": true, "merchant": { "counta_org_id": "…", "created": true, "name": "Bright Pharmacy Ltd",
  "einvoicing": { "enabled": true, "platform_keys": false,
    "keys": { "api_key": "•••• 9f2c", "api_secret": "•••• 77ab", "crypto_keys": "certificate •••• T0=" },
    "check": { "ok": true, "note": "NRS let the key act for the Business ID. NRS accepted a test IRN made with the Service ID. crypto_keys.txt makes a QR code." },
    "missing": [] } } }
```

E-invoicing switches itself on once nothing in `missing` is left. Each entry in `missing` has an `id` and words to show:

| id | What NRS still needs |
| --- | --- |
| `tin` | The merchant's Tax ID |
| `contact` | The merchant's email and phone |
| `address` | The street, city, state, LGA and postcode |
| `keys` | The Business ID, Service ID, API key, API secret and crypto_keys.txt |
| `check` | NRS accepting the keys |
| `service` | The service code, for a merchant that sells services |

A merchant whose owner switched e-invoicing off in Counta stays off; invoices for it are answered 409.

## An invoice

```
POST /prism/einvoices
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
    "paid": { "amount": 399900, "method": "transfer", "reference": "TRF-7781", "paid_at": "2026-11-14T10:30:00+01:00" },
    "notes": "Thank you for your business."
  },
  "merchant": { … }, "nrs": { … }
}
```

`merchant` and `nrs` are optional here: send them with a merchant's first invoice to set it up in the same call.

### The partner

- `partner.id` is Prism's id for the partner. With `invoice.ref` it names the invoice: the same `ref` from the same partner is the same invoice.
- `partner.name` is shown to the merchant and names the partner's holding account.
- `partner.books` is set by the partner's key and is required:
  - `true`: the invoice goes in the merchant's books in Counta, a sale like any other.
  - `false`: e-invoicing only. NRS signs it for the merchant, who sees it in Counta under Settings, E-invoicing; it stays out of the books, the reports and the tax returns. This is for merchants whose books are kept somewhere else.

### The invoice

| Field | |
| --- | --- |
| `ref` | Required. The partner's own id for the invoice, up to 100 characters. |
| `type` | `invoice` (the default), `receipt` (paid at once, can be to someone unnamed) or `credit_note` (e-invoicing only, for now). |
| `number` | What is printed. E-invoicing only, its letters and digits are the first part of the IRN, so the merchant may use a number once a day. Defaults to `ref`. In the books the sale takes the merchant's next Counta number and keeps this as its reference. |
| `issue_date`, `due_date` | `YYYY-MM-DD`. Today by default; not in the future, nor more than a year ago. |
| `currency` | `NGN` only, for now. |
| `prices_include_vat` | Whether `unit_price` includes VAT. Default `false`. |
| `customer.kind` | `business`, `government` or `individual`. Defaults to `business` when there is a `tin`. |
| `customer.tin` | Required for a business or government buyer in Nigeria: NRS checks invoices to them against it. |
| `customer.name` | Required on an invoice or credit note. A receipt without it is to a walk-in customer. |
| `lines` | 1 to 300. Each has `description`, `qty` (above zero) and `unit_price`. |
| `lines[].kind` | `goods` or `service`. Defaults to `goods` when there is an `hs_code`. |
| `lines[].hs_code` | Required for goods: the HS code from NRS's list (`3004.90`, or `300490` or `3004.90.00`, which mean the same). In the books, the `sku` of one of the merchant's items that has an HS code does instead. |
| `lines[].vat` | `standard` (the default), `zero` or `exempt`. VAT is at the merchant's rate when it is VAT-registered, nothing when it is not. In the books, a line matched to one of the merchant's items by `sku` takes the item's VAT treatment. |
| `lines[].unit` | The unit, in words (`pack`, `carton`, `kg`) or as NRS's quantity code (`XPK`, `KGM`). |
| `lines[].discount` | An amount off the line. |
| `total` | Optional. When sent, Counta's total must agree within ₦1, or the invoice is refused with both figures. |
| `paid` | What was paid: `amount` (the total by default), `method` (`cash`, `transfer`, `card`, `pos`, `cheque` or `other`), `reference`, `paid_at`. A receipt is paid in full. |
| `original_ref` | A credit note's invoice: the `ref` it corrects, from the same partner. Its credit notes may not come to more than it. |

Service lines carry the merchant's service code; goods lines carry their HS codes. Invoices to a business or government are business-to-business (or business-to-government) and NRS signs them before the buyer gets them. Invoices to anyone else are reported to NRS with the next five-minute batch, with their QR code made at once.

### What happens

1. Counta records it. In the books, an invoice to a business waits as a draft until NRS signs it, as invoices do in Counta; then it is issued and posted. A receipt, or an invoice to a person, is posted at once.
2. Counta sends it to NRS straight away, so the answer usually says `signed` already, with the IRN and the QR code. That takes a second or two; when NRS is slow it can take up to a minute, so give the call 90 seconds. When NRS does not answer, the invoice is `waiting` and Counta tries again on its own.
3. A signed invoice to a business or government goes on to the buyer's access point through NRS, and NRS's notifications say when it is delivered.
4. In the books, a payment is booked to a holding account named after the partner ("Shopwise POS balance"), the way Paystack payments are, and matched to the bank in Banking when the money lands. On an invoice that waits for NRS, the payment is booked once it is signed. NRS is told when an invoice is paid in full.
5. Invoices through Prism never count against the merchant's Counta plan: Prism charges partners in credits.

The answer:

```json
{ "ok": true, "duplicate": false, "resubmitted": false,
  "invoice": { "id": "…", "ref": "SW-2026-000981", "partner_id": "ptn_42", "books": false, "type": "invoice", "counta_org_id": "…", "sale_id": null,
    "number": "SW2026000981", "issue_date": "2026-11-14", "due_date": "2026-11-28", "currency": "NGN", "subtotal": 372000, "vat": 27900, "total": 399900,
    "paid": true, "payment_waiting": false, "kind": "clear", "state": "signed", "irn": "SW2026000981-94ND90NR-20261114", "qr": "…",
    "signed_at": "2026-11-14T09:31:07Z", "note": "Signed by NRS.", "tries": 1, "next_try_at": null, "nrs_knows_paid": true,
    "buyer": { "state": "transmitting", "note": null, "at": "2026-11-14T09:31:08Z" }, "created_at": "…", "updated_at": "…" } }
```

`state`:

| state | |
| --- | --- |
| `waiting` | Counta is still to send it, or NRS did not answer and Counta tries again (`next_try_at`, with NRS's words in `note`). |
| `sending` | NRS is checking it now. |
| `signed` | NRS signed it. `irn` and `qr` are final. |
| `refused` | NRS will not take it as it is. `note` has NRS's reason. Send it again, corrected, under the same `ref`. |
| `stopped` | It will not go: a credit note whose invoice NRS never signed, or a sale the merchant voided before NRS signed it. |

`buyer.state`, once a signed invoice to a business or government is on its way: `due` and `sending` (Counta is giving it to NRS), `transmitting` (NRS has it), `transmitted` (delivered to the buyer's access point), `acknowledged` (the buyer's access point confirmed it), `failed` (NRS could not deliver it; `note` says why, and the merchant can send it again from Counta). Until TaxStreem is an accredited access point on NRS, signed invoices wait at `due`.

### Sent again

The same invoice under the same `ref` is answered with `duplicate: true` and the invoice as it is now; nothing is sent twice. An invoice NRS refused can be sent again under its `ref` with what NRS asked for put right: the answer has `resubmitted: true`, and it goes to NRS again. In the books this works while the invoice is still a draft (an invoice to a business, which waits for NRS). A corrected invoice keeps its `books` and `type`.

## Where an invoice stands

```
POST /prism/einvoice-status   { "org_id": "biz_900", "partner_id": "ptn_42", "ref": "SW-2026-000981" }
→ { "ok": true, "invoice": { … } }
```

## A payment reported later

```
POST /prism/einvoice-paid
{ "org_id": "biz_900", "partner_id": "ptn_42", "ref": "SW-2026-000981",
  "paid": { "amount": 399900, "method": "transfer", "reference": "TRF-7781", "paid_at": "2026-11-20T14:05:00+01:00" } }
→ { "ok": true, "invoice": { … } }
```

`amount` defaults to what is still owed. In the books the payment is booked to the partner's holding account, at most what is still owed; an invoice still waiting for NRS takes it once signed. E-invoicing only, a payment of the whole total marks the invoice paid. Once an invoice is paid in full and signed, NRS is told at once.

## Callbacks

Counta tells Prism each change, at the address set in the admin portal as `PRISM_CALLBACK_URL` (under TaxStreem; an https address), signed the same way Prism signs its calls:

```
POST <PRISM_CALLBACK_URL>
x-counta-signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<raw body>" with TAXSTREEM_SSO_SECRET>
x-counta-event: einvoice.updated
x-counta-delivery: <the callback's id>

{ "event": "einvoice.updated", "id": "<the callback's id>", "change": "signed", "at": "2026-11-14T09:31:07Z",
  "org_id": "biz_900", "partner_id": "ptn_42", "ref": "SW-2026-000981", "invoice": { … } }
```

`change` is one of `signed`, `refused`, `stopped`, `buyer_transmitted`, `buyer_acknowledged`, `buyer_failed` and `paid_reported` (NRS was told it is paid). `invoice` is the invoice as it is when the callback is sent, so a late callback still carries the latest state: take `invoice` as the truth and `change` as the reason it came.

Prism answers with any 2xx. Anything else, or no answer within 15 seconds, is tried again after a minute, 5 minutes, 15 minutes, 30 minutes, an hour and then every 3 hours, 12 times in all (about a day), and then given up. Until `PRISM_CALLBACK_URL` is set, callbacks wait and are tried hourly without counting. The same callback can arrive twice; `id` tells them apart.

The admin portal's Keys page shows the address Prism sends invoices to, how many merchants and invoices there are, and how the callbacks are going, with the last problem.

## Copies: UBL (PINT NG) and the seal

`POST /prism/einvoice-ubl` with `{ org_id, partner_id, ref }` answers the invoice as a file: UBL 2.1 in OpenPeppol's PINT NG Billing 1.0.0 (`ubl.ts`), or 422 with `missing` when the invoice is to a consumer or lacks something PINT NG needs. `POST /prism/einvoice-signed-copy` answers TaxStreem's JAdES seal (`jades.ts`): `{ ok, seal: { format, irn, sealed_at, jws } }`, or 409 until it exists. `GET /einvoice/certificate` (no authentication) answers the seal's certificate as PEM with `x-certificate-sha256`. The public reference for partners, with a Node.js check of a seal, is at counta-taxstreem.netlify.app/developers. [e-invoicing.md](e-invoicing.md) has how the seal and the UBL copy are made.

## What the merchant sees

The merchant's owner sees e-invoices outside the books in Counta, under Settings, E-invoicing: the list (filtered by what needs a person, waiting or signed, and searched by number, customer or ref), each one with its stamp (QR code and IRN), lines, totals and where it stands with NRS and the buyer. One NRS could not deliver can be sent to the buyer again from there. Notifications of a refusal or a failed delivery open it. Invoices in the books are sales: they show in Sales with "Shopwise POS through Prism · ref" in their notes.

## Tables and functions

| | |
| --- | --- |
| `prism_einvoices` | Each partner invoice: the partner, its `ref`, books or not, and the sale or document it became. A payment that waits for NRS's signature. |
| `einvoice_only` | Invoices kept outside the books: the invoice as the partner sent it, worked out the way Counta works out a sale. |
| `einvoice_docs` | As for sales, with `source` `sale` or `only`. |
| `prism_callbacks` | Each change to tell Prism, with its tries. |
| `svc_prism_merchant`, `svc_prism_enable` | The merchant, and switching e-invoicing on. |
| `svc_prism_einvoice`, `svc_prism_einvoice_status`, `svc_prism_einvoice_paid` | Invoices, their status and payments. |
| `svc_prism_callback_claim`, `svc_prism_callback_done` | The callbacks. |
| `einvoice_only_list`, `einvoice_only_get` | What the merchant sees. |
| `svc_prism_doc` | The document behind a partner's `ref`, for its copies. |
| `api_clients`, `api_tokens` | OAuth 2.0 clients (SHA-256 of the secret) and their tokens (SHA-256, an hour each). `svc_api_token_issue`, `svc_api_token_check`; `admin_api_clients`, `admin_api_client_create`, `admin_api_client_revoke` for the Keys page. Migration `20261115000100_security_signing.sql`. |

The `svc_` functions are for the einvoice function alone (service role). The migration is `20261114000100_prism_einvoice.sql`.

## Not yet

- Credit notes for merchants whose books are in Counta. They are raised in Counta, from the sale.
- Invoices in other currencies.
- Invoices NRS brings for a merchant (received from its suppliers) are not passed to Prism yet; the merchant sees them in Counta as draft bills.
