import { useEffect, useMemo, useState } from 'react';
import { NavLink, Route, Routes, useLocation, useNavigate } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession } from '../state/session';
import { useCounts, useTransfers } from '../lib/queries';
import { buildItems, qtyLabel } from '../lib/domain';
import { fmtTime, when } from '../lib/format';
import { Icon } from '../components/Icon';
import { Spinner, Thumb } from '../components/ui';
import { InstallBanner } from '../components/InstallBanner';
import { store } from '../lib/pwa';
import { discard, enqueue, retry, useQueue, type Op } from './queue';
import { BranchChip, MCtx, MTop, QueueBanner, useM } from './ctx';
import ScanScreen from './Scan';
import SellScreen from './Sell';
import ReceiveScreen from './ReceivePhone';
import { CountList, CountSheet } from './CountPhone';
import ChatScreen from './ChatPhone';
import IssueScreen from './IssuePhone';
import { TillScreen } from './TillPhone';
import { AddScreen } from './AddPhone';
import { useVatRate } from '../lib/vat';

export default function MobileApp() {
  // The VAT rule book, so every VAT figure and label on the screens uses the rate on its own date.
  useVatRate();
  const { data: inv, isLoading } = useInventory();
  const { orgId } = useSession();
  const queue = useQueue(orgId);
  const key = 'counta.m.loc.' + orgId;
  const [loc, setLocState] = useState<string>(() => { try { return localStorage.getItem(key) || ''; } catch { return ''; } });
  const location = useLocation();
  useEffect(() => {
    if (!inv) return;
    if (!loc || !inv.locations.some((l) => l.id === loc)) setLocState(inv.me.location_id || inv.locations.find((l) => l.is_main)?.id || inv.locations[0]?.id || '');
  }, [inv, loc]);
  useEffect(() => { document.title = 'Counta · phone'; }, []);
  const qc = useQueryClient();
  // What the phone just posted changes stock, counts and jobs, so fetch them fresh.
  useEffect(() => {
    if (queue.lastSync) for (const k of ['inv', 'jobs', 'counts', 'transfers', 'ledger', 'activity']) void qc.invalidateQueries({ queryKey: [k] });
  }, [queue.lastSync?.at]); // eslint-disable-line react-hooks/exhaustive-deps
  const setLoc = (l: string) => { setLocState(l); try { localStorage.setItem(key, l); } catch { /* ignore */ } };
  const value = useMemo(() => ({ loc, setLoc, queue }), [loc, queue]); // eslint-disable-line react-hooks/exhaustive-deps
  if (isLoading && !inv) return <div className="m-shell" style={{ display: 'grid', placeItems: 'center' }}><Spinner /></div>;
  if (!inv) return <div className="m-shell" style={{ display: 'grid', placeItems: 'center', padding: 24, textAlign: 'center' }}>Could not load your business. Connect to data once so the phone can save a copy.</div>;
  const tabs: [string, string, string, boolean][] = [
    ['/m', 'Today', 'house', true],
    ['/m/scan', 'Scan', 'scan', true],
    ['/m/till', 'Sell', 'receipt', can(inv, 'record_sales')],
    ['/m/receive', 'Receive', 'camera', can(inv, 'receive_stock')],
    ['/m/count', 'Count', 'list', can(inv, 'count_stock')],
    ['/m/chat', 'Martina', 'martina', true],
  ];
  const shown = tabs.filter((t) => t[3]);
  const path = location.pathname;
  return (
    <MCtx.Provider value={value}>
      <div className="m-shell">
        <div className="m-body">
          <Routes>
            <Route index element={<Today />} />
            <Route path="scan" element={<ScanScreen />} />
            <Route path="sell" element={<SellScreen />} />
            <Route path="till" element={<TillScreen />} />
            <Route path="add" element={<AddScreen />} />
            <Route path="receive" element={<ReceiveScreen />} />
            <Route path="count" element={<CountList />} />
            <Route path="count/:id" element={<CountSheet />} />
            <Route path="chat" element={<ChatScreen />} />
            <Route path="issue" element={<IssueScreen />} />
          </Routes>
        </div>
        <nav className="m-tabs" style={{ gridTemplateColumns: `repeat(${shown.length}, 1fr)` }}>
          {shown.map(([to, label, icon]) => {
            const on = to === '/m' ? path === '/m' || path === '/m/' : path.startsWith(to) || (to === '/m/till' && path.startsWith('/m/sell'));
            return <NavLink key={to} to={to} end={to === '/m'} className={'m-tab' + (on ? ' on' : '')}><Icon name={icon} size={20} color={on ? '#0072F5' : '#6B7280'} />{label}</NavLink>;
          })}
        </nav>
      </div>
    </MCtx.Provider>
  );
}

