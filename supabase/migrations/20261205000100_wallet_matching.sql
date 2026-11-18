-- Payments to the business wallet that a customer cut short by WHT, the NCD levy or VAT withheld, with or without the
-- invoice's reference: the waiting pay request is settled at once, the deduction booked and the customer's page shows it
-- paid. A customer can say on the document's page that they have paid (the amount and the name on the account they paid
-- from), which makes Counta look for the transfer straight away; after ten minutes without it, the business is asked to
-- check. A person who answers the books inbox with "a customer paying what they owe" (and a rule learned from that answer)
-- now settles that customer's invoices. A named customer's transfer that fits one of their open invoices is settled without
-- asking. Pay requests close when their invoice is settled by any route. Wallets with a request waiting are read every minute.

alter table public.payment_requests add column if not exists claimed_at timestamptz;
alter table public.payment_requests add column if not exists claim jsonb;
alter table public.payment_requests add column if not exists claim_flagged_at timestamptz;
comment on column public.payment_requests.claim is 'What the customer said on the document page they sent: {amount, name, count, at}. Never settles anything by itself.';
create index if not exists payment_requests_claims on public.payment_requests(claimed_at) where status = 'pending' and claimed_at is not null and claim_flagged_at is null;

-- What a customer kept back from a payment: WHT worked out on the total with VAT is recognised too, after the usual bases.
create or replace function private.customer_short_split(p_sale uuid, p_due numeric, p_amt numeric) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare s public.sales; cu public.customers; v_vat numeric := 0; v_gap numeric; v_net numeric; v_tol numeric; v_exp jsonb; v_exp_rate numeric;
  v_wht_done numeric; v_ncd_done numeric; v_vat_done numeric; r numeric; v_wb numeric; nb text; v_wv numeric; v_pass int;
  v_wht numeric; v_ncd numeric; v_sum numeric; v_diff numeric; v_rates numeric[]; v_bases numeric[]; v_exact boolean; v_on_total boolean;
begin
  select * into s from sales where id = p_sale;
  if s.id is null or coalesce(p_amt, 0) <= 0 or p_amt >= p_due - 0.004 then return null; end if;
  select * into cu from customers where id = s.customer_id;
  if cu.id is null or cu.is_walk_in then return null; end if;
  select coalesce(sum(a.amount) filter (where c.method = 'wht_credit'), 0), coalesce(sum(a.amount) filter (where c.method = 'ncd_levy'), 0),
         coalesce(sum(a.amount) filter (where c.method = 'wvat_credit'), 0)
    into v_wht_done, v_ncd_done, v_vat_done
  from collection_allocations a join collections c on c.id = a.collection_id where a.sale_id = s.id and c.status = 'confirmed';
  if coalesce(cu.wvat_agent, false) then v_vat := greatest(s.vat_total - v_vat_done, 0); end if;
  v_net := s.total - s.vat_total;
  v_gap := round(p_due - p_amt, 2);
  v_tol := least(1.00, round(v_net * 0.001, 2));
  v_exp := private.expected_wht(s.id);
  v_exp_rate := (v_exp->>'rate')::numeric;
  -- The expected rate, none (the levy or VAT alone), the usual rates, and the doubled ones only for a business with no Tax ID.
  v_rates := array[v_exp_rate, 0, 0.02, 0.05, 0.10]
    || case when (select nullif(trim(o.tin), '') is null from orgs o where o.id = s.org_id) then array[0.04, 0.20]::numeric[] else '{}'::numeric[] end;
  -- Exact first, then within the rounding tolerance. Each time WHT on the value before VAT (and on the lines before any
  -- discount and delivery, when that differs) first, then on the total with VAT, which some customers use.
  for v_pass in 1..4 loop
    v_exact := v_pass in (1, 2);
    v_on_total := v_pass in (2, 4);
    v_bases := case when not v_on_total then case when s.subtotal > 0 and abs(s.subtotal - v_net) >= 0.005 then array[v_net, s.subtotal] else array[v_net] end
                    when s.vat_total > 0 then array[s.total] else '{}'::numeric[] end;
    continue when cardinality(v_bases) = 0;
    foreach r in array (select array_agg(x order by o) from (select distinct on (x) x, o from unnest(v_rates) with ordinality u(x, o)
                        where x is not null order by x, o) z) loop
      continue when v_on_total and r = 0;
      foreach v_wb in array v_bases loop
        v_wht := case when r = 0 then 0 else greatest(round(v_wb * r, 2) - v_wht_done, 0) end;
        continue when r > 0 and v_wht = 0;
        foreach nb in array case when cu.ncd_levy then array['net', 'gross', 'none'] else array['none', 'net', 'gross'] end loop
          v_ncd := case nb when 'none' then 0 when 'net' then greatest(round(v_net * 0.01, 2) - v_ncd_done, 0)
                   else greatest(round(s.total * 0.01, 2) - v_ncd_done, 0) end;
          continue when nb <> 'none' and v_ncd = 0;
          foreach v_wv in array case when v_vat > 0 then array[v_vat, 0] else array[0::numeric] end loop
            v_sum := v_wht + v_ncd + v_wv;
            continue when v_sum <= 0;
            v_diff := round(v_gap - v_sum, 2);
            if (v_exact and abs(v_diff) < 0.005) or (not v_exact and abs(v_diff) <= v_tol and (v_wht > 0 or v_ncd > 0)) then
              if v_wht > 0 then v_wht := v_wht + v_diff; else v_ncd := v_ncd + v_diff; end if;
              return jsonb_build_object('wht', round(v_wht, 2), 'wht_rate', case when v_wht > 0 then r end, 'wvat', v_wv, 'ncd', round(v_ncd, 2),
                'ncd_base', case when v_ncd > 0 then nb end, 'expected_rate', v_exp_rate, 'expected', coalesce(r = v_exp_rate, false),
                'deducted', v_gap, 'rounding', v_diff,
                'wht_base', case when v_wht > 0 then case when v_on_total then 'total' when v_wb = v_net then 'net' else 'lines' end end);
            end if;
          end loop;
        end loop;
      end loop;
    end loop;
  end loop;
  return null;
end $$;

create or replace function private.book_customer_withholding(p_org uuid, p_customer uuid, p_sale uuid, p_split jsonb, p_at timestamptz, m public.members) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_wht numeric := coalesce((p_split->>'wht')::numeric, 0); v_wvat numeric := coalesce((p_split->>'wvat')::numeric, 0);
  v_ncd numeric := coalesce((p_split->>'ncd')::numeric, 0); v_rate numeric := nullif(p_split->>'wht_rate', '')::numeric;
  cu public.customers; v_num text; v_marked boolean := false; v_kept text[] := '{}'; v_ask text[] := '{}';
  v_on_total boolean := p_split->>'wht_base' = 'total';
begin
  if v_wvat > 0 then
    perform private.add_collection(p_org, p_customer, v_wvat, 'wvat_credit', jsonb_build_object('reference', 'VAT withheld',
      'received_at', p_at, 'note', 'VAT the customer withholds and pays to the NRS; credited in the VAT return', 'spread', false), m, 'confirmed', array[p_sale]);
  end if;
  if v_wht > 0 then
    perform private.add_collection(p_org, p_customer, v_wht, 'wht_credit', jsonb_build_object('reference', 'WHT deducted',
      'wht_rate', p_split->'wht_rate', 'received_at', p_at, 'note', case when v_on_total then 'Worked out on the total with VAT; collect a WHT credit note for this amount'
        else 'Collect the WHT credit note' end, 'spread', false), m, 'confirmed', array[p_sale]);
  end if;
  if v_ncd > 0 then
    perform private.add_collection(p_org, p_customer, v_ncd, 'ncd_levy', jsonb_build_object('reference', 'NCD levy deducted',
      'received_at', p_at, 'note', 'The 1% Nigerian Content Development levy the customer deducted; ask them for the NCDF remittance receipt', 'spread', false),
      m, 'confirmed', array[p_sale]);
  end if;
  if not (p_split ? 'deducted') then return; end if;
  select * into cu from customers where id = p_customer for update;
  if v_ncd > 0 and not coalesce(cu.ncd_levy, false) then update customers set ncd_levy = true where id = p_customer; v_marked := true; end if;
  if v_wht > 0 and v_rate > 0 and cu.wht_rate is distinct from v_rate then update customers set wht_rate = v_rate where id = p_customer; end if;
  select number into v_num from sales where id = p_sale;
  if v_wht > 0 then
    v_kept := v_kept || (private.naira(v_wht) || ' WHT' || coalesce(' (' || rtrim(rtrim(to_char(v_rate * 100, 'FM990.00'), '0'), '.') || '%'
      || case when v_on_total then ' of the total with VAT' else '' end || ')', ''));
    v_ask := v_ask || case when v_on_total then 'a WHT credit note for ' || private.naira(v_wht) else 'the WHT credit note' end;
  end if;
  if v_ncd > 0 then v_kept := v_kept || (private.naira(v_ncd) || ' NCD levy (1%)'); v_ask := v_ask || 'the NCDF receipt'::text; end if;
  if v_wvat > 0 then v_kept := v_kept || (private.naira(v_wvat) || ' VAT withheld'); end if;
  perform private.notify_perm(p_org, 'keep_books', 'payment', coalesce(v_num, 'An invoice') || ' settled in full',
    coalesce(cu.name, 'The customer') || ' kept back ' || array_to_string(v_kept, ' and ') || '.'
      || case when cardinality(v_ask) > 0 then ' Ask them for ' || array_to_string(v_ask, ' and ') || '.' else '' end
      || case when v_marked then ' Counta now expects the levy from them.' else '' end,
    '/sell/sales?open=' || p_sale, 'withheld-' || p_sale, case when p_split ? 'seen' then m.id end);
end $$;

