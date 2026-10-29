// Counta AI: Gemini-backed invoice and bank statement reading, Martina answers and voice capture.
// Gemini runs on Vertex AI, signed in with Application Default Credentials: the Edge Function secret
// GOOGLE_APPLICATION_CREDENTIALS_JSON, with GOOGLE_CLOUD_PROJECT and GOOGLE_CLOUD_LOCATION (see google.ts). Without it, a
// Gemini API key (GEMINI_API_KEY, Edge Function secret or Vault) is used. GEMINI_MODEL is optional (defaults to gemini-3.8-flash).
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { encodeBase64 } from 'jsr:@std/encoding@1/base64';
import { cleanVat, numens, VAT_SCHEMA, VAT_SYSTEM, type VatAnswer, type VatItem, vatPrompt } from './vat.ts';
import { catalogueText, CIT_MAP_SCHEMA, CIT_MAP_SYSTEM, cleanCitLines, type TbRow, tbText, type TemplateLine } from './cit.ts';
import { CAC_DOC_SCHEMA, CAC_DOC_SYSTEM, cacDocChecks, type Category, cleanCacDoc, cleanInsight, cleanNinSlip, INSIGHT_SYSTEM, insightPrompt, looseJson,
  NIN_SLIP_SCHEMA, NIN_SLIP_SYSTEM } from './kyc.ts';
import { cleanProduct, PRODUCT_SCHEMA, PRODUCT_SYSTEM, validBarcode } from './product.ts';
import { cleanSupplier, sha256hex, sniff, SUPPLIER_SCHEMA, supplierSystem } from './supplier.ts';
import { accessProblem, CredentialError, fallbackModels, type GeminiConfig, geminiConfig, generateContent, quotaMessage, thinkingConfig } from './google.ts';

let MODEL = Deno.env.get('GEMINI_MODEL') || 'gemini-3.8-flash';
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

// How Gemini is reached, read again once a minute: Vertex AI with ADC, or a Gemini API key. Keys set in the admin portal
// live in Supabase Vault and come first; the Edge Function secrets are the fallback.
let CFG: GeminiConfig = { mode: 'none' };
let cfgAt = 0;
async function vaultFirst(admin: SupabaseClient, name: string, rpc = 'app_secret') {
  const { data } = await admin.rpc(rpc, { p_name: name });
  const v = typeof data === 'string' ? data.trim() : '';
  return v || (Deno.env.get(name) || '').trim();
}
async function loadKeys(admin: SupabaseClient) {
  if (Date.now() - cfgAt < 60_000) return;
  cfgAt = Date.now();
  CFG = await geminiConfig((name) => vaultFirst(admin, name));
  MODEL = (await vaultFirst(admin, 'GEMINI_MODEL')) || 'gemini-3.8-flash';
}
const aiOn = () => CFG.mode !== 'none';
// Switched off by TaxStreem for everyone, or for this business.
async function paused(admin: SupabaseClient, orgId: string | null) {
  const { data } = await admin.rpc('svc_feature', { p_org: orgId, p_feature: 'ai_reading' });
  return data === false;
}
const PAUSED = { ok: false, reason: 'paused', error: 'AI reading is off for this business (paused by TaxStreem, or not in its plan). Type the details in for now.' };
const isUuid = (v: unknown) => typeof v === 'string' && /^[0-9a-f-]{36}$/i.test(v);

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const NL = String.fromCharCode(10);
// What a business sees. TaxStreem's admin portal shows the setup problem itself (status and check).
const notConfigured = () => ({ ok: false, reason: 'not_configured', error: 'AI reading is not switched on yet. TaxStreem is setting it up; type the details in for now.' });

type Part = { text: string } | { inlineData: { mimeType: string; data: string } };

// Models that just failed are skipped for two minutes, and each attempt gives up after 50 seconds (80 for a statement),
// so a busy model costs one slow call rather than every call.
const resting = new Map<string, number>();
// thinking: 'low' keeps simple structured jobs (matching columns, reading stock lines) quick. A model that
// does not accept the setting is retried once without it.
const noThinking = new Set<string>();
// search: true lets Gemini search Google (grounding); the answer then comes as JSON text, since older models do not
// combine a response schema with tools, and the sources come back as grounding.
async function gemini(system: string, parts: Part[], schema: unknown, temperature = 0.1,
  opts: { thinking?: 'low'; timeoutMs?: number; search?: boolean; org?: string | null; kind?: string } = {}): Promise<{ data: any; model: string; grounding?: any }> {
  // A business's plan may limit documents read and questions answered each month: the database says whether this one fits.
  const metered = opts.kind && READ_KINDS.has(opts.kind) ? 'ai_reads' : opts.kind && ASSISTANT_KINDS.has(opts.kind) ? 'assistant' : null;
  if (metered && isUuid(opts.org)) {
    const { data: ent } = await meterDb.rpc('svc_entitle', { p_org: opts.org, p_meter: metered });
    if (ent && ent.ok === false) throw new Error(String(ent.message || 'Your plan has no room for this this month.'));
  }
  let lastErr = '';
  const all = [MODEL, ...fallbackModels(CFG).filter((m) => m !== MODEL)];
  const ready = all.filter((m) => (resting.get(m) || 0) < Date.now());
  for (const model of ready.length ? ready : all) {
    let res: Response | null = null;
    for (const think of opts.thinking && !noThinking.has(model) ? [true, false] : [false]) {
      try {
        res = await generateContent(CFG, model, {
          systemInstruction: { parts: [{ text: system }] },
          contents: [{ role: 'user', parts }],
          generationConfig: {
            // Gemini 3 and later loop or lose accuracy below their default temperature, so it is only set for older models.
            ...(opts.search ? {} : { responseMimeType: 'application/json', responseSchema: schema }), ...(/^gemini-[12]\./.test(model) ? { temperature } : {}),
            ...(think ? { thinkingConfig: thinkingConfig(CFG, model, opts.thinking!) } : {}),
          },
          ...(opts.search ? { tools: [{ googleSearch: {} }] } : {}),
        }, opts.timeoutMs || 50_000);
      } catch (e) {
        if (e instanceof CredentialError) throw e;
        lastErr = `${model} did not answer (${(e as Error).name})`; resting.set(model, Date.now() + 120_000); res = null; break;
      }
      if (think && res.status === 400 && /thinking/i.test(await res.clone().text())) { noThinking.add(model); continue; }
      break;
    }
    if (!res) continue;
    const refused = accessProblem(CFG, res.status, await res.clone().text());
    if (refused) throw new CredentialError(refused);
    if (res.status === 404 || res.status === 400 && (await res.clone().text()).includes('not found')) { lastErr = `${model} unavailable`; resting.set(model, Date.now() + 3600_000); continue; }
    if (res.status === 429 || res.status >= 500) {
      const why = await res.text();
      console.warn('gemini', model, res.status, why.slice(0, 400));
      lastErr = res.status === 429 && /quota|exhaust/i.test(why) ? quotaMessage(CFG) : `${model} busy (${res.status})`;
      resting.set(model, Date.now() + 120_000); continue;
    }
    if (!res.ok) throw new Error(`Gemini ${res.status}: ${(await res.text()).slice(0, 300)}`);
    const body = await res.json();
    const text = body?.candidates?.[0]?.content?.parts?.map((p: any) => p.text || '').join('') || '';
    if (!text) throw new Error('Gemini returned no content' + (body?.promptFeedback?.blockReason ? ` (${body.promptFeedback.blockReason})` : ''));
    meter(opts.org, opts.kind || 'other', model, body, Boolean(opts.search));
    if (opts.search) return { data: looseJson(text), model, grounding: body?.candidates?.[0]?.groundingMetadata || null };
    return { data: JSON.parse(text), model };
  }
  throw new Error(lastErr || 'No Gemini model available');
}

// Every Gemini call is counted for TaxStreem's cost view: the business, what it was for, the model and the tokens.
// Best effort: a call is never held up or failed by the count.
const meterDb = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false } });
// The kinds the plans' AI quotas count (private.ai_read_kinds and private.ai_assistant_kinds in the database).
const READ_KINDS = new Set(['read_invoice', 'read_statement', 'read_purchase_invoice', 'read_cac_document', 'read_nin_slip', 'read_product', 'supplier_invoice', 'extract_rows']);
const ASSISTANT_KINDS = new Set(['ask', 'chat', 'check', 'business_insights']);
function meter(org: string | null | undefined, kind: string, model: string, body: any, grounded = false) {
  const u = body?.usageMetadata || {};
  const tin = Number(u.promptTokenCount) || 0, tout = (Number(u.candidatesTokenCount) || 0) + (Number(u.thoughtsTokenCount) || 0);
  if (!tin && !tout) return;
  // Gemini 3 bills each search the model ran; older models one per grounded prompt.
  const searches = Array.isArray(body?.candidates?.[0]?.groundingMetadata?.webSearchQueries) ? body.candidates[0].groundingMetadata.webSearchQueries.length : (grounded ? 1 : 0);
  meterDb.rpc('svc_usage', { p: { org_id: isUuid(org) ? org : null, service: 'gemini', kind, item: model, qty_in: tin, qty_out: tout, searches } })
    .then(() => {}, () => {});
}
const orgOf = (b: any) => (isUuid(b?.org_id) ? String(b.org_id) : null);

const S = {
  str: { type: 'STRING' }, num: { type: 'NUMBER' }, int: { type: 'INTEGER' }, bool: { type: 'BOOLEAN' },
  nstr: { type: 'STRING', nullable: true }, nnum: { type: 'NUMBER', nullable: true },
};

// ---------------------------------------------------------------- invoices
// A Tax ID as printed ("2622431609295", "TIN: 20000071-0001", "Tax ID 2622 4316 09295") reduced to its digits; anything
// that is not 8 to 13 digits is dropped.
export function invoiceTin(v: unknown): string | null {
  const m = String(v ?? '').match(/\d[\d\s\-./]{6,24}\d/);
  const d = m ? m[0].replace(/[\s\-./]/g, '') : '';
  return /^[0-9]{8,13}$/.test(d) ? d : null;
}

const INVOICE_SCHEMA = {
  type: 'OBJECT',
  properties: {
    vendor_id: S.nstr, vendor_name: S.nstr, vendor_tin: { type: 'STRING', nullable: true, description: 'The seller\'s Tax ID or TIN exactly as printed' },
    invoice_no: S.nstr, invoice_date: { type: 'STRING', nullable: true, description: 'YYYY-MM-DD' },
    vat_charged: S.bool, prices_include_vat: S.bool, currency: S.nstr, invoice_total: S.nnum,
    other_charges: { type: 'ARRAY', items: { type: 'OBJECT', properties: { label: S.str, amount: S.num }, required: ['label', 'amount'] } },
    lines: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          raw_text: S.str, item_id: S.nstr, new_item_name: S.nstr, qty: S.num,
          unit_kind: { type: 'STRING', enum: ['purchase', 'selling'] }, unit_label: S.str, unit_cost: S.num, line_total_read: S.nnum,
          confidence: S.int,
          alt_reading: { type: 'OBJECT', nullable: true, properties: { label: S.str, qty: S.num, unit_kind: { type: 'STRING', enum: ['purchase', 'selling'] } }, required: ['label', 'qty'] },
          bbox: { type: 'ARRAY', nullable: true, items: S.int },
          batch_no: S.nstr, expiry_date: S.nstr,
          new_item: {
            type: 'OBJECT', nullable: true,
            properties: { purchase_unit: S.str, pack_size: S.int, selling_unit: S.str, category: S.str, vat_treatment: { type: 'STRING', enum: ['standard', 'zero', 'exempt'] } },
          },
        },
        required: ['raw_text', 'qty', 'unit_kind', 'unit_cost', 'confidence'],
      },
    },
  },
  required: ['lines', 'vat_charged', 'prices_include_vat'],
};

