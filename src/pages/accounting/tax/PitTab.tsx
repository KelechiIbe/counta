// Personal income tax for a business name, a sole proprietor or a partnership, year by year from 2025 accounts. The
// business's assessable profit comes from the same figures and adjustments as companies income tax (Figures and
// Adjustments are the same screens); the PIT rule book then adds back the private share of mixed-use costs, donations and
// research above 5% of turnover. Each person (the proprietor, or each partner) has a return of their own for the state that
// taxes them: TaxStreem Flux files those for the states it covers, and the business marks the others filed. An NGO sees why
// it is exempt, and the owner can say it trades.
import { useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useInventory, useSession, useToast } from '../../../state/session';
import { ai, rpc, signedDoc, supabase } from '../../../lib/supabase';
import { edge, money } from '../../../lib/api';
import { N2, fmtDay, when } from '../../../lib/format';
import { CA_CATEGORIES, OTHER_INCOME, PIT_STATE, RELIEFS, pitLaw, usePitYear, usePitYears } from '../../../lib/tax';
import { buildPitPack } from '../../../lib/pitPack';
import { downloadBlob, safeName } from '../../../lib/exporters';
import { TB_FIELDS, tbRows } from '../../../lib/moveBooks';
import { Icon } from '../../../components/Icon';
import { Alert, Drawer, Empty, Field, MenuButton, Modal, ModalHead, Pills, SkeletonRows, Spinner, Stat } from '../../../components/ui';
import { SheetRows } from '../../../components/SheetRows';
import { Adjustments, Figures, TaxAssetModal, amt, openInTab, useTaxRefresh } from './CitTab';

type Sub = 'computation' | 'people' | 'figures' | 'adjustments' | 'mixed' | 'allowances' | 'accounts';
const KIND_LABEL: Record<string, string> = { sole: 'Sole proprietor', partnership: 'Partnership' };
const ROLE_LABEL: Record<string, string> = { proprietor: 'Proprietor', active: 'Partner in the business', dormant: 'Dormant partner' };

export default function PitTab({ year, setYear }: { year: number | null; setYear: (y: number) => void }) {
  const years = usePitYears();
  const list: any[] = years.data?.years || [];
  useEffect(() => {
    if (year || !list.length) return;
    setYear((list.find((y) => y.ended && y.has_data) || list.find((y) => y.ended) || list[0]).year);
  }, [list.length]); // eslint-disable-line react-hooks/exhaustive-deps
  if (years.isLoading) return <SkeletonRows n={6} />;
  if (years.error) return <Alert kind="yellow" icon="shield">{(years.error as Error).message}</Alert>;
  if (years.data?.kind === 'exempt') return <ExemptPanel />;
  if (!list.length) return <Empty>Counta prepares personal income tax from 2025 accounts. There is no year to show yet.</Empty>;
  return (
    <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '270px minmax(0,1fr)', gap: 16, alignItems: 'start' }}>
      <div className="stack" style={{ gap: 8 }}>
        {list.map((y) => {
          const st = PIT_STATE[y.state] || PIT_STATE.draft;
          const on = y.year === year;
          return (
            <button key={y.year} className="card card-pad" onClick={() => setYear(y.year)} aria-pressed={on} data-testid={`pit-year-${y.year}`}
              style={{ textAlign: 'left', cursor: 'pointer', border: on ? '1.5px solid #0072F5' : undefined, padding: 14, background: on ? '#F5F9FF' : undefined }}>
              <div className="row" style={{ justifyContent: 'space-between' }}><b>{y.year} accounts</b><span className={'chip ' + st.tone}>{st.label}</span></div>
              <div className="faint" style={{ fontSize: 12, marginTop: 4 }}>Year of assessment {y.yoa} · {y.regime === 'PITA' ? 'PITA' : 'NTA 2025'}{y.ended ? ` · due ${fmtDay(y.due)}` : ' · running'}</div>
              <div className="row" style={{ justifyContent: 'space-between', marginTop: 8, fontSize: 13 }}>
                {!y.has_data ? <span className="muted">No figures yet</span>
                  : y.tax != null ? <span>Income tax <b className="num">{N2(y.tax)}</b></span>
                  : <span>Assessable profit <b className="num">{amt(y.assessable)}</b></span>}
                {Number(y.blocks) > 0 && y.state === 'draft' && <span style={{ color: '#B45309', fontSize: 12 }}>{y.blocks} to settle</span>}
              </div>
            </button>
          );
        })}
        <div className="faint" style={{ fontSize: 12, lineHeight: 1.5, padding: '0 4px' }}>
          2025 accounts use the old law (Personal Income Tax Act); 2026 accounts onwards the Nigeria Tax Act 2025. Each return is due on 31 March after the year ends.
        </div>
      </div>
      <div style={{ minWidth: 0 }}>{year ? <PitYear key={year} year={year} firstYear={Number(years.data?.first_year || 2025)} /> : <Empty>Choose a year.</Empty>}</div>
    </div>
  );
}

// ---------------------------------------------------------------- an NGO
function ExemptPanel() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const nav = useNavigate();
  const [busy, setBusy] = useState(false);
  const owner = inv?.me.role === 'owner';
  const guarantee = !!(inv?.org as any)?.cit_profile?.limited_by_guarantee;
  async function set(p: Record<string, boolean>, ok: string, to?: string) {
    setBusy(true);
    try { await rpc('save_income_tax_setup', { p_org: orgId, p }); toast(ok); await refresh(); if (to) nav(to); } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <div className="card card-pad stack" style={{ gap: 12, maxWidth: 720 }} data-testid="pit-exempt">
      <div className="row" style={{ gap: 8 }}><Icon name="shield" size={18} color="#15803D" /><b style={{ fontSize: 17 }}>Exempt from income tax</b></div>
      <div style={{ fontSize: 14, lineHeight: 1.6 }}>
        {guarantee ? 'CAC records the business as a company limited by guarantee.' : 'CAC records the business as incorporated trustees.'} An organisation engaged in
        educational, religious or charitable activities of a public character pays no income tax on its income, except on profits from a trade or business it
        carries on (Nigeria Tax Act 2025, s.162(1)(a)(iii)). Its trading profits are taxed as a company's.
      </div>
      <div className="faint" style={{ fontSize: 13 }}>It still deducts and pays WHT and PAYE for others, and charges VAT where its sales are taxable.</div>
      {owner ? (
        <div className="row wrap" style={{ gap: 8 }}>
          <button className="btn btn-secondary btn-sm" disabled={busy} onClick={() => set({ ngo_trades: true }, 'Companies income tax is now worked out on its profits', '/tax/cit')}>
            <Icon name="building" size={14} />It carries on a trade or business</button>
          {guarantee && <button className="btn btn-ghost btn-sm" disabled={busy} onClick={() => set({ limited_by_guarantee: false }, 'Taxed as a company', '/tax/cit')}>It is not an NGO</button>}
        </div>
      ) : <div className="faint" style={{ fontSize: 12 }}>The owner can change this if the business trades.</div>}
    </div>
  );
}

