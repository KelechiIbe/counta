-- Release 3 of the identity work (20261127000100_letterhead_and_vat_switch.sql): a firm's own letterhead on its engagement
-- letters (uploaded or built in Counta, checked file by file, printed on letters a partner signs from then on and kept on
-- them), the preview of a letter before anyone signs it, and VAT turned on by Counta every morning for a business that
-- must charge it, with why kept and everyone who keeps its books told. A draft saved before VAT changed is saved again
-- before it is issued. Only fake people (example.test addresses).
begin;

-- Fixture: practice Head Partners (partner Bisi, partner Kunle, manager Tola, staff Ife) with an office address, phone and
-- registration number; another practice (partner Kemi); a cleared involved intake and its draft letter; letterhead files in
-- storage as the browser would have uploaded them. Ada owns Ada Traders Ltd, which does not charge VAT, with Bimpe (admin)
-- and Kola (staff); the practice keeps its books (involved).
do $$
declare pr uuid; pr2 uuid; i uuid; o uuid; v_ada uuid; f text;
begin
  perform tests.hooks_on();
  perform tests.remember('bisi', tests.user('bisi.partner@head.example.test', 'Bisi Partner'));
  perform tests.remember('kunle', tests.user('kunle.partner@head.example.test', 'Kunle Partner'));
  perform tests.remember('tola', tests.user('tola.manager@head.example.test', 'Tola Manager'));
  perform tests.remember('ife', tests.user('ife.staff@head.example.test', 'Ife Staff'));
  perform tests.remember('kemi', tests.user('kemi.partner@other.example.test', 'Kemi Partner'));
  pr := tests.remember('pr', tests.practice(tests.id('bisi'), 'Head Partners', true));
  update practices set email = 'office@head.example.test', phone = '+234 1 000 0001', state = 'Lagos', address = '3 Test Avenue, Ikoyi', firm_reg = 'BN 445566'
  where id = pr;
  perform tests.remember('bisi_pm', (select id from practice_members where practice_id = pr and user_id = tests.id('bisi')));
  perform tests.remember('kunle_pm', tests.practice_member(pr, tests.id('kunle'), 'partner'));
  perform tests.remember('tola_pm', tests.practice_member(pr, tests.id('tola'), 'manager'));
  perform tests.remember('ife_pm', tests.practice_member(pr, tests.id('ife'), 'staff'));
  update practice_members set created_at = created_at + interval '1 minute' where practice_id = pr and user_id <> tests.id('bisi');
  pr2 := tests.remember('pr2', tests.practice(tests.id('kemi'), 'Other Partners', true));

  i := tests.remember('i', tests.cleared_intake(pr, 'Dayo Foods Ltd'));
  perform tests.as_user(tests.id('bisi'));
  perform tests.remember('l', (public.practice_letter_draft(i, '{}')->>'id')::uuid);
  perform tests.as_postgres();

  insert into storage.buckets (id, name) values ('documents', 'documents') on conflict do nothing;
  foreach f in array array['first.pdf', 'next.pdf', 'letter.pdf', 'page.png', 'page.jpg', 'logo.png', 'big.pdf', 'wrong.pdf', 'logo-big.png'] loop
    insert into storage.objects (bucket_id, name, metadata) values ('documents', 'practice/' || pr || '/letterhead/' || f,
      jsonb_build_object('size', case f when 'big.pdf' then 6 * 1048576 when 'logo-big.png' then 3 * 1048576 else 120000 end,
        'mimetype', case when f = 'wrong.pdf' then 'image/png' when f like '%.pdf' then 'application/pdf' when f like '%.png' then 'image/png' else 'image/jpeg' end));
  end loop;
  insert into storage.objects (bucket_id, name, metadata) values ('documents', 'practice/' || pr2 || '/letterhead/first.pdf', '{"size": 1000, "mimetype": "application/pdf"}');

  v_ada := tests.remember('ada', tests.user('ada.owner@ada.example.test', 'Ada Owner'));
  perform tests.remember('bimpe', tests.user('bimpe.admin@ada.example.test', 'Bimpe Admin'));
  perform tests.remember('kola', tests.user('kola.staff@ada.example.test', 'Kola Staff'));
  o := tests.remember('o', tests.org(v_ada, 'Ada Traders Ltd'));
  update orgs set vat_registered = false, vat_opt_in = false where id = o;
  perform tests.remember('bimpe_seat', tests.member(o, tests.id('bimpe'), 'admin'));
  perform tests.remember('kola_seat', tests.member(o, tests.id('kola'), 'staff'));
  perform tests.remember('o_client', tests.involved_client(pr, o));
  perform tests.as_user(v_ada);
  perform tests.remember('cu', public.save_customer(o, '{"name": "Bola Stores", "email": "bola@example.test"}'));
  perform tests.as_postgres();
