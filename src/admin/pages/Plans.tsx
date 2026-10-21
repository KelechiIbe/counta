// Plans and the modules they are made of. A module is a feature a business has or not, or a monthly limit on something
// counted (sales, AI reads, WhatsApp messages...). Each plan says, for every module, whether it is included, the limit, and
// whether going past it is stopped or only warned about. The calculator prices the limits against what the services cost.
import { useEffect, useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { rpc } from '../../lib/supabase';
import { N2, when } from '../../lib/format';
import { useToast } from '../../state/session';
import { Alert, Field, Modal, ModalHead, SkeletonRows, Spinner } from '../../components/ui';
import { pct, tidyError } from '../api';
import { Card, grid, PageHead } from '../ui';

const usePlans = () => useQuery({ queryKey: ['admin-plans'], queryFn: () => rpc<any>('admin_plans') });
const FEATURE_LABEL: Record<string, string> = { payments: 'Payments', bulk_payments: 'Bulk payments', martina: 'Martina', phone_calls: 'Phone calls', payment_voice: 'Spoken announcements',
  ai_reading: 'AI reading', email: 'Email to customers', whatsapp: 'WhatsApp to customers', bank_feeds: 'Bank feeds', supplier_portal: 'Supplier invoice portal' };
const METER_LABEL: Record<string, string> = { sales: 'Sales recorded', ai_reads: 'Documents read by AI', assistant: 'Questions to Martina', call_minutes: 'Phone call minutes',
  whatsapp: 'WhatsApp messages', emails: 'Emails', tin_checks: 'Tax ID checks', supplier_invoices: 'Supplier invoices', payouts: 'Payouts', users: 'Team members (now)',
  locations: 'Branches (now)', bank_feeds: 'Linked bank accounts (now)' };

export default function Plans() {
  const q = usePlans();
  const [editing, setEditing] = useState<any | null>(null);
  const [module, setModule] = useState<any | null>(null);
  const d = q.data;
  return (
    <div className="stack" style={{ gap: 18 }}>
      <PageHead title="Plans" sub="Every business is on a plan: the one it pays for, or the default. Prices include VAT. A module a plan does not mention is included with no limit, so adding a module never takes anything away by itself."
        right={<button className="btn btn-primary btn-sm" onClick={() => setEditing({ price_month: 0, target_margin: 0.6, trial_days: 0, public: true, active: true, sort: 100 })}>New plan</button>} />
      {q.isLoading ? <SkeletonRows n={6} /> : !d ? <Alert kind="red" icon="alert">{tidyError(q.error)}</Alert> : (
        <>
          <div style={grid(260)}>
            {(d.plans || []).map((p: any) => (
              <div key={p.id} className="card card-pad stack" style={{ gap: 8 }}>
                <div className="row" style={{ justifyContent: 'space-between', gap: 6 }}>
                  <b style={{ fontSize: 16 }}>{p.name}</b>
                  <span className="row" style={{ gap: 4 }}>{p.is_default && <span className="chip t-blue">default</span>}{!p.public && <span className="chip t-grey">hidden</span>}{!p.active && <span className="chip t-grey">off</span>}</span>
                </div>
                <div><span style={{ fontSize: 20, fontWeight: 700 }}>{Number(p.price_month) > 0 ? N2(p.price_month) : 'Free'}</span>{Number(p.price_month) > 0 && <span className="muted" style={{ fontSize: 12 }}> a month · {N2(p.price_year)} a year</span>}</div>
                <div className="muted" style={{ fontSize: 12.5 }}>{p.businesses} business{Number(p.businesses) === 1 ? '' : 'es'} · {N2(p.mrr)} a month · target margin {pct(p.target_margin, 0)}{p.trial_days ? ` · ${p.trial_days}-day trial` : ''}</div>
                <div className="stack" style={{ gap: 2, fontSize: 12 }}>
                  {(p.entitlements || []).filter((e: any) => !e.included || e.quota != null).slice(0, 8).map((e: any) => (
                    <span key={e.module} className="row" style={{ justifyContent: 'space-between' }}><span className="faint">{e.name}</span>
                      <span>{!e.included ? 'not included' : `${Number(e.quota).toLocaleString('en-NG')}${e.enforce === 'block' ? '' : ', warn'}`}</span></span>
                  ))}
                  {!(p.entitlements || []).some((e: any) => !e.included || e.quota != null) && <span className="faint">Everything, no limits</span>}
                </div>
                <button className="btn btn-secondary btn-sm" style={{ marginTop: 'auto' }} onClick={() => setEditing(p)}>Edit</button>
              </div>
            ))}
          </div>
          <Card title="Modules" sub="What plans are made of. A feature switches a part of Counta on or off for the plan; a quota counts something each month (or now, for people, branches and linked accounts)."
            right={<button className="btn btn-secondary btn-sm" onClick={() => setModule({ kind: 'quota', active: true, sort: 100 })}>New module</button>} pad={false}>
            <div className="tbl"><div className="tr head shade th hide-sm" style={{ gridTemplateColumns: 'minmax(200px,1.5fr) 200px 140px 90px 70px', minWidth: 720 }}>
              <span>Module</span><span>Counts or controls</span><span className="right">Cost of one unit</span><span>State</span><span /></div>
              {(d.modules || []).map((m: any) => (
                <div key={m.key} className="tr" style={{ gridTemplateColumns: 'minmax(200px,1.5fr) 200px 140px 90px 70px', minWidth: 720 }}>
                  <span><b>{m.name}</b><span className="faint" style={{ display: 'block', fontSize: 11 }}>{m.key}{m.what ? ` · ${m.what}` : ''}</span></span>
                  <span className="muted">{m.kind === 'feature' ? FEATURE_LABEL[m.feature] || m.feature : `${METER_LABEL[m.meter] || m.meter}${m.unit ? ` · ${m.unit}` : ''}`}</span>
                  <span className="right num">{m.unit_cost_ngn != null ? `${N2(m.unit_cost_ngn)} set` : <span className="faint">from rates</span>}</span>
                  <span>{m.active ? <span className="chip t-green">on</span> : <span className="chip t-grey">off</span>}</span>
                  <span><button className="btn btn-ghost btn-xs" onClick={() => setModule(m)}>Edit</button></span>
                </div>
              ))}
            </div>
          </Card>
        </>
      )}
      {editing && d && <PlanEditor plan={editing} modules={(d.modules || []).filter((m: any) => m.active)} plans={d.plans || []} onClose={() => setEditing(null)} />}
      {module && d && <ModuleEditor m={module} features={d.features || []} meters={d.meters || []} taken={(d.modules || []).map((x: any) => x.key)} onClose={() => setModule(null)} />}
    </div>
  );
}

type Ent = { included: boolean; quota: string; enforce: 'block' | 'warn' };

// Codes and keys are made from the name, so nobody has to invent one: "Growth Plus" becomes growth-plus. The database takes
// a plan code that starts with a letter and runs 2 to 30 characters, and a module key that starts with a letter and runs 2 to 40.
export const PLAN_CODE = /^[a-z][a-z0-9_-]{1,29}$/;
export const MODULE_KEY = /^[a-z][a-z0-9_]{1,39}$/;
export function slugFrom(name: string, sep: '-' | '_', max: number, prefix: string) {
  let c = name.toLowerCase().normalize('NFKD').replace(/[\u0300-\u036f]/g, '').replace(/[^a-z0-9]+/g, sep).split(sep).filter(Boolean).join(sep);
  if (c && !/^[a-z]/.test(c)) c = prefix + sep + c;
  c = c.slice(0, max).replace(/[-_]+$/, '');
  return c.length >= 2 || !c ? c : `${c}${sep}${prefix}`;
}
// Amounts as people type them ("35,000", "₦35000") become plain numbers; anything else is left for the check to name.
const plainNum = (v: string) => String(v ?? '').replace(/[,\s₦]/g, '');
const isMoney = (v: string) => /^\d+(\.\d{1,2})?$/.test(plainNum(v));
const isWhole = (v: string) => /^\d+$/.test(plainNum(v));

function PlanEditor({ plan, modules, plans, onClose }: { plan: any; modules: any[]; plans: any[]; onClose: () => void }) {
  const toast = useToast();
  const qc = useQueryClient();
  const isNew = !plan.id;
  const [f, setF] = useState<any>({ code: plan.code || '', name: plan.name || '', description: plan.description || '', price_month: String(Number(plan.price_month || 0)),
    price_year: plan.price_year != null && plan.id ? String(Number(plan.price_year)) : '', trial_days: String(plan.trial_days || 0), target_margin: String(Math.round(Number(plan.target_margin ?? 0.6) * 100)),
    public: plan.public !== false, active: plan.active !== false, is_default: !!plan.is_default, sort: String(plan.sort ?? 100) });
  const [ents, setEnts] = useState<Record<string, Ent>>(() => Object.fromEntries(modules.map((m) => {
    const e = (plan.entitlements || []).find((x: any) => x.module === m.key);
    return [m.key, { included: e ? !!e.included : true, quota: e?.quota != null ? String(Number(e.quota)) : '', enforce: (e?.enforce || 'warn') as 'block' | 'warn' }];
  })));
  const [busy, setBusy] = useState(false);
  // A new plan's code follows its name until someone types a code of their own.
  const [ownCode, setOwnCode] = useState(!isNew);
  const set = (k: string, v: any) => setF((x: any) => ({ ...x, [k]: v }));
  const setName = (v: string) => setF((x: any) => ({ ...x, name: v, ...(ownCode ? {} : { code: slugFrom(v, '-', 30, 'plan') }) }));
  const setCode = (v: string) => {
    const code = v.toLowerCase().replace(/[^a-z0-9_-]/g, '').slice(0, 30);
    setOwnCode(code !== '');
    setF((x: any) => ({ ...x, code: code || slugFrom(x.name, '-', 30, 'plan') }));
  };
  const setE = (k: string, p: Partial<Ent>) => setEnts((x) => ({ ...x, [k]: { ...x[k], ...p } }));
  // The calculator, asked again a moment after the price, margin or a quota changes.
  const quotas = useMemo(() => Object.fromEntries(Object.entries(ents).filter(([, e]) => e.included && e.quota !== '').map(([k, e]) => [k, Number(e.quota)])), [ents]);
  const [calcArgs, setCalcArgs] = useState({ price_month: Number(plainNum(f.price_month)) || 0, target_margin: Number(f.target_margin) / 100, quotas });
  useEffect(() => { const t = window.setTimeout(() => setCalcArgs({ price_month: Number(plainNum(f.price_month)) || 0, target_margin: Math.min(Math.max(Number(f.target_margin) || 0, 0), 99) / 100, quotas }), 400); return () => window.clearTimeout(t); },
    [f.price_month, f.target_margin, quotas]);
  const calc = useQuery({ queryKey: ['admin-plan-calc', calcArgs], queryFn: () => rpc<any>('admin_plan_calc', { p: calcArgs }) });
  const c = calc.data;
  const row = (k: string) => (c?.modules || []).find((x: any) => x.module === k);
  const feats = modules.filter((m) => m.kind === 'feature'), qs = modules.filter((m) => m.kind === 'quota');
  // Everything the database would refuse, said in words before Save is pressed.
  const codeErr = !f.code ? null : !PLAN_CODE.test(f.code) ? 'Start with a letter; use 2 to 30 lowercase letters, numbers or hyphens.'
    : plans.some((p) => p.code === f.code && p.id !== plan.id) ? `Another plan already uses ${f.code}. Change the name or the code.` : null;
  const name = f.name.trim();
  const problem = !name ? 'Give the plan a name.' : name.length < 2 ? 'The name needs at least 2 letters.'
    : !f.code ? 'The plan needs a code.' : codeErr ? `Code: ${codeErr}`
    : !isMoney(f.price_month) ? 'Write the monthly price as a number, like 35000.'
    : f.price_year !== '' && !isMoney(f.price_year) ? 'Write the yearly price as a number, like 350000, or leave it empty.'
    : !isWhole(f.trial_days) || Number(plainNum(f.trial_days)) > 90 ? 'A free trial runs from 0 to 90 days.'
    : !/^\d+(\.\d+)?$/.test(plainNum(f.target_margin)) || Number(plainNum(f.target_margin)) >= 100 ? 'The target margin is a percentage from 0 to 99.'
    : !/^-?\d+$/.test(plainNum(f.sort)) ? 'The order shown is a whole number.'
    : qs.find((m) => ents[m.key].included && ents[m.key].quota !== '' && !/^\d+(\.\d+)?$/.test(ents[m.key].quota)) ? 'Each limit is a number, or empty for no limit.'
    : null;
  async function save() {
    if (problem) { toast(problem, 'err'); return; }
    setBusy(true);
    try {
      await rpc('admin_save_plan', { p: { id: plan.id || null, code: f.code, name, description: f.description, price_month: plainNum(f.price_month), price_year: plainNum(f.price_year) || null,
        trial_days: plainNum(f.trial_days), target_margin: Math.min(Math.max(Number(plainNum(f.target_margin)) || 0, 0), 99) / 100, public: f.public, active: f.active, is_default: f.is_default, sort: plainNum(f.sort),
        entitlements: modules.map((m) => ({ module: m.key, included: ents[m.key].included, quota: m.kind === 'quota' && ents[m.key].quota !== '' ? ents[m.key].quota : null, enforce: ents[m.key].enforce })) } });
      toast(`${f.name} saved`); await qc.invalidateQueries({ queryKey: ['admin-plans'] }); onClose();
    } catch (e) { toast(tidyError(e), 'err'); }
    setBusy(false);
  }
  function applySuggestions() {
    setEnts((x) => {
      const n = { ...x };
      for (const r of c?.modules || []) if (r.suggested != null && n[r.module]?.included) n[r.module] = { ...n[r.module], quota: String(r.suggested) };
      return n;
    });
  }
  return (
    <Modal onClose={onClose} width={980}>
      <ModalHead title={isNew ? 'New plan' : `Edit ${plan.name}`} sub={isNew ? undefined : `${plan.businesses ?? 0} businesses on it`} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 14 }}>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1.4fr 1fr 1fr 1fr', gap: 10 }}>
          <Field label="Name"><input className="input" value={f.name} maxLength={40} onChange={(e) => setName(e.target.value)} /></Field>
          <Field label="Code" hint={codeErr ? undefined : isNew && !ownCode ? 'Made from the name' : 'Lowercase, no spaces'} error={codeErr}><input className="input mono" value={f.code} maxLength={30} onChange={(e) => setCode(e.target.value)} /></Field>
          <Field label="A month (₦, VAT in)"><input className="input num" inputMode="decimal" value={f.price_month} onChange={(e) => set('price_month', e.target.value)} /></Field>
          <Field label="A year (₦)" hint="Empty: 12 months"><input className="input num" inputMode="decimal" value={f.price_year} onChange={(e) => set('price_year', e.target.value)} /></Field>
          <Field label="Target margin (%)"><input className="input num" inputMode="decimal" value={f.target_margin} onChange={(e) => set('target_margin', e.target.value)} /></Field>
        </div>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '2fr 1fr 1fr', gap: 10 }}>
          <Field label="What businesses read"><input className="input" value={f.description} maxLength={400} onChange={(e) => set('description', e.target.value)} /></Field>
          <Field label="Free trial (days)"><input className="input num" inputMode="numeric" value={f.trial_days} onChange={(e) => set('trial_days', e.target.value)} /></Field>
          <Field label="Order shown"><input className="input num" inputMode="numeric" value={f.sort} onChange={(e) => set('sort', e.target.value)} /></Field>
        </div>
        <div className="row wrap" style={{ gap: 16 }}>
          <label className="check"><input type="checkbox" checked={f.public} onChange={(e) => set('public', e.target.checked)} />Businesses can choose it</label>
          <label className="check"><input type="checkbox" checked={f.active} disabled={plan.is_default} onChange={(e) => set('active', e.target.checked)} />On</label>
          <label className="check"><input type="checkbox" checked={f.is_default} disabled={plan.is_default} onChange={(e) => set('is_default', e.target.checked)} />The default plan (every business without another)</label>
        </div>

        <div className="stack" style={{ gap: 6 }}>
          <div className="label">Features</div>
          <div style={grid(230)}>
            {feats.map((m) => (
              <div key={m.key} className="row" style={{ gap: 8, justifyContent: 'space-between', border: '1px solid var(--line)', borderRadius: 10, padding: '6px 10px' }}>
                <label className="check" style={{ minWidth: 0 }}><input type="checkbox" checked={ents[m.key].included} onChange={(e) => setE(m.key, { included: e.target.checked })} /><span className="ellipsis">{m.name}</span></label>
                {!ents[m.key].included && <select className="input input-sm" style={{ width: 92 }} value={ents[m.key].enforce} onChange={(e) => setE(m.key, { enforce: e.target.value as any })} aria-label={`When ${m.name} is not included`}>
                  <option value="block">turned off</option><option value="warn">left on</option></select>}
              </div>
            ))}
          </div>
        </div>

        <div className="stack" style={{ gap: 6 }}>
          <div className="row wrap" style={{ justifyContent: 'space-between' }}>
            <div className="label">Limits {calc.isFetching && <Spinner small />}</div>
            {c && <button className="btn btn-ghost btn-xs" onClick={applySuggestions}>Use the suggested limits</button>}
          </div>
          <div className="card" style={{ overflow: 'hidden' }}>
            <div className="tbl"><div className="tr head shade th hide-sm" style={{ gridTemplateColumns: 'minmax(180px,1.4fr) 70px 110px 110px 110px 110px 110px 110px', minWidth: 900 }}>
              <span>Module</span><span>In</span><span className="right">Limit</span><span>Past it</span><span className="right">One unit</span><span className="right">Average use</span><span className="right">Suggested</span><span className="right">Cost at limit</span></div>
              {qs.map((m) => {
                const r = row(m.key); const e = ents[m.key];
                return (
                  <div key={m.key} className="tr" style={{ gridTemplateColumns: 'minmax(180px,1.4fr) 70px 110px 110px 110px 110px 110px 110px', minWidth: 900 }}>
                    <span><b>{m.name}</b><span className="faint" style={{ display: 'block', fontSize: 11 }}>{m.unit}</span></span>
                    <span><input type="checkbox" checked={e.included} onChange={(ev) => setE(m.key, { included: ev.target.checked })} aria-label={`${m.name} included`} /></span>
                    <span><input className="input input-sm num" disabled={!e.included} placeholder="no limit" inputMode="numeric" value={e.quota} onChange={(ev) => setE(m.key, { quota: ev.target.value.replace(/[^0-9.]/g, '') })} aria-label={`${m.name} limit`} /></span>
                    <span><select className="input input-sm" value={e.enforce} disabled={!e.included || e.quota === ''} onChange={(ev) => setE(m.key, { enforce: ev.target.value as any })} aria-label={`Past the ${m.name} limit`}>
                      <option value="block">stop</option><option value="warn">warn</option></select></span>
                    <span className="right num">{r ? N2(r.unit_cost_ngn) : '—'}</span>
                    <span className="right num faint">{r ? Number(r.average).toLocaleString('en-NG') : '—'}</span>
                    <span className="right num">{r?.suggested != null ? Number(r.suggested).toLocaleString('en-NG') : <span className="faint">—</span>}</span>
                    <span className="right num">{r?.cost_at_quota != null ? N2(r.cost_at_quota) : <span className="faint">—</span>}</span>
                  </div>
                );
              })}
            </div>
          </div>
          {c && (
            <div style={grid(190)}>
              <div className="card card-pad"><div className="mini-label">Price without VAT</div><div className="num" style={{ fontSize: 18, fontWeight: 700 }}>{N2(c.price_net)}</div></div>
              <div className="card card-pad"><div className="mini-label">Budget for services</div><div className="num" style={{ fontSize: 18, fontWeight: 700 }}>{N2(c.budget_ngn)}</div><div className="faint" style={{ fontSize: 11 }}>after the margin and {N2(c.fixed_share_ngn)} of fixed bills</div></div>
              <div className="card card-pad"><div className="mini-label">Margin if every limit is used</div><div className="num" style={{ fontSize: 18, fontWeight: 700, color: c.margin_full != null && Number(c.margin_full) < Number(c.target_margin) ? '#B91C1C' : '#15803D' }}>{c.margin_full == null ? '—' : pct(c.margin_full, 1)}</div></div>
              <div className="card card-pad"><div className="mini-label">Margin at average use</div><div className="num" style={{ fontSize: 18, fontWeight: 700 }}>{c.margin_average == null ? '—' : pct(c.margin_average, 1)}</div></div>
            </div>
          )}
          {c && (c.unlimited_costed || []).length > 0 && <Alert kind="amber" icon="alert">No limit on {(c.unlimited_costed as string[]).join(', ')}: each costs money with every use, so the margin at full use cannot be known.</Alert>}
          <div className="faint" style={{ fontSize: 12 }}>One unit's cost comes from the rates on the Cost of service page and the last 30 days of use (or a cost set on the module). The suggestion splits the budget the way the average business's costs are made up.</div>
        </div>
      </div>
      <div className="modal-ft m-wrap">{problem && <span className="grow" style={{ color: '#B91C1C', fontSize: 13 }} role="status">{problem}</span>}
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy || !!problem} onClick={save}>{busy ? 'Saving…' : 'Save the plan'}</button></div>
    </Modal>
  );
}

