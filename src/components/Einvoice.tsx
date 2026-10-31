// A sale's e-invoice with NRS: where it stands, what to do when NRS refuses it, and the IRN and QR code printed on the
// documents. See docs/e-invoicing.md.
import { useEffect, useRef, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { rpc } from '../lib/supabase';
import { useAction } from '../lib/queries';
import { when } from '../lib/format';
import { qrSvg } from '../lib/labels';
import type { Sale, SaleEinvoice } from '../lib/api';
import { Alert } from './ui';

// The QR code as an SVG, drawn once it is known.
export function useQr(text: string | null | undefined, size = 120) {
  const [svg, setSvg] = useState('');
  useEffect(() => {
    let live = true;
    if (!text) { setSvg(''); return; }
    qrSvg(text, size).then((s) => { if (live) setSvg(s); }).catch(() => setSvg(''));
    return () => { live = false; };
  }, [text, size]);
  return svg;
}

// The stamp on a document: the QR code NRS's MBS 360 app reads, and the IRN.
export function EinvoiceStamp({ irn, qr, signed, size = 96 }: { irn: string; qr?: string | null; signed?: boolean; size?: number }) {
  const svg = useQr(qr, size);
  return (
    <div className="einv-stamp" data-testid="einv-stamp" style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
      {svg && <div aria-label="NRS QR code" style={{ width: size, height: size, flex: 'none' }} dangerouslySetInnerHTML={{ __html: svg }} />}
      <div style={{ fontSize: 11, lineHeight: 1.45, minWidth: 0 }}>
        <div style={{ fontWeight: 600 }}>NRS e-invoice{signed ? ', signed by NRS' : ''}</div>
        <div style={{ fontFamily: 'ui-monospace, Menlo, monospace', wordBreak: 'break-all' }}>IRN {irn}</div>
        <div style={{ opacity: 0.75 }}>Scan with NRS's MBS 360 app to check it.</div>
      </div>
    </div>
  );
}

// A sale shows its stamp once it may reach the buyer: a cleared sale when NRS has signed it, a reported one at once.
export const showStamp = (e?: SaleEinvoice | { irn?: string | null; qr?: string | null; state?: string; kind?: string; signed?: boolean } | null) =>
  !!e && !!e.irn && ((e as any).signed === true || e.state === 'signed' || (e.kind === 'report' && ['waiting', 'sending'].includes(String(e.state))));

// Held from the buyer: cleared and not signed yet.
export const heldFromBuyer = (e?: SaleEinvoice | null) => !!e && e.kind === 'clear' && e.state !== 'signed';

export function nrsChip(status?: string | null) {
  if (!status) return null;
  const c: Record<string, [string, string]> = { signed: ['t-green', 'NRS signed'], waiting: ['t-amber', 'NRS waiting'], sending: ['t-amber', 'NRS waiting'],
    refused: ['t-red', 'NRS refused'], stopped: ['t-grey', 'Not sent'] };
  const [tone, label] = c[status] || ['t-grey', status];
  return <span className={'chip ' + tone} style={{ marginLeft: 4 }} data-testid="nrs-chip">{label}</span>;
}

// A signed sale to a business or government, sent to the buyer's access point through NRS (part 3).
const BUYER_WORDS: Record<string, string> = {
  due: 'Going to the buyer through NRS.', sending: 'Going to the buyer through NRS.', transmitting: 'NRS is sending it to the buyer.',
  transmitted: 'Delivered to the buyer through NRS.', acknowledged: 'The buyer\'s access point has it.', failed: 'NRS could not deliver it to the buyer.',
};
function BuyerDelivery({ sale, b, canAct }: { sale: Sale; b: NonNullable<SaleEinvoice['buyer']>; canAct: boolean }) {
  const qc = useQueryClient();
  const { run, busy } = useAction();
  const moving = ['due', 'sending', 'transmitting'].includes(b.state);
  // While it is on its way, ask again every three seconds, for a minute.
  useEffect(() => {
    if (!moving) return;
    let n = 0;
    const t = window.setInterval(() => { n += 1; qc.invalidateQueries({ queryKey: ['sale', sale.id] }); if (n >= 20) window.clearInterval(t); }, 3000);
    return () => window.clearInterval(t);
  }, [b.state, sale.id]); // eslint-disable-line react-hooks/exhaustive-deps
  const words = BUYER_WORDS[b.state] || b.state;
  if (b.state === 'failed') {
    return (
      <Alert kind="amber" icon="alert">
        <div data-testid="einv-buyer" data-state={b.state} style={{ wordBreak: 'break-word' }}>{words}{b.note && !/^NRS could not deliver/.test(b.note) ? ` ${b.note}` : ''}</div>
        {canAct && <div style={{ marginTop: 8 }}><button className="btn btn-secondary btn-sm" disabled={busy}
          onClick={() => run(() => rpc('einvoice_send_to_buyer', { p_sale: sale.id }), { ok: `${sale.number} is going to the buyer again`, invalidate: ['sale', 'sales', 'einvoice'] })}>Send to the buyer again</button></div>}
      </Alert>
    );
  }
  return (
    <div className="row" style={{ gap: 8, fontSize: 13 }} data-testid="einv-buyer" data-state={b.state}>
      <span className={'chip ' + (b.state === 'acknowledged' || b.state === 'transmitted' ? 't-green' : 't-amber')}>{b.state === 'acknowledged' ? 'Received' : b.state === 'transmitted' ? 'Delivered' : 'On its way'}</span>
      {/* NRS's reason for a retry, unless it is TaxStreem's own set-up (the APP keys), which the business cannot change. */}
      <span className="muted" style={{ wordBreak: 'break-word' }}>{words}{moving && b.note && !/^TaxStreem's access point keys/.test(b.note) ? ` ${b.note}` : ''}{!moving && b.at ? ` ${when(b.at)}` : ''}</span>
    </div>
  );
}

// Where the sale stands with NRS, kept fresh while NRS is still answering.
export function EinvoiceStatus({ sale, canAct = true }: { sale: Sale; canAct?: boolean }) {
  const e = sale.einvoice;
  const qc = useQueryClient();
  const { run, busy } = useAction();
  const waiting = !!e && ['waiting', 'sending'].includes(e.state);
  // While NRS is checking a cleared sale (or the QR code is being made), ask again every two seconds, for a minute and a half.
  useEffect(() => {
    if (!e || !waiting || (e.kind === 'report' && e.qr)) return;
    let n = 0;
    const t = window.setInterval(() => {
      n += 1;
      qc.invalidateQueries({ queryKey: ['sale', sale.id] });
      if (n >= 45) window.clearInterval(t);
    }, 2000);
    return () => window.clearInterval(t);
  }, [e?.state, e?.kind, e?.qr, sale.id]); // eslint-disable-line react-hooks/exhaustive-deps
  // Once NRS has answered, the list of sales and the settings' count catch up too.
  const was = useRef(e?.state);
  useEffect(() => {
    if (was.current && was.current !== e?.state) ['sales', 'einvoice'].forEach((k) => qc.invalidateQueries({ queryKey: [k] }));
    was.current = e?.state;
  }, [e?.state]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!e) return null;
  const done = { invalidate: ['sale', 'sales', 'einvoice'] };
  const retrying = waiting && e.tries > 0 && e.note;
  return (
    <div className="stack" style={{ gap: 8 }} data-testid="einv-sale" data-state={e.state} data-kind={e.kind}>
      {waiting && e.kind === 'clear' && (
        <Alert kind="yellow" icon="clock">
          {e.held ? 'Waiting for NRS to sign it. It is issued, and can go to the customer, once NRS signs it.' : 'Waiting for NRS to sign it before it goes to the customer.'}
          {retrying ? <div style={{ marginTop: 4, fontSize: 13 }}>{e.note}{e.next_try_at ? ` Next try ${when(e.next_try_at)}.` : ''}</div> : null}
          {e.held && e.state === 'waiting' && canAct && (
            <div style={{ marginTop: 8 }}><button className="btn btn-secondary btn-sm" disabled={busy}
              onClick={() => run(() => rpc('einvoice_take_back', { p_sale: sale.id }), { ok: `${sale.number} taken back to change`, ...done })}>Take it back to change</button></div>
          )}
        </Alert>
      )}
      {waiting && e.kind === 'report' && (
        <Alert kind="blue" icon="info">
          Goes to NRS with the next batch, within five minutes. NRS expects it within 24 hours.
          {retrying ? <div style={{ marginTop: 4, fontSize: 13 }}>{e.note}</div> : null}
        </Alert>
      )}
      {e.state === 'signed' && (
        <Alert kind="green" icon="check">Signed by NRS{e.signed_at ? ` ${when(e.signed_at)}` : ''}.{e.pay_status === 'PAID' ? ' NRS knows it is paid.' : ''}</Alert>
      )}
      {e.state === 'signed' && e.buyer && <BuyerDelivery sale={sale} b={e.buyer} canAct={canAct} />}
      {e.state === 'refused' && (
        <Alert kind="red" icon="alert">
          <div style={{ wordBreak: 'break-word' }}>{/^(NRS refused|Not sent)/.test(e.note || '') ? e.note : `NRS refused it. ${e.note || ''}`}</div>
          {e.held
            ? <div style={{ marginTop: 4, fontSize: 13 }}>It is a draft again: put it right, then issue it again.</div>
            : canAct && <div style={{ marginTop: 8 }}><button className="btn btn-secondary btn-sm" disabled={busy}
                onClick={() => run(() => rpc('einvoice_send_again', { p_sale: sale.id }), { ok: `${sale.number} sent to NRS again`, ...done })}>Send to NRS again</button>
                <span className="faint" style={{ fontSize: 12, marginLeft: 8 }}>Put the customer's details right first. The amounts can only change by voiding it.</span></div>}
        </Alert>
      )}
      {e.state === 'stopped' && <div className="faint" style={{ fontSize: 12 }}>Not sent to NRS. {e.note}</div>}
      {e.irn && showStamp(e) && <EinvoiceStamp irn={e.irn} qr={e.qr} signed={e.state === 'signed'} />}
    </div>
  );
}
