-- Numens decides the VAT on lines typed on an invoice and on new products received as stock (20261204000100_vat_by_numens.sql):
-- the line takes the answer on record for its words, a person confirms or changes the answers Numens is not sure of
-- before the invoice is issued, a person's choice is theirs and Numens never undoes it, recurring schedules settle it
-- when they are saved, and lines from elsewhere keep their own VAT. Only fake people (example.test addresses).
begin;

-- Fixture: Ada owns Ada Clinic Ltd (VAT-registered) with Kola (staff: records sales and receives stock, sets no VAT) and
-- Tayo (accountant: keeps the books, records no sales); customer Bola Stores. Numens has answered for two services:
-- medical consultation (zero-rated, sure) and tuition (zero-rated, not sure).
do $$
declare o uuid;
begin
  perform tests.hooks_on();
  perform tests.remember('ada', tests.user('ada.owner@clinic.example.test', 'Ada Owner'));
  perform tests.remember('kola', tests.user('kola.staff@clinic.example.test', 'Kola Staff'));
  perform tests.remember('tayo', tests.user('tayo.books@clinic.example.test', 'Tayo Books'));
  o := tests.remember('o', tests.org(tests.id('ada'), 'Ada Clinic Ltd'));
  update orgs set vat_registered = true where id = o;
  perform tests.remember('kola_seat', tests.member(o, tests.id('kola'), 'staff'));
  perform tests.remember('tayo_seat', tests.member(o, tests.id('tayo'), 'accountant'));
  perform tests.as_user(tests.id('ada'));
  perform tests.remember('cu', public.save_customer(o, '{"name": "Bola Stores", "email": "bola@example.test"}'));
  perform tests.as_service();
  perform public.svc_line_vat_store(o, '[
    {"description": "Medical consultation", "treatment": "zero", "confidence": 0.95, "reason": "Medical services are zero-rated.", "law": "NTA 2025 s.187",
     "nrs_label": "Medical services", "source": "gemini", "model": "test-model"},
    {"description": "Tuition for primary pupils", "treatment": "zero", "confidence": 0.6, "reason": "Tuition looks zero-rated.", "law": "NTA 2025 s.187",
     "nrs_label": "Tuition relating to nursery, primary, secondary or tertiary education", "source": "gemini", "model": "test-model"}]'::jsonb);
  perform tests.as_postgres();
end $$;

-- An invoice as the app saves it: typed lines, each {description, vat_treatment, vat_by}, 100,000 each.
create function pg_temp.doc(p_lines jsonb, p_status text default 'draft', p_id uuid default null) returns jsonb language sql as $f$
  select public.save_sale_doc(tests.id('o'), jsonb_build_object('id', p_id, 'customer_id', tests.id('cu'), 'status', p_status, 'prices_include_vat', false,
    'lines', (select jsonb_agg(l || '{"qty": 1, "unit_price": 100000}'::jsonb) from jsonb_array_elements(p_lines) l)))
$f$;

create function pg_temp.line(p_sale uuid, p_desc text) returns public.sale_lines language sql as $f$
  select * from sale_lines where sale_id = p_sale and description = p_desc
$f$;

