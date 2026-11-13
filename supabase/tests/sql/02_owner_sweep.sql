-- The owner sweep: every owner comparison goes through the resolver. In a business the practice runs under full mandate the
-- firm's acting owners pass the owner's checks (user-facing and service functions), and what went to the owner, or acted as
-- the owner, goes to the business's contact. An ordinary business is unchanged (the golden baseline proves it in full; the
-- last two tests keep a few of its edges here).
begin;

-- Runs a statement as the current caller and undoes whatever it did: its error, or null when it went through.
create function tests.dry_run(p_sql text) returns text
language plpgsql as $$
begin
  execute p_sql;
  raise exception 'tests.dry_run: went through';
exception when others then
  return case when sqlerrm = 'tests.dry_run: went through' then null else sqlstate || ': ' || sqlerrm end;
end $$;
grant execute on function tests.dry_run(text) to authenticated, service_role;

-- Fixture: a practice (partner, manager) running a business under full mandate; an ordinary business (owner, admin).
do $$
declare v_partner uuid; v_manager uuid; v_pr uuid; v_o uuid; v_owner uuid; v_admin uuid; v_ord uuid;
begin
  v_partner := tests.remember('partner', tests.user('partner@firm.example.test', 'Ngozi Partner'));
  v_manager := tests.remember('manager', tests.user('manager@firm.example.test', 'Tunde Manager'));
  v_owner := tests.remember('owner', tests.user('sw.owner@example.test', 'Ada Owner'));
  v_admin := tests.remember('admin', tests.user('sw.admin@example.test', 'Femi Admin'));
  v_pr := tests.remember('pr', tests.practice(v_partner, 'Sweep Partners', true));
  perform tests.practice_member(v_pr, v_manager, 'manager');
  v_o := tests.remember('o', tests.managed_org(v_pr, 'Sweep Managed Ltd'));
  perform tests.remember('partner_seat', (select id from members where org_id = v_o and user_id = v_partner));
  perform tests.remember('manager_seat', (select id from members where org_id = v_o and user_id = v_manager));
  v_ord := tests.remember('ord', tests.org(v_owner, 'Sweep Ordinary Ltd'));
  perform tests.remember('admin_seat', tests.member(v_ord, v_admin, 'admin'));
  perform tests.as_postgres();
end $$;

-- test: sweep_user_facing
do $$
declare o uuid := tests.id('o');
begin
  perform tests.as_user(tests.id('partner'));
  assert (public.get_team(o)->>'is_owner')::boolean, 'sweep_user_facing: get_team is_owner';
  assert (public.portal_logins(o)->>'can_manage')::boolean, 'sweep_user_facing: portal_logins can_manage';
  assert coalesce(tests.error_of(format($q$select public.close_year(%L, current_date)$q$, o)), '') not like '%Only the owner%',
    'sweep_user_facing: close_year passes owner check';
  perform tests.as_postgres();
end $$;

-- test: sweep_user_facing_checks
-- Each owner-only check lets the acting owner through (whatever the function says next is not the owner refusal).
do $$
declare o uuid := tests.id('o'); r record; e text;
begin
  perform tests.as_user(tests.id('partner'));
  for r in select * from (values
    ('close_books', format($q$select public.close_books(%L, current_date)$q$, o), '%Only the owner closes the books%'),
    ('waive_close_step', format($q$select public.waive_close_step(%L, current_date, 'bank', 'No bank account yet')$q$, o), '%Only the owner can waive%'),
    ('identity_slip', format($q$select public.identity_slip(%L, %L)$q$, o, o::text || '/kyc/nin-slip-1.pdf'), '%Only the owner adds the NIN slip%'),
    ('portal_login_begin', format($q$select public.portal_login_begin(%L, 'lirs')$q$, o), '%Only the owner saves or removes%'),
    ('save_income_tax_setup', format($q$select public.save_income_tax_setup(%L, '{}')$q$, o), '%Only the owner changes how the business is taxed%'),
    ('set_transfer_settings', format($q$select public.set_transfer_settings(%L, '{}')$q$, o), '%Only the owner changes payment settings%'),
    ('transfer_name_check_start', format($q$select public.transfer_name_check_start(%L)$q$, o), '%Only the owner changes payment settings%'),
    ('update_payment_settings', format($q$select public.update_payment_settings(%L, '{}')$q$, o), '%Only the owner changes payment settings%'),
    ('update_sales_settings', format($q$select public.update_sales_settings(%L, '{}')$q$, o), '%Only the owner changes these settings%'),
    ('set_vat_charging', format($q$select public.set_vat_charging(%L, '{"charge": true}')$q$, o), '%Only the owner turns VAT%'),
    ('invite_member', format($q$select public.invite_member(%L, 'Bisi Admin', 'bisi.admin@example.test', 'admin')$q$, o), '%Only the owner makes someone an admin%'),
    ('save_role_permissions', format($q$select public.save_role_permissions(%L, 'admin', '{}')$q$, o), '%Only the owner changes what admins can do%'),
    ('referral_connect', format($q$select public.referral_connect(%L, 'NOCODE')$q$, o), '%Only the owner of the business connects%'),
    ('record_takings', format($q$select public.record_takings(%L, %L, current_date, 1000, 0, 0)$q$, o, (select id from locations where org_id = o and is_main)),
      '%Only the owner or a manager records takings%'),
    ('save_voice_settings', format($q$select public.save_voice_settings(%L, '{"voice_lang": "pcm"}')$q$, o), '%Only the owner or a manager chooses the voice%'),
    ('prepare_reminder_call', format($q$select public.prepare_reminder_call(%L, 'count_due')$q$, tests.id('manager_seat')), '%Only owners and managers%')
  ) t(fn, sql, refusal) loop
    e := tests.dry_run(r.sql);
    assert coalesce(e, '') not like r.refusal, format('sweep_user_facing_checks: %s refused the acting owner (%s)', r.fn, e);
  end loop;
  perform tests.as_postgres();
