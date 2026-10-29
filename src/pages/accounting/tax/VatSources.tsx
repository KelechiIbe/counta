// VAT from records kept outside Counta: sales schedules exported from another POS, purchase invoices that show VAT (to
// claim the input VAT), and money received into the bank with no Counta invoice behind it.
import { useEffect, useMemo, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useInventory, useSession, useToast } from '../../../state/session';
import { rpc, supabase } from '../../../lib/supabase';
import { edge, money, moneyAccounts, today } from '../../../lib/api';
import { cellText, detectHeader, parseDate, parseNum, pickSheet, readWorkbook, type Cell, type SheetData } from '../../../lib/sheet';
import { N2, fmtDay, uuid, when } from '../../../lib/format';
import { Icon } from '../../../components/Icon';
import { Alert, Empty, Field, Modal, ModalHead, Pills, SkeletonRows, Spinner } from '../../../components/ui';
import { StatusChip } from '../../sell/common';
import { useTaxRefresh } from './CitTab';
import { NG_STATES } from '../../../lib/countries';

// The VAT treatments in plain words.
const TREAT: Record<string, string> = { standard: 'VAT at 7.5%', zero: 'No VAT (zero-rated)', exempt: 'No VAT (exempt)' };
const TONE: Record<string, string> = { standard: 't-grey', zero: 't-blue', exempt: 't-amber' };

export function useVatSources(orgId: string | null) {
  return useQuery({ queryKey: ['vat_sources', orgId], enabled: Boolean(orgId), queryFn: () => rpc<any>('get_sales_schedules', { p_org: orgId }) });
}

// ---------------------------------------------------------------- money into the bank with no Counta invoice
const SOURCE_WORDS: Record<string, string> = { ai: 'Decided by the AI', product: 'From your product', usual: 'From what you usually sell', person: 'Set by your team' };