end $$;

-- A file as the browser describes it after uploading it to the practice's letterhead folder.
create function pg_temp.lh_file(p_name text, p_kind text, p_w numeric, p_h numeric, p_practice uuid default null) returns jsonb
language sql as $f$
  select jsonb_build_object('path', 'practice/' || coalesce(p_practice, tests.id('pr')) || '/letterhead/' || p_name, 'sha256', repeat('ab', 32),
    'kind', p_kind, 'w', p_w, 'h', p_h)
$f$;
create function pg_temp.a4(p_name text default 'first.pdf') returns jsonb language sql as $f$ select pg_temp.lh_file(p_name, 'pdf', 595.28, 841.89) $f$;

-- test: letterhead_upload
-- A partner sets an uploaded letterhead: kept as checked, with the defaults filled in, the same page and margins for the
-- following pages, and who set it and when. Plain (or null) takes it off.
do $$
declare pr uuid := tests.id('pr'); r jsonb; lh jsonb;
begin
  assert (select letterhead from practices where id = pr) is null, 'letterhead_upload: plain until set';
  perform tests.as_user(tests.id('bisi'));
  r := public.practice_set_letterhead(pr, jsonb_build_object('mode', 'upload', 'first', pg_temp.a4(), 'margins', '{"first_top": 160, "first_bottom": 80}'::jsonb));
  lh := r->'practice'->'letterhead';
  assert lh->>'mode' = 'upload' and lh->>'font' = 'helvetica' and lh->>'color' = '#111827' and lh->>'next_mode' = 'same', 'letterhead_upload: defaults';
  assert lh->'first'->>'path' = 'practice/' || pr || '/letterhead/first.pdf' and lh->'first'->>'kind' = 'pdf' and (lh->'first'->>'w')::numeric = 595.28,
    'letterhead_upload: the file';
  assert lh->'page' = '[595.28, 841.89]'::jsonb, 'letterhead_upload: the page is the PDF''s own';
  assert lh->'margins' = '{"first_top": 160, "first_bottom": 80, "next_top": 160, "next_bottom": 80, "left": 56, "right": 56}'::jsonb,
    'letterhead_upload: following pages keep the first page''s margins';
  assert lh->'next' = 'null'::jsonb, 'letterhead_upload: no second page';
  assert (r->'practice'->>'letterhead_set_by')::uuid = tests.id('bisi_pm') and (r->'practice'->>'letterhead_set_at') is not null, 'letterhead_upload: who and when';

  -- Another page for the following pages, with its own margins; or none at all.
  lh := public.practice_set_letterhead(pr, jsonb_build_object('mode', 'upload', 'first', pg_temp.a4(), 'next_mode', 'upload', 'next', pg_temp.a4('next.pdf'),
    'font', 'times', 'color', '#0b3b75', 'margins', '{"first_top": 160, "first_bottom": 80, "next_top": 90, "next_bottom": 60, "left": 60, "right": 50}'::jsonb))
    ->'practice'->'letterhead';
  assert lh->>'next_mode' = 'upload' and lh->'next'->>'path' like '%/next.pdf' and lh->>'font' = 'times' and lh->>'color' = '#0B3B75', 'letterhead_upload: a second page';
  assert lh->'margins' = '{"first_top": 160, "first_bottom": 80, "next_top": 90, "next_bottom": 60, "left": 60, "right": 50}'::jsonb, 'letterhead_upload: its margins';
  lh := public.practice_set_letterhead(pr, jsonb_build_object('mode', 'upload', 'first', pg_temp.a4(), 'next_mode', 'none'))->'practice'->'letterhead';
  assert lh->>'next_mode' = 'none' and (lh->'margins'->>'next_top')::numeric = 56 and (lh->'margins'->>'next_bottom')::numeric = 56, 'letterhead_upload: plain following pages';

  -- Pictures of a whole page: A4 or US Letter by their shape.
  lh := public.practice_set_letterhead(pr, jsonb_build_object('mode', 'upload', 'first', pg_temp.lh_file('page.png', 'png', 2480, 3508)))->'practice'->'letterhead';
  assert lh->'page' = '[595.28, 841.89]'::jsonb, 'letterhead_upload: an A4 picture';
  lh := public.practice_set_letterhead(pr, jsonb_build_object('mode', 'upload', 'first', pg_temp.lh_file('page.jpg', 'jpg', 2550, 3300)))->'practice'->'letterhead';
  assert lh->'page' = '[612, 792]'::jsonb, 'letterhead_upload: a US Letter picture';

  assert public.practice_set_letterhead(pr, '{"mode": "plain"}')->'practice'->'letterhead' = 'null'::jsonb, 'letterhead_upload: plain takes it off';
  assert public.practice_set_letterhead(pr, null)->'practice'->'letterhead' = 'null'::jsonb, 'letterhead_upload: so does null';
  perform tests.as_postgres();
