import { useEffect, useMemo, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { get, set } from 'idb-keyval';
import { can, useInventory, useSession } from '../state/session';
import { useCounts } from '../lib/queries';
import { cleanError, rpc } from '../lib/supabase';
import { num, when } from '../lib/format';
import { pluralUnit, puAbbr } from '../lib/domain';
import { Icon } from '../components/Icon';
import { Spinner, Thumb } from '../components/ui';
import { MTop, QueueBanner, useM } from './ctx';
import { Done } from './common';
import { enqueue } from './queue';
import { REASONS } from '../lib/types';

interface SheetLine { item_id: string; name: string; selling_unit: string; purchase_unit: string; pack_size: number; photo_path: string | null; category: string; counted: number | null }
interface Sheet { session: any; lines: SheetLine[] }

export function CountList() {
  const { data: inv } = useInventory();
  const counts = useCounts();
  const nav = useNavigate();
  if (!inv) return null;
  const mine = (counts.data || []).filter((c) => c.assignee_id === inv.me.id && (c.status === 'open' || c.status === 'awaiting_reasons'));
  return (
    <>
      <MTop title="Stock counts" />
      <QueueBanner />
      <div className="m-pad stack" style={{ gap: 10 }}>
        {!can(inv, 'count_stock') && <div className="muted">Your role does not count stock.</div>}
        {counts.isLoading && <Spinner small />}
        {mine.map((c) => (
          <button key={c.id} className="m-card row" style={{ cursor: 'pointer', font: 'inherit', textAlign: 'left' }} onClick={() => nav('/m/count/' + c.id)}>
            <Icon name="list" size={18} color="#A16207" />
            <span className="grow"><span style={{ display: 'block', fontSize: 14, fontWeight: 600 }}>{c.ref} · {c.area}</span>
              <span className="faint" style={{ fontSize: 11 }}>{inv.locations.find((l) => l.id === c.location_id)?.name} · {c.status === 'awaiting_reasons' ? 'tell us why some counts differ' : 'assigned ' + when(c.created_at)}{c.rejected_count ? ' · recount' : ''}</span></span>
            <Icon name="chevR" size={16} color="#9CA3AF" />
          </button>
        ))}
        {counts.data && !mine.length && <div className="empty">No counts are waiting for you. When the owner schedules one, it appears here and works offline once opened.</div>}
      </div>
    </>
  );
}

export function CountSheet() {
  const { id } = useParams();
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const { queue } = useM();
  const nav = useNavigate();
  const qc = useQueryClient();
  const draftKey = 'counta.countdraft.' + id;
  const sheet = useQuery({
    queryKey: ['countSheet', id], enabled: !!id, networkMode: 'always', retry: 0,
    queryFn: async (): Promise<Sheet> => {
      try { const s = await rpc<Sheet>('get_count_sheet', { p_session: id }); await set('counta.sheet.' + id, s).catch(() => {}); return s; }
      catch (e) { const cached = await get<Sheet>('counta.sheet.' + id).catch(() => undefined); if (cached) return cached; throw e; }
    },
  });
  const [vals, setVals] = useState<Record<string, string>>({});
  const [loaded, setLoaded] = useState(false);
  const [stage, setStage] = useState<'count' | 'reasons' | 'queued' | 'submitted' | 'done'>('count');
  const [variances, setVariances] = useState<{ item_id: string; name: string; selling_unit: string; variance: number }[]>([]);
  const [reasons, setReasons] = useState<Record<string, { reason: string; note: string }>>({});
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => { get<Record<string, string>>(draftKey).then((d) => { if (d) setVals(d); setLoaded(true); }).catch(() => setLoaded(true)); }, [draftKey]);
  useEffect(() => { if (loaded) set(draftKey, vals).catch(() => {}); }, [vals, loaded, draftKey]);
  const s = sheet.data?.session;
  useEffect(() => {
    if (s?.status === 'awaiting_reasons' && sheet.data) {
      setVariances(sheet.data.lines.filter((l: any) => l.variance).map((l: any) => ({ item_id: l.item_id, name: l.name, selling_unit: l.selling_unit, variance: Number(l.variance) })));
      setStage('reasons');
    }
  }, [s?.status]); // eslint-disable-line react-hooks/exhaustive-deps
  const lines = useMemo(() => sheet.data?.lines || [], [sheet.data]);
  if (!inv) return null;
  if (sheet.isLoading) return <><MTop title="Count" /><div className="m-pad"><Spinner small /></div></>;
  if (sheet.error || !s) return <><MTop title="Count" /><div className="m-pad stack" style={{ gap: 10 }}><div className="alert alert-red">{cleanError(sheet.error) || 'Count not found.'}</div><button className="m-btn secondary" onClick={() => nav('/m/count')}>Back to counts</button></div></>;
  const loc = inv.locations.find((l) => l.id === s.location_id)?.name || '';
  const counted = lines.filter((l) => vals[l.item_id] !== undefined && vals[l.item_id] !== '' && Number(vals[l.item_id]) >= 0).length;
  const ready = counted === lines.length && lines.length > 0;
  const owner = inv.members.find((m) => m.id === s.created_by)?.display_name.split(' ')[0] || 'the owner';

  async function submit() {
    if (!ready || !orgId) return;
    const payload = lines.map((l) => ({ item_id: l.item_id, counted: Number(vals[l.item_id]) }));
    setErr(null); setBusy(true);
    if (!navigator.onLine) {
      await enqueue({ org: orgId, kind: 'count', label: 'Count', detail: `${s.ref} · ${lines.length} items`, payload: { session_id: id, lines: payload }, author: inv!.me.display_name });
      setBusy(false); setStage('queued'); return;
    }
    try {
      const r = await rpc<{ variances: any[] }>('submit_count', { p_session: id, p_lines: payload, p_device: 'phone', p_offline: false });
      await set(draftKey, {}).catch(() => {});
      qc.invalidateQueries({ queryKey: ['counts'] });
      if (r.variances?.length) { setVariances(r.variances.map((v) => ({ ...v, variance: Number(v.variance) }))); setStage('reasons'); }
      else setStage('submitted');
    } catch (e) {
      if (!navigator.onLine) { await enqueue({ org: orgId, kind: 'count', label: 'Count', detail: `${s.ref} · ${lines.length} items`, payload: { session_id: id, lines: payload }, author: inv!.me.display_name }); setStage('queued'); }
      else setErr(cleanError(e));
    } finally { setBusy(false); }
  }
  async function saveReasons() {
    const list = variances.map((v) => ({ item_id: v.item_id, reason: reasons[v.item_id]?.reason || '', note: reasons[v.item_id]?.note || '' }));
    if (list.some((l) => !l.reason)) { setErr('Pick a reason for every difference.'); return; }
    if (list.some((l) => l.reason === 'Other' && !l.note.trim())) { setErr('Add a short note where the reason is Other.'); return; }
    setBusy(true); setErr(null);
    try { await rpc('set_count_reasons', { p_session: id, p_reasons: list }); qc.invalidateQueries({ queryKey: ['counts'] }); setStage('done'); }
    catch (e) { setErr(cleanError(e)); } finally { setBusy(false); }
  }

  const title = `Count ${s.ref}`;
  if (stage === 'queued') return <><MTop title={title} /><QueueBanner /><Done title="Queued · will sync" body={`Your count is saved on this phone. When data returns it goes to ${owner} for approval. Nothing changes in stock until then.`} action="Back to counts" onAction={() => nav('/m/count')} icon="clock" tone="amber" /></>;
  if (stage === 'submitted' || stage === 'done') return <><MTop title={title} /><Done title="Submitted" body={`${stage === 'done' ? 'Thanks for the reasons. ' : 'Every count matched. '}${owner} approves the adjustments; stock changes only after that.`} action="Back to counts" onAction={() => nav('/m/count')} /></>;
  if (stage === 'reasons') {
    return (
      <>
        <MTop title={title} />
        <div className="m-pad stack" style={{ gap: 12, flex: 1, overflowY: 'auto' }}>
          <div className="muted" style={{ fontSize: 13, lineHeight: 1.45 }}>{variances.length} item{variances.length === 1 ? '' : 's'} came out different from the books. Tell {owner} what you think happened.</div>
          {variances.map((v) => (
            <div key={v.item_id} className="m-card stack" style={{ gap: 8 }}>
              <div className="row" style={{ justifyContent: 'space-between' }}><b style={{ fontSize: 13 }}>{v.name}</b><span style={{ fontSize: 12, fontWeight: 700, color: v.variance < 0 ? '#DC2626' : '#15803D' }}>{v.variance < 0 ? `${num(-v.variance)} short` : `${num(v.variance)} over`}</span></div>
              <div className="row wrap" style={{ gap: 6 }}>
                {REASONS.map((r) => <button key={r} className={'pill' + (reasons[v.item_id]?.reason === r ? ' on' : '')} style={{ padding: '6px 10px', fontSize: 12 }} onClick={() => setReasons((x) => ({ ...x, [v.item_id]: { reason: r, note: x[v.item_id]?.note || '' } }))}>{r}</button>)}
              </div>
              {reasons[v.item_id]?.reason === 'Other' && <input className="input" placeholder="What happened?" value={reasons[v.item_id]?.note || ''} onChange={(e) => setReasons((x) => ({ ...x, [v.item_id]: { reason: 'Other', note: e.target.value } }))} />}
            </div>
          ))}
          {err && <div className="alert alert-red">{err}</div>}
        </div>
        <div className="m-foot"><button className="m-btn" disabled={busy} onClick={saveReasons}>Send reasons</button></div>
      </>
    );
  }
  return (
    <>
      <MTop title={title} />
      <QueueBanner />
      <div style={{ padding: '12px 16px 0', fontSize: 12, color: '#6B7280', lineHeight: 1.45 }}>{s.area} · {loc} · assigned by {owner}. Find each product, then type what you see in selling units. Expected quantities are hidden.{!queue.online ? ' You can finish offline; it submits when data returns.' : ''}</div>
      <div className="m-pad stack" style={{ gap: 10, flex: 1, overflowY: 'auto' }}>
        {lines.map((l) => {
          const v = vals[l.item_id] ?? '';
          const n = Number(v);
          return (
            <div key={l.item_id} className="m-card row" style={{ gap: 12 }}>
              <Thumb name={l.name} path={l.photo_path} size={40} />
              <div className="grow"><div style={{ fontSize: 13, fontWeight: 600 }}>{l.name}</div>
                <div className="faint" style={{ fontSize: 11 }}>{v !== '' && l.pack_size > 1 && n >= l.pack_size ? `= ${Math.floor(n / l.pack_size)} ${puAbbr(l.purchase_unit)}${n % l.pack_size ? ` + ${num(n % l.pack_size)}` : ''}` : `Count ${pluralUnit(l.selling_unit, 2)}${l.pack_size > 1 ? ` · 1 ${l.purchase_unit.toLowerCase()} = ${l.pack_size}` : ''}`}</div></div>
              <input type="number" inputMode="numeric" min={0} value={v} placeholder="0" aria-label={'Count of ' + l.name}
                onChange={(e) => setVals((x) => ({ ...x, [l.item_id]: e.target.value }))}
                style={{ width: 80, border: '1px solid ' + (v !== '' ? '#B9D4FF' : '#E6E6E6'), borderRadius: 8, padding: '9px 10px', fontSize: 16, fontWeight: 600, textAlign: 'right' }} />
            </div>
          );
        })}
        {err && <div className="alert alert-red">{err}</div>}
      </div>
      <div className="m-foot">
        <button className="m-btn" disabled={!ready || busy} onClick={submit}>{ready ? (busy ? 'Submitting…' : 'Submit count') : `Count all ${lines.length} items to submit (${counted} done)`}</button>
      </div>
    </>
  );
}
