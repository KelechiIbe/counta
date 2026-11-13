-- Engagement letters: per-practice templates as blocks (the default is the lawyer-drafted letter, converted), a letter per
-- intake with merge values from the intake, the practice and the partner, frozen once a partner signs; e-signing by the
-- client through a hashed es_ link and a 6-digit code emailed to them (5 sends a Lagos day, 5 tries per code, locked after
-- 15 failures); a signed copy may be uploaded instead. Edge-function calls are only recorded in net._requests.
begin;

-- Fixture: a verified practice (partners Bisi and Kunle, a manager, staff) with an office address, phone and state; another
-- practice; a cleared involved intake (Dayo Foods Ltd, RC 1234567, with an address and an industry), a cleared full-mandate
-- intake (Ikenna Textiles Ltd) and an intake whose conflicts check has not been run.
do $$
declare v_partner uuid; v_partner2 uuid; v_manager uuid; v_staff uuid; v_other uuid; v_pr uuid; v_pr2 uuid; v_i uuid; v_u uuid;
begin
  v_partner := tests.remember('partner', tests.user('bisi.partner@firm.example.test', 'Bisi Partner'));
  v_partner2 := tests.remember('partner2', tests.user('kunle.partner@firm.example.test', 'Kunle Partner'));
  v_manager := tests.remember('manager', tests.user('tola.manager@firm.example.test', 'Tola Manager'));
  v_staff := tests.remember('staff', tests.user('ife.staff@firm.example.test', 'Ife Staff'));
  v_other := tests.remember('other_partner', tests.user('kemi.other@other.example.test', 'Kemi Other'));
  v_pr := tests.remember('pr', tests.practice(v_partner, 'Letter Partners', true));
  update practices set email = 'office@firm.example.test', phone = '+234 1 000 0000', state = 'Lagos', address = '1 Test Street, Ikeja'
  where id = v_pr;
  perform tests.remember('partner_pm', (select id from practice_members where practice_id = v_pr and user_id = v_partner));
  perform tests.remember('partner2_pm', tests.practice_member(v_pr, v_partner2, 'partner'));
  perform tests.remember('manager_pm', tests.practice_member(v_pr, v_manager, 'manager'));
  perform tests.remember('staff_pm', tests.practice_member(v_pr, v_staff, 'staff'));
  -- Bisi is the practice's first partner (in one transaction everyone would join at the same moment).
  update practice_members set created_at = created_at + interval '1 minute' where practice_id = v_pr and user_id <> v_partner;
  v_pr2 := tests.remember('pr2', tests.practice(v_other, 'Other Partners', true));

  v_i := tests.remember('i', tests.cleared_intake(v_pr, 'Dayo Foods Ltd'));
  update practice_intakes set rc_number = 'RC 1234567', entity_type = 'company', address = '2 Test Road, Lekki', industry = 'Food processing'
  where id = v_i;
  perform tests.remember('f', tests.cleared_intake(v_pr, 'Ikenna Textiles Ltd', 'full'));
  perform tests.as_user(v_partner);
  v_u := public.practice_intake_save(v_pr, '{"legal_name":"Unchecked Ventures Ltd","risk_rating":"low"}')->>'id';
  perform tests.as_postgres();
  perform tests.remember('u', v_u);
end $$;

-- test: default_template_valid
-- The lawyer-drafted letter as blocks: valid, the 16 numbered headings with fixed ids, every merge field of the draft used,
-- the conditional sections as optional blocks, the full-mandate clause as the one full-variant block, the fixes in, and
-- no clause numbers written into the text (the renderer numbers what remains).
do $$
declare b jsonb := private.letter_default_body();
begin
  assert private.letter_body_ok(b) is null, 'default_template_valid: validates';
  assert (select count(*) from jsonb_array_elements(b->'blocks') x where x->>'kind' = 'heading' and (x->>'level')::int = 1) = 16,
    'default_template_valid: 16 headings';
  assert (select array_agg(x->>'id' order by n) from jsonb_array_elements(b->'blocks') with ordinality t(x, n) where x->>'kind' = 'heading' and (x->>'level')::int = 1)
    = '{scope,authority,responsibilities,team,fees,confidentiality,conflicts,aml,personal_data,liability,copyright,retention,term,problems,governing_law,signing}',
    'default_template_valid: fixed heading ids';
  assert (select count(distinct x->>'id') from jsonb_array_elements(b->'blocks') x where x->>'id' in ('scope','scope_services','svc_bookkeeping','conf_other_clients','term')) = 5,
    'default_template_valid: pinned ids';
  assert (select bool_and(b::text like '%{{' || f || '}}%' or b::text like '%{{#' || f || '}}%' or b->'blocks' @> jsonb_build_array(jsonb_build_object('optional', f))
            or f in ('mode.full_mandate','signature.firm','signature.client')) from unnest(private.letter_fields()) f),
    'default_template_valid: every field maps';
  assert (select count(*) from jsonb_array_elements(b->'blocks') x where x->>'variant' = 'full') = 1, 'default_template_valid: one full-mandate clause';
  assert b::text like '%Rev360%' and b::text like '%Nigeria Data Protection Act 2023%' and b::text not like '%TaxProMax%' and b::text not ilike '%ethSSL%',
    'default_template_valid: fixes';
  assert not exists (select 1 from jsonb_array_elements(b->'blocks') x where x->>'text' ~ '^(\d+(\.\d+)?\s|\([a-z]+\)\s)'),
    'default_template_valid: numbering computed at render';

  -- The 50 fields of the draft, each once.
  assert cardinality(private.letter_fields()) = 50 and (select count(distinct f) from unnest(private.letter_fields()) f) = 50,
    'default_template_valid: 50 fields';
  assert (b->>'version')::int = 1 and jsonb_array_length(b->'blocks') = 118, 'default_template_valid: version 1, one block per paragraph';
  -- References by id, never by written-out number.
  assert b::text like '%paragraph {{ref:scope_services}}%' and b::text like '%where paragraph {{ref:svc_bookkeeping}} applies%'
     and b::text like '%as described in paragraph {{ref:conf_other_clients}},%' and b::text like '%ends under paragraph {{ref:term}} or%',
    'default_template_valid: references';
  assert not exists (select 1 from jsonb_array_elements(b->'blocks') x where x->>'text' ~ 'paragraph [0-9]'), 'default_template_valid: no written-out references';
  assert (select x->>'kind' = 'clause' and (x->>'level')::int = 2 from jsonb_array_elements(b->'blocks') x where x->>'id' = 'scope_services')
     and (select x->>'kind' = 'list' and (x->>'level')::int = 3 and x->>'optional' = 'service.bookkeeping' from jsonb_array_elements(b->'blocks') x where x->>'id' = 'svc_bookkeeping')
     and (select x->>'kind' = 'clause' from jsonb_array_elements(b->'blocks') x where x->>'id' = 'conf_other_clients'),
    'default_template_valid: kinds and levels of the pinned blocks';
  assert (select count(*) from jsonb_array_elements(b->'blocks') x where x->>'kind' = 'list' and (x->>'level')::int = 4) = 19,
    'default_template_valid: (i) items at level 4';
  -- Clause 2.1(d) only with bookkeeping; the full-mandate clause is 2.2.
  assert (select x->>'optional' = 'service.bookkeeping' and x->>'kind' = 'list' and (x->>'level')::int = 3
          from jsonb_array_elements(b->'blocks') x where x->>'text' like '%{{ref:svc_bookkeeping}}%'), 'default_template_valid: 2.1(d) optional';
  assert (select x->>'kind' = 'clause' and x->>'text' like 'Full mandate. The Client further authorises us%' and x->>'optional' is null
          from jsonb_array_elements(b->'blocks') x where x->>'variant' = 'full'), 'default_template_valid: full-mandate clause';
  -- Whole-paragraph sections are optional blocks; inline ones stay in the text.
  assert (select count(*) from jsonb_array_elements(b->'blocks') x where x->>'optional' = 'service.advisory') = 4
     and (select count(*) from jsonb_array_elements(b->'blocks') x where x->>'optional' = 'service.bookkeeping') = 8
     and (select count(*) from jsonb_array_elements(b->'blocks') x where x->>'optional' = 'service.monthly') = 6
     and (select count(*) from jsonb_array_elements(b->'blocks') x where x->>'optional' = 'service.annual') = 6
     and (select count(*) from jsonb_array_elements(b->'blocks') x where x->>'optional' = 'service.other') = 1
     and (select count(*) from jsonb_array_elements(b->'blocks') x where x->>'optional' = 'fees.deposit') = 1
     and (select count(*) from jsonb_array_elements(b->'blocks') x where x->>'optional' is not null) = 26,
    'default_template_valid: optional sections';
  assert not exists (select 1 from jsonb_array_elements(b->'blocks') x where x->>'text' ~ '^\{\{#'), 'default_template_valid: no block opens with a section';
  assert b::text like '%discussions{{#proposal.date}} and our proposal dated {{proposal.date}}{{/proposal.date}}. This letter%'
     and b::text like '%{{#fees.deposit}} and the expense deposit{{/fees.deposit}}%', 'default_template_valid: inline sections kept';
  assert (select array_agg(x->>'text' order by n) from jsonb_array_elements(b->'blocks') with ordinality t(x, n) where x->>'kind' = 'signature') = '{firm,client}',
    'default_template_valid: signature blocks';
  -- The draft's wording, spot-checked; no addresses or phone numbers.
  assert b::text like '%whichever is {{liability.cap_basis}}.%' and b::text like '%The seat of arbitration is {{arbitration.seat}} and the language is English.%'
     and b::text like '%(currently Rev360) or the portal of the relevant SIRS; and%', 'default_template_valid: wording';
  assert b::text not like '%@%' and b::text !~ '[0-9]{5,}', 'default_template_valid: no addresses or phone numbers';
  assert private.letter_defaults() = '{"liability.cap_basis":"lower","retention.years":6,"termination.notice_days":30,"termination.handover_days":14,
    "fees.payment_days":14,"fees.suspend_days":30,"fees.frequency":"monthly","fees.billing_day":1,"fees.billing_period":"month","service.days":10,
    "arbitration.seat":"Lagos","contact.salutation":"Sir/Madam","client.reg_label":"RC"}'::jsonb, 'default_template_valid: defaults';
  assert (select bool_and(k = any (private.letter_fields())) from jsonb_object_keys(private.letter_defaults()) k), 'default_template_valid: defaults are fields';
