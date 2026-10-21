// Documents: every file the business keeps in Counta, in folders by year, month, kind and folder, the way TaxStreem files
// them. Nothing is copied: invoices, bills, tax files, Flux's evidence and receipts stay with what they belong to, and
// this page finds them. Sales documents, a day's till receipts and PRN slips are drawn as PDFs when opened. Any folder,
// month or year downloads as one zip. Files can also be uploaded straight in.
import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useSession, useToast } from '../../state/session';
import { cleanError } from '../../lib/supabase';
import { downloadBlob } from '../../lib/exporters';
import { N2, fmtDay } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Empty, Field, Modal, ModalHead, Pills, Seg, SkeletonRows, Spinner } from '../../components/ui';
import {
  CATS, FOLDERS, MAX_UPLOAD, MONTHS, catLabel, extOf, fileBlob, fileName, formatOf, isImage, isPdf, loadFiles, loadTree, monthLabel, placeFilter, placeOf,
  removeDocument, sizeLabel, uploadDocument, viewUrl, yearLabel, zipPlace, type DocCat, type DocFile, type DocNode, type Place, type ZipProgress,
} from '../../lib/documents';

type Pill = DocCat | 'all';
type Level = 'year' | 'month' | 'cat' | 'folder' | 'sub';
type Item = { id: string; label: string; n: number; hint?: string };
type Column = { level: Level; title: string; items: Item[]; selected: string | undefined };

const store = {
  get: (k: string) => { try { return localStorage.getItem(k); } catch { return null; } },
  set: (k: string, v: string) => { try { localStorage.setItem(k, v); } catch { /* private mode */ } },
};
function useNarrow() {
  const q = '(max-width: 720px)';
  const [m, setM] = useState(() => typeof window !== 'undefined' && window.matchMedia(q).matches);
  useEffect(() => { const mq = window.matchMedia(q); const f = () => setM(mq.matches); mq.addEventListener('change', f); return () => mq.removeEventListener('change', f); }, []);
  return m;
}
const sum = (ns: DocNode[]) => ns.reduce((s, n) => s + Number(n.n || 0), 0);
const uniq = <T,>(xs: T[]) => xs.filter((x, i) => xs.indexOf(x) === i);
const lagosMonth = () => new Date(Date.now() + 3600_000).toISOString().slice(0, 7);

// The columns for where the person is, from the tree: years, then months, kinds, folders and a folder's parts.
function columnsFor(nodes: DocNode[], at: Place, pill: Pill): { cols: Column[]; leaf: boolean; subs: boolean } {
  const cols: Column[] = [];
  const years = uniq(nodes.map((n) => n.year)).sort((a, b) => (a == null ? 1 : b == null ? -1 : b - a));
  cols.push({ level: 'year', title: 'Year', selected: at.year === undefined ? undefined : String(at.year),
    items: years.map((y) => ({ id: String(y), label: yearLabel(y), n: sum(nodes.filter((n) => n.year === y)), hint: y == null ? 'Company papers and files with no month' : undefined })) });
  if (at.year === undefined) return { cols, leaf: false, subs: false };
  const inYear = nodes.filter((n) => n.year === at.year);
  let inMonth = inYear;
  if (at.year != null) {
    const months = uniq(inYear.map((n) => Number(n.month))).sort((a, b) => (a === 0 ? -1 : b === 0 ? 1 : b - a));
    cols.push({ level: 'month', title: 'Month', selected: at.month === undefined ? undefined : String(at.month),
      items: months.map((m) => ({ id: String(m), label: monthLabel(m), n: sum(inYear.filter((n) => Number(n.month) === m)), hint: m === 0 ? 'Returns and statements for the whole year' : undefined })) });
    if (at.month === undefined) return { cols, leaf: false, subs: false };
    inMonth = inYear.filter((n) => Number(n.month) === at.month);
  }
  let cat = pill === 'all' ? at.cat : pill;
  if (pill === 'all') {
    const cats = CATS.map((c) => c.id).filter((c) => inMonth.some((n) => n.cat === c));
    cols.push({ level: 'cat', title: 'Kind', selected: at.cat, items: cats.map((c) => ({ id: c, label: catLabel(c), n: sum(inMonth.filter((n) => n.cat === c)) })) });
    if (!at.cat) return { cols, leaf: false, subs: false };
    cat = at.cat;
  }
  const inCat = inMonth.filter((n) => n.cat === cat);
  const folders = uniq(inCat.map((n) => n.folder));
  cols.push({ level: 'folder', title: 'Folder', selected: at.folder, items: folders.map((f) => ({ id: f, label: f, n: sum(inCat.filter((n) => n.folder === f)) })) });
  if (!at.folder) return { cols, leaf: false, subs: false };
  const inFolder = inCat.filter((n) => n.folder === at.folder);
  if (inFolder.some((n) => n.sub)) {
    const subs = uniq(inFolder.map((n) => n.sub || ''));
    cols.push({ level: 'sub', title: at.folder, selected: at.sub, items: subs.map((s) => ({ id: s, label: s || 'In this folder', n: sum(inFolder.filter((n) => (n.sub || '') === s)) })) });
    return { cols, leaf: at.sub !== undefined, subs: true };
  }
  return { cols, leaf: true, subs: false };
}

