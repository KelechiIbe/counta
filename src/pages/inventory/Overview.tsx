import { useEffect, useMemo, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { useLoc } from '../../shell/AppShell';
import { useCashStory, useNeedsAction, useSuggestions } from '../../shell/needsAction';
import { useCounts, useLedger, useProposals } from '../../lib/queries';
import { buildItems, suAbbr } from '../../lib/domain';
import { K, P, N, when, plural, fmtDay } from '../../lib/format';
import { moveBy, moveItem, moveQty, moveRef, typeLabel, typeTone } from '../../lib/ledger';
import { askMartina, buildContext, localAnswer, type Answer } from '../../lib/martina';
import { Icon } from '../../components/Icon';
import { PeriodPicker } from '../../components/PeriodPicker';
import { ROLLING, presetLabel, useScreenPeriod } from '../../lib/period';
import { Kpi, Label, SkeletonRows, Spinner } from '../../components/ui';
import JournalDrawer from '../../components/JournalDrawer';
import ImportPanel from './ImportPanel';
import { rpc, supabase } from '../../lib/supabase';

function PromptBar() {
  const { data: inv } = useInventory();
  const { loc } = useLoc();
  const nav = useNavigate();
  const { suggestions } = useSuggestions();
  const proposals = useProposals();
  const counts = useCounts();
  const { story } = useCashStory('ALL');
  const [q, setQ] = useState('');
  const [busy, setBusy] = useState(false);
  const [ans, setAns] = useState<Answer | null>(null);
  const items = useMemo(() => (inv ? buildItems(inv, 'ALL') : []), [inv]);
  if (!inv) return null;
  const other = inv.locations.length > 1 ? inv.locations[inv.locations.length - 1] : inv.locations[0];
  const topSug = suggestions[0];
  const chips = [
    `What's running low at ${other?.name || 'the shop'}?`,
    story.weekday ? `Why didn't ${story.weekday}'s cash match?` : 'Does cash match stock this week?',
    'Which items are losing money?',
    topSug ? `Draft a PO for ${topSug.item.name.split(' ').slice(0, 2).join(' ')}` : 'What expires soon?',
  ];
  async function ask(text: string) {
    if (!text.trim() || busy) return;
    setQ(text); setBusy(true); setAns(null);
    const ctx = buildContext(inv!, items, suggestions, proposals.data || [], story, counts.data || []);
    const a = await askMartina(text, ctx, () => localAnswer(text, inv!, items, suggestions, proposals.data || [], story));
    setAns(a); setBusy(false);
  }
  function go() {
    if (!ans) return;
    if (ans.action?.type === 'draft_po') nav('/inventory/reorder', { state: { draft: ans.action.item_id } });
    else nav(ans.route);
  }
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 12, padding: '8px 0 4px' }}>
      <form onSubmit={(e) => { e.preventDefault(); ask(q); }} style={{ width: '100%', maxWidth: 820, display: 'flex', alignItems: 'center', gap: 10, border: '1px solid #E6E6E6', borderRadius: 999, padding: '8px 10px 8px 8px', boxShadow: 'var(--shadow-card)' }}>
        <span style={{ width: 36, height: 36, borderRadius: '50%', background: 'linear-gradient(135deg,#0072F5,#7C3AED 55%,#DB2779)', display: 'grid', placeItems: 'center', flex: 'none' }}><Icon name="sparkles" size={16} color="#fff" /></span>
        <input value={q} onChange={(e) => setQ(e.target.value)} aria-label="Ask Martina about your stock"
          placeholder={`Ask about your stock — how many cartons of ${items[0]?.name.split(' ')[0] || 'Milo'} are left at ${other?.name || 'the shop'}?`}
          style={{ flex: 1, border: 'none', fontSize: 15, color: '#111827', background: 'transparent', minWidth: 0, boxShadow: 'none', outline: 'none' }} />
        <button type="submit" aria-label="Ask" style={{ width: 36, height: 36, borderRadius: '50%', border: 'none', background: '#F0F7FF', display: 'grid', placeItems: 'center', cursor: 'pointer' }}>
          {busy ? <Spinner small /> : <Icon name="send" size={16} color="#0072F5" />}
        </button>
      </form>
      <div className="row wrap" style={{ justifyContent: 'center', gap: 8 }}>
        {chips.map((c) => (
          <button key={c} onClick={() => ask(c)} className="pill" style={{ padding: '8px 14px', color: '#111827' }}>{c}</button>
        ))}
      </div>
      {ans && (
        <div className="rise" style={{ width: '100%', maxWidth: 820, background: '#F0F7FF', border: '1px solid #B9D4FF', borderRadius: 14, padding: '16px 18px', display: 'flex', gap: 14 }}>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 14, fontWeight: 600 }}>{ans.t}</div>
            <div style={{ fontSize: 14, color: '#242527', lineHeight: 1.5, marginTop: 4 }}>{ans.d}</div>
            <div className="row" style={{ marginTop: 12 }}>
              <button className="btn btn-primary btn-sm" onClick={go}>{ans.cta}</button>
              <button className="btn btn-ghost" onClick={() => { setAns(null); setQ(''); }}>Dismiss</button>
              <span className="faint" style={{ fontSize: 11, marginLeft: 'auto' }}>{ans.source === 'ai' ? 'Martina · Gemini' : 'Martina · from your records'}</span>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function EmptyState() {
  const [open, setOpen] = useState(false);
  const { refreshMemberships, setOrgId } = useSession();
  const toast = useToast();
  const nav = useNavigate();
  const qc = useQueryClient();
  const { data: inv } = useInventory();
  const [busy, setBusy] = useState(false);
  async function sample() {
    setBusy(true);
    try {
      const id = await rpc<string>('create_sample_business');
      await refreshMemberships(); setOrgId(id); qc.invalidateQueries();
      toast('Sample business ready · Kelandellen Company Limited'); nav('/inventory');
    } catch (e: any) { toast(e.message, 'err'); } finally { setBusy(false); }
  }
  const canImport = can(inv, 'edit_prices');
  return (
    <>
      <div style={{ border: '1px dashed #D1D5DB', borderRadius: 16, minHeight: 520, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', textAlign: 'center', padding: 40, maxWidth: 1280, margin: '0 auto' }}>
        <div style={{ width: 80, height: 80, borderRadius: '50%', background: '#F3F4F6', display: 'grid', placeItems: 'center' }}><Icon name="package" size={36} color="#6B7280" sw={1.5} /></div>
        <div style={{ fontFamily: 'var(--font-brand)', fontSize: 24, fontWeight: 600, marginTop: 22 }}>Upload an inventory</div>
        <div style={{ fontSize: 16, color: '#4B5563', maxWidth: 520, lineHeight: 1.5, marginTop: 8 }}>Import a spreadsheet of your products and we'll match its columns, then analyse your margins, landed cost, and stock health.</div>
        {canImport ? (
          <button className="btn btn-primary" onClick={() => setOpen(true)} style={{ marginTop: 22, padding: '13px 22px', fontSize: 16, borderRadius: 14, boxShadow: 'var(--shadow-cta)' }}>
            <Icon name="upload" size={18} color="#fff" />Upload inventory
          </button>
        ) : null}
        {canImport ? (
          <button className="btn btn-secondary" onClick={() => nav('/inventory/migrate')} style={{ marginTop: 10 }}>
            <Icon name="truck" size={16} />Moving from QuickBooks, Sage, Zoho, Tally or another system?
          </button>
        ) : <div className="hint" style={{ marginTop: 22 }}>The owner sets up the product list. You will see it here once it is in.</div>}
        <div className="muted" style={{ fontSize: 13, marginTop: 18 }}>
          Want to look around first? <button className="btn-ghost" style={{ color: '#0072F5', cursor: 'pointer', padding: 0, fontSize: 13 }} onClick={sample} disabled={busy}>{busy ? 'Building the sample shop…' : 'Open the sample business'}</button>
        </div>
      </div>
      {open && <ImportPanel onClose={() => setOpen(false)} />}
    </>
  );
}

export default function Overview() {
  const { data: inv } = useInventory();
  const { loc } = useLoc();
  const nav = useNavigate();
  const location = useLocation();
  const { rows } = useNeedsAction();
  const ledger = useLedger(loc, 10);
  const [journal, setJournal] = useState<string | null>(null);
  const voice = useQuery({
    queryKey: ['voicePending', inv?.org.id], enabled: can(inv, 'approve_adjustments'),
    queryFn: async () => (await supabase.from('movements').select('id', { count: 'exact', head: true }).eq('org_id', inv!.org.id).eq('review_status', 'pending')).count || 0,
  });
  useEffect(() => { if (location.hash === '#needs-action') document.getElementById('needs-action')?.scrollIntoView({ behavior: 'smooth' }); }, [location.hash]);
  const items = useMemo(() => (inv ? buildItems(inv, loc) : []), [inv, loc]);
  // Margin and top movers for a period: the last 30 days come with the stock figures; any other period asks the sales report.
  const { orgId } = useSession();
  const [period, setPeriod] = useScreenPeriod(orgId, 'inventory-overview', 'l30', inv?.org.fiscal_year_start || 1);
  const custom = period.preset !== 'l30';
  const sold = useQuery({
    queryKey: ['report', 'sales_by_item', period.from, period.to, loc, orgId], enabled: !!inv && custom, staleTime: 30_000, placeholderData: (p) => p,
    queryFn: () => rpc<{ rows: any[] }>('inventory_report', { p_org: orgId, p_report: 'sales_by_item', p_from: period.from, p_to: period.to,
      p_location: loc === 'ALL' ? null : loc, p_item: null, p_accounts: null }),
  });
  if (!inv) return null;
  if (!inv.items.length) return <EmptyState />;
  const costs = inv.can_see_costs;
  const value = items.reduce((a, i) => a + (i.value || 0), 0);
  const soldRows: any[] = custom ? sold.data?.rows || [] : [];
  const rev = custom ? soldRows.reduce((a, r) => a + Number(r.revenue || 0), 0) : inv.items.reduce((a, i) => a + Number(i.revenue_30), 0);
  const cogs = custom ? soldRows.reduce((a, r) => a + Number(r.cogs || 0), 0) : inv.items.reduce((a, i) => a + Number(i.cogs_30 || 0), 0);
  const span = custom ? (period.preset ? presetLabel(period.preset, inv.org.fiscal_year_start || 1).toLowerCase() : `${fmtDay(period.from)} to ${fmtDay(period.to)}`) : 'last 30 days';
  const gm = rev > 0 ? ((rev - cogs) / rev) * 100 : null;
  const low = items.filter((i) => i.status === 'Low');
  const dead = items.filter((i) => i.status === 'Dead');
  const exp = items.flatMap((i) => i.batchesInScope.filter((b) => b.expiry_date && (Date.parse(b.expiry_date) - Date.parse(inv.today)) / 864e5 <= 30).map((b) => ({ b, i })));
  const expValue = exp.reduce((a, { b, i }) => a + Number(b.qty_remaining) * (i.wac || 0), 0);
  const days = Math.max(1, Math.round((Date.parse(period.to) - Date.parse(period.from)) / 864e5) + 1);
  const top: { id: string; name: string; revenue: number; perDay: number | null; unit: string }[] = custom
    ? soldRows.filter((r) => Number(r.revenue) > 0).sort((a, b) => Number(b.revenue) - Number(a.revenue)).slice(0, 5)
      .map((r) => ({ id: String(r.item_id || r.item), name: String(r.item), revenue: Number(r.revenue), perDay: Number(r.qty) / days, unit: String(r.unit || '') }))
    : [...items].filter((i) => Number(i.revenue_30) > 0).sort((a, b) => Number(b.revenue_30) - Number(a.revenue_30)).slice(0, 5)
      .map((i) => ({ id: i.id, name: i.name, revenue: Number(i.revenue_30), perDay: i.vel, unit: suAbbr(i.selling_unit) }));
  const allRows = [...rows];
  if (voice.data) allRows.push({ key: 'voice', t: `${plural(voice.data, 'voice entry', 'voice entries')} to review`, d: 'Staff still earning trust on voice capture', cta: 'Review', to: '/inventory/locations', icon: 'mic', color: '#0072F5', bg: '#F0F7FF' });
  return (
    <div className="container">
      <PromptBar />
      <div className="card card-pad m-2" style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(170px, 1fr))', gap: 20 }}>
        <Kpi label="Stock value" value={costs ? K(value) : '—'} sub={`${items.length} items · weighted average cost`} color="#111827" />
        <Kpi label={custom ? `Gross margin · ${span}` : 'Gross margin · 30d'} value={costs ? P(gm) : '—'} sub="From actual sales and their cost" color="#15803D" />
        <Kpi label="Low stock" value={String(low.length)} sub={low.map((i) => i.name.split(' ')[0]).slice(0, 4).join(', ') || 'Nothing below floor'} color="#C2410C" />
        <Kpi label="Expiring ≤ 30d" value={plural(exp.length, 'batch', 'batches')} sub={costs ? K(expValue) + ' at risk' : 'Sell these first'} color="#A16207" />
        <Kpi label="Dead stock" value={costs ? K(dead.reduce((a, i) => a + (i.value || 0), 0)) : String(dead.length)} sub={plural(dead.length, 'item') + ' unmoved 90+ days'} color="#4B5563" />
      </div>
      <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(340px, 1fr))', gap: 20, alignItems: 'start' }}>
        <div className="card card-pad" id="needs-action">
          <Label style={{ marginBottom: 12 }}>Needs action</Label>
          {!allRows.length && <div className="muted" style={{ fontSize: 14, padding: '12px 4px', borderTop: '1px solid #F3F4F6' }}>Nothing is waiting on you. New receipts, counts and price changes will show up here.</div>}
          {allRows.map((a) => (
            <div key={a.key} onClick={() => nav(a.to, { state: a.state })} className="row" role="button" tabIndex={0}
              onKeyDown={(e) => e.key === 'Enter' && nav(a.to, { state: a.state })}
              style={{ gap: 12, padding: '12px 4px', borderTop: '1px solid #F3F4F6', cursor: 'pointer' }}>
              <span style={{ width: 36, height: 36, borderRadius: 10, background: a.bg, display: 'grid', placeItems: 'center', flex: 'none' }}><Icon name={a.icon} size={18} color={a.color} /></span>
              <div className="grow"><div style={{ fontSize: 14, fontWeight: 600 }}>{a.t}</div><div style={{ fontSize: 12, color: '#6B7280', marginTop: 2 }}>{a.d}</div></div>
              <span style={{ fontSize: 13, fontWeight: 600, color: '#0072F5', whiteSpace: 'nowrap' }}>{a.cta}</span>
            </div>
          ))}
        </div>
        <div className="card card-pad">
          <div className="row wrap" style={{ justifyContent: 'space-between', gap: 8, marginBottom: 12 }}>
            <Label>Top movers · {custom ? span : '30-day'} revenue</Label>
            <PeriodPicker value={period} onChange={setPeriod} presets={ROLLING} align="end" label="Sales in" />
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            {!top.length && <div className="muted" style={{ fontSize: 14 }}>{custom && sold.isLoading ? 'Loading…' : `No sales recorded in the ${span}.`}</div>}
            {top.map((t) => (
              <div key={t.id}>
                <div className="row" style={{ justifyContent: 'space-between', fontSize: 13, marginBottom: 5 }}><span style={{ fontWeight: 500 }}>{t.name}</span><span style={{ fontWeight: 600 }}>{K(t.revenue)}</span></div>
                <div className="bar"><div style={{ width: `${Math.round((t.revenue / top[0].revenue) * 100)}%` }} /></div>
                {t.perDay != null && <div style={{ fontSize: 11, color: '#9CA3AF', marginTop: 4 }}>{Math.round(t.perDay * 10) / 10} {t.unit}/day</div>}
              </div>
            ))}
          </div>
        </div>
      </div>
      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="card-hd"><Label>Movement ledger</Label><span style={{ fontSize: 12, color: '#9CA3AF' }}>Append-only · every row links to its journal and source image</span></div>
        <div className="tbl">
          <div className="tr head th rsp" style={{ gridTemplateColumns: '150px 110px minmax(200px,1.4fr) minmax(120px,.8fr) 120px minmax(220px,1.4fr) 140px', minWidth: 1000 }}>
            <span>When</span><span>Type</span><span>Item</span><span>Quantity</span><span className="right">Value</span><span>Reference</span><span>By</span>
          </div>
          {ledger.isLoading && <SkeletonRows n={5} />}
          {(ledger.data || []).map((m) => (
            <div key={m.gid} className={'tr rsp' + (costs && m.journal_ref ? ' click' : '')} onClick={() => costs && m.journal_ref && setJournal(m.journal_ref)}
              style={{ gridTemplateColumns: '150px 110px minmax(200px,1.4fr) minmax(120px,.8fr) 120px minmax(220px,1.4fr) 140px', minWidth: 1000 }}>
              <span className="muted">{when(m.recorded_at)}</span>
              <span><span className={'chip ' + typeTone(m.type)}>{typeLabel(m.type)}</span></span>
              <span className="m-main" style={{ fontWeight: 500 }}>{moveItem(m)}</span>
              <span style={{ color: '#242527' }}>{moveQty(m)}</span>
              <span className="right num" style={{ fontWeight: 600, color: Number(m.value) < 0 ? '#4B5563' : '#111827' }}>{m.value == null ? '—' : N(m.value)}</span>
              <span className="muted ellipsis" title={moveRef(m, inv.locations)}>{moveRef(m, inv.locations)}</span>
              <span className="muted ellipsis">{moveBy(m, inv.locations)}</span>
            </div>
          ))}
          {ledger.data && !ledger.data.length && <div className="muted" style={{ padding: 24, fontSize: 14 }}>No movements yet.</div>}
        </div>
      </div>
      {journal && <JournalDrawer journalRef={journal} onClose={() => setJournal(null)} />}
    </div>
  );
}