end $$;

-- test: letter_body_rejects
do $$
begin
  assert private.letter_body_ok('{"version":1,"blocks":[{"id":"a","kind":"paragraph","level":1,"text":"<b>x</b>"}]}') is not null, 'letter_body_rejects: html';
  assert private.letter_body_ok('{"version":1,"blocks":[{"id":"a","kind":"paragraph","level":1,"text":"{{client.nickname}}"}]}') is not null, 'letter_body_rejects: field';
  assert private.letter_body_ok('{"version":1,"blocks":[{"id":"a","kind":"paragraph","level":1,"text":"see {{ref:zz}}"}]}') is not null, 'letter_body_rejects: ref';
  -- A small valid body, then one thing wrong at a time.
  assert private.letter_body_ok('{"version":1,"blocks":[{"id":"h","kind":"heading","level":1,"text":"Scope"},
    {"id":"c-1","kind":"clause","level":2,"text":"See {{ref:h}} for {{client.name}}{{#fees.deposit}} and {{fees.deposit}}{{/fees.deposit}}.","optional":"service.other","variant":null},
    {"id":"s","kind":"signature","level":1,"text":"client","variant":"involved"}]}') is null, 'letter_body_rejects: a valid body';
  assert private.letter_body_ok('{"version":2,"blocks":[{"id":"a","kind":"paragraph","level":1,"text":"x"}]}') like '%version%', 'letter_body_rejects: version';
  assert private.letter_body_ok('{"version":1,"blocks":[]}') like '%1 to 600%', 'letter_body_rejects: no blocks';
  assert private.letter_body_ok(jsonb_build_object('version', 1, 'blocks', (select jsonb_agg(jsonb_build_object('id', 'b' || g, 'kind', 'paragraph', 'level', 1, 'text', 'x'))
    from generate_series(1, 601) g))) like '%1 to 600%', 'letter_body_rejects: 601 blocks';
  assert private.letter_body_ok(jsonb_build_object('version', 1, 'blocks', (select jsonb_agg(jsonb_build_object('id', 'b' || g, 'kind', 'paragraph', 'level', 1, 'text', repeat('x', 3900)))
    from generate_series(1, 60) g))) like '%200 KB%', 'letter_body_rejects: too big';
  assert private.letter_body_ok('{"version":1,"blocks":[{"id":"a","kind":"paragraph","level":1,"text":"x"},{"id":"a","kind":"paragraph","level":1,"text":"y"}]}') like '%Two paragraphs%',
    'letter_body_rejects: duplicate id';
  assert private.letter_body_ok('{"version":1,"blocks":[{"id":"A b","kind":"paragraph","level":1,"text":"x"}]}') like '%id%', 'letter_body_rejects: id form';
  assert private.letter_body_ok('{"version":1,"blocks":[{"id":"a","kind":"table","level":1,"text":"x"}]}') like '%heading, clause%', 'letter_body_rejects: kind';
  assert private.letter_body_ok('{"version":1,"blocks":[{"id":"a","kind":"paragraph","level":5,"text":"x"}]}') like '%level%', 'letter_body_rejects: level';
  assert private.letter_body_ok('{"version":1,"blocks":[{"id":"a","kind":"paragraph","level":"1","text":"x"}]}') like '%level%', 'letter_body_rejects: level as text';
  assert private.letter_body_ok(jsonb_build_object('version', 1, 'blocks', jsonb_build_array(jsonb_build_object('id', 'a', 'kind', 'paragraph', 'level', 1, 'text', repeat('x', 4001)))))
    like '%4,000%', 'letter_body_rejects: long text';
  assert private.letter_body_ok('{"version":1,"blocks":[{"id":"a","kind":"paragraph","level":1,"text":"  "}]}') like '%no text%', 'letter_body_rejects: empty text';
  assert private.letter_body_ok('{"version":1,"blocks":[{"id":"a","kind":"paragraph","level":1,"text":"x","variant":"both"}]}') like '%full mandate%', 'letter_body_rejects: variant';
  assert private.letter_body_ok('{"version":1,"blocks":[{"id":"a","kind":"paragraph","level":1,"text":"x","optional":"service.payroll"}]}') like '%service.payroll%',
    'letter_body_rejects: optional field';
  assert private.letter_body_ok('{"version":1,"blocks":[{"id":"a","kind":"paragraph","level":1,"text":"x","colour":"red"}]}') like '%settings%', 'letter_body_rejects: unknown setting';
  assert private.letter_body_ok('{"version":1,"blocks":[{"id":"a","kind":"paragraph","level":1,"text":"x"}],"theme":"dark"}') like '%settings%', 'letter_body_rejects: unknown body key';
  assert private.letter_body_ok('{"version":1,"blocks":[{"id":"a","kind":"signature","level":1,"text":"witness"}]}') like '%firm or the client%', 'letter_body_rejects: signature';
  assert private.letter_body_ok('{"version":1,"blocks":[{"id":"a","kind":"paragraph","level":1,"text":"{{#fees.deposit}}x"}]}') like '%without closing%', 'letter_body_rejects: open section';
  assert private.letter_body_ok('{"version":1,"blocks":[{"id":"a","kind":"paragraph","level":1,"text":"x{{/fees.deposit}}"}]}') like '%without opening%', 'letter_body_rejects: stray close';
  assert private.letter_body_ok('{"version":1,"blocks":[{"id":"a","kind":"paragraph","level":1,"text":"{{#fees.deposit}}{{#team.assistant}}x{{/fees.deposit}}{{/team.assistant}}"}]}')
    like '%without opening%', 'letter_body_rejects: crossed sections';
  assert private.letter_body_ok('{"version":1,"blocks":[{"id":"a","kind":"paragraph","level":1,"text":"{{client.name}"}]}') like '%braces%', 'letter_body_rejects: half a tag';
  assert private.letter_body_ok('{"version":1,"blocks":[{"id":"a","kind":"paragraph","level":1,"text":"{{ client.name }}"}]}') like '%unknown field%', 'letter_body_rejects: spaced tag';
  assert private.letter_body_ok('{"version":1,"blocks":[{"id":"p","kind":"paragraph","level":1,"text":"x"},{"id":"a","kind":"clause","level":2,"text":"see {{ref:p}}"}]}')
    like '%not a numbered paragraph%', 'letter_body_rejects: ref to an unnumbered block';
  assert private.letter_body_ok('[1]') is not null and private.letter_body_ok(null) is not null and private.letter_body_ok('{"version":1,"blocks":[7]}') is not null,
    'letter_body_rejects: not a body';
end $$;

-- test: templates_partner_only
-- Every lead reads the templates (the standard letter is added as the default the first time); only partners change them.
do $$
declare pr uuid := tests.id('pr'); r jsonb; t uuid; std uuid; v_body jsonb := '{"version":1,"blocks":[{"id":"scope","kind":"heading","level":1,"text":"Scope"},
  {"id":"terms","kind":"clause","level":2,"text":"We act for {{client.name}}."}]}';
