# Plans, subscriptions and the cost of service

TaxStreem sets Counta's plans in the admin portal (Plans), sees who pays for what (Subscriptions), and sees what running Counta costs it, business by business (Cost of service). Businesses see their plan, what they have used this month, and pay for a plan under Settings, Subscription.

## Modules

A plan is made of modules. A module is either a feature a business has or not, or a quota that counts something:

| Kind | Modules |
| --- | --- |
| Feature | Payments, Bulk payments, Martina, Phone calls, Spoken announcements, AI reading, WhatsApp to customers, Email to customers, Bank feeds, Supplier invoice portal |
| Quota each month | Sales (receipts and invoices), AI reads (invoices, statements, photos, documents), questions to Martina, phone call minutes, WhatsApp messages, emails, Tax ID checks, supplier invoices, payouts |
| Quota at any time | Team members, branches, linked bank accounts |

Admins add modules (Plans, New module): a feature switches one of Counta's switches; a quota counts one of the meters above. A module can carry a cost per unit set by hand; otherwise its cost comes from the rates (below). A new module's key, like a new plan's code, is made from its name (Extra reports becomes extra_reports, 35k Premium becomes plan-35k-premium) and can be typed over; a key or code already in use is refused before Save, and so is any field the database would turn away, with the reason shown beside the Save button.

## Plans and entitlements

For every module a plan says whether it is included, the limit (empty for no limit) and what happens past it: stop, or warn. A module a plan does not mention is included with no limit, so adding a module never takes anything away by itself. Prices include VAT; the yearly price defaults to twelve months. A plan can have a free trial, can be hidden from businesses, and one plan is the default: every business without a subscription is on it.

The migration adds one plan, Standard: free, the default, everything included, no limits. Nothing a business does today stops until an admin sets plans up.

An admin can put one business on any plan without a charge (complimentary, for a number of months) and can override a single module for one business, for a while or until removed (Businesses, a business, Plan).

How limits act:

- A feature not included is off for the business, unless the plan says to leave it on. A switch an admin sets for one business wins over everything; then the platform switch; then the plan.
- A quota that stops refuses the next use with a plain reason, for example "Your plan (Growth) includes 2,000 sales a month, and this month's are used up. The owner can move to a bigger plan in Settings, Subscription." A message over its limit is kept and marked failed with that reason, so whatever queued it carries on.
- A quota that warns lets the use through. The people who manage the business are told at 80% and when it goes over, once a month for each.
- AI quotas are checked by the edge functions before Gemini is asked, so a refused question costs nothing.
- Sample businesses are never limited.

Months are Lagos months.

## Subscriptions

Settings, Subscription shows the plan, its price and renewal date, how it is paid, this month's use of each quota and the plans the business can move to. The owner (or anyone who manages settings) chooses a plan, monthly or yearly, paid by card or from the business wallet.

- A dearer plan starts at once, for a full month or year. A cheaper one starts when the current period ends. A free plan starts at once.
- A plan with a trial starts the trial with no payment; the first payment is taken when it ends, the way chosen.
- Stop renewing lets the plan run to the end of the period, then the business moves to the default plan. Keep the plan undoes it.

By card: the first payment goes through Flutterwave's checkout (card only), which returns to the Subscription page; Counta asks Flutterwave about the payment before saying it is paid, and the webhook does the same. Flutterwave keeps the card; Counta stores the token it gives back, never shown to the browser, and charges it for renewals (`/v3/tokenized-charges`). The owner can remove the card or switch renewals to the wallet.

From the wallet: Counta moves the price from the business wallet to TaxStreem's Flutterwave account (a Flutterwave-to-Flutterwave transfer to `FLW_MERCHANT_ID`, through the relay). The transfer webhook or the five-minute poll confirms it, and the business's books record it: Dr 6303 Software Subscriptions & Maintenance (without VAT, or the whole price when the business is not VAT-registered), Dr input VAT, Cr the wallet. Until `FLW_MERCHANT_ID` is set in the admin portal, a wallet payment fails with "pay by card".

Renewals run in the payments function's poll. A renewal that fails puts the subscription past due: Counta tries again each day, and after three days unpaid the business moves to the default plan. Each charge has a reference `SUB-` followed by 16 hexadecimal characters.

The admin portal's Subscriptions page shows monthly recurring revenue, how many businesses pay, are on a trial, are past due or will not renew, what was collected this month, and every business with its plan and last payment.

## Cost of service

The Cost of service page prices what each business used in a month from Counta's own records:

| Service | Measured from |
| --- | --- |
| Google Gemini | Input and output tokens and Google Search queries of every AI call (`usage_events`) |
| ElevenLabs | Characters spoken (announcements) and agent minutes (phone calls and the voice guide) |
| Twilio | Phone call minutes, rounded up per call |
| WhatsApp (Meta) | Utility messages sent |
| Resend | Emails sent |
| Mono | Linked bank accounts each month, and every lookup (Tax ID, NIN, CAC) |
| Flutterwave | Card fees on plan payments (TaxStreem pays these); fees on collections and payouts (the business pays these, shown apart) |
| Supabase | File storage, by business folder |

Rates start from the providers' published prices, each marked "to check" until someone checks it against the bill or agreement and ticks it. A rate applies from its date, so a price change is a new rate. Mono's prices are not published, so its rates start at zero until TaxStreem enters the ones in its agreement. Dollar prices are turned into naira at the rate for the month's last day (or today, for the current month), from the Currency page.

Fixed monthly bills (Supabase, Netlify, the relay server, the Twilio number, the ElevenLabs plan) start empty for TaxStreem to enter, and are shared equally across the month's businesses.

The page shows TaxStreem's cost against plan revenue (without VAT), by plan and by business, with the biggest costs of each.

## Pricing a plan

The plan editor has a calculator. It takes the price without VAT, keeps back the target margin and the business's share of the fixed bills, and shows what is left for services. For each quota it shows one unit's cost (from the rates and the last 30 days of use), the average business's use, a suggested limit (the budget split the way the average business's costs are made up) and the cost at the limit. It then gives the margin if every limit is used and at average use. When a module that costs money has no limit, the margin at full use cannot be known and the calculator says so instead of giving a figure.
