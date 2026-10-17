import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { can, useInventory, useSession, useToast } from '../state/session';
import { rpc } from '../lib/supabase';
import { num, uuid } from '../lib/format';
import { pluralUnit, puAbbr, qtyLabel } from '../lib/domain';
import { recipeNeeds, round3, useJobs, type Job } from '../lib/jobs';
import type { Item } from '../lib/types';
import { Icon } from '../components/Icon';
import { Thumb } from '../components/ui';
import { BranchChip, MTop, QueueBanner, useM } from './ctx';
import { Done, ItemSearch } from './common';
import { enqueue } from './queue';

interface Line { item: Item; qty: string; unit: 'selling' | 'purchase' }

// Issue stock from this branch to an open production run or job. Works offline: the issue waits on the phone
// and posts with the time it was made.
export default function IssueScreen() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const { loc, queue } = useM();
  const jobs = useJobs();
  const toast = useToast();
  const nav = useNavigate();
  const [job, setJob] = useState<Job | null>(null);
  const [lines, setLines] = useState<Line[]>([]);
  const [newName, setNewName] = useState('');
  const [creating, setCreating] = useState(false);
  const [done, setDone] = useState<string | null>(null);
  if (!inv) return null;
  if (!can(inv, 'issue_stock')) return <><MTop title="Issue stock" /><div className="m-pad muted">Your role does not issue stock to jobs. Ask the owner for the Issue to jobs permission.</div></>;
  const open = (jobs.data?.jobs || []).filter((j) => j.status === 'open' && j.location_id === loc);
  const recipe = job?.kind === 'production' ? jobs.data?.recipes.find((r) => r.item_id === job.output_item_id) : undefined;
  const qtyOf = (l: Line) => Number(l.qty) * (l.unit === 'purchase' ? l.item.pack_size : 1);

  async function createJob() {
    setCreating(true);
    try {
      const r = await rpc<{ id: string; ref: string }>('save_job', { p_org: orgId, p_job: { kind: 'job', name: newName.trim(), location_id: loc, client_uuid: uuid() } });
      const fresh = await jobs.refetch();
      setJob(fresh.data?.jobs.find((j) => j.id === r.id) || null); setNewName('');
    } catch (e: any) { toast(e.message || 'Could not open the job', 'err'); }
    setCreating(false);
  }
  // What the recipe still needs for the planned quantity, after what has already gone to this run.
  const stillNeeded: Line[] = [];
  if (job && recipe) {
    for (const n of recipeNeeds(recipe, Number(job.planned_qty || 0))) {
      const it = inv.items.find((i) => i.id === n.item_id);
      const left = round3(n.qty - Number(job.materials.find((m) => m.item_id === n.item_id)?.net || 0));
      if (it && left > 0) stillNeeded.push({ item: it, qty: String(left), unit: 'selling' });
    }
  }
  const fromRecipe = () => setLines(stillNeeded);
  async function submit() {
    if (!job) return;
    const payload = { job_id: job.id, ref: job.ref, lines: lines.map((l) => ({ item_id: l.item.id, qty: round3(qtyOf(l)) })) };
    await enqueue({ org: orgId!, kind: 'issue', label: 'Issued', detail: `${job.ref} · ${lines.length} item${lines.length === 1 ? '' : 's'}`, payload, author: inv!.me.display_name });
    setDone(`${lines.length} item${lines.length === 1 ? '' : 's'} issued to ${job.ref} · ${job.name}`);
    setLines([]);
  }

  if (done) return <><MTop title="Issue stock" /><Done title="Issued" body={done + (queue.online ? '' : '. Saved on this phone; it posts when data returns.')} action="Issue more" onAction={() => setDone(null)} /></>;
  return (
    <>
      <MTop title={job ? job.ref : 'Issue stock'} right={!job ? <BranchChip /> : undefined} />
      <QueueBanner />
      <div className="m-pad stack" style={{ gap: 12, paddingBottom: 24 }}>
        {!job ? (
          <>
            <div className="muted" style={{ fontSize: 13, lineHeight: 1.5 }}>Choose the production run or job the stock is going to.</div>
            {open.map((j) => (
              <button key={j.id} className="m-card row" style={{ cursor: 'pointer', font: 'inherit', textAlign: 'left' }} onClick={() => setJob(j)}>
                <Icon name={j.kind === 'production' ? 'factory' : 'wrench'} size={18} color="#0072F5" />
                <span className="grow"><span style={{ display: 'block', fontSize: 13, fontWeight: 600 }}>{j.ref} · {j.name}</span>
                  <span className="faint" style={{ fontSize: 11 }}>{j.kind === 'production' ? `Makes ${num(Number(j.planned_qty || 0))} ${inv.items.find((i) => i.id === j.output_item_id)?.name || ''}` : `Charged to ${j.charge_account_name || j.charge_account}`} · {j.materials.length} item{j.materials.length === 1 ? '' : 's'} so far</span></span>
                <Icon name="chevR" size={16} color="#9CA3AF" />
              </button>
            ))}
            {!open.length && <div className="m-card muted" style={{ fontSize: 13 }}>Nothing is open at this branch.</div>}
            <div className="m-card stack" style={{ gap: 8 }}>
              <div style={{ fontSize: 13, fontWeight: 600 }}>New job</div>
              <input className="input" value={newName} onChange={(e) => setNewName(e.target.value)} placeholder="e.g. Generator service" aria-label="Job name" />
              <button className="m-btn" disabled={!newName.trim() || creating || !queue.online} onClick={createJob}>{queue.online ? (creating ? 'Opening…' : 'Open job') : 'Needs data to open a job'}</button>
              <div className="faint" style={{ fontSize: 11 }}>Production runs are opened from the full app, where the recipe and output are set.</div>
            </div>
          </>
        ) : (
          <>
            <div className="m-card row" style={{ gap: 10 }}>
              <Icon name={job.kind === 'production' ? 'factory' : 'wrench'} size={18} color="#0072F5" />
              <span className="grow"><span style={{ display: 'block', fontSize: 13, fontWeight: 600 }}>{job.name}</span><span className="faint" style={{ fontSize: 11 }}>From {inv.locations.find((l) => l.id === job.location_id)?.name}</span></span>
              <button className="btn btn-xs btn-secondary" onClick={() => { setJob(null); setLines([]); }}>Change</button>
            </div>
            {recipe && !lines.length && (stillNeeded.length > 0
              ? <button className="m-btn secondary" onClick={fromRecipe}><Icon name="list" size={16} />Fill from the recipe</button>
              : <div className="faint" style={{ fontSize: 12 }}>Everything the recipe needs for {num(Number(job.planned_qty || 0))} has gone to this run. Add anything extra below.</div>)}
            <ItemSearch onPick={(it) => setLines((ls) => (ls.some((l) => l.item.id === it.id) ? ls : [...ls, { item: it, qty: '', unit: 'selling' }]))} placeholder="Add an item: name or barcode" />
            {lines.map((l, i) => (
              <div key={l.item.id} className="m-card stack" style={{ gap: 8 }}>
                <div className="row"><Thumb name={l.item.name} path={l.item.photo_path} size={32} /><span className="grow"><span style={{ display: 'block', fontSize: 13, fontWeight: 600 }}>{l.item.name}</span><span className="faint" style={{ fontSize: 11 }}>{qtyLabel(l.item, Number(l.item.qty?.[job.location_id] || 0))} here</span></span>
                  <button className="btn btn-xs btn-ghost" aria-label={'Remove ' + l.item.name} onClick={() => setLines((ls) => ls.filter((_, k) => k !== i))}><Icon name="x" size={14} /></button></div>
                <div style={{ display: 'grid', gridTemplateColumns: l.item.pack_size > 1 ? '1fr 1fr' : '1fr', gap: 8 }}>
                  <input className="input" type="number" inputMode="decimal" min={0} value={l.qty} placeholder="Quantity" aria-label={'Quantity of ' + l.item.name} style={{ fontSize: 17, fontWeight: 600 }}
                    onChange={(e) => setLines((ls) => ls.map((x, k) => (k === i ? { ...x, qty: e.target.value } : x)))} />
                  {l.item.pack_size > 1 && (
                    <select className="input" value={l.unit} aria-label="Unit" onChange={(e) => setLines((ls) => ls.map((x, k) => (k === i ? { ...x, unit: e.target.value as Line['unit'] } : x)))}>
                      <option value="selling">{pluralUnit(l.item.selling_unit, 2)}</option><option value="purchase">{puAbbr(l.item.purchase_unit)} ({l.item.pack_size})</option>
                    </select>
                  )}
                </div>
              </div>
            ))}
            {lines.length > 0 && (
              <button className="m-btn" disabled={lines.some((l) => !(qtyOf(l) > 0))} onClick={submit}>
                Issue {lines.length} item{lines.length === 1 ? '' : 's'} to {job.ref}
              </button>
            )}
            <button className="btn btn-ghost btn-sm" onClick={() => nav('/m')}>Back to Today</button>
          </>
        )}
      </div>
    </>
  );
}