begin
  perform tests.as_user(tests.id('manager'));
  r := public.practice_letter_templates(pr);
  assert jsonb_array_length(r) = 1 and r->0->>'name' = 'Counta standard letter' and (r->0->>'is_default')::boolean and r->0->>'kind' = 'blocks'
     and not (r->0->>'archived')::boolean and r->0->'pdf_path' = 'null'::jsonb, 'templates_partner_only: the standard letter';
  std := r->0->>'id';
  assert jsonb_array_length(public.practice_letter_templates(pr)) = 1, 'templates_partner_only: added once';
  perform tests.throws(format($q$select public.practice_letter_template_save(%L, '{"name":"Mine","kind":"blocks","body":%s}')$q$, pr, v_body), '%partner%');
  perform tests.throws(format($q$select public.practice_letter_template_save(%L, jsonb_build_object('id', %L::uuid, 'archived', true))$q$, pr, std), '%partner%');
  perform tests.as_user(tests.id('staff'));
  perform tests.throws(format('select public.practice_letter_templates(%L)', pr), '%partners and managers%');
  perform tests.as_user(tests.id('other_partner'));
  perform tests.throws(format('select public.practice_letter_templates(%L)', pr), '%not on this practice%');
  perform tests.throws(format($q$select public.practice_letter_template_save(%L, '{"name":"Mine","kind":"blocks","body":%s}')$q$, pr, v_body), '%not on this practice%');
  perform tests.as_postgres();
  assert (select body = private.letter_default_body() from practice_letter_templates where id = std), 'templates_partner_only: the default body';

  -- A partner adds a template and makes it the default: the standard letter stops being the default.
  perform tests.as_user(tests.id('partner'));
  r := public.practice_letter_template_save(pr, jsonb_build_object('name', ' Short letter ', 'kind', 'blocks', 'body', v_body, 'is_default', true));
  t := r->>'id';
  assert r->>'name' = 'Short letter' and (r->>'is_default')::boolean and r->'body' = v_body, 'templates_partner_only: saved';
  perform tests.throws(format($q$select public.practice_letter_template_save(%L, '{"name":"Bad","kind":"blocks","body":{"version":1,"blocks":[{"id":"a","kind":"paragraph","level":1,"text":"{{client.nickname}}"}]}}')$q$, pr),
    '%client.nickname%');
  perform tests.throws(format($q$select public.practice_letter_template_save(%L, '{"name":"No body","kind":"blocks"}')$q$, pr), '%form%');
  perform tests.throws(format($q$select public.practice_letter_template_save(%L, jsonb_build_object('name', 'X', 'kind', 'blocks', 'body', %L::jsonb))$q$, pr, v_body),
    '%2 to 80%');
  perform tests.throws(format($q$select public.practice_letter_template_save(%L, '{"name":"Odd","kind":"docx"}')$q$, pr), '%blocks or a PDF%');
  -- A PDF template: a file in the practice's letters folder, signed as it stands.
  perform tests.throws(format($q$select public.practice_letter_template_save(%L, '{"name":"Our PDF","kind":"pdf","pdf_path":"practice/%s/intake/x/our.pdf"}')$q$, pr, pr),
    '%letters folder%');
  perform tests.throws(format($q$select public.practice_letter_template_save(%L, '{"name":"Our PDF","kind":"pdf","pdf_path":"practice/%s/letters/templates/our.docx"}')$q$, pr, pr),
    '%PDF%');
  r := public.practice_letter_template_save(pr, jsonb_build_object('name', 'Our PDF', 'kind', 'pdf', 'pdf_path', 'practice/' || pr || '/letters/templates/our.pdf'));
  perform tests.remember('pdf_template', (r->>'id')::uuid);
  assert r->>'kind' = 'pdf' and r->'body' = 'null'::jsonb and not (r->>'is_default')::boolean, 'templates_partner_only: a PDF template';
  perform tests.throws(format($q$select public.practice_letter_template_save(%L, jsonb_build_object('id', %L::uuid, 'kind', 'blocks', 'body', %L::jsonb))$q$, pr, r->>'id', v_body),
    '%keeps its kind%');
  perform tests.as_postgres();
  assert (select count(*) from practice_letter_templates where practice_id = pr and is_default) = 1
     and (select is_default from practice_letter_templates where id = t) and not (select is_default from practice_letter_templates where id = std),
    'templates_partner_only: one default';
  -- Archived, a template is no longer the default; the standard letter is made the default again.
  perform tests.as_user(tests.id('partner'));
  r := public.practice_letter_template_save(pr, jsonb_build_object('id', t, 'archived', true));
  assert (r->>'archived')::boolean and not (r->>'is_default')::boolean, 'templates_partner_only: archived, not the default';
  perform tests.throws(format($q$select public.practice_letter_template_save(%L, jsonb_build_object('id', %L::uuid, 'archived', 'maybe'))$q$, pr, t), '%true or false%');
  perform public.practice_letter_template_save(pr, jsonb_build_object('id', std, 'is_default', true));
  r := public.practice_letter_templates(pr);
  perform tests.as_postgres();
  assert jsonb_array_length(r) = 3 and r->0->>'id' = std::text and (select count(*) from practice_letter_templates where practice_id = pr and is_default) = 1,
    'templates_partner_only: the standard letter is the default again, listed first';
  -- The table keeps one default per practice whatever writes it.
  perform tests.throws(format($q$update practice_letter_templates set is_default = true where id = %L$q$, t), '%check constraint%');
  perform tests.throws(format($q$insert into practice_letter_templates (practice_id, name, kind, body, is_default) values (%L, 'Two', 'blocks', %L, true)$q$, pr, v_body),
    '%duplicate key%');
end $$;

-- test: letter_draft_defaults
-- A draft letter from the default template: the variant is the intake's mode, the merge values are the defaults, then the
-- intake's, the practice's and the engagement partner's, then the caller's; retention at least five years.
do $$
declare pr uuid := tests.id('pr'); i uuid := tests.id('i'); l uuid; r jsonb; m jsonb;
  v_archived uuid := (select id from practice_letter_templates where practice_id = tests.id('pr') and archived limit 1);
begin
  perform tests.as_user(tests.id('manager'));
  r := public.practice_letter_draft(i, '{}');
  l := r->>'id';
  perform tests.as_postgres();
  perform tests.remember('l', l);
  assert (select merge->>'liability.cap_basis' = 'lower' and retention_years = 6 from engagement_letters where id = l), 'letter_draft_defaults';
  -- (As the manager while staying postgres, so the assertion may read the table too.)
  perform tests.as_definer(tests.id('manager'));
  assert public.practice_intake(i)->'letters'->0 = jsonb_build_object('id', l, 'status', 'draft', 'variant', (select variant from engagement_letters where id = l)),
    'letter_draft_defaults: practice_intake lists the letter';
  perform tests.as_user(tests.id('manager'));
  perform tests.throws(format($q$select public.practice_letter_draft(%L, '{"retention_years":4}')$q$, i), '23514%');
  perform tests.as_postgres();

  -- (Qualified: in PL/pgSQL an unqualified "select merge into" reads nothing, MERGE being a keyword.)
  select x.merge into m from engagement_letters x where x.id = l;
  assert m @> private.letter_defaults(), 'letter_draft_defaults: the defaults';
  assert m->>'client.name' = 'Dayo Foods Ltd' and m->>'client.rc_number' = '1234567' and m->>'client.reg_label' = 'RC' and m->>'client.address' = '2 Test Road, Lekki'
     and m->>'client.description' = 'operates in the food processing sector' and m->>'letter.date' = to_char((now() at time zone 'Africa/Lagos')::date, 'FMDD FMMonth YYYY'),
    'letter_draft_defaults: the intake';
  assert m->>'firm.name' = 'Letter Partners' and m->>'firm.email' = 'office@firm.example.test' and m->>'firm.phone' = (select phone from practices where id = pr) and m ? 'firm.phone' and m->>'firm.city' = 'Lagos'
     and m->>'partner.name' = 'Bisi Partner' and m->>'partner.title' = 'Partner' and m->>'partner.email' = 'bisi.partner@firm.example.test',
    'letter_draft_defaults: the practice and its first partner';
  assert (m->>'service.bookkeeping')::boolean and (m->>'service.monthly')::boolean and (m->>'service.annual')::boolean and not (m->>'service.advisory')::boolean
     and m->>'engagement.title_lower' = 'accounting and tax compliance services' and not (m->>'mode.full_mandate')::boolean and (m->>'retention.years')::int = 6,
    'letter_draft_defaults: the usual services';
  assert (select bool_and(k = any (private.letter_fields())) from jsonb_object_keys(m) k), 'letter_draft_defaults: only letter fields';
  assert (select variant = 'involved' and not white_label and status = 'draft' and source = 'template' and blocks = private.letter_default_body()
            and template_id = (select id from practice_letter_templates where practice_id = pr and is_default) and practice_id = pr and intake_id = i
            and client_id is null and title = 'Letter of engagement: Dayo Foods Ltd' and created_by = tests.id('manager_pm') and doc_path is null
          from engagement_letters where id = l), 'letter_draft_defaults: the letter';
  assert (select array_agg(kind || ':' || actor) from engagement_letter_events where letter_id = l) = '{drafted:Tola Manager}', 'letter_draft_defaults: event';
  assert r->>'status' = 'draft' and r->'signers' = '[]'::jsonb and jsonb_array_length(r->'events') = 1 and r->>'template_name' = 'Counta standard letter',
    'letter_draft_defaults: returns the letter';

  -- The caller's values win; retention years go into the letter's text; a field that is not the draft's is refused.
  perform tests.as_user(tests.id('partner'));
  r := public.practice_letter_draft(i, '{"retention_years":7,"merge":{"fees.amount":250000,"liability.cap_basis":"higher","contact.name":"Ada Eze"}}');
  perform tests.remember('l2', (r->>'id')::uuid);
  assert (r->>'retention_years')::int = 7 and (r->'merge'->>'retention.years')::int = 7 and r->'merge'->>'liability.cap_basis' = 'higher'
     and (r->'merge'->>'fees.amount')::numeric = 250000 and r->'merge'->>'contact.name' = 'Ada Eze', 'letter_draft_defaults: the caller''s values';
  r := public.practice_letter_draft(i, '{"merge":{"retention.years":8}}');
  assert (r->>'retention_years')::int = 8, 'letter_draft_defaults: retention from the merge values';
  perform tests.throws(format($q$select public.practice_letter_draft(%L, '{"merge":{"client.nickname":"Dee"}}')$q$, i), '%client.nickname%');
  perform tests.throws(format($q$select public.practice_letter_draft(%L, '{"merge":{"client.name":{"a":1}}}')$q$, i), '%client.name%');
  perform tests.throws(format($q$select public.practice_letter_draft(%L, '{"merge":{"client.name":"<script>x</script>"}}')$q$, i), '%client.name%');
  perform tests.throws(format($q$select public.practice_letter_draft(%L, '{"merge":{"client.name":"{{ref:term}}"}}')$q$, i), '%client.name%');
  perform tests.throws(format($q$select public.practice_letter_draft(%L, '{"merge":["x"]}')$q$, i), '%merge%');
  perform tests.throws(format($q$select public.practice_letter_draft(%L, '{"variant":"both"}')$q$, i), '%full mandate or involved%');
  -- A PDF template makes a PDF letter, signed as it stands.
  r := public.practice_letter_draft(i, jsonb_build_object('template_id', tests.id('pdf_template')));
  assert r->>'source' = 'pdf' and r->>'doc_path' = 'practice/' || pr || '/letters/templates/our.pdf' and r->'blocks' = 'null'::jsonb, 'letter_draft_defaults: PDF letter';

  -- A full-mandate intake: the full variant, white label. The variant can be chosen.
  r := public.practice_letter_draft(tests.id('f'), '{}');
  assert r->>'variant' = 'full' and (r->>'white_label')::boolean and (r->'merge'->>'mode.full_mandate')::boolean, 'letter_draft_defaults: full mandate';
  r := public.practice_letter_draft(tests.id('f'), '{"variant":"involved"}');
  assert r->>'variant' = 'involved' and not (r->>'white_label')::boolean, 'letter_draft_defaults: variant chosen';
  -- Leads of the practice only; not on a declined intake; not from another practice's template or an archived one.
  perform tests.as_user(tests.id('staff'));
  perform tests.throws(format($q$select public.practice_letter_draft(%L, '{}')$q$, i), '%partners and managers%');
  perform tests.as_user(tests.id('other_partner'));
  perform tests.throws(format($q$select public.practice_letter_draft(%L, '{}')$q$, i), '%not on this practice%');
  perform tests.throws(format($q$select public.practice_letter(%L)$q$, l), '%not on this practice%');
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_letter_draft(%L, jsonb_build_object('template_id', %L::uuid))$q$, i, v_archived), '%Template not found%');
  perform tests.throws(format($q$select public.practice_letter_draft(%L, '{"template_id":"%s"}')$q$, i, gen_random_uuid()), '%Template not found%');
  perform tests.as_postgres();
  update practice_intakes set status = 'declined' where id = tests.id('u');
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_letter_draft(%L, '{}')$q$, tests.id('u')), '%declined%');
  perform tests.as_postgres();
  update practice_intakes set status = 'draft' where id = tests.id('u');
  -- Newest first in the intake.
  update engagement_letters set created_at = created_at - interval '1 hour' where id = l;
  perform tests.as_user(tests.id('partner'));
  assert public.practice_intake(i)->'letters'->-1->>'id' = l::text and jsonb_array_length(public.practice_intake(i)->'letters') = 4,
    'letter_draft_defaults: newest first';
  perform tests.as_postgres();
