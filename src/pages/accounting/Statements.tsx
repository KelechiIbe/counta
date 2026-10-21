// Financial statements under IFRS (or IFRS for SMEs), laid out the way they are signed: corporate information, the
// directors' report, the statement of directors' responsibilities, the four primary statements, the notes, the
// statement of value added and the five-year summary, with the tax computation and capital allowance schedule under the
// Nigeria Tax Act 2025 (or the Companies Income Tax Act for earlier years). The full set exports to Word, PDF and Excel, ready to sign.
import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useScreenPeriod } from '../../lib/period';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { today, yearStart } from '../../lib/api';
import { fmtDay } from '../../lib/format';
import { areport } from '../../lib/accounting';
import { buildPack, cellText, type Block, type PSection } from '../../lib/fsPack';
import { useFilingCurrent, VersionBanner } from '../../practice/VersionBanner';
import { openDoc } from '../../practice/api';
import { downloadBlob, safeName } from '../../lib/exporters';
import { Icon } from '../../components/Icon';
import { Alert, Drawer, Field, MenuButton, Pills, SkeletonRows } from '../../components/ui';
import { PeriodBar, ReportPanel, type Period } from '../../components/Books';

type Tab = 'corporate' | 'directors_report' | 'responsibilities' | 'sopl' | 'sofp' | 'soce' | 'cash_flow' | 'notes' | 'value_added' | 'five_year' | 'tax_computation' | 'capital_allowances';
const TABS: { id: Tab; label: string }[] = [
  { id: 'corporate', label: 'Company details' }, { id: 'directors_report', label: "Directors' report" }, { id: 'responsibilities', label: 'Responsibilities' },
  { id: 'sopl', label: 'Profit or loss' }, { id: 'sofp', label: 'Financial position' }, { id: 'soce', label: 'Changes in equity' }, { id: 'cash_flow', label: 'Cash flows' },
  { id: 'notes', label: 'Notes' }, { id: 'value_added', label: 'Value added' }, { id: 'five_year', label: 'Five-year summary' },
  { id: 'tax_computation', label: 'Tax computation' }, { id: 'capital_allowances', label: 'Capital allowances' },
];
const CORE = new Set<Tab>(['sopl', 'sofp', 'soce', 'cash_flow', 'notes']);

