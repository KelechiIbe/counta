// Earnings: the Counta Partner programme from the practice's side. Its link, its tier and what the next one pays, what it
// earned from each business it brought, the payouts with their WHT notes, the bank account it is paid into, its listing in
// the directory and businesses that asked from there.
import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { N2, fmtDay, when } from '../../lib/format';
import { qrSvg } from '../../lib/labels';
import { type PartnerHome, type PayoutNote, pct, SOURCE_TEXT, tierTone, usePracticePartner } from '../../lib/partners';
import { useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Field, Modal, ModalHead, SkeletonRows, Spinner } from '../../components/ui';
import { PartnerBadge } from '../../components/PartnerBadge';
import { Card, PageHead, Tile, grid } from '../../admin/ui';
import { serviceList, usePracticeHome } from '../api';

const day = (iso: string | null | undefined) => (iso ? fmtDay(iso.slice(0, 10)) : '');
const monthName = (d: string) => new Date(d + 'T12:00:00Z').toLocaleString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });

export default function Earnings({ pid }: { pid: string }) {
  const home = usePracticeHome(pid);
  const q = usePracticePartner(pid);
  const d = q.data;
  if (q.isLoading) return <SkeletonRows n={6} />;
  if (q.isError || !d) return <Alert kind="red" icon="alert">{cleanError(q.error)}</Alert>;
  const partner = d.me.role === 'partner';
  return (
    <>
      <PageHead title="Earnings" right={<PartnerBadge tier={d.tier} />}
        sub={<>The Counta Partner programme. Bring businesses to Counta and earn {pct(d.tiers[0]?.rate)} of what they pay for their plan, for their first
          {' '}{d.tiers[0]?.months} months{d.tiers.length > 1 ? ', more as you grow' : ''}. Each payment's share is yours {d.terms.hold_days} days after it,
          {' '}paid into your bank on the {d.terms.payout_day}{ordinal(d.terms.payout_day)} of the month.</>} />
      {!d.enabled && <Alert kind="grey" icon="info">TaxStreem has paused the programme for now. What you earned so far is still paid.</Alert>}
      {d.requests.length > 0 && <Requests pid={pid} d={d} />}
      <div style={grid(170)}>
        <Tile label="Earned so far" value={N2(d.totals.earned)} sub={`${d.tier.paying} paying ${d.tier.paying === 1 ? 'business' : 'businesses'}`} />
        <Tile label="Waiting" value={N2(d.totals.waiting)} sub={`each amount waits ${d.terms.hold_days} days`} />
        <Tile label="Ready to pay" value={N2(Number(d.totals.ready) + Number(d.totals.in_payout))} sub={`paid from ${N2(d.terms.min_payout)}`} tone="#15803D" />
        <Tile label="Paid to you" value={N2(d.totals.paid)} sub={d.terms.wht_rate > 0 ? `before ${pct(d.terms.wht_rate)} WHT` : undefined} />
      </div>
      <div style={grid(340)}>
        <ShareLink d={d} name={home.data?.practice.name || ''} />
        <TierCard d={d} />
      </div>
      <GetPaid pid={pid} d={d} partner={partner} />
      <Referred d={d} />
      <Payouts d={d} />
      {d.listing.directory && <Directory pid={pid} d={d} partner={partner} />}
    </>
  );
}

function ordinal(n: number) { return n % 10 === 1 && n !== 11 ? 'st' : n % 10 === 2 && n !== 12 ? 'nd' : n % 10 === 3 && n !== 13 ? 'rd' : 'th'; }