end $$;

-- test: letter_save_rules
-- While a draft: partners change the clauses, leads the merge values, title and retention.
do $$
declare l uuid := tests.id('l'); r jsonb; v_body jsonb; v_pdf_letter uuid := (select id from engagement_letters where source = 'pdf' limit 1);
begin
  v_body := jsonb_set(private.letter_default_body(), '{blocks,0,text}', '"{{letter.date}} (draft)"');
  perform tests.as_user(tests.id('manager'));
  perform tests.throws(format($q$select public.practice_letter_save(%L, jsonb_build_object('blocks', %L::jsonb))$q$, l, v_body), '%partner%');
  r := public.practice_letter_save(l, '{"merge":{"fees.amount":150000,"service.advisory":true},"title":"Engagement letter for Dayo Foods","retention_years":9}');
  assert (r->'merge'->>'fees.amount')::numeric = 150000 and (r->'merge'->>'service.advisory')::boolean and r->'merge'->>'client.name' = 'Dayo Foods Ltd'
     and r->>'title' = 'Engagement letter for Dayo Foods' and (r->>'retention_years')::int = 9 and (r->'merge'->>'retention.years')::int = 9,
    'letter_save_rules: a lead changes the merge values';
  perform tests.throws(format($q$select public.practice_letter_save(%L, '{"merge":{"client.nickname":"Dee"}}')$q$, l), '%client.nickname%');
  perform tests.throws(format($q$select public.practice_letter_save(%L, '{"retention_years":3}')$q$, l), '23514%');
  perform tests.throws(format($q$select public.practice_letter_save(%L, '{"title":"x"}')$q$, l), '%2 to 160%');
  perform tests.as_user(tests.id('partner'));
  r := public.practice_letter_save(l, jsonb_build_object('blocks', v_body));
  assert r->'blocks'->'blocks'->0->>'text' = '{{letter.date}} (draft)', 'letter_save_rules: a partner changes a clause';
  r := public.practice_letter_save(l, jsonb_build_object('blocks', v_body->'blocks'));
  assert r->'blocks' = v_body, 'letter_save_rules: the blocks alone are the body';
  perform tests.throws(format($q$select public.practice_letter_save(%L, '{"blocks":{"version":1,"blocks":[{"id":"a","kind":"paragraph","level":1,"text":"<i>x</i>"}]}}')$q$, l),
    '%HTML%');
  perform tests.as_postgres();
  assert (select blocks = v_body from engagement_letters where id = l), 'letter_save_rules: the bad body was not kept';
  -- A PDF letter's clauses are the PDF's.
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_letter_save(%L, jsonb_build_object('blocks', %L::jsonb))$q$, v_pdf_letter, v_body), '%PDF%');
  -- Back to the standard text for what follows.
  perform tests.as_postgres();
  update engagement_letters set blocks = private.letter_default_body(), retention_years = 6, merge = merge || '{"retention.years":6}' where id = l;
end $$;

-- test: letter_prepare
-- What the practice function renders, for a partner, while the letter is a draft and the intake is cleared.
do $$
declare pr uuid := tests.id('pr'); l uuid := tests.id('l'); r jsonb; u_letter uuid;
begin
  perform tests.as_user(tests.id('manager'));
  perform tests.throws(format('select public.practice_letter_prepare(%L)', l), '%partner%');
  perform tests.as_user(tests.id('partner2'));
  r := public.practice_letter_prepare(l);
  perform tests.as_postgres();
  assert r->>'letter_id' = l::text and r->>'practice_id' = pr::text and r->>'source' = 'template' and r->'doc_path' = 'null'::jsonb
     and r->>'title' = 'Engagement letter for Dayo Foods' and r->>'variant' = 'involved' and r->'blocks' = private.letter_default_body()
     and r->'merge' = (select merge from engagement_letters where id = l), 'letter_prepare';
  assert r->'firm' @> '{"name":"Letter Partners","email":"office@firm.example.test","state":"Lagos"}' and r->'firm'->>'phone' = (select phone from practices where id = pr)
     and r->'partner' @> jsonb_build_object('id', tests.id('partner2_pm'), 'name', 'Kunle Partner', 'email', 'kunle.partner@firm.example.test', 'title', 'Partner'),
    'letter_prepare: the firm and the signing partner';
  -- Not before the conflicts check is done: the letter says it was.
  perform tests.as_user(tests.id('partner'));
  u_letter := public.practice_letter_draft(tests.id('u'), '{}')->>'id';
  perform tests.throws(format('select public.practice_letter_prepare(%L)', u_letter), '%conflicts check%');
  perform tests.as_postgres();
  perform tests.remember('u_letter', u_letter);
end $$;

-- test: letter_freeze
-- A partner signs: the rendered letter's path and fingerprint are recorded and the letter is frozen.
do $$
declare pr uuid := tests.id('pr'); l uuid := tests.id('l'); r jsonb; v_path text;
begin
  v_path := 'practice/' || pr || '/letters/' || l || '/letter.pdf';
  perform tests.as_service();
  -- Only a partner of the practice signs for it, a rendered file in the letter's folder, and a draft once.
  perform tests.throws(format($q$select public.svc_letter_frozen(%L, jsonb_build_object('doc_path', %L, 'doc_sha256', repeat('ab', 32), 'by_user', %L::uuid))$q$,
    l, v_path, tests.id('manager')), '%partner%');
  perform tests.throws(format($q$select public.svc_letter_frozen(%L, jsonb_build_object('doc_path', %L, 'doc_sha256', repeat('ab', 32), 'by_user', %L::uuid))$q$,
    l, v_path, tests.id('other_partner')), '%partner%');
  perform tests.throws(format($q$select public.svc_letter_frozen(%L, jsonb_build_object('doc_path', %L, 'doc_sha256', repeat('ab', 32), 'by_user', %L::uuid))$q$,
    l, 'practice/' || pr || '/letters/elsewhere/letter.pdf', tests.id('partner')), '%letter''s folder%');
  perform tests.throws(format($q$select public.svc_letter_frozen(%L, jsonb_build_object('doc_path', %L, 'doc_sha256', 'abc', 'by_user', %L::uuid))$q$,
    l, v_path, tests.id('partner')), '%SHA-256%');
  perform tests.throws(format($q$select public.svc_letter_frozen(%L, jsonb_build_object('doc_path', %L, 'doc_sha256', repeat('ab', 32), 'by_user', %L::uuid))$q$,
    tests.id('u_letter'), 'practice/' || pr || '/letters/' || tests.id('u_letter') || '/letter.pdf', tests.id('partner')), '%conflicts check%');
  r := public.svc_letter_frozen(l, jsonb_build_object('doc_path', v_path, 'doc_sha256', repeat('ab', 32), 'by_user', tests.id('partner'),
    'signature_name', 'Bisi Partner', 'ip', '203.0.113.5', 'ua', 'Test browser'));
  perform tests.as_postgres();
  assert r->>'status' = 'partner_signed', 'letter_freeze: signed by the firm';
  assert (select status = 'partner_signed' and doc_path = v_path and doc_sha256 = repeat('ab', 32) and partner_id = tests.id('partner_pm')
            and partner_signature = 'Bisi Partner' and partner_signed_at = now() and partner_ip = '203.0.113.5' and partner_ua = 'Test browser'
          from engagement_letters where id = l), 'letter_freeze: the firm''s signature recorded';
  perform tests.throws(format($q$update engagement_letters set blocks = '{}' where id = %L$q$, l), '%cannot be edited%');
  perform tests.throws(format($q$update engagement_letters set merge = merge || '{"fees.amount":1}' where id = %L$q$, l), '%cannot be edited%');
  perform tests.throws(format($q$update engagement_letters set variant = 'full', white_label = true where id = %L$q$, l), '%cannot be edited%');
  perform tests.throws(format($q$update engagement_letters set doc_sha256 = repeat('cd', 32) where id = %L$q$, l), '%cannot be edited%');
  perform tests.throws(format($q$update engagement_letters set doc_path = doc_path || 'x' where id = %L$q$, l), '%cannot be edited%');
  perform tests.throws(format($q$update engagement_letters set intake_id = %L where id = %L$q$, tests.id('f'), l), '%cannot be edited%');
  perform tests.throws(format($q$update engagement_letters set template_id = null where id = %L$q$, l), '%cannot be edited%');
  perform tests.throws(format($q$update engagement_letters set source = 'pdf' where id = %L$q$, l), '%cannot be edited%');
  perform tests.throws(format($q$update engagement_letters set retention_years = 9 where id = %L$q$, l), '%cannot be edited%');
  perform tests.throws(format($q$update engagement_letters set partner_signed_at = now() - interval '1 day' where id = %L$q$, l), '%cannot be edited%');
  assert tests.error_of(format($q$update engagement_letters set updated_at = now() where id = %L$q$, l)) is null, 'letter_freeze: other columns may change';
  perform tests.as_service();
  perform tests.throws(format($q$select public.svc_letter_frozen(%L, jsonb_build_object('doc_path', %L, 'doc_sha256', repeat('ab', 32), 'by_user', %L::uuid))$q$,
    l, v_path, tests.id('partner')), '%draft%');
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_letter_save(%L, '{"merge":{"fees.amount":1}}')$q$, l), '%draft%');
  perform tests.throws(format('select public.practice_letter_prepare(%L)', l), '%draft%');
  perform tests.as_postgres();
  assert (select array_agg(kind || ':' || actor order by id) from engagement_letter_events where letter_id = l) = '{drafted:Tola Manager,partner_signed:Bisi Partner}'
     and (select ip = '203.0.113.5' and ua = 'Test browser' from engagement_letter_events where letter_id = l and kind = 'partner_signed'),
    'letter_freeze: event';
