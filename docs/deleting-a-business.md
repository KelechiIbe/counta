# Deleting a business

TaxStreem's admins can delete a business for good from the admin portal: **Businesses**, open the business, **Delete this
business** at the bottom of the page. Reviewers cannot.

## What goes

- The business and every record in it: sales, invoices, receipts, bills, customers, suppliers, products and stock, the
  books, tax returns, payments, team, settings, its subscription, and its onboarding and identity checks.
- Its files in storage (documents, uploads, photos, the logo).
- The keys of the tools it connected (kept in Vault).
- Its bank feeds: Mono is told to stop reading the bank.
- A WhatsApp number it linked on TaxStreem's OpenWA server: logged out and removed.
- The **logins of the people who are in no other business**, so the same email can sign up again from the start.
- The sample business of each of those people.

## Who keeps their login

- Anyone who is also in another business (the preview names it).
- Anyone in an accountant practice.
- TaxStreem's admins and reviewers.

They simply stop being in the deleted business. An owner who keeps their login is asked to set up a business at their next
sign-in.

## What stops it

- Money in any of its wallets or its tax wallet: the books' balance, or the last balance the bank reported. Move the money
  out first. The account numbers at Flutterwave cannot be closed from Counta; they stay with Flutterwave, unused.
- Money on its way: a payout or bulk payment being sent, money moving between the wallets, a tax payment being made, or a
  subscription payment.
- A sample business on its own. It goes when its owner's business is deleted.

## How it works

1. The preview (`admin_business_delete_preview`) lists what goes, whose login is removed or kept and why, and anything that
   stops it.
2. The admin types the business's name. `admin_business_delete` checks the name and the blockers again and removes every
   record in one transaction. That includes rows in tables that would otherwise keep them with no business (identity
   checks, the guide, usage, sign-ins from TaxStreem, payment events).
3. The admin server function (`supabase/functions/admin`, action `delete_business`) then removes the files, the logins (only
   of people still in no business), the Mono feeds and the WhatsApp numbers. It emails every admin.
4. The admin log (**Admin team**) keeps one line: who deleted which business, when, and the counts. No list of people or
   ids stays once the deletion is finished.

If a part could not finish (Mono or OpenWA did not answer, for example), the business is already gone and **Businesses**
shows the deletion with **Try again** (action `delete_business_finish`). Each part is safe to run again.

Migration: `20261102000100_business_delete.sql`.
