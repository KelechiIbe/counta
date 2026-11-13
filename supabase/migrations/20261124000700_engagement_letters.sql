-- Practice management, part 7: engagement letters, the default letter, and the records of signing.
--
-- A practice keeps letter templates; a letter is drafted for a due-diligence intake, signed by a partner, sent to the
-- client and e-signed by them (or a copy signed on paper is uploaded). The rendering, the PDF, the signature page and the
-- completion certificate are the practice edge function's; this migration keeps the records and the rules.
--   practice_letter_templates   kind blocks (a body of blocks, below) or pdf (a file in practice/<pid>/letters/, signed as it
--                               stands). One default per practice; templates are archived, not deleted. The first read
--                               adds "Counta standard letter" (private.letter_default_body()) as the default. Partners
--                               change templates; partners and managers read them.
--   engagement_letters          one per letter: the intake (and its client link once there is one), full or involved
--                               variant (a full-mandate letter is white label: the client sees only the firm), the body
--                               and merge values copied from the template and the intake, the rendered file and its
--                               SHA-256, the signed file and its SHA-256, the years the firm keeps its files (at least 5),
--                               the partner's signature (name, time, IP, user agent). draft -> partner_signed -> sent ->
--                               completed, or uploaded (a signed copy), or void. Once the partner signs, what the letter
--                               says is frozen (engagement_letters_freeze); a completed, uploaded or void letter is closed.
--   engagement_letter_signers   the client's signer: an es_ link (only its SHA-256 kept, 14 days, replaced by each email),
--                               a 6-digit code emailed on request (only its SHA-256 kept, 10 minutes; 5 emails a Lagos
--                               day, 5 tries per code, locked after 15 wrong codes), the signature image, typed name, IP,
--                               user agent and time.
--   engagement_letter_events    what happened to a letter, when, by whom, from which IP and browser. Never changed.
-- A body is {version: 1, blocks: [{id, kind, level, text, variant?, optional?}]}: kind heading, clause, paragraph, list or
-- signature; level 1 to 4 (a heading 1., a clause 1.1, list items (a) and (i)); plain text (line breaks allowed, no HTML)
-- with merge fields {{field}}, sections {{#field}}...{{/field}} kept when the field is set, and references {{ref:id}} to
-- another numbered block; variant full or involved (or both, when null); optional names the field that keeps the block.
-- Numbers are never written into the text: the renderer numbers what remains after variants and optional blocks drop out.
-- engagement_letters.blocks holds such a body. Merge values are the fields of private.letter_fields() only.
-- Emails go in the firm's name through the messaging hook (private.practice_mail -> svc_practice_mail), which mints the
-- link or the code as the email is sent, so neither is ever stored or queued in the clear. The signing calls are the
-- service role's (svc_sign_*); a wrong code never raises, so the counts stay. Each step is recorded, and logged in the
-- client business's activity log when there is a business (without links, codes or fingerprints).
-- Letter files live directly in practice/<pid>/letters/<letter id>/ (template PDFs in practice/<pid>/letters/templates/),
-- one level, plain file names; like intake files they are for the practice's partners and managers only
-- (private.practice_file_ok, redefined here).

-- ---------------------------------------------------------------------------
-- 0. Letter files
-- ---------------------------------------------------------------------------
-- A file directly in one of the practice's letter folders, practice/<pid>/letters/<folder>/<name>: the folder a letter's id
-- or templates; the name letters, digits, dots, dashes and underscores, not starting with a dot and without "..".
-- At most 500 characters.
create or replace function private.letter_file_ok(p_path text, p_practice uuid, p_folder text) returns boolean
language sql immutable set search_path = public, private as $$
  select coalesce(length(p_path) <= 500 and p_path !~ '\.\.'
    and p_path ~ ('^practice/' || p_practice::text || '/letters/' || p_folder || '/[A-Za-z0-9_-][A-Za-z0-9._-]*$'), false)
$$;

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table public.practice_letter_templates (
  id uuid primary key default gen_random_uuid(),
  practice_id uuid not null references public.practices(id) on delete cascade,
  name text not null check (length(trim(name)) between 2 and 80),
  kind text not null default 'blocks' check (kind in ('blocks', 'pdf')),
  body jsonb,
  pdf_path text check (pdf_path is null or private.letter_file_ok(pdf_path, practice_id, 'templates')),
  is_default boolean not null default false,
  archived boolean not null default false,
  created_by uuid references public.practice_members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((kind = 'blocks' and jsonb_typeof(body) = 'object' and pdf_path is null) or (kind = 'pdf' and pdf_path is not null and body is null)),
  check (not (is_default and archived))
);
create unique index practice_letter_templates_default on public.practice_letter_templates(practice_id) where is_default;
create index practice_letter_templates_practice on public.practice_letter_templates(practice_id, archived, name);
create index practice_letter_templates_created_by on public.practice_letter_templates(created_by) where created_by is not null;
alter table public.practice_letter_templates enable row level security;
revoke all on public.practice_letter_templates from anon, authenticated;

create table public.engagement_letters (
  id uuid primary key default gen_random_uuid(),
  practice_id uuid not null references public.practices(id) on delete cascade,
  intake_id uuid not null references public.practice_intakes(id) on delete cascade,
  client_id uuid references public.practice_clients(id) on delete set null,
  template_id uuid references public.practice_letter_templates(id) on delete set null,
  variant text not null default 'involved' check (variant in ('full', 'involved')),
  source text not null default 'template' check (source in ('template', 'pdf', 'signed_upload')),
  status text not null default 'draft' check (status in ('draft', 'partner_signed', 'sent', 'completed', 'uploaded', 'void')),
  title text not null check (length(trim(title)) between 2 and 160),
  blocks jsonb,
  merge jsonb not null default '{}' check (jsonb_typeof(merge) = 'object'),
  -- The rendered letter in the letter's folder, or the template PDF a PDF letter is.
  doc_path text check (doc_path is null or private.letter_file_ok(doc_path, practice_id, id::text)
    or private.letter_file_ok(doc_path, practice_id, 'templates')),
  doc_sha256 text check (doc_sha256 ~ '^[0-9a-f]{64}$'),
  final_path text check (final_path is null or private.letter_file_ok(final_path, practice_id, id::text)),
  final_sha256 text check (final_sha256 ~ '^[0-9a-f]{64}$'),
  retention_years int not null default 6 check (retention_years >= 5),
  partner_id uuid references public.practice_members(id) on delete set null,
  partner_signature text check (length(partner_signature) <= 120),
  -- The signing partner's name and email as they were when they signed (the completion certificate's).
  partner_name text check (length(partner_name) <= 80),
  partner_email text check (length(partner_email) <= 254),
  partner_signed_at timestamptz,
  partner_ip text,
  partner_ua text,
  white_label boolean not null default false,
  void_reason text check (length(void_reason) <= 500),
  created_by uuid references public.practice_members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- White label exactly when the letter is the full-mandate one.
  check (white_label = (variant = 'full')),
  check (source <> 'pdf' or doc_path is not null),
  check (status not in ('partner_signed', 'sent', 'completed')
    or (doc_path is not null and doc_sha256 is not null and partner_signed_at is not null and partner_name is not null and partner_email is not null)),
  check (status not in ('completed', 'uploaded') or (final_path is not null and final_sha256 is not null)),
  check (status <> 'void' or void_reason is not null)
);
create index engagement_letters_intake on public.engagement_letters(intake_id, created_at desc);
create index engagement_letters_practice on public.engagement_letters(practice_id, status);
create index engagement_letters_client on public.engagement_letters(client_id) where client_id is not null;
create index engagement_letters_template on public.engagement_letters(template_id) where template_id is not null;
create index engagement_letters_partner on public.engagement_letters(partner_id) where partner_id is not null;
create index engagement_letters_created_by on public.engagement_letters(created_by) where created_by is not null;
alter table public.engagement_letters enable row level security;
revoke all on public.engagement_letters from anon, authenticated;

create table public.engagement_letter_signers (
  id uuid primary key default gen_random_uuid(),
  letter_id uuid not null references public.engagement_letters(id) on delete cascade,
  name text not null check (length(trim(name)) between 2 and 120),
  email text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and length(email) <= 254),
  title text check (length(title) <= 80),
  token_hash text,
  token_expires timestamptz,
  sends_today int not null default 0,
  sends_day date,
  otp_hash text,
  otp_expires timestamptz,
  otp_tries int not null default 0,
  otp_failures int not null default 0,
  locked_at timestamptz,
  code_verified_at timestamptz,
  signature_path text check (length(signature_path) <= 500),
  typed_name text check (length(typed_name) <= 120),
  ip text,
  ua text,
  signed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- One signer per letter: sending again replaces the signer's details and link.
create unique index engagement_letter_signers_letter on public.engagement_letter_signers(letter_id);
create unique index engagement_letter_signers_token on public.engagement_letter_signers(token_hash) where token_hash is not null;
alter table public.engagement_letter_signers enable row level security;
revoke all on public.engagement_letter_signers from anon, authenticated;

create table public.engagement_letter_events (
  id bigint generated always as identity primary key,
  letter_id uuid not null references public.engagement_letters(id) on delete cascade,
  at timestamptz not null default now(),
  kind text not null check (kind in ('drafted', 'partner_signed', 'sent', 'opened', 'code_sent', 'code_failed', 'signed', 'uploaded', 'voided')),
  actor text,
  ip text,
  ua text,
  detail jsonb not null default '{}'
);
create index engagement_letter_events_letter on public.engagement_letter_events(letter_id, id);
alter table public.engagement_letter_events enable row level security;
revoke all on public.engagement_letter_events from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Fields, defaults and what a letter may hold
-- ---------------------------------------------------------------------------
-- The merge fields of the draft letter (docs/superpowers/specs/2026-11-12-engagement-letter-template.md), in its order.
create or replace function private.letter_fields() returns text[]
language sql immutable set search_path = public, private as $$
  select array['letter.date', 'contact.title', 'contact.name', 'contact.salutation', 'client.name', 'client.address', 'client.name_upper',
    'client.reg_label', 'client.rc_number', 'client.description', 'engagement.title_upper', 'engagement.title_lower', 'engagement.start_date',
    'proposal.date', 'firm.name', 'firm.email', 'firm.phone', 'firm.city', 'fees.frequency', 'fees.amount', 'fees.amount_words', 'fees.deposit',
    'fees.deposit_words', 'fees.billing_day', 'fees.billing_period', 'fees.payment_days', 'fees.suspend_days', 'service.advisory',
    'service.bookkeeping', 'service.monthly', 'service.annual', 'service.other', 'service.other_text', 'service.days', 'partner.name',
    'partner.title', 'partner.email', 'team.assistant', 'conflicts.note', 'liability.cap_basis', 'retention.years', 'termination.notice_days',
    'termination.handover_days', 'arbitration.seat', 'signer.name', 'signer.title', 'signer.date', 'mode.full_mandate', 'signature.firm',
    'signature.client']
$$;

-- The values every new letter starts with; the liability cap is "whichever is lower" until the firm changes it.
create or replace function private.letter_defaults() returns jsonb
language sql immutable set search_path = public, private as $$
  select '{"liability.cap_basis":"lower","retention.years":6,"termination.notice_days":30,"termination.handover_days":14,"fees.payment_days":14,
    "fees.suspend_days":30,"fees.frequency":"monthly","fees.billing_day":1,"fees.billing_period":"month","service.days":10,"arbitration.seat":"Lagos",
    "contact.salutation":"Sir/Madam","client.reg_label":"RC"}'::jsonb
