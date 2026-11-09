// Waiting for a POS terminal: the till has sent the sale's amount to a Moniepoint terminal and waits for Moniepoint to say it was
// paid. A decline, a timeout or a terminal that never got the amount can be sent again, to the same terminal or another.
import { useEffect, useRef, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { edge, type PosRequest, type TillTerminal } from '../../lib/api';
import { N2 } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Modal, ModalHead, Spinner } from '../../components/ui';
import { announce } from '../../lib/speech';

const HOW: Record<string, string> = { any: 'card or transfer', card: 'card', transfer: 'transfer' };
export const PAID_HOW: Record<string, string> = { card: 'card', transfer: 'transfer', other: 'POS' };

export function PosWait({ request, saleNumber, terminals, onPaid, onClose, onCancelSale }: {
  request: PosRequest; saleNumber?: string | null; terminals: TillTerminal[]; onPaid: (r: PosRequest) => void; onClose: () => void; onCancelSale?: () => void;
}) {
  const [r, setR] = useState<PosRequest>(request);
  const [busy, setBusy] = useState(false);
  const [term, setTerm] = useState(request.terminal_id);
  const [how, setHow] = useState<PosRequest['pay_method']>(request.pay_method);
  const toast = useToast();
  const qc = useQueryClient();
  const { orgId } = useSession();
  const done = useRef(false);
  const pushed = useRef<string | null>(null);
  // A request the till has just opened goes to its terminal once.
  useEffect(() => {
    if (r.status !== 'creating' || pushed.current === r.id) return;
    pushed.current = r.id;
    let live = true;
    edge<{ request: PosRequest }>('pos', { action: 'push', request_id: r.id }).then((x) => {
      if (!live) return;
      if (x.ok === false || !x.request) toast(x.error || 'Moniepoint did not answer. Try again.', 'err');
      else setR(x.request);
    });
    return () => { live = false; };
  }, [r.id, r.status]); // eslint-disable-line react-hooks/exhaustive-deps
  // Every four seconds while the terminal has it; Moniepoint's webhook usually answers first.
  useEffect(() => {
    if (r.status !== 'sent') return;
    const t = window.setInterval(async () => {
      const x = await edge<{ request: PosRequest }>('pos', { action: 'check', request_id: r.id });
      if (x.request) setR(x.request);
    }, 4000);
    return () => window.clearInterval(t);
  }, [r.id, r.status]);
  useEffect(() => {
    if (r.status === 'paid' && !done.current) {
      done.current = true;
      const amount = Number(r.paid_amount || r.amount);
      void announce('payment_received', { org_id: orgId, request_id: r.id }, `Payment received. ${Math.round(amount).toLocaleString('en-NG')} naira.`);
      void qc.invalidateQueries({ queryKey: ['pos_waiting'] });
      onPaid(r);
    }
  }, [r.status]); // eslint-disable-line react-hooks/exhaustive-deps

  async function again() {
    setBusy(true);
    try {
      const n = await rpc<PosRequest>('pos_retry', { p_request: r.id, p_terminal: term, p_how: how });
      done.current = false;
      setR(n);
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  async function stop() {
    setBusy(true);
    try { setR(await rpc<PosRequest>('pos_cancel', { p_request: r.id })); } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  const ready = terminals.filter((t) => t.ready);
  const over = ['declined', 'failed', 'expired', 'cancelled'].includes(r.status);
  const amount = Number(r.amount);
  return (
    <Modal onClose={onClose} width={460}>
      <ModalHead title="Pay on the terminal" sub={`${saleNumber ? saleNumber + ' · ' : ''}${N2(amount)}`} onClose={onClose} />
      <div className="modal-body" style={{ alignItems: 'stretch' }} data-testid="pos-wait" data-status={r.status}>
        {r.status === 'creating' ? (
          <div className="row" style={{ justifyContent: 'center', padding: 24, gap: 10 }}><Spinner />Sending {N2(amount)} to {r.terminal_name}…</div>
        ) : r.status === 'sent' ? (
          <div style={{ textAlign: 'center', padding: '6px 0' }}>
            <div className="muted" style={{ fontSize: 13 }}>On {r.terminal_name} now</div>
            <div style={{ fontSize: 32, fontWeight: 700, margin: '4px 0 10px' }}>{N2(amount)}</div>
            <div className="muted" style={{ fontSize: 14 }}>
              {r.pay_method === 'transfer' ? 'The terminal shows its account number. Ask the customer to transfer exactly this amount to it.'
                : r.pay_method === 'card' ? 'Ask the customer to tap or insert their card on the terminal.'
                  : 'Ask the customer to tap or insert their card, or to pay by transfer on the terminal.'}
            </div>
            <div className="row" style={{ justifyContent: 'center', gap: 8, color: '#6B7280', fontSize: 13, marginTop: 14 }}><Spinner small />Waiting for {r.provider_name}. Counta says it out loud when it is paid.</div>
          </div>
        ) : r.status === 'paid' ? (
          <Alert kind="green" icon="check">Paid {N2(r.paid_amount || amount)} by {PAID_HOW[r.paid_how || 'other']} on {r.terminal_name}.</Alert>
        ) : (
          <Alert kind={r.status === 'declined' || r.status === 'failed' ? 'red' : 'amber'} icon="alert">
            {r.status === 'declined' ? `Declined${r.response_message ? `: ${r.response_message}` : ''}. Nothing was taken from the customer.`
              : r.status === 'failed' ? (r.error || `${r.provider_name} did not send the amount to the terminal.`)
                : r.status === 'expired' ? 'The terminal did not answer in time. If the customer paid, Counta still finds it when Moniepoint reports it.'
                  : 'Withdrawn here. Cancel it on the terminal too, if it is still showing the amount.'}
          </Alert>
        )}
        {over && (
          <div className="stack" style={{ gap: 8, marginTop: 4 }}>
            <div className="row wrap" style={{ gap: 8 }}>
              <select className="input input-sm" value={term} onChange={(e) => setTerm(e.target.value)} aria-label="Terminal" style={{ flex: 1, minWidth: 160 }}>
                {ready.map((t) => <option key={t.id} value={t.id}>{t.name}{t.here === false ? ' (another branch)' : ''}</option>)}
              </select>
              <select className="input input-sm" value={how} onChange={(e) => setHow(e.target.value as PosRequest['pay_method'])} aria-label="How the customer pays">
                {(['any', 'card', 'transfer'] as const).map((h) => <option key={h} value={h}>{HOW[h][0].toUpperCase() + HOW[h].slice(1)}</option>)}
              </select>
            </div>
            <button className="btn btn-primary" disabled={busy || !ready.length} onClick={again}><Icon name="refresh" size={14} color="#fff" />Send it again</button>
          </div>
        )}
      </div>
      <div className="modal-ft">
        {onCancelSale && r.status !== 'paid' && <button className="btn btn-ghost" disabled={busy} onClick={onCancelSale}>Cancel this sale</button>}
        {r.status === 'sent' && <button className="btn btn-ghost" disabled={busy} onClick={stop}>Stop waiting</button>}
        <button className="btn btn-secondary" onClick={onClose}>{r.status === 'paid' ? 'Done' : 'Keep waiting in the background'}</button>
      </div>
    </Modal>
  );
}