end $$;

-- test: letterhead_built
-- A letterhead built in Counta: the logo, layout, colour, which details show (the website only when there is one), and a
-- footer of up to two lines.
do $$
declare pr uuid := tests.id('pr'); lh jsonb;
begin
  perform tests.as_user(tests.id('kunle'));
  lh := public.practice_set_letterhead(pr, '{"mode": "built"}')->'practice'->'letterhead';
  assert lh = '{"mode": "built", "font": "helvetica", "color": "#0B3B75", "logo": null, "layout": "left", "show": {"address": true, "phone": true,
    "email": true, "firm_reg": true, "website": false}, "website": null, "footer": null, "page": [595.28, 841.89]}'::jsonb, 'letterhead_built: defaults';
  lh := public.practice_set_letterhead(pr, jsonb_build_object('mode', 'built', 'logo', pg_temp.lh_file('logo.png', 'png', 600, 240), 'layout', 'center',
    'color', '#9D174D', 'show', '{"phone": false}'::jsonb, 'website', 'www.head.example.test', 'footer', E'Partners: Bisi Partner FCA, Kunle Partner ACA\r\nRegulated by ICAN'))
    ->'practice'->'letterhead';
  assert lh->'logo'->>'kind' = 'png' and lh->>'layout' = 'center' and lh->>'color' = '#9D174D', 'letterhead_built: logo, layout, colour';
  assert lh->'show' = '{"address": true, "phone": false, "email": true, "firm_reg": true, "website": true}'::jsonb, 'letterhead_built: details shown';
  assert lh->>'footer' = E'Partners: Bisi Partner FCA, Kunle Partner ACA\nRegulated by ICAN', 'letterhead_built: footer of two lines';
  perform public.practice_set_letterhead(pr, '{"mode": "plain"}');
  perform tests.as_postgres();
end $$;

-- test: letterhead_refused
-- Only a partner sets it, files only from the practice's own letterhead folder, there in storage, of the kind and size
-- they claim, pages that are A4 or US Letter, and margins that leave room for the letter.
do $$
declare pr uuid := tests.id('pr'); q text := 'select public.practice_set_letterhead(%L, %L::jsonb)';
  m jsonb := '{"mode": "upload"}';