async function readInvoice(sb: SupabaseClient, admin: SupabaseClient, body: any, userId: string) {
  const { data: r, error } = await sb.from('receipts').select('*').eq('id', body.receipt_id).single();
  if (error || !r) return json({ ok: false, error: 'Receipt not found or not yours.' }, 404);
  const { data: me } = await sb.from('members').select('id').eq('user_id', userId).eq('org_id', r.org_id).maybeSingle();
  const memberId: string | null = me?.id ?? null;
  if (!['reading', 'needs_review'].includes(r.status)) return json({ ok: false, error: 'This receipt is already ' + r.status }, 409);
  const fail = async (msg: string, reason = 'error') => {
    await sb.from('receipts').update({ status: 'needs_review', ai_error: msg }).eq('id', r.id);
    return json({ ok: false, reason, error: msg });
  };
  if (!aiOn()) return fail(notConfigured().error, 'not_configured');
  if (await paused(admin, r.org_id)) return fail(PAUSED.error, 'paused');
  if (!r.document_path) return fail('There is no document attached to read.');

  const { data: blob, error: dErr } = await sb.storage.from('documents').download(r.document_path);
  if (dErr || !blob) return fail('Could not open the uploaded file.');
  const bytes = new Uint8Array(await blob.arrayBuffer());
  if (bytes.length > 18 * 1024 * 1024) return fail('The file is too large to read. Use a photo under 15MB.');
  const mime = r.document_mime || blob.type || (r.document_path.endsWith('.pdf') ? 'application/pdf' : 'image/jpeg');

  const { data: inv, error: iErr } = await sb.rpc('get_inventory', { p_org: r.org_id });
  if (iErr) return fail(iErr.message);
  const items = (inv.items || []).map((i: any) => ({
    id: i.id, name: i.name, purchase_unit: i.purchase_unit, pack_size: i.pack_size, selling_unit: i.selling_unit, barcode: i.barcode,
    category: i.category, last_cost_per_selling_unit: i.last_cost ?? i.wac ?? null,
  }));
  const vendors = (inv.vendors || []).map((v: any) => ({ id: v.id, name: v.name, vat_registered: v.vat_registered }));
  const handwritten = r.source === 'photo_handwritten';
  const system = `You read supplier invoices for a Nigerian retail shop so stock can be received into its books.
${handwritten ? 'This is a HANDWRITTEN market invoice (duplicate booklet). Spelling is loose ("chikin", "Peak milk") and quantities use market shorthand.' : 'This is a TYPED or printed distributor invoice.'}
Rules:
- Return one entry in "lines" for every product line. Put delivery, transport, loading or similar fees in "other_charges", not in lines.
- Match each line to the shop's item master below by meaning, not spelling. Use the item's id only when you are confident it is the same product and size; otherwise item_id = null and give a clean new_item_name plus your best new_item guess.
- qty is the number of units bought. unit_kind = "purchase" when the unit is the item's purchase unit (carton/ctn, bag, bale, crate, pack-of-packs), "selling" when it is the item's selling unit. unit_label is the short unit as written (ctn, bag, bale, pk, tin, btl, doz...).
- Market shorthand: "doz" = 12 selling units; "half bag" / "½ bag" = half the item's pack_size, expressed as selling units (unit_kind "selling"); "1 ctn" = 1 purchase unit.
- unit_cost is the price per ONE unit of unit_kind, in naira, excluding VAT if VAT is shown separately. If only the line total is legible, divide it by qty. line_total_read is the line amount exactly as printed (null if none).
- confidence (0-100) is how sure you are of the WHOLE line: item, qty, unit and cost. Use below 85 when handwriting is ambiguous, digits could be read two ways, the unit is unclear, or qty x unit_cost does not match the printed total. When unsure, give the most likely reading and put the other plausible one in alt_reading with a short human label like "16 packs" or "1 bag (20 packs)".
- bbox: the line's box on the page as [ymin, xmin, ymax, xmax] scaled 0-1000 (images only; null for PDFs).
- batch_no and expiry_date (YYYY-MM-DD) only when printed on the line.
- vendor_tin: the seller's Tax ID (13 digits) or old TIN exactly as printed on the document (labels such as "TIN", "Tax ID", "FIRS TIN", "NRS TIN"); null when the document shows none. Never the buyer's.
- vendor: set vendor_id if the seller matches a known vendor, else vendor_name as printed. vat_charged = true when the invoice charges VAT or shows the seller's VAT registration, Tax ID or old TIN with a VAT line. prices_include_vat = true only when unit prices clearly include VAT.
- Never invent lines or numbers that are not on the document.
ITEM MASTER: ${JSON.stringify(items)}
KNOWN VENDORS: ${JSON.stringify(vendors)}`;

  let out: any; let model = MODEL;
  try {
    const res = await gemini(system, [{ text: 'Read this invoice.' }, { inlineData: { mimeType: mime, data: encodeBase64(bytes) } }], INVOICE_SCHEMA, 0.1, { org: r.org_id, kind: 'read_invoice' });
    out = res.data; model = res.model;
  } catch (e) {
    return fail('Could not read the invoice: ' + (e as Error).message);
  }

  const known = new Map(items.map((i: any) => [i.id, i]));
  // Prices that include VAT lose it at the rate on the invoice's day.
  const { data: vr } = await admin.rpc('current_vat_rate', { p_day: /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(out.invoice_date || '') ? out.invoice_date : null });
  const vatRate = Number(vr) > 0 ? Number(vr) : 0.075;
  const vat = new Map((inv.items || []).map((i: any) => [i.id, i.vat_treatment]));
  const lines = (out.lines || []).filter((l: any) => l && (l.qty || l.unit_cost)).map((l: any, idx: number) => {
    let itemId = l.item_id && known.has(l.item_id) ? l.item_id : null;
    let conf = Math.max(0, Math.min(100, Math.round(Number(l.confidence) || 0)));
    const qty = Math.max(0, Number(l.qty) || 0);
    let cost = Math.max(0, Number(l.unit_cost) || 0);
    const total = l.line_total_read != null ? Number(l.line_total_read) : null;
    if (total && qty && Math.abs(qty * cost - total) / total > 0.01) conf = Math.min(conf, 60);
    if (!itemId && conf > 84) conf = Math.min(conf, 90);
    const vatT = itemId ? vat.get(itemId) : l.new_item?.vat_treatment || 'standard';
    if (out.prices_include_vat && vatT === 'standard') cost = Math.round((cost / (1 + vatRate)) * 100) / 100;
    const it: any = itemId ? known.get(itemId) : null;
    return {
      receipt_id: r.id, org_id: r.org_id, line_no: idx + 1, raw_text: String(l.raw_text || '').slice(0, 300), item_id: itemId,
      new_item: itemId ? null : {
        name: (l.new_item_name || l.raw_text || 'New item').slice(0, 120), purchase_unit: l.new_item?.purchase_unit || 'Carton',
        pack_size: Math.max(1, Number(l.new_item?.pack_size) || 1), selling_unit: l.new_item?.selling_unit || 'piece',
        category: l.new_item?.category || 'General', vat_treatment: l.new_item?.vat_treatment || 'standard',
      },
      qty, unit_kind: l.unit_kind === 'selling' ? 'selling' : 'purchase',
      unit_label: l.unit_label || (it ? (l.unit_kind === 'selling' ? it.selling_unit : it.purchase_unit) : null),
      unit_cost: cost, confidence: conf, alt_reading: l.alt_reading && l.alt_reading.qty ? l.alt_reading : null,
      bbox: Array.isArray(l.bbox) && l.bbox.length === 4 && !mime.includes('pdf') ? l.bbox.map((n: number) => Math.round(n)) : null,
      confirmed: conf >= 85, model_reading: { item_id: itemId, qty, unit_kind: l.unit_kind, unit_cost: cost, raw: l.raw_text },
      batch_no: l.batch_no || null, expiry_date: /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(l.expiry_date || '') ? l.expiry_date : null,
    };
  });

  if (!lines.length) return fail('No product lines were found on that document. Add them by hand below.');
  const { error: lErr } = await sb.from('receipt_lines').insert(lines);
  if (lErr) return fail('Could not save the lines: ' + lErr.message);
  const vendor = out.vendor_id ? vendors.find((v: any) => v.id === out.vendor_id) : null;
  await sb.from('receipts').update({
    status: 'needs_review', ai_model: model, ai_error: null,
    vendor_id: vendor?.id ?? r.vendor_id, vendor_name: vendor?.name ?? out.vendor_name ?? r.vendor_name,
    // The Tax ID printed on the invoice goes with the bill: it fills an empty supplier record and is flagged when it differs.
    vendor_tin: invoiceTin(out.vendor_tin) ?? r.vendor_tin ?? null,
    invoice_no: out.invoice_no || r.invoice_no, invoice_date: /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(out.invoice_date || '') ? out.invoice_date : r.invoice_date,
    vendor_vat_registered: Boolean(out.vat_charged || vendor?.vat_registered), prices_include_vat: Boolean(out.prices_include_vat),
  }).eq('id', r.id);
  await admin.from('ai_logs').insert({ org_id: r.org_id, member_id: memberId, kind: 'read_invoice', model, input: { receipt_id: r.id, mime, source: r.source }, output: out });
  return json({ ok: true, lines: lines.length, doubtful: lines.filter((l: any) => !l.confirmed).length, other_charges: out.other_charges || [], model });
}

// ---------------------------------------------------------------- Martina
const ROUTES = ['/inventory', '/inventory/items', '/inventory/receive', '/inventory/counts', '/inventory/reorder', '/inventory/pricing', '/inventory/insights', '/inventory/locations'];
const MARTINA = `You are Martina, TaxStreem's inventory assistant for Nigerian shop owners and their staff.
Answer from the JSON snapshot of the business only. Never invent items, quantities or naira amounts. If the data does not answer the question, say what is missing.
Write in plain, calm English. Use ₦ with thousands separators. Quote stock as purchase units plus selling units when helpful (e.g. "6 ctn · 72 tins").
Respect the viewer: if can_see_costs is false, never mention costs or margins.
Nothing is ordered or repriced automatically; drafts always wait for the owner's approval.`;

async function ask(body: any) {
  if (!aiOn()) return json(notConfigured());
  const schema = {
    type: 'OBJECT',
    properties: {
      title: { type: 'STRING', description: 'Short headline, under 8 words' },
      detail: { type: 'STRING', description: 'One to three sentences with the specific numbers' },
      cta_label: { type: 'STRING', description: 'Button text, 1-3 words, e.g. Open reorder' },
      cta_route: { type: 'STRING', enum: ROUTES },
      action: { type: 'OBJECT', nullable: true, properties: { type: { type: 'STRING', enum: ['draft_po', 'none'] }, item_id: S.nstr } },
    },
    required: ['title', 'detail', 'cta_label', 'cta_route'],
  };
  try {
    const { data, model } = await gemini(MARTINA + NL + 'Pick cta_route for the page where the owner acts on your answer. Use action draft_po (with the item id) only when they ask to order or reorder a specific item.',
      [{ text: 'SNAPSHOT:' + NL + JSON.stringify(body.context).slice(0, 120000) + NL + NL + 'QUESTION: ' + String(body.question || '').slice(0, 500) }], schema, 0.2, { org: orgOf(body), kind: 'ask' });
    return json({ ok: true, answer: data, model });
  } catch (e) {
    return json({ ok: false, reason: 'error', error: (e as Error).message });
  }
}

