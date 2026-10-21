// A small Gemini client with structured JSON answers and model fallback (the same behaviour as the ai function), on
// Vertex AI with ADC or the Gemini API with a key (google.ts).
import { accessProblem, CredentialError, fallbackModels, type GeminiConfig, generateContent, quotaMessage } from './google.ts';
const resting = new Map<string, number>();

export const S = {
  str: { type: 'STRING' }, num: { type: 'NUMBER' }, int: { type: 'INTEGER' }, bool: { type: 'BOOLEAN' },
  nstr: { type: 'STRING', nullable: true }, nnum: { type: 'NUMBER', nullable: true },
};

export async function gemini(cfg: { g: GeminiConfig; model: string }, system: string, text: string, schema: unknown, temperature = 0.1): Promise<{ data: any; model: string; usage: { in: number; out: number } }> {
  let lastErr = '';
  const all = [cfg.model, ...fallbackModels(cfg.g).filter((m) => m !== cfg.model)];
  const ready = all.filter((m) => (resting.get(m) || 0) < Date.now());
  for (const model of ready.length ? ready : all) {
    let res: Response;
    try {
      res = await generateContent(cfg.g, model, {
        systemInstruction: { parts: [{ text: system }] },
        contents: [{ role: 'user', parts: [{ text }] }],
        // Gemini 3 and later loop or lose accuracy below their default temperature, so it is only set for older models.
        generationConfig: { responseMimeType: 'application/json', responseSchema: schema, ...(/^gemini-[12]\./.test(model) ? { temperature } : {}) },
      }, 55_000);
    } catch (e) {
      if (e instanceof CredentialError) throw e;
      lastErr = `${model} did not answer (${(e as Error).name})`; resting.set(model, Date.now() + 120_000); continue;
    }
    const refused = accessProblem(cfg.g, res.status, await res.clone().text());
    if (refused) throw new CredentialError(refused);
    if (res.status === 404 || (res.status === 400 && (await res.clone().text()).includes('not found'))) { lastErr = `${model} unavailable`; resting.set(model, Date.now() + 3600_000); continue; }
    if (res.status === 429 || res.status >= 500) {
      const why = await res.text();
      lastErr = res.status === 429 && /quota|exhaust/i.test(why) ? quotaMessage(cfg.g) : `${model} busy (${res.status})`;
      resting.set(model, Date.now() + 120_000); continue;
    }
    if (!res.ok) throw new Error(`Gemini ${res.status}: ${(await res.text()).slice(0, 300)}`);
    const body = await res.json();
    const out = body?.candidates?.[0]?.content?.parts?.map((p: any) => p.text || '').join('') || '';
    if (!out) throw new Error('Gemini returned no content' + (body?.promptFeedback?.blockReason ? ` (${body.promptFeedback.blockReason})` : ''));
    const u = body?.usageMetadata || {};
    return { data: JSON.parse(out), model, usage: { in: Number(u.promptTokenCount) || 0, out: (Number(u.candidatesTokenCount) || 0) + (Number(u.thoughtsTokenCount) || 0) } };
  }
  throw new Error(lastErr || 'No Gemini model available');
}
