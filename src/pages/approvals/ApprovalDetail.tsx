// One request waiting for approval, as the approver sees it: what it is, the figures, and why it waits. Shared by the
// Approvals page and the director's page (/approve), so both show the same thing.
import type { ReactNode } from 'react';
import { N2, fmtDay, when } from '../../lib/format';
import { KIND_LABEL, REASON_LABEL, RELIEF, STATUS_LABEL, STATUS_TONE, decidedText, type Approval } from '../../lib/approvals';

const FREQ: Record<string, string> = { monthly: 'Every month', quarterly: 'Every three months', annually: 'Every year' };
const METHOD: Record<string, string> = { cash: 'cash', transfer: 'bank transfer', cheque: 'cheque', other: 'another way' };

export function ApprovalDetail({ a, open }: { a: Approval; open?: boolean }) {
  const s = a.summary || {};
  return (
    <div className="stack" style={{ gap: 6, minWidth: 0 }} data-testid="approval-item">
      <div className="row wrap" style={{ gap: 8 }}>
        <b style={{ minWidth: 0 }}>{s.title || KIND_LABEL[a.kind]}</b>
        <span className={'chip ' + STATUS_TONE[a.status]}>{a.status === 'pending' ? KIND_LABEL[a.kind] : STATUS_LABEL[a.status]}</span>
      </div>
      <div className="faint" style={{ fontSize: 12 }}>
        {a.requested_by_name ? `Asked by ${a.requested_by_name}` : 'Asked'} {when(a.created_at)} · {a.reasons.map((r) => REASON_LABEL[r]).join(' · ')}
      </div>
      {a.status !== 'pending' && <div style={{ fontSize: 13, color: a.status === 'approved' ? undefined : '#B91C1C' }}>{decidedText(a)}.</div>}
      {open !== false && <Figures a={a} s={s} />}
    </div>
  );
}

function Row({ k, v }: { k: string; v: ReactNode }) {
  return <div className="row" style={{ justifyContent: 'space-between', gap: 12, fontSize: 13 }}><span className="muted">{k}</span><span className="num" style={{ textAlign: 'right' }}>{v}</span></div>;
}

function Figures({ a, s }: { a: Approval; s: Record<string, any> }) {
  const lines: any[] = Array.isArray(s.lines) ? s.lines : [];
  const box = { background: '#FAFAFA', borderRadius: 10, padding: '10px 12px' } as const;
  if (a.kind === 'invoice') return (
    <div className="stack" style={{ gap: 4, ...box }}>
      {lines.map((l, i) => (
        <div key={i} className="row" style={{ justifyContent: 'space-between', gap: 12, fontSize: 13 }}>
          <span className="ellipsis">{Number(l.qty)} × {l.description} at {N2(l.unit_price)}{Number(l.discount) > 0 ? `, less ${N2(l.discount)}` : ''}</span>
          <span className="num">{N2(l.gross)}</span>
        </div>
      ))}
      {Number(s.discount) > 0 && <Row k="Discounts" v={`${N2(s.discount)} (${s.discount_pct}% off)`} />}
      <Row k={s.relief ? `VAT (exempt: ${RELIEF[s.relief as keyof typeof RELIEF]?.label.toLowerCase() || s.relief}${s.relief_ref ? `, ${s.relief_ref}` : ''})` : s.export ? 'VAT (export, zero-rated)' : 'VAT'} v={N2(s.vat)} />
      <Row k="Total" v={<b>{N2(s.total)}</b>} />
      <Row k="Dated" v={`${fmtDay(s.issue_date)}${s.due_date ? `, due ${fmtDay(s.due_date)}` : ''}`} />
    </div>
  );
  if (a.kind === 'credit_note') return (
    <div className="stack" style={{ gap: 4, ...box }}>
      {lines.map((l, i) => <Row key={i} k={l.description} v={N2(l.gross)} />)}
      <Row k="VAT in it" v={N2(s.vat)} />
      <Row k="Credit note" v={<b>{N2(s.total)}</b>} />
      {s.reason && <Row k="Reason" v={s.reason} />}
      {s.refund && Number(s.refund.amount) > 0 && <Row k="Refunded" v={`${N2(s.refund.amount)} by ${METHOD[s.refund.method] || s.refund.method}`} />}
    </div>
  );
  if (a.kind === 'refund') return (
    <div className="stack" style={{ gap: 4, ...box }}>
      <Row k="Refund" v={<b>{N2(s.amount)}</b>} /><Row k="Paid by" v={METHOD[s.method] || s.method} />{s.reason && <Row k="Reason" v={s.reason} />}
    </div>
  );
  if (a.kind === 'payout') return (
    <div className="stack" style={{ gap: 4, ...box }}>
      <Row k="To" v={`${s.account_name} · ${s.bank_name || ''} ${s.account_number || ''}`} />
      <Row k="Amount" v={<b>{N2(s.amount)}</b>} />
      {(s.vendor || s.customer) && <Row k={s.vendor ? 'Supplier' : 'Customer'} v={s.vendor || s.customer} />}
      {s.narration && <Row k="Narration" v={s.narration} />}
    </div>
  );
  if (a.kind === 'payout_batch') return (
    <div className="stack" style={{ gap: 4, ...box }}>
      {(Array.isArray(s.payments) ? s.payments : []).slice(0, 20).map((p: any, i: number) => (
        <Row key={i} k={`${p.account_name} · ${p.bank_name || ''} ${p.account_number}`} v={N2(p.amount)} />
      ))}
      {Number(s.rows) > 20 && <div className="faint" style={{ fontSize: 12 }}>And {Number(s.rows) - 20} more.</div>}
      {Number(s.wht) > 0 && <Row k="WHT deducted" v={N2(s.wht)} />}
      <Row k="Transfer fees, about" v={N2(s.fees)} />
      <Row k="Total" v={<b>{N2(s.total)}</b>} />
    </div>
  );
  if (a.kind === 'recurring') return (
    <div className="stack" style={{ gap: 4, ...box }}>
      {(Array.isArray(s.lines) ? s.lines : []).map((l: any, i: number) => <Row key={i} k={`${Number(l.qty)} × ${l.description}${l.once ? ' (first invoice only)' : ''}`} v={N2(Number(l.qty) * Number(l.unit_price))} />)}
      <Row k="Each invoice, before VAT" v={<b>{N2(s.amount_before_vat)}</b>} />
      <Row k="How often" v={`${FREQ[s.frequency] || s.frequency}, on day ${s.day_of_month}`} />
      <Row k="From" v={`${fmtDay(s.start_date)}${s.end_date ? ` to ${fmtDay(s.end_date)}` : ''}`} />
      <Row k="Sent to the customer" v={s.auto_send ? 'Yes, as each is issued' : 'No'} />
    </div>
  );
  return null;
}
