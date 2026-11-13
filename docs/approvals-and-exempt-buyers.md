# Approvals and exempt buyers

Release 2 of the identity and compliance work (`20261126000100_approvals_and_relief.sql`). Some things a person does in a business wait for someone else to approve them before they go into the books or leave the wallet, and a sale to a diplomatic mission, a free trade zone entity or a humanitarian project can be exempt from VAT.

## What waits, and for whom

The database decides (`private.approval_route`), whatever screen, chat or voice command asked:

| Who asks | What | Who approves |
| --- | --- | --- |
| The firm that keeps the books, under **full mandate** | An invoice, a credit note or return, a refund, a payment out of the wallet (one payout, a bill paid from the wallet, a bulk payment), a recurring invoice (once) | The director who confirmed the wallets, by a link and a code |
| The firm, for a client who is **involved** | The same | The owner or an admin, in the app |
| Anyone but the owner or an admin | A credit note or return | The owner or an admin |
| Anyone but the owner or an admin | An invoice whose discounts come to more than the business's limit (10% unless the owner changes it, in Settings, Books and tax) | The owner or an admin |
| Anyone but the owner or an admin | An invoice they marked exempt from VAT themselves (not the customer's own exemption) | The owner or an admin |

A request is tried first and rolled back, so one that could not go through (more than can be credited, not enough in the wallet) is refused at once with the reason, and nothing waits. Approved, it is carried out as the person who asked, with their permissions at that moment; if it can no longer go through (someone credited the invoice meanwhile, the invoice changed), it is kept as "approved, not carried out" with why, and they are told. Rejecting takes a reason, which the person who asked sees. An invoice changed after it was sent for approval is withdrawn from the approver; issuing it again asks again. Counta's own runs (a recurring schedule already approved, an integration) never wait.

A payment waiting for approval keeps its place in the wallet (`payouts.status = 'pending_approval'`). Approved, it is ready to send from Payments; rejected or cancelled, it is cancelled. A recurring schedule the firm sets up or changes waits once (`recurring_invoices.approval_state`); rejected, it is paused and cannot be resumed or run until it is changed and approved. Tax payments from the tax wallet to TaxStreem's listed tax accounts do not wait: their amounts come from the filed returns.

## The director's approvals

Under full mandate the director who confirmed the wallets by code approves what the firm asks for. When they confirmed, Counta kept where their code went (`practice_director_confirmations.approver_email` and `approver_phone`) for this, instead of wiping it after the hour. It is wiped when the mandate ends or is handed over, and when another director confirms. A confirmation TaxStreem accepted on a NIN slip leaves nothing to reach the director by: the Full mandate tab says so and lets the firm ask a director to confirm by code, and until one does, nothing the firm asks for can go through.

1. **The link.** As requests come in, the director gets an email in the firm's name with what waits and a link to `/approve` (7 days), and an SMS saying the link is in their email (or carrying it, when there is no email). One email covers whatever comes in within ten minutes; the firm can send the link again from Approvals.
2. **The code.** On the page the director asks for a 6-digit code to their phone (SMS through Termii) and email, five a day. A right code lets them approve or reject for 15 minutes; fifteen wrong codes lock the link.
3. **The decision.** They approve or reject what they choose; rejecting takes a reason. Each approval records the director's name, the time, their IP address and browser.

A link stops working when the mandate ends or another director confirms for the business.

## Exempt buyers

Goods and services supplied to a diplomatic mission or diplomat, an approved entity in an export processing or free trade zone, or a humanitarian donor-funded project are exempt from VAT. In Counta:

- **A customer's own exemption.** The owner or an admin marks a customer exempt, with its reference (the accreditation or note verbale, the zone licence, the project reference): `customers.vat_relief`, `vat_relief_ref`. Every sale to that customer is exempt.
- **One document.** Anyone who records sales can mark an invoice, quote or order exempt, with the reference (`set_sale_vat_relief`). An invoice someone other than the owner or an admin marked waits for their approval when it is issued.

Every line of an exempt document is exempt (VAT status 1) and carries the description the NRS VAT return uses for that exemption (`sale_lines.nrs_vat_label`); each line keeps its own treatment in `item_vat_treatment`, so taking the exemption off restores it. A credit note on an exempt invoice is exempt the same way. An export stays zero-rated and cannot also be exempt. The customer's copy says who the supply is to and the reference.

## Where it shows

- **Approvals** (in the menu): what waits for this person, what they asked for, and what was decided in the last 30 days. The owner and admins approve or reject here; the firm sees which director approves and can send the link again. The menu's count is what waits for this person.
- **Sales**: a document waiting says for whom and why, and the owner or an admin can approve it there. The invoice editor ticks a customer's own exemption, warns when discounts pass the limit, and says when the firm's invoices wait for the client.
- **Payments**, **bulk payments** and **recurring invoices** say what waits for whom.
- The accountant portal's **Full mandate** tab names the director who approves and where links go.

## Tables

| Table | What |
| --- | --- |
| `approvals` | One request: what it is, who asked, who approves, why it waits, what the approver sees, and what was decided |
| `approval_links` | A link to the director's approvals (its hash) and the code that opens it |

Nobody reads these tables directly; the functions check who may do what.