function ShareLink({ d, name }: { d: PartnerHome; name: string }) {
  const toast = useToast();
  const link = `${window.location.origin}/r/${d.code}`;
  const [svg, setSvg] = useState('');
  useEffect(() => { qrSvg(link, 132).then(setSvg).catch(() => setSvg('')); }, [link]);
  const offer = d.terms.welcome.on && d.terms.welcome.percent > 0
    ? ` Sign up with my link and get ${d.terms.welcome.percent}% off your first ${d.terms.welcome.payments > 1 ? `${d.terms.welcome.payments} payments` : 'payment'}.` : '';
  const message = `${name || 'We'} keep${name ? 's' : ''} our clients' books and file their taxes in Counta, by TaxStreem.${offer} ${link}`;
  async function copy(text: string, what: string) {
    try { await navigator.clipboard.writeText(text); toast(`${what} copied`); } catch { toast('Select it and copy it yourself.', 'err'); }
  }
  return (
    <Card title="Your link" sub={<>Send it to businesses you work with. Those that join through it are yours{offer ? `, and they get ${d.terms.welcome.percent}% off` : ''}.</>}>
      <div className="row wrap" style={{ gap: 14, alignItems: 'flex-start' }}>
        {svg && <div aria-label="QR code for your link" style={{ width: 132, height: 132, flex: 'none' }} dangerouslySetInnerHTML={{ __html: svg }} />}
        <div className="stack" style={{ gap: 8, flex: '1 1 200px', minWidth: 0 }}>
          <div className="mono" style={{ fontSize: 14, wordBreak: 'break-all' }} data-testid="partner-link">{link}</div>
          <div className="faint" style={{ fontSize: 12 }}>Code <b className="mono">{d.code}</b></div>
          <div className="row wrap" style={{ gap: 8 }}>
            <button className="btn btn-primary btn-sm" onClick={() => copy(link, 'Link')}><Icon name="copy" size={14} color="#fff" />Copy link</button>
            <a className="btn btn-secondary btn-sm" href={`https://wa.me/?text=${encodeURIComponent(message)}`} target="_blank" rel="noreferrer"><Icon name="wa" size={14} />Share on WhatsApp</a>
            <button className="btn btn-ghost btn-sm" onClick={() => copy(message, 'Message')}>Copy message</button>
          </div>
        </div>
      </div>
    </Card>
  );
}

function TierCard({ d }: { d: PartnerHome }) {
  const t = d.tier;
  const tone = tierTone(t.code);
  const next = t.next;
  const nextMs = d.milestones.find((m) => !m.reached);
  const span = next ? Math.max(1, next.clients - t.clients) : 1;
  const done = next ? Math.min(1, (t.paying - t.clients) / span) : 1;
  return (
    <Card title={`${t.name} partner`} sub={`You earn ${pct(t.rate)} of each payment, for ${t.months} months from a business's first payment.`}>
      {next ? (
        <div className="stack" style={{ gap: 6 }}>
          <div style={{ fontSize: 14 }}><b>{next.clients - t.paying}</b> more paying {next.clients - t.paying === 1 ? 'business' : 'businesses'} to reach {next.name}: {pct(next.rate)} for {next.months} months.</div>
          <div style={{ height: 8, borderRadius: 4, background: '#F1F5F9', overflow: 'hidden' }} aria-label={`Progress to ${next.name}`}>
            <div style={{ width: `${Math.round(done * 100)}%`, height: '100%', background: tone.ring }} />
          </div>
        </div>
      ) : <div style={{ fontSize: 14 }}>The top tier. Thank you.</div>}
      {d.milestones.length > 0 && (
        <div className="stack" style={{ gap: 6 }}>
          <div className="mini-label">Milestone bonuses</div>
          {d.milestones.map((m) => (
            <div key={m.clients} className="row" style={{ gap: 8, fontSize: 14 }}>
              <Icon name={m.reached ? 'check' : 'gift'} size={15} color={m.reached ? '#15803D' : '#6B7280'} />
              <span className="grow">{m.clients} paying businesses</span>
              <b className="num">{N2(m.bonus)}</b>
              {m.reached && <span className={'chip ' + (m.paid ? 't-green' : 't-blue')}>{m.paid ? 'Paid' : 'Earned'}</span>}
            </div>
          ))}
          {nextMs && <div className="faint" style={{ fontSize: 12 }}>Next: {N2(nextMs.bonus)} at {nextMs.clients}.</div>}
        </div>
      )}
    </Card>
  );
}

