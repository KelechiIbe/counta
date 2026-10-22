// The Counta Partner programme: what accountants earn (tiers, milestone bonuses, the welcome offer), the payouts waiting
// for approval with the bank's name check, payouts that failed, the WHT withheld each month, and every practice's totals.
import { useEffect, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { N2, fmtDay, when } from '../../lib/format';
import { pct, type Tier } from '../../lib/partners';
import { useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Field, Seg, SkeletonRows, Spinner } from '../../components/ui';
import { Card, PageHead, Tile, Toggle, grid } from '../ui';

type Settings = {
  enabled: boolean; tiers: Tier[]; milestones: { clients: number; bonus: number }[]; welcome: { on: boolean; percent: number; payments: number };
  hold_days: number; min_payout: number; payout_day: number; wht_rate: number; directory: { on: boolean; min_clients: number };
  payer: { name: string; tin: string | null; address: string | null };
};
type Payout = {
  id: string; practice: string; practice_id: string; period: string; gross: number; wht_rate: number; wht: number; net: number;
  status: 'draft' | 'approved' | 'sending' | 'paid' | 'failed' | 'cancelled'; bank_name: string | null; last4: string | null; account_name: string | null;
  name_match: boolean | null; reference: string; attempts: number; error: string | null; note: string | null; approved_at: string | null; paid_at: string | null;
  created_at: string; verified: boolean; bank_changed: boolean; lines: number;
};
type Data = {
  settings: Settings; payouts: Payout[]; wht: { month: string; wht: number; gross: number; payouts: number }[];
  practices: { id: string; name: string; code: string; listed: boolean; verified: boolean; tier: string; paying: number; referrals: number; void: number; earned: number;
    paid: number; waiting: number; bank: { bank_name: string; last4: string; account_name: string; name_match: boolean; set_at: string } | null }[];
  last_run: { period: string; ran_at: string; created: number } | null;
};

const STATUS: Record<Payout['status'], [string, string]> = {
  draft: ['To approve', 't-amber'], approved: ['Approved, to send', 't-blue'], sending: ['Sent, bank to confirm', 't-blue'], paid: ['Paid', 't-green'],
  failed: ['Failed', 't-red'], cancelled: ['Held', 't-grey'],
};
const monthName = (d: string) => new Date(d.slice(0, 10) + 'T12:00:00Z').toLocaleString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });

export default function Partners() {
  const q = useQuery({ queryKey: ['admin-partners'], queryFn: () => rpc<Data>('admin_partners') });
  const [tab, setTab] = useState<'payouts' | 'practices' | 'settings'>('payouts');
  const d = q.data;
  const open = d?.payouts.filter((x) => ['draft', 'failed'].includes(x.status)) || [];
  return (
    <>
      <PageHead title="Partners" sub="Accountants earn a share of what the businesses they bring pay for Counta. Approve each payout here; Counta sends it from TaxStreem's Flutterwave balance." />
      {q.isLoading ? <SkeletonRows n={6} /> : q.isError || !d ? <Alert kind="red" icon="alert">{cleanError(q.error)}</Alert> : (
        <>
          {!d.settings.enabled && <Alert kind="amber" icon="alert">The programme is paused: no new referrals, earnings or welcome offers. Payouts already listed still go.</Alert>}
          <div style={grid(170)}>
            <Tile label="To approve" value={open.filter((x) => x.status === 'draft').length} tone={open.length ? '#B45309' : undefined} sub={open.some((x) => x.status === 'failed') ? 'and failed ones below' : 'payouts'} onClick={() => setTab('payouts')} />
            <Tile label="Practices earning" value={d.practices.filter((p) => p.paying > 0).length} sub={(() => { const n = d.practices.reduce((a, p) => a + p.paying, 0); return `${n} paying ${n === 1 ? 'business' : 'businesses'}`; })()} onClick={() => setTab('practices')} />
            <Tile label="Owed to partners" value={N2(d.practices.reduce((a, p) => a + Number(p.waiting), 0))} sub="earned, not yet paid" />
            <Tile label="Paid to partners" value={N2(d.practices.reduce((a, p) => a + Number(p.paid), 0))} sub="before WHT" />
          </div>
          <Seg value={tab} onChange={setTab} options={[{ id: 'payouts', label: 'Payouts' }, { id: 'practices', label: 'Practices' }, { id: 'settings', label: 'Settings' }]} />
          {tab === 'payouts' && <PayoutsTab d={d} />}
          {tab === 'practices' && <PracticesTab d={d} />}
          {tab === 'settings' && <SettingsTab s={d.settings} />}
        </>
      )}
    </>
  );
}

