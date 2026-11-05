// Personal income tax for a business name, a sole proprietor or a partnership, year by year from 2025 accounts. The
// business's assessable profit comes from the same figures and adjustments as companies income tax (Figures and
// Adjustments are the same screens); the PIT rule book then adds back the private share of mixed-use costs, donations and
// research above 5% of turnover. Each person (the proprietor, or each partner) has a return of their own for the state that
// taxes them: Counta's own bot files Lagos returns on LIRS e-Tax with each person's own login (bots/lirs), TaxStreem Flux
// files those for the other states it covers, and the business marks the rest filed. An NGO sees why it is exempt, and the
// owner can say it trades.
import { useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useInventory, useSession, useToast } from '../../../state/session';
import { ai, rpc, signedDoc, supabase } from '../../../lib/supabase';
import { edge, money } from '../../../lib/api';
import { N2, fmtDay, fmtTime, when } from '../../../lib/format';
import { CA_CATEGORIES, HOME_TYPES, OCCUPANCY, OTHER_INCOME, PIT_STATE, RELIEFS, STAFF_ROLES, incomeChoice, incomeOf, pitLaw, usePitYear, usePitYears } from '../../../lib/tax';
import { buildPitPack } from '../../../lib/pitPack';
import { downloadBlob, safeName } from '../../../lib/exporters';
import { TB_FIELDS, tbRows } from '../../../lib/moveBooks';
import { Icon } from '../../../components/Icon';
import { Alert, Drawer, Empty, Field, MenuButton, Modal, ModalHead, Pills, SkeletonRows, Spinner, Stat } from '../../../components/ui';
import { SheetRows } from '../../../components/SheetRows';
import { Adjustments, Figures, TaxAssetModal, amt, openInTab, useTaxRefresh } from './CitTab';

type Sub = 'computation' | 'people' | 'staff' | 'figures' | 'adjustments' | 'mixed' | 'allowances' | 'accounts';
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
  const [tcc, setTcc] = useState<any>(null);
  const [pay, setPay] = useState<string | null>(null);
  const [loginFor, setLoginFor] = useState<string | null>(null);
  const d = q.data;
  const live = (d?.computation?.people || []) as any[];
  const bots: string[] = d?.bot_authorities || [];
  // While Counta's bot is at work on e-Tax, the year looks again every few seconds.
  const working = live.some((p) => (p.bot || bots.includes(p.authority)) && (p.status === 'sent' || !!p.etax_login?.checking
    || ['queued', 'running'].includes(p.jobs?.bill?.status) || ['queued', 'running'].includes(p.jobs?.pay_account?.status)));
  useEffect(() => {
    if (!working) return;
    const t = setInterval(() => { void refresh(); }, 8000);
    return () => clearInterval(t);
  }, [working]); // eslint-disable-line react-hooks/exhaustive-deps
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
  const isBot = (p: any) => !!p.bot || bots.includes(p.authority);
  const fluxPeople = people.filter((p) => (p.flux || isBot(p)) && ['approved', 'rejected'].includes(p.status));
  const botPeople = fluxPeople.filter(isBot), viaFlux = fluxPeople.filter((p) => !isBot(p));
  const logins: any[] = d.logins || [];
  const noLogin = Array.from(new Set(viaFlux.filter((p) => !logins.some((l) => l.authority === p.authority)).map((p) => p.authority_short || p.authority_name || p.authority)));
  const noEtax = botPeople.filter((p) => 'etax_login' in p && (!p.etax_login || p.etax_login.status === 'failed')).map((p) => p.name);


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
  // Each return Flux files carries the person's own computation as a PDF (the portal's tax calculation), made once from
  // the approved figures and kept with the return.
  async function computations() {
    const mod = await import('../../../lib/fsExport');
    for (const p of fluxPeople.filter((x) => !x.computation_path)) {
      const blob = await mod.packPdf(buildPitPack(d, inv?.org.name || '', { personId: p.person_id }));
      const path = `${orgId}/tax/pit/${year}/computation/${Date.now()}-${String(p.name).replace(/[^\w.-]+/g, '_').slice(-60)}.pdf`;
      const { error } = await supabase.storage.from('documents').upload(path, blob, { contentType: 'application/pdf', upsert: false });
      if (error) throw new Error(error.message.includes('row-level') ? 'Only whoever files the business\'s tax sends the returns.' : error.message);
      await rpc('save_pit_computation_file', { p_org: orgId, p_year: year, p_person: p.person_id, p_path: path });
    }
  }
  async function send() {
    setBusy('send'); setSendOut(null);
    try {
      await computations();
      const r = await edge<any>('tax-files', { action: 'pit_send', org_id: orgId, year });
      setSendOut(r);
      if (r.ok) {
        const viaBot = Number(r.bot || 0), toFlux = Number(r.sent) - viaBot;
        toast([viaBot ? `Counta's bot is filing ${viaBot} return${viaBot === 1 ? '' : 's'} on e-Tax` : '', toFlux ? `Sent ${toFlux} to TaxStreem Flux` : ''].filter(Boolean).join('. '));
        if (viaBot && r.woke === false) toast('Counta\'s bot is not set up yet, so the return waits until it is. Ask TaxStreem.', 'err');
        if (!r.failed) setModal(null);
      }
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
              <button className="btn btn-primary btn-sm" disabled={!!busy} onClick={() => { setSendOut(null); setModal('send'); }} data-testid="pit-send">
                <Icon name="send" size={14} color="#fff" />{viaFlux.length ? 'Send to Flux' : 'File on e-Tax'}</button>)}
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
        {d.row?.status === 'approved' && <FilingList people={people} bots={bots} canMark={!!can.approve} canPay={!!can.see_all} onMark={setFiling} onTcc={setTcc} onPay={(p) => setPay(p.person_id)} onLogin={(p) => setLoginFor(p.person_id)}
          onPaid={(p) => act(`paid-${p.person_id}`, () => rpc('pit_pay_tapped', { p_org: orgId, p_year: year, p_person: p.person_id }), `Counta will confirm ${p.name}'s payment with LIRS`)}
          onAgain={(p, kind) => act(`again-${p.person_id}`, async () => {
            const r = await edge<any>('tax-files', kind === 'file' ? { action: 'pit_send', org_id: orgId, year, person_id: p.person_id } : { action: 'pit_bill', org_id: orgId, year, person_id: p.person_id });
            if (!r.ok) throw new Error(r.error || 'That did not work.');
          }, kind === 'file' ? `Counta's bot is filing ${p.name}'s return again` : `Counta's bot is raising ${p.name}'s bill again`)} />}
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
        { id: 'staff', label: 'Staff' }, { id: 'figures', label: 'Figures' }, { id: 'adjustments', label: 'Adjustments' }, { id: 'mixed', label: 'Mixed use' }, { id: 'allowances', label: 'Capital allowances' },
        { id: 'accounts', label: 'Statement of accounts' }]} />
      {sub === 'computation' && <Computation d={d} />}
      {sub === 'people' && <People d={d} year={year} firstYear={firstYear} />}
      {sub === 'staff' && <Staff d={d} year={year} />}
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
          <ModalHead title={viaFlux.length ? 'Send to TaxStreem Flux' : 'File on LIRS e-Tax'} sub={`${year} accounts · year of assessment ${comp.yoa}`} onClose={() => setModal(null)} />
          <div className="modal-body stack" style={{ gap: 10, fontSize: 14 }}>
            {botPeople.length > 0 && <div data-testid="pit-send-bot">Counta's bot signs in to LIRS e-Tax as each person, with their own login, and files their return as they would: their statement
              of income, home, household staff and reliefs with their documents, the statement of accounts and their computation (made now as a PDF){comp.kind === 'sole' ? ' and the business\'s fixed assets' : ''}.
              It then confirms the return and raises the bill to pay:</div>}
            {botPeople.length > 0 && <div className="stack" style={{ gap: 4, fontSize: 13 }}>
              {botPeople.map((p) => <span key={p.person_id}><Icon name="check" size={13} color="#15803D" /> {p.name} · {p.etax_login?.payer_id || 'no e-Tax login yet'} · {N2(p.computation?.figures?.payable)}</span>)}
            </div>}
            {botPeople.length > 0 && <div className="faint" style={{ fontSize: 12 }}>Confirming is the declaration on e-Tax that the return is true and complete; a false return is an offence. A confirmed return can only be reopened by LIRS.</div>}
            {viaFlux.length > 0 && <div>Flux signs in to the state portal as the business and files these returns, each with the person's computation (made now as a PDF), their statement of income,
              home and reliefs with their documents, the business's figures{comp.kind === 'partnership' ? ', the partners and their shares' : ''}, staff and fixed assets, and the statement of accounts:</div>}
            {viaFlux.length > 0 && <div className="stack" style={{ gap: 4, fontSize: 13 }}>
              {viaFlux.map((p) => <span key={p.person_id}><Icon name="check" size={13} color="#15803D" /> {p.name} · {p.authority_name || p.authority} · {N2(p.computation?.figures?.payable)}</span>)}
            </div>}
            {noEtax.length > 0 && <Alert kind="amber" icon="lock"><span data-testid="pit-no-etax">Add the e-Tax login of {noEtax.join(' and ')} first (Add e-Tax login, beside {noEtax.length === 1 ? 'the return' : 'each return'}), so Counta's bot can sign in as them.</span></Alert>}
            {people.filter((p) => !p.flux).length > 0 && <div className="faint" style={{ fontSize: 12 }}>Flux does not file in {Array.from(new Set(people.filter((p) => !p.flux).map((p) => p.authority_state || p.authority_short || p.authority))).join(', ')} yet. Download the computation, file those returns with the state and mark them filed here.</div>}
            {noLogin.length > 0 && <Alert kind="amber" icon="lock"><span data-testid="pit-no-login">Save the business's {noLogin.join(' and ')} login under <a href="/settings#tax-logins">Settings, Tax portal logins</a> first, so Flux can sign in.</span></Alert>}
            {sendOut && !sendOut.ok && <Alert kind={sendOut.reason === 'not_configured' ? 'blue' : 'red'} icon="info">{sendOut.error}</Alert>}
            {sendOut?.failed > 0 && sendOut.ok && <Alert kind="amber" icon="info">{(sendOut.results || []).filter((r: any) => !r.ok).map((r: any) => `${r.name}: ${r.error}`).join(' ')}</Alert>}
          </div>
          <div className="modal-ft"><button className="btn btn-secondary" onClick={() => setModal(null)}>Close</button>
            <button className="btn btn-primary" disabled={!!busy || noLogin.length > 0 || noEtax.length > 0} onClick={send} data-testid="pit-send-go">{busy === 'send' ? 'Sending…' : viaFlux.length ? 'Send' : 'File'}</button></div>
        </Modal>
      )}
      {filing && <MarkFiled year={year} person={filing} onClose={() => setFiling(null)} />}
      {tcc && <TccModal d={d} year={year} person={people.find((p) => p.person_id === tcc.person_id) || tcc} onClose={() => setTcc(null)} />}
      {loginFor && <LoginModal d={d} year={year} personId={loginFor} onClose={() => setLoginFor(null)} />}
      {pay && people.find((p) => p.person_id === pay) && <PayModal year={year} person={people.find((p) => p.person_id === pay)} onClose={() => setPay(null)} />}
    </div>
  );
}