function OpRow({ op, who }: { op: Op; who: string }) {
  const dot = op.status === 'posted' ? '#15803D' : op.status === 'failed' ? '#DC2626' : '#F59E0B';
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '11px 0', borderBottom: '1px solid #F3F4F6' }}>
      <span style={{ width: 8, height: 8, borderRadius: 4, background: dot, flex: 'none' }} />
      <div className="grow">
        <div style={{ fontSize: 13, fontWeight: 600 }} className="ellipsis">{op.label} · {op.detail}</div>
        <div className="faint" style={{ fontSize: 11 }}>{fmtTime(op.created_at)} · {who}{op.result ? ' · ' + op.result : ''}</div>
        {op.status === 'failed' && <div style={{ fontSize: 11, color: '#DC2626', marginTop: 2 }}>{op.error}</div>}
      </div>
      {op.status === 'posted' && <span style={{ fontSize: 11, color: '#15803D', fontWeight: 600 }}>Posted</span>}
      {(op.status === 'queued' || op.status === 'posting') && <span className="faint" style={{ fontSize: 11 }}>{op.status === 'posting' ? 'Posting…' : 'Queued'}</span>}
      {op.status === 'failed' && <span className="row" style={{ gap: 4 }}><button className="btn btn-xs btn-secondary" onClick={() => retry(op.id)}>Retry</button><button className="btn btn-xs btn-ghost" onClick={() => discard(op.id)}>Drop</button></span>}
    </div>
  );
}

