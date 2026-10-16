-- The test notification opens the app's home, which picks the phone or full app for the device.
create or replace function public.send_test_notification() returns uuid
language plpgsql security definer set search_path = public, private as $$
declare v uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  insert into notifications (user_id, kind, title, body, url)
  values (auth.uid(), 'test', 'Notifications are on', 'Counta will tell you here when a count, an invoice or a transfer needs you.', '/')
  returning id into v;
  return v;
end $$;