async function chat(body: any) {
  if (!aiOn()) return json(notConfigured());
  const schema = {
    type: 'OBJECT',
    properties: {
      reply: { type: 'STRING' },
      quick_replies: { type: 'ARRAY', items: { type: 'STRING' } },
      action: {
        type: 'OBJECT', nullable: true,
        properties: { type: { type: 'STRING', enum: ['offer_po', 'none'] }, item_id: S.nstr, qty_purchase_units: S.nnum, vendor_id: S.nstr },
      },
    },
    required: ['reply'],
  };
  const history = (body.messages || []).slice(-12).map((m: any) => `${m.role === 'user' ? 'OWNER' : 'MARTINA'}: ${String(m.text).slice(0, 600)}`).join(NL);
  try {
    const { data, model } = await gemini(MARTINA + `
You are chatting on a phone, WhatsApp-style. Keep replies to 1-3 short sentences. Offer up to 3 quick_replies the owner might tap next.
When the owner asks about an item running low or asks to reorder, set action.type = "offer_po" with the item id, a sensible qty_purchase_units (use the reorder suggestion when present) and the preferred vendor id if known, and ask them to confirm. Do not claim anything was sent; the app handles approval.`,
      [{ text: 'SNAPSHOT:' + NL + JSON.stringify(body.context).slice(0, 100000) + NL + NL + 'CONVERSATION:' + NL + history }], schema, 0.3, { org: orgOf(body), kind: 'chat' });
    return json({ ok: true, ...data, model });
  } catch (e) {
    return json({ ok: false, reason: 'error', error: (e as Error).message });
  }
}

// ---------------------------------------------------------------- voice
async function voice(body: any) {
  if (!aiOn()) return json(notConfigured());
  if (!body.audio_base64) return json({ ok: false, error: 'No audio received.' }, 400);
  if (body.audio_base64.length > 14_000_000) return json({ ok: false, error: 'That recording is too long. Keep it under a minute.' }, 413);
  const schema = {
    type: 'OBJECT',
    properties: {
      transcript: S.str, language: S.str,
      movement: { type: 'STRING', enum: ['sale', 'receipt', 'unknown'] },
      item_id: S.nstr, qty: S.nnum, unit_kind: { type: 'STRING', enum: ['purchase', 'selling'] }, location_name: S.nstr,
      sales: {
        type: 'ARRAY', description: 'Every sale in the note, one per customer or separate sale, in the order said',
        items: {
          type: 'OBJECT',
          properties: {
            customer_name: { type: 'STRING', nullable: true, description: 'The buyer\'s name only when it is said' },
            payment: { type: 'STRING', enum: ['cash', 'transfer', 'pos', 'card', 'later', 'unknown'] },
            lines: { type: 'ARRAY', items: { type: 'OBJECT', properties: { item_id: S.str, qty: S.num, unit_kind: { type: 'STRING', enum: ['purchase', 'selling'] } },
              required: ['item_id', 'qty', 'unit_kind'] } },
          },
          required: ['payment', 'lines'],
        },
      },
      confidence: S.int, readback: { type: 'STRING', description: 'One plain English sentence confirming what will be recorded, with naira value if known' },
      problem: { type: 'STRING', nullable: true, description: 'Why it cannot be recorded, if so' },
    },
    required: ['transcript', 'movement', 'confidence', 'readback'],
  };
  try {
    const { data, model } = await gemini(`You transcribe short voice notes from shop staff in Nigeria (Nigerian Pidgin, Yoruba, Hausa, Igbo or English) and turn them into stock movements.
"I don sell three cartons of Indomie" means a SALE of 3 purchase units (cartons) of the matching Indomie item. "We collect 5 bag of rice" is a RECEIPT.
Match the item from ITEMS by meaning. qty is a number; unit_kind "purchase" for cartons/bags/bales/crates, "selling" for packs/tins/bottles/pieces.
A note may hold several sales: "Mama Bisi buy two Indomie and one Coke, she pay transfer; Chidi take one carton semo, e go pay later" is two sales.
For a sale, list every sale in sales, each with all its products in lines, the buyer's name in customer_name only when said (never invent one),
and payment: cash, transfer, pos, card, later (on credit, "e go pay", "I go collect am later"), or unknown when the note does not say.
Also fill item_id, qty and unit_kind with the first product of the first sale.
If the location is mentioned, return its name exactly as in LOCATIONS. If anything essential is missing, set movement "unknown" and explain in problem.
ITEMS: ${JSON.stringify(body.items || []).slice(0, 60000)}
LOCATIONS: ${JSON.stringify(body.locations || [])}`,
      [{ text: 'Transcribe and interpret this voice note.' }, { inlineData: { mimeType: body.mime || 'audio/webm', data: body.audio_base64 } }], schema, 0.1, { org: orgOf(body), kind: 'voice' });
    return json({ ok: true, ...data, model });
  } catch (e) {
    return json({ ok: false, reason: 'error', error: (e as Error).message });
  }
}

// ---------------------------------------------------------------- spreadsheet import
// Matches the columns of whatever sheet a business uploads to Counta's item fields. The app sends the
// header row, a few sample rows, the field catalogue for the business's industry and the branch names.
async function mapColumns(body: any) {
  if (!aiOn()) return json(notConfigured());
  const headers: string[] = (body.headers || []).slice(0, 80).map((h: unknown) => String(h ?? '').slice(0, 80));
  if (!headers.length) return json({ ok: false, error: 'No columns to match.' }, 400);
  const samples: string[][] = (body.samples || []).slice(0, 8).map((r: unknown[]) => (r || []).slice(0, 80).map((c) => String(c ?? '').slice(0, 80)));
  const fields = (body.fields || []).slice(0, 120);
  const schema = {
    type: 'OBJECT',
    properties: {
      columns: {
        type: 'ARRAY',
        items: {
          type: 'OBJECT',
          properties: {
            index: S.int,
            field: { type: 'STRING', description: 'A field key from FIELDS, or "note" to keep the value on the item as a note, or "ignore"' },
            location: { type: 'STRING', nullable: true, description: 'For qty / qty_pu columns that belong to one branch: that branch name exactly as in BRANCHES' },
            confidence: S.int,
          },
          required: ['index', 'field', 'confidence'],
        },
      },
      quantities_in: { type: 'STRING', enum: ['selling', 'purchase'], description: 'Are plain quantity columns counted in selling units (pieces, packs) or purchase units (cartons, bags)?' },
      costs_per: { type: 'STRING', enum: ['selling', 'purchase'] },
      prices_per: { type: 'STRING', enum: ['selling', 'purchase'] },
      summary: { type: 'STRING', description: 'One plain sentence on what the sheet holds and anything the user should check' },
    },
    required: ['columns', 'quantities_in', 'costs_per', 'prices_per', 'summary'],
  };
  try {
    const { data, model } = await gemini(`You match spreadsheet columns from Nigerian businesses to an inventory system's fields.
Headers are often abbreviated or informal: "Desc" or "Description" is usually the product name, "Ctn" is carton, "Qty" quantity, "CP" cost price, "SP" selling price, "W/S" wholesale, "Exp" expiry, "S/N" a row number (ignore it), "Pcs" pieces.
Use the sample values, not just the header: a column of 8-14 digit numbers is a barcode; values like "24 x 50cl" or "ctn of 12" are pack sizes; money with commas or ₦ is a price or cost; dates in the future near an item are expiry dates.
Fields ending in _pu are per purchase unit (carton, bag, case). Choose qty_pu, cost_pu or price_pu when the header or values say carton/bag/case, otherwise qty, cost, price.
A column whose header names a branch (from BRANCHES) and holds quantities is stock at that branch: field qty or qty_pu with location set.
Each field may be used once, except qty and qty_pu which may repeat for different branches. Keep columns you cannot place as "note"; use "ignore" only for row numbers, blank or computed total columns.
FIELDS: ${JSON.stringify(fields)}
BRANCHES: ${JSON.stringify(body.locations || [])}
INDUSTRY: ${String(body.industry || 'retail')}`,
      [{ text: 'HEADERS (index: name):\n' + headers.map((h, i) => `${i}: ${h}`).join('\n') + '\n\nSAMPLE ROWS:\n' + samples.map((r) => JSON.stringify(r)).join('\n') }],
      schema, 0.1, { thinking: 'low', org: orgOf(body), kind: 'map_columns' });
    return json({ ok: true, ...data, model });
  } catch (e) {
    return json({ ok: false, reason: 'error', error: (e as Error).message });
  }
}

// For sheets with no usable columns (one free-text description per row, or a pasted list), Martina reads
// each line into item fields. Up to 120 lines per call.
async function extractRows(body: any) {
  if (!aiOn()) return json(notConfigured());
  const lines: { row: number; text: string }[] = (body.lines || []).slice(0, 120).map((l: any) => ({ row: Number(l.row) || 0, text: String(l.text || '').slice(0, 400) }));
  if (!lines.length) return json({ ok: false, error: 'No lines to read.' }, 400);
  const attrKeys: string[] = (body.attribute_keys || []).slice(0, 40).map(String);
  const schema = {
    type: 'OBJECT',
    properties: {
      items: {
        type: 'ARRAY',
        items: {
          type: 'OBJECT',
          properties: {
            row: S.int, name: S.str, brand: S.nstr, category: S.nstr, item_type: S.nstr,
            purchase_unit: S.nstr, pack_size: { type: 'INTEGER', nullable: true }, selling_unit: S.nstr,
            qty: { type: 'NUMBER', nullable: true, description: 'Quantity on hand in SELLING units' },
            cost: { type: 'NUMBER', nullable: true, description: 'Cost per SELLING unit in naira' },
            price: { type: 'NUMBER', nullable: true, description: 'Selling price per SELLING unit in naira' },
            barcode: S.nstr, sku: S.nstr, expiry_date: { type: 'STRING', nullable: true, description: 'YYYY-MM-DD' }, batch_no: S.nstr,
            attributes: { type: 'ARRAY', items: { type: 'OBJECT', properties: { key: S.str, value: S.str }, required: ['key', 'value'] } },
          },
          required: ['row', 'name'],
        },
      },
    },
    required: ['items'],
  };
  try {
    const { data, model } = await gemini(`You turn lines from a Nigerian shop's stock list into inventory items.
Lines look like "Indomie chicken 70g x40 - 12 ctns @ 9,600" (12 cartons of 40 packs, ₦9,600 per carton, so qty 480 packs and cost 240 per pack) or "Dangote sugar 1kg 20 bags".
Always convert quantities, costs and prices to SELLING units using the pack size. Keep the product name clean (brand, product, size) without quantities or prices.
Use item_type only when obvious: raw_material, packaging, consumable, spare_part, chemical, finished_good or merchandise.
attributes may only use these keys: ${JSON.stringify(attrKeys)}. Return one item per input line, with its row number. Skip lines that are headings or totals.
INDUSTRY: ${String(body.industry || 'retail')}`,
      [{ text: lines.map((l) => `${l.row}: ${l.text}`).join('\n') }], schema, 0.1, { thinking: 'low', org: orgOf(body), kind: 'extract_rows' });
    const items = (data.items || []).map((it: any) => ({
      ...it, attributes: Object.fromEntries((it.attributes || []).filter((a: any) => attrKeys.includes(a.key)).map((a: any) => [a.key, a.value])),
    }));
    return json({ ok: true, items, model });
  } catch (e) {
    return json({ ok: false, reason: 'error', error: (e as Error).message });
  }
}