// Where to go when an item in a column is chosen: everything after that level is let go.
function choose(at: Place, level: Level, id: string): Place {
  if (level === 'year') return { year: id === 'null' ? null : Number(id) };
  if (level === 'month') return { year: at.year, month: Number(id) };
  if (level === 'cat') return { year: at.year, month: at.month, cat: id as DocCat };
  if (level === 'folder') return { year: at.year, month: at.month, cat: at.cat, folder: id };
  return { ...at, sub: id };
}
function upTo(at: Place, level: Level | 'root'): Place {
  if (level === 'root') return {};
  if (level === 'year') return { year: at.year };
  if (level === 'month') return { year: at.year, month: at.month };
  if (level === 'cat') return { year: at.year, month: at.month, cat: at.cat };
  if (level === 'folder') return { year: at.year, month: at.month, cat: at.cat, folder: at.folder };
  return at;
}
function crumbs(at: Place, pill: Pill): { level: Level | 'root'; label: string }[] {
  const out: { level: Level | 'root'; label: string }[] = [{ level: 'root', label: pill === 'all' ? 'Documents' : catLabel(pill) }];
  if (at.year !== undefined) out.push({ level: 'year', label: yearLabel(at.year) });
  if (at.year != null && at.month !== undefined) out.push({ level: 'month', label: monthLabel(at.month) });
  if (at.cat) out.push({ level: 'cat', label: catLabel(at.cat) });
  if (at.folder) out.push({ level: 'folder', label: at.folder });
  if (at.sub !== undefined) out.push({ level: 'sub', label: at.sub || 'In this folder' });
  return out;
}
const placeName = (at: Place, pill: Pill, business: string) =>
  [business, ...crumbs(at, pill).slice(at.year === undefined && pill === 'all' ? 0 : 1).map((c) => c.label)].filter(Boolean).join(' ');

const SOURCE: Record<string, string> = { counta: 'Made in Counta', flux: 'Sent by TaxStreem Flux', accountant: 'From your accountant', upload: 'Uploaded' };
function fileIcon(f: DocFile) { return isImage(f) ? 'image' : ['xlsx', 'xls', 'csv'].includes(extOf(f)) ? 'list' : 'file'; }

