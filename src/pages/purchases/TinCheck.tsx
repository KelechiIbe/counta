// Tax IDs checked with the NRS: a status chip, the check itself (through the mono edge function, which asks the NRS and
// lets the database compare the names), confirming a name that is spelt differently, and why a bill waits for it.
import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { edge } from '../../lib/api';
import { rpc } from '../../lib/supabase';
import { fmtDay, when } from '../../lib/format';
import { useSession, useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Spinner } from '../../components/ui';

export type TinStatus = 'verified' | 'mismatch' | 'not_found' | 'confirmed' | null | undefined;
export type TinCheck = { taxpayer_name?: string | null; tin_type?: string | null; tax_office?: string | null; name_checked?: boolean; compared_with?: string | null;
  source?: string; confirmed_by?: string; confirmed_at?: string } | null | undefined;

const REFRESH = ['bill', 'bills', 'vendor-tax', 'inv', 'payments'];

export function TinChip({ status, hasTin }: { status: TinStatus; hasTin: boolean }) {
  if (!hasTin) return <span className="chip t-red">No Tax ID</span>;
  if (status === 'verified') return <span className="chip t-green"><Icon name="check" size={11} />Checked with the NRS</span>;
  if (status === 'confirmed') return <span className="chip t-green"><Icon name="check" size={11} />Confirmed</span>;
  if (status === 'mismatch') return <span className="chip t-amber">NRS name differs</span>;
  if (status === 'not_found') return <span className="chip t-red">Not on the NRS record</span>;
  return <span className="chip t-grey">Not checked yet</span>;
}

// What the NRS said, in a line or two.
export function TinOutcome({ status, check, at }: { status: TinStatus; check: TinCheck; at?: string | null }) {
  if (!status) return null;
  const nrs = check?.taxpayer_name;
  return (
    <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>
      {status === 'not_found' ? 'The NRS has no record of this Tax ID.'
        : nrs ? <>NRS record: <b className="ink3">{nrs}</b>{check?.tax_office ? ` · ${check.tax_office}` : ''}{status === 'mismatch' && check?.compared_with ? `, not ${check.compared_with}` : ''}.</>
          : 'The NRS record exists; it gives no name for an individual.'}
      {status === 'confirmed' && check?.confirmed_by ? ` Confirmed as the same business by ${check.confirmed_by}${check.confirmed_at ? ` on ${fmtDay(String(check.confirmed_at).slice(0, 10))}` : ''}.` : ''}
      {at ? ` Checked ${when(at)}.` : ''}
    </div>
  );
}

export function useTinCheck() {
  const { orgId } = useSession();
  const qc = useQueryClient();
  const toast = useToast();
  const [busy, setBusy] = useState<string | null>(null);
  const refresh = () => Promise.all(REFRESH.map((k) => qc.invalidateQueries({ queryKey: [k] })));
  async function check(vendorId: string | null, quiet = false): Promise<TinStatus> {
    setBusy('check');
    try {
      const r = await edge<{ status: TinStatus }>('mono', { action: 'verify_tin', org_id: orgId, vendor_id: vendorId });
      if (r.ok === false) { if (!quiet) toast(r.error || 'The NRS check did not go through.', 'err'); return undefined; }
      await refresh();
      if (!quiet) {
        toast(r.status === 'verified' ? 'Checked: the NRS record matches' : r.status === 'mismatch' ? 'The NRS name is different. Look at it below.'
          : 'The NRS has no record of that Tax ID', r.status === 'verified' ? undefined : 'err');
      }
      return r.status;
    } finally { setBusy(null); }
  }
  async function confirm(vendorId: string | null) {
    setBusy('confirm');
    try { await rpc('confirm_tin', { p_org: orgId, p_vendor: vendorId }); toast('Confirmed as the same business'); await refresh(); }
    catch (e) { toast((e as Error).message, 'err'); }
    finally { setBusy(null); }
  }
  return { check, confirm, busy };
}