begin
  perform tests.as_user(tests.id('tola'));
  perform tests.throws(format(q, pr, jsonb_build_object('mode', 'upload', 'first', pg_temp.a4())), '42501: Only a partner changes the letterhead.');
  perform tests.as_user(tests.id('ife'));
  perform tests.throws(format(q, pr, '{"mode": "built"}'), '42501: %partners and managers%');
  perform tests.as_user(tests.id('kemi'));
  perform tests.throws(format(q, pr, '{"mode": "built"}'), '42501: %not on this practice%');

  perform tests.as_user(tests.id('bisi'));
  perform tests.throws(format(q, pr, '{"mode": "fancy"}'), '%plain, your own letterhead%');
  perform tests.throws(format(q, pr, '{"mode": "built", "border": true}'), '%settings Counta does not know%');
  perform tests.throws(format(q, pr, '{"mode": "built", "font": "Comic Sans"}'), '%Helvetica or Times%');
  perform tests.throws(format(q, pr, '{"mode": "built", "color": "blue"}'), '%hex code%');
  perform tests.throws(format(q, pr, '{"mode": "built", "font": 3}'), '%must be text%');
  perform tests.throws(format(q, pr, m), '%letterhead page is missing%');
  -- Where the file is.
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.lh_file('first.pdf', 'pdf', 595.28, 841.89, tests.id('pr2')))), '%practice''s letterhead folder%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.a4() || jsonb_build_object('path', 'practice/' || pr || '/letters/first.pdf'))),
    '%practice''s letterhead folder%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.a4() || jsonb_build_object('path', 'practice/' || pr || '/letterhead/../x.pdf'))),
    '%practice''s letterhead folder%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.a4() || jsonb_build_object('path', 'practice/' || pr || '/letterhead/old/first.pdf'))),
    '%practice''s letterhead folder%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.a4('missing.pdf'))), '%not found. Upload it again.');
  -- What it is.
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.a4() || '{"sha256": "abc"}')), '%no SHA-256 fingerprint%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.a4() || '{"kind": "docx"}')), '%a PDF, PNG or JPG%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.a4() || '{"kind": "png"}')), '%file name does not match its kind%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.a4('wrong.pdf'))), '%not the kind of file its name says%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.a4('big.pdf'))), '%at most 5 MB%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.a4() - 'w')), '%size is missing%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.a4() || '{"extra": 1}')), '%settings Counta does not know%');
  -- Its page.
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.lh_file('first.pdf', 'pdf', 841.89, 595.28))), '%upright page%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.lh_file('first.pdf', 'pdf', 300, 400))), '%upright page%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.lh_file('page.png', 'png', 800, 1131))), '%1,000 to 2,600 pixels wide%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.lh_file('page.png', 'png', 2000, 2000))), '%shape of a whole A4 or US Letter%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.lh_file('page.png', 'png', 2000, 3600))), '%shape of a whole A4 or US Letter%');
  -- The following pages.
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.a4(), 'next_mode', 'upload')), '%page for the following pages is missing%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.a4(), 'next_mode', 'upload', 'next', pg_temp.lh_file('next.pdf', 'pdf', 612, 792))),
    '%same size as the first page%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.a4(), 'next_mode', 'some')), '%following pages show%');
  -- The margins.
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.a4(), 'margins', '{"first_top": "lots"}'::jsonb)), '%must be numbers%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.a4(), 'margins', '{"top": 100}'::jsonb)), '%margins are not in the expected form%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.a4(), 'margins', '{"first_top": 10}'::jsonb)), '%space at the top%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.a4(), 'margins', '{"first_bottom": 400}'::jsonb)), '%space at the bottom%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.a4(), 'margins', '{"left": 250}'::jsonb)), '%space at each side%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.a4(), 'margins', '{"first_top": 400, "first_bottom": 200}'::jsonb)),
    '%too little room for the letter%106 mm between the space at the top%');
  perform tests.throws(format(q, pr, m || jsonb_build_object('first', pg_temp.a4(), 'margins', '{"left": 150, "right": 150}'::jsonb)),
    '%too little room for the letter%between the sides%');
  -- Built: the logo, the details, the footer.
  perform tests.throws(format(q, pr, jsonb_build_object('mode', 'built', 'logo', pg_temp.a4())), '%logo must be a PNG or JPG%');
  perform tests.throws(format(q, pr, jsonb_build_object('mode', 'built', 'logo', pg_temp.lh_file('logo.png', 'png', 1600, 400))), '%16 to 1,200 pixels%');
  perform tests.throws(format(q, pr, jsonb_build_object('mode', 'built', 'logo', pg_temp.lh_file('logo-big.png', 'png', 600, 240))), '%logo must be at most 2 MB%');
  perform tests.throws(format(q, pr, '{"mode": "built", "layout": "right"}'), '%left or in the centre%');
  perform tests.throws(format(q, pr, '{"mode": "built", "show": {"fax": true}}'), '%which of the firm''s details%');
  perform tests.throws(format(q, pr, '{"mode": "built", "show": {"phone": "no"}}'), '%which of the firm''s details%');
  perform tests.throws(format(q, pr, '{"mode": "built", "website": "my firm.ng"}'), '%without spaces%');
  perform tests.throws(format(q, pr, jsonb_build_object('mode', 'built', 'footer', E'one\ntwo\nthree')), '%two lines%');
  perform tests.throws(format(q, pr, '{"mode": "built", "footer": "<b>Partners</b>"}'), '%two lines%');
  perform tests.throws(format(q, pr, jsonb_build_object('mode', 'built', 'footer', repeat('x', 301))), '%300 characters%');
  perform tests.as_postgres();
  assert (select letterhead from practices where id = pr) is null, 'letterhead_refused: nothing was saved';
end $$;

-- test: letterhead_files
-- Partners and managers keep the files in the practice's letterhead folder; staff and other practices do not see them.
do $$
declare pr uuid := tests.id('pr'); f text;
begin
  f := 'practice/' || pr || '/letterhead/first.pdf';
  perform tests.as_user(tests.id('bisi'));
  assert private.practice_file_ok(f) and private.practice_file_ok('practice/' || pr || '/letterhead/new.png'), 'letterhead_files: a partner';
  perform tests.as_user(tests.id('tola'));
  assert private.practice_file_ok(f), 'letterhead_files: a manager';
  perform tests.as_user(tests.id('ife'));
  assert not private.practice_file_ok(f), 'letterhead_files: not staff';
  perform tests.as_user(tests.id('kemi'));
  assert not private.practice_file_ok(f), 'letterhead_files: not another practice';
  perform tests.as_postgres();
end $$;

