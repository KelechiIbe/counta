// Values for previewing a template or a letterhead with a sample letter: every service shown, the letter's own defaults.
import type { MergeValues } from '../../supabase/functions/_shared/letter.ts';

export const PREVIEW_MERGE: MergeValues = {
  'service.advisory': true, 'service.bookkeeping': true, 'service.monthly': true, 'service.annual': true, 'liability.cap_basis': 'lower', 'retention.years': 6,
  'fees.frequency': 'monthly', 'fees.amount': 250000, 'fees.deposit': 50000, 'fees.billing_day': 20, 'fees.billing_period': 'month', 'fees.payment_days': 14,
  'fees.suspend_days': 30, 'service.days': 7, 'termination.notice_days': 30, 'termination.handover_days': 14, 'arbitration.seat': 'Lagos',
  'client.name': 'Client Name Limited', 'firm.name': 'Your Firm', 'partner.name': 'Engagement Partner', 'partner.title': 'Partner',
};