function Today() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const { loc, queue } = useM();
  const nav = useNavigate();
  const counts = useCounts();
  const transfers = useTransfers();
  const items = useMemo(() => (inv ? buildItems(inv, loc || 'ALL') : []), [inv, loc]);
  if (!inv) return null;
  const me = inv.me;
  const first = me.display_name.split(' ')[0];
  const hour = Number(new Date().toLocaleString('en-GB', { hour: '2-digit', hour12: false, timeZone: 'Africa/Lagos' }));
  const hello = hour < 12 ? 'Good morning' : hour < 17 ? 'Good afternoon' : 'Good evening';
  const branch = inv.locations.find((l) => l.id === loc)?.name || '';
  const mine = (counts.data || []).filter((c) => c.assignee_id === me.id && c.status === 'open');
  const incoming = (transfers.data || []).filter((t) => t.status === 'in_transit' && t.to_location_id === loc);
  const low = items.filter((i) => i.vel > 0 && i.q <= Number(i.reorder_floor)).sort((a, b) => (a.cover ?? 0) - (b.cover ?? 0)).slice(0, 5);
  const ops = [...queue.ops].reverse().slice(0, 12);
  const quick: [string, string, string, boolean][] = [
    ['receipt', 'Scan to sell', '/m/till', can(inv, 'record_sales')],
    ['camera', 'Add a product from photos', '/m/add', can(inv, 'add_items') || can(inv, 'edit_prices')],
    ['scan', 'Scan an item', '/m/scan', true],
    ['mic', 'Talk to record a sale', '/m/sell', can(inv, 'record_sales')],
    ['camera', 'Photograph an invoice', '/m/receive', can(inv, 'receive_stock')],
    ['factory', 'Issue to a job', '/m/issue', can(inv, 'issue_stock')],
    ['martina', 'Ask Martina', '/m/chat', true],
  ];
  return (
    <>
      <MTop title="Today" right={<BranchChip />} />
      <QueueBanner />
      <div className="m-pad stack" style={{ gap: 14, paddingBottom: 24 }}>
        <InstallBanner phone />
        <div>
          <div style={{ fontSize: 20, fontWeight: 600, fontFamily: 'var(--font-brand)' }}>{hello}, {first}</div>
          <div className="muted" style={{ fontSize: 13, marginTop: 2 }}>{inv.org.name}{branch ? ' · ' + branch : ''}</div>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          {quick.filter((q) => q[3]).map(([icon, label, to]) => (
            <button key={to} className="m-card" onClick={() => nav(to)} style={{ display: 'flex', flexDirection: 'column', gap: 10, alignItems: 'flex-start', cursor: 'pointer', font: 'inherit', textAlign: 'left' }}>
              <span style={{ width: 36, height: 36, borderRadius: 10, background: '#F0F7FF', display: 'grid', placeItems: 'center' }}><Icon name={icon} size={18} color="#0072F5" /></span>
              <span style={{ fontSize: 13, fontWeight: 600 }}>{label}</span>
            </button>
          ))}
        </div>
        {mine.length > 0 && (
          <div className="stack" style={{ gap: 8 }}>
            <div className="label">Counts for you</div>
            {mine.map((c) => (
              <button key={c.id} className="m-card row" style={{ cursor: 'pointer', font: 'inherit', textAlign: 'left' }} onClick={() => nav('/m/count/' + c.id)}>
                <Icon name="list" size={18} color="#A16207" /><span className="grow"><span style={{ display: 'block', fontSize: 13, fontWeight: 600 }}>{c.ref} · {c.area}</span><span className="faint" style={{ fontSize: 11 }}>{inv.locations.find((l) => l.id === c.location_id)?.name} · assigned {when(c.created_at)}{c.rejected_count ? ' · recount' : ''}</span></span><Icon name="chevR" size={16} color="#9CA3AF" />
              </button>
            ))}
          </div>
        )}
        {incoming.length > 0 && (can(inv, 'transfer_stock') || can(inv, 'receive_stock')) && (
          <div className="stack" style={{ gap: 8 }}>
            <div className="label">Arriving at {branch}</div>
            {incoming.map((t) => {
              const it = inv.items.find((i) => i.id === t.item_id);
              const queued = queue.ops.some((o) => o.kind === 'transfer_receive' && o.payload.transfer_id === t.id && o.status !== 'failed');
              return (
                <div key={t.id} className="m-card row">
                  <Thumb name={it?.name || 'TR'} path={it?.photo_path} size={36} />
                  <div className="grow"><div style={{ fontSize: 13, fontWeight: 600 }}>{it?.name}</div><div className="faint" style={{ fontSize: 11 }}>{t.ref} · {it ? qtyLabel(it, Number(t.qty)) : t.qty} from {inv.locations.find((l) => l.id === t.from_location_id)?.name}</div></div>
                  <button className="btn btn-xs btn-primary" disabled={queued} onClick={() => enqueue({ org: orgId!, kind: 'transfer_receive', label: 'Transfer in', detail: `${t.ref} · ${it?.name || ''}`, payload: { transfer_id: t.id }, author: me.display_name })}>{queued ? 'Confirmed' : 'Got it'}</button>
                </div>
              );
            })}
          </div>
        )}
        {low.length > 0 && (
          <div className="stack" style={{ gap: 6 }}>
            <div className="label">Running low here</div>
            <div className="m-card" style={{ padding: '4px 12px' }}>
              {low.map((i) => (
                <div key={i.id} className="row" style={{ padding: '8px 0', borderBottom: '1px solid #F3F4F6' }}>
                  <span className="grow" style={{ fontSize: 13 }}>{i.name}</span><span style={{ fontSize: 12, color: '#C2410C', fontWeight: 600 }}>{qtyLabel(i, i.q).split(' · ')[0]}</span>
                </div>
              ))}
            </div>
          </div>
        )}
        <div className="stack" style={{ gap: 2 }}>
          <div className="label">On this phone</div>
          {ops.length ? ops.map((o) => <OpRow key={o.id} op={o} who={o.author} />) : <div className="muted" style={{ fontSize: 13, padding: '8px 0' }}>Sales, counts and invoices you record here show up in this list, with their sync status.</div>}
        </div>
        <button className="m-card row" style={{ cursor: 'pointer', font: 'inherit', textAlign: 'left' }} onClick={() => { store.set('counta-view', 'full'); nav('/home'); }}>
          <Icon name="panel" size={18} color="#0072F5" />
          <span className="grow"><span style={{ display: 'block', fontSize: 13, fontWeight: 600 }}>Open the full app</span><span className="faint" style={{ fontSize: 11 }}>Reports, approvals, reorders, pricing and settings, sized for this phone</span></span>
          <Icon name="chevR" size={16} color="#9CA3AF" />
        </button>
      </div>
    </>
  );
}