// ---------------------------------------------------------------- one year
function PitYear({ year, firstYear }: { year: number; firstYear: number }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const q = usePitYear(year);
  const [sub, setSub] = useState<Sub>('computation');
  const [busy, setBusy] = useState<string | null>(null);
  const [modal, setModal] = useState<null | 'approve' | 'reopen' | 'send' | 'outside'>(null);
  const [reason, setReason] = useState('');
  const [attest, setAttest] = useState(false);
  const [sendOut, setSendOut] = useState<any>(null);
  const [filing, setFiling] = useState<any>(null);
  const d = q.data;
  if (q.isLoading) return <SkeletonRows n={8} />;
  if (q.error) return <Alert kind="yellow" icon="shield">{(q.error as Error).message}</Alert>;
  if (!d) return null;
  if (d.needs_setup) return <SetupCard d={d} />;
  const comp = d.computation || {};
  const fig = comp.figures || {};
  const biz = comp.business || {};
  const people: any[] = comp.people || [];
  const checks: any[] = comp.checks || [];
  const blocks = checks.filter((c) => c.severity === 'block');
  const st = PIT_STATE[d.state] || PIT_STATE.draft;
  const draft = d.row?.status === 'draft';
  const can = d.can || {};
  const fluxPeople = people.filter((p) => p.flux && ['approved', 'rejected'].includes(p.status));

  async function act(key: string, fn: () => Promise<any>, ok?: string) {
    setBusy(key);
    try { const r = await fn(); if (ok) toast(ok); await refresh(); return r ?? true; } catch (e) { toast((e as Error).message, 'err'); return null; } finally { setBusy(null); }
  }
  async function download(kind: 'docx' | 'pdf' | 'xlsx') {
    setBusy('download');
    try {
      const m = buildPitPack(d, inv?.org.name || '');
      const mod = await import('../../../lib/fsExport');
      const blob = kind === 'docx' ? await mod.packDocx(m) : kind === 'pdf' ? await mod.packPdf(m) : await mod.packXlsx(m);
      downloadBlob(blob, `${safeName(`${inv?.org.name || 'Business'} income tax ${year}${draft ? ' draft' : ''}`)}.${kind}`);
    } catch (e) { toast((e as Error).message || 'Could not make the file.', 'err'); }
    setBusy(null);
  }
  async function send() {
    setBusy('send'); setSendOut(null);
    try {
      const r = await edge<any>('tax-files', { action: 'pit_send', org_id: orgId, year });
      setSendOut(r);
      if (r.ok) { toast(`Sent ${r.sent} return${r.sent === 1 ? '' : 's'} to TaxStreem Flux`); if (!r.failed) setModal(null); }
      await refresh();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }

  return (
    <div className="stack" style={{ gap: 14 }} data-testid="pit-year">
      <div className="card card-pad stack" style={{ gap: 12 }}>
        <div className="row wrap" style={{ justifyContent: 'space-between', gap: 10, alignItems: 'flex-start' }}>
          <div style={{ minWidth: 0 }}>
            <div className="row wrap" style={{ gap: 8 }}>
              <span style={{ fontSize: 20, fontWeight: 700 }}>{year} accounts</span>
              <span className={'chip ' + st.tone} data-testid="pit-state">{st.label}</span>
              {comp.kind && <span className="chip t-grey">{KIND_LABEL[comp.kind] || comp.kind}</span>}
            </div>
            <div className="muted" style={{ fontSize: 13, marginTop: 4 }}>
              Year of assessment {comp.yoa} · {fmtDay(d.period?.from)} to {fmtDay(d.period?.to)} · {pitLaw(comp.regime)}
            </div>
          </div>
          <div className="row wrap">
            <MenuButton label={draft ? 'Draft computation' : 'Computation'} icon="download" busy={busy === 'download' ? 'Preparing…' : undefined} width={220}
              items={[{ key: 'pdf', label: 'PDF', icon: 'file', onClick: () => download('pdf') }, { key: 'docx', label: 'Word', icon: 'file', onClick: () => download('docx') },
                { key: 'xlsx', label: 'Excel', icon: 'columns', onClick: () => download('xlsx') }]} />
            {can.approve && draft && (
              <button className="btn btn-primary btn-sm" disabled={!!busy || blocks.length > 0} title={blocks.length ? 'Settle the points marked to fix first' : undefined}
                onClick={() => { setAttest(false); setModal('approve'); }} data-testid="pit-approve"><Icon name="check" size={14} color="#fff" />Approve</button>)}
            {can.approve && d.row?.status === 'approved' && fluxPeople.length > 0 && (
              <button className="btn btn-primary btn-sm" disabled={!!busy} onClick={() => { setSendOut(null); setModal('send'); }}><Icon name="send" size={14} color="#fff" />Send to Flux</button>)}
            {can.approve && d.row?.status === 'approved' && !people.some((p) => ['sent', 'filed'].includes(p.status)) && (
              <button className="btn btn-ghost btn-sm" disabled={!!busy} onClick={() => { setReason(''); setModal('reopen'); }}><Icon name="undo" size={14} />Reopen</button>)}
            {can.approve && draft && <button className="btn btn-ghost btn-sm" disabled={!!busy} onClick={() => { setReason(''); setModal('outside'); }}>Filed outside Counta</button>}
            {can.approve && d.row?.status === 'filed_outside' && (
              <button className="btn btn-ghost btn-sm" disabled={!!busy} onClick={() => act('outside', () => rpc('mark_pit_filed', { p_org: orgId, p_year: year, p: { outside: false } }), 'Back to a draft')}>
                <Icon name="undo" size={14} />Not filed after all</button>)}
          </div>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(128px,1fr))', gap: 8 }}>
          <Stat label="Profit before tax" value={amt(biz.figures?.profit_before_tax)} />
          <Stat label="Assessable profit" value={amt(biz.figures?.assessable)} sub={comp.kind === 'partnership' ? `shared by ${people.length}` : undefined} />
          {can.see_all && <Stat label="Income tax" value={N2(fig.tax)} sub={Number(fig.cgt) ? `+ ${N2(fig.cgt)} capital gains tax` : undefined} />}
          {can.see_all && <Stat label="Payable" value={N2(fig.payable)} color="#0072F5" sub={Number(fig.wht_credit_used) ? `after ${N2(fig.wht_credit_used)} of WHT credits` : undefined} />}
          <Stat label="Due" value={comp.ended ? fmtDay(comp.due) : 'Year still running'} />
        </div>
        {d.row?.status === 'approved' && <div className="faint" style={{ fontSize: 12 }}>Approved by {d.row.approved_by || 'someone'} ({when(d.row.approved_at)}), who confirmed the statement of accounts. The figures are frozen; reopen the year to change them.</div>}
        {d.row?.status === 'filed_outside' && <Alert kind="green" icon="check">Marked as filed outside Counta{d.row.settings?.filed_outside?.note ? `: ${d.row.settings.filed_outside.note}` : ''}. Losses and allowances still carry on to the next year.</Alert>}
        {d.row?.status === 'approved' && <FilingList people={people} canMark={!!can.approve} onMark={setFiling} />}
      </div>

      {checks.length > 0 && draft && (
        <div className="card" style={{ overflow: 'hidden' }} data-testid="pit-checks">
          {checks.map((c, i) => (
            <div key={c.id + i} className="tr" style={{ gridTemplateColumns: '24px minmax(0,1fr)', gap: 10, fontSize: 13 }}>
              <Icon name={c.severity === 'block' ? 'alert' : c.severity === 'warn' ? 'info' : 'check'} size={15} color={c.severity === 'block' ? '#DC2626' : c.severity === 'warn' ? '#B45309' : '#6B7280'} />
              <span>{c.text}{c.severity === 'block' && <span className="faint"> · to fix before approving</span>}</span>
            </div>
          ))}
        </div>
      )}

      <Pills value={sub} onChange={setSub} options={[{ id: 'computation', label: 'Computation' }, { id: 'people', label: comp.kind === 'partnership' ? 'Partners' : 'Proprietor' },
        { id: 'figures', label: 'Figures' }, { id: 'adjustments', label: 'Adjustments' }, { id: 'mixed', label: 'Mixed use' }, { id: 'allowances', label: 'Capital allowances' },
        { id: 'accounts', label: 'Statement of accounts' }]} />
      {sub === 'computation' && <Computation d={d} />}
      {sub === 'people' && <People d={d} year={year} firstYear={firstYear} />}
      {sub === 'figures' && (d.cit ? <Figures d={d.cit} year={year} /> : <Alert kind="grey" icon="lock">The figures are for those who keep the books or see the money.</Alert>)}
      {sub === 'adjustments' && (d.cit ? <div className="stack" style={{ gap: 10 }}>
        <div className="faint" style={{ fontSize: 13 }}>The same adjustments as for companies income tax. Mixed use, donations and research above 5% of turnover are then added for personal income tax, on the Computation.</div>
        <Adjustments d={d.cit} year={year} /></div> : <Alert kind="grey" icon="lock">The adjustments are for those who keep the books or see the money.</Alert>)}
      {sub === 'mixed' && <MixedUse d={d} year={year} />}
      {sub === 'allowances' && <Allowances d={d} year={year} firstYear={firstYear} />}
      {sub === 'accounts' && <Accounts d={d} year={year} />}

      {modal === 'approve' && (
        <Modal onClose={() => setModal(null)} width={540}>
          <ModalHead title={`Approve the ${year} returns`} sub={`Year of assessment ${comp.yoa} · ${people.length} return${people.length === 1 ? '' : 's'}`} onClose={() => setModal(null)} />
          <div className="modal-body stack" style={{ gap: 10 }}>
            {people.map((p) => (
              <div key={p.person_id} className="row" style={{ justifyContent: 'space-between', fontSize: 14 }}>
                <span>{p.name} <span className="faint">· {p.authority_short || p.authority || 'no state'}</span></span><span className="num">{N2(p.computation?.figures?.payable)}</span>
              </div>
            ))}
            <div className="row" style={{ justifyContent: 'space-between', fontWeight: 700 }}><span>Payable in all</span><span className="num">{N2(fig.payable)}</span></div>
            <label className="check" style={{ alignItems: 'flex-start', fontSize: 13, lineHeight: 1.5 }}>
              <input type="checkbox" checked={attest} onChange={(e) => setAttest(e.target.checked)} data-testid="pit-attest" />
              <span>I confirm that the statement of accounts is a true and correct account of the business's income and expenses for the year, and that the people, shares and reliefs here are as stated. The return goes to the state with it (NTAA 2025 s.13(2)(d)).</span>
            </label>
            <Alert kind="grey" icon="lock">Approving freezes the figures and every person's return. Later changes to the books do not alter an approved return.</Alert>
            {checks.filter((c) => c.severity === 'warn').length > 0 && <Alert kind="amber" icon="info">{checks.filter((c) => c.severity === 'warn').map((c) => c.text).join(' ')}</Alert>}
          </div>
          <div className="modal-ft"><button className="btn btn-secondary" onClick={() => setModal(null)}>Cancel</button>
            <button className="btn btn-primary" disabled={!!busy || !attest} onClick={async () => { if (await act('approve', () => rpc('approve_pit_year', { p_org: orgId, p_year: year, p: { attest: true } }), `${year} returns approved`)) setModal(null); }}>Approve</button></div>
        </Modal>
      )}
      {modal === 'reopen' && (
        <Modal onClose={() => setModal(null)} width={480}>
          <ModalHead title={`Reopen the ${year} returns`} onClose={() => setModal(null)} />
          <div className="modal-body stack" style={{ gap: 10 }}>
            <div className="muted" style={{ fontSize: 13 }}>The approval is cleared and the year is worked out again from the current figures.</div>
            <Field label="Why"><input className="input" autoFocus value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
          </div>
          <div className="modal-ft"><button className="btn btn-secondary" onClick={() => setModal(null)}>Cancel</button>
            <button className="btn btn-primary" disabled={!!busy || reason.trim().length < 3} onClick={async () => { if (await act('reopen', () => rpc('reopen_pit_year', { p_org: orgId, p_year: year, p_reason: reason }), 'Reopened')) setModal(null); }}>Reopen</button></div>
        </Modal>
      )}
      {modal === 'outside' && (
        <Modal onClose={() => setModal(null)} width={480}>
          <ModalHead title={`The ${year} returns were filed outside Counta`} onClose={() => setModal(null)} />
          <div className="modal-body stack" style={{ gap: 10 }}>
            <div className="muted" style={{ fontSize: 13 }}>For a year an accountant or the state's portal already took care of. Counta stops reminding you, and losses and allowances still carry on.</div>
            <Field label="Note (optional)"><input className="input" autoFocus value={reason} onChange={(e) => setReason(e.target.value)} placeholder="For example, filed with LIRS by our accountant" /></Field>
          </div>
          <div className="modal-ft"><button className="btn btn-secondary" onClick={() => setModal(null)}>Cancel</button>
            <button className="btn btn-primary" disabled={!!busy} onClick={async () => { if (await act('outside', () => rpc('mark_pit_filed', { p_org: orgId, p_year: year, p: { outside: true, note: reason } }), 'Marked as filed')) setModal(null); }}>Mark as filed</button></div>
        </Modal>
      )}
      {modal === 'send' && (
        <Modal onClose={() => setModal(null)} width={520}>
          <ModalHead title="Send to TaxStreem Flux" sub={`${year} accounts · year of assessment ${comp.yoa}`} onClose={() => setModal(null)} />
          <div className="modal-body stack" style={{ gap: 10, fontSize: 14 }}>
            <div>Flux files these returns with the state, each with the computation, the business's figures{comp.kind === 'partnership' ? ', the partners and their shares' : ''} and the statement of accounts:</div>
            <div className="stack" style={{ gap: 4, fontSize: 13 }}>
              {fluxPeople.map((p) => <span key={p.person_id}><Icon name="check" size={13} color="#15803D" /> {p.name} · {p.authority_name || p.authority} · {N2(p.computation?.figures?.payable)}</span>)}
            </div>
            {people.filter((p) => !p.flux).length > 0 && <div className="faint" style={{ fontSize: 12 }}>Flux does not file in {Array.from(new Set(people.filter((p) => !p.flux).map((p) => p.authority_state || p.authority_short || p.authority))).join(', ')} yet. Download the computation, file those returns with the state and mark them filed here.</div>}
            {sendOut && !sendOut.ok && <Alert kind={sendOut.reason === 'not_configured' ? 'blue' : 'red'} icon="info">{sendOut.error}</Alert>}
            {sendOut?.failed > 0 && sendOut.ok && <Alert kind="amber" icon="info">{(sendOut.results || []).filter((r: any) => !r.ok).map((r: any) => `${r.name}: ${r.error}`).join(' ')}</Alert>}
          </div>
          <div className="modal-ft"><button className="btn btn-secondary" onClick={() => setModal(null)}>Close</button>
            <button className="btn btn-primary" disabled={!!busy} onClick={send}>{busy === 'send' ? 'Sending…' : 'Send'}</button></div>
        </Modal>
      )}
      {filing && <MarkFiled year={year} person={filing} onClose={() => setFiling(null)} />}
    </div>
  );
}

