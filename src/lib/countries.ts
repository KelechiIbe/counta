// ISO 3166-1 alpha-2 codes. Names come from the browser so they read naturally; Nigeria is listed first.
const CODES = ('AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ '
  + 'DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP '
  + 'KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ '
  + 'OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ '
  + 'UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW').split(' ');

let names: Intl.DisplayNames | null = null;
try { names = new Intl.DisplayNames(['en'], { type: 'region' }); } catch { names = null; }

export function countryName(code?: string | null): string {
  const c = String(code || 'NG').toUpperCase();
  if (c === 'NG') return 'Nigeria';
  try { return names?.of(c) || c; } catch { return c; }
}

export const COUNTRIES: { code: string; name: string }[] = [
  { code: 'NG', name: 'Nigeria' },
  ...CODES.filter((c) => c !== 'NG').map((code) => ({ code, name: countryName(code) })).sort((a, b) => a.name.localeCompare(b.name)),
];

export const NG_STATES = ['Abia', 'Adamawa', 'Akwa Ibom', 'Anambra', 'Bauchi', 'Bayelsa', 'Benue', 'Borno', 'Cross River', 'Delta', 'Ebonyi', 'Edo', 'Ekiti', 'Enugu',
  'FCT Abuja', 'Gombe', 'Imo', 'Jigawa', 'Kaduna', 'Kano', 'Katsina', 'Kebbi', 'Kogi', 'Kwara', 'Lagos', 'Nasarawa', 'Niger', 'Ogun', 'Ondo', 'Osun', 'Oyo', 'Plateau',
  'Rivers', 'Sokoto', 'Taraba', 'Yobe', 'Zamfara'];

export const isExport = (country?: string | null) => !!country && country.toUpperCase() !== 'NG';

// One line for an address block: street, city, state, and the country when it is not Nigeria.
export function addressLines(c: { address?: string | null; city?: string | null; state?: string | null; country?: string | null }): string[] {
  const out = String(c.address || '').split(/\n+/).map((x) => x.trim()).filter(Boolean);
  const place = [c.city, c.state].filter(Boolean).join(', ');
  if (place && !out.some((l) => l.toLowerCase().includes(place.toLowerCase()))) out.push(place);
  if (isExport(c.country)) out.push(countryName(c.country));
  return out;
}
