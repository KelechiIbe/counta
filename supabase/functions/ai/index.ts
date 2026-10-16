// Counta AI: Gemini-backed invoice reading, Martina answers and voice capture.
// Needs GEMINI_API_KEY, either as an Edge Function secret or in Supabase Vault (read through
// public.app_secret). GEMINI_MODEL is optional (defaults to gemini-3.8-flash).
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { encodeBase64 } from 'jsr:@std/encoding@1/base64';

let GEMINI_KEY = Deno.env.get('GEMINI_API_KEY') || '';
let MODEL = Deno.env.get('GEMINI_MODEL') || 'gemini-3.8-flash';
const FALLBACK_MODELS = ['gemini-3.6-flash', 'gemini-3.5-flash', 'gemini-flash-latest'];
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

// Vault fallback for keys that are not set as Edge Function secrets. Cached per instance.
let vaultAt = 0;
async function loadKeys(admin: SupabaseClient) {
  if (GEMINI_KEY || Date.now() - vaultAt < 60_000) return;
  vaultAt = Date.now();
  const [{ data: key }, { data: model }] = await Promise.all([
    admin.rpc('app_secret', { p_name: 'GEMINI_API_KEY' }),
    admin.rpc('app_secret', { p_name: 'GEMINI_MODEL' }),
  ]);
  if (typeof key === 'string' && key) GEMINI_KEY = key.trim();
  if (typeof model === 'string' && model && !Deno.env.get('GEMINI_MODEL')) MODEL = model.trim();
}

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const NL = String.fromCharCode(10);
const NOT_CONFIGURED = { ok: false, reason: 'not_configured', error: 'AI reading is not switched on yet. Add GEMINI_API_KEY in Supabase Edge Function secrets.' };

type Part = { text: string } | { inlineData: { mimeType: string; data: string } };

async function gemini(system: string, parts: Part[], schema: unknown, temperature = 0.1): Promise<{ data: any; model: string }> {
  let lastErr = '';
  for (const model of [MODEL, ...FALLBACK_MODELS.filter((m) => m !== MODEL)]) {
    const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': GEMINI_KEY },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: system }] },
        contents: [{ role: 'user', parts }],
        generationConfig: { responseMimeType: 'application/json', responseSchema: schema, temperature },
      }),
    });
    if (res.status === 404 || res.status === 400 && (await res.clone().text()).includes('not found')) { lastErr = `${model} unavailable`; continue; }
    if (res.status === 429 || res.status >= 500) { lastErr = `${model} busy (${res.status})`; continue; }
    if (!res.ok) throw new Error(`Gemini ${res.status}: ${(await res.text()).slice(0, 300)}`);
    const body = await res.json();
    const text = body?.candidates?.[0]?.content?.parts?.map((p: any) => p.text || '').join('') || '';
    if (!text) throw new Error('Gemini returned no content' + (body?.promptFeedback?.blockReason ? ` (${body.promptFeedback.blockReason})` : ''));
    return { data: JSON.parse(text), model };
  }
  throw new Error(lastErr || 'No Gemini model available');
}

const S = {
  str: { type: 'STRING' }, num: { type: 'NUMBER' }, int: { type: 'INTEGER' }, bool: { type: 'BOOLEAN' },
  nstr: { type: 'STRING', nullable: true }, nnum: { type: 'NUMBER', nullable: true },
};