-- test: lines_take_numens
-- A typed line marked for Numens takes the answer on record whatever the app sent, with its reason and NRS description; one
-- with nothing on record waits for Numens; a line not marked (another caller) keeps its own VAT.
do $$
declare s jsonb; v uuid;
begin
  perform tests.as_user(tests.id('ada'));
  s := pg_temp.doc('[{"description": "Medical  consultation", "vat_treatment": "standard", "vat_by": "numens"},
                     {"description": "Tuition for primary pupils", "vat_treatment": "standard", "vat_by": "numens"},
                     {"description": "Report writing", "vat_treatment": "standard", "vat_by": "numens"},
                     {"description": "Old style line", "vat_treatment": "exempt"}]');
  v := (s->>'id')::uuid;
  perform tests.remember('draft', v);
  perform tests.as_postgres();
  assert (select vat_treatment = 'zero' and vat = 0 and vat_basis->>'source' = 'gemini' and (vat_basis->>'confidence')::numeric = 0.95
            and vat_basis->>'reason' = 'Medical services are zero-rated.' and nrs_vat_label = 'Medical services'
          from pg_temp.line(v, 'Medical  consultation')), format('lines_take_numens: medical, got %s', to_jsonb(pg_temp.line(v, 'Medical  consultation')));
  assert (select vat_treatment = 'zero' and (vat_basis->>'confidence')::numeric = 0.6 from pg_temp.line(v, 'Tuition for primary pupils')),
    'lines_take_numens: tuition takes the answer Numens is not sure of';
  assert (select vat_treatment = 'standard' and vat = 7500 and vat_basis = '{"source": "waiting"}' from pg_temp.line(v, 'Report writing')),
    'lines_take_numens: nothing on record waits for Numens';
  assert (select vat_treatment = 'exempt' and vat_basis is null from pg_temp.line(v, 'Old style line')), 'lines_take_numens: an unmarked line keeps its VAT';
  assert (select count(*) from line_vat where org_id = tests.id('o')) = 2, 'lines_take_numens: reading changes nothing on record';
  assert (s->'lines'->0 ? 'vat_basis'), 'lines_take_numens: the app sees the basis';
end $$;

-- test: issue_asks
-- Issuing refuses the lines Numens is not sure of or has not answered, naming them; the person confirms one and changes
-- the other in the editor, and the invoice is issued. Their choices are recorded as theirs, Numens' answer kept beside.
do $$
declare s jsonb; v uuid := tests.id('draft');
begin
  perform tests.as_user(tests.id('ada'));
  perform tests.throws(format('select public.issue_invoice(%L)', v), '%Check the VAT on "Tuition for primary pupils", "Report writing" before issuing%');
  s := pg_temp.doc('[{"description": "Medical  consultation", "vat_treatment": "zero", "vat_by": "numens"},
                     {"description": "Tuition for primary pupils", "vat_treatment": "zero", "vat_by": "person"},
                     {"description": "Report writing", "vat_treatment": "exempt", "vat_by": "person"},
                     {"description": "Old style line", "vat_treatment": "exempt"}]', 'issue', v);
  perform tests.as_postgres();
  assert s->>'status' <> 'draft', format('issue_asks: issued, got %s', s->>'status');
  assert (select source = 'person' and treatment = 'zero' and by_name = 'Ada Owner' and ai->>'treatment' = 'zero' and (ai->>'confidence')::numeric = 0.6
            and nrs_label = 'Tuition relating to nursery, primary, secondary or tertiary education' and confidence is null
          from line_vat where org_id = tests.id('o') and key = 'tuition for primary pupils'), 'issue_asks: confirming records the person';
  assert (select source = 'person' and treatment = 'exempt' and ai is null and nrs_label is null from line_vat where org_id = tests.id('o') and key = 'report writing'),
    'issue_asks: choosing with nothing on record';
  assert (select vat_treatment = 'exempt' and vat_basis->>'source' = 'person' and vat_basis->>'by' = 'Ada Owner' from pg_temp.line(v, 'Report writing')),
    'issue_asks: the line carries the person''s choice';
  -- The customer's copy shows each line's VAT, not who decided it or why.
  assert (select jsonb_array_length(d->'lines') = 4 and not exists (select 1 from jsonb_array_elements(d->'lines') l where l ? 'vat_basis')
          from (select public.public_document((select public_token from sales where id = v)) d) x),
    format('issue_asks: the public copy, got %s', public.public_document((select public_token from sales where id = v))->'lines'->0);
end $$;

