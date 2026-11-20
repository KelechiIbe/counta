-- The VAT set aside for the tax wallet, and the wallet checks against Flutterwave.
--
-- VAT moved from the business wallet to the tax wallet followed each payment's share of the invoice total, so a customer
-- who kept back WHT or the NCD levy left part of the VAT "inside" the credit, where it never moved: the tax wallet came up
-- short by VAT x WHT / total on every such invoice (₦0.07 on a ₦253.75 invoice paid less ₦5 WHT). WHT and the levy come
-- off the price before VAT, so the money the customer sends carries all the VAT. VAT a customer withholds is the reverse:
-- the customer pays it to the NRS, so none of it is set aside. The share is now worked out on everything paid into the
-- wallet for the sale and topped up to that figure, whatever order payments and credits arrive in.
--
-- Flutterwave's balance for a payout subaccount carries an available and a ledger figure. On live accounts the ledger
-- figure reads 0.00 while the available one is the money in the wallet, so the checks compare the available balance. A
-- check that agrees with the books closes the earlier "wallet differs" questions.

-- What a sale's money in the business wallet must have set aside as VAT, topped up to that figure (returns what it added).
-- Kept back by the customer: WHT and the NCD levy (off the price before VAT) and VAT withheld (paid to the NRS by them).
-- The money they pay in cash is the total less all three, and it carries the VAT less what they withheld.
create or replace function private.sale_vat_topup(p_sale uuid, p_key uuid) returns numeric
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; w public.wallets; t public.tax_wallets; v_kept numeric; v_vat_kept numeric; v_cash numeric; v_base numeric;
  v_due numeric; v_set numeric; v_add numeric;
begin
  -- One top-up at a time per sale, so two payments landing together cannot both add the same share.
  perform pg_advisory_xact_lock(hashtext('sale_vat_topup:' || p_sale::text));
  select * into s from sales where id = p_sale;
  if s.id is null or coalesce(s.vat_total, 0) <= 0 or coalesce(s.total, 0) <= 0 then return 0; end if;
  select * into t from tax_wallets where org_id = s.org_id and status = 'active';
  if t.id is null then return 0; end if;
  -- The business wallet the customer's money reached (the latest, if more than one ever did).
  select w2.* into w from collection_allocations a join collections c on c.id = a.collection_id
    join wallets w2 on w2.bank_account_id = c.bank_account_id and w2.status = 'active'
  where a.sale_id = s.id and c.status = 'confirmed' and c.journal_id is not null and c.direction = 'in'
    and c.method not in ('wht_credit', 'wvat_credit', 'ncd_levy', 'advance')
  order by c.created_at desc limit 1;
  if w.id is null then return 0; end if;
  select coalesce(sum(a.amount) filter (where c.method in ('wht_credit', 'ncd_levy')), 0),
         coalesce(sum(a.amount) filter (where c.method = 'wvat_credit'), 0),
         coalesce(sum(a.amount) filter (where c.bank_account_id = w.bank_account_id and c.journal_id is not null
           and c.method not in ('wht_credit', 'wvat_credit', 'ncd_levy', 'advance')), 0)
    into v_kept, v_vat_kept, v_cash
  from collection_allocations a join collections c on c.id = a.collection_id
  where a.sale_id = s.id and c.status = 'confirmed' and c.direction = 'in';
  v_base := s.total - v_kept - v_vat_kept;
  if v_base <= 0 or v_cash <= 0 then return 0; end if;
  v_due := least(round(v_cash * (s.vat_total - v_vat_kept) / v_base, 2), greatest(s.vat_total - v_vat_kept, 0));
  -- Already set aside for this sale: by its payments and credits, and (a sale posted from a wallet line) by the sale itself.
  select coalesce(sum(mv.amount), 0) into v_set from tax_moves mv
  where mv.org_id = s.org_id and mv.kind = 'vat' and mv.direction = 'in' and mv.status <> 'cancelled'
    and ((mv.source_type = 'allocation' and mv.source_id in (select private.alloc_key(a.collection_id, a.sale_id) from collection_allocations a where a.sale_id = s.id))
      or (mv.source_type = 'sale' and mv.source_id = s.id)
      or (mv.source_type = 'sale_vat_change' and mv.description = 'More VAT on ' || s.number));
  v_add := round(v_due - v_set, 2);
  if v_add < 0.01 then return 0; end if;
  insert into tax_moves (org_id, tax_wallet_id, wallet_id, direction, kind, amount, period, source_type, source_id, description)
  values (s.org_id, t.id, w.id, 'in', 'vat', v_add, date_trunc('month', s.issue_date)::date, 'allocation', p_key, 'VAT on ' || s.number)
  on conflict (source_type, source_id, kind) do nothing;
  return case when found then v_add else 0 end;
end $$;

-- A confirmed collection (money, or a credit for what the customer kept back): each sale it settles has its VAT set aside
-- topped up. The move is keyed by the collection and the sale, as before.
create or replace function private.queue_vat_moves(p_collection uuid) returns int
language plpgsql security definer set search_path = public, private as $$
declare c public.collections; a record; v_n int := 0;
begin
  select * into c from collections where id = p_collection;
  if c.id is null or c.status <> 'confirmed' or c.journal_id is null or c.direction <> 'in' or c.method = 'advance' then return 0; end if;
  for a in select distinct ca.sale_id from collection_allocations ca where ca.collection_id = c.id loop
    if private.sale_vat_topup(a.sale_id, private.alloc_key(c.id, a.sale_id)) > 0 then v_n := v_n + 1; end if;
  end loop;
  return v_n;