-- What the customer of a waiting pay request kept back, when the money that landed is what is owed less WHT, the NCD levy
-- or VAT withheld (null otherwise). Only a request for the whole balance: a deposit or a part payment carries no deduction.
create or replace function private.request_split(p_request uuid, p_amt numeric) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare r public.payment_requests; s public.sales; v_due numeric;
begin
  select * into r from payment_requests where id = p_request;
  if r.sale_id is null or coalesce(p_amt, 0) <= 0 or p_amt >= r.amount - 0.004 then return null; end if;
  select * into s from sales where id = r.sale_id;
  if s.doc_type not in ('invoice', 'order') or s.journal_id is null or s.status not in ('open', 'partially_paid') then return null; end if;
  v_due := s.total - s.amount_paid - s.credited - coalesce((select sum(a.amount) from collection_allocations a join collections c on c.id = a.collection_id
    where a.sale_id = s.id and c.status = 'pending'), 0);
  if r.amount < v_due - 0.004 then return null; end if;
  return private.customer_short_split(s.id, v_due, p_amt);
end $$;

create or replace function public.svc_wallet_inflow(p_rail text, p_account_ref text, d jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare w public.wallets; tw public.tax_wallets; r public.payment_requests; bl public.bank_lines; v_amt numeric := round(private.num(d->>'amount'), 2); v_at timestamptz;
  v_ref text := coalesce(nullif(d->>'provider_ref', ''), nullif(d->>'reference', '')); v_text text; v_n int; v_named boolean; conf jsonb; tr public.tax_transfers;
  v_journal uuid; rq record; s public.sales;
begin
  select * into w from wallets where rail = p_rail and (account_ref = p_account_ref or account_number = p_account_ref) order by (account_ref = p_account_ref) desc limit 1;
  if w.id is null then
    select * into tw from tax_wallets where rail = p_rail and (account_ref = p_account_ref or account_number = p_account_ref) order by (account_ref = p_account_ref) desc limit 1;
  end if;
  if (w.id is null and tw.id is null) or coalesce(v_amt, 0) = 0 or v_ref is null then return jsonb_build_object('ok', false, 'reason', 'unknown_wallet'); end if;
  v_at := coalesce(nullif(d->>'at', '')::timestamptz, now());
  v_text := upper(coalesce(d->>'narration', '') || ' ' || coalesce(d->>'reference', ''));

  if tw.id is not null then
    if exists (select 1 from bank_lines where bank_account_id = tw.bank_account_id and fingerprint = 'wallet:' || v_ref) then
      return jsonb_build_object('ok', true, 'duplicate', true);
    end if;
    -- Our own transfer from the business wallet: its entry is already in the books.
    select * into tr from tax_transfers where tax_wallet_id = tw.id and direction = 'in' and status in ('sent', 'done')
      and (position(reference in v_text) > 0 or (amount = v_amt and sent_at > v_at - interval '2 days'
           and not exists (select 1 from bank_lines bx where bx.bank_account_id = tw.bank_account_id and bx.journal_id = tax_transfers.journal_id)))
    order by (position(reference in v_text) > 0) desc, sent_at limit 1;
    insert into bank_lines (org_id, bank_account_id, line_date, amount, description, reference, counterparty, counterparty_account, counterparty_bank, source,
      provider_ref, fingerprint, status, journal_id, matched_by, confidence, stage)
    values (tw.org_id, tw.bank_account_id, private.local_day(tw.org_id, v_at), v_amt, coalesce(d->>'narration', ''), d->>'reference', d->'sender'->>'name',
      d->'sender'->>'account', d->'sender'->>'bank', 'wallet', v_ref, 'wallet:' || v_ref,
      case when tr.id is not null then 'matched' else 'unmatched' end, tr.journal_id, case when tr.id is not null then 'system' end,
      case when tr.id is not null then 1 end, case when tr.id is not null then 'tax_transfer' end)
    on conflict do nothing returning * into bl;
    if tr.id is not null then update tax_transfers set status = 'done', done_at = coalesce(done_at, v_at) where id = tr.id; end if;
    if bl.id is not null and bl.status = 'unmatched' then
      perform private.match_bank_line(bl.id);
      select * into bl from bank_lines where id = bl.id;
    end if;
    return jsonb_build_object('ok', true, 'matched', coalesce(bl.status, 'matched') <> 'unmatched', 'bank_line', bl.id, 'tax_wallet', true);
  end if;

  if exists (select 1 from bank_lines where bank_account_id = w.bank_account_id and fingerprint = 'wallet:' || v_ref) then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  -- A customer's transfer to the business's own number for a sale (or a balance) waiting for it. What fits: exactly the
  -- amount asked, then the amount the customer said they sent, then what is owed less the WHT, NCD levy or VAT withheld the
  -- customer kept back. None of these needs the reference. A request the narration names comes first, then the closer fit,
  -- a request still waiting, the oldest.
  select x.*, count(*) over (partition by x.fit) n into rq from (
    select r2.id, r2.tx_ref, r2.sale_id, r2.status, r2.created_at,
      (r2.pay_ref is not null and position(upper(r2.pay_ref) in v_text) > 0) named,
      case when r2.amount = v_amt then 1
           when r2.status in ('pending', 'expired') and private.num(r2.claim->>'amount') = v_amt then 2
           when r2.amount > v_amt and private.request_split(r2.id, v_amt) is not null then 3 end fit
    from payment_requests r2
    where r2.wallet_id = w.id and r2.direct and r2.status in ('pending', 'expired', 'cancelled')
      and r2.created_at <= v_at + interval '10 minutes' and r2.created_at > v_at - interval '4 days') x
  where x.fit is not null
  order by x.named desc, x.fit, (x.status = 'pending') desc, (x.status = 'expired') desc, x.created_at
  limit 1;
  if rq.id is not null then
    conf := public.svc_payment_confirmed(rq.tx_ref, jsonb_build_object('amount', v_amt, 'fee', 0, 'provider_ref', v_ref, 'paid_at', v_at,
      'payer', coalesce(d->'sender', '{}'::jsonb)));
    select c.journal_id into v_journal from payment_requests pr join collections c on c.id = pr.collection_id where pr.id = rq.id;
    insert into bank_lines (org_id, bank_account_id, line_date, amount, description, reference, counterparty, counterparty_account, counterparty_bank, source,
      provider_ref, fingerprint, status, journal_id, matched_by, confidence, stage)
    values (w.org_id, w.bank_account_id, private.local_day(w.org_id, v_at), v_amt, coalesce(d->>'narration', ''), d->>'reference', d->'sender'->>'name',
      d->'sender'->>'account', d->'sender'->>'bank', 'wallet', v_ref, 'wallet:' || v_ref, 'matched', v_journal, 'system',
      case when rq.named or rq.n = 1 then 1 else 0.8 end, 'wallet_request')
    on conflict do nothing returning * into bl;
    -- Several fit and nothing in the narration tells them apart: given to the oldest, and someone checks.
    if rq.n > 1 and not rq.named and bl.id is not null then
      insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
      values (w.org_id, 'bookkeeper', 'wallet_payment_check', 'bank_line', bl.id,
        'Check which sale ' || private.naira(v_amt) || ' paid',
        case when rq.fit = 1 then rq.n || ' payments of ' || private.naira(v_amt) || ' were waiting when this transfer reached the wallet, and its narration does not say which. Counta gave it to '
            || coalesce((select number from sales where id = rq.sale_id), 'the oldest') || '. Ask the cashier if that is right.'
          else rq.n || ' payments waiting could take this ' || private.naira(v_amt) || ' once what the customer kept back is allowed for, and its narration does not say which. Counta gave it to '
            || coalesce((select number from sales where id = rq.sale_id), 'the oldest') || '. Check that it is right.' end,
        jsonb_build_object('request_id', rq.id, 'sale_id', rq.sale_id), 0.8,
        case when rq.fit = 1 then 'Wallet transfer matched by amount only' else 'Wallet transfer matched by what was owed less what the customer kept back' end,
        'wallet_request', 'info', v_amt, v_journal)
      on conflict do nothing;
    end if;
    -- The amount the customer said they sent, short of what is owed with nothing to explain the gap: the business is told.
    if rq.fit = 2 and rq.sale_id is not null then
      select * into s from sales where id = rq.sale_id;
      if s.status = 'partially_paid' then
        perform private.notify_perm(w.org_id, 'keep_books', 'payment', s.number || ' part paid',
          coalesce(s.customer_name, 'The customer') || ' sent ' || private.naira(v_amt) || ', the amount they said they paid. '
            || private.naira(s.total - s.amount_paid - s.credited) || ' is still owed: ask them about the difference.',
          '/sell/sales?open=' || s.id, 'short-' || rq.id);
      end if;
    end if;
    return jsonb_build_object('ok', true, 'matched', true, 'request', conf->'request', 'bank_line', bl.id);
  end if;

  -- Our own sweep of a checkout payment: the collection already posted it.
  select * into r from payment_requests where wallet_id = w.id and sweep_status in ('sent', 'pending', 'failed')
    and (sweep_ref = d->>'reference' or coalesce(d->>'narration', '') like '%' || tx_ref || '%' or coalesce(d->>'reference', '') like '%' || tx_ref || '%'
         or (round(paid_amount - coalesce(fee, 0), 2) = v_amt and paid_at > v_at - interval '2 days'
             and coalesce(d->'sender'->>'name', '') ~* '(flutterwave|taxstreem|counta)'))
  order by (sweep_ref = d->>'reference') desc nulls last, paid_at limit 1;
  -- Money back from the tax wallet.
  if r.id is null then
    select * into tr from tax_transfers where wallet_id = w.id and direction = 'out' and status in ('sent', 'done')
      and (position(reference in v_text) > 0 or (amount = v_amt and sent_at > v_at - interval '2 days'
           and not exists (select 1 from bank_lines bx where bx.bank_account_id = w.bank_account_id and bx.journal_id = tax_transfers.journal_id)))
    order by (position(reference in v_text) > 0) desc, sent_at limit 1;
  end if;
  insert into bank_lines (org_id, bank_account_id, line_date, amount, description, reference, counterparty, counterparty_account, counterparty_bank, source,
    provider_ref, fingerprint, status, journal_id, matched_by, confidence)
  values (w.org_id, w.bank_account_id, private.local_day(w.org_id, v_at), v_amt, coalesce(d->>'narration', ''), d->>'reference', d->'sender'->>'name',
    d->'sender'->>'account', d->'sender'->>'bank', 'wallet', v_ref, 'wallet:' || v_ref,
    case when r.id is not null or tr.id is not null then 'matched' else 'unmatched' end,
    coalesce((select journal_id from collections where id = r.collection_id), tr.journal_id),
    case when r.id is not null or tr.id is not null then 'system' end, case when r.id is not null or tr.id is not null then 1 end)
  on conflict do nothing
  returning * into bl;
  if r.id is not null then
    update payment_requests set sweep_status = 'done', swept_at = coalesce(swept_at, v_at) where id = r.id;
  end if;
  if tr.id is not null then update tax_transfers set status = 'done', done_at = coalesce(done_at, v_at) where id = tr.id; end if;
  -- Everything else goes through the same pipeline as a bank statement line (a customer paying an invoice into the wallet, say).
  if bl.id is not null and bl.status = 'unmatched' then
    if private.match_bank_line(bl.id) is null then
      perform private.notify_perm(w.org_id, 'keep_books', 'bank', 'Money into the wallet: ₦' || to_char(v_amt, 'FM999,999,999,990.00'),
        coalesce(d->'sender'->>'name', 'Unknown sender') || coalesce(' · ' || (d->>'narration'), ''), '/accounting/banking', 'inflow-' || bl.id);
      perform private.call_function('atlas', jsonb_build_object('action', 'classify_lines', 'org_id', w.org_id));
    end if;
    select * into bl from bank_lines where id = bl.id;
  end if;
  return jsonb_build_object('ok', true, 'matched', bl.status <> 'unmatched', 'stage', bl.stage, 'bank_line', bl.id);
end $$;

create or replace function public.svc_payment_confirmed(p_tx_ref text, d jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare r public.payment_requests; w public.wallets; c public.collections; s public.sales; v_amt numeric; v_fee numeric; m public.members;
  v_due numeric; v_split jsonb;
begin
  select * into r from payment_requests where tx_ref = p_tx_ref for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown_reference'); end if;
  if r.status = 'paid' then return jsonb_build_object('ok', true, 'duplicate', true, 'request', private.request_json(r)); end if;
  v_amt := round(coalesce(private.num(d->>'amount'), 0), 2);
  if v_amt <= 0 then return jsonb_build_object('ok', false, 'reason', 'no_amount'); end if;
  v_fee := least(greatest(round(coalesce(private.num(d->>'fee'), 0), 2), 0), v_amt);
  select * into w from wallets where id = r.wallet_id;
  -- The money arrived even if the request was cancelled or expired in the meantime: it still belongs to this customer.
  update payment_requests set status = 'paid', paid_amount = v_amt, fee = v_fee, paid_at = coalesce(nullif(d->>'paid_at', '')::timestamptz, now()),
    provider_ref = coalesce(nullif(d->>'provider_ref', ''), provider_ref), payer = d->'payer',
    sweep_status = case when r.rail = 'flutterwave' and w.barter_id is not null and not r.direct then 'pending' else 'not_needed' end
  where id = r.id returning * into r;
  -- The customer's word that they paid, if the business was asked about it, is answered by the money.
  update ai_proposals set status = 'approved', decided_at = now(), decision = jsonb_build_object('auto', 'paid', 'amount', v_amt)
  where kind = 'payment_claim' and source_type = 'payment_request' and source_id = r.id and status in ('pending', 'info');
  m := (select mm from members mm where mm.id = r.created_by);
  if r.sale_id is not null then
    select * into s from sales where id = r.sale_id for update;
    -- A till sale waiting for this transfer posts now, and takes its stock.
    if s.doc_type = 'receipt' and s.journal_id is null and s.status not in ('cancelled', 'void', 'draft') then
      perform private.post_sale(s.id, coalesce(m, jsonb_populate_record(null::public.members, jsonb_build_object('id', s.created_by))), r.paid_at);
      select * into s from sales where id = s.id;
    end if;
  end if;
  -- Paid short by exactly what the customer was expected to keep back (WHT, the NCD levy, VAT withheld): settled in full.
  if s.id is not null and s.doc_type in ('invoice', 'order') and s.journal_id is not null and s.status in ('open', 'partially_paid') then
    v_due := s.total - s.amount_paid - s.credited - coalesce((select sum(a.amount) from collection_allocations a join collections cc on cc.id = a.collection_id
      where a.sale_id = s.id and cc.status = 'pending'), 0);
    v_split := private.customer_short_split(s.id, v_due, v_amt);
    if v_split is not null then
      perform private.book_customer_withholding(r.org_id, s.customer_id, s.id, v_split, r.paid_at, m);
    end if;
  end if;
  c := private.add_collection(r.org_id, coalesce(r.customer_id, s.customer_id), v_amt, case when r.rail = 'flutterwave' then 'flutterwave' else 'rail' end,
    jsonb_build_object('bank_account_id', w.bank_account_id, 'fee', v_fee, 'provider_ref', coalesce(nullif(d->>'provider_ref', ''), r.tx_ref),
      'reference', r.tx_ref, 'payment_request_id', r.id, 'received_at', r.paid_at, 'shift_id', r.shift_id,
      'note', 'Paid by ' || coalesce(d->'payer'->>'name', 'customer') || coalesce(' from ' || (d->'payer'->>'bank'), ''),
      'spread', case when (s.id is null or s.status in ('void', 'cancelled'))
                      and not (select is_walk_in from customers where id = coalesce(r.customer_id, s.customer_id)) then 'true' else 'false' end),
    null::public.members, 'confirmed',
    case when s.id is not null and s.status not in ('void', 'cancelled') then array[s.id] end);
  -- The rail confirmed it, not a person; the request's author stays on record as who asked for it.
  update collections set created_by = r.created_by where id = c.id;
  update payment_requests set collection_id = c.id where id = r.id returning * into r;
  -- Tell whoever asked for it, and the people who look after money.
  if m.user_id is not null then
    perform private.notify(r.org_id, m.user_id, 'payment', 'Paid ₦' || to_char(v_amt, 'FM999,999,999,990.00') || coalesce(' for ' || s.number, ''),
      coalesce(d->'payer'->>'name', 'Customer') || ' paid by ' || case r.method when 'account' then 'transfer' when 'link' then 'payment link' else 'QR' end,
      case when s.id is not null then '/sell/sales?open=' || s.id else '/sell/customers' end, 'paid-' || r.id);
  end if;
  return jsonb_build_object('ok', true, 'request', private.request_json(r), 'collection', c.number, 'org_id', r.org_id,
    'sweep', case when r.sweep_status = 'pending' then jsonb_build_object('barter_id', w.barter_id, 'amount', v_amt - v_fee, 'reference', 'SWP-' || r.tx_ref) end);
end $function$;

create or replace function private.refresh_sale(p_sale uuid) returns public.sales
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; v_paid numeric; v_cred numeric; v_status text;
begin
  select * into s from sales where id = p_sale for update;
  if s.doc_type in ('quote', 'credit_note') or s.status in ('void', 'converted', 'cancelled', 'expired', 'draft') then return s; end if;
  select coalesce(sum(a.amount), 0) into v_paid from collection_allocations a join collections c on c.id = a.collection_id
    where a.sale_id = s.id and c.status = 'confirmed';
  select coalesce(sum(amount), 0) into v_cred from credit_allocations where sale_id = s.id;
  v_status := case when v_paid + v_cred >= s.total - 0.004 then case when v_cred >= s.total - 0.004 and v_paid = 0 then 'credited' else 'paid' end
                   when v_paid + v_cred > 0 then 'partially_paid'
                   when s.journal_id is null and s.doc_type in ('order', 'receipt') then 'pending'
                   else 'open' end;
  update sales set amount_paid = v_paid, credited = v_cred, status = v_status where id = s.id returning * into s;
  -- Settled by whatever route (the wallet, the books inbox, a payment recorded by hand, a credit note): a pay request still
  -- waiting for it closes, so neither the customer's page nor the cashier's screen waits on, and the customer's word that
  -- they paid is answered.
  if v_status in ('paid', 'credited') then
    update ai_proposals set status = 'approved', decided_at = now(), decision = jsonb_build_object('auto', 'settled')
    where kind = 'payment_claim' and source_type = 'payment_request' and status in ('pending', 'info')
      and source_id in (select pr.id from payment_requests pr where pr.sale_id = s.id);
    update payment_requests set status = 'cancelled', error = coalesce(error, 'Settled another way') where sale_id = s.id and status = 'pending';
  end if;
  return s;
end $$;

-- How money from a customer is applied when a person (or a rule learned from one) says who paid but not which invoice:
-- the open invoice it fits, exactly or less what the customer kept back (oldest first); otherwise their open invoices
-- oldest first, as far as the money goes; held as their credit when nothing is owed.
create or replace function private.customer_pick(p_org uuid, p_customer uuid, p_amt numeric) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare x record; v_left numeric := round(p_amt, 2); v_ids uuid[] := '{}'; v_nums text[] := '{}'; v_all uuid[] := '{}'; v_dues numeric[] := '{}'; v_numbers text[] := '{}'; i int;
begin
  for x in
    select s.id, s.number, s.total - s.amount_paid - s.credited - coalesce((select sum(a.amount) from collection_allocations a join collections cc on cc.id = a.collection_id
        where a.sale_id = s.id and cc.status = 'pending'), 0) due
    from sales s
    where s.org_id = p_org and s.customer_id = p_customer and s.status in ('open', 'partially_paid') and s.journal_id is not null
      and s.doc_type in ('invoice', 'order', 'receipt')
    order by coalesce(s.due_date, s.issue_date), s.created_at
  loop
    continue when x.due <= 0.004;
    if abs(x.due - p_amt) < 0.005 or private.customer_short_split(x.id, x.due, p_amt) is not null then
      return jsonb_build_object('kind', 'sale', 'id', x.id, 'number', x.number, 'party_id', p_customer);
    end if;
    v_all := v_all || x.id; v_dues := v_dues || x.due; v_numbers := v_numbers || x.number;
  end loop;
  for i in 1..coalesce(cardinality(v_all), 0) loop
    exit when v_left <= 0.004;
    v_ids := v_ids || v_all[i]; v_nums := v_nums || v_numbers[i]; v_left := v_left - v_dues[i];
  end loop;
  if cardinality(v_ids) = 1 then return jsonb_build_object('kind', 'sale', 'id', v_ids[1], 'number', v_nums[1], 'party_id', p_customer); end if;
  if cardinality(v_ids) > 1 then
    return jsonb_build_object('kind', 'sales', 'ids', to_jsonb(v_ids), 'number', array_to_string(v_nums, ', '), 'party_id', p_customer);
  end if;
  return jsonb_build_object('kind', 'credit', 'party_id', p_customer);
end $$;

create or replace function private.apply_match(p_line uuid, c jsonb, m public.members, p_holding uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare bl public.bank_lines; b public.bank_accounts; s public.sales; bb public.bills; col public.collections; j public.journals; v_amt numeric; v_due numeric;
  v_split jsonb; v_at timestamptz; v_ref text; v_fee numeric; v_wht numeric; v_left_wht numeric; v_gross numeric; v_rate numeric; v_ids uuid[]; x uuid; v_tol numeric;
begin
  select * into bl from bank_lines where id = p_line for update;
  select * into b from bank_accounts where id = bl.bank_account_id;
  v_amt := abs(bl.amount);
  v_at := private.line_time(bl.org_id, bl.line_date);
  v_ref := coalesce(bl.reference, left(bl.description, 60));
  if c->>'kind' = 'sales' then
    v_ids := array(select (jsonb_array_elements_text(c->'ids'))::uuid);
    foreach x in array v_ids loop
      if not exists (select 1 from sales where id = x and status in ('open', 'partially_paid')) then raise exception 'One of those invoices is no longer open. Say what this payment was.'; end if;
    end loop;
    if p_holding is not null then perform private.reverse_entry(p_holding, m.id, 'Matched to ' || (c->>'number'), null); end if;
    col := private.add_collection(bl.org_id, (c->>'party_id')::uuid, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
      'reference', v_ref, 'note', 'Confirmed from the bank by ' || coalesce(m.display_name, 'a person'), 'spread', false), m, 'confirmed', v_ids);
    update bank_lines set status = 'matched', journal_id = col.journal_id, stage = 'user', matched_by = 'user', confidence = 1 where id = bl.id;
    return jsonb_build_object('journal_id', col.journal_id, 'settled', c->>'number');
  elsif c->>'kind' = 'sale' then
    select * into s from sales where id = (c->>'id')::uuid for update;
    if s.id is null or s.status not in ('open', 'partially_paid') then raise exception '% is no longer open. Say what this payment was.', coalesce(s.number, 'The invoice'); end if;
    v_due := s.total - s.amount_paid - s.credited - coalesce((select sum(a.amount) from collection_allocations a join collections cc on cc.id = a.collection_id
      where a.sale_id = s.id and cc.status = 'pending'), 0);
    v_tol := greatest(100, round(v_due * 0.005, 2));
    if p_holding is not null then perform private.reverse_entry(p_holding, m.id, 'Matched to ' || s.number, null); end if;
    v_fee := 0;
    if v_amt < v_due - 0.004 then
      v_split := private.customer_short_split(s.id, v_due, v_amt);
      if v_split is null and c->>'basis' = 'less_wht_charge' and coalesce((c->>'wht')::numeric, 0) > 0
         and v_due - (c->>'wht')::numeric - v_amt > 0.004 and v_due - (c->>'wht')::numeric - v_amt <= v_tol then
        v_rate := round((c->>'wht')::numeric / nullif(s.subtotal, 0), 4);
        v_split := jsonb_build_object('wht', (c->>'wht')::numeric, 'wht_rate', v_rate, 'wvat', 0);
        v_fee := round(v_due - (c->>'wht')::numeric - v_amt, 2);
      elsif v_split is null and c->>'basis' in ('bank_charge', 'less_wht_charge') and v_due - v_amt <= v_tol then
        v_fee := round(v_due - v_amt, 2);
      end if;
      if v_split is not null then perform private.book_customer_withholding(bl.org_id, s.customer_id, s.id, v_split, v_at, m); end if;
    end if;
    -- A bank charge taken out of the payment: the invoice is settled in full and the charge is the business's cost.
    col := private.add_collection(bl.org_id, s.customer_id, v_amt + v_fee, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
      'reference', v_ref, 'fee', v_fee, 'note', 'Confirmed from the bank by ' || coalesce(m.display_name, 'a person')
        || case when v_fee > 0 then ' · ' || private.naira(v_fee) || ' bank charge' else '' end, 'spread', false), m, 'confirmed', array[s.id]);
    update bank_lines set status = 'matched', journal_id = col.journal_id, stage = 'user', matched_by = 'user', confidence = 1 where id = bl.id;
    if v_amt > v_due + 0.004 then
      insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
      values (bl.org_id, 'bookkeeper', 'overpaid_invoice', 'bank_line', bl.id, s.customer_name || ' paid more than ' || s.number,
        'The extra is held as customer credit. Refund it or use it on their next invoice.', jsonb_build_object('sale_id', s.id, 'customer_id', s.customer_id), 0.9,
        'AR: payment exceeds what is owed', 'user', 'info', v_amt - v_due, col.journal_id) on conflict do nothing;
    end if;
    return jsonb_build_object('journal_id', col.journal_id, 'settled', s.number);
  elsif c->>'kind' = 'bill' then
    select * into bb from bills where id = (c->>'id')::uuid for update;
    if bb.id is null or bb.status not in ('approved', 'partially_paid') then raise exception '% is no longer open. Say what this payment was.', coalesce(bb.number, 'The bill'); end if;
    v_due := bb.total - bb.amount_paid - coalesce((select sum(gross) from bill_payments where bill_id = bb.id and status = 'processing'), 0);
    v_left_wht := greatest(bb.wht_expected + bb.wvat_expected - bb.wht_withheld - bb.wvat_withheld, 0);
    v_tol := greatest(100, round(v_due * 0.005, 2));
    v_fee := 0;
    v_gross := case when abs(v_due - v_amt) < 0.005 then v_due
                    when v_left_wht > 0 and abs(v_due - v_left_wht - v_amt) < 0.005 then v_due
                    when v_amt - v_due > 0.004 and v_amt - v_due <= v_tol then v_due
                    when v_left_wht > 0 and v_amt - (v_due - v_left_wht) > 0.004 and v_amt - (v_due - v_left_wht) <= v_tol then v_due
                    when v_amt < v_due - v_left_wht then round(v_amt / (1 - coalesce((bb.wht_expected + bb.wvat_expected) / nullif(bb.total, 0), 0)), 2) end;
    if v_gross is null then raise exception '% has only % left to pay.', bb.number, private.naira(v_due); end if;
    v_wht := case when abs(v_due - v_amt) < 0.005 or (v_amt - v_due > 0.004 and v_amt - v_due <= v_tol) then 0
                  when v_amt < v_due - v_left_wht then greatest(v_gross - v_amt, 0)
                  else v_left_wht end;
    v_fee := round(greatest(v_amt - (v_gross - v_wht), 0), 2);
    if p_holding is not null then perform private.reverse_entry(p_holding, m.id, 'Matched to ' || bb.number, null); end if;
    j := private.record_bill_payment(bb.id, b.id, v_gross, v_wht, v_at, v_ref, m);
    -- Charges the bank added on top of the payment.
    if v_fee > 0 then
      perform private.post_entry(bl.org_id, 'Bank charge on paying ' || bb.number, 'bank', bl.id, m.id, m.id, jsonb_build_array(
          jsonb_build_object('code', '6701', 'debit', v_fee, 'memo', 'Charge on ' || bb.number),
          jsonb_build_object('code', b.ledger_code, 'credit', v_fee, 'memo', bl.description)), v_at,
        jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id))));
    end if;
    update bank_lines set status = 'matched', journal_id = j.id, stage = 'user', matched_by = 'user', confidence = 1 where id = bl.id;
    return jsonb_build_object('journal_id', j.id, 'settled', bb.number);
  end if;
  if c->>'kind' = 'credit' then
    -- A customer's money with nothing owed: held as their credit, for the next invoice or a refund.
    if p_holding is not null then perform private.reverse_entry(p_holding, m.id, 'Held as customer credit', null); end if;
    col := private.add_collection(bl.org_id, (c->>'party_id')::uuid, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
      'reference', v_ref, 'note', 'Nothing owed: held as customer credit · ' || coalesce(m.display_name, 'a person'), 'spread', false), m, 'confirmed', null);
    update bank_lines set status = 'matched', journal_id = col.journal_id, stage = 'user', matched_by = 'user', confidence = 1 where id = bl.id;
    return jsonb_build_object('journal_id', col.journal_id, 'settled', null, 'credit', v_amt);
  end if;
  raise exception 'Choose the invoice or bill this paid.';
