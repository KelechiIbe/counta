-- Release 3 of the identity and compliance work: a firm's own letterhead on its engagement letters, and VAT turned on by
-- Counta itself when a business must charge it.
--
-- 1. Letterhead (practices.letterhead, set by a partner with practice_set_letterhead). Plain (null) is the letter as it
--    was: the firm's name at the head of the first page. A firm can instead upload its own blank letterhead page (a PDF,
--    PNG or JPG, as exported from Word), laid under every page of the letter, with a second page for the following pages
--    if it has one, and the space to keep clear at the top, bottom and sides. Or it builds one here: its logo, colour,
--    typeface, the details shown under its name, and a footer line. The files live in practice/<practice>/letterhead/ in
--    the documents bucket; private.letterhead_norm checks every setting and that each file is there.
--    The letterhead in force when a partner signs is printed on the letter and kept on it (engagement_letters.letterhead);
--    it is part of the letter's fingerprint, so a letterhead changed between preparing and signing makes the partner sign
--    again. Letters already signed never change, and a letter the firm uploaded as a finished PDF is left as it stands.
--    practice_letter_preview gives the practice function what it needs to show a draft, a template or a sample letter as
--    a PDF before anyone signs (with a letterhead not yet saved, for a partner trying one).
-- 2. VAT turned on by itself. Every morning private.vat_threshold_tick looks at each business that does not charge VAT. A
--    business that must charge it (sales this financial year above ₦100 million, or not a small company: last full year's
--    turnover above ₦100 million, fixed assets above ₦250 million, or professional services) has VAT turned on, and the
--    owner, everyone who keeps its books and its accountant are told why. Each change, by Counta or by the owner, is kept
--    in vat_changes with the figures behind it, and the VAT tab shows the last one.
--    A draft invoice saved before VAT was turned on or off is not issued until it is saved again, so that its VAT is right.
-- Run once, in the SQL Editor of the counta project, as one script.

-- ---------------------------------------------------------------------------
-- 1. Letterhead
-- ---------------------------------------------------------------------------
alter table public.practices add column if not exists letterhead jsonb check (letterhead is null or jsonb_typeof(letterhead) = 'object');
alter table public.practices add column if not exists letterhead_set_at timestamptz;
alter table public.practices add column if not exists letterhead_set_by uuid references public.practice_members(id) on delete set null;
create index if not exists practices_letterhead_set_by on public.practices(letterhead_set_by) where letterhead_set_by is not null;
alter table public.engagement_letters add column if not exists letterhead jsonb check (letterhead is null or jsonb_typeof(letterhead) = 'object');

-- The page a letterhead file makes, in points: a PDF's own page, or for a picture A4 or US Letter by its shape.
create or replace function private.letterhead_page(f jsonb) returns jsonb
language sql immutable set search_path = public, private as $$
  select case when f->>'kind' = 'pdf' then jsonb_build_array((f->>'w')::numeric, (f->>'h')::numeric)
    when abs((f->>'h')::numeric / (f->>'w')::numeric - 1.2941) < abs((f->>'h')::numeric / (f->>'w')::numeric - 1.4142) then '[612, 792]'::jsonb
    else '[595.28, 841.89]'::jsonb end
$$;

