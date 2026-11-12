<!--
Counta default engagement letter template (Release 1 draft).
Merge fields: {{...}}. Conditional blocks: {{#key}} ... {{/key}} render only when key is true.
Clause numbers are written out for review; the renderer renumbers after conditional blocks drop out.
No real-person data may appear in this file (the repository is public).
-->

{{letter.date}}

{{contact.title}}
{{client.name}}
{{client.address}}

Attention: {{contact.name}}

Dear {{contact.salutation}},

LETTER OF ENGAGEMENT FOR THE PROVISION OF {{engagement.title_upper}} TO {{client.name_upper}}

We write further to our recent discussions{{#proposal.date}} and our proposal dated {{proposal.date}}{{/proposal.date}}. This letter sets out the terms on which {{firm.name}} ("we", "us" or "our") will act for {{client.name}} ({{client.reg_label}} {{client.rc_number}}) ("you" or the "Client").

We understand that the Client {{client.description}} and requires {{engagement.title_lower}} in Nigeria on an ongoing basis.

1. Scope of Engagement

1.1 This engagement runs on a {{fees.frequency}} basis. Our role will include the services below.

{{#service.advisory}}
(a) Tax review and advisory. We will review the Client's current and recent commercial arrangements and contracts, assess the tax issues they raise, and issue a memorandum of advice covering:
  (i) the most tax-efficient structure for the Client's operations and transactions, taking account of any related entities;
  (ii) the transaction taxes (value added tax (VAT), withholding tax (WHT), stamp duties and similar taxes) that apply to each arrangement, and lawful measures to manage them; and
  (iii) the Client's tax obligations as a business operating in Nigeria, including income tax, monthly VAT and WHT, employee taxes, pensions and other statutory contributions, and transfer pricing where relevant.
{{/service.advisory}}

{{#service.bookkeeping}}
(b) Accounting setup, tax registrations and bookkeeping. We will set up and maintain an accounting system for the Client to support bookkeeping, financial reporting and internal controls. Under this workstream we will:
  (i) issue and track invoices for payment;
  (ii) review supplier invoices for settlement;
  (iii) record transactions in the accounting system and reconcile the books each month;
  (iv) provide reports on financial performance and business health;
  (v) recommend internal control measures; and
  (vi) register the Client for tax with the Nigeria Revenue Service (NRS) and the relevant State Internal Revenue Service (SIRS), and obtain its Tax ID, as required to file returns and obtain a Tax Clearance Certificate.
{{/service.bookkeeping}}

{{#service.monthly}}
(c) Monthly tax compliance (VAT, WHT and PAYE). For each monthly filing we will:
  (i) review the relevant information from the Client's accounting records;
  (ii) prepare the returns and supporting schedules;
  (iii) send the draft returns and our observations to you for review and approval;
  (iv) discuss the returns with you and advise on the tax payable, if any; and
  (v) file the approved returns and send you copies of the filed returns for your records.
{{/service.monthly}}

{{#service.annual}}
(d) Annual income tax compliance. For each year of assessment we will:
  (i) liaise with the Client's auditors on the preparation of audited financial statements, where required;
  (ii) review the audit work papers and prepare the income tax computations, including capital allowance schedules and supporting documents;
  (iii) send the computations and our observations to you for review and approval;
  (iv) file the approved returns on the NRS online tax portal (currently Rev360) or the portal of the relevant SIRS; and
  (v) send you copies of the filed documents for your records.
{{/service.annual}}

{{#service.other}}
(e) {{service.other_text}}
{{/service.other}}

1.2 Exclusions. Our services do not include statutory audit, representation in a tax audit or investigation, payroll processing, physical inventory counts, forecasting, or system implementation or migration beyond the initial accounting setup, or any service not listed in paragraph 1.1. If the Client needs any of these, we will agree the scope and fees separately in writing.

1.3 Service levels. We will deliver monthly work (including reports, reconciliations and statutory returns) within {{service.days}} days of receiving all the documents and information we need. Annual work will be completed within the deadlines set by the relevant tax authorities, provided you and your auditors give us information in good time.

2. Our Authority to Act

2.1 By signing this letter, the Client appoints us as its tax agent and authorises us, for the purposes of this engagement, to:
  (a) correspond with, file returns with, and receive notices from the NRS and any SIRS on the Client's behalf;
  (b) register the Client for any tax it is required to register for;
  (c) keep the Client's books and records in an accounting system we select, maintained in the Client's name; and
  (d) issue invoices, receipts and credit notes in the Client's name, where paragraph 1.1(b) applies.

{{#mode.full_mandate}}
2.2 Full mandate. The Client further authorises us to set up and administer its accounting records and related systems without the Client's day-to-day involvement, and to act as administrator of those systems on the Client's behalf. This includes verifying the Client's identity with service providers using information and documents the Client gives us for that purpose. This authority does not extend to opening any payment or collection account in the Client's name, or to moving the Client's funds, unless a director of the Client separately authorises it in writing.
{{/mode.full_mandate}}

2.3 Access and credentials. The Client may give us access to its tax portal accounts and view-only access to its bank accounts. We will keep any credentials secure and use them only for this engagement. The Client remains the owner of those accounts and should change the credentials when the engagement ends.

2.4 This authority continues until the engagement ends under paragraph 13 or the Client withdraws it in writing.

3. Your Responsibilities

3.1 The Client is responsible for:
  (a) giving us complete and accurate information and documents, in good time;
  (b) the management decisions of its business, including whether to accept our advice;
  (c) reviewing and approving returns and computations before we file them, except where it has asked us in writing to file without prior review;
  (d) paying taxes when due, unless we have agreed in writing to arrange payment from funds the Client provides;
  (e) keeping original records and documents as required by law; and
  (f) telling us promptly of any change in its business, ownership, directors or contact details.

3.2 We will rely on the information the Client gives us. We are not responsible for errors or delays that result from information that is incomplete, inaccurate or late.

4. Our Team

4.1 We will set up a core team with relevant experience for this engagement, led by the engagement partner named below. Other members and resources of the firm will be available as needed.

4.2 {{partner.name}}, {{partner.title}}, has overall responsibility for this engagement{{#team.assistant}} and will be assisted by {{team.assistant}}{{/team.assistant}}.

4.3 If you have difficulty reaching our team, please email {{firm.email}}{{#firm.phone}} or call our office on {{firm.phone}} during business hours{{/firm.phone}}.

4.4 We understand that {{contact.name}} (the "Designated Client Contact") is authorised to instruct us on this engagement and to approve costs within its scope. We will assume this remains the case until you tell us otherwise. Where we act on instructions from other people at the Client who have taken part in correspondence with the Designated Client Contact, we will make sure the Designated Client Contact knows.

5. Professional Fees and Expenses

5.1 Our fee for this engagement is a consolidated {{fees.frequency}} fee of {{fees.amount}} ({{fees.amount_words}}), covering the scope of work in paragraph 1.1.

5.2 Assumptions. Our fee assumes that:
  (a) the scope of work will not change materially during the engagement; if we are asked to do work outside it, we will tell you and obtain your written approval, and that work will be charged separately;
  (b) we will receive timely and clear instructions, and the documents and information we ask for within a reasonable time;
  (c) instructions will be given by email and video or telephone calls, and we will not be required to attend in-person meetings; travel outside {{firm.city}} at your request will be charged in addition to our fee; and
  (d) out-of-pocket expenses and administrative costs are charged separately, at cost.
If any of these assumptions proves wrong, either of us should tell the other promptly.

{{#fees.deposit}}
5.3 Expenses. To avoid consulting you on every small out-of-pocket expense (such as printing, courier charges and statutory filing fees), we ask for a deposit on account of {{fees.deposit}} ({{fees.deposit_words}}). When the deposit is used up we will send a detailed statement of expenses, supported by receipts where available, and may ask for a further deposit. We will obtain your approval before incurring any large individual expense.
{{/fees.deposit}}

5.4 Taxes. Our fees are exclusive of VAT, which we will add to our invoices at the applicable rate (currently 7.5%). Where the Client deducts withholding tax from our fees, it should remit the tax and give us the credit note or receipt promptly.

5.5 Billing and payment. We will invoice our fee{{#fees.deposit}} and the expense deposit{{/fees.deposit}} when this letter is signed, and then on day {{fees.billing_day}} of each {{fees.billing_period}}. Invoices are payable within {{fees.payment_days}} days. We may pause work on the engagement while any invoice remains unpaid {{fees.suspend_days}} days after its due date.

6. Confidentiality

6.1 We will keep confidential all information about the Client's affairs that we receive in this engagement, except where the Client authorises disclosure, where the law or a regulator requires it, or where the information is already public. We may also disclose information to our professional indemnity insurers and professional advisers on a confidential basis.

6.2 We may say that we have acted for the Client on a matter that is already public, and identify the Client by name or logo and the general nature of our work. Where the matter is not public, we will only say the Client is our client with its consent.

6.3 We also owe a duty of confidentiality to our other clients. If we hold confidential information about another client that may be relevant to you, we will not disclose it to you or use it for your benefit, and we will treat your information the same way. You agree that we may act for another client whose interests are not adverse to yours without your consent, provided we keep your information confidential, using a separate team where appropriate.

7. Conflicts of Interest

7.1 Professional rules of ethics that govern accountants and tax practitioners prohibit us from acting where there is a conflict of interest, or a significant risk of one.

7.2 A conflict of interest arises where:
  (a) the work we are asked to do for one client is against the interests of another client, for example advising on a claim against that other client; or
  (b) as described in paragraph 6.3, we hold confidential information from acting for one client that is relevant to a matter we are asked to handle for another.

7.3 We check for actual and potential conflicts before accepting new instructions. If we identify a potential conflict, we will try to resolve it with the parties concerned, subject to our duty of confidentiality.

7.4 We have carried out a conflicts check and confirm that no conflict of interest arises from this engagement{{#conflicts.note}}, {{conflicts.note}}{{/conflicts.note}}.

8. Anti-Money Laundering

8.1 As a designated non-financial business under the Money Laundering (Prevention and Prohibition) Act 2022, we must identify and verify our clients and their beneficial owners before and during an engagement, and keep those records for at least five years after the engagement ends. The Client agrees to give us the information and documents we need for this.

8.2 The law may require us to report a suspicion of money laundering or terrorist financing to the authorities without telling the Client. A report made in good faith is not a breach of our duty of confidentiality, and we will not be liable for any loss that results from it.

9. Personal Data

9.1 In this engagement we will process personal data about the Client's directors, shareholders, employees, customers and suppliers, such as names, contact details and identification and transaction information. We will process it in line with the Nigeria Data Protection Act 2023, only for the purposes of this engagement and to meet our legal and professional obligations.

9.2 We will keep the personal data secure, limit access to the people who need it, and use service providers (including our accounting software providers) only under terms that protect it. Where data is stored or processed outside Nigeria, we will make sure it is protected as the Act requires.

9.3 We will tell the Client without undue delay if we become aware of a breach affecting personal data we hold for it, and will help it meet its own obligations under the Act. The Client confirms it has the right to give us the personal data it shares with us.

10. Limitation of Liability

10.1 We will not be liable for any loss, damage, cost or expense suffered by the Client or any other party in connection with our information, advice or other work under this engagement, unless a Nigerian court finally establishes that it arose from our negligence. In that case our total liability is limited to the amount of our professional indemnity insurance cover or the total fees paid to us under this engagement, whichever is {{liability.cap_basis}}.

10.2 Our advice is for the Client's use only. A third party may rely on it only with our express written consent, and the Client will indemnify {{firm.name}} and its personnel against claims arising from any third party's reliance on our advice.

10.3 {{firm.name}} alone is responsible for the services under this letter. No individual partner, employee or adviser has any personal liability to the Client for them.

10.4 Where we are jointly liable with another person, our liability is reduced by any contribution we would have recovered from another adviser but cannot recover because the Client agreed to limit that adviser's liability.

11. Copyright

Original materials we produce for the Client remain our copyright. The fees paid give the Client a licence to use them for the purposes for which they were produced and related purposes. The Client does not own the copyright in our work unless we agree in writing. The Client's own books, records and data remain the Client's property.

12. Retention of Documents

We will keep our files for this engagement for {{retention.years}} years after it ends. After that period, provided we have returned the Client's original documents, we may destroy the files without further reference to the Client. The Client may ask us before then to keep them for longer.

13. Term and Termination

13.1 This engagement starts on the date this letter is signed{{#engagement.start_date}} and covers work from {{engagement.start_date}}{{/engagement.start_date}}, and continues until either party ends it.

13.2 Either party may end the engagement by giving the other {{termination.notice_days}} days' written notice.

13.3 We may end the engagement immediately by written notice if fees remain unpaid {{fees.suspend_days}} days after their due date, or if continuing to act would breach the law or our professional rules.

13.4 When the engagement ends, the Client will pay our fees and expenses up to the date it ends. We will return the Client's original documents and hand over its books, records and data, including access to the accounting system we maintained for it, within {{termination.handover_days}} days.

14. Resolving Problems

To discuss any aspect of this engagement, please contact {{partner.name}}, {{partner.title}}, at {{partner.email}}. We will deal with any concern promptly and professionally.

15. Governing Law and Dispute Resolution

15.1 This letter, and any non-contractual obligations arising from or connected with it, are governed by Nigerian law.

15.2 The parties will first try to settle any dispute, controversy or claim arising from or relating to this letter (including its breach, existence, validity or termination) through good-faith negotiation.

15.3 Any dispute not settled within 30 days after negotiations begin, or any longer period the parties agree in writing, will be referred to and finally resolved by arbitration under the Arbitration Rules in the First Schedule to the Arbitration and Mediation Act 2023. The tribunal will be a sole arbitrator appointed by agreement of the parties or, failing agreement within 14 days, in accordance with that Act. The seat of arbitration is {{arbitration.seat}} and the language is English.

15.4 The parties will keep confidential the existence and substance of any dispute and arbitration, the materials used and created for it, and any award, unless the information is already public (other than through a breach of this paragraph) or must be disclosed by law, to a party's professional advisers or insurers, or to protect a legal right or enforce or challenge an award.

16. Signature and Entire Agreement

16.1 This letter may be signed electronically and in counterparts. An electronic signature has the same effect as a handwritten one.

16.2 This letter is the entire agreement between the parties about its subject matter and replaces any earlier understanding or agreement, written or oral. It may be amended only in writing signed by both parties.

If you agree with these terms, please confirm by signing below. We look forward to working with you.

Yours faithfully,
For: {{firm.name}}

{{signature.firm}}
{{partner.name}}
{{partner.title}}

The above terms are accepted by the authorised representative of {{client.name}}:

{{signature.client}}
Name: {{signer.name}}
Designation: {{signer.title}}
Date: {{signer.date}}
