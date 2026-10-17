// A small Gemini client with structured JSON answers and model fallback (the same behaviour as the ai function).
const FALLBACK_MODELS = ['gemini-3.6-flash', 'gemini-3.5-flash', 'gemini-flash-latest'];
const BASE = Deno.env.get('GEMINI_BASE_URL') || 'https://generativelanguage.googleapis.com/v1beta';
const resting = new Map<string, number>();

export const S = {
  str: { type: 'STRING' }, num: { type: 'NUMBER' }, int: { type: 'INTEGER' }, bool: { type: 'BOOLEAN' },
  nstr: { type: 'STRING', nullable: true }, nnum: { type: 'NUMBER', nullable: true },
};

export async function gemini(cfg: { key: string; model: string }, system: string, text: string, schema: unknown, temperature = 0.1): Promise<{ data: any; model: string }> {
  let lastErr = '';
  const all = [cfg.model, ...FALLBACK_MODELS.filter((m) => m !== cfg.model)];
  const ready = all.filter((m) => (resting.get(m) || 0) < Date.now());
  for (const model of ready.length ? ready : all) {
    let res: Response;
    try {
      res = await fetch(`${BASE}/models/${model}:generateContent`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-goog-api-key': cfg.key },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: system }] },
          contents: [{ role: 'user', parts: [{ text }] }],
          generationConfig: { responseMimeType: 'application/json', responseSchema: schema, temperature },
        }),
        signal: AbortSignal.timeout(55_000),
      });
    } catch (e) {
      lastErr = `${model} did not answer (${(e as Error).name})`; resting.set(model, Date.now() + 120_000); continue;
    }
    if (res.status === 404 || (res.status === 400 && (await res.clone().text()).includes('not found'))) { lastErr = `${model} unavailable`; resting.set(model, Date.now() + 3600_000); continue; }
    if (res.status === 429 || res.status >= 500) {
      const why = await res.text();
      lastErr = res.status === 429 && /quota|exhaust/i.test(why) ? 'The Gemini key has used up its quota.' : `${model} busy (${res.status})`;
      resting.set(model, Date.now() + 120_000); continue;
    }
    if (!res.ok) throw new Error(`Gemini ${res.status}: ${(await res.text()).slice(0, 300)}`);
    const body = await res.json();
    const out = body?.candidates?.[0]?.content?.parts?.map((p: any) => p.text || '').join('') || '';
    if (!out) throw new Error('Gemini returned no content' + (body?.promptFeedback?.blockReason ? ` (${body.promptFeedback.blockReason})` : ''));
    return { data: JSON.parse(out), model };
  }
  throw new Error(lastErr || 'No Gemini model available');
}