export default function Statements() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const [tab, setTab] = useState<Tab>('sofp');
  const [period, setPeriod] = useScreenPeriod(orgId, 'statements', 'ytd', inv?.org.fiscal_year_start || 1);
  const [editing, setEditing] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [showAll, setShowAll] = useState(false);
  const pack = useQuery({ queryKey: ['fs-pack', orgId, period.from, period.to], enabled: !!orgId, staleTime: 30_000,
    queryFn: () => rpc<any>('financial_statements_pack', { p_org: orgId, p_from: period.from, p_to: period.to }) });
  const model = useMemo(() => (pack.data ? buildPack(pack.data) : null), [pack.data]);
  const fsKey = pack.data?.periods?.from && pack.data?.periods?.to ? `${pack.data.periods.from}:${pack.data.periods.to}` : null;
  const acc = useFilingCurrent('fs', fsKey).data;
  if (!inv) return null;
  const canEdit = inv.me.role === 'owner' || can(inv, 'keep_books');
  const warnings = model?.warnings || [];
  const errors = warnings.filter((w) => w.level === 'error');
  const shown = showAll ? warnings : warnings.filter((w) => w.level !== 'info').slice(0, 6);

  async function exportSet(kind: 'docx' | 'pdf' | 'xlsx') {
    setBusy(kind);
    try {
      const fresh = await pack.refetch();
      if (!fresh.data) throw new Error('Could not load the statements.');
      const m = buildPack(fresh.data);
      const mod = await import('../../lib/fsExport');
      const blob = kind === 'docx' ? await mod.packDocx(m) : kind === 'pdf' ? await mod.packPdf(m) : await mod.packXlsx(m);
      downloadBlob(blob, `${safeName(`${inv!.org.name} financial statements ${period.to}`)}.${kind}`);
      const errs = m.warnings.filter((w) => w.level === 'error').length;
      toast(errs ? `Exported. Fix ${errs === 1 ? 'one thing' : `${errs} things`} on the checklist before the directors sign.` : 'Exported, ready for the directors to sign.', errs ? 'err' : undefined);
    } catch (e) { toast((e as Error).message || 'Could not make the file.', 'err'); }
    setBusy(null);
  }
  const section = model?.sections.find((s) => s.key === tab);

  return (
    <div className="container">
      <div className="row wrap" style={{ justifyContent: 'space-between', gap: 10 }}>
        <PeriodBar value={period} onChange={setPeriod} />
        <div className="row wrap">
          {canEdit && <button className="btn btn-secondary btn-sm" onClick={() => setEditing(true)}><Icon name="building" size={14} />Company details</button>}
          {acc && <button className="btn btn-secondary btn-sm" onClick={() => openDoc(acc.file_path, acc.file_name).catch((e) => toast(e.message, 'err'))}><Icon name="download" size={14} />Accountant's version</button>}
          <MenuButton label="Export full set" icon="download" className="btn btn-primary btn-sm" width={260} busy={busy ? 'Preparing…' : undefined} disabled={!model}
            items={[
              { key: 'docx', label: 'Word document', hint: 'Edit before printing; contents and page numbers included', icon: 'file', onClick: () => exportSet('docx') },
              { key: 'pdf', label: 'PDF', hint: 'Print and sign as it is', icon: 'printer', onClick: () => exportSet('pdf') },
              { key: 'xlsx', label: 'Excel workbook', hint: 'One sheet per statement, numbers kept as numbers', icon: 'layers', onClick: () => exportSet('xlsx') },
            ]} />
        </div>
      </div>
      <VersionBanner kind="fs" period={fsKey} />

      {pack.isLoading ? <div className="card card-pad"><SkeletonRows n={3} /></div> : warnings.length > 0 && (
        <div className="card card-pad stack" style={{ gap: 8 }}>
          <div className="row wrap" style={{ justifyContent: 'space-between' }}>
            <div style={{ fontWeight: 600 }}>{errors.length ? `${errors.length === 1 ? 'One thing' : `${errors.length} things`} to fix before signing` : 'Before the directors sign'}</div>
            {warnings.length > shown.length || showAll ? <button className="link" style={{ fontSize: 13 }} onClick={() => setShowAll(!showAll)}>{showAll ? 'Show less' : `Show all ${warnings.length}`}</button> : null}
          </div>
          {shown.map((w, i) => (
            <div key={i} className="row" style={{ gap: 8, alignItems: 'flex-start', fontSize: 13.5 }}>
              <Icon name={w.level === 'error' ? 'alert' : w.level === 'warn' ? 'info' : 'pencil'} size={15} color={w.level === 'error' ? '#DC2626' : w.level === 'warn' ? '#B45309' : '#6B7280'} />
              <span style={{ flex: 1 }}>{w.text}</span>
              {canEdit && w.key !== 'tax_charge' && (w.key || /director|secretary|approval/i.test(w.text)) && <button className="link" style={{ fontSize: 13, flex: 'none' }} onClick={() => setEditing(true)}>Edit</button>}
              {/RC number and (TIN|Tax ID)/.test(w.text) && <a className="link" style={{ fontSize: 13, flex: 'none' }} href="/settings#branding">Open</a>}
              {/Close the period/.test(w.text) && <a className="link" style={{ fontSize: 13, flex: 'none' }} href="/accounting/close">Open</a>}
              {/books inbox/.test(w.text) && <a className="link" style={{ fontSize: 13, flex: 'none' }} href="/accounting/inbox">Open</a>}
              {/Banking/.test(w.text) && <a className="link" style={{ fontSize: 13, flex: 'none' }} href="/accounting/banking">Open</a>}
              {(w.key === 'tax_charge' || /^Tax computation:/.test(w.text)) && <button className="link" style={{ fontSize: 13, flex: 'none' }} onClick={() => setTab('tax_computation')}>Open</button>}
            </div>
          ))}
        </div>
      )}

      <Pills value={tab} onChange={setTab} options={TABS} />
      {CORE.has(tab) ? <ReportPanel id={tab} period={period} title={tab === 'sopl' ? 'Statement of profit or loss and other comprehensive income' : areport(tab).title} />
        : pack.isLoading ? <div className="card card-pad"><SkeletonRows n={8} /></div>
        : pack.error ? <Alert kind="red" icon="alert">{(pack.error as Error).message}</Alert>
        : tab === 'tax_computation' && section ? <TaxPanel section={section} pack={pack.data} period={period} canEdit={can(inv, 'keep_books')} />
        : section && <SectionView s={section} onEdit={canEdit ? () => setEditing(true) : undefined} />}
      {editing && <CompanyDetails onClose={() => setEditing(false)} />}
    </div>
  );
}