-- test: letterhead_on_letters
-- The letterhead in force when a partner signs is in what the practice function prints (with the firm's registration
-- number), is part of the fingerprint, and is kept on the letter; a letterhead changed between preparing and signing
-- makes the partner sign again; a signed letter's letterhead never changes.
do $$
declare pr uuid := tests.id('pr'); l uuid := tests.id('l'); prep jsonb; fp text; r jsonb; v_lh jsonb;
begin
  perform tests.as_user(tests.id('bisi'));
  prep := public.practice_letter_prepare(l);
  assert prep->'letterhead' = 'null'::jsonb and prep->'firm'->>'firm_reg' = 'BN 445566', 'letterhead_on_letters: plain, with the registration number';
  fp := prep->>'fingerprint';
  v_lh := public.practice_set_letterhead(pr, jsonb_build_object('mode', 'upload', 'first', pg_temp.a4()))->'practice'->'letterhead';
  prep := public.practice_letter_prepare(l);
  assert prep->'letterhead' = v_lh, 'letterhead_on_letters: the letterhead is printed';
  assert prep->>'fingerprint' <> fp, 'letterhead_on_letters: and is part of the fingerprint';
  perform tests.as_service();
  perform tests.throws(format($q$select public.svc_letter_frozen(%L, %L::jsonb)$q$, l, jsonb_build_object('doc_path', 'practice/' || pr || '/letters/' || l || '/letter.pdf',
    'doc_sha256', repeat('ab', 32), 'by_user', tests.id('bisi'), 'fingerprint', fp)), '%changed while it was being signed%');
  r := public.svc_letter_frozen(l, jsonb_build_object('doc_path', 'practice/' || pr || '/letters/' || l || '/letter.pdf',
    'doc_sha256', repeat('ab', 32), 'by_user', tests.id('bisi'), 'fingerprint', prep->>'fingerprint'));
  assert r->>'status' = 'partner_signed' and r->'letterhead' = v_lh, 'letterhead_on_letters: kept on the letter';
  assert (select detail->>'letterhead' from engagement_letter_events where letter_id = l and kind = 'partner_signed') = 'upload',
    'letterhead_on_letters: in its record';
  perform tests.as_user(tests.id('bisi'));
  perform public.practice_set_letterhead(pr, '{"mode": "plain"}');
  perform tests.as_postgres();
  assert (select letterhead from engagement_letters where id = l) = v_lh, 'letterhead_on_letters: a signed letter keeps its letterhead';
  perform tests.throws(format('update engagement_letters set letterhead = null where id = %L', l), '%signed letter cannot be edited%');
end $$;

-- test: letterhead_pdf_letters
-- A letter the firm uploaded as a finished PDF is printed as it stands: no letterhead, and changing the letterhead does not
-- touch its fingerprint.
do $$
declare pr uuid := tests.id('pr'); t uuid; l uuid; fp text; i uuid;
begin
  i := tests.cleared_intake(pr, 'Pdf Letter Ltd');
  perform tests.as_user(tests.id('bisi'));
  t := (public.practice_letter_template_save(pr, jsonb_build_object('name', 'Our PDF', 'kind', 'pdf', 'pdf_path', 'practice/' || pr || '/letters/templates/our.pdf'))->>'id')::uuid;
  l := (public.practice_letter_draft(i, jsonb_build_object('template_id', t))->>'id')::uuid;
  fp := public.practice_letter_prepare(l)->>'fingerprint';
  perform public.practice_set_letterhead(pr, jsonb_build_object('mode', 'upload', 'first', pg_temp.a4()));
  assert public.practice_letter_prepare(l)->'letterhead' = 'null'::jsonb, 'letterhead_pdf_letters: no letterhead';
  assert public.practice_letter_prepare(l)->>'fingerprint' = fp, 'letterhead_pdf_letters: fingerprint unchanged';
  perform public.practice_set_letterhead(pr, '{"mode": "plain"}');
  perform tests.as_postgres();
end $$;