end $$;

-- test: letter_send_queues_mail
-- A partner sends the signed letter to the client's signer: the messaging hook is queued; the link is made when it sends.
do $$
declare l uuid := tests.id('l'); r jsonb; s uuid;
begin
  perform tests.hooks_on();
  perform tests.as_user(tests.id('manager'));
  perform tests.throws(format($q$select public.practice_letter_send(%L, '{"name":"Dayo Client","email":"dayo@client.example.test","title":"Director"}')$q$, l), '%partner%');
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_letter_send(%L, '{"name":"Dayo Client","email":" Bisi.Partner@FIRM.example.test "}')$q$, l), '%client''s own email%');
  perform tests.throws(format($q$select public.practice_letter_send(%L, '{"name":"Dayo Client","email":"OFFICE@firm.example.test"}')$q$, l), '%client''s own email%');
  perform tests.throws(format($q$select public.practice_letter_send(%L, '{"name":"Dayo Client","email":"not-an-email"}')$q$, l), '%email address%');
  perform tests.throws(format($q$select public.practice_letter_send(%L, '{"name":"D","email":"dayo@client.example.test"}')$q$, l), '%name%');
  perform tests.throws(format($q$select public.practice_letter_send(%L, '{"name":"Dayo Client","email":"dayo@client.example.test"}')$q$, tests.id('l2')), '%firm signs%');
  r := public.practice_letter_send(l, '{"name":"Dayo Client","email":"Dayo@Client.example.test","title":"Director"}');
  perform tests.as_postgres();
  s := r->'signers'->0->>'id';
  perform tests.remember('s', s);
  assert exists (select 1 from net._requests where body->>'action' = 'practice_mail' and body->>'kind' = 'letter_sign'), 'letter_send_queues_mail';
  assert (select count(*) from net._requests where url = 'http://functions.test/messaging' and body = jsonb_build_object('action', 'practice_mail', 'kind', 'letter_sign', 'id', s)) = 1,
    'letter_send_queues_mail: the signer named';
  assert r->>'status' = 'sent' and jsonb_array_length(r->'signers') = 1 and r->'signers'->0->>'email' = 'dayo@client.example.test'
     and not (r->'signers'->0 ?| array['token_hash', 'otp_hash']), 'letter_send_queues_mail: sent, signer listed without hashes';
  assert (select name = 'Dayo Client' and email = 'dayo@client.example.test' and title = 'Director' and token_hash is null and otp_hash is null and signed_at is null
          from engagement_letter_signers where id = s), 'letter_send_queues_mail: the signer, no link yet';
  assert (select array_agg(kind order by id) from engagement_letter_events where letter_id = l) = '{drafted,partner_signed,sent}', 'letter_send_queues_mail: event';
  assert not exists (select 1 from net._requests where body::text ~ 'es_[0-9a-f]{48}'), 'letter_send_queues_mail: no link in the queue';
end $$;

-- test: sign_token_and_code
-- The messaging function asks for the email as it sends it: a fresh es_ link (only its hash kept, for 14 days; the last
-- link sent is the one that works) and, for the code email, a 6-digit code (only its hash kept, for 10 minutes).
do $$
declare l uuid := tests.id('l'); s uuid := tests.id('s'); r jsonb; tok text; tok2 text; c text;
begin
  perform tests.as_service();
  r := public.svc_practice_mail('letter_sign', s);
  assert r->>'link' ~ '/sign/es_[0-9a-f]{48}$' and (r->>'white_label')::boolean = ((select variant from engagement_letters where id = l) = 'full'),
    'sign_token_and_code: link';
  assert r->>'to' = 'dayo@client.example.test' and r->>'from_name' = 'Letter Partners' and r->>'reply_to' = 'bisi.partner@firm.example.test'
     and r->>'greet' = 'Dayo' and r->>'button' is not null and jsonb_array_length(r->'lines') >= 1 and r->>'link' like 'https://%/sign/es_%'
     and (r - 'link')::text not ilike '%counta%', 'sign_token_and_code: the email, in the firm''s name (the link''s domain aside)';
  tok := substring(r->>'link' from 'es_[0-9a-f]{48}$');
  perform tests.as_postgres();
  assert (select token_hash = private.sha256_hex(tok) and token_hash <> tok and token_expires between now() + interval '14 days' - interval '1 minute' and now() + interval '14 days'
          from engagement_letter_signers where id = s), 'sign_token_and_code: hash kept for 14 days';
  perform tests.as_service();
  tok2 := substring(public.svc_practice_mail('letter_sign', s)->>'link' from 'es_[0-9a-f]{48}$');
  assert tok2 <> tok and public.svc_sign_open(tok, '203.0.113.9', 'UA')->>'reason' = 'invalid' and (public.svc_sign_open(tok2, '203.0.113.9', 'UA')->>'ok')::boolean,
    'sign_token_and_code: a new link replaces the old';
  assert public.svc_sign_open('es_' || repeat('0', 48), '203.0.113.9', 'UA')->>'reason' = 'invalid' and public.svc_sign_open('nonsense', null, null)->>'reason' = 'invalid'
     and public.svc_sign_open(null, null, null)->>'reason' = 'invalid', 'sign_token_and_code: unknown links';
  c := public.svc_practice_mail('letter_code', s)->>'code';
  assert c ~ '^[0-9]{6}$', 'sign_token_and_code: 6 digits';
  r := public.svc_practice_mail('letter_code', s);
  assert r->>'code' ~ '^[0-9]{6}$' and r->>'to' = 'dayo@client.example.test' and (r - 'link')::text not ilike '%counta%', 'sign_token_and_code: the code email';
  c := r->>'code';
  perform tests.as_postgres();
  perform set_config('letters.tok', tok2, true);
  assert (select otp_hash = private.sha256_hex(s::text || ':' || c) and otp_tries = 0 and otp_expires = now() + interval '10 minutes'
          from engagement_letter_signers where id = s), 'sign_token_and_code: the code''s hash kept for 10 minutes';
  assert not exists (select 1 from net._requests where body::text like '%' || c || '%') and not exists (select 1 from engagement_letter_events where detail::text like '%' || c || '%'),
    'sign_token_and_code: the code is in no queue and no record';
  -- Nothing to send for a letter that is not out for signing, or for an id that is not a signer's.
  perform tests.as_service();
  assert public.svc_practice_mail('letter_sign', gen_random_uuid()) is null and public.svc_practice_mail('letter_code', gen_random_uuid()) is null
     and public.svc_practice_mail('letter_done', l) is null, 'sign_token_and_code: nothing to send';
  perform tests.throws(format('select public.svc_practice_mail(''letter_shout'', %L)', s), '%Unknown%');
  perform tests.as_postgres();
end $$;