-- test: person_stands
-- The person's choice is used for the same words next time (case and spacing aside), Numens never replaces it, and the
-- same choice made again changes nothing on record.
do $$
declare s jsonb; v_at timestamptz;
begin
  perform tests.as_service();
  perform public.svc_line_vat_store(tests.id('o'), '[{"description": "Report writing", "treatment": "standard", "confidence": 0.99, "reason": "x", "source": "numens"}]');
  perform tests.as_postgres();
  assert (select source = 'person' and treatment = 'exempt' from line_vat where org_id = tests.id('o') and key = 'report writing'), 'person_stands: Numens leaves it';
  v_at := (select updated_at from line_vat where org_id = tests.id('o') and key = 'report writing');
  perform tests.as_user(tests.id('kola'));
  s := pg_temp.doc('[{"description": "REPORT   writing", "vat_treatment": "standard", "vat_by": "numens"},
                     {"description": "report writing", "vat_treatment": "exempt", "vat_by": "person"}]', 'issue');
  perform tests.as_postgres();
  assert s->>'status' <> 'draft' and (select bool_and(vat_treatment = 'exempt' and vat_basis->>'by' = 'Ada Owner') from sale_lines where sale_id = (s->>'id')::uuid),
    'person_stands: both lines take Ada''s choice';
  assert (select updated_at = v_at and by_name = 'Ada Owner' from line_vat where org_id = tests.id('o') and key = 'report writing'),
    'person_stands: the same choice again changes nothing';
end $$;

-- test: lookup_and_store
-- What the app reads: the threshold and what is on record, in the order asked; only those who record sales may ask, and
-- only the service stores Numens' answers (an NRS description off the list for the treatment is dropped).
do $$
declare r jsonb;
begin
  update orgs set auto_post_threshold = 0.9 where id = tests.id('o');
  perform tests.as_user(tests.id('kola'));
  r := public.line_vat_lookup(tests.id('o'), '["Physiotherapy session", "medical consultation"]');
  perform tests.as_postgres();
  assert (r->>'threshold')::numeric = 0.9, 'lookup_and_store: the business threshold';
  assert r->'lines'->0 = '{"description": "Physiotherapy session"}' and r->'lines'->1->>'treatment' = 'zero' and r->'lines'->1->>'source' = 'gemini'
    and r->'lines'->1->>'description' = 'medical consultation', format('lookup_and_store: rows, got %s', r);
  perform tests.as_user(tests.id('tayo'));
  perform tests.throws(format('select public.line_vat_lookup(%L, %L)', tests.id('o'), '["x"]'), '%Your role does not allow this (record sales)%');
  perform tests.throws(format('select public.svc_line_vat_store(%L, %L)', tests.id('o'), '[]'), '%permission denied%');
  perform tests.as_anon();
  perform tests.throws(format('select public.line_vat_lookup(%L, %L)', tests.id('o'), '["x"]'), '%permission denied%');
  perform tests.as_service();
  r := public.svc_line_vat_store(tests.id('o'), '[{"description": "Physiotherapy session", "treatment": "zero", "confidence": 1.7, "nrs_label": "Government licences"},
    {"description": "", "treatment": "zero"}, {"description": "Bad", "treatment": "free"}]');
  perform tests.as_postgres();
  assert jsonb_array_length(r) = 1 and (r->0->>'confidence')::numeric = 1 and not (r->0 ? 'nrs_label') and r->0->>'source' = 'gemini',
    format('lookup_and_store: stored and cleaned, got %s', r);
  update orgs set auto_post_threshold = 0.8 where id = tests.id('o');
end $$;

-- test: quote_keeps_basis
-- A quote turned into an invoice keeps its typed lines with Numens.
do $$
declare q jsonb; inv jsonb;
begin
  perform tests.as_user(tests.id('ada'));
  q := public.save_sale_doc(tests.id('o'), jsonb_build_object('doc_type', 'quote', 'customer_id', tests.id('cu'),
    'lines', '[{"description": "Medical consultation", "qty": 1, "unit_price": 5000, "vat_treatment": "standard", "vat_by": "numens"}]'::jsonb));
  inv := public.convert_quote((q->>'id')::uuid);
  perform tests.as_postgres();
  assert (select vat_treatment = 'zero' and vat_basis->>'source' = 'gemini' from sale_lines where sale_id = (inv->>'id')::uuid),
    format('quote_keeps_basis: got %s', inv->'lines');
end $$;

