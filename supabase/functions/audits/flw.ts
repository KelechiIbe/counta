// What the audits function sends to Flutterwave and how it reads the answers. Pure, so it is tested on its own.

// Flutterwave takes Nigerian phone numbers as digits only: "+234 803 555 0142" and "0803-555-0142" both become "08035550142".
export function ngPhone(p?: string | null): string | undefined {
  const d = String(p || '').replace(/\D/g, '');
  const n = d.startsWith('234') && d.length >= 12 ? '0' + d.slice(3) : d;
  return n.length >= 10 && n.length <= 14 ? n : undefined;
}

export type SubCtx = {
  practice: { id: string; name: string; email?: string | null; phone?: string | null };
  bank: { bank_code: string; account_number: string; account_name: string; name_match: boolean };
  subaccount: { ref?: string | null; num?: number | null; bank?: string | null; account?: string | null; status: string };
  referral_rate: number;
};

// The firm's split: its share settles to its bank account; TaxStreem's default share is the referral rate (each checkout
// sets TaxStreem's share as a flat amount anyway). Email and phone fall back to the partner setting it up.
export function subaccountBody(ctx: SubCtx, fallback: { email?: string | null; phone?: string | null }) {
  const email = (ctx.practice.email || fallback.email || '').trim();
  const phone = ngPhone(ctx.practice.phone) || ngPhone(fallback.phone);
  if (!email) throw new Error('Add the practice\'s email address under Practice first.');
  if (!phone) throw new Error('Add the practice\'s phone number under Practice first.');
  return {
    account_bank: ctx.bank.bank_code, account_number: ctx.bank.account_number,
    business_name: ctx.practice.name.slice(0, 100), business_email: email, business_mobile: phone,
    business_contact: ctx.bank.account_name.slice(0, 100), business_contact_mobile: phone,
    country: 'NG', split_type: 'percentage', split_value: Number(ctx.referral_rate) || 0,
  };
}

// Whether the split must be made, moved to a new bank account, or is already right.
export function subaccountPlan(ctx: SubCtx): 'create' | 'update' | 'keep' {
  const s = ctx.subaccount;
  if (!s.num || !s.ref) return 'create';
  if (s.status === 'ready' && s.bank === ctx.bank.bank_code && s.account === ctx.bank.account_number) return 'keep';
  return 'update';
}

export type ChargeCtx = {
  charge: { tx_ref: string; amount: number | string; referral: number | string; subaccount_ref: string; status: string };
  engagement: { id: string; year: number };
  org: { id: string; name: string; email?: string | null; phone?: string | null };
  firm: { id: string; name: string };
  description: string;
  return_path: string;
};

// A Flutterwave checkout for an audit: the business pays the amount; TaxStreem takes its referral fee as a flat amount and the
// firm's split gets the rest, less Flutterwave's charge (with "flat" the subaccount bears it).
export function checkoutBody(ctx: ChargeCtx, appUrl: string) {
  const back = /^\/[a-z/-]+$/.test(ctx.return_path) ? ctx.return_path : '/filing';
  return {
    tx_ref: ctx.charge.tx_ref, amount: Number(ctx.charge.amount), currency: 'NGN',
    redirect_url: `${appUrl.replace(/\/$/, '')}${back}?audit_ref=${encodeURIComponent(ctx.charge.tx_ref)}`,
    customer: { email: ctx.org.email || `billing+${String(ctx.org.id).slice(0, 8)}@counta.ng`, name: String(ctx.org.name).slice(0, 60),
      phonenumber: ngPhone(ctx.org.phone) },
    customizations: { title: 'Counta', description: ctx.description.slice(0, 120) },
    payment_options: 'card, banktransfer, ussd',
    subaccounts: [{ id: ctx.charge.subaccount_ref, transaction_charge_type: 'flat', transaction_charge: Number(ctx.charge.referral) }],
    meta: { kind: 'audit', engagement_id: ctx.engagement.id, org_id: ctx.org.id },
  };
}

export type Verdict = { status: 'successful'; paid_amount: number; fee: number; provider_ref: string }
  | { status: 'failed'; error: string; provider_ref?: string } | { status: 'pending' };

// Flutterwave's answer to verify_by_reference, read against what was due. Paid in naira, at least the amount due, for this
// reference: successful. Failed: failed. Anything else is still pending.
export function readVerify(d: any, txRef: string, due: number): Verdict {
  if (!d || d.tx_ref !== txRef) return { status: 'pending' };
  const st = String(d.status || '').toLowerCase();
  if (st === 'successful') {
    if (d.currency && d.currency !== 'NGN') return { status: 'failed', error: `Paid in ${d.currency}, not naira.`, provider_ref: String(d.id || '') };
    const paid = Number(d.amount) || 0;
    if (paid + 0.005 < due) return { status: 'failed', error: `Flutterwave confirmed ₦${paid.toFixed(2)}, less than the ₦${due.toFixed(2)} due.`, provider_ref: String(d.id || '') };
    return { status: 'successful', paid_amount: paid, fee: Number(d.app_fee) || 0, provider_ref: String(d.id || d.flw_ref || '') };
  }
  if (st === 'failed') return { status: 'failed', error: String(d.processor_response || 'The payment failed.').slice(0, 200), provider_ref: String(d.id || '') };
  return { status: 'pending' };
}
