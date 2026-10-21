// Hands-free Martina: while Counta is open, the browser's own speech recogniser listens for "Hello Martina". Hearing it,
// Counta stops listening (so the microphone is free) and opens a voice conversation with Martina, passing on whatever the
// person said after her name. When the conversation ends, listening starts again.
//
// The recogniser is the browser's (Chrome and Edge send the audio to Google's speech service; Safari uses Apple's). It
// runs only while Counta is open: a browser cannot listen with the app closed or the phone locked.

type Rec = {
  lang: string; continuous: boolean; interimResults: boolean; maxAlternatives: number;
  onresult: ((e: any) => void) | null; onerror: ((e: any) => void) | null; onend: (() => void) | null; onstart: (() => void) | null;
  start: () => void; stop: () => void; abort: () => void;
};

const Recogniser = (): (new () => Rec) | null => {
  if (typeof window === 'undefined') return null;
  const w = window as any;
  return w.SpeechRecognition || w.webkitSpeechRecognition || null;
};
export const wakeSupported = () => Boolean(Recogniser());

// "Hello Martina", "Hi Martina", "Hey Martina", "OK Martina", "Good morning Martina", and the ways recognisers tend to hear
// her name (Martin, Marina, Martini, Matina). The wake word must come first in what was said.
const NAME = '(martina|martinah|martin|marina|martini|matina|martena|martine)';
const GREET = '(hello|hallo|helo|hi|hey|ok|okay|good morning|good afternoon|good evening)';
const WAKE = new RegExp(`(?:^|\\b)${GREET}[\\s,.!-]*${NAME}\\b[\\s,.!?-]*`, 'i');

// Whether the words carry the wake phrase, and what was said after it ("Hello Martina, record a sale" → "record a sale").
export function parseWake(text: string): { heard: boolean; rest: string } {
  const m = WAKE.exec(String(text || ''));
  if (!m) return { heard: false, rest: '' };
  return { heard: true, rest: String(text).slice(m.index + m[0].length).trim() };
}

