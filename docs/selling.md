# Selling in Counta

Counta's Sell section covers the till, invoices and quotes, customers on credit, orders and deliveries for distributors, price lists and an online shop. Every sale updates stock and the books in the same step, and every way of being paid ends in the same ledger.

## What each sale posts

An issued sale writes one journal:

| | Account |
| --- | --- |
| Dr | 1101 Trade receivables, gross, with the customer as the party (till sales use the walk-in customer) |
| Cr | 41xx Revenue, net of VAT and discounts (delivery charges to their own income account) |
| Cr | 2201 Output VAT, for standard-rated lines |
| Dr / Cr | 5400 Cost of sales and 1203 Inventory at weighted average cost |

Money received posts separately as a collection: Dr till cash, bank or wallet (and Dr 6701 for a provider's fee), Cr 1101. Anything paid beyond what is owed goes to 2107 Customer advances. Cash confirms itself. Transfers, POS, cheques and other channels stay pending until a manager or the bookkeeper confirms them against the bank (Sales, Payments to confirm). Flutterwave and partner-rail payments confirm themselves once the rail's record says paid. Until a payment is confirmed the customer still owes the money.

The VAT on each line comes from the item's treatment, which the tax agent sets when the item is added (see [atlas.md](atlas.md)).

## The till

- Branch and cashier shift: a shift opens with a counted float and closes with a count. Pay-ins, pay-outs and cash drops to the bank or safe are recorded during the shift. The difference at close posts to cash over and short with the cashier's name.
- Cart: scan with a barcode scanner or the camera, search by name or SKU, or tap a best seller. Lines can be sold by the selling unit or the purchase unit (a carton at the carton price). The customer's price list and quantity tiers apply before checkout (`till_prices`). People with Edit prices can override a price.
- Discounts on a line and on the whole sale.
- Split tender: cash, transfer to the business's account, pay by transfer (a one-off account from the rail), payment link, QR, POS, cheque and on account for customers with credit. Change is worked out on cash.
- Pay by transfer waits on screen, checks every four seconds and says the payment out loud when the money arrives.
- Receipt: on screen, by WhatsApp or email, printed on an 80 mm thermal printer over Bluetooth (ESC/POS), or printed from the browser.
- Keyboard: F2 to search, F9 to pay.
- Returns and voids: a return credits the lines returned, puts the stock back (or writes it off) and refunds by the method chosen. A void needs a reason.

## Invoices, quotes, credit notes

- Quotes convert to invoices. Invoices can take a deposit, part payments and WHT credits from customers that withhold.
- Each document has a public page (`/p/<token>`) that shows it and lets the customer pay by transfer, link or QR without signing in. It can be printed or saved as PDF.
- Credit notes reverse revenue, VAT and stock for returned goods.

## Customers and credit

- Each customer can have a price list, payment terms and a credit limit. Only a manager, an accountant or the owner sets a limit.
- A sale on account that takes the customer over their limit is refused at the till; a manager can approve it.
- Statements show every document and payment with the running balance, export to Excel or PDF and can be sent by WhatsApp or email with a pay link.
- Payment reminders go out automatically on the days the business chooses (for example 3 days before the due date, on it, and 3, 7 and 14 days after), each with a link to pay.
- A payment settles the documents it names, then the oldest open ones. Overpayments sit as advances and can be used on the next sale or refunded.

## Distributors

- Price lists: fixed prices per item with quantity tiers, a percentage off retail, or a markup on cost. A customer's list applies at the till and on invoices.
- Orders: taken by phone or by a sales rep (Sell, Orders and deliveries) or placed in the online shop. An order waits unposted until it is confirmed; deposits sit as customer advances. Confirming posts the sale, moves the stock, applies any deposit and opens a delivery when the customer asked for one.
- Deliveries: each delivery has a delivery note to print, a status (pending, dispatched, delivered, failed or cancelled) and can be assigned to a van.
- Vans: a van is a location. Stock is transferred to it and sold from it like any branch, and a stock count at the end of the day shows what came back.

## Online shop

Each business can switch on a shop at `/shop/<slug>` (Sell, Online shop). It lists the goods the business sells, optionally limited to chosen categories, with their price and whether they are in stock at the shop's branch, read live from stock levels; the business can choose to show the quantity too. The shop link and its QR code can be shared on WhatsApp, Instagram and anywhere else. New orders notify everyone who records sales.

Each product shows its photo and a storefront description: what it is, size or weight, what is in the pack, how to use it. Both are set on the item (Inventory, Items, Edit, Online shop); the description is up to 4,000 characters and keeps its line breaks. Customers tap a product to see the large photo and the full description and add it to the cart from there. The staff note on the item (Description) is never shown in the shop. Photos taken on a phone are resized in the browser to at most 1,600 pixels before upload, so they load quickly and stay under the 5 MB limit.

The shop wears the business's branding: its colour (shared with invoices), logo, a banner picture, a tagline and links to Instagram, Facebook, TikTok and X. These are set under Sell, Online shop, Look and checkout.

Checkout runs in four steps:

1. Cart: quantities, with the smallest order the business accepts, if it set one.
2. Your details: name, WhatsApp number and, optionally, email. A returning customer's details are remembered on their own phone.
3. Delivery: pickup (with the pickup address) or delivery to an address, city and state, plus a note for the shop.
4. Payment: pay now (a transfer account made for the order, card or USSD when the business has online payments) or pay on delivery or at pickup, when the business allows it.

The confirmation gives the order number and a link to the order's own page, where the customer can pay and follow the order: placed, confirmed, on its way or ready for pickup, and delivered or collected.

## Branded documents

Invoices, receipts, quotes, orders and credit notes print in one of three templates (Settings, Branding):

| Template | Look |
| --- | --- |
| Classic | Logo and business details on the left, the title in the brand colour, a tinted table heading |
| Modern | A band of the brand colour across the top, a coloured table heading and a bold total |
| Minimal | Plain and spacious; the brand colour only on the title and the total |

Every document carries the business's logo, office address, phone, email, website, Tax ID and RC number, the customer's name, contact person, address and Tax ID, the VAT status of each line, the amount in words, the payment details and an optional signature line. Each of Tax ID, RC number, VAT status, amount in words and signature can be switched off. Counta picks black or white text for whatever colour is chosen. The same document is the customer's online copy, the A4 print and the PDF ("View, print or PDF" on any document), and the emails use the same logo and colour.

## Customers

A customer can have a street address, city, state and country, a contact person, a Tax ID (or the tax number of their own country, for a customer abroad) and up to five more email addresses that receive a copy of every email. None of these is required. Quick add at the till and on invoices takes a phone number, with email, Tax ID and address one tap away.

The Tax ID replaced the TIN: 13 digits, from the NIN for an individual and from the RC number for a company. A Tax ID typed into Counta (the business's own under Settings, a customer's, a vendor's) must have 13 digits; spaces and dashes are dropped. A number already on file, including an old TIN, keeps printing until someone types a new one, and imports and TaxStreem sign-in bring numbers in as they are. Screens mark an old TIN so it can be replaced.

## VAT status of each sale

Every sale line carries a VAT status, shown in the sales list (with a filter), on each document and in Sales analysis (By VAT status):

| Code | Meaning |
| --- | --- |
| 0 | VATable at 7.5% |
| 1 | Exempt |
| 2 | Zero-rated |

A customer whose country is not Nigeria makes the sale an export: every line, delivery included, is zero-rated (2), whatever the item's own treatment, and the document says so. The item's own treatment is kept on the line. A manager or the bookkeeper can change whether an unposted document is an export, with a reason that is kept for the VAT records. Credit notes follow the sale they credit.

## Permissions

| Permission | Lets a person |
| --- | --- |
| Record sales | Use the till, raise invoices and orders, take payments |
| Edit prices | Change prices at the till and edit price lists |
| Keep the books | Confirm payments, refund customers, see the books |
| Make payments | Pay bills and send payouts from the wallet |
| See margins | See costs and margins |

The owner sets these per person under Inventory, Locations and staff. The accountant role starts with Keep the books and See margins and can prepare the month-end close; only the owner closes a month.
