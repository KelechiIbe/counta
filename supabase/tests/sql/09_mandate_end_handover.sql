-- Full mandate II: the handover to the owner (a ph_ link to someone outside the firm, taken by the person signed in with
-- that address: the owner's place, silence and branding lifted, the firm's places ordinary accountants outside the plan's
-- limit on people); ending the mandate without a handover (refused while money is in a wallet or a payment is moving;
-- connections paused, the business read-only and kept, the engagement partner's place kept); changing the engagement
-- partner (also of a business kept read-only); the export of the business's records; deletion blocked while the records are
-- kept; the portal's and the admin portal's reads. Edge-function calls are only recorded in net._requests.
begin;

-- Fixture: a verified practice (partner Bisi, partner Kunle, manager Tola, staff Ada), another practice, a TaxStreem admin
-- and a reviewer, the owner-to-be (Ngozi) and someone else; hooks on.
do $$
declare v_partner uuid; v_pr uuid;
begin
  v_partner := tests.remember('partner', tests.user('partner@firm.example.test', 'Bisi Partner'));
  perform tests.remember('partner2', tests.user('kunle.partner@firm.example.test', 'Kunle Partner'));
  perform tests.remember('manager', tests.user('tola.manager@firm.example.test', 'Tola Manager'));
  perform tests.remember('ada', tests.user('ada.staff@firm.example.test', 'Ada Staff'));
  perform tests.remember('new_owner', tests.user('owner@client.example.test', 'Ngozi Owner'));
  perform tests.remember('someone', tests.user('someone@example.test', 'Some One'));
  perform tests.remember('other_partner', tests.user('kemi.other@other.example.test', 'Kemi Other'));
  v_pr := tests.remember('pr', tests.practice(v_partner, 'Handover Partners', true));
  update practices set email = 'office@firm.example.test' where id = v_pr;
  perform tests.remember('partner_pm', (select id from practice_members where practice_id = v_pr and user_id = v_partner));
  perform tests.remember('partner2_pm', tests.practice_member(v_pr, tests.id('partner2'), 'partner'));
  perform tests.remember('manager_pm', tests.practice_member(v_pr, tests.id('manager'), 'manager'));
  perform tests.remember('ada_pm', tests.practice_member(v_pr, tests.id('ada'), 'staff'));
  -- Bisi is the practice's first partner (in one transaction everyone would join at the same moment).
  update practice_members set created_at = created_at + interval '1 minute' where practice_id = v_pr and user_id <> v_partner;
  perform tests.remember('pr2', tests.practice(tests.id('other_partner'), 'Other Partners', true));
  perform tests.remember('admin', tests.admin_user('admin1@example.test'));
  perform tests.remember('reviewer', tests.user('reviewer1@example.test'));
  insert into platform_reviewers (user_id) values (tests.id('reviewer'));
  perform tests.hooks_on();
end $$;

-- A wallet and a tax wallet opened for the business the way the payments edge function opens them; returns the wallet.
create function pg_temp.open_wallets(p_org uuid) returns uuid language plpgsql as $f$
declare w uuid; tw uuid;
begin
  insert into wallets (org_id, rail) values (p_org, 'flutterwave') returning id into w;
  perform public.svc_wallet_ready(w, jsonb_build_object('account_ref', 'w-' || p_org, 'account_number', '0123456789', 'bank_name', 'Test Bank', 'account_name', 'Test Ltd'));
  insert into tax_wallets (org_id, rail) values (p_org, 'flutterwave') returning id into tw;
  perform public.svc_tax_wallet_ready(tw, jsonb_build_object('account_ref', 't-' || p_org, 'account_number', '0123456780', 'bank_name', 'Test Bank', 'account_name', 'Test Ltd Tax'));
  return w;
end $f$;

-- The ledger code of a wallet's (or tax wallet's) account.
create function pg_temp.wallet_code(p_org uuid, p_tax boolean) returns text language sql as $f$
  select b.ledger_code from bank_accounts b
  where b.id = case when p_tax then (select bank_account_id from tax_wallets where org_id = p_org) else (select bank_account_id from wallets where org_id = p_org) end
$f$;

-- An entry moving p_amount from p_from to p_to (ledger codes), as Counta posts it.
create function pg_temp.move(p_org uuid, p_from text, p_to text, p_amount numeric) returns void language sql as $f$
  select private.post_entry(p_org, 'Test movement', 'manual', null, null, null,
    jsonb_build_array(jsonb_build_object('code', p_to, 'debit', p_amount), jsonb_build_object('code', p_from, 'credit', p_amount)));
$f$;

-- test: handover_start_rules
-- A partner hands a business the firm runs under full mandate to someone outside the firm: never a practice person's
-- address (whatever its case or spaces, whatever their status), one handover waiting at a time, five a day; the email is
-- the firm's, with a ph_ link, sent at most five times a day; the link's preview names the firm, the business and the address.
do $$
declare pr uuid := tests.id('pr'); c uuid; ci uuid; h uuid; h2 uuid; r jsonb; v_tok text;
begin
  c := tests.full_client(pr, tests.id('partner'), 'Ikenna Textiles Ltd');
  perform tests.remember('hc', c);
  perform tests.remember('ho', (select org_id from practice_clients where id = c));
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_handover_start(%L, '{"email":" PARTNER@firm.example.test ","name":"P"}')$q$, c), 'P0001: That person is on the practice.');
  perform tests.as_postgres();
  update practice_members set status = 'disabled' where id = tests.id('ada_pm');
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_handover_start(%L, '{"email":"Ada.Staff@firm.example.test","name":"Ada Staff"}')$q$, c), '%on the practice%');
  perform tests.as_postgres();
  update practice_members set status = 'active' where id = tests.id('ada_pm');
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_handover_start(%L, '{"email":"Ngozi.Alias@Sub.Firm.example.test","name":"Ngozi Owner"}')$q$, c), '%firm''s domain%');
  perform tests.throws(format($q$select public.practice_handover_start(%L, '{"email":"office@firm.example.test","name":"Office"}')$q$, c), '%on the practice%');
  perform tests.throws(format($q$select public.practice_handover_start(%L, '{"email":"not an email","name":"Ngozi Owner"}')$q$, c), '%email address%');
  perform tests.throws(format($q$select public.practice_handover_start(%L, '{"email":"owner@client.example.test","name":"N"}')$q$, c), '%name%');
  perform tests.as_user(tests.id('manager'));
  perform tests.throws(format($q$select public.practice_handover_start(%L, '{"email":"owner@client.example.test","name":"Ngozi Owner"}')$q$, c), '42501: Only a partner%');
  perform tests.as_user(tests.id('other_partner'));
  perform tests.throws(format($q$select public.practice_handover_start(%L, '{"email":"owner@client.example.test","name":"Ngozi Owner"}')$q$, c), '%not on this practice%');
  -- Started twice: the first is cancelled.
  perform tests.as_user(tests.id('partner'));
  h := (public.practice_handover_start(c, '{"email":" Owner@Client.example.test ","name":"Ngozi Owner"}')->>'id')::uuid;
  h2 := (public.practice_handover_start(c, '{"email":"owner@client.example.test","name":"Ngozi Owner"}')->>'id')::uuid;
  perform tests.as_postgres();
  assert (select status from practice_handovers where id = h) = 'cancelled'
     and (select (status, email, sent_count) = ('pending', 'owner@client.example.test', 0) from practice_handovers where id = h2),
    'handover_start_rules: one waiting';
  assert exists (select 1 from activity_log where org_id = tests.id('ho') and action = 'handover_started'), 'handover_start_rules: logged';
  -- The email, as the partner asks for it to go.
  perform tests.as_user(tests.id('partner'));
  assert public.practice_invite_check('handover', h2)->>'ok' = 'true', 'handover_start_rules: check';
  perform tests.throws(format('select public.practice_invite_check(%L, %L)', 'handover', h), '%accepted or cancelled%');
  perform tests.as_user(tests.id('manager'));
  perform tests.throws(format('select public.practice_invite_check(%L, %L)', 'handover', h2), '42501: Only a partner%');
  perform tests.as_service();
  r := public.svc_practice_invite_link('handover', h2);
  assert r->>'link' ~ 'ph_[0-9a-f]{48}$', 'handover_start_rules: link';
  assert r->>'link' like '%/practice/join?t=ph_%' and r->>'to' = 'owner@client.example.test' and r->>'from_name' = 'Handover Partners'
     and r->>'heading' = 'Take over Ikenna Textiles Ltd on Counta' and r->>'subject' = 'Take over Ikenna Textiles Ltd on Counta'
     and r->>'reply_to' = 'partner@firm.example.test' and r->>'greet' = 'Ngozi', format('handover_start_rules: email, got %s', r);
  assert public.svc_practice_invite_link('handover', h) is null, 'handover_start_rules: no link for a cancelled handover';
  v_tok := substring(r->>'link' from 'ph_[0-9a-f]{48}$');
  perform tests.as_postgres();
  assert (select token_hash = private.sha256_hex(v_tok) and token_expires > now() + interval '13 days' and sent_count = 1 from practice_handovers where id = h2),
    'handover_start_rules: only the hash kept, fourteen days';
  perform tests.as_anon();
  r := public.practice_invite_preview(v_tok);
  assert r = '{"kind": "handover", "status": "open", "practice": "Handover Partners", "business": "Ikenna Textiles Ltd", "email": "owner@client.example.test"}'::jsonb,
    format('handover_start_rules: preview, got %s', r);
  assert public.practice_invite_preview('ph_' || repeat('0', 48))->>'status' = 'invalid', 'handover_start_rules: unknown link';
  -- Five emails a day.
  perform tests.as_postgres();
  update practice_handovers set sent_count = 5, sent_at = now() where id = h2;
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format('select public.practice_invite_check(%L, %L)', 'handover', h2), '%enough emails to owner@client.example.test%');
  perform tests.as_postgres();
  update practice_handovers set sent_count = 1 where id = h2;
  -- Five handovers a day.
  update practice_handovers set created_at = now() - interval '1 hour' where id in (h, h2);
  insert into practice_handovers (practice_id, client_id, email, name, status)
  select pr, c, 'x' || g || '@client.example.test', 'Old Try', 'cancelled' from generate_series(1, 3) g;
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_handover_start(%L, '{"email":"owner@client.example.test","name":"Ngozi Owner"}')$q$, c), '%five handovers%');
  perform tests.as_postgres();
  delete from practice_handovers where client_id = c and name = 'Old Try';
  -- Only a business the firm runs under full mandate.
  ci := tests.involved_client(pr, tests.org(tests.id('someone'), 'Involved Hand Ltd'));
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_handover_start(%L, '{"email":"owner@client.example.test","name":"Ngozi Owner"}')$q$, ci), '%full mandate%');
  perform tests.as_postgres();
  perform tests.remember('h', h2);
