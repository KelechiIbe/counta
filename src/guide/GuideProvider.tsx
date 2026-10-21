// Martina, the onboarding guide: one conversation for the whole app (voice over WebRTC, or typing), and the tools she
// uses, each carried out here as the signed-in person through the same calls the screens make.
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { edge } from '../lib/api';
import { rpc } from '../lib/supabase';
import { useSession } from '../state/session';
import {
  cacSearch, cacSelect, cacStatusReport, classLabel, guideConsent, guideLanguage, guideMark, kycAnswer, kycManual, kycSubmit, openWallet, readCacDocument, saveVoice,
  webInsights, type Answers, type Category, type GuideState, type Kyc, type Score, type WebInsights,
} from '../lib/onboard';
import { fetchSpeech, playAudio } from '../lib/speech';
import { assistantTools } from './assistantTools';
import { clearPending, currentPending, runPending, voiceActions } from './actions';
import { chime, chooseHandsFree, handsFreeChosen, micBusyNow, onMicChange, WakeListener, wakeSupported, type WakeState } from './handsFree';
import type { Inventory } from '../lib/types';
import { checkNin } from '../pages/onboarding/Identity';

export type Line = { role: 'agent' | 'user'; text: string; at: number };
export type Status = 'idle' | 'connecting' | 'live' | 'ending';
type Conv = {
  endSession: () => Promise<void>; sendUserMessage: (t: string) => void; sendContextualUpdate: (t: string) => void; setMicMuted: (m: boolean) => void;
  getInputVolume: () => number; getOutputVolume: () => number; setVolume?: (o: { volume: number }) => void; getId?: () => string;
};
// Martina has two jobs: the onboarding guide, and the assistant for everything else in Counta.
export type Agent = 'guide' | 'assistant';
export type OnboardScreen = 'welcome' | 'find' | 'found' | 'questions' | 'summary' | 'score' | 'identity' | 'document' | 'done';
type Wallet = { account_number: string | null; bank_name: string | null; account_name: string | null; status: string };

interface GuideCtx {
  status: Status; textOnly: boolean; speaking: boolean; muted: boolean; lines: Line[]; error: string | null; minimized: boolean; agent: Agent;
  start: (o?: { text?: boolean; agent?: Agent; first?: string; handsFree?: boolean }) => Promise<boolean>; end: () => Promise<void>; send: (t: string) => void; toggleMute: () => void; setMinimized: (v: boolean) => void;
  // What the person does on screen, told to Martina so she keeps up.
  notify: (t: string) => void;
  volumes: () => { input: number; output: number };
  screen: OnboardScreen | null; setScreen: (s: OnboardScreen | null) => void;
  filled: Record<string, number>; markFilled: (keys: string[]) => void;
  uploadAsk: { kind: string; at: number } | null;
  voicePicker: boolean; setVoicePicker: (v: boolean) => void;
  wallet: Wallet | null; setWallet: (w: Wallet | null) => void;
  confetti: number; celebrate: () => void;
  insights: () => Promise<WebInsights | null>;
  // "Hello Martina": the choice for this device, whether the browser can do it, and what the listener is doing.
  handsFree: boolean; setHandsFree: (on: boolean) => void; wakeSupported: boolean; wakeState: WakeState; wakeNote: string | null;
  // The action Martina is holding for approval, approved or cancelled with a tap.
  approvePending: () => Promise<void>; cancelPending: () => void;
}
const Ctx = createContext<GuideCtx>(null as any);
export const useGuideTalk = () => useContext(Ctx);

const ONBOARD: Record<string, OnboardScreen> = { questions: 'questions', summary: 'summary', score: 'score', identity: 'identity', document: 'document' };
const ROUTES: Record<string, string> = { home: '/home', payments: '/payments', sell: '/sell/till', banking: '/accounting/banking', statements: '/accounting/banking',
  products: '/inventory/items', team: '/inventory/locations' };
// Eleven digits in a row (spaces or dashes between groups allowed) are treated as an NIN.
const looksLikeNin = (t: string) => /(^|\D)\d{11}(\D|$)/.test(String(t || '').replace(/(\d)[\s-]+(?=\d)/g, '$1'));
const short = (o: unknown) => JSON.stringify(o, (_k, v) => (v === null || v === '' || (Array.isArray(v) && !v.length) ? undefined : v));