$$;

-- Why a body is not a letter Counta can keep, or null when it is. At most 200 KB, version 1, 1 to 600 blocks, each with an
-- id of its own (lower-case letters, digits, - and _, up to 40), a kind at its level as the renderer numbers it (a heading
-- 1., level 1; a clause 1.1, level 2; a list item (a), level 3, or (i), level 4; an unnumbered paragraph at levels 1 to 4,
-- its indent; a signature at level 1), and up to 4,000 characters of plain text (no HTML); a variant of full or involved,
-- or none; optional naming a field. Every {{field}}, {{#field}}
-- and {{/field}} names a field of the letter, sections close in order within their block, and every {{ref:id}} names a
-- numbered block (heading, clause or list item) of the letter. A signature block's text says whose: firm or client.
create or replace function private.letter_body_ok(p_body jsonb) returns text
language plpgsql immutable set search_path = public, private as $$
declare v_fields text[] := private.letter_fields(); v_ids text[]; v_numbered text[]; b jsonb; n int := 0;
  v_id text; v_kind text; v_text text; v_tag text; v_name text; v_stack text[];
begin
  if jsonb_typeof(p_body) is distinct from 'object' then return 'The letter is not in the expected form.'; end if;
  if octet_length(p_body::text) > 204800 then return 'The letter is too long: keep it under 200 KB.'; end if;
  if p_body - array['version', 'blocks'] <> '{}'::jsonb then return 'The letter has settings Counta does not know.'; end if;
  if p_body->'version' is distinct from '1'::jsonb then return 'The letter''s format version must be 1.'; end if;
  if jsonb_typeof(p_body->'blocks') is distinct from 'array' or jsonb_array_length(p_body->'blocks') not between 1 and 600 then
    return 'A letter has 1 to 600 paragraphs.';
  end if;
  select array_agg(x->>'id'), coalesce(array_agg(x->>'id') filter (where x->>'kind' in ('heading', 'clause', 'list')), '{}')
    into v_ids, v_numbered
  from jsonb_array_elements(p_body->'blocks') x;
  for b in select x from jsonb_array_elements(p_body->'blocks') x loop
    n := n + 1;
    if jsonb_typeof(b) is distinct from 'object' then return format('Paragraph %s is not in the expected form.', n); end if;
    v_id := case when jsonb_typeof(b->'id') = 'string' then b->>'id' end;
    if v_id is null or v_id !~ '^[a-z0-9_-]{1,40}$' then
      return format('Paragraph %s needs an id of 1 to 40 lower-case letters, digits, dashes or underscores.', n);
    end if;
    if (select count(*) from unnest(v_ids) x where x = v_id) > 1 then return format('Two paragraphs have the id %s.', v_id); end if;
    if b - array['id', 'kind', 'level', 'text', 'variant', 'optional'] <> '{}'::jsonb then
      return format('Paragraph %s has settings Counta does not know.', v_id);
    end if;
    v_kind := case when jsonb_typeof(b->'kind') = 'string' then b->>'kind' end;
    if v_kind is null or v_kind not in ('heading', 'clause', 'paragraph', 'list', 'signature') then
      return format('Paragraph %s is not a heading, clause, paragraph, list item or signature.', v_id);
    end if;
    if jsonb_typeof(b->'level') is distinct from 'number' or b->>'level' !~ '^[1-4]$' then
      return format('Paragraph %s needs a level from 1 to 4.', v_id);
    end if;
    if not (case v_kind when 'heading' then b->>'level' = '1' when 'clause' then b->>'level' = '2' when 'list' then b->>'level' in ('3', '4')
                        when 'signature' then b->>'level' = '1' else true end) then
      return format('Paragraph %s is a %s at level %s: a heading is at level 1, a clause at level 2, a list item at level 3 or 4 and a signature at level 1.',
        v_id, v_kind, b->>'level');
    end if;
    v_text := case when jsonb_typeof(b->'text') = 'string' then b->>'text' end;
    if v_text is null or btrim(v_text) = '' then return format('Paragraph %s has no text.', v_id); end if;
    if length(v_text) > 4000 then return format('Paragraph %s is longer than 4,000 characters.', v_id); end if;
    if v_text ~ '<[A-Za-z/!]' then return format('Paragraph %s holds HTML: write plain text.', v_id); end if;
    if coalesce(jsonb_typeof(b->'variant'), 'null') <> 'null' and (jsonb_typeof(b->'variant') <> 'string' or b->>'variant' not in ('full', 'involved')) then
      return format('Paragraph %s is for the full mandate letter, the involved letter, or both.', v_id);
    end if;
    if coalesce(jsonb_typeof(b->'optional'), 'null') <> 'null' and (jsonb_typeof(b->'optional') <> 'string' or not (b->>'optional' = any (v_fields))) then
      return format('Paragraph %s depends on a field the letter does not have: %s.', v_id, b->>'optional');
    end if;
    if v_kind = 'signature' then
      if v_text not in ('firm', 'client') then return format('Signature %s is for the firm or the client.', v_id); end if;
      continue;
    end if;
    v_stack := '{}';
    for v_tag in select m[1] from regexp_matches(v_text, '\{\{([^{}]*)\}\}', 'g') m loop
      if v_tag like 'ref:%' then
        if not (substr(v_tag, 5) = any (v_numbered)) then
          return format('Paragraph %s refers to %s, which is not a numbered paragraph of this letter.', v_id, substr(v_tag, 5));
        end if;
      elsif left(v_tag, 1) in ('#', '/') then
        v_name := substr(v_tag, 2);
        if not (v_name = any (v_fields)) then return format('Paragraph %s uses an unknown field: %s.', v_id, v_name); end if;
        if left(v_tag, 1) = '#' then
          v_stack := v_stack || v_name;
        elsif cardinality(v_stack) = 0 or v_stack[cardinality(v_stack)] <> v_name then
          return format('Paragraph %s closes {{/%s}} without opening it.', v_id, v_name);
        else
          v_stack := v_stack[1:cardinality(v_stack) - 1];
        end if;
      elsif not (v_tag = any (v_fields)) then
        return format('Paragraph %s uses an unknown field: %s.', v_id, v_tag);
      end if;
    end loop;
    if cardinality(v_stack) > 0 then return format('Paragraph %s opens {{#%s}} without closing it.', v_id, v_stack[cardinality(v_stack)]); end if;
    if regexp_replace(v_text, '\{\{[^{}]*\}\}', '', 'g') ~ '\{\{|\}\}' then return format('Paragraph %s has unmatched braces.', v_id); end if;
  end loop;
  return null;
end $$;

-- A number of years to keep the letter's files, given as a JSON number or text: null when not given, else a whole number of
-- 5 or more (fewer is refused as the table's check would refuse it).
create or replace function private.letter_years(p jsonb) returns int
language plpgsql immutable set search_path = public, private as $$
declare v int;
begin
  if p is null or jsonb_typeof(p) = 'null' then return null; end if;
  if jsonb_typeof(p) not in ('number', 'string') or (p #>> '{}') !~ '^\s*[0-9]{1,3}\s*$' then
    raise exception 'Keep the letter''s files for a whole number of years, 5 or more.' using errcode = '22023';
  end if;
  v := trim(p #>> '{}')::int;
  if v < 5 then raise exception 'Keep the letter''s files for at least 5 years.' using errcode = '23514'; end if;
  return v;
end $$;

-- Why merge values are not a letter's, or null when they are: fields of the letter only, each text (plain, up to 2,000
-- characters, no HTML and no {{ }}), a number, yes or no, or nothing.
create or replace function private.letter_merge_ok(p_merge jsonb) returns text
language plpgsql immutable set search_path = public, private as $$
declare e record;
begin
  if jsonb_typeof(p_merge) is distinct from 'object' then return 'The merge values must be an object of fields.'; end if;
  for e in select key, value from jsonb_each(p_merge) loop
    if not (e.key = any (private.letter_fields())) then return format('%s is not a field of the letter.', e.key); end if;
    if jsonb_typeof(e.value) not in ('string', 'number', 'boolean', 'null') then
      return format('The value of %s must be text, a number, or yes or no.', e.key);
    end if;
    if jsonb_typeof(e.value) = 'string' and (length(e.value #>> '{}') > 2000 or (e.value #>> '{}') ~ '<[A-Za-z/!]|\{\{|\}\}') then
      return format('The value of %s must be plain text of up to 2,000 characters, without HTML or {{ }}.', e.key);
    end if;
  end loop;
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- 3. The default letter
-- ---------------------------------------------------------------------------
-- The draft letter, word for word, one block per paragraph, with its clause numbers taken out: 1. headings (level 1), 1.1
-- clauses (level 2), (a) list items (level 3), (i) list items (level 4); unnumbered paragraphs inside a section are at
-- level 2, the opening and the close at level 1. A paragraph wholly inside {{#field}}...{{/field}} is optional on that
-- field; the {{#mode.full_mandate}} paragraph (2.2) is the full variant; sections inside a sentence stay in the text.
-- Clause 2.1(d) is there only with bookkeeping. "paragraph 1.1", "1.1(b)", "6.3" and "13" refer to their blocks by id.
create or replace function private.letter_default_body() returns jsonb
language sql immutable set search_path = public, private as $$
  select jsonb_build_object('version', 1, 'blocks', jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id', b.id, 'kind', b.kind, 'level', b.level,
      'text', b.text, 'variant', b.variant, 'optional', b.optional)) order by b.n))
  from (values
    (1, 'date', 'paragraph', 1, '{{letter.date}}', null::text, null::text),
    (2, 'addressee', 'paragraph', 1, E'{{contact.title}}\n{{client.name}}\n{{client.address}}', null, null),
    (3, 'attention', 'paragraph', 1, 'Attention: {{contact.name}}', null, null),
    (4, 'salutation', 'paragraph', 1, 'Dear {{contact.salutation}},', null, null),
    (5, 'subject', 'paragraph', 1, 'LETTER OF ENGAGEMENT FOR THE PROVISION OF {{engagement.title_upper}} TO {{client.name_upper}}', null, null),
    (6, 'introduction', 'paragraph', 1, 'We write further to our recent discussions{{#proposal.date}} and our proposal dated {{proposal.date}}{{/proposal.date}}. This letter sets out the terms on which {{firm.name}} ("we", "us" or "our") will act for {{client.name}} ({{client.reg_label}} {{client.rc_number}}) ("you" or the "Client").', null, null),
    (7, 'understanding', 'paragraph', 1, 'We understand that the Client {{client.description}} and requires {{engagement.title_lower}} in Nigeria on an ongoing basis.', null, null),

    (8, 'scope', 'heading', 1, 'Scope of Engagement', null, null),
    (9, 'scope_services', 'clause', 2, 'This engagement runs on a {{fees.frequency}} basis. Our role will include the services below.', null, null),
    (10, 'svc_advisory', 'list', 3, 'Tax review and advisory. We will review the Client''s current and recent commercial arrangements and contracts, assess the tax issues they raise, and issue a memorandum of advice covering:', null, 'service.advisory'),
    (11, 'svc_advisory_structure', 'list', 4, 'the most tax-efficient structure for the Client''s operations and transactions, taking account of any related entities;', null, 'service.advisory'),
    (12, 'svc_advisory_transaction_taxes', 'list', 4, 'the transaction taxes (value added tax (VAT), withholding tax (WHT), stamp duties and similar taxes) that apply to each arrangement, and lawful measures to manage them; and', null, 'service.advisory'),
    (13, 'svc_advisory_obligations', 'list', 4, 'the Client''s tax obligations as a business operating in Nigeria, including income tax, monthly VAT and WHT, employee taxes, pensions and other statutory contributions, and transfer pricing where relevant.', null, 'service.advisory'),
    (14, 'svc_bookkeeping', 'list', 3, 'Accounting setup, tax registrations and bookkeeping. We will set up and maintain an accounting system for the Client to support bookkeeping, financial reporting and internal controls. Under this workstream we will:', null, 'service.bookkeeping'),
    (15, 'svc_bookkeeping_invoices', 'list', 4, 'issue and track invoices for payment;', null, 'service.bookkeeping'),
    (16, 'svc_bookkeeping_supplier_invoices', 'list', 4, 'review supplier invoices for settlement;', null, 'service.bookkeeping'),
    (17, 'svc_bookkeeping_reconciliation', 'list', 4, 'record transactions in the accounting system and reconcile the books each month;', null, 'service.bookkeeping'),
    (18, 'svc_bookkeeping_reports', 'list', 4, 'provide reports on financial performance and business health;', null, 'service.bookkeeping'),
    (19, 'svc_bookkeeping_controls', 'list', 4, 'recommend internal control measures; and', null, 'service.bookkeeping'),
    (20, 'svc_bookkeeping_registration', 'list', 4, 'register the Client for tax with the Nigeria Revenue Service (NRS) and the relevant State Internal Revenue Service (SIRS), and obtain its Tax ID, as required to file returns and obtain a Tax Clearance Certificate.', null, 'service.bookkeeping'),
    (21, 'svc_monthly', 'list', 3, 'Monthly tax compliance (VAT, WHT and PAYE). For each monthly filing we will:', null, 'service.monthly'),
    (22, 'svc_monthly_review', 'list', 4, 'review the relevant information from the Client''s accounting records;', null, 'service.monthly'),
    (23, 'svc_monthly_prepare', 'list', 4, 'prepare the returns and supporting schedules;', null, 'service.monthly'),
    (24, 'svc_monthly_approval', 'list', 4, 'send the draft returns and our observations to you for review and approval;', null, 'service.monthly'),
    (25, 'svc_monthly_advice', 'list', 4, 'discuss the returns with you and advise on the tax payable, if any; and', null, 'service.monthly'),
    (26, 'svc_monthly_filing', 'list', 4, 'file the approved returns and send you copies of the filed returns for your records.', null, 'service.monthly'),
    (27, 'svc_annual', 'list', 3, 'Annual income tax compliance. For each year of assessment we will:', null, 'service.annual'),
    (28, 'svc_annual_auditors', 'list', 4, 'liaise with the Client''s auditors on the preparation of audited financial statements, where required;', null, 'service.annual'),
    (29, 'svc_annual_computations', 'list', 4, 'review the audit work papers and prepare the income tax computations, including capital allowance schedules and supporting documents;', null, 'service.annual'),
    (30, 'svc_annual_approval', 'list', 4, 'send the computations and our observations to you for review and approval;', null, 'service.annual'),
    (31, 'svc_annual_filing', 'list', 4, 'file the approved returns on the NRS online tax portal (currently Rev360) or the portal of the relevant SIRS; and', null, 'service.annual'),
    (32, 'svc_annual_copies', 'list', 4, 'send you copies of the filed documents for your records.', null, 'service.annual'),
    (33, 'svc_other', 'list', 3, '{{service.other_text}}', null, 'service.other'),
    (34, 'scope_exclusions', 'clause', 2, 'Exclusions. Our services do not include statutory audit, representation in a tax audit or investigation, payroll processing, physical inventory counts, forecasting, or system implementation or migration beyond the initial accounting setup, or any service not listed in paragraph {{ref:scope_services}}. If the Client needs any of these, we will agree the scope and fees separately in writing.', null, null),
    (35, 'scope_service_levels', 'clause', 2, 'Service levels. We will deliver monthly work (including reports, reconciliations and statutory returns) within {{service.days}} days of receiving all the documents and information we need. Annual work will be completed within the deadlines set by the relevant tax authorities, provided you and your auditors give us information in good time.', null, null),

    (36, 'authority', 'heading', 1, 'Our Authority to Act', null, null),
    (37, 'authority_appointment', 'clause', 2, 'By signing this letter, the Client appoints us as its tax agent and authorises us, for the purposes of this engagement, to:', null, null),
    (38, 'authority_tax_authorities', 'list', 3, 'correspond with, file returns with, and receive notices from the NRS and any SIRS on the Client''s behalf;', null, null),
    (39, 'authority_registration', 'list', 3, 'register the Client for any tax it is required to register for;', null, null),
    (40, 'authority_books', 'list', 3, 'keep the Client''s books and records in an accounting system we select, maintained in the Client''s name; and', null, null),
    (41, 'authority_invoices', 'list', 3, 'issue invoices, receipts and credit notes in the Client''s name, where paragraph {{ref:svc_bookkeeping}} applies.', null, 'service.bookkeeping'),
    (42, 'authority_full_mandate', 'clause', 2, 'Full mandate. The Client further authorises us to set up and administer its accounting records and related systems without the Client''s day-to-day involvement, and to act as administrator of those systems on the Client''s behalf. This includes verifying the Client''s identity with service providers using information and documents the Client gives us for that purpose. This authority does not extend to opening any payment or collection account in the Client''s name, or to moving the Client''s funds, unless a director of the Client separately authorises it in writing.', 'full', null),
    (43, 'authority_access', 'clause', 2, 'Access and credentials. The Client may give us access to its tax portal accounts and view-only access to its bank accounts. We will keep any credentials secure and use them only for this engagement. The Client remains the owner of those accounts and should change the credentials when the engagement ends.', null, null),
    (44, 'authority_duration', 'clause', 2, 'This authority continues until the engagement ends under paragraph {{ref:term}} or the Client withdraws it in writing.', null, null),

    (45, 'responsibilities', 'heading', 1, 'Your Responsibilities', null, null),
    (46, 'resp_client', 'clause', 2, 'The Client is responsible for:', null, null),
    (47, 'resp_information', 'list', 3, 'giving us complete and accurate information and documents, in good time;', null, null),
    (48, 'resp_decisions', 'list', 3, 'the management decisions of its business, including whether to accept our advice;', null, null),
    (49, 'resp_approval', 'list', 3, 'reviewing and approving returns and computations before we file them, except where it has asked us in writing to file without prior review;', null, null),
    (50, 'resp_tax_payments', 'list', 3, 'paying taxes when due, unless we have agreed in writing to arrange payment from funds the Client provides;', null, null),
    (51, 'resp_records', 'list', 3, 'keeping original records and documents as required by law; and', null, null),
    (52, 'resp_changes', 'list', 3, 'telling us promptly of any change in its business, ownership, directors or contact details.', null, null),
    (53, 'resp_reliance', 'clause', 2, 'We will rely on the information the Client gives us. We are not responsible for errors or delays that result from information that is incomplete, inaccurate or late.', null, null),

    (54, 'team', 'heading', 1, 'Our Team', null, null),
    (55, 'team_core', 'clause', 2, 'We will set up a core team with relevant experience for this engagement, led by the engagement partner named below. Other members and resources of the firm will be available as needed.', null, null),
    (56, 'team_partner', 'clause', 2, '{{partner.name}}, {{partner.title}}, has overall responsibility for this engagement{{#team.assistant}} and will be assisted by {{team.assistant}}{{/team.assistant}}.', null, null),
    (57, 'team_contact', 'clause', 2, 'If you have difficulty reaching our team, please email {{firm.email}}{{#firm.phone}} or call our office on {{firm.phone}} during business hours{{/firm.phone}}.', null, null),
    (58, 'team_designated_contact', 'clause', 2, 'We understand that {{contact.name}} (the "Designated Client Contact") is authorised to instruct us on this engagement and to approve costs within its scope. We will assume this remains the case until you tell us otherwise. Where we act on instructions from other people at the Client who have taken part in correspondence with the Designated Client Contact, we will make sure the Designated Client Contact knows.', null, null),

    (59, 'fees', 'heading', 1, 'Professional Fees and Expenses', null, null),
    (60, 'fees_amount', 'clause', 2, 'Our fee for this engagement is a consolidated {{fees.frequency}} fee of {{fees.amount}} ({{fees.amount_words}}), covering the scope of work in paragraph {{ref:scope_services}}.', null, null),
    (61, 'fees_assumptions', 'clause', 2, 'Assumptions. Our fee assumes that:', null, null),
    (62, 'fees_assume_scope', 'list', 3, 'the scope of work will not change materially during the engagement; if we are asked to do work outside it, we will tell you and obtain your written approval, and that work will be charged separately;', null, null),
    (63, 'fees_assume_instructions', 'list', 3, 'we will receive timely and clear instructions, and the documents and information we ask for within a reasonable time;', null, null),
    (64, 'fees_assume_meetings', 'list', 3, 'instructions will be given by email and video or telephone calls, and we will not be required to attend in-person meetings; travel outside {{firm.city}} at your request will be charged in addition to our fee; and', null, null),
    (65, 'fees_assume_expenses', 'list', 3, 'out-of-pocket expenses and administrative costs are charged separately, at cost.', null, null),
    (66, 'fees_assumptions_wrong', 'paragraph', 2, 'If any of these assumptions proves wrong, either of us should tell the other promptly.', null, null),
    (67, 'fees_deposit', 'clause', 2, 'Expenses. To avoid consulting you on every small out-of-pocket expense (such as printing, courier charges and statutory filing fees), we ask for a deposit on account of {{fees.deposit}} ({{fees.deposit_words}}). When the deposit is used up we will send a detailed statement of expenses, supported by receipts where available, and may ask for a further deposit. We will obtain your approval before incurring any large individual expense.', null, 'fees.deposit'),
    (68, 'fees_taxes', 'clause', 2, 'Taxes. Our fees are exclusive of VAT, which we will add to our invoices at the applicable rate (currently 7.5%). Where the Client deducts withholding tax from our fees, it should remit the tax and give us the credit note or receipt promptly.', null, null),
    (69, 'fees_billing', 'clause', 2, 'Billing and payment. We will invoice our fee{{#fees.deposit}} and the expense deposit{{/fees.deposit}} when this letter is signed, and then on day {{fees.billing_day}} of each {{fees.billing_period}}. Invoices are payable within {{fees.payment_days}} days. We may pause work on the engagement while any invoice remains unpaid {{fees.suspend_days}} days after its due date.', null, null),

    (70, 'confidentiality', 'heading', 1, 'Confidentiality', null, null),
    (71, 'conf_our_duty', 'clause', 2, 'We will keep confidential all information about the Client''s affairs that we receive in this engagement, except where the Client authorises disclosure, where the law or a regulator requires it, or where the information is already public. We may also disclose information to our professional indemnity insurers and professional advisers on a confidential basis.', null, null),
    (72, 'conf_publicity', 'clause', 2, 'We may say that we have acted for the Client on a matter that is already public, and identify the Client by name or logo and the general nature of our work. Where the matter is not public, we will only say the Client is our client with its consent.', null, null),
    (73, 'conf_other_clients', 'clause', 2, 'We also owe a duty of confidentiality to our other clients. If we hold confidential information about another client that may be relevant to you, we will not disclose it to you or use it for your benefit, and we will treat your information the same way. You agree that we may act for another client whose interests are not adverse to yours without your consent, provided we keep your information confidential, using a separate team where appropriate.', null, null),

    (74, 'conflicts', 'heading', 1, 'Conflicts of Interest', null, null),
    (75, 'conflicts_rules', 'clause', 2, 'Professional rules of ethics that govern accountants and tax practitioners prohibit us from acting where there is a conflict of interest, or a significant risk of one.', null, null),
    (76, 'conflicts_definition', 'clause', 2, 'A conflict of interest arises where:', null, null),
    (77, 'conflicts_adverse', 'list', 3, 'the work we are asked to do for one client is against the interests of another client, for example advising on a claim against that other client; or', null, null),
    (78, 'conflicts_information', 'list', 3, 'as described in paragraph {{ref:conf_other_clients}}, we hold confidential information from acting for one client that is relevant to a matter we are asked to handle for another.', null, null),
    (79, 'conflicts_checks', 'clause', 2, 'We check for actual and potential conflicts before accepting new instructions. If we identify a potential conflict, we will try to resolve it with the parties concerned, subject to our duty of confidentiality.', null, null),
    (80, 'conflicts_confirmation', 'clause', 2, 'We have carried out a conflicts check and confirm that no conflict of interest arises from this engagement{{#conflicts.note}}, {{conflicts.note}}{{/conflicts.note}}.', null, null),

    (81, 'aml', 'heading', 1, 'Anti-Money Laundering', null, null),
    (82, 'aml_identification', 'clause', 2, 'As a designated non-financial business under the Money Laundering (Prevention and Prohibition) Act 2022, we must identify and verify our clients and their beneficial owners before and during an engagement, and keep those records for at least five years after the engagement ends. The Client agrees to give us the information and documents we need for this.', null, null),
    (83, 'aml_reporting', 'clause', 2, 'The law may require us to report a suspicion of money laundering or terrorist financing to the authorities without telling the Client. A report made in good faith is not a breach of our duty of confidentiality, and we will not be liable for any loss that results from it.', null, null),

    (84, 'personal_data', 'heading', 1, 'Personal Data', null, null),
    (85, 'data_processing', 'clause', 2, 'In this engagement we will process personal data about the Client''s directors, shareholders, employees, customers and suppliers, such as names, contact details and identification and transaction information. We will process it in line with the Nigeria Data Protection Act 2023, only for the purposes of this engagement and to meet our legal and professional obligations.', null, null),
    (86, 'data_security', 'clause', 2, 'We will keep the personal data secure, limit access to the people who need it, and use service providers (including our accounting software providers) only under terms that protect it. Where data is stored or processed outside Nigeria, we will make sure it is protected as the Act requires.', null, null),
    (87, 'data_breach', 'clause', 2, 'We will tell the Client without undue delay if we become aware of a breach affecting personal data we hold for it, and will help it meet its own obligations under the Act. The Client confirms it has the right to give us the personal data it shares with us.', null, null),

    (88, 'liability', 'heading', 1, 'Limitation of Liability', null, null),
    (89, 'liability_cap', 'clause', 2, 'We will not be liable for any loss, damage, cost or expense suffered by the Client or any other party in connection with our information, advice or other work under this engagement, unless a Nigerian court finally establishes that it arose from our negligence. In that case our total liability is limited to the amount of our professional indemnity insurance cover or the total fees paid to us under this engagement, whichever is {{liability.cap_basis}}.', null, null),
    (90, 'liability_third_parties', 'clause', 2, 'Our advice is for the Client''s use only. A third party may rely on it only with our express written consent, and the Client will indemnify {{firm.name}} and its personnel against claims arising from any third party''s reliance on our advice.', null, null),
    (91, 'liability_firm_only', 'clause', 2, '{{firm.name}} alone is responsible for the services under this letter. No individual partner, employee or adviser has any personal liability to the Client for them.', null, null),
    (92, 'liability_contribution', 'clause', 2, 'Where we are jointly liable with another person, our liability is reduced by any contribution we would have recovered from another adviser but cannot recover because the Client agreed to limit that adviser''s liability.', null, null),

    (93, 'copyright', 'heading', 1, 'Copyright', null, null),
    (94, 'copyright_terms', 'paragraph', 2, 'Original materials we produce for the Client remain our copyright. The fees paid give the Client a licence to use them for the purposes for which they were produced and related purposes. The Client does not own the copyright in our work unless we agree in writing. The Client''s own books, records and data remain the Client''s property.', null, null),

    (95, 'retention', 'heading', 1, 'Retention of Documents', null, null),
    (96, 'retention_terms', 'paragraph', 2, 'We will keep our files for this engagement for {{retention.years}} years after it ends. After that period, provided we have returned the Client''s original documents, we may destroy the files without further reference to the Client. The Client may ask us before then to keep them for longer.', null, null),

    (97, 'term', 'heading', 1, 'Term and Termination', null, null),
    (98, 'term_start', 'clause', 2, 'This engagement starts on the date this letter is signed{{#engagement.start_date}} and covers work from {{engagement.start_date}}{{/engagement.start_date}}, and continues until either party ends it.', null, null),
    (99, 'term_notice', 'clause', 2, 'Either party may end the engagement by giving the other {{termination.notice_days}} days'' written notice.', null, null),
    (100, 'term_immediate', 'clause', 2, 'We may end the engagement immediately by written notice if fees remain unpaid {{fees.suspend_days}} days after their due date, or if continuing to act would breach the law or our professional rules.', null, null),
    (101, 'term_handover', 'clause', 2, 'When the engagement ends, the Client will pay our fees and expenses up to the date it ends. We will return the Client''s original documents and hand over its books, records and data, including access to the accounting system we maintained for it, within {{termination.handover_days}} days.', null, null),

    (102, 'problems', 'heading', 1, 'Resolving Problems', null, null),
    (103, 'problems_contact', 'paragraph', 2, 'To discuss any aspect of this engagement, please contact {{partner.name}}, {{partner.title}}, at {{partner.email}}. We will deal with any concern promptly and professionally.', null, null),

    (104, 'governing_law', 'heading', 1, 'Governing Law and Dispute Resolution', null, null),
    (105, 'law_nigerian', 'clause', 2, 'This letter, and any non-contractual obligations arising from or connected with it, are governed by Nigerian law.', null, null),
    (106, 'law_negotiation', 'clause', 2, 'The parties will first try to settle any dispute, controversy or claim arising from or relating to this letter (including its breach, existence, validity or termination) through good-faith negotiation.', null, null),
    (107, 'law_arbitration', 'clause', 2, 'Any dispute not settled within 30 days after negotiations begin, or any longer period the parties agree in writing, will be referred to and finally resolved by arbitration under the Arbitration Rules in the First Schedule to the Arbitration and Mediation Act 2023. The tribunal will be a sole arbitrator appointed by agreement of the parties or, failing agreement within 14 days, in accordance with that Act. The seat of arbitration is {{arbitration.seat}} and the language is English.', null, null),
    (108, 'law_confidentiality', 'clause', 2, 'The parties will keep confidential the existence and substance of any dispute and arbitration, the materials used and created for it, and any award, unless the information is already public (other than through a breach of this paragraph) or must be disclosed by law, to a party''s professional advisers or insurers, or to protect a legal right or enforce or challenge an award.', null, null),

    (109, 'signing', 'heading', 1, 'Signature and Entire Agreement', null, null),
    (110, 'signing_electronic', 'clause', 2, 'This letter may be signed electronically and in counterparts. An electronic signature has the same effect as a handwritten one.', null, null),
    (111, 'signing_entire_agreement', 'clause', 2, 'This letter is the entire agreement between the parties about its subject matter and replaces any earlier understanding or agreement, written or oral. It may be amended only in writing signed by both parties.', null, null),
    (112, 'closing', 'paragraph', 1, 'If you agree with these terms, please confirm by signing below. We look forward to working with you.', null, null),
    (113, 'closing_firm', 'paragraph', 1, E'Yours faithfully,\nFor: {{firm.name}}', null, null),
    (114, 'signature_firm', 'signature', 1, 'firm', null, null),
    (115, 'firm_signatory', 'paragraph', 1, E'{{partner.name}}\n{{partner.title}}', null, null),
    (116, 'acceptance', 'paragraph', 1, 'The above terms are accepted by the authorised representative of {{client.name}}:', null, null),
    (117, 'signature_client', 'signature', 1, 'client', null, null),
    (118, 'client_signatory', 'paragraph', 1, E'Name: {{signer.name}}\nDesignation: {{signer.title}}\nDate: {{signer.date}}', null, null)
  ) b(n, id, kind, level, text, variant, optional)
$$;

-- ---------------------------------------------------------------------------
-- 4. Links and one-time codes (shared with the director confirmations)
-- ---------------------------------------------------------------------------
-- A link token: the prefix, an underscore and 48 hex characters (24 random bytes), and its SHA-256 to store. Callers keep
-- the hash, with token_expires = now() + 14 days, and find a presented token by private.sha256_hex(token).
create or replace function private.token_new(p_prefix text) returns jsonb
language plpgsql volatile set search_path = public, private as $$
declare v_token text;
begin
  if coalesce(p_prefix, '') !~ '^[a-z]{2,8}$' then raise exception 'A token prefix is 2 to 8 lower-case letters.'; end if;
  v_token := p_prefix || '_' || encode(extensions.gen_random_bytes(24), 'hex');
  return jsonb_build_object('token', v_token, 'hash', private.sha256_hex(v_token));
end $$;

-- Whether another code may be emailed: five a day, counted by the day in Lagos. When it may, the counters to store.
create or replace function private.otp_send_ok(p_sends_day date, p_sends_today int) returns jsonb
language sql stable set search_path = public, private as $$
  select case when p_sends_day = z.today and coalesce(p_sends_today, 0) >= 5 then jsonb_build_object('ok', false, 'reason', 'too_many_today')
    else jsonb_build_object('ok', true, 'sends_day', z.today,
      'sends_today', case when p_sends_day = z.today then coalesce(p_sends_today, 0) + 1 else 1 end) end
  from (select (now() at time zone 'Africa/Lagos')::date as today) z
$$;

-- A new 6-digit code for the holder p_id: the code (to email, never to store), the SHA-256 of "<p_id>:<code>" and its
-- expiry, ten minutes from now. The caller stores the hash and expiry and sets otp_tries = 0.
create or replace function private.otp_new(p_id uuid) returns jsonb
language plpgsql volatile set search_path = public, private as $$
declare v_code text := lpad((('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint % 1000000)::text, 6, '0');
begin
  return jsonb_build_object('code', v_code, 'otp_hash', private.sha256_hex(p_id::text || ':' || v_code), 'otp_expires', now() + interval '10 minutes');
end $$;

-- A code presented by the holder p_id, against what is stored. Refused without comparing when the holder is locked (15
-- wrong codes), the code is gone or past its expiry, or its 5 tries are used up; otherwise compared (spaces aside), which
-- uses a try, and a wrong code is a failure. Returns {ok, reason: null|locked|expired|used_up|wrong_code, otp_tries,
-- otp_failures, locked, tries_left}: the caller writes the counters back (locked_at = now() once locked), never raising,
-- so they persist.
create or replace function private.otp_check(p_id uuid, p_code text, p_otp_hash text, p_otp_expires timestamptz, p_otp_tries int,
  p_otp_failures int, p_locked_at timestamptz) returns jsonb
language plpgsql stable set search_path = public, private as $$
declare v_tries int := coalesce(p_otp_tries, 0); v_failures int := coalesce(p_otp_failures, 0); v_ok boolean := false; v_reason text;
begin
  if p_locked_at is not null or v_failures >= 15 then
    v_reason := 'locked';
  elsif p_otp_hash is null or p_otp_expires is null or p_otp_expires <= now() then
    v_reason := 'expired';
  elsif v_tries >= 5 then
    v_reason := 'used_up';
  elsif private.sha256_hex(p_id::text || ':' || regexp_replace(coalesce(p_code, ''), '\s', '', 'g')) = p_otp_hash then
    v_ok := true; v_tries := v_tries + 1;
  else
    v_reason := 'wrong_code'; v_tries := v_tries + 1; v_failures := v_failures + 1;
  end if;
  return jsonb_build_object('ok', v_ok, 'reason', v_reason, 'otp_tries', v_tries, 'otp_failures', v_failures,
    'locked', p_locked_at is not null or v_failures >= 15,
    'tries_left', case when p_locked_at is not null or v_failures >= 15 or v_reason in ('expired', 'used_up') then 0 else greatest(5 - v_tries, 0) end);
end $$;

-- ---------------------------------------------------------------------------
-- 5. Records: events, emails, the freeze
-- ---------------------------------------------------------------------------
-- One step in a letter's life, in its record and, when the letter is for a business, in that business's activity log
-- (the letter and the practice only: no link, code, fingerprint or person's details).
create or replace function private.letter_event(p_letter uuid, p_kind text, p_actor text, p_ip text, p_ua text, p_detail jsonb default '{}')
returns void
language plpgsql set search_path = public, private as $$
declare v_org uuid; v_practice uuid;
begin
  if coalesce(p_kind, '') not in ('drafted', 'partner_signed', 'sent', 'opened', 'code_sent', 'code_failed', 'signed', 'uploaded', 'voided') then
    raise exception 'Unknown letter event kind: %.', p_kind;
  end if;
  insert into engagement_letter_events (letter_id, kind, actor, ip, ua, detail)
  values (p_letter, p_kind, left(nullif(trim(p_actor), ''), 120), left(nullif(trim(p_ip), ''), 64), left(nullif(p_ua, ''), 300), coalesce(p_detail, '{}'));
  select l.practice_id, coalesce(pc.org_id, x.org_id) into v_practice, v_org
  from engagement_letters l
  left join practice_clients pc on pc.id = l.client_id
  left join practice_intakes x on x.id = l.intake_id
  where l.id = p_letter;
  if v_org is not null then
    perform private.activity_event(v_org, 'letter_' || p_kind, case p_kind
        when 'drafted' then 'Engagement letter drafted'
        when 'partner_signed' then 'Engagement letter signed by the firm'
        when 'sent' then 'Engagement letter sent for signature'
        when 'opened' then 'Engagement letter opened by the client'
        when 'code_sent' then 'Engagement letter signing code sent'
        when 'code_failed' then 'Engagement letter signing code entered wrongly'
        when 'signed' then 'Engagement letter signed by the client'
        when 'uploaded' then 'Engagement letter signed copy uploaded'
        else 'Engagement letter voided' end,
      jsonb_build_object('letter_id', p_letter, 'practice_id', v_practice));
  end if;
end $$;

-- Asks the messaging function to send a practice email (it calls svc_practice_mail for the content).
create or replace function private.practice_mail(p_kind text, p_id uuid) returns void
language plpgsql set search_path = public, private as $$
begin
  perform private.call_function('messaging', jsonb_build_object('action', 'practice_mail', 'kind', p_kind, 'id', p_id));
end $$;

-- A letter only moves forward: draft -> partner_signed, uploaded or void; partner_signed -> sent, uploaded or void; sent ->
-- sent (again), completed, uploaded or void; completed, uploaded and void letters are closed. It stays with its practice.
-- Once the partner signs, what the letter says, the firm's signature and who signed it are fixed. (The template or the
-- partner's place in the practice may go, deleted, leaving the letter without the link to it.)
create or replace function private.engagement_letters_freeze() returns trigger
language plpgsql set search_path = public, private as $$
begin
  if new.practice_id is distinct from old.practice_id then raise exception 'A letter stays with its practice.'; end if;
  if old.status in ('completed', 'uploaded', 'void')
     and (new.status, new.final_path, new.final_sha256, new.void_reason) is distinct from (old.status, old.final_path, old.final_sha256, old.void_reason) then
    raise exception 'This letter is closed: it cannot change.';
  end if;
  if old.status <> 'draft' and (
       new.status = 'draft'
     or (new.blocks, new.merge, new.variant, new.source, new.doc_path, new.doc_sha256, new.intake_id, new.title, new.retention_years, new.white_label,
         new.partner_signature, new.partner_name, new.partner_email, new.partner_signed_at, new.partner_ip, new.partner_ua)
        is distinct from
        (old.blocks, old.merge, old.variant, old.source, old.doc_path, old.doc_sha256, old.intake_id, old.title, old.retention_years, old.white_label,
         old.partner_signature, old.partner_name, old.partner_email, old.partner_signed_at, old.partner_ip, old.partner_ua)
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
end $$;

create trigger engagement_letters_freeze before update on public.engagement_letters
  for each row execute function private.engagement_letters_freeze();

-- A letter's events are never changed or removed; they go only with the letter itself (a delete cascading from it).
create or replace function private.engagement_letter_events_guard() returns trigger
language plpgsql set search_path = public, private as $$
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then return null; end if;
  raise exception 'The record of a letter''s events cannot be changed.' using errcode = '42501';
end $$;

create trigger engagement_letter_events_kept before update or delete or truncate on public.engagement_letter_events
  for each statement execute function private.engagement_letter_events_guard();

-- ---------------------------------------------------------------------------
-- 6. Helpers
-- ---------------------------------------------------------------------------
-- The letter, for its practice's partners and managers (locked when it is to be changed).
create or replace function private.letter_require(p_letter uuid, p_lock boolean default false) returns public.engagement_letters
language plpgsql set search_path = public, private as $$
declare l public.engagement_letters;
begin
  if p_lock then select * into l from engagement_letters where id = p_letter for update;
  else select * into l from engagement_letters where id = p_letter; end if;
  if l.id is null then raise exception 'Letter not found.'; end if;
  perform private.practice_require(l.practice_id, true);
  return l;
end $$;

-- A letter as the portal shows it: its columns, the names of its template, partner and intake, its signer (no link or
-- code hashes) and its events.
create or replace function private.letter_json(l public.engagement_letters) returns jsonb
language sql stable set search_path = public, private as $$
  select to_jsonb(l) || jsonb_build_object(
    'template_name', (select name from practice_letter_templates where id = l.template_id),
    'intake_name', (select legal_name from practice_intakes where id = l.intake_id),
    'signers', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'email', s.email, 'title', s.title,
        'link_sent', s.token_hash is not null, 'token_expires', s.token_expires, 'sends_today', s.sends_today, 'sends_day', s.sends_day,
        'otp_failures', s.otp_failures, 'locked', s.locked_at is not null, 'locked_at', s.locked_at, 'code_verified_at', s.code_verified_at,
        'signature_path', s.signature_path, 'typed_name', s.typed_name, 'ip', s.ip, 'ua', s.ua, 'signed_at', s.signed_at, 'created_at', s.created_at)
        order by s.created_at), '[]'::jsonb)
      from engagement_letter_signers s where s.letter_id = l.id),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'at', e.at, 'kind', e.kind, 'actor', e.actor, 'ip', e.ip, 'ua', e.ua,
        'detail', e.detail) order by e.id), '[]'::jsonb)
      from engagement_letter_events e where e.letter_id = l.id))
$$;

create or replace function private.letter_template_json(t public.practice_letter_templates) returns jsonb
language sql stable set search_path = public, private as $$
  select jsonb_build_object('id', t.id, 'name', t.name, 'kind', t.kind, 'body', t.body, 'pdf_path', t.pdf_path, 'is_default', t.is_default,
    'archived', t.archived, 'created_by_name', (select display_name from practice_members where id = t.created_by), 'created_at', t.created_at,
    'updated_at', t.updated_at)
$$;

-- A practice with no templates gets the standard letter as its default.
create or replace function private.letter_template_ensure(p_practice uuid) returns void
language sql set search_path = public, private as $$
  insert into practice_letter_templates (practice_id, name, kind, body, is_default)
  select p_practice, 'Counta standard letter', 'blocks', private.letter_default_body(), true
  where not exists (select 1 from practice_letter_templates where practice_id = p_practice)
  on conflict (practice_id) where is_default do nothing
$$;

-- The signer a presented link belongs to, or nothing. Locks the letter, then the signer: every call that locks both locks
-- them in that order.
create or replace function private.letter_signer_by_token(p_token text) returns public.engagement_letter_signers
language plpgsql set search_path = public, private as $$
declare s public.engagement_letter_signers; v_id uuid; v_letter uuid;
begin
  if coalesce(p_token, '') ~ '^es_[0-9a-f]{48}$' then
    select id, letter_id into v_id, v_letter from engagement_letter_signers where token_hash = private.sha256_hex(p_token);
    if v_id is not null then
      perform 1 from engagement_letters where id = v_letter for update;
      -- (The link may have been replaced while waiting.)
      select * into s from engagement_letter_signers where id = v_id and token_hash = private.sha256_hex(p_token) for update;
    end if;
  end if;
  return s;
end $$;

-- Why a signer cannot act on the letter now, or null when it is out for their signature: invalid (no such link), expired,
-- void, signed (already, by them), closed (a signed copy was uploaded instead).
create or replace function private.letter_signer_state(s public.engagement_letter_signers, l public.engagement_letters) returns text
language sql stable set search_path = public, private as $$
  select case when s.id is null or l.id is null then 'invalid'
    when s.token_expires is null or s.token_expires <= now() then 'expired'
    when l.status = 'void' then 'void'
    when s.signed_at is not null or l.status = 'completed' then 'signed'
    when l.status <> 'sent' then 'closed' end
$$;

-- The intake a letter is for may be engaged on: not declined, its risk rated and its conflicts check clear (the letter
-- says the check was done).
create or replace function private.letter_intake_ready(p_intake uuid) returns void
language plpgsql set search_path = public, private as $$
declare i public.practice_intakes;
begin
  select * into i from practice_intakes where id = p_intake;
  if i.status = 'declined' then raise exception 'This intake was declined after the conflicts check.'; end if;
  if not private.intake_cleared(i) then
    raise exception 'Finish the due diligence and conflicts check first: the letter confirms the check was done.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 7. The portal's calls (partners and managers unless said)
-- ---------------------------------------------------------------------------
-- The practice's templates, the default first.
create or replace function public.practice_letter_templates(p_practice uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.practice_require(p_practice, true);
  perform private.letter_template_ensure(p_practice);
  return (select coalesce(jsonb_agg(private.letter_template_json(t) order by t.is_default desc, t.archived, t.name, t.id), '[]'::jsonb)
          from practice_letter_templates t where t.practice_id = p_practice);
end $$;

-- A partner adds or changes a template. p: {id?, name, kind: blocks|pdf, body? (blocks), pdf_path? (pdf, in the practice's
-- letters folder), is_default?, archived?}; a key left out keeps its value. A template keeps its kind. Archived, it is not
-- the default; made the default, the practice's other default stops being one.
create or replace function public.practice_letter_template_save(p_practice uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.practice_members; t public.practice_letter_templates; v_name text; v_kind text; v_body jsonb; v_pdf text; v_default boolean;
  v_archived boolean; v_err text;
begin
  m := private.practice_require(p_practice, true);
  if m.role <> 'partner' then raise exception 'Only a partner manages the practice''s letter templates.' using errcode = '42501'; end if;
  if jsonb_typeof(p) is distinct from 'object' then raise exception 'Nothing to save.'; end if;
  if nullif(p->>'id', '') is not null then
    select * into t from practice_letter_templates where id = private.uuid_of(p->>'id') and practice_id = p_practice for update;
    if t.id is null then raise exception 'Template not found.'; end if;
  end if;
  v_name := case when p ? 'name' then trim(p->>'name') else t.name end;
  if v_name is null or length(v_name) not between 2 and 80 then raise exception 'Name the template (2 to 80 characters).'; end if;
  v_kind := coalesce(nullif(p->>'kind', ''), t.kind, 'blocks');
  if v_kind not in ('blocks', 'pdf') then raise exception 'A template is blocks or a PDF.'; end if;
  if t.id is not null and v_kind <> t.kind then raise exception 'A template keeps its kind: start a new template instead.'; end if;
  if v_kind = 'blocks' then
    v_body := case when p ? 'body' then p->'body' else t.body end;
    v_err := private.letter_body_ok(v_body);
    if v_err is not null then raise exception '%', v_err; end if;
  else
    v_pdf := case when p ? 'pdf_path' then nullif(trim(p->>'pdf_path'), '') else t.pdf_path end;
    if v_pdf is null or not private.letter_file_ok(v_pdf, p_practice, 'templates') then
      raise exception 'Upload the PDF to the templates folder of the practice''s letters folder first.';
    end if;
    if lower(v_pdf) !~ '\.pdf$' then raise exception 'The template file must be a PDF.'; end if;
  end if;
  foreach v_err in array array['is_default', 'archived'] loop
    if jsonb_typeof(p->v_err) not in ('boolean', 'null') and coalesce(p->>v_err, '') not in ('true', 'false') then
      raise exception 'Say true or false for %.', replace(v_err, '_', ' ');
    end if;
  end loop;
  v_archived := coalesce((p->>'archived')::boolean, t.archived, false);
  v_default := coalesce((p->>'is_default')::boolean, t.is_default, false) and not v_archived;
  if v_default then
    update practice_letter_templates set is_default = false, updated_at = now() where practice_id = p_practice and is_default and id is distinct from t.id;
  end if;
  if t.id is null then
    insert into practice_letter_templates (practice_id, name, kind, body, pdf_path, is_default, archived, created_by)
    values (p_practice, v_name, v_kind, v_body, v_pdf, v_default, v_archived, m.id)
    returning * into t;
  else
    update practice_letter_templates set name = v_name, body = v_body, pdf_path = v_pdf, is_default = v_default, archived = v_archived, updated_at = now()
    where id = t.id
    returning * into t;
  end if;
  return private.letter_template_json(t);
end $$;

-- Drafts a letter for the intake. p: {template_id? (else the practice's default), variant? (else the intake's mode),
-- merge?, retention_years? (else merge's retention.years, else 6)}. The merge values are the defaults, then what the
-- intake, the practice and the engagement partner say (the client link's partner, else the caller when a partner, else the
-- practice's first partner; the services are the client link's, else the usual ones), then the caller's.
create or replace function public.practice_letter_draft(p_intake uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.practice_intakes; m public.practice_members; pr public.practices; t public.practice_letter_templates; pt public.practice_members;
  c public.practice_clients; l public.engagement_letters; v_variant text; v_services text[]; v_work text[]; v_merge jsonb; v_years int; v_err text;
begin
  i := private.intake_require(p_intake);
  m := private.practice_me(i.practice_id);
  p := coalesce(p, '{}');
  if jsonb_typeof(p) <> 'object' then raise exception 'Nothing to draft.'; end if;
  if i.status = 'declined' then raise exception 'This intake was declined after the conflicts check.'; end if;
  v_variant := coalesce(nullif(p->>'variant', ''), i.mode_requested);
  if v_variant not in ('full', 'involved') then raise exception 'Choose the full mandate or involved letter.'; end if;
  if p ? 'merge' and jsonb_typeof(p->'merge') not in ('object', 'null') then raise exception 'The merge values must be an object of fields.'; end if;

  perform private.letter_template_ensure(i.practice_id);
  if nullif(p->>'template_id', '') is not null then
    select * into t from practice_letter_templates where id = private.uuid_of(p->>'template_id') and practice_id = i.practice_id and not archived;
    if t.id is null then raise exception 'Template not found.'; end if;
  else
    select * into t from practice_letter_templates where practice_id = i.practice_id and is_default and not archived;
    if t.id is null then raise exception 'Choose a template: the practice has no default letter.'; end if;
  end if;

  select * into pr from practices where id = i.practice_id;
  select * into c from practice_clients where id = i.client_id;
  select * into pt from practice_members where id = c.engagement_partner_id and status = 'active';
  if pt.id is null and m.role = 'partner' then pt := m; end if;
  if pt.id is null then
    select * into pt from practice_members where practice_id = i.practice_id and role = 'partner' and status = 'active' order by created_at, id limit 1;
  end if;
  v_services := coalesce(c.services, '{bookkeeping,vat,wht,cit,statements}');
  v_work := array_remove(array[case when 'advisory' = any (v_services) then 'tax advisory' end,
    case when 'bookkeeping' = any (v_services) then 'accounting' end,
    case when v_services && '{vat,wht,payroll,cit,statements}' then 'tax compliance' end], null);
  v_merge := private.letter_defaults() || jsonb_strip_nulls(jsonb_build_object(
      'letter.date', to_char((now() at time zone 'Africa/Lagos')::date, 'FMDD FMMonth YYYY'),
      'client.name', i.legal_name,
      'client.address', i.address,
      'client.reg_label', case i.entity_type when 'business_name' then 'BN' when 'incorporated_trustees' then 'IT' end,
      'client.rc_number', nullif(regexp_replace(trim(i.rc_number), '^(RC|BN|IT)[[:space:].:-]*', '', 'i'), ''),
      'client.description', 'operates in the ' || lower(i.industry) || ' sector',
      'engagement.title_lower', case cardinality(v_work) when 0 then null when 1 then v_work[1]
          else array_to_string(v_work[1:cardinality(v_work) - 1], ', ') || ' and ' || v_work[cardinality(v_work)] end || ' services',
      'firm.name', pr.name, 'firm.email', pr.email, 'firm.phone', pr.phone, 'firm.city', pr.state,
      'partner.name', pt.display_name, 'partner.title', case when pt.id is not null then 'Partner' end, 'partner.email', pt.email,
      'service.advisory', 'advisory' = any (v_services), 'service.bookkeeping', 'bookkeeping' = any (v_services),
      'service.monthly', v_services && '{vat,wht,payroll}', 'service.annual', v_services && '{cit,statements}',
      'mode.full_mandate', v_variant = 'full'))
    || case when jsonb_typeof(p->'merge') = 'object' then p->'merge' else '{}' end;
  v_years := coalesce(private.letter_years(p->'retention_years'), private.letter_years(v_merge->'retention.years'), 6);
  v_merge := v_merge || jsonb_build_object('retention.years', v_years);
  v_err := private.letter_merge_ok(v_merge);
  if v_err is not null then raise exception '%', v_err; end if;

  insert into engagement_letters (practice_id, intake_id, client_id, template_id, variant, source, title, blocks, merge, doc_path, retention_years,
    white_label, created_by)
  values (i.practice_id, i.id, i.client_id, t.id, v_variant, case when t.kind = 'pdf' then 'pdf' else 'template' end,
    left('Letter of engagement: ' || i.legal_name, 160), t.body, v_merge, t.pdf_path, v_years, v_variant = 'full', m.id)
  returning * into l;
  perform private.letter_event(l.id, 'drafted', m.display_name, null, null, jsonb_build_object('template_id', t.id, 'variant', v_variant));
  return private.letter_json(l);
end $$;

-- Changes a draft. p: {blocks? (partners: a body, or its blocks alone), merge? (merged into the values), title?,
-- retention_years? (else merge's retention.years)}.
create or replace function public.practice_letter_save(p_letter uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.engagement_letters; m public.practice_members; v_body jsonb; v_merge jsonb; v_title text; v_years int; v_err text;
begin
  l := private.letter_require(p_letter, true);
  m := private.practice_me(l.practice_id);
  if jsonb_typeof(p) is distinct from 'object' then raise exception 'Nothing to save.'; end if;
  if l.status <> 'draft' then raise exception 'Only a draft can be changed: a signed letter cannot be edited. Void it and start again.'; end if;
  v_body := l.blocks;
  if p ? 'blocks' then
    if m.role <> 'partner' then raise exception 'Only a partner changes the clauses of a letter.' using errcode = '42501'; end if;
    if l.source <> 'template' then raise exception 'This letter is a PDF: it is signed as it stands.'; end if;
    v_body := case when jsonb_typeof(p->'blocks') = 'array' then jsonb_build_object('version', 1, 'blocks', p->'blocks') else p->'blocks' end;
    v_err := private.letter_body_ok(v_body);
    if v_err is not null then raise exception '%', v_err; end if;
  end if;
  v_merge := l.merge;
  if p ? 'merge' then
    if jsonb_typeof(p->'merge') <> 'object' then raise exception 'The merge values must be an object of fields.'; end if;
    v_merge := v_merge || (p->'merge');
  end if;
  v_title := case when p ? 'title' then trim(p->>'title') else l.title end;
  if v_title is null or length(v_title) not between 2 and 160 then raise exception 'Give the letter a title (2 to 160 characters).'; end if;
  v_years := coalesce(private.letter_years(p->'retention_years'), private.letter_years(p->'merge'->'retention.years'), l.retention_years);
  v_merge := v_merge || jsonb_build_object('retention.years', v_years);
  v_err := private.letter_merge_ok(v_merge);
  if v_err is not null then raise exception '%', v_err; end if;
  update engagement_letters set blocks = v_body, merge = v_merge, title = v_title, retention_years = v_years, updated_at = now()
  where id = l.id
  returning * into l;
  return private.letter_json(l);
end $$;

-- One letter, with its signer and events.
create or replace function public.practice_letter(p_letter uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  return private.letter_json(private.letter_require(p_letter));
end $$;

-- What the practice function needs to render a draft for a partner to sign: the body, the merge values, the firm and the
-- signing partner (a PDF letter: its file, signed as it stands).
create or replace function public.practice_letter_prepare(p_letter uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
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
    'variant', l.variant, 'blocks', l.blocks, 'merge', l.merge,
    'firm', jsonb_build_object('name', pr.name, 'email', pr.email, 'phone', pr.phone, 'address', pr.address, 'state', pr.state),
    'partner', jsonb_build_object('id', m.id, 'name', m.display_name, 'email', m.email, 'title', 'Partner'));
end $$;

-- A partner sends the signed letter to the client's signer (or sends it again, perhaps to someone else: a new link, and the
-- codes start afresh). p: {name, email, title?}. The signer's address cannot be the firm's.
create or replace function public.practice_letter_send(p_letter uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.engagement_letters; m public.practice_members; v_name text := trim(coalesce(p->>'name', ''));
  v_email text := lower(trim(coalesce(p->>'email', ''))); v_title text := nullif(trim(coalesce(p->>'title', '')), ''); v_signer uuid;
begin
  l := private.letter_require(p_letter, true);
  m := private.practice_me(l.practice_id);
  if m.role <> 'partner' then raise exception 'Only a partner sends a letter for signing.' using errcode = '42501'; end if;
  if l.status = 'void' then raise exception 'This letter is void: draft a new one.'; end if;
  if l.status in ('completed', 'uploaded') then raise exception 'This letter is signed already.'; end if;
  if l.status not in ('partner_signed', 'sent') then raise exception 'Send the letter once the firm signs it.'; end if;
  perform private.letter_intake_ready(l.intake_id);
  if length(v_name) not between 2 and 120 then raise exception 'Enter the signer''s name (2 to 120 characters).'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 254 then raise exception 'Enter the signer''s email address.'; end if;
  if length(v_title) > 80 then raise exception 'Keep the signer''s title under 80 characters.'; end if;
  if exists (select 1 from practice_members where practice_id = l.practice_id and lower(trim(email)) = v_email)
     or exists (select 1 from practices where id = l.practice_id and lower(trim(email)) = v_email) then
    raise exception 'Send the letter to the client''s own email address, not the firm''s.';
  end if;
  insert into engagement_letter_signers (letter_id, name, email, title)
  values (l.id, v_name, v_email, v_title)
  on conflict (letter_id) do update set name = excluded.name, email = excluded.email, title = excluded.title, token_hash = null, token_expires = null,
    otp_hash = null, otp_expires = null, otp_tries = 0, otp_failures = 0, locked_at = null, code_verified_at = null, updated_at = now()
  returning id into v_signer;
  update engagement_letters set status = 'sent', updated_at = now() where id = l.id returning * into l;
  perform private.letter_event(l.id, 'sent', m.display_name, null, null, jsonb_build_object('signer_id', v_signer, 'to', v_email));
  perform private.practice_mail('letter_sign', v_signer);
  return private.letter_json(l);
end $$;

-- A partner records a copy signed outside Counta, uploaded to the letter's folder, once the intake is cleared (the letter
-- says the conflicts check was done). p: {path, sha256}. From a draft the uploaded file is the letter; otherwise the letter
-- stays as the firm signed it and its link stops working.
create or replace function public.practice_letter_upload_signed(p_letter uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.engagement_letters; m public.practice_members; v_path text := trim(coalesce(p->>'path', '')); v_sha text := lower(trim(coalesce(p->>'sha256', '')));
begin
  l := private.letter_require(p_letter, true);
  m := private.practice_me(l.practice_id);
  if m.role <> 'partner' then raise exception 'Only a partner records a signed letter.' using errcode = '42501'; end if;
  if l.status = 'void' then raise exception 'This letter is void: draft a new one.'; end if;
  if l.status in ('completed', 'uploaded') then raise exception 'This letter is signed already.'; end if;
  perform private.letter_intake_ready(l.intake_id);
  if not private.letter_file_ok(v_path, l.practice_id, l.id::text) then raise exception 'Upload the signed copy to the letter''s folder first.'; end if;
  if v_sha !~ '^[0-9a-f]{64}$' then raise exception 'The signed copy''s SHA-256 fingerprint is missing.'; end if;
  update engagement_letters set
    source = case when status = 'draft' then 'signed_upload' else source end,
    doc_path = case when status = 'draft' then v_path else doc_path end,
    doc_sha256 = case when status = 'draft' then v_sha else doc_sha256 end,
    final_path = v_path, final_sha256 = v_sha, status = 'uploaded', updated_at = now()
  where id = l.id
  returning * into l;
  perform private.letter_event(l.id, 'uploaded', m.display_name, null, null, jsonb_build_object('sha256', v_sha));
  return private.letter_json(l);
end $$;

-- A partner voids a letter not yet signed by both sides, giving a reason. Its link then says it was withdrawn.
create or replace function public.practice_letter_void(p_letter uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare l public.engagement_letters; m public.practice_members; v_reason text := trim(coalesce(p_reason, ''));
begin
  l := private.letter_require(p_letter, true);
  m := private.practice_me(l.practice_id);
  if m.role <> 'partner' then raise exception 'Only a partner voids a letter.' using errcode = '42501'; end if;
  if l.status = 'void' then raise exception 'This letter is void already.'; end if;
  if l.status in ('completed', 'uploaded') then
    raise exception 'A letter signed by both sides stays on record. Draft a new letter to change the terms.';
  end if;
  if length(v_reason) not between 5 and 500 then raise exception 'Give a reason for voiding the letter (5 to 500 characters).'; end if;
  update engagement_letters set status = 'void', void_reason = v_reason, updated_at = now() where id = l.id returning * into l;
  perform private.letter_event(l.id, 'voided', m.display_name, null, null, jsonb_build_object('reason', v_reason));
  return private.letter_json(l);
end $$;

-- One intake in full, with its engagement letters, newest first.
create or replace function public.practice_intake(p_intake uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.practice_intakes;
begin
  i := private.intake_require(p_intake);
  return private.intake_json(i, true) || jsonb_build_object('letters',
    (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'status', l.status, 'variant', l.variant) order by l.created_at desc, l.id), '[]'::jsonb)
     from engagement_letters l where l.intake_id = i.id));
end $$;

-- ---------------------------------------------------------------------------
-- 8. The practice function's calls (service role)
-- ---------------------------------------------------------------------------
-- The partner has signed: the letter as rendered (in the letter's folder; a PDF letter is its own file), its SHA-256, and
-- the partner's signature, name and email as they are now (the completion certificate shows them).
-- p: {doc_path, doc_sha256, by_user (the signed-in partner), signature_name?, ip?, ua?}.
create or replace function public.svc_letter_frozen(p_letter uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
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
  perform private.set_actor(pm.user_id);
  update engagement_letters set status = 'partner_signed', doc_path = v_path, doc_sha256 = v_sha, partner_id = pm.id, partner_signature = v_sig,
    partner_name = pm.display_name, partner_email = lower(trim(pm.email)), partner_signed_at = now(), partner_ip = left(nullif(trim(p->>'ip'), ''), 64),
    partner_ua = left(nullif(p->>'ua', ''), 300), updated_at = now()
  where id = l.id
  returning * into l;
  perform private.letter_event(l.id, 'partner_signed', pm.display_name, l.partner_ip, l.partner_ua, jsonb_build_object('signature', v_sig));
  return private.letter_json(l);
end $$;

-- The signing page opens a link: the letter to read (the signed copy once both have signed). Never raises. The opening is
-- recorded once a Lagos day per signer.
create or replace function public.svc_sign_open(p_token text, p_ip text, p_ua text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.engagement_letter_signers; l public.engagement_letters; v_state text;
begin
  s := private.letter_signer_by_token(p_token);
  select * into l from engagement_letters where id = s.letter_id;
  v_state := private.letter_signer_state(s, l);
  if v_state is not null and v_state <> 'signed' then return jsonb_build_object('ok', false, 'reason', v_state); end if;
  if v_state is null and not exists (
       select 1 from engagement_letter_events e
       where e.letter_id = l.id and e.kind = 'opened' and e.detail->>'signer_id' = s.id::text
         and (e.at at time zone 'Africa/Lagos')::date = (now() at time zone 'Africa/Lagos')::date) then
    perform private.letter_event(l.id, 'opened', s.name, p_ip, p_ua, jsonb_build_object('signer_id', s.id));
  end if;
  return jsonb_build_object('ok', true, 'letter_id', l.id, 'title', l.title, 'firm_name', (select name from practices where id = l.practice_id),
    'signer_name', s.name, 'doc_path', case when l.status = 'completed' then l.final_path else l.doc_path end, 'status', l.status,
    'white_label', l.white_label);
end $$;

-- The signer asks for a code by email: five a Lagos day. Never raises.
create or replace function public.svc_sign_code(p_token text, p_ip text, p_ua text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.engagement_letter_signers; l public.engagement_letters; v_state text; r jsonb;
begin
  s := private.letter_signer_by_token(p_token);
  select * into l from engagement_letters where id = s.letter_id;
  v_state := private.letter_signer_state(s, l);
  if v_state is not null then return jsonb_build_object('ok', false, 'reason', v_state); end if;
  if s.locked_at is not null then return jsonb_build_object('ok', false, 'reason', 'locked'); end if;
  r := private.otp_send_ok(s.sends_day, s.sends_today);
  if not (r->>'ok')::boolean then return jsonb_build_object('ok', false, 'reason', r->>'reason'); end if;
  update engagement_letter_signers set sends_day = (r->>'sends_day')::date, sends_today = (r->>'sends_today')::int, updated_at = now() where id = s.id;
  perform private.practice_mail('letter_code', s.id);
  perform private.letter_event(l.id, 'code_sent', s.name, p_ip, p_ua, jsonb_build_object('signer_id', s.id, 'sends_today', (r->>'sends_today')::int));
  return jsonb_build_object('ok', true, 'sends_left', 5 - (r->>'sends_today')::int);
end $$;

-- The signer enters the code: five tries per code, locked after fifteen wrong codes. Right, the signer may sign for the
-- next 15 minutes, and the practice function gets what the completion certificate needs. Never raises, so the counts stay.
create or replace function public.svc_sign_verify(p_token text, p_code text, p_ip text, p_ua text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.engagement_letter_signers; l public.engagement_letters; v_state text; r jsonb;
begin
  s := private.letter_signer_by_token(p_token);
  select * into l from engagement_letters where id = s.letter_id;
  v_state := private.letter_signer_state(s, l);
  if v_state is not null then return jsonb_build_object('ok', false, 'reason', v_state, 'tries_left', 0); end if;
  r := private.otp_check(s.id, p_code, s.otp_hash, s.otp_expires, s.otp_tries, s.otp_failures, s.locked_at);
  update engagement_letter_signers set otp_tries = (r->>'otp_tries')::int, otp_failures = (r->>'otp_failures')::int,
    locked_at = case when (r->>'locked')::boolean then coalesce(locked_at, now()) else locked_at end,
    otp_hash = case when (r->>'ok')::boolean then null else otp_hash end,
    code_verified_at = case when (r->>'ok')::boolean then now() else code_verified_at end, updated_at = now()
  where id = s.id
  returning * into s;
  if r->>'reason' = 'wrong_code' then
    perform private.letter_event(l.id, 'code_failed', s.name, p_ip, p_ua,
      jsonb_build_object('signer_id', s.id, 'tries_left', (r->>'tries_left')::int, 'locked', (r->>'locked')::boolean));
  end if;
  if not (r->>'ok')::boolean then
    return jsonb_build_object('ok', false, 'reason', r->>'reason', 'tries_left', (r->>'tries_left')::int, 'locked', (r->>'locked')::boolean);
  end if;
  return jsonb_build_object('ok', true, 'reason', null, 'tries_left', (r->>'tries_left')::int, 'locked', false,
    'letter', jsonb_build_object('letter_id', l.id, 'signer_id', s.id, 'doc_path', l.doc_path, 'doc_sha256', l.doc_sha256, 'title', l.title,
      'practice_id', l.practice_id, 'partner_name', l.partner_name, 'partner_signature', l.partner_signature,
      'partner_email', l.partner_email, 'partner_signed_at', l.partner_signed_at, 'partner_ip', l.partner_ip, 'partner_ua', l.partner_ua,
      'signer_name', s.name, 'signer_email', s.email, 'signer_title', s.title, 'code_verified_at', s.code_verified_at, 'white_label', l.white_label));
end $$;

-- The signer has signed: their signature image and the final letter (with its certificate), both in the letter's folder,
-- within 15 minutes of entering the code. p: {signature_path, final_path, final_sha256, typed_name, ip, ua}. The letter
-- is completed and both sides are emailed. A link or state that does not allow it is a reason, not an error.
create or replace function public.svc_sign_complete(p_token text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.engagement_letter_signers; l public.engagement_letters; v_state text;
  v_sig text := trim(coalesce(p->>'signature_path', '')); v_final text := trim(coalesce(p->>'final_path', ''));
  v_sha text := lower(trim(coalesce(p->>'final_sha256', ''))); v_name text := trim(coalesce(p->>'typed_name', ''));
begin
  s := private.letter_signer_by_token(p_token);
  select * into l from engagement_letters where id = s.letter_id;
  v_state := private.letter_signer_state(s, l);
  if v_state is not null then return jsonb_build_object('ok', false, 'reason', v_state); end if;
  if s.locked_at is not null then return jsonb_build_object('ok', false, 'reason', 'locked'); end if;
  if s.code_verified_at is null or s.code_verified_at <= now() - interval '15 minutes' then
    return jsonb_build_object('ok', false, 'reason', 'not_verified');
  end if;
  if not private.letter_file_ok(v_sig, l.practice_id, l.id::text) or not private.letter_file_ok(v_final, l.practice_id, l.id::text) then
    raise exception 'The signature and the signed letter must be stored in the letter''s folder.';
  end if;
  if v_sha !~ '^[0-9a-f]{64}$' then raise exception 'The signed letter''s SHA-256 fingerprint is missing.'; end if;
  if length(v_name) not between 2 and 120 then raise exception 'Type the signer''s name (2 to 120 characters).'; end if;
  update engagement_letter_signers set signature_path = v_sig, typed_name = v_name, ip = left(nullif(trim(p->>'ip'), ''), 64),
    ua = left(nullif(p->>'ua', ''), 300), signed_at = now(), updated_at = now()
  where id = s.id
  returning * into s;
  update engagement_letters set final_path = v_final, final_sha256 = v_sha, status = 'completed', updated_at = now() where id = l.id returning * into l;
  perform private.letter_event(l.id, 'signed', v_name, s.ip, s.ua, jsonb_build_object('signer_id', s.id, 'typed_name', v_name));
  perform private.practice_mail('letter_done', l.id);
  return jsonb_build_object('ok', true, 'letter_id', l.id, 'status', l.status);
end $$;

-- What a practice email says, for the messaging function as it sends it, in the firm's name; null when there is nothing to
-- send. letter_sign (a signer): a fresh link, replacing the last one, for 14 days. letter_code (a signer): a fresh code for
-- 10 minutes, its tries reset. letter_done (a letter): to the signer, copied to the partner, with a fresh link to the
-- signed letter.
create or replace function public.svc_practice_mail(p_kind text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.engagement_letter_signers; l public.engagement_letters; pr public.practices; v_app text; v_client text; v_reply text; t jsonb;
begin
  -- The letter, then its signer, locked in that order.
  if p_kind in ('letter_sign', 'letter_code') then
    select * into l from engagement_letters where id = (select letter_id from engagement_letter_signers where id = p_id) for update;
    select * into s from engagement_letter_signers where id = p_id and letter_id = l.id for update;
    if s.id is null or l.status is distinct from 'sent' or s.signed_at is not null then return null; end if;
    if p_kind = 'letter_code' and s.locked_at is not null then return null; end if;
  elsif p_kind = 'letter_done' then
    select * into l from engagement_letters where id = p_id for update;
    if l.id is null or l.status <> 'completed' then return null; end if;
    select * into s from engagement_letter_signers where letter_id = l.id and signed_at is not null for update;
    if s.id is null then return null; end if;
  else
    raise exception 'Unknown practice email: %.', p_kind;
  end if;
  v_app := coalesce((select value from private.config where key = 'app_url'), 'https://counta-taxstreem.netlify.app');
  select * into pr from practices where id = l.practice_id;
  select legal_name into v_client from practice_intakes where id = l.intake_id;
  -- Replies go to the partner who signed (at their address now while they are in the practice), else the practice.
  v_reply := coalesce((select email from practice_members where id = l.partner_id and status = 'active'), l.partner_email, pr.email);

  if p_kind = 'letter_sign' then
    t := private.token_new('es');
    update engagement_letter_signers set token_hash = t->>'hash', token_expires = now() + interval '14 days', updated_at = now() where id = s.id;
    return jsonb_build_object('to', s.email, 'reply_to', v_reply, 'from_name', pr.name,
      'subject', 'Letter of engagement from ' || pr.name || ' to sign',
      'heading', 'Your letter of engagement',
      'greet', split_part(trim(s.name), ' ', 1),
      'lines', jsonb_build_array(pr.name || ' has signed its letter of engagement with ' || v_client || ' and sent it to you to read and sign.',
        'Use the button to open it. Before you sign, a 6-digit code is emailed to this address to confirm it is you. The link works for fourteen days.'),
      'button', 'Read and sign', 'link', v_app || '/sign/' || (t->>'token'), 'white_label', l.white_label);
  elsif p_kind = 'letter_code' then
    t := private.otp_new(s.id);
    update engagement_letter_signers set otp_hash = t->>'otp_hash', otp_expires = (t->>'otp_expires')::timestamptz, otp_tries = 0, updated_at = now()
    where id = s.id;
    return jsonb_build_object('to', s.email, 'reply_to', v_reply, 'from_name', pr.name,
      'subject', 'Your code to sign the letter of engagement',
      'heading', 'Your signing code',
      'greet', split_part(trim(s.name), ' ', 1),
      'lines', jsonb_build_array('Enter this code to sign the letter of engagement from ' || pr.name || '. It works for ten minutes.',
        'If you did not ask for a code, you can ignore this email.'),
      'button', null, 'link', null, 'code', t->>'code', 'white_label', l.white_label);
  end if;
  t := private.token_new('es');
  update engagement_letter_signers set token_hash = t->>'hash', token_expires = now() + interval '14 days', updated_at = now() where id = s.id;
  return jsonb_build_object('to', s.email, 'cc', v_reply, 'reply_to', v_reply, 'from_name', pr.name,
    'subject', 'Letter of engagement signed: ' || v_client,
    'heading', 'Your letter of engagement is signed',
    'greet', split_part(trim(s.name), ' ', 1),
    'lines', jsonb_build_array(pr.name || ' and ' || v_client || ' have both signed the letter of engagement.',
      'Use the button to download the signed letter with its certificate of signing. The link works for fourteen days.'),
    'button', 'Download the signed letter', 'link', v_app || '/sign/' || (t->>'token'), 'white_label', l.white_label);
end $$;

-- ---------------------------------------------------------------------------
-- 9. Letter files are for partners and managers, as intake files are
-- ---------------------------------------------------------------------------
-- (Redefined from 20261124000600_intake_conflicts.sql.) practice/<pid>/intake/... and practice/<pid>/letters/...: the
-- practice's active partners and managers, who keep the intakes and the letters (signed letters and their certificates
-- are there, and the practice function writes them under names it chooses); practice/<pid>/exports/...: its active
-- partners. Called by the bucket's policies as the signed-in person, so it reads the practice as its owner.
create or replace function private.practice_file_ok(p_name text) returns boolean
language sql stable security definer set search_path = public, private as $$
  select coalesce(p_name ~ '^practice/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/(intake|letters|exports)/[^/]', false)
    and exists (select 1 from practice_members pm
                where pm.practice_id::text = split_part(p_name, '/', 2) and pm.user_id = auth.uid() and pm.status = 'active'
                  and case split_part(p_name, '/', 3) when 'exports' then pm.role = 'partner' else pm.role in ('partner', 'manager') end)
$$;
revoke execute on function private.practice_file_ok(text) from public, anon;
grant execute on function private.practice_file_ok(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 10. Grants
-- ---------------------------------------------------------------------------
-- core.sql grants every private function to authenticated: the helpers this migration creates are not callable by the
-- signed-in person.
revoke all on function private.letter_file_ok(text, uuid, text), private.letter_years(jsonb), private.letter_fields(), private.letter_defaults(),
  private.letter_body_ok(jsonb), private.letter_merge_ok(jsonb),
  private.letter_default_body(), private.token_new(text), private.otp_send_ok(date, int), private.otp_new(uuid),
  private.otp_check(uuid, text, text, timestamptz, int, int, timestamptz), private.letter_event(uuid, text, text, text, text, jsonb),
  private.practice_mail(text, uuid), private.engagement_letters_freeze(), private.engagement_letter_events_guard(),
  private.letter_require(uuid, boolean), private.letter_json(public.engagement_letters), private.letter_template_json(public.practice_letter_templates),
  private.letter_template_ensure(uuid), private.letter_signer_by_token(text),
  private.letter_signer_state(public.engagement_letter_signers, public.engagement_letters), private.letter_intake_ready(uuid)
  from public, anon, authenticated;
revoke execute on function public.practice_letter_templates(uuid), public.practice_letter_template_save(uuid, jsonb), public.practice_letter_draft(uuid, jsonb),
  public.practice_letter_save(uuid, jsonb), public.practice_letter(uuid), public.practice_letter_prepare(uuid), public.practice_letter_send(uuid, jsonb),
  public.practice_letter_upload_signed(uuid, jsonb), public.practice_letter_void(uuid, text)
  from public, anon;
grant execute on function public.practice_letter_templates(uuid), public.practice_letter_template_save(uuid, jsonb), public.practice_letter_draft(uuid, jsonb),
  public.practice_letter_save(uuid, jsonb), public.practice_letter(uuid), public.practice_letter_prepare(uuid), public.practice_letter_send(uuid, jsonb),
  public.practice_letter_upload_signed(uuid, jsonb), public.practice_letter_void(uuid, text)
  to authenticated;
revoke all on function public.svc_letter_frozen(uuid, jsonb), public.svc_sign_open(text, text, text), public.svc_sign_code(text, text, text),
  public.svc_sign_verify(text, text, text, text), public.svc_sign_complete(text, jsonb), public.svc_practice_mail(text, uuid)
  from public, anon, authenticated;
grant execute on function public.svc_letter_frozen(uuid, jsonb), public.svc_sign_open(text, text, text), public.svc_sign_code(text, text, text),
  public.svc_sign_verify(text, text, text, text), public.svc_sign_complete(text, jsonb), public.svc_practice_mail(text, uuid)
  to service_role;