// ---------------------------------------------------------------- bank statements
// Reads a bank statement the column reader could not: a scanned PDF (page images) or an unusual layout (page text with
// the columns kept apart by " | "). Up to 8 pages a call; the app sends a long statement two pages at a time and joins the parts.
const STATEMENT_SCHEMA = {
  type: 'OBJECT',
  properties: {
    bank_name: S.nstr, account_number: { type: 'STRING', nullable: true, description: 'Digits only, usually 10' }, account_name: S.nstr, currency: S.nstr,
    period_from: { type: 'STRING', nullable: true, description: 'YYYY-MM-DD' }, period_to: { type: 'STRING', nullable: true, description: 'YYYY-MM-DD' },
    opening_balance: { type: 'NUMBER', nullable: true, description: "The statement's opening balance as printed (header, Opening Balance or Balance B/F line), negative if overdrawn; null when not printed on these pages" },
    closing_balance: { type: 'NUMBER', nullable: true, description: "The statement's closing balance as printed (header, Closing Balance or Balance C/F line), negative if overdrawn; null when not printed on these pages. Never the last balance on a page" },
    order: { type: 'STRING', enum: ['oldest_first', 'newest_first'] },
    lines: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          date: { type: 'STRING', description: 'Transaction (posting) date, YYYY-MM-DD' },
          description: { type: 'STRING', description: 'The full narration, wrapped lines joined' },
          reference: S.nstr,
          debit: { type: 'NUMBER', nullable: true, description: 'Money out, positive naira' },
          credit: { type: 'NUMBER', nullable: true, description: 'Money in, positive naira' },
          balance: { type: 'NUMBER', nullable: true, description: 'Running balance after this line, negative if overdrawn' },
        },
        // Every field is asked for (null when not printed), so a reader in a hurry does not leave the balances out.
        required: ['date', 'description', 'reference', 'debit', 'credit', 'balance'],
      },
    },
    notes: { type: 'STRING', nullable: true, description: 'Anything the person should check, in one plain sentence' },
  },
  required: ['bank_name', 'account_number', 'account_name', 'period_from', 'period_to', 'opening_balance', 'closing_balance', 'order', 'lines', 'notes'],
};

async function readStatement(body: any) {
  if (!aiOn()) return json(notConfigured());
  const pages: string[] = (Array.isArray(body.pages) ? body.pages : []).slice(0, 8).map((p: unknown) => String(p ?? '').slice(0, 30000)).filter(Boolean);
  const images: { mime: string; data: string }[] = (Array.isArray(body.images) ? body.images : []).slice(0, 8)
    .filter((i: any) => i && /^image\/(jpeg|png|webp)$/.test(String(i.mime)) && typeof i.data === 'string' && i.data.length < 6_000_000);
  if (!pages.length && !images.length) return json({ ok: false, error: 'Nothing to read.' }, 400);
  const first = Number(body.first_page || 1);
  const system = `You read Nigerian bank statements so their transactions can be matched in a business's books.
Statements come from GTBank, Access, Zenith, First Bank, UBA, Fidelity, FCMB, Union, Sterling, Stanbic IBTC, Wema (ALAT), Polaris, Ecobank, Keystone,
Providus, Jaiz, Moniepoint, OPay, Kuda, PalmPay and others, each laid out its own way. Column names vary: Trans Date, Posted Date, Date Posted,
Value Date; Narration, Description, Details, Remarks; Reference, Ref No, Cheque No; Debit, Debits, Withdrawals, Money Out; Credit, Credits,
Deposits, Lodgements, Money In; Balance. Some use one Amount column with a sign, "DR"/"CR" after the figure, or a separate Dr/Cr column.
Rules:
- One entry in "lines" for every transaction, in the order printed. Join a narration that wraps onto the next printed line.
- Skip page headers and footers, repeated column headings, "Opening Balance", "Balance B/F", "Closing Balance", "Balance C/F", totals and subtotals:
  put the opening and closing figures in opening_balance and closing_balance instead.
- date is the transaction or posting date, not the value date. Dates are day first (01/10/2026 is 1 October 2026).
- debit is money out and credit is money in, both as positive numbers; leave the other one null. Never move a figure between the two.
- balance is the running balance printed on the line, negative when the statement shows it overdrawn (DR, a minus sign or brackets).
- order: newest_first when the printed dates run backwards.
- Copy figures exactly as printed. Never invent a line, a date or an amount; when a figure is unreadable leave it null and say so in notes.
${first > 1 ? `These are pages from page ${first} on: the statement's header may not be here, so leave the header fields null unless they are printed on these pages.` : ''}`;
  const parts: Part[] = [];
  if (pages.length) parts.push({ text: pages.map((p, i) => `PAGE ${first + i}:\n${p}`).join('\n\n') });
  for (const im of images) parts.push({ inlineData: { mimeType: im.mime, data: im.data } });
  parts.push({ text: 'Read this statement.' });
  // An answer whose lines carry no amounts, or whose fields run into each other, is a reading gone wrong: asked once more.
  const garbled = (d: any) => {
    const ls = Array.isArray(d?.lines) ? d.lines : [];
    return !ls.length || ls.filter((l: any) => l?.debit == null && l?.credit == null).length > ls.length / 2
      || ls.some((l: any) => /[\r\n]|\s\|\s/.test(`${l?.reference ?? ''}${l?.date ?? ''}`) || String(l?.reference ?? '').length > 80);
  };
  try {
    let { data, model } = await gemini(system, parts, STATEMENT_SCHEMA, 0, { thinking: 'low', timeoutMs: 80_000, org: orgOf(body), kind: 'read_statement' });
    if (garbled(data)) {
      try {
        const again = await gemini(system, parts, STATEMENT_SCHEMA, 0, { thinking: 'low', timeoutMs: 80_000, org: orgOf(body), kind: 'read_statement' });
        if (!garbled(again.data)) ({ data, model } = again);
      } catch { /* the first answer stands, and the checks in the app show what is wrong with it */ }
    }
    const day = (v: unknown) => (/^\d{4}-\d{2}-\d{2}$/.test(String(v || '')) ? String(v) : null);
    const lines = (data.lines || []).map((l: any) => ({
      date: day(l.date), description: String(l.description || '').replace(/\s+/g, ' ').trim().slice(0, 500), reference: l.reference ? String(l.reference).slice(0, 120) : null,
      debit: Number.isFinite(Number(l.debit)) && l.debit !== null ? Math.abs(Number(l.debit)) : null,
      credit: Number.isFinite(Number(l.credit)) && l.credit !== null ? Math.abs(Number(l.credit)) : null,
      balance: Number.isFinite(Number(l.balance)) && l.balance !== null ? Number(l.balance) : null,
    }));
    return json({ ok: true, model, ...data, lines, period_from: day(data.period_from), period_to: day(data.period_to),
      account_number: data.account_number ? String(data.account_number).replace(/\D/g, '') || null : null });
  } catch (e) {
    return json({ ok: false, reason: 'error', error: (e as Error).message });
  }
}

// ---------------------------------------------------------------- VAT treatment of items (Numens, Gemini until Numens is connected)
// Compares secrets in constant time.
function sameSecret(a: string, b: string) {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let d = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) d |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return d === 0;
}

const svcSecret = (admin: SupabaseClient, name: string) => vaultFirst(admin, name, 'svc_secret');

async function classifyVat(admin: SupabaseClient, items: VatItem[]): Promise<{ answers: VatAnswer[]; error?: string }> {
  if (!items.length) return { answers: [] };
  const url = await svcSecret(admin, 'NUMENS_API_URL'), key = await svcSecret(admin, 'NUMENS_API_KEY');
  let error: string | undefined;
  if (url && key) {
    try { return { answers: await numens(url, key, items) }; } catch (e) { error = (e as Error).message; console.warn('numens', error); }
  }
  if (!aiOn()) return { answers: [], error: error || 'No tax model is connected yet. TaxStreem is setting it up.' };
  const answers: VatAnswer[] = [];
  for (let i = 0; i < items.length; i += 30) {
    const chunk = items.slice(i, i + 30);
    const { data, model } = await gemini(VAT_SYSTEM, [{ text: vatPrompt(chunk) }], VAT_SCHEMA, 0.1, { thinking: 'low', org: chunk[0]?.org_id, kind: 'vat_classify' });
    answers.push(...cleanVat(chunk, data?.results || [], 'gemini', model));
  }
  return { answers };
}

async function applyVat(admin: SupabaseClient, items: VatItem[]) {
  const { answers, error } = await classifyVat(admin, items);
  if (error && !answers.length) return { ok: false, error, checked: 0 };
  const byId = new Map(answers.map((a) => [a.id, a]));
  const results = [];
  for (const it of items) {
    const a = byId.get(it.id);
    // No answer for an item the model was shown: a person decides (the item is flagged for review).
    const { data } = await admin.rpc('svc_set_item_vat', { p_item: it.id, p: a ? { treatment: a.treatment, confidence: a.confidence, reason: a.reason, law: a.law,
      source: a.source, model: a.model, nrs_label: a.nrs_label ?? null } : { treatment: null } });
    results.push({ id: it.id, name: it.name, treatment: a?.treatment ?? null, confidence: a?.confidence ?? 0, applied: Boolean(data?.applied), kept: data?.kept });
  }
  return { ok: true, checked: results.length, results };
}

// ---------------------------------------------------------------- VAT from other systems' records
// The lines of an uploaded sales schedule have no Counta product behind them: their VAT treatment is decided from the
// description, the same way as an item's (Numens, or Gemini until it is connected). The answers go back to the page,
// which shows them for the person to check before saving.
async function vatClassifyText(sb: SupabaseClient, admin: SupabaseClient, body: any) {
  const orgId = String(body.org_id || '');
  if (!isUuid(orgId)) return json({ ok: false, error: 'Choose the business.' }, 400);
  // Only someone who sees the business's VAT work may ask (the same check the schedules page uses).
  const { error } = await sb.rpc('get_sales_schedules', { p_org: orgId });
  if (error) return json({ ok: false, error: error.message }, 403);
  if (await paused(admin, orgId)) return json(PAUSED);
  const seen = new Set<string>();
  const items: VatItem[] = [];
  for (const l of Array.isArray(body.lines) ? body.lines : []) {
    const name = String(l?.name || '').replace(/\s+/g, ' ').trim().slice(0, 200);
    const key = name.toLowerCase();
    if (!name || seen.has(key)) continue;
    seen.add(key);
    items.push({ id: String(items.length + 1), org_id: orgId, name });
    if (items.length >= 300) break;
  }
  if (!items.length) return json({ ok: true, results: [] });
  const { data: org } = await admin.from('orgs').select('industry').eq('id', orgId).maybeSingle();
  for (const it of items) it.industry = org?.industry || undefined;
  const { answers, error: e2 } = await classifyVat(admin, items);
  if (e2 && !answers.length) return json({ ok: false, reason: aiOn() ? 'error' : 'not_configured', error: e2 });
  const byId = new Map(answers.map((a) => [a.id, a]));
  return json({ ok: true, results: items.map((it) => {
    const a = byId.get(it.id);
    return { name: it.name, treatment: a?.treatment ?? null, confidence: a?.confidence ?? 0, nrs_label: a?.nrs_label ?? null, reason: a?.reason ?? null, source: a?.source ?? null };
  }) });
}

