// What a payer's page (the public document) sees of its payment request, and how often it may make Counta read the rail.

export function publicView(r: any) {
  if (!r) return null;
  return { method: r.method, status: r.status, amount: r.amount, account_number: r.account_number, bank_name: r.bank_name, account_name: r.account_name,
    link_url: r.link_url, qr_image: r.qr_image, expires_at: r.expires_at, direct: Boolean(r.direct), pay_ref: r.direct ? r.pay_ref : undefined,
    error: r.status === 'failed' ? 'This way of paying is not available right now.' : undefined,
    // The customer's own word that they paid, and whether the business has been asked to check.
    claimed_at: r.claimed_at || undefined, claim_amount: r.claim_amount ?? r.claim?.amount ?? undefined, claim_flagged: Boolean(r.claim_flagged || r.claim_flagged_at) };
}

// Every 15 seconds, or every 5 for the first three minutes after the customer says they have paid.
export function publicCheckEvery(claimedAt: string | null | undefined, now = Date.now()) {
  const at = claimedAt ? Date.parse(claimedAt) : NaN;
  return Number.isFinite(at) && now - at >= 0 && now - at < 180_000 ? 5_000 : 15_000;
}