-- test: letter_preview
-- What the practice function needs to show a letter before anyone signs it: a draft of the practice, a template or a sample
-- letter, with the practice's letterhead, or a letterhead a partner is trying.
do $$
declare pr uuid := tests.id('pr'); l uuid; r jsonb; b jsonb := private.letter_default_body(); v_lh jsonb; v_blocks jsonb;
begin
  perform tests.as_user(tests.id('bisi'));
  l := (public.practice_letter_draft(tests.id('i'), '{}')->>'id')::uuid;
  v_lh := public.practice_set_letterhead(pr, '{"mode": "built", "website": "www.head.example.test"}')->'practice'->'letterhead';
  perform tests.as_postgres();
  select blocks into v_blocks from engagement_letters where id = l;
  perform tests.as_user(tests.id('tola'));
  r := public.practice_letter_preview(pr, jsonb_build_object('letter_id', l));
  assert r->'blocks' = v_blocks and r->>'variant' = 'involved' and r->'letterhead' = v_lh,
    'letter_preview: a draft, with the practice''s letterhead';
  assert r->'firm'->>'firm_reg' = 'BN 445566' and r->'partner'->>'name' = 'The signing partner', 'letter_preview: a manager is not the one signing';
  r := public.practice_letter_preview(pr, jsonb_build_object('blocks', b, 'merge', '{"client.name": "Sample Client Ltd"}'::jsonb, 'variant', 'full', 'title', 'Sample'));
  assert r->'blocks' = b and r->>'variant' = 'full' and r->>'title' = 'Sample' and r->'merge'->>'client.name' = 'Sample Client Ltd', 'letter_preview: a template';
  perform tests.throws(format($q$select public.practice_letter_preview(%L, %L::jsonb)$q$, pr, jsonb_build_object('blocks', b, 'letterhead', '{"mode": "built"}'::jsonb)),
    '42501: Only a partner tries a new letterhead.');
  perform tests.throws(format($q$select public.practice_letter_preview(%L, %L::jsonb)$q$, pr, '{"blocks": {"version": 2}}'), '%format version must be 1%');
  perform tests.throws(format($q$select public.practice_letter_preview(%L, %L::jsonb)$q$, pr, jsonb_build_object('blocks', b, 'merge', '{"client.nickname": "x"}'::jsonb)),
    '%client.nickname%');
  perform tests.throws(format($q$select public.practice_letter_preview(%L, %L::jsonb)$q$, pr, jsonb_build_object('blocks', b, 'variant', 'both')), '%full mandate or for an involved%');
  perform tests.throws(format($q$select public.practice_letter_preview(%L, %L::jsonb)$q$, pr, jsonb_build_object('letter_id', tests.id('l'))), '%signed already%');
  perform tests.throws(format($q$select public.practice_letter_preview(%L, '"x"'::jsonb)$q$, pr), '%Say which letter%');

  perform tests.as_user(tests.id('bisi'));
  r := public.practice_letter_preview(pr, jsonb_build_object('blocks', b, 'letterhead', jsonb_build_object('mode', 'upload', 'first', pg_temp.a4())));
  assert r->'letterhead'->>'mode' = 'upload' and r->'partner'->>'name' = 'Bisi Partner', 'letter_preview: a partner tries a letterhead';
  assert public.practice_home(pr)->'practice'->'letterhead' = v_lh, 'letter_preview: without saving it';
  perform tests.throws(format($q$select public.practice_letter_preview(%L, %L::jsonb)$q$, pr, jsonb_build_object('blocks', b, 'letterhead', '{"mode": "upload"}'::jsonb)),
    '%letterhead page is missing%');

  perform tests.as_user(tests.id('ife'));
  perform tests.throws(format($q$select public.practice_letter_preview(%L, %L::jsonb)$q$, pr, jsonb_build_object('letter_id', l)), '42501: %partners and managers%');
  perform tests.as_user(tests.id('kemi'));
  perform tests.throws(format($q$select public.practice_letter_preview(%L, %L::jsonb)$q$, tests.id('pr2'), jsonb_build_object('letter_id', l)), '%Letter not found%');
  perform tests.as_user(tests.id('bisi'));
  perform public.practice_set_letterhead(pr, '{"mode": "plain"}');
  perform tests.as_postgres();
end $$;

-- test: vat_must_reason
-- Why a business that does not charge VAT must, and the words its people get.
do $$
declare w jsonb;
begin
  assert private.vat_must_reason('{"crossed": true, "small": false, "turnover": 200000000}') = 'sales_passed', 'vat_must_reason: sales first';
  assert private.vat_must_reason('{"crossed": false, "small": true}') is null, 'vat_must_reason: a small company need not';
  assert private.vat_must_reason('{"crossed": false, "small": false, "turnover": 120000000, "fixed_assets": 300000000}') = 'turnover', 'vat_must_reason: turnover';
  assert private.vat_must_reason('{"crossed": false, "small": false, "turnover": 90000000, "fixed_assets": 300000000}') = 'fixed_assets', 'vat_must_reason: fixed assets';
  assert private.vat_must_reason('{"crossed": false, "small": false, "turnover": 1000, "fixed_assets": 0, "professional_services": true}') = 'professional_services',
    'vat_must_reason: professional services';
  w := private.vat_on_words('sales_passed', '{"year_from": "2026-01-01", "year_to_date": 101234567.5}', '2026-11-14');
  assert w->>'title' = 'VAT is now on: sales passed ₦100 million', 'vat_must_reason: title';
  assert w->'lines'->>0 = 'Sales this financial year (from 1 Jan 2026) come to ₦101,234,567.50, above the ₦100 million a small company may make without charging VAT.',
    'vat_must_reason: why';
  assert w->'lines'->>1 like '%charge VAT at 7.5% where it applies%by the 21st.' and w->'lines'->>2 like '%must be saved again before it is issued.',
    'vat_must_reason: what changes';
  w := private.vat_on_words('turnover', '{"from": "2025-01-01", "to": "2025-12-31", "turnover": 150000000}', '2026-11-14');
  assert w->'lines'->>0 = 'Turnover for 1 Jan 2025 to 31 Dec 2025 was ₦150,000,000.00, above the ₦100 million small company limit.', 'vat_must_reason: turnover words';
  assert private.vat_on_words('fixed_assets', '{"fixed_assets": 260000000}', '2026-11-14')->'lines'->>0 like '%₦260,000,000.00, above the ₦250 million%',
    'vat_must_reason: fixed assets words';
  assert private.vat_on_words('professional_services', '{}', '2026-11-14')->>'title' = 'VAT is now on for professional services', 'vat_must_reason: professional words';