// ---------------------------------------------------------------- VAT on money in with no Counta invoice
// A payment the business received with no invoice is taken as a sale; its VAT is decided per payment from what the business
// sells and what the payment says. The database hands over the payments waiting (svc_receipts_for_vat) and books each answer
// (svc_set_receipt_vat): at the business's threshold the sale is booked again, below it the payment is marked to check.
const RECEIPTS_RULES = `

You now decide the VAT on payments a Nigerian business received into its bank account or wallet with no invoice behind them. Each payment is taken as
a sale of what the business sells. Decide, for each payment, the VAT treatment of what was most likely sold.
- What the business sells comes first: its trade, the examples it gave of what it sells, and its products with the VAT each one carries.
- The narration may name what was bought (an item, a service, "school fees", "consultation"). Use it when it does; it decides over the usual.
- Most narrations name only the sender or a reference. Then decide from what the business sells. When everything it sells carries the same treatment,
  give that treatment with high confidence. When it sells things with different treatments and the payment does not say which, give the treatment of
  most of what it sells, with confidence below 0.8, so a person checks it.
- A sender's name is never evidence of what was bought, and a payment from an individual is not a reason for any treatment.
- reason: one short sentence the owner understands, saying what you went by (for example "Everything the business sells is medicine, which is
  zero-rated" or "The payment says it was for school fees: tuition is zero-rated").`;

async function vatReceiptsPending(admin: SupabaseClient) {
  if (!aiOn()) return { ok: false, reason: 'not_configured' };
  const { data: groups, error } = await admin.rpc('svc_receipts_for_vat', { p_limit: 40 });
  if (error) return { ok: false, error: error.message };
  let applied = 0, unsure = 0, failed = 0;
  for (const g of (groups as any[]) || []) {
    const sales: any[] = Array.isArray(g?.sales) ? g.sales : [];
    if (!sales.length || await paused(admin, g.org_id)) continue;
    const products = (Array.isArray(g.products) ? g.products : []).slice(0, 60)
      .map((p: any) => `${String(p.name || '').slice(0, 80)}: ${p.vat}`).join('\n');
    const examples = Array.isArray(g.business?.examples) ? g.business.examples.map((e: unknown) => String(e).slice(0, 80)).slice(0, 10) : [];
    const text = `BUSINESS\n${JSON.stringify({ name: g.business?.name || '', trade: g.business?.industry || '', sells: g.business?.offering || '',
      activity: g.business?.activity || '', category: g.business?.category || '', examples })}\n\nPRODUCTS (name: VAT)\n${products || '(none in Counta)'}\n\nPAYMENTS\n`
      + sales.map((s) => JSON.stringify({ id: String(s.id), date: s.date, amount: s.amount, narration: String(s.narration || '').slice(0, 200) })).join('\n');
    try {
      const { data } = await gemini(VAT_SYSTEM + RECEIPTS_RULES, [{ text }], VAT_SCHEMA, 0.1, { thinking: 'low', org: g.org_id, kind: 'vat_receipts' });
      const byId = new Map(((data?.results || []) as any[]).map((r) => [String(r?.id), r]));
      for (const s of sales) {
        const r = byId.get(String(s.id));
        const t = ['standard', 'zero', 'exempt'].includes(r?.treatment) ? r.treatment : null;
        const conf = Math.min(Math.max(Number(r?.confidence) || 0, 0), 1);
        const { data: res } = await admin.rpc('svc_set_receipt_vat', { p_sale: s.id, p: { treatment: t, confidence: t ? conf : 0,
          reason: r?.reason ? String(r.reason).slice(0, 300) : null } });
        if ((res as any)?.applied) applied++; else unsure++;
      }
    } catch (e) {
      failed += sales.length;
      console.warn('vat_receipts', (e as Error).message);
    }
  }
  return { ok: true, applied, unsure, failed };
}

// The kinds of purchase withholding tax tells apart, for an invoice the business paid (codes of wht_rates).
const PURCHASE_WHT = ['goods', 'services', 'professional', 'rent', 'commission', 'brokerage', 'construction_roads', 'construction_other', 'colocation',
  'ex_over_counter', 'ex_manufacturer', 'ex_telecom_airline', 'ex_petroleum', 'ex_insurance', 'ex_reimbursable', 'ex_bank_charges', 'none'];
const PURCHASE_SCHEMA = {
  type: 'OBJECT',
  properties: {
    is_invoice: S.bool, supplier_name: S.nstr, supplier_tin: S.nstr, invoice_no: S.nstr,
    invoice_date: { type: 'STRING', nullable: true, description: 'YYYY-MM-DD' }, description: S.nstr,
    net: { type: 'NUMBER', nullable: true, description: 'Amount before VAT' }, vat: { type: 'NUMBER', nullable: true, description: 'VAT shown on the invoice; 0 when none is shown' },
    total: S.nnum, vat_shown: S.bool, paid: { type: 'BOOLEAN', nullable: true, description: 'True when the document shows it was paid (receipt, PAID stamp, zero balance)' },
    confidence: S.int, warnings: { type: 'ARRAY', items: S.str },
    supplier_type: { type: 'STRING', nullable: true, enum: ['company', 'business_name', 'individual'], description: 'What the seller is' },
    supplier_address: S.nstr,
    wht_category: { type: 'STRING', nullable: true, enum: PURCHASE_WHT, description: 'The kind of purchase for withholding tax' },
  },
  required: ['is_invoice', 'vat_shown', 'confidence', 'warnings'],
};
// A purchase invoice uploaded to claim its input VAT: what it says, for the person to check. Nothing is saved here.
async function readPurchaseInvoice(sb: SupabaseClient, admin: SupabaseClient, body: any) {
  const orgId = String(body.org_id || ''), path = String(body.path || '');
  if (!isUuid(orgId) || !path.startsWith(orgId + '/') || path.includes('..')) return json({ ok: false, error: 'Upload the invoice first.' }, 400);
  const { error } = await sb.rpc('get_sales_schedules', { p_org: orgId });
  if (error) return json({ ok: false, error: error.message }, 403);
  if (!aiOn()) return json(notConfigured());
  if (await paused(admin, orgId)) return json(PAUSED);
  const { data: blob, error: dErr } = await sb.storage.from('documents').download(path);
  if (dErr || !blob) return json({ ok: false, error: 'Could not open the uploaded file.' });
  const bytes = new Uint8Array(await blob.arrayBuffer());
  if (bytes.length > 18 * 1024 * 1024) return json({ ok: false, error: 'The file is too large to read. Use a photo or PDF under 15MB.' });
  const mime = String(body.mime || blob.type || (path.endsWith('.pdf') ? 'application/pdf' : 'image/jpeg'));
  if (!/^(application\/pdf|image\/(jpeg|png|webp))$/.test(mime)) return json({ ok: false, error: 'Upload a PDF or a photo of the invoice.' });
  const { data: me } = await admin.from('orgs').select('name, tin').eq('id', orgId).maybeSingle();
  const system = `You read purchase invoices that a Nigerian business paid, so it can claim the input VAT on them in its monthly VAT return.
The buyer is ${me?.name || 'the business'}${me?.tin ? ` (Tax ID ${me.tin})` : ''}; the supplier is the other party.
Rules:
- is_invoice: false when this is not a supplier's invoice or receipt (a quotation, a delivery note with no prices, a bank statement, a photo of something else).
- supplier_name and supplier_tin as printed (the seller's, never the buyer's). invoice_no and invoice_date (YYYY-MM-DD; Nigerian dates are day first).
- net is the amount before VAT, vat the VAT charged as printed, total the amount payable. vat_shown is true only when the invoice shows a VAT amount or a
  VAT line at 7.5%; a price "inclusive of VAT" with no VAT figure is vat_shown false (no input VAT can be claimed from it).
- When the invoice shows a VAT figure but not the amount before VAT, net = total - vat.
- description: what was bought, in a few words.
- paid: true when it shows it was paid (a receipt, a PAID stamp, a zero balance), false when it shows an amount still due, null when you cannot tell.
- confidence 0-100: how sure you are of the figures. Below 80 when digits could be read two ways or the figures do not add up.
- warnings: short plain sentences about anything a person should check (the VAT is not 7.5% of the net, the buyer is someone else, the date is old).
- supplier_type: company when the seller's name carries Ltd, Limited, PLC or an RC number; business_name for an enterprise, ventures or a BN number;
  individual for a person; null when you cannot tell. supplier_address: the seller's address as printed, else null.
- wht_category, the kind of purchase for withholding tax: goods (supply of goods), services (repairs, cleaning, security, transport, printing, catering,
  events and other services), professional (consultancy, legal, audit, accounting, technical or management services), rent (rent, hire or lease),
  commission, brokerage, construction_roads (roads, bridges, buildings, power plants), construction_other (other building or installation work),
  colocation (telecom tower co-location), ex_over_counter (bought across the counter and paid on the spot, as at a shop), ex_manufacturer (goods the
  seller makes itself), ex_telecom_airline (telephone, internet data, airline tickets), ex_petroleum (petrol, diesel, kerosene, cooking gas), ex_insurance
  (insurance premiums), ex_reimbursable (costs reimbursed at cost), ex_bank_charges (bank charges), none when nothing applies.
- Never invent a figure that is not on the document.`;
  let out: any, model = MODEL;
  try {
    const res = await gemini(system, [{ text: 'Read this purchase invoice.' }, { inlineData: { mimeType: mime, data: encodeBase64(bytes) } }], PURCHASE_SCHEMA, 0.1, { thinking: 'low', org: orgId, kind: 'read_purchase_invoice' });
    out = res.data; model = res.model;
  } catch (e) {
    if (e instanceof CredentialError) return json(notConfigured());
    return json({ ok: false, error: 'Could not read the invoice: ' + (e as Error).message });
  }
  const n = (v: unknown) => (v == null || v === '' || !Number.isFinite(Number(v)) ? null : Math.round(Number(v) * 100) / 100);
  let net = n(out.net), vat = n(out.vat), total = n(out.total);
  if (net == null && total != null && vat != null) net = Math.round((total - vat) * 100) / 100;
  if (total == null && net != null && vat != null) total = Math.round((net + vat) * 100) / 100;
  const warnings: string[] = (Array.isArray(out.warnings) ? out.warnings : []).map((w: unknown) => String(w).slice(0, 200)).slice(0, 6);
  if (net != null && vat != null && vat > net * 0.075 + 1) warnings.push('The VAT is more than 7.5% of the amount before VAT.');
  if (net != null && vat != null && total != null && Math.abs(net + vat - total) > 1) warnings.push('The amount before VAT and the VAT do not add up to the total.');
  const day = /^\d{4}-\d{2}-\d{2}$/.test(String(out.invoice_date || '')) ? out.invoice_date : null;
  return json({ ok: true, model, invoice: {
    is_invoice: Boolean(out.is_invoice), supplier_name: out.supplier_name ? String(out.supplier_name).slice(0, 160) : null, supplier_tin: invoiceTin(out.supplier_tin),
    invoice_no: out.invoice_no ? String(out.invoice_no).slice(0, 60) : null, invoice_date: day, description: out.description ? String(out.description).slice(0, 200) : null,
    net, vat: out.vat_shown ? vat : 0, total, vat_shown: Boolean(out.vat_shown) && (vat || 0) > 0, paid: out.paid ?? null,
    confidence: Math.max(0, Math.min(100, Math.round(Number(out.confidence) || 0))), warnings,
    supplier_type: ['company', 'business_name', 'individual'].includes(out.supplier_type) ? out.supplier_type : null,
    supplier_address: out.supplier_address ? String(out.supplier_address).slice(0, 300) : null,
    wht_category: PURCHASE_WHT.includes(out.wht_category) ? out.wht_category : null } });
}