-- test: recurring_settles_vat
-- A schedule with a line Numens is not sure of, or has not answered, is refused until the person decides; saved, each line
-- carries the decision, a save that leaves the lines alone keeps them as they are, and each run takes the VAT on record.
do $$
declare p jsonb; r jsonb; v_lines jsonb; v_sale uuid;
begin
  perform tests.as_user(tests.id('ada'));
  p := jsonb_build_object('customer_id', tests.id('cu'), 'frequency', 'monthly', 'day_of_month', 1, 'start_date', '2026-01-01', 'auto_send', false);
  perform tests.throws(format('select public.recurring_save(%L, %L)', tests.id('o'), p || '{"lines": [{"description": "Tuition for secondary pupils", "qty": 1,
    "unit_price": 50000, "vat_treatment": "standard", "vat_by": "numens"}]}'), '%Numens has not checked the VAT on "Tuition for secondary pupils"%');
  perform tests.as_service();
  perform public.svc_line_vat_store(tests.id('o'), '[{"description": "Tuition for secondary pupils", "treatment": "zero", "confidence": 0.5}]');
  perform tests.as_user(tests.id('ada'));
  perform tests.throws(format('select public.recurring_save(%L, %L)', tests.id('o'), p || '{"lines": [{"description": "Tuition for secondary pupils", "qty": 1,
    "unit_price": 50000, "vat_treatment": "standard", "vat_by": "numens"}]}'), '%Check the VAT on "Tuition for secondary pupils" first%');
  r := public.recurring_save(tests.id('o'), p || '{"lines": [{"description": "Tuition for secondary pupils", "qty": 1, "unit_price": 50000,
    "vat_treatment": "zero", "vat_by": "person"}, {"description": "Medical consultation", "qty": 1, "unit_price": 10000, "vat_treatment": "standard",
    "vat_by": "numens"}, {"description": "Retainer", "qty": 1, "unit_price": 1000, "vat_treatment": "standard"}]}');
  v_lines := r->'lines';
  assert v_lines->0->>'vat_treatment' = 'zero' and v_lines->0->'vat_basis'->>'source' = 'person' and not (v_lines->0 ? 'vat_by')
    and v_lines->1->>'vat_treatment' = 'zero' and v_lines->1->'vat_basis'->>'source' = 'gemini'
    and not (v_lines->2 ? 'vat_basis') and v_lines->2->>'vat_treatment' = 'standard', format('recurring_settles_vat: saved lines, got %s', v_lines);
  r := public.recurring_save(tests.id('o'), jsonb_build_object('id', r->>'id', 'notes', 'Monthly'));
  assert r->'lines' = v_lines, format('recurring_settles_vat: a save without lines keeps them, got %s', r->'lines');
  r := public.recurring_save(tests.id('o'), jsonb_build_object('id', r->>'id', 'lines', v_lines));
  assert r->'lines' = v_lines, 'recurring_settles_vat: the lines sent back as saved stay as they are';
  perform tests.as_postgres();
  -- A person changes the medical consultation on another invoice: the next run takes it.
  perform private.line_vat_decide(tests.id('o'), 'Medical consultation', 'person', 'exempt', (select m from members m where id = tests.id('kola_seat')));
  v_sale := private.recurring_run((r->>'id')::uuid, '2026-01-01');
  assert (select vat_treatment = 'exempt' and vat_basis->>'by' = 'Kola Staff' from sale_lines where sale_id = v_sale and description = 'Medical consultation')
     and (select vat_treatment = 'standard' and vat_basis is null from sale_lines where sale_id = v_sale and description = 'Retainer')
     and (select status from sales where id = v_sale) <> 'draft', 'recurring_settles_vat: the run takes the VAT on record';
end $$;