end $$;

create or replace function private.match_bank_line(p_line uuid) returns text
language plpgsql security definer set search_path = public, private as $$
declare bl public.bank_lines; b public.bank_accounts; v_amt numeric; v_in boolean; r record; c public.collections; v_cnt int; m public.members;
  v_cust public.customers; v_vendor public.vendors; v_due numeric; v_rate numeric; v_gross numeric; v_wht numeric; v_head numeric; j public.journals;
  other public.bank_lines; ob public.bank_accounts; v_key text; v_rule public.entity_rules; v_at timestamptz; v_text text; s public.sales; bb public.bills;
  v_left_wht numeric; v_pid uuid; v_split jsonb; v_cands jsonb; v_pos text; v_fits int; v_fit uuid; mr public.members;
begin
  select * into bl from bank_lines where id = p_line for update;
  if bl.status <> 'unmatched' then return bl.stage; end if;
  select * into b from bank_accounts where id = bl.bank_account_id;
  v_amt := abs(bl.amount); v_in := bl.amount > 0;
  v_key := private.party_key(coalesce(nullif(bl.counterparty, ''), bl.description));
  update bank_lines set party_key = v_key where id = bl.id;
  v_at := private.line_time(bl.org_id, bl.line_date);
  v_text := coalesce(bl.description, '') || ' ' || coalesce(bl.reference, '') || ' ' || coalesce(bl.counterparty, '');
  -- Actions are taken in the name of the business owner; the line and its evidence say why.
  m := private.org_contact(bl.org_id);

  -- 1 Already in the books on this account, same amount, within three days, not yet tied to another line.
  select l.journal_id into r from journal_lines l join journals jj on jj.id = l.journal_id
  where l.org_id = bl.org_id and l.account_code = b.ledger_code and (case when v_in then l.debit else l.credit end) = v_amt
    and jj.entry_date between bl.line_date - 3 and bl.line_date + 3
    and not exists (select 1 from bank_lines x where x.bank_account_id = b.id and x.journal_id = l.journal_id and x.id <> bl.id)
  order by abs(jj.entry_date - bl.line_date), jj.created_at limit 1;
  if r.journal_id is not null then
    update bank_lines set status = 'matched', journal_id = r.journal_id, stage = 'in_books', matched_by = 'system', confidence = 1 where id = bl.id;
    return 'in_books';
  end if;
  -- 1b A POS provider settling payments Counta already holds in 9002 (see pos_settle_line).
  if v_in then
    v_pos := private.pos_settle_line(bl, b, m);
    if v_pos is not null then return v_pos; end if;
  end if;

  if v_in then
    -- 2 A transfer recorded at the till or against an invoice, waiting for confirmation: the statement confirms it.
    select count(*) into v_cnt from collections col where col.org_id = bl.org_id and col.status = 'pending' and col.direction = 'in'
      and col.amount = v_amt and col.method in ('transfer', 'card', 'pos', 'cheque', 'other') and col.received_at::date between bl.line_date - 5 and bl.line_date + 1;
    if v_cnt >= 1 then
      select col.* into c from collections col join customers cu on cu.id = col.customer_id
      where col.org_id = bl.org_id and col.status = 'pending' and col.direction = 'in' and col.amount = v_amt
        and col.method in ('transfer', 'card', 'pos', 'cheque', 'other') and col.received_at::date between bl.line_date - 5 and bl.line_date + 1
      order by private.name_in(cu.name, bl.description) desc, (col.reference is not null and position(upper(col.reference) in upper(bl.description || ' ' || coalesce(bl.reference, ''))) > 0) desc,
        abs(col.received_at::date - bl.line_date), col.received_at limit 1;
      if v_cnt = 1 or private.name_in((select name from customers where id = c.customer_id), bl.description) then
        update collections set status = 'confirmed', bank_account_id = b.id, confirmed_at = now(), note = concat_ws(' · ', note, 'Confirmed by the bank statement')
        where id = c.id;
        c := private.post_collection(c.id, m);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'pending_payment', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'pending_payment';
      end if;
    end if;

    -- 2b The invoice or order the narration names, whoever paid it (a director paying for the company, a relative).
    select * into s from sales x where x.org_id = bl.org_id and x.doc_type in ('invoice', 'order') and x.status in ('open', 'partially_paid') and x.journal_id is not null
      and x.issue_date <= bl.line_date + 1 and private.doc_in_text(x.number, v_text)
    order by x.issue_date desc limit 1;
    if s.id is not null then
      v_due := s.total - s.amount_paid - s.credited - coalesce((select sum(a.amount) from collection_allocations a join collections cc on cc.id = a.collection_id
        where a.sale_id = s.id and cc.status = 'pending'), 0);
      -- The invoice's own number and exactly what is owed (or that less WHT, and VAT for a customer who withholds VAT): settled.
      -- Any other amount is put to a person below.
      v_split := private.customer_short_split(s.id, v_due, v_amt);
      if abs(v_due - v_amt) < 0.005 or v_split is not null then
        if v_split is not null then
          perform private.book_customer_withholding(bl.org_id, s.customer_id, s.id, v_split, v_at, m);
        end if;
        c := private.add_collection(bl.org_id, s.customer_id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
          'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'Matched from the bank by ' || s.number, 'spread', false), m, 'confirmed', array[s.id]);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'invoice_ref', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'invoice_ref';
      end if;
    end if;
  else
    -- 3 Statutory payees clear the tax head, never an expense (AP-06).
    select * into r from payee_registry pr where pr.kind like 'statutory%' and pr.direction in ('out', 'both')
      and upper(bl.description || ' ' || coalesce(bl.counterparty, '')) ~ pr.pattern order by pr.id limit 1;
    if r.id is not null then
      j := private.post_bank_line(bl.id, coalesce(case when r.role is not null then private.acct(bl.org_id, r.role) end, r.account_code), null, null,
        r.description || ' · ' || bl.description, 'statutory', jsonb_build_object('matched_by', 'rule'));
      select coalesce(sum(credit - debit), 0) into v_head from journal_lines where org_id = bl.org_id and account_code = coalesce(case when r.role is not null then private.acct(bl.org_id, r.role) end, r.account_code);
      if v_head < -0.004 then
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'tax', 'remittance_without_accrual', 'bank_line', bl.id, 'Paid more ' || r.description || ' than the books owed',
          'This remittance is more than the liability on record. Is a return missing, or was this paid in advance?',
          jsonb_build_object('account', r.account_code, 'overpaid', -v_head), 1, 'AP-06 exception', 'statutory', 'info', v_amt, j.id) on conflict do nothing;
      end if;
      return 'statutory';
    end if;

    -- 3b The bill the narration names: Counta's number, or the supplier's own invoice number together with the amount
    --    owed or the supplier's name (a short invoice number alone could be a coincidence).
    select bb2.* into bb from bills bb2 where bb2.org_id = bl.org_id and bb2.status in ('approved', 'partially_paid')
      and (private.doc_in_text(bb2.number, v_text)
           or private.ref_in_text(bb2.vendor_ref, v_text) and (abs(bb2.total - bb2.amount_paid - v_amt) < 0.005
             or abs(bb2.total - bb2.amount_paid - greatest(bb2.wht_expected + bb2.wvat_expected - bb2.wht_withheld - bb2.wvat_withheld, 0) - v_amt) < 0.005
             or private.name_in((select name from vendors where id = bb2.vendor_id), coalesce(bl.counterparty, '') || ' ' || bl.description)))
    order by bb2.due_date limit 1;
    if bb.id is not null then
      v_due := bb.total - bb.amount_paid - coalesce((select sum(gross) from bill_payments where bill_id = bb.id and status = 'processing'), 0);
      v_left_wht := greatest(bb.wht_expected + bb.wvat_expected - bb.wht_withheld - bb.wvat_withheld
        - coalesce((select sum(wht + wvat) from bill_payments where bill_id = bb.id and status = 'processing'), 0), 0);
      v_rate := coalesce((bb.wht_expected + bb.wvat_expected) / nullif(bb.total, 0), 0);
      v_gross := case when abs(v_due - v_amt) < 0.005 then v_due
                      when v_left_wht > 0 and abs(v_due - v_left_wht - v_amt) < 0.005 then v_due end;
      if v_gross is not null then
        v_wht := greatest(v_gross - v_amt, 0);
        j := private.record_bill_payment(bb.id, b.id, v_gross, v_wht, v_at, coalesce(bl.reference, left(bl.description, 60)), m);
        update bank_lines set status = 'matched', journal_id = j.id, stage = 'bill_ref', matched_by = 'system', confidence = 1 where id = bl.id;
        return 'bill_ref';
      end if;
    end if;
  end if;

  if v_in then
    -- 4 A customer named in the narration: their open invoices that fit are put to a person to confirm (AR-03).
    for v_cust in select cu.* from customers cu where cu.org_id = bl.org_id and not cu.is_walk_in and not cu.archived
        and private.name_in(cu.name, coalesce(bl.counterparty, '') || ' ' || bl.description)
        order by length(cu.name) desc limit 1 loop
      -- One of their open invoices fits, exactly or less what they kept back (WHT, the NCD levy, VAT withheld): settled.
      select count(*), (array_agg(x.id order by x.ord))[1], (array_agg(x.due order by x.ord))[1] into v_fits, v_fit, v_due
      from (select s2.id, row_number() over (order by coalesce(s2.due_date, s2.issue_date), s2.created_at) ord,
              s2.total - s2.amount_paid - s2.credited - coalesce((select sum(a.amount) from collection_allocations a join collections cc on cc.id = a.collection_id
                where a.sale_id = s2.id and cc.status = 'pending'), 0) due
            from sales s2
            where s2.org_id = bl.org_id and s2.customer_id = v_cust.id and s2.status in ('open', 'partially_paid') and s2.journal_id is not null
              and s2.doc_type in ('invoice', 'order', 'receipt')) x
      where x.due > 0.004 and (abs(x.due - v_amt) < 0.005 or private.customer_short_split(x.id, x.due, v_amt) is not null);
      if v_fits = 1 then
        select * into s from sales where id = v_fit for update;
        v_split := private.customer_short_split(s.id, v_due, v_amt);
        if v_split is not null then
          perform private.book_customer_withholding(bl.org_id, s.customer_id, s.id, v_split, v_at, m);
        end if;
        c := private.add_collection(bl.org_id, s.customer_id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
          'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'Matched from the bank: ' || v_cust.name || ' named, ' || s.number || ' fits',
          'spread', false), m, 'confirmed', array[s.id]);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'customer_invoice', matched_by = 'system', confidence = 0.95 where id = bl.id;
        return 'customer_invoice';
      end if;
      v_cands := private.match_candidates(bl.id);
      if jsonb_array_length(v_cands) > 0 then
        perform private.propose_match(bl.id, v_cands, 'customer');
        return 'customer';
      end if;
      select coalesce(sum(s2.total - s2.amount_paid - s2.credited), 0) into v_due from sales s2
      where s2.customer_id = v_cust.id and s2.status in ('open', 'partially_paid') and s2.journal_id is not null;
      -- Paying with nothing owed: held as an advance, flagged (AR rule).
      if v_due <= 0.004 then
        c := private.add_collection(bl.org_id, v_cust.id, v_amt, 'transfer', jsonb_build_object('bank_account_id', b.id, 'received_at', v_at,
          'reference', coalesce(bl.reference, left(bl.description, 60)), 'note', 'No invoice open: held as customer credit', 'spread', true), m, 'confirmed', null);
        update bank_lines set status = 'matched', journal_id = c.journal_id, stage = 'customer_advance', matched_by = 'system', confidence = 0.8 where id = bl.id;
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'bookkeeper', 'advance_without_invoice', 'bank_line', bl.id, v_cust.name || ' paid with nothing owed',
          'Held as customer credit. Raise the invoice it was for, or refund it.', jsonb_build_object('customer_id', v_cust.id), 0.8,
          'AR: inflow from a known customer with no open invoice', 'customer', 'info', v_amt, c.journal_id) on conflict do nothing;
        return 'customer_advance';
      end if;
    end loop;
  else
    -- 5 A vendor named in the narration being paid for open bills (AP-03).
    for v_vendor in select v.* from vendors v where v.org_id = bl.org_id
        and (private.name_in(v.name, coalesce(bl.counterparty, '') || ' ' || bl.description)
             or (v.account_number is not null and position(v.account_number in coalesce(bl.counterparty_account, '') || bl.description) > 0))
        order by length(v.name) desc limit 1 loop
      v_cands := private.match_candidates(bl.id);
      if jsonb_array_length(v_cands) > 0 then
        perform private.propose_match(bl.id, v_cands, 'vendor_bill');
        return 'vendor_bill';
      end if;
      -- A known vendor with no matching bill: post to their usual account and ask for the bill (AP-05).
      if v_vendor.default_account is not null then
        j := private.post_bank_line(bl.id, v_vendor.default_account, null, null, v_vendor.name || ' · no bill', 'vendor_no_bill',
          jsonb_build_object('matched_by', 'rule', 'ai_confidence', 0.85));
        insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount, journal_id)
        values (bl.org_id, 'bookkeeper', 'payment_without_bill', 'bank_line', bl.id, 'Paid ' || v_vendor.name || ' without a bill',
          'Posted to their usual account with no VAT claimed and no WHT. Upload the bill if there is one.', jsonb_build_object('vendor_id', v_vendor.id),
          0.85, 'AP-05', 'vendor_no_bill', 'info', v_amt, j.id) on conflict do nothing;
        return 'vendor_no_bill';
      end if;
    end loop;
  end if;

  -- 6 Money moving between the business's own accounts.
  select x.* into other from bank_lines x join bank_accounts xa on xa.id = x.bank_account_id
  where x.org_id = bl.org_id and x.bank_account_id <> bl.bank_account_id and x.amount = -bl.amount and x.status in ('unmatched', 'posted')
    and x.line_date between bl.line_date - 2 and bl.line_date + 2 and (x.status = 'unmatched' or x.stage = 'transfer_one_leg')
  order by abs(x.line_date - bl.line_date) limit 1;
  if other.id is not null then
    select * into ob from bank_accounts where id = other.bank_account_id;
    if other.status = 'unmatched' then
      j := private.post_entry(bl.org_id, 'Transfer between own accounts · ' || b.name || ' and ' || ob.name, 'bank', bl.id, m.id, null,
        private.reclass_pair(case when v_in then b.ledger_code else ob.ledger_code end, case when v_in then ob.ledger_code else b.ledger_code end, v_amt, null, null),
        v_at, jsonb_build_object('evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id), jsonb_build_object('type', 'bank_line', 'id', other.id))));
      update bank_lines set status = 'matched', journal_id = j.id, stage = 'transfer', matched_by = 'system', confidence = 1 where id in (bl.id, other.id);
    else
      j := private.post_bank_line(bl.id, private.acct(bl.org_id, 'bank_clearing'), null, null, 'Transfer between own accounts · ' || ob.name, 'transfer',
        jsonb_build_object('matched_by', 'system'), 'matched');
      update bank_lines set stage = 'transfer' where id = other.id;
    end if;
    return 'transfer';
  end if;
  -- 6b Money sent to Bujeti from this account (or taken back from it): a transfer to or from the Bujeti balance.
  if upper(v_text) ~ '\yBUJETI\y' then
    select xa.* into ob from bank_accounts xa where xa.org_id = bl.org_id and xa.id <> b.id and xa.active and xa.provider = 'integration'
      and xa.provider_ref = bl.org_id::text || ':bujeti';
    if ob.id is not null then
      perform private.post_bank_line(bl.id, ob.ledger_code, null, null, case when v_in then 'Money back from Bujeti · ' else 'Money sent to Bujeti · ' end || bl.description,
        'transfer', jsonb_build_object('matched_by', 'system'));
      return 'transfer';
    end if;
  end if;
  if exists (select 1 from bank_accounts xa where xa.org_id = bl.org_id and xa.id <> b.id and xa.active
             and ((xa.account_number is not null and position(xa.account_number in coalesce(bl.counterparty_account, '') || ' ' || bl.description) > 0)
                  or upper(bl.description) ~ '(OWN ACCOUNT|SELF TRANSFER|TRF TO SELF|SWEEP)')) then
    perform private.post_bank_line(bl.id, private.acct(bl.org_id, 'bank_clearing'), null, null, 'Transfer between own accounts, other side to come', 'transfer_one_leg',
      jsonb_build_object('matched_by', 'system'));
    return 'transfer_one_leg';
  end if;

  -- 7 A rule learned from an earlier decision.
  select * into v_rule from entity_rules er where er.org_id = bl.org_id and er.direction = case when v_in then 'in' else 'out' end
    and v_key is not null and (er.party_key = v_key or position(er.party_key in v_key) > 0) order by length(er.party_key) desc limit 1;
  if v_rule.id is not null and private.postable(bl.org_id, v_rule.account_code) then
    if v_in and v_rule.customer_id is not null and v_rule.account_code ~ '^(1101|1102)' then
      -- A customer's money to what they owe goes to their invoices, as a person's answer does.
      mr := m;
      mr.display_name := 'a learned rule';
      perform private.apply_match(bl.id, private.customer_pick(bl.org_id, v_rule.customer_id, v_amt), mr, null);
      update bank_lines set stage = 'rule', matched_by = 'rule', confidence = 0.95 where id = bl.id;
    else
      perform private.post_bank_line(bl.id, v_rule.account_code,
        case when v_rule.customer_id is not null then 'customer' when v_rule.vendor_id is not null then 'vendor' end, coalesce(v_rule.customer_id, v_rule.vendor_id),
        null, 'rule', jsonb_build_object('matched_by', 'rule', 'ai_confidence', 0.95));
    end if;
    update entity_rules set hits = hits + 1 where id = v_rule.id;
    return 'rule';
  end if;

  -- 8 Payee types: bank charges, power, telcos, internet, fuel, CAC, interest received.
  select * into r from payee_registry pr where pr.kind not like 'statutory%' and pr.direction in (case when v_in then 'in' else 'out' end, 'both')
    and upper(bl.description || ' ' || coalesce(bl.counterparty, '')) ~ pr.pattern order by pr.id limit 1;
  if r.id is not null then
    perform private.post_bank_line(bl.id, coalesce(case when r.role is not null then private.acct(bl.org_id, r.role) end, r.account_code), null, null,
      r.description || ' · ' || bl.description, 'registry', jsonb_build_object('matched_by', 'rule', 'ai_confidence', 0.9));
    return 'registry';
  end if;

  -- 9 Nobody named: the open invoices (or bills) the amount fits, as it stands, less WHT or less bank charges, are put to a
  --   person to confirm in one tap.
  v_cands := private.match_candidates(bl.id);
  if jsonb_array_length(v_cands) > 0 then
    perform private.propose_match(bl.id, v_cands, case when v_in then 'invoice_amount' else 'bill_amount' end);
    return case when v_in then 'invoice_amount' else 'bill_amount' end;
  end if;
  return null;
end $$;

create or replace function public.resolve_proposal(p_proposal uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare pr public.ai_proposals; m public.members; bl public.bank_lines; v_code text; v_action text := coalesce(nullif(p->>'action', ''), 'approve'); j public.journals;
  b public.bank_accounts; v_amt numeric; v_party_type text := nullif(p->>'party_type', ''); v_party uuid := nullif(p->>'party_id', '')::uuid;
  v_at timestamptz; v_cands jsonb; v_pick jsonb; v_res jsonb; v_i int; v_hold uuid;
begin
  select * into pr from ai_proposals where id = p_proposal for update;
  if not found then raise exception 'Not found.'; end if;
  m := private.require(pr.org_id, 'keep_books');
  if pr.status not in ('pending', 'auto_posted', 'info') then raise exception 'This was already decided.'; end if;
  if v_action = 'dismiss' then
    if pr.status = 'pending' and pr.holding_journal_id is not null then raise exception 'Choose where this goes, or mark it as not a real transaction.'; end if;
    update ai_proposals set status = 'approved', decided_by = m.id, decided_at = now(), decision = p where id = pr.id;
    return jsonb_build_object('status', 'dismissed');
  end if;
  if pr.source_type <> 'bank_line' then
    raise exception 'Open the % to decide it.', replace(pr.kind, '_', ' ');
  end if;
  select * into bl from bank_lines where id = pr.source_id for update;
  select * into b from bank_accounts where id = bl.bank_account_id;
  v_amt := abs(bl.amount);
  if v_action = 'ignore' then
    -- Not a real transaction (a duplicate or a reversed transfer on the statement): the suspense entry is taken back.
    if pr.holding_journal_id is not null then perform private.reverse_entry(pr.holding_journal_id, m.id, 'Not a real transaction: ' || coalesce(p->>'note', ''), null); end if;
    if pr.status = 'auto_posted' and pr.journal_id is not null and not private.undo_bank_line_sale(bl.id, m, 'Not a real transaction') then
      perform private.reverse_entry(pr.journal_id, m.id, 'Not a real transaction', null);
    end if;
    update bank_lines set status = 'ignored', note = nullif(trim(p->>'note'), '') where id = bl.id;
    update ai_proposals set status = 'rejected', decided_by = m.id, decided_at = now(), decision = p where id = pr.id;
    return jsonb_build_object('status', 'ignored');
  end if;
  v_at := private.line_time(pr.org_id, bl.line_date);
  -- Confirming one of the invoices or bills the matcher proposed (the first unless another is chosen).
  if pr.status = 'pending' and pr.proposal->>'kind' in ('invoice_match', 'bill_match') and v_action = 'approve'
     and (nullif(p->>'account_code', '') is null or (p->>'account_code' = pr.proposal->>'account_code' and coalesce(p->>'party_id', pr.proposal->>'party_id') = pr.proposal->>'party_id')
          or p ? 'candidate' or p ? 'sale_id' or p ? 'bill_id') then
    v_cands := coalesce(pr.proposal->'candidates',
      jsonb_build_array(jsonb_build_object('kind', case when pr.proposal->>'kind' = 'invoice_match' then 'sale' else 'bill' end,
        'id', coalesce(pr.proposal->>'sale_id', pr.proposal->>'bill_id'), 'number', pr.proposal->>'number', 'party_id', pr.proposal->>'party_id',
        'basis', null)));
    if nullif(p->>'sale_id', '') is not null or nullif(p->>'bill_id', '') is not null then
      select c into v_pick from jsonb_array_elements(v_cands) c where c->>'id' = coalesce(nullif(p->>'sale_id', ''), p->>'bill_id') limit 1;
      if v_pick is null then raise exception 'Choose one of the documents proposed, or say what this payment was.'; end if;
    else
      v_i := coalesce(nullif(p->>'candidate', '')::int, 0);
      v_pick := v_cands->v_i;
      if v_pick is null then raise exception 'Choose one of the documents proposed.'; end if;
    end if;
    v_res := private.apply_match(bl.id, v_pick, m, case when pr.status = 'pending' then pr.holding_journal_id end);
    update ai_proposals set status = 'approved', decided_by = m.id, decided_at = now(), decision = p || jsonb_build_object('chosen', v_pick),
      journal_id = (v_res->>'journal_id')::uuid where id = pr.id;
    return jsonb_build_object('status', 'approved', 'journal_ref', (select ref from journals where id = (v_res->>'journal_id')::uuid), 'settled', v_res->>'settled');
  end if;
  v_code := coalesce(nullif(p->>'account_code', ''), pr.proposal->>'account_code');
  if v_code is null or not private.postable(pr.org_id, v_code) or v_code = b.ledger_code then raise exception 'Choose the account this belongs to.'; end if;
  if v_code ~ '^(1101|1102)' and v_party_type is distinct from 'customer' then raise exception 'Say which customer.'; end if;
  if v_code ~ '^(2101|2102)' and v_party_type is distinct from 'vendor' then raise exception 'Say which vendor.'; end if;
  if v_code ~ '^(2201|1402|2202|1401)' then raise exception 'VAT and WHT come only from invoices and bills, not from bank lines.'; end if;
  -- Money in from a customer, to what they owe: applied to their invoices (the one it fits, less any WHT or levy they kept
  -- back; otherwise the oldest first; held as their credit when nothing is owed), so each invoice shows what was paid.
  if bl.amount > 0 and v_code ~ '^(1101|1102)'
     and ((pr.status = 'pending' and pr.holding_journal_id is not null)
          or (pr.status = 'auto_posted' and v_action = 'change' and v_code <> pr.proposal->>'account_code')) then
    if v_party is null or not exists (select 1 from customers where id = v_party and org_id = pr.org_id) then raise exception 'Say which customer.'; end if;
    v_hold := case when pr.status = 'pending' then pr.holding_journal_id end;
    if pr.status = 'auto_posted' and not private.undo_bank_line_sale(bl.id, m, 'Corrected by ' || coalesce(m.display_name, 'a person')) then
      v_hold := pr.journal_id;
    end if;
    v_pick := private.customer_pick(pr.org_id, v_party, v_amt);
    v_res := private.apply_match(bl.id, v_pick, m, v_hold);
  -- The agent took it as a sale and a person says otherwise: the sale is taken back and the line posted where they say.
  elsif pr.status = 'auto_posted' and v_action = 'change' and v_code <> pr.proposal->>'account_code'
     and private.undo_bank_line_sale(bl.id, m, 'Corrected by ' || coalesce(m.display_name, 'a person')) then
    j := private.post_bank_line(bl.id, v_code, v_party_type, v_party, bl.description, 'user', jsonb_build_object('matched_by', 'user'));
  -- Money in taken as sales with no Counta invoice behind it: a sale with its VAT, as the business answered for such money.
  elsif bl.amount > 0 and private.is_sales_account(pr.org_id, v_code) and private.vat_on_sales(pr.org_id)
     and ((pr.status = 'pending' and pr.holding_journal_id is not null) or (pr.status = 'auto_posted' and v_action = 'change' and v_code <> pr.proposal->>'account_code')) then
    perform private.reverse_entry(case when pr.status = 'pending' then pr.holding_journal_id else pr.journal_id end, m.id, 'Taken as a sale with VAT', null);
    update bank_lines set status = 'unmatched', journal_id = null where id = bl.id;
    j := private.bank_line_sale(bl.id, v_code, v_party_type, v_party, 'user', jsonb_build_object('matched_by', 'user'), m);
  elsif pr.status = 'pending' and pr.holding_journal_id is not null then
    -- Out of suspense into the account chosen.
    j := private.post_entry(pr.org_id, 'Confirmed: ' || bl.description, 'reclass', bl.id, m.id, m.id,
      case when bl.amount > 0 then jsonb_build_array(
          jsonb_build_object('code', private.acct(pr.org_id, 'suspense'), 'debit', v_amt, 'memo', 'Out of suspense'),
          jsonb_build_object('code', v_code, 'credit', v_amt, 'party_type', v_party_type, 'party_id', v_party, 'memo', bl.description))
        else jsonb_build_array(
          jsonb_build_object('code', v_code, 'debit', v_amt, 'party_type', v_party_type, 'party_id', v_party, 'memo', bl.description),
          jsonb_build_object('code', private.acct(pr.org_id, 'suspense'), 'credit', v_amt, 'memo', 'Out of suspense')) end,
      v_at,
      jsonb_build_object('origin', 'manual', 'ai_confidence', pr.confidence, 'ai_proposal_id', pr.id,
        'evidence', jsonb_build_array(jsonb_build_object('type', 'bank_line', 'id', bl.id), jsonb_build_object('type', 'decision', 'by', m.display_name, 'note', p->>'note'))));
    update bank_lines set status = 'posted', stage = 'user', matched_by = 'user', confidence = 1 where id = bl.id;
  elsif pr.status = 'auto_posted' and v_action = 'change' and v_code <> pr.proposal->>'account_code' then
    -- The agent posted it, a person says otherwise: move it.
    j := private.post_entry(pr.org_id, 'Corrected: ' || bl.description, 'reclass', bl.id, m.id, m.id,
      private.reclass_pair(v_code, pr.proposal->>'account_code', case when bl.amount > 0 then -v_amt else v_amt end, null, null), now(),
      jsonb_build_object('origin', 'manual', 'ai_proposal_id', pr.id));
  end if;
  update ai_proposals set status = 'approved', decided_by = m.id, decided_at = now(),
    decision = p || jsonb_build_object('account_code', v_code) || case when v_res is not null then jsonb_build_object('chosen', v_pick) else '{}'::jsonb end,
    journal_id = coalesce(j.id, (v_res->>'journal_id')::uuid, journal_id) where id = pr.id;
  -- Learn the party for next time (CLS-05).
  if coalesce((p->>'remember')::boolean, false) and bl.party_key is not null then
    insert into entity_rules (org_id, party_key, direction, account_code, vendor_id, customer_id, note, source, created_by)
    values (pr.org_id, bl.party_key, case when bl.amount > 0 then 'in' else 'out' end, v_code,
      case when v_party_type = 'vendor' then v_party end, case when v_party_type = 'customer' then v_party end, nullif(trim(p->>'note'), ''), 'reviewer', m.id)
    on conflict (org_id, party_key, direction) do update set account_code = excluded.account_code, vendor_id = excluded.vendor_id, customer_id = excluded.customer_id,
      note = coalesce(excluded.note, entity_rules.note);
  end if;
  return jsonb_build_object('status', 'approved', 'journal_ref', coalesce(j.ref, (select ref from journals where id = (v_res->>'journal_id')::uuid)))
    || case when v_res is not null then jsonb_build_object('settled', v_res->>'settled', 'credit', v_res->'credit') else '{}'::jsonb end;
end $$;

create or replace function public.svc_work(p_kind text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  if p_kind = 'requests' then
    update payment_requests set status = 'expired' where status = 'pending' and expires_at < now() - interval '30 minutes';
    update payment_requests set status = 'failed', error = coalesce(error, 'The payment rail did not answer.') where status = 'creating' and created_at < now() - interval '10 minutes';
    -- Transfers to the business's own number are found on the wallet's statement, not by asking the rail about the request.
    return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'tx_ref', tx_ref, 'rail', rail, 'org_id', org_id)), '[]'::jsonb) from (
      select id, tx_ref, rail, org_id from payment_requests
      where status = 'pending' and not direct and created_at < now() - interval '2 minutes' and created_at > now() - interval '2 days'
        and (checked_at is null or checked_at < now() - interval '4 minutes')
      order by created_at limit 50) x);
  elsif p_kind = 'direct_wallets' then
    return (select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'rail', w.rail, 'account_ref', w.account_ref, 'org_id', w.org_id)), '[]'::jsonb)
      from wallets w where w.status = 'active' and w.account_ref is not null
        and exists (select 1 from payment_requests r where r.wallet_id = w.id and r.direct and r.status = 'pending' and r.created_at > now() - interval '3 days'));
  elsif p_kind = 'sweeps' then
    return (select coalesce(jsonb_agg(jsonb_build_object('tx_ref', r.tx_ref, 'amount', r.paid_amount - coalesce(r.fee, 0), 'barter_id', w.barter_id,
        'reference', 'SWP-' || r.tx_ref, 'last_reference', r.sweep_ref, 'status', r.sweep_status)), '[]'::jsonb)
      from payment_requests r join wallets w on w.id = r.wallet_id
      where r.status = 'paid' and r.sweep_status in ('pending', 'failed') and w.barter_id is not null and r.paid_at > now() - interval '30 days');
  elsif p_kind = 'payouts' then
    return (select coalesce(jsonb_agg(jsonb_build_object('reference', p.reference, 'rail', w.rail, 'provider_ref', p.provider_ref)), '[]'::jsonb)
      from payouts p join wallets w on w.id = p.wallet_id where p.status = 'processing' and p.sent_at < now() - interval '5 minutes');
  elsif p_kind = 'wallets' then
    return (select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'rail', w.rail, 'account_ref', w.account_ref, 'org_id', w.org_id)), '[]'::jsonb)
      from wallets w where w.status = 'active');
  elsif p_kind = 'tax_wallets' then
    return (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'rail', t.rail, 'account_ref', t.account_ref, 'org_id', t.org_id, 'tax', true)), '[]'::jsonb)
      from tax_wallets t where t.status = 'active' and t.account_ref is not null);
  elsif p_kind = 'tax_transfers' then
    return private.tax_transfers_due();
  elsif p_kind = 'tax_payments' then
    return (select coalesce(jsonb_agg(jsonb_build_object('reference', x.reference, 'rail', t.rail, 'provider_ref', x.provider_ref)), '[]'::jsonb)
      from tax_payments x join tax_wallets t on t.id = x.tax_wallet_id where x.status = 'processing' and x.sent_at < now() - interval '5 minutes');
  elsif p_kind = 'batches' then
    return (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'number', b.number, 'title', b.title, 'mode', b.mode, 'rail', w.rail, 'account_ref', w.account_ref,
        'bulk', b.mode = 'bulk' and exists (select 1 from payment_rails r where r.code = w.rail and 'bulk_payout' = any(r.capabilities)),
        'barter_id', w.barter_id, 'provider_batch_ids', b.provider_batch_ids,
        'approved', (select count(*) from payouts where batch_id = b.id and status = 'approved'),
        'processing', (select count(*) from payouts where batch_id = b.id and status = 'processing')) order by b.sent_at), '[]'::jsonb)
      from payout_batches b join wallets w on w.id = b.wallet_id where b.status = 'sending');
  elsif p_kind = 'claims' then
    -- Customers who said ten minutes ago that they paid, and whose money has not been matched: the business is asked once.
    return (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'tx_ref', r.tx_ref, 'rail', r.rail, 'direct', r.direct, 'wallet_id', r.wallet_id)), '[]'::jsonb)
      from payment_requests r where r.status = 'pending' and r.claimed_at is not null and r.claim_flagged_at is null
        and r.claimed_at < now() - interval '10 minutes' and r.claimed_at > now() - interval '4 days');
  end if;
  raise exception 'Unknown work kind.';