// ---------------------------------------------------------------- moving the books: old chart to Counta's chart
const MAP_SCHEMA = {
  type: 'OBJECT',
  properties: {
    results: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: { id: S.str, code: { type: 'STRING', nullable: true, description: 'A Counta account code from the list, or null' },
          confidence: { type: 'NUMBER', description: '0 to 1' }, reason: S.str },
        required: ['id', 'code', 'confidence', 'reason'],
      },
    },
  },
  required: ['results'],
};
const MAP_SYSTEM = [
  'You are a chartered accountant moving a Nigerian business from QuickBooks, Zoho Books, Xero or Sage into Counta.',
  'For each account from the old trial balance, choose the one Counta account its balance belongs in, from the list given. Use only codes in the list.',
  'Bank, cash and payment wallet accounts map to 1012 (naira bank), 1013 (foreign currency bank), 1011 (cash) or 1014 (wallet); Counta opens a bank account for each.',
  'Accounts receivable control accounts map to 1101, accounts payable control accounts to 2101. Opening balance equity maps to 3999.',
  'Respect the side of the balance: a credit balance on an asset-sounding account may be an overdraft or a liability.',
  'Confidence is how sure you are that a careful accountant would choose the same account: 0.9 or more only when the name and type leave no doubt; below 0.8 when a person should check.',
  'Reason: one short sentence in plain English.',
].join(' ');
async function mapAccounts(sb: SupabaseClient, body: any) {
  if (!aiOn()) return json(notConfigured());
  const { data: g, error } = await sb.rpc('get_books_migration', { p_org: String(body.org_id || '') });
  if (error) return json({ ok: false, error: error.message });
  const mig = g?.migration;
  if (!mig || mig.status !== 'draft') return json({ ok: false, error: 'There is no migration in progress.' });
  // Only what a person has not decided and the rules were not sure about.
  const todo = (g.accounts || []).filter((a: any) => a.mapped_by !== 'person' && (a.confidence ?? 0) < 0.9).slice(0, 400);
  if (!todo.length) return json({ ok: true, ai_updated: 0, ...g });
  const { data: chart, error: e2 } = await sb.rpc('get_chart', { p_org: mig.org_id });
  if (e2) return json({ ok: false, error: e2.message });
  const list = ((chart?.accounts || []) as any[])
    .filter((a) => a.active !== false && (!a.is_group || ['1011', '1012', '1013', '1014'].includes(a.code)) && a.statement !== 'system' || ['3999', '9002'].includes(a.code))
    .map((a) => `${a.code} ${a.name} [${a.ifrs_line || a.category}]`).join(NL);
  const rows = todo.map((a: any) => JSON.stringify({ id: a.id, code: a.source_code, name: a.source_name, type: a.source_type,
    balance: Number(a.debit) - Number(a.credit), rule_guess: a.mapped_code, rule_confidence: a.confidence })).join(NL);
  const prompt = `Source system: ${mig.source}. Cut-over date: ${mig.as_of}.${NL}${NL}Counta accounts (code name [statement line]):${NL}${list}${NL}${NL}`
    + `Old accounts to place (balance is debit positive):${NL}${rows}`;
  const results: any[] = [];
  let model = '';
  for (let i = 0; i < todo.length; i += 80) {
    const chunkIds = new Set(todo.slice(i, i + 80).map((a: any) => a.id));
    const chunkRows = rows.split(NL).filter((r: string) => chunkIds.has(JSON.parse(r).id)).join(NL);
    const out = await gemini(MAP_SYSTEM, [{ text: prompt.replace(rows, () => chunkRows) }], MAP_SCHEMA, 0.1, { thinking: 'low', org: mig.org_id, kind: 'map_accounts' });
    model = out.model;
    results.push(...((out.data?.results || []) as any[]).filter((r) => chunkIds.has(r.id)));
  }
  const { data: res, error: e3 } = await sb.rpc('migration_ai_map', { p_migration: mig.id, p_maps: results, p_model: model });
  if (e3) return json({ ok: false, error: e3.message });
  return json({ ok: true, model, ...res });
}

// ---------------------------------------------------------------- CIT: audited accounts or a trial balance onto the Rev360 lines
// body: {org_id, year, kind: 'afs' | 'trial_balance', file_path (PDF or picture in the business's documents), rows (a trial balance read in the browser)}
async function citMap(sb: SupabaseClient, body: any) {
  if (!aiOn()) return json(notConfigured());
  const orgId = String(body.org_id || ''), year = Number(body.year), kind = body.kind === 'trial_balance' ? 'trial_balance' : 'afs';
  // The year as the person may see it: proves they may handle tax returns for this business, and gives the template lines.
  const { data: cy, error } = await sb.rpc('cit_year', { p_org: orgId, p_year: year });
  if (error) return json({ ok: false, error: error.message });
  if (!cy?.can_edit) return json({ ok: false, error: 'Only someone who keeps the books, on a return not yet approved, reads statements into it.' });
  const lines = (cy.lines || []) as TemplateLine[];
  const parts: Part[] = [{ text: `Accounting year: ${year} (${cy.period?.from} to ${cy.period?.to}).${NL}Template input lines (cell | section | label):${NL}${catalogueText(lines)}` }];
  const path = String(body.file_path || '');
  if (path) {
    if (path.split('/')[0] !== orgId) return json({ ok: false, error: 'That file is not this business\'s.' });
    // Downloaded as the person: storage rules decide whether they may read it.
    const { data: blob, error: dErr } = await sb.storage.from('documents').download(path);
    if (dErr || !blob) return json({ ok: false, error: 'Could not open the file.' });
    if (blob.size > 18_000_000) return json({ ok: false, error: 'The file is larger than 18 MB. Upload the statements without the scanned appendices.' });
    const mime = blob.type && blob.type !== 'application/octet-stream' ? blob.type : path.toLowerCase().endsWith('.pdf') ? 'application/pdf' : 'image/jpeg';
    if (!/^(application\/pdf|image\/(jpeg|png|webp))$/.test(mime)) return json({ ok: false, error: 'Upload the statements as a PDF or a picture.' });
    parts.push({ text: kind === 'afs' ? 'The audited financial statements:' : 'The trial balance:' });
    parts.push({ inlineData: { mimeType: mime, data: encodeBase64(new Uint8Array(await blob.arrayBuffer())) } });
  } else if (Array.isArray(body.rows) && body.rows.length) {
    parts.push({ text: `The trial balance at the year end (code | account | balance):${NL}${tbText(body.rows as TbRow[])}` });
  } else {
    return json({ ok: false, error: 'Upload the audited financial statements or a trial balance.' });
  }
  const { data, model } = await gemini(CIT_MAP_SYSTEM, parts, CIT_MAP_SCHEMA, 0.1, { timeoutMs: 120_000, org: orgId, kind: 'cit_map' });
  const { lines: placed, dropped } = cleanCitLines(data?.lines || [], lines);
  if (!placed.length) return json({ ok: false, error: 'No figures could be read from it. Check it is the full statements for ' + year + '.', warnings: data?.warnings || [] });
  const totals = data?.totals || {};
  const { data: after, error: e2 } = await sb.rpc('cit_import', { p_org: orgId, p_year: year,
    p: { lines: placed, totals, file_path: path || null, kind, replace: body.replace !== false } });
  if (e2) return json({ ok: false, error: e2.message });
  // The statements read are the ones the return is filed with, unless others are attached already.
  if (kind === 'afs' && path && !after?.row?.afs_path) await sb.rpc('save_cit_year', { p_org: orgId, p_year: year, p: { afs_path: path } });
  return json({ ok: true, model, placed: placed.length, low_confidence: placed.filter((l) => l.confidence < 0.8).length, dropped, totals,
    period_end: data?.period_end || null, company_name: data?.company_name || null, warnings: data?.warnings || [],
    checks: (after?.computation?.checks || []).filter((c: any) => ['pbt_ties_to_afs', 'revenue_ties_to_pl', 'sfp_ties_to_accounts', 'figures_missing'].includes(c.id)) });
}

// ---------------------------------------------------------------- onboarding
// What the web says about the business on the person's profile (their own draft, or the business they own).
async function businessInsights(sb: SupabaseClient, admin: SupabaseClient, body: any, userId: string) {
  if (!aiOn()) return json(notConfigured());
  const orgId = body.org_id ? String(body.org_id) : null;
  const { data: k, error } = await sb.rpc('kyc_draft', orgId ? { p_org: orgId } : {});
  if (error) return json({ ok: false, error: error.message });
  if (!k?.business?.name) return json({ ok: false, error: 'Find the business first.' });
  const { data: allowed } = await admin.rpc('svc_kyc_take', { p_user: userId, p_kind: 'web' });
  if (!allowed) return json({ ok: false, reason: 'limit', error: 'Counta has looked the business up online a few times today already.' });
  const { data: cats } = await sb.from('business_categories').select('id, label, kind').order('sort');
  const list = (cats || []) as Category[];
  let found: any; let model = '';
  try {
    const r = await gemini(INSIGHT_SYSTEM, [{ text: insightPrompt(k.business, list) }], null, 0.3, { search: true, timeoutMs: 60_000, org: orgId, kind: 'business_insights' });
    found = cleanInsight(r.data, list, r.grounding); model = r.model;
  } catch (e) {
    if (e instanceof CredentialError) throw e;
    return json({ ok: false, reason: 'error', error: 'The web search did not finish. Carry on without it.' });
  }
  const { data: kyc, error: e2 } = await admin.rpc('svc_kyc_store', { p_user: userId, p_part: 'web', p_data: { ...found, model }, p_org: orgId });
  if (e2) return json({ ok: false, error: e2.message });
  return json({ ok: true, kyc, insights: found });
}

