-- Payments open for every identity status that counts as checked; the others say why not. A business TaxStreem paused
-- is refused.
-- callers: definer:owner
-- setup
insert into orgs (id, name, identity_status) values ('00000000-0000-4000-8000-000000000011', 'Golden Pending', 'pending'), ('00000000-0000-4000-8000-000000000012', 'Golden Review', 'review'),
  ('00000000-0000-4000-8000-000000000013', 'Golden Rejected', 'rejected'), ('00000000-0000-4000-8000-000000000014', 'Golden Verified', 'verified'), ('00000000-0000-4000-8000-000000000015', 'Golden Approved', 'approved'),
  ('00000000-0000-4000-8000-000000000016', 'Golden Paused', 'not_required');
insert into org_switches (org_id, feature, enabled) values ('00000000-0000-4000-8000-000000000016', 'payments', false);
-- call
select o.name, o.identity_status, tests.error_of(format('select private.require_payments_open(%L)', o.id)) as error from orgs o order by o.name