-- test: no_vat_no_question
-- Where the lines carry no VAT whatever they are, nobody is asked: an export, and a business that does not charge VAT
-- (whose recurring schedules save without Numens' answer).
do $$
declare s jsonb; v_gh uuid; r jsonb;
begin
  perform tests.as_user(tests.id('ada'));
  v_gh := public.save_customer(tests.id('o'), '{"name": "Accra Buyers", "email": "accra@example.test", "country": "GH"}');
  s := public.save_sale_doc(tests.id('o'), jsonb_build_object('customer_id', v_gh, 'status', 'issue',
    'lines', '[{"description": "Market research report", "qty": 1, "unit_price": 1000, "vat_treatment": "standard", "vat_by": "numens"}]'::jsonb));
  assert s->>'status' <> 'draft' and (s->'lines'->0->>'vat_treatment') = 'zero', format('no_vat_no_question: the export is issued, got %s', s->>'status');
  perform tests.as_postgres();
  update orgs set vat_registered = false where id = tests.id('o');
  perform tests.as_user(tests.id('ada'));
  s := pg_temp.doc('[{"description": "Data entry", "vat_treatment": "standard", "vat_by": "numens"}]', 'issue');
  assert s->>'status' <> 'draft', 'no_vat_no_question: a business that charges no VAT issues';
  r := public.recurring_save(tests.id('o'), jsonb_build_object('customer_id', tests.id('cu'), 'frequency', 'monthly', 'day_of_month', 1, 'start_date', '2026-01-01',
    'auto_send', false, 'lines', '[{"description": "Data entry", "qty": 1, "unit_price": 100, "vat_treatment": "standard", "vat_by": "numens"}]'::jsonb));
  assert r->'lines'->0 = '{"description": "Data entry", "qty": 1, "unit_price": 100, "vat_treatment": "standard", "once": false}',
    format('no_vat_no_question: the schedule saves as it was, got %s', r->'lines');
  perform tests.as_postgres();
  update orgs set vat_registered = true where id = tests.id('o');
end $$;

-- test: new_product_vat
-- A new product received as stock: Numens' sweep decides its VAT, unless the person who chose it may set VAT.
do $$
declare v_rc uuid; v_due jsonb; v_loc uuid := (select id from locations where org_id = tests.id('o') order by is_main desc limit 1);
begin
  insert into receipts (org_id, ref, source, status, location_id, vendor_name, vendor_vat_registered)
  values (tests.id('o'), 'RCV-VAT-1', 'manual', 'needs_review', v_loc, 'Medi Supplies', true) returning id into v_rc;
  insert into receipt_lines (receipt_id, org_id, line_no, new_item, qty, unit_kind, unit_cost, confirmed) values
    (v_rc, tests.id('o'), 1, '{"name": "Gauze roll", "pack_size": 1, "vat_treatment": "zero", "vat_by": "person"}', 2, 'purchase', 1000, true),
    (v_rc, tests.id('o'), 2, '{"name": "Hand towel", "pack_size": 1}', 1, 'purchase', 500, true);
  perform tests.as_user(tests.id('ada'));
  perform public.post_receipt(v_rc);
  perform tests.as_postgres();
  assert (select vat_treatment = 'zero' and vat_basis->>'source' = 'manual' and vat_basis->>'by' = 'Ada Owner' and vat_checked_at is not null
          from items where org_id = tests.id('o') and name = 'Gauze roll'), 'new_product_vat: the owner''s choice stands';
  assert (select vat_treatment = 'standard' and vat_basis is null and vat_checked_at is null from items where org_id = tests.id('o') and name = 'Hand towel'),
    'new_product_vat: Numens decides the other';
  perform tests.as_service();
  v_due := public.svc_items_for_vat(60);
  perform tests.as_postgres();
  assert exists (select 1 from jsonb_array_elements(v_due) x where x->>'name' = 'Hand towel')
     and not exists (select 1 from jsonb_array_elements(v_due) x where x->>'name' = 'Gauze roll'), format('new_product_vat: the sweep picks up only Numens'' one, got %s', v_due);

  insert into receipts (org_id, ref, source, status, location_id, vendor_name, vendor_vat_registered)
  values (tests.id('o'), 'RCV-VAT-2', 'manual', 'needs_review', v_loc, 'Medi Supplies', true) returning id into v_rc;
  insert into receipt_lines (receipt_id, org_id, line_no, new_item, qty, unit_kind, unit_cost, confirmed) values
    (v_rc, tests.id('o'), 1, '{"name": "Face mask box", "pack_size": 1, "vat_treatment": "exempt", "vat_by": "person"}', 1, 'purchase', 800, true);
  perform tests.as_user(tests.id('kola'));
  perform public.post_receipt(v_rc);
  perform tests.as_postgres();
  assert (select vat_basis is null and vat_checked_at is null from items where org_id = tests.id('o') and name = 'Face mask box'),
    'new_product_vat: staff who set no VAT leave it to Numens';
end $$;

rollback;