-- test: sign_limits
-- Five codes a Lagos day; five tries per code; locked after fifteen failures. Wrong codes never raise, so the counts stay.
do $$
declare s uuid := tests.id('s'); tok text := current_setting('letters.tok'); r jsonb; c text; w text; k int; n int;
begin
  perform tests.hooks_on();
  perform tests.as_service();
  for k in 1..5 loop
    r := public.svc_sign_code(tok, '203.0.113.9', 'UA');
    assert (r->>'ok')::boolean, format('sign_limits: code %s sent', k);
  end loop;
  r := public.svc_sign_code(tok, '203.0.113.9', 'UA');
  assert not (r->>'ok')::boolean and r->>'reason' = 'too_many_today', 'sign_limits: a sixth code today refused';
  perform tests.as_postgres();
  assert (select sends_today = 5 and sends_day = (now() at time zone 'Africa/Lagos')::date from engagement_letter_signers where id = s), 'sign_limits: counted';
  assert (select count(*) from net._requests where body = jsonb_build_object('action', 'practice_mail', 'kind', 'letter_code', 'id', s)) = 5
     and (select count(*) from engagement_letter_events e join engagement_letter_signers x on x.letter_id = e.letter_id where x.id = s and e.kind = 'code_sent') = 5,
    'sign_limits: five code emails queued';
  -- The next Lagos day starts again.
  update engagement_letter_signers set sends_day = sends_day - 1 where id = s;
  perform tests.as_service();
  assert (public.svc_sign_code(tok, '203.0.113.9', 'UA')->>'ok')::boolean, 'sign_limits: a new day';
  perform tests.as_postgres();
  assert (select sends_today = 1 from engagement_letter_signers where id = s), 'sign_limits: a new count';

  -- Five tries per code: then even the right code is refused.
  perform tests.as_service();
  c := public.svc_practice_mail('letter_code', s)->>'code';
  w := lpad(((c::int + 1) % 1000000)::text, 6, '0');
  for k in 1..5 loop
    r := public.svc_sign_verify(tok, w, '203.0.113.9', 'UA');
    assert not (r->>'ok')::boolean and r->>'reason' = 'wrong_code' and (r->>'tries_left')::int = 5 - k, format('sign_limits: wrong code %s', k);
  end loop;
  r := public.svc_sign_verify(tok, c, '203.0.113.9', 'UA');
  assert r->>'reason' = 'used_up' and not (r->>'ok')::boolean and r->'letter' is null, 'sign_limits: five wrong codes → used_up';
  perform tests.as_postgres();
  assert (select otp_tries = 5 and otp_failures = 5 and locked_at is null and code_verified_at is null from engagement_letter_signers where id = s),
    'sign_limits: the counts kept';
  -- An expired code.
  perform tests.as_service();
  c := public.svc_practice_mail('letter_code', s)->>'code';
  perform tests.as_postgres();
  update engagement_letter_signers set otp_expires = now() - interval '1 second' where id = s;
  perform tests.as_service();
  assert public.svc_sign_verify(tok, c, '203.0.113.9', 'UA')->>'reason' = 'expired', 'sign_limits: an expired code';
  -- Ten more failures over two more codes: locked at fifteen.
  for n in 1..2 loop
    c := public.svc_practice_mail('letter_code', s)->>'code';
    w := lpad(((c::int + 1) % 1000000)::text, 6, '0');
    for k in 1..5 loop
      r := public.svc_sign_verify(tok, w, '203.0.113.9', 'UA');
    end loop;
  end loop;
  assert r->>'reason' = 'wrong_code' and (r->>'locked')::boolean and (r->>'tries_left')::int = 0, 'sign_limits: the fifteenth failure';
  perform tests.as_postgres();
  assert (select otp_failures = 15 and locked_at = now() from engagement_letter_signers where id = s), 'sign_limits: fifteen failures → locked, locked_at set';
  perform tests.as_service();
  assert public.svc_sign_code(tok, '203.0.113.9', 'UA')->>'reason' = 'locked', 'sign_limits: no more codes';
  assert public.svc_practice_mail('letter_code', s) is null, 'sign_limits: no code email for a locked signer';
  perform tests.as_postgres();
  update engagement_letter_signers set otp_hash = private.sha256_hex(s::text || ':123456'), otp_expires = now() + interval '5 minutes', otp_tries = 0 where id = s;
  perform tests.as_service();
  assert public.svc_sign_verify(tok, '123456', '203.0.113.9', 'UA')->>'reason' = 'locked', 'sign_limits: not even the right code';
  perform tests.as_postgres();
  assert (select count(*) from engagement_letter_events e join engagement_letter_signers x on x.letter_id = e.letter_id where x.id = s and e.kind = 'code_failed') = 15,
    'sign_limits: each failure recorded';
  -- The partner sends the letter again: a new link, the codes start afresh (the day's code emails still count).
  perform tests.as_user(tests.id('partner'));
  r := public.practice_letter_send(tests.id('l'), '{"name":"Dayo Client","email":"dayo@client.example.test","title":"Director"}');
  perform tests.as_postgres();
  assert r->'signers'->0->>'id' = s::text and (select token_hash is null and otp_hash is null and otp_tries = 0 and otp_failures = 0 and locked_at is null
            and sends_today = 1 from engagement_letter_signers where id = s), 'sign_limits: sent again';
  perform tests.as_service();
  assert public.svc_sign_open(tok, '203.0.113.9', 'UA')->>'reason' = 'invalid', 'sign_limits: the old link stops';
  perform tests.as_postgres();
end $$;

-- test: sign_complete
-- The client opens the link, asks for a code, confirms it and signs: the letter is completed and both sides are emailed.
do $$
declare pr uuid := tests.id('pr'); l uuid; s uuid; tok text; c text; r jsonb; v_done jsonb; v_final text;
begin
  perform tests.hooks_on();
  perform tests.as_user(tests.id('partner'));
  l := public.practice_letter_draft(tests.id('i'), '{"merge":{"contact.name":"Dayo Client"}}')->>'id';
  perform tests.as_service();
  perform public.svc_letter_frozen(l, jsonb_build_object('doc_path', 'practice/' || pr || '/letters/' || l || '/letter.pdf', 'doc_sha256', repeat('ab', 32),
    'by_user', tests.id('partner'), 'signature_name', 'Bisi Partner', 'ip', '203.0.113.5', 'ua', 'Test browser'));
  perform tests.as_user(tests.id('partner'));
  s := public.practice_letter_send(l, '{"name":"Dayo Client","email":"dayo@client.example.test","title":"Director"}')->'signers'->0->>'id';
  perform tests.as_service();
  tok := substring(public.svc_practice_mail('letter_sign', s)->>'link' from 'es_[0-9a-f]{48}$');
  r := public.svc_sign_open(tok, '203.0.113.9', 'UA');
  assert (r->>'ok')::boolean and r->>'letter_id' = l::text and r->>'title' = 'Letter of engagement: Dayo Foods Ltd' and r->>'firm_name' = 'Letter Partners'
     and r->>'signer_name' = 'Dayo Client' and r->>'doc_path' = 'practice/' || pr || '/letters/' || l || '/letter.pdf' and r->>'status' = 'sent'
     and not (r->>'white_label')::boolean, 'sign_complete: opened';
  assert (public.svc_sign_code(tok, '203.0.113.9', 'UA')->>'ok')::boolean, 'sign_complete: code asked for';
  c := public.svc_practice_mail('letter_code', s)->>'code';
  assert public.svc_sign_complete(tok, '{}')->>'reason' = 'not_verified', 'sign_complete: not before the code';
  r := public.svc_sign_verify(tok, c, '203.0.113.9', 'UA');
  assert (public.svc_sign_verify(tok, c, '203.0.113.9', 'UA')->>'reason') = 'expired', 'sign_complete: a code works once';
  assert (r->>'ok')::boolean and r->>'reason' is null, 'sign_complete: verify';
  assert r->'letter' @> jsonb_build_object('letter_id', l, 'signer_id', s, 'doc_path', 'practice/' || pr || '/letters/' || l || '/letter.pdf', 'doc_sha256', repeat('ab', 32),
       'title', 'Letter of engagement: Dayo Foods Ltd', 'practice_id', pr, 'partner_name', 'Bisi Partner', 'partner_email', 'bisi.partner@firm.example.test',
       'partner_ip', '203.0.113.5', 'partner_ua', 'Test browser', 'signer_name', 'Dayo Client', 'signer_email', 'dayo@client.example.test', 'signer_title', 'Director')
     and r->'letter'->>'partner_signed_at' is not null, 'sign_complete: what the certificate needs';
  -- The code confirms the signer for 15 minutes.
  perform tests.as_postgres();
  update engagement_letter_signers set code_verified_at = now() - interval '16 minutes' where id = s;
  perform tests.as_service();
  v_final := 'practice/' || pr || '/letters/' || l || '/final.pdf';
  assert public.svc_sign_complete(tok, jsonb_build_object('signature_path', 'practice/' || pr || '/letters/' || l || '/signature-' || s || '.png', 'final_path', v_final,
    'final_sha256', repeat('cd', 32), 'typed_name', 'Dayo Client', 'ip', '203.0.113.9', 'ua', 'UA'))->>'reason' = 'not_verified', 'sign_complete: 15 minutes';
  assert (public.svc_sign_code(tok, '203.0.113.9', 'UA')->>'ok')::boolean, 'sign_complete: another code';
  c := public.svc_practice_mail('letter_code', s)->>'code';
  assert (public.svc_sign_verify(tok, c, '203.0.113.9', 'UA')->>'ok')::boolean, 'sign_complete: verified again';
  perform tests.throws(format($q$select public.svc_sign_complete(%L, jsonb_build_object('signature_path', 'practice/%s/letters/elsewhere/sig.png', 'final_path', %L,
    'final_sha256', repeat('cd', 32), 'typed_name', 'Dayo Client'))$q$, tok, pr, v_final), '%letter''s folder%');
  perform tests.throws(format($q$select public.svc_sign_complete(%L, jsonb_build_object('signature_path', %L, 'final_path', %L, 'final_sha256', 'zz', 'typed_name', 'Dayo Client'))$q$,
    tok, 'practice/' || pr || '/letters/' || l || '/sig.png', v_final), '%SHA-256%');
  perform tests.throws(format($q$select public.svc_sign_complete(%L, jsonb_build_object('signature_path', %L, 'final_path', %L, 'final_sha256', repeat('cd', 32), 'typed_name', ' '))$q$,
    tok, 'practice/' || pr || '/letters/' || l || '/sig.png', v_final), '%name%');
  r := public.svc_sign_complete(tok, jsonb_build_object('signature_path', 'practice/' || pr || '/letters/' || l || '/signature-' || s || '.png', 'final_path', v_final,
    'final_sha256', repeat('cd', 32), 'typed_name', 'Dayo Client', 'ip', '203.0.113.9', 'ua', 'UA'));
  assert (r->>'ok')::boolean and r->>'status' = 'completed', 'sign_complete: done';
  perform tests.as_postgres();
  assert (select status from engagement_letters where id = l) = 'completed'
     and (select array_agg(kind order by id) from engagement_letter_events where letter_id = l) @> '{partner_signed,sent,opened,code_sent,signed}', 'sign_complete';
  assert (select final_path = v_final and final_sha256 = repeat('cd', 32) from engagement_letters where id = l)
     and (select signed_at = now() and typed_name = 'Dayo Client' and ip = '203.0.113.9' and ua = 'UA' and signature_path like '%/signature-' || s || '.png'
          from engagement_letter_signers where id = s), 'sign_complete: the signature recorded';
  assert exists (select 1 from net._requests where body = jsonb_build_object('action', 'practice_mail', 'kind', 'letter_done', 'id', l)), 'sign_complete: both told';
  perform tests.as_service();
  v_done := public.svc_practice_mail('letter_done', l);
  assert v_done->>'to' = 'dayo@client.example.test' and v_done->>'cc' = 'bisi.partner@firm.example.test' and v_done->>'from_name' = 'Letter Partners'
     and v_done->>'link' ~ '/sign/es_[0-9a-f]{48}$' and not (v_done->>'white_label')::boolean, 'sign_complete: the signed-letter email';
  -- Signed once: the new link opens the signed copy; nothing more can be done with it.
  tok := substring(v_done->>'link' from 'es_[0-9a-f]{48}$');
  r := public.svc_sign_open(tok, '203.0.113.9', 'UA');
  assert (r->>'ok')::boolean and r->>'status' = 'completed' and r->>'doc_path' = v_final, 'sign_complete: the signed copy';
  assert public.svc_sign_code(tok, '203.0.113.9', 'UA')->>'reason' = 'signed' and public.svc_sign_verify(tok, '000000', '203.0.113.9', 'UA')->>'reason' = 'signed'
     and public.svc_sign_complete(tok, '{}')->>'reason' = 'signed', 'sign_complete: once';
  perform tests.as_postgres();
  perform tests.remember('l_done', l);
  -- A completed letter is the record: it cannot be voided or replaced by an upload.
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_letter_void(%L, 'Wrong client entirely')$q$, l), '%stays on record%');
  perform tests.throws(format($q$select public.practice_letter_upload_signed(%L, jsonb_build_object('path', 'practice/%s/letters/%s/signed.pdf', 'sha256', repeat('ef', 32)))$q$, l, pr, l),
    '%signed already%');
  perform tests.as_postgres();
  perform tests.throws(format($q$update engagement_letters set status = 'void', void_reason = 'x' where id = %L$q$, l), '%closed%');
