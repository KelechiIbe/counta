# The Counta Partner programme

Accountants earn a share of what the businesses they bring to Counta pay for their plans. The migration is
`supabase/migrations/20261105000100_partner_programme.sql`; payouts go through the `payments` function.

## Who counts

A business counts for a practice when it connects to that practice before it has ever paid for a Counta plan. It can
connect in four ways:

- the practice's own link, `/r/<CODE>`
- the practice's email invitation
- the business inviting its accountant
- the business asking a listed partner from the directory

Only one practice counts for each business: the first one that connects. A business that was already an active client
when the programme started counts for its practice in the same way, if it had never paid.

These do not count:

- a business owned by someone in the practice (`void_reason = 'self'`)
- a business that leaves the practice before its first payment (`void_reason = 'ended'`); it can then count for the next practice it joins
- a business that was already paying when it connected

## What a practice earns

The window starts at the business's first paid plan. For the tier's number of months, each payment earns the tier's rate,
but only while the business stays connected. A yearly payment counts only for the months of it inside the window, so a
first payment for a year, with a 6-month window, earns on half of it.

The tier depends on how many of the practice's referred businesses have paid:

| Tier   | From paying businesses | Rate  | Months |
|--------|-----------------------:|------:|-------:|
| Bronze | 0                      | 15%   | 6      |
| Silver | 10                     | 17.5% | 6      |
| Gold   | 25                     | 20%   | 9      |

A business's months are fixed when it first pays. The rate is the practice's tier when each payment comes in.

Milestone bonuses are paid once each: ₦25,000 at 5 paying businesses, ₦75,000 at 10, and ₦200,000 at 25.

The welcome offer gives a business that connected an accountant before paying 20% off its first payment. On a yearly
payment, it is 20% off one month's price. The commission is worked out on what the business actually paid.

TaxStreem changes every number in the admin portal, under Partners, Settings. A change applies to earnings from then on.

## Getting paid

1. Each amount waits 30 days after the payment it came from.
2. On the 5th of each month, the poll lists one payout per practice. A practice is listed only when all three are true:
   - at least ₦5,000 is ready (smaller amounts carry over)
   - a partner has a licence TaxStreem verified
   - it has a bank account the bank named
3. TaxStreem approves each payout in the admin portal. The portal shows whether the name the bank gave matches the practice or one of its partners, and warns if the account changed after the payout was listed.
4. On approval, `payments` sends the transfer from TaxStreem's own Flutterwave balance (no subaccount), through the relay. The reference is `CNTR-…`.
5. The webhook (`transfer.completed`) or the poll settles the payout. If the bank refuses it, TaxStreem can send it again (on a new reference) or hold it. A held payout's amounts wait for the next listing.

Withholding tax is deducted at the rate set in the admin portal (5% to start). Each paid payout has a WHT note under
Earnings in the accountant portal. The admin portal lists the WHT withheld each month, for remitting.

## Where people see it

| Who | Where | What they see |
|---|---|---|
| The practice | Accountant portal, Earnings | its link (with QR code and WhatsApp message), tier, milestones, businesses and earnings, payouts and WHT notes, bank account, directory listing, and requests from the directory |
| Anyone with the link | `/r/<CODE>` | the practice, its tier and verified licences, and the welcome offer; the code is kept through sign-up |
| A business owner | Home | the offer to connect the practice whose link they followed |
| A business | the plan page | the welcome offer |
| A business | Settings, Your accountant | the partner directory, and the badge of its own accountant |
| TaxStreem | admin portal, Partners | payouts to approve, the practices, and the settings |