end $$;

-- test: handover_accept
-- The person signed in with the handover's address takes the business over, once: they are its owner, the practice no
-- longer runs it (silence and branding lift), the client is involved and was handed over, the firm's people are ordinary
-- accountants, and it is logged.
do $$
declare c uuid := tests.id('hc'); o uuid := tests.id('ho'); h uuid := tests.id('h'); v_old text; v_tok text; r jsonb;
begin
  perform tests.as_service();
  v_old := substring(public.svc_practice_invite_link('handover', h)->>'link' from 'ph_[0-9a-f]{48}$');
  v_tok := substring(public.svc_practice_invite_link('handover', h)->>'link' from 'ph_[0-9a-f]{48}$');
  perform tests.as_anon();
  assert public.practice_invite_preview(v_old)->>'status' = 'invalid', 'handover_accept: a link sent again replaces the last one';
  perform tests.as_user(tests.id('someone'));
  perform tests.throws(format('select public.practice_handover_accept(%L)', v_tok),
    'P0001: This handover is for owner@client.example.test. Sign in with that email address.');
  perform tests.throws(format('select public.practice_handover_accept(%L)', v_old), '%not valid%');
  perform tests.throws($q$select public.practice_handover_accept('pm_abc')$q$, '%not valid%');
  -- Before: the practice runs the business, its people act as the owner.
  perform tests.as_postgres();
  assert (select count(*) from members where org_id = o and acts_as_owner and status = 'active') = 3, 'handover_accept: before';
  perform tests.as_user(tests.id('new_owner'));
  r := public.practice_handover_accept(v_tok);
  assert r = jsonb_build_object('org_id', o), format('handover_accept: returns the business, got %s', r);
  perform tests.as_postgres();
  assert (select managed_by is null from orgs where id = o) and (select role from members where org_id = o and user_id = tests.id('new_owner')) = 'owner',
    'handover_accept: owner';
  assert (select status = 'active' and email = 'owner@client.example.test' and practice_id is null and not acts_as_owner and p_manage_team and p_make_payments
          from members where org_id = o and user_id = tests.id('new_owner')), 'handover_accept: the owner''s place';
  assert (select mode = 'involved' and end_kind = 'handover' and status = 'active' from practice_clients where id = c), 'handover_accept: involved';
  assert not exists (select 1 from members where org_id = o and acts_as_owner and status = 'active')
     and exists (select 1 from members where org_id = o and user_id = tests.id('partner') and role = 'accountant' and status = 'active'),
    'handover_accept: firm drops to accountant';
  assert (select bool_and(role = 'accountant' and not p_make_payments and not p_manage_team) from members where org_id = o and practice_id = tests.id('pr') and status = 'active'),
    'handover_accept: ordinary accountants';
  assert (select status = 'accepted' and accepted_by = tests.id('new_owner') and accepted_at is not null from practice_handovers where id = h), 'handover_accept: accepted';
  assert exists (select 1 from activity_log where org_id = o and action = 'handover' and practice_id = tests.id('pr')), 'handover_accept: logged';
  assert private.outbound_check(o, 'call', 'reminder', null) is null and not private.white_label(o, null), 'handover_accept: silence and branding lifted';
  -- No director confirmed the wallets: TaxStreem checks the handover before payments open; its flag says the session's
  -- address could not be read.
  assert (select identity_status = 'review' and identity->>'reason' = 'handover' and identity->'handover'->>'status_before' = 'pending' from orgs where id = o)
     and not private.payments_open(o), 'handover_accept: TaxStreem checks it';
  assert (select detail->>'reason' = 'no_director' and detail->'ip_matches_firm' = 'null'::jsonb and detail->'ip' = 'null'::jsonb and resolved_at is null
          from practice_mandate_flags where client_id = c and kind = 'handover'), 'handover_accept: flagged';
  -- Once.
  perform tests.as_user(tests.id('new_owner'));
  perform tests.throws(format('select public.practice_handover_accept(%L)', v_tok), '%accepted already%');
  perform tests.as_anon();
  assert public.practice_invite_preview(v_tok)->>'status' = 'used', 'handover_accept: used';
  -- Alerts go to the owner now.
  perform tests.as_postgres();
  perform private.alert_send(o, 'test', 'k2', array['email'], '{"title":"T"}');
  assert (select to_address from messages where org_id = o and template = 'alert' order by created_at desc limit 1) = 'owner@client.example.test', 'handover_accept: silence lifted';
  assert (select status from messages where org_id = o and template = 'alert' order by created_at desc limit 1) <> 'suppressed', 'handover_accept: sent';
end $$;

-- test: handover_to_confirmed_director
-- The director who confirmed the wallets takes the business over (their confirmed address, whatever its case):
-- payments stay open, nothing for TaxStreem to check.
do $$
declare pr uuid := tests.id('pr'); c uuid; o uuid; h uuid; v_tok text; v_dir uuid;
begin
  c := tests.full_client(pr, tests.id('partner'));
  o := (select org_id from practice_clients where id = c);
  v_dir := tests.user('tunde.director@client.example.test', 'Tunde Bello');
  update orgs set identity_status = 'verified', director_confirmed_at = now() where id = o;
  insert into practice_director_confirmations (practice_id, client_id, name, email, status, confirmed_at)
  values (pr, c, 'Tunde Bello', 'Tunde.Director@Client.example.test', 'confirmed', now());
  assert private.payments_open(o), 'handover_to_confirmed_director: open before';
  perform tests.as_user(tests.id('partner'));
  h := (public.practice_handover_start(c, '{"email":"tunde.director@client.example.test","name":"Tunde Bello"}')->>'id')::uuid;
  perform tests.as_service();
  v_tok := substring(public.svc_practice_invite_link('handover', h)->>'link' from 'ph_[0-9a-f]{48}$');
  perform tests.as_user(v_dir);
  perform public.practice_handover_accept(v_tok);
  perform tests.as_postgres();
  assert (select managed_by is null and identity_status = 'verified' and not identity ? 'reason' from orgs where id = o) and private.payments_open(o),
    'handover_to_confirmed_director: payments stay open';
  assert not exists (select 1 from practice_mandate_flags where client_id = c and kind = 'handover'), 'handover_to_confirmed_director: no flag';
  perform private.require_payments_open(o);
