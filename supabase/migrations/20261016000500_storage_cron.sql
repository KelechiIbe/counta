-- Counta — file storage (invoice images, product photos) and the nightly job

insert into storage.buckets (id, name, public, file_size_limit)
values ('documents', 'documents', false, 15728640),
       ('item-photos', 'item-photos', true, 5242880)
on conflict (id) do nothing;

-- Paths are always "<org_id>/<file>", so the first folder decides access.
create policy "documents read by members" on storage.objects for select to authenticated
  using (bucket_id = 'documents' and (select private.is_member_text((storage.foldername(name))[1])));
create policy "documents upload by members" on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and (select private.is_member_text((storage.foldername(name))[1])));
create policy "photos upload by members" on storage.objects for insert to authenticated
  with check (bucket_id = 'item-photos' and (select private.is_member_text((storage.foldername(name))[1])));
create policy "photos replace by members" on storage.objects for update to authenticated
  using (bucket_id = 'item-photos' and (select private.is_member_text((storage.foldername(name))[1])));

-- Nightly: quarantine expired batches, raise margin alerts.
create or replace function private.cron_nightly() returns void
language plpgsql security definer set search_path = public, private as $$
declare o record;
begin
  perform private.auto_quarantine_expired();
  for o in select id from orgs loop
    perform private.refresh_price_alerts_internal(o.id);
  end loop;
end $$;

create extension if not exists pg_cron;
select cron.schedule('counta-nightly', '15 23 * * *', 'select private.cron_nightly()');
