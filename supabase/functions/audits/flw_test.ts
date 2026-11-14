import { assertEquals, assertThrows } from 'jsr:@std/assert@1';
import { type ChargeCtx, checkoutBody, ngPhone, readVerify, type SubCtx, subaccountBody, subaccountPlan } from './flw.ts';

const sub: SubCtx = {
  practice: { id: 'p1', name: 'Okafor Audit & Co', email: 'audit@okafor.example.test', phone: '+234 803 555 0142' },
  bank: { bank_code: '058', account_number: '0011223344', account_name: 'OKAFOR AUDIT AND CO', name_match: true },
  subaccount: { status: 'none' },
  referral_rate: 0.1,
};

Deno.test('phones_as_flutterwave_takes_them', () => {
  assertEquals(ngPhone('+234 803 555 0142'), '08035550142');
  assertEquals(ngPhone('0803-555-0142'), '08035550142');
  assertEquals(ngPhone('12345'), undefined);
  assertEquals(ngPhone(null), undefined);
});

Deno.test('subaccount_body', () => {
  assertEquals(subaccountBody(sub, {}), {
    account_bank: '058', account_number: '0011223344', business_name: 'Okafor Audit & Co', business_email: 'audit@okafor.example.test',
    business_mobile: '08035550142', business_contact: 'OKAFOR AUDIT AND CO', business_contact_mobile: '08035550142',
    country: 'NG', split_type: 'percentage', split_value: 0.1,
  });
  // The partner's own email and phone when the practice has none.
  const bare = { ...sub, practice: { id: 'p1', name: 'Okafor Audit & Co', email: null, phone: null } };
  const b = subaccountBody(bare, { email: 'bisi@okafor.example.test', phone: '08030000001' });
  assertEquals([b.business_email, b.business_mobile], ['bisi@okafor.example.test', '08030000001']);
  assertThrows(() => subaccountBody(bare, { email: 'bisi@okafor.example.test' }), Error, 'phone number');
  assertThrows(() => subaccountBody(bare, { phone: '08030000001' }), Error, 'email address');
});

Deno.test('subaccount_plan', () => {
  assertEquals(subaccountPlan(sub), 'create');
  const made = { ...sub, subaccount: { ref: 'RS_1', num: 2181, bank: '058', account: '0011223344', status: 'ready' } };
  assertEquals(subaccountPlan(made), 'keep');
  assertEquals(subaccountPlan({ ...made, bank: { ...sub.bank, account_number: '0099887766' } }), 'update');
  assertEquals(subaccountPlan({ ...made, subaccount: { ...made.subaccount, status: 'failed' } }), 'update');
});

const charge: ChargeCtx = {
  charge: { tx_ref: 'AUD-0123456789ABCDEF', amount: '5125000.00', referral: '500000.00', subaccount_ref: 'RS_OKAFOR', status: 'pending' },
  engagement: { id: 'e1', year: 2025 },
  org: { id: '52279150-c4a8-4fdd-ba92-c5804b302439', name: 'Ada Industries Ltd', email: null, phone: '0803 000 0002' },
  firm: { id: 'p1', name: 'Okafor Audit & Co' },
  description: 'Audit of the 2025 accounts by Okafor Audit & Co',
  return_path: '/tax/cit',
};

Deno.test('checkout_splits_the_referral_off', () => {
  assertEquals(checkoutBody(charge, 'https://counta.example.test/'), {
    tx_ref: 'AUD-0123456789ABCDEF', amount: 5125000, currency: 'NGN',
    redirect_url: 'https://counta.example.test/tax/cit?audit_ref=AUD-0123456789ABCDEF',
    customer: { email: 'billing+52279150@counta.ng', name: 'Ada Industries Ltd', phonenumber: '08030000002' },
    customizations: { title: 'Counta', description: 'Audit of the 2025 accounts by Okafor Audit & Co' },
    payment_options: 'card, banktransfer, ussd',
    subaccounts: [{ id: 'RS_OKAFOR', transaction_charge_type: 'flat', transaction_charge: 500000 }],
    meta: { kind: 'audit', engagement_id: 'e1', org_id: '52279150-c4a8-4fdd-ba92-c5804b302439' },
  });
  // A return path that is not a plain app path goes to the Filing page.
  assertEquals(checkoutBody({ ...charge, return_path: 'https://evil.example.test' }, 'https://counta.example.test').redirect_url,
    'https://counta.example.test/filing?audit_ref=AUD-0123456789ABCDEF');
});

Deno.test('verify_reads_flutterwave', () => {
  const ref = 'AUD-0123456789ABCDEF';
  assertEquals(readVerify({ tx_ref: ref, status: 'successful', amount: 5125000, currency: 'NGN', app_fee: 2000, id: 998877 }, ref, 5125000),
    { status: 'successful', paid_amount: 5125000, fee: 2000, provider_ref: '998877' });
  assertEquals(readVerify({ tx_ref: ref, status: 'successful', amount: 5000, currency: 'NGN', id: 1 }, ref, 5125000),
    { status: 'failed', error: 'Flutterwave confirmed ₦5000.00, less than the ₦5125000.00 due.', provider_ref: '1' });
  assertEquals(readVerify({ tx_ref: ref, status: 'successful', amount: 5125000, currency: 'USD', id: 1 }, ref, 5125000).status, 'failed');
  assertEquals(readVerify({ tx_ref: ref, status: 'failed', processor_response: 'Insufficient funds', id: 2 }, ref, 5125000),
    { status: 'failed', error: 'Insufficient funds', provider_ref: '2' });
  assertEquals(readVerify({ tx_ref: 'AUD-OTHER', status: 'successful', amount: 5125000 }, ref, 5125000), { status: 'pending' });
  assertEquals(readVerify({ tx_ref: ref, status: 'pending' }, ref, 5125000), { status: 'pending' });
  assertEquals(readVerify(null, ref, 5125000), { status: 'pending' });
});