// The CAC document the owner added (kyc_doc), read and compared with the CAC record.
async function readCacDocument(sb: SupabaseClient, admin: SupabaseClient, body: any, userId: string) {
  if (!aiOn()) return json(notConfigured());
  const orgId = String(body.org_id || '');
  const { data: k, error } = await sb.rpc('kyc_draft', { p_org: orgId });
  if (error) return json({ ok: false, error: error.message });
  const path = String(k?.doc?.path || '');
  if (!path || path.split('/')[0] !== orgId) return json({ ok: false, error: 'Add the CAC document first.' });
  const { data: allowed } = await admin.rpc('svc_kyc_take', { p_user: userId, p_kind: 'document' });
  if (!allowed) return json({ ok: false, reason: 'limit', error: 'Counta has read a few documents for you today already. Try again tomorrow.' });
  // Downloaded as the person: only the owner may read the CAC folder.
  const { data: blob, error: dErr } = await sb.storage.from('documents').download(path);
  if (dErr || !blob) return json({ ok: false, error: 'Could not open the document.' });
  if (blob.size > 15_000_000) return json({ ok: false, error: 'The document is larger than 15 MB. Upload just the status report pages.' });
  const mime = blob.type && blob.type !== 'application/octet-stream' ? blob.type : path.toLowerCase().endsWith('.pdf') ? 'application/pdf' : 'image/jpeg';
  if (!/^(application\/pdf|image\/(jpeg|png|webp))$/.test(mime)) return json({ ok: false, error: 'Upload the document as a PDF or a picture.' });
  const { data, model } = await gemini(CAC_DOC_SYSTEM, [{ text: `The person added this as: ${k.doc.kind}.` },
    { inlineData: { mimeType: mime, data: encodeBase64(new Uint8Array(await blob.arrayBuffer())) } }], CAC_DOC_SCHEMA, 0.1, { timeoutMs: 90_000, org: orgId, kind: 'read_cac_document' });
  const extract = cleanCacDoc(data);
  const checks = cacDocChecks(extract, k.business, String(k.doc.kind || 'other'));
  const { data: kyc, error: e2 } = await admin.rpc('svc_kyc_store', { p_user: userId, p_part: 'doc',
    p_data: { extract, checks, model, read_at: new Date().toISOString() }, p_org: orgId });
  if (e2) return json({ ok: false, error: e2.message });
  return json({ ok: true, kyc, extract, checks });
}

// The NIN slip the owner added when their NIN did not match a director: read, then compared with the directors by the database.
async function readNinSlip(sb: SupabaseClient, admin: SupabaseClient, body: any, userId: string) {
  if (!aiOn()) return json(notConfigured());
  const orgId = String(body.org_id || '');
  const { data: st, error } = await sb.rpc('identity_state', { p_org: orgId });
  if (error) return json({ ok: false, error: error.message });
  if (!st?.can_check) return json({ ok: false, error: 'Only the owner adds the NIN slip.' });
  const path = String(st?.slip?.path || '');
  if (!path.startsWith(`${orgId}/kyc/nin-slip-`)) return json({ ok: false, error: 'Add the NIN slip first.' });
  const { data: allowed } = await admin.rpc('svc_kyc_take', { p_user: userId, p_kind: 'nin_slip' });
  if (!allowed) return json({ ok: false, reason: 'limit', error: 'Counta has read a few NIN slips for you today already. Try again tomorrow.' });
  // Downloaded as the person: only the owner may read the business's identity folder.
  const { data: blob, error: dErr } = await sb.storage.from('documents').download(path);
  if (dErr || !blob) return json({ ok: false, error: 'Could not open the NIN slip.' });
  if (blob.size > 10_000_000) return json({ ok: false, error: 'The file is larger than 10 MB. Take a photo of the slip instead.' });
  const mime = blob.type && blob.type !== 'application/octet-stream' ? blob.type : path.toLowerCase().endsWith('.pdf') ? 'application/pdf' : 'image/jpeg';
  if (!/^(application\/pdf|image\/(jpeg|png|webp))$/.test(mime)) return json({ ok: false, error: 'Add the NIN slip as a PDF or a photo.' });
  const { data } = await gemini(NIN_SLIP_SYSTEM, [{ text: 'Read this identity document.' },
    { inlineData: { mimeType: mime, data: encodeBase64(new Uint8Array(await blob.arrayBuffer())) } }], NIN_SLIP_SCHEMA, 0, { timeoutMs: 60_000, org: orgId, kind: 'read_nin_slip' });
  const extract = cleanNinSlip(data);
  const { data: identity, error: e2 } = await admin.rpc('svc_identity_slip', { p_user: userId, p_org: orgId, p_extract: extract });
  if (e2) return json({ ok: false, error: e2.message });
  // A slip that matches no director waits for TaxStreem: the review address and the reviewers hear of it.
  if (identity?.status === 'review') await tellReviewers(admin, orgId);
  return json({ ok: true, identity, document_type: extract.document_type });
}

// An email to the review address (KYC_REVIEW_EMAIL, admin@taxstreem.com unless set in the admin portal) and every reviewer.
// It names the business and links to the review page; the NIN and what the slip says stay in the portal. Best effort: the
// owner's answer never waits on it or fails because of it.
const RESEND = (Deno.env.get('RESEND_BASE_URL') || 'https://api.resend.com').replace(/\/$/, '');
async function tellReviewers(admin: SupabaseClient, orgId: string) {
  try {
    const key = await svcSecret(admin, 'RESEND_API_KEY');
    const from = String(await svcSecret(admin, 'RESEND_FROM')).match(/[A-Z0-9._%+-]+@[A-Z0-9-]+(?:\.[A-Z0-9-]+)*\.[A-Z]{2,}/i)?.[0];
    if (!key || !from) { console.warn('nin review: email is not set up'); return; }
    const { data: to } = await admin.rpc('svc_review_recipients');
    const list = (Array.isArray(to) ? to : []).filter((e: unknown) => typeof e === 'string').slice(0, 20);
    if (!list.length) return;
    const { data: org } = await admin.from('orgs').select('name').eq('id', orgId).maybeSingle();
    const name = String(org?.name || 'A business').replace(/[\r\n]+/g, ' ').slice(0, 120);
    const app = (String(await svcSecret(admin, 'APP_URL')) || 'https://counta-taxstreem.netlify.app').replace(/\/$/, '');
    const text = [`${name} added a NIN slip, and Counta could not match it to a director on the business's CAC record.`,
      'Payments, payment links and payouts stay locked for the business until a reviewer decides.', '',
      `Review it in the admin portal: ${app}/admin/reviews`, '',
      'This email carries no NIN and nothing from the slip. Those are in the portal, behind your authenticator code.'].join(NL);
    const r = await fetch(`${RESEND}/emails`, { method: 'POST', signal: AbortSignal.timeout(10_000),
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', 'Idempotency-Key': `nin-review-${orgId}-${new Date().toISOString().slice(0, 16)}` },
      body: JSON.stringify({ from: `Counta <${from}>`, to: list, subject: `NIN slip to review: ${name}`, text }) });
    if (!r.ok) console.warn('nin review email', r.status, (await r.text()).slice(0, 200));
  } catch (e) { console.warn('nin review email', (e as Error).message); }
}

// ---------------------------------------------------------------- supplier invoices
// From the invoice portal (a supplier, no sign-in) or uploaded by someone in the business. Counta reads the invoice, asks
// the bank whose name the account is in, writes what it read (the database finds or adds the supplier, writes a draft bill
// and checks the invoice), checks a new Tax ID with the NRS, and then tells the supplier what is wrong.
async function hookSecret(admin: SupabaseClient) {
  const env = (Deno.env.get('PUSH_HOOK_SECRET') || '').trim();
  if (env) return env;
  const { data } = await admin.rpc('app_secret', { p_name: 'PUSH_HOOK_SECRET' });
  return typeof data === 'string' ? data.trim() : '';
}
async function callHook(admin: SupabaseClient, fn: string, body: Record<string, unknown>, timeoutMs = 20_000): Promise<any> {
  const key = await hookSecret(admin);
  if (!key) return null;
  try {
    const r = await fetch(`${SUPABASE_URL}/functions/v1/${fn}`, { method: 'POST', signal: AbortSignal.timeout(timeoutMs),
      headers: { 'Content-Type': 'application/json', 'x-counta-hook': key, Authorization: `Bearer ${SERVICE}` }, body: JSON.stringify(body) });
    return await r.json().catch(() => null);
  } catch (e) { console.warn('hook', fn, (e as Error).message); return null; }
}
const MAX_INVOICE = 8 * 1024 * 1024;
async function readSupplier(admin: SupabaseClient, open: any, bytes: Uint8Array, mime: string) {
  const sha = await sha256hex(bytes);
  const fileMeta = { path: open.path, sha256: sha, file_size: bytes.length, mime };
  const finish = async (p: Record<string, unknown>) => {
    const { data, error } = await admin.rpc('svc_si_read', { p_id: open.id, p: { ...fileMeta, ...p } });
    if (error) throw new Error(error.message);
    return data;
  };
  if (!aiOn()) return await finish({ error: 'Counta could not read it: AI reading is not switched on yet. Enter the bill by hand from the invoice.' });
  if (await paused(admin, open.org_id)) return await finish({ error: 'AI reading is paused for this business. Enter the bill by hand from the invoice.' });
  const { data: org } = await admin.from('orgs').select('name, tin').eq('id', open.org_id).maybeSingle();
  let x: any, model = MODEL;
  try {
    const r = await gemini(supplierSystem({ name: org?.name || open.business, tin: org?.tin }, open.accounts || [], open.wht || []),
      [{ text: 'Read this invoice.' }, { inlineData: { mimeType: mime, data: encodeBase64(bytes) } }], SUPPLIER_SCHEMA, 0,
      { thinking: 'low', timeoutMs: 80_000, org: open.org_id, kind: 'supplier_invoice' });
    x = cleanSupplier(r.data); model = r.model;
  } catch (e) {
    if (e instanceof CredentialError) return await finish({ error: 'Counta could not read it just now (AI reading is not available). Enter the bill by hand from the invoice.' });
    return await finish({ error: 'Counta could not read the invoice: ' + (e as Error).message });
  }
  // Whose name the bank holds the account in, when the invoice gives one.
  let resolved: string | null = null;
  const acct = String(x.bank?.account_number || '').replace(/\D/g, '');
  if (/^\d{10}$/.test(acct)) {
    const r = await callHook(admin, 'payments', { action: 'resolve_hook', account_number: acct, bank_name: x.bank?.bank_name || '' });
    if (r?.ok && r.account_name) resolved = String(r.account_name).slice(0, 160);
  }
  const read = await finish({ extract: x, model, bank_resolved_name: resolved });
  // A Tax ID Counta has not checked yet is checked with the NRS before the checks are final.
  if (read?.tin_check) await callHook(admin, 'mono', { action: 'verify_vendor_tin', org_id: open.org_id, vendor_id: read.tin_check }, 25_000);
  const { data: done, error } = await admin.rpc('svc_si_finish', { p_id: open.id });
  if (error) throw new Error(error.message);
  return done;
}

// What the supplier is told on the page: the problems Counta found that are theirs to fix.
const supplierView = (si: any) => ({ number: si?.number, status: si?.status, business: si?.business,
  issues: (Array.isArray(si?.checks) ? si.checks : []).filter((c: any) => c.notify && c.severity !== 'info').map((c: any) => String(c.text)),
  emailed: si?.notice_status === 'sent', failed: si?.status === 'failed' });