function GetPaid({ pid, d, partner }: { pid: string; d: PartnerHome; partner: boolean }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [edit, setEdit] = useState(!d.bank);
  const [f, setF] = useState({ bank_code: d.bank?.bank_code || '', account_number: '' });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const banks = useQuery({ queryKey: ['banks'], enabled: partner && edit, staleTime: 3600_000,
    queryFn: async () => { const r = await edge<{ banks: { code: string; name: string }[] }>('payments', { action: 'banks' }); if (r.ok === false) throw new Error(r.error); return r.banks; } });
  async function save() {
    setBusy(true); setErr(null);
    const r = await edge<any>('payments', { action: 'practice_bank_save', practice_id: pid, ...f });
    setBusy(false);
    if (r.ok === false) { setErr(r.error || 'The account was not saved.'); return; }
    await qc.invalidateQueries({ queryKey: ['practice-partner', pid] });
    setEdit(false); setF({ ...f, account_number: '' });
    toast(`Saved: ${r.bank?.account_name}`);
  }
  return (
    <Card title="Getting paid" sub="Two things before the first payout: a licence TaxStreem has verified, and the bank account to pay into.">
      <div className="row" style={{ gap: 8, fontSize: 14 }}>
        <Icon name={d.verified ? 'check' : 'alert'} size={16} color={d.verified ? '#15803D' : '#B45309'} />
        <span>{d.verified ? 'Your ICAN, ANAN or CITN licence is verified.' : <>No verified licence yet. Add your licence number under <Link to={`/practice/${pid}/settings`}>Practice</Link>; TaxStreem checks it.</>}</span>
      </div>
      {d.bank && !edit && (
        <div className="row wrap" style={{ gap: 8, fontSize: 14 }} data-testid="partner-bank">
          <Icon name="landmark" size={16} color="#15803D" />
          <span className="grow" style={{ minWidth: 0 }}>Paid into <b>{d.bank.bank_name} ••••{d.bank.last4}</b>, {d.bank.account_name}
            <span className="faint" style={{ fontSize: 12, display: 'block' }}>Set by {d.bank.set_by || 'a partner'} {when(d.bank.set_at)}</span></span>
          {partner && <button className="btn btn-ghost btn-sm" onClick={() => setEdit(true)}>Change</button>}
        </div>
      )}
      {d.bank && !d.bank.name_match && <Alert kind="amber" icon="info">The bank holds this account in a name that is not the practice's or a partner's. TaxStreem checks it before paying.</Alert>}
      {!d.bank && !partner && <div className="faint" style={{ fontSize: 13 }}>A partner adds the bank account.</div>}
      {partner && edit && (
        <div className="stack" style={{ gap: 10 }}>
          <div style={grid(200)}>
            <Field label="Bank">
              <select className="input" value={f.bank_code} onChange={(e) => setF({ ...f, bank_code: e.target.value })} disabled={!banks.data}>
                <option value="">{banks.isLoading ? 'Loading banks…' : 'Choose the bank'}</option>
                {(banks.data || []).map((b) => <option key={b.code} value={b.code}>{b.name}</option>)}
              </select>
            </Field>
            <Field label="Account number"><input className="input mono" inputMode="numeric" maxLength={13} value={f.account_number} onChange={(e) => setF({ ...f, account_number: e.target.value })} placeholder="10 digits" /></Field>
          </div>
          {banks.isError && <Alert kind="amber" icon="alert">{cleanError(banks.error)}</Alert>}
          {err && <Alert kind="red" icon="alert">{err}</Alert>}
          <div className="row wrap" style={{ gap: 8 }}>
            <button className="btn btn-primary btn-sm" disabled={busy || !f.bank_code || f.account_number.replace(/\D/g, '').length !== 10} onClick={save}>{busy ? <Spinner small /> : null}Check with the bank and save</button>
            {d.bank && <button className="btn btn-ghost btn-sm" onClick={() => setEdit(false)}>Cancel</button>}
          </div>
          <div className="faint" style={{ fontSize: 12 }}>Counta asks the bank whose name the account is in. Every other partner hears when it changes.</div>
        </div>
      )}
    </Card>
  );
}

const REF_COLS = 'minmax(170px,1.4fr) minmax(110px,1fr) minmax(170px,1.2fr) 110px';
const PAY_COLS = 'minmax(150px,1.3fr) 110px 100px 110px 100px';
const STATUS: Record<string, [string, string]> = {
  waiting: ['Waiting for the first payment', 't-grey'], earning: ['Earning', 't-green'], completed: ['Done', 't-blue'], void: ['Not counted', 't-grey'],
};

