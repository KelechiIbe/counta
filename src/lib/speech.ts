// Spoken announcements in the business's Nigerian voice (ElevenLabs, through the voice function), with the phone's own
// voice as the fallback when the voice is off, over its daily allowance, offline or slow.
import { edge } from './api';

type Kind = 'payment_received' | 'sale_recorded' | 'payment_demo' | 'preview';
type Said = { ok?: boolean; enabled?: boolean; text?: string; audio?: string; mime?: string; reason?: string; error?: string; lang?: string };

let current: HTMLAudioElement | null = null;

export function chime() {
  try {
    const ctx = new (window.AudioContext || (window as any).webkitAudioContext)();
    const o = ctx.createOscillator(), g = ctx.createGain();
    o.connect(g); g.connect(ctx.destination);
    o.frequency.setValueAtTime(880, ctx.currentTime); o.frequency.setValueAtTime(1320, ctx.currentTime + 0.12);
    g.gain.setValueAtTime(0.15, ctx.currentTime); g.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.35);
    o.start(); o.stop(ctx.currentTime + 0.36);
    window.setTimeout(() => ctx.close?.().catch(() => {}), 600);
  } catch { /* no audio */ }
}

export function browserSay(text: string) {
  try {
    const u = new SpeechSynthesisUtterance(text);
    const voices = window.speechSynthesis.getVoices();
    u.voice = voices.find((v) => /en-NG/i.test(v.lang)) || voices.find((v) => /en-GB/i.test(v.lang)) || null;
    u.lang = u.voice?.lang || 'en-NG'; u.rate = 1;
    window.speechSynthesis.cancel(); window.setTimeout(() => window.speechSynthesis.speak(u), 120);
  } catch { /* no voice */ }
}

export function stopSpeech() {
  try { current?.pause(); } catch { /* ignore */ }
  current = null;
  try { window.speechSynthesis.cancel(); } catch { /* ignore */ }
}

// Plays base64 audio and resolves when it ends (or fails to start).
export function playAudio(b64: string, mime = 'audio/mpeg', volume = 1): Promise<boolean> {
  return new Promise((resolve) => {
    try {
      stopSpeech();
      const a = new Audio(`data:${mime};base64,${b64}`);
      a.volume = volume;
      current = a;
      a.onended = () => { if (current === a) current = null; resolve(true); };
      a.onerror = () => resolve(false);
      a.play().then(() => {}, () => resolve(false));
    } catch { resolve(false); }
  });
}

// Fetch the words and the audio for an announcement. Waits at most `waitMs`; past that the phone's voice speaks.
export async function fetchSpeech(kind: Kind, payload: Record<string, unknown>, waitMs = 4500): Promise<Said> {
  const timer = new Promise<Said>((res) => window.setTimeout(() => res({ ok: false, reason: 'slow' }), waitMs));
  return await Promise.race([edge<Said>('voice', { action: 'speak', kind, ...payload }).catch(() => ({ ok: false, reason: 'error' } as Said)), timer]);
}

// Say it in the business's voice; if that is not possible, say the same words with the phone's voice.
export async function announce(kind: Kind, payload: Record<string, unknown>, fallback: string, opts: { chime?: boolean } = {}) {
  if (opts.chime !== false) chime();
  if (!navigator.onLine) { browserSay(fallback); return { voice: false }; }
  const r = await fetchSpeech(kind, payload);
  if (r.ok && r.enabled === false) return { voice: false, off: true };
  if (r.ok && r.audio && (await playAudio(r.audio, r.mime))) return { voice: true, text: r.text };
  browserSay(r.text || fallback);
  return { voice: false, text: r.text || fallback, reason: r.reason };
}