async function portalUpload(admin: SupabaseClient, req: Request, body: any) {
  const raw = String(body.file || '');
  if (!raw) return json({ ok: false, error: 'Choose the invoice file.' }, 400);
  if (raw.length > Math.ceil(MAX_INVOICE / 3) * 4 + 8) return json({ ok: false, error: 'The file is larger than 8 MB. Send a smaller PDF or a photo.' }, 413);
  let bytes: Uint8Array;
  try { bytes = Uint8Array.from(atob(raw.replace(/^data:[^,]+,/, '')), (c) => c.charCodeAt(0)); } catch { return json({ ok: false, error: 'The file could not be read.' }, 400); }
  const mime = sniff(bytes);
  if (!mime) return json({ ok: false, error: 'Send the invoice as a PDF or a photo (JPEG, PNG or WebP).' }, 400);
  if (bytes.length > MAX_INVOICE) return json({ ok: false, error: 'The file is larger than 8 MB. Send a smaller PDF or a photo.' }, 413);
  const ip = (req.headers.get('x-forwarded-for') || req.headers.get('cf-connecting-ip') || '').split(',')[0].trim();
  const ext = mime === 'application/pdf' ? 'pdf' : mime.split('/')[1].replace('jpeg', 'jpg');
  const { data: open, error } = await admin.rpc('svc_si_open', { p: { source: 'portal', token: String(body.token || ''), submitter: body.submitter || {},
    mime, file_name: String(body.file_name || '').slice(0, 160), file_size: bytes.length, sha256: await sha256hex(bytes),
    ip_hash: ip ? (await sha256hex(ip + SERVICE.slice(-16))).slice(0, 32) : null } });
  if (error) return json({ ok: false, error: error.message });
  const path = `${open.org_id}/bills/supplier-${open.id}.${ext}`;
  const up = await admin.storage.from('documents').upload(path, bytes, { contentType: mime, upsert: false });
  if (up.error) return json({ ok: false, error: 'The file could not be saved just now. Try again.' }, 500);
  open.path = path;
  try {
    const si = await readSupplier(admin, open, bytes, mime);
    return json({ ok: true, invoice: { ...supplierView(si), business: open.business } });
  } catch (e) {
    console.error('portal invoice', (e as Error).message);
    return json({ ok: true, invoice: { number: open.number, business: open.business, status: 'reading', issues: [], emailed: false } });
  }
}

async function readSupplierUpload(sb: SupabaseClient, admin: SupabaseClient, body: any, userId: string) {
  const orgId = String(body.org_id || ''), path = String(body.path || '');
  if (!isUuid(orgId) || !path.startsWith(orgId + '/') || path.includes('..')) return json({ ok: false, error: 'Upload the invoice first.' }, 400);
  const { data: me } = await sb.from('members').select('id').eq('org_id', orgId).eq('user_id', userId).eq('status', 'active').maybeSingle();
  if (!me) return json({ ok: false, error: 'You are not a member of this business.' }, 403);
  // Downloaded as the person: storage rules decide whether they may read it.
  const { data: blob, error: dErr } = await sb.storage.from('documents').download(path);
  if (dErr || !blob) return json({ ok: false, error: 'Could not open the uploaded file.' });
  const bytes = new Uint8Array(await blob.arrayBuffer());
  if (bytes.length > MAX_INVOICE) return json({ ok: false, error: 'The file is larger than 8 MB. Upload a smaller PDF or a photo.' });
  const mime = sniff(bytes);
  if (!mime) return json({ ok: false, error: 'Upload the invoice as a PDF or a photo (JPEG, PNG or WebP).' });
  const { data: open, error } = await admin.rpc('svc_si_open', { p: { source: 'upload', org_id: orgId, member_id: me.id, path, mime,
    file_name: String(body.file_name || '').slice(0, 160), file_size: bytes.length, sha256: await sha256hex(bytes) } });
  if (error) return json({ ok: false, error: error.message });
  const si = await readSupplier(admin, open, bytes, mime);
  return json({ ok: true, invoice: si });
}

// A product from photos of its front and back, for someone who may add products to the business.
async function readProduct(sb: SupabaseClient, admin: SupabaseClient, body: any, userId: string) {
  if (!aiOn()) return json(notConfigured());
  const orgId = String(body.org_id || '');
  const { data: me } = await sb.from('members').select('role, p_add_items, p_edit_prices').eq('org_id', orgId).eq('user_id', userId).eq('status', 'active').maybeSingle();
  if (!me || !(me.role === 'owner' || me.p_add_items || me.p_edit_prices)) return json({ ok: false, error: 'Your role does not add products. Ask the owner for "Add products".' });
  const images: { mime: string; data: string }[] = (Array.isArray(body.images) ? body.images : []).slice(0, 3)
    .filter((i: any) => i && /^image\/(jpeg|png|webp)$/.test(String(i.mime)) && typeof i.data === 'string' && i.data.length < 6_000_000);
  if (!images.length) return json({ ok: false, error: 'Take a photo of the product first.' }, 400);
  const { data: allowed } = await admin.rpc('svc_kyc_take', { p_user: userId, p_kind: 'product' });
  if (!allowed) return json({ ok: false, reason: 'limit', error: 'That is a lot of products for one day. Add the rest by typing them in.' });
  const categories: string[] = (Array.isArray(body.categories) ? body.categories : []).slice(0, 60).map((c: unknown) => String(c).slice(0, 40));
  const device = validBarcode(body.barcode);
  const parts: Part[] = [{ text: [`The business: ${String(body.industry || 'retail').slice(0, 40)}.`, `Its categories: ${categories.join(', ') || 'none yet'}.`,
    device ? `The phone read this barcode on the back: ${device}.` : 'The phone could not read a barcode.',
    images.length > 1 ? 'The first photo is the front of the product, the second the back.' : 'One photo of the product.'].join(NL) }];
  for (const im of images) parts.push({ inlineData: { mimeType: im.mime, data: im.data } });
  try {
    const { data, model } = await gemini(PRODUCT_SYSTEM, parts, PRODUCT_SCHEMA, 0.1, { thinking: 'low', timeoutMs: 45_000, org: orgId, kind: 'read_product' });
    const product = cleanProduct(data, device, categories);
    if (!product.name) return json({ ok: false, error: 'The photo did not show the product name clearly. Take it again closer, or type it in.' });
    return json({ ok: true, product, model });
  } catch (e) {
    if (e instanceof CredentialError) throw e;
    return json({ ok: false, reason: 'error', error: 'The photos could not be read just now. Type the product in, or try again.' });
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  const authHeader = req.headers.get('Authorization') || '';
  const sb = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } });
  const admin = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false } });
  // The database's own calls (new or renamed items waiting for a VAT decision) carry the shared hook secret, not a user.
  const hook = req.headers.get('x-counta-hook') || '';
  if (hook) {
    let expected = Deno.env.get('PUSH_HOOK_SECRET') || '';
    if (!expected) {
      const { data } = await admin.rpc('app_secret', { p_name: 'PUSH_HOOK_SECRET' });
      expected = typeof data === 'string' ? data.trim() : '';
    }
    if (!expected || !sameSecret(expected, hook)) return json({ ok: false, error: 'Not allowed.' }, 401);
    let hb: any = {};
    try { hb = await req.json(); } catch { /* empty body */ }
    if (hb.action !== 'vat_classify_pending' && hb.action !== 'vat_receipts_pending') return json({ ok: false, error: 'Unknown action.' }, 400);
    try {
      await loadKeys(admin);
      if (hb.action === 'vat_receipts_pending') return json(await vatReceiptsPending(admin));
      const { data: items } = await admin.rpc('svc_items_for_vat', { p_limit: 60 });
      const open = new Map<string, boolean>();
      const keep: VatItem[] = [];
      for (const it of (items as VatItem[]) || []) {
        if (!open.has(it.org_id)) open.set(it.org_id, !(await paused(admin, it.org_id)));
        if (open.get(it.org_id)) keep.push(it);
      }
      return json(await applyVat(admin, keep));
    } catch (e) {
      return json({ ok: false, error: (e as Error).message }, 500);
    }
  }
  let body: any;
  try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid request.' }, 400); }
  // The invoice portal: a supplier with the business's link, no account.
  if (body?.action === 'portal_upload') {
    try { await loadKeys(admin); return await portalUpload(admin, req, body); }
    catch (e) { return json({ ok: false, error: (e as Error).message }, 500); }
  }
  const { data: u } = await sb.auth.getUser();
  if (!u?.user) return json({ ok: false, error: 'Sign in first.' }, 401);
  try {
    await loadKeys(admin);
    // Everything but the status and the connection check waits while TaxStreem has paused AI reading.
    const orgId = isUuid(body.org_id) ? body.org_id : null;
    if (!['status', 'check'].includes(body.action) && await paused(admin, orgId)) return json(PAUSED);
    switch (body.action) {
      case 'status': {
        const off = await paused(admin, orgId);
        return json({ ok: true, configured: aiOn() && !off, paused: off, model: MODEL, auth: CFG.mode, location: CFG.mode === 'vertex' ? CFG.location : undefined,
          problem: CFG.problem });
      }
      case 'check': {
        // A one-line request, so the person setting up Vertex AI sees at once whether the credential and the project work.
        if (!aiOn()) return json(notConfigured());
        const t0 = Date.now();
        try {
          const { data, model } = await gemini('Answer in JSON.', [{ text: 'Reply with ok set to true.' }], { type: 'OBJECT', properties: { ok: S.bool }, required: ['ok'] }, 0, { kind: 'check' });
          return json({ ok: data?.ok === true, model, auth: CFG.mode, location: CFG.mode === 'vertex' ? CFG.location : undefined, ms: Date.now() - t0 });
        } catch (e) {
          return json({ ok: false, reason: 'error', error: (e as Error).message, auth: CFG.mode });
        }
      }
      case 'vat_classify_item': {
        // The item must be visible to the caller (row-level security), which proves they belong to its business.
        const { data: it } = await sb.from('items').select('id, org_id, name, category, brand, description, item_type, selling_unit, vat_treatment')
          .eq('id', String(body.item_id || '')).maybeSingle();
        if (!it) return json({ ok: false, error: 'Item not found.' });
        const { data: org } = await admin.from('orgs').select('industry').eq('id', it.org_id).maybeSingle();
        return json(await applyVat(admin, [{ id: it.id, org_id: it.org_id, name: it.name, category: it.category, brand: it.brand, description: it.description,
          item_type: it.item_type, unit: it.selling_unit, current: it.vat_treatment, industry: org?.industry }]));
      }
      case 'read_invoice': return await readInvoice(sb, admin, body, u.user.id);
      case 'read_purchase_invoice': return await readPurchaseInvoice(sb, admin, body);
      case 'vat_classify_text': return await vatClassifyText(sb, admin, body);
      case 'ask': return await ask(body);
      case 'chat': return await chat(body);
      case 'voice': return await voice(body);
      case 'map_columns': return await mapColumns(body);
      case 'extract_rows': return await extractRows(body);
      case 'read_statement': return await readStatement(body);
      case 'map_accounts': return await mapAccounts(sb, body);
      case 'cit_map': return await citMap(sb, body);
      case 'business_insights': return await businessInsights(sb, admin, body, u.user.id);
      case 'read_cac_document': return await readCacDocument(sb, admin, body, u.user.id);
      case 'read_nin_slip': return await readNinSlip(sb, admin, body, u.user.id);
      case 'read_product': return await readProduct(sb, admin, body, u.user.id);
      case 'read_supplier_invoice': return await readSupplierUpload(sb, admin, body, u.user.id);
      default: return json({ ok: false, error: 'Unknown action.' }, 400);
    }
  } catch (e) {
    // A problem with Google's credential is TaxStreem's to fix: the admin portal's connection check shows it in full.
    if (e instanceof CredentialError) {
      console.error('gemini credential', (e as Error).message);
      return json({ ok: false, reason: 'not_configured', error: 'AI reading is not available just now. TaxStreem has been told; type the details in for now.' }, 503);
    }
    return json({ ok: false, reason: 'error', error: (e as Error).message }, 500);
  }
});
