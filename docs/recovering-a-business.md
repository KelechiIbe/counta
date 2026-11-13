# One company, one business: recovering a business someone else set up

A company is on Counta once. Its registration number (RC, BN or IT, compared within its registry) or its Tax ID can belong to one business only, whoever set it up: an owner, an accountant, or a firm running it under full mandate. Sample businesses and businesses kept read-only after a mandate ended do not count. The migrations are `20261125000100_director_identity.sql` and `20261125000200_account_recovery.sql`.

## Setting up a company already on Counta

When someone setting up a business picks a company on CAC that is already on Counta, the onboarding says so at once, with the address of the account that holds it masked (`k******@g****.com`), and the business profile cannot be submitted (`kyc_submit` answers `exists`). If it is their own business already, they are sent to it. A trigger on `orgs` (`orgs_reg_unique`) refuses a second business with the same number or Tax ID, whichever function writes it.

A director on the company's CAC record can **recover** it instead.

## The recovery

1. **The director proves who they are** (`/recover`, then `/recover/<id>`). Their NIN is looked up with NIMC (the `mono` function's `recovery_nin`, three a day per recovery, within their daily NIN lookups) and must match, by name, a director on the company's CAC record (or a proprietor of a business name). The recovery uses the CAC record of the company's registration number; one found by its Tax ID alone goes to support.
2. **A 6-digit code** goes to the phone number NIMC holds for the NIN (SMS through Termii) and to the director's email on the CAC record. It never goes to an address or a phone of the business's own people, or of the firm that runs it: someone already in the business is no proof. Counta keeps the name matched and the NIN's last four digits; where the code went is wiped once it is right, or within the hour. (A director confirming a firm's wallets is the one exception: see [Approvals and exempt buyers](approvals-and-exempt-buyers.md).)
3. **The holder has 30 minutes.** Once the code is right, the holder is told by email and in the app: the owners, or for a business a firm runs, its engagement partner and the firm (the firm's leads see it on the client's Full mandate tab). The owner sees a banner on every screen and answers in Settings. **No money leaves the business's wallets** until the recovery is settled (`private.payments_open`, `private.require_payments_open`).
4. **The holder hands it over or says no.** Handed over (`recovery_handover_start`), the director gets an email with a link (7 days). Signed in with the login that asked, they take the business (`recovery_accept`): they become its owner, the previous owners' places end, a firm's places end with its mandate, and the business's identity stands verified by the recovery. The previous owners are emailed. The director's own login is unchanged. Saying no takes a reason (`recovery_dispute`): TaxStreem decides, and payments stay paused meanwhile.
5. **TaxStreem's support.** The director can ask support from the page while they cannot get the code (no longer having the NIN's phone or the CAC email), once the holder's 30 minutes have passed, or once the holder said no (`support_request`, three a day). The request reaches the admin portal and the support address (`SUPPORT_EMAIL`), with replies going to the director.

**TaxStreem checks first** when NIMC holds no phone for the NIN or SMS is not set up (the code then goes to the director's CAC email and phone), and when another director's recovery of the same business is open. The holder is told only once TaxStreem approves.

## TaxStreem's side

The admin portal's **Recoveries and support** page (admins and reviewers) lists the open recoveries with whom the NIN matched, the NIN's last four digits, where the code went (masked) and the holder's addresses, and the open support requests. Reviewers approve or reject a recovery waiting for a check; admins can also hand a business over themselves when the holder has not answered or a dispute is decided for the director. Every decision takes a note and goes in the audit log, and the director is told.

## Tables

| Table | What |
| --- | --- |
| `identity_checks` | A NIN matched to the CAC record and the code sent for it (also a director's confirmation of a firm's wallets) |
| `account_recoveries` | A director's recovery of a business: where it stands, whom the NIN matched, the holder's 30 minutes, the handover link (its hash) and the previous owners |
| `support_cases` | Support requests from the app |

Nobody reads these tables directly; the functions check who may do what.
