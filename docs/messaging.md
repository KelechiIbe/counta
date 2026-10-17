# Customer messages: email and WhatsApp

Counta sends invoices, receipts, orders, statements and payment reminders by email through Resend and by WhatsApp through the WhatsApp Business Cloud API. Every message carries a link to the document page, where the customer can pay by transfer, link or QR. TaxStreem holds one Resend account and one verified WhatsApp Business number for all businesses on Counta.

## How a message goes out

1. Someone presses Send on a document, or the nightly reminder job finds an invoice due on one of the business's reminder days (Settings, Customer messages).
2. The database queues the message in `messages` and asks the `messaging` function to deliver it.
3. The function sends it and records the provider's id. Delivery and read receipts from WhatsApp update the row.
4. A message that fails for a passing reason is tried again after ten minutes, up to three tries in all. A message queued while a channel has no keys waits without using up its tries and goes out once the keys are set, as long as that happens within three days.

## Email (Resend)

| Secret | Value |
| --- | --- |
| `RESEND_API_KEY` | API key from the Resend dashboard |
| `RESEND_FROM` | An address on a domain verified in Resend: `billing@counta.ng` or `Counta <billing@counta.ng>` |

Counta reads the email address out of `RESEND_FROM` whatever surrounds it (quotes, a display name, spaces) and sends each email from `<Business name> via Counta <that address>`, with the business's own email (or the reply-to address set in Settings) as Reply-To, so customers' replies reach the business. A customer's extra addresses (up to five) receive a copy. Resend's `Idempotency-Key` is `counta-<message id>`, so a retry never sends twice. The email has a plain-text part as well as HTML, and carries the business's logo, brand colour, address, Tax ID and website.

Settings, Customer messages shows whether email is on and the address it sends from, and the reason the last message failed.

### When emails do not arrive

1. Settings, Customer messages: if it says the sending address has no email address in it, fix `RESEND_FROM`.
2. The domain in `RESEND_FROM` must be verified in Resend (Domains). Resend refuses mail from any other domain, and from `onboarding@resend.dev` to anyone but the account owner.
3. The failed message's reason is shown under Latest. Messages that failed for a passing reason are tried again on their own.

## WhatsApp

| Secret | Value |
| --- | --- |
| `WHATSAPP_TOKEN` | A permanent system-user access token with `whatsapp_business_messaging` |
| `WHATSAPP_PHONE_NUMBER_ID` | The phone number id (not the phone number) |
| `WHATSAPP_BUSINESS_ACCOUNT_ID` | The WhatsApp Business Account id |
| `WHATSAPP_APP_SECRET` | The Meta app secret, to check webhook signatures |
| `WHATSAPP_VERIFY_TOKEN` | Any long random string; enter the same value in Meta's webhook settings |
| `WHATSAPP_TEMPLATE_LANG` | Optional, default `en` |

Webhook in the Meta app (WhatsApp, Configuration): callback URL `https://krtqqhndmncarwusukrw.supabase.co/functions/v1/messaging/whatsapp`, verify token as above, subscribe to `messages`.

### Templates to submit to Meta

Messages to customers start outside the 24-hour window, so each one uses an approved template. Submit these five in the Utility category, language English. The variables are filled in this order.

**counta_document** (5 variables)

```
Hello {{1}}, {{2}} has sent you {{3}} for {{4}}. You can view it and pay here: {{5}}
Sent with Counta.
```

Example: Ada, Bright Pharmacy Ltd, invoice INV-0042, ₦51,626.88, https://counta-taxstreem.netlify.app/p/…

**counta_receipt** (5 variables)

```
Hello {{1}}, thank you for buying from {{2}}. Your receipt {{3}} for {{4}} is here: {{5}}
Sent with Counta.
```

**counta_order** (5 variables)

```
Hello {{1}}, {{2}} has your order {{3}} for {{4}}. You can follow it and pay here: {{5}}
Sent with Counta.
```

**counta_payment_reminder** (6 variables)

```
Hello {{1}}, a reminder from {{2}}: {{3}} on {{4}} {{5}}. You can pay by bank transfer here: {{6}}
Sent with Counta.
```

Example: Ada, Bright Pharmacy Ltd, ₦12,500.00, INV-0042, was due on 31 Oct 2026, https://…

**counta_statement** (4 variables)

```
Hello {{1}}, your balance with {{2}} is {{3}}. You can see your statement and pay here: {{4}}
Sent with Counta.
```

Meta refuses templates that begin or end with a variable, which is why each one ends with a short line of plain text. If Meta asks for changes, keep the number and order of the variables; the wording around them can change without touching Counta.

## Testing

The edge test harness sends every template through mock Resend and Graph servers and checks the sender, reply-to, idempotency key, template name, language and variables, the webhook signature check and the status updates.