end $$;

-- The wallet against Flutterwave's available balance; a check that agrees closes the earlier "wallet differs" questions.
create or replace function public.svc_wallet_balance(p_wallet uuid, p_available numeric, p_ledger numeric) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare w public.wallets; v_books numeric; v_transit numeric; v_diff numeric; rec public.wallet_reconciliations; v_out numeric;
  v_provider numeric := coalesce(p_available, p_ledger);
begin
  select * into w from wallets where id = p_wallet for update;
  if not found then raise exception 'Wallet not found.'; end if;
  update wallets set provider_available = p_available, provider_ledger = p_ledger, balance_at = now() where id = w.id;
  v_books := private.wallet_ledger(w.id);
  -- Confirmed in the books but not yet in the wallet: sweeps on their way. Left the wallet but not yet in the books: payouts processing.
  -- A sweep the rail accepted more than two days ago and that never arrived is no longer "in transit": it shows as a difference.
  select coalesce(sum(paid_amount - coalesce(fee, 0)), 0) into v_transit from payment_requests where wallet_id = w.id and status = 'paid'
    and (sweep_status in ('pending', 'failed') or (sweep_status = 'sent' and coalesce(swept_at, paid_at) > now() - interval '2 days'));
  select coalesce(sum(amount + fee), 0) into v_out from payouts where wallet_id = w.id and status = 'processing';
  v_diff := round(v_provider - (v_books - v_transit - v_out), 2);
  insert into wallet_reconciliations (org_id, wallet_id, provider_balance, books_balance, in_transit, difference, status, details)
  values (w.org_id, w.id, v_provider, v_books, v_transit + v_out, v_diff, case when abs(v_diff) < 0.01 then 'matched' else 'difference' end,
    jsonb_build_object('available', p_available, 'ledger', p_ledger, 'sweeps_in_transit', v_transit, 'payouts_processing', v_out,
      'unmatched_lines', (select count(*) from bank_lines where bank_account_id = w.bank_account_id and status = 'unmatched')))
  returning * into rec;
  update ai_proposals set status = 'superseded' where org_id = w.org_id and kind = 'wallet_difference' and status = 'pending' and proposal->>'wallet_id' = w.id::text;
  if rec.status = 'difference' then
    insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount)
    values (w.org_id, 'reconciler', 'wallet_difference', 'wallet_reconciliation', rec.id,
      'Wallet differs from the books by ₦' || to_char(abs(v_diff), 'FM999,999,999,990.00'),
      case when v_diff > 0 then 'The wallet holds more than the books show. Is there money in it that was never recorded?'
           else 'The books show more than the wallet holds. Was something paid out or charged that the books do not know about?' end,
      jsonb_build_object('wallet_id', w.id, 'difference', v_diff, 'books', v_books, 'provider', v_provider, 'in_transit', v_transit + v_out),
      0, 'Nightly wallet reconciliation', 'reconcile', 'pending', abs(v_diff))
    on conflict do nothing;
  end if;
  return to_jsonb(rec);
end $$;

create or replace function public.svc_tax_wallet_balance(p_wallet uuid, p_available numeric, p_ledger numeric) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare t public.tax_wallets; v_books numeric; v_transit numeric; v_provider numeric := coalesce(p_available, p_ledger);
begin
  update tax_wallets set provider_available = p_available, provider_ledger = p_ledger, balance_at = now() where id = p_wallet returning * into t;
  if not found then raise exception 'Tax wallet not found.'; end if;
  v_books := private.tax_wallet_ledger(t.id);
  select coalesce(sum(amount + fee), 0) into v_transit from tax_payments where tax_wallet_id = t.id and status = 'processing';
  return jsonb_build_object('books', v_books, 'provider', v_provider, 'difference', round(v_provider - (v_books - v_transit), 2));
end $$;

revoke all on function private.sale_vat_topup(uuid, uuid), private.queue_vat_moves(uuid) from public, anon, authenticated;
revoke all on function public.svc_wallet_balance(uuid, numeric, numeric), public.svc_tax_wallet_balance(uuid, numeric, numeric) from public, anon, authenticated;
grant execute on function public.svc_wallet_balance(uuid, numeric, numeric), public.svc_tax_wallet_balance(uuid, numeric, numeric) to service_role;

-- The balance the wallet pages show: the ledger figure saved from live checks reads 0.00, so it takes the available one.
update public.wallets set provider_ledger = provider_available where rail = 'flutterwave' and provider_ledger = 0 and coalesce(provider_available, 0) <> 0;
update public.tax_wallets set provider_ledger = provider_available where rail = 'flutterwave' and provider_ledger = 0 and coalesce(provider_available, 0) <> 0;

-- Invoices already paid less WHT, the NCD levy or VAT withheld: the VAT left behind is topped up now, keyed by the credit
-- that left it behind (as the credit itself now does).
do $$
declare c record; v_n int := 0;
begin
  for c in select distinct cc.id from collections cc join collection_allocations a on a.collection_id = cc.id join sales s on s.id = a.sale_id
           join tax_wallets t on t.org_id = cc.org_id and t.status = 'active'
           where cc.method in ('wht_credit', 'ncd_levy', 'wvat_credit') and cc.status = 'confirmed' and cc.journal_id is not null and s.vat_total > 0 loop
    v_n := v_n + private.queue_vat_moves(c.id);
  end loop;
  raise notice 'VAT topped up on % sale(s)', v_n;
end $$;
