// Journals: every entry in the books, who posted it and on what evidence; manual journals (balanced, with a reason) and
// reversals. Posted journals are never edited.
import { useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { must, rpc, supabase } from '../../lib/supabase';
import { money, today, useChart, useCustomers, useBills } from '../../lib/api';
import { N2, fmtDay } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { PeriodPicker } from '../../components/PeriodPicker';
import { useScreenPeriod } from '../../lib/period';
import { Alert, Drawer, Empty, Field, Modal, ModalHead, SkeletonRows } from '../../components/ui';
import JournalDrawer from '../../components/JournalDrawer';

const ORIGIN: Record<string, string> = { system: 'Counta', ai: 'Atlas', manual: 'By hand', import: 'Imported' };

export default function Journals() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const [q, setQ] = useState('');
  const [period, setPeriod] = useScreenPeriod(orgId, 'journals', 'all', inv?.org.fiscal_year_start || 1);
  const from = period.preset === 'all' ? '' : period.from;
  const to = period.preset === 'all' ? '' : period.to;
  const [origin, setOrigin] = useState('');
  const [open, setOpen] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const [reversing, setReversing] = useState<any>(null);
  const [reason, setReason] = useState('');
  const list = useQuery({
    queryKey: ['journals', orgId, from, to, origin],
    enabled: !!orgId && !!inv?.can_see_costs,
    queryFn: () => {
      let x = supabase.from('journals').select('id, ref, entry_date, memo, source_type, origin, ai_confidence, reversal_of, created_at, journal_lines(account_code, debit, credit)').eq('org_id', orgId!);
      if (from) x = x.gte('entry_date', from);
      if (to) x = x.lte('entry_date', to);
      if (origin) x = x.eq('origin', origin);
      return must<any[]>(x.order('je_no', { ascending: false }).limit(300));
    },
  });
  const rows = useMemo(() => (list.data || []).filter((j) => !q.trim() || `${j.ref} ${j.memo}`.toLowerCase().includes(q.trim().toLowerCase())), [list.data, q]);
  const reversed = new Set((list.data || []).map((j) => j.reversal_of).filter(Boolean));
  if (!inv) return null;
  if (!inv.can_see_costs) return <div className="container"><Alert kind="yellow" icon="shield">Journals show to people who see margins or keep the books.</Alert></div>;
  return (
    <div className="container">
      <div className="row wrap" style={{ justifyContent: 'space-between' }}>
        <div className="row wrap">
          <input className="input input-sm" placeholder="Journal or description" value={q} onChange={(e) => setQ(e.target.value)} style={{ width: 240 }} />
          <PeriodPicker value={period} onChange={setPeriod} label="Journal dates" />
          <select className="input input-sm" style={{ width: 'auto' }} value={origin} onChange={(e) => setOrigin(e.target.value)} aria-label="Posted by"><option value="">Posted by anyone</option><option value="system">Counta</option><option value="ai">Atlas</option><option value="manual">By hand</option></select>
        </div>
        {can(inv, 'keep_books') && <button className="btn btn-primary btn-sm" onClick={() => setCreating(true)}><Icon name="plus" size={14} color="#fff" />Journal</button>}
      </div>
      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="tbl">
          <div className="tr head shade th hide-sm" style={{ gridTemplateColumns: '90px 100px minmax(220px,2fr) 110px 120px 130px', minWidth: 860 }}><span>Journal</span><span>Date</span><span>Description</span><span>By</span><span className="right">Amount</span><span /></div>
          {list.isLoading ? <SkeletonRows n={8} /> : !rows.length ? <div style={{ padding: 20 }}><Empty>No journals match.</Empty></div> : rows.map((j) => {
            const amt = (j.journal_lines || []).reduce((a: number, l: any) => a + Number(l.debit), 0);
            return (
              <div key={j.id} className="tr click" onClick={() => setOpen(j.ref)} style={{ gridTemplateColumns: '90px 100px minmax(220px,2fr) 110px 120px 130px', minWidth: 860 }}>
                <b className="mono">{j.ref}</b><span className="muted">{fmtDay(j.entry_date)}</span>
                <span className="ellipsis">{j.memo}<span className="faint" style={{ display: 'block', fontSize: 11 }}>{(j.journal_lines || []).map((l: any) => l.account_code).filter((v: string, i: number, a: string[]) => a.indexOf(v) === i).join(', ')}</span></span>
                <span className="muted">{ORIGIN[j.origin] || j.origin}{j.ai_confidence != null ? ` · ${Math.round(Number(j.ai_confidence) * 100)}%` : ''}</span>
                <span className="right num">{N2(amt)}</span>
                <span onClick={(e) => e.stopPropagation()}>{j.reversal_of ? <span className="chip t-grey">Reversal</span> : reversed.has(j.id) ? <span className="chip t-red">Reversed</span>
                  : can(inv, 'keep_books') && <button className="btn btn-ghost btn-xs" onClick={() => setReversing(j)}>Reverse</button>}</span>
              </div>
            );
          })}
        </div>
      </div>
      {open && <JournalDrawer journalRef={open} onClose={() => setOpen(null)} />}
      {creating && <NewJournal onClose={() => setCreating(false)} />}
      {reversing && (
        <Modal onClose={() => setReversing(null)} width={460}>
          <ModalHead title={`Reverse ${reversing.ref}`} sub="Posts the same entry the other way round today. The original stays in the books." onClose={() => setReversing(null)} />
          <div className="modal-body"><Field label="Why"><input className="input" autoFocus value={reason} onChange={(e) => setReason(e.target.value)} /></Field></div>
          <div className="modal-ft"><button className="btn btn-danger" disabled={reason.trim().length < 3} onClick={async () => {
            try { await rpc('reverse_journal', { p_journal: reversing.id, p_reason: reason }); toast('Reversed'); setReversing(null); setReason(''); await qc.invalidateQueries({ queryKey: ['journals'] }); }
            catch (e) { toast((e as Error).message, 'err'); }
          }}>Reverse</button></div>
        </Modal>
      )}
    </div>
  );
}