// Each person's return once the year is approved: with Flux, filed, sent back, or to file.
function FilingList({ people, canMark, onMark }: { people: any[]; canMark: boolean; onMark: (p: any) => void }) {
  return (
    <div className="stack" style={{ gap: 6 }} data-testid="pit-filing">
      {people.map((p) => {
        const s = p.status === 'filed' ? { tone: 't-green', text: `Filed${p.filed_at ? ' ' + fmtDay(String(p.filed_at).slice(0, 10)) : ''}${p.acknowledgement_ref ? ` · ${p.acknowledgement_ref}` : ''}${p.filed_by_business ? ' (by the business)' : ''}` }
          : p.status === 'sent' ? { tone: 't-amber', text: `With Flux${p.flux_ref ? ` (${p.flux_ref})` : ''}${p.flux_message ? ` · ${p.flux_message}` : ''}` }
          : p.status === 'rejected' ? { tone: 't-red', text: `Sent back${p.flux_message ? `: ${p.flux_message}` : ''}` }
          : p.flux_status === 'send_failed' ? { tone: 't-red', text: `Not sent: ${p.flux_message || 'Flux did not take it'}` }
          : { tone: 't-grey', text: p.flux ? 'Ready for Flux' : 'To file with the state' };
        return (
          <div key={p.person_id} className="row wrap" style={{ justifyContent: 'space-between', gap: 8, fontSize: 13 }}>
            <span style={{ minWidth: 0 }}><b>{p.name}</b> <span className="faint">· {p.authority_name || p.authority}</span></span>
            <span className="row" style={{ gap: 6 }}>
              <span className={'chip ' + s.tone}>{s.text}</span>
              {p.payment_url && <a className="btn btn-ghost btn-xs" href={p.payment_url} target="_blank" rel="noopener noreferrer"><Icon name="card" size={12} />Pay</a>}
              {canMark && ['approved', 'rejected'].includes(p.status) && <button className="btn btn-ghost btn-xs" onClick={() => onMark(p)}>Mark filed</button>}
            </span>
          </div>
        );
      })}
    </div>
  );
}

