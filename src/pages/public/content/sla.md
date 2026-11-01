# Service Level Agreement for E-Invoicing

Last updated: 1 November 2026

## Introduction

This Service Level Agreement (SLA) sets out the terms on which TaxStreem Technologies Limited ("TaxStreem", "we") provides System Integration (SI) and Access Point Provider (APP) services for the Nigeria Revenue Service (NRS) e-invoicing solution, the Merchant Buyer Solution (MBS).

It applies to every business that issues or receives e-invoices through TaxStreem: in Counta, TaxStreem's accounting, inventory and sales software, or through a partner that uses the [TaxStreem E-Invoicing API](/developers).

By using our e-invoicing services, you agree to the terms in this SLA. Please read it carefully before you start.

## Scope of services

We provide two services.

**System Integration (SI)**

- Integration of your sales and accounting records with the NRS MBS e-invoicing platform.
- Onboarding support, API management and compliance setup, so your e-invoices are generated and transmitted securely.

**Access Point Provider (APP)**

- Secure transmission of e-invoices between your business, your trading partners and the NRS platform.
- Real-time invoice validation, security checks and tracking.

Our APP services start once NRS licenses TaxStreem as an Access Point Provider. Until then, your default access point on the MBS delivers your signed invoices, and the rest of this SLA applies in full.

## Service availability

We guarantee 99.9% uptime for our e-invoicing services in every calendar month. In a 30-day month, that leaves room for no more than 43 minutes of downtime. If downtime goes beyond that, you may be eligible for service credits (see [Liabilities and penalties](#liabilities-and-penalties)).

Downtime means our service cannot accept, send or report your invoices. Time when the NRS platform itself is unavailable does not count, nor do faults in your own systems or connection, nor events beyond our reasonable control. While NRS is unavailable we hold your invoices and send them as soon as NRS answers, so you can keep trading.

We announce planned maintenance at least 48 hours ahead and schedule it for quiet hours.

## Response and resolution times

Our support operates 24 hours a day, 7 days a week. Write to [support@taxstreem.com](mailto:support@taxstreem.com), or use Help inside Counta.

| Priority | What it covers | We respond within | We resolve within |
| --- | --- | --- | --- |
| Critical | Our service is down; invoices cannot reach NRS for many businesses; your data may be at risk | 30 minutes | 1 hour |
| High | A major function fails for your business, such as invoices not being signed or delivered | 1 hour | 4 hours |
| Normal | Any other fault or question | 4 hours | 8 hours |

Times run from when your report reaches us. Resolved means the service works for you again, which may be through a temporary fix while we complete the permanent one.

## Security and data protection

We protect your data with strong encryption.

- **Data encryption** during transmission and at rest. Your NRS API key, API secret and crypto keys are encrypted with keys held in a hardware security module, and no screen shows them again once they are saved.
- **Regular security audits** to keep us in line with NRS requirements.
- **Two-step sign-in.** Anyone who can change your business's settings or its NRS keys signs in to Counta with a password and a code from an authenticator app, and Counta refuses changes to e-invoicing from a session without that code. Everyone else in your business may turn it on.
- **Sealed invoices.** Once NRS signs an invoice, TaxStreem seals the invoice exactly as it was sent with a JAdES signature made in a hardware security module, so either side can later show what was sent and when.
- **Partner access by OAuth 2.0.** Partners that send invoices for you use short-lived access tokens, and TaxStreem keeps only a hash of each secret and token.
- **Invoice data kept in Nigeria.** A live copy of our database, with every invoice in it, is kept on servers in Lagos and stays within minutes of the main database in Google Cloud.

We comply with the Nigeria Data Protection Act 2023 and follow NRS guidelines on cryptographic stamps for invoice validation. Our [Privacy Notice](/privacy) explains how we handle personal data.

## Monitoring and compliance

We continuously monitor:

- system uptime and performance;
- each invoice's progress with NRS, so one that NRS refuses or cannot receive reaches a person quickly;
- compliance with NRS's e-invoicing and cryptographic standards.

## Liabilities and penalties

If we fail to meet this SLA, these remedies apply.

- **Downtime above 0.1% in a month:** service credits or rebates in proportion to the excess downtime.
- **Delays in responding to or resolving critical issues:** a refund equal to 0.01% of your monthly accrued e-invoicing fees.

To claim, write to [support@taxstreem.com](mailto:support@taxstreem.com) within 30 days after the end of the month in which the failure happened.

## Confidentiality

We keep all information shared through our services confidential. We do not disclose it to third parties without your explicit consent, except to NRS as e-invoicing requires and where the law obliges us. Our [Privacy Notice](/privacy) gives the details.

## Changes to this agreement

We may update this SLA from time to time to reflect changes in our services or operations. When we do, we revise the "Last updated" date at the top and tell you of any material change by email or inside Counta.

## Termination

This SLA stays in effect until either party ends it with 30 days' notice. Either party may end it at once for a breach related to security or to compliance with the NRS framework.

## Contact

Questions about this SLA go to [support@taxstreem.com](mailto:support@taxstreem.com). You may also contact NRS at [einvoice@nrs.gov.ng](mailto:einvoice@nrs.gov.ng).