function PayoutsTab({ d }: { d: Data }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [busy, setBusy] = useState<string | null>(null);
  const refresh = () => qc.invalidateQueries({ queryKey: ['admin-partners'] });
  async function run() {
    setBusy('run');
    try { const r = await rpc<{ created: number }>('admin_partner_payout_run'); toast(r.created ? `${r.created} listed to approve` : 'Nothing new is ready to pay'); await refresh(); }
    catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  async function send() {
    setBusy('send');
    const r = await edge<any>('payments', { action: 'partner_payouts_send' });
    if (r.ok === false) toast(r.error || 'Not sent', 'err');
    else toast(r.waiting ? 'Transfers are not switched on: approved payouts wait for the relay.' : `${r.sent} sent${r.failed ? `, ${r.failed} refused` : ''}`, r.failed || r.waiting ? 'err' : undefined);
    await refresh(); setBusy(null);
  }
  const live = d.payouts.filter((x) => ['draft', 'failed', 'approved', 'sending'].includes(x.status));
  const done = d.payouts.filter((x) => !live.includes(x));
  return (
    <div className="stack" style={{ gap: 14 }}>
      <div className="row wrap" style={{ gap: 8 }}>
        <span className="faint grow" style={{ fontSize: 13 }}>{d.last_run ? `Last listed ${when(d.last_run.ran_at)}, ${d.last_run.created} payout${d.last_run.created === 1 ? '' : 's'}.` : 'Not listed yet this month.'}
          {' '}Payouts are listed on the {d.settings.payout_day}{d.settings.payout_day === 1 ? 'st' : d.settings.payout_day === 2 ? 'nd' : d.settings.payout_day === 3 ? 'rd' : 'th'} of each month.</span>
        <button className="btn btn-secondary btn-sm" disabled={busy !== null} onClick={run}>{busy === 'run' ? <Spinner small /> : null}List payouts now</button>
        {d.payouts.some((x) => x.status === 'approved') && <button className="btn btn-primary btn-sm" disabled={busy !== null} onClick={send}>{busy === 'send' ? <Spinner small /> : <Icon name="send" size={14} color="#fff" />}Send approved payouts</button>}
      </div>
      {!live.length ? <Alert kind="green" icon="check">Nothing waiting.</Alert> : live.map((x) => <PayoutCard key={x.id} x={x} onDone={refresh} />)}
      {done.length > 0 && (
        <Card title="Earlier payouts" pad={false}>
          <div className="tbl">
            {done.map((x) => (
              <div key={x.id} className="tr rsp" style={{ gridTemplateColumns: 'minmax(160px,1.4fr) minmax(120px,1fr) 120px 120px' }}>
                <span className="m-main"><b>{x.practice}</b><span className="faint" style={{ display: 'block', fontSize: 12 }}>{monthName(x.period)} · {x.reference}</span></span>
                <span className="faint">{x.bank_name} ••••{x.last4}</span>
                <span className="right num">{N2(x.net)}</span>
                <span className="right m-end"><span className={'chip ' + STATUS[x.status][1]}>{STATUS[x.status][0]}</span><span className="faint" style={{ display: 'block', fontSize: 12 }}>{x.paid_at ? fmtDay(x.paid_at.slice(0, 10)) : x.note || ''}</span></span>
              </div>
            ))}
          </div>
        </Card>
      )}
      {d.wht.length > 0 && (
        <Card title="WHT withheld" sub="Withheld from partner payouts, by the month they were paid, for remitting." pad={false}>
          <div className="tbl" data-testid="partner-wht">
            {d.wht.map((w) => (
              <div key={w.month} className="tr" style={{ gridTemplateColumns: 'minmax(140px,1fr) 120px 140px' }}>
                <span>{monthName(w.month)} · {w.payouts} payout{w.payouts === 1 ? '' : 's'}</span><span className="right num faint">{N2(w.gross)}</span><span className="right num"><b>{N2(w.wht)}</b></span>
              </div>
            ))}
          </div>
        </Card>
      )}
    </div>
  );
}

function PayoutCard({ x, onDone }: { x: Payout; onDone: () => void }) {
  const toast = useToast();
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  async function act(action: 'approve' | 'hold' | 'retry') {
    if (action === 'hold' && note.trim().length < 3) { toast('Say why it is held.', 'err'); return; }
    setBusy(action);
    try {
      await rpc('admin_partner_payout_decide', { p_payout: x.id, p_action: action, p_note: note.trim() || null });
      if (action !== 'hold') {
        const r = await edge<any>('payments', { action: 'partner_payouts_send' });
        toast(r.ok === false ? (r.error || 'Approved; not sent yet') : r.waiting ? 'Approved. Transfers are not switched on, so it waits.' : r.failed ? 'Approved, but Flutterwave refused it' : 'Approved and sent',
          r.ok === false || r.failed ? 'err' : undefined);
      } else toast('Held. Its amount waits for the next payout.');
      onDone();
    } catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  const [label, tone] = STATUS[x.status];
  return (
    <div className="card card-pad stack" style={{ gap: 10 }} data-testid="partner-payout">
      <div className="row wrap" style={{ gap: 10, alignItems: 'flex-start' }}>
        <div style={{ flex: '1 1 240px', minWidth: 0 }}>
          <div style={{ fontWeight: 700, fontSize: 16 }}>{x.practice}</div>
          <div className="faint" style={{ fontSize: 13 }}>{monthName(x.period)} · {x.lines} {x.lines === 1 ? 'amount' : 'amounts'} · {x.reference}{x.attempts > 1 ? ` · attempt ${x.attempts}` : ''}</div>
        </div>
        <span className={'chip ' + tone}>{label}</span>
      </div>
      <div className="row wrap" style={{ gap: 18, fontSize: 14 }}>
        <span>Earned <b className="num">{N2(x.gross)}</b></span>
        <span>WHT {pct(x.wht_rate)} <b className="num">{N2(x.wht)}</b></span>
        <span>To pay <b className="num" style={{ fontSize: 16 }}>{N2(x.net)}</b></span>
      </div>
      <div className="row wrap" style={{ gap: 8, fontSize: 14 }}>
        <Icon name="landmark" size={15} color="#6B7280" />
        <span>{x.bank_name} ••••{x.last4} · <b>{x.account_name}</b></span>
        {x.name_match ? <span className="chip t-green">Name matches the practice</span> : <span className="chip t-red">Name differs from the practice and its partners</span>}
      </div>
      {x.bank_changed && <Alert kind="amber" icon="alert">The practice changed its bank account after this was listed. Approving uses the new account.</Alert>}
      {!x.verified && <Alert kind="red" icon="shield">No partner of this practice has a verified licence now.</Alert>}
      {x.error && <Alert kind="red" icon="alert">{x.error}</Alert>}
      {(x.status === 'draft' || x.status === 'failed') && (
        <div className="row wrap" style={{ gap: 8 }}>
          <input className="input" style={{ flex: '1 1 220px', minWidth: 0, height: 34 }} placeholder="Note (needed to hold)" value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} />
          {x.status === 'draft' && <button className="btn btn-primary btn-sm" disabled={busy !== null || !x.verified} onClick={() => act('approve')}>{busy === 'approve' ? <Spinner small /> : <Icon name="check" size={14} color="#fff" />}Approve and pay</button>}
          {x.status === 'failed' && <button className="btn btn-primary btn-sm" disabled={busy !== null} onClick={() => act('retry')}>{busy === 'retry' ? <Spinner small /> : null}Send again</button>}
          <button className="btn btn-ghost btn-sm" disabled={busy !== null} onClick={() => act('hold')}>{busy === 'hold' ? <Spinner small /> : null}Hold</button>
        </div>
      )}
    </div>
  );
}

function PracticesTab({ d }: { d: Data }) {
  if (!d.practices.length) return <Alert kind="grey" icon="info">No practice has brought a business yet.</Alert>;
  return (
    <Card pad={false}>
      <div className="tbl" data-testid="partner-practices">
        <div className="tr head shade th hide-sm" style={{ gridTemplateColumns: COLS }}>
          <span>Practice</span><span>Tier</span><span className="right">Paying</span><span className="right">Earned</span><span className="right">Paid</span><span>Bank</span>
        </div>
        {d.practices.map((p) => (
          <div key={p.id} className="tr rsp" style={{ gridTemplateColumns: COLS }}>
            <span className="m-main"><b>{p.name}</b><span className="faint" style={{ display: 'block', fontSize: 12 }}>{p.code}{p.listed ? ' · listed' : ''}{p.verified ? '' : ' · licence not verified'}</span></span>
            <span>{p.tier}</span>
            <span className="right num">{p.paying} <span className="faint">of {p.referrals}</span></span>
            <span className="right num">{N2(p.earned)}</span>
            <span className="right num">{N2(p.paid)}</span>
            <span className="m-line" style={{ fontSize: 12 }}>{p.bank ? <>{p.bank.bank_name} ••••{p.bank.last4}{p.bank.name_match ? '' : <span className="chip t-red" style={{ marginLeft: 6 }}>name differs</span>}</> : <span className="faint">none yet</span>}</span>
          </div>
        ))}
      </div>
    </Card>
  );
}
const COLS = 'minmax(170px,1.5fr) 80px 90px 120px 120px minmax(130px,1fr)';

function SettingsTab({ s }: { s: Settings }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [f, setF] = useState<Settings>(s);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => setF(s), [s]);
  const tier = (i: number, k: keyof Tier, v: string) => setF({ ...f, tiers: f.tiers.map((t, j) => (j === i ? { ...t, [k]: k === 'name' ? v : Number(v) } : t)) });
  const ms = (i: number, k: 'clients' | 'bonus', v: string) => setF({ ...f, milestones: f.milestones.map((m, j) => (j === i ? { ...m, [k]: Number(v) } : m)) });
  async function save() {
    setBusy(true); setErr(null);
    try {
      await rpc('admin_partner_settings_save', { p: { ...f, tiers: f.tiers.map(({ name, clients, rate, months }) => ({ name, clients, rate, months })) } });
      await qc.invalidateQueries({ queryKey: ['admin-partners'] });
      toast('Saved. New earnings use these numbers.');
    } catch (e) { setErr(cleanError(e)); }
    setBusy(false);
  }
  const num = { className: 'input input-sm num', inputMode: 'decimal' as const, style: { width: '100%' } };
  return (
    <div className="stack" style={{ gap: 14 }}>
      <Card title="The programme" right={<Toggle on={f.enabled} onChange={(v) => setF({ ...f, enabled: v })} label="Programme on" />}
        sub="Off: no new referrals, earnings or welcome offers. What was earned is still paid.">
        <div style={grid(170)}>
          <Field label="Days each amount waits"><input {...num} value={f.hold_days} onChange={(e) => setF({ ...f, hold_days: Number(e.target.value) })} /></Field>
          <Field label="Smallest payout (₦)"><input {...num} value={f.min_payout} onChange={(e) => setF({ ...f, min_payout: Number(e.target.value) })} /></Field>
          <Field label="Payout day of the month"><input {...num} value={f.payout_day} onChange={(e) => setF({ ...f, payout_day: Number(e.target.value) })} /></Field>
          <Field label="WHT rate (%)" hint="Withheld from each payout"><input {...num} value={Math.round(f.wht_rate * 10000) / 100} onChange={(e) => setF({ ...f, wht_rate: Number(e.target.value) / 100 })} /></Field>
        </div>
      </Card>
      <Card title="Tiers" sub="By the number of businesses a practice brought that have paid. The first starts at 0. A business's months are set when it first pays; the rate is the practice's tier when each payment comes in.">
        {f.tiers.map((t, i) => (
          <div key={i} className="row wrap" style={{ gap: 8, alignItems: 'flex-end' }} data-testid="tier-row">
            <Field label="Name" style={{ flex: '1 1 120px' }}><input className="input input-sm" value={t.name} onChange={(e) => tier(i, 'name', e.target.value)} maxLength={20} /></Field>
            <Field label="From paying businesses" style={{ flex: '1 1 120px' }}><input {...num} value={t.clients} disabled={i === 0} onChange={(e) => tier(i, 'clients', e.target.value)} /></Field>
            <Field label="Rate (%)" style={{ flex: '1 1 90px' }}><input {...num} value={Math.round(t.rate * 10000) / 100} onChange={(e) => tier(i, 'rate', String(Number(e.target.value) / 100))} /></Field>
            <Field label="Months" style={{ flex: '1 1 90px' }}><input {...num} value={t.months} onChange={(e) => tier(i, 'months', e.target.value)} /></Field>
            {i > 0 && <button className="btn btn-ghost btn-sm" onClick={() => setF({ ...f, tiers: f.tiers.filter((_, j) => j !== i) })} aria-label={`Remove ${t.name}`}><Icon name="trash" size={14} /></button>}
          </div>
        ))}
        {f.tiers.length < 5 && <div><button className="btn btn-ghost btn-sm" onClick={() => {
          const last = f.tiers[f.tiers.length - 1];
          setF({ ...f, tiers: [...f.tiers, { code: '', name: 'New tier', clients: (last?.clients || 0) + 10, rate: last?.rate || 0.15, months: last?.months || 6 }] });
        }}><Icon name="plus" size={14} />Add a tier</button></div>}
      </Card>
      <Card title="Milestone bonuses" sub="Paid once each, when that many businesses a practice brought have paid.">
        {f.milestones.map((m, i) => (
          <div key={i} className="row wrap" style={{ gap: 8, alignItems: 'flex-end' }}>
            <Field label="Paying businesses" style={{ flex: '1 1 140px' }}><input {...num} value={m.clients} onChange={(e) => ms(i, 'clients', e.target.value)} /></Field>
            <Field label="Bonus (₦)" style={{ flex: '1 1 140px' }}><input {...num} value={m.bonus} onChange={(e) => ms(i, 'bonus', e.target.value)} /></Field>
            <button className="btn btn-ghost btn-sm" onClick={() => setF({ ...f, milestones: f.milestones.filter((_, j) => j !== i) })} aria-label="Remove"><Icon name="trash" size={14} /></button>
          </div>
        ))}
        {f.milestones.length < 10 && <div><button className="btn btn-ghost btn-sm" onClick={() => setF({ ...f, milestones: [...f.milestones, { clients: (f.milestones[f.milestones.length - 1]?.clients || 0) + 10, bonus: 0 }] })}><Icon name="plus" size={14} />Add a milestone</button></div>}
      </Card>
      <Card title="Welcome offer" right={<Toggle on={f.welcome.on} onChange={(v) => setF({ ...f, welcome: { ...f.welcome, on: v } })} label="Welcome offer on" />}
        sub="Off the first payments of a business that connected an accountant before it paid. A yearly payment gets it on that many months' worth.">
        <div style={grid(170)}>
          <Field label="Discount (%)"><input {...num} value={f.welcome.percent} onChange={(e) => setF({ ...f, welcome: { ...f.welcome, percent: Number(e.target.value) } })} /></Field>
          <Field label="Payments it covers"><input {...num} value={f.welcome.payments} onChange={(e) => setF({ ...f, welcome: { ...f.welcome, payments: Number(e.target.value) } })} /></Field>
        </div>
      </Card>
      <Card title="Directory" right={<Toggle on={f.directory.on} onChange={(v) => setF({ ...f, directory: { ...f.directory, on: v } })} label="Directory on" />}
        sub="Listed practices with a verified licence, shown to businesses in Settings, Your accountant.">
        <Field label="Paying businesses before a practice shows" style={{ maxWidth: 260 }}><input {...num} value={f.directory.min_clients} onChange={(e) => setF({ ...f, directory: { ...f.directory, min_clients: Number(e.target.value) } })} /></Field>
      </Card>
      <Card title="On the WHT notes" sub="The payer's details printed on each partner's WHT note.">
        <div style={grid(220)}>
          <Field label="Name"><input className="input" value={f.payer.name} onChange={(e) => setF({ ...f, payer: { ...f.payer, name: e.target.value } })} /></Field>
          <Field label="Tax ID"><input className="input mono" value={f.payer.tin || ''} onChange={(e) => setF({ ...f, payer: { ...f.payer, tin: e.target.value } })} /></Field>
        </div>
        <Field label="Address"><input className="input" value={f.payer.address || ''} onChange={(e) => setF({ ...f, payer: { ...f.payer, address: e.target.value } })} /></Field>
      </Card>
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
      <div><button className="btn btn-primary" disabled={busy} onClick={save}>{busy ? <Spinner small /> : null}Save the programme</button></div>
    </div>
  );
}
