// Sell → Import sales: a month of sales from another POS or sales system, posted as Counta sales so the books, stock,
// customers and taxes follow them. The person picks the file; Counta reads it (src/lib/salesUpload.ts), matches each
// product to theirs (or adds it, or records it with no stock), asks where each way of paying goes, then posts the sales in
// batches (sales_import_batch). Card and POS money waits in clearing until the provider's settlement shows in the bank;
// transfers wait for the bank line. A row already uploaded is skipped; a whole upload can be undone.
import { useMemo, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Link } from 'react-router-dom';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { ai, cleanError, rpc } from '../../lib/supabase';
import { N2, fmtDay, when } from '../../lib/format';
import { cellText, detectHeader, pickSheet, readWorkbook, type SheetData } from '../../lib/sheet';
import { downloadBlob, reportCsv, safeName } from '../../lib/exporters';
import {
  FIELDS, TEMPLATE_COLUMNS, guessLayout, inferQuantities, matchColumns, priceHints, productKey, readSales, solvePrices, totalLooksBeforeDiscount,
  type Layout, type Method, type UpRow,
} from '../../lib/salesUpload';
import { Icon } from '../../components/Icon';
import { ItemPicker } from '../../components/ItemPicker';
import { Alert, Empty, Field, Modal, ModalHead, SkeletonRows, Spinner, Stat } from '../../components/ui';
import type { Item } from '../../lib/types';

type Vat = 'standard' | 'zero' | 'exempt';
type Decision = { mode: 'item' | 'new' | 'non_stock'; item_id?: string | null; item_name?: string | null; vat: Vat; how?: string | null; picking?: boolean; price?: number | null };
type PayMap = { method: Method; account_id: string | null; confirmed: boolean };
type Prep = {
  products: { name: string; key: string; mode: 'item' | 'non_stock' | null; item_id: string | null; item_name: string | null; vat_treatment: Vat | null; price: number | null; how: string | null }[];
  posted: string[]; format: any; locations: { id: string; name: string; is_main: boolean }[]; accounts: { id: string; name: string; kind: string; bank_name: string | null; location_id: string | null }[];
  filed_months: string[]; schedules: { id: string; number: string; from: string; to: string; amount: number }[]; closed_through: string | null;
  vat_registered: boolean; can_create_items: boolean;
};

const VAT_WORD: Record<Vat, string> = { standard: 'VAT at 7.5%', zero: 'Zero-rated', exempt: 'Exempt' };
const METHOD_WORD: Record<Method, string> = { cash: 'Cash', card: 'Card', pos: 'POS', transfer: 'Transfer', cheque: 'Cheque', other: 'Other' };
const BY_METHOD: Record<string, string> = {
  cash: 'Cash, in the branch\'s cash', card_clearing: 'Card, waiting for the settlement', pos_clearing: 'POS, waiting for the settlement', card: 'Card, settled',
  pos: 'POS, settled', transfer_waiting: 'Transfers waiting for the bank line', transfer: 'Transfers in the bank', other_waiting: 'Other, waiting for the bank line',
  other: 'Other ways of paying', cheque_waiting: 'Cheques waiting for the bank line', cheque: 'Cheques', refund: 'Refunds paid',
};
const BATCH = 50;
const pl = (n: number, one: string, many = one + 's') => `${n} ${n === 1 ? one : many}`;
// The Lagos day of a moment (Nigeria keeps one hour ahead of UTC all year).
const lagosDay = (iso: string) => new Date(Date.parse(iso) + 3600_000).toISOString().slice(0, 10);
const dayOfRow = (u: UpRow) => u.day || (u.at ? lagosDay(u.at) : null);
const isWalkIn = (n: string | null) => !n || /^(walk[ -]?in|walkin|cash|guest|customer)( customer)?s?$/i.test(n.trim());

export default function SalesImport() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const [open, setOpen] = useState<string | null>(null);
  const [upload, setUpload] = useState(false);
  const q = useQuery({ queryKey: ['sales_imports', orgId], enabled: !!orgId, queryFn: () => rpc<{ imports: any[]; can_upload: boolean }>('get_sales_imports', { p_org: orgId }) });
  if (!inv) return null;
  const mayUpload = can(inv, 'approve_adjustments') && !!q.data?.can_upload;
  const list = q.data?.imports || [];
  return (
    <div className="container" style={{ maxWidth: 1040 }}>
      <div className="row wrap" style={{ justifyContent: 'space-between', gap: 12, alignItems: 'flex-start' }}>
        <div className="muted" style={{ fontSize: 14, maxWidth: 640, lineHeight: 1.55 }}>
          Sell through another POS? Upload the sales it exports each month (CSV or Excel). Counta posts each one as a sale: stock goes out at cost, card and POS
          money waits until the provider settles it into your bank, transfers wait for the bank line, sales on credit are owed by the customer, and returns come
          back as credit notes. VAT, the books and your reports follow.
        </div>
        <div className="row wrap" style={{ gap: 8 }}>
          <button className="btn btn-secondary btn-sm" onClick={() => void templateFile(inv.org?.name || 'Counta').catch(() => undefined)}><Icon name="download" size={14} />Template</button>
          {mayUpload && <button className="btn btn-primary btn-sm" onClick={() => setUpload(true)}><Icon name="upload" size={14} color="#fff" />Upload sales</button>}
        </div>
      </div>
      {q.error && <Alert kind="yellow" icon="shield" style={{ marginTop: 14 }}>{cleanError(q.error)}</Alert>}
      {!q.error && !can(inv, 'approve_adjustments') && <Alert kind="grey" icon="info" style={{ marginTop: 14 }}>A manager, an accountant or the owner uploads sales.</Alert>}
      <div className="card" style={{ marginTop: 16, overflow: 'hidden' }}>
        {q.isLoading ? <SkeletonRows n={4} /> : !list.length ? <div style={{ padding: 20 }}><Empty>Uploads appear here. Each one can be opened to see what it posted, and undone.</Empty></div> : list.map((s) => (
          <div key={s.id} className="tr click" onClick={() => setOpen(s.id)} style={{ gridTemplateColumns: 'minmax(0,1.5fr) 110px 120px 110px' }}>
            <span className="ellipsis"><b>{s.number}</b>{s.file_name ? <span className="muted"> · {s.file_name}</span> : null}
              <span className="faint" style={{ display: 'block', fontSize: 12 }}>
                {s.date_from ? `${fmtDay(s.date_from)} to ${fmtDay(s.date_to)} · ` : ''}{pl(s.sales, 'sale')}{s.returns ? `, ${pl(s.returns, 'return')}` : ''}{s.failed ? ` · ${s.failed} not posted` : ''} · {when(s.created_at)}{s.created_by_name ? ` · ${s.created_by_name}` : ''}
              </span></span>
            <span><ImportStatus s={s.status} /></span>
            <span className="right num">{N2(s.amount)}</span>
            <span className="right num faint">VAT {N2(s.vat)}</span>
          </div>
        ))}
      </div>
      {upload && <UploadWizard onClose={() => setUpload(false)} onDone={(id) => { setUpload(false); setOpen(id); }} />}
      {open && <ImportView id={open} onClose={() => setOpen(null)} />}
    </div>
  );
}

