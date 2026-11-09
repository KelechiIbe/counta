// POS payments nobody rang up, held in suspense until a person says what each was: a sale or invoice waiting for that amount,
// a customer paying on account, a till sale with no items, or something else (the owner's own money, a loan).
import { useMemo, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { useChart, type Customer, type PosTxn } from '../../lib/api';
import { N2, when } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert } from '../../components/ui';
import { AccountPicker, type PickOption } from '../../components/AccountPicker';
import { forBankLine, type ChartAccount } from '../../lib/accountHints';
import { CustomerPicker } from '../sell/common';

const KIND: Record<string, string> = { card: 'Card', transfer: 'Transfer', other: 'POS' };
// Accounts a POS payment can be "something else" for: not a bank, cash, stock, receivables, payables or system account.
const NOT_FOR_POS = /^(10|12|9|1101|2101|2107)/;

export function PosToMatch({ rows }: { rows: PosTxn[] }) {
  const chart = useChart();
  const accounts = useMemo(() => forBankLine((chart.data?.accounts || []) as ChartAccount[]).filter((a) => !NOT_FOR_POS.test(a.code)), [chart.data]);
  if (!rows.length) return null;
  return (
    <div className="stack" style={{ gap: 10 }}>
      <Alert kind="amber" icon="info">These were paid on your POS terminals with no sale rung up in Counta. Until you say what each was, the money waits in suspense in the books.</Alert>
      {rows.map((r) => <MatchRow key={r.id} r={r} accounts={accounts} />)}
    </div>
  );
}

function MatchRow({ r, accounts }: { r: PosTxn; accounts: ChartAccount[] }) {
  const toast = useToast();
  const qc = useQueryClient();
  const [mode, setMode] = useState<'customer' | 'account' | null>(null);
  const [customer, setCustomer] = useState<Customer | null>(null);
  const [code, setCode] = useState('');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const options: PickOption[] = useMemo(() => {
    const pick = (re: RegExp, why: string) => accounts.find((a) => re.test(a.name))?.code;
    return [
      { code: pick(/director|owner|proprietor/i, '') || '', why: "The owner's own money paid into the business" },
      { code: pick(/loan/i, '') || '', why: 'Money lent to the business' },
      { code: pick(/other income|sundry income|miscellaneous income/i, '') || '', why: 'Income that is not a sale' },
    ].filter((o) => o.code);
  }, [accounts]);
  async function assign(p: Record<string, unknown>, done: string) {
    setBusy(true);
    try {
      await rpc('pos_assign', { p_txn: r.id, p: { ...p, note: note.trim() || null } });
      toast(done);
      await Promise.all(['pos_overview', 'pos_match', 'sales', 'sale', 'customers', 'inbox'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <div className="card card-pad stack" style={{ gap: 10 }} data-testid="pos-match" data-ref={r.transaction_ref}>
      <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-start', gap: 10 }}>
        <div style={{ minWidth: 0 }}>
          <div style={{ fontWeight: 600 }}>{KIND[r.kind]} on {r.terminal_name || 'a terminal'}</div>
          <div className="faint" style={{ fontSize: 12, marginTop: 2 }}>{when(r.occurred_at)} · {r.provider_name} {r.transaction_ref}{r.payer ? ` · from ${r.payer}` : ''}</div>
          {r.note && <div style={{ fontSize: 13, color: '#B45309', marginTop: 4 }}>{r.note}</div>}
        </div>
        <b className="num" style={{ color: '#15803D', whiteSpace: 'nowrap' }}>+{N2(r.amount)}</b>
      </div>
      <div className="row wrap" style={{ gap: 6 }}>
        {(r.candidates || []).map((c) => (
          <button key={c.id} className="btn btn-secondary btn-sm" disabled={busy} onClick={() => assign({ sale_id: c.id }, `Matched to ${c.number}`)}>
            <Icon name="check" size={13} />{c.number} · {c.customer}
          </button>
        ))}
        <button className="btn btn-secondary btn-sm" disabled={busy} onClick={() => assign({ as: 'till_sale' }, 'Recorded as a till sale')}>A sale I did not ring up</button>
        <button className={'btn btn-sm ' + (mode === 'customer' ? 'btn-primary' : 'btn-secondary')} disabled={busy} onClick={() => setMode(mode === 'customer' ? null : 'customer')}>A customer paying their account</button>
        <button className={'btn btn-sm ' + (mode === 'account' ? 'btn-primary' : 'btn-secondary')} disabled={busy} onClick={() => setMode(mode === 'account' ? null : 'account')}>Something else</button>
      </div>
      {mode === 'customer' && (
        <div className="row wrap" style={{ gap: 8, alignItems: 'center' }}>
          <div style={{ flex: 1, minWidth: 220 }}><CustomerPicker value={customer} onChange={(c) => setCustomer(c)} allowNew={false} walkIn={false} placeholder="Which customer paid?" /></div>
          <button className="btn btn-primary btn-sm" disabled={busy || !customer} onClick={() => customer && assign({ customer_id: customer.id }, `Recorded as ${customer.name}'s payment`)}>Save</button>
        </div>
      )}
      {mode === 'account' && (
        <div className="stack" style={{ gap: 8 }}>
          <AccountPicker accounts={accounts} options={options} value={code} onChange={setCode} disabled={busy} />
          <div className="row wrap" style={{ gap: 8 }}>
            <input className="input input-sm" style={{ flex: 1, minWidth: 200 }} value={note} onChange={(e) => setNote(e.target.value)} placeholder="What was it? (kept with the entry)" aria-label="What was it" />
            <button className="btn btn-primary btn-sm" disabled={busy || !code} onClick={() => assign({ account: code }, 'Saved')}>Save</button>
          </div>
        </div>
      )}
    </div>
  );
}