interface JL { key: string; code: string; debit: string; credit: string; memo: string; party_id: string }
function NewJournal({ onClose }: { onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const chart = useChart();
  const customers = useCustomers();
  const bills = useBills({}, true);
  const [date, setDate] = useState(today());
  const [memo, setMemo] = useState('');
  const [evidence, setEvidence] = useState('');
  const [lines, setLines] = useState<JL[]>([0, 1].map(() => ({ key: crypto.randomUUID(), code: '', debit: '', credit: '', memo: '', party_id: '' })));
  const accounts = (chart.data?.accounts || []).filter((a: any) => !a.is_group && a.active);
  const dr = lines.reduce((a, l) => a + (money(l.debit) || 0), 0), cr = lines.reduce((a, l) => a + (money(l.credit) || 0), 0);
  const upd = (k: string, p: Partial<JL>) => setLines((ls) => ls.map((l) => (l.key === k ? { ...l, ...p } : l)));
  const partyFor = (code: string) => (/^(1101|1102|2107)/.test(code) ? 'customer' : /^(2101|2102|1106)/.test(code) ? 'vendor' : null);
  async function post() {
    try {
      await rpc('post_manual_journal', { p_org: orgId, p_date: date, p_memo: memo, p_lines: lines.filter((l) => l.code && (money(l.debit) || money(l.credit))).map((l) => ({
        code: l.code, debit: money(l.debit) || 0, credit: money(l.credit) || 0, memo: l.memo || null, party_type: l.party_id ? partyFor(l.code) : null, party_id: l.party_id || null })),
        p_evidence: evidence ? [{ type: 'note', text: evidence }] : [] });
      toast('Journal posted'); await qc.invalidateQueries({ queryKey: ['journals'] }); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
  }
  return (
    <Drawer onClose={onClose} width={820}>
      <div className="drawer-hd"><div className="grow"><div className="drawer-title">New journal</div><div className="muted" style={{ fontSize: 13 }}>For what nothing else posts: accruals, prepayments, corrections, opening balances. VAT and WHT come only from invoices and bills.</div></div>
        <button className="x-btn" onClick={onClose} aria-label="Close"><Icon name="x" size={18} /></button></div>
      <div className="drawer-body stack" style={{ gap: 12 }}>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '160px 1fr', gap: 10 }}>
          <Field label="Date"><input className="input" type="date" value={date} onChange={(e) => setDate(e.target.value)} /></Field>
          <Field label="What it is for" req><input className="input" value={memo} onChange={(e) => setMemo(e.target.value)} placeholder="Accrued electricity for October" /></Field>
        </div>
        <div className="card" style={{ overflow: 'hidden' }}>
          <div className="tr head shade th" style={{ gridTemplateColumns: 'minmax(220px,2fr) 120px 120px minmax(140px,1fr) 30px' }}><span>Account</span><span className="right">Debit</span><span className="right">Credit</span><span>Line note</span><span /></div>
          {lines.map((l) => (
            <div key={l.key} className="tr" style={{ gridTemplateColumns: 'minmax(220px,2fr) 120px 120px minmax(140px,1fr) 30px', alignItems: 'start' }}>
              <span className="stack" style={{ gap: 4 }}>
                <select className="input input-sm" value={l.code} onChange={(e) => upd(l.key, { code: e.target.value, party_id: '' })}><option value="">Account</option>{accounts.map((a: any) => <option key={a.code} value={a.code}>{a.code} {a.name}</option>)}</select>
                {partyFor(l.code) && <select className="input input-sm" value={l.party_id} onChange={(e) => upd(l.key, { party_id: e.target.value })}>
                  <option value="">Which {partyFor(l.code)}?</option>{(partyFor(l.code) === 'customer' ? (customers.data?.customers || []).filter((c) => !c.is_walk_in) : (bills.data?.vendors || [])).map((x: any) => <option key={x.id} value={x.id}>{x.name}</option>)}</select>}
              </span>
              <input className="input input-sm num" inputMode="decimal" value={l.debit} onChange={(e) => upd(l.key, { debit: e.target.value, credit: e.target.value ? '' : l.credit })} aria-label="Debit" />
              <input className="input input-sm num" inputMode="decimal" value={l.credit} onChange={(e) => upd(l.key, { credit: e.target.value, debit: e.target.value ? '' : l.debit })} aria-label="Credit" />
              <input className="input input-sm" value={l.memo} onChange={(e) => upd(l.key, { memo: e.target.value })} />
              <button className="btn btn-ghost btn-xs" onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))} aria-label="Remove line"><Icon name="trash" size={13} /></button>
            </div>
          ))}
          <div className="tr" style={{ gridTemplateColumns: 'minmax(220px,2fr) 120px 120px minmax(140px,1fr) 30px', fontWeight: 700 }}>
            <button className="btn btn-ghost btn-xs" style={{ justifySelf: 'start' }} onClick={() => setLines((ls) => [...ls, { key: crypto.randomUUID(), code: '', debit: '', credit: '', memo: '', party_id: '' }])}><Icon name="plus" size={13} />Line</button>
            <span className="right num">{N2(dr)}</span><span className="right num">{N2(cr)}</span>
            <span style={{ color: Math.abs(dr - cr) < 0.005 ? '#15803D' : '#DC2626', fontSize: 12 }}>{Math.abs(dr - cr) < 0.005 ? 'Balanced' : `Off by ${N2(Math.abs(dr - cr))}`}</span><span />
          </div>
        </div>
        <Field label="Evidence" hint="What supports it: an agreement, a schedule, an email. Every journal carries its evidence."><input className="input" value={evidence} onChange={(e) => setEvidence(e.target.value)} /></Field>
      </div>
      <div className="drawer-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={!memo.trim() || dr <= 0 || Math.abs(dr - cr) >= 0.005} onClick={post}>Post journal</button></div>
    </Drawer>
  );
}