export default function Documents() {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const narrow = useNarrow();
  const [pill, setPill] = useState<Pill>('all');
  const [at, setAt] = useState<Place>({});
  const [view, setView] = useState<'columns' | 'icons'>(() => (store.get('counta-docs-view') === 'icons' ? 'icons' : 'columns'));
  const [preview, setPreview] = useState(() => store.get('counta-docs-preview') !== 'off');
  const [q, setQ] = useState('');
  const [query, setQuery] = useState('');
  const [sel, setSel] = useState<DocFile | null>(null);
  const [upload, setUpload] = useState(false);
  const [zip, setZip] = useState<{ label: string; p: ZipProgress | null; error?: string } | null>(null);
  const cancel = useRef(false);
  useEffect(() => { store.set('counta-docs-view', view); }, [view]);
  useEffect(() => { store.set('counta-docs-preview', preview ? 'on' : 'off'); }, [preview]);
  useEffect(() => { const t = setTimeout(() => setQuery(q.trim()), 300); return () => clearTimeout(t); }, [q]);

  const tree = useQuery({ queryKey: ['documents-tree', orgId], enabled: !!orgId, queryFn: () => loadTree(orgId!) });
  const can = tree.data?.can || ({} as Record<DocCat, boolean>);
  const allNodes = tree.data?.nodes || [];
  const nodes = useMemo(() => allNodes.filter((n) => pill === 'all' || n.cat === pill), [allNodes, pill]);
  const { cols, leaf } = useMemo(() => columnsFor(nodes, at, pill), [nodes, at, pill]);
  const loading = tree.isLoading;
  const empty = !loading && !allNodes.length;
  const filter = useMemo(() => placeFilter(at, pill), [at, pill]);
  const files = useQuery({ queryKey: ['documents-files', orgId, filter], enabled: !!orgId && leaf && !query,
    queryFn: () => loadFiles(orgId!, { ...filter, limit: 500 }) });
  const search = useQuery({ queryKey: ['documents-search', orgId, query, pill], enabled: !!orgId && query.length >= 2,
    queryFn: () => loadFiles(orgId!, { q: query, ...(pill !== 'all' ? { cat: pill } : {}), limit: 200 }) });
  const shown: DocFile[] = useMemo(() => {
    if (query.length >= 2) return search.data?.files || [];
    const fs = files.data?.files || [];
    return at.sub === '' ? fs.filter((f) => !f.sub) : fs;
  }, [query, search.data, files.data, at.sub]);
  useEffect(() => { if (sel && !shown.some((f) => f.id === sel.id)) setSel(null); }, [shown, sel]);
  useEffect(() => { setAt({}); setSel(null); }, [orgId]);
  // Choosing a kind (or the one already chosen) starts again from the top.
  const pick = (v: Pill) => { setPill(v); setAt({}); setSel(null); };

  const pills: { id: Pill; label: string; count?: number }[] = [{ id: 'all', label: 'All', count: sum(allNodes) },
    ...CATS.filter((c) => can[c.id] && allNodes.some((n) => n.cat === c.id))
      .map((c) => ({ id: c.id as Pill, label: c.label, count: sum(allNodes.filter((n) => n.cat === c.id)) }))];
  // The one column a phone or the icons view shows: the first not yet chosen, or the files.
  const active = cols.find((c) => c.selected === undefined) || null;
  const box = useRef<HTMLDivElement>(null);
  const [boxW, setBoxW] = useState(0);
  useEffect(() => {
    const el = box.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setBoxW(el.clientWidth));
    ro.observe(el); setBoxW(el.clientWidth);
    return () => ro.disconnect();
  }, [view, narrow, query, loading, empty]);
  const fit = boxW ? Math.max(1, Math.floor((boxW - (leaf ? 320 : 0)) / 200)) : cols.length;
  const visible = cols.slice(Math.max(0, cols.length - fit));
  const business = tree.data?.business || 'Counta';

  async function zipHere(list?: DocFile[]) {
    if (!orgId) return;
    const label = query.length >= 2 ? `${business} search ${query}` : placeName(at, pill, business);
    cancel.current = false;
    setZip({ label, p: null });
    try {
      let fs = list;
      if (!fs) {
        const r = await loadFiles(orgId, { ...placeFilter(at, pill), limit: 2000 });
        if (r.more) throw new Error('There are more than 2,000 files here. Choose a year or a month first, then download that.');
        fs = at.sub === '' ? r.files.filter((f) => !f.sub) : r.files;
      }
      if (!fs.length) throw new Error('There are no files here to download.');
      const blob = await zipPlace(orgId, business, fs, (p) => setZip((z) => (z ? { ...z, p: { ...p, failed: [...p.failed] } } : z)), () => cancel.current);
      downloadBlob(blob, `${label.replace(/[\\/:*?"<>|]+/g, '-').slice(0, 120)}.zip`);
      setZip((z) => (z && z.p?.failed.length ? z : null));
      if (!zip?.p?.failed.length) toast('The zip is downloading.');
    } catch (e) {
      if ((e as Error).message === 'cancelled') { setZip(null); return; }
      setZip((z) => (z ? { ...z, error: cleanError(e) } : z));
    }
  }

  const head = (
    <div className="row wrap docs-head" style={{ justifyContent: 'space-between', gap: 10 }}>
      <div className="docs-search">
        <Icon name="search" size={16} color="#9CA3AF" />
        <input className="input input-sm" placeholder="Search names, customers, suppliers" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search documents" />
        {q && <button className="x-btn" onClick={() => setQ('')} aria-label="Clear the search"><Icon name="x" size={14} color="#9CA3AF" /></button>}
      </div>
      <div className="row wrap" style={{ gap: 8 }}>
        <Seg value={view} onChange={setView} options={[{ id: 'columns', label: 'Columns' }, { id: 'icons', label: 'Icons' }]} />
        {!narrow && <button className="btn btn-ghost btn-sm" onClick={() => setPreview(!preview)} aria-pressed={!preview}><Icon name="eye" size={15} />{preview ? 'Hide preview' : 'Show preview'}</button>}
        <button className="btn btn-secondary btn-sm" onClick={() => zipHere(query.length >= 2 ? shown : undefined)} disabled={empty || (query.length >= 2 && !shown.length)} data-testid="docs-zip">
          <Icon name="download" size={15} />Download zip
        </button>
        <button className="btn btn-primary btn-sm" onClick={() => setUpload(true)}><Icon name="upload" size={15} color="#fff" />Upload</button>
      </div>
    </div>
  );

  const fileRow = (f: DocFile, withPlace = false) => (
    <button key={f.id} className={'docs-file' + (sel?.id === f.id ? ' on' : '')} onClick={() => setSel(f)} data-testid="doc-file" title={f.name}>
      <span className="docs-ficon"><Icon name={fileIcon(f)} size={16} color={f.kind === 'file' ? '#6B7280' : '#0072F5'} /></span>
      <span className="grow" style={{ minWidth: 0 }}>
        <span className="ellipsis" style={{ display: 'block', fontWeight: 500 }}>{f.name}</span>
        <span className="faint ellipsis" style={{ display: 'block', fontSize: 11 }}>
          {withPlace ? placeOf(f) : [f.day ? fmtDay(f.day) : '', f.amount != null ? N2(Number(f.amount)) : '', sizeLabel(f.size)].filter(Boolean).join(' · ')}
        </span>
      </span>
      <span className="docs-ext">{extOf(f).toUpperCase()}</span>
    </button>
  );
  const fileList = (list: DocFile[], busy: boolean, withPlace = false, more = false) => (
    <div className="docs-list" data-testid="docs-files">
      {busy ? <div style={{ padding: 12 }}><SkeletonRows n={5} h={14} /></div>
        : !list.length ? <div className="faint" style={{ padding: 16, fontSize: 13 }}>{query ? 'Nothing matches that.' : 'No files here.'}</div>
        : list.map((f) => fileRow(f, withPlace))}
      {more && <div className="faint" style={{ padding: '8px 12px', fontSize: 12 }}>Showing the newest 500. Download the zip for all of them.</div>}
    </div>
  );
  const colList = (c: Column) => (
    <div className="docs-list" data-testid={`docs-col-${c.level}`}>
      {c.items.map((it) => (
        <button key={it.id} className={'docs-item' + (c.selected === it.id ? ' on' : '')} onClick={() => { setAt(choose(at, c.level, it.id)); setSel(null); }} title={it.hint} data-item={it.id}>
          <Icon name="folder" size={16} color={c.selected === it.id ? '#0072F5' : '#9CA3AF'} />
          <span className="grow ellipsis">{it.label}</span>
          <span className="faint" style={{ fontSize: 11 }}>{it.n}</span>
          <Icon name="chevron" size={14} color="#D1D5DB" style={{ transform: 'rotate(-90deg)' }} />
        </button>
      ))}
    </div>
  );
  const crumbBar = (
    <nav className="docs-crumbs" aria-label="Where you are">
      {crumbs(at, pill).map((c, i, all) => (
        <span key={c.level} className="row" style={{ gap: 4 }}>
          {i > 0 && <span className="faint">/</span>}
          {i < all.length - 1 ? <button className="link" onClick={() => { setAt(upTo(at, c.level)); setSel(null); }}>{c.label}</button> : <b>{c.label}</b>}
        </span>
      ))}
    </nav>
  );

  let body: ReactNode;
  if (query.length >= 2) {
    body = (
      <div className="card docs-pane">
        <div className="docs-colhead">{search.isLoading ? 'Searching' : `${shown.length}${search.data?.more ? '+' : ''} found`} for "{query}"</div>
        {fileList(shown, search.isLoading, true)}
      </div>
    );
  } else if (view === 'columns' && !narrow) {
    body = (
      <div className="card docs-cols" data-testid="docs-columns">
        {visible.map((c) => (
          <div key={c.level} className="docs-col">
            <div className="docs-colhead">{c.title}</div>
            {colList(c)}
          </div>
        ))}
        {leaf && (
          <div className="docs-col docs-col-files">
            <div className="docs-colhead">Files{files.data ? ` · ${shown.length}` : ''}</div>
            {fileList(shown, files.isLoading, false, files.data?.more)}
          </div>
        )}
      </div>
    );
  } else {
    // One level at a time: a phone, or the icons view.
    body = (
      <div className="card docs-pane">
        <div className="docs-colhead row" style={{ justifyContent: 'space-between' }}>
          {crumbBar}
          {cols.length > 1 || at.year !== undefined ? <button className="btn btn-ghost btn-xs" onClick={() => {
            const last = crumbs(at, pill); setAt(upTo(at, last.length > 1 ? last[last.length - 2].level : 'root')); setSel(null);
          }}><Icon name="undo" size={13} />Back</button> : null}
        </div>
        {leaf ? (view === 'icons' ? (
          <div className="docs-grid" data-testid="docs-files">
            {files.isLoading ? <SkeletonRows n={3} /> : !shown.length ? <div className="faint" style={{ padding: 12 }}>No files here.</div> : shown.map((f) => (
              <button key={f.id} className={'docs-tile' + (sel?.id === f.id ? ' on' : '')} onClick={() => setSel(f)} data-testid="doc-file" title={f.name}>
                <span className="docs-tile-ico"><Icon name={fileIcon(f)} size={28} color={f.kind === 'file' ? '#6B7280' : '#0072F5'} /><span className="docs-ext">{extOf(f).toUpperCase()}</span></span>
                <span className="docs-tile-name">{f.name}</span>
                <span className="faint" style={{ fontSize: 11 }}>{f.day ? fmtDay(f.day) : ''}</span>
              </button>
            ))}
          </div>
        ) : fileList(shown, files.isLoading, false, files.data?.more)) : active && (view === 'icons' ? (
          <div className="docs-grid" data-testid={`docs-col-${active.level}`}>
            {active.items.map((it) => (
              <button key={it.id} className="docs-tile" onClick={() => { setAt(choose(at, active.level, it.id)); setSel(null); }} title={it.hint} data-item={it.id}>
                <span className="docs-tile-ico"><Icon name="folder" size={34} color="#0072F5" /></span>
                <span className="docs-tile-name">{it.label}</span>
                <span className="faint" style={{ fontSize: 11 }}>{it.n} {it.n === 1 ? 'file' : 'files'}</span>
              </button>
            ))}
          </div>
        ) : colList(active))}
      </div>
    );
  }

  const panel = sel && <PreviewPanel key={sel.id} f={sel} org={orgId!} compact={narrow} onClose={() => setSel(null)} onRemoved={() => {
    setSel(null); qc.invalidateQueries({ queryKey: ['documents-tree'] }); qc.invalidateQueries({ queryKey: ['documents-files'] }); qc.invalidateQueries({ queryKey: ['documents-search'] });
  }} />;

  return (
    <div className="container" style={{ maxWidth: 1400 }}>
      <div className="muted" style={{ fontSize: 14, marginTop: -6 }}>
        Every invoice, bill, receipt, tax file and upload in one place, filed by year, month and kind. Download any folder as a zip.
      </div>
      {tree.error ? <Alert kind="yellow" icon="shield">{cleanError(tree.error)}</Alert> : (
        <>
          <Pills value={pill} onChange={pick} options={pills} />
          {head}
          {loading ? <SkeletonRows n={8} /> : empty ? (
            <Empty>
              <div className="stack" style={{ alignItems: 'center', gap: 10 }}>
                <Icon name="folder" size={28} color="#9CA3AF" />
                <div>Nothing here yet. Invoices, bills, tax files and receipts appear here as the business works in Counta.</div>
                <button className="btn btn-secondary btn-sm" onClick={() => setUpload(true)}><Icon name="upload" size={15} />Upload a file</button>
              </div>
            </Empty>
          ) : (
            <div className="docs-main">
              <div className="docs-browse" ref={box}>
                {view === 'columns' && !narrow && !query && crumbBar}
                {body}
              </div>
              {preview && !narrow && (panel || <div className="card docs-preview docs-preview-empty faint" data-testid="docs-preview-empty">
                <Icon name="file" size={28} color="#D1D5DB" /><div>Choose a file to see it here.</div></div>)}
            </div>
          )}
        </>
      )}
      {sel && (narrow || !preview) && (
        <Modal onClose={() => setSel(null)} width={560}>
          <div className="docs-modal-preview">{panel}</div>
        </Modal>
      )}
      {upload && orgId && <UploadModal org={orgId} can={can} at={at} pill={pill} onClose={() => setUpload(false)} onDone={(n) => {
        setUpload(false); toast(n === 1 ? 'The file is in Documents.' : `${n} files are in Documents.`);
        qc.invalidateQueries({ queryKey: ['documents-tree'] }); qc.invalidateQueries({ queryKey: ['documents-files'] });
      }} />}
      {zip && (
        <Modal onClose={() => { cancel.current = true; setZip(null); }} width={440}>
          <ModalHead title="Download zip" sub={zip.label} onClose={() => { cancel.current = true; setZip(null); }} />
          <div className="modal-body" data-testid="docs-zip-progress">
            {zip.error ? <Alert kind="yellow" icon="alert">{zip.error}</Alert> : !zip.p ? <div className="row"><Spinner small /> Finding the files</div> : (
              <>
                <div className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}>
                  <span>{zip.p.done < zip.p.total ? 'Putting the files together' : 'Done'}</span><span className="faint">{zip.p.done} of {zip.p.total}</span>
                </div>
                <div className="docs-bar"><span style={{ width: `${zip.p.total ? Math.round((zip.p.done / zip.p.total) * 100) : 0}%` }} /></div>
                {zip.p.failed.length > 0 && zip.p.done >= zip.p.total && (
                  <Alert kind="yellow" icon="alert">
                    {zip.p.failed.length === 1 ? 'One file could not be added' : `${zip.p.failed.length} files could not be added`}; the zip lists them in a note.
                    <ul style={{ margin: '6px 0 0', paddingLeft: 18 }}>{zip.p.failed.slice(0, 5).map((x, i) => <li key={i}>{x.name}: {x.why}</li>)}</ul>
                  </Alert>
                )}
              </>
            )}
          </div>
          <div className="modal-ft">
            <button className="btn btn-secondary" onClick={() => { cancel.current = true; setZip(null); }}>{zip.error || (zip.p && zip.p.done >= zip.p.total) ? 'Close' : 'Cancel'}</button>
          </div>
        </Modal>
      )}
    </div>
  );
}

