// Counta practice: engagement letters signed and e-signed, a director's confirmation of the wallets, a client's records
// exported, and the end of a full mandate. POST JSON {action, ...} -> {ok: true, ...} or {ok: false, error} (with reason
// when the database gave one). The actions are in actions.ts.
//
// Signed-in callers (Authorization: Bearer <user JWT>; the database checks each as the person):
//   letter_freeze { letter_id, signature_name? }  -> a partner signs a draft for the firm: practice_letter_prepare, the
//                                                    blocks numbered and merged (_shared/letter.ts) into a PDF stored
//                                                    write-once at practice/<pid>/letters/<lid>/letter.pdf (a PDF letter's
//                                                    own file as it stands), its SHA-256, then svc_letter_frozen. {letter}
//   export { client_id }                          -> a partner exports a full-mandate client's records (practice_export_begin,
//                                                    export.ts): {url} for 10 minutes, sha256, bytes
//   end_mandate { client_id, reason }             -> practice_end_mandate, then the business's bank feeds unlinked at Mono
//                                                    (the database only unlinks them in Counta, keeping former_feed).
//                                                    {client_id, org_id, read_only_at, retain_until, feeds: {unlinked, failed}}
//   unlink_feeds { client_id }                    -> those Mono unlinks tried again. {feeds}
// Public (the client's signer on /sign, a director on /confirm and /approve; no account, the link's token):
//   sign_open { token }                           -> svc_sign_open and a 5-minute link to the letter (doc_url)
//   sign_code { token }                           -> a code emailed to the signer (svc_sign_code)
//   sign_submit { token, code, typed_name, signature_png } -> the code checked, the stored letter re-hashed and refused
//                                                    if it changed since the firm signed, a signature page and completion
//                                                    certificate added (pdf.ts), stored write-once as signature-<signer>.png
//                                                    and final.pdf, svc_sign_complete. {status, doc_url}
//   director_open { token }                       -> svc_director_open: who asks, for which business, and the step (nin, code, slip)
//   director_nin { token, nin }                   -> svc_director_nin_begin (three a day), the NIN looked up at Mono and the
//                                                    directors' contacts read from the CAC record (_shared/mono_lookup.ts),
//                                                    then svc_director_identity: the code to the NIN's phone and the CAC email
//   director_slip { token, file }                 -> with nothing to send a code to, the NIN slip (a PDF or picture data URL,
//                                                    5 MB at most) stored write-once where svc_director_slip_target says, then
//                                                    svc_director_slip: TaxStreem checks it
//   director_code { token }, director_confirm { token, code }, director_decline { token, reason }
//                                                 -> svc_director_code (the code again), _confirm, _decline
//   approval_open { token }                       -> svc_approval_open: what waits for the director of a full-mandate client
//                                                    (/approve), and whether a code has been confirmed
//   approval_code { token }, approval_verify { token, code }
//                                                 -> svc_approval_code (a code to the director's phone and email), _verify
//                                                    (a right code lets them decide for 15 minutes)
//   approval_decide { token, ids, approve, note } -> svc_approval_decide: approved, each is carried out as the person who
//                                                    asked; rejecting takes a reason
// Public actions check the token's form first and send the caller's IP address and browser with every call; tokens are
// never logged; answers carry Referrer-Policy: no-referrer.
//
// Secrets: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY; MONO_SECRET_KEY, and MONO_LOOKUP_SECRET_KEY when the
// lookups sit on another Mono app (Vault first, as the mono function reads them). MONO_BASE_URL is for tests.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { handle } from './actions.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const MONO = (Deno.env.get('MONO_BASE_URL') || 'https://api.withmono.com').replace(/\/$/, '');
const admin = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false } });

const secrets = new Map<string, { v: string; at: number }>();
// Keys set in the admin portal (Supabase Vault) come first; the Edge Function secrets are the fallback.
async function secret(name: string): Promise<string> {
  const hit = secrets.get(name);
  if (hit && Date.now() - hit.at < 60_000) return hit.v;
  const { data } = await admin.rpc('app_secret', { p_name: name });
  const v = (typeof data === 'string' ? data.trim() : '') || (Deno.env.get(name) || '').trim();
  secrets.set(name, { v, at: Date.now() });
  return v;
}

Deno.serve((req) => handle(req, {
  admin,
  asUser: (authorization) => createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false } }),
  secret,
  monoUrl: MONO,
}));