function Referred({ d }: { d: PartnerHome }) {
  return (
    <Card title="Businesses you brought" sub="Each counts from its first paid plan, while it stays your client. A business already paying when it joined you, or one of your own, does not count."
      pad={false}>
      {!d.referrals.length ? <div className="card-pad muted" style={{ fontSize: 14 }}>None yet. Share your link, invite a client from Clients, or list your practice in the directory below.</div> : (
        <div className="tbl" data-testid="partner-referrals">
          <div className="tr head shade th hide-sm" style={{ gridTemplateColumns: REF_COLS }}>
            <span>Business</span><span>How</span><span>Status</span><span className="right">Earned</span>
          </div>
          {d.referrals.map((r) => {
            const [label, tone] = STATUS[r.status];
            return (
              <div key={r.id} className="tr rsp" style={{ gridTemplateColumns: REF_COLS }}>
                <span className="m-main"><b>{r.business}</b><span className="faint" style={{ display: 'block', fontSize: 12 }}>since {day(r.connected_at)}</span></span>
                <span className="faint">{SOURCE_TEXT[r.source]}</span>
                <span><span className={'chip ' + tone}>{label}</span>
                  <span className="faint" style={{ display: 'block', fontSize: 12 }}>{r.status === 'earning' && r.window_ends ? `until ${day(r.window_ends)}`
                    : r.status === 'void' ? (r.void_reason === 'self' ? 'your own business' : 'left before paying') : ''}</span></span>
                <span className="right num m-end">{N2(r.earned)}</span>
              </div>
            );
          })}
        </div>
      )}
      {d.commissions.length > 0 && (
        <div className="card-pad stack" style={{ gap: 6, borderTop: '1px solid var(--line)' }}>
          <div className="mini-label">Recent earnings</div>
          {d.commissions.slice(0, 12).map((c) => (
            <div key={c.id} className="row" style={{ gap: 8, fontSize: 14 }}>
              <Icon name={c.kind === 'bonus' ? 'gift' : 'percent'} size={14} color="#6B7280" />
              <span className="grow ellipsis" style={{ minWidth: 0 }}>{c.note}{c.rate ? <span className="faint"> · {pct(c.rate)}</span> : null}</span>
              <span className="faint hide-xs" style={{ fontSize: 12 }}>{c.status === 'waiting' ? `from ${day(c.available_at)}` : c.status === 'ready' ? 'ready' : c.status === 'in_payout' ? 'being paid' : c.status}</span>
              <b className="num">{N2(c.amount)}</b>
            </div>
          ))}
        </div>
      )}
    </Card>
  );
}

function Payouts({ d }: { d: PartnerHome }) {
  const [note, setNote] = useState<string | null>(null);
  if (!d.payouts.length) return null;
  return (
    <Card title="Payouts" pad={false}>
      <div className="tbl" data-testid="partner-payouts">
        <div className="tr head shade th hide-sm" style={{ gridTemplateColumns: PAY_COLS }}>
          <span>Month</span><span className="right">Earned</span><span className="right">WHT</span><span className="right">Paid</span><span />
        </div>
        {d.payouts.map((x) => (
          <div key={x.id} className="tr rsp" style={{ gridTemplateColumns: PAY_COLS }}>
            <span className="m-main">{monthName(x.period)}<span className="faint" style={{ display: 'block', fontSize: 12 }}>{x.status === 'paid' ? `to ${x.bank_name} ••••${x.last4}, ${day(x.paid_at)}` : 'on its way'}</span></span>
            <span className="right num faint">{N2(x.gross)}</span>
            <span className="right num faint">{x.wht > 0 ? `− ${N2(x.wht)}` : N2(0)}</span>
            <span className="right num"><b>{N2(x.net)}</b></span>
            <span className="right m-end">{x.status === 'paid' ? <button className="btn btn-ghost btn-xs" onClick={() => setNote(x.id)}>WHT note</button> : <span className="chip t-amber">Processing</span>}</span>
          </div>
        ))}
      </div>
      {note && <NoteModal id={note} onClose={() => setNote(null)} />}
    </Card>
  );
}

