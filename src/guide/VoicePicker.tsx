// Choosing the Nigerian voice that announces payments: hear each one (in English or Pidgin), choose, then hear a pretend
// payment land in that voice. Used by the guide, the checklist and Settings.
import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useSession, useToast } from '../state/session';
import { guideMark, saveVoice, useVoices, type Voice } from '../lib/onboard';
import { fetchSpeech, playAudio } from '../lib/speech';
import { rpc } from '../lib/supabase';
import { Icon } from '../components/Icon';
import { Alert, Modal, ModalHead, Seg, Spinner } from '../components/ui';
import { useQuery } from '@tanstack/react-query';
import { useGuideTalk } from './GuideProvider';

export interface VoiceSettings { voice_id: string | null; voice_lang: 'en' | 'pcm'; events: Record<string, boolean>; can_edit: boolean; voices: Voice[] }
export function useVoiceSettings(orgId: string | null | undefined) {
  return useQuery({ queryKey: ['voice-settings', orgId], enabled: !!orgId, queryFn: () => rpc<VoiceSettings>('voice_settings', { p_org: orgId }) });
}

export function VoicePicker({ onChosen, compact }: { onChosen?: () => void; compact?: boolean }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const g = useGuideTalk();
  const list = useVoices();
  const settings = useVoiceSettings(orgId);
  const s = settings.data;
  const [lang, setLang] = useState<'en' | 'pcm' | null>(null);
  const [playing, setPlaying] = useState<string | null>(null);
  const [saving, setSaving] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const language = lang || s?.voice_lang || 'en';
  const voices = list.data?.voices || [];

  async function hear(v: Voice) {
    setErr(null); setPlaying(v.voice_id);
    const r = await fetchSpeech('preview', { voice_id: v.voice_id, lang: language }, 8000);
    if (r.ok && r.audio) await playAudio(r.audio, r.mime); else setErr(r.error || 'That voice did not play. Try another one.');
    setPlaying(null);
    void guideMark('voice_previewed').catch(() => null);
  }
  async function choose(v: Voice) {
    if (!orgId) return;
    setErr(null); setSaving(v.voice_id);
    try {
      await saveVoice(orgId, { voice_id: v.voice_id, voice_lang: language });
      await guideMark('voice_chosen').catch(() => null);
      await qc.invalidateQueries({ queryKey: ['voice-settings'] }); void qc.invalidateQueries({ queryKey: ['guide'] });
      g.answer(`I'll take ${v.name}, in ${language === 'pcm' ? 'Pidgin' : 'English'}.`, 'Saved on screen as the voice that announces payments.');
      // The moment: a pretend payment lands, in the voice just chosen.
      const r = await fetchSpeech('payment_demo', { org_id: orgId }, 8000);
      g.celebrate();
      if (r.ok && r.audio) await playAudio(r.audio, r.mime);
      void guideMark('payment_demo').catch(() => null);
      toast(`${v.name} will announce your payments`);
      onChosen?.();
    } catch (e) { setErr((e as Error).message); } finally { setSaving(null); }
  }

  if (list.isLoading || settings.isLoading) return <div className="row" style={{ justifyContent: 'center', padding: 24 }}><Spinner /></div>;
  if (!list.data?.configured) return <Alert kind="grey" icon="volume">Nigerian voices are not available yet. TaxStreem is setting them up; the phone's own voice announces payments meanwhile.</Alert>;
  if (!voices.length) return <Alert kind="amber" icon="volume">No voices are ready yet. Try again in a minute.</Alert>;
  return (
    <div className="stack" style={{ gap: 12 }}>
      <div className="row wrap" style={{ justifyContent: 'space-between', gap: 8 }}>
        {!compact && <div className="muted" style={{ fontSize: 13 }}>Tap a voice to hear it. This voice says "payment received" when money lands.</div>}
        <Seg value={language} onChange={(v) => setLang(v)} options={[{ id: 'en', label: 'English' }, { id: 'pcm', label: 'Pidgin' }]} />
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(150px, 1fr))', gap: 10 }}>
        {voices.map((v) => {
          const on = s?.voice_id === v.voice_id;
          return (
            <div key={v.voice_id} className={'ob-tile' + (on ? ' on' : '')} style={{ cursor: 'default' }}>
              <div className="row" style={{ justifyContent: 'space-between' }}>
                <b style={{ fontSize: 15 }}>{v.name}</b>
                {on && <span className="chip t-green" style={{ fontSize: 11 }}>Chosen</span>}
              </div>
              <div className="faint" style={{ fontSize: 12, textTransform: 'capitalize' }}>{[v.gender, v.age?.replace('_', ' ')].filter(Boolean).join(' · ') || 'Nigerian voice'}</div>
              <div className="row" style={{ gap: 6, marginTop: 6 }}>
                <button className="btn btn-secondary btn-xs" onClick={() => hear(v)} disabled={!!playing} aria-label={`Hear ${v.name}`}>
                  {playing === v.voice_id ? <Spinner small /> : <Icon name="volume" size={13} />}Hear
                </button>
                {s?.can_edit !== false && (
                  <button className="btn btn-primary btn-xs" onClick={() => choose(v)} disabled={!!saving} aria-label={`Choose ${v.name}`}>
                    {saving === v.voice_id ? <Spinner small /> : <Icon name="check" size={13} color="#fff" />}{on ? 'Again' : 'Choose'}
                  </button>
                )}
              </div>
            </div>
          );
        })}
      </div>
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
    </div>
  );
}

export function VoicePickerModal({ onClose }: { onClose: () => void }) {
  return (
    <Modal onClose={onClose} width={620} z={90}>
      <ModalHead title="Choose your payment voice" sub="Real Nigerian voices. Pick the one you want to hear every time money lands." onClose={onClose} />
      <div className="modal-body"><VoicePicker onChosen={onClose} /></div>
    </Modal>
  );
}