function ModuleEditor({ m, features, meters, taken, onClose }: { m: any; features: string[]; meters: string[]; taken: string[]; onClose: () => void }) {
  const toast = useToast();
  const qc = useQueryClient();
  const isNew = !m.key;
  const [f, setF] = useState<any>({ ...m, unit_cost_ngn: m.unit_cost_ngn != null ? String(Number(m.unit_cost_ngn)) : '' });
  const [busy, setBusy] = useState(false);
  // A new module's key follows its name until someone types a key of their own. An existing key never changes.
  const [ownKey, setOwnKey] = useState(!isNew);
  const set = (k: string, v: any) => setF((x: any) => ({ ...x, [k]: v }));
  const setName = (v: string) => setF((x: any) => ({ ...x, name: v, ...(ownKey ? {} : { key: slugFrom(v, '_', 40, 'module') }) }));
  const setKey = (v: string) => {
    const key = v.toLowerCase().replace(/[^a-z0-9_]/g, '').slice(0, 40);
    setOwnKey(key !== '');
    setF((x: any) => ({ ...x, key: key || slugFrom(x.name || '', '_', 40, 'module') }));
  };
  // Saving a new module under a key already in use would overwrite that module, so it is stopped here.
  const keyErr = !isNew || !f.key ? null : !MODULE_KEY.test(f.key) ? 'Start with a letter; use 2 to 40 lowercase letters, numbers or underscores.'
    : taken.includes(f.key) ? `A module called ${f.key} already exists. Change the name or the key.` : null;
  const nm = String(f.name || '').trim();
  const problem = !nm ? 'Give the module a name.' : nm.length < 2 ? 'The name needs at least 2 letters.' : !f.key ? 'The module needs a key.' : keyErr ? `Key: ${keyErr}`
    : f.kind === 'quota' && !f.meter ? 'Choose what it counts.' : f.kind === 'feature' && !f.feature ? 'Choose what it switches.'
    : f.unit_cost_ngn !== '' && !/^\d+(\.\d{1,4})?$/.test(plainNum(f.unit_cost_ngn)) ? 'Write the cost of one unit as a number, like 5.50, or leave it empty.'
    : !/^-?\d+$/.test(plainNum(String(f.sort ?? 100))) ? 'The order is a whole number.' : null;
  async function save() {
    if (problem) { toast(problem, 'err'); return; }
    setBusy(true);
    try { await rpc('admin_save_module', { p: { key: f.key, name: nm, kind: f.kind, meter: f.kind === 'quota' ? f.meter : null, feature: f.kind === 'feature' ? f.feature : null,
      unit: f.unit || '', what: f.what || '', unit_cost_ngn: plainNum(f.unit_cost_ngn), sort: plainNum(String(f.sort ?? 100)), active: f.active } });
      toast('Module saved'); await qc.invalidateQueries({ queryKey: ['admin-plans'] }); onClose(); }
    catch (e) { toast(tidyError(e), 'err'); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={560}>
      <ModalHead title={m.key ? m.name : 'New module'} sub={m.updated_at ? `Changed ${when(m.updated_at)}` : undefined} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 10 }}>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1.4fr', gap: 10 }}>
          <Field label="Name"><input className="input" value={f.name || ''} maxLength={60} onChange={(e) => setName(e.target.value)} /></Field>
          <Field label="Key" hint={keyErr ? undefined : isNew && !ownKey ? 'Made from the name' : undefined} error={keyErr}><input className="input mono" disabled={!isNew} value={f.key || ''} maxLength={40} onChange={(e) => setKey(e.target.value)} /></Field>
        </div>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1.4fr', gap: 10 }}>
          <Field label="Kind"><select className="input" value={f.kind} disabled={!!m.key} onChange={(e) => set('kind', e.target.value)}><option value="quota">A limit</option><option value="feature">A feature</option></select></Field>
          {f.kind === 'quota' ? <Field label="Counts"><select className="input" value={f.meter || ''} onChange={(e) => set('meter', e.target.value)}><option value="">Choose</option>{meters.map((x) => <option key={x} value={x}>{METER_LABEL[x] || x}</option>)}</select></Field>
            : <Field label="Switches"><select className="input" value={f.feature || ''} onChange={(e) => set('feature', e.target.value)}><option value="">Choose</option>{features.map((x) => <option key={x} value={x}>{FEATURE_LABEL[x] || x}</option>)}</select></Field>}
        </div>
        {f.kind === 'quota' && <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr', gap: 10 }}>
          <Field label="Unit, as businesses read it"><input className="input" value={f.unit || ''} onChange={(e) => set('unit', e.target.value)} placeholder="messages a month" /></Field>
          <Field label="Cost of one unit (₦)" hint="Empty: from the rates"><input className="input num" inputMode="decimal" value={f.unit_cost_ngn} onChange={(e) => set('unit_cost_ngn', e.target.value)} /></Field>
        </div>}
        <Field label="What it is"><input className="input" value={f.what || ''} onChange={(e) => set('what', e.target.value)} /></Field>
        <div className="row" style={{ gap: 16 }}>
          <Field label="Order"><input className="input num" style={{ width: 90 }} value={f.sort ?? 100} onChange={(e) => set('sort', e.target.value)} /></Field>
          <label className="check" style={{ marginTop: 20 }}><input type="checkbox" checked={f.active !== false} onChange={(e) => set('active', e.target.checked)} />On</label>
        </div>
      </div>
      <div className="modal-ft m-wrap">{problem && <span className="grow" style={{ color: '#B91C1C', fontSize: 13 }} role="status">{problem}</span>}
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy || !!problem} onClick={save}>Save</button></div>
    </Modal>
  );
}