end $$;

-- test: upload_signed_copy
-- A signed copy uploaded instead: from a draft (the letter is that file) or from a letter out for signing (its link stops).
do $$
declare pr uuid := tests.id('pr'); l2 uuid := tests.id('l2'); r jsonb; tok text;
begin
  perform tests.as_user(tests.id('manager'));
  perform tests.throws(format($q$select public.practice_letter_upload_signed(%L, jsonb_build_object('path', 'practice/%s/letters/%s/signed.pdf', 'sha256', repeat('ef', 32)))$q$, l2, pr, l2),
    '%partner%');
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_letter_upload_signed(%L, jsonb_build_object('path', 'practice/%s/letters/other/signed.pdf', 'sha256', repeat('ef', 32)))$q$, l2, pr),
    '%letter''s folder%');
  perform tests.throws(format($q$select public.practice_letter_upload_signed(%L, jsonb_build_object('path', 'practice/%s/letters/%s/signed.pdf', 'sha256', 'nope'))$q$, l2, pr, l2),
    '%SHA-256%');
  assert public.practice_letter_upload_signed(l2, jsonb_build_object('path', 'practice/' || pr || '/letters/' || l2 || '/signed.pdf', 'sha256', repeat('ef', 32)))->>'status' = 'uploaded',
    'upload_signed_copy';
  perform tests.as_postgres();
  assert (select status = 'uploaded' and source = 'signed_upload' and doc_path = final_path and final_path = 'practice/' || pr || '/letters/' || l2 || '/signed.pdf'
            and final_sha256 = repeat('ef', 32) and doc_sha256 = final_sha256 from engagement_letters where id = l2), 'upload_signed_copy: the file is the letter';
  assert (select array_agg(kind order by id) from engagement_letter_events where letter_id = l2) = '{drafted,uploaded}', 'upload_signed_copy: event';
  -- From a letter out for signing: the link stops working.
  perform tests.as_service();
  tok := substring(public.svc_practice_mail('letter_sign', tests.id('s'))->>'link' from 'es_[0-9a-f]{48}$');
  assert (public.svc_sign_open(tok, '203.0.113.9', 'UA')->>'ok')::boolean, 'upload_signed_copy: the link works before';
  perform tests.as_user(tests.id('partner'));
  r := public.practice_letter_upload_signed(tests.id('l'), jsonb_build_object('path', 'practice/' || pr || '/letters/' || tests.id('l') || '/signed.pdf', 'sha256', repeat('ef', 32)));
  assert r->>'status' = 'uploaded' and r->>'source' = 'template' and r->>'doc_sha256' = repeat('ab', 32), 'upload_signed_copy: the rendered letter kept';
  perform tests.as_service();
  assert public.svc_sign_open(tok, '203.0.113.9', 'UA')->>'reason' = 'closed' and public.svc_sign_code(tok, '203.0.113.9', 'UA')->>'reason' = 'closed'
     and public.svc_practice_mail('letter_sign', tests.id('s')) is null, 'upload_signed_copy: the link stops';
  perform tests.as_postgres();
end $$;

-- test: letter_void
-- A partner voids a letter that is not signed by both sides, with a reason; its link then says so.
do $$
declare pr uuid := tests.id('pr'); l uuid; s uuid; tok text; r jsonb;
begin
  perform tests.as_user(tests.id('partner'));
  l := public.practice_letter_draft(tests.id('i'), '{}')->>'id';
  perform tests.as_service();
  perform public.svc_letter_frozen(l, jsonb_build_object('doc_path', 'practice/' || pr || '/letters/' || l || '/letter.pdf', 'doc_sha256', repeat('ab', 32),
    'by_user', tests.id('partner2')));
  perform tests.as_user(tests.id('partner'));
  s := public.practice_letter_send(l, '{"name":"Dayo Client","email":"dayo@client.example.test"}')->'signers'->0->>'id';
  perform tests.as_service();
  tok := substring(public.svc_practice_mail('letter_sign', s)->>'link' from 'es_[0-9a-f]{48}$');
  perform tests.as_user(tests.id('manager'));
  perform tests.throws(format($q$select public.practice_letter_void(%L, 'Fees were wrong')$q$, l), '%partner%');
  perform tests.as_user(tests.id('partner'));
  perform tests.throws(format($q$select public.practice_letter_void(%L, 'no')$q$, l), '%reason%');
  r := public.practice_letter_void(l, '  Fees were wrong  ');
  assert r->>'status' = 'void' and r->>'void_reason' = 'Fees were wrong', 'letter_void';
  perform tests.throws(format($q$select public.practice_letter_void(%L, 'Fees were wrong')$q$, l), '%void already%');
  perform tests.throws(format($q$select public.practice_letter_send(%L, '{"name":"Dayo Client","email":"dayo@client.example.test"}')$q$, l), '%void%');
  perform tests.as_service();
  assert public.svc_sign_open(tok, '203.0.113.9', 'UA')->>'reason' = 'void' and public.svc_sign_code(tok, '203.0.113.9', 'UA')->>'reason' = 'void'
     and public.svc_sign_verify(tok, '000000', '203.0.113.9', 'UA')->>'reason' = 'void', 'letter_void: the link says so';
  assert public.svc_practice_mail('letter_sign', s) is null, 'letter_void: no more links';
  perform tests.as_postgres();
  assert (select signed_at is null from engagement_letter_signers where id = s) and (select kind from engagement_letter_events where letter_id = l order by id desc limit 1) = 'voided'
     and (select detail->>'reason' from engagement_letter_events where letter_id = l and kind = 'voided') = 'Fees were wrong', 'letter_void: event';
  perform tests.throws(format($q$update engagement_letters set status = 'draft' where id = %L$q$, l), '%closed%');
  -- A draft may be voided too.
  perform tests.as_user(tests.id('partner'));
  assert public.practice_letter_void(tests.id('u_letter'), 'Not going ahead')->>'status' = 'void', 'letter_void: a draft';
  perform tests.as_postgres();
end $$;

-- test: letter_events_logged
-- A letter for an existing client: each step is in the business's activity log too, with no link, code or fingerprint.
do $$
declare pr uuid := tests.id('pr'); o uuid; c uuid; x uuid; l uuid;
begin
  o := tests.org(tests.user('logged.owner@example.test', 'Lola Owner'), 'Lola Bakes Ltd');
  c := tests.involved_client(pr, o);
  x := (select intake_id from practice_clients where id = c);
  perform tests.as_user(tests.id('partner'));
  perform public.practice_intake_save(pr, jsonb_build_object('id', x, 'risk_rating', 'low'));
  perform public.practice_conflict_run(x);
  perform tests.as_postgres();
  l := tests.completed_letter(x);
  assert (select client_id = c and status = 'completed' and variant = 'involved' from engagement_letters where id = l), 'letter_events_logged: the client''s letter';
  assert (select array_agg(action order by id) from activity_log where org_id = o and action like 'letter_%')
         = '{letter_drafted,letter_partner_signed,letter_sent,letter_signed}', 'letter_events_logged';
  assert (select bool_and(source = 'event' and practice_id = pr and after->>'letter_id' = l::text and label like 'Engagement letter%')
          from activity_log where org_id = o and action like 'letter_%'), 'letter_events_logged: the practice''s entries';
  assert not exists (select 1 from activity_log where org_id = o and (after::text ~ 'es_[0-9a-f]{48}' or after::text ~ '[0-9a-f]{64}' or after::text ~ '\m[0-9]{6}\M')),
    'letter_events_logged: no link, code or fingerprint';
end $$;

