// The person's tax station (from their e-Tax profile) matched to e-Tax's list of agencies for bills, whose names are
// spelt their own way ("Lekki II Tax Stattion").
const ROMAN: Record<string, string> = { i: '1', ii: '2', iii: '3', iv: '4', v: '5', vi: '6', vii: '7', viii: '8', ix: '9', x: '10' };
const NOISE = new Set(['tax', 'taxes', 'station', 'stattion', 'statation', 'stn', 'office', 'lirs', 'the', 'of', 'and', 'lagos', 'state', 'internal', 'revenue', 'service']);

export function tokens(s: string): string[] {
  return String(s || '').toLowerCase().replace(/\./g, '').replace(/&/g, ' and ').replace(/[^a-z0-9]+/g, ' ').trim().split(/\s+/)
    .filter(Boolean).map((t) => ROMAN[t] || t).filter((t) => !NOISE.has(t));
}

export type Agency = { FullName?: string; AgencyRef?: string; orcAgency2?: string | number; HeadRef?: string | number; [k: string]: unknown };

// The agency for an office name: an exact match of the meaningful words, or the one clearly closest (at least two
// thirds of the words shared, and nothing else as close).
export function matchAgency(office: string, agencies: Agency[]): Agency | null {
  const want = tokens(office);
  if (!want.length) return null;
  const key = want.join(' ');
  const exact = agencies.filter((a) => tokens(String(a.FullName || '')).join(' ') === key);
  if (exact.length === 1) return exact[0];
  let best: Agency | null = null, bestScore = 0, tie = false;
  for (const a of agencies) {
    const have = tokens(String(a.FullName || ''));
    if (!have.length) continue;
    const A = new Set(want), B = new Set(have);
    const shared = [...A].filter((t) => B.has(t)).length;
    const score = shared / Math.max(A.size, B.size);
    // A number in the name must agree (Lekki 1 is not Lekki 2).
    const nums = (x: Set<string>) => [...x].filter((t) => /^\d+$/.test(t)).sort().join(',');
    if (nums(A) !== nums(B)) continue;
    if (score > bestScore + 1e-9) { best = a; bestScore = score; tie = false; } else if (Math.abs(score - bestScore) < 1e-9) tie = true;
  }
  return best && !tie && bestScore >= 0.66 ? best : null;
}