end $$;

-- test: handover_review_closes_payments
-- A handover to anyone other than the director who confirmed: the payments that were open shut until TaxStreem has
-- checked it (its own message), a 'handover' flag records that the accepting session came from an address the firm's
-- people use (an IPv4 address written as IPv6 still matches), and TaxStreem's approval through the identity review opens
-- them again.
do $$
declare pr uuid := tests.id('pr'); c uuid; o uuid; h uuid; v_tok text; v_alias uuid; v_session uuid := gen_random_uuid(); f jsonb;
begin
  c := tests.full_client(pr, tests.id('partner'));
  o := (select org_id from practice_clients where id = c);
  v_alias := tests.user('ngozi.alias@freemail.example.test', 'Ngozi Alias');
  update orgs set identity_status = 'verified', director_confirmed_at = now() where id = o;
  insert into practice_director_confirmations (practice_id, client_id, name, email, status, confirmed_at)
  values (pr, c, 'Amina Yusuf', 'amina.director@client.example.test', 'confirmed', now());
  assert private.payments_open(o), 'handover_review_closes_payments: open before';
  -- The firm's partner signed in from 203.0.113.50 last week; the new owner's session comes from the same address.
  insert into auth.sessions (user_id, ip, created_at, updated_at) values (tests.id('partner'), '203.0.113.50', now() - interval '7 days', now() - interval '7 days');
  insert into auth.sessions (id, user_id, ip) values (v_session, v_alias, '::ffff:203.0.113.50');
  perform tests.as_user(tests.id('partner'));
  h := (public.practice_handover_start(c, '{"email":"ngozi.alias@freemail.example.test","name":"Ngozi Alias"}')->>'id')::uuid;
  perform tests.as_service();
  v_tok := substring(public.svc_practice_invite_link('handover', h)->>'link' from 'ph_[0-9a-f]{48}$');
  perform tests.as_postgres();
  perform tests.set_claims(tests.user_claims(v_alias, 'aal1') || jsonb_build_object('session_id', v_session));
  set local role authenticated;
  perform public.practice_handover_accept(v_tok);
  perform tests.as_postgres();
  assert (select managed_by is null and identity_status = 'review' and identity->>'reason' = 'handover' and identity->'handover'->>'status_before' = 'verified'
          from orgs where id = o) and not private.payments_open(o), 'handover_review_closes_payments: shut';
  perform tests.throws(format('select private.require_payments_open(%L)', o),
    '42501: Payments open once TaxStreem has checked the handover. This usually takes a working day.');
  select detail into f from practice_mandate_flags where client_id = c and kind = 'handover';
  assert f->>'reason' = 'not_director' and (f->>'ip_matches_firm')::boolean and f->>'ip' = '203.0.113.50' and f->>'handover_id' = h::text,
    format('handover_review_closes_payments: flagged, got %s', f);
  -- Neither the new owner's NIN check nor a NIN slip goes round TaxStreem's check: not a new slip, not one already stored.
  perform tests.as_service();
  assert public.svc_identity_nin(v_alias, o, '1234', 'Amina', null, 'Yusuf') = '{"verified": false, "reason": "handover_review"}'::jsonb,
    'handover_review_closes_payments: no NIN check meanwhile';
  perform tests.as_postgres();
  update orgs set identity = identity || jsonb_build_object('slip', jsonb_build_object('path', o || '/kyc/nin-slip-old.jpg', 'file_name', 'old.jpg', 'at', now(), 'read', false))
  where id = o;
  perform tests.as_service();
  perform tests.throws(format($q$select public.svc_identity_slip(%L, %L, '{"is_nin_document": true, "first_name": "Amina", "surname": "Yusuf", "nin_last4": "1234"}')$q$, v_alias, o),
    'P0001: Payments open once TaxStreem has checked the handover.%');
  perform tests.as_user(v_alias);
  perform tests.throws(format('select public.identity_slip(%L, %L)', o, o || '/kyc/nin-slip-new.jpg'), '%checked the handover%');
  assert (select x->>'reason' = 'handover' and (x->>'handover_review')::boolean and x->>'status' = 'review' from public.identity_state(o) x),
    'handover_review_closes_payments: the screens know';
  perform tests.as_postgres();
  assert (select identity_status from orgs where id = o) = 'review', 'handover_review_closes_payments: still in review';
  -- TaxStreem sees it is a handover, of a business confirmed before it.
  perform tests.as_user(tests.id('admin'), 'aal2');
  assert exists (select 1 from jsonb_array_elements(public.identity_reviews()) x
                 where x->>'org_id' = o::text and x->>'reason' = 'handover' and x->'handover'->>'status_before' = 'verified' and x->'handover'->>'id' = h::text),
    'handover_review_closes_payments: in the review queue, as a handover';
  assert exists (select 1 from jsonb_array_elements(public.admin_mandates()->'flags') x where x->>'kind' = 'handover' and x->'business'->>'org_id' = o::text),
    'handover_review_closes_payments: on the mandates page';
  -- Rejected: it stays shut, and only TaxStreem deciding again opens it.
  perform public.review_identity(o, false, 'Not the owner on our records');
  perform tests.as_postgres();
  assert (select identity_status = 'rejected' and identity->>'reason' = 'handover' from orgs where id = o) and not private.payments_open(o), 'handover_review_closes_payments: rejected';
  assert (select resolved_at is null from practice_mandate_flags where client_id = c and kind = 'handover'), 'handover_review_closes_payments: the flag stays open';
  perform tests.throws(format('select private.require_payments_open(%L)', o), '42501: Payments are locked: TaxStreem did not accept the handover of the business.%');
  perform tests.as_service();
  assert public.svc_identity_nin(v_alias, o, '1234', 'Amina', null, 'Yusuf')->>'reason' = 'handover_review', 'handover_review_closes_payments: no NIN check after a rejection';
  perform tests.throws(format($q$select public.svc_identity_slip(%L, %L, '{"is_nin_document": true, "first_name": "Amina", "surname": "Yusuf", "nin_last4": "1234"}')$q$, v_alias, o),
    '%did not accept the handover%');
  perform tests.as_user(v_alias);
  perform tests.throws(format('select public.identity_slip(%L, %L)', o, o || '/kyc/nin-slip-new.jpg'), '%did not accept the handover%');
  -- Approved (the business was confirmed before the handover): payments open, the flag resolved.
  perform tests.as_user(tests.id('admin'), 'aal2');
  assert public.review_identity(o, true, null)->>'status' = 'approved', 'handover_review_closes_payments: approve';
  perform tests.as_postgres();
  assert (select identity_status = 'approved' from orgs where id = o) and private.payments_open(o), 'handover_review_closes_payments: approved, open';
  perform private.require_payments_open(o);
  assert (select resolved_at is not null and resolution_note like 'Identity review: approved%' from practice_mandate_flags where client_id = c and kind = 'handover'),
    'handover_review_closes_payments: flag resolved';
  perform tests.as_service();
  assert (public.svc_identity_nin(v_alias, o, '1234', 'Amina', null, 'Yusuf')->>'already')::boolean, 'handover_review_closes_payments: confirmed';
  perform tests.as_postgres();
end $$;

-- test: handover_approval_back_to_pending
-- A business handed over before its identity was confirmed: TaxStreem's approval sends it back to the ordinary check
-- ('pending', no longer a handover review), and the new owner then confirms it like any owner (here with their own NIN,
-- as the business is not on CAC).
do $$
declare o uuid := tests.id('ho');
begin
  assert (select identity_status = 'review' and identity->'handover'->>'status_before' = 'pending' from orgs where id = o), 'handover_approval_back_to_pending: before';
  perform tests.as_user(tests.id('admin'), 'aal2');
  assert public.review_identity(o, true, 'Owner confirmed by phone')->>'status' = 'pending', 'handover_approval_back_to_pending: pending';
  perform tests.as_postgres();
  assert (select identity_status = 'pending' and not identity ? 'reason' and identity ? 'handover' from orgs where id = o)
     and not private.handover_pending('pending', (select identity from orgs where id = o)) and not private.payments_open(o),
    'handover_approval_back_to_pending: the ordinary check';
  perform tests.throws(format('select private.require_payments_open(%L)', o), '42501: Payments open once a director confirms their NIN.%');
  perform tests.as_user(tests.id('new_owner'));
  assert (select x->'reason' = 'null'::jsonb and not (x->>'handover_review')::boolean from public.identity_state(o) x), 'handover_approval_back_to_pending: the screens know';
  perform tests.as_service();
  assert (public.svc_identity_nin(tests.id('new_owner'), o, '4321', 'Ngozi', null, 'Owner')->>'verified')::boolean, 'handover_approval_back_to_pending: the owner confirms';
  perform tests.as_postgres();
  assert (select identity_status = 'verified' from orgs where id = o) and private.payments_open(o), 'handover_approval_back_to_pending: open';