const HOLD_TEXT: Record<string, (v: string) => string> = {
  no_tin: (v) => `${v} has no Tax ID. Counta pays a bill with withholding tax only once the supplier's Tax ID is on record and checked with the NRS, because the WHT schedule needs it.`,
  tin_unchecked: (v) => `${v}'s Tax ID has not been checked with the NRS yet. Check it before this bill is paid.`,
  tin_not_found: (v) => `The NRS has no record of ${v}'s Tax ID. Correct it, or send the bill back for the right one.`,
  tin_mismatch: (v) => `The NRS name for ${v}'s Tax ID is different. Confirm it is the same business, or correct the Tax ID, before paying.`,
};
export const holdText = (reason: string, vendor: string) => (HOLD_TEXT[reason] || HOLD_TEXT.tin_unchecked)(vendor);

// On a bill: why it cannot be paid yet, with what to do about it.
export function TinHold({ bill, canKeep, canCheck, onSendBack, onAddTin }: { bill: any; canKeep: boolean; canCheck: boolean; onSendBack: () => void; onAddTin: () => void }) {
  const f = bill.tax_flags || {};
  const reason: string = f.tin_hold;
  const { check, confirm, busy } = useTinCheck();
  const vendor = bill.vendor?.name || 'The supplier';
  return (
    <Alert kind="red" icon="shield">
      <b style={{ display: 'block', marginBottom: 2 }}>Rejected for payment: {reason === 'no_tin' ? 'no Tax ID' : reason === 'tin_mismatch' ? 'Tax ID name differs' : reason === 'tin_not_found' ? 'Tax ID not on the NRS record' : 'Tax ID not checked'}</b>
      {holdText(reason, vendor)}
      {(reason === 'tin_mismatch' || reason === 'tin_not_found') && <TinOutcome status={f.tin_status} check={f.tin_check} at={f.tin_checked_at} />}
      <div className="row wrap" style={{ gap: 6, marginTop: 8 }}>
        {reason === 'no_tin' && canCheck && <button className="btn btn-secondary btn-xs" onClick={onAddTin}><Icon name="plus" size={12} />Add the Tax ID</button>}
        {(reason === 'tin_unchecked' || reason === 'tin_not_found') && canCheck && (
          <button className="btn btn-primary btn-xs" disabled={!!busy} onClick={() => check(bill.vendor_id)}>{busy === 'check' ? <Spinner small /> : <Icon name="shield" size={12} color="#fff" />}Check with the NRS</button>
        )}
        {reason === 'tin_mismatch' && canKeep && (
          <button className="btn btn-primary btn-xs" disabled={!!busy} onClick={() => confirm(bill.vendor_id)}>{busy === 'confirm' ? <Spinner small /> : <Icon name="check" size={12} color="#fff" />}It is the same business</button>
        )}
        {reason !== 'no_tin' && canCheck && <button className="btn btn-secondary btn-xs" onClick={onAddTin}><Icon name="pencil" size={12} />Correct the Tax ID</button>}
        {f.can_return && canKeep && <button className="btn btn-secondary btn-xs" onClick={onSendBack}><Icon name="undo" size={12} />Reject and send back for the Tax ID</button>}
      </div>
    </Alert>
  );
}

// Settings: the business's own Tax ID against the NRS record.
export function OrgTinPanel({ org, canEdit }: { org: { tin?: string | null; rc_number?: string | null; tin_status?: TinStatus; tin_check?: TinCheck; tin_checked_at?: string | null }; canEdit: boolean }) {
  const { check, confirm, busy } = useTinCheck();
  if (!org.tin && !org.rc_number) return null;
  return (
    <div className="card card-pad stack" style={{ gap: 6, borderRadius: 12 }}>
      <div className="row wrap" style={{ justifyContent: 'space-between', gap: 8 }}>
        <span className="row" style={{ gap: 8 }}><b style={{ fontSize: 14 }}>Your Tax ID with the NRS</b><TinChip status={org.tin_status} hasTin={!!org.tin} /></span>
        {canEdit && <span className="row" style={{ gap: 6 }}>
          {org.tin_status === 'mismatch' && <button className="btn btn-secondary btn-xs" disabled={!!busy} onClick={() => confirm(null)}>It is our business</button>}
          <button className="btn btn-secondary btn-xs" disabled={!!busy} onClick={() => check(null)}>{busy === 'check' ? <Spinner small /> : <Icon name="shield" size={12} />}
            {org.tin_status ? 'Check again' : org.tin ? 'Check with the NRS' : 'Find our Tax ID from the RC number'}</button>
        </span>}
      </div>
      <TinOutcome status={org.tin_status} check={org.tin_check} at={org.tin_checked_at} />
    </div>
  );
}