end $$;

-- test: sweep_user_facing_flags
do $$
declare o uuid := tests.id('o');
begin
  perform tests.as_user(tests.id('partner'));
  assert (public.transfer_settings(o)->>'can_change')::boolean, 'sweep_user_facing_flags: transfer_settings can_change';
  assert (public.vat_status(o)->>'can_change')::boolean, 'sweep_user_facing_flags: vat_status can_change';
  assert (public.tax_profile(o)->>'is_owner')::boolean, 'sweep_user_facing_flags: tax_profile is_owner';
  assert (public.get_payments(o, '{}')->'can'->>'settings')::boolean, 'sweep_user_facing_flags: get_payments can settings';
  assert (public.voice_settings(o)->>'can_edit')::boolean, 'sweep_user_facing_flags: voice_settings can_edit';
  assert (public.leak_radar(o, 90)->>'can_see_people')::boolean, 'sweep_user_facing_flags: leak_radar can_see_people';
  assert (public.pos_overview(o)->'can'->>'connect')::boolean, 'sweep_user_facing_flags: pos_overview can connect';
  assert (public.guide_state(o)->'org'->>'is_owner')::boolean, 'sweep_user_facing_flags: guide_state is_owner';
  assert (public.identity_state(o)->>'can_check')::boolean, 'sweep_user_facing_flags: identity_state can_check';
  perform tests.as_definer(tests.id('partner'));
  assert (private.pit_access(o)->>'owner')::boolean, 'sweep_user_facing_flags: pit_access owner';
  assert (private.pos_require_owner(o)).id = tests.id('partner_seat'), 'sweep_user_facing_flags: pos_require_owner';
  perform tests.as_postgres();
end $$;

-- test: sweep_svc
do $$
declare o uuid := tests.id('o');
begin
  perform tests.as_service();
  assert coalesce(tests.error_of(format($q$select public.svc_identity_nin(%L, %L, '1234', 'Ada', null, 'Eze')$q$, tests.id('partner'), o)), '')
    not like '%Only the owner%', 'sweep_svc: svc_identity_nin owner check';
  assert coalesce(tests.dry_run(format($q$select public.svc_identity_slip(%L, %L, '{}')$q$, tests.id('partner'), o)), '')
    not like '%Only the owner%', 'sweep_svc: svc_identity_slip owner check';
  assert coalesce(tests.dry_run(format($q$select public.svc_pos_connection_save(%L)$q$,
      jsonb_build_object('org_id', o, 'member_id', tests.id('partner_seat'), 'provider', 'moniepoint'))), '')
    not like '%Only the owner%', 'sweep_svc: svc_pos_connection_save owner check';
  perform tests.as_postgres();
end $$;

-- test: sweep_recipient
do $$
declare o uuid := tests.id('o');
begin
  perform tests.as_user(tests.id('partner'));
  assert public.get_alert_prefs(o)->'owner'->>'email' = 'partner@firm.example.test', 'sweep_recipient: alert prefs contact';
  perform tests.as_postgres();
  perform private.alert_send(o, 'test', 'k1', array['email'], '{"title":"T","body":"B"}');
  assert (select to_address from messages where org_id = o and template = 'alert') = 'partner@firm.example.test', 'sweep_recipient: alert email to org_contact';
  perform tests.as_postgres();
end $$;

-- test: sweep_actor
-- Postings that act as the owner act as the contact's place.
do $$
declare o uuid := tests.id('o'); v_charge uuid;
begin
  assert (private.pos_owner_member(o)).id = tests.id('partner_seat'), 'sweep_actor: POS postings act as the contact';
  assert (private.prism_owner(o)).id = tests.id('partner_seat'), 'sweep_actor: Prism postings act as the contact';
  insert into subscription_charges (org_id, plan_id, billing, amount, method, kind, tx_ref)
  values (o, (select id from plans order by sort limit 1), 'month', 5000, 'card', 'start', 'SWEEP-TEST-1') returning id into v_charge;
  perform tests.as_service();
  assert public.svc_subscription_charge(v_charge)->'org'->>'email' = 'partner@firm.example.test', 'sweep_actor: the checkout email is the contact''s';
  perform tests.as_postgres();