end $$;

-- The document page's view of its payment: whether the customer has said they paid, and whether the business was asked.
create or replace function public.public_payment_status(p_token text) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object('status', s.status, 'balance', s.total - s.amount_paid - s.credited,
    'request', (select private.request_json(r) - 'sale_id' - 'payer'
        || jsonb_build_object('claimed_at', r.claimed_at, 'claim_amount', private.num(r.claim->>'amount'), 'claim_flagged', r.claim_flagged_at is not null)
      from payment_requests r where r.sale_id = s.id order by r.created_at desc limit 1))
  from sales s where s.public_token = p_token and s.status <> 'draft'
$$;

-- The customer's word, from the document's page, that they have paid: what they sent and the name on the account they paid
-- from. It makes Counta look for the transfer at once and lets a transfer of that amount be matched with no reference. It
-- never settles anything by itself. Called by the payments function, which then reads the wallet's statement.
create or replace function public.svc_public_claim(p_token text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.sales; r public.payment_requests; v_amt numeric := round(private.num(p->>'amount'), 2); v_due numeric; v_n int;
  v_name text := nullif(left(regexp_replace(trim(coalesce(p->>'name', '')), '\s+', ' ', 'g'), 80), '');
begin
  if coalesce(p_token, '') !~ '^[a-f0-9]{24,64}$' then raise exception 'Document not found.'; end if;
  select * into s from sales where public_token = p_token and status <> 'draft';
  if not found then raise exception 'Document not found.'; end if;
  select * into r from payment_requests where sale_id = s.id and status = 'pending' order by created_at desc limit 1 for update;
  if not found then raise exception 'Choose how you are paying first, then tell us once you have paid.'; end if;
  v_due := s.total - s.amount_paid - s.credited;
  if v_amt is null or v_amt <= 0 then raise exception 'Enter the amount you sent.'; end if;
  if v_amt > greatest(v_due, r.amount) + 0.004 then raise exception 'That is more than the % owed.', private.naira(greatest(v_due, r.amount)); end if;
  v_n := coalesce((r.claim->>'count')::int, 0) + 1;
  if v_n > 10 then raise exception 'Your payment is noted. % will confirm it once it arrives.', coalesce((select name from orgs where id = s.org_id), 'The business'); end if;
  update payment_requests set claimed_at = now(), claim = jsonb_build_object('amount', v_amt, 'name', coalesce(v_name, r.claim->>'name'), 'count', v_n, 'at', now())
  where id = r.id returning * into r;
  return jsonb_build_object('id', r.id, 'tx_ref', r.tx_ref, 'rail', r.rail, 'direct', r.direct, 'wallet_id', r.wallet_id);
end $$;

-- Ten minutes after a customer said they paid, with no money matched: the business is asked once, in the books inbox and
-- by notification, to check the bank and record the payment when they see it. The question closes itself when the money is
-- matched or the invoice is settled another way.
create or replace function public.svc_claim_unmatched(p_request uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare r public.payment_requests; s public.sales; v_who text; v_title text; v_q text; v_link text;
begin
  select * into r from payment_requests where id = p_request for update;
  if not found or r.status <> 'pending' or r.claimed_at is null or r.claim_flagged_at is not null then return jsonb_build_object('ok', true, 'asked', false); end if;
  select * into s from sales where id = r.sale_id;
  v_who := coalesce(nullif(s.customer_name, ''), (select name from customers where id = r.customer_id), 'A customer');
  v_title := v_who || ' says they paid ' || coalesce(s.number, 'their balance');
  v_q := v_who || ' said on ' || to_char(r.claimed_at at time zone 'Africa/Lagos', 'FMDD Mon "at" HH24:MI') || ' that they sent '
    || private.naira(private.num(r.claim->>'amount')) || coalesce(' from an account named ' || (r.claim->>'name'), '')
    || ', and it has not reached the wallet. Check the bank, then record the payment'
    || coalesce(' on ' || s.number, '') || ' when you see it.';
  v_link := case when s.id is not null then '/sell/sales?open=' || s.id else '/accounting/inbox' end;
  insert into ai_proposals (org_id, agent, kind, source_type, source_id, title, question, proposal, confidence, rationale, stage, status, amount)
  values (r.org_id, 'bookkeeper', 'payment_claim', 'payment_request', r.id, left(v_title, 200), v_q,
    jsonb_build_object('request_id', r.id, 'sale_id', r.sale_id, 'number', s.number, 'amount', private.num(r.claim->>'amount'), 'name', r.claim->>'name'),
    0.5, 'The customer''s word; nothing matching has reached the wallet', 'claim', 'pending', private.num(r.claim->>'amount'))
  on conflict do nothing;
  update payment_requests set claim_flagged_at = now() where id = r.id;
  perform private.notify_perm(r.org_id, 'keep_books', 'payment', v_title, v_q, v_link, 'claim-' || r.id);
  perform private.notify_perm(r.org_id, 'approve_adjustments', 'payment', v_title, v_q, v_link, 'claim-' || r.id);
  return jsonb_build_object('ok', true, 'asked', true);
end $$;

-- Every minute while a sale waits for a transfer to the business's own number: the payments function reads those
-- wallets' statements (the five-minute run does everything else).
create or replace function private.payments_direct_tick() returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if exists (select 1 from payment_requests where direct and status = 'pending' and created_at > now() - interval '3 days') then
    perform private.call_function('payments', jsonb_build_object('action', 'poll_direct'));
  end if;
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'counta-payments-direct';
    perform cron.schedule('counta-payments-direct', '* * * * *', $c$select private.payments_direct_tick()$c$);
  end if;
end $$;

revoke all on function private.customer_short_split(uuid, numeric, numeric), private.book_customer_withholding(uuid, uuid, uuid, jsonb, timestamptz, public.members),
  private.request_split(uuid, numeric), private.refresh_sale(uuid), private.customer_pick(uuid, uuid, numeric), private.apply_match(uuid, jsonb, public.members, uuid),
  private.match_bank_line(uuid), private.payments_direct_tick() from public, anon, authenticated;
revoke all on function public.svc_wallet_inflow(text, text, jsonb), public.svc_payment_confirmed(text, jsonb), public.svc_work(text),
  public.svc_public_claim(text, jsonb), public.svc_claim_unmatched(uuid) from public, anon, authenticated;
grant execute on function public.svc_wallet_inflow(text, text, jsonb), public.svc_payment_confirmed(text, jsonb), public.svc_work(text),
  public.svc_public_claim(text, jsonb), public.svc_claim_unmatched(uuid) to service_role;
revoke all on function public.resolve_proposal(uuid, jsonb) from public, anon;
grant execute on function public.resolve_proposal(uuid, jsonb) to authenticated, service_role;
grant execute on function public.public_payment_status(text) to anon, authenticated, service_role;
