// A business's records in one zip, for the firm that ran it under full mandate (practice_export_begin decides who may):
//   tables/<table>.json   every exported table's rows for the business (its own orgs row too), secrets redacted by the
//                         database (svc_export_rows, page by page)
//   ledger.csv            the ledger line by line in date order (svc_export_ledger)
//   activity_log.json     the activity log, oldest first (svc_export_activity)
//   files/<path>          every stored file in the documents bucket under <org id>/, except the kyc/ folder (CAC documents
//                         and NIN slips stay with the owner and never leave)
// Stored write-once at practice/<practice>/exports/<client>/<yyyyMMdd-HHmmss>.zip (Lagos time) and logged (svc_export_done).
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { zipSync, type Zippable } from 'npm:fflate@0.8.3';
import { exportable, sha256Hex, UserError } from './util.ts';

const BUCKET = 'documents';
const PAGE = 1000;
// The stored files are read into memory to be zipped: past this, the export is refused with a plain answer rather than
// running the function out of memory.
export const MAX_FILE_BYTES = 100 * 1024 * 1024;

type Begin = { org_id: string; client_id: string; practice_id: string; tables: string[] };
type Page = { rows: unknown[]; next: string | null };

// Every row of a paged export call ({rows, next}), following next until the last page.
async function allPages(admin: SupabaseClient, fn: string, args: Record<string, unknown>): Promise<unknown[]> {
  const rows: unknown[] = [];
  let after: string | null = null;
  for (;;) {
    const { data, error } = await admin.rpc(fn, { ...args, p_after: after, p_limit: PAGE });
    if (error) throw new Error(`${fn}: ${error.message}`);
    const page = data as Page;
    if (!page || !Array.isArray(page.rows)) throw new Error(`${fn}: no rows`);
    rows.push(...page.rows);
    if (!page.next) return rows;
    if (page.next === after) throw new Error(`${fn}: the next page is the same page`);
    after = page.next;
  }
}

const LEDGER_COLUMNS = ['date', 'journal_ref', 'account_code', 'account_name', 'debit', 'credit', 'memo'];
// One CSV cell: quoted when it holds a comma, quote or line break; text a spreadsheet would run as a formula starts with '.
function cell(v: unknown): string {
  if (v === null || v === undefined) return '';
  let s = typeof v === 'object' ? JSON.stringify(v) : String(v);
  if (typeof v === 'string' && /^[=+@\t\r]|^-(?!\d)/.test(s)) s = "'" + s;
  return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}
export function ledgerCsv(rows: unknown[]): string {
  const lines = [LEDGER_COLUMNS.join(',')];
  for (const r of rows as Record<string, unknown>[]) lines.push(LEDGER_COLUMNS.map((k) => cell(r?.[k])).join(','));
  return lines.join('\r\n') + '\r\n';
}

type Listed = { name: string; id: string | null; metadata?: { size?: number } | null };

// The business's stored files: every object under <org id>/ (folders walked), the kyc/ folder never opened.
async function storedFiles(admin: SupabaseClient, orgId: string): Promise<{ path: string; size: number }[]> {
  const out: { path: string; size: number }[] = [];
  const walk = async (prefix: string, depth: number): Promise<void> => {
    if (depth > 12) throw new Error(`Folders nested too deep under ${prefix}`);
    for (let offset = 0; ; offset += PAGE) {
      const { data, error } = await admin.storage.from(BUCKET).list(prefix, { limit: PAGE, offset, sortBy: { column: 'name', order: 'asc' } });
      if (error) throw new Error(`Listing ${prefix}: ${error.message}`);
      const items = (data || []) as Listed[];
      for (const it of items) {
        if (!it?.name || it.name === '.emptyFolderPlaceholder') continue;
        const path = `${prefix}/${it.name}`;
        if (it.id === null) {
          if (depth === 0 && it.name.toLowerCase() === 'kyc') continue;
          await walk(path, depth + 1);
        } else if (exportable(path, orgId)) {
          out.push({ path, size: Number(it.metadata?.size) || 0 });
        }
      }
      if (items.length < PAGE) return;
    }
  };
  await walk(orgId, 0);
  return out;
}

// The time an export was made, as its file name: yyyyMMdd-HHmmss in Lagos (UTC+1).
export function exportStamp(d: Date): string {
  const t = new Date(d.getTime() + 3600_000).toISOString();
  return `${t.slice(0, 4)}${t.slice(5, 7)}${t.slice(8, 10)}-${t.slice(11, 13)}${t.slice(14, 16)}${t.slice(17, 19)}`;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function buildExport(admin: SupabaseClient, b: Begin, now: Date = new Date()): Promise<{ path: string; sha256: string; bytes: number }> {
  if (![b?.org_id, b?.client_id, b?.practice_id].every((x) => typeof x === 'string' && UUID.test(x)) || !Array.isArray(b.tables)) {
    throw new Error('The export was not started properly.');
  }
  const enc = new TextEncoder();
  const zip: Zippable = {};

  for (const table of b.tables) {
    if (typeof table !== 'string' || !/^[a-z_][a-z0-9_]*$/.test(table)) throw new Error(`Not a table name: ${String(table)}`);
    const rows = await allPages(admin, 'svc_export_rows', { p_org: b.org_id, p_table: table });
    zip[`tables/${table}.json`] = enc.encode(JSON.stringify(rows, null, 1));
  }
  zip['ledger.csv'] = enc.encode(ledgerCsv(await allPages(admin, 'svc_export_ledger', { p_org: b.org_id })));
  zip['activity_log.json'] = enc.encode(JSON.stringify(await allPages(admin, 'svc_export_activity', { p_org: b.org_id }), null, 1));

  const files = await storedFiles(admin, b.org_id);
  const total = files.reduce((s, f) => s + f.size, 0);
  if (total > MAX_FILE_BYTES) {
    throw new UserError(`The business's stored files come to ${Math.ceil(total / 1048576)} MB, more than an export can hold (100 MB). Ask TaxStreem for a full copy.`);
  }
  for (const f of files) {
    const { data, error } = await admin.storage.from(BUCKET).download(f.path);
    if (error || !data) throw new Error(`Reading ${f.path}: ${error?.message || 'no data'}`);
    // Stored files are mostly PDFs and images already compressed: kept as they are.
    zip[`files/${f.path}`] = [new Uint8Array(await data.arrayBuffer()), { level: 0 }];
  }

  const out = zipSync(zip, { level: 6 });
  const path = `practice/${b.practice_id}/exports/${b.client_id}/${exportStamp(now)}.zip`;
  const { error: upErr } = await admin.storage.from(BUCKET).upload(path, out, { contentType: 'application/zip', upsert: false });
  if (upErr) throw new UserError(/exist|duplicate/i.test(upErr.message) ? 'An export was made this very second. Try again in a moment.' : `The export could not be stored: ${upErr.message}`);
  const sha256 = await sha256Hex(out);
  const { error: doneErr } = await admin.rpc('svc_export_done', { p_client: b.client_id, p: { path, sha256, bytes: out.length } });
  if (doneErr) {
    // An export that is not in the business's activity log is not left where the firm's partners can read it.
    await admin.storage.from(BUCKET).remove([path]).catch(() => null);
    throw new Error(`svc_export_done: ${doneErr.message}`);
  }
  return { path, sha256, bytes: out.length };
}