end $$;

-- test: handover_accept_refusals
-- Someone of the firm cannot take a handover (they joined it after the handover started), nor can an expired link be
-- used; while the handover waits, Counta may email its address about the business; not once it is cancelled.
do $$
declare pr uuid := tests.id('pr'); c uuid; o uuid; h uuid; v_late uuid; v_tok text;
begin
  c := tests.full_client(pr, tests.id('partner'));
  o := (select org_id from practice_clients where id = c);
  v_late := tests.user('late.owner@latecomer.example.test', 'Late Owner');
  perform tests.as_user(tests.id('partner'));
  h := (public.practice_handover_start(c, '{"email":"late.owner@latecomer.example.test","name":"Late Owner"}')->>'id')::uuid;
  perform tests.as_service();
  v_tok := substring(public.svc_practice_invite_link('handover', h)->>'link' from 'ph_[0-9a-f]{48}$');
  perform tests.as_postgres();
  insert into messages (org_id, channel, to_address, template, params) values (o, 'email', 'late.owner@latecomer.example.test', 'invite', '{}');
  assert (select status from messages where org_id = o and to_address = 'late.owner@latecomer.example.test') = 'queued', 'handover_accept_refusals: the handover''s address';
  insert into messages (org_id, channel, to_address, template, params) values (o, 'email', 'stranger@client.example.test', 'invite', '{}');
  assert (select status from messages where org_id = o and to_address = 'stranger@client.example.test') = 'suppressed', 'handover_accept_refusals: no one else';
  -- Expired.
  update practice_handovers set token_expires = now() - interval '1 minute' where id = h;
  perform tests.as_user(v_late);
  perform tests.throws(format('select public.practice_handover_accept(%L)', v_tok), '%expired%');
  perform tests.as_postgres();
  update practice_handovers set token_expires = now() + interval '1 day' where id = h;
  -- An address not confirmed yet.
  update auth.users set email_confirmed_at = null where id = v_late;
  perform tests.as_user(v_late);
  perform tests.throws(format('select public.practice_handover_accept(%L)', v_tok), '42501: Confirm your email address first%');
  perform tests.as_postgres();
  update auth.users set email_confirmed_at = now() where id = v_late;
  -- On the practice.
  perform tests.practice_member(pr, v_late, 'staff');
  perform tests.as_user(v_late);
  perform tests.throws(format('select public.practice_handover_accept(%L)', v_tok), '%on the practice%');
  perform tests.as_postgres();
  assert (select managed_by = pr from orgs where id = o), 'handover_accept_refusals: still run by the practice';
  -- (The late joiner leaves again: their address and domain would be the firm's.)
  delete from practice_members where practice_id = pr and user_id = v_late;
  -- Cancelled by another handover: its address is not written to any more (an alert goes to the firm instead).
  perform tests.as_user(tests.id('partner'));
  perform public.practice_handover_start(c, '{"email":"owner2@client.example.test","name":"Second Owner"}');
  perform tests.as_postgres();
  insert into messages (org_id, channel, to_address, template, params) values (o, 'email', 'late.owner@latecomer.example.test', 'alert', '{}');
  assert (select to_address = 'partner@firm.example.test' and params->>'readdressed' = 'true' from messages where org_id = o and template = 'alert'),
    'handover_accept_refusals: to the firm again';
  perform tests.as_user(v_late);
  perform tests.throws(format('select public.practice_handover_accept(%L)', v_tok), '%not valid%');
  perform tests.as_postgres();
end $$;

-- test: seats_after_handover
-- After the handover the firm's accountants' places stay outside the plan's limit on people, as they were under full
-- mandate; the business's own people count against it.
do $$
declare o uuid := tests.id('ho'); c uuid := tests.id('hc');
begin
  insert into org_entitlement_overrides (org_id, module_key, included, quota, enforce) values (o, 'users', true, 2, 'block');
  assert (select count(*) from members where org_id = o and practice_id = tests.id('pr') and status = 'active') = 3, 'seats_after_handover: three firm places';
  assert private.meter_usage(o, 'users') = 1, format('seats_after_handover: only the owner counts, got %s', private.meter_usage(o, 'users'));
  perform tests.member(o, tests.user('cashier@client.example.test'), 'cashier');
  perform tests.throws(format('select tests.member(%L, tests.user(%L), %L)', o, 'cashier2@client.example.test', 'cashier'), '%Your plan%');
  perform tests.as_user(tests.id('partner'));
  perform public.practice_assign(c, tests.id('ada_pm'), true);
  perform tests.as_postgres();
  assert exists (select 1 from members where org_id = o and user_id = tests.id('ada') and role = 'accountant' and status = 'active'), 'seats_after_handover: a firm person added';
  assert private.meter_usage(o, 'users') = 2, 'seats_after_handover: still the business''s own';
  -- Ended by the owner: the firm's places are switched off and would count again.
  perform tests.as_user(tests.id('new_owner'));
  perform public.practice_end(c);
  perform tests.as_postgres();
  assert not exists (select 1 from members where org_id = o and practice_id = tests.id('pr') and status = 'active'), 'seats_after_handover: ended';
  assert not private.seat_exempt(o, tests.id('pr')), 'seats_after_handover: no longer exempt';
  delete from org_entitlement_overrides where org_id = o;
end $$;

-- test: end_refuses_money
-- Ending a full mandate waits while either wallet holds money or a payment is moving; a partner ends it, with a reason.
do $$
declare pr uuid := tests.id('pr'); c uuid; o uuid; w uuid; v_w text; v_t text; ci uuid; p uuid;
begin
  c := tests.full_client(pr, tests.id('partner'));
  o := (select org_id from practice_clients where id = c);
  perform tests.remember('ec', c);
  perform tests.remember('eo', o);
  w := pg_temp.open_wallets(o);
  v_w := pg_temp.wallet_code(o, false);
  v_t := pg_temp.wallet_code(o, true);
  perform pg_temp.move(o, '3001', v_w, 5000);
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_end_mandate(%L, '{"reason":"Client moved firms"}')$q$, c),
    'P0001: Move the money out of the business wallet and the tax wallet first.');
  perform tests.as_postgres();
  perform pg_temp.move(o, v_w, v_t, 5000);
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_end_mandate(%L, '{"reason":"Client moved firms"}')$q$, c), '%Move the money out%');
  perform tests.as_postgres();
  perform pg_temp.move(o, v_t, '3001', 4999.99);
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_end_mandate(%L, '{"reason":"Client moved firms"}')$q$, c), '%Move the money out%');
  perform tests.as_postgres();
  perform pg_temp.move(o, v_t, '3001', 0.01);
  -- Payments moving: a payout, a transfer to or from the tax wallet, a tax payment.
  insert into payouts (org_id, number, wallet_id, purpose, amount, bank_code, account_number, account_name, narration, reference, status)
  values (o, 'PO-T1', w, 'withdrawal', 100, '058', '0123456789', 'Test Account', 'Test', 'ref-t1', 'approved') returning id into p;
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_end_mandate(%L, '{"reason":"Client moved firms"}')$q$, c),
    'P0001: Wait for the payouts in progress to finish first.');
  perform tests.as_postgres();
  update payouts set status = 'failed' where id = p;
  insert into tax_transfers (org_id, tax_wallet_id, wallet_id, direction, amount, reference, status)
  values (o, (select id from tax_wallets where org_id = o), w, 'in', 100, 'tt-1', 'sent') returning id into p;
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_end_mandate(%L, '{"reason":"Client moved firms"}')$q$, c), '%payouts in progress%');
  perform tests.as_postgres();
  update tax_transfers set status = 'done' where id = p;
  insert into tax_payments (org_id, tax_wallet_id, kind, period, amount, tax_reference, reference, bank_code, account_number, account_name)
  values (o, (select id from tax_wallets where org_id = o), 'vat', date_trunc('month', current_date)::date, 100, 'TAXREF1', 'tp-1', '000', '0000000001', 'NRS')
  returning id into p;
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_end_mandate(%L, '{"reason":"Client moved firms"}')$q$, c), '%payouts in progress%');
  perform tests.as_postgres();
  update tax_payments set status = 'failed' where id = p;
  -- A reason; a partner; a full mandate.
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_end_mandate(%L, '{"reason":" Too short "}')$q$, c), '%10 characters%');
  perform tests.as_user(tests.id('manager'));
  perform tests.throws(format($q$select public.practice_end_mandate(%L, '{"reason":"Client moved firms"}')$q$, c), '42501: Only a partner%');
  perform tests.as_postgres();
  ci := (select id from practice_clients where practice_id = pr and mode = 'involved' and status = 'active' limit 1);
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_end_mandate(%L, '{"reason":"Client moved firms"}')$q$, ci), '%full mandate%');
  perform tests.as_postgres();
  assert (select read_only_at is null and managed_by = pr from orgs where id = o), 'end_refuses_money: nothing changed';
