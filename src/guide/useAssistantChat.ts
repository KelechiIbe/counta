// Martina for everyday work, typed or spoken, through the same ElevenLabs conversation as the dock. A typed question opens a
// text conversation and goes straight in; the microphone opens a voice one. If the live line cannot be reached, the screens
// fall back to answering from the stock records on this device.
import { useState } from 'react';
import { useGuideTalk } from './GuideProvider';
import { useWords } from '../lib/wording';

export function useAssistantChat() {
  const g = useGuideTalk();
  const w = useWords();
  const [fallback, setFallback] = useState<string | null>(null);
  const mine = g.agent === 'assistant';
  const lines = mine ? g.lines : [];
  const live = mine && g.status === 'live';
  const connecting = g.status === 'connecting';
  // The setup guide is running in the dock: one conversation at a time.
  const busyElsewhere = !mine && g.status !== 'idle';
  const waiting = live && lines[lines.length - 1]?.role === 'user';
  async function ask(text: string) {
    const v = text.trim();
    if (!v) return;
    if (live) { g.send(v); return; }
    if (g.status !== 'idle') return;
    const ok = await g.start({ agent: 'assistant', text: true, first: v });
    if (!ok) setFallback(v);
  }
  async function talk() {
    if (g.status !== 'idle') return;
    const ok = await g.start({ agent: 'assistant' });
    if (!ok) setFallback('');
  }
  const starters = [
    w.revenue === 'sales' ? 'How were sales this month?' : `How much ${w.revenue} came in this month?`,
    `Which ${w.customers} owe us money?`,
    w.has_stock ? 'What is running low?' : `Draft an invoice for a ${w.customer}`,
    'Where do we stand on VAT and tax?',
  ];
  return { g, lines, live, connecting, busyElsewhere, waiting, ask, talk, end: g.end, error: g.error, voice: live && !g.textOnly,
    fallback, clearFallback: () => setFallback(null), starters };
}
