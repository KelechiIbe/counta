# Audits

A company above the small company limits has its financial statements audited before they are filed. Counta tells it so,
lets it choose a TaxStreem partner firm that audits companies of its size, and takes the payment through Flutterwave with
TaxStreem's referral fee split off. Migration `20261130000100_audit_firms.sql`; edge function `audits`.

## Who needs an audit

`private.audit_need(org, year)` uses the year's CIT figures (`private.cit_compute`): turnover above the small company limit,
or fixed assets above theirs. The limits are the tax rules TaxStreem keeps in the admin portal (`small_company_turnover`,
₦100 million; `small_company_fixed_assets`, ₦250 million), for every year. Only a company is asked: a business name or
partnership files a statement of accounts. A company providing professional services is tested on its size like any other.

The Filing page (a paid CIT year) and the CIT tab show the year's audit panel. Every morning at 06:35 UTC
`private.audit_tick` tells a company once for each year (the one running and the one before) that crosses a limit, unless the
year already has an auditor or a request, or its return is filed (`audit_notices`). A company whose details say it is exempt
from audit is told that no longer holds.

## Which firms are offered

A firm appears once every step in `private.audit_ready` is done and a partner has switched audits on (Audits, in the
accountant portal):

1. A partner with an ICAN or ANAN number and an FRC number, both verified by TaxStreem (Accountants in the admin portal). The
   FRC number is asked for when a practice is set up and under Practice; the sign-up page says what offering audits needs.
2. A payout bank account in the firm's or a partner's name, confirmed with the bank (Earnings).
3. The firm's Tax ID and state, for the withholding tax clients deduct.
4. A price for at least one turnover band. TaxStreem sets the bands in the admin portal (the upper end of each; the last band is
   everything above). A firm leaves blank the bands it does not take.
5. Flutterwave set up: the `audits` function makes a collection subaccount on that bank account (`POST /subaccounts`), or moves
   it when the payout account changes (`PUT /subaccounts/:id`). Its reference is kept on `practice_audit_offers`.

The business sees each firm with its price for the business's band, VAT added when the firm charges it, and its signing
partners with their FRC numbers. A firm that keeps the business's books is shown with a warning about independence.

## Asking, answering, paying

The owner or an admin asks one firm (`audit_request`); one live request or audit a year (`audit_engagements`). Partners and
managers accept or decline in the portal, within the days TaxStreem sets (7); an unanswered request lapses. The business can
withdraw before paying, or name an auditor of its own (`audit_own`).

Once accepted, the business pays (`audits` function, `pay`). `audit_pay_start` enters the bill from the firm in the business's
books as a draft (audit fees, 6501, VAT when the firm charges it, WHT for professional services by the firm's form) and records
the checkout (`audit_charges`): the fee and VAT less the withholding tax. Flutterwave's checkout splits it: TaxStreem takes its
referral fee as a flat amount (`transaction_charge_type: flat`), and the firm's subaccount gets the rest, less Flutterwave's
charge. The referral fee is a share of the fee before VAT (10%), set in the admin portal and fixed when the business asks.

Counta asks Flutterwave for the transaction by its reference (on the way back from the checkout, and every five minutes while
one is open; one not paid within a day is given up). When it is paid, `svc_audit_charge_update` approves the bill (when its
month is open; else it stays a draft and the audit says why), marks the audit paid and tells both sides. The card payment's bank
line pays the bill later, as usual, with the WHT the business owes. A second payment, or one after the request was withdrawn and
another firm chosen, is kept and marked for TaxStreem to refund (Audits, in the admin portal).

## Secrets

`FLW_SECRET_KEY` and `APP_URL`, as for the payments function. Flutterwave takes subaccount calls only from TaxStreem's
whitelisted address, so the audits function sends them through the transfer relay when `FLW_RELAY_URL` and
`FLW_RELAY_SECRET` are set (`docs/transfer-relay.md`; the relay forwards them from version 2). A relay not yet updated, or
one that cannot be reached, sent nothing, so the call then goes straight to Flutterwave, and the firm sees "update the
relay" if Flutterwave refuses it. Checkouts and payment checks are not restricted and go straight to Flutterwave.

## Still to come

The auditor's workspace (the pack in Word, Excel or PDF, revised files and the summary of changes), signing with uploaded
signature images, inviting an auditor who is not on Counta, and holding the return's approval until the audit is signed.