end $$;

-- test: end_mandate
-- Ended without a handover: connections paused (tools, POS, bank feeds), the plan cancelled at the end of its period, the
-- client ended, only the engagement partner's place left, a waiting handover cancelled and a director's request closed,
-- logged, and last the business read-only and kept as long as the letter says (six years by default), still run by the
-- practice so it stays silent. Payments that were open shut, and no stored file is deleted while the records are kept.
do $$
declare pr uuid := tests.id('pr'); c uuid := tests.id('ec'); o uuid := tests.id('eo'); h uuid; d public.practice_director_confirmations; r jsonb;
  v_path text := tests.id('eo') || '/documents/kept-letter.pdf';
begin
  update orgs set identity_status = 'verified', director_confirmed_at = now() where id = o;
  insert into documents (org_id, cat, folder, name, path, uploaded_by)
  values (o, 'company', 'Letters', 'Kept letter.pdf', v_path, (select id from members where org_id = o and user_id = tests.id('partner')));
  assert private.payments_open(o) and (private.org_brand(o, null)->>'pay_online')::boolean, 'end_mandate: payments open before';
  perform tests.as_user(tests.id('partner'));
  assert private.document_may_delete(v_path), 'end_mandate: the file could be deleted before';
  perform tests.as_postgres();
  insert into integrations (org_id, provider, hook_token_hash) values (o, 'paystack', 'abc123');
  insert into pos_connections (org_id, provider, label) values (o, 'moniepoint', 'Shop counter');
  insert into org_entitlement_overrides (org_id, module_key, included, quota, enforce) values (o, 'bank_feeds', true, 5, 'block');
  perform private.open_bank_account(o, 'bank', 'GTB feed', '{"provider": "mono", "provider_ref": "mono-test-1"}'::jsonb, null);
  insert into subscriptions (org_id, plan_id, status, billing, current_period_start, current_period_end, paid_by)
  values (o, private.default_plan_id(), 'active', 'month', now(), now() + interval '20 days', pr)
  on conflict (org_id) do update set paid_by = excluded.paid_by;
  insert into practice_director_confirmations (practice_id, client_id, name, email, token_hash, token_expires)
  values (pr, c, 'Tunde Bello', 'tunde@director.example.test', repeat('cd', 32), now() + interval '14 days') returning * into d;
  assert private.director_state(d) is null, 'end_mandate: the director''s request waits';
  perform tests.as_user(tests.id('partner'));
  h := (public.practice_handover_start(c, '{"email":"owner3@client.example.test","name":"Third Owner"}')->>'id')::uuid;
  r := public.practice_end_mandate(c, '{"reason":"Client moved firms"}');
  perform tests.as_postgres();
  assert r->>'org_id' = o::text and (r->>'retain_until')::date = (current_date + interval '6 years')::date, format('end_mandate: returns, got %s', r);
  assert (select read_only_at is not null and retain_until = (current_date + interval '6 years')::date and managed_by = pr from orgs where id = o), 'end_mandate: kept 6 years (letter default)';
  assert (select retain_until from practice_intakes where client_id = c) = (select retain_until from orgs where id = o), 'end_mandate: intake kept as long, set by the Task 8 trigger';
  assert (select status from integrations where org_id = o) = 'paused' and (select status from pos_connections where org_id = o) = 'removed', 'end_mandate: paused';
  assert (select provider_ref is null and provider = 'manual' and provider_meta->>'unlinked_reason' = 'engagement ended' and provider_meta->>'former_feed' = 'mono-test-1'
          from bank_accounts where org_id = o and name = 'GTB feed'), 'end_mandate: feed unlinked';
  assert (select cancel_at_period_end and paid_by = pr from subscriptions where org_id = o), 'end_mandate: plan ends with its period';
  assert (select status = 'ended' and end_kind = 'ended' and ended_at is not null and ended_by = tests.id('partner') from practice_clients where id = c), 'end_mandate: ended';
  assert (select status from members where org_id = o and user_id = tests.id('partner')) = 'active' and (select status from members where org_id = o and user_id = tests.id('manager')) = 'disabled',
    'end_mandate: seats';
  assert (select count(*) from members where org_id = o and status = 'active') = 1, 'end_mandate: only the engagement partner';
  assert (select status from practice_handovers where id = h) = 'cancelled', 'end_mandate: handover cancelled';
  select * into d from practice_director_confirmations where id = d.id;
  assert private.director_state(d) = 'closed', 'end_mandate: director''s request closed';
  assert exists (select 1 from activity_log where org_id = o and action = 'mandate_ended' and after->>'reason' = 'Client moved firms'), 'end_mandate: logged';
  -- Read-only for the people signed in.
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.save_customer(%L, '{"name":"After"}')$q$, o), '42501%');
  perform tests.throws(format($q$select public.practice_end_mandate(%L, '{"reason":"Client moved firms"}')$q$, c), '%full mandate%');
  assert not private.document_may_delete(v_path), 'end_mandate: no stored file deleted while kept';
  perform tests.as_postgres();
  insert into messages (org_id, channel, to_address, template, params) values (o, 'email', 'partner@firm.example.test', 'alert', '{}');
  assert (select status from messages where org_id = o order by created_at desc limit 1) = 'suppressed', 'end_mandate: silence persists';
  -- Payments shut.
  assert not private.payments_open(o) and not (private.org_brand(o, null)->>'pay_online')::boolean, 'end_mandate: payments shut';
  perform tests.throws(format('select private.require_payments_open(%L)', o), '42501: This business is read-only: its engagement has ended. Payments are closed.');
  -- Past the date, a file may go again.
  update orgs set retain_until = current_date - 1 where id = o;
  perform tests.as_user(tests.id('partner'));
  assert private.document_may_delete(v_path), 'end_mandate: a file past the date';
  perform tests.as_postgres();
  update orgs set retain_until = (current_date + interval '6 years')::date where id = o;
end $$;

-- test: end_tick_runs_for_others
-- After a mandate ends, the renewal run still renews every other business: the ended business, even paid by card with no
-- practice named, moves to the standard plan when its period ends instead of being charged (a charge for a business the
-- practice runs that does not name the practice would stop the whole run).
do $$
declare o uuid := tests.id('eo'); v_ord uuid; v_plan uuid; r jsonb;
begin
  insert into plans (code, name, price_month) values ('growth-t', 'Growth Test', 5000) returning id into v_plan;
  v_ord := tests.org(tests.id('someone'), 'Renewing Ordinary Ltd');
  insert into subscription_cards (org_id, token, email, last4) values (v_ord, 'card-tok-1', 'someone@example.test', '4242');
  insert into subscriptions (org_id, plan_id, status, billing, pay_method, current_period_start, current_period_end)
  values (v_ord, v_plan, 'active', 'month', 'card', now() - interval '1 month', now() - interval '1 minute')
  on conflict (org_id) do update set plan_id = excluded.plan_id, pay_method = 'card', current_period_end = excluded.current_period_end;
  -- The worst case for the ended business: a card of its own, no practice named.
  insert into subscription_cards (org_id, token, email, last4) values (o, 'card-tok-2', 'books@firm.example.test', '1111');
  update subscriptions set plan_id = v_plan, pay_method = 'card', paid_by = null, current_period_end = now() - interval '1 minute' where org_id = o;
  perform tests.as_service();
  r := public.svc_subscription_tick();
  perform tests.as_postgres();
  assert exists (select 1 from subscription_charges where org_id = v_ord and kind = 'renewal'), format('end_tick_runs_for_others: renewed, got %s', r);
  assert not exists (select 1 from subscription_charges where org_id = o)
     and (select plan_id = private.default_plan_id() and pay_method is null from subscriptions where org_id = o), 'end_tick_runs_for_others: the ended business ends its plan';
end $$;