// A spoken yes or no to "Shall I go ahead?", in English or Pidgin. A reply holding both ("yes... no, wait") counts as neither.
const YES = /\b(yes|yeah|yea|yep|yup|ya|sure|ok|okay|alright|all right|go ahead|go on|do it|do that|confirm(ed)?|approve(d)?|proceed|save it|record it|issue it|send it|correct|that'?s (right|correct|fine|good)|perfect|please do|abeg do am|do am|oya|na so|e correct|carry go|make you do am)\b/i;
const NO = /\b(no|nope|nah|don'?t|do not|wait|stop|cancel|hold on|hold it|not yet|never ?mind|change|wrong|abeg no|no o|make you no|leave am|forget it)\b/i;
export const saidYes = (t: string) => YES.test(t) && !NO.test(t);
export const saidNo = (t: string) => NO.test(t);

// A short rising chime: Martina heard her name.
export function chime() {
  try {
    const A = (window as any).AudioContext || (window as any).webkitAudioContext;
    if (!A) return;
    const ctx = new A();
    const t = ctx.currentTime;
    for (const [i, f] of [660, 990].entries()) {
      const o = ctx.createOscillator(), g = ctx.createGain();
      o.type = 'sine'; o.frequency.value = f;
      g.gain.setValueAtTime(0.0001, t + i * 0.12); g.gain.exponentialRampToValueAtTime(0.18, t + i * 0.12 + 0.02); g.gain.exponentialRampToValueAtTime(0.0001, t + i * 0.12 + 0.22);
      o.connect(g).connect(ctx.destination); o.start(t + i * 0.12); o.stop(t + i * 0.12 + 0.25);
    }
    window.setTimeout(() => { try { void ctx.close(); } catch { /* gone */ } }, 800);
  } catch { /* no sound is fine */ }
}

// The person's choice for this device. Per device on purpose: a shared till should not start listening because someone
// turned it on at home.
const KEY = 'counta.handsfree';
export function handsFreeChosen(): boolean { try { return localStorage.getItem(KEY) === '1'; } catch { return false; } }
export function chooseHandsFree(on: boolean) { try { if (on) localStorage.setItem(KEY, '1'); else localStorage.removeItem(KEY); } catch { /* private window */ } }

export type WakeState = 'off' | 'listening' | 'paused' | 'blocked' | 'unsupported';

// Listens for the wake phrase until stopped. The recogniser stops by itself after a silence or a minute; it is started
// again each time, with a growing pause after errors so a broken microphone does not spin.
export class WakeListener {
  private rec: Rec | null = null;
  private active = false;
  private failures = 0;
  private restartTimer = 0;
  private waitTimer = 0;
  private pending: { rest: string; at: number } | null = null;
  constructor(private cb: { onWake: (rest: string) => void; onState: (s: WakeState, why?: string) => void }) {}

  start() {
    const R = Recogniser();
    if (!R) { this.cb.onState('unsupported'); return; }
    if (this.active) return;
    this.active = true;
    this.open(R);
  }

  stop(state: WakeState = 'off') {
    this.active = false;
    window.clearTimeout(this.restartTimer); window.clearTimeout(this.waitTimer);
    this.pending = null;
    const r = this.rec; this.rec = null;
    if (r) { r.onend = null; r.onresult = null; r.onerror = null; try { r.abort(); } catch { /* already stopped */ } }
    this.cb.onState(state);
  }

  private open(R: new () => Rec) {
    const r = new R();
    r.lang = (navigator.language || '').toLowerCase().startsWith('en-ng') ? 'en-NG' : 'en-GB';
    r.continuous = true; r.interimResults = true; r.maxAlternatives = 3;
    r.onstart = () => { this.failures = 0; this.cb.onState('listening'); };
    r.onresult = (e: any) => {
      // Each phrase is checked as it forms. Once the wake phrase is heard, Counta waits for the end of the sentence (or a
      // second and a half without new words) so "Hello Martina, record two Indomie for Mama Bisi" arrives whole.
      for (let i = e.resultIndex; i < e.results.length; i++) {
        const res = e.results[i];
        const alts: string[] = Array.from({ length: res.length }, (_, k) => String(res[k]?.transcript || ''));
        const hit = alts.map(parseWake).find((w) => w.heard);
        if (!hit && !this.pending) continue;
        const rest = hit ? hit.rest : this.pending!.rest;
        this.pending = { rest, at: Date.now() };
        window.clearTimeout(this.waitTimer);
        if (res.isFinal) { this.fire(); return; }
        this.waitTimer = window.setTimeout(() => this.fire(), 1500);
      }
    };
    r.onerror = (e: any) => {
      const err = String(e?.error || '');
      if (err === 'not-allowed' || err === 'service-not-allowed') {
        this.stop('blocked');
        this.cb.onState('blocked', 'The microphone is blocked for Counta. Allow it in the browser to use "Hello Martina".');
        return;
      }
      if (err !== 'no-speech' && err !== 'aborted') this.failures++;
    };
    r.onend = () => {
      if (!this.active) return;
      // Started again after a short pause; longer after repeated errors (network down, microphone taken by another app).
      const wait = this.failures ? Math.min(30_000, 1000 * 2 ** Math.min(this.failures, 5)) : 250;
      if (this.failures > 2) this.cb.onState('paused', 'Listening paused: the speech service did not answer. Counta tries again shortly.');
      this.restartTimer = window.setTimeout(() => { if (this.active) this.open(R); }, wait);
    };
    this.rec = r;
    try { r.start(); } catch { this.failures++; r.onend?.(); }
  }

  private fire() {
    const p = this.pending;
    if (!p || !this.active) return;
    this.pending = null;
    // The microphone is handed to the conversation: listening stops here and starts again when it ends.
    this.stop('paused');
    this.cb.onWake(p.rest);
  }
}

// Other screens that record from the microphone (the phone's voice sale) say so, and listening for "Hello Martina" waits.
let micUsers = 0;
const micListeners = new Set<() => void>();
export function micInUse(on: boolean) { micUsers = Math.max(0, micUsers + (on ? 1 : -1)); micListeners.forEach((l) => l()); }
export const micBusyNow = () => micUsers > 0;
export function onMicChange(l: () => void) { micListeners.add(l); return () => { micListeners.delete(l); }; }