// Each person's return once the year is approved: with Flux, filed, sent back, or to file; then the bill Flux generated
// on the portal, the payment, and the tax clearance certificate.
const TCC_LABEL: Record<string, { label: string; tone: string }> = {
  requested: { label: 'Certificate requested', tone: 't-amber' }, processing: { label: 'Certificate in progress', tone: 't-amber' },
  issued: { label: 'Certificate issued', tone: 't-green' }, rejected: { label: 'Certificate refused', tone: 't-red' },
};
const STEP_LABEL: Record<string, string> = {
  signed_in: 'Signed in', signed_in_again: 'Signed in again', documents: 'Documents attached', statement_of_income: 'Statement of income in', accommodation: 'Home in',
  support_staff: 'Household staff in', assets: 'Assets in', reliefs: 'Reliefs in', confirmed: 'Confirmed', bill: 'Bill raised', payment_page: 'On the payments page',
  transfer_account: 'Account ready', checked: 'Checked for the payment',
};
function FilingList({ people, bots, canMark, canPay, onMark, onTcc, onPay, onPaid, onAgain, onLogin }: { people: any[]; bots: string[]; canMark: boolean; canPay: boolean; onMark: (p: any) => void;
  onTcc: (p: any) => void; onPay: (p: any) => void; onPaid: (p: any) => void; onAgain: (p: any, kind: 'file' | 'bill') => void; onLogin: (p: any) => void }) {
  return (
    <div className="stack" style={{ gap: 8 }} data-testid="pit-filing">
      {people.map((p) => {
        const bot = !!p.bot || bots.includes(p.authority);
        const jobs = p.jobs || {};
        const fileJob = jobs.file;
        const step = fileJob?.step ? STEP_LABEL[fileJob.step] || fileJob.step : null;
        const s = p.status === 'filed' ? { tone: 't-green', text: `Filed${p.filed_at ? ' ' + fmtDay(String(p.filed_at).slice(0, 10)) : ''}${p.acknowledgement_ref ? ` · ${bot ? 'return ' : ''}${p.acknowledgement_ref}` : ''}${p.filed_by_business ? ' (by the business)' : ''}${bot && !p.filed_by_business ? ' on e-Tax' : ''}` }
          : p.status === 'sent' && bot ? { tone: 't-amber', text: p.flux_status === 'processing' ? `Counta's bot is filing it on e-Tax${step ? ` · ${step}` : ''}` : 'Waiting for Counta\'s bot' }
          : p.status === 'sent' ? { tone: 't-amber', text: `With Flux${p.flux_ref ? ` (${p.flux_ref})` : ''}${p.flux_message ? ` · ${p.flux_message}` : ''}` }
          : p.status === 'rejected' ? { tone: 't-red', text: `Sent back${p.flux_message ? `: ${p.flux_message}` : ''}` }
          : p.flux_status === 'send_failed' ? { tone: 't-red', text: `Not ${bot ? 'filed' : 'sent'}: ${p.flux_message || (bot ? 'e-Tax did not take it' : 'Flux did not take it')}` }
          : { tone: 't-grey', text: bot ? 'Ready to file on e-Tax' : p.flux ? 'Ready for Flux' : 'To file with the state' };
        const bill = p.bill;
        const payUrl = !p.paid_at && !bot ? bill?.payment_url || p.payment_url : null;
        const t = p.tcc || {};
        const tl = t.status ? TCC_LABEL[t.status] : null;
        const billJob = jobs.bill;
        const billFailed = bot && p.status === 'filed' && !bill && billJob?.status === 'failed';
        const billWaiting = bot && p.status === 'filed' && !bill && ['queued', 'running'].includes(billJob?.status);
        // Counta checks the Lagos State payments page only once money has gone out (the wallet, a bank line, or I've paid).
        const pc = jobs.pay_checks || null;
        const checking = bot && !p.paid_at && !!pc?.active;
        const notShowing = bot && !p.paid_at && !!pc && !pc.active && !!pc.ended_at;
        return (
          <div key={p.person_id} className="stack" style={{ gap: 4 }} data-testid="pit-filing-row" data-person={p.name}>
            <div className="row wrap" style={{ justifyContent: 'space-between', gap: 8, fontSize: 13 }}>
              <span style={{ minWidth: 0 }}><b>{p.name}</b> <span className="faint">· {p.authority_name || p.authority}</span></span>
              <span className="row wrap" style={{ gap: 6 }}>
                <span className={'chip ' + s.tone} data-testid="pit-filing-state">{s.text}</span>
                {payUrl && <a className="btn btn-ghost btn-xs" href={payUrl} target="_blank" rel="noopener noreferrer"><Icon name="card" size={12} />Pay{bill?.amount != null ? ` ${N2(bill.amount)}` : ''}</a>}
                {bot && bill && !p.paid_at && canPay && <button className="btn btn-primary btn-xs" onClick={() => onPay(p)} data-testid="pit-pay"><Icon name="card" size={12} color="#fff" />Pay {N2(bill.amount)}</button>}
                {bot && bill && !p.paid_at && canPay && !checking && <button className="btn btn-ghost btn-xs" onClick={() => onPaid(p)} data-testid="pit-paid"
                  title="Paid from outside Counta? Counta then confirms it with LIRS."><Icon name="check" size={12} />I've paid</button>}
                {bot && 'etax_login' in p && p.status !== 'filed' && <button className="btn btn-ghost btn-xs" onClick={() => onLogin(p)} data-testid="pit-login-open">
                  <Icon name="lock" size={12} />{p.etax_login ? 'e-Tax login' : 'Add e-Tax login'}</button>}
                {canMark && bot && p.flux_status === 'send_failed' && p.status === 'approved' && <button className="btn btn-ghost btn-xs" onClick={() => onAgain(p, 'file')}>Try again</button>}
                {canMark && billFailed && <button className="btn btn-ghost btn-xs" onClick={() => onAgain(p, 'bill')}>Raise the bill again</button>}
                {canMark && ['approved', 'rejected'].includes(p.status) && <button className="btn btn-ghost btn-xs" onClick={() => onMark(p)}>Mark filed</button>}
                {canMark && p.status === 'filed' && !['requested', 'processing', 'issued'].includes(t.status) && <button className="btn btn-ghost btn-xs" onClick={() => onTcc(p)}><Icon name="shield" size={12} />Tax clearance</button>}
              </span>
            </div>
            {bot && p.etax_login?.status === 'failed' && <div style={{ fontSize: 12, color: '#B91C1C', textAlign: 'right' }}>e-Tax did not accept {p.name}'s login{p.etax_login.message ? `: ${p.etax_login.message}` : ''}. Save it again with e-Tax login.</div>}
            {(billFailed || billWaiting) && <div className="faint" style={{ fontSize: 12, textAlign: 'right' }} data-testid="pit-bill-state">{billWaiting ? 'Counta\'s bot is raising the bill on e-Tax.' : `The bill was not raised: ${billJob?.error || 'e-Tax did not take it'}.`}</div>}
            {(bill || p.paid_at || tl) && (
              <div className="row wrap faint" style={{ gap: 8, fontSize: 12, justifyContent: 'flex-end' }} data-testid="pit-after-filing">
                {bill && <span>Bill {bill.reference || ''} for {N2(bill.amount)}{bill.agency ? ` · ${bill.agency}` : ''}{bill.expires_at && !p.paid_at ? ` · pay by ${fmtDay(String(bill.expires_at).slice(0, 10))}` : ''}</span>}
                {p.paid_at && <span className="chip t-green">Paid {fmtDay(String(p.paid_at).slice(0, 10))}{p.payment_ref ? ` · ${p.payment_ref}` : ''}</span>}
                {checking && <span className="chip t-amber" data-testid="pit-checking-chip">Confirming with LIRS{pc.next_at ? ` · next check ${fmtTime(pc.next_at)}` : ''}</span>}
                {notShowing && <span className="chip t-red" data-testid="pit-not-showing">Not showing as paid on LIRS</span>}
                {tl && <span className={'chip ' + tl.tone}>{tl.label}{t.number ? ` ${t.number}` : ''}{t.expires_on ? `, valid to ${fmtDay(t.expires_on)}` : ''}{t.status === 'rejected' && t.message ? `: ${t.message}` : ''}</span>}
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

// Paying a person's e-Tax bill. By transfer for now: Counta's bot opens the bill on e-Tax's Flutterwave channel (the Lagos State
// payments page), chooses bank transfer and brings back the one-time account for the exact amount. The account works for 15
// minutes, so the bot fetches it only when the person says they are ready, and the screen counts the time down; once it has
// expired the number is hidden. Counta checks the payments page only once money has gone out: a payment from the Counta
// wallet, the bank line in the books, or the person tapping I've paid (up to two hours after the account expired).
const mmss = (ms: number) => `${Math.floor(ms / 60_000)}:${String(Math.floor(ms / 1000) % 60).padStart(2, '0')}`;
function PayModal({ year, person, onClose }: { year: number; person: any; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const [method, setMethod] = useState<'transfer' | 'tax_wallet' | 'business'>('transfer');
  const [asked, setAsked] = useState<{ at: number; fetched: number; job: string | null } | null>(null);
  const [busy, setBusy] = useState(false);
  const [now, setNow] = useState(Date.now());
  const bill = person.bill || {};
  const tr = bill.transfer || null;
  const job = person.jobs?.pay_account || null;
  const pc = person.jobs?.pay_checks || null;
  const checking = !person.paid_at && !!pc?.active;
  const fetched = tr?.fetched_at ? Date.parse(tr.fetched_at) : 0;
  // Flutterwave's time, or 15 minutes after the bot fetched it.
  const expires = tr ? (tr.expires_at ? Date.parse(tr.expires_at) : fetched + 15 * 60_000) : 0;
  const left = Math.max(0, expires - now);
  const live = !!tr && left > 0;
  const lately = !!tr && now - expires < 2 * 3600_000;
  // Waiting for the account asked for: a newer one arrives, or that job fails, or three minutes pass.
  const got = !!asked && fetched > asked.fetched;
  const jobFailed = !!asked && !!job && job.id === asked.job && job.status === 'failed';
  const waiting = !!asked && !got && !jobFailed && Date.now() - asked.at < 180_000;
  const failed = !asked || got ? null : jobFailed ? job.error || 'The bot could not get the account.' : !waiting ? 'The account did not come back in time. Try again in a minute.' : null;
  useEffect(() => {
    if (!waiting) return;
    const t = setInterval(() => { void refresh(); }, 3000);
    return () => clearInterval(t);
  }, [waiting]); // eslint-disable-line react-hooks/exhaustive-deps
  // The countdown, while the account works.
  useEffect(() => {
    setNow(Date.now());
    if (!tr) return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [tr?.fetched_at]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { if (person.paid_at) { toast(`${person.name}'s ${year} income tax is paid`); onClose(); } }, [person.paid_at]); // eslint-disable-line react-hooks/exhaustive-deps
  async function ask() {
    setBusy(true);
    try {
      const r = await edge<any>('tax-files', { action: 'pit_pay', org_id: orgId, year, person_id: person.person_id, pay_with: method });
      if (!r.ok) throw new Error(r.error || 'That did not work.');
      setAsked({ at: Date.now(), fetched, job: r.job?.id ?? null });
      await refresh();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  async function paid() {
    setBusy(true);
    try {
      const r = await rpc<any>('pit_pay_tapped', { p_org: orgId, p_year: year, p_person: person.person_id });
      toast(r?.result === 'already' ? 'Counta is already confirming this payment with LIRS' : 'Thank you. Counta will confirm the payment with LIRS');
      await refresh();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  const copy = async (v: string) => { try { await navigator.clipboard.writeText(v); toast('Copied'); } catch { /* the number is on the screen */ } };
  const opts: { id: 'transfer' | 'tax_wallet' | 'business'; label: string; sub: string; off?: boolean }[] = [
    { id: 'transfer', label: 'Bank transfer', sub: 'A one-time account from e-Tax\'s Flutterwave channel, for the exact amount. It works for 15 minutes.' },
    { id: 'tax_wallet', label: 'Tax wallet', sub: 'Comes next.', off: true },
    { id: 'business', label: 'Business account', sub: 'Comes next.', off: true },
  ];
  // A new account only once the one on screen is about to stop working (Counta refuses one sooner).
  const canAsk = !waiting && method === 'transfer' && (!live || left <= 3 * 60_000);
  return (
    <Modal onClose={onClose} width={520}>
      <ModalHead title={`Pay ${person.name}'s ${year} income tax`} sub={`Bill ${bill.reference || ''} · ${N2(bill.amount)}${bill.agency ? ` · ${bill.agency}` : ''}`} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 12, fontSize: 14 }} data-testid="pit-pay-modal">
        {checking && <Alert kind="blue" icon="clock"><span data-testid="pit-checking">Counta is confirming the payment with LIRS{pc.next_at ? `. The next check is at ${fmtTime(pc.next_at)}` : ''}.
          The bill shows as paid here once the Lagos State payments page does, so you can close this.</span></Alert>}
        <div className="stack" style={{ gap: 6 }}>
          {opts.map((o) => (
            <label key={o.id} className="check" style={{ alignItems: 'flex-start', opacity: o.off ? 0.55 : 1 }}>
              <input type="radio" name="pay-with" disabled={o.off} checked={method === o.id} onChange={() => setMethod(o.id)} />
              <span><b style={{ fontSize: 13 }}>{o.label}</b><span className="faint" style={{ display: 'block', fontSize: 12 }}>{o.sub}</span></span>
            </label>
          ))}
        </div>
        {live && !waiting && (
          <div className="card card-pad stack" style={{ gap: 6, background: '#F5F9FF' }} data-testid="pit-transfer">
            <div className="faint" style={{ fontSize: 12 }}>Transfer exactly</div>
            <div style={{ fontSize: 22, fontWeight: 700 }} className="num">{N2(tr.amount)}</div>
            <div className="row wrap" style={{ gap: 8, alignItems: 'center' }}>
              <span style={{ fontSize: 20, fontWeight: 700, letterSpacing: 1 }} className="num" data-testid="pit-transfer-account">{tr.account_number}</span>
              <button className="btn btn-ghost btn-xs" onClick={() => copy(tr.account_number)}><Icon name="copy" size={12} />Copy</button>
            </div>
            <div style={{ fontSize: 13 }}>{tr.bank_name} · {tr.account_name}</div>
            <div style={{ fontSize: 13, fontWeight: 600, color: left <= 3 * 60_000 ? '#B91C1C' : '#1f2933' }} data-testid="pit-countdown">
              Works for another {mmss(left)} (until {fmtTime(new Date(expires).toISOString())})</div>
            <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>
              {Number(tr.fee) > 0 ? `The amount includes the payment page's ${N2(tr.fee)} processing fee. ` : ''}
              Pay it in one transfer from any bank, then tap I've paid. Counta then confirms the payment with LIRS.
            </div>
          </div>
        )}
        {tr && !live && !waiting && !checking && <Alert kind="amber" icon="clock"><span data-testid="pit-transfer-expired">This account has expired, so don't pay into it. When you're ready to pay, ask for a new one.</span></Alert>}
        {!live && !waiting && !person.paid_at && !checking && <div className="faint" style={{ fontSize: 12.5, lineHeight: 1.5 }} data-testid="pit-ready-note">
          Have your bank app open before you ask. The account works for 15 minutes from when it appears, so pay it straight away.</div>}
        {waiting && <div className="row" style={{ gap: 8, fontSize: 13 }} data-testid="pit-transfer-waiting"><Spinner small />Counta's bot is getting the account from the Lagos State payments page{job?.step ? ` (${STEP_LABEL[job.step] || job.step})` : ''}…</div>}
        {failed && <Alert kind="red" icon="info">{failed}</Alert>}
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>Close</button>
        {(live || lately) && !waiting && !checking && <button className="btn btn-secondary" disabled={busy} onClick={paid} data-testid="pit-paid-modal"><Icon name="check" size={13} />I've paid</button>}
        {/* While Counta confirms a payment, a new account is still there for anyone who tapped I've paid by mistake. */}
        {canAsk && <button className={checking ? 'btn btn-secondary' : 'btn btn-primary'} disabled={busy} onClick={ask} data-testid="pit-transfer-ask">
          {busy ? 'Asking…' : checking ? 'Get a new account' : tr ? 'I\'m ready, get a new account' : 'I\'m ready, get the account'}</button>}
      </div>
    </Modal>
  );
}

// What a tax clearance certificate needs: a profile picture of the person, the returns for the year and the two before it
// (filed through Counta, or attached), and the authority to file any return still outstanding.
function TccModal({ d, year, person, onClose }: { d: any; year: number; person: any; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const t = person.tcc || {};
  const [photo, setPhoto] = useState<{ path: string; name: string } | null>(t.photo_path ? { path: t.photo_path, name: t.photo_name || 'Profile picture' } : null);
  const [prior, setPrior] = useState<Record<string, { path: string; name: string } | null>>(() => ({ ...(t.prior_returns || {}) }));
  const [authorise, setAuthorise] = useState(!!t.authorise_outstanding);
  const [busy, setBusy] = useState<string | null>(null);
  const [out, setOut] = useState<any>(null);
  const photoIn = useRef<HTMLInputElement>(null);
  const retIn = useRef<HTMLInputElement>(null);
  const [retYear, setRetYear] = useState<string | null>(null);
  const prefix = `${orgId}/tax/pit/${year}/people/${person.person_id}/tcc/`;
  const years: any[] = t.years || [];
  const payable = Number(person.bill?.amount ?? person.computation?.figures?.payable ?? 0);
  const unpaid = payable > 0 && !person.paid_at;
  const login = (d.logins || []).some((l: any) => l.authority === person.authority);
  const missing = years.filter((y) => !y.filed_in_counta && !prior[String(y.year)]?.path && Number(y.year) !== year);
  async function upload(f: File, kind: 'photo' | 'return') {
    setBusy('up');
    try {
      if (kind === 'photo' && !/\.(jpe?g|png)$/i.test(f.name) && !/^image\/(jpeg|png)$/.test(f.type)) throw new Error('The picture is a JPEG or PNG.');
      const r = await putPersonFile(prefix, f);
      if (kind === 'photo') setPhoto(r); else if (retYear) setPrior((x) => ({ ...x, [retYear]: r }));
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }
  const payload = () => ({ photo_path: photo?.path || null, photo_name: photo?.name || null, authorise_outstanding: authorise,
    prior_returns: Object.fromEntries(years.filter((y) => Number(y.year) !== year).map((y) => [String(y.year), prior[String(y.year)] || null])) });
  async function save(apply: boolean) {
    setBusy(apply ? 'apply' : 'save'); setOut(null);
    try {
      await rpc('save_pit_tcc', { p_org: orgId, p_year: year, p_person: person.person_id, p: payload() });
      if (!apply) { toast('Saved'); await refresh(); onClose(); return; }
      const r = await edge<any>('tax-files', { action: 'pit_tcc_request', org_id: orgId, year, person_id: person.person_id });
      setOut(r); await refresh();
      if (r.ok) { toast('Flux is applying for the certificate'); onClose(); }
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }
  return (
    <Modal onClose={onClose} width={560}>
      <ModalHead title={`${person.name}'s tax clearance certificate`} sub={`${person.authority_name || person.authority} · covers ${year - 2} to ${year} accounts`} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 12, fontSize: 14 }} data-testid="pit-tcc">
        <div className="muted" style={{ fontSize: 13 }}>Flux applies on the state portal once the {year} return is filed and paid. The state asks for a profile picture, the returns for the last three years and the authority to file any return still outstanding.</div>
        <div className="row wrap" style={{ gap: 8, alignItems: 'center' }}>
          <b style={{ fontSize: 13, minWidth: 120 }}>Profile picture</b>
          {photo ? <span className="chip t-grey"><Icon name="check" size={12} color="#15803D" /> {photo.name}</span> : <span style={{ color: '#B45309', fontSize: 13 }}>Not added yet</span>}
          <button className="btn btn-ghost btn-xs" disabled={!!busy} onClick={() => photoIn.current?.click()}>{photo ? 'Replace' : 'Add a picture'}</button>
        </div>
        <div className="stack" style={{ gap: 6 }}>
          <b style={{ fontSize: 13 }}>Returns</b>
          {years.map((y) => {
            const k = String(y.year); const f = prior[k];
            return (
              <div key={k} className="row wrap" style={{ gap: 8, fontSize: 13, alignItems: 'center' }} data-tcc-year={k}>
                <span style={{ minWidth: 120 }}>{k} accounts</span>
                {y.filed_in_counta ? <span className="chip t-green">Filed through Counta{y.acknowledgement_ref ? ` · ${y.acknowledgement_ref}` : ''}</span>
                  : f?.path ? <><span className="chip t-grey"><Icon name="check" size={12} color="#15803D" /> {f.name}</span>
                      <button className="btn btn-ghost btn-xs" disabled={!!busy} onClick={() => setPrior((x) => ({ ...x, [k]: null }))}>Remove</button></>
                  : <><span style={{ color: '#B45309' }}>Attach the return filed, or the acknowledgement</span>
                      <button className="btn btn-ghost btn-xs" disabled={!!busy} onClick={() => { setRetYear(k); retIn.current?.click(); }} aria-label={`Attach the ${k} return`}>Attach</button></>}
              </div>
            );
          })}
        </div>
        <label className="check" style={{ alignItems: 'flex-start', fontSize: 13, lineHeight: 1.5 }}>
          <input type="checkbox" checked={authorise} onChange={(e) => setAuthorise(e.target.checked)} />
          <span>{person.name} authorises TaxStreem to file any return still outstanding for these years, so the certificate can be issued.</span>
        </label>
        {unpaid && <Alert kind="amber" icon="card">The bill of {N2(payable)} is not paid yet. Flux applies once the state has the payment.</Alert>}
        {!login && <Alert kind="amber" icon="lock">Save the business's {person.authority_short || person.authority_name} login under <a href="/settings#tax-logins">Settings, Tax portal logins</a> first.</Alert>}
        {out && !out.ok && <Alert kind={out.reason === 'not_configured' ? 'blue' : 'red'} icon="info">{out.error}</Alert>}
        <input ref={photoIn} type="file" accept="image/jpeg,.jpg,.jpeg,image/png,.png" hidden onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) upload(f, 'photo'); }} />
        <input ref={retIn} type="file" accept={FILE_TYPES} hidden onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) upload(f, 'return'); }} />
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Close</button>
        <button className="btn btn-ghost" disabled={!!busy} onClick={() => save(false)}>Save</button>
        <button className="btn btn-primary" disabled={!!busy || !photo || missing.length > 0 || unpaid || !login} onClick={() => save(true)} data-testid="pit-tcc-apply">
          {busy === 'apply' ? 'Asking Flux…' : 'Ask Flux to apply'}</button></div>
    </Modal>
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
                {!p.hidden && <PortalLines p={p} />}
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

// How the person's figures go on the state portal's statement of income, and any relief left out for want of documents.
const FIELD_LABEL: Record<string, string> = { salary: 'Salary', commission: 'Commission', trade_income: 'Trade income', allowance: 'Allowance', pension: 'Pension',
  annuity: 'Annuity', gratuities: 'Gratuities', foreign_income: 'Foreign income (in naira)', dividend: 'Dividend', interest: 'Interest', rent: 'Rent', other_income: 'Other income' };
function PortalLines({ p }: { p: any }) {
  const fields = p.income_fields?.fields;
  const held: any[] = p.reliefs_held || [];
  if (!fields && !held.length) return null;
  const shown = Object.keys(FIELD_LABEL).filter((k) => Number(fields?.[k] || 0) !== 0);
  return (
    <div style={{ padding: '10px 16px', borderTop: '1px solid var(--line)', fontSize: 12 }} data-testid="pit-portal-lines">
      {fields && <div className="faint" style={{ lineHeight: 1.7 }}>On the state portal's statement of income: {shown.length ? shown.map((k) => `${FIELD_LABEL[k]} ${N2(fields[k])}`).join(' · ') : 'nothing'}.</div>}
      {held.map((h) => <div key={h.relief} style={{ color: '#B45309', lineHeight: 1.6 }}>{h.label} ({N2(h.amount)}) left out until {(h.missing || []).join(', ')} {h.missing?.length === 1 ? 'is' : 'are'} added under People.</div>)}
    </div>
  );
}

// ---------------------------------------------------------------- the people
function People({ d, year, firstYear }: { d: any; year: number; firstYear: number }) {
  const comp = d.computation || {};
  const people: any[] = comp.people || [];
  const [edit, setEdit] = useState<any>(null);
  const [login, setLogin] = useState<string | null>(null);
  const can = d.can || {};
  const me = d.me;
  const bots: string[] = d.bot_authorities || [];
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
          // Once the year is approved the drawer is closed, but a person's own e-Tax login can still be saved or changed.
          const loginOnly = !click && (!!p.bot || bots.includes(p.authority)) && 'etax_login' in p;
          return (
            <div key={p.person_id} className={'tr rsp' + (click || loginOnly ? ' click' : '')} onClick={() => (click ? setEdit(p) : loginOnly ? setLogin(p.person_id) : null)} data-testid="pit-person-row"
              style={{ gridTemplateColumns: 'minmax(180px,1.4fr) 90px minmax(160px,1fr) minmax(140px,1fr)', minWidth: 640, fontSize: 13, alignItems: 'start' }}>
              <span className="m-main" style={{ minWidth: 0 }}><b>{p.name}</b>{mine && <span className="chip t-blue" style={{ marginLeft: 6 }}>You</span>}
                <span className="faint" style={{ display: 'block', fontSize: 11 }}>{ROLE_LABEL[p.role] || p.role}{p.tin ? ` · Tax ID ${p.tin}` : ' · no Tax ID yet'}</span></span>
              <span className="num" data-label="Share">{comp.kind === 'partnership' ? `${Number(p.share_pct)}%` : '100%'}</span>
              <span className="muted">{p.role === 'active' ? `Works from ${p.office?.name || 'an office'}${p.office?.state ? ` (${p.office.state})` : ''}` : p.resident === false ? 'Lives outside Nigeria' : 'Lives in ' + (p.authority_state || 'a state not chosen')}</span>
              <span className="m-line">{p.authority_name || <span style={{ color: '#B45309' }}>Choose the state</span>}
                {(p.bot || (d.bot_authorities || []).includes(p.authority)) && 'etax_login' in p && (
                  <span style={{ display: 'block', fontSize: 11, color: !p.etax_login ? '#B45309' : p.etax_login.status === 'failed' ? '#B91C1C' : undefined }} className={p.etax_login && p.etax_login.status !== 'failed' ? 'faint' : undefined} data-testid="pit-person-etax">
                    {p.etax_login ? `e-Tax ${p.etax_login.payer_id} · ${loginState(p.etax_login).label.toLowerCase()}` : 'No e-Tax login yet'}</span>)}</span>
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
      {login && <LoginModal d={d} year={year} personId={login} onClose={() => setLogin(null)} />}
    </div>
  );
}

interface Line { kind: string; label: string; amount: string; tax_deducted: string }
interface StaffLine { role: string; registered: boolean; payer_id: string; name: string; address: string; income_paid: string }
type Doc = { doc: string; path: string; name: string };
type Need = { label: string; docs: { id: string; label: string }[]; fields?: string[]; accommodation?: boolean };
const FILE_TYPES = 'application/pdf,.pdf,image/jpeg,.jpg,.jpeg,image/png,.png';

// A file for a person's return, stored where only they and those who file tax can open it.
export async function putPersonFile(prefix: string, f: File) {
  if (f.size > 15_000_000) throw new Error('The file is larger than 15 MB.');
  if (!/\.(pdf|jpe?g|png)$/i.test(f.name) && !/^(application\/pdf|image\/(jpeg|png))$/.test(f.type)) throw new Error('Attach a PDF, JPEG or PNG.');
  const path = `${prefix}${Date.now()}-${f.name.replace(/[^\w.-]+/g, '_').slice(-80)}`;
  const { error } = await supabase.storage.from('documents').upload(path, f, { contentType: f.type || 'application/pdf', upsert: false });
  if (error) throw new Error(error.message.includes('row-level') ? 'Only this person and whoever files the business\'s tax attach these documents.' : error.message);
  return { path, name: f.name.slice(0, 160) };
}

// The documents one relief needs, each with the files attached for it.
function ReliefDocs({ id, need, docs, prefix, onChange }: { id: string; need: Need; docs: Doc[]; prefix: string | null; onChange: (d: Doc[]) => void }) {
  const toast = useToast();
  const file = useRef<HTMLInputElement>(null);
  const [which, setWhich] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  if (!need?.docs?.length) return null;
  async function add(f: File) {
    if (!prefix || !which) return;
    setBusy(true);
    try { const r = await putPersonFile(`${prefix}${id}/`, f); onChange([...docs, { doc: which, path: r.path, name: r.name }]); }
    catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <div className="stack" style={{ gap: 4, gridColumn: '1 / -1', marginTop: -4 }} data-relief-docs={id}>
      {need.docs.map((n) => {
        const mine = docs.filter((x) => x.doc === n.id);
        return (
          <div key={n.id} className="row wrap" style={{ gap: 6, fontSize: 12 }}>
            <Icon name={mine.length ? 'check' : 'paperclip'} size={12} color={mine.length ? '#15803D' : '#B45309'} />
            <span className={mine.length ? 'muted' : ''} style={{ color: mine.length ? undefined : '#B45309' }}>{n.label}</span>
            {mine.map((x) => (
              <span key={x.path} className="chip t-grey" style={{ gap: 4 }}>
                <button type="button" className="link" style={{ fontSize: 12, border: 0, background: 'none', padding: 0, cursor: 'pointer', color: 'var(--primary)' }} onClick={() => openInTab(() => signedDoc(x.path))}>{x.name}</button>
                <button type="button" className="x-btn" aria-label={`Remove ${x.name}`} style={{ width: 16, height: 16 }} onClick={() => onChange(docs.filter((y) => y.path !== x.path))}><Icon name="x" size={10} /></button>
              </span>
            ))}
            {prefix ? <button type="button" className="btn btn-ghost btn-xs" disabled={busy} onClick={() => { setWhich(n.id); file.current?.click(); }} aria-label={`Attach: ${n.label}`}>
              {busy && which === n.id ? <Spinner small /> : <Icon name="plus" size={11} />}Attach</button>
              : <span className="faint">Save first, then attach</span>}
          </div>
        );
      })}
      <input ref={file} type="file" accept={FILE_TYPES} hidden onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) add(f); }} />
    </div>
  );
}

// The person's own LIRS e-Tax login, for Counta's bot: saved through the server into a locked vault, never shown again.
const LOGIN_STATE: Record<string, { label: string; tone: string }> = {
  saved: { label: 'Saved, not checked yet', tone: 't-grey' }, verified: { label: 'Working', tone: 't-green' }, failed: { label: 'Did not work', tone: 't-red' },
  checking: { label: 'Checking with e-Tax', tone: 't-blue' },
};
// While the bot checks a login it has just been given, that is what the person sees.
const loginState = (l: any) => (l?.checking ? LOGIN_STATE.checking : LOGIN_STATE[l?.status] || LOGIN_STATE.saved);
function EtaxLogin({ year, person }: { year: number; person: any }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const l = person.etax_login || null;
  const [open, setOpen] = useState(!l);
  const [payer, setPayer] = useState(l?.payer_id || '');
  const [pw, setPw] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const first = String(person.name || '').trim().split(/\s+/)[0] || 'they';
  const st = l ? loginState(l) : null;
  // The check takes a minute or so: the login looks again every few seconds until it is done.
  const checking = !!l?.checking;
  useEffect(() => {
    if (!checking) return;
    const t = setInterval(() => { void refresh(); }, 4000);
    return () => clearInterval(t);
  }, [checking]); // eslint-disable-line react-hooks/exhaustive-deps
  // A check waiting to be tried again: look again just after its time.
  const retryAt: string | null = l?.check_retry_at || null;
  useEffect(() => {
    if (!retryAt) return;
    const t = setTimeout(() => { void refresh(); }, Math.max(5000, Math.min(Date.parse(retryAt) - Date.now() + 5000, 15 * 60_000)));
    return () => clearTimeout(t);
  }, [retryAt]); // eslint-disable-line react-hooks/exhaustive-deps
  async function call(kind: 'save' | 'remove') {
    setBusy(kind);
    try {
      const r = await edge<any>('tax-files', kind === 'save'
        ? { action: 'pit_etax_login_save', org_id: orgId, person_id: person.person_id, payer_id: payer, password: pw }
        : { action: 'pit_etax_login_remove', org_id: orgId, person_id: person.person_id });
      if (!r.ok) throw new Error(r.error || 'That did not work.');
      setPw('');
      toast(kind === 'remove' ? 'e-Tax login removed'
        : r.woke === false ? 'e-Tax login saved. Counta checks it with e-Tax once its bot is running.' : 'e-Tax login saved. Counta is checking it with e-Tax.');
      await refresh();
      setOpen(kind === 'remove');
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }
  return (
    <div className="card card-pad stack" style={{ gap: 8, background: '#F8FAFC' }} data-testid="pit-etax-login">
      <div className="row wrap" style={{ justifyContent: 'space-between', gap: 8 }}>
        <b style={{ fontSize: 14 }}>{person.name}'s LIRS e-Tax login</b>
        {st && <span className={'chip ' + st.tone} data-testid="pit-etax-login-state">{st.label}</span>}
      </div>
      <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>Counta's bot signs in to e-Tax as {person.name} with this login to file the {year} return and raise the bill,
        as {first} would. The password is kept in a locked vault for the bot alone and is never shown again. If {first} is signed in to e-Tax while the bot works, e-Tax signs {first} out.</div>
      {l?.status === 'failed' && !checking && <Alert kind="red" icon="lock">e-Tax did not accept it{l.message ? `: ${l.message}` : ''}. Save it again.</Alert>}
      {checking && <div className="row" style={{ gap: 8, fontSize: 13 }} data-testid="pit-etax-checking"><Spinner small />Counta's bot is signing in to e-Tax with it to check it. Nothing on e-Tax is changed.</div>}
      {l?.status === 'verified' && !checking && l.message && <Alert kind="yellow" icon="info">{l.message}</Alert>}
      {l?.status === 'saved' && !checking && l.check_retry_at && <Alert kind="grey" icon="clock">Counta could not check it with e-Tax yet{l.check_error ? `: ${l.check_error}` : '.'} It tries again at {fmtTime(l.check_retry_at)}.</Alert>}
      {l?.status === 'saved' && !checking && !l.check_retry_at && l.check_waiting && <Alert kind="grey" icon="clock">Counta's bot has not reached it yet. It checks it as soon as it runs, and again before the return is sent.</Alert>}
      {l?.status === 'saved' && !checking && !l.check_retry_at && !l.check_waiting && l.check_error && <Alert kind="grey" icon="info">Counta could not check it with e-Tax yet: {l.check_error} Save it again to check it now; otherwise it is checked when the return is sent.</Alert>}
      {l && !open && (
        <div className="row wrap" style={{ gap: 8, fontSize: 13 }}>
          <span>Payer ID <b>{l.payer_id}</b>{l.saved_by ? <span className="faint"> · saved by {l.saved_by}{l.saved_at ? `, ${when(l.saved_at)}` : ''}</span> : null}</span>
          <button className="btn btn-ghost btn-xs" onClick={() => setOpen(true)}>Change</button>
          <button className="btn btn-ghost btn-xs" disabled={!!busy} onClick={() => call('remove')}>{busy === 'remove' ? 'Removing…' : 'Remove'}</button>
        </div>
      )}
      {l?.status === 'verified' && !checking && (l.etax_name || l.tax_station_name) && (
        <div className="faint" style={{ fontSize: 12 }} data-testid="pit-etax-found">On e-Tax as {l.etax_name || person.name}{l.tax_station_name ? `, tax station ${l.tax_station_name}` : ''}{l.checked_at ? ` · checked ${when(l.checked_at)}` : ''}.</div>
      )}
      {open && (
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: 'minmax(0,1fr) minmax(0,1fr) auto', gap: 8, alignItems: 'end' }}>
          <Field label="Payer ID"><input className="input" aria-label="e-Tax Payer ID" value={payer} onChange={(e) => setPayer(e.target.value)} placeholder="N-1234567" autoComplete="off" /></Field>
          <Field label="e-Tax password"><input className="input" type="password" aria-label="e-Tax password" value={pw} onChange={(e) => setPw(e.target.value)} autoComplete="new-password" /></Field>
          <div className="row" style={{ gap: 6 }}>
            <button className="btn btn-primary btn-sm" disabled={!!busy || !payer.trim() || !pw} onClick={() => call('save')}>{busy === 'save' ? 'Saving…' : 'Save login'}</button>
            {l && <button className="btn btn-ghost btn-sm" onClick={() => { setOpen(false); setPw(''); }}>Cancel</button>}
          </div>
        </div>
      )}
      <div className="faint" style={{ fontSize: 11 }}>The Payer ID is the number starting N- on {first}'s e-Tax profile, which is not the Tax ID.</div>
    </div>
  );
}

// The login on its own, once the year is approved and the drawer is closed to changes.
function LoginModal({ d, year, personId, onClose }: { d: any; year: number; personId: string; onClose: () => void }) {
  const person = (d.computation?.people || []).find((x: any) => x.person_id === personId);
  if (!person) return null;
  return (
    <Modal onClose={onClose} width={560}>
      <ModalHead title={`${person.name}'s e-Tax login`} sub={person.authority_name || person.authority} onClose={onClose} />
      <div className="modal-body" data-testid="pit-login-modal"><EtaxLogin year={year} person={person} /></div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Close</button></div>
    </Modal>
  );
}

// e-Tax's support staff screen: the person's own household staff, with what each was paid in the year.
function HouseholdStaff({ year, rows, onChange }: { year: number; rows: StaffLine[]; onChange: (r: StaffLine[]) => void }) {
  const upd = (i: number, patch: Partial<StaffLine>) => onChange(rows.map((x, j) => (j === i ? { ...x, ...patch } : x)));
  return (
    <div className="stack" style={{ gap: 8 }} data-testid="pit-household-staff">
      <div className="row" style={{ justifyContent: 'space-between' }}><div className="label">Household staff in {year}</div>
        <button className="btn btn-secondary btn-xs" onClick={() => onChange([...rows, { role: 'driver', registered: false, payer_id: '', name: '', address: '', income_paid: '' }])}>
          <Icon name="plus" size={12} />Staff</button></div>
      <div className="faint" style={{ fontSize: 12, marginTop: -4 }}>e-Tax asks each person for their own driver, cook, security, cleaner or gardener, and what each was paid in the year. The business's employees go under Staff instead.</div>
      {!rows.length && <div className="faint" style={{ fontSize: 13 }}>None.</div>}
      {rows.map((x, i) => (
        <div key={i} className="card" style={{ padding: 10, borderRadius: 10, display: 'grid', gridTemplateColumns: 'minmax(0,1fr) minmax(0,1fr) 32px', gap: 8 }} data-staff-row={i}>
          <select className="input input-sm" aria-label="What they do" value={x.role} onChange={(e) => upd(i, { role: e.target.value })}>
            {STAFF_ROLES.map((r) => <option key={r.id} value={r.id}>{r.label}</option>)}</select>
          <input className="input input-sm num" inputMode="decimal" placeholder={`Paid in ${year}`} aria-label="Paid in the year" value={x.income_paid} onChange={(e) => upd(i, { income_paid: e.target.value })} />
          <button className="x-btn" aria-label="Remove the staff" onClick={() => onChange(rows.filter((_, j) => j !== i))}><Icon name="x" size={14} /></button>
          <label className="check" style={{ gridColumn: '1 / -1', fontSize: 12 }}><input type="checkbox" checked={x.registered} onChange={(e) => upd(i, { registered: e.target.checked })} />Has a Payer ID on e-Tax</label>
          {x.registered
            ? <input className="input input-sm" style={{ gridColumn: '1 / -1' }} placeholder="Their Payer ID (N-…)" aria-label="Their Payer ID" value={x.payer_id} onChange={(e) => upd(i, { payer_id: e.target.value })} />
            : <>
                <input className="input input-sm" placeholder="Full name" aria-label="Full name of the staff" value={x.name} onChange={(e) => upd(i, { name: e.target.value })} />
                <input className="input input-sm" style={{ gridColumn: '2 / -1' }} placeholder="Home address" aria-label="Home address of the staff" value={x.address} onChange={(e) => upd(i, { address: e.target.value })} />
              </>}
        </div>
      ))}
    </div>
  );
}

function PersonDrawer({ d, year, firstYear, person, onClose }: { d: any; year: number; firstYear: number; person: any; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const comp = d.computation || {};
  const isNew = !!person.new;
  const all = !!d.can?.edit_people;
  const legacy = comp.regime === 'PITA';
  const needs: Record<string, Need> = d.relief_needs || {};
  const s = (v: unknown) => (v == null || v === '' || Number(v) === 0 ? '' : String(v));
  const base = (d.people_all || []).find((x: any) => x.id === person.person_id) || {};
  const a0 = person.accommodation || {};
  const [f, setF] = useState({
    name: person.name || '', tin: person.tin || base.tin || '', member_id: base.member_id || '',
    share_pct: isNew ? '' : String(person.share_pct ?? ''), role: person.role === 'proprietor' ? 'active' : person.role || 'active',
    office_location_id: person.office_location_id || '', residence: person.residence || '', resident: person.resident !== false,
    remuneration: s(person.remuneration), remuneration_note: person.remuneration_note || '',
    losses_bf: s(person.opening?.losses_bf), ca_bf: s(person.opening?.ca_bf),
    reliefs: Object.fromEntries(RELIEFS.map((r) => [r.id, s(person.reliefs?.[r.id])])) as Record<string, string>,
    other: ((person.other_income || []) as any[]).map((l) => ({ kind: incomeChoice(l), label: l.label || '', amount: String(l.amount ?? ''), tax_deducted: s(l.tax_deducted) })) as Line[],
    acc: { address: a0.address || '', type: a0.type || '', occupancy: a0.occupancy || '', landlord_name: a0.landlord_name || '', landlord_id: a0.landlord_id || '',
      landlord_address: a0.landlord_address || '', rent_paid: s(a0.rent_paid), rent_paid_by_employer: s(a0.rent_paid_by_employer), started_on: a0.started_on || '', ended_on: a0.ended_on || '' },
    rsa_number: person.pension_details?.rsa_number || '', pfa: person.pension_details?.pfa || '',
    life_company: person.pension_details?.life_company || '', life_policy: person.pension_details?.life_policy || '',
    mortgage_institution: person.pension_details?.mortgage_institution || '', mortgage_capital: s(person.pension_details?.mortgage_capital),
    staff: ((person.household_staff || []) as any[]).map((x) => ({ role: x.role || 'driver', registered: !!x.registered, payer_id: x.payer_id || '', name: x.name || '',
      address: x.address || '', income_paid: s(x.income_paid) })) as StaffLine[],
    docs: { ...(person.relief_docs || {}) } as Record<string, Doc[]>,
  });
  // The person as the year shows them now (the drawer opened with a copy): their e-Tax login changes while it is open.
  const livePerson = (comp.people || []).find((x: any) => x.person_id === person.person_id) || person;
  // A person Counta's own bot files for (LIRS e-Tax): e-Tax also asks for their household staff and takes their own login.
  const bot = !isNew && (!!person.bot || (d.bot_authorities || []).includes(person.authority));
  const [busy, setBusy] = useState(false);
  const set = (k: string, v: any) => setF((x) => ({ ...x, [k]: v }));
  const setAcc = (k: string, v: string) => setF((x) => ({ ...x, acc: { ...x.acc, [k]: v } }));
  const sole = comp.kind === 'sole' && !isNew;
  const firstForPerson = !person.bf?.from_previous_year;
  // Rent relief comes from the accommodation (a tenant's rent), not from a box of its own.
  const reliefs = RELIEFS.filter((r) => r.id !== 'rent_paid' && (r.law === 'both' || (legacy ? r.law === 'pita' : r.law === 'nta')));
  const held: Record<string, string[]> = Object.fromEntries(((person.reliefs_held || []) as any[]).map((h) => [h.relief, h.missing || []]));
  const prefix = person.person_id ? `${orgId}/tax/pit/${year}/people/${person.person_id}/` : null;
  const tenant = f.acc.occupancy === 'tenant';
  const n = (v: string) => (v.trim() === '' ? 0 : money(v));
  const netRent = tenant ? Math.max((n(f.acc.rent_paid) || 0) - (n(f.acc.rent_paid_by_employer) || 0), 0) : 0;
  async function save(remove = false) {
    setBusy(true);
    try {
      let id = person.person_id as string | undefined;
      if (all && (isNew || remove || f.name !== person.name || f.tin !== (person.tin || base.tin || '') || f.member_id !== (base.member_id || ''))) {
        const r = await rpc<any>('save_pit_person', { p_org: orgId, p: remove ? { id, delete: true } : { id: id || null, name: f.name, tin: f.tin || null, member_id: f.member_id || null } });
        if (remove) { toast(r.removed ? 'Removed' : 'Kept for earlier years, and left out from now on'); await refresh(); onClose(); setBusy(false); return; }
        id = r.id;
      }
      const hasAcc = Object.values(f.acc).some((v) => String(v).trim() !== '');
      const p: Record<string, unknown> = {
        residence: f.residence || null, resident: f.resident,
        reliefs: Object.fromEntries(reliefs.map((r) => [r.id, n(f.reliefs[r.id] || '')])),
        other_income: f.other.filter((l) => l.amount.trim() || l.label.trim()).map((l) => ({ ...incomeOf(l.kind), label: l.label, amount: money(l.amount), tax_deducted: n(l.tax_deducted) })),
        accommodation: hasAcc ? { ...f.acc, rent_paid: tenant ? n(f.acc.rent_paid) : 0, rent_paid_by_employer: n(f.acc.rent_paid_by_employer),
          landlord_name: tenant ? f.acc.landlord_name : '', landlord_id: tenant ? f.acc.landlord_id : '', landlord_address: tenant ? f.acc.landlord_address : '' } : {},
        pension_details: { rsa_number: f.rsa_number, pfa: f.pfa, life_company: f.life_company, life_policy: f.life_policy,
          mortgage_institution: f.mortgage_institution, mortgage_capital: f.mortgage_capital.trim() ? n(f.mortgage_capital) : '' },
      };
      if (bot) p.household_staff = f.staff.filter((x) => x.name.trim() || x.payer_id.trim() || x.income_paid.trim())
        .map((x) => (x.registered ? { role: x.role, registered: true, payer_id: x.payer_id.trim(), name: x.name.trim() || null, income_paid: n(x.income_paid) }
          : { role: x.role, registered: false, name: x.name.trim(), address: x.address.trim(), income_paid: n(x.income_paid) }));
      if (!isNew) p.relief_docs = Object.fromEntries(Object.entries(needs).filter(([, v]) => v.docs?.length).map(([k]) => [k, f.docs[k] || []]));
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
    <Drawer onClose={onClose} width={680}>
      <div className="drawer-hd"><div className="grow"><div className="drawer-title">{isNew ? 'A partner' : person.name}</div>
        <div className="muted" style={{ fontSize: 13 }}>{year} accounts · year of assessment {comp.yoa}{!isNew && person.authority_name ? ` · ${person.authority_name}` : ''}</div></div>
        <button className="x-btn" onClick={onClose} aria-label="Close"><Icon name="x" size={18} /></button></div>
      <div className="drawer-body stack" style={{ gap: 14 }}>
        {bot && 'etax_login' in livePerson && <EtaxLogin year={year} person={livePerson} />}
        {all && (
          <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
            <Field label="Name" req style={{ gridColumn: '1 / -1' }}><input className="input" value={f.name} onChange={(e) => set('name', e.target.value)} /></Field>
            <Field label="Tax ID"><input className="input" value={f.tin} onChange={(e) => set('tin', e.target.value)} placeholder="From taxid.nrs.gov.ng" /></Field>
            <Field label="Their Counta login" hint="Linked, they can enter their own reliefs, other income and home."><select className="input" value={f.member_id} onChange={(e) => set('member_id', e.target.value)}>
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

        <div className="label">Where they lived in {year}</div>
        <div className="faint" style={{ fontSize: 12, marginTop: -8 }}>The state portal asks for this before anything else on the return.{person.accommodation_carried ? ' Carried from last year: check it' + (tenant ? ' and enter this year\'s rent.' : '.') : ''}</div>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }} data-testid="pit-home">
          <Field label="Address" style={{ gridColumn: '1 / -1' }}><input className="input" aria-label="Home address" value={f.acc.address} onChange={(e) => setAcc('address', e.target.value)} /></Field>
          <Field label="Kind of home"><select className="input" aria-label="Kind of home" value={f.acc.type} onChange={(e) => setAcc('type', e.target.value)}>
            <option value="">Choose</option>{HOME_TYPES.map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}</select></Field>
          <Field label="How they live there"><select className="input" aria-label="How they live there" value={f.acc.occupancy} onChange={(e) => setAcc('occupancy', e.target.value)}>
            <option value="">Choose</option>{OCCUPANCY.map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}</select></Field>
          <Field label="Moved in"><input className="input" type="date" aria-label="Moved in" value={f.acc.started_on} onChange={(e) => setAcc('started_on', e.target.value)} /></Field>
          <Field label="Moved out (if they did)"><input className="input" type="date" aria-label="Moved out" value={f.acc.ended_on} onChange={(e) => setAcc('ended_on', e.target.value)} /></Field>
          {tenant && <>
            <Field label="Landlord"><input className="input" aria-label="Landlord" value={f.acc.landlord_name} onChange={(e) => setAcc('landlord_name', e.target.value)} /></Field>
            <Field label="Landlord's Tax ID or ID (optional)"><input className="input" aria-label="Landlord's ID" value={f.acc.landlord_id} onChange={(e) => setAcc('landlord_id', e.target.value)} /></Field>
            <Field label="Landlord's address" style={{ gridColumn: '1 / -1' }}><input className="input" aria-label="Landlord's address" value={f.acc.landlord_address} onChange={(e) => setAcc('landlord_address', e.target.value)} /></Field>
            <Field label={`Rent for ${year}`}><input className="input num" inputMode="decimal" aria-label="Rent for the year" value={f.acc.rent_paid} onChange={(e) => setAcc('rent_paid', e.target.value)} /></Field>
            <Field label="Of which an employer paid"><input className="input num" inputMode="decimal" aria-label="Rent an employer paid" value={f.acc.rent_paid_by_employer} onChange={(e) => setAcc('rent_paid_by_employer', e.target.value)} /></Field>
            {!legacy && <div className="faint" style={{ gridColumn: '1 / -1', fontSize: 12 }}>Rent relief: 20% of the rent they paid themselves ({N2(netRent)}), at most ₦500,000 (NTA 2025 s.30(2)(a)(vi)). Leave out any part claimed as business rent.</div>}
          </>}
          {f.acc.occupancy === 'employer' && <Field label="Rent an employer paid (optional)"><input className="input num" inputMode="decimal" aria-label="Rent an employer paid" value={f.acc.rent_paid_by_employer} onChange={(e) => setAcc('rent_paid_by_employer', e.target.value)} /></Field>}
        </div>

        <div className="label">Reliefs for {year}</div>
        <div className="faint" style={{ fontSize: 12, marginTop: -8 }}>The state portal refuses a relief without its documents, so each counts once they are attached.</div>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          {reliefs.map((r) => {
            const amount = Number(n(f.reliefs[r.id] || '') || 0);
            return (
              <div key={r.id} className="stack" style={{ gap: 6, gridColumn: amount > 0 ? '1 / -1' : undefined }}>
                <Field label={r.label} hint={r.hint}><input className="input num" inputMode="decimal" value={f.reliefs[r.id] || ''} data-relief={r.id}
                  onChange={(e) => set('reliefs', { ...f.reliefs, [r.id]: e.target.value })} /></Field>
                {amount > 0 && r.id === 'pension' && (
                  <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
                    <Field label="RSA number"><input className="input" aria-label="RSA number" value={f.rsa_number} onChange={(e) => set('rsa_number', e.target.value)} placeholder="PEN followed by 12 digits" /></Field>
                    <Field label="Pension fund administrator"><input className="input" aria-label="Pension fund administrator" value={f.pfa} onChange={(e) => set('pfa', e.target.value)} /></Field>
                  </div>
                )}
                {amount > 0 && r.id === 'life_insurance' && (
                  <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
                    <Field label="Insurance company"><input className="input" aria-label="Insurance company" value={f.life_company} onChange={(e) => set('life_company', e.target.value)} /></Field>
                    <Field label="Policy name"><input className="input" aria-label="Policy name" value={f.life_policy} onChange={(e) => set('life_policy', e.target.value)} placeholder="As on the policy" /></Field>
                  </div>
                )}
                {amount > 0 && r.id === 'home_loan_interest' && (
                  <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
                    <Field label="Mortgage lender"><input className="input" aria-label="Mortgage lender" value={f.mortgage_institution} onChange={(e) => set('mortgage_institution', e.target.value)} placeholder="The primary mortgage bank" /></Field>
                    <Field label="Capital sum on the mortgage"><input className="input num" inputMode="decimal" aria-label="Capital sum on the mortgage" value={f.mortgage_capital} onChange={(e) => set('mortgage_capital', e.target.value)} /></Field>
                  </div>
                )}
                {amount > 0 && <ReliefDocs id={r.id} need={needs[r.id]} docs={f.docs[r.id] || []} prefix={prefix} onChange={(x) => set('docs', { ...f.docs, [r.id]: x })} />}
                {amount > 0 && held[r.id] && <div style={{ fontSize: 12, color: '#B45309' }} data-held={r.id}>Left out of the computation until saved with: {held[r.id].join(', ')}.</div>}
              </div>
            );
          })}
        </div>
        <div className="faint" style={{ fontSize: 12 }}>{legacy ? 'Old law: pension, NHF, NHIS, life insurance and gratuity come off first, then the consolidated relief allowance, then home loan interest.' : 'These come off total income at full value (NTA 2025 s.30). There is no consolidated relief allowance from 2026.'}
          {bot ? ' e-Tax has no section for gratuity or rent relief: Counta counts them in the computation attached to the return.' : ''}</div>
        {bot && <HouseholdStaff year={year} rows={f.staff} onChange={(x) => set('staff', x)} />}
        <div className="row" style={{ justifyContent: 'space-between' }}><div className="label">Other income in {year}</div>
          <button className="btn btn-secondary btn-xs" onClick={() => set('other', [...f.other, { kind: 'employment', label: '', amount: '', tax_deducted: '' }])}><Icon name="plus" size={12} />Income</button></div>
        {!f.other.length && <div className="faint" style={{ fontSize: 13 }}>None. Add a salary, rent, dividends, interest or income from abroad, so the return covers everything.</div>}
        {f.other.map((l, i) => {
          const k = OTHER_INCOME.find((x) => x.id === l.kind);
          const kind = incomeOf(l.kind).kind;
          const upd = (patch: Partial<Line>) => set('other', f.other.map((y, j) => (j === i ? { ...y, ...patch } : y)));
          return (
            <div key={i} className="card" style={{ padding: 10, borderRadius: 10, display: 'grid', gridTemplateColumns: 'minmax(0,1fr) minmax(0,1fr) 32px', gap: 8 }}>
              <select className="input input-sm" style={{ gridColumn: '1 / 3' }} aria-label="Kind of income" value={l.kind} onChange={(e) => upd({ kind: e.target.value })}>{OTHER_INCOME.map((x) => <option key={x.id} value={x.id}>{x.label}</option>)}</select>
              <button className="x-btn" aria-label="Remove" onClick={() => set('other', f.other.filter((_, j) => j !== i))}><Icon name="x" size={14} /></button>
              <input className="input input-sm num" inputMode="decimal" placeholder="Amount" aria-label="Amount" value={l.amount} onChange={(e) => upd({ amount: e.target.value })} />
              <input className="input input-sm num" style={{ gridColumn: '2 / -1' }} inputMode="decimal" placeholder={kind === 'foreign_earned' ? 'Foreign tax' : kind === 'employment' ? 'PAYE' : 'Tax deducted'}
                aria-label={kind === 'foreign_earned' ? 'Foreign tax paid' : kind === 'employment' ? 'PAYE deducted' : 'Tax deducted'} value={l.tax_deducted} onChange={(e) => upd({ tax_deducted: e.target.value })} />
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

// ---------------------------------------------------------------- staff
// The business's employees for the year, for the state portal's support staff screen. Saving the list (even an empty
// one) confirms it; a return Flux files cannot be approved until it is confirmed.
type StaffRow = { name: string; role: string; annual_pay: string; tin: string };
function Staff({ d, year }: { d: any; year: number }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const comp = d.computation || {};
  const review = comp.staff_review || {};
  const blank: StaffRow = { name: '', role: '', annual_pay: '', tin: '' };
  const [rows, setRows] = useState<StaffRow[]>(() => ((comp.staff || []) as any[]).map((x) => ({ name: x.name || '', role: x.role || '', annual_pay: String(x.annual_pay ?? ''), tin: x.tin || '' })));
  const [busy, setBusy] = useState(false);
  if (comp.staff == null) return <Alert kind="grey" icon="lock">The staff and their pay are for those who keep the books or see the money.</Alert>;
  const ro = !d.can?.edit_business;
  const filled = rows.filter((r) => r.name.trim() || r.annual_pay.trim() || r.role.trim());
  const total = filled.reduce((t, r) => t + (money(r.annual_pay) || 0), 0);
  const salaries = Number(comp.business?.figures?.salaries || 0);
  const upd = (i: number, patch: Partial<StaffRow>) => setRows(rows.map((r, j) => (j === i ? { ...r, ...patch } : r)));
  async function save(none = false) {
    setBusy(true);
    try {
      const staff = none ? [] : filled.map((r) => ({ name: r.name.trim(), role: r.role.trim() || null, annual_pay: r.annual_pay.trim() === '' ? null : money(r.annual_pay), tin: r.tin.trim() || null }));
      await rpc('save_pit_year', { p_org: orgId, p_year: year, p: { staff } });
      if (none) setRows([]);
      toast(none ? 'Confirmed: no employees' : 'Staff saved'); await refresh();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <div className="stack" style={{ gap: 12 }} data-testid="pit-staff">
      <div className="muted" style={{ fontSize: 13, lineHeight: 1.6 }}>The state portal asks for the business's employees with each return: their names, roles and pay for {year}. The fixed assets go from Capital allowances.</div>
      <div className="card" style={{ overflow: 'auto' }}>
        <div className="tr head shade th rsp" style={{ gridTemplateColumns: 'minmax(160px,1.4fr) minmax(120px,1fr) 140px 140px 32px', minWidth: 640 }}>
          <span>Name</span><span>Role</span><span className="right">Pay for the year</span><span>Tax ID</span><span />
        </div>
        {rows.length === 0 && <div style={{ padding: 14 }} className="faint">No employees listed.</div>}
        {rows.map((r, i) => (
          <div key={i} className="tr rsp" style={{ gridTemplateColumns: 'minmax(160px,1.4fr) minmax(120px,1fr) 140px 140px 32px', minWidth: 640, gap: 8 }} data-testid="pit-staff-row">
            <input className="input input-sm m-main" aria-label="Employee name" disabled={ro} value={r.name} onChange={(e) => upd(i, { name: e.target.value })} />
            <input className="input input-sm" aria-label="Role" disabled={ro} value={r.role} onChange={(e) => upd(i, { role: e.target.value })} />
            <input className="input input-sm num" aria-label="Pay for the year" inputMode="decimal" disabled={ro} value={r.annual_pay} onChange={(e) => upd(i, { annual_pay: e.target.value })} />
            <input className="input input-sm" aria-label="Tax ID" disabled={ro} value={r.tin} onChange={(e) => upd(i, { tin: e.target.value })} />
            {!ro ? <button className="x-btn" aria-label="Remove employee" onClick={() => setRows(rows.filter((_, j) => j !== i))}><Icon name="x" size={14} /></button> : <span />}
          </div>
        ))}
        <div className="row wrap" style={{ justifyContent: 'space-between', padding: '10px 16px', fontSize: 13 }}>
          {!ro ? <button className="btn btn-secondary btn-xs" onClick={() => setRows([...rows, blank])}><Icon name="plus" size={12} />Employee</button> : <span />}
          <span>Pay listed <b className="num">{N2(total)}</b><span className="faint"> · salaries in the accounts {N2(salaries)}</span></span>
        </div>
      </div>
      {!ro && (
        <div className="row wrap" style={{ gap: 8, alignItems: 'center' }}>
          <button className="btn btn-primary" disabled={busy} onClick={() => save()} data-testid="pit-staff-save">{busy ? 'Saving…' : review.reviewed ? 'Save' : 'Confirm the staff'}</button>
          {filled.length === 0 && <button className="btn btn-ghost" disabled={busy} onClick={() => save(true)} data-testid="pit-staff-none">It had no employees</button>}
          {!review.reviewed && <span className="faint" style={{ fontSize: 12 }}>A return Flux files is approved once the staff are confirmed.</span>}
        </div>
      )}
      {review.reviewed && <div className="faint" style={{ fontSize: 12 }}>Confirmed{review.by ? ` by ${review.by}` : ''}{review.at ? ` (${when(review.at)})` : ''}.</div>}
    </div>
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
