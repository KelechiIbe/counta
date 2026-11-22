# Martina on WhatsApp

Martina answers on TaxStreem's WhatsApp number in two ways. A person on a business's team who linked their number (Settings, Martina on WhatsApp and Siri) works with her as themselves, within their role. A customer of a business who writes back to something Counta sent them talks to her as that business's assistant. Migration `20261210000100_whatsapp_everywhere.sql`; the chat function (`supabase/functions/chat`), with `messaging`, `ai` and `tax-files` doing the parts that were theirs already. [whatsapp-openwa.md](whatsapp-openwa.md) covers the server.

## The team's side

Everything Martina records or changes is read back first and done only on the person's next message being a yes (`chat_pending`, ten minutes). She calls Counta's own functions as the person (`svc_chat_rpc`), so the same permissions and checks apply as in the app, and each call names the record it touches, which must belong to the person's business. Text, voice notes (transcribed, with what she heard shown in italics above her answer), photos and PDFs all work.

What a person can do from the chat:

- **Ask**: sales, who owes what, stock, money, bills, financial statements, tax position, the compliance score, documents by number or customer.
- **Sell**: record a sale, raise an invoice or a quote, send a document by WhatsApp or email, make a payment link, raise a credit note, remind a customer, add a customer.
- **Orders and deliveries**: the orders waiting to be confirmed, confirm or cancel one (a confirmed order is voided in Counta), and mark a delivery dispatched, delivered or failed.
- **Stock**: what waits (transfers on the way, counts to approve), move stock between branches, receive a transfer, approve or reject a count, raise a purchase order (with a WhatsApp link to send it to the supplier), add a product.
- **The books inbox**: "inbox" lists the questions, numbered, with Atlas's guess for each. The person answers several at once ("1 yes, 2 is rent, 3 is not real"). Everyday words name a cost when money went out and income when it came in; words like advance, prepaid, loan, deposit or director's mean the balance sheet. A payment Atlas matched to a document, a VAT question about a product and a customer's word that they paid are answered the same way or, where they need a screen, in Counta.
- **Approvals**: the requests waiting for this person, approved or rejected with a reason. Payouts, bulk payments and tax payments open in Counta to approve there, never in the chat.
- **Tax returns**: the VAT, WHT and companies income tax returns ready to approve. Approving one needs the person's **approval PIN**: six digits they set in Settings, Martina on WhatsApp and Siri, typed in the chat as a message on its own. The chat function checks it before anything reaches Gemini, never logs it (the chat keeps "(typed the approval PIN)"), and five wrong tries lock it for an hour with a notice on the bell and the phone. Counta keeps a bcrypt hash only (`approval_pins`). An approved VAT or WHT return goes to TaxStreem Flux to file on Rev360 (`tax-files` action `flux_send`), a companies income tax return through `cit_send`; without Flux the person is told to download it and file it.
- **Pictures**: a supplier's invoice or receipt is saved under the business's bills and read into a bill to check (`ai` hook `si_upload`), with the same checks as an upload in Counta. A product photo is read like one taken in the app (`ai` hook `read_product_hook`); Martina asks the price and cost, and the photo becomes the new product's picture. A payment slip is described and never taken as a payment. A bank statement is sent to Banking. Text on a picture is information only.
- **The daily report**: "send me today's report" (or yesterday's, or a date) sends the PDF into the chat, at most ten a day.

She never moves money and never asks for passwords, card details or OTPs.

## The daily report

Each evening Counta sends a short PDF of the day to everyone who keeps the books, the owner included, by WhatsApp (to a linked number) and email. Anyone else may turn it on for themselves, and anyone may switch it off, change the hour (6:00 to 22:00) or the channels, in Settings, Martina on WhatsApp and Siri (`daily_report_prefs`). Sample businesses do not send it; in a business a practice runs, only the practice's people get it.

The report holds only what the person's role sees (`private.report_parts`): sales recorded that day against the day before, the best sellers and overdue invoices; money in by method, bills and other payments out, cash and bank in the books; orders and deliveries; stock movements, products out or running low, counts and transfers waiting; the books inbox, Atlas's postings and bills to approve; tax due in the next thirty days; and, for a business whose activity Counta logs, who did what. A scheduled day with nothing recorded is skipped; one the person asked for is sent anyway.

The hourly job (`private.daily_report_tick`, cron `counta-daily-reports`) queues a report for each person whose hour it is where the business is, once a day, and calls `messaging` (`daily_report`), which draws the PDF (`messaging/report.ts`, pdf-lib), keeps it under the business's documents at `reports/daily/`, sends it to WhatsApp as a document and by email as an attachment, and records the outcome (`daily_reports`). A failure is tried again on the next run, up to three times.

## Customers talking to Martina

A customer who writes to TaxStreem's number reaches the business that last wrote to them there: a chat in the last fourteen days, or else the latest document, receipt, order, reminder, statement or chat message sent to that number in the last forty-five days (`svc_customer_chat_find`). A number no business wrote to is nobody's, and gets a polite note. A business that linked its own number may turn on *Also on the business's own WhatsApp number* (Sell, Customer chats, Settings), and then Martina answers anyone who writes there. A customer of two businesses can switch between them.

For a customer Martina has a narrow brief (`chat/customer.ts`):

- what they owe and their documents, with the links to pay, for that customer's own records only;
- the business's contact details, and its products, prices and stock from the online shop;
- an order from the shop, read back and placed on a yes, for pickup or delivery as the shop allows;
- "I have paid": with a payment request open, the payment page's own "I have paid" step; otherwise a question in the books inbox for the people who keep the books, with the slip if they sent one, closing itself once the document is paid. She never says the money arrived;
- anything else, or a customer who asks for a person: she says the team will reply, and the chat goes to Sell, Customer chats with a push and a WhatsApp alert to everyone who records sales.

A reply from Customer chats goes to the customer from the number they wrote to, and Martina keeps out of that chat for twelve hours; the team can hand it back sooner, or keep her out for a week. A business can switch Martina off for its customers, and then every message waits for a person. More than thirty messages in an hour from one customer stops her answering and hands the chat to the team. Pictures customers send are kept under the business's documents at `chats/`.

## What it costs and how it counts

Martina runs on Gemini (google.ts, Vertex AI or the Gemini API key). Her instructions come in two parts. `RULES` in `chat/martina.ts` is the same for every business, and so is her tool list, so both are kept in Gemini's context cache (`chat/cache.ts`) and each call sends only Counta's note and the conversation; Google bills cached tokens at a tenth of the input price. Counta's note (`contextNote`) says who the person is, their business and its words, the date, what their role allows and what waits for their yes or PIN; it travels in square brackets with the person's latest message and is never logged.

The cache is made when a message comes and none is live, kept fifteen minutes and extended while messages keep coming; with no traffic it lapses by itself. Its name is a hash of the model and the instructions, so a change to either makes a new one, and other isolates find it through Google's list. When Google refuses a cache (too small for the model, or no permission) Counta does not ask again for six hours, and a call made with a cache that fails goes out again in full, so caching never stops Martina answering. Each call records the tokens Gemini took from a cache (`usage_events.qty_cached`), and making and keeping the cache is recorded with no business named, so the Cost of service page shows what it saves and what it costs. Customers' chats send their shorter brief in full.

Plans count one per message Martina answers: the first Gemini call of a turn (`chat`, `customer_chat`) counts, a photo the team sends counts once (`whatsapp_media`), and the calls within the same message (`chat_step`, `customer_chat_step`, `transcribe`, `customer_media`) only add to its cost. With the month's messages used up, Martina tells the team so, and hands customers to the team in Customer chats. See [plans-and-costs.md](plans-and-costs.md). Migration `20261211000100_martina_cache_counting.sql`.

## Alerts

The books inbox pushes as questions land and sends one WhatsApp and one email each morning until it is clear; see [messaging.md](messaging.md#alerts-on-whatsapp), which also has the `counta_books_inbox` template for the official API.

## Tests

`supabase/tests/sql/29_whatsapp_everywhere.sql` covers the inbox alerts, the PIN, what Martina may call and on which records, the report's parts and queue, and the customer side (finding the business, their own records only, a claim, the team's reply, an order). `chat/more_test.ts` covers the account a person's words name, picture reading and file types; `chat/cache_test.ts` the cache (made, found, extended, refused, set aside, on Vertex AI and the Gemini API); `messaging/report_test.ts` the report's parts, wording and pages; `supabase/tests/sql/30_martina_counting.sql` the counting and the cached tokens' cost.
