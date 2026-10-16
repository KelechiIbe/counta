import { useMemo, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { rpc } from '../lib/supabase';
import { useAction } from '../lib/queries';
import { useInventory } from '../state/session';
import {
  CATEGORIES, accountName, acct, chartCsv, choicesFor, useAccounts, useItemAccounts, usePostingMap,
  type Account, type PostingRole,
} from '../lib/accounts';
import { Alert, Drawer, Pills, SkeletonRows, XButton, Empty } from './ui';
import { Icon } from './Icon';

const REFRESH = ['postingMap', 'itemAccounts', 'inv', 'ledger', 'activity'];

// Settings: where each kind of stock entry lands in the TaxStreem chart.
export function PostingRules({ owner, onOpenChart }: { owner: boolean; onOpenChart: () => void }) {
  const map = usePostingMap();
  const accounts = useAccounts();
  const { run, busy } = useAction();
  const [pending, setPending] = useState<{ role: PostingRole; code: string } | null>(null);

  return (
    <>
      <div className="ink3" style={{ fontSize: 13, lineHeight: 1.6 }}>
        Counta posts into TaxStreem&apos;s chart of accounts. Each kind of stock entry lands in the account shown here, and the same rules apply on the phone app.
      </div>
      <div className="card" style={{ borderRadius: 12, overflow: 'hidden' }}>
        <div className="tr head shade th" style={{ gridTemplateColumns: 'minmax(180px,1fr) minmax(220px,1.1fr)', padding: '8px 14px' }}><span>Entry</span><span>Account</span></div>
        {map.isLoading && <div style={{ padding: 14 }}><SkeletonRows n={4} /></div>}
        {(map.data || []).map((r) => {
          const choices = choicesFor(accounts.data, r.allowed);
          return (
            <div key={r.role} className="tr" style={{ gridTemplateColumns: 'minmax(180px,1fr) minmax(220px,1.1fr)', padding: '12px 14px', alignItems: 'start' }}>
              <span><span className="ink" style={{ fontWeight: 600 }}>{r.label}</span><span className="faint" style={{ display: 'block', fontSize: 12, marginTop: 2, lineHeight: 1.45 }}>{r.description}</span></span>
              {owner && choices.length > 1 ? (
                <select className="input input-sm" aria-label={r.label} value={pending?.role.role === r.role ? pending.code : r.account_code}
                  onChange={(e) => setPending(e.target.value === r.account_code ? null : { role: r, code: e.target.value })}>
                  {choices.map((a) => <option key={a.code} value={a.code}>{a.code} · {a.name}{a.code === r.default_code ? ' (default)' : ''}</option>)}
                </select>
              ) : (
                <span><span className="mono ink3">{r.account_code}</span> {r.account_name}</span>
              )}
            </div>
          );
        })}
      </div>
      {pending && <PendingRule pending={pending} busy={busy} accounts={accounts.data} onCancel={() => setPending(null)} onDone={() => setPending(null)} run={run} />}
      <div className="row wrap">
        <button className="btn btn-secondary btn-sm" onClick={onOpenChart}><Icon name="book" size={14} />View the chart of accounts</button>
      </div>
    </>
  );
}

function PendingRule({ pending, accounts, busy, onCancel, onDone, run }: {
  pending: { role: PostingRole; code: string }; accounts: Account[] | undefined; busy: boolean;
  onCancel: () => void; onDone: () => void; run: ReturnType<typeof useAction>['run'];
}) {
  const { data: inv } = useInventory();
  const qc = useQueryClient();
  const moves = pending.role.role === 'inventory' || pending.role.role === 'goods_in_transit';
  async function confirm() {
    const r = await run(() => rpc<any>('set_posting_rule', { p_org: inv!.org.id, p_role: pending.role.role, p_code: pending.code }), {
      ok: (x) => `${pending.role.label} now posts to ${x.account_code} ${x.account_name}${x.journal_ref ? ` · balance moved in ${x.journal_ref}` : ''}`,
      invalidate: REFRESH,
    });
    if (r) { await qc.invalidateQueries({ queryKey: ['postingMap'] }); onDone(); }
  }
  return (
    <Alert kind="blue" icon="info">
      <div style={{ lineHeight: 1.5 }}>
        Change <b>{pending.role.label.toLowerCase()}</b> from {pending.role.account_code} {pending.role.account_name} to <b>{pending.code} {accountName(accounts, pending.code)}</b>?
        {moves ? ' The balance already in the old account moves across in one reclass journal.' : ' Entries already posted stay where they are; new entries use the new account.'}
      </div>
      <div className="row" style={{ marginTop: 10 }}>
        <button className="btn btn-primary btn-sm" disabled={busy} onClick={confirm}>Save rule</button>
        <button className="btn btn-ghost btn-sm" onClick={onCancel}>Cancel</button>
      </div>
    </Alert>
  );
}

// The full TaxStreem chart, laid out like Accounting > Chart of accounts.
export function ChartDrawer({ onClose }: { onClose: () => void }) {
  const accounts = useAccounts();
  const map = usePostingMap();
  const [cat, setCat] = useState<string>('all');
  const [q, setQ] = useState('');
  const used = useMemo(() => {
    const m = new Map<string, string[]>();
    for (const r of map.data || []) m.set(r.account_code, [...(m.get(r.account_code) || []), r.label]);
    return m;
  }, [map.data]);
  const all = accounts.data || [];
  const counts = useMemo(() => Object.fromEntries(CATEGORIES.map((c) => [c, all.filter((a) => a.category === c).length])), [all]);
  const needle = q.trim().toLowerCase();
  const rows = all.filter((a) => (cat === 'all' || a.category === cat)
    && (!needle || a.code.includes(needle) || a.name.toLowerCase().includes(needle)));
  const depth = (a: Account) => (a.parent_code == null ? 0 : a.is_group ? 1 : 2);

  function exportCsv() {
    const blob = new Blob([chartCsv(rows.length ? rows : all)], { type: 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const el = document.createElement('a');
    el.href = url; el.download = 'taxstreem-chart-of-accounts.csv'; el.click();
    setTimeout(() => URL.revokeObjectURL(url), 2000);
  }

  return (
    <Drawer onClose={onClose} width={720}>
      <div className="drawer-hd">
        <span style={{ width: 44, height: 44, borderRadius: 12, background: '#F0F7FF', display: 'grid', placeItems: 'center', flex: 'none' }}><Icon name="book" size={20} color="#0072F5" /></span>
        <div className="grow">
          <div className="drawer-title">Chart of accounts</div>
          <div className="muted" style={{ fontSize: 13, marginTop: 2 }}>TaxStreem standard chart · {all.filter((a) => !a.is_group).length} posting accounts under {all.filter((a) => a.is_group).length} headers</div>
        </div>
        <button className="btn btn-secondary btn-sm" onClick={exportCsv} disabled={!all.length}><Icon name="download" size={14} />Export CSV</button>
        <XButton onClick={onClose} />
      </div>
      <div style={{ padding: '14px 24px 0', display: 'flex', flexDirection: 'column', gap: 12 }}>
        <Pills value={cat} onChange={setCat} options={[{ id: 'all', label: 'All account types', count: all.length }, ...CATEGORIES.map((c) => ({ id: c, label: c, count: counts[c] }))]} />
        <input className="input input-sm" placeholder="Search by code or name" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search accounts" />
      </div>
      <div className="drawer-body" style={{ paddingTop: 12 }}>
        {accounts.isLoading ? <SkeletonRows n={8} /> : !rows.length ? <Empty>No account matches “{q}”.</Empty> : (
          <div className="card" style={{ borderRadius: 12, overflow: 'hidden' }}>
            <div className="tr head shade th" style={{ gridTemplateColumns: '90px 1fr 110px', padding: '8px 14px' }}><span>Account code</span><span>Account name</span><span>Normal balance</span></div>
            {rows.map((a) => (
              <div key={a.code} className="tr" style={{ gridTemplateColumns: '90px 1fr 110px', padding: '9px 14px', background: a.is_group && depth(a) === 0 ? '#FAFAFA' : undefined }}>
                <span className="mono ink3" style={{ fontWeight: a.is_group ? 700 : 400 }}>{a.code}</span>
                <span style={{ paddingLeft: depth(a) * 14, fontWeight: a.is_group ? 600 : 400 }}>
                  {a.name}
                  {used.has(a.code) && <span className="chip t-blue" style={{ marginLeft: 8, fontSize: 10 }} title={used.get(a.code)!.join(', ')}>Counta · {used.get(a.code)!.join(', ').toLowerCase()}</span>}
                </span>
                <span className="ink3">{a.normal_balance === 'credit' ? 'Credit' : 'Debit'}</span>
              </div>
            ))}
          </div>
        )}
      </div>
    </Drawer>
  );
}

// Item drawer: which inventory account this item's stock sits in.
export function ItemAccountCard({ itemId, itemName }: { itemId: string; itemName: string }) {
  const { data: inv } = useInventory();
  const map = usePostingMap();
  const accounts = useAccounts();
  const overrides = useItemAccounts();
  const { run, busy } = useAction();
  const [choice, setChoice] = useState<string | null>(null);
  if (!inv) return null;
  const owner = inv.me.role === 'owner';
  const dflt = acct(map.data, 'inventory');
  const own = overrides.data?.[itemId] || null;
  const current = own || dflt.code;
  const role = map.data?.find((r) => r.role === 'inventory');
  const choices = role ? choicesFor(accounts.data, role.allowed) : [];
  const value = choice ?? (own || '');

  async function save() {
    const r = await run(() => rpc<any>('set_item_inventory_account', { p_item: itemId, p_code: value || null }), {
      ok: (x) => `${itemName} now sits in ${x.account_code} ${x.account_name}${x.journal_ref ? ` · stock value moved in ${x.journal_ref}` : ''}`,
      invalidate: REFRESH,
    });
    if (r) setChoice(null);
  }

  return (
    <div className="card" style={{ padding: 14, borderRadius: 12 }}>
      <div className="mini-label">Inventory account</div>
      <div style={{ fontSize: 14, marginTop: 6 }}><span className="mono ink3">{current}</span> {accountName(accounts.data, current)}{!own && <span className="faint" style={{ fontSize: 12 }}> · business default</span>}</div>
      {owner && choices.length > 1 && (
        <div className="row wrap" style={{ marginTop: 10, gap: 8 }}>
          <select className="input input-sm" style={{ maxWidth: 340 }} aria-label="Inventory account" value={value} onChange={(e) => setChoice(e.target.value)}>
            <option value="">Business default ({dflt.code} {dflt.name})</option>
            {choices.map((a) => <option key={a.code} value={a.code}>{a.code} · {a.name}</option>)}
          </select>
          {choice !== null && choice !== (own || '') && <button className="btn btn-primary btn-sm" disabled={busy} onClick={save}>Move to this account</button>}
        </div>
      )}
      <div className="muted" style={{ fontSize: 12, marginTop: 8, lineHeight: 1.45 }}>Raw materials, work in progress, consumables and chemicals can each sit in their own TaxStreem inventory account. Moving an item posts one reclass journal for the stock it holds.</div>
    </div>
  );
}