// ------------------------------------------------------------------ the preview and a file's details
// compact: a phone, where a PDF inside the page shows nothing useful; Open shows it full screen.
function PreviewPanel({ f, org, compact, onClose, onRemoved }: { f: DocFile; org: string; compact?: boolean; onClose: () => void; onRemoved: () => void }) {
  const toast = useToast();
  const [url, setUrl] = useState<string | null>(null);
  const [made, setMade] = useState<Blob | null>(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(true);
  const [confirm, setConfirm] = useState(false);
  useEffect(() => {
    let gone = false; let obj: string | null = null;
    (async () => {
      try {
        if (f.kind === 'file') { const u = await viewUrl(f); if (!gone) setUrl(u); }
        else { const b = await fileBlob(org, f); if (gone) return; obj = URL.createObjectURL(b); setMade(b); setUrl(obj); }
      } catch (e) { if (!gone) setErr(cleanError(e)); }
      finally { if (!gone) setBusy(false); }
    })();
    return () => { gone = true; if (obj) URL.revokeObjectURL(obj); };
  }, [f.id]);
  const m = f.period ? Number(f.period.slice(5, 7)) : null;
  const facts: [string, ReactNode][] = [
    ['Kind', `${catLabel(f.cat)} · ${f.folder}${f.sub ? ` · ${f.sub}` : ''}`],
    ...(f.cat === 'tax' ? [['Tax', f.folder] as [string, ReactNode]] : []),
    ['Period', m ? `${MONTHS[m - 1]} ${f.year}` : f.year != null ? `${f.year}, the full year` : 'No date'],
    ['Year', f.year ?? '—'],
    ['Format', `${formatOf(f)}${f.size ? `, ${sizeLabel(f.size)}` : ''}`],
    ['File name', fileName(f)],
    ...(f.party ? [[f.source === 'upload' ? 'Uploaded by' : f.cat === 'purchases' ? 'Supplier' : f.cat === 'sales' ? 'Customer' : 'From', f.party] as [string, ReactNode]] : []),
    ...(f.amount != null ? [['Amount', N2(Number(f.amount))] as [string, ReactNode]] : []),
    ['Where it came from', SOURCE[f.source] || f.source],
    ...(f.source === 'upload' && f.at ? [['Added', fmtDay(f.at)] as [string, ReactNode]] : f.day ? [['Date', fmtDay(f.day)] as [string, ReactNode]] : []),
  ];
  const tags = [catLabel(f.cat), f.folder, f.sub, f.kind !== 'file' ? 'Made when opened' : '', f.source === 'flux' ? 'Flux' : ''].filter(Boolean) as string[];
  async function download() {
    try { downloadBlob(made || (await fileBlob(org, f)), fileName(f)); } catch (e) { toast(cleanError(e), 'err'); }
  }
  function open() {
    if (!url) return;
    const w = window.open(url, '_blank', 'noopener');
    if (!w) toast('Your browser blocked the new tab. Use Download instead.', 'err');
  }
  return (
    <div className="card docs-preview" data-testid="docs-preview">
      <div className="docs-preview-hd">
        <b className="grow" style={{ minWidth: 0, overflowWrap: 'anywhere' }}>{f.name}</b>
        <button className="x-btn" onClick={onClose} aria-label="Close the preview"><Icon name="x" size={16} color="#6B7280" /></button>
      </div>
      <div className="docs-preview-view">
        {busy ? <Spinner /> : err ? <div className="faint" style={{ padding: 12, fontSize: 13 }}>{err}</div>
          : url && isImage(f) ? <img src={url} alt={f.name} />
          : url && (isPdf(f) || f.kind !== 'file') && !compact ? <iframe src={url} title={f.name} />
          : url && compact && (isPdf(f) || f.kind !== 'file') ? <div className="stack" style={{ alignItems: 'center', gap: 6 }}><Icon name="file" size={40} color="#0072F5" /><span className="faint" style={{ fontSize: 12 }}>PDF ready. Tap Open to read it.</span></div>
          : <div className="stack" style={{ alignItems: 'center', gap: 6 }}><Icon name={fileIcon(f)} size={40} color="#9CA3AF" /><span className="faint" style={{ fontSize: 12 }}>{formatOf(f)}: download it to open</span></div>}
      </div>
      <div className="row" style={{ gap: 8, padding: '12px 16px', borderBottom: '1px solid var(--line)' }}>
        <button className="btn btn-secondary btn-sm grow" onClick={open} disabled={!url}><Icon name="external" size={14} />Open</button>
        <button className="btn btn-primary btn-sm grow" onClick={download} disabled={busy && f.kind !== 'file'}><Icon name="download" size={14} color="#fff" />Download</button>
      </div>
      <dl className="docs-facts">
        {facts.map(([k, v]) => <div key={k}><dt>{k}</dt><dd>{v}</dd></div>)}
      </dl>
      <div className="row wrap" style={{ gap: 6, padding: '0 16px 14px' }}>{tags.map((t, i) => <span key={t + i} className={'chip ' + (i === 0 ? 't-blue' : 't-grey')}>{t}</span>)}</div>
      {f.source === 'upload' && f.id.startsWith('doc:') && (
        <div style={{ padding: '0 16px 16px' }}>
          {!confirm ? <button className="btn btn-ghost btn-sm" onClick={() => setConfirm(true)}><Icon name="trash" size={14} />Take it out of Documents</button> : (
            <div className="stack" style={{ gap: 8 }}>
              <span style={{ fontSize: 13 }}>Take {f.name} out? The file is deleted.</span>
              <div className="row" style={{ gap: 8 }}>
                <button className="btn btn-secondary btn-sm" onClick={() => setConfirm(false)}>Keep it</button>
                <button className="btn btn-danger btn-sm" onClick={async () => {
                  try { await removeDocument(org, f); toast('Taken out of Documents.'); onRemoved(); } catch (e) { toast(cleanError(e), 'err'); setConfirm(false); }
                }}>Take it out</button>
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// ------------------------------------------------------------------ uploading
function UploadModal({ org, can, at, pill, onClose, onDone }: { org: string; can: Record<DocCat, boolean>; at: Place; pill: Pill; onClose: () => void; onDone: (n: number) => void }) {
  const kinds = CATS.filter((c) => can[c.id]);
  const start = (at.cat && can[at.cat] ? at.cat : pill !== 'all' && can[pill] ? pill : kinds.find((c) => c.id === 'other')?.id || kinds[0]?.id || 'other') as DocCat;
  const [cat, setCat] = useState<DocCat>(start);
  const [folder, setFolder] = useState(() => (at.folder && FOLDERS[start].includes(at.folder) ? at.folder : FOLDERS[start][0]));
  const [month, setMonth] = useState(() => (at.year != null && at.month ? `${at.year}-${String(at.month).padStart(2, '0')}` : lagosMonth()));
  const [year, setYear] = useState(() => (at.year != null ? at.year : Number(lagosMonth().slice(0, 4)) - 1));
  const [list, setList] = useState<File[]>([]);
  const [notes, setNotes] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const yearOnly = cat === 'tax' && folder === 'CIT';
  const big = list.filter((f) => f.size > MAX_UPLOAD);
  async function go() {
    setBusy(true); setErr('');
    let n = 0;
    try {
      for (const f of list) {
        await uploadDocument(org, f, { cat, folder, period: cat === 'company' || yearOnly ? null : month || null, year: yearOnly ? year : null, notes });
        n++;
      }
      onDone(n);
    } catch (e) {
      setErr(`${n ? `${n} uploaded. ` : ''}${cleanError(e)}`);
      setList(list.slice(n));
    } finally { setBusy(false); }
  }
  const thisYear = Number(lagosMonth().slice(0, 4));
  return (
    <Modal onClose={busy ? () => {} : onClose} width={520}>
      <ModalHead title="Upload into Documents" sub="Files are kept with this business, in the folder you choose." onClose={busy ? () => {} : onClose} />
      <div className="modal-body">
        <Field label="Files" hint="PDFs, photos, spreadsheets or Word files, up to 25 MB each.">
          <input type="file" multiple className="input" data-testid="docs-upload-input"
            accept=".pdf,.png,.jpg,.jpeg,.webp,.heic,.xlsx,.xls,.csv,.docx,.doc,.txt,image/*,application/pdf" onChange={(e) => setList(Array.from(e.target.files || []))} />
        </Field>
        {list.length > 0 && <div className="faint" style={{ fontSize: 12 }}>{list.map((f) => `${f.name} (${sizeLabel(f.size)})`).join(', ')}</div>}
        {big.length > 0 && <Alert kind="yellow" icon="alert">{big.map((f) => f.name).join(', ')} {big.length === 1 ? 'is' : 'are'} larger than 25 MB.</Alert>}
        <div className="row wrap" style={{ gap: 12 }}>
          <Field label="Kind" style={{ flex: '1 1 180px' }}>
            <select className="input" value={cat} onChange={(e) => { const c = e.target.value as DocCat; setCat(c); setFolder(FOLDERS[c][0]); }} data-testid="docs-upload-kind">
              {kinds.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}
            </select>
          </Field>
          <Field label="Folder" style={{ flex: '1 1 180px' }}>
            <select className="input" value={folder} onChange={(e) => setFolder(e.target.value)} data-testid="docs-upload-folder">
              {FOLDERS[cat].map((f) => <option key={f} value={f}>{f}</option>)}
            </select>
          </Field>
        </div>
        {cat === 'company' ? <div className="faint" style={{ fontSize: 12 }}>Company papers are kept without a date, under No date.</div>
          : yearOnly ? (
            <Field label="Year of account">
              <select className="input" value={year} onChange={(e) => setYear(Number(e.target.value))}>
                {Array.from({ length: 8 }, (_, i) => thisYear - i).map((y) => <option key={y} value={y}>{y}</option>)}
              </select>
            </Field>
          ) : (
            <Field label="Month it belongs to"><input className="input" type="month" value={month} onChange={(e) => setMonth(e.target.value)} max={lagosMonth()} data-testid="docs-upload-month" /></Field>
          )}
        <Field label="Note" hint="Optional, for whoever opens it later."><input className="input" value={notes} onChange={(e) => setNotes(e.target.value)} maxLength={500} /></Field>
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose} disabled={busy}>Cancel</button>
        <button className="btn btn-primary" onClick={go} disabled={busy || !list.length || big.length > 0 || (!yearOnly && cat !== 'company' && !month)} data-testid="docs-upload-go">
          {busy ? <Spinner small /> : <Icon name="upload" size={15} color="#fff" />}Upload {list.length > 1 ? `${list.length} files` : ''}
        </button>
      </div>
    </Modal>
  );
}
