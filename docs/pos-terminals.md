# POS terminals (Moniepoint)

A business that takes card and transfer payments on Moniepoint terminals connects its Moniepoint account in Payments, POS terminals. From then on the till sends each sale's amount to a terminal, so the cashier never keys it in, and the sale completes the moment Moniepoint confirms the payment. Payments keyed on a terminal by hand reach Counta through the same connection and are matched to their sales. OPay and PalmPay terminals are not supported yet.

The code lives in `supabase/functions/pos` (the `pos` Edge Function, with Moniepoint's API in `moniepoint.ts`) and `supabase/migrations/20261122000100_pos_moniepoint.sql`. The screens are `src/pages/payments/PosTerminals.tsx`, `src/pages/sell/PosWait.tsx` and `src/pages/payments/PosMatch.tsx`.

## Connecting

Only the owner connects, because the key can push amounts to every terminal the business has. The sample business cannot connect.

In the Moniepoint Business app the owner opens Settings, POS Terminal Configuration, switches on ERP Integration, then creates a client under POS App Developers for the live environment with transaction push, transaction read, webhook read and webhook write. Moniepoint shows the key once. The owner pastes it into Counta's Connect Moniepoint form and picks the bank account the terminals pay into. When no account in Counta looks like Moniepoint, the form offers to open one called Moniepoint (bank name Moniepoint MFB), with an optional account number.

Counta then asks Moniepoint about the key (`GET /v1/introspect`). A sandbox key is refused, since it never sees real payments. A key that lacks one of the four permissions is refused with the missing ones named. A key for several Moniepoint businesses gets a second question, which business this is. Counta subscribes to `V1_POS_PURCHASE_TRANSACTION` and `V1_POS_TRANSFER_TRANSACTION` at a webhook address with a random 48-character token, reads the subscription's signing secret, and sets Basic auth on the webhook with a random password where Moniepoint allows it. The key, the signing secret and the password are kept in Vault; the screens only ever show the key's last four characters.

Replacing the key runs the same steps and removes the old subscription. Disconnecting removes the subscription at Moniepoint, wipes the three secrets and stops the till sending to the terminals. Payments already in the books stay where they are.

## Terminals and the ₦100 test

Each terminal is added by its serial number (on the back of the terminal, or in the Moniepoint Business app), with a name the cashier will recognise and the branch it sits in. A terminal that takes a payment before anyone adds it appears on its own, without a branch, and the screen asks which branch it is in. A terminal can be taken out of use and brought back.

Moniepoint's documentation does not say whether amounts sent to a terminal are in naira or kobo, so before the till sends any sale Counta asks for one test. The owner (or a manager) sends ₦100 to a terminal from Payments, POS terminals and says what the terminal shows: ₦100.00, ₦10,000.00 or ₦1.00. A right answer marks the connection ready. Either wrong answer switches the unit and asks for the test again. Nobody pays the test amount; it is cancelled on the terminal.

## At the till

With a connection ready, choosing POS at the till offers "Send to" each terminal, the branch's own first and others marked as another branch, plus "Keyed on another machine (record it only)" for a terminal Counta does not know. Pay by transfer offers the terminal's account the same way, with the Counta wallet as the other choice; a transfer sent to the terminal shows its account number on the terminal screen.

Taking the payment saves the sale as waiting, opens a request with a reference of the form `CNP` and sixteen letters and digits, and sends the amount to the terminal (`POST /v1/transactions`). The till shows the amount and waits. Moniepoint's webhook usually answers first; the till also asks Moniepoint every four seconds (`GET /v1/transactions/merchants/{reference}`). When the payment is approved the sale is paid, the receipt opens and Counta says the payment out loud.

A decline shows Moniepoint's reason. The cashier can send it again to the same terminal or another, as card, transfer or either. "Stop waiting" withdraws the request in Counta, and the cashier should cancel it on the terminal too. "Keep waiting in the background" closes the screen; a banner on the till lists every sale still waiting at a terminal, and each opens the waiting screen again. A request that never reached its terminal expires after ten minutes, and one the terminal never answered expires after thirty. If the customer paid after that, the payment still finds its sale, as below.

The money is recorded from Moniepoint's own answer for that reference, never from the webhook's body alone.

## Payments keyed by hand

A payment on a terminal that Counta did not send arrives by webhook. Counta checks the HMAC signature (`moniepoint-webhook-signature`, Base64 HMAC-SHA256 of `id__timestamp__body` with the subscription's secret), the Basic auth password when one is set, the age of the event (more than seven days old is refused) and the business. It records the payment straight away and then looks the event up at Moniepoint (`GET /v1/webhook-subscription-events/{id}`) to confirm it. Each payment is then placed in this order:

1. A sale the till sent to a terminal for exactly this amount in the last four days, still unpaid. The cashier keyed it by hand, or the customer paid after the till gave up. The nearest in time wins, the same terminal first, and when more than one sale was waiting the payment carries a note asking someone to check with the cashier.
2. A POS, card or transfer payment a cashier recorded in the last two days and that waits to be confirmed, for this amount (from the full till's "record it only", or the phone app's POS). It is confirmed. When several match, the one from the terminal's own branch wins; with several and none from that branch, the payment goes on to the next steps.
3. A business that ticks "We take money for sales that are not rung up in Counta" in Settings, Books: a till sale with no items, at the full amount.
4. Anything else waits in Sales, Payments to confirm (and in Payments, POS terminals) for someone who keeps the books. They pick a waiting sale or invoice for that amount, record it as a sale they did not ring up, give it to a customer paying their account, or post it to another account with a note (the owner's own money, a loan, other income). Bank, cash, stock, receivables, payables and system accounts cannot be chosen there.

A declined payment is kept for the record and posts nothing. A payment Moniepoint reports as approved and later as declined keeps its booking and tells the owner, because the reversal needs a person.

## The books

A POS payment does not go straight to the bank account. It goes to 9002 Bank clearing, so the books do not claim money the account has not shown yet. A sale paid at a terminal posts Dr 9002, Cr receivables (or revenue and VAT for a till sale), and the screen shows how much is waiting to show in the account. A payment waiting for a person posts Dr 9002, Cr suspense, and matching it moves it out of suspense.

When the account's statement or bank feed brings in a credit, the matcher's second step (see [banking-and-feeds.md](banking-and-feeds.md#matching)) looks for POS payments in 9002 on that account: first a single payment within three days before or one day after the line whose amount, less any fee already booked, is the line's amount or at most 2% more; then all the payments of the line's day, or the day before, together, inside the same 2%. The line posts Dr bank, Dr 6701 Payment fees for the difference, Cr 9002, and those payments are marked as in the account.

## Keeping in step

A database cron job, `counta-pos`, calls the function every two minutes while any connection is live or failing. It checks every request still waiting on a terminal and, every six hours, reads each connection's event history at Moniepoint (`GET /v1/webhook-subscription-events`) for anything a webhook missed. A connection whose key Moniepoint refuses is marked as stopped answering, the owner is told, and the till falls back to recording POS payments without sending them.

## Supabase settings

The function needs no secrets of its own beyond Supabase's: each business's key lives in Vault. It is deployed with JWT verification off, because Moniepoint's webhook carries no Supabase token; the function checks the user's token itself for every other action. `MONIEPOINT_POS_BASE_URL` overrides `https://api.pos.moniepoint.com` for tests, and `POS_ALLOW_SANDBOX=1` lets the test harness use sandbox keys.

## Not built yet

The phone app (`/m`) records POS sales for confirmation, and step 2 above confirms them when Moniepoint reports the payment; it does not send amounts to terminals. Counta subscribes only to purchase and transfer events, so agency transactions on a terminal (cash withdrawals, bill payments for customers) never reach the books. Selling from an app on the terminal itself is not built.
