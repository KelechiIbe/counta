# Opening Counta from TaxStreem

People open Counta from their TaxStreem account without a separate password. TaxStreem signs a short-lived token, Counta checks it, makes sure the person and the business exist, and signs the person in. Prism, TaxStreem's payables product, uses the same shared secret to send supplier bills into Counta's books.

## Single sign-on

TaxStreem sends the browser to:

```
https://counta-taxstreem.netlify.app/sso?token=<JWT>
```

The token is a JWT signed with HS256 using `TAXSTREEM_SSO_SECRET` (the same value is set on both sides; at least 32 random bytes).

| Claim | Required | Meaning |
| --- | --- | --- |
| `iss` | yes | `taxstreem` (or the value of `TAXSTREEM_SSO_ISSUER` if set) |
| `aud` | yes | `counta`, or an array that includes it |
| `iat`, `exp` | yes | Seconds since 1970. `exp - iat` at most 600; Counta allows 30 seconds of clock drift |
| `jti` | yes | Unique per token. A token is accepted once; a second use is refused |
| `sub` | yes | TaxStreem user id |
| `email` | yes | The person's email address |
| `email_verified` | yes | Must be `true` |
| `name`, `phone` | no | Used when the person is new |
| `org.id` | yes | TaxStreem business id. Counta links the business to it on first use |
| `org.name`, `org.email`, `org.phone`, `org.tin`, `org.rc_number`, `org.vat_registered` | no | Used when the business is new |
| `org.address`, `org.principal_activity`, `org.incorporation_date` (YYYY-MM-DD), `org.company_secretary` | no | Filled in on the business when Counta does not have them yet; they print on the financial statements |
| `org.directors` | no | The directors collected at onboarding: `[{ "name", "role", "frc_number", "appointed" }]`. Sent on every sign-in; a non-empty list replaces the one Counta holds. The chair and the managing director (or the first two) sign the financial statements |
| `role` | no | `owner`, `admin` (becomes manager), `manager`, `accountant`, `cashier`; anything else becomes staff. Default owner |
| `rail` | no | Payment rail code for a partner integration (see [payment-rails.md](payment-rails.md)) |
| `next` | no | Counta page to open after sign-in, such as `/sell/till`. Must start with a single `/` |

Example payload:

```json
{
  "iss": "taxstreem", "aud": ["counta"], "iat": 1792300000, "exp": 1792300300, "jti": "8f3c…",
  "sub": "usr_123", "email": "ada@brightpharm.ng", "email_verified": true, "name": "Ada Obi",
  "org": { "id": "biz_900", "name": "Bright Pharmacy Ltd", "tin": "11223344-0001", "vat_registered": true,
           "directors": [{ "name": "Ada Obi", "role": "Managing Director", "frc_number": "FRC/2021/IODN/00000012345", "appointed": "2019-03-01" }] },
  "role": "owner", "next": "/sell/till"
}
```

What happens on Counta's side:

1. The `/sso` page posts the token to the `taxstreem` edge function.
2. The function checks the signature, issuer, audience, times, `jti` and `email_verified`.
3. The person is found by email, or created with the email already confirmed.
4. The business is found by `org.id`, or created and owned by the person signing in. Its Tax ID (or old TIN) and RC number come from the token.
5. The person becomes a member with the role's default permissions, unless they already are one. A member the owner has switched off is refused.
6. The function returns a one-time token hash; the page exchanges it for a session and opens `next`.

Errors are shown on the `/sso` page in plain words ("This sign-in link has expired. Open Counta from TaxStreem again."). Nothing about the token is shown.

Signing a token in Node:

```js
import { createHmac, randomUUID } from 'node:crypto';
const b64 = (o) => Buffer.from(typeof o === 'string' ? o : JSON.stringify(o)).toString('base64url');
const now = Math.floor(Date.now() / 1000);
const body = b64({ alg: 'HS256', typ: 'JWT' }) + '.' + b64({ iss: 'taxstreem', aud: ['counta'], iat: now, exp: now + 300, jti: randomUUID(), sub, email, email_verified: true, name, org, role, next: '/home' });
const token = body + '.' + createHmac('sha256', process.env.TAXSTREEM_SSO_SECRET).update(body).digest('base64url');
```

## Prism bills

Prism sends a supplier bill into the books of a business that has opened Counta at least once.

```
POST https://krtqqhndmncarwusukrw.supabase.co/functions/v1/taxstreem/prism/bills
x-taxstreem-signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<raw body>" with TAXSTREEM_SSO_SECRET>
Content-Type: application/json

{
  "org_id": "biz_900",
  "bill": {
    "prism_id": "PRM-2026-000123",
    "vendor": { "name": "Emzor Pharmaceuticals", "tin": "01234567-0001", "is_individual": false, "wht_category": "goods",
                "bank_code": "058", "account_number": "0123456789", "account_name": "EMZOR PHARMACEUTICAL IND LTD" },
    "vendor_ref": "INV-88231", "bill_date": "2026-10-14", "due_date": "2026-11-13",
    "vat_charged": true, "prices_include_vat": false,
    "lines": [ { "description": "Paracetamol 500mg x 1000", "account_code": "5101", "qty": 20, "unit_cost": 18500 } ]
  }
}
```

Counta refuses a signature more than 300 seconds old. The answer is `{ ok, duplicate, bill: { id, number, status, total, wht_expected } }`. Sending the same `prism_id` again returns the first bill with `duplicate: true`. The bill arrives as a draft for someone with Keep the books to check and approve; Counta works out the withholding tax from the supplier's category (`goods`, `services`, `professional`, `rent`, `commission`, `construction_roads`, `construction_other`, `brokerage`, `royalty`, `interest`, `dividend`, `directors_fees`, `entertainment` or `none`).

Status of a bill:

```
POST …/taxstreem/prism/bill-status   { "org_id": "biz_900", "prism_id": "PRM-2026-000123" }
→ { ok, bill: { id, number, status, total, amount_paid, wht_withheld, due_date } }
```

## Secrets

| Name | Where |
| --- | --- |
| `TAXSTREEM_SSO_SECRET` | Supabase Edge Function secret or Vault, and TaxStreem's own configuration |
| `TAXSTREEM_SSO_ISSUER` | Optional, defaults to `taxstreem` |
