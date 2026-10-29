-- Counta · Invitations to the admin portal's team (6 November)
--
-- Admin team, Add used to give an existing Counta account the admin or reviewer role and send nothing, so the person was
-- never told, and someone without a Counta account could not be added at all. Now:
-- - Someone who already has a Counta account gets the role at once, and an email saying so with the link to the portal.
-- - Someone without one gets an invitation by email. Its link works once, for seven days: they sign up (or sign in) with
--   that address, confirm it, and accept, and the role applies then.
-- - Every admin is told by email when someone is added, invited, or accepts an invitation.
-- - Waiting invitations are listed with Resend and Withdraw, and a person who has not set up their authenticator yet can be
--   sent the welcome again.
-- The emails are written here and sent by the admin edge function (Resend). Links carry a one-time token; only its SHA-256
-- is kept, and a resend replaces it, so an older link stops working.

-- ---------------------------------------------------------------------------
-- 1. The invitations, and whether each person on the team has had the welcome
-- ---------------------------------------------------------------------------
create table if not exists public.admin_invites (
  id uuid primary key default gen_random_uuid(),
  email text not null check (email = lower(btrim(email)) and email ~* '^[A-Z0-9._%+-]+@[A-Z0-9-]+(\.[A-Z0-9-]+)*\.[A-Z]{2,}$'),
  role text not null check (role in ('admin', 'reviewer')),
  status text not null default 'open' check (status in ('open', 'accepted', 'withdrawn')),
  token_hash text unique,
  token_expires timestamptz,
  sent_at timestamptz,
  sent_count int not null default 0,
  last_error text,
  invited_by uuid references auth.users(id) on delete set null,
  invited_at timestamptz not null default now(),
  closed_by uuid references auth.users(id) on delete set null,
  closed_at timestamptz
);
-- One invitation waits for an address at a time; inviting it again brings that one up to date.
create unique index if not exists admin_invites_open_email on public.admin_invites(email) where status = 'open';
create index if not exists admin_invites_invited_by on public.admin_invites(invited_by);
create index if not exists admin_invites_closed_by on public.admin_invites(closed_by);
alter table public.admin_invites enable row level security;
revoke all on public.admin_invites from anon, authenticated;

alter table public.platform_admins add column if not exists welcomed_at timestamptz;
alter table public.platform_reviewers add column if not exists welcomed_at timestamptz;
-- Someone who has already set up an authenticator has clearly found the portal.
update public.platform_admins p set welcomed_at = p.added_at
  where p.welcomed_at is null and exists (select 1 from auth.mfa_factors f where f.user_id = p.user_id and f.status = 'verified');
update public.platform_reviewers p set welcomed_at = p.added_at
  where p.welcomed_at is null and exists (select 1 from auth.mfa_factors f where f.user_id = p.user_id and f.status = 'verified');

create or replace function private.staff_role_words(p_role text) returns text
language sql immutable set search_path = public as $$
  select case p_role when 'admin' then 'an admin' else 'a reviewer' end
$$;

-- A person's name as they gave it at sign-up, else their email.
create or replace function private.staff_name(p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(btrim(u.raw_user_meta_data->>'full_name'), ''), u.email) from auth.users u where u.id = p_user
$$;