end $$;

-- test: sweep_policy_helper
-- The documents bucket's policy helper still runs as the signed-in person, and lets the acting owner remove another's upload.
do $$
declare o uuid := tests.id('o'); v_doc uuid; v_path text := tests.id('o')::text || '/documents/other/sweep-test-upload.pdf';
begin
  insert into documents (org_id, cat, folder, name, path, source, uploaded_by)
  values (o, 'other', 'Other', 'Sweep upload', v_path, 'upload', tests.id('manager_seat')) returning id into v_doc;
  assert has_function_privilege('authenticated', 'private.document_may_delete(text)', 'execute')
     and not has_function_privilege('anon', 'private.document_may_delete(text)', 'execute'),
    'sweep_policy_helper: document_may_delete stays callable by the signed-in person';
  perform tests.as_user(tests.id('partner'));
  assert private.document_may_delete(v_path), 'sweep_policy_helper: the acting owner may remove another''s upload';
  assert (public.document_delete(o, v_doc)->>'ok')::boolean, 'sweep_policy_helper: document_delete by the acting owner';
  perform tests.as_postgres();
end $$;

-- test: sweep_ordinary_unchanged
-- An ordinary business's admin is still not the owner, and the owner still is.
do $$
declare ord uuid := tests.id('ord');
begin
  perform tests.as_user(tests.id('admin'));
  assert not (public.get_team(ord)->>'is_owner')::boolean, 'sweep_ordinary_unchanged: admin is not the owner';
  assert tests.dry_run(format($q$select public.close_year(%L, current_date)$q$, ord)) like '42501: Only the owner closes the year.%',
    'sweep_ordinary_unchanged: admin cannot close the year';
  assert tests.dry_run(format($q$select public.save_voice_settings(%L, '{}')$q$, ord)) like '42501: Only the owner or a manager chooses the voice.%',
    'sweep_ordinary_unchanged: admin cannot choose the voice';
  perform tests.as_user(tests.id('owner'));
  assert (public.get_team(ord)->>'is_owner')::boolean, 'sweep_ordinary_unchanged: the owner is the owner';
  perform tests.as_service();
  assert tests.error_of(format($q$select public.svc_identity_slip(%L, %L, '{}')$q$, tests.id('admin'), ord)) like '42501: Only the owner adds the NIN slip.%',
    'sweep_ordinary_unchanged: svc_identity_slip refuses an admin';
  perform tests.as_postgres();
  assert (private.pos_owner_member(ord)).user_id = tests.id('owner') and (private.prism_owner(ord)).user_id = tests.id('owner'),
    'sweep_ordinary_unchanged: postings act as the owner';
  perform tests.as_postgres();
end $$;

-- test: sweep_invited_owner
-- A business Prism made has an owner who is still an invitation: Prism postings and the checkout email keep using that place.
do $$
declare v_org uuid; v_ow uuid; v_charge uuid;
begin
  insert into orgs (name, email, is_sample, prism_merchant) values ('Sweep Prism Merchant Ltd', 'shop@merchant.example.test', false, true) returning id into v_org;
  insert into members (org_id, email, display_name, role, title, status) values (v_org, 'boss@merchant.example.test', 'Bola Boss', 'owner', 'Owner', 'invited')
  returning id into v_ow;
  assert (private.prism_owner(v_org)).id = v_ow, 'sweep_invited_owner: Prism postings act as the invited owner';
  insert into subscription_charges (org_id, plan_id, billing, amount, method, kind, tx_ref)
  values (v_org, (select id from plans order by sort limit 1), 'month', 5000, 'card', 'start', 'SWEEP-TEST-2') returning id into v_charge;
  perform tests.as_service();
  assert public.svc_subscription_charge(v_charge)->'org'->>'email' = 'boss@merchant.example.test', 'sweep_invited_owner: the checkout email is the invited owner''s';
  perform tests.as_postgres();
end $$;

-- test: sweep_private_revoked
do $$
begin
  assert not has_function_privilege('authenticated', 'private.chat_context(chat_links)', 'execute')
     and not has_function_privilege('anon', 'private.chat_context(chat_links)', 'execute')
     and not has_function_privilege('authenticated', 'private.notify_perm(uuid,text,text,text,text,text,text,uuid,uuid)', 'execute')
     and not has_function_privilege('authenticated', 'private.prism_owner(uuid)', 'execute')
     and not has_function_privilege('authenticated', 'private.pos_owner_member(uuid)', 'execute'),
    'sweep_private_revoked: redefined private functions are not callable by the signed-in person';
  perform tests.as_postgres();
end $$;

rollback;