-- test: engagement_partner_change
-- A partner chooses another engagement partner (an active partner or manager of the firm), for an active client and for a
-- full mandate kept read-only after it ended: the place kept moves to the new one, and the one before can then be moved.
do $$
declare pr uuid := tests.id('pr'); c uuid; ce uuid; oe uuid; r jsonb;
  v_other uuid := (select id from practice_members where practice_id = tests.id('pr2') limit 1);
begin
  -- An active client whose engagement partner is Kunle.
  c := tests.full_client(pr, tests.id('partner'));
  update practice_clients set engagement_partner_id = tests.id('partner2_pm') where id = c;
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_update_member(%L, '{"role":"staff"}')$q$, tests.id('partner2_pm')), '%engagement partner%');
  perform tests.as_user(tests.id('manager'));
  perform tests.throws(format('select public.practice_set_engagement_partner(%L, %L)', c, tests.id('manager_pm')), '42501: Only a partner%');
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format('select public.practice_set_engagement_partner(%L, %L)', c, tests.id('ada_pm')), '%active partners or managers%');
  perform tests.throws(format('select public.practice_set_engagement_partner(%L, %L)', c, v_other), '%active partners or managers%');
  r := public.practice_set_engagement_partner(c, tests.id('manager_pm'));
  assert r->>'engagement_partner_id' = tests.id('manager_pm')::text, 'engagement_partner_change: active';
  perform tests.as_postgres();
  assert exists (select 1 from activity_log where org_id = (select org_id from practice_clients where id = c) and action = 'engagement_partner'), 'engagement_partner_change: logged';
  -- A mandate ended without a handover, Kunle its engagement partner: his place is the one kept.
  ce := tests.full_client(pr, tests.id('partner'));
  oe := (select org_id from practice_clients where id = ce);
  update practice_clients set engagement_partner_id = tests.id('partner2_pm') where id = ce;
  perform tests.as_user(tests.id('partner'));
  perform public.practice_end_mandate(ce, '{"reason":"Engagement over, no handover"}');
  perform tests.as_postgres();
  assert (select array_agg(user_id) from members where org_id = oe and status = 'active') = array[tests.id('partner2')], 'engagement_partner_change: Kunle kept';
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_update_member(%L, '{"role":"staff"}')$q$, tests.id('partner2_pm')), '%engagement partner%');
  r := public.practice_set_engagement_partner(ce, tests.id('manager_pm'));
  perform tests.as_postgres();
  assert (select engagement_partner_id from practice_clients where id = ce) = tests.id('manager_pm')
     and (select array_agg(user_id) from members where org_id = oe and status = 'active') = array[tests.id('manager')]
     and (select acts_as_owner and role = 'admin' from members where org_id = oe and user_id = tests.id('manager')),
    'engagement_partner_change: the kept place moves';
  assert (select read_only_at is not null from orgs where id = oe), 'engagement_partner_change: still read-only';
  perform tests.as_user(tests.id('manager'));
  perform tests.throws(format($q$select public.save_customer(%L, '{"name":"After"}')$q$, oe), '42501%');
  -- Kunle is no one's engagement partner now.
  perform tests.as_user(tests.id('partner'));
  perform public.practice_update_member(tests.id('partner2_pm'), '{"role":"staff"}');
  perform tests.as_postgres();
  assert (select role from practice_members where id = tests.id('partner2_pm')) = 'staff', 'engagement_partner_change: moved';
  update practice_members set role = 'partner' where id = tests.id('partner2_pm');
  -- A client handed over or ended otherwise: no.
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format('select public.practice_set_engagement_partner(%L, %L)', tests.id('hc'), tests.id('partner_pm')), '%ended%');
  perform tests.as_postgres();
end $$;

-- test: deletion_blocked
-- A business kept after its engagement ended is not deleted, whichever way, until its records are past the date.
do $$
declare o uuid := tests.id('eo'); v_name text; v_err text;
begin
  select name into v_name from orgs where id = o;
  perform tests.throws(format('delete from orgs where id = %L', o), 'P0001: This business is kept until ' || to_char(current_date + interval '6 years', 'DD Mon YYYY') || ' (engagement records).');
  perform tests.as_user(tests.id('admin'), 'aal2');
  perform tests.throws(format('select public.admin_business_delete(%L, %L)', o, v_name), '%kept until%');
  perform tests.throws(format('select public.admin_business_delete_preview(%L)', o), '%kept until%');
  -- The wrong name is not even asked about first.
  perform tests.throws(format('select public.admin_business_delete(%L, %L)', o, 'Wrong Name'), '%kept until%');
  perform tests.as_postgres();
  update orgs set retain_until = current_date - 1 where id = o;
  -- Past the date the guard lets it go: the admin's delete goes through (rolled back here).
  perform tests.as_user(tests.id('admin'), 'aal2');
  begin
    perform public.admin_business_delete(o, v_name);
    raise exception 'rolled back';
  exception when others then
    v_err := sqlerrm;
  end;
  perform tests.as_postgres();
  assert v_err = 'rolled back', format('deletion_blocked: past the date the business is deleted, got %s', v_err);
  update orgs set retain_until = (current_date + interval '6 years')::date where id = o;
  assert exists (select 1 from orgs where id = o), 'deletion_blocked: still there';
end $$;

-- test: export_rows
-- A partner exports a full-mandate client's records (also kept read-only after it ended): every business table but the
-- logs, sessions and KYC, each row with its secrets redacted and CAC people's names hidden, paged by the table's primary
-- key; values whole, however long; the business's own row without its identity, directors and company secretary; the
-- ledger and the activity log, paged the same way; the finished file logged.
do $$
declare pr uuid := tests.id('pr'); c uuid := tests.id('ec'); o uuid := tests.id('eo'); t jsonb; r jsonb; r2 jsonb; v_rows int; v_after text; v_n int := 0;
  v_big jsonb; v_t text; v_followed int := 0; v_lines int;