-- test: completed_letter_helper
-- tests.completed_letter: a full-mandate intake's letter, signed by both sides, in the firm's name only.
do $$
declare l uuid; r jsonb;
begin
  l := tests.completed_letter(tests.id('f'));
  assert (select status = 'completed' and variant = 'full' and white_label and final_path is not null and final_sha256 ~ '^[0-9a-f]{64}$' and retention_years = 6
          from engagement_letters where id = l), 'completed_letter_helper';
  assert (select signed_at is not null and code_verified_at is not null from engagement_letter_signers where letter_id = l), 'completed_letter_helper: signed';
  perform tests.as_service();
  r := public.svc_practice_mail('letter_done', l);
  perform tests.as_postgres();
  assert (r->>'white_label')::boolean and r->>'from_name' = 'Letter Partners' and (r - 'link')::text not ilike '%counta%', 'completed_letter_helper: white label';
  perform tests.as_user(tests.id('manager'));
  assert public.practice_intake(tests.id('f'))->'letters' @> jsonb_build_array(jsonb_build_object('id', l, 'status', 'completed', 'variant', 'full')),
    'completed_letter_helper: listed';
  perform tests.as_postgres();
end $$;

-- test: events_kept
-- A letter's record of events is never changed.
do $$
declare l uuid := tests.id('l_done');
begin
  perform tests.throws(format($q$update engagement_letter_events set actor = 'Someone' where letter_id = %L$q$, l), '%cannot be changed%');
  perform tests.throws(format($q$delete from engagement_letter_events where letter_id = %L$q$, l), '%cannot be changed%');
  perform private.letter_event(l, 'opened', 'Dayo Client', null, null);
  perform tests.throws(format($q$select private.letter_event(%L, 'printed', 'x', null, null)$q$, l), '%kind%');
end $$;

-- test: otp_helpers
do $$
declare s uuid := tests.id('s'); r jsonb; t jsonb;
begin
  assert (private.token_new('es')->>'token') ~ '^es_[0-9a-f]{48}$' and private.token_new('es')->>'hash' ~ '^[0-9a-f]{64}$', 'otp_helpers: token';
  t := private.token_new('dc');
  assert t->>'token' ~ '^dc_[0-9a-f]{48}$' and t->>'hash' = private.sha256_hex(t->>'token') and private.token_new('dc')->>'token' <> t->>'token', 'otp_helpers: hashed, fresh';
  perform tests.throws($q$select private.token_new('ES!')$q$, '%prefix%');
  assert not (private.otp_send_ok((now() at time zone 'Africa/Lagos')::date, 5)->>'ok')::boolean
     and (private.otp_send_ok((now() at time zone 'Africa/Lagos')::date - 1, 5)->>'sends_today')::int = 1, 'otp_helpers: five sends a Lagos day';
  assert private.otp_send_ok((now() at time zone 'Africa/Lagos')::date, 4) = jsonb_build_object('ok', true, 'sends_day', (now() at time zone 'Africa/Lagos')::date, 'sends_today', 5)
     and private.otp_send_ok(null, null) = jsonb_build_object('ok', true, 'sends_day', (now() at time zone 'Africa/Lagos')::date, 'sends_today', 1)
     and private.otp_send_ok((now() at time zone 'Africa/Lagos')::date, 5) = '{"ok": false, "reason": "too_many_today"}', 'otp_helpers: counters';
  assert private.otp_check(s, '000000', 'x', now() + interval '1 minute', 0, 14, null)->>'reason' = 'wrong_code'
     and (private.otp_check(s, '000000', 'x', now() + interval '1 minute', 0, 14, null)->>'locked')::boolean, 'otp_helpers: fifteenth failure locks';
  r := private.otp_new(s);
  assert r->>'code' ~ '^[0-9]{6}$' and r->>'otp_hash' = private.sha256_hex(s::text || ':' || (r->>'code')) and (r->>'otp_expires')::timestamptz = now() + interval '10 minutes',
    'otp_helpers: a new code';
  assert private.otp_check(s, r->>'code', r->>'otp_hash', now() + interval '1 minute', 2, 3, null)
         = jsonb_build_object('ok', true, 'reason', null, 'otp_tries', 3, 'otp_failures', 3, 'locked', false, 'tries_left', 2), 'otp_helpers: right code';
  assert private.otp_check(s, ' ' || (r->>'code') || ' ', r->>'otp_hash', now() + interval '1 minute', 0, 0, null)->>'ok' = 'true', 'otp_helpers: spaces ignored';
  assert private.otp_check(s, '000000', 'x', now() + interval '1 minute', 1, 0, null)
         = jsonb_build_object('ok', false, 'reason', 'wrong_code', 'otp_tries', 2, 'otp_failures', 1, 'locked', false, 'tries_left', 3), 'otp_helpers: wrong code';
  assert private.otp_check(s, r->>'code', r->>'otp_hash', now() + interval '1 minute', 5, 5, null)->>'reason' = 'used_up'
     and private.otp_check(s, r->>'code', r->>'otp_hash', now() - interval '1 second', 0, 0, null)->>'reason' = 'expired'
     and private.otp_check(s, r->>'code', null, null, 0, 0, null)->>'reason' = 'expired'
     and private.otp_check(s, r->>'code', r->>'otp_hash', now() + interval '1 minute', 0, 0, now())->>'reason' = 'locked'
     and (private.otp_check(s, r->>'code', r->>'otp_hash', now() + interval '1 minute', 0, 15, null)->>'locked')::boolean
     and private.otp_check(s, r->>'code', r->>'otp_hash', now() + interval '1 minute', 0, 15, null)->>'reason' = 'locked', 'otp_helpers: refused before comparing';
  assert private.otp_check(s, r->>'code', r->>'otp_hash', now() + interval '1 minute', 5, 5, null)->>'otp_tries' = '5'
     and private.otp_check(s, r->>'code', r->>'otp_hash', now() + interval '1 minute', 5, 5, null)->>'otp_failures' = '5', 'otp_helpers: counters unchanged when refused';
  assert private.otp_check(gen_random_uuid(), r->>'code', r->>'otp_hash', now() + interval '1 minute', 0, 0, null)->>'reason' = 'wrong_code',
    'otp_helpers: a code is for its holder only';
end $$;

-- test: letters_go_with_their_records
-- Letters, signers and events go only with the records they belong to: a practice deleted once its due-diligence records
-- are past their retention date takes its templates and letters with it, signed ones included.
do $$
declare pr uuid := tests.id('pr'); l uuid := tests.id('l_done');
begin
  -- A template removed leaves the letters made from it, signed ones too, as they are (they hold their own copy).
  assert tests.error_of(format('delete from practice_letter_templates where id = (select template_id from engagement_letters where id = %L)', l)) is null,
    'letters_go_with_their_records: a template removed';
  assert (select template_id is null and status = 'completed' and blocks = private.letter_default_body() from engagement_letters where id = l),
    'letters_go_with_their_records: the signed letter unchanged';
  update practice_intakes set retain_until = current_date where practice_id = pr;
  assert tests.error_of(format('delete from practices where id = %L', pr)) is null, 'letters_go_with_their_records: the practice deleted';
  assert not exists (select 1 from engagement_letters where practice_id = pr) and not exists (select 1 from engagement_letter_events where letter_id = l)
     and not exists (select 1 from engagement_letter_signers where letter_id = l) and not exists (select 1 from practice_letter_templates where practice_id = pr),
    'letters_go_with_their_records: letters, signers, events and templates with it';
end $$;

-- test: letter_helpers_revoked
do $$
declare f text;
begin
  foreach f in array array['private.letter_fields()', 'private.letter_body_ok(jsonb)', 'private.letter_default_body()', 'private.letter_defaults()',
    'private.letter_event(uuid, text, text, text, text, jsonb)', 'private.practice_mail(text, uuid)', 'private.token_new(text)', 'private.otp_send_ok(date, integer)',
    'private.otp_new(uuid)', 'private.otp_check(uuid, text, text, timestamp with time zone, integer, integer, timestamp with time zone)',
    'private.letter_merge_ok(jsonb)', 'private.letter_require(uuid, boolean)', 'private.letter_json(engagement_letters)',
    'private.letter_template_ensure(uuid)', 'private.letter_template_json(practice_letter_templates)', 'private.letter_signer_by_token(text)',
    'private.engagement_letters_freeze()', 'private.engagement_letter_events_guard()',
    'private.letter_signer_state(engagement_letter_signers, engagement_letters)', 'private.letter_intake_ready(uuid)'] loop
    assert not has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute'), format('letter_helpers_revoked: %s', f);
  end loop;
  foreach f in array array['public.svc_letter_frozen(uuid, jsonb)', 'public.svc_sign_open(text, text, text)', 'public.svc_sign_code(text, text, text)',
    'public.svc_sign_verify(text, text, text, text)', 'public.svc_sign_complete(text, jsonb)', 'public.svc_practice_mail(text, uuid)'] loop
    assert not has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute')
       and has_function_privilege('service_role', f, 'execute'), format('letter_helpers_revoked: %s for the service only', f);
  end loop;
  foreach f in array array['public.practice_letter_templates(uuid)', 'public.practice_letter_template_save(uuid, jsonb)', 'public.practice_letter_draft(uuid, jsonb)',
    'public.practice_letter_save(uuid, jsonb)', 'public.practice_letter(uuid)', 'public.practice_letter_prepare(uuid)', 'public.practice_letter_send(uuid, jsonb)',
    'public.practice_letter_upload_signed(uuid, jsonb)', 'public.practice_letter_void(uuid, text)', 'public.practice_intake(uuid)'] loop
    assert has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute'), format('letter_helpers_revoked: %s for signed-in people', f);
  end loop;
  foreach f in array array['public.practice_letter_templates', 'public.engagement_letters', 'public.engagement_letter_signers', 'public.engagement_letter_events'] loop
    assert not has_table_privilege('authenticated', f, 'select') and not has_table_privilege('anon', f, 'select')
       and not has_table_privilege('authenticated', f, 'insert') and not has_table_privilege('authenticated', f, 'update')
       and (select relrowsecurity from pg_class where oid = f::regclass), format('letter_helpers_revoked: table %s', f);
  end loop;
  assert exists (select 1 from pg_trigger where tgrelid = 'public.engagement_letters'::regclass and tgname = 'engagement_letters_freeze'),
    'letter_helpers_revoked: the freeze trigger';
end $$;

rollback;