function ImportStatus({ s }: { s: string }) {
  const [t, c] = s === 'posted' ? ['Posted', 't-green'] : s === 'void' ? ['Undone', 't-grey'] : ['Not finished', 't-amber'];
  return <span className={'chip ' + c}>{t}</span>;
}

// ---------------------------------------------------------------- one upload
function ImportView({ id, onClose }: { id: string; onClose: () => void }) {
  const toast = useToast();
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ['sales_import', id], queryFn: () => rpc<any>('get_sales_import', { p_import: id }) });
  const [undo, setUndo] = useState(false);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const d = q.data;
  async function refresh() {
    await Promise.all([qc.invalidateQueries({ queryKey: ['sales_import', id] }), qc.invalidateQueries({ queryKey: ['sales_imports'] }),
      qc.invalidateQueries({ queryKey: ['sales'] }), qc.invalidateQueries({ queryKey: ['inv'] }), qc.invalidateQueries({ queryKey: ['inbox'] })]);
  }
  async function doUndo() {
    setBusy(true); setErr(null);
    try { const r = await rpc<any>('void_sales_import', { p_import: id, p_reason: reason }); await refresh(); setUndo(false); toast(`${r.undone} sales and returns undone`); }
    catch (e) { setErr(cleanError(e)); }
    setBusy(false);
  }
  async function finish() {
    setBusy(true); setErr(null);
    try { await rpc('sales_import_finish', { p_import: id }); await refresh(); } catch (e) { setErr(cleanError(e)); }
    setBusy(false);
  }
  const sm = d?.summary || {};
  return (
    <Modal onClose={onClose} width={760}>
      <ModalHead title={d ? `${d.number}${d.file_name ? ` · ${d.file_name}` : ''}` : 'Upload'} sub={d ? `${d.date_from ? `${fmtDay(d.date_from)} to ${fmtDay(d.date_to)} · ` : ''}uploaded ${when(d.created_at)}${d.created_by_name ? ` by ${d.created_by_name}` : ''}` : undefined}
        onClose={onClose} extra={d ? <ImportStatus s={d.status} /> : undefined} />
      <div className="modal-body stack" style={{ gap: 14 }}>
        {!d ? <SkeletonRows n={5} /> : (
          <>
            {d.status === 'void' && <Alert kind="grey" icon="info">Undone {when(d.voided_at)}{d.voided_by_name ? ` by ${d.voided_by_name}` : ''}: {d.void_reason}. Its sales are void and their entries reversed.</Alert>}
            {d.status === 'posting' && <Alert kind="amber" icon="alert">This upload stopped before it finished. What it posted stays. Finish it to see its figures and match the bank lines it explains, or upload the file again: rows already posted are skipped.</Alert>}
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(140px,1fr))', gap: 10 }}>
              <Stat label="Sales posted" value={d.sales} sub={d.returns ? `and ${pl(d.returns, 'return')}` : undefined} />
              <Stat label="Amount" value={N2(d.amount)} sub={`VAT ${N2(d.vat)}`} />
              <Stat label="Skipped" value={d.skipped} sub="Uploaded before" />
              <Stat label="Not posted" value={d.failed} color={d.failed ? '#C2410C' : undefined} />
            </div>
            {Object.keys(d.by_method || {}).length > 0 && (
              <div className="card card-pad stack" style={{ gap: 6 }}>
                <b style={{ fontSize: 14 }}>Where the money went</b>
                {Object.entries(d.by_method as Record<string, number>).sort((a, b) => b[1] - a[1]).map(([k, v]) => (
                  <div key={k} className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}><span>{BY_METHOD[k] || k.replace(/_/g, ' ')}</span><span className="num">{N2(v)}</span></div>
                ))}
                {Number(d.owed) > 0 && <div className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}><span>Owed by customers ({pl(d.invoices, 'invoice')})</span><span className="num">{N2(d.owed)}</span></div>}
              </div>
            )}
            {d.status === 'posted' && (
              <div className="stack" style={{ gap: 8 }}>
                {Number(sm.in_clearing) > 0 && <Alert kind="blue" icon="info">{N2(sm.in_clearing)} of card and POS payments wait in clearing (9002). Each is settled when the provider&apos;s payout shows in your bank statement, one payment or a day&apos;s payments together, with the provider&apos;s charge booked as a bank charge.</Alert>}
                {Number(sm.waiting_transfers) > 0 && <Alert kind="blue" icon="info">{Number(sm.waiting_transfers) === 1 ? '1 transfer waits for its bank line. It is' : `${sm.waiting_transfers} transfers wait for their bank lines. They are`} confirmed as your bank statement comes in.</Alert>}
                {Number(sm.matched_lines) > 0 && <Alert kind="green" icon="check">{Number(sm.matched_lines) === 1 ? '1 bank line already in Counta was' : `${sm.matched_lines} bank lines already in Counta were`} matched to this upload.</Alert>}
                {(sm.bank_sales_alike || []).length > 0 && <Alert kind="amber" icon="alert">The bank feed already recorded {sm.bank_sales_alike.length} receipts of the same amounts as transfers in this upload ({sm.bank_sales_alike.slice(0, 4).map((x: any) => x.number).join(', ')}{sm.bank_sales_alike.length > 4 ? '…' : ''}). If they are the same money, void those bank receipts so the sales are not counted twice, then the transfers match their bank lines.</Alert>}
                {Number(sm.no_cost) > 0 && <Alert kind="amber" icon="alert">{sm.no_cost} products sold have no cost in Counta yet, so their cost of sales is nil. Record their purchases or set their costs in Inventory.</Alert>}
              </div>
            )}
            {(d.problems || []).length > 0 && (
              <div className="stack" style={{ gap: 6 }}>
                <div className="row" style={{ justifyContent: 'space-between' }}>
                  <b style={{ fontSize: 14 }}>Rows not posted</b>
                  <button className="btn btn-ghost btn-xs" onClick={() => downloadBlob(reportCsv([{ key: 'row', label: 'Row' }, { key: 'receipt', label: 'Receipt' }, { key: 'status', label: 'Status' }, { key: 'error', label: 'Reason' }],
                    d.problems), `${safeName(d.number + ' ' + (d.file_name || ''))} – rows not posted.csv`)}><Icon name="download" size={12} />CSV</button>
                </div>
                <div className="card" style={{ maxHeight: 260, overflow: 'auto' }}>
                  {d.problems.slice(0, 300).map((p: any, i: number) => (
                    <div key={i} className="tr" style={{ gridTemplateColumns: '60px 110px minmax(0,1fr)', fontSize: 13 }}>
                      <span className="faint">Row {p.row}</span><span className="ellipsis">{p.receipt || '–'}</span>
                      <span className={p.status === 'duplicate' ? 'faint' : ''}>{p.status === 'duplicate' ? p.error : p.error}</span>
                    </div>
                  ))}
                </div>
              </div>
            )}
            {undo && (
              <div className="card card-pad stack" style={{ gap: 8, background: '#FFF7ED' }}>
                <b>Undo {d.number}?</b>
                <div className="muted" style={{ fontSize: 13, lineHeight: 1.5 }}>Every sale and return it posted is voided and its entries reversed on their own dates. Stock comes back, and bank lines it settled go back to the Books inbox to be matched again. Nothing is undone if one of them cannot be (a filed VAT month, or a payment recorded on it since).</div>
                <Field label="Why"><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Wrong file, wrong month…" /></Field>
                <div className="row" style={{ gap: 8 }}>
                  <button className="btn btn-danger btn-sm" disabled={busy || !reason.trim()} onClick={doUndo}>{busy ? <Spinner small /> : null}Undo the upload</button>
                  <button className="btn btn-secondary btn-sm" onClick={() => setUndo(false)}>Keep it</button>
                </div>
              </div>
            )}
            {err && <Alert kind="red" icon="alert">{err}</Alert>}
          </>
        )}
      </div>
      <div className="modal-ft">
        <Link className="btn btn-secondary" to="/sell/sales" onClick={onClose}>See sales</Link>
        {d?.status === 'posting' && <button className="btn btn-primary" disabled={busy} onClick={finish}>Finish it</button>}
        {d?.can_undo && !undo && <button className="btn btn-secondary" onClick={() => setUndo(true)}>Undo</button>}
        <button className="btn btn-primary" onClick={onClose}>Done</button>
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------- the upload
type Step = 'file' | 'products' | 'money' | 'review' | 'posting';

