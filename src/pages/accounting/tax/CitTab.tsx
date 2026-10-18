// Companies income tax, year by year: from the first year Counta prepares (2023 accounts at the earliest) to the year
// running now. Each year is computed from the books, or from audited accounts or a trial balance read in by AI (and checked
// line by line), under the law of its year of assessment. An approved year is frozen, downloads as the Rev360 template and
// goes to TaxStreem Flux, which files it.
import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../../state/session';
import { ai, rpc, signedDoc, supabase } from '../../../lib/supabase';
import { edge, money } from '../../../lib/api';
import { N2, fmtDay, when } from '../../../lib/format';
import { CA_CATEGORIES, CIT_STATUS, SECTIONS, SOURCE_LABEL, TAX_KEYS, WVAT_AGENTS, lawLong, lawShort, useCitYear, useCitYears, useTaxProfile } from '../../../lib/tax';
import { TB_FIELDS, tbRows } from '../../../lib/moveBooks';
import { Icon } from '../../../components/Icon';
import { Alert, Drawer, Empty, Field, Modal, ModalHead, Pills, SkeletonRows, Spinner, Stat } from '../../../components/ui';
import { SheetRows } from '../../../components/SheetRows';

type Sub = 'computation' | 'figures' | 'adjustments' | 'allowances' | 'brought' | 'statements';
const CLASS_LABEL: Record<string, string> = { SMALL: 'Small company', MEDIUM: 'Medium company', LARGE: 'Large company', REGULAR: 'Company' };

export function useTaxRefresh() {
  const qc = useQueryClient();
  return () => Promise.all(TAX_KEYS.map((k) => qc.invalidateQueries({ queryKey: [k] })));
}

// Files come back as signed links that download (the link asks for an attachment), so the page stays where it is.
export function downloadUrl(url: string) {
  const a = document.createElement('a');
  a.href = url; a.rel = 'noopener';
  document.body.appendChild(a); a.click(); a.remove();
}
// A document to read opens in a new tab, opened at the click so the browser does not block it while the link is made.
export async function openInTab(get: () => Promise<string | null>) {
  const w = window.open('', '_blank');
  const url = await get().catch(() => null);
  if (!url) { w?.close(); return false; }
  if (w) w.location.href = url; else window.location.href = url;
  return true;
}

const amt = (v: unknown) => { const n = Number(v || 0); return n < 0 ? `(${N2(-n)})` : N2(n); };

export default function CitTab({ year, setYear }: { year: number | null; setYear: (y: number) => void }) {
  const years = useCitYears();
  const [profile, setProfile] = useState(false);
  const list: any[] = years.data?.years || [];
  // Open the latest year that has ended, unless one was asked for.
  useEffect(() => {
    if (year || !list.length) return;
    setYear((list.find((y) => y.ended && y.has_data) || list.find((y) => y.ended) || list[0]).year);
  }, [list.length]); // eslint-disable-line react-hooks/exhaustive-deps
  if (years.isLoading) return <SkeletonRows n={6} />;
  if (years.error) return <Alert kind="yellow" icon="shield">{(years.error as Error).message}</Alert>;
  return (
    <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '270px minmax(0,1fr)', gap: 16, alignItems: 'start' }}>
      <div className="stack" style={{ gap: 8 }}>
        {list.map((y) => {
          const st = CIT_STATUS[y.status] || CIT_STATUS.draft;
          const on = y.year === year;
          return (
            <button key={y.year} className="card card-pad" onClick={() => setYear(y.year)} aria-pressed={on}
              style={{ textAlign: 'left', cursor: 'pointer', border: on ? '1.5px solid #0072F5' : undefined, padding: 14, background: on ? '#F5F9FF' : undefined }}>
              <div className="row" style={{ justifyContent: 'space-between' }}><b>{y.year} accounts</b><span className={'chip ' + st.tone}>{st.label}</span></div>
              <div className="faint" style={{ fontSize: 12, marginTop: 4 }}>Year of assessment {y.yoa} · {lawShort(y.regime)}{y.ended ? ` · due ${fmtDay(y.due)}` : ' · running'}</div>
              <div className="row" style={{ justifyContent: 'space-between', marginTop: 8, fontSize: 13 }}>
                {y.has_data || y.source === 'books' ? <span>Tax payable <b className="num">{N2(y.payable)}</b></span> : <span className="muted">No figures yet</span>}
                {Number(y.blocks) > 0 && y.status === 'draft' && <span style={{ color: '#B45309', fontSize: 12 }}>{y.blocks} to settle</span>}
              </div>
            </button>
          );
        })}
        <button className="btn btn-ghost btn-sm" onClick={() => setProfile(true)} style={{ justifyContent: 'flex-start' }}><Icon name="building" size={14} />The company's tax profile</button>
        <div className="faint" style={{ fontSize: 12, lineHeight: 1.5, padding: '0 4px' }}>
          Accounts for 2023 and 2024 are computed under the Companies Income Tax Act; 2025 accounts onwards under the Nigeria Tax Act 2025.
        </div>
      </div>
      <div style={{ minWidth: 0 }}>{year ? <CitYear key={year} year={year} /> : <Empty>Choose a year.</Empty>}</div>
      {profile && <ProfileDrawer onClose={() => setProfile(false)} />}
    </div>
  );
}