function MarkFiled({ year, person, onClose }: { year: number; person: any; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const [ref, setRef] = useState('');
  const [on, setOn] = useState('');
  const [busy, setBusy] = useState(false);
  async function save() {
    setBusy(true);
    try { await rpc('mark_pit_filed', { p_org: orgId, p_year: year, p: { person_id: person.person_id, acknowledgement_ref: ref, filed_on: on || null } }); toast('Marked as filed'); await refresh(); onClose(); }
    catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={460}>
      <ModalHead title={`${person.name}'s return`} sub={`Filed with ${person.authority_name || person.authority}`} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 10 }}>
        <Field label="Acknowledgement or assessment number"><input className="input" autoFocus value={ref} onChange={(e) => setRef(e.target.value)} /></Field>
        <Field label="Filed on"><input className="input" type="date" value={on} onChange={(e) => setOn(e.target.value)} style={{ maxWidth: 200 }} /></Field>
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy || ref.trim().length < 3} onClick={save}>Save</button></div>
    </Modal>
  );
}

// ---------------------------------------------------------------- first time: who the people are
function SetupCard({ d }: { d: any }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const [busy, setBusy] = useState(false);
  const names: string[] = d.suggested || [];
  if (!d.can?.approve) return <Alert kind="blue" icon="info">Whoever files the business's tax sets up its income tax first: who owns the business, or who its partners are.</Alert>;
  return (
    <div className="card card-pad stack" style={{ gap: 12, maxWidth: 680 }} data-testid="pit-setup">
      <b style={{ fontSize: 17 }}>Who pays the tax on this business's profit?</b>
      <div style={{ fontSize: 14, lineHeight: 1.6 }}>A business name pays personal income tax through its owner, or through its partners in their shares of the profit, each to the state they belong to.</div>
      {names.length > 0 ? <div style={{ fontSize: 14 }}>CAC has {names.length === 1 ? 'one proprietor' : `${names.length} proprietors`}: <b>{names.join(', ')}</b>. Start with {names.length === 1 ? 'that name' : 'those names'}; you can add or remove people next.</div>
        : <div style={{ fontSize: 14 }}>Counta starts with the owner. Add partners next if there are any.</div>}
      <div><button className="btn btn-primary btn-sm" disabled={busy} onClick={async () => { setBusy(true); try { await rpc('pit_setup', { p_org: orgId }); await refresh(); } catch (e) { toast((e as Error).message, 'err'); } setBusy(false); }}>
        {busy ? <Spinner small /> : <Icon name="users" size={14} color="#fff" />}Start</button></div>
    </div>
  );
}

// ---------------------------------------------------------------- the computation
function Rows({ rows }: { rows: any[] }) {
  return (
    <>
      {rows.map((r: any) => {
        const strong = r._style === 'subtotal' || r._style === 'total';
        return (
          <div key={r.id} className="tr" style={{ gridTemplateColumns: 'minmax(0,1fr) 150px', fontWeight: strong ? 700 : undefined,
            background: r._style === 'total' ? '#F5F9FF' : strong ? '#FAFAFA' : undefined, color: r._style === 'memo' ? '#4B5563' : undefined }}>
            <span style={{ minWidth: 0 }}>{r.line}{r.basis && <span className="faint" style={{ display: 'block', fontSize: 12, fontWeight: 400 }}>{r.basis}</span>}</span>
            <span className="right num">{amt(r.amount)}</span>
          </div>
        );
      })}
    </>
  );
}