function UploadWizard({ onClose, onDone }: { onClose: () => void; onDone: (id: string) => void }) {
  const { orgId } = useSession();
  const { data: inv } = useInventory();
  const qc = useQueryClient();
  const input = useRef<HTMLInputElement>(null);
  const [step, setStep] = useState<Step>('file');
  const [file, setFile] = useState('');
  const [sheet, setSheet] = useState<SheetData | null>(null);
  const [headerIdx, setHeaderIdx] = useState(0);
  const [layout, setLayout] = useState<Layout>('per_sale');
  const [map, setMap] = useState<Record<string, number>>({});
  const [before, setBefore] = useState<boolean | null>(null);
  const [prep, setPrep] = useState<Prep | null>(null);
  const [dec, setDec] = useState<Record<string, Decision>>({});
  const [pays, setPays] = useState<Record<string, PayMap>>({});
  const [branches, setBranches] = useState<Record<string, string>>({});
  const [loc, setLoc] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [vatAsked, setVatAsked] = useState<'no' | 'asking' | 'done' | 'failed'>('no');
  const [progress, setProgress] = useState<{ done: number; total: number; posted: number; failed: number; dup: number; importId: string | null }>({ done: 0, total: 0, posted: 0, failed: 0, dup: 0, importId: null });

  const headers = useMemo(() => (sheet ? (sheet.rows[headerIdx] || []).map(cellText) : []), [sheet, headerIdx]);
  const signature = useMemo(() => headers.map((h) => h.toLowerCase().trim()).join('|').slice(0, 500), [headers]);
  const rows = useMemo<UpRow[]>(() => (sheet ? readSales(sheet.rows, sheet.rowNo, headerIdx, { layout, map, totalBeforeDiscount: !!before }) : []), [sheet, headerIdx, layout, map, before]);
  const blocked = rows.filter((u) => u.problems.some((p) => /^No /.test(p) || /no unit price/.test(p)));
  const good = rows.filter((u) => !blocked.includes(u));
  const days = good.map(dayOfRow).filter(Boolean).sort() as string[];
  const products = useMemo(() => {
    const by = new Map<string, { name: string; key: string; sales: number; qty: number }>();
    for (const u of good) for (const l of u.lines) {
      const p = by.get(l.key); if (p) { p.sales++; p.qty += l.qty; } else by.set(l.key, { name: l.name, key: l.key, sales: 1, qty: l.qty });
    }
    return [...by.values()].sort((a, b) => b.sales - a.sales);
  }, [good]);
  const items = useMemo(() => (inv?.items || []) as Item[], [inv]);
  const itemById = useMemo(() => new Map(items.map((i) => [i.id, i])), [items]);
  // What one of each product sells for: the person's figure, the product's Counta price, what the file shows when it
  // sold alone, or what is left of a sale when the other products' prices are known.
  const hints = useMemo(() => {
    const known = priceHints(good);
    for (const p of prep?.products || []) {
      const d = dec[p.key];
      const it = d?.item_id ? itemById.get(d.item_id) : undefined;
      const v = d?.price ?? (d?.mode === 'item' ? it?.price ?? p.price : null);
      if (v != null && Number(v) > 0) known.set(p.key, Number(v));
    }
    return solvePrices(good, known);
  }, [good, prep, dec, itemById]);

  async function read(f: File) {
    setErr(null); setBusy('read');
    try {
      const all = await readWorkbook(f);
      if (!all.length) throw new Error('That file has no rows.');
      const s = all[pickSheet(all)];
      let h = detectHeader(s.rows), best = 0;
      for (let i = 0; i < Math.min(25, s.rows.length); i++) {
        const hd = (s.rows[i] || []).map(cellText);
        const n = Object.keys(matchColumns(hd, guessLayout(hd))).length;
        if (n > best) { best = n; h = i; }
      }
      const hd = (s.rows[h] || []).map(cellText);
      const lay = guessLayout(hd);
      let mp = matchColumns(hd, lay);
      let bf = totalLooksBeforeDiscount(s.rows, h, mp);
      // A layout uploaded before comes back as it was set.
      const sig = hd.map((x) => x.toLowerCase().trim()).join('|').slice(0, 500);
      const p = await rpc<Prep>('sales_import_prepare', { p_org: orgId, p: { signature: sig } }).catch(() => null);
      const fm = p?.format;
      if (fm?.mapping?.columns) { mp = fm.mapping.columns; if (typeof fm.mapping.before === 'boolean') bf = fm.mapping.before; }
      if (fm?.methods) setPays(fm.methods);
      if (fm?.branches) setBranches(fm.branches);
      setFile(f.name); setSheet(s); setHeaderIdx(h); setLayout(fm?.layout || lay); setMap(mp); setBefore(bf ?? (lay === 'per_sale' && mp.discount != null ? null : false));
    } catch (e) { setErr((e as Error).message || 'Could not read that file.'); }
    setBusy(null);
  }

  // Step 2: what Counta knows of these products and receipts.
  async function toProducts() {
    setErr(null); setBusy('prepare');
    try {
      const p = await rpc<Prep>('sales_import_prepare', { p_org: orgId, p: { names: products.map((x) => x.name), keys: good.map((u) => u.key), signature, from: days[0] || null, to: days[days.length - 1] || null } });
      setPrep(p);
      const d: Record<string, Decision> = {};
      for (const x of p.products) {
        const old = dec[x.key];
        d[x.key] = old || (x.mode === 'item' ? { mode: 'item', item_id: x.item_id, item_name: x.item_name, vat: (x.vat_treatment || 'standard') as Vat, how: x.how }
          : x.mode === 'non_stock' ? { mode: 'non_stock', vat: (x.vat_treatment || 'standard') as Vat, how: x.how }
          : { mode: p.can_create_items ? 'new' : 'non_stock', vat: 'standard', how: null });
      }
      setDec(d);
      if (!loc) setLoc((p.locations.find((l) => l.is_main) || p.locations[0])?.id || '');
      setStep('products');
      const unknown = p.products.filter((x) => !x.mode).map((x) => x.name);
      if (unknown.length && vatAsked === 'no') void askVat(unknown);
    } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  // The VAT engine's answer for products Counta does not know yet; a person can change each.
  async function askVat(names: string[]) {
    setVatAsked('asking');
    try {
      const got: Record<string, Vat> = {};
      for (let i = 0; i < names.length; i += 300) {
        const r = await ai<{ results: any[] }>('vat_classify_text', { org_id: orgId, lines: names.slice(i, i + 300).map((n) => ({ name: n })) });
        if (r.ok === false) throw new Error(r.error || 'not available');
        for (const x of r.results || []) if (x.treatment && Number(x.confidence) >= 0.6) got[productKey(String(x.name))] = x.treatment;
      }
      setDec((d) => { const n = { ...d }; for (const [k, v] of Object.entries(got)) if (n[k] && !n[k].how && n[k].mode !== 'item') n[k] = { ...n[k], vat: v }; return n; });
      setVatAsked('done');
    } catch { setVatAsked('failed'); }
  }

  // Step 3: new products added, choices saved, then the ways of paying.
  async function toMoney() {
    if (!prep) return;
    setErr(null); setBusy('products');
    try {
      const fresh = products.filter((p) => dec[p.key]?.mode === 'new' && !dec[p.key]?.how);
      const skipped: string[] = [];
      for (let i = 0; i < fresh.length; i += 500) {
        const r = await rpc<any>('import_inventory', { p_org: orgId, p_rows: fresh.slice(i, i + 500).map((p) => ({ name: p.name, price: hints.get(p.key) ?? null, vat_treatment: dec[p.key].vat })),
          p_options: { mode: 'skip', file_name: `Sales upload: ${file}` } });
        for (const x of r?.skipped || []) if (x.reason !== 'Already in your items') skipped.push(`${x.name} (${String(x.reason).toLowerCase()})`);
      }
      if (fresh.length) await qc.invalidateQueries({ queryKey: ['inv'] });
      if (skipped.length) throw new Error(`These were not added: ${skipped.slice(0, 6).join(', ')}${skipped.length > 6 ? ` and ${skipped.length - 6} more` : ''}. Give them a price, or record them with no stock.`);
      const save = products.filter((p) => { const x = dec[p.key]; return x && !x.how && (x.mode === 'non_stock' || (x.mode === 'item' && x.item_id)); })
        .map((p) => ({ name: p.name, mode: dec[p.key].mode, item_id: dec[p.key].item_id || null, vat_treatment: dec[p.key].mode === 'non_stock' ? dec[p.key].vat : null }));
      for (let i = 0; i < save.length; i += 2000) await rpc('save_sales_import_products', { p_org: orgId, p_rows: save.slice(i, i + 2000) });
      // Added products are found by their names from now on.
      if (fresh.length) setDec((d) => { const n = { ...d }; for (const p of fresh) n[p.key] = { ...n[p.key], how: 'name' }; return n; });
      // Ways of paying seen in the file, with what was set before for them.
      const labels = new Map<string, Method>();
      for (const u of good) for (const p of u.pay) if (!labels.has(p.label)) labels.set(p.label, p.method);
      setPays((old) => {
        const n: Record<string, PayMap> = {};
        for (const [l, m] of labels) n[l] = old[l] || { method: m, account_id: null, confirmed: false };
        return n;
      });
      const names = [...new Set(good.map((u) => u.branch).filter(Boolean) as string[])];
      setBranches((old) => {
        const n: Record<string, string> = {};
        for (const b of names) n[b] = old[b] || prep.locations.find((l) => l.name.toLowerCase() === b.toLowerCase())?.id || loc;
        return n;
      });
      setStep('money');
    } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }

  const priceOf = (key: string): number | null => hints.get(key) ?? null;
  const final = useMemo(() => {
    if (step !== 'review' && step !== 'posting') return null;
    const copy: UpRow[] = good.map((u) => ({ ...u, lines: u.lines.map((l) => ({ ...l })) }));
    const q = inferQuantities(copy, priceOf);
    return { rows: copy, ...q };
  }, [step, good, dec, prep, items]);

  const posted = new Set(prep?.posted || []);
  const filed = new Set((prep?.filed_months || []).map((m) => m.slice(0, 7)));
  const toSend = (final?.rows || []).filter((u) => !posted.has(u.key));
  const inFiled = toSend.filter((u) => { const d = dayOfRow(u); return d && filed.has(d.slice(0, 7)); });
  const creditWalkIns = toSend.filter((u) => u.kind === 'sale' && u.owed > 0.004 && isWalkIn(u.customer.name));

  function payload(u: UpRow, i: number) {
    const location = (u.branch && branches[u.branch]) || loc || null;
    return {
      row: u.row, key: u.key, receipt: u.receipt, kind: u.kind, at: u.at, day: u.day, location_id: location, original: u.original,
      customer: u.customer, total: u.kind === 'sale' ? u.total : null, discount: u.discount, sold_by: u.sold_by, note: u.note, reason: u.note,
      lines: u.lines.map((l) => {
        const d = dec[l.key];
        return { name: l.name, qty: l.qty, unit_price: l.unit_price, discount: l.discount, price_hint: hints.get(l.key) ?? null,
          item_id: d?.mode === 'item' ? d.item_id || null : null, non_stock: d?.mode === 'non_stock' || undefined, vat_treatment: d?.mode === 'non_stock' ? d.vat : undefined };
      }),
      payments: u.pay.map((p) => { const m = pays[p.label] || { method: p.method, account_id: null, confirmed: false }; return { method: m.method, amount: p.amount, account_id: m.account_id, confirmed: m.confirmed }; }),
      _i: i,
    };
  }

  async function post() {
    setErr(null); setStep('posting');
    const list = toSend;
    let importId = progress.importId;
    try {
      if (!importId) {
        const imp = await rpc<any>('sales_import_start', { p_org: orgId, p: { file_name: file, source: null, layout, location_id: loc || null, signature, rows_total: list.length,
          mapping: { columns: map, before }, methods: pays, branches } });
        importId = imp.id as string;
      }
      let { done, posted: ok, failed, dup } = importId === progress.importId ? progress : { done: 0, posted: 0, failed: 0, dup: 0 };
      setProgress({ done, total: list.length, posted: ok, failed, dup, importId });
      for (let i = done; i < list.length; i += BATCH) {
        const part = list.slice(i, i + BATCH).map(payload).map(({ _i, ...x }) => x);
        const r = await rpc<any>('sales_import_batch', { p_import: importId, p_rows: part });
        for (const x of r.rows || []) { if (x.status === 'posted') ok++; else if (x.status === 'duplicate') dup++; else failed++; }
        done = Math.min(i + BATCH, list.length);
        setProgress({ done, total: list.length, posted: ok, failed, dup, importId });
      }
      await rpc('sales_import_finish', { p_import: importId });
      await Promise.all(['sales_imports', 'sales', 'inv', 'inbox', 'customers'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
      onDone(importId);
    } catch (e) {
      setErr(`${cleanError(e)} What was posted stays; carry on to post the rest.`);
    }
  }

  const fields = FIELDS.filter((f) => f.layouts.includes(layout));
  const need = layout === 'per_sale' ? ['date', 'items', 'total'] : ['date', 'item', 'qty', 'unit_price'];
  const missing = need.filter((k) => map[k] == null);
  const accounts = prep?.accounts || [];
  const bankish = accounts.filter((a) => a.kind !== 'cash');
  const stepNo = { file: 1, products: 2, money: 3, review: 4, posting: 4 }[step];
  const unknownLeft = products.filter((p) => dec[p.key]?.mode === 'item' && !dec[p.key]?.item_id);
  const unpriced = products.filter((p) => dec[p.key]?.mode === 'new' && !dec[p.key]?.how && !(priceOf(p.key)! > 0));

  return (
    <Modal onClose={step === 'posting' && !err ? () => undefined : onClose} width={920}>
      <ModalHead title="Upload sales" sub={`Step ${stepNo} of 4 · ${step === 'file' ? 'The file' : step === 'products' ? 'Your products' : step === 'money' ? 'Where the money went' : 'Check and post'}${file ? ` · ${file}` : ''}`}
        onClose={step === 'posting' && !err ? () => undefined : onClose} />
      <div className="modal-body stack" style={{ gap: 14 }}>
        <input ref={input} type="file" hidden accept=".csv,.xlsx,.xls,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,application/vnd.ms-excel"
          onChange={(e) => { const f = e.target.files?.[0]; if (f) void read(f); e.target.value = ''; }} />

        {step === 'file' && (
          <>
            <div className="row wrap" style={{ gap: 10 }}>
              <button className="btn btn-secondary btn-sm" disabled={busy === 'read'} onClick={() => input.current?.click()}>{busy === 'read' ? <Spinner small /> : <Icon name="upload" size={14} />}{file ? 'Choose another file' : 'Choose the file'}</button>
              <span className="muted" style={{ fontSize: 13 }}>The sales export from your POS for the month, or Counta&apos;s template.</span>
            </div>
            {sheet && (
              <>
                <div className="row wrap" style={{ gap: 8, alignItems: 'center' }}>
                  <span style={{ fontSize: 13 }}>Each row of this file is</span>
                  <button className={'btn btn-xs ' + (layout === 'per_sale' ? 'btn-primary' : 'btn-secondary')} onClick={() => { setLayout('per_sale'); setMap(matchColumns(headers, 'per_sale')); }}>one sale</button>
                  <button className={'btn btn-xs ' + (layout === 'per_line' ? 'btn-primary' : 'btn-secondary')} onClick={() => { setLayout('per_line'); setMap(matchColumns(headers, 'per_line')); }}>one product of a sale</button>
                </div>
                <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: 'repeat(3,minmax(0,1fr))', gap: 10 }}>
                  {fields.map((f) => (
                    <Field key={f.key} label={`${f.label}${need.includes(f.key) ? '' : ' (if any)'}`}>
                      <select className="input input-sm" value={map[f.key] ?? ''} onChange={(e) => { const n = { ...map }; if (e.target.value === '') delete n[f.key]; else n[f.key] = Number(e.target.value); setMap(n); }}>
                        <option value="">Not in the file</option>{headers.map((h, i) => <option key={i} value={i}>{h || `Column ${i + 1}`}</option>)}
                      </select>
                    </Field>
                  ))}
                </div>
                {layout === 'per_sale' && map.discount != null && (
                  <div className="card card-pad stack" style={{ gap: 8, background: '#F8FAFC' }}>
                    <b style={{ fontSize: 14 }}>Is the total in this file before or after the discount?</b>
                    <div className="row wrap" style={{ gap: 8 }}>
                      <button className={'btn btn-sm ' + (before === true ? 'btn-primary' : 'btn-secondary')} onClick={() => setBefore(true)}>Before: the customer paid the total less the discount</button>
                      <button className={'btn btn-sm ' + (before === false ? 'btn-primary' : 'btn-secondary')} onClick={() => setBefore(false)}>After: the total is what the customer paid</button>
                    </div>
                    {before != null && totalLooksBeforeDiscount(sheet.rows, headerIdx, map) === before && <div className="faint" style={{ fontSize: 12 }}>Counta read this from cash sales in the file where the cash paid shows it.</div>}
                  </div>
                )}
                {missing.length > 0 ? <Alert kind="amber" icon="alert">Choose the column for {missing.map((k) => FIELDS.find((f) => f.key === k)?.label.toLowerCase()).join(', ')}.</Alert> : (
                  <div className="card card-pad stack" style={{ gap: 6 }}>
                    <div style={{ fontSize: 14 }}><b>{good.filter((u) => u.kind === 'sale').length}</b> sales{good.some((u) => u.kind === 'return') ? <>, <b>{good.filter((u) => u.kind === 'return').length}</b> returns</> : null}
                      {days.length ? <> from <b>{fmtDay(days[0])}</b> to <b>{fmtDay(days[days.length - 1])}</b></> : null}, <b>{N2(good.reduce((a, u) => a + (u.kind === 'sale' ? u.total || 0 : 0), 0))}</b> paid
                      {good.some((u) => u.discount) ? <> after <b>{N2(good.reduce((a, u) => a + u.discount, 0))}</b> of discounts</> : null}, <b>{products.length}</b> products.</div>
                    {blocked.length > 0 && <div className="muted" style={{ fontSize: 13 }}>{blocked.length} rows cannot be read and are left out: {blocked.slice(0, 4).map((u) => `row ${u.row} (${u.problems.join(', ').toLowerCase()})`).join('; ')}{blocked.length > 4 ? '…' : ''}</div>}
                    {good.some((u) => u.problems.length) && <div className="muted" style={{ fontSize: 13 }}>{good.filter((u) => u.problems.length).slice(0, 3).map((u) => `Row ${u.row}: ${u.problems.join(', ')}`).join('. ')}</div>}
                  </div>
                )}
              </>
            )}
          </>
        )}

        {step === 'products' && prep && (
          <>
            <div className="muted" style={{ fontSize: 13, lineHeight: 1.55 }}>
              Each product in the file is one of yours (its stock goes out and its cost is booked), a new product to add, or a sale with no stock (a service, a fee). Counta remembers your answers for next month.
              {vatAsked === 'asking' ? ' Counta is checking the VAT on the new ones…' : vatAsked === 'failed' ? ' The VAT check is not available now: check the VAT on new ones yourself.' : ''}
            </div>
            <div className="row wrap" style={{ gap: 8 }}>
              <span className="chip t-green">{products.filter((p) => dec[p.key]?.mode === 'item' && dec[p.key]?.item_id).length} yours</span>
              <span className="chip t-blue">{products.filter((p) => dec[p.key]?.mode === 'new').length} new</span>
              <span className="chip t-grey">{products.filter((p) => dec[p.key]?.mode === 'non_stock').length} no stock</span>
              <span style={{ flex: 1 }} />
              {prep.can_create_items && <button className="btn btn-ghost btn-xs" onClick={() => setDec((d) => { const n = { ...d }; for (const p of products) if (!n[p.key]?.how && n[p.key]?.mode !== 'item') n[p.key] = { ...n[p.key], mode: 'new' }; return n; })}>All new ones as products</button>}
              <button className="btn btn-ghost btn-xs" onClick={() => setDec((d) => { const n = { ...d }; for (const p of products) if (!n[p.key]?.how && n[p.key]?.mode !== 'item') n[p.key] = { ...n[p.key], mode: 'non_stock' }; return n; })}>All new ones with no stock</button>
            </div>
            <div className="card" style={{ maxHeight: 420, overflow: 'auto' }}>
              {products.map((p) => {
                const d = dec[p.key] || { mode: 'non_stock', vat: 'standard' as Vat };
                const set = (x: Partial<Decision>) => setDec((o) => ({ ...o, [p.key]: { ...d, ...x, how: x.mode || x.item_id ? null : d.how } }));
                const price = priceOf(p.key);
                return (
                  <div key={p.key} className="tr" style={{ gridTemplateColumns: 'minmax(0,1.4fr) 90px minmax(0,1.4fr) 130px', alignItems: 'center', fontSize: 13 }}>
                    <span className="ellipsis" title={p.name}><b>{p.name}</b><span className="faint" style={{ display: 'block', fontSize: 12 }}>{p.sales} sales{d.how === 'saved' ? ' · as last time' : d.how === 'name' ? ' · same name' : ''}</span></span>
                    <span>{d.mode === 'new' && !d.how ? (
                      <input className="input input-sm num" inputMode="decimal" placeholder="Price" value={d.price ?? (price ? String(price) : '')} style={{ borderColor: price ? undefined : '#F59E0B' }}
                        onChange={(e) => { const v = Number(e.target.value.replace(/[,₦\s]/g, '')); setDec((o) => ({ ...o, [p.key]: { ...d, price: e.target.value.trim() && v > 0 ? v : null } })); }} />
                    ) : <span className="num faint">{price ? N2(price) : '–'}</span>}</span>
                    <span>
                      {d.picking ? <ItemPicker items={items} autoFocus placeholder="Type the name of your product" onPick={(it) => set({ mode: 'item', item_id: it.id, item_name: it.name, vat: it.vat_treatment, picking: false })} /> : (
                        <select className="input input-sm" value={d.mode === 'item' ? `item:${d.item_id || ''}` : d.mode} onChange={(e) => {
                          const v = e.target.value;
                          if (v === 'pick') set({ picking: true });
                          else if (v.startsWith('item:')) set({ mode: 'item' });
                          else set({ mode: v as Decision['mode'], item_id: null, item_name: null });
                        }}>
                          {d.mode === 'item' && d.item_id && <option value={`item:${d.item_id}`}>Your product: {d.item_name || itemById.get(d.item_id)?.name}</option>}
                          {prep.can_create_items && <option value="new">Add it as a new product</option>}
                          <option value="non_stock">A sale with no stock</option>
                          <option value="pick">One of my products…</option>
                        </select>
                      )}
                    </span>
                    <span>{d.mode === 'item' ? <span className="faint">{VAT_WORD[(d.item_id && itemById.get(d.item_id)?.vat_treatment) || d.vat]}</span> : (
                      <select className="input input-sm" value={d.vat} onChange={(e) => setDec((o) => ({ ...o, [p.key]: { ...d, vat: e.target.value as Vat } }))}>
                        {(['standard', 'zero', 'exempt'] as Vat[]).map((v) => <option key={v} value={v}>{VAT_WORD[v]}</option>)}
                      </select>)}</span>
                  </div>
                );
              })}
            </div>
            {unknownLeft.length > 0 && <Alert kind="amber" icon="alert">Choose what {unknownLeft.length} products are.</Alert>}
            {unpriced.length > 0 && <Alert kind="amber" icon="alert">{unpriced.length} new products have no price Counta can work out from the file ({unpriced.slice(0, 3).map((p) => p.name).join(', ')}{unpriced.length > 3 ? '…' : ''}). Type their selling prices, or <button className="btn btn-ghost btn-xs" style={{ display: 'inline', padding: 0 }}
              onClick={() => setDec((d) => { const n = { ...d }; for (const p of unpriced) n[p.key] = { ...n[p.key], mode: 'non_stock' }; return n; })}>record them with no stock</button>.</Alert>}
          </>
        )}

        {step === 'money' && prep && (
          <>
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
              {Object.keys(branches).length === 0 ? (
                <Field label="Branch these sales were made in"><select className="input" value={loc} onChange={(e) => setLoc(e.target.value)}>{prep.locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</select></Field>
              ) : Object.keys(branches).map((b) => (
                <Field key={b} label={`"${b}" in the file is`}><select className="input" value={branches[b]} onChange={(e) => setBranches({ ...branches, [b]: e.target.value })}>{prep.locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</select></Field>
              ))}
            </div>
            <div className="card" style={{ overflow: 'hidden' }}>
              {Object.entries(pays).map(([label, m]) => {
                const total = good.reduce((a, u) => a + u.pay.filter((p) => p.label === label).reduce((x, p) => x + p.amount, 0), 0);
                const set = (x: Partial<PayMap>) => setPays({ ...pays, [label]: { ...m, ...x } });
                return (
                  <div key={label} className="tr" style={{ gridTemplateColumns: 'minmax(0,1fr) 120px minmax(0,1.6fr)', alignItems: 'start', fontSize: 13 }}>
                    <span><b style={{ textTransform: 'capitalize' }}>{label}</b><span className="faint" style={{ display: 'block' }}>{N2(total)}</span></span>
                    <select className="input input-sm" value={m.method} onChange={(e) => set({ method: e.target.value as Method })}>{(Object.keys(METHOD_WORD) as Method[]).map((k) => <option key={k} value={k}>{METHOD_WORD[k]}</option>)}</select>
                    <span className="stack" style={{ gap: 6 }}>
                      {m.method === 'cash' ? <span className="muted">Into the branch&apos;s cash drawer.</span> : (
                        <>
                          <select className="input input-sm" value={m.account_id || ''} onChange={(e) => set({ account_id: e.target.value || null })}>
                            <option value="">{m.method === 'card' || m.method === 'pos' ? 'Not sure yet: the settlement decides' : 'Not sure yet: the bank line decides'}</option>
                            {bankish.map((a) => <option key={a.id} value={a.id}>{a.name}{a.bank_name ? ` · ${a.bank_name}` : ''}</option>)}
                          </select>
                          <span className="faint" style={{ fontSize: 12, lineHeight: 1.45 }}>{m.method === 'card' || m.method === 'pos'
                            ? 'Held in clearing until the provider pays it into this account. The provider\'s charge is booked as a bank charge then.'
                            : m.confirmed ? 'Recorded as received into this account now.' : 'Each waits for its bank line, then the sale is paid.'}</span>
                          {(m.method === 'transfer' || m.method === 'other' || m.method === 'cheque') && m.account_id && (
                            <label className="row" style={{ gap: 6, fontSize: 12 }}><input type="checkbox" checked={m.confirmed} onChange={(e) => set({ confirmed: e.target.checked })} />Count them as received now (no bank statement in Counta for this account)</label>
                          )}
                        </>
                      )}
                    </span>
                  </div>
                );
              })}
              {!Object.keys(pays).length && <div style={{ padding: 16 }}><Empty>No payments in the file: every sale is on credit.</Empty></div>}
            </div>
          </>
        )}

        {(step === 'review' || step === 'posting') && final && prep && (
          <>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(150px,1fr))', gap: 10 }}>
              <Stat label="To post" value={toSend.filter((u) => u.kind === 'sale').length} sub={toSend.some((u) => u.kind === 'return') ? `sales and ${pl(toSend.filter((u) => u.kind === 'return').length, 'return')}` : 'sales'} />
              <Stat label="Paid" value={N2(toSend.reduce((a, u) => a + (u.kind === 'sale' ? (u.total || 0) - u.owed : 0), 0))} />
              <Stat label="On credit" value={N2(toSend.reduce((a, u) => a + (u.kind === 'sale' ? u.owed : 0), 0))} />
              <Stat label="Uploaded before" value={good.length - toSend.length} sub="Skipped" />
            </div>
            {final.worked > 0 && <Alert kind="green" icon="check">Counta worked out the quantities of {final.worked} sales from the prices (a product listed once for four times its price is four of it).</Alert>}
            {final.guessed > 0 && <Alert kind="grey" icon="info">{final.guessed} sales with several products do not say how many of each: they are recorded as one of each, the total shared by price. Their stock may need a count later.</Alert>}
            {inFiled.length > 0 && <Alert kind="amber" icon="alert">{inFiled.length} sales are in months whose VAT return is filed ({[...filed].join(', ')}). They will not post. Reopen those returns first to include them.</Alert>}
            {prep.closed_through && toSend.some((u) => (dayOfRow(u) || '') <= prep.closed_through!) && <Alert kind="amber" icon="alert">The books are closed up to {fmtDay(prep.closed_through)}. Sales before then will not post.</Alert>}
            {prep.schedules.length > 0 && <Alert kind="red" icon="alert">Sales schedule{prep.schedules.length > 1 ? 's' : ''} {prep.schedules.map((s) => s.number).join(', ')} already booked sales for these days in the VAT tab. Undo {prep.schedules.length > 1 ? 'them' : 'it'} first, or these sales count twice.</Alert>}
            {creditWalkIns.length > 0 && <Alert kind="amber" icon="alert">{creditWalkIns.length} sales are not paid in full and name no customer. They will not post: Counta needs to know who owes the money.</Alert>}
            {step === 'posting' && (
              <div className="card card-pad stack" style={{ gap: 8 }}>
                <div className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}><b>{progress.done < progress.total ? 'Posting…' : 'Matching the bank lines…'}</b><span className="num">{progress.done} of {progress.total}</span></div>
                <div style={{ height: 8, background: '#E5E7EB', borderRadius: 99, overflow: 'hidden' }}><div style={{ width: `${progress.total ? (progress.done / progress.total) * 100 : 0}%`, height: '100%', background: '#0072F5', transition: 'width .3s' }} /></div>
                <div className="faint" style={{ fontSize: 12 }}>{progress.posted} posted{progress.dup ? ` · ${progress.dup} uploaded before` : ''}{progress.failed ? ` · ${progress.failed} not posted (listed when it finishes)` : ''}</div>
              </div>
            )}
          </>
        )}
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
      </div>
      <div className="modal-ft">
        {step === 'file' && <><button className="btn btn-secondary" onClick={onClose}>Cancel</button>
          <button className="btn btn-primary" disabled={!sheet || missing.length > 0 || !good.length || (layout === 'per_sale' && map.discount != null && before == null) || !!busy} onClick={toProducts}>{busy === 'prepare' ? <Spinner small /> : null}Next: products</button></>}
        {step === 'products' && <><button className="btn btn-secondary" onClick={() => setStep('file')}>Back</button>
          <button className="btn btn-primary" disabled={unknownLeft.length > 0 || unpriced.length > 0 || !!busy} onClick={toMoney}>{busy === 'products' ? <><Spinner small />Saving the products…</> : 'Next: where the money went'}</button></>}
        {step === 'money' && <><button className="btn btn-secondary" onClick={() => setStep('products')}>Back</button>
          <button className="btn btn-primary" onClick={() => setStep('review')}>Next: check</button></>}
        {step === 'review' && <><button className="btn btn-secondary" onClick={() => setStep('money')}>Back</button>
          <button className="btn btn-primary" disabled={!toSend.length} onClick={post}>Post {toSend.length} {toSend.some((u) => u.kind === 'return') ? 'sales and returns' : toSend.length === 1 ? 'sale' : 'sales'}</button></>}
        {step === 'posting' && err && <><button className="btn btn-secondary" onClick={() => { if (progress.importId) onDone(progress.importId); else onClose(); }}>Stop here</button>
          <button className="btn btn-primary" onClick={post}>Carry on</button></>}
      </div>
    </Modal>
  );
}

// The template: one row per product, with an example sheet and how to fill it.
async function templateFile(orgName: string) {
  const mod: any = await import('exceljs');
  const ExcelJS = (mod.default || mod) as typeof import('exceljs');
  const wb = new ExcelJS.Workbook();
  wb.creator = 'Counta · TaxStreem'; wb.created = new Date();
  const ws = wb.addWorksheet('Sales', { views: [{ state: 'frozen', ySplit: 1 }] });
  const ex = wb.addWorksheet('Example', { views: [{ state: 'frozen', ySplit: 1 }] });
  const how = wb.addWorksheet('How to fill it');
  for (const s of [ws, ex]) {
    const r = s.getRow(1);
    TEMPLATE_COLUMNS.forEach((c, i) => {
      const cell = r.getCell(i + 1);
      cell.value = c.h; cell.font = { bold: true, color: { argb: 'FFFFFFFF' } };
      cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: c.h.endsWith('*') ? 'FF004FB0' : 'FF0072F5' } };
      cell.alignment = { vertical: 'middle', wrapText: true };
      cell.note = { texts: [{ text: c.note }] } as any;
      s.getColumn(i + 1).width = c.w;
      if (c.text) s.getColumn(i + 1).numFmt = '@';
      if (c.fmt) s.getColumn(i + 1).numFmt = c.fmt;
    });
    r.height = 34;
  }
  const d = (day: number) => new Date(Date.UTC(2026, 6, day));
  const rows: (string | number | Date | null)[][] = [
    ['R-1001', d(3), '09:12', null, null, null, null, null, 'Procold Tab X 4', 2, 1500, null, null, 3000, null, null, null, 'Sale', null, 'Joseph', null],
    ['R-1002', d(3), '11:40', null, null, null, null, null, 'Otrivin Adults Nasal Drop 01', 1, 4800, null, 300, 1000, 7700, null, null, 'Sale', null, 'Joseph', null],
    ['R-1002', d(3), '11:40', null, null, null, null, null, 'Vigor Chocolate Bar', 1, 4200, null, null, null, null, null, null, 'Sale', null, 'Joseph', null],
    ['R-1003', d(4), '15:05', 'Queen Imo', '08031234567', null, null, null, 'Kiss Lube Gel 120Ml', 2, 2900, null, null, null, null, 3000, 2800, 'Sale', null, 'Chinonye', 'Pays the rest Friday'],
    ['R-1004', d(6), '10:20', null, null, null, null, null, 'Vigor Chocolate Bar', 1, 4200, null, null, 4200, null, null, null, 'Return', 'R-1002', 'Joseph', 'Expired'],
  ];
  rows.forEach((v, i) => { const r = ex.getRow(i + 2); v.forEach((x, j) => { r.getCell(j + 1).value = x as any; }); });
  how.getColumn(1).width = 110;
  [
    `Sales for ${orgName}: one row per product sold.`,
    '',
    'Rows with the same receipt number are one sale. Put the sale\'s discount and its payments (cash, card or POS, transfer, amount owed) on its first row only.',
    'Unit prices are what the customer paid for one, with VAT inside. Counta works out the VAT from each product\'s VAT treatment.',
    'A sale not paid in full needs the customer\'s name: Counta records it as an invoice they owe.',
    'Card and POS money waits in clearing until your provider pays it into the bank. Transfers wait for the bank line.',
    'For goods brought back, write Return under "Sale or return" and the original receipt number. Cash in "Paid in cash" on a return is the refund.',
    'Counta never posts the same receipt twice, so you can upload a file again after fixing it.',
    'See the Example sheet. Columns marked * are needed.',
  ].forEach((t, i) => { const c = how.getCell(`A${i + 1}`); c.value = t; c.alignment = { wrapText: true }; if (i === 0) c.font = { bold: true, size: 13 }; });
  const buf = await wb.xlsx.writeBuffer();
  downloadBlob(new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }), 'Counta sales template.xlsx');
}