end $$;

-- test: vat_turned_on
-- Sales this year pass ₦100 million: the next morning's run turns VAT on, keeps why with the figures, tells the owner, the
-- admin and the firm's people in their accountant's places (not staff), and emails the owner. Running again changes nothing.
do $$
declare o uuid := tests.id('o'); c public.vat_changes;
begin
  perform tests.as_user(tests.id('ada'));
  perform public.save_sale_doc(o, jsonb_build_object('customer_id', tests.id('cu'), 'status', 'issue',
    'lines', '[{"description": "Big contract", "qty": 1, "unit_price": 150000000, "vat_treatment": "exempt"}]'::jsonb));
  assert public.vat_status(o)->>'advice' = 'must_start' and (public.vat_status(o)->>'auto_on')::boolean
     and public.vat_status(o)->>'must_reason' = 'sales_passed', 'vat_turned_on: the VAT tab says Counta turns it on';
  perform tests.as_postgres();
  perform private.vat_threshold_tick();
  assert (select vat_registered and not vat_opt_in from orgs where id = o), 'vat_turned_on: on';
  select * into c from vat_changes where org_id = o;
  assert c.charge and c.by_member is null and c.by_name = 'Counta' and c.reason = 'sales_passed' and (c.status->>'year_to_date')::numeric = 150000000,
    'vat_turned_on: why, with the figures';
  assert (select array_agg(u.email order by u.email) from notifications n join auth.users u on u.id = n.user_id where n.org_id = o and n.kind = 'vat_on')
    = array['ada.owner@ada.example.test', 'bimpe.admin@ada.example.test', 'bisi.partner@head.example.test', 'kunle.partner@head.example.test',
            'tola.manager@head.example.test'], 'vat_turned_on: who is told (the accountant''s places, not Kola on the staff)';
  assert (select count(*) from messages where org_id = o and template = 'alert' and channel = 'email' and to_address = 'ada.owner@ada.example.test'
            and params->>'heading' = 'VAT is now on: sales passed ₦100 million' and params->>'link' like '%/tax/vat') = 1,
    'vat_turned_on: the owner is emailed';
  perform tests.as_user(tests.id('ada'));
  assert public.vat_status(o)->'last_change'->>'reason' = 'sales_passed' and (public.vat_status(o)->'last_change'->>'auto')::boolean
     and public.vat_status(o)->>'advice' = 'ok' and not (public.vat_status(o)->>'auto_on')::boolean, 'vat_turned_on: the VAT tab says why';
  perform tests.as_postgres();
  perform private.vat_threshold_tick();
  assert (select count(*) from vat_changes where org_id = o) = 1 and (select count(*) from notifications where org_id = o and kind = 'vat_on') = 5,
    'vat_turned_on: once';
  -- Above ₦100 million this year, the owner cannot turn it off.
  perform tests.as_user(tests.id('ada'));
  perform tests.throws(format($q$select public.set_vat_charging(%L, '{"charge": false}')$q$, o), '%Only a small company%may stop charging VAT%');
  perform tests.as_postgres();
end $$;

