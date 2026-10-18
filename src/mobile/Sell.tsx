import { useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { can, useInventory, useSession } from '../state/session';
import { ai } from '../lib/supabase';
import { aiStatus } from '../lib/martina';
import { N, num } from '../lib/format';
import { pluralUnit } from '../lib/domain';
import type { Item } from '../lib/types';
import { Icon } from '../components/Icon';
import { Spinner } from '../components/ui';
import { BranchChip, MTop, QueueBanner, useM } from './ctx';
import { Done, ItemSearch, SaleSheet } from './common';
import { enqueue } from './queue';
import { toWav } from '../lib/audio';
import { announce, browserSay } from '../lib/speech';

type Heard = { transcript: string; movement: 'sale' | 'receipt' | 'unknown'; item_id: string | null; qty: number | null; unit_kind?: 'purchase' | 'selling'; location_name?: string | null; confidence: number; readback: string; problem?: string | null };

function pickMime(): string {
  const M: any = (window as any).MediaRecorder;
  if (!M) return '';
  for (const t of ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg;codecs=opus']) if (M.isTypeSupported?.(t)) return t;
  return '';
}
const toB64 = (b: Blob) => new Promise<string>((res, rej) => { const r = new FileReader(); r.onload = () => res(String(r.result).split(',')[1] || ''); r.onerror = rej; r.readAsDataURL(b); });
// The sale said back in the business's Nigerian voice; the phone's own voice reads the line when offline.
function speak(text: string, sale?: { org_id: string; item_id: string; qty: number; amount: number }) {
  if (sale && navigator.onLine) { void announce('sale_recorded', sale, text, { chime: false }); return; }
  browserSay(text);
}

export default function SellScreen() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const { loc, queue } = useM();
  const nav = useNavigate();
  const status = useQuery({ queryKey: ['aiStatus'], queryFn: aiStatus, staleTime: 5 * 60 * 1000, enabled: queue.online });
  const [stage, setStage] = useState<'idle' | 'listening' | 'thinking' | 'heard' | 'done'>('idle');
  const [heard, setHeard] = useState<Heard | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [retries, setRetries] = useState(0);
  const [manual, setManual] = useState<Item | null>(null);
  const [fix, setFix] = useState(false);
  const [doneMsg, setDoneMsg] = useState('');
  const rec = useRef<{ mr: MediaRecorder; chunks: Blob[]; stream: MediaStream; timer: number } | null>(null);
  useEffect(() => () => { rec.current?.stream.getTracks().forEach((t) => t.stop()); window.clearTimeout(rec.current?.timer); }, []);
  if (!inv) return null;
  if (!can(inv, 'record_sales')) return <><MTop title="Sell" /><div className="m-pad muted">Your role does not record sales.</div></>;
  const me = inv.me;
  const voiceReady = queue.online && status.data?.configured && !!pickMime() && !!navigator.mediaDevices;
  const item = heard?.item_id ? inv.items.find((i) => i.id === heard.item_id) || null : null;
  const hereId = heard?.location_name ? inv.locations.find((l) => l.name.toLowerCase() === heard.location_name!.toLowerCase())?.id || loc : loc;
  const su = item && heard?.qty ? Number(heard.qty) * (heard.unit_kind === 'purchase' ? item.pack_size : 1) : 0;
  const pending = Number(me.voice_confirmed) < Number(inv.org.voice_trust_threshold);

  async function start() {
    setErr(null);
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const mime = pickMime();
      const mr = new MediaRecorder(stream, mime ? { mimeType: mime } : undefined);
      const chunks: Blob[] = [];
      mr.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
      mr.onstop = () => { stream.getTracks().forEach((t) => t.stop()); void understand(new Blob(chunks, { type: (mime || 'audio/webm').split(';')[0] })); };
      mr.start();
      const timer = window.setTimeout(() => { if (mr.state === 'recording') mr.stop(); }, 15000);
      rec.current = { mr, chunks, stream, timer };
      setStage('listening');
    } catch { setErr('The microphone is blocked. Allow it for this site, or record the sale by hand below.'); }
  }
  function stop() { const r = rec.current; if (r && r.mr.state === 'recording') { window.clearTimeout(r.timer); r.mr.stop(); } }
  async function understand(blob: Blob) {
    setStage('thinking');
    if (blob.size < 1200) { setErr('That was too short. Hold the button and say the full sentence.'); setStage('idle'); return; }
    try {
      const audio = await toWav(blob);
      const r = await ai<Heard & { ok: boolean }>('voice', {
        audio_base64: await toB64(audio), mime: audio.type || 'audio/webm',
        items: inv!.items.map((i) => ({ id: i.id, name: i.name, purchase_unit: i.purchase_unit, pack_size: i.pack_size, selling_unit: i.selling_unit })),
        locations: inv!.locations.map((l) => l.name),
      });
      if (!r.ok) { setErr(r.error || 'Could not understand that. Try again or record it by hand.'); setStage('idle'); return; }
      setHeard(r); setStage('heard');
    } catch (e: any) { setErr(e.message); setStage('idle'); }
  }
  async function confirm() {
    if (!heard || !item || !(su > 0) || !orgId) return;
    await enqueue({
      org: orgId, kind: 'sale', label: 'Voice sale', detail: `${num(Number(heard.qty))} ${heard.unit_kind === 'purchase' ? item.purchase_unit.toLowerCase() : item.selling_unit} ${item.name}`,
      payload: { item_id: item.id, location_id: hereId, qty: su, unit_price: Number(item.price), channel: 'Voice', voice: true, note: heard.transcript, voice_clean: retries === 0 },
      author: me.display_name,
    });
    const branch = inv!.locations.find((l) => l.id === hereId)?.name || '';
    const line = heard.readback || `${num(su)} ${pluralUnit(item.selling_unit, su)} of ${item.name} sold at ${branch}, ${N(su * Number(item.price))}.`;
    speak(line, { org_id: orgId!, item_id: item.id, qty: su, amount: su * Number(item.price) });
    setDoneMsg(`"${line}" Stock updated${pending ? '; the owner will review it' : ''}.`);
    setStage('done'); setRetries(0);
  }
  const reset = () => { setStage('idle'); setHeard(null); setErr(null); setManual(null); setFix(false); };

  if (stage === 'done') return <><MTop title="Talk to record" right={<BranchChip />} /><QueueBanner /><Done title="Recorded" body={doneMsg} action="Record another" onAction={reset} /></>;
  return (
    <>
      <MTop title="Talk to record" right={<BranchChip />} />
      <QueueBanner />
      <div className="m-pad stack" style={{ gap: 16, flex: 1 }}>
        {stage === 'heard' && heard ? (
          fix && item ? <SaleSheet item={item} voice={{ qty: Number(heard.qty) || 1, unit_kind: heard.unit_kind || 'selling', transcript: heard.transcript, clean: false, location_id: hereId }} onCancel={() => setFix(false)} onDone={(m) => { setDoneMsg(m); setStage('done'); }} /> : (
            <div className="stack rise" style={{ gap: 12 }}>
              <div className="muted" style={{ fontSize: 12 }}>I heard</div>
              <div style={{ fontSize: 15, fontStyle: 'italic', background: '#FAFAFA', borderRadius: 12, padding: 12 }}>"{heard.transcript}"</div>
              <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>I understood</div>
              {heard.movement === 'sale' && item && su > 0 ? (
                <div className="m-card stack" style={{ gap: 8, padding: 14 }}>
                  <Row k="Movement" v="Sale" /><Row k="Item" v={item.name} />
                  <Row k="Quantity" v={heard.unit_kind === 'purchase' && item.pack_size > 1 ? `${num(Number(heard.qty))} ${pluralUnit(item.purchase_unit.toLowerCase(), Number(heard.qty))} = ${num(su)} ${pluralUnit(item.selling_unit, su)}` : `${num(su)} ${pluralUnit(item.selling_unit, su)}`} />
                  <Row k="Value" v={N(su * Number(item.price))} /><Row k="Location" v={inv.locations.find((l) => l.id === hereId)?.name || ''} />
                </div>
              ) : (
                <div className="alert alert-yellow">{heard.movement === 'receipt' ? 'That sounds like stock coming in. Receipts need the invoice photo, so use Receive.' : heard.problem || 'I could not match that to one item and quantity.'}</div>
              )}
              {pending && heard.movement === 'sale' && item && <div style={{ fontSize: 12, color: '#A16207', background: '#FEFCE8', borderRadius: 10, padding: 10, lineHeight: 1.45 }}>Voice entries from {me.display_name.split(' ')[0]} are flagged for owner review until {inv.org.voice_trust_threshold} are confirmed without correction ({me.voice_confirmed} so far).</div>}
              <div className="row" style={{ gap: 8, marginTop: 4 }}>
                <button className="m-btn secondary" style={{ flex: 1 }} onClick={() => { setRetries((r) => r + 1); setHeard(null); setStage('idle'); }}>Wrong, say again</button>
                {heard.movement === 'sale' && item && su > 0 ? <button className="m-btn" style={{ flex: 1 }} onClick={confirm}>Correct</button>
                  : heard.movement === 'receipt' ? <button className="m-btn" style={{ flex: 1 }} onClick={() => nav('/m/receive')}>Open Receive</button> : null}
              </div>
              {heard.movement === 'sale' && item && <button className="m-btn ghost" onClick={() => setFix(true)}>Close, but fix the quantity</button>}
            </div>
          )
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 16, padding: '12px 0 4px', textAlign: 'center' }}>
            {voiceReady ? (
              <>
                <div className="ink3" style={{ fontSize: 15, lineHeight: 1.5 }}>{stage === 'listening' ? 'Listening… tap again when you finish.' : stage === 'thinking' ? 'Understanding…' : <>Say what happened. For example:<br /><b style={{ color: '#111827' }}>"I don sell three cartons of Indomie"</b></>}</div>
                <button onClick={stage === 'listening' ? stop : start} disabled={stage === 'thinking'} aria-label={stage === 'listening' ? 'Stop recording' : 'Start recording'}
                  style={{ position: 'relative', width: 88, height: 88, borderRadius: '50%', border: 'none', background: '#0072F5', display: 'grid', placeItems: 'center', cursor: 'pointer', boxShadow: '0 12px 32px rgba(0,114,245,.28)' }}>
                  {stage === 'listening' && <span style={{ position: 'absolute', inset: 0, borderRadius: '50%', background: '#3E88FF', animation: 'tsPulse 1.2s ease-out infinite' }} />}
                  <span style={{ position: 'relative' }}>{stage === 'thinking' ? <Spinner small /> : <Icon name={stage === 'listening' ? 'stop' : 'mic'} size={32} color="#fff" />}</span>
                </button>
                <div className="faint" style={{ fontSize: 12 }}>Yoruba · Hausa · Igbo · Pidgin · English</div>
              </>
            ) : (
              <div className="alert alert-blue" style={{ textAlign: 'left' }}>
                {!queue.online ? 'Voice needs data to understand you. Record the sale by hand below; it saves on this phone and posts when data returns.'
                  : status.data && !status.data.configured ? 'Voice entry switches on when the owner adds a Gemini key. Record the sale by hand below for now.'
                  : 'This browser cannot record audio. Record the sale by hand below.'}
              </div>
            )}
            {err && <div className="alert alert-red" style={{ textAlign: 'left', width: '100%' }}>{err}</div>}
          </div>
        )}
        {stage !== 'heard' && (
          <div className="stack" style={{ gap: 8 }}>
            <div className="label">Or record by hand</div>
            {manual ? <SaleSheet item={manual} onCancel={() => setManual(null)} onDone={(m) => { setDoneMsg(m); setStage('done'); }} /> : <ItemSearch onPick={setManual} placeholder="Which item did you sell?" />}
          </div>
        )}
      </div>
    </>
  );
}

function Row({ k, v }: { k: string; v: string }) {
  return <div className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}><span className="muted">{k}</span><b style={{ textAlign: 'right' }}>{v}</b></div>;
}