function esc(s: unknown) { return String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!)); }

function NoteModal({ id, onClose }: { id: string; onClose: () => void }) {
  const q = useQuery({ queryKey: ['payout-note', id], queryFn: () => rpc<PayoutNote>('practice_payout_note', { p_payout: id }) });
  const n = q.data;
  function print() {
    if (!n) return;
    const w = window.open('', '_blank');
    if (!w) return;
    w.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>WHT note ${esc(n.payout.reference)}</title><style>
      body{font-family:system-ui,sans-serif;color:#111;margin:32px;max-width:720px}h1{font-size:20px;margin:0 0 4px}td,th{padding:6px 8px;border-bottom:1px solid #ddd;text-align:left;font-size:13px}
      .r{text-align:right}table{border-collapse:collapse;width:100%;margin-top:16px}.m{color:#555;font-size:13px;line-height:1.5}</style></head><body>
      <h1>Withholding tax credit note</h1><div class="m">Reference ${esc(n.payout.reference)} · paid ${esc(fmtDay(n.payout.paid_at.slice(0, 10)))}</div>
      <p class="m"><b>From</b> ${esc(n.payer.name)}${n.payer.tin ? `, Tax ID ${esc(n.payer.tin)}` : ''}${n.payer.address ? `, ${esc(n.payer.address)}` : ''}<br>
      <b>To</b> ${esc(n.payee.name)}${n.payee.firm_reg ? `, ${esc(n.payee.firm_reg)}` : ''}${n.payee.address ? `, ${esc(n.payee.address)}` : ''}</p>
      <p class="m">Commission under the Counta Partner programme for ${esc(monthName(n.payout.period))}.</p>
      <table><tr><th>For</th><th class="r">Amount</th></tr>${n.lines.map((l) => `<tr><td>${esc(l.note)}</td><td class="r">${esc(N2(l.amount))}</td></tr>`).join('')}
      <tr><td><b>Commission</b></td><td class="r"><b>${esc(N2(n.payout.gross))}</b></td></tr>
      <tr><td>Withholding tax at ${esc(pct(n.payout.wht_rate))}</td><td class="r">${esc(N2(n.payout.wht))}</td></tr>
      <tr><td><b>Paid</b> to ${esc(n.payout.bank_name)} ••••${esc(n.payout.last4)}</td><td class="r"><b>${esc(N2(n.payout.net))}</b></td></tr></table>
      <p class="m">${esc(n.payer.name)} deducted the tax above and pays it to the tax authority. Keep this note to claim the credit.</p>
      <script>window.onload=function(){setTimeout(function(){window.print()},200)}</script></body></html>`);
    w.document.close();
  }
  return (
    <Modal onClose={onClose} width={560}>
      <ModalHead title="WHT note" sub={n ? `${n.payout.reference} · ${monthName(n.payout.period)}` : undefined} onClose={onClose} />
      <div className="card-pad stack" style={{ gap: 10 }}>
        {q.isLoading ? <Spinner /> : q.isError || !n ? <Alert kind="red" icon="alert">{cleanError(q.error)}</Alert> : (
          <>
            <div style={{ fontSize: 14, lineHeight: 1.6 }}>{n.payer.name}{n.payer.tin ? ` (Tax ID ${n.payer.tin})` : ''} paid {n.payee.name} <b>{N2(n.payout.net)}</b> on {day(n.payout.paid_at)}:
              commission of {N2(n.payout.gross)} less withholding tax of <b>{N2(n.payout.wht)}</b> at {pct(n.payout.wht_rate)}.</div>
            <div className="stack" style={{ gap: 4 }}>{n.lines.map((l, i) => <div key={i} className="row" style={{ gap: 8, fontSize: 13 }}><span className="grow">{l.note}</span><span className="num">{N2(l.amount)}</span></div>)}</div>
            <div><button className="btn btn-primary btn-sm" onClick={print}><Icon name="printer" size={14} color="#fff" />Print or save as PDF</button></div>
          </>
        )}
      </div>
    </Modal>
  );
}

function Directory({ pid, d, partner }: { pid: string; d: PartnerHome; partner: boolean }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [blurb, setBlurb] = useState(d.listing.blurb || '');
  const [busy, setBusy] = useState(false);
  async function save(listed: boolean) {
    setBusy(true);
    try { await rpc('practice_listing_save', { p_practice: pid, p: { listed, blurb } }); await qc.invalidateQueries({ queryKey: ['practice-partner', pid] }); toast(listed ? 'Your practice is in the directory' : 'Taken out of the directory'); }
    catch (e) { toast(cleanError(e), 'err'); }
    setBusy(false);
  }
  return (
    <Card title="The partner directory" sub="Businesses choosing an accountant in Counta see listed partners with their tier, and ask one to take them on.">
      {!d.verified && <Alert kind="grey" icon="info">The directory lists practices with a verified licence.</Alert>}
      <Field label="What you do, for whom" hint={`${blurb.length}/300 · shown with your practice's name${d.listing.state ? ` and ${d.listing.state}` : ''}`}>
        <textarea className="input" maxLength={300} disabled={!partner} value={blurb} onChange={(e) => setBlurb(e.target.value)} style={{ minHeight: 64 }}
          placeholder="Bookkeeping, VAT and annual returns for retailers and restaurants in Lagos." />
      </Field>
      {partner ? (
        <div className="row wrap" style={{ gap: 8 }}>
          {d.listing.listed ? <>
            <span className="chip t-green">Listed</span>
            <button className="btn btn-secondary btn-sm" disabled={busy} onClick={() => save(true)}>Save the description</button>
            <button className="btn btn-ghost btn-sm" disabled={busy} onClick={() => save(false)}>Take us out</button>
          </> : <button className="btn btn-primary btn-sm" disabled={busy || !d.verified} onClick={() => save(true)}>{busy ? <Spinner small /> : null}List our practice</button>}
        </div>
      ) : <div className="faint" style={{ fontSize: 13 }}>{d.listing.listed ? 'Listed.' : 'Not listed.'} A partner changes this.</div>}
    </Card>
  );
}

function Requests({ pid, d }: { pid: string; d: PartnerHome }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [busy, setBusy] = useState<string | null>(null);
  async function answer(id: string, yes: boolean) {
    setBusy(id);
    try {
      await rpc('practice_directory_answer', { p_client: id, p_accept: yes });
      await Promise.all(['practice-partner', 'practice-home'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
      toast(yes ? 'They are now your client' : 'Declined; they will hear');
    } catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  return (
    <Card title={`${d.requests.length} ${d.requests.length === 1 ? 'business asks' : 'businesses ask'} you to be their accountant`} sub="From the partner directory. Saying yes gives your people their places in the business.">
      {d.requests.map((r) => (
        <div key={r.client_id} className="row wrap" style={{ gap: 8 }} data-testid="partner-request">
          <div className="grow" style={{ minWidth: 0 }}><b>{r.business}</b>
            <span className="faint" style={{ display: 'block', fontSize: 13 }}>{serviceList(r.services)}{r.billing === 'practice' ? ' · asks you to pay for its plan' : ''} · {when(r.created_at)}</span>
            {r.note && <span style={{ display: 'block', fontSize: 13 }}>“{r.note}”</span>}</div>
          <button className="btn btn-primary btn-sm" disabled={busy !== null} onClick={() => answer(r.client_id, true)}>{busy === r.client_id ? <Spinner small /> : null}Take them on</button>
          <button className="btn btn-ghost btn-sm" disabled={busy !== null} onClick={() => answer(r.client_id, false)}>Decline</button>
        </div>
      ))}
    </Card>
  );
}

// A note on the Clients page when businesses asked from the directory.
export function RequestsNote({ pid }: { pid: string }) {
  const q = usePracticePartner(pid);
  const n = q.data?.requests.length || 0;
  if (!n) return null;
  return (
    <Alert kind="blue" icon="users">
      {n} {n === 1 ? 'business asks' : 'businesses ask'} you to be their accountant from the partner directory. <Link to={`/practice/${pid}/earnings`}>Answer under Earnings</Link>.
    </Alert>
  );
}
