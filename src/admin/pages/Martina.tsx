// Martina's manner on calls and in the app, her default voice, and the Nigerian voices businesses may choose from.
import { useRef, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { rpc } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { num, when } from '../../lib/format';
import { useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Field, Pills, SkeletonRows, Spinner } from '../../components/ui';
import { type Settings, tidyError, useSettings } from '../api';
import { Card, PageHead, Toggle } from '../ui';

const TONES: { id: 'calm' | 'warm' | 'lively'; label: string; what: string }[] = [
  { id: 'calm', label: 'Calm', what: 'Steady and unhurried, with no expressive cues. Pleased when things go well, never excited.' },
  { id: 'warm', label: 'Warm', what: 'Calm, with a few gentle cues: warm when greeting or thanking, reassuring when something went wrong. The cues need Eleven v4 Turbo.' },
  { id: 'lively', label: 'Lively', what: 'The more animated delivery Martina had before. Expressive cues are free with Eleven v4 Turbo.' },
];

// The ElevenLabs model she speaks with. v4 Turbo is the most lifelike; the v2.5 models read plainly and never sigh or laugh.
const MODELS: { id: 'eleven_v4_turbo' | 'eleven_turbo_v2_5' | 'eleven_flash_v2_5'; label: string; what: string }[] = [
  { id: 'eleven_v4_turbo', label: 'Natural · Eleven v4 Turbo', what: 'The most lifelike, and what she has used so far. It can add the odd breath or sigh; her instructions now rule them out.' },
  { id: 'eleven_turbo_v2_5', label: 'Steady · Turbo v2.5', what: 'Clear and even. Never sighs or laughs, and sounds a little less lively.' },
  { id: 'eleven_flash_v2_5', label: 'Plain · Flash v2.5', what: 'The quickest to answer and the flattest delivery. Never sighs or laughs.' },
];

// One player for every preview on the page, so two never talk over each other.
function usePlayer() {
  const a = useRef<HTMLAudioElement | null>(null);
  const [playing, setPlaying] = useState<string | null>(null);
  function play(id: string, url: string | null) {
    if (!url) return;
    a.current?.pause();
    if (playing === id) { setPlaying(null); return; }
    const el = new Audio(url); a.current = el;
    el.onended = () => setPlaying(null);
    el.play().then(() => setPlaying(id)).catch(() => setPlaying(null));
  }
  return { playing, play };
}

type Lib = { voice_id: string; public_owner_id: string; name: string; gender: string | null; age: string | null; accent: string | null; description: string | null; preview_url: string | null; added: boolean };

export default function Martina() {
  const s = useSettings();
  const qc = useQueryClient();
  const toast = useToast();
  const p = usePlayer();
  const [busy, setBusy] = useState<string | null>(null);
  const [gender, setGender] = useState<'female' | 'male'>('female');
  const [lib, setLib] = useState<Lib[] | null>(null);
  const [libErr, setLibErr] = useState<string | null>(null);
  // The choice shows at once; it goes back if the save is refused.
  const [tone, setTone] = useState<string | null>(null);
  const [model, setModel] = useState<string | null>(null);
  const d = s.data;
  async function save(patch: Partial<Settings['martina']>, ok: string) {
    setBusy('m');
    try { await rpc('admin_save_setting', { p_key: 'martina', p_value: patch }); toast(ok); await qc.invalidateQueries({ queryKey: ['admin-settings'] }); }
    catch (e) { toast(tidyError(e), 'err'); setTone(null); setModel(null); }
    setBusy(null);
  }
  async function offer(id: string, active: boolean) {
    setBusy(id);
    try { await rpc('admin_set_voice', { p_voice: id, p_active: active }); await qc.invalidateQueries({ queryKey: ['admin-settings'] }); }
    catch (e) { toast(tidyError(e), 'err'); }
    setBusy(null);
  }
  async function browse(g = gender) {
    setBusy('lib'); setLibErr(null);
    const r = await edge<{ voices: Lib[] }>('voice', { action: 'admin_library', gender: g });
    setBusy(null);
    if (r.ok === false) { setLibErr(r.error || 'The library did not answer.'); return; }
    setLib(r.voices || []);
  }
  async function add(v: Lib) {
    setBusy(v.voice_id);
    const r = await edge('voice', { action: 'admin_add_voice', ...v });
    setBusy(null);
    if (r.ok === false) { toast(r.error || 'Not added.', 'err'); return; }
    toast(`${v.name} is on offer`);
    setLib((l) => (l || []).map((x) => (x.voice_id === v.voice_id ? { ...x, added: true } : x)));
    await qc.invalidateQueries({ queryKey: ['admin-settings'] });
  }
  if (s.isLoading) return <SkeletonRows n={6} />;
  if (s.isError || !d) return <Alert kind="red" icon="alert">{tidyError(s.error)}</Alert>;
  const active = d.voices.filter((v) => v.active);
  return (
    <>
      <PageHead title="Martina and voices" sub="How Martina sounds on phone calls and in the app, for every business. Agents pick up a change on their next conversation." />
      <Card title="Her manner" sub={d.updated.martina ? `Changed ${when(d.updated.martina.at)}${d.updated.martina.by ? ` by ${d.updated.martina.by}` : ''}` : 'As Counta set it.'}>
        <div className="stack" style={{ gap: 8 }} role="radiogroup" aria-label="Martina's manner">
          {TONES.map((t) => (
            <label key={t.id} className="row" style={{ gap: 10, alignItems: 'flex-start', cursor: 'pointer', padding: '10px 12px', border: '1px solid var(--line)', borderRadius: 12,
              background: (tone ?? d.martina.tone) === t.id ? 'var(--primary-soft)' : '#fff' }}>
              <input type="radio" name="tone" checked={(tone ?? d.martina.tone) === t.id} disabled={busy !== null} onChange={() => { setTone(t.id); void save({ tone: t.id }, `Martina is ${t.label.toLowerCase()} now`); }} style={{ marginTop: 3 }} />
              <span><b>{t.label}</b><span className="muted" style={{ display: 'block', fontSize: 13, lineHeight: 1.5 }}>{t.what}</span></span>
            </label>
          ))}
        </div>
        <div className="stack" style={{ gap: 8 }} role="radiogroup" aria-label="Martina's voice model" data-testid="voice-model">
          <b style={{ fontSize: 14, marginTop: 6 }}>Her voice model</b>
          <span className="muted" style={{ fontSize: 13, marginTop: -4 }}>For Martina everywhere: the setup guide, the assistant and her phone calls. Try one, then talk to her.</span>
          {MODELS.map((m) => {
            const cur = model ?? d.martina.voice_model ?? 'eleven_v4_turbo';
            return (
              <label key={m.id} className="row" style={{ gap: 10, alignItems: 'flex-start', cursor: 'pointer', padding: '10px 12px', border: '1px solid var(--line)', borderRadius: 12,
                background: cur === m.id ? 'var(--primary-soft)' : '#fff' }}>
                <input type="radio" name="voice_model" checked={cur === m.id} disabled={busy !== null} onChange={() => { setModel(m.id); void save({ voice_model: m.id }, `Martina speaks with ${m.label.split(' · ')[1]} now`); }} style={{ marginTop: 3 }} />
                <span><b>{m.label}</b><span className="muted" style={{ display: 'block', fontSize: 13, lineHeight: 1.5 }}>{m.what}</span></span>
              </label>
            );
          })}
        </div>
        <Field label="Her voice where a business has not chosen one" hint="Calls and the in-app guide use the business's own announcement voice when it has one.">
          <select className="input" style={{ maxWidth: 360 }} value={d.martina.default_voice_id || ''} disabled={busy !== null}
            onChange={(e) => save({ default_voice_id: e.target.value || null }, 'Martina\'s voice saved')}>
            <option value="">The first voice on offer</option>
            {active.map((v) => <option key={v.voice_id} value={v.voice_id}>{v.name}{v.gender ? ` (${v.gender})` : ''}</option>)}
          </select>
        </Field>
      </Card>
      <Card title={`Voices on offer (${active.length})`} sub="Businesses choose their announcement voice from these. A voice taken off stays with the businesses that already use it." pad={false}>
        {d.voices.map((v) => (
          <div key={v.voice_id} className="adm-row" style={{ gridTemplateColumns: 'auto minmax(0,1fr) 140px auto' }}>
            <button className="btn btn-secondary btn-sm" disabled={!v.preview_url} onClick={() => p.play(v.voice_id, v.preview_url)} aria-label={`Play ${v.name}`}>
              <Icon name={p.playing === v.voice_id ? 'stop' : 'volume'} size={14} />
            </button>
            <div style={{ minWidth: 0 }}><b>{v.name}</b> <span className="faint" style={{ fontSize: 12 }}>{[v.gender, v.age, v.accent].filter(Boolean).join(' · ')}</span>
              {v.description && <div className="faint ellipsis" style={{ fontSize: 12 }}>{v.description}</div>}</div>
            <span className="faint" style={{ fontSize: 12 }}>{num(v.businesses)} business{v.businesses === 1 ? '' : 'es'}{d.martina.default_voice_id === v.voice_id ? ' · Martina' : ''}</span>
            <span className="row" style={{ gap: 6 }}>{busy === v.voice_id && <Spinner small />}<Toggle on={v.active} disabled={busy !== null} label={`Offer ${v.name}`} onChange={(on) => offer(v.voice_id, on)} /></span>
          </div>
        ))}
        {!d.voices.length && <div className="card-pad muted" style={{ fontSize: 14 }}>No voices yet. They load from ElevenLabs the first time a business opens its voice settings, or add some below.</div>}
      </Card>
      <Card title="Find more Nigerian voices" sub="From the ElevenLabs voice library, most used first. Adding one puts it on offer at once."
        right={<div className="row" style={{ gap: 8 }}>
          <Pills value={gender} onChange={(g) => { setGender(g); if (lib) void browse(g); }} options={[{ id: 'female', label: 'Female' }, { id: 'male', label: 'Male' }]} />
          <button className="btn btn-secondary btn-sm" disabled={busy === 'lib'} onClick={() => browse()}>{busy === 'lib' ? <Spinner small /> : <Icon name="search" size={14} />}{lib ? 'Refresh' : 'Show voices'}</button>
        </div>} pad={false}>
        {libErr && <div style={{ padding: 16 }}><Alert kind="red" icon="alert">{libErr}</Alert></div>}
        {lib && !lib.length && <div className="card-pad muted" style={{ fontSize: 14 }}>No voices found.</div>}
        {(lib || []).map((v) => (
          <div key={v.voice_id} className="adm-row" style={{ gridTemplateColumns: 'auto minmax(0,1fr) auto' }}>
            <button className="btn btn-secondary btn-sm" disabled={!v.preview_url} onClick={() => p.play('lib' + v.voice_id, v.preview_url)} aria-label={`Play ${v.name}`}>
              <Icon name={p.playing === 'lib' + v.voice_id ? 'stop' : 'volume'} size={14} />
            </button>
            <div style={{ minWidth: 0 }}><b>{v.name}</b> <span className="faint" style={{ fontSize: 12 }}>{[v.gender, v.age, v.accent].filter(Boolean).join(' · ')}</span>
              {v.description && <div className="faint ellipsis" style={{ fontSize: 12 }}>{v.description}</div>}</div>
            {v.added ? <span className="chip t-green">On the list</span>
              : <button className="btn btn-primary btn-sm" disabled={busy !== null} onClick={() => add(v)}>{busy === v.voice_id ? <Spinner small /> : <Icon name="plus" size={14} color="#fff" />}Add</button>}
          </div>
        ))}
      </Card>
    </>
  );
}
