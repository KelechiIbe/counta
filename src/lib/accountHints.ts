// Plain words for the chart of accounts: what each common account is for, and the everyday words people search with.
// The books inbox uses them to explain Atlas's short list and to find an account by what the money was for ("diesel",
// "salary", "rent") rather than by its accounting name.

export type ChartAccount = { code: string; name: string; is_group?: boolean; active?: boolean; is_system?: boolean; kind?: string; own?: boolean; category?: string };

// code: [what it is for, extra search words]
const HINTS: Record<string, [string, string]> = {
  '1011': ['Cash kept in the office or shop', 'petty cash till drawer'],
  '1012': ['Money moved to another of your bank accounts', 'transfer own account bank'],
  '1014': ['Money moved to a wallet such as Opay, Moniepoint or Paystack', 'wallet opay moniepoint palmpay paystack flutterwave'],
  '1104': ['Money lent or advanced to a staff member, to be paid back', 'staff loan salary advance'],
  '1105': ['Money a director took and owes back to the business', 'director owner took loan'],
  '1106': ['Paid a supplier before the goods or service arrived', 'deposit supplier advance prepayment'],
  '1110': ['Money someone owes the business that is not a sale', 'owed refund due'],
  '1101': ['A customer paying what they owe on credit', 'customer debtor invoice paid'],
  '1301': ['Rent paid in advance for months to come', 'rent advance yearly'],
  '1302': ['Insurance paid in advance', 'insurance premium advance'],
  '1303': ['Paid in advance for something used over later months', 'advance prepaid subscription'],
  '1403': ['Company income tax paid in advance', 'tax instalment cit'],
  '1511': ['Buying a car, van, bus or motorbike for the business', 'car vehicle van bus truck motorbike keke'],
  '1513': ['Buying tools and machines that last years', 'tools machine equipment generator'],
  '1514': ['Buying office equipment that lasts years', 'printer photocopier air conditioner ac fridge'],
  '1517': ['Buying computers, laptops and phones that last years', 'laptop computer phone ipad tablet server'],
  '1519': ['Buying furniture and fittings', 'chairs tables desk shelves furniture'],
  '1526': ['Building work on a rented shop or office', 'renovation partition tiling fitout'],
  '1607': ['Software or an app built or bought for the business', 'app software development website build'],
  '2101': ['Paying a supplier you bought from on credit', 'supplier creditor bill paid'],
  '2103': ['Paying a cost that was owed from an earlier month', 'accrued owed expense'],
  '2104': ['Money the business owes someone that is not a supplier bill', 'owed payable'],
  '2106': ['A director putting money in as a loan, or being paid back', 'director loan owner put money repay'],
  '2107': ['A customer paying before you deliver or invoice', 'deposit advance customer prepayment'],
  '2109': ['Money you must give back to a customer', 'refund customer'],
  '2203': ['PAYE paid to the tax office for staff', 'paye tax staff lirs'],
  '2204': ['Pension paid to the pension administrator', 'pension pfa'],
  '2208': ['Company income tax paid', 'cit income tax firs nrs'],
  '2301': ['Overdraft from the bank', 'overdraft od'],
  '2302': ['A loan due within a year: money in when taken, out when repaid', 'loan borrow repay short'],
  '2305': ['Interest owed on a loan', 'interest loan'],
  '2501': ['A bank loan over a year: money in when taken, out when repaid', 'bank loan term borrow repay'],
  '2502': ['A loan from a shareholder or someone close to the business', 'shareholder loan family friend'],
  '2505': ['Deposits customers leave with the business', 'deposit caution refundable'],
  '3001': ['The owner putting money in for shares', 'capital shares owner investment'],
  '3004': ['Money in for shares not yet issued', 'deposit for shares investment'],
  '3005': ['Profit taken out by the owner (a business name) or dividends', 'drawings owner took profit dividend'],
  '4107': ['Selling goods', 'sales goods shop customer'],
  '4106': ['Income from construction work', 'construction contract job'],
  '4108': ['Income from transport, delivery or haulage', 'delivery transport haulage logistics'],
  '4109': ['Income from food, drinks or rooms', 'restaurant food hotel rooms'],
  '4110': ['Income from tech, media or communication services', 'tech software media'],
  '4113': ['Income from property', 'rent property real estate'],
  '4115': ['Income from support and admin services', 'service fee admin support'],
  '4116': ['School or training fees', 'school fees tuition training'],
  '4117': ['Income from oil and gas work', 'oil gas'],
  '4121': ['Income from services not listed elsewhere', 'service fee income'],
  '4501': ['Commission earned', 'commission agent'],
  '4502': ['Interest the bank or a borrower paid you', 'interest earned savings'],
  '4504': ['Rent you received', 'rent received tenant'],
  '4508': ['Selling an old asset for more than it was worth in the books', 'sold asset disposal'],
  '4510': ['Gain from exchanging dollars or other currency', 'fx exchange dollar gain'],
  '4512': ['A debt you had written off that was paid after all', 'bad debt recovered'],
  '4514': ['An insurance claim paid to you', 'insurance claim'],
  '4516': ['Small income that fits nowhere else', 'sundry other income misc'],
  '5101': ['Buying goods to sell, here in Nigeria', 'stock goods purchase buy supplier market'],
  '5102': ['Buying goods to sell from abroad', 'import stock purchase'],
  '5104': ['Transport and clearing to bring stock in', 'carriage clearing haulage inward'],
  '5105': ['Customs duty on imported stock', 'duty customs import'],
  '5201': ['Wages of people who make the product or do the job', 'labour wages workers production'],
  '5202': ['Materials used to make the product or do the job', 'materials inputs'],
  '5203': ['Paying a subcontractor to do part of a job', 'subcontractor contractor job'],
  '5303': ['Fuel and power for the factory', 'factory diesel power'],
  '6101': ['Salaries and wages of staff', 'salary wages staff pay payroll'],
  '6102': ['Staff allowances such as transport or lunch', 'allowance transport lunch staff'],
  '6104': ['The business\'s share of staff pension', 'pension employer'],
  '6106': ['Medical bills for staff', 'hospital medical hmo staff'],
  '6107': ['Training and courses for staff', 'training course workshop'],
  '6108': ['Staff welfare such as meals and gifts', 'welfare staff party food'],
  '6109': ['Directors\' pay', 'director salary pay'],
  '6110': ['Directors\' expenses', 'director expenses'],
  '6112': ['Casual workers and contractors paid for their time', 'casual labour contract staff freelancer'],
  '6113': ['Hiring costs such as job adverts', 'recruitment hiring'],
  '6201': ['Rent for the office or shop', 'rent shop office landlord'],
  '6202': ['Tenement rates and local council charges on property', 'rates tenement council'],
  '6203': ['Estate or building service charge', 'service charge estate'],
  '6204': ['Water bills', 'water'],
  '6205': ['Electricity bills and prepaid meter units', 'nepa phcn ekedc ikedc electricity light meter units'],
  '6206': ['Diesel for the generator or vehicles', 'diesel ago generator fuel'],
  '6207': ['Petrol', 'petrol pms fuel'],
  '6208': ['Generator repairs and servicing', 'generator gen repair service'],
  '6209': ['Repairs and maintenance', 'repair fix maintenance plumber electrician'],
  '6210': ['Cleaning', 'cleaning cleaner janitor'],
  '6211': ['Security guards and services', 'security guard'],
  '6212': ['Stationery and printing', 'stationery printing paper'],
  '6213': ['Courier and postage', 'courier dispatch postage gig dhl'],
  '6215': ['Business insurance', 'insurance'],
  '6216': ['Office consumables', 'consumables supplies office'],
  '6301': ['Phone and airtime', 'airtime recharge phone mtn glo airtel 9mobile'],
  '6302': ['Internet and data', 'data internet wifi router spectranet'],
  '6303': ['Software subscriptions', 'subscription software google microsoft zoom canva'],
  '6304': ['Website costs', 'website domain hosting'],
  '6305': ['IT support and computer repairs', 'it support computer repair'],
  '6401': ['Adverts and promotions', 'adverts ads facebook instagram google marketing promotion'],
  '6403': ['Public relations', 'pr publicity'],
  '6405': ['Trade fairs and exhibitions', 'exhibition trade fair stand'],
  '6407': ['Costs of selling and distributing goods', 'distribution selling'],
  '6409': ['Entertaining customers', 'entertainment client lunch'],
  '6410': ['Gifts to customers or partners', 'gifts hamper'],
  '6501': ['Audit fees', 'audit auditor'],
  '6502': ['Accountant and bookkeeping fees', 'accountant bookkeeping'],
  '6503': ['Lawyers\' fees', 'legal lawyer solicitor'],
  '6504': ['Consultants\' fees', 'consultant consultancy'],
  '6506': ['CAC filings and company secretary', 'cac filing secretary annual returns'],
  '6507': ['Other professional fees', 'professional fees'],
  '6508': ['Government charges and regulators', 'government regulator agency'],
  '6509': ['Licences and permits', 'licence permit'],
  '6510': ['Memberships and dues', 'membership dues association'],
  '6512': ['Levies and statutory charges', 'levy statutory charge ncd'],
  '6513': ['Fines', 'fine'],
  '6514': ['Penalties', 'penalty late filing'],
  '6601': ['Local transport and logistics', 'transport uber bolt taxi bus logistics delivery dispatch'],
  '6602': ['Travel within Nigeria', 'travel flight trip local'],
  '6603': ['Travel abroad', 'travel international flight visa'],
  '6604': ['Hotels', 'hotel accommodation'],
  '6605': ['Running vehicles: fuel, servicing, papers', 'vehicle car fuel servicing particulars'],
  '6606': ['Freight and moving goods', 'freight haulage moving goods'],
  '6701': ['Bank charges', 'bank charges sms alert stamp duty card maintenance transfer fee'],
  '6702': ['Interest paid on a loan or overdraft', 'interest loan overdraft'],
  '6703': ['Loss from exchanging dollars or other currency', 'fx exchange dollar loss'],
  '6801': ['A customer debt you will not collect', 'bad debt write off'],
  '6904': ['Donations', 'donation charity church mosque'],
  '6907': ['Small costs that fit nowhere else', 'sundry misc other'],
  '7101': ['Loan fees', 'loan fee arrangement'],
  '7105': ['Other finance costs', 'finance cost'],
};

