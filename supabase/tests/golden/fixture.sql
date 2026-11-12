-- Golden fixture: an ordinary (non-managed) business, its team, a verified practice involved with it, and a few
-- documents. Loaded as postgres inside each case's transaction by golden/run.sh; every id is kept with tests.remember.
-- Fake names and @example.test addresses only.
do $$
declare v_id uuid; v_org uuid; v_practice uuid; v_client uuid; v_customer uuid; v_sale jsonb; v_bill jsonb;
begin
  perform tests.hooks_on();

  perform tests.remember('owner', tests.user('owner@example.test', 'Golden Owner'));
  perform tests.remember('admin', tests.user('admin@example.test', 'Golden Admin'));
  perform tests.remember('accountant', tests.user('accountant@example.test', 'Golden Accountant'));
  perform tests.remember('staff', tests.user('staff@example.test', 'Golden Staff'));
  perform tests.remember('partner', tests.user('partner@example.test', 'Golden Partner'));
  perform tests.remember('platform', tests.admin_user('platform@example.test'));

  -- The business and its team.
  v_org := tests.remember('org', tests.org(tests.id('owner'), 'Golden Foods Ltd'));
  update orgs set phone = '+2348030000001', tin = '12345678-0001', rc_number = 'RC 123456', address = '1 Test Street, Lagos'
  where id = v_org;
  update members set phone = '+2348030000001' where org_id = v_org and role = 'owner';
  perform tests.remember('m_owner', (select id from members where org_id = v_org and role = 'owner'));
  perform tests.remember('m_admin', tests.member(v_org, tests.id('admin'), 'admin'));
  perform tests.remember('m_accountant', tests.member(v_org, tests.id('accountant'), 'accountant'));
  perform tests.remember('m_staff', tests.member(v_org, tests.id('staff'), 'staff'));

  -- A verified practice involved with the business: the partner's seat comes from the seat sync.
  v_practice := tests.remember('practice', tests.practice(tests.id('partner'), 'Golden Partners', true));
  v_client := tests.remember('client', tests.involved_client(v_practice, v_org));
  perform tests.remember('m_partner', (select id from members where org_id = v_org and user_id = tests.id('partner')));

  -- Documents, entered by the owner.
  perform tests.as_user(tests.id('owner'));
  v_customer := tests.remember('customer', public.save_customer(v_org,
    '{"name": "Golden Customer Ltd", "email": "customer@example.test", "phone": "08030000002", "kind": "business"}'));
  v_sale := public.save_sale_doc(v_org, jsonb_build_object('customer_id', v_customer,
    'lines', '[{"description": "Catering, draft", "qty": 1, "unit_price": 10000, "vat_treatment": "standard"}]'::jsonb));
  perform tests.remember('invoice_draft', (v_sale->>'id')::uuid);
  v_sale := public.save_sale_doc(v_org, jsonb_build_object('customer_id', v_customer, 'status', 'issue',
    'lines', '[{"description": "Catering", "qty": 2, "unit_price": 25000, "vat_treatment": "standard"}]'::jsonb));
  perform tests.remember('invoice', (v_sale->>'id')::uuid);
  v_bill := public.save_bill(v_org, jsonb_build_object('status', 'approve',
    'vendor', '{"name": "Golden Supplier Ltd", "email": "supplier@example.test", "phone": "08030000003"}'::jsonb,
    'lines', '[{"description": "Flour", "account_code": "5101", "qty": 4, "unit_cost": 5000}]'::jsonb));
  perform tests.remember('bill', (v_bill->>'id')::uuid);
  perform tests.as_postgres();
  perform tests.remember('vendor', (select vendor_id from bills where id = tests.id('bill')));

  -- Wallets, opened the way the payments edge function opens them, and NGN 1,000,000 of share capital paid into the wallet.
  insert into wallets (org_id, rail, created_by) values (v_org, 'flutterwave', tests.id('m_owner')) returning id into v_id;
  perform tests.remember('wallet', v_id);
  perform public.svc_wallet_ready(v_id, '{"account_ref": "golden-wallet", "account_number": "0123456789", "bank_name": "Test Bank", "account_name": "Golden Foods Ltd"}');
  insert into tax_wallets (org_id, rail, created_by) values (v_org, 'flutterwave', tests.id('m_owner')) returning id into v_id;
  perform tests.remember('tax_wallet', v_id);
  perform public.svc_tax_wallet_ready(v_id, '{"account_ref": "golden-tax-wallet", "account_number": "0123456780", "bank_name": "Test Bank", "account_name": "Golden Foods Ltd Tax"}');
  perform tests.as_user(tests.id('owner'));
  perform public.post_manual_journal(v_org, private.local_day(v_org, now()), 'Share capital paid into the wallet', jsonb_build_array(
    jsonb_build_object('code', (select b.ledger_code from bank_accounts b join wallets w on w.bank_account_id = b.id where w.id = tests.id('wallet')), 'debit', 1000000),
    jsonb_build_object('code', '3001', 'credit', 1000000)));
  perform tests.as_postgres();

  -- Fixed values where Counta draws random ones, and distinct creation times, so every run reads the same.
  update orgs set invoice_portal_token = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1' where id = v_org;
  update sales set public_token = case id when tests.id('invoice_draft') then 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2' else 'c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3' end
  where org_id = v_org;
  update practices set referral_code = 'GOLD-0000' where id = v_practice;
  update members set created_at = now() - case id when tests.id('m_owner') then interval '5 minutes' when tests.id('m_admin') then interval '4 minutes'
    when tests.id('m_accountant') then interval '3 minutes' when tests.id('m_staff') then interval '2 minutes' else interval '1 minute' end
  where org_id = v_org;
  update sales set created_at = now() - case id when tests.id('invoice_draft') then interval '2 minutes' else interval '1 minute' end where org_id = v_org;
end $$;