begin
  perform tests.as_user(tests.id('partner'));
  r := public.practice_export_begin(c);
  t := r->'tables';
  assert t ? 'customers' and not t ? 'kyc_profiles', 'export_rows: tables';
  assert t ? 'orgs', 'export_rows: the business''s own row';
  assert r->>'org_id' = o::text and r->>'client_id' = c::text and r->>'practice_id' = pr::text, 'export_rows: what to export';
  assert not (t ?| array['activity_log', 'usage_events', 'ai_logs', 'shop_hits', 'sso_logins', 'chat_links', 'whatsapp_sessions', 'portal_logins', 'pit_etax_logins'])
     and t ?& array['subscriptions', 'role_permissions', 'journal_lines', 'pit_people'], 'export_rows: the logs, sessions and KYC stay';
  perform tests.as_user(tests.id('manager'));
  perform tests.throws(format('select public.practice_export_begin(%L)', c), '42501: Only a partner%');
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format('select public.practice_export_begin(%L)', tests.id('hc')), '%full mandate%');
  perform tests.as_service();
  assert (select bool_and(x->>'hook_token_hash' = '[redacted]') and count(*) = 1 from jsonb_array_elements(public.svc_export_rows(o, 'integrations', null, 1000)->'rows') x), 'export_rows: redacted';
  perform tests.throws(format('select public.svc_export_rows(%L, %L, null, 10)', o, 'kyc_profiles'), '%not exported%');
  perform tests.throws(format('select public.svc_export_rows(%L, %L, null, 10)', o, 'customers; drop table orgs'), '%not exported%');
  perform tests.as_postgres();
  insert into role_permissions (org_id, role, perms) values (o, 'manager', '{}'), (o, 'staff', '{}') on conflict do nothing;
  insert into pit_people (org_id, name, source) values (o, 'Tunde Bello', 'cac'), (o, 'Shop Manager', 'added');
  perform tests.as_service();
  assert jsonb_array_length(public.svc_export_rows(o, 'role_permissions', null, 1000)->'rows') >= 2 and public.svc_export_rows(o, 'subscriptions', null, 1000) ? 'rows',
    'export_rows: tables without an id column page by their primary key';
  r := public.svc_export_rows(o, 'role_permissions', null, 1);
  assert r->>'next' is not null and public.svc_export_rows(o, 'role_permissions', r->>'next', 1)->'rows'->0 <> r->'rows'->0, 'export_rows: next page starts after the last key';
  -- Paging through a table one row at a time gives every row once.
  v_after := null;
  loop
    r := public.svc_export_rows(o, 'role_permissions', v_after, 1);
    v_n := v_n + jsonb_array_length(r->'rows');
    exit when r->>'next' is null;
    v_after := r->>'next';
  end loop;
  perform tests.as_postgres();
  assert v_n = (select count(*) from role_permissions where org_id = o), 'export_rows: every row once';
  perform tests.as_service();
  r := public.svc_export_rows(o, 'role_permissions', null, 1000);
  assert r->'next' = 'null'::jsonb, 'export_rows: no next page';
  perform tests.throws(format('select public.svc_export_rows(%L, %L, %L, 10)', o, 'role_permissions', 'not json'), '%page%');
  r := public.svc_export_rows(o, 'pit_people', null, 1000);
  assert (select bool_and(case when x->>'source' = 'cac' then x->>'name' = '[redacted]' else x->>'name' <> '[redacted]' end) from jsonb_array_elements(r->'rows') x)
     and jsonb_array_length(r->'rows') = 2, 'export_rows: CAC people''s names hidden';
  r := public.svc_export_ledger(o);
  assert jsonb_array_length(r->'rows') > 0 and r->'next' = 'null'::jsonb
     and (select bool_and(x ?& array['date', 'journal_ref', 'account_code', 'account_name', 'debit', 'credit', 'memo']) from jsonb_array_elements(r->'rows') x)
     and (select sum((x->>'debit')::numeric) = sum((x->>'credit')::numeric) from jsonb_array_elements(r->'rows') x), 'export_rows: ledger';
  -- The ledger and the activity log one row at a time: every row once.
  v_lines := jsonb_array_length(r->'rows');
  v_n := 0; v_after := null;
  loop
    r := public.svc_export_ledger(o, v_after, 1);
    v_n := v_n + jsonb_array_length(r->'rows');
    exit when r->>'next' is null;
    v_after := r->>'next';
  end loop;
  assert v_n = v_lines and v_lines > 1, format('export_rows: ledger paged, %s of %s', v_n, v_lines);
  r := public.svc_export_activity(o);
  assert jsonb_array_length(r->'rows') > 1 and r->'next' = 'null'::jsonb, 'export_rows: activity';
  v_lines := jsonb_array_length(r->'rows');
  v_n := 0; v_after := null;
  loop
    r := public.svc_export_activity(o, v_after, 2);
    v_n := v_n + jsonb_array_length(r->'rows');
    exit when r->>'next' is null;
    v_after := r->>'next';
  end loop;
  assert v_n = v_lines, format('export_rows: activity paged, %s of %s', v_n, v_lines);
  perform tests.throws(format('select public.svc_export_activity(%L, %L, 10)', o, '[1, 2]'), '%page%');
  -- A page marker of the right shape with values of the wrong type: refused in plain words.
  perform tests.throws(format('select public.svc_export_activity(%L, %L, 10)', o, '[{"a": 1}]'), 'P0001: That page of the export is not valid.');
  perform tests.throws(format('select public.svc_export_ledger(%L, %L, 10)', o, '["not a date", 1, 2]'), 'P0001: That page of the export is not valid.');
  perform tests.throws(format('select public.svc_export_ledger(%L, %L, 10)', o, '["2026-01-01", "x", 2]'), 'P0001: That page of the export is not valid.');
  perform tests.throws(format('select public.svc_export_rows(%L, %L, %L, 1)', o, 'role_permissions', '["not-a-uuid", "manager"]'), 'P0001: That page of the export is not valid.');
  -- A value longer than 4 KB, an array, comes out whole.
  perform tests.as_postgres();
  v_big := jsonb_build_object('items', (select jsonb_agg(jsonb_build_object('n', g, 'label', 'item number ' || g)) from generate_series(1, 300) g));
  update integrations set settings = v_big where org_id = o;
  assert length(v_big::text) > 4096, 'export_rows: a long value';
  perform tests.as_service();
  assert (select x->'settings' = v_big from jsonb_array_elements(public.svc_export_rows(o, 'integrations', null, 1000)->'rows') x), 'export_rows: whole values';
  -- The business's own row, without the identity check, directors and company secretary, its secrets redacted.
  r := public.svc_export_rows(o, 'orgs', null, 1000);
  assert jsonb_array_length(r->'rows') = 1 and r->'rows'->0->>'id' = o::text and r->'rows'->0->>'identity' = '[redacted]' and r->'rows'->0->>'directors' = '[redacted]'
     and r->'rows'->0->>'company_secretary' = '[redacted]' and r->'rows'->0->>'invoice_portal_token' = '[redacted]' and r->'rows'->0->>'name' is not null,
    format('export_rows: the business''s row, got %s', r);
  -- Every exported table: a first page of one row, and the next page when there is one.
  for v_t in select jsonb_array_elements_text(t) loop
    r := public.svc_export_rows(o, v_t, null, 1);
    if r->>'next' is not null then
      r2 := public.svc_export_rows(o, v_t, r->>'next', 1);
      assert r2->'rows'->0 is distinct from r->'rows'->0, format('export_rows: %s next page', v_t);
      v_followed := v_followed + 1;
    end if;
  end loop;
  assert v_followed >= 10, format('export_rows: next pages followed in %s tables', v_followed);
  perform tests.throws(format($q$select public.svc_export_done(%L, '{"path":"practice/elsewhere/x.zip","sha256":"%s","bytes":10}')$q$, c, repeat('ab', 32)), '%path%');
  perform public.svc_export_done(c, jsonb_build_object('path', 'practice/' || pr || '/exports/' || c || '/x.zip', 'sha256', repeat('ab', 32), 'bytes', 10));
  perform tests.as_postgres();
  assert exists (select 1 from activity_log where org_id = o and action = 'export'), 'export_rows: logged';
end $$;

-- test: portal_reads
-- The portal's home lists the clients with their mode, intake, due-diligence state, read-only state and retention, and the
-- full mandates kept read-only; it says whether the firm may run full mandates. A client's page carries its mandate and
-- the opposing parties recorded for it. Leads choose download-only and the alert address (one of the firm's).
do $$
declare pr uuid := tests.id('pr'); c uuid; o uuid; h jsonb; v_row jsonb; m jsonb; v_intake uuid;
begin
  c := tests.full_client(pr, tests.id('partner'));
  o := (select org_id from practice_clients where id = c);
  v_intake := (select intake_id from practice_clients where id = c);
  perform tests.as_user(tests.id('partner'));
  h := public.practice_home(pr);
  assert (h->>'can_full')::boolean and exists (select 1 from jsonb_array_elements(h->'clients') x where x->>'mode' = 'full'), 'portal_reads: home';
  select y into v_row from jsonb_array_elements(h->'clients') y where y->>'id' = c::text;
  assert v_row->>'intake_id' = v_intake::text and v_row->>'dd_incomplete' = 'false' and v_row->>'read_only' = 'false'
     and v_row->'retain_until' = 'null'::jsonb, format('portal_reads: client row, got %s', v_row);
  select y into v_row from jsonb_array_elements(h->'clients') y where y->>'id' = tests.id('ec')::text;
  assert v_row->>'status' = 'ended' and v_row->>'read_only' = 'true' and (v_row->>'retain_until')::date = (current_date + interval '6 years')::date, 'portal_reads: kept client listed';
  assert not exists (select 1 from jsonb_array_elements(h->'past_clients') y where y->>'id' = tests.id('ec')::text)
     and exists (select 1 from jsonb_array_elements(h->'past_clients') y where y->>'id' = tests.id('hc')::text), 'portal_reads: past clients, not the kept one twice';
  m := public.practice_client(c);
  assert m->'mandate' ? 'director', 'portal_reads: client mandate';
  assert m->'client'->>'mode' = 'full' and m->'client' ? 'end_kind' and m->'client'->>'intake_id' = v_intake::text, 'portal_reads: client';
  assert (m->'mandate'->>'payments_open')::boolean = false and m->'mandate'->>'send_mode' = 'send' and m->'mandate'->'director' = 'null'::jsonb
     and m->'mandate'->'letter'->>'status' = 'completed' and m->'mandate'->>'engagement_partner_id' = tests.id('partner_pm')::text, format('portal_reads: mandate, got %s', m->'mandate');
  assert public.practice_client(tests.id('ec'))->'mandate'->>'read_only_at' is not null, 'portal_reads: kept client''s mandate';
  assert public.practice_client(tests.id('hc'))->'mandate' = 'null'::jsonb, 'portal_reads: no mandate once handed over';
  perform public.practice_opposing_save(pr, jsonb_build_object('client_id', c, 'name', 'Rival Haulage Ltd'));
  assert public.practice_client(c)->'opposing_parties'->0->>'name' = 'Rival Haulage Ltd', 'portal_reads: opposing parties';
  perform public.practice_set_send_mode(c, 'download_only');
  perform tests.as_postgres();
  assert (select send_mode from orgs where id = o) = 'download_only', 'portal_reads: send mode';
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format('select public.practice_set_send_mode(%L, %L)', c, 'loud'), '%send%download%');
  perform tests.throws(format('select public.practice_set_alert_email(%L, %L)', c, 'someone@client.example.test'), '%firm%');
  perform public.practice_set_alert_email(c, ' Alerts@Firm.example.test ');
  assert public.practice_client(c)->'mandate'->>'alert_email' = 'alerts@firm.example.test', 'portal_reads: alert email';
  perform public.practice_set_alert_email(c, null);
  assert public.practice_client(c)->'mandate'->'alert_email' = 'null'::jsonb, 'portal_reads: alert email cleared';
  perform tests.throws(format('select public.practice_set_send_mode(%L, %L)', tests.id('ec'), 'send'), '%full mandate%');
  -- A director asked and a handover started: their contact details for leads.
  perform public.practice_handover_start(c, '{"email":"portal.owner@client.example.test","name":"Portal Owner"}');
  perform tests.as_postgres();
  insert into practice_director_confirmations (practice_id, client_id, name, email) values (pr, c, 'Tunde Bello', 'tunde.portal@director.example.test');
  perform tests.as_user(tests.id('partner'));
  m := public.practice_client(c);
  assert m->'mandate'->'director'->>'name' = 'Tunde Bello' and m->'mandate'->'director'->>'email' = 'tunde.portal@director.example.test'
     and m->'mandate'->'handover'->>'email' = 'portal.owner@client.example.test' and m->'mandate'->'handover'->>'status' = 'pending', 'portal_reads: contacts for leads';
  -- Staff assigned to the client: no opposing parties, no contact details, no settings.
  perform public.practice_assign(c, tests.id('ada_pm'), true);
  perform tests.as_user(tests.id('ada'));
  m := public.practice_client(c);
  assert m->'opposing_parties' = '[]'::jsonb and m->'mandate' ? 'send_mode', 'portal_reads: staff';
  assert m->'mandate'->'director'->>'status' = 'pending' and m->'mandate'->'director'->'name' = 'null'::jsonb and m->'mandate'->'director'->'email' = 'null'::jsonb
     and m->'mandate'->'handover'->>'status' = 'pending' and m->'mandate'->'handover'->'email' = 'null'::jsonb, format('portal_reads: no contacts for staff, got %s', m->'mandate');
  perform tests.throws(format('select public.practice_set_send_mode(%L, %L)', c, 'send'), '42501%');
  perform tests.as_postgres();