// ---------------------------------------------------------------- one year
function CitYear({ year }: { year: number }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const q = useCitYear(year);
  const [sub, setSub] = useState<Sub>('computation');
  const [busy, setBusy] = useState<string | null>(null);
  const [modal, setModal] = useState<null | 'approve' | 'reopen' | 'send'>(null);
  const [reason, setReason] = useState('');
  const [flux, setFlux] = useState<string | null>(null);
  const d = q.data;
  if (q.isLoading) return <SkeletonRows n={8} />;
  if (q.error) return <Alert kind="yellow" icon="shield">{(q.error as Error).message}</Alert>;
  if (!d) return null;
  const comp = d.computation || {};
  const fig = comp.figures || {};
  const row = d.row || {};
  const checks: any[] = comp.checks || [];
  const blocks = checks.filter((c) => c.severity === 'block');
  const st = CIT_STATUS[row.status] || CIT_STATUS.draft;
  const legacy = comp.regime === 'LEGACY_CITA';
  const frozen = !['draft', 'rejected'].includes(row.status);
  const canSend = ['approved', 'rejected'].includes(row.status) && d.can_approve && !!row.afs_path;

  async function act(key: string, fn: () => Promise<any>, ok?: string) {
    setBusy(key);
    try { const r = await fn(); if (ok) toast(ok); await refresh(); return r; } catch (e) { toast((e as Error).message, 'err'); } finally { setBusy(null); }
  }
  async function download() {
    setBusy('download');
    try {
      const r = await edge<any>('tax-files', { action: 'cit_file', org_id: orgId, year });
      if (r.ok === false) throw new Error(r.error || 'Could not make the file.');
      const broken = (r.ties || []).filter((t: any) => !t.ok);
      if (broken.length) toast(`The draft does not tie yet: ${broken.map((t: any) => t.label).join(', ')}`, 'err');
      downloadUrl(r.url);
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }
  async function send() {
    setBusy('send'); setFlux(null);
    try {
      const r = await edge<any>('tax-files', { action: 'cit_send', org_id: orgId, year });
      if (r.ok === false) { if (r.reason === 'not_configured') setFlux(r.error); else toast(r.error || 'Flux did not take it.', 'err'); }
      else { toast(`Sent to TaxStreem Flux${r.flux_ref ? ` (${r.flux_ref})` : ''}`); setModal(null); }
      await refresh();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }

  return (
    <div className="stack" style={{ gap: 14 }}>
      <div className="card card-pad stack" style={{ gap: 12 }}>
        <div className="row wrap" style={{ justifyContent: 'space-between', gap: 10, alignItems: 'flex-start' }}>
          <div style={{ minWidth: 0 }}>
            <div className="row wrap" style={{ gap: 8 }}>
              <span style={{ fontSize: 20, fontWeight: 700 }}>{year} accounts</span>
              <span className={'chip ' + st.tone}>{st.label}</span>
              {comp.class && <span className="chip t-grey">{CLASS_LABEL[comp.class] || comp.class}</span>}
            </div>
            <div className="muted" style={{ fontSize: 13, marginTop: 4 }}>
              Year of assessment {comp.yoa} · {fmtDay(d.period?.from)} to {fmtDay(d.period?.to)} · {lawLong(comp.regime)}
            </div>
          </div>
          <div className="row wrap">
            <button className="btn btn-secondary btn-sm" disabled={!!busy} onClick={download}>
              {busy === 'download' ? <Spinner small /> : <Icon name="download" size={14} />}{frozen ? 'Rev360 file' : 'Draft Rev360 file'}</button>
            {d.can_approve && ['draft', 'rejected'].includes(row.status) && (
              <button className="btn btn-primary btn-sm" disabled={!!busy || blocks.length > 0} title={blocks.length ? 'Settle the points marked to fix first' : undefined}
                onClick={() => setModal('approve')}><Icon name="check" size={14} color="#fff" />Approve</button>)}
            {canSend && <button className="btn btn-primary btn-sm" disabled={!!busy} onClick={() => setModal('send')}><Icon name="send" size={14} color="#fff" />Send to Flux</button>}
            {d.can_approve && row.status === 'approved' && <button className="btn btn-ghost btn-sm" disabled={!!busy} onClick={() => { setReason(''); setModal('reopen'); }}><Icon name="undo" size={14} />Reopen</button>}
          </div>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(128px,1fr))', gap: 8 }}>
          <Stat label="Profit before tax" value={amt(fig.profit_before_tax)} />
          <Stat label="Total profits" value={amt(fig.total_profits)} sub={Number(fig.loss_relief) ? `after ${N2(fig.loss_relief)} of losses` : undefined} />
          <Stat label="Total tax" value={N2(fig.total_tax)} sub={legacy ? `CIT ${N2(fig.cit_payable)} · TET ${N2(fig.tertiary_education_tax)}` : `CIT ${N2(fig.cit_payable)} · levy ${N2(fig.development_levy)}`} />
          <Stat label="Payable" value={N2(fig.payable)} color="#0072F5" sub={Number(fig.wht_credit) ? `after ${N2(fig.wht_credit)} of WHT credits` : undefined} />
          <Stat label="Due" value={comp.ended ? fmtDay(comp.due) : 'Year still running'} />
        </div>
        {row.status === 'approved' && <div className="faint" style={{ fontSize: 12 }}>Approved by {row.approved_by || 'someone'} ({when(row.approved_at)}). The figures are frozen; reopen the year to change them.</div>}
        {(row.flux_status || ['sent', 'filed', 'rejected'].includes(row.status)) && <FluxState row={row} />}
        {flux && <Alert kind="blue" icon="info">{flux}</Alert>}
      </div>

      {checks.length > 0 && !frozen && (
        <div className="card" style={{ overflow: 'hidden' }}>
          {checks.map((c, i) => (
            <div key={c.id + i} className="tr" style={{ gridTemplateColumns: '24px minmax(0,1fr)', gap: 10, fontSize: 13 }}>
              <Icon name={c.severity === 'block' ? 'alert' : c.severity === 'warn' ? 'info' : 'check'} size={15} color={c.severity === 'block' ? '#DC2626' : c.severity === 'warn' ? '#B45309' : '#6B7280'} />
              <span>{c.text}{c.severity === 'block' && <span className="faint"> · to fix before approving</span>}</span>
            </div>
          ))}
        </div>
      )}

      <Pills value={sub} onChange={setSub} options={[{ id: 'computation', label: 'Computation' }, { id: 'figures', label: 'Figures' }, { id: 'adjustments', label: 'Adjustments' },
        { id: 'allowances', label: 'Capital allowances' }, { id: 'brought', label: 'Brought forward' }, { id: 'statements', label: 'Audited accounts' }]} />
      {sub === 'computation' && <Computation d={d} />}
      {sub === 'figures' && <Figures d={d} year={year} />}
      {sub === 'adjustments' && <Adjustments d={d} year={year} />}
      {sub === 'allowances' && <Allowances d={d} year={year} />}
      {sub === 'brought' && <BroughtForward d={d} year={year} />}
      {sub === 'statements' && <Statements d={d} year={year} />}

      {modal === 'approve' && (
        <Modal onClose={() => setModal(null)} width={500}>
          <ModalHead title={`Approve the ${year} return`} sub={`Year of assessment ${comp.yoa}`} onClose={() => setModal(null)} />
          <div className="modal-body stack" style={{ gap: 10 }}>
            <div className="row" style={{ justifyContent: 'space-between' }}><span>Total tax</span><b className="num">{N2(fig.total_tax)}</b></div>
            <div className="row" style={{ justifyContent: 'space-between' }}><span>Less WHT credits</span><span className="num">{N2(fig.wht_credit)}</span></div>
            <div className="row" style={{ justifyContent: 'space-between', fontWeight: 700 }}><span>Payable</span><span className="num">{N2(fig.payable)}</span></div>
            <Alert kind="grey" icon="lock">Approving freezes the figures, the computation, the template and the fixed asset declaration as they are now. Later changes to the books do not alter an approved return.</Alert>
            {checks.filter((c) => c.severity === 'warn').length > 0 && <Alert kind="amber" icon="info">{checks.filter((c) => c.severity === 'warn').map((c) => c.text).join(' ')}</Alert>}
          </div>
          <div className="modal-ft"><button className="btn btn-secondary" onClick={() => setModal(null)}>Cancel</button>
            <button className="btn btn-primary" disabled={!!busy} onClick={async () => { if (await act('approve', () => rpc('approve_cit_year', { p_org: orgId, p_year: year }), `${year} return approved`)) setModal(null); }}>Approve</button></div>
        </Modal>
      )}
      {modal === 'reopen' && (
        <Modal onClose={() => setModal(null)} width={480}>
          <ModalHead title={`Reopen the ${year} return`} onClose={() => setModal(null)} />
          <div className="modal-body stack" style={{ gap: 10 }}>
            <div className="muted" style={{ fontSize: 13 }}>The approval and the frozen file are cleared, and the year is worked out again from the current figures.</div>
            <Field label="Why"><input className="input" autoFocus value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
          </div>
          <div className="modal-ft"><button className="btn btn-secondary" onClick={() => setModal(null)}>Cancel</button>
            <button className="btn btn-primary" disabled={!!busy || reason.trim().length < 3} onClick={async () => { if (await act('reopen', () => rpc('reopen_cit_year', { p_org: orgId, p_year: year, p_reason: reason }), 'Reopened')) setModal(null); }}>Reopen</button></div>
        </Modal>
      )}
      {modal === 'send' && (
        <Modal onClose={() => setModal(null)} width={500}>
          <ModalHead title="Send to TaxStreem Flux" sub={`${year} accounts · year of assessment ${comp.yoa}`} onClose={() => setModal(null)} />
          <div className="modal-body stack" style={{ gap: 10, fontSize: 14 }}>
            <div>Flux files the return on Rev360 with:</div>
            <div className="stack" style={{ gap: 4, fontSize: 13 }}>
              <span><Icon name="check" size={13} color="#15803D" /> the Rev360 CIT template filled from the approved figures</span>
              <span><Icon name="check" size={13} color="#15803D" /> the audited financial statements you attached</span>
              <span><Icon name="check" size={13} color="#15803D" /> the fixed asset declaration and the computation</span>
            </div>
            <div className="row" style={{ justifyContent: 'space-between', fontWeight: 700 }}><span>Tax payable</span><span className="num">{N2(fig.payable)}</span></div>
            {flux && <Alert kind="blue" icon="info">{flux}</Alert>}
          </div>
          <div className="modal-ft"><button className="btn btn-secondary" onClick={() => setModal(null)}>Cancel</button>
            <button className="btn btn-primary" disabled={!!busy} onClick={send}>{busy === 'send' ? 'Sending…' : 'Send'}</button></div>
        </Modal>
      )}
    </div>
  );
}

function FluxState({ row }: { row: any }) {
  const text = row.status === 'filed' ? `Filed on Rev360${row.filed_at ? ' ' + when(row.filed_at) : ''}${row.acknowledgement_ref ? ` · acknowledgement ${row.acknowledgement_ref}` : ''}.`
    : row.status === 'rejected' ? `Flux sent it back${row.flux_message ? `: ${row.flux_message}` : '.'} Fix the figures and approve again.`
    : row.flux_status === 'send_failed' ? `Not sent: ${row.flux_message || 'Flux did not take it.'}`
    : row.status === 'sent' ? `With Flux${row.flux_ref ? ` (${row.flux_ref})` : ''}${row.flux_sent_at ? ` since ${when(row.flux_sent_at)}` : ''}${row.flux_message ? ` · ${row.flux_message}` : ''}.` : row.flux_message;
  if (!text) return null;
  return <Alert kind={row.status === 'filed' ? 'green' : row.status === 'rejected' || row.flux_status === 'send_failed' ? 'red' : 'blue'} icon={row.status === 'filed' ? 'check' : 'send'}>{text}</Alert>;
}

// ---------------------------------------------------------------- the computation
function Computation({ d }: { d: any }) {
  const comp = d.computation || {};
  const fig = comp.figures || {};
  return (
    <div className="stack" style={{ gap: 12 }}>
      <div className="card" style={{ overflow: 'hidden' }}>
        {(comp.rows || []).map((r: any) => {
          const strong = r._style === 'subtotal' || r._style === 'total';
          return (
            <div key={r.id} className="tr" style={{ gridTemplateColumns: 'minmax(0,1fr) 150px', fontWeight: strong ? 700 : undefined, background: r._style === 'total' ? '#F5F9FF' : strong ? '#FAFAFA' : undefined }}>
              <span style={{ minWidth: 0 }}>{r.line}{r.basis && <span className="faint" style={{ display: 'block', fontSize: 12, fontWeight: 400 }}>{r.basis}</span>}</span>
              <span className="right num">{amt(r.amount)}</span>
            </div>
          );
        })}
      </div>
      {Number(fig.interest_excess) > 0 && <Alert kind="grey" icon="info">Interest to connected persons above 30% of EBITDA ({N2(fig.interest_excess)}) is added back and carried forward.</Alert>}
      <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>
        Carried forward to {Number(comp.year) + 1}: losses {N2(comp.cf?.losses)}, unused capital allowances {N2(comp.cf?.ca)}
        {(comp.cf?.interest || []).length ? `, disallowed interest ${N2((comp.cf.interest as any[]).reduce((a, x) => a + Number(x.amount || 0), 0))}` : ''}.
        Computed under the {comp.rulebook?.law || lawLong(comp.regime)}; rules {comp.rulebook?.id}{comp.rulebook?.status !== 'approved' ? ' (awaiting TaxStreem sign-off)' : ''}.
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- the template lines
function Figures({ d, year }: { d: any; year: number }) {
  const [all, setAll] = useState(false);
  const [q, setQ] = useState('');
  const [edit, setEdit] = useState<any>(null);
  const lines: any[] = (d.lines || []).filter((l: any) => l.sheet !== 'PROFIT_ADJUSTMENT' && l.sheet !== 'USER_INPUT');
  const t = d.computation?.totals || {};
  const fig = d.computation?.figures || {};
  const term = q.trim().toLowerCase();
  const shown = (l: any) => (all || Number(l.amount) !== 0 || l.override || l.imported) && (!term || l.label.toLowerCase().includes(term));
  const totalAssets = Number(t.total_assets || 0), totalEL = Number(t.total_equity_liabilities || 0);
  return (
    <div className="stack" style={{ gap: 12 }}>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(150px,1fr))', gap: 8 }}>
        <Stat label="Revenue" value={N2(fig.turnover)} />
        <Stat label="Profit before tax" value={amt(fig.profit_before_tax)} />
        <Stat label="Total assets" value={N2(totalAssets)} />
        <Stat label="Equity and liabilities" value={N2(totalEL)} color={Math.abs(totalAssets - totalEL) >= 1 ? '#DC2626' : undefined}
          sub={Math.abs(totalAssets - totalEL) >= 1 ? `differs by ${N2(totalAssets - totalEL)}` : 'balances'} />
      </div>
      <div className="row wrap" style={{ justifyContent: 'space-between' }}>
        <div className="row" style={{ flex: 1, minWidth: 200 }}><Icon name="search" size={15} color="#9CA3AF" /><input className="input input-sm" placeholder="Find a line" value={q} onChange={(e) => setQ(e.target.value)} /></div>
        <label className="check" style={{ fontSize: 13 }}><input type="checkbox" checked={all} onChange={(e) => setAll(e.target.checked)} />Show every line of the template</label>
      </div>
      {d.row?.source === 'imported' && !Object.keys(d.row?.imported || {}).length && (
        <Alert kind="blue" icon="info">No figures yet. Read them from the audited accounts or a trial balance under Audited accounts, or tick "Show every line" and enter them.</Alert>
      )}
      {SECTIONS.map((s) => {
        const ls = lines.filter((l) => l.section === s.id);
        const vis = ls.filter(shown);
        if (!vis.length) return null;
        return (
          <div key={s.id} className="card" style={{ overflow: 'hidden' }}>
            <div className="tr head shade" style={{ gridTemplateColumns: 'minmax(0,1fr) 150px' }}><b>{s.label}</b><b className="right num">{amt(ls.reduce((a, l) => a + Number(l.amount || 0), 0))}</b></div>
            {vis.map((l) => {
              const src = SOURCE_LABEL[l.source] || SOURCE_LABEL.books;
              const conf = l.imported?.confidence;
              return (
                <div key={l.cell} className={'tr' + (d.can_edit ? ' click' : '')} onClick={() => d.can_edit && setEdit(l)} style={{ gridTemplateColumns: 'minmax(0,1fr) auto 150px', gap: 8 }}>
                  <span style={{ minWidth: 0 }}>{l.label}<span className="faint" style={{ display: 'block', fontSize: 11 }}>{l.cell.replace(/_/g, ' ').replace('!', ' · ')}{l.note ? ` · ${l.note}` : ''}</span></span>
                  <span className="row" style={{ gap: 4 }}>
                    {(l.source !== 'books' || Number(l.amount) !== 0) && <span className={'chip ' + src.tone}>{src.label}</span>}
                    {conf != null && Number(conf) < 0.8 && <span className="chip t-amber" title="The AI was not sure. Check it against the statements.">check · {Math.round(Number(conf) * 100)}%</span>}
                  </span>
                  <span className="right num">{amt(l.amount)}</span>
                </div>
              );
            })}
          </div>
        );
      })}
      {edit && <LineModal d={d} year={year} line={edit} onClose={() => setEdit(null)} />}
    </div>
  );
}

function LineModal({ d, year, line, onClose }: { d: any; year: number; line: any; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const imported = d.row?.source === 'imported';
  const [amount, setAmount] = useState(String(line.override?.amount ?? line.imported?.amount ?? line.amount ?? ''));
  const [reason, setReason] = useState(line.override?.reason || line.imported?.note || '');
  const [busy, setBusy] = useState(false);
  const detail = line.detail && typeof line.detail === 'object' ? Object.entries(line.detail as Record<string, number>).filter(([, v]) => Number(v) !== 0) : [];
  async function save(p: any, ok: string) {
    setBusy(true);
    try { await rpc('save_cit_year', { p_org: orgId, p_year: year, p }); toast(ok); await refresh(); onClose(); } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  const n = money(amount);
  return (
    <Modal onClose={onClose} width={520}>
      <ModalHead title={line.label} sub={`${line.cell.replace('!', ' · ')}${line.note ? ' · ' + line.note : ''}`} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 12 }}>
        {detail.length > 0 && (
          <div className="stack" style={{ gap: 4, fontSize: 13 }}>
            <div className="label">From the books</div>
            {detail.map(([k, v]) => <div key={k} className="row" style={{ justifyContent: 'space-between' }}><span className="muted">{k}</span><span className="num">{amt(v)}</span></div>)}
          </div>
        )}
        {line.imported?.source && line.imported.source !== 'manual' && (
          <div className="faint" style={{ fontSize: 12 }}>Read from the {line.imported.source === 'afs' ? 'audited accounts' : 'trial balance'}{line.imported.note ? `: ${line.imported.note}` : ''}
            {line.imported.confidence != null ? ` · ${Math.round(Number(line.imported.confidence) * 100)}% sure` : ''}</div>
        )}
        {line.positive_only && <div className="faint" style={{ fontSize: 12 }}>The template takes only amounts above zero on this line.</div>}
        <Field label={imported ? 'Amount' : 'Amount to file instead of the books'}><input className="input num" inputMode="decimal" autoFocus value={amount} onChange={(e) => setAmount(e.target.value)} /></Field>
        <Field label={imported ? 'Where it comes from (optional)' : 'Why it differs from the books'}><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      </div>
      <div className="modal-ft">
        {imported ? (line.imported && <button className="btn btn-ghost" disabled={busy} onClick={() => save({ imported: { [line.cell]: null } }, 'Line cleared')}>Clear</button>)
          : (line.override && <button className="btn btn-ghost" disabled={busy} onClick={() => save({ overrides: { [line.cell]: null } }, 'Back to the books')}>Use the books</button>)}
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy || n == null || (!imported && reason.trim().length < 3)}
          onClick={() => save(imported ? { imported: { [line.cell]: { amount: n, note: reason.trim() || undefined } } } : { overrides: { [line.cell]: { amount: n, reason } } }, 'Saved')}>Save</button>
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------- profit adjustments
function Adjustments({ d, year }: { d: any; year: number }) {
  const [edit, setEdit] = useState<any>(null);
  const lines: any[] = (d.lines || []).filter((l: any) => l.sheet === 'PROFIT_ADJUSTMENT');
  const fig = d.computation?.figures || {};
  const group = (id: string, title: string, total: number) => (
    <div className="card" style={{ overflow: 'hidden' }}>
      <div className="tr head shade" style={{ gridTemplateColumns: 'minmax(0,1fr) 150px' }}><b>{title}</b><b className="right num">{N2(total)}</b></div>
      {lines.filter((l) => l.section === id).map((l) => {
        const items: any[] = l.items || [];
        const fixed = l.cell === 'PROFIT_ADJUSTMENT!D23';
        return (
          <div key={l.cell} className={'tr' + (d.can_edit && !fixed ? ' click' : '')} onClick={() => d.can_edit && !fixed && setEdit(l)} style={{ gridTemplateColumns: 'minmax(0,1fr) 150px', alignItems: 'start' }}>
            <span style={{ minWidth: 0 }}>{l.label}
              {fixed && <span className="faint" style={{ display: 'block', fontSize: 11 }}>The computation starts from profit before tax, so the tax charge is never added back.</span>}
              {items.map((it, i) => (
                <span key={i} className="faint" style={{ display: 'block', fontSize: 12 }}>{it.auto ? '' : '• '}{it.label}: {N2(it.amount)}{it.basis ? ` · ${it.basis}` : ''}</span>
              ))}
            </span>
            <span className="right num" style={{ color: Number(l.amount) ? undefined : '#9CA3AF' }}>{N2(l.amount)}</span>
          </div>
        );
      })}
    </div>
  );
  return (
    <div className="stack" style={{ gap: 12 }}>
      <div className="faint" style={{ fontSize: 13 }}>Depreciation, donations above the limit and the like come from the books by the rule book; add anything else with its reason. Each reason prints on the computation.</div>
      {group('add_back', 'Add back: disallowable expenses', Number(fig.addbacks || 0))}
      {group('deduction', 'Deduct: income not taxed and tax-only deductions', Number(fig.deductions || 0))}
      {edit && <AdjModal d={d} year={year} line={edit} onClose={() => setEdit(null)} />}
    </div>
  );
}

interface Item { label: string; amount: string; reason: string }
function AdjModal({ d, year, line, onClose }: { d: any; year: number; line: any; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const saved = d.row?.adjustments?.[line.cell] || {};
  const [items, setItems] = useState<Item[]>((saved.items || []).map((x: any) => ({ label: x.label, amount: String(x.amount), reason: x.reason })));
  const [ovr, setOvr] = useState<{ on: boolean; amount: string; reason: string; label: string }>({ on: !!saved.override, amount: saved.override ? String(saved.override.amount) : '',
    reason: saved.override?.reason || '', label: saved.override?.label || '' });
  const [busy, setBusy] = useState(false);
  const autos: any[] = (line.items || []).filter((x: any) => x.auto);
  async function save(clear = false) {
    setBusy(true);
    try {
      const value = clear ? null : { items: items.filter((x) => x.label.trim() || x.amount.trim()).map((x) => ({ label: x.label, amount: money(x.amount), reason: x.reason })),
        ...(ovr.on ? { override: { amount: money(ovr.amount), reason: ovr.reason, label: ovr.label || null } } : {}) };
      await rpc('save_cit_year', { p_org: orgId, p_year: year, p: { adjustments: { [line.cell]: value } } });
      toast('Adjustment saved'); await refresh(); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={600}>
      <ModalHead title={line.label} sub={line.section === 'add_back' ? 'Added back to profit' : 'Deducted from profit'} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 12 }}>
        {autos.length > 0 && !ovr.on && (
          <div className="stack" style={{ gap: 4, fontSize: 13 }}>
            <div className="label">Worked out by Counta</div>
            {autos.map((a, i) => <div key={i} className="row" style={{ justifyContent: 'space-between' }}><span className="muted">{a.label}{a.basis ? ` · ${a.basis}` : ''}</span><span className="num">{N2(a.amount)}</span></div>)}
          </div>
        )}
        {!ovr.on && (
          <div className="stack" style={{ gap: 8 }}>
            <div className="row" style={{ justifyContent: 'space-between' }}><div className="label">Your items</div>
              <button className="btn btn-secondary btn-xs" onClick={() => setItems([...items, { label: '', amount: '', reason: '' }])}><Icon name="plus" size={12} />Item</button></div>
            {!items.length && <div className="faint" style={{ fontSize: 13 }}>None. Add what the books cannot show, with the reason.</div>}
            {items.map((x, i) => (
              <div key={i} className="card" style={{ padding: 10, borderRadius: 10, display: 'grid', gridTemplateColumns: 'minmax(0,1.4fr) 130px 32px', gap: 8 }}>
                <input className="input input-sm" placeholder="What it is" value={x.label} onChange={(e) => setItems(items.map((y, j) => (j === i ? { ...y, label: e.target.value } : y)))} />
                <input className="input input-sm num" inputMode="decimal" placeholder="Amount" value={x.amount} onChange={(e) => setItems(items.map((y, j) => (j === i ? { ...y, amount: e.target.value } : y)))} />
                <button className="x-btn" aria-label="Remove" onClick={() => setItems(items.filter((_, j) => j !== i))}><Icon name="x" size={14} /></button>
                <input className="input input-sm" style={{ gridColumn: '1 / -1' }} placeholder="Reason (prints on the computation)" value={x.reason} onChange={(e) => setItems(items.map((y, j) => (j === i ? { ...y, reason: e.target.value } : y)))} />
              </div>
            ))}
          </div>
        )}
        <label className="check"><input type="checkbox" checked={ovr.on} onChange={(e) => setOvr({ ...ovr, on: e.target.checked })} />Replace the whole row with one amount</label>
        {ovr.on && (
          <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
            <Field label="Amount"><input className="input num" inputMode="decimal" value={ovr.amount} onChange={(e) => setOvr({ ...ovr, amount: e.target.value })} /></Field>
            <Field label="Description (optional)"><input className="input" value={ovr.label} onChange={(e) => setOvr({ ...ovr, label: e.target.value })} /></Field>
            <Field label="Reason" style={{ gridColumn: '1 / -1' }}><input className="input" value={ovr.reason} onChange={(e) => setOvr({ ...ovr, reason: e.target.value })} /></Field>
          </div>
        )}
      </div>
      <div className="modal-ft">
        {(saved.items?.length || saved.override) && <button className="btn btn-ghost" disabled={busy} onClick={() => save(true)}>Remove yours</button>}
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy} onClick={() => save()}>Save</button>
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------- capital allowances
function Allowances({ d, year }: { d: any; year: number }) {
  const ca = d.computation?.ca || {};
  const fig = d.computation?.figures || {};
  const [asset, setAsset] = useState<any>(null);
  const [taxAsset, setTaxAsset] = useState<any>(null);
  const legacy = d.computation?.regime === 'LEGACY_CITA';
  const cats: any[] = ca.categories || [];
  const assets: any[] = ca.assets || [];
  return (
    <div className="stack" style={{ gap: 12 }}>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(150px,1fr))', gap: 8 }}>
        <Stat label="Allowances for the year" value={N2(ca.totals?.allowance)} sub={Number(ca.totals?.investment) ? `+ ${N2(ca.totals.investment)} investment allowance` : undefined} />
        <Stat label="Available, with brought forward" value={N2(fig.capital_allowances_available)} />
        <Stat label="Used this year" value={N2(fig.capital_allowances)} sub={legacy && fig.restricted ? 'limited to two-thirds of assessable profit' : undefined} />
        <Stat label="Carried forward" value={N2(d.computation?.cf?.ca)} />
      </div>
      {(ca.missing || []).length > 0 && <Alert kind="amber" icon="alert">No Rev360 category yet for {(ca.missing as string[]).join(', ')}. Choose one below so they get their allowance.</Alert>}
      {cats.length > 0 && (
        <div className="card" style={{ overflow: 'auto' }}>
          <div className="tr head shade th" style={{ gridTemplateColumns: 'minmax(180px,1.5fr) repeat(5,110px)', minWidth: 760 }}>
            <span>Category</span><span className="right">Tax value b/f</span><span className="right">Additions</span><span className="right">Allowance</span><span className="right">Balancing</span><span className="right">Tax value c/f</span>
          </div>
          {cats.map((c) => (
            <div key={c.category} className="tr" style={{ gridTemplateColumns: 'minmax(180px,1.5fr) repeat(5,110px)', minWidth: 760, fontSize: 13 }}>
              <span>{c.category}<span className="faint"> · {c.assets}</span></span><span className="right num">{N2(c.twdv_bf)}</span><span className="right num">{N2(c.additions)}</span>
              <span className="right num">{N2(Number(c.allowance) + Number(c.investment || 0))}</span>
              <span className="right num">{Number(c.balancing_charge) ? `+${N2(c.balancing_charge)}` : Number(c.balancing_allowance) ? `-${N2(c.balancing_allowance)}` : '—'}</span>
              <span className="right num">{N2(c.twdv_cf)}</span>
            </div>
          ))}
        </div>
      )}
      <div className="card" style={{ overflow: 'auto' }}>
        <div className="card-hd row" style={{ justifyContent: 'space-between' }}><b>Asset by asset</b>
          {d.can_edit && <button className="btn btn-secondary btn-sm" onClick={() => setTaxAsset({})}><Icon name="plus" size={13} />Asset kept for tax only</button>}</div>
        {!assets.length ? <div style={{ padding: 16 }}><Empty>No assets in the register or kept for tax.</Empty></div> : assets.map((a) => (
          <div key={a.key} className={'tr' + (d.can_edit ? ' click' : '')} onClick={() => d.can_edit && (a.kind === 'register' ? setAsset(a) : setTaxAsset((d.tax_assets || []).find((t: any) => t.id === a.asset_id) || { id: a.asset_id }))}
            style={{ gridTemplateColumns: 'minmax(200px,1.6fr) minmax(150px,1fr) 110px 110px 110px', minWidth: 720, fontSize: 13, alignItems: 'start' }}>
            <span style={{ minWidth: 0 }}><b>{a.number ? `${a.number} ` : ''}{a.name}</b>
              <span className="faint" style={{ display: 'block', fontSize: 11 }}>{a.kind === 'register' ? 'Fixed asset register' : 'Kept for tax only'} · in use {fmtDay(a.in_use)}{a.disposed ? ' · disposed this year' : ''}{a.use_pct != null && Number(a.use_pct) < 100 ? ` · ${a.use_pct}% business use` : ''}</span>
              {!a.qualifies && a.reason && <span style={{ display: 'block', fontSize: 11, color: '#B45309' }}>{a.reason}</span>}</span>
            <span className="muted" style={{ minWidth: 0 }}>{a.category || <span style={{ color: '#B45309' }}>Choose a category</span>}</span>
            <span className="right num">{N2(a.qce)}</span>
            <span className="right num">{N2(Number(a.allowance || 0) + Number(a.investment || 0))}</span>
            <span className="right num">{N2(a.twdv_cf)}</span>
          </div>
        ))}
      </div>
      <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>
        Columns: cost, allowance for {year}, tax value carried forward. {legacy ? 'Initial and annual allowances at the Second Schedule rates of the Companies Income Tax Act, with ₦10 kept on each asset until it is sold.'
          : 'Annual allowances on cost at the Nigeria Tax Act rates, with 1% of cost kept until the asset is sold.'}
      </div>
      {asset && <AssetTaxModal d={d} year={year} a={asset} onClose={() => setAsset(null)} />}
      {taxAsset && <TaxAssetModal t={taxAsset} onClose={() => setTaxAsset(null)} />}
    </div>
  );
}

function AssetTaxModal({ d, year, a, onClose }: { d: any; year: number; a: any; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const firstYear = !d.computation?.bf?.from_previous_year;
  const open = d.row?.settings?.opening_twdv || {};
  const [f, setF] = useState({ tax_category: a.category || '', tax_use_pct: String(a.use_pct ?? 100), tax_qualifies: !(a.qualifies === false && a.reason === 'Marked as not qualifying'), opening: open[a.key] != null ? String(open[a.key]) : '' });
  const [busy, setBusy] = useState(false);
  async function save() {
    setBusy(true);
    try {
      await rpc('set_asset_tax', { p_asset: a.asset_id, p: { tax_category: f.tax_category || null, tax_use_pct: money(f.tax_use_pct) ?? 100, tax_qualifies: f.tax_qualifies } });
      if (firstYear && d.can_edit) {
        const next = { ...open };
        if (f.opening.trim() === '') delete next[a.key]; else next[a.key] = money(f.opening);
        if (JSON.stringify(next) !== JSON.stringify(open)) await rpc('save_cit_year', { p_org: orgId, p_year: year, p: { settings: { opening_twdv: next } } });
      }
      toast('Saved'); await refresh(); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={500}>
      <ModalHead title={`${a.number || ''} ${a.name}`.trim()} sub="How tax treats this asset" onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 12 }}>
        <Field label="Rev360 category"><select className="input" value={f.tax_category} onChange={(e) => setF({ ...f, tax_category: e.target.value })}>
          <option value="">Choose</option>{CA_CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}</select></Field>
        <Field label="Share used for the business (%)"><input className="input num" inputMode="decimal" value={f.tax_use_pct} onChange={(e) => setF({ ...f, tax_use_pct: e.target.value })} /></Field>
        <label className="check"><input type="checkbox" checked={f.tax_qualifies} onChange={(e) => setF({ ...f, tax_qualifies: e.target.checked })} />Qualifies for capital allowances</label>
        {firstYear && <Field label={`Tax value at the start of ${year} (optional)`} hint="From the last return filed before Counta. Left empty, Counta works it out from the cost and the years in use.">
          <input className="input num" inputMode="decimal" value={f.opening} onChange={(e) => setF({ ...f, opening: e.target.value })} /></Field>}
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy} onClick={save}>Save</button></div>
    </Modal>
  );
}

function TaxAssetModal({ t, onClose }: { t: any; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const s = (v: unknown) => (v == null ? '' : String(v));
  const [f, setF] = useState({ name: s(t.name), tax_category: s(t.tax_category), in_use_from: s(t.in_use_from), cost: s(t.cost), accumulated_depreciation: s(t.accumulated_depreciation),
    depreciation_as_at: s(t.depreciation_as_at), disposed_at: s(t.disposed_at), proceeds: s(t.proceeds), tax_use_pct: s(t.tax_use_pct ?? 100), tax_qualifies: t.tax_qualifies !== false, note: s(t.note) });
  const [busy, setBusy] = useState(false);
  const set = (k: string, v: any) => setF((x) => ({ ...x, [k]: v }));
  async function save(del = false) {
    setBusy(true);
    try {
      await rpc('save_tax_asset', { p_org: orgId, p: del ? { id: t.id, delete: true } : { id: t.id || null, ...f, cost: money(f.cost), accumulated_depreciation: money(f.accumulated_depreciation) ?? 0,
        proceeds: money(f.proceeds), tax_use_pct: money(f.tax_use_pct) ?? 100 } });
      toast(del ? 'Removed' : 'Saved'); await refresh(); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={560}>
      <ModalHead title={t.id ? f.name || 'Asset' : 'An asset kept for tax only'} sub="Bought before Counta's books, or on an earlier capital allowance schedule" onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 10 }}>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          <Field label="Name" req style={{ gridColumn: '1 / -1' }}><input className="input" value={f.name} onChange={(e) => set('name', e.target.value)} /></Field>
          <Field label="Rev360 category" req><select className="input" value={f.tax_category} onChange={(e) => set('tax_category', e.target.value)}><option value="">Choose</option>{CA_CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}</select></Field>
          <Field label="First used" req><input className="input" type="date" value={f.in_use_from} onChange={(e) => set('in_use_from', e.target.value)} /></Field>
          <Field label="Cost" req><input className="input num" inputMode="decimal" value={f.cost} onChange={(e) => set('cost', e.target.value)} /></Field>
          <Field label="Share used for the business (%)"><input className="input num" inputMode="decimal" value={f.tax_use_pct} onChange={(e) => set('tax_use_pct', e.target.value)} /></Field>
          <Field label="Accumulated depreciation"><input className="input num" inputMode="decimal" value={f.accumulated_depreciation} onChange={(e) => set('accumulated_depreciation', e.target.value)} /></Field>
          <Field label="As at"><input className="input" type="date" value={f.depreciation_as_at} onChange={(e) => set('depreciation_as_at', e.target.value)} /></Field>
          <Field label="Sold or scrapped on"><input className="input" type="date" value={f.disposed_at} onChange={(e) => set('disposed_at', e.target.value)} /></Field>
          <Field label="For"><input className="input num" inputMode="decimal" value={f.proceeds} onChange={(e) => set('proceeds', e.target.value)} /></Field>
        </div>
        <label className="check"><input type="checkbox" checked={f.tax_qualifies} onChange={(e) => set('tax_qualifies', e.target.checked)} />Qualifies for capital allowances</label>
        <Field label="Note"><input className="input" value={f.note} onChange={(e) => set('note', e.target.value)} /></Field>
      </div>
      <div className="modal-ft">
        {t.id && <button className="btn btn-ghost" disabled={busy} onClick={() => save(true)}><Icon name="trash" size={13} />Remove</button>}
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy || !f.name.trim() || !f.tax_category || !f.in_use_from || money(f.cost) == null} onClick={() => save()}>Save</button>
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------- amounts brought forward and the year's settings
function BroughtForward({ d, year }: { d: any; year: number }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const comp = d.computation || {};
  const st = d.row?.settings || {};
  const legacy = comp.regime === 'LEGACY_CITA';
  const fromPrev = !!comp.bf?.from_previous_year;
  const s = (v: unknown) => (v == null || Number(v) === 0 ? '' : String(v));
  const [f, setF] = useState({ override: !!st.bf_override, bf_reason: st.bf_reason || '', losses_bf: s(st.losses_bf), ca_bf: s(st.ca_bf),
    interest_bf: ((st.interest_bf || []) as any[]).map((x) => ({ yoa: String(x.yoa), amount: String(x.amount) })), connected_interest: s(st.connected_interest),
    donations_unlisted: s(st.donations_unlisted), chargeable_gains_other: s(st.chargeable_gains_other), notes: st.notes || '' });
  const [busy, setBusy] = useState(false);
  const set = (k: string, v: any) => setF((x) => ({ ...x, [k]: v }));
  const typed = !fromPrev || f.override;
  async function save() {
    setBusy(true);
    try {
      const n = (v: string) => (v.trim() === '' ? null : money(v));
      const settings: any = { connected_interest: n(f.connected_interest), donations_unlisted: n(f.donations_unlisted), chargeable_gains_other: n(f.chargeable_gains_other), notes: f.notes.trim() || null };
      if (typed) Object.assign(settings, { losses_bf: n(f.losses_bf), ca_bf: n(f.ca_bf), interest_bf: f.interest_bf.filter((x) => money(x.amount)).map((x) => ({ yoa: Number(x.yoa), amount: money(x.amount) })) });
      if (fromPrev) Object.assign(settings, f.override ? { bf_override: true, bf_reason: f.bf_reason } : { bf_override: null, bf_reason: null });
      await rpc('save_cit_year', { p_org: orgId, p_year: year, p: { settings } });
      toast('Saved and worked out again'); await refresh();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  const ro = !d.can_edit;
  return (
    <div className="card card-pad stack" style={{ gap: 14 }}>
      {fromPrev ? (
        <div className="stack" style={{ gap: 6 }}>
          <b>Brought forward from the {year - 1} computation</b>
          <div className="row wrap" style={{ gap: 16, fontSize: 13 }}>
            <span>Losses <b className="num">{N2(comp.bf?.losses)}</b></span><span>Capital allowances <b className="num">{N2(comp.bf?.ca)}</b></span>
            {!legacy && <span>Disallowed interest <b className="num">{N2((comp.bf?.interest || []).reduce((a: number, x: any) => a + Number(x.amount || 0), 0))}</b></span>}
          </div>
          {!ro && <label className="check" style={{ fontSize: 13 }}><input type="checkbox" checked={f.override} onChange={(e) => set('override', e.target.checked)} />Use different amounts (for example, as agreed with the NRS)</label>}
          {f.override && <Field label="Why they differ"><input className="input" disabled={ro} value={f.bf_reason} onChange={(e) => set('bf_reason', e.target.value)} /></Field>}
        </div>
      ) : <div className="muted" style={{ fontSize: 13 }}>{year} is the first year Counta prepares. Enter what the last return filed carried forward.</div>}
      {typed && (
        <div className="stack" style={{ gap: 10 }}>
          <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
            <Field label="Tax losses brought forward"><input className="input num" disabled={ro} inputMode="decimal" value={f.losses_bf} onChange={(e) => set('losses_bf', e.target.value)} /></Field>
            <Field label="Unused capital allowances brought forward"><input className="input num" disabled={ro} inputMode="decimal" value={f.ca_bf} onChange={(e) => set('ca_bf', e.target.value)} /></Field>
          </div>
          {!legacy && (
            <div className="stack" style={{ gap: 6 }}>
              <div className="row" style={{ justifyContent: 'space-between' }}><span className="label">Disallowed interest brought forward, by year of assessment</span>
                {!ro && <button className="btn btn-secondary btn-xs" onClick={() => set('interest_bf', [...f.interest_bf, { yoa: String(year), amount: '' }])}><Icon name="plus" size={12} />Year</button>}</div>
              {f.interest_bf.map((x, i) => (
                <div key={i} className="row" style={{ gap: 8 }}>
                  <input className="input input-sm" style={{ width: 90 }} inputMode="numeric" value={x.yoa} disabled={ro} onChange={(e) => set('interest_bf', f.interest_bf.map((y, j) => (j === i ? { ...y, yoa: e.target.value } : y)))} />
                  <input className="input input-sm num" style={{ width: 160 }} inputMode="decimal" placeholder="Amount" value={x.amount} disabled={ro} onChange={(e) => set('interest_bf', f.interest_bf.map((y, j) => (j === i ? { ...y, amount: e.target.value } : y)))} />
                  {!ro && <button className="x-btn" aria-label="Remove" onClick={() => set('interest_bf', f.interest_bf.filter((_, j) => j !== i))}><Icon name="x" size={14} /></button>}
                </div>
              ))}
            </div>
          )}
        </div>
      )}
      <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
        {!legacy && <Field label="Interest paid to connected persons" hint="Deductible up to 30% of EBITDA; the rest carries forward up to five years.">
          <input className="input num" disabled={ro} inputMode="decimal" value={f.connected_interest} onChange={(e) => set('connected_interest', e.target.value)} /></Field>}
        <Field label="Donations to bodies not on the approved list" hint="Not deductible; the rest is allowed up to the limit.">
          <input className="input num" disabled={ro} inputMode="decimal" value={f.donations_unlisted} onChange={(e) => set('donations_unlisted', e.target.value)} /></Field>
        {!legacy && <Field label="Other chargeable gains" hint="Gains on disposals outside the fixed asset register.">
          <input className="input num" disabled={ro} inputMode="decimal" value={f.chargeable_gains_other} onChange={(e) => set('chargeable_gains_other', e.target.value)} /></Field>}
      </div>
      <Field label="Notes for whoever prepares the return"><textarea className="input" disabled={ro} style={{ minHeight: 60 }} value={f.notes} onChange={(e) => set('notes', e.target.value)} /></Field>
      {st.reopened && <div className="faint" style={{ fontSize: 12 }}>Reopened by {st.reopened.by} ({when(st.reopened.at)}): {st.reopened.reason}</div>}
      {!ro && <div><button className="btn btn-primary" disabled={busy || (f.override && f.bf_reason.trim().length < 3)} onClick={save}>{busy ? 'Saving…' : 'Save and work it out again'}</button></div>}
    </div>
  );
}

// ---------------------------------------------------------------- audited accounts: attached, read by AI, or a trial balance
function Statements({ d, year }: { d: any; year: number }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const file = useRef<HTMLInputElement>(null);
  const row = d.row || {};
  const [busy, setBusy] = useState<string | null>(null);
  const [result, setResult] = useState<any>(null);
  const afsName = row.afs_path ? String(row.afs_path).split('/').pop()!.replace(/^\d+-/, '') : null;
  const imp = row.imported_from;
  async function upload(f: File) {
    if (!/\.pdf$/i.test(f.name) && f.type !== 'application/pdf') { toast('Attach the statements as a PDF.', 'err'); return; }
    if (f.size > 25_000_000) { toast('The file is larger than 25 MB.', 'err'); return; }
    setBusy('upload');
    try {
      const path = `${orgId}/tax/cit/${year}/afs/${Date.now()}-${f.name.replace(/[^\w.-]+/g, '_').slice(-80)}`;
      const { error } = await supabase.storage.from('documents').upload(path, f, { contentType: 'application/pdf', upsert: false });
      if (error) throw new Error(error.message.includes('row-level') ? 'Your role cannot attach tax documents.' : error.message);
      await rpc('save_cit_year', { p_org: orgId, p_year: year, p: { afs_path: path } });
      toast('Audited accounts attached'); await refresh();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }
  async function read(body: Record<string, unknown>) {
    setBusy('read'); setResult(null);
    try {
      const r = await ai<any>('cit_map', { org_id: orgId, year, ...body });
      if (r.ok === false) throw new Error(r.reason === 'not_configured' ? 'The AI reader is not set up yet.' : r.error || 'Could not read it.');
      setResult(r); toast(`${r.placed} figures placed on the template`); await refresh();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }
  async function setSource(source: 'books' | 'imported') {
    setBusy('source');
    try { await rpc('save_cit_year', { p_org: orgId, p_year: year, p: { source } }); toast(source === 'books' ? 'Figures from the books' : 'Figures from the audited accounts'); await refresh(); }
    catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }
  return (
    <div className="stack" style={{ gap: 12 }}>
      <div className="card card-pad stack" style={{ gap: 10 }}>
        <b>Audited financial statements</b>
        <div className="muted" style={{ fontSize: 13 }}>Rev360 needs them with the return: the auditor's report, the statements and notes, and the capital allowance schedule, as one PDF.</div>
        {row.afs_path ? (
          <div className="row wrap" style={{ gap: 8 }}>
            <span className="row" style={{ gap: 6, fontSize: 14 }}><Icon name="file" size={15} />{afsName}</span>
            <button className="btn btn-ghost btn-xs" onClick={() => openInTab(() => signedDoc(row.afs_path))}><Icon name="eye" size={13} />Open</button>
            {d.can_edit && <button className="btn btn-ghost btn-xs" disabled={!!busy} onClick={() => file.current?.click()}>Replace</button>}
            {d.can_edit && <button className="btn btn-ghost btn-xs" disabled={!!busy} onClick={async () => { setBusy('rm'); try { await rpc('save_cit_year', { p_org: orgId, p_year: year, p: { afs_path: null } }); await refresh(); } catch (e) { toast((e as Error).message, 'err'); } setBusy(null); }}>Remove</button>}
          </div>
        ) : d.can_edit ? <div><button className="btn btn-secondary btn-sm" disabled={!!busy} onClick={() => file.current?.click()}>{busy === 'upload' ? <Spinner small /> : <Icon name="paperclip" size={14} />}Attach the PDF</button></div>
          : <div className="faint" style={{ fontSize: 13 }}>Not attached yet.</div>}
        <input ref={file} type="file" accept="application/pdf,.pdf" hidden onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) upload(f); }} />
      </div>

      <div className="card card-pad stack" style={{ gap: 10 }}>
        <div className="row wrap" style={{ justifyContent: 'space-between' }}>
          <b>Where the figures come from</b>
          {d.can_edit && <div className="seg" role="tablist">
            <button className={row.source === 'books' ? 'on' : ''} disabled={!!busy} onClick={() => row.source !== 'books' && setSource('books')}>Counta's books</button>
            <button className={row.source === 'imported' ? 'on' : ''} disabled={!!busy} onClick={() => row.source !== 'imported' && setSource('imported')}>Audited accounts</button>
          </div>}
        </div>
        <div className="muted" style={{ fontSize: 13 }}>
          {row.source === 'books' ? `The template is filled from the ledger for ${year}. Use the audited accounts instead for a year the books do not fully cover, or when the auditors' adjustments are not posted.`
            : 'The template is filled from the audited accounts or a trial balance, read in below or entered under Figures. Check every line marked "check" against the statements.'}
        </div>
        {imp && <div className="faint" style={{ fontSize: 12 }}>Last read: {imp.lines} line{imp.lines === 1 ? '' : 's'} from the {imp.kind === 'trial_balance' ? 'trial balance' : 'audited accounts'} by {imp.by} ({when(imp.at)})
          {imp.profit_before_tax != null ? ` · their profit before tax ${N2(imp.profit_before_tax)}` : ''}{imp.revenue != null ? ` · revenue ${N2(imp.revenue)}` : ''}{imp.total_assets != null ? ` · total assets ${N2(imp.total_assets)}` : ''}</div>}
      </div>

      {d.can_edit && (
        <div className="card card-pad stack" style={{ gap: 12 }}>
          <b>Read the figures with AI</b>
          <div className="muted" style={{ fontSize: 13 }}>The AI places each figure on the most specific line of the Rev360 template, for {year} only. It replaces the figures read before; you check them under Figures before approving.</div>
          <div className="row wrap">
            <button className="btn btn-primary btn-sm" disabled={!!busy || !row.afs_path} onClick={() => read({ kind: 'afs', file_path: row.afs_path })}>
              {busy === 'read' ? <Spinner small /> : <Icon name="sparkles" size={14} color="#fff" />}Read the attached statements</button>
            {!row.afs_path && <span className="faint" style={{ fontSize: 12 }}>Attach the PDF first.</span>}
          </div>
          <div className="label" style={{ marginTop: 4 }}>Or a trial balance at the year end (Excel or CSV)</div>
          <SheetRows fields={TB_FIELDS} need={[['debit', 'credit'], ['balance']]} action={(n) => `Read ${n} accounts with AI`}
            onRows={async (rows) => { await read({ kind: 'trial_balance', rows: tbRows(rows) }); }} />
          {busy === 'read' && <div className="row" style={{ gap: 8 }}><Spinner small /><span className="muted" style={{ fontSize: 13 }}>Reading. Statements with many notes take up to two minutes.</span></div>}
          {result && (
            <Alert kind={(result.checks || []).length ? 'amber' : 'green'} icon={(result.checks || []).length ? 'alert' : 'check'}>
              {result.placed} figures placed{result.low_confidence ? `, ${result.low_confidence} to check` : ''}{(result.dropped || []).length ? `, ${result.dropped.length} not on an input line` : ''}.
              {(result.checks || []).map((c: any) => ' ' + c.text).join('')}{(result.warnings || []).length ? ` Notes: ${(result.warnings as string[]).join(' ')}` : ''}
            </Alert>
          )}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- the company's tax profile
function ProfileDrawer({ onClose }: { onClose: () => void }) {
  const { orgId } = useSession();
  const { data: inv } = useInventory();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const p = useTaxProfile();
  const d = p.data;
  const [f, setF] = useState<any>(null);
  useEffect(() => {
    if (!d || f) return;
    const cp = d.cit_profile || {};
    setF({ professional_services: !!d.professional_services, commenced_on: d.commenced_on || '', wvat_agent: d.wvat_agent || '', wht_small_company: !!d.wht_small_company,
      non_resident: !!cp.non_resident, mne_constituent: !!cp.mne_constituent, group_turnover_eur: cp.group_turnover_eur ? String(cp.group_turnover_eur) : '',
      bank_or_insurer_subsidiary: !!cp.bank_or_insurer_subsidiary, imported_equity_25: !!cp.imported_equity_25, agricultural_trade: !!cp.agricultural_trade,
      hydrocarbon: !!cp.hydrocarbon, sector_regime: cp.sector_regime || '' });
  }, [d]); // eslint-disable-line react-hooks/exhaustive-deps
  const [busy, setBusy] = useState(false);
  const set = (k: string, v: any) => setF((x: any) => ({ ...x, [k]: v }));
  const ro = !d?.can_edit;
  async function save() {
    setBusy(true);
    try {
      const flag = (v: boolean) => (v ? true : null);
      await rpc('save_tax_profile', { p_org: orgId, p: { professional_services: f.professional_services, commenced_on: f.commenced_on || null, wvat_agent: f.wvat_agent || '',
        wht_small_company: f.wht_small_company, cit_profile: { non_resident: flag(f.non_resident), mne_constituent: flag(f.mne_constituent),
          group_turnover_eur: f.mne_constituent && money(f.group_turnover_eur) ? money(f.group_turnover_eur) : null, bank_or_insurer_subsidiary: flag(f.bank_or_insurer_subsidiary),
          imported_equity_25: flag(f.imported_equity_25), agricultural_trade: flag(f.agricultural_trade), hydrocarbon: flag(f.hydrocarbon), sector_regime: f.sector_regime || null } } });
      toast('Tax profile saved'); await refresh(); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  const box = (k: string, label: ReactNode) => <label className="check"><input type="checkbox" disabled={ro} checked={!!f?.[k]} onChange={(e) => set(k, e.target.checked)} />{label}</label>;
  return (
    <Drawer onClose={onClose} width={620}>
      <div className="drawer-hd"><div className="grow"><div className="drawer-title">The company's tax profile</div><div className="muted" style={{ fontSize: 13 }}>What the tax engines need to know about {inv?.org.name || 'the business'}.</div></div>
        <button className="x-btn" onClick={onClose} aria-label="Close"><Icon name="x" size={18} /></button></div>
      <div className="drawer-body stack" style={{ gap: 14 }}>
        {!d || !f ? <Spinner /> : (
          <>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(160px,1fr))', gap: 8 }}>
              <Stat label="Tax ID" value={d.tin || 'Not set'} /><Stat label="RC number" value={d.rc_number || 'Not set'} />
              <Stat label="State" value={d.state || 'Not known'} sub={d.state ? undefined : 'Add the address in Settings'} />
              <Stat label="Financial year" value={`Starts in ${new Date(2026, Number(d.fiscal_year_start || 1) - 1, 1).toLocaleDateString('en-GB', { month: 'long' })}`} />
            </div>
            <div className="faint" style={{ fontSize: 12 }}>The Tax ID, RC number, address and financial year are changed in Settings.</div>
            <div className="label">Companies income tax</div>
            {box('professional_services', 'Provides professional services (law, accounting, consulting and the like): never a small company')}
            <Field label="Started business on" hint="The first years of a new company have special rules (minimum tax, basis periods)."><input className="input" type="date" disabled={ro} value={f.commenced_on} onChange={(e) => set('commenced_on', e.target.value)} style={{ maxWidth: 200 }} /></Field>
            {box('mne_constituent', 'Part of a multinational group with revenue of €750 million or more (15% minimum effective tax)')}
            {f.mne_constituent && <Field label="Group revenue (euros)"><input className="input num" inputMode="decimal" disabled={ro} value={f.group_turnover_eur} onChange={(e) => set('group_turnover_eur', e.target.value)} style={{ maxWidth: 240 }} /></Field>}
            {box('bank_or_insurer_subsidiary', 'A bank, an insurer, or a subsidiary of one (the interest limit does not apply)')}
            {box('agricultural_trade', 'In agricultural trade (no minimum tax, for years under the old law)')}
            {box('imported_equity_25', 'At least 25% of the share capital was brought in as foreign equity (no minimum tax, old law)')}
            {box('non_resident', 'A non-resident company')}
            {box('hydrocarbon', 'In upstream petroleum (hydrocarbon tax)')}
            <Field label="Taxed under special rules" hint="Counta does not compute these returns yet; the year will say so.">
              <select className="input" disabled={ro} value={f.sector_regime} onChange={(e) => set('sector_regime', e.target.value)} style={{ maxWidth: 320 }}>
                <option value="">No</option><option value="free_zone">Free trade zone enterprise</option><option value="upstream_petroleum">Upstream petroleum</option>
                <option value="insurance">Insurance (special rules)</option><option value="shipping_airline">Shipping or airline</option><option value="other">Other special regime</option>
              </select></Field>
            <div className="label">Withholding</div>
            <Field label="Withholding VAT agent" hint="An agent keeps the VAT on its suppliers' invoices and pays it to the NRS by the 14th.">
              <select className="input" disabled={ro} value={f.wvat_agent} onChange={(e) => set('wvat_agent', e.target.value)}>
                <option value="">Not an agent</option>{WVAT_AGENTS.map((w) => <option key={w.id} value={w.id}>{w.label}</option>)}</select></Field>
            {box('wht_small_company', 'A small company: no WHT on a supplier with a Tax ID while the month\'s purchases from them stay within ₦2 million')}
          </>
        )}
      </div>
      {!ro && f && <div className="drawer-ft"><button className="btn btn-primary" disabled={busy} onClick={save}>{busy ? 'Saving…' : 'Save'}</button><button className="btn btn-ghost" onClick={onClose}>Cancel</button></div>}
    </Drawer>
  );
}

export function useCan() {
  const { data: inv } = useInventory();
  return useMemo(() => ({ keep: can(inv, 'keep_books'), pay: can(inv, 'make_payments') || can(inv, 'keep_books'), owner: can(inv, 'owner') }), [inv]);
}