// What CAC holds, as Martina reads it out: names and facts, never anyone's personal details.
function businessBrief(k: Kyc | null | undefined) {
  const b = k?.business;
  if (!b) return null;
  return {
    name: b.name, rc_number: b.rc_number, type: classLabel(b.classification) + (b.company_type ? ` (${b.company_type.toLowerCase()})` : ''), registered_on: b.registered_on,
    active: b.active, address: b.address, state: b.state, objectives: b.objectives?.slice(0, 600), nature: b.nature, share_capital_naira: b.share_capital,
    issued_shares: b.issued_shares, directors: b.directors?.map((d) => d.name + (d.chairman ? ' (chairman)' : '')),
    shareholders: b.shareholders?.map((s) => s.name + (s.shares ? ` (${s.shares} shares)` : '')), secretary: b.secretary,
    tax_id_on_record: Boolean(b.tax_id), tax_office: b.tin?.tax_office,
  };
}
const scoreBrief = (s: Score) => ({ score: s.score, out_of: s.total, doing_well: s.items.filter((i) => i.ok).map((i) => i.label),
  to_do: s.items.filter((i) => !i.ok).map((i) => ({ what: i.label, how: i.text })) });

export function GuideProvider({ children }: { children: ReactNode }) {
  const { session, orgId, setOrgId, refreshMemberships } = useSession();
  const nav = useNavigate();
  const loc = useLocation();
  const qc = useQueryClient();
  const [status, setStatus] = useState<Status>('idle');
  const [textOnly, setTextOnly] = useState(false);
  const [speaking, setSpeaking] = useState(false);
  const [muted, setMuted] = useState(false);
  const [lines, setLines] = useState<Line[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [minimized, setMinimized] = useState(false);
  const [screen, setScreen] = useState<OnboardScreen | null>(null);
  const [filled, setFilled] = useState<Record<string, number>>({});
  const [uploadAsk, setUploadAsk] = useState<{ kind: string; at: number } | null>(null);
  const [voicePicker, setVoicePicker] = useState(false);
  const [wallet, setWallet] = useState<Wallet | null>(null);
  const [confetti, setConfetti] = useState(0);
  const [agent, setAgent] = useState<Agent>('guide');
  const agentRef = useRef<Agent>('guide');
  const conv = useRef<Conv | null>(null);
  // An NIN said or typed to Martina: the conversation is deleted from ElevenLabs once it ends.
  const saidNin = useRef(false);
  // The ElevenLabs id of the conversation going on, kept after it ends so it can be deleted.
  const convId = useRef<string | null>(null);
  const insightsP = useRef<Promise<WebInsights | null> | null>(null);
  // The tools read the latest values through refs, since the conversation keeps the functions it started with.
  const live = useRef({ orgId, nav, path: loc.pathname });
  live.current = { orgId, nav, path: loc.pathname };

  // Everything said in this conversation, readable by the tools at once (the state updates a render later).
  const said = useRef<Line[]>([]);
  const add = useCallback((role: Line['role'], text: string) => {
    if (!text?.trim()) return;
    const line = { role, text: text.trim(), at: Date.now() };
    said.current = [...said.current.slice(-60), line];
    setLines((l) => [...l.slice(-30), line]);
  }, []);
  const markFilled = useCallback((keys: string[]) => {
    const t = Date.now();
    setFilled((f) => ({ ...f, ...Object.fromEntries(keys.map((k) => [k, t])) }));
  }, []);
  const celebrate = useCallback(() => setConfetti((c) => c + 1), []);
  const refresh = useCallback(() => {
    void qc.invalidateQueries({ queryKey: ['kyc'] });
    void qc.invalidateQueries({ queryKey: ['guide'] });
    void qc.invalidateQueries({ queryKey: ['compliance'] });
  }, [qc]);

  // The web search runs in the background from the moment the business is chosen.
  const insights = useCallback(() => {
    if (!insightsP.current) insightsP.current = webInsights().then((r) => { refresh(); return r.insights; }).catch(() => null);
    return insightsP.current;
  }, [refresh]);

  const goOnboard = useCallback((s: OnboardScreen) => {
    setScreen(s);
    if (!live.current.path.startsWith('/onboarding')) live.current.nav('/onboarding');
  }, []);

  const tools = useMemo<Record<string, (p: any) => Promise<string>>>(() => {
    const safe = (fn: (p: any) => Promise<unknown>) => async (p: any) => {
      try { const r = await fn(p || {}); return typeof r === 'string' ? r : short(r); } catch (e) { return short({ error: (e as Error).message }); }
    };
    const org = () => { if (!live.current.orgId) throw new Error('The business is not set up yet. Finish the profile first.'); return live.current.orgId; };
    return {
      get_progress: safe(async () => {
        const g = await rpc<GuideState>('guide_state', live.current.orgId ? { p_org: live.current.orgId } : {});
        const cats = qc.getQueryData<Category[]>(['business-categories']) || [];
        return { first_name: g.first_name, business: g.org?.name, language: g.language, next_step: g.next, done: `${g.done} of ${g.total}`,
          steps: g.steps.map((s) => `${s.id}: ${s.done ? 'done' : s.skipped ? 'skipped' : s.optional ? 'to do (optional)' : 'to do'}`),
          call_consent: g.call.consent, categories: cats.map((c) => `${c.id} = ${c.label} (${c.kind})`) };
      }),
      find_business: safe(async ({ query }) => {
        const k = await cacSearch(String(query || ''));
        refresh(); goOnboard('find');
        const c = k.search.candidates;
        if (!c.length) return { matches: [], note: 'Nothing on CAC by that name. Try another spelling or the RC number, or call not_registered.' };
        return { matches: c.map((x) => ({ id: x.id, name: x.name, rc: x.rc_number, type: classLabel(x.classification), area: [x.city, x.state].filter(Boolean).join(', '),
          active: x.active !== false })) };
      }),
      choose_business: safe(async ({ cac_id }) => {
        const r = await cacSelect(cac_id);
        insightsP.current = null; void insights();
        refresh(); goOnboard('found'); markFilled(['business']);
        return { cac: businessBrief(r.kyc), tax_note: r.tax_note };
      }),
      web_insights: safe(async () => {
        const w = await insights();
        if (!w) return { found_online: false, note: 'The web search did not finish. Carry on without it.' };
        return { found_online: w.found_online, summary: w.summary, website: w.website, socials: w.socials.map((s) => s.platform), sells: w.sells,
          suggested_offering: w.offering_guess, suggested_category: w.category_guess, observations: w.observations };
      }),
      not_registered: safe(async (p) => {
        const k = await kycManual({ name: p.name, kind: p.kind || 'unregistered', address: p.address, state: p.state });
        refresh(); goOnboard('questions');
        return { saved: businessBrief(k)?.name, still_missing: k.missing.length ? k.missing : 'nothing, all answered' };
      }),
      save_answers: safe(async (p) => {
        const a: Partial<Answers> & Record<string, unknown> = {};
        for (const k of ['offering', 'category', 'revenue_band', 'receive_methods', 'pay_methods', 'reasons', 'reason_note', 'examples', 'charges_vat']) if (p[k] != null && p[k] !== '') a[k] = p[k];
        const filing: Record<string, string> = {};
        for (const t of ['vat', 'wht', 'cit']) if (p['filing_' + t]) filing[t] = p['filing_' + t];
        if (Object.keys(filing).length) a.filing = filing as Answers['filing'];
        if (!Object.keys(a).length) return { note: 'Nothing to save.' };
        const k = await kycAnswer(a);
        markFilled([...Object.keys(a).filter((x) => x !== 'filing'), ...Object.keys(filing).map((t) => 'filing_' + t)]);
        refresh(); if (live.current.path.startsWith('/onboarding')) setScreen((s) => (s === 'summary' ? s : 'questions')); else goOnboard('questions');
        return { saved: Object.keys(a), still_missing: k.missing.length ? k.missing : 'nothing, all answered' };
      }),
      show_summary: safe(async () => {
        const k = await rpc<Kyc>('kyc_draft', {});
        goOnboard('summary');
        return { business: businessBrief(k), category: k.category?.label, answers: k.answers, still_missing: k.missing.length ? k.missing : 'nothing, all answered' };
      }),
      submit_profile: safe(async ({ trading_name }) => {
        const phone = (session?.user?.user_metadata as any)?.phone;
        const r = await kycSubmit({ ...(trading_name ? { trading_name } : {}), ...(phone ? { phone } : {}) });
        await refreshMemberships(); setOrgId(r.org_id); refresh(); goOnboard('score'); celebrate();
        void guideMark('score_seen').catch(() => null);
        return { business: r.name, ...scoreBrief(r.compliance) };
      }),
      get_score: safe(async () => scoreBrief(await rpc<Score>('compliance_score', { p_org: org() }))),
      fetch_cac_report: safe(async () => {
        const o = org();
        goOnboard('document');
        await cacStatusReport(o); refresh();
        const r = await readCacDocument(o); refresh();
        return { fetched: true, checks: r.checks.map((c) => `${c.ok ? 'OK' : 'CHECK'}: ${c.note}`), share_capital: r.extract?.share_capital, report_date: r.extract?.document_date };
      }),
      open_upload: safe(async ({ kind }) => {
        setUploadAsk({ kind: kind || 'status_report', at: Date.now() }); goOnboard('document');
        return 'The upload box is open on screen. Ask them to tap "Choose file".';
      }),
      show_screen: safe(async ({ screen: s }) => {
        if (s === 'voice') { setVoicePicker(true); return 'The voice choices are on screen.'; }
        if (ONBOARD[s]) { goOnboard(ONBOARD[s]); return `Showing ${s}.`; }
        if (ROUTES[s]) { if (!live.current.orgId) return { error: 'The business is not set up yet.' }; live.current.nav(ROUTES[s]); return `Showing ${s}.`; }
        return { error: 'Unknown screen.' };
      }),
      get_account_number: safe(async () => {
        const w = await openWallet(org());
        setWallet(w); refresh(); if (w.status === 'active') celebrate();
        return w.status === 'active' ? { bank: w.bank_name, account_number: w.account_number, account_name: w.account_name }
          : { note: 'The bank is still opening the account. It shows on the home screen as soon as it is ready.' };
      }),
      offer_voices: safe(async () => {
        setVoicePicker(true);
        const r = await edge<{ voices: { voice_id: string; name: string; gender: string }[] }>('voice', { action: 'voices' });
        return { voices: (r.voices || []).map((v) => ({ id: v.voice_id, name: v.name, gender: v.gender })), note: 'They can tap each voice to hear it.' };
      }),
      set_voice: safe(async ({ voice_id, lang }) => {
        const o = org();
        await saveVoice(o, { voice_id, ...(lang ? { voice_lang: lang } : {}) });
        await guideMark('voice_chosen'); refresh(); void qc.invalidateQueries({ queryKey: ['voice-settings'] });
        return 'Saved.';
      }),
      play_payment_demo: safe(async () => {
        const o = org();
        const r = await fetchSpeech('payment_demo', { org_id: o }, 8000);
        // Martina goes quiet while the business's own voice says it.
        conv.current?.setVolume?.({ volume: 0 });
        celebrate();
        if (r.ok && r.audio) await playAudio(r.audio, r.mime);
        conv.current?.setVolume?.({ volume: 1 });
        void guideMark('payment_demo').catch(() => null);
        return 'Played.';
      }),
      mark_step: safe(async ({ mark }) => { await guideMark(mark); refresh(); return 'Noted.'; }),
      set_language: safe(async ({ lang }) => { await guideLanguage(lang === 'pcm' ? 'pcm' : 'en'); refresh(); return 'Switched.'; }),
      call_consent: safe(async ({ consent, phone }) => {
        const g = await guideConsent(Boolean(consent), phone || (session?.user?.user_metadata as any)?.phone);
        refresh();
        return g.call.consent ? { saved: true, number: g.call.phone } : { saved: true, consent: false };
      }),
      celebrate: safe(async () => { celebrate(); return 'Done.'; }),
      verify_nin: safe(async ({ nin }) => {
        const o = org();
        saidNin.current = true;
        if (live.current.path.startsWith('/onboarding')) goOnboard('identity'); else live.current.nav('/settings#identity');
        const r = await checkNin(o, String(nin || ''), conv.current?.getId?.() || null);
        refresh(); void qc.invalidateQueries({ queryKey: ['identity'] }); void qc.invalidateQueries({ queryKey: ['inv'] });
        if (r.result.verified) celebrate();
        return r.result.verified ? { verified: true, director: r.result.matched, note: 'Payments can now be switched on.' }
          : { verified: false, why: r.result.reason, directors_on_record: r.result.people, next: 'Ask them to add their NIN slip (open_nin_upload), or skip if they are not a director.' };
      }),
      open_nin_upload: safe(async () => {
        setUploadAsk({ kind: 'nin_slip', at: Date.now() });
        if (live.current.path.startsWith('/onboarding')) goOnboard('identity'); else live.current.nav('/settings#identity');
        return 'The NIN slip upload is on screen.';
      }),
      ...Object.fromEntries(Object.entries(assistantTools({ org, nav: (to: string) => live.current.nav(to), qc, celebrate })).map(([k, fn]) => [k, safe(fn)])),
      ...Object.fromEntries(Object.entries(voiceActions({
        org, nav: (to: string) => live.current.nav(to), qc,
        inv: async () => qc.getQueryData<Inventory>(['inv', org()]) || await rpc<Inventory>('get_inventory', { p_org: org() }),
        userSince: (at: number) => said.current.filter((l) => l.role === 'user' && l.at > at).map((l) => l.text),
      })).map(([k, fn]) => [k, safe(fn)])),
      // The person is done ("thanks, that's all"): Martina says goodbye, then the conversation closes and, hands-free,
      // Counta listens for her name again.
      finish: safe(async () => { endSoon.current?.(); return 'Closing after your goodbye.'; }),
    };
  }, [qc, refresh, goOnboard, markFilled, insights, celebrate, refreshMemberships, setOrgId, session]);

  const start = useCallback(async (o: { text?: boolean; agent?: Agent; first?: string; handsFree?: boolean } = {}) => {
    if (conv.current || status === 'connecting') return false;
    const which: Agent = o.agent || 'guide';
    handsFreeTalk.current = Boolean(o.handsFree);
    // Everyday conversations keep what was said on screen when Martina reconnects; the setup guide starts afresh.
    const keep = which === 'assistant' && agentRef.current === 'assistant';
    agentRef.current = which;
    setError(null); setStatus('connecting'); setMinimized(false); setAgent(which); if (!keep) setLines([]);
    let text = Boolean(o.text);
    try {
      if (!text) {
        try { (await navigator.mediaDevices.getUserMedia({ audio: true })).getTracks().forEach((t) => t.stop()); }
        catch { text = true; setError('The microphone is blocked, so we can type instead. Allow the microphone for this site to talk.'); }
      }
      const page = live.current.path.replace(/^\/m(\/|$)/, '/phone/').split('/').filter(Boolean).slice(0, 2).join(' ').replace('accounting tax', 'tax') || 'home';
      const t = which === 'assistant'
        ? await edge<any>('voice', { action: 'assistant_token', text, org_id: live.current.orgId, page,
          ...(o.handsFree ? { hands_free: true, has_request: Boolean(String(o.first || '').trim()) } : {}) })
        : await edge<any>('voice', { action: 'guide_token', text, ...(live.current.orgId ? { org_id: live.current.orgId } : {}) });
      if (!t.ok) throw new Error(t.error || 'Martina is not available just now.');
      const { Conversation } = await import('@elevenlabs/client');
      setTextOnly(text);
      const base = {
        dynamicVariables: t.dynamic_variables, overrides: t.overrides, clientTools: tools,
        onConnect: () => { setStatus('live'); if (which === 'guide') void guideMark('intro_heard').catch(() => null); },
        onDisconnect: () => {
          conv.current = null; setStatus('idle'); setSpeaking(false); clearPending(); said.current = [];
          // ElevenLabs finishes the conversation first; anything it still holds is retried every quarter of an hour.
          if (saidNin.current) {
            saidNin.current = false;
            const id = convId.current;
            window.setTimeout(() => { void edge('voice', { action: 'forget', ...(id ? { conversation_id: id } : {}) }).catch(() => null); }, 8000);
          }
        },
        onError: (m: string) => setError(typeof m === 'string' ? m : 'The conversation dropped.'),
        onMessage: (m: { message: string; source?: string; role?: string }) => {
          const who = (m.role || m.source) === 'user' ? 'user' : 'agent';
          if (who === 'user' && looksLikeNin(m.message)) saidNin.current = true;
          lastHeard.current = Date.now();
          add(who, m.message);
        },
        onModeChange: (m: { mode: string }) => { speakingRef.current = m.mode === 'speaking'; lastHeard.current = Date.now(); setSpeaking(m.mode === 'speaking'); },
      };
      const c = text
        ? await Conversation.startSession({ ...base, signedUrl: t.signed_url, textOnly: true, connectionType: 'websocket' } as any)
        : await Conversation.startSession({ ...base, conversationToken: t.token, connectionType: 'webrtc' } as any);
      conv.current = c as unknown as Conv;
      convId.current = (() => { try { return (c as any).getId?.() || t.conversation_id || null; } catch { return t.conversation_id || null; } })();
      if (text) setStatus('live');
      const first = String(o.first || '').trim();
      if (first) { if (looksLikeNin(first)) saidNin.current = true; add('user', first); conv.current.sendUserMessage(first); }
      return true;
    } catch (e) {
      conv.current = null; setStatus('idle'); handsFreeTalk.current = false;
      setError((e as Error).message || 'Could not reach Martina.');
      return false;
    }
  }, [status, tools, add]);

  const end = useCallback(async () => {
    const c = conv.current;
    if (!c) return;
    setStatus('ending');
    try { await c.endSession(); } catch { /* already gone */ }
    conv.current = null; setStatus('idle'); setSpeaking(false); clearPending(); said.current = [];
  }, []);
  const send = useCallback((t: string) => {
    const v = t.trim(); if (!v || !conv.current) return;
    if (looksLikeNin(v)) saidNin.current = true;
    add('user', v); conv.current.sendUserMessage(v);
  }, [add]);
  const notify = useCallback((t: string) => { try { conv.current?.sendContextualUpdate(t); } catch { /* not live */ } }, []);
  const toggleMute = useCallback(() => { setMuted((m) => { conv.current?.setMicMuted(!m); return !m; }); }, []);
  const volumes = useCallback(() => {
    try { return { input: conv.current?.getInputVolume() ?? 0, output: conv.current?.getOutputVolume() ?? 0 }; } catch { return { input: 0, output: 0 }; }
  }, []);

  // ---------------------------------------------------------------- hands-free
  const [handsFree, setHandsFreeState] = useState(() => handsFreeChosen());
  const [wakeState, setWakeState] = useState<WakeState>('off');
  const [wakeNote, setWakeNote] = useState<string | null>(null);
  const [micBusy, setMicBusy] = useState(micBusyNow());
  const [visible, setVisible] = useState(() => typeof document === 'undefined' || document.visibilityState !== 'hidden');
  const handsFreeTalk = useRef(false);
  const speakingRef = useRef(false);
  const lastHeard = useRef(0);
  const endSoon = useRef<(() => void) | null>(null);
  const listener = useRef<WakeListener | null>(null);
  const startRef = useRef(start);
  startRef.current = start;
  const setHandsFree = useCallback((on: boolean) => { chooseHandsFree(on); setHandsFreeState(on); setWakeNote(null); }, []);
  useEffect(() => onMicChange(() => setMicBusy(micBusyNow())), []);
  useEffect(() => {
    const v = () => setVisible(document.visibilityState !== 'hidden');
    document.addEventListener('visibilitychange', v);
    return () => document.removeEventListener('visibilitychange', v);
  }, []);
  // Listening runs while the choice is on, someone is signed in to a business, Counta is on screen, no conversation is going
  // and no other screen is recording.
  const listen = handsFree && !!session && !!orgId && status === 'idle' && visible && !micBusy && wakeSupported();
  useEffect(() => {
    if (!listen) { listener.current?.stop(handsFree ? 'paused' : 'off'); return; }
    const l = new WakeListener({
      onWake: (rest) => {
        chime();
        setMinimized(false);
        void startRef.current({ agent: 'assistant', handsFree: true, ...(rest ? { first: rest } : {}) });
      },
      onState: (st, why) => {
        setWakeState(st);
        if (why) setWakeNote(why); else if (st === 'listening') setWakeNote(null);
        if (st === 'blocked') { chooseHandsFree(false); setHandsFreeState(false); }
      },
    });
    listener.current = l;
    l.start();
    return () => { l.stop(); if (listener.current === l) listener.current = null; };
  }, [listen, handsFree]);
  useEffect(() => { if (!handsFree) setWakeState(wakeSupported() ? 'off' : 'unsupported'); }, [handsFree]);

  // A hands-free conversation closes itself after twenty seconds of quiet (a minute while an action waits for a yes), and after
  // Martina's goodbye when the person is done.
  useEffect(() => {
    endSoon.current = () => {
      // Her goodbye may still be on its way when she calls finish: wait for it to start and end (or a few quiet seconds), at most
      // twelve seconds, so it is never cut off.
      const t0 = Date.now();
      let spoke = speakingRef.current, quietSince = 0;
      const tick = () => {
        if (!conv.current) return;
        const now = Date.now();
        if (speakingRef.current) { spoke = true; quietSince = 0; } else if (!quietSince) quietSince = now;
        if (now - t0 > 12_000 || (spoke && quietSince && now - quietSince > 700) || (!spoke && now - t0 > 3000)) { void end(); return; }
        window.setTimeout(tick, 250);
      };
      window.setTimeout(tick, 250);
    };
  }, [end]);
  useEffect(() => {
    if (status !== 'live' || !handsFreeTalk.current) return;
    lastHeard.current = Date.now();
    const t = window.setInterval(() => {
      const quiet = Date.now() - lastHeard.current;
      if (!speakingRef.current && quiet > (currentPending() ? 60_000 : 20_000)) void end();
    }, 2000);
    return () => window.clearInterval(t);
  }, [status, end]);
  useEffect(() => { if (status === 'idle') handsFreeTalk.current = false; }, [status]);

  // Approve or Cancel tapped on the card: done here, and Martina is told so she can say it.
  const approvePending = useCallback(async () => {
    const p = currentPending();
    if (!p) return;
    const r = await runPending(p.id);
    const msg = 'error' in r ? `The person tapped Approve, but it failed: ${r.error}` : `The person tapped Approve on screen. Done: ${r.summary}`;
    add('agent', 'error' in r ? r.error : r.summary);
    try { conv.current?.sendContextualUpdate(msg); } catch { /* not live */ }
  }, [add]);
  const cancelPending = useCallback(() => {
    if (!currentPending()) return;
    clearPending();
    try { conv.current?.sendContextualUpdate('The person tapped Cancel on screen. Nothing was done.'); } catch { /* not live */ }
  }, []);

  // Signing out ends the conversation.
  useEffect(() => { if (!session && conv.current) void end(); }, [session, end]);
  useEffect(() => () => { void conv.current?.endSession(); }, []);

  // Test builds can drive the tools the way the agent does (VITE_GUIDE_TEST=1), without ElevenLabs.
  useEffect(() => {
    if (import.meta.env.VITE_GUIDE_TEST !== '1') return;
    (window as any).__countaGuide = { tool: (name: string, p: unknown) => tools[name]?.(p), lines: () => lines,
      // What the person says, as the conversation would hear it.
      say: (t: string) => add('user', t) };
  }, [tools, lines, add]);

  const value = useMemo<GuideCtx>(() => ({
    status, textOnly, speaking, muted, lines, error, minimized, agent, start, end, send, toggleMute, setMinimized, notify, volumes,
    screen, setScreen, filled, markFilled, uploadAsk, voicePicker, setVoicePicker, wallet, setWallet, confetti, celebrate, insights,
    handsFree, setHandsFree, wakeSupported: wakeSupported(), wakeState, wakeNote, approvePending, cancelPending,
  }), [status, textOnly, speaking, muted, lines, error, minimized, agent, start, end, send, toggleMute, notify, volumes, screen, filled, markFilled, uploadAsk,
    voicePicker, wallet, confetti, celebrate, insights, handsFree, setHandsFree, wakeState, wakeNote, approvePending, cancelPending]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}
