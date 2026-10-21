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

Once TaxStreem's own OpenWA server is connected, WhatsApp goes through it; see [whatsapp-openwa.md](whatsapp-openwa.md) for setting it up, Martina on WhatsApp and Siri, and businesses' own numbers. The official Cloud API below stays as the fallback (`WHATSAPP_PROVIDER = meta`).

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

Messages to customers and suppliers start outside the 24-hour window, so each one uses an approved template. Submit these six in the Utility category, language English (and the three alert templates below). The variables are filled in this order.

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

**counta_bill_returned** (4 variables), to a supplier whose invoice is sent back unpaid

```
Hello {{1}}, {{2}} has returned your invoice {{3}} without paying it: {{4}}.
Sent with Counta.
```

Example: Bisi, Bright Pharmacy Ltd, BCS-118, your Tax ID is missing. You can get it at taxid.nrs.gov.ng; please send it to us with an invoice that shows it

**counta_invoice_issues** (4 variables), to a supplier whose invoice came in with problems (from the invoice portal or uploaded by the business)

```
Hello {{1}}, {{2}} has received your invoice {{3}}. Please check: {{4}}
Sent with Counta.
```

Example: Bisi, Bright Pharmacy Ltd, BCS-118, VAT should be ₦7,500.00 (7.5% of ₦100,000.00), but the invoice shows ₦10,000.00. The invoice has no bank account for payment.

### Alerts to the business's owner

Counta also writes to the owner of each business when something needs doing: a tax return due, invoices due or overdue, and
transactions to confirm before the month's returns. These go from Counta (no reply-to), only to the owner, at most once per
alert and channel. TaxStreem sets when they go in the admin portal (Alerts and tax wallets); each business can stop email,
WhatsApp and calls to itself in Settings, Alerts. Sample businesses are never messaged. Submit these three as well, in the
Utility category, language English.

**counta_tax_deadline** (6 variables)

```
Hello {{1}}, {{2}}'s {{3}} for {{4}} is due on {{5}}. Amount: {{6}}. Open Counta to check it and file on time.
Sent by Counta.
```

Example: Ada, Bright Pharmacy Ltd, vat return, September 2026, 21 Oct 2026, ₦184,250.00

**counta_invoices_due** (5 variables)

```
Hello {{1}}, {{2}} has {{3}} invoices due or overdue, {{4}} in all. The oldest is {{5}}. Open Counta to send reminders or statements.
Sent by Counta.
```

Example: Ada, Bright Pharmacy Ltd, 4, ₦1,240,000.00, INV-0031

**counta_confirm_items** (5 variables)

```
Hello {{1}}, {{2}} has {{3}} transactions from {{4}} to confirm before the VAT and WHT returns due on {{5}}. Open the books inbox in Counta to confirm them.
Sent by Counta.
```

Example: Ada, Bright Pharmacy Ltd, 12, September 2026, 21 Oct

Which channel each alert uses, cheapest first: the red number in the menu and a push notification are free and cover
everything; email (a fraction of a kobo) carries the important ones; WhatsApp (a paid utility conversation) the same, a
little less often; and a call from Martina (the dearest) only the day before a tax return is due, plus, when a business
turns it on, a polite follow-up of a customer's invoice that is at least a week overdue after a reminder went unanswered.

Meta refuses templates that begin or end with a variable, which is why each one ends with a short line of plain text. If Meta asks for changes, keep the number and order of the variables; the wording around them can change without touching Counta.

## Testing

The edge test harness sends every template through mock Resend and Graph servers and checks the sender, reply-to, idempotency key, template name, language and variables, the webhook signature check and the status updates.