-- ---------------------------------------------------------------------------
-- 2. Adding someone: the role at once when they have an account, otherwise an invitation
-- ---------------------------------------------------------------------------
create or replace function public.admin_add_staff(p_email text, p_role text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_email text := lower(btrim(coalesce(p_email, ''))); v_user uuid; v_had boolean; v_inv public.admin_invites;
begin
  perform private.require_staff();
  if p_role is null or p_role not in ('admin', 'reviewer') then raise exception 'Choose admin or reviewer.'; end if;
  if v_email !~* '^[A-Z0-9._%+-]+@[A-Z0-9-]+(\.[A-Z0-9-]+)*\.[A-Z]{2,}$' then raise exception 'Enter their email address.'; end if;
  select id into v_user from auth.users where lower(email) = v_email;
  if v_user is not null then
    if p_role = 'admin' then
      v_had := exists (select 1 from platform_admins where user_id = v_user);
      insert into platform_admins (user_id, added_by) values (v_user, auth.uid()) on conflict do nothing;
    else
      v_had := exists (select 1 from platform_reviewers where user_id = v_user);
      insert into platform_reviewers (user_id, added_by) values (v_user, auth.uid()) on conflict do nothing;
    end if;
    -- An invitation still waiting for the address is no longer needed.
    update admin_invites set status = 'accepted', closed_by = auth.uid(), closed_at = now(), token_expires = least(token_expires, now())
      where email = v_email and status = 'open';
    if v_had then return jsonb_build_object('status', 'already', 'user_id', v_user, 'email', v_email, 'role', p_role); end if;
    perform private.audit('add_staff', v_email, jsonb_build_object('role', p_role));
    return jsonb_build_object('status', 'added', 'user_id', v_user, 'email', v_email, 'role', p_role);
  end if;
  insert into admin_invites (email, role, invited_by) values (v_email, p_role, auth.uid())
  on conflict (email) where status = 'open' do update set role = excluded.role, invited_by = excluded.invited_by, invited_at = now()
  returning * into v_inv;
  perform private.audit('invite_staff', v_email, jsonb_build_object('role', p_role));
  return jsonb_build_object('status', 'invited', 'invite_id', v_inv.id, 'email', v_email, 'role', p_role);
end $$;

-- The team, the invitations still waiting, and the record of changes.
create or replace function public.admin_staff() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_staff();
  return jsonb_build_object(
    'staff', (select coalesce(jsonb_agg(x order by x->>'role', x->>'email'), '[]'::jsonb) from (
        select jsonb_build_object('user_id', u.id, 'email', u.email, 'role', 'admin', 'added_at', a.added_at, 'me', u.id = auth.uid(),
          'authenticator', exists (select 1 from auth.mfa_factors f where f.user_id = u.id and f.status = 'verified'), 'welcomed_at', a.welcomed_at) x
        from platform_admins a join auth.users u on u.id = a.user_id
        union all
        select jsonb_build_object('user_id', u.id, 'email', u.email, 'role', 'reviewer', 'added_at', r.added_at, 'me', u.id = auth.uid(),
          'authenticator', exists (select 1 from auth.mfa_factors f where f.user_id = u.id and f.status = 'verified'), 'welcomed_at', r.welcomed_at)
        from platform_reviewers r join auth.users u on u.id = r.user_id) s),
    'invites', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'email', i.email, 'role', i.role, 'invited_at', i.invited_at,
        'invited_by', u.email, 'sent_at', i.sent_at, 'expires', i.token_expires, 'expired', i.token_expires is not null and i.token_expires < now(),
        'last_error', i.last_error) order by i.invited_at desc), '[]'::jsonb)
      from admin_invites i left join auth.users u on u.id = i.invited_by where i.status = 'open'),
    'audit', (select coalesce(jsonb_agg(jsonb_build_object('at', a.at, 'email', u.email, 'action', a.action, 'target', a.target, 'detail', a.detail) order by a.at desc), '[]'::jsonb)
      from (select * from admin_audit order by at desc limit 200) a left join auth.users u on u.id = a.user_id));
end $$;