-- One letterhead file as the browser describes it after uploading it: its path in the practice's letterhead folder, its
-- SHA-256, its kind (pdf, png or jpg) and its size (a PDF page in points, a picture in pixels). Checked against the
-- stored object: it must be there, at most 5 MB (a logo 2 MB), of the kind its name says. p_role: first, next or logo.
create or replace function private.letterhead_file(p_practice uuid, f jsonb, p_role text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_path text; v_sha text; v_kind text; v_w numeric; v_h numeric; v_meta jsonb; v_found boolean; v_max bigint; v_r numeric;
  v_what text := case p_role when 'logo' then 'The logo' when 'next' then 'The page for the following pages' else 'The letterhead page' end;
begin
  if jsonb_typeof(f) is distinct from 'object' then raise exception '% is missing. Upload it again.', v_what; end if;
  if f - array['path', 'sha256', 'kind', 'w', 'h'] <> '{}'::jsonb then raise exception '% has settings Counta does not know.', v_what; end if;
  v_path := case when jsonb_typeof(f->'path') = 'string' then f->>'path' end;
  v_sha := lower(coalesce(case when jsonb_typeof(f->'sha256') = 'string' then f->>'sha256' end, ''));
  v_kind := case when jsonb_typeof(f->'kind') = 'string' then f->>'kind' end;
  if v_path is null or length(v_path) > 300 or v_path ~ '\.\.'
     or v_path !~ ('^practice/' || p_practice::text || '/letterhead/[A-Za-z0-9_-][A-Za-z0-9._-]*$') then
    raise exception '% must be stored in the practice''s letterhead folder.', v_what;
  end if;
  if v_sha !~ '^[0-9a-f]{64}$' then raise exception '% has no SHA-256 fingerprint. Upload it again.', v_what; end if;
  if v_kind is null or v_kind not in ('pdf', 'png', 'jpg') or (p_role = 'logo' and v_kind = 'pdf') then
    raise exception '% must be %.', v_what, case when p_role = 'logo' then 'a PNG or JPG picture' else 'a PDF, PNG or JPG' end;
  end if;
  if lower(v_path) !~ (case v_kind when 'pdf' then '\.pdf$' when 'png' then '\.png$' else '\.jpe?g$' end) then
    raise exception '%''s file name does not match its kind.', v_what;
  end if;
  if jsonb_typeof(f->'w') is distinct from 'number' or jsonb_typeof(f->'h') is distinct from 'number' then
    raise exception '%''s size is missing. Upload it again.', v_what;
  end if;
  v_w := round((f->>'w')::numeric, 2);
  v_h := round((f->>'h')::numeric, 2);
  if p_role = 'logo' then
    if v_w not between 16 and 1200 or v_h not between 16 and 1200 then raise exception 'The logo must be 16 to 1,200 pixels on each side.'; end if;
  elsif v_kind = 'pdf' then
    if v_w not between 400 and 700 or v_h not between 500 and 1000 or v_h <= v_w then
      raise exception '% must be an upright page the size of A4 or US Letter.', v_what;
    end if;
  else
    if v_w not between 1000 and 2600 or v_h not between 1300 and 3700 then
      raise exception '% must be a whole page 1,000 to 2,600 pixels wide. Save it from Word as a PDF instead, or as a picture at 150 to 300 dpi.', v_what;
    end if;
    v_r := v_h / v_w;
    if abs(v_r - 1.4142) > 0.045 and abs(v_r - 1.2941) > 0.04 then
      raise exception '% must have the shape of a whole A4 or US Letter page.', v_what;
    end if;
  end if;
  select true, o.metadata into v_found, v_meta from storage.objects o where o.bucket_id = 'documents' and o.name = v_path;
  if v_found is null then raise exception '% was not found. Upload it again.', v_what; end if;
  v_max := (case when p_role = 'logo' then 2 else 5 end) * 1048576;
  if coalesce(v_meta->>'size', '') ~ '^\d+$' and (v_meta->>'size')::bigint > v_max then
    raise exception '% must be at most % MB.', v_what, v_max / 1048576;
  end if;
  if nullif(v_meta->>'mimetype', '') is not null
     and v_meta->>'mimetype' <> (case v_kind when 'pdf' then 'application/pdf' when 'png' then 'image/png' else 'image/jpeg' end) then
    raise exception '% is not the kind of file its name says.', v_what;
  end if;
  return jsonb_build_object('path', v_path, 'sha256', v_sha, 'kind', v_kind, 'w', v_w, 'h', v_h);
end $$;

-- A letterhead as Counta keeps it, from what a partner sent; null for plain. Anything Counta cannot use is refused with
-- the reason.
--   upload: {mode, font, color, first, next_mode same|upload|none, next, margins {first_top, first_bottom, next_top,
--            next_bottom, left, right} in points, page [w, h]}
--   built:  {mode, font, color, logo, layout left|center, show {address, phone, email, firm_reg, website}, website, footer,
--            page [w, h]}
create or replace function private.letterhead_norm(p_practice uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_mode text; v_font text; v_color text; v_first jsonb; v_next jsonb; v_next_mode text; m jsonb; v_page jsonb; v_np jsonb; k text;
  v_top numeric; v_bottom numeric; v_ntop numeric; v_nbottom numeric; v_left numeric; v_right numeric;
  v_logo jsonb; v_layout text; v_show jsonb; v_site text; v_foot text; v_w numeric; v_h numeric;
begin
  if p is null or jsonb_typeof(p) = 'null' then return null; end if;
  if jsonb_typeof(p) <> 'object' then raise exception 'The letterhead is not in the expected form.'; end if;
  if p - array['mode', 'font', 'color', 'first', 'next', 'next_mode', 'margins', 'logo', 'layout', 'show', 'website', 'footer'] <> '{}'::jsonb then
    raise exception 'The letterhead has settings Counta does not know.';
  end if;
  foreach k in array array['mode', 'font', 'color', 'next_mode', 'layout', 'website', 'footer'] loop
    if p ? k and jsonb_typeof(p->k) not in ('string', 'null') then raise exception 'The letterhead''s % must be text.', replace(k, '_', ' '); end if;
  end loop;
  v_mode := coalesce(nullif(p->>'mode', ''), 'plain');
  if v_mode not in ('plain', 'upload', 'built') then raise exception 'Choose plain, your own letterhead, or one built in Counta.'; end if;
  if v_mode = 'plain' then return null; end if;
  v_font := coalesce(nullif(p->>'font', ''), 'helvetica');
  if v_font not in ('helvetica', 'times') then raise exception 'Choose Helvetica or Times for the letter.'; end if;
  v_color := upper(coalesce(nullif(btrim(p->>'color'), ''), case v_mode when 'built' then '#0B3B75' else '#111827' end));
  if v_color !~ '^#[0-9A-F]{6}$' then raise exception 'The colour must be a hex code such as #0B3B75.'; end if;

  if v_mode = 'upload' then
    v_first := private.letterhead_file(p_practice, p->'first', 'first');
    v_page := private.letterhead_page(v_first);
    v_w := (v_page->>0)::numeric;
    v_h := (v_page->>1)::numeric;
    v_next_mode := coalesce(nullif(p->>'next_mode', ''), 'same');
    if v_next_mode not in ('same', 'upload', 'none') then raise exception 'Choose what the following pages show: the same letterhead, another page, or none.'; end if;
    if v_next_mode = 'upload' then
      v_next := private.letterhead_file(p_practice, p->'next', 'next');
      v_np := private.letterhead_page(v_next);
      if abs((v_np->>0)::numeric - v_w) > 3 or abs((v_np->>1)::numeric - v_h) > 3 then
        raise exception 'The page for the following pages must be the same size as the first page.';
      end if;
    end if;
    m := coalesce(p->'margins', '{}'::jsonb);
    if jsonb_typeof(m) <> 'object' or m - array['first_top', 'first_bottom', 'next_top', 'next_bottom', 'left', 'right'] <> '{}'::jsonb then
      raise exception 'The letterhead''s margins are not in the expected form.';
    end if;
    foreach k in array array['first_top', 'first_bottom', 'next_top', 'next_bottom', 'left', 'right'] loop
      if m ? k and jsonb_typeof(m->k) <> 'number' then raise exception 'The letterhead''s margins must be numbers.'; end if;
    end loop;
    v_top := round(coalesce((m->>'first_top')::numeric, 150), 1);
    v_bottom := round(coalesce((m->>'first_bottom')::numeric, 90), 1);
    v_left := round(coalesce((m->>'left')::numeric, 56), 1);
    v_right := round(coalesce((m->>'right')::numeric, 56), 1);
    if v_next_mode = 'same' then
      v_ntop := v_top; v_nbottom := v_bottom;
    else
      v_ntop := round(coalesce((m->>'next_top')::numeric, case when v_next_mode = 'none' then 56 else v_top end), 1);
      v_nbottom := round(coalesce((m->>'next_bottom')::numeric, case when v_next_mode = 'none' then 56 else v_bottom end), 1);
    end if;
    if v_top not between 36 and 420 or v_ntop not between 36 and 420 then raise exception 'The space at the top must be 13 to 148 mm.'; end if;
    if v_bottom not between 30 and 300 or v_nbottom not between 30 and 300 then raise exception 'The space at the bottom must be 11 to 105 mm.'; end if;
    if v_left not between 36 and 200 or v_right not between 36 and 200 then raise exception 'The space at each side must be 13 to 70 mm.'; end if;
    if v_h - v_top - v_bottom < 300 or v_h - v_ntop - v_nbottom < 300 then
      raise exception 'That leaves too little room for the letter: keep at least 106 mm between the space at the top and at the bottom.';
    end if;
    if v_w - v_left - v_right < 300 then raise exception 'That leaves too little room for the letter: keep at least 106 mm between the sides.'; end if;
    return jsonb_build_object('mode', 'upload', 'font', v_font, 'color', v_color, 'first', v_first, 'next_mode', v_next_mode, 'next', v_next,
      'page', v_page, 'margins', jsonb_build_object('first_top', v_top, 'first_bottom', v_bottom, 'next_top', v_ntop, 'next_bottom', v_nbottom,
        'left', v_left, 'right', v_right));
  end if;

  -- Built in Counta.
  v_logo := case when p->'logo' is null or jsonb_typeof(p->'logo') = 'null' then null else private.letterhead_file(p_practice, p->'logo', 'logo') end;
  v_layout := coalesce(nullif(p->>'layout', ''), 'left');
  if v_layout not in ('left', 'center') then raise exception 'Choose the logo on the left or in the centre.'; end if;
  v_show := coalesce(p->'show', '{}'::jsonb);
  if jsonb_typeof(v_show) <> 'object' or v_show - array['address', 'phone', 'email', 'firm_reg', 'website'] <> '{}'::jsonb then
    raise exception 'Choose which of the firm''s details the letterhead shows.';
  end if;
  foreach k in array array['address', 'phone', 'email', 'firm_reg', 'website'] loop
    if v_show ? k and jsonb_typeof(v_show->k) <> 'boolean' then raise exception 'Choose which of the firm''s details the letterhead shows.'; end if;
  end loop;
  v_site := nullif(btrim(coalesce(p->>'website', '')), '');
  if v_site is not null and (length(v_site) > 100 or v_site !~ '^[A-Za-z0-9][A-Za-z0-9.:/_~%?#=&+-]*$') then
    raise exception 'Type the website without spaces, for example www.yourfirm.ng.';
  end if;
  v_foot := nullif(btrim(regexp_replace(regexp_replace(coalesce(p->>'footer', ''), '\r', '', 'g'), '[\t ]+', ' ', 'g')), '');
  if v_foot is not null and (length(v_foot) > 300 or array_length(string_to_array(v_foot, E'\n'), 1) > 2 or v_foot ~ '[<>{}]') then
    raise exception 'Keep the footer to two lines and 300 characters, without < > { or }.';
  end if;
  return jsonb_build_object('mode', 'built', 'font', v_font, 'color', v_color, 'logo', v_logo, 'layout', v_layout,
    'show', jsonb_build_object('address', coalesce((v_show->>'address')::boolean, true), 'phone', coalesce((v_show->>'phone')::boolean, true),
      'email', coalesce((v_show->>'email')::boolean, true), 'firm_reg', coalesce((v_show->>'firm_reg')::boolean, true),
      'website', coalesce((v_show->>'website')::boolean, v_site is not null)),
    'website', v_site, 'footer', v_foot, 'page', '[595.28, 841.89]'::jsonb);
end $$;

-- A partner sets the practice's letterhead ({mode: 'plain'} or null takes it off). Letters signed from now on carry it.
create or replace function public.practice_set_letterhead(p_practice uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.practice_members; v jsonb;
begin
  m := private.practice_require(p_practice, true);
  if m.role <> 'partner' then raise exception 'Only a partner changes the letterhead.' using errcode = '42501'; end if;
  v := private.letterhead_norm(p_practice, p);
  update practices set letterhead = v, letterhead_set_at = now(), letterhead_set_by = m.id, updated_at = now() where id = p_practice;
  return public.practice_home(p_practice);
end $$;

-- What the practice function needs to show a letter as a PDF before anyone signs it (partners and managers):
--   {letter_id}                        a draft letter of the practice, as it stands
--   {blocks, merge, variant, title}    a template in the editor, or a sample letter
--   letterhead (partners only)         a letterhead not yet saved, to try it; otherwise the practice's own
create or replace function public.practice_letter_preview(p_practice uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.practice_members; pr public.practices; l public.engagement_letters; v_err text; v_lh jsonb; v_blocks jsonb; v_merge jsonb;
  v_variant text; v_title text;
begin
  m := private.practice_require(p_practice, true);
  if jsonb_typeof(p) is distinct from 'object' then raise exception 'Say which letter to show.'; end if;
  select * into pr from practices where id = p_practice;
  if p ? 'letterhead' then
    if m.role <> 'partner' then raise exception 'Only a partner tries a new letterhead.' using errcode = '42501'; end if;
    v_lh := private.letterhead_norm(p_practice, p->'letterhead');
  else
    v_lh := pr.letterhead;
  end if;
  if nullif(p->>'letter_id', '') is not null then
    select * into l from engagement_letters where id = private.uuid_of(p->>'letter_id');
    if l.id is null or l.practice_id <> p_practice then raise exception 'Letter not found.'; end if;
    if l.source <> 'template' then raise exception 'This letter is a PDF the firm uploaded: open its file to see it.'; end if;
    if l.status <> 'draft' then raise exception 'This letter is signed already: open its PDF to see it.'; end if;
    v_blocks := l.blocks; v_merge := l.merge; v_variant := l.variant; v_title := l.title;
  else
    v_blocks := p->'blocks';
    v_merge := coalesce(p->'merge', '{}'::jsonb);
    v_variant := coalesce(nullif(p->>'variant', ''), 'involved');
    v_title := coalesce(nullif(btrim(p->>'title'), ''), 'Letter of engagement');
    if v_variant not in ('full', 'involved') then raise exception 'Choose the letter for a full mandate or for an involved client.'; end if;
    if length(v_title) > 160 then raise exception 'Keep the title under 160 characters.'; end if;
    v_err := private.letter_merge_ok(v_merge);
    if v_err is not null then raise exception '%', v_err; end if;
  end if;
  v_err := private.letter_body_ok(v_blocks);
  if v_err is not null then raise exception '%', v_err; end if;
  return jsonb_build_object('practice_id', p_practice, 'blocks', v_blocks, 'merge', v_merge, 'variant', v_variant, 'title', v_title,
    'firm', jsonb_build_object('name', pr.name, 'email', pr.email, 'phone', pr.phone, 'address', pr.address, 'state', pr.state, 'firm_reg', pr.firm_reg),
    'partner', jsonb_build_object('name', case when m.role = 'partner' then m.display_name else 'The signing partner' end, 'title', 'Partner'),
    'letterhead', v_lh);
end $$;

-- The letter as a partner signs it now also carries the letterhead and the firm's registration number.
CREATE OR REPLACE FUNCTION public.practice_letter_prepare(p_letter uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare l public.engagement_letters; m public.practice_members; pr public.practices; v_err text;
begin
  l := private.letter_require(p_letter);
  m := private.practice_me(l.practice_id);
  if m.role <> 'partner' then raise exception 'Only a partner signs letters for the firm.' using errcode = '42501'; end if;
  if l.status <> 'draft' then raise exception 'Only a draft letter is signed by the firm.'; end if;
  perform private.letter_intake_ready(l.intake_id);
  if l.source = 'template' then
    v_err := private.letter_body_ok(l.blocks);
    if v_err is not null then raise exception '%', v_err; end if;
  end if;
  select * into pr from practices where id = l.practice_id;
  return jsonb_build_object('letter_id', l.id, 'practice_id', l.practice_id, 'source', l.source, 'doc_path', l.doc_path, 'title', l.title,
    'variant', l.variant, 'blocks', l.blocks, 'merge', l.merge, 'fingerprint', private.letter_fingerprint(l.id),
    'firm', jsonb_build_object('name', pr.name, 'email', pr.email, 'phone', pr.phone, 'address', pr.address, 'state', pr.state, 'firm_reg', pr.firm_reg),
    'partner', jsonb_build_object('id', m.id, 'name', m.display_name, 'email', m.email, 'title', 'Partner'),
    'letterhead', case when l.source = 'template' then pr.letterhead end);
end $function$;

-- The fingerprint taken when a letter is prepared also covers the letterhead and the firm's registration number, which a
-- built letterhead prints.
CREATE OR REPLACE FUNCTION private.letter_fingerprint(p_letter uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'private'
AS $function$
  select encode(sha256(convert_to(jsonb_build_object('blocks', l.blocks, 'merge', l.merge, 'variant', l.variant, 'title', l.title,
      'source', l.source, 'doc_path', l.doc_path, 'updated_at', extract(epoch from l.updated_at)::text,
      'firm', jsonb_build_object('name', pr.name, 'email', pr.email, 'phone', pr.phone, 'address', pr.address, 'state', pr.state, 'firm_reg', pr.firm_reg),
      'letterhead', case when l.source = 'template' then pr.letterhead end)::text, 'UTF8')), 'hex')
  from engagement_letters l join practices pr on pr.id = l.practice_id
  where l.id = p_letter
$function$;

-- Signing for the firm keeps the letterhead the letter was printed with (the fingerprint has checked it is the one prepared).
CREATE OR REPLACE FUNCTION public.svc_letter_frozen(p_letter uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare l public.engagement_letters; pm public.practice_members; v_path text := nullif(trim(coalesce(p->>'doc_path', '')), '');
  v_sha text := lower(trim(coalesce(p->>'doc_sha256', ''))); v_sig text; v_err text;
begin
  select * into l from engagement_letters where id = p_letter for update;
  if l.id is null then raise exception 'Letter not found.'; end if;
  if l.status <> 'draft' then raise exception 'Only a draft letter is signed by the firm.'; end if;
  select * into pm from practice_members
  where practice_id = l.practice_id and user_id = private.uuid_of(p->>'by_user') and role = 'partner' and status = 'active';
  if pm.id is null then raise exception 'Only a partner of the practice signs its letters.' using errcode = '42501'; end if;
  perform private.letter_intake_ready(l.intake_id);
  if l.source = 'pdf' then
    if v_path is distinct from l.doc_path then raise exception 'A PDF letter is signed as it stands: its file cannot change.'; end if;
  elsif not private.letter_file_ok(v_path, l.practice_id, l.id::text) then
    raise exception 'The signed letter must be stored in the letter''s folder.';
  end if;
  if v_sha !~ '^[0-9a-f]{64}$' then raise exception 'The letter''s SHA-256 fingerprint is missing.'; end if;
  if l.source = 'template' then
    v_err := private.letter_body_ok(l.blocks);
    if v_err is not null then raise exception '%', v_err; end if;
  end if;
  v_sig := coalesce(nullif(trim(p->>'signature_name'), ''), pm.display_name);
  if length(v_sig) not between 2 and 120 then raise exception 'Type the partner''s name to sign (2 to 120 characters).'; end if;
  if coalesce(p->>'fingerprint', '') is distinct from private.letter_fingerprint(l.id) then
    raise exception 'The letter changed while it was being signed. Sign it again.';
  end if;
  perform private.set_actor(pm.user_id);
  update engagement_letters set status = 'partner_signed', doc_path = v_path, doc_sha256 = v_sha, partner_id = pm.id, partner_signature = v_sig,
    partner_name = pm.display_name, partner_email = lower(trim(pm.email)), partner_signed_at = now(), partner_ip = left(nullif(trim(p->>'ip'), ''), 64),
    partner_ua = left(nullif(p->>'ua', ''), 300), updated_at = now(),
    letterhead = case when l.source = 'template' then (select letterhead from practices where id = l.practice_id) end
  where id = l.id
  returning * into l;
  perform private.letter_event(l.id, 'partner_signed', pm.display_name, l.partner_ip, l.partner_ua,
    jsonb_build_object('signature', v_sig, 'letterhead', coalesce(l.letterhead->>'mode', 'plain')));
  return private.letter_json(l);
end $function$;

-- A signed letter keeps its letterhead too.
CREATE OR REPLACE FUNCTION private.engagement_letters_freeze()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'private'
AS $function$
begin
  if new.practice_id is distinct from old.practice_id then raise exception 'A letter stays with its practice.'; end if;
  if old.status in ('completed', 'uploaded', 'void')
     and (new.status, new.final_path, new.final_sha256, new.void_reason) is distinct from (old.status, old.final_path, old.final_sha256, old.void_reason) then
    raise exception 'This letter is closed: it cannot change.';
  end if;
  if old.status <> 'draft' and (
       new.status = 'draft'
     or (new.blocks, new.merge, new.variant, new.source, new.doc_path, new.doc_sha256, new.intake_id, new.title, new.retention_years, new.white_label,
         new.partner_signature, new.partner_name, new.partner_email, new.partner_signed_at, new.partner_ip, new.partner_ua, new.letterhead)
        is distinct from
        (old.blocks, old.merge, old.variant, old.source, old.doc_path, old.doc_sha256, old.intake_id, old.title, old.retention_years, old.white_label,
         old.partner_signature, old.partner_name, old.partner_email, old.partner_signed_at, old.partner_ip, old.partner_ua, old.letterhead)
     or (new.template_id is distinct from old.template_id
         and not (new.template_id is null and not exists (select 1 from practice_letter_templates where id = old.template_id)))
     or (new.partner_id is distinct from old.partner_id
         and not (new.partner_id is null and not exists (select 1 from practice_members where id = old.partner_id)))) then
    raise exception 'A signed letter cannot be edited. Void it and start again.';
  end if;
  if new.status is distinct from old.status and not (
       (old.status = 'draft' and new.status in ('partner_signed', 'uploaded', 'void'))
    or (old.status = 'partner_signed' and new.status in ('sent', 'uploaded', 'void'))
    or (old.status = 'sent' and new.status in ('completed', 'uploaded', 'void'))) then
    raise exception 'A letter cannot go from % to %.', old.status, new.status;
  end if;
  return new;
end $function$;

-- Partners and managers keep the practice's letterhead files (practice/<practice>/letterhead/...), as they do its letters.
CREATE OR REPLACE FUNCTION private.practice_file_ok(p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select coalesce(p_name ~ '^practice/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/(intake|letters|exports|letterhead)/[^/]', false)
    and exists (select 1 from practice_members pm
                where pm.practice_id::text = split_part(p_name, '/', 2) and pm.user_id = auth.uid() and pm.status = 'active'
                  and case split_part(p_name, '/', 3) when 'exports' then pm.role = 'partner' else pm.role in ('partner', 'manager') end)
$function$;

-- ---------------------------------------------------------------------------
-- 2. VAT turned on by itself
-- ---------------------------------------------------------------------------
create table if not exists public.vat_changes (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  charge boolean not null,
  by_member uuid references public.members(id) on delete set null,   -- null: Counta turned it on
  by_name text,
  reason text not null check (reason in ('sales_passed', 'turnover', 'fixed_assets', 'professional_services', 'owner')),
  status jsonb not null default '{}'::jsonb,                          -- private.vat_small_status at the time
  created_at timestamptz not null default clock_timestamp()
);
create index if not exists vat_changes_org on public.vat_changes(org_id, created_at desc);
create index if not exists vat_changes_by_member on public.vat_changes(by_member) where by_member is not null;
alter table public.vat_changes enable row level security;
revoke all on public.vat_changes from anon, authenticated;
select private.activity_attach('public.vat_changes');

-- Why a business that does not charge VAT must: sales this financial year above ₦100 million, or not a small company
-- (turnover in the last full year above ₦100 million, fixed assets above ₦250 million, or professional services). Null
-- when it need not.
create or replace function private.vat_must_reason(st jsonb) returns text
language sql immutable set search_path = public, private as $$
  select case when coalesce((st->>'crossed')::boolean, false) then 'sales_passed'
    when coalesce((st->>'small')::boolean, true) then null
    when coalesce((st->>'turnover')::numeric, 0) > 100000000 then 'turnover'
    when coalesce((st->>'fixed_assets')::numeric, 0) > 250000000 then 'fixed_assets'
    when coalesce((st->>'professional_services')::boolean, false) then 'professional_services' end
$$;

-- What the business's people are told when Counta turns VAT on.
create or replace function private.vat_on_words(p_reason text, st jsonb, p_day date) returns jsonb
language plpgsql stable set search_path = public, private as $$
declare v_title text; v_why text; v_rate text := rtrim(to_char(private.vat_rate(p_day) * 100, 'FM999990.99'), '.');
  fmt constant text := 'FMDD Mon YYYY';
begin
  case p_reason
    when 'sales_passed' then
      v_title := 'VAT is now on: sales passed ₦100 million';
      v_why := 'Sales this financial year (from ' || to_char((st->>'year_from')::date, fmt) || ') come to ' || private.naira((st->>'year_to_date')::numeric)
        || ', above the ₦100 million a small company may make without charging VAT.';
    when 'turnover' then
      v_title := 'VAT is now on: turnover is above ₦100 million';
      v_why := 'Turnover for ' || to_char((st->>'from')::date, fmt) || ' to ' || to_char((st->>'to')::date, fmt) || ' was '
        || private.naira((st->>'turnover')::numeric) || ', above the ₦100 million small company limit.';
    when 'fixed_assets' then
      v_title := 'VAT is now on: fixed assets are above ₦250 million';
      v_why := 'Fixed assets come to ' || private.naira((st->>'fixed_assets')::numeric) || ', above the ₦250 million small company limit.';
    else
      v_title := 'VAT is now on for professional services';
      v_why := 'The business provides professional services, which the small company exemption from VAT does not cover.';
  end case;
  return jsonb_build_object('title', v_title, 'lines', jsonb_build_array(v_why,
    'Counta turned VAT on this morning. Invoices and receipts from now on charge VAT at ' || v_rate || '% where it applies, and a VAT return is due every month by the 21st.',
    'Invoices already issued stay as they are. A draft saved before today must be saved again before it is issued.',
    'If a figure is wrong, correct the books. Once the business is back within the small company limits, the owner can turn VAT off in Accounting, Tax returns, VAT.'));
end $$;

-- Every morning: each business that does not charge VAT but must has it turned on, and its people are told. One business
-- that fails never stops the others.
CREATE OR REPLACE FUNCTION private.vat_threshold_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare o record; st jsonb; v_reason text; c public.vat_changes; w jsonb;
begin
  for o in select id from orgs where not vat_registered and not is_sample and read_only_at is null loop
    begin
      st := private.vat_small_status(o.id);
      v_reason := private.vat_must_reason(st);
      continue when v_reason is null;
      update orgs set vat_registered = true, vat_opt_in = false where id = o.id and not vat_registered;
      continue when not found;
      insert into vat_changes (org_id, charge, by_member, by_name, reason, status) values (o.id, true, null, 'Counta', v_reason, st) returning * into c;
      w := private.vat_on_words(v_reason, st, private.local_day(o.id, now()));
      perform private.alert_send(o.id, 'vat_on', c.id::text, array['push', 'email', 'whatsapp'],
        jsonb_build_object('title', w->>'title', 'body', w->'lines'->>0, 'lines', w->'lines', 'url', '/tax/vat', 'perm', 'keep_books',
          'button', 'Open VAT'));
    exception when others then
      raise warning 'vat_threshold_tick: % could not be switched: %', o.id, sqlerrm;
    end;
  end loop;
end $function$;

-- The owner's own changes are kept too.
CREATE OR REPLACE FUNCTION public.set_vat_charging(p_org uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; st jsonb; v_charge boolean := (p->>'charge')::boolean; v_was boolean;
begin
  m := private.require(p_org, null);
  if not private.perm_of(m, 'owner') then raise exception 'Only the owner turns VAT on or off.' using errcode = '42501'; end if;
  if v_charge is null then raise exception 'Say whether the business charges VAT.'; end if;
  st := private.vat_small_status(p_org);
  if not v_charge and not (st->>'small')::boolean then
    raise exception 'Only a small company (turnover up to ₦100 million, fixed assets up to ₦250 million, no professional services) may stop charging VAT.';
  end if;
  if not v_charge and (st->>'crossed')::boolean then raise exception 'Turnover this year is above ₦100 million, so VAT must be charged.'; end if;
  select vat_registered into v_was from orgs where id = p_org for update;
  update orgs set vat_registered = v_charge, vat_opt_in = v_charge and (st->>'small')::boolean where id = p_org;
  if v_was is distinct from v_charge then
    insert into vat_changes (org_id, charge, by_member, by_name, reason, status) values (p_org, v_charge, m.id, m.display_name, 'owner', st);
  end if;
  return public.vat_status(p_org);
end $function$;

-- The VAT tab also shows the last change (who, when and why) and whether Counta turns VAT on tomorrow morning.
CREATE OR REPLACE FUNCTION public.vat_status(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare m public.members; st jsonb; o public.orgs; v_advice text;
begin
  m := private.require(p_org, null);
  select * into o from orgs where id = p_org;
  st := private.vat_small_status(p_org);
  v_advice := case
      when not (st->>'charging')::boolean and ((st->>'crossed')::boolean or not (st->>'small')::boolean) then 'must_start'
      when (st->>'charging')::boolean and (st->>'small')::boolean and not (st->>'opt_in')::boolean then 'may_stop'
      else 'ok' end;
  return st || jsonb_build_object('advice', v_advice, 'can_change', private.perm_of(m, 'owner'),
    'must_reason', case when v_advice = 'must_start' then private.vat_must_reason(st) end,
    'auto_on', v_advice = 'must_start' and not o.is_sample and o.read_only_at is null,
    'last_change', (select jsonb_build_object('charge', c.charge, 'auto', c.by_member is null, 'by', coalesce(c.by_name, 'Counta'), 'reason', c.reason,
        'at', c.created_at, 'year_to_date', c.status->'year_to_date', 'year_from', c.status->'year_from', 'turnover', c.status->'turnover',
        'fixed_assets', c.status->'fixed_assets', 'from', c.status->'from', 'to', c.status->'to')
      from vat_changes c where c.org_id = p_org order by c.created_at desc limit 1));
end $function$;

-- A draft saved before VAT was turned on or off is saved again before it is issued, so its VAT is right.
CREATE OR REPLACE FUNCTION private.issue_invoice_as(p_sale uuid, p_issue_date date, m members)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare s public.sales; c public.customers; v_owed numeric; v_day date; v_today date; d public.einvoice_docs; v_vat boolean;
begin
  select * into s from sales where id = p_sale for update;
  if not found then raise exception 'Invoice not found.'; end if;
  if s.doc_type <> 'invoice' or s.status <> 'draft' then raise exception '% is not a draft invoice.', s.number; end if;
  select * into d from einvoice_docs where sale_id = s.id;
  if d.state in ('waiting', 'sending') then raise exception 'NRS is already checking %.', s.number; end if;
  if s.total <= 0 then raise exception 'The invoice total must be above zero.'; end if;
  select vat_registered into v_vat from orgs where id = s.org_id;
  if s.vat_registered is distinct from v_vat then
    raise exception 'VAT was turned % for the business after % was saved. Open it and save it again so its VAT is right, then issue it.',
      case when v_vat then 'on' else 'off' end, s.number;
  end if;
  v_today := private.local_day(s.org_id, now());
  -- A draft left with the day it was started takes the day it is issued.
  v_day := coalesce(p_issue_date, case when s.issue_date = private.local_day(s.org_id, s.created_at) then v_today else s.issue_date end);
  if v_day > v_today then raise exception 'An invoice cannot be dated in the future.'; end if;
  perform private.require_open_day(s.org_id, v_day);
  select * into c from customers where id = s.customer_id;
  v_owed := private.customer_balance(s.org_id, c.id) + s.total;
  if c.credit_limit > 0 and v_owed > c.credit_limit + 0.004 and not (private.perm_of(m, 'approve_adjustments') or private.perm_of(m, 'keep_books')) then
    raise exception '% would owe % against a credit limit of %. A manager can issue it.', c.name, to_char(v_owed, 'FM999,999,999,990.00'), to_char(c.credit_limit, 'FM999,999,999,990.00');
  end if;
  -- To a business or government buyer, with e-invoicing on: NRS signs it first. It stays a draft, locked, until then.
  if private.einvoice_route(s.id) = 'clear' then
    if coalesce(upper(c.country), 'NG') = 'NG' and nullif(btrim(coalesce(c.tin, '')), '') is null then
      raise exception 'Add %''s Tax ID before issuing: NRS checks invoices to businesses and government, and needs it.', c.name;
    end if;
    update sales set due_date = coalesce(due_date, v_day) + (v_day - issue_date), issue_date = v_day,
      customer_name = c.name, customer_tin = c.tin, customer_email = c.email, customer_phone = c.phone, customer_address = c.address where id = s.id;
    perform private.einvoice_open(s.id, 'clear', true, m.id);
    return private.sale_json(s.id, private.can_see_costs(s.org_id));
  end if;
  update sales set status = 'open', due_date = coalesce(due_date, v_day) + (v_day - issue_date), issue_date = v_day where id = s.id;
  s := private.post_sale(s.id, m, private.posting_time(s.org_id, v_day));
  s := private.refresh_sale(s.id);
  return private.sale_json(s.id, private.can_see_costs(s.org_id));
end $function$;

-- ---------------------------------------------------------------------------
-- 3. Grants
-- ---------------------------------------------------------------------------
revoke all on function private.letterhead_page(jsonb), private.letterhead_file(uuid, jsonb, text), private.letterhead_norm(uuid, jsonb),
  private.vat_must_reason(jsonb), private.vat_on_words(text, jsonb, date) from public, anon, authenticated;

revoke all on function public.practice_set_letterhead(uuid, jsonb), public.practice_letter_preview(uuid, jsonb) from public, anon;
grant execute on function public.practice_set_letterhead(uuid, jsonb), public.practice_letter_preview(uuid, jsonb) to authenticated;