export function ReceiptsVatCard({ settings, receipts, counts, canWork }: { settings: any; receipts?: any[]; counts?: any; canWork: boolean }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const [busy, setBusy] = useState<string | null>(null);
  const [filter, setFilter] = useState<'check' | 'all'>('check');
  const list = receipts || [];
  const toCheck = Number(counts?.to_check || 0);
  const shown = filter === 'check' && toCheck > 0 ? list.filter((r) => r.check) : list;
  const refreshAll = () => Promise.all([qc.invalidateQueries({ queryKey: ['vat_sources'] }), qc.invalidateQueries({ queryKey: ['attention'] })]);
  async function save(p: Record<string, string>) {
    setBusy('settings');
    try { await rpc('set_receipts_vat', { p_org: orgId, p }); toast('Saved'); await refreshAll(); }
    catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }
  async function change(id: string, treatment: string) {
    setBusy(id);
    try { await rpc('set_receipt_vat', { p_sale: id, p: { treatment } }); toast('VAT changed and booked again'); await refreshAll(); }
    catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }
  async function askAgain() {
    setBusy('ask');
    try { const r = await rpc<{ asked: number }>('recheck_receipts_vat', { p_org: orgId }); toast(r.asked ? 'The AI will look at them again shortly' : 'Nothing to ask about'); await refreshAll(); }
    catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }
  const answered = settings?.vat_on_receipts === 'inclusive' || settings?.vat_on_receipts === 'exclusive';
  const oneForAll = settings?.receipts_vat_treatment === 'zero' || settings?.receipts_vat_treatment === 'exempt';
  return (
    <div className="card card-pad stack" style={{ gap: 10 }} data-testid="receipts-vat">
      <b>Money in with no Counta invoice</b>
      <div className="muted" style={{ fontSize: 13, lineHeight: 1.55 }}>When a payment reaches your bank or wallet without a Counta invoice behind it (from a connected bank, an uploaded statement or the wallet) and is posted to sales, Counta records it as a sale with its VAT. Counta&apos;s AI decides the VAT on each payment from what you sell and what the payment says, and you can change any of them.</div>
      {!answered && <Alert kind="amber" icon="info">Not answered yet. Until you do, Counta treats the amounts as including VAT.</Alert>}
      <Field label="Did you include VAT in what customers paid?">
        <div className="row wrap" style={{ gap: 8 }}>
          {[['inclusive', 'Yes, the amount includes VAT'], ['exclusive', 'No, VAT was not added']].map(([v, l]) => (
            <button key={v} className={'btn btn-sm ' + (settings?.vat_on_receipts === v ? 'btn-primary' : 'btn-secondary')} disabled={!canWork || busy !== null} onClick={() => save({ vat_on_receipts: v })}>{l}</button>
          ))}
        </div>
      </Field>
      <div className="faint" style={{ fontSize: 12 }}>{settings?.vat_on_receipts === 'exclusive' ? 'Where VAT applies, 7.5% is added on top and counted as your cost, since the customer did not pay it.'
        : 'Where VAT applies, Counta works it back out of each amount: the amount divided by 1.075 is the sale, the rest is VAT.'}</div>
      {oneForAll && (
        <Alert kind="blue" icon="info">
          <div className="row wrap" style={{ gap: 10, justifyContent: 'space-between', alignItems: 'center' }}>
            <span>You told Counta that everything you sell is {settings.receipts_vat_treatment === 'zero' ? 'zero-rated' : 'exempt'}, so no payment carries VAT.</span>
            {canWork && <button className="btn btn-secondary btn-sm" disabled={busy !== null} onClick={() => save({ receipts_vat_treatment: 'standard' })}>Let the AI decide each payment</button>}
          </div>
        </Alert>
      )}
      {list.length > 0 && (
        <div className="stack" style={{ gap: 8 }}>
          <div className="row wrap" style={{ gap: 8, justifyContent: 'space-between', alignItems: 'center' }}>
            <Pills value={filter === 'check' && toCheck > 0 ? 'check' : 'all'} onChange={setFilter}
              options={[...(toCheck > 0 ? [{ id: 'check' as const, label: 'To check', count: toCheck }] : []), { id: 'all' as const, label: 'All recent' }]} />
            {canWork && toCheck > 0 && <button className="btn btn-ghost btn-sm" disabled={busy !== null} onClick={askAgain}>{busy === 'ask' ? <Spinner small /> : <Icon name="sparkles" size={14} />}Ask the AI again</button>}
          </div>
          {Number(counts?.ai_waiting || 0) > 0 && <div className="faint" style={{ fontSize: 12 }}>The AI looks at {Number(counts.ai_waiting) === 1 ? 'one new payment' : `${counts.ai_waiting} new payments`} within a few minutes.</div>}
          <div className="card" style={{ overflow: 'hidden' }}>
            {shown.map((r) => (
              <div key={r.id} className="tr" style={{ display: 'flex', flexWrap: 'wrap', gap: 10, alignItems: 'flex-start' }} data-testid="receipt-vat-row">
                <span style={{ flex: '1 1 260px', minWidth: 0 }}>
                  <span className="ellipsis" style={{ display: 'block' }}><b>{r.narration || r.number}</b></span>
                  <span className="faint" style={{ display: 'block', fontSize: 12 }}>{fmtDay(r.date)} · {r.number}{r.account ? ` · ${r.account}` : ''}{r.counterparty ? ` · ${r.counterparty}` : ''}</span>
                  <span className="faint" style={{ display: 'block', fontSize: 12 }}>{r.ai_waiting ? 'The AI will look at it shortly.' : r.source === 'usual' && r.ai_looked ? 'The AI was not sure' : SOURCE_WORDS[r.source] || ''}{r.reason && !r.ai_waiting ? `: ${r.reason}` : ''}</span>
                  {r.check && !r.ai_waiting && <span className="chip t-amber" style={{ marginTop: 4 }}>To check</span>}
                </span>
                <span className="right num" style={{ flex: '0 0 110px', marginLeft: 'auto' }}>{N2(r.amount)}<span className="faint" style={{ display: 'block', fontSize: 12 }}>VAT {N2(r.vat)}</span></span>
                <span style={{ flex: '0 1 190px', minWidth: 160 }}>
                  {canWork && !r.filed ? (
                    <select className="input input-sm" value={r.treatment} disabled={busy !== null} aria-label={`VAT on ${r.number}`} onChange={(e) => change(r.id, e.target.value)}>
                      {Object.entries(TREAT).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
                    </select>
                  ) : <span className={'chip ' + TONE[r.treatment]}>{TREAT[r.treatment]}</span>}
                  {r.check && canWork && !r.filed && !r.ai_waiting && (
                    <button className="btn btn-ghost btn-sm" style={{ marginTop: 4 }} disabled={busy !== null} onClick={() => change(r.id, r.treatment)}>Looks right</button>
                  )}
                  {r.filed && <span className="faint" style={{ display: 'block', fontSize: 11 }}>Its month is filed</span>}
                </span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- sales schedules from another POS
type SField = { key: string; label: string; req?: boolean; syn: string[] };
const SFIELDS: SField[] = [
  { key: 'date', label: 'Date', req: true, syn: ['date', 'transaction date', 'trans date', 'sale date', 'date time', 'datetime', 'created at', 'created', 'time', 'posted', 'receipt date', 'invoice date'] },
  { key: 'amount', label: 'Amount paid', req: true, syn: ['amount', 'total', 'total amount', 'gross', 'gross sales', 'net sales', 'sales', 'amount paid', 'paid', 'grand total', 'value', 'line total', 'sum'] },
  { key: 'description', label: 'Item or description', syn: ['item', 'item name', 'product', 'product name', 'description', 'details', 'narration', 'particulars', 'name', 'items', 'menu item'] },
  { key: 'reference', label: 'Receipt or reference', syn: ['reference', 'ref', 'receipt', 'receipt no', 'receipt number', 'invoice', 'invoice no', 'transaction id', 'order', 'order no', 'order id', 'id', 'sku', 'barcode'] },
  { key: 'customer', label: 'Customer', syn: ['customer', 'customer name', 'client', 'buyer', 'company'] },
  { key: 'customer_tin', label: 'Customer Tax ID', syn: ['tin', 'tax id', 'customer tin', 'customer tax id'] },
  { key: 'method', label: 'Payment method', syn: ['payment', 'payment method', 'payment type', 'tender', 'mode', 'payment mode', 'channel', 'method', 'paid by'] },
  { key: 'qty', label: 'Quantity (if no amount)', syn: ['qty', 'quantity', 'units'] },
  { key: 'unit_price', label: 'Unit price (if no amount)', syn: ['unit price', 'price', 'rate'] },
];
const norm = (h: string) => String(h ?? '').toLowerCase().replace(/[*_\-.:#()/\\₦[\]]/g, ' ').replace(/\s+/g, ' ').trim();
const isTotal = (t: string) => /^(grand\s+)?(sub\s*)?totals?\b|^total for\b/i.test(t.trim());
function methodOf(v: string): string {
  const s = v.toLowerCase();
  if (/cash/.test(s)) return 'cash';
  if (/pos|terminal|moniepoint|opay pos/.test(s)) return 'pos';
  if (/card|visa|master|verve/.test(s)) return 'card';
  if (/transfer|bank|trf|nip|ussd/.test(s)) return 'transfer';
  return 'other';
}
// "05/10/2026 14:22" and "2026-10-05T14:22:00": the day is what matters.
const dayOf = (c: Cell) => parseDate(c instanceof Date || typeof c === 'number' ? c : String(c ?? '').trim().replace(/[ T]\d{1,2}:\d{2}(:\d{2})?(\s*[ap]m)?$/i, '').trim());

export function SchedulesPanel({ data, canWork }: { data: any; canWork: boolean }) {
  const [upload, setUpload] = useState(false);
  const [open, setOpen] = useState<string | null>(null);
  const list: any[] = data?.schedules || [];
  return (
    <div className="stack" style={{ gap: 12 }}>
      <div className="card card-pad stack" style={{ gap: 8 }}>
        <div className="row wrap" style={{ justifyContent: 'space-between', gap: 10 }}>
          <div style={{ flex: '1 1 320px' }}>
            <b>Sales recorded in another POS</b>
            <div className="muted" style={{ fontSize: 13, marginTop: 4, lineHeight: 1.55 }}>Upload the transactions schedule your POS exports (CSV or Excel). Counta reads each sale, works out its VAT and puts it in the month&apos;s VAT return and the NRS template, ready to file.</div>
          </div>
          {canWork && <button className="btn btn-primary btn-sm" disabled={!data?.settings?.vat_registered} onClick={() => setUpload(true)}><Icon name="upload" size={14} color="#fff" />Upload a schedule</button>}
        </div>
        {!data?.settings?.vat_registered && <Alert kind="grey" icon="info">Turn on charging VAT first (above) to load sales for the VAT return.</Alert>}
      </div>
      <div className="card" style={{ overflow: 'hidden' }}>
        {!list.length ? <div style={{ padding: 20 }}><Empty>Schedules you upload appear here, as drafts to check and then posted.</Empty></div> : list.map((s) => (
          <div key={s.id} className="tr click" onClick={() => setOpen(s.id)} style={{ gridTemplateColumns: 'minmax(0,1.4fr) 120px 130px 120px' }}>
            <span className="ellipsis"><b>{s.number}</b> {s.file_name ? <span className="muted">· {s.file_name}</span> : null}
              <span className="faint" style={{ display: 'block', fontSize: 12 }}>{s.date_from ? `${fmtDay(s.date_from)} to ${fmtDay(s.date_to)}` : ''} · {s.line_count} sales · amounts {s.vat_inclusive ? 'include' : 'exclude'} VAT · {when(s.created_at)}{s.created_by_name ? ` · ${s.created_by_name}` : ''}</span></span>
            <span><StatusChip s={s.status === 'posted' ? 'confirmed' : s.status === 'void' ? 'void' : 'draft'} /></span>
            <span className="right num">{N2(s.amount)}</span>
            <span className="right num faint">VAT {N2(s.vat)}</span>
          </div>
        ))}
      </div>
      {upload && <ScheduleUpload accounts={data?.accounts || []} onClose={() => setUpload(false)} onSaved={(id) => { setUpload(false); setOpen(id); }} />}
      {open && <ScheduleModal id={open} canWork={canWork} onClose={() => setOpen(null)} />}
    </div>
  );
}

function ScheduleUpload({ accounts, onClose, onSaved }: { accounts: any[]; onClose: () => void; onSaved: (id: string) => void }) {
  const { orgId } = useSession();
  const { data: inv } = useInventory();
  const qc = useQueryClient();
  const input = useRef<HTMLInputElement>(null);
  const [file, setFile] = useState('');
  const [sheet, setSheet] = useState<SheetData | null>(null);
  const [headerIdx, setHeaderIdx] = useState(0);
  const [map, setMap] = useState<Record<string, number>>({});
  const [incl, setIncl] = useState<boolean | null>(null);
  const [settle, setSettle] = useState('');
  const [loc, setLoc] = useState(inv?.locations?.[0]?.id || '');
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const headers = useMemo(() => (sheet ? (sheet.rows[headerIdx] || []).map(cellText) : []), [sheet, headerIdx]);
  function match(h: string[]) {
    const out: Record<string, number> = {}; const used = new Set<number>();
    for (const f of SFIELDS) {
      let best = -1, score = 0;
      h.forEach((raw, i) => {
        if (used.has(i)) return;
        const x = norm(raw);
        const s = f.syn.reduce((a, syn) => Math.max(a, x === syn ? 100 : syn.length > 3 && x.includes(syn) ? syn.length : 0), 0);
        if (s > score) { score = s; best = i; }
      });
      if (best >= 0) { out[f.key] = best; used.add(best); }
    }
    return out;
  }
  async function read(f: File) {
    setErr(null);
    try {
      const all = await readWorkbook(f);
      if (!all.length) throw new Error('That file has no rows.');
      const s = all[pickSheet(all)];
      let h = detectHeader(s.rows), best = 0;
      for (let i = 0; i < Math.min(25, s.rows.length); i++) {
        const n = Object.keys(match((s.rows[i] || []).map(cellText))).length;
        if (n > best) { best = n; h = i; }
      }
      setFile(f.name); setSheet(s); setHeaderIdx(h); setMap(match((s.rows[h] || []).map(cellText)));
    } catch (e) { setErr((e as Error).message || 'Could not read that file.'); }
  }
  const rows = useMemo(() => {
    if (!sheet) return [] as any[];
    const get = (r: Cell[], k: string) => (map[k] != null ? r[map[k]] : null);
    const out: any[] = [];
    sheet.rows.slice(headerIdx + 1).forEach((r, i) => {
      if (!r || r.every((c) => c == null || String(c).trim() === '')) return;
      const desc = cellText(get(r, 'description') ?? '').trim();
      const first = cellText(r[0] ?? '');
      if (isTotal(desc) || isTotal(first)) return;
      let amt = parseNum(get(r, 'amount'));
      if (amt == null && map.qty != null && map.unit_price != null) {
        const q = parseNum(get(r, 'qty')), p = parseNum(get(r, 'unit_price'));
        if (q != null && p != null) amt = Math.round(q * p * 100) / 100;
      }
      const date = dayOf(get(r, 'date'));
      if (amt == null && !date) return;
      out.push({ row: (sheet.rowNo?.[headerIdx + 1 + i] ?? headerIdx + 2 + i), date, amount: amt, description: desc || 'Sale',
        reference: cellText(get(r, 'reference') ?? '').trim() || null, customer: cellText(get(r, 'customer') ?? '').trim() || null,
        customer_tin: cellText(get(r, 'customer_tin') ?? '').trim() || null, method: methodOf(cellText(get(r, 'method') ?? '')) });
    });
    return out;
  }, [sheet, headerIdx, map]);
  const bad = rows.filter((r) => !r.date || r.amount == null);
  const total = rows.reduce((a, r) => a + (Number(r.amount) > 0 ? Number(r.amount) : 0), 0);
  async function save() {
    if (incl == null) { setErr('Answer whether the amounts already include VAT.'); return; }
    setBusy('classify'); setErr(null);
    try {
      // The VAT engine decides the lines no Counta product explains; the database keeps a product's own treatment.
      const known = new Set((inv?.items || []).map((i: any) => String(i.name).toLowerCase()));
      const names = [...new Set(rows.map((r) => r.description).filter((d) => d && !known.has(d.toLowerCase())))].slice(0, 300);
      const cls = names.length ? await edge<{ results: any[] }>('ai', { action: 'vat_classify_text', org_id: orgId, lines: names.map((n) => ({ name: n })) }) : { ok: true, results: [] };
      const by = new Map<string, any>((cls.ok === false ? [] : cls.results || []).map((x: any) => [String(x.name).toLowerCase(), x]));
      setBusy('save');
      const lines = rows.map((r) => {
        const c = by.get(String(r.description).toLowerCase());
        // Only a confident answer is used; the rest stay standard and are marked as a guess to check.
        return c && c.treatment && Number(c.confidence) >= 0.8 ? { ...r, vat_treatment: c.treatment, treatment_source: 'engine', nrs_label: c.nrs_label } : r;
      });
      const s = await rpc<any>('save_sales_schedule', { p_org: orgId, p: { file_name: file, source: null, vat_inclusive: incl, settle_to: settle || null, location_id: loc || null, lines } });
      await qc.invalidateQueries({ queryKey: ['vat_sources'] });
      onSaved(s.id);
    } catch (e) { setErr((e as Error).message); }
    setBusy(null);
  }
  return (
    <Modal onClose={onClose} width={760}>
      <ModalHead title="Upload a sales schedule" sub="The transactions schedule from your POS, as CSV or Excel" onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 12 }}>
        <input ref={input} type="file" hidden accept=".csv,.xlsx,.xls,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,application/vnd.ms-excel"
          onChange={(e) => { const f = e.target.files?.[0]; if (f) void read(f); e.target.value = ''; }} />
        <div className="row wrap"><button className="btn btn-secondary btn-sm" onClick={() => input.current?.click()}><Icon name="upload" size={14} />{file ? 'Choose another file' : 'Choose the file'}</button>{file && <span className="muted" style={{ fontSize: 13 }}>{file}</span>}</div>
        {sheet && (
          <>
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: 'repeat(3,minmax(0,1fr))', gap: 10 }}>
              {SFIELDS.map((f) => (
                <Field key={f.key} label={`${f.label}${f.req ? '' : ' (optional)'}`}>
                  <select className="input input-sm" value={map[f.key] ?? ''} onChange={(e) => { const n = { ...map }; if (e.target.value === '') delete n[f.key]; else n[f.key] = Number(e.target.value); setMap(n); }}>
                    <option value="">Not in the file</option>{headers.map((h, i) => <option key={i} value={i}>{h || `Column ${i + 1}`}</option>)}
                  </select>
                </Field>
              ))}
            </div>
            <div className="faint" style={{ fontSize: 12 }}>{rows.length} sales read, {N2(total)} in all{bad.length ? ` · ${bad.length} without a date or an amount (check the columns above)` : ''}. Refunds and lines already loaded are left out and listed.</div>
            <div className="card card-pad stack" style={{ gap: 8, background: '#F8FAFC' }}>
              <b>When you received these payments, did the amounts include VAT?</b>
              <div className="row wrap" style={{ gap: 8 }}>
                <button className={'btn btn-sm ' + (incl === true ? 'btn-primary' : 'btn-secondary')} onClick={() => setIncl(true)}>Yes, VAT is inside the amounts</button>
                <button className={'btn btn-sm ' + (incl === false ? 'btn-primary' : 'btn-secondary')} onClick={() => setIncl(false)}>No, VAT was not added</button>
              </div>
              <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>{incl === true ? 'Counta works the VAT back: each amount divided by 1.075 is the sale before VAT, and the rest is the VAT.'
                : incl === false ? 'Counta adds 7.5% VAT on top of each amount. You still owe it, so it is recorded as your cost.' : 'This decides how the VAT is worked out on every line that carries VAT.'}</div>
            </div>
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
              <Field label="Card, POS and transfer payments went into" hint="Not sure? They wait in clearing until the bank statement shows them.">
                <select className="input" value={settle} onChange={(e) => setSettle(e.target.value)}>
                  <option value="">Not sure: hold them in clearing</option>{accounts.filter((a) => a.kind !== 'cash').map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
                </select>
              </Field>
              {(inv?.locations || []).length > 1 && <Field label="Branch"><select className="input" value={loc} onChange={(e) => setLoc(e.target.value)}>{(inv?.locations || []).map((l: any) => <option key={l.id} value={l.id}>{l.name}</option>)}</select></Field>}
            </div>
          </>
        )}
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={!rows.length || incl == null || !!busy || map.date == null || (map.amount == null && (map.qty == null || map.unit_price == null))} onClick={save}>
          {busy === 'classify' ? <><Spinner small />Checking the VAT on each item…</> : busy === 'save' ? 'Saving…' : 'Read and check'}
        </button>
      </div>
    </Modal>
  );
}

function ScheduleModal({ id, canWork, onClose }: { id: string; canWork: boolean; onClose: () => void }) {
  const toast = useToast();
  const qc = useQueryClient();
  const refresh = useTaxRefresh();
  const q = useQuery({ queryKey: ['vat_schedule', id], queryFn: () => rpc<any>('get_sales_schedule', { p_schedule: id }) });
  const [filter, setFilter] = useState<'all' | 'guessed' | 'other' | 'excluded' | 'invoices'>('all');
  const [busy, setBusy] = useState<string | null>(null);
  const [reason, setReason] = useState('');
  const s = q.data;
  const draft = s?.status === 'draft' && canWork;
  async function line(l: any, p: Record<string, unknown>) {
    setBusy(l.id);
    try { await rpc('update_schedule_line', { p_line: l.id, p }); await q.refetch(); } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }
  async function post() {
    setBusy('post');
    try { await rpc('post_sales_schedule', { p_schedule: id }); toast(`${s.number} is in the books and the VAT return`); await Promise.all([q.refetch(), qc.invalidateQueries({ queryKey: ['vat_sources'] }), refresh()]); }
    catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }
  async function takeBack() {
    setBusy('void');
    try {
      const r = await rpc<any>('void_sales_schedule', { p_schedule: id, p_reason: reason || 'Removed before posting' });
      toast(r?.deleted ? 'Draft removed' : `${s.number} taken back`);
      await Promise.all([qc.invalidateQueries({ queryKey: ['vat_sources'] }), refresh()]);
      if (r?.deleted) onClose(); else await q.refetch();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }
  const lines: any[] = (s?.lines || []).filter((l: any) => filter === 'all' ? true : filter === 'guessed' ? l.treatment_source === 'default' && !l.excluded && !l.use_invoice
    : filter === 'other' ? l.vat_treatment !== 'standard' && !l.excluded : filter === 'excluded' ? l.excluded : l.invoice_id);
  return (
    <Modal onClose={onClose} width={900}>
      <ModalHead title={s ? `${s.number}${s.file_name ? ` · ${s.file_name}` : ''}` : 'Sales schedule'} sub={s ? `${s.status === 'draft' ? 'Draft: check it, then post' : s.status === 'posted' ? `Posted ${when(s.posted_at)}${s.posted_by_name ? ` by ${s.posted_by_name}` : ''}` : `Taken back: ${s.void_reason || ''}`} · amounts ${s.vat_inclusive ? 'include' : 'exclude'} VAT` : ''} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 12 }}>
        {q.isLoading || !s ? <SkeletonRows n={6} /> : (
          <>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(150px,1fr))', gap: 8 }}>
              <div className="card card-pad"><div className="faint" style={{ fontSize: 12 }}>Sales</div><b className="num">{N2(s.amount)}</b><div className="faint" style={{ fontSize: 12 }}>{s.counts?.included} lines</div></div>
              <div className="card card-pad"><div className="faint" style={{ fontSize: 12 }}>Before VAT</div><b className="num">{N2(s.net)}</b></div>
              <div className="card card-pad"><div className="faint" style={{ fontSize: 12 }}>Output VAT</div><b className="num">{N2(s.vat)}</b></div>
              <div className="card card-pad"><div className="faint" style={{ fontSize: 12 }}>Paying your invoices</div><b>{s.counts?.invoice_payments || 0}</b><div className="faint" style={{ fontSize: 12 }}>{s.counts?.excluded || 0} left out</div></div>
            </div>
            {(s.by_month || []).length > 0 && (
              <div className="card" style={{ overflow: 'auto' }}>
                <div className="tr head shade th" style={{ gridTemplateColumns: '130px repeat(5,minmax(90px,1fr))', minWidth: 640 }}><span>Month</span><span className="right">With VAT</span><span className="right">No VAT: zero-rated</span><span className="right">No VAT: exempt</span><span className="right">VAT</span><span className="right">Lines</span></div>
                {s.by_month.map((m: any) => (
                  <div key={m.month} className="tr" style={{ gridTemplateColumns: '130px repeat(5,minmax(90px,1fr))', minWidth: 640 }}>
                    <b>{new Date(m.month + 'T00:00:00Z').toLocaleDateString('en-GB', { month: 'short', year: 'numeric', timeZone: 'UTC' })}</b>
                    <span className="right num">{N2(m.standard || 0)}</span><span className="right num">{N2(m.zero || 0)}</span><span className="right num">{N2(m.exempt || 0)}</span><span className="right num">{N2(m.vat)}</span><span className="right">{m.lines}</span>
                  </div>
                ))}
              </div>
            )}
            {Number(s.counts?.guessed) > 0 && <Alert kind="amber" icon="info">{s.counts.guessed} line{s.counts.guessed === 1 ? '' : 's'} had no Counta product and no clear answer from the VAT engine, so {s.counts.guessed === 1 ? 'it carries' : 'they carry'} VAT at 7.5% for now. Check {s.counts.guessed === 1 ? 'it' : 'them'} under “To check”.</Alert>}
            <Pills value={filter} onChange={setFilter} options={[{ id: 'all', label: 'All' }, { id: 'guessed', label: 'To check', count: Number(s.counts?.guessed) || undefined },
              { id: 'other', label: 'No VAT' }, { id: 'invoices', label: 'Invoice payments', count: Number(s.counts?.invoice_candidates) || undefined }, { id: 'excluded', label: 'Left out' }]} />
            <div className="card" style={{ overflow: 'auto', maxHeight: 420 }}>
              <div className="tr head shade th" style={{ gridTemplateColumns: '90px minmax(180px,2fr) 110px 100px 170px 120px', minWidth: 820 }}><span>Date</span><span>Item</span><span className="right">Amount</span><span className="right">VAT</span><span>VAT treatment</span><span /></div>
              {!lines.length ? <div style={{ padding: 16 }}><Empty>Nothing here.</Empty></div> : lines.slice(0, 400).map((l) => (
                <div key={l.id} className="tr" style={{ gridTemplateColumns: '90px minmax(180px,2fr) 110px 100px 170px 120px', minWidth: 820, opacity: l.excluded ? .6 : 1 }}>
                  <span className="muted">{fmtDay(l.line_date)}</span>
                  <span className="ellipsis" title={l.description}>{l.description}<span className="faint" style={{ display: 'block', fontSize: 11 }}>
                    {[l.reference, l.customer_name, l.method !== 'other' ? l.method : null, l.excluded ? l.exclude_reason : null,
                      l.invoice_number ? `${l.use_invoice ? 'Pays' : 'May pay'} ${l.invoice_number}${l.invoice_basis?.basis === 'less_wht' ? ' less WHT' : ''}` : null, l.nrs_label].filter(Boolean).join(' · ')}</span></span>
                  <span className="right num">{N2(l.amount)}</span>
                  <span className="right num">{l.excluded || l.use_invoice ? '—' : N2(l.vat)}</span>
                  <span>{draft && !l.excluded && !l.use_invoice ? (
                    <select className="input input-sm" value={l.vat_treatment} disabled={busy === l.id} onChange={(e) => line(l, { vat_treatment: e.target.value })}>
                      {Object.entries(TREAT).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
                    </select>) : <span className={'chip ' + TONE[l.vat_treatment]}>{TREAT[l.vat_treatment]}</span>}
                    {l.treatment_source === 'default' && !l.excluded && !l.use_invoice && <span className="faint" style={{ display: 'block', fontSize: 11 }}>a guess</span>}</span>
                  <span className="row" style={{ gap: 4, justifyContent: 'flex-end' }}>
                    {draft && l.invoice_id && <button className="btn btn-ghost btn-xs" disabled={busy === l.id} onClick={() => line(l, { use_invoice: !l.use_invoice })}>{l.use_invoice ? 'It is a new sale' : 'It pays the invoice'}</button>}
                    {draft && Number(l.amount) > 0 && <button className="btn btn-ghost btn-xs" disabled={busy === l.id} onClick={() => line(l, { excluded: !l.excluded })}>{l.excluded ? 'Put back' : 'Leave out'}</button>}
                  </span>
                </div>
              ))}
            </div>
            {s.status === 'posted' && canWork && (
              <Field label="Take it back (the sales are voided; not possible once the month's return is filed)"><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Why" /></Field>
            )}
          </>
        )}
      </div>
      <div className="modal-ft">
        {s?.status === 'draft' && canWork && <button className="btn btn-ghost" disabled={!!busy} onClick={takeBack}>Delete the draft</button>}
        {s?.status === 'posted' && canWork && <button className="btn btn-ghost" disabled={!!busy || reason.trim().length < 3} onClick={takeBack}>Take it back</button>}
        <button className="btn btn-secondary" onClick={onClose}>Close</button>
        {draft && <button className="btn btn-primary" disabled={!!busy || !Number(s.counts?.included || 0) && !Number(s.counts?.invoice_payments || 0)} onClick={post}>{busy === 'post' ? 'Posting…' : 'Post to the books'}</button>}
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------- input VAT from purchase invoices
export function PurchasesPanel({ data, canWork }: { data: any; canWork: boolean }) {
  const [open, setOpen] = useState(false);
  const list: any[] = data?.purchases || [];
  return (
    <div className="stack" style={{ gap: 12 }}>
      <div className="card card-pad row wrap" style={{ justifyContent: 'space-between', gap: 10 }}>
        <div style={{ flex: '1 1 320px' }}>
          <b>Input VAT on purchase invoices</b>
          <div className="muted" style={{ fontSize: 13, marginTop: 4, lineHeight: 1.55 }}>Upload the invoices that show VAT. Counta reads each one and finds the payment behind it, and you check both. The VAT is claimed in the month of the invoice, and any withholding tax falls in the month it was paid. Invoices without a VAT figure carry nothing to claim.</div>
        </div>
        {canWork && <button className="btn btn-primary btn-sm" disabled={!data?.settings?.vat_registered} onClick={() => setOpen(true)}><Icon name="upload" size={14} color="#fff" />Upload invoices</button>}
      </div>
      <div className="card" style={{ overflow: 'hidden' }}>
        {!list.length ? <div style={{ padding: 20 }}><Empty>Purchase invoices claimed here appear with their VAT.</Empty></div> : list.map((b) => (
          <div key={b.id} className="tr" style={{ gridTemplateColumns: 'minmax(0,1.4fr) 100px 120px 110px' }}>
            <span className="ellipsis"><b>{b.vendor}</b><span className="faint" style={{ display: 'block', fontSize: 12 }}>{b.vendor_ref || b.number} · {fmtDay(b.bill_date)} · {b.number}
              {b.paid_on ? ` · paid ${fmtDay(b.paid_on)}` : ''}{Number(b.wht_borne) > 0 ? ` · WHT ${N2(b.wht_borne)} borne by you` : Number(b.wht_withheld) > 0 ? ` · WHT ${N2(b.wht_withheld)} kept back` : Number(b.wht) > 0 ? ` · WHT ${N2(b.wht)} when paid` : ''}</span></span>
            <span><StatusChip s={b.status} /></span>
            <span className="right num">{N2(b.total)}</span>
            <span className="right num" style={{ color: '#15803D' }}>VAT {N2(b.vat)}</span>
          </div>
        ))}
      </div>
      {open && <ClaimInvoicesModal onClose={() => setOpen(false)} />}
    </div>
  );
}

// The kinds of purchase withholding tax tells apart (codes of wht_rates), in the words a business uses.
const WHT_KINDS: [string, string][] = [
  ['goods', 'Goods bought'], ['services', 'Services (repairs, cleaning, transport, printing and the like)'], ['professional', 'Professional or consultancy services'],
  ['rent', 'Rent, hire or lease'], ['commission', 'Commission'], ['brokerage', 'Brokerage'], ['construction_roads', 'Building roads, bridges or buildings'],
  ['construction_other', 'Other construction or installation'], ['colocation', 'Telecom tower co-location'],
  ['ex_over_counter', 'Bought over the counter and paid on the spot (no WHT)'], ['ex_manufacturer', 'Goods the supplier makes itself (no WHT)'],
  ['ex_telecom_airline', 'Phone, internet data or air tickets (no WHT)'], ['ex_petroleum', 'Petrol, diesel or gas (no WHT)'], ['ex_insurance', 'Insurance (no WHT)'],
  ['ex_reimbursable', 'Costs paid back at cost (no WHT)'], ['ex_bank_charges', 'Bank charges (no WHT)'], ['none', 'Nothing to withhold'],
];
const guessType = (name: string) => (/\b(ltd|limited|plc|incorporated)\b/i.test(name) ? 'company' : /\b(enterprises?|ventures?|global|concepts?)\b/i.test(name) ? 'business_name' : '');
const monthWord = (d: string) => new Date(d + 'T12:00:00').toLocaleDateString('en-GB', { month: 'long', year: 'numeric' });

type Pay = { kind: 'bank_line' | 'payout'; id: string; date: string; amount: number; description: string | null; counterparty: string | null; account: string;
  basis: 'full' | 'less_wht'; named: boolean; wht: number; charge: number };
type Lookup = { vendor: { id: string; name: string; wht_category: string | null; type: string | null; has_tin: boolean; state: string | null; address: string | null } | null;
  wht: { category: string; name: string; rate: number; amount: number; doubled: boolean; note: string | null; corporate: boolean }; duplicate: string | null; matches: Pay[] };
type Claim = { key: string; name: string; path?: string; mime?: string; status: 'uploading' | 'reading' | 'ready' | 'saving' | 'saved' | 'skipped' | 'error'; error?: string;
  f: { supplier_name: string; supplier_tin: string; invoice_no: string; invoice_date: string; description: string; net: string; vat: string; total: string;
    supplier_type: string; supplier_address: string; supplier_state: string; wht_category: string };
  vat_shown?: boolean; warnings?: string[]; confidence?: number; paidHint?: boolean | null;
  // How it was paid: one of the payments found, paid with no record (when, from where, WHT kept back or not), or not paid yet.
  pay?: string; paidOn?: string; paidFrom?: string; whtTaken?: boolean; done?: string };

// Several invoices at once: each is uploaded, read and shown for checking; the ones that show VAT are claimed.
// bankLine: a payment out of the bank that one invoice is for (from Banking), which it then settles.
export function ClaimInvoicesModal({ onClose, bankLine }: { onClose: () => void; bankLine?: { id: string; amount: number; description: string; line_date: string } }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const refresh = useTaxRefresh();
  const input = useRef<HTMLInputElement>(null);
  const [claims, setClaims] = useState<Claim[]>([]);
  const [paidFrom, setPaidFrom] = useState('');
  const accts = useQuery({ queryKey: ['money_accounts', orgId], enabled: Boolean(orgId) && !bankLine, queryFn: () => moneyAccounts(orgId!) });
  const set = (key: string, p: Partial<Claim>) => setClaims((c) => c.map((x) => (x.key === key ? { ...x, ...p, f: { ...x.f, ...(p.f || {}) } } : x)));
  async function add(files: FileList) {
    const list = [...files].slice(0, bankLine ? 1 : 20);
    for (const file of list) {
      const key = uuid();
      const blank = { supplier_name: '', supplier_tin: '', invoice_no: '', invoice_date: '', description: '', net: '', vat: '', total: '', supplier_type: '', supplier_address: '',
        supplier_state: '', wht_category: '' };
      setClaims((c) => [...c, { key, name: file.name, status: 'uploading', f: blank }]);
      try {
        const mime = file.type || (file.name.toLowerCase().endsWith('.pdf') ? 'application/pdf' : 'image/jpeg');
        if (!/^(application\/pdf|image\/(jpeg|png|webp))$/.test(mime)) throw new Error('Upload a PDF or a photo (JPEG, PNG or WebP).');
        if (file.size > 15 * 1024 * 1024) throw new Error('The file is over 15MB.');
        const ext = mime === 'application/pdf' ? 'pdf' : mime === 'image/png' ? 'png' : mime === 'image/webp' ? 'webp' : 'jpg';
        const path = `${orgId}/vat-purchases/${today()}-${uuid()}.${ext}`;
        const { error } = await supabase.storage.from('documents').upload(path, file, { contentType: mime, upsert: false });
        if (error) throw new Error(error.message.includes('row-level') ? 'Your role cannot upload invoices.' : error.message);
        set(key, { path, mime, status: 'reading' });
        const r = await edge<{ invoice: any }>('ai', { action: 'read_purchase_invoice', org_id: orgId, path, mime });
        if (r.ok === false) { set(key, { status: 'ready', error: r.reason === 'not_configured' || r.reason === 'paused' ? `${r.error} Type the figures in below.` : r.error }); continue; }
        const i = r.invoice;
        const name = i.supplier_name || '';
        set(key, { status: i.is_invoice ? 'ready' : 'skipped', vat_shown: i.vat_shown, warnings: i.warnings, confidence: i.confidence, paidHint: i.paid ?? null,
          error: !i.is_invoice ? 'This does not look like a supplier invoice or receipt.' : !i.vat_shown ? 'No VAT is shown on this invoice, so there is nothing to claim.' : undefined,
          f: { supplier_name: name, supplier_tin: i.supplier_tin || '', invoice_no: i.invoice_no || '', invoice_date: i.invoice_date || '', description: i.description || '',
            net: i.net != null ? String(i.net) : '', vat: i.vat != null ? String(i.vat) : '', total: i.total != null ? String(i.total) : '',
            supplier_type: i.supplier_type || guessType(name), supplier_address: i.supplier_address || '', supplier_state: '', wht_category: i.wht_category || '' } });
      } catch (e) { set(key, { status: 'error', error: (e as Error).message }); }
    }
  }
  async function claim(c: Claim, look: Lookup | null) {
    set(c.key, { status: 'saving', error: undefined });
    const m = look?.matches.find((x) => `${x.kind}:${x.id}` === c.pay);
    const payment = bankLine ? { payment: 'bank_line', bank_line_id: bankLine.id }
      : m ? (m.kind === 'bank_line' ? { payment: 'bank_line', bank_line_id: m.id } : { payment: 'payout', payout_id: m.id })
      : c.pay === 'unpaid' ? { payment: 'unpaid' }
      : { payment: 'paid', paid_from: c.paidFrom || paidFrom, paid_on: c.paidOn, wht_taken: c.whtTaken !== false };
    try {
      const r = await rpc<any>('save_vat_purchase', { p_org: orgId, p: { document_path: c.path, supplier_name: c.f.supplier_name, supplier_tin: c.f.supplier_tin, invoice_no: c.f.invoice_no,
        invoice_date: c.f.invoice_date, description: c.f.description, net: money(c.f.net), vat: money(c.f.vat), total: money(c.f.total) || null,
        supplier_type: c.f.supplier_type || null, supplier_address: c.f.supplier_address || null, supplier_state: c.f.supplier_state || null,
        wht_category: c.f.wht_category || 'none', ...payment } });
      const b = r.bill || {};
      const words = [`Input VAT of ${N2(b.vat)} claimed for ${monthWord(c.f.invoice_date)}.`,
        Number(b.wht_borne) > 0 ? `The business owes the WHT of ${N2(b.wht_borne)} itself, in ${monthWord(r.wht_month)}.`
          : Number(b.wht_withheld) > 0 ? `WHT of ${N2(b.wht_withheld)} is due for ${monthWord(r.wht_month)}.`
          : r.payment === 'unpaid' && Number(b.wht) > 0 ? `${b.number} is waiting in Purchases; WHT of ${N2(b.wht)} is kept back when you pay it.` : null].filter(Boolean).join(' ');
      set(c.key, { status: 'saved', done: words });
      toast(`Input VAT of ${N2(money(c.f.vat) || 0)} claimed`);
      await Promise.all([qc.invalidateQueries({ queryKey: ['vat_sources'] }), qc.invalidateQueries({ queryKey: ['banking'] }), refresh()]);
    } catch (e) { set(c.key, { status: 'ready', error: (e as Error).message }); }
  }
  return (
    <Modal onClose={onClose} width={800}>
      <ModalHead title={bankLine ? 'Attach the invoice for this payment' : 'Claim input VAT from invoices'}
        sub={bankLine ? `${fmtDay(bankLine.line_date)} · ${bankLine.description} · ${N2(Math.abs(bankLine.amount))}` : 'PDFs or photos of the invoices your suppliers gave you'} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 12 }}>
        <input ref={input} type="file" hidden multiple={!bankLine} accept="application/pdf,image/jpeg,image/png,image/webp" onChange={(e) => { if (e.target.files?.length) void add(e.target.files); e.target.value = ''; }} />
        <div className="row wrap" style={{ gap: 10 }}>
          <button className="btn btn-secondary btn-sm" onClick={() => input.current?.click()}><Icon name="upload" size={14} />{claims.length ? 'Add more' : bankLine ? 'Choose the invoice' : 'Choose invoices'}</button>
          {!bankLine && (
            <select className="input input-sm" style={{ width: 'auto' }} value={paidFrom} onChange={(e) => setPaidFrom(e.target.value)} aria-label="Usually paid from">
              <option value="">Usually paid from…</option>{(accts.data || []).map((a: any) => <option key={a.id} value={a.id}>{a.name}</option>)}
            </select>
          )}
        </div>
        {!bankLine && <div className="faint" style={{ fontSize: 12 }}>Counta looks for the payment behind each invoice in your bank lines and wallet payouts. If it is not there, you say when it was paid. WHT falls in the month of the payment.</div>}
        {!claims.length && <Empty>Counta reads the supplier, the invoice number and date, and the VAT. You check them before anything is saved.</Empty>}
        {claims.map((c) => <ClaimCard key={c.key} c={c} set={(p) => set(c.key, p)} bankLine={bankLine} accounts={accts.data || []} paidFrom={paidFrom} onClaim={(look) => claim(c, look)} />)}
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Done</button></div>
    </Modal>
  );
}

function ClaimCard({ c, set, bankLine, accounts, paidFrom, onClaim }: { c: Claim; set: (p: Partial<Claim>) => void; bankLine?: { id: string; amount: number };
  accounts: any[]; paidFrom: string; onClaim: (look: Lookup | null) => void }) {
  const { orgId } = useSession();
  const editing = c.status === 'ready' || c.status === 'saving';
  const f = c.f;
  const field = (k: keyof Claim['f']) => (e: { target: { value: string } }) => set({ f: { ...f, [k]: e.target.value } });
  // What the records hold for this invoice: the supplier, its WHT and the payments that could have paid it.
  const key = JSON.stringify([f.supplier_name, f.supplier_tin, f.supplier_type, f.invoice_no, f.invoice_date, f.net, f.vat, f.total, f.wht_category]);
  const [look, setLook] = useState<Lookup | null>(null);
  const [looking, setLooking] = useState(false);
  useEffect(() => {
    if (!editing || !orgId || !f.supplier_name.trim() || !f.invoice_date || !(money(f.vat) || 0)) { setLook(null); return; }
    let live = true;
    const t = setTimeout(async () => {
      setLooking(true);
      try {
        const r = await rpc<Lookup>('vat_purchase_payments', { p_org: orgId, p: { supplier_name: f.supplier_name, supplier_tin: f.supplier_tin, supplier_type: f.supplier_type || null,
          invoice_no: f.invoice_no, invoice_date: f.invoice_date, net: money(f.net), vat: money(f.vat), total: money(f.total) || null, wht_category: f.wht_category || null } });
        if (!live) return;
        setLook(r);
        // What the supplier on file says fills what the invoice left open; the best payment found is chosen to start with.
        const fill: Partial<Claim['f']> = {};
        if (!f.wht_category && r.vendor?.wht_category) fill.wht_category = r.vendor.wht_category;
        if (!f.supplier_type && r.vendor?.type) fill.supplier_type = r.vendor.type;
        const first = r.matches[0];
        set({ ...(Object.keys(fill).length ? { f: fill as Claim['f'] } : {}),
          ...(c.pay === undefined && !bankLine ? { pay: first ? `${first.kind}:${first.id}` : c.paidHint === false ? 'unpaid' : undefined } : {}),
          ...(c.pay && c.pay.includes(':') && !r.matches.some((x) => `${x.kind}:${x.id}` === c.pay) ? { pay: first ? `${first.kind}:${first.id}` : undefined } : {}) });
      } catch { if (live) setLook(null); }
      if (live) setLooking(false);
    }, 450);
    return () => { live = false; clearTimeout(t); };
  }, [key, editing, orgId]); // eslint-disable-line react-hooks/exhaustive-deps
  const total = money(f.total) || (money(f.net) || 0) + (money(f.vat) || 0);
  const w = look?.wht;
  const wht = Number(w?.amount || 0);
  const needsState = wht > 0 && f.supplier_type && f.supplier_type !== 'company' && !look?.vendor?.state;
  const payReady = bankLine ? true : c.pay === 'unpaid' || (c.pay?.includes(':') ?? false) || (c.pay === 'paid' && Boolean(c.paidOn) && Boolean(c.paidFrom || paidFrom));
  const ready = editing && f.supplier_name && f.invoice_date && (money(f.vat) || 0) > 0 && f.wht_category && !look?.duplicate && payReady && (!needsState || f.supplier_state);
  const blBasis = bankLine && look ? (Math.abs(Math.abs(bankLine.amount) - total) <= Math.max(100, total * 0.005) ? 'full' : wht > 0 ? 'less_wht' : null) : null;
  return (
    <div className="card card-pad stack" style={{ gap: 8, borderColor: c.status === 'saved' ? '#86EFAC' : undefined }} data-testid="claim-card">
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <b className="ellipsis">{f.supplier_name || c.name}</b>
        <span className="faint" style={{ fontSize: 12 }}>{c.status === 'uploading' ? 'Uploading…' : c.status === 'reading' ? 'Reading…' : c.status === 'saving' ? 'Saving…'
          : c.status === 'saved' ? 'Claimed' : c.status === 'skipped' ? 'Nothing to claim' : c.confidence != null ? `Read with ${c.confidence}% confidence` : ''}</span>
      </div>
      {(c.status === 'uploading' || c.status === 'reading') && <Spinner small />}
      {c.error && <Alert kind={c.status === 'error' ? 'red' : 'amber'} icon="info">{c.error}</Alert>}
      {c.status === 'saved' && c.done && <Alert kind="green" icon="check">{c.done}</Alert>}
      {(c.warnings || []).map((x, i) => <div key={i} className="faint" style={{ fontSize: 12 }}>• {x}</div>)}
      {editing && (
        <div className="m-2" style={{ display: 'grid', gridTemplateColumns: 'repeat(4,minmax(0,1fr))', gap: 8 }}>
          <Field label="Supplier" style={{ gridColumn: 'span 2' }}><input className="input input-sm" value={f.supplier_name} onChange={field('supplier_name')} /></Field>
          <Field label="Supplier Tax ID"><input className="input input-sm" value={f.supplier_tin} onChange={field('supplier_tin')} /></Field>
          <Field label="Invoice number"><input className="input input-sm" value={f.invoice_no} onChange={field('invoice_no')} /></Field>
          <Field label="Invoice date"><input className="input input-sm" type="date" max={today()} value={f.invoice_date} onChange={field('invoice_date')} /></Field>
          <Field label="Before VAT"><input className="input input-sm num" inputMode="decimal" value={f.net} onChange={field('net')} /></Field>
          <Field label="VAT"><input className="input input-sm num" inputMode="decimal" value={f.vat} onChange={field('vat')} /></Field>
          <Field label="Total"><input className="input input-sm num" inputMode="decimal" value={f.total} onChange={field('total')} /></Field>
          <Field label="What was bought" style={{ gridColumn: '1 / -1' }}><input className="input input-sm" value={f.description} onChange={field('description')} /></Field>
        </div>
      )}
      {editing && (
        <div className="row wrap" style={{ gap: 8, alignItems: 'flex-end' }}>
          <Field label="The supplier is" style={{ flex: '1 1 160px' }}>
            <select className="input input-sm" value={f.supplier_type} onChange={field('supplier_type')} aria-label="The supplier is">
              <option value="">Choose…</option><option value="company">A company</option><option value="business_name">A business name</option><option value="individual">A person</option>
            </select>
          </Field>
          <Field label="For withholding tax, this is" style={{ flex: '3 1 260px', minWidth: 0 }}>
            <select className="input input-sm" value={f.wht_category} onChange={field('wht_category')} aria-label="For withholding tax, this is">
              <option value="">Choose what was bought…</option>{WHT_KINDS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}
            </select>
          </Field>
          {needsState && (
            <Field label="Supplier's state" hint="Its WHT goes to that state's revenue service." style={{ flex: '1 1 200px' }}>
              <select className="input input-sm" value={f.supplier_state} onChange={field('supplier_state')} aria-label="Supplier's state">
                <option value="">Choose…</option>{NG_STATES.map((st) => <option key={st} value={st}>{st}</option>)}
              </select>
            </Field>
          )}
        </div>
      )}
      {editing && f.wht_category && w && (
        <div className="faint" style={{ fontSize: 12.5 }} data-testid="claim-wht">
          {wht > 0 ? `WHT of ${N2(wht)} (${(Number(w.rate) * 100).toLocaleString('en-NG', { maximumFractionDigits: 2 })}%${w.doubled ? ', doubled as the supplier has no Tax ID' : ''}). It falls in the month the invoice was paid.`
            : `No WHT on this${w.note ? `: ${w.note.charAt(0).toLowerCase()}${w.note.slice(1)}` : ''}.`}
        </div>
      )}
      {editing && look?.duplicate && <Alert kind="amber" icon="alert">This invoice is already in the books as {look.duplicate}.</Alert>}
      {editing && bankLine && look && (
        <div className="faint" style={{ fontSize: 12.5 }}>
          {blBasis === 'full' ? (wht > 0 ? `The payment is the whole invoice, so no WHT was taken off. The business owes the ${N2(wht)} WHT itself.` : 'The payment settles the invoice.')
            : blBasis === 'less_wht' ? `The payment is the invoice less ${N2(wht)} WHT.` : null}
        </div>
      )}
      {editing && !bankLine && f.wht_category && (
        <div className="stack" style={{ gap: 6 }} data-testid="claim-payment">
          <b style={{ fontSize: 13 }}>How was it paid?{looking && <span className="faint" style={{ fontWeight: 400 }}> · looking in your records…</span>}</b>
          {(look?.matches || []).map((m) => {
            const k = `${m.kind}:${m.id}`;
            return (
              <label key={k} className="check" style={{ alignItems: 'flex-start', fontSize: 13 }}>
                <input type="radio" name={`pay-${c.key}`} checked={c.pay === k} onChange={() => set({ pay: k })} />
                <span>{N2(m.amount)} on {fmtDay(m.date)} from {m.account}{m.description ? ` · ${m.description}` : ''}
                  <span className="faint" style={{ display: 'block', fontSize: 12 }}>
                    {m.basis === 'less_wht' ? `The invoice less ${N2(m.wht)} WHT` : wht > 0 ? `The whole invoice: no WHT was taken off, so the business owes the ${N2(wht)} itself` : 'The whole invoice'}
                    {m.charge > 0 ? `, with ${N2(m.charge)} of bank charges` : ''}{m.kind === 'payout' ? ' · a wallet payout' : ''}</span>
                </span>
              </label>
            );
          })}
          {look && !look.matches.length && <div className="faint" style={{ fontSize: 12.5 }}>No payment in your bank lines or wallet matches this invoice.</div>}
          <label className="check" style={{ fontSize: 13 }}>
            <input type="radio" name={`pay-${c.key}`} checked={c.pay === 'paid'} onChange={() => set({ pay: 'paid', whtTaken: c.whtTaken ?? true })} />
            {look?.matches.length ? 'Paid another way, not in these records' : 'Paid'}
          </label>
          {c.pay === 'paid' && (
            <div className="stack" style={{ gap: 8, paddingLeft: 24 }}>
              <div className="row wrap" style={{ gap: 8 }}>
                <Field label="Paid on"><input className="input input-sm" type="date" max={today()} value={c.paidOn || ''} onChange={(e) => set({ paidOn: e.target.value })} aria-label="Paid on" /></Field>
                <Field label="From">
                  <select className="input input-sm" value={c.paidFrom || paidFrom} onChange={(e) => set({ paidFrom: e.target.value })} aria-label="Paid from">
                    <option value="">Choose the account…</option>{accounts.map((a: any) => <option key={a.id} value={a.id}>{a.name}</option>)}
                  </select>
                </Field>
              </div>
              {wht > 0 && (
                <div className="stack" style={{ gap: 4 }}>
                  <label className="check" style={{ fontSize: 13 }}><input type="radio" name={`taken-${c.key}`} checked={c.whtTaken !== false} onChange={() => set({ whtTaken: true })} />
                    Paid {N2(total - wht)}, keeping {N2(wht)} back for WHT</label>
                  <label className="check" style={{ fontSize: 13 }}><input type="radio" name={`taken-${c.key}`} checked={c.whtTaken === false} onChange={() => set({ whtTaken: false })} />
                    Paid the whole {N2(total)} (the business then owes the WHT itself)</label>
                </div>
              )}
            </div>
          )}
          <label className="check" style={{ fontSize: 13 }}>
            <input type="radio" name={`pay-${c.key}`} checked={c.pay === 'unpaid'} onChange={() => set({ pay: 'unpaid' })} />Not paid yet: put it in Purchases as a bill to pay
          </label>
        </div>
      )}
      {editing && (
        <div className="row" style={{ justifyContent: 'flex-end' }}>
          <button className="btn btn-primary btn-sm" disabled={c.status === 'saving' || !ready} onClick={() => onClaim(look)}>
            Claim {N2(money(f.vat) || 0)} input VAT
          </button>
        </div>
      )}
    </div>
  );
}