// ---------------------------------------------------------------- one front page, drawn from the same model as the exports
function SectionView({ s, onEdit }: { s: PSection; onEdit?: () => void }) {
  return (
    <div className="card" style={{ overflow: 'hidden' }}>
      <div className="card-hd">
        <div><div style={{ fontWeight: 700, fontSize: 16 }}>{s.title}</div>{s.subtitle && <div className="faint" style={{ fontSize: 13 }}>{s.subtitle}</div>}</div>
        {onEdit && (s.key === 'corporate' || s.key === 'directors_report' || s.key === 'responsibilities') && <button className="btn btn-secondary btn-sm" onClick={onEdit}><Icon name="pencil" size={14} />Edit details and wording</button>}
      </div>
      <div className="fs-doc" style={{ padding: '18px 20px 24px', maxWidth: s.wide ? undefined : 860 }}>
        {s.blocks.map((b, i) => <BlockView key={i} b={b} />)}
      </div>
    </div>
  );
}
function BlockView({ b }: { b: Block }) {
  if (b.t === 'heading') return <div style={{ fontWeight: 700, fontSize: b.level === 2 ? 15 : 14, margin: '16px 0 6px', color: '#111827' }}>{b.text}</div>;
  if (b.t === 'para') return <p style={{ margin: '0 0 8px', paddingLeft: (b.indent || 0) * 16, lineHeight: 1.55, fontSize: 14, color: '#374151', textAlign: 'justify' }}>{b.text}</p>;
  if (b.t === 'kv') return (
    <div style={{ display: 'grid', gridTemplateColumns: 'minmax(140px, 240px) 1fr', gap: '8px 16px', fontSize: 14 }}>
      {b.items.map(([k, v], i) => <div key={i} style={{ display: 'contents' }}><div style={{ fontWeight: 600 }}>{k}</div><div style={{ whiteSpace: 'pre-wrap', color: /^To be completed/.test(v) ? '#B45309' : undefined }}>{v}</div></div>)}
    </div>
  );
  if (b.t === 'sign') return (
    <div className="row wrap" style={{ gap: 32, marginTop: 18 }}>
      {b.items.map((it, i) => (
        <div key={i} style={{ minWidth: 220 }}>
          <div style={{ borderBottom: '1px dotted #9CA3AF', height: 40 }} />
          <div style={{ fontWeight: 600, marginTop: 6 }}>{it.name || <span className="faint">Name</span>}</div>
          <div className="faint" style={{ fontSize: 12 }}>{it.role}</div>
        </div>
      ))}
    </div>
  );
  const amount = (t: string) => t === 'money' || t === 'pct' || t === 'number';
  return (
    <div className="tbl" style={{ margin: '6px 0 12px' }}>
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13.5, minWidth: b.cols.length > 4 ? 640 : 0 }}>
        <thead><tr>{b.cols.map((c) => <th key={c.key} style={{ textAlign: amount(c.type) ? 'right' : c.type === 'note' ? 'center' : 'left', fontSize: 11.5, color: '#6B7280', fontWeight: 600, padding: '6px 8px', whiteSpace: 'pre-line', borderBottom: amount(c.type) ? '1px solid #111827' : undefined, verticalAlign: 'bottom' }}>{c.label}</th>)}</tr></thead>
        <tbody>
          {b.rows.map((r, i) => {
            const strong = ['heading', 'subtotal', 'total'].includes(r.style);
            return (
              <tr key={i}>
                {b.cols.map((c, j) => (
                  <td key={c.key} className={amount(c.type) ? 'num' : undefined} style={{
                    textAlign: amount(c.type) ? 'right' : c.type === 'note' ? 'center' : 'left', padding: '5px 8px', paddingLeft: j === 0 ? 8 + r.indent * 16 : 8,
                    fontWeight: strong || r.style === 'subheading' ? 600 : 400, fontStyle: r.style === 'subheading' ? 'italic' : undefined, whiteSpace: amount(c.type) ? 'nowrap' : undefined,
                    borderTop: amount(c.type) && (r.style === 'subtotal' || r.style === 'total') ? '1px solid #111827' : undefined,
                    borderBottom: amount(c.type) && r.style === 'total' ? '3px double #111827' : undefined,
                  }}>{cellText(c, r.cells[c.key])}</td>
                ))}
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

// ---------------------------------------------------------------- the tax computation (worked on in Tax returns), and posting its charge
function TaxPanel({ section, pack, period, canEdit }: { section: PSection; pack: any; period: Period; canEdit: boolean }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const tc = pack?.tax_computation?.extra || {};
  const st = tc.settings || {};
  const fig = tc.figures || {};
  const [busy, setBusy] = useState(false);
  const refresh = () => Promise.all(['fs-pack', 'report', 'ledger', 'cit-years', 'cit-year'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
  async function post() {
    setBusy(true);
    try {
      const r = await rpc<any>('post_tax_charge', { p_org: orgId, p_from: period.from, p_to: period.to });
      toast(r.journal_ref ? `Tax charge posted in ${r.journal_ref}` : 'No tax to charge for this period'); await refresh();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  const legacy = fig.regime === 'LEGACY_CITA';
  const charge = Number(fig.cit || 0) + Number(fig.levy || 0) + Number(fig.topup || 0);
  const inBooks = Number(fig.tax_in_accounts || 0);
  const N = (v: unknown) => Number(v || 0).toLocaleString('en-NG', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return (
    <div className="stack" style={{ gap: 12 }}>
      <div className="card card-pad stack" style={{ gap: 10 }}>
        <div className="row wrap" style={{ justifyContent: 'space-between', gap: 10 }}>
          <div className="row wrap" style={{ gap: 18 }}>
            <div><div className="faint" style={{ fontSize: 12 }}>Total profit</div><div style={{ fontWeight: 700, fontSize: 18 }} className="num">₦{N(fig.total_profit)}</div></div>
            <div><div className="faint" style={{ fontSize: 12 }}>Tax charge</div><div style={{ fontWeight: 700, fontSize: 18 }} className="num">₦{N(charge)}</div></div>
            <div><div className="faint" style={{ fontSize: 12 }}>Payable after WHT credits</div><div style={{ fontWeight: 700, fontSize: 18 }} className="num">₦{N(fig.payable)}</div></div>
            <div><div className="faint" style={{ fontSize: 12 }}>In the accounts</div><div style={{ fontWeight: 700, fontSize: 18, color: Math.abs(charge - inBooks) >= 1 ? '#B45309' : undefined }} className="num">₦{N(inBooks)}</div></div>
          </div>
          <div className="row wrap">
            {fig.year && <Link className="btn btn-secondary btn-sm" to={`/tax/cit?year=${fig.year}`}><Icon name="pencil" size={14} />{canEdit ? 'Adjustments, losses and the return' : 'Open the tax return'}</Link>}
            {canEdit && <button className="btn btn-primary btn-sm" disabled={busy || !fig.company} onClick={post}>{busy ? 'Posting…' : st.posted_ref ? 'Post again' : 'Post the tax charge'}</button>}
          </div>
        </div>
        <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>
          {st.posted_ref ? `Posted in ${st.posted_ref} for the period to ${fmtDay(st.posted_to)}. Posting again replaces it. `
            : `Posting puts companies income tax (7501 to 2208) and the ${legacy ? 'tertiary education tax' : 'development levy'} (7502 to 2209) in the accounts on the last day of the period. `}
          {fig.year ? `This is the ${fig.year} return (year of assessment ${fig.yoa}) under the ${fig.law || (legacy ? 'Companies Income Tax Act' : 'Nigeria Tax Act 2025')}. ` : ''}
          Adjustments, losses brought forward and capital allowances are kept with the return in Tax returns; each prints with its reason.
        </div>
      </div>
      <SectionView s={section} />
    </div>
  );
}

// ---------------------------------------------------------------- corporate information, directors and the wording only the directors can give
interface Director { name: string; role: string; frc_number: string; appointed: string; resigned: string }
const ROLES = ['Chairman', 'Managing Director', 'Chief Executive Officer', 'Executive Director', 'Non-executive Director', 'Director'];
const WORDING: [string, string, string][] = [
  ['review', 'Business review', 'Revenue, profit and the main things that happened in the year. Leave empty for a summary from the figures.'],
  ['dividend', 'Dividend', 'For example: The directors recommend a dividend of ₦0.50 per share.'],
  ['going_concern', 'Going concern', 'Leave empty for the standard statement that the Company will continue in business.'],
  ['events_after', 'Events after the reporting period', 'Anything material since the year end, or leave empty for "none".'],
  ['contingencies', 'Contingent liabilities', 'Lawsuits, guarantees or claims, or leave empty for "none".'],
  ['commitments', 'Capital commitments', 'Contracts signed for assets not yet received, or leave empty for "none".'],
  ['future', 'Future developments', 'Plans for the coming year (optional).'],
  ['directors_interests', "Directors' interests", 'Shares each director holds, or leave empty for the standard wording.'],
  ['pledged', 'Assets pledged as security', 'Leave empty if none are pledged.'],
  ['employees', 'Employment policy', 'Leave empty for the standard paragraph on employees, disability and safety.'],
];

function CompanyDetails({ onClose }: { onClose: () => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const o = (inv?.org || {}) as Record<string, any>;
  const [busy, setBusy] = useState(false);
  const [dirs, setDirs] = useState<Director[]>([]);
  const [f, setF] = useState<Record<string, string | boolean>>({});
  const [n, setN] = useState<Record<string, string>>({});
  useEffect(() => {
    setDirs((o.directors || []).map((d: any) => ({ name: d.name || '', role: d.role || 'Director', frc_number: d.frc_number || '', appointed: d.appointed || '', resigned: d.resigned || '' })));
    setF({ company_secretary: o.company_secretary || '', auditors: o.auditors || '', audit_exempt: !!o.audit_exempt, bankers: o.bankers || '', solicitors: o.solicitors || '',
      registered_office: o.registered_office || o.address || '', incorporation_date: o.incorporation_date || '',
      authorised_shares: String(o.share_info?.authorised_shares ?? ''), issued_shares: String(o.share_info?.issued_shares ?? ''), nominal_value: String(o.share_info?.nominal_value ?? '') });
    setN({ approved_on: '', employees_count: '', ...Object.fromEntries(Object.entries(o.fs_narrative || {}).map(([k, v]) => [k, String(v ?? '')])) });
  }, [o.id]); // eslint-disable-line react-hooks/exhaustive-deps
  const set = (k: string, v: string | boolean) => setF((x) => ({ ...x, [k]: v }));
  const setD = (i: number, k: keyof Director, v: string) => setDirs((ds) => ds.map((d, j) => (j === i ? { ...d, [k]: v } : d)));
  async function save() {
    setBusy(true);
    try {
      const num = (v: unknown) => (String(v ?? '').trim() === '' ? null : Number(String(v).replace(/,/g, '')));
      await rpc('update_corporate_info', { p_org: orgId, p_patch: {
        directors: dirs.filter((d) => d.name.trim()), company_secretary: f.company_secretary, auditors: f.auditors, audit_exempt: !!f.audit_exempt, bankers: f.bankers,
        solicitors: f.solicitors, registered_office: f.registered_office, incorporation_date: f.incorporation_date || null,
        share_info: { authorised_shares: num(f.authorised_shares), issued_shares: num(f.issued_shares), nominal_value: num(f.nominal_value) },
        fs_narrative: n,
      } });
      await Promise.all([qc.invalidateQueries({ queryKey: ['inv'] }), qc.invalidateQueries({ queryKey: ['fs-pack'] })]);
      toast('Company details saved'); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <Drawer onClose={onClose} width={720}>
      <div className="drawer-hd"><div className="grow"><div className="drawer-title">Company details for the statements</div>
        <div className="muted" style={{ fontSize: 13 }}>Directors usually arrive from your TaxStreem onboarding. Anything you change here prints on the next export.</div></div>
        <button className="x-btn" onClick={onClose} aria-label="Close"><Icon name="x" size={18} /></button></div>
      <div className="drawer-body stack" style={{ gap: 18 }}>
        <div className="stack" style={{ gap: 8 }}>
          <div className="row" style={{ justifyContent: 'space-between' }}><div className="label">Directors</div>
            <button className="btn btn-secondary btn-xs" onClick={() => setDirs((d) => [...d, { name: '', role: d.length ? 'Director' : 'Chairman', frc_number: '', appointed: '', resigned: '' }])}><Icon name="plus" size={12} />Add a director</button></div>
          {!dirs.length && <Alert kind="amber" icon="info">Add at least two directors. The first two who have not resigned (the chair, then the managing director) sign the statements.</Alert>}
          {dirs.map((d, i) => (
            <div key={i} className="card" style={{ padding: 12, borderRadius: 12 }}>
              <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr 1fr', gap: 8 }}>
                <Field label="Full name"><input className="input" value={d.name} onChange={(e) => setD(i, 'name', e.target.value)} placeholder="Chief Adaeze Okafor" /></Field>
                <Field label="Role"><input className="input" list="dir-roles" value={d.role} onChange={(e) => setD(i, 'role', e.target.value)} /></Field>
                <Field label="FRC number"><input className="input" value={d.frc_number} onChange={(e) => setD(i, 'frc_number', e.target.value)} placeholder="FRC/2020/IODN/00000012345" /></Field>
                <Field label="Appointed"><input className="input" type="date" value={d.appointed} onChange={(e) => setD(i, 'appointed', e.target.value)} /></Field>
                <Field label="Resigned"><input className="input" type="date" value={d.resigned} onChange={(e) => setD(i, 'resigned', e.target.value)} /></Field>
                <div style={{ display: 'flex', alignItems: 'flex-end' }}><button className="btn btn-ghost btn-sm" onClick={() => setDirs((ds) => ds.filter((_, j) => j !== i))}><Icon name="trash" size={14} />Remove</button></div>
              </div>
            </div>
          ))}
          <datalist id="dir-roles">{ROLES.map((r) => <option key={r} value={r} />)}</datalist>
        </div>
        <div className="stack" style={{ gap: 10 }}>
          <div className="label">Corporate information</div>
          <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
            <Field label="Company secretary"><input className="input" value={String(f.company_secretary || '')} onChange={(e) => set('company_secretary', e.target.value)} /></Field>
            <Field label="Date of incorporation"><input className="input" type="date" value={String(f.incorporation_date || '')} onChange={(e) => set('incorporation_date', e.target.value)} /></Field>
            <Field label="Bankers"><input className="input" value={String(f.bankers || '')} onChange={(e) => set('bankers', e.target.value)} placeholder="Guaranty Trust Bank Plc" /></Field>
            <Field label="Solicitors"><input className="input" value={String(f.solicitors || '')} onChange={(e) => set('solicitors', e.target.value)} /></Field>
            <Field label="Auditors"><input className="input" disabled={!!f.audit_exempt} value={String(f.auditors || '')} onChange={(e) => set('auditors', e.target.value)} placeholder="Firm name, Chartered Accountants" /></Field>
            <label className="check" style={{ alignSelf: 'end', paddingBottom: 10 }}><input type="checkbox" checked={!!f.audit_exempt} onChange={(e) => set('audit_exempt', e.target.checked)} />Small company exempt from audit (CAMA 2020 s.402)</label>
          </div>
          <Field label="Registered office"><textarea className="input" value={String(f.registered_office || '')} onChange={(e) => set('registered_office', e.target.value)} style={{ minHeight: 56 }} /></Field>
          <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10 }}>
            <Field label="Authorised shares"><input className="input" inputMode="numeric" value={String(f.authorised_shares || '')} onChange={(e) => set('authorised_shares', e.target.value)} /></Field>
            <Field label="Issued shares" hint="Used for earnings per share."><input className="input" inputMode="numeric" value={String(f.issued_shares || '')} onChange={(e) => set('issued_shares', e.target.value)} /></Field>
            <Field label="Nominal value per share (₦)"><input className="input" inputMode="decimal" value={String(f.nominal_value || '')} onChange={(e) => set('nominal_value', e.target.value)} /></Field>
          </div>
        </div>
        <div className="stack" style={{ gap: 10 }}>
          <div className="label">Approval and wording</div>
          <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
            <Field label="Date the board approves the statements" hint="Leave empty to print a blank line."><input className="input" type="date" value={n.approved_on || ''} onChange={(e) => setN({ ...n, approved_on: e.target.value })} /></Field>
            <Field label="Average number of employees"><input className="input" inputMode="numeric" value={n.employees_count || ''} onChange={(e) => setN({ ...n, employees_count: e.target.value })} /></Field>
          </div>
          {WORDING.map(([k, l, hint]) => (
            <Field key={k} label={l} hint={hint}><textarea className="input" value={n[k] || ''} onChange={(e) => setN({ ...n, [k]: e.target.value })} style={{ minHeight: 56 }} /></Field>
          ))}
        </div>
      </div>
      <div className="drawer-ft"><button className="btn btn-primary" disabled={busy} onClick={save}>{busy ? 'Saving…' : 'Save'}</button><button className="btn btn-ghost" onClick={onClose}>Cancel</button></div>
    </Drawer>
  );
}