end $$;

-- test: admin_reads
-- TaxStreem's mandates page: director confirmations to review, the practices that run full mandates, the open flags; a
-- flag resolved with a note, audited.
do $$
declare pr uuid := tests.id('pr'); f uuid; d uuid; r jsonb; fr uuid;
begin
  insert into practice_mandate_flags (practice_id, kind, detail) values (pr, 'duplicate_company', '{"matched_on": "rc_number"}') returning id into f;
  insert into practice_director_confirmations (practice_id, client_id, name, email, status, ip, flags)
  values (pr, tests.id('ec'), 'Tunde Bello', 'tunde@director.example.test', 'review', '203.0.113.7', '{"review_reason": "firm_ip"}') returning id into d;
  insert into practice_mandate_flags (practice_id, client_id, kind, detail) values (pr, tests.id('ec'), 'director_review', jsonb_build_object('confirmation_id', d))
  returning id into fr;
  perform tests.as_user(tests.id('admin'), 'aal2');
  r := public.admin_mandates();
  assert public.admin_mandates() ? 'reviews' and public.admin_mandates() ? 'flags', 'admin_reads';
  assert (select x->>'ip' = '203.0.113.7' and x->'practice'->>'name' = 'Handover Partners' and x->'director'->>'name' = 'Tunde Bello' and x->'business'->>'name' is not null
          from jsonb_array_elements(r->'reviews') x where x->>'id' = d::text), format('admin_reads: review, got %s', r->'reviews');
  assert (select (x->>'full_clients')::int >= 1 and (x->>'partner_verified')::boolean and x->'suspended_at' = 'null'::jsonb
          from jsonb_array_elements(r->'practices') x where x->>'id' = pr::text), 'admin_reads: practice';
  assert exists (select 1 from jsonb_array_elements(r->'flags') x where x->>'id' = f::text and x->>'kind' = 'duplicate_company'), 'admin_reads: flags';
  perform tests.throws(format('select public.admin_mandate_flag_resolve(%L, %L)', f, 'ok'), '%5 characters%');
  perform tests.throws(format('select public.admin_mandate_flag_resolve(%L, %L)', fr, 'Looked at it'), '%confirmation%');
  r := public.admin_mandate_flag_resolve(f, 'Checked with the CAC record');
  assert r->>'id' = f::text and r->>'resolved_at' is not null, 'admin_reads: resolved';
  assert not exists (select 1 from jsonb_array_elements(public.admin_mandates()->'flags') x where x->>'id' = f::text), 'admin_reads: no longer open';
  perform tests.throws(format('select public.admin_mandate_flag_resolve(%L, %L)', f, 'Checked again'), '%resolved already%');
  perform tests.as_postgres();
  assert exists (select 1 from admin_audit where action = 'mandate_flag_resolved' and target = f::text), 'admin_reads: audited';
  perform tests.as_user(tests.id('reviewer'), 'aal2');
  assert public.admin_mandates() ? 'practices', 'admin_reads: a reviewer reads it';
  perform tests.as_user(tests.id('partner'));
  perform tests.throws($q$select public.admin_mandates()$q$, '%only for TaxStreem%');
  perform tests.as_postgres();
end $$;

-- test: end_helpers_revoked
do $$
declare f text;
begin
  foreach f in array array['private.org_pause_all(uuid)', 'private.export_tables()', 'private.seat_exempt(uuid, uuid)', 'private.require_not_kept(date)',
    'private.orgs_retention_guard()', 'private.outbound_check(uuid, text, text, text)', 'private.practice_sync_seats(uuid)', 'private.meter_usage(uuid, text)',
    'private.enforce_plan()', 'private.mandate_client_require(uuid)', 'private.export_redact(jsonb)', 'private.export_after(text, text[])',
    'private.payments_open(uuid)', 'private.require_payments_open(uuid)', 'private.handover_pending(text, jsonb)', 'private.handover_pending_text(text)',
    'private.identity_json(uuid, boolean)'] loop
    assert not has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute'), format('end_helpers_revoked: %s', f);
  end loop;
  foreach f in array array['public.svc_export_rows(uuid, text, text, integer)', 'public.svc_export_ledger(uuid, text, integer)', 'public.svc_export_activity(uuid, text, integer)',
    'public.svc_export_done(uuid, jsonb)'] loop
    assert not has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute')
       and has_function_privilege('service_role', f, 'execute'), format('end_helpers_revoked: %s for the service only', f);
  end loop;
  foreach f in array array['public.practice_handover_start(uuid, jsonb)', 'public.practice_handover_accept(text)', 'public.practice_end_mandate(uuid, jsonb)',
    'public.practice_export_begin(uuid)', 'public.practice_set_send_mode(uuid, text)', 'public.practice_set_alert_email(uuid, text)',
    'public.practice_set_engagement_partner(uuid, uuid)', 'public.admin_mandates()', 'public.admin_mandate_flag_resolve(uuid, text)'] loop
    assert has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute'), format('end_helpers_revoked: %s for signed-in people', f);
  end loop;
  -- The storage policy's helper stays the signed-in person's to call; the retention guard runs as its owner.
  assert has_function_privilege('authenticated', 'private.document_may_delete(text)', 'execute')
     and not has_function_privilege('anon', 'private.document_may_delete(text)', 'execute'), 'end_helpers_revoked: document_may_delete for signed-in people';
  assert (select prosecdef and proconfig is not null from pg_proc where oid = 'private.orgs_retention_guard()'::regprocedure), 'end_helpers_revoked: retention guard as its owner';
  assert not has_table_privilege('authenticated', 'public.practice_handovers', 'select') and not has_table_privilege('anon', 'public.practice_handovers', 'select')
     and not has_table_privilege('authenticated', 'public.practice_handovers', 'insert') and (select relrowsecurity from pg_class where oid = 'public.practice_handovers'::regclass),
    'end_helpers_revoked: table practice_handovers';
end $$;

rollback;
