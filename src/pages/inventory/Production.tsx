import { useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { can, useInventory, useSession } from '../../state/session';
import { useAction } from '../../lib/queries';
import { rpc } from '../../lib/supabase';
import { N, fmtDay, num, uuid, when } from '../../lib/format';
import { pluralUnit, puAbbr, qtyLabel } from '../../lib/domain';
import { jobNoun, recipeNeeds, recipeUnitCost, round3, STATUS_LABEL, useJobs, type Job, type Recipe } from '../../lib/jobs';
import type { Item } from '../../lib/types';
import { Icon } from '../../components/Icon';
import { ItemPicker } from '../../components/ItemPicker';
import { Alert, Annot, Chip, Drawer, Field, Label, Modal, ModalHead, Seg, SkeletonRows, XButton } from '../../components/ui';

const COLS = '100px minmax(200px,1.5fr) 130px 150px 120px 120px 110px';
type Tab = 'open' | 'closed' | 'recipes';

export default function Production() {
  const { data: inv } = useInventory();
  const jobs = useJobs();
  const [params, setParams] = useSearchParams();
  const [tab, setTab] = useState<Tab>('open');
  const [active, setActive] = useState<string | null>(params.get('open'));
  const [creating, setCreating] = useState<Job['kind'] | null>(null);
  const [recipeFor, setRecipeFor] = useState<string | null | undefined>(undefined);
  useEffect(() => { if (params.get('open')) { setActive(params.get('open')); setParams({}, { replace: true }); } }, [params.get('open')]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!inv) return null;
  const canIssue = can(inv, 'issue_stock');
  const costs = inv.can_see_costs;
  const list = (jobs.data?.jobs || []).filter((j) => (tab === 'open' ? j.status === 'open' : j.status !== 'open'));
  const job = active ? jobs.data?.jobs.find((j) => j.id === active) || null : null;
  const locName = (id: string) => inv.locations.find((l) => l.id === id)?.name || '—';
  const itemName = (id: string | null) => inv.items.find((i) => i.id === id)?.name || '—';
  return (
    <div className="container">
      <div className="row m-wrap" style={{ justifyContent: 'space-between', gap: 12 }}>
        <div className="ink3" style={{ fontSize: 14, maxWidth: 700, lineHeight: 1.5 }}>
          Issue raw materials, packaging and spares out of stock to a production run or a job. A run carries its cost in work in progress until you record what it made; a job charges the stock to its own account when it leaves the store.
        </div>
        {canIssue ? (
          <div className="row" style={{ gap: 8 }}>
            <button className="btn btn-secondary" onClick={() => setCreating('job')}><Icon name="wrench" size={16} />New job</button>
            <button className="btn btn-primary" onClick={() => setCreating('production')}><Icon name="factory" size={16} color="#fff" />New production run</button>
          </div>
        ) : <Annot>Ask the owner for the Issue to jobs permission</Annot>}
      </div>
      <Seg value={tab} onChange={setTab} options={[
        { id: 'open', label: `Open · ${(jobs.data?.jobs || []).filter((j) => j.status === 'open').length}` },
        { id: 'closed', label: 'Closed lately' }, { id: 'recipes', label: `Recipes · ${jobs.data?.recipes.length || 0}` }]} />

      {tab !== 'recipes' ? (
        <div className="card" style={{ overflow: 'hidden' }}>
          <div className="tbl">
            <div className="tr head th rsp" style={{ gridTemplateColumns: COLS, minWidth: 900 }}>
              <span>Ref</span><span>Name</span><span>Branch</span><span>{tab === 'open' ? 'Makes / charged to' : 'Made / charged to'}</span><span>Materials</span><span>{tab === 'open' ? 'Opened' : 'Closed'}</span><span>Status</span>
            </div>
            {jobs.isLoading && !jobs.data && <SkeletonRows n={3} />}
            {list.map((j) => (
              <div key={j.id} className="tr click rsp" onClick={() => setActive(j.id)} style={{ gridTemplateColumns: COLS, minWidth: 900 }}>
                <span style={{ fontWeight: 600, color: '#0072F5' }}>{j.ref}</span>
                <span className="ellipsis m-main m-first" style={{ fontWeight: 500 }}>
                  <Icon name={j.kind === 'production' ? 'factory' : 'wrench'} size={14} color="#6B7280" style={{ marginRight: 6, verticalAlign: -2 }} />{j.name}
                </span>
                <span className="ink3">{locName(j.location_id)}</span>
                <span className="ink3 ellipsis" data-label={j.kind === 'production' ? 'Makes' : 'Charged to'}>
                  {j.kind === 'production'
                    ? `${num(Number(j.produced_qty ?? j.planned_qty ?? 0))} × ${itemName(j.output_item_id)}`
                    : `${j.charge_account} ${j.charge_account_name || ''}`}
                </span>
                <span data-label="Materials">{j.materials.length ? (costs && j.materials_value != null ? N(j.materials_value) : `${j.materials.length} item${j.materials.length === 1 ? '' : 's'}`) : '—'}</span>
                <span className="muted">{fmtDay((tab === 'open' ? j.created_at : j.closed_at || j.created_at).slice(0, 10))}</span>
                <span className="m-end"><Chip label={STATUS_LABEL[j.status]} t={j.status === 'open' ? 't-blue' : j.status === 'completed' ? 't-green' : 't-grey'} /></span>
              </div>
            ))}
            {jobs.data && !list.length && (
              <div className="muted" style={{ padding: 24, fontSize: 14, lineHeight: 1.6 }}>
                {tab === 'open' ? 'Nothing open. Start a production run to turn materials into a finished item, or a job to charge spares and supplies to a repair, a project or a customer.' : 'Nothing closed in the last 60 days.'}
              </div>
            )}
          </div>
        </div>
      ) : (
        <RecipesTab onEdit={(id) => setRecipeFor(id)} />
      )}

      {job && <JobDrawer job={job} onClose={() => setActive(null)} onRecipe={(id) => setRecipeFor(id)} />}
      {creating && <NewJobModal kind={creating} onClose={() => setCreating(null)} onCreated={(id) => { setCreating(null); setTab('open'); setActive(id); }} />}
      {recipeFor !== undefined && <RecipeModal itemId={recipeFor} onClose={() => setRecipeFor(undefined)} />}
    </div>
  );
}

// ---------------------------------------------------------------------------
function NewJobModal({ kind: initial, onClose, onCreated }: { kind: Job['kind']; onClose: () => void; onCreated: (id: string) => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const jobs = useJobs();
  const { run, busy } = useAction();
  const [kind, setKind] = useState<Job['kind']>(initial);
  const [name, setName] = useState('');
  const [loc, setLoc] = useState(inv?.me.location_id || inv?.locations.find((l) => l.is_main)?.id || inv?.locations[0]?.id || '');
  const [output, setOutput] = useState<Item | null>(null);
  const [planned, setPlanned] = useState('');
  const [account, setAccount] = useState(jobs.data?.default_account || '5202');
  const [customer, setCustomer] = useState('');
  const [due, setDue] = useState('');
  const [notes, setNotes] = useState('');
  if (!inv) return null;
  const makeable = inv.items.filter((i) => i.item_type !== 'raw_material' && i.item_type !== 'packaging' && i.item_type !== 'consumable' && i.item_type !== 'spare_part');
  const recipe = output ? jobs.data?.recipes.find((r) => r.item_id === output.id) : undefined;
  async function save() {
    const r = await run(() => rpc<{ id: string; ref: string }>('save_job', { p_org: orgId, p_job: {
      kind, name: name.trim() || (kind === 'production' && output ? output.name : ''), location_id: loc,
      output_item_id: output?.id || null, planned_qty: planned, charge_account: account, customer, due_date: due || null, notes } }),
      { ok: (x) => `${x.ref} opened`, invalidate: ['jobs'] });
    if (r) onCreated(r.id);
  }
  return (
    <Modal onClose={onClose} width={520}>
      <ModalHead title={kind === 'production' ? 'New production run' : 'New job'} sub={kind === 'production' ? 'Materials issued to it sit in work in progress until you record its output.' : 'Stock issued to it is charged to the account you choose here.'} onClose={onClose} />
      <div className="modal-body">
        <Seg value={kind} onChange={setKind} options={[{ id: 'production', label: 'Production run' }, { id: 'job', label: 'Job, repair or project' }]} />
        {kind === 'production' ? (
          <>
            <Field label="What it makes" req>
              {output ? (
                <div className="row" style={{ justifyContent: 'space-between', border: '1px solid #E5E7EB', borderRadius: 10, padding: '9px 12px' }}>
                  <span style={{ fontWeight: 600, fontSize: 14 }}>{output.name}</span><button className="btn btn-ghost btn-xs" onClick={() => setOutput(null)}>Change</button>
                </div>
              ) : <ItemPicker items={makeable} onPick={setOutput} placeholder="Find the finished item" autoFocus />}
            </Field>
            {output && recipe && <Alert kind="blue" icon="list">{output.name} has a recipe: one batch makes {num(recipe.yield_qty)} {pluralUnit(output.selling_unit, Number(recipe.yield_qty))} from {recipe.lines.length} material{recipe.lines.length === 1 ? '' : 's'}. You can issue from it after the run opens.</Alert>}
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
              <Field label={`Planned quantity${output ? ` (${pluralUnit(output.selling_unit, 2)})` : ''}`} req><input className="input" type="number" inputMode="decimal" min={0} value={planned} onChange={(e) => setPlanned(e.target.value)} /></Field>
              <Field label="Branch"><select className="input" value={loc} onChange={(e) => setLoc(e.target.value)}>{inv.locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</select></Field>
            </div>
            <Field label="Name" hint="Leave blank to use the item's name."><input className="input" value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. Morning bake, Batch 14" /></Field>
          </>
        ) : (
          <>
            <Field label="Name" req><input className="input" value={name} autoFocus onChange={(e) => setName(e.target.value)} placeholder="e.g. Generator service, Mr Bello's AC repair, Warehouse roof" /></Field>
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
              <Field label="Branch"><select className="input" value={loc} onChange={(e) => setLoc(e.target.value)}>{inv.locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</select></Field>
              <Field label="Due"><input className="input" type="date" value={due} onChange={(e) => setDue(e.target.value)} /></Field>
            </div>
            <Field label="Charge stock to" hint="Customer jobs usually go to direct materials, upkeep to repairs and maintenance, and building work to capital work in progress.">
              <select className="input" value={account} onChange={(e) => setAccount(e.target.value)}>
                {(jobs.data?.accounts || []).map((a) => <option key={a.code} value={a.code}>{a.code} · {a.name}</option>)}
              </select>
            </Field>
            <Field label="Customer"><input className="input" value={customer} onChange={(e) => setCustomer(e.target.value)} placeholder="Optional" /></Field>
          </>
        )}
        <Field label="Notes"><textarea className="input" rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} /></Field>
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" onClick={save} disabled={busy || !loc || (kind === 'production' ? !output || !(Number(planned) > 0) : !name.trim())}>Open {jobNoun(kind)}</button>
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------------------
function JobDrawer({ job: j, onClose, onRecipe }: { job: Job; onClose: () => void; onRecipe: (itemId: string) => void }) {
  const { data: inv } = useInventory();
  const jobs = useJobs();
  const { run, busy } = useAction();
  const [issue, setIssue] = useState<null | 'issue' | 'return'>(null);
  const [output, setOutput] = useState(false);
  const [confirmCancel, setConfirmCancel] = useState(false);
  if (!inv) return null;
  const costs = inv.can_see_costs;
  const canIssue = can(inv, 'issue_stock');
  const canFinish = can(inv, 'approve_adjustments');
  const out = inv.items.find((i) => i.id === j.output_item_id);
  const recipe = jobs.data?.recipes.find((r) => r.item_id === j.output_item_id);
  const target = Number(j.produced_qty ?? j.planned_qty ?? 0);
  const needs = recipeNeeds(recipe, target);
  const ids = [...new Set([...j.materials.map((m) => m.item_id), ...needs.map((n) => n.item_id)])];
  const loc = inv.locations.find((l) => l.id === j.location_id)?.name;
  const open = j.status === 'open';
  const total = Number(j.materials_value || 0) + Number(j.other_costs || 0);
  return (
    <Drawer onClose={onClose} width={640}>
      <div className="drawer-hd">
        <div className="grow" style={{ minWidth: 0 }}>
          <div className="drawer-title ellipsis">{j.ref} · {j.name}</div>
          <div className="muted" style={{ fontSize: 13, marginTop: 2 }}>
            {j.kind === 'production' ? 'Production run' : 'Job'} · {loc} · opened {when(j.created_at)}{j.created_by_name ? ' by ' + j.created_by_name : ''}
          </div>
        </div>
        <Chip label={STATUS_LABEL[j.status]} t={open ? 't-blue' : j.status === 'completed' ? 't-green' : 't-grey'} />
        <XButton onClick={onClose} />
      </div>
      <div className="drawer-body stack" style={{ gap: 16 }}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(140px,1fr))', gap: 10 }}>
          {j.kind === 'production' ? (
            <>
              <Box label={j.produced_qty != null ? 'Made' : 'Planned'} value={out ? `${num(target)} ${pluralUnit(out.selling_unit, target)}` : num(target)} sub={out?.name} />
              {costs && <Box label={open ? 'In work in progress' : 'Total cost'} value={N(open ? Number(j.wip || 0) : total)} sub={j.other_costs ? `${N(j.other_costs)} added to materials` : 'materials issued'} />}
              {costs && j.output_unit_cost != null && <Box label="Cost per unit" value={N(j.output_unit_cost)} sub={out ? `per ${out.selling_unit}` : ''} />}
            </>
          ) : (
            <>
              <Box label="Charged to" value={j.charge_account || ''} sub={j.charge_account_name || ''} />
              {costs && <Box label="Stock used" value={N(j.materials_value || 0)} sub={`${j.materials.length} item${j.materials.length === 1 ? '' : 's'}`} />}
              {j.customer && <Box label="Customer" value={j.customer} sub={j.due_date ? 'due ' + fmtDay(j.due_date) : ''} />}
            </>
          )}
        </div>

        {open && canIssue && (
          <div className="row wrap" style={{ gap: 8 }}>
            <button className="btn btn-primary btn-sm" onClick={() => setIssue('issue')}><Icon name="arrow" size={14} color="#fff" />Issue stock</button>
            {j.materials.some((m) => m.net > 0) && <button className="btn btn-secondary btn-sm" onClick={() => setIssue('return')}><Icon name="undo" size={14} />Return unused</button>}
            {j.kind === 'production' && canFinish && <button className="btn btn-secondary btn-sm" onClick={() => setOutput(true)}><Icon name="check" size={14} />Record output</button>}
            {j.kind === 'job' && <button className="btn btn-secondary btn-sm" disabled={busy} onClick={() => run(() => rpc('close_job', { p_job: j.id }), { ok: `${j.ref} closed`, invalidate: ['jobs'] })}><Icon name="check" size={14} />Close job</button>}
            {(j.kind === 'job' || canFinish) && <button className="btn btn-ghost btn-sm" style={{ color: '#B91C1C' }} onClick={() => setConfirmCancel(true)}>Cancel</button>}
          </div>
        )}
        {confirmCancel && (
          <Alert kind="red" icon="alert">
            <div className="stack" style={{ gap: 8 }}>
              <span>{j.kind === 'production'
                ? (Number(j.wip || 0) > 0 ? `Cancelling writes off ${costs ? N(j.wip || 0) : 'the materials'} still in work in progress. Return what is still usable first.` : 'Cancel this run? Nothing is left in work in progress.')
                : 'Cancel this job? Stock already issued stays charged to it.'}</span>
              <span className="row" style={{ gap: 8 }}>
                <button className="btn btn-xs btn-secondary" onClick={() => setConfirmCancel(false)}>Keep it open</button>
                <button className="btn btn-xs btn-primary" style={{ background: '#B91C1C' }} disabled={busy}
                  onClick={() => run(() => rpc('close_job', { p_job: j.id, p_cancel: true }), { ok: `${j.ref} cancelled`, invalidate: ['jobs', 'inv', 'ledger'] }).then(() => setConfirmCancel(false))}>Cancel {jobNoun(j.kind)}</button>
              </span>
            </div>
          </Alert>
        )}

        <div>
          <div className="row" style={{ justifyContent: 'space-between', marginBottom: 8 }}>
            <Label>Materials{recipe ? ' against the recipe' : ''}</Label>
            {j.kind === 'production' && out && can(inv, 'edit_prices') && <button className="btn btn-ghost btn-xs" onClick={() => onRecipe(out.id)}>{recipe ? 'Edit recipe' : 'Add a recipe'}</button>}
          </div>
          {ids.length ? (
            <div className="card" style={{ overflow: 'hidden' }}>
              <table className="mini-table" style={{ width: '100%' }}>
                <thead><tr><th>Item</th>{recipe && <th className="right">Recipe</th>}<th className="right">Issued</th><th className="right">Returned</th><th className="right">Used</th>{recipe && <th className="right">Difference</th>}{costs && <th className="right">Cost</th>}</tr></thead>
                <tbody>
                  {ids.map((id) => {
                    const it = inv.items.find((i) => i.id === id);
                    const m = j.materials.find((x) => x.item_id === id);
                    const need = needs.find((n) => n.item_id === id)?.qty;
                    const used = Number(m?.net || 0);
                    const diff = need != null ? round3(used - need) : null;
                    const pct = need ? (diff! / need) * 100 : null;
                    return (
                      <tr key={id}>
                        <td>{it?.name || 'Removed item'}<div className="faint" style={{ fontSize: 11 }}>{it?.selling_unit}</div></td>
                        {recipe && <td className="right num">{need != null ? num(need, 2) : '—'}</td>}
                        <td className="right num">{m?.issued ? num(Number(m.issued), 2) : '—'}</td>
                        <td className="right num">{m?.returned ? num(Number(m.returned), 2) : '—'}</td>
                        <td className="right num" style={{ fontWeight: 600 }}>{num(used, 2)}</td>
                        {recipe && <td className="right num" style={{ color: pct != null && Math.abs(pct) > 5 ? (pct > 0 ? '#B91C1C' : '#A16207') : undefined }}>{diff == null ? '—' : `${diff > 0 ? '+' : ''}${num(diff, 2)}${pct != null ? ` (${pct > 0 ? '+' : ''}${pct.toFixed(0)}%)` : ''}`}</td>}
                        {costs && <td className="right num">{m?.value != null ? N(m.value) : '—'}</td>}
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          ) : <div className="muted" style={{ fontSize: 13 }}>Nothing issued yet.</div>}
          {recipe && j.kind === 'production' && <div className="faint" style={{ fontSize: 12, marginTop: 6, lineHeight: 1.5 }}>Recipe quantities are for {num(target)} {out ? pluralUnit(out.selling_unit, target) : ''}, wastage included. More than 5% over the recipe shows in red: it is where waste or leakage hides.</div>}
        </div>

        {(j.notes || j.closed_at) && (
          <div className="stack" style={{ gap: 4, fontSize: 13 }}>
            {j.notes && <div style={{ whiteSpace: 'pre-wrap' }} className="ink3">{j.notes}</div>}
            {j.closed_at && <div className="faint">{STATUS_LABEL[j.status]} {when(j.closed_at)}{j.closed_by_name ? ' by ' + j.closed_by_name : ''}</div>}
          </div>
        )}
      </div>
      {issue && <IssueModal job={j} mode={issue} recipe={recipe} onClose={() => setIssue(null)} />}
      {output && out && <OutputModal job={j} item={out} recipe={recipe} onClose={() => setOutput(false)} />}
    </Drawer>
  );
}

function Box({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div style={{ border: '1px solid #EEF0F3', borderRadius: 12, padding: '10px 12px', minWidth: 0 }}>
      <div className="mini-label">{label}</div>
      <div style={{ fontSize: 16, fontWeight: 600, marginTop: 4 }} className="ellipsis">{value}</div>
      {sub && <div className="faint ellipsis" style={{ fontSize: 12, marginTop: 2 }}>{sub}</div>}
    </div>
  );
}

// ---------------------------------------------------------------------------
interface Line { item: Item; qty: string; unit: 'selling' | 'purchase'; note: string }
const lineQty = (l: Line) => Number(l.qty) * (l.unit === 'purchase' ? l.item.pack_size : 1);

export function IssueModal({ job: j, mode, recipe, onClose }: { job: Job; mode: 'issue' | 'return'; recipe?: Recipe; onClose: () => void }) {
  const { data: inv } = useInventory();
  const { run, busy } = useAction();
  const [lines, setLines] = useState<Line[]>([]);
  const [warn, setWarn] = useState<any[] | null>(null);
  const [full, setFull] = useState(false);
  const items = useMemo(() => {
    if (!inv) return [];
    if (mode === 'return') return inv.items.filter((i) => j.materials.some((m) => m.item_id === i.id && m.net > 0));
    return inv.items.filter((i) => i.id !== j.output_item_id);
  }, [inv, mode, j]);
  if (!inv) return null;
  const onHand = (it: Item) => Number(it.qty?.[j.location_id] || 0);
  const add = (it: Item, qty = '') => setLines((ls) => (ls.some((l) => l.item.id === it.id) ? ls : [...ls, { item: it, qty, unit: 'selling', note: '' }]));
  function fromRecipe() {
    const target = Number(j.planned_qty || 0);
    const needs = recipeNeeds(recipe, target);
    const next: Line[] = [];
    for (const n of needs) {
      const it = inv!.items.find((i) => i.id === n.item_id);
      if (!it) continue;
      const already = Number(j.materials.find((m) => m.item_id === n.item_id)?.net || 0);
      const left = round3(n.qty - already);
      if (left > 0) next.push({ item: it, qty: String(left), unit: 'selling', note: '' });
    }
    setLines(next);
    setFull(!next.length);
  }
  const bad = lines.some((l) => !(lineQty(l) > 0));
  const short = mode === 'issue' ? lines.filter((l) => lineQty(l) > onHand(l.item)) : [];
  const over = mode === 'return' ? lines.filter((l) => lineQty(l) > Number(j.materials.find((m) => m.item_id === l.item.id)?.net || 0) + 0.0005) : [];
  async function submit() {
    const r = await run(() => rpc<any>('issue_materials', {
      p_job: j.id, p_return: mode === 'return', p_client_uuid: uuid(),
      p_lines: lines.map((l) => ({ item_id: l.item.id, qty: round3(lineQty(l)), note: l.note || null })),
    }), { ok: (x) => `${mode === 'return' ? 'Returned to stock' : 'Issued to ' + j.ref} · ${x.journal_ref}${x.value != null ? ' · ' + N(x.value) : ''}`, invalidate: ['jobs', 'inv', 'ledger', 'activity'] });
    if (r) { if (r.warnings?.length) setWarn(r.warnings); else onClose(); }
  }
  return (
    <Modal onClose={onClose} width={620} z={60}>
      <ModalHead title={mode === 'return' ? `Return unused stock from ${j.ref}` : `Issue stock to ${j.ref}`}
        sub={mode === 'return' ? 'It goes back on the shelf at the cost it left at.' : `From ${inv.locations.find((l) => l.id === j.location_id)?.name}, at average cost, oldest expiry first.`} onClose={onClose} />
      <div className="modal-body">
        {warn ? (
          <Alert kind="yellow" icon="alert">
            <div className="stack" style={{ gap: 6 }}>
              <b>Issued. The books now show less than zero for:</b>
              {warn.map((w) => <span key={w.item}>{w.item}: {num(w.on_hand, 2)} on hand, {num(w.qty, 2)} issued</span>)}
              <span>Count these soon so the stock figure is right again.</span>
            </div>
          </Alert>
        ) : (
          <>
            <div className="row" style={{ gap: 8 }}>
              <div className="grow"><ItemPicker items={items} onPick={(it) => add(it)} exclude={lines.map((l) => l.item.id)} autoFocus placeholder={mode === 'return' ? `Find an item that went to this ${jobNoun(j.kind)}` : undefined} /></div>
              {mode === 'issue' && recipe && j.kind === 'production' && <button className="btn btn-secondary" onClick={fromRecipe}><Icon name="list" size={15} />Fill from recipe</button>}
            </div>
            {lines.length > 0 && (
              <div className="stack" style={{ gap: 8 }}>
                {lines.map((l, i) => {
                  const net = Number(j.materials.find((m) => m.item_id === l.item.id)?.net || 0);
                  return (
                    <div key={l.item.id} className="line-grid" style={{ display: 'grid', gridTemplateColumns: 'minmax(0,1fr) 110px 120px 28px', gap: 8, alignItems: 'center' }}>
                      <div style={{ minWidth: 0 }}>
                        <div className="ellipsis" style={{ fontWeight: 600, fontSize: 14 }}>{l.item.name}</div>
                        <div className="faint" style={{ fontSize: 12 }}>{mode === 'return' ? `${num(net, 2)} ${pluralUnit(l.item.selling_unit, net)} went to this ${jobNoun(j.kind)}` : `${qtyLabel(l.item, onHand(l.item))} here`}</div>
                      </div>
                      <input className={'input' + (lineQty(l) > 0 ? '' : ' err')} type="number" inputMode="decimal" min={0} value={l.qty} aria-label={'Quantity of ' + l.item.name}
                        onChange={(e) => setLines((ls) => ls.map((x, k) => (k === i ? { ...x, qty: e.target.value } : x)))} />
                      {l.item.pack_size > 1 ? (
                        <select className="input" value={l.unit} aria-label="Unit" onChange={(e) => setLines((ls) => ls.map((x, k) => (k === i ? { ...x, unit: e.target.value as Line['unit'] } : x)))}>
                          <option value="selling">{pluralUnit(l.item.selling_unit, 2)}</option><option value="purchase">{puAbbr(l.item.purchase_unit)} of {l.item.pack_size}</option>
                        </select>
                      ) : <span className="muted" style={{ fontSize: 13 }}>{pluralUnit(l.item.selling_unit, 2)}</span>}
                      <button className="btn btn-ghost btn-xs" aria-label={'Remove ' + l.item.name} onClick={() => setLines((ls) => ls.filter((_, k) => k !== i))}><Icon name="x" size={14} /></button>
                    </div>
                  );
                })}
              </div>
            )}
            {!lines.length && full && <div className="muted" style={{ fontSize: 13 }}>Everything the recipe needs for {num(Number(j.planned_qty || 0))} has already gone to this run. Add anything extra above.</div>}
            {!lines.length && !full && <div className="muted" style={{ fontSize: 13 }}>{mode === 'return' ? 'Add the items coming back and how much of each.' : 'Add each item and how much leaves the store for this ' + jobNoun(j.kind) + '.'}</div>}
            {short.length > 0 && <Alert kind="yellow" icon="info">The books show less than you are issuing for {short.map((l) => l.item.name).join(', ')}. You can still issue; count it soon afterwards.</Alert>}
            {over.length > 0 && <Alert kind="red" icon="alert">You are returning more {over.map((l) => l.item.name).join(', ')} than went to this {jobNoun(j.kind)}.</Alert>}
          </>
        )}
      </div>
      <div className="modal-ft">
        {warn ? <button className="btn btn-primary" onClick={onClose}>Done</button> : (
          <>
            <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
            <button className="btn btn-primary" disabled={busy || !lines.length || bad || over.length > 0} onClick={submit}>
              {mode === 'return' ? 'Return to stock' : `Issue ${lines.length || ''} item${lines.length === 1 ? '' : 's'}`}
            </button>
          </>
        )}
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------------------
function OutputModal({ job: j, item, recipe, onClose }: { job: Job; item: Item; recipe?: Recipe; onClose: () => void }) {
  const { data: inv } = useInventory();
  const { run, busy } = useAction();
  const [qty, setQty] = useState(String(j.planned_qty ?? ''));
  const [costs, setCosts] = useState<{ label: string; amount: string }[]>([{ label: 'Labour', amount: '' }]);
  const [batch, setBatch] = useState('');
  const [expiry, setExpiry] = useState('');
  if (!inv) return null;
  const extra = costs.reduce((a, c) => a + (Number(c.amount) || 0), 0);
  const total = Number(j.wip || 0) + extra;
  const unit = Number(qty) > 0 ? total / Number(qty) : null;
  const standard = recipeUnitCost(recipe, inv.items);
  async function save() {
    const r = await run(() => rpc<any>('complete_production', { p_job: j.id, p_qty: Number(qty), p_extra: {
      costs: costs.filter((c) => Number(c.amount) > 0), batch_no: batch || null, expiry_date: expiry || null } }),
      { ok: (x) => `${num(x.qty)} ${pluralUnit(item.selling_unit, x.qty)} of ${item.name} into stock · ${x.journal_ref}`, invalidate: ['jobs', 'inv', 'ledger', 'activity'] });
    if (r) onClose();
  }
  return (
    <Modal onClose={onClose} width={540} z={60}>
      <ModalHead title={`Record what ${j.ref} made`} sub={`The run's whole cost moves into ${item.name}, and the run closes.`} onClose={onClose} />
      <div className="modal-body">
        <Field label={`Quantity made (${pluralUnit(item.selling_unit, 2)})`} req><input className="input" type="number" inputMode="decimal" min={0} value={qty} autoFocus onChange={(e) => setQty(e.target.value)} /></Field>
        <div>
          <label className="field-label">Labour, power and other costs to add</label>
          <div className="stack" style={{ gap: 8 }}>
            {costs.map((c, i) => (
              <div key={i} style={{ display: 'grid', gridTemplateColumns: 'minmax(0,1fr) 140px 28px', gap: 8 }}>
                <input className="input" value={c.label} placeholder="e.g. Baker wages, Diesel" onChange={(e) => setCosts((cs) => cs.map((x, k) => (k === i ? { ...x, label: e.target.value } : x)))} />
                <input className="input" type="number" inputMode="decimal" min={0} value={c.amount} placeholder="₦" aria-label="Amount" onChange={(e) => setCosts((cs) => cs.map((x, k) => (k === i ? { ...x, amount: e.target.value } : x)))} />
                <button className="btn btn-ghost btn-xs" aria-label="Remove cost" onClick={() => setCosts((cs) => cs.filter((_, k) => k !== i))}><Icon name="x" size={14} /></button>
              </div>
            ))}
            <button className="btn btn-ghost btn-xs" style={{ alignSelf: 'flex-start', paddingLeft: 0 }} onClick={() => setCosts((cs) => [...cs, { label: '', amount: '' }])}><Icon name="plus" size={13} />Add a cost</button>
          </div>
          <div className="hint" style={{ marginTop: 6 }}>These are already in your expenses. Adding them here makes them part of the item's cost, so its margin is real.</div>
        </div>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="Batch number" hint={`Blank uses ${j.ref}.`}><input className="input" value={batch} onChange={(e) => setBatch(e.target.value)} /></Field>
          <Field label="Best before"><input className="input" type="date" value={expiry} onChange={(e) => setExpiry(e.target.value)} /></Field>
        </div>
        {inv.can_see_costs && (
          <div className="card" style={{ padding: 12, fontSize: 13, background: '#FAFBFC' }}>
            <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">Materials in work in progress</span><b>{N(j.wip || 0)}</b></div>
            {extra > 0 && <div className="row" style={{ justifyContent: 'space-between', marginTop: 4 }}><span className="muted">Other costs</span><b>{N(extra)}</b></div>}
            <div className="row" style={{ justifyContent: 'space-between', marginTop: 6, paddingTop: 6, borderTop: '1px solid #EEF0F3' }}><span>Cost per {item.selling_unit}</span><b>{unit != null ? N(unit) : '—'}</b></div>
            {standard != null && unit != null && <div className="faint" style={{ marginTop: 4 }}>The recipe at today's costs comes to {N(standard)} before labour.</div>}
            {Number(item.price) > 0 && unit != null && <div className="faint" style={{ marginTop: 2 }}>Selling price {N(item.price)} · margin {(((Number(item.price) - unit) / Number(item.price)) * 100).toFixed(1)}%</div>}
          </div>
        )}
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy || !(Number(qty) > 0) || !(total > 0)} onClick={save}>Post output and close run</button>
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------------------
function RecipesTab({ onEdit }: { onEdit: (itemId: string | null) => void }) {
  const { data: inv } = useInventory();
  const jobs = useJobs();
  if (!inv) return null;
  const recipes = jobs.data?.recipes || [];
  const canEdit = can(inv, 'edit_prices');
  return (
    <div className="card" style={{ overflow: 'hidden' }}>
      <div className="card-hd row" style={{ justifyContent: 'space-between' }}>
        <Label>Recipes</Label>
        {canEdit && <button className="btn btn-secondary btn-sm" onClick={() => onEdit(null)}><Icon name="plus" size={14} />New recipe</button>}
      </div>
      {recipes.length ? (
        <table className="mini-table" style={{ width: '100%' }}>
          <thead><tr><th>Makes</th><th className="right">One batch</th><th>Materials</th>{inv.can_see_costs && <th className="right">Material cost per unit</th>}<th /></tr></thead>
          <tbody>
            {recipes.map((r) => {
              const it = inv.items.find((i) => i.id === r.item_id);
              const uc = recipeUnitCost(r, inv.items);
              return (
                <tr key={r.item_id}>
                  <td style={{ fontWeight: 600 }}>{it?.name || 'Removed item'}</td>
                  <td className="right num">{num(r.yield_qty)} {it ? pluralUnit(it.selling_unit, Number(r.yield_qty)) : ''}</td>
                  <td className="ink3">{r.lines.map((l) => inv.items.find((i) => i.id === l.item_id)?.name).filter(Boolean).join(', ')}</td>
                  {inv.can_see_costs && <td className="right num">{uc != null ? N(uc) : '—'}{uc != null && it && Number(it.price) > 0 ? <div className="faint" style={{ fontSize: 11 }}>{(((Number(it.price) - uc) / Number(it.price)) * 100).toFixed(0)}% margin before labour</div> : null}</td>}
                  <td className="right">{canEdit && <button className="btn btn-ghost btn-xs" onClick={() => onEdit(r.item_id)}>Edit</button>}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      ) : <div className="muted" style={{ padding: 24, fontSize: 14, lineHeight: 1.6 }}>A recipe lists what goes into one batch of a finished item. With one, a production run can issue its materials in one tap, and Counta flags runs that use more than the recipe allows.</div>}
    </div>
  );
}

function RecipeModal({ itemId, onClose }: { itemId: string | null; onClose: () => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const jobs = useJobs();
  const { run, busy } = useAction();
  const existing = jobs.data?.recipes.find((r) => r.item_id === itemId);
  const [output, setOutput] = useState<Item | null>(() => inv?.items.find((i) => i.id === itemId) || null);
  const [yieldQty, setYield] = useState(String(existing?.yield_qty ?? 1));
  const [lines, setLines] = useState<{ item: Item; qty: string; waste: string }[]>(() =>
    (existing?.lines || []).map((l) => ({ item: inv!.items.find((i) => i.id === l.item_id)!, qty: String(l.qty), waste: String(l.wastage_pct || 0) })).filter((l) => l.item));
  const [notes, setNotes] = useState(existing?.notes || '');
  if (!inv) return null;
  const draft: Recipe | undefined = output ? { item_id: output.id, yield_qty: Number(yieldQty) || 1, notes, updated_at: '', lines: lines.map((l) => ({ item_id: l.item.id, qty: Number(l.qty) || 0, wastage_pct: Number(l.waste) || 0 })) } : undefined;
  const uc = recipeUnitCost(draft, inv.items);
  async function save(remove = false) {
    const r = await run(() => rpc('save_recipe', { p_org: orgId, p_item: output!.id, p_yield: Number(yieldQty), p_notes: notes,
      p_lines: remove ? [] : lines.map((l) => ({ item_id: l.item.id, qty: Number(l.qty), wastage_pct: Number(l.waste) || 0 })) }),
      { ok: remove ? 'Recipe removed' : 'Recipe saved', invalidate: ['jobs'] });
    if (r) onClose();
  }
  return (
    <Modal onClose={onClose} width={620} z={70}>
      <ModalHead title={existing ? `Recipe for ${output?.name}` : 'New recipe'} sub="What goes into one batch, in each material's selling unit." onClose={onClose} />
      <div className="modal-body">
        {!output ? <Field label="Finished item"><ItemPicker items={inv.items.filter((i) => !jobs.data?.recipes.some((r) => r.item_id === i.id))} onPick={setOutput} autoFocus placeholder="Find the item this recipe makes" /></Field> : (
          <>
            <Field label={`One batch makes (${pluralUnit(output.selling_unit, 2)})`}><input className="input" type="number" inputMode="decimal" min={0} value={yieldQty} onChange={(e) => setYield(e.target.value)} style={{ maxWidth: 180 }} /></Field>
            <ItemPicker items={inv.items.filter((i) => i.id !== output.id)} exclude={lines.map((l) => l.item.id)} onPick={(it) => setLines((ls) => [...ls, { item: it, qty: '', waste: '0' }])} placeholder="Add a material" />
            {lines.map((l, i) => (
              <div key={l.item.id} style={{ display: 'grid', gridTemplateColumns: 'minmax(0,1fr) 110px 100px 28px', gap: 8, alignItems: 'center' }}>
                <div style={{ minWidth: 0 }}><div className="ellipsis" style={{ fontWeight: 600, fontSize: 14 }}>{l.item.name}</div><div className="faint" style={{ fontSize: 12 }}>{l.item.selling_unit}{inv.can_see_costs && l.item.wac != null ? ` · ${N(l.item.wac)} each` : ''}</div></div>
                <input className={'input' + (Number(l.qty) > 0 ? '' : ' err')} type="number" inputMode="decimal" min={0} value={l.qty} placeholder="Qty" aria-label={'Quantity of ' + l.item.name} onChange={(e) => setLines((ls) => ls.map((x, k) => (k === i ? { ...x, qty: e.target.value } : x)))} />
                <div className="row" style={{ gap: 4 }}><input className="input" type="number" inputMode="decimal" min={0} max={99} value={l.waste} aria-label="Wastage percent" onChange={(e) => setLines((ls) => ls.map((x, k) => (k === i ? { ...x, waste: e.target.value } : x)))} /><span className="muted" style={{ fontSize: 12 }}>%</span></div>
                <button className="btn btn-ghost btn-xs" aria-label={'Remove ' + l.item.name} onClick={() => setLines((ls) => ls.filter((_, k) => k !== i))}><Icon name="x" size={14} /></button>
              </div>
            ))}
            {lines.length > 0 && <div className="faint" style={{ fontSize: 12 }}>Quantity per batch, then expected wastage. {uc != null && inv.can_see_costs ? `Materials come to ${N(uc)} per ${output.selling_unit} at today's costs.` : ''}</div>}
            <Field label="Method or notes"><textarea className="input" rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} /></Field>
          </>
        )}
      </div>
      <div className="modal-ft">
        {existing && <button className="btn btn-ghost" style={{ marginRight: 'auto', color: '#B91C1C' }} disabled={busy} onClick={() => save(true)}>Remove recipe</button>}
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy || !output || !lines.length || lines.some((l) => !(Number(l.qty) > 0)) || !(Number(yieldQty) > 0)} onClick={() => save(false)}>Save recipe</button>
      </div>
    </Modal>
  );
}

