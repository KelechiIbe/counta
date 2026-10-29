# The admin portal's team

TaxStreem's admin portal (`/admin`) has two kinds of people. Admins can change everything in the portal. Reviewers see
identity reviews and accountants' licences only. Both must enter a code from an authenticator app each time they open the
portal; the portal sets the app up the first time. The page is Admin team. The migration is
`supabase/migrations/20261106000100_admin_invitations.sql`, and the emails go from the `admin` edge function.

## Adding someone

An admin types the person's email address, chooses Admin or Reviewer, and presses Add (`add_staff` in the `admin`
function, which calls `admin_add_staff` as the admin).

| The address | What happens | The email |
| --- | --- | --- |
| Has a Counta account | They get the role at once | The welcome: who added them, the link to `/admin`, and that the portal will ask them to set up an authenticator |
| Has no Counta account | An invitation waits for the address (one at a time; inviting it again updates the role) | The invitation: who sent it, a link to `/admin/join` that works once, for seven days, and the address to sign up with |
| Already has that role | Nothing changes | None |

Every other admin is emailed when someone is added, invited, or accepts an invitation. The person the alert is about is
left off it, since they get their own email.

If an email does not go (Resend refuses it, or email is not set up under Keys and services), the person keeps the role or
the invitation, and the page says why. An invitation that did not go shows the reason in its row until it is sent again.

## The invitation link

`/admin/join?t=sa_…` shows who sent the invitation and for which role before anyone signs in
(`admin_staff_invite_preview`). Someone new creates their account with the invited address; sign-up brings them back to
the link. To accept (`accept_staff_invite` in the `admin` function, which calls `admin_accept_staff_invite`):

- they must be signed in with the address the invitation went to, and
- that address must be confirmed.

Accepting gives them the role, closes the invitation, and sends them to the portal, which asks them to set up their
authenticator. The link works once. Only the link's SHA-256 is kept, and sending the invitation again makes a new link, so
an older email's link stops working.

A link says so when it is used, expired, withdrawn, or replaced by a newer one.

## Waiting invitations

Each waiting invitation is listed with who sent it, until when its link works, and any email error.

- **Resend** sends a fresh link (at most five a day for one invitation).
- **Withdraw** closes it; its link then says it was withdrawn. The address can be invited again later.

Someone on the team who has not set up their authenticator shows when the welcome went, and **Email again** sends it again
(once a minute at most).

## Records

Every add, invitation, resend, withdrawal, acceptance and welcome sent again is written to the record of changes on the same
page (`admin_audit`). The invitations are kept in `admin_invites`, which the app cannot read directly; the page reads them
through `admin_staff`.

## People added before 6 November

People added before these emails existed were never told. The hand-over file asks the `admin` function once
(`welcome_pending`, with the database's hook secret) to send the welcome to everyone on the team who has neither had it
nor set up an authenticator. `welcomed_at` on `platform_admins` and `platform_reviewers` records it, so nobody gets it
twice.