// Accounts a bank line never goes to: tax and control accounts kept by Counta itself, suspense and clearing, the system
// accounts, and the contra accounts that only depreciation and provisions write to.
const NEVER = /^(2201|1402|2202|1401|9|1103|1207|155|156|157|1609|1654|3999|5400|5401)/;

export const accountHint = (code: string): string => HINTS[code]?.[0] || HINTS[code.split('-')[0]]?.[0] || '';

export function forBankLine(accounts: ChartAccount[]): ChartAccount[] {
  return accounts.filter((a) => !a.is_group && a.active !== false && !a.is_system && !NEVER.test(a.code));
}

const words = (s: string) => s.toLowerCase().normalize('NFKD').replace(/[^a-z0-9 ]+/g, ' ').split(/\s+/).filter(Boolean);

// Finds accounts by code, name, what they are for, or everyday words. Best first.
export function searchAccounts(accounts: ChartAccount[], query: string, limit = 8): ChartAccount[] {
  const q = words(query);
  if (!q.length) return [];
  const scored: { a: ChartAccount; s: number }[] = [];
  for (const a of accounts) {
    const name = words(a.name);
    const extra = words(`${HINTS[a.code]?.[0] || ''} ${HINTS[a.code]?.[1] || ''} ${HINTS[a.code.split('-')[0]]?.[1] || ''}`);
    let s = 0;
    for (const w of q) {
      let best = 0;
      if (a.code.startsWith(w)) best = 6;
      for (const n of name) { if (n === w) best = Math.max(best, 5); else if (n.startsWith(w) && w.length >= 2) best = Math.max(best, 4); }
      for (const n of extra) { if (n === w) best = Math.max(best, 4); else if (n.startsWith(w) && w.length >= 3) best = Math.max(best, 3); }
      if (!best) { s = 0; break; }
      s += best;
    }
    if (s > 0) scored.push({ a, s: s + (HINTS[a.code] ? 0.5 : 0) });
  }
  return scored.sort((x, y) => y.s - x.s || x.a.code.localeCompare(y.a.code)).slice(0, limit).map((x) => x.a);
}

// When Atlas gave fewer than five accounts (or none): accounts the narration names, then the usual ones for money in or out.
const USUAL_IN = ['2107', '2106', '3001', '2302', '4516', '1110'];
const USUAL_OUT = ['5101', '6101', '6112', '6601', '6701', '3005', '6209', '6907'];
export function fillShortList(accounts: ChartAccount[], have: string[], narration: string, moneyIn: boolean, size = 5): string[] {
  const out = [...have];
  const known = new Set(accounts.map((a) => a.code));
  const add = (c: string) => { if (out.length < size && known.has(c) && !out.includes(c)) out.push(c); };
  for (const w of words(narration).filter((w) => w.length >= 4 && !/^(transfer|trf|from|payment|nip|via|with|ltd|limited|nigeria|enterprises)$/.test(w))) {
    for (const a of searchAccounts(accounts, w, 2)) {
      // Money in to an expense, or money out to income, is never offered from words alone.
      if (moneyIn ? /^[567]/.test(a.code) : /^4/.test(a.code)) continue;
      add(a.code);
    }
  }
  for (const c of moneyIn ? USUAL_IN : USUAL_OUT) add(c);
  return out;
}