-- test: vat_other_reasons
-- A professional services firm is turned on whatever its sales; a small company, a business that charges VAT already, the
-- sample business and a read-only business are left alone; one business that fails does not stop the others.
do $$
declare v_u uuid; ps uuid; sm uuid; ro uuid; sa uuid; bad uuid;
begin
  v_u := tests.user('owner.five@five.example.test', 'Five Owner');
  ps := tests.org(v_u, 'Pro Services Ltd');
  sm := tests.org(v_u, 'Small Shop Ltd');
  ro := tests.org(v_u, 'Ended Ltd');
  sa := tests.org(v_u, 'Sample Ltd');
  bad := tests.org(v_u, 'Broken Ltd');
  update orgs set vat_registered = false, professional_services = (id in (ps, ro, sa, bad)), read_only_at = case when id = ro then now() end,
    is_sample = (id = sa) where id in (ps, sm, ro, sa, bad);
  create function tests.vat_fail() returns trigger language plpgsql as $f$
  begin
    if new.org_id = (select id from orgs where name = 'Broken Ltd') then raise exception 'storage is down'; end if;
    return new;
  end $f$;
  create trigger vat_fail before insert on vat_changes for each row execute function tests.vat_fail();
  perform private.vat_threshold_tick();
  assert (select vat_registered from orgs where id = ps) and (select reason from vat_changes where org_id = ps) = 'professional_services',
    'vat_other_reasons: professional services';
  assert not (select vat_registered from orgs where id = sm), 'vat_other_reasons: a small company is left alone';
  assert not (select vat_registered from orgs where id = ro), 'vat_other_reasons: a read-only business is left alone';
  assert not (select vat_registered from orgs where id = sa), 'vat_other_reasons: the sample business is left alone';
  assert not (select vat_registered from orgs where id = bad) and not exists (select 1 from vat_changes where org_id = bad),
    'vat_other_reasons: a failure undoes that business only';
  drop trigger vat_fail on vat_changes;
  drop function tests.vat_fail();
end $$;

-- test: vat_owner_changes
-- The owner's own changes are kept with who made them; saving the same state again adds nothing.
do $$
declare v_u uuid; o uuid; r jsonb;
begin
  v_u := tests.user('owner.six@six.example.test', 'Six Owner');
  o := tests.org(v_u, 'Six Ltd');
  update orgs set vat_registered = false where id = o;
  perform tests.as_user(v_u);
  r := public.set_vat_charging(o, '{"charge": true}');
  assert r->'last_change'->>'by' = 'Six Owner' and not (r->'last_change'->>'auto')::boolean and r->'last_change'->>'reason' = 'owner'
     and (r->'last_change'->>'charge')::boolean, 'vat_owner_changes: on';
  perform public.set_vat_charging(o, '{"charge": true}');
  r := public.set_vat_charging(o, '{"charge": false}');
  perform tests.as_postgres();
  assert not (r->'last_change'->>'charge')::boolean and (select count(*) from vat_changes where org_id = o) = 2, 'vat_owner_changes: off, and no repeat';
end $$;

-- test: vat_stale_draft
-- A draft saved before VAT was turned on is not issued until it is saved again; then it carries VAT.
do $$
declare v_u uuid; o uuid; cu uuid; d jsonb; r jsonb;
begin
  v_u := tests.user('owner.seven@seven.example.test', 'Seven Owner');
  o := tests.org(v_u, 'Seven Ltd');
  update orgs set vat_registered = false where id = o;
  perform tests.as_user(v_u);
  cu := public.save_customer(o, '{"name": "Tade Stores", "email": "tade@example.test"}');
  d := public.save_sale_doc(o, jsonb_build_object('customer_id', cu, 'status', 'draft',
    'lines', '[{"description": "Supplies", "qty": 1, "unit_price": 100000, "vat_treatment": "standard"}]'::jsonb));
  assert (d->>'vat_total')::numeric = 0 and not (d->>'vat_registered')::boolean, 'vat_stale_draft: no VAT while it is off';
  perform public.set_vat_charging(o, '{"charge": true}');
  perform tests.throws(format('select public.issue_invoice(%L)', d->>'id'),
    format('P0001: VAT was turned on for the business after %s was saved. Open it and save it again so its VAT is right, then issue it.', d->>'number'));
  d := public.save_sale_doc(o, jsonb_build_object('id', d->>'id', 'customer_id', cu, 'status', 'draft',
    'lines', '[{"description": "Supplies", "qty": 1, "unit_price": 100000, "vat_treatment": "standard"}]'::jsonb));
  r := public.issue_invoice((d->>'id')::uuid);
  assert r->>'status' = 'open' and (r->>'vat_total')::numeric = 6976.74, 'vat_stale_draft: saved again, it is issued with VAT (inside the price)';
  perform tests.as_postgres();
end $$;

-- test: vat_changes_table
-- Nobody reads the table directly; every change is in the business's activity log and its export.
do $$
begin
  assert (select relrowsecurity from pg_class where oid = 'public.vat_changes'::regclass), 'vat_changes_table: row security on';
  assert not exists (select 1 from information_schema.role_table_grants where table_name = 'vat_changes' and grantee in ('anon', 'authenticated')),
    'vat_changes_table: no table access';
  assert exists (select 1 from pg_trigger where tgrelid = 'public.vat_changes'::regclass and tgname = 'activity_row'), 'vat_changes_table: activity log';
  assert 'vat_changes' = any (private.export_tables()), 'vat_changes_table: in the export';
end $$;

rollback;