-- Sending an invitation again (the admin edge function sends it, with a fresh link). Five a day at most.
create or replace function public.admin_resend_staff_invite(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v public.admin_invites;
begin
  perform private.require_staff();
  select * into v from admin_invites where id = p_id;
  if not found or v.status <> 'open' then raise exception 'That invitation was already accepted or withdrawn.'; end if;
  if v.sent_at > now() - interval '1 day' and v.sent_count >= 5 then
    raise exception 'This invitation has been sent five times today. Try again tomorrow.';
  end if;
  perform private.audit('resend_staff_invite', v.email, jsonb_build_object('role', v.role));
  return jsonb_build_object('invite_id', v.id, 'email', v.email, 'role', v.role);
end $$;

create or replace function public.admin_withdraw_staff_invite(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v public.admin_invites;
begin
  perform private.require_staff();
  update admin_invites set status = 'withdrawn', closed_by = auth.uid(), closed_at = now(), token_expires = least(coalesce(token_expires, now()), now())
    where id = p_id and status = 'open' returning * into v;
  if not found then raise exception 'That invitation was already accepted or withdrawn.'; end if;
  perform private.audit('withdraw_staff_invite', v.email, jsonb_build_object('role', v.role));
  return jsonb_build_object('withdrawn', v.id, 'email', v.email);
end $$;

-- Sending the welcome again to someone on the team (the admin edge function sends it). Once a minute at most.
create or replace function public.admin_staff_resend_welcome(p_user uuid, p_role text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_email text; v_at timestamptz; v_found boolean;
begin
  perform private.require_staff();
  if p_role is null or p_role not in ('admin', 'reviewer') then raise exception 'Choose admin or reviewer.'; end if;
  if p_role = 'admin' then
    select true, welcomed_at into v_found, v_at from platform_admins where user_id = p_user;
  else
    select true, welcomed_at into v_found, v_at from platform_reviewers where user_id = p_user;
  end if;
  if v_found is null then raise exception 'They are no longer on the admin team.'; end if;
  if v_at > now() - interval '1 minute' then raise exception 'The welcome went a moment ago. Give it a minute to arrive.'; end if;
  select email into v_email from auth.users where id = p_user;
  perform private.audit('resend_staff_welcome', v_email, jsonb_build_object('role', p_role));
  return jsonb_build_object('user_id', p_user, 'email', v_email, 'role', p_role);
end $$;

-- ---------------------------------------------------------------------------
-- 3. The emails' words, for the admin edge function. An invitation gets a fresh link each time it is sent.
-- ---------------------------------------------------------------------------
create or replace function public.svc_staff_mail(p_kind text, p_id uuid, p_role text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_app text; v public.admin_invites; v_token text; v_by uuid; v_by_name text; v_by_email text; v_to text; v_name text; v_found boolean;
begin
  v_app := coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app');
  if p_kind = 'invite' then
    select * into v from admin_invites where id = p_id and status = 'open' for update;
    if not found then return null; end if;
    if v.sent_at > now() - interval '1 day' and v.sent_count >= 5 then
      raise exception 'This invitation has been sent five times today. Try again tomorrow.';
    end if;
    v_token := 'sa_' || encode(extensions.gen_random_bytes(24), 'hex');
    update admin_invites set token_hash = encode(extensions.digest(v_token, 'sha256'), 'hex'), token_expires = now() + interval '7 days',
      sent_count = case when sent_at > now() - interval '1 day' then sent_count + 1 else 1 end, sent_at = now() where id = v.id;
    v_by_name := private.staff_name(v.invited_by);
    select email into v_by_email from auth.users where id = v.invited_by;
    return jsonb_build_object('to', v.email, 'reply_to', v_by_email, 'link', v_app || '/admin/join?t=' || v_token,
      'subject', coalesce(v_by_name, 'TaxStreem') || ' invited you to the Counta admin portal',
      'heading', 'Join TaxStreem''s Counta admin portal', 'greet', null,
      'lines', jsonb_build_array(
        coalesce(v_by_name, 'A TaxStreem admin') || ' has invited you to be ' || private.staff_role_words(v.role) || ' in the Counta admin portal, '
          || case v.role when 'admin' then 'where TaxStreem runs Counta for every business.' else 'where TaxStreem checks identity documents and accountants'' licences.' end,
        'Use the button to create your Counta account with ' || v.email || ', or to sign in if you already have one with that address. The link works once, for seven days.',
        'The portal then asks you to set up an authenticator app, such as Google Authenticator, Microsoft Authenticator or 1Password, and asks for its code each time you open it.'),
      'button', 'Accept the invitation',
      'footer', 'If you were not expecting this, you can ignore the email' || coalesce(' or tell ' || v_by_email, '') || '.');
  elsif p_kind = 'welcome' then
    if p_role = 'admin' then
      select true, added_by into v_found, v_by from platform_admins where user_id = p_id;
    elsif p_role = 'reviewer' then
      select true, added_by into v_found, v_by from platform_reviewers where user_id = p_id;
    end if;
    if v_found is null then return null; end if;
    select email, nullif(btrim(raw_user_meta_data->>'full_name'), '') into v_to, v_name from auth.users where id = p_id;
    if v_to is null then return null; end if;
    v_by_name := private.staff_name(v_by);
    select email into v_by_email from auth.users where id = v_by;
    return jsonb_build_object('to', v_to, 'reply_to', v_by_email, 'link', v_app || '/admin',
      'subject', case p_role when 'admin' then 'You are now an admin in the Counta admin portal' else 'You are now a reviewer in the Counta admin portal' end,
      'heading', 'Welcome to the Counta admin portal', 'greet', v_name,
      'lines', jsonb_build_array(
        coalesce(v_by_name, 'A TaxStreem admin') || ' has made you ' || private.staff_role_words(p_role) || ' in the Counta admin portal, '
          || case p_role when 'admin' then 'where TaxStreem runs Counta for every business.' else 'where TaxStreem checks identity documents and accountants'' licences.' end,
        'Sign in with ' || v_to || '. The first time you open the portal it asks you to set up an authenticator app, such as Google Authenticator, Microsoft Authenticator or 1Password, and it asks for the app''s code each time after that.'),
      'button', 'Open the admin portal',
      'footer', 'If you were not expecting this' || coalesce(', tell ' || v_by_email, ', tell TaxStreem') || '.');
  end if;
  return null;
end $$;

-- What became of the email: a welcome that went is noted; an invitation that did not go shows why on the page.
create or replace function public.svc_staff_mail_sent(p_kind text, p_id uuid, p_role text default null, p_error text default null) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if p_kind = 'invite' then
    update admin_invites set last_error = left(p_error, 300) where id = p_id;
  elsif p_kind = 'welcome' and p_error is null then
    if p_role = 'admin' then update platform_admins set welcomed_at = now() where user_id = p_id;
    else update platform_reviewers set welcomed_at = now() where user_id = p_id; end if;
  end if;
end $$;

-- People on the team who never had the welcome and have not set up their authenticator: someone added as an admin and a
-- reviewer gets one email, as an admin.
create or replace function public.svc_staff_welcome_pending() returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('user_id', x.user_id, 'role', x.role) order by x.added_at), '[]'::jsonb) from (
    select a.user_id, 'admin' as role, a.added_at from platform_admins a
     where a.welcomed_at is null and not exists (select 1 from auth.mfa_factors f where f.user_id = a.user_id and f.status = 'verified')
    union all
    select r.user_id, 'reviewer', r.added_at from platform_reviewers r
     where r.welcomed_at is null and not exists (select 1 from auth.mfa_factors f where f.user_id = r.user_id and f.status = 'verified')
       and not exists (select 1 from platform_admins a where a.user_id = r.user_id)) x
$$;

-- ---------------------------------------------------------------------------
-- 4. The link in the invitation: what it is for, shown before signing in, and accepting it
-- ---------------------------------------------------------------------------
create or replace function public.admin_staff_invite_preview(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v public.admin_invites;
begin
  if coalesce(p_token, '') !~ '^sa_[0-9a-f]{48}$' then return jsonb_build_object('status', 'invalid'); end if;
  select * into v from admin_invites where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
  if not found then return jsonb_build_object('status', 'invalid'); end if;
  return jsonb_build_object(
    'status', case when v.status = 'accepted' then 'used' when v.status = 'withdrawn' then 'withdrawn' when v.token_expires < now() then 'expired' else 'open' end,
    'email', v.email, 'role', v.role, 'invited_by', private.staff_name(v.invited_by));
end $$;

-- Accepting: signed in with the address the invitation went to, and that address confirmed.
create or replace function public.admin_accept_staff_invite(p_token text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v public.admin_invites; v_email text; v_confirmed timestamptz;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if coalesce(p_token, '') !~ '^sa_[0-9a-f]{48}$' then raise exception 'This invitation link is not complete. Open it from the email again.'; end if;
  select * into v from admin_invites where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex') for update;
  if not found then raise exception 'This invitation link has been replaced or used. Open the latest email, or ask for it to be sent again.'; end if;
  if v.status = 'withdrawn' then raise exception 'This invitation was withdrawn.'; end if;
  if v.status <> 'open' then raise exception 'This invitation has already been used.'; end if;
  if v.token_expires is null or v.token_expires < now() then raise exception 'This invitation has expired. Ask a TaxStreem admin to send it again.'; end if;
  select lower(email), email_confirmed_at into v_email, v_confirmed from auth.users where id = auth.uid();
  if v_email is distinct from v.email then
    raise exception 'This invitation is for %. Sign in with that email address to accept it.', v.email using errcode = '42501';
  end if;
  if v_confirmed is null then raise exception 'Confirm your email address first, then open the link again.' using errcode = '42501'; end if;
  if v.role = 'admin' then
    insert into platform_admins (user_id, added_by, welcomed_at) values (auth.uid(), v.invited_by, now()) on conflict (user_id) do nothing;
  else
    insert into platform_reviewers (user_id, added_by, welcomed_at) values (auth.uid(), v.invited_by, now()) on conflict (user_id) do nothing;
  end if;
  update admin_invites set status = 'accepted', closed_by = auth.uid(), closed_at = now(), token_expires = least(token_expires, now()) where id = v.id;
  perform private.audit('accept_staff_invite', v.email, jsonb_build_object('role', v.role));
  return jsonb_build_object('role', v.role, 'email', v.email);
end $$;

-- ---------------------------------------------------------------------------
-- 5. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function private.staff_role_words(text), private.staff_name(uuid) from public, anon, authenticated;
revoke all on function public.admin_resend_staff_invite(uuid), public.admin_withdraw_staff_invite(uuid), public.admin_staff_resend_welcome(uuid, text),
  public.admin_accept_staff_invite(text), public.admin_staff_invite_preview(text),
  public.svc_staff_mail(text, uuid, text), public.svc_staff_mail_sent(text, uuid, text, text), public.svc_staff_welcome_pending()
  from public, anon, authenticated;
grant execute on function public.admin_resend_staff_invite(uuid), public.admin_withdraw_staff_invite(uuid), public.admin_staff_resend_welcome(uuid, text),
  public.admin_accept_staff_invite(text) to authenticated;
grant execute on function public.admin_staff_invite_preview(text) to anon, authenticated;
grant execute on function public.svc_staff_mail(text, uuid, text), public.svc_staff_mail_sent(text, uuid, text, text), public.svc_staff_welcome_pending() to service_role;

-- ---------------------------------------------------------------------------
-- 6. People added before these emails existed: the welcome, once
-- ---------------------------------------------------------------------------
-- Asks the admin edge function (with the database's hook secret) to send the welcome to everyone on the team who has neither
-- had it nor set up an authenticator. The request goes when this transaction commits, and it is asked for only once.
do $$
begin
  if not exists (select 1 from private.config where key = 'staff_welcome_asked')
     and jsonb_array_length(public.svc_staff_welcome_pending()) > 0 then
    insert into private.config (key, value) values ('staff_welcome_asked', now()::text);
    perform private.call_function('admin', '{"action": "welcome_pending"}'::jsonb);
  end if;
end $$;
