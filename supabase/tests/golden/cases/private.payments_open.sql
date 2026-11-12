-- Payments open for every identity status that counts as checked.
-- callers: definer:owner
-- setup
insert into orgs (id, name, identity_status) values ('00000000-0000-4000-8000-000000000011', 'Golden Pending', 'pending'), ('00000000-0000-4000-8000-000000000012', 'Golden Review', 'review'),
  ('00000000-0000-4000-8000-000000000013', 'Golden Rejected', 'rejected'), ('00000000-0000-4000-8000-000000000014', 'Golden Verified', 'verified'), ('00000000-0000-4000-8000-000000000015', 'Golden Approved', 'approved');
-- call
select o.name, o.identity_status, private.payments_open(o.id) from orgs o order by o.name