function Computation({ d }: { d: any }) {
  const comp = d.computation || {};
  const people: any[] = comp.people || [];
  const [open, setOpen] = useState<string | null>(people.length === 1 ? people[0]?.person_id : null);
  return (
    <div className="stack" style={{ gap: 12 }}>
      <div className="card" style={{ overflow: 'hidden' }} data-testid="pit-business">
        <div className="card-hd"><b>The business</b></div>
        <Rows rows={comp.business?.rows || []} />
      </div>
      {people.map((p) => {
        const f = p.computation?.figures || {};
        const isOpen = open === p.person_id;
        return (
          <div key={p.person_id} className="card" style={{ overflow: 'hidden' }} data-testid="pit-person">
            <button type="button" className="card-hd row" style={{ justifyContent: 'space-between', width: '100%', textAlign: 'left', cursor: 'pointer', gap: 8, flexWrap: 'wrap',
              border: 0, borderBottom: isOpen ? '1px solid var(--line)' : 0, background: 'none', font: 'inherit', color: 'inherit' }}
              onClick={() => setOpen(isOpen ? null : p.person_id)} aria-expanded={isOpen}>
              <span style={{ minWidth: 0 }}><b>{p.name}</b>
                <span className="faint" style={{ fontSize: 12 }}> · {ROLE_LABEL[p.role] || p.role}{comp.kind === 'partnership' ? ` · ${Number(p.share_pct)}%` : ''} · {p.authority_name || 'state not known'}</span></span>
              <span className="row" style={{ gap: 8 }}>
                {p.hidden ? <span className="faint" style={{ fontSize: 12 }}>Share {amt(f.business_income)}</span>
                  : <span style={{ fontSize: 13 }}>Payable <b className="num">{N2(f.payable)}</b></span>}
                <Icon name={isOpen ? 'chevD' : 'chevR'} size={14} />
              </span>
            </button>
            {isOpen && (
              <>
                <Rows rows={p.computation?.rows || []} />
                {p.hidden ? <div className="faint" style={{ padding: '10px 16px', fontSize: 12 }}>{p.name}'s reliefs, other income and tax are seen only by them and by those who file the business's tax.</div> : (
                  <div className="faint" style={{ padding: '10px 16px', fontSize: 12, lineHeight: 1.6 }}>
                    {(p.computation?.other_income || []).filter((l: any) => l.treatment !== 'taxable').map((l: any) => (
                      <span key={l.label + l.amount} style={{ display: 'block' }}>{l.label} {N2(l.amount)}: {l.treatment === 'final' ? 'taxed in full when the tax was deducted, so left out' : l.treatment === 'exempt_minimum_wage' ? 'pay of the national minimum wage or less, exempt' : 'exempt'}.</span>
                    ))}
                    Effective rate {(Number(f.effective_rate || 0) * 100).toFixed(1)}%, top rate {(Number(f.marginal_rate || 0) * 100).toFixed(0)}%. Carried forward: losses {N2(p.computation?.cf?.losses)}, unused capital allowances {N2(p.computation?.cf?.ca)}.
                  </div>
                )}
              </>
            )}
          </div>
        );
      })}
      <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>
        Computed under the {comp.rulebook?.law || pitLaw(comp.regime)}; rules {comp.rulebook?.id}{comp.rulebook?.status !== 'approved' ? ' (awaiting TaxStreem sign-off)' : ''}.
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- the people
function People({ d, year, firstYear }: { d: any; year: number; firstYear: number }) {
  const comp = d.computation || {};
  const people: any[] = comp.people || [];
  const [edit, setEdit] = useState<any>(null);
  const can = d.can || {};
  const me = d.me;
  const inactive = (d.people_all || []).filter((x: any) => !x.active && !people.some((p) => p.person_id === x.id));
  return (
    <div className="stack" style={{ gap: 12 }}>
      <div className="card" style={{ overflow: 'auto' }}>
        <div className="card-hd row" style={{ justifyContent: 'space-between' }}>
          <b>{comp.kind === 'partnership' ? 'Partners' : 'Proprietor'}</b>
          {can.edit_people && <button className="btn btn-secondary btn-sm" onClick={() => setEdit({ new: true })}><Icon name="plus" size={13} />{comp.kind === 'partnership' ? 'Partner' : 'Add a partner'}</button>}
        </div>
        {people.map((p) => {
          const mine = me && p.person_id === me;
          const click = can.edit_people || (mine && can.edit_self);
          return (
            <div key={p.person_id} className={'tr rsp' + (click ? ' click' : '')} onClick={() => click && setEdit(p)} data-testid="pit-person-row"
              style={{ gridTemplateColumns: 'minmax(180px,1.4fr) 90px minmax(160px,1fr) minmax(140px,1fr)', minWidth: 640, fontSize: 13, alignItems: 'start' }}>
              <span className="m-main" style={{ minWidth: 0 }}><b>{p.name}</b>{mine && <span className="chip t-blue" style={{ marginLeft: 6 }}>You</span>}
                <span className="faint" style={{ display: 'block', fontSize: 11 }}>{ROLE_LABEL[p.role] || p.role}{p.tin ? ` · Tax ID ${p.tin}` : ' · no Tax ID yet'}</span></span>
              <span className="num" data-label="Share">{comp.kind === 'partnership' ? `${Number(p.share_pct)}%` : '100%'}</span>
              <span className="muted">{p.role === 'active' ? `Works from ${p.office?.name || 'an office'}${p.office?.state ? ` (${p.office.state})` : ''}` : p.resident === false ? 'Lives outside Nigeria' : 'Lives in ' + (p.authority_state || 'a state not chosen')}</span>
              <span className="m-line">{p.authority_name || <span style={{ color: '#B45309' }}>Choose the state</span>}</span>
            </div>
          );
        })}
      </div>
      {inactive.length > 0 && <div className="faint" style={{ fontSize: 12 }}>No longer with the business: {inactive.map((x: any) => x.name).join(', ')}.</div>}
      <div className="faint" style={{ fontSize: 12, lineHeight: 1.6 }}>
        {comp.kind === 'partnership'
          ? 'Profit is shared as the partnership agreement says, equally where there is none (NTA 2025 s.15(3)). A partner who works in the business pays the state of the office he works from; a dormant partner the state he lives in, or the NRS if he lives abroad (Twelfth Schedule para 4).'
          : 'The owner is taxed on the whole profit and pays the state he lived in on 1 January of the year of assessment (Twelfth Schedule para 6). With two or more owners, the business is a partnership.'}
      </div>
      {edit && <PersonDrawer d={d} year={year} firstYear={firstYear} person={edit} onClose={() => setEdit(null)} />}
    </div>
  );
}

interface Line { kind: string; label: string; amount: string; tax_deducted: string }
function PersonDrawer({ d, year, firstYear, person, onClose }: { d: any; year: number; firstYear: number; person: any; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const comp = d.computation || {};
  const isNew = !!person.new;
  const all = !!d.can?.edit_people;
  const legacy = comp.regime === 'PITA';
  const s = (v: unknown) => (v == null || v === '' || Number(v) === 0 ? '' : String(v));
  const base = (d.people_all || []).find((x: any) => x.id === person.person_id) || {};
  const [f, setF] = useState({
    name: person.name || '', tin: person.tin || base.tin || '', member_id: base.member_id || '',
    share_pct: isNew ? '' : String(person.share_pct ?? ''), role: person.role === 'proprietor' ? 'active' : person.role || 'active',
    office_location_id: person.office_location_id || '', residence: person.residence || '', resident: person.resident !== false,
    remuneration: s(person.remuneration), remuneration_note: person.remuneration_note || '',
    losses_bf: s(person.opening?.losses_bf), ca_bf: s(person.opening?.ca_bf),
    reliefs: Object.fromEntries(RELIEFS.map((r) => [r.id, s(person.reliefs?.[r.id])])) as Record<string, string>,
    other: ((person.other_income || []) as any[]).map((l) => ({ kind: l.kind, label: l.label || '', amount: String(l.amount ?? ''), tax_deducted: s(l.tax_deducted) })) as Line[],
  });
  const [busy, setBusy] = useState(false);
  const set = (k: string, v: any) => setF((x) => ({ ...x, [k]: v }));
  const sole = comp.kind === 'sole' && !isNew;
  const firstForPerson = !person.bf?.from_previous_year;
  const reliefs = RELIEFS.filter((r) => r.law === 'both' || (legacy ? r.law === 'pita' : r.law === 'nta'));
  async function save(remove = false) {
    setBusy(true);
    try {
      let id = person.person_id as string | undefined;
      if (all && (isNew || remove || f.name !== person.name || f.tin !== (person.tin || base.tin || '') || f.member_id !== (base.member_id || ''))) {
        const r = await rpc<any>('save_pit_person', { p_org: orgId, p: remove ? { id, delete: true } : { id: id || null, name: f.name, tin: f.tin || null, member_id: f.member_id || null } });
        if (remove) { toast(r.removed ? 'Removed' : 'Kept for earlier years, and left out from now on'); await refresh(); onClose(); setBusy(false); return; }
        id = r.id;
      }
      const n = (v: string) => (v.trim() === '' ? 0 : money(v));
      const p: Record<string, unknown> = {
        residence: f.residence || null, resident: f.resident,
        reliefs: Object.fromEntries(reliefs.map((r) => [r.id, n(f.reliefs[r.id] || '')])),
        other_income: f.other.filter((l) => l.amount.trim() || l.label.trim()).map((l) => ({ kind: l.kind, label: l.label, amount: money(l.amount), tax_deducted: n(l.tax_deducted) })),
      };
      if (firstForPerson) p.opening = { losses_bf: n(f.losses_bf), ca_bf: n(f.ca_bf) };
      if (all) Object.assign(p, { remuneration: n(f.remuneration), remuneration_note: f.remuneration_note || null,
        ...(sole ? {} : { share_pct: money(f.share_pct) ?? 0, role: f.role, office_location_id: f.office_location_id || null }) });
      await rpc('save_pit_person_year', { p_org: orgId, p_year: year, p_person: id, p });
      toast('Saved and worked out again'); await refresh(); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  const states = (d.authorities || []).filter((a: any) => a.code !== 'NRS');
  return (
    <Drawer onClose={onClose} width={640}>
      <div className="drawer-hd"><div className="grow"><div className="drawer-title">{isNew ? 'A partner' : person.name}</div>
        <div className="muted" style={{ fontSize: 13 }}>{year} accounts · year of assessment {comp.yoa}{!isNew && person.authority_name ? ` · ${person.authority_name}` : ''}</div></div>
        <button className="x-btn" onClick={onClose} aria-label="Close"><Icon name="x" size={18} /></button></div>
      <div className="drawer-body stack" style={{ gap: 14 }}>
        {all && (
          <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
            <Field label="Name" req style={{ gridColumn: '1 / -1' }}><input className="input" value={f.name} onChange={(e) => set('name', e.target.value)} /></Field>
            <Field label="Tax ID"><input className="input" value={f.tin} onChange={(e) => set('tin', e.target.value)} placeholder="From taxid.nrs.gov.ng" /></Field>
            <Field label="Their Counta login" hint="Linked, they can enter their own reliefs and other income."><select className="input" value={f.member_id} onChange={(e) => set('member_id', e.target.value)}>
              <option value="">Not linked</option>{(d.members || []).map((m: any) => <option key={m.id} value={m.id}>{m.name}</option>)}</select></Field>
          </div>
        )}
        {all && !sole && (
          <>
            <div className="label">In the partnership</div>
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
              <Field label="Share of the profit (%)" req><input className="input num" inputMode="decimal" value={f.share_pct} onChange={(e) => set('share_pct', e.target.value)} /></Field>
              <Field label="Role"><select className="input" value={f.role} onChange={(e) => set('role', e.target.value)}>
                <option value="active">Works in the business</option><option value="dormant">Dormant (does not work in it)</option></select></Field>
              {f.role === 'active' && <Field label="Office they work from" hint="The state of this office taxes them." style={{ gridColumn: '1 / -1' }}>
                <select className="input" value={f.office_location_id} onChange={(e) => set('office_location_id', e.target.value)}>
                  <option value="">Choose</option>{(d.locations || []).map((l: any) => <option key={l.id} value={l.id}>{l.name}{l.state ? ` (${l.state})` : ' (no state yet)'}</option>)}</select></Field>}
            </div>
          </>
        )}
        {(sole || f.role === 'dormant' || isNew || !all) && (
          <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
            <Field label={sole ? 'State they lived in on 1 January' : 'State they live in'} hint={sole ? 'That state taxes the owner (Twelfth Schedule para 6).' : undefined}>
              <select className="input" value={f.residence} disabled={!f.resident} onChange={(e) => set('residence', e.target.value)}>
                <option value="">Choose</option>{states.map((a: any) => <option key={a.code} value={a.code}>{a.state}</option>)}</select></Field>
            <label className="check" style={{ alignSelf: 'end', paddingBottom: 10 }}><input type="checkbox" checked={!f.resident} onChange={(e) => set('resident', !e.target.checked)} />Lives outside Nigeria (files with the NRS)</label>
          </div>
        )}
        {all && (
          <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
            <Field label={sole ? 'The owner\'s own pay charged as an expense' : 'Pay, interest on capital and benefits charged in the accounts'}
              hint={sole ? 'A drawing, added back to the owner.' : 'It goes to this partner before the profit is shared (s.15(1)(a)).'}>
              <input className="input num" inputMode="decimal" value={f.remuneration} onChange={(e) => set('remuneration', e.target.value)} /></Field>
            <Field label="Note"><input className="input" value={f.remuneration_note} onChange={(e) => set('remuneration_note', e.target.value)} placeholder="For example, salary in Salaries & Wages" /></Field>
          </div>
        )}
        {firstForPerson && (
          <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
            <Field label="Business losses brought forward" hint={year === firstYear ? 'From the last return filed before Counta.' : 'New to the business this year: usually nothing.'}>
              <input className="input num" inputMode="decimal" value={f.losses_bf} onChange={(e) => set('losses_bf', e.target.value)} /></Field>
            <Field label="Unused capital allowances brought forward"><input className="input num" inputMode="decimal" value={f.ca_bf} onChange={(e) => set('ca_bf', e.target.value)} /></Field>
          </div>
        )}
        <div className="label">Reliefs for {year}</div>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          {reliefs.map((r) => (
            <Field key={r.id} label={r.label} hint={r.hint}><input className="input num" inputMode="decimal" value={f.reliefs[r.id] || ''} data-relief={r.id}
              onChange={(e) => set('reliefs', { ...f.reliefs, [r.id]: e.target.value })} /></Field>
          ))}
        </div>
        <div className="faint" style={{ fontSize: 12 }}>{legacy ? 'Old law: pension, NHF, NHIS, life insurance and gratuity come off first, then the consolidated relief allowance, then home loan interest.' : 'These come off total income at full value (NTA 2025 s.30). There is no consolidated relief allowance from 2026.'} Keep the evidence: the state may ask for it.</div>
        <div className="row" style={{ justifyContent: 'space-between' }}><div className="label">Other income in {year}</div>
          <button className="btn btn-secondary btn-xs" onClick={() => set('other', [...f.other, { kind: 'employment', label: '', amount: '', tax_deducted: '' }])}><Icon name="plus" size={12} />Income</button></div>
        {!f.other.length && <div className="faint" style={{ fontSize: 13 }}>None. Add a salary, rent, dividends, interest or income from abroad, so the return covers everything.</div>}
        {f.other.map((l, i) => {
          const k = OTHER_INCOME.find((x) => x.id === l.kind);
          const upd = (patch: Partial<Line>) => set('other', f.other.map((y, j) => (j === i ? { ...y, ...patch } : y)));
          return (
            <div key={i} className="card" style={{ padding: 10, borderRadius: 10, display: 'grid', gridTemplateColumns: 'minmax(0,1fr) minmax(0,1fr) 32px', gap: 8 }}>
              <select className="input input-sm" style={{ gridColumn: '1 / 3' }} aria-label="Kind of income" value={l.kind} onChange={(e) => upd({ kind: e.target.value })}>{OTHER_INCOME.map((x) => <option key={x.id} value={x.id}>{x.label}</option>)}</select>
              <button className="x-btn" aria-label="Remove" onClick={() => set('other', f.other.filter((_, j) => j !== i))}><Icon name="x" size={14} /></button>
              <input className="input input-sm num" inputMode="decimal" placeholder="Amount" aria-label="Amount" value={l.amount} onChange={(e) => upd({ amount: e.target.value })} />
              <input className="input input-sm num" style={{ gridColumn: '2 / -1' }} inputMode="decimal" placeholder={l.kind === 'foreign_earned' ? 'Foreign tax' : l.kind === 'employment' ? 'PAYE' : 'Tax deducted'}
                aria-label={l.kind === 'foreign_earned' ? 'Foreign tax paid' : l.kind === 'employment' ? 'PAYE deducted' : 'Tax deducted'} value={l.tax_deducted} onChange={(e) => upd({ tax_deducted: e.target.value })} />
              <input className="input input-sm" style={{ gridColumn: '1 / -1' }} placeholder="Description (employer, property, bank)" aria-label="Description" value={l.label} onChange={(e) => upd({ label: e.target.value })} />
              {k?.hint && <span className="faint" style={{ gridColumn: '1 / -1', fontSize: 11 }}>{k.hint}</span>}
            </div>
          );
        })}
      </div>
      <div className="drawer-ft">
        <button className="btn btn-primary" disabled={busy || (all && f.name.trim().length < 2)} onClick={() => save()}>{busy ? 'Saving…' : 'Save'}</button>
        <button className="btn btn-ghost" onClick={onClose}>Cancel</button>
        {all && !isNew && <button className="btn btn-ghost" style={{ marginLeft: 'auto' }} disabled={busy} onClick={() => save(true)}><Icon name="trash" size={13} />Remove</button>}
      </div>
    </Drawer>
  );
}

// ---------------------------------------------------------------- mixed use
function MixedUse({ d, year }: { d: any; year: number }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const lines: any[] = (d.computation?.business?.mixed_use || []).filter((l: any) => Number(l.amount) !== 0 || l.marked);
  const [f, setF] = useState<Record<string, { on: boolean; pct: string }>>(() => Object.fromEntries(lines.map((l) => [l.cell, { on: !!l.marked, pct: String(l.marked ? l.business_pct : 50) }])));
  const [busy, setBusy] = useState(false);
  const ro = !d.can?.edit_business;
  const reviewed = !!d.row?.settings?.mixed_use_reviewed;
  async function save() {
    setBusy(true);
    try {
      const mu: Record<string, number | null> = {};
      for (const l of lines) mu[l.cell] = f[l.cell]?.on ? money(f[l.cell].pct) ?? 50 : null;
      await rpc('save_pit_year', { p_org: orgId, p_year: year, p: { mixed_use: mu } });
      toast('Saved and worked out again'); await refresh();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  if (!lines.length) return <Empty>No vehicle, internet, power or rent costs in the accounts for {year}.</Empty>;
  return (
    <div className="stack" style={{ gap: 12 }} data-testid="pit-mixed">
      <div className="muted" style={{ fontSize: 13, lineHeight: 1.6 }}>When a car, a phone line, the internet, power or a home is used both for the business and for private life, only the business share is deductible (PIT rule book s.4). Tick each one that is partly private. Assets used partly in private life get their business share of capital allowances under Capital allowances.</div>
      <div className="card" style={{ overflow: 'hidden' }}>
        {lines.map((l) => {
          const v = f[l.cell] || { on: false, pct: '50' };
          return (
            <div key={l.cell} className="tr rsp" style={{ gridTemplateColumns: 'minmax(0,1fr) 130px 160px', gap: 10, alignItems: 'center', fontSize: 14 }}>
              <label className="check m-main" style={{ minWidth: 0 }}><input type="checkbox" disabled={ro} checked={v.on} onChange={(e) => setF({ ...f, [l.cell]: { ...v, on: e.target.checked } })} data-cell={l.cell} />{l.label}</label>
              <span className="right num">{N2(l.amount)}</span>
              {v.on ? <span className="row m-end" style={{ gap: 6, justifyContent: 'flex-end' }}><input className="input input-sm num" style={{ width: 70 }} disabled={ro} inputMode="decimal" value={v.pct} onChange={(e) => setF({ ...f, [l.cell]: { ...v, pct: e.target.value } })} /><span className="faint" style={{ fontSize: 12 }}>% business</span></span>
                : <span className="faint right m-end" style={{ fontSize: 12 }}>all business</span>}
            </div>
          );
        })}
      </div>
      {!ro && <div className="row" style={{ gap: 8 }}><button className="btn btn-primary" disabled={busy} onClick={save} data-testid="pit-mixed-save">{busy ? 'Saving…' : reviewed ? 'Save' : 'Confirm'}</button>
        {!reviewed && <span className="faint" style={{ fontSize: 12 }}>Confirm even when none is private: the return cannot be approved until you do.</span>}</div>}
      {reviewed && <div className="faint" style={{ fontSize: 12 }}>Confirmed{d.row.settings.mixed_use_by ? ` by ${d.row.settings.mixed_use_by}` : ''}{d.row.settings.mixed_use_at ? ` (${when(d.row.settings.mixed_use_at)})` : ''}.</div>}
    </div>
  );
}

// ---------------------------------------------------------------- capital allowances
function Allowances({ d, year, firstYear }: { d: any; year: number; firstYear: number }) {
  const comp = d.computation || {};
  const ca = comp.business?.ca || {};
  const legacy = comp.regime === 'PITA';
  const people: any[] = comp.people || [];
  const [asset, setAsset] = useState<any>(null);
  const [taxAsset, setTaxAsset] = useState<any>(null);
  const canEdit = !!d.cit?.can_edit;
  return (
    <div className="stack" style={{ gap: 12 }}>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(150px,1fr))', gap: 8 }}>
        <Stat label="Allowances for the year" value={N2(comp.business?.figures?.ca_year)} />
        <Stat label="Tax value carried forward" value={N2(ca.totals?.twdv_cf)} />
        {Number(comp.business?.figures?.balancing_charge) > 0 && <Stat label="Balancing charges" value={N2(comp.business.figures.balancing_charge)} />}
      </div>
      {(ca.missing || []).length > 0 && <Alert kind="amber" icon="alert">No category yet for {(ca.missing as string[]).join(', ')}. Choose one below so they get their allowance.</Alert>}
      {comp.kind === 'partnership' && people.length > 0 && (
        <div className="card" style={{ overflow: 'auto' }}>
          <div className="card-hd"><b>Shared in the profit-sharing ratio</b></div>
          <div className="tr head shade th rsp" style={{ gridTemplateColumns: 'minmax(160px,1.4fr) repeat(4,110px)', minWidth: 620 }}>
            <span>Partner</span><span className="right">Share</span><span className="right">Brought forward</span><span className="right">Used</span><span className="right">Carried forward</span>
          </div>
          {people.map((p) => {
            const f = p.computation?.figures || {};
            return (
              <div key={p.person_id} className="tr rsp" style={{ gridTemplateColumns: 'minmax(160px,1.4fr) repeat(4,110px)', minWidth: 620, fontSize: 13 }}>
                <span className="m-main">{p.name} <span className="faint">· {Number(p.share_pct)}%</span></span>
                {p.hidden ? <span className="faint right" style={{ gridColumn: '2 / -1' }}>Seen by them and whoever files tax</span> : <>
                  <span className="right num" data-label="Share">{N2(f.ca_share)}</span><span className="right num" data-label="Brought forward">{N2(f.ca_bf)}</span>
                  <span className="right num" data-label="Used">{N2(f.capital_allowances)}</span><span className="right num" data-label="Carried forward">{N2(p.computation?.cf?.ca)}</span></>}
              </div>
            );
          })}
        </div>
      )}
      <div className="card" style={{ overflow: 'auto' }}>
        <div className="card-hd row" style={{ justifyContent: 'space-between' }}><b>Asset by asset</b>
          {canEdit && <button className="btn btn-secondary btn-sm" onClick={() => setTaxAsset({})}><Icon name="plus" size={13} />Asset kept for tax only</button>}</div>
        {!(ca.assets || []).length ? <div style={{ padding: 16 }}><Empty>No assets in the register or kept for tax.</Empty></div> : (ca.assets as any[]).map((a) => (
          <div key={a.key} className={'tr rsp' + (canEdit ? ' click' : '')} onClick={() => canEdit && (a.kind === 'register' ? setAsset(a) : setTaxAsset((d.cit?.tax_assets || []).find((t: any) => t.id === a.asset_id) || { id: a.asset_id }))}
            style={{ gridTemplateColumns: 'minmax(200px,1.6fr) minmax(150px,1fr) 110px 110px 110px', minWidth: 720, fontSize: 13, alignItems: 'start' }}>
            <span className="m-main" style={{ minWidth: 0 }}><b>{a.number ? `${a.number} ` : ''}{a.name}</b>
              <span className="faint" style={{ display: 'block', fontSize: 11 }}>{a.kind === 'register' ? 'Fixed asset register' : 'Kept for tax only'} · in use {fmtDay(a.in_use)}{a.disposed ? ' · disposed this year' : ''}{a.use_pct != null && Number(a.use_pct) < 100 ? ` · ${a.use_pct}% business use` : ''}</span>
              {!a.qualifies && a.reason && <span style={{ display: 'block', fontSize: 11, color: '#B45309' }}>{a.reason}</span>}</span>
            <span className="muted m-line" style={{ minWidth: 0 }}>{a.category || <span style={{ color: '#B45309' }}>Choose a category</span>}</span>
            <span className="right num" data-label="Cost">{N2(a.qce)}</span>
            <span className="right num" data-label="Allowance">{N2(Number(a.allowance || 0))}</span>
            <span className="right num" data-label="Carried forward">{N2(a.twdv_cf)}</span>
          </div>
        ))}
      </div>
      <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>
        Columns: cost, allowance for {year}, tax value carried forward. {legacy ? 'Old law: initial and annual allowances, with ₦10 kept on each asset until it is sold; no investment allowance and no two-thirds limit for individuals.'
          : 'Annual allowances on cost at the First Schedule rates, with 1% of cost kept until the asset is sold.'} An asset used partly in private life gets the business share of its allowance.
      </div>
      {asset && <PitAssetModal d={d} year={year} firstYear={firstYear} a={asset} onClose={() => setAsset(null)} />}
      {taxAsset && <TaxAssetModal t={taxAsset} onClose={() => setTaxAsset(null)} />}
    </div>
  );
}

function PitAssetModal({ d, year, firstYear, a, onClose }: { d: any; year: number; firstYear: number; a: any; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const [f, setF] = useState({ tax_category: a.category || '', tax_use_pct: String(a.use_pct ?? 100), tax_qualifies: !(a.qualifies === false && a.reason === 'Marked as not qualifying'), opening: '' });
  const [busy, setBusy] = useState(false);
  async function save() {
    setBusy(true);
    try {
      await rpc('set_asset_tax', { p_asset: a.asset_id, p: { tax_category: f.tax_category || null, tax_use_pct: money(f.tax_use_pct) ?? 100, tax_qualifies: f.tax_qualifies } });
      if (year === firstYear && f.opening.trim() !== '') {
        const cy = await rpc<any>('cit_year', { p_org: orgId, p_year: firstYear });
        const open = { ...(cy?.row?.settings?.opening_twdv || {}), [a.key]: money(f.opening) };
        await rpc('save_cit_year', { p_org: orgId, p_year: firstYear, p: { settings: { opening_twdv: open } } });
      }
      toast('Saved'); await refresh(); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={500}>
      <ModalHead title={`${a.number || ''} ${a.name}`.trim()} sub="How tax treats this asset" onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 12 }}>
        <Field label="Category"><select className="input" value={f.tax_category} onChange={(e) => setF({ ...f, tax_category: e.target.value })}>
          <option value="">Choose</option>{CA_CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}</select></Field>
        <Field label="Share used for the business (%)" hint="A car or a solar system also used at home: usually 50%."><input className="input num" inputMode="decimal" value={f.tax_use_pct} onChange={(e) => setF({ ...f, tax_use_pct: e.target.value })} /></Field>
        <label className="check"><input type="checkbox" checked={f.tax_qualifies} onChange={(e) => setF({ ...f, tax_qualifies: e.target.checked })} />Qualifies for capital allowances</label>
        {year === firstYear && <Field label={`Tax value at the start of ${year} (optional)`} hint="From the last return filed before Counta. Left empty, Counta works it out from the cost and the years in use.">
          <input className="input num" inputMode="decimal" value={f.opening} onChange={(e) => setF({ ...f, opening: e.target.value })} /></Field>}
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy || !d.cit?.can_edit} onClick={save}>Save</button></div>
    </Modal>
  );
}

// ---------------------------------------------------------------- the statement of accounts, and where the figures come from
function Accounts({ d, year }: { d: any; year: number }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const file = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [result, setResult] = useState<any>(null);
  const row = d.row || {};
  const draft = row.status === 'draft';
  const canEdit = !!d.can?.edit_business;
  const soaName = row.soa_path ? String(row.soa_path).split('/').pop()!.replace(/^\d+-/, '') : null;
  const source = d.cit?.row?.source;
  async function put(blob: Blob, name: string, ok: string) {
    const path = `${orgId}/tax/pit/${year}/soa/${Date.now()}-${name.replace(/[^\w.-]+/g, '_').slice(-80)}`;
    const { error } = await supabase.storage.from('documents').upload(path, blob, { contentType: 'application/pdf', upsert: false });
    if (error) throw new Error(error.message.includes('row-level') ? 'Your role cannot attach tax documents.' : error.message);
    await rpc('save_pit_year', { p_org: orgId, p_year: year, p: { soa_path: path } });
    toast(ok); await refresh();
  }
  async function upload(f: File) {
    if (!/\.pdf$/i.test(f.name) && f.type !== 'application/pdf') { toast('Attach the statement as a PDF.', 'err'); return; }
    if (f.size > 25_000_000) { toast('The file is larger than 25 MB.', 'err'); return; }
    setBusy('upload');
    try { await put(f, f.name, 'Statement of accounts attached'); } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }
  async function fromCounta() {
    setBusy('counta');
    try {
      const pack = await rpc<any>('financial_statements_pack', { p_org: orgId, p_from: d.period.from, p_to: d.period.to });
      const { buildPack } = await import('../../../lib/fsPack');
      const mod = await import('../../../lib/fsExport');
      const blob = await mod.packPdf(buildPack(pack));
      await put(blob, `${safeName(`${inv?.org.name || 'Business'} statement of accounts ${year}`)}.pdf`, 'Counta\'s statements attached');
    } catch (e) { toast((e as Error).message || 'Could not make the statements.', 'err'); }
    setBusy(null);
  }
  async function read(body: Record<string, unknown>) {
    setBusy('read'); setResult(null);
    try {
      const r = await ai<any>('cit_map', { org_id: orgId, year, ...body });
      if (r.ok === false) throw new Error(r.reason === 'not_configured' ? 'The AI reader is not set up yet.' : r.error || 'Could not read it.');
      setResult(r); toast(`${r.placed} figures read`); await refresh();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }
  async function setSource(s: 'books' | 'imported') {
    setBusy('source');
    try { await rpc('save_cit_year', { p_org: orgId, p_year: year, p: { source: s } }); toast(s === 'books' ? 'Figures from the books' : 'Figures from the accounts read in'); await refresh(); }
    catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }
  return (
    <div className="stack" style={{ gap: 12 }}>
      <div className="card card-pad stack" style={{ gap: 10 }} data-testid="pit-soa">
        <b>Statement of accounts</b>
        <div className="muted" style={{ fontSize: 13 }}>The state asks for the business's accounts with each return: audited financial statements, or a statement of accounts the taxpayer attests (NTAA 2025 s.13(2)(d)). Approving the year is that attestation.</div>
        {row.soa_path ? (
          <div className="row wrap" style={{ gap: 8 }}>
            <span className="row" style={{ gap: 6, fontSize: 14 }}><Icon name="file" size={15} />{soaName}</span>
            <button className="btn btn-ghost btn-xs" onClick={() => openInTab(() => signedDoc(row.soa_path))}><Icon name="eye" size={13} />Open</button>
            {canEdit && draft && <button className="btn btn-ghost btn-xs" disabled={!!busy} onClick={() => file.current?.click()}>Replace</button>}
            {canEdit && draft && <button className="btn btn-ghost btn-xs" disabled={!!busy} onClick={async () => { setBusy('rm'); try { await rpc('save_pit_year', { p_org: orgId, p_year: year, p: { soa_path: null } }); await refresh(); } catch (e) { toast((e as Error).message, 'err'); } setBusy(null); }}>Remove</button>}
          </div>
        ) : canEdit && draft ? (
          <div className="row wrap" style={{ gap: 8 }}>
            <button className="btn btn-primary btn-sm" disabled={!!busy || source === 'imported'} onClick={fromCounta} title={source === 'imported' ? 'The figures for this year come from accounts read in' : undefined}>
              {busy === 'counta' ? <Spinner small /> : <Icon name="book" size={14} color="#fff" />}Use Counta's financial statements</button>
            <button className="btn btn-secondary btn-sm" disabled={!!busy} onClick={() => file.current?.click()}>{busy === 'upload' ? <Spinner small /> : <Icon name="paperclip" size={14} />}Attach a PDF</button>
          </div>
        ) : <div className="faint" style={{ fontSize: 13 }}>Not attached yet.</div>}
        <input ref={file} type="file" accept="application/pdf,.pdf" hidden onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) upload(f); }} />
      </div>

      {d.cit && (
        <div className="card card-pad stack" style={{ gap: 10 }}>
          <div className="row wrap" style={{ justifyContent: 'space-between' }}>
            <b>Where the figures come from</b>
            {d.cit.can_edit && <div className="seg" role="tablist">
              <button className={source === 'books' ? 'on' : ''} disabled={!!busy} onClick={() => source !== 'books' && setSource('books')}>Counta's books</button>
              <button className={source === 'imported' ? 'on' : ''} disabled={!!busy} onClick={() => source !== 'imported' && setSource('imported')}>Accounts read in</button>
            </div>}
          </div>
          <div className="muted" style={{ fontSize: 13 }}>{source === 'books' ? `From the ledger for ${year}. Use accounts read in for a year the books do not fully cover.` : 'From accounts or a trial balance read in below, or entered under Figures. Check each line marked "check".'}</div>
          {d.cit.can_edit && (
            <div className="stack" style={{ gap: 10 }}>
              <div className="row wrap">
                <button className="btn btn-secondary btn-sm" disabled={!!busy || !row.soa_path} onClick={() => read({ kind: 'afs', file_path: row.soa_path })}>
                  {busy === 'read' ? <Spinner small /> : <Icon name="sparkles" size={14} />}Read the figures from the attached accounts</button>
                {!row.soa_path && <span className="faint" style={{ fontSize: 12 }}>Attach the accounts first.</span>}
              </div>
              <div className="label">Or a trial balance at the year end (Excel or CSV)</div>
              <SheetRows fields={TB_FIELDS} need={[['debit', 'credit'], ['balance']]} action={(n) => `Read ${n} accounts with AI`}
                onRows={async (rows) => { await read({ kind: 'trial_balance', rows: tbRows(rows) }); }} />
              {result && <Alert kind={(result.checks || []).length ? 'amber' : 'green'} icon={(result.checks || []).length ? 'alert' : 'check'}>
                {result.placed} figures read{result.low_confidence ? `, ${result.low_confidence} to check` : ''}.{(result.checks || []).map((c: any) => ' ' + c.text).join('')}</Alert>}
            </div>
          )}
        </div>
      )}
      <div className="faint" style={{ fontSize: 12 }}>Counta does not post personal income tax as a cost of the business. When the business pays a partner's tax for them, it is that partner's drawing.</div>
    </div>
  );
}
