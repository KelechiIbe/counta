import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useInventory } from '../state/session';
import { when } from '../lib/format';
import {
  ACTIVE, CALL_STATUS, TOPICS, callDetails, callDuration, callHeadline, useVoiceCalls, useVoiceStatus, voice,
  type ReminderTopic, type VoiceCall,
} from '../lib/voice';
import type { Member } from '../lib/types';
import { Icon } from './Icon';
import { Alert, Chip, Label, Modal, ModalHead } from './ui';
import { isOn, PAUSED, useFeatures } from '../lib/features';

export function CallChip({ c }: { c: Pick<VoiceCall, 'status'> }) {
  const s = CALL_STATUS[c.status];
  return <Chip label={s.label} t={s.t} />;
}

// Everything a call produced: the outcome fields, ElevenLabs' summary and the transcript on demand.
export function CallResult({ c }: { c: VoiceCall }) {
  const [open, setOpen] = useState(false);
  const live = ACTIVE.includes(c.status);
  const rows = callDetails(c);
  return (
    <div className="stack" style={{ gap: 10 }}>
      <div className="row" style={{ gap: 10, alignItems: 'flex-start' }}>
        <span style={{ width: 34, height: 34, borderRadius: 10, display: 'grid', placeItems: 'center', background: live ? '#F0F7FF' : '#FAFAFA', flex: 'none' }}>
          <Icon name="call" size={16} color={live ? '#0072F5' : '#6B7280'} />
        </span>
        <div className="grow" style={{ minWidth: 0 }}>
          <div style={{ fontSize: 14, fontWeight: 600 }}>{callHeadline(c)}</div>
          <div className="muted" style={{ fontSize: 12, marginTop: 2 }}>{c.to_number} · {when(c.created_at)}{c.duration_secs ? ` · ${callDuration(c.duration_secs)}` : ''}</div>
        </div>
        <CallChip c={c} />
      </div>
      {live && <div className="hint">Martina is handling it. This updates on its own, so you can close this and carry on.</div>}
      {rows.length > 0 && (
        <div style={{ background: '#FAFAFA', borderRadius: 12, padding: '10px 14px', display: 'grid', gap: 6, fontSize: 13 }}>
          {rows.map((r) => <div key={r.label} className="row" style={{ gap: 10, alignItems: 'baseline' }}><span className="muted" style={{ width: 96, flex: 'none', fontSize: 12 }}>{r.label}</span><span>{r.value}</span></div>)}
        </div>
      )}
      {c.summary && <div className="ink3" style={{ fontSize: 13, lineHeight: 1.5 }}>{c.summary}</div>}
      {c.transcript && c.transcript.length > 0 && (
        <div>
          <button className="btn btn-ghost btn-xs" style={{ paddingLeft: 0 }} onClick={() => setOpen(!open)}>{open ? 'Hide transcript' : 'Read the transcript'}</button>
          {open && (
            <div className="stack" style={{ gap: 6, marginTop: 6, maxHeight: 280, overflowY: 'auto', fontSize: 13 }}>
              {c.transcript.map((t, i) => (
                <div key={i} style={{ alignSelf: t.role === 'agent' ? 'flex-start' : 'flex-end', maxWidth: '85%', background: t.role === 'agent' ? '#F3F4F6' : '#F0F7FF', borderRadius: 12, padding: '8px 12px', lineHeight: 1.45 }}>
                  <span className="faint" style={{ display: 'block', fontSize: 10, marginBottom: 2 }}>{t.role === 'agent' ? 'Martina' : 'Them'}</span>{t.text}
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

export function CallList({ calls, names }: { calls: VoiceCall[]; names?: (c: VoiceCall) => string }) {
  const [open, setOpen] = useState<string | null>(null);
  return (
    <div>
      {calls.map((c) => (
        <div key={c.id} style={{ borderTop: '1px solid #F3F4F6' }}>
          <button className="row" onClick={() => setOpen(open === c.id ? null : c.id)}
            style={{ width: '100%', gap: 12, padding: '12px 20px', border: 0, background: 'transparent', textAlign: 'left', font: 'inherit', cursor: 'pointer' }}>
            <Icon name="call" size={15} color={ACTIVE.includes(c.status) ? '#0072F5' : '#9CA3AF'} />
            <span className="grow" style={{ minWidth: 0 }}>
              <span style={{ display: 'block', fontSize: 13, fontWeight: 600 }}>{names ? names(c) : c.to_number}</span>
              <span className="muted" style={{ display: 'block', fontSize: 12, marginTop: 1 }}>{callHeadline(c)}</span>
            </span>
            <span className="muted hide-sm" style={{ fontSize: 12 }}>{when(c.created_at)}</span>
            <CallChip c={c} />
          </button>
          {open === c.id && <div style={{ padding: '0 20px 14px' }}><CallResult c={c} /></div>}
        </div>
      ))}
    </div>
  );
}

function SetupNote({ reason }: { reason?: string | null }) {
  return (
    <Alert kind="yellow" icon="call">
      {reason === 'paused' ? PAUSED.phone_calls
        : reason === 'error' ? 'The phone line did not answer just now. Try again shortly, or send the order by WhatsApp or email.'
        : 'Phone calls are not available yet. TaxStreem is setting them up; send orders and reminders by WhatsApp or email meanwhile.'}
    </Alert>
  );
}

function LiveCall({ id, filter }: { id: string; filter: { po_id?: string; member_id?: string } }) {
  const calls = useVoiceCalls({ ...filter, limit: 5 });
  const c = (calls.data || []).find((x) => x.id === id);
  if (!c) return <div className="muted" style={{ fontSize: 13 }}>Starting the call…</div>;
  return <CallResult c={c} />;
}

// Martina phones the vendor on a purchase order, reads it out and records what they agree.
export function VendorCallModal({ po, vendor, lines, onClose }: {
  po: { id: string; ref: string; total?: number | null }; vendor: { name: string; phone: string | null }; lines: string[]; onClose: () => void;
}) {
  const { data: inv } = useInventory();
  const status = useVoiceStatus();
  const qc = useQueryClient();
  const history = useVoiceCalls({ po_id: po.id, limit: 5 });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [callId, setCallId] = useState<string | null>(null);
  const feats = useFeatures();
  const paused = !isOn(feats.data, 'phone_calls');
  const ready = status.data?.configured && !paused;
  const live = (history.data || []).find((c) => ACTIVE.includes(c.status));
  async function call() {
    setBusy(true); setErr(null);
    const r = await voice<{ call_id?: string }>('call_vendor', { po_id: po.id });
    setBusy(false);
    if (r.call_id) setCallId(r.call_id);
    if (!r.ok && !r.call_id) { setErr(r.error || 'The call could not start.'); return; }
    if (!r.ok) setErr(r.error || 'The call could not start.');
    qc.invalidateQueries({ queryKey: ['voice-calls'] });
  }
  const shown = callId || live?.id || null;
  return (
    <Modal onClose={onClose} width={520}>
      <ModalHead title={`Call ${vendor.name}`} sub={`${po.ref} · Martina places the order by phone`} onClose={onClose} />
      <div className="modal-body">
        {shown ? <LiveCall id={shown} filter={{ po_id: po.id }} /> : (
          <>
            <div className="ink3" style={{ fontSize: 14, lineHeight: 1.55 }}>
              Martina rings {vendor.phone || 'the vendor'}, says she is an AI assistant calling for {inv?.org.name || 'your business'}, and reads out the order:
            </div>
            <div style={{ background: '#FAFAFA', borderRadius: 12, padding: '12px 14px', fontSize: 13, lineHeight: 1.6 }}>
              {lines.map((l, i) => <div key={i}>{l}</div>)}
            </div>
            <div className="hint">She confirms quantities and the delivery date, notes anything out of stock or repriced, and never discusses payment details. If the vendor confirms, the order is marked sent and you get a notification with what was agreed.</div>
          </>
        )}
        {status.data && !ready && !shown && <SetupNote reason={paused ? 'paused' : status.data.reason} />}
        {!vendor.phone && !shown && <Alert kind="yellow" icon="alert">Add a phone number for {vendor.name} first.</Alert>}
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
        {!shown && (history.data || []).length > 0 && (
          <div>
            <Label style={{ marginBottom: 6 }}>Earlier calls about {po.ref}</Label>
            <div className="card" style={{ borderRadius: 12, overflow: 'hidden' }}><CallList calls={history.data!} names={() => vendor.name} /></div>
          </div>
        )}
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>{shown ? 'Close' : 'Cancel'}</button>
        {!shown && <button className="btn btn-primary" onClick={call} disabled={busy || !ready || !vendor.phone}><Icon name="call" size={16} color="#fff" />{busy ? 'Dialling…' : 'Call now'}</button>}
      </div>
    </Modal>
  );
}

// Martina phones a team member about something waiting for them in the app.
export function ReminderCallModal({ member, onClose }: { member: Member; onClose: () => void }) {
  const status = useVoiceStatus();
  const qc = useQueryClient();
  const [topic, setTopic] = useState<ReminderTopic>('count_due');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [callId, setCallId] = useState<string | null>(null);
  const first = member.display_name.split(' ')[0];
  const feats = useFeatures();
  const paused = !isOn(feats.data, 'phone_calls');
  const ready = status.data?.configured && !paused;
  async function call() {
    setBusy(true); setErr(null);
    const r = await voice<{ call_id?: string }>('call_member', { member_id: member.id, topic });
    setBusy(false);
    if (r.call_id) setCallId(r.call_id);
    if (!r.ok) setErr(r.error || 'The call could not start.');
    qc.invalidateQueries({ queryKey: ['voice-calls'] });
  }
  return (
    <Modal onClose={onClose} width={480}>
      <ModalHead title={`Call ${first}`} sub={member.phone ? `Martina rings ${member.phone} with a short reminder` : 'No phone number saved'} onClose={onClose} />
      <div className="modal-body">
        {callId ? <LiveCall id={callId} filter={{ member_id: member.id }} /> : (
          <>
            <div className="field-label">What is the call about?</div>
            <div className="stack" style={{ gap: 6 }}>
              {TOPICS.map((t) => (
                <label key={t.id} className="row" style={{ gap: 10, border: '1px solid ' + (topic === t.id ? '#0072F5' : '#E5E7EB'), background: topic === t.id ? '#F0F7FF' : '#fff', borderRadius: 12, padding: '10px 12px', cursor: 'pointer' }}>
                  <input type="radio" name="topic" checked={topic === t.id} onChange={() => setTopic(t.id)} />
                  <span><span style={{ display: 'block', fontSize: 14, fontWeight: 600 }}>{t.label}</span><span className="muted" style={{ display: 'block', fontSize: 12 }}>{t.who}</span></span>
                </label>
              ))}
            </div>
            <div className="hint">Martina tells {first} exactly what is waiting and how to finish it in Counta, then asks when it will be done. You get a notification with the answer.</div>
          </>
        )}
        {status.data && !ready && !callId && <SetupNote reason={paused ? 'paused' : status.data.reason} />}
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>{callId ? 'Close' : 'Cancel'}</button>
        {!callId && <button className="btn btn-primary" onClick={call} disabled={busy || !ready || !member.phone}><Icon name="call" size={16} color="#fff" />{busy ? 'Dialling…' : 'Call now'}</button>}
      </div>
    </Modal>
  );
}

// Recent calls for the whole business, for the Reorder page and Settings.
export function RecentCalls({ title = 'Phone calls by Martina' }: { title?: string }) {
  const { data: inv } = useInventory();
  const calls = useVoiceCalls({ limit: 8 });
  if (!inv || !calls.data?.length) return null;
  const name = (c: VoiceCall) => c.kind === 'vendor_order'
    ? `${inv.vendors.find((v) => v.id === c.vendor_id)?.name || 'Vendor'}${c.variables?.po_ref ? ' · ' + c.variables.po_ref : ''}`
    : `${inv.members.find((m) => m.id === c.member_id)?.display_name || 'Team member'} · ${TOPICS.find((t) => t.id === c.topic)?.label || 'reminder'}`;
  return (
    <div className="card" style={{ overflow: 'hidden' }}>
      <div className="card-hd"><Label>{title}</Label><span className="faint" style={{ fontSize: 12 }}>Tap a call for what was agreed</span></div>
      <CallList calls={calls.data} names={name} />
    </div>
  );
}