// ---------------------------------------------------------------- invoices
const INVOICE_SCHEMA = {
  type: 'OBJECT',
  properties: {
    vendor_id: S.nstr, vendor_name: S.nstr, invoice_no: S.nstr, invoice_date: { type: 'STRING', nullable: true, description: 'YYYY-MM-DD' },
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

async function readInvoice(sb: SupabaseClient, admin: SupabaseClient, body: any, memberId: string | null) {
  const { data: r, error } = await sb.from('receipts').select('*').eq('id', body.receipt_id).single();
  if (error || !r) return json({ ok: false, error: 'Receipt not found or not yours.' }, 404);
  if (!['reading', 'needs_review'].includes(r.status)) return json({ ok: false, error: 'This receipt is already ' + r.status }, 409);
  const fail = async (msg: string, reason = 'error') => {
    await sb.from('receipts').update({ status: 'needs_review', ai_error: msg }).eq('id', r.id);
    return json({ ok: false, reason, error: msg });
  };
  if (!GEMINI_KEY) return fail(NOT_CONFIGURED.error, 'not_configured');
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
- vendor: set vendor_id if the seller matches a known vendor, else vendor_name as printed. vat_charged = true when the invoice charges VAT or shows the seller's VAT/TIN registration with a VAT line. prices_include_vat = true only when unit prices clearly include VAT.
- Never invent lines or numbers that are not on the document.
ITEM MASTER: ${JSON.stringify(items)}
KNOWN VENDORS: ${JSON.stringify(vendors)}`;

  let out: any; let model = MODEL;
  try {
    const res = await gemini(system, [{ text: 'Read this invoice.' }, { inlineData: { mimeType: mime, data: encodeBase64(bytes) } }], INVOICE_SCHEMA);
    out = res.data; model = res.model;
  } catch (e) {
    return fail('Could not read the invoice: ' + (e as Error).message);
  }

  const known = new Map(items.map((i: any) => [i.id, i]));
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
    if (out.prices_include_vat && vatT === 'standard') cost = Math.round((cost / 1.075) * 100) / 100;
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
  if (!GEMINI_KEY) return json(NOT_CONFIGURED);
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
      [{ text: 'SNAPSHOT:' + NL + JSON.stringify(body.context).slice(0, 120000) + NL + NL + 'QUESTION: ' + String(body.question || '').slice(0, 500) }], schema, 0.2);
    return json({ ok: true, answer: data, model });
  } catch (e) {
    return json({ ok: false, reason: 'error', error: (e as Error).message });
  }
}

async function chat(body: any) {
  if (!GEMINI_KEY) return json(NOT_CONFIGURED);
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
      [{ text: 'SNAPSHOT:' + NL + JSON.stringify(body.context).slice(0, 100000) + NL + NL + 'CONVERSATION:' + NL + history }], schema, 0.3);
    return json({ ok: true, ...data, model });
  } catch (e) {
    return json({ ok: false, reason: 'error', error: (e as Error).message });
  }
}

// ---------------------------------------------------------------- voice
async function voice(body: any) {
  if (!GEMINI_KEY) return json(NOT_CONFIGURED);
  if (!body.audio_base64) return json({ ok: false, error: 'No audio received.' }, 400);
  if (body.audio_base64.length > 14_000_000) return json({ ok: false, error: 'That recording is too long. Keep it under a minute.' }, 413);
  const schema = {
    type: 'OBJECT',
    properties: {
      transcript: S.str, language: S.str,
      movement: { type: 'STRING', enum: ['sale', 'receipt', 'unknown'] },
      item_id: S.nstr, qty: S.nnum, unit_kind: { type: 'STRING', enum: ['purchase', 'selling'] }, location_name: S.nstr,
      confidence: S.int, readback: { type: 'STRING', description: 'One plain English sentence confirming what will be recorded, with naira value if known' },
      problem: { type: 'STRING', nullable: true, description: 'Why it cannot be recorded, if so' },
    },
    required: ['transcript', 'movement', 'confidence', 'readback'],
  };
  try {
    const { data, model } = await gemini(`You transcribe short voice notes from shop staff in Nigeria (Nigerian Pidgin, Yoruba, Hausa, Igbo or English) and turn them into one stock movement.
"I don sell three cartons of Indomie" means a SALE of 3 purchase units (cartons) of the matching Indomie item. "We collect 5 bag of rice" is a RECEIPT.
Match the item from ITEMS by meaning. qty is a number; unit_kind "purchase" for cartons/bags/bales/crates, "selling" for packs/tins/bottles/pieces.
If the location is mentioned, return its name exactly as in LOCATIONS. If anything essential is missing, set movement "unknown" and explain in problem.
ITEMS: ${JSON.stringify(body.items || []).slice(0, 60000)}
LOCATIONS: ${JSON.stringify(body.locations || [])}`,
      [{ text: 'Transcribe and interpret this voice note.' }, { inlineData: { mimeType: body.mime || 'audio/webm', data: body.audio_base64 } }], schema, 0.1);
    return json({ ok: true, ...data, model });
  } catch (e) {
    return json({ ok: false, reason: 'error', error: (e as Error).message });
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  const authHeader = req.headers.get('Authorization') || '';
  const sb = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } });
  const admin = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false } });
  const { data: u } = await sb.auth.getUser();
  if (!u?.user) return json({ ok: false, error: 'Sign in first.' }, 401);
  let body: any;
  try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid request.' }, 400); }
  try {
    await loadKeys(admin);
    switch (body.action) {
      case 'status': return json({ ok: true, configured: Boolean(GEMINI_KEY), model: MODEL });
      case 'read_invoice': {
        const { data: m } = await sb.from('members').select('id').eq('user_id', u.user.id).limit(1).maybeSingle();
        return await readInvoice(sb, admin, body, m?.id ?? null);
      }
      case 'ask': return await ask(body);
      case 'chat': return await chat(body);
      case 'voice': return await voice(body);
      default: return json({ ok: false, error: 'Unknown action.' }, 400);
    }
  } catch (e) {
    return json({ ok: false, reason: 'error', error: (e as Error).message }, 500);
  }
});
